#!/usr/bin/env bash
# Dedicated-host HY2 acceptance. Never run this script on the editing host.
# HY2_CORES_DIR points to official, SHA256-verified binaries named xray-VERSION
# and sing-box-VERSION. HY2_EVIDENCE_DIR preserves configs, core logs and counters.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="${HY2_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
readonly TEST_ROOT
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
if [[ "${VPSCTL_HY2_NETNS:-0}" != 1 ]]; then
    exec env VPSCTL_HY2_NETNS=1 unshare --net --mount --propagation private -- bash "$SCRIPT_PATH" "$@"
fi

HY2_CORES_DIR="${HY2_CORES_DIR:?provide the verified release binary directory}"
HY2_EVIDENCE_DIR="${HY2_EVIDENCE_DIR:?provide a dedicated evidence directory}"
HY2_SCOPE="${HY2_SCOPE:-all}"
mkdir -p -- "$HY2_EVIDENCE_DIR"
TEST_TEMP="$HY2_EVIDENCE_DIR"
TEST_SYSTEM_ROOT="$TEST_TEMP/root"
mkdir -p -- "$TEST_SYSTEM_ROOT/usr/local/bin"
PIDS=()
CORE_PIDS=()
CASE_INDEX=0
ECHO_PID=''
TRAFFIC_FAILURES=0
cleanup() {
    local pid
    for pid in "${CORE_PIDS[@]}" "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${CORE_PIDS[@]}" "${PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT
trap 'printf "FAIL: line %s; evidence %s\n" "$LINENO" "$TEST_TEMP" >&2' ERR
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
stop_cores() {
    local pid
    for pid in "${CORE_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${CORE_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    CORE_PIDS=()
}
for tool in bash curl ip jq nft openssl python3 sha256sum ss nsenter unshare; do
    command -v "$tool" >/dev/null || fail "missing tool $tool"
done
[[ "$(id -u)" == 0 ]] || fail 'root required inside private namespace'
ip link set lo up
ip link add compat-default type dummy
ip link set compat-default up
ip address add 198.18.0.1/32 dev compat-default
ip -6 address add 2001:db8:ffff::1/128 dev compat-default
ip route add default dev compat-default
ip -6 route add default dev compat-default
ip address add 127.0.0.2/32 dev lo
ip -6 address add fd73::1/128 dev lo
unshare --net -- sleep 1800 &
CLIENT_NS_PID=$!
PIDS+=("$CLIENT_NS_PID")
for _ in {1..40}; do
    [[ "$(readlink "/proc/$CLIENT_NS_PID/ns/net")" != "$(readlink /proc/self/ns/net)" ]] && break
    sleep 0.05
done
ip link add hy2-main type veth peer name hy2-client
ip link set hy2-client netns "$CLIENT_NS_PID"
ip address add 10.73.2.1/24 dev hy2-main
ip -6 address add fd73:2::1/64 dev hy2-main nodad
ip address add 10.73.2.3/32 dev lo
ip -6 address add fd73:2::3/128 dev hy2-main nodad
ip link set hy2-main up
nsenter -t "$CLIENT_NS_PID" -n ip link set lo up
nsenter -t "$CLIENT_NS_PID" -n ip address add 10.73.2.2/24 dev hy2-client
nsenter -t "$CLIENT_NS_PID" -n ip -6 address add fd73:2::2/64 dev hy2-client nodad
nsenter -t "$CLIENT_NS_PID" -n ip link set hy2-client up
nsenter -t "$CLIENT_NS_PID" -n ip route add default via 10.73.2.1
nsenter -t "$CLIENT_NS_PID" -n ip -6 route add default via fd73:2::1

export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_ENV_INIT=systemd VPSCTL_ENV_PACKAGE_MANAGER=apt-get VPSCTL_ENV_ARCH=x86_64
export VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1
# shellcheck source=../../lib/command.sh
source "$TEST_ROOT/lib/command.sh"
# shellcheck source=../../lib/ufw.sh
source "$TEST_ROOT/lib/ufw.sh"
# shellcheck source=../../commands/service/proxy/ufw.sh
source "$TEST_ROOT/commands/service/proxy/ufw.sh"
vps_cmd_init 'HY2 real acceptance' "$TEST_ROOT"
for module in common core hysteria2 protocols-sing-box protocols-xray nodes relay-uri relay hysteria2-runtime; do
    # shellcheck disable=SC1090
    source "$TEST_ROOT/commands/service/proxy/$module.sh"
done
proxy_common_init
proxy_relay_init
proxy_ensure_layout
cp -- "$HY2_CORES_DIR/xray-26.9.30" "$TEST_SYSTEM_ROOT/usr/local/bin/xray"
cp -- "$HY2_CORES_DIR/sing-box-1.14.2" "$TEST_SYSTEM_ROOT/usr/local/bin/sing-box"
PROXY_RELAY_FILE="$TEST_TEMP/relay.json"
proxy_relay_default >"$PROXY_RELAY_FILE"
TLS_CERT="$TEST_TEMP/rsa.pem"
TLS_KEY="$TEST_TEMP/rsa.key"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 -subj '/CN=hy2.acceptance.test' \
    -addext 'subjectAltName=DNS:hy2.acceptance.test' -keyout "$TLS_KEY" -out "$TLS_CERT" >"$TEST_TEMP/cert.log" 2>&1
FIXTURE="$(dirname -- "$SCRIPT_PATH")/../fixtures/hy2-traffic.py"

binary() { printf '%s/%s-%s' "$HY2_CORES_DIR" "$1" "$2"; }
wait_listener() {
    local mode="$1" port="$2" pid="$3" namespace="${4:-}" sockets
    for _ in {1..160}; do
        kill -0 "$pid" 2>/dev/null || break
        if [[ -n "$namespace" ]]; then
            if [[ "$mode" == udp ]]; then sockets="$(nsenter -t "$namespace" -n ss -H -lun)"; else sockets="$(nsenter -t "$namespace" -n ss -H -ltn)"; fi
        elif [[ "$mode" == udp ]]; then sockets="$(ss -H -lun)"; else sockets="$(ss -H -ltn)"; fi
        awk '{print $4}' <<<"$sockets" | grep -Eq ":${port}$" && return 0
        sleep 0.05
    done
    fail "listener $mode/$port did not start"
}
wait_udp_bindings() {
    local port="$1" expected="$2" pid="$3" count
    for _ in {1..160}; do
        kill -0 "$pid" 2>/dev/null || break
        count="$(ss -H -lun | awk -v port="$port" '$4 ~ (":" port "$") {count++} END {print count+0}')"
        ((count >= expected)) && return 0
        sleep 0.05
    done
    fail "only $count/$expected UDP target bindings ready on $port"
}
start_core() {
    if [[ "${5:-}" == client ]]; then
        nsenter -t "$CLIENT_NS_PID" -n "$(binary "$1" "$2")" run -c "$3" >"$4" 2>&1 &
    else
        "$(binary "$1" "$2")" run -c "$3" >"$4" 2>&1 &
    fi
    CORE_PIDS+=("$!")
}
check_config() {
    local core="$1" version="$2" config="$3"
    if [[ "$core" == xray ]]; then
        "$(binary "$core" "$version")" run -test -c "$config" >"$config.check" 2>&1
    else
        "$(binary "$core" "$version")" check -c "$config" >"$config.check" 2>&1
    fi
}
make_node() {
    local core="$1" obfs="$2" hops="$3" listen="$4" publish="$5" node
    node="$(proxy_prepare_node_json "$core" hysteria2 node-0000000000000011 acceptance \
        "$listen" 53100 "$publish" hy2.acceptance.test /unused unused imported "$TLS_CERT" "$TLS_KEY" \
        "$obfs" 100 200 bbr auto '' '' '' "$hops")"
    jq -c --arg root "$TEST_SYSTEM_ROOT" '.tls.certificate_path=($root+.tls.certificate_path) |
        .tls.key_path=($root+.tls.key_path)' <<<"$node"
}
render_case() {
    local server="$1" sv="$2" client="$3" cv="$4" obfs="$5" interval="$6" options="$7" listen="$8" publish="$9"
    local node descriptor uri exit_json bundle hops=''
    CASE_INDEX=$((CASE_INDEX + 1))
    CASE_DIR="$TEST_TEMP/case-$(printf '%03d' "$CASE_INDEX")-$server-$sv-$client-$cv-$obfs-${interval:-off}"
    mkdir -p "$CASE_DIR"
    [[ -z "$interval" ]] || hops=53101-53103
    node="$(make_node "$server" "$obfs" "$hops" "$listen" "$publish")"
    jq -n --argjson node "$node" '{schema_version:1,nodes:[$node]}' >"$CASE_DIR/nodes.json"
    proxy_render_config "$server" "$CASE_DIR/nodes.json" "$PROXY_RELAY_FILE" "$sv" >"$CASE_DIR/server.json"
    if [[ "$server" == sing-box ]]; then
        jq '.log.level="debug"' "$CASE_DIR/server.json" >"$CASE_DIR/server-debug.json"
    else
        jq '.log.loglevel="debug"' "$CASE_DIR/server.json" >"$CASE_DIR/server-debug.json"
    fi
    mv "$CASE_DIR/server-debug.json" "$CASE_DIR/server.json"
    if [[ "$server" == xray ]]; then uri="$(proxy_xray_render_uri "$node")"; else uri="$(proxy_sb_render_uri "$node")"; fi
    printf '%s\n' "$uri" >"$CASE_DIR/uri.txt"
    descriptor="$(proxy_relay_uri_parse "$uri" hysteria2)"
    exit_json="$(jq -n --arg core "$client" --arg uri "$uri" --argjson descriptor "$descriptor" --argjson options "$options" \
        --arg interval "$interval" '{id:"exit-0000000000000011",type:"protocol",core:$core,profile:"hysteria2",uri:$uri,
        descriptor:$descriptor,endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint,client_options:$options} |
        if $interval != "" then .client_options.hop_interval=$interval else . end')"
    exit_json="$(proxy_relay_apply_client_options "$exit_json" "$TLS_CERT")"
    printf '%s\n' "$exit_json" >"$CASE_DIR/exit.json"
    bundle="$(proxy_relay_render_outbound "$client" "$exit_json" "$cv")"
    printf '%s\n' "$bundle" >"$CASE_DIR/bundle.json"
    if [[ -n "$interval" ]]; then
        jq -e '.endpoint.ports == "53100-53103" and .endpoint.port == 53100' <<<"$descriptor" >/dev/null ||
            fail 'client endpoint must include actual listener plus extra ports'
    fi
    if [[ "$client" == sing-box ]]; then
        if jq -e 'has("up_mbps")' <<<"$options" >/dev/null; then
            jq -e --argjson o "$options" '.outbounds[0] | .up_mbps==$o.up_mbps and .down_mbps==$o.down_mbps' <<<"$bundle" >/dev/null
        else
            jq -e '.outbounds[0] | has("up_mbps") or has("down_mbps") | not' <<<"$bundle" >/dev/null || fail 'auto client unexpectedly forced bandwidth'
        fi
    elif jq -e 'has("up_mbps")' <<<"$options" >/dev/null; then
        jq -e --argjson o "$options" '[.. | objects | select(has("brutalUp"))] |
            length==1 and .[0].brutalUp==($o.up_mbps*1000000|tostring) and .[0].brutalDown==($o.down_mbps*1000000|tostring)' \
            <<<"$bundle" >/dev/null
    else
        jq -e '[.. | objects | select(has("brutalUp") or has("brutalDown"))] | length==0' <<<"$bundle" >/dev/null ||
            fail 'auto Xray client unexpectedly forced bandwidth'
    fi
    if [[ "$client" == sing-box ]]; then
        jq -n --argjson b "$bundle" '{log:{level:"debug"},inbounds:[{type:"socks",tag:"client",listen:"127.0.0.1",listen_port:54100}],
            outbounds:$b.outbounds,route:{rules:[{inbound:["client"],action:"route",outbound:$b.target_tag}],final:$b.target_tag}}' >"$CASE_DIR/client.json"
    else
        jq -n --argjson b "$bundle" '{log:{loglevel:"debug"},inbounds:[{protocol:"socks",tag:"client",listen:"127.0.0.1",port:54100,
            settings:{auth:"noauth",udp:true}}],outbounds:$b.outbounds,
            routing:{rules:[{type:"field",inboundTag:["client"],outboundTag:$b.target_tag}]}}' >"$CASE_DIR/client.json"
    fi
    check_config "$server" "$sv" "$CASE_DIR/server.json"
    check_config "$client" "$cv" "$CASE_DIR/client.json"
    printf 'PASS: configs %s\n' "${CASE_DIR##*/}"
}

