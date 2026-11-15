"""Root queue profiles and reversible ownership of their boot service."""

import copy
import json
import math
import re
import shlex

from .common import TuneError, parse_mbps, valid_interface


LEGACY_UNITS = (
    "network-tuning-fq.service",
    "network-tuning-po0-shaper.service",
    "network-tuning-us-shaper.service",
)
MARKER = "# Managed by vpsctl network tune egress."
_FQ_INTS = {"limit", "flow_limit", "buckets", "orphan_mask", "quantum", "initial_quantum"}
_FQ_RATES = {"maxrate", "defrate", "low_rate_threshold"}
_FQ_TIMES = {"refill_delay", "ce_threshold", "horizon", "offload_horizon"}
_CODEL_INTS = {"limit", "flows", "quantum", "memory_limit", "drop_batch"}
_HANDLE = re.compile(r"^[0-9a-fA-F]{0,4}:[0-9a-fA-F]{0,4}$")


def _json_run(ctx, argv):
    result = ctx.run(argv)
    try:
        value = json.loads(result.stdout)
    except (TypeError, ValueError) as exc:
        raise TuneError("无法解析 tc JSON 输出", 3) from exc
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise TuneError("tc JSON 输出格式不受支持", 3)
    return value


def read_tree(ctx, iface, stats=False):
    """Return only the root tree; clsact/ingress remain independently owned."""
    iface = valid_interface(iface)
    argv = ["tc", "-j"] + (["-s"] if stats else []) + ["qdisc", "show", "dev", iface]
    tree = _json_run(ctx, argv)
    tbfs = [node for node in tree if node.get("kind") == "tbf"]
    if tbfs:
        # Ordinary tc JSON omits the byte limit, mpu and rate-table cell size.
        # Keep its exact numeric burst, merging the missing detailed fields.
        detailed = _json_run(ctx, ["tc", "-j", "-d", "-r", "qdisc", "show", "dev", iface])
        for node in tbfs:
            other = next((item for item in detailed if item.get("kind") == "tbf" and item.get("handle") == node.get("handle")), None)
            if other is None:
                raise TuneError("读取 TBF 详细快照时队列发生变化", 10)
            opts = node.setdefault("options", {})
            detail = _options(other)
            if "minburst" in opts or "mtu" in detail or "peakrate" in opts:
                # iproute2 prints peakrate only in non-JSON output. Refuse
                # this unsupported variant instead of losing the hidden rate.
                raise TuneError("不支持完整保存带 peakrate 的 TBF", 3)
            burst = detail.get("burst")
            if isinstance(burst, str):
                cell = re.search(r"/(\d+)$", burst)
                if not cell:
                    raise TuneError("TBF 详细 burst 格式不受支持", 3)
                opts["burst_cell"] = int(cell[1])
            if "burst_raw" in detail:
                opts["burst_restore_bytes"] = _tbf_input_bytes(ctx, opts["rate"], detail["burst_raw"])
            opts.update({key: value for key, value in detail.items() if key not in ("burst", "burst_raw")})
    return [item for item in tree if item.get("kind") not in ("clsact", "ingress")
            and not str(item.get("parent", "")).startswith("ffff:")]


def _options(node):
    options = node.get("options", {})
    if not isinstance(options, dict):
        raise TuneError("队列选项格式不受支持", 3)
    # iproute2 emits trailing spaces in these two JSON field names.
    result = {key.strip(): value for key, value in options.items()}
    if node.get("kind") == "fq_codel":
        result.setdefault("ecn", False)
    return result


def _number(value, label, minimum=0):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < minimum:
        raise TuneError("无效的队列参数：" + label, 3)
    return format(value, ".12g")


def _codel_input_us(value):
    """Invert fq_codel's floored 1024 ns tick -> integer us dump."""
    _number(value, "CoDel time")
    if int(value) != value:
        raise TuneError("CoDel 快照时间必须为整数微秒", 3)
    ticks = (int(value) * 1000 + 1023) // 1024
    return (ticks * 1024 + 999) // 1000


def _tbf_input_bytes(ctx, rate, raw_ticks):
    """Recover the least whole-byte burst that dumps the saved psched tick."""
    try:
        ticks = int(raw_ticks, 16) if isinstance(raw_ticks, str) else int(raw_ticks)
        fields = ctx.run(["cat", "/proc/net/psched"]).stdout.split()
        t2us, us2t, clock_res = (int(value, 16) for value in fields[:3])
        if clock_res == 1_000_000_000:
            t2us = us2t
        numerator, denominator = ticks * int(rate) * us2t, t2us * clock_res
        if min(ticks, rate, us2t, denominator) <= 0:
            raise ValueError
        return (numerator + denominator - 1) // denominator
    except (ValueError, TypeError, ZeroDivisionError) as exc:
        raise TuneError("无法还原 TBF psched burst 精度", 3) from exc


