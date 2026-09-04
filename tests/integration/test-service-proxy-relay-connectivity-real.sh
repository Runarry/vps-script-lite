#!/usr/bin/env bash

# Real end-to-end protocol relay acceptance for the dedicated
# host-vps-scripts machine.  For every available profile/core pair it runs:
# local SOCKS client -> managed Shadowsocks entry -> tested protocol exit ->
# local HTTP target.  Set SING_BOX_BINARY and/or XRAY_BINARY to real binaries.
# This script is syntax-checked, but intentionally not run by tests/run.sh.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
TEST_TEMP="$(mktemp -d)"
readonly TEST_TEMP
TEST_SYSTEM_ROOT="${TEST_TEMP}/root"
mkdir -p -- "$TEST_SYSTEM_ROOT"
TARGET_PORT=47999
TARGET_PID=''
CASE_PIDS=()
CASE_LOGS=()

stop_case() {
    local pid
    for pid in "${CASE_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
    for pid in "${CASE_PIDS[@]}"; do wait "$pid" >/dev/null 2>&1 || true; done
    CASE_PIDS=()
    CASE_LOGS=()
}

cleanup() {
    stop_case
    [[ -z "$TARGET_PID" ]] || kill "$TARGET_PID" >/dev/null 2>&1 || true
    [[ -z "$TARGET_PID" ]] || wait "$TARGET_PID" >/dev/null 2>&1 || true
    rm -rf -- "$TEST_TEMP"
}
trap cleanup EXIT

for tool in bash curl jq openssl python3 sha256sum ss; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'FAIL: missing %s\n' "$tool" >&2; exit 3; }
done

SING_BOX_BINARY="${SING_BOX_BINARY:-$(command -v sing-box 2>/dev/null || true)}"
XRAY_BINARY="${XRAY_BINARY:-$(command -v xray 2>/dev/null || true)}"
CONNECTIVITY_CORE="${CONNECTIVITY_CORE:-all}"
CONNECTIVITY_PROFILE="${CONNECTIVITY_PROFILE:-all}"
CONNECTIVITY_SWITCH_SMOKE_ONLY="${CONNECTIVITY_SWITCH_SMOKE_ONLY:-0}"
# Xray's official gRPC REALITY example uses Yahoo; unlike some otherwise valid
# TLS sites it consistently supports the complete REALITY+HTTP/2 handshake.
CONNECTIVITY_SNI="${CONNECTIVITY_SNI:-www.yahoo.com}"
CONNECTIVITY_LANDING_ADDRESS="${CONNECTIVITY_LANDING_ADDRESS:-127.0.0.1}"
ALLOW_XRAY_TROJAN_GRPC_REALITY_XFAIL="${ALLOW_XRAY_TROJAN_GRPC_REALITY_XFAIL:-0}"
[[ -n "$SING_BOX_BINARY" || -n "$XRAY_BINARY" ]] || {
    printf 'FAIL: provide SING_BOX_BINARY and/or XRAY_BINARY\n' >&2
    exit 3
}
case "$CONNECTIVITY_CORE" in all | sing-box | xray) ;; *) printf 'FAIL: invalid CONNECTIVITY_CORE\n' >&2; exit 2 ;; esac
case "$CONNECTIVITY_SWITCH_SMOKE_ONLY" in 0 | 1) ;; *)
    printf 'FAIL: CONNECTIVITY_SWITCH_SMOKE_ONLY must be 0 or 1\n' >&2
    exit 2
    ;;
esac
case "$ALLOW_XRAY_TROJAN_GRPC_REALITY_XFAIL" in 0 | 1) ;; *)
    printf 'FAIL: ALLOW_XRAY_TROJAN_GRPC_REALITY_XFAIL must be 0 or 1\n' >&2
    exit 2
    ;;
esac

export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_ENV_INIT=systemd
export VPSCTL_ENV_PACKAGE_MANAGER=apt-get
export VPSCTL_ENV_ARCH=x86_64
export VPSCTL_NON_INTERACTIVE=1
export VPSCTL_NO_COLOR=1

