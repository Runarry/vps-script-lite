# shellcheck shell=bash
# Terminal UI for vpsctl. The interface intentionally uses an ASCII layout so
# it remains readable in basic SSH terminals and serial consoles.

declare -g VPS_UI_WIDTH=76
declare -g VPS_UI_CHOICE=""
declare -g VPS_UI_INDEX=-1
declare -g VPS_UI_RESET=""
declare -g VPS_UI_BOLD=""
declare -g VPS_UI_DIM=""
declare -g VPS_UI_GREEN=""
declare -g VPS_UI_YELLOW=""
declare -g VPS_UI_RED=""
declare -g VPS_UI_CYAN=""

vps_ui_init() {
    local detected_width="${COLUMNS:-}"

    VPS_UI_RESET=""
    VPS_UI_BOLD=""
    VPS_UI_DIM=""
    VPS_UI_GREEN=""
    VPS_UI_YELLOW=""
    VPS_UI_RED=""
    VPS_UI_CYAN=""

    if [[ ! "$detected_width" =~ ^[0-9]+$ ]] && command -v tput >/dev/null 2>&1; then
        detected_width="$(tput cols 2>/dev/null || true)"
    fi
    [[ "$detected_width" =~ ^[0-9]+$ ]] || detected_width=76
    ((detected_width > 100)) && detected_width=100
    ((detected_width < 48)) && detected_width=48
    VPS_UI_WIDTH="$detected_width"

    if [[ "${VPSCTL_NO_COLOR:-0}" == "0" && -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
        VPS_UI_RESET=$'\033[0m'
        VPS_UI_BOLD=$'\033[1m'
        VPS_UI_DIM=$'\033[2m'
        VPS_UI_GREEN=$'\033[32m'
        VPS_UI_YELLOW=$'\033[33m'
        VPS_UI_RED=$'\033[31m'
        VPS_UI_CYAN=$'\033[36m'
    fi
}

vps_ui_repeat() {
    local character="$1"
    local count="$2"
    local output

    printf -v output '%*s' "$count" ''
    printf '%s\n' "${output// /$character}"
}

vps_ui_rule() {
    vps_ui_repeat "${1:--}" "$VPS_UI_WIDTH"
}

vps_ui_clear_screen() {
    if [[ "${VPSCTL_CLEAR:-1}" == "1" && "${VPSCTL_NO_COLOR:-0}" == "0" && -z "${NO_COLOR:-}" && -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
        printf '\033[2J\033[H'
    fi
}

vps_ui_header() {
    local title="$1"
    vps_ui_rule '='
    printf ' %s%s%s\n' "$VPS_UI_BOLD" "$title" "$VPS_UI_RESET"
    vps_ui_rule '='
}

vps_ui_kv() {
    local label="$1"
    local value="${2:-未知}"
    printf '  %s：%s\n' "$label" "$(vps_ui_value_label "$value")"
}

vps_ui_value_label() {
    case "$1" in
        unknown) printf '%s未知%s' "$VPS_UI_YELLOW" "$VPS_UI_RESET" ;;
        unavailable | 'not available') printf '%s不可用%s' "$VPS_UI_YELLOW" "$VPS_UI_RESET" ;;
        enabled) printf '%s已启用%s' "$VPS_UI_GREEN" "$VPS_UI_RESET" ;;
        disabled) printf '%s未启用%s' "$VPS_UI_YELLOW" "$VPS_UI_RESET" ;;
        yes) printf '%s是%s' "$VPS_UI_GREEN" "$VPS_UI_RESET" ;;
        no) printf '%s否%s' "$VPS_UI_YELLOW" "$VPS_UI_RESET" ;;
        bare-metal) printf '%s物理机%s' "$VPS_UI_CYAN" "$VPS_UI_RESET" ;;
        wsl) printf '%sWSL%s' "$VPS_UI_CYAN" "$VPS_UI_RESET" ;;
        docker) printf '%sDocker%s' "$VPS_UI_CYAN" "$VPS_UI_RESET" ;;
        lxc) printf '%sLXC%s' "$VPS_UI_CYAN" "$VPS_UI_RESET" ;;
        container) printf '%s容器%s' "$VPS_UI_CYAN" "$VPS_UI_RESET" ;;
        local) printf '%s本地%s' "$VPS_UI_CYAN" "$VPS_UI_RESET" ;;
        *) printf '%s' "$1" ;;
    esac
}

