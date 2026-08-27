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
Manage TCP congestion control and the default queueing discipline.

Usage:
  bbr.sh [global-options] status
  bbr.sh [global-options] enable [--algorithm ALG] [--qdisc QDISC] [--apply-live-qdisc]
  bbr.sh [global-options] set --algorithm ALG --qdisc QDISC [--apply-live-qdisc]
  bbr.sh [global-options] restore

Actions:
  status               Show the current kernel and saved configuration state
  enable               Enable settings, defaulting to bbr with fq
  set                  Select an available TCP algorithm and default qdisc
  restore              Restore the state saved before the first change

Options:
  --algorithm ALG      TCP algorithm listed by the running kernel
  --qdisc QDISC        Default queueing discipline (for example fq or fq_codel)
  --apply-live-qdisc   Replace the root qdisc on the default-route interface
  --dry-run            Show commands without changing the system
  --yes                 Approve ordinary change confirmations
  --non-interactive    Never read from the terminal
  --quiet              Suppress non-essential informational messages
  --verbose            Show additional diagnostics
  --                    Stop option parsing
  -h, --help           Show this help

Changes affect only the currently running kernel. Persistent settings are
written to /etc/sysctl.d/90-vpsctl-bbr.conf and
/etc/modules-load.d/90-vpsctl-bbr.conf. Replacing a live root qdisc can briefly
affect network traffic.
EOF
}

bbr_die_usage() {
    vps_cmd_error "$1"
    return 2
}

