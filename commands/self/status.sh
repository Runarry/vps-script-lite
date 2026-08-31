#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SELF_STATUS_PROJECT_ROOT="${VPSCTL_PROJECT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
# shellcheck source=../../lib/distribution.sh
# shellcheck disable=SC1091
source "${SELF_STATUS_PROJECT_ROOT}/lib/distribution.sh"

if (($# > 0)); then
    case "$1" in
        -h | --help)
            (($# == 1)) || exit 2
            printf '用法：vpsctl self status\n显示本地分发状态；不会访问网络。\n'
            exit 0
            ;;
        *) vps_distribution_error "self status 不接受参数：$1"; exit 2 ;;
    esac
fi
vps_distribution_self_status
