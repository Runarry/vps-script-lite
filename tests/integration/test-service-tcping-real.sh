#!/usr/bin/env bash
# Opt-in real service and network acceptance on host-vps-scripts or its isolated Alpine VM.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
[[ "${VPSCTL_REAL_TCPING_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_TCPING_TEST=1 in the dedicated test environment\n'
    exit 0
}
((EUID == 0)) || {
    printf 'FAIL: real TCPing acceptance requires root\n' >&2
    exit 4
}
for tool in bash jq python3 sha256sum timeout; do
    command -v "$tool" >/dev/null || {
        printf 'FAIL: missing %s\n' "$tool" >&2
        exit 3
    }
done

TEST_TEMP="$(mktemp -d /var/tmp/vpsctl-tcping-real.XXXXXX)"
RESULT_DIR="${VPSCTL_TCPING_RESULT_DIR:-$TEST_TEMP}"
mkdir -p -- "$RESULT_DIR"
exec > >(tee -a "$RESULT_DIR/acceptance.log") 2>&1
printf 'source=%s\n' "$TEST_ROOT"
sha256sum "$TEST_ROOT/bin/vpsctl" "$TEST_ROOT/commands/service/tcping.sh" "$TEST_ROOT/commands/service/tcping/listener.py"
# shellcheck source=/dev/null
. /etc/os-release
printf 'system=%s-%s kernel=%s boot_id=%s\n' "${ID:-unknown}" "${VERSION_ID:-unknown}" "$(uname -r)" "$(cat /proc/sys/kernel/random/boot_id)"

state='/var/lib/vpsctl/service/tcping/state.json'
runtime='/usr/local/libexec/vpsctl/tcping/listener.py'
ready='/run/vpsctl/tcping-ready.json'
fw='/var/lib/vpsctl/network/ufw/state.json'
unit=''
init=''
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
    init=systemd
    unit='/etc/systemd/system/vpsctl-tcping.service'
elif command -v rc-service >/dev/null && command -v rc-update >/dev/null; then
    init=openrc
    unit='/etc/init.d/vpsctl-tcping'
else
    printf 'FAIL: no supported init manager\n' >&2
    exit 3
fi
printf 'init=%s\n' "$init"

for path in "$state" "$runtime" "$unit" "$ready"; do
    [[ ! -e "$path" && ! -L "$path" ]] || {
        printf 'FAIL: pre-existing TCPing path %s\n' "$path" >&2
        exit 3
    }
done
if [[ "$init" == systemd ]]; then
    ! systemctl is-active --quiet vpsctl-tcping.service || exit 3
    ! systemctl is-enabled --quiet vpsctl-tcping.service || exit 3
else
    ! rc-service vpsctl-tcping status >/dev/null 2>&1 || exit 3
    [[ ! -e /etc/runlevels/default/vpsctl-tcping ]] || exit 3
fi
if command -v ufw >/dev/null; then ufw status; else printf 'ufw=absent\n'; fi
if [[ -f "$fw" ]]; then jq -c '[.requirements[] | .owner] | unique' "$fw" >"$RESULT_DIR/ufw-owners-before.json"; fi

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
vpsctl() { bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes "$@"; }
check_enabled() {
    if [[ "$init" == systemd ]]; then
        systemctl is-active --quiet vpsctl-tcping.service && systemctl is-enabled --quiet vpsctl-tcping.service
    else
        rc-service vpsctl-tcping status >/dev/null 2>&1 && [[ -e /etc/runlevels/default/vpsctl-tcping ]]
    fi
}
check_disabled() {
    if [[ "$init" == systemd ]]; then
        ! systemctl is-active --quiet vpsctl-tcping.service && ! systemctl is-enabled --quiet vpsctl-tcping.service
    else
        ! rc-service vpsctl-tcping status >/dev/null 2>&1 && [[ ! -e /etc/runlevels/default/vpsctl-tcping ]]
    fi
}
free_port() {
    python3 -B - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("0.0.0.0", 0))
    print(sock.getsockname()[1])
PY
}
probe() {
    local address="$1" port="$2" count="${3:-16}"
    python3 -B - "$address" "$port" "$count" <<'PY'
import concurrent.futures
import socket
import sys

address, port, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
family = socket.AF_INET6 if ":" in address else socket.AF_INET
def once(_):
    with socket.socket(family, socket.SOCK_STREAM) as connection:
        connection.settimeout(3)
        connection.connect((address, port))
        if connection.recv(1) != b"":
            raise AssertionError("TCPing did not close the connection")
with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
    list(pool.map(once, range(count)))
PY
}
probe_closed() {
    python3 -B - "$1" "$2" <<'PY'
import socket
import sys
host, port = sys.argv[1], int(sys.argv[2])
family = socket.AF_INET6 if ":" in host else socket.AF_INET
try:
    with socket.socket(family, socket.SOCK_STREAM) as connection:
        connection.settimeout(1)
        connection.connect((host, port))
except OSError:
    pass
else:
    raise SystemExit("unexpected TCPing ingress on stopped port")
PY
}

