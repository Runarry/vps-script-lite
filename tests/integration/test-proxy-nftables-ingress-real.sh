#!/usr/bin/env bash
# Dedicated-host, isolated real node ingress -> protocol relay acceptance.
# shellcheck disable=SC1091,SC2016
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
if [[ "${VPSCTL_PROXY_NFT_NETNS:-0}" != 1 ]]; then
    exec env VPSCTL_PROXY_NFT_NETNS=1 unshare --net --mount --propagation private -- bash "$0" "$@"
fi
result="${PROXY_NFT_EVIDENCE_DIR:?set a unique evidence directory}"
cores="${PROXY_NFT_CORES_DIR:?set the verified binary directory}"
mkdir -p "$result/root/usr/local/bin"
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$result/root"
export VPSCTL_ENV_INIT=systemd VPSCTL_ENV_PACKAGE_MANAGER=apt-get VPSCTL_ENV_ARCH=x86_64
export VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1
PIDS=()
cleanup() {
    local status=$? pid
    trap - EXIT
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    exit "$status"
}
trap cleanup EXIT
trap 'printf "FAIL: line=%s evidence=%s\n" "$LINENO" "$result" >&2' ERR
for tool in ip nft jq python3 curl ss nsenter unshare; do command -v "$tool" >/dev/null; done
source "$TEST_ROOT/lib/command.sh"
source "$TEST_ROOT/lib/nftables.sh"
source "$TEST_ROOT/commands/service/proxy/nftables.sh"
vps_cmd_init proxy-nft-ingress "$TEST_ROOT"
for module in common core hysteria2 protocols-sing-box protocols-xray nodes relay-uri relay-forward relay; do
    # shellcheck disable=SC1090
    source "$TEST_ROOT/commands/service/proxy/$module.sh"
done
proxy_common_init; proxy_relay_init; proxy_ensure_layout
cp "$cores/xray-26.9.30" "$result/root/usr/local/bin/xray"
cp "$cores/sing-box-1.14.2" "$result/root/usr/local/bin/sing-box"
ip link set lo up
unshare --net -- sleep 1800 &
client_pid=$!; PIDS+=("$client_pid")
for _ in {1..40}; do [[ "$(readlink "/proc/$client_pid/ns/net")" != "$(readlink /proc/self/ns/net)" ]] && break; sleep .05; done
ip link add proxy-main type veth peer name proxy-client
ip link set proxy-client netns "$client_pid"
ip address add 10.74.1.1/24 dev proxy-main
ip link set proxy-main up
nsenter -t "$client_pid" -n ip link set lo up
nsenter -t "$client_pid" -n ip address add 10.74.1.2/24 dev proxy-client
nsenter -t "$client_pid" -n ip link set proxy-client up
cat >"$result/target-http.py" <<'PY'
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body=b'native-nft-node-relay-ok'
        self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def log_message(self,*args):pass