def _option_args(node, complete=True):
    """Serialize every understood option; never silently drop unknown options."""
    kind, opts = node.get("kind"), _options(node)
    args = []
    if kind in ("mq", "noqueue"):
        allowed = set()
    elif kind == "fq":
        allowed = _FQ_INTS | _FQ_RATES | _FQ_TIMES | {
            "pacing", "timer_slack", "horizon_drop", "horizon_cap", "bands", "priomap", "weights"}
        for key in sorted(_FQ_INTS & opts.keys()):
            args += [key, _number(opts[key], key)]
        for key in sorted(_FQ_RATES & opts.keys()):
            args += [key, _number(opts[key] * 8, key) + "bit"]
        if complete and "low_rate_threshold" not in opts:
            # tc omits this field when it is explicitly zero.
            args += ["low_rate_threshold", "0bit"]
        for key in sorted(_FQ_TIMES & opts.keys()):
            args += [key, _number(opts[key], key) + "us"]
        if "timer_slack" in opts:
            args += ["timer_slack", _number(opts["timer_slack"], "timer_slack") + "ns"]
        args += ["pacing" if opts.get("pacing", True) else "nopacing"]
        for key in ("horizon_drop", "horizon_cap"):
            if key in opts:
                args.append(key)
        if "bands" in opts or "priomap" in opts:
            if opts.get("bands") != 3 or len(opts.get("priomap", [])) != 16:
                raise TuneError("无法完整恢复 fq bands/priomap", 3)
            args += ["bands", "3", "priomap"] + [_number(v, "priomap") for v in opts["priomap"]]
        if "weights" in opts:
            if not isinstance(opts["weights"], list) or len(opts["weights"]) != 3:
                raise TuneError("无法完整恢复 fq weights", 3)
            args += ["weights"] + [_number(v, "weights", 1) for v in opts["weights"]]
    elif kind == "fq_codel":
        allowed = _CODEL_INTS | {"target", "interval", "ecn", "ce_threshold", "ce_threshold_selector", "ce_threshold_mask"}
        for key in sorted(_CODEL_INTS & opts.keys()):
            args += [key, _number(opts[key], key)]
        for key in ("target", "interval", "ce_threshold"):
            if key in opts:
                args += [key, str(_codel_input_us(opts[key])) + "us"]
        # noecn is represented by the absence of the JSON ecn field.
        args += ["ecn" if opts.get("ecn", False) else "noecn"]
        if "ce_threshold_selector" in opts or "ce_threshold_mask" in opts:
            selector, mask = opts.get("ce_threshold_selector", 0), opts.get("ce_threshold_mask", 0)
            if any(not isinstance(value, int) or not 0 <= value <= 255 for value in (selector, mask)):
                raise TuneError("无法恢复 fq_codel ce_threshold_selector", 3)
            args += ["ce_threshold_selector", str(selector) + "/" + str(mask)]
    elif kind == "tbf":
        allowed = {"rate", "burst", "burst_cell", "burst_restore_bytes", "lat", "limit", "mpu", "overhead", "linklayer"}
        for key in ("rate", "burst"):
            if key not in opts:
                raise TuneError("TBF 快照缺少 " + key, 3)
        burst = _number(opts.get("burst_restore_bytes", opts["burst"]), "burst", 1)
        if "burst_cell" in opts:
            cell = opts["burst_cell"]
            if not isinstance(cell, int) or cell < 1 or cell & (cell - 1):
                raise TuneError("TBF burst cell 必须为 2 的幂", 3)
            burst += "/" + str(cell)
        args += ["rate", _number(opts["rate"] * 8, "rate", 1) + "bit", "burst", burst]
        if "limit" in opts:
            args += ["limit", _number(opts["limit"], "limit", 1)]
        elif "lat" in opts:
            args += ["latency", _number(opts["lat"], "lat") + "us"]
        else:
            raise TuneError("TBF 快照缺少队列长度/延迟", 3)
        for key in ("mpu", "overhead"):
            if key in opts:
                args += [key, _number(opts[key], key)]
        if "linklayer" in opts:
            if opts["linklayer"] not in ("ethernet", "atm"):
                raise TuneError("无法恢复 TBF linklayer", 3)
            args += ["linklayer", opts["linklayer"]]
    else:
        raise TuneError("无法完整保存/恢复此队列：" + str(kind), 3)
    unknown = opts.keys() - allowed
    if unknown:
        raise TuneError("队列包含不支持的选项：" + ", ".join(sorted(unknown)), 3)
    return args


