#!/usr/bin/env bash
# Integration boundaries for proxy configuration, DNS cache, nft and UFW.
# The shared UFW suite owns real rule matching and reference counting.
# shellcheck disable=SC2317 # Sourced proxy functions call the test doubles below.
set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
# shellcheck source=../../lib/ufw.sh
source "$TEST_ROOT/lib/ufw.sh"
# shellcheck source=../../commands/network/ufw/common.sh
source "$TEST_ROOT/commands/network/ufw/common.sh"
# shellcheck source=../../commands/network/ufw/inventory.sh
source "$TEST_ROOT/commands/network/ufw/inventory.sh"
# shellcheck source=../../commands/service/proxy/ufw.sh
source "$TEST_ROOT/commands/service/proxy/ufw.sh"
# shellcheck source=../../commands/service/proxy/relay-forward.sh
source "$TEST_ROOT/commands/service/proxy/relay-forward.sh"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
expect_status() {
    local expected="$1" actual=0
    shift
    "$@" || actual=$?
    [[ "$actual" == "$expected" ]] || fail "expected status $expected, got $actual: $*"
}
expect_same_requirements() {
    local expected="$1" actual
    shift
    actual="$("$@")" || fail "requirement conversion failed: $*"
    jq -e --argjson expected "$expected" 'sort == ($expected | sort)' <<<"$actual" >/dev/null ||
        fail "requirement sets differ: $*"
}
vps_cmd_error() { :; }
vps_cmd_warning() { :; }
vps_cmd_info() { :; }
vps_cmd_success() { :; }
vps_cmd_require_no_symlink_components() { [[ "$1" != *'unsafe'* ]]; }
vps_ufw_init() { :; }
vps_ufw_ipv6_available() { [[ "${TEST_IPV6:-1}" == 1 ]]; }

PROXY_STATE_DIR="$TEST_TMP"
PROXY_MANIFEST="$TEST_TMP/nodes.json"
PROXY_RELAY_FILE="$TEST_TMP/relay.json"
PROXY_RELAY_FORWARD_MANIFEST="$PROXY_RELAY_FILE"
PROXY_RELAY_FORWARD_CACHE="$TEST_TMP/cache.json"
PROXY_RELAY_FORWARD_CACHE_LOGICAL="$PROXY_RELAY_FORWARD_CACHE"
TEST_UFW_CURRENT='[]'
TEST_UFW_STACK=()
VPS_UFW_DEPTH=0
TEST_UFW_FAIL_BEGIN=0
TEST_UFW_FAIL_COMMIT=0
TEST_UFW_FAIL_ROLLBACK=0
TEST_NFT_FAIL=0
TEST_CACHE_FAIL=0
TEST_EVENTS="$TEST_TMP/events"
: >"$TEST_EVENTS"