# shellcheck source=../../lib/command.sh
source "${TEST_ROOT}/lib/command.sh"
vps_cmd_init "relay real connectivity test" "$TEST_ROOT"
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
mkdir -p -- "${TEST_SYSTEM_ROOT}/usr/local/bin"
if [[ -n "$SING_BOX_BINARY" ]]; then cp -p -- "$SING_BOX_BINARY" "${TEST_SYSTEM_ROOT}/usr/local/bin/sing-box"; fi
if [[ -n "$XRAY_BINARY" ]]; then cp -p -- "$XRAY_BINARY" "${TEST_SYSTEM_ROOT}/usr/local/bin/xray"; fi

shared_cert="${TEST_TEMP}/shared-cert.pem"
shared_key="${TEST_TEMP}/shared-key.pem"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=${CONNECTIVITY_SNI}" \
    -addext "subjectAltName=DNS:${CONNECTIVITY_SNI}" -keyout "$shared_key" -out "$shared_cert" >/dev/null 2>&1

HTTP_CODE='
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"vpsctl-relay-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, _format, *_args):
        pass
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
'
python3 -c "$HTTP_CODE" "$TARGET_PORT" >"${TEST_TEMP}/http.log" 2>&1 &
TARGET_PID=$!

wait_listener() {
    local mode="$1" port="$2" pid="$3" log="$4" attempt
    for attempt in {1..100}; do
        kill -0 "$pid" >/dev/null 2>&1 || break
        if [[ "$mode" == udp ]]; then
            ss -H -lun | awk '{print $4}' | grep -Eq ":${port}$" && return 0
        else
            ss -H -ltn | awk '{print $4}' | grep -Eq ":${port}$" && return 0
        fi
        sleep 0.05
    done
    printf 'FAIL: listener %s/%s did not start\n' "$port" "$mode" >&2
    [[ ! -f "$log" ]] || tail -n 80 -- "$log" >&2
    return 1
}

wait_listener tcp "$TARGET_PORT" "$TARGET_PID" "${TEST_TEMP}/http.log"

start_core() {
    local core="$1" binary="$2" config="$3" log="$4"
    case "$core" in
        sing-box) "$binary" run -c "$config" >"$log" 2>&1 & ;;
        xray) "$binary" run -c "$config" >"$log" 2>&1 & ;;
    esac
    CASE_PIDS+=("$!")
    CASE_LOGS+=("$log")
}

show_case_logs() {
    local log
    for log in "${CASE_LOGS[@]}"; do
        printf '%s\n' "--- ${log##*/} ---" >&2
        [[ ! -f "$log" ]] || tail -n 100 -- "$log" >&2
    done
}

materialize_certificate_paths() {
    local node="$1"
    jq --arg root "$TEST_SYSTEM_ROOT" '
        if .tls.certificate_path != "" then
            .tls.certificate_path=($root + .tls.certificate_path) |
            .tls.key_path=($root + .tls.key_path) |
            .tls.insecure=true
        else . end
    ' <<<"$node"
}

render_uri() {
    local core="$1" node="$2"
    case "$core" in
        sing-box) proxy_sb_render_uri "$node" ;;
        xray) proxy_xray_render_uri "$node" ;;
    esac
}

validate_config() {
    local core="$1" binary="$2" config="$3"
    case "$core" in
        sing-box) "$binary" check -c "$config" >/dev/null ;;
        xray) "$binary" run -test -c "$config" >/dev/null ;;
    esac
}

render_shadowsocks_client_config() {
    local uri="$1" port="$2" output="$3" descriptor client_exit bundle
    descriptor="$(proxy_relay_uri_parse "$uri" shadowsocks-aes-256-gcm)" || return $?
    client_exit="$(jq -cn --arg id exit-fffffffffffffffe --arg name switch-client \
        --arg uri "$uri" --argjson descriptor "$descriptor" '
        {id:$id,name:$name,type:"protocol",core:"sing-box",profile:"shadowsocks-aes-256-gcm",uri:$uri,
         descriptor:$descriptor,endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint}')" || return 10
    bundle="$(proxy_relay_render_outbound sing-box "$client_exit")" || return $?
    jq -n --argjson bundle "$bundle" --argjson port "$port" '{
        log:{level:"warn"},
        inbounds:[{type:"socks",tag:"client",listen:"127.0.0.1",listen_port:$port}],
        outbounds:$bundle.outbounds,
        route:{rules:[{inbound:["client"],action:"route",outbound:$bundle.target_tag}],final:$bundle.target_tag}
    }' >"$output"
}

