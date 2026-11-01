# shellcheck shell=bash
# shellcheck disable=SC2034
NFT_CLI_ARGS=()
NFT_CLI_BUSINESS_FDS=()
NFT_CLI_BACKUP=''
NFT_CLI_LOCKED=0
NFT_CLI_RECOVER=0
NFT_CLI_START_AFTER_UNLOCK=0
NFT_CLI_INIT=''
NFT_CLI_PATHS=(/usr/local/lib/vpsctl/nftables /etc/systemd/system/vpsctl-nftables.service /etc/init.d/vpsctl-nftables)

nft_cli_parse_globals() {
    NFT_CLI_ARGS=()
    while (($#)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;; --install-deps) VPSCTL_INSTALL_DEPS=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;; --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;; --verbose) VPSCTL_VERBOSE=1 ;; --no-color) VPSCTL_NO_COLOR=1 ;;
            --)
                shift
                NFT_CLI_ARGS=("$@")
                return 0
                ;;
            *)
                NFT_CLI_ARGS=("$@")
                return 0
                ;;
        esac
        shift
    done
}

nft_cli_valid_port() { [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
nft_cli_valid_ports() { vps_nft_validate_port "$1"; }
nft_cli_valid_address() { vps_nft_validate_source "$1" "${2:-both}"; }

nft_cli_read_tools() {
    command -v jq >/dev/null 2>&1 && return 0
    vps_cmd_error '此视图需要 jq；请先安装或启用防火墙'
    return 3
}

nft_cli_detect_init() {
    NFT_CLI_INIT="${VPSCTL_ENV_INIT:-unknown}"
    case "$NFT_CLI_INIT" in
        systemd) ;; openrc | openrc-init) NFT_CLI_INIT=openrc ;;
        *)
            if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
                NFT_CLI_INIT=systemd
            elif command -v rc-service >/dev/null 2>&1; then
                NFT_CLI_INIT=openrc
            else
                vps_cmd_error '开机加载需要 systemd 或 OpenRC'
                return 3
            fi
            ;;
    esac
}

nft_cli_boot_state() {
    case "$NFT_CLI_INIT" in
        systemd) systemctl is-enabled vpsctl-nftables.service 2>/dev/null || true ;;
        openrc)
            if [[ -e "$(vps_cmd_system_path /etc/runlevels/default/vpsctl-nftables)" ]]; then printf 'enabled\n'; else printf 'disabled\n'; fi
            ;;
    esac
}

nft_cli_runtime_active() {
    local status=0
    [[ "$NFT_CLI_INIT" == systemd ]] || return 1
    if systemctl is-active --quiet vpsctl-nftables.service; then return 0; else status=$?; fi
    case "$status" in 3 | 4) return 1 ;; *) return 20 ;; esac
}

nft_cli_stop_runtime() {
    local status=0
    if nft_cli_runtime_active; then
        # Our generated oneshot has no ExecStop and never calls back into nft.
        vps_cmd_run systemctl stop vpsctl-nftables.service || return 20
    else
        status=$?
        [[ "$status" == 1 ]] || return "$status"
    fi
}

nft_cli_persist() {
    local operation="$1" unit
    nft_cli_detect_init || return $?
    if [[ "$operation" == disable ]]; then
        unit=/etc/systemd/system/vpsctl-nftables.service
        [[ "$NFT_CLI_INIT" != openrc ]] || unit=/etc/init.d/vpsctl-nftables
        [[ -f "$(vps_cmd_system_path "$unit")" ]] || return 0
    fi
    case "$NFT_CLI_INIT:$operation" in
        systemd:enable)
            vps_cmd_run systemctl daemon-reload && vps_cmd_run systemctl enable vpsctl-nftables.service
            ;;
        systemd:disable)
            vps_cmd_run systemctl disable vpsctl-nftables.service
            ;;
        openrc:enable) vps_cmd_run rc-update add vpsctl-nftables default ;;
        openrc:disable)
            [[ -e "$(vps_cmd_system_path /etc/runlevels/default/vpsctl-nftables)" ]] || return 0
            vps_cmd_run rc-update del vpsctl-nftables default
            ;;
    esac
}

