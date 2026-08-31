#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SELF_UNINSTALL_PROJECT_ROOT="${VPSCTL_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=../../lib/distribution.sh
# shellcheck disable=SC1091
source "${SELF_UNINSTALL_PROJECT_ROOT}/lib/distribution.sh"

purge=0
confirm_uninstall=0
confirm_purge=0
while (($# > 0)); do
    case "$1" in
        --purge) purge=1 ;;
        --confirm-uninstall) confirm_uninstall=1 ;;
        --confirm-purge) confirm_purge=1 ;;
        -h | --help)
            printf '用法：vpsctl [--yes] self uninstall [--purge] [--confirm-uninstall] [--confirm-purge]\n'
            exit 0
            ;;
        *) vps_distribution_error "未知 self uninstall 选项：$1"; exit 2 ;;
    esac
    shift
done
if [[ "$confirm_purge" == 1 && "$purge" != 1 ]]; then
    vps_distribution_error '--confirm-purge 只能与 --purge 一起使用'
    exit 2
fi
if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == 1 || ! -t 0 || ! -t 1 ]]; then
    [[ "$confirm_uninstall" == 1 ]] || {
        vps_distribution_error '非交互卸载必须显式使用 --confirm-uninstall'
        exit 3
    }
    [[ "$purge" != 1 || "$confirm_purge" == 1 ]] || {
        vps_distribution_error '非交互 purge 必须显式使用 --confirm-purge'
        exit 3
    }
    VPSCTL_ASSUME_YES=1
else
    # The sourced distribution library consumes this process-local context.
    # shellcheck disable=SC2034
    VPSCTL_ASSUME_YES=0
fi
vps_distribution_self_uninstall "$purge"
