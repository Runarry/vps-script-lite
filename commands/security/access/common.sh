# shellcheck shell=bash

readonly ACCESS_MANAGED_MARKER='# Managed by vpsctl security access.'
readonly ACCESS_STATE_LOGICAL='/var/lib/vpsctl/security/access'
readonly ACCESS_BACKUP_LOGICAL='/var/lib/vpsctl/backups/security/access'
readonly ACCESS_CONFIG_LOGICAL='/etc/ssh/sshd_config.d/00-vpsctl-access.conf'
readonly ACCESS_MAIN_CONFIG_LOGICAL='/etc/ssh/sshd_config'

ACCESS_STATE_DIR=''
ACCESS_TRANSACTION_DIR=''
ACCESS_BACKUP_DIR=''
ACCESS_CONFIG=''
ACCESS_MAIN_CONFIG=''
ACCESS_SECRET_DIR=''

access_common_init() {
    ACCESS_STATE_DIR="$(vps_cmd_system_path "$ACCESS_STATE_LOGICAL")" || return $?
    ACCESS_TRANSACTION_DIR="$(vps_cmd_system_path "${ACCESS_STATE_LOGICAL}/transactions")" || return $?
    ACCESS_BACKUP_DIR="$(vps_cmd_system_path "$ACCESS_BACKUP_LOGICAL")" || return $?
    ACCESS_CONFIG="$(vps_cmd_system_path "$ACCESS_CONFIG_LOGICAL")" || return $?
    ACCESS_MAIN_CONFIG="$(vps_cmd_system_path "$ACCESS_MAIN_CONFIG_LOGICAL")" || return $?
}

access_cleanup_secret() {
    local secret_dir="${ACCESS_SECRET_DIR:-}"

    ACCESS_SECRET_DIR=''
    [[ -n "$secret_dir" && "$secret_dir" == /tmp/vpsctl-access-key.* ]] || return 0
    [[ ! -L "$secret_dir" && -d "$secret_dir" ]] || return 0
    rm -f -- "$secret_dir/id_key" "$secret_dir/id_key.pub" 2>/dev/null || true
    rmdir -- "$secret_dir" 2>/dev/null || true
}

access_require_platform() {
    local os_id init

    if [[ "${VPSCTL_TESTING:-0}" == 1 ]]; then
        os_id="${VPSCTL_ENV_OS_ID:-ubuntu}"
        init="${VPSCTL_ENV_INIT:-systemd}"
    else
        os_id="${VPSCTL_ENV_OS_ID:-}"
        init="${VPSCTL_ENV_INIT:-}"
        if [[ -z "$os_id" && -r /etc/os-release ]]; then
            os_id="$(awk -F= '$1 == "ID" {gsub(/^\"|\"$/, "", $2); print tolower($2); exit}' /etc/os-release)"
        fi
        if [[ -z "$init" ]] && [[ -d /run/systemd/system ]]; then
            init=systemd
        fi
    fi
    case "$os_id" in
        debian | ubuntu | rhel | centos | rocky | almalinux | ol | fedora) ;;
        *)
            vps_cmd_error "security access 仅支持 Debian/Ubuntu 与 RHEL 系发行版（当前：${os_id:-未知}）"
            return 3
            ;;
    esac
    [[ "$init" == systemd ]] || {
        vps_cmd_error "security access 仅支持 systemd；OpenRC 与其他 init 系统不受支持"
        return 3
    }
    VPSCTL_ENV_OS_ID="$os_id"
    VPSCTL_ENV_INIT="$init"
    access_sshd_init || return $?
    command -v systemctl >/dev/null 2>&1 || {
        vps_cmd_error "未找到 systemctl，无法安全管理 SSH 服务"
        return 3
    }
}

access_validate_user_name() {
    [[ "${1:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

access_require_user() {
    local user="${1:-}" entry

    access_validate_user_name "$user" || {
        vps_cmd_error "无效的用户名：${user:-<空>}"
        return 2
    }
    entry="$(getent passwd "$user" 2>/dev/null || true)"
    [[ -n "$entry" ]] || {
        vps_cmd_error "用户不存在：$user"
        return 3
    }
    printf '%s\n' "$entry"
}

access_login_uid_min() {
    local login_defs value

    login_defs="$(vps_cmd_system_path /etc/login.defs)" || return $?
    value=''
    if [[ -r "$login_defs" && -f "$login_defs" && ! -L "$login_defs" ]]; then
        value="$(awk '$1 == "UID_MIN" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$login_defs")"
    fi
    printf '%s\n' "${value:-1000}"
}

access_require_login_user() {
    local user="$1" entry uid shell uid_min

    entry="$(access_require_user "$user")" || return $?
    IFS=: read -r _ _ uid _ _ _ shell <<<"$entry"
    if [[ "$user" == root && "$uid" == 0 ]]; then
        return 0
    fi
    uid_min="$(access_login_uid_min)" || return $?
    [[ "$uid" =~ ^[0-9]+$ && "$uid_min" =~ ^[0-9]+$ && "$uid" -ge "$uid_min" ]] || {
        vps_cmd_error "拒绝修改系统服务账户：$user（uid=$uid，UID_MIN=$uid_min）"
        return 3
    }
    case "$shell" in
        '' | /bin/false | /usr/bin/false | /sbin/nologin | /usr/sbin/nologin)
            vps_cmd_error "拒绝修改不可登录的系统账户：$user（shell=${shell:-空}）"
            return 3
            ;;
    esac
}

access_user_field() {
    local user="$1" field="$2" entry old_ifs="$IFS"
    local _ uid gid home shell

    entry="$(access_require_user "$user")" || return $?
    IFS=: read -r _ _ uid gid _ home shell <<<"$entry"
    IFS="$old_ifs"
    case "$field" in
        uid) printf '%s\n' "$uid" ;;
        gid) printf '%s\n' "$gid" ;;
        home) printf '%s\n' "$home" ;;
        shell) printf '%s\n' "$shell" ;;
        *) return 70 ;;
    esac
}

