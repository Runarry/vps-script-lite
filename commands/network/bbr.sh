#!/usr/bin/env bash
# Global CLI flags are consumed by the sourced command helper library.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

BBR_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly BBR_PROJECT_ROOT
readonly BBR_MANAGED_MARKER='# Managed by vpsctl network bbr.'

# shellcheck source=../../lib/command.sh
source "${BBR_PROJECT_ROOT}/lib/command.sh"

BBR_ACTION=""
BBR_ALGORITHM=""
BBR_QDISC=""
BBR_APPLY_LIVE_QDISC=0

BBR_SYSCTL_FILE=""
BBR_MODULES_FILE=""
BBR_ORIGINAL_FILE=""

BBR_TX_ACTIVE=0
BBR_TX_ROLLBACK_NEEDED=0
BBR_TX_ALGORITHM=""
BBR_TX_QDISC=""
BBR_TX_SYSCTL_PRESENT=0
BBR_TX_SYSCTL_B64=""
BBR_TX_MODULES_PRESENT=0
BBR_TX_MODULES_B64=""
BBR_TX_ORIGINAL_PRESENT=0
BBR_TX_ORIGINAL_B64=""
BBR_TX_LIVE_QDISC_CAPTURED=0
BBR_TX_LIVE_INTERFACE=""
BBR_TX_LIVE_QDISC=""
BBR_ORIGINAL_LOADED=0
BBR_ORIGINAL_VERSION=""
BBR_ORIGINAL_LIVE_PRESENT=0
BBR_ORIGINAL_LIVE_INTERFACE=""
BBR_ORIGINAL_LIVE_QDISC=""

bbr_usage() {
    cat <<'EOF'
管理 TCP 拥塞控制算法与默认队列规则（qdisc）。

用法：
  bbr.sh [global-options] status
  bbr.sh [global-options] enable [--algorithm ALG] [--qdisc QDISC] [--apply-live-qdisc]
  bbr.sh [global-options] set --algorithm ALG --qdisc QDISC [--apply-live-qdisc]
  bbr.sh [global-options] restore

操作：
  status               显示当前内核状态和已保存的配置状态
  enable               启用配置，默认使用 bbr 与 fq
  set                  选择当前内核可用的 TCP 算法与默认 qdisc
  restore              恢复首次修改前保存的状态

选项：
  --algorithm ALG      指定当前内核列出的 TCP 算法
  --qdisc QDISC        指定默认 qdisc（例如 fq 或 fq_codel）
  --apply-live-qdisc   立即替换默认路由网卡的 root qdisc
  --dry-run            仅显示计划，不修改系统
  --yes                 自动同意普通确认提示
  --non-interactive    禁止从终端读取输入
  --quiet              隐藏非必要信息
  --verbose            显示更多诊断信息
  --no-color           禁用彩色输出
  --                    停止解析选项
  -h, --help           显示此帮助

本命令不会安装或切换内核，仅配置当前运行内核。持久化设置写入
/etc/sysctl.d/90-vpsctl-bbr.conf 和
/etc/modules-load.d/90-vpsctl-bbr.conf。立即替换 root qdisc 可能造成短暂网络波动。
EOF
}

bbr_die_usage() {
    vps_cmd_error "$1"
    return 2
}

bbr_require_linux() {
    [[ "${VPSCTL_TESTING:-0}" == "1" || "$(uname -s 2>/dev/null || true)" == "Linux" ]] && return 0
    vps_cmd_error "network bbr 仅支持 Linux"
    return 3
}

