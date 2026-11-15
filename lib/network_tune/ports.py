"""Independent post-SNAT service-port shaping, with explicitly owned resources."""

import copy
import hashlib
import json
import math
import shlex

from .common import TuneError, parse_mbps, valid_id, valid_interface
from .egress import apply_profile, capture_snapshot, profile_matches, restore_snapshot


TABLE = "vpsctl_tune_ports"
OWNER = "vpsctl-network-tune:ports:v1"
UNIT = "vpsctl-network-tune-ports.service"
MASK = 0xffff0000
PREF_BASE = 49152
MAX_SLOT = 8191
_DYNAMIC = {"handle", "index", "stats", "stats2", "ref", "bind", "used",
            "lastuse", "firstused", "last_used", "first_used", "installed", "in_hw_count"}


def _normal(value, nft=False):
    if isinstance(value, dict):
        return {key: _normal(item, nft) for key, item in value.items()
                if key not in (_DYNAMIC if nft else _DYNAMIC - {"handle"})}
    if isinstance(value, list):
        return [_normal(item, nft) for item in value]
    return value


def _fingerprint(value, nft=False):
    return json.dumps(_normal(value, nft), sort_keys=True, separators=(",", ":"))


def _ifb(rule_id):
    return "vtt" + hashlib.sha256(rule_id.encode("utf-8")).hexdigest()[:10]


def _alias(rule_id):
    return OWNER + ":" + rule_id


def _positive(value, name, maximum=None):
    try:
        result = int(value)
        if isinstance(value, bool) or str(result) != str(value) or result <= 0:
            raise ValueError()
    except (ValueError, TypeError):
        raise TuneError(name + " 必须是正整数", 2)
    if maximum is not None and result > maximum:
        raise TuneError(name + " 超出范围", 2)
    return result


def _default(args, name, value):
    supplied = getattr(args, name, None)
    return value if supplied is None else supplied


def _positive_number(value, name):
    try:
        number = float(value)
        if isinstance(value, bool) or not math.isfinite(number) or number <= 0:
            raise ValueError()
        return number
    except (ValueError, TypeError):
        raise TuneError(name + " 必须是正数", 2)


def _rule(args, slot):
    rule_id = valid_id(args.id)
    interface = valid_interface(args.interface)
    protocol = getattr(args, "protocol", None) or "tcp"
    family = getattr(args, "family", None) or "both"
    if protocol not in ("tcp", "udp", "both") or family not in ("ipv4", "ipv6", "both"):
        raise TuneError("无效的协议或地址族", 2)
    port = _positive(args.port, "port", 65535)
    total = getattr(args, "total_mbps", None)
    flow = getattr(args, "flow_mbps", None)
    if total is None and flow is None:
        raise TuneError("至少指定 --total-mbps 或 --flow-mbps", 2)
    if flow is not None and protocol != "tcp":
        raise TuneError("每流限速仅支持 TCP；UDP/both 请使用共享总限速", 2)
    profile = {"mode": "tbf-fq" if total is not None and flow is not None else
               "tbf" if total is not None else "fq"}
    if total is not None:
        profile.update(rate_bps=parse_mbps(total),
                       burst_bytes=_positive(_default(args, "burst_kib", 64), "burst-kib") * 1024,
                       latency_ms=_positive_number(_default(args, "latency_ms", 50), "latency-ms"))
    if flow is not None:
        profile.update(maxrate_bps=parse_mbps(flow), orphan_mask=0xffffffff,
                       limit_packets=_positive(_default(args, "queue_packets", 1024), "queue-packets"),
                       flow_limit=_positive(_default(args, "flow_limit", 100), "flow-limit"))
    elif getattr(args, "queue_packets", None) is not None or getattr(args, "flow_limit", None) is not None:
        raise TuneError("queue-packets/flow-limit 需要 TCP 每流限速", 2)
    return {"id": rule_id, "interface": interface, "port": port, "protocol": protocol,
            "family": family, "profile": profile, "slot": slot, "ifb": _ifb(rule_id)}


def _keys(rule):
    protocols = ("tcp", "udp") if rule["protocol"] == "both" else (rule["protocol"],)
    families = ("ipv4", "ipv6") if rule["family"] == "both" else (rule["family"],)
    return {(rule["interface"], protocol, family, rule["port"])
            for protocol in protocols for family in families}