vps_ui_status_badge() {
    case "${VPS_ENV[compatibility]}" in
        supported) printf '%s支持%s' "$VPS_UI_GREEN" "$VPS_UI_RESET" ;;
        limited) printf '%s受限%s' "$VPS_UI_YELLOW" "$VPS_UI_RESET" ;;
        *) printf '%s不支持%s' "$VPS_UI_RED" "$VPS_UI_RESET" ;;
    esac
}

vps_ui_availability_label() {
    case "$1" in
        ready) printf '%s可用%s' "$VPS_UI_GREEN" "$VPS_UI_RESET" ;;
        *) printf '%s受限%s' "$VPS_UI_YELLOW" "$VPS_UI_RESET" ;;
    esac
}

vps_ui_risk_label() {
    case "$1" in
        read-only) printf '%s只读%s' "$VPS_UI_GREEN" "$VPS_UI_RESET" ;;
        change) printf '%s变更%s' "$VPS_UI_YELLOW" "$VPS_UI_RESET" ;;
        disruptive) printf '%s中断性%s' "$VPS_UI_RED" "$VPS_UI_RESET" ;;
        destructive) printf '%s破坏性%s' "$VPS_UI_RED" "$VPS_UI_RESET" ;;
        *) printf '%s%s%s' "$VPS_UI_CYAN" "$1" "$VPS_UI_RESET" ;;
    esac
}

vps_ui_privilege_label() {
    case "$1" in
        user) printf '%s普通用户%s' "$VPS_UI_GREEN" "$VPS_UI_RESET" ;;
        optional-root) printf '%s按需 root%s' "$VPS_UI_YELLOW" "$VPS_UI_RESET" ;;
        root) printf '%s必须 root%s' "$VPS_UI_RED" "$VPS_UI_RESET" ;;
        *) printf '%s%s%s' "$VPS_UI_CYAN" "$1" "$VPS_UI_RESET" ;;
    esac
}

vps_ui_dry_run_label() {
    case "$1" in
        supported) printf '%s支持%s' "$VPS_UI_GREEN" "$VPS_UI_RESET" ;;
        not-applicable) printf '%s不适用%s' "$VPS_UI_CYAN" "$VPS_UI_RESET" ;;
        unsupported) printf '%s不支持%s' "$VPS_UI_RED" "$VPS_UI_RESET" ;;
        *) printf '%s%s%s' "$VPS_UI_CYAN" "$1" "$VPS_UI_RESET" ;;
    esac
}

vps_ui_lifecycle_label() {
    case "$1" in
        stable) printf '%s稳定%s' "$VPS_UI_GREEN" "$VPS_UI_RESET" ;;
        experimental) printf '%s实验性%s' "$VPS_UI_YELLOW" "$VPS_UI_RESET" ;;
        deprecated) printf '%s已弃用%s' "$VPS_UI_YELLOW" "$VPS_UI_RESET" ;;
        removed) printf '%s已移除%s' "$VPS_UI_RED" "$VPS_UI_RESET" ;;
        *) printf '%s%s%s' "$VPS_UI_CYAN" "$1" "$VPS_UI_RESET" ;;
    esac
}

vps_ui_exit_code() {
    local status="$1"

    case "$status" in
        0) printf '%s%s%s' "$VPS_UI_GREEN" "$status" "$VPS_UI_RESET" ;;
        30) printf '%s%s%s' "$VPS_UI_YELLOW" "$status" "$VPS_UI_RESET" ;;
        130) printf '%s%s%s' "$VPS_UI_CYAN" "$status" "$VPS_UI_RESET" ;;
        *) printf '%s%s%s' "$VPS_UI_RED" "$status" "$VPS_UI_RESET" ;;
    esac
}

