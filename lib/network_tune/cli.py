"""User interfaces and passive diagnostics for network tuning."""
from __future__ import annotations

import argparse
import contextlib
import datetime
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

from .common import Context, TuneError, read_sysctl, valid_interface
from .buffers import BufferManager
from .egress import EgressManager
from .ports import PortManager


class TuneParser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        kwargs.setdefault("allow_abbrev", False)
        super().__init__(*args, **kwargs)


def globals_for(parser):
    for flag in ("dry-run", "yes", "non-interactive", "install-deps", "quiet", "verbose", "no-color", "json"):
        parser.add_argument("--" + flag, action="store_true", default=argparse.SUPPRESS)
    return parser


def parser():
    root = globals_for(TuneParser(
        prog="network tune", description="管理 TCP 缓冲区、网卡出口整形和返回客户端的端口限速；不自动测速或修改代理节点。"))
    groups = root.add_subparsers(dest="group", metavar="{status,diagnose,buffer,egress,port}")
    for command, text in (("status", "查看配置、实际队列和持久化来源"), ("diagnose", "被动观察资源和丢包增量，不产生测试流量")):
        action = globals_for(groups.add_parser(command, help=text))
        action.add_argument("--interface")
        if command == "diagnose":
            action.add_argument("--seconds", type=int, default=10)
    buffers = globals_for(groups.add_parser("buffer", help="TCP 缓冲区估算、设置和恢复"))
    actions = buffers.add_subparsers(dest="action", required=True)
    estimate = globals_for(actions.add_parser("estimate", help="根据真实 RTT、目标带宽和物理内存计算建议"))
    for option in ("rtt-ms", "tx-mbps", "rx-mbps"):
        estimate.add_argument("--" + option)
    change = globals_for(actions.add_parser("set", help="设置推荐或手动缓冲区"))
    for option in ("rtt-ms", "tx-mbps", "rx-mbps", "tx-max", "rx-max", "tx-triplet", "rx-triplet"):
        change.add_argument("--" + option)
    change.add_argument("--recommended", action="store_true")
    change.add_argument("--sync-core", action="store_true", help="明确同步所选方向的 net.core.*mem_max")
    change.add_argument("--set", dest="settings", action="append", default=[], metavar="KEY=VALUE")
    globals_for(actions.add_parser("restore", help="移除受管覆盖并恢复外部有效配置或原值"))
    egress = globals_for(groups.add_parser("egress", help="网卡出口队列"))
    actions = egress.add_subparsers(dest="action", required=True)
    for command in ("set", "clear", "restore", "adopt"):
        action = globals_for(actions.add_parser(command))
        action.add_argument("--interface", help="省略时仅在默认网卡唯一时自动选择")
        if command == "set":
            action.add_argument("--mode", required=True, choices=("tbf", "tbf-fq", "fq"))
            for option in ("rate-mbps", "maxrate-mbps", "burst-kib", "latency-ms", "queue-packets", "flow-limit"):
                action.add_argument("--" + option)
        if command == "adopt":
            action.add_argument("--service")
    ports = globals_for(groups.add_parser("port", help="按服务源端口限制返回客户端的出站流量"))
    actions = ports.add_subparsers(dest="action", required=True)
    globals_for(actions.add_parser("list"))
    action = globals_for(actions.add_parser("set"))
    action.add_argument("--id", required=True)
    action.add_argument("--interface")
    action.add_argument("--port", required=True, type=int)
    action.add_argument("--protocol", choices=("tcp", "udp", "both"), default="tcp")
    action.add_argument("--family", choices=("ipv4", "ipv6", "both"), default="both")
    for option in ("total-mbps", "flow-mbps", "burst-kib", "latency-ms", "queue-packets", "flow-limit"):
        action.add_argument("--" + option)
    action = globals_for(actions.add_parser("delete"))
    action.add_argument("--id", required=True)
    internal = groups.add_parser("internal", help=argparse.SUPPRESS)
    actions = internal.add_subparsers(dest="action", required=True)
    actions.add_parser("egress-apply").add_argument("interface")
    actions.add_parser("ports-apply").add_argument("--interface")
    groups._choices_actions = [choice for choice in groups._choices_actions if choice.dest != "internal"]
    return root


