#!/usr/bin/env bash
# Isolated TCPing acceptance. Run only on host-vps-scripts (see AGENTS.md).
set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
readonly TEST_ROOT TEST_TEMP
readonly TEST_LISTENER="$TEST_ROOT/commands/service/tcping/listener.py"
readonly TEST_COMMAND="$TEST_ROOT/commands/service/tcping.sh"
readonly TEST_SYSTEM_ROOT="$TEST_TEMP/root"
readonly TEST_FAKE_BIN="$TEST_TEMP/bin"
readonly TEST_LOG="$TEST_TEMP/mock.log"
listener_pid=''
mock_live_pid=''
cleanup() {
    if [[ -n "$listener_pid" ]]; then
        kill "$listener_pid" >/dev/null 2>&1 || true
        wait "$listener_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$mock_live_pid" ]]; then
        kill "$mock_live_pid" >/dev/null 2>&1 || true
        wait "$mock_live_pid" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$TEST_TEMP"
}

test_module() {
    local state unit runtime fw before reused_pid='' port occupied_pid='' occupied_port cancel_status=0 signal_status=0
    state="$TEST_SYSTEM_ROOT/var/lib/vpsctl/service/tcping/state.json"
    unit="$TEST_SYSTEM_ROOT/etc/systemd/system/vpsctl-tcping.service"
    runtime="$TEST_SYSTEM_ROOT/usr/local/libexec/vpsctl/tcping/listener.py"
    fw="$TEST_SYSTEM_ROOT/var/lib/vpsctl/network/ufw/state.json"
    port=42691
    mkdir -p "$TEST_SYSTEM_ROOT/run" "$TEST_FAKE_BIN"
    : >"$TEST_LOG"
    sleep 600 &
    mock_live_pid=$!
    export MOCK_LIVE_PID="$mock_live_pid" MOCK_LOG="$TEST_LOG"
    export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT" VPSCTL_ENV_INIT=systemd
    export VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1 VPSCTL_ASSUME_YES=0
    export PATH="$TEST_FAKE_BIN:$PATH"

    cat >"$TEST_FAKE_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_LOG"
root="$VPSCTL_SYSTEM_ROOT"
action="${1:-}"
case "$action" in
    is-active) [[ -e "$root/run/tcping-active" ]] ;;
    is-enabled) [[ -e "$root/run/tcping-enabled" ]] ;;
    daemon-reload) exit 0 ;;
    start)
        if [[ -e "$root/run/signal-start-once" ]]; then
            rm -f "$root/run/signal-start-once"
            kill -TERM "$PPID"
            exit 143
        fi
        if [[ -e "$root/run/fail-start-once" ]]; then rm -f "$root/run/fail-start-once"; exit 20; fi
        port="$(sed -nE 's/.*--port ([0-9]+) --ready-file.*/\1/p' "$root/etc/systemd/system/vpsctl-tcping.service")"
        [[ "$port" =~ ^[0-9]+$ ]] || exit 21
        mkdir -p "$root/run/vpsctl"
        printf '{"pid":%s,"port":%s,"families":["ipv4","ipv6"]}\n' "$MOCK_LIVE_PID" "$port" >"$root/run/vpsctl/tcping-ready.json"
        touch "$root/run/tcping-active"
        ;;
    stop)
        rm -f "$root/run/tcping-active" "$root/run/vpsctl/tcping-ready.json"
        ;;
    enable)
        if [[ -e "$root/run/fail-enable-once" ]]; then rm -f "$root/run/fail-enable-once"; exit 20; fi
        touch "$root/run/tcping-enabled"
        ;;
    disable) rm -f "$root/run/tcping-enabled" ;;
    *) exit 2 ;;
esac
SH
    cat >"$TEST_FAKE_BIN/ufw" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == status ]] || exit 2
printf 'Status: inactive\n'
SH
    cat >"$TEST_FAKE_BIN/apt-get" <<'SH'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >>"$MOCK_LOG"
