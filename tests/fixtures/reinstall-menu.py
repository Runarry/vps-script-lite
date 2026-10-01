#!/usr/bin/env python3
"""Exercise the real menu in a PTY, using only isolated shell-suite mocks."""

import codecs
import errno
import os
from pathlib import Path
import pty
import re
import select
import signal
import subprocess
import sys
import termios
import time


ENTRY = sys.argv[1]
TEMP = Path(sys.argv[2])
COUNT = 0
PROMPT = r"请选择[^\r\n]*> "


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class Menu:
    def __init__(self, name, args=("menu",), seed=False, **overrides):
        global COUNT
        COUNT += 1
        self.name = name
        self.root = TEMP / f"menu-{COUNT}"
        (self.root / "proc/self").mkdir(parents=True)
        (self.root / "boot/grub").mkdir(parents=True)
        (self.root / "proc/self/mountinfo").write_text("")
        (self.root / "proc/cmdline").write_text("")
        self.env = dict(os.environ, VPSCTL_SYSTEM_ROOT=str(self.root),
                        VPSCTL_NON_INTERACTIVE="0", MOCK_SLEEP="0", MOCK_EXIT="0",
                        MOCK_READ_STDIN="0", MOCK_RESET_EXIT="0", MOCK_REBOOT_EXIT="0")
        self.env.update({key: str(value) for key, value in overrides.items()})
        if seed:
            state = self.root / "var/lib/vpsctl/reinstall"
            state.mkdir(parents=True)
            (state / "reinstall.sh").write_bytes(Path(self.env["MOCK_UPSTREAM"]).read_bytes())
            (self.root / "reinstall-tmp").mkdir()
            (self.root / "reinstall-tmp/image").write_text("keep\n")
            (self.root / "reinstall-vmlinuz").write_text("kernel\n")
            (self.root / "reinstall.log").write_text("log\n")
            (self.root / "boot/grub/custom.cfg").write_text(
                "### BEGIN reinstall.sh ###\nmenuentry reinstall {}\n### END reinstall.sh ###\n")
        self.output = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.cursor = 0
        self.status = None
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe("bash", ["bash", ENTRY, *args], self.env)

    def __enter__(self):
        return self

    def __exit__(self, exception_type, exception, traceback):
        if self.status is None:
            try:
                os.killpg(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(self.pid, 0)
        os.close(self.fd)
        # Transcript never records sent inputs separately; hidden passwords stay hidden.
        (self.root / "transcript.txt").write_text(self.output)
        if exception is not None:
            print(f"FAIL: {self.name}; evidence: {self.root}", file=sys.stderr)

    def poll(self, timeout=0.05):
        if select.select([self.fd], [], [], timeout)[0]:
            try:
                data = os.read(self.fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
            else:
                self.output += self.decoder.decode(data)
        if self.status is None:
            child, result = os.waitpid(self.pid, os.WNOHANG)
            if child:
                self.status = os.waitstatus_to_exitcode(result)

    def expect(self, pattern):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            match = re.search(pattern, self.output[self.cursor:])
            if match:
                self.cursor += match.end()
                return
            self.poll()
            require(self.status is None, f"{self.name}: exited {self.status} before prompt {pattern!r}")
        raise AssertionError(f"{self.name}: timeout awaiting {pattern!r}; tail {self.output[-1500:]!r}")

    def send(self, text):
        os.write(self.fd, text.encode())

    def choice(self, value=""):
        self.expect(PROMPT)
        self.send(value + "\n")

    def value(self, label, value=""):
        self.expect(label + r"[^\r\n]*[：:]\s*")
        self.send(value + "\n")

    def password(self, value, repeat=False):
        self.expect(("再次输入密码" if repeat else "输入密码") + r"[^\r\n]*[：:]\s*")
        deadline = time.monotonic() + 1
        while termios.tcgetattr(self.fd)[3] & termios.ECHO:
            require(time.monotonic() < deadline, f"{self.name}: password terminal echo remains enabled")
            time.sleep(0.01)
        self.send(value + "\n")

    def confirm(self, answer="y"):
        self.expect(r"确认准备重装[^\r\n]*\[是/否，输入 y 确认\] ")
        self.send(answer + "\n")

    def post(self, answer=""):
        self.choice(answer)
        self.choice("q")

    def finish(self, expected=0):
        deadline = time.monotonic() + 8
        while self.status is None and time.monotonic() < deadline:
            self.poll()
        require(self.status == expected, f"{self.name}: expected exit {expected}, got {self.status}")
        # Drain the last output after the child exits.
        self.poll(0)

    def args(self):
        return [item.decode() for item in (self.root / "args").read_bytes().split(b"\0")[:-1]]

    def event_lines(self):
        path = self.root / "events"
        return path.read_text().splitlines() if path.exists() else []

    def no_mutation(self):
        for name in ("events", "args", "var", "run"):
            require(not (self.root / name).exists(), f"{self.name}: unexpected write {name}")

    def preserved(self):
        for name in ("reinstall-tmp/image", "reinstall-vmlinuz", "reinstall.log",
                     "boot/grub/custom.cfg", "var/lib/vpsctl/reinstall/reinstall.sh"):
            require((self.root / name).exists(), f"{self.name}: lost recovery resource {name}")


def linux(menu, target="1", version="", user="", auth="", port=""):
    menu.choice(target)
    menu.choice(version)
    menu.value("用户名", user)
    menu.choice(auth)
    if auth != "2" and auth != "3":
        menu.value("SSH.*端口", port)


def windows(menu, target="6", version="", edition="", lang="", user="", auth="", port=""):
    menu.choice(target)
    menu.choice(version)
    if target == "7":
        menu.choice(edition)
    menu.choice(lang)
    menu.value("用户名", user)
    menu.choice(auth)
    if auth != "2":
        menu.value("RDP.*端口", port)


def argument_contract(menu, positionals, expected, random_password=True):
    argv = menu.args()
    require(argv[:len(positionals)] == positionals,
            f"{menu.name}: expected positionals {positionals!r}, actual {argv!r}")
    flags = argv[len(positionals):]
    require(len(flags) % 2 == 0, f"{menu.name}: flags must contain key/value pairs: {flags!r}")
    options = dict(zip(flags[::2], flags[1::2]))
    require(len(options) * 2 == len(flags), f"{menu.name}: duplicated flags {flags!r}")
    if random_password:
        password = options.pop("--password", "")
        require(len(password) >= 12 and all(re.search(pattern, password)
                                          for pattern in ("[a-z]", "[A-Z]", "[0-9]", "[^a-zA-Z0-9]")),
                f"{menu.name}: random password does not satisfy platform character classes")
        require(password not in menu.output, f"{menu.name}: random password leaked in terminal")
    require(options == expected, f"{menu.name}: expected options {expected!r}, actual {options!r}")
    require((menu.root / "tty").exists(), f"{menu.name}: upstream lost its terminal")


def check_presets():
    families = [("1", "debian", ["13", "12", None]),
                ("2", "ubuntu", ["24.04", "22.04", "26.04", None]),
                ("3", "alpine", ["3.24", "3.23", None]),
                ("4", "rocky", ["9", "10", "8", None]),
                ("5", "almalinux", ["9", "10", "8", None])]
    for target, family, versions in families:
        for index, version in enumerate(versions, 1):
            with Menu(f"{family}-{version or 'latest'}") as menu:
                linux(menu, target, "" if index == 1 else str(index))
                menu.confirm()
                menu.post("")
                menu.finish()
                argument_contract(menu, [family] + ([version] if version else []),
                                  {"--username": "root", "--ssh-port": "22"})
                require(menu.event_lines() == ["download", f"upstream:{family}"],
                        f"{menu.name}: unexpected later-reboot side effects")
    images = ["Windows 11 Enterprise LTSC 2024", "Windows 11 Pro",
              "Windows 10 Enterprise LTSC 2021", "Windows 10 Pro"]
    for index, image in enumerate(images, 1):
        with Menu(f"windows-client-{index}") as menu:
            windows(menu, version="" if index == 1 else str(index), lang="2" if index == 2 else "")
            menu.confirm()
            menu.post("2")
            menu.finish()
            argument_contract(menu, ["windows"], {"--image-name": image,
                              "--lang": "en-us" if index == 2 else "zh-cn",
                              "--username": "administrator", "--rdp-port": "3389"})
    for index, year in enumerate(("2022", "2025", "2019"), 1):
        for edition, name in (("", "ServerStandard"), ("2", "ServerDatacenter")):
            with Menu(f"windows-server-{year}-{name}") as menu:
                windows(menu, "7", "" if index == 1 else str(index), edition)
                menu.confirm()
                menu.post("q")
                menu.finish()
                argument_contract(menu, ["windows"], {"--image-name": f"Windows Server {year} {name}",
                                  "--lang": "zh-cn", "--username": "administrator", "--rdp-port": "3389"})
    with Menu("raw-exact-url") as menu:
        url = "https://example.test/image.raw?token=a%20b&part=1#fragment"
        menu.choice("8")
        menu.value("RAW.*URL", url)
        menu.value("用户名")
        menu.choice()
        menu.value("SSH.*端口")
        menu.confirm()
        menu.post()
        menu.finish()
        argument_contract(menu, ["dd"], {"--img": url, "--username": "root", "--ssh-port": "22"})
        require("安装环境" in menu.output, "RAW did not explain installation-only credentials")


def check_credentials():
    secret = "space \"quote' $money `literal` \\back!"
    with Menu("hidden-password-retry") as menu:
        linux(menu, user="operator", auth="2")
        menu.password("")
        menu.password(secret)
        menu.password("mismatch", repeat=True)
        menu.password(secret)
        menu.password(secret, repeat=True)
        menu.value("SSH.*端口", "0")
        menu.value("SSH.*端口", "65536")
        menu.value("SSH.*端口", "2202")
        menu.confirm()
        menu.post()
        menu.finish()
        argument_contract(menu, ["debian", "13"], {"--username": "operator", "--ssh-port": "2202",
                          "--password": secret}, random_password=False)
        require(secret not in menu.output and "mismatch" not in menu.output, "password echoed to terminal")
    with Menu("windows-hidden-password") as menu:
        windows(menu, user="admin", auth="2")
        menu.password(secret)
        menu.password(secret, repeat=True)
        menu.value("RDP.*端口", "3390")
        menu.confirm()
        menu.post()
        menu.finish()
        argument_contract(menu, ["windows"], {"--image-name": "Windows 11 Enterprise LTSC 2024",
                          "--lang": "zh-cn", "--username": "admin", "--rdp-port": "3390",
                          "--password": secret}, random_password=False)
        require(secret not in menu.output, "Windows password echoed to terminal")
    public_file = TEMP / "test public key.pub"
    public_file.write_text("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest fixture@example\n")
    for key in ("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest fixture@example",
                str(public_file), "https://example.test/keys?a=1&b=2", "gh:fixture"):
        with Menu("ssh-key-exact-value") as menu:
            linux(menu, auth="3")
            menu.value("SSH 公钥", key)
            menu.value("SSH.*端口")
            menu.confirm()
            menu.post()
            menu.finish()
            argument_contract(menu, ["debian", "13"], {"--username": "root", "--ssh-port": "22",
                              "--ssh-key": key}, random_password=False)
    private_file = TEMP / "private-key"
    private_file.write_text("-----BEGIN OPENSSH PRIVATE KEY-----\nprivate-secret-marker\n")
    with Menu("reject-private-key-path") as menu:
        linux(menu, auth="3")
        menu.value("SSH 公钥", str(private_file))
        menu.expect("所选文件包含私钥")
        menu.no_mutation()
        menu.value("SSH 公钥", str(public_file))
        menu.value("SSH.*端口")
        menu.confirm()
        menu.post()
        menu.finish()
        argument_contract(menu, ["debian", "13"], {"--username": "root", "--ssh-port": "22",
                          "--ssh-key": str(public_file)}, random_password=False)
        require("private-secret-marker" not in menu.output, "private-key contents leaked to terminal")


def check_cancellation():
    with Menu("no-args-terminal", args=()) as menu:
        menu.choice("q")
        menu.finish()
        menu.no_mutation()
    with Menu("zero-exits") as menu:
        menu.choice("0")
        menu.finish()
        menu.no_mutation()
    with Menu("invalid-main-version-and-cancel") as menu:
        menu.choice("99")
        menu.choice("oops")
        menu.choice("1")
        menu.choice("99")
        menu.choice("q")
        menu.choice("q")
        menu.finish()
        menu.no_mutation()
    for cancel_stage in ("username", "auth", "password", "port", "confirm"):
        with Menu(f"cancel-{cancel_stage}") as menu:
            menu.choice("1")
            menu.choice()
            menu.value("用户名", "q" if cancel_stage == "username" else "")
            if cancel_stage != "username":
                menu.choice("q" if cancel_stage == "auth" else "2" if cancel_stage == "password" else "")
            if cancel_stage == "password":
                menu.password("q")
            elif cancel_stage in ("port", "confirm"):
                menu.value("SSH.*端口", "q" if cancel_stage == "port" else "")
            if cancel_stage == "confirm":
                menu.confirm("q")
            menu.choice("q")
            menu.finish()
            menu.no_mutation()
    with Menu("default-no-even-with-yes", args=("--yes", "menu")) as menu:
        linux(menu)
        menu.confirm("")
        menu.choice("q")
        menu.finish()
        menu.no_mutation()
    with Menu("raw-invalid-url") as menu:
        menu.choice("8")
        for url in ("ftp://example.test/image", "https://", "file:///image"):
            menu.value("RAW.*URL", url)
        menu.value("RAW.*URL", "q")
        menu.choice("q")
        menu.finish()
        menu.no_mutation()
    with Menu("dry-run-terminal", args=("--dry-run", "menu")) as menu:
        menu.finish(2)
        menu.no_mutation()
    with Menu("read-only-status-help") as menu:
        menu.choice("9")
        menu.choice("12")
        menu.choice("q")
        menu.finish()
        menu.no_mutation()


def check_post_menu():
    with Menu("main-reset-offline", seed=True, MOCK_DOWNLOAD="fail") as menu:
        menu.choice("10")
        menu.choice("q")
        menu.finish()
        require(menu.event_lines() == ["upstream:reset"], "main reset did not use retained upstream offline")
        require(not (menu.root / "boot/grub/custom.cfg").exists(), "main reset did not cancel preparation")
        require((menu.root / "var/lib/vpsctl/reinstall/reinstall.sh").exists(), "main reset removed retained tool")
    with Menu("main-uninstall-offline", seed=True, MOCK_DOWNLOAD="fail") as menu:
        menu.choice("11")
        menu.choice("q")
        menu.finish()
        require(menu.event_lines() == ["upstream:reset"], "main uninstall did not reset before cleanup offline")
        for name in ("var/lib/vpsctl/reinstall", "reinstall-tmp", "reinstall-vmlinuz", "reinstall.log"):
            require(not (menu.root / name).exists(), f"main uninstall left {name}")
    for choice in ("1", "2", "3", "q", "eof"):
        with Menu(f"post-{choice}", seed=True) as menu:
            linux(menu)
            menu.confirm()
            if choice == "eof":
                menu.expect(PROMPT)
                menu.send("\x04")
                menu.choice("q")
            else:
                menu.post(choice)
            menu.finish()
            events = ["download", "upstream:debian"]
            if choice == "1":
                events.append("reboot")
                menu.preserved()
            elif choice == "3":
                events.append("upstream:reset")
                require(not (menu.root / "boot/grub/custom.cfg").exists(), "post reset left mock boot entry")
                require(not (menu.root / "reinstall-tmp").exists(), "post reset did not cancel mock preparation")
                require((menu.root / "var/lib/vpsctl/reinstall/reinstall.sh").exists(), "reset deleted retained script")
            else:
                menu.preserved()
            require(menu.event_lines() == events, f"{menu.name}: unexpected events {menu.event_lines()!r}")
    with Menu("upstream-failure-no-reboot", seed=True, MOCK_EXIT=47) as menu:
        linux(menu)
        menu.confirm()
        menu.finish(47)
        menu.preserved()
        require(menu.event_lines() == ["download", "upstream:debian"], "failed upstream entered post actions")
        require("立即重启" not in menu.output, "failure offered reboot")
    with Menu("reboot-failure-preserves-state", seed=True, MOCK_REBOOT_EXIT=1) as menu:
        linux(menu)
        menu.confirm()
        menu.choice("1")
        menu.finish(20)
        menu.preserved()
        require(menu.event_lines() == ["download", "upstream:debian", "reboot"], "reboot failure triggered reset")
    with Menu("post-reset-failure", seed=True, MOCK_RESET_EXIT=42) as menu:
        linux(menu)
        menu.confirm()
        menu.choice("3")
        menu.finish(42)
        menu.preserved()
        require(menu.event_lines() == ["download", "upstream:debian", "upstream:reset"], "reset failure events")


def locked(menu):
    before = menu.event_lines()
    env = dict(menu.env, VPSCTL_NON_INTERACTIVE="1", MOCK_SLEEP="0")
    for action in ("reset", "uninstall"):
        result = subprocess.run(["bash", ENTRY, action], env=env, capture_output=True, timeout=5)
        require(result.returncode == 3, f"{menu.name}: {action} acquired held menu lock, exit {result.returncode}")
    require(menu.event_lines() == before, f"{menu.name}: concurrent action reached upstream")


def check_lifecycle():
    with Menu("upstream-terminal-stdin", MOCK_READ_STDIN=1) as menu:
        linux(menu)
        menu.confirm()
        deadline = time.monotonic() + 5
        while not (menu.root / "tty").exists():
            require(time.monotonic() < deadline, "mock upstream never received TTY")
            menu.poll()
        menu.send("child terminal input\n")
        menu.post()
        menu.finish()
        require((menu.root / "stdin").read_text() == "child terminal input", "menu child lost terminal stdin")
    for signum, expected, name in ((signal.SIGINT, 130, "INT"), (signal.SIGTERM, 143, "TERM")):
        with Menu(f"menu-forwards-{name}", seed=True, MOCK_SLEEP=1) as menu:
            linux(menu)
            menu.confirm()
            deadline = time.monotonic() + 5
            while not (menu.root / "pid").exists():
                require(time.monotonic() < deadline, "mock upstream never started")
                menu.poll()
            child = int((menu.root / "pid").read_text())
            require(child != menu.pid, "menu must retain wrapper for completion actions")
            locked(menu)
            os.kill(menu.pid, signum)
            menu.finish(expected)
            require((menu.root / "signal").read_text().strip() == name, f"menu did not forward {name}")
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError("menu signal left upstream running")
            menu.preserved()
            env = dict(menu.env, VPSCTL_NON_INTERACTIVE="1", MOCK_SLEEP="0")
            result = subprocess.run(["bash", ENTRY, "reset"], env=env, capture_output=True, timeout=5)
            require(result.returncode == 0, "menu signal did not release its lock")
    with Menu("post-menu-retains-lock", seed=True) as menu:
        linux(menu)
        menu.confirm()
        menu.expect(PROMPT)
        locked(menu)
        menu.send("2\n")
        menu.choice("q")
        menu.finish()
        menu.preserved()


check_presets()
check_credentials()
check_cancellation()
check_post_menu()
check_lifecycle()
print(f"PASS: reinstall menu PTY acceptance ({COUNT} fixtures)")