bbr_parse_args() {
    local positional=()

    : "${VPSCTL_DRY_RUN:=0}"
    : "${VPSCTL_ASSUME_YES:=0}"
    : "${VPSCTL_NON_INTERACTIVE:=0}"

    while (($# > 0)); do
        case "$1" in
            --dry-run)
                VPSCTL_DRY_RUN=1
                ;;
            --yes)
                VPSCTL_ASSUME_YES=1
                ;;
            --non-interactive)
                VPSCTL_NON_INTERACTIVE=1
                ;;
            --quiet)
                VPSCTL_QUIET=1
                ;;
            --verbose)
                VPSCTL_VERBOSE=1
                ;;
            --no-color)
                VPSCTL_NO_COLOR=1
                ;;
            -h | --help)
                BBR_ACTION="help"
                shift
                (($# == 0)) || bbr_die_usage "--help 不接受其他参数"
                return $?
                ;;
            --algorithm)
                (($# >= 2)) || {
                    bbr_die_usage "--algorithm 缺少参数值"
                    return $?
                }
                BBR_ALGORITHM="$2"
                shift
                ;;
            --qdisc)
                (($# >= 2)) || {
                    bbr_die_usage "--qdisc 缺少参数值"
                    return $?
                }
                BBR_QDISC="$2"
                shift
                ;;
            --apply-live-qdisc)
                BBR_APPLY_LIVE_QDISC=1
                ;;
            --)
                shift
                positional+=("$@")
                break
                ;;
            -*)
                bbr_die_usage "未知选项：$1"
                return $?
                ;;
            *)
                positional+=("$1")
                ;;
        esac
        shift
    done

    ((${#positional[@]} <= 1)) || {
        bbr_die_usage "多余参数：${positional[1]}"
        return $?
    }
    if ((${#positional[@]} == 1)); then
        BBR_ACTION="${positional[0]}"
    fi
}

bbr_validate_name() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]
}

bbr_proc_path() {
    local key="$1"
    printf '%s\n' "$(vps_cmd_system_path "/proc/sys/${key//./\/}")"
}

bbr_sysctl_read() {
    local key="$1"
    local path value

    path="$(bbr_proc_path "$key")"
    if [[ -r "$path" ]]; then
        value="$(<"$path")"
        vps_cmd_trim "$value"
        return 0
    fi
    if [[ "${VPSCTL_TESTING:-0}" == "1" ]]; then
        return 1
    fi
    command -v sysctl >/dev/null 2>&1 || return 1
    value="$(sysctl -n "$key" 2>/dev/null)" || return 1
    vps_cmd_trim "$value"
}

bbr_current_algorithm() {
    bbr_sysctl_read net.ipv4.tcp_congestion_control
}

bbr_current_qdisc() {
    bbr_sysctl_read net.core.default_qdisc
}

bbr_available_algorithms() {
    bbr_sysctl_read net.ipv4.tcp_available_congestion_control
}

bbr_algorithm_available() {
    local requested="$1"
    local available item
    local -a items=()

    available="$(bbr_available_algorithms)" || return 1
    IFS=' ' read -r -a items <<<"$available"
    for item in "${items[@]}"; do
        [[ "$item" == "$requested" ]] && return 0
    done
    return 1
}

bbr_status() {
    local algorithm algorithm_style qdisc qdisc_style available available_style
    local module_state module_style interface interface_style root_qdisc root_style

    algorithm="$(bbr_current_algorithm 2>/dev/null || printf '未知')"
    qdisc="$(bbr_current_qdisc 2>/dev/null || printf '未知')"
    available="$(bbr_available_algorithms 2>/dev/null || printf '未知')"
    algorithm_style="emphasis"
    qdisc_style="emphasis"
    available_style="info"
    [[ "$algorithm" != "未知" ]] || algorithm_style="error"
    [[ "$qdisc" != "未知" ]] || qdisc_style="error"
    [[ "$available" != "未知" ]] || available_style="warning"

    if [[ -d "$(vps_cmd_system_path /sys/module/tcp_bbr)" ]]; then
        module_state="已加载"
        module_style="success"
    elif bbr_algorithm_available bbr; then
        module_state="可用"
        module_style="info"
    else
        module_state="不可用"
        module_style="warning"
    fi
    interface="$(bbr_default_interface 2>/dev/null || printf '不可用')"
    interface_style="info"
    [[ "$interface" != "不可用" ]] || interface_style="warning"
    root_qdisc="不可用"
    root_style="warning"
    if [[ "$interface" != "不可用" ]] && command -v tc >/dev/null 2>&1; then
        root_qdisc="$(bbr_interface_root_qdisc "$interface" 2>/dev/null || printf '不可用')"
        [[ "$root_qdisc" == "不可用" ]] || root_style="emphasis"
    fi

    vps_cmd_status "当前拥塞控制算法" "$algorithm" "$algorithm_style"
    vps_cmd_status "默认 qdisc" "$qdisc" "$qdisc_style"
    vps_cmd_status "内核可用算法" "$available" "$available_style"
    vps_cmd_status "BBR 模块" "$module_state" "$module_style"
    vps_cmd_status "默认路由网卡" "$interface" "$interface_style"
    vps_cmd_status "网卡 root qdisc" "$root_qdisc" "$root_style"
    if [[ -f "$BBR_SYSCTL_FILE" ]]; then
        vps_cmd_status "sysctl 持久化配置" "已存在" success
    else
        vps_cmd_status "sysctl 持久化配置" "缺失" warning
    fi
    if [[ -f "$BBR_MODULES_FILE" ]]; then
        vps_cmd_status "modules-load 持久化配置" "已存在" success
    else
        vps_cmd_status "modules-load 持久化配置" "缺失" warning
    fi
    if [[ -f "$BBR_ORIGINAL_FILE" ]]; then
        vps_cmd_status "原始状态" "已保存" success
    else
        vps_cmd_status "原始状态" "未保存" warning
    fi
}

bbr_encode_file() {
    local path="$1"
    command -v base64 >/dev/null 2>&1 || return 3
    base64 -w 0 -- "$path"
}

bbr_atomic_write_path() {
    local physical_path="$1"
    local mode="$2"
    local logical_path="$physical_path"

    if [[ "${VPSCTL_TESTING:-0}" == "1" ]]; then
        logical_path="${physical_path#"$VPSCTL_SYSTEM_ROOT"}"
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        cat >/dev/null
        vps_cmd_info "演练：将以权限 ${mode} 原子写入 ${logical_path}"
        return 0
    fi
    vps_cmd_atomic_write "$logical_path" "$mode"
}

bbr_logical_path() {
    local physical_path="$1"

    if [[ "${VPSCTL_TESTING:-0}" == "1" ]]; then
        printf '%s\n' "${physical_path#"$VPSCTL_SYSTEM_ROOT"}"
    else
        printf '%s\n' "$physical_path"
    fi
}

bbr_file_has_managed_marker() {
    local path="$1"
    local line

    [[ -f "$path" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "$BBR_MANAGED_MARKER" ]] && return 0
    done <"$path"
    return 1
}

bbr_file_matches_snapshot() {
    local path="$1"
    local expected_present="$2"
    local expected_b64="$3"
    local actual_b64

    if [[ "$expected_present" == "0" ]]; then
        [[ ! -e "$path" && ! -L "$path" ]]
        return $?
    fi
    [[ "$expected_present" == "1" && -f "$path" && ! -L "$path" ]] || return 1
    actual_b64="$(bbr_encode_file "$path")" || return $?
    [[ "$actual_b64" == "$expected_b64" ]]
}

bbr_file_matches_saved_original() {
    local path="$1"

    [[ "$BBR_ORIGINAL_LOADED" == "1" ]] || return 1
    case "$path" in
        "$BBR_SYSCTL_FILE")
            bbr_file_matches_snapshot "$path" "$BBR_ORIGINAL_SYSCTL_PRESENT" "$BBR_ORIGINAL_SYSCTL_B64"
            ;;
        "$BBR_MODULES_FILE")
            bbr_file_matches_snapshot "$path" "$BBR_ORIGINAL_MODULES_PRESENT" "$BBR_ORIGINAL_MODULES_B64"
            ;;
        *)
            return 1
            ;;
    esac
}