SH
    chmod +x "$TEST_FAKE_BIN/systemctl" "$TEST_FAKE_BIN/ufw" "$TEST_FAKE_BIN/apt-get"

    assert_status 0 bash "$TEST_COMMAND" --install-deps --help
    assert_status 0 bash "$TEST_COMMAND" --install-deps status
    assert_status 0 bash "$TEST_COMMAND" --install-deps stop
    [[ ! -e "$state" && ! -e "$runtime" && ! -e "$unit" ]] || fail 'read-only/empty stop created TCPing files'
    ! grep -Fq 'apt-get ' "$TEST_LOG" || fail 'help/status/stop installed a dependency'

    assert_status 2 bash "$TEST_COMMAND" start
    for bad in 0 65536 -1 abc 1.5 00000; do
        assert_status 2 bash "$TEST_COMMAND" start --port "$bad"
    done
    assert_status 2 bash "$TEST_COMMAND" start --port "$port" --port "$port"
    [[ ! -e "$state" ]] || fail 'invalid start wrote state'

    assert_status 0 bash "$TEST_COMMAND" start --port "$port"
    [[ -f "$runtime" && -f "$unit" && -e "$TEST_SYSTEM_ROOT/run/tcping-enabled" ]] || fail 'start did not deploy and enable service'
    jq -e --argjson port "$port" '.schema_version==1 and .port==$port and .enabled==true' "$state" >/dev/null || fail 'start state schema is wrong'
    jq -e --argjson port "$port" '[.requirements[] | select(.owner=="tcping" and .scope=="tcping" and .port==($port|tostring))] | length==1' "$fw" >/dev/null || fail 'start did not record TCPing UFW demand'
    rm -f "$TEST_SYSTEM_ROOT/run/vpsctl/tcping-ready.json"
    : >"$TEST_LOG"
    assert_status 0 bash "$TEST_COMMAND" start --port "$port"
    [[ -e "$TEST_SYSTEM_ROOT/run/vpsctl/tcping-ready.json" ]] || fail 'same-port start did not recover missing readiness'
    grep -Fq 'stop vpsctl-tcping.service' "$TEST_LOG" || fail 'missing readiness did not restart stale service'
    printf '\n# Test fixture: retained managed listener differs from project source.\n' >>"$runtime"
    cmp -s "$runtime" "$TEST_LISTENER" && fail 'same-port fixture did not change managed runtime'
    head -n 3 "$runtime" | grep -Fxq '# Managed by vpsctl tcping.' || fail 'same-port fixture lost managed runtime marker'
    before="$(sha256sum "$state" "$unit" "$runtime")"
    reused_pid="$(jq -r '.pid' "$TEST_SYSTEM_ROOT/run/vpsctl/tcping-ready.json")"
    : >"$TEST_LOG"
    assert_status 0 bash "$TEST_COMMAND" start --port "$port"
    [[ "$(sha256sum "$state" "$unit" "$runtime")" == "$before" ]] || fail 'same-port start rewrote configuration'
    ! grep -Eq '^(stop|start) ' "$TEST_LOG" || fail 'same-port start restarted service'
    ! cmp -s "$runtime" "$TEST_LISTENER" || fail 'same-port start replaced retained managed runtime'
    [[ "$(jq -r '.pid' "$TEST_SYSTEM_ROOT/run/vpsctl/tcping-ready.json")" == "$reused_pid" ]] || fail 'same-port start replaced listener process'
    kill -0 "$reused_pid" >/dev/null 2>&1 || fail 'same-port start left listener process unavailable'
    # Compare the literal command guidance printed by the CLI.
    # shellcheck disable=SC2016
    grep -Fq 'TCPing 已在该端口运行，本次未重新部署监听脚本。需要更新脚本时，请先执行 `vpsctl service tcping stop`，再执行 `vpsctl service tcping start`。' "$TEST_TEMP/output" || fail 'same-port start did not explain retained listener script'

    occupied_port="$(
        python3 -B - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("0.0.0.0", 0))
    print(sock.getsockname()[1])
