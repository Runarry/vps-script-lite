#!/usr/bin/env bash

# Real compatibility acceptance for the dedicated host-vps-scripts machine.
# The test intentionally stays out of tests/run.sh. It starts project-rendered
# server/client configurations against real core binaries and performs actual
# TCP/UDP requests. Xray policy checks run in a private network+mount namespace.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH
INTERNAL_MODE="${1:-}"
PHASE="${PHASE:-1}"

[[ "$PHASE" == 1 ]] || {
    printf 'FAIL: this revision implements PHASE=1 only\n' >&2
    exit 2
}
case "$INTERNAL_MODE" in '' | --internal-xray-policy) ;; *)
    printf 'FAIL: unsupported internal mode\n' >&2
    exit 2
    ;;
esac

TEST_TEMP="$(mktemp -d)"
readonly TEST_TEMP
TEST_SYSTEM_ROOT="${TEST_TEMP}/root"
mkdir -p -- "$TEST_SYSTEM_ROOT"

CORE_PIDS=()
TARGET_PID=''
HOSTS_MOUNTED=0

stop_cores() {
    local pid
    for pid in "${CORE_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
    for pid in "${CORE_PIDS[@]}"; do wait "$pid" >/dev/null 2>&1 || true; done
    CORE_PIDS=()
}

cleanup() {
    stop_cores
    if [[ -n "$TARGET_PID" ]]; then
        kill "$TARGET_PID" >/dev/null 2>&1 || true
        wait "$TARGET_PID" >/dev/null 2>&1 || true
    fi
    if [[ "$HOSTS_MOUNTED" == 1 ]]; then umount /etc/hosts >/dev/null 2>&1 || true; fi
    rm -rf -- "$TEST_TEMP"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

for tool in bash curl jq openssl python3 sha256sum ss timeout; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

SING_BOX_BINARY="${SING_BOX_BINARY:-$(command -v sing-box 2>/dev/null || true)}"
XRAY_OLD_BINARY="${XRAY_OLD_BINARY:-$(command -v xray 2>/dev/null || true)}"
XRAY_NEW_BINARY="${XRAY_NEW_BINARY:-}"
[[ -x "$SING_BOX_BINARY" ]] || fail 'SING_BOX_BINARY is not executable'
[[ -x "$XRAY_OLD_BINARY" ]] || fail 'XRAY_OLD_BINARY is not executable'
[[ -x "$XRAY_NEW_BINARY" ]] || fail 'XRAY_NEW_BINARY is not executable'

sing_version_output="$($SING_BOX_BINARY version 2>/dev/null)" || fail 'could not read sing-box version'
xray_old_version_output="$($XRAY_OLD_BINARY version 2>/dev/null)" || fail 'could not read old Xray version'
xray_new_version_output="$($XRAY_NEW_BINARY version 2>/dev/null)" || fail 'could not read new Xray version'
[[ "$sing_version_output" == *'sing-box version 1.14.0'* ]] || fail 'expected sing-box 1.14.0'
[[ "$xray_old_version_output" == *'Xray 26.3.27 '* ]] || fail 'expected Xray 26.3.27'
[[ "$xray_new_version_output" == *'Xray 26.9.9 '* ]] || fail 'expected Xray 26.9.9'

export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
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
vps_cmd_init 'proxy compatibility real test' "$TEST_ROOT"
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

proxy_common_init
proxy_ensure_layout
mkdir -p -- "${TEST_SYSTEM_ROOT}/usr/local/bin"
cp -p -- "$SING_BOX_BINARY" "${TEST_SYSTEM_ROOT}/usr/local/bin/sing-box"
cp -p -- "$XRAY_OLD_BINARY" "${TEST_SYSTEM_ROOT}/usr/local/bin/xray"

PROXY_MANIFEST="${TEST_TEMP}/nodes.json"
PROXY_RELAY_FILE="${TEST_TEMP}/relay.json"
export PROXY_MANIFEST PROXY_RELAY_FILE
proxy_manifest_default >"$PROXY_MANIFEST"
jq -n '{schema_version:1,exits:[],bindings:[],forwards:[]}' >"$PROXY_RELAY_FILE"

start_core() {
    local core="$1" binary="$2" config="$3" log="$4"
    case "$core" in
        sing-box) "$binary" run -c "$config" >"$log" 2>&1 & ;;
        xray) "$binary" run -c "$config" >"$log" 2>&1 & ;;
        *) return 2 ;;
    esac
    CORE_PIDS+=("$!")
}