def _safe_probe(call):
    try:
        return call()
    except (TuneError, OSError, ValueError) as error:
        return {"unavailable": str(error), "code": getattr(error, "code", 3)}


def _json_command(ctx, args):
    result = ctx.run(args)
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise TuneError("系统命令未返回有效 JSON：" + args[0], 3)


def _interface(ctx, value=None):
    if value:
        valid_interface(value)
        ctx.run(["ip", "link", "show", "dev", value])
        return value
    devices = set()
    for family in ("-4", "-6"):
        routes = _json_command(ctx, ["ip", "-j", family, "route", "show", "default"])
        devices.update(row["dev"] for row in routes if row.get("dev"))
    if len(devices) != 1:
        raise TuneError("默认出口网卡不唯一或不存在，请明确提供 --interface", 2)
    return valid_interface(next(iter(devices)))


def _kernel(ctx):
    result = {"release": os.uname().release, "systemd": ctx.path("/run/systemd/system").is_dir()}
    for name in ("tcp_congestion_control", "tcp_available_congestion_control", "tcp_sack", "tcp_timestamps", "tcp_window_scaling"):
        result[name] = _safe_probe(lambda name=name: read_sysctl(ctx, "net.ipv4." + name))
    result["default_qdisc"] = _safe_probe(lambda: read_sysctl(ctx, "net.core.default_qdisc"))
    module = _safe_probe(lambda: ctx.run(["modinfo", "-F", "version", "tcp_bbr"]).stdout.strip())
    result["bbr_module_version"] = module if isinstance(module, str) and module else "未暴露/未知"
    return result


def _public_egress(data):
    if "interfaces" not in data:
        return data
    cleaned = {"interfaces": {}}
    for name, item in data["interfaces"].items():
        record = item.get("record") or {}
        service = item.get("service") or {}
        cleaned["interfaces"][name] = {
            "managed": item.get("managed", False), "enabled": record.get("enabled", False),
            "profile": record.get("profile"), "matches": item.get("matches"),
            "tree": item.get("tree", []),
            "service": {key: value for key, value in service.items() if key != "file"},
        }
    return cleaned


def status(ctx, interface=None):
    if interface:
        valid_interface(interface)
    interfaces = _safe_probe(lambda: _json_command(ctx, ["ip", "-j", "link", "show"]))
    shaped = _safe_probe(lambda: EgressManager(ctx).status(interface))
    if isinstance(shaped, dict):
        shaped = _public_egress(shaped)
    return {"time_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "kernel": _kernel(ctx), "links": interfaces,
            "buffers": _safe_probe(lambda: BufferManager(ctx).status()),
            "egress": shaped, "ports": _safe_probe(lambda: PortManager(ctx).status()),
            "notes": [
                "TCP 参数作用于本机终止的连接，不直接改变纯转发连接的端到端窗口。",
                "本机启用 SACK/时间戳不等于链路已协商成功，缓存估算不能修复握手改写。",
                "出站限速只约束返回客户端的服务端口，不是入方向限速。",
                "限速值是发送上限，不是吞吐或最低带宽保证；IFB 统计不可与物理出口相加。",
            ]}


def _passive_snapshot(ctx, interface=None):
    def proc(name):
        try:
            return ctx.path(name).read_text()
        except OSError:
            return ""
    qdisc_args = ["tc", "-j", "-s", "qdisc", "show"]
    if interface:
        qdisc_args += ["dev", valid_interface(interface)]
    sockets = _safe_probe(lambda: ctx.run(["ss", "-tin"]).stdout)
    socket_map = {}
    if isinstance(sockets, str):
        for entry in re.split(r"(?m)^(?=ESTAB|CLOSE-WAIT|FIN-WAIT)", sockets):
            if not entry.startswith(("ESTAB", "CLOSE-WAIT", "FIN-WAIT")):
                continue
            fields = entry.splitlines()[0].split()
            if len(fields) >= 5:
                match = re.search(r"\bbytes_retrans:(\d+)", entry)
                socket_map[" ".join(fields[3:5])] = int(match.group(1)) if match else 0
    cpu = proc("/proc/stat").splitlines()
    memory = proc("/proc/meminfo")
    return {"time": time.monotonic(), "cpu": cpu[0] if cpu else "",
            "memory": {key: int(value) * 1024 for key, value in
                       re.findall(r"^(MemTotal|MemAvailable|SwapTotal|SwapFree):\s+(\d+)", memory, re.MULTILINE)},
            "qdiscs": _safe_probe(lambda: _json_command(ctx, qdisc_args)),
            "links": _safe_probe(lambda: _json_command(ctx, ["ip", "-j", "-s", "-d", "link", "show"])),
            "sockets": socket_map}


