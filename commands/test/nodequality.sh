#!/usr/bin/env bash
# Global CLI flags are consumed by the sourced command helper library.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

NODEQUALITY_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly NODEQUALITY_PROJECT_ROOT
readonly NODEQUALITY_URL='https://run.NodeQuality.com'

# shellcheck source=../../lib/command.sh
source "${NODEQUALITY_PROJECT_ROOT}/lib/command.sh"
# shellcheck source=../../lib/server-test.sh
source "${NODEQUALITY_PROJECT_ROOT}/lib/server-test.sh"

NODEQUALITY_ARGS=()

nodequality_usage() {
    cat <<'EOF'
运行 NodeQuality 官方最新服务器质量测试。

用法：
  nodequality.sh [global-options]
  nodequality.sh -h|--help

命令会在独立临时目录中通过 HTTPS 下载 https://run.NodeQuality.com，
不作修改且不传参数地运行。需要 Linux 与 root 权限，不支持 --dry-run。
上游的报告上传行为保持不变。

可直接运行脚本时使用的全局选项：
  --install-deps       保留公共选项兼容性（本命令不会自动安装依赖）
  --yes                保留公共选项兼容性
  --non-interactive    不受支持；测试需要交互确认
  --quiet              减少非必要输出
  --verbose            显示详细诊断
  --no-color           禁用 ANSI 颜色
  --dry-run            不受支持，将返回错误
  --                    停止解析全局选项
  -h, --help           显示此帮助（不访问网络）
EOF
}

nodequality_parse_globals() {
    NODEQUALITY_ARGS=()
    while (($# > 0)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --install-deps) VPSCTL_INSTALL_DEPS=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --no-color) VPSCTL_NO_COLOR=1 ;;
            --)
                shift
                NODEQUALITY_ARGS=("$@")
                return 0
                ;;
            *)
                NODEQUALITY_ARGS=("$@")
                return 0
                ;;
        esac
        shift
    done
}

nodequality_main() {
    local init_status

    nodequality_parse_globals "$@"
    if vps_cmd_init "test nodequality" "$NODEQUALITY_PROJECT_ROOT"; then :; else
        init_status=$?
        return "$init_status"
    fi
    set -- "${NODEQUALITY_ARGS[@]}"
    if (($# == 1)) && [[ "$1" == help || "$1" == -h || "$1" == --help ]]; then
        nodequality_usage
        return 0
    fi
    if (($# > 0)); then
        vps_cmd_error "NodeQuality 不接受参数：$1"
        nodequality_usage >&2
        return 2
    fi
    vps_server_test_run nodequality "$NODEQUALITY_URL"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    nodequality_main "$@"
fi
