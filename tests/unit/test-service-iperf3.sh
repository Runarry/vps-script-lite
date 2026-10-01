#!/usr/bin/env bash
# Isolated acceptance; execute only on host-vps-scripts (AGENTS.md).
set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
readonly TEST_ROOT TEST_TEMP
readonly TEST_COMMAND="$TEST_ROOT/commands/service/iperf3.sh"
readonly TEST_SYSTEM_ROOT="$TEST_TEMP/root"
readonly TEST_FAKE_BIN="$TEST_TEMP/bin"
readonly TEST_LOG="$TEST_TEMP/mock.log"
mock_live_pid=''
cleanup() {
    if [[ -n "$mock_live_pid" ]]; then
        kill "$mock_live_pid" 2>/dev/null || true
        wait "$mock_live_pid" 2>/dev/null || true
    fi
    rm -rf -- "$TEST_TEMP"
}
trap cleanup EXIT
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
assert_status() {
    local expected="$1" actual=0
    shift
    "$@" >"$TEST_TEMP/output" 2>&1 || actual=$?
    [[ "$actual" == "$expected" ]] || fail "$*: expected $expected, got $actual; $(cat "$TEST_TEMP/output")"
}
assert_state() {
    jq -e --argjson port "$1" --argjson enabled "$2" \
        '.schema_version==1 and .port==$port and .enabled==$enabled' "$state" >/dev/null || fail 'state does not match expected port/intent'
}
assert_running() {
    [[ -e "$TEST_SYSTEM_ROOT/run/iperf3-active" && -e "$TEST_SYSTEM_ROOT/run/iperf3-enabled" ]] || fail 'service is not active and enabled'
}
snapshot() { sha256sum "$state" "$unit" "$fw"; }

mkdir -p "$TEST_SYSTEM_ROOT/run" "$TEST_FAKE_BIN"
: >"$TEST_LOG"
sleep 600 &
mock_live_pid=$!
export MOCK_LIVE_PID="$mock_live_pid" MOCK_LOG="$TEST_LOG" MOCK_BIN="$TEST_FAKE_BIN"
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT" VPSCTL_ENV_INIT=systemd
export VPSCTL_ENV_PACKAGE_MANAGER=apt-get VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1 VPSCTL_ASSUME_YES=0
export PATH="$TEST_FAKE_BIN:$PATH"
cat >"$TEST_FAKE_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$MOCK_LOG"
root="$VPSCTL_SYSTEM_ROOT"
case "${1:-}" in
    is-active) [[ -e "$root/run/iperf3-active" ]] ;;
    is-enabled) [[ -e "$root/run/iperf3-enabled" ]] ;;
    show)
        if [[ -e "$root/run/iperf3-active" ]]; then printf '%s\n' "$MOCK_LIVE_PID"; else printf '0\n'; fi
        ;;
    daemon-reload) exit 0 ;;
    start|restart)
        if [[ -e "$root/run/signal-start-once" ]]; then
            rm -f "$root/run/signal-start-once"
            kill -TERM "$PPID"
            exit 143
        fi
        if [[ -e "$root/run/fail-start-once" ]]; then rm -f "$root/run/fail-start-once"; exit 20; fi
        port="$(sed -nE 's/^ExecStart=.* (-p|--port) ([0-9]+).*/\2/p' "$root/etc/systemd/system/vpsctl-iperf3.service")"
        [[ "$port" =~ ^[0-9]+$ ]] || exit 21
        printf '%s\n' "$port" >"$root/run/iperf3-port"
        touch "$root/run/iperf3-active"
        ;;
    stop) rm -f "$root/run/iperf3-active" "$root/run/iperf3-port" ;;
    enable)
        if [[ -e "$root/run/fail-enable-once" ]]; then rm -f "$root/run/fail-enable-once"; exit 20; fi
        touch "$root/run/iperf3-enabled"
        ;;
    disable) rm -f "$root/run/iperf3-enabled" ;;
    *) exit 2 ;;
esac
SH
cat >"$TEST_FAKE_BIN/ss" <<'SH'
#!/usr/bin/env bash
# An idle iperf3 server has TCP control listening, but no UDP test socket.
root="$VPSCTL_SYSTEM_ROOT"
requested=''
if [[ "$*" =~ sport\ =\ :([0-9]+) ]]; then requested="${BASH_REMATCH[1]}"; fi
if [[ "$*" != *u* && -e "$root/run/iperf3-active" ]]; then
    port="$(cat "$root/run/iperf3-port")"
    if [[ -z "$requested" || "$requested" == "$port" ]]; then
        printf 'LISTEN 0 4096 *:%s *:* users:(("iperf3",pid=%s,fd=3))\n' "$port" "$MOCK_LIVE_PID"
    fi
