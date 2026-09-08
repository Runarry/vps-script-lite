# shellcheck shell=bash
# Shared scalars are consumed by the sibling command modules.
# shellcheck disable=SC2034
# Private command helpers. All shared firewall state lives in lib/ufw.sh.

UFW_CLI_ARGS=()
UFW_CLI_BUSINESS_FDS=()
UFW_CLI_TMP=''
UFW_CLI_SNAPSHOT=''
UFW_CLI_RECOVERY_NEEDED=0
UFW_CLI_LOCKED=0
UFW_CLI_INIT=''
UFW_CLI_BOOT_BEFORE=''
UFW_CLI_BOOT_CHANGED=0
UFW_CLI_REMOVED_PACKAGE=''
UFW_CLI_INSTALLED_PACKAGE=''
UFW_CLI_UNINSTALL_CONFIG=''

ufw_cli_parse_globals() {
    UFW_CLI_ARGS=()
    while (($#)); do
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
                UFW_CLI_ARGS=("$@")
                return 0
                ;;
            *)
                UFW_CLI_ARGS=("$@")
                return 0
                ;;
        esac
        shift
    done
}

ufw_cli_require_installed() {
    command -v ufw >/dev/null 2>&1 && return 0
    vps_cmd_error '尚未安装 UFW；请先运行 vpsctl network ufw install'
    return 3
}

ufw_cli_detect_init() {
    UFW_CLI_INIT="${VPSCTL_ENV_INIT:-unknown}"
    case "$UFW_CLI_INIT" in
        openrc | openrc-init) UFW_CLI_INIT=openrc ;;
        systemd) ;;
        *)
            if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system || "${VPSCTL_TESTING:-0}" == 1 ]]; then
                UFW_CLI_INIT=systemd
            elif command -v rc-service >/dev/null 2>&1; then
                UFW_CLI_INIT=openrc
            else
                vps_cmd_error 'UFW 持久化需要 systemd 或 OpenRC'
                return 3
            fi
            ;;
    esac
}

ufw_cli_persist() {
    local operation="$1"
    ufw_cli_detect_init || return $?
    ufw_cli_remember_boot || return $?
    UFW_CLI_BOOT_CHANGED=1
    case "$UFW_CLI_INIT:$operation" in
        systemd:enable) vps_cmd_run systemctl enable ufw.service ;;
        systemd:disable) vps_cmd_run systemctl disable ufw.service ;;
        openrc:enable) vps_cmd_run rc-update add ufw default ;;
        openrc:disable) vps_cmd_run rc-update del ufw default ;;
    esac
}

ufw_cli_remember_boot() {
    local output path
    [[ -z "$UFW_CLI_BOOT_BEFORE" && "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    case "$UFW_CLI_INIT" in
        systemd)
            output="$(systemctl is-enabled ufw.service 2>/dev/null || true)"
            case "$output" in enabled | enabled-runtime) UFW_CLI_BOOT_BEFORE=enabled ;; disabled) UFW_CLI_BOOT_BEFORE=disabled ;; not-found | '') UFW_CLI_BOOT_BEFORE=absent ;; *) UFW_CLI_BOOT_BEFORE=unchanged ;; esac
            ;;
        openrc)
            path="$(vps_cmd_system_path /etc/runlevels/default/ufw)" || return $?
            if [[ -e "$path" || -L "$path" ]]; then UFW_CLI_BOOT_BEFORE=enabled; else UFW_CLI_BOOT_BEFORE=disabled; fi
            ;;
    esac
}

