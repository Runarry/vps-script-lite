#!/usr/bin/env bash

# Phase-2 real protocol acceptance for host-vps-scripts. This test is kept out
# of tests/run.sh because it starts real cores and creates a private network
# and mount namespace. Run it with the four explicit core binary variables.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_PATH

if [[ "${VPSCTL_ENHANCEMENTS_NETNS:-0}" != 1 ]]; then
    command -v unshare >/dev/null 2>&1 || {
        printf 'FAIL: missing required tool: unshare\n' >&2
        exit 3
    }
    exec env VPSCTL_ENHANCEMENTS_NETNS=1 unshare --net --mount --propagation private -- \
        bash "$SCRIPT_PATH" "$@"
fi

ENHANCEMENT_SCOPE="${ENHANCEMENT_SCOPE:-all}"
case "$ENHANCEMENT_SCOPE" in
    all | xhttp | hysteria | sing-box-knobs | sing-box-server-bbr | alpha) ;;
    *)
        printf 'FAIL: invalid ENHANCEMENT_SCOPE\n' >&2
        exit 2
        ;;
esac

TEST_TEMP="$(mktemp -d)"
readonly TEST_TEMP
TEST_SYSTEM_ROOT="${TEST_TEMP}/root"
mkdir -p -- "$TEST_SYSTEM_ROOT"

CORE_PIDS=()
TARGET_PIDS=()
HOSTS_MOUNTED=0
TEST_FAILED=0

stop_cores() {
    local pid
    for pid in "${CORE_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
    for pid in "${CORE_PIDS[@]}"; do wait "$pid" >/dev/null 2>&1 || true; done
    CORE_PIDS=()
}

cleanup() {
    local pid
    stop_cores
    for pid in "${TARGET_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
    for pid in "${TARGET_PIDS[@]}"; do wait "$pid" >/dev/null 2>&1 || true; done
    if [[ "$HOSTS_MOUNTED" == 1 ]]; then umount /etc/hosts >/dev/null 2>&1 || true; fi
    if [[ "$TEST_FAILED" == 1 ]]; then
        printf 'EVIDENCE: preserved failed fixture directory: %s\n' "$TEST_TEMP" >&2
    else
        rm -rf -- "$TEST_TEMP"
    fi
}
trap cleanup EXIT
trap 'TEST_FAILED=1' ERR

