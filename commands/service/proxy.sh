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
PROXY_ALL_CUSTOM_VERSIONS=0
PROXY_ALL_SING_BOX_TAG=""
PROXY_ALL_XRAY_TAG=""
PROXY_INTERACTIVE=0

proxy_usage() {
    cat <<'EOF'
代理管理 - Xray 与 sing-box 平级内核和节点管理

用法：
  vpsctl [global-options] service proxy [action] [options]

核心：
  status [--core CORE|all] [--json]
  install [--version TAG]
  update [--version TAG] [--confirm-external-update]
  uninstall [--purge] [--confirm-purge]
  start [--enable]
  stop [--disable]
  restart [--confirm-disruptive]
  logs [--lines N] [--follow] [--since VALUE]

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

交互模式会根据操作和当前状态自动选择内核，存在多个候选时提供编号
选择。配置变更只校验并写入，不自动重启正在运行的内核。

高级脚本用法：CORE 为 sing-box 或 xray；生命周期操作可显式传入
--core CORE，install/update 还支持 --core all。非交互模式存在多个候选
时必须显式指定 --core。

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

proxy_lifecycle_candidates() {
    local action="$1" filtered="${2:-0}" core
    for core in sing-box xray; do
        case "$action" in
            install)
                if [[ "$filtered" == "1" ]]; then
                    proxy_core_registered "$core" || printf '%s\n' "$core"
                else
                    printf '%s\n' "$core"
                fi
                ;;
            update | uninstall | logs)
                proxy_core_registered "$core" && printf '%s\n' "$core"
                ;;
            start)
                if proxy_core_registered "$core"; then
                    if [[ "$filtered" == "1" ]]; then
                        proxy_service_is_active "$core" || printf '%s\n' "$core"
                    else
                        printf '%s\n' "$core"
                    fi
                fi
                ;;
            stop | restart)
                if proxy_core_registered "$core"; then
                    if [[ "$filtered" == "1" ]]; then
                        proxy_service_is_active "$core" && printf '%s\n' "$core"
                    else
                        printf '%s\n' "$core"
                    fi
                fi
                ;;
            *) return 2 ;;
        esac
    done
}

proxy_no_lifecycle_candidates() {
    case "$1" in
        install) vps_cmd_error "所有支持的代理内核均已登记；可在高级用法中显式指定 --core" ;;
        start) vps_cmd_error "没有已登记且尚未运行的代理内核" ;;
        stop | restart) vps_cmd_error "没有正在运行的已登记代理内核" ;;
        *) vps_cmd_error "当前没有已登记代理内核" ;;
    esac
    return 3
}