assert_switch_curl() {
    local socks_port="$1" label="$2" response='' curl_status=0
    response="$(curl --noproxy '' --socks5-hostname "127.0.0.1:${socks_port}" \
        --connect-timeout 5 --max-time 15 -fsS "http://127.0.0.1:${TARGET_PORT}/core-switch")" || curl_status=$?
    if ((curl_status != 0)) || [[ "$response" != vpsctl-relay-ok ]]; then
        printf 'FAIL: %s (curl=%s, response=%s)\n' "$label" "$curl_status" "$response" >&2
        show_case_logs
        return 1
    fi
    printf 'PASS: %s\n' "$label"
}

run_node_core_switch_smoke() {
    local case_dir="${TEST_TEMP}/core-switch-shared" server_port=57101 socks_port=57102
    local node_id=node-fffffffffffff001 source_node target_node source_uri target_uri
    local source_manifest target_manifest empty_relay source_config target_config client_config
    local server_pid client_pid
    mkdir -p -- "$case_dir"

    source_node="$(proxy_prepare_node_json sing-box shadowsocks-aes-256-gcm "$node_id" \
        switch-shared 127.0.0.1 "$server_port" 127.0.0.1 "$CONNECTIVITY_SNI" /unused unused \
        self-signed '' '' none 100 200 bbr)" || return 1
    target_node="$(jq '.core="xray"' <<<"$source_node")" || return 1
    source_uri="$(render_uri sing-box "$source_node")" || return 1
    target_uri="$(render_uri xray "$target_node")" || return 1
    [[ "$target_uri" == "$source_uri" ]] || {
        printf 'FAIL: shared node client URI changed across core switch\n' >&2
        return 1
    }

    source_manifest="${case_dir}/source-nodes.json"
    target_manifest="${case_dir}/target-nodes.json"
    empty_relay="${case_dir}/empty-relay.json"
    source_config="${case_dir}/source.json"
    target_config="${case_dir}/target.json"
    client_config="${case_dir}/client.json"
    jq -n --argjson node "$source_node" '{schema_version:1,nodes:[$node]}' >"$source_manifest"
    jq -n --argjson node "$target_node" '{schema_version:1,nodes:[$node]}' >"$target_manifest"
    proxy_relay_default >"$empty_relay"
    proxy_render_config sing-box "$source_manifest" "$empty_relay" >"$source_config" || return 1
    proxy_render_config xray "$target_manifest" "$empty_relay" >"$target_config" || return 1
    render_shadowsocks_client_config "$source_uri" "$socks_port" "$client_config" || return 1
    validate_config sing-box "$SING_BOX_BINARY" "$source_config" || return 1
    validate_config xray "$XRAY_BINARY" "$target_config" || return 1
    validate_config sing-box "$SING_BOX_BINARY" "$client_config" || return 1

    start_core sing-box "$SING_BOX_BINARY" "$source_config" "${case_dir}/source.log"
    server_pid="${CASE_PIDS[-1]}"
    wait_listener tcp "$server_port" "$server_pid" "${case_dir}/source.log" || { show_case_logs; return 1; }
    start_core sing-box "$SING_BOX_BINARY" "$client_config" "${case_dir}/client-source.log"
    client_pid="${CASE_PIDS[-1]}"
    wait_listener tcp "$socks_port" "$client_pid" "${case_dir}/client-source.log" || { show_case_logs; return 1; }
    assert_switch_curl "$socks_port" 'shared Shadowsocks node before sing-box to Xray switch' || return 1
    stop_case

    start_core xray "$XRAY_BINARY" "$target_config" "${case_dir}/target.log"
    server_pid="${CASE_PIDS[-1]}"
    wait_listener tcp "$server_port" "$server_pid" "${case_dir}/target.log" || { show_case_logs; return 1; }
    start_core sing-box "$SING_BOX_BINARY" "$client_config" "${case_dir}/client-target.log"
    client_pid="${CASE_PIDS[-1]}"
    wait_listener tcp "$socks_port" "$client_pid" "${case_dir}/client-target.log" || { show_case_logs; return 1; }
    assert_switch_curl "$socks_port" 'shared Shadowsocks node after sing-box to Xray switch' || return 1
    stop_case
}

