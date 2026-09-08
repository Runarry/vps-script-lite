#!/usr/bin/env bash

# Destructive REALITY anti-relay acceptance for the dedicated host-vps-scripts
# machine. It binds a controlled TLS fallback on 127.0.0.1:443 and temporarily
# adds two test names to /etc/hosts. This script is intentionally not run by
# tests/run.sh.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
TEST_TEMP="$(mktemp -d)"
readonly TEST_TEMP
TEST_SYSTEM_ROOT="${TEST_TEMP}/root"
readonly TEST_SYSTEM_ROOT
TARGET_SNI="reality-guard-target.test"
EDITED_SNI="reality-guard-edited.test"
TARGET_PORT=443
TARGET_EVIDENCE="${TEST_TEMP}/target-arrivals.log"
HOSTS_BACKUP="${TEST_TEMP}/hosts.before"
TARGET_PID=''
OCCUPIED_PID=''
CORE_PID=''
HOSTS_CHANGED=0
NODE_RECORDS=()

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
blocked() { printf 'BLOCKED: %s\n' "$1" >&2; exit 3; }

stop_core() {
    if [[ -n "$CORE_PID" ]]; then
        kill "$CORE_PID" >/dev/null 2>&1 || true
        wait "$CORE_PID" >/dev/null 2>&1 || true
        CORE_PID=''
    fi
}

cleanup() {
    local original_status="$1" restore_status=0
    trap - EXIT
    stop_core
    if [[ -n "$TARGET_PID" ]]; then
        kill "$TARGET_PID" >/dev/null 2>&1 || true
        wait "$TARGET_PID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$OCCUPIED_PID" ]]; then
        kill "$OCCUPIED_PID" >/dev/null 2>&1 || true
        wait "$OCCUPIED_PID" >/dev/null 2>&1 || true
    fi
    if [[ "$HOSTS_CHANGED" == 1 && -f "$HOSTS_BACKUP" ]]; then
        cp -p -- "$HOSTS_BACKUP" /etc/hosts || restore_status=20
        if ((restore_status == 0)); then
            cmp -s -- "$HOSTS_BACKUP" /etc/hosts || restore_status=20
        fi
    fi
    if ((restore_status != 0)); then
        printf 'FAIL: could not restore /etc/hosts; recovery copy retained at %s\n' "$HOSTS_BACKUP" >&2
        printf 'EVIDENCE: retained test directory %s\n' "$TEST_TEMP" >&2
        exit "$restore_status"
    fi
    if ((original_status == 0)); then
        rm -rf -- "$TEST_TEMP"
    else
        printf 'EVIDENCE: retained failed test directory %s\n' "$TEST_TEMP" >&2
    fi
    exit "$original_status"
}
trap 'cleanup "$?"' EXIT

[[ "$EUID" == 0 ]] || blocked 'run as root on the dedicated host-vps-scripts machine'
for tool in bash cmp jq openssl python3 sha256sum ss timeout; do
    command -v "$tool" >/dev/null 2>&1 || blocked "missing required tool: $tool"
done

SING_BOX_BINARY="${SING_BOX_BINARY:-$(command -v sing-box 2>/dev/null || true)}"
XRAY_BINARY="${XRAY_BINARY:-$(command -v xray 2>/dev/null || true)}"
[[ -x "$SING_BOX_BINARY" ]] || blocked 'provide an executable SING_BOX_BINARY'
[[ -x "$XRAY_BINARY" ]] || blocked 'provide an executable XRAY_BINARY'
if ss -H -ltn | grep -Eq "(^|[[:space:]])([^[:space:]]*:)?${TARGET_PORT}([[:space:]]|$)"; then
    blocked '127.0.0.1:443 must be free for the controlled REALITY target'
fi
for port in 10000 43001 43002 43101 43102 43103 43104; do
    if ss -H -ltn | grep -Eq "(^|[[:space:]])([^[:space:]]*:)?${port}([[:space:]]|$)"; then
        blocked "required test port is already listening: $port"
    fi
done

mkdir -p -- "$TEST_SYSTEM_ROOT"
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
vps_cmd_init "REALITY anti-relay real test" "$TEST_ROOT"
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
# shellcheck source=../../commands/service/proxy/relay-forward.sh
source "${TEST_ROOT}/commands/service/proxy/relay-forward.sh"
# shellcheck source=../../commands/service/proxy/relay.sh
source "${TEST_ROOT}/commands/service/proxy/relay.sh"