wait_listener() {
    local mode="$1" address="$2" port="$3" pid="$4"
    for _ in {1..120}; do
        kill -0 "$pid" >/dev/null 2>&1 || break
        if [[ "$mode" == udp ]]; then
            ss -H -lun | awk '{print $4}' | grep -Fq "${address}:${port}" && return 0
        else
            ss -H -ltn | awk '{print $4}' | grep -Fq "${address}:${port}" && return 0
        fi
        sleep 0.05
    done
    fail "listener did not start: ${address}:${port}/${mode}"
}

validate_config() {
    local core="$1" binary="$2" config="$3" log="$4"
    case "$core" in
        sing-box) "$binary" check -c "$config" >"$log" 2>&1 ;;
        xray) "$binary" run -test -c "$config" >"$log" 2>&1 ;;
        *) return 2 ;;
    esac || fail "real $core rejected generated configuration"
}

materialize_node_paths() {
    jq -c --arg root "$TEST_SYSTEM_ROOT" '
        if .tls.certificate_path != "" then
            .tls.certificate_path=($root + .tls.certificate_path) |
            .tls.key_path=($root + .tls.key_path)
        else . end
    ' <<<"$1"
}

make_exit() {
    local core="$1" id="$2" profile="$3" uri="$4" options="${5:-}" descriptor
    [[ -n "$options" ]] || options='{}'
    descriptor="$(proxy_relay_uri_parse "$uri" "$profile")" || return $?
    jq -cn --arg id "$id" --arg core "$core" --arg profile "$profile" --arg uri "$uri" \
        --argjson descriptor "$descriptor" --argjson options "$options" '
        {id:$id,name:"compat",type:"protocol",core:$core,profile:$profile,uri:$uri,
         descriptor:$descriptor,endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint} +
        (if $options == {} then {} else {client_options:$options} end)
    '
}

render_client_config() {
    local core="$1" bundle="$2" port="$3" output="$4"
    case "$core" in
        sing-box)
            jq -n --argjson bundle "$bundle" --argjson port "$port" '{
                log:{level:"warn"},
                inbounds:[{type:"socks",tag:"client",listen:"127.0.0.1",listen_port:$port}],
                outbounds:$bundle.outbounds,
                route:{rules:[{inbound:["client"],action:"route",outbound:$bundle.target_tag}],final:$bundle.target_tag}
            }' >"$output"
            ;;
        xray)
            jq -n --argjson bundle "$bundle" --argjson port "$port" '{
                log:{loglevel:"warning"},
                inbounds:[{tag:"client",listen:"127.0.0.1",port:$port,protocol:"socks",settings:{auth:"noauth",udp:true}}],
                outbounds:$bundle.outbounds,
                routing:{rules:[{type:"field",inboundTag:["client"],outboundTag:$bundle.target_tag}]}
            }' >"$output"
            ;;
    esac
}

assert_http_success() {
    local socks_port="$1" label="$2" response status=0
    response="$(curl --noproxy '' --socks5-hostname "127.0.0.1:${socks_port}" \
        --connect-timeout 3 --max-time 8 -fsS 'http://127.0.0.1:54450/compat')" || status=$?
    [[ "$status" == 0 && "$response" == vpsctl-compat-ok ]] || fail "$label"
}

assert_http_failure() {
    local socks_port="$1" label="$2" status=0
    curl --noproxy '' --socks5-hostname "127.0.0.1:${socks_port}" \
        --connect-timeout 2 --max-time 4 -fsS 'http://127.0.0.1:54450/compat' >/dev/null 2>&1 || status=$?
    [[ "$status" != 0 ]] || fail "$label unexpectedly completed a request"
}

start_http_target() {
    local code
    code='from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body=b"vpsctl-compat-ok"
        self.send_response(200)
        self.send_header("Content-Length",str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self,*args): pass
ThreadingHTTPServer(("127.0.0.1",54450),Handler).serve_forever()'
    python3 -c "$code" >"${TEST_TEMP}/http.log" 2>&1 &
    TARGET_PID=$!
    wait_listener tcp 127.0.0.1 54450 "$TARGET_PID"
}