bbr_file_is_unmanaged() {
    local path="$1"

    [[ -e "$path" || -L "$path" ]] || return 1
    bbr_file_has_managed_marker "$path" && return 1
    bbr_file_matches_saved_original "$path" && return 1
    return 0
}

bbr_has_unmanaged_persistence() {
    local path

    for path in "$BBR_SYSCTL_FILE" "$BBR_MODULES_FILE"; do
        if bbr_file_is_unmanaged "$path"; then
            return 0
        fi
    done
    return 1
}

bbr_backup_unmanaged_persistence() {
    local path logical_path

    for path in "$BBR_SYSCTL_FILE" "$BBR_MODULES_FILE"; do
        if bbr_file_is_unmanaged "$path" && [[ -f "$path" && ! -L "$path" ]]; then
            logical_path="$(bbr_logical_path "$path")"
            if [[ "$VPSCTL_DRY_RUN" == "1" ]]; then
                vps_cmd_info "演练：覆盖前将备份未受管文件 ${logical_path}"
            else
                vps_cmd_backup_file bbr "$logical_path" >/dev/null || return $?
            fi
        fi
    done
}

bbr_validate_restore_ownership() {
    local path logical_path

    for path in "$BBR_SYSCTL_FILE" "$BBR_MODULES_FILE"; do
        if bbr_file_is_unmanaged "$path"; then
            logical_path="$(bbr_logical_path "$path")"
            vps_cmd_error "文件已不再由 vpsctl 管理，拒绝覆盖恢复：${logical_path}"
            return 3
        fi
    done
}

bbr_snapshot_file() {
    local path="$1"
    local present_name="$2"
    local content_name="$3"
    local encoded=""

    if [[ -f "$path" ]]; then
        encoded="$(bbr_encode_file "$path")" || return $?
        printf -v "$present_name" '%s' 1
        printf -v "$content_name" '%s' "$encoded"
    else
        printf -v "$present_name" '%s' 0
        printf -v "$content_name" '%s' ""
    fi
}

bbr_restore_file_snapshot() {
    local path="$1"
    local mode="$2"
    local present="$3"
    local encoded="$4"

    if [[ "$present" == "1" ]]; then
        printf '%s' "$encoded" | base64 -d | bbr_atomic_write_path "$path" "$mode"
    else
        vps_cmd_run rm -f -- "$path"
    fi
}

bbr_begin_transaction() {
    BBR_TX_ROLLBACK_NEEDED=0
    BBR_TX_LIVE_QDISC_CAPTURED=0
    BBR_TX_LIVE_INTERFACE=""
    BBR_TX_LIVE_QDISC=""
    BBR_TX_ALGORITHM="$(bbr_current_algorithm)" || {
        vps_cmd_error "无法读取当前 TCP 拥塞控制算法"
        return 3
    }
    BBR_TX_QDISC="$(bbr_current_qdisc)" || {
        vps_cmd_error "无法读取当前默认 qdisc"
        return 3
    }
    bbr_snapshot_file "$BBR_SYSCTL_FILE" BBR_TX_SYSCTL_PRESENT BBR_TX_SYSCTL_B64 || return $?
    bbr_snapshot_file "$BBR_MODULES_FILE" BBR_TX_MODULES_PRESENT BBR_TX_MODULES_B64 || return $?
    bbr_snapshot_file "$BBR_ORIGINAL_FILE" BBR_TX_ORIGINAL_PRESENT BBR_TX_ORIGINAL_B64 || return $?
    BBR_TX_ACTIVE=1
}

bbr_mark_transaction_dirty() {
    [[ "$BBR_TX_ACTIVE" == "1" ]] || return 70
    # Loaded kernel modules can be shared by other users and are intentionally
    # not unloaded on rollback. Mark only before changing vpsctl-managed files
    # or sysctl/qdisc state; dry-run never creates state that needs restoring.
    [[ "$VPSCTL_DRY_RUN" == "1" ]] || BBR_TX_ROLLBACK_NEEDED=1
}

bbr_rollback() {
    local failed=0

    [[ "$BBR_TX_ACTIVE" == "1" && "$BBR_TX_ROLLBACK_NEEDED" == "1" ]] || return 0
    vps_cmd_warning "变更失败，正在恢复此前的运行状态和文件"
    bbr_restore_file_snapshot "$BBR_SYSCTL_FILE" 0644 "$BBR_TX_SYSCTL_PRESENT" "$BBR_TX_SYSCTL_B64" || failed=1
    bbr_restore_file_snapshot "$BBR_MODULES_FILE" 0644 "$BBR_TX_MODULES_PRESENT" "$BBR_TX_MODULES_B64" || failed=1
    bbr_restore_file_snapshot "$BBR_ORIGINAL_FILE" 0600 "$BBR_TX_ORIGINAL_PRESENT" "$BBR_TX_ORIGINAL_B64" || failed=1
    vps_cmd_run sysctl -w "net.ipv4.tcp_congestion_control=${BBR_TX_ALGORITHM}" >/dev/null || failed=1
    vps_cmd_run sysctl -w "net.core.default_qdisc=${BBR_TX_QDISC}" >/dev/null || failed=1
    if [[ "$BBR_TX_LIVE_QDISC_CAPTURED" == "1" ]]; then
        vps_cmd_run tc qdisc replace dev "$BBR_TX_LIVE_INTERFACE" root "$BBR_TX_LIVE_QDISC" || failed=1
    fi
    BBR_TX_ACTIVE=0
    BBR_TX_ROLLBACK_NEEDED=0
    ((failed == 0))
}

