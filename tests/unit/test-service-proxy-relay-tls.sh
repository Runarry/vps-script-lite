#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TEMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_json() { jq -e "$2" <<<"$1" >/dev/null || fail "$3"; }
expect_failure() {
    local status=0
    "$@" >"$TEST_TEMP/rejected.stdout" 2>"$TEST_TEMP/rejected.stderr" || status=$?
    ((status != 0)) || fail "expected rejection: $1"
}

# Only the relay modules are exercised. System transactions below are replaced
# with fixture writes so CRUD assertions can check the candidate and write gate.
source "$TEST_ROOT/commands/service/proxy/relay-uri.sh"
source "$TEST_ROOT/commands/service/proxy/relay.sh"
PROXY_MANIFEST="$TEST_TEMP/nodes.json"
PROXY_STATE_DIR="$TEST_TEMP"
PROXY_RELAY_FILE="$TEST_TEMP/relay.json"
PROXY_ETC_LOGICAL=/etc/vpsctl/proxy
vps_cmd_error() { printf '%s\n' "$*" >&2; }
vps_cmd_success() { :; }
vps_cmd_system_path() { printf '%s%s' "$TEST_TEMP/root" "$1"; }
proxy_manifest_validate_file() { jq -e '.nodes | type == "array"' "$1" >/dev/null; }
proxy_is_interactive() { return 1; }
proxy_stop_after_dependency_plan() { return 1; }
proxy_valid_name() { [[ -n "$1" ]]; }
proxy_core_valid() { [[ "$1" == sing-box || "$1" == xray ]]; }
proxy_core_label() { printf '%s' "$1"; }
proxy_require_state_access() { :; }
proxy_ensure_tools() { :; }
proxy_core_registered() { return 1; }
proxy_relay_prepare_state() { proxy_relay_validate_file "$PROXY_RELAY_FILE"; }
proxy_mktemp_json() { mktemp "$1/.$2.XXXXXX"; }
vps_cmd_lock() { :; }
vps_cmd_unlock() { :; }
proxy_recover_transaction() { :; }
proxy_ufw_relay_transaction() { "$@"; }
_proxy_relay_commit_candidate() {
    proxy_relay_validate_file "$1" || return $?
    printf '%s' "${3-}" >"$TEST_TEMP/commit-core"
    cp -- "$1" "$PROXY_RELAY_FILE"
}

make_exit() {
    local uri="$1" core="${2:-sing-box}" descriptor
    descriptor="$(proxy_relay_uri_parse "$uri")"
    jq -cn --arg uri "$uri" --arg core "$core" --argjson d "$descriptor" '
        {id:"exit-0000000000000001",name:"fixture",type:"protocol",core:$core,
         profile:$d.profile,uri:$uri,descriptor:$d,endpoint:$d.endpoint,
         network_hint:$d.network_hint,created_at:"fixture",updated_at:"fixture"}'
}
write_state() {
    jq -n --argjson item "$1" '{schema_version:1,exits:[$item],bindings:[],forwards:[]}' >"$PROXY_RELAY_FILE"
}

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj /CN=relay.example -keyout "$TEST_TEMP/key-a.pem" -out "$TEST_TEMP/cert-a.pem" >/dev/null 2>&1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj /CN=other.example -keyout "$TEST_TEMP/key-b.pem" -out "$TEST_TEMP/cert-b.pem" >/dev/null 2>&1
cat "$TEST_TEMP/cert-a.pem" "$TEST_TEMP/cert-b.pem" >"$TEST_TEMP/chain.pem"
cert_pin="$(openssl x509 -in "$TEST_TEMP/cert-a.pem" -outform DER | sha256sum)"
cert_pin="${cert_pin%% *}"
spki="$(openssl pkey -in "$TEST_TEMP/key-a.pem" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 -binary | base64 | tr -d '\n')"
wrong_spki="$(openssl pkey -in "$TEST_TEMP/key-b.pem" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 -binary | base64 | tr -d '\n')"
uri="hysteria2://secret@relay.example:443?sni=relay.example&insecure=1&pinSHA256=$cert_pin"
empty_uri='hysteria2://secret@relay.example:443?sni=relay.example&insecure=1'
legacy="$(make_exit "$uri")"
legacy="$(jq '.descriptor={schema_version:0,compatible_cores:[],tls:{insecure:true}}' <<<"$legacy")"
printf '{"nodes":[]}\n' >"$PROXY_MANIFEST"
write_state "$legacy"
cp "$PROXY_RELAY_FILE" "$TEST_TEMP/original.json"

