#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TEMP"' EXIT
export VPSCTL_TESTING=1 VPSCTL_NON_INTERACTIVE=1 VPSCTL_DRY_RUN=0
export VPSCTL_SYSTEM_ROOT="${TEST_TEMP}/root"
export VPSCTL_ENV_INIT=systemd VPSCTL_ENV_ARCH=x86_64
mkdir -p "$VPSCTL_SYSTEM_ROOT"

# Exercise real CLI parsing, state validation, URI parsing and both renderers.
# Only certificate creation, services and commit boundaries are replaced.
# shellcheck source=lib/command.sh
source "${TEST_ROOT}/lib/command.sh"
vps_cmd_init 'proxy node enhancements tests' "$TEST_ROOT"
# shellcheck source=commands/service/proxy/common.sh
source "${TEST_ROOT}/commands/service/proxy/common.sh"
# shellcheck source=commands/service/proxy/protocols-sing-box.sh
source "${TEST_ROOT}/commands/service/proxy/protocols-sing-box.sh"
# shellcheck source=commands/service/proxy/protocols-xray.sh
source "${TEST_ROOT}/commands/service/proxy/protocols-xray.sh"
# shellcheck source=commands/service/proxy/relay-uri.sh
source "${TEST_ROOT}/commands/service/proxy/relay-uri.sh"
# shellcheck source=commands/service/proxy/relay.sh
source "${TEST_ROOT}/commands/service/proxy/relay.sh"
# shellcheck source=commands/service/proxy/nodes.sh
source "${TEST_ROOT}/commands/service/proxy/nodes.sh"
proxy_common_init
proxy_relay_init
mkdir -p "$PROXY_STATE_DIR"
proxy_manifest_default >"$PROXY_MANIFEST"
TEST_SB_VERSION=1.14.0
TEST_XRAY_VERSION=26.3.27
TEST_WRITES="${TEST_TEMP}/writes"
: >"$TEST_WRITES"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_json() { jq -e "$2" <<<"$1" >/dev/null || fail "$3"; }
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
run_ok() { "$@" >"${TEST_TEMP}/output" 2>&1 || fail "command failed: $*; $(<"${TEST_TEMP}/output")"; }
reject_without_writes() {
    local before after status=0
    before="$(sha256sum "$PROXY_MANIFEST" "$TEST_WRITES"; if [[ -f "$PROXY_RELAY_FILE" ]]; then sha256sum "$PROXY_RELAY_FILE"; fi)"
    "$@" >"${TEST_TEMP}/output" 2>&1 || status=$?
    ((status != 0)) || fail "command unexpectedly succeeded: $*"
    after="$(sha256sum "$PROXY_MANIFEST" "$TEST_WRITES"; if [[ -f "$PROXY_RELAY_FILE" ]]; then sha256sum "$PROXY_RELAY_FILE"; fi)"
    assert_equal "$before" "$after" "rejected operation changed state or staged a certificate/configuration: $*"
}
node_named() { jq -ce --arg name "$1" '.nodes[] | select(.name == $name)' "$PROXY_MANIFEST"; }
replace_node() {
    jq --arg id "$1" --argjson node "$2" '(.nodes[] | select(.id == $id))=$node' "$PROXY_MANIFEST" >"${TEST_TEMP}/replace.json"
    mv -- "${TEST_TEMP}/replace.json" "$PROXY_MANIFEST"
}