vps_ui_dashboard() {
    local version="$1"
    local cpu_summary disk_summary network_summary

    cpu_summary="$(vps_ui_value_label "${VPS_ENV[cpu_cores]}") 核 / $(vps_ui_value_label "${VPS_ENV[memory_total]}")"
    disk_summary="可用 $(vps_ui_value_label "${VPS_ENV[root_disk_available]}") / 总计 $(vps_ui_value_label "${VPS_ENV[root_disk_total]}")（已用 $(vps_ui_value_label "${VPS_ENV[root_disk_used_percent]}")）"
    network_summary="IPv4 $(vps_ui_value_label "${VPS_ENV[ipv4]}") / IPv6 $(vps_ui_value_label "${VPS_ENV[ipv6]}")"
    vps_ui_rule '='
    printf ' %sVPS Script Lite%s  v%s\n' "$VPS_UI_BOLD" "$VPS_UI_RESET" "$version"
    printf ' 主机：%s    状态：' "${VPS_ENV[hostname]}"
    vps_ui_status_badge
    printf '\n'
    vps_ui_rule '-'
    printf ' %s基础环境%s\n' "$VPS_UI_CYAN" "$VPS_UI_RESET"
    vps_ui_kv "系统" "${VPS_ENV[os_pretty_name]}"
    vps_ui_kv "内核" "${VPS_ENV[kernel_name]} ${VPS_ENV[kernel_release]}"
    vps_ui_kv "架构" "${VPS_ENV[architecture]}"
    vps_ui_kv "虚拟化" "${VPS_ENV[virtualization]}"
    vps_ui_kv "CPU / 内存" "$cpu_summary"
    vps_ui_kv "根分区" "$disk_summary"
    vps_ui_kv "网络" "$network_summary"
    vps_ui_kv "BBR 状态" "${VPS_ENV[bbr_status]}"
    vps_ui_kv "BBR 版本" "${VPS_ENV[bbr_version]}"
    vps_ui_kv "拥塞控制" "${VPS_ENV[congestion_control]}"
    vps_ui_rule '-'
}

vps_ui_environment_details() {
    printf ' %s系统与能力%s\n' "$VPS_UI_CYAN" "$VPS_UI_RESET"
    vps_ui_kv "系统 ID" "${VPS_ENV[os_id]}"
    vps_ui_kv "系统族" "${VPS_ENV[os_id_like]:-未知}"
    vps_ui_kv "系统版本" "${VPS_ENV[os_version_id]}"
    vps_ui_kv "代号" "${VPS_ENV[os_codename]:-未知}"
    vps_ui_kv "CPU 型号" "${VPS_ENV[cpu_model]}"
    vps_ui_kv "Bash" "${VPS_ENV[bash_version]}"
    vps_ui_kv "可用拥塞控制" "${VPS_ENV[available_congestion_controls]}"
    vps_ui_kv "兼容性" "${VPS_ENV[compatibility_detail]}"
}

