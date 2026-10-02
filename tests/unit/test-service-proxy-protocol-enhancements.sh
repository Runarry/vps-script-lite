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
    for invalid in '.options.obfs_type="invalid"' '.options.bbr_profile="invalid"' \
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

test_hysteria_relay_outbounds() {
    local uri parsed exit_json rendered base single version item
    uri='hy2://p%2Bass@[2001:db8::10]:24445,24443-24444,24444?sni=relay.example#multi'
    parsed="$(proxy_relay_uri_parse "$uri")" || fail 'HY2 IPv6 multiport parse'
    assert_json "$parsed" '.endpoint == {host:"2001:db8::10",port:24443,ports:"24443-24445"}' 'canonical union and numeric fallback port'
    assert_json "$(proxy_relay_uri_parse 'hy2://secret@relay.example')" '.endpoint == {host:"relay.example",port:443} and .tls.server_name == "relay.example"' 'HY2 omitted port and SNI defaults'
    assert_json "$(proxy_relay_uri_parse 'hysteria2://secret@[2001:db8::10]?sni=relay.example')" '.endpoint == {host:"2001:db8::10",port:443}' 'HY2 IPv6 omitted port default'
    assert_json "$(proxy_relay_uri_parse 'hy2://secret@relay.example:00443,443-443')" '.endpoint == {host:"relay.example",port:443}' 'collapsed single port keeps legacy descriptor shape'
    for item in 0 65536 443-442 '443,,444' '443,' '443:444'; do
        assert_status 10 proxy_relay_uri_parse "hy2://secret@relay.example:$item"
    done
    assert_status 10 proxy_relay_uri_parse 'socks5://user:secret@relay.example'
    assert_equal 'hy2://p%2Bass@[2001:db8::20]:34443?sni=relay.example#multi' \
        "$(proxy_relay_uri_rewrite "$uri" '2001:db8::20' 34443)" 'native forward share URI has one local port'
    base="$(jq -cn --arg uri "$uri" '{id:"exit-0000000000000001",type:"protocol",core:"sing-box",profile:"hysteria2",uri:$uri}')"
    rendered="$(proxy_relay_render_outbound sing-box "$base" 1.11.0)" || fail 'fixed hop baseline'
    assert_json "$rendered" '.outbounds[0] | .server_ports == ["24443:24445"] and .hop_interval == "30s" and (has("server_port") | not) and (has("up_mbps") | not)' 'sing-box multiport default hop and auto bandwidth'
    assert_status 10 proxy_relay_render_outbound sing-box "$base" 1.10.9
    exit_json="$(jq -c '.client_options={hop_interval:"5-10",up_mbps:17,down_mbps:31,chrome_parrot:false,bbr_profile:"aggressive"}' <<<"$base")"
    rendered="$(proxy_relay_render_outbound sing-box "$exit_json" 1.14.0)" || fail 'sing-box all HY2 client options'
    assert_json "$rendered" '.outbounds[0] | .server_ports == ["24443:24445"] and .hop_interval == "5s" and .hop_interval_max == "10s" and .up_mbps == 17 and .down_mbps == 31 and .disable_chrome_parrot and .bbr_profile == "aggressive"' 'sing-box random interval, bandwidth, Chrome and BBR'
    assert_status 10 proxy_relay_render_outbound sing-box "$(jq -c '.client_options={hop_interval:"5-10"}' <<<"$base")" 1.13.12
    assert_status 10 proxy_relay_render_outbound sing-box "$exit_json" 1.14.0-beta.1
    for item in '.client_options={up_mbps:17}' '.client_options={up_mbps:0,down_mbps:31}' \
        '.client_options={hop_interval:"4"}' '.client_options={hop_interval:"10-5"}'; do
        assert_status 10 proxy_relay_render_outbound sing-box "$(jq -c "$item" <<<"$base")" 1.14.0
    done
    exit_json="$(jq -c '.core="xray"' <<<"$exit_json")"
    # Keep URI-only data separate from client settings, including Gecko.
    exit_json="$(jq -c --arg uri "${uri%%#*}&obfs=gecko&obfs-password=mask#multi" '.uri=$uri' <<<"$exit_json")"
    for version in 26.9.8 26.9.9; do
        rendered="$(proxy_relay_render_outbound xray "$exit_json" "$version")" || fail "Xray multiport schema $version"
        assert_json "$rendered" '.outbounds[0] | .settings.port == 24443 and .streamSettings.finalmask.quicParams.brutalUp == "17000000" and .streamSettings.finalmask.quicParams.brutalDown == "31000000" and .streamSettings.finalmask.quicParams.bbrProfile == "aggressive" and .streamSettings.finalmask.quicParams.disableChromeParrot and .streamSettings.finalmask.udp[0] == {type:"salamander",settings:{password:"mask",packetSize:"512-1200"}} and (.streamSettings.finalmask.quicParams | has("congestion") | not)' 'Xray manual negotiation and Gecko mapping'
        if [[ "$version" == 26.9.8 ]]; then
            assert_json "$rendered" '.outbounds[0].streamSettings.finalmask | .quicParams.udpHop == {ports:"24443-24445",interval:"5-10"} and (.udp | length) == 1' 'old Xray udpHop schema'
        else
            assert_json "$rendered" '.outbounds[0].streamSettings.finalmask | (.quicParams | has("udpHop") | not) and .udp[-1] == {type:"udphop",settings:{mode:"intervalLocal,intervalRemote",remotePorts:"24443-24445",interval:"5-10"}}' 'new Xray udphop must be last'
        fi
    done
    assert_status 10 proxy_relay_render_outbound xray "$exit_json" 26.9.7
    base="$(jq -c '.core="xray"' <<<"$base")"
    assert_status 10 proxy_relay_render_outbound xray "$base" 26.3.26
    assert_status 0 proxy_relay_render_outbound xray "$base" 26.3.27
    assert_status 10 proxy_relay_render_outbound xray "$(jq -c '.client_options={bbr_profile:"standard"}' <<<"$base")" 26.4.12
    assert_status 0 proxy_relay_render_outbound xray "$(jq -c '.client_options={bbr_profile:"standard"}' <<<"$base")" 26.4.13
    exit_json="$(jq -c 'del(.client_options)' <<<"$exit_json")"
    assert_status 10 proxy_relay_render_outbound xray "$exit_json" 26.5.31
    assert_status 0 proxy_relay_render_outbound xray "$exit_json" 26.6.1
    single="$(jq -c '.uri="hy2://secret@relay.example:443"' <<<"$base")"
    rendered="$(proxy_relay_render_outbound xray "$single" 26.9.9)" || fail 'Xray default HY2 outbound'
    assert_json "$rendered" '.outbounds[0].streamSettings | has("finalmask") | not' 'single-port auto defaults do not introduce native options'
    assert_status 10 proxy_relay_render_outbound xray "$(jq -c '.client_options={hop_interval:"30"}' <<<"$single")" 26.9.9
}

test_hysteria_gui_uri() {
    local core host node uri query parsed rewritten native
    : >"$TEST_TEMP/hy2-gui-uris.txt"
    for core in sing-box xray; do
        for host in relay.example 192.0.2.10 2001:db8::10; do
            node="$(fixture_node "$core" hysteria2 | jq -c --arg host "$host" '.address=$host | .options.hop_ports="20120-20200"')"
            if [[ "$core" == sing-box ]]; then uri="$(proxy_sb_render_uri "$node")"
            else uri="$(proxy_xray_render_uri "$node")"; fi
            [[ "$uri" == *':34443?'* ]] || fail 'GUI URI authority must contain the numeric listener, not a range'
            query="${uri%%#*}"
            query="$(_proxy_relay_query_json "${query#*\?}")"
            assert_json "$query" '.mport == "20120-20200,34443" and .pinSHA256 == ("a" * 64)' 'GUI hopping extension and TLS pin'
            parsed="$(proxy_relay_uri_parse "$uri")"
            assert_json "$parsed" '.endpoint.port == 20120 and .endpoint.ports == "20120-20200,34443" and .credentials.password == "p+a&ss:word"' 'compatible URI roundtrip retains the complete port set and password'
            printf '%s\n' "$uri" >>"$TEST_TEMP/hy2-gui-uris.txt"
            rewritten="$(proxy_relay_uri_rewrite "$uri" "$host" 24443)"
            [[ "$rewritten" != *mport=* && "$rewritten" == *':24443?'* && "$rewritten" == *pinSHA256=* ]] || fail 'single-port forward must remove upstream hopping without losing TLS pin'
            assert_json "$(proxy_relay_uri_parse "$rewritten")" '.endpoint.port == 24443 and (.endpoint | has("ports") | not)' 'single-port rewrite stays single'
            rewritten="$(proxy_relay_uri_rewrite "$uri" "$host" '24445,24443-24444')"
            assert_json "$(proxy_relay_uri_parse "$rewritten")" '.endpoint.port == 24443 and .endpoint.ports == "24443-24445"' 'mport replacement removes the previous port set'
            node="$(jq 'del(.options.hop_ports)' <<<"$node")"
            if [[ "$core" == sing-box ]]; then uri="$(proxy_sb_render_uri "$node")"
            else uri="$(proxy_xray_render_uri "$node")"; fi
            [[ "$uri" != *mport=* && "$uri" == *':34443?'* ]] || fail 'single-port exports stay unchanged'
        done
    done
    native='hy2://secret@relay.example:20120-20200?sni=relay.example'
    assert_json "$(proxy_relay_uri_parse 'hy2://secret@relay.example:443?mport=20200%2C20120-20199')" '.endpoint == {host:"relay.example",port:20120,ports:"20120-20200"}' 'mport normalizes independently of numeric fallback'
    assert_equal "$(proxy_relay_uri_parse "$native")" "$(proxy_relay_uri_parse "${native/20120-20200/20120}&mport=20120-20200")" 'native and compatible forms have identical descriptors'
    assert_status 0 proxy_relay_uri_parse "$native&mport=20120-20200"
    assert_status 10 proxy_relay_uri_parse "$native&mport=20121-20200"
    assert_status 10 proxy_relay_uri_parse 'hy2://secret@relay.example:443?mport='
    assert_status 10 proxy_relay_uri_parse 'hy2://secret@relay.example:443?mport=0-65536'
    assert_status 10 proxy_relay_uri_parse 'hy2://secret@relay.example:443?mport=443&mport=444'
    assert_json "$(proxy_relay_uri_parse 'hy2://secret@relay.example?mport=20120')" '.endpoint == {host:"relay.example",port:20120}' 'single mport does not accidentally dial the fallback'
    assert_equal 'hy2://secret@relay.example:24443' "$(proxy_relay_uri_rewrite 'hy2://secret@relay.example:443?mport=20120-20200' relay.example 24443)" 'rewriting a query containing only mport leaves no empty query'
    assert_equal 'hy2://secret@relay.example:24443' "$(proxy_relay_uri_rewrite 'hy2://secret@relay.example:443' relay.example 24443)" 'empty query rewrite stays empty'
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
printf 'TEST: Hysteria2 URI multiport and outbound capability/rendering matrix\n'
test_hysteria_relay_outbounds
printf 'TEST: Hysteria2 GUI-compatible mport links and native import compatibility\n'
test_hysteria_gui_uri
printf 'PASS: proxy protocol enhancements\n'
