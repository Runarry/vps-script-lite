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
            printf '卸载受管入口、current 和分发版本目录；--purge 只额外删除 /var/lib/vpsctl/self/ 元数据。\n'
            printf '使用 --yes、--confirm-uninstall 或 --confirm-purge 任一项授权；--confirm-purge 只能与 --purge 一起使用。\n'
            printf '未预先授权时交互确认一次；非交互未授权返回 3。\n'
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
if [[ "$confirm_uninstall" == 1 || "$confirm_purge" == 1 ]]; then
    # The sourced distribution library consumes this process-local context.
    # shellcheck disable=SC2034
    VPSCTL_ASSUME_YES=1
fi
vps_distribution_self_uninstall "$purge"