vps_cmd_require_root() { return 0; }
vps_cmd_lock() { return 0; }
vps_cmd_unlock() { return 0; }
proxy_require_platform() { return 0; }
proxy_ensure_mutation_tools() { return 0; }
proxy_ensure_tools() { return 0; }
proxy_stop_after_dependency_plan() { return 1; }
proxy_prepare_manifest_state() { proxy_manifest_validate_file "$PROXY_MANIFEST"; }
proxy_recover_transaction() { return 0; }
proxy_core_registered() { return 0; }
proxy_core_binary_path() { printf '/bin/false'; }
proxy_core_config_version() {
    case "$1" in sing-box) printf '%s' "$TEST_SB_VERSION" ;; xray) printf '%s' "$TEST_XRAY_VERSION" ;; *) return 2 ;; esac
}
proxy_generate_reality_keys() {
    PROXY_REALITY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    PROXY_REALITY_PUBLIC_KEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
}
ss() { return 0; }
proxy_prepare_certificate() {
    printf 'certificate\n' >>"$TEST_WRITES"
    PROXY_CERTIFICATE_LOGICAL="${PROXY_ETC_LOGICAL}/${1}/certs/${2}/cert.pem"
    PROXY_KEY_LOGICAL="${PROXY_ETC_LOGICAL}/${1}/certs/${2}/key.pem"
    PROXY_CERTIFICATE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    PROXY_CERTIFICATE_INSECURE=true
    PROXY_CERTIFICATE_ID=""
}
proxy_cleanup_orphan_certs() { return 0; }
proxy_mktemp_json() {
    printf 'stage %s\n' "$2" >>"$TEST_WRITES"
    mktemp "${1}/.${2}.XXXXXX.json"
}
proxy_commit_manifest_config() {
    [[ "$VPSCTL_DRY_RUN" != 1 ]] || return 0
    printf 'commit %s\n' "$4" >>"$TEST_WRITES"
    cp -- "$2" "$PROXY_MANIFEST"
    cp -- "$3" "${TEST_TEMP}/config-${1}.json"
}
proxy_node_core_set_prepare_certificate() {
    printf 'switch-certificate\n' >>"$TEST_WRITES"
    PROXY_SWITCH_NODE_JSON="$(jq --arg source "/${2}/certs/" --arg target "/${3}/certs/" '
        .tls.certificate_path |= (split($source) | join($target)) |
        .tls.key_path |= (split($source) | join($target))
    ' <<<"$1")"
    PROXY_SWITCH_CREATED_CERTS='[]'
}
proxy_abort_core_switch_cert_stage() { return 0; }
proxy_commit_core_switch() {
    printf 'switch-commit\n' >>"$TEST_WRITES"
    cp -- "$3" "$PROXY_MANIFEST"
    cp -- "$4" "${TEST_TEMP}/config-${1}.json"
    cp -- "$5" "${TEST_TEMP}/config-${2}.json"
    [[ "$7" != true ]] || cp -- "$6" "$PROXY_RELAY_FILE"
    PROXY_CORE_SWITCH_COMMITTED=1
}

# All three XHTTP profiles have explicit defaults only when newly created.
run_ok proxy_node_add --profile vless-xhttp-tls --core xray --name tls-xhttp --port 30101 --address proxy.example
run_ok proxy_node_add --profile vless-xhttp-reality --core xray --name reality-xhttp --port 30102 --address proxy.example --host front.example
run_ok proxy_node_add --profile trojan-xhttp-reality --core xray --name trojan-xhttp --port 30103 --address proxy.example
tls_node="$(node_named tls-xhttp)"
reality_node="$(node_named reality-xhttp)"
trojan_node="$(node_named trojan-xhttp)"
assert_json "$tls_node" '.transport.mode == "auto"' 'new TLS XHTTP defaults to auto'
assert_json "$reality_node" '.transport.mode == "stream-one" and .transport.host == "front.example" and .tls.server_name == "www.amd.com" and .tls.mode == "reality" and .tls.reality_guard.enabled and (.credentials.uuid | length > 0)' 'new VLESS Reality uses UUID, XHTTP, separate Host and Reality guard'
assert_json "$trojan_node" '.transport.mode == "stream-one"' 'new Trojan Reality XHTTP default'
guard_port="$(jq -r '.tls.reality_guard.listen_port' <<<"$reality_node")"
reject_without_writes proxy_node_add --profile vless-tcp --core xray --port "$guard_port" --address proxy.example
reject_without_writes proxy_node_add --profile vless-xhttp-reality --core xray --port 30110 --address proxy.example --cert-mode imported --cert-file /tmp/cert --key-file /tmp/key
reject_without_writes proxy_node_add --profile vless-tcp --core xray --port 30110 --address proxy.example --xhttp-mode auto
reject_without_writes proxy_node_add --profile vless-xhttp-reality --core xray --port 30110 --address proxy.example --xhttp-mode invalid
reject_without_writes proxy_node_add --profile vless-xhttp-reality --core xray --port 30110 --address proxy.example --host 'invalid host'

