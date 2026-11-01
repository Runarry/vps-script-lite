#!/usr/bin/env bash
# All runtime checks execute in a new network namespace on host-vps-scripts.
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'
if [[ "${1:-}" != --isolated ]]; then exec unshare -n -- bash "$0" --isolated; fi
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT
# shellcheck source=/dev/null
source "$TEST_ROOT/lib/command.sh"
# shellcheck source=/dev/null
source "$TEST_ROOT/lib/nftables.sh"
VPSCTL_TESTING=1 VPSCTL_DRY_RUN=0 VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1
VPSCTL_SYSTEM_ROOT="$TEST_TMP/root"
mkdir -p "$VPSCTL_SYSTEM_ROOT/run"
vps_cmd_init nftables-library-test "$TEST_ROOT"
vps_nft_init
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
assert_json() { jq -e "$2" <<<"$1" >/dev/null || fail "$3"; }
expect_status() {
    local expected="$1" status=0
    shift
    "$@" || status=$?
    [[ "$status" == "$expected" ]] || fail "expected $expected, got $status: $*"
}
save() {
    jq "$1" <<<"$(vps_nft_state)" >"$TEST_TMP/candidate.json"
    vps_nft_save_state "$TEST_TMP/candidate.json"
}
desired() {
    jq -n --arg owner "$1" --arg port "$2" '[{owner:$owner,kind:"input",family:"ipv4",proto:"tcp",port:$port,source:"any",destination:"any",temporary:false}]' >"$TEST_TMP/desired.json"
}

assert_json "$(vps_nft_state)" '.schema_version==1 and .enabled==false' 'default state'
vps_nft_validate_source '192.0.2.1,2001:db8::/64'
for invalid in '300.1.1.1' '1.2.3.4/33' '2001:::1' '1:2:3:4:5:6:7:8:9' '1.2.3.4;drop' '1.2.3.4,'; do
    expect_status 2 vps_nft_validate_source "$invalid"
done
expect_status 2 vps_nft_validate_port '65536'
expect_status 2 vps_nft_validate_port '90-80'
expect_status 2 vps_nft_validate_source '2001:db8::1' ipv4
desired ssh 22
vps_nft_begin ssh "$TEST_TMP/desired.json"
vps_nft_commit
expect_status 1 vps_nft_is_active
assert_json "$(vps_nft_scope_desired ssh)" '.[0].port=="22"' 'inactive transaction records demand'
desired ssh 2222
vps_nft_begin ssh "$TEST_TMP/desired.json"
vps_nft_rollback
assert_json "$(vps_nft_scope_desired ssh)" '.[0].port=="22"' 'inactive rollback restores demand'

nft add table inet foreign_sentinel
nft 'add chain inet foreign_sentinel input { type filter hook input priority 10; policy accept; }'
save '.enabled=true | .rules=[{id:"source",action:"allow-only",proto:"tcp",port:"443",source:"192.0.2.1,192.0.2.2",family:"both",service:"",comment:"",expires_at:0}] |
 .limits=[{id:"rate",proto:"tcp",port:"443",source:"any",family:"both",service:"",rate:"10/second",burst:5,connections:3},
          {id:"udp",proto:"udp",port:"53",source:"any",family:"both",service:"",rate:"10/second",burst:5,connections:0}]'
vps_nft_apply
vps_nft_is_active
nft list table inet foreign_sentinel >/dev/null || fail 'foreign table lost'
assert_json "$(nft -j list table inet vpsctl_firewall)" 'any(.nftables[];.chain.name=="prerouting" and .chain.prio == -150)' 'pre-DNAT hook'
assert_json "$(nft -j list table inet vpsctl_firewall)" 'any(.nftables[];.chain.name=="input" and .chain.policy=="drop") and any(.nftables[];.chain.name=="forward" and .chain.policy=="accept")' 'chain policies'