proxy_relay_validate_file "$PROXY_RELAY_FILE" || fail 'unresolved legacy pin is manageable'
proxy_relay_normalize_file "$PROXY_RELAY_FILE" "$TEST_TEMP/normalized.json"
cmp -s "$PROXY_RELAY_FILE" "$TEST_TEMP/original.json" || fail 'normalization modified source'
normalized="$(jq -c '.exits[0]' "$TEST_TEMP/normalized.json")"
assert_json "$normalized" '.descriptor.schema_version == 1 and .descriptor.tls.certificate_sha256 != "" and .client_options == null' 'legacy descriptor rebuild and unresolved pin retention'
expect_failure proxy_relay_normalize_file "$PROXY_RELAY_FILE" "$PROXY_RELAY_FILE"
expect_failure proxy_relay_render_outbound sing-box "$normalized" 1.14.0
proxy_relay_exit_list --json >"$TEST_TEMP/list.json"
proxy_relay_exit_show --id exit-0000000000000001 >"$TEST_TEMP/show.txt"
cmp -s "$PROXY_RELAY_FILE" "$TEST_TEMP/original.json" || fail 'read commands modified legacy state'
tampered="$(jq '.endpoint.port=444' <<<"$legacy")"
write_state "$tampered"
expect_failure proxy_relay_validate_file "$PROXY_RELAY_FILE"
write_state "$legacy"

# An unrelated readable certificate is never enough for automatic migration.
jq -n --arg cert "$TEST_TEMP/cert-a.pem" '{nodes:[{tls:{certificate_path:$cert}}]}' >"$PROXY_MANIFEST"
assert_json "$(proxy_relay_normalize_exit "$legacy")" '.client_options == null' 'unmanaged certificate must not be scanned'
managed='/etc/vpsctl/proxy/sing-box/certs/node-0000000000000001/cert.pem'
mkdir -p "$(dirname "$(vps_cmd_system_path "$managed")")"
cp "$TEST_TEMP/chain.pem" "$(vps_cmd_system_path "$managed")"
jq -n --arg cert "$managed" '{nodes:[{tls:{certificate_path:$cert}}]}' >"$PROXY_MANIFEST"
normalized="$(proxy_relay_normalize_exit "$legacy")"
assert_json "$normalized" ".client_options.tls_spki_sha256 == \"$spki\" and .client_options.tls_cert_sha256 == \"$cert_pin\"" 'resolve matching leaf certificate and public key from current manifest'
proxy_relay_normalize_file "$PROXY_RELAY_FILE" "$TEST_TEMP/normalized.json" "$PROXY_MANIFEST"
cmp -s "$PROXY_RELAY_FILE" "$TEST_TEMP/original.json" || fail 'automatic migration modified source'

explicit="$(proxy_relay_apply_client_options "$legacy" '' "$wrong_spki" off)"
assert_json "$(proxy_relay_normalize_exit "$explicit")" ".client_options.tls_spki_sha256 == \"$wrong_spki\" and .client_options.chrome_parrot == false and (.client_options | has(\"tls_cert_sha256\") | not)" 'preserve canonical explicit trust and false Chrome setting'
rendered="$(proxy_relay_render_outbound sing-box "$explicit" 1.14.0-alpha.1)"
assert_json "$rendered" ".outbounds[0].tls.certificate_public_key_sha256 == [\"$wrong_spki\"] and .outbounds[0].tls.insecure == false and .outbounds[0].disable_chrome_parrot == true" 'explicit pin cannot be bypassed by URI insecure and Chrome off is rendered'
expect_failure proxy_relay_render_outbound sing-box "$explicit" 1.13.9
expect_failure proxy_relay_render_outbound sing-box "$normalized" 1.12.9
rendered="$(proxy_relay_render_outbound sing-box "$normalized" 1.13.0)"
assert_json "$rendered" '(.outbounds[0] | has("disable_chrome_parrot") | not)' 'omitted Chrome option retains core default'
rendered="$(proxy_relay_render_outbound sing-box "$(proxy_relay_apply_client_options "$normalized" '' '' on)" 1.14.0)"
assert_json "$rendered" '.outbounds[0].disable_chrome_parrot == false' 'Chrome on is rendered'
rendered="$(proxy_relay_render_outbound sing-box "$(make_exit "$empty_uri")" 1.12.0)"
assert_json "$rendered" '.outbounds[0].tls.insecure == true and (.outbounds[0].tls | has("certificate_public_key_sha256") | not)' 'unpinned URI keeps previous insecure behavior'
expect_failure proxy_relay_apply_client_options "$legacy" "$TEST_TEMP/cert-b.pem" '' ''
expect_failure proxy_relay_apply_client_options "$legacy" "$TEST_TEMP/cert-a.pem" "$spki" ''
chain_exit="$(proxy_relay_apply_client_options "$legacy" "$TEST_TEMP/chain.pem" '' '')"
assert_json "$chain_exit" ".client_options.tls_cert_sha256 == \"$cert_pin\"" 'PEM chain uses leaf certificate'
for invalid in "$cert_pin" "${spki%=}" 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB=' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==' 'AAAA'; do
    expect_failure proxy_relay_apply_client_options "$legacy" '' "$invalid" ''
