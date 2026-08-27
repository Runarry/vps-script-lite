#!/usr/bin/env bash
# Global CLI flags are consumed by the sourced command helper library.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'

VPS_DNS_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly VPS_DNS_PROJECT_ROOT
# shellcheck source=../../lib/command.sh
source "${VPS_DNS_PROJECT_ROOT}/lib/command.sh"
vps_cmd_init "network dns" "$VPS_DNS_PROJECT_ROOT"

VPS_DNS_BACKEND=""
VPS_DNS_NM_CONNECTION=""
VPS_DNS_NM_DEVICE=""
VPS_DNS_TEST_DOMAIN="example.com"
VPS_DNS_INSTALL_DEPS=0
declare -a VPS_DNS_SERVERS=()

vps_dns_path() { vps_cmd_system_path "$1"; }

vps_dns_join_servers() {
    local IFS=' '
    printf '%s' "${VPS_DNS_SERVERS[*]}"
}

vps_dns_atomic_write() {
    local target="$1" mode="$2" mapped parent
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        cat >/dev/null
        vps_cmd_info "dry-run: would replace $target (mode $mode)"
        return 0
    fi
    mapped="$(vps_dns_path "$target")" || return $?
    vps_cmd_require_no_symlink_components "$mapped" || return $?
    parent="${mapped%/*}"
    [[ -d "$parent" ]] || mkdir -p -- "$parent" || return 20
    vps_cmd_atomic_write "$target" "$mode" || return 20
}

vps_dns_require_writable_target() {
    local logical="$1" mapped parent options probe
    mapped="$(vps_dns_path "$logical")" || return 10
    vps_cmd_require_no_symlink_components "$mapped" || return $?
    parent="${mapped%/*}"
    if command -v findmnt >/dev/null 2>&1; then
        probe="$parent"
        while [[ ! -e "$probe" && "$probe" != / ]]; do
            probe="${probe%/*}"
            [[ -n "$probe" ]] || probe=/
        done
        if options="$(findmnt -no OPTIONS --target "$probe" 2>/dev/null)"; then :; else
            vps_cmd_error "cannot determine mount options for $logical"
            return 20
        fi
        if [[ ",$options," == *,ro,* ]]; then
            vps_cmd_error "managed DNS target is on a read-only mount: $logical"
            return 3
        fi
    fi
}

vps_dns_usage() {
    cat <<'EOF'
Usage: vpsctl [global-options] network dns [action] [options]

Actions:
  show                         Show the active DNS backend and servers
  test --server IP [...]       Query a domain through every named server
  set --server IP [...]        Replace DNS after all candidates pass testing
  refresh                      Reload the owning DNS backend and caches
  verify                       Verify configured servers and system resolution
  restore [--backup PATH]      Restore the latest (or selected) backup
  help                         Show this help

Options for test/set:
  --server IP                  Candidate DNS server; may be repeated
  --test-domain DOMAIN         Query name used for testing (default: example.com)
  --install-deps               Explicitly allow installing a DNS query tool

With no action, a terminal gets a submenu; otherwise the command behaves as show.
EOF
}

vps_dns_require_linux() {
    [[ "${VPSCTL_TESTING:-0}" == "1" || "$(uname -s 2>/dev/null || true)" == "Linux" ]] && return 0
    vps_cmd_error "network dns is supported on Linux only"
    return 3
}

