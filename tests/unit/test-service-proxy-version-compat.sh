#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TEMP"' EXIT
export VPSCTL_TESTING=1 VPSCTL_NON_INTERACTIVE=1 VPSCTL_DRY_RUN=0
export VPSCTL_SYSTEM_ROOT="${TEST_TEMP}/root"
export VPSCTL_ENV_INIT=systemd VPSCTL_ENV_ARCH=x86_64
export TEST_PROXY_ROOT="$VPSCTL_SYSTEM_ROOT"
export TMPDIR="${TEST_TEMP}/tmp"
mkdir -p "$TMPDIR" "$VPSCTL_SYSTEM_ROOT"

# shellcheck source=lib/command.sh
source "${TEST_ROOT}/lib/command.sh"
vps_cmd_init 'proxy version compatibility tests' "$TEST_ROOT"
# shellcheck source=commands/service/proxy/common.sh
source "${TEST_ROOT}/commands/service/proxy/common.sh"
# shellcheck source=commands/service/proxy/protocols-xray.sh
source "${TEST_ROOT}/commands/service/proxy/protocols-xray.sh"
# shellcheck source=commands/service/proxy/core.sh
source "${TEST_ROOT}/commands/service/proxy/core.sh"
proxy_common_init
PROXY_RELAY_LOGICAL="${PROXY_STATE_LOGICAL}/relay.json"
PROXY_RELAY_FILE="${PROXY_STATE_DIR}/relay.json"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_json() { jq -e "$2" "$1" >/dev/null || fail "$3"; }

# Keep filesystem, rendering, candidate checks, journal and pending operations
# real; replace network/package/service boundaries with deterministic fixtures.
vps_cmd_require_root() { return 0; }
vps_cmd_lock() { return 0; }
vps_cmd_unlock() { return 0; }
proxy_ensure_mutation_tools() { return 0; }
proxy_service_is_active() { [[ -f "${TEST_PROXY_ROOT}/active" ]]; }
proxy_service_is_enabled() { return 1; }
proxy_ufw_restore_pending() { _proxy_restore_pending "$@"; }
proxy_service_action() {
    printf '%s\n' "$2" >>"${TEST_PROXY_ROOT}/service.log"
    case "$2" in
        start | restart)
            if [[ -e "${TEST_PROXY_ROOT}/fail-start-once" ]]; then
                rm -f -- "${TEST_PROXY_ROOT}/fail-start-once" "${TEST_PROXY_ROOT}/active"
                return 20
            fi
            touch "${TEST_PROXY_ROOT}/active"
            ;;
        stop) rm -f -- "${TEST_PROXY_ROOT}/active" ;;
        *) return 0 ;;
    esac
}
proxy_relay_validate_file() { jq -e '.schema_version == 1' "$1" >/dev/null; }
proxy_relay_normalize_file() {
    [[ "${3:-}" == "$PROXY_MANIFEST" ]] || return 10
    jq 'del(.legacy_cache)' "$1" >"$2"
}
proxy_relay_render_outbound() {
    [[ "${3:-}" == "${PROXY_RENDER_CORE_VERSION:-}" ]] || return 10
    jq -cn --arg version "${3:-}" \
        '{outbounds:[{tag:"relay-fixture",protocol:"shadowsocks",version_fixture:$version}],target_tag:"relay-fixture"}'
}

write_binary() {
    local output="$1" version="$2"
    printf '#!/usr/bin/env bash\nversion=%s\n' "$version" >"$output"
    cat >>"$output" <<'EOF'
set -eu
if [[ "${1:-}" == version ]]; then printf 'Xray %s\n' "$version"; exit 0; fi
[[ "$*" == 'run -test -c '* ]] || exit 2
config="$4"
cp -- "$config" "${TEST_PROXY_ROOT}/checked-config.json"
if [[ -e "${TEST_PROXY_ROOT}/reject-config" ]]; then
    printf 'unknown field finalRules, password test-secret-password, privateKey test-secret-private-key\n' >&2
    exit 10
fi
if [[ "$version" == 26.9.8 ]]; then
    jq -e 'all(.outbounds[] | select(.tag | startswith("direct-node-"));
        (.streamSettings.sockopt.domainStrategy | type) == "string" and (.settings | has("domainStrategy") | not))' "$config" >/dev/null