run_tls_pin_case() {
    local core="$1" label="$2" expect="$3" exit_json="$4" version="$5"
    local binary bundle config log socks_port pid
    case "$core" in
        sing-box)
            binary="$SING_BOX_BINARY"
            socks_port=54432
            ;;
        xray)
            binary="$XRAY_OLD_BINARY"
            socks_port=54433
            ;;
    esac
    bundle="$(proxy_relay_render_outbound "$core" "$exit_json" "$version")" || fail "$label outbound render"
    if [[ "$core" == sing-box ]]; then
        jq -e '.outbounds[0].tls.insecure == false and
            (.outbounds[0].tls.certificate_public_key_sha256 | length) == 1' \
            <<<"$bundle" >/dev/null || fail "$label did not enforce SPKI with strict TLS"
    else
        jq -e '.outbounds[0].streamSettings.tlsSettings.pinnedPeerCertSha256 != "" and
            (.outbounds[0].streamSettings.tlsSettings | has("allowInsecure") | not)' \
            <<<"$bundle" >/dev/null || fail "$label did not enforce Xray certificate pin"
    fi
    config="${TEST_TEMP}/${label}.json"
    log="${TEST_TEMP}/${label}.log"
    render_client_config "$core" "$bundle" "$socks_port" "$config"
    validate_config "$core" "$binary" "$config" "${log}.check"
    start_core "$core" "$binary" "$config" "$log"
    pid="${CORE_PIDS[-1]}"
    wait_listener tcp 127.0.0.1 "$socks_port" "$pid"
    if [[ "$expect" == success ]]; then
        assert_http_success "$socks_port" "$label failed with the correct pin"
    else
        assert_http_failure "$socks_port" "$label"
    fi
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    CORE_PIDS=()
}

run_tls_pin_acceptance() {
    local cert key wrong_cert wrong_key logical_node server_node server_manifest server_config
    local legacy_node legacy_uri pinless_node pinless_uri pins wrong_pins options exit_json normalized server_pid
    cert="${TEST_TEMP}/spki-cert.pem"
    key="${TEST_TEMP}/spki-key.pem"
    wrong_cert="${TEST_TEMP}/wrong-cert.pem"
    wrong_key="${TEST_TEMP}/wrong-key.pem"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=spki.compat.test' \
        -addext 'subjectAltName=DNS:spki.compat.test' -keyout "$key" -out "$cert" >/dev/null 2>&1
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=wrong.compat.test' \
        -addext 'subjectAltName=DNS:wrong.compat.test' -keyout "$wrong_key" -out "$wrong_cert" >/dev/null 2>&1

    logical_node="$(proxy_prepare_node_json xray vless-grpc-tls node-0000000000000001 compat-spki \
        127.0.0.1 54431 127.0.0.1 spki.compat.test /unused compat-grpc imported "$cert" "$key" \
        none 100 200 bbr auto)" || fail 'prepare TLS pin server node'
    jq -n --argjson node "$logical_node" '{schema_version:1,nodes:[$node]}' >"$PROXY_MANIFEST"
    pins="$(_proxy_relay_certificate_pins "$(vps_cmd_system_path "$(jq -r '.tls.certificate_path' <<<"$logical_node")")")" ||
        fail 'derive correct certificate pins'
    wrong_pins="$(_proxy_relay_certificate_pins "$wrong_cert")" || fail 'derive wrong certificate pins'

    server_node="$(materialize_node_paths "$logical_node")" || fail 'materialize TLS server paths'
    server_manifest="${TEST_TEMP}/spki-server-manifest.json"
    server_config="${TEST_TEMP}/spki-server.json"
    jq -n --argjson node "$server_node" '{schema_version:1,nodes:[$node]}' >"$server_manifest"
    proxy_render_config xray "$server_manifest" "$PROXY_RELAY_FILE" 26.3.27 >"$server_config" || fail 'render TLS pin server'
    validate_config xray "$XRAY_OLD_BINARY" "$server_config" "${TEST_TEMP}/spki-server.check"
    start_core xray "$XRAY_OLD_BINARY" "$server_config" "${TEST_TEMP}/spki-server.log"
    server_pid="${CORE_PIDS[-1]}"
    wait_listener tcp 127.0.0.1 54431 "$server_pid"

    legacy_node="$(jq '.tls.insecure=true' <<<"$logical_node")" || fail 'prepare legacy URI node'
    legacy_uri="$(proxy_xray_render_uri "$legacy_node")" || fail 'render legacy certificate-pin URI'
    pinless_node="$(jq '.tls.insecure=true | .tls.certificate_sha256=""' <<<"$logical_node")" || fail 'prepare pinless URI node'
    pinless_uri="$(proxy_xray_render_uri "$pinless_node")" || fail 'render pinless insecure URI'

    options="$(jq -c '{tls_spki_sha256,tls_cert_sha256}' <<<"$pins")"
    exit_json="$(make_exit sing-box exit-0000000000000001 vless-grpc-tls "$pinless_uri" "$options")" || fail 'sing-box correct exit'
    run_tls_pin_case sing-box spki-sing-correct success "$exit_json" 1.14.0
    exit_json="$(make_exit xray exit-0000000000000002 vless-grpc-tls "$pinless_uri" "$options")" || fail 'Xray correct exit'
    run_tls_pin_case xray spki-xray-correct success "$exit_json" 26.3.27

    options="$(jq -c '{tls_spki_sha256,tls_cert_sha256}' <<<"$wrong_pins")"
    exit_json="$(make_exit sing-box exit-0000000000000003 vless-grpc-tls "$pinless_uri" "$options")" || fail 'sing-box wrong exit'
    run_tls_pin_case sing-box spki-sing-wrong failure "$exit_json" 1.14.0
    exit_json="$(make_exit xray exit-0000000000000004 vless-grpc-tls "$pinless_uri" "$options")" || fail 'Xray wrong exit'
    run_tls_pin_case xray spki-xray-wrong failure "$exit_json" 26.3.27

    exit_json="$(make_exit sing-box exit-0000000000000005 vless-grpc-tls "$legacy_uri")" || fail 'sing-box legacy exit'
    normalized="$(proxy_relay_normalize_exit "$exit_json" "$PROXY_MANIFEST")" || fail 'sing-box legacy pin migration'
    jq -e --arg spki "$(jq -r '.tls_spki_sha256' <<<"$pins")" \
        '.client_options.tls_spki_sha256 == $spki and (.client_options.tls_cert_sha256 | length) == 64' \
        <<<"$normalized" >/dev/null || fail 'legacy URI did not migrate to SPKI'
    run_tls_pin_case sing-box spki-sing-legacy success "$exit_json" 1.14.0
    exit_json="$(make_exit xray exit-0000000000000006 vless-grpc-tls "$legacy_uri")" || fail 'Xray legacy exit'
    run_tls_pin_case xray spki-xray-legacy success "$exit_json" 26.3.27

    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
    CORE_PIDS=()
    printf 'PASS: real TLS pinning (correct, wrong, insecure-bypass rejection, legacy URI migration; sing-box/Xray)\n'
}