fail() {
    TEST_FAILED=1
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

for tool in bash curl ip jq mount openssl python3 sha256sum ss timeout; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done
[[ "$(id -u)" == 0 ]] || fail 'protocol enhancement acceptance requires root in its private namespace'

SING_BOX_STABLE_BINARY="${SING_BOX_STABLE_BINARY:-}"
SING_BOX_ALPHA_BINARY="${SING_BOX_ALPHA_BINARY:-}"
XRAY_OLD_BINARY="${XRAY_OLD_BINARY:-}"
XRAY_NEW_BINARY="${XRAY_NEW_BINARY:-}"
for binary in "$SING_BOX_STABLE_BINARY" "$SING_BOX_ALPHA_BINARY" "$XRAY_OLD_BINARY" "$XRAY_NEW_BINARY"; do
    [[ -x "$binary" ]] || fail "core binary is not executable: ${binary:-<empty>}"
done
[[ "$("$SING_BOX_STABLE_BINARY" version 2>/dev/null)" == *'sing-box version 1.14.0'* ]] ||
    fail 'expected stable sing-box 1.14.0'
[[ "$("$SING_BOX_ALPHA_BINARY" version 2>/dev/null)" == *'sing-box version 1.15.0-alpha.3'* ]] ||
    fail 'expected preview sing-box 1.15.0-alpha.3'
[[ "$("$XRAY_OLD_BINARY" version 2>/dev/null)" == *'Xray 26.3.27 '* ]] || fail 'expected Xray 26.3.27'
[[ "$("$XRAY_NEW_BINARY" version 2>/dev/null)" == *'Xray 26.9.9 '* ]] || fail 'expected Xray 26.9.9'

ip link set lo up
ip link add compat-default type dummy
ip link set compat-default up
ip address add 198.18.0.1/32 dev compat-default
ip -6 address add 2001:db8:ffff::1/128 dev compat-default
ip route add default dev compat-default
ip -6 route add default dev compat-default

hosts_file="${TEST_TEMP}/hosts"
cp -p -- /etc/hosts "$hosts_file"
{
    printf '\n127.0.0.1 reality-sni.compat.test tls-sni.compat.test\n'
    printf '127.0.0.1 xhttp-host.compat.test wrong-host.compat.test\n'
} >>"$hosts_file"
mount --bind "$hosts_file" /etc/hosts
HOSTS_MOUNTED=1

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
vps_cmd_init 'proxy protocol enhancements real test' "$TEST_ROOT"
# shellcheck source=../../commands/service/proxy/common.sh
source "${TEST_ROOT}/commands/service/proxy/common.sh"
# shellcheck source=../../commands/service/proxy/core.sh
source "${TEST_ROOT}/commands/service/proxy/core.sh"
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

proxy_common_init
proxy_relay_init
proxy_ensure_layout
mkdir -p -- "${TEST_SYSTEM_ROOT}/usr/local/bin"
cp -p -- "$SING_BOX_STABLE_BINARY" "${TEST_SYSTEM_ROOT}/usr/local/bin/sing-box"
cp -p -- "$XRAY_OLD_BINARY" "${TEST_SYSTEM_ROOT}/usr/local/bin/xray"

PROXY_MANIFEST="${TEST_TEMP}/nodes.json"
PROXY_RELAY_FILE="${TEST_TEMP}/relay.json"
export PROXY_MANIFEST PROXY_RELAY_FILE
proxy_manifest_default >"$PROXY_MANIFEST"
jq -n '{schema_version:1,exits:[],bindings:[],forwards:[]}' >"$PROXY_RELAY_FILE"
CASE_INDEX=0
CA_CERT="${TEST_TEMP}/compat-ca.pem"
CA_KEY="${TEST_TEMP}/compat-ca.key"
TLS_CERT="${TEST_TEMP}/compat-server.pem"
TLS_KEY="${TEST_TEMP}/compat-server.key"
TLS_CSR="${TEST_TEMP}/compat-server.csr"

create_certificates() {
    local extensions="${TEST_TEMP}/certificate-extensions.cnf"
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
        -subj '/CN=vpsctl compatibility test CA' -keyout "$CA_KEY" -out "$CA_CERT" >/dev/null 2>&1
    openssl req -new -newkey rsa:2048 -sha256 -nodes -subj '/CN=tls-sni.compat.test' \
        -keyout "$TLS_KEY" -out "$TLS_CSR" >/dev/null 2>&1
    {
        printf 'subjectAltName=DNS:tls-sni.compat.test,DNS:reality-sni.compat.test\n'
        printf 'basicConstraints=critical,CA:FALSE\n'
        printf 'keyUsage=critical,digitalSignature,keyEncipherment\n'
        printf 'extendedKeyUsage=serverAuth\n'
    } >"$extensions"
    openssl x509 -req -in "$TLS_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
        -days 1 -sha256 -extfile "$extensions" -out "$TLS_CERT" >/dev/null 2>&1
    export SSL_CERT_FILE="$CA_CERT"
}

start_reality_target() {
    local evidence="${TEST_TEMP}/reality-target.tsv"
    : >"$evidence"
    python3 "${TEST_ROOT}/tests/fixtures/reality-anti-relay-target.py" \
        127.0.0.1 443 "$TLS_CERT" "$TLS_KEY" "$evidence" \
        >"${TEST_TEMP}/reality-target.log" 2>&1 &
    TARGET_PIDS+=("$!")
    wait_listener tcp 127.0.0.1 443 "${TARGET_PIDS[-1]}"
}

start_core() {
    local core="$1" binary="$2" config="$3" log="$4"
    case "$core" in
        sing-box) "$binary" run -c "$config" >"$log" 2>&1 & ;;
        xray) "$binary" run -c "$config" >"$log" 2>&1 & ;;
        *) return 2 ;;
    esac
    CORE_PIDS+=("$!")
}

validate_config() {
    local core="$1" binary="$2" config="$3" log="$4"
    case "$core" in
        sing-box) "$binary" check -c "$config" >"$log" 2>&1 ;;
        xray) "$binary" run -test -c "$config" >"$log" 2>&1 ;;
        *) return 2 ;;
    esac || fail "real $core rejected generated configuration"
}

wait_listener() {
    local mode="$1" address="$2" port="$3" pid="$4"
    for _ in {1..160}; do
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

materialize_node_paths() {
    jq -c --arg root "$TEST_SYSTEM_ROOT" '
        if .tls.certificate_path != "" then
            .tls.certificate_path=($root + .tls.certificate_path) |
            .tls.key_path=($root + .tls.key_path)
        else . end
    ' <<<"$1"
}

make_exit() {
    local core="$1" id="$2" profile="$3" uri="$4" descriptor
    descriptor="$(proxy_relay_uri_parse "$uri" "$profile")" || return $?
    jq -cn --arg id "$id" --arg core "$core" --arg profile "$profile" --arg uri "$uri" \
        --argjson descriptor "$descriptor" '{
            id:$id,name:"enhancement-real",type:"protocol",core:$core,profile:$profile,uri:$uri,
            descriptor:$descriptor,endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint
        }'
}

pin_exit() {
    local exit_json="$1" certificate="$2"
    proxy_relay_apply_client_options "$exit_json" "$certificate"
}

render_client_config() {
    local core="$1" bundle="$2" port="$3" output="$4" log_level="${5:-warn}"
    case "$core" in
        sing-box)
            jq -n --argjson bundle "$bundle" --argjson port "$port" --arg level "$log_level" '{
                log:{level:$level},
                inbounds:[{type:"socks",tag:"client",listen:"127.0.0.1",listen_port:$port}],
                outbounds:$bundle.outbounds,
                route:{rules:[{inbound:["client"],action:"route",outbound:$bundle.target_tag}],final:$bundle.target_tag}
            }' >"$output"
            ;;
        xray)
            jq -n --argjson bundle "$bundle" --argjson port "$port" --arg level "$log_level" '{
                log:{loglevel:$level},
                inbounds:[{tag:"client",listen:"127.0.0.1",port:$port,protocol:"socks",
                    settings:{auth:"noauth",udp:true}}],
                outbounds:$bundle.outbounds,
                routing:{rules:[{type:"field",inboundTag:["client"],outboundTag:$bundle.target_tag}]}
            }' >"$output"
            ;;
    esac
}