ThreadingHTTPServer(('127.0.0.1',55999),Handler).serve_forever()
PY
python3 "$result/target-http.py" >"$result/http.log" 2>&1 &
http_pid=$!; PIDS+=("$http_pid")
wait_listener() {
    local port="$1" pid="$2" namespace="${3:-}" sockets
    for _ in {1..100}; do
        kill -0 "$pid" 2>/dev/null || return 1
        if [[ -z "$namespace" ]]; then sockets="$(ss -H -ltn)"; else sockets="$(nsenter -t "$namespace" -n ss -H -ltn)"; fi
        awk '{print $4}' <<<"$sockets" | grep -Eq ":${port}$" && return 0
        sleep .05
    done
    return 1
}
wait_listener 55999 "$http_pid"
vps_nft_state | jq '.enabled=true' >"$result/firewall.json"
vps_nft_save_state "$result/firewall.json"; vps_nft_apply
probe() { nsenter -t "$client_pid" -n curl --noproxy '' --socks5-hostname 127.0.0.1:55003 --connect-timeout 2 --max-time 3 -fsS http://127.0.0.1:55999/relay; }
start_core() {
    local binary="$1" config="$2" log="$3" namespace="${4:-}"
    if [[ -z "$namespace" ]]; then "$binary" run -c "$config" >"$log" 2>&1 &
    else nsenter -t "$namespace" -n "$binary" run -c "$config" >"$log" 2>&1 & fi
    LAST_PID=$!; PIDS+=("$LAST_PID")
}
for core in xray sing-box; do
    dir="$result/$core"; mkdir -p "$dir"
    binary="$result/root/usr/local/bin/$core"
    version="$(_proxy_core_binary_version "$core" "$binary")"
    landing="$(proxy_prepare_node_json "$core" shadowsocks-aes-256-gcm node-0000000000000101 landing 127.0.0.1 55001 127.0.0.1 ingress.test /unused unused self-signed '' '' none 100 200 bbr)"
    entry="$(proxy_prepare_node_json "$core" shadowsocks-aes-256-gcm node-0000000000000102 entry 10.74.1.1 55002 10.74.1.1 ingress.test /unused unused self-signed '' '' none 100 200 bbr)"
    if [[ "$core" == xray ]]; then landing_uri="$(proxy_xray_render_uri "$landing")"; entry_uri="$(proxy_xray_render_uri "$entry")"
    else landing_uri="$(proxy_sb_render_uri "$landing")"; entry_uri="$(proxy_sb_render_uri "$entry")"; fi
    descriptor="$(proxy_relay_uri_parse "$landing_uri" shadowsocks-aes-256-gcm)"
    entry_descriptor="$(proxy_relay_uri_parse "$entry_uri" shadowsocks-aes-256-gcm)"
    jq -n --argjson node "$landing" '{schema_version:1,nodes:[$node]}' >"$dir/landing-nodes.json"
    jq -n --argjson node "$entry" '{schema_version:1,nodes:[$node]}' >"$dir/entry-nodes.json"
    proxy_relay_default >"$dir/empty-relay.json"
    jq -n --arg core "$core" --arg uri "$landing_uri" --argjson descriptor "$descriptor" \
        '{schema_version:1,exits:[{id:"exit-0000000000000101",name:"landing",type:"protocol",core:$core,profile:"shadowsocks-aes-256-gcm",uri:$uri,descriptor:$descriptor,endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint,created_at:"",updated_at:""}],bindings:[{id:"bind-0000000000000101",node_id:"node-0000000000000102",exit_id:"exit-0000000000000101",created_at:"",updated_at:""}],forwards:[]}' >"$dir/relay.json"
    proxy_render_config "$core" "$dir/landing-nodes.json" "$dir/empty-relay.json" "$version" >"$dir/landing.json"
    proxy_render_config "$core" "$dir/entry-nodes.json" "$dir/relay.json" "$version" >"$dir/entry.json"
    client_exit="$(jq -cn --arg core "$core" --arg uri "$entry_uri" --argjson descriptor "$entry_descriptor" \
        '{id:"exit-0000000000000102",name:"client",type:"protocol",core:$core,profile:"shadowsocks-aes-256-gcm",uri:$uri,descriptor:$descriptor,endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint}')"
    bundle="$(proxy_relay_render_outbound "$core" "$client_exit")"
    if [[ "$core" == sing-box ]]; then
        jq -n --argjson bundle "$bundle" '{log:{level:"debug"},inbounds:[{type:"socks",tag:"client",listen:"127.0.0.1",listen_port:55003}],outbounds:$bundle.outbounds,route:{rules:[{inbound:["client"],action:"route",outbound:$bundle.target_tag}],final:$bundle.target_tag}}' >"$dir/client.json"
        for config in landing entry client; do "$binary" check -c "$dir/$config.json" >"$dir/$config.check" 2>&1; done
    else
        jq -n --argjson bundle "$bundle" '{log:{loglevel:"debug"},inbounds:[{protocol:"socks",tag:"client",listen:"127.0.0.1",port:55003,settings:{auth:"noauth",udp:true}}],outbounds:$bundle.outbounds,routing:{rules:[{type:"field",inboundTag:["client"],outboundTag:$bundle.target_tag}]}}' >"$dir/client.json"
        for config in landing entry client; do "$binary" run -test -c "$dir/$config.json" >"$dir/$config.check" 2>&1; done
    fi
    start_core "$binary" "$dir/landing.json" "$dir/landing.log"; landing_pid="$LAST_PID"; wait_listener 55001 "$landing_pid"
    start_core "$binary" "$dir/entry.json" "$dir/entry.log"; entry_pid="$LAST_PID"; wait_listener 55002 "$entry_pid"
    start_core "$binary" "$dir/client.json" "$dir/client.log" "$client_pid"; socks_pid="$LAST_PID"; wait_listener 55003 "$socks_pid" "$client_pid"
    if probe >"$dir/default-denied.response" 2>"$dir/default-denied.err"; then echo 'FAIL: node ingress bypassed default deny'; exit 1; fi
    proxy_nft_nodes_desired "$dir/entry-nodes.json" >"$dir/desired.json"
    vps_nft_begin proxy-nodes "$dir/desired.json" force; vps_nft_commit
    [[ "$(probe)" == native-nft-node-relay-ok ]]
    nft -j list table inet vpsctl_firewall >"$dir/allowed-ruleset.json"
    jq -e 'any(.nftables[].rule // empty; .chain=="input" and any(.expr[];.counter.packets>0))' "$dir/allowed-ruleset.json" >/dev/null
    printf '[]\n' >"$dir/empty-desired.json"
    vps_nft_begin proxy-nodes "$dir/empty-desired.json"; vps_nft_commit
    # Existing proxy connections may be reusable; stop/restart client to force new ingress.
    kill "$socks_pid"; wait "$socks_pid" 2>/dev/null || true
    start_core "$binary" "$dir/client.json" "$dir/client-removed.log" "$client_pid"; socks_pid="$LAST_PID"; wait_listener 55003 "$socks_pid" "$client_pid"
    if probe >"$dir/removed-denied.response" 2>"$dir/removed-denied.err"; then echo 'FAIL: removed node requirement retained new ingress'; exit 1; fi
    for pid in "$landing_pid" "$entry_pid" "$socks_pid"; do kill "$pid"; wait "$pid" 2>/dev/null || true; done
    PIDS=("$client_pid" "$http_pid")
    printf 'PASS: %s %s peer ingress default-deny -> managed node -> ordinary TCP protocol relay -> HTTP; requirement removal blocks new ingress\n' "$core" "$version"
done
vps_nft_clear
echo 'PASS: native firewall real representative proxy node ingress, both cores'
