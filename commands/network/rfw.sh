#!/usr/bin/env bash
# Global CLI flags are consumed by the sourced command helper library.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

rfw_project_root() {
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P
}

RFW_PROJECT_ROOT="$(rfw_project_root)"
readonly RFW_PROJECT_ROOT
# shellcheck source=../../lib/command.sh
source "${RFW_PROJECT_ROOT}/lib/command.sh"
vps_cmd_init rfw "$RFW_PROJECT_ROOT"
: "${VPSCTL_INSTALL_DEPS:=0}"

# Keep all path mapping, mutation execution, locking, backups, and token prompts
# behind lib/command.sh's public API.  These tiny adapters accept already-mapped
# paths because this command also needs to inspect them directly.
system_path() { vps_cmd_system_path "$@"; }
run() { vps_cmd_run "$@"; }
lock() { vps_cmd_lock "$@"; }
unlock() { vps_cmd_unlock "$@"; }
confirm_token() { vps_cmd_confirm_token "$@"; }
rfw_logical_path() {
    local path="$1"
    if [[ "${VPSCTL_TESTING:-0}" == "1" && "$path" == "${VPSCTL_SYSTEM_ROOT}"/* ]]; then
        printf '/%s\n' "${path#"${VPSCTL_SYSTEM_ROOT}"/}"
    else
        printf '%s\n' "$path"
    fi
}
atomic_write() {
    local logical
    logical="$(rfw_logical_path "$1")" || return
    vps_cmd_atomic_write "$logical" "$2"
}
backup_file() {
    local feature="$1" logical
    logical="$(rfw_logical_path "$2")" || return
    vps_cmd_backup_file "$feature" "$logical"
}

readonly RFW_REPOSITORY="narwhal-cloud/rfw"
readonly RFW_RELEASE_API="https://api.github.com/repos/${RFW_REPOSITORY}/releases/latest"
readonly RFW_MANAGED_MARKER="# Managed by vpsctl (rfw)"
readonly RFW_PORT_ACCESS_PIN_LOGICAL="/sys/fs/bpf/rfw_port_access_log"
RFW_BINARY="$(system_path /usr/local/bin/rfw)"
RFW_CONFIG="$(system_path /etc/vpsctl/rfw.conf)"
RFW_UNIT="$(system_path /etc/systemd/system/rfw.service)"
RFW_STATE_DIR="$(system_path /var/lib/vpsctl/network/rfw)"
RFW_PORT_ACCESS_PIN="$(system_path "$RFW_PORT_ACCESS_PIN_LOGICAL")"
readonly RFW_BINARY RFW_CONFIG RFW_UNIT RFW_STATE_DIR RFW_PORT_ACCESS_PIN
readonly RFW_PENDING="${RFW_STATE_DIR}/pending"
readonly RFW_LKG_CONFIG="${RFW_STATE_DIR}/rfw.conf.last-known-good"
readonly RFW_METADATA="${RFW_STATE_DIR}/install.meta"
RFW_BACKUP_ROOT="$(system_path /var/lib/vpsctl/backups/network/rfw)"
readonly RFW_BACKUP_ROOT

declare -A RFW_CFG=()
RFW_LOCKED=0
RFW_TMP_DIR=""
RFW_CONFIRM_APPROVED=0
declare -a RFW_ARGS=()
RFW_META_TAG=""
RFW_META_ASSET=""
RFW_META_SHA256=""
RFW_FETCHED_TAG=""
RFW_FETCHED_ASSET=""
RFW_FETCHED_SHA256=""

rfw_require_safe_managed_paths() {
    local path

    for path in \
        "$RFW_BINARY" "$RFW_CONFIG" "$RFW_UNIT" \
        "$RFW_STATE_DIR" "$RFW_PENDING" "$RFW_LKG_CONFIG" "$RFW_METADATA" \
        "$RFW_BACKUP_ROOT"; do
        vps_cmd_require_no_symlink_components "$path" || return $?
    done
}

rfw_error() { vps_cmd_error "$@"; }
rfw_info() { vps_cmd_info "$@"; }
rfw_success() { vps_cmd_success "$@"; }
rfw_warning() { vps_cmd_warning "$@"; }

rfw_usage() {
    cat <<'EOF'
管理 narwhal-cloud/rfw XDP 防火墙。

用法：
  rfw [global-options] [status]
  rfw install [--force]
  rfw update [--force]
  rfw configure [configuration-options]
  rfw start [--enable] [--confirm-disruptive]
  rfw stop [--disable]
  rfw restart [--confirm-disruptive]
  rfw stats [--port PORT] [--ip ADDRESS] [--blocked-only|--allowed-only]
            [--group-by-port]
  rfw logs [--follow] [--lines COUNT] [--since VALUE]
  rfw uninstall [--purge] [--confirm-purge]

配置选项（未指定的值保持不变）：
  --iface NAME
  --geo-mode none|blocklist|whitelist
  --countries CC[,CC...]
  --block-email on|off       --block-http on|off
  --block-socks5 on|off      --block-wireguard on|off
  --block-quic on|off        --block-all on|off
  --fet off|loose|strict     --xdp-mode auto|skb|drv|hw
  --log-port-access on|off   --rust-log LEVEL

终端中无参数运行会打开子菜单；非交互运行会显示状态。
RFW 当前仅过滤 IPv4。启用 block-all 或 FET strict 时，交互模式必须输入
APPLY-RFW；非交互模式必须显式传入 --confirm-disruptive。--yes 不能绕过此确认。

全局选项（必须位于动作之前）：
  --install-deps  --dry-run  --yes  --non-interactive  --quiet  --verbose  --no-color  --
EOF
}

rfw_unlock() {
    if [[ "$RFW_LOCKED" == "1" ]]; then
        unlock network-rfw || true
        RFW_LOCKED=0
    fi
}

rfw_cleanup_tmp() {
    if [[ -n "${RFW_TMP_DIR:-}" ]]; then
        rm -rf -- "$RFW_TMP_DIR"
        RFW_TMP_DIR=""
    fi
}

rfw_take_lock() {
    rfw_require_safe_managed_paths || return $?
    lock network-rfw || return $?
    RFW_LOCKED=1
    trap rfw_unlock EXIT
}

rfw_require_root() {
    vps_cmd_require_root
}

rfw_platform_target() {
    local kernel arch
    kernel="${VPSCTL_ENV_KERNEL_NAME:-$(uname -s 2>/dev/null || true)}"
    arch="${VPSCTL_ENV_ARCH:-$(uname -m 2>/dev/null || true)}"

    [[ "$kernel" == "Linux" ]] || {
        rfw_error "RFW 仅支持 Linux"
        return 3
    }
    if [[ -n "${VPSCTL_ENV_INIT:-}" && "${VPSCTL_ENV_INIT}" != "systemd" ]]; then
        rfw_error "RFW 管理功能需要 systemd"
        return 3
    fi
    command -v systemctl >/dev/null 2>&1 || {
        rfw_error "缺少必需命令 systemctl"
        return 3
    }
    if [[ -z "${VPSCTL_ENV_INIT:-}" && ! -d "$(system_path /run/systemd/system)" ]]; then
        rfw_error "RFW 管理功能需要正在运行的 systemd"
        return 3
    fi

    case "$arch" in
        x86_64 | amd64) printf 'x86_64-unknown-linux-musl\n' ;;
        aarch64 | arm64) printf 'aarch64-unknown-linux-musl\n' ;;
        *)
            rfw_error "不支持的架构：${arch:-未知}（仅支持 x86_64 或 aarch64）"
            return 3
            ;;
    esac
}

rfw_parse_global_options() {
    RFW_ARGS=()
    while (($#)); do
        case "$1" in
            --install-deps) VPSCTL_INSTALL_DEPS=1 ;;
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --no-color) VPSCTL_NO_COLOR=1 ;;
            -h | --help)
                (($# == 1)) || {
                    rfw_error "$1 不接受额外参数"
                    return 2
                }
                RFW_ARGS=(help)
                return 0
                ;;
            --)
                shift
                RFW_ARGS=("$@")
                return 0
                ;;
            -*)
                rfw_error "未知全局选项：$1"
                return 2
                ;;
            *)
                RFW_ARGS=("$@")
                return 0
                ;;
        esac
        shift
    done
}

rfw_defaults() {
    local iface="${RFW_DEFAULT_INTERFACE:-eth0}"
    local route_line=""

    if [[ -z "${RFW_DEFAULT_INTERFACE:-}" ]] && command -v ip >/dev/null 2>&1; then
        route_line="$(ip route show default 2>/dev/null | head -n 1 || true)"
        if [[ "$route_line" =~ (^|[[:space:]])dev[[:space:]]+([^[:space:]]+) ]]; then
            iface="${BASH_REMATCH[2]}"
        fi
    fi

    RFW_CFG=()
    RFW_CFG[interface]="$iface"
    RFW_CFG[geo_mode]="none"
    RFW_CFG[countries]=""
    RFW_CFG[block_email]="off"
    RFW_CFG[block_http]="off"
    RFW_CFG[block_socks5]="off"
    RFW_CFG[block_wireguard]="off"
    RFW_CFG[block_quic]="off"
    RFW_CFG[block_all]="off"
    RFW_CFG[fet]="off"
    RFW_CFG[xdp_mode]="auto"
    RFW_CFG[log]="off"
    RFW_CFG[RUST_LOG]="info"
}

rfw_display_switch() {
    case "$1" in
        on) printf '开启' ;;
        off) printf '关闭' ;;
        *) printf '%s' "$1" ;;
    esac
}

rfw_display_geo_mode() {
    case "$1" in
        none) printf '关闭' ;;
        blocklist) printf '黑名单' ;;
        whitelist) printf '白名单' ;;
        *) printf '%s' "$1" ;;
    esac
}

rfw_display_fet() {
    case "$1" in
        off) printf '关闭' ;;
        loose) printf '宽松' ;;
        strict) printf '严格' ;;
        *) printf '%s' "$1" ;;
    esac
}

rfw_display_pending_reason() {
    case "$1" in
        install) printf '安装' ;;
        update) printf '更新' ;;
        configure) printf '配置' ;;
        *) printf '%s' "$1" ;;
    esac
}

rfw_valid_interface() { [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; }
rfw_valid_switch() { [[ "$1" == "on" || "$1" == "off" ]]; }
rfw_valid_geo_mode() { [[ "$1" == "none" || "$1" == "blocklist" || "$1" == "whitelist" ]]; }
rfw_valid_fet() { [[ "$1" == "off" || "$1" == "loose" || "$1" == "strict" ]]; }
rfw_valid_xdp() { [[ "$1" == "auto" || "$1" == "skb" || "$1" == "drv" || "$1" == "hw" ]]; }
rfw_valid_rust_log() { [[ "$1" =~ ^(off|error|warn|info|debug|trace)(,[A-Za-z0-9_:-]+=(off|error|warn|info|debug|trace))*$ ]]; }
rfw_valid_country_code() {
    local codes=" AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS YE YT ZA ZM ZW "
    [[ "$codes" == *" $1 "* ]]
}

rfw_normalize_countries() {
    local value="${1^^}" item joined=""
    local -a items=()
    [[ -n "$value" ]] || {
        printf '\n'
        return 0
    }
    IFS=',' read -r -a items <<<"$value"
    for item in "${items[@]}"; do
        [[ "$item" =~ ^[A-Z]{2}$ ]] && rfw_valid_country_code "$item" || return 1
        case ",${joined}," in *",${item},"*) return 1 ;; esac
        [[ -n "$joined" ]] && joined+=","
        joined+="$item"
    done
    printf '%s\n' "$joined"
}

rfw_validate_config() {
    local key countries
    for key in interface geo_mode countries block_email block_http block_socks5 block_wireguard block_quic block_all fet xdp_mode log RUST_LOG; do
        [[ ${RFW_CFG[$key]+present} == present ]] || {
            rfw_error "配置缺少键：$key"
            return 10
        }
    done
    rfw_valid_interface "${RFW_CFG[interface]}" || {
        rfw_error "网络接口无效：${RFW_CFG[interface]}"
        return 10
    }
    rfw_valid_geo_mode "${RFW_CFG[geo_mode]}" || {
        rfw_error "geo_mode 无效：${RFW_CFG[geo_mode]}"
        return 10
    }
    for key in block_email block_http block_socks5 block_wireguard block_quic block_all log; do
        rfw_valid_switch "${RFW_CFG[$key]}" || {
            rfw_error "${key} 必须是 on 或 off"
            return 10
        }
    done
    rfw_valid_fet "${RFW_CFG[fet]}" || {
        rfw_error "fet 必须是 off、loose 或 strict"
        return 10
    }
    rfw_valid_xdp "${RFW_CFG[xdp_mode]}" || {
        rfw_error "xdp_mode 必须是 auto、skb、drv 或 hw"
        return 10
    }
    rfw_valid_rust_log "${RFW_CFG[RUST_LOG]}" || {
        rfw_error "RUST_LOG 表达式无效"
        return 10
    }
    countries="$(rfw_normalize_countries "${RFW_CFG[countries]}")" || {
        rfw_error "countries 必须是以逗号分隔且不重复的 ISO 3166-1 alpha-2 国家代码"
        return 10
    }
    RFW_CFG[countries]="$countries"
    if [[ "${RFW_CFG[geo_mode]}" == "none" && -n "$countries" ]]; then
        rfw_error "geo_mode=none 时 countries 必须为空"
        return 10
    fi
    if [[ "${RFW_CFG[geo_mode]}" != "none" && -z "$countries" ]]; then
        rfw_error "geo_mode 为 blocklist 或 whitelist 时必须设置 countries"
        return 10
    fi
}

rfw_load_config_file() {
    local file="$1" line key value line_number=0 first required
    local -A seen=()
    rfw_defaults
    [[ -r "$file" ]] || return 1
    [[ ! -L "$file" ]] || {
        rfw_error "配置文件不能是符号链接：$file"
        return 10
    }
    IFS= read -r first <"$file" || {
        rfw_error "配置文件为空：$file"
        return 10
    }
    [[ "${first%$'\r'}" == "$RFW_MANAGED_MARKER" ]] || {
        rfw_error "配置文件不受 vpsctl 管理：$file"
        return 10
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=([^[:space:]]*)$ ]]; then
            rfw_error "配置语法无效：${file}:${line_number}"
            return 10
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        case "$key" in
            interface | geo_mode | countries | block_email | block_http | block_socks5 | block_wireguard | block_quic | block_all | fet | xdp_mode | log | RUST_LOG) ;;
            *)
                rfw_error "未知配置键 '${key}'：${file}:${line_number}"
                return 10
                ;;
        esac
        [[ ${seen[$key]+present} != present ]] || {
            rfw_error "配置键 '${key}' 重复"
            return 10
        }
        seen[$key]=1
        RFW_CFG[$key]="$value"
    done <"$file"
    for required in interface geo_mode countries block_email block_http block_socks5 block_wireguard block_quic block_all fet xdp_mode log RUST_LOG; do
        [[ ${seen[$required]+present} == present ]] || {
            rfw_error "配置缺少键：$required"
            return 10
        }
    done
    rfw_validate_config
}

rfw_load_config() {
    rfw_load_config_file "$RFW_CONFIG" || {
        local status=$?
        if [[ "$status" == "1" ]]; then
            rfw_error "尚未安装 RFW 配置"
            return 3
        fi
        return "$status"
    }
}

rfw_has_effective_policy() {
    local key
    [[ "${RFW_CFG[fet]}" != "off" || "${RFW_CFG[log]}" == "on" ]] && return 0
    for key in block_email block_http block_socks5 block_wireguard block_quic block_all; do
        [[ "${RFW_CFG[$key]}" == "on" ]] && return 0
    done
    return 1
}

rfw_kernel_supported() {
    local release major minor
    release="${VPSCTL_ENV_KERNEL_RELEASE:-$(uname -r 2>/dev/null || true)}"
    if [[ ! "$release" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?([+-][0-9A-Za-z._+~-]+)?$ ]]; then
        rfw_error "无法验证内核版本：${release:-未知}"
        return 3
    fi
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    if ((major < 5 || (major == 5 && minor < 15))); then
        rfw_error "RFW 需要 Linux 内核 5.15 或更高版本（当前 ${release}）"
        return 3
    fi
}

rfw_platform_gate() {
    rfw_platform_target >/dev/null || return
    rfw_kernel_supported
}

rfw_managed_files_present() {
    if [[ -f "$RFW_BINARY" && ! -L "$RFW_BINARY" && -x "$RFW_BINARY" ]] &&
        rfw_is_managed_file "$RFW_CONFIG" &&
        rfw_is_managed_file "$RFW_UNIT" &&
        rfw_load_metadata; then
        return 0
    fi
    return 1
}

rfw_require_managed_files() {
    rfw_managed_files_present && return 0
    rfw_error "需要完整且由 vpsctl 管理的 RFW 安装"
    return 3
}

rfw_ensure_dependencies() {
    vps_cmd_ensure_tools network-rfw "$@"
}

rfw_stop_after_dependency_plan() {
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == "1" ]] || return 1
    rfw_info "依赖仅完成安装计划；请安装依赖后重新运行以继续安全验证"
}

rfw_runtime_preflight() {
    rfw_platform_target >/dev/null || return
    rfw_kernel_supported || return
    command -v ip >/dev/null 2>&1 || {
        rfw_error "验证网络接口需要 ip 命令"
        return 3
    }
    ip link show dev "${RFW_CFG[interface]}" >/dev/null 2>&1 || {
        rfw_error "配置的网络接口不存在：${RFW_CFG[interface]}"
        return 3
    }
    if [[ "${RFW_CFG[log]}" == "on" ]]; then
        command -v mountpoint >/dev/null 2>&1 || {
            rfw_error "验证 bpffs 需要 mountpoint 命令"
            return 3
        }
        mountpoint -q "$(system_path /sys/fs/bpf)" || {
            rfw_error "端口访问日志要求在 /sys/fs/bpf 挂载 bpffs"
            return 3
        }
    fi
}

rfw_valid_ipv4() {
    local value="$1" octet
    local -a octets=()
    [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octets <<<"$value"
    for octet in "${octets[@]}"; do
        [[ "$octet" == "0" || "$octet" != 0* ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

rfw_emit_config() {
    printf '%s\n' "$RFW_MANAGED_MARKER"
    printf '# 以下内容仅按数据解析，绝不会被 source。\n'
    printf 'interface=%s\n' "${RFW_CFG[interface]}"
    printf 'geo_mode=%s\n' "${RFW_CFG[geo_mode]}"
    printf 'countries=%s\n' "${RFW_CFG[countries]}"
    printf 'block_email=%s\n' "${RFW_CFG[block_email]}"
    printf 'block_http=%s\n' "${RFW_CFG[block_http]}"
    printf 'block_socks5=%s\n' "${RFW_CFG[block_socks5]}"
    printf 'block_wireguard=%s\n' "${RFW_CFG[block_wireguard]}"
    printf 'block_quic=%s\n' "${RFW_CFG[block_quic]}"
    printf 'block_all=%s\n' "${RFW_CFG[block_all]}"
    printf 'fet=%s\n' "${RFW_CFG[fet]}"
    printf 'xdp_mode=%s\n' "${RFW_CFG[xdp_mode]}"
    printf 'log=%s\n' "${RFW_CFG[log]}"
    printf 'RUST_LOG=%s\n' "${RFW_CFG[RUST_LOG]}"
}

rfw_build_exec_start() {
    local exec="/usr/local/bin/rfw --iface ${RFW_CFG[interface]} --xdp-mode ${RFW_CFG[xdp_mode]}"
    case "${RFW_CFG[geo_mode]}" in
        blocklist) exec+=" --countries ${RFW_CFG[countries]}" ;;
        whitelist) exec+=" --allow-only-countries ${RFW_CFG[countries]}" ;;
    esac
    [[ "${RFW_CFG[block_email]}" == "on" ]] && exec+=" --block-email"
    [[ "${RFW_CFG[block_http]}" == "on" ]] && exec+=" --block-http"
    [[ "${RFW_CFG[block_socks5]}" == "on" ]] && exec+=" --block-socks5"
    [[ "${RFW_CFG[block_wireguard]}" == "on" ]] && exec+=" --block-wireguard"
    [[ "${RFW_CFG[block_quic]}" == "on" ]] && exec+=" --block-quic"
    [[ "${RFW_CFG[block_all]}" == "on" ]] && exec+=" --block-all"
    case "${RFW_CFG[fet]}" in
        loose) exec+=" --block-fet-loose" ;;
        strict) exec+=" --block-fet-strict" ;;
    esac
    [[ "${RFW_CFG[log]}" == "on" ]] && exec+=" --log-port-access"
    printf '%s\n' "$exec"
}

rfw_emit_unit() {
    local exec_start
    exec_start="$(rfw_build_exec_start)"
    cat <<EOF
${RFW_MANAGED_MARKER}
[Unit]
Description=RFW eBPF/XDP 防火墙
Documentation=https://github.com/narwhal-cloud/rfw
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment=RUST_LOG=${RFW_CFG[RUST_LOG]}
EOF
    if [[ "${RFW_CFG[log]}" == "on" ]]; then
        printf 'ExecStartPre=/usr/bin/rm -f -- %s\n' "$RFW_PORT_ACCESS_PIN_LOGICAL"
    fi
    cat <<EOF
ExecStart=${exec_start}
EOF
    if [[ "${RFW_CFG[log]}" == "on" ]]; then
        printf 'ExecStopPost=/usr/bin/rm -f -- %s\n' "$RFW_PORT_ACCESS_PIN_LOGICAL"
    fi
    cat <<EOF
KillSignal=SIGINT
Restart=on-failure
RestartSec=3s
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF
}

rfw_is_managed_file() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] && IFS= read -r line <"$file" && [[ "$line" == "$RFW_MANAGED_MARKER" ]]
}

rfw_unit_uses_port_access_log() {
    rfw_is_managed_file "$RFW_UNIT" &&
        grep -Eq '^ExecStart=.*[[:space:]]--log-port-access([[:space:]]|$)' "$RFW_UNIT"
}

rfw_load_metadata() {
    local line key value first required
    local -A seen=()
    RFW_META_TAG=""
    RFW_META_ASSET=""
    RFW_META_SHA256=""
    [[ -f "$RFW_METADATA" && ! -L "$RFW_METADATA" ]] || return 1
    IFS= read -r first <"$RFW_METADATA" || return 1
    [[ "$first" == "$RFW_MANAGED_MARKER" ]] || return 1
    while IFS='=' read -r key value; do
        [[ "$key" == "$RFW_MANAGED_MARKER" || -z "$key" ]] && continue
        case "$key" in tag | asset | sha256) ;; *) return 1 ;; esac
        [[ ${seen[$key]+present} != present ]] || return 1
        seen[$key]=1
        case "$key" in
            tag) RFW_META_TAG="$value" ;;
            asset) RFW_META_ASSET="$value" ;;
            sha256) RFW_META_SHA256="${value,,}" ;;
        esac
    done <"$RFW_METADATA"
    for required in tag asset sha256; do [[ ${seen[$required]+present} == present ]] || return 1; done
    [[ "$RFW_META_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$RFW_META_ASSET" =~ ^rfw-(x86_64|aarch64)-unknown-linux-musl$ ]] || return 1
    [[ "$RFW_META_SHA256" =~ ^[0-9a-f]{64}$ ]]
}

rfw_emit_metadata() {
    printf '%s\n' "$RFW_MANAGED_MARKER"
    printf 'tag=%s\nasset=%s\nsha256=%s\n' "$RFW_META_TAG" "$RFW_META_ASSET" "$RFW_META_SHA256"
}

rfw_write_metadata() {
    run mkdir -p "$RFW_STATE_DIR" || return 20
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] && return 0
    rfw_emit_metadata | atomic_write "$RFW_METADATA" 0600 || return 20
}

rfw_binary_matches_metadata() {
    local actual
    command -v sha256sum >/dev/null 2>&1 || return 1
    rfw_load_metadata || return 1
    actual="$(sha256sum "$RFW_BINARY" 2>/dev/null)" || return 1
    actual="${actual%%[[:space:]]*}"
    [[ "${actual,,}" == "$RFW_META_SHA256" ]]
}

rfw_is_managed_install() {
    [[ -f "$RFW_BINARY" && ! -L "$RFW_BINARY" && -x "$RFW_BINARY" ]] || return 1
    rfw_is_managed_file "$RFW_CONFIG" || return 1
    rfw_is_managed_file "$RFW_UNIT" || return 1
    rfw_binary_matches_metadata || return 1
}

rfw_require_managed_install() {
    rfw_is_managed_install && return 0
    rfw_error "需要完整且由 vpsctl 管理的 RFW 安装"
    return 3
}

rfw_safe_backup_file() {
    local path="$1" resolved root_resolved
    [[ -n "$path" && "$path" == "$RFW_BACKUP_ROOT"/* && "$path" != *'/../'* ]] || return 1
    [[ -f "$path" && ! -L "$path" && ! -L "$RFW_BACKUP_ROOT" ]] || return 1
    resolved="$(readlink -f -- "$path" 2>/dev/null || true)"
    root_resolved="$(readlink -f -- "$RFW_BACKUP_ROOT" 2>/dev/null || true)"
    [[ -n "$resolved" && -n "$root_resolved" && "$resolved" == "$root_resolved"/* ]]
}

rfw_install_owned() {
    if [[ -e "$RFW_BINARY" && ! -f "$RFW_UNIT" ]]; then return 1; fi
    if [[ -e "$RFW_UNIT" ]] && ! rfw_is_managed_file "$RFW_UNIT"; then return 1; fi
    if [[ -e "$RFW_CONFIG" ]] && ! rfw_is_managed_file "$RFW_CONFIG"; then return 1; fi
    [[ ! -e "$RFW_BINARY" ]] || rfw_is_managed_file "$RFW_UNIT"
}

rfw_confirm_overwrite() {
    local force="$1"
    local status
    RFW_CONFIRM_APPROVED=0
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    if rfw_install_owned; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    if [[ "$force" == "1" ]]; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
        rfw_error "拒绝覆盖不受管的 RFW 文件；如确需覆盖，请显式传入 --force"
        return 3
    fi
    if confirm_token "检测到不受管的 RFW 文件；确认覆盖" "OVERWRITE-RFW"; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    status=$?
    [[ "$status" == "130" ]] && return 130
    rfw_info "已取消安装，未更改任何文件。"
    return 0
}

rfw_release_tag() {
    local json_file="$1" tag draft prerelease
    tag="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$json_file" | head -n 1)"
    draft="$(sed -n 's/.*"draft"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$json_file" | head -n 1)"
    prerelease="$(sed -n 's/.*"prerelease"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$json_file" | head -n 1)"
    [[ "$draft" == "false" && "$prerelease" == "false" ]] || {
        rfw_error "最新 Release 元数据缺少 draft=false 或 prerelease=false 的稳定版声明"
        return 20
    }
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        rfw_error "最新稳定 Release 的 tag 无效：${tag:-缺失}"
        return 20
    }
    printf '%s\n' "$tag"
}

rfw_expected_checksum() {
    local checksums="$1" asset="$2" line hash name found=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^([0-9A-Fa-f]{64})[[:space:]]+[*]?([^[:space:]]+)$ ]]; then
            hash="${BASH_REMATCH[1],,}"
            name="${BASH_REMATCH[2]}"
            if [[ "$name" == "$asset" ]]; then
                [[ -z "$found" ]] || {
                    rfw_error "checksums.txt 中 ${asset} 的 checksum 条目重复"
                    return 20
                }
                found="$hash"
            fi
        fi
    done <"$checksums"
    [[ -n "$found" ]] || {
        rfw_error "checksums.txt 中没有 ${asset} 的精确 checksum 条目"
        return 20
    }
    printf '%s\n' "$found"
}

rfw_fetch_binary() {
    local output="$1" target tag tag_version binary_version asset expected actual tmp_dir json checksums version_output
    command -v curl >/dev/null 2>&1 || {
        rfw_error "缺少必需命令 curl"
        return 3
    }
    command -v sha256sum >/dev/null 2>&1 || {
        rfw_error "缺少必需命令 sha256sum"
        return 3
    }
    target="$(rfw_platform_target)" || return
    asset="rfw-${target}"
    tmp_dir="$(dirname -- "$output")"
    json="${tmp_dir}/release.json"
    checksums="${tmp_dir}/checksums.txt"

    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 15 --max-time 120 -o "$json" "$RFW_RELEASE_API" || {
        rfw_error "查询最新 RFW Release 失败"
        return 20
    }
    tag="$(rfw_release_tag "$json")" || return
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 15 --max-time 300 -o "$output" \
        "https://github.com/${RFW_REPOSITORY}/releases/download/${tag}/${asset}" || {
        rfw_error "下载 ${asset} 失败"
        return 20
    }
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 15 --max-time 120 -o "$checksums" \
        "https://github.com/${RFW_REPOSITORY}/releases/download/${tag}/checksums.txt" || {
        rfw_error "下载 checksums.txt 失败"
        return 20
    }
    expected="$(rfw_expected_checksum "$checksums" "$asset")" || return
    actual="$(sha256sum "$output")" || {
        rfw_error "执行 sha256sum 失败"
        return 20
    }
    actual="${actual%%[[:space:]]*}"
    actual="${actual,,}"
    if [[ ! "$actual" =~ ^[0-9a-f]{64}$ || "$actual" != "$expected" ]]; then
        rfw_error "${asset} 的 checksum 校验失败"
        return 20
    fi
    chmod 0755 -- "$output" || {
        rfw_error "无法为下载的 RFW 添加可执行权限"
        return 20
    }
    version_output="$("$output" --version 2>/dev/null)" || {
        rfw_error "下载的 RFW 未通过 --version 冒烟测试"
        return 20
    }
    binary_version="$(sed -n 's/.*\(^\|[^0-9]\)\(v\{0,1\}[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\([^0-9].*\|$\)/\2/p' <<<"$version_output" | head -n 1)"
    tag_version="${tag#v}"
    binary_version="${binary_version#v}"
    [[ -n "$binary_version" && "$binary_version" == "$tag_version" ]] || {
        rfw_error "下载的二进制版本 '${binary_version:-未知}' 与 Release ${tag} 不一致"
        return 20
    }
    RFW_FETCHED_TAG="$tag"
    RFW_FETCHED_ASSET="$asset"
    RFW_FETCHED_SHA256="$expected"
}

rfw_write_pending() {
    local reason="$1" binary_backup="${2:-}" config_backup="${3:-}" metadata_backup="${4:-}"
    run mkdir -p "$RFW_STATE_DIR"
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        rfw_info "演练：将 RFW 更改标记为待重启（$(rfw_display_pending_reason "$reason")）"
        return 0
    fi
    {
        printf '%s\n' "$RFW_MANAGED_MARKER"
        printf 'reason=%s\n' "$reason"
        printf 'binary_backup=%s\n' "$binary_backup"
        printf 'config_backup=%s\n' "$config_backup"
        printf 'metadata_backup=%s\n' "$metadata_backup"
    } | atomic_write "$RFW_PENDING" 0600
}

rfw_pending_value() {
    local wanted="$1" key value first line_number=0 found=""
    local -A seen=()
    [[ -r "$RFW_PENDING" && ! -L "$RFW_PENDING" ]] || return 1
    IFS= read -r first <"$RFW_PENDING" || return 1
    [[ "$first" == "$RFW_MANAGED_MARKER" ]] || return 1
    while IFS='=' read -r key value; do
        line_number=$((line_number + 1))
        [[ "$key" == "$RFW_MANAGED_MARKER" || -z "$key" ]] && continue
        case "$key" in reason | binary_backup | config_backup | metadata_backup) ;; *) return 1 ;; esac
        [[ ${seen[$key]+present} != present ]] || return 1
        seen[$key]=1
        [[ "$key" != "$wanted" ]] || found="$value"
    done <"$RFW_PENDING"
    for key in reason binary_backup config_backup metadata_backup; do [[ ${seen[$key]+present} == present ]] || return 1; done
    value="$(sed -n 's/^reason=//p' "$RFW_PENDING")"
    [[ "$value" == "update" || "$value" == "configure" ]] || return 1
    [[ ${seen[$wanted]+present} == present ]] || return 1
    printf '%s\n' "$found"
}

rfw_restore_transaction_file() {
    local target="$1" existed="$2" backup="$3" mode="$4"
    if [[ "$existed" == "1" ]]; then
        rfw_safe_backup_file "$backup" || return 1
        atomic_write "$target" "$mode" <"$backup" || return 1
    else
        run rm -f "$target" || return 1
    fi
}

rfw_rollback_files() {
    local binary_existed="$1" binary_backup="$2" config_existed="$3" config_backup="$4" unit_existed="$5" unit_backup="$6" metadata_existed="$7" metadata_backup="$8" reload="${9:-0}"
    local failed=0
    rfw_restore_transaction_file "$RFW_BINARY" "$binary_existed" "$binary_backup" 0755 || failed=1
    rfw_restore_transaction_file "$RFW_CONFIG" "$config_existed" "$config_backup" 0600 || failed=1
    rfw_restore_transaction_file "$RFW_UNIT" "$unit_existed" "$unit_backup" 0644 || failed=1
    rfw_restore_transaction_file "$RFW_METADATA" "$metadata_existed" "$metadata_backup" 0600 || failed=1
    if [[ "$reload" == "1" ]]; then run systemctl daemon-reload || failed=1; fi
    ((failed == 0))
}

rfw_rollback_config_unit() {
    local config_backup="$1" unit_backup="$2" failed=0
    if rfw_safe_backup_file "$config_backup"; then atomic_write "$RFW_CONFIG" 0600 <"$config_backup" || failed=1; else failed=1; fi
    if rfw_safe_backup_file "$unit_backup"; then atomic_write "$RFW_UNIT" 0644 <"$unit_backup" || failed=1; else failed=1; fi
    run systemctl daemon-reload || failed=1
    ((failed == 0))
}

rfw_write_config_and_unit() {
    local reload="${1:-1}"
    rfw_validate_config || return
    run mkdir -p "$(dirname -- "$RFW_CONFIG")" "$(dirname -- "$RFW_UNIT")" || return 20
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        rfw_info "演练：写入已验证的配置和 systemd 单元"
        [[ "$reload" == "0" ]] || run systemctl daemon-reload
        return 0
    fi
    rfw_emit_config | atomic_write "$RFW_CONFIG" 0600 || return 20
    rfw_emit_unit | atomic_write "$RFW_UNIT" 0644 || return 20
    if [[ "$reload" != "0" ]]; then run systemctl daemon-reload || return 20; fi
}

rfw_install_or_update() {
    local action="$1" force=0 arg tmp_dir downloaded status
    local -a dependency_tools=(curl sha256sum)
    local binary_backup="" config_backup="" unit_backup="" metadata_backup="" previous_backup=""
    local pending_binary_backup="" pending_config_backup="" pending_metadata_backup=""
    local binary_existed=0 config_existed=0 unit_existed=0 metadata_existed=0
    shift
    while (($#)); do
        arg="$1"
        case "$arg" in
            --force) force=1 ;;
            -h | --help)
                rfw_usage
                return 0
                ;;
            *)
                rfw_error "${action} 的未知选项：$arg"
                return 2
                ;;
        esac
        shift
    done
    rfw_require_root || return
    rfw_platform_gate || return
    if [[ -L "$RFW_BINARY" || -L "$RFW_CONFIG" || -L "$RFW_UNIT" ]]; then
        rfw_error "拒绝操作包含符号链接的 RFW 文件"
        return 3
    fi
    if [[ "$action" == "update" ]]; then
        rfw_require_managed_files || return
        rfw_validate_pending_backups || return
    else
        rfw_confirm_overwrite "$force" || return
        [[ "$RFW_CONFIRM_APPROVED" == "1" ]] || return 0
    fi

    if [[ "$action" == "install" ]] && rfw_managed_files_present; then
        rfw_ensure_dependencies sha256sum || return
        if rfw_stop_after_dependency_plan; then
            return 0
        fi
        if rfw_is_managed_install; then
            rfw_success "RFW 已安装并通过验证，无需更改。"
            return 0
        fi
    fi
    if [[ "$action" == "install" && "$force" == "0" ]] &&
        rfw_install_owned && [[ -e "$RFW_BINARY" && -e "$RFW_UNIT" && -e "$RFW_CONFIG" ]]; then
        rfw_error "RFW 已安装；如需替换受管二进制，请使用 update"
        return 3
    fi
    [[ "$action" == "install" ]] && dependency_tools+=(ip)
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] || dependency_tools+=(flock)
    rfw_ensure_dependencies "${dependency_tools[@]}" || return
    if rfw_stop_after_dependency_plan; then
        return 0
    fi
    if [[ "$action" == "update" ]]; then
        rfw_require_managed_install || return
    fi

    rfw_take_lock || return
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        rfw_info "演练：获取、验证并原子安装最新 RFW 发布版本"
        rfw_info "演练：将写入 ${RFW_CONFIG} 和 ${RFW_UNIT}；服务状态不会改变"
        return 0
    fi

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-rfw.XXXXXX")" || {
        rfw_error "创建临时下载目录失败"
        return 20
    }
    RFW_TMP_DIR="$tmp_dir"
    downloaded="${tmp_dir}/rfw"
    trap 'rfw_cleanup_tmp; rfw_unlock' EXIT
    if rfw_fetch_binary "$downloaded"; then
        :
    else
        status=$?
        rfw_cleanup_tmp
        trap rfw_unlock EXIT
        [[ "$status" == "3" ]] && return 3
        return 20
    fi
    if [[ "$action" == "update" && "$force" == "0" ]]; then
        rfw_load_metadata || {
            rfw_cleanup_tmp
            return 3
        }
        if [[ "$RFW_META_TAG" == "$RFW_FETCHED_TAG" && "$RFW_META_SHA256" == "$RFW_FETCHED_SHA256" ]]; then
            rfw_cleanup_tmp
            trap rfw_unlock EXIT
            rfw_success "RFW ${RFW_META_TAG} 已是最新版本，无需更改。"
            return 0
        fi
    fi

    if [[ -e "$RFW_BINARY" ]]; then
        binary_existed=1
        binary_backup="$(backup_file rfw "$RFW_BINARY")" || {
            rfw_cleanup_tmp
            return 20
        }
    fi
    if [[ -e "$RFW_CONFIG" ]]; then
        config_existed=1
        config_backup="$(backup_file rfw "$RFW_CONFIG")" || {
            rfw_cleanup_tmp
            return 20
        }
    fi
    if [[ -e "$RFW_UNIT" ]]; then
        unit_existed=1
        unit_backup="$(backup_file rfw "$RFW_UNIT")" || {
            rfw_cleanup_tmp
            return 20
        }
    fi
    if [[ -e "$RFW_METADATA" ]]; then
        metadata_existed=1
        metadata_backup="$(backup_file rfw "$RFW_METADATA")" || {
            rfw_cleanup_tmp
            return 20
        }
    fi
    pending_binary_backup="$binary_backup"
    pending_config_backup="$config_backup"
    pending_metadata_backup="$metadata_backup"
    if [[ "$action" == "update" && -e "$RFW_PENDING" ]]; then
        previous_backup="$(rfw_pending_value binary_backup 2>/dev/null || true)"
        [[ -z "$previous_backup" ]] || pending_binary_backup="$previous_backup"
        previous_backup="$(rfw_pending_value config_backup 2>/dev/null || true)"
        [[ -z "$previous_backup" ]] || pending_config_backup="$previous_backup"
        previous_backup="$(rfw_pending_value metadata_backup 2>/dev/null || true)"
        [[ -z "$previous_backup" ]] || pending_metadata_backup="$previous_backup"
    fi
    run mkdir -p "$(dirname -- "$RFW_BINARY")" || {
        rfw_cleanup_tmp
        return 20
    }
    if ! atomic_write "$RFW_BINARY" 0755 <"$downloaded"; then
        rfw_cleanup_tmp
        return 20
    fi
    RFW_META_TAG="$RFW_FETCHED_TAG"
    RFW_META_ASSET="$RFW_FETCHED_ASSET"
    RFW_META_SHA256="$RFW_FETCHED_SHA256"
    if ! rfw_write_metadata; then
        rfw_cleanup_tmp
        if rfw_rollback_files "$binary_existed" "$binary_backup" "$config_existed" "$config_backup" "$unit_existed" "$unit_backup" "$metadata_existed" "$metadata_backup" 0; then return 20; else return 30; fi
    fi

    if [[ ! -e "$RFW_CONFIG" ]]; then
        rfw_defaults
        if ! rfw_write_config_and_unit 0; then
            rfw_cleanup_tmp
            if rfw_rollback_files "$binary_existed" "$binary_backup" "$config_existed" "$config_backup" "$unit_existed" "$unit_backup" "$metadata_existed" "$metadata_backup" 0; then return 20; else return 30; fi
        fi
    elif [[ "$action" == "install" ]]; then
        if rfw_is_managed_file "$RFW_CONFIG"; then
            if ! rfw_load_config; then
                rfw_cleanup_tmp
                if rfw_rollback_files "$binary_existed" "$binary_backup" "$config_existed" "$config_backup" "$unit_existed" "$unit_backup" "$metadata_existed" "$metadata_backup" 0; then return 10; else return 30; fi
            fi
        else
            rfw_defaults
        fi
        if ! rfw_write_config_and_unit 0; then
            rfw_cleanup_tmp
            if rfw_rollback_files "$binary_existed" "$binary_backup" "$config_existed" "$config_backup" "$unit_existed" "$unit_backup" "$metadata_existed" "$metadata_backup" 0; then return 20; else return 30; fi
        fi
    fi
    if [[ "$action" == "update" ]]; then
        if ! rfw_write_pending "$action" "$pending_binary_backup" "$pending_config_backup" "$pending_metadata_backup"; then
            rfw_cleanup_tmp
            if rfw_rollback_files "$binary_existed" "$binary_backup" "$config_existed" "$config_backup" "$unit_existed" "$unit_backup" "$metadata_existed" "$metadata_backup" 0; then return 20; else return 30; fi
        fi
    fi
    rfw_cleanup_tmp
    trap rfw_unlock EXIT
    rfw_success "RFW ${RFW_FETCHED_TAG} 已原子安装；服务未启动或重启。"
    [[ -n "$binary_backup" ]] && rfw_info "旧二进制已保留在：$binary_backup"
    return 0
}

rfw_prompt_config_value() {
    local key="$1" prompt="$2" validator="$3" invalid_message="$4" value
    while true; do
        value="$(vps_cmd_prompt_value "$prompt" "${RFW_CFG[$key]}")" || return $?
        if "$validator" "$value"; then
            RFW_CFG[$key]="$value"
            return 0
        fi
        rfw_warning "$invalid_message"
    done
}

rfw_prompt_countries() {
    local value normalized
    while true; do
        value="$(vps_cmd_prompt_value "国家代码（逗号分隔）" "${RFW_CFG[countries]}")" || return $?
        if normalized="$(rfw_normalize_countries "$value")" && [[ -n "$normalized" ]]; then
            RFW_CFG[countries]="$normalized"
            return 0
        fi
        rfw_warning "请输入以逗号分隔且不重复的 ISO 3166-1 alpha-2 国家代码"
    done
}

rfw_show_config_summary() {
    local countries="${RFW_CFG[countries]:-无}"
    printf '\n即将保存的 RFW 配置\n'
    printf '  网络接口：%s\n' "${RFW_CFG[interface]}"
    printf '  GeoIP：%s；国家：%s\n' "$(rfw_display_geo_mode "${RFW_CFG[geo_mode]}")" "$countries"
    printf '  阻止外发邮件：%s；HTTP：%s；SOCKS5：%s\n' \
        "$(rfw_display_switch "${RFW_CFG[block_email]}")" \
        "$(rfw_display_switch "${RFW_CFG[block_http]}")" \
        "$(rfw_display_switch "${RFW_CFG[block_socks5]}")"
    printf '  WireGuard：%s；QUIC：%s；全部入站：%s\n' \
        "$(rfw_display_switch "${RFW_CFG[block_wireguard]}")" \
        "$(rfw_display_switch "${RFW_CFG[block_quic]}")" \
        "$(rfw_display_switch "${RFW_CFG[block_all]}")"
    printf '  FET：%s；XDP：%s\n' "$(rfw_display_fet "${RFW_CFG[fet]}")" "${RFW_CFG[xdp_mode]}"
    printf '  端口访问日志：%s；日志级别：%s\n' "$(rfw_display_switch "${RFW_CFG[log]}")" "${RFW_CFG[RUST_LOG]}"
}

rfw_configure_wizard() {
    local key rust_log_default
    local -a switch_prompts=(
        block_email "阻止外发邮件"
        block_http "阻止 HTTP"
        block_socks5 "阻止 SOCKS5"
        block_wireguard "阻止 WireGuard"
        block_quic "阻止 QUIC"
        block_all "阻止全部入站流量"
        log "端口访问日志"
    )

    rfw_info "RFW 配置向导：开放输入会校验格式，编号选择可直接按 Enter 保留当前值。"
    rfw_prompt_config_value interface "网络接口" rfw_valid_interface "网络接口格式无效，请重新输入" || return
    RFW_CFG[geo_mode]="$(vps_cmd_prompt_select "GeoIP 模式" "${RFW_CFG[geo_mode]}" \
        none "关闭" blocklist "黑名单" whitelist "白名单")" || return $?
    if [[ "${RFW_CFG[geo_mode]}" == "none" ]]; then
        RFW_CFG[countries]=""
    else
        rfw_prompt_countries || return
    fi
    while ((${#switch_prompts[@]})); do
        key="${switch_prompts[0]}"
        RFW_CFG[$key]="$(vps_cmd_prompt_select "${switch_prompts[1]}" "${RFW_CFG[$key]}" \
            off "关闭" on "开启")" || return $?
        switch_prompts=("${switch_prompts[@]:2}")
    done
    RFW_CFG[fet]="$(vps_cmd_prompt_select "FET 模式" "${RFW_CFG[fet]}" \
        off "关闭" loose "宽松" strict "严格")" || return $?
    RFW_CFG[xdp_mode]="$(vps_cmd_prompt_select "XDP 模式" "${RFW_CFG[xdp_mode]}" \
        auto "自动" skb "SKB / 通用模式" drv "驱动模式" hw "硬件卸载模式")" || return $?
    rust_log_default="${RFW_CFG[RUST_LOG]%%,*}"
    case "$rust_log_default" in
        off | error | warn | info | debug | trace) ;;
        *) rust_log_default=info ;;
    esac
    RFW_CFG[RUST_LOG]="$(vps_cmd_prompt_select "Rust 日志级别" "$rust_log_default" \
        off "关闭" error "错误" warn "警告" info "信息" debug "调试" trace "跟踪")" || return $?
    rfw_validate_config || return
    rfw_show_config_summary
    vps_cmd_confirm "确认保存以上配置？"
}

rfw_configure() {
    local changed=0 config_backup="" unit_backup="" previous_binary_backup="" previous_config_backup="" previous_metadata_backup="" pending_config_backup="" key value new_config new_unit
    local -a dependency_tools=(sha256sum)
    rfw_require_root || return
    rfw_platform_gate || return
    rfw_require_managed_files || return
    rfw_load_config || return

    while (($#)); do
        key="$1"
        case "$key" in
            --iface | --geo-mode | --countries | --block-email | --block-http | --block-socks5 | --block-wireguard | --block-quic | --block-all | --fet | --xdp-mode | --log-port-access | --rust-log)
                (($# >= 2)) || {
                    rfw_error "$key 缺少参数值"
                    return 2
                }
                value="$2"
                case "$key" in
                    --iface) RFW_CFG[interface]="$value" ;;
                    --geo-mode) RFW_CFG[geo_mode]="$value" ;;
                    --countries) RFW_CFG[countries]="$value" ;;
                    --block-email) RFW_CFG[block_email]="$value" ;;
                    --block-http) RFW_CFG[block_http]="$value" ;;
                    --block-socks5) RFW_CFG[block_socks5]="$value" ;;
                    --block-wireguard) RFW_CFG[block_wireguard]="$value" ;;
                    --block-quic) RFW_CFG[block_quic]="$value" ;;
                    --block-all) RFW_CFG[block_all]="$value" ;;
                    --fet) RFW_CFG[fet]="$value" ;;
                    --xdp-mode) RFW_CFG[xdp_mode]="$value" ;;
                    --log-port-access) RFW_CFG[log]="$value" ;;
                    --rust-log) RFW_CFG[RUST_LOG]="$value" ;;
                esac
                changed=1
                shift 2
                ;;
            -h | --help)
                rfw_usage
                return 0
                ;;
            *)
                rfw_error "configure 的未知选项：$key"
                return 2
                ;;
        esac
    done
    if [[ "$changed" == "0" ]]; then
        if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
            rfw_error "无选项运行 configure 需要交互式终端"
            return 2
        fi
        if ! rfw_configure_wizard; then
            rfw_info "已取消配置，未更改任何文件。"
            return 0
        fi
    fi
    rfw_validate_config || return
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] || dependency_tools+=(flock)
    rfw_ensure_dependencies "${dependency_tools[@]}" || return
    if rfw_stop_after_dependency_plan; then
        return 0
    fi
    rfw_require_managed_install || return
    rfw_validate_pending_backups || return
    new_config="$(rfw_emit_config)"
    new_unit="$(rfw_emit_unit)"
    if cmp -s <(printf '%s\n' "$new_config") "$RFW_CONFIG" && cmp -s <(printf '%s\n' "$new_unit") "$RFW_UNIT"; then
        rfw_success "RFW 配置已符合要求，无需更改。"
        return 0
    fi
    rfw_take_lock || return
    previous_binary_backup="$(rfw_pending_value binary_backup 2>/dev/null || true)"
    previous_config_backup="$(rfw_pending_value config_backup 2>/dev/null || true)"
    previous_metadata_backup="$(rfw_pending_value metadata_backup 2>/dev/null || true)"
    if [[ -n "$previous_binary_backup" ]] && ! rfw_safe_backup_file "$previous_binary_backup"; then
        rfw_error "待重启二进制备份不在受管备份目录内或不安全"
        return 3
    fi
    if [[ -n "$previous_config_backup" ]] && ! rfw_safe_backup_file "$previous_config_backup"; then
        rfw_error "待重启配置备份不在受管备份目录内或不安全"
        return 3
    fi
    if [[ -n "$previous_metadata_backup" ]] && ! rfw_safe_backup_file "$previous_metadata_backup"; then
        rfw_error "待重启元数据备份不在受管备份目录内或不安全"
        return 3
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != "1" ]]; then
        config_backup="$(backup_file rfw "$RFW_CONFIG")" || return 20
        unit_backup="$(backup_file rfw "$RFW_UNIT")" || return 20
    fi
    pending_config_backup="${previous_config_backup:-$config_backup}"
    if ! rfw_write_config_and_unit; then
        if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] || rfw_rollback_config_unit "$config_backup" "$unit_backup"; then return 20; else return 30; fi
    fi
    if ! rfw_write_pending "configure" "$previous_binary_backup" "$pending_config_backup" "$previous_metadata_backup"; then
        if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] || rfw_rollback_config_unit "$config_backup" "$unit_backup"; then return 20; else return 30; fi
    fi
    rfw_success "RFW 配置已保存；需要重启后生效，当前运行中的服务未改变。"
}

rfw_is_disruptive() {
    [[ "${RFW_CFG[block_all]}" == "on" || "${RFW_CFG[fet]}" == "strict" ]]
}

rfw_require_disruptive_confirmation() {
    local supplied="$1" status
    RFW_CONFIRM_APPROVED=0
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    if ! rfw_is_disruptive; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
        if [[ "$supplied" == "1" ]]; then
            RFW_CONFIRM_APPROVED=1
            return 0
        fi
        rfw_error "高风险策略要求显式传入 --confirm-disruptive"
        return 3
    fi
    if confirm_token "此策略可能阻断正常流量或全部入站流量；确认应用" "APPLY-RFW"; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    status=$?
    [[ "$status" == "130" ]] && return 130
    rfw_info "已取消启动，服务状态未改变。"
    return 0
}

rfw_save_lkg() {
    run mkdir -p "$RFW_STATE_DIR"
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        rfw_info "演练：记录 RFW 最近一次成功配置并清除待重启标记"
        return 0
    fi
    atomic_write "$RFW_LKG_CONFIG" 0600 <"$RFW_CONFIG" || return 20
    run rm -f "$RFW_PENDING" || return 20
}

rfw_validate_pending_backups() {
    local backup binary_backup metadata_backup reason
    [[ ! -e "$RFW_PENDING" ]] && return 0
    [[ -f "$RFW_PENDING" && ! -L "$RFW_PENDING" ]] || {
        rfw_error "待重启标记不安全"
        return 3
    }
    reason="$(rfw_pending_value reason 2>/dev/null)" || {
        rfw_error "待重启标记无效"
        return 3
    }
    binary_backup="$(rfw_pending_value binary_backup 2>/dev/null)" || {
        rfw_error "待重启标记无效"
        return 3
    }
    [[ -z "$binary_backup" ]] || rfw_safe_backup_file "$binary_backup" || {
        rfw_error "待重启二进制备份不安全"
        return 3
    }
    backup="$(rfw_pending_value config_backup 2>/dev/null)" || {
        rfw_error "待重启标记无效"
        return 3
    }
    [[ -z "$backup" ]] || rfw_safe_backup_file "$backup" || {
        rfw_error "待重启配置备份不安全"
        return 3
    }
    metadata_backup="$(rfw_pending_value metadata_backup 2>/dev/null)" || {
        rfw_error "待重启标记无效"
        return 3
    }
    [[ -z "$metadata_backup" ]] || rfw_safe_backup_file "$metadata_backup" || {
        rfw_error "待重启元数据备份不安全"
        return 3
    }
    if [[ "$reason" == "update" && (-z "$binary_backup" || -z "$metadata_backup") ]]; then
        rfw_error "update 待重启标记缺少二进制或元数据回滚状态"
        return 3
    fi
    if [[ (-n "$binary_backup" && -z "$metadata_backup") || (-z "$binary_backup" && -n "$metadata_backup") ]]; then
        rfw_error "待重启二进制与元数据回滚状态不一致"
        return 3
    fi
}

rfw_restore_pending() {
    local mode="$1" binary_backup config_backup metadata_backup restored_config=0 failed=0
    [[ -f "$RFW_PENDING" && ! -L "$RFW_PENDING" ]] || return 1
    binary_backup="$(rfw_pending_value binary_backup 2>/dev/null)" || return 1
    config_backup="$(rfw_pending_value config_backup 2>/dev/null)" || return 1
    metadata_backup="$(rfw_pending_value metadata_backup 2>/dev/null)" || return 1
    if [[ -n "$binary_backup" ]]; then
        rfw_safe_backup_file "$binary_backup" || return 1
        atomic_write "$RFW_BINARY" 0755 <"$binary_backup" || failed=1
    fi
    if [[ -n "$metadata_backup" ]]; then
        rfw_safe_backup_file "$metadata_backup" || return 1
        atomic_write "$RFW_METADATA" 0600 <"$metadata_backup" || failed=1
    fi
    if [[ -f "$RFW_LKG_CONFIG" && ! -L "$RFW_LKG_CONFIG" ]] && rfw_load_config_file "$RFW_LKG_CONFIG"; then
        atomic_write "$RFW_CONFIG" 0600 <"$RFW_LKG_CONFIG" || failed=1
        restored_config=1
    elif [[ -n "$config_backup" ]] && rfw_safe_backup_file "$config_backup" && rfw_load_config_file "$config_backup"; then
        atomic_write "$RFW_CONFIG" 0600 <"$config_backup" || failed=1
        restored_config=1
    fi
    if ((restored_config)); then
        rfw_emit_unit | atomic_write "$RFW_UNIT" 0644 || failed=1
    fi
    run systemctl daemon-reload || failed=1
    if [[ "$mode" == "restart" ]]; then
        run systemctl restart rfw.service || failed=1
        systemctl is-active --quiet rfw.service || failed=1
    else
        run systemctl stop rfw.service || failed=1
        if systemctl is-active --quiet rfw.service; then failed=1; fi
    fi
    if ((failed == 0)); then
        run rm -f "$RFW_PENDING" || return 1
        return 0
    fi
    return 1
}

rfw_ensure_runtime_dependencies() {
    local -a tools=(sha256sum ip)

    [[ "${RFW_CFG[log]}" == "on" ]] && tools+=(mountpoint)
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] || tools+=(flock)
    rfw_ensure_dependencies "${tools[@]}"
}

rfw_service_start() {
    local enable=0 confirmed=0 was_enabled=0 arg
    while (($#)); do
        arg="$1"
        case "$arg" in
            --enable)
                enable=1
                shift
                ;;
            --confirm-disruptive)
                confirmed=1
                shift
                ;;
            *)
                rfw_error "start 的未知选项：$arg"
                return 2
                ;;
        esac
    done
    rfw_require_root || return
    rfw_platform_gate || return
    rfw_require_managed_files || return
    rfw_load_config || return
    rfw_has_effective_policy || {
        rfw_error "未启用任何过滤规则或端口日志，拒绝启动"
        return 3
    }
    rfw_validate_pending_backups || return
    rfw_ensure_runtime_dependencies || return
    if rfw_stop_after_dependency_plan; then
        return 0
    fi
    rfw_require_managed_install || return
    rfw_runtime_preflight || return
    if systemctl is-active --quiet rfw.service && [[ -e "$RFW_PENDING" ]]; then
        rfw_error "RFW 正在运行且存在待生效更改；请使用 restart 安全应用"
        return 3
    fi
    rfw_require_disruptive_confirmation "$confirmed" || return
    [[ "$RFW_CONFIRM_APPROVED" == "1" ]] || return 0
    rfw_take_lock || return
    if systemctl is-active --quiet rfw.service; then
        if ((enable)) && ! systemctl is-enabled --quiet rfw.service; then
            run systemctl enable rfw.service || return 20
        fi
        rfw_success "RFW 已在运行，未执行重复启动。"
        return 0
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        run systemctl daemon-reload
        run systemctl start rfw.service
        ((enable == 0)) || run systemctl enable rfw.service
        rfw_save_lkg
        return 0
    fi
    systemctl is-enabled --quiet rfw.service >/dev/null 2>&1 && was_enabled=1
    run systemctl daemon-reload || return 20
    if ! run systemctl start rfw.service || ! systemctl is-active --quiet rfw.service; then
        run systemctl stop rfw.service || true
        if [[ -e "$RFW_PENDING" ]] && ! rfw_restore_pending start; then return 30; fi
        return 20
    fi
    if ((enable)) && ! run systemctl enable rfw.service; then
        ((was_enabled == 1)) || run systemctl disable rfw.service || true
        run systemctl stop rfw.service || true
        if [[ -e "$RFW_PENDING" ]] && ! rfw_restore_pending start; then return 30; fi
        return 20
    fi
    if ! rfw_save_lkg; then return 30; fi
    rfw_success "RFW 启动成功。"
}

rfw_service_stop() {
    local disable=0
    while (($#)); do
        case "$1" in
            --disable) disable=1 ;;
            *)
                rfw_error "stop 的未知选项：$1"
                return 2
                ;;
        esac
        shift
    done
    rfw_require_root || return
    rfw_platform_gate || return
    if [[ "${VPSCTL_DRY_RUN:-0}" != "1" ]]; then
        rfw_ensure_dependencies flock || return
        if rfw_stop_after_dependency_plan; then
            return 0
        fi
    fi
    rfw_take_lock || return
    run systemctl stop rfw.service || return 20
    if ((disable)); then
        run systemctl disable rfw.service || return 20
    fi
    rfw_success "RFW 已停止。"
}

rfw_service_restart() {
    local confirmed=0 arg
    while (($#)); do
        arg="$1"
        case "$arg" in
            --confirm-disruptive)
                confirmed=1
                shift
                ;;
            *)
                rfw_error "restart 的未知选项：$arg"
                return 2
                ;;
        esac
    done
    rfw_require_root || return
    rfw_platform_gate || return
    rfw_require_managed_files || return
    rfw_load_config || return
    rfw_has_effective_policy || {
        rfw_error "未启用任何过滤规则或端口日志，拒绝重启"
        return 3
    }
    rfw_validate_pending_backups || return
    rfw_ensure_runtime_dependencies || return
    if rfw_stop_after_dependency_plan; then
        return 0
    fi
    rfw_require_managed_install || return
    rfw_runtime_preflight || return
    rfw_require_disruptive_confirmation "$confirmed" || return
    [[ "$RFW_CONFIRM_APPROVED" == "1" ]] || return 0
    rfw_take_lock || return
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        run systemctl daemon-reload
        run systemctl restart rfw.service
        rfw_save_lkg
        return 0
    fi
    run systemctl daemon-reload || return 20
    if run systemctl restart rfw.service && systemctl is-active --quiet rfw.service; then
        if ! rfw_save_lkg; then return 30; fi
        rfw_success "RFW 重启成功；待生效配置和二进制现已应用。"
    else
        if [[ -e "$RFW_PENDING" ]]; then
            if rfw_restore_pending restart; then
                rfw_error "重启失败；已恢复并启动上一版 RFW"
                return 20
            fi
            rfw_error "重启失败，且回滚未完整完成"
            return 30
        fi
        if systemctl is-active --quiet rfw.service; then
            return 20
        fi
        rfw_error "重启失败，RFW 当前未运行"
        return 30
    fi
}

rfw_status() {
    local version="未安装或不受管" active="未安装" enabled="未安装" pending="否" config="未安装" pending_reason=""
    local countries_display
    local active_style="muted" enabled_style="muted" pending_style="success" config_style="muted"
    if [[ "${VPSCTL_INSTALL_DEPS:-0}" == "1" ]]; then
        rfw_platform_gate || return
        rfw_ensure_dependencies sha256sum || return
        if rfw_stop_after_dependency_plan; then
            return 0
        fi
    fi
    if rfw_is_managed_install; then
        version="$("$RFW_BINARY" --version 2>/dev/null | head -n 1 || printf '已安装（无法获取版本）') [${RFW_META_TAG}]"
        active="$(systemctl is-active rfw.service 2>/dev/null || true)"
        enabled="$(systemctl is-enabled rfw.service 2>/dev/null || true)"
        [[ -n "$active" ]] || active="unknown"
        [[ -n "$enabled" ]] || enabled="unknown"
        case "$active" in
            active)
                active="运行中"
                active_style="success"
                ;;
            inactive)
                active="未运行"
                active_style="error"
                ;;
            failed)
                active="运行失败"
                active_style="error"
                ;;
            activating)
                active="正在启动"
                active_style="warning"
                ;;
            deactivating)
                active="正在停止"
                active_style="warning"
                ;;
            *)
                active="未知"
                active_style="warning"
                ;;
        esac
        case "$enabled" in
            enabled)
                enabled="已启用"
                enabled_style="success"
                ;;
            disabled)
                enabled="未启用"
                enabled_style="warning"
                ;;
            static)
                enabled="静态单元"
                enabled_style="info"
                ;;
            masked)
                enabled="已屏蔽"
                enabled_style="error"
                ;;
            *)
                enabled="未知"
                enabled_style="warning"
                ;;
        esac
    fi
    if [[ -e "$RFW_PENDING" ]]; then
        pending_reason="$(rfw_pending_value reason 2>/dev/null || true)"
        pending="是${pending_reason:+（$(rfw_display_pending_reason "$pending_reason")）}"
        pending_style="warning"
    fi
    if rfw_is_managed_file "$RFW_CONFIG"; then
        if rfw_load_config_file "$RFW_CONFIG" 2>/dev/null; then
            countries_display="${RFW_CFG[countries]:-无}"
            config="网卡=${RFW_CFG[interface]}，GeoIP=$(rfw_display_geo_mode "${RFW_CFG[geo_mode]}")，国家=${countries_display}，邮件=$(rfw_display_switch "${RFW_CFG[block_email]}")，HTTP=$(rfw_display_switch "${RFW_CFG[block_http]}")，SOCKS5=$(rfw_display_switch "${RFW_CFG[block_socks5]}")，WireGuard=$(rfw_display_switch "${RFW_CFG[block_wireguard]}")，QUIC=$(rfw_display_switch "${RFW_CFG[block_quic]}")，全部入站=$(rfw_display_switch "${RFW_CFG[block_all]}")，FET=$(rfw_display_fet "${RFW_CFG[fet]}")，XDP=${RFW_CFG[xdp_mode]}，访问日志=$(rfw_display_switch "${RFW_CFG[log]}")，RUST_LOG=${RFW_CFG[RUST_LOG]}"
            config_style="info"
        else
            config="无效"
            config_style="error"
        fi
    fi
    printf 'RFW 状态\n'
    vps_cmd_status "版本" "$version" "info"
    vps_cmd_status "运行状态" "$active" "$active_style"
    vps_cmd_status "开机启动" "$enabled" "$enabled_style"
    vps_cmd_status "待重启" "$pending" "$pending_style"
    vps_cmd_status "配置" "$config" "$config_style"
    vps_cmd_status "IPv6 警告" "RFW 仅过滤 IPv4，IPv6 流量不受保护" "warning"
}

rfw_stats() {
    local arg blocked=0 allowed=0
    local -a args=(stats)
    while (($#)); do
        arg="$1"
        case "$arg" in
            --port)
                (($# >= 2)) || {
                    rfw_error "--port 需要参数值"
                    return 2
                }
                [[ "$2" =~ ^[0-9]+$ ]] && ((10#$2 >= 1 && 10#$2 <= 65535)) || {
                    rfw_error "端口无效：$2"
                    return 2
                }
                args+=(--port "$2")
                shift 2
                ;;
            --ip)
                (($# >= 2)) || {
                    rfw_error "--ip 需要参数值"
                    return 2
                }
                rfw_valid_ipv4 "$2" || {
                    rfw_error "IPv4 地址无效：$2"
                    return 2
                }
                args+=(--ip "$2")
                shift 2
                ;;
            --blocked-only)
                blocked=1
                args+=("$arg")
                shift
                ;;
            --allowed-only)
                allowed=1
                args+=("$arg")
                shift
                ;;
            --group-by-port)
                args+=("$arg")
                shift
                ;;
            *)
                rfw_error "stats 的未知选项：$arg"
                return 2
                ;;
        esac
    done
    ((blocked == 0 || allowed == 0)) || {
        rfw_error "--blocked-only 与 --allowed-only 不能同时使用"
        return 2
    }
    rfw_require_root || return
    rfw_platform_gate || return
    rfw_require_managed_files || return
    rfw_load_config || return
    [[ "${RFW_CFG[log]}" == "on" ]] || {
        rfw_error "统计信息要求 log-port-access=on"
        return 3
    }
    systemctl is-active --quiet rfw.service || {
        rfw_error "查看统计信息前，rfw.service 必须处于运行状态"
        return 3
    }
    rfw_ensure_dependencies sha256sum || return
    if rfw_stop_after_dependency_plan; then
        return 0
    fi
    rfw_require_managed_install || return
    "$RFW_BINARY" "${args[@]}" || return 20
}

rfw_logs() {
    local arg
    local -a args=(-u rfw.service --no-pager)
    while (($#)); do
        arg="$1"
        case "$arg" in
            -f | --follow)
                args+=(-f)
                shift
                ;;
            -n | --lines)
                (($# >= 2)) || {
                    rfw_error "$arg 需要参数值"
                    return 2
                }
                [[ "$2" =~ ^[0-9]+$ ]] || {
                    rfw_error "日志行数无效：$2"
                    return 2
                }
                args+=(-n "$2")
                shift 2
                ;;
            --since)
                (($# >= 2)) || {
                    rfw_error "--since 需要参数值"
                    return 2
                }
                [[ "$2" != *$'\n'* ]] || {
                    rfw_error "--since 参数值无效"
                    return 2
                }
                args+=(--since "$2")
                shift 2
                ;;
            *)
                rfw_error "logs 的未知选项：$arg"
                return 2
                ;;
        esac
    done
    rfw_platform_gate || return
    command -v journalctl >/dev/null 2>&1 || {
        rfw_error "缺少必需命令 journalctl"
        return 3
    }
    journalctl "${args[@]}" || return 20
}

rfw_confirm_purge() {
    local confirmed="$1" status
    RFW_CONFIRM_APPROVED=0
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
        if [[ "$confirmed" == "1" ]]; then
            RFW_CONFIRM_APPROVED=1
            return 0
        fi
        rfw_error "彻底清除要求显式传入 --confirm-purge"
        return 3
    fi
    if confirm_token "彻底清除会永久删除 RFW 配置、状态与备份；确认清除" "PURGE-RFW"; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    status=$?
    [[ "$status" == "130" ]] && return 130
    rfw_info "已取消彻底清除，未更改任何文件。"
    return 0
}

rfw_uninstall() {
    local purge=0 confirmed=0 arg failed=0 cleanup_port_access_pin=0
    while (($#)); do
        arg="$1"
        case "$arg" in
            --purge)
                purge=1
                shift
                ;;
            --confirm-purge)
                confirmed=1
                shift
                ;;
            *)
                rfw_error "uninstall 的未知选项：$arg"
                return 2
                ;;
        esac
    done
    rfw_require_root || return
    rfw_platform_gate || return
    if ((purge)); then
        rfw_confirm_purge "$confirmed" || return
        [[ "$RFW_CONFIRM_APPROVED" == "1" ]] || return 0
    fi
    if [[ -e "$RFW_UNIT" ]] && ! rfw_is_managed_file "$RFW_UNIT"; then
        rfw_error "拒绝卸载不受管的 rfw.service 单元"
        return 3
    fi
    if [[ -e "$RFW_BINARY" && ! -e "$RFW_UNIT" ]]; then
        rfw_error "拒绝删除不受管的 RFW 二进制"
        return 3
    fi
    if ((purge)) && [[ -e "$RFW_CONFIG" ]] && ! rfw_is_managed_file "$RFW_CONFIG"; then
        rfw_error "拒绝彻底清除不受管的 RFW 配置"
        return 3
    fi
    if [[ -e "$RFW_UNIT" ]] && rfw_unit_uses_port_access_log; then
        cleanup_port_access_pin=1
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != "1" ]]; then
        rfw_ensure_dependencies flock || return
        if rfw_stop_after_dependency_plan; then
            return 0
        fi
    fi
    rfw_take_lock || return
    if systemctl is-active --quiet rfw.service >/dev/null 2>&1; then run systemctl stop rfw.service || failed=1; fi
    if systemctl is-enabled --quiet rfw.service >/dev/null 2>&1; then run systemctl disable rfw.service || failed=1; fi
    if ((cleanup_port_access_pin)); then run rm -f -- "$RFW_PORT_ACCESS_PIN" || failed=1; fi
    run rm -f "$RFW_UNIT" "$RFW_BINARY" || failed=1
    if ((purge)); then
        run rm -f "$RFW_CONFIG" "$RFW_METADATA" "$RFW_PENDING" "$RFW_LKG_CONFIG" || failed=1
        [[ ! -d "$RFW_STATE_DIR" ]] || run rmdir "$RFW_STATE_DIR" || failed=1
        [[ ! -d "$RFW_BACKUP_ROOT" ]] || run rm -rf "$RFW_BACKUP_ROOT" || failed=1
    fi
    run systemctl daemon-reload || failed=1
    if ((purge)); then
        rfw_success "RFW 二进制、systemd 单元、配置、受管状态与备份已清除。"
    else
        rfw_success "RFW 二进制和 systemd 单元已删除；配置、状态与备份均已保留。"
    fi
    ((failed == 0)) || return 30
}

rfw_menu_start() {
    local choice
    choice="$(vps_cmd_prompt_select "启动方式" start \
        start "仅启动（推荐）" enable "启动并启用开机启动")" || return $?
    if [[ "$choice" == "enable" ]]; then
        rfw_service_start --enable
    else
        rfw_service_start
    fi
}

rfw_menu_stop() {
    local choice
    choice="$(vps_cmd_prompt_select "停止方式" stop \
        stop "仅停止（推荐）" disable "停止并禁用开机启动")" || return $?
    if [[ "$choice" == "disable" ]]; then
        rfw_service_stop --disable
    else
        rfw_service_stop
    fi
}

rfw_menu_stats() {
    local filter port_mode port ip_mode ip group
    local -a args=()

    filter="$(vps_cmd_prompt_select "统计筛选" all \
        all "全部流量（推荐）" blocked "仅已阻止" allowed "仅已允许")" || return $?
    case "$filter" in
        blocked) args+=(--blocked-only) ;;
        allowed) args+=(--allowed-only) ;;
    esac
    port_mode="$(vps_cmd_prompt_select "端口筛选" none \
        none "不限端口（推荐）" input "输入端口")" || return $?
    if [[ "$port_mode" == "input" ]]; then
        while true; do
            port="$(vps_cmd_prompt_value "端口（1-65535）" "")" || return $?
            if [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535)); then
                args+=(--port "$port")
                break
            fi
            rfw_warning "端口无效，请重新输入"
        done
    fi
    ip_mode="$(vps_cmd_prompt_select "IPv4 筛选" none \
        none "不限地址（推荐）" input "输入 IPv4 地址")" || return $?
    if [[ "$ip_mode" == "input" ]]; then
        while true; do
            ip="$(vps_cmd_prompt_value "IPv4 地址" "")" || return $?
            if rfw_valid_ipv4 "$ip"; then
                args+=(--ip "$ip")
                break
            fi
            rfw_warning "IPv4 地址无效，请重新输入"
        done
    fi
    group="$(vps_cmd_prompt_select "是否按端口分组" no \
        no "否（推荐）" yes "是")" || return $?
    [[ "$group" == "no" ]] || args+=(--group-by-port)
    rfw_stats "${args[@]}"
}

rfw_menu_logs() {
    local lines follow since_mode since
    local -a args=()

    lines="$(vps_cmd_prompt_select "日志行数" 100 \
        50 "50 行" 100 "100 行（推荐）" 200 "200 行" 500 "500 行" input "手动输入")" || return $?
    if [[ "$lines" == "input" ]]; then
        while true; do
            lines="$(vps_cmd_prompt_value "日志行数（0-1000000）" "100")" || return $?
            if [[ "$lines" =~ ^[0-9]+$ && ${#lines} -le 7 ]] && ((10#$lines <= 1000000)); then
                break
            fi
            rfw_warning "日志行数无效，请重新输入"
        done
    fi
    args+=(--lines "$lines")
    follow="$(vps_cmd_prompt_select "是否持续跟随新日志" no \
        no "否（推荐）" yes "是")" || return $?
    [[ "$follow" == "no" ]] || args+=(--follow)
    since_mode="$(vps_cmd_prompt_select "日志起始时间" none \
        none "不限制（推荐）" input "输入 journalctl --since 值")" || return $?
    if [[ "$since_mode" == "input" ]]; then
        while true; do
            since="$(vps_cmd_prompt_value "起始时间（例如 today 或 1 hour ago）" "today")" || return $?
            if [[ -n "$since" && "$since" != *$'\n'* && "$since" != *$'\r'* ]]; then
                args+=(--since "$since")
                break
            fi
            rfw_warning "起始时间不能为空且不能包含换行"
        done
    fi
    rfw_logs "${args[@]}"
}

rfw_menu_uninstall() {
    local choice
    choice="$(vps_cmd_prompt_select "卸载方式" keep \
        keep "保留配置、状态与备份（推荐）" purge "彻底清除")" || return $?
    if [[ "$choice" == "purge" ]]; then
        rfw_uninstall --purge
    else
        rfw_uninstall
    fi
}

rfw_menu_action() {
    local status=0
    "$@" || status=$?
    rfw_unlock
    [[ "$status" == "130" ]] && return 0
    return "$status"
}

rfw_menu() {
    local choice status=0 prompt_status
    while true; do
        printf '\nRFW 管理\n'
        choice="$(vps_cmd_prompt_select "请选择功能" "" \
            status "查看状态" install "安装" update "更新" configure "配置" \
            start "启动" stop "停止" restart "重启" stats "访问统计" \
            logs "日志" uninstall "卸载")" || {
                prompt_status=$?
                [[ "$prompt_status" == "130" ]] && return "$status"
                return "$prompt_status"
            }
        case "$choice" in
            status) rfw_menu_action rfw_status || status=$? ;;
            install) rfw_menu_action rfw_install_or_update install || status=$? ;;
            update) rfw_menu_action rfw_install_or_update update || status=$? ;;
            configure) rfw_menu_action rfw_configure || status=$? ;;
            start) rfw_menu_action rfw_menu_start || status=$? ;;
            stop) rfw_menu_action rfw_menu_stop || status=$? ;;
            restart) rfw_menu_action rfw_service_restart || status=$? ;;
            stats) rfw_menu_action rfw_menu_stats || status=$? ;;
            logs) rfw_menu_action rfw_menu_logs || status=$? ;;
            uninstall) rfw_menu_action rfw_menu_uninstall || status=$? ;;
        esac
    done
}

rfw_main() {
    local action
    rfw_parse_global_options "$@" || return
    set -- "${RFW_ARGS[@]}"
    if (($# == 0)); then
        if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == "0" && -t 0 && -t 1 ]]; then
            rfw_menu
        else
            rfw_status
        fi
        return
    fi
    action="$1"
    shift
    case "$action" in
        status)
            (($# == 0)) || {
                rfw_error "status 不接受选项"
                return 2
            }
            rfw_status
            ;;
        install) rfw_install_or_update install "$@" ;;
        update) rfw_install_or_update update "$@" ;;
        configure) rfw_configure "$@" ;;
        start) rfw_service_start "$@" ;;
        stop) rfw_service_stop "$@" ;;
        restart) rfw_service_restart "$@" ;;
        stats) rfw_stats "$@" ;;
        logs) rfw_logs "$@" ;;
        uninstall) rfw_uninstall "$@" ;;
        help | -h | --help) rfw_usage ;;
        *)
            rfw_error "未知动作：$action"
            rfw_usage >&2
            return 2
            ;;
    esac
}

rfw_main "$@"