def _same_rule(a, b):
    return all(a.get(key) == b.get(key) for key in
               ("id", "interface", "port", "protocol", "family", "profile", "slot", "ifb"))


def _nft_script(rules, exists):
    lines = ["delete table inet " + TABLE] if exists else []
    if not rules:
        return "\n".join(lines) + "\n"
    lines += ["add table inet " + TABLE + " { comment " + json.dumps(OWNER) + "; }",
              "add chain inet " + TABLE + " postrouting { type filter hook postrouting priority 110; policy accept; }"]
    for rule_id, rule in sorted(rules.items()):
        for _, protocol, family, port in sorted(_keys(rule)):
            # The ct expression registers conntrack/defragmentation for both inet
            # families. It precedes the transport-header lookup, including for
            # forwarded IPv4/IPv6 fragments. Locally produced fragments inherit
            # the mark when fragmentation occurs after postrouting.
            lines.append("add rule inet " + TABLE + " postrouting "
                         "ct state { invalid, new, established, related, untracked } "
                         "oifname " + json.dumps(rule["interface"]) + " meta nfproto " + family +
                         " meta l4proto " + protocol + " " + protocol + " sport " + str(port) +
                         " meta mark set (meta mark & 0x0000ffff) | " + hex(rule["slot"] << 16) +
                         " comment " + json.dumps(OWNER + ":" + rule_id))
    return "\n".join(lines) + "\n"


def _contains_mark(value):
    if isinstance(value, dict):
        if value.get("meta", {}).get("key") == "mark":
            return True
        return any(_contains_mark(item) for item in value.values())
    return isinstance(value, list) and any(_contains_mark(item) for item in value)


def _int(value):
    try:
        return int(value, 0) if isinstance(value, str) else int(value)
    except (TypeError, ValueError):
        return None


def _preserves_high(value):
    """Recognize writes that provably leave every reserved bit unchanged."""
    if value == {"meta": {"key": "mark"}}:
        return True
    if not isinstance(value, dict) or len(value) != 1:
        return False
    op, operands = next(iter(value.items()))
    if op not in ("&", "|", "^") or not isinstance(operands, list) or len(operands) != 2:
        return False
    for expression, constant in (operands, operands[::-1]):
        number = _int(constant)
        if number is not None and _preserves_high(expression):
            return (number & MASK == MASK) if op == "&" else (number & MASK == 0)
    return False


def _low_mark_only(value):
    if not _contains_mark(value):
        return True
    if value == {"meta": {"key": "mark"}}:
        return False
    if isinstance(value, dict):
        if "&" in value:
            operands = value["&"]
            if isinstance(operands, list) and len(operands) == 2:
                for expression, constant in (operands, operands[::-1]):
                    number = _int(constant)
                    if number is not None and number & MASK == 0:
                        if expression == {"meta": {"key": "mark"}}:
                            return True
        return all(_low_mark_only(item) for item in value.values())
    if isinstance(value, list):
        return all(_low_mark_only(item) for item in value)
    return True


def _foreign_mark_conflict(value):
    if not _contains_mark(value):
        return False
    if value == {"meta": {"key": "mark"}}:
        return True
    if isinstance(value, dict) and "mangle" in value:
        assignment = value["mangle"]
        if assignment.get("key") == {"meta": {"key": "mark"}}:
            return not _preserves_high(assignment.get("value"))
    if isinstance(value, dict):
        return any(_foreign_mark_conflict(item) for item in value.values()) if not _low_mark_only(value) else False
    if isinstance(value, list):
        return any(_foreign_mark_conflict(item) for item in value)
    return False