PY
    )"
    # Hold the occupied port through the subprocess lifetime.
    python3 -B - "$occupied_port" "$TEST_TEMP/occupied-ready" <<'PY' &
import socket
import sys
import time
with socket.socket() as sock:
    sock.bind(("0.0.0.0", int(sys.argv[1])))
    sock.listen()
    open(sys.argv[2], "w").close()
    time.sleep(30)
PY
    occupied_pid=$!
    for _ in {1..100}; do
        [[ -e "$TEST_TEMP/occupied-ready" ]] && break
        sleep 0.02
    done
    [[ -e "$TEST_TEMP/occupied-ready" ]] || fail 'occupied-port fixture did not start'
    assert_status 3 bash "$TEST_COMMAND" start --port "$occupied_port"
    [[ "$(sha256sum "$state" "$unit" "$runtime")" == "$before" ]] || fail 'occupied-port change altered existing service'
    [[ -e "$TEST_SYSTEM_ROOT/run/tcping-active" ]] || fail 'occupied-port change stopped old service'
    kill "$occupied_pid"
    wait "$occupied_pid" || true

    : >"$TEST_SYSTEM_ROOT/run/fail-start-once"
    assert_status 20 bash "$TEST_COMMAND" start --port "$((port + 1))"
    [[ "$(sha256sum "$state" "$unit" "$runtime")" == "$before" ]] || fail 'failed port change did not restore files'
    [[ -e "$TEST_SYSTEM_ROOT/run/tcping-active" && -e "$TEST_SYSTEM_ROOT/run/tcping-enabled" ]] || fail 'failed port change did not restore old service'
    jq -e --argjson port "$port" '.port==$port' "$TEST_SYSTEM_ROOT/run/vpsctl/tcping-ready.json" >/dev/null || fail 'failed port change did not restore old readiness'

    # An unrelated UFW owner must survive release of the TCPing demand.
    jq '.requirements += [(.requirements[0] | .owner="ssh" | .scope="ssh" | .port="22222")] | .links.ssh={scope:"ssh",detached:false}' "$fw" >"$fw.next"
    mv "$fw.next" "$fw"
    assert_status 0 bash "$TEST_COMMAND" stop
    jq -e --argjson port "$port" '.schema_version==1 and .port==$port and .enabled==false' "$state" >/dev/null || fail 'stop did not retain disabled port'
    [[ -f "$runtime" && -f "$unit" && ! -e "$TEST_SYSTEM_ROOT/run/tcping-active" && ! -e "$TEST_SYSTEM_ROOT/run/tcping-enabled" ]] || fail 'stop did not retain files and disable service'
    jq -e '[.requirements[] | .owner] | index("tcping") == null and index("ssh") != null' "$fw" >/dev/null || fail 'stop changed unrelated UFW owner or retained TCPing demand'

    assert_status 0 bash "$TEST_COMMAND" start
    jq -e --argjson port "$port" '.port==$port and .enabled==true' "$state" >/dev/null || fail 'portless restart did not reuse saved port'
    cmp -s "$runtime" "$TEST_LISTENER" || fail 'stop then start did not deploy current listener script'
    if command -v script >/dev/null 2>&1; then
        before="$(sha256sum "$state" "$unit" "$runtime")"
        printf 'n\n' | VPSCTL_NON_INTERACTIVE=0 script -q -e -c "bash $TEST_COMMAND uninstall" /dev/null >"$TEST_TEMP/cancel-output" 2>&1 || cancel_status=$?
        [[ "$cancel_status" == 130 ]] || fail "declined uninstall should return 130, got $cancel_status"
        [[ "$(sha256sum "$state" "$unit" "$runtime")" == "$before" && -e "$TEST_SYSTEM_ROOT/run/tcping-active" ]] ||
            fail 'declined uninstall changed running service'
    fi
    assert_status 0 bash "$TEST_COMMAND" --yes uninstall
    [[ ! -e "$state" && ! -e "$runtime" && ! -e "$unit" ]] || fail 'uninstall left owned files'
    [[ ! -e "$TEST_SYSTEM_ROOT/run/tcping-enabled" ]] || fail 'uninstall left autostart enabled'
    jq -e '[.requirements[] | .owner] | index("tcping") == null and index("ssh") != null' "$fw" >/dev/null || fail 'uninstall changed unrelated UFW owner'
    : >"$TEST_SYSTEM_ROOT/run/signal-start-once"
    assert_status 143 bash "$TEST_COMMAND" start --port "$port"
    [[ ! -e "$state" && ! -e "$runtime" && ! -e "$unit" && ! -e "$TEST_SYSTEM_ROOT/run/tcping-enabled" ]] ||
        fail 'interrupted start left TCPing files or autostart'
    jq -e '[.requirements[] | .owner] | index("tcping") == null and index("ssh") != null' "$fw" >/dev/null ||
        fail 'interrupted start left TCPing UFW demand or removed other owner'

    cat >"$TEST_TEMP/postcommit.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$TEST_COMMAND"