bbr_write_original_record() {
    local algorithm="$1"
    local qdisc="$2"
    local sysctl_present="$3"
    local sysctl_b64="$4"
    local modules_present="$5"
    local modules_b64="$6"
    local live_present="$7"
    local live_interface="$8"
    local live_qdisc="$9"

    {
        printf 'version=2\n'
        printf 'algorithm=%s\n' "$algorithm"
        printf 'qdisc=%s\n' "$qdisc"
        printf 'sysctl_present=%s\n' "$sysctl_present"
        printf 'sysctl_b64=%s\n' "$sysctl_b64"
        printf 'modules_present=%s\n' "$modules_present"
        printf 'modules_b64=%s\n' "$modules_b64"
        printf 'live_present=%s\n' "$live_present"
        printf 'live_interface=%s\n' "$live_interface"
        printf 'live_qdisc=%s\n' "$live_qdisc"
    } | bbr_atomic_write_path "$BBR_ORIGINAL_FILE" 0600
}

bbr_save_original() {
    local sysctl_present modules_present sysctl_b64 modules_b64

    [[ ! -e "$BBR_ORIGINAL_FILE" ]] || return 0
    bbr_snapshot_file "$BBR_SYSCTL_FILE" sysctl_present sysctl_b64 || return $?
    bbr_snapshot_file "$BBR_MODULES_FILE" modules_present modules_b64 || return $?
    bbr_write_original_record \
        "$BBR_TX_ALGORITHM" "$BBR_TX_QDISC" \
        "$sysctl_present" "$sysctl_b64" \
        "$modules_present" "$modules_b64" \
        "$BBR_TX_LIVE_QDISC_CAPTURED" "$BBR_TX_LIVE_INTERFACE" "$BBR_TX_LIVE_QDISC"
}

bbr_extend_original_live_snapshot() {
    [[ "$BBR_ORIGINAL_LOADED" == "1" ]] || return 70
    [[ "$BBR_ORIGINAL_LIVE_PRESENT" == "0" ]] || return 0
    [[ "$BBR_TX_LIVE_QDISC_CAPTURED" == "1" ]] || return 0

    bbr_write_original_record \
        "$BBR_ORIGINAL_ALGORITHM" "$BBR_ORIGINAL_QDISC" \
        "$BBR_ORIGINAL_SYSCTL_PRESENT" "$BBR_ORIGINAL_SYSCTL_B64" \
        "$BBR_ORIGINAL_MODULES_PRESENT" "$BBR_ORIGINAL_MODULES_B64" \
        1 "$BBR_TX_LIVE_INTERFACE" "$BBR_TX_LIVE_QDISC" || return $?
    BBR_ORIGINAL_VERSION=2
    BBR_ORIGINAL_LIVE_PRESENT=1
    BBR_ORIGINAL_LIVE_INTERFACE="$BBR_TX_LIVE_INTERFACE"
    BBR_ORIGINAL_LIVE_QDISC="$BBR_TX_LIVE_QDISC"
}

bbr_validate_base64() {
    local value="$1"

    command -v base64 >/dev/null 2>&1 || return 3
    printf '%s' "$value" | base64 -d >/dev/null 2>&1
}

bbr_validate_interface_name() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:@-]{0,14}$ ]]
}