vps_ui_main_menu() {
    local index domain count

    printf ' %s主菜单%s\n\n' "$VPS_UI_BOLD" "$VPS_UI_RESET"
    if ((${#VPS_DOMAIN_IDS[@]} == 0)); then
        printf '  %s暂无已登记功能。%s\n' "$VPS_UI_DIM" "$VPS_UI_RESET"
    else
        for ((index = 0; index < ${#VPS_DOMAIN_IDS[@]}; index++)); do
            domain="${VPS_DOMAIN_IDS[$index]}"
            count="$(vps_registry_count_commands "$domain")"
            printf '  [%d] %s  %s(%s 个功能)%s\n' "$((index + 1))" "${VPS_DOMAIN_LABEL[$domain]}" "$VPS_UI_DIM" "$count" "$VPS_UI_RESET"
        done
    fi
    printf '\n  [q] 退出\n\n'
}

vps_ui_domain_commands() {
    local domain="$1"
    local index command_key ready_label

    printf ' %s%s%s\n\n' "$VPS_UI_DIM" "${VPS_DOMAIN_DESCRIPTION[$domain]}" "$VPS_UI_RESET"
    for ((index = 0; index < ${#VPS_REGISTRY_RESULTS[@]}; index++)); do
        command_key="${VPS_REGISTRY_RESULTS[$index]}"
        if vps_env_requirements_met "${VPS_COMMAND_REQUIREMENTS[$command_key]}"; then
            ready_label="$(vps_ui_availability_label ready)"
        else
            ready_label="$(vps_ui_availability_label limited)"
        fi
        printf '  [%d] %s  [%b]\n' "$((index + 1))" "${VPS_COMMAND_LABEL[$command_key]}" "$ready_label"
        printf '      %s\n' "${VPS_COMMAND_SUMMARY[$command_key]}"
    done
}

vps_ui_command_details() {
    local command_key="$1"

    printf ' %s%s%s\n\n' "$VPS_UI_BOLD" "${VPS_COMMAND_LABEL[$command_key]}" "$VPS_UI_RESET"
    vps_ui_kv "命令" "${VPS_COMMAND_DOMAIN[$command_key]} ${VPS_COMMAND_ACTION[$command_key]}"
    vps_ui_kv "摘要" "${VPS_COMMAND_SUMMARY[$command_key]}"
    vps_ui_kv "风险" "$(vps_ui_risk_label "${VPS_COMMAND_RISK[$command_key]}")"
    vps_ui_kv "权限" "$(vps_ui_privilege_label "${VPS_COMMAND_PRIVILEGE[$command_key]}")"
    vps_ui_kv "演练" "$(vps_ui_dry_run_label "${VPS_COMMAND_DRY_RUN[$command_key]}")"
    vps_ui_kv "能力要求" "${VPS_COMMAND_REQUIREMENTS[$command_key]:-无}"
    vps_ui_kv "生命周期" "$(vps_ui_lifecycle_label "${VPS_COMMAND_LIFECYCLE[$command_key]}")"
}

vps_ui_registered_commands() {
    local command_key availability

    if ((${#VPS_COMMAND_KEYS[@]} == 0)); then
        vps_ui_info "当前尚无已实现的功能命令。环境检测和管理 UI 已可使用。"
        return 0
    fi

    for command_key in "${VPS_COMMAND_KEYS[@]}"; do
        if vps_env_requirements_met "${VPS_COMMAND_REQUIREMENTS[$command_key]}"; then
            availability="$(vps_ui_availability_label ready)"
        else
            availability="$(vps_ui_availability_label limited)"
        fi
        printf '  %-28s [%b] %s\n' \
            "${VPS_COMMAND_DOMAIN[$command_key]} ${VPS_COMMAND_ACTION[$command_key]}" \
            "$availability" \
            "${VPS_COMMAND_SUMMARY[$command_key]}"
    done
}

vps_ui_info() {
    printf '\n  %s提示%s  %s\n' "$VPS_UI_CYAN" "$VPS_UI_RESET" "$1"
}

vps_ui_warning() {
    printf '\n  %s警告%s  %s\n' "$VPS_UI_YELLOW" "$VPS_UI_RESET" "$1"
}

vps_ui_read_choice() {
    local prompt="$1"
    printf ' %s%s%s > ' "$VPS_UI_CYAN" "$prompt" "$VPS_UI_RESET"
    if IFS= read -r VPS_UI_CHOICE; then
        VPS_UI_CHOICE="$(vps_env_trim "$VPS_UI_CHOICE")"
        return 0
    fi
    return 1
}

vps_ui_parse_index() {
    local choice="$1"
    local item_count="$2"
    local numeric_value

    VPS_UI_INDEX=-1
    [[ "$choice" =~ ^[1-9][0-9]{0,3}$ ]] || return 1
    [[ "$item_count" =~ ^[0-9]+$ ]] || return 1

    numeric_value=$((10#$choice))
    ((numeric_value >= 1 && numeric_value <= item_count)) || return 1
    # Consumed by the menu controller in bin/vpsctl.
    # shellcheck disable=SC2034
    VPS_UI_INDEX=$((numeric_value - 1))
}

vps_ui_pause() {
    local _pause_input
    printf '\n %s按 Enter 返回...%s' "$VPS_UI_CYAN" "$VPS_UI_RESET"
    IFS= read -r _pause_input || true
}
