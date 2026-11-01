#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SELF_UPDATE_PROJECT_ROOT="${VPSCTL_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=../../lib/distribution.sh
# shellcheck disable=SC1091
source "${SELF_UPDATE_PROJECT_ROOT}/lib/distribution.sh"

requested_version=""
offline_directory=""
while (($# > 0)); do
    case "$1" in
        --version)
            [[ -z "$requested_version" ]] || { vps_distribution_error '重复指定 --version'; exit 2; }
            (($# >= 2)) || { vps_distribution_error '--version 需要 vX.Y.Z'; exit 2; }
            requested_version="$2"; shift 2
            [[ "$requested_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { vps_distribution_error '版本必须为 vX.Y.Z'; exit 2; }
            requested_version="${requested_version#v}"
            ;;
        --offline-dir)
            if (($# < 2)) || [[ -z "$2" || -n "$offline_directory" ]]; then
                vps_distribution_error '--offline-dir 需要一个本地包目录且不可重复'; exit 2
            fi
            offline_directory="$2"; shift 2
            ;;
        -h | --help)
            printf '用法：vpsctl [--yes] self update [--version vX.Y.Z | --offline-dir 本地包目录]\n'
            exit 0
            ;;
        *) vps_distribution_error "未知 self update 选项：$1"; exit 2 ;;
    esac
done
if [[ -n "$offline_directory" ]]; then
    [[ -z "$requested_version" ]] || { vps_distribution_error '--offline-dir 与 --version 互斥'; exit 2; }
    vps_distribution_require_self_mutation
    vps_distribution_validate_managed_install
    vps_distribution_confirm '确认从本地离线包切换 vpsctl release，成功后删除受管历史版本？'
    vps_offline_validate_package "$offline_directory"
    # The target bootstrap loads its own verified core and command registry.
    exec bash "$VPS_OFFLINE_ROOT/vpsctl.sh" --offline-dir "$VPS_OFFLINE_ROOT" --version
fi
vps_distribution_self_update "$requested_version"