reality_id="$(jq -r '.id' <<<"$reality_node")"
credentials="$(jq -Sc '.credentials' <<<"$reality_node")"
run_ok proxy_node_edit --id "$reality_id" --xhttp-mode packet-up --host upload.example
run_ok proxy_node_edit --id "$reality_id" --name reality-renamed
updated="$(proxy_manifest_node "$reality_id")"
assert_json "$updated" '.transport.mode == "packet-up" and .transport.host == "upload.example" and .tls.server_name == "www.amd.com" and .tls.reality_guard.enabled' 'rename retains explicit XHTTP settings and Reality guard'
assert_equal "$credentials" "$(jq -Sc '.credentials' <<<"$updated")" 'XHTTP edits preserve all credentials'
assert_equal "$guard_port" "$(jq -r '.tls.reality_guard.listen_port' <<<"$updated")" 'XHTTP edits preserve guard port'
uri="$(proxy_node_render_uri_json "$updated")"
[[ "$uri" == *'mode=packet-up'* && "$uri" == *'host=upload.example'* ]] || fail 'explicit mode/Host missing from client URI'
for profile in vless-xhttp-tls trojan-xhttp-reality; do
    legacy="$(jq -c --arg profile "$profile" '.nodes[] | select(.profile == $profile) | del(.transport.mode,.transport.host)' "$PROXY_MANIFEST")"
    legacy_id="$(jq -r '.id' <<<"$legacy")"
    replace_node "$legacy_id" "$legacy"
    before_uri="$(proxy_node_render_uri_json "$legacy")"
    run_ok proxy_node_edit --id "$legacy_id" --name "legacy-${profile}"
    updated="$(proxy_manifest_node "$legacy_id")"
    assert_json "$updated" '(.transport | has("mode") or has("host") | not)' 'editing old XHTTP does not materialize new defaults'
    after_uri="$(proxy_node_render_uri_json "$updated")"
    assert_equal "${before_uri%%#*}" "${after_uri%%#*}" 'legacy XHTTP connection URI preserved after rename'
done

