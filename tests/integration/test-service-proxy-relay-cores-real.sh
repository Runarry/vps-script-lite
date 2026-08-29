#!/usr/bin/env bash

# Real binary validation for every public relay profile/core combination.
# Set SING_BOX_BINARY and XRAY_BINARY when they are not on PATH.  This test is
# syntax-checked, but intentionally not run by tests/run.sh.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
TEST_TEMP="$(mktemp -d)"
readonly TEST_TEMP
TEST_SYSTEM_ROOT="${TEST_TEMP}/root"
trap 'rm -rf -- "$TEST_TEMP"' EXIT
mkdir -p -- "$TEST_SYSTEM_ROOT"

for tool in bash jq openssl sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'FAIL: missing %s\n' "$tool" >&2; exit 3; }
done

SING_BOX_BINARY="${SING_BOX_BINARY:-$(command -v sing-box 2>/dev/null || true)}"
XRAY_BINARY="${XRAY_BINARY:-$(command -v xray 2>/dev/null || true)}"
[[ -n "$SING_BOX_BINARY" || -n "$XRAY_BINARY" ]] || {
    printf 'FAIL: provide SING_BOX_BINARY and/or XRAY_BINARY\n' >&2
    exit 3
}

export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_ENV_INIT=systemd
export VPSCTL_ENV_PACKAGE_MANAGER=apt-get
export VPSCTL_ENV_ARCH=x86_64
export VPSCTL_NON_INTERACTIVE=1
export VPSCTL_NO_COLOR=1

# shellcheck source=../../lib/command.sh
source "${TEST_ROOT}/lib/command.sh"
vps_cmd_init "relay real core test" "$TEST_ROOT"
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

count=0
while IFS=$'\t' read -r profile _label; do
    [[ -n "$profile" ]] || continue
    while IFS= read -r core; do
        [[ -n "$core" ]] || continue
        binary=""
        case "$core" in
            sing-box) binary="$SING_BOX_BINARY" ;;
            xray) binary="$XRAY_BINARY" ;;
        esac
        [[ -n "$binary" ]] || continue

        count=$((count + 1))
        printf -v node_id 'node-%016x' "$count"
        printf -v exit_id 'exit-%016x' "$count"
        printf -v bind_id 'bind-%016x' "$count"
        port=$((46000 + count))
        obfs=none
        [[ "$profile" != hysteria2 ]] || obfs=salamander
        node="$(proxy_prepare_node_json "$core" "$profile" "$node_id" "real-${profile}-${core}" \
            127.0.0.1 "$port" 198.51.100.10 www.amd.com /relay-real relay-real self-signed '' '' \
            "$obfs" 100 200 bbr)" || { printf 'FAIL: node fixture %s/%s\n' "$profile" "$core" >&2; exit 1; }
        if [[ "$(jq -r '.tls.enabled' <<<"$node")" == true && "$(jq -r '.tls.mode' <<<"$node")" != reality ]]; then
            cert_logical="$(jq -r '.tls.certificate_path' <<<"$node")"
            key_logical="$(jq -r '.tls.key_path' <<<"$node")"
            node="$(jq --arg cert "${TEST_SYSTEM_ROOT}${cert_logical}" --arg key "${TEST_SYSTEM_ROOT}${key_logical}" \
                '.tls.certificate_path=$cert | .tls.key_path=$key' <<<"$node")"
        fi

        case "$core" in
            sing-box) uri="$(proxy_sb_render_uri "$node")" ;;
            xray) uri="$(proxy_xray_render_uri "$node")" ;;
        esac
        descriptor="$(proxy_relay_uri_parse "$uri" "$profile")" || { printf 'FAIL: URI parse %s/%s\n' "$profile" "$core" >&2; exit 1; }
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        manifest="${TEST_TEMP}/nodes-${count}.json"
        relay="${TEST_TEMP}/relay-${count}.json"
        config="${TEST_TEMP}/config-${count}.json"
        jq -n --argjson node "$node" '{schema_version:1,nodes:[$node]}' >"$manifest"
        jq -n --arg exit_id "$exit_id" --arg bind_id "$bind_id" --arg node_id "$node_id" \
            --arg name "real-exit-${count}" --arg core "$core" --arg profile "$profile" --arg uri "$uri" \
            --arg now "$now" --argjson descriptor "$descriptor" '
            {schema_version:1,
             exits:[{id:$exit_id,name:$name,type:"protocol",core:$core,profile:$profile,uri:$uri,
                     descriptor:$descriptor,endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint,
                     created_at:$now,updated_at:$now}],
             bindings:[{id:$bind_id,node_id:$node_id,exit_id:$exit_id,created_at:$now,updated_at:$now}],
             forwards:[]}' >"$relay"
        proxy_render_config "$core" "$manifest" "$relay" >"$config" || {
            printf 'FAIL: config render %s/%s\n' "$profile" "$core" >&2
            exit 1
        }
        validation_output=""
        case "$core" in
            sing-box) validation_output="$("${TEST_SYSTEM_ROOT}/usr/local/bin/sing-box" check -c "$config" 2>&1)" ;;
            xray) validation_output="$("${TEST_SYSTEM_ROOT}/usr/local/bin/xray" run -test -c "$config" 2>&1)" ;;
        esac || {
            printf 'FAIL: real core rejected %s/%s: %s\n' "$profile" "$core" "$validation_output" >&2
            exit 1
        }
    done < <(proxy_profile_cores "$profile")
done < <(proxy_all_profiles)

printf 'PASS: %s real relay profile/core configurations\n' "$count"