bbr_load_original() {
    local line key value required
    local -A seen=()

    BBR_ORIGINAL_LOADED=0
    BBR_ORIGINAL_VERSION=""
    BBR_ORIGINAL_ALGORITHM=""
    BBR_ORIGINAL_QDISC=""
    BBR_ORIGINAL_SYSCTL_PRESENT=""
    BBR_ORIGINAL_SYSCTL_B64=""
    BBR_ORIGINAL_MODULES_PRESENT=""
    BBR_ORIGINAL_MODULES_B64=""
    BBR_ORIGINAL_LIVE_PRESENT=0
    BBR_ORIGINAL_LIVE_INTERFACE=""
    BBR_ORIGINAL_LIVE_QDISC=""

    [[ -r "$BBR_ORIGINAL_FILE" ]] || {
        vps_cmd_error "尚未保存原始状态"
        return 3
    }
    while IFS= read -r line; do
        [[ "$line" == *=* ]] || {
            vps_cmd_error "已保存的原始状态含有格式错误的行"
            return 10
        }
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            version | algorithm | qdisc | sysctl_present | sysctl_b64 | modules_present | modules_b64 | live_present | live_interface | live_qdisc) ;;
            *)
                vps_cmd_error "已保存的原始状态含有未知键：${key}"
                return 10
                ;;
        esac
        [[ -z "${seen[$key]+x}" ]] || {
            vps_cmd_error "已保存的原始状态含有重复键：${key}"
            return 10
        }
        seen["$key"]=1
        case "$key" in
            version) BBR_ORIGINAL_VERSION="$value" ;;
            algorithm) BBR_ORIGINAL_ALGORITHM="$value" ;;
            qdisc) BBR_ORIGINAL_QDISC="$value" ;;
            sysctl_present) BBR_ORIGINAL_SYSCTL_PRESENT="$value" ;;
            sysctl_b64) BBR_ORIGINAL_SYSCTL_B64="$value" ;;
            modules_present) BBR_ORIGINAL_MODULES_PRESENT="$value" ;;
            modules_b64) BBR_ORIGINAL_MODULES_B64="$value" ;;
            live_present) BBR_ORIGINAL_LIVE_PRESENT="$value" ;;
            live_interface) BBR_ORIGINAL_LIVE_INTERFACE="$value" ;;
            live_qdisc) BBR_ORIGINAL_LIVE_QDISC="$value" ;;
        esac
    done <"$BBR_ORIGINAL_FILE"

    for required in version algorithm qdisc sysctl_present sysctl_b64 modules_present modules_b64; do
        [[ -n "${seen[$required]+x}" ]] || {
            vps_cmd_error "已保存的原始状态缺少键：${required}"
            return 10
        }
    done
    [[ "$BBR_ORIGINAL_VERSION" == "1" || "$BBR_ORIGINAL_VERSION" == "2" ]] || {
        vps_cmd_error "已保存的原始状态格式版本不受支持"
        return 10
    }
    if [[ "$BBR_ORIGINAL_VERSION" == "1" ]]; then
        for required in live_present live_interface live_qdisc; do
            [[ -z "${seen[$required]+x}" ]] || {
                vps_cmd_error "version=1 的原始状态不能包含 live qdisc 键"
                return 10
            }
        done
        BBR_ORIGINAL_LIVE_PRESENT=0
        BBR_ORIGINAL_LIVE_INTERFACE=""
        BBR_ORIGINAL_LIVE_QDISC=""
    else
        for required in live_present live_interface live_qdisc; do
            [[ -n "${seen[$required]+x}" ]] || {
                vps_cmd_error "已保存的原始状态缺少键：${required}"
                return 10
            }
        done
    fi
    bbr_validate_name "$BBR_ORIGINAL_ALGORITHM" && bbr_validate_name "$BBR_ORIGINAL_QDISC" || {
        vps_cmd_error "已保存的原始状态含有无效内核设置"
        return 10
    }
    [[ "$BBR_ORIGINAL_SYSCTL_PRESENT" =~ ^[01]$ && "$BBR_ORIGINAL_MODULES_PRESENT" =~ ^[01]$ ]] || {
        vps_cmd_error "已保存的原始状态含有无效文件元数据"
        return 10
    }
    bbr_validate_base64 "$BBR_ORIGINAL_SYSCTL_B64" && bbr_validate_base64 "$BBR_ORIGINAL_MODULES_B64" || {
        vps_cmd_error "已保存的原始状态含有无效 base64 数据"
        return 10
    }
    if [[ "$BBR_ORIGINAL_SYSCTL_PRESENT" == "0" && -n "$BBR_ORIGINAL_SYSCTL_B64" ]] ||
        [[ "$BBR_ORIGINAL_MODULES_PRESENT" == "0" && -n "$BBR_ORIGINAL_MODULES_B64" ]]; then
        vps_cmd_error "已保存的原始状态为缺失文件记录了内容"
        return 10
    fi
    [[ "$BBR_ORIGINAL_LIVE_PRESENT" =~ ^[01]$ ]] || {
        vps_cmd_error "已保存的原始状态含有无效 live qdisc 元数据"
        return 10
    }
    if [[ "$BBR_ORIGINAL_LIVE_PRESENT" == "1" ]]; then
        bbr_validate_interface_name "$BBR_ORIGINAL_LIVE_INTERFACE" && bbr_validate_name "$BBR_ORIGINAL_LIVE_QDISC" || {
            vps_cmd_error "已保存的原始状态含有无效 live qdisc 值"
            return 10
        }
    elif [[ -n "$BBR_ORIGINAL_LIVE_INTERFACE" || -n "$BBR_ORIGINAL_LIVE_QDISC" ]]; then
        vps_cmd_error "已保存的原始状态为缺失的 live qdisc 快照记录了值"
        return 10
    fi
    BBR_ORIGINAL_LOADED=1
}

bbr_persistence_matches_saved_original() {
    [[ "$BBR_ORIGINAL_LOADED" == "1" ]] || return 1
    bbr_file_matches_saved_original "$BBR_SYSCTL_FILE" || return 1
    bbr_file_matches_saved_original "$BBR_MODULES_FILE"
}

bbr_runtime_matches_saved_original() {
    local algorithm qdisc

    algorithm="$(bbr_current_algorithm)" || return 1
    qdisc="$(bbr_current_qdisc)" || return 1
    [[ "$algorithm" == "$BBR_ORIGINAL_ALGORITHM" && "$qdisc" == "$BBR_ORIGINAL_QDISC" ]]
}

bbr_live_matches_saved_original() {
    local current_qdisc

    [[ "$BBR_ORIGINAL_LIVE_PRESENT" == "1" ]] || return 0
    command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1 || return 1
    ip link show dev "$BBR_ORIGINAL_LIVE_INTERFACE" >/dev/null 2>&1 || return 1
    current_qdisc="$(bbr_interface_root_qdisc "$BBR_ORIGINAL_LIVE_INTERFACE")" || return 1
    [[ "$current_qdisc" == "$BBR_ORIGINAL_LIVE_QDISC" ]]
}

bbr_load_algorithm_module() {
    local algorithm="$1"

    bbr_algorithm_available "$algorithm" && return 0
    if [[ "$algorithm" != "bbr" ]]; then
        vps_cmd_error "当前运行内核不可用 TCP 算法：${algorithm}"
        return 3
    fi
    command -v modprobe >/dev/null 2>&1 || {
        vps_cmd_error "bbr 不可用，且系统未安装 modprobe"
        return 3
    }
    vps_cmd_run modprobe tcp_bbr || {
        vps_cmd_error "加载 tcp_bbr 失败"
        return 20
    }
    if [[ "$VPSCTL_DRY_RUN" == "1" ]]; then
        vps_cmd_info "演练模式无法在加载 tcp_bbr 后重新检查算法"
        return 0
    fi
    bbr_algorithm_available "$algorithm" || {
        vps_cmd_error "加载 tcp_bbr 后 TCP 算法仍不可用：${algorithm}"
        return 3
    }
}