run_hysteria_ed25519_acceptance() {
    local cert key logical_node server_node server_manifest server_config uri pins options exit_json bundle config log
    local server_pid client_pid chrome socks_port
    cert="${TEST_TEMP}/hy-ed25519-cert.pem"
    key="${TEST_TEMP}/hy-ed25519-key.pem"
    openssl req -x509 -newkey ed25519 -nodes -days 1 -subj '/CN=hy.compat.test' \
        -addext 'subjectAltName=DNS:hy.compat.test' -keyout "$key" -out "$cert" >/dev/null 2>&1
    logical_node="$(proxy_prepare_node_json sing-box hysteria2 node-0000000000000011 compat-hy \
        127.0.0.1 54441 127.0.0.1 hy.compat.test /unused unused imported "$cert" "$key" \
        none 100 200 bbr auto)" || fail 'prepare Hysteria2 Ed25519 node'
    jq -n --argjson node "$logical_node" '{schema_version:1,nodes:[$node]}' >"$PROXY_MANIFEST"
    pins="$(_proxy_relay_certificate_pins "$(vps_cmd_system_path "$(jq -r '.tls.certificate_path' <<<"$logical_node")")")" ||
        fail 'derive Hysteria2 certificate pins'
    uri="$(proxy_sb_render_uri "$logical_node")" || fail 'render Hysteria2 URI'
    server_node="$(materialize_node_paths "$logical_node")" || fail 'materialize Hysteria2 server paths'
    server_manifest="${TEST_TEMP}/hy-server-manifest.json"
    server_config="${TEST_TEMP}/hy-server.json"
    jq -n --argjson node "$server_node" '{schema_version:1,nodes:[$node]}' >"$server_manifest"
    proxy_render_config sing-box "$server_manifest" "$PROXY_RELAY_FILE" 1.14.0 >"$server_config" || fail 'render Hysteria2 server'
    validate_config sing-box "$SING_BOX_BINARY" "$server_config" "${TEST_TEMP}/hy-server.check"
    start_core sing-box "$SING_BOX_BINARY" "$server_config" "${TEST_TEMP}/hy-server.log"
    server_pid="${CORE_PIDS[-1]}"
    wait_listener udp 127.0.0.1 54441 "$server_pid"

    for chrome in true false; do
        if [[ "$chrome" == true ]]; then socks_port=54442; else socks_port=54443; fi
        options="$(jq -c --argjson chrome "$chrome" '{tls_spki_sha256,tls_cert_sha256,chrome_parrot:$chrome}' <<<"$pins")"
        exit_json="$(make_exit sing-box exit-0000000000000011 hysteria2 "$uri" "$options")" || fail "prepare Hysteria2 chrome=$chrome exit"
        bundle="$(proxy_relay_render_outbound sing-box "$exit_json" 1.14.0)" || fail "render Hysteria2 chrome=$chrome outbound"
        jq -e --argjson chrome "$chrome" '.outbounds[0].disable_chrome_parrot == ($chrome | not)' \
            <<<"$bundle" >/dev/null || fail "Hysteria2 chrome=$chrome renderer"
        config="${TEST_TEMP}/hy-client-${chrome}.json"
        log="${TEST_TEMP}/hy-client-${chrome}.log"
        render_client_config sing-box "$bundle" "$socks_port" "$config"
        validate_config sing-box "$SING_BOX_BINARY" "$config" "${log}.check"
        start_core sing-box "$SING_BOX_BINARY" "$config" "$log"
        client_pid="${CORE_PIDS[-1]}"
        wait_listener tcp 127.0.0.1 "$socks_port" "$client_pid"
        if [[ "$chrome" == true ]]; then
            assert_http_failure "$socks_port" 'Hysteria2 Ed25519 with Chrome parrot enabled'
        else
            assert_http_success "$socks_port" 'Hysteria2 Ed25519 with Chrome parrot disabled'
        fi
        kill "$client_pid" >/dev/null 2>&1 || true
        wait "$client_pid" >/dev/null 2>&1 || true
        CORE_PIDS=("$server_pid")
    done
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
    CORE_PIDS=()
    printf 'PASS: real Hysteria2 Ed25519 certificate behavior (Chrome parrot on fails, off succeeds)\n'
}