def diagnose(ctx, args):
    if not 1 <= args.seconds <= 60:
        raise TuneError("--seconds 必须为 1 至 60 秒", 2)
    before = _passive_snapshot(ctx, args.interface)
    time.sleep(args.seconds)
    after = _passive_snapshot(ctx, args.interface)
    deltas = []
    if isinstance(before["qdiscs"], list) and isinstance(after["qdiscs"], list):
        keys = lambda row: (row.get("dev"), row.get("handle"), row.get("parent"), row.get("kind"))
        old = {keys(row): row for row in before["qdiscs"]}
        for row in after["qdiscs"]:
            previous = old.get(keys(row))
            if previous:
                delta = {field: row.get(field, 0) - previous.get(field, 0)
                         for field in ("bytes", "packets", "drops", "overlimits", "requeues")}
                deltas.append({"interface": row.get("dev"), "handle": row.get("handle"),
                               "kind": row.get("kind"), "counter_reset": any(v < 0 for v in delta.values()),
                               "delta": delta})
    nonidle = None
    try:
        old = list(map(int, before["cpu"].split()[1:9]))
        new = list(map(int, after["cpu"].split()[1:9]))
        delta = [b - a for a, b in zip(old, new)]
        if len(delta) == 8 and min(delta) >= 0 and sum(delta):
            nonidle = 100 * (sum(delta) - delta[3] - delta[4]) / sum(delta)
    except ValueError:
        pass
    common = set(before["sockets"]) & set(after["sockets"])
    retrans = sum(max(0, after["sockets"][key] - before["sockets"][key]) for key in common)
    return {"seconds": after["time"] - before["time"], "cpu_nonidle_percent": nonidle,
            "memory": after["memory"], "qdisc_deltas": deltas,
            "continuing_tcp_connections": len(common), "continuing_tcp_retransmitted_bytes": retrans,
            "warnings": ["被动观测不产生测试流量，不能据此保证带宽达标。",
                         "仅比较持续存活的 TCP 连接；新建、已结束连接不在重传增量中。",
                         "父子队列计数可能包含同一报文，请勿相加。",
                         "需要经实际业务路径验证；本机开关正常不能排除中间设备改写握手。"]}


def dispatch(ctx, args):
    group = args.group or "status"
    if group == "status":
        return status(ctx, getattr(args, "interface", None))
    if group == "diagnose":
        return diagnose(ctx, args)
    if group == "buffer":
        manager = BufferManager(ctx)
        if args.action == "estimate":
            return manager.estimate(args)
        ctx.require_mutation()
        with ctx.lock("network-tune"):
            return getattr(manager, args.action)(args)
    if group == "port" and args.action == "list":
        return PortManager(ctx).list()
    ctx.require_mutation()
    if group == "egress" or (group == "port" and args.action == "set"):
        args.interface = _interface(ctx, args.interface)
    if group == "internal":
        ctx.lock_wait_seconds = 60
    with ctx.unit_restore_scope(), ctx.lock("network-tune"), ctx.lock("network-qdisc"), ctx.runtime_transaction():
        if group == "egress":
            return getattr(EgressManager(ctx), args.action)(args)
        if group == "port":
            with ctx.lock("network-nftables"):
                return getattr(PortManager(ctx), args.action)(args)
        if group == "internal":
            if args.action == "egress-apply":
                return EgressManager(ctx).boot(args.interface)
            with ctx.lock("network-nftables"):
                return PortManager(ctx).boot(args.interface)
    raise TuneError("未知网络调优动作", 2)


def _size(value):
    if value is None:
        return "不可用"
    return f"{value / 1048576:.2f} MiB"


def _rate(value):
    return "无额外上限" if value is None else f"{value / 1_000_000:g} Mbps"