run_relay_core_switch_smoke() {
    local case_dir="${TEST_TEMP}/core-switch-relay" landing_port=57111 entry_port=57112 socks_port=57113
    local landing_id=node-fffffffffffff011 entry_id=node-fffffffffffff012
    local exit_id=exit-fffffffffffff011 bind_id=bind-fffffffffffff011 now
    local landing entry_source entry_target landing_uri entry_source_uri entry_target_uri descriptor
    local landing_manifest source_manifest target_manifest empty_relay source_relay target_relay
    local landing_config source_config target_config client_config landing_pid relay_pid client_pid
    mkdir -p -- "$case_dir"

    landing="$(proxy_prepare_node_json sing-box shadowsocks-aes-256-gcm "$landing_id" \
        switch-relay-landing 127.0.0.1 "$landing_port" 127.0.0.1 "$CONNECTIVITY_SNI" /unused unused \
        self-signed '' '' none 100 200 bbr)" || return 1
    entry_source="$(proxy_prepare_node_json sing-box shadowsocks-aes-256-gcm "$entry_id" \
        switch-relay-entry 127.0.0.1 "$entry_port" 127.0.0.1 "$CONNECTIVITY_SNI" /unused unused \
        self-signed '' '' none 100 200 bbr)" || return 1
    entry_target="$(jq '.core="xray"' <<<"$entry_source")" || return 1
    landing_uri="$(render_uri sing-box "$landing")" || return 1
    entry_source_uri="$(render_uri sing-box "$entry_source")" || return 1
    entry_target_uri="$(render_uri xray "$entry_target")" || return 1
    [[ "$entry_target_uri" == "$entry_source_uri" ]] || {
        printf 'FAIL: relay entry client URI changed across core switch\n' >&2
        return 1
    }
    descriptor="$(proxy_relay_uri_parse "$landing_uri" shadowsocks-aes-256-gcm)" || return 1
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    landing_manifest="${case_dir}/landing-nodes.json"
    source_manifest="${case_dir}/source-nodes.json"
    target_manifest="${case_dir}/target-nodes.json"
    empty_relay="${case_dir}/empty-relay.json"
    source_relay="${case_dir}/source-relay.json"
    target_relay="${case_dir}/target-relay.json"
    landing_config="${case_dir}/landing.json"
    source_config="${case_dir}/source.json"
    target_config="${case_dir}/target.json"
    client_config="${case_dir}/client.json"
    jq -n --argjson node "$landing" '{schema_version:1,nodes:[$node]}' >"$landing_manifest"
    jq -n --argjson node "$entry_source" '{schema_version:1,nodes:[$node]}' >"$source_manifest"
    jq -n --argjson node "$entry_target" '{schema_version:1,nodes:[$node]}' >"$target_manifest"
    proxy_relay_default >"$empty_relay"
    jq -n --arg exit_id "$exit_id" --arg bind_id "$bind_id" --arg node_id "$entry_id" \
        --arg uri "$landing_uri" --arg now "$now" --argjson descriptor "$descriptor" '
        {schema_version:1,
         exits:[{id:$exit_id,name:"switch-relay-exit",type:"protocol",core:"sing-box",
                 profile:"shadowsocks-aes-256-gcm",uri:$uri,descriptor:$descriptor,
                 endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint,
                 created_at:$now,updated_at:$now}],
         bindings:[{id:$bind_id,node_id:$node_id,exit_id:$exit_id,created_at:$now,updated_at:$now}],
         forwards:[]}' >"$source_relay"
    jq '(.exits[0].core)="xray"' "$source_relay" >"$target_relay"
    proxy_render_config sing-box "$landing_manifest" "$empty_relay" >"$landing_config" || return 1
    proxy_render_config sing-box "$source_manifest" "$source_relay" >"$source_config" || return 1
    proxy_render_config xray "$target_manifest" "$target_relay" >"$target_config" || return 1
    render_shadowsocks_client_config "$entry_source_uri" "$socks_port" "$client_config" || return 1
    validate_config sing-box "$SING_BOX_BINARY" "$landing_config" || return 1
    validate_config sing-box "$SING_BOX_BINARY" "$source_config" || return 1
    validate_config xray "$XRAY_BINARY" "$target_config" || return 1
    validate_config sing-box "$SING_BOX_BINARY" "$client_config" || return 1

    start_core sing-box "$SING_BOX_BINARY" "$landing_config" "${case_dir}/landing-source.log"
    landing_pid="${CASE_PIDS[-1]}"
    wait_listener tcp "$landing_port" "$landing_pid" "${case_dir}/landing-source.log" || { show_case_logs; return 1; }
    start_core sing-box "$SING_BOX_BINARY" "$source_config" "${case_dir}/source.log"
    relay_pid="${CASE_PIDS[-1]}"
    wait_listener tcp "$entry_port" "$relay_pid" "${case_dir}/source.log" || { show_case_logs; return 1; }
    start_core sing-box "$SING_BOX_BINARY" "$client_config" "${case_dir}/client-source.log"
    client_pid="${CASE_PIDS[-1]}"
    wait_listener tcp "$socks_port" "$client_pid" "${case_dir}/client-source.log" || { show_case_logs; return 1; }
    assert_switch_curl "$socks_port" 'exclusive Shadowsocks relay before synchronized core switch' || return 1
    stop_case

    start_core sing-box "$SING_BOX_BINARY" "$landing_config" "${case_dir}/landing-target.log"
    landing_pid="${CASE_PIDS[-1]}"
    wait_listener tcp "$landing_port" "$landing_pid" "${case_dir}/landing-target.log" || { show_case_logs; return 1; }
    start_core xray "$XRAY_BINARY" "$target_config" "${case_dir}/target.log"
    relay_pid="${CASE_PIDS[-1]}"
    wait_listener tcp "$entry_port" "$relay_pid" "${case_dir}/target.log" || { show_case_logs; return 1; }
    start_core sing-box "$SING_BOX_BINARY" "$client_config" "${case_dir}/client-target.log"
    client_pid="${CASE_PIDS[-1]}"
    wait_listener tcp "$socks_port" "$client_pid" "${case_dir}/client-target.log" || { show_case_logs; return 1; }
    assert_switch_curl "$socks_port" 'exclusive Shadowsocks relay after synchronized core switch' || return 1
    stop_case
}