def _legacy_mark_conflict(line):
    tokens = shlex.split(line)
    def argument(name, default=None):
        if name not in tokens:
            return default
        index = tokens.index(name) + 1
        return tokens[index] if index < len(tokens) else None
    packet_match = any(tokens[index:index + 2] == ["-m", "mark"] for index in range(len(tokens) - 1))
    if packet_match and "--mark" in tokens:
        value = argument("--mark")
        parts = value.split("/", 1) if value else []
        mask = _int(parts[1]) if len(parts) == 2 else 0xffffffff
        if mask is None or mask & MASK:
            return True
    target = argument("-j", argument("--jump"))
    if target == "CONNMARK":
        # Restore/save can exchange packet and connection marks. Only explicitly
        # low-bit masks prove the reserved packet bits remain independent.
        if "--restore-mark" in tokens or "--save-mark" in tokens:
            mask = _int(argument("--nfmask", argument("--mask", "0xffffffff")))
            if mask is None or mask & MASK:
                return True
            if "--restore-mark" in tokens:
                ctmask = _int(argument("--ctmask", argument("--mask", "0xffffffff")))
                if ctmask is None or ctmask & MASK:
                    return True
        return False
    if target == "MARK":
        recognized = False
        for flag in ("--set-xmark", "--set-mark", "--and-mark", "--or-mark", "--xor-mark"):
            value = argument(flag)
            if value is None:
                continue
            recognized = True
            parts = value.split("/", 1)
            number = _int(parts[0])
            if number is None:
                return True
            if flag in ("--set-xmark", "--set-mark"):
                mask = _int(parts[1]) if len(parts) == 2 else 0xffffffff
                if mask is None or (number | mask) & MASK:
                    return True
            elif flag == "--and-mark":
                if number & MASK != MASK:
                    return True
            elif number & MASK:
                return True
        if not recognized:
            return True
    return False