# Unsupported options and versions are rejected before credential/cert staging.
TEST_XRAY_VERSION=26.3.26
reject_without_writes proxy_node_add --profile hysteria2 --core xray --port 30200 --address proxy.example
TEST_XRAY_VERSION=26.3.27
reject_without_writes proxy_node_add --profile hysteria2 --core xray --port 30200 --address proxy.example --obfs gecko
reject_without_writes proxy_node_add --profile hysteria2 --core xray --port 30200 --address proxy.example --bbr-profile standard
reject_without_writes proxy_node_add --profile hysteria2 --core sing-box --port 30200 --address proxy.example --bbr-profile invalid
reject_without_writes proxy_node_add --profile vless-tcp --core sing-box --port 30200 --address proxy.example --bbr-profile standard
TEST_SB_VERSION=1.13.12
reject_without_writes proxy_node_add --profile hysteria2 --core sing-box --port 30200 --address proxy.example --obfs gecko
reject_without_writes proxy_node_add --profile hysteria2 --core sing-box --port 30200 --address proxy.example --bbr-profile conservative
TEST_SB_VERSION=1.14.0
run_ok proxy_node_add --profile hysteria2 --core sing-box --name hy-gecko --port 30201 --address proxy.example --obfs gecko --bbr-profile aggressive --up-mbps 123 --down-mbps 456 --ip-strategy ipv6_only
hy_node="$(node_named hy-gecko)"
hy_id="$(jq -r '.id' <<<"$hy_node")"
hy_password="$(jq -r '.options.obfs_password' <<<"$hy_node")"
assert_json "$hy_node" '.options.bbr_profile == "aggressive" and .options.up_mbps == 123 and .options.down_mbps == 456' 'BBR profile does not replace bandwidth'
reject_without_writes proxy_node_edit --id "$hy_id" --xhttp-mode auto
reject_without_writes proxy_node_edit --id "$hy_id" --host front.example
reject_without_writes proxy_node_edit --id "$hy_id" --up-mbps 1.5
run_ok proxy_node_edit --id "$hy_id" --obfs none
run_ok proxy_node_edit --id "$hy_id" --obfs salamander
run_ok proxy_node_edit --id "$hy_id" --obfs gecko
run_ok proxy_node_edit --id "$hy_id" --name hy-renamed
updated="$(proxy_manifest_node "$hy_id")"
assert_equal "$hy_password" "$(jq -r '.options.obfs_password' <<<"$updated")" 'obfuscation password survives disabling, re-enabling and switching types'
assert_equal "$(jq -Sc '.credentials' <<<"$hy_node")" "$(jq -Sc '.credentials' <<<"$updated")" 'Hysteria2 edits preserve authentication'
assert_json "$updated" '.options.bbr_profile == "aggressive" and .options.up_mbps == 123 and .options.down_mbps == 456 and .ip_strategy == "ipv6_only"' 'rename preserves optional BBR, bandwidth and IP strategy'
reject_without_writes proxy_node_core_set --id "$hy_id" --core xray --confirm-disruptive
run_ok proxy_node_edit --id "$hy_id" --obfs salamander
reject_without_writes proxy_node_core_set --id "$hy_id" --core xray --confirm-disruptive
updated="$(proxy_manifest_node "$hy_id")"
updated="$(jq 'del(.options.bbr_profile) | .options.chrome_parrot=false' <<<"$updated")"
replace_node "$hy_id" "$updated"
reject_without_writes proxy_node_core_set --id "$hy_id" --core xray --confirm-disruptive
updated="$(jq 'del(.options.chrome_parrot)' <<<"$updated")"
replace_node "$hy_id" "$updated"
TEST_XRAY_VERSION=26.3.26
reject_without_writes proxy_node_core_set --id "$hy_id" --core xray --confirm-disruptive
TEST_XRAY_VERSION=26.3.27

# Switching validates both real configurations while retaining server-only Mbps,
# credentials, TLS identity and IP policy, which a URI comparison alone misses.
before_switch="$(proxy_manifest_node "$hy_id")"
run_ok proxy_node_core_set --id "$hy_id" --core xray --confirm-disruptive
after_switch="$(proxy_manifest_node "$hy_id")"
assert_equal "$(jq -Sc 'del(.core,.updated_at,.tls.certificate_path,.tls.key_path)' <<<"$before_switch")" \
    "$(jq -Sc 'del(.core,.updated_at,.tls.certificate_path,.tls.key_path)' <<<"$after_switch")" 'switch retains every non-path runtime field'
assert_json "$(<"${TEST_TEMP}/config-xray.json")" \
    '.inbounds[] | select(.protocol == "hysteria") | .streamSettings.finalmask.quicParams.brutalUp == "123000000" and .streamSettings.finalmask.quicParams.brutalDown == "456000000"' 'Xray preserves decimal Mbps units'
assert_json "$(<"${TEST_TEMP}/config-xray.json")" \
    '.outbounds[] | select(.tag | startswith("direct-node-")) | .settings.domainStrategy == "ForceIPv6"' 'Xray preserves IPv6-only direct policy'
reject_without_writes proxy_node_edit --id "$hy_id" --bbr-profile standard
reject_without_writes proxy_node_edit --id "$hy_id" --obfs gecko
run_ok proxy_node_core_set --id "$hy_id" --core sing-box --confirm-disruptive
assert_json "$(<"${TEST_TEMP}/config-sing-box.json")" \
    '.inbounds[] | select(.type == "hysteria2") | .up_mbps == 123 and .down_mbps == 456 and .obfs.type == "salamander"' 'reverse switch retains Hysteria2 runtime fields'

