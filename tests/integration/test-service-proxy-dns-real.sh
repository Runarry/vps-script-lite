#!/usr/bin/env bash

# Real sing-box DNS acceptance for the dedicated host-vps-scripts machine.
# The deterministic cases run in private network and mount namespaces; the
# optional public preset smoke runs on the host network without changing it.
# This script is syntax-checked, but intentionally not run by tests/run.sh.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
INTERNAL_MODE="${1:-}"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
blocked() { printf 'BLOCKED: %s\n' "$1" >&2; exit 3; }

case "$INTERNAL_MODE" in
    '')
        [[ "$EUID" == 0 ]] || blocked 'run as root on the dedicated host-vps-scripts machine'
        command -v unshare >/dev/null 2>&1 || blocked 'missing required tool: unshare'
        if [[ "${RUN_PUBLIC_DNS_TEST:-1}" == 1 ]]; then
            bash "$SCRIPT_PATH" --internal-cloudflare
        fi
        exec unshare --net --mount --propagation private -- bash "$SCRIPT_PATH" --internal-isolated
        ;;
    --internal-cloudflare | --internal-isolated) ;;
    *) fail "unsupported internal mode: $INTERNAL_MODE" ;;
esac

for tool in bash curl dbus-daemon dig getent ip jq mount openssl python3 sha256sum ss; do
    command -v "$tool" >/dev/null 2>&1 || blocked "missing required tool: $tool"
done

SING_BOX_BINARY="${SING_BOX_BINARY:-$(command -v sing-box 2>/dev/null || true)}"
[[ -x "$SING_BOX_BINARY" ]] || blocked 'provide an executable SING_BOX_BINARY'
sing_version="$($SING_BOX_BINARY version 2>/dev/null | awk 'NR == 1 {print $3}')"
[[ "$sing_version" == 1.14.0* ]] || blocked "expected stable sing-box 1.14.x, got ${sing_version:-unknown}"

BOOTSTRAP_TEMP="$(mktemp -d "${DNS_EVIDENCE_ROOT:-/tmp}/vpsctl-dns-bootstrap.XXXXXX")"
export VPSCTL_SYSTEM_ROOT="${BOOTSTRAP_TEMP}/root"
mkdir -p -- "$VPSCTL_SYSTEM_ROOT"
export VPSCTL_TESTING=1
export VPSCTL_ENV_INIT=systemd
export VPSCTL_ENV_PACKAGE_MANAGER=apt-get
export VPSCTL_ENV_ARCH=x86_64
export VPSCTL_NON_INTERACTIVE=1
export VPSCTL_NO_COLOR=1

# shellcheck source=../../lib/command.sh
source "${TEST_ROOT}/lib/command.sh"
# shellcheck source=../../lib/ufw.sh
source "${TEST_ROOT}/lib/ufw.sh"
# shellcheck source=../../commands/service/proxy/ufw.sh
source "${TEST_ROOT}/commands/service/proxy/ufw.sh"
vps_cmd_init 'proxy DNS real test' "$TEST_ROOT"
# shellcheck source=../../commands/service/proxy/common.sh
source "${TEST_ROOT}/commands/service/proxy/common.sh"
# shellcheck source=../../commands/service/proxy/protocols-sing-box.sh
source "${TEST_ROOT}/commands/service/proxy/protocols-sing-box.sh"
# shellcheck source=../../commands/service/proxy/protocols-xray.sh
source "${TEST_ROOT}/commands/service/proxy/protocols-xray.sh"
# shellcheck source=../../commands/service/proxy/nodes.sh
source "${TEST_ROOT}/commands/service/proxy/nodes.sh"
# shellcheck source=../../commands/service/proxy/relay-uri.sh
source "${TEST_ROOT}/commands/service/proxy/relay-uri.sh"
# shellcheck source=../../commands/service/proxy/relay.sh
source "${TEST_ROOT}/commands/service/proxy/relay.sh"