class PortManager:
    def __init__(self, ctx):
        self.ctx = ctx
        self.state_path = ctx.state_dir / "ports.json"

    def _load(self):
        state = self.ctx.read_json(self.state_path, {"schema_version": 1, "rules": {}, "clsact_owned": []})
        if not isinstance(state, dict) or state.get("schema_version") != 1 or not isinstance(state.get("rules"), dict):
            raise TuneError("端口限速状态格式无效")
        seen, slots, devices = set(), set(), set()
        for rule_id, record in state["rules"].items():
            try:
                if (valid_id(rule_id) != record["id"] or record["ifb"] != _ifb(rule_id) or
                        valid_interface(record["interface"]) != record["interface"] or
                        record["protocol"] not in ("tcp", "udp", "both") or
                        record["family"] not in ("ipv4", "ipv6", "both") or
                        not 1 <= record["port"] <= 65535 or not 1 <= record["slot"] <= MAX_SLOT or
                        record["slot"] in slots or record["ifb"] in devices or
                        record["profile"]["mode"] not in ("tbf", "tbf-fq", "fq")):
                    raise ValueError()
                expanded = _keys(record)
                if seen & expanded:
                    raise ValueError()
                seen |= expanded
                slots.add(record["slot"])
                devices.add(record["ifb"])
            except (KeyError, TypeError, ValueError, TuneError):
                raise TuneError("端口限速规则状态损坏：" + str(rule_id))
        return state

    def _json(self, argv):
        result = self.ctx.run(argv)
        try:
            return json.loads(result.stdout)
        except (ValueError, TypeError):
            raise TuneError("命令未返回有效 JSON：" + " ".join(argv), 20)

    def _link(self, name):
        links = self._json(["ip", "-j", "-d", "link", "show"])
        return next((link for link in links if link.get("ifname") == name), None)

    def _table(self, ruleset):
        entries = []
        table = None
        for item in ruleset.get("nftables", []):
            for kind, value in item.items():
                if not isinstance(value, dict):
                    continue
                own = value.get("family") == "inet" and (value.get("table") == TABLE or
                                                         kind == "table" and value.get("name") == TABLE)
                if own:
                    entries.append(item)
                    if kind == "table":
                        table = value
                elif _foreign_mark_conflict(value):
                    raise TuneError("已有 nft packet mark 使用，无法确认保留高 16 位空闲")
        if entries and (table is None or table.get("comment") != OWNER):
            raise TuneError("同名 nft 表不属于端口限速功能")
        return entries

    def _legacy_marks(self):
        for family, command in (("ip", "iptables-save"), ("ip6", "ip6tables-save")):
            path = self.ctx.path("/proc/net/" + family + "_tables_names")
            if not path.exists() or "mangle" not in path.read_text().split():
                continue
            self.ctx.require_tools(command)
            version = self.ctx.run([command, "--version"]).stdout
            if "nf_tables" in version:
                command = command.replace("-save", "-legacy-save")
                self.ctx.require_tools(command)
            output = self.ctx.run([command, "-t", "mangle"]).stdout
            if any(_legacy_mark_conflict(line) for line in output.splitlines() if line.startswith("-A ")):
                raise TuneError("已有 legacy " + command + " mark 规则，不能确认高 16 位空闲")

    def _filters(self, interface):
        chains = self._json(["tc", "-j", "chain", "show", "dev", interface, "egress"])
        if any(int(chain.get("chain", 0)) != 0 for chain in chains):
            raise TuneError(interface + " 存在外部 egress chain")
        return self._json(["tc", "-j", "filter", "show", "dev", interface, "egress"])

    def _preflight(self, state, desired, boot=False):
        self.ctx.require_tools("ip", "tc", "nft")
        unit = self.ctx.unit_path(UNIT)
        unit_state = self.ctx.unit_state(UNIT)
        if unit.exists():
            self.ctx.snapshot_file(unit)
            if OWNER not in unit.read_text():
                raise TuneError("同名启动服务不属于端口限速功能")
        elif unit_state.get("load_state", "not-found") != "not-found":
            raise TuneError("系统中已有其他位置提供的同名启动服务")
        ruleset = self._json(["nft", "-j", "list", "ruleset"])
        table = self._table(ruleset)
        self._legacy_marks()
        interfaces = {rule["interface"] for rule in list(state["rules"].values()) + list(desired.values())}
        for item in ruleset.get("nftables", []):
            flowtable = item.get("flowtable", {})
            devices = flowtable.get("dev", flowtable.get("devices", []))
            if isinstance(devices, str):
                devices = [devices]
            if interfaces.intersection(devices):
                raise TuneError("目标接口已有 nft flowtable，会绕过端口分类")
        for family in ("-4", "-6"):
            for policy in self._json(["ip", "-j", family, "rule", "show"]):
                output = policy.get("oif", policy.get("oifname"))
                if output and output not in interfaces:
                    continue
                if "fwmark" in policy:
                    value = policy["fwmark"]
                    inline_mask = value.split("/", 1)[1] if isinstance(value, str) and "/" in value else 0xffffffff
                    mask = _int(policy.get("fwmask", inline_mask))
                    if mask is None or mask & MASK:
                        raise TuneError("策略路由已经使用保留的 packet mark 高 16 位")
        if table:
            expected = state.get("nft_fingerprint")
            if not expected or expected != _fingerprint(table, nft=True):
                raise TuneError("端口限速 nft 表已发生外部修改")
        elif state["rules"] and not boot:
            raise TuneError("端口限速 nft 表丢失，请通过启动恢复后重试")
        live = {"table": table, "links": {}, "filters": {}, "clsact": {}, "unit": unit_state}
        for interface in sorted(interfaces):
            link = self._link(interface)
            if link is None:
                raise TuneError("接口不存在：" + interface, 3)
            live["links"][interface] = link
            queues = self._json(["tc", "-j", "qdisc", "show", "dev", interface])
            if any(queue.get("kind") == "ingress" for queue in queues):
                raise TuneError(interface + " 已有 ingress qdisc，不能替换为 clsact")
            live["clsact"][interface] = any(queue.get("kind") == "clsact" for queue in queues)
            filters = self._filters(interface) if live["clsact"][interface] else []
            expected = {PREF_BASE + rule["slot"]: rule for rule in state["rules"].values()
                        if rule["interface"] == interface}
            for item in filters:
                record = expected.get(item.get("pref"))
                if record is None or item.get("kind") != "fw":
                    raise TuneError(interface + " 存在外部 egress 分类器")
            for pref, record in expected.items():
                actual = [item for item in filters if item.get("pref") == pref]
                if actual and _fingerprint(actual) != record.get("filter_fingerprint"):
                    raise TuneError(interface + " 的端口分类器已发生外部修改")
                if not actual and not boot:
                    raise TuneError(interface + " 的端口分类器丢失")
            live["filters"][interface] = filters
        for rule_id, rule in {**state["rules"], **desired}.items():
            device = self._link(rule["ifb"])
            live["links"][rule["ifb"]] = device
            if device is None:
                if rule_id in state["rules"] and not boot:
                    raise TuneError("端口限速 IFB 丢失：" + rule["ifb"])
                continue
            if (device.get("ifalias") != _alias(rule_id) or
                    device.get("linkinfo", {}).get("info_kind") != "ifb"):
                raise TuneError("同名设备不属于端口限速功能：" + rule["ifb"])
            if rule_id not in state["rules"]:
                raise TuneError("发现没有已保存规则的同名 IFB：" + rule["ifb"])
            old = state["rules"][rule_id]
            if device.get("mtu") != live["links"][old["interface"]].get("mtu"):
                raise TuneError("IFB MTU 与物理接口不一致：" + rule["ifb"])
            if "UP" not in device.get("flags", []) and not boot:
                raise TuneError("端口限速 IFB 未启用：" + rule["ifb"])
            if not profile_matches(self.ctx, rule["ifb"], old["profile"]):
                raise TuneError("IFB 队列配置已发生外部修改：" + rule["ifb"])
            for direction in ("ingress", "egress"):
                filters = self._json(["tc", "-j", "filter", "show", "dev", rule["ifb"], direction])
                if filters:
                    raise TuneError("IFB 存在外部分类器：" + rule["ifb"])
            # Snapshot checks reject unowned root filters or unsupported children.
            capture_snapshot(self.ctx, rule["ifb"])
        return live

    def list(self):
        state = self._load()
        return {"feature": "ports", "rules": copy.deepcopy(state["rules"])}

    def status(self):
        state = self._load()
        result = {"feature": "ports", "rules": copy.deepcopy(state["rules"]),
                  "managed": bool(state["rules"]), "drift": []}
        if state["rules"]:
            try:
                self._preflight(state, state["rules"])
            except TuneError as error:
                result["drift"].append(str(error))
        return result

    def set(self, args):
        state = self._load()
        rule_id = valid_id(args.id)
        previous = state["rules"].get(rule_id)
        slots = {record["slot"] for record in state["rules"].values()}
        slot = previous["slot"] if previous else next((i for i in range(1, MAX_SLOT + 1) if i not in slots), None)
        if slot is None:
            raise TuneError("端口限速规则数量已达到上限")
        record = _rule(args, slot)
        for other_id, other in state["rules"].items():
            if other_id != rule_id and _keys(record) & _keys(other):
                raise TuneError("端口限速规则重叠：" + other_id)
        desired = copy.deepcopy(state["rules"])
        desired[rule_id] = record
        live = self._preflight(state, desired)
        if previous and _same_rule(previous, record):
            return {"feature": "ports", "changed": False, "rule": previous}
        if self.ctx.dry_run:
            return {"feature": "ports", "dry_run": True, "rule": record}
        caps = []
        for key, label in (("rate_bps", "总限速"), ("maxrate_bps", "每条 TCP 流限速")):
            rate = record["profile"].get(key)
            value = (f"{rate // 1_000_000}.{rate % 1_000_000:06d}".rstrip("0").rstrip(".") + " Mbps"
                     if rate is not None else "未设置")
            caps.append(label + "：" + value)
        protocol = {"tcp": "TCP", "udp": "UDP", "both": "TCP+UDP"}[record["protocol"]]
        family = {"ipv4": "IPv4", "ipv6": "IPv6", "both": "IPv4+IPv6"}[record["family"]]
        self.ctx.confirm("设置端口限速 " + rule_id + "，接口 " + record["interface"] + "，源端口 " + str(record["port"]) +
                         "，协议 " + protocol + "，地址族 " + family + "；" + "；".join(caps))
        return self._commit(state, desired, live)

    def delete(self, args):
        state = self._load()
        rule_id = valid_id(args.id)
        if rule_id not in state["rules"]:
            return {"feature": "ports", "changed": False, "deleted": rule_id}
        desired = copy.deepcopy(state["rules"])
        del desired[rule_id]
        live = self._preflight(state, desired)
        if self.ctx.dry_run:
            return {"feature": "ports", "dry_run": True, "deleted": rule_id}
        previous = state["rules"][rule_id]
        self.ctx.confirm("删除端口限速 " + rule_id + "，接口 " + previous["interface"] + "，源端口 " + str(previous["port"]))
        return self._commit(state, desired, live)

    def boot(self, interface=None):
        state = self._load()
        if not state["rules"]:
            return {"feature": "ports", "changed": False}
        if interface is not None:
            valid_interface(interface)
        live = self._preflight(state, state["rules"], boot=True)
        complete = bool(live["table"]) and all(live["links"].get(rule["ifb"]) and
                    any(item.get("pref") == PREF_BASE + rule["slot"] for item in live["filters"][rule["interface"]])
                    for rule in state["rules"].values())
        if complete:
            return {"feature": "ports", "changed": False}
        if self.ctx.dry_run:
            return {"feature": "ports", "dry_run": True}
        return self._commit(state, copy.deepcopy(state["rules"]), live, boot=True)

    def _add_filter(self, rule):
        self.ctx.mutate(["tc", "filter", "add", "dev", rule["interface"], "egress", "protocol", "all",
                         "pref", str(PREF_BASE + rule["slot"]), "handle", hex(rule["slot"] << 16) + "/0xffff0000",
                         "fw", "action", "skbedit", "mark", "0/0xffff0000", "pipe", "action", "mirred",
                         "egress", "redirect", "dev", rule["ifb"]])

    def _delete_filter(self, rule):
        self.ctx.mutate(["tc", "filter", "del", "dev", rule["interface"], "egress", "protocol", "all",
                         "pref", str(PREF_BASE + rule["slot"]), "handle", hex(rule["slot"] << 16) + "/0xffff0000", "fw"])

    def _write_table(self, rules, exists):
        if rules or exists:
            self.ctx.mutate(["nft", "-f", "-"], input=_nft_script(rules, exists))

    def _commit(self, old, desired, live, boot=False):
        self.ctx.require_mutation()
        saved_state = self.ctx.snapshot_file(self.state_path)
        saved_unit = live["unit"]
        if saved_unit["exists"]:
            path = self.ctx.unit_path(UNIT)
            if not path.is_file() or OWNER not in path.read_text():
                raise TuneError("同名启动服务不属于端口限速功能")
        before = {rule_id: capture_snapshot(self.ctx, rule["ifb"])
                  for rule_id, rule in old["rules"].items() if live["links"].get(rule["ifb"])}
        created_devices, created_clsact, added_filters, removed_filters, removed_devices = [], [], [], [], []
        table_changed = False
        owned_clsact = set(old.get("clsact_owned", []))
        try:
            for rule_id, rule in desired.items():
                interface, device = rule["interface"], rule["ifb"]
                mtu = live["links"][interface]["mtu"]
                if not live["links"].get(device):
                    self.ctx.mutate(["ip", "link", "add", "name", device, "type", "ifb"])
                    created_devices.append(device)
                    self.ctx.mutate(["ip", "link", "set", "dev", device, "alias", _alias(rule_id)])
                if not live["links"].get(device) or live["links"][device].get("mtu") != mtu:
                    self.ctx.mutate(["ip", "link", "set", "dev", device, "mtu", str(mtu)])
                if not live["links"].get(device) or "UP" not in live["links"][device].get("flags", []):
                    self.ctx.mutate(["ip", "link", "set", "dev", device, "up"])
                apply_profile(self.ctx, device, rule["profile"], handle="a200:")
                if not live["clsact"][interface]:
                    self.ctx.mutate(["tc", "qdisc", "add", "dev", interface, "clsact"])
                    live["clsact"][interface] = True
                    created_clsact.append(interface)
                    owned_clsact.add(interface)
            # Keep unchanged filters in place, including their counters.
            for rule_id, previous in old["rules"].items():
                replacement = desired.get(rule_id)
                if replacement is None or replacement["interface"] != previous["interface"]:
                    actual = live["filters"][previous["interface"]]
                    if any(item.get("pref") == PREF_BASE + previous["slot"] for item in actual):
                        self._delete_filter(previous)
                        removed_filters.append(previous)
            for rule_id, rule in desired.items():
                previous = old["rules"].get(rule_id)
                actual = live["filters"][rule["interface"]]
                present = previous and previous["interface"] == rule["interface"] and any(
                    item.get("pref") == PREF_BASE + rule["slot"] for item in actual)
                if not present:
                    self._add_filter(rule)
                    added_filters.append(rule)
                actual = self._filters(rule["interface"])
                matching = [item for item in actual if item.get("pref") == PREF_BASE + rule["slot"]]
                if not matching:
                    raise TuneError("新增端口分类器未生效", 20)
                rule["filter_fingerprint"] = _fingerprint(matching)
            if not live["table"] or not all(rule_id in old["rules"] and _same_rule(old["rules"][rule_id], rule)
                                              for rule_id, rule in desired.items()) or set(desired) != set(old["rules"]):
                self._write_table(desired, bool(live["table"]))
                table_changed = True
            for rule_id, previous in old["rules"].items():
                if rule_id not in desired and live["links"].get(previous["ifb"]):
                    self.ctx.mutate(["ip", "link", "del", "dev", previous["ifb"]])
                    removed_devices.append(previous)
            needed = {rule["interface"] for rule in desired.values()}
            for interface in sorted(owned_clsact - needed):
                # Never remove a clsact that gained foreign ingress/egress filters.
                ingress = self._json(["tc", "-j", "filter", "show", "dev", interface, "ingress"])
                egress = self._filters(interface)
                if not ingress and not egress:
                    self.ctx.mutate(["tc", "qdisc", "del", "dev", interface, "clsact"])
                owned_clsact.discard(interface)
            new = {"schema_version": 1, "rules": desired, "clsact_owned": sorted(owned_clsact)}
            table = self._table(self._json(["nft", "-j", "list", "ruleset"]))
            if bool(table) != bool(desired):
                raise TuneError("端口分类 nft 表未生效", 20)
            new["nft_fingerprint"] = _fingerprint(table, nft=True) if table else None
            self.ctx.write_json(self.state_path, new)
            if desired:
                self.ctx.install_runtime()
                self.ctx.write_unit(UNIT, "# " + OWNER + "\n[Unit]\nDescription=VPS service port shaping\n"
                                    "After=network-online.target\nWants=network-online.target\n\n[Service]\n"
                                    "Type=oneshot\nRemainAfterExit=yes\n"
                                    "ExecStart=/usr/bin/python3 /usr/local/lib/vpsctl/network-tune/runtime.pyz internal ports-apply\n\n"
                                    "[Install]\nWantedBy=multi-user.target\n")
                self.ctx.systemctl("enable", UNIT)
            elif saved_unit["exists"]:
                self.ctx.systemctl("disable", "--now", UNIT)
                self.ctx.remove_file(self.ctx.unit_path(UNIT))
                self.ctx.systemctl("daemon-reload")
            return {"feature": "ports", "changed": True, "rules": desired, "boot": boot}
        except BaseException as error:
            failures = []
            def undo(operation):
                try:
                    operation()
                except BaseException as failure:
                    failures.append(str(failure))
            for rule in reversed(added_filters):
                undo(lambda rule=rule: self._delete_filter(rule))
            for previous in removed_devices:
                undo(lambda previous=previous: self.ctx.mutate(["ip", "link", "add", "name", previous["ifb"], "type", "ifb"]))
                undo(lambda previous=previous: self.ctx.mutate(["ip", "link", "set", "dev", previous["ifb"], "alias", _alias(previous["id"])]))
                undo(lambda previous=previous: self.ctx.mutate(["ip", "link", "set", "dev", previous["ifb"], "mtu", str(live["links"][previous["ifb"]]["mtu"]), "up"]))
            for rule_id, snapshot in before.items():
                device = old["rules"][rule_id]["ifb"]
                link = live["links"][device]
                undo(lambda device=device, link=link: self.ctx.mutate(["ip", "link", "set", "dev", device,
                     "mtu", str(link["mtu"]), "up" if "UP" in link.get("flags", []) else "down"]))
                undo(lambda rule_id=rule_id, snapshot=snapshot: restore_snapshot(self.ctx, old["rules"][rule_id]["ifb"], snapshot))
            for previous in removed_filters:
                interface = previous["interface"]
                queues = None
                try:
                    queues = self._json(["tc", "-j", "qdisc", "show", "dev", interface])
                except BaseException as failure:
                    failures.append(str(failure))
                if queues is not None and not any(queue.get("kind") == "clsact" for queue in queues):
                    undo(lambda interface=interface: self.ctx.mutate(["tc", "qdisc", "add", "dev", interface, "clsact"]))
                undo(lambda previous=previous: self._add_filter(previous))
            if table_changed:
                undo(lambda: self._write_table(old["rules"] if live["table"] else {}, bool(desired)))
            for device in reversed(created_devices):
                undo(lambda device=device: self.ctx.mutate(["ip", "link", "del", "dev", device]))
            for interface in reversed(created_clsact):
                def remove_created_clsact(interface=interface):
                    ingress = self._json(["tc", "-j", "filter", "show", "dev", interface, "ingress"])
                    if ingress or self._filters(interface):
                        raise TuneError("回滚保留新增的外部 clsact 分类器：" + interface)
                    self.ctx.mutate(["tc", "qdisc", "del", "dev", interface, "clsact"])
                undo(remove_created_clsact)
            undo(lambda: self.ctx.restore_file(self.state_path, saved_state))
            undo(lambda: self.ctx.restore_unit(UNIT, saved_unit))
            if failures:
                raise TuneError("端口限速失败且回滚不完整：" + str(error) + "；" + "；".join(failures), 30) from error
            raise
