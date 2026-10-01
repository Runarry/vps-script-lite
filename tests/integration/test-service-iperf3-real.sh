#!/usr/bin/env bash
# Opt-in real acceptance on host-vps-scripts or its isolated Alpine VM.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
[[ "${VPSCTL_REAL_IPERF3_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_IPERF3_TEST=1 in the dedicated test environment\n'
    exit 0
}
((EUID == 0)) || {
    printf 'FAIL: real iperf3 acceptance requires root\n' >&2
    exit 4
}
for tool in bash jq python3 sha256sum timeout; do
    command -v "$tool" >/dev/null || {
        printf 'FAIL: missing %s\n' "$tool" >&2
        exit 3
    }
done
TEST_TEMP="$(mktemp -d /var/tmp/vpsctl-iperf3-real.XXXXXX)"
RESULT_DIR="${VPSCTL_IPERF3_RESULT_DIR:-$TEST_TEMP}"
mkdir -p -- "$RESULT_DIR"
exec > >(tee -a "$RESULT_DIR/acceptance.log") 2>&1
printf 'source=%s\n' "$TEST_ROOT"
sha256sum "$TEST_ROOT/bin/vpsctl" "$TEST_ROOT/commands/service/iperf3.sh"
# shellcheck source=/dev/null
. /etc/os-release
printf 'system=%s-%s kernel=%s boot_id=%s\n' "${ID:-unknown}" "${VERSION_ID:-unknown}" "$(uname -r)" "$(cat /proc/sys/kernel/random/boot_id)"
state='/var/lib/vpsctl/service/iperf3/state.json'
fw='/var/lib/vpsctl/network/ufw/state.json'
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null; then
    init=systemd
    unit='/etc/systemd/system/vpsctl-iperf3.service'
elif command -v rc-service >/dev/null && command -v rc-update >/dev/null; then
    init=openrc
    unit='/etc/init.d/vpsctl-iperf3'
else
    printf 'FAIL: no supported init manager\n' >&2
    exit 3
fi
printf 'init=%s\n' "$init"

# Refuse to replace an existing user's instance, even if currently stopped.
for path in "$state" "$unit" /var/log/vpsctl/iperf3.log /run/vpsctl/iperf3.pid /run/vpsctl-iperf3.pid; do
    [[ ! -e "$path" && ! -L "$path" ]] || {
        printf 'FAIL: pre-existing iperf3 path %s\n' "$path" >&2
        exit 3
    }
done
if [[ "$init" == systemd ]]; then
    ! systemctl is-active --quiet vpsctl-iperf3.service || exit 3
    ! systemctl is-enabled --quiet vpsctl-iperf3.service || exit 3
else
    ! rc-service vpsctl-iperf3 status >/dev/null 2>&1 || exit 3
    [[ ! -e /etc/runlevels/default/vpsctl-iperf3 ]] || exit 3
fi
if command -v ufw >/dev/null; then ufw status; else printf 'ufw=absent\n'; fi
if [[ -f "$fw" ]]; then
    jq -S '[.requirements[] | select(.owner!="iperf3")]' "$fw" >"$RESULT_DIR/ufw-unrelated-before.json"
    jq -e 'all(.requirements[]; .owner!="iperf3")' "$fw" >/dev/null || {
        printf 'FAIL: pre-existing iperf3 UFW demand\n'
        exit 3
    }
else printf '[]\n' >"$RESULT_DIR/ufw-unrelated-before.json"; fi

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
vpsctl() { bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes "$@"; }
check_enabled() {
    if [[ "$init" == systemd ]]; then
        systemctl is-active --quiet vpsctl-iperf3.service && systemctl is-enabled --quiet vpsctl-iperf3.service
    else rc-service vpsctl-iperf3 status >/dev/null 2>&1 && [[ -e /etc/runlevels/default/vpsctl-iperf3 ]]; fi
}
check_disabled() {
    if [[ "$init" == systemd ]]; then
        ! systemctl is-active --quiet vpsctl-iperf3.service && ! systemctl is-enabled --quiet vpsctl-iperf3.service
    else ! rc-service vpsctl-iperf3 status >/dev/null 2>&1 && [[ ! -e /etc/runlevels/default/vpsctl-iperf3 ]]; fi
}
service_pid() {
    if [[ "$init" == systemd ]]; then
        systemctl show -p MainPID --value vpsctl-iperf3.service
    else cat /run/vpsctl/iperf3.pid; fi
}
free_port() {
    python3 -B - <<'PY'
import socket
for _ in range(100):
    with socket.socket() as tcp, socket.socket(type=socket.SOCK_DGRAM) as udp:
        tcp.bind(("0.0.0.0", 0))
        port = tcp.getsockname()[1]
        try:
            udp.bind(("0.0.0.0", port))
        except OSError:
            continue
        print(port)
        break
else:
    raise SystemExit("could not find a free TCP+UDP port")
PY
}
probe_closed() {
    local -a runner=(python3)
    if [[ -n "${namespace:-}" && ("$1" == "${root_ip:-}" || "$1" == "${root_ip6:-}") ]]; then
        runner=(ip netns exec "$namespace" python3)
    fi
    "${runner[@]}" -B - "$1" "$2" <<'PY'
import socket
import sys
host, port = sys.argv[1], int(sys.argv[2])
family = socket.AF_INET6 if ":" in host else socket.AF_INET
try:
    with socket.socket(family) as connection:
        connection.settimeout(1)
        connection.connect((host, port))
except OSError:
    pass
else:
    raise SystemExit("unexpected listener on stopped port")
PY
}
client_case() {
    local name="$1" address="$2" port="$3"
    local -a runner=(iperf3)
    shift 3
    if [[ -n "${namespace:-}" && ("$address" == "${root_ip:-}" || "$address" == "${root_ip6:-}") ]]; then
        runner=(ip netns exec "$namespace" iperf3)
    fi
    timeout 15 "${runner[@]}" -c "$address" -p "$port" -t 1 -J "$@" >"$RESULT_DIR/$name.json"
    jq -e 'has("error")|not' "$RESULT_DIR/$name.json" >/dev/null || fail "$name returned a protocol error"
    jq -e '.end.sum_received.bytes>0 or .end.sum.bytes>0' "$RESULT_DIR/$name.json" >/dev/null || fail "$name transferred no data"
    printf 'PASS: client %s\n' "$name"
}
client_matrix() {
    local prefix="$1" address="$2" port="$3"
    client_case "$prefix-tcp-normal" "$address" "$port"
    client_case "$prefix-tcp-reverse" "$address" "$port" -R
    client_case "$prefix-tcp-multi" "$address" "$port" -P 3
    client_case "$prefix-tcp-multi-reverse" "$address" "$port" -P 3 -R
    client_case "$prefix-udp" "$address" "$port" -u -b 1M
    client_case "$prefix-udp-reverse" "$address" "$port" -u -b 1M -R
}
assert_firewall_demand() {
    local port="$1"
    jq -e --arg port "$port" '[.requirements[] | select(.owner=="iperf3" and .scope=="iperf3" and .port==$port and .family=="ipv4") | .proto] | sort==["tcp","udp"]' \
        "$fw" >/dev/null || fail 'missing IPv4 TCP+UDP iperf3 firewall demands'
}
assert_unrelated_firewall() {
    jq -S '[.requirements[] | select(.owner!="iperf3")]' "$fw" >"$RESULT_DIR/ufw-unrelated-after.json"
    cmp -s "$RESULT_DIR/ufw-unrelated-before.json" "$RESULT_DIR/ufw-unrelated-after.json" || fail 'unrelated firewall demands changed'
}
assert_live_rule() {
    local port="$1" owner="$2" present="$3" protocol="$4" inventory
    inventory="$(vpsctl network ufw rule list --json)"
    if [[ "$present" == yes ]]; then
        jq -e --arg port "$port" --arg owner "$owner" --arg protocol "$protocol" \
            'any(.[]; .family=="ipv4" and .kind=="input" and .proto==$protocol and .port==$port and (.owners|index($owner)))' \
            <<<"$inventory" >/dev/null || fail "missing $protocol $port UFW owner $owner"
    else
        jq -e --arg port "$port" --arg owner "$owner" --arg protocol "$protocol" \
            'all(.[]; .port!=$port or .proto!=$protocol or (.owners|index($owner)|not))' \
            <<<"$inventory" >/dev/null || fail "retained $protocol $port UFW owner $owner"
    fi
}
assert_manual_rule() {
    vpsctl network ufw rule list --json | jq -e --arg port "$old_port" \
        'any(.[]; .family=="ipv4" and .proto=="tcp" and .port==$port and .action=="allow")' >/dev/null || fail 'pre-existing manual TCP rule was removed'
}
other_owner() {
    IPERF3_TEST_ROOT="$TEST_ROOT" IPERF3_TEST_PORT="$new_port" IPERF3_TEST_DESIRED="$TEST_TEMP/other-owner.json" \
        bash -c '
        set -Eeuo pipefail
        source "$IPERF3_TEST_ROOT/lib/command.sh"
        source "$IPERF3_TEST_ROOT/lib/ufw.sh"
        vps_cmd_init iperf3-real-acceptance "$IPERF3_TEST_ROOT"
        if [[ "$1" == add ]]; then
            jq -n --arg port "$IPERF3_TEST_PORT" \
                '\''["tcp","udp"] | map({owner:"node:iperf3-test",kind:"input",family:"ipv4",proto:.,port:$port,source:"any",destination:"any",temporary:false})'\'' \
                >"$IPERF3_TEST_DESIRED"
        else printf "[]\n" >"$IPERF3_TEST_DESIRED"; fi
        vps_ufw_begin iperf3-other "$IPERF3_TEST_DESIRED"
        vps_ufw_commit
    ' _ "$1"
}
busy_pid=''
owned=0
namespace=''
root_if=''
root_ip=''
root_ip6=''
manual_port=''
other_owner_seeded=0
if [[ "${VPSCTL_IPERF3_NETNS:-0}" == 1 ]]; then command -v ip >/dev/null || fail 'network namespace test requires ip'; fi
if [[ "${VPSCTL_IPERF3_LIVE_UFW:-0}" == 1 ]]; then
    command -v ufw >/dev/null || fail 'live UFW acceptance requires existing UFW'
    [[ "$(LC_ALL=C ufw status | head -1)" == 'Status: active' ]] || fail 'live UFW acceptance requires already active UFW'
    if [[ -f "$fw" ]]; then
        jq -e 'all(.requirements[]; .owner!="node:iperf3-test" and .scope!="iperf3-other")' "$fw" >/dev/null || fail 'pre-existing shared-owner test demand'
    fi
fi
cleanup() {
    local result=$?
    trap - EXIT HUP INT TERM
    if [[ -n "$busy_pid" ]]; then
        kill "$busy_pid" 2>/dev/null || true
        wait "$busy_pid" 2>/dev/null || true
    fi
    if [[ -n "$namespace" ]]; then ip netns del "$namespace" 2>/dev/null || true; fi
    if [[ -n "$root_if" ]]; then ip link del "$root_if" 2>/dev/null || true; fi
    if ((owned)) && [[ -e "$state" || -e "$unit" ]]; then vpsctl service iperf3 uninstall || result=30; fi
    if ((other_owner_seeded)); then other_owner clear || result=30; fi
    if [[ -n "$manual_port" ]]; then ufw --force delete allow "$manual_port/tcp" || result=30; fi
    if ((result == 0)); then printf 'PASS: real iperf3 acceptance and owned-resource cleanup\n'; fi
    printf 'results=%s\n' "$RESULT_DIR"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
old_port="$(free_port)"
new_port="$(free_port)"
while [[ "$new_port" == "$old_port" ]]; do new_port="$(free_port)"; done
if [[ "${VPSCTL_IPERF3_LIVE_UFW:-0}" == 1 ]]; then
    inventory_before="$(vpsctl network ufw rule list --json)"
    while ! jq -e --arg old "$old_port" --arg new "$new_port" 'all(.[]; .port!=$old and .port!=$new)' <<<"$inventory_before" >/dev/null; do
        old_port="$(free_port)"
        new_port="$(free_port)"
        while [[ "$new_port" == "$old_port" ]]; do new_port="$(free_port)"; done
    done
fi
printf 'old_port=%s new_port=%s\n' "$old_port" "$new_port"

vpsctl service iperf3 status
vpsctl service iperf3
vpsctl --dry-run --install-deps service iperf3 start --port "$old_port"
[[ ! -e "$state" && ! -e "$unit" ]] || fail 'read/dry-run deployed service'
if [[ "${VPSCTL_IPERF3_LIVE_UFW:-0}" == 1 ]]; then
    ufw allow "$old_port/tcp" comment 'iperf3-accept-manual'
    manual_port="$old_port"
fi
owned=1
vpsctl --install-deps service iperf3 start --port "$old_port"
check_enabled || fail 'start did not activate and enable service'
jq -e --argjson port "$old_port" '.schema_version==1 and .port==$port and .enabled==true' "$state" >/dev/null || fail 'start state schema'
assert_firewall_demand "$old_port"
if [[ "${VPSCTL_IPERF3_LIVE_UFW:-0}" == 1 ]]; then
    assert_live_rule "$old_port" iperf3 yes tcp
    assert_live_rule "$old_port" iperf3 yes udp
fi
binary_path="$(command -v iperf3)"
binary_before="$(sha256sum "$binary_path")"
iperf3 --version
client_matrix ipv4 127.0.0.1 "$old_port"
ipv6=0
if python3 -B - <<'PY'; then
import socket
try:
    with socket.socket(socket.AF_INET6) as connection:
        connection.bind(("::1", 0))
except OSError:
    raise SystemExit(1)
PY
    ipv6=1
    client_matrix ipv6 ::1 "$old_port"
    if [[ -f /etc/default/ufw ]] && awk -F= '/^[[:space:]]*IPV6[[:space:]]*=/ {gsub(/[[:space:]"\047]/,"",$2); value=tolower($2)} END {exit(value!="yes")}' /etc/default/ufw; then
        jq -e --arg port "$old_port" '[.requirements[] | select(.owner=="iperf3" and .port==$port and .family=="ipv6") | .proto] | sort==["tcp","udp"]' "$fw" >/dev/null || fail 'missing IPv6 firewall demands'
    else printf 'NOT RUN: UFW IPv6 is not configured; native IPv6 traffic passed\n'; fi
else printf 'NOT RUN: IPv6 unavailable on host\n'; fi

if [[ "${VPSCTL_IPERF3_NETNS:-0}" == 1 ]]; then
    namespace="vipf${BASHPID}"
    root_if="vih${BASHPID}"
    peer_if="vip${BASHPID}"
    subnet=$((BASHPID % 180 + 40))
    root_ip="10.253.${subnet}.1"
    client_ip="10.253.${subnet}.2"
    ip netns add "$namespace"
    ip link add "$root_if" type veth peer name "$peer_if"
    ip link set "$peer_if" netns "$namespace"
    ip address add "$root_ip/24" dev "$root_if"
    ip link set "$root_if" up
    ip -n "$namespace" link set lo up
    ip -n "$namespace" link set "$peer_if" up
    ip -n "$namespace" address add "$client_ip/24" dev "$peer_if"
    if ((ipv6)); then
        printf -v ipv6_token '%x' "$((BASHPID % 65535))"
        root_ip6="fd7b:2026:${ipv6_token}::1"
        client_ip6="fd7b:2026:${ipv6_token}::2"
        ip -6 address add "$root_ip6/64" dev "$root_if" nodad
        ip -n "$namespace" -6 address add "$client_ip6/64" dev "$peer_if" nodad
    fi
    client_matrix peer-ipv4 "$root_ip" "$old_port"
    if ((ipv6)); then client_matrix peer-ipv6 "$root_ip6" "$old_port"; fi
    printf 'PASS: native IPv4/IPv6 traffic from an isolated peer\n'
fi

before="$(sha256sum "$state" "$unit")"
pid_before="$(service_pid)"
vpsctl service iperf3 start --port "$old_port"
[[ "$before" == "$(sha256sum "$state" "$unit")" && "$(service_pid)" == "$pid_before" ]] || fail 'same-port start rewrote files/restarted process'

# Native sockets verify both conflict protocols while the old instance stays live.
for proto in tcp udp udp-connected; do
    busy_port="$(free_port)"
    rm -f "$TEST_TEMP/busy-ready"
    python3 -B - "$proto" "$busy_port" "$TEST_TEMP/busy-ready" <<'PY' &
import socket
import sys
import time
with socket.socket(type=socket.SOCK_STREAM if sys.argv[1] == "tcp" else socket.SOCK_DGRAM) as sock:
    sock.bind(("0.0.0.0", int(sys.argv[2])))
    if sys.argv[1] == "tcp":
        sock.listen()
    elif sys.argv[1] == "udp-connected":
        sock.connect(("127.0.0.1", 9))
    open(sys.argv[3], "w").close()
    time.sleep(30)
PY
    busy_pid=$!
    for _ in {1..100}; do
        [[ -e "$TEST_TEMP/busy-ready" ]] && break
        sleep 0.02
    done
    [[ -e "$TEST_TEMP/busy-ready" ]] || fail 'conflict fixture failed to bind'
    if vpsctl service iperf3 start --port "$busy_port"; then fail "$proto conflict unexpectedly accepted"; fi
    [[ "$before" == "$(sha256sum "$state" "$unit")" && "$(service_pid)" == "$pid_before" ]] || fail "$proto conflict changed old service"
    kill "$busy_pid"
    wait "$busy_pid" || true
    busy_pid=''
done
client_case after-conflicts 127.0.0.1 "$old_port"
vpsctl service iperf3 start --port "$new_port"
check_enabled || fail 'port switch disabled service'
assert_firewall_demand "$new_port"
client_case switched-tcp 127.0.0.1 "$new_port"
client_case switched-udp 127.0.0.1 "$new_port" -u -b 1M
probe_closed 127.0.0.1 "$old_port"
if ((ipv6)); then
    client_case switched-ipv6 ::1 "$new_port"
    probe_closed ::1 "$old_port"
fi
if [[ -n "$namespace" ]]; then
    client_case switched-peer-tcp "$root_ip" "$new_port"
    client_case switched-peer-udp "$root_ip" "$new_port" -u -b 1M
    probe_closed "$root_ip" "$old_port"
    if ((ipv6)); then
        client_case switched-peer-ipv6 "$root_ip6" "$new_port"
        probe_closed "$root_ip6" "$old_port"
    fi
fi
if [[ "${VPSCTL_IPERF3_LIVE_UFW:-0}" == 1 ]]; then
    assert_live_rule "$new_port" iperf3 yes tcp
    assert_live_rule "$new_port" iperf3 yes udp
    assert_live_rule "$old_port" iperf3 no tcp
    assert_live_rule "$old_port" iperf3 no udp
    assert_manual_rule
    other_owner add
    other_owner_seeded=1
    assert_live_rule "$new_port" node:iperf3-test yes tcp
    assert_live_rule "$new_port" node:iperf3-test yes udp
fi

vpsctl service iperf3 stop
check_disabled || fail 'stop left service active/enabled'
jq -e --argjson port "$new_port" '.port==$port and .enabled==false' "$state" >/dev/null || fail 'stop lost port/disabled intent'
[[ -f "$unit" ]] || fail 'stop removed service configuration'
probe_closed 127.0.0.1 "$new_port"
jq -e 'all(.requirements[]; .owner!="iperf3")' "$fw" >/dev/null || fail 'stop retained UFW demand'
if [[ -n "$namespace" ]]; then
    probe_closed "$root_ip" "$new_port"
    if ((ipv6)); then probe_closed "$root_ip6" "$new_port"; fi
fi
if [[ "${VPSCTL_IPERF3_LIVE_UFW:-0}" == 1 ]]; then
    vpsctl network ufw sync
    assert_live_rule "$new_port" iperf3 no tcp
    assert_live_rule "$new_port" iperf3 no udp
    assert_live_rule "$new_port" node:iperf3-test yes tcp
    assert_live_rule "$new_port" node:iperf3-test yes udp
    assert_manual_rule
    other_owner clear
    other_owner_seeded=0
    vpsctl network ufw sync
    assert_live_rule "$new_port" iperf3 no tcp
    assert_live_rule "$new_port" iperf3 no udp
    assert_manual_rule
    printf 'PASS: live UFW borrowed/manual/shared ownership and stopped global sync\n'
fi
assert_unrelated_firewall
vpsctl service iperf3 restart
check_enabled || fail 'restart did not activate and enable service'
client_case restarted 127.0.0.1 "$new_port"
vpsctl service iperf3 logs
vpsctl service iperf3 uninstall
[[ ! -e "$state" && ! -e "$unit" && ! -e /var/log/vpsctl/iperf3.log && ! -e /run/vpsctl/iperf3.pid && ! -e /run/vpsctl-iperf3.pid ]] || fail 'uninstall left owned files'
check_disabled || fail 'uninstall left service active/enabled'
[[ "$(sha256sum "$binary_path")" == "$binary_before" ]] || fail 'uninstall removed/changed native package binary'
jq -e 'all(.requirements[]; .owner!="iperf3")' "$fw" >/dev/null || fail 'uninstall retained UFW demand'
assert_unrelated_firewall
owned=0
printf 'PASS: idempotence, TCP/UDP conflict preservation, port switch, stop/restart/logs/uninstall, retained package\n'