bbr_require_linux() {
    [[ "${VPSCTL_TESTING:-0}" == "1" || "$(uname -s 2>/dev/null || true)" == "Linux" ]] && return 0
    vps_cmd_error "network bbr is supported on Linux only"
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
            -h | --help)
                BBR_ACTION="help"
                shift
                (($# == 0)) || bbr_die_usage "--help does not accept additional arguments"
                return $?
                ;;
            --algorithm)
                (($# >= 2)) || {
                    bbr_die_usage "--algorithm requires a value"
                    return $?
                }
                BBR_ALGORITHM="$2"
                shift
                ;;
            --qdisc)
                (($# >= 2)) || {
                    bbr_die_usage "--qdisc requires a value"
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
                bbr_die_usage "unknown option: $1"
                return $?
                ;;
            *)
                positional+=("$1")
                ;;
        esac
        shift
    done

    ((${#positional[@]} <= 1)) || {
        bbr_die_usage "unexpected argument: ${positional[1]}"
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
    local algorithm qdisc available module_state interface root_qdisc

    algorithm="$(bbr_current_algorithm 2>/dev/null || printf 'unknown')"
    qdisc="$(bbr_current_qdisc 2>/dev/null || printf 'unknown')"
    available="$(bbr_available_algorithms 2>/dev/null || printf 'unknown')"

    if [[ -d "$(vps_cmd_system_path /sys/module/tcp_bbr)" ]]; then
        module_state="loaded"
    elif bbr_algorithm_available bbr; then
        module_state="available"
    else
        module_state="unavailable"
    fi
    interface="$(bbr_default_interface 2>/dev/null || printf 'unavailable')"
    root_qdisc="unavailable"
    if [[ "$interface" != "unavailable" ]] && command -v tc >/dev/null 2>&1; then
        root_qdisc="$(bbr_interface_root_qdisc "$interface" 2>/dev/null || printf 'unavailable')"
    fi

    printf 'algorithm: %s\n' "$algorithm"
    printf 'qdisc: %s\n' "$qdisc"
    printf 'available_algorithms: %s\n' "$available"
    printf 'bbr_module: %s\n' "$module_state"
    printf 'default_interface: %s\n' "$interface"
    printf 'interface_root_qdisc: %s\n' "$root_qdisc"
    if [[ -f "$BBR_SYSCTL_FILE" ]]; then
        printf 'persistent_sysctl: present\n'
    else
        printf 'persistent_sysctl: absent\n'
    fi
    if [[ -f "$BBR_MODULES_FILE" ]]; then
        printf 'persistent_modules: present\n'
    else
        printf 'persistent_modules: absent\n'
    fi
    if [[ -f "$BBR_ORIGINAL_FILE" ]]; then
        printf 'original_state: saved\n'
    else
        printf 'original_state: absent\n'
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
        vps_cmd_info "dry-run: would atomically write ${logical_path} with mode ${mode}"
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
                vps_cmd_info "dry-run: would back up unmanaged file before overwrite: ${logical_path}"
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
            vps_cmd_error "refusing to restore over a file no longer managed by vpsctl: ${logical_path}"
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
    BBR_TX_LIVE_QDISC_CAPTURED=0
    BBR_TX_LIVE_INTERFACE=""
    BBR_TX_LIVE_QDISC=""
    BBR_TX_ALGORITHM="$(bbr_current_algorithm)" || {
        vps_cmd_error "cannot read the current TCP congestion-control algorithm"
        return 3
    }
    BBR_TX_QDISC="$(bbr_current_qdisc)" || {
        vps_cmd_error "cannot read the current default qdisc"
        return 3
    }
    bbr_snapshot_file "$BBR_SYSCTL_FILE" BBR_TX_SYSCTL_PRESENT BBR_TX_SYSCTL_B64 || return $?
    bbr_snapshot_file "$BBR_MODULES_FILE" BBR_TX_MODULES_PRESENT BBR_TX_MODULES_B64 || return $?
    bbr_snapshot_file "$BBR_ORIGINAL_FILE" BBR_TX_ORIGINAL_PRESENT BBR_TX_ORIGINAL_B64 || return $?
    BBR_TX_ACTIVE=1
}

bbr_rollback() {
    local failed=0

    [[ "$BBR_TX_ACTIVE" == "1" ]] || return 0
    vps_cmd_warning "change failed; restoring the previous runtime and files"
    bbr_restore_file_snapshot "$BBR_SYSCTL_FILE" 0644 "$BBR_TX_SYSCTL_PRESENT" "$BBR_TX_SYSCTL_B64" || failed=1
    bbr_restore_file_snapshot "$BBR_MODULES_FILE" 0644 "$BBR_TX_MODULES_PRESENT" "$BBR_TX_MODULES_B64" || failed=1
    bbr_restore_file_snapshot "$BBR_ORIGINAL_FILE" 0600 "$BBR_TX_ORIGINAL_PRESENT" "$BBR_TX_ORIGINAL_B64" || failed=1
    vps_cmd_run sysctl -w "net.ipv4.tcp_congestion_control=${BBR_TX_ALGORITHM}" >/dev/null || failed=1
    vps_cmd_run sysctl -w "net.core.default_qdisc=${BBR_TX_QDISC}" >/dev/null || failed=1
    if [[ "$BBR_TX_LIVE_QDISC_CAPTURED" == "1" ]]; then
        vps_cmd_run tc qdisc replace dev "$BBR_TX_LIVE_INTERFACE" root "$BBR_TX_LIVE_QDISC" || failed=1
    fi
    BBR_TX_ACTIVE=0
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
        vps_cmd_error "no original state has been saved"
        return 3
    }
    while IFS= read -r line; do
        [[ "$line" == *=* ]] || {
            vps_cmd_error "saved original state contains a malformed line"
            return 10
        }
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            version | algorithm | qdisc | sysctl_present | sysctl_b64 | modules_present | modules_b64 | live_present | live_interface | live_qdisc) ;;
            *)
                vps_cmd_error "saved original state contains an unknown key: ${key}"
                return 10
                ;;
        esac
        [[ -z "${seen[$key]+x}" ]] || {
            vps_cmd_error "saved original state contains a duplicate key: ${key}"
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
            vps_cmd_error "saved original state is missing key: ${required}"
            return 10
        }
    done
    [[ "$BBR_ORIGINAL_VERSION" == "1" || "$BBR_ORIGINAL_VERSION" == "2" ]] || {
        vps_cmd_error "saved original state has an unsupported format"
        return 10
    }
    if [[ "$BBR_ORIGINAL_VERSION" == "1" ]]; then
        for required in live_present live_interface live_qdisc; do
            [[ -z "${seen[$required]+x}" ]] || {
                vps_cmd_error "version 1 original state must not contain live qdisc keys"
                return 10
            }
        done
        BBR_ORIGINAL_LIVE_PRESENT=0
        BBR_ORIGINAL_LIVE_INTERFACE=""
        BBR_ORIGINAL_LIVE_QDISC=""
    else
        for required in live_present live_interface live_qdisc; do
            [[ -n "${seen[$required]+x}" ]] || {
                vps_cmd_error "saved original state is missing key: ${required}"
                return 10
            }
        done
    fi
    bbr_validate_name "$BBR_ORIGINAL_ALGORITHM" && bbr_validate_name "$BBR_ORIGINAL_QDISC" || {
        vps_cmd_error "saved original state contains invalid kernel settings"
        return 10
    }
    [[ "$BBR_ORIGINAL_SYSCTL_PRESENT" =~ ^[01]$ && "$BBR_ORIGINAL_MODULES_PRESENT" =~ ^[01]$ ]] || {
        vps_cmd_error "saved original state contains invalid file metadata"
        return 10
    }
    bbr_validate_base64 "$BBR_ORIGINAL_SYSCTL_B64" && bbr_validate_base64 "$BBR_ORIGINAL_MODULES_B64" || {
        vps_cmd_error "saved original state contains invalid base64 data"
        return 10
    }
    if [[ "$BBR_ORIGINAL_SYSCTL_PRESENT" == "0" && -n "$BBR_ORIGINAL_SYSCTL_B64" ]] ||
        [[ "$BBR_ORIGINAL_MODULES_PRESENT" == "0" && -n "$BBR_ORIGINAL_MODULES_B64" ]]; then
        vps_cmd_error "saved original state has content for an absent file"
        return 10
    fi
    [[ "$BBR_ORIGINAL_LIVE_PRESENT" =~ ^[01]$ ]] || {
        vps_cmd_error "saved original state contains invalid live qdisc metadata"
        return 10
    }
    if [[ "$BBR_ORIGINAL_LIVE_PRESENT" == "1" ]]; then
        bbr_validate_interface_name "$BBR_ORIGINAL_LIVE_INTERFACE" && bbr_validate_name "$BBR_ORIGINAL_LIVE_QDISC" || {
            vps_cmd_error "saved original state contains invalid live qdisc values"
            return 10
        }
    elif [[ -n "$BBR_ORIGINAL_LIVE_INTERFACE" || -n "$BBR_ORIGINAL_LIVE_QDISC" ]]; then
        vps_cmd_error "saved original state has values for an absent live qdisc snapshot"
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
        vps_cmd_error "TCP algorithm is not available in the running kernel: ${algorithm}"
        return 3
    fi
    command -v modprobe >/dev/null 2>&1 || {
        vps_cmd_error "bbr is unavailable and modprobe is not installed"
        return 3
    }
    vps_cmd_run modprobe tcp_bbr || {
        vps_cmd_error "failed to load tcp_bbr"
        return 20
    }
    if [[ "$VPSCTL_DRY_RUN" == "1" ]]; then
        vps_cmd_info "dry-run cannot re-check algorithms after loading tcp_bbr"
        return 0
    fi
    bbr_algorithm_available "$algorithm" || {
        vps_cmd_error "TCP algorithm is still unavailable after loading tcp_bbr: ${algorithm}"
        return 3
    }
}

bbr_prepare_qdisc() {
    local qdisc="$1"

    command -v modprobe >/dev/null 2>&1 || return 0
    if ! vps_cmd_run modprobe "sch_${qdisc}"; then
        vps_cmd_verbose "sch_${qdisc} is built in or unavailable; sysctl validation will decide"
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
        vps_cmd_require_no_symlink_components "$directory" || return $?
        vps_cmd_run mkdir -p -- "$directory" || return 20
    done
    vps_cmd_run chmod 0700 -- "${BBR_ORIGINAL_FILE%/*}" || return 20
}

bbr_validate_managed_paths() {
    local path

    for path in "$BBR_SYSCTL_FILE" "$BBR_MODULES_FILE" "$BBR_ORIGINAL_FILE"; do
        vps_cmd_require_no_symlink_components "$path" || return $?
    done
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
        vps_cmd_error "--apply-live-qdisc requires tc"
        return 3
    }
    BBR_TX_LIVE_INTERFACE="$(bbr_default_interface)" || {
        vps_cmd_error "cannot determine the default-route interface"
        return 3
    }
    BBR_TX_LIVE_QDISC="$(bbr_interface_root_qdisc "$BBR_TX_LIVE_INTERFACE")" || {
        vps_cmd_error "cannot determine the current root qdisc on ${BBR_TX_LIVE_INTERFACE}"
        return 3
    }
    bbr_validate_name "$BBR_TX_LIVE_QDISC" || {
        vps_cmd_error "current root qdisc has an unsafe type: ${BBR_TX_LIVE_QDISC}"
        return 3
    }
    BBR_TX_LIVE_QDISC_CAPTURED=1
}

