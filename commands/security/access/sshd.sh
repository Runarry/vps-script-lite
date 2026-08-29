# shellcheck shell=bash

ACCESS_SSH_SERVICE=''
ACCESS_SSH_CONFIG_DIR=''
ACCESS_ENTRY_SCRIPT=''

access_sshd_init() {
    local os_id="${VPSCTL_ENV_OS_ID:-}"

    ACCESS_SSH_CONFIG_DIR="$(vps_cmd_system_path /etc/ssh/sshd_config.d)" || return $?
    case "$os_id" in
        debian | ubuntu) ACCESS_SSH_SERVICE=ssh.service ;;
        *) ACCESS_SSH_SERVICE=sshd.service ;;
    esac
}

access_sshd_binary() {
    local binary

    binary="$(command -v sshd 2>/dev/null || true)"
    [[ -n "$binary" && -x "$binary" ]] || {
        vps_cmd_error "未找到 OpenSSH sshd"
        return 3
    }
    printf '%s\n' "$binary"
}

access_sshd_active_lines() {
    awk '
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line == "" || substr(line,1,1) == "#") next
            sub(/[[:space:]]+#.*/, "", line)
            print line
        }
    ' "$1"
}

access_sshd_vendor_include_allowed() {
    local argument="$1" policy

    case "${VPSCTL_ENV_OS_ID:-}" in
        rhel | centos | rocky | almalinux | ol | fedora) ;;
        *) return 1 ;;
    esac
    [[ "$argument" == /etc/crypto-policies/back-ends/opensshserver.config ]] || return 1
    policy="$(vps_cmd_system_path "$argument")" || return $?
    [[ -r "$policy" && -f "$policy" ]]
}

access_sshd_validate_standard() {
    local sshd include_count=0 line keyword argument file base before_include=1

    [[ -f "$ACCESS_MAIN_CONFIG" && ! -L "$ACCESS_MAIN_CONFIG" ]] || {
        vps_cmd_error "/etc/ssh/sshd_config 必须是非符号链接普通文件"
        return 3
    }
    vps_cmd_require_no_symlink_components "$ACCESS_MAIN_CONFIG" || return $?
    [[ ! -e "$ACCESS_SSH_CONFIG_DIR" || -d "$ACCESS_SSH_CONFIG_DIR" ]] || {
        vps_cmd_error "/etc/ssh/sshd_config.d 必须是目录"
        return 3
    }
    [[ ! -L "$ACCESS_SSH_CONFIG_DIR" ]] || {
        vps_cmd_error "/etc/ssh/sshd_config.d 不能是符号链接"
        return 3
    }
    while IFS= read -r line; do
        keyword="${line%%[[:space:]]*}"
        argument="$(vps_cmd_trim "${line#"$keyword"}")"
        keyword="${keyword,,}"
        case "$keyword" in
            include)
                include_count=$((include_count + 1))
                [[ "$argument" == /etc/ssh/sshd_config.d/\*.conf ]] || {
                    vps_cmd_error "sshd_config 含非标准 Include；只接受 /etc/ssh/sshd_config.d/*.conf"
                    return 10
                }
                before_include=0
                ;;
            match)
                vps_cmd_error "检测到 Match 条件块；无法证明全局访问策略，拒绝自动修改"
                return 10
                ;;
            port)
                access_validate_port "$argument" || {
                    vps_cmd_error "主 sshd_config 含非标准 Port：$argument"
                    return 10
                }
                ;;
            listenaddress)
                vps_cmd_error "主 sshd_config 含活动 ListenAddress；拒绝猜测端口绑定语义"
                return 10
                ;;
            permitrootlogin | passwordauthentication | kbdinteractiveauthentication | challengeresponseauthentication | pubkeyauthentication | authenticationmethods | exposeauthinfo | allowusers | denyusers | allowgroups | denygroups)
                if ((before_include)); then
                    vps_cmd_error "sshd_config 在标准 Include 前设置了 $keyword，受管 drop-in 无法可靠覆盖"
                    return 10
                fi
                ;;
        esac
    done < <(access_sshd_active_lines "$ACCESS_MAIN_CONFIG")
    ((include_count == 1)) || {
        vps_cmd_error "sshd_config 必须且只能包含一个标准 Include /etc/ssh/sshd_config.d/*.conf"
        return 10
    }
    if [[ -d "$ACCESS_SSH_CONFIG_DIR" ]]; then
        for file in "$ACCESS_SSH_CONFIG_DIR"/*.conf; do
            [[ -e "$file" ]] || continue
            [[ -f "$file" && ! -L "$file" ]] || {
                vps_cmd_error "SSH drop-in 必须是非符号链接普通文件：${file##*/}"
                return 10
            }
            base="${file##*/}"
            while IFS= read -r line; do
                keyword="${line%%[[:space:]]*}"
                argument="$(vps_cmd_trim "${line#"$keyword"}")"
                keyword="${keyword,,}"
                case "$keyword" in
                    include)
                        if [[ "$file" != "$ACCESS_CONFIG" ]] && ! access_sshd_vendor_include_allowed "$argument"; then
                            vps_cmd_error "drop-in $base 含未经批准的嵌套 Include：$argument"
                            return 10
                        fi
                        ;;
                    match | listenaddress | authenticationmethods | allowusers | denyusers | allowgroups | denygroups)
                        if [[ "$file" != "$ACCESS_CONFIG" ]]; then
                            vps_cmd_error "drop-in $base 含复杂指令 $keyword；拒绝自动合并"
                            return 10
                        fi
                        ;;
                    port)
                        access_validate_port "$argument" || {
                            vps_cmd_error "drop-in $base 含非标准 Port：$argument"
                            return 10
                        }
                        ;;
                esac
                if [[ "$base" < "00-vpsctl-access.conf" ]]; then
                    case "$keyword" in
                        permitrootlogin | passwordauthentication | kbdinteractiveauthentication | challengeresponseauthentication | pubkeyauthentication | exposeauthinfo)
                            vps_cmd_error "drop-in $base 排在 vpsctl 受管文件之前并设置 $keyword，拒绝继续"
                            return 10
                            ;;
                    esac
                fi
            done < <(access_sshd_active_lines "$file")
        done
    fi
    if [[ -e "$ACCESS_CONFIG" ]] && ! grep -Fqx "$ACCESS_MANAGED_MARKER" "$ACCESS_CONFIG"; then
        vps_cmd_error "受管 drop-in 路径已被非 vpsctl 文件占用：$ACCESS_CONFIG_LOGICAL"
        return 10
    fi
    sshd="$(access_sshd_binary)" || return $?
    "$sshd" -t -f "$ACCESS_MAIN_CONFIG" || {
        vps_cmd_error "当前 sshd_config 未通过 sshd -t；拒绝开始事务"
        return 10
    }
}

access_sshd_effective_value() {
    local key="$1" sshd effective output

    sshd="$(access_sshd_binary)" || return $?
    effective="$("$sshd" -T -f "$ACCESS_MAIN_CONFIG" 2>/dev/null)" || return 20
    output="$(awk -v wanted="$key" '$1 == wanted {print $2; exit}' <<<"$effective")"
    [[ -n "$output" ]] || return 10
    printf '%s\n' "$output"
}

access_sshd_current_port() {
    local sshd output count

    sshd="$(access_sshd_binary)" || return $?
    output="$("$sshd" -T -f "$ACCESS_MAIN_CONFIG" 2>/dev/null | awk '$1 == "port" {print $2}')" || return 20
    count="$(grep -c . <<<"$output" || true)"
    [[ "$count" == 1 ]] || {
        vps_cmd_error "当前 sshd 有多个有效端口，拒绝自动推断事务基线"
        return 10
    }
    access_validate_port "$output" || return 10
    printf '%s\n' "$output"
}

access_sshd_map_root() {
    case "$1" in
        yes) printf 'allow\n' ;;
        no) printf 'deny\n' ;;
        prohibit-password | without-password | forced-commands-only) printf 'key-only\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

