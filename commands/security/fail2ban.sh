#!/usr/bin/env bash
# Manage a deliberately small, SSH-only Fail2ban policy.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

FAIL2BAN_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly FAIL2BAN_PROJECT_ROOT

# shellcheck source=../../lib/command.sh
source "${FAIL2BAN_PROJECT_ROOT}/lib/command.sh"

readonly FAIL2BAN_MARKER='# Managed by vpsctl security fail2ban.'
readonly FAIL2BAN_CONFIG_LOGICAL='/etc/fail2ban/jail.d/99-vpsctl-sshd.local'
readonly FAIL2BAN_STATE_LOGICAL='/var/lib/vpsctl/security/fail2ban'
readonly FAIL2BAN_BACKUP_LOGICAL='/var/lib/vpsctl/backups/security/fail2ban'
readonly FAIL2BAN_HASH_LOGICAL="${FAIL2BAN_STATE_LOGICAL}/config.sha256"
readonly FAIL2BAN_METADATA_LOGICAL="${FAIL2BAN_STATE_LOGICAL}/metadata"
readonly FAIL2BAN_SERVICE='fail2ban.service'
readonly FAIL2BAN_UNINSTALL_TOKEN='REMOVE-VPSCTL-FAIL2BAN'
readonly FAIL2BAN_VERIFY_IP='192.0.2.1'
readonly FAIL2BAN_MIN_VERSION='0.11'

FAIL2BAN_CONFIG=''
FAIL2BAN_STATE_DIR=''
FAIL2BAN_BACKUP_DIR=''
FAIL2BAN_HASH_FILE=''
FAIL2BAN_METADATA_FILE=''
FAIL2BAN_VERIFY_SELECTED=''
FAIL2BAN_ARGS=()

FAIL2BAN_BANTIME='1h'
FAIL2BAN_FINDTIME='10m'
FAIL2BAN_MAXRETRY='5'
FAIL2BAN_INCREMENT='on'
FAIL2BAN_MAX_BANTIME='1w'
FAIL2BAN_PORT='22'
FAIL2BAN_BANACTION='iptables-multiport'
FAIL2BAN_IGNORE=()

fail2ban_usage() {
    cat <<'EOF'
为 OpenSSH 管理独立、可回滚的 Fail2ban sshd jail。

用法：
  fail2ban.sh [global-options] status [--json]
  fail2ban.sh [global-options] install [--ignore-ip IP_OR_CIDR]...
      [--ignore-current-session] [--adopt-existing]
  fail2ban.sh [global-options] configure [--bantime DURATION]
      [--findtime DURATION] [--maxretry 1..100] [--increment on|off]
      [--max-bantime DURATION]
  fail2ban.sh [global-options] sync-ssh-port
  fail2ban.sh [global-options] ignore list
  fail2ban.sh [global-options] ignore add|remove --ip IP_OR_CIDR
  fail2ban.sh [global-options] unban --ip IP
  fail2ban.sh [global-options] verify
  fail2ban.sh [global-options] start|stop|restart
  fail2ban.sh [global-options] logs [--lines N]
  fail2ban.sh [global-options] restore --backup ID --confirm-restore ID
  fail2ban.sh [global-options] uninstall --confirm-uninstall REMOVE-VPSCTL-FAIL2BAN

全局选项：
  --dry-run --install-deps --yes --non-interactive --quiet --verbose --no-color
  -h, --help

仅支持 systemd 与 OpenSSH。安装支持 apt、dnf5、dnf、yum、pacman 和 zypper；
明确拒绝 apk/OpenRC。uninstall 仅删除 vpsctl 受管 jail，不删除软件包、服务或备份。
EOF
}

fail2ban_parse_globals() {
    FAIL2BAN_ARGS=()
    while (($# > 0)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --install-deps) VPSCTL_INSTALL_DEPS=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --no-color) VPSCTL_NO_COLOR=1 ;;
            --) shift; FAIL2BAN_ARGS=("$@"); return 0 ;;
            *) FAIL2BAN_ARGS=("$@"); return 0 ;;
        esac
        shift
    done
}

fail2ban_init_paths() {
    FAIL2BAN_CONFIG="$(vps_cmd_system_path "$FAIL2BAN_CONFIG_LOGICAL")" || return $?
    FAIL2BAN_STATE_DIR="$(vps_cmd_system_path "$FAIL2BAN_STATE_LOGICAL")" || return $?
    FAIL2BAN_BACKUP_DIR="$(vps_cmd_system_path "$FAIL2BAN_BACKUP_LOGICAL")" || return $?
    FAIL2BAN_HASH_FILE="$(vps_cmd_system_path "$FAIL2BAN_HASH_LOGICAL")" || return $?
    FAIL2BAN_METADATA_FILE="$(vps_cmd_system_path "$FAIL2BAN_METADATA_LOGICAL")" || return $?
}

fail2ban_require_platform() {
    local allow_readonly="${1:-0}" kernel init

    if [[ "${VPSCTL_TESTING:-0}" == 1 ]]; then
        kernel="${VPSCTL_ENV_KERNEL_NAME:-Linux}"
        init="${VPSCTL_ENV_INIT:-systemd}"
    else
        kernel="${VPSCTL_ENV_KERNEL_NAME:-$(uname -s 2>/dev/null || true)}"
        init="${VPSCTL_ENV_INIT:-}"
        [[ -n "$init" ]] || { [[ -d /run/systemd/system ]] && init=systemd; }
    fi
    [[ "$kernel" == Linux ]] || {
        vps_cmd_error "security fail2ban 仅支持 Linux"
        return 3
    }
    if [[ "$init" != systemd && "$allow_readonly" == 1 ]]; then
        VPSCTL_ENV_INIT="${init:-unknown}"
        return 0
    fi
    [[ "$init" == systemd ]] || {
        vps_cmd_error "security fail2ban 仅支持 systemd；明确不支持 OpenRC"
        return 3
    }
    [[ "${VPSCTL_ENV_PACKAGE_MANAGER:-}" != apk ]] || {
        vps_cmd_error "security fail2ban 明确不支持 apk 平台"
        return 3
    }
    command -v systemctl >/dev/null 2>&1 || {
        vps_cmd_error "未找到 systemctl"
        return 3
    }
    VPSCTL_ENV_INIT=systemd
}

fail2ban_physical_to_logical() {
    local path="$1"
    if [[ "${VPSCTL_TESTING:-0}" == 1 ]]; then
        [[ "$path" == "${VPSCTL_SYSTEM_ROOT%/}/"* ]] || return 2
        printf '/%s\n' "${path#"${VPSCTL_SYSTEM_ROOT%/}/"}"
    else
        printf '%s\n' "$path"
    fi
}

fail2ban_atomic_file() {
    local target="$1" mode="$2" logical
    logical="$(fail2ban_physical_to_logical "$target")" || return $?
    vps_cmd_atomic_write "$logical" "$mode"
}

fail2ban_sha256() {
    local output
    output="$(sha256sum -- "$1" 2>/dev/null)" || return 20
    output="${output%%[[:space:]]*}"
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || return 20
    printf '%s\n' "$output"
}

fail2ban_json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

fail2ban_validate_duration() {
    [[ "${1:-}" =~ ^[1-9][0-9]{0,8}([smhdw])?$ ]]
}

fail2ban_duration_seconds() {
    local value="$1" number suffix multiplier=1
    fail2ban_validate_duration "$value" || return 2
    suffix="${value: -1}"
    if [[ "$suffix" =~ [smhdw] ]]; then number="${value%?}"; else number="$value"; suffix=s; fi
    case "$suffix" in s) multiplier=1 ;; m) multiplier=60 ;; h) multiplier=3600 ;; d) multiplier=86400 ;; w) multiplier=604800 ;; esac
    printf '%s\n' "$((10#$number * multiplier))"
}

