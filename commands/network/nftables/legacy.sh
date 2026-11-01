# shellcheck shell=bash
# One-time retirement and recovery of the previous firewall frontends.
# The caller owns the business/firewall locks and the surrounding nft snapshot.

nft_cli_legacy_paths() {
    printf '%s\n' /etc/ufw /etc/default/ufw /var/lib/ufw \
        /var/lib/vpsctl/network/ufw /etc/vpsctl/rfw.conf \
        /etc/systemd/system/rfw.service /usr/local/bin/rfw \
        /var/lib/vpsctl/network/rfw /etc/fail2ban/jail.d/99-vpsctl-sshd.local \
        /var/lib/vpsctl/security/fail2ban/metadata /var/lib/vpsctl/security/fail2ban/config.sha256 \
        /usr/local/libexec/vpsctl-proxy-runtime
}

nft_cli_legacy_managed_rfw() {
    local file="$1" first=''
    [[ -f "$file" && ! -L "$file" ]] || return 1
    IFS= read -r first <"$file" || return 1
    [[ "$first" == '# Managed by vpsctl (rfw)' ]]
}

nft_cli_legacy_unit_state() {
    local service="$1" field="$2" result
    if [[ "${NFT_LEGACY_INIT:-}" == openrc ]]; then
        if [[ "$field" == active ]]; then
            if rc-service "$service" status >/dev/null 2>&1; then printf active; else printf inactive; fi
        elif rc-update show default 2>/dev/null | awk -v s="$service" '$1 == s {found=1} END {exit !found}'; then
            printf enabled
        else printf disabled; fi
        return 0
    fi
    result="$(systemctl "is-$field" "$service.service" 2>/dev/null || true)"
    case "$result" in active | inactive | failed | enabled | enabled-runtime | disabled | static | masked | not-found | '') printf '%s' "${result:-not-found}" ;;
    *)
        vps_cmd_error "无法识别旧防火墙服务状态：$service $field $result"
        return 3
        ;;
    esac
}