access_sshd_render() {
    local old_port="$1" new_port="$2" root_value="$3" password_value="$4" kbd_value="$5"
    local pubkey_value="$6" expose_value="$7" pending="$8"
    printf '%s\n' "$ACCESS_MANAGED_MARKER"
    printf '# Do not edit while an access transaction is active.\n'
    printf 'Port %s\n' "$new_port"
    [[ "$pending" == 1 && "$old_port" != "$new_port" ]] && printf 'Port %s\n' "$old_port"
    printf 'PermitRootLogin %s\n' "$root_value"
    printf 'PasswordAuthentication %s\n' "$password_value"
    printf 'KbdInteractiveAuthentication %s\n' "$kbd_value"
    printf 'PubkeyAuthentication %s\n' "$pubkey_value"
    printf 'ExposeAuthInfo %s\n' "$expose_value"
}

access_sshd_assert_effective() {
    local old_port="$1" new_port="$2" root_value="$3" password_value="$4" kbd_value="$5"
    local pubkey_value="$6" expose_value="$7" pending="$8" fallback_user="${9:-}" sshd output actual ports expected context_user context_label
    local -a context_users=('')

    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    sshd="$(access_sshd_binary)" || return $?
    if [[ "$pending" == 1 && "$old_port" != "$new_port" ]]; then
        expected="$(printf '%s\n%s\n' "$old_port" "$new_port" | sort -n -u | tr '\n' ' ')"
    else
        expected="${new_port} "
    fi
    context_users+=(root)
    [[ -z "$fallback_user" || "$fallback_user" == root ]] || context_users+=("$fallback_user")
    for context_user in "${context_users[@]}"; do
        if [[ -z "$context_user" ]]; then
            context_label=global
            output="$("$sshd" -T -f "$ACCESS_MAIN_CONFIG" 2>/dev/null)" || return 10
        else
            context_label="user=$context_user"
            output="$("$sshd" -T -f "$ACCESS_MAIN_CONFIG" -C "user=$context_user,host=localhost,addr=127.0.0.1" 2>/dev/null)" || return 10
        fi
        for actual in \
            "permitrootlogin:$root_value" \
            "passwordauthentication:$password_value" \
            "kbdinteractiveauthentication:$kbd_value" \
            "pubkeyauthentication:$pubkey_value" \
            "exposeauthinfo:$expose_value"; do
            ports="$(awk -v key="${actual%%:*}" '$1 == key {print $2; exit}' <<<"$output")"
            [[ "$ports" == "${actual#*:}" ]] || {
                vps_cmd_error "候选 SSH 配置未生效（$context_label）：${actual%%:*} 期望 ${actual#*:}，实际 ${ports:-缺失}"
                return 10
            }
        done
        ports="$(awk '$1 == "port" {print $2}' <<<"$output" | sort -n -u | tr '\n' ' ')"
        [[ "$ports" == "$expected" ]] || {
            vps_cmd_error "候选 SSH 端口集合未精确生效（$context_label）：期望 $expected，实际 ${ports:-空}"
            return 10
        }
    done
}

access_sshd_validate_candidate() {
    local candidate="$1" sshd temp_root temp_main temp_dropin file status=0

    sshd="$(access_sshd_binary)" || return $?
    temp_root="$(mktemp -d /tmp/vpsctl-access-sshd.XXXXXX)" || return 20
    temp_main="$temp_root/sshd_config"
    temp_dropin="$temp_root/sshd_config.d"
    mkdir -m 0700 -- "$temp_dropin" || status=20
    if ((status == 0)); then
        awk -v include_path="$temp_dropin/*.conf" '
            {
                probe=$0
                sub(/^[[:space:]]*/, "", probe)
                if (probe ~ /^[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]+\/etc\/ssh\/sshd_config\.d\/\*\.conf([[:space:]]|$)/)
                    print "Include " include_path
                else
                    print
            }
        ' "$ACCESS_MAIN_CONFIG" >"$temp_main" || status=20
        chmod 0600 -- "$temp_main" || status=20
    fi
    if ((status == 0)); then
        for file in "$ACCESS_SSH_CONFIG_DIR"/*.conf; do
            [[ -f "$file" && ! -L "$file" ]] || continue
            [[ "$file" == "$ACCESS_CONFIG" ]] && continue
            cp -p -- "$file" "$temp_dropin/${file##*/}" || {
                status=20
                break
            }
        done
    fi
    if ((status == 0)); then
        install -o root -g root -m 0600 -- "$candidate" "$temp_dropin/00-vpsctl-access.conf" || status=20
    fi
    if ((status == 0)) && ! "$sshd" -t -f "$temp_main"; then
        status=10
    fi
    rm -rf -- "$temp_root"
    ((status == 0)) || {
        [[ "$status" == 10 ]] && vps_cmd_error "候选 SSH 配置未通过 sshd -t"
        return "$status"
    }
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || vps_cmd_info "演练：候选 drop-in 已在隔离配置树通过 sshd -t"
}

access_sshd_install_candidate() {
    local candidate="$1"

    access_atomic_from_file "$candidate" "$ACCESS_CONFIG" 0644
}

access_sshd_reload() {
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：将 reload $ACCESS_SSH_SERVICE 并检查服务状态"
        return 0
    fi
    systemctl is-active --quiet "$ACCESS_SSH_SERVICE" || {
        vps_cmd_error "$ACCESS_SSH_SERVICE 当前未运行"
        return 3
    }
    systemctl reload "$ACCESS_SSH_SERVICE" || return 20
    systemctl is-active --quiet "$ACCESS_SSH_SERVICE" || return 20
}

access_sshd_port_listening() {
    local port="$1" output

    command -v ss >/dev/null 2>&1 || {
        vps_cmd_error "缺少 ss，无法证明 sshd 监听端口"
        return 3
    }
    output="$(ss -H -ltnp "( sport = :${port} )" 2>/dev/null)" || return 1
    grep -q '"sshd"' <<<"$output"
}

access_sshd_require_new_port_free() {
    local old_port="$1" new_port="$2" output

    [[ "$old_port" == "$new_port" ]] && return 0
    output="$(ss -H -ltn "( sport = :${new_port} )" 2>/dev/null || true)"
    if [[ -n "${output//[[:space:]]/}" ]]; then
        vps_cmd_error "新端口 $new_port 已被监听，拒绝覆盖"
        return 3
    fi
}

access_sshd_verify_ports() {
    local old_port="$1" new_port="$2" pending="$3"

    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    access_sshd_port_listening "$new_port" || {
        vps_cmd_error "reload 后未检测到 SSH 新端口 $new_port 监听"
        return 20
    }
    if [[ "$old_port" != "$new_port" ]]; then
        if [[ "$pending" == 1 ]]; then
            access_sshd_port_listening "$old_port" || {
                vps_cmd_error "prepare 后旧 SSH 端口 $old_port 未继续监听"
                return 20
            }
        elif access_sshd_port_listening "$old_port"; then
            vps_cmd_error "commit 后旧 SSH 端口 $old_port 仍在监听"
            return 20
        fi
    fi
}