record_ports() {
    nft -j list table inet hy2_evidence >"$CASE_DIR/counters.json"
    python3 - "$CASE_DIR/counters.json" "${1:-$CASE_DIR/traffic.jsonl}" <<'PY'
import json,sys
rules=json.load(open(sys.argv[1]))["nftables"]
ports=[]
for item in rules:
    rule=item.get("rule",{})
    count=sum(expr.get("counter",{}).get("packets",0) for expr in rule.get("expr",[]))
    if count: ports.append(rule.get("comment"))
samples=[json.loads(line) for line in open(sys.argv[2])]
assert len(ports)>=2,("hopping did not visit multiple original destination ports",ports)
assert samples[-1]["elapsed"]>=16,("less than three fixed hopping intervals",samples[-1])
assert len(samples)>=16,("insufficient TCP/UDP continuity samples",len(samples))
kind="TCP/UDP" if samples[-1]["udp"]=="PASS" else "TCP (UDP failed separately)"
print("PASS: continuous",kind,"through >=3 intervals; destination ports",ports)
PY
}
run_case() {
    local server="$1" sv="$2" client="$3" cv="$4" obfs="$5" interval="$6" options="${7:-}" listen="${8:-::}" publish="${9:-10.73.2.1}" duration=0
    [[ -n "$options" ]] || options='{}'
    render_case "$server" "$sv" "$client" "$cv" "$obfs" "$interval" "$options" "$listen" "$publish"
    if ((CASE_INDEX <= ${HY2_SKIP_CASES:-0})); then
        printf 'REUSED: previously verified traffic case %s\n' "${CASE_DIR##*/}"
        return 0
    fi
    proxy_hy2_render_nft "$CASE_DIR/nodes.json" >"$CASE_DIR/hy2.nft"
    nft --check -f "$CASE_DIR/hy2.nft"
    nft -f "$CASE_DIR/hy2.nft"
    if [[ -n "$interval" ]]; then
        nft delete table inet hy2_evidence 2>/dev/null || true
        nft add table inet hy2_evidence
        nft 'add chain inet hy2_evidence prerouting { type filter hook prerouting priority -110; policy accept; }'
        for port in 53100 53101 53102 53103; do
            nft add rule inet hy2_evidence prerouting udp dport "$port" counter comment "port-$port"
        done
        duration=17
        [[ "$interval" != *-* ]] || duration=23
    fi
    start_core "$server" "$sv" "$CASE_DIR/server.json" "$CASE_DIR/server.log"
    wait_listener udp 53100 "${CORE_PIDS[-1]}"
    start_core "$client" "$cv" "$CASE_DIR/client.json" "$CASE_DIR/client.log" client
    wait_listener tcp 54100 "${CORE_PIDS[-1]}" "$CLIENT_NS_PID"
    if ! nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" continuous 54100 "$duration" >"$CASE_DIR/traffic.jsonl" 2>"$CASE_DIR/traffic.err"; then
        nft -j list ruleset >"$CASE_DIR/failed-ruleset.json"
        if grep -q '^PASS: TCP sample' "$CASE_DIR/traffic.err"; then
            nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" tcp-continuous 54100 "$duration" >"$CASE_DIR/tcp-only.jsonl" 2>"$CASE_DIR/tcp-only.err"
            [[ -z "$interval" ]] || record_ports "$CASE_DIR/tcp-only.jsonl"
            printf 'PASS: TCP continuity %s; UDP FAIL retained\n' "${CASE_DIR##*/}"
        fi
        stop_cores
        TRAFFIC_FAILURES=$((TRAFFIC_FAILURES + 1))
        printf 'FAIL: real TCP/UDP %s; inspect traffic.err and server.log\n' "${CASE_DIR##*/}"
        return 0
    fi
    [[ -z "$interval" ]] || record_ports
    stop_cores
    printf 'PASS: real TCP/UDP %s\n' "${CASE_DIR##*/}"
}
config_matrix() {
    local version feature opts interval obfs
    for version in 26.3.27 26.4.13 26.6.1 26.9.8 26.9.9 26.9.30; do
        "$(binary xray "$version")" version >"$TEST_TEMP/xray-$version.version"
        grep -Fq "Xray $version " "$TEST_TEMP/xray-$version.version" || fail "wrong Xray version $version"
        render_case xray "$version" xray "$version" none '' '{}' 127.0.0.1 127.0.0.1
        for feature in hop-ports hop-random gecko chrome-parrot bbr-profile; do
            proxy_hy2_capable xray "$version" "$feature" || continue
            opts='{}'
            interval=''
            obfs=none
            case "$feature" in
            hop-ports) interval=5 ;;
            hop-random) interval=5-7 ;;
            gecko) obfs=gecko ;;
            chrome-parrot) opts='{"chrome_parrot":false}' ;;
            bbr-profile) opts='{"bbr_profile":"standard"}' ;;
            esac
            render_case xray "$version" xray "$version" "$obfs" "$interval" "$opts" 127.0.0.1 127.0.0.1
        done
    done
    for version in 1.13.21 1.14.2; do
        "$(binary sing-box "$version")" version >"$TEST_TEMP/sing-box-$version.version"
        grep -Fxq "sing-box version $version" "$TEST_TEMP/sing-box-$version.version" || fail "wrong sing-box version $version"
        render_case sing-box "$version" sing-box "$version" none 5 '{}' 127.0.0.1 127.0.0.1
    done
    render_case sing-box 1.14.2 sing-box 1.14.2 gecko 5-7 '{"up_mbps":100,"down_mbps":200,"chrome_parrot":false,"bbr_profile":"standard"}' 127.0.0.1 127.0.0.1
}
traffic_matrix() {
    python3 "$FIXTURE" echo 127.0.0.1,127.0.0.2,::1,fd73::1 56001 >"$TEST_TEMP/echo.log" 2>&1 &
    ECHO_PID=$!
    PIDS+=("$ECHO_PID")
    wait_listener tcp 56001 "${PIDS[-1]}"
    local obfs
    for obfs in none salamander gecko; do
        run_case xray 26.9.30 sing-box 1.14.2 "$obfs" 5 '{}'
        run_case sing-box 1.14.2 xray 26.9.30 "$obfs" 5 '{}'
    done
    run_case sing-box 1.13.21 xray 26.4.13 none 5 '{}'
    run_case sing-box 1.13.21 xray 26.3.27 salamander 5 '{}'
    run_case xray 26.6.1 sing-box 1.14.2 salamander 5-7 '{}'
    run_case sing-box 1.14.2 xray 26.9.9 gecko 5-7 '{}'
    run_case sing-box 1.14.2 xray 26.9.8 gecko 5-7 '{}'
    run_case xray 26.9.30 sing-box 1.14.2 none 5-7 '{}'
    run_case sing-box 1.14.2 xray 26.9.30 none 5 '{"up_mbps":100,"down_mbps":200,"chrome_parrot":false,"bbr_profile":"standard"}' fd73:2::1 fd73:2::1
    run_case xray 26.9.30 sing-box 1.14.2 none 5 '{}' 10.73.2.1 10.73.2.1
    run_case sing-box 1.14.2 sing-box 1.14.2 gecko 5-7 '{}'
}
nft_scope() {
    local node target_pid echo_pid offbind_node
    mkdir -p "$TEST_TEMP/nft-scope"
    node="$(make_node sing-box none 53101-53103 :: 10.73.2.1)"
    jq -n --argjson node "$node" '{schema_version:1,nodes:[$node]}' >"$TEST_TEMP/nft-scope/nodes.json"
    proxy_hy2_render_nft "$TEST_TEMP/nft-scope/nodes.json" >"$TEST_TEMP/nft-scope/mapping.nft"
    nft add table ip vpsctl_proxy_forward4
    nft add table ip6 vpsctl_proxy_forward6
    nft -f "$TEST_TEMP/nft-scope/mapping.nft"
    nft list table ip vpsctl_proxy_forward4 >"$TEST_TEMP/nft-scope/forward4-preserved.txt"
    nft list table ip6 vpsctl_proxy_forward6 >"$TEST_TEMP/nft-scope/forward6-preserved.txt"
    # Explicit sockets preserve the source address of each UDP response. A
    # wildcard REDIRECT may choose either local IPv6 address on this interface.
    python3 "$FIXTURE" echo 10.73.2.1,fd73:2::1,10.73.2.3,fd73:2::3 53100 --marker base: >"$TEST_TEMP/nft-scope/base.log" 2>&1 &
    echo_pid=$!
    PIDS+=("$echo_pid")
    wait_udp_bindings 53100 4 "$echo_pid"
    python3 "$FIXTURE" echo 10.73.2.1,fd73:2::1,10.73.2.3,fd73:2::3 53101 --marker extra: >"$TEST_TEMP/nft-scope/extra.log" 2>&1 &
    echo_pid=$!
    PIDS+=("$echo_pid")
    wait_udp_bindings 53101 4 "$echo_pid"
    nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" udp 10.73.2.1 53101 --marker base:
    nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" udp fd73:2::1 53102 --marker base:
    nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" tcp 10.73.2.1 53101 --marker extra:
    nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" tcp fd73:2::1 53101 --marker extra:
    # No OUTPUT rule: unrelated locally initiated UDP must retain its destination.
    python3 "$FIXTURE" udp 10.73.2.1 53101 --marker extra:
    python3 "$FIXTURE" udp fd73:2::1 53101 --marker extra:

    unshare --net -- sleep 1800 &
    target_pid=$!
    PIDS+=("$target_pid")
    for _ in {1..40}; do
        [[ "$(readlink "/proc/$target_pid/ns/net")" != "$(readlink /proc/self/ns/net)" ]] && break
        sleep 0.05
    done
    ip link add hy2-forward type veth peer name hy2-target
    ip link set hy2-target netns "$target_pid"
    ip address add 10.73.3.1/24 dev hy2-forward
    ip -6 address add fd73:3::1/64 dev hy2-forward nodad
    ip link set hy2-forward up
    nsenter -t "$target_pid" -n ip link set lo up
    nsenter -t "$target_pid" -n ip address add 10.73.3.2/24 dev hy2-target
    nsenter -t "$target_pid" -n ip -6 address add fd73:3::2/64 dev hy2-target nodad
    nsenter -t "$target_pid" -n ip link set hy2-target up
    nsenter -t "$target_pid" -n ip route add default via 10.73.3.1
    nsenter -t "$target_pid" -n ip -6 route add default via fd73:3::1
    sysctl -qw net.ipv4.ip_forward=1
    sysctl -qw net.ipv6.conf.all.forwarding=1
    nsenter -t "$target_pid" -n python3 "$FIXTURE" echo 10.73.3.2,fd73:3::2 53101 --marker forwarded: >"$TEST_TEMP/nft-scope/target.log" 2>&1 &
    echo_pid=$!
    PIDS+=("$echo_pid")
    wait_listener udp 53101 "$echo_pid" "$target_pid"
    python3 "$FIXTURE" udp 10.73.3.2 53101 --marker forwarded:
    nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" udp 10.73.3.2 53101 --marker forwarded:
    nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" udp fd73:3::2 53101 --marker forwarded:

    # Explicit binds apply only to their own local destination address.
    offbind_node="$(jq '.listen="10.73.2.1"' <<<"$node")"
    jq -n --argjson a "$offbind_node" --argjson b "$(jq '.id="node-0000000000000012" | .listen="fd73:2::1"' <<<"$node")" \
        '{schema_version:1,nodes:[$a,$b]}' >"$TEST_TEMP/nft-scope/explicit.json"
    proxy_hy2_render_nft "$TEST_TEMP/nft-scope/explicit.json" >"$TEST_TEMP/nft-scope/explicit.nft"
    nft -f "$TEST_TEMP/nft-scope/explicit.nft"
    nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" udp 10.73.2.1 53101 --marker base:
    nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" udp fd73:2::1 53101 --marker base:
    nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" udp 10.73.2.3 53101 --marker extra:
    nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" udp fd73:2::3 53101 --marker extra:
    nft -j list ruleset >"$TEST_TEMP/nft-scope/ruleset.json"
    printf 'PASS: IPv4/IPv6 extra-port UDP mapping, explicit binds, TCP same-port, unrelated OUTPUT and forwarded UDP, independent forward tables\n'
}
chrome_scope() {
    local saved_cert="$TLS_CERT" saved_key="$TLS_KEY"
    TLS_CERT="$TEST_TEMP/ed25519.pem"
    TLS_KEY="$TEST_TEMP/ed25519.key"
    openssl req -x509 -newkey ed25519 -nodes -days 1 -subj '/CN=hy2.acceptance.test' \
        -addext 'subjectAltName=DNS:hy2.acceptance.test' -keyout "$TLS_KEY" -out "$TLS_CERT" >"$TEST_TEMP/ed25519-cert.log" 2>&1
    if [[ -z "$ECHO_PID" ]]; then
        python3 "$FIXTURE" echo 127.0.0.1 56001 >"$TEST_TEMP/ed25519-echo.log" 2>&1 &
        ECHO_PID=$!
        PIDS+=("$ECHO_PID")
        wait_listener tcp 56001 "$ECHO_PID"
    fi
    render_case sing-box 1.14.2 xray 26.9.30 none '' '{"chrome_parrot":true}' :: 10.73.2.1
    start_core sing-box 1.14.2 "$CASE_DIR/server.json" "$CASE_DIR/server.log"
    wait_listener udp 53100 "${CORE_PIDS[-1]}"
    start_core xray 26.9.30 "$CASE_DIR/client.json" "$CASE_DIR/client.log" client
    wait_listener tcp 54100 "${CORE_PIDS[-1]}" "$CLIENT_NS_PID"
    if nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" continuous 54100 0 >"$CASE_DIR/traffic.jsonl" 2>"$CASE_DIR/traffic.err"; then
        fail 'Chrome-parrot-on unexpectedly authenticated Ed25519 certificate'
    fi
    grep -Eqi 'ed25519|signature|certificate|handshake|authentication' "$CASE_DIR/client.log" ||
        fail 'Chrome-parrot rejection lacks TLS evidence'
    stop_cores
    run_case sing-box 1.14.2 xray 26.9.30 none '' '{"chrome_parrot":false}'
    TLS_CERT="$saved_cert"
    TLS_KEY="$saved_key"
    if ((TRAFFIC_FAILURES == 0)); then
        printf 'PASS: latest Xray Chrome parrot on rejects Ed25519, off passes pinned-certificate TCP/UDP\n'
    else
        printf 'PARTIAL: latest Xray Chrome on rejects Ed25519; off authenticates TCP but UDP failed (see preserved evidence)\n'
    fi
}
ufw_scope() {
    local node echo_pid
    command -v ufw >/dev/null || fail 'UFW is not installed on the dedicated host'
    mkdir -p "$TEST_SYSTEM_ROOT/etc/default"
    cp -a /etc/ufw "$TEST_SYSTEM_ROOT/etc/ufw"
    cp /etc/default/ufw "$TEST_SYSTEM_ROOT/etc/default/ufw"
    mount --bind "$TEST_SYSTEM_ROOT/etc/ufw" /etc/ufw
    mount --bind "$TEST_SYSTEM_ROOT/etc/default/ufw" /etc/default/ufw
    ufw --force reset >"$TEST_TEMP/ufw-reset.log" 2>&1
    ufw default deny incoming >"$TEST_TEMP/ufw-default.log" 2>&1
    ufw default allow outgoing >>"$TEST_TEMP/ufw-default.log" 2>&1
    ufw --force enable >"$TEST_TEMP/ufw-enable.log" 2>&1
    python3 "$FIXTURE" echo 10.73.2.1 53110 >"$TEST_TEMP/ufw-denied-target.log" 2>&1 &
    echo_pid=$!
    PIDS+=("$echo_pid")
    wait_listener udp 53110 "$echo_pid"
    if nsenter -t "$CLIENT_NS_PID" -n python3 "$FIXTURE" udp 10.73.2.1 53110 >"$TEST_TEMP/ufw-denied.log" 2>&1; then
        fail 'default-deny did not block unrelated incoming UDP'
    fi
    node="$(make_node xray salamander 53101-53103 :: 10.73.2.1)"
    jq -n --argjson node "$node" '{schema_version:1,nodes:[$node]}' >"$TEST_TEMP/ufw-nodes.json"
    proxy_ufw_nodes_desired "$TEST_TEMP/ufw-nodes.json" >"$TEST_TEMP/ufw-desired.json"
    vps_ufw_begin proxy-nodes "$TEST_TEMP/ufw-desired.json" force
    vps_ufw_commit
    ufw status numbered >"$TEST_TEMP/ufw-status.txt"
    python3 "$FIXTURE" echo 127.0.0.1 56001 >"$TEST_TEMP/ufw-echo.log" 2>&1 &
    ECHO_PID=$!
    PIDS+=("$ECHO_PID")
    wait_listener tcp 56001 "$ECHO_PID"
    run_case xray 26.9.30 sing-box 1.14.2 salamander 5 '{}'
    nft -j list ruleset >"$TEST_TEMP/ufw-ruleset.json"
    ufw disable >"$TEST_TEMP/ufw-disable.log" 2>&1
    printf 'PASS: real UFW default-deny blocks unrelated UDP and project-managed listener rule permits HY2 multi-port TCP/UDP\n'
}
server_bbr_scope() {
    local version profile node manifest config
    for version in 26.4.13 26.9.30; do
        "$(binary xray "$version")" version >"$TEST_TEMP/xray-$version.version"
        grep -Fq "Xray $version " "$TEST_TEMP/xray-$version.version" || fail "wrong Xray version $version"
        for profile in standard conservative aggressive; do
            node="$(make_node xray none '' :: 10.73.2.1)"
            node="$(jq -c --arg profile "$profile" '.options.up_mbps=10000 |
                .options.down_mbps=10000 | .options.bbr_profile=$profile' <<<"$node")"
            manifest="$TEST_TEMP/server-bbr-$version-$profile.nodes.json"
            config="$TEST_TEMP/server-bbr-$version-$profile.json"
            jq -n --argjson node "$node" '{schema_version:1,nodes:[$node]}' >"$manifest"
            proxy_render_config xray "$manifest" "$PROXY_RELAY_FILE" "$version" >"$config"
            jq -e --arg profile "$profile" '.inbounds[] | select(.protocol=="hysteria") |
                .streamSettings.finalmask.quicParams |
                .bbrProfile==$profile and .brutalUp=="10000000000" and .brutalDown=="10000000000"' \
                "$config" >/dev/null || fail "server BBR/bandwidth fields $version/$profile"
            check_config xray "$version" "$config"
            printf 'PASS: Xray %s server BBR %s; bandwidth 10000/10000 Mbps\n' "$version" "$profile"
        done
    done
}
case "$HY2_SCOPE" in
all)
    config_matrix
    traffic_matrix
    chrome_scope
    nft_scope
    ;;