def _validate_tree(tree):
    roots = [node for node in tree if node.get("root")]
    if len(roots) != 1:
        raise TuneError("无法识别唯一 root qdisc", 3)
    root = roots[0]
    children = [node for node in tree if not node.get("root")]
    for node in tree:
        if not _HANDLE.fullmatch(node.get("handle", "")):
            raise TuneError("队列句柄无效", 3)
        _option_args(node)
    if children:
        prefix = root["handle"].split(":")[0]
        if root["kind"] not in ("mq", "tbf"):
            raise TuneError("不支持此 root 的子队列拓扑", 3)
        parents = set()
        for node in children:
            parent = node.get("parent", "")
            if not _HANDLE.fullmatch(parent) or parent.split(":")[0] not in (prefix, "" if prefix == "0" else prefix):
                raise TuneError("不支持嵌套/脱离 root 的队列", 3)
            if parent in parents or node["kind"] not in ("fq", "fq_codel", "noqueue"):
                raise TuneError("不支持的子队列", 3)
            parents.add(parent)
        if root["kind"] == "tbf" and (len(children) != 1 or children[0]["kind"] != "fq" or children[0]["parent"].split(":")[1] != "1"):
            raise TuneError("仅支持 TBF 内置队列或 TBF+fq", 3)
    return root, children


def capture_snapshot(ctx, iface):
    tree = read_tree(ctx, iface)
    root, _ = _validate_tree(tree)
    parents = ["root"]
    if root["handle"] != "0:":
        parents.append(root["handle"])
    for parent in parents:
        argv = ["tc", "-j", "filter", "show", "dev", iface]
        argv += ["root"] if parent == "root" else ["parent", parent]
        if _json_run(ctx, argv):
            raise TuneError("root 队列存在外部过滤器，拒绝替换", 10)
    return {"schema_version": 1, "tree": [
        {key: copy.deepcopy(node[key]) for key in ("kind", "handle", "root", "parent", "options") if key in node}
        for node in tree]}


def _burst_tolerance(rate_bytes):
    # tc converts the token bucket through integer microseconds/psched ticks.
    return max(1, math.ceil(rate_bytes / 1_000_000))


def _same_options(expected, actual, kind, complete=True):
    for key, value in expected.items():
        if key not in actual:
            return False
        tolerance = 0
        if kind == "tbf" and key == "burst":
            tolerance = _burst_tolerance(expected.get("rate", 0))
        elif kind == "tbf" and key == "lat":
            tolerance = 2
        if tolerance:
            if abs(value - actual[key]) > tolerance:
                return False
        elif actual[key] != value:
            return False
    if kind == "fq":
        if actual.get("maxrate") != expected.get("maxrate"):
            return False
        if actual.get("pacing", True) != expected.get("pacing", True):
            return False
        if complete and any(actual.get(key, 0) != expected.get(key, 0) for key in ("defrate", "low_rate_threshold")):
            return False
    if kind == "fq_codel" and actual.get("ecn", False) != expected.get("ecn", False):
        return False
    return True


def _snapshot_matches(ctx, iface, snapshot):
    expected = snapshot["tree"]
    actual = read_tree(ctx, iface)
    eroot, echildren = _validate_tree(expected)
    try:
        aroot, achildren = _validate_tree(actual)
    except TuneError:
        return False
    if len(expected) != len(actual) or eroot["kind"] != aroot["kind"]:
        return False
    pairs = [(eroot, aroot)]
    by_minor = {node["parent"].split(":")[1]: node for node in achildren}
    for node in echildren:
        other = by_minor.get(node["parent"].split(":")[1])
        if other is None or node["kind"] != other["kind"]:
            return False
        pairs.append((node, other))
    return all(_same_options(_options(a), _options(b), a["kind"]) for a, b in pairs)


def _free_handle(tree, preferred="a100:"):
    if not re.fullmatch(r"[0-9a-fA-F]{1,4}:", preferred):
        raise TuneError("无效的队列句柄", 2)
    occupied = {node.get("handle") for node in tree}
    start = int(preferred[:-1], 16)
    for offset in range(65534):
        value = 1 + ((start - 1 + offset) % 65534)
        handle = f"{value:x}:"
        if handle not in occupied:
            return handle
    raise TuneError("没有可用队列句柄", 10)