proxy_prompt_core() {
    local action="$1" core label
    local -a candidates=()
    while IFS= read -r core; do
        [[ -n "$core" ]] && candidates+=("$core")
    done < <(proxy_lifecycle_candidates "$action" 1)
    ((${#candidates[@]} > 0)) || proxy_no_lifecycle_candidates "$action" || return $?
    if ((${#candidates[@]} == 1)); then
        printf '%s' "${candidates[0]}"
        return 0
    fi
    proxy_is_interactive || {
        vps_cmd_error "存在多个候选内核，请使用 --core sing-box|xray"
        return 2
    }
    local -a choices=()
    for core in "${candidates[@]}"; do
        label="$(proxy_core_label "$core")"
        choices+=("$core" "$label")
    done
    if [[ "$action" == "install" || "$action" == "update" ]]; then
        choices+=(all "全部候选内核")
    fi
    proxy_prompt_select "请选择要执行 ${action} 的内核：" "" "${choices[@]}"
}

proxy_resolve_lifecycle_core() {
    local requested="$1" action="$2" allow_all="${3:-0}" mode="registered"
    if [[ -n "$requested" ]]; then
        if [[ "$requested" == "all" && "$allow_all" == "1" ]]; then
            printf 'all'
            return 0
        fi
        proxy_core_valid "$requested" || {
            vps_cmd_error "无效内核：$requested"
            return 2
        }
        [[ "$action" == "install" ]] && mode="install"
        if [[ "$mode" == "registered" ]] && ! proxy_core_registered "$requested"; then
            vps_cmd_error "内核尚未登记：$requested"
            return 3
        fi
        printf '%s' "$requested"
        return 0
    fi
    if proxy_is_interactive; then
        proxy_prompt_core "$action"
        return
    fi
    local -a candidates=()
    local core
    while IFS= read -r core; do
        [[ -n "$core" ]] && candidates+=("$core")
    done < <(proxy_lifecycle_candidates "$action" 1)
    ((${#candidates[@]} > 0)) || proxy_no_lifecycle_candidates "$action" || return $?
    if ((${#candidates[@]} == 1)); then
        printf '%s' "${candidates[0]}"
        return 0
    fi
    vps_cmd_error "存在多个候选内核，请使用 --core sing-box|xray$( [[ "$allow_all" == "1" ]] && printf '|all' )"
    return 2
}

proxy_forward_has_option() {
    local expected="$1" arg
    for arg in "${PROXY_FORWARD_ARGS[@]}"; do
        [[ "$arg" == "$expected" ]] && return 0
    done
    return 1
}

proxy_prompt_release_options() {
    local action="$1" core="${2:-sing-box}" mode tag label candidate
    proxy_forward_has_option --version && return 0
    if [[ "$core" == all ]]; then
        label="全部候选内核"
    else
        label="$(proxy_core_label "$core")"
    fi
    mode="$(proxy_prompt_quick_custom \
        "${label} ${action} 版本：" \
        "使用最新稳定版（推荐）" "输入 Release tag")" || return $?
    [[ "$mode" == quick ]] && return 0
    if [[ "$core" == all ]]; then
        PROXY_ALL_CUSTOM_VERSIONS=1
        while IFS= read -r candidate; do
            while true; do
                tag="$(proxy_prompt_value "$(proxy_core_label "$candidate") Release tag" "")" || return $?
                [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] && break
                vps_cmd_warning "Release tag 格式无效，请重新输入"
            done
            case "$candidate" in
                sing-box) PROXY_ALL_SING_BOX_TAG="$tag" ;;
                xray) PROXY_ALL_XRAY_TAG="$tag" ;;
            esac
        done < <(proxy_lifecycle_candidates "$action" 1)
        return 0
    fi
    while true; do
        tag="$(proxy_prompt_value "Release tag" "")" || return $?
        if [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]]; then
            PROXY_FORWARD_ARGS+=(--version "$tag")
            return 0
        fi
        vps_cmd_warning "Release tag 格式无效，请重新输入"
    done
}

proxy_prompt_logs_options() {
    local mode=custom lines follow since
    if proxy_forward_has_option --lines || proxy_forward_has_option --follow || proxy_forward_has_option --since; then
        return 0
    fi
    mode="$(proxy_prompt_quick_custom "日志参数：" \
        "最近 100 行、不跟随、不限制起始时间（推荐）" "自定义日志参数")" || return $?
    [[ "$mode" == custom ]] || return 0
    if ! proxy_forward_has_option --lines; then
        lines="$(proxy_prompt_select "请选择日志行数：" 100 \
            50 "50 行" 100 "100 行" 200 "200 行" 500 "500 行" input "手动输入")" || return $?
        if [[ "$lines" == input ]]; then
            while true; do
                lines="$(proxy_prompt_value "日志行数（0-1000000）" "100")" || return $?
                [[ "$lines" =~ ^[0-9]+$ && ${#lines} -le 7 ]] && ((10#$lines <= 1000000)) && break
                vps_cmd_warning "日志行数无效，请重新输入"
            done
        fi
        PROXY_FORWARD_ARGS+=(--lines "$lines")
    fi
    if ! proxy_forward_has_option --follow; then
        follow="$(proxy_prompt_select "是否持续跟踪新日志？" no no "否（推荐）" yes "是")" || return $?
        [[ "$follow" == no ]] || PROXY_FORWARD_ARGS+=(--follow)
    fi
    if [[ "$PROXY_INIT_SYSTEM" == systemd ]] && ! proxy_forward_has_option --since; then
        mode="$(proxy_prompt_quick_custom "日志起始时间：" "不限制（推荐）" "输入 journalctl --since 值")" || return $?
        if [[ "$mode" == custom ]]; then
            while true; do
                since="$(proxy_prompt_value "起始时间（例如 today 或 1 hour ago）" "today")" || return $?
                [[ -n "$since" && "$since" != *$'\n'* && "$since" != *$'\r'* ]] && break
                vps_cmd_warning "起始时间不能为空"
            done
            PROXY_FORWARD_ARGS+=(--since "$since")
        fi
    fi
}

proxy_prepare_interactive_action() {
    local action="$1" core="$2" choice
    proxy_is_interactive || return 0
    case "$action" in
        install | update)
            proxy_prompt_release_options "$action" "$core"
            ;;
        uninstall)
            if ! proxy_forward_has_option --purge; then
                choice="$(proxy_prompt_select "卸载后如何处理配置和节点？" keep \
                    keep "保留配置、节点与备份（推荐）" purge "彻底清除")" || return $?
                [[ "$choice" == keep ]] || PROXY_FORWARD_ARGS+=(--purge)
            fi
            ;;
        start)
            if ! proxy_forward_has_option --enable; then
                choice="$(proxy_prompt_select "启动方式：" start \
                    start "仅启动（推荐）" enable "启动并启用开机启动")" || return $?
                [[ "$choice" == start ]] || PROXY_FORWARD_ARGS+=(--enable)
            fi
            ;;
        stop)
            if ! proxy_forward_has_option --disable; then
                choice="$(proxy_prompt_select "停止方式：" stop \
                    stop "仅停止（推荐）" disable "停止并禁用开机启动")" || return $?
                [[ "$choice" == stop ]] || PROXY_FORWARD_ARGS+=(--disable)
            fi
            ;;
        logs) proxy_prompt_logs_options ;;
    esac
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
    local action="$1" allow_all=0 core status=0 succeeded=0 failed=0 tag
    shift
    PROXY_ALL_CUSTOM_VERSIONS=0
    PROXY_ALL_SING_BOX_TAG=""
    PROXY_ALL_XRAY_TAG=""
    proxy_extract_core "$@" || return $?
    case "$action" in
        install)
            allow_all=1
            ;;
        update)
            allow_all=1
            ;;
    esac
    core="$(proxy_resolve_lifecycle_core "$PROXY_SELECTED_CORE" "$action" "$allow_all")" || return $?
    proxy_prepare_interactive_action "$action" "$core" || return $?
    if [[ "$core" == "all" ]]; then
        local forwarded
        for forwarded in "${PROXY_FORWARD_ARGS[@]}"; do
            if [[ "$forwarded" == "--version" ]]; then
                vps_cmd_error "--core all 不能共用一个 --version；请分别为两个内核指定 Release tag"
                return 2
            fi
        done
        if [[ "$PROXY_ALL_CUSTOM_VERSIONS" == "1" ]]; then
            while IFS= read -r core; do
                [[ -n "$core" ]] || continue
                case "$core" in
                    sing-box) tag="$PROXY_ALL_SING_BOX_TAG" ;;
                    xray) tag="$PROXY_ALL_XRAY_TAG" ;;
                esac
                if "proxy_core_${action}" "$core" --version "$tag" "${PROXY_FORWARD_ARGS[@]}"; then
                    succeeded=$((succeeded + 1))
                else
                    status=$?
                    failed=$((failed + 1))
                fi
            done < <(proxy_lifecycle_candidates "$action" 1)
            ((failed == 0)) && return 0
            ((succeeded == 0)) && return "$status"
            return 30
        fi
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

proxy_menu_action() {
    local status
    if "$@"; then
        return 0
    else
        status=$?
    fi
    if [[ "$status" == "130" ]]; then
        vps_cmd_info "已取消当前操作"
        return 0
    fi
    return "$status"
}

proxy_core_menu_run() {
    local choice status=0 rc
    while true; do
        if choice="$(proxy_prompt_select "内核管理" "" \
            install "安装内核" update "更新内核" uninstall "卸载内核")"; then
            :
        else
            rc=$?
            [[ "$rc" == "130" ]] && return "$status"
            return "$rc"
        fi
        proxy_menu_action proxy_dispatch_core_action "$choice" || status=$?
        proxy_pause
    done
}

proxy_service_menu_run() {
    local choice status=0 rc
    while true; do
        if choice="$(proxy_prompt_select "服务控制" "" \
            start "启动服务" stop "停止服务" restart "重启服务")"; then
            :
        else
            rc=$?
            [[ "$rc" == "130" ]] && return "$status"
            return "$rc"
        fi
        proxy_menu_action proxy_dispatch_core_action "$choice" || status=$?
        proxy_pause
    done
}

proxy_logs_menu_run() {
    local choice status=0 rc
    while true; do
        if choice="$(proxy_prompt_select "日志" view view "查看内核日志")"; then
            :
        else
            rc=$?
            [[ "$rc" == "130" ]] && return "$status"
            return "$rc"
        fi
        if [[ "$choice" == view ]]; then
            proxy_menu_action proxy_dispatch_core_action logs || status=$?
        fi
        proxy_pause
    done
}

proxy_time_menu_run() {
    local choice status=0 rc
    while true; do
        if choice="$(proxy_prompt_select "时间" "" \
            status "查看系统时间状态" sync "同步系统时间")"; then
            :
        else
            rc=$?
            [[ "$rc" == "130" ]] && return "$status"
            return "$rc"
        fi
        case "$choice" in
            status) proxy_menu_action proxy_time_status || status=$? ;;
            sync) proxy_menu_action proxy_time_sync || status=$? ;;
        esac
        proxy_pause
    done
}

proxy_protocol_menu_run() {
    local choice status=0 rc
    while true; do
        if choice="$(proxy_prompt_select "协议" profiles profiles "查看支持的协议与内核")"; then
            :
        else
            rc=$?
            [[ "$rc" == "130" ]] && return "$status"
            return "$rc"
        fi
        if [[ "$choice" == profiles ]]; then
            proxy_menu_action proxy_profiles_show || status=$?
        fi
        proxy_pause
    done
}

proxy_menu_run() {
    local choice status=0 rc
    while true; do
        printf '\n代理管理\n'
        printf '============================================================\n'
        proxy_core_status all || true
        if choice="$(proxy_prompt_select "代理能力" "" \
            core "内核管理" nodes "节点管理" service "服务控制" \
            logs "日志" time "时间" protocols "协议")"; then
            :
        else
            rc=$?
            [[ "$rc" == "130" ]] && return "$status"
            return "$rc"
        fi
        case "$choice" in
            core) proxy_core_menu_run || status=$? ;;
            nodes) proxy_node_menu_run || status=$? ;;
            service) proxy_service_menu_run || status=$? ;;
            logs) proxy_logs_menu_run || status=$? ;;
            time) proxy_time_menu_run || status=$? ;;
            protocols) proxy_protocol_menu_run || status=$? ;;
        esac
    done
}

proxy_dispatch() {
    local action="${1:-}" subaction="${2:-}"
    if [[ -z "$action" ]]; then
        if proxy_is_interactive; then
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
    if vps_cmd_is_interactive; then
        PROXY_INTERACTIVE=1
    else
        PROXY_INTERACTIVE=0
    fi
    proxy_dispatch "${PROXY_ARGS[@]}" || status=$?
    return "$status"
}

proxy_main "$@"