nft_cli_business_lock() {
    local directory feature descriptor path
    directory="$(vps_cmd_system_path /run/vpsctl)" || return $?
    vps_cmd_require_no_symlink_components "$directory" || return $?
    mkdir -p -- "$directory" || return 20
    for feature in security-access proxy security-tls security-fail2ban tcping iperf3 po0-relay; do
        path="$directory/$feature.lock"
        [[ "$feature" != po0-relay ]] || path="$(vps_cmd_system_path /run/lock/po0-relay.lock)"
        vps_cmd_require_no_symlink_components "$path" || return $?
        mkdir -p -- "${path%/*}" || return 20
        exec {descriptor}>"$path" || return 20
        NFT_CLI_BUSINESS_FDS+=("$descriptor")
        if ! flock -n "$descriptor"; then
            vps_cmd_error "$feature 操作正在运行"
            return 3
        fi
    done
}

nft_cli_business_unlock() {
    local index descriptor
    for ((index = ${#NFT_CLI_BUSINESS_FDS[@]} - 1; index >= 0; index--)); do
        descriptor="${NFT_CLI_BUSINESS_FDS[$index]}"
        flock -u "$descriptor" 2>/dev/null || true
        exec {descriptor}>&-
    done
    NFT_CLI_BUSINESS_FDS=()
}

nft_cli_no_ssh_transaction() {
    local active
    active="$(vps_cmd_system_path /var/lib/vpsctl/security/access/active)" || return $?
    vps_cmd_require_no_symlink_components "$active" || return $?
    [[ ! -e "$active" ]] && return 0
    vps_cmd_error '存在未完成 SSH 访问事务；请先 commit 或 abort 再执行全局防火墙操作'
    return 3
}

nft_cli_backup_files() {
    local target="$1" logical path index=0 active=0 status=0
    mkdir -p -- "$target/files" || return 20
    for logical in "${NFT_CLI_PATHS[@]}"; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        if [[ -e "$path" ]]; then cp -a -- "$path" "$target/files/$index" || return 20; fi
        index=$((index + 1))
    done
    nft_cli_boot_state >"$target/boot" || return 20
    if nft_cli_runtime_active; then active=1; else
        status=$?
        [[ "$status" == 1 ]] || return "$status"
    fi
    printf '%s\n' "$active" >"$target/runtime-active" || return 20
    printf '%s\n' "$NFT_CLI_INIT" >"$target/init"
}

nft_cli_restore_files() {
    local source="$1" logical path index=0
    [[ -d "$source/files" && -f "$source/boot" && -f "$source/init" ]] || return 3
    NFT_CLI_INIT="$(<"$source/init")"
    case "$NFT_CLI_INIT" in systemd | openrc) ;; *) return 3 ;; esac
    NFT_CLI_START_AFTER_UNLOCK=0
    # Remove current boot links while the installed unit still exists.
    nft_cli_persist disable || return 20
    nft_cli_stop_runtime || return $?
    for logical in "${NFT_CLI_PATHS[@]}"; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        rm -rf -- "$path" || return 20
        if [[ -e "$source/files/$index" ]]; then
            mkdir -p -- "${path%/*}" && cp -a -- "$source/files/$index" "$path" || return 20
        fi
        index=$((index + 1))
    done
    if [[ "$NFT_CLI_INIT" == systemd ]]; then vps_cmd_run systemctl daemon-reload || return 20; fi
    case "$(<"$source/boot")" in
        enabled) nft_cli_persist enable || return 20 ;;
        enabled-runtime) vps_cmd_run systemctl enable --runtime vpsctl-nftables.service || return 20 ;;
        *) nft_cli_persist disable || return 20 ;;
    esac
    if [[ "$NFT_CLI_INIT" == systemd && -f "$source/runtime-active" && "$(<"$source/runtime-active")" == 1 ]]; then
        NFT_CLI_START_AFTER_UNLOCK=1
    fi
}

nft_cli_recover() {
    local backup="$1" status=0 prepared
    # Clear/restore only our table; old firewall state is restored separately.
    if [[ -f "$backup/po0/present" ]]; then
        nft_cli_po0_source || return 30
        prepared="$backup/recovery"
        vps_nft_prepare_restore "$backup/snapshot" "$prepared" || return 30
        cat -- "$backup/po0/runtime-restore.nft" >>"$prepared/batch.nft" || return 30
        nft -c -f "$prepared/batch.nft" && nft -f "$prepared/batch.nft" || return 30
        vps_nft_commit_prepared "$prepared" || status=30
        po0_coop_restore "$backup/po0" || status=30
    else vps_nft_restore "$backup/snapshot" || status=30; fi
    nft_cli_restore_files "$backup" || status=30
    [[ ! -d "$backup/legacy" ]] || nft_cli_legacy_restore "$backup/legacy" || status=30
    return "$status"
}