read_exact_py='
def read_exact(sock,size):
    data=b""
    while len(data)<size:
        chunk=sock.recv(size-len(data))
        if not chunk: raise EOFError("short read")
        data+=chunk
    return data
'

start_echo_target() {
    local code
    code='import selectors,socket,sys
port=int(sys.argv[1])
sel=selectors.DefaultSelector()
for kind in ("tcp","udp"):
    sock=socket.socket(socket.AF_INET,socket.SOCK_STREAM if kind=="tcp" else socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); sock.bind(("127.0.0.1",port))
    if kind=="tcp": sock.listen(32)
    sock.setblocking(False); sel.register(sock,selectors.EVENT_READ,kind)
while True:
    for key,_ in sel.select():
        sock=key.fileobj
        if key.data=="udp":
            data,peer=sock.recvfrom(65535); sock.sendto(data,peer)
        else:
            conn,_=sock.accept(); conn.settimeout(4)
            try:
                data=conn.recv(65535)
                if data: conn.sendall(data)
            finally: conn.close()'
    python3 -c "$code" 56001 >"${TEST_TEMP}/echo-target.log" 2>&1 &
    TARGET_PIDS+=("$!")
    wait_listener tcp 127.0.0.1 56001 "${TARGET_PIDS[-1]}"
    wait_listener udp 127.0.0.1 56001 "${TARGET_PIDS[-1]}"
}

start_h2_target() {
    local code
    H2_EVIDENCE="${TEST_TEMP}/h2-evidence.tsv"
    export H2_EVIDENCE
    : >"$H2_EVIDENCE"
    code='import socket,struct,sys,threading
port=int(sys.argv[1]); evidence=sys.argv[2]
def exact(conn,size):
    data=b""
    while len(data)<size:
        chunk=conn.recv(size-len(data))
        if not chunk: raise EOFError
        data+=chunk
    return data
def frame(conn):
    head=exact(conn,9); size=int.from_bytes(head[:3],"big")
    return head[3],head[4],int.from_bytes(head[5:],"big")&0x7fffffff,exact(conn,size)
def literal(block,offset,prefix):
    mask=(1<<prefix)-1; value=block[offset]&mask; offset+=1
    if value==mask:
        shift=0
        while True:
            byte=block[offset]; offset+=1; value+=(byte&127)<<shift
            if byte<128: break
            shift+=7
    length=block[offset]&127; huffman=block[offset]&128; offset+=1
    if huffman: raise ValueError("huffman not supported in fixture")
    return value,block[offset:offset+length].decode("ascii"),offset+length
def decode_headers(block):
    result={}; offset=0; names={1:":authority",4:":path"}
    while offset<len(block):
        byte=block[offset]
        if byte&128:
            offset+=1; continue
        index,value,offset=literal(block,offset,4)
        if index in names: result[names[index]]=value
    return result
def send_frame(conn,kind,flags,stream,payload=b""):
    conn.sendall(len(payload).to_bytes(3,"big")+bytes((kind,flags))+
        (stream&0x7fffffff).to_bytes(4,"big")+payload)
def handle(conn):
    conn.settimeout(8)
    try:
        if exact(conn,24)!=b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n": return
        headers=None
        while headers is None:
            kind,flags,stream,payload=frame(conn)
            if kind==1 and stream==1: headers=decode_headers(payload)
        authority=headers.get(":authority",""); path=headers.get(":path","")
        token=path.rsplit("/",1)[-1]
        with open(evidence,"a",encoding="ascii") as out:
            out.write(f"{token}\t{authority}\t{path}\n"); out.flush()
        body=token.encode("ascii")
        send_frame(conn,4,0,0); send_frame(conn,1,4,1,b"\x88"); send_frame(conn,0,1,1,body)
    except (ConnectionError,EOFError,OSError,ValueError): pass
    finally: conn.close()
server=socket.socket(); server.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
server.bind(("127.0.0.1",56000)); server.listen(32)
while True:
    conn,_=server.accept(); threading.Thread(target=handle,args=(conn,),daemon=True).start()'
    python3 -c "$code" 56000 "$H2_EVIDENCE" >"${TEST_TEMP}/h2-target.log" 2>&1 &
    TARGET_PIDS+=("$!")
    wait_listener tcp 127.0.0.1 56000 "${TARGET_PIDS[-1]}"
}

socks_tcp_echo() {
    local socks_port="$1" token="$2"
    python3 - "$socks_port" "$token" <<PY
import socket,struct,sys
$read_exact_py
port=int(sys.argv[1]); token=sys.argv[2].encode("ascii")
s=socket.create_connection(("127.0.0.1",port),timeout=4); s.settimeout(6)
s.sendall(b"\x05\x01\x00")
if read_exact(s,2)!=b"\x05\x00": raise SystemExit(2)
s.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01"+struct.pack("!H",56001))
head=read_exact(s,4)
if head[:2]!=b"\x05\x00": raise SystemExit(3)
size={1:4,4:16}.get(head[3])
if size is None:
    size=read_exact(s,1)[0]
read_exact(s,size+2); s.sendall(token)
if read_exact(s,len(token))!=token: raise SystemExit(4)
PY
}

