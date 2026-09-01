#!/usr/bin/env bash
# Global CLI flags are consumed by the sourced command helper library.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

IP_POLICY_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly IP_POLICY_PROJECT_ROOT
readonly IP_POLICY_MANAGED_MARKER='# Managed by vpsctl network ip-policy.'
readonly IP_POLICY_SCOPE='glibc_getaddrinfo_order'

# shellcheck source=../../lib/command.sh
source "${IP_POLICY_PROJECT_ROOT}/lib/command.sh"

IP_POLICY_GAI_FILE=""
IP_POLICY_STATE_FILE=""
IP_POLICY_BACKUP_ROOT=""
IP_POLICY_ARGS=()

IP_POLICY_STATE_LOADED=0
IP_POLICY_STATE_ORIGINAL_PRESENT=""
IP_POLICY_STATE_ORIGINAL_MODE=""
IP_POLICY_STATE_BACKUP_FILE=""
IP_POLICY_STATE_BACKUP_SHA256=""
IP_POLICY_STATE_MANAGED_POLICY=""
IP_POLICY_STATE_MANAGED_SHA256=""

ip_policy_usage() {
    cat <<'EOF'
管理 glibc getaddrinfo(3) 的 IPv4/IPv6 地址选择顺序。

用法：
  ip-policy.sh [global-options] status [--json]
  ip-policy.sh [global-options] set --policy prefer_ipv4|prefer_ipv6
  ip-policy.sh [global-options] restore

操作：
  status               显示策略、所有权及地址/默认路由诊断
  set                  写入完整 RFC 6724 precedence 表
  restore              精确恢复首次修改前的 /etc/gai.conf

选项：
  --policy POLICY      prefer_ipv4 或 prefer_ipv6
  --json               以 JSON 输出 status
  --install-deps       明确允许安装缺失的系统工具
  --dry-run            仅显示计划，不修改系统
  --yes                自动同意普通确认提示
  --non-interactive    禁止从终端读取输入
  --quiet              隐藏非必要信息
  --verbose            显示更多诊断信息
  --no-color           禁用彩色输出
  --                    停止解析全局选项
  -h, --help           显示此帮助

本命令只影响使用 glibc getaddrinfo(3) 地址排序的程序，不修改接口地址、
路由、DNS 服务器或内核 IPv6 开关。
EOF
}

ip_policy_require_linux() {
    [[ "${VPSCTL_TESTING:-0}" == "1" || "$(uname -s 2>/dev/null || true)" == "Linux" ]] && return 0
    vps_cmd_error "network ip-policy 仅支持 Linux"
    return 3
}

ip_policy_detect_libc() {
    local output="" loader

    case "${VPSCTL_ENV_LIBC:-}" in
        glibc | musl) printf '%s\n' "$VPSCTL_ENV_LIBC"; return 0 ;;
    esac
    if command -v getconf >/dev/null 2>&1; then
        output="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
        [[ "${output,,}" == glibc\ * ]] && { printf 'glibc\n'; return 0; }
    fi
    if command -v ldd >/dev/null 2>&1; then
        output="$(LC_ALL=C ldd --version 2>&1 || true)"
        case "${output,,}" in
            *musl*) printf 'musl\n'; return 0 ;;
            *glibc* | *"gnu libc"* | *"gnu c library"*) printf 'glibc\n'; return 0 ;;
        esac
    fi
    for loader in /lib/ld-musl-*.so.1 /lib64/ld-musl-*.so.1; do
        [[ ! -e "$loader" ]] || { printf 'musl\n'; return 0; }
    done
    printf 'unknown\n'
}

ip_policy_require_glibc() {
    local libc

    libc="$(ip_policy_detect_libc)" || return 3
    [[ "$libc" == "glibc" ]] && return 0
    vps_cmd_error "network ip-policy 仅适用于 glibc；当前用户空间：$libc"
    return 3
}