def _profile(value):
    if not value:
        return "未托管"
    mode = value.get("mode")
    if mode == "fq":
        return "每流 fq，" + _rate(value.get("maxrate_bps"))
    text = "总出口 " + _rate(value.get("rate_bps")) + f"，突发 {value.get('burst_bytes', 0) / 1024:g} KiB"
    if mode == "tbf":
        return text + f"，FIFO 排队预算 {value.get('latency_ms')} ms"
    return text + f"，fq 限长 {value.get('limit_packets')} 包（不承诺固定等待时限）"


def _rules(rules):
    if not rules:
        print("尚未设置端口限速。")
    for rule_id, rule in sorted(rules.items()):
        print(f"  {rule_id}: {rule['interface']} 源端口 {rule['port']} / {rule['protocol']} / {rule['family']}")
        profile = rule["profile"]
        print("    汇总：" + _rate(profile.get("rate_bps")) + "；每 TCP 流：" + _rate(profile.get("maxrate_bps")))


def render(result, args, ctx):
    if ctx.json_output:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        return
    if result.get("dry_run") or ctx.dry_run:
        print("演练：未修改系统配置。")
    if "kernel" in result:
        kernel = result["kernel"]
        print(f"网络调优状态：内核 {kernel['release']}；BBR 版本 {kernel['bbr_module_version']}")
        print("拥塞控制：" + str(kernel.get("tcp_congestion_control")))
        buffers = result["buffers"]
        print("\nTCP 参数：")
        if "unavailable" in buffers:
            print("  不可读取：" + buffers["unavailable"])
        else:
            for name, value in sorted(buffers.get("keys", {}).items()):
                print(f"  {name} = {value.get('runtime', '不可用')}")
                if value.get("source"):
                    print("    持久化来源：" + value["source"])
            if buffers.get("drift"):
                print("  注意：受管参数或持久配置存在差异。")
        print("\n出口队列：")
        egress = result["egress"]
        if "unavailable" in egress:
            print("  不可读取：" + egress["unavailable"])
        elif not egress.get("interfaces"):
            print("  尚未托管出口队列；指定 --interface 可查看现有队列。")
        for name, item in egress.get("interfaces", {}).items():
            print(f"  {name}: " + _profile(item.get("profile")))
            print(f"    实际队列：{', '.join(row['kind'] for row in item.get('tree', []))}；配置匹配：{item.get('matches')}")
            if item.get("service"):
                print("    开机启用：" + ("是" if item["service"].get("enabled") else "否"))
        print("\n端口限速：")
        ports = result["ports"]
        if "unavailable" in ports:
            print("  不可读取：" + ports["unavailable"])
        else:
            _rules(ports.get("rules", {}))
            for warning in ports.get("drift", []):
                print("  注意：" + warning)
        for note in result["notes"]:
            print("说明：" + note)
        return
    if "budget_bytes" in result:
        print("TCP 缓冲区建议：物理内存 " + _size(result.get("memory_bytes")) +
              "，单方向建议预算 " + _size(result["budget_bytes"]))
        for key, label in (("tx", "发送"), ("rx", "接收")):
            value = result.get(key)
            if not value:
                continue
            print(label + "方向：")
            print(f"  BDP：{value.get('bdp_bytes')} 字节；理论建议：{_size(value.get('needed_max_bytes'))}")
            print("  建议上限：" + _size(value.get("suggested_max_bytes")))
            if value.get("reason"):
                print("  " + str(value["reason"]))
            if value.get("suggested_triplet"):
                print("  三元组：" + " ".join(map(str, value["suggested_triplet"])))
        print("这是自动调节上限，不是预分配内存；手动值可覆盖建议，缓存不能修复链路丢包或握手改写。")
        return
    if "qdisc_deltas" in result:
        print(f"被动观测 {result['seconds']:.1f} 秒；CPU 非空闲 {result['cpu_nonidle_percent']}%")
        print("可用内存：" + _size(result.get("memory", {}).get("MemAvailable")))
        for row in result["qdisc_deltas"]:
            print(f"  {row['interface']} {row['kind']} {row['handle']}: "
                  f"发送增量 {row['delta']['bytes']} B，丢弃增量 {row['delta']['drops']}" +
                  ("（计数器重置，不能作差）" if row["counter_reset"] else ""))
        print(f"持续存活连接 {result['continuing_tcp_connections']}；重传字节增量 {result['continuing_tcp_retransmitted_bytes']}")
        for warning in result["warnings"]:
            print("说明：" + warning)
        return
    if "rules" in result:
        _rules(result["rules"])
    elif "rule" in result:
        _rules({result["rule"]["id"]: result["rule"]})
    if "deleted" in result:
        print("删除规则：" + result["deleted"])
    if "profile" in result:
        print(str(result.get("interface", "")) + "：" + _profile(result["profile"]))
    elif "interface" in result and any(key in result for key in ("restore", "restored", "cleared")):
        restoring = result.get("restore", result.get("restored", False))
        print(result["interface"] + ("：恢复接管前队列及旧服务，可能重新启用旧限速。" if restoring else
                                    "：取消出口整形，恢复内核默认队列；保留独立端口规则。"))
    if "values" in result:
        for name, value in result["values"].items():
            print("  " + name + " = " + str(value))
    print(result.get("message") or ("操作已完成。" if result.get("changed") else
                                  "已显示计划。" if ctx.dry_run else "操作完成，配置无需重复应用。"))


