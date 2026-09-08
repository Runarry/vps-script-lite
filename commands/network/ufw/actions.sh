# shellcheck shell=bash
# Recovery state is consumed by common.sh.
# shellcheck disable=SC2034

ufw_cli_status() {
    local json="${1:-0}" installed=false active=false rc=0 ipv6=false rules='[]' links='[]' defaults=''
    command -v ufw >/dev/null 2>&1 && installed=true
    if [[ "$installed" == true ]]; then
        vps_ufw_is_active && active=true || rc=$?
        ((rc <= 1)) || return "$rc"
    fi
    if vps_ufw_ipv6_available; then ipv6=true; fi
    if [[ "$json" == 1 ]]; then
        vps_ufw_require_tools || return $?
        [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
        rules="$(vps_ufw_inventory)" || return $?
        links="$(vps_ufw_links)" || return $?
        jq -n --argjson installed "$installed" --argjson active "$active" --argjson ipv6 "$ipv6" \
            --argjson rules "$rules" --argjson links "$links" \
            '{installed:$installed,active:$active,ipv6:$ipv6,rules:$rules,links:$links}'
        return 0
    fi
    printf 'UFW 安装：%s\nUFW 启用：%s\nIPv6 防护：%s\n' "$installed" "$active" "$ipv6"
    if [[ "$installed" == true ]]; then LC_ALL=C ufw status verbose || return 3; fi
    defaults="$(vps_cmd_system_path /etc/default/ufw)" || return $?
    vps_cmd_require_no_symlink_components "$defaults" || return $?
    if [[ -r "$defaults" ]]; then
        awk '/^(DEFAULT_(INPUT|OUTPUT|FORWARD)_POLICY|IPV6)=/ {print}' "$defaults"
    fi
    printf '\n规则（包括停用期间的持久规则）：rule list\n服务联动及解除状态：link list\n'
}

ufw_cli_copy_configuration() {
    local destination="$1" logical path name
    mkdir -p -- "$destination" || return 20
    chmod 0700 -- "$destination" || return 20
    for logical in /etc/ufw /etc/default/ufw; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        name=etc-ufw
        [[ "$logical" != /etc/default/ufw ]] || name=default-ufw
        if [[ -e "$path" ]]; then
            cp -a -- "$path" "$destination/$name" || return 20
        fi
    done
}

ufw_cli_restore_configuration() {
    local source="$1" logical path name
    for logical in /etc/ufw /etc/default/ufw; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        name=etc-ufw
        [[ "$logical" != /etc/default/ufw ]] || name=default-ufw
        if [[ -e "$source/$name" ]]; then
            mkdir -p -- "${path%/*}" || return 20
            if [[ -d "$source/$name" ]]; then
                mkdir -p -- "$path" || return 20
                cp -a -- "$source/$name/." "$path/" || return 20
            else
                cp -a -- "$source/$name" "$path" || return 20
            fi
        fi
    done
}

ufw_cli_install_locked() {
    local manager had_config=0 path
    ufw_cli_detect_init || return $?
    ufw_cli_remember_boot || return $?
    for path in /etc/ufw/ufw.conf /etc/ufw/user.rules /etc/ufw/user6.rules /etc/default/ufw; do
        [[ ! -e "$(vps_cmd_system_path "$path")" ]] || had_config=1
    done
    if ! command -v ufw >/dev/null 2>&1; then
        manager="$(vps_cmd_detect_package_manager)" || return $?
        if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
            ufw_cli_copy_configuration "$UFW_CLI_TMP/install-config" || return $?
        fi
        UFW_CLI_INSTALLED_PACKAGE="$manager"
        vps_cmd_install_packages "$manager" ufw || return $?
        if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
            hash -r
            ufw_cli_require_installed || return 20
            ufw_cli_restore_configuration "$UFW_CLI_TMP/install-config" || return $?
        fi
        # Reinstalling saved ENABLED=yes configuration must not activate UFW
        # through a package hook. Installation preserves policy, not activation.
        vps_cmd_run env LC_ALL=C ufw --force disable || return 20
    fi
    if ((had_config == 0)); then
        vps_cmd_run env LC_ALL=C ufw --force disable || return 20
        vps_cmd_run env LC_ALL=C ufw default deny incoming || return 20
        vps_cmd_run env LC_ALL=C ufw default allow outgoing || return 20
        vps_cmd_run env LC_ALL=C ufw default deny routed || return 20
    fi
    ufw_cli_persist enable || return 20
    UFW_CLI_INSTALLED_PACKAGE=''
    vps_cmd_success 'UFW 已安装；已有策略保留，新安装保持停用。请用 enable 启用并自动放行业务端口'
}

ufw_cli_remove_package() {
    local manager="$1" purge="${2:-0}" operation=remove
    [[ "$purge" != 1 ]] || operation=purge
    case "$manager" in
        apt-get) vps_cmd_run apt-get "$operation" -y ufw || return 20 ;;
        dnf5 | dnf | yum) vps_cmd_run "$manager" remove -y ufw || return 20 ;;
        apk) vps_cmd_run apk del ufw || return 20 ;;
        pacman) vps_cmd_run pacman -R --noconfirm ufw || return 20 ;;
        zypper) vps_cmd_run zypper --non-interactive remove ufw || return 20 ;;
        *) return 3 ;;
    esac
}

