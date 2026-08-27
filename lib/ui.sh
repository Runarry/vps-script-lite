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
    if [[ "${VPSCTL_CLEAR:-1}" == "1" && -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
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
    local value="${2:-unknown}"
    printf '  %-16s %s\n' "$label" "$value"
}

vps_ui_status_badge() {
    case "${VPS_ENV[compatibility]}" in
        supported) printf '%sSUPPORTED%s' "$VPS_UI_GREEN" "$VPS_UI_RESET" ;;
        limited) printf '%sLIMITED%s' "$VPS_UI_YELLOW" "$VPS_UI_RESET" ;;
        *) printf '%sUNSUPPORTED%s' "$VPS_UI_RED" "$VPS_UI_RESET" ;;
    esac
}

vps_ui_dashboard() {
    local version="$1"
    local cpu_summary disk_summary network_summary

    cpu_summary="${VPS_ENV[cpu_cores]} core(s) / ${VPS_ENV[memory_total]}"
    disk_summary="${VPS_ENV[root_disk_available]} free of ${VPS_ENV[root_disk_total]} (${VPS_ENV[root_disk_used_percent]} used)"
    network_summary="IPv4 ${VPS_ENV[ipv4]} / IPv6 ${VPS_ENV[ipv6]}"
    vps_ui_rule '='
    printf ' %sVPS Script Lite%s  v%s\n' "$VPS_UI_BOLD" "$VPS_UI_RESET" "$version"
    printf ' Host: %s    Status: ' "${VPS_ENV[hostname]}"
    vps_ui_status_badge
    printf '\n'
    vps_ui_rule '-'
    printf ' %s基础环境%s\n' "$VPS_UI_CYAN" "$VPS_UI_RESET"
    vps_ui_kv "System" "${VPS_ENV[os_pretty_name]}"
    vps_ui_kv "Kernel" "${VPS_ENV[kernel_name]} ${VPS_ENV[kernel_release]}"
    vps_ui_kv "Architecture" "${VPS_ENV[architecture]}"
    vps_ui_kv "Virtualization" "${VPS_ENV[virtualization]}"
    vps_ui_kv "CPU / Memory" "$cpu_summary"
    vps_ui_kv "Root disk" "$disk_summary"
    vps_ui_kv "Network" "$network_summary"
    vps_ui_kv "BBR status" "${VPS_ENV[bbr_status]}"
    vps_ui_kv "BBR version" "${VPS_ENV[bbr_version]}"
    vps_ui_kv "CC algorithm" "${VPS_ENV[congestion_control]}"
    vps_ui_rule '-'
}

vps_ui_environment_details() {
    printf ' %s系统与能力%s\n' "$VPS_UI_CYAN" "$VPS_UI_RESET"
    vps_ui_kv "OS ID" "${VPS_ENV[os_id]}"
    vps_ui_kv "OS family" "${VPS_ENV[os_id_like]:-unknown}"
    vps_ui_kv "OS version" "${VPS_ENV[os_version_id]}"
    vps_ui_kv "Codename" "${VPS_ENV[os_codename]:-unknown}"
    vps_ui_kv "CPU model" "${VPS_ENV[cpu_model]}"
    vps_ui_kv "Bash" "${VPS_ENV[bash_version]}"
    vps_ui_kv "Available CC" "${VPS_ENV[available_congestion_controls]}"
    vps_ui_kv "Compatibility" "${VPS_ENV[compatibility_detail]}"
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
            ready_label="${VPS_UI_GREEN}ready${VPS_UI_RESET}"
        else
            ready_label="${VPS_UI_YELLOW}limited${VPS_UI_RESET}"
        fi
        printf '  [%d] %s  [%b]\n' "$((index + 1))" "${VPS_COMMAND_LABEL[$command_key]}" "$ready_label"
        printf '      %s\n' "${VPS_COMMAND_SUMMARY[$command_key]}"
    done
}

vps_ui_command_details() {
    local command_key="$1"

    printf ' %s%s%s\n\n' "$VPS_UI_BOLD" "${VPS_COMMAND_LABEL[$command_key]}" "$VPS_UI_RESET"
    vps_ui_kv "Command" "${VPS_COMMAND_DOMAIN[$command_key]} ${VPS_COMMAND_ACTION[$command_key]}"
    vps_ui_kv "Summary" "${VPS_COMMAND_SUMMARY[$command_key]}"
    vps_ui_kv "Risk" "${VPS_COMMAND_RISK[$command_key]}"
    vps_ui_kv "Privilege" "${VPS_COMMAND_PRIVILEGE[$command_key]}"
    vps_ui_kv "Dry-run" "${VPS_COMMAND_DRY_RUN[$command_key]}"
    vps_ui_kv "Requirements" "${VPS_COMMAND_REQUIREMENTS[$command_key]:-none}"
    vps_ui_kv "Lifecycle" "${VPS_COMMAND_LIFECYCLE[$command_key]}"
}

vps_ui_registered_commands() {
    local command_key

    if ((${#VPS_COMMAND_KEYS[@]} == 0)); then
        vps_ui_info "当前尚无已实现的功能命令。环境检测和管理 UI 已可使用。"
        return 0
    fi

    for command_key in "${VPS_COMMAND_KEYS[@]}"; do
        printf '  %-28s %s\n' "${VPS_COMMAND_DOMAIN[$command_key]} ${VPS_COMMAND_ACTION[$command_key]}" "${VPS_COMMAND_SUMMARY[$command_key]}"
    done
}

vps_ui_info() {
    printf '\n  %sINFO%s  %s\n' "$VPS_UI_CYAN" "$VPS_UI_RESET" "$1"
}

vps_ui_warning() {
    printf '\n  %sWARN%s  %s\n' "$VPS_UI_YELLOW" "$VPS_UI_RESET" "$1"
}

vps_ui_read_choice() {
    local prompt="$1"
    printf ' %s > ' "$prompt"
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
    VPS_UI_INDEX=$((numeric_value - 1))
}

vps_ui_pause() {
    local ignored
    printf '\n 按 Enter 返回...'
    IFS= read -r ignored || true
}
