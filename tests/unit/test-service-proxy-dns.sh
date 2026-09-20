#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

export VPSCTL_PROXY_TEST_HARNESS_ONLY=1
# shellcheck source=test-service-proxy.sh
# The harness path is resolved from this test file.
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-service-proxy.sh"
unset VPSCTL_PROXY_TEST_HARNESS_ONLY

dns_config_path() { printf '%s' "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json"; }
dns_pending_path() { printf '%s' "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/sing-box.json"; }

assert_dns_state() {
    local mode="$1" server="$2" port="$3" tls_server_name="$4" path="$5" bootstrap="$6" message="$7"
    jq -e --arg mode "$mode" --arg server "$server" --argjson port "$port" \
        --arg tls_server_name "$tls_server_name" --arg path "$path" --arg bootstrap "$bootstrap" '
        .settings.sing_box.dns == {
            mode:$mode,
            server:(if $server == "" then null else $server end),
            port:$port,
            tls_server_name:(if $tls_server_name == "" then null else $tls_server_name end),
            path:(if $path == "" then null else $path end),
            bootstrap:(if $bootstrap == "" then null else $bootstrap end)
        }
    ' "$(manifest_path)" >/dev/null || fail "$message"
}

assert_dns_common_rendering() {
    local config="$1" policy_id="$2" guard_id="$3"
    jq -e --arg policy_id "$policy_id" --arg guard_id "$guard_id" '
        .dns.final == "proxy-dns" and
        .route.default_domain_resolver == "proxy-dns" and
        any(.outbounds[]; .tag == ("direct-" + $policy_id) and
            .domain_resolver == {server:"proxy-dns",strategy:"prefer_ipv4"}) and
        any(.outbounds[]; .tag == ("reality-target-" + $guard_id) and
            .domain_resolver.server == "proxy-dns")
    ' "$config" >/dev/null || fail "DNS common route, node policy, or REALITY resolver rendering"
}

test_dns_cli_defaults_and_validation() {
    local manifest_hash config_hash
    reset_root
    install_external sing-box 1.13.0

    # Reading an old manifest computes the default without eagerly rewriting it.
    jq -e 'has("settings") | not' "$(manifest_path)" >/dev/null || fail "fresh legacy manifest unexpectedly has settings"
    manifest_hash="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    run_proxy dns show --json
    assert_equal 0 "$RUN_STATUS" "default DNS JSON show"
    assert_json "$RUN_OUTPUT" "default DNS JSON show"
    jq -e '
        .schema_version == 1 and .core == "sing-box" and .installed == true and
        .version == "1.13.0" and .source == "default" and
        .settings == {mode:"system",server:null,port:null,tls_server_name:null,path:null,bootstrap:null} and
        .effective.dns.final == "proxy-dns" and
        .effective.route.default_domain_resolver == "proxy-dns" and
        .pending_restart == false and .pending_reason == null
    ' <<<"$RUN_OUTPUT" >/dev/null || fail "default DNS JSON contract"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "DNS show rewrote old manifest"

    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box --name dns-legacy-write \
        --port 33401 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "ordinary write against old DNS manifest"
    jq -e 'getpath(["settings","sing_box","dns"]) == null' "$(manifest_path)" >/dev/null ||
        fail "ordinary node write eagerly stored default DNS settings"

    run_proxy dns show --core xray --json
    assert_equal 2 "$RUN_STATUS" "DNS rejects Xray core"
    run_proxy dns show --core sing-box --core sing-box
    assert_equal 2 "$RUN_STATUS" "DNS rejects duplicate core"
    run_proxy dns show --json extra
    assert_equal 2 "$RUN_STATUS" "DNS show rejects positional arguments"

    manifest_hash="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    config_hash="$(sha256sum "$(dns_config_path)" | awk '{print $1}')"
    run_proxy --dry-run dns set --preset cloudflare-doh
    assert_equal 0 "$RUN_STATUS" "DNS preset dry-run"
    assert_contains "$RUN_OUTPUT" "演练" "DNS preset dry-run output"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "DNS dry-run manifest"
    assert_equal "$config_hash" "$(sha256sum "$(dns_config_path)" | awk '{print $1}')" "DNS dry-run config"

    run_proxy dns set
    assert_equal 2 "$RUN_STATUS" "DNS set requires mode or preset"
    run_proxy dns set --mode invalid
    assert_equal 2 "$RUN_STATUS" "DNS invalid mode"
    run_proxy dns set --mode udp --mode tcp --server 1.1.1.1
    assert_equal 2 "$RUN_STATUS" "DNS duplicate mode"
    run_proxy dns set --mode udp --server 1.1.1.1 --server 8.8.8.8
    assert_equal 2 "$RUN_STATUS" "DNS duplicate server"
    run_proxy dns set --mode system --server 1.1.1.1
    assert_equal 2 "$RUN_STATUS" "system DNS rejects upstream"
    run_proxy dns set --mode udp --server 1.1.1.1 --tls-server-name dns.example
    assert_equal 2 "$RUN_STATUS" "UDP DNS rejects TLS name"
    run_proxy dns set --mode dot --server dns.example --path /dns-query
    assert_equal 2 "$RUN_STATUS" "DoT rejects HTTP path"
    run_proxy dns set --mode doh --server dns.example --path dns-query
    assert_equal 2 "$RUN_STATUS" "DoH rejects relative path"
    run_proxy dns set --mode tcp --server 1.1.1.1 --port 0
    assert_equal 2 "$RUN_STATUS" "DNS rejects zero port"
    run_proxy dns set --mode tcp --server 1.1.1.1 --port 65536
    assert_equal 2 "$RUN_STATUS" "DNS rejects oversized port"
    run_proxy dns set --mode dot --server dns.example --bootstrap bootstrap.example
    assert_equal 2 "$RUN_STATUS" "DNS bootstrap requires IP literal"
    run_proxy dns set --mode udp --server 'bad host'
    assert_equal 2 "$RUN_STATUS" "DNS rejects malformed server"
    run_proxy dns set --preset cloudflare-doh --server 8.8.8.8
    assert_equal 2 "$RUN_STATUS" "DNS preset rejects field override"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "invalid DNS CLI changed manifest"
    assert_equal "$config_hash" "$(sha256sum "$(dns_config_path)" | awk '{print $1}')" "invalid DNS CLI changed config"
}