proxy_common_init
proxy_relay_init
proxy_ensure_layout
mkdir -p -- "${TEST_SYSTEM_ROOT}/usr/local/bin" "${PROXY_STATE_DIR}/cores"
cp -p -- "$SING_BOX_BINARY" "${TEST_SYSTEM_ROOT}/usr/local/bin/sing-box"
cp -p -- "$XRAY_BINARY" "${TEST_SYSTEM_ROOT}/usr/local/bin/xray"
jq -n '{schema_version:1,core:"sing-box",binary:"/usr/local/bin/sing-box",owned:false,
    version:"real",release_tag:"",sha256:"real",service:"vpsctl-proxy-sing-box",
    installed_at:"2026-01-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z"}' \
    >"${PROXY_STATE_DIR}/cores/sing-box.json"
jq -n '{schema_version:1,core:"xray",binary:"/usr/local/bin/xray",owned:false,
    version:"real",release_tag:"",sha256:"real",service:"vpsctl-proxy-xray",
    installed_at:"2026-01-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z"}' \
    >"${PROXY_STATE_DIR}/cores/xray.json"
proxy_manifest_default >"$PROXY_MANIFEST"
proxy_relay_forward_manifest_default >"$PROXY_RELAY_FILE"

certificate="${TEST_TEMP}/target-cert.pem"
key="${TEST_TEMP}/target-key.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj "/CN=${TARGET_SNI}" \
    -addext "subjectAltName=DNS:${TARGET_SNI},DNS:${EDITED_SNI}" \
    -keyout "$key" -out "$certificate" >/dev/null 2>&1
: >"$TARGET_EVIDENCE"
cp -p -- /etc/hosts "$HOSTS_BACKUP"
HOSTS_CHANGED=1
printf '\n127.0.0.1 %s %s # vpsctl-reality-guard-real\n' "$TARGET_SNI" "$EDITED_SNI" >>/etc/hosts
python3 "${TEST_ROOT}/tests/fixtures/reality-anti-relay-target.py" \
    127.0.0.1 "$TARGET_PORT" "$certificate" "$key" "$TARGET_EVIDENCE" \
    >"${TEST_TEMP}/target.log" 2>&1 &
TARGET_PID=$!
python3 -m http.server 10000 --bind 127.0.0.1 >"${TEST_TEMP}/occupied.log" 2>&1 &
OCCUPIED_PID=$!

wait_listener() {
    local port="$1" pid="$2" log="$3" attempt
    for attempt in {1..100}; do
        kill -0 "$pid" >/dev/null 2>&1 || break
        ss -H -ltn | grep -Eq "(^|[[:space:]])([^[:space:]]*:)?${port}([[:space:]]|$)" && return 0
        sleep 0.05
    done
    [[ ! -f "$log" ]] || tail -n 80 -- "$log" >&2
    fail "listener did not start on TCP $port"
}
wait_listener "$TARGET_PORT" "$TARGET_PID" "${TEST_TEMP}/target.log"
wait_listener 10000 "$OCCUPIED_PID" "${TEST_TEMP}/occupied.log"

render_uri() {
    case "$1" in
        sing-box) proxy_sb_render_uri "$2" ;;
        xray) proxy_xray_render_uri "$2" ;;
        *) return 2 ;;
    esac
}

append_guarded_node() {
    local core="$1" profile="$2" ordinal="$3" public_port="$4" strategy="$5"
    local id name path service node guarded before_uri after_uri guard_port temporary
    printf -v id 'node-%016x' "$ordinal"
    name="real-guard-${profile}-${core}"
    path="/guard-${ordinal}"
    service="guard-${ordinal}"
    node="$(proxy_prepare_node_json "$core" "$profile" "$id" "$name" 127.0.0.1 "$public_port" \
        127.0.0.1 "$TARGET_SNI" "$path" "$service" self-signed '' '' none 100 200 bbr "$strategy")" ||
        fail "prepare node $profile/$core"
    before_uri="$(render_uri "$core" "$node")" || fail "render legacy URI $profile/$core"
    guarded="$(proxy_reality_guard_apply "$node" on)" || fail "enable guard $profile/$core"
    after_uri="$(render_uri "$core" "$guarded")" || fail "render guarded URI $profile/$core"
    [[ "$before_uri" == "$after_uri" ]] || fail "guard changed URI $profile/$core"
    jq -e '.tls.reality_guard.enabled == true and
        (.tls.reality_guard.listen_port >= 10000 and .tls.reality_guard.listen_port <= 29999)' \
        <<<"$guarded" >/dev/null || fail "guard state $profile/$core"
    guard_port="$(jq -r '.tls.reality_guard.listen_port' <<<"$guarded")"
    temporary="${TEST_TEMP}/nodes.append.json"
    jq --argjson node "$guarded" '.nodes += [$node]' "$PROXY_MANIFEST" >"$temporary"
    mv -- "$temporary" "$PROXY_MANIFEST"
    proxy_manifest_validate_file "$PROXY_MANIFEST" || fail "manifest after $profile/$core"
    NODE_RECORDS+=("${core}|${profile}|${id}|${public_port}|${guard_port}")
}