vps_dns_is_ipv4() {
    local value="$1" part
    local -a parts=()
    [[ "$value" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    IFS='.' read -r -a parts <<<"$value"
    ((${#parts[@]} == 4)) || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        ((10#$part <= 255)) || return 1
    done
}

vps_dns_is_ipv6() {
    local value="${1,,}" left right item ipv4_tail prefix
    local -a left_parts=() right_parts=() all_parts=()
    if [[ "$value" == *.* ]]; then
        ipv4_tail="${value##*:}"
        vps_dns_is_ipv4 "$ipv4_tail" || return 1
        prefix="${value%:*}"
        value="${prefix}:0:0"
    fi
    [[ "$value" == *:* && "$value" =~ ^[0-9a-f:]+$ ]] || return 1
    [[ "$value" != *:::* ]] || return 1
    if [[ "$value" == *::* ]]; then
        [[ "${value#*::}" != *::* ]] || return 1
        left="${value%%::*}"
        right="${value#*::}"
        [[ -z "$left" ]] || IFS=':' read -r -a left_parts <<<"$left"
        [[ -z "$right" ]] || IFS=':' read -r -a right_parts <<<"$right"
        ((${#left_parts[@]} + ${#right_parts[@]} < 8)) || return 1
        all_parts=("${left_parts[@]}" "${right_parts[@]}")
    else
        IFS=':' read -r -a all_parts <<<"$value"
        ((${#all_parts[@]} == 8)) || return 1
    fi
    for item in "${all_parts[@]}"; do
        [[ "$item" =~ ^[0-9a-f]{1,4}$ ]] || return 1
    done
}

vps_dns_validate_server() {
    vps_dns_is_ipv4 "$1" || vps_dns_is_ipv6 "$1"
}

vps_dns_parse_servers() {
    VPS_DNS_SERVERS=()
    VPS_DNS_TEST_DOMAIN="example.com"
    VPS_DNS_INSTALL_DEPS=0
    while (($# > 0)); do
        case "$1" in
            --server)
                (($# >= 2)) || {
                    vps_cmd_error "--server requires an address"
                    return 2
                }
                vps_dns_validate_server "$2" || {
                    vps_cmd_error "invalid DNS server address: $2"
                    return 2
                }
                local existing duplicate=0
                for existing in "${VPS_DNS_SERVERS[@]}"; do [[ "$existing" == "$2" ]] && duplicate=1; done
                if ((duplicate == 0)); then
                    ((${#VPS_DNS_SERVERS[@]} < 3)) || {
                        vps_cmd_error "at most three distinct --server values are allowed"
                        return 2
                    }
                    VPS_DNS_SERVERS+=("$2")
                fi
                shift 2
                ;;
            --test-domain)
                (($# >= 2)) || {
                    vps_cmd_error "--test-domain requires a value"
                    return 2
                }
                [[ "$2" =~ ^([A-Za-z0-9_][A-Za-z0-9_-]{0,62}\.)*[A-Za-z0-9_][A-Za-z0-9_-]{0,62}\.?$ ]] || {
                    vps_cmd_error "invalid test domain: $2"
                    return 2
                }
                VPS_DNS_TEST_DOMAIN="$2"
                shift 2
                ;;
            --install-deps)
                VPS_DNS_INSTALL_DEPS=1
                shift
                ;;
            -h | --help)
                vps_dns_usage
                return 64
                ;;
            *)
                vps_cmd_error "unknown option: $1"
                return 2
                ;;
        esac
    done
    ((${#VPS_DNS_SERVERS[@]} > 0)) || {
        vps_cmd_error "at least one --server is required"
        return 2
    }
}

vps_dns_query_tool() {
    local tool
    for tool in dig drill nslookup; do
        command -v "$tool" >/dev/null 2>&1 && {
            printf '%s\n' "$tool"
            return 0
        }
    done
    return 1
}

vps_dns_install_query_tool() {
    local manager="" package="" status
    if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == "1" && "$VPS_DNS_INSTALL_DEPS" != "1" ]]; then
        vps_cmd_error "no dig, drill, or nslookup found; rerun with --install-deps"
        return 3
    fi
    if [[ "$VPS_DNS_INSTALL_DEPS" != "1" ]]; then
        [[ "${VPSCTL_DRY_RUN:-0}" != "1" ]] || {
            vps_cmd_error "dry-run needs --install-deps to plan dependency installation"
            return 3
        }
        if vps_cmd_confirm "Install a DNS query tool?"; then :; else
            status=$?
            [[ "$status" == 1 ]] && return 64
            return "$status"
        fi
    fi
    vps_cmd_require_root || return $?
    for manager in apt-get dnf5 dnf yum apk pacman zypper; do
        command -v "$manager" >/dev/null 2>&1 && break
        manager=""
    done
    [[ -n "$manager" ]] || {
        vps_cmd_error "no supported package manager found"
        return 3
    }
    case "$manager" in
        apt-get)
            package="dnsutils"
            vps_cmd_run apt-get update || return 20
            vps_cmd_run apt-get install -y "$package" || return 20
            ;;
        dnf5 | dnf | yum)
            package="bind-utils"
            vps_cmd_run "$manager" install -y "$package" || return 20
            ;;
        apk)
            package="bind-tools"
            vps_cmd_run apk add "$package" || return 20
            ;;
        pacman)
            package="bind"
            vps_cmd_run pacman -Sy --noconfirm "$package" || return 20
            ;;
        zypper)
            package="bind-utils"
            vps_cmd_run zypper --non-interactive install "$package" || return 20
            ;;
    esac
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    vps_dns_query_tool >/dev/null || {
        vps_cmd_error "installation completed but no query tool is available"
        return 3
    }
}

vps_dns_query() {
    local tool="$1" server="$2" domain="$3" output
    case "$tool" in
        dig)
            output="$(dig +time=3 +tries=1 +short "@$server" "$domain" A 2>/dev/null)" || return 1
            [[ "$output" =~ [^[:space:]] ]]
            ;;
        drill)
            output="$(drill "@$server" "$domain" A 2>/dev/null)" || return 1
            [[ "$output" == *"ANSWER SECTION"* && "$output" =~ [^[:space:]] ]]
            ;;
        nslookup)
            output="$(nslookup -timeout=3 "$domain" "$server" 2>/dev/null)" || return 1
            [[ "$output" == *"Address"* && "$output" =~ [^[:space:]] ]]
            ;;
        *) return 3 ;;
    esac
}

vps_dns_test_candidates() {
    local tool server failed=0
    tool="$(vps_dns_query_tool 2>/dev/null || true)"
    if [[ -z "$tool" ]]; then
        if vps_dns_install_query_tool; then :; else return $?; fi
        tool="$(vps_dns_query_tool 2>/dev/null || true)"
        if [[ -z "$tool" && "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
            vps_cmd_info "dry-run: candidate queries would run after dependency installation"
            return 0
        fi
    fi
    for server in "${VPS_DNS_SERVERS[@]}"; do
        if vps_dns_query "$tool" "$server" "$VPS_DNS_TEST_DOMAIN"; then
            vps_cmd_info "$server answered for $VPS_DNS_TEST_DOMAIN via $tool"
        else
            vps_cmd_error "$server failed the directed query for $VPS_DNS_TEST_DOMAIN"
            failed=1
        fi
    done
    ((failed == 0)) || return 20
}

vps_dns_resolv_link_owner() {
    local resolv target
    resolv="$(vps_dns_path /etc/resolv.conf)"
    [[ -L "$resolv" ]] || {
        printf 'regular\n'
        return 0
    }
    target="$(readlink "$resolv" 2>/dev/null || true)"
    case "$target" in
        *systemd/resolve/*) printf 'systemd-resolved\n' ;;
        *NetworkManager/*) printf 'networkmanager\n' ;;
        *run/resolvconf/* | *resolvconf/run/*) printf 'openresolv\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

vps_dns_default_device() {
    local line token previous=""
    local -a tokens=()
    command -v ip >/dev/null 2>&1 || return 1
    while IFS= read -r line; do
        previous=""
        IFS=$' \t' read -r -a tokens <<<"$line"
        for token in "${tokens[@]}"; do
            [[ "$previous" == "dev" ]] && {
                printf '%s\n' "$token"
                return 0
            }
            previous="$token"
        done
    done < <(ip route show default 2>/dev/null)
    return 1
}

vps_dns_valid_nm_identity() {
    local connection="$1" device="$2"

    [[ -n "$connection" && "$connection" != -* && "$connection" != *$'\r'* && "$connection" != *$'\n'* ]] || return 1
    [[ "$device" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]
}

vps_dns_detect_backend() {
    local device="" connection="" owner resolvconf_version=""
    VPS_DNS_BACKEND="plain"
    VPS_DNS_NM_CONNECTION=""
    VPS_DNS_NM_DEVICE=""
    owner="$(vps_dns_resolv_link_owner)"
    if command -v nmcli >/dev/null 2>&1; then
        device="$(vps_dns_default_device 2>/dev/null || true)"
        if [[ -n "$device" ]]; then
            if connection="$(nmcli --escape no -g GENERAL.CONNECTION device show "$device" 2>/dev/null | head -n 1)"; then :; else connection=""; fi
            if [[ -n "$connection" && "$connection" != "--" ]]; then
                if ! vps_dns_valid_nm_identity "$connection" "$device"; then
                    VPS_DNS_BACKEND="conflict"
                    return 0
                fi
                if [[ "$owner" != regular && "$owner" != networkmanager && "$owner" != systemd-resolved ]]; then
                    VPS_DNS_BACKEND="conflict"
                    return 0
                fi
                VPS_DNS_BACKEND="networkmanager"
                VPS_DNS_NM_CONNECTION="$connection"
                VPS_DNS_NM_DEVICE="$device"
                return 0
            fi
        fi
    fi
    if [[ "$owner" == systemd-resolved ]]; then
        VPS_DNS_BACKEND="systemd-resolved"
        return 0
    fi
    if command -v resolvconf >/dev/null 2>&1; then
        if [[ "$owner" != regular && "$owner" != openresolv ]]; then
            VPS_DNS_BACKEND="conflict"
            return 0
        fi
        resolvconf_version="$(resolvconf --version 2>&1 || true)"
        if [[ "${resolvconf_version,,}" == *openresolv* ]]; then
            VPS_DNS_BACKEND="openresolv"
        else
            VPS_DNS_BACKEND="debian-resolvconf"
        fi
        return 0
    fi
    [[ "$owner" == unknown ]] && VPS_DNS_BACKEND="unsafe-symlink"
    return 0
}

vps_dns_read_servers() {
    local file line key value
    file="$(vps_dns_path /etc/resolv.conf)"
    [[ -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        IFS=$' \t' read -r key value _ <<<"$line"
        [[ "$key" == "nameserver" && -n "${value:-}" ]] && printf '%s\n' "$value"
    done <"$file"
}

vps_dns_show() {
    local servers
    vps_dns_detect_backend
    if servers="$(vps_dns_effective_servers)"; then :; else return 20; fi
    printf 'DNS backend: %s\n' "$VPS_DNS_BACKEND"
    [[ -z "$VPS_DNS_NM_CONNECTION" ]] || printf 'Default connection: %s\n' "$VPS_DNS_NM_CONNECTION"
    if [[ -n "$servers" ]]; then
        printf 'Active servers:\n%s\n' "$servers"
    else
        printf 'Active servers: none detected\n'
    fi
}

vps_dns_backup_root() { vps_dns_path /var/lib/vpsctl/backups/network/dns; }

vps_dns_backup_current() {
    local backend="$1" source backup root kind="file" state_logical property value metadata_logical
    root="$(vps_dns_backup_root)"
    case "$backend" in
        systemd-resolved) source="/etc/systemd/resolved.conf.d/90-vpsctl-dns.conf" ;;
        openresolv) source="/etc/resolvconf.conf" ;;
        *) source="/etc/resolv.conf" ;;
    esac
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "dry-run: would back up DNS state for $backend"
        return 0
    fi
    vps_cmd_require_no_symlink_components "$root" || return $?
    mkdir -p -- "$root" || return 20
    vps_cmd_require_no_symlink_components "$root" || return $?
    chmod 0700 -- "$root" || return 20
    state_logical="/var/lib/vpsctl/backups/network/dns/.current-state"
    if [[ "$backend" == "networkmanager" ]]; then
        kind="networkmanager"
        {
            printf 'connection=%s\n' "$VPS_DNS_NM_CONNECTION"
            printf 'device=%s\n' "$VPS_DNS_NM_DEVICE"
            for property in ipv4.dns ipv4.ignore-auto-dns ipv4.dns-search ipv4.dns-options ipv6.dns ipv6.ignore-auto-dns ipv6.dns-search ipv6.dns-options; do
                if value="$(nmcli --escape no -g "$property" connection show "$VPS_DNS_NM_CONNECTION" 2>/dev/null)"; then :; else return 20; fi
                value="${value//$'\n'/ }"
                printf '%s=%s\n' "$property" "$value"
            done
        } | vps_dns_atomic_write "$state_logical" 0600 || return 20
        backup="$(vps_cmd_backup_file "dns" "$state_logical")" || return $?
        source="@networkmanager"
    elif [[ -f "$(vps_dns_path "$source")" && ! -L "$(vps_dns_path "$source")" ]]; then
        backup="$(vps_cmd_backup_file "dns" "$source")" || return $?
    else
        kind="absent"
        printf 'VPSCTL_DNS_TARGET_WAS_ABSENT\n' | vps_dns_atomic_write "$state_logical" 0600 || return 20
        backup="$(vps_cmd_backup_file "dns" "$state_logical")" || return $?
    fi
    metadata_logical="${backup%/*}/metadata"
    if [[ "${VPSCTL_TESTING:-0}" == "1" ]]; then
        metadata_logical="${metadata_logical#"${VPSCTL_SYSTEM_ROOT%/}"}"
    fi
    {
        printf 'backend=%s\n' "$backend"
        printf 'kind=%s\n' "$kind"
        printf 'target=%s\n' "$source"
        printf 'backup=%s\n' "$backup"
    } | vps_dns_atomic_write "$metadata_logical" 0600 || return 20
    {
        printf 'backend=%s\n' "$backend"
        printf 'kind=%s\n' "$kind"
        printf 'target=%s\n' "$source"
        printf 'backup=%s\n' "$backup"
    } | vps_dns_atomic_write /var/lib/vpsctl/backups/network/dns/latest 0600 || return 20
}

vps_dns_collect_search() {
    local file line rest
    file="$(vps_dns_path /etc/resolv.conf)"
    [[ -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*search[[:space:]]+ ]]; then
            rest="${line#*search}"
            rest="${rest#${rest%%[![:space:]]*}}"
            printf '%s\n' "$rest"
            return 0
        fi
    done <"$file"
}

vps_dns_collect_options() {
    local file line rest
    file="$(vps_dns_path /etc/resolv.conf)"
    [[ -r "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*options[[:space:]]+ ]]; then
            rest="${line#*options}"
            rest="${rest#${rest%%[![:space:]]*}}"
            printf '%s\n' "$rest"
            return 0
        fi
    done <"$file"
}

vps_dns_write_plain() {
    local file line inserted=0 server output=""
    file="$(vps_dns_path /etc/resolv.conf)"
    if [[ -r "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*nameserver[[:space:]]+ ]]; then
                if ((inserted == 0)); then
                    for server in "${VPS_DNS_SERVERS[@]}"; do output+="nameserver ${server}"$'\n'; done
                    inserted=1
                fi
                continue
            fi
            output+="$line"$'\n'
        done <"$file"
    fi
    if ((inserted == 0)); then
        for server in "${VPS_DNS_SERVERS[@]}"; do output+="nameserver ${server}"$'\n'; done
    fi
    printf '%s' "$output" | vps_dns_atomic_write /etc/resolv.conf 0644 || return 20
}

vps_dns_write_resolved() {
    local joined
    joined="$(vps_dns_join_servers)"
    {
        printf '[Resolve]\nDNS=%s\nFallbackDNS=\nDomains=~.\n' "$joined"
    } | vps_dns_atomic_write /etc/systemd/resolved.conf.d/90-vpsctl-dns.conf 0644 || return 20
}

vps_dns_write_openresolv() {
    local file line output="" joined
    file="$(vps_dns_path /etc/resolvconf.conf)"
    if [[ -r "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*(name_servers|name_server_blacklist)[[:space:]]*= ]] && continue
            output+="$line"$'\n'
        done <"$file"
    fi
    joined="$(vps_dns_join_servers)"
    output+="name_servers=\"${joined}\""$'\n'
    output+='name_server_blacklist="*"'$'\n'
    printf '%s' "$output" | vps_dns_atomic_write /etc/resolvconf.conf 0644 || return 20
}

vps_dns_write_nm() {
    local server search options v4="" v6=""
    for server in "${VPS_DNS_SERVERS[@]}"; do
        if vps_dns_is_ipv4 "$server"; then v4+="${v4:+ }$server"; else v6+="${v6:+ }$server"; fi
    done
    search="$(vps_dns_collect_search)"
    options="$(vps_dns_collect_options)"
    options="${options//$'\t'/ }"
    while [[ "$options" == *"  "* ]]; do options="${options//  / }"; done
    options="${options// /,}"
    vps_cmd_run nmcli connection modify "$VPS_DNS_NM_CONNECTION" \
        ipv4.dns "$v4" ipv4.ignore-auto-dns yes ipv6.dns "$v6" ipv6.ignore-auto-dns yes \
        ipv4.dns-search "$search" ipv6.dns-search "$search" \
        ipv4.dns-options "$options" ipv6.dns-options "$options" || return 20
}

vps_dns_refresh_backend() {
    local backend="${1:-}"
    [[ -n "$backend" ]] || {
        vps_dns_detect_backend
        backend="$VPS_DNS_BACKEND"
    }
    case "$backend" in
        networkmanager)
            [[ -n "$VPS_DNS_NM_DEVICE" ]] || {
                vps_cmd_error "NetworkManager default device is unknown"
                return 3
            }
            vps_cmd_run nmcli connection reload || return 20
            vps_cmd_run nmcli device reapply "$VPS_DNS_NM_DEVICE" || return 20
            ;;
        systemd-resolved) vps_cmd_run systemctl restart systemd-resolved || return 20 ;;
        openresolv) vps_cmd_run resolvconf -u || return 20 ;;
        debian-resolvconf | conflict | unsafe-symlink)
            vps_cmd_error "DNS backend ownership is unsafe for refresh"
            return 3
            ;;
        plain) : ;;
    esac
    if command -v resolvectl >/dev/null 2>&1; then
        vps_cmd_run resolvectl flush-caches || return 20
    elif command -v systemd-resolve >/dev/null 2>&1; then
        vps_cmd_run systemd-resolve --flush-caches || return 20
    fi
}

vps_dns_effective_servers() {
    local output line rest token owner
    local IFS=$' \t\n'
    case "${VPS_DNS_BACKEND:-plain}" in
        networkmanager)
            owner="$(vps_dns_resolv_link_owner)"
            if [[ "$owner" == systemd-resolved ]]; then
                if output="$(resolvectl dns 2>/dev/null)"; then :; else return 20; fi
                output="$(while IFS= read -r line; do
                    rest="${line#*:}"
                    printf '%s ' "$rest"
                done <<<"$output")"
            else
                if output="$(nmcli --escape no -g IP4.DNS,IP6.DNS device show 2>/dev/null)"; then :; else return 20; fi
                output="${output//,/ }"
            fi
            ;;
        systemd-resolved)
            if output="$(resolvectl dns 2>/dev/null)"; then :; else return 20; fi
            output="$(while IFS= read -r line; do
                rest="${line#*:}"
                printf '%s ' "$rest"
            done <<<"$output")"
            ;;
        *)
            vps_dns_read_servers
            return 0
            ;;
    esac
    output="${output//$'\n'/ }"
    for token in $output; do
        token="${token%%\%*}"
        vps_dns_validate_server "$token" && printf '%s\n' "$token"
    done
}

vps_dns_verify_servers() {
    local actual server line found missing=0 extra=0 expected
    if actual="$(vps_dns_effective_servers)"; then :; else return 20; fi
    for server in "${VPS_DNS_SERVERS[@]}"; do
        found=0
        while IFS= read -r line; do [[ "$line" == "$server" ]] && found=1; done <<<"$actual"
        if ((found == 0)); then
            vps_cmd_error "configured server is not active: $server"
            missing=1
        fi
    done
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if vps_dns_is_ipv4 "$line" && [[ "$line" == 127.* ]]; then continue; fi
        [[ "$line" == "::1" ]] && continue
        found=0
        for expected in "${VPS_DNS_SERVERS[@]}"; do [[ "$line" == "$expected" ]] && found=1; done
        if ((found == 0)); then
            vps_cmd_error "unexpected active upstream DNS server: $line"
            extra=1
        fi
    done <<<"$actual"
    ((missing == 0 && extra == 0)) || return 20
}

vps_dns_verify_system_resolution() {
    if command -v getent >/dev/null 2>&1; then
        getent ahosts "$VPS_DNS_TEST_DOMAIN" >/dev/null 2>&1
    elif command -v host >/dev/null 2>&1; then
        host "$VPS_DNS_TEST_DOMAIN" >/dev/null 2>&1
    else
        local tool
        tool="$(vps_dns_query_tool 2>/dev/null || true)"
        [[ -n "$tool" ]] && vps_dns_query "$tool" "${VPS_DNS_SERVERS[0]:-127.0.0.1}" "$VPS_DNS_TEST_DOMAIN"
    fi
}

vps_dns_verify() {
    local server effective
    [[ -n "${VPS_DNS_BACKEND:-}" ]] || vps_dns_detect_backend
    if ((${#VPS_DNS_SERVERS[@]} == 0)); then
        if effective="$(vps_dns_effective_servers)"; then :; else return 20; fi
        while IFS= read -r server; do [[ -n "$server" ]] && VPS_DNS_SERVERS+=("$server"); done <<<"$effective"
    fi
    ((${#VPS_DNS_SERVERS[@]} > 0)) || {
        vps_cmd_error "no active DNS servers detected"
        return 10
    }
    vps_dns_verify_servers || return 20
    vps_dns_verify_system_resolution || {
        vps_cmd_error "system resolution failed for $VPS_DNS_TEST_DOMAIN"
        return 20
    }
    vps_cmd_info "DNS servers and system resolution verified"
}

vps_dns_set() {
    local backend status managed_target=""
    if vps_dns_test_candidates; then :; else
        status=$?
        [[ "$status" == 64 ]] && {
            vps_cmd_info "DNS operation cancelled"
            return 0
        }
        vps_cmd_error "candidate testing failed; no configuration was written"
        return "$status"
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != "1" ]]; then
        if vps_cmd_confirm "Replace the system DNS configuration with the tested servers?"; then :; else
            status=$?
            if [[ "$status" == 1 ]]; then
                vps_cmd_info "DNS change cancelled"
                return 0
            fi
            return "$status"
        fi
        vps_cmd_require_root || return $?
    fi
    vps_dns_detect_backend
    backend="$VPS_DNS_BACKEND"
    case "$backend" in
        debian-resolvconf)
            vps_cmd_error "legacy Debian resolvconf ownership detected; refusing an unsafe modification"
            return 3
            ;;
        conflict | unsafe-symlink)
            vps_cmd_error "conflicting or unknown resolv.conf ownership; refusing modification"
            return 3
            ;;
    esac
    case "$backend" in
        systemd-resolved) managed_target="/etc/systemd/resolved.conf.d/90-vpsctl-dns.conf" ;;
        openresolv) managed_target="/etc/resolvconf.conf" ;;
        plain) managed_target="/etc/resolv.conf" ;;
    esac
    if [[ "$backend" == systemd-resolved ]]; then
        command -v resolvectl >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1 || {
            vps_cmd_error "systemd-resolved ownership requires resolvectl and systemctl"
            return 3
        }
    fi
    if [[ -n "$managed_target" && -L "$(vps_dns_path "$managed_target")" ]]; then
        vps_cmd_error "managed DNS target is a symlink; refusing to replace it: $managed_target"
        return 3
    fi
    if [[ -n "$managed_target" ]]; then vps_dns_require_writable_target "$managed_target" || return $?; fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != "1" ]]; then
        vps_cmd_lock "network-dns" || return $?
        trap 'vps_cmd_unlock; trap - RETURN' RETURN
        vps_dns_backup_current "$backend" || return 20
    fi
    case "$backend" in
        networkmanager) vps_dns_write_nm || return 20 ;;
        systemd-resolved) vps_dns_write_resolved || return 20 ;;
        openresolv) vps_dns_write_openresolv || return 20 ;;
        plain) vps_dns_write_plain || return 20 ;;
    esac
    if ! vps_dns_refresh_backend "$backend"; then
        vps_cmd_error "DNS was written but refresh failed; restore with: vpsctl network dns restore"
        return 30
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != "1" ]] && ! vps_dns_verify; then
        vps_cmd_error "post-change verification failed; the new configuration was retained"
        vps_cmd_error "restore it with: vpsctl network dns restore"
        return 30
    fi
    return 0
}

vps_dns_restore() {
    local selected="" record root target="" backup="" key value kind="" saved_backend="" current_backend connection="" device="" metadata selected_parent root_real status
    local backend_count=0 kind_count=0 target_count=0 backup_count=0 latest_backend="" latest_kind="" latest_target=""
    local -a nm_args=()
    local -a nm_properties=(ipv4.dns ipv4.ignore-auto-dns ipv4.dns-search ipv4.dns-options ipv6.dns ipv6.ignore-auto-dns ipv6.dns-search ipv6.dns-options)
    local -A nm_seen=()
    local property
    while (($# > 0)); do
        case "$1" in
            --backup)
                (($# >= 2)) || {
                    vps_cmd_error "--backup requires a path"
                    return 2
                }
                selected="$2"
                shift 2
                ;;
            *)
                vps_cmd_error "unknown restore option: $1"
                return 2
                ;;
        esac
    done
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] || vps_cmd_require_root || return $?
    root="$(vps_dns_backup_root)"
    record="${root}/latest"
    if [[ -z "$selected" ]]; then
        [[ -f "$record" && ! -L "$record" ]] || {
            vps_cmd_error "latest DNS backup metadata is missing or unsafe"
            return 10
        }
        while IFS='=' read -r key value; do
            case "$key" in
                backend)
                    latest_backend="$value"
                    backend_count=$((backend_count + 1))
                    ;;
                kind)
                    latest_kind="$value"
                    kind_count=$((kind_count + 1))
                    ;;
                target)
                    latest_target="$value"
                    target_count=$((target_count + 1))
                    ;;
                backup)
                    backup="$value"
                    backup_count=$((backup_count + 1))
                    ;;
                *) return 10 ;;
            esac
        done <"$record"
        [[ "$backend_count" == 1 && "$kind_count" == 1 && "$target_count" == 1 && "$backup_count" == 1 ]] || return 10
    else
        backup="$selected"
    fi
    [[ "$backup" == /* && -f "$backup" && ! -L "$backup" ]] || {
        vps_cmd_error "backup file is missing or unsafe"
        return 10
    }
    [[ -d "$root" && ! -L "$root" ]] || {
        vps_cmd_error "DNS backup root is missing or unsafe"
        return 10
    }
    root_real="$(cd -- "$root" && pwd -P)" || return 10
    selected_parent="$(cd -- "${backup%/*}" && pwd -P)" || return 10
    [[ "$selected_parent" == "$root_real"/* ]] || {
        vps_cmd_error "backup escapes the DNS backup root"
        return 10
    }
    backup="${selected_parent}/${backup##*/}"
    metadata="${selected_parent}/metadata"
    [[ -f "$metadata" && ! -L "$metadata" ]] || {
        vps_cmd_error "backup metadata is missing or unsafe"
        return 10
    }
    backend_count=0 kind_count=0 target_count=0 backup_count=0
    while IFS='=' read -r key value; do
        case "$key" in
            backend)
                saved_backend="$value"
                backend_count=$((backend_count + 1))
                ;;
            kind)
                kind="$value"
                kind_count=$((kind_count + 1))
                ;;
            target)
                target="$value"
                target_count=$((target_count + 1))
                ;;
            backup)
                [[ "$value" == "$backup" ]] || return 10
                backup_count=$((backup_count + 1))
                ;;
            *) return 10 ;;
        esac
    done <"$metadata"
    [[ "$backend_count" == 1 && "$kind_count" == 1 && "$target_count" == 1 && "$backup_count" == 1 ]] || return 10
    if [[ -z "$selected" ]]; then
        [[ "$latest_backend" == "$saved_backend" && "$latest_kind" == "$kind" && "$latest_target" == "$target" ]] || return 10
    fi
    case "$saved_backend:$kind:$target" in
        networkmanager:networkmanager:@networkmanager | systemd-resolved:file:/etc/systemd/resolved.conf.d/90-vpsctl-dns.conf | systemd-resolved:absent:/etc/systemd/resolved.conf.d/90-vpsctl-dns.conf | openresolv:file:/etc/resolvconf.conf | openresolv:absent:/etc/resolvconf.conf | plain:file:/etc/resolv.conf | plain:absent:/etc/resolv.conf) ;;
        *)
            vps_cmd_error "invalid DNS backup metadata tuple"
            return 10
            ;;
    esac
    vps_dns_detect_backend
    current_backend="$VPS_DNS_BACKEND"
    [[ "$current_backend" == "$saved_backend" ]] || {
        vps_cmd_error "current DNS owner does not match backup backend"
        return 3
    }
    if [[ "$target" == /* ]]; then vps_dns_require_writable_target "$target" || return $?; fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != "1" ]]; then
        if vps_cmd_confirm "Restore DNS configuration from $backup?"; then :; else
            status=$?
            if [[ "$status" == 1 ]]; then
                vps_cmd_info "DNS restore cancelled"
                return 0
            fi
            return "$status"
        fi
        vps_cmd_lock "network-dns" || return $?
        trap 'vps_cmd_unlock; trap - RETURN' RETURN
    fi
    case "$kind" in
        networkmanager)
            while IFS='=' read -r key value; do
                case "$key" in
                    connection)
                        [[ -z "${nm_seen[connection]:-}" ]] || return 10
                        nm_seen[connection]=1
                        connection="$value"
                        ;;
                    device)
                        [[ -z "${nm_seen[device]:-}" ]] || return 10
                        nm_seen[device]=1
                        device="$value"
                        ;;
                    ipv4.dns | ipv4.ignore-auto-dns | ipv4.dns-search | ipv4.dns-options | ipv6.dns | ipv6.ignore-auto-dns | ipv6.dns-search | ipv6.dns-options)
                        [[ -z "${nm_seen[$key]:-}" ]] || return 10
                        nm_seen[$key]=1
                        nm_args+=("$key" "$value")
                        ;;
                    *) return 10 ;;
                esac
            done <"$backup"
            [[ "${nm_seen[connection]:-}" == 1 && "${nm_seen[device]:-}" == 1 ]] && vps_dns_valid_nm_identity "$connection" "$device" || {
                vps_cmd_error "NetworkManager backup has an invalid connection or device"
                return 10
            }
            for property in "${nm_properties[@]}"; do [[ "${nm_seen[$property]:-}" == 1 ]] || {
                vps_cmd_error "NetworkManager backup lacks $property"
                return 10
            }; done
            VPS_DNS_NM_CONNECTION="$connection"
            VPS_DNS_NM_DEVICE="$device"
            vps_cmd_run nmcli connection modify "$connection" "${nm_args[@]}" || return 20
            ;;
        absent)
            vps_cmd_run rm -f -- "$(vps_dns_path "$target")" || return 20
            ;;
        file)
            if [[ "${VPSCTL_DRY_RUN:-0}" != "1" && -f "$(vps_dns_path "$target")" ]]; then
                vps_cmd_backup_file "dns" "$target" >/dev/null || return 20
            fi
            vps_dns_atomic_write "$target" 0644 <"$backup" || return 20
            ;;
    esac
    if ! vps_dns_refresh_backend "$saved_backend"; then
        vps_cmd_error "DNS was restored but refresh failed; retry with: vpsctl network dns restore --backup $backup"
        return 30
    fi
    vps_cmd_info "DNS configuration restored from $backup"
}

vps_dns_menu() {
    local choice raw token status
    local -a tokens=() args=()
    while true; do
        printf '\nDNS management\n  1) Show\n  2) Test servers\n  3) Set servers\n  4) Verify\n  5) Refresh\n  6) Restore latest\n  q) Quit\n\nChoice: '
        IFS= read -r choice || return 0
        case "$choice" in
            1) vps_dns_show ;;
            2 | 3)
                vps_cmd_warning "Use only DNS server IP addresses you trust. Enter one to three addresses."
                printf 'Servers (comma or space separated): '
                IFS= read -r raw || continue
                raw="${raw//,/ }"
                IFS=$' \t' read -r -a tokens <<<"$raw"
                args=()
                for token in "${tokens[@]}"; do [[ -n "$token" ]] && args+=(--server "$token"); done
                if vps_dns_parse_servers "${args[@]}"; then
                    if [[ "$choice" == 2 ]]; then vps_dns_test_candidates || true; else vps_dns_set || true; fi
                fi
                ;;
            4)
                VPS_DNS_SERVERS=()
                VPS_DNS_BACKEND=""
                vps_dns_verify || true
                ;;
            5) vps_cmd_require_root && vps_dns_refresh_backend || true ;;
            6) vps_dns_restore || true ;;
            q | Q | '') return 0 ;;
        esac
    done
}

vps_dns_parse_standalone_globals() {
    VPS_DNS_ARGS=()
    while (($# > 0)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --)
                shift
                VPS_DNS_ARGS=("$@")
                return 0
                ;;
            *)
                VPS_DNS_ARGS=("$@")
                return 0
                ;;
        esac
        shift
    done
}

vps_dns_main() {
    local action status
    vps_dns_parse_standalone_globals "$@"
    set -- "${VPS_DNS_ARGS[@]}"
    action="${1:-}"
    if [[ "$action" == help || "$action" == -h || "$action" == --help ]]; then
        (($# == 1)) || {
            vps_cmd_error "help accepts no additional arguments"
            return 2
        }
        vps_dns_usage
        return 0
    fi
    vps_dns_require_linux || return $?
    if [[ -z "$action" ]]; then
        if [[ "${VPSCTL_NON_INTERACTIVE:-0}" != "1" && -t 0 && -t 1 ]]; then vps_dns_menu; else vps_dns_show; fi
        return $?
    fi
    shift || true
    case "$action" in
        show)
            (($# == 0)) || {
                vps_cmd_error "show accepts no options"
                return 2
            }
            vps_dns_show
            ;;
        test)
            if vps_dns_parse_servers "$@"; then :; else
                status=$?
                [[ "$status" == 64 ]] && return 0
                return "$status"
            fi
            if vps_dns_test_candidates; then return 0; else
                status=$?
                [[ "$status" == 64 ]] && return 0
                return "$status"
            fi
            ;;
        set)
            if vps_dns_parse_servers "$@"; then :; else
                status=$?
                [[ "$status" == 64 ]] && return 0
                return "$status"
            fi
            vps_dns_set
            ;;
        refresh)
            (($# == 0)) || {
                vps_cmd_error "refresh accepts no options"
                return 2
            }
            vps_cmd_require_root && vps_dns_refresh_backend
            ;;
        verify)
            (($# == 0)) || {
                vps_cmd_error "verify accepts no options"
                return 2
            }
            VPS_DNS_SERVERS=()
            vps_dns_verify
            ;;
        restore) vps_dns_restore "$@" ;;
        *)
            vps_cmd_error "unknown DNS action: $action"
            vps_dns_usage >&2
            return 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    vps_dns_main "$@"
fi