test_dns_modes_rendering_and_state_preservation() {
    local policy_id relay_id guard_id xray_id exit_id uri config nodes_before relay_before xray_before
    reset_root
    install_external sing-box 1.13.0
    install_external xray 26.9.8

    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box --name dns-policy \
        --port 33501 --address proxy.example --ip-strategy prefer_ipv4
    assert_equal 0 "$RUN_STATUS" "DNS policy fixture"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box --name dns-relay \
        --port 33502 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "DNS relay fixture"
    run_proxy node add --profile vless-reality-vision --core sing-box --name dns-guard \
        --port 33503 --address proxy.example --sni reality.example --reality-anti-relay on
    assert_equal 0 "$RUN_STATUS" "DNS REALITY guard fixture"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name dns-xray \
        --port 33504 --address proxy.example --ip-strategy prefer_ipv6
    assert_equal 0 "$RUN_STATUS" "DNS Xray fixture"
    policy_id="$(node_id_by_name dns-policy)"
    relay_id="$(node_id_by_name dns-relay)"
    guard_id="$(node_id_by_name dns-guard)"
    xray_id="$(node_id_by_name dns-xray)"

    run_proxy node show --id "$relay_id" --uri
    assert_equal 0 "$RUN_STATUS" "DNS relay fixture URI"
    uri="$RUN_OUTPUT"
    run_proxy relay exit add --name dns-protocol-exit --uri "$uri" --core sing-box
    assert_equal 0 "$RUN_STATUS" "DNS relay exit fixture"
    exit_id="$(jq -r '.exits[] | select(.name == "dns-protocol-exit") | .id' "$(relay_path)")"
    run_proxy relay bind add --node-id "$relay_id" --exit-id "$exit_id"
    assert_equal 0 "$RUN_STATUS" "DNS relay binding fixture"

    nodes_before="$(jq -Sc .nodes "$(manifest_path)")"
    relay_before="$(sha256sum "$(relay_path)" | awk '{print $1}')"
    xray_before="$(sha256sum "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json" | awk '{print $1}')"
    config="$(dns_config_path)"

    run_proxy dns set --mode system
    assert_equal 0 "$RUN_STATUS" "system DNS set"
    assert_dns_state system '' null '' '' '' "system DNS normalized state"
    jq -e 'any(.dns.servers[]; . == {type:"local",tag:"proxy-dns",prefer_go:true})' "$config" >/dev/null ||
        fail "sing-box 1.13 system DNS rendering"
    assert_dns_common_rendering "$config" "$policy_id" "$guard_id"

    run_proxy dns set --mode system-native
    assert_equal 0 "$RUN_STATUS" "system-native DNS set"
    assert_dns_state system-native '' null '' '' '' "system-native DNS normalized state"
    jq -e 'any(.dns.servers[]; . == {type:"local",tag:"proxy-dns"})' "$config" >/dev/null ||
        fail "system-native DNS rendering"

    run_proxy dns set --mode udp --server 1.1.1.1 --port 5353
    assert_equal 0 "$RUN_STATUS" "UDP DNS set"
    assert_dns_state udp 1.1.1.1 5353 '' '' '' "UDP DNS normalized state"
    jq -e 'any(.dns.servers[]; . == {type:"udp",tag:"proxy-dns",server:"1.1.1.1",server_port:5353}) and
        all(.dns.servers[]; .tag != "proxy-dns-bootstrap")' "$config" >/dev/null || fail "UDP DNS rendering"

    run_proxy dns set --mode tcp --server 9.9.9.9
    assert_equal 0 "$RUN_STATUS" "TCP DNS set"
    assert_dns_state tcp 9.9.9.9 53 '' '' '' "TCP DNS normalized state"
    jq -e 'any(.dns.servers[]; . == {type:"tcp",tag:"proxy-dns",server:"9.9.9.9",server_port:53}) and
        all(.dns.servers[]; .tag != "proxy-dns-bootstrap")' "$config" >/dev/null || fail "TCP DNS rendering"

    run_proxy dns set --mode dot --server dns.example --tls-server-name tls.dns.example --bootstrap 8.8.8.8
    assert_equal 0 "$RUN_STATUS" "DoT DNS set"
    assert_dns_state dot dns.example 853 tls.dns.example '' 8.8.8.8 "DoT DNS normalized state"
    jq -e '
        any(.dns.servers[]; . == {type:"tls",tag:"proxy-dns",server:"dns.example",server_port:853,
            tls:{enabled:true,server_name:"tls.dns.example"},domain_resolver:"proxy-dns-bootstrap"}) and
        any(.dns.servers[]; . == {type:"udp",tag:"proxy-dns-bootstrap",server:"8.8.8.8",server_port:53})
    ' "$config" >/dev/null || fail "DoT bootstrap DNS rendering"

    run_proxy dns set --preset cloudflare-doh
    assert_equal 0 "$RUN_STATUS" "Cloudflare DoH preset set"
    assert_dns_state doh 1.1.1.1 443 cloudflare-dns.com /dns-query '' "DoH preset normalized state"
    jq -e '
        any(.dns.servers[]; . == {type:"https",tag:"proxy-dns",server:"1.1.1.1",server_port:443,
            path:"/dns-query",tls:{enabled:true,server_name:"cloudflare-dns.com"}}) and
        all(.dns.servers[]; .tag != "proxy-dns-bootstrap")
    ' "$config" >/dev/null || fail "DoH preset rendering"

    # A hostname upstream without an explicit bootstrap uses the local resolver
    # only for bootstrapping that upstream.
    run_proxy dns set --mode doh --server resolver.example --tls-server-name resolver.example --path /resolve
    assert_equal 0 "$RUN_STATUS" "DoH local bootstrap set"
    assert_dns_state doh resolver.example 443 resolver.example /resolve '' "DoH local bootstrap normalized state"
    jq -e '
        any(.dns.servers[]; .tag == "proxy-dns" and .type == "https" and
            .domain_resolver == "proxy-dns-bootstrap") and
        any(.dns.servers[]; . == {type:"local",tag:"proxy-dns-bootstrap",prefer_go:true})
    ' "$config" >/dev/null || fail "DoH local compatibility bootstrap rendering"

    assert_equal "$nodes_before" "$(jq -Sc .nodes "$(manifest_path)")" "DNS changes altered nodes"
    assert_equal "$relay_before" "$(sha256sum "$(relay_path)" | awk '{print $1}')" "DNS changes altered relay state"
    assert_equal "$xray_before" "$(sha256sum "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json" | awk '{print $1}')" "DNS changes altered Xray config"
    assert_equal sing-box "$(jq -r --arg id "$policy_id" '.nodes[] | select(.id == $id) | .core' "$(manifest_path)")" "DNS changed policy node core"
    assert_equal xray "$(jq -r --arg id "$xray_id" '.nodes[] | select(.id == $id) | .core' "$(manifest_path)")" "DNS changed Xray node core"

    run_proxy node edit --id "$policy_id" --name dns-policy-edited
    assert_equal 0 "$RUN_STATUS" "node edit preserves saved DNS"
    assert_dns_state doh resolver.example 443 resolver.example /resolve '' "node edit altered saved DNS"
    jq -e '.dns.final == "proxy-dns" and
        any(.dns.servers[]; .tag == "proxy-dns" and .server == "resolver.example")' "$config" >/dev/null ||
        fail "node edit dropped rendered DNS"

    run_proxy dns reset
    assert_equal 0 "$RUN_STATUS" "DNS reset"
    jq -e 'getpath(["settings","sing_box","dns"]) == null' "$(manifest_path)" >/dev/null || fail "DNS reset retained saved settings"
    jq -e 'any(.dns.servers[]; . == {type:"local",tag:"proxy-dns",prefer_go:true})' "$config" >/dev/null ||
        fail "DNS reset did not restore effective default"
    run_proxy dns show --json
    assert_equal default "$(jq -r .source <<<"$RUN_OUTPUT")" "DNS reset show source"
}