start_policy_targets() {
    local log="$1" code
    code='import selectors,socket,sys,threading
port=int(sys.argv[1]); log_path=sys.argv[2]
items=[
 (socket.AF_INET,"127.0.0.2","loop-v4"),(socket.AF_INET6,"::1","loop-v6"),
 (socket.AF_INET,"10.77.0.2","private-v4"),(socket.AF_INET6,"fd77::2","private-v6"),
 (socket.AF_INET,"93.184.216.34","public-v4"),(socket.AF_INET6,"2606:2800:220:1:248:1893:25c8:1946","public-v6")]
sel=selectors.DefaultSelector()
for family,address,label in items:
    for kind in ("tcp","udp"):
        sock=socket.socket(family,socket.SOCK_STREAM if kind=="tcp" else socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        if family==socket.AF_INET6: sock.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
        sock.bind((address,port))
        if kind=="tcp": sock.listen(16)
        sock.setblocking(False); sel.register(sock,selectors.EVENT_READ,(kind,label))
def record(token,label,kind):
    with open(log_path,"a",encoding="ascii") as out:
        out.write(f"{token}\t{label}\t{kind}\n"); out.flush()
def serve_tcp(conn,label):
    conn.settimeout(8)
    try:
        data=b""
        while b"\r\n" not in data and len(data)<65535:
            chunk=conn.recv(65535-len(data))
            if not chunk: break
            data+=chunk
        if not data:
            record("EMPTY",label,"tcp"); return
        first=data.split(b"\r\n",1)[0].split()
        token=first[1].lstrip(b"/").decode("ascii","strict")
        record(token,label,"tcp"); body=token.encode("ascii")
        conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: "+str(len(body)).encode()+b"\r\nConnection: close\r\n\r\n"+body)
    except (ConnectionError,IndexError,TimeoutError,UnicodeError,socket.timeout) as error:
        record("ERROR-"+type(error).__name__,label,"tcp")
    finally: conn.close()
while True:
    for key,_ in sel.select():
        sock=key.fileobj; kind,label=key.data
        if kind=="udp":
            data,peer=sock.recvfrom(65535); token=data.decode("ascii","strict")
            record(token,label,kind); sock.sendto(data,peer)
        else:
            conn,_=sock.accept()
            threading.Thread(target=serve_tcp,args=(conn,label),daemon=True).start()'
    : >"$log"
    python3 -c "$code" 55300 "$log" >"${TEST_TEMP}/policy-target.log" 2>&1 &
    TARGET_PID=$!
    sleep 0.25
    kill -0 "$TARGET_PID" >/dev/null 2>&1 || fail 'policy target fixture did not start'
}

socks_udp_request() {
    local port="$1" host="$2" token="$3"
    python3 - "$port" "$host" "$token" <<'PY'
import ipaddress,socket,struct,sys
proxy_port=int(sys.argv[1]); host=sys.argv[2].encode("ascii"); token=sys.argv[3].encode("ascii")
ctl=socket.create_connection(("127.0.0.1",proxy_port),timeout=3); ctl.settimeout(3)
ctl.sendall(b"\x05\x01\x00")
if ctl.recv(2)!=b"\x05\x00": raise SystemExit(2)
ctl.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
head=ctl.recv(4)
if len(head)!=4 or head[:2]!=b"\x05\x00": raise SystemExit(3)
atyp=head[3]
if atyp==1: relay=socket.inet_ntop(socket.AF_INET,ctl.recv(4)); family=socket.AF_INET
elif atyp==4: relay=socket.inet_ntop(socket.AF_INET6,ctl.recv(16)); family=socket.AF_INET6
elif atyp==3:
    size=ctl.recv(1)[0]; relay=ctl.recv(size).decode("ascii"); family=socket.AF_INET
else: raise SystemExit(4)
relay_port=struct.unpack("!H",ctl.recv(2))[0]
if relay in ("0.0.0.0","::"): relay="127.0.0.1"; family=socket.AF_INET
udp=socket.socket(family,socket.SOCK_DGRAM); udp.settimeout(4)
packet=b"\x00\x00\x00\x03"+bytes([len(host)])+host+struct.pack("!H",55300)+token
udp.sendto(packet,(relay,relay_port)); reply,_=udp.recvfrom(65535)
offset=3; atyp=reply[offset]; offset+=1
if atyp==1: offset+=4
elif atyp==4: offset+=16
elif atyp==3: offset+=1+reply[offset]
else: raise SystemExit(5)
offset+=2
if reply[offset:]!=token: raise SystemExit(6)
PY
}

wait_policy_record() {
    local token="$1"
    for _ in {1..80}; do
        grep -Fq "${token}"$'\t' "$POLICY_EVIDENCE" && return 0
        sleep 0.05
    done
    return 1
}

assert_policy_record() {
    local token="$1" scope="$2" protocol="$3" expected="$4" line label family
    wait_policy_record "$token" || fail "no target record for $token"
    line="$(grep -F "${token}"$'\t' "$POLICY_EVIDENCE" | tail -n 1)"
    IFS=$'\t' read -r _ label _ <<<"$line"
    [[ "$label" == "${scope}-v4" || "$label" == "${scope}-v6" ]] || fail "$token reached wrong target scope"
    family="${label##*-}"
    if [[ "$expected" != either && "$family" != "$expected" ]]; then
        fail "$token expected $expected but reached $family"
    fi
}

run_policy_request() {
    local socks_port="$1" host="$2" token="$3" protocol="$4" response status=0
    if [[ "$protocol" == tcp ]]; then
        response="$(curl --noproxy '' --socks5-hostname "127.0.0.1:${socks_port}" \
            --connect-timeout 3 --max-time 8 -fsS "http://${host}:55300/${token}")" || status=$?
        if [[ "$status" != 0 || "$response" != "$token" ]]; then
            tail -n 20 -- "$POLICY_EVIDENCE" >&2 || true
            tail -n 20 -- "${POLICY_SERVER_LOG:-/dev/null}" >&2 || true
            tail -n 20 -- "${POLICY_CLIENT_LOG:-/dev/null}" >&2 || true
            fail "TCP request failed for $token"
        fi
    else
        socks_udp_request "$socks_port" "$host" "$token" || fail "UDP request failed for $token"
    fi
}

render_policy_client() {
    local manifest="$1" output="$2" outbounds='[]' rules='[]' index=0 node uri exit_json bundle tag port
    while IFS= read -r node; do
        uri="$(proxy_xray_render_uri "$node")" || fail 'render policy client URI'
        printf -v tag 'exit-%016x' "$((index + 101))"
        exit_json="$(make_exit sing-box "$tag" shadowsocks-aes-256-gcm "$uri")" || fail 'prepare policy client exit'
        bundle="$(proxy_relay_render_outbound sing-box "$exit_json" 1.14.0)" || fail 'render policy client outbound'
        port=$((55400 + index))
        outbounds="$(jq -c --argjson current "$outbounds" --argjson add "$(jq -c '.outbounds' <<<"$bundle")" '$current+$add' <<<null)"
        rules="$(jq -c --argjson current "$rules" --arg inbound "policy-client-${index}" --arg outbound "$(jq -r '.target_tag' <<<"$bundle")" \
            '$current+[{inbound:[$inbound],action:"route",outbound:$outbound}]' <<<null)"
        index=$((index + 1))
    done < <(jq -c '.nodes[]' "$manifest")
    jq -n --argjson outbounds "$outbounds" --argjson rules "$rules" '{
        log:{level:"warn"},
        inbounds:[range(0;5) as $i | {type:"socks",tag:("policy-client-"+($i|tostring)),
            listen:"127.0.0.1",listen_port:(55400+$i)}],
        outbounds:$outbounds,route:{rules:$rules}
    }' >"$output"
}

