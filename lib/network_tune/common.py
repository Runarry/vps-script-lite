"""Shared standard-library runtime for local network tuning."""
from __future__ import annotations

import base64
import contextlib
import decimal
import fcntl
import hashlib
import importlib.resources
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile

SCHEMA_VERSION = 1
PACKAGE_FILES = (
    "__init__.py", "__main__.py", "common.py", "buffers.py",
    "egress.py", "ports.py", "cli.py",
)
MIB = 1024 * 1024
MANAGED_MARKER = "Managed by vpsctl network tune"
RUNTIME_MARKER = (MANAGED_MARKER + " runtime v1").encode("ascii")


class TuneError(Exception):
    def __init__(self, message, code=10):
        super().__init__(message)
        self.code = code


def truth(value):
    return str(value or "").lower() in ("1", "true", "yes", "on")


def parse_mbps(value):
    try:
        number = decimal.Decimal(str(value))
        if not number.is_finite() or number <= 0:
            raise ValueError
        if number < decimal.Decimal('0.000001') or number > decimal.Decimal(2**63 - 1).scaleb(-6):
            raise ValueError
        with decimal.localcontext() as precision:
            precision.prec = max(28, len(number.as_tuple().digits) + 12)
            result = number * 1_000_000
            if result != result.to_integral_value():
                raise ValueError
        return int(result)
    except (decimal.InvalidOperation, ValueError, TypeError):
        raise TuneError("带宽必须是正数 Mbps，精度不能小于 1 bit/s", 2)


def parse_size(value):
    if isinstance(value, int):
        if value < 0:
            raise TuneError("容量不能为负数", 2)
        return value
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*(B|KiB|MiB|GiB|K|M|G)?\s*",
                         str(value), re.IGNORECASE)
    if not match:
        raise TuneError("容量格式无效；使用字节整数或 KiB/MiB/GiB", 2)
    unit = (match.group(2) or "b").lower()
    power = {"b": 0, "k": 1, "kib": 1, "m": 2, "mib": 2, "g": 3, "gib": 3}[unit]
    coefficient = decimal.Decimal(match.group(1))
    with decimal.localcontext() as precision:
        precision.prec = max(28, len(coefficient.as_tuple().digits) + 12)
        number = coefficient * (1024 ** power)
        if number != number.to_integral_value() or number > 2**63 - 1:
            raise TuneError("容量必须能表示为完整字节且在支持范围内", 2)
    return int(number)


def valid_interface(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.:-]{0,14}", value):
        raise TuneError("网卡名称无效", 2)
    return value


def valid_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,47}", value):
        raise TuneError("规则 ID 只能包含字母、数字、点、短横线和下划线，最长 48 字符", 2)
    return value


def runtime_archive():
    """Deterministic executable zip, also embedded in the standalone PO0 file."""
    data = io.BytesIO()
    root_main = b"from network_tune.cli import main\nraise SystemExit(main())\n"
    with zipfile.ZipFile(data, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.comment = RUNTIME_MARKER
        members = {"__main__.py": root_main}
        package = importlib.resources.files("network_tune")
        for name in PACKAGE_FILES:
            members["network_tune/" + name] = package.joinpath(name).read_bytes()
        for name, content in sorted(members.items()):
            info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, content, compress_type=zipfile.ZIP_STORED)
    return data.getvalue()