bbr_prepare_qdisc() {
    local qdisc="$1"

    command -v modprobe >/dev/null 2>&1 || return 0
    if ! vps_cmd_run modprobe "sch_${qdisc}"; then
        vps_cmd_verbose "sch_${qdisc} 可能已内置或不可用，将以 sysctl 校验结果为准"
    fi
}

bbr_write_managed_files() {
    local algorithm="$1"
    local qdisc="$2"

    {
        printf '%s\n' "$BBR_MANAGED_MARKER"
        printf 'net.ipv4.tcp_congestion_control = %s\n' "$algorithm"
        printf 'net.core.default_qdisc = %s\n' "$qdisc"
    } | bbr_atomic_write_path "$BBR_SYSCTL_FILE" 0644 || return $?

    {
        printf '%s\n' "$BBR_MANAGED_MARKER"
        [[ "$algorithm" == "bbr" ]] && printf 'tcp_bbr\n'
        printf 'sch_%s\n' "$qdisc"
    } | bbr_atomic_write_path "$BBR_MODULES_FILE" 0644
}

bbr_prepare_directories() {
    local directory

    for directory in "${BBR_SYSCTL_FILE%/*}" "${BBR_MODULES_FILE%/*}" "${BBR_ORIGINAL_FILE%/*}"; do
        bbr_require_safe_system_path "$directory" || return $?
        vps_cmd_run mkdir -p -- "$directory" || return 20
    done
    vps_cmd_run chmod 0700 -- "${BBR_ORIGINAL_FILE%/*}" || return 20
}

bbr_validate_managed_paths() {
    local path

    for path in "$BBR_SYSCTL_FILE" "$BBR_MODULES_FILE" "$BBR_ORIGINAL_FILE"; do
        bbr_require_safe_system_path "$path" || return $?
    done
}

bbr_require_safe_system_path() {
    local path="$1"
    local status

    if vps_cmd_require_no_symlink_components "$path" 2>/dev/null; then
        return 0
    else
        status=$?
    fi
    vps_cmd_error "系统路径包含符号链接，拒绝继续：$(bbr_logical_path "$path")"
    return "$status"
}

bbr_apply_runtime() {
    local algorithm="$1"
    local qdisc="$2"
    local actual

    vps_cmd_run sysctl -w "net.ipv4.tcp_congestion_control=${algorithm}" >/dev/null || return 20
    vps_cmd_run sysctl -w "net.core.default_qdisc=${qdisc}" >/dev/null || return 20
    [[ "$VPSCTL_DRY_RUN" == "1" ]] && return 0

    actual="$(bbr_current_algorithm)" || return 20
    [[ "$actual" == "$algorithm" ]] || return 20
    actual="$(bbr_current_qdisc)" || return 20
    [[ "$actual" == "$qdisc" ]] || return 20
}

bbr_default_interface() {
    local output token expect_device=0
    local -a tokens=()

    command -v ip >/dev/null 2>&1 || return 3
    output="$(ip route show default 2>/dev/null)" || return 3
    output="${output%%$'\n'*}"
    IFS=' ' read -r -a tokens <<<"$output"
    for token in "${tokens[@]}"; do
        if ((expect_device)); then
            printf '%s\n' "$token"
            return 0
        fi
        [[ "$token" == "dev" ]] && expect_device=1
    done
    return 3
}

bbr_interface_root_qdisc() {
    local interface="$1"
    local line token previous qdisc_name is_root
    local -a tokens=()

    while IFS= read -r line; do
        previous=""
        qdisc_name=""
        is_root=0
        IFS=' ' read -r -a tokens <<<"$line"
        for token in "${tokens[@]}"; do
            [[ "$previous" == "qdisc" ]] && qdisc_name="$token"
            [[ "$token" == "root" ]] && is_root=1
            previous="$token"
        done
        if ((is_root)) && [[ -n "$qdisc_name" ]]; then
            printf '%s\n' "$qdisc_name"
            return 0
        fi
    done < <(tc qdisc show dev "$interface" 2>/dev/null)
    return 1
}

bbr_capture_live_qdisc() {
    command -v tc >/dev/null 2>&1 || {
        vps_cmd_error "--apply-live-qdisc 需要 tc"
        return 3
    }
    BBR_TX_LIVE_INTERFACE="$(bbr_default_interface)" || {
        vps_cmd_error "无法确定默认路由网卡"
        return 3
    }
    BBR_TX_LIVE_QDISC="$(bbr_interface_root_qdisc "$BBR_TX_LIVE_INTERFACE")" || {
        vps_cmd_error "无法读取 ${BBR_TX_LIVE_INTERFACE} 当前的 root qdisc"
        return 3
    }
    bbr_validate_name "$BBR_TX_LIVE_QDISC" || {
        vps_cmd_error "当前 root qdisc 类型不安全：${BBR_TX_LIVE_QDISC}"
        return 3
    }
    BBR_TX_LIVE_QDISC_CAPTURED=1
}

bbr_apply_live_qdisc() {
    local qdisc="$1"

    [[ "$BBR_TX_LIVE_QDISC_CAPTURED" == "1" ]] || {
        vps_cmd_error "替换前未记录 live qdisc 状态"
        return 70
    }
    vps_cmd_run tc qdisc replace dev "$BBR_TX_LIVE_INTERFACE" root "$qdisc"
}

