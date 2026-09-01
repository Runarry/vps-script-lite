# shellcheck shell=bash

access_key_ensure_ssh_keygen() {
    local manager package

    command -v ssh-keygen >/dev/null 2>&1 && return 0
    if [[ "${VPSCTL_INSTALL_DEPS:-0}" != 1 ]]; then
        if vps_cmd_is_interactive; then
            vps_cmd_confirm "缺少 ssh-keygen，是否安装 OpenSSH 客户端工具？" || return 3
        else
            vps_cmd_error "缺少 ssh-keygen；请安装 OpenSSH 客户端，或添加 --install-deps"
            return 3
        fi
    fi
    manager="$(vps_cmd_detect_package_manager)" || return $?
    case "$manager" in
        apt-get) package=openssh-client ;;
        dnf5 | dnf | yum) package=openssh-clients ;;
        *)
            vps_cmd_error "当前包管理器没有经过验证的 ssh-keygen 软件包映射"
            return 3
            ;;
    esac
    vps_cmd_install_packages "$manager" "$package" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_warning "演练已列出依赖安装；安装后需重新运行以完成密钥安全校验"
        return 3
    fi
    hash -r
    command -v ssh-keygen >/dev/null 2>&1 || return 20
}

access_key_authorized_path() {
    local user="$1" home

    home="$(access_user_field "$user" home)" || return $?
    [[ "$home" == /* && "$home" != / && "$home" != *$'\n'* && "$home" != *$'\r'* ]] || {
        vps_cmd_error "用户 $user 的主目录无效：$home"
        return 3
    }
    printf '%s/.ssh/authorized_keys\n' "$(vps_cmd_system_path "$home")"
}

access_key_validate_line() {
    local line="$1" first rest second tmp

    [[ -n "$line" && "$line" != *$'\n'* && "$line" != *$'\r'* && ${#line} -le 16384 ]] || {
        vps_cmd_error "公钥必须是单行且长度不超过 16384 字节"
        return 10
    }
    first="${line%%[[:space:]]*}"
    rest="${line#"$first"}"
    rest="$(vps_cmd_trim "$rest")"
    second="${rest%%[[:space:]]*}"
    case "$first" in
        ssh-ed25519 | ssh-rsa | ecdsa-sha2-nistp256 | ecdsa-sha2-nistp384 | ecdsa-sha2-nistp521 | sk-ssh-ed25519@openssh.com | sk-ecdsa-sha2-nistp256@openssh.com) ;;
        *)
            vps_cmd_error "公钥必须以受支持的 OpenSSH 密钥类型开头；不接受 authorized_keys 选项"
            return 10
            ;;
    esac
    [[ "$second" =~ ^[A-Za-z0-9+/]+={0,3}$ ]] || {
        vps_cmd_error "公钥主体不是有效的单行 Base64"
        return 10
    }
    access_key_ensure_ssh_keygen || return $?
    tmp="$(mktemp)" || return 20
    printf '%s\n' "$line" >"$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    chmod 0600 -- "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
        rm -f -- "$tmp"
        vps_cmd_error "ssh-keygen 无法解析该公钥"
        return 10
    fi
    rm -f -- "$tmp"
}

access_key_require_pubkey_enabled() {
    local effective

    access_sshd_validate_standard || return $?
    effective="$(access_sshd_effective_value pubkeyauthentication)" || return $?
    [[ "$effective" == yes ]] || {
        vps_cmd_error "当前 sshd 的 PubkeyAuthentication 未启用；请先通过 ssh prepare 安全启用"
        return 3
    }
}

access_user_has_authorized_key() {
    local user="$1" authorized line tmp valid=1

    authorized="$(access_key_authorized_path "$user")" || return $?
    [[ -f "$authorized" && ! -L "$authorized" && -r "$authorized" ]] || return 1
    while IFS= read -r line; do
        [[ -n "$line" && "${line#\#}" == "$line" ]] || continue
        tmp="$(mktemp)" || return 20
        printf '%s\n' "$line" >"$tmp" || {
            rm -f -- "$tmp"
            return 20
        }
        if ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
            valid=0
            rm -f -- "$tmp"
            break
        fi
        rm -f -- "$tmp"
    done <"$authorized"
    return "$valid"
}

ACCESS_KEY_ADDED=0
ACCESS_KEY_ADDED_PATH=''
ACCESS_KEY_ADDED_TYPE=''
ACCESS_KEY_ADDED_BLOB=''
ACCESS_KEY_BACKUP_ID=''
ACCESS_KEY_BACKUP_DIR=''

access_key_create_backup() {
    local user="$1" authorized="$2" backup_id backup_dir present=0 mode='' uid='' gid='' original_sha='' tmp logical

    backup_id="$(access_new_id bak)" || return $?
    backup_dir="$(access_backup_path "$backup_id")" || return $?
    mkdir -p -- "$backup_dir" || return 20
    chmod 0700 -- "$backup_dir" || return 20
    logical="$(access_physical_to_logical "$authorized")" || return $?
    if [[ -f "$authorized" ]]; then
        present=1
        mode="$(stat -c %a -- "$authorized")" || return 20
        uid="$(stat -c %u -- "$authorized")" || return 20
        gid="$(stat -c %g -- "$authorized")" || return 20
        original_sha="$(access_sha256_file "$authorized")" || return $?
        cp -p -- "$authorized" "$backup_dir/authorized_keys" || return 20
        chmod 0600 -- "$backup_dir/authorized_keys" || return 20
    else
        uid="$(access_user_field "$user" uid)" || return $?
        gid="$(access_user_field "$user" gid)" || return $?
        mode=600
    fi
    tmp="$(mktemp "${backup_dir}/.manifest.XXXXXX")" || return 20
    {
        access_kv_put schema_version 1
        access_kv_put kind authorized_keys
        access_kv_put backup_id "$backup_id"
        access_kv_put lifecycle prepared
        access_kv_put user "$user"
        access_kv_put path "$logical"
        access_kv_put original_present "$present"
        access_kv_put original_mode "$mode"
        access_kv_put original_uid "$uid"
        access_kv_put original_gid "$gid"
        access_kv_put original_sha256 "$original_sha"
        access_kv_put applied_sha256 ''
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
    ACCESS_KEY_BACKUP_ID="$backup_id"
    ACCESS_KEY_BACKUP_DIR="$backup_dir"
}

access_key_mark_backup() {
    local lifecycle="$1" applied_sha="$2" manifest="$ACCESS_KEY_BACKUP_DIR/manifest" tmp key value

    [[ -f "$manifest" && ! -L "$manifest" ]] || return 30
    tmp="$(mktemp "${ACCESS_KEY_BACKUP_DIR}/.manifest.XXXXXX")" || return 20
    while IFS=$'\t' read -r key value; do
        case "$key" in
            lifecycle) access_kv_put lifecycle "$lifecycle" ;;
            applied_sha256) access_kv_put applied_sha256 "$applied_sha" ;;
            *) access_kv_put "$key" "$value" ;;
        esac
    done <"$manifest" >"$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    chmod 0600 -- "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    mv -f -- "$tmp" "$manifest" || {
        rm -f -- "$tmp"
        return 20
    }
}

access_key_add_line_locked() {
    local user="$1" line="$2" authorized="$3" ssh_dir="$4" uid="$5" gid="$6" tmp

    if [[ -f "$authorized" ]] && awk -v wanted_type="${line%%[[:space:]]*}" -v wanted_blob="$(vps_cmd_trim "${line#"${line%%[[:space:]]*}"}")" '
        BEGIN { split(wanted_blob, p, /[[:space:]]+/); wanted_blob=p[1] }
        $1 == wanted_type && $2 == wanted_blob { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$authorized"; then
        vps_cmd_info "该公钥已由并发操作添加到 $user 的 authorized_keys"
        return 0
    fi
    access_key_create_backup "$user" "$authorized" || return $?
    mkdir -p -- "$ssh_dir" || return 20
    chmod 0700 -- "$ssh_dir" || return 20
    chown "$uid:$gid" -- "$ssh_dir" || return 20
    vps_cmd_require_no_symlink_components "$ssh_dir" || return $?
    vps_cmd_require_no_symlink_components "$authorized" || return $?
    tmp="$(mktemp "${ssh_dir}/.authorized_keys.XXXXXX")" || return 20
    if [[ -f "$authorized" ]]; then
        cat -- "$authorized" >"$tmp" || {
            rm -f -- "$tmp"
            return 20
        }
        [[ ! -s "$tmp" ]] || [[ "$(tail -c 1 -- "$tmp" 2>/dev/null || true)" == '' ]] || printf '\n' >>"$tmp"
    fi
    printf '%s\n' "$line" >>"$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    chmod 0600 -- "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    chown "$uid:$gid" -- "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    mv -f -- "$tmp" "$authorized" || {
        rm -f -- "$tmp"
        return 20
    }
    ACCESS_KEY_ADDED=1
    ACCESS_KEY_ADDED_PATH="$authorized"
    ACCESS_KEY_ADDED_TYPE="${line%%[[:space:]]*}"
    ACCESS_KEY_ADDED_BLOB="$(vps_cmd_trim "${line#"${line%%[[:space:]]*}"}")"
    ACCESS_KEY_ADDED_BLOB="${ACCESS_KEY_ADDED_BLOB%%[[:space:]]*}"
    access_key_mark_backup committed "$(access_sha256_file "$authorized")" || return 30
    vps_cmd_success "已添加 $user 的 SSH 公钥"
    vps_cmd_info "authorized_keys 备份 ID：$ACCESS_KEY_BACKUP_ID"
}

access_key_add_line() {
    local user="$1" line="$2" authorized ssh_dir uid gid status=0

    ACCESS_KEY_ADDED=0
    ACCESS_KEY_ADDED_PATH=''
    ACCESS_KEY_ADDED_TYPE=''
    ACCESS_KEY_ADDED_BLOB=''
    vps_cmd_require_root || return $?
    access_require_login_user "$user" || return $?
    access_key_require_pubkey_enabled || return $?
    access_key_validate_line "$line" || return $?
    authorized="$(access_key_authorized_path "$user")" || return $?
    ssh_dir="${authorized%/*}"
    uid="$(access_user_field "$user" uid)" || return $?
    gid="$(access_user_field "$user" gid)" || return $?
    vps_cmd_require_no_symlink_components "$ssh_dir" || return $?
    vps_cmd_require_no_symlink_components "$authorized" || return $?
    [[ ! -e "$ssh_dir" || -d "$ssh_dir" ]] || {
        vps_cmd_error "$ssh_dir 不是目录"
        return 3
    }
    [[ ! -e "$authorized" || -f "$authorized" ]] || {
        vps_cmd_error "$authorized 不是普通文件"
        return 3
    }
    if [[ -f "$authorized" ]] && awk -v wanted_type="${line%%[[:space:]]*}" -v wanted_blob="$(vps_cmd_trim "${line#"${line%%[[:space:]]*}"}")" '
        BEGIN { split(wanted_blob, p, /[[:space:]]+/); wanted_blob=p[1] }
        $1 == wanted_type && $2 == wanted_blob { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$authorized"; then
        vps_cmd_info "该公钥已存在于 $user 的 authorized_keys"
        return 0
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：将公钥去重后写入 $user 的 authorized_keys"
        return 0
    fi
    access_prepare_layout || return $?
    vps_cmd_lock security-access || return $?
    access_key_add_line_locked "$user" "$line" "$authorized" "$ssh_dir" "$uid" "$gid" || status=$?
    vps_cmd_unlock
    return "$status"
}

access_key_rollback_last_add_locked() {
    local authorized="${ACCESS_KEY_ADDED_PATH:-}" tmp

    [[ "${ACCESS_KEY_ADDED:-0}" == 1 && -f "$authorized" && ! -L "$authorized" ]] || return 0
    tmp="$(mktemp "${authorized%/*}/.authorized_keys.rollback.XXXXXX")" || return 20
    awk -v wanted_type="$ACCESS_KEY_ADDED_TYPE" -v wanted_blob="$ACCESS_KEY_ADDED_BLOB" '
        BEGIN { removed=0 }
        {
            if (!removed && $1 == wanted_type && $2 == wanted_blob) { removed=1; next }
            print
        }
        END { if (!removed) exit 1 }
    ' "$authorized" >"$tmp" || {
        rm -f -- "$tmp"
        return 30
    }
    chmod --reference="$authorized" "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    chown --reference="$authorized" "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    mv -f -- "$tmp" "$authorized" || {
        rm -f -- "$tmp"
        return 20
    }
    if [[ -n "$ACCESS_KEY_BACKUP_DIR" && "$(access_kv_get "$ACCESS_KEY_BACKUP_DIR/manifest" original_present 2>/dev/null || true)" == 0 ]]; then
        rm -f -- "$authorized" || return 20
        access_key_mark_backup rolled_back '' || return 30
    elif [[ -n "$ACCESS_KEY_BACKUP_DIR" ]]; then
        access_key_mark_backup rolled_back "$(access_sha256_file "$authorized")" || return 30
    fi
    ACCESS_KEY_ADDED=0
}

access_key_rollback_last_add() {
    local status=0

    access_prepare_layout || return $?
    vps_cmd_lock security-access || return $?
    access_key_rollback_last_add_locked || status=$?
    vps_cmd_unlock
    return "$status"
}

access_key_restore_locked() {
    local backup_id="$1" backup_dir="$2" manifest="$3" user="$4" expected="$5" applied="$6"
    local present mode uid gid tmp

    [[ "$(access_sha256_file "$expected")" == "$applied" ]] || {
        vps_cmd_error "authorized_keys 在获取操作锁前发生变化，拒绝覆盖"
        return 30
    }
    present="$(access_kv_get "$manifest" original_present)" || return 30
    if [[ "$present" == 1 ]]; then
        mode="$(access_kv_get "$manifest" original_mode)" || return 30
        uid="$(access_kv_get "$manifest" original_uid)" || return 30
        gid="$(access_kv_get "$manifest" original_gid)" || return 30
        tmp="$backup_dir/authorized_keys"
        [[ -f "$tmp" && ! -L "$tmp" ]] || return 30
        [[ "$(access_sha256_file "$tmp")" == "$(access_kv_get "$manifest" original_sha256)" ]] || return 30
        access_atomic_from_file "$tmp" "$expected" "$mode" || return $?
        chown "$uid:$gid" -- "$expected" || return 30
    elif [[ "$present" == 0 ]]; then
        rm -f -- "$expected" || return 20
    else
        return 30
    fi
    ACCESS_KEY_BACKUP_DIR="$backup_dir"
    access_key_mark_backup restored "$applied" || return 30
    vps_cmd_success "已恢复 $user 的 authorized_keys 备份 $backup_id"
}

access_key_restore() {
    local backup_id="$1" backup_dir manifest user logical expected current applied status=0

    vps_cmd_require_root || return $?
    backup_dir="$(access_backup_path "$backup_id")" || return $?
    manifest="$backup_dir/manifest"
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 3
    [[ "$(access_kv_get "$manifest" kind)" == authorized_keys ]] || return 3
    [[ "$(access_kv_get "$manifest" lifecycle)" == committed ]] || {
        vps_cmd_error "该 authorized_keys 备份不是可恢复的 committed 状态"
        return 3
    }
    user="$(access_kv_get "$manifest" user)" || return 30
    logical="$(access_kv_get "$manifest" path)" || return 30
    expected="$(access_key_authorized_path "$user")" || return $?
    [[ "$(access_physical_to_logical "$expected")" == "$logical" ]] || {
        vps_cmd_error "备份路径与用户当前主目录不匹配"
        return 30
    }
    applied="$(access_kv_get "$manifest" applied_sha256)" || return 30
    [[ -f "$expected" && ! -L "$expected" ]] || {
        vps_cmd_error "当前 authorized_keys 缺失"
        return 30
    }
    current="$(access_sha256_file "$expected")" || return $?
    [[ "$current" == "$applied" ]] || {
        vps_cmd_error "authorized_keys 已在备份后变化，拒绝覆盖"
        return 30
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：已通过漂移检查，将恢复 $user 的 authorized_keys 备份 $backup_id"
        return 0
    fi
    vps_cmd_confirm_token "恢复会替换 $user 的 authorized_keys" "$backup_id" || return 3
    access_prepare_layout || return $?
    vps_cmd_lock security-access || return $?
    access_key_restore_locked "$backup_id" "$backup_dir" "$manifest" "$user" "$expected" "$applied" || status=$?
    vps_cmd_unlock
    return "$status"
}

access_key_add() {
    local user="$1" source_kind="$2" source_value="${3:-}" line extra

    case "$source_kind" in
        stdin)
            IFS= read -r line || {
                vps_cmd_error "标准输入中没有公钥"
                return 2
            }
            extra=''
            if IFS= read -r extra || [[ -n "$extra" ]]; then
                vps_cmd_error "--stdin 只接受一行公钥"
                return 2
            fi
            ;;
        file)
            [[ -f "$source_value" && ! -L "$source_value" && -r "$source_value" ]] || {
                vps_cmd_error "公钥文件必须是可读普通文件且不能是符号链接：$source_value"
                return 3
            }
            IFS= read -r line <"$source_value" || {
                vps_cmd_error "公钥文件为空：$source_value"
                return 10
            }
            extra=''
            if {
                IFS= read -r _
                IFS= read -r extra || [[ -n "$extra" ]]
            } <"$source_value"; then
                vps_cmd_error "公钥文件只能包含一行"
                return 10
            fi
            ;;
        *) return 70 ;;
    esac
    access_key_add_line "$user" "$line"
}

access_key_generate() {
    local user="$1" key_file key_type=ed25519 saved=''

    vps_cmd_require_root || return $?
    access_require_login_user "$user" || return $?
    access_key_ensure_ssh_keygen || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：将生成一次性 Ed25519（失败时 RSA-4096）密钥并添加公钥"
        return 0
    fi
    [[ -t 1 ]] || {
        vps_cmd_error "key generate 只允许把一次性私钥输出到 TTY；拒绝管道、重定向和日志捕获"
        return 3
    }
    ACCESS_SECRET_DIR="$(mktemp -d /tmp/vpsctl-access-key.XXXXXX)" || return 20
    chmod 0700 -- "$ACCESS_SECRET_DIR" || {
        access_cleanup_secret
        return 20
    }
    key_file="${ACCESS_SECRET_DIR}/id_key"
    printf 'ssh-keygen 将询问可选口令；留空表示无口令。\n' >/dev/tty
    if ! ssh-keygen -q -t ed25519 -C "vpsctl-${user}" -f "$key_file" </dev/tty >/dev/tty; then
        rm -f -- "$key_file" "$key_file.pub"
        key_type=rsa-4096
        printf 'Ed25519 不可用，回退到 RSA-4096。\n' >/dev/tty
        ssh-keygen -q -t rsa -b 4096 -C "vpsctl-${user}" -f "$key_file" </dev/tty >/dev/tty || {
            access_cleanup_secret
            vps_cmd_error "Ed25519 与 RSA-4096 密钥生成均失败"
            return 20
        }
    fi
    access_key_add_line "$user" "$(<"$key_file.pub")" || {
        access_cleanup_secret
        return $?
    }
    printf '\n一次性私钥（%s，仅此次显示；请立即保存到安全位置）：\n\n' "$key_type" >/dev/tty
    cat -- "$key_file" >/dev/tty
    printf '\n\n保存完成后请输入 SAVED；其他输入将撤销刚添加的公钥：' >/dev/tty
    IFS= read -r saved </dev/tty || saved=''
    if [[ "$saved" != SAVED ]]; then
        if ! access_key_rollback_last_add; then
            access_cleanup_secret
            vps_cmd_error "未确认保存私钥，且无法精确撤销本次公钥；请立即人工检查 authorized_keys"
            return 30
        fi
        access_cleanup_secret
        vps_cmd_warning "未确认 SAVED；一次性私钥已删除，本次新增公钥已撤销"
        return 130
    fi
    access_cleanup_secret
    vps_cmd_warning "一次性私钥已从服务器临时目录删除，无法再次显示"
}