class Context:
    def __init__(self, dry_run=None, assume_yes=None, non_interactive=None, json_output=False):
        self.testing = os.environ.get("VPSCTL_TESTING") == "1"
        root = os.environ.get("VPSCTL_SYSTEM_ROOT", "") if self.testing else ""
        if self.testing and root:
            candidate = Path(root)
            if not candidate.is_absolute() or ".." in candidate.parts or candidate == Path("/"):
                raise TuneError("测试系统根目录必须为明确的绝对隔离目录", 2)
            self.root = candidate
        else:
            self.root = Path("/")
        self.dry_run = truth(os.environ.get("VPSCTL_DRY_RUN")) if dry_run is None else dry_run
        self.assume_yes = truth(os.environ.get("VPSCTL_ASSUME_YES")) if assume_yes is None else assume_yes
        self.non_interactive = truth(os.environ.get("VPSCTL_NON_INTERACTIVE")) if non_interactive is None else non_interactive
        self.json_output = json_output
        self.quiet = truth(os.environ.get("VPSCTL_QUIET"))
        self.state_dir = self.path("/var/lib/vpsctl/network/tune")
        self.runtime_path = self.path("/usr/local/lib/vpsctl/network-tune/runtime.pyz")
        self.lock_wait_seconds = 0
        self._deferred_unit_starts = None

    def path(self, logical):
        value = Path(logical)
        if not value.is_absolute() or ".." in value.parts:
            raise TuneError("系统路径必须为不含上级跳转的绝对路径", 10)
        return self.root / str(value).lstrip("/") if self.root != Path("/") else value

    def safe_path(self, path):
        path = Path(path)
        if not path.is_absolute() or ".." in path.parts:
            raise TuneError("拒绝不安全的文件路径", 10)
        if self.root != Path("/") and path != self.root and self.root not in path.parents:
            raise TuneError("测试操作超出隔离系统目录", 10)
        for current in [path, *path.parents]:
            if current.is_symlink():
                raise TuneError("受管文件路径包含符号链接：" + str(current), 10)
        return path

    def run(self, argv, check=True, input=None, timeout=15):
        if not isinstance(argv, (tuple, list)) or not argv:
            raise TuneError("内部命令必须使用明确参数列表", 70)
        command = [str(x) for x in argv]
        try:
            result = subprocess.run(command, input=input, text=True, capture_output=True,
                                    timeout=timeout, env=os.environ.copy())
        except FileNotFoundError:
            raise TuneError("缺少命令：" + command[0], 3)
        except subprocess.TimeoutExpired:
            raise TuneError("命令超时：" + " ".join(command[:5]), 20)
        if check and result.returncode:
            detail = (result.stderr or result.stdout).strip()[:1800]
            raise TuneError("命令失败：" + " ".join(command[:6]) + (": " + detail if detail else ""), 20)
        return result

    def mutate(self, argv, **kwargs):
        if self.dry_run:
            raise TuneError("内部错误：演练中尝试执行写命令", 70)
        return self.run(argv, **kwargs)

    def read_json(self, path, default=None):
        path = self.safe_path(path)
        if not path.exists():
            return default
        if not path.is_file():
            raise TuneError("受管状态不是普通文件：" + str(path), 10)
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except PermissionError:
            raise TuneError("无权读取受管状态：" + str(path), 4)
        except (ValueError, OSError) as error:
            raise TuneError("无法读取受管状态：" + str(path) + ": " + str(error), 10)

    def atomic_write(self, path, content, mode=0o600):
        if self.dry_run:
            raise TuneError("内部错误：演练中尝试写文件", 70)
        path = self.safe_path(path)
        if path.exists() and not path.is_file():
            raise TuneError("受管目标不是普通文件：" + str(path), 10)
        raw = content.encode("utf-8") if isinstance(content, str) else content
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, name = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "wb") as output:
                os.fchmod(output.fileno(), mode)
                output.write(raw)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            if temporary.exists():
                temporary.unlink()

    def write_json(self, path, data, mode=0o600):
        self.atomic_write(path, json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n", mode)

    def remove_file(self, path):
        if self.dry_run:
            raise TuneError("内部错误：演练中尝试删除文件", 70)
        path = self.safe_path(path)
        if path.exists():
            if not path.is_file():
                raise TuneError("拒绝删除非普通受管文件：" + str(path), 10)
            path.unlink()

    def snapshot_file(self, path):
        path = self.safe_path(path)
        if not path.exists():
            return {"exists": False}
        if not path.is_file():
            raise TuneError("不能保存非普通文件：" + str(path), 10)
        return {"exists": True, "data": base64.b64encode(path.read_bytes()).decode("ascii"),
                "mode": stat.S_IMODE(path.stat().st_mode)}

    def restore_file(self, path, snapshot):
        if not isinstance(snapshot, dict) or not isinstance(snapshot.get("exists"), bool):
            raise TuneError("文件恢复记录无效", 10)
        if snapshot["exists"]:
            try:
                raw = base64.b64decode(snapshot["data"], validate=True)
                mode = int(snapshot["mode"])
                if mode < 0 or mode > 0o777:
                    raise ValueError("mode")
            except (KeyError, ValueError, TypeError):
                raise TuneError("文件恢复记录损坏", 10)
            self.atomic_write(path, raw, mode)
        else:
            self.remove_file(path)

    def confirm(self, summary):
        if self.dry_run:
            return
        if not self.quiet:
            print(summary, file=sys.stderr)
        if self.assume_yes:
            return
        if self.non_interactive or not sys.stdin.isatty():
            raise TuneError("非交互写操作需要 --yes；可先使用 --dry-run 查看计划", 2)
        try:
            answer = input("确认应用以上变更？[y/N] ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            raise TuneError("操作已取消", 130)
        if answer not in ("y", "yes"):
            raise TuneError("操作已取消", 130)

    def require_mutation(self):
        if not sys.platform.startswith("linux"):
            raise TuneError("网络调优写操作仅支持 Linux/systemd", 3)
        if not self.testing and not self.dry_run and os.geteuid() != 0:
            raise TuneError("网络调优写操作需要 root 权限", 4)
        if not self.path("/run/systemd/system").is_dir():
            raise TuneError("网络调优写操作需要 systemd；其他 Linux 仅提供只读查询", 3)

    def require_tools(self, *names):
        missing = [name for name in names if shutil.which(name) is None]
        if missing:
            raise TuneError("缺少工具：" + "、".join(missing) + "；请使用 --install-deps 安装所需依赖", 3)

    @contextlib.contextmanager
    def lock(self, name):
        if self.dry_run:
            yield
            return
        if not re.fullmatch(r"[a-z0-9-]+", name):
            raise TuneError("锁名称无效", 70)
        target = self.safe_path(self.path("/run/vpsctl/" + name + ".lock"))
        target.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(target, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            deadline = time.monotonic() + self.lock_wait_seconds
            while True:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TuneError("另一个操作正在使用此配置，请稍后重试：" + name, 10)
                    time.sleep(0.1)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def install_runtime(self):
        data = runtime_archive()
        target = self.safe_path(self.runtime_path)
        if target.exists():
            if target.read_bytes() == data:
                return "/usr/local/lib/vpsctl/network-tune/runtime.pyz"
            try:
                with zipfile.ZipFile(target) as archive:
                    owned = archive.comment == RUNTIME_MARKER
            except (OSError, zipfile.BadZipFile):
                owned = False
            if not owned:
                raise TuneError("同名运行时文件不属于网络调优模块：" + str(target), 10)
        self.atomic_write(target, data, 0o644)
        return "/usr/local/lib/vpsctl/network-tune/runtime.pyz"

    @contextlib.contextmanager
    def runtime_transaction(self):
        if self.dry_run:
            yield
            return
        saved = self.snapshot_file(self.runtime_path)
        try:
            yield
        except BaseException as error:
            try:
                if self.snapshot_file(self.runtime_path) != saved:
                    self.restore_file(self.runtime_path, saved)
            except BaseException as failure:
                raise TuneError("操作失败且共享运行时恢复失败：" + str(failure), 30) from error
            raise

    @contextlib.contextmanager
    def unit_restore_scope(self):
        """Restart our restored units after the caller releases its shared locks."""
        previous = self._deferred_unit_starts
        self._deferred_unit_starts = set()
        failure = None
        try:
            yield
        except BaseException as error:
            failure = error
            raise
        finally:
            starts = self._deferred_unit_starts
            self._deferred_unit_starts = previous
            errors = []
            for name in sorted(starts):
                try:
                    self.run(["systemctl", "start", name], timeout=90)
                except BaseException as error:
                    errors.append(str(error))
            if errors:
                raise TuneError("恢复服务启动失败：" + "; ".join(errors), 30) from failure

    def unit_path(self, name):
        if not re.fullmatch(r"[A-Za-z0-9_.@:\\-]+\.service", name):
            raise TuneError("服务名称无效", 10)
        return self.path("/etc/systemd/system/" + name)

    def systemctl(self, *args, check=True):
        return self.run(["systemctl", *args], check=check, timeout=30)

    def unit_state(self, name):
        file = self.snapshot_file(self.unit_path(name))
        result = self.systemctl("show", name, "-p", "LoadState", "-p", "ActiveState",
                                "-p", "UnitFileState", check=False)
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        return {"exists": file["exists"], "file": file,
                "active": values.get("ActiveState") == "active",
                "enabled": values.get("UnitFileState") in ("enabled", "enabled-runtime"),
                "load_state": values.get("LoadState", "not-found"),
                "active_state": values.get("ActiveState", "inactive"),
                "unit_file_state": values.get("UnitFileState", "")}

    def write_unit(self, name, content):
        self.atomic_write(self.unit_path(name), content, 0o644)
        self.systemctl("daemon-reload")

    def restore_unit(self, name, snapshot):
        current = self.unit_state(name)
        if current["active"] and not snapshot.get("active"):
            self.systemctl("stop", name)
        if current["enabled"]:
            self.systemctl("disable", name)
        self.restore_file(self.unit_path(name), snapshot["file"])
        self.systemctl("daemon-reload")
        if snapshot.get("enabled"):
            self.systemctl("enable", name)
        if snapshot.get("active"):
            if name.startswith("vpsctl-network-tune-") and self._deferred_unit_starts is not None:
                self._deferred_unit_starts.add(name)
            else:
                self.systemctl("start", name)

    def memory_bytes(self):
        try:
            contents = self.path("/proc/meminfo").read_text()
            value = re.search(r"^MemTotal:\s+(\d+)\s+kB", contents, re.MULTILINE)
            if value:
                return int(value.group(1)) * 1024
        except OSError:
            pass
        raise TuneError("无法读取物理内存，不能生成受预算约束的缓存建议", 3)


def read_sysctl(ctx, key):
    if not re.fullmatch(r"[a-zA-Z0-9_.]+", key):
        raise TuneError("内核参数名称无效", 2)
    return ctx.run(["sysctl", "-n", key]).stdout.strip()


def set_sysctl(ctx, key, value):
    if not re.fullmatch(r"[a-zA-Z0-9_.]+", key) or "\n" in str(value) or "\r" in str(value):
        raise TuneError("内核参数格式无效", 2)
    ctx.mutate(["sysctl", "-w", key + "=" + str(value)])


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()
