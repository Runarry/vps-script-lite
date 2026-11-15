"""TCP socket buffer estimates and targeted sysctl management."""

import base64
from decimal import Decimal, localcontext
from fnmatch import fnmatchcase
import os
import re

from .common import MANAGED_MARKER, MIB, SCHEMA_VERSION, TuneError, parse_mbps, parse_size, read_sysctl, set_sysctl


_INT_MAX = 2 ** 31 - 1
_DIRECTIONS = {
    "tx": ("net.ipv4.tcp_wmem", "net.core.wmem_max"),
    "rx": ("net.ipv4.tcp_rmem", "net.core.rmem_max"),
}
_TRIPLETS = {tcp for tcp, _ in _DIRECTIONS.values()}
_CORE_MAXIMA = {core for _, core in _DIRECTIONS.values()}
_SWITCH_MAXIMA = {
    "net.ipv4.tcp_sack": 1,
    "net.ipv4.tcp_timestamps": 2,
    "net.ipv4.tcp_window_scaling": 1,
    "net.ipv4.tcp_moderate_rcvbuf": 1,
    "net.ipv4.tcp_mtu_probing": 2,
}
_KEYS = _TRIPLETS | _CORE_MAXIMA | _SWITCH_MAXIMA.keys()
_FRAGMENT = "/etc/sysctl.d/99-vpsctl-network-tune.conf"
_FRAGMENT_NAME = _FRAGMENT.rsplit("/", 1)[-1]
_SOURCE_DIRS = ("/etc/sysctl.d", "/run/sysctl.d", "/usr/local/lib/sysctl.d", "/usr/lib/sysctl.d", "/lib/sysctl.d")
_KEY_SEPARATORS = str.maketrans("./", "/.")


def _integers(values):
    return " ".join(str(value) for value in values)


def _numeric_value(key, value):
    """Canonicalize a kernel value without enforcing a policy on its original values."""
    parts = value.split() if isinstance(value, str) else []
    count = 3 if key in _TRIPLETS else 1
    if len(parts) != count or any(not re.fullmatch(r"-?[0-9]{1,10}", part) for part in parts):
        raise ValueError(value)
    values = [int(part) for part in parts]
    if any(number < -_INT_MAX - 1 or number > _INT_MAX for number in values):
        raise ValueError(value)
    return _integers(values)


def _size(value):
    size = parse_size(value)
    if not 0 < size <= _INT_MAX:
        raise TuneError(f"缓冲区大小必须为 1 至 {_INT_MAX} 字节：{value}", 2)
    return size


def _triplet(value):
    if isinstance(value, (list, tuple)):
        parts = value
    elif "," in value:
        parts = [part.strip() for part in value.split(",")]
    else:
        parts = value.split()
    if len(parts) != 3:
        raise TuneError("TCP 缓冲区三元组需要依次提供最小值、默认值和最大值", 2)
    sizes = [_size(part) for part in parts]
    if not sizes[0] <= sizes[1] <= sizes[2]:
        raise TuneError("TCP 缓冲区三元组必须满足最小值 ≤ 默认值 ≤ 最大值", 2)
    return _integers(sizes)


def _manual_setting(key, value):
    if key in _TRIPLETS:
        return _triplet(value)
    if key in _CORE_MAXIMA:
        return str(_size(value))
    limit = _SWITCH_MAXIMA[key]
    if value not in {str(number) for number in range(limit + 1)}:
        raise TuneError(f"{key} 必须为 0 至 {limit} 的整数", 2)
    return value


def _fragment_content(values):
    return (f"# {MANAGED_MARKER} buffers.\n" + "".join(
        f"{key} = {value}\n" for key, value in sorted(values.items())
    )).encode("utf-8")


def _source_key(key):
    key = key.strip()
    dot = key.find(".")
    slash = key.find("/")
    if dot >= 0 and (slash == -1 or dot < slash):
        key = key.translate(_KEY_SEPARATORS)
    return "/".join(part for part in key.split("/") if part)


def _matches(pattern, key):
    if pattern == key:
        return True
    pattern_parts = pattern.split("/")
    key_parts = key.split("/")
    return len(pattern_parts) == len(key_parts) and all(
        fnmatchcase(part, pattern_part) for part, pattern_part in zip(key_parts, pattern_parts)
    )