fi
if [[ -f "$root/run/conflict" ]]; then
    read -r proto port <"$root/run/conflict"
    if [[ "$proto" == uc ]]; then
        [[ "$*" == *a* ]] || exit 0
        proto=u
    fi
    if [[ "$*" == *"$proto"* && ( -z "$requested" || "$requested" == "$port" ) ]]; then
        printf '%s 0 0 0.0.0.0:%s 0.0.0.0:* users:(("other",pid=1,fd=3))\n' \
            "$([[ "$proto" == t ]] && printf LISTEN || printf UNCONN)" "$port"
    fi
fi
SH
cat >"$TEST_FAKE_BIN/iperf3" <<'SH'
#!/usr/bin/env bash
printf 'iperf 3.17 (mock)\n'
SH
cat >"$TEST_FAKE_BIN/ufw" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == status ]] || exit 2
printf 'Status: inactive\n'
SH
cat >"$TEST_FAKE_BIN/apt-get" <<'SH'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >>"$MOCK_LOG"
if [[ -e "$VPSCTL_SYSTEM_ROOT/run/fail-package-once" ]]; then
    rm -f "$VPSCTL_SYSTEM_ROOT/run/fail-package-once"
    exit 20
fi
if [[ " $* " == *' install '* ]]; then touch "$VPSCTL_SYSTEM_ROOT/run/dependency-installed"; fi
SH
cat >"$TEST_FAKE_BIN/debconf-set-selections" <<'SH'
#!/usr/bin/env bash
printf 'debconf: ' >>"$MOCK_LOG"
cat >>"$MOCK_LOG"
SH
cat >"$TEST_FAKE_BIN/journalctl" <<'SH'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*" >>"$MOCK_LOG"
SH
cat >"$TEST_FAKE_BIN/dpkg-query" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == -S ]] || exit 2
[[ ! -e "$VPSCTL_SYSTEM_ROOT/run/unowned-binary" ]] || exit 1
printf 'iperf3: %s\n' "$2"
SH
chmod +x "$TEST_FAKE_BIN/"*
state="$TEST_SYSTEM_ROOT/var/lib/vpsctl/service/iperf3/state.json"
unit="$TEST_SYSTEM_ROOT/etc/systemd/system/vpsctl-iperf3.service"
fw="$TEST_SYSTEM_ROOT/var/lib/vpsctl/network/ufw/state.json"

# Read commands and a nonexistent stop never install or deploy a service.
for action in help status stop logs ''; do
    if [[ -n "$action" ]]; then
        assert_status 0 bash "$TEST_COMMAND" --install-deps "$action"
    else assert_status 0 bash "$TEST_COMMAND"; fi
done
[[ ! -e "$state" && ! -e "$unit" ]] || fail 'read-only/empty stop deployed files'
! grep -Fq 'apt-get ' "$TEST_LOG" || fail 'read-only/empty stop installed dependencies'
assert_status 3 bash "$TEST_COMMAND" restart
# A pre-existing system package may be updated before the managed service exists.
assert_status 0 bash "$TEST_COMMAND" update
[[ ! -e "$state" && ! -e "$unit" ]] || fail 'package-only update deployed a service'
: >"$TEST_SYSTEM_ROOT/run/unowned-binary"
: >"$TEST_LOG"
assert_status 3 bash "$TEST_COMMAND" update
! grep -Fq 'apt-get ' "$TEST_LOG" || fail 'unowned binary triggered a package update'
[[ ! -e "$state" && ! -e "$unit" ]] || fail 'rejected unmanaged update deployed a service'
rm -f "$TEST_SYSTEM_ROOT/run/unowned-binary" "$TEST_SYSTEM_ROOT/run/dependency-installed"
cat >"$TEST_TEMP/missing-binary.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$TEST_COMMAND"
command() {
    if [[ "${1:-}" == -v && "${2:-}" == iperf3 ]]; then return 1; fi
    builtin command "$@"
}
iperf3_main update
SH
export TEST_COMMAND
assert_status 3 bash "$TEST_TEMP/missing-binary.sh"
for bad in 0 65536 -1 abc 1.5 00000; do assert_status 2 bash "$TEST_COMMAND" start --port "$bad"; done
assert_status 2 bash "$TEST_COMMAND" start --port 5201 --port 5202
assert_status 2 bash "$TEST_COMMAND" start --port
assert_status 2 bash "$TEST_COMMAND" status --port 5201
assert_status 2 bash "$TEST_COMMAND" restart --port 5201
assert_status 2 bash "$TEST_COMMAND" unknown
assert_status 0 bash "$TEST_COMMAND" --dry-run start
[[ ! -e "$state" && ! -e "$unit" ]] || fail 'invalid/dry-run command deployed files'
printf 'PASS: parsing, read-only commands, absent restart/binary, undeployed package update, unmanaged update rejection, dry run\n'