free_port() {
    python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

wait_file() {
    local file="$1" pid="$2" log="$3" _attempt
    for _attempt in {1..300}; do
        [[ -s "$file" ]] && return 0
        kill -0 "$pid" >/dev/null 2>&1 || break
        sleep 0.05
    done
    [[ ! -f "$log" ]] || tail -n 100 -- "$log" >&2
    fail "fixture did not become ready: ${file##*/}"
}

wait_listener() {
    local port="$1" pid="$2" log="$3" _attempt
    for _attempt in {1..120}; do
        kill -0 "$pid" >/dev/null 2>&1 || break
        ss -H -ltn | awk '{print $4}' | grep -Eq ":${port}$" && return 0
        sleep 0.05
    done
    [[ ! -f "$log" ]] || tail -n 100 -- "$log" >&2
    fail "listener did not start on TCP $port"
}

render_dns_client_config() {
    local settings="$1" socks_port="$2" strategy="$3" output="$4" rendered resolver='{}'
    rendered="$(proxy_dns_render "$settings" "$sing_version")" || return $?
    if [[ "$strategy" != auto ]]; then
        resolver="$(jq -cn --arg strategy "$strategy" \
            '{domain_resolver:{server:"proxy-dns",strategy:$strategy}}')"
    fi
    jq -n --argjson rendered "$rendered" --argjson port "$socks_port" --argjson resolver "$resolver" '{
        log:{level:"debug",timestamp:true},
        dns:$rendered.dns,
        inbounds:[{type:"socks",tag:"client",listen:"127.0.0.1",listen_port:$port}],
        outbounds:[({type:"direct",tag:"direct"} + $resolver)],
        route:($rendered.route + {final:"direct"})
    }' >"$output"
}

run_cloudflare_smoke() {
    local socks_port settings config log response status=0
    PUBLIC_TEMP="$(mktemp -d "${DNS_EVIDENCE_ROOT:-/tmp}/vpsctl-dns-public.XXXXXX")"
    socks_port="$(free_port)"
    settings='{"mode":"doh","server":"1.1.1.1","port":443,"tls_server_name":"cloudflare-dns.com","path":"/dns-query","bootstrap":null}'
    config="${PUBLIC_TEMP}/cloudflare.json"
    log="${PUBLIC_TEMP}/cloudflare.log"
    render_dns_client_config "$settings" "$socks_port" auto "$config"
    "$SING_BOX_BINARY" check -c "$config" >"${log}.check" 2>&1 || {
        tail -n 100 -- "${log}.check" >&2
        fail 'sing-box rejected the rendered Cloudflare DoH preset'
    }
    "$SING_BOX_BINARY" run -c "$config" >"$log" 2>&1 &
    PUBLIC_PID=$!
    wait_listener "$socks_port" "$PUBLIC_PID" "$log"
    response="$(curl --noproxy '' --socks5-hostname "127.0.0.1:${socks_port}" \
        --connect-timeout 5 --max-time 15 -fsS https://example.com/)" || status=$?
    if ((status != 0)) || [[ "$response" != *Example\ Domain* ]]; then
        tail -n 100 -- "$log" >&2
        fail "public Cloudflare DoH preset query failed (curl=$status)"
    fi
    grep -Eq 'dns: exchanged|dns/https|cloudflare' "$log" || fail 'Cloudflare DoH smoke lacked DNS transport evidence'
    printf 'PASS: public Cloudflare DoH preset (1.1.1.1 with TLS name cloudflare-dns.com)\n'
}

if [[ "$INTERNAL_MODE" == --internal-cloudflare ]]; then
    PUBLIC_TEMP=''
    PUBLIC_PID=''
    public_cleanup() {
        local status="$1"
        [[ -z "$PUBLIC_PID" ]] || kill "$PUBLIC_PID" >/dev/null 2>&1 || true
        [[ -z "$PUBLIC_PID" ]] || wait "$PUBLIC_PID" >/dev/null 2>&1 || true
        if [[ -n "$PUBLIC_TEMP" ]]; then
            if ((status == 0)) && [[ "${KEEP_TEST_TEMP:-0}" != 1 ]]; then
                rm -rf -- "$PUBLIC_TEMP"
            else
                printf 'EVIDENCE: retained public test directory %s\n' "$PUBLIC_TEMP" >&2
            fi
        fi
        rm -rf -- "$BOOTSTRAP_TEMP"
    }
    trap 'public_cleanup "$?"' EXIT
    proxy_common_init
    run_cloudflare_smoke
    exit 0
fi

