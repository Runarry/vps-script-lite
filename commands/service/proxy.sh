#!/usr/bin/env bash

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    printf 'service proxy 需要 Bash 4.4 或更高版本。\n' >&2
    exit 3
fi

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

proxy_project_root() {
    if [[ -n "${VPSCTL_PROJECT_ROOT:-}" ]]; then
        printf '%s' "$VPSCTL_PROJECT_ROOT"
        return 0
    fi
    local script_dir
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    cd -- "${script_dir}/../.." && pwd -P
}

PROXY_PROJECT_ROOT="$(proxy_project_root)"
readonly PROXY_PROJECT_ROOT

# shellcheck source=../../lib/command.sh
source "${PROXY_PROJECT_ROOT}/lib/command.sh"
vps_cmd_init "service proxy" "$PROXY_PROJECT_ROOT" || exit $?

readonly PROXY_MODULE_DIR="${PROXY_PROJECT_ROOT}/commands/service/proxy"

proxy_load_module() {
    local name="$1" path
    path="${PROXY_MODULE_DIR}/${name}"
    [[ "$name" =~ ^[a-z0-9-]+\.sh$ ]] || {
        vps_cmd_error "无效代理模块名称：$name"
        return 2
    }
    [[ -f "$path" && -r "$path" && ! -L "$path" ]] || {
        vps_cmd_error "无法安全读取代理模块：$path"
        return 3
    }
    vps_cmd_require_no_symlink_components "$path" || return $?
    # shellcheck source=/dev/null
    source "$path"
}

proxy_load_module common.sh || exit $?
proxy_load_module protocols-sing-box.sh || exit $?
proxy_load_module protocols-xray.sh || exit $?
proxy_load_module nodes.sh || exit $?
proxy_load_module core.sh || exit $?
proxy_load_module time.sh || exit $?
proxy_common_init || exit $?

PROXY_ARGS=()
PROXY_FORWARD_ARGS=()
PROXY_SELECTED_CORE=""

proxy_usage() {
    cat <<'EOF'
代理管理 - Xray 与 sing-box 平级内核和节点管理

用法：
  vpsctl [global-options] service proxy [action] [options]

核心：
  status [--core CORE|all] [--json]
  install --core CORE|all [--version TAG]
  update [--core CORE|all] [--version TAG] [--confirm-external-update]
  uninstall [--core CORE] [--purge] [--confirm-purge]
  start [--core CORE] [--enable]
  stop [--core CORE] [--disable]
  restart [--core CORE] [--confirm-disruptive]
  logs [--core CORE] [--lines N] [--follow] [--since VALUE]

节点：
  profiles
  node list [--core CORE|all] [--json]
  node show --id NODE_ID [--uri]
  node add --profile PROFILE [--core CORE] [--name NAME] [--port PORT]
           [--listen ADDRESS] [--address CLIENT_ADDRESS] [--sni HOST]
           [--path PATH] [--service-name NAME]
           [--cert-mode self-signed|imported --cert-file FILE --key-file FILE]
           [--obfs none|salamander] [--up-mbps N] [--down-mbps N]
           [--congestion-control bbr|cubic|new_reno]
  node edit --id NODE_ID [可修改 node add 中的非凭据字段]
  node delete --id NODE_ID [--confirm-delete]
  subscription [--core CORE|all]

系统时间：
  time status [--json]
  time sync

CORE 为 sing-box 或 xray。仅安装一个兼容内核时，节点添加和多数核心
操作会自动选中它；存在多个候选时，交互模式会询问，非交互模式必须
显式给出 --core。配置变更只校验并写入，不自动重启正在运行的内核。

全局选项 --dry-run、--yes、--non-interactive、--quiet、--verbose、
--no-color 应放在 service 之前；直接执行本脚本时也可放在 action 之前。
EOF
}

proxy_parse_direct_globals() {
    PROXY_ARGS=()
    while (($#)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --no-color) VPSCTL_NO_COLOR=1 ;;
            -h | --help)
                PROXY_ARGS=(help)
                return 0
                ;;
            --)
                shift
                PROXY_ARGS=("$@")
                return 0
                ;;
            -*)
                vps_cmd_error "未知全局选项：$1"
                return 2
                ;;
            *)
                PROXY_ARGS=("$@")
                return 0
                ;;
        esac
        shift
    done
}