else
    jq -e 'all(.outbounds[] | select(.tag | startswith("direct-node-"));
        (.settings.domainStrategy | type) == "string" and (has("streamSettings") | not))' "$config" >/dev/null
fi
EOF
    chmod 0755 -- "$output"
}

_proxy_core_fetch_release() {
    local core="$1" version="${3:-v26.9.8}" output="$4" info="$5" sha
    [[ "$core" == xray ]] || return 2
    version="${version#v}"
    write_binary "$output" "$version"
    sha="$(_proxy_core_sha256 "$output")"
    jq -n --arg version "$version" --arg sha "$sha" \
        '{version:$version,release_tag:("v"+$version),sha256:$sha}' >"$info"
}

reset_fixture() {
    [[ "$VPSCTL_SYSTEM_ROOT" == "$TEST_TEMP/root" ]] || fail 'unsafe fixture root'
    rm -rf -- "$VPSCTL_SYSTEM_ROOT"
    mkdir -p "$VPSCTL_SYSTEM_ROOT/usr/local/bin"
    proxy_ensure_layout
    mkdir -p "$(dirname -- "$(proxy_core_config_path xray)")"
    jq -n '
        {schema_version:1,nodes:([
            ["auto","prefer_ipv4","prefer_ipv6","ipv4_only","ipv6_only"] | to_entries[] |
            {id:("node-000000000000000" + (.key | tostring)),core:"xray",
             name:("policy-" + (.key | tostring)),profile:"shadowsocks-aes-256-gcm",
             listen:"127.0.0.1",port:(31000+.key),address:"proxy.example",ip_strategy:.value,
             credentials:{password:"test-secret-password"},tls:{},transport:{},
             options:{method:"aes-256-gcm",padding:false}}
        ] + [{id:"node-0000000000000005",core:"xray",name:"guard",profile:"vless-reality-vision",
             listen:"127.0.0.1",port:31005,address:"proxy.example",ip_strategy:"auto",
             credentials:{uuid:"11111111-1111-4111-8111-111111111111",private_key:"test-secret-private-key",
                          public_key:"fixture-public-key",short_id:"0123456789abcdef"},
             tls:{enabled:true,mode:"reality",server_name:"target.example",
                  reality_guard:{enabled:true,listen_port:21000}},
             transport:{type:"tcp",flow:"xtls-rprx-vision"},options:{}}])}
    ' >"$PROXY_MANIFEST"
}

register_fixture() {
    local version="$1" config_version="${2:-$1}" binary
    binary="$(proxy_core_binary_path xray)"
    write_binary "$binary" "$version"
    _proxy_core_write_meta xray /usr/local/bin/xray true "$version" "v$version" "$(_proxy_core_sha256 "$binary")" fixture-date
    proxy_render_config xray "$PROXY_MANIFEST" "$PROXY_RELAY_FILE" "$config_version" >"$(proxy_core_config_path xray)"
}

generation_hash() {
    local path
    for path in "$(proxy_core_binary_path xray)" "$(proxy_core_config_path xray)" \
        "$(proxy_core_meta_path xray)" "$PROXY_MANIFEST" "$PROXY_RELAY_FILE" "$(proxy_core_pending_path xray)"; do
        if [[ -f "$path" ]]; then sha256sum "$path"; else printf 'missing %s\n' "$path"; fi
    done
}

run_update() {
    RUN_STATUS=0
    proxy_core_update xray --version "${1:-v26.9.8}" >"${TEST_TEMP}/output" 2>&1 || RUN_STATUS=$?
    RUN_OUTPUT="$(<"${TEST_TEMP}/output")"
}