# Exercise real dependency policy with a lookup seam; other dependencies stay real.
cat >"$TEST_TEMP/dependencies.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$TEST_COMMAND"
_vps_cmd_tool_available() {
    if [[ "$1" == iperf3 ]]; then [[ -e "$VPSCTL_SYSTEM_ROOT/run/dependency-installed" ]]
    else command -v "$1" >/dev/null 2>&1; fi
}
iperf3_main "$@"
SH
export TEST_COMMAND
assert_status 3 bash "$TEST_TEMP/dependencies.sh" start
[[ ! -e "$state" && ! -e "$unit" ]] || fail 'rejected dependency installation deployed files'
assert_status 0 bash "$TEST_TEMP/dependencies.sh" --dry-run --install-deps start
[[ ! -e "$state" && ! -e "$unit" && ! -e "$TEST_SYSTEM_ROOT/run/dependency-installed" ]] || fail 'dependency dry run mutated system'
: >"$TEST_LOG"
assert_status 0 bash "$TEST_TEMP/dependencies.sh" --install-deps start
grep -Eq '^apt-get install .*iperf3' "$TEST_LOG" || fail 'explicit dependency permission did not install iperf3'
grep -Eq '^debconf: iperf3 iperf3/start_daemon boolean false' "$TEST_LOG" || fail 'Debian default daemon was not suppressed before install'
debconf_line="$(grep -n '^debconf:' "$TEST_LOG" | head -1 | cut -d: -f1)"
install_line="$(grep -n '^apt-get install ' "$TEST_LOG" | head -1 | cut -d: -f1)"
((debconf_line < install_line)) || fail 'Debian daemon suppression happened after package installation'
assert_state 5201 true
assert_running
printf 'PASS: missing dependency policy, default port, Debian native daemon suppression\n'

# Healthy reuse must not rewrite service configuration or restart native process.
before="$(sha256sum "$state" "$unit")"
firewall_before="$(jq -Sc '{requirements,links,managed,leases}' "$fw")"
: >"$TEST_LOG"
assert_status 0 bash "$TEST_COMMAND" start --port 05201
[[ "$(sha256sum "$state" "$unit")" == "$before" ]] || fail 'healthy same-port start rewrote service configuration'
[[ "$(jq -Sc '{requirements,links,managed,leases}' "$fw")" == "$firewall_before" ]] || fail 'healthy same-port start changed firewall demands/ownership'
! grep -Eq '^systemctl (start|restart|stop) ' "$TEST_LOG" || fail 'healthy same-port start restarted service'
rm -f "$TEST_SYSTEM_ROOT/run/iperf3-enabled"
assert_status 0 bash "$TEST_COMMAND" start
assert_running
assert_state 5201 true
printf 'PASS: TCP-only readiness, same-port idempotence, re-enable drifted service\n'

port=42691
before="$(snapshot)"
for proto in t u uc; do
    printf '%s %s\n' "$proto" "$port" >"$TEST_SYSTEM_ROOT/run/conflict"
    assert_status 3 bash "$TEST_COMMAND" start --port "$port"
    [[ "$(snapshot)" == "$before" ]] || fail "$proto port conflict changed state/unit/UFW"
    assert_running
