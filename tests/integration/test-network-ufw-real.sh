#!/usr/bin/env bash
# Opt-in destructive UFW acceptance for the dedicated host-vps-scripts host.
# shellcheck disable=SC2016 # Single-quoted jq filters contain jq variables.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT

[[ "${VPSCTL_REAL_UFW_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_UFW_TEST=1 on the dedicated host\n'
    exit 0
}
((EUID == 0)) || { printf 'FAIL: real UFW acceptance requires root\n' >&2; exit 4; }

for tool in apt-get awk bash cat cmp dpkg-query find flock grep ip ip6tables-save iptables-save jq nft python3 sha256sum sleep sort ssh sshd sysctl systemctl tar tee timeout xargs; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'FAIL: missing %s\n' "$tool" >&2; exit 3; }
done

. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] || {
    printf 'FAIL: this recorded acceptance is restricted to Debian 13\n' >&2
    exit 3
}

exec 9>/run/lock/vpsctl-ufw-real.lock
flock -n 9 || { printf 'FAIL: another real UFW acceptance is active\n' >&2; exit 3; }

TEST_TEMP="$(mktemp -d /var/tmp/vpsctl-ufw-real.XXXXXX)"
readonly TEST_TEMP
BASELINE="$TEST_TEMP/baseline"
mkdir -p -- "$BASELINE"
RESULT_DIR="${VPSCTL_UFW_RESULT_DIR:-/var/tmp/vpsctl-ufw-results}"
mkdir -p -- "$RESULT_DIR"
RESULT_LOG="$RESULT_DIR/network-ufw-real.log"
: >"$RESULT_LOG"
exec > >(tee -a "$RESULT_LOG") 2>&1

suffix="${BASHPID}"
CLIENT_NS="vpsctl-ufw-c-${suffix}"
ROOT_IF="vuc${suffix}"
PEER_IF="vup${suffix}"
third_octet=$((BASHPID % 180 + 30))
IPV4_ROOT="10.254.${third_octet}.1"
IPV4_CLIENT="10.254.${third_octet}.2"
printf -v IPV6_TOKEN '%x' "$((BASHPID % 65535))"
IPV6_ROOT="fd7a:2026:${IPV6_TOKEN}::1"
IPV6_CLIENT="fd7a:2026:${IPV6_TOKEN}::2"
PORT_BASE=$((43000 + BASHPID % 1000 * 8))
((PORT_BASE <= 65520)) || PORT_BASE=53100
TCP_PORT=$PORT_BASE
UDP_PORT=$((PORT_BASE + 1))
CRUD_PORT_A=$((PORT_BASE + 2))
CRUD_PORT_B=$((PORT_BASE + 3))
CRUD_PORT_C=$((PORT_BASE + 4))
BLOCK_PORT=$((PORT_BASE + 5))
SERVER_PIDS=()
SYSCTL_CAPTURED=0
PACKAGE_BASELINE=''

vpsctl() {
    bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes "$@"
}

package_status() {
    local status
    status="$(dpkg-query -W -f='${Status}\n' ufw 2>/dev/null || true)"
    [[ "$status" == 'install ok installed' ]] && printf 'installed\n' || printf 'absent\n'
}

hash_file() {
    [[ -e "$1" ]] && sha256sum -- "$1" | awk '{print $1}' || printf 'absent\n'
}

code_fingerprint() {
    find "$TEST_ROOT" -type f -not -path '*/.git/*' -print0 |
        LC_ALL=C sort -z |
        xargs -0 sha256sum |
        sha256sum |
        awk '{print $1}'
}

snapshot_paths() {
    local path
    : >"$BASELINE/paths.present"
    for path in etc/ufw etc/default/ufw var/lib/ufw var/lib/vpsctl/network/ufw; do
        if [[ -e "/$path" || -L "/$path" ]]; then
            printf '%s\n' "$path" >>"$BASELINE/paths.present"
        fi
    done
    if [[ -s "$BASELINE/paths.present" ]]; then
        tar -C / -cpf "$BASELINE/paths.tar" -T "$BASELINE/paths.present"
    fi
}