ip_policy_parse_standalone_globals() {
    IP_POLICY_ARGS=()
    while (($# > 0)); do
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
                IP_POLICY_ARGS=("$@")
                return 0
                ;;
            *)
                IP_POLICY_ARGS=("$@")
                return 0
                ;;
        esac
        shift
    done
}

ip_policy_logical_path() {
    local path="$1"

    if [[ "${VPSCTL_TESTING:-0}" == "1" ]]; then
        printf '%s\n' "${path#"$VPSCTL_SYSTEM_ROOT"}"
    else
        printf '%s\n' "$path"
    fi
}

ip_policy_require_safe_path() {
    local path="$1" status

    if vps_cmd_require_no_symlink_components "$path" 2>/dev/null; then
        return 0
    else
        status=$?
    fi
    vps_cmd_error "系统路径包含符号链接，拒绝继续：$(ip_policy_logical_path "$path")"
    return "$status"
}

ip_policy_validate_paths() {
    local path

    for path in "$IP_POLICY_GAI_FILE" "$IP_POLICY_STATE_FILE" "$IP_POLICY_BACKUP_ROOT"; do
        ip_policy_require_safe_path "$path" || return $?
    done
    if [[ -e "$IP_POLICY_GAI_FILE" && ! -f "$IP_POLICY_GAI_FILE" ]]; then
        vps_cmd_error "/etc/gai.conf 不是普通文件，拒绝继续"
        return 3
    fi
    if [[ -e "$IP_POLICY_STATE_FILE" && ! -f "$IP_POLICY_STATE_FILE" ]]; then
        vps_cmd_error "ip-policy 状态路径不是普通文件，拒绝继续"
        return 3
    fi
}

ip_policy_prepare_directories() {
    local state_directory="${IP_POLICY_STATE_FILE%/*}"
    local state_root state_network path

    state_root="$(vps_cmd_system_path /var/lib/vpsctl)" || return $?
    state_network="$(vps_cmd_system_path /var/lib/vpsctl/network)" || return $?
    for path in "$state_root" "$state_network" "$state_directory"; do
        ip_policy_require_safe_path "$path" || return $?
    done
    ip_policy_require_safe_path "$IP_POLICY_BACKUP_ROOT" || return $?
    vps_cmd_run mkdir -p -- "$state_root" "$state_network" "$state_directory" "$IP_POLICY_BACKUP_ROOT" || return 20
    # state.json is deliberately non-secret and status must remain usable by
    # non-root callers.  Do not change modes on shared vpsctl ancestors: other
    # commands may intentionally have provisioned them more restrictively.
    vps_cmd_run chmod 0755 -- "$state_directory" || return 20
    vps_cmd_run chmod 0700 -- "$IP_POLICY_BACKUP_ROOT" || return 20
}

ip_policy_atomic_write_physical() {
    local physical_path="$1" mode="$2" logical_path

    logical_path="$(ip_policy_logical_path "$physical_path")"
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        cat >/dev/null
        vps_cmd_info "演练：将以权限 ${mode} 原子写入 ${logical_path}"
        return 0
    fi
    vps_cmd_atomic_write "$logical_path" "$mode"
}

ip_policy_render() {
    local policy="$1" mapped_precedence

    case "$policy" in
        prefer_ipv4) mapped_precedence=100 ;;
        prefer_ipv6) mapped_precedence=35 ;;
        *) return 2 ;;
    esac

    printf '%s\n' "$IP_POLICY_MANAGED_MARKER"
    printf '# scope: %s\n' "$IP_POLICY_SCOPE"
    printf '# policy: %s\n' "$policy"
    printf 'precedence ::1/128       50\n'
    printf 'precedence ::/0          40\n'
    printf 'precedence ::ffff:0:0/96 %s\n' "$mapped_precedence"
    printf 'precedence 2002::/16     30\n'
    printf 'precedence 2001::/32      5\n'
    printf 'precedence fc00::/7        3\n'
    printf 'precedence ::/96           1\n'
    printf 'precedence fec0::/10       1\n'
    printf 'precedence 3ffe::/16       1\n'
}

ip_policy_sha256_stream() {
    local output

    output="$(sha256sum)" || return 20
    output="${output%%[[:space:]]*}"
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || return 20
    printf '%s\n' "$output"
}

ip_policy_sha256_file() {
    local path="$1" output

    [[ -f "$path" && ! -L "$path" ]] || return 3
    output="$(sha256sum -- "$path")" || return 20
    output="${output%%[[:space:]]*}"
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || return 20
    printf '%s\n' "$output"
}

ip_policy_expected_hash() {
    ip_policy_render "$1" | ip_policy_sha256_stream
}

ip_policy_file_has_marker() {
    local line

    [[ -f "$IP_POLICY_GAI_FILE" && ! -L "$IP_POLICY_GAI_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$IP_POLICY_MANAGED_MARKER" ]] && return 0
    done <"$IP_POLICY_GAI_FILE"
    return 1
}

