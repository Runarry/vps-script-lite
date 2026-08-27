# shellcheck shell=bash
# Private time helpers for commands/service/proxy.sh. Sourcing this file only
# defines functions. proxy_common_init must have initialized the platform first.

_proxy_time_bool() {
    case "${1,,}" in
        1 | yes | true | enabled | active) printf 'true' ;;
        0 | no | false | disabled | inactive) printf 'false' ;;
        *) printf 'false' ;;
    esac
}

_proxy_time_json_escape() {
    local value="${1:-}"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

_proxy_time_systemd_unit_exists() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl cat "$1" >/dev/null 2>&1
}

_proxy_time_systemd_unit_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "$1" >/dev/null 2>&1
}

_proxy_time_openrc_service_exists() {
    local service="$1"
    command -v rc-service >/dev/null 2>&1 || return 1
    while IFS= read -r candidate; do
        [[ "$candidate" == "$service" ]] && return 0
    done < <(rc-service -l 2>/dev/null)
    return 1
}

_proxy_time_chrony_service() {
    local service
    case "$PROXY_INIT_SYSTEM" in
        systemd)
            for service in chrony chronyd; do
                if _proxy_time_systemd_unit_exists "${service}.service"; then
                    printf '%s' "$service"
                    return 0
                fi
            done
            ;;
        openrc)
            for service in chronyd chrony; do
                if _proxy_time_openrc_service_exists "$service"; then
                    printf '%s' "$service"
                    return 0
                fi
            done
            ;;
        *) return 1 ;;
    esac
    return 1
}

_proxy_time_default_chrony_service() {
    case "$PROXY_INIT_SYSTEM" in
        openrc)
            case "$PROXY_PACKAGE_MANAGER" in
                apt-get) printf 'chrony' ;;
                *) printf 'chronyd' ;;
            esac
            ;;
        systemd)
            case "$PROXY_PACKAGE_MANAGER" in
                apt-get) printf 'chrony' ;;
                *) printf 'chronyd' ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

_proxy_time_detect_backend() {
    local service
    case "$PROXY_INIT_SYSTEM" in
        systemd)
            if _proxy_time_systemd_unit_active systemd-timesyncd.service; then
                printf 'systemd-timesyncd'
                return 0
            fi
            for service in chrony chronyd; do
                if _proxy_time_systemd_unit_active "${service}.service"; then
                    printf 'chrony'
                    return 0
                fi
            done
            if _proxy_time_systemd_unit_exists systemd-timesyncd.service; then
                printf 'systemd-timesyncd'
                return 0
            fi
            if _proxy_time_chrony_service >/dev/null; then
                printf 'chrony'
                return 0
            fi
            if command -v chronyc >/dev/null 2>&1; then
                printf 'chrony'
                return 0
            fi
            if command -v timedatectl >/dev/null 2>&1 &&
                [[ "$(timedatectl show -p CanNTP --value 2>/dev/null || true)" =~ ^(yes|true|1)$ ]]; then
                printf 'timedatectl'
                return 0
            fi
            ;;
        openrc)
            if _proxy_time_chrony_service >/dev/null || command -v chronyc >/dev/null 2>&1; then
                printf 'chrony'
                return 0
            fi
            ;;
    esac
    printf 'none'
}

_proxy_time_timedatectl_value() {
    command -v timedatectl >/dev/null 2>&1 || return 1
    timedatectl show -p "$1" --value 2>/dev/null
}

_proxy_time_chrony_sync_value() {
    local tracking
    command -v chronyc >/dev/null 2>&1 || return 1
    tracking="$(LC_ALL=C chronyc tracking 2>/dev/null)" || return 1
    [[ "$tracking" == *"Leap status"*"Normal"* || "$tracking" == *"Leap status"*"Not synchronised"* ]] || return 1
    if [[ "$tracking" == *"Leap status"*"Normal"* ]]; then
        printf 'true'
    else
        printf 'false'
    fi
}