access_sshd_restore_backup_config() {
    local backup_dir="$1" present candidate count index logical physical saved current_hash original_hash managed_hash

    present="$(access_kv_get "$backup_dir/manifest" config_present)" || return 30
    if [[ "$present" == 1 ]]; then
        candidate="$backup_dir/managed.conf"
        [[ -f "$candidate" && ! -L "$candidate" ]] || return 30
        access_sshd_install_candidate "$candidate"
    elif [[ "$present" == 0 ]]; then
        [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]] || rm -f -- "$ACCESS_CONFIG" || return 20
    else
        return 30
    fi
    count="$(access_kv_get "$backup_dir/manifest" port_file_count 2>/dev/null || printf 0)"
    [[ "$count" =~ ^[0-9]+$ ]] || return 30
    for ((index = 0; index < count; index++)); do
        logical="$(access_kv_get "$backup_dir/manifest" "port_file_${index}")" || return 30
        physical="$(vps_cmd_system_path "$logical")" || return $?
        saved="$backup_dir/port-files/$index"
        [[ -f "$saved" && ! -L "$saved" ]] || return 30
        original_hash="$(access_kv_get "$backup_dir/manifest" "port_file_sha256_${index}")" || return 30
        managed_hash="$(access_kv_get "$backup_dir/manifest" "port_file_managed_sha256_${index}")" || return 30
        [[ "$(access_sha256_file "$saved")" == "$original_hash" ]] || return 30
        [[ -f "$physical" && ! -L "$physical" ]] || return 30
        current_hash="$(access_sha256_file "$physical")" || return 30
        [[ "$current_hash" == "$managed_hash" || "$current_hash" == "$original_hash" ]] || {
            vps_cmd_error "SSH Port 来源文件在事务期间发生漂移：$logical"
            return 30
        }
        access_atomic_from_file "$saved" "$physical" "$(access_kv_get "$backup_dir/manifest" "port_file_mode_${index}")" || return $?
        if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
            chown "$(access_kv_get "$backup_dir/manifest" "port_file_uid_${index}"):$(access_kv_get "$backup_dir/manifest" "port_file_gid_${index}")" -- "$physical" || return 20
        fi
    done
}

access_sshd_print_recovery() {
    local backup_dir="$1" manifest present count index logical physical mode uid gid command

    manifest="$backup_dir/manifest"
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 0
    vps_cmd_error "自动回滚不完整；请保持当前会话并依次执行以下人工恢复命令："
    present="$(access_kv_get "$manifest" config_present 2>/dev/null || true)"
    if [[ "$present" == 1 && -f "$backup_dir/managed.conf" ]]; then
        printf -v command 'install -o 0 -g 0 -m 0644 -- %q %q' "$backup_dir/managed.conf" "$ACCESS_CONFIG"
    else
        printf -v command 'rm -f -- %q' "$ACCESS_CONFIG"
    fi
    vps_cmd_error "$command"
    count="$(access_kv_get "$manifest" port_file_count 2>/dev/null || printf 0)"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    for ((index = 0; index < count; index++)); do
        logical="$(access_kv_get "$manifest" "port_file_${index}" 2>/dev/null || true)"
        physical="$(vps_cmd_system_path "$logical" 2>/dev/null || true)"
        mode="$(access_kv_get "$manifest" "port_file_mode_${index}" 2>/dev/null || true)"
        uid="$(access_kv_get "$manifest" "port_file_uid_${index}" 2>/dev/null || true)"
        gid="$(access_kv_get "$manifest" "port_file_gid_${index}" 2>/dev/null || true)"
        [[ -n "$physical" && "$mode" =~ ^[0-7]{3,4}$ && "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || continue
        printf -v command 'install -o %q -g %q -m %q -- %q %q' "$uid" "$gid" "$mode" "$backup_dir/port-files/$index" "$physical"
        vps_cmd_error "$command"
    done
    printf -v command '%q -t -f %q && systemctl reload %q' "$(access_sshd_binary 2>/dev/null || printf sshd)" "$ACCESS_MAIN_CONFIG" "$ACCESS_SSH_SERVICE"
    vps_cmd_error "$command"
    vps_cmd_error "防火墙只可按 vpsctl 标记恢复；不要按端口删除未知来源规则。"
}

access_sshd_make_backup() {
    local backup_id="$1" backup_dir="$2" tx_id="$3" old_port="$4" new_port="$5"
    local present=0 config_sha='' tmp file line keyword count=0 logical normalized_tmp
    local -a port_files=() port_modes=() port_uids=() port_gids=() port_hashes=() port_managed_hashes=()

    mkdir -p -- "$backup_dir" || return 20
    chmod 0700 -- "$backup_dir" || return 20
    if [[ -f "$ACCESS_CONFIG" ]]; then
        cp -p -- "$ACCESS_CONFIG" "$backup_dir/managed.conf" || return 20
        chmod 0600 -- "$backup_dir/managed.conf" || return 20
        present=1
        config_sha="$(access_sha256_file "$ACCESS_CONFIG")" || return $?
    fi
    if [[ -f "$ACCESS_FW_STATE" ]]; then
        cp -p -- "$ACCESS_FW_STATE" "$backup_dir/firewall.state" || return 20
        chmod 0600 -- "$backup_dir/firewall.state" || return 20
    fi
    for file in "$ACCESS_MAIN_CONFIG" "$ACCESS_SSH_CONFIG_DIR"/*.conf; do
        [[ -f "$file" && ! -L "$file" && "$file" != "$ACCESS_CONFIG" ]] || continue
        while IFS= read -r line; do
            keyword="${line%%[[:space:]]*}"
            if [[ "${keyword,,}" == port ]]; then
                port_files+=("$file")
                break
            fi
        done < <(access_sshd_active_lines "$file")
    done
    if ((${#port_files[@]} > 0)); then
        mkdir -p -- "$backup_dir/port-files" || return 20
        chmod 0700 -- "$backup_dir/port-files" || return 20
        for file in "${port_files[@]}"; do
            port_modes+=("$(stat -c %a -- "$file")")
            port_uids+=("$(stat -c %u -- "$file")")
            port_gids+=("$(stat -c %g -- "$file")")
            port_hashes+=("$(access_sha256_file "$file")")
            normalized_tmp="$(mktemp)" || return 20
            awk '
                { probe=$0; sub(/^[[:space:]]*/, "", probe); split(probe, fields, /[[:space:]]+/)
                  if (tolower(fields[1]) == "port") print "# vpsctl access disabled original: " $0; else print }
            ' "$file" >"$normalized_tmp" || {
                rm -f -- "$normalized_tmp"
                return 20
            }
            port_managed_hashes+=("$(access_sha256_file "$normalized_tmp")")
            rm -f -- "$normalized_tmp"
            cp -p -- "$file" "$backup_dir/port-files/$count" || return 20
            chmod 0600 -- "$backup_dir/port-files/$count" || return 20
            count=$((count + 1))
        done
    fi
    tmp="$(mktemp --tmpdir="$backup_dir" .manifest.XXXXXX)" || return 20
    {
        access_kv_put schema_version 1
        access_kv_put kind ssh
        access_kv_put backup_id "$backup_id"
        access_kv_put transaction_id "$tx_id"
        access_kv_put created_epoch "$(date +%s)"
        access_kv_put config_present "$present"
        access_kv_put config_sha256 "$config_sha"
        access_kv_put old_port "$old_port"
        access_kv_put new_port "$new_port"
        access_kv_put lifecycle prepared
        access_kv_put applied_sha256 ''
        access_kv_put port_file_count "$count"
        count=0
        for file in "${port_files[@]}"; do
            logical="$(access_physical_to_logical "$file")" || return 20
            access_kv_put "port_file_${count}" "$logical"
            access_kv_put "port_file_mode_${count}" "${port_modes[$count]}"
            access_kv_put "port_file_uid_${count}" "${port_uids[$count]}"
            access_kv_put "port_file_gid_${count}" "${port_gids[$count]}"
            access_kv_put "port_file_sha256_${count}" "${port_hashes[$count]}"
            access_kv_put "port_file_managed_sha256_${count}" "${port_managed_hashes[$count]}"
            count=$((count + 1))
        done
    } >"$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    chmod 0600 -- "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    mv -f -- "$tmp" "$backup_dir/manifest" || {
        rm -f -- "$tmp"
        return 20
    }
}