bbr_restore_saved_live_qdisc() {
    [[ "$BBR_ORIGINAL_LIVE_PRESENT" == "1" ]] || return 0
    command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1 || {
        vps_cmd_error "ip 或 tc 不可用，无法恢复已保存的 live qdisc"
        return 20
    }
    ip link show dev "$BBR_ORIGINAL_LIVE_INTERFACE" >/dev/null 2>&1 || {
        vps_cmd_error "网卡已消失，无法恢复已保存的 live qdisc：${BBR_ORIGINAL_LIVE_INTERFACE}"
        return 20
    }
    vps_cmd_run tc qdisc replace dev "$BBR_ORIGINAL_LIVE_INTERFACE" root "$BBR_ORIGINAL_LIVE_QDISC" || {
        vps_cmd_error "无法将 ${BBR_ORIGINAL_LIVE_INTERFACE} 的 root qdisc 恢复为 ${BBR_ORIGINAL_LIVE_QDISC}"
        return 20
    }
}

bbr_apply_settings() {
    local algorithm="$1"
    local qdisc="$2"
    local status=0
    local locked=0
    local unmanaged_confirmed=0

    vps_cmd_require_root || return $?
    bbr_validate_name "$algorithm" || {
        vps_cmd_error "TCP 算法名称无效：${algorithm}"
        return 10
    }
    bbr_validate_name "$qdisc" || {
        vps_cmd_error "qdisc 名称无效：${qdisc}"
        return 10
    }
    if [[ -e "$BBR_ORIGINAL_FILE" ]]; then
        bbr_load_original || return $?
    else
        BBR_ORIGINAL_LOADED=0
    fi
    if bbr_has_unmanaged_persistence; then
        vps_cmd_warning "检测到未受管的 vpsctl BBR 持久化文件，将先备份再覆盖"
        if vps_cmd_confirm "是否备份并覆盖现有 BBR 持久化文件？"; then
            unmanaged_confirmed=1
        else
            status=$?
            if ((status == 1)); then
                vps_cmd_info "未进行任何更改"
                return 0
            fi
            return "$status"
        fi
    fi
    if vps_cmd_confirm "是否应用 TCP 算法 '${algorithm}' 和默认 qdisc '${qdisc}'？"; then
        :
    else
        status=$?
        if ((status == 1)); then
            vps_cmd_info "未进行任何更改"
            return 0
        fi
        return "$status"
    fi
    if [[ "$VPSCTL_DRY_RUN" != "1" ]]; then
        vps_cmd_lock network-bbr || return $?
        locked=1
    fi
    bbr_validate_managed_paths || status=$?
    if ((status == 0)); then
        if [[ -e "$BBR_ORIGINAL_FILE" ]]; then
            bbr_load_original || status=$?
        else
            BBR_ORIGINAL_LOADED=0
        fi
    fi
    if ((status == 0)) && bbr_has_unmanaged_persistence; then
        if ((unmanaged_confirmed == 0)); then
            vps_cmd_error "确认后出现未受管持久化文件，请重新执行操作"
            status=3
        else
            bbr_backup_unmanaged_persistence || status=$?
        fi
    fi
    ((status != 0)) || bbr_begin_transaction || status=$?
    ((status != 0)) || bbr_load_algorithm_module "$algorithm" || status=$?
    ((status != 0)) || bbr_prepare_qdisc "$qdisc" || status=$?
    if ((status == 0)) && [[ "$BBR_APPLY_LIVE_QDISC" == "1" ]]; then
        bbr_capture_live_qdisc || status=$?
    fi
    ((status != 0)) || bbr_mark_transaction_dirty || status=$?
    ((status != 0)) || bbr_prepare_directories || status=$?
    ((status != 0)) || bbr_save_original || status=$?
    if ((status == 0)) && [[ "$BBR_APPLY_LIVE_QDISC" == "1" && "$BBR_ORIGINAL_LOADED" == "1" ]]; then
        bbr_extend_original_live_snapshot || status=$?
    fi
    ((status != 0)) || bbr_write_managed_files "$algorithm" "$qdisc" || status=$?
    if ((status == 0)); then
        if bbr_apply_runtime "$algorithm" "$qdisc"; then
            :
        else
            status=$?
            vps_cmd_error "应用或校验运行时 sysctl 设置失败"
        fi
    fi
    if ((status == 0)) && [[ "$BBR_APPLY_LIVE_QDISC" == "1" ]]; then
        bbr_apply_live_qdisc "$qdisc" || status=$?
    fi

    if ((status != 0)) && [[ "$BBR_TX_ROLLBACK_NEEDED" == "1" ]]; then
        bbr_rollback || status=30
    fi
    BBR_TX_ACTIVE=0
    BBR_TX_ROLLBACK_NEEDED=0
    ((locked == 0)) || vps_cmd_unlock
    ((status == 0)) || return "$status"
    vps_cmd_success "已应用 TCP 算法 ${algorithm}，默认 qdisc 为 ${qdisc}"
}