vps_ufw_begin() { VPS_UFW_DEPTH=1; printf 'begin\n' >>"$POST_LOG"; }
vps_ufw_commit() {
    printf 'commit\n' >>"$POST_LOG"
    if [[ ! -e "$POST_MARK" ]]; then
        touch "$POST_MARK"
        kill -TERM "$BASHPID"
        return 143
    fi
    VPS_UFW_DEPTH=0
}
vps_ufw_rollback() { VPS_UFW_DEPTH=0; printf 'rollback\n' >>"$POST_LOG"; }
tcping_main start --port "$POST_PORT"
SH
    : >"$TEST_TEMP/postcommit.log"
    env TEST_COMMAND="$TEST_COMMAND" POST_LOG="$TEST_TEMP/postcommit.log" POST_MARK="$TEST_TEMP/postcommit-sent" \
        POST_PORT="$port" bash "$TEST_TEMP/postcommit.sh" >"$TEST_TEMP/postcommit-output" 2>&1 || signal_status=$?
    [[ "$signal_status" == 143 ]] || fail "post-commit signal returned $signal_status"
    [[ "$(grep -Fc 'commit' "$TEST_TEMP/postcommit.log")" == 2 ]] || fail 'post-commit signal did not finish UFW transaction in cleanup'
    ! grep -Fq 'rollback' "$TEST_TEMP/postcommit.log" || fail 'post-commit signal rolled back committed service'
    jq -e --argjson port "$port" '.port==$port and .enabled==true' "$state" >/dev/null || fail 'post-commit signal lost persisted service state'
    [[ -e "$TEST_SYSTEM_ROOT/run/tcping-active" && -e "$TEST_SYSTEM_ROOT/run/tcping-enabled" ]] ||
        fail 'post-commit signal stopped persisted service'
    assert_status 0 bash "$TEST_COMMAND" --yes uninstall
    if command -v script >/dev/null 2>&1; then
        cancel_status=0
        printf 'q\n' | VPSCTL_NON_INTERACTIVE=0 script -q -e -c "bash $TEST_COMMAND" /dev/null >"$TEST_TEMP/menu-output" 2>&1 || cancel_status=$?
        [[ "$cancel_status" == 0 ]] || fail "interactive menu exit returned $cancel_status"
        grep -Fq '创建 / 启动 / 修改端口' "$TEST_TEMP/menu-output" || fail 'interactive menu omitted start action'
        grep -Fq '卸载' "$TEST_TEMP/menu-output" || fail 'interactive menu omitted uninstall action'
        [[ ! -e "$state" ]] || fail 'interactive menu exit changed state'
    fi
    printf 'PASS: mock systemd CLI lifecycle, validation, rollback, UFW ownership\n'
}