append_guarded_node sing-box vless-reality-vision 1 43001 prefer_ipv4
append_guarded_node sing-box anytls-reality 2 43002 auto
append_guarded_node xray vless-reality-vision 257 43101 auto
append_guarded_node xray vless-grpc-reality 258 43102 auto
append_guarded_node xray trojan-xhttp-reality 259 43103 auto
append_guarded_node xray trojan-grpc-reality 260 43104 auto

# The real listener on 10000 is skipped and all six guard ports are allocated
# monotonically across both cores.
expected_guard=10001
for record in "${NODE_RECORDS[@]}"; do
    IFS='|' read -r _core _profile _id _public guard <<<"$record"
    [[ "$guard" == "$expected_guard" ]] ||
        fail "guard allocation expected $expected_guard, got $guard for $_profile/$_core"
    expected_guard=$((expected_guard + 1))
done

# Bind one Xray node to a protocol relay exit and leave one sing-box node on a
# non-default IP policy. Their ordinary rules must remain scoped to the public
# node inbound and follow every guard rule.
relay_userinfo="$(jq -nr --arg value 'aes-256-gcm:guard-password' \
    '$value | @base64 | gsub("=+$"; "")')"
relay_uri="ss://${relay_userinfo}@127.0.0.1:49999#guard-relay"
relay_descriptor="$(proxy_relay_uri_parse "$relay_uri" shadowsocks-aes-256-gcm)" || fail 'parse relay isolation fixture'
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg uri "$relay_uri" --arg now "$now" --argjson descriptor "$relay_descriptor" '{
    schema_version:1,
    exits:[{id:"exit-0000000000000001",name:"guard-real",type:"protocol",core:"xray",profile:"shadowsocks-aes-256-gcm",
        uri:$uri,descriptor:$descriptor,endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint,
        created_at:$now,updated_at:$now}],
    bindings:[{id:"bind-0000000000000001",node_id:"node-0000000000000101",exit_id:"exit-0000000000000001",
        created_at:$now,updated_at:$now}],forwards:[]
}' >"$PROXY_RELAY_FILE"
proxy_relay_validate_file "$PROXY_RELAY_FILE" "$PROXY_MANIFEST" || fail 'relay isolation fixture validation'

SB_CONFIG="${TEST_TEMP}/sing-box.json"
XRAY_CONFIG="${TEST_TEMP}/xray.json"
proxy_render_config sing-box "$PROXY_MANIFEST" "$PROXY_RELAY_FILE" >"$SB_CONFIG" || fail 'render sing-box guard config'
proxy_render_config xray "$PROXY_MANIFEST" "$PROXY_RELAY_FILE" >"$XRAY_CONFIG" || fail 'render Xray guard config'
"$SING_BOX_BINARY" check -c "$SB_CONFIG" >"${TEST_TEMP}/sing-box-check.log" 2>&1 || {
    tail -n 100 -- "${TEST_TEMP}/sing-box-check.log" >&2
    fail 'real sing-box rejected guard config'
}
"$XRAY_BINARY" run -test -c "$XRAY_CONFIG" >"${TEST_TEMP}/xray-check.log" 2>&1 || {
    tail -n 100 -- "${TEST_TEMP}/xray-check.log" >&2
    fail 'real Xray rejected guard config'
}

jq -e '
    ([.inbounds[] | select(.tag | startswith("reality-guard-"))] | length) == 2 and
    ([.outbounds[] | select(.tag | startswith("reality-target-"))] | length) == 2 and
    (.route.rules[0:6] | all(.inbound[0] | startswith("reality-guard-"))) and
    (.route.rules[6].inbound == ["node-0000000000000001"]) and
    (.route.rules[6].outbound == "direct-node-0000000000000001") and
    any(.inbounds[]; .tag == "node-0000000000000001" and
        .tls.reality.handshake == {server:"127.0.0.1",server_port:10001})
