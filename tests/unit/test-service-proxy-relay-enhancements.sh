#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TEMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_json() { jq -e "$2" <<<"$1" >/dev/null || fail "$3"; }
expect_status() {
    local expected="$1" actual=0
    shift
    "$@" >"$TEST_TEMP/stdout" 2>"$TEST_TEMP/stderr" || actual=$?
    [[ "$actual" == "$expected" ]] || fail "$1 returned $actual, expected $expected"
}

source "$TEST_ROOT/commands/service/proxy/relay-uri.sh"
source "$TEST_ROOT/commands/service/proxy/relay.sh"
PROXY_MANIFEST="$TEST_TEMP/nodes.json"
PROXY_STATE_DIR="$TEST_TEMP"
PROXY_RELAY_FILE="$TEST_TEMP/relay.json"
printf '{"nodes":[]}\n' >"$PROXY_MANIFEST"
vps_cmd_error() { printf '%s\n' "$*" >&2; }
vps_cmd_success() { :; }
proxy_is_interactive() { return 1; }
proxy_stop_after_dependency_plan() { return 1; }
proxy_valid_name() { [[ -n "$1" ]]; }
proxy_core_valid() { [[ "$1" == sing-box || "$1" == xray ]]; }
proxy_core_label() { printf '%s' "$1"; }
proxy_relay_prepare_state() { proxy_relay_validate_file "$PROXY_RELAY_FILE"; }
proxy_mktemp_json() { mktemp "$1/.$2.XXXXXX"; }
vps_cmd_lock() { :; }
vps_cmd_unlock() { :; }
proxy_recover_transaction() { :; }
_proxy_relay_commit_candidate() {
    proxy_relay_validate_file "$1" || return $?
    cp -- "$1" "$PROXY_RELAY_FILE"
}
make_exit() {
    local uri="$1" core="$2" descriptor
    descriptor="$(proxy_relay_uri_parse "$uri")"
    jq -cn --arg uri "$uri" --arg core "$core" --argjson d "$descriptor" '
        {id:"exit-0000000000000001",name:"fixture",type:"protocol",core:$core,
         profile:$d.profile,uri:$uri,descriptor:$d,endpoint:$d.endpoint,
         network_hint:$d.network_hint,created_at:"fixture",updated_at:"fixture"}'
}
write_state() {
    jq -n --argjson item "$1" '{schema_version:1,exits:[$item],bindings:[],forwards:[]}' >"$PROXY_RELAY_FILE"
}
make_xhttp_uri() {
    local profile="$1" mode="${2-}" uri
    case "$profile" in
        vless-xhttp-tls) uri="vless://$uuid@relay.example:443?security=tls&encryption=none" ;;
        vless-xhttp-reality) uri="vless://$uuid@relay.example:443?security=reality&encryption=none&pbk=$public_key&sid=0123456789abcdef&fp=chrome" ;;
        trojan-xhttp-reality) uri="trojan://pass%3Aword@relay.example:443?security=reality&pbk=$public_key&sid=0123456789abcdef&fp=chrome" ;;
        *) return 2 ;;
    esac
    uri+='&type=xhttp&path=%2Frelay%2Fv2&host=front.example&sni=server.example'
    [[ -z "$mode" ]] || uri+="&mode=$mode"
    printf '%s' "$uri"
}

uuid=11111111-1111-4111-8111-111111111111
public_key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
spki=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
cert_pin=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for profile in vless-xhttp-tls vless-xhttp-reality trojan-xhttp-reality; do
    for mode in '' auto packet-up stream-up stream-one; do
        uri="$(make_xhttp_uri "$profile" "$mode")"
        parsed="$(proxy_relay_uri_parse "$uri")"
        assert_json "$parsed" ".profile == \"$profile\" and .transport.mode == \"${mode:-stream-one}\" and .transport.host == \"front.example\" and .transport.path == \"/relay/v2\" and .tls.server_name == \"server.example\" and .tls.alpn == [\"h2\"] and .compatible_cores == [\"xray\"]" 'XHTTP parse preserves mode, Host, path and SNI'
        exit_json="$(make_exit "$uri" xray)"
        rendered="$(proxy_relay_render_outbound xray "$exit_json" 26.3.27)"
        assert_json "$rendered" ".outbounds[0].streamSettings.network == \"xhttp\" and .outbounds[0].streamSettings.xhttpSettings == {mode:\"${mode:-stream-one}\",host:\"front.example\",path:\"/relay/v2\"}" 'XHTTP outbound uses imported mode and HTTP endpoint fields'
        if [[ "$profile" == vless-xhttp-tls ]]; then
            assert_json "$rendered" '.outbounds[0].streamSettings.tlsSettings.alpn == ["h2"]' 'TLS XHTTP must stay on H2'
        else
            assert_json "$rendered" '.outbounds[0].streamSettings.security == "reality" and .outbounds[0].streamSettings.realitySettings.serverName == "server.example"' 'REALITY XHTTP retains REALITY security and SNI'
        fi
        rewritten="$(proxy_relay_uri_rewrite "$uri" 2001:db8::10 24443)"
        after="$(proxy_relay_uri_parse "$rewritten")"
        assert_json "$after" '.endpoint == {host:"2001:db8::10",port:24443}' 'XHTTP IPv6 rewrite changes endpoint'
        [[ "$(jq -c 'del(.endpoint)' <<<"$parsed")" == "$(jq -c 'del(.endpoint)' <<<"$after")" ]] || fail 'XHTTP rewrite changed authentication or transport options'
        expect_status 10 proxy_relay_uri_parse "${uri}&extra=%7B%7D"
        expect_status 10 proxy_relay_uri_parse "${uri}&alpn=h3"
        expect_status 10 proxy_relay_uri_parse "${uri}&h3=1"
    done
    expect_status 10 proxy_relay_uri_parse "$(make_xhttp_uri "$profile" invalid)"
    expect_status 10 proxy_relay_uri_parse "$(make_xhttp_uri "$profile")&alpn=h2%2Ch3"