ufw_cli_enable_locked() {
    ufw_cli_require_installed || return $?
    ufw_cli_sync_locked force || return $?
    vps_cmd_run env LC_ALL=C ufw --force enable || return 20
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        vps_ufw_is_active || {
            vps_cmd_error 'UFW 未进入启用状态'
            return 20
        }
    fi
    ufw_cli_persist enable || return 20
    vps_cmd_success 'UFW 已启用并设置开机加载'
}

ufw_cli_disable_locked() {
    ufw_cli_require_installed || return $?
    vps_cmd_run env LC_ALL=C ufw --force disable || return 20
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        local status=0
        vps_ufw_is_active || status=$?
        [[ "$status" == 1 ]] || {
            vps_cmd_error 'UFW 停用验证失败'
            return 20
        }
    fi
    vps_cmd_success 'UFW 已停用，规则和联动状态已保留'
}

ufw_cli_reload_locked() {
    ufw_cli_require_installed || return $?
    vps_cmd_run env LC_ALL=C ufw reload || return 20
    vps_ufw_inventory >/dev/null || return $?
}

ufw_cli_reset_locked() {
    ufw_cli_require_installed || return $?
    vps_cmd_run env LC_ALL=C ufw --force reset || return 20
    vps_cmd_run env LC_ALL=C ufw default deny incoming || return 20
    vps_cmd_run env LC_ALL=C ufw default allow outgoing || return 20
    vps_cmd_run env LC_ALL=C ufw default deny routed || return 20
    # Match native UFW reset: remain disabled. Keep desired/detached ownership
    # so the next enable can stage attached service rules before activation.
    ufw_cli_sync_locked record-only || return $?
    vps_cmd_success 'UFW 已重置并保持停用；联动需求和解除状态保留，下一次 enable 会先放行业务'
}