test_dns_version_boundaries_and_transactions() {
    local manifest_hash config_hash pending binary_backup meta meta_hash binary binary_hash
    reset_root
    install_external sing-box 1.12.0
    run_proxy dns set --mode system
    assert_equal 0 "$RUN_STATUS" "sing-box 1.12 DNS set"
    jq -e 'any(.dns.servers[]; . == {type:"local",tag:"proxy-dns"}) and
        all(.dns.servers[]; has("prefer_go") | not)' "$(dns_config_path)" >/dev/null ||
        fail "sing-box 1.12 must omit prefer_go"
    run_proxy dns set --mode udp --server 1.1.1.1
    assert_equal 0 "$RUN_STATUS" "sing-box 1.12 modern UDP DNS"

    reset_root
    install_external sing-box 1.11.0
    manifest_hash="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    config_hash="$(sha256sum "$(dns_config_path)" | awk '{print $1}')"
    run_proxy dns set --mode system-native
    assert_equal 3 "$RUN_STATUS" "sing-box below 1.12 rejects explicit DNS"
    assert_contains "$RUN_OUTPUT" "1.12" "old sing-box DNS version hint"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "old-version rejection manifest"
    assert_equal "$config_hash" "$(sha256sum "$(dns_config_path)" | awk '{print $1}')" "old-version rejection config"

    reset_root
    install_external sing-box 1.13.0
    run_proxy dns set --mode udp --server 1.1.1.1
    assert_equal 0 "$RUN_STATUS" "DNS transaction baseline"
    manifest_hash="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    config_hash="$(sha256sum "$(dns_config_path)" | awk '{print $1}')"
    meta="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores/sing-box.json"
    binary="${TEST_SYSTEM_ROOT}/usr/bin/sing-box"
    meta_hash="$(sha256sum "$meta" | awk '{print $1}')"
    binary_hash="$(sha256sum "$binary" | awk '{print $1}')"
    set_release_scenario default
    run_proxy update --core sing-box --version v1.11.0 --confirm-external-update
    assert_equal 10 "$RUN_STATUS" "saved DNS blocks sing-box downgrade below 1.12"
    assert_contains "$RUN_OUTPUT" "1.12" "saved DNS downgrade version hint"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "DNS downgrade rejection manifest"
    assert_equal "$config_hash" "$(sha256sum "$(dns_config_path)" | awk '{print $1}')" "DNS downgrade rejection config"
    assert_equal "$meta_hash" "$(sha256sum "$meta" | awk '{print $1}')" "DNS downgrade rejection metadata"
    assert_equal "$binary_hash" "$(sha256sum "$binary" | awk '{print $1}')" "DNS downgrade rejection binary"
    [[ ! -e "$(dns_pending_path)" ]] || fail "DNS downgrade rejection left pending state"

    touch "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    run_proxy dns set --mode tcp --server 9.9.9.9
    assert_equal 10 "$RUN_STATUS" "DNS candidate validation failure"
    rm -f -- "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "DNS validation rollback manifest"
    assert_equal "$config_hash" "$(sha256sum "$(dns_config_path)" | awk '{print $1}')" "DNS validation rollback config"
    [[ ! -e "$(dns_pending_path)" ]] || fail "DNS validation failure left pending state"

    touch "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-sing-box.service"
    touch "${TEST_SYSTEM_ROOT}/run/fail-service-restart-once"
    run_proxy dns set --mode tcp --server 9.9.9.9
    assert_equal 20 "$RUN_STATUS" "active DNS restart failure"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "DNS restart rollback manifest"
    assert_equal "$config_hash" "$(sha256sum "$(dns_config_path)" | awk '{print $1}')" "DNS restart rollback config"
    [[ ! -e "$(dns_pending_path)" ]] || fail "DNS restart failure left pending state"

    rm -f -- "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-sing-box.service"
    set_release_scenario default
    run_proxy update --core sing-box --version v1.13.1 --confirm-external-update
    assert_equal 0 "$RUN_STATUS" "core update pending before DNS change"
    pending="$(dns_pending_path)"
    jq -e '.reason == "core-update"' "$pending" >/dev/null || fail "core update pending reason fixture"
    binary_backup="$(jq -r .binary_backup "$pending")"
    [[ -n "$binary_backup" ]] || fail "core update pending lacks binary backup"

    : >"$MOCK_LOG"
    run_proxy dns set --preset cloudflare-doh
    assert_equal 0 "$RUN_STATUS" "DNS change merges core-update pending"
    jq -e '
        .reason | contains("core-update") and contains("dns-set")
    ' "$pending" >/dev/null || fail "DNS change did not merge pending reasons"
    assert_equal "$binary_backup" "$(jq -r .binary_backup "$pending")" "DNS pending merge lost binary backup"
    assert_not_contains "$(<"$MOCK_LOG")" "restart vpsctl-proxy-sing-box.service" "core update pending must not auto-restart"

    run_proxy restart --core sing-box --confirm-disruptive
    assert_equal 0 "$RUN_STATUS" "apply core update and DNS pending"
    [[ ! -e "$pending" ]] || fail "explicit restart did not clear DNS pending state"
    jq -e '.dns.final == "proxy-dns" and
        any(.dns.servers[]; .tag == "proxy-dns" and .type == "https")' "$(dns_config_path)" >/dev/null ||
        fail "applied pending DNS config"
}