socks_udp_echo() {
    local socks_port="$1" token="$2"
    python3 - "$socks_port" "$token" <<PY
import socket,struct,sys
$read_exact_py
port=int(sys.argv[1]); token=sys.argv[2].encode("ascii")
ctl=socket.create_connection(("127.0.0.1",port),timeout=4); ctl.settimeout(4)
ctl.sendall(b"\x05\x01\x00")
if read_exact(ctl,2)!=b"\x05\x00": raise SystemExit(2)
ctl.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
head=read_exact(ctl,4)
if head[:2]!=b"\x05\x00": raise SystemExit(3)
if head[3]==1: relay=socket.inet_ntop(socket.AF_INET,read_exact(ctl,4)); family=socket.AF_INET
elif head[3]==4: relay=socket.inet_ntop(socket.AF_INET6,read_exact(ctl,16)); family=socket.AF_INET6
else:
    size=read_exact(ctl,1)[0]; relay=read_exact(ctl,size).decode("ascii"); family=socket.AF_INET
relay_port=struct.unpack("!H",read_exact(ctl,2))[0]
if relay in ("0.0.0.0","::"): relay="127.0.0.1"; family=socket.AF_INET
udp=socket.socket(family,socket.SOCK_DGRAM); udp.settimeout(6)
packet=b"\x00\x00\x00\x01\x7f\x00\x00\x01"+struct.pack("!H",56001)+token
udp.sendto(packet,(relay,relay_port)); reply,_=udp.recvfrom(65535)
offset=3; atyp=reply[offset]; offset+=1
if atyp==1: offset+=4
elif atyp==4: offset+=16
else: offset+=1+reply[offset]
offset+=2
if reply[offset:]!=token: raise SystemExit(4)
PY
}

socks_h2_request() {
    local socks_port="$1" authority="$2" path="$3" token="$4"
    python3 - "$socks_port" "$authority" "$path" "$token" <<PY
import socket,struct,sys
$read_exact_py
port=int(sys.argv[1]); authority=sys.argv[2].encode("ascii"); path=sys.argv[3].encode("ascii"); token=sys.argv[4].encode("ascii")
s=socket.create_connection(("127.0.0.1",port),timeout=4); s.settimeout(8)
s.sendall(b"\x05\x01\x00")
if read_exact(s,2)!=b"\x05\x00": raise SystemExit(2)
s.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01"+struct.pack("!H",56000))
head=read_exact(s,4)
if head[:2]!=b"\x05\x00": raise SystemExit(3)
size={1:4,4:16}.get(head[3])
if size is None: size=read_exact(s,1)[0]
read_exact(s,size+2)
headers=b"\x82\x86\x01"+bytes((len(authority),))+authority+b"\x04"+bytes((len(path),))+path
def frame(kind,flags,stream,payload=b""):
    return len(payload).to_bytes(3,"big")+bytes((kind,flags))+stream.to_bytes(4,"big")+payload
s.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"+frame(4,0,0)+frame(1,5,1,headers))
body=b""
while True:
    head=read_exact(s,9); length=int.from_bytes(head[:3],"big"); payload=read_exact(s,length)
    if head[3]==0 and int.from_bytes(head[5:],"big")==1: body+=payload
    if head[4]&1 and int.from_bytes(head[5:],"big")==1: break
if body!=token: raise SystemExit(4)
PY
}

wait_h2_record() {
    local token="$1"
    for _ in {1..80}; do
        grep -Fq "${token}"$'\t' "$H2_EVIDENCE" && return 0
        sleep 0.05
    done
    return 1
}

render_uri() {
    case "$1" in sing-box) proxy_sb_render_uri "$2" ;; xray) proxy_xray_render_uri "$2" ;; *) return 2 ;; esac
}

core_binary() {
    case "$1" in sing-box) printf '%s' "$ACTIVE_SB_BINARY" ;; xray) printf '%s' "$ACTIVE_XRAY_BINARY" ;; *) return 2 ;; esac
}

core_version() {
    case "$1" in sing-box) printf '%s' "$ACTIVE_SB_VERSION" ;; xray) printf '%s' "$ACTIVE_XRAY_VERSION" ;; *) return 2 ;; esac
}