bbr_apply_live_qdisc() {
    local qdisc="$1"

    [[ "$BBR_TX_LIVE_QDISC_CAPTURED" == "1" ]] || {
        vps_cmd_error "live qdisc state was not captured before replacement"
        return 70
    }
    vps_cmd_run tc qdisc replace dev "$BBR_TX_LIVE_INTERFACE" root "$qdisc"
}

bbr_restore_saved_live_qdisc() {
    [[ "$BBR_ORIGINAL_LIVE_PRESENT" == "1" ]] || return 0
    command -v ip >/dev/null 2>&1 && command -v tc >/dev/null 2>&1 || {
        vps_cmd_error "cannot restore saved live qdisc because ip or tc is unavailable"
        return 20
    }
    ip link show dev "$BBR_ORIGINAL_LIVE_INTERFACE" >/dev/null 2>&1 || {
        vps_cmd_error "cannot restore saved live qdisc; interface disappeared: ${BBR_ORIGINAL_LIVE_INTERFACE}"
        return 20
    }
    vps_cmd_run tc qdisc replace dev "$BBR_ORIGINAL_LIVE_INTERFACE" root "$BBR_ORIGINAL_LIVE_QDISC" || {
        vps_cmd_error "failed to restore ${BBR_ORIGINAL_LIVE_INTERFACE} root qdisc to ${BBR_ORIGINAL_LIVE_QDISC}"
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
        vps_cmd_error "invalid TCP algorithm name: ${algorithm}"
        return 10
    }
    bbr_validate_name "$qdisc" || {
        vps_cmd_error "invalid qdisc name: ${qdisc}"
        return 10
    }
    if [[ -e "$BBR_ORIGINAL_FILE" ]]; then
        bbr_load_original || return $?
    else
        BBR_ORIGINAL_LOADED=0
    fi
    if bbr_has_unmanaged_persistence; then
        vps_cmd_warning "existing unmanaged vpsctl BBR persistence files will be backed up and overwritten"
        if vps_cmd_confirm "Back up and overwrite the existing BBR persistence files?"; then
            unmanaged_confirmed=1
        else
            status=$?
            if ((status == 1)); then
                vps_cmd_info "no changes made"
                return 0
            fi
            return "$status"
        fi
    fi
    if vps_cmd_confirm "Apply TCP algorithm '${algorithm}' and default qdisc '${qdisc}'?"; then
        :
    else
        status=$?
        if ((status == 1)); then
            vps_cmd_info "no changes made"
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
            vps_cmd_error "unmanaged persistence appeared after confirmation; retry the operation"
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
            vps_cmd_error "failed to apply or verify runtime sysctl settings"
        fi
    fi
    if ((status == 0)) && [[ "$BBR_APPLY_LIVE_QDISC" == "1" ]]; then
        bbr_apply_live_qdisc "$qdisc" || status=$?
    fi

    if ((status != 0)) && [[ "$BBR_TX_ACTIVE" == "1" ]]; then
        bbr_rollback || status=30
    fi
    BBR_TX_ACTIVE=0
    ((locked == 0)) || vps_cmd_unlock
    ((status == 0)) || return "$status"
    vps_cmd_info "TCP algorithm is ${algorithm}; default qdisc is ${qdisc}"
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
        vps_cmd_info "original TCP, qdisc, and persistence state is already restored"
        return 0
    fi
    if vps_cmd_confirm "Restore the first saved TCP and qdisc state?"; then
        :
    else
        status=$?
        if ((status == 1)); then
            vps_cmd_info "no changes made"
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
    ((status != 0)) || bbr_prepare_directories || status=$?
    ((status != 0)) || bbr_restore_file_snapshot "$BBR_SYSCTL_FILE" 0644 "$BBR_ORIGINAL_SYSCTL_PRESENT" "$BBR_ORIGINAL_SYSCTL_B64" || status=$?
    ((status != 0)) || bbr_restore_file_snapshot "$BBR_MODULES_FILE" 0644 "$BBR_ORIGINAL_MODULES_PRESENT" "$BBR_ORIGINAL_MODULES_B64" || status=$?
    if ((status == 0)); then
        if bbr_apply_runtime "$BBR_ORIGINAL_ALGORITHM" "$BBR_ORIGINAL_QDISC"; then
            :
        else
            status=$?
            vps_cmd_error "failed to restore or verify runtime sysctl settings"
        fi
    fi

    if ((status != 0)) && [[ "$BBR_TX_ACTIVE" == "1" ]]; then
        bbr_rollback || status=30
    fi
    BBR_TX_ACTIVE=0
    if ((status == 0)) && [[ "$BBR_ORIGINAL_LIVE_PRESENT" == "1" ]]; then
        bbr_restore_saved_live_qdisc || partial_status=30
    fi
    ((locked == 0)) || vps_cmd_unlock
    ((status == 0)) || return "$status"
    ((partial_status == 0)) || return "$partial_status"
    vps_cmd_info "restored TCP algorithm ${BBR_ORIGINAL_ALGORITHM} and qdisc ${BBR_ORIGINAL_QDISC}"
}