run_xray_policy_version() {
    local version="$1" binary="$2" manifest="$3" client_config="$4" server_config server_log client_log
    local server_pid client_pid index=0 strategy scope protocol expected token host socks_port
    server_config="${TEST_TEMP}/xray-policy-${version}.json"
    server_log="${TEST_TEMP}/xray-policy-${version}.log"
    client_log="${TEST_TEMP}/xray-policy-client-${version}.log"
    POLICY_SERVER_LOG="$server_log"
    POLICY_CLIENT_LOG="$client_log"
    export POLICY_SERVER_LOG POLICY_CLIENT_LOG
    proxy_render_config xray "$manifest" "$PROXY_RELAY_FILE" "$version" >"$server_config" || fail "render Xray $version policy server"
    if [[ "$version" == 26.3.27 ]]; then
        jq -e 'all(.outbounds[] | select(.tag | startswith("direct-node-"));
            (.settings.domainStrategy | IN("UseIPv4v6","UseIPv6v4","ForceIPv4","ForceIPv6")) and
            (.streamSettings | not))' "$server_config" >/dev/null || fail 'old Xray policy compatibility shape'
    else
        jq -e 'all(.outbounds[] | select(.tag | startswith("direct-node-"));
            .settings.finalRules == [{action:"allow"}] and
            (.streamSettings.sockopt.domainStrategy | IN("UseIPv4v6","UseIPv6v4","ForceIPv4","ForceIPv6"))) and
            .outbounds[0].settings.finalRules == [{action:"allow"}]' "$server_config" >/dev/null ||
            fail 'new Xray policy compatibility shape'
    fi
    validate_config xray "$binary" "$server_config" "${server_log}.check"
    validate_config sing-box "$SING_BOX_BINARY" "$client_config" "${client_log}.check"
    start_core xray "$binary" "$server_config" "$server_log"
    server_pid="${CORE_PIDS[-1]}"
    start_core sing-box "$SING_BOX_BINARY" "$client_config" "$client_log"
    client_pid="${CORE_PIDS[-1]}"
    for index in {0..4}; do
        wait_listener tcp 127.0.0.1 "$((55100 + index))" "$server_pid"
        wait_listener tcp 127.0.0.1 "$((55400 + index))" "$client_pid"
    done

    index=0
    for strategy in auto prefer_ipv4 prefer_ipv6 ipv4_only ipv6_only; do
        case "$strategy" in auto) expected=either ;; prefer_ipv4 | ipv4_only) expected=v4 ;; prefer_ipv6 | ipv6_only) expected=v6 ;; esac
        socks_port=$((55400 + index))
        for scope in loop private public; do
            host="${scope}.compat.test"
            for protocol in tcp udp; do
                token="v${version//./}-${strategy}-${scope}-${protocol}"
                run_policy_request "$socks_port" "$host" "$token" "$protocol"
                assert_policy_record "$token" "$scope" "$protocol" "$expected"
            done
        done
        index=$((index + 1))
    done
    stop_cores
    printf 'PASS: real Xray %s IP policy (5 strategies, TCP/UDP, loopback/private/public targets)\n' "$version"
}