run_xhttp_case() {
    local version="$1" binary="$2" profile="$3" mode="$4" variant="$5"
    local id port socks_port path host node server_node client_node manifest server_config client_config
    local uri exit_json bundle server_pid client_pid token app_path before after status=0
    CASE_INDEX=$((CASE_INDEX + 1))
    printf -v id 'node-%016x' "$CASE_INDEX"
    port=$((51000 + CASE_INDEX))
    socks_port=$((51500 + CASE_INDEX))
    path="/transport/$profile/$mode"
    host='xhttp-host.compat.test'
    if [[ "$profile" == vless-xhttp-tls ]]; then
        node="$(proxy_prepare_node_json xray "$profile" "$id" "xhttp-$CASE_INDEX" \
            127.0.0.1 "$port" 127.0.0.1 tls-sni.compat.test "$path" unused \
            imported "$TLS_CERT" "$TLS_KEY" none 100 200 bbr auto "$mode" "$host")" ||
            fail "prepare XHTTP $version/$profile/$mode"
    else
        node="$(proxy_prepare_node_json xray "$profile" "$id" "xhttp-$CASE_INDEX" \
            127.0.0.1 "$port" 127.0.0.1 reality-sni.compat.test "$path" unused \
            self-signed '' '' none 100 200 bbr auto "$mode" "$host")" ||
            fail "prepare XHTTP $version/$profile/$mode"
        node="$(proxy_reality_guard_apply "$node" off)" || fail "disable fixture guard $profile"
    fi
    server_node="$(materialize_node_paths "$node")" || fail "materialize XHTTP $profile paths"
    manifest="${TEST_TEMP}/xhttp-$CASE_INDEX-nodes.json"
    server_config="${TEST_TEMP}/xhttp-$CASE_INDEX-server.json"
    client_config="${TEST_TEMP}/xhttp-$CASE_INDEX-client.json"
    jq -n --argjson node "$server_node" '{schema_version:1,nodes:[$node]}' >"$manifest"
    proxy_render_config xray "$manifest" "$PROXY_RELAY_FILE" "$version" >"$server_config" ||
        fail "render XHTTP server $version/$profile/$mode"
    jq -e --arg mode "$mode" --arg host "$host" --arg path "$path" --arg profile "$profile" '
        .inbounds[] | select(.tag | startswith("node-")) |
        .streamSettings.network == "xhttp" and
        .streamSettings.xhttpSettings == {mode:$mode,host:$host,path:$path} and
        (if $profile == "vless-xhttp-tls" then
             .streamSettings.security == "tls" and .streamSettings.tlsSettings.alpn == ["h2"]
         else .streamSettings.security == "reality" and
             .streamSettings.realitySettings.serverNames == ["reality-sni.compat.test"] end)
    ' "$server_config" >/dev/null || fail "XHTTP server fields $version/$profile/$mode"
    client_node="$node"
    case "$variant" in
        correct) ;;
        wrong-path) client_node="$(jq '.transport.path="/wrong-transport-path"' <<<"$client_node")" ;;
        wrong-host) client_node="$(jq '.transport.host="wrong-host.compat.test"' <<<"$client_node")" ;;
        wrong-sni) client_node="$(jq '.tls.server_name="wrong-sni.compat.test"' <<<"$client_node")" ;;
        *) return 2 ;;
    esac
    uri="$(proxy_xray_render_uri "$client_node")" || fail "render XHTTP client URI $variant"
    exit_json="$(make_exit xray "exit-$(printf '%016x' "$CASE_INDEX")" "$profile" "$uri")" ||
        fail "prepare XHTTP client exit $variant"
    if [[ "$profile" == vless-xhttp-tls ]]; then
        exit_json="$(pin_exit "$exit_json" "$TLS_CERT")" || fail 'pin TLS XHTTP client'
    fi
    bundle="$(proxy_relay_render_outbound xray "$exit_json" "$version")" ||
        fail "render XHTTP client $version/$profile/$mode/$variant"
    jq -e --arg mode "$mode" --arg path "$(jq -r '.transport.path' <<<"$client_node")" \
        --arg host "$(jq -r '.transport.host' <<<"$client_node")" \
        --arg sni "$(jq -r '.tls.server_name' <<<"$client_node")" --arg profile "$profile" '
        .outbounds[0].streamSettings.network == "xhttp" and
        .outbounds[0].streamSettings.xhttpSettings == {mode:$mode,host:$host,path:$path} and
        (if $profile == "vless-xhttp-tls" then .outbounds[0].streamSettings.tlsSettings.serverName == $sni
         else .outbounds[0].streamSettings.realitySettings.serverName == $sni end)
    ' <<<"$bundle" >/dev/null || fail "XHTTP client transport separation $variant"
    render_client_config xray "$bundle" "$socks_port" "$client_config" warning
    validate_config xray "$binary" "$server_config" "${TEST_TEMP}/xhttp-$CASE_INDEX-server.check"
    validate_config xray "$binary" "$client_config" "${TEST_TEMP}/xhttp-$CASE_INDEX-client.check"
    start_core xray "$binary" "$server_config" "${TEST_TEMP}/xhttp-$CASE_INDEX-server.log"
    server_pid="${CORE_PIDS[-1]}"
    wait_listener tcp 127.0.0.1 "$port" "$server_pid"
    start_core xray "$binary" "$client_config" "${TEST_TEMP}/xhttp-$CASE_INDEX-client.log"
    client_pid="${CORE_PIDS[-1]}"
    wait_listener tcp 127.0.0.1 "$socks_port" "$client_pid"
    printf -v token 'xhttp-%s-%s-%s-%s' "${version//./}" "$profile" "$mode" "$variant"
    app_path="/application/$token"
    before="$(wc -l <"$H2_EVIDENCE")"
    if [[ "$variant" == correct || ("$profile" == vless-xhttp-tls && "$variant" == wrong-sni) ]]; then
        socks_h2_request "$socks_port" application.compat.test "$app_path" "$token" ||
            fail "real H2 request $version/$profile/$mode"
        wait_h2_record "$token" || fail "H2 target evidence $version/$profile/$mode"
        grep -Fxq "${token}"$'\tapplication.compat.test\t'"$app_path" "$H2_EVIDENCE" ||
            fail "H2 authority/path evidence $version/$profile/$mode"
        if [[ "$variant" == wrong-sni ]]; then
            printf 'PASS: Xray TLS full-certificate pin authenticated with separately preserved alternate SNI (%s)\n' "$version"
        fi
    else
        socks_h2_request "$socks_port" application.compat.test "$app_path" "$token" >/dev/null 2>&1 || status=$?
        [[ "$status" != 0 ]] || fail "$variant unexpectedly crossed XHTTP server"
        sleep 0.4
        after="$(wc -l <"$H2_EVIDENCE")"
        [[ "$after" == "$before" ]] || fail "$variant reached H2 target"
    fi
    kill -0 "$server_pid" >/dev/null 2>&1 || fail "XHTTP server exited during $variant"
    stop_cores
}