ufw_cli_purge_configuration() {
    local logical path child
    # Other packages (notably OpenSSH) own application profiles here. Preserve
    # that directory even when the operator purges UFW's own configuration.
    path="$(vps_cmd_system_path /etc/ufw)" || return $?
    vps_cmd_require_no_symlink_components "$path" || return $?
    if [[ -d "$path" ]]; then
        for child in "$path"/* "$path"/.[!.]* "$path"/..?*; do
            [[ -e "$child" || -L "$child" ]] || continue
            [[ "$child" != "$path/applications.d" ]] || continue
            vps_cmd_require_no_symlink_components "$child" || return $?
            vps_cmd_run rm -rf -- "$child" || return 20
        done
    fi
    for logical in /etc/default/ufw /var/lib/vpsctl/network/ufw; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        vps_cmd_run rm -rf -- "$path" || return 20
    done
}

ufw_cli_uninstall_locked() {
    local purge="$1" manager='' installed=0 root backup='' path
    if command -v ufw >/dev/null 2>&1; then
        installed=1
        manager="$(vps_cmd_detect_package_manager)" || return $?
        ufw_cli_disable_locked || return $?
        ufw_cli_persist disable || return 20
    elif [[ "$purge" == 1 ]]; then
        # An earlier APT remove leaves conffile metadata even without a binary.
        # Purge that metadata so the next install recreates deleted defaults.
        manager="$(vps_cmd_detect_package_manager)" || return $?
        [[ "$manager" == apt-get ]] || manager=''
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        ufw_cli_copy_configuration "$UFW_CLI_TMP/uninstall-config" || return $?
        UFW_CLI_UNINSTALL_CONFIG="$UFW_CLI_TMP/uninstall-config"
        if [[ "$purge" == 1 ]]; then
            root="$(vps_cmd_system_path /var/lib/vpsctl/backups/network/ufw)" || return $?
            vps_cmd_require_no_symlink_components "$root" || return $?
            mkdir -p -- "$root" || return 20
            chmod 0700 -- "$root" || return 20
            backup="$(mktemp -d "$root/purge-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")" || return 20
            # Preserve the pre-disable state as well as every user rule.
            cp -a -- "$UFW_CLI_SNAPSHOT" "$backup/snapshot" || return 20
            vps_cmd_info "清理前恢复快照：$backup/snapshot"
        fi
    fi
    if [[ -n "$manager" ]]; then
        [[ "$installed" != 1 ]] || UFW_CLI_REMOVED_PACKAGE="$manager"
        ufw_cli_remove_package "$manager" "$purge" || return $?
    fi
    if [[ "$purge" == 1 ]]; then
        ufw_cli_purge_configuration || return $?
        vps_cmd_success 'UFW 和配置、联动状态已清理；恢复快照已保留'
    else
        [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]] || ufw_cli_restore_configuration "$UFW_CLI_TMP/uninstall-config" || return $?
        vps_cmd_success 'UFW 已卸载；配置和服务联动状态已保留，重新安装后可恢复使用'
    fi
    UFW_CLI_REMOVED_PACKAGE=''
}

ufw_cli_default_locked() {
    ufw_cli_require_installed || return $?
    vps_cmd_run env LC_ALL=C ufw default "$2" "$1" || return 20
}

ufw_cli_logging_locked() {
    ufw_cli_require_installed || return $?
    vps_cmd_run env LC_ALL=C ufw logging "$1" || return 20
}

ufw_cli_ipv6_locked() {
    local value="$1" config temporary active=0 status=0 attached
    ufw_cli_require_installed || return $?
    if [[ "$value" == off ]]; then
        attached="$(vps_ufw_links)" || return $?
        if jq -e 'any(.[]; (.detached | not) and any(.requirements[]; .family == "ipv6"))' <<<"$attached" >/dev/null; then
            vps_cmd_error 'IPv6 规则仍被服务引用；请先解除这些服务的联动再关闭 IPv6 防护'
            return 3
        fi
    fi
    config="$(vps_cmd_system_path /etc/default/ufw)" || return $?
    vps_cmd_require_no_symlink_components "$config" || return $?
    [[ -f "$config" ]] || return 3
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：设置 /etc/default/ufw IPV6=$value，并同步需求/重新加载"
        return 0
    fi
    vps_ufw_is_active && active=1 || status=$?
    ((status <= 1)) || return "$status"
    # Disable while the old IPv6 setting still applies, so switching to no
    # cannot leave an old live ip6tables ruleset behind.
    if ((active == 1)); then vps_cmd_run env LC_ALL=C ufw --force disable || return 20; fi
    temporary="$UFW_CLI_TMP/default-ufw"
    [[ "$value" != on ]] || value=yes
    [[ "$value" != off ]] || value=no
    awk -v value="$value" 'BEGIN {found=0} /^IPV6=/ {if (!found) print "IPV6=" value; found=1; next} {print} END {if (!found) print "IPV6=" value}' "$config" >"$temporary" || return 20
    vps_cmd_atomic_write /etc/default/ufw 0644 <"$temporary" || return $?
    if ((active == 1)); then
        ufw_cli_sync_locked force || return $?
        vps_cmd_run env LC_ALL=C ufw --force enable || return 20
        vps_ufw_is_active || return 20
    else
        ufw_cli_sync_locked record-only || return $?
    fi
}

ufw_cli_links_list() {
    local json="${1:-0}" links
    vps_ufw_require_tools || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
    links="$(vps_ufw_links)" || return $?
    if [[ "$json" == 1 ]]; then
        printf '%s\n' "$links"
        return 0
    fi
    printf '服务 OWNER\t联动状态\t需求数\n'
    jq -r '.[] | [.owner,(if .detached then "已解除（保持）" else "自动联动" end),(.requirements | length)] | @tsv' <<<"$links"
}

ufw_cli_link_locked() {
    local operation="$1" owner="$2" links
    links="$(vps_ufw_links)" || return $?
    jq -e --arg owner "$owner" 'any(.[]; .owner == $owner)' <<<"$links" >/dev/null || {
        vps_cmd_error '未知服务 OWNER；请先 sync 后通过 link list 查看'
        return 3
    }
    case "$operation" in
        detach) vps_ufw_link_set "$owner" detached || return $? ;;
        attach)
            vps_ufw_link_set "$owner" attached || return $?
            ufw_cli_sync_locked auto || return $?
            ;;
    esac
}

ufw_cli_app_locked() {
    ufw_cli_require_installed || return $?
    vps_cmd_run env LC_ALL=C ufw app "$@" || return 20
}