run_xray_policy_acceptance() {
    local hosts manifest client_config node temporary index=0 strategy
    command -v ip >/dev/null 2>&1 || fail 'missing required tool: ip'
    command -v mount >/dev/null 2>&1 || fail 'missing required tool: mount'
    [[ "$(id -u)" == 0 ]] || fail 'Xray network-namespace policy test requires root'
    ip link set lo up
    ip link add compat-default type dummy
    ip link set compat-default up
    ip address add 198.18.0.1/32 dev compat-default
    ip -6 address add 2001:db8:ffff::1/128 dev compat-default
    ip route add default dev compat-default
    ip -6 route add default dev compat-default
    ip address add 127.0.0.2/8 dev lo
    ip address add 10.77.0.2/32 dev lo
    ip address add 93.184.216.34/32 dev lo
    ip -6 address add fd77::2/128 dev lo
    ip -6 address add 2606:2800:220:1:248:1893:25c8:1946/128 dev lo
    hosts="${TEST_TEMP}/hosts"
    cp -p -- /etc/hosts "$hosts"
    {
        printf '\n127.0.0.2 loop.compat.test\n::1 loop.compat.test\n'
        printf '10.77.0.2 private.compat.test\nfd77::2 private.compat.test\n'
        printf '93.184.216.34 public.compat.test\n2606:2800:220:1:248:1893:25c8:1946 public.compat.test\n'
    } >>"$hosts"
    mount --bind "$hosts" /etc/hosts
    HOSTS_MOUNTED=1
    POLICY_EVIDENCE="${TEST_TEMP}/policy-target.tsv"
    export POLICY_EVIDENCE
    start_policy_targets "$POLICY_EVIDENCE"

    manifest="${TEST_TEMP}/policy-nodes.json"
    proxy_manifest_default >"$manifest"
    for strategy in auto prefer_ipv4 prefer_ipv6 ipv4_only ipv6_only; do
        node="$(proxy_prepare_node_json xray shadowsocks-aes-256-gcm "$(printf 'node-%016x' "$((index + 33))")" \
            "policy-$strategy" 127.0.0.1 "$((55100 + index))" 127.0.0.1 unused.test /unused unused \
            self-signed '' '' none 100 200 bbr "$strategy")" || fail "prepare policy node $strategy"
        temporary="${TEST_TEMP}/policy-nodes.append.json"
        jq --argjson node "$node" '.nodes += [$node]' "$manifest" >"$temporary"
        mv -- "$temporary" "$manifest"
        index=$((index + 1))
    done
    proxy_manifest_validate_file "$manifest" || fail 'policy manifest validation'
    client_config="${TEST_TEMP}/policy-client.json"
    render_policy_client "$manifest" "$client_config"
    run_xray_policy_version 26.3.27 "$XRAY_OLD_BINARY" "$manifest" "$client_config"
    run_xray_policy_version 26.9.9 "$XRAY_NEW_BINARY" "$manifest" "$client_config"
}

if [[ "$INTERNAL_MODE" == --internal-xray-policy ]]; then
    run_xray_policy_acceptance
    exit 0
fi

start_http_target
run_tls_pin_acceptance
run_hysteria_ed25519_acceptance

command -v unshare >/dev/null 2>&1 || fail 'missing required tool: unshare'
unshare --net --mount --propagation private -- bash "$SCRIPT_PATH" --internal-xray-policy

# Reuse the project's dedicated REALITY guard acceptance, which already checks
# both cores, every guarded profile, loopback-only helpers, exact-SNI filtering,
# rule ordering, and SNI edits with real fallback traffic. Run it against both
# Xray compatibility branches because their Freedom settings differ.
for reality_xray in "$XRAY_OLD_BINARY" "$XRAY_NEW_BINARY"; do
    SING_BOX_BINARY="$SING_BOX_BINARY" XRAY_BINARY="$reality_xray" \
        bash "${TEST_ROOT}/tests/integration/test-service-proxy-reality-anti-relay-real.sh"
done

printf 'PASS: phase 1 service proxy core compatibility real acceptance\n'