access_validate_port() {
    [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#$1 >= 1 && 10#$1 <= 65535))
}

access_validate_id() {
    case "${1:-}" in
        tx-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f] | \
            bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
        *) return 1 ;;
    esac
}

access_random_hex() {
    local value

    value="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || return 20
    [[ "$value" =~ ^[0-9a-f]{16}$ ]] || return 20
    printf '%s\n' "$value"
}

access_new_id() {
    local prefix="$1" random

    random="$(access_random_hex)" || return $?
    printf '%s-%s-%s\n' "$prefix" "$(date -u +%Y%m%dT%H%M%SZ)" "$random"
}

access_sha256_file() {
    local output

    output="$(sha256sum -- "$1" 2>/dev/null)" || return 20
    output="${output%%[[:space:]]*}"
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || return 20
    printf '%s\n' "$output"
}

access_kv_get() {
    local file="$1" key="$2"

    [[ "$key" =~ ^[a-z][a-z0-9_]*$ ]] || return 2
    [[ -f "$file" && ! -L "$file" ]] || return 3
    awk -v wanted="$key" '
        {
            separator=index($0, "\t")
            if (separator > 0 && substr($0, 1, separator - 1) == wanted) {
                print substr($0, separator + 1)
                found=1
                exit
            }
        }
        END { if (!found) exit 1 }
    ' "$file"
}

access_kv_put() {
    local key="$1" value="${2:-}"

    [[ "$key" =~ ^[a-z][a-z0-9_]*$ ]] || return 2
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] || return 2
    printf '%s\t%s\n' "$key" "$value"
}

access_physical_to_logical() {
    local path="$1"

    if [[ "${VPSCTL_TESTING:-0}" == 1 ]]; then
        [[ "$path" == "${VPSCTL_SYSTEM_ROOT%/}/"* ]] || return 2
        printf '/%s\n' "${path#"${VPSCTL_SYSTEM_ROOT%/}/"}"
    else
        printf '%s\n' "$path"
    fi
}

access_atomic_from_file() {
    local source="$1" target="$2" mode="$3" logical

    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：将原子写入 $target（权限 $mode）"
        return 0
    fi
    logical="$(access_physical_to_logical "$target")" || return $?
    vps_cmd_atomic_write "$logical" "$mode" <"$source"
}

access_prepare_layout() {
    local path

    for path in "$ACCESS_STATE_DIR" "$ACCESS_TRANSACTION_DIR" "$ACCESS_BACKUP_DIR"; do
        vps_cmd_require_no_symlink_components "$path" || return $?
    done
    vps_cmd_run mkdir -p -- "$ACCESS_STATE_DIR" "$ACCESS_TRANSACTION_DIR" "$ACCESS_BACKUP_DIR" || return 20
    vps_cmd_run chmod 0755 -- "$ACCESS_STATE_DIR" "$ACCESS_TRANSACTION_DIR" || return 20
    vps_cmd_run chmod 0700 -- "$ACCESS_BACKUP_DIR" || return 20
}

access_transaction_path() {
    local id="$1"

    [[ "$id" == tx-* ]] && access_validate_id "$id" || {
        vps_cmd_error "无效的事务 ID：${id:-<空>}"
        return 2
    }
    printf '%s/%s\n' "$ACCESS_TRANSACTION_DIR" "$id"
}

access_backup_path() {
    local id="$1"

    [[ "$id" == bak-* ]] && access_validate_id "$id" || {
        vps_cmd_error "无效的备份 ID：${id:-<空>}"
        return 2
    }
    printf '%s/%s\n' "$ACCESS_BACKUP_DIR" "$id"
}

access_active_transaction() {
    local active_file="${ACCESS_STATE_DIR}/active" id

    [[ -f "$active_file" && ! -L "$active_file" ]] || return 1
    IFS= read -r id <"$active_file" || return 1
    [[ "$id" == tx-* ]] && access_validate_id "$id" || return 1
    printf '%s\n' "$id"
}

access_write_active() {
    local id="$1" tmp

    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    tmp="$(mktemp "${ACCESS_STATE_DIR}/.active.XXXXXX")" || return 20
    printf '%s\n' "$id" >"$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    chmod 0644 -- "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    mv -f -- "$tmp" "${ACCESS_STATE_DIR}/active" || {
        rm -f -- "$tmp"
        return 20
    }
}

access_clear_active() {
    local expected="$1" current

    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    current="$(access_active_transaction 2>/dev/null || true)"
    [[ -z "$current" || "$current" == "$expected" ]] || return 30
    rm -f -- "${ACCESS_STATE_DIR}/active" || return 20
}

access_json_escape() {
    local value="${1:-}"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}