test_alpine_init_mapping() (
    export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$TEST_TEMP/alpine-root" VPSCTL_ENV_INIT=init
    mkdir -p "$VPSCTL_SYSTEM_ROOT" "$TEST_TEMP/alpine-bin"
    printf '#!/bin/sh\nexit 0\n' >"$TEST_TEMP/alpine-bin/rc-service"
    printf '#!/bin/sh\nexit 0\n' >"$TEST_TEMP/alpine-bin/rc-update"
    chmod +x "$TEST_TEMP/alpine-bin/rc-service" "$TEST_TEMP/alpine-bin/rc-update"
    export PATH="$TEST_TEMP/alpine-bin:$PATH"
    # shellcheck source=/dev/null
    source "$TEST_COMMAND"
    tcping_init_paths
    [[ "$TCPING_INIT" == openrc && "$TCPING_UNIT_LOGICAL" == /etc/init.d/vpsctl-tcping ]] ||
        fail 'Alpine init was not mapped to OpenRC'
    printf 'PASS: Alpine init environment maps to OpenRC\n'
)
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
assert_status() {
    local expected="$1" actual=0
    shift
    "$@" >"$TEST_TEMP/output" 2>&1 || actual=$?
    [[ "$actual" == "$expected" ]] || fail "$*: expected status $expected, got $actual; output: $(cat "$TEST_TEMP/output")"
}

test_listener() {
    local port attempt
    port="$(
        python3 -B - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
    )"
    [[ "$port" =~ ^[0-9]+$ ]] || fail 'could not allocate listener test port'

    python3 -B "$TEST_LISTENER" --port "$port" --ready-file "$TEST_TEMP/ready.json" >"$TEST_TEMP/listener.log" 2>&1 &
    listener_pid=$!
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -s "$TEST_TEMP/ready.json" ]] && break
        kill -0 "$listener_pid" 2>/dev/null || fail "listener exited before ready: $(cat "$TEST_TEMP/listener.log")"
        sleep 0.05
    done
    [[ -s "$TEST_TEMP/ready.json" ]] || fail 'listener did not publish readiness'
    jq -e --argjson port "$port" --argjson pid "$listener_pid" \
        '.port == $port and .pid == $pid and (.families | index("ipv4"))' "$TEST_TEMP/ready.json" >/dev/null ||
        fail 'readiness JSON does not identify live IPv4 listener'

    # Connections from both address families must close promptly even in a burst.
    python3 -B - "$port" "$TEST_TEMP/ready.json" <<'PY'
import concurrent.futures
import json
import socket
import sys

port = int(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as stream:
    families = json.load(stream)["families"]
targets = [(socket.AF_INET, "127.0.0.1")]
if "ipv6" in families:
    targets.append((socket.AF_INET6, "::1"))

def probe(target):
    family, address = target
    with socket.socket(family, socket.SOCK_STREAM) as connection:
        connection.settimeout(3)
        connection.connect((address, port))
        if connection.recv(1) != b"":
            raise AssertionError("TCPing did not close accepted connection")

for target in targets:
    for _ in range(16):
        probe(target)
with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
    list(pool.map(probe, targets * 48))
PY

    assert_status 3 python3 -B "$TEST_LISTENER" --port "$port" --check
    kill "$listener_pid"
    wait "$listener_pid" || fail 'listener did not exit cleanly on SIGTERM'
    listener_pid=''
    [[ ! -e "$TEST_TEMP/ready.json" ]] || fail 'listener left stale readiness JSON after stop'
    printf 'PASS: listener IPv4/IPv6 accept-close, concurrent ingress, occupied port, readiness cleanup\n'
}

test_listener
test_alpine_init_mapping
test_module