done
legacy="$(make_exit "$(make_xhttp_uri vless-xhttp-tls)" xray)"
legacy="$(jq '.descriptor={compatible_cores:["sing-box"],transport:{mode:"old-cache"}}' <<<"$legacy")"
write_state "$legacy"
cp "$PROXY_RELAY_FILE" "$TEST_TEMP/legacy.json"
proxy_relay_normalize_file "$PROXY_RELAY_FILE" "$TEST_TEMP/normalized.json"
cmp -s "$PROXY_RELAY_FILE" "$TEST_TEMP/legacy.json" || fail 'XHTTP descriptor normalization changed source'
assert_json "$(cat "$TEST_TEMP/normalized.json")" '.exits[0].descriptor.transport.mode == "stream-one"' 'legacy XHTTP client mode remains stream-one'

hys_uri="hy2://user%3Ap%40ss@relay.example:443?sni=server.example&insecure=1&pinSHA256=$cert_pin"
salamander_uri="${hys_uri}&obfs=salamander&obfs-password=mask%3Asecret"
gecko_uri="${hys_uri}&obfs=gecko&obfs-password=mask%3Asecret"
parsed="$(proxy_relay_uri_parse "$hys_uri")"
assert_json "$parsed" '.compatible_cores == ["sing-box","xray"] and .network_hint == "udp" and .credentials.password == "user:p@ss"' 'Hysteria2 URI supports both cores and decoded authentication'
for hys_version in 26.3.27 26.9.9; do
    rendered="$(proxy_relay_render_outbound xray "$(make_exit "$salamander_uri" xray)" "$hys_version")"
    assert_json "$rendered" ".outbounds[0] | .protocol == \"hysteria\" and .settings == {version:2,address:\"relay.example\",port:443} and .streamSettings.network == \"hysteria\" and .streamSettings.security == \"tls\" and .streamSettings.hysteriaSettings == {version:2,auth:\"user:p@ss\"} and .streamSettings.tlsSettings.pinnedPeerCertSha256 == \"$cert_pin\" and .streamSettings.finalmask == {udp:[{type:\"salamander\",settings:{password:\"mask:secret\"}}]}" 'Xray Hysteria2 maps protocol, auth, full certificate pin and Salamander without congestion overrides'
done
for hys_version in 25.12.31 26.2.99 26.3.26; do
    expect_status 10 proxy_relay_render_outbound xray "$(make_exit "$hys_uri" xray)" "$hys_version"
done
rendered="$(proxy_relay_render_outbound xray "$(make_exit "$hys_uri" xray)" 26.3.27)"
assert_json "$rendered" '(.outbounds[0].streamSettings | has("finalmask") | not)' 'Xray Hysteria2 without obfuscation keeps native congestion defaults'
sb_exit="$(proxy_relay_apply_client_options "$(make_exit "$hys_uri" sing-box)" '' "$spki" '')"
rendered="$(proxy_relay_render_outbound sing-box "$sb_exit" 1.13.0)"
assert_json "$rendered" '.outbounds[0] | has("bbr_profile") == false and has("up_mbps") == false and has("down_mbps") == false and has("disable_chrome_parrot") == false' 'omitted local Hysteria2 options retain native defaults'
for bbr in standard conservative aggressive; do
    local_exit="$(proxy_relay_apply_client_options "$sb_exit" '' '' '' "$bbr")"
    [[ "$(jq -r '.uri' <<<"$local_exit")" == "$hys_uri" ]] || fail 'BBR profile was encoded into the standard URI'
    rendered="$(proxy_relay_render_outbound sing-box "$local_exit" 1.14.0)"
    assert_json "$rendered" ".outbounds[0].bbr_profile == \"$bbr\" and .outbounds[0].tls.insecure == false and .outbounds[0].tls.certificate_public_key_sha256 == [\"$spki\"]" 'BBR profile keeps first-stage SPKI pin enforcement'
    expect_status 10 proxy_relay_render_outbound sing-box "$local_exit" 1.13.99
    expect_status 10 proxy_relay_apply_client_options "$(make_exit "$hys_uri" xray)" '' '' '' "$bbr"
    expect_status 10 proxy_relay_render_outbound xray "$(jq '.core="xray"' <<<"$local_exit")" 26.9.9