def _choose(title, options):
    print("\n" + title)
    for index, (_, text) in enumerate(options, 1):
        print(f"  {index}) {text}")
    print("  0) 返回")
    while True:
        try:
            answer = input("请选择：").strip()
        except EOFError:
            raise TuneError("输入已结束", 130)
        if answer == "0":
            return None
        if answer.isdigit() and 1 <= int(answer) <= len(options):
            return options[int(answer) - 1][0]
        print("请输入列表中的编号。")


def _ask(label, default=None):
    prompt = label + (f" [{default}]" if default is not None else "") + "："
    try:
        value = input(prompt).strip()
    except EOFError:
        raise TuneError("输入已结束", 130)
    if value == ":q":
        raise TuneError("操作已取消", 130)
    return value or (str(default) if default is not None else "")


def _select_interface(ctx):
    links = _json_command(ctx, ["ip", "-j", "-d", "link", "show"])
    entries = [(row["ifname"], row["ifname"] + " / " + row.get("operstate", "未知"))
               for row in links if row["ifname"] != "lo" and
               row.get("linkinfo", {}).get("info_kind") != "ifb"]
    selected = _choose("选择作用网卡", entries)
    return selected


def _menu_action(arguments, ctx):
    path = os.environ.get("VPSCTL_TUNE_FRONTEND_PATH")
    kind = os.environ.get("VPSCTL_TUNE_FRONTEND_KIND")
    if path and kind in ("vpsctl", "po0") and Path(path).is_file():
        command = ["bash", path] + (["tune"] if kind == "po0" else [])
        flags = []
        if ctx.dry_run:
            flags.append("--dry-run")
        if truth_env("VPSCTL_INSTALL_DEPS"):
            flags.append("--install-deps")
        result = subprocess.run(command + flags + arguments, check=False)
        if result.returncode not in (0, 130):
            print("该操作未成功，请查看上方原因。", file=sys.stderr)
        return
    selected = parser().parse_args(arguments)
    selected_ctx = Context(dry_run=ctx.dry_run, assume_yes=ctx.assume_yes,
                           non_interactive=ctx.non_interactive)
    render(dispatch(selected_ctx, selected), selected, selected_ctx)


def truth_env(name):
    return os.environ.get(name, "").lower() in ("1", "yes", "true", "on")


