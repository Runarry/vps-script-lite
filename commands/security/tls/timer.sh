# shellcheck shell=bash
# systemd timer for security tls renew --all, and uninstall.

tls_emit_renew_service() {
    cat <<EOF
${TLS_MARKER}
[Unit]
Description=vpsctl TLS certificate renewal
Documentation=https://github.com/Runarry/vps-script-lite
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$(tls_vpsctl_exec_line)
Nice=10
EOF
}

tls_emit_renew_timer() {
    cat <<EOF
${TLS_MARKER}
[Unit]
Description=vpsctl TLS certificate renewal timer
Documentation=https://github.com/Runarry/vps-script-lite

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true
Unit=vpsctl-tls-renew.service

[Install]
WantedBy=timers.target
EOF
}

tls_is_managed_unit() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] && IFS= read -r line <"$file" && [[ "$line" == "$TLS_MARKER" ]]
}

tls_write_timer_units() {
    local service_dir
    service_dir="$(dirname -- "$TLS_TIMER_SERVICE")"
    mkdir -p -- "$service_dir" || return 20
    vps_cmd_require_no_symlink_components "$service_dir" || return $?
    tls_emit_renew_service | tls_atomic_file "$TLS_TIMER_SERVICE_LOGICAL" 0644 || return 20
    tls_emit_renew_timer | tls_atomic_file "$TLS_TIMER_UNIT_LOGICAL" 0644 || return 20
}

tls_timer_enable_quiet() {
    [[ "$(tls_init_detected)" == systemd ]] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：启用 vpsctl-tls-renew.timer"
        return 0
    fi
    tls_write_timer_units || return $?
    vps_cmd_run systemctl daemon-reload || return 20
    vps_cmd_run systemctl enable --now vpsctl-tls-renew.timer || return 20
}

tls_timer_status() {
    (($# == 0)) || { vps_cmd_error "timer status 不接受参数"; return 2; }
    tls_timer_flags
    if [[ "$TLS_TIMER_SUPPORTED" != true ]]; then
        vps_cmd_status "续期 timer" "当前环境不支持 systemd" warning
        return 0
    fi
    vps_cmd_status "unit" "$(tls_is_managed_unit "$TLS_TIMER_UNIT" && printf 受管 || printf 缺失)" \
        "$(tls_is_managed_unit "$TLS_TIMER_UNIT" && printf success || printf warning)"
    vps_cmd_status "enabled" "$TLS_TIMER_ENABLED" "$([[ "$TLS_TIMER_ENABLED" == true ]] && printf success || printf warning)"
    vps_cmd_status "active" "$TLS_TIMER_ACTIVE" "$([[ "$TLS_TIMER_ACTIVE" == true ]] && printf success || printf warning)"
}

tls_timer_enable() {
    (($# == 0)) || { vps_cmd_error "timer enable 不接受参数"; return 2; }
    vps_cmd_require_root || return $?
    tls_require_systemd || return $?
    tls_ensure_tools timer flock || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then return 0; fi
    vps_cmd_lock security-tls || return $?
    tls_timer_enable_quiet || return $?
    vps_cmd_success "已启用证书续期 timer"
}

tls_timer_disable() {
    (($# == 0)) || { vps_cmd_error "timer disable 不接受参数"; return 2; }
    vps_cmd_require_root || return $?
    tls_require_systemd || return $?
    tls_ensure_tools timer flock || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then return 0; fi
    vps_cmd_lock security-tls || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：停用 vpsctl-tls-renew.timer"
        return 0
    fi
    vps_cmd_run systemctl disable --now vpsctl-tls-renew.timer || true
    vps_cmd_success "已停用证书续期 timer"
}

tls_timer_dispatch() {
    local action="${1:-}"
    shift || true
    case "$action" in
        status) tls_timer_status "$@" ;;
        enable) tls_timer_enable "$@" ;;
        disable) tls_timer_disable "$@" ;;
        *) vps_cmd_error "timer 动作必须是 status|enable|disable"; return 2 ;;
    esac
}

tls_remove_timer_units() {
    if command -v systemctl >/dev/null 2>&1; then
        vps_cmd_run systemctl disable --now vpsctl-tls-renew.timer || true
        vps_cmd_run systemctl daemon-reload || true
    fi
    if tls_is_managed_unit "$TLS_TIMER_UNIT" || [[ ! -e "$TLS_TIMER_UNIT" ]]; then
        rm -f -- "$TLS_TIMER_UNIT"
    fi
    if tls_is_managed_unit "$TLS_TIMER_SERVICE" || [[ ! -e "$TLS_TIMER_SERVICE" ]]; then
        rm -f -- "$TLS_TIMER_SERVICE"
    fi
}

tls_uninstall() {
    local confirm=0 purge=0 confirm_purge=0
    while (($#)); do
        case "$1" in
            --confirm-uninstall)
                (($# >= 2)) || { vps_cmd_error "--confirm-uninstall 需要令牌"; return 2; }
                [[ "$2" == "$TLS_UNINSTALL_TOKEN" ]] || { vps_cmd_error "卸载确认令牌不匹配"; return 2; }
                confirm=1
                shift 2
                ;;
            --purge) purge=1; shift ;;
            --confirm-purge) confirm_purge=1; shift ;;
            *) vps_cmd_error "uninstall 未知选项：$1"; return 2 ;;
        esac
    done
    ((confirm)) || {
        vps_cmd_error "uninstall 需要 --confirm-uninstall $TLS_UNINSTALL_TOKEN"
        return 2
    }
    if ((purge)) && ((confirm_purge == 0)); then
        vps_cmd_error "purge 还需要 --confirm-purge"
        return 2
    fi
    vps_cmd_require_root || return $?
    tls_ensure_tools uninstall flock || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then return 0; fi
    vps_cmd_lock security-tls || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：卸载 TLS 续期 timer$( ((purge)) && printf ' 并清除证书库存' )"
        return 0
    fi
    tls_remove_timer_units
    if ((purge)); then
        rm -rf -- "$TLS_LIVE_DIR" "$TLS_CERTS_DIR" "$TLS_ACCOUNT_DIR" "$TLS_CRED_DIR"
        rm -f -- "$TLS_LEGO_META" "$TLS_GLOBAL_META"
        if [[ -f "$TLS_LEGO_BIN" && ! -L "$TLS_LEGO_BIN" ]]; then
            rm -f -- "$TLS_LEGO_BIN"
        fi
        vps_cmd_success "已卸载续期 timer 并清除证书库存；备份保留在 $TLS_BACKUP_LOGICAL"
    else
        vps_cmd_success "已卸载续期 timer；证书文件保持不变"
    fi
}