done
expect_status 2 proxy_relay_apply_client_options "$sb_exit" '' '' '' fast
for chrome in on off; do
    expect_status 10 proxy_relay_apply_client_options "$(make_exit "$hys_uri" xray)" '' '' "$chrome"
done
gecko_exit="$(proxy_relay_apply_client_options "$(make_exit "$gecko_uri" sing-box)" '' "$spki" '')"
rendered="$(proxy_relay_render_outbound sing-box "$gecko_exit" 1.14.0)"
assert_json "$rendered" '.outbounds[0].obfs == {type:"gecko",password:"mask:secret"}' 'Gecko leaves packet-size parameters at native defaults'
expect_status 10 proxy_relay_render_outbound sing-box "$gecko_exit" 1.13.99
expect_status 10 proxy_relay_render_outbound xray "$(make_exit "$gecko_uri" xray)" 26.9.9
expect_status 10 proxy_relay_uri_parse "${hys_uri}&obfs=gecko"
for query in bbr_profile=aggressive up_mbps=100 down_mbps=200 tls_spki_sha256=AAAA chrome_parrot=true; do
    expect_status 10 proxy_relay_uri_parse "${hys_uri}&${query}"
done
rewritten="$(proxy_relay_uri_rewrite "$gecko_uri" 2001:db8::20 5443)"
assert_json "$(proxy_relay_uri_parse "$rewritten")" ".endpoint == {host:\"2001:db8::20\",port:5443} and .options.obfs_type == \"gecko\" and .options.obfs_password == \"mask:secret\" and .tls.certificate_sha256 == \"$cert_pin\"" 'Gecko URI rewrite preserves protocol settings and full certificate pin'

write_state "$sb_exit"
proxy_relay_exit_edit --id exit-0000000000000001 --bbr-profile aggressive
proxy_relay_exit_edit --id exit-0000000000000001 --name renamed
assert_json "$(cat "$PROXY_RELAY_FILE")" ".exits[0].client_options.bbr_profile == \"aggressive\" and .exits[0].client_options.tls_spki_sha256 == \"$spki\"" 'BBR-only edit and rename preserve TLS trust'
cp "$PROXY_RELAY_FILE" "$TEST_TEMP/before-switch.json"
expect_status 10 proxy_relay_exit_edit --id exit-0000000000000001 --core xray
cmp -s "$PROXY_RELAY_FILE" "$TEST_TEMP/before-switch.json" || fail 'unsupported BBR core switch changed state'
proxy_relay_exit_edit --id exit-0000000000000001 --uri "${hys_uri}&obfs=salamander&obfs-password=new-mask"
assert_json "$(cat "$PROXY_RELAY_FILE")" '.exits[0].client_options.bbr_profile == "aggressive" and (.exits[0].client_options | has("tls_spki_sha256") | not)' 'URI change invalidates old TLS trust while keeping explicit BBR policy'
cp "$PROXY_RELAY_FILE" "$TEST_TEMP/before-add.json"
expect_status 10 proxy_relay_exit_add --name rejected --core xray --uri "$hys_uri" --bbr-profile standard
expect_status 10 proxy_relay_exit_add --name rejected --core xray --uri "$gecko_uri"
cmp -s "$PROXY_RELAY_FILE" "$TEST_TEMP/before-add.json" || fail 'unsupported Xray client options changed state'
proxy_relay_exit_add --name gecko --core sing-box --uri "$gecko_uri" --tls-spki-sha256 "$spki" --bbr-profile conservative
assert_json "$(cat "$PROXY_RELAY_FILE")" '.exits | any(.name == "gecko" and .client_options.bbr_profile == "conservative")' 'BBR CLI add stores the explicit policy'

proxy_relay_select_exit() { printf '%s' exit-0000000000000001; }
proxy_prompt_select() {
    case "$1" in
        '编辑字段') printf '%s\n' "$@" >"$TEST_TEMP/menu-options"; printf 'bbr-profile' ;;
        'BBR Profile') printf 'conservative' ;;
        *) return 2 ;;
    esac
}
proxy_relay_menu_exit_edit
assert_json "$(cat "$PROXY_RELAY_FILE")" '.exits[0].client_options.bbr_profile == "conservative"' 'numbered menu BBR selection reaches the edit command'
printf 'PASS: relay XHTTP modes, Hysteria2 cores, Gecko, BBR, pin preservation and URI rewrites\n'
