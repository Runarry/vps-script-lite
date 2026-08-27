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
RFW_BINARY="$(system_path /usr/local/bin/rfw)"
RFW_CONFIG="$(system_path /etc/vpsctl/rfw.conf)"
RFW_UNIT="$(system_path /etc/systemd/system/rfw.service)"
RFW_STATE_DIR="$(system_path /var/lib/vpsctl/network/rfw)"
readonly RFW_BINARY RFW_CONFIG RFW_UNIT RFW_STATE_DIR
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

rfw_error() { printf 'rfw: %s\n' "$*" >&2; }
rfw_info() { [[ "${VPSCTL_QUIET:-0}" == "1" ]] || printf '%s\n' "$*"; }

rfw_usage() {
    cat <<'EOF'
Manage the narwhal-cloud/rfw XDP firewall.

Usage:
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

Configuration options (unspecified values keep their current setting):
  --iface NAME
  --geo-mode none|blocklist|whitelist
  --countries CC[,CC...]
  --block-email on|off       --block-http on|off
  --block-socks5 on|off      --block-wireguard on|off
  --block-quic on|off        --block-all on|off
  --fet off|loose|strict     --xdp-mode auto|skb|drv|hw
  --log-port-access on|off   --rust-log LEVEL

With no arguments a terminal gets a submenu; non-interactive use shows status.
RFW currently filters IPv4 only. block-all and FET strict always require the
  literal token APPLY-RFW in a terminal; non-interactive callers must pass the
  explicit --confirm-disruptive flag. --yes never approves those settings.

Global options (must precede the action):
  --dry-run  --yes  --non-interactive  --quiet  --verbose  --
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
        rfw_error "RFW is supported on Linux only"
        return 3
    }
    if [[ -n "${VPSCTL_ENV_INIT:-}" && "${VPSCTL_ENV_INIT}" != "systemd" ]]; then
        rfw_error "RFW management requires systemd"
        return 3
    fi
    command -v systemctl >/dev/null 2>&1 || {
        rfw_error "systemctl is required"
        return 3
    }
    if [[ -z "${VPSCTL_ENV_INIT:-}" && ! -d "$(system_path /run/systemd/system)" ]]; then
        rfw_error "RFW management requires a running systemd instance"
        return 3
    fi

    case "$arch" in
        x86_64 | amd64) printf 'x86_64-unknown-linux-musl\n' ;;
        aarch64 | arm64) printf 'aarch64-unknown-linux-musl\n' ;;
        *)
            rfw_error "unsupported architecture: ${arch:-unknown} (expected x86_64 or aarch64)"
            return 3
            ;;
    esac
}

