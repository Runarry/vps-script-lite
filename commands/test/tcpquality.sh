#!/usr/bin/env bash
# Global CLI flags are consumed by the sourced command helper library.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

TCPQUALITY_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TCPQUALITY_PROJECT_ROOT
readonly TCPQUALITY_URL='https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh'

# shellcheck source=../../lib/command.sh
source "${TCPQUALITY_PROJECT_ROOT}/lib/command.sh"
# shellcheck source=../../lib/server-test.sh
source "${TCPQUALITY_PROJECT_ROOT}/lib/server-test.sh"

TCPQUALITY_ARGS=()

tcpquality_usage() {
    cat <<'EOF'
运行 TcpQuality 官方最新 TCP 质量测试。

用法：
  tcpquality.sh [global-options]
  tcpquality.sh -h|--help

命令会在独立临时目录中通过 HTTPS 下载 TcpQuality 官方最新脚本，
不作修改且不传参数地运行。需要 Linux 与 root 权限，不支持 --dry-run。
上游自己的交互选项和报告上传行为保持不变。

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

tcpquality_parse_globals() {
    TCPQUALITY_ARGS=()
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
                TCPQUALITY_ARGS=("$@")
                return 0
                ;;
            *)
                TCPQUALITY_ARGS=("$@")
                return 0
                ;;
        esac
        shift
    done
}

tcpquality_main() {
    local init_status

    tcpquality_parse_globals "$@"
    if vps_cmd_init "test tcpquality" "$TCPQUALITY_PROJECT_ROOT"; then :; else
        init_status=$?
        return "$init_status"
    fi
    set -- "${TCPQUALITY_ARGS[@]}"
    if (($# == 1)) && [[ "$1" == help || "$1" == -h || "$1" == --help ]]; then
        tcpquality_usage
        return 0
    fi
    if (($# > 0)); then
        vps_cmd_error "TcpQuality 不接受参数：$1"
        tcpquality_usage >&2
        return 2
    fi
    vps_server_test_run tcpquality "$TCPQUALITY_URL"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    tcpquality_main "$@"
fi