test_xhttp_defaults() {
    local profile node legacy rendered uri query
    for profile in vless-xhttp-tls vless-xhttp-reality trojan-xhttp-reality; do
        CASE_INDEX=$((CASE_INDEX + 1))
        if [[ "$profile" == vless-xhttp-tls ]]; then
            node="$(proxy_prepare_node_json xray "$profile" "$(printf 'node-%016x' "$CASE_INDEX")" default \
                127.0.0.1 "$((51000 + CASE_INDEX))" 127.0.0.1 tls-sni.compat.test /defaults unused \
                imported "$TLS_CERT" "$TLS_KEY" none 100 200 bbr)" || fail "prepare default $profile"
            jq -e '.transport.mode == "auto"' <<<"$node" >/dev/null || fail 'new TLS XHTTP default is not auto'
        else
            node="$(proxy_prepare_node_json xray "$profile" "$(printf 'node-%016x' "$CASE_INDEX")" default \
                127.0.0.1 "$((51000 + CASE_INDEX))" 127.0.0.1 reality-sni.compat.test /defaults unused \
                self-signed '' '' none 100 200 bbr)" || fail "prepare default $profile"
            jq -e '.transport.mode == "stream-one"' <<<"$node" >/dev/null ||
                fail "new REALITY XHTTP default is not stream-one: $profile"
        fi
    done
    node="$(proxy_prepare_node_json xray vless-xhttp-tls node-0000000000000f01 legacy \
        127.0.0.1 52901 127.0.0.1 tls-sni.compat.test /legacy unused \
        imported "$TLS_CERT" "$TLS_KEY" none 100 200 bbr)" || fail 'prepare legacy TLS base'
    legacy="$(jq 'del(.transport.mode,.transport.host)' <<<"$node")"
    rendered="$(PROXY_RENDER_CORE_VERSION=26.3.27 proxy_xray_render_node "$(materialize_node_paths "$legacy")")" ||
        fail 'render legacy TLS XHTTP'
    jq -e '.[0].streamSettings.xhttpSettings ==
        {mode:"stream-one",host:"tls-sni.compat.test",path:"/legacy"}' <<<"$rendered" >/dev/null ||
        fail 'legacy TLS XHTTP behavior changed'
    uri="$(proxy_xray_render_uri "$legacy")" || fail 'render legacy TLS URI'
    [[ "$uri" == *'mode=stream-one'* && "$uri" == *'host=tls-sni.compat.test'* ]] ||
        fail 'legacy TLS XHTTP client behavior changed'
    node="$(proxy_prepare_node_json xray trojan-xhttp-reality node-0000000000000f02 legacy \
        127.0.0.1 52902 127.0.0.1 reality-sni.compat.test /legacy unused \
        self-signed '' '' none 100 200 bbr)" || fail 'prepare legacy REALITY base'
    legacy="$(jq 'del(.transport.mode,.transport.host)' <<<"$node")"
    rendered="$(PROXY_RENDER_CORE_VERSION=26.3.27 proxy_xray_render_node "$legacy")" ||
        fail 'render legacy Trojan XHTTP'
    jq -e '.[0].streamSettings.xhttpSettings == {path:"/legacy"}' <<<"$rendered" >/dev/null ||
        fail 'legacy Trojan XHTTP server behavior changed'
    uri="$(proxy_xray_render_uri "$legacy")" || fail 'render legacy Trojan URI'
    query="${uri#*\?}"
    query="${query%%#*}"
    query="$(_proxy_relay_query_json "$query")"
    jq -e 'has("mode") or has("host") | not' <<<"$query" >/dev/null ||
        fail 'legacy Trojan XHTTP URI materialized new defaults'
    printf 'PASS: XHTTP new defaults and legacy behavior\n'
}