netns_probe() {
    local address="$1" port="$2" expected="$3"
    ip netns exec "$namespace" python3 -B - "$address" "$port" "$expected" <<'PY'
import socket
import sys

host, port, expected = sys.argv[1], int(sys.argv[2]), sys.argv[3]
family = socket.AF_INET6 if ":" in host else socket.AF_INET
try:
    with socket.socket(family, socket.SOCK_STREAM) as connection:
        connection.settimeout(3)
        connection.connect((host, port))
        if expected == "closed":
            raise AssertionError("stopped TCPing accepted namespace ingress")
        if connection.recv(1) != b"":
            raise AssertionError("TCPing did not close namespace ingress")
except OSError:
    if expected != "closed":
        raise
PY
}

other_owner() {
    TCPING_TEST_ROOT="$TEST_ROOT" TCPING_TEST_PORT="$new_port" TCPING_TEST_DESIRED="$TEST_TEMP/other-owner.json" \
        bash -c '
        set -Eeuo pipefail
        source "$TCPING_TEST_ROOT/lib/command.sh"
        source "$TCPING_TEST_ROOT/lib/ufw.sh"
        vps_cmd_init tcping-real-acceptance "$TCPING_TEST_ROOT"
        if [[ "$1" == add ]]; then
            jq -n --arg port "$TCPING_TEST_PORT" \
                '\''[{owner:"node:tcping-test",kind:"input",family:"ipv4",proto:"tcp",port:$port,source:"any",destination:"any",temporary:false}]'\'' \
                >"$TCPING_TEST_DESIRED"
        else printf "[]\n" >"$TCPING_TEST_DESIRED"; fi
        vps_ufw_begin tcping-other "$TCPING_TEST_DESIRED"
        vps_ufw_commit
    ' _ "$1"
}

assert_rule() {
    local port="$1" owner="$2" present="$3" inventory
    inventory="$(vpsctl network ufw rule list --json)"
    if [[ "$present" == yes ]]; then
        jq -e --arg port "$port" --arg owner "$owner" \
            'any(.[]; .family=="ipv4" and .kind=="input" and .proto=="tcp" and .port==$port and (.owners|index($owner)))' \
            <<<"$inventory" >/dev/null || fail "UFW has no IPv4 TCP $port rule owned by $owner"
    else
        jq -e --arg port "$port" --arg owner "$owner" \
            'all(.[]; .port!=$port or (.owners|index($owner)|not))' \
            <<<"$inventory" >/dev/null || fail "UFW retained IPv4 TCP $port rule owned by $owner"
    fi
}