nft_cli_cleanup() {
    if [[ "$NFT_CLI_RECOVER" == 1 && -n "$NFT_CLI_BACKUP" ]]; then
        nft_cli_recover "$NFT_CLI_BACKUP" || vps_cmd_error "恢复未完成：$NFT_CLI_BACKUP"
        NFT_CLI_RECOVER=0
    fi
    if [[ "$NFT_CLI_LOCKED" == 1 ]]; then
        vps_nft_unlock || true
        NFT_CLI_LOCKED=0
    fi
    nft_cli_business_unlock
    if [[ "$NFT_CLI_START_AFTER_UNLOCK" == 1 ]]; then
        NFT_CLI_START_AFTER_UNLOCK=0
        vps_cmd_run systemctl start vpsctl-nftables.service || {
            vps_cmd_error "规则与文件已恢复，但专用服务启动失败；快照：$NFT_CLI_BACKUP"
            return 30
        }
    fi
}

nft_cli_change() {
    local global="$1" callback="$2" status=0 root
    shift 2
    vps_cmd_require_root || return $?
    vps_nft_require_tools || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        [[ "$global" != 1 ]] || nft_cli_no_ssh_transaction || return $?
        "$callback" "$@"
        return $?
    fi
    NFT_CLI_BACKUP=''
    NFT_CLI_RECOVER=0
    NFT_CLI_START_AFTER_UNLOCK=0
    trap nft_cli_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ "$global" == 1 ]]; then
        if nft_cli_business_lock && nft_cli_no_ssh_transaction; then
            :
        else
            status=$?
            nft_cli_cleanup
            return "$status"
        fi
    fi
    vps_nft_lock || {
        status=$?
        nft_cli_cleanup
        return "$status"
    }
    NFT_CLI_LOCKED=1
    nft_cli_detect_init || {
        status=$?
        nft_cli_cleanup
        return "$status"
    }
    root="$(vps_cmd_system_path /var/lib/vpsctl/backups/network/nftables)" || return $?
    vps_cmd_require_no_symlink_components "$root" || {
        nft_cli_cleanup
        return 3
    }
    if ! { mkdir -p -- "$root" && chmod 0700 -- "$root"; }; then
        nft_cli_cleanup
        return 20
    fi
    NFT_CLI_BACKUP="$(mktemp -d "$root/change-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")" || {
        nft_cli_cleanup
        return 20
    }
    if vps_nft_snapshot "$NFT_CLI_BACKUP/snapshot" && nft_cli_backup_files "$NFT_CLI_BACKUP"; then
        :
    else
        status=$?
        nft_cli_cleanup
        return "$status"
    fi
    NFT_CLI_RECOVER=1
    "$callback" "$@" || status=$?
    if ((status != 0)); then
        if nft_cli_recover "$NFT_CLI_BACKUP"; then
            vps_cmd_warning '操作失败，已恢复防火墙和专用服务'
        else
            vps_cmd_error "恢复未完成，快照：$NFT_CLI_BACKUP"
            status=30
        fi
    else vps_cmd_info "恢复快照：$NFT_CLI_BACKUP"; fi
    NFT_CLI_RECOVER=0
    nft_cli_cleanup || status=30
    return "$status"
}

nft_cli_save_json() {
    local json="$1" candidate
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        nft_cli_validate_json "$json" || return $?
        vps_cmd_info '演练：验证、原子保存状态并更新自有 nftables 表'
        return 0
    fi
    candidate="$NFT_CLI_BACKUP/candidate.json"
    (
        umask 077
        printf '%s\n' "$json" >"$candidate"
    ) || return 20
    vps_nft_save_state "$candidate" && vps_nft_apply
}

# Validate a dry-run candidate without creating temporary files or touching state.
nft_cli_validate_json() {
    local json="$1" record family value
    vps_nft_init || return $?
    jq -e -f "$VPS_NFT_LIB_DIR/schema.jq" <<<"$json" >/dev/null || return 2
    while IFS= read -r record; do
        family="$(jq -r '.family' <<<"$record")"
        while IFS= read -r value; do
            vps_nft_validate_source "$value" "$family" || return 2
        done < <(jq -r '.source, (.destination // empty), (.original_destination // empty)' <<<"$record")
    done < <(jq -c '.rules[],.limits[],.requirements[]' <<<"$json")
}