# Source membership changes preserve native objects and dynamic meter contents.
handles_before="$(nft -a -j list table inet vpsctl_firewall | jq -cS '[.nftables[] | (.set // .chain // empty) | select(.name|startswith("generation_")|not) | {name,handle}] | sort_by(.name)')"
nft 'add element inet vpsctl_firewall m_cmF0ZQ_4 { 192.0.2.9 timeout 60s }'
save '.rules[0].source="192.0.2.1,192.0.2.3"'
vps_nft_prepare_state "$VPS_NFT_STATE_FILE" "$TEST_TMP/plan"
if grep -v ' generation_' "$TEST_TMP/plan/batch.nft" | grep -Eq 'flush (table|chain)|delete (table|set)|add (chain|rule)'; then fail 'source update rebuilt objects'; fi
vps_nft_apply
handles_after="$(nft -a -j list table inet vpsctl_firewall | jq -cS '[.nftables[] | (.set // .chain // empty) | select(.name|startswith("generation_")|not) | {name,handle}] | sort_by(.name)')"
[[ "$handles_before" == "$handles_after" ]] || fail 'source edit replaced native objects'
nft 'get element inet vpsctl_firewall s_c291cmNl_4 { 192.0.2.1, 192.0.2.3 }' >/dev/null || fail 'source edit lost retained or added member'
if nft 'get element inet vpsctl_firewall s_c291cmNl_4 { 192.0.2.2 }' >/dev/null 2>&1; then fail 'source edit retained removed member'; fi
nft 'get element inet vpsctl_firewall m_cmF0ZQ_4 { 192.0.2.9 }' >/dev/null || fail 'source edit reset meter contents'
save '.logging=true'
vps_nft_apply
assert_json "$(nft -j list set inet vpsctl_firewall m_cmF0ZQ_4)" 'any(.nftables[];.set.elem!=null and (.set.elem|length)>0)' 'meter state retained across chain update'
save '.limits[1].rate="1/hour"'
vps_nft_apply
assert_json "$(nft -j list set inet vpsctl_firewall m_dWRw_4)" 'any(.nftables[];.set.timeout==18000)' 'slow-rate meter retains credits until full burst refill'

# Removing an overlapping subnet retains the separately listed host; ranges
# are canonicalized before nft auto-merge so updates cannot lose authorization.
save '.rules[0].source="192.0.2.0/24,192.0.2.1,2001:db8::/64,2001:db8::1"'
vps_nft_apply
save '.rules[0].source="192.0.2.1,2001:db8::1"'
vps_nft_apply
nft 'get element inet vpsctl_firewall s_c291cmNl_4 { 192.0.2.1 }' >/dev/null || fail 'retained IPv4 host lost after subnet removal'
if nft 'get element inet vpsctl_firewall s_c291cmNl_4 { 192.0.2.2 }' >/dev/null 2>&1; then fail 'removed IPv4 subnet retained'; fi
nft 'get element inet vpsctl_firewall s_c291cmNl_6 { 2001:db8::1 }' >/dev/null || fail 'retained IPv6 host lost after subnet removal'
if nft 'get element inet vpsctl_firewall s_c291cmNl_6 { 2001:db8::2 }' >/dev/null 2>&1; then fail 'removed IPv6 subnet retained'; fi

# Begin must permit both ports until the service switches; commit retires old.
desired ssh 2222
vps_nft_begin ssh "$TEST_TMP/desired.json"
runtime="$(nft list chain inet vpsctl_firewall input)"
[[ "$runtime" == *'dport 22 '* && "$runtime" == *'dport 2222 '* ]] || fail 'prepare did not retain both ports'
vps_nft_commit
runtime="$(nft list chain inet vpsctl_firewall input)"
[[ "$runtime" != *'dport 22 '* && "$runtime" == *'dport 2222 '* ]] || fail 'commit did not retire old port'
desired ssh 3333
vps_nft_begin ssh "$TEST_TMP/desired.json"
desired tcping 4444
vps_nft_begin tcping "$TEST_TMP/desired.json"
vps_nft_commit
vps_nft_rollback
assert_json "$(vps_nft_scope_desired ssh)" '.[0].port=="2222"' 'outer rollback restores original'
assert_json "$(vps_nft_scope_desired tcping)" 'length==0' 'outer rollback restores nested owner'

# Rolling back a child must retain endpoints protected by its outer frame.
desired ssh 3333
vps_nft_begin ssh "$TEST_TMP/desired.json"
desired tcping 4444
vps_nft_begin tcping "$TEST_TMP/desired.json"
vps_nft_rollback
runtime="$(nft list chain inet vpsctl_firewall input)"
[[ "$runtime" == *'dport 2222 '* && "$runtime" == *'dport 3333 '* ]] || fail 'child rollback lost outer prepare endpoints'
vps_nft_rollback

