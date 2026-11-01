#!/usr/bin/env bash
# Offline, source-safe entry point for the dedicated boot service and PO0.
# shellcheck disable=SC1091
NFT_RUNTIME_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$NFT_RUNTIME_ROOT/lib/command.sh"
source "$NFT_RUNTIME_ROOT/lib/nftables.sh"

nft_runtime_main() {
    local status=0
    export VPSCTL_NON_INTERACTIVE=1 VPSCTL_INSTALL_DEPS=0
    vps_cmd_init network-nftables "$NFT_RUNTIME_ROOT" || return $?
    vps_nft_init && vps_nft_lock || return $?
    case "${1:-start}" in
        start | reload) vps_nft_apply || status=$? ;;
        stop) vps_nft_clear || status=$? ;;
        *) status=2 ;;
    esac
    vps_nft_unlock || true
    return "$status"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
    IFS=$'\n\t'
    nft_runtime_main "$@"
fi