ufw_cli_recover() {
    if [[ -n "$UFW_CLI_INSTALLED_PACKAGE" ]] && command -v ufw >/dev/null 2>&1; then
        vps_cmd_warning '安装未完成，正在停用并移除本次安装的 UFW 软件包'
        vps_cmd_run env LC_ALL=C ufw --force disable || return 30
        # An empty snapshot removes new conffiles. Purge their package metadata
        # too, so retrying installation can recreate them instead of keeping rc.
        ufw_cli_remove_package "$UFW_CLI_INSTALLED_PACKAGE" 1 || return 30
        hash -r
        ufw_cli_restore_configuration "$UFW_CLI_TMP/install-config" || return 30
    fi
    if [[ -n "$UFW_CLI_REMOVED_PACKAGE" ]] && ! command -v ufw >/dev/null 2>&1; then
        vps_cmd_warning '卸载未完成，正在重新安装原 UFW 软件包以恢复防火墙'
        vps_cmd_install_packages "$UFW_CLI_REMOVED_PACKAGE" ufw || return 30
        hash -r
    fi
    if [[ -n "$UFW_CLI_UNINSTALL_CONFIG" ]]; then
        # Package hooks and a partial purge may touch files outside the shared
        # snapshot. Restore the complete saved tree before its pre-disable state.
        ufw_cli_restore_configuration "$UFW_CLI_UNINSTALL_CONFIG" || return 30
    fi
    vps_ufw_restore "$UFW_CLI_SNAPSHOT" || return 30
    if [[ "$UFW_CLI_BOOT_CHANGED" == 1 ]]; then
        case "$UFW_CLI_INIT:$UFW_CLI_BOOT_BEFORE" in
            systemd:enabled) vps_cmd_run systemctl enable ufw.service || return 30 ;;
            systemd:disabled) vps_cmd_run systemctl disable ufw.service || return 30 ;;
            openrc:enabled) vps_cmd_run rc-update add ufw default || return 30 ;;
            openrc:disabled) vps_cmd_run rc-update del ufw default || return 30 ;;
        esac
    fi
}

# The business commands use one vps_cmd lock slot. Acquire the same lock files
# using independent descriptors so the shared library never disturbs that slot.
# This order is also used by enable, attach and other global policy changes.
ufw_cli_business_lock() {
    local directory feature descriptor
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    directory="$(vps_cmd_system_path /run/vpsctl)" || return $?
    vps_cmd_require_no_symlink_components "$directory" || return $?
    mkdir -p -- "$directory" || return 20
    for feature in security-access proxy security-tls; do
        vps_cmd_require_no_symlink_components "$directory/$feature.lock" || return $?
        exec {descriptor}>"$directory/$feature.lock" || return 20
        UFW_CLI_BUSINESS_FDS+=("$descriptor")
        if ! flock -n "$descriptor"; then
            vps_cmd_error "${feature} 操作正在运行；本次 UFW 操作尚未修改系统"
            return 3
        fi
    done
}