run_xhttp_matrix() {
    local version binary profile mode variant
    for version in 26.3.27 26.9.9; do
        if [[ "$version" == 26.3.27 ]]; then binary="$XRAY_OLD_BINARY"; else binary="$XRAY_NEW_BINARY"; fi
        for profile in vless-xhttp-tls vless-xhttp-reality trojan-xhttp-reality; do
            for mode in auto packet-up stream-up stream-one; do
                run_xhttp_case "$version" "$binary" "$profile" "$mode" correct
            done
            for variant in wrong-path wrong-host wrong-sni; do
                run_xhttp_case "$version" "$binary" "$profile" stream-one "$variant"
            done
        done
        printf 'PASS: real XHTTP/H2 modes, profiles and negative separation on Xray %s\n' "$version"
    done
}

run_hysteria_case() {
    local label="$1" server_core="$2" client_core="$3" obfs="$4" bbr_profile="${5:-}" server_bbr="${6:-}"
    local id port socks_port node server_node manifest server_config client_config uri exit_json bundle
    local server_binary server_version client_binary client_version server_pid client_pid token
    CASE_INDEX=$((CASE_INDEX + 1))
    printf -v id 'node-%016x' "$CASE_INDEX"
    port=$((53000 + CASE_INDEX))
    socks_port=$((54000 + CASE_INDEX))
    server_binary="$(core_binary "$server_core")"
    server_version="$(core_version "$server_core")"
    client_binary="$(core_binary "$client_core")"
    client_version="$(core_version "$client_core")"
    node="$(proxy_prepare_node_json "$server_core" hysteria2 "$id" "hys-$CASE_INDEX" \
        127.0.0.1 "$port" 127.0.0.1 tls-sni.compat.test /unused unused \
        imported "$TLS_CERT" "$TLS_KEY" "$obfs" 100 100 bbr auto)" ||
        fail "prepare Hysteria2 $label"
    if [[ -n "$server_bbr" ]]; then
        node="$(jq --arg bbr "$server_bbr" '.options.bbr_profile=$bbr' <<<"$node")" ||
            fail "persist Hysteria2 server BBR profile $label"
    fi
    server_node="$(materialize_node_paths "$node")" || fail "materialize Hysteria2 $label"
    manifest="${TEST_TEMP}/hys-$CASE_INDEX-nodes.json"
    server_config="${TEST_TEMP}/hys-$CASE_INDEX-server.json"
    client_config="${TEST_TEMP}/hys-$CASE_INDEX-client.json"
    jq -n --argjson node "$server_node" '{schema_version:1,nodes:[$node]}' >"$manifest"
    proxy_render_config "$server_core" "$manifest" "$PROXY_RELAY_FILE" "$server_version" >"$server_config" ||
        fail "render Hysteria2 server $label"
    uri="$(render_uri "$server_core" "$node")" || fail "render Hysteria2 URI $label"
    exit_json="$(make_exit "$client_core" "exit-$(printf '%016x' "$CASE_INDEX")" hysteria2 "$uri")" ||
        fail "prepare Hysteria2 exit $label"
    exit_json="$(proxy_relay_apply_client_options "$exit_json" "$TLS_CERT" '' '' "$bbr_profile")" ||
        fail "apply Hysteria2 client options $label"
    bundle="$(proxy_relay_render_outbound "$client_core" "$exit_json" "$client_version")" ||
        fail "render Hysteria2 client $label"
    if [[ "$server_core" == xray ]]; then
        jq -e --arg obfs "$obfs" '
            .inbounds[] | select(.tag | startswith("node-")) |
            .protocol == "hysteria" and .settings.version == 2 and
            .streamSettings.hysteriaSettings == {version:2} and
            .streamSettings.finalmask.quicParams ==
                {brutalUp:"100000000",brutalDown:"100000000"} and
            (if $obfs == "salamander" then
                 .streamSettings.finalmask.udp[0].type == "salamander"
             else (.streamSettings.finalmask | has("udp") | not) end)
        ' "$server_config" >/dev/null || fail "Xray native Hysteria2 server shape $label"
    elif [[ -n "$server_bbr" ]]; then
        jq -e --arg bbr "$server_bbr" '
            .inbounds[] | select(.tag | startswith("node-")) |
            .type == "hysteria2" and .bbr_profile == $bbr and
            .up_mbps == 100 and .down_mbps == 100
        ' "$server_config" >/dev/null || fail "sing-box server BBR profile/bandwidth shape $label"
    fi
    if [[ "$client_core" == xray ]]; then
        jq -e --arg obfs "$obfs" '
            .outbounds[0].protocol == "hysteria" and
            .outbounds[0].settings.version == 2 and
            .outbounds[0].streamSettings.hysteriaSettings.version == 2 and
            (if $obfs == "salamander" then
                 .outbounds[0].streamSettings.finalmask.udp[0].type == "salamander"
             else (.outbounds[0].streamSettings | has("finalmask") | not) end)
        ' <<<"$bundle" >/dev/null || fail "Xray native Hysteria2 client shape $label"
    else
        jq -e --arg obfs "$obfs" --arg bbr "$bbr_profile" '
            .outbounds[0].type == "hysteria2" and
            ((.outbounds[0] | has("up_mbps") or has("down_mbps")) | not) and
            (if $obfs == "none" then (.outbounds[0] | has("obfs") | not)
             else .outbounds[0].obfs.type == $obfs end) and
            (if $bbr == "" then (.outbounds[0] | has("bbr_profile") | not)
             else .outbounds[0].bbr_profile == $bbr end)
        ' <<<"$bundle" >/dev/null || fail "sing-box Hysteria2 client shape $label"
    fi
    render_client_config "$client_core" "$bundle" "$socks_port" "$client_config" debug
    validate_config "$server_core" "$server_binary" "$server_config" "${TEST_TEMP}/hys-$CASE_INDEX-server.check"
    validate_config "$client_core" "$client_binary" "$client_config" "${TEST_TEMP}/hys-$CASE_INDEX-client.check"
    start_core "$server_core" "$server_binary" "$server_config" "${TEST_TEMP}/hys-$CASE_INDEX-server.log"
    server_pid="${CORE_PIDS[-1]}"
    wait_listener udp 127.0.0.1 "$port" "$server_pid"
    start_core "$client_core" "$client_binary" "$client_config" "${TEST_TEMP}/hys-$CASE_INDEX-client.log"
    client_pid="${CORE_PIDS[-1]}"
    wait_listener tcp 127.0.0.1 "$socks_port" "$client_pid"
    token="hys-$label-tcp"
    socks_tcp_echo "$socks_port" "$token" || fail "Hysteria2 TCP $label"
    token="hys-$label-udp"
    socks_udp_echo "$socks_port" "$token" || fail "Hysteria2 UDP $label"
    kill -0 "$server_pid" >/dev/null 2>&1 || fail "Hysteria2 server exited: $label"
    stop_cores
}