ip link set lo up
ip link add dns-default type dummy
ip address add 192.0.2.2/32 dev dns-default
ip -6 address add 2001:db8::2/128 dev dns-default
ip link set dns-default up
ip route add default dev dns-default
ip -6 route add default dev dns-default
python3 -c 'import dbus, dbus.service, gi' >/dev/null 2>&1 ||
    blocked 'python3-dbus and python3-gi are required (extracted packages on PYTHONPATH are sufficient)'

TEST_TEMP="$BOOTSTRAP_TEMP"
readonly TEST_TEMP
TEST_SYSTEM_ROOT="${TEST_TEMP}/root"

CORE_PIDS=()
FIXTURE_PID=''
RESOLVED_PID=''
BUS_PID=''
RESOLV_MOUNTED=0

stop_cores() {
    local pid
    for pid in "${CORE_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
    for pid in "${CORE_PIDS[@]}"; do wait "$pid" >/dev/null 2>&1 || true; done
    CORE_PIDS=()
}

cleanup() {
    local status="$1"
    trap - EXIT
    stop_cores
    [[ -z "$RESOLVED_PID" ]] || kill "$RESOLVED_PID" >/dev/null 2>&1 || true
    [[ -z "$RESOLVED_PID" ]] || wait "$RESOLVED_PID" >/dev/null 2>&1 || true
    [[ -z "$FIXTURE_PID" ]] || kill "$FIXTURE_PID" >/dev/null 2>&1 || true
    [[ -z "$FIXTURE_PID" ]] || wait "$FIXTURE_PID" >/dev/null 2>&1 || true
    [[ -z "$BUS_PID" ]] || kill "$BUS_PID" >/dev/null 2>&1 || true
    [[ -z "$BUS_PID" ]] || wait "$BUS_PID" >/dev/null 2>&1 || true
    if [[ "$RESOLV_MOUNTED" == 1 ]]; then umount /etc/resolv.conf >/dev/null 2>&1 || status=20; fi
    if ((status == 0)) && [[ "${KEEP_TEST_TEMP:-0}" != 1 ]]; then
        rm -rf -- "$TEST_TEMP"
    else
        printf 'EVIDENCE: retained test directory %s\n' "$TEST_TEMP" >&2
    fi
    exit "$status"
}
trap 'cleanup "$?"' EXIT

proxy_common_init
proxy_relay_init
proxy_ensure_layout
mkdir -p -- "${TEST_SYSTEM_ROOT}/usr/local/bin" "${PROXY_STATE_DIR}/cores"
cp -p -- "$SING_BOX_BINARY" "${TEST_SYSTEM_ROOT}/usr/local/bin/sing-box"
jq -n --arg version "$sing_version" '{schema_version:1,core:"sing-box",binary:"/usr/local/bin/sing-box",
    owned:false,version:$version,release_tag:"",sha256:"real",service:"vpsctl-proxy-sing-box",
    installed_at:"2026-01-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z"}' \
    >"${PROXY_STATE_DIR}/cores/sing-box.json"

CERT="${TEST_TEMP}/dns-cert.pem"
KEY="${TEST_TEMP}/dns-key.pem"
DNS_EVIDENCE="${TEST_TEMP}/dns-evidence.jsonl"
DNS_READY="${TEST_TEMP}/dns-ready.json"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=dns-fixture.test' \
    -addext 'subjectAltName=DNS:dns-fixture.test,DNS:dns-target.test,DNS:dns-upstream.test' \
    -keyout "$KEY" -out "$CERT" >/dev/null 2>&1
export SSL_CERT_FILE="$CERT"

python3 "${TEST_ROOT}/tests/fixtures/dns-server.py" --host 127.0.0.53 --udp-port 53 \
    --http-port 443 --cert "$CERT" --key "$KEY" --evidence "$DNS_EVIDENCE" --ready "$DNS_READY" \
    >"${TEST_TEMP}/dns-fixture.log" 2>&1 &
FIXTURE_PID=$!
wait_file "$DNS_READY" "$FIXTURE_PID" "${TEST_TEMP}/dns-fixture.log"
TCP_PORT="$(jq -r .tcp "$DNS_READY")"
DOT_PORT="$(jq -r .dot "$DNS_READY")"
DOH_PORT="$(jq -r .doh "$DNS_READY")"