proxy_extract_core() {
    PROXY_SELECTED_CORE=""
    PROXY_FORWARD_ARGS=()
    while (($#)); do
        case "$1" in
            --core)
                (($# >= 2)) || {
                    vps_cmd_error "--core 需要值"
                    return 2
                }
                [[ -z "$PROXY_SELECTED_CORE" ]] || {
                    vps_cmd_error "--core 只能指定一次"
                    return 2
                }
                PROXY_SELECTED_CORE="$2"
                shift 2
                ;;
            *)
                PROXY_FORWARD_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

proxy_prompt_core() {
    local mode="$1" choice index core
    local -a candidates=()
    case "$mode" in
        install)
            candidates=(sing-box xray)
            ;;
        registered)
            while IFS= read -r core; do candidates+=("$core"); done < <(proxy_installed_cores)
            ;;
        *) return 2 ;;
    esac
    ((${#candidates[@]} > 0)) || {
        vps_cmd_error "当前没有已登记代理内核"
        return 3
    }
    if ((${#candidates[@]} == 1)); then
        printf '%s' "${candidates[0]}"
        return 0
    fi
    vps_cmd_is_interactive || {
        vps_cmd_error "存在多个候选内核，请使用 --core sing-box|xray"
        return 2
    }
    printf '请选择内核：\n' >&2
    for ((index = 0; index < ${#candidates[@]}; index++)); do
        printf '  [%d] %s\n' "$((index + 1))" "$(proxy_core_label "${candidates[$index]}")" >&2
    done
    printf '选择：' >&2
    IFS= read -r choice || return 130
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] || return 2
    ((10#$choice <= ${#candidates[@]})) || return 2
    printf '%s' "${candidates[$((10#$choice - 1))]}"
}

proxy_resolve_lifecycle_core() {
    local requested="$1" mode="$2" allow_all="${3:-0}"
    if [[ -n "$requested" ]]; then
        if [[ "$requested" == "all" && "$allow_all" == "1" ]]; then
            printf 'all'
            return 0
        fi
        proxy_core_valid "$requested" || {
            vps_cmd_error "无效内核：$requested"
            return 2
        }
        if [[ "$mode" == "registered" ]] && ! proxy_core_registered "$requested"; then
            vps_cmd_error "内核尚未登记：$requested"
            return 3
        fi
        printf '%s' "$requested"
        return 0
    fi
    proxy_prompt_core "$mode"
}

proxy_run_all() {
    local function_name="$1" core status=0 succeeded=0 failed=0
    shift
    for core in sing-box xray; do
        if "$function_name" "$core" "$@"; then
            succeeded=$((succeeded + 1))
        else
            status=$?
            failed=$((failed + 1))
        fi
    done
    ((failed == 0)) && return 0
    ((succeeded == 0)) && return "$status"
    return 30
}

proxy_run_registered() {
    local function_name="$1" core status=0 succeeded=0 failed=0
    shift
    while IFS= read -r core; do
        [[ -n "$core" ]] || continue
        if "$function_name" "$core" "$@"; then
            succeeded=$((succeeded + 1))
        else
            status=$?
            failed=$((failed + 1))
        fi
    done < <(proxy_installed_cores)
    ((succeeded + failed > 0)) || {
        vps_cmd_error "当前没有已登记代理内核"
        return 3
    }
    ((failed == 0)) && return 0
    ((succeeded == 0)) && return "$status"
    return 30
}

proxy_dispatch_core_action() {
    local action="$1" allow_all=0 mode="registered" core
    shift
    proxy_extract_core "$@" || return $?
    case "$action" in
        install)
            allow_all=1
            mode="install"
            ;;
        update)
            allow_all=1
            ;;
    esac
    core="$(proxy_resolve_lifecycle_core "$PROXY_SELECTED_CORE" "$mode" "$allow_all")" || return $?
    if [[ "$core" == "all" ]]; then
        local forwarded
        for forwarded in "${PROXY_FORWARD_ARGS[@]}"; do
            if [[ "$forwarded" == "--version" ]]; then
                vps_cmd_error "--core all 不能共用一个 --version；请分别为两个内核指定 Release tag"
                return 2
            fi
        done
        if [[ "$action" == "update" ]]; then
            proxy_run_registered "proxy_core_${action}" "${PROXY_FORWARD_ARGS[@]}"
        else
            proxy_run_all "proxy_core_${action}" "${PROXY_FORWARD_ARGS[@]}"
        fi
    else
        "proxy_core_${action}" "$core" "${PROXY_FORWARD_ARGS[@]}"
    fi
}

proxy_pause() {
    local ignored
    printf '\n按 Enter 返回代理菜单...' >&2
    IFS= read -r ignored || true
}

proxy_menu_run() {
    local choice status=0 id
    while true; do
        printf '\n代理管理\n'
        printf '============================================================\n'
        proxy_core_status all || true
        cat <<'EOF'

  [1] 安装内核       [2] 更新内核       [3] 卸载内核
  [4] 启动内核       [5] 停止内核       [6] 重启内核
  [7] 添加节点       [8] 查看节点       [9] 修改节点
 [10] 删除节点      [11] 输出订阅      [12] 查看日志
 [13] 同步系统时间  [14] 支持的协议     [q] 返回
EOF
        printf '请选择：' >&2
        IFS= read -r choice || return "$status"
        case "$choice" in
            1) proxy_dispatch_core_action install || status=$? ;;
            2) proxy_dispatch_core_action update || status=$? ;;
            3) proxy_dispatch_core_action uninstall || status=$? ;;
            4) proxy_dispatch_core_action start || status=$? ;;
            5) proxy_dispatch_core_action stop || status=$? ;;
            6) proxy_dispatch_core_action restart || status=$? ;;
            7) proxy_node_add || status=$? ;;
            8) proxy_node_list || status=$? ;;
            9)
                proxy_node_list || true
                id="$(proxy_prompt_value "要修改的节点 ID" "")" || status=$?
                [[ -z "$id" ]] || proxy_node_edit --id "$id" || status=$?
                ;;
            10) proxy_node_delete || status=$? ;;
            11) proxy_subscription || status=$? ;;
            12) proxy_dispatch_core_action logs || status=$? ;;
            13) proxy_time_sync || status=$? ;;
            14) proxy_profiles_show || status=$? ;;
            q | Q | 0) return "$status" ;;
            *) vps_cmd_warning "菜单选项无效"; continue ;;
        esac
        proxy_pause
    done
}

