#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TEMP"' EXIT
export VPSCTL_TESTING=1 VPSCTL_NON_INTERACTIVE=1 VPSCTL_DRY_RUN=0
export VPSCTL_SYSTEM_ROOT="${TEST_TEMP}/root"
mkdir -p "$VPSCTL_SYSTEM_ROOT"
# shellcheck source=lib/command.sh
source "${TEST_ROOT}/lib/command.sh"
vps_cmd_init 'proxy protocol enhancement tests' "$TEST_ROOT"
# shellcheck source=commands/service/proxy/common.sh
source "${TEST_ROOT}/commands/service/proxy/common.sh"
# shellcheck source=commands/service/proxy/protocols-sing-box.sh
source "${TEST_ROOT}/commands/service/proxy/protocols-sing-box.sh"
# shellcheck source=commands/service/proxy/protocols-xray.sh
source "${TEST_ROOT}/commands/service/proxy/protocols-xray.sh"
# shellcheck source=commands/service/proxy/relay-uri.sh
source "${TEST_ROOT}/commands/service/proxy/relay-uri.sh"
proxy_common_init

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_json() { jq -e "$2" >/dev/null <<<"$1" || fail "$3"; }
assert_status() {
    local expected="$1" actual=0
    shift
    "$@" >"${TEST_TEMP}/output" 2>&1 || actual=$?
    assert_equal "$expected" "$actual" "$*: $(<"${TEST_TEMP}/output")"
}