vps_nft_lock
vps_nft_snapshot "$TEST_TMP/snapshot"
vps_nft_unlock
save '.rules[0].expires_at=(now|floor)+60'
vps_nft_apply
expires="$(jq '.rules[0].expires_at' "$VPS_NFT_STATE_FILE")"
sleep 1
save '.revision+=1'
vps_nft_prepare_state "$VPS_NFT_STATE_FILE" "$TEST_TMP/ttl-plan"
[[ ! -s "$TEST_TMP/ttl-plan/batch.nft" ]] || fail 'unchanged TTL was reloaded'
[[ "$(jq '.rules[0].expires_at' "$VPS_NFT_STATE_FILE")" == "$expires" ]] || fail 'absolute TTL changed'
vps_nft_lock
vps_nft_restore "$TEST_TMP/snapshot"
vps_nft_unlock
assert_json "$(vps_nft_state)" '.rules[0].expires_at==0' 'snapshot state restores'
nft list table inet foreign_sentinel >/dev/null || fail 'restore lost foreign table'

# Inject failure AFTER kernel commit, before applied.json publication. Recovery
# must inspect the actual native generation rather than the old cache.
jq '.rules += [{id:"failed-commit",action:"deny",proto:"tcp",port:"5555",source:"any",family:"ipv4",service:"",expires_at:0}]' \
    "$VPS_NFT_STATE_FILE" >"$TEST_TMP/failed-state.json"
vps_nft_prepare_state "$TEST_TMP/failed-state.json" "$TEST_TMP/failed-plan"
nft -c -f "$TEST_TMP/failed-plan/batch.nft"
nft -f "$TEST_TMP/failed-plan/batch.nft"
mv -- "$VPS_NFT_APPLIED_FILE" "$TEST_TMP/old-applied.json"
mkdir -- "$VPS_NFT_APPLIED_FILE"
if vps_nft_commit_prepared "$TEST_TMP/failed-plan" >/dev/null 2>&1; then fail 'metadata failure injection did not fail'; fi
rmdir -- "$VPS_NFT_APPLIED_FILE"
mv -- "$TEST_TMP/old-applied.json" "$VPS_NFT_APPLIED_FILE"
vps_nft_lock
vps_nft_restore "$TEST_TMP/snapshot"
vps_nft_unlock
runtime="$(nft list table inet vpsctl_firewall)"
[[ "$runtime" != *'5555'* ]] || fail 'failed metadata commit left candidate native rules'
assert_json "$(vps_nft_state)" 'all(.rules[];.id!="failed-commit")' 'failed metadata commit restored state'

vps_nft_link_set ssh detached
assert_json "$(vps_nft_inventory)" 'all(.[];.origin!="service" or (.owners|index("ssh"))==null)' 'detach releases service demand'
vps_nft_link_set ssh attached
assert_json "$(vps_nft_inventory)" 'any(.[];.origin=="service" and (.owners|index("ssh"))!=null)' 'attach restores demand'

# Abandoned preparation recovers from the root snapshot on next transaction.
(
    desired ssh 5555
    vps_nft_begin ssh "$TEST_TMP/desired.json"
)
desired tcping 4444
vps_nft_begin tcping "$TEST_TMP/desired.json"
vps_nft_commit
assert_json "$(vps_nft_scope_desired ssh)" '.[0].port=="2222"' 'interrupted prepare recovery'
(
    desired ssh 6666
    vps_nft_begin ssh "$TEST_TMP/desired.json"
)
vps_nft_apply
assert_json "$(vps_nft_scope_desired ssh)" '.[0].port=="2222"' 'ordinary sync recovers interrupted preparation'
vps_nft_clear
expect_status 1 vps_nft_is_active
nft list table inet foreign_sentinel >/dev/null || fail 'clear lost foreign table'
vps_nft_lock
vps_nft_restore "$TEST_TMP/snapshot"
vps_nft_unlock
vps_nft_is_active || fail 'active snapshot could not recreate a cleared private table'
vps_nft_clear
printf 'PASS: native nftables validation, compile, incremental sets, meters, TTL, transactions, recovery and foreign table isolation\n'
