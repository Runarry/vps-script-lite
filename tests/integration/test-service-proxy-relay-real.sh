#!/usr/bin/env bash

# Destructive integration check for the dedicated host-vps-scripts machine.
# It uses unique nft table names and always removes them on exit.  This file is
# syntax-checked by tests/run.sh but is intentionally not run by that suite.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
TEST_TEMP="$(mktemp -d)"
readonly TEST_TEMP
TABLE_SUFFIX="$$"
PROXY_RELAY_FORWARD_TABLE4="vpsctl_relay_accept4_${TABLE_SUFFIX}"
PROXY_RELAY_FORWARD_TABLE6="vpsctl_relay_accept6_${TABLE_SUFFIX}"
export PROXY_RELAY_FORWARD_TABLE4 PROXY_RELAY_FORWARD_TABLE6
CLIENT_NS="vpsctl-relay-client-${TABLE_SUFFIX}"
SERVER_NS="vpsctl-relay-server-${TABLE_SUFFIX}"
ROOT_CLIENT_IF="vrc${TABLE_SUFFIX}"
ROOT_SERVER_IF="vrs${TABLE_SUFFIX}"
CLIENT_PEER_IF="vrcp${TABLE_SUFFIX}"
SERVER_PEER_IF="vrsp${TABLE_SUFFIX}"
OLD_IPV4_FORWARD=''
OLD_IPV6_FORWARD=''
SERVER_PIDS=()
READY_FILES=()

cleanup() {
    local pid
    for pid in "${SERVER_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
    for pid in "${SERVER_PIDS[@]}"; do wait "$pid" >/dev/null 2>&1 || true; done
    nft destroy table ip "$PROXY_RELAY_FORWARD_TABLE4" >/dev/null 2>&1 || true
    nft destroy table ip6 "$PROXY_RELAY_FORWARD_TABLE6" >/dev/null 2>&1 || true
    ip netns del "$CLIENT_NS" >/dev/null 2>&1 || true
    ip netns del "$SERVER_NS" >/dev/null 2>&1 || true
    ip link del "$ROOT_CLIENT_IF" >/dev/null 2>&1 || true
    ip link del "$ROOT_SERVER_IF" >/dev/null 2>&1 || true
    [[ -z "$OLD_IPV4_FORWARD" ]] || sysctl -q -w "net.ipv4.ip_forward=${OLD_IPV4_FORWARD}" >/dev/null 2>&1 || true
    [[ -z "$OLD_IPV6_FORWARD" ]] || sysctl -q -w "net.ipv6.conf.all.forwarding=${OLD_IPV6_FORWARD}" >/dev/null 2>&1 || true
    rm -rf -- "$TEST_TEMP"
}
trap cleanup EXIT

((EUID == 0)) || { printf 'FAIL: real relay nft test requires root\n' >&2; exit 4; }
for tool in jq nft sort cmp grep ip python3 sysctl; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'FAIL: missing %s\n' "$tool" >&2; exit 3; }
done

# shellcheck source=../../lib/command.sh
source "${TEST_ROOT}/lib/command.sh"
vps_cmd_init "relay real nft test" "$TEST_ROOT"
# shellcheck source=../../commands/service/proxy/relay-forward.sh
source "${TEST_ROOT}/commands/service/proxy/relay-forward.sh"

manifest="${TEST_TEMP}/relay.json"
cache="${TEST_TEMP}/cache.json"
batch="${TEST_TEMP}/rules.nft"
before_tables="${TEST_TEMP}/tables.before"
after_tables="${TEST_TEMP}/tables.after"

nft list tables | LC_ALL=C sort >"$before_tables"
jq -n '{schema_version:1,
    exits:[
        {id:"exit-real-v4",type:"direct",endpoint:{host:"198.51.100.20",port:443},network_hint:"tcp"},
        {id:"exit-real-v6",type:"direct",endpoint:{host:"2001:db8::20",port:8443},network_hint:"udp"}
    ],
    bindings:[],
    forwards:[
        {id:"forward-real-v4",name:"real-v4",exit_id:"exit-real-v4",listen_port_start:45100,listen_port_end:45110,network:"both",publish_address:"relay.example"},
        {id:"forward-real-v6",name:"real-v6",exit_id:"exit-real-v6",listen_port_start:45200,listen_port_end:45200,network:"udp",publish_address:"relay6.example"}
    ]}' >"$manifest"
jq -n '{schema_version:1,exits:{
    "exit-real-v4":{host:"198.51.100.20",ipv4:"198.51.100.20",ipv6:null},
    "exit-real-v6":{host:"2001:db8::20",ipv4:null,ipv6:"2001:db8::20"}
}}' >"$cache"