test_version_order() {
    local version minimum expected status
    while IFS=' ' read -r version minimum expected; do
        status=0
        proxy_core_version_at_least "$version" "$minimum" || status=1
        assert_equal "$expected" "$status" "version $version >= $minimum"
    done <<'EOF'
26.4.14 26.4.15 1
v26.4.15 26.4.15 0
26.5.3-rc.1 26.5.3 1
26.5.3+build.7 26.5.3 0
26.9.8-rc.1 26.9.8 1
26.10.1 26.9.8 0
1.14.0-alpha.10 1.14.0-alpha.2 0
1.14.0-beta 1.14.0-alpha.10 0
1.14.0-2 1.14.0-alpha 1
1.14.0-alpha 1.14.0-alpha.1 1
1.14.0 1.14.0-rc.10 0
fixture 26.9.8 1
EOF
}

test_render_versions() {
    local version rendered="${TEST_TEMP}/render.json" expected_rules expected_sockopt
    reset_fixture
    for version in legacy 26.4.14 26.4.15-rc.1 26.4.15 26.5.3-rc.1 26.5.3 26.9.8-rc.1 26.9.8; do
        proxy_render_config xray "$PROXY_MANIFEST" "$PROXY_RELAY_FILE" "$version" >"$rendered"
        case "$version" in
            26.4.15 | 26.5.3-rc.1) expected_rules=ipsBlocked ;;
            26.5.3 | 26.9.8-rc.1 | 26.9.8) expected_rules=finalRules ;;
            *) expected_rules=legacy ;;
        esac
        expected_sockopt=false
        [[ "$version" != 26.9.8 ]] || expected_sockopt=true
        jq -e --arg rules "$expected_rules" --argjson sockopt "$expected_sockopt" '
            all(.outbounds[] | select(.protocol == "freedom");
                if $rules == "finalRules" then .settings.finalRules == [{action:"allow"}] and (.settings | has("ipsBlocked") | not)
                elif $rules == "ipsBlocked" then .settings.ipsBlocked == [] and (.settings | has("finalRules") | not)
                else (.settings | has("ipsBlocked") or has("finalRules") | not) end) and
            ([.outbounds[] | select(.tag | startswith("direct-node-")) |
                if $sockopt then .streamSettings.sockopt.domainStrategy else .settings.domainStrategy end] ==
             ["UseIPv4v6","UseIPv6v4","ForceIPv4","ForceIPv6"]) and
            all(.outbounds[] | select(.tag | startswith("direct-node-"));
                if $sockopt then (.settings | has("domainStrategy") | not) else (has("streamSettings") | not) end) and
            all(.outbounds[]; .tag != "direct-node-0000000000000000") and
            ([.outbounds[] | select(.tag == "direct")][0] | (.settings | has("domainStrategy") | not) and (has("streamSettings") | not)) and
            .routing.rules[0].outboundTag == "reality-target-node-0000000000000005" and
            .routing.rules[1].outboundTag == "block" and .routing.rules[2].outboundTag == "direct-node-0000000000000001"
        ' "$rendered" >/dev/null || fail "render boundary $version"
    done
    proxy_render_config xray "$PROXY_MANIFEST" >"$rendered"
    assert_json "$rendered" '.outbounds[0] == {protocol:"freedom",tag:"direct"}' 'unregistered legacy rendering'
    register_fixture 26.9.8
    proxy_render_config xray "$PROXY_MANIFEST" >"$rendered"
    assert_json "$rendered" '.outbounds[0].settings.finalRules == [{action:"allow"}]' 'registered version rendering'
    proxy_render_config xray "$PROXY_MANIFEST" "$PROXY_RELAY_FILE" 26.4.15 >"$rendered"
    assert_json "$rendered" '.outbounds[0].settings.ipsBlocked == []' 'candidate version overrides metadata'
    assert_json "$(proxy_core_meta_path xray)" '.version == "26.9.8"' 'candidate version leaves metadata alone'
    [[ -z "${PROXY_RENDER_CORE_VERSION:-}" ]] || fail 'render version escaped local scope'
    printf '{"schema_version":1,"exits":[{"id":"exit-fixture","type":"protocol","core":"xray"}],"bindings":[{"exit_id":"exit-fixture","node_id":"node-0000000000000000"}],"forwards":[]}' >"$PROXY_RELAY_FILE"
    proxy_render_config xray "$PROXY_MANIFEST" "$PROXY_RELAY_FILE" 26.4.15 >"$rendered"
    assert_json "$rendered" 'any(.outbounds[]; .version_fixture == "26.4.15")' 'relay receives candidate version'
}