mapfile -t bus_info < <(dbus-daemon --session --fork --print-address=1 --print-pid=1)
BUS_ADDRESS="${bus_info[0]:-}"
BUS_PID="${bus_info[1]:-}"
[[ -n "$BUS_ADDRESS" && "$BUS_PID" =~ ^[0-9]+$ ]] || fail 'could not start private D-Bus daemon'
export DBUS_SYSTEM_BUS_ADDRESS="$BUS_ADDRESS"
python3 "${TEST_ROOT}/tests/fixtures/resolved-empty.py" --address "$BUS_ADDRESS" \
    --ready "${TEST_TEMP}/resolved-ready" >"${TEST_TEMP}/resolved.log" 2>&1 &
RESOLVED_PID=$!
wait_file "${TEST_TEMP}/resolved-ready" "$RESOLVED_PID" "${TEST_TEMP}/resolved.log"

cat >"${TEST_TEMP}/resolv.conf" <<'EOF'
# This is /run/systemd/resolve/stub-resolv.conf managed by man:systemd-resolved(8).
# The private D-Bus link intentionally has no DNS/DNSEx entries.
nameserver 127.0.0.53
options timeout:1 attempts:1
EOF
mount --bind "${TEST_TEMP}/resolv.conf" /etc/resolv.conf
RESOLV_MOUNTED=1
dig +time=1 +tries=1 +short @127.0.0.53 dns-target.test A | grep -Fxq '127.0.0.1' ||
    fail 'direct DNS probe did not receive the fixture A record'
getent ahostsv4 dns-target.test | grep -Fq '127.0.0.1' || fail 'ordinary libc/system DNS did not work in regression fixture'
printf 'PASS: ordinary system DNS works while the private resolved link has no DNS servers\n'

start_core() {
    local config="$1" log="$2"
    "$SING_BOX_BINARY" run -c "$config" >"$log" 2>&1 &
    CORE_PIDS+=("$!")
}

run_curl_success() {
    local socks_port="$1" path="$2" response status=0
    response="$(curl --noproxy '' --socks5-hostname "127.0.0.1:${socks_port}" --cacert "$CERT" \
        --connect-timeout 3 --max-time 8 -fsS "https://dns-target.test:443/${path}")" || status=$?
    [[ "$status" == 0 && "$response" == vpsctl-dns-ok ]] || return 1
}

run_curl_failure() {
    local socks_port="$1" path="$2" status=0
    curl --noproxy '' --socks5-hostname "127.0.0.1:${socks_port}" --cacert "$CERT" \
        --connect-timeout 2 --max-time 4 -fsS "https://dns-target.test:443/${path}" >/dev/null 2>&1 || status=$?
    [[ "$status" != 0 ]]
}

evidence_count() {
    local transport="$1" name="${2:-}"
    jq -s --arg transport "$transport" --arg name "$name" \
        '[.[] | select(.transport == $transport and ($name == "" or .name == $name))] | length' "$DNS_EVIDENCE"
}

run_dns_mode() {
    local label="$1" settings="$2" expected_transport="$3" strategy="${4:-auto}"
    local socks_port config log pid before after
    socks_port="$(free_port)"
    config="${TEST_TEMP}/${label}.json"
    log="${TEST_TEMP}/${label}.log"
    before="$(evidence_count "$expected_transport")"
    render_dns_client_config "$settings" "$socks_port" "$strategy" "$config"
    "$SING_BOX_BINARY" check -c "$config" >"${log}.check" 2>&1 || {
        tail -n 100 -- "${log}.check" >&2
        fail "sing-box rejected $label configuration"
    }
    start_core "$config" "$log"
    pid="${CORE_PIDS[-1]}"
    wait_listener "$socks_port" "$pid" "$log"
    run_curl_success "$socks_port" "$label" || {
        tail -n 100 -- "$log" >&2
        fail "$label did not resolve and connect through sing-box"
    }
    after="$(evidence_count "$expected_transport")"
    ((after > before)) || fail "$label did not reach the expected $expected_transport DNS endpoint"
    stop_cores
    printf 'PASS: real sing-box DNS mode %s\n' "$label"
}