_proxy_time_service_enabled() {
    local backend="$1" service
    case "$PROXY_INIT_SYSTEM:$backend" in
        systemd:systemd-timesyncd)
            systemctl is-enabled --quiet systemd-timesyncd.service >/dev/null 2>&1
            ;;
        systemd:chrony)
            service="$(_proxy_time_chrony_service)" || return 1
            systemctl is-enabled --quiet "${service}.service" >/dev/null 2>&1
            ;;
        openrc:chrony)
            service="$(_proxy_time_chrony_service)" || return 1
            rc-update show default 2>/dev/null | awk '{print $1}' | grep -Fxq "$service"
            ;;
        systemd:timedatectl)
            [[ "$(_proxy_time_timedatectl_value NTP || true)" =~ ^(yes|true|1)$ ]]
            ;;
        *) return 1 ;;
    esac
}

_proxy_time_current_state() {
    local backend="$1" raw_value="" enabled_value="" synchronized_value=""

    raw_value="$(_proxy_time_timedatectl_value NTP || true)"
    if [[ "$raw_value" =~ ^(yes|true|1|no|false|0)$ ]]; then
        enabled_value="$(_proxy_time_bool "$raw_value")"
    fi
    if [[ -z "$enabled_value" ]]; then
        _proxy_time_service_enabled "$backend" && enabled_value=true || enabled_value=false
    fi
    if [[ "$backend" == "chrony" ]]; then
        synchronized_value="$(_proxy_time_chrony_sync_value || true)"
    fi
    if [[ -z "$synchronized_value" ]]; then
        synchronized_value="$(_proxy_time_bool "$(_proxy_time_timedatectl_value NTPSynchronized || true)")"
    fi
    printf '%s %s' "$enabled_value" "$synchronized_value"
}

proxy_time_status() {
    local output_json=0 utc_time timezone backend enabled synchronized
    case "${1:-}" in
        '') ;;
        --json) output_json=1 ;;
        *)
            vps_cmd_error "time status 仅支持 --json"
            return 2
            ;;
    esac
    (($# <= 1)) || {
        vps_cmd_error "time status 参数过多"
        return 2
    }

    utc_time="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || {
        vps_cmd_error "无法读取当前 UTC 时间"
        return 20
    }
    timezone="$(_proxy_time_timedatectl_value Timezone || true)"
    if [[ -z "$timezone" && "${VPSCTL_TESTING:-0}" == "1" ]]; then
        timezone="${TZ:-UTC}"
    elif [[ -z "$timezone" ]]; then
        timezone="$(date +%Z 2>/dev/null || printf 'unknown')"
    fi
    backend="$(_proxy_time_detect_backend)"
    IFS=' ' read -r enabled synchronized <<<"$(_proxy_time_current_state "$backend")"

    if ((output_json)); then
        printf '{"schema_version":1,"utc_time":"%s","timezone":"%s","ntp_enabled":%s,"ntp_synchronized":%s,"backend":"%s"}\n' \
            "$(_proxy_time_json_escape "$utc_time")" \
            "$(_proxy_time_json_escape "$timezone")" \
            "$enabled" "$synchronized" \
            "$(_proxy_time_json_escape "$backend")"
        return 0
    fi

    vps_cmd_status "UTC 时间" "$utc_time" info
    vps_cmd_status "时区" "$timezone" info
    vps_cmd_status "NTP 已启用" "$([[ "$enabled" == true ]] && printf '是' || printf '否')" "$([[ "$enabled" == true ]] && printf 'success' || printf 'warning')"
    vps_cmd_status "时间已同步" "$([[ "$synchronized" == true ]] && printf '是' || printf '否')" "$([[ "$synchronized" == true ]] && printf 'success' || printf 'warning')"
    vps_cmd_status "时间同步后端" "$backend" "$([[ "$backend" != none ]] && printf 'info' || printf 'warning')"
}