switch_smoke_count=0
if [[ -n "$SING_BOX_BINARY" && -n "$XRAY_BINARY" ]]; then
    run_node_core_switch_smoke || exit 1
    switch_smoke_count=$((switch_smoke_count + 1))
    run_relay_core_switch_smoke || exit 1
    switch_smoke_count=$((switch_smoke_count + 1))
else
    printf 'SKIP: real node core switch smoke requires both sing-box and Xray binaries\n'
fi
if [[ "$CONNECTIVITY_SWITCH_SMOKE_ONLY" == 1 ]]; then
    printf 'PASS: %s real node core switch smoke cases\n' "$switch_smoke_count"
    exit 0
fi

count=0
pass_count=0
xfail_count=0
while IFS=$'\t' read -r profile _label; do
    [[ -n "$profile" ]] || continue
    [[ "$CONNECTIVITY_PROFILE" == all || "$CONNECTIVITY_PROFILE" == "$profile" ]] || continue
    while IFS= read -r core; do
        [[ -n "$core" ]] || continue
        [[ "$CONNECTIVITY_CORE" == all || "$CONNECTIVITY_CORE" == "$core" ]] || continue
        binary=''
        case "$core" in sing-box) binary="$SING_BOX_BINARY" ;; xray) binary="$XRAY_BINARY" ;; esac
        [[ -n "$binary" ]] || continue

        count=$((count + 1))
        landing_port=$((48000 + count * 3))
        entry_port=$((landing_port + 1))
        socks_port=$((landing_port + 2))
        printf -v landing_id 'node-%016x' "$((count * 2 - 1))"
        printf -v entry_id 'node-%016x' "$((count * 2))"
        printf -v exit_id 'exit-%016x' "$count"
        printf -v bind_id 'bind-%016x' "$count"
        case_dir="${TEST_TEMP}/case-${count}-${core}-${profile}"
        mkdir -p -- "$case_dir"

        obfs=none
        [[ "$profile" != hysteria2 ]] || obfs=salamander
        landing="$(proxy_prepare_node_json "$core" "$profile" "$landing_id" "landing-${profile}" \
            "$CONNECTIVITY_LANDING_ADDRESS" "$landing_port" "$CONNECTIVITY_LANDING_ADDRESS" "$CONNECTIVITY_SNI" /relay-connect relay-connect \
            imported "$shared_cert" "$shared_key" "$obfs" 100 200 bbr)" || {
            printf 'FAIL: landing fixture %s/%s\n' "$profile" "$core" >&2; exit 1;
        }
        landing="$(materialize_certificate_paths "$landing")" || exit 1
        entry="$(proxy_prepare_node_json "$core" shadowsocks-aes-256-gcm "$entry_id" "entry-${profile}" \
            127.0.0.1 "$entry_port" 127.0.0.1 "$CONNECTIVITY_SNI" /unused unused self-signed '' '' none 100 200 bbr)" || {
            printf 'FAIL: entry fixture %s/%s\n' "$profile" "$core" >&2; exit 1;
        }

        landing_uri="$(render_uri "$core" "$landing")" || exit 1
        entry_uri="$(render_uri "$core" "$entry")" || exit 1
        descriptor="$(proxy_relay_uri_parse "$landing_uri" "$profile")" || exit 1
        entry_descriptor="$(proxy_relay_uri_parse "$entry_uri" shadowsocks-aes-256-gcm)" || exit 1
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        landing_manifest="${case_dir}/landing-nodes.json"
        entry_manifest="${case_dir}/entry-nodes.json"
        empty_relay="${case_dir}/empty-relay.json"
        relay="${case_dir}/relay.json"
        landing_config="${case_dir}/landing.json"
        relay_config="${case_dir}/relay-core.json"
        client_config="${case_dir}/client.json"
        jq -n --argjson node "$landing" '{schema_version:1,nodes:[$node]}' >"$landing_manifest"
        jq -n --argjson node "$entry" '{schema_version:1,nodes:[$node]}' >"$entry_manifest"
        proxy_relay_default >"$empty_relay"
        jq -n --arg exit_id "$exit_id" --arg bind_id "$bind_id" --arg node_id "$entry_id" \
            --arg name "landing-${profile}" --arg core "$core" --arg profile "$profile" \
            --arg uri "$landing_uri" --arg now "$now" --argjson descriptor "$descriptor" '
            {schema_version:1,
             exits:[{id:$exit_id,name:$name,type:"protocol",core:$core,profile:$profile,uri:$uri,
                     descriptor:$descriptor,endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint,
                     created_at:$now,updated_at:$now}],
             bindings:[{id:$bind_id,node_id:$node_id,exit_id:$exit_id,created_at:$now,updated_at:$now}],
             forwards:[]}' >"$relay"
        proxy_render_config "$core" "$landing_manifest" "$empty_relay" >"$landing_config" || exit 1
        proxy_render_config "$core" "$entry_manifest" "$relay" >"$relay_config" || exit 1
        if [[ "$core" == xray ]]; then
            jq '.log.loglevel="debug"' "$landing_config" >"${landing_config}.debug"
            mv -- "${landing_config}.debug" "$landing_config"
            jq '.log.loglevel="debug"' "$relay_config" >"${relay_config}.debug"
            mv -- "${relay_config}.debug" "$relay_config"
        fi

        client_exit="$(jq -cn --arg id exit-ffffffffffffffff --arg name client --arg core "$core" \
            --arg profile shadowsocks-aes-256-gcm --arg uri "$entry_uri" --argjson descriptor "$entry_descriptor" '
            {id:$id,name:$name,type:"protocol",core:$core,profile:$profile,uri:$uri,
             descriptor:$descriptor,endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint}')"
        client_bundle="$(proxy_relay_render_outbound "$core" "$client_exit")" || exit 1
        if [[ "$core" == sing-box ]]; then
            jq -n --argjson bundle "$client_bundle" --argjson port "$socks_port" '{
                log:{level:"warn"},
                inbounds:[{type:"socks",tag:"client",listen:"127.0.0.1",listen_port:$port}],
                outbounds:$bundle.outbounds,
                route:{rules:[{inbound:["client"],action:"route",outbound:$bundle.target_tag}],final:$bundle.target_tag}
            }' >"$client_config"
        else
            jq -n --argjson bundle "$client_bundle" --argjson port "$socks_port" '{
                log:{loglevel:"debug"},
                inbounds:[{tag:"client",listen:"127.0.0.1",port:$port,protocol:"socks",settings:{auth:"noauth",udp:true}}],
                outbounds:$bundle.outbounds,
                routing:{rules:[{type:"field",inboundTag:["client"],outboundTag:$bundle.target_tag}]}
            }' >"$client_config"
        fi

        validate_config "$core" "$binary" "$landing_config" || exit 1
        validate_config "$core" "$binary" "$relay_config" || exit 1
        validate_config "$core" "$binary" "$client_config" || exit 1
        start_core "$core" "$binary" "$landing_config" "${case_dir}/landing.log"
        landing_pid="${CASE_PIDS[-1]}"
        landing_network="$(jq -r '.network_hint' <<<"$descriptor")"
        [[ "$landing_network" != both ]] || landing_network=tcp
        wait_listener "$landing_network" "$landing_port" "$landing_pid" "${case_dir}/landing.log" || { show_case_logs; exit 1; }
        start_core "$core" "$binary" "$relay_config" "${case_dir}/relay.log"
        relay_pid="${CASE_PIDS[-1]}"
        wait_listener tcp "$entry_port" "$relay_pid" "${case_dir}/relay.log" || { show_case_logs; exit 1; }
        start_core "$core" "$binary" "$client_config" "${case_dir}/client.log"
        client_pid="${CASE_PIDS[-1]}"
        wait_listener tcp "$socks_port" "$client_pid" "${case_dir}/client.log" || { show_case_logs; exit 1; }

        response=''
        curl_status=0
        response="$(curl --noproxy '' --socks5-hostname "127.0.0.1:${socks_port}" \
            --connect-timeout 5 --max-time 15 -fsS "http://127.0.0.1:${TARGET_PORT}/relay")" || curl_status=$?
        if ((curl_status != 0)) || [[ "$response" != vpsctl-relay-ok ]]; then
            # Xray 26.3.27 and 26.6.27 complete REALITY authentication for
            # Trojan+gRPC+REALITY, then close the connection while gRPC reads
            # the HTTP/2 server preface. Keep this opt-in and signature-bound:
            # strict runs still fail, while a future upstream fix becomes an
            # XPASS below instead of remaining silently hidden.
            if [[ "$ALLOW_XRAY_TROJAN_GRPC_REALITY_XFAIL" == 1 &&
                "$core" == xray && "$profile" == trojan-grpc-reality ]] &&
                grep -Fq 'error reading server preface' "${case_dir}/relay.log" &&
                grep -Fq 'use of closed network connection' "${case_dir}/relay.log" &&
                kill -0 "$landing_pid" >/dev/null 2>&1; then
                printf 'XFAIL: connectivity %s/%s (upstream gRPC/REALITY server-preface closure)\n' "$profile" "$core"
                xfail_count=$((xfail_count + 1))
                stop_case
                continue
            fi
            printf 'FAIL: connectivity %s/%s (curl=%s, response=%s)\n' "$profile" "$core" "$curl_status" "$response" >&2
            show_case_logs
            exit 1
        fi
        if [[ "$ALLOW_XRAY_TROJAN_GRPC_REALITY_XFAIL" == 1 &&
            "$core" == xray && "$profile" == trojan-grpc-reality ]]; then
            printf 'XPASS: connectivity %s/%s; remove the upstream-failure allowance\n' "$profile" "$core" >&2
            exit 1
        fi
        printf 'PASS: connectivity %s/%s\n' "$profile" "$core"
        pass_count=$((pass_count + 1))
        stop_case
    done < <(proxy_profile_cores "$profile")
done < <(proxy_all_profiles)

((count > 0)) || { printf 'FAIL: no matching profile/core cases\n' >&2; exit 3; }
printf 'PASS: %s real protocol relay connectivity cases (%s passed, %s expected upstream failure)\n' \
    "$count" "$pass_count" "$xfail_count"
printf 'PASS: %s real node core switch smoke cases\n' "$switch_smoke_count"