def _effective_source(key, entries):
    path_key = key.replace(".", "/")
    patterns = {}
    for entry in entries:
        pattern = entry["pattern"]
        previous = patterns.get(pattern)
        if previous is not None and previous["value"] != entry["value"]:
            del patterns[pattern]
        patterns[pattern] = entry
    # systemd excludes literal assignments and explicit negative matches from globs.
    if path_key in patterns:
        return patterns[path_key]
    return next((entry for entry in reversed(patterns.values()) if entry["value"] is not None), None)


class BufferManager:
    def __init__(self, ctx):
        self.ctx = ctx
        self.config_file = ctx.path(_FRAGMENT)
        self.state_file = ctx.state_dir / "buffers.json"

    def _runtime_value(self, key):
        try:
            return _numeric_value(key, read_sysctl(self.ctx, key))
        except ValueError as error:
            raise TuneError(f"无法识别 {key} 的当前值：{error}") from error

    def _write_value(self, key, value):
        set_sysctl(self.ctx, key, value)
        observed = self._runtime_value(key)
        if observed != value:
            raise TuneError(f"{key} 写入后为 {observed}，预期为 {value}", 20)

    def _config_assignments(self, keys, *, proposed=None, without_owned=False, creating=False):
        files = {}
        for logical in _SOURCE_DIRS:
            try:
                for path in self.ctx.path(logical).iterdir():
                    if path.name.startswith(".") or path.suffix != ".conf" or path.name in files:
                        continue
                    if path == self.config_file and (without_owned or proposed is not None):
                        continue
                    if path.is_symlink() or path.is_file():
                        files[path.name] = (f"{logical}/{path.name}", path)
            except FileNotFoundError:
                continue
            except OSError as error:
                raise TuneError(f"无法读取 sysctl.d 目录 {logical}：{error}") from error
        if proposed is not None:
            shadowed = files.get(_FRAGMENT_NAME)
            if creating and shadowed and shadowed[1].is_file():
                raise TuneError(f"创建 {_FRAGMENT} 会遮蔽现有配置 {shadowed[0]}")
            files[_FRAGMENT_NAME] = (_FRAGMENT, None)

        normalized = {key: key.replace(".", "/") for key in keys}
        result = {key: [] for key in keys}
        for name in sorted(files, key=os.fsencode):
            logical, path = files[name]
            try:
                if path is None:
                    content = _fragment_content(proposed).decode("utf-8")
                elif path.is_file():
                    content = path.read_text(encoding="utf-8", errors="surrogateescape")
                else:
                    # A symlink to /dev/null masks a lower-priority file with the same name.
                    continue
            except OSError as error:
                raise TuneError(f"无法读取 sysctl 配置 {logical}：{error}") from error
            for number, line in enumerate(content.splitlines(), 1):
                line = line.strip()
                if not line or line.startswith(("#", ";")):
                    continue
                setting_key, equals, value = line.removeprefix("-").partition("=")
                if not equals and not line.startswith("-"):
                    continue
                pattern = _source_key(setting_key)
                for key, path_key in normalized.items():
                    if _matches(pattern, path_key):
                        result[key].append({"file": logical, "line": number, "pattern": pattern,
                                            "value": value.strip() if equals else None})
        return result

    def _existing(self, *, require_owned=True):
        state_snapshot = self.ctx.snapshot_file(self.state_file)
        config_snapshot = self.ctx.snapshot_file(self.config_file)
        state = self.ctx.read_json(self.state_file, default=None)
        if state_snapshot["exists"]:
            version = state.get("schema_version") if isinstance(state, dict) else None
            if type(version) is not int or version != SCHEMA_VERSION:
                raise TuneError("无法识别 TCP 缓冲区状态的版本")
            desired, original = state.get("desired"), state.get("original")
            if not isinstance(desired, dict) or not isinstance(original, dict) or not desired:
                raise TuneError("TCP 缓冲区状态缺少已管理的参数")
            if desired.keys() != original.keys() or not desired.keys() <= _KEYS:
                raise TuneError("TCP 缓冲区状态包含不匹配的参数")
            try:
                if any(_numeric_value(key, value) != value for values in (desired, original) for key, value in values.items()):
                    raise ValueError
            except ValueError as error:
                raise TuneError("TCP 缓冲区状态包含无效的参数值") from error
        else:
            state = None

        owned = bool(state and config_snapshot["exists"] and
                     base64.b64decode(config_snapshot["data"]) == _fragment_content(state["desired"]))
        if require_owned and config_snapshot["exists"] and not owned:
            raise TuneError(f"{_FRAGMENT} 已存在且内容与 TCP 缓冲区状态不匹配")
        return state, state_snapshot, config_snapshot, owned

    def estimate(self, args):
        rate_arguments = {direction: getattr(args, f"{direction}_mbps", None) for direction in _DIRECTIONS}
        rate_arguments = {direction: value for direction, value in rate_arguments.items() if value is not None}
        rtt_text = str(getattr(args, "rtt_ms", "")).strip()
        if not rate_arguments or not re.fullmatch(r"[0-9]+(?:\.[0-9]*)?|\.[0-9]+", rtt_text):
            raise TuneError("估算需要正数 --rtt-ms 和至少一个方向的速率", 2)
        rtt = Decimal(rtt_text)
        if rtt <= 0:
            raise TuneError("--rtt-ms 必须大于 0", 2)
        rates = {direction: parse_mbps(value) for direction, value in rate_arguments.items()}
        self.ctx.require_tools("sysctl")
        memory = self.ctx.memory_bytes()
        budget = memory // (16 * MIB) * MIB
        cap = min(budget, _INT_MAX // MIB * MIB)
        result = {"rtt_ms": rtt_text, "memory_bytes": memory, "budget_bytes": budget}
        for direction, bps in rates.items():
            tcp, core = _DIRECTIONS[direction]
            # Mbps × milliseconds × 125 is equivalent to bps × milliseconds × 0.000125.
            with localcontext() as decimal_context:
                decimal_context.prec = len(rtt.as_tuple().digits) + len(str(bps)) + 3
                bdp = rtt * bps * Decimal("0.000125")
            numerator, denominator = bdp.as_integer_ratio()
            mib_divisor = denominator * MIB
            need = max(4, 2 + (2 * numerator + mib_divisor - 1) // mib_divisor) * MIB
            current = [int(part) for part in self._runtime_value(tcp).split()]
            reason = None
            suggestion = None
            if not 0 <= current[0] <= current[1]:
                reason = "现有最小值和默认值无法组成有效的缓冲区三元组"
            elif cap == 0 or current[1] > cap:
                reason = "可用上限无法保留现有最小值和默认值"
            else:
                suggestion = current[:2] + [max(current[1], min(need, cap))]
                if suggestion[2] < need:
                    reason = "建议上限受内存预算或内核整数范围限制"
            result[direction] = {
                "rate_bps": bps, "bdp_bytes": format(bdp, "f"), "needed_max_bytes": need,
                "suggested_max_bytes": suggestion[2] if suggestion else None,
                "current_triplet": current, "suggested_triplet": suggestion, "reason": reason,
                "key": tcp, "core_key": core if getattr(args, "sync_core", False) else None,
            }
        result["message"] = "TCP 缓冲区估算"
        return result

    def _manual_values(self, args, sync):
        updates = {}
        before = {}

        def add(key, value):
            if key in updates:
                raise TuneError(f"重复设置 {key}", 2)
            updates[key] = value

        for setting in getattr(args, "settings", None) or []:
            key, equals, value = setting.partition("=")
            key = key.strip()
            if not equals or key not in _KEYS:
                raise TuneError(f"不支持的 TCP 缓冲区设置：{setting}", 2)
            add(key, _manual_setting(key, value.strip()))
        selected_max = False
        for direction, (tcp, core) in _DIRECTIONS.items():
            maximum = getattr(args, f"{direction}_max", None)
            triplet = getattr(args, f"{direction}_triplet", None)
            if maximum is not None and triplet is not None:
                raise TuneError(f"--{direction}-max 和 --{direction}-triplet 只能使用一个", 2)
            if maximum is not None:
                maximum = _size(maximum)
                current = before[tcp] = self._runtime_value(tcp)
                minimum, default, _ = (int(part) for part in current.split())
                if not 0 <= minimum <= default <= maximum:
                    raise TuneError(f"--{direction}-max 无法保留当前最小值和默认值 {minimum} {default}，可提供完整三元组", 2)
                add(tcp, _integers((minimum, default, maximum)))
                if sync:
                    add(core, str(maximum))
                selected_max = True
            if triplet is not None:
                add(tcp, _triplet(triplet))
        if sync and not selected_max:
            raise TuneError("--sync-core 需要指定 --tx-max、--rx-max 或 --recommended", 2)
        if not updates:
            raise TuneError("需要指定建议值、缓冲区上限、三元组或高级参数", 2)
        return updates, before

    def _verify_persistence(self, desired, selected, *, creating):
        sources = self._config_assignments(selected, proposed=desired, creating=creating)
        for key, entries in sources.items():
            effective = _effective_source(key, entries)
            if effective is None:
                raise TuneError(f"{_FRAGMENT} 缺少 {key} 的持久化值")
            try:
                if _numeric_value(key, effective["value"]) == desired[key]:
                    continue
            except ValueError:
                pass
            raise TuneError(f"{effective['file']}:{effective['line']} 的 {key} 会覆盖 {_FRAGMENT}")

    def _restore_values(self, original):
        configured = self._config_assignments(original, without_owned=True)
        values = {}
        sources = {}
        for key, value in original.items():
            effective = _effective_source(key, configured[key])
            if effective and effective["value"] is not None:
                try:
                    value = _numeric_value(key, effective["value"])
                except ValueError as error:
                    raise TuneError(f"无法还原 {effective['file']}:{effective['line']} 中的 {key}：值无效") from error
                sources[key] = effective["file"]
            else:
                sources[key] = None
            values[key] = value
        return values, sources

    def _apply(self, before, values, state, state_snapshot, config_snapshot):
        attempted = []
        touched = []
        try:
            for key in sorted(values):
                if before[key] != values[key]:
                    attempted.append(key)
                    self._write_value(key, values[key])
            if state is None:
                if config_snapshot["exists"]:
                    touched.append((self.config_file, config_snapshot))
                    self.ctx.remove_file(self.config_file)
                touched.append((self.state_file, state_snapshot))
                self.ctx.remove_file(self.state_file)
            else:
                content = _fragment_content(state["desired"])
                if not config_snapshot["exists"] or base64.b64decode(config_snapshot["data"]) != content:
                    touched.append((self.config_file, config_snapshot))
                    self.ctx.atomic_write(self.config_file, content, mode=0o644)
                if self.ctx.read_json(self.state_file, default=None) != state:
                    touched.append((self.state_file, state_snapshot))
                    self.ctx.write_json(self.state_file, state)
        except (Exception, KeyboardInterrupt) as error:
            failures = []
            for path, snapshot in reversed(touched):
                try:
                    self.ctx.restore_file(path, snapshot)
                except (Exception, KeyboardInterrupt) as rollback_error:
                    failures.append(f"{path}：{rollback_error}")
            for key in reversed(attempted):
                try:
                    try:
                        current = self._runtime_value(key)
                    except TuneError:
                        current = None
                    if current != before[key]:
                        self._write_value(key, before[key])
                except (Exception, KeyboardInterrupt) as rollback_error:
                    failures.append(f"{key}：{rollback_error}")
            if failures:
                raise TuneError(f"TCP 缓冲区操作失败且回滚不完整（{error}）：{'；'.join(failures)}", 30) from error
            raise

    def _confirm(self, action, before, values, state_snapshot, config_snapshot):
        self.ctx.require_mutation()
        changes = "\n".join(f"  {key} = {before[key]} → {value}" for key, value in sorted(values.items()))
        self.ctx.confirm(f"{action} TCP 缓冲区参数\n{changes}\n配置文件 {_FRAGMENT}")
        if (self.ctx.snapshot_file(self.state_file) != state_snapshot or
                self.ctx.snapshot_file(self.config_file) != config_snapshot or
                any(self._runtime_value(key) != value for key, value in before.items())):
            raise TuneError("TCP 缓冲区配置或当前值在确认期间改变，请重新运行")

    def set(self, args):
        sync = getattr(args, "sync_core", False)
        recommended = getattr(args, "recommended", False)
        manual_flags = (f"{direction}_{kind}" for direction in _DIRECTIONS for kind in ("max", "triplet"))
        manual = getattr(args, "settings", None) or any(getattr(args, flag, None) is not None for flag in manual_flags)
        estimate_flags = ("rtt_ms", "tx_mbps", "rx_mbps")
        if recommended and manual:
            raise TuneError("--recommended 和手动参数只能使用一种", 2)
        if not recommended and any(getattr(args, flag, None) is not None for flag in estimate_flags):
            raise TuneError("--rtt-ms、--tx-mbps 和 --rx-mbps 需要与 --recommended 一起使用", 2)
        estimate = None
        self.ctx.require_tools("sysctl")
        if recommended:
            estimate = self.estimate(args)
            updates, before = {}, {}
            for direction, (tcp, core) in _DIRECTIONS.items():
                plan = estimate.get(direction, {})
                if plan.get("suggested_triplet") is not None:
                    updates[tcp] = _integers(plan["suggested_triplet"])
                    before[tcp] = _integers(plan["current_triplet"])
                    if sync:
                        updates[core] = str(plan["suggested_max_bytes"])
        else:
            updates, before = self._manual_values(args, sync)
        result = {"changed": False, "would_change": False, "dry_run": self.ctx.dry_run, "values": updates}
        if estimate is not None:
            result["estimate"] = estimate
        if not updates:
            return {**result, "message": "所选方向没有可应用的 TCP 缓冲区建议"}

        old_state, state_snapshot, config_snapshot, owned = self._existing()
        desired = {**(old_state["desired"] if old_state else {}), **updates}
        original = dict(old_state["original"]) if old_state else {}
        for key in updates:
            if key not in before:
                before[key] = self._runtime_value(key)
            original.setdefault(key, before[key])
        state = {"schema_version": SCHEMA_VERSION, "desired": desired, "original": original}
        creating = not config_snapshot["exists"]
        self._verify_persistence(desired, updates, creating=creating)
        if owned and state == old_state and before == updates:
            return {**result, "message": "TCP 缓冲区参数已生效"}
        if self.ctx.dry_run:
            return {**result, "would_change": True, "message": "计划设置 TCP 缓冲区参数"}
        self._confirm("设置", before, updates, state_snapshot, config_snapshot)
        self._verify_persistence(desired, updates, creating=creating)
        self._apply(before, updates, state, state_snapshot, config_snapshot)
        return {**result, "changed": True, "message": "已设置 TCP 缓冲区参数"}

    def restore(self, args):
        state, state_snapshot, config_snapshot, _ = self._existing()
        result = {"changed": False, "would_change": False, "dry_run": self.ctx.dry_run, "values": {}}
        if state is None:
            return {**result, "message": "没有需要还原的 TCP 缓冲区参数"}
        self.ctx.require_tools("sysctl")
        values, sources = self._restore_values(state["original"])
        before = {key: self._runtime_value(key) for key in values}
        result.update(values=values, sources=sources)
        if self.ctx.dry_run:
            return {**result, "would_change": True, "message": "计划还原 TCP 缓冲区参数"}
        self._confirm("还原", before, values, state_snapshot, config_snapshot)
        if self._restore_values(state["original"]) != (values, sources):
            raise TuneError("外部 TCP 缓冲区配置在确认期间改变，请重新运行")
        self._apply(before, values, None, state_snapshot, config_snapshot)
        return {**result, "changed": True, "message": "已还原 TCP 缓冲区参数"}

    def status(self):
        self.ctx.require_tools("sysctl")
        state, _, config_snapshot, owned = self._existing(require_owned=False)
        desired = state["desired"] if state else {}
        drift = bool((state or config_snapshot["exists"]) and not owned)
        keys = {}
        for key, sources in sorted(self._config_assignments(_KEYS).items()):
            item = {"runtime": None, "desired": desired.get(key), "persistent": None, "sources": sources}
            try:
                item["runtime"] = self._runtime_value(key)
            except TuneError as error:
                item["error"] = str(error)
            effective = _effective_source(key, sources)
            if effective and effective["value"] is not None:
                item["source"] = effective["file"]
                try:
                    item["persistent"] = _numeric_value(key, effective["value"])
                except ValueError:
                    item["persistent"] = effective["value"]
                    item["persistent_error"] = "配置中的参数值无效"
            if key in desired and (item["runtime"] != desired[key] or item["persistent"] != desired[key]):
                drift = True
            keys[key] = item
        return {"managed": state is not None, "config_path": _FRAGMENT, "keys": keys, "drift": drift,
                "message": "TCP 缓冲区状态"}