rfw_parse_global_options() {
    RFW_ARGS=()
    while (($#)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            -h | --help)
                (($# == 1)) || {
                    rfw_error "$1 does not accept additional arguments"
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
                rfw_error "unknown global option: $1"
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
            rfw_error "configuration is missing key: $key"
            return 10
        }
    done
    rfw_valid_interface "${RFW_CFG[interface]}" || {
        rfw_error "invalid interface: ${RFW_CFG[interface]}"
        return 10
    }
    rfw_valid_geo_mode "${RFW_CFG[geo_mode]}" || {
        rfw_error "invalid geo_mode: ${RFW_CFG[geo_mode]}"
        return 10
    }
    for key in block_email block_http block_socks5 block_wireguard block_quic block_all log; do
        rfw_valid_switch "${RFW_CFG[$key]}" || {
            rfw_error "${key} must be on or off"
            return 10
        }
    done
    rfw_valid_fet "${RFW_CFG[fet]}" || {
        rfw_error "fet must be off, loose, or strict"
        return 10
    }
    rfw_valid_xdp "${RFW_CFG[xdp_mode]}" || {
        rfw_error "xdp_mode must be auto, skb, drv, or hw"
        return 10
    }
    rfw_valid_rust_log "${RFW_CFG[RUST_LOG]}" || {
        rfw_error "invalid RUST_LOG expression"
        return 10
    }
    countries="$(rfw_normalize_countries "${RFW_CFG[countries]}")" || {
        rfw_error "countries must be unique comma-separated ISO alpha-2 codes"
        return 10
    }
    RFW_CFG[countries]="$countries"
    if [[ "${RFW_CFG[geo_mode]}" == "none" && -n "$countries" ]]; then
        rfw_error "countries must be empty when geo_mode is none"
        return 10
    fi
    if [[ "${RFW_CFG[geo_mode]}" != "none" && -z "$countries" ]]; then
        rfw_error "countries is required for blocklist and whitelist modes"
        return 10
    fi
}

rfw_load_config_file() {
    local file="$1" line key value line_number=0 first required
    local -A seen=()
    rfw_defaults
    [[ -r "$file" ]] || return 1
    [[ ! -L "$file" ]] || {
        rfw_error "configuration must not be a symbolic link: $file"
        return 10
    }
    IFS= read -r first <"$file" || {
        rfw_error "configuration is empty: $file"
        return 10
    }
    [[ "${first%$'\r'}" == "$RFW_MANAGED_MARKER" ]] || {
        rfw_error "configuration is not vpsctl-managed: $file"
        return 10
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=([^[:space:]]*)$ ]]; then
            rfw_error "invalid configuration syntax at ${file}:${line_number}"
            return 10
        fi
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        case "$key" in
            interface | geo_mode | countries | block_email | block_http | block_socks5 | block_wireguard | block_quic | block_all | fet | xdp_mode | log | RUST_LOG) ;;
            *)
                rfw_error "unknown configuration key '${key}' at ${file}:${line_number}"
                return 10
                ;;
        esac
        [[ ${seen[$key]+present} != present ]] || {
            rfw_error "duplicate configuration key '${key}'"
            return 10
        }
        seen[$key]=1
        RFW_CFG[$key]="$value"
    done <"$file"
    for required in interface geo_mode countries block_email block_http block_socks5 block_wireguard block_quic block_all fet xdp_mode log RUST_LOG; do
        [[ ${seen[$required]+present} == present ]] || {
            rfw_error "configuration is missing key: $required"
            return 10
        }
    done
    rfw_validate_config
}

rfw_load_config() {
    rfw_load_config_file "$RFW_CONFIG" || {
        local status=$?
        if [[ "$status" == "1" ]]; then
            rfw_error "RFW configuration is not installed"
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
    release="${release%%-*}"
    if [[ ! "$release" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]]; then
        rfw_error "unable to validate kernel release: ${release:-unknown}"
        return 3
    fi
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    if ((major < 5 || (major == 5 && minor < 15))); then
        rfw_error "RFW requires Linux kernel 5.15 or newer (found ${release})"
        return 3
    fi
}

rfw_runtime_preflight() {
    rfw_platform_target >/dev/null || return
    rfw_kernel_supported || return
    command -v ip >/dev/null 2>&1 || {
        rfw_error "ip is required to validate the configured interface"
        return 3
    }
    ip link show dev "${RFW_CFG[interface]}" >/dev/null 2>&1 || {
        rfw_error "configured interface does not exist: ${RFW_CFG[interface]}"
        return 3
    }
    if [[ "${RFW_CFG[log]}" == "on" ]]; then
        command -v mountpoint >/dev/null 2>&1 || {
            rfw_error "mountpoint is required to validate bpffs"
            return 3
        }
        mountpoint -q "$(system_path /sys/fs/bpf)" || {
            rfw_error "port logging requires bpffs mounted at /sys/fs/bpf"
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
    printf '# Values are parsed as data; this file is never sourced.\n'
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
Description=RFW eBPF/XDP Firewall
Documentation=https://github.com/narwhal-cloud/rfw
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment=RUST_LOG=${RFW_CFG[RUST_LOG]}
ExecStart=${exec_start}
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
    rfw_error "a complete vpsctl-managed RFW installation is required"
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
        rfw_error "refusing to overwrite unmanaged RFW files; pass --force explicitly"
        return 3
    fi
    if confirm_token "Unmanaged RFW files exist. Type OVERWRITE-RFW to replace them" "OVERWRITE-RFW"; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    status=$?
    [[ "$status" == "130" ]] && return 130
    rfw_info "Installation cancelled; no files were changed."
    return 0
}

rfw_release_tag() {
    local json_file="$1" tag draft prerelease
    tag="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$json_file" | head -n 1)"
    draft="$(sed -n 's/.*"draft"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$json_file" | head -n 1)"
    prerelease="$(sed -n 's/.*"prerelease"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' "$json_file" | head -n 1)"
    [[ "$draft" == "false" && "$prerelease" == "false" ]] || {
        rfw_error "latest release metadata is missing stable draft/prerelease assertions"
        return 20
    }
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        rfw_error "latest stable release has an invalid tag: ${tag:-missing}"
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
                    rfw_error "duplicate checksum entry for ${asset}"
                    return 20
                }
                found="$hash"
            fi
        fi
    done <"$checksums"
    [[ -n "$found" ]] || {
        rfw_error "checksums.txt has no exact entry for ${asset}"
        return 20
    }
    printf '%s\n' "$found"
}