def _buffer_menu(ctx):
    selection = _choose("TCP 缓冲区", [
        ("status", "查看当前参数"), ("estimate", "仅计算建议"),
        ("recommended", "计算建议并设置"), ("manual", "手动设置收发上限"),
        ("advanced", "高级 TCP 参数"), ("restore", "恢复外部有效配置/原值"),
    ])
    if selection is None:
        return
    if selection == "status":
        return _menu_action(["status"], ctx)
    if selection == "restore":
        return _menu_action(["buffer", "restore"], ctx)
    if selection in ("estimate", "recommended"):
        print("填写实际链路 RTT；不要使用被中间网关提前应答的建连耗时。带宽按本机发送/接收分别填写。")
        values = ["--rtt-ms", _ask("RTT（毫秒）")]
        for key, label in (("tx-mbps", "目标发送 Mbps，留空不修改"), ("rx-mbps", "目标接收 Mbps，留空不修改")):
            value = _ask(label)
            if value:
                values += ["--" + key, value]
        action = ["buffer", "estimate"] if selection == "estimate" else ["buffer", "set", "--recommended"]
        if selection == "recommended":
            sync = _choose("是否同步核心 socket 上限", [("no", "保持 net.core.*mem_max"), ("yes", "同步所选方向 net.core.*mem_max")])
            if sync is None:
                return
            if sync == "yes":
                values += ["--sync-core"]
        return _menu_action(action + values, ctx)
    if selection == "manual":
        values = []
        for key, label in (("tx-max", "发送上限，如 16MiB；留空保持"), ("rx-max", "接收上限，如 16MiB；留空保持")):
            value = _ask(label)
            if value:
                values += ["--" + key, value]
        if values:
            sync = _choose("是否同步核心 socket 上限", [("no", "保持 net.core.*mem_max"), ("yes", "同步所选方向 net.core.*mem_max")])
            if sync is None:
                return
            if sync == "yes":
                values += ["--sync-core"]
            return _menu_action(["buffer", "set"] + values, ctx)
        return
    fields = [
        ("net.ipv4.tcp_rmem", "接收完整三元组：最小/初始/最大"),
        ("net.ipv4.tcp_wmem", "发送完整三元组：最小/初始/最大"),
        ("net.core.rmem_max", "核心接收 socket 上限"),
        ("net.core.wmem_max", "核心发送 socket 上限"),
        ("net.ipv4.tcp_sack", "SACK"), ("net.ipv4.tcp_timestamps", "TCP 时间戳"),
        ("net.ipv4.tcp_window_scaling", "TCP 窗口缩放"),
        ("net.ipv4.tcp_moderate_rcvbuf", "接收缓冲区自动调节"),
        ("net.ipv4.tcp_mtu_probing", "MTU 黑洞探测"),
    ]
    field = _choose("选择要明确修改的参数", fields)
    if not field:
        return
    if field.endswith(("tcp_rmem", "tcp_wmem")):
        value = _ask("最小 初始 最大，如 4096 131072 16MiB")
    elif field.startswith("net.core."):
        value = _ask("上限，如 16MiB")
    elif field.endswith("tcp_timestamps"):
        value = _choose("时间戳模式", [("1", "开启，使用随机偏移"), ("2", "开启，不使用随机偏移"), ("0", "关闭")])
    elif field.endswith("tcp_mtu_probing"):
        value = _choose("探测模式", [("1", "发现黑洞时启用"), ("2", "始终启用"), ("0", "关闭")])
    else:
        value = _choose("参数状态", [("1", "开启"), ("0", "关闭")])
    if value is not None:
        _menu_action(["buffer", "set", "--set", field + "=" + value], ctx)


def _egress_menu(ctx):
    selection = _choose("网卡出口整形", [
        ("set", "设置总出口/每流节奏"), ("adopt", "接管已识别的旧优化服务"),
        ("clear", "取消本模块整形，恢复内核默认队列"),
        ("restore", "恢复首次接管前队列及服务（可能重新启用旧限速）"),
    ])
    if not selection:
        return
    interface = _select_interface(ctx)
    if not interface:
        return
    values = ["egress", selection, "--interface", interface]
    if selection == "set":
        mode = _choose("选择队列模式", [("tbf", "总出口＋FIFO"), ("tbf-fq", "总出口＋fq"), ("fq", "全网卡每流发送节奏")])
        if not mode:
            return
        values += ["--mode", mode]
        if mode == "fq":
            values += ["--maxrate-mbps", _ask("每流 Mbps，输入 none 取消额外上限", "none")]
        else:
            values += ["--rate-mbps", _ask("网卡总出口 Mbps"),
                       "--burst-kib", _ask("允许突发量 KiB（可编辑起点）", "64")]
            if mode == "tbf":
                values += ["--latency-ms", _ask("FIFO 排队预算 ms（不是端到端时延）", "50")]
            else:
                values += ["--queue-packets", _ask("fq 总限长，包数", "1024"),
                           "--flow-limit", _ask("fq 每流限长，包数", "100")]
                print("使用 fq 子队列后按包数排队，不承诺固定毫秒等待上限。")
    _menu_action(values, ctx)