access_sshd_normalize_ports() {
    local backup_dir="$1" count index logical physical saved tmp

    count="$(access_kv_get "$backup_dir/manifest" port_file_count 2>/dev/null || printf 0)"
    [[ "$count" =~ ^[0-9]+$ ]] || return 30
    for ((index = 0; index < count; index++)); do
        logical="$(access_kv_get "$backup_dir/manifest" "port_file_${index}")" || return 30
        physical="$(vps_cmd_system_path "$logical")" || return $?
        saved="$backup_dir/port-files/$index"
        tmp="$(mktemp)" || return 20
        awk '
            {
                probe=$0
                sub(/^[[:space:]]*/, "", probe)
                split(probe, fields, /[[:space:]]+/)
                if (tolower(fields[1]) == "port") print "# vpsctl access disabled original: " $0
                else print
            }
        ' "$saved" >"$tmp" || {
            rm -f -- "$tmp"
            return 20
        }
        access_atomic_from_file "$tmp" "$physical" "$(access_kv_get "$backup_dir/manifest" "port_file_mode_${index}")" || {
            rm -f -- "$tmp"
            return $?
        }
        rm -f -- "$tmp"
    done
}

access_sshd_write_transaction() {
    local tx_dir="$1" status="$2" tx_id="$3" backup_id="$4" created="$5" expires="$6"
    local old_port="$7" new_port="$8" root_value="$9" password_value="${10}" kbd_value="${11}" pubkey_value="${12}" expose_value="${13}" fallback_user="${14}"
    local firewall_mode="${15}" firewall_backend="${16}" firewall_added="${17}" previous_backend="${18}" previous_port="${19}" pending_sha="${20}"
    local tmp

    tmp="$(mktemp --tmpdir="$tx_dir" .state.XXXXXX)" || return 20
    {
        access_kv_put schema_version 1
        access_kv_put status "$status"
        access_kv_put transaction_id "$tx_id"
        access_kv_put backup_id "$backup_id"
        access_kv_put created_epoch "$created"
        access_kv_put expires_epoch "$expires"
        access_kv_put old_port "$old_port"
        access_kv_put new_port "$new_port"
        access_kv_put permit_root_login "$root_value"
        access_kv_put password_authentication "$password_value"
        access_kv_put kbd_interactive_authentication "$kbd_value"
        access_kv_put pubkey_authentication "$pubkey_value"
        access_kv_put original_expose_auth_info "$expose_value"
        access_kv_put fallback_user "$fallback_user"
        access_kv_put firewall_mode "$firewall_mode"
        access_kv_put firewall_backend "$firewall_backend"
        access_kv_put firewall_added "$firewall_added"
        access_kv_put previous_firewall_backend "$previous_backend"
        access_kv_put previous_firewall_port "$previous_port"
        access_kv_put pending_sha256 "$pending_sha"
    } >"$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    chmod 0644 -- "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    mv -f -- "$tmp" "$tx_dir/state" || {
        rm -f -- "$tmp"
        return 20
    }
}

access_sshd_schedule_abort() {
    local tx_id="$1" unit
    unit="vpsctl-access-${tx_id}"

    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：将安排 15 分钟后自动 abort 事务 $tx_id"
        return 0
    fi
    command -v systemd-run >/dev/null 2>&1 || {
        vps_cmd_error "缺少 systemd-run，无法提供 15 分钟自动回滚"
        return 3
    }
    systemd-run --quiet --unit="$unit" --on-active=15m /bin/bash "$ACCESS_ENTRY_SCRIPT" --non-interactive ssh abort --transaction "$tx_id" || return 20
}

access_sshd_cancel_abort() {
    local tx_id="$1" unit
    unit="vpsctl-access-${tx_id}"

    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    systemctl stop "${unit}.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "${unit}.service" >/dev/null 2>&1 || true
}

access_sshd_backup_mark() {
    local backup_dir="$1" lifecycle="$2" applied_sha="$3" old tmp key value
    old="$backup_dir/manifest"

    [[ -f "$old" && ! -L "$old" ]] || return 30
    tmp="$(mktemp --tmpdir="$backup_dir" .manifest.XXXXXX)" || return 20
    while IFS=$'\t' read -r key value; do
        case "$key" in
            lifecycle) access_kv_put lifecycle "$lifecycle" ;;
            applied_sha256) access_kv_put applied_sha256 "$applied_sha" ;;
            *) access_kv_put "$key" "$value" ;;
        esac
    done <"$old" >"$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    chmod 0600 -- "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    mv -f -- "$tmp" "$old" || {
        rm -f -- "$tmp"
        return 20
    }
}

access_sshd_transaction_mark() {
    local state="$1" new_status="$2" directory tmp key value found=0

    [[ -f "$state" && ! -L "$state" ]] || return 30
    directory="${state%/*}"
    tmp="$(mktemp --tmpdir="$directory" .state.XXXXXX)" || return 20
    while IFS=$'\t' read -r key value; do
        if [[ "$key" == status ]]; then
            access_kv_put status "$new_status"
            found=1
        else
            access_kv_put "$key" "$value"
        fi
    done <"$state" >"$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    ((found == 1)) || {
        rm -f -- "$tmp"
        return 30
    }
    chmod 0644 -- "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    mv -f -- "$tmp" "$state" || {
        rm -f -- "$tmp"
        return 20
    }
}

access_ssh_prepare_rollback() {
    local backup_dir="$1" backend="$2" new_port="$3" added="$4" previous_backend="$5" previous_port="$6" failed=0

    access_sshd_restore_backup_config "$backup_dir" || failed=1
    access_sshd_reload || failed=1
    access_firewall_abort "$backend" "$new_port" "$added" "$previous_backend" "$previous_port" || failed=1
    if ((failed)); then
        access_sshd_print_recovery "$backup_dir"
        return 1
    fi
}