system_settings='{"mode":"system","server":null,"port":null,"tls_server_name":null,"path":null,"bootstrap":null}'
native_settings='{"mode":"system-native","server":null,"port":null,"tls_server_name":null,"path":null,"bootstrap":null}'
udp_settings='{"mode":"udp","server":"127.0.0.53","port":53,"tls_server_name":null,"path":null,"bootstrap":null}'
tcp_settings="$(jq -cn --argjson port "$TCP_PORT" '{mode:"tcp",server:"127.0.0.53",port:$port,tls_server_name:null,path:null,bootstrap:null}')"
dot_settings="$(jq -cn --argjson port "$DOT_PORT" '{mode:"dot",server:"127.0.0.53",port:$port,tls_server_name:"dns-fixture.test",path:null,bootstrap:null}')"
doh_settings="$(jq -cn --argjson port "$DOH_PORT" '{mode:"doh",server:"127.0.0.53",port:$port,tls_server_name:"dns-fixture.test",path:"/dns-query",bootstrap:null}')"
bootstrap_settings="$(jq -cn --argjson port "$DOH_PORT" '{mode:"doh",server:"dns-upstream.test",port:$port,tls_server_name:"dns-fixture.test",path:"/dns-query",bootstrap:"127.0.0.53"}')"

run_dns_mode system "$system_settings" udp
run_dns_mode udp "$udp_settings" udp
run_dns_mode tcp "$tcp_settings" tcp
run_dns_mode dot "$dot_settings" dot
run_dns_mode doh "$doh_settings" doh
bootstrap_before="$(evidence_count udp dns-upstream.test.)"
run_dns_mode doh-domain-bootstrap "$bootstrap_settings" doh
bootstrap_after="$(evidence_count udp dns-upstream.test.)"
((bootstrap_after > bootstrap_before)) || fail 'domain upstream did not use explicit UDP bootstrap'
printf 'PASS: domain DNS upstream resolved through proxy-dns-bootstrap\n'

for strategy in prefer_ipv4 prefer_ipv6 ipv4_only ipv6_only; do
    before4="$(evidence_count http4)"
    before6="$(evidence_count http6)"
    run_dns_mode "policy-${strategy}" "$udp_settings" udp "$strategy"
    after4="$(evidence_count http4)"
    after6="$(evidence_count http6)"
    case "$strategy" in
        prefer_ipv4 | ipv4_only) ((after4 > before4 && after6 == before6)) || fail "$strategy did not select IPv4" ;;
        prefer_ipv6 | ipv6_only) ((after6 > before6 && after4 == before4)) || fail "$strategy did not select IPv6" ;;
    esac
done
printf 'PASS: real IPv4/IPv6 domain_resolver strategy selection\n'

bad_tls_settings="$(jq -cn --argjson port "$DOT_PORT" '{mode:"dot",server:"127.0.0.53",port:$port,tls_server_name:"wrong-dns.test",path:null,bootstrap:null}')"
bad_port="$(free_port)"
unreachable_settings="$(jq -cn --argjson port "$bad_port" '{mode:"tcp",server:"127.0.0.53",port:$port,tls_server_name:null,path:null,bootstrap:null}')"
for failure in bad-tls unreachable; do
    case "$failure" in bad-tls) settings="$bad_tls_settings" ;; unreachable) settings="$unreachable_settings" ;; esac
    socks_port="$(free_port)"
    config="${TEST_TEMP}/${failure}.json"
    log="${TEST_TEMP}/${failure}.log"
    render_dns_client_config "$settings" "$socks_port" auto "$config"
    "$SING_BOX_BINARY" check -c "$config" >"${log}.check" 2>&1 || fail "sing-box rejected $failure negative configuration"
    start_core "$config" "$log"
    pid="${CORE_PIDS[-1]}"
    wait_listener "$socks_port" "$pid" "$log"
    run_curl_failure "$socks_port" "$failure" || fail "$failure unexpectedly resolved and connected"
    kill -0 "$pid" >/dev/null 2>&1 || fail "$failure terminated sing-box instead of failing the query"
    stop_cores
    case "$failure" in
        bad-tls) grep -Eqi 'certificate|tls|x509' "$log" || fail 'bad TLS failure lacked certificate/TLS evidence' ;;
        unreachable) grep -Eqi 'refused|timeout|deadline|unreachable' "$log" || fail 'unreachable upstream lacked network failure evidence' ;;
    esac
    printf 'PASS: %s DNS upstream fails closed and leaves sing-box running\n' "$failure"
done