_proxy_time_install_chrony() {
    local -a command_args
    case "$PROXY_PACKAGE_MANAGER" in
        apt-get)
            command_args=(apt-get update)
            vps_cmd_run "${command_args[@]}" || return 20
            command_args=(apt-get install -y --no-install-recommends chrony)
            ;;
        dnf5) command_args=(dnf5 install -y chrony) ;;
        dnf) command_args=(dnf install -y chrony) ;;
        yum) command_args=(yum install -y chrony) ;;
        apk) command_args=(apk add --no-cache chrony) ;;
        pacman) command_args=(pacman -S --noconfirm --needed chrony) ;;
        zypper) command_args=(zypper --non-interactive install --no-recommends chrony) ;;
        *)
            vps_cmd_error "无法使用当前包管理器安装 chrony：${PROXY_PACKAGE_MANAGER}"
            return 3
            ;;
    esac
    vps_cmd_run "${command_args[@]}" || return 20
}

_proxy_time_enable_systemd() {
    local backend="$1" service="$2" timedatectl_enabled=0
    if [[ "$backend" != "chrony" ]]; then
        if command -v timedatectl >/dev/null 2>&1; then
            if vps_cmd_run timedatectl set-ntp true; then
                timedatectl_enabled=1
            elif [[ "$backend" == timedatectl ]]; then
                return 20
            fi
        elif [[ "$backend" == timedatectl ]]; then
            return 20
        fi
    fi

    case "$backend" in
        systemd-timesyncd)
            if ((timedatectl_enabled == 0)); then
                vps_cmd_run systemctl enable --now systemd-timesyncd.service || return 20
            fi
            ;;
        chrony)
            vps_cmd_run systemctl enable --now "${service}.service" || return 20
            ;;
        timedatectl) ;;
        *) return 3 ;;
    esac
}

_proxy_time_enable_openrc() {
    local service="$1"
    vps_cmd_run rc-update add "$service" default || return 20
    vps_cmd_run rc-service "$service" start || return 20
}

_proxy_time_wait_synchronized() {
    local chrony_planned="${1:-0}" attempt synchronized
    if command -v chronyc >/dev/null 2>&1 ||
        [[ "$chrony_planned" == "1" && "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_run chronyc makestep || return 20
        [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] && return 0
        LC_ALL=C chronyc waitsync 30 0.0 0.0 1 >/dev/null 2>&1 && return 0
        vps_cmd_error "chrony 未能在 30 秒内确认时间同步"
        return 30
    fi

    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] && return 0
    for ((attempt = 0; attempt < 30; attempt++)); do
        synchronized="$(_proxy_time_timedatectl_value NTPSynchronized || true)"
        [[ "$synchronized" =~ ^(yes|true|1)$ ]] && return 0
        [[ "${VPSCTL_TESTING:-0}" == "1" ]] || sleep 1
    done
    vps_cmd_error "NTP 后端未能在 30 秒内确认时间同步"
    return 30
}

proxy_time_sync() (
    local backend service="" installed=0
    (($# == 0)) || {
        vps_cmd_error "time sync 不接受位置参数"
        return 2
    }
    vps_cmd_require_root || return $?
    vps_cmd_lock proxy-time || return $?
    trap 'vps_cmd_unlock' EXIT

    case "$PROXY_INIT_SYSTEM" in
        systemd | openrc) ;;
        *)
            vps_cmd_error "时间同步仅支持 systemd 或 OpenRC（当前：${PROXY_INIT_SYSTEM}）"
            return 3
            ;;
    esac

    backend="$(_proxy_time_detect_backend)"
    if [[ "$PROXY_INIT_SYSTEM" == openrc && "$backend" != chrony ]]; then
        backend=none
    fi
    if [[ "$backend" == none ]]; then
        _proxy_time_install_chrony || return $?
        installed=1
        backend=chrony
    fi

    if [[ "$backend" == chrony ]]; then
        service="$(_proxy_time_chrony_service || true)"
        if [[ -z "$service" ]]; then
            service="$(_proxy_time_default_chrony_service)" || return 3
        fi
    fi

    case "$PROXY_INIT_SYSTEM" in
        systemd) _proxy_time_enable_systemd "$backend" "$service" || return $? ;;
        openrc) _proxy_time_enable_openrc "$service" || return $? ;;
    esac

    _proxy_time_wait_synchronized "$installed" || return $?
    if ((installed)); then
        vps_cmd_success "chrony 已安装并启用，时间同步已确认"
    else
        vps_cmd_success "NTP 已启用，时间同步已确认（后端：${backend}）"
    fi
)