proxy_relay_forward_render_nft "$manifest" "$cache" >"$batch"
grep -Fq 'fib daddr type local' "$batch" || { printf 'FAIL: missing local-destination guard\n' >&2; exit 1; }
grep -Fq 'dnat to 198.51.100.20:443' "$batch" || { printf 'FAIL: missing fixed IPv4 target port\n' >&2; exit 1; }
grep -Fq 'dnat to [2001:db8::20]:8443' "$batch" || { printf 'FAIL: missing fixed IPv6 target port\n' >&2; exit 1; }
if grep -Eq '(^|[[:space:]])output([[:space:]]|$)' "$batch"; then
    printf 'FAIL: relay batch must not contain an OUTPUT chain\n' >&2
    exit 1
fi

proxy_relay_forward_nft_check "$batch"
proxy_relay_forward_nft_apply "$batch"
nft list table ip "$PROXY_RELAY_FORWARD_TABLE4" >/dev/null
nft list table ip6 "$PROXY_RELAY_FORWARD_TABLE6" >/dev/null

# Exercise the actual data path in isolated namespaces.  The echo servers return
# the source address they observed so the client can verify masquerading too.
printf -v IPV6_TOKEN '%x' "$((TABLE_SUFFIX % 65535))"
IPV4_CLIENT_ROOT="10.253.241.1"
IPV4_CLIENT="10.253.241.2"
IPV4_SERVER_ROOT="10.253.242.1"
IPV4_SERVER="10.253.242.2"
IPV6_CLIENT_ROOT="fd42:2026:${IPV6_TOKEN}:1::1"
IPV6_CLIENT="fd42:2026:${IPV6_TOKEN}:1::2"
IPV6_SERVER_ROOT="fd42:2026:${IPV6_TOKEN}:2::1"
IPV6_SERVER="fd42:2026:${IPV6_TOKEN}:2::2"

ip netns add "$CLIENT_NS"
ip netns add "$SERVER_NS"
ip link add "$ROOT_CLIENT_IF" type veth peer name "$CLIENT_PEER_IF"
ip link add "$ROOT_SERVER_IF" type veth peer name "$SERVER_PEER_IF"
ip link set "$CLIENT_PEER_IF" netns "$CLIENT_NS"
ip link set "$SERVER_PEER_IF" netns "$SERVER_NS"
ip -n "$CLIENT_NS" link set "$CLIENT_PEER_IF" name eth0
ip -n "$SERVER_NS" link set "$SERVER_PEER_IF" name eth0
ip link set "$ROOT_CLIENT_IF" up
ip link set "$ROOT_SERVER_IF" up
ip -n "$CLIENT_NS" link set lo up
ip -n "$SERVER_NS" link set lo up
ip -n "$CLIENT_NS" link set eth0 up
ip -n "$SERVER_NS" link set eth0 up
ip address add "${IPV4_CLIENT_ROOT}/24" dev "$ROOT_CLIENT_IF"
ip address add "${IPV4_SERVER_ROOT}/24" dev "$ROOT_SERVER_IF"
ip -6 address add "${IPV6_CLIENT_ROOT}/64" dev "$ROOT_CLIENT_IF" nodad
ip -6 address add "${IPV6_SERVER_ROOT}/64" dev "$ROOT_SERVER_IF" nodad
ip -n "$CLIENT_NS" address add "${IPV4_CLIENT}/24" dev eth0
ip -n "$SERVER_NS" address add "${IPV4_SERVER}/24" dev eth0
ip -n "$CLIENT_NS" -6 address add "${IPV6_CLIENT}/64" dev eth0 nodad
ip -n "$SERVER_NS" -6 address add "${IPV6_SERVER}/64" dev eth0 nodad
ip -n "$CLIENT_NS" route add default via "$IPV4_CLIENT_ROOT"
ip -n "$SERVER_NS" route add default via "$IPV4_SERVER_ROOT"
ip -n "$CLIENT_NS" -6 route add default via "$IPV6_CLIENT_ROOT"
ip -n "$SERVER_NS" -6 route add default via "$IPV6_SERVER_ROOT"

OLD_IPV4_FORWARD="$(sysctl -n net.ipv4.ip_forward)"
OLD_IPV6_FORWARD="$(sysctl -n net.ipv6.conf.all.forwarding)"
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q -w net.ipv6.conf.all.forwarding=1

