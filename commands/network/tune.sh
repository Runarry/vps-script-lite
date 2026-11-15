#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/command.sh disable=SC1091
source "$PROJECT_ROOT/lib/command.sh"

tune_main() {
    local skip_dependencies=0
    local -a arguments=() action=() tools=()

    # The Python CLI accepts common flags at every parser level. Respect them
    # before a dependency can be installed, and forward the original options.
    while (($#)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --install-deps) VPSCTL_INSTALL_DEPS=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --no-color) VPSCTL_NO_COLOR=1 ;;
            --json) ;;
            --help | -h) skip_dependencies=1 ;;
            --)
                if ((${#action[@]} == 0)); then shift; fi
                break
                ;;
            -*) if ((${#action[@]} < 2)); then skip_dependencies=1; fi ;;
            *) if ((${#action[@]} < 2)); then action+=("$1"); fi ;;
        esac
        arguments+=("$1")
        shift
    done

    vps_cmd_init 'network tune' "$PROJECT_ROOT" || return $?
    export VPSCTL_DRY_RUN VPSCTL_INSTALL_DEPS VPSCTL_ASSUME_YES VPSCTL_NON_INTERACTIVE
    export VPSCTL_QUIET VPSCTL_VERBOSE VPSCTL_NO_COLOR VPSCTL_TESTING VPSCTL_SYSTEM_ROOT
    export VPSCTL_TUNE_FRONTEND_PATH="$PROJECT_ROOT/commands/network/tune.sh"
    export VPSCTL_TUNE_FRONTEND_KIND=vpsctl

    case "${action[0]:-}:${action[1]:-}" in
        buffer:set | buffer:restore) tools=(python3 sysctl) ;;
        egress:set | egress:clear | egress:restore | egress:adopt) tools=(python3 ip tc systemctl) ;;
        port:set | port:delete) tools=(python3 ip tc nft systemctl) ;;
    esac
    if [[ "$skip_dependencies" == 0 ]] && ((${#tools[@]})) && [[ "$VPSCTL_DRY_RUN" == 1 || ($EUID == 0 && -d /run/systemd/system) ]]; then
        vps_cmd_ensure_tools network-tune "${tools[@]}" || return $?
        if [[ "$VPS_CMD_DEPENDENCIES_PLANNED" == 1 ]]; then
            vps_cmd_info '依赖安装计划已列出。工具就绪后可重新查看完整演练。'
            return 0
        fi
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        vps_cmd_error '网络调优需要 python3，请安装后重试。'
        return 3
    fi
    exec python3 -B "$PROJECT_ROOT/lib/network_tune/__main__.py" "${arguments[@]}" "$@"
}

tune_main "$@"