done
rm -f "$TEST_SYSTEM_ROOT/run/conflict"
for fault in fail-start-once fail-enable-once signal-start-once; do
    # A port change must restore a previously disabled actual boot state too.
    rm -f "$TEST_SYSTEM_ROOT/run/iperf3-enabled"
    : >"$TEST_SYSTEM_ROOT/run/$fault"
    expected=20
    [[ "$fault" != signal-start-once ]] || expected=143
    assert_status "$expected" bash "$TEST_COMMAND" start --port "$port"
    [[ "$(snapshot)" == "$before" ]] || fail "$fault did not restore state/unit/UFW"
    [[ -e "$TEST_SYSTEM_ROOT/run/iperf3-active" && ! -e "$TEST_SYSTEM_ROOT/run/iperf3-enabled" ]] || fail "$fault did not restore actual active/enabled status"
    [[ "$(cat "$TEST_SYSTEM_ROOT/run/iperf3-port")" == 5201 ]] || fail "$fault did not restore original listener port"
done
assert_status 0 bash "$TEST_COMMAND" start --port "$port"
assert_running
assert_state "$port" true
printf 'PASS: TCP/UDP conflicts, start/enable failure and TERM rollback, port switch\n'

# Package updates preserve actual service state independently of persistent intent.
for intent in true false; do
    jq --argjson intent "$intent" '.enabled=$intent' "$state" >"$state.next"
    mv "$state.next" "$state"
    for active in 0 1; do
        for enabled in 0 1; do
            if ((active)); then
                touch "$TEST_SYSTEM_ROOT/run/iperf3-active"
                printf '%s\n' "$port" >"$TEST_SYSTEM_ROOT/run/iperf3-port"
            else rm -f "$TEST_SYSTEM_ROOT/run/iperf3-active" "$TEST_SYSTEM_ROOT/run/iperf3-port"; fi
            if ((enabled)); then touch "$TEST_SYSTEM_ROOT/run/iperf3-enabled"; else rm -f "$TEST_SYSTEM_ROOT/run/iperf3-enabled"; fi
            before="$(snapshot)"
            : >"$TEST_LOG"
            assert_status 0 bash "$TEST_COMMAND" update
            [[ "$(snapshot)" == "$before" ]] || fail "update rewrote intent/files for active=$active enabled=$enabled intent=$intent"
            [[ -e "$TEST_SYSTEM_ROOT/run/iperf3-active" ]] && actual_active=1 || actual_active=0
            [[ -e "$TEST_SYSTEM_ROOT/run/iperf3-enabled" ]] && actual_enabled=1 || actual_enabled=0
            [[ "$actual_active" == "$active" && "$actual_enabled" == "$enabled" ]] || fail "update changed actual states $active/$enabled"
            grep -Eq '^apt-get install .*--only-upgrade.*iperf3|^apt-get install .*iperf3.*--only-upgrade' "$TEST_LOG" || fail 'update was not limited to the existing system package'
            if ((active)); then
                grep -Eq '^systemctl (start|restart) ' "$TEST_LOG" || fail 'active update did not restart new binary'
            else ! grep -Eq '^systemctl (start|restart) ' "$TEST_LOG" || fail 'stopped update started the service'; fi
        done
    done
done
: >"$TEST_SYSTEM_ROOT/run/fail-package-once"
before="$(snapshot)"
assert_status 20 bash "$TEST_COMMAND" update
[[ "$(snapshot)" == "$before" ]] || fail 'failed update changed prior service configuration/UFW'
assert_running
# Package ownership is a precondition; rejection cannot touch the deployed
# service, including actual runtime and boot state that differ from saved intent.
: >"$TEST_SYSTEM_ROOT/run/unowned-binary"
: >"$TEST_LOG"
before="$(snapshot)"
runtime_before="$(sha256sum "$TEST_SYSTEM_ROOT/run/iperf3-port" "$TEST_FAKE_BIN/iperf3")"
assert_status 3 bash "$TEST_COMMAND" update
[[ "$(snapshot)" == "$before" ]] || fail 'unowned update changed state/unit/UFW'
[[ "$(sha256sum "$TEST_SYSTEM_ROOT/run/iperf3-port" "$TEST_FAKE_BIN/iperf3")" == "$runtime_before" ]] || fail 'unowned update changed runtime/binary'
assert_running
! grep -Fq 'apt-get ' "$TEST_LOG" || fail 'unowned deployed binary triggered package operations'
! grep -Eq '^systemctl (stop|start|restart|enable|disable) ' "$TEST_LOG" || fail 'unowned update mutated actual service state'
rm -f "$TEST_SYSTEM_ROOT/run/unowned-binary"
printf 'PASS: update state matrix, package failure, unowned binary precondition preservation\n'