# Confirm the unmodified native local resolver takes the empty resolved link
# branch and produces the exact upstream failure this feature fixes.
socks_port="$(free_port)"
render_dns_client_config "$native_settings" "$socks_port" auto "${TEST_TEMP}/native-failure.json"
start_core "${TEST_TEMP}/native-failure.json" "${TEST_TEMP}/native-failure.log"
pid="${CORE_PIDS[-1]}"
wait_listener "$socks_port" "$pid" "${TEST_TEMP}/native-failure.log"
run_curl_failure "$socks_port" native-failure || fail 'system-native unexpectedly bypassed empty resolved link'
grep -Fq 'link has no DNS servers configured' "${TEST_TEMP}/native-failure.log" || {
    tail -n 120 -- "${TEST_TEMP}/native-failure.log" >&2
    fail 'system-native failure did not reproduce the resolved-link error'
}
stop_cores
printf 'PASS: reproduced link has no DNS servers configured with ordinary system DNS working\n'

render_reality_pair() {
    local guard="$1" settings="$2" server_port="$3" socks_port="$4" server_config="$5" client_config="$6"
    local node manifest relay uri descriptor exit_json bundle id
    case "$guard" in on) id='node-0000000000000001' ;; off) id='node-0000000000000002' ;; esac
    node="$(proxy_prepare_node_json sing-box vless-reality-vision "$id" "dns-reality-${guard}" \
        127.0.0.1 "$server_port" 127.0.0.1 dns-target.test /unused unused self-signed '' '' \
        none 100 200 bbr auto)" || return $?
    node="$(proxy_reality_guard_apply "$node" "$guard")" || return $?
    manifest="${TEST_TEMP}/reality-${guard}-nodes.json"
    relay="${TEST_TEMP}/reality-${guard}-relay.json"
    jq -n --argjson node "$node" --argjson dns "$settings" \
        '{schema_version:1,settings:{sing_box:{dns:$dns}},nodes:[$node]}' >"$manifest"
    proxy_relay_default >"$relay"
    proxy_render_config sing-box "$manifest" "$relay" "$sing_version" >"$server_config" || return $?
    uri="$(proxy_sb_render_uri "$node")" || return $?
    descriptor="$(proxy_relay_uri_parse "$uri" vless-reality-vision)" || return $?
    exit_json="$(jq -cn --arg uri "$uri" --argjson descriptor "$descriptor" '{
        id:"exit-0000000000000001",name:"dns-reality-client",type:"protocol",core:"sing-box",
        profile:"vless-reality-vision",uri:$uri,descriptor:$descriptor,endpoint:$descriptor.endpoint,
        network_hint:$descriptor.network_hint
    }')"
    bundle="$(proxy_relay_render_outbound sing-box "$exit_json" "$sing_version")" || return $?
    jq -n --argjson bundle "$bundle" --argjson port "$socks_port" '{
        log:{level:"debug",timestamp:true},
        inbounds:[{type:"socks",tag:"client",listen:"127.0.0.1",listen_port:$port}],
        outbounds:$bundle.outbounds,
        route:{rules:[{inbound:["client"],action:"route",outbound:$bundle.target_tag}],final:$bundle.target_tag}
    }' >"$client_config"
}

run_reality_case() {
    local guard="$1" settings="$2" expected="$3" label="$4"
    local server_port socks_port server_config client_config server_log client_log server_pid client_pid
    server_port="$(free_port)"
    socks_port="$(free_port)"
    server_config="${TEST_TEMP}/${label}-server.json"
    client_config="${TEST_TEMP}/${label}-client.json"
    server_log="${TEST_TEMP}/${label}-server.log"
    client_log="${TEST_TEMP}/${label}-client.log"
    render_reality_pair "$guard" "$settings" "$server_port" "$socks_port" "$server_config" "$client_config"
    "$SING_BOX_BINARY" check -c "$server_config" >"${server_log}.check" 2>&1 || fail "$label server config rejected"
    "$SING_BOX_BINARY" check -c "$client_config" >"${client_log}.check" 2>&1 || fail "$label client config rejected"
    start_core "$server_config" "$server_log"
    server_pid="${CORE_PIDS[-1]}"
    wait_listener "$server_port" "$server_pid" "$server_log"
    start_core "$client_config" "$client_log"
    client_pid="${CORE_PIDS[-1]}"
    wait_listener "$socks_port" "$client_pid" "$client_log"
    if [[ "$expected" == success ]]; then
        run_curl_success "$socks_port" "$label" || {
            tail -n 100 -- "$server_log" >&2
            tail -n 100 -- "$client_log" >&2
            fail "$label valid REALITY handshake failed"
        }
    else
        run_curl_failure "$socks_port" "$label" || fail "$label unexpectedly completed REALITY handshake"
        grep -Fq 'link has no DNS servers configured' "$server_log" || fail "$label lacked resolved-link failure evidence"
    fi
    kill -0 "$server_pid" >/dev/null 2>&1 || fail "$label terminated the REALITY server"
    stop_cores
    printf 'PASS: %s\n' "$label"
}