jq -n --arg ipv4 "$IPV4_SERVER" --arg ipv6 "$IPV6_SERVER" '{schema_version:1,
    exits:[
        {id:"exit-connect-v4",type:"direct",endpoint:{host:$ipv4,port:45443},network_hint:"both"},
        {id:"exit-connect-v6",type:"direct",endpoint:{host:$ipv6,port:45444},network_hint:"both"}
    ],
    bindings:[],
    forwards:[
        {id:"forward-connect-v4",name:"connect-v4",exit_id:"exit-connect-v4",listen_port_start:45100,listen_port_end:45100,network:"both",publish_address:"relay.example"},
        {id:"forward-connect-v6",name:"connect-v6",exit_id:"exit-connect-v6",listen_port_start:45200,listen_port_end:45200,network:"both",publish_address:"relay6.example"}
    ]}' >"$manifest"
jq -n --arg ipv4 "$IPV4_SERVER" --arg ipv6 "$IPV6_SERVER" '{schema_version:1,exits:{
    "exit-connect-v4":{host:$ipv4,ipv4:$ipv4,ipv6:null},
    "exit-connect-v6":{host:$ipv6,ipv4:null,ipv6:$ipv6}
}}' >"$cache"
proxy_relay_forward_render_nft "$manifest" "$cache" >"$batch"
proxy_relay_forward_nft_check "$batch"
proxy_relay_forward_nft_apply "$batch"

SERVER_CODE='
import socket, sys
mode, host, port_text, ready = sys.argv[1:]
family = socket.AF_INET6 if ":" in host else socket.AF_INET
kind = socket.SOCK_STREAM if mode == "tcp" else socket.SOCK_DGRAM
sock = socket.socket(family, kind)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind((host, int(port_text)))
if mode == "tcp":
    sock.listen(1)
open(ready, "w", encoding="ascii").close()
if mode == "tcp":
    conn, peer = sock.accept()
    with conn:
        payload = conn.recv(128)
        conn.sendall(peer[0].encode() + b"|" + payload)
else:
    payload, peer = sock.recvfrom(128)
    sock.sendto(peer[0].encode() + b"|" + payload, peer)
'
CLIENT_CODE='
import socket, sys
mode, host, port_text, expected_source, label = sys.argv[1:]
family = socket.AF_INET6 if ":" in host else socket.AF_INET
kind = socket.SOCK_STREAM if mode == "tcp" else socket.SOCK_DGRAM
payload = ("probe-" + label).encode()
sock = socket.socket(family, kind)
sock.settimeout(5)
if mode == "tcp":
    sock.connect((host, int(port_text)))
    sock.sendall(payload)
    response = sock.recv(256)
else:
    sock.sendto(payload, (host, int(port_text)))
    response, _peer = sock.recvfrom(256)
expected = expected_source.encode() + b"|" + payload
if response != expected:
    raise SystemExit("unexpected relay response: %r != %r" % (response, expected))
'

start_server() {
    local mode="$1" host="$2" port="$3" label="$4" ready
    ready="${TEST_TEMP}/ready-${label}"
    ip netns exec "$SERVER_NS" python3 -c "$SERVER_CODE" "$mode" "$host" "$port" "$ready" &
    SERVER_PIDS+=("$!")
    READY_FILES+=("$ready")
}

run_client() {
    local mode="$1" host="$2" port="$3" expected_source="$4" label="$5"
    ip netns exec "$CLIENT_NS" python3 -c "$CLIENT_CODE" "$mode" "$host" "$port" "$expected_source" "$label"
}

start_server tcp "$IPV4_SERVER" 45443 tcp-v4
start_server udp "$IPV4_SERVER" 45443 udp-v4
start_server tcp "$IPV6_SERVER" 45444 tcp-v6
start_server udp "$IPV6_SERVER" 45444 udp-v6
all_ready=0
for _attempt in {1..100}; do
    all_ready=1
    for ready in "${READY_FILES[@]}"; do [[ -e "$ready" ]] || all_ready=0; done
    ((all_ready)) && break
    sleep 0.05
done
((all_ready)) || { printf 'FAIL: relay namespace servers did not become ready\n' >&2; exit 1; }

run_client tcp "$IPV4_CLIENT_ROOT" 45100 "$IPV4_SERVER_ROOT" tcp-v4
run_client udp "$IPV4_CLIENT_ROOT" 45100 "$IPV4_SERVER_ROOT" udp-v4
run_client tcp "$IPV6_CLIENT_ROOT" 45200 "$IPV6_SERVER_ROOT" tcp-v6
run_client udp "$IPV6_CLIENT_ROOT" 45200 "$IPV6_SERVER_ROOT" udp-v6
for pid in "${SERVER_PIDS[@]}"; do wait "$pid"; done
SERVER_PIDS=()

proxy_relay_forward_nft_clear

nft list tables | LC_ALL=C sort >"$after_tables"
cmp -s "$before_tables" "$after_tables" || {
    printf 'FAIL: nft table set changed after managed-table cleanup\n' >&2
    exit 1
}

printf 'PASS: real relay nft transaction test\n'
