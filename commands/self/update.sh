#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SELF_UPDATE_PROJECT_ROOT="${VPSCTL_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=../../lib/distribution.sh
# shellcheck disable=SC1091
source "${SELF_UPDATE_PROJECT_ROOT}/lib/distribution.sh"

requested_version=""
while (($# > 0)); do
    case "$1" in
        --version)
            (($# >= 2)) || { vps_distribution_error '--version 需要 vX.Y.Z'; exit 2; }
            requested_version="$2"; shift 2
            [[ "$requested_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { vps_distribution_error '版本必须为 vX.Y.Z'; exit 2; }
            requested_version="${requested_version#v}"
            ;;
        -h | --help)
            printf '用法：vpsctl [--yes] self update [--version vX.Y.Z]\n'
            exit 0
            ;;
        *) vps_distribution_error "未知 self update 选项：$1"; exit 2 ;;
    esac
done
vps_distribution_self_update "$requested_version"