run_reality_case on "$native_settings" failure reality-native-resolved-regression
run_reality_case on "$system_settings" success reality-system-guard-on
run_reality_case off "$system_settings" success reality-system-guard-off

# A managed relay outbound whose endpoint is a hostname must also inherit the
# global project resolver.  Exercise the real outbound and query, while the
# broader protocol/relay matrix remains covered by the existing connectivity suite.
relay_server_port="$(free_port)"
relay_socks_port="$(free_port)"
relay_node="$(proxy_prepare_node_json sing-box shadowsocks-aes-256-gcm node-0000000000000d01 \
    dns-relay 127.0.0.1 "$relay_server_port" 127.0.0.1 dns-target.test /unused unused \
    self-signed '' '' none 100 200 bbr auto)"
relay_manifest="${TEST_TEMP}/relay-server-nodes.json"
relay_empty="${TEST_TEMP}/relay-server-relay.json"
jq -n --argjson node "$relay_node" '{schema_version:1,nodes:[$node]}' >"$relay_manifest"
proxy_relay_default >"$relay_empty"
proxy_render_config sing-box "$relay_manifest" "$relay_empty" "$sing_version" >"${TEST_TEMP}/relay-server.json"
relay_uri="$(proxy_sb_render_uri "$relay_node")"
relay_uri="$(proxy_relay_uri_rewrite "$relay_uri" dns-target.test "$relay_server_port")"
relay_descriptor="$(proxy_relay_uri_parse "$relay_uri" shadowsocks-aes-256-gcm)"
relay_exit="$(jq -cn --arg uri "$relay_uri" --argjson descriptor "$relay_descriptor" '{
    id:"exit-0000000000000d01",name:"dns-relay-host",type:"protocol",core:"sing-box",
    profile:"shadowsocks-aes-256-gcm",uri:$uri,descriptor:$descriptor,endpoint:$descriptor.endpoint,
    network_hint:$descriptor.network_hint
}')"
relay_bundle="$(proxy_relay_render_outbound sing-box "$relay_exit" "$sing_version")"
relay_dns="$(proxy_dns_render "$udp_settings" "$sing_version")"
jq -n --argjson bundle "$relay_bundle" --argjson dns "$relay_dns" --argjson port "$relay_socks_port" '{
    log:{level:"debug",timestamp:true},dns:$dns.dns,
    inbounds:[{type:"socks",tag:"client",listen:"127.0.0.1",listen_port:$port}],
    outbounds:$bundle.outbounds,
    route:($dns.route + {rules:[{inbound:["client"],action:"route",outbound:$bundle.target_tag}],final:$bundle.target_tag})
}' >"${TEST_TEMP}/relay-client.json"
start_core "${TEST_TEMP}/relay-server.json" "${TEST_TEMP}/relay-server.log"
wait_listener "$relay_server_port" "${CORE_PIDS[-1]}" "${TEST_TEMP}/relay-server.log"
start_core "${TEST_TEMP}/relay-client.json" "${TEST_TEMP}/relay-client.log"
wait_listener "$relay_socks_port" "${CORE_PIDS[-1]}" "${TEST_TEMP}/relay-client.log"
run_curl_success "$relay_socks_port" relay-hostname || {
    tail -n 100 -- "${TEST_TEMP}/relay-client.log" >&2
    fail 'relay server hostname did not resolve through proxy-dns'
}
stop_cores
printf 'PASS: real relay server hostname resolution through proxy-dns\n'

printf 'PASS: service proxy DNS real acceptance\n'