access_ssh_prepare() {
    local requested_port="$1" requested_root="$2" requested_password="$3" fallback_user="$4" firewall_mode="$5"
    local old_port new_port current_root current_password current_kbd current_pubkey current_expose root_value password_value kbd_value tx_id backup_id tx_dir backup_dir
    local created expires candidate pending_sha backend=none active rollback_failed=0

    vps_cmd_require_root || return $?
    vps_cmd_ensure_tools security-access sshd ss systemctl systemd-run || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 && "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_warning "演练已列出 SSH 事务依赖；安装后需重新运行才能校验候选配置"
        return 3
    fi
    access_sshd_validate_standard || return $?
    active="$(access_active_transaction 2>/dev/null || true)"
    [[ -z "$active" ]] || {
        vps_cmd_error "已有未完成访问事务：$active；请先 commit 或 abort"
        return 3
    }
    old_port="$(access_sshd_current_port)" || return $?
    new_port="${requested_port:-$old_port}"
    access_sshd_require_new_port_free "$old_port" "$new_port" || return $?
    current_root="$(access_sshd_effective_value permitrootlogin)" || return $?
    current_password="$(access_sshd_effective_value passwordauthentication)" || return $?
    current_kbd="$(access_sshd_effective_value kbdinteractiveauthentication)" || return $?
    current_pubkey="$(access_sshd_effective_value pubkeyauthentication)" || return $?
    current_expose="$(access_sshd_effective_value exposeauthinfo)" || return $?
    root_value="$current_root"
    [[ "$requested_root" != allow ]] || root_value=yes
    [[ "$requested_root" != deny ]] || root_value=no
    password_value="$current_password"
    kbd_value="$current_kbd"
    if [[ "$requested_password" == allow ]]; then
        password_value=yes
    elif [[ "$requested_password" == deny ]]; then
        password_value=no
        kbd_value=no
    fi
    access_validate_port "$new_port" || {
        vps_cmd_error "无效 SSH 端口：$new_port"
        return 2
    }
    case "$root_value" in yes | no | prohibit-password | without-password | forced-commands-only) ;; *) return 10 ;; esac
    [[ "$password_value" == yes || "$password_value" == no ]] || return 10
    [[ "$kbd_value" == yes || "$kbd_value" == no ]] || return 10
    [[ "$current_pubkey" == yes || "$current_pubkey" == no ]] || return 10
    [[ "$current_expose" == yes || "$current_expose" == no ]] || return 10
    if [[ "$requested_password" == deny && "$current_pubkey" != yes ]]; then
        vps_cmd_error "不能在 PubkeyAuthentication 未启用时禁用密码登录"
        return 3
    fi
    if [[ -n "$fallback_user" ]]; then
        access_require_login_user "$fallback_user" || return $?
        [[ "$(access_user_field "$fallback_user" uid)" != 0 ]] || {
            vps_cmd_error "--fallback-user 必须是非 root 用户"
            return 2
        }
        access_user_has_admin_access "$fallback_user" || {
            vps_cmd_error "fallback 用户 $fallback_user 未通过 sudo/wheel 管理员能力检查"
            return 3
        }
        access_user_has_authorized_key "$fallback_user" || {
            vps_cmd_error "fallback 用户 $fallback_user 尚无有效 authorized_keys 公钥"
            return 3
        }
    elif [[ "$root_value" == no ]]; then
        vps_cmd_error "禁用 root SSH 登录时必须指定已有公钥的 --fallback-user"
        return 3
    fi
    access_prepare_layout || return $?
    vps_cmd_lock security-access || return $?
    tx_id="$(access_new_id tx)" || {
        vps_cmd_unlock
        return $?
    }
    backup_id="$(access_new_id bak)" || {
        vps_cmd_unlock
        return $?
    }
    tx_dir="$(access_transaction_path "$tx_id")" || {
        vps_cmd_unlock
        return $?
    }
    backup_dir="$(access_backup_path "$backup_id")" || {
        vps_cmd_unlock
        return $?
    }
    created="$(date +%s)"
    expires=$((created + 900))
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        mkdir -p -- "$tx_dir/proofs" || {
            vps_cmd_unlock
            return 20
        }
        chmod 0755 -- "$tx_dir" || {
            vps_cmd_unlock
            return 20
        }
        chmod 0700 -- "$tx_dir/proofs" || {
            vps_cmd_unlock
            return 20
        }
    fi
    access_firewall_load_managed
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        access_sshd_make_backup "$backup_id" "$backup_dir" "$tx_id" "$old_port" "$new_port" || {
            vps_cmd_unlock
            return $?
        }
    fi
    if [[ "$firewall_mode" == auto ]]; then
        if ! backend="$(access_firewall_detect)"; then
            if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] && ! access_ssh_prepare_rollback "$backup_dir" none "$new_port" 0 "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT"; then rollback_failed=1; fi
            vps_cmd_unlock
            ((rollback_failed == 0)) && return 3
            return 30
        fi
        if ! access_firewall_require_auto_backend "$backend"; then
            if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] && ! access_ssh_prepare_rollback "$backup_dir" "$backend" "$new_port" 0 "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT"; then rollback_failed=1; fi
            vps_cmd_unlock
            ((rollback_failed == 0)) && return 3
            return 30
        fi
    else
        vps_cmd_warning "防火墙为 manual；请确认 TCP $new_port 已从管理端可达"
    fi
    if ! candidate="$(mktemp)"; then
        [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]] || access_ssh_prepare_rollback "$backup_dir" "$backend" "$new_port" "$ACCESS_FW_ADDED" "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT" || rollback_failed=1
        vps_cmd_unlock
        ((rollback_failed == 0)) && return 20
        return 30
    fi
    access_sshd_render "$old_port" "$new_port" "$root_value" "$password_value" "$kbd_value" "$current_pubkey" yes 1 >"$candidate"
    access_sshd_validate_candidate "$candidate" || {
        rm -f -- "$candidate"
        [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]] || access_ssh_prepare_rollback "$backup_dir" "$backend" "$new_port" "$ACCESS_FW_ADDED" "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT" || rollback_failed=1
        vps_cmd_unlock
        ((rollback_failed == 0)) && return 10
        access_sshd_print_recovery "$backup_dir"
        return 30
    }
    if [[ "$firewall_mode" == auto ]] && ! access_firewall_open "$backend" "$new_port" "$old_port"; then
        rm -f -- "$candidate"
        if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] && ! access_ssh_prepare_rollback "$backup_dir" "$backend" "$new_port" "$ACCESS_FW_ADDED" "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT"; then rollback_failed=1; fi
        vps_cmd_unlock
        ((rollback_failed == 0)) && return 20
        return 30
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        rm -f -- "$candidate"
        vps_cmd_unlock
        vps_cmd_info "演练完成：未创建可提交的事务或备份"
        return 0
    fi
    if ! access_sshd_normalize_ports "$backup_dir"; then
        if ! access_sshd_restore_backup_config "$backup_dir"; then
            vps_cmd_unlock
            access_sshd_print_recovery "$backup_dir"
            return 30
        fi
        vps_cmd_unlock
        return 20
    fi
    if ! access_sshd_install_candidate "$candidate"; then
        rm -f -- "$candidate"
        access_ssh_prepare_rollback "$backup_dir" "$backend" "$new_port" "$ACCESS_FW_ADDED" "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT" || rollback_failed=1
        vps_cmd_unlock
        ((rollback_failed == 0)) && return 20
        access_sshd_print_recovery "$backup_dir"
        return 30
    fi
    if ! access_sshd_assert_effective "$old_port" "$new_port" "$root_value" "$password_value" "$kbd_value" "$current_pubkey" yes 1 "$fallback_user"; then
        rm -f -- "$candidate"
        access_sshd_restore_backup_config "$backup_dir" || rollback_failed=1
        access_firewall_abort "$backend" "$new_port" "$ACCESS_FW_ADDED" "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT" || rollback_failed=1
        vps_cmd_unlock
        ((rollback_failed == 0)) && return 10
        return 30
    fi
    if ! pending_sha="$(access_sha256_file "$ACCESS_CONFIG")"; then
        rm -f -- "$candidate"
        access_ssh_prepare_rollback "$backup_dir" "$backend" "$new_port" "$ACCESS_FW_ADDED" "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT" || rollback_failed=1
        vps_cmd_unlock
        ((rollback_failed == 0)) && return 20
        return 30
    fi
    rm -f -- "$candidate"
    if ! access_sshd_reload || ! access_sshd_verify_ports "$old_port" "$new_port" 1; then
        access_sshd_restore_backup_config "$backup_dir" || rollback_failed=1
        access_sshd_reload || rollback_failed=1
        access_firewall_abort "$backend" "$new_port" "$ACCESS_FW_ADDED" "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT" || rollback_failed=1
        vps_cmd_unlock
        ((rollback_failed == 0)) && return 20
        return 30
    fi
    access_sshd_write_transaction "$tx_dir" prepared "$tx_id" "$backup_id" "$created" "$expires" "$old_port" "$new_port" "$root_value" "$password_value" "$kbd_value" "$current_pubkey" "$current_expose" "$fallback_user" "$firewall_mode" "$backend" "$ACCESS_FW_ADDED" "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT" "$pending_sha" || {
        access_sshd_restore_backup_config "$backup_dir" || rollback_failed=1
        access_sshd_reload || rollback_failed=1
        access_firewall_abort "$backend" "$new_port" "$ACCESS_FW_ADDED" "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT" || rollback_failed=1
        vps_cmd_unlock
        ((rollback_failed == 0)) && return 20
        return 30
    }
    if ! access_write_active "$tx_id"; then
        access_sshd_restore_backup_config "$backup_dir" || rollback_failed=1
        access_sshd_reload || rollback_failed=1
        access_firewall_abort "$backend" "$new_port" "$ACCESS_FW_ADDED" "$ACCESS_FW_PREVIOUS_BACKEND" "$ACCESS_FW_PREVIOUS_PORT" || rollback_failed=1
        access_sshd_transaction_mark "$tx_dir/state" aborted || rollback_failed=1
        vps_cmd_unlock
        ((rollback_failed == 0)) && return 20
        return 30
    fi
    if ! access_sshd_schedule_abort "$tx_id"; then
        vps_cmd_unlock
        access_ssh_abort "$tx_id" || rollback_failed=1
        ((rollback_failed == 0)) && return 20
        return 30
    fi
    vps_cmd_unlock
    vps_cmd_success "SSH 访问事务已准备；旧端口 $old_port 与新端口 $new_port 将并行监听 15 分钟"
    vps_cmd_warning "请从第二个非 root SSH 会话连接新端口并运行：vpsctl security access session verify --transaction $tx_id"
    printf '%s\n' "$tx_id"
}