test_same_binary_migration() {
    local before binary_hash first_pending
    reset_fixture
    register_fixture 26.9.8 26.3.27
    binary_hash="$(_proxy_core_sha256 "$(proxy_core_binary_path xray)")"
    run_update
    assert_equal 0 "$RUN_STATUS" "same-binary migration: $RUN_OUTPUT"
    assert_equal "$binary_hash" "$(_proxy_core_sha256 "$(proxy_core_binary_path xray)")" 'same binary digest'
    assert_json "$(proxy_core_config_path xray)" '.outbounds[0].settings.finalRules == [{action:"allow"}]' 'same-binary config migration'
    assert_json "$(proxy_core_pending_path xray)" '.reason == "core-update" and .config_backup != "" and .binary_backup != ""' 'migration pending rollback'
    [[ ! -e "$PROXY_RELAY_FILE" ]] || fail 'migration created absent relay state'
    [[ ! -e "${TEST_PROXY_ROOT}/service.log" ]] || fail 'update performed a service action'
    first_pending="$(<"$(proxy_core_pending_path xray)")"
    before="$(generation_hash)"
    run_update
    assert_equal 0 "$RUN_STATUS" "same-state no-op: $RUN_OUTPUT"
    assert_equal "$before" "$(generation_hash)" 'no-op preserves all files'
    assert_equal "$first_pending" "$(<"$(proxy_core_pending_path xray)")" 'no-op preserves pending'

    reset_fixture
    register_fixture 26.9.8
    printf '{"schema_version":1,"exits":[],"bindings":[],"forwards":[],"legacy_cache":true}' >"$PROXY_RELAY_FILE"
    run_update
    assert_equal 0 "$RUN_STATUS" "same-binary relay-only migration: $RUN_OUTPUT"
    assert_json "$PROXY_RELAY_FILE" 'has("legacy_cache") | not' 'relay-only migration committed'
    assert_json "$(proxy_core_pending_path xray)" '.relay_touched and .relay_existed and .relay_backup != ""' 'relay-only migration backup'
}

test_rejection_and_midwrite_rollback() (
    local before original_write target
    reset_fixture
    register_fixture 26.5.3
    printf '{"schema_version":1,"exits":[],"bindings":[],"forwards":[],"legacy_cache":true}' >"$PROXY_RELAY_FILE"
    before="$(generation_hash)"
    touch "${TEST_PROXY_ROOT}/reject-config"
    run_update
    assert_equal 10 "$RUN_STATUS" 'candidate rejection status'
    assert_equal "$before" "$(generation_hash)" 'candidate rejection replaces nothing'
    [[ "$RUN_OUTPUT" == *finalRules* && "$RUN_OUTPUT" != *test-secret-password* && "$RUN_OUTPUT" != *test-secret-private-key* ]] || fail "unsafe or missing validation diagnostic: $RUN_OUTPUT"
    [[ ! -e "$PROXY_TRANSACTION" ]] || fail 'candidate rejection wrote transaction'
    rm -f -- "${TEST_PROXY_ROOT}/reject-config"
    original_write="$(declare -f vps_cmd_atomic_write)"
    eval "${original_write/vps_cmd_atomic_write/vps_cmd_atomic_write_original}"
    vps_cmd_atomic_write() {
        if [[ "$1" == "$FAIL_LOGICAL" && -f "${TEST_PROXY_ROOT}/fail-write-once" ]]; then
            rm -f -- "${TEST_PROXY_ROOT}/fail-write-once"
            return 20
        fi
        vps_cmd_atomic_write_original "$@"
    }
    for target in /usr/local/bin/xray "$(proxy_core_config_logical xray)" "$PROXY_RELAY_LOGICAL" \
        "$(proxy_core_meta_logical xray)" "$(proxy_core_pending_logical xray)"; do
        FAIL_LOGICAL="$target"
        touch "${TEST_PROXY_ROOT}/fail-write-once"
        run_update
        assert_equal 20 "$RUN_STATUS" "write failure status at $target: $RUN_OUTPUT"
        assert_equal "$before" "$(generation_hash)" "same-generation rollback at $target"
        [[ ! -e "$PROXY_TRANSACTION" ]] || fail "journal survived successful rollback at $target"
    done
)