config) config_matrix ;;
traffic) traffic_matrix ;;
nft) nft_scope ;;
chrome) chrome_scope ;;
ufw) ufw_scope ;;
server-bbr) server_bbr_scope ;;
supplement)
    python3 "$FIXTURE" echo 127.0.0.1 56001 >"$TEST_TEMP/echo.log" 2>&1 &
    ECHO_PID=$!
    PIDS+=("$ECHO_PID")
    wait_listener tcp 56001 "$ECHO_PID"
    run_case sing-box 1.14.2 sing-box 1.14.2 gecko 5-7 '{}'
    run_case sing-box 1.14.2 xray 26.9.30 none 5 '{"up_mbps":100,"down_mbps":200,"chrome_parrot":false,"bbr_profile":"standard"}' fd73:2::1 fd73:2::1
    ;;
bind)
    python3 "$FIXTURE" echo 127.0.0.1 56001 >"$TEST_TEMP/echo.log" 2>&1 &
    ECHO_PID=$!
    PIDS+=("$ECHO_PID")
    wait_listener tcp 56001 "$ECHO_PID"
    run_case xray 26.9.30 sing-box 1.14.2 none 5 '{}' 10.73.2.1 10.73.2.1
    ;;
*) fail "unknown scope $HY2_SCOPE" ;;
esac
((TRAFFIC_FAILURES == 0)) || fail "$TRAFFIC_FAILURES real TCP/UDP case(s) failed; independent cases continued"
printf 'PASS: HY2 real acceptance (%s); evidence %s\n' "$HY2_SCOPE" "$TEST_TEMP"