rfw_fetch_binary() {
    local output="$1" target tag tag_version binary_version asset expected actual tmp_dir json checksums version_output
    command -v curl >/dev/null 2>&1 || {
        rfw_error "curl is required"
        return 3
    }
    command -v sha256sum >/dev/null 2>&1 || {
        rfw_error "sha256sum is required"
        return 3
    }
    target="$(rfw_platform_target)" || return
    asset="rfw-${target}"
    tmp_dir="$(dirname -- "$output")"
    json="${tmp_dir}/release.json"
    checksums="${tmp_dir}/checksums.txt"

    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 15 --max-time 120 -o "$json" "$RFW_RELEASE_API" || {
        rfw_error "failed to query latest RFW release"
        return 20
    }
    tag="$(rfw_release_tag "$json")" || return
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 15 --max-time 300 -o "$output" \
        "https://github.com/${RFW_REPOSITORY}/releases/download/${tag}/${asset}" || {
        rfw_error "failed to download ${asset}"
        return 20
    }
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 15 --max-time 120 -o "$checksums" \
        "https://github.com/${RFW_REPOSITORY}/releases/download/${tag}/checksums.txt" || {
        rfw_error "failed to download checksums.txt"
        return 20
    }
    expected="$(rfw_expected_checksum "$checksums" "$asset")" || return
    actual="$(sha256sum "$output")" || {
        rfw_error "sha256sum failed"
        return 20
    }
    actual="${actual%%[[:space:]]*}"
    actual="${actual,,}"
    if [[ ! "$actual" =~ ^[0-9a-f]{64}$ || "$actual" != "$expected" ]]; then
        rfw_error "checksum verification failed for ${asset}"
        return 20
    fi
    chmod 0755 -- "$output" || {
        rfw_error "failed to make downloaded RFW executable"
        return 20
    }
    version_output="$("$output" --version 2>/dev/null)" || {
        rfw_error "downloaded RFW failed its --version smoke test"
        return 20
    }
    binary_version="$(sed -n 's/.*\(^\|[^0-9]\)\(v\{0,1\}[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\([^0-9].*\|$\)/\2/p' <<<"$version_output" | head -n 1)"
    tag_version="${tag#v}"
    binary_version="${binary_version#v}"
    [[ -n "$binary_version" && "$binary_version" == "$tag_version" ]] || {
        rfw_error "downloaded binary version '${binary_version:-unknown}' does not match release ${tag}"
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
        rfw_info "DRY-RUN: mark RFW changes pending (${reason})"
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
        rfw_info "DRY-RUN: write validated configuration and systemd unit"
        [[ "$reload" == "0" ]] || run systemctl daemon-reload
        return 0
    fi
    rfw_emit_config | atomic_write "$RFW_CONFIG" 0600 || return 20
    rfw_emit_unit | atomic_write "$RFW_UNIT" 0644 || return 20
    if [[ "$reload" != "0" ]]; then run systemctl daemon-reload || return 20; fi
}

rfw_install_or_update() {
    local action="$1" force=0 arg tmp_dir downloaded status
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
                rfw_error "unknown ${action} option: $arg"
                return 2
                ;;
        esac
        shift
    done
    rfw_require_root || return
    rfw_platform_target >/dev/null || return
    if [[ "$action" == "install" ]] && rfw_is_managed_install; then
        rfw_info "RFW is already installed and verified; no changes are required."
        return 0
    fi
    if [[ -L "$RFW_BINARY" || -L "$RFW_CONFIG" || -L "$RFW_UNIT" ]]; then
        rfw_error "refusing to operate on symbolic-link RFW artifacts"
        return 3
    fi
    if [[ "$action" == "update" ]]; then
        rfw_require_managed_install || return
        rfw_validate_pending_backups || return
    else
        rfw_confirm_overwrite "$force" || return
        [[ "$RFW_CONFIRM_APPROVED" == "1" ]] || return 0
        if [[ "$force" == "0" ]] && rfw_install_owned && [[ -e "$RFW_BINARY" && -e "$RFW_UNIT" && -e "$RFW_CONFIG" ]]; then
            rfw_error "RFW is already installed; use update to replace the managed binary"
            return 3
        fi
    fi

    rfw_take_lock
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        rfw_info "DRY-RUN: fetch, verify, and atomically install the latest RFW release"
        rfw_info "DRY-RUN: write ${RFW_CONFIG} and ${RFW_UNIT}; service state is unchanged"
        return 0
    fi

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-rfw.XXXXXX")" || {
        rfw_error "failed to create a temporary download directory"
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
            rfw_info "RFW ${RFW_META_TAG} is already current; no changes are required."
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
    rfw_info "RFW ${RFW_FETCHED_TAG} installed atomically. The service was not started or restarted."
    [[ -n "$binary_backup" ]] && rfw_info "Previous binary preserved at: $binary_backup"
    return 0
}

rfw_prompt_value() {
    local key="$1" prompt="$2" current value
    current="${RFW_CFG[$key]}"
    printf '%s [%s]: ' "$prompt" "${current:-empty}"
    IFS= read -r value || return 1
    if [[ "$value" == "-" ]]; then
        RFW_CFG[$key]=""
    elif [[ -n "$value" ]]; then
        RFW_CFG[$key]="$value"
    fi
}

rfw_configure_wizard() {
    rfw_info "RFW configuration wizard. Press Enter to keep the displayed value."
    rfw_prompt_value interface "Network interface" || return
    rfw_prompt_value geo_mode "Geo mode (none/blocklist/whitelist)" || return
    rfw_prompt_value countries "Countries (comma-separated; '-' clears)" || return
    rfw_prompt_value block_email "Block outbound email (on/off)" || return
    rfw_prompt_value block_http "Block HTTP (on/off)" || return
    rfw_prompt_value block_socks5 "Block SOCKS5 (on/off)" || return
    rfw_prompt_value block_wireguard "Block WireGuard (on/off)" || return
    rfw_prompt_value block_quic "Block QUIC (on/off)" || return
    rfw_prompt_value block_all "Block all inbound traffic (on/off)" || return
    rfw_prompt_value fet "FET mode (off/loose/strict)" || return
    rfw_prompt_value xdp_mode "XDP mode (auto/skb/drv/hw)" || return
    rfw_prompt_value log "Port access logging (on/off)" || return
    rfw_prompt_value RUST_LOG "Rust log level" || return
}

rfw_configure() {
    local changed=0 config_backup="" unit_backup="" previous_binary_backup="" previous_config_backup="" previous_metadata_backup="" pending_config_backup="" key value new_config new_unit
    rfw_require_root || return
    rfw_platform_target >/dev/null || return
    rfw_require_managed_install || return
    rfw_validate_pending_backups || return
    rfw_load_config || return

    while (($#)); do
        key="$1"
        case "$key" in
            --iface | --geo-mode | --countries | --block-email | --block-http | --block-socks5 | --block-wireguard | --block-quic | --block-all | --fet | --xdp-mode | --log-port-access | --rust-log)
                (($# >= 2)) || {
                    rfw_error "missing value for $key"
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
                rfw_error "unknown configure option: $key"
                return 2
                ;;
        esac
    done
    if [[ "$changed" == "0" ]]; then
        if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
            rfw_error "configure without options requires an interactive terminal"
            return 2
        fi
        if ! rfw_configure_wizard; then
            rfw_info "Configuration cancelled; no files were changed."
            return 0
        fi
    fi
    rfw_validate_config || return
    new_config="$(rfw_emit_config)"
    new_unit="$(rfw_emit_unit)"
    if cmp -s <(printf '%s\n' "$new_config") "$RFW_CONFIG" && cmp -s <(printf '%s\n' "$new_unit") "$RFW_UNIT"; then
        rfw_info "RFW configuration already matches the requested values; no changes are required."
        return 0
    fi
    rfw_take_lock
    previous_binary_backup="$(rfw_pending_value binary_backup 2>/dev/null || true)"
    previous_config_backup="$(rfw_pending_value config_backup 2>/dev/null || true)"
    previous_metadata_backup="$(rfw_pending_value metadata_backup 2>/dev/null || true)"
    if [[ -n "$previous_binary_backup" ]] && ! rfw_safe_backup_file "$previous_binary_backup"; then
        rfw_error "pending binary backup is outside the managed backup root or unsafe"
        return 3
    fi
    if [[ -n "$previous_config_backup" ]] && ! rfw_safe_backup_file "$previous_config_backup"; then
        rfw_error "pending configuration backup is outside the managed backup root or unsafe"
        return 3
    fi
    if [[ -n "$previous_metadata_backup" ]] && ! rfw_safe_backup_file "$previous_metadata_backup"; then
        rfw_error "pending metadata backup is outside the managed backup root or unsafe"
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
    rfw_info "RFW configuration saved. Restart is pending; the running service was not changed."
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
        rfw_error "disruptive policy requires the explicit --confirm-disruptive flag"
        return 3
    fi
    if confirm_token "This policy can block legitimate or all inbound traffic. Type APPLY-RFW" "APPLY-RFW"; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    status=$?
    [[ "$status" == "130" ]] && return 130
    rfw_info "Start cancelled; no service state was changed."
    return 0
}

rfw_save_lkg() {
    run mkdir -p "$RFW_STATE_DIR"
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        rfw_info "DRY-RUN: record last-known-good RFW configuration and clear pending marker"
        return 0
    fi
    atomic_write "$RFW_LKG_CONFIG" 0600 <"$RFW_CONFIG" || return 20
    run rm -f "$RFW_PENDING" || return 20
}

rfw_validate_pending_backups() {
    local backup binary_backup metadata_backup reason
    [[ ! -e "$RFW_PENDING" ]] && return 0
    [[ -f "$RFW_PENDING" && ! -L "$RFW_PENDING" ]] || {
        rfw_error "pending marker is unsafe"
        return 3
    }
    reason="$(rfw_pending_value reason 2>/dev/null)" || {
        rfw_error "pending marker is invalid"
        return 3
    }
    binary_backup="$(rfw_pending_value binary_backup 2>/dev/null)" || {
        rfw_error "pending marker is invalid"
        return 3
    }
    [[ -z "$binary_backup" ]] || rfw_safe_backup_file "$binary_backup" || {
        rfw_error "pending binary backup is unsafe"
        return 3
    }
    backup="$(rfw_pending_value config_backup 2>/dev/null)" || {
        rfw_error "pending marker is invalid"
        return 3
    }
    [[ -z "$backup" ]] || rfw_safe_backup_file "$backup" || {
        rfw_error "pending configuration backup is unsafe"
        return 3
    }
    metadata_backup="$(rfw_pending_value metadata_backup 2>/dev/null)" || {
        rfw_error "pending marker is invalid"
        return 3
    }
    [[ -z "$metadata_backup" ]] || rfw_safe_backup_file "$metadata_backup" || {
        rfw_error "pending metadata backup is unsafe"
        return 3
    }
    if [[ "$reason" == "update" && (-z "$binary_backup" || -z "$metadata_backup") ]]; then
        rfw_error "update pending marker lacks binary or metadata rollback state"
        return 3
    fi
    if [[ (-n "$binary_backup" && -z "$metadata_backup") || (-z "$binary_backup" && -n "$metadata_backup") ]]; then
        rfw_error "pending binary/metadata rollback state is inconsistent"
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
                rfw_error "unknown start option: $arg"
                return 2
                ;;
        esac
    done
    rfw_require_root || return
    rfw_require_managed_install || return
    rfw_load_config || return
    rfw_has_effective_policy || {
        rfw_error "refusing to start without any filtering rule or port logging enabled"
        return 3
    }
    rfw_runtime_preflight || return
    rfw_validate_pending_backups || return
    if systemctl is-active --quiet rfw.service && [[ -e "$RFW_PENDING" ]]; then
        rfw_error "RFW is already active with pending changes; use restart to apply them safely"
        return 3
    fi
    rfw_require_disruptive_confirmation "$confirmed" || return
    [[ "$RFW_CONFIRM_APPROVED" == "1" ]] || return 0
    rfw_take_lock
    if systemctl is-active --quiet rfw.service; then
        if ((enable)) && ! systemctl is-enabled --quiet rfw.service; then
            run systemctl enable rfw.service || return 20
        fi
        rfw_info "RFW is already active; no restart was performed."
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
    rfw_info "RFW started successfully."
}

rfw_service_stop() {
    local disable=0
    while (($#)); do
        case "$1" in
            --disable) disable=1 ;;
            *)
                rfw_error "unknown stop option: $1"
                return 2
                ;;
        esac
        shift
    done
    rfw_require_root || return
    rfw_platform_target >/dev/null || return
    rfw_take_lock
    run systemctl stop rfw.service || return 20
    if ((disable)); then
        run systemctl disable rfw.service || return 20
    fi
    rfw_info "RFW stopped."
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
                rfw_error "unknown restart option: $arg"
                return 2
                ;;
        esac
    done
    rfw_require_root || return
    rfw_require_managed_install || return
    rfw_load_config || return
    rfw_has_effective_policy || {
        rfw_error "refusing to restart without any filtering rule or port logging enabled"
        return 3
    }
    rfw_runtime_preflight || return
    rfw_validate_pending_backups || return
    rfw_require_disruptive_confirmation "$confirmed" || return
    [[ "$RFW_CONFIRM_APPROVED" == "1" ]] || return 0
    rfw_take_lock
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        run systemctl daemon-reload
        run systemctl restart rfw.service
        rfw_save_lkg
        return 0
    fi
    run systemctl daemon-reload || return 20
    if run systemctl restart rfw.service && systemctl is-active --quiet rfw.service; then
        if ! rfw_save_lkg; then return 30; fi
        rfw_info "RFW restarted; pending configuration and binary are now active."
    else
        if [[ -e "$RFW_PENDING" ]]; then
            if rfw_restore_pending restart; then
                rfw_error "restart failed; restored and started the previous RFW version"
                return 20
            fi
            rfw_error "restart failed and rollback was incomplete"
            return 30
        fi
        if systemctl is-active --quiet rfw.service; then
            return 20
        fi
        rfw_error "restart failed and RFW is now inactive"
        return 30
    fi
}

rfw_status() {
    local version="not installed or unmanaged" active="not installed" enabled="not installed" pending="no" config="not installed" pending_reason=""
    if rfw_is_managed_install; then
        version="$("$RFW_BINARY" --version 2>/dev/null | head -n 1 || printf 'installed (version unavailable)') [${RFW_META_TAG}]"
        active="$(systemctl is-active rfw.service 2>/dev/null || true)"
        enabled="$(systemctl is-enabled rfw.service 2>/dev/null || true)"
        [[ -n "$active" ]] || active="unknown"
        [[ -n "$enabled" ]] || enabled="unknown"
    fi
    if [[ -e "$RFW_PENDING" ]]; then
        pending_reason="$(rfw_pending_value reason 2>/dev/null || true)"
        pending="yes${pending_reason:+ (${pending_reason})}"
    fi
    if rfw_is_managed_file "$RFW_CONFIG"; then
        if rfw_load_config_file "$RFW_CONFIG" 2>/dev/null; then
            config="interface=${RFW_CFG[interface]}, geo=${RFW_CFG[geo_mode]}${RFW_CFG[countries]:+(${RFW_CFG[countries]})}, email=${RFW_CFG[block_email]}, http=${RFW_CFG[block_http]}, socks5=${RFW_CFG[block_socks5]}, wireguard=${RFW_CFG[block_wireguard]}, quic=${RFW_CFG[block_quic]}, all=${RFW_CFG[block_all]}, fet=${RFW_CFG[fet]}, xdp=${RFW_CFG[xdp_mode]}, log=${RFW_CFG[log]}, RUST_LOG=${RFW_CFG[RUST_LOG]}"
        else
            config="invalid"
        fi
    fi
    printf 'RFW status\n'
    printf '  Version:   %s\n' "$version"
    printf '  Service:   %s\n' "$active"
    printf '  Autostart: %s\n' "$enabled"
    printf '  Pending:   %s\n' "$pending"
    printf '  Config:    %s\n' "$config"
    printf '  Warning: RFW filters IPv4 only; IPv6 traffic is not protected.\n'
}

rfw_stats() {
    local arg blocked=0 allowed=0
    local -a args=(stats)
    rfw_require_root || return
    rfw_platform_target >/dev/null || return
    rfw_require_managed_install || return
    systemctl is-active --quiet rfw.service || {
        rfw_error "RFW service must be active to read statistics"
        return 3
    }
    rfw_load_config || return
    [[ "${RFW_CFG[log]}" == "on" ]] || {
        rfw_error "statistics require log-port-access=on"
        return 3
    }
    while (($#)); do
        arg="$1"
        case "$arg" in
            --port)
                (($# >= 2)) || {
                    rfw_error "--port requires a value"
                    return 2
                }
                [[ "$2" =~ ^[0-9]+$ ]] && ((10#$2 >= 1 && 10#$2 <= 65535)) || {
                    rfw_error "invalid port: $2"
                    return 2
                }
                args+=(--port "$2")
                shift 2
                ;;
            --ip)
                (($# >= 2)) || {
                    rfw_error "--ip requires a value"
                    return 2
                }
                rfw_valid_ipv4 "$2" || {
                    rfw_error "invalid IPv4 address: $2"
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
                rfw_error "unknown stats option: $arg"
                return 2
                ;;
        esac
    done
    ((blocked == 0 || allowed == 0)) || {
        rfw_error "--blocked-only and --allowed-only are mutually exclusive"
        return 2
    }
    "$RFW_BINARY" "${args[@]}" || return 20
}

rfw_logs() {
    local arg
    local -a args=(-u rfw.service --no-pager)
    rfw_platform_target >/dev/null || return
    while (($#)); do
        arg="$1"
        case "$arg" in
            -f | --follow)
                args+=(-f)
                shift
                ;;
            -n | --lines)
                (($# >= 2)) || {
                    rfw_error "$arg requires a value"
                    return 2
                }
                [[ "$2" =~ ^[0-9]+$ ]] || {
                    rfw_error "invalid line count: $2"
                    return 2
                }
                args+=(-n "$2")
                shift 2
                ;;
            --since)
                (($# >= 2)) || {
                    rfw_error "--since requires a value"
                    return 2
                }
                [[ "$2" != *$'\n'* ]] || {
                    rfw_error "invalid --since value"
                    return 2
                }
                args+=(--since "$2")
                shift 2
                ;;
            *)
                rfw_error "unknown logs option: $arg"
                return 2
                ;;
        esac
    done
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
        rfw_error "--purge requires the explicit --confirm-purge flag"
        return 3
    fi
    if confirm_token "Purge permanently deletes the RFW configuration. Type PURGE-RFW" "PURGE-RFW"; then
        RFW_CONFIRM_APPROVED=1
        return 0
    fi
    status=$?
    [[ "$status" == "130" ]] && return 130
    rfw_info "Purge cancelled; no files were changed."
    return 0
}

rfw_uninstall() {
    local purge=0 confirmed=0 arg failed=0
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
                rfw_error "unknown uninstall option: $arg"
                return 2
                ;;
        esac
    done
    rfw_require_root || return
    rfw_platform_target >/dev/null || return
    if ((purge)); then
        rfw_confirm_purge "$confirmed" || return
        [[ "$RFW_CONFIRM_APPROVED" == "1" ]] || return 0
    fi
    if [[ -e "$RFW_UNIT" ]] && ! rfw_is_managed_file "$RFW_UNIT"; then
        rfw_error "refusing to uninstall an unmanaged rfw.service unit"
        return 3
    fi
    if [[ -e "$RFW_BINARY" && ! -e "$RFW_UNIT" ]]; then
        rfw_error "refusing to remove an unowned RFW binary"
        return 3
    fi
    if ((purge)) && [[ -e "$RFW_CONFIG" ]] && ! rfw_is_managed_file "$RFW_CONFIG"; then
        rfw_error "refusing to purge an unmanaged RFW configuration"
        return 3
    fi
    rfw_take_lock
    if systemctl is-active --quiet rfw.service >/dev/null 2>&1; then run systemctl stop rfw.service || failed=1; fi
    if systemctl is-enabled --quiet rfw.service >/dev/null 2>&1; then run systemctl disable rfw.service || failed=1; fi
    run rm -f "$RFW_UNIT" "$RFW_BINARY" || failed=1
    if ((purge)); then
        run rm -f "$RFW_CONFIG" "$RFW_METADATA" "$RFW_PENDING" "$RFW_LKG_CONFIG" || failed=1
        [[ ! -d "$RFW_STATE_DIR" ]] || run rmdir "$RFW_STATE_DIR" || failed=1
        [[ ! -d "$RFW_BACKUP_ROOT" ]] || run rm -rf "$RFW_BACKUP_ROOT" || failed=1
    fi
    run systemctl daemon-reload || failed=1
    if ((purge)); then
        rfw_info "RFW binary, unit, configuration, and managed state removed."
    else
        rfw_info "RFW binary and unit removed; configuration, state, and backups were retained."
    fi
    ((failed == 0)) || return 30
}

rfw_menu() {
    local choice
    while true; do
        cat <<'EOF'

RFW management
  1) Status       2) Install      3) Update
  4) Configure    5) Start        6) Stop
  7) Restart      8) Stats        9) Logs
 10) Uninstall    q) Quit
EOF
        printf 'Choice: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) rfw_status ;;
            2) rfw_install_or_update install ;;
            3) rfw_install_or_update update ;;
            4) rfw_configure ;;
            5) rfw_service_start ;;
            6) rfw_service_stop ;;
            7) rfw_service_restart ;;
            8) rfw_stats ;;
            9) rfw_logs -n 100 ;;
            10) rfw_uninstall ;;
            q | Q) return 0 ;;
            *) rfw_error "invalid menu choice" ;;
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
                rfw_error "status accepts no options"
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
            rfw_error "unknown action: $action"
            rfw_usage >&2
            return 2
            ;;
    esac
}

rfw_main "$@"