def _port_menu(ctx):
    selection = _choose("返回客户端的端口限速", [("list", "查看规则"), ("set", "添加或修改规则"), ("delete", "删除规则")])
    if not selection:
        return
    if selection == "list":
        return _menu_action(["port", "list"], ctx)
    if selection == "delete":
        rules = PortManager(ctx).list().get("rules", {})
        rule_id = _choose("选择规则", [(key, f"{key}: {rule['interface']}:{rule['port']}/{rule['protocol']}") for key, rule in sorted(rules.items())])
        if rule_id:
            return _menu_action(["port", "delete", "--id", rule_id], ctx)
        return
    interface = _select_interface(ctx)
    if not interface:
        return
    rule_id = _ask("规则名称 ID（相同 ID 表示修改）")
    port = _ask("本机服务源端口；po0 填返回客户端的入口端口")
    protocol = _choose("协议", [("tcp", "TCP"), ("udp", "UDP 汇总"), ("both", "TCP＋UDP 共享汇总")])
    if not protocol:
        return
    family = _choose("地址族", [("both", "IPv4＋IPv6 共享上限"), ("ipv4", "IPv4"), ("ipv6", "IPv6")])
    if not family:
        return
    mode = "total"
    if protocol == "tcp":
        mode = _choose("限速方式", [("total", "所有连接共享端口总额"), ("flow", "每条 TCP 连接发送节奏"), ("both", "端口总额与每连接上限同时设置")])
        if not mode:
            return
    values = ["port", "set", "--id", rule_id, "--interface", interface,
              "--port", port, "--protocol", protocol, "--family", family]
    if mode in ("total", "both"):
        values += ["--total-mbps", _ask("端口汇总 Mbps")]
    if mode in ("flow", "both"):
        values += ["--flow-mbps", _ask("每 TCP 流 Mbps")]
    print("该规则不限制入方向，也不会自动跟随代理节点端口变化。")
    _menu_action(values, ctx)


def menu(ctx):
    while True:
        selection = _choose("网络调优", [
            ("buffer", "TCP 缓冲区"), ("egress", "出口整形"),
            ("port", "端口限速"), ("status", "查看完整状态"),
            ("diagnose", "被动诊断（不测速）"),
        ])
        if selection is None:
            return 0
        try:
            if selection == "buffer":
                _buffer_menu(ctx)
            elif selection == "egress":
                _egress_menu(ctx)
            elif selection == "port":
                _port_menu(ctx)
            else:
                values = [selection]
                if selection == "diagnose":
                    values += ["--seconds", _ask("观察秒数，1 至 60", "10")]
                _menu_action(values, ctx)
        except TuneError as error:
            print("[错误] " + str(error), file=sys.stderr)


def _interrupted(signum, frame):
    raise TuneError("操作被中断", 130)


def main(argv=None):
    try:
        if sys.version_info < (3, 9):
            raise TuneError("网络调优需要 Python 3.9 或更新版本", 3)
        args = parser().parse_args(argv)
        for flag, name in (("quiet", "VPSCTL_QUIET"), ("verbose", "VPSCTL_VERBOSE"),
                           ("no_color", "VPSCTL_NO_COLOR"), ("install_deps", "VPSCTL_INSTALL_DEPS")):
            if getattr(args, flag, False):
                os.environ[name] = "1"
        ctx = Context(dry_run=getattr(args, "dry_run", None), assume_yes=getattr(args, "yes", None),
                      non_interactive=getattr(args, "non_interactive", None),
                      json_output=getattr(args, "json", False))
        for name in ("SIGINT", "SIGTERM", "SIGHUP"):
            if hasattr(signal, name):
                signal.signal(getattr(signal, name), _interrupted)
        if not args.group and sys.stdin.isatty() and sys.stdout.isatty() and not ctx.non_interactive and not ctx.json_output:
            return menu(ctx)
        if args.group == "internal":
            ctx.assume_yes = True
            ctx.non_interactive = True
        result = dispatch(ctx, args)
        render(result, args, ctx)
        return 0
    except TuneError as error:
        print("[错误] " + str(error), file=sys.stderr)
        return error.code
    except KeyboardInterrupt:
        print("操作已取消。", file=sys.stderr)
        return 130
    except BrokenPipeError:
        return 130