# Independent owner survives stop and uninstall.
jq '.requirements += [(.requirements[0] | .owner="ssh" | .scope="ssh" | .port="22222")] | .links.ssh={scope:"ssh",detached:false}' "$fw" >"$fw.next"
mv "$fw.next" "$fw"
assert_status 0 bash "$TEST_COMMAND" stop
assert_state "$port" false
[[ -f "$unit" && ! -e "$TEST_SYSTEM_ROOT/run/iperf3-active" && ! -e "$TEST_SYSTEM_ROOT/run/iperf3-enabled" ]] || fail 'stop did not disable service and retain files'
jq -e '[.requirements[].owner] | index("iperf3")==null and index("ssh")!=null' "$fw" >/dev/null || fail 'stop corrupted UFW owner isolation'
assert_status 0 bash "$TEST_COMMAND" restart
assert_state "$port" true
assert_running
assert_status 0 bash "$TEST_COMMAND" logs
binary_before="$(sha256sum "$TEST_FAKE_BIN/iperf3")"
mkdir -p "$TEST_SYSTEM_ROOT/var/log/vpsctl"
printf 'test log\n' >"$TEST_SYSTEM_ROOT/var/log/vpsctl/iperf3.log"
assert_status 0 bash "$TEST_COMMAND" --yes uninstall
[[ ! -e "$state" && ! -e "$unit" && ! -e "$TEST_SYSTEM_ROOT/var/log/vpsctl/iperf3.log" ]] || fail 'uninstall left owned files'
[[ "$(sha256sum "$TEST_FAKE_BIN/iperf3")" == "$binary_before" ]] || fail 'uninstall removed/changed system binary'
! grep -Eq '^apt-get (remove|purge|autoremove)' "$TEST_LOG" || fail 'uninstall removed system packages'
jq -e '[.requirements[].owner] | index("iperf3")==null and index("ssh")!=null' "$fw" >/dev/null || fail 'uninstall changed unrelated UFW owner'
: >"$TEST_SYSTEM_ROOT/run/signal-start-once"
assert_status 143 bash "$TEST_COMMAND" start --port "$port"
[[ ! -e "$state" && ! -e "$unit" && ! -e "$TEST_SYSTEM_ROOT/run/iperf3-enabled" ]] || fail 'interrupted fresh install leaked owned resources'
jq -e '[.requirements[].owner] | index("iperf3")==null and index("ssh")!=null' "$fw" >/dev/null || fail 'interrupted fresh install leaked firewall demand'
printf 'PASS: stop/restart/logs/uninstall, retained package, fresh-install signal cleanup\n'

# Once business state is committed, a signal must finish firewall commit rather
# than roll back only half of the transaction.
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
iperf3_main start --port "$POST_PORT"
SH
: >"$TEST_TEMP/postcommit.log"
signal_status=0
env POST_LOG="$TEST_TEMP/postcommit.log" POST_MARK="$TEST_TEMP/postcommit-sent" POST_PORT="$port" \
    bash "$TEST_TEMP/postcommit.sh" >"$TEST_TEMP/postcommit-output" 2>&1 || signal_status=$?
[[ "$signal_status" == 143 ]] || fail "post-commit signal returned $signal_status"
[[ "$(grep -Fc 'commit' "$TEST_TEMP/postcommit.log")" == 2 ]] || fail 'post-commit signal did not finish firewall commit'
! grep -Fq 'rollback' "$TEST_TEMP/postcommit.log" || fail 'post-commit signal rolled back committed state'
assert_state "$port" true
assert_running
assert_status 0 bash "$TEST_COMMAND" --yes uninstall
if command -v script >/dev/null 2>&1; then
    menu_status=0
    printf 'q\n' | VPSCTL_NON_INTERACTIVE=0 script -q -e -c "bash $TEST_COMMAND" /dev/null >"$TEST_TEMP/menu-output" 2>&1 || menu_status=$?
    [[ "$menu_status" == 0 ]] || fail "interactive menu exit returned $menu_status"
    grep -Fq '卸载' "$TEST_TEMP/menu-output" || fail 'interactive menu omitted uninstall'
    grep -Fq '更新' "$TEST_TEMP/menu-output" || fail 'interactive menu omitted update'
    [[ ! -e "$state" && ! -e "$unit" ]] || fail 'interactive menu exit mutated service'
fi
printf 'PASS: committed transaction signal recovery and interactive menu exit\n'