restore_paths() {
    local path
    for path in /etc/ufw /etc/default/ufw /var/lib/ufw /var/lib/vpsctl/network/ufw; do
        [[ "$path" == /etc/ufw || "$path" == /etc/default/ufw || "$path" == /var/lib/ufw || "$path" == /var/lib/vpsctl/network/ufw ]] || return 1
        rm -rf -- "$path"
    done
    [[ ! -f "$BASELINE/paths.tar" ]] || tar -C / -xpf "$BASELINE/paths.tar"
}

capture_sysctls() {
    local key
    : >"$BASELINE/sysctls"
    for key in \
        net.ipv4.ip_forward net.ipv6.conf.default.forwarding net.ipv6.conf.all.forwarding \
        net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter \
        net.ipv4.icmp_echo_ignore_broadcasts net.ipv4.icmp_ignore_bogus_error_responses \
        net.ipv4.icmp_echo_ignore_all net.ipv4.conf.all.log_martians \
        net.ipv4.conf.default.log_martians net.ipv6.conf.all.accept_redirects \
        net.ipv6.conf.default.accept_redirects; do
        if sysctl -n "$key" >/dev/null 2>&1; then
            printf '%s=%s\n' "$key" "$(sysctl -n "$key")" >>"$BASELINE/sysctls"
        fi
    done
    SYSCTL_CAPTURED=1
}

restore_sysctls() {
    local assignment
    ((SYSCTL_CAPTURED == 1)) || return 0
    while IFS= read -r assignment; do
        [[ -n "$assignment" ]] || continue
        sysctl -q -w "$assignment" >/dev/null || return 1
    done <"$BASELINE/sysctls"
}

snapshot_netfilter() {
    nft list ruleset >"$BASELINE/nft.rules"
    iptables-save >"$BASELINE/iptables.rules"
    ip6tables-save >"$BASELINE/ip6tables.rules"
}

restore_netfilter_if_needed() {
    local now="$TEST_TEMP/nft.after" restore="$TEST_TEMP/nft.restore"
    nft list ruleset >"$now"
    if ! cmp -s -- "$BASELINE/nft.rules" "$now"; then
        printf 'WARN: netfilter differs after UFW cleanup; restoring the captured ruleset atomically\n'
        { printf 'flush ruleset\n'; cat -- "$BASELINE/nft.rules"; } >"$restore"
        nft -c -f "$restore" && nft -f "$restore" || return 1
    fi
    iptables-save | cmp -s -- "$BASELINE/iptables.rules" - || return 1
    ip6tables-save | cmp -s -- "$BASELINE/ip6tables.rules" - || return 1
}

stop_servers() {
    local pid
    for pid in "${SERVER_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
    for pid in "${SERVER_PIDS[@]}"; do wait "$pid" >/dev/null 2>&1 || true; done
    SERVER_PIDS=()
}