vps_ufw_begin() {
    printf 'begin:%s\n' "$1" >>"$TEST_EVENTS"
    [[ "$TEST_UFW_FAIL_BEGIN" == 0 ]] || return 20
    TEST_UFW_STACK+=("$TEST_UFW_CURRENT")
    VPS_UFW_DEPTH=${#TEST_UFW_STACK[@]}
    TEST_UFW_CURRENT="$(cat -- "$2")"
}
vps_ufw_commit() {
    local index=$((${#TEST_UFW_STACK[@]} - 1))
    printf 'commit\n' >>"$TEST_EVENTS"
    ((index >= 0)) || return 70
    unset 'TEST_UFW_STACK[index]'
    VPS_UFW_DEPTH=${#TEST_UFW_STACK[@]}
    [[ "$TEST_UFW_FAIL_COMMIT" == 0 ]] || return 30
}
vps_ufw_rollback() {
    local index=$((${#TEST_UFW_STACK[@]} - 1))
    printf 'rollback\n' >>"$TEST_EVENTS"
    ((index >= 0)) || return 70
    TEST_UFW_CURRENT="${TEST_UFW_STACK[index]}"
    unset 'TEST_UFW_STACK[index]'
    VPS_UFW_DEPTH=${#TEST_UFW_STACK[@]}
    [[ "$TEST_UFW_FAIL_ROLLBACK" == 0 ]] || return 30
}

cat >"$PROXY_MANIFEST" <<'EOF'
{"nodes":[
 {"id":"tcp","core":"sing-box","profile":"vless-reality-vision","listen":"::","port":31000,"tls":{"reality_guard":{"enabled":true,"listen_port":11000}}},
 {"id":"udp","core":"sing-box","profile":"hysteria2","listen":"0.0.0.0","port":31001},
 {"id":"tuic","core":"sing-box","profile":"tuic-v5","listen":"203.0.113.7","port":31002},
 {"id":"ss","core":"xray","profile":"shadowsocks-2022","listen":"::","port":31003},
 {"id":"local","core":"xray","profile":"socks5","listen":"127.0.0.1","port":31004},
 {"id":"local6","core":"sing-box","profile":"socks5","listen":"::1","port":31005}
]}
EOF
proxy_ufw_nodes_desired "$PROXY_MANIFEST" >"$TEST_TMP/nodes-desired.json"
jq -e 'length == 8 and all(.[]; .port != "11000" and .port != "31004" and .port != "31005") and
    ([.[] | select(.owner == "node:tcp")] | length == 2 and all(.[]; .proto == "tcp")) and
    ([.[] | select(.owner == "node:ss")] | length == 4) and
    any(.[]; .owner == "node:tuic" and .proto == "udp" and .destination == "203.0.113.7")' \
    "$TEST_TMP/nodes-desired.json" >/dev/null || fail 'node protocols, families, destinations or guard exclusion'
expect_same_requirements "$(<"$TEST_TMP/nodes-desired.json")" ufw_cli_nodes_desired "$PROXY_MANIFEST"
TEST_IPV6=0 proxy_ufw_nodes_desired "$PROXY_MANIFEST" >"$TEST_TMP/ipv4.json"
jq -e 'length == 5 and all(.[]; .family == "ipv4")' "$TEST_TMP/ipv4.json" >/dev/null || fail 'IPv6-disabled dual listener'
TEST_IPV6=0 expect_same_requirements "$(<"$TEST_TMP/ipv4.json")" ufw_cli_nodes_desired "$PROXY_MANIFEST"
printf '{"nodes":[{"id":"v6","profile":"socks5","listen":"2001:db8::7","port":31000}]}' >"$TEST_TMP/ipv6.json"
TEST_IPV6=0 proxy_ufw_nodes_desired "$TEST_TMP/ipv6.json" >"$TEST_TMP/explicit-ipv6.json"
jq -e 'length == 1 and .[0].family == "ipv6"' "$TEST_TMP/explicit-ipv6.json" >/dev/null || fail 'inactive UFW must retain explicit IPv6 demand'
TEST_IPV6=0 expect_same_requirements "$(<"$TEST_TMP/explicit-ipv6.json")" ufw_cli_nodes_desired "$TEST_TMP/ipv6.json"

for profile in shadowsocks-aes-256-gcm shadowsocks-chacha20-poly1305 shadowsocks-2022 shadowsocks-2022-padding; do
    jq --arg profile "$profile" '.nodes=[.nodes[3] | .profile=$profile]' "$PROXY_MANIFEST" >"$TEST_TMP/profile.json"
    result="$(proxy_ufw_nodes_desired "$TEST_TMP/profile.json")"
    jq -e 'length == 4 and ([.[].proto] | unique) == ["tcp","udp"]' <<<"$result" >/dev/null || fail "$profile protocol mapping"
    expect_same_requirements "$result" ufw_cli_nodes_desired "$TEST_TMP/profile.json"
done

# Entry-specific defaults and validation remain outside the shared converter.
printf '{"nodes":[{"id":"defaults","profile":"socks5","listen":"","port":31000}]}' >"$TEST_TMP/defaults.json"
result="$(ufw_cli_nodes_desired "$TEST_TMP/defaults.json")"
jq -e 'length == 2 and all(.[]; .destination == "any")' <<<"$result" >/dev/null || fail 'global empty listener default changed'
result="$(proxy_ufw_nodes_desired "$TEST_TMP/defaults.json")"
jq -e 'length == 1 and .[0].family == "ipv4" and .[0].destination == ""' <<<"$result" >/dev/null || fail 'proxy empty listener default changed'
jq 'del(.nodes[].listen)' "$TEST_TMP/defaults.json" >"$TEST_TMP/no-listen.json"
expect_status 10 ufw_cli_nodes_desired "$TEST_TMP/no-listen.json"
result="$(proxy_ufw_nodes_desired "$TEST_TMP/no-listen.json")"
jq -e 'length == 2 and all(.[]; .destination == "any")' <<<"$result" >/dev/null || fail 'proxy missing listener default changed'
for field in '.nodes[0].port=65536' '.nodes[0].listen="not-an-ip"' '.nodes[0].id="invalid id"' 'del(.nodes[0].profile)'; do
    jq "$field" "$TEST_TMP/ipv6.json" >"$TEST_TMP/invalid-node.json"
    expect_status 10 ufw_cli_nodes_desired "$TEST_TMP/invalid-node.json"
done
jq '.nodes |= map(.core="xray")' "$PROXY_MANIFEST" >"$TEST_TMP/switched.json"
proxy_ufw_nodes_desired "$TEST_TMP/switched.json" >"$TEST_TMP/switched-desired.json"
cmp -s "$TEST_TMP/nodes-desired.json" "$TEST_TMP/switched-desired.json" || fail 'core switch changed firewall ownership'

proxy_ufw_nodes_sync
node_original="$TEST_UFW_CURRENT"
jq '(.nodes[] | select(.id == "tcp")).port=32000' "$PROXY_MANIFEST" >"$TEST_TMP/candidate.json"
test_write_nodes() {
    printf 'business\n' >>"$TEST_EVENTS"
    cp "$TEST_TMP/candidate.json" "$PROXY_MANIFEST"
}
test_reject_nodes() {
    printf 'business-failed\n' >>"$TEST_EVENTS"
    return 20
}
: >"$TEST_EVENTS"
TEST_UFW_FAIL_BEGIN=1
expect_status 20 proxy_ufw_nodes_transaction "$TEST_TMP/candidate.json" test_write_nodes
TEST_UFW_FAIL_BEGIN=0
[[ "$(cat "$TEST_EVENTS")" == 'begin:proxy-nodes' ]] || fail 'UFW addition failure ran node business mutation'
expect_status 20 proxy_ufw_nodes_transaction "$TEST_TMP/candidate.json" test_reject_nodes
[[ "$TEST_UFW_CURRENT" == "$node_original" ]] || fail 'failed node mutation did not restore UFW'
TEST_UFW_FAIL_COMMIT=1
expect_status 30 proxy_ufw_nodes_transaction "$TEST_TMP/candidate.json" test_write_nodes
TEST_UFW_FAIL_COMMIT=0
jq -e 'any(.[]; .port == "32000") and all(.[]; .port != "31000")' <<<"$TEST_UFW_CURRENT" >/dev/null || fail 'cleanup failure removed committed node demand'
jq -e 'any(.nodes[]; .port == 32000)' "$PROXY_MANIFEST" >/dev/null || fail 'cleanup failure rolled back committed node'
[[ "${#TEST_UFW_STACK[@]}" == 0 ]] || fail 'node transaction frame leaked'

cat >"$PROXY_RELAY_FILE" <<'EOF'
{"exits":[{"id":"exit-one","endpoint":{"host":"exit.example","port":443},"network_hint":"both"}],
 "forwards":[{"id":"range","exit_id":"exit-one","network":"auto","family":"dual","listen_port_start":35000,"listen_port_end":35020},
             {"id":"udp-only","exit_id":"exit-one","network":"udp","family":"ipv4","listen_port_start":36000,"listen_port_end":36000}]}
EOF
printf '{"exits":{"exit-one":{"host":"exit.example","ipv4":"198.51.100.10","ipv6":"2001:db8::10"}}}' >"$PROXY_RELAY_FORWARD_CACHE"
proxy_ufw_forwards_desired "$PROXY_RELAY_FILE" "$PROXY_RELAY_FORWARD_CACHE" >"$TEST_TMP/routes.json"
jq -e 'length == 5 and all(.[]; .kind == "route" and .port == "443") and
    ([.[] | select(.owner == "forward:range")] | length == 4) and
    any(.[]; .owner == "forward:udp-only" and .family == "ipv4" and .proto == "udp")' \
    "$TEST_TMP/routes.json" >/dev/null || fail 'DNAT needs route target port, not input range'
expect_same_requirements "$(<"$TEST_TMP/routes.json")" ufw_cli_forwards_desired "$PROXY_RELAY_FILE" "$PROXY_RELAY_FORWARD_CACHE"
jq '.exits["exit-one"].host="stale.example"' "$PROXY_RELAY_FORWARD_CACHE" >"$TEST_TMP/stale.json"
expect_status 10 proxy_ufw_forwards_desired "$PROXY_RELAY_FILE" "$TEST_TMP/stale.json"
expect_status 3 ufw_cli_forwards_desired "$PROXY_RELAY_FILE" "$TEST_TMP/stale.json"
expect_status 10 proxy_ufw_forwards_desired "$PROXY_RELAY_FILE" "$TEST_TMP/missing-cache.json"
printf '{"exits":{"exit-one":{"host":"exit.example"}}}' >"$TEST_TMP/unresolved.json"
expect_status 10 proxy_ufw_forwards_desired "$PROXY_RELAY_FILE" "$TEST_TMP/unresolved.json"
expect_status 3 ufw_cli_forwards_desired "$PROXY_RELAY_FILE" "$TEST_TMP/unresolved.json"
jq '.forwards=[.forwards[0] | .family="ipv6"]' "$PROXY_RELAY_FILE" >"$TEST_TMP/family.json"
result="$(proxy_ufw_forwards_desired "$TEST_TMP/family.json" "$PROXY_RELAY_FORWARD_CACHE")"
jq -e 'length == 2 and all(.[]; .family == "ipv6" and .destination == "2001:db8::10")' <<<"$result" >/dev/null || fail 'explicit IPv6 forward destination'
expect_same_requirements "$result" ufw_cli_forwards_desired "$TEST_TMP/family.json" "$PROXY_RELAY_FORWARD_CACHE"
jq 'del(.exits["exit-one"].ipv6)' "$PROXY_RELAY_FORWARD_CACHE" >"$TEST_TMP/ipv4-cache.json"
expect_status 10 proxy_ufw_forwards_desired "$TEST_TMP/family.json" "$TEST_TMP/ipv4-cache.json"
expect_status 3 ufw_cli_forwards_desired "$TEST_TMP/family.json" "$TEST_TMP/ipv4-cache.json"
result="$(proxy_ufw_forwards_desired "$PROXY_RELAY_FILE" "$TEST_TMP/ipv4-cache.json")"
jq -e 'length == 3 and all(.[]; .family == "ipv4")' <<<"$result" >/dev/null || fail 'dual forward lost available family'
expect_same_requirements "$result" ufw_cli_forwards_desired "$PROXY_RELAY_FILE" "$TEST_TMP/ipv4-cache.json"
for field in '.forwards[0].network="invalid"' '.forwards[0].family="invalid"' '.exits=[]'; do
    jq "$field" "$PROXY_RELAY_FILE" >"$TEST_TMP/invalid-forward.json"
    expect_status 10 proxy_ufw_forwards_desired "$TEST_TMP/invalid-forward.json" "$PROXY_RELAY_FORWARD_CACHE"
    expect_status 10 ufw_cli_forwards_desired "$TEST_TMP/invalid-forward.json" "$PROXY_RELAY_FORWARD_CACHE"
done
jq 'del(.forwards[].family)' "$PROXY_RELAY_FILE" >"$TEST_TMP/default-family.json"
result="$(proxy_ufw_forwards_desired "$TEST_TMP/default-family.json" "$PROXY_RELAY_FORWARD_CACHE")"
expect_same_requirements "$result" ufw_cli_forwards_desired "$TEST_TMP/default-family.json" "$PROXY_RELAY_FORWARD_CACHE"
jq 'del(.forwards[].network)' "$TEST_TMP/default-family.json" >"$TEST_TMP/default-network.json"
expect_status 10 proxy_ufw_forwards_desired "$TEST_TMP/default-network.json" "$PROXY_RELAY_FORWARD_CACHE"
result="$(ufw_cli_forwards_desired "$TEST_TMP/default-network.json" "$PROXY_RELAY_FORWARD_CACHE")"
jq -e 'length == 8 and all(.[]; .port == "443")' <<<"$result" >/dev/null || fail 'global missing network default changed'

# Exercise the real apply function with observable filesystem/nft boundaries.
# shellcheck disable=SC2317
proxy_relay_forward_init() { :; }
vps_cmd_require_root() { :; }
proxy_ensure_mutation_tools() { :; }
proxy_stop_after_dependency_plan() { return 1; }
_proxy_relay_forward_require_safe_paths() { :; }
proxy_relay_forward_manifest_validate() { :; }
proxy_relay_forward_detect_loops() { :; }
_proxy_relay_forward_warn_external_policy() { :; }
proxy_relay_forward_refresh_cache() { cp "$TEST_TMP/cache.next.json" "$3"; }
proxy_relay_forward_nft_snapshot() { cp "$TEST_TMP/runtime.nft" "$1"; }
proxy_relay_forward_render_nft() { cat "$2"; }
proxy_relay_forward_nft_check() { printf 'nft-check\n' >>"$TEST_EVENTS"; }
proxy_relay_forward_nft_apply() {
    printf 'nft-apply\n' >>"$TEST_EVENTS"
    jq -e 'any(.[]; .destination == "198.51.100.20")' <<<"$TEST_UFW_CURRENT" >/dev/null || return 71
    [[ "$TEST_NFT_FAIL" == 0 ]] || return 20
    cp "$1" "$TEST_TMP/runtime.nft"
}
proxy_relay_forward_nft_restore() {
    printf 'nft-restore\n' >>"$TEST_EVENTS"
    cp "$1" "$TEST_TMP/runtime.nft"
}
proxy_relay_forward_nft_clear() {
    printf 'nft-clear\n' >>"$TEST_EVENTS"
    : >"$TEST_TMP/runtime.nft"
}
proxy_atomic_write_from_file() {
    printf 'cache-write\n' >>"$TEST_EVENTS"
    if [[ "$TEST_CACHE_FAIL" == 1 ]]; then
        TEST_CACHE_FAIL=0
        return 20
    fi
    cp "$1" "$2"
}
cp "$PROXY_RELAY_FORWARD_CACHE" "$TEST_TMP/cache.old.json"
jq '.exits["exit-one"].ipv4="198.51.100.20"' "$PROXY_RELAY_FORWARD_CACHE" >"$TEST_TMP/cache.next.json"
printf 'original nft snapshot\n' >"$TEST_TMP/runtime.nft"
cp "$TEST_TMP/runtime.nft" "$TEST_TMP/runtime.old.nft"
TEST_UFW_CURRENT="$(cat "$TEST_TMP/routes.json")"
forward_original="$TEST_UFW_CURRENT"

: >"$TEST_EVENTS"
TEST_UFW_FAIL_BEGIN=1
expect_status 20 proxy_relay_forward_apply
TEST_UFW_FAIL_BEGIN=0
[[ "$(cat "$TEST_EVENTS")" == $'nft-check\nbegin:proxy-forwards' ]] || fail 'UFW failure reached nft apply'
cmp -s "$TEST_TMP/cache.old.json" "$PROXY_RELAY_FORWARD_CACHE" || fail 'UFW begin failure changed DNS cache'

: >"$TEST_EVENTS"
TEST_NFT_FAIL=1
expect_status 20 proxy_relay_forward_apply
TEST_NFT_FAIL=0
[[ "$TEST_UFW_CURRENT" == "$forward_original" ]] || fail 'nft rejection retained new firewall target'
[[ "$(cat "$TEST_EVENTS")" == $'nft-check\nbegin:proxy-forwards\nnft-apply\nrollback' ]] || fail 'nft failure rollback order'

: >"$TEST_EVENTS"
TEST_CACHE_FAIL=1
expect_status 20 proxy_relay_forward_apply
[[ "$TEST_UFW_CURRENT" == "$forward_original" ]] || fail 'cache write rejection retained new target'
cmp -s "$TEST_TMP/cache.old.json" "$PROXY_RELAY_FORWARD_CACHE" || fail 'cache failure did not restore cache'
cmp -s "$TEST_TMP/runtime.old.nft" "$TEST_TMP/runtime.nft" || fail 'cache failure did not restore nft'
[[ "$(cat "$TEST_EVENTS")" == $'nft-check\nbegin:proxy-forwards\nnft-apply\ncache-write\nnft-restore\ncache-write\nrollback' ]] || fail 'cache rollback order'

: >"$TEST_EVENTS"
proxy_relay_forward_apply
[[ "$(cat "$TEST_EVENTS")" == $'nft-check\nbegin:proxy-forwards\nnft-apply\ncache-write\ncommit' ]] || fail 'new target must be allowed before DNAT switch'
cmp -s "$TEST_TMP/cache.next.json" "$PROXY_RELAY_FORWARD_CACHE" || fail 'successful refresh cache'
jq -e 'any(.[]; .destination == "198.51.100.20") and all(.[]; .destination != "198.51.100.10")' \
    <<<"$TEST_UFW_CURRENT" >/dev/null || fail 'successful refresh target replacement'
[[ "${#TEST_UFW_STACK[@]}" == 0 ]] || fail 'forward frame leaked'

test_nested_forward_apply() { proxy_relay_forward_apply; }
proxy_ufw_relay_transaction test_nested_forward_apply
jq -e 'length == 5' <<<"$TEST_UFW_CURRENT" >/dev/null || fail 'outer commit lost nested forward declarations'
[[ "${#TEST_UFW_STACK[@]}" == 0 ]] || fail 'outer forward frame leaked'

# A failed auto-apply can restore its files inside an existing node frame, which
# is itself nested inside a relay frame. Clearing pending must wait for every
# outer rollback/resync; an outer UFW failure must leave recovery retryable.
TEST_PENDING_FILE="$TEST_TMP/pending-xray.json"
cp "$PROXY_MANIFEST" "$TEST_TMP/restored-nodes.json"
jq '(.nodes[] | select(.id == "tcp")).port=33000' "$PROXY_MANIFEST" >"$TEST_TMP/pending-candidate.json"
proxy_core_pending_path() { printf '%s' "$TEST_PENDING_FILE"; }
proxy_prepare_pending_restore() {
    cp "$TEST_TMP/restored-nodes.json" "$2/nodes.json"
    [[ "$TEST_PENDING_RUNTIME" == 0 ]] || cp "$PROXY_RELAY_FORWARD_CACHE" "$2/cache.json"
}
_proxy_restore_pending() {
    printf 'pending-files-restored\n' >>"$TEST_EVENTS"
    cp "$2/nodes.json" "$PROXY_MANIFEST"
    [[ "$TEST_PENDING_RUNTIME" == 0 ]] || proxy_ufw_forwards_sync_cached
}
proxy_clear_pending() {
    [[ "$VPS_UFW_DEPTH" == 0 && "${PROXY_UFW_TRANSACTION_DEPTH:-0}" -le 1 ]] || fail 'pending cleared inside unfinished UFW frame'
    printf 'pending-clear:%s\n' "$1" >>"$TEST_EVENTS"
    rm -f -- "$TEST_PENDING_FILE"
}
test_pending_outer_fault() {
    case "$TEST_PENDING_FAULT" in
        rollback) TEST_UFW_FAIL_ROLLBACK=1 ;;
        resync) TEST_UFW_FAIL_COMMIT=1 ;;
    esac
}
test_pending_autoapply_failure() {
    cp "$TEST_TMP/pending-candidate.json" "$PROXY_MANIFEST"
    proxy_ufw_restore_pending xray || return $?
    [[ -f "$TEST_PENDING_FILE" && "$PROXY_UFW_PENDING_RESTORE_CORE" == xray ]] || fail 'inner restore cleared pending before outer cleanup'
    [[ "$TEST_PENDING_WRAPPER" == relay ]] || test_pending_outer_fault
    return 20
}
test_pending_relay_autoapply_failure() {
    expect_status 20 proxy_ufw_nodes_transaction "$TEST_TMP/pending-candidate.json" test_pending_autoapply_failure
    [[ -f "$TEST_PENDING_FILE" ]] || fail 'node frame cleared pending before outer relay cleanup'
    test_pending_outer_fault
    return 20
}
for TEST_PENDING_WRAPPER in node relay; do
    for TEST_PENDING_FAULT in none rollback resync; do
        printf 'TEST: nested pending restore wrapper=%s outer-fault=%s\n' "$TEST_PENDING_WRAPPER" "$TEST_PENDING_FAULT"
        TEST_UFW_STACK=(); VPS_UFW_DEPTH=0
        TEST_UFW_FAIL_ROLLBACK=0; TEST_UFW_FAIL_COMMIT=0
        PROXY_UFW_PENDING_RESTORE_CORE=''
        TEST_PENDING_RUNTIME=0; [[ "$TEST_PENDING_WRAPPER" != relay ]] || TEST_PENDING_RUNTIME=1
        cp "$TEST_TMP/restored-nodes.json" "$PROXY_MANIFEST"
        printf '{}\n' >"$TEST_PENDING_FILE"
        : >"$TEST_EVENTS"
        expected=20; [[ "$TEST_PENDING_FAULT" == none ]] || expected=30
        if [[ "$TEST_PENDING_WRAPPER" == node ]]; then
            expect_status "$expected" proxy_ufw_nodes_transaction "$TEST_TMP/pending-candidate.json" test_pending_autoapply_failure
        else
            expect_status "$expected" proxy_ufw_relay_transaction test_pending_relay_autoapply_failure
        fi
        [[ "$VPS_UFW_DEPTH" == 0 && "${#TEST_UFW_STACK[@]}" == 0 ]] || fail 'nested pending test leaked UFW frame'
        if [[ "$TEST_PENDING_FAULT" == none ]]; then
            [[ ! -e "$TEST_PENDING_FILE" && -z "$PROXY_UFW_PENDING_RESTORE_CORE" ]] || fail 'completed outer cleanup did not clear pending'
            [[ "$(tail -n 1 "$TEST_EVENTS")" == pending-clear:xray ]] || fail 'pending cleared before final outer resync'
        else
            [[ -f "$TEST_PENDING_FILE" && "$PROXY_UFW_PENDING_RESTORE_CORE" == xray ]] || fail 'failed outer cleanup consumed retryable pending'
            ! grep -Fq pending-clear "$TEST_EVENTS" || fail 'failed outer cleanup cleared pending'
        fi
    done
done

printf 'PASS: proxy UFW declarations and transaction boundaries\n'