ip_policy_original_is_safe_to_adopt() {
    local line trimmed

    [[ -e "$IP_POLICY_GAI_FILE" ]] || return 0
    [[ -f "$IP_POLICY_GAI_FILE" && ! -L "$IP_POLICY_GAI_FILE" ]] || {
        vps_cmd_error "/etc/gai.conf 不是安全的普通文件，拒绝接管"
        return 3
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        trimmed="$(vps_cmd_trim "$line")"
        [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
        vps_cmd_error "首次接管时 /etc/gai.conf 含有非空、非注释配置，拒绝覆盖"
        return 3
    done <"$IP_POLICY_GAI_FILE"
}

ip_policy_reset_state_variables() {
    IP_POLICY_STATE_LOADED=0
    IP_POLICY_STATE_ORIGINAL_PRESENT=""
    IP_POLICY_STATE_ORIGINAL_MODE=""
    IP_POLICY_STATE_BACKUP_FILE=""
    IP_POLICY_STATE_BACKUP_SHA256=""
    IP_POLICY_STATE_MANAGED_POLICY=""
    IP_POLICY_STATE_MANAGED_SHA256=""
}

ip_policy_load_state() {
    local quiet="${1:-0}" line key value required
    local schema_version="" scope="" target="" started=0 ended=0
    local -A seen=()

    ip_policy_reset_state_variables
    [[ -f "$IP_POLICY_STATE_FILE" && ! -L "$IP_POLICY_STATE_FILE" ]] || {
        [[ "$quiet" == "1" ]] || vps_cmd_error "尚未保存 ip-policy 原始状态"
        return 3
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="$(vps_cmd_trim "$line")"
        case "$line" in
            \{)
                ((started == 0 && ended == 0)) || {
                    [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态文件 JSON 边界无效"
                    return 10
                }
                started=1
                continue
                ;;
            \})
                ((started == 1 && ended == 0)) || {
                    [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态文件 JSON 边界无效"
                    return 10
                }
                ended=1
                continue
                ;;
        esac
        ((started == 1 && ended == 0)) || {
            [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态字段位于 JSON 对象之外"
            return 10
        }
        [[ "$line" =~ ^\"([a-z0-9_]+)\"[[:space:]]*:[[:space:]]*(.*),?$ ]] || {
            [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态文件格式无效"
            return 10
        }
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        value="${value%,}"
        [[ -z "${seen[$key]+x}" ]] || {
            [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态文件含有重复键：${key}"
            return 10
        }
        seen["$key"]=1
        case "$key" in
            schema_version) schema_version="$value" ;;
            scope | target | original_mode | backup_file | backup_sha256 | managed_policy | managed_sha256)
                [[ "$value" =~ ^\"([^\"]*)\"$ ]] || {
                    [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态字段 ${key} 格式无效"
                    return 10
                }
                value="${BASH_REMATCH[1]}"
                case "$key" in
                    scope) scope="$value" ;;
                    target) target="$value" ;;
                    original_mode) IP_POLICY_STATE_ORIGINAL_MODE="$value" ;;
                    backup_file) IP_POLICY_STATE_BACKUP_FILE="$value" ;;
                    backup_sha256) IP_POLICY_STATE_BACKUP_SHA256="$value" ;;
                    managed_policy) IP_POLICY_STATE_MANAGED_POLICY="$value" ;;
                    managed_sha256) IP_POLICY_STATE_MANAGED_SHA256="$value" ;;
                esac
                ;;
            original_present)
                case "$value" in
                    true) IP_POLICY_STATE_ORIGINAL_PRESENT=1 ;;
                    false) IP_POLICY_STATE_ORIGINAL_PRESENT=0 ;;
                    *)
                        [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态中的 original_present 无效"
                        return 10
                        ;;
                esac
                ;;
            *)
                [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态文件含有未知键：${key}"
                return 10
                ;;
        esac
    done <"$IP_POLICY_STATE_FILE"

    ((started == 1 && ended == 1)) || {
        [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态文件 JSON 对象不完整"
        return 10
    }

    for required in schema_version scope target original_present original_mode backup_file backup_sha256 managed_policy managed_sha256; do
        [[ -n "${seen[$required]+x}" ]] || {
            [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态文件缺少键：${required}"
            return 10
        }
    done
    [[ "$schema_version" == "1" && "$scope" == "$IP_POLICY_SCOPE" && "$target" == "/etc/gai.conf" ]] || {
        [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态文件版本、作用域或目标无效"
        return 10
    }
    [[ "$IP_POLICY_STATE_MANAGED_POLICY" == "prefer_ipv4" || "$IP_POLICY_STATE_MANAGED_POLICY" == "prefer_ipv6" ]] || {
        [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态中的策略无效"
        return 10
    }
    [[ "$IP_POLICY_STATE_MANAGED_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
        [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 状态中的受管 SHA-256 无效"
        return 10
    }
    if [[ "$IP_POLICY_STATE_ORIGINAL_PRESENT" == "1" ]]; then
        if ! [[ "$IP_POLICY_STATE_ORIGINAL_MODE" =~ ^[0-7]{3,4}$ ]] ||
            [[ "$IP_POLICY_STATE_BACKUP_FILE" != /var/lib/vpsctl/backups/network/ip-policy/*/gai.conf ]] ||
            ! [[ "$IP_POLICY_STATE_BACKUP_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
            [[ "$quiet" == "1" ]] || vps_cmd_error "ip-policy 原始文件元数据无效"
            return 10
        fi
    else
        [[ -z "$IP_POLICY_STATE_ORIGINAL_MODE" && -z "$IP_POLICY_STATE_BACKUP_FILE" && -z "$IP_POLICY_STATE_BACKUP_SHA256" ]] || {
            [[ "$quiet" == "1" ]] || vps_cmd_error "缺失原始文件不应包含备份元数据"
            return 10
        }
    fi
    IP_POLICY_STATE_LOADED=1
}

ip_policy_validate_backup() {
    local backup_path actual_hash root_real parent_real

    [[ "$IP_POLICY_STATE_ORIGINAL_PRESENT" == "1" ]] || return 0
    backup_path="$(vps_cmd_system_path "$IP_POLICY_STATE_BACKUP_FILE")" || return $?
    ip_policy_require_safe_path "$backup_path" || return $?
    [[ -f "$backup_path" && ! -L "$backup_path" ]] || {
        vps_cmd_error "ip-policy 原始备份缺失或不安全"
        return 10
    }
    root_real="$(cd -- "$IP_POLICY_BACKUP_ROOT" && pwd -P)" || return 10
    parent_real="$(cd -- "${backup_path%/*}" && pwd -P)" || return 10
    [[ "$parent_real" == "$root_real"/* ]] || {
        vps_cmd_error "ip-policy 备份路径超出固定备份根目录"
        return 10
    }
    actual_hash="$(ip_policy_sha256_file "$backup_path")" || return $?
    [[ "$actual_hash" == "$IP_POLICY_STATE_BACKUP_SHA256" ]] || {
        vps_cmd_error "ip-policy 原始备份 SHA-256 校验失败"
        return 10
    }
}

ip_policy_validate_managed_ownership() {
    local actual_hash expected_hash

    [[ "$IP_POLICY_STATE_LOADED" == "1" ]] || return 70
    [[ -f "$IP_POLICY_GAI_FILE" && ! -L "$IP_POLICY_GAI_FILE" ]] || {
        vps_cmd_error "受管 /etc/gai.conf 缺失或不安全，拒绝覆盖"
        return 3
    }
    ip_policy_file_has_marker || {
        vps_cmd_error "/etc/gai.conf 缺少 vpsctl 固定 marker，拒绝覆盖"
        return 3
    }
    actual_hash="$(ip_policy_sha256_file "$IP_POLICY_GAI_FILE")" || return $?
    expected_hash="$(ip_policy_expected_hash "$IP_POLICY_STATE_MANAGED_POLICY")" || return $?
    [[ "$IP_POLICY_STATE_MANAGED_SHA256" == "$expected_hash" && "$actual_hash" == "$expected_hash" ]] || {
        vps_cmd_error "/etc/gai.conf SHA-256 与 vpsctl 所有权记录不符，拒绝覆盖"
        return 3
    }
}

ip_policy_write_state() {
    local original_present="$1" original_mode="$2" backup_file="$3"
    local backup_sha256="$4" policy="$5" managed_sha256="$6"
    local json_present=false

    [[ "$original_present" == "1" ]] && json_present=true
    {
        printf '{\n'
        printf '  "schema_version": 1,\n'
        printf '  "scope": "%s",\n' "$IP_POLICY_SCOPE"
        printf '  "target": "/etc/gai.conf",\n'
        printf '  "original_present": %s,\n' "$json_present"
        printf '  "original_mode": "%s",\n' "$original_mode"
        printf '  "backup_file": "%s",\n' "$backup_file"
        printf '  "backup_sha256": "%s",\n' "$backup_sha256"
        printf '  "managed_policy": "%s",\n' "$policy"
        printf '  "managed_sha256": "%s"\n' "$managed_sha256"
        printf '}\n'
    } | ip_policy_atomic_write_physical "$IP_POLICY_STATE_FILE" 0644
}

ip_policy_write_managed() {
    local policy="$1"
    ip_policy_render "$policy" | ip_policy_atomic_write_physical "$IP_POLICY_GAI_FILE" 0644
}

ip_policy_backup_original() {
    local backup_physical

    backup_physical="$(vps_cmd_backup_file ip-policy /etc/gai.conf)" || return $?
    ip_policy_logical_path "$backup_physical"
}

ip_policy_restore_original_content() {
    local backup_path

    if [[ "$IP_POLICY_STATE_ORIGINAL_PRESENT" == "1" ]]; then
        backup_path="$(vps_cmd_system_path "$IP_POLICY_STATE_BACKUP_FILE")" || return $?
        ip_policy_atomic_write_physical "$IP_POLICY_GAI_FILE" "$IP_POLICY_STATE_ORIGINAL_MODE" <"$backup_path"
    else
        vps_cmd_run rm -f -- "$IP_POLICY_GAI_FILE"
    fi
}

ip_policy_dependencies() {
    local action="$1"
    local -a tools=(sha256sum)

    if [[ "$action" == "set" || "$action" == "restore" ]]; then
        tools+=(flock)
    fi
    vps_cmd_ensure_tools network-ip-policy "${tools[@]}"
}

ip_policy_stop_after_dependency_plan() {
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == "1" ]] || return 1
    vps_cmd_info "依赖仅完成安装计划；请安装依赖后重新运行"
}

ip_policy_set() {
    local policy="$1" status=0 locked=0
    local original_present=0 original_mode="" backup_file="" backup_sha256=""
    local managed_sha256 old_policy="" new_state=0 managed_written=0

    [[ "$policy" == "prefer_ipv4" || "$policy" == "prefer_ipv6" ]] || {
        vps_cmd_error "无效策略：${policy}"
        return 2
    }
    ip_policy_dependencies set || return $?
    ip_policy_stop_after_dependency_plan && return 0
    vps_cmd_require_root || return $?
    ip_policy_validate_paths || return $?

    if [[ -e "$IP_POLICY_STATE_FILE" ]]; then
        ip_policy_load_state || return $?
        ip_policy_validate_managed_ownership || return $?
        ip_policy_validate_backup || return $?
        old_policy="$IP_POLICY_STATE_MANAGED_POLICY"
        if [[ "$old_policy" == "$policy" ]]; then
            vps_cmd_success "地址选择策略已是 ${policy}"
            return 0
        fi
    else
        ip_policy_original_is_safe_to_adopt || return $?
        new_state=1
    fi

    if vps_cmd_confirm "是否将系统地址选择策略设置为 ${policy}？"; then
        :
    else
        status=$?
        if ((status == 1)); then
            vps_cmd_info "未进行任何更改"
            return 0
        fi
        return "$status"
    fi

    managed_sha256="$(ip_policy_expected_hash "$policy")" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        ip_policy_prepare_directories || return $?
        ip_policy_write_managed "$policy" || return $?
        ip_policy_write_state 0 "" "" "" "$policy" "$managed_sha256" || return $?
        vps_cmd_success "演练完成：将设置地址选择策略 ${policy}"
        return 0
    fi

    vps_cmd_lock network-ip-policy || return $?
    locked=1
    ip_policy_validate_paths || status=$?
    if ((status == 0)) && [[ "$new_state" == "1" ]]; then
        [[ ! -e "$IP_POLICY_STATE_FILE" ]] || {
            vps_cmd_error "获取锁后发现状态已变化，请重试"
            status=3
        }
        ((status != 0)) || ip_policy_original_is_safe_to_adopt || status=$?
    elif ((status == 0)); then
        ip_policy_load_state || status=$?
        ((status != 0)) || ip_policy_validate_managed_ownership || status=$?
        ((status != 0)) || ip_policy_validate_backup || status=$?
        if ((status == 0)) && [[ "$IP_POLICY_STATE_MANAGED_POLICY" != "$old_policy" ]]; then
            vps_cmd_error "获取锁后发现策略已变化，请重试"
            status=3
        fi
    fi
    ((status != 0)) || ip_policy_prepare_directories || status=$?

    if ((status == 0)) && [[ "$new_state" == "1" ]]; then
        if [[ -f "$IP_POLICY_GAI_FILE" ]]; then
            original_present=1
            original_mode="$(stat -c '%a' -- "$IP_POLICY_GAI_FILE")" || status=20
            if ((status == 0)); then
                backup_file="$(ip_policy_backup_original)" || status=$?
            fi
            if ((status == 0)); then
                backup_sha256="$(ip_policy_sha256_file "$(vps_cmd_system_path "$backup_file")")" || status=$?
            fi
        fi
    elif ((status == 0)); then
        original_present="$IP_POLICY_STATE_ORIGINAL_PRESENT"
        original_mode="$IP_POLICY_STATE_ORIGINAL_MODE"
        backup_file="$IP_POLICY_STATE_BACKUP_FILE"
        backup_sha256="$IP_POLICY_STATE_BACKUP_SHA256"
    fi

    if ((status == 0)); then
        if ip_policy_write_managed "$policy"; then
            managed_written=1
        else
            status=$?
        fi
    fi
    if ((status == 0)); then
        ip_policy_write_state "$original_present" "$original_mode" "$backup_file" "$backup_sha256" "$policy" "$managed_sha256" || status=$?
    fi
    if ((status != 0 && managed_written == 1)); then
        if [[ "$new_state" == "1" ]]; then
            IP_POLICY_STATE_ORIGINAL_PRESENT="$original_present"
            IP_POLICY_STATE_ORIGINAL_MODE="$original_mode"
            IP_POLICY_STATE_BACKUP_FILE="$backup_file"
            ip_policy_restore_original_content >/dev/null 2>&1 || status=30
        elif [[ -n "$old_policy" ]]; then
            ip_policy_write_managed "$old_policy" >/dev/null 2>&1 || status=30
        fi
    fi
    ((locked == 0)) || vps_cmd_unlock
    ((status == 0)) || return "$status"
    vps_cmd_success "已设置系统地址选择策略：${policy}"
    vps_cmd_info "作用域仅为 glibc getaddrinfo 地址排序；未重启服务，长期运行进程可能继续使用缓存或旧排序"
}

ip_policy_restore() {
    local status=0 locked=0 old_policy restored=0

    ip_policy_dependencies restore || return $?
    ip_policy_stop_after_dependency_plan && return 0
    vps_cmd_require_root || return $?
    ip_policy_validate_paths || return $?
    ip_policy_load_state || return $?
    ip_policy_validate_managed_ownership || return $?
    ip_policy_validate_backup || return $?
    old_policy="$IP_POLICY_STATE_MANAGED_POLICY"

    if vps_cmd_confirm "是否恢复首次修改前的 /etc/gai.conf？"; then
        :
    else
        status=$?
        if ((status == 1)); then
            vps_cmd_info "未进行任何更改"
            return 0
        fi
        return "$status"
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        if [[ "$IP_POLICY_STATE_ORIGINAL_PRESENT" == "1" ]]; then
            vps_cmd_info "演练：将从 ${IP_POLICY_STATE_BACKUP_FILE} 原子恢复 /etc/gai.conf"
        else
            vps_cmd_info "演练：将删除首次修改前不存在的 /etc/gai.conf"
        fi
        vps_cmd_info "演练：将移除活动状态 /var/lib/vpsctl/network/ip-policy/state.json"
        return 0
    fi

    vps_cmd_lock network-ip-policy || return $?
    locked=1
    ip_policy_validate_paths || status=$?
    ((status != 0)) || ip_policy_load_state || status=$?
    ((status != 0)) || ip_policy_validate_managed_ownership || status=$?
    ((status != 0)) || ip_policy_validate_backup || status=$?
    if ((status == 0)) && [[ "$IP_POLICY_STATE_MANAGED_POLICY" != "$old_policy" ]]; then
        vps_cmd_error "获取锁后发现策略已变化，请重试"
        status=3
    fi
    if ((status == 0)); then
        if ip_policy_restore_original_content; then
            restored=1
        else
            status=$?
        fi
    fi
    if ((status == 0)); then
        rm -f -- "$IP_POLICY_STATE_FILE" || status=20
    fi
    if ((status != 0 && restored == 1)); then
        ip_policy_write_managed "$old_policy" >/dev/null 2>&1 || status=30
    fi
    ((locked == 0)) || vps_cmd_unlock
    ((status == 0)) || return "$status"
    vps_cmd_success "已恢复首次修改前的 /etc/gai.conf"
    vps_cmd_info "未重启服务；长期运行进程可能继续使用缓存或恢复前的地址排序"
}

ip_policy_diagnostic() {
    local family="$1" kind="$2" output

    command -v ip >/dev/null 2>&1 || {
        printf '不可用'
        return 0
    }
    case "$kind" in
        address)
            output="$(ip -o "-$family" address show scope global 2>/dev/null | awk '{print $4}' || true)"
            ;;
        route)
            output="$(ip "-$family" route show default 2>/dev/null || true)"
            ;;
        *) return 70 ;;
    esac
    output="${output//$'\n'/, }"
    printf '%s' "${output:-无}"
}

ip_policy_json_escape() {
    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

ip_policy_collect_status() {
    local actual_hash expected_hash

    IP_POLICY_STATUS_POLICY="unmanaged"
    IP_POLICY_STATUS_MANAGED=false
    IP_POLICY_STATUS_OWNERSHIP="unmanaged"
    IP_POLICY_STATUS_STATE=false

    if [[ -e "$IP_POLICY_STATE_FILE" || -L "$IP_POLICY_STATE_FILE" ]]; then
        IP_POLICY_STATUS_STATE=true
        if ! ip_policy_require_safe_path "$IP_POLICY_STATE_FILE" >/dev/null 2>&1 ||
            ! ip_policy_load_state 1; then
            IP_POLICY_STATUS_OWNERSHIP="invalid_state"
            IP_POLICY_STATUS_POLICY="unknown"
        elif ! ip_policy_require_safe_path "$IP_POLICY_GAI_FILE" >/dev/null 2>&1 ||
            [[ ! -f "$IP_POLICY_GAI_FILE" || -L "$IP_POLICY_GAI_FILE" ]]; then
            IP_POLICY_STATUS_OWNERSHIP="managed_file_missing"
            IP_POLICY_STATUS_POLICY="$IP_POLICY_STATE_MANAGED_POLICY"
        elif ! ip_policy_file_has_marker; then
            IP_POLICY_STATUS_OWNERSHIP="marker_missing"
            IP_POLICY_STATUS_POLICY="$IP_POLICY_STATE_MANAGED_POLICY"
        elif ! command -v sha256sum >/dev/null 2>&1; then
            IP_POLICY_STATUS_OWNERSHIP="sha256_unavailable"
            IP_POLICY_STATUS_POLICY="$IP_POLICY_STATE_MANAGED_POLICY"
        else
            actual_hash="$(ip_policy_sha256_file "$IP_POLICY_GAI_FILE" 2>/dev/null || true)"
            expected_hash="$(ip_policy_expected_hash "$IP_POLICY_STATE_MANAGED_POLICY" 2>/dev/null || true)"
            IP_POLICY_STATUS_POLICY="$IP_POLICY_STATE_MANAGED_POLICY"
            if [[ -n "$actual_hash" && "$actual_hash" == "$expected_hash" && "$actual_hash" == "$IP_POLICY_STATE_MANAGED_SHA256" ]]; then
                IP_POLICY_STATUS_MANAGED=true
                IP_POLICY_STATUS_OWNERSHIP="verified"
            else
                IP_POLICY_STATUS_OWNERSHIP="sha256_mismatch"
            fi
        fi
    elif [[ -e "$IP_POLICY_GAI_FILE" || -L "$IP_POLICY_GAI_FILE" ]]; then
        IP_POLICY_STATUS_POLICY="unmanaged"
        IP_POLICY_STATUS_OWNERSHIP="unmanaged_file"
    fi

    IP_POLICY_STATUS_IPV4_ADDRESSES="$(ip_policy_diagnostic 4 address)"
    IP_POLICY_STATUS_IPV6_ADDRESSES="$(ip_policy_diagnostic 6 address)"
    IP_POLICY_STATUS_IPV4_ROUTE="$(ip_policy_diagnostic 4 route)"
    IP_POLICY_STATUS_IPV6_ROUTE="$(ip_policy_diagnostic 6 route)"
}

ip_policy_status() {
    local json="${1:-0}" managed_text state_text ownership_style=warning

    ip_policy_collect_status
    if [[ "$json" == "1" ]]; then
        printf '{\n'
        printf '  "schema_version": 1,\n'
        printf '  "scope": "%s",\n' "$IP_POLICY_SCOPE"
        printf '  "policy": "%s",\n' "$(ip_policy_json_escape "$IP_POLICY_STATUS_POLICY")"
        printf '  "managed": %s,\n' "$IP_POLICY_STATUS_MANAGED"
        printf '  "ownership": "%s",\n' "$(ip_policy_json_escape "$IP_POLICY_STATUS_OWNERSHIP")"
        printf '  "state_saved": %s,\n' "$IP_POLICY_STATUS_STATE"
        printf '  "config_path": "/etc/gai.conf",\n'
        printf '  "diagnostics": {\n'
        printf '    "ipv4_addresses": "%s",\n' "$(ip_policy_json_escape "$IP_POLICY_STATUS_IPV4_ADDRESSES")"
        printf '    "ipv6_addresses": "%s",\n' "$(ip_policy_json_escape "$IP_POLICY_STATUS_IPV6_ADDRESSES")"
        printf '    "ipv4_default_route": "%s",\n' "$(ip_policy_json_escape "$IP_POLICY_STATUS_IPV4_ROUTE")"
        printf '    "ipv6_default_route": "%s"\n' "$(ip_policy_json_escape "$IP_POLICY_STATUS_IPV6_ROUTE")"
        printf '  }\n'
        printf '}\n'
        return 0
    fi

    managed_text="否"
    state_text="未保存"
    [[ "$IP_POLICY_STATUS_MANAGED" == "true" ]] && managed_text="是"
    [[ "$IP_POLICY_STATUS_STATE" == "true" ]] && state_text="已保存"
    [[ "$IP_POLICY_STATUS_OWNERSHIP" == "verified" ]] && ownership_style=success
    [[ "$IP_POLICY_STATUS_OWNERSHIP" == "unmanaged" || "$IP_POLICY_STATUS_OWNERSHIP" == "unmanaged_file" ]] && ownership_style=info
    vps_cmd_status "作用域" "$IP_POLICY_SCOPE" info
    vps_cmd_status "地址选择策略" "$IP_POLICY_STATUS_POLICY" emphasis
    vps_cmd_status "vpsctl 受管" "$managed_text" "$ownership_style"
    vps_cmd_status "所有权校验" "$IP_POLICY_STATUS_OWNERSHIP" "$ownership_style"
    vps_cmd_status "原始状态" "$state_text" "$ownership_style"
    vps_cmd_status "全局 IPv4 地址" "$IP_POLICY_STATUS_IPV4_ADDRESSES" info
    vps_cmd_status "全局 IPv6 地址" "$IP_POLICY_STATUS_IPV6_ADDRESSES" info
    vps_cmd_status "IPv4 默认路由" "$IP_POLICY_STATUS_IPV4_ROUTE" info
    vps_cmd_status "IPv6 默认路由" "$IP_POLICY_STATUS_IPV6_ROUTE" info
}

ip_policy_menu_snapshot() {
    local managed="否"

    [[ -n "${IP_POLICY_GAI_FILE:-}" ]] || return 0
    ip_policy_collect_status || true
    [[ "${IP_POLICY_STATUS_MANAGED:-}" == "true" ]] && managed="是"
    printf '当前  %s  ·  受管 %s' "${IP_POLICY_STATUS_POLICY:-未知}" "$managed"
}

ip_policy_menu() {
    local choice status=0 prompt_status snapshot

    while true; do
        snapshot="$(ip_policy_menu_snapshot 2>/dev/null || true)"
        [[ -z "$snapshot" ]] || printf ' %s\n' "$snapshot" >&2
        choice="$(vps_cmd_prompt_select \
            "系统 IP 地址选择策略" status \
            status "查看状态" \
            prefer_ipv4 "优先 IPv4" \
            prefer_ipv6 "优先 IPv6" \
            restore "恢复原始状态" \
            quit "退出")" || {
                prompt_status=$?
                ((prompt_status == 130)) && return "$status"
                return "$prompt_status"
            }
        case "$choice" in
            status) ip_policy_status || status=$? ;;
            prefer_ipv4 | prefer_ipv6) ip_policy_set "$choice" || status=$? ;;
            restore) ip_policy_restore || status=$? ;;
            quit) return "$status" ;;
            *)
                vps_cmd_error "交互选择返回了未知 ip-policy 动作：${choice}"
                return 70
                ;;
        esac
    done
}

ip_policy_main() {
    local action policy="" json=0 init_status

    if vps_cmd_init network-ip-policy "$IP_POLICY_PROJECT_ROOT"; then
        :
    else
        init_status=$?
        return "$init_status"
    fi
    IP_POLICY_GAI_FILE="$(vps_cmd_system_path /etc/gai.conf)"
    IP_POLICY_STATE_FILE="$(vps_cmd_system_path /var/lib/vpsctl/network/ip-policy/state.json)"
    IP_POLICY_BACKUP_ROOT="$(vps_cmd_system_path /var/lib/vpsctl/backups/network/ip-policy)"

    ip_policy_parse_standalone_globals "$@"
    set -- "${IP_POLICY_ARGS[@]}"
    action="${1:-}"
    if [[ "$action" == "help" || "$action" == "-h" || "$action" == "--help" ]]; then
        (($# == 1)) || {
            vps_cmd_error "help 不接受额外参数"
            return 2
        }
        ip_policy_usage
        return 0
    fi
    ip_policy_require_linux || return $?
    ip_policy_require_glibc || return $?
    if [[ -z "$action" ]]; then
        if vps_cmd_is_interactive; then
            ip_policy_menu
        else
            ip_policy_status
        fi
        return $?
    fi
    shift

    case "$action" in
        status)
            while (($# > 0)); do
                case "$1" in
                    --json)
                        ((json == 0)) || {
                            vps_cmd_error "status 重复指定 --json"
                            return 2
                        }
                        json=1
                        ;;
                    *)
                        vps_cmd_error "未知 status 选项：$1"
                        return 2
                        ;;
                esac
                shift
            done
            ip_policy_status "$json"
            ;;
        set)
            while (($# > 0)); do
                case "$1" in
                    --policy)
                        (($# >= 2)) || {
                            vps_cmd_error "--policy 缺少参数值"
                            return 2
                        }
                        [[ -z "$policy" ]] || {
                            vps_cmd_error "set 重复指定 --policy"
                            return 2
                        }
                        policy="$2"
                        shift
                        ;;
                    *)
                        vps_cmd_error "未知 set 选项：$1"
                        return 2
                        ;;
                esac
                shift
            done
            [[ -n "$policy" ]] || {
                vps_cmd_error "set 需要 --policy"
                return 2
            }
            ip_policy_set "$policy"
            ;;
        restore)
            (($# == 0)) || {
                vps_cmd_error "restore 不接受选项"
                return 2
            }
            ip_policy_restore
            ;;
        *)
            vps_cmd_error "未知 ip-policy 动作：${action}"
            ip_policy_usage >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ip_policy_main "$@"
fi