fail2ban_validate_maxretry() {
    [[ "${1:-}" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$1 >= 1 && 10#$1 <= 100))
}

fail2ban_validate_lines() {
    [[ "${1:-}" =~ ^[0-9]{1,6}$ ]] || return 1
    ((10#$1 <= 100000))
}

fail2ban_validate_ip() {
    local value="${1:-}" address prefix octet old_ifs="$IFS" remainder
    local -a parts=() groups=()

    [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *[[:space:]]* ]] || return 1
    address="${value%%/*}"
    prefix=''
    [[ "$value" != */* ]] || prefix="${value#*/}"
    if [[ "$address" == *:* ]]; then
        [[ "$address" =~ ^[0-9A-Fa-f:]+$ && "$address" == *:* ]] || return 1
        [[ "$address" != *:::* ]] || return 1
        remainder="${address#*::}"
        [[ "$address" != *::* || "$remainder" != *::* ]] || return 1
        IFS=: read -r -a groups <<<"${address#:}"
        IFS="$old_ifs"
        if [[ "$address" == *::* ]]; then ((${#groups[@]} < 8)) || return 1; else ((${#groups[@]} == 8)) || return 1; fi
        for octet in "${groups[@]}"; do [[ -z "$octet" || "$octet" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; done
        if [[ -n "$prefix" ]]; then
            [[ "$prefix" =~ ^[0-9]{1,3}$ ]] && ((10#$prefix <= 128)) || return 1
        fi
        return 0
    fi
    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<<"$address"
    IFS="$old_ifs"
    ((${#parts[@]} == 4)) || return 1
    for octet in "${parts[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1
    done
    if [[ -n "$prefix" ]]; then
        [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && ((10#$prefix <= 32)) || return 1
    fi
}

fail2ban_validate_host_ip() {
    [[ "${1:-}" != */* ]] && fail2ban_validate_ip "$1"
}

fail2ban_validate_backup_id() {
    [[ "${1:-}" =~ ^bak-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]]
}

fail2ban_random_hex() {
    local value
    value="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || return 20
    [[ "$value" =~ ^[0-9a-f]{16}$ ]] || return 20
    printf '%s\n' "$value"
}

fail2ban_new_backup_id() {
    local random
    random="$(fail2ban_random_hex)" || return $?
    printf 'bak-%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$random"
}

fail2ban_require_managed() {
    local expected actual schema metadata_hash
    [[ -f "$FAIL2BAN_CONFIG" && ! -L "$FAIL2BAN_CONFIG" ]] || {
        vps_cmd_error "尚未安装 vpsctl 受管 Fail2ban 配置"
        return 3
    }
    grep -Fqx "$FAIL2BAN_MARKER" "$FAIL2BAN_CONFIG" || {
        vps_cmd_error "目标配置不是 vpsctl 受管文件，拒绝修改"
        return 10
    }
    [[ -f "$FAIL2BAN_HASH_FILE" && ! -L "$FAIL2BAN_HASH_FILE" ]] || {
        vps_cmd_error "受管配置缺少完整性状态，拒绝修改"
        return 30
    }
    [[ -f "$FAIL2BAN_METADATA_FILE" && ! -L "$FAIL2BAN_METADATA_FILE" ]] || {
        vps_cmd_error "受管配置缺少状态元数据，拒绝修改"
        return 30
    }
    expected="$(<"$FAIL2BAN_HASH_FILE")"
    schema="$(fail2ban_manifest_value "$FAIL2BAN_METADATA_FILE" schema_version 2>/dev/null || true)"
    metadata_hash="$(fail2ban_manifest_value "$FAIL2BAN_METADATA_FILE" config_sha256 2>/dev/null || true)"
    actual="$(fail2ban_sha256 "$FAIL2BAN_CONFIG")" || return $?
    [[ "$schema" == 1 && "$expected" =~ ^[0-9a-f]{64}$ && "$expected" == "$actual" && "$metadata_hash" == "$actual" ]] || {
        vps_cmd_error "受管 Fail2ban 配置发生哈希漂移；请先审查并显式恢复"
        return 30
    }
}

fail2ban_config_state() {
    local expected actual schema metadata_hash
    if [[ ! -e "$FAIL2BAN_CONFIG" ]]; then printf missing; return 0; fi
    if [[ ! -f "$FAIL2BAN_CONFIG" || -L "$FAIL2BAN_CONFIG" ]] || ! grep -Fqx "$FAIL2BAN_MARKER" "$FAIL2BAN_CONFIG"; then
        printf unmanaged
        return 0
    fi
    if [[ ! -f "$FAIL2BAN_HASH_FILE" || -L "$FAIL2BAN_HASH_FILE" || ! -f "$FAIL2BAN_METADATA_FILE" || -L "$FAIL2BAN_METADATA_FILE" ]]; then printf drift; return 0; fi
    expected="$(<"$FAIL2BAN_HASH_FILE")"
    schema="$(fail2ban_manifest_value "$FAIL2BAN_METADATA_FILE" schema_version 2>/dev/null || true)"
    metadata_hash="$(fail2ban_manifest_value "$FAIL2BAN_METADATA_FILE" config_sha256 2>/dev/null || true)"
    actual="$(fail2ban_sha256 "$FAIL2BAN_CONFIG" 2>/dev/null || true)"
    if [[ "$schema" == 1 && "$expected" =~ ^[0-9a-f]{64}$ && "$expected" == "$actual" && "$metadata_hash" == "$actual" ]]; then printf managed; else printf drift; fi
}

fail2ban_load_config() {
    local key value ignores
    FAIL2BAN_BANTIME='1h'
    FAIL2BAN_FINDTIME='10m'
    FAIL2BAN_MAXRETRY='5'
    FAIL2BAN_INCREMENT='on'
    FAIL2BAN_MAX_BANTIME='1w'
    FAIL2BAN_PORT='22'
    FAIL2BAN_BANACTION='iptables-multiport'
    FAIL2BAN_IGNORE=('127.0.0.1/8' '::1')
    [[ -r "$FAIL2BAN_CONFIG" && -f "$FAIL2BAN_CONFIG" ]] || return 0
    while IFS=$'\t' read -r key value; do
        case "$key" in
            bantime) FAIL2BAN_BANTIME="$value" ;;
            findtime) FAIL2BAN_FINDTIME="$value" ;;
            maxretry) FAIL2BAN_MAXRETRY="$value" ;;
            increment) [[ "${value,,}" == true ]] && FAIL2BAN_INCREMENT=on || FAIL2BAN_INCREMENT=off ;;
            maxtime) FAIL2BAN_MAX_BANTIME="$value" ;;
            port) FAIL2BAN_PORT="$value" ;;
            banaction) FAIL2BAN_BANACTION="$value" ;;
            ignoreip)
                FAIL2BAN_IGNORE=()
                ignores="$value"
                IFS=' ' read -r -a FAIL2BAN_IGNORE <<<"$ignores"
                ;;
        esac
    done < <(awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ || /^[[:space:]]*\[/ {next}
        {
            line=$0; sub(/[[:space:]]+#.*/, "", line)
            separator=index(line, "="); if (!separator) next
            key=tolower(substr(line, 1, separator-1)); value=substr(line, separator+1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (key == "bantime.increment") key="increment"
            else if (key == "bantime.maxtime") key="maxtime"
            print key "\t" value
        }
    ' "$FAIL2BAN_CONFIG")
}

fail2ban_emit_config() {
    local item ignore_line='' increment=false
    [[ "$FAIL2BAN_INCREMENT" == on ]] && increment=true
    for item in "${FAIL2BAN_IGNORE[@]}"; do ignore_line="${ignore_line:+${ignore_line} }${item}"; done
    cat <<EOF
${FAIL2BAN_MARKER}
# Do not edit this file by hand; use vpsctl security fail2ban.

[sshd]
enabled = true
port = ${FAIL2BAN_PORT}
maxretry = ${FAIL2BAN_MAXRETRY}
findtime = ${FAIL2BAN_FINDTIME}
bantime = ${FAIL2BAN_BANTIME}
ignoreip = ${ignore_line}
usedns = no
banaction = ${FAIL2BAN_BANACTION}
bantime.increment = ${increment}
bantime.maxtime = ${FAIL2BAN_MAX_BANTIME}
EOF
}

fail2ban_existing_sshd_jail() {
    local jail_local jail_dir file
    jail_local="$(vps_cmd_system_path /etc/fail2ban/jail.local)" || return $?
    jail_dir="$(vps_cmd_system_path /etc/fail2ban/jail.d)" || return $?
    for file in "$jail_local" "$jail_dir"/*.local; do
        [[ -e "$file" && "$file" != "$FAIL2BAN_CONFIG" ]] || continue
        [[ -f "$file" && ! -L "$file" ]] || {
            vps_cmd_error "Fail2ban jail 配置必须是非符号链接普通文件：$file"
            return 10
        }
        if awk 'BEGIN{found=1} /^[[:space:]]*\[[[:space:]]*sshd[[:space:]]*\][[:space:]]*([#;].*)?$/ {found=0; exit} END{exit found}' "$file"; then
            printf '%s\n' "$file"
            return 0
        fi
    done
    return 1
}

fail2ban_detect_banaction() {
    local firewalld=0 ufw_active=0
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then firewalld=1; fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | awk 'tolower($0) ~ /^status:[[:space:]]*active/ {found=1} END{exit !found}'; then ufw_active=1; fi
    if ((firewalld + ufw_active > 1)); then
        vps_cmd_error "检测到多个活动防火墙前端（firewalld 与 UFW），拒绝选择 Fail2ban banaction"
        return 10
    fi
    if ((firewalld)); then printf 'firewallcmd-rich-rules\n'
    elif ((ufw_active)); then printf 'ufw\n'
    elif command -v nft >/dev/null 2>&1; then printf 'nftables-multiport\n'
    elif command -v iptables >/dev/null 2>&1; then printf 'iptables-multiport\n'
    else printf 'nftables-multiport\n'
    fi
}

fail2ban_ssh_port() {
    local output ports='' port separator=''
    command -v sshd >/dev/null 2>&1 || {
        vps_cmd_error "未找到 OpenSSH sshd"
        return 3
    }
    output="$(sshd -T 2>/dev/null)" || {
        vps_cmd_error "无法读取有效的 OpenSSH 配置（sshd -T 失败）"
        return 10
    }
    while IFS= read -r port; do
        [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || {
            vps_cmd_error "OpenSSH 返回无效端口：$port"
            return 10
        }
        ports="${ports}${separator}${port}"
        separator=,
    done < <(awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2 + 0}' <<<"$output" | sort -n -u)
    [[ -n "$ports" ]] || {
        vps_cmd_error "OpenSSH 未返回有效监听端口"
        return 10
    }
    printf '%s\n' "$ports"
}

fail2ban_current_session_ip() {
    local value="${SSH_CONNECTION:-}"
    value="${value%%[[:space:]]*}"
    fail2ban_validate_host_ip "$value" || {
        vps_cmd_error "--ignore-current-session 需要有效的 SSH_CONNECTION 客户端地址"
        return 3
    }
    printf '%s\n' "$value"
}

fail2ban_add_ignore_value() {
    local value="$1" item
    fail2ban_validate_ip "$value" || {
        vps_cmd_error "无效 IP 或 CIDR：$value"
        return 2
    }
    for item in "${FAIL2BAN_IGNORE[@]}"; do [[ "$item" != "$value" ]] || return 0; done
    FAIL2BAN_IGNORE+=("$value")
}

fail2ban_version() {
    local output version
    command -v fail2ban-client >/dev/null 2>&1 || return 1
    output="$(fail2ban-client -V 2>/dev/null)" || return 1
    version="$(grep -Eo '[vV]?[0-9]+(\.[0-9]+){1,2}' <<<"$output" | head -n 1 | sed 's/^[vV]//')"
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

fail2ban_version_supported() {
    local version="$1" major minor
    IFS=. read -r major minor _ <<<"$version"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 1
    ((10#$major > 0 || 10#$minor >= 11))
}

fail2ban_install_package() {
    local action="$1" manager version=''
    local -a packages=(fail2ban)
    manager="$(vps_cmd_detect_package_manager)" || return $?
    case "$manager" in
        apk)
            vps_cmd_error "security fail2ban 明确不支持 apk/OpenRC 平台"
            return 3
            ;;
        apt-get | dnf5 | dnf | yum | pacman | zypper) ;;
        *) vps_cmd_error "不支持的软件包管理器：$manager"; return 3 ;;
    esac
    case "$manager" in
        apt-get) packages+=(python3-systemd) ;;
        dnf5 | dnf | yum)
            packages+=(fail2ban-systemd)
            [[ "$action" != firewallcmd-rich-rules ]] || packages+=(fail2ban-firewalld)
            ;;
    esac
    case "$action" in
        nftables-multiport) command -v nft >/dev/null 2>&1 || packages+=(nftables) ;;
        iptables-multiport) command -v iptables >/dev/null 2>&1 || packages+=(iptables) ;;
    esac
    vps_cmd_info "将使用 $manager 确保 Fail2ban 及其 systemd/防火墙依赖"
    vps_cmd_install_packages "$manager" "${packages[@]}" || return $?
    [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]] && return 0
    hash -r
    command -v fail2ban-client >/dev/null 2>&1 || {
        vps_cmd_error "软件包安装完成后仍未找到 fail2ban-client"
        return 20
    }
    version="$(fail2ban_version)" || {
        vps_cmd_error "无法读取 Fail2ban 版本"
        return 20
    }
    fail2ban_version_supported "$version" || {
        vps_cmd_error "需要 Fail2ban ${FAIL2BAN_MIN_VERSION}+，当前版本：$version"
        return 3
    }
}

fail2ban_make_backup() {
    local id directory existed=0 sha='absent' mode='absent' uid='absent' gid='absent'
    local hash_existed=0 hash_sha='absent' metadata_existed=0 metadata_sha='absent'
    id="$(fail2ban_new_backup_id)" || return $?
    directory="${FAIL2BAN_BACKUP_DIR}/${id}"
    mkdir -p -- "$FAIL2BAN_BACKUP_DIR" || return 20
    mkdir -- "$directory" || return 20
    chmod 0700 -- "$FAIL2BAN_BACKUP_DIR" "$directory" || return 20
    if [[ -e "$FAIL2BAN_CONFIG" ]]; then
        [[ -f "$FAIL2BAN_CONFIG" && ! -L "$FAIL2BAN_CONFIG" ]] || return 10
        cp -p -- "$FAIL2BAN_CONFIG" "$directory/config" || return 20
        existed=1
        sha="$(fail2ban_sha256 "$FAIL2BAN_CONFIG")" || return $?
        mode="$(stat -c '%a' -- "$FAIL2BAN_CONFIG")" || return 20
        uid="$(stat -c '%u' -- "$FAIL2BAN_CONFIG")" || return 20
        gid="$(stat -c '%g' -- "$FAIL2BAN_CONFIG")" || return 20
    fi
    if [[ -e "$FAIL2BAN_HASH_FILE" ]]; then
        [[ -f "$FAIL2BAN_HASH_FILE" && ! -L "$FAIL2BAN_HASH_FILE" ]] || return 10
        cp -p -- "$FAIL2BAN_HASH_FILE" "$directory/config.sha256" || return 20
        hash_existed=1; hash_sha="$(fail2ban_sha256 "$FAIL2BAN_HASH_FILE")" || return $?
    fi
    if [[ -e "$FAIL2BAN_METADATA_FILE" ]]; then
        [[ -f "$FAIL2BAN_METADATA_FILE" && ! -L "$FAIL2BAN_METADATA_FILE" ]] || return 10
        cp -p -- "$FAIL2BAN_METADATA_FILE" "$directory/metadata" || return 20
        metadata_existed=1; metadata_sha="$(fail2ban_sha256 "$FAIL2BAN_METADATA_FILE")" || return $?
    fi
    {
        printf 'version\t1\n'
        printf 'kind\tfail2ban-sshd\n'
        printf 'config_existed\t%s\n' "$existed"
        printf 'config_sha256\t%s\n' "$sha"
        printf 'config_mode\t%s\n' "$mode"
        printf 'config_uid\t%s\n' "$uid"
        printf 'config_gid\t%s\n' "$gid"
        printf 'hash_existed\t%s\n' "$hash_existed"
        printf 'hash_sha256\t%s\n' "$hash_sha"
        printf 'metadata_existed\t%s\n' "$metadata_existed"
        printf 'metadata_sha256\t%s\n' "$metadata_sha"
        printf 'lifecycle\tactive\n'
    } >"$directory/manifest" || return 20
    chmod 0600 -- "$directory/manifest" || return 20
    printf '%s\n' "$id"
}

fail2ban_manifest_value() {
    local file="$1" key="$2"
    awk -F '\t' -v wanted="$key" '$1 == wanted {print substr($0, length($1)+2); found=1; exit} END{if (!found) exit 1}' "$file"
}

fail2ban_restore_snapshot() {
    local backup_id="$1" directory manifest existed stored_sha actual kind version mode uid gid
    local hash_existed hash_sha metadata_existed metadata_sha
    directory="${FAIL2BAN_BACKUP_DIR}/${backup_id}"
    manifest="$directory/manifest"
    vps_cmd_require_no_symlink_components "$directory" || return 1
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
    version="$(fail2ban_manifest_value "$manifest" version)" || return 1
    kind="$(fail2ban_manifest_value "$manifest" kind)" || return 1
    [[ "$version" == 1 && "$kind" == fail2ban-sshd ]] || return 1
    existed="$(fail2ban_manifest_value "$manifest" config_existed)" || return 1
    stored_sha="$(fail2ban_manifest_value "$manifest" config_sha256)" || return 1
    mode="$(fail2ban_manifest_value "$manifest" config_mode)" || return 1
    uid="$(fail2ban_manifest_value "$manifest" config_uid)" || return 1
    gid="$(fail2ban_manifest_value "$manifest" config_gid)" || return 1
    case "$existed" in
        1)
            [[ -f "$directory/config" && ! -L "$directory/config" ]] || return 1
            actual="$(fail2ban_sha256 "$directory/config")" || return 1
            [[ "$stored_sha" == "$actual" ]] || return 1
            [[ "$mode" =~ ^[0-7]{3,4}$ && "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ ]] || return 1
            fail2ban_atomic_file "$FAIL2BAN_CONFIG" "$mode" <"$directory/config" || return 1
            chown "$uid:$gid" -- "$FAIL2BAN_CONFIG" || return 1
            ;;
        0)
            [[ "$stored_sha" == absent ]] || return 1
            rm -f -- "$FAIL2BAN_CONFIG" || return 1
            ;;
        *) return 1 ;;
    esac
    hash_existed="$(fail2ban_manifest_value "$manifest" hash_existed)" || return 1
    hash_sha="$(fail2ban_manifest_value "$manifest" hash_sha256)" || return 1
    metadata_existed="$(fail2ban_manifest_value "$manifest" metadata_existed)" || return 1
    metadata_sha="$(fail2ban_manifest_value "$manifest" metadata_sha256)" || return 1
    case "$hash_existed" in
        1) [[ -f "$directory/config.sha256" && ! -L "$directory/config.sha256" && "$(fail2ban_sha256 "$directory/config.sha256")" == "$hash_sha" ]] || return 1; fail2ban_atomic_file "$FAIL2BAN_HASH_FILE" 0600 <"$directory/config.sha256" || return 1 ;;
        0) [[ "$hash_sha" == absent ]] || return 1; rm -f -- "$FAIL2BAN_HASH_FILE" || return 1 ;;
        *) return 1 ;;
    esac
    case "$metadata_existed" in
        1) [[ -f "$directory/metadata" && ! -L "$directory/metadata" && "$(fail2ban_sha256 "$directory/metadata")" == "$metadata_sha" ]] || return 1; fail2ban_atomic_file "$FAIL2BAN_METADATA_FILE" 0600 <"$directory/metadata" || return 1 ;;
        0) [[ "$metadata_sha" == absent ]] || return 1; rm -f -- "$FAIL2BAN_METADATA_FILE" || return 1 ;;
        *) return 1 ;;
    esac
}

fail2ban_write_state() {
    local hash item ignore_line=''
    hash="$(fail2ban_sha256 "$FAIL2BAN_CONFIG")" || return $?
    for item in "${FAIL2BAN_IGNORE[@]}"; do ignore_line="${ignore_line:+${ignore_line} }${item}"; done
    {
        printf 'schema_version\t1\n'
        printf 'config_sha256\t%s\n' "$hash"
        printf 'ports\t%s\n' "$FAIL2BAN_PORT"
        printf 'bantime\t%s\n' "$FAIL2BAN_BANTIME"
        printf 'findtime\t%s\n' "$FAIL2BAN_FINDTIME"
        printf 'maxretry\t%s\n' "$FAIL2BAN_MAXRETRY"
        printf 'increment\t%s\n' "$FAIL2BAN_INCREMENT"
        printf 'max_bantime\t%s\n' "$FAIL2BAN_MAX_BANTIME"
        printf 'banaction\t%s\n' "$FAIL2BAN_BANACTION"
        printf 'usedns\tno\n'
        printf 'ignoreip\t%s\n' "$ignore_line"
    } | fail2ban_atomic_file "$FAIL2BAN_METADATA_FILE" 0600 || return 20
    printf '%s\n' "$hash" | fail2ban_atomic_file "$FAIL2BAN_HASH_FILE" 0600
}

fail2ban_prepare_dirs() {
    local config_dir="${FAIL2BAN_CONFIG%/*}" config_dir_created=0
    vps_cmd_require_no_symlink_components "$config_dir" || return $?
    vps_cmd_require_no_symlink_components "$FAIL2BAN_STATE_DIR" || return $?
    vps_cmd_require_no_symlink_components "$FAIL2BAN_BACKUP_DIR" || return $?
    [[ -e "$config_dir" ]] || config_dir_created=1
    mkdir -p -- "$config_dir" "$FAIL2BAN_STATE_DIR" "$FAIL2BAN_BACKUP_DIR" || return 20
    [[ "$config_dir_created" == 0 ]] || chmod 0755 -- "$config_dir" || return 20
    chmod 0700 -- "$FAIL2BAN_STATE_DIR" "$FAIL2BAN_BACKUP_DIR" || return 20
    vps_cmd_require_no_symlink_components "$FAIL2BAN_CONFIG" || return $?
    vps_cmd_require_no_symlink_components "$FAIL2BAN_STATE_DIR" || return $?
    vps_cmd_require_no_symlink_components "$FAIL2BAN_BACKUP_DIR" || return $?
}

fail2ban_daemon_apply() {
    local was_active="$1"
    fail2ban-client -t >/dev/null || {
        vps_cmd_error "fail2ban-client -t 配置测试失败"
        return 20
    }
    if [[ "$was_active" == 1 ]]; then
        # A plain reload can leave a replaced banaction registered but not
        # started. Restart only this jail and preserve tickets (no --unban).
        vps_cmd_run fail2ban-client reload --restart sshd || return 20
    else
        vps_cmd_run systemctl enable --now "$FAIL2BAN_SERVICE" || return 20
    fi
    fail2ban_wait_ready
}

fail2ban_wait_ready() {
    local attempt
    for attempt in {1..40}; do
        if fail2ban-client ping >/dev/null 2>&1 && fail2ban-client status sshd >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.25
    done
    vps_cmd_error "Fail2ban 服务已启动，但 socket 或 sshd jail 未在 10 秒内就绪"
    return 20
}

fail2ban_rollback_daemon() {
    local was_active="$1" was_enabled="$2"
    if [[ "$was_active" == 1 ]]; then
        fail2ban-client reload --restart sshd >/dev/null 2>&1 || systemctl restart "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || true
    else
        systemctl stop "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || true
        [[ "$was_enabled" == 1 ]] || systemctl disable "$FAIL2BAN_SERVICE" >/dev/null 2>&1 || true
    fi
}

fail2ban_apply_loaded_config() {
    local backup_id was_active=0 was_enabled=0 rc=0
    vps_cmd_require_root || return $?
    vps_cmd_lock security-fail2ban || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：将备份并原子写入 $FAIL2BAN_CONFIG_LOGICAL，测试配置后 reload/start"
        fail2ban_emit_config
        return 0
    fi
    fail2ban_prepare_dirs || return $?
    backup_id="$(fail2ban_make_backup)" || return $?
    systemctl is-active --quiet "$FAIL2BAN_SERVICE" >/dev/null 2>&1 && was_active=1
    systemctl is-enabled --quiet "$FAIL2BAN_SERVICE" >/dev/null 2>&1 && was_enabled=1
    if ! fail2ban_emit_config | fail2ban_atomic_file "$FAIL2BAN_CONFIG" 0644; then rc=20
    elif ! fail2ban_daemon_apply "$was_active"; then rc=20
    elif ! fail2ban_write_state; then rc=20
    fi
    if ((rc != 0)); then
        vps_cmd_warning "配置应用失败，正在恢复备份 $backup_id"
        if ! fail2ban_restore_snapshot "$backup_id"; then
            vps_cmd_error "Fail2ban 配置回滚失败"
            return 30
        fi
        fail2ban_rollback_daemon "$was_active" "$was_enabled"
        return "$rc"
    fi
    vps_cmd_success "Fail2ban sshd jail 已应用；备份 ID：$backup_id"
}

fail2ban_json_string_array() {
    local item separator=''
    printf '['
    for item in "$@"; do printf '%s"%s"' "$separator" "$(fail2ban_json_escape "$item")"; separator=,; done
    printf ']'
}

fail2ban_json_ports() {
    local csv="$1" item separator=''
    printf '['
    if [[ "$csv" != unknown && -n "$csv" && "$csv" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        local old_ifs="$IFS"
        IFS=,
        for item in $csv; do printf '%s%s' "$separator" "$item"; separator=,; done
        IFS="$old_ifs"
    fi
    printf ']'
}

fail2ban_ban_count() {
    local kind="$1" output
    output="$(fail2ban-client status sshd 2>/dev/null)" || return 1
    case "$kind" in
        currently) output="$(sed -n 's/^[[:space:]|`-]*Currently banned:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' <<<"$output" | head -n 1)" ;;
        total) output="$(sed -n 's/^[[:space:]|`-]*Total banned:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' <<<"$output" | head -n 1)" ;;
        *) return 2 ;;
    esac
    output="$(vps_cmd_trim "$output")"
    [[ "$output" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$output"
}

fail2ban_status() {
    local json="$1" installed=false active=false enabled=false jail=false state version='' current_ports='unknown' managed_ports='unknown' synced=false
    local current_bans='' total_bans='' increment_json=null maxretry_json=null current_bans_json=null total_bans_json=null
    command -v fail2ban-client >/dev/null 2>&1 && installed=true
    [[ "$installed" == false ]] || version="$(fail2ban_version 2>/dev/null || true)"
    systemctl is-active --quiet "$FAIL2BAN_SERVICE" >/dev/null 2>&1 && active=true
    systemctl is-enabled --quiet "$FAIL2BAN_SERVICE" >/dev/null 2>&1 && enabled=true
    [[ "$active" == true ]] && fail2ban-client status sshd >/dev/null 2>&1 && jail=true
    current_ports="$(fail2ban_ssh_port 2>/dev/null || printf unknown)"
    state="$(fail2ban_config_state)"
    if [[ "$state" == managed || "$state" == drift ]]; then
        fail2ban_load_config
        managed_ports="$FAIL2BAN_PORT"
        if [[ "$FAIL2BAN_INCREMENT" == on ]]; then increment_json=true; else increment_json=false; fi
        [[ "$FAIL2BAN_MAXRETRY" =~ ^[0-9]+$ ]] && maxretry_json="$FAIL2BAN_MAXRETRY"
    fi
    [[ "$current_ports" != unknown && "$managed_ports" != unknown && "$current_ports" == "$managed_ports" ]] && synced=true
    if [[ "$jail" == true ]]; then
        current_bans="$(fail2ban_ban_count currently 2>/dev/null || true)"
        total_bans="$(fail2ban_ban_count total 2>/dev/null || true)"
        [[ "$current_bans" =~ ^[0-9]+$ ]] && current_bans_json="$current_bans"
        [[ "$total_bans" =~ ^[0-9]+$ ]] && total_bans_json="$total_bans"
    fi
    if [[ "$json" == 1 ]]; then
        printf '{"schema_version":1,"platform":"%s","version":' "$(fail2ban_json_escape "${VPSCTL_ENV_INIT:-unknown}")"
        if [[ -n "$version" ]]; then printf '"%s"' "$(fail2ban_json_escape "$version")"; else printf 'null'; fi
        printf ',"installed":%s,"service":{"active":%s,"enabled":%s},"config":{"state":"%s","drift":%s},"jail":{"name":"sshd","active":%s,"current_ports":' \
            "$installed" "$active" "$enabled" "$state" "$([[ "$state" == drift ]] && printf true || printf false)" "$jail"
        fail2ban_json_ports "$current_ports"
        printf ',"managed_ports":'; fail2ban_json_ports "$managed_ports"
        printf ',"ports_synced":%s,"bantime":' "$synced"
        if [[ "$managed_ports" != unknown ]]; then printf '"%s"' "$(fail2ban_json_escape "$FAIL2BAN_BANTIME")"; else printf null; fi
        printf ',"findtime":'
        if [[ "$managed_ports" != unknown ]]; then printf '"%s"' "$(fail2ban_json_escape "$FAIL2BAN_FINDTIME")"; else printf null; fi
        printf ',"maxretry":%s,"increment":%s,"max_bantime":' "$maxretry_json" "$increment_json"
        if [[ "$managed_ports" != unknown ]]; then printf '"%s"' "$(fail2ban_json_escape "$FAIL2BAN_MAX_BANTIME")"; else printf null; fi
        printf ',"banaction":'
        if [[ "$managed_ports" != unknown ]]; then printf '"%s"' "$(fail2ban_json_escape "$FAIL2BAN_BANACTION")"; else printf null; fi
        printf ',"ignoreip":'
        if [[ "$managed_ports" != unknown ]]; then fail2ban_json_string_array "${FAIL2BAN_IGNORE[@]}"; else printf '[]'; fi
        printf ',"current_bans":%s,"total_bans":%s}}\n' "$current_bans_json" "$total_bans_json"
        return 0
    fi
    vps_cmd_status "Fail2ban" "$([[ "$installed" == true ]] && printf 已安装 || printf 未安装)" "$([[ "$installed" == true ]] && printf success || printf warning)"
    vps_cmd_status "服务" "$([[ "$active" == true ]] && printf 运行中 || printf 未运行)" "$([[ "$active" == true ]] && printf success || printf warning)"
    vps_cmd_status "sshd jail" "$([[ "$jail" == true ]] && printf 活动 || printf 未活动)" "$([[ "$jail" == true ]] && printf success || printf warning)"
    vps_cmd_status "配置" "$state" "$([[ "$state" == managed ]] && printf success || printf warning)"
    vps_cmd_status "当前 SSH 端口" "$current_ports" normal
    vps_cmd_status "受管 SSH 端口" "$managed_ports" "$([[ "$synced" == true ]] && printf success || printf warning)"
    [[ "$managed_ports" == unknown ]] || vps_cmd_status "封禁策略" "${FAIL2BAN_MAXRETRY} 次/${FAIL2BAN_FINDTIME}，${FAIL2BAN_BANTIME}（increment=${FAIL2BAN_INCREMENT}, max=${FAIL2BAN_MAX_BANTIME}）" normal
    [[ -z "$current_bans" ]] || vps_cmd_status "当前/累计封禁" "${current_bans}/${total_bans:-unknown}" normal
}

fail2ban_dispatch_status() {
    local json=0
    while (($#)); do case "$1" in --json) [[ "$json" == 0 ]] || { vps_cmd_error "重复指定 --json"; return 2; }; json=1 ;; *) vps_cmd_error "status 未知选项：$1"; return 2 ;; esac; shift; done
    fail2ban_status "$json"
}

fail2ban_dispatch_install() {
    local adopt=0 current=0 existing='' value existing_status=0 managed_existing=0 selected_action=''
    local -a additions=()
    while (($#)); do
        case "$1" in
            --ignore-ip) (($# >= 2)) || { vps_cmd_error "--ignore-ip 需要值"; return 2; }; additions+=("$2"); shift 2 ;;
            --ignore-current-session) [[ "$current" == 0 ]] || { vps_cmd_error "重复指定 --ignore-current-session"; return 2; }; current=1; shift ;;
            --adopt-existing) [[ "$adopt" == 0 ]] || { vps_cmd_error "重复指定 --adopt-existing"; return 2; }; adopt=1; shift ;;
            *) vps_cmd_error "install 未知选项：$1"; return 2 ;;
        esac
    done
    for value in "${additions[@]}"; do fail2ban_validate_ip "$value" || { vps_cmd_error "无效 IP 或 CIDR：$value"; return 2; }; done
    [[ "$current" == 0 ]] || additions+=("$(fail2ban_current_session_ip)") || return $?
    vps_cmd_require_root || return $?
    if [[ -e "$FAIL2BAN_CONFIG" ]]; then
        if grep -Fqx "$FAIL2BAN_MARKER" "$FAIL2BAN_CONFIG" 2>/dev/null; then
            fail2ban_require_managed || return $?
            managed_existing=1
        elif [[ "$adopt" != 1 ]]; then
            vps_cmd_error "目标位置已有非受管配置；使用 --adopt-existing 才会接管"
            return 10
        fi
    fi
    existing="$(fail2ban_existing_sshd_jail)" || existing_status=$?
    [[ "$existing_status" == 0 || "$existing_status" == 1 ]] || return "$existing_status"
    if [[ -n "$existing" && "$adopt" != 1 ]]; then
        vps_cmd_error "检测到非受管 sshd jail：$existing；请审查后使用 --adopt-existing"
        return 10
    fi
    selected_action="$(fail2ban_detect_banaction)" || return $?
    fail2ban_install_package "$selected_action" || return $?
    existing=''; existing_status=0
    existing="$(fail2ban_existing_sshd_jail)" || existing_status=$?
    [[ "$existing_status" == 0 || "$existing_status" == 1 ]] || return "$existing_status"
    if [[ -n "$existing" && "$adopt" != 1 ]]; then
        vps_cmd_error "检测到非受管 sshd jail：$existing；请审查后使用 --adopt-existing"
        return 10
    fi
    if [[ "$managed_existing" == 1 ]]; then fail2ban_load_config
    else
        FAIL2BAN_BANTIME='1h'; FAIL2BAN_FINDTIME='10m'; FAIL2BAN_MAXRETRY='5'; FAIL2BAN_INCREMENT='on'; FAIL2BAN_MAX_BANTIME='1w'
        FAIL2BAN_IGNORE=('127.0.0.1/8' '::1')
    fi
    FAIL2BAN_BANACTION="$selected_action"
    FAIL2BAN_PORT="$(fail2ban_ssh_port)" || return $?
    for value in "${additions[@]}"; do fail2ban_add_ignore_value "$value" || return $?; done
    fail2ban_apply_loaded_config
}

fail2ban_dispatch_configure() {
    local changed=0 value new_bantime='' new_findtime='' new_maxretry='' new_increment='' new_max_bantime=''
    local -A seen=()
    while (($#)); do
        (($# >= 2)) || { vps_cmd_error "$1 需要值"; return 2; }
        value="$2"
        [[ -z "${seen[$1]+set}" ]] || { vps_cmd_error "重复指定 $1"; return 2; }
        seen[$1]=1
        case "$1" in
            --bantime) fail2ban_validate_duration "$value" || { vps_cmd_error "无效 bantime：$value"; return 2; }; new_bantime="$value" ;;
            --findtime) fail2ban_validate_duration "$value" || { vps_cmd_error "无效 findtime：$value"; return 2; }; new_findtime="$value" ;;
            --maxretry) fail2ban_validate_maxretry "$value" || { vps_cmd_error "maxretry 必须是 1..100"; return 2; }; new_maxretry="$value" ;;
            --increment) value="$(vps_cmd_parse_on_off "$value" 2>/dev/null)" || { vps_cmd_error "increment 必须是 on 或 off"; return 2; }; new_increment="$value" ;;
            --max-bantime) fail2ban_validate_duration "$value" || { vps_cmd_error "无效 max-bantime：$value"; return 2; }; new_max_bantime="$value" ;;
            *) vps_cmd_error "configure 未知选项：$1"; return 2 ;;
        esac
        changed=1; shift 2
    done
    [[ "$changed" == 1 ]] || { vps_cmd_error "configure 至少需要一个配置选项"; return 2; }
    fail2ban_require_managed || return $?
    fail2ban_load_config
    [[ -z "$new_bantime" ]] || FAIL2BAN_BANTIME="$new_bantime"
    [[ -z "$new_findtime" ]] || FAIL2BAN_FINDTIME="$new_findtime"
    [[ -z "$new_maxretry" ]] || FAIL2BAN_MAXRETRY="$new_maxretry"
    [[ -z "$new_increment" ]] || FAIL2BAN_INCREMENT="$new_increment"
    [[ -z "$new_max_bantime" ]] || FAIL2BAN_MAX_BANTIME="$new_max_bantime"
    if [[ "$FAIL2BAN_INCREMENT" == on ]] && (( $(fail2ban_duration_seconds "$FAIL2BAN_MAX_BANTIME") < $(fail2ban_duration_seconds "$FAIL2BAN_BANTIME") )); then
        vps_cmd_error "increment=on 时 max-bantime 不能小于 bantime"
        return 2
    fi
    fail2ban_apply_loaded_config
}

fail2ban_sync_ssh_port() {
    local port
    fail2ban_require_managed || return $?
    fail2ban_load_config
    port="$(fail2ban_ssh_port)" || return $?
    if [[ "$port" == "$FAIL2BAN_PORT" ]]; then vps_cmd_success "Fail2ban 已使用 SSH 端口 $port"; return 0; fi
    FAIL2BAN_PORT="$port"
    fail2ban_apply_loaded_config
}

fail2ban_ignore_list() {
    local item
    fail2ban_require_managed || return $?
    fail2ban_load_config
    for item in "${FAIL2BAN_IGNORE[@]}"; do printf '%s\n' "$item"; done
}

fail2ban_ignore_change() {
    local action="$1" ip='' item found=0
    shift
    while (($#)); do case "$1" in --ip) (($# >= 2)) || { vps_cmd_error "--ip 需要值"; return 2; }; [[ -z "$ip" ]] || { vps_cmd_error "重复指定 --ip"; return 2; }; ip="$2"; shift 2 ;; *) vps_cmd_error "ignore $action 未知选项：$1"; return 2 ;; esac; done
    [[ -n "$ip" ]] || { vps_cmd_error "ignore $action 需要 --ip"; return 2; }
    fail2ban_validate_ip "$ip" || { vps_cmd_error "无效 IP 或 CIDR：$ip"; return 2; }
    fail2ban_require_managed || return $?
    fail2ban_load_config
    if [[ "$action" == add ]]; then
        for item in "${FAIL2BAN_IGNORE[@]}"; do
            if [[ "$item" == "$ip" ]]; then vps_cmd_success "忽略地址已存在：$ip"; return 0; fi
        done
        fail2ban_add_ignore_value "$ip" || return $?
    else
        case "$ip" in 127.0.0.1/8 | ::1) vps_cmd_error "不能移除强制回环忽略地址：$ip"; return 3 ;; esac
        local -a retained=()
        for item in "${FAIL2BAN_IGNORE[@]}"; do
            if [[ "$item" == "$ip" ]]; then found=1; else retained+=("$item"); fi
        done
        [[ "$found" == 1 ]] || { vps_cmd_error "忽略列表中不存在：$ip"; return 3; }
        FAIL2BAN_IGNORE=("${retained[@]}")
    fi
    fail2ban_apply_loaded_config
}

fail2ban_dispatch_ignore() {
    local action="${1:-}"
    [[ -n "$action" ]] || { vps_cmd_error "ignore 需要 list、add 或 remove"; return 2; }
    shift
    case "$action" in list) (($# == 0)) || { vps_cmd_error "ignore list 不接受参数"; return 2; }; fail2ban_ignore_list ;; add | remove) fail2ban_ignore_change "$action" "$@" ;; *) vps_cmd_error "未知 ignore 动作：$action"; return 2 ;; esac
}

fail2ban_unban() {
    local ip=''
    while (($#)); do case "$1" in --ip) (($# >= 2)) || { vps_cmd_error "--ip 需要值"; return 2; }; [[ -z "$ip" ]] || { vps_cmd_error "重复指定 --ip"; return 2; }; ip="$2"; shift 2 ;; *) vps_cmd_error "unban 未知选项：$1"; return 2 ;; esac; done
    [[ -n "$ip" ]] && fail2ban_validate_host_ip "$ip" || { vps_cmd_error "unban 需要有效的 --ip（不接受 CIDR）"; return 2; }
    vps_cmd_require_root || return $?
    fail2ban_require_managed || return $?
    vps_cmd_lock security-fail2ban || return $?
    vps_cmd_run fail2ban-client set sshd unbanip "$ip" || return 20
    vps_cmd_success "已请求解除封禁：$ip"
}

fail2ban_verify_cleanup() {
    [[ -z "${FAIL2BAN_VERIFY_SELECTED:-}" ]] || fail2ban-client set sshd unbanip "$FAIL2BAN_VERIFY_SELECTED" >/dev/null 2>&1 || true
}

fail2ban_verify() {
    local status_output='' candidate rc=0
    local -a candidates=("$FAIL2BAN_VERIFY_IP" '198.51.100.1' '203.0.113.1')
    vps_cmd_require_root || return $?
    fail2ban_require_managed || return $?
    vps_cmd_lock security-fail2ban || return $?
    [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]] && { vps_cmd_info "演练：将 ban/unban 固定 TEST-NET 候选地址"; return 0; }
    trap 'fail2ban_verify_cleanup; vps_cmd_unlock' EXIT
    if ! fail2ban-client ping >/dev/null; then rc=20
    elif ! fail2ban-client status sshd >/dev/null; then rc=20
    elif ! status_output="$(fail2ban-client status sshd)"; then rc=20
    else
        for candidate in "${candidates[@]}"; do
            if [[ "$status_output" != *"$candidate"* ]]; then FAIL2BAN_VERIFY_SELECTED="$candidate"; break; fi
        done
        [[ -n "$FAIL2BAN_VERIFY_SELECTED" ]] || { vps_cmd_error "所有固定 TEST-NET 验证地址都已被封禁"; rc=3; }
    fi
    if ((rc == 0)) && ! fail2ban-client set sshd banip "$FAIL2BAN_VERIFY_SELECTED" >/dev/null; then rc=20
    elif ((rc == 0)) && ! status_output="$(fail2ban-client status sshd)"; then rc=20
    elif ((rc == 0)) && [[ "$status_output" != *"$FAIL2BAN_VERIFY_SELECTED"* ]]; then
        vps_cmd_error "测试地址未出现在 sshd jail 封禁列表"
        rc=20
    elif ((rc == 0)) && ! fail2ban-client set sshd unbanip "$FAIL2BAN_VERIFY_SELECTED" >/dev/null; then
        vps_cmd_error "测试地址解除封禁命令失败"
        rc=20
    elif ((rc == 0)) && ! status_output="$(fail2ban-client status sshd)"; then rc=20
    elif ((rc == 0)) && [[ "$status_output" == *"$FAIL2BAN_VERIFY_SELECTED"* ]]; then
        vps_cmd_error "测试地址解除封禁后仍在封禁列表中"
        rc=20
    fi
    fail2ban_verify_cleanup
    trap 'vps_cmd_unlock' EXIT
    ((rc == 0)) || return "$rc"
    vps_cmd_success "Fail2ban ban/unban 验证通过（$FAIL2BAN_VERIFY_SELECTED）"
}

fail2ban_service_action() {
    local action="$1"
    vps_cmd_require_root || return $?
    fail2ban_require_managed || return $?
    vps_cmd_lock security-fail2ban || return $?
    case "$action" in
        start) vps_cmd_run systemctl start "$FAIL2BAN_SERVICE" ;;
        stop) vps_cmd_run systemctl stop "$FAIL2BAN_SERVICE" ;;
        restart) vps_cmd_run systemctl restart "$FAIL2BAN_SERVICE" ;;
    esac || return 20
    [[ "$action" == stop || "${VPSCTL_DRY_RUN:-0}" == 1 ]] || fail2ban_wait_ready || return 20
    vps_cmd_success "Fail2ban 服务操作完成：$action"
}

fail2ban_logs() {
    local lines=100 seen=0
    while (($#)); do case "$1" in --lines) (($# >= 2)) || { vps_cmd_error "--lines 需要值"; return 2; }; [[ "$seen" == 0 ]] || { vps_cmd_error "重复指定 --lines"; return 2; }; seen=1; lines="$2"; shift 2 ;; *) vps_cmd_error "logs 未知选项：$1"; return 2 ;; esac; done
    fail2ban_validate_lines "$lines" || { vps_cmd_error "--lines 必须是 0..100000"; return 2; }
    journalctl -u "$FAIL2BAN_SERVICE" --no-pager -n "$lines"
}

fail2ban_restore() {
    local backup='' confirm='' directory manifest lifecycle kind version safety current_state was_active=0 was_enabled=0 rc=0
    while (($#)); do
        case "$1" in
            --backup) (($# >= 2)) || { vps_cmd_error "--backup 需要值"; return 2; }; [[ -z "$backup" ]] || { vps_cmd_error "重复指定 --backup"; return 2; }; backup="$2"; shift 2 ;;
            --confirm-restore) (($# >= 2)) || { vps_cmd_error "--confirm-restore 需要值"; return 2; }; [[ -z "$confirm" ]] || { vps_cmd_error "重复指定 --confirm-restore"; return 2; }; confirm="$2"; shift 2 ;;
            *) vps_cmd_error "restore 未知选项：$1"; return 2 ;;
        esac
    done
    fail2ban_validate_backup_id "$backup" || { vps_cmd_error "restore 需要有效 --backup ID"; return 2; }
    [[ "$confirm" == "$backup" ]] || { vps_cmd_error "--confirm-restore 必须与备份 ID 完全一致"; return 2; }
    directory="${FAIL2BAN_BACKUP_DIR}/${backup}"; manifest="$directory/manifest"
    vps_cmd_require_no_symlink_components "$directory" || return $?
    [[ -f "$manifest" && ! -L "$manifest" ]] || { vps_cmd_error "备份不存在：$backup"; return 3; }
    version="$(fail2ban_manifest_value "$manifest" version 2>/dev/null || true)"
    kind="$(fail2ban_manifest_value "$manifest" kind 2>/dev/null || true)"
    [[ "$version" == 1 && "$kind" == fail2ban-sshd ]] || { vps_cmd_error "备份清单类型或版本无效：$backup"; return 30; }
    lifecycle="$(fail2ban_manifest_value "$manifest" lifecycle 2>/dev/null || true)"
    [[ "$lifecycle" == active ]] || { vps_cmd_error "备份已恢复或损坏：$backup"; return 3; }
    current_state="$(fail2ban_config_state)"
    case "$current_state" in
        managed | missing) ;;
        unmanaged) vps_cmd_error "当前配置不是 vpsctl 受管文件，拒绝覆盖"; return 10 ;;
        drift) vps_cmd_error "当前受管配置发生漂移，拒绝恢复"; return 30 ;;
        *) return 30 ;;
    esac
    vps_cmd_require_root || return $?
    vps_cmd_lock security-fail2ban || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then vps_cmd_info "演练：将恢复备份 $backup"; return 0; fi
    fail2ban_prepare_dirs || return $?
    safety="$(fail2ban_make_backup)" || return $?
    systemctl is-active --quiet "$FAIL2BAN_SERVICE" >/dev/null 2>&1 && was_active=1
    systemctl is-enabled --quiet "$FAIL2BAN_SERVICE" >/dev/null 2>&1 && was_enabled=1
    if ! fail2ban_restore_snapshot "$backup"; then rc=30
    elif [[ -e "$FAIL2BAN_CONFIG" ]]; then
        if ! fail2ban_daemon_apply "$was_active"; then rc=20
        elif grep -Fqx "$FAIL2BAN_MARKER" "$FAIL2BAN_CONFIG"; then
            fail2ban_write_state || rc=20
        else
            rm -f -- "$FAIL2BAN_HASH_FILE" "$FAIL2BAN_METADATA_FILE" || rc=20
        fi
    elif [[ "$was_active" == 1 ]] && ! fail2ban-client reload --restart sshd; then rc=20
    fi
    if ((rc != 0)); then
        fail2ban_restore_snapshot "$safety" || return 30
        fail2ban_rollback_daemon "$was_active" "$was_enabled"
        return "$rc"
    fi
    if [[ ! -e "$FAIL2BAN_CONFIG" ]]; then rm -f -- "$FAIL2BAN_HASH_FILE" "$FAIL2BAN_METADATA_FILE" || rc=20; fi
    if ((rc == 0)) && ! awk -F '\t' 'BEGIN{OFS="\t"} $1=="lifecycle" {$2="restored"} {print}' "$manifest" | fail2ban_atomic_file "$manifest" 0600; then rc=20; fi
    if ((rc != 0)); then
        fail2ban_restore_snapshot "$safety" || return 30
        if grep -Fqx "$FAIL2BAN_MARKER" "$FAIL2BAN_CONFIG" 2>/dev/null; then fail2ban_write_state || return 30; else rm -f -- "$FAIL2BAN_HASH_FILE" "$FAIL2BAN_METADATA_FILE" || return 30; fi
        fail2ban_rollback_daemon "$was_active" "$was_enabled"
        return "$rc"
    fi
    vps_cmd_success "已恢复备份 $backup；恢复前状态保存在 $safety"
}

fail2ban_uninstall() {
    local confirm='' backup was_active=0
    while (($#)); do case "$1" in --confirm-uninstall) (($# >= 2)) || { vps_cmd_error "--confirm-uninstall 需要值"; return 2; }; [[ -z "$confirm" ]] || { vps_cmd_error "重复指定 --confirm-uninstall"; return 2; }; confirm="$2"; shift 2 ;; *) vps_cmd_error "uninstall 未知选项：$1"; return 2 ;; esac; done
    [[ "$confirm" == "$FAIL2BAN_UNINSTALL_TOKEN" ]] || { vps_cmd_error "uninstall 需要 --confirm-uninstall $FAIL2BAN_UNINSTALL_TOKEN"; return 2; }
    fail2ban_require_managed || return $?
    vps_cmd_require_root || return $?
    vps_cmd_lock security-fail2ban || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then vps_cmd_info "演练：仅移除受管配置，不移除包、服务或备份"; return 0; fi
    fail2ban_prepare_dirs || return $?
    backup="$(fail2ban_make_backup)" || return $?
    systemctl is-active --quiet "$FAIL2BAN_SERVICE" >/dev/null 2>&1 && was_active=1
    rm -f -- "$FAIL2BAN_CONFIG" || return 20
    if [[ "$was_active" == 1 ]] && ! fail2ban-client reload --restart sshd; then
        fail2ban_restore_snapshot "$backup" || return 30
        fail2ban-client reload --restart sshd >/dev/null 2>&1 || true
        return 20
    fi
    if ! rm -f -- "$FAIL2BAN_HASH_FILE" "$FAIL2BAN_METADATA_FILE"; then
        fail2ban_restore_snapshot "$backup" || return 30
        fail2ban-client reload --restart sshd >/dev/null 2>&1 || true
        return 20
    fi
    vps_cmd_success "已移除 vpsctl 受管 Fail2ban 配置；保留软件包、服务和备份 $backup"
}

fail2ban_menu() {
    local choice action value ip backup current_answer status=0 rc
    local -a install_args=()
    while true; do
        choice="$(vps_cmd_prompt_select "Fail2ban SSH 防护" status status "查看状态" install "安装默认策略" configure "调整封禁参数" sync "同步 SSH 端口" ignore "管理忽略地址" unban "解除 IP 封禁" service "服务启停/重启" verify "执行 ban/unban 验证" logs "查看日志" restore "恢复备份" uninstall "移除受管配置" quit "退出")" || {
            rc=$?; [[ "$rc" == 130 ]] && return "$status"; return "$rc"
        }
        case "$choice" in
            status) fail2ban_status 0 || status=$? ;;
            install)
                install_args=()
                if ip="$(fail2ban_current_session_ip 2>/dev/null)"; then
                    current_answer="$(vps_cmd_prompt_select "是否将当前 SSH 客户端 $ip 加入 ignoreip" no no "不加入" yes "加入")" || continue
                    [[ "$current_answer" != yes ]] || install_args+=(--ignore-current-session)
                fi
                fail2ban_dispatch_install "${install_args[@]}" || status=$?
                ;;
            configure)
                fail2ban_require_managed || { status=$?; continue; }
                fail2ban_load_config
                value="$(vps_cmd_prompt_value "bantime" "$FAIL2BAN_BANTIME")" || continue
                action="$(vps_cmd_prompt_value "findtime" "$FAIL2BAN_FINDTIME")" || continue
                ip="$(vps_cmd_prompt_value "maxretry" "$FAIL2BAN_MAXRETRY")" || continue
                current_answer="$(vps_cmd_prompt_select "递增封禁" "$FAIL2BAN_INCREMENT" on "开启" off "关闭")" || continue
                backup="$(vps_cmd_prompt_value "max-bantime" "$FAIL2BAN_MAX_BANTIME")" || continue
                fail2ban_dispatch_configure --bantime "$value" --findtime "$action" --maxretry "$ip" --increment "$current_answer" --max-bantime "$backup" || status=$?
                ;;
            sync) fail2ban_sync_ssh_port || status=$? ;;
            ignore)
                action="$(vps_cmd_prompt_select "忽略地址操作" list list "列出" add "添加" remove "移除")" || continue
                if [[ "$action" == list ]]; then fail2ban_ignore_list || status=$?
                else ip="$(vps_cmd_prompt_value "IP 或 CIDR" '')" || continue; fail2ban_ignore_change "$action" --ip "$ip" || status=$?; fi
                ;;
            unban) ip="$(vps_cmd_prompt_value "要解除封禁的 IP" '')" || continue; fail2ban_unban --ip "$ip" || status=$? ;;
            service) action="$(vps_cmd_prompt_select "服务操作" restart restart "重启" start "启动" stop "停止")" || continue; fail2ban_service_action "$action" || status=$? ;;
            verify) fail2ban_verify || status=$? ;;
            logs) value="$(vps_cmd_prompt_value "日志行数" 100)" || continue; fail2ban_logs --lines "$value" || status=$? ;;
            restore)
                backup="$(vps_cmd_prompt_value "备份 ID" '')" || continue
                vps_cmd_confirm_token "确认恢复备份" "$backup" || continue
                fail2ban_restore --backup "$backup" --confirm-restore "$backup" || status=$?
                ;;
            uninstall)
                vps_cmd_confirm_token "仅移除 vpsctl 受管配置" "$FAIL2BAN_UNINSTALL_TOKEN" || continue
                fail2ban_uninstall --confirm-uninstall "$FAIL2BAN_UNINSTALL_TOKEN" || status=$?
                ;;
            quit) return "$status" ;;
        esac
    done
}

fail2ban_main() {
    local action init_status
    fail2ban_parse_globals "$@"
    if vps_cmd_init "security fail2ban" "$FAIL2BAN_PROJECT_ROOT"; then :; else init_status=$?; return "$init_status"; fi
    fail2ban_init_paths || return $?
    set -- "${FAIL2BAN_ARGS[@]}"
    action="${1:-}"
    if [[ "$action" == help || "$action" == -h || "$action" == --help ]]; then (($# == 1)) || { vps_cmd_error "help 不接受额外参数"; return 2; }; fail2ban_usage; return 0; fi
    if [[ "$action" == status ]]; then fail2ban_require_platform 1 || return $?; else fail2ban_require_platform 0 || return $?; fi
    if [[ -z "$action" ]]; then if vps_cmd_is_interactive; then fail2ban_menu; else fail2ban_status 0; fi; return $?; fi
    shift
    case "$action" in
        status) fail2ban_dispatch_status "$@" ;;
        install) fail2ban_dispatch_install "$@" ;;
        configure) fail2ban_dispatch_configure "$@" ;;
        sync-ssh-port) (($# == 0)) || { vps_cmd_error "sync-ssh-port 不接受参数"; return 2; }; fail2ban_sync_ssh_port ;;
        ignore) fail2ban_dispatch_ignore "$@" ;;
        unban) fail2ban_unban "$@" ;;
        verify) (($# == 0)) || { vps_cmd_error "verify 不接受参数"; return 2; }; fail2ban_verify ;;
        start | stop | restart) (($# == 0)) || { vps_cmd_error "$action 不接受参数"; return 2; }; fail2ban_service_action "$action" ;;
        logs) fail2ban_logs "$@" ;;
        restore) fail2ban_restore "$@" ;;
        uninstall) fail2ban_uninstall "$@" ;;
        *) vps_cmd_error "未知 security fail2ban 动作：$action"; fail2ban_usage >&2; return 2 ;;
    esac
}

trap 'vps_cmd_unlock' EXIT

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    fail2ban_main "$@"
fi