access_session_verify() {
    local tx_id="$1" tx_dir state status expires now new_port password_login fallback_user actual_user actual_uid
    local client_ip client_port server_ip server_port extra auth_file auth_method proof_tmp proof auth_mtime auth_uid auth_mode proof_mode proof_owner

    tx_dir="$(access_transaction_path "$tx_id")" || return $?
    state="$tx_dir/state"
    [[ -f "$state" && ! -L "$state" ]] || {
        vps_cmd_error "事务不存在：$tx_id"
        return 3
    }
    [[ "$(access_active_transaction 2>/dev/null || true)" == "$tx_id" ]] || {
        vps_cmd_error "该事务不是当前活动事务"
        return 3
    }
    status="$(access_kv_get "$state" status)" || return 30
    [[ "$status" == prepared ]] || {
        vps_cmd_error "事务不是待证明状态：$status"
        return 3
    }
    expires="$(access_kv_get "$state" expires_epoch)" || return 30
    now="$(date +%s)"
    [[ "$expires" =~ ^[0-9]+$ ]] && ((now <= expires)) || {
        vps_cmd_error "事务已超过 15 分钟证明窗口"
        return 3
    }
    actual_uid="$(id -u)" || return 20
    ((actual_uid != 0)) || {
        vps_cmd_error "session verify 必须从第二个非 root SSH 会话执行"
        return 4
    }
    actual_user="$(id -un)" || return 20
    access_require_login_user "$actual_user" || return $?
    fallback_user="$(access_kv_get "$state" fallback_user)" || return 30
    [[ -z "$fallback_user" || "$actual_user" == "$fallback_user" ]] || {
        vps_cmd_error "证明会话必须使用 fallback 用户 $fallback_user"
        return 3
    }
    [[ -n "${SSH_CONNECTION:-}" && -n "${SSH_TTY:-}" && "${SSH_TTY:-}" == /dev/* ]] || {
        vps_cmd_error "未检测到带 TTY 的 SSH 会话"
        return 3
    }
    command -v sudo >/dev/null 2>&1 || {
        vps_cmd_error "证明用户缺少 sudo"
        return 3
    }
    if ! sudo -v </dev/tty; then
        vps_cmd_error "sudo -v 未通过；证明用户不是可用管理员"
        return 3
    fi
    IFS=' ' read -r client_ip client_port server_ip server_port extra <<<"$SSH_CONNECTION"
    [[ -n "$client_ip" && -n "$client_port" && -n "$server_ip" && -n "$server_port" && -z "$extra" ]] || return 3
    new_port="$(access_kv_get "$state" new_port)" || return 30
    [[ "$server_port" == "$new_port" ]] || {
        vps_cmd_error "当前会话连接的是服务端口 $server_port，而事务要求新端口 $new_port"
        return 3
    }
    auth_file="${SSH_USER_AUTH:-}"
    [[ -n "$auth_file" && "$auth_file" == /* && -f "$auth_file" && ! -L "$auth_file" && -r "$auth_file" ]] || {
        vps_cmd_error "未获得 sshd ExposeAuthInfo 认证证明"
        return 3
    }
    auth_mtime="$(stat -c %Y -- "$auth_file" 2>/dev/null || true)"
    auth_uid="$(stat -c %u -- "$auth_file" 2>/dev/null || true)"
    auth_mode="$(stat -c %a -- "$auth_file" 2>/dev/null || true)"
    [[ "$auth_uid" == "$actual_uid" && "$auth_mode" == 600 ]] || {
        vps_cmd_error "SSH 认证证明文件所有权或权限不安全"
        return 3
    }
    [[ "$auth_mtime" =~ ^[0-9]+$ ]] && ((auth_mtime >= $(access_kv_get "$state" created_epoch))) || {
        vps_cmd_error "SSH 认证证明早于事务创建时间"
        return 3
    }
    if grep -Eq '^publickey([[:space:]]|$)' "$auth_file"; then
        auth_method=publickey
    elif grep -Eq '^(password|keyboard-interactive)([[:space:]]|$)' "$auth_file"; then
        auth_method=password
    else
        vps_cmd_error "无法识别当前 SSH 会话的认证方式"
        return 3
    fi
    password_login="$(access_kv_get "$state" password_authentication)" || return 30
    [[ "$password_login" != no || "$auth_method" == publickey ]] || {
        vps_cmd_error "事务将禁用密码登录，证明会话必须使用 publickey"
        return 3
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：第二会话已通过端口、用户、sudo 与认证方式检查；不会写入证明"
        return 0
    fi
    proof="$tx_dir/proofs/proof.${actual_uid}"
    proof_tmp="$(mktemp /tmp/vpsctl-access-proof.XXXXXX)" || return 20
    umask 077
    {
        access_kv_put schema_version 1
        access_kv_put transaction_id "$tx_id"
        access_kv_put user "$actual_user"
        access_kv_put uid "$actual_uid"
        access_kv_put server_port "$server_port"
        access_kv_put auth_method "$auth_method"
        access_kv_put verified_epoch "$now"
    } >"$proof_tmp" || {
        rm -f -- "$proof_tmp"
        return 20
    }
    chmod 0600 -- "$proof_tmp" || {
        rm -f -- "$proof_tmp"
        return 20
    }
    sudo install -o root -g root -m 0600 -- "$proof_tmp" "$proof" || {
        rm -f -- "$proof_tmp"
        return 20
    }
    rm -f -- "$proof_tmp"
    proof_mode="$(sudo stat -c %a -- "$proof" 2>/dev/null || true)"
    proof_owner="$(sudo stat -c %u -- "$proof" 2>/dev/null || true)"
    [[ "$proof_mode" == 600 && "$proof_owner" == 0 ]] || {
        sudo rm -f -- "$proof" || true
        return 20
    }
    vps_cmd_success "已记录事务 $tx_id 的第二会话证明（$actual_user，$auth_method，端口 $server_port）"
}

access_sshd_find_proof() {
    local tx_dir="$1" fallback="$2" proof uid owner user verified mode recorded_uid

    if [[ -n "$fallback" ]]; then
        uid="$(access_user_field "$fallback" uid)" || return $?
        proof="$tx_dir/proofs/proof.${uid}"
        [[ -f "$proof" && ! -L "$proof" ]] || return 3
        owner="$(stat -c %u -- "$proof" 2>/dev/null || true)"
        mode="$(stat -c %a -- "$proof" 2>/dev/null || true)"
        recorded_uid="$(access_kv_get "$proof" uid 2>/dev/null || true)"
        user="$(access_kv_get "$proof" user 2>/dev/null || true)"
        [[ "$owner" == 0 && "$recorded_uid" == "$uid" && "$user" == "$fallback" && "$mode" == 600 ]] || return 3
        printf '%s\n' "$proof"
        return 0
    fi
    for proof in "$tx_dir"/proofs/proof.*; do
        [[ -f "$proof" && ! -L "$proof" ]] || continue
        owner="$(stat -c %u -- "$proof" 2>/dev/null || true)"
        [[ "$owner" == 0 ]] || continue
        mode="$(stat -c %a -- "$proof" 2>/dev/null || true)"
        recorded_uid="$(access_kv_get "$proof" uid 2>/dev/null || true)"
        user="$(access_kv_get "$proof" user 2>/dev/null || true)"
        verified="$(access_kv_get "$proof" verified_epoch 2>/dev/null || true)"
        [[ "$mode" == 600 && "$recorded_uid" =~ ^[0-9]+$ ]] && ((recorded_uid != 0)) || continue
        [[ -n "$user" && "$(access_user_field "$user" uid 2>/dev/null || true)" == "$recorded_uid" && "$verified" =~ ^[0-9]+$ ]] || continue
        printf '%s\n' "$proof"
        return 0
    done
    return 3
}

access_ssh_commit() {
    local tx_id="$1" confirm_id="$2" tx_dir state status expires now proof proof_tx proof_port proof_auth proof_user
    local backup_id backup_dir old_port new_port root_value password_value kbd_value pubkey_value expose_value fallback firewall_backend firewall_added previous_backend previous_port candidate applied_sha pending_sha current_sha proof_verified created failed=0 rollback_failed=0

    vps_cmd_require_root || return $?
    [[ "$confirm_id" == "$tx_id" ]] || {
        vps_cmd_error "--confirm-apply 必须精确等于事务 ID"
        return 2
    }
    access_prepare_layout || return $?
    vps_cmd_lock security-access || return $?
    tx_dir="$(access_transaction_path "$tx_id")" || {
        vps_cmd_unlock
        return $?
    }
    state="$tx_dir/state"
    [[ -f "$state" && ! -L "$state" ]] || {
        vps_cmd_unlock
        vps_cmd_error "事务不存在：$tx_id"
        return 3
    }
    status="$(access_kv_get "$state" status)" || {
        vps_cmd_unlock
        return 30
    }
    [[ "$status" == prepared ]] || {
        vps_cmd_unlock
        vps_cmd_error "事务不是待提交状态：$status"
        return 3
    }
    expires="$(access_kv_get "$state" expires_epoch)" || {
        vps_cmd_unlock
        return 30
    }
    now="$(date +%s)"
    [[ "$expires" =~ ^[0-9]+$ ]] && ((now <= expires)) || {
        vps_cmd_unlock
        vps_cmd_error "事务已过期；等待自动回滚或执行 abort"
        return 3
    }
    fallback="$(access_kv_get "$state" fallback_user)" || {
        vps_cmd_unlock
        return 30
    }
    proof="$(access_sshd_find_proof "$tx_dir" "$fallback")" || {
        vps_cmd_unlock
        vps_cmd_error "尚无合格的第二个非 root SSH 会话证明"
        return 3
    }
    proof_tx="$(access_kv_get "$proof" transaction_id)" || {
        vps_cmd_unlock
        return 30
    }
    proof_port="$(access_kv_get "$proof" server_port)" || {
        vps_cmd_unlock
        return 30
    }
    proof_auth="$(access_kv_get "$proof" auth_method)" || {
        vps_cmd_unlock
        return 30
    }
    proof_user="$(access_kv_get "$proof" user)" || {
        vps_cmd_unlock
        return 30
    }
    proof_verified="$(access_kv_get "$proof" verified_epoch)" || {
        vps_cmd_unlock
        return 30
    }
    created="$(access_kv_get "$state" created_epoch)" || {
        vps_cmd_unlock
        return 30
    }
    new_port="$(access_kv_get "$state" new_port)" || {
        vps_cmd_unlock
        return 30
    }
    password_value="$(access_kv_get "$state" password_authentication)" || {
        vps_cmd_unlock
        return 30
    }
    [[ "$proof_tx" == "$tx_id" && "$proof_port" == "$new_port" ]] || {
        vps_cmd_unlock
        vps_cmd_error "会话证明与事务不匹配"
        return 30
    }
    [[ "$proof_verified" =~ ^[0-9]+$ && "$created" =~ ^[0-9]+$ && "$proof_verified" -ge "$created" && "$proof_verified" -le "$expires" ]] || {
        vps_cmd_unlock
        vps_cmd_error "会话证明时间无效"
        return 30
    }
    [[ "$password_value" != no || "$proof_auth" == publickey ]] || {
        vps_cmd_unlock
        vps_cmd_error "禁用密码登录需要 publickey 会话证明"
        return 3
    }
    old_port="$(access_kv_get "$state" old_port)" || {
        vps_cmd_unlock
        return 30
    }
    root_value="$(access_kv_get "$state" permit_root_login)" || {
        vps_cmd_unlock
        return 30
    }
    kbd_value="$(access_kv_get "$state" kbd_interactive_authentication)" || {
        vps_cmd_unlock
        return 30
    }
    pubkey_value="$(access_kv_get "$state" pubkey_authentication)" || {
        vps_cmd_unlock
        return 30
    }
    expose_value="$(access_kv_get "$state" original_expose_auth_info)" || {
        vps_cmd_unlock
        return 30
    }
    backup_id="$(access_kv_get "$state" backup_id)" || {
        vps_cmd_unlock
        return 30
    }
    backup_dir="$(access_backup_path "$backup_id")" || {
        vps_cmd_unlock
        return $?
    }
    firewall_backend="$(access_kv_get "$state" firewall_backend)" || {
        vps_cmd_unlock
        return 30
    }
    firewall_added="$(access_kv_get "$state" firewall_added)" || {
        vps_cmd_unlock
        return 30
    }
    previous_backend="$(access_kv_get "$state" previous_firewall_backend)" || {
        vps_cmd_unlock
        return 30
    }
    previous_port="$(access_kv_get "$state" previous_firewall_port)" || {
        vps_cmd_unlock
        return 30
    }
    pending_sha="$(access_kv_get "$state" pending_sha256)" || {
        vps_cmd_unlock
        return 30
    }
    current_sha="$(access_sha256_file "$ACCESS_CONFIG")" || {
        vps_cmd_unlock
        return $?
    }
    [[ "$current_sha" == "$pending_sha" ]] || {
        vps_cmd_unlock
        vps_cmd_error "prepare 后受管 SSH 配置发生漂移，拒绝提交"
        return 30
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_unlock
        vps_cmd_info "演练：证明与配置漂移检查已通过；不会提交配置、收敛防火墙或消费证明"
        return 0
    fi
    candidate="$(mktemp)" || {
        vps_cmd_unlock
        return 20
    }
    access_sshd_render "$old_port" "$new_port" "$root_value" "$password_value" "$kbd_value" "$pubkey_value" "$expose_value" 0 >"$candidate"
    access_sshd_validate_candidate "$candidate" || {
        rm -f -- "$candidate"
        vps_cmd_unlock
        return $?
    }
    access_sshd_install_candidate "$candidate" || {
        rm -f -- "$candidate"
        vps_cmd_unlock
        return 20
    }
    if ! access_sshd_assert_effective "$old_port" "$new_port" "$root_value" "$password_value" "$kbd_value" "$pubkey_value" "$expose_value" 0 "$fallback"; then
        access_sshd_render "$old_port" "$new_port" "$root_value" "$password_value" "$kbd_value" "$pubkey_value" yes 1 >"$candidate"
        access_sshd_install_candidate "$candidate" || rollback_failed=1
        rm -f -- "$candidate"
        vps_cmd_unlock
        ((rollback_failed == 0)) && return 10
        return 30
    fi
    rm -f -- "$candidate"
    if ! access_sshd_reload || ! access_sshd_verify_ports "$old_port" "$new_port" 0; then
        access_sshd_render "$old_port" "$new_port" "$root_value" "$password_value" "$kbd_value" "$pubkey_value" yes 1 >"$candidate"
        access_sshd_install_candidate "$candidate" || rollback_failed=1
        access_sshd_reload || rollback_failed=1
        rm -f -- "$candidate"
        vps_cmd_unlock
        ((rollback_failed == 0)) && return 20
        return 30
    fi
    applied_sha="$(access_sha256_file "$ACCESS_CONFIG")" || {
        vps_cmd_unlock
        return $?
    }
    access_firewall_commit "$firewall_backend" "$old_port" "$new_port" "$firewall_added" "$previous_backend" "$previous_port" || failed=1
    access_sshd_backup_mark "$backup_dir" committed "$applied_sha" || failed=1
    access_sshd_transaction_mark "$state" committed || failed=1
    rm -f -- "$proof" || failed=1
    chmod 0700 -- "$tx_dir/proofs" || failed=1
    access_clear_active "$tx_id" || failed=1
    access_sshd_cancel_abort "$tx_id"
    vps_cmd_unlock
    if ((failed)); then
        vps_cmd_error "SSH 配置已提交到端口 $new_port，但元数据或防火墙收尾失败；备份 ID：$backup_id"
        access_sshd_print_recovery "$backup_dir"
        return 30
    fi
    vps_cmd_success "已提交 SSH 访问事务 $tx_id（证明用户：$proof_user）；备份 ID：$backup_id"
    printf '%s\n' "$backup_id"
}

access_ssh_abort() {
    local tx_id="$1" tx_dir state status backup_id backup_dir backend added new_port previous_backend previous_port failed=0

    vps_cmd_require_root || return $?
    access_prepare_layout || return $?
    vps_cmd_lock security-access || return $?
    tx_dir="$(access_transaction_path "$tx_id")" || {
        vps_cmd_unlock
        return $?
    }
    state="$tx_dir/state"
    [[ -f "$state" && ! -L "$state" ]] || {
        vps_cmd_unlock
        vps_cmd_error "事务不存在：$tx_id"
        return 3
    }
    status="$(access_kv_get "$state" status)" || {
        vps_cmd_unlock
        return 30
    }
    [[ "$status" == prepared ]] || {
        vps_cmd_unlock
        vps_cmd_error "只能回滚 prepared 事务（当前：$status）"
        return 3
    }
    backup_id="$(access_kv_get "$state" backup_id)" || {
        vps_cmd_unlock
        return 30
    }
    backup_dir="$(access_backup_path "$backup_id")" || {
        vps_cmd_unlock
        return $?
    }
    backend="$(access_kv_get "$state" firewall_backend)" || {
        vps_cmd_unlock
        return 30
    }
    added="$(access_kv_get "$state" firewall_added)" || {
        vps_cmd_unlock
        return 30
    }
    new_port="$(access_kv_get "$state" new_port)" || {
        vps_cmd_unlock
        return 30
    }
    previous_backend="$(access_kv_get "$state" previous_firewall_backend)" || {
        vps_cmd_unlock
        return 30
    }
    previous_port="$(access_kv_get "$state" previous_firewall_port)" || {
        vps_cmd_unlock
        return 30
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_unlock
        vps_cmd_info "演练：将从备份 $backup_id 恢复 prepare 前配置、reload SSH 并仅撤销本事务防火墙规则"
        return 0
    fi
    access_sshd_restore_backup_config "$backup_dir" || failed=1
    access_sshd_reload || failed=1
    access_firewall_abort "$backend" "$new_port" "$added" "$previous_backend" "$previous_port" || failed=1
    access_sshd_backup_mark "$backup_dir" aborted '' || failed=1
    access_sshd_transaction_mark "$state" aborted || failed=1
    access_clear_active "$tx_id" || failed=1
    access_sshd_cancel_abort "$tx_id"
    vps_cmd_unlock
    ((failed == 0)) || {
        vps_cmd_error "事务回滚不完整，请用备份 $backup_id 人工恢复"
        access_sshd_print_recovery "$backup_dir"
        return 30
    }
    vps_cmd_success "已回滚 SSH 访问事务 $tx_id"
}

access_ssh_restore() {
    local backup_id="$1" backup_dir manifest lifecycle applied current current_copy failed=0
    local previous_backend='' previous_port='' current_backend='' current_port=''

    vps_cmd_require_root || return $?
    [[ -z "$(access_active_transaction 2>/dev/null || true)" ]] || {
        vps_cmd_error "存在活动事务；请先 abort 后再 restore"
        return 3
    }
    backup_dir="$(access_backup_path "$backup_id")" || return $?
    manifest="$backup_dir/manifest"
    [[ -f "$manifest" && ! -L "$manifest" ]] || {
        vps_cmd_error "备份不存在或无效：$backup_id"
        return 3
    }
    lifecycle="$(access_kv_get "$manifest" lifecycle)" || return 30
    [[ "$lifecycle" == committed ]] || {
        vps_cmd_error "只允许恢复已提交事务的备份（当前：$lifecycle）"
        return 3
    }
    applied="$(access_kv_get "$manifest" applied_sha256)" || return 30
    [[ -f "$ACCESS_CONFIG" && ! -L "$ACCESS_CONFIG" ]] || {
        vps_cmd_error "当前受管 SSH 配置缺失，拒绝盲目覆盖"
        return 30
    }
    current="$(access_sha256_file "$ACCESS_CONFIG")" || return $?
    [[ "$current" == "$applied" ]] || {
        vps_cmd_error "当前受管 SSH 配置已变化；所有权校验失败，拒绝恢复旧备份"
        return 30
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：已通过漂移检查，将恢复 SSH 备份 $backup_id 并仅调整 vpsctl 自有防火墙规则"
        return 0
    fi
    vps_cmd_confirm_token "恢复会替换当前 SSH 访问配置并调整防火墙" "$backup_id" || {
        vps_cmd_error "restore 必须在 TTY 中输入备份 ID 强确认；--yes 不会绕过"
        return 3
    }
    access_prepare_layout || return $?
    vps_cmd_lock security-access || return $?
    current="$(access_sha256_file "$ACCESS_CONFIG")" || {
        vps_cmd_unlock
        return $?
    }
    [[ "$current" == "$applied" ]] || {
        vps_cmd_unlock
        vps_cmd_error "受管 SSH 配置在获取操作锁前发生变化，拒绝恢复"
        return 30
    }
    current_copy="$(mktemp)" || {
        vps_cmd_unlock
        return 20
    }
    cp -p -- "$ACCESS_CONFIG" "$current_copy" || {
        rm -f -- "$current_copy"
        vps_cmd_unlock
        return 20
    }
    access_sshd_restore_backup_config "$backup_dir" || failed=1
    if ((failed == 0)); then
        if [[ -f "$ACCESS_CONFIG" ]]; then
            access_sshd_validate_standard || failed=1
        else
            local sshd
            sshd="$(access_sshd_binary)" || failed=1
            ((failed)) || "$sshd" -t -f "$ACCESS_MAIN_CONFIG" || failed=1
        fi
    fi
    ((failed)) || access_sshd_reload || failed=1
    if ((failed)); then
        access_sshd_install_candidate "$current_copy" || true
        access_sshd_reload || true
        rm -f -- "$current_copy"
        vps_cmd_unlock
        vps_cmd_error "恢复后的 SSH 配置验证失败，已尝试回到恢复前状态"
        access_sshd_print_recovery "$backup_dir"
        return 30
    fi
    rm -f -- "$current_copy"
    access_firewall_load_managed
    current_backend="$ACCESS_FW_PREVIOUS_BACKEND"
    current_port="$ACCESS_FW_PREVIOUS_PORT"
    if [[ -f "$backup_dir/firewall.state" ]]; then
        previous_backend="$(access_kv_get "$backup_dir/firewall.state" backend 2>/dev/null || true)"
        previous_port="$(access_kv_get "$backup_dir/firewall.state" port 2>/dev/null || true)"
    fi
    if [[ -n "$current_backend" && "$current_backend:$current_port" != "$previous_backend:$previous_port" ]]; then
        access_firewall_close "$current_backend" "$current_port" 1 || failed=1
    fi
    if [[ -n "$previous_backend" && "$current_backend:$current_port" != "$previous_backend:$previous_port" ]]; then
        access_firewall_require_auto_backend "$previous_backend" || failed=1
        if ((failed == 0)); then
            access_firewall_open "$previous_backend" "$previous_port" '' 1 || failed=1
            access_firewall_write_state "$previous_backend" "$previous_port" || failed=1
        fi
    elif [[ -z "$previous_backend" ]]; then
        access_firewall_write_state '' '' || failed=1
    fi
    access_sshd_backup_mark "$backup_dir" restored "$applied" || failed=1
    vps_cmd_unlock
    ((failed == 0)) || {
        vps_cmd_error "SSH 配置已恢复，但防火墙或元数据恢复不完整"
        access_sshd_print_recovery "$backup_dir"
        return 30
    }
    vps_cmd_success "已恢复备份 $backup_id"
}