bbr_interactive_menu() {
    local choice algorithm qdisc confirm_status

    while true; do
        printf '\nNetwork BBR management\n'
        printf '  1) Status\n'
        printf '  2) Enable BBR + fq\n'
        printf '  3) Custom algorithm and qdisc\n'
        printf '  4) Restore original state\n'
        printf '  q) Quit\n'
        printf 'Choice: '
        IFS= read -r choice || return 0
        case "$choice" in
            1)
                bbr_status || true
                ;;
            2)
                BBR_APPLY_LIVE_QDISC=0
                if vps_cmd_confirm "Immediately replace the default interface root qdisc?"; then
                    BBR_APPLY_LIVE_QDISC=1
                else
                    confirm_status=$?
                    ((confirm_status == 1)) || return "$confirm_status"
                fi
                bbr_apply_settings bbr fq || true
                ;;
            3)
                printf 'TCP algorithm: '
                IFS= read -r algorithm || return 130
                printf 'Default qdisc: '
                IFS= read -r qdisc || return 130
                BBR_APPLY_LIVE_QDISC=0
                if vps_cmd_confirm "Immediately replace the default interface root qdisc?"; then
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
                vps_cmd_warning "unknown menu choice: ${choice}"
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
                bbr_die_usage "status does not accept setting options"
                return $?
            }
            bbr_status
            ;;
        enable)
            bbr_apply_settings "${BBR_ALGORITHM:-bbr}" "${BBR_QDISC:-fq}"
            ;;
        set)
            [[ -n "$BBR_ALGORITHM" ]] || {
                bbr_die_usage "set requires --algorithm"
                return $?
            }
            [[ -n "$BBR_QDISC" ]] || {
                bbr_die_usage "set requires --qdisc"
                return $?
            }
            bbr_apply_settings "$BBR_ALGORITHM" "$BBR_QDISC"
            ;;
        restore)
            [[ -z "$BBR_ALGORITHM" && -z "$BBR_QDISC" && "$BBR_APPLY_LIVE_QDISC" == "0" ]] || {
                bbr_die_usage "restore does not accept setting options"
                return $?
            }
            bbr_restore
            ;;
        *)
            bbr_die_usage "unknown action: ${BBR_ACTION}"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    bbr_main "$@"
fi