test_repeated_update_and_start_rollback() {
    local before first_pending status=0
    reset_fixture
    register_fixture 26.5.3
    printf '{"schema_version":1,"exits":[],"bindings":[],"forwards":[],"legacy_cache":true}' >"$PROXY_RELAY_FILE"
    before="$(generation_hash)"
    run_update
    assert_equal 0 "$RUN_STATUS" "first update: $RUN_OUTPUT"
    assert_json "$PROXY_RELAY_FILE" 'has("legacy_cache") | not' 'relay state migration committed'
    first_pending="$(<"$(proxy_core_pending_path xray)")"
    run_update v26.5.3
    assert_equal 0 "$RUN_STATUS" "second update: $RUN_OUTPUT"
    assert_equal "$first_pending" "$(<"$(proxy_core_pending_path xray)")" 'repeated update preserves initial rollback backups'
    touch "${TEST_PROXY_ROOT}/fail-start-once"
    proxy_core_start xray >"${TEST_TEMP}/start-output" 2>&1 || status=$?
    assert_equal 20 "$status" "start failure recovers old generation: $(<"${TEST_TEMP}/start-output")"
    assert_equal "$before" "$(generation_hash)" 'start failure restores binary/config/meta/relay generation'
    [[ -f "${TEST_PROXY_ROOT}/active" ]] || fail 'previous generation not started'
}

test_interrupted_update_with_pending() (
    local before
    reset_fixture
    register_fixture 26.5.3
    run_update
    assert_equal 0 "$RUN_STATUS" "prepare existing pending: $RUN_OUTPUT"
    before="$(generation_hash)"
    # Simulate process termination after binary/config writes, bypassing normal
    # error handling. Recovery must retain the pending from before this update.
    _proxy_core_write_meta() { exit 87; }
    run_update v26.5.3
    assert_equal 87 "$RUN_STATUS" 'interrupted update status'
    [[ -f "$PROXY_TRANSACTION" ]] || fail 'interrupted update lost journal'
    proxy_recover_transaction >"${TEST_TEMP}/recover-output" 2>&1 || fail "recover interrupted update: $(<"${TEST_TEMP}/recover-output")"
    assert_equal "$before" "$(generation_hash)" 'interrupted update restores immediate generation and earlier pending'
    [[ ! -e "$PROXY_TRANSACTION" ]] || fail 'recovered update retained journal'
)

printf 'TEST: version ordering and Xray Freedom thresholds\n'
test_version_order
test_render_versions
printf 'TEST: same-binary migration and all-content no-op\n'
test_same_binary_migration
printf 'TEST: candidate rejection and every write boundary rollback\n'
test_rejection_and_midwrite_rollback
printf 'TEST: repeated updates preserve initial start rollback\n'
test_repeated_update_and_start_rollback
printf 'TEST: interrupted update retains prior pending recovery point\n'
test_interrupted_update_with_pending
printf 'PASS: proxy version compatibility and update transactions\n'