bbr_restore() {
    local status=0
    local locked=0
    local partial_status=0

    vps_cmd_require_root || return $?
    bbr_load_original || return $?
    bbr_validate_managed_paths || return $?
    bbr_validate_restore_ownership || return $?
    if bbr_persistence_matches_saved_original && bbr_runtime_matches_saved_original && bbr_live_matches_saved_original; then
        vps_cmd_success "TCP、qdisc 和持久化配置已处于原始状态"
        return 0
    fi
    if vps_cmd_confirm "是否恢复首次保存的 TCP 与 qdisc 状态？"; then
        :
    else
        status=$?
        if ((status == 1)); then
            vps_cmd_info "未进行任何更改"
            return 0
        fi
        return "$status"
    fi

    if [[ "$VPSCTL_DRY_RUN" != "1" ]]; then
        vps_cmd_lock network-bbr || return $?
        locked=1
    fi
    bbr_validate_managed_paths || status=$?
    ((status != 0)) || bbr_validate_restore_ownership || status=$?
    ((status != 0)) || bbr_begin_transaction || status=$?
    ((status != 0)) || bbr_load_algorithm_module "$BBR_ORIGINAL_ALGORITHM" || status=$?
    ((status != 0)) || bbr_prepare_qdisc "$BBR_ORIGINAL_QDISC" || status=$?
    ((status != 0)) || bbr_mark_transaction_dirty || status=$?
    ((status != 0)) || bbr_prepare_directories || status=$?
    ((status != 0)) || bbr_restore_file_snapshot "$BBR_SYSCTL_FILE" 0644 "$BBR_ORIGINAL_SYSCTL_PRESENT" "$BBR_ORIGINAL_SYSCTL_B64" || status=$?
    ((status != 0)) || bbr_restore_file_snapshot "$BBR_MODULES_FILE" 0644 "$BBR_ORIGINAL_MODULES_PRESENT" "$BBR_ORIGINAL_MODULES_B64" || status=$?
    if ((status == 0)); then
        if bbr_apply_runtime "$BBR_ORIGINAL_ALGORITHM" "$BBR_ORIGINAL_QDISC"; then
            :
        else
            status=$?
            vps_cmd_error "恢复或校验运行时 sysctl 设置失败"
        fi
    fi

    if ((status != 0)) && [[ "$BBR_TX_ROLLBACK_NEEDED" == "1" ]]; then
        bbr_rollback || status=30
    fi
    BBR_TX_ACTIVE=0
    BBR_TX_ROLLBACK_NEEDED=0
    if ((status == 0)) && [[ "$BBR_ORIGINAL_LIVE_PRESENT" == "1" ]]; then
        bbr_restore_saved_live_qdisc || partial_status=30
    fi
    ((locked == 0)) || vps_cmd_unlock
    ((status == 0)) || return "$status"
    ((partial_status == 0)) || return "$partial_status"
    vps_cmd_success "已恢复 TCP 算法 ${BBR_ORIGINAL_ALGORITHM} 和 qdisc ${BBR_ORIGINAL_QDISC}"
}

bbr_interactive_menu() {
    local choice algorithm qdisc confirm_status

    while true; do
        printf '\nBBR 网络管理\n'
        printf '  1) 查看状态\n'
        printf '  2) 启用 BBR + fq\n'
        printf '  3) 自定义算法和 qdisc\n'
        printf '  4) 恢复原始状态\n'
        printf '  q) 退出\n'
        printf '请选择：'
        IFS= read -r choice || return 0
        case "$choice" in
            1)
                bbr_status || true
                ;;
            2)
                BBR_APPLY_LIVE_QDISC=0
                if vps_cmd_confirm "是否立即替换默认路由网卡的 root qdisc？"; then
                    BBR_APPLY_LIVE_QDISC=1
                else
                    confirm_status=$?
                    ((confirm_status == 1)) || return "$confirm_status"
                fi
                bbr_apply_settings bbr fq || true
                ;;
            3)
                printf 'TCP 算法：'
                IFS= read -r algorithm || return 130
                printf '默认 qdisc：'
                IFS= read -r qdisc || return 130
                BBR_APPLY_LIVE_QDISC=0
                if vps_cmd_confirm "是否立即替换默认路由网卡的 root qdisc？"; then
                    BBR_APPLY_LIVE_QDISC=1
                else
                    confirm_status=$?
                    ((confirm_status == 1)) || return "$confirm_status"
                fi
                bbr_apply_settings "$algorithm" "$qdisc" || true
                ;;
            4)
                bbr_restore || true
                ;;
            q | Q | '')
                return 0
                ;;
            *)
                vps_cmd_warning "未知菜单选项：${choice}"
                ;;
        esac
    done
}

bbr_main() {
    local init_status

    if vps_cmd_init network-bbr "$BBR_PROJECT_ROOT"; then
        :
    else
        init_status=$?
        return "$init_status"
    fi
    BBR_SYSCTL_FILE="$(vps_cmd_system_path /etc/sysctl.d/90-vpsctl-bbr.conf)"
    BBR_MODULES_FILE="$(vps_cmd_system_path /etc/modules-load.d/90-vpsctl-bbr.conf)"
    BBR_ORIGINAL_FILE="$(vps_cmd_system_path /var/lib/vpsctl/network/bbr/original.conf)"

    bbr_parse_args "$@" || return $?
    if [[ "$BBR_ACTION" == "help" ]]; then
        bbr_usage
        return 0
    fi
    bbr_require_linux || return $?
    if [[ -z "$BBR_ACTION" ]]; then
        if vps_cmd_is_interactive; then
            bbr_interactive_menu
        else
            bbr_status
        fi
        return $?
    fi

    case "$BBR_ACTION" in
        status)
            [[ -z "$BBR_ALGORITHM" && -z "$BBR_QDISC" && "$BBR_APPLY_LIVE_QDISC" == "0" ]] || {
                bbr_die_usage "status 不接受设置选项"
                return $?
            }
            bbr_status
            ;;
        enable)
            bbr_apply_settings "${BBR_ALGORITHM:-bbr}" "${BBR_QDISC:-fq}"
            ;;
        set)
            [[ -n "$BBR_ALGORITHM" ]] || {
                bbr_die_usage "set 需要 --algorithm"
                return $?
            }
            [[ -n "$BBR_QDISC" ]] || {
                bbr_die_usage "set 需要 --qdisc"
                return $?
            }
            bbr_apply_settings "$BBR_ALGORITHM" "$BBR_QDISC"
            ;;
        restore)
            [[ -z "$BBR_ALGORITHM" && -z "$BBR_QDISC" && "$BBR_APPLY_LIVE_QDISC" == "0" ]] || {
                bbr_die_usage "restore 不接受设置选项"
                return $?
            }
            bbr_restore
            ;;
        *)
            bbr_die_usage "未知操作：${BBR_ACTION}"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    bbr_main "$@"
fi