run_hysteria_matrix() {
    local generation obfs server_core client_core
    ACTIVE_SB_BINARY="$SING_BOX_STABLE_BINARY"
    ACTIVE_SB_VERSION=1.14.0
    for generation in old new; do
        if [[ "$generation" == old ]]; then
            ACTIVE_XRAY_BINARY="$XRAY_OLD_BINARY"
            ACTIVE_XRAY_VERSION=26.3.27
        else
            ACTIVE_XRAY_BINARY="$XRAY_NEW_BINARY"
            ACTIVE_XRAY_VERSION=26.9.9
        fi
        for obfs in none salamander; do
            for server_core in sing-box xray; do
                for client_core in sing-box xray; do
                    run_hysteria_case "$generation-$server_core-to-$client_core-$obfs" \
                        "$server_core" "$client_core" "$obfs"
                done
            done
        done
        printf 'PASS: real Hysteria2 dual-core TCP/UDP matrix on Xray %s\n' "$ACTIVE_XRAY_VERSION"
    done
}

run_sing_box_knobs() {
    local profile
    ACTIVE_XRAY_BINARY="$XRAY_NEW_BINARY"
    ACTIVE_XRAY_VERSION=26.9.9
    ACTIVE_SB_BINARY="$SING_BOX_STABLE_BINARY"
    ACTIVE_SB_VERSION=1.14.0
    run_hysteria_case stable-gecko sing-box sing-box gecko
    for profile in conservative standard aggressive; do
        run_hysteria_case "bbr-$profile" xray sing-box none "$profile"
    done
    printf 'PASS: sing-box 1.14 Gecko and three negotiated-BBR profile fixtures\n'
}

run_sing_box_server_bbr() {
    local profile
    ACTIVE_XRAY_BINARY="$XRAY_NEW_BINARY"
    ACTIVE_XRAY_VERSION=26.9.9
    ACTIVE_SB_BINARY="$SING_BOX_STABLE_BINARY"
    ACTIVE_SB_VERSION=1.14.0
    for profile in conservative standard aggressive; do
        run_hysteria_case "server-bbr-$profile" sing-box sing-box none '' "$profile"
    done
    printf 'PASS: sing-box 1.14 three managed-server BBR profiles with retained bandwidth and BBR clients\n'
}

run_alpha_smoke() {
    ACTIVE_XRAY_BINARY="$XRAY_NEW_BINARY"
    ACTIVE_XRAY_VERSION=26.9.9
    ACTIVE_SB_BINARY="$SING_BOX_ALPHA_BINARY"
    ACTIVE_SB_VERSION=1.15.0-alpha.3
    run_hysteria_case alpha-gecko sing-box sing-box gecko
    printf 'PASS: sing-box 1.15.0-alpha.3 Hysteria2 compatibility smoke\n'
}

create_certificates
start_reality_target
start_echo_target
start_h2_target

case "$ENHANCEMENT_SCOPE" in
    all)
        test_xhttp_defaults
        run_xhttp_matrix
        run_hysteria_matrix
        run_sing_box_knobs
        run_sing_box_server_bbr
        run_alpha_smoke
        ;;
    xhttp)
        test_xhttp_defaults
        run_xhttp_matrix
        ;;
    hysteria) run_hysteria_matrix ;;
    sing-box-knobs) run_sing_box_knobs ;;
    sing-box-server-bbr) run_sing_box_server_bbr ;;
    alpha) run_alpha_smoke ;;
esac

printf 'PASS: phase 2 real protocol enhancement acceptance (%s)\n' "$ENHANCEMENT_SCOPE"