proxy_dispatch() {
    local action="${1:-}" subaction="${2:-}"
    if [[ -z "$action" ]]; then
        if vps_cmd_is_interactive; then
            proxy_menu_run
        else
            proxy_core_status all
        fi
        return
    fi
    shift
    case "$action" in
        status)
            proxy_extract_core "$@" || return $?
            proxy_core_status "${PROXY_SELECTED_CORE:-all}" "${PROXY_FORWARD_ARGS[@]}"
            ;;
        install | update | uninstall | start | stop | restart | logs)
            proxy_dispatch_core_action "$action" "$@"
            ;;
        profiles)
            (($# == 0)) || { vps_cmd_error "profiles 不接受选项"; return 2; }
            proxy_profiles_show
            ;;
        node)
            (($# >= 1)) || { vps_cmd_error "node 需要 list|show|add|edit|delete"; return 2; }
            subaction="$1"
            shift
            case "$subaction" in
                list) proxy_node_list "$@" ;;
                show) proxy_node_show "$@" ;;
                add) proxy_node_add "$@" ;;
                edit) proxy_node_edit "$@" ;;
                delete) proxy_node_delete "$@" ;;
                *) vps_cmd_error "未知 node 动作：$subaction"; return 2 ;;
            esac
            ;;
        subscription)
            proxy_subscription "$@"
            ;;
        time)
            (($# >= 1)) || { vps_cmd_error "time 需要 status|sync"; return 2; }
            subaction="$1"
            shift
            case "$subaction" in
                status) proxy_time_status "$@" ;;
                sync) proxy_time_sync "$@" ;;
                *) vps_cmd_error "未知 time 动作：$subaction"; return 2 ;;
            esac
            ;;
        help | -h | --help)
            (($# == 0)) || { vps_cmd_error "help 不接受额外参数"; return 2; }
            proxy_usage
            ;;
        *)
            vps_cmd_error "未知代理动作：$action"
            proxy_usage >&2
            return 2
            ;;
    esac
}

proxy_main() {
    local status=0
    trap 'vps_cmd_unlock' EXIT
    proxy_parse_direct_globals "$@" || return $?
    # Direct-mode globals were parsed after vps_cmd_init; normalize them once
    # more so invalid external values cannot leak into helpers.
    vps_cmd_init "service proxy" "$PROXY_PROJECT_ROOT" || return $?
    proxy_common_init || return $?
    proxy_dispatch "${PROXY_ARGS[@]}" || status=$?
    return "$status"
}

proxy_main "$@"