' "$SB_CONFIG" >/dev/null || fail 'sing-box guard ordering, loopback target or IP-policy isolation'
jq -e '
    ([.inbounds[] | select(.tag | startswith("reality-guard-"))] | length) == 4 and
    ([.outbounds[] | select(.tag | startswith("reality-target-"))] | length) == 4 and
    (.routing.rules[0:8] | all(.inboundTag[0] | startswith("reality-guard-"))) and
    (.routing.rules[8].inboundTag == ["node-0000000000000101"]) and
    (.routing.rules[8].outboundTag | startswith("relay-exit-")) and
    any(.inbounds[]; .tag == "node-0000000000000101" and
        .streamSettings.realitySettings.target == "127.0.0.1:10003")
' "$XRAY_CONFIG" >/dev/null || fail 'Xray guard ordering, loopback target or relay isolation'

target_count() {
    awk 'END {print NR + 0}' "$TARGET_EVIDENCE"
}

wait_target_count() {
    local wanted="$1" attempt
    for attempt in {1..50}; do
        [[ "$(target_count)" -ge "$wanted" ]] && return 0
        sleep 0.05
    done
    return 1
}

tls_probe() {
    local port="$1" mode="$2" name="${3:-}" output=''
    if [[ "$mode" == sni ]]; then
        output="$(printf 'GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$name" |
            timeout 8 openssl s_client -connect "127.0.0.1:${port}" -servername "$name" -quiet 2>&1)" || true
    else
        output="$(printf 'GET / HTTP/1.1\r\nHost: none\r\nConnection: close\r\n\r\n' |
            timeout 8 openssl s_client -connect "127.0.0.1:${port}" -noservername -quiet 2>&1)" || true
    fi
    printf '%s' "$output"
    return 0
}

raw_probe() {
    local port="$1" hex="$2"
    python3 -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2)
s.settimeout(2)
s.sendall(bytes.fromhex(sys.argv[2]))
try:
    s.recv(4096)
except (ConnectionError, TimeoutError, socket.timeout):
    pass
s.close()
' "$port" "$hex" >/dev/null 2>&1 || true
}

assert_target_unchanged() {
    local before="$1" label="$2"
    sleep 1.25
    [[ "$(target_count)" == "$before" ]] || fail "$label reached controlled fallback target"
    kill -0 "$CORE_PID" >/dev/null 2>&1 || fail "$label coincided with core process exit"
}

assert_loopback_guard() {
    local port="$1" lines
    lines="$(ss -H -ltn | grep -E "(^|[[:space:]])127\\.0\\.0\\.1:${port}([[:space:]]|$)" || true)"
    [[ -n "$lines" ]] || fail "guard $port is not listening on IPv4 loopback"
    if ss -H -ltn | grep -E "(^|[[:space:]])(0\\.0\\.0\\.0|\\[::\\]|\\*):${port}([[:space:]]|$)" >/dev/null; then
        fail "guard $port is exposed beyond loopback"
    fi
}

start_core() {
    local core="$1" config="$2" log="$3" binary
    case "$core" in sing-box) binary="$SING_BOX_BINARY" ;; xray) binary="$XRAY_BINARY" ;; *) return 2 ;; esac
    "$binary" run -c "$config" >"$log" 2>&1 &
    CORE_PID=$!
}