done
invalid="$(jq '.client_options={chrome_parrot:"false"}' <<<"$legacy")"
expect_failure proxy_relay_normalize_exit "$invalid"
invalid="$(jq --arg pin "$cert_pin" '.client_options={tls_cert_sha256:$pin}' <<<"$legacy")"
expect_failure proxy_relay_normalize_exit "$invalid"
anytls="$(make_exit 'anytls://secret@relay.example:443?security=tls&sni=relay.example')"
expect_failure proxy_relay_apply_client_options "$anytls" '' '' on
reality="$(make_exit 'vless://11111111-1111-4111-8111-111111111111@relay.example:443?security=reality&type=tcp&flow=xtls-rprx-vision&sni=relay.example&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef')"
expect_failure proxy_relay_apply_client_options "$reality" "$TEST_TEMP/cert-a.pem" '' ''
plain="$(make_exit 'vless://11111111-1111-4111-8111-111111111111@relay.example:443?security=none&type=tcp')"
expect_failure proxy_relay_apply_client_options "$plain" '' "$spki" ''
xray="$(make_exit "vless://11111111-1111-4111-8111-111111111111@relay.example:443?security=tls&type=grpc&serviceName=relay&sni=relay.example&pcs=$cert_pin&insecure=1" xray)"
expect_failure proxy_relay_apply_client_options "$xray" '' "$spki" ''
rendered="$(proxy_relay_render_outbound xray "$xray")"
assert_json "$rendered" ".outbounds[0].streamSettings.tlsSettings.pinnedPeerCertSha256 == \"$cert_pin\"" 'Xray keeps the whole certificate hash'
xray="$(proxy_relay_apply_client_options "$(make_exit 'vless://11111111-1111-4111-8111-111111111111@relay.example:443?security=tls&type=grpc&serviceName=relay&sni=relay.example' xray)" "$TEST_TEMP/cert-a.pem" '' '')"
rendered="$(proxy_relay_render_outbound xray "$xray")"
assert_json "$rendered" ".outbounds[0].streamSettings.tlsSettings.pinnedPeerCertSha256 == \"$cert_pin\"" 'Xray can express a PEM certificate pin without pcs in the URI'

# CLI edits keep explicit options on a rename, discard old TLS trust on a new
# URI, and apply newly supplied TLS parameters only to that new URI.
printf '{"nodes":[]}\n' >"$PROXY_MANIFEST"
write_state "$explicit"
proxy_relay_exit_edit --id exit-0000000000000001 --name renamed
assert_json "$(cat "$PROXY_RELAY_FILE")" ".exits[0].client_options.tls_spki_sha256 == \"$wrong_spki\" and .exits[0].client_options.chrome_parrot == false" 'rename preserves canonical client options'
proxy_relay_exit_edit --id exit-0000000000000001 --uri "$empty_uri"
assert_json "$(cat "$PROXY_RELAY_FILE")" '(.exits[0].client_options | has("tls_spki_sha256") | not) and (.exits[0].client_options | has("tls_cert_sha256") | not)' 'new URI clears old TLS trust'
proxy_relay_exit_edit --id exit-0000000000000001 --uri "$uri" --tls-spki-sha256 "$spki" --chrome-parrot on
assert_json "$(cat "$PROXY_RELAY_FILE")" ".exits[0].client_options.tls_spki_sha256 == \"$spki\" and .exits[0].client_options.chrome_parrot == true" 'new explicit options apply to new URI'
cp "$PROXY_RELAY_FILE" "$TEST_TEMP/before-rejection.json"
expect_failure proxy_relay_exit_edit --id exit-0000000000000001 --tls-cert-file "$TEST_TEMP/cert-b.pem"
cmp -s "$PROXY_RELAY_FILE" "$TEST_TEMP/before-rejection.json" || fail 'bad certificate changed saved state'
expect_failure proxy_relay_exit_add --name rejected --uri "$uri" --tls-spki-sha256 "$spki" --tls-cert-file "$TEST_TEMP/cert-a.pem"
cmp -s "$PROXY_RELAY_FILE" "$TEST_TEMP/before-rejection.json" || fail 'mutually exclusive TLS inputs changed saved state'
new_xray_status=0
proxy_relay_exit_add --name unsafe-xray --core xray \
    --uri 'vless://11111111-1111-4111-8111-111111111111@relay.example:443?security=tls&type=grpc&serviceName=relay&sni=relay.example&insecure=1' \
    >"$TEST_TEMP/rejected.stdout" 2>"$TEST_TEMP/rejected.stderr" || new_xray_status=$?