# Capture a self-contained Debian package so restoring a purged UFW does not
# require an old repository version or an Internet connection.
nft_cli_legacy_backup_deb() {
    local directory="$1" staging="$1/package-root" path source name
    mkdir -p -- "$staging/DEBIAN" || return 20
    dpkg-query -W -f='Package: ${binary:Package}\nVersion: ${Version}\nArchitecture: ${Architecture}\nMaintainer: ${Maintainer}\nDepends: ${Depends}\nDescription: ${Description}\n' ufw >"$staging/DEBIAN/control" || return 20
    while IFS= read -r path; do
        [[ "$path" == /* && "$path" != / && "$path" != /. ]] || continue
        source="$(vps_cmd_system_path "$path")" || return $?
        [[ -e "$source" || -L "$source" ]] || continue
        if [[ -d "$source" && ! -L "$source" ]]; then
            mkdir -p -- "$staging$path" || return 20
        else
            mkdir -p -- "${staging}${path%/*}" || return 20
            cp -a -- "$source" "$staging$path" || return 20
        fi
    done < <(dpkg-query -L ufw)
    for name in conffiles config templates preinst postinst prerm postrm triggers; do
        source="$(vps_cmd_system_path "/var/lib/dpkg/info/ufw.$name")" || return $?
        [[ ! -f "$source" ]] || cp -p -- "$source" "$staging/DEBIAN/$name" || return 20
    done
    # dpkg needs installed conffiles in the archive; do not retain stale hashes
    # from the old package because this is a backup of the actual installed files.
    dpkg-deb --build --root-owner-group "$staging" "$directory/ufw-recovery.deb" >/dev/null || return 20
    rm -rf -- "$staging" || return 20
}

nft_cli_legacy_sysctls() {
    local file key value
    file="$(vps_cmd_system_path /etc/ufw/sysctl.conf)" || return $?
    {
        printf '%s\n' net.ipv4.ip_forward net.ipv6.conf.all.forwarding
        if [[ -f "$file" ]]; then
            awk -F= '/^[[:space:]]*net[./][a-zA-Z0-9_./]+[[:space:]]*=/ {gsub(/[[:space:]]/, "", $1); gsub(/\//, ".", $1); print $1}' "$file"
        fi
    } | sort -u | while IFS= read -r key; do
        [[ "$key" =~ ^net\.[a-zA-Z0-9_.]+$ ]] || return 10
        if value="$(sysctl -n "$key" 2>/dev/null)"; then printf '%s\t%s\n' "$key" "$value"; fi
    done
}

nft_cli_legacy_restore_sysctls() {
    local directory="$1" key value status=0
    [[ -f "$directory/sysctls.tsv" ]] || return 0
    while IFS=$'\t' read -r key value; do
        [[ "$key" =~ ^net\.[a-zA-Z0-9_.]+$ && -n "$value" && "$value" != *$'\n'* ]] || return 10
        vps_cmd_run sysctl -q -w "$key=$value" || status=20
    done <"$directory/sysctls.tsv"
    return "$status"
}

nft_cli_legacy_check_fail2ban() {
    local config digest expected actual
    NFT_LEGACY_F2B=false NFT_LEGACY_F2B_ACTIVE=false
    config="$(vps_cmd_system_path /etc/fail2ban/jail.d/99-vpsctl-sshd.local)" || return $?
    [[ -f "$config" ]] || return 0
    vps_cmd_require_no_symlink_components "$config" || return $?
    grep -Fqx '# Managed by vpsctl security fail2ban.' "$config" || return 0
    digest="$(vps_cmd_system_path /var/lib/vpsctl/security/fail2ban/config.sha256)" || return $?
    vps_cmd_require_no_symlink_components "$digest" || return $?
    [[ -f "$digest" ]] || {
        vps_cmd_error '受管 Fail2ban 缺少配置校验信息'
        return 10
    }
    expected="$(<"$digest")"
    actual="$(sha256sum -- "$config")" || return 20
    [[ "$expected" == "${actual%% *}" ]] || {
        vps_cmd_error '受管 Fail2ban 配置已被外部修改，尚未切换旧防火墙'
        return 10
    }
    NFT_LEGACY_F2B=true
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then NFT_LEGACY_F2B_ACTIVE=true; fi
}

nft_cli_legacy_migrate_fail2ban() {
    local directory="$1" config metadata candidate digest
    jq -e '.fail2ban.managed' "$directory/state.json" >/dev/null || return 0
    config="$(vps_cmd_system_path /etc/fail2ban/jail.d/99-vpsctl-sshd.local)" || return $?
    if awk -F= '/^[[:space:]]*banaction[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); if ($2=="nftables-multiport") found=1} END {exit !found}' "$config"; then return 0; fi
    metadata="$(vps_cmd_system_path /var/lib/vpsctl/security/fail2ban/metadata)" || return $?
    candidate="$directory/fail2ban.candidate"
    awk 'BEGIN {n=0} /^[[:space:]]*banaction[[:space:]]*=/ {print "banaction = nftables-multiport"; n++; next} {print} END {if (n!=1) exit 10}' "$config" >"$candidate" || return 10
    vps_cmd_atomic_write /etc/fail2ban/jail.d/99-vpsctl-sshd.local 0600 <"$candidate" || return $?
    digest="$(sha256sum -- "$candidate")" || return 20
    digest="${digest%% *}"
    printf '%s\n' "$digest" | vps_cmd_atomic_write /var/lib/vpsctl/security/fail2ban/config.sha256 0600 || return $?
    vps_cmd_require_no_symlink_components "$metadata" || return $?
    awk -F '\t' -v hash="$digest" 'BEGIN {OFS="\t"} $1=="config_sha256" {$2=hash} $1=="banaction" {$2="nftables-multiport"} {print}' "$metadata" >"$directory/fail2ban.metadata" || return 20
    vps_cmd_atomic_write /var/lib/vpsctl/security/fail2ban/metadata 0600 <"$directory/fail2ban.metadata" || return $?
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client -t >/dev/null || return 20
        if jq -e '.fail2ban.active' "$directory/state.json" >/dev/null; then
            vps_cmd_run fail2ban-client reload --restart sshd || return 20
            fail2ban-client ping >/dev/null && fail2ban-client status sshd >/dev/null || return 20
        fi
    fi
}

nft_cli_legacy_migrate_proxy_runtime() {
    local runtime helper relative source directory root="${NFT_CLI_PROJECT_ROOT:-}" first=''
    local -a files=(lib/command.sh lib/ui.sh lib/offline.sh lib/nftables.sh
        lib/nftables/schema.jq lib/nftables/render.jq lib/nftables/reconcile.jq lib/nftables/transactions.sh)
    runtime="$(vps_cmd_system_path /usr/local/libexec/vpsctl-proxy-runtime)" || return $?
    [[ -d "$runtime" ]] || return 0
    helper="$(vps_cmd_system_path /usr/local/libexec/vpsctl-proxy-forward-refresh)" || return $?
    vps_cmd_require_no_symlink_components "$helper" || return $?
    [[ -f "$helper" ]] || {
        vps_cmd_error '中转运行时存在但缺少受管 helper，无法自动升级'
        return 3
    }
    IFS= read -r first <"$helper" || return 10
    case "$first" in '#!/usr/bin/env bash' | '#!/bin/bash' | '#!/bin/sh') ;; *) return 3 ;; esac
    grep -Fqx '# Managed by vpsctl proxy relay-forward.' "$helper" || return 3
    [[ -n "$root" && -f "$root/lib/registry.sh" ]] || return 3
    # Fixed bundle metadata supplies the deployment list, never another command.
    # shellcheck source=../../../lib/registry.sh
    source "$root/lib/registry.sh"
    while IFS= read -r relative; do files+=("$relative"); done < <(vps_registry_bundle_files service-proxy)
    # Prove all current files are available before replacing any old runtime.
    for relative in "${files[@]}"; do
        source="$root/$relative"
        vps_cmd_require_no_symlink_components "$source" || return $?
        [[ -f "$source" && -r "$source" ]] || {
            vps_cmd_error "缺少中转升级依赖：$relative"
            return 3
        }
    done
    for relative in "${files[@]}"; do
        directory="$runtime/${relative%/*}"
        vps_cmd_require_no_symlink_components "$directory" || return $?
        mkdir -p -- "$directory" || return 20
        vps_cmd_atomic_write "/usr/local/libexec/vpsctl-proxy-runtime/$relative" 0644 <"$root/$relative" || return $?
    done
    for relative in lib/ufw.sh commands/service/proxy/ufw.sh; do
        vps_cmd_require_no_symlink_components "$runtime/$relative" || return $?
        rm -f -- "$runtime/$relative" || return 20
    done
    # The persistent watch starts a fresh child from this directory each cycle;
    # the caller's proxy lock excludes a concurrent refresh during replacement.
}

nft_cli_legacy_begin() {
    local directory="$1" logical path unit binary config manager='' installed=false package_state=absent
    local ufw_active=inactive ufw_boot=not-found rfw=false rfw_active=inactive rfw_boot=not-found status
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info '演练：备份旧 UFW/RFW；新规则生效后退役旧后端，不导入手工规则'
        return 0
    fi
    vps_cmd_require_no_symlink_components "$directory" || return $?
    mkdir -p -- "$directory/files" || return 20
    chmod 0700 -- "$directory" "$directory/files" || return 20
    NFT_LEGACY_INIT="${VPSCTL_ENV_INIT:-}"
    case "$NFT_LEGACY_INIT" in systemd) ;; openrc | openrc-init) NFT_LEGACY_INIT=openrc ;;
    *) if [[ -d /run/systemd/system ]]; then NFT_LEGACY_INIT=systemd; elif command -v rc-service >/dev/null 2>&1; then NFT_LEGACY_INIT=openrc; else return 3; fi ;; esac
    unit="$(vps_cmd_system_path /etc/systemd/system/rfw.service)" || return $?
    binary="$(vps_cmd_system_path /usr/local/bin/rfw)" || return $?
    config="$(vps_cmd_system_path /etc/vpsctl/rfw.conf)" || return $?
    if [[ -e "$unit" || -e "$binary" || -e "$config" ]]; then
        nft_cli_legacy_managed_rfw "$unit" || {
            vps_cmd_error '现有 RFW 缺少脚本所有权标记，无法安全自动退役；原文件未修改'
            return 3
        }
        [[ ! -e "$config" ]] || nft_cli_legacy_managed_rfw "$config" || return 3
        [[ "$NFT_LEGACY_INIT" == systemd ]] || return 3
        rfw=true
        rfw_active="$(nft_cli_legacy_unit_state rfw active)" || return $?
        rfw_boot="$(nft_cli_legacy_unit_state rfw enabled)" || return $?
        ip -details -json link show | jq '[.[] | .xdp.prog? | select(.name == "rfw") | .id]' >"$directory/rfw-programs.json" || return 20
    fi
    if command -v ufw >/dev/null 2>&1; then
        installed=true
        status="$(LC_ALL=C ufw status)" || return 20
        case "${status%%$'\n'*}" in 'Status: active') ufw_active=active ;; 'Status: inactive') ;; *) return 10 ;; esac
        ufw_boot="$(nft_cli_legacy_unit_state ufw enabled)" || return $?
        manager="$(vps_cmd_detect_package_manager)" || return $?
        package_state=installed
    elif command -v dpkg-query >/dev/null 2>&1; then
        status="$(dpkg-query -W -f='${db:Status-Status}' ufw 2>/dev/null || true)"
        if [[ "$status" == config-files ]]; then
            manager=apt-get
            package_state='config-files'
        fi
    fi
    for logical in $(nft_cli_legacy_paths); do
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        [[ -e "$path" ]] || continue
        mkdir -p -- "$directory/files${logical%/*}" || return 20
        cp -a -- "$path" "$directory/files$logical" || return 20
    done
    if [[ "$installed" == true && "$manager" == apt-get ]]; then nft_cli_legacy_backup_deb "$directory" || return $?; fi
    nft_cli_legacy_sysctls >"$directory/sysctls.tsv" || return $?
    nft_cli_legacy_check_fail2ban || return $?
    jq -n --arg init "$NFT_LEGACY_INIT" --arg manager "$manager" --arg package "$package_state" \
        --argjson installed "$installed" --arg ua "$ufw_active" --arg ub "$ufw_boot" \
        --argjson rfw "$rfw" --arg ra "$rfw_active" --arg rb "$rfw_boot" \
        --argjson f2b "$NFT_LEGACY_F2B" --argjson f2b_active "$NFT_LEGACY_F2B_ACTIVE" \
        '{schema_version:1,init:$init,manager:$manager,ufw:{installed:$installed,package:$package,active:$ua,boot:$ub},rfw:{managed:$rfw,active:$ra,boot:$rb},fail2ban:{managed:$f2b,active:$f2b_active}}' >"$directory/state.json" || return 20
    chmod 0600 -- "$directory/state.json" "$directory/sysctls.tsv" || return 20
}

nft_cli_legacy_retire() {
    local directory="$1" remaining
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    [[ -f "$directory/state.json" ]] || return 3
    NFT_LEGACY_INIT="$(jq -r .init "$directory/state.json")" || return 10
    : >"$directory/retirement-started" || return 20
    nft_cli_legacy_migrate_proxy_runtime || return $?
    nft_cli_legacy_migrate_fail2ban "$directory" || return $?
    if jq -e '.ufw.installed' "$directory/state.json" >/dev/null; then
        vps_cmd_run env LC_ALL=C ufw --force disable || return 20
        if [[ "$NFT_LEGACY_INIT" == systemd ]]; then
            if [[ "$(jq -r .ufw.boot "$directory/state.json")" != not-found ]]; then
                vps_cmd_run systemctl stop ufw.service || return 20
                vps_cmd_run systemctl disable ufw.service || return 20
            fi
        else
            vps_cmd_run rc-update del ufw default || return 20
        fi
    fi
    if jq -e '.rfw.managed' "$directory/state.json" >/dev/null; then
        vps_cmd_run systemctl stop rfw.service || return 20
        vps_cmd_run systemctl disable rfw.service || return 20
        remaining="$(ip -details -json link show | jq --slurpfile old "$directory/rfw-programs.json" '[.[] | .xdp.prog?.id | select(. != null) | select(. as $id | $old[0] | index($id))] | length')" || return 20
        [[ "$remaining" == 0 ]] || {
            vps_cmd_error 'RFW 停止后其 XDP 程序仍挂载，已中止清理'
            return 20
        }
    fi
    # UFW may apply sysctl.conf while stopping. Forwarding belongs to the relay.
    nft_cli_legacy_restore_sysctls "$directory"
}

nft_cli_legacy_remove_package() {
    case "$1" in
        apt-get) vps_cmd_run env DEBIAN_FRONTEND=noninteractive apt-get purge -y ufw ;;
        dnf5 | dnf | yum) vps_cmd_run "$1" remove -y ufw ;;
        apk) vps_cmd_run apk del ufw ;;
        pacman) vps_cmd_run pacman -R --noconfirm ufw ;;
        zypper) vps_cmd_run zypper --non-interactive remove ufw ;;
        '') return 0 ;;
        *) return 3 ;;
    esac
}

nft_cli_legacy_finish() {
    local directory="$1" logical path child manager
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    [[ -f "$directory/retirement-started" ]] || return 3
    manager="$(jq -r .manager "$directory/state.json")" || return 10
    nft_cli_legacy_remove_package "$manager" || return 20
    # Keep application profiles owned by other packages (for example OpenSSH).
    path="$(vps_cmd_system_path /etc/ufw)" || return $?
    vps_cmd_require_no_symlink_components "$path" || return $?
    if [[ -d "$path" ]]; then
        for child in "$path"/* "$path"/.[!.]* "$path"/..?*; do
            [[ -e "$child" || -L "$child" ]] || continue
            [[ "$child" != "$path/applications.d" ]] || continue
            rm -rf -- "$child" || return 20
        done
    fi
    for logical in /etc/default/ufw /var/lib/ufw /var/lib/vpsctl/network/ufw; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        rm -rf -- "$path" || return 20
    done
    if jq -e '.rfw.managed' "$directory/state.json" >/dev/null; then
        for logical in /etc/vpsctl/rfw.conf /etc/systemd/system/rfw.service /usr/local/bin/rfw /var/lib/vpsctl/network/rfw /sys/fs/bpf/rfw_port_access_log; do
            path="$(vps_cmd_system_path "$logical")" || return $?
            vps_cmd_require_no_symlink_components "$path" || return $?
            rm -rf -- "$path" || return 20
        done
        vps_cmd_run systemctl daemon-reload || return 20
    fi
    hash -r
    nft_cli_legacy_restore_sysctls "$directory" || return $?
    : >"$directory/retired" || return 20
}

nft_cli_legacy_restore_boot() {
    local service="$1" mode="$2"
    case "$NFT_LEGACY_INIT:$mode" in
        systemd:enabled) vps_cmd_run systemctl enable "$service.service" ;;
        systemd:enabled-runtime) vps_cmd_run systemctl disable "$service.service" && vps_cmd_run systemctl enable --runtime "$service.service" ;;
        systemd:disabled) vps_cmd_run systemctl disable "$service.service" ;;
        openrc:enabled) vps_cmd_run rc-update add "$service" default ;;
        openrc:disabled) if rc-update show default | awk -v s="$service" '$1 == s {found=1} END {exit !found}'; then vps_cmd_run rc-update del "$service" default; fi ;;
        *:masked | *:static | *:not-found) return 0 ;;
        *) return 3 ;;
    esac
}

nft_cli_legacy_restore() {
    local directory="$1" logical path manager unit child temporary failed=0
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    [[ -f "$directory/retirement-started" ]] || return 0
    [[ -f "$directory/state.json" ]] || return 3
    NFT_LEGACY_INIT="$(jq -r .init "$directory/state.json")" || return 10
    manager="$(jq -r .manager "$directory/state.json")" || return 10
    # A failed restore can itself have reintroduced old frontends. Compensate
    # back to a snapshot where they were absent, rather than leaving two owners.
    if jq -e '.ufw.package == "absent"' "$directory/state.json" >/dev/null && command -v ufw >/dev/null 2>&1; then
        vps_cmd_run env LC_ALL=C ufw --force disable || return 30
        nft_cli_legacy_remove_package "$(vps_cmd_detect_package_manager)" || return 30
        hash -r
    fi
    unit="$(vps_cmd_system_path /etc/systemd/system/rfw.service)" || return $?
    if ! jq -e '.rfw.managed' "$directory/state.json" >/dev/null && [[ -e "$unit" ]]; then
        nft_cli_legacy_managed_rfw "$unit" || return 30
        vps_cmd_run systemctl stop rfw.service || return 30
        vps_cmd_run systemctl disable rfw.service || return 30
    fi
    if jq -e '.ufw.installed' "$directory/state.json" >/dev/null && ! command -v ufw >/dev/null 2>&1; then
        if [[ "$manager" == apt-get && -f "$directory/ufw-recovery.deb" ]]; then
            vps_cmd_run env DEBIAN_FRONTEND=noninteractive dpkg -i "$directory/ufw-recovery.deb" || failed=1
        else
            vps_cmd_install_packages "$manager" ufw || failed=1
        fi
        hash -r
    fi
    for logical in $(nft_cli_legacy_paths); do
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        if [[ ! -e "$directory/files$logical" ]]; then
            if [[ "$logical" == /etc/ufw && -d "$path" ]]; then
                for child in "$path"/* "$path"/.[!.]* "$path"/..?*; do
                    [[ -e "$child" || -L "$child" ]] || continue
                    [[ "$child" == "$path/applications.d" ]] || rm -rf -- "$child" || failed=1
                done
            else rm -rf -- "$path" || failed=1; fi
            continue
        fi
        mkdir -p -- "${path%/*}" || {
            failed=1
            continue
        }
        if [[ "$logical" == /usr/local/libexec/vpsctl-proxy-runtime ]]; then
            rm -rf -- "$path" || {
                failed=1
                continue
            }
        fi
        if [[ -d "$directory/files$logical" ]]; then
            mkdir -p -- "$path" && cp -a -- "$directory/files$logical/." "$path/" || failed=1
        else
            # A still-running RFW can hold its executable open when retirement
            # failed before stop. Rename an intact copy rather than truncating it.
            temporary="$(mktemp "${path%/*}/.nft-legacy-restore.XXXXXX")" || {
                failed=1
                continue
            }
            if cp -a -- "$directory/files$logical" "$temporary" && mv -f -- "$temporary" "$path"; then
                :
            else
                rm -f -- "$temporary"
                failed=1
            fi
        fi
    done
    [[ "$NFT_LEGACY_INIT" != systemd ]] || vps_cmd_run systemctl daemon-reload || failed=1
    if jq -e '.ufw.installed' "$directory/state.json" >/dev/null; then
        if [[ "$(jq -r .ufw.active "$directory/state.json")" == active ]]; then
            vps_cmd_run env LC_ALL=C ufw --force enable || failed=1
        else vps_cmd_run env LC_ALL=C ufw --force disable || failed=1; fi
        nft_cli_legacy_restore_boot ufw "$(jq -r .ufw.boot "$directory/state.json")" || failed=1
    fi
    if jq -e '.rfw.managed' "$directory/state.json" >/dev/null; then
        nft_cli_legacy_restore_boot rfw "$(jq -r .rfw.boot "$directory/state.json")" || failed=1
        if [[ "$(jq -r .rfw.active "$directory/state.json")" == active ]]; then
            vps_cmd_run systemctl start rfw.service || failed=1
            systemctl is-active --quiet rfw.service || failed=1
        else vps_cmd_run systemctl stop rfw.service || failed=1; fi
    fi
    if jq -e '.fail2ban.managed and .fail2ban.active' "$directory/state.json" >/dev/null; then
        if ! vps_cmd_run fail2ban-client reload --restart sshd; then
            vps_cmd_run systemctl restart fail2ban.service || failed=1
        fi
        fail2ban-client ping >/dev/null && fail2ban-client status sshd >/dev/null || failed=1
    fi
    nft_cli_legacy_restore_sysctls "$directory" || failed=1
    ((failed == 0)) && return 0
    vps_cmd_error "旧防火墙恢复未完成，恢复材料保留于：$directory"
    return 30
}