# Exclusive relay exits are rebuilt from their URI, with explicit runtime options
# checked against the target before staging certificates or changing either state.
# This synthetic full-certificate pin checks state/config preservation only;
# this unit does not create the remote certificate or perform a TLS handshake.
relay_cert_pin=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
relay_uri="hysteria2://relay-password@relay.example:443?sni=relay.example&insecure=1&pinSHA256=${relay_cert_pin}&obfs=salamander&obfs-password=relay-obfs#relay"
descriptor="$(proxy_relay_uri_parse "$relay_uri" hysteria2)"
jq -n --arg node "$hy_id" --arg uri "$relay_uri" --argjson descriptor "$descriptor" '{schema_version:1,
    exits:[{id:"exit-aaaaaaaaaaaaaaaa",name:"exclusive-hy",type:"protocol",core:"sing-box",profile:"hysteria2",
        uri:$uri,descriptor:($descriptor | .compatible_cores=["sing-box"]),endpoint:$descriptor.endpoint,
        network_hint:$descriptor.network_hint,client_options:{chrome_parrot:false},created_at:"",updated_at:""}],
    bindings:[{id:"bind-aaaaaaaaaaaaaaaa",node_id:$node,exit_id:"exit-aaaaaaaaaaaaaaaa",created_at:"",updated_at:""}],forwards:[]
}' >"$PROXY_RELAY_FILE"
reject_without_writes proxy_node_core_set --id "$hy_id" --core xray --confirm-disruptive
jq '.exits[0].client_options={bbr_profile:"standard"}' "$PROXY_RELAY_FILE" >"${TEST_TEMP}/relay.json"
mv -- "${TEST_TEMP}/relay.json" "$PROXY_RELAY_FILE"
reject_without_writes proxy_node_core_set --id "$hy_id" --core xray --confirm-disruptive
jq '.exits[0].client_options={} | .exits[0].uri |= sub("obfs=salamander";"obfs=gecko")' "$PROXY_RELAY_FILE" >"${TEST_TEMP}/relay.json"
mv -- "${TEST_TEMP}/relay.json" "$PROXY_RELAY_FILE"
reject_without_writes proxy_node_core_set --id "$hy_id" --core xray --confirm-disruptive
jq --arg uri "$relay_uri" '.exits[0].uri=$uri' "$PROXY_RELAY_FILE" >"${TEST_TEMP}/relay.json"
mv -- "${TEST_TEMP}/relay.json" "$PROXY_RELAY_FILE"
run_ok proxy_node_core_set --id "$hy_id" --core xray --confirm-disruptive
assert_json "$(<"$PROXY_RELAY_FILE")" '.exits[0].core == "xray" and (.exits[0].descriptor.compatible_cores | index("xray") != null)' 'exclusive exit migrated with URI-derived compatibility cache'
assert_json "$(<"${TEST_TEMP}/config-xray.json")" \
    ".outbounds[] | select(.protocol == \"hysteria\") | .streamSettings.tlsSettings.pinnedPeerCertSha256 == \"$relay_cert_pin\"" 'exclusive exit retains full-certificate pin in Xray configuration'
assert_json "$(proxy_manifest_node "$hy_id")" '.ip_strategy == "ipv6_only" and .options.up_mbps == 123 and .options.down_mbps == 456' 'bound-node switch retains temporarily inactive direct policy and bandwidth'

run_ok proxy_node_add --profile hysteria2 --core xray --name hy-xray --port 30202 --address proxy.example
assert_json "$(node_named hy-xray)" '.core == "xray" and .options.obfs_type == "none" and .options.up_mbps == 10000 and .options.down_mbps == 10000 and (.options | has("bbr_profile") | not)' 'Xray Hysteria2 CLI retains original bandwidth defaults without sing-box options'

printf 'PASS: proxy node XHTTP, Hysteria2 and core-switch enhancements\n'
