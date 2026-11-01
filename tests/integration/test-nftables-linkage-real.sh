#!/usr/bin/env bash
# Real shared-owner transactions, run only inside the isolated parent netns.
# shellcheck disable=SC1091,SC2016
set -Eeuo pipefail
IFS=$'\n\t'
[[ "${VPSCTL_NFT_LINKAGE_CHILD:-0}" == 1 ]] || { echo 'SKIP: run through test-network-nftables-real.sh'; exit 0; }
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
result="$1" cns="$2"
source "$TEST_ROOT/lib/command.sh"
source "$TEST_ROOT/lib/nftables.sh"
vps_cmd_init nft-linkage-real "$TEST_ROOT"
vps_nft_init
probe() { ip netns exec "$cns" python3 "$result/probe.py" tcp 10.203.1.1 41006 10.203.1.2 "$1"; }
jq -n '["shared-a","shared-b"] | map({owner:.,kind:"input",family:"ipv4",proto:"tcp",port:"41006",source:"any",destination:"any",temporary:false})' >"$result/shared-both.json"
jq '[.[]|select(.owner=="shared-b")]' "$result/shared-both.json" >"$result/shared-one.json"
printf '[]\n' >"$result/shared-none.json"
probe block
vps_nft_begin shared-accept "$result/shared-both.json"
probe allow
vps_nft_commit
vps_nft_inventory | jq -e 'any(.[];.port=="41006" and .owners==["shared-a","shared-b"])' >/dev/null
vps_nft_begin shared-accept "$result/shared-one.json"; vps_nft_commit
probe allow
vps_nft_begin shared-accept "$result/shared-none.json"
probe allow
vps_nft_commit
probe block
vps_nft_begin shared-accept "$result/shared-both.json"
probe allow
vps_nft_rollback
probe block
[[ ! -e "$VPS_NFT_JOURNAL" ]]
vps_nft_begin shared-accept "$result/shared-both.json"; vps_nft_commit
vps_nft_link_set shared-a detached
probe allow
vps_nft_link_set shared-b detached
probe block
vps_nft_link_set shared-a attached
probe allow
vps_nft_begin shared-accept "$result/shared-none.json"; vps_nft_commit
probe block
echo 'PASS: real shared-owner prepare/commit/rollback and detach/attach retain exactly the required listener'