exercise_core() {
    local core="$1" config="$2" log="$3" record record_core profile _id public guard
    local before output representative=''
    start_core "$core" "$config" "$log"
    for record in "${NODE_RECORDS[@]}"; do
        IFS='|' read -r record_core profile id public guard <<<"$record"
        [[ "$record_core" == "$core" ]] || continue
        representative="${representative:-$public}"
        wait_listener "$public" "$CORE_PID" "$log"
        wait_listener "$guard" "$CORE_PID" "$log"
        assert_loopback_guard "$guard"
        before="$(target_count)"
        output="$(tls_probe "$public" sni "$TARGET_SNI")"
        wait_target_count "$((before + 1))" || {
            tail -n 100 -- "$log" >&2
            fail "correct SNI did not reach target for $profile/$core"
        }
        [[ "$output" == *vpsctl-reality-fallback-ok* ]] || fail "correct SNI fallback response for $profile/$core"
        [[ "$(target_count)" == "$((before + 1))" ]] || fail "unexpected target connection count for $profile/$core"
    done

    before="$(target_count)"
    output="$(tls_probe "$representative" sni wrong-guard-target.test)"
    [[ "$output" != *vpsctl-reality-fallback-ok* ]] || fail "$core wrong SNI received fallback"
    assert_target_unchanged "$before" "$core wrong SNI"
    output="$(tls_probe "$representative" sni "prefix.${TARGET_SNI}")"
    [[ "$output" != *vpsctl-reality-fallback-ok* ]] || fail "$core containing SNI received fallback"
    assert_target_unchanged "$before" "$core domain-containing SNI"
    output="$(tls_probe "$representative" none)"
    [[ "$output" != *vpsctl-reality-fallback-ok* ]] || fail "$core no-SNI TLS received fallback"
    assert_target_unchanged "$before" "$core no-SNI TLS"
    raw_probe "$representative" '474554202f20485454502f312e300d0a0d0a'
    assert_target_unchanged "$before" "$core non-TLS payload"
    raw_probe "$representative" '16030100200100001c0303'
    assert_target_unchanged "$before" "$core truncated TLS ClientHello"
    output="$(tls_probe "$representative" sni "$TARGET_SNI")"
    wait_target_count "$((before + 1))" || fail "$core post-negative positive control did not reach target"
    [[ "$output" == *vpsctl-reality-fallback-ok* ]] || fail "$core post-negative positive control response"
    [[ "$(target_count)" == "$((before + 1))" ]] || fail "$core post-negative target connection count"
    stop_core
}

exercise_core sing-box "$SB_CONFIG" "${TEST_TEMP}/sing-box.log"
exercise_core xray "$XRAY_CONFIG" "${TEST_TEMP}/xray.log"

# Editing an enabled node's SNI must immediately revoke the old exact whitelist
# while retaining the guard port and REALITY keys.
edit_id='node-0000000000000101'
edit_public=43101
edit_guard="$(jq -r --arg id "$edit_id" '.nodes[] | select(.id == $id) | .tls.reality_guard.listen_port' "$PROXY_MANIFEST")"
keys_before="$(jq -Sc --arg id "$edit_id" '.nodes[] | select(.id == $id) | .credentials |
    {private_key,public_key,short_id}' "$PROXY_MANIFEST")"
jq --arg id "$edit_id" --arg sni "$EDITED_SNI" '
    (.nodes[] | select(.id == $id) | .tls.server_name) = $sni
' "$PROXY_MANIFEST" >"${TEST_TEMP}/nodes.edited.json"
mv -- "${TEST_TEMP}/nodes.edited.json" "$PROXY_MANIFEST"
proxy_manifest_validate_file "$PROXY_MANIFEST" || fail 'edited SNI manifest validation'
[[ "$edit_guard" == "$(jq -r --arg id "$edit_id" '.nodes[] | select(.id == $id) | .tls.reality_guard.listen_port' "$PROXY_MANIFEST")" ]] ||
    fail 'SNI edit changed guard port'
[[ "$keys_before" == "$(jq -Sc --arg id "$edit_id" '.nodes[] | select(.id == $id) | .credentials |
    {private_key,public_key,short_id}' "$PROXY_MANIFEST")" ]] || fail 'SNI edit changed REALITY keys'
proxy_render_config xray "$PROXY_MANIFEST" "$PROXY_RELAY_FILE" >"$XRAY_CONFIG" || fail 'render edited-SNI Xray config'
"$XRAY_BINARY" run -test -c "$XRAY_CONFIG" >/dev/null 2>&1 || fail 'real Xray rejected edited-SNI config'
start_core xray "$XRAY_CONFIG" "${TEST_TEMP}/xray-edited.log"
wait_listener "$edit_public" "$CORE_PID" "${TEST_TEMP}/xray-edited.log"
wait_listener "$edit_guard" "$CORE_PID" "${TEST_TEMP}/xray-edited.log"
before="$(target_count)"
output="$(tls_probe "$edit_public" sni "$TARGET_SNI")"
[[ "$output" != *vpsctl-reality-fallback-ok* ]] || fail 'old SNI received fallback after edit'
assert_target_unchanged "$before" 'old SNI after edit'
output="$(tls_probe "$edit_public" sni "$EDITED_SNI")"
wait_target_count "$((before + 1))" || fail 'edited SNI did not reach controlled target'
[[ "$output" == *vpsctl-reality-fallback-ok* ]] || fail 'edited SNI fallback response'
[[ "$(target_count)" == "$((before + 1))" ]] || fail 'edited SNI target connection count'
stop_core

printf 'PASS: real REALITY anti-relay config, fallback, negative filtering and SNI-edit acceptance (%s target arrivals)\n' \
    "$(target_count)"