def _reset_root(ctx, iface):
    tree = read_tree(ctx, iface)
    roots = [node for node in tree if node.get("root")]
    if len(roots) == 1 and roots[0].get("kind") == "noqueue":
        return
    if len(roots) == 1 and roots[0].get("handle") == "0:":
        # A kernel-created handle zero cannot be deleted. A temporary owned
        # handle lets deletion recreate the device's actual kernel default.
        ctx.mutate(["tc", "qdisc", "replace", "dev", iface, "root", "handle", _free_handle(tree), "fq"])
    ctx.mutate(["tc", "qdisc", "del", "dev", iface, "root"])


def restore_snapshot(ctx, iface, snapshot):
    iface = valid_interface(iface)
    if not isinstance(snapshot, dict) or snapshot.get("schema_version") != 1:
        raise TuneError("无效的队列快照", 10)
    root, children = _validate_tree(snapshot.get("tree", []))
    if _snapshot_matches(ctx, iface, snapshot):
        return
    commands = []
    current = read_tree(ctx, iface)
    root_handle = _free_handle(current, root["handle"] if root["handle"] != "0:" else "a200:")
    if root["kind"] != "noqueue":
        commands.append(["tc", "qdisc", "replace", "dev", iface, "root", "handle", root_handle, root["kind"]] + _option_args(root))
        handles = {root_handle, *(node.get("handle") for node in current)}
        for node in sorted(children, key=lambda item: int(item["parent"].split(":")[1], 16)):
            handle = node["handle"]
            if handle == "0:" or handle in handles:
                handle = _free_handle([{"handle": value} for value in handles], "a201:")
            handles.add(handle)
            parent = root_handle + node["parent"].split(":")[1]
            commands.append(["tc", "qdisc", "replace", "dev", iface, "parent", parent, "handle", handle, node["kind"]] + _option_args(node))
    # A fresh handle replaces the whole root tree without inheriting options.
    # noqueue is intrinsic to the device and is restored by deleting our root.
    if root["kind"] == "noqueue":
        _reset_root(ctx, iface)
    intrinsic_children = {}
    expected_children = {node["parent"].split(":")[1]: node for node in children}
    for argv in commands:
        if root["kind"] == "mq" and "parent" in argv:
            parent = argv[argv.index("parent") + 1]
            expected = expected_children[parent.split(":")[1]]
            intrinsic = intrinsic_children.get(parent)
            if (expected["handle"] == "0:" and intrinsic and intrinsic.get("handle") == "0:"
                    and intrinsic["kind"] == expected["kind"]
                    and _same_options(_options(expected), _options(intrinsic), expected["kind"])):
                # mq has already recreated this exact intrinsic default leaf.
                continue
        try:
            ctx.mutate(argv)
        except TuneError as exc:
            if "weights" not in argv or "Not enough elements in weights" not in str(exc):
                raise
            # iproute2 before 6.16 has an extra NEXT_ARG in the weights
            # parser. Its error occurs before any netlink mutation. Retry
            # only that exact error, supplying its skipped first argument.
            index = argv.index("weights") + 1
            ctx.mutate(argv[:index] + [argv[index]] + argv[index:])
        if root["kind"] == "mq" and "root" in argv:
            intrinsic_children = {node["parent"]: node for node in read_tree(ctx, iface) if "parent" in node}
    if not _snapshot_matches(ctx, iface, snapshot):
        raise TuneError("恢复后的完整队列配置与快照不一致", 20)


def _validate_profile(profile):
    mode = profile.get("mode")
    if mode not in ("fq", "tbf", "tbf-fq"):
        raise TuneError("不支持的出口模式", 2)
    if mode != "fq":
        for key in ("rate_bps", "burst_bytes", "latency_ms"):
            _number(profile.get(key), key, 1 if key != "latency_ms" else 0.001)
    for key in ("maxrate_bps", "limit_packets", "flow_limit", "orphan_mask"):
        if profile.get(key) is not None:
            _number(profile[key], key, 0 if key == "orphan_mask" else 1)
    if profile.get("maxrate_bps", 0) is not None and profile.get("maxrate_bps", 0) >= 0xFFFFFFFF * 8:
        raise TuneError("fq maxrate 超过内核支持范围", 2)


def _fq_profile_options(profile):
    opts = {}
    for key, tc_key in (("limit_packets", "limit"), ("flow_limit", "flow_limit"), ("orphan_mask", "orphan_mask")):
        if profile.get(key) is not None:
            opts[tc_key] = profile[key]
    if profile.get("maxrate_bps") is not None:
        opts["maxrate"] = profile["maxrate_bps"] // 8
    return opts