fixture_node() {
    jq -cn --arg core "$1" --arg profile "$2" '
        {id:"node-0000000000000001",core:$core,profile:$profile,name:"protocol fixture",
         listen:"127.0.0.1",port:34443,address:"2001:db8::10",
         credentials:{uuid:"11111111-1111-4111-8111-111111111111",password:"p+a&ss:word",
                      private_key:"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                      public_key:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",short_id:"0123456789abcdef"},
         tls:{enabled:true,mode:"self-signed",server_name:"sni.example",insecure:true,
              certificate_path:"/fixture/cert.pem",key_path:"/fixture/key.pem",
              certificate_sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
         transport:{type:(if $profile == "hysteria2" then "quic" else "xhttp" end),path:"/xhttp?part=1&item=2"},
         options:{obfs_type:"none",obfs_password:"o+b&fs",up_mbps:100,down_mbps:200,congestion_control:"bbr"}} |
         if $profile | endswith("reality") then .tls.mode="reality" else . end
    '
}

test_xhttp_modes() {
    local profile mode base node rendered uri descriptor query
    for profile in vless-xhttp-tls vless-xhttp-reality trojan-xhttp-reality; do
        proxy_xray_supports_profile "$profile" || fail "profile missing: $profile"
        base="$(fixture_node xray "$profile")"
        for mode in auto packet-up stream-up stream-one; do
            node="$(jq -c --arg mode "$mode" '.transport.mode=$mode | .transport.host="host.example"' <<<"$base")"
            rendered="$(proxy_xray_render_node "$node")" || fail "render $profile/$mode"
            jq -e --arg mode "$mode" --argjson node "$node" '
                length == 1 and .[0].streamSettings.network == "xhttp" and
                .[0].streamSettings.xhttpSettings == {mode:$mode,host:"host.example",path:$node.transport.path} and
                (if $node.profile == "vless-xhttp-tls" then
                     .[0].streamSettings.security == "tls" and .[0].streamSettings.tlsSettings.alpn == ["h2"]
                 else .[0].streamSettings.security == "reality" and
                     .[0].streamSettings.realitySettings.serverNames == ["sni.example"] end)
            ' >/dev/null <<<"$rendered" || fail "XHTTP settings $profile/$mode"
            uri="$(proxy_xray_render_uri "$node")" || fail "URI $profile/$mode"
            descriptor="$(proxy_relay_uri_parse "$uri" "$profile")" || fail "URI parse $profile/$mode"
            jq -e --arg mode "$mode" --argjson node "$node" '
                .transport.type == "xhttp" and .transport.mode == $mode and
                .transport.host == "host.example" and .transport.path == $node.transport.path and
                .tls.server_name == "sni.example" and .tls.alpn == ["h2"] and
                .endpoint.host == "2001:db8::10" and .endpoint.port == 34443
            ' >/dev/null <<<"$descriptor" || fail "XHTTP URI roundtrip $profile/$mode"
            [[ "$uri" != *BBBBBBBB* ]] || fail 'XHTTP URI contains private key'
        done
        assert_status 10 proxy_xray_validate_node "$(jq -c '.transport.mode="invalid"' <<<"$base")"
        assert_status 10 proxy_xray_validate_node "$(jq -c '.transport.mode=null' <<<"$base")"
        assert_status 10 proxy_xray_validate_node "$(jq -c '.transport.host="bad\nhost"' <<<"$base")"

        rendered="$(proxy_xray_render_node "$base")"
        uri="$(proxy_xray_render_uri "$base")"
        query="${uri#*\?}"; query="${query%%#*}"
        query="$(_proxy_relay_query_json "$query")"
        if [[ "$profile" == trojan-xhttp-reality ]]; then
            assert_json "$rendered" '.[0].streamSettings.xhttpSettings | has("mode") or has("host") | not' 'legacy Trojan server defaults'
            assert_json "$query" 'has("mode") or has("host") | not' 'legacy Trojan client no-mode URI'
        else
            assert_json "$rendered" '.[0].streamSettings.xhttpSettings.mode == "stream-one"' 'legacy TLS or new REALITY stream-one default'
            assert_json "$query" '.mode == "stream-one"' 'stream-one client default'
        fi
        if [[ "$profile" == vless-xhttp-tls ]]; then
            assert_json "$rendered" '.[0].streamSettings.xhttpSettings.host == "sni.example"' 'legacy TLS server host default'
            assert_json "$query" '.host == "sni.example" and .alpn == "h2"' 'legacy TLS client host/H2 defaults'
        fi
    done
}

test_xray_hysteria() {
    local node rendered uri sb_uri parsed obfs invalid
    proxy_xray_supports_profile hysteria2 || fail 'Xray Hysteria2 profile missing'
    for obfs in none salamander; do
        node="$(fixture_node xray hysteria2 | jq -c --arg obfs "$obfs" '.options.obfs_type=$obfs')"
        rendered="$(PROXY_RENDER_CORE_VERSION=26.3.27 proxy_xray_render_node "$node")" || fail "Xray Hysteria2 $obfs"
        jq -e --argjson node "$node" --arg obfs "$obfs" '
            .[0].protocol == "hysteria" and
            .[0].settings == {version:2,clients:[{auth:$node.credentials.password}]} and
            .[0].streamSettings.network == "hysteria" and .[0].streamSettings.security == "tls" and
            .[0].streamSettings.hysteriaSettings == {version:2} and
            .[0].streamSettings.tlsSettings.alpn == ["h3"] and
            .[0].streamSettings.finalmask.quicParams == {brutalUp:"100000000",brutalDown:"200000000"} and
            (if $obfs == "none" then (.[0].streamSettings.finalmask | has("udp") | not)
             else .[0].streamSettings.finalmask.udp == [{type:"salamander",settings:{password:$node.options.obfs_password}}] end)
        ' >/dev/null <<<"$rendered" || fail "native Xray Hysteria2 shape/bandwidth $obfs"
        uri="$(proxy_xray_render_uri "$node")"
        sb_uri="$(proxy_sb_render_uri "$(jq -c '.core="sing-box"' <<<"$node")")"
        assert_equal "$sb_uri" "$uri" 'Hysteria2 URI has same semantics and encoding on both cores'
        parsed="$(proxy_relay_uri_parse "$uri" hysteria2)" || fail 'Xray Hysteria2 URI parse'
        jq -e --arg obfs "$obfs" '.profile == "hysteria2" and .options.obfs_type == $obfs and
            .credentials.password == "p+a&ss:word" and .tls.certificate_sha256 == ("a" * 64)' \
            >/dev/null <<<"$parsed" || fail 'Hysteria2 URI roundtrip'
        [[ "$uri" != *up_mbps* && "$uri" != *brutalUp* && "$uri" != *bbr_profile* && "$uri" != *spki* ]] || fail 'Hysteria2 URI leaked local options'
    done
    for invalid in '.options.obfs_type="gecko"' '.options.bbr_profile="standard"' \
        '.options.chrome_parrot=false' '.options.disable_chrome_parrot=true' '.client_options.chrome_parrot=true' \
        '.options.up_mbps=0' '.options.down_mbps=-1'; do
        assert_status 10 proxy_xray_validate_node "$(jq -c "$invalid" <<<"$node")"
    done
    PROXY_RENDER_CORE_VERSION=26.3.26 assert_status 10 proxy_xray_render_node "$node"
    PROXY_RENDER_CORE_VERSION=26.3.27-rc.1 assert_status 10 proxy_xray_render_node "$node"
    PROXY_RENDER_CORE_VERSION=26.9.9 assert_status 0 proxy_xray_render_node "$node"
    PROXY_RENDER_CORE_VERSION=26.3.26 assert_status 0 proxy_xray_validate_node "$node"
    PROXY_RENDER_CORE_VERSION=26.3.26 assert_status 0 proxy_xray_render_uri "$node"
    (
        proxy_core_config_version() { printf '26.3.26'; }
        assert_status 10 proxy_xray_render_node "$node"
        PROXY_RENDER_CORE_VERSION=26.3.27 assert_status 0 proxy_xray_render_node "$node"
    )
}

test_sing_box_hysteria_options() {
    local node base rendered uri parsed profile
    base="$(fixture_node sing-box hysteria2)"
    rendered="$(PROXY_RENDER_CORE_VERSION=1.13.12 proxy_sb_render_node "$base")" || fail 'legacy sing-box Hysteria2 render'
    assert_json "$rendered" '.[0] | has("bbr_profile") or has("obfs") | not' 'legacy sing-box native defaults'
    node="$(jq -c '.options.obfs_type="gecko"' <<<"$base")"
    rendered="$(PROXY_RENDER_CORE_VERSION=1.14.0 proxy_sb_render_node "$node")" || fail 'Gecko render'
    assert_json "$rendered" '.[0].obfs == {type:"gecko",password:"o+b&fs"}' 'Gecko native packet-size defaults'
    uri="$(proxy_sb_render_uri "$node")"
    parsed="$(proxy_relay_uri_parse "$uri" hysteria2)" || fail 'Gecko URI parse'
    assert_json "$parsed" '.options.obfs_type == "gecko" and .options.obfs_password == "o+b&fs"' 'Gecko URI roundtrip'
    PROXY_RENDER_CORE_VERSION=1.13.12 assert_status 10 proxy_sb_render_node "$node"
    PROXY_RENDER_CORE_VERSION=1.14.0-beta.1 assert_status 10 proxy_sb_render_node "$node"
    PROXY_RENDER_CORE_VERSION=1.13.12 assert_status 0 proxy_sb_render_uri "$node"
    for profile in standard conservative aggressive; do
        node="$(jq -c --arg profile "$profile" '.options.bbr_profile=$profile' <<<"$base")"
        rendered="$(PROXY_RENDER_CORE_VERSION=1.14.0 proxy_sb_render_node "$node")" || fail "BBR $profile render"
        jq -e --arg profile "$profile" '.[0].bbr_profile == $profile and (.[0] | has("congestion_control") | not)' \
            >/dev/null <<<"$rendered" || fail 'BBR field location'
        PROXY_RENDER_CORE_VERSION=1.13.12 assert_status 10 proxy_sb_render_node "$node"
        PROXY_RENDER_CORE_VERSION=1.13.12 assert_status 0 proxy_sb_validate_node "$node"
        uri="$(PROXY_RENDER_CORE_VERSION=1.13.12 proxy_sb_render_uri "$node")"
        [[ "$uri" != *bbr* && "$uri" != *up_mbps* && "$uri" != *down_mbps* ]] || fail 'BBR or bandwidth serialized into URI'
    done
    assert_status 10 proxy_sb_validate_node "$(jq -c '.options.bbr_profile="invalid"' <<<"$base")"
    assert_status 10 proxy_sb_validate_node "$(jq -c '.options.bbr_profile=null' <<<"$base")"
    assert_status 10 proxy_sb_validate_node "$(jq -c '.options.obfs_type="gecko" | .options.obfs_password=""' <<<"$base")"
    (
        proxy_core_config_version() { printf '1.13.12'; }
        assert_status 10 proxy_sb_render_node "$node"
        PROXY_RENDER_CORE_VERSION=1.14.0 assert_status 0 proxy_sb_render_node "$node"
    )
}

printf 'TEST: XHTTP modes, legacy defaults and URI roundtrips\n'
test_xhttp_modes
printf 'TEST: Xray native Hysteria2 config, units, URI and version gates\n'
test_xray_hysteria
printf 'TEST: sing-box Hysteria2 Gecko, BBR and native defaults\n'
test_sing_box_hysteria_options
printf 'PASS: proxy protocol enhancements\n'