namespace=''
root_if=''
busy_pid=''
manual_port=''
other_owner_seeded=0
cleanup() {
    local result=$?
    trap - EXIT HUP INT TERM
    if [[ -n "$busy_pid" ]]; then
        kill "$busy_pid" 2>/dev/null || true
        wait "$busy_pid" 2>/dev/null || true
    fi
    if [[ -n "$namespace" ]]; then ip netns del "$namespace" 2>/dev/null || true; fi
    if [[ -n "$root_if" ]]; then ip link del "$root_if" 2>/dev/null || true; fi
    if [[ -f "$unit" || -f "$state" || -f "$runtime" ]]; then vpsctl service tcping uninstall || result=30; fi
    if ((other_owner_seeded == 1)); then other_owner clear || result=30; fi
    if [[ -n "$manual_port" ]]; then ufw --force delete allow "$manual_port/tcp" || result=30; fi
    if ((result == 0)); then printf 'PASS: real TCPing acceptance and owned-resource cleanup\n'; fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

old_port="$(free_port)"
new_port="$(free_port)"
while [[ "$new_port" == "$old_port" ]]; do new_port="$(free_port)"; done
printf 'old_port=%s new_port=%s\n' "$old_port" "$new_port"
if [[ "${VPSCTL_TCPING_LIVE_UFW:-0}" == 1 ]]; then
    [[ "$(LC_ALL=C ufw status | head -1)" == 'Status: active' ]] || fail 'live UFW acceptance needs an active firewall'
    ufw allow "$old_port/tcp" comment 'tcping-accept-manual'
    manual_port="$old_port"
fi

# Dry run and untouched read commands must not install the feature.
vpsctl service tcping status
vpsctl service tcping
vpsctl --dry-run service tcping start --port "$old_port"
[[ ! -e "$state" && ! -e "$runtime" && ! -e "$unit" ]] || fail 'dry-run changed TCPing files'
vpsctl service tcping start --port "$old_port"
check_enabled || fail 'start did not activate and enable service'
jq -e --argjson port "$old_port" '.schema_version==1 and .port==$port and .enabled==true' "$state" >/dev/null || fail 'start state schema'
jq -e --argjson port "$old_port" '.port==$port and .pid>1 and (.families|index("ipv4"))' "$ready" >/dev/null || fail 'readiness does not identify running IPv4 listener'
[[ -f "$runtime" && -f "$unit" ]] || fail 'start did not deploy files'
cmp -s "$runtime" "$TEST_ROOT/commands/service/tcping/listener.py" || fail 'installed listener differs from source'
if [[ "$init" == systemd ]] && command -v runuser >/dev/null 2>&1; then
    user_status=0
    runuser -u nobody -- bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive service tcping status \
        >"$TEST_TEMP/unprivileged-status" 2>&1 || user_status=$?
    if runuser -u nobody -- test -r "$state" && runuser -u nobody -- test -r "$runtime" &&
        runuser -u nobody -- test -r "$unit" && runuser -u nobody -- test -r "$ready"; then
        [[ "$user_status" == 0 ]] || fail "readable state should return ordinary-user status 0, got $user_status"
        grep -Fq '运行中' "$TEST_TEMP/unprivileged-status" || fail 'ordinary-user status missed running listener'
        grep -Fq "$old_port" "$TEST_TEMP/unprivileged-status" || fail 'ordinary-user status missed configured port'
        printf 'PASS: readable ordinary-user status reports live listener\n'
    else
        [[ "$user_status" == 4 ]] || fail "restricted state should return 4 to an ordinary user, got $user_status"
        grep -Fq 'root' "$TEST_TEMP/unprivileged-status" || fail 'restricted status did not explain root is needed'
        ! grep -Fq '未安装' "$TEST_TEMP/unprivileged-status" || fail 'restricted status falsely reported uninstalled'
        printf 'PASS: restricted ordinary-user status fails clearly without false state\n'
    fi
fi
if [[ "${VPSCTL_TCPING_LIVE_UFW:-0}" == 1 ]]; then assert_rule "$old_port" tcping yes; fi

if [[ "${VPSCTL_TCPING_NETNS:-0}" == 1 ]]; then
    command -v ip >/dev/null || fail 'network namespace test needs ip'
    namespace="vtcp${BASHPID}"
    root_if="vth${BASHPID}"
    peer_if="vtp${BASHPID}"
    subnet=$((BASHPID % 180 + 40))
    root_ip="10.252.${subnet}.1"
    client_ip="10.252.${subnet}.2"
    printf -v ipv6_token '%x' "$((BASHPID % 65535))"
    root_ip6="fd7a:2026:${ipv6_token}::1"
    client_ip6="fd7a:2026:${ipv6_token}::2"
    ip netns add "$namespace"
    ip link add "$root_if" type veth peer name "$peer_if"
    ip link set "$peer_if" netns "$namespace"
    ip address add "$root_ip/24" dev "$root_if"
    ip -6 address add "$root_ip6/64" dev "$root_if" nodad
    ip link set "$root_if" up
    ip -n "$namespace" link set lo up
    ip -n "$namespace" link set "$peer_if" up
    ip -n "$namespace" address add "$client_ip/24" dev "$peer_if"
    ip -n "$namespace" -6 address add "$client_ip6/64" dev "$peer_if" nodad
    netns_probe "$root_ip" "$old_port" open
    netns_probe "$root_ip6" "$old_port" open
    printf 'PASS: IPv4/IPv6 ingress from separate network namespace\n'
fi
probe 127.0.0.1 "$old_port" 64
if jq -e '.families|index("ipv6")' "$ready" >/dev/null; then probe ::1 "$old_port" 64; fi
printf 'PASS: real IPv4/IPv6 concurrent ingress\n'

before="$(sha256sum "$state" "$unit" "$runtime")"
if [[ "$init" == systemd ]]; then
    service_pid="$(systemctl show -p MainPID --value vpsctl-tcping.service)"
else service_pid="$(jq -r '.pid' "$ready")"; fi
vpsctl service tcping start --port "$old_port"
[[ "$before" == "$(sha256sum "$state" "$unit" "$runtime")" ]] || fail 'same-port start rewrote files'
[[ "$(jq -r '.pid' "$ready")" == "$service_pid" ]] || fail 'same-port start restarted listener'

busy_port="$(free_port)"
python3 -B - "$busy_port" "$TEST_TEMP/busy-ready" <<'PY' &
import socket
import sys
import time
with socket.socket() as sock:
    sock.bind(("0.0.0.0", int(sys.argv[1])))
    sock.listen()
    open(sys.argv[2], "w").close()
    time.sleep(30)
PY
busy_pid=$!
for _ in {1..100}; do
    [[ -e "$TEST_TEMP/busy-ready" ]] && break
    sleep 0.02
done
[[ -e "$TEST_TEMP/busy-ready" ]] || fail 'occupied-port fixture failed'
if vpsctl service tcping start --port "$busy_port"; then fail 'occupied port change unexpectedly succeeded'; fi
[[ "$before" == "$(sha256sum "$state" "$unit" "$runtime")" ]] || fail 'occupied port change altered files'
probe 127.0.0.1 "$old_port"
kill "$busy_pid"
wait "$busy_pid" || true
busy_pid=''

vpsctl service tcping start --port "$new_port"
check_enabled || fail 'port change disabled service'
jq -e --argjson port "$new_port" '.port==$port and .enabled==true' "$state" >/dev/null || fail 'port change state'
probe 127.0.0.1 "$new_port"
probe_closed 127.0.0.1 "$old_port"
if [[ -n "$namespace" ]]; then
    netns_probe "$root_ip" "$new_port" open
    netns_probe "$root_ip6" "$new_port" open
    netns_probe "$root_ip" "$old_port" closed
    netns_probe "$root_ip6" "$old_port" closed
fi
if [[ "${VPSCTL_TCPING_LIVE_UFW:-0}" == 1 ]]; then
    assert_rule "$new_port" tcping yes
    vpsctl network ufw rule list --json | jq -e --arg port "$old_port" \
        'any(.[]; .family=="ipv4" and .port==$port and .action=="allow")' >/dev/null ||
        fail 'port change removed pre-existing manual UFW rule'
    other_owner add
    other_owner_seeded=1
    assert_rule "$new_port" node:tcping-test yes
fi
printf 'PASS: idempotence, occupied-port preservation, successful port change\n'

vpsctl service tcping stop
check_disabled || fail 'stop left active or enabled service'
jq -e --argjson port "$new_port" '.port==$port and .enabled==false' "$state" >/dev/null || fail 'stop did not retain port and disabled state'
[[ -f "$runtime" && -f "$unit" && ! -e "$ready" ]] || fail 'stop did not retain files or remove readiness'
probe_closed 127.0.0.1 "$new_port"
if [[ -n "$namespace" ]]; then
    netns_probe "$root_ip" "$new_port" closed
    netns_probe "$root_ip6" "$new_port" closed
fi
jq -e '[.requirements[] | select(.owner=="tcping")] | length==0' "$fw" >/dev/null || fail 'stop retained UFW demand'
if [[ "${VPSCTL_TCPING_LIVE_UFW:-0}" == 1 ]]; then
    assert_rule "$new_port" tcping no
    assert_rule "$new_port" node:tcping-test yes
    other_owner clear
    other_owner_seeded=0
    vpsctl network ufw sync
    assert_rule "$new_port" tcping no
    vpsctl network ufw rule list --json | jq -e --arg port "$old_port" \
        'any(.[]; .family=="ipv4" and .port==$port and .action=="allow")' >/dev/null ||
        fail 'global sync removed manual UFW rule'
    printf 'PASS: live UFW manual/shared ownership and stopped global sync\n'
fi
vpsctl service tcping start
check_enabled || fail 'portless restart failed'
probe 127.0.0.1 "$new_port"
vpsctl service tcping uninstall
[[ ! -e "$state" && ! -e "$runtime" && ! -e "$unit" && ! -e "$ready" ]] || fail 'uninstall left owned files'
check_disabled || fail 'uninstall left active or enabled service'
jq -e '[.requirements[] | select(.owner=="tcping")] | length==0' "$fw" >/dev/null || fail 'uninstall retained UFW demand'
printf 'PASS: stop/restart/uninstall lifecycle\n'