ufw_cli_business_unlock() {
    local index descriptor
    for ((index = ${#UFW_CLI_BUSINESS_FDS[@]} - 1; index >= 0; index--)); do
        descriptor="${UFW_CLI_BUSINESS_FDS[$index]}"
        flock -u "$descriptor" 2>/dev/null || true
        exec {descriptor}>&-
    done
    UFW_CLI_BUSINESS_FDS=()
}

ufw_cli_no_ssh_transaction() {
    local active
    active="$(vps_cmd_system_path /var/lib/vpsctl/security/access/active)" || return $?
    vps_cmd_require_no_symlink_components "$active" || return $?
    [[ ! -e "$active" ]] && return 0
    vps_cmd_error '存在未完成 SSH 访问事务；请先 commit 或 abort 再执行此全局防火墙操作'
    return 3
}

ufw_cli_cleanup() {
    if [[ "$UFW_CLI_RECOVERY_NEEDED" == 1 && -n "$UFW_CLI_SNAPSHOT" ]]; then
        if ufw_cli_recover; then
            UFW_CLI_RECOVERY_NEEDED=0
        else
            vps_cmd_error "UFW 自动恢复失败，保留恢复快照：$UFW_CLI_SNAPSHOT"
        fi
    fi
    if [[ "$UFW_CLI_LOCKED" == 1 ]]; then
        vps_ufw_unlock || true
        UFW_CLI_LOCKED=0
    fi
    ufw_cli_business_unlock
    if [[ "$UFW_CLI_RECOVERY_NEEDED" == 0 && -n "$UFW_CLI_TMP" ]]; then
        rm -rf -- "$UFW_CLI_TMP"
        UFW_CLI_TMP=''
    fi
}

# Run one complete command transaction. GLOBAL=1 obtains business locks first;
# BLOCK_PENDING=1 refuses changes that could invalidate SSH's rollback proof.
ufw_cli_change() {
    local global="$1" block_pending="$2" callback="$3" status=0
    shift 3
    UFW_CLI_BOOT_BEFORE=''
    UFW_CLI_BOOT_CHANGED=0
    UFW_CLI_REMOVED_PACKAGE=''
    UFW_CLI_INSTALLED_PACKAGE=''
    UFW_CLI_UNINSTALL_CONFIG=''
    vps_cmd_require_root || return $?
    vps_ufw_require_tools || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info '依赖仅完成安装计划；安装后请重新运行'
        return 0
    fi
    trap ufw_cli_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ "$global" == 1 ]]; then
        ufw_cli_business_lock || {
            status=$?
            ufw_cli_cleanup
            return "$status"
        }
    fi
    if [[ "$block_pending" == 1 ]]; then
        ufw_cli_no_ssh_transaction || {
            status=$?
            ufw_cli_cleanup
            return "$status"
        }
    fi
    vps_ufw_lock || {
        status=$?
        ufw_cli_cleanup
        return "$status"
    }
    UFW_CLI_LOCKED=1
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        UFW_CLI_TMP="$(mktemp -d /tmp/vpsctl-ufw.XXXXXX)" || {
            ufw_cli_cleanup
            return 20
        }
        UFW_CLI_SNAPSHOT="$UFW_CLI_TMP/snapshot"
        vps_ufw_snapshot "$UFW_CLI_SNAPSHOT" || {
            status=$?
            ufw_cli_cleanup
            return "$status"
        }
        UFW_CLI_RECOVERY_NEEDED=1
    fi
    "$callback" "$@" || status=$?
    if ((status == 0)); then
        UFW_CLI_RECOVERY_NEEDED=0
    elif [[ "$UFW_CLI_RECOVERY_NEEDED" == 1 ]]; then
        if ufw_cli_recover; then
            UFW_CLI_RECOVERY_NEEDED=0
            vps_cmd_warning '操作失败，已恢复原 UFW 配置和联动状态'
        else
            vps_cmd_error "恢复失败，快照保留在 $UFW_CLI_SNAPSHOT"
            status=30
        fi
    fi
    # Do not retry a failed restore from the EXIT trap; retain the evidence.
    if ((status == 30)) && [[ "$UFW_CLI_RECOVERY_NEEDED" == 1 ]]; then
        UFW_CLI_SNAPSHOT=''
    fi
    ufw_cli_cleanup
    return "$status"
}

ufw_cli_strong_confirm() {
    local approved="$1" token="$2" prompt="$3"
    [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]] && return 0
    if [[ "${UFW_CLI_INTERACTIVE:-0}" == 1 ]]; then
        vps_cmd_confirm_token "$prompt" "$token"
    elif [[ "$approved" != 1 ]]; then
        vps_cmd_error "${prompt}；非交互模式需显式确认选项（--yes 不能代替）"
        return 3
    fi
}

ufw_cli_valid_port() {
    [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

ufw_cli_valid_ports() {
    local value="$1" item start end slots=0
    local -a items=()
    IFS=, read -r -a items <<<"$value"
    [[ -n "$value" && "$value" != *, && "$value" != ,* && "$value" != *,,* ]] || return 2
    for item in "${items[@]}"; do
        if [[ "$item" == *:* ]]; then
            [[ "$item" =~ ^([0-9]{1,5}):([0-9]{1,5})$ ]] || return 2
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            ufw_cli_valid_port "$start" && ufw_cli_valid_port "$end" && ((10#$start <= 10#$end)) || return 2
            slots=$((slots + 2))
        else
            ufw_cli_valid_port "$item" || return 2
            slots=$((slots + 1))
        fi
    done
    # UFW uses xt_multiport's 15 slots; a single range uses its regular matcher.
    ((${#items[@]} == 1 || slots <= 15))
}

ufw_cli_valid_address() {
    local value="$1" address prefix part
    local -a parts=()
    [[ "$value" == any ]] && return 0
    [[ "$value" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || return 2
    address="${value%%/*}"
    prefix=''
    [[ "$value" != */* ]] || prefix="${value##*/}"
    if [[ "$address" == *:* ]]; then
        [[ "$address" == *:*:* && ${#address} -le 45 ]] || return 2
        [[ -z "$prefix" ]] || ((10#$prefix <= 128)) || return 2
    else
        [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 2
        IFS=. read -r -a parts <<<"$address"
        for part in "${parts[@]}"; do ((10#$part <= 255)) || return 2; done
        [[ -z "$prefix" ]] || ((10#$prefix <= 32)) || return 2
    fi
}