test_dns_uninstall_preserve_and_purge() {
    reset_root
    install_external sing-box 1.13.0
    run_proxy dns set --mode udp --server 1.1.1.1
    assert_equal 0 "$RUN_STATUS" "DNS uninstall fixture"

    run_proxy uninstall --core sing-box
    assert_equal 0 "$RUN_STATUS" "default uninstall preserves DNS"
    assert_dns_state udp 1.1.1.1 53 '' '' '' "default uninstall removed DNS state"
    run_proxy dns show --json
    assert_equal 0 "$RUN_STATUS" "show preserved DNS without installed core"
    jq -e '.installed == false and .source == "saved" and .settings.mode == "udp"' <<<"$RUN_OUTPUT" >/dev/null ||
        fail "preserved DNS show after uninstall"

    install_external sing-box 1.13.0
    run_proxy uninstall --core sing-box --purge --confirm-purge
    assert_equal 0 "$RUN_STATUS" "purge uninstall clears DNS"
    jq -e 'getpath(["settings","sing_box","dns"]) == null' "$(manifest_path)" >/dev/null ||
        fail "purge uninstall retained DNS state"
    [[ ! -e "$(dns_pending_path)" ]] || fail "purge uninstall retained DNS pending state"
}

printf 'TEST: proxy DNS defaults, dry-run and CLI validation\n'
test_dns_cli_defaults_and_validation
printf 'TEST: proxy DNS mode rendering and shared state preservation\n'
test_dns_modes_rendering_and_state_preservation
printf 'TEST: proxy DNS version boundaries and transactions\n'
test_dns_version_boundaries_and_transactions
printf 'TEST: proxy DNS uninstall preservation and purge\n'
test_dns_uninstall_preserve_and_purge
printf 'PASS: service proxy DNS tests\n'