def profile_matches(ctx, iface, profile):
    _validate_profile(profile)
    try:
        root, children = _validate_tree(read_tree(ctx, iface))
    except TuneError:
        return False
    mode = profile["mode"]
    if mode == "fq":
        return root["kind"] == "fq" and not children and _same_options(_fq_profile_options(profile), _options(root), "fq", complete=False)
    if root["kind"] != "tbf" or len(children) != (1 if mode == "tbf-fq" else 0):
        return False
    opts = _options(root)
    wanted = {"rate": profile["rate_bps"] // 8, "burst": profile["burst_bytes"], "lat": profile["latency_ms"] * 1000}
    if not _same_options(wanted, opts, "tbf"):
        return False
    return mode == "tbf" or (children[0]["kind"] == "fq" and _same_options(_fq_profile_options(profile), _options(children[0]), "fq", complete=False))


def apply_profile(ctx, iface, profile, handle="a100:"):
    iface = valid_interface(iface)
    _validate_profile(profile)
    if profile_matches(ctx, iface, profile):
        return
    tree = read_tree(ctx, iface)
    root_handle = _free_handle(tree, handle)
    mode = profile["mode"]
    argv = ["tc", "qdisc", "replace", "dev", iface, "root", "handle", root_handle]
    if mode == "fq":
        argv += ["fq"] + _option_args({"kind": "fq", "options": _fq_profile_options(profile)}, complete=False)
    else:
        argv += ["tbf", "rate", str(profile["rate_bps"]) + "bit", "burst", str(profile["burst_bytes"]),
                 "latency", format(profile["latency_ms"], ".12g") + "ms"]
    ctx.mutate(argv)
    if mode == "tbf-fq":
        child_handle = _free_handle(tree + [{"handle": root_handle}], root_handle)
        ctx.mutate(["tc", "qdisc", "replace", "dev", iface, "parent", root_handle + "1", "handle", child_handle,
                    "fq"] + _option_args({"kind": "fq", "options": _fq_profile_options(profile)}, complete=False))
    if not profile_matches(ctx, iface, profile):
        raise TuneError("队列应用后读回校验失败", 20)


def _positive(value, name, default=None):
    value = default if value is None else value
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise TuneError(name + " 必须为正数", 2) from exc
    if not math.isfinite(result) or result <= 0:
        raise TuneError(name + " 必须为正数", 2)
    return result


def _profile_from_args(args):
    mode = args.mode
    profile = {"mode": mode}
    if mode != "fq":
        if getattr(args, "rate_mbps", None) is None:
            raise TuneError("TBF 必须指定 --rate-mbps", 2)
        profile.update(rate_bps=parse_mbps(args.rate_mbps),
                       burst_bytes=int(_positive(getattr(args, "burst_kib", None), "burst-kib", 64) * 1024),
                       latency_ms=_positive(getattr(args, "latency_ms", None), "latency-ms", 20 if mode == "tbf-fq" else 50))
    elif any(getattr(args, key, None) is not None for key in ("rate_mbps", "burst_kib", "latency_ms")):
        raise TuneError("fq 不接受总速率/burst/latency 参数", 2)
    maxrate = getattr(args, "maxrate_mbps", None)
    if mode == "tbf" and any(getattr(args, key, None) is not None for key in ("maxrate_mbps", "queue_packets", "flow_limit")):
        raise TuneError("纯 TBF 不接受 fq 参数", 2)
    if mode != "tbf":
        profile["maxrate_bps"] = None if maxrate is None or str(maxrate).lower() == "none" else parse_mbps(maxrate)
        for key, dest, default in (("queue_packets", "limit_packets", 1024), ("flow_limit", "flow_limit", 100)):
            value = getattr(args, key, None)
            if value is not None or mode == "tbf-fq":
                number = _positive(value, key, default)
                if not number.is_integer():
                    raise TuneError(key + " 必须为整数", 2)
                profile[dest] = int(number)
    _validate_profile(profile)
    return profile


def _unit_name(iface):
    # systemd-escape's instance escaping, without an extra runtime dependency.
    escaped = "".join(char if char.isascii() and (char.isalnum() or char in "_:.") else "\\x" + format(ord(char), "02x") for char in iface)
    if escaped.startswith("."):
        escaped = "\\x2e" + escaped[1:]
    return "vpsctl-network-tune-egress@" + escaped + ".service"


def _unit_content(iface):
    return (MARKER + "\n[Unit]\nDescription=vpsctl egress tuning " + iface +
            "\nWants=network-online.target\nAfter=network-online.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\n"
            "ExecStart=/usr/bin/python3 /usr/local/lib/vpsctl/network-tune/runtime.pyz internal egress-apply " + iface +
            "\n\n[Install]\nWantedBy=multi-user.target\n")


class EgressManager:
    def __init__(self, ctx):
        self.ctx = ctx
        self.state_path = ctx.state_dir / "egress.json"

    def _load(self):
        state = self.ctx.read_json(self.state_path, {"schema_version": 1, "interfaces": {}})
        if not isinstance(state, dict) or state.get("schema_version") != 1 or not isinstance(state.get("interfaces"), dict):
            raise TuneError("出口状态文件格式无效", 10)
        return state

    def _ready(self, iface):
        valid_interface(iface)
        self.ctx.require_mutation()
        self.ctx.require_tools("tc", "ip", "systemctl")
        self.ctx.run(["ip", "link", "show", "dev", iface])

    def _owned_unit(self, name):
        snapshot = self.ctx.unit_state(name)
        path = self.ctx.unit_path(name)
        if not snapshot.get("exists") and snapshot.get("load_state") not in (None, "", "not-found"):
            raise TuneError("同名出口服务来自受管路径以外：" + name, 10)
        if snapshot.get("exists") and MARKER not in path.read_text():
            raise TuneError("出口持久化单元已被外部接管：" + name, 10)
        return snapshot

    def _legacy_candidates(self):
        result = {}
        for name in LEGACY_UNITS:
            snapshot = self.ctx.unit_state(name)
            if snapshot.get("exists") and (snapshot.get("active") or snapshot.get("enabled")):
                result[name] = snapshot
        return result

    def _rollback(self, iface, tree, state_file, unit_name, unit, legacy, dropins, original_error):
        errors = []
        for name, snapshot in legacy.items():
            try:
                self.ctx.restore_unit(name, snapshot)
            except Exception as exc:
                errors.append(str(exc))
        for path, snapshot in dropins:
            try:
                self.ctx.restore_file(path, snapshot)
            except Exception as exc:
                errors.append(str(exc))
        for action in (lambda: self.ctx.restore_file(self.state_path, state_file),
                       lambda: self.ctx.restore_unit(unit_name, unit),
                       lambda: self.ctx.systemctl("daemon-reload"),
                       lambda: restore_snapshot(self.ctx, iface, tree)):
            try:
                action()
            except Exception as exc:
                errors.append(str(exc))
        if errors:
            raise TuneError("出口操作失败，回滚未完成：" + "; ".join(errors), 30) from original_error
        raise original_error

    def _install(self, iface, profile, state, original, legacy=None):
        ctx, name = self.ctx, _unit_name(iface)
        unit = self._owned_unit(name)
        before = capture_snapshot(ctx, iface)
        state_file = ctx.snapshot_file(self.state_path)
        legacy = legacy or {}
        dropins = []
        try:
            ctx.install_runtime()
            for old_name in legacy:
                path = ctx.path("/run/systemd/system/" + old_name + ".d/90-vpsctl-network-tune-adopt.conf")
                saved = ctx.snapshot_file(path)
                if saved.get("exists"):
                    raise TuneError("接管用临时 drop-in 已存在：" + str(path), 10)
                dropins.append((path, saved))
                ctx.atomic_write(path, "[Service]\nExecStop=\nExecStopPost=\n", 0o644)
            if legacy:
                ctx.systemctl("daemon-reload")
            for old_name in legacy:
                ctx.systemctl("stop", old_name)
                ctx.systemctl("disable", old_name)
            apply_profile(ctx, iface, profile)
            record = {"profile": profile, "original": original, "enabled": True}
            previous = state["interfaces"].get(iface, {})
            if previous.get("legacy_units") or legacy:
                record["legacy_units"] = previous.get("legacy_units", legacy)
            state["interfaces"][iface] = record
            ctx.write_json(self.state_path, state)
            ctx.write_unit(name, _unit_content(iface))
            ctx.systemctl("daemon-reload")
            # Do not start here: ExecStart takes the same locks and the profile
            # is already applied. The enabled unit reconciles on the next boot.
            ctx.systemctl("enable", name)
            for path, saved in dropins:
                ctx.restore_file(path, saved)
            if dropins:
                ctx.systemctl("daemon-reload")
        except BaseException as exc:
            self._rollback(iface, before, state_file, name, unit, legacy, dropins, exc)
        return {"changed": True, "interface": iface, "profile": profile, "service": name, "adopted": list(legacy)}

    def set(self, args):
        iface, profile = valid_interface(args.interface), _profile_from_args(args)
        self._ready(iface)
        state = self._load()
        previous = state["interfaces"].get(iface)
        snapshot = capture_snapshot(self.ctx, iface)
        legacy = self._legacy_candidates()
        if legacy:
            raise TuneError("检测到旧整形服务，请先使用 egress adopt：" + ", ".join(legacy), 10)
        unit = self._owned_unit(_unit_name(iface))
        unit_matches = unit.get("exists") and self.ctx.unit_path(_unit_name(iface)).read_text() == _unit_content(iface)
        if previous and previous.get("enabled") and previous.get("profile") == profile and unit.get("enabled") and unit_matches and profile_matches(self.ctx, iface, profile):
            return {"changed": False, "interface": iface, "profile": profile}
        self.ctx.confirm("应用 " + iface + " 出口队列 " + json.dumps(profile, ensure_ascii=False))
        if self.ctx.dry_run:
            return {"dry_run": True, "interface": iface, "profile": profile}
        return self._install(iface, profile, state, previous["original"] if previous else snapshot)

    def clear(self, args):
        return self._remove(args, restore=False)

    def restore(self, args):
        return self._remove(args, restore=True)

    def _remove(self, args, restore):
        iface = valid_interface(args.interface)
        self._ready(iface)
        state = self._load()
        record = state["interfaces"].get(iface)
        if record is None:
            raise TuneError("该网卡没有可恢复的受管出口状态", 10)
        if not restore and not record.get("enabled"):
            return {"changed": False, "interface": iface, "cleared": True}
        before = capture_snapshot(self.ctx, iface)
        name = _unit_name(iface)
        unit = self._owned_unit(name)
        state_file = self.ctx.snapshot_file(self.state_path)
        legacy = {old_name: self.ctx.unit_state(old_name) for old_name in record.get("legacy_units", {})}
        self.ctx.confirm(("恢复原始完整队列及旧服务：" if restore else "清除出口限制，恢复内核默认队列（保留恢复快照）：") + iface)
        if self.ctx.dry_run:
            return {"dry_run": True, "interface": iface, "restore": restore}
        try:
            if unit.get("exists"):
                self.ctx.systemctl("disable", name)
                self.ctx.systemctl("stop", name)
            if restore:
                for old_name, saved in record.get("legacy_units", {}).items():
                    self.ctx.restore_unit(old_name, saved)
                restore_snapshot(self.ctx, iface, record["original"])
                del state["interfaces"][iface]
                self.ctx.remove_file(self.ctx.unit_path(name))
                self.ctx.systemctl("daemon-reload")
            else:
                _reset_root(self.ctx, iface)
                record["enabled"] = False
            self.ctx.write_json(self.state_path, state)
        except BaseException as exc:
            self._rollback(iface, before, state_file, name, unit, legacy, [], exc)
        return {"changed": True, "interface": iface, "restored": restore, "cleared": not restore}

    def adopt(self, args):
        iface = valid_interface(args.interface)
        self._ready(iface)
        state = self._load()
        if iface in state["interfaces"]:
            raise TuneError("网卡已受管，不能重复接管旧服务", 10)
        requested = getattr(args, "service", None)
        if requested and not requested.endswith(".service"):
            requested += ".service"
        if requested and requested not in LEGACY_UNITS:
            raise TuneError("仅支持接管已知 network-tuning 服务", 2)
        candidates = self._legacy_candidates()
        if requested:
            candidates = {requested: candidates[requested]} if requested in candidates else {}
        if not candidates:
            raise TuneError("没有可接管的已知活动/启用服务", 10)
        profiles = []
        selected = {}
        for name, saved in candidates.items():
            content = self.ctx.systemctl("cat", name).stdout
            profile = _legacy_profile(content, iface)
            if profile is not None:
                profiles.append(profile)
                saved["unit_text"] = content
                selected[name] = saved
        if len(profiles) != 1:
            raise TuneError("无法唯一确定该网卡的旧整形服务", 10)
        profile = profiles[0]
        if not profile_matches(self.ctx, iface, profile):
            raise TuneError("旧服务命令与实际队列不一致，拒绝猜测接管参数", 10)
        original = capture_snapshot(self.ctx, iface)
        self.ctx.confirm("接管 " + ", ".join(selected) + "，保留当前出口参数及完整恢复快照")
        if self.ctx.dry_run:
            return {"dry_run": True, "interface": iface, "profile": profile, "adopted": list(selected)}
        return self._install(iface, profile, state, original, selected)

    def status(self, interface=None):
        state = self._load()
        names = [valid_interface(interface)] if interface else sorted(state["interfaces"])
        interfaces = {}
        for iface in names:
            record = state["interfaces"].get(iface)
            item = {"managed": record is not None, "record": record, "tree": read_tree(self.ctx, iface, stats=True)}
            if record:
                item["matches"] = profile_matches(self.ctx, iface, record["profile"]) if record.get("enabled") else None
                item["service"] = self.ctx.unit_state(_unit_name(iface))
            interfaces[iface] = item
        return {"interfaces": interfaces}

    def boot(self, interface):
        iface = valid_interface(interface)
        self._ready(iface)
        record = self._load()["interfaces"].get(iface)
        if not record or not record.get("enabled"):
            return {"changed": False, "interface": iface}
        before = capture_snapshot(self.ctx, iface)
        matches = profile_matches(self.ctx, iface, record["profile"])
        try:
            apply_profile(self.ctx, iface, record["profile"])
        except BaseException as exc:
            try:
                restore_snapshot(self.ctx, iface, before)
            except Exception as rollback:
                raise TuneError("开机应用失败且队列回滚失败：" + str(rollback), 30) from exc
            raise
        return {"changed": not matches, "interface": iface}


def _tc_rate(value):
    match = re.fullmatch(r"(\d+(?:\.\d+)?)([kmg]?)(?:bit|bps)", value.lower())
    if not match:
        raise TuneError("旧服务速率参数无法识别", 10)
    return int(float(match[1]) * {"": 1, "k": 1000, "m": 1_000_000, "g": 1_000_000_000}[match[2]])


def _legacy_profile(content, iface):
    starts = []
    for line in content.splitlines():
        if line.startswith("ExecStart="):
            value = line.partition("=")[2].strip()
            if not value:
                starts = []
            else:
                starts.append(shlex.split(value))
    if not starts or any(len(argv) < 9 or argv[0] not in ("/usr/sbin/tc", "/sbin/tc", "/usr/bin/tc") or argv[1:4] != ["qdisc", "replace", "dev"] for argv in starts):
        raise TuneError("旧服务不是受支持的直接 tc 命令", 10)
    if all(argv[4] != iface for argv in starts):
        return None
    if any(argv[4] != iface for argv in starts) or starts[0][5:7] != ["root", "handle"]:
        raise TuneError("旧服务修改多个网卡或使用未知拓扑", 10)
    root = starts[0]
    mode = root[8]
    if mode not in ("tbf", "fq"):
        raise TuneError("旧服务队列类型不受支持", 10)
    if len(root[9:]) % 2:
        raise TuneError("旧服务队列参数无法识别", 10)
    opts = dict(zip(root[9::2], root[10::2]))
    profile = {"mode": mode}
    if mode == "fq":
        if set(opts) - {"maxrate", "limit", "flow_limit", "orphan_mask"} or len(starts) != 1:
            raise TuneError("旧 fq 服务包含未知参数", 10)
        profile["maxrate_bps"] = _tc_rate(opts["maxrate"]) if "maxrate" in opts else None
    else:
        if set(opts) != {"rate", "burst", "latency"}:
            raise TuneError("旧 TBF 服务包含未知参数", 10)
        burst = re.fullmatch(r"(\d+)(kb|k|b)?", opts["burst"].lower())
        latency = re.fullmatch(r"(\d+(?:\.\d+)?)(ms|us|s)", opts["latency"].lower())
        if not burst or not latency:
            raise TuneError("旧 TBF burst/latency 无法识别", 10)
        profile.update(rate_bps=_tc_rate(opts["rate"]), burst_bytes=int(burst[1]) * (1024 if burst[2] in ("kb", "k") else 1),
                       latency_ms=float(latency[1]) * {"ms": 1, "us": 0.001, "s": 1000}[latency[2]])
        if len(starts) == 2:
            child = starts[1]
            if child[5:7] != ["parent", root[7] + "1"] or child[7] != "handle" or child[9] != "fq" or len(child[10:]) % 2:
                raise TuneError("旧 TBF 子队列无法识别", 10)
            opts = dict(zip(child[10::2], child[11::2]))
            if set(opts) - {"maxrate", "limit", "flow_limit", "orphan_mask"}:
                raise TuneError("旧 TBF+fq 子队列参数不受支持", 10)
            profile.update(mode="tbf-fq", maxrate_bps=_tc_rate(opts["maxrate"]) if "maxrate" in opts else None,
                           limit_packets=int(opts.get("limit", 10000)), flow_limit=int(opts.get("flow_limit", 100)))
        elif len(starts) != 1:
            raise TuneError("旧服务包含额外启动命令", 10)
    if profile["mode"] != "tbf":
        for key, dest in (("limit", "limit_packets"), ("flow_limit", "flow_limit"), ("orphan_mask", "orphan_mask")):
            if key in opts:
                profile[dest] = int(opts[key])
    _validate_profile(profile)
    return profile