cleanup() {
    local original_status=$? cleanup_status=0
    trap - EXIT HUP INT TERM
    stop_servers
    ip netns del "$CLIENT_NS" >/dev/null 2>&1 || true
    ip link del "$ROOT_IF" >/dev/null 2>&1 || true
    if command -v ufw >/dev/null 2>&1; then ufw --force disable >/dev/null 2>&1 || cleanup_status=1; fi
    if [[ "$(package_status)" == installed ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y ufw >/dev/null || cleanup_status=1
    fi
    restore_sysctls || cleanup_status=1
    restore_paths || cleanup_status=1
    systemctl daemon-reload >/dev/null 2>&1 || true
    restore_netfilter_if_needed || cleanup_status=1
    [[ "$(package_status)" == "$PACKAGE_BASELINE" ]] || cleanup_status=1
    if ((cleanup_status == 0)); then
        printf 'PASS: package, UFW paths, sysctls, and netfilter baseline restored\n'
        rm -rf -- "$TEST_TEMP"
    else
        printf 'FAIL: cleanup did not reproduce the captured baseline; evidence retained at %s\n' "$TEST_TEMP" >&2
    fi
    ((original_status != 0)) || original_status=$((cleanup_status == 0 ? 0 : 30))
    exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

assert_jq() {
    local json="$1" label="$2"
    shift 2
    jq -e "$@" <<<"$json" >/dev/null || {
        printf 'FAIL: %s\n' "$label" >&2
        return 1
    }
}

rule_inventory() {
    vpsctl network ufw rule list --json
}

setup_namespace() {
    ip netns add "$CLIENT_NS"
    ip link add "$ROOT_IF" type veth peer name "$PEER_IF"
    ip link set "$PEER_IF" netns "$CLIENT_NS"
    ip -n "$CLIENT_NS" link set "$PEER_IF" name eth0
    ip link set "$ROOT_IF" up
    ip -n "$CLIENT_NS" link set lo up
    ip -n "$CLIENT_NS" link set eth0 up
    ip address add "${IPV4_ROOT}/24" dev "$ROOT_IF"
    ip -6 address add "${IPV6_ROOT}/64" dev "$ROOT_IF" nodad
    ip -n "$CLIENT_NS" address add "${IPV4_CLIENT}/24" dev eth0
    ip -n "$CLIENT_NS" -6 address add "${IPV6_CLIENT}/64" dev eth0 nodad
}

SERVER_CODE='
import socket, sys
mode, host, port_text, ready = sys.argv[1:]
family = socket.AF_INET6 if ":" in host else socket.AF_INET
kind = socket.SOCK_STREAM if mode == "tcp" else socket.SOCK_DGRAM
s = socket.socket(family, kind)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((host, int(port_text)))
if mode == "tcp": s.listen(4)
open(ready, "w", encoding="ascii").close()
if mode == "tcp":
    c, _ = s.accept()
    with c:
        p = c.recv(64)
        c.sendall(b"ufw-ok|" + p)
else:
    p, peer = s.recvfrom(64)
    s.sendto(b"ufw-ok|" + p, peer)
'

CLIENT_CODE='
import socket, sys
mode, host, port_text = sys.argv[1:]
family = socket.AF_INET6 if ":" in host else socket.AF_INET
kind = socket.SOCK_STREAM if mode == "tcp" else socket.SOCK_DGRAM
s = socket.socket(family, kind)
s.settimeout(2)
p = (mode + "-probe").encode()
if mode == "tcp":
    s.connect((host, int(port_text)))
    s.sendall(p)
    r = s.recv(64)
else:
    s.sendto(p, (host, int(port_text)))
    r, _ = s.recvfrom(64)
if r != b"ufw-ok|" + p: raise SystemExit("unexpected response")
'

start_server() {
    local mode="$1" host="$2" port="$3" label="$4" ready
    ready="$TEST_TEMP/ready-$label"
    rm -f -- "$ready"
    python3 -c "$SERVER_CODE" "$mode" "$host" "$port" "$ready" &
    SERVER_PIDS+=("$!")
    for _attempt in {1..100}; do [[ -e "$ready" ]] && return 0; sleep 0.05; done
    printf 'FAIL: server %s did not become ready\n' "$label" >&2
    return 1
}

probe_allowed() {
    ip netns exec "$CLIENT_NS" python3 -c "$CLIENT_CODE" "$1" "$2" "$3"
}

probe_blocked() {
    if timeout 4 ip netns exec "$CLIENT_NS" python3 -c "$CLIENT_CODE" "$1" "$2" "$3" >/dev/null 2>&1; then
        printf 'FAIL: unmanaged %s/%s unexpectedly crossed UFW INPUT\n' "$3" "$1" >&2
        return 1
    fi
}

PACKAGE_BASELINE="$(package_status)"
[[ "$PACKAGE_BASELINE" == absent ]] || {
    printf 'FAIL: dedicated baseline requires UFW to be uninstalled\n' >&2
    exit 3
}
snapshot_paths
snapshot_netfilter
printf 'INFO: baseline nft=%s etc-ufw=%s code=%s\n' \
    "$(hash_file "$BASELINE/nft.rules")" \
    "$(hash_file "$BASELINE/paths.tar")" \
    "$(code_fingerprint)"

vpsctl --install-deps network ufw install
vpsctl network ufw install
command -v ufw >/dev/null
capture_sysctls
LC_ALL=C ufw status | grep -Fqx 'Status: inactive'
systemctl is-enabled --quiet ufw.service
printf 'PASS: install leaves UFW inactive and persistent\n'

vpsctl network ufw ipv6 on
vpsctl network ufw enable
LC_ALL=C ufw status | grep -Fqx 'Status: active'
inventory="$(rule_inventory)"
ssh_port="$(sshd -T | awk '$1 == "port" {print $2; exit}')"
connection="${SSH_CONNECTION:-}"
[[ -n "$connection" ]] || { printf 'FAIL: acceptance must run from an SSH session\n' >&2; exit 3; }
connection_port="${connection##* }"
assert_jq "$inventory" 'effective SSH port was not linked before enable' --arg port "$ssh_port" \
    'any(.[]; (.owners | index("ssh")) and .kind == "input" and .proto == "tcp" and .port == $port)'
assert_jq "$inventory" 'current SSH connection port was not linked before enable' --arg port "$connection_port" \
    'any(.[]; (.owners | index("ssh")) and .kind == "input" and .proto == "tcp" and .port == $port)'
printf 'PASS: first enable preserved effective and current SSH ports\n'

vpsctl network ufw rule add --action allow --direction in --proto tcp --port "$CRUD_PORT_A" --family ipv4 --comment accept-crud-a
inventory="$(rule_inventory)"
crud_id="$(jq -r --arg port "$CRUD_PORT_A" '.[] | select(.port == $port and .comment == "accept-crud-a") | .id' <<<"$inventory")"
crud_number="$(jq -r --arg id "$crud_id" '.[] | select(.id == $id) | .number' <<<"$inventory")"
[[ "$crud_id" =~ ^[a-f0-9]{64}$ && "$crud_number" =~ ^[1-9][0-9]*$ ]]
vpsctl network ufw rule add --action deny --direction in --proto udp --port "$CRUD_PORT_B" --family ipv4 --position 1 --comment accept-crud-b
inventory="$(rule_inventory)"
inserted_number="$(jq -r --arg port "$CRUD_PORT_B" '.[] | select(.port == $port and .comment == "accept-crud-b") | .number' <<<"$inventory")"
[[ "$inserted_number" == 1 ]]
vpsctl network ufw rule edit --id "$crud_id" --port "$CRUD_PORT_C" --comment accept-crud-edited
inventory="$(rule_inventory)"
assert_jq "$inventory" 'rule edit did not replace the selected rule' --arg old "$CRUD_PORT_A" --arg new "$CRUD_PORT_C" \
    'all(.[]; .port != $old) and any(.[]; .port == $new and .comment == "accept-crud-edited")'
edited_id="$(jq -r --arg port "$CRUD_PORT_C" '.[] | select(.port == $port and .comment == "accept-crud-edited") | .id' <<<"$inventory")"
vpsctl network ufw rule delete --id "$edited_id"
vpsctl network ufw rule delete --number 1
inventory="$(rule_inventory)"
assert_jq "$inventory" 'CRUD rules remained after delete' --arg a "$CRUD_PORT_A" --arg b "$CRUD_PORT_B" --arg c "$CRUD_PORT_C" \
    'all(.[]; .port != $a and .port != $b and .port != $c)'
printf 'PASS: public rule CRUD, stable ID, and insertion order\n'

apps="$(vpsctl network ufw app list)"
grep -F 'OpenSSH' <<<"$apps" >/dev/null
vpsctl network ufw app info OpenSSH | grep -F 'OpenSSH' >/dev/null
vpsctl network ufw app default deny
grep -Fqx 'DEFAULT_APPLICATION_POLICY="DROP"' /etc/default/ufw
vpsctl network ufw app default skip
grep -Fqx 'DEFAULT_APPLICATION_POLICY="SKIP"' /etc/default/ufw
vpsctl network ufw app update OpenSSH
vpsctl network ufw app update all
vpsctl network ufw default incoming reject
grep -Fqx 'DEFAULT_INPUT_POLICY="REJECT"' /etc/default/ufw
vpsctl network ufw default incoming deny
grep -Fqx 'DEFAULT_INPUT_POLICY="DROP"' /etc/default/ufw
vpsctl network ufw default routed allow
grep -Fqx 'DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw
vpsctl network ufw default routed deny
grep -Fqx 'DEFAULT_FORWARD_POLICY="DROP"' /etc/default/ufw
vpsctl network ufw logging high
LC_ALL=C ufw status verbose | grep -F 'Logging: on (high)' >/dev/null
vpsctl network ufw logging off
LC_ALL=C ufw status verbose | grep -F 'Logging: off' >/dev/null
vpsctl network ufw logging low
LC_ALL=C ufw status verbose | grep -F 'Logging: on (low)' >/dev/null
printf 'PASS: application profiles, default policies, and logging controls\n'

setup_namespace
start_server tcp "$IPV4_ROOT" "$BLOCK_PORT" blocked-v4-tcp
start_server udp "$IPV4_ROOT" "$((BLOCK_PORT + 1))" blocked-v4-udp
start_server tcp "$IPV6_ROOT" "$BLOCK_PORT" blocked-v6-tcp
start_server udp "$IPV6_ROOT" "$((BLOCK_PORT + 1))" blocked-v6-udp
probe_blocked tcp "$IPV4_ROOT" "$BLOCK_PORT"
probe_blocked udp "$IPV4_ROOT" "$((BLOCK_PORT + 1))"
probe_blocked tcp "$IPV6_ROOT" "$BLOCK_PORT"
probe_blocked udp "$IPV6_ROOT" "$((BLOCK_PORT + 1))"
stop_servers

vpsctl network ufw rule add --action allow --direction in --proto tcp --port "$TCP_PORT" --family both --comment accept-input-tcp
vpsctl network ufw rule add --action allow --direction in --proto udp --port "$UDP_PORT" --family both --comment accept-input-udp
start_server tcp "$IPV4_ROOT" "$TCP_PORT" allow-v4-tcp
start_server udp "$IPV4_ROOT" "$UDP_PORT" allow-v4-udp
start_server tcp "$IPV6_ROOT" "$TCP_PORT" allow-v6-tcp
start_server udp "$IPV6_ROOT" "$UDP_PORT" allow-v6-udp
probe_allowed tcp "$IPV4_ROOT" "$TCP_PORT"
probe_allowed udp "$IPV4_ROOT" "$UDP_PORT"
probe_allowed tcp "$IPV6_ROOT" "$TCP_PORT"
probe_allowed udp "$IPV6_ROOT" "$UDP_PORT"
for pid in "${SERVER_PIDS[@]}"; do wait "$pid"; done
SERVER_PIDS=()
printf 'PASS: real IPv4/IPv6 TCP/UDP INPUT data path\n'

inventory="$(rule_inventory)"
while IFS= read -r owned_id; do
    vpsctl network ufw rule delete --id "$owned_id"
done < <(jq -r '.[] | select(.comment == "accept-input-tcp" or .comment == "accept-input-udp") | .id' <<<"$inventory")

vpsctl network ufw disable
LC_ALL=C ufw status | grep -Fqx 'Status: inactive'
vpsctl network ufw enable
LC_ALL=C ufw status | grep -Fqx 'Status: active'
printf 'PASS: disable and re-enable preserve reconciled SSH requirements\n'

if [[ "${VPSCTL_UFW_BASIC_ONLY:-0}" == 1 ]]; then
    printf 'PASS: network UFW basic real acceptance\n'
    exit 0
fi

VPSCTL_UFW_LINKAGE_CHILD=1 \
    bash "$TEST_ROOT/tests/integration/test-ufw-linkage-real.sh"

vpsctl network ufw uninstall
[[ "$(package_status)" == absent ]]
[[ -d /var/lib/vpsctl/network/ufw ]]
vpsctl --install-deps network ufw install
vpsctl network ufw install
LC_ALL=C ufw status | grep -Fqx 'Status: inactive'
vpsctl network ufw enable
inventory="$(rule_inventory)"
assert_jq "$inventory" 'ordinary uninstall/reinstall lost desired SSH ownership' 'any(.[]; (.owners | index("ssh")))'
vpsctl network ufw uninstall --purge --confirm-purge
[[ "$(package_status)" == absent && ! -e /var/lib/vpsctl/network/ufw ]]
vpsctl --install-deps network ufw install
vpsctl network ufw install
LC_ALL=C ufw status | grep -Fqx 'Status: inactive'
vpsctl network ufw uninstall --purge --confirm-purge
[[ "$(package_status)" == absent && ! -e /var/lib/vpsctl/network/ufw ]]
printf 'PASS: ordinary uninstall preserves linkage; purge removes state and permits a clean reinstall\n'

printf 'PASS: network UFW real acceptance\n'