[[ "$new_xray_status" == 10 ]] || fail 'new unpinned insecure Xray exit must fail with status 10 without an installed core'
cmp -s "$PROXY_RELAY_FILE" "$TEST_TEMP/before-rejection.json" || fail 'unpinned insecure Xray exit changed saved state'
proxy_relay_exit_add --name external-unresolved --core sing-box --uri "$uri"
assert_json "$(cat "$PROXY_RELAY_FILE")" '.exits | any(.name == "external-unresolved" and .client_options == null)' 'unresolved external pin can be saved before binding'

# A legacy exit used only by nftables remains editable and deletable without an
# outbound render. A rename must not demand TLS material from a legacy binding.
write_state "$legacy"
state="$(jq '.forwards=[{id:"forward-0000000000000001",name:"forward",exit_id:"exit-0000000000000001",
    listen_port_start:24443,listen_port_end:24443,network:"udp",family:"ipv4",
    publish_address:"forward.example",created_at:"fixture",updated_at:"fixture"}]' "$PROXY_RELAY_FILE")"
printf '%s\n' "$state" >"$PROXY_RELAY_FILE"
proxy_relay_exit_edit --id exit-0000000000000001 --name legacy-renamed
[[ ! -s "$TEST_TEMP/commit-core" ]] || fail 'forward-only legacy rename requested a core render'
proxy_relay_exit_delete --id exit-0000000000000001 --cascade --confirm-cascade
assert_json "$(cat "$PROXY_RELAY_FILE")" '.exits == [] and .forwards == []' 'unresolved forward-only legacy exit can be deleted'
write_state "$legacy"
state="$(jq '.bindings=[{id:"bind-0000000000000001",node_id:"node-0000000000000001",
    exit_id:"exit-0000000000000001",created_at:"fixture",updated_at:"fixture"}]' "$PROXY_RELAY_FILE")"
printf '%s\n' "$state" >"$PROXY_RELAY_FILE"
printf '{"nodes":[{"id":"node-0000000000000001","core":"sing-box"}]}\n' >"$PROXY_MANIFEST"
proxy_relay_exit_edit --id exit-0000000000000001 --name bound-legacy-renamed
[[ ! -s "$TEST_TEMP/commit-core" ]] || fail 'bound legacy rename requested a core render'
write_state "$legacy"
printf '{"nodes":[]}\n' >"$PROXY_MANIFEST"

proxy_relay_select_exit() { printf '%s' exit-0000000000000001; }
proxy_prompt_select() {
    case "$1" in
        '编辑字段')
            printf '%s\n' "$@" >"$TEST_TEMP/menu-options"
            printf '%s' "$MENU_FIELD"
            ;;
        'Chrome QUIC') printf 'off' ;;
        *) return 2 ;;
    esac
}
proxy_prompt_value() { printf '%s' "$MENU_VALUE"; }
MENU_FIELD=tls-cert-file MENU_VALUE="$TEST_TEMP/cert-a.pem" proxy_relay_menu_exit_edit
assert_json "$(cat "$PROXY_RELAY_FILE")" ".exits[0].client_options.tls_spki_sha256 == \"$spki\"" 'numbered menu certificate input reaches edit'
MENU_FIELD=tls-spki-sha256 MENU_VALUE="$wrong_spki" proxy_relay_menu_exit_edit
assert_json "$(cat "$PROXY_RELAY_FILE")" ".exits[0].client_options.tls_spki_sha256 == \"$wrong_spki\"" 'numbered menu SPKI input reaches edit'
MENU_FIELD=chrome-parrot MENU_VALUE='' proxy_relay_menu_exit_edit
assert_json "$(cat "$PROXY_RELAY_FILE")" '.exits[0].client_options.chrome_parrot == false' 'numbered menu Chrome input reaches edit'
printf 'PASS: relay TLS pins, migration, client options, CLI and menu\n'
