#!/usr/bin/env bash
# Tests intentionally exercise globals consumed by sourced DNS functions.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
TEST_SYSTEM_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_SYSTEM_ROOT"' EXIT

export VPSCTL_PROJECT_ROOT="$TEST_ROOT"
export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0 VPSCTL_ASSUME_YES=1 VPSCTL_NON_INTERACTIVE=1
export VPSCTL_QUIET=1 VPSCTL_VERBOSE=0 VPSCTL_NO_COLOR=1

mkdir -p "$TEST_SYSTEM_ROOT/etc" "$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/network/dns"
printf 'search svc.example\noptions timeout:1\nnameserver 192.0.2.53\n' >"$TEST_SYSTEM_ROOT/etc/resolv.conf"

# shellcheck source=../../commands/network/dns.sh
source "$TEST_ROOT/commands/network/dns.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpectedly contains '$2'"; }

test_address_validation() {
    vps_dns_validate_server 1.1.1.1 || fail "valid IPv4 was rejected"
    vps_dns_validate_server 2001:4860:4860::8888 || fail "valid IPv6 was rejected"
    ! vps_dns_validate_server 01.2.3.4 || fail "leading-zero IPv4 was accepted"
    ! vps_dns_validate_server 256.1.1.1 || fail "out-of-range IPv4 was accepted"
    ! vps_dns_validate_server 2001:::1 || fail "malformed IPv6 was accepted"
    vps_dns_parse_servers --server 1.1.1.1 --server 1.1.1.1 --server 8.8.8.8
    assert_equal 2 "${#VPS_DNS_SERVERS[@]}" "server deduplication"
    ! vps_dns_parse_servers --server 1.1.1.1 --server 8.8.8.8 --server 9.9.9.9 --server 208.67.222.222 >/dev/null 2>&1 || fail "more than three servers were accepted"
}

test_standalone_globals() {
    VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0 VPSCTL_ASSUME_YES=0 VPSCTL_NON_INTERACTIVE=0 VPSCTL_QUIET=0 VPSCTL_VERBOSE=0
    vps_dns_parse_standalone_globals --dry-run --install-deps --yes --non-interactive --quiet --verbose --no-color -- set --server 1.1.1.1
    assert_equal 1 "$VPSCTL_DRY_RUN" "standalone dry-run"
    assert_equal 1 "$VPSCTL_INSTALL_DEPS" "standalone install-deps"
    assert_equal 1 "$VPSCTL_ASSUME_YES" "standalone yes"
    assert_equal 1 "$VPSCTL_NON_INTERACTIVE" "standalone non-interactive"
    assert_equal 1 "$VPSCTL_QUIET" "standalone quiet"
    assert_equal 1 "$VPSCTL_VERBOSE" "standalone verbose"
    assert_equal 1 "$VPSCTL_NO_COLOR" "standalone no-color"
    assert_equal set "${VPS_DNS_ARGS[0]}" "standalone option terminator"
    VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0 VPSCTL_ASSUME_YES=1 VPSCTL_NON_INTERACTIVE=1 VPSCTL_QUIET=1 VPSCTL_VERBOSE=0
}

test_dependency_authorization() (
    local calls=0 status=0

    VPSCTL_DRY_RUN=0
    VPSCTL_NON_INTERACTIVE=1
    VPSCTL_INSTALL_DEPS=1
    VPS_DNS_INSTALL_DEPS=0
    vps_cmd_ensure_tools() {
        assert_equal 1 "$VPSCTL_INSTALL_DEPS" "global dependency authorization passed to shared helper"
        calls=$((calls + 1))
    }
    vps_dns_install_query_tool
    assert_equal 1 "$calls" "global dependency authorization call count"
    assert_equal 1 "$VPSCTL_INSTALL_DEPS" "global dependency authorization preserved"

    calls=0
    VPSCTL_INSTALL_DEPS=0
    vps_dns_parse_servers --server 1.1.1.1 --install-deps
    assert_equal 1 "$VPS_DNS_INSTALL_DEPS" "action dependency authorization"
    vps_dns_install_query_tool
    assert_equal 1 "$calls" "action dependency authorization call count"
    assert_equal 0 "$VPSCTL_INSTALL_DEPS" "action authorization must not leak globally"

    vps_dns_ensure_action_tools network-dns flock
    assert_equal 2 "$calls" "action authorization covers transaction dependencies"
    assert_equal 0 "$VPSCTL_INSTALL_DEPS" "transaction dependency authorization must not leak globally"

    calls=0
    status=0
    VPSCTL_INSTALL_DEPS=1
    VPS_DNS_INSTALL_DEPS=0
    vps_cmd_ensure_tools() {
        calls=$((calls + 1))
        return 20
    }
    vps_dns_install_query_tool >/dev/null 2>&1 || status=$?
    assert_equal 20 "$status" "dependency installer failure status"
    assert_equal 1 "$calls" "failing dependency helper call count"
    assert_equal 1 "$VPSCTL_INSTALL_DEPS" "global authorization restored after dependency failure"

    calls=0
    status=0
    VPSCTL_INSTALL_DEPS=0
    VPS_DNS_INSTALL_DEPS=0
    vps_dns_install_query_tool >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" "missing DNS dependency authorization status"
    assert_equal 0 "$calls" "unauthorized DNS dependency helper call count"
)

test_dry_run_dependency_and_dns_plan() (
    local empty_path output

    VPSCTL_DRY_RUN=1
    VPSCTL_INSTALL_DEPS=1
    VPSCTL_QUIET=0
    VPS_DNS_SERVERS=(9.9.9.9)
    VPS_DNS_TEST_DOMAIN=example.com
    vps_dns_query_tool() { return 1; }
    vps_dns_install_query_tool() {
        VPS_CMD_DEPENDENCIES_PLANNED=1
        vps_cmd_info "演练：将安装 DNS 查询依赖"
    }
    vps_dns_detect_backend() {
        VPS_DNS_BACKEND=plain
        VPS_DNS_NM_CONNECTION=""
        VPS_DNS_NM_DEVICE=""
    }
    vps_dns_require_writable_target() { return 0; }
    vps_dns_write_plain() { vps_cmd_info "演练：将替换 /etc/resolv.conf"; }
    vps_dns_refresh_backend() { vps_cmd_info "演练：将刷新 DNS 后端"; }

    output="$(vps_dns_set 2>&1)"
    assert_contains "$output" '将安装 DNS 查询依赖' "dry-run DNS dependency plan"
    assert_contains "$output" '安装依赖后将查询候选 DNS 服务器' "dry-run deferred query plan"
    assert_contains "$output" '将替换 /etc/resolv.conf' "dry-run DNS write plan after dependencies"
    assert_contains "$output" '将刷新 DNS 后端' "dry-run DNS refresh plan after dependencies"

    empty_path="${TEST_SYSTEM_ROOT}/empty-query-path"
    mkdir -p -- "$empty_path"
    output="$(PATH="$empty_path" vps_dns_verify_system_resolution 2>&1)"
    assert_contains "$output" '安装依赖后将验证系统解析链路' "dry-run deferred verify plan"
)

test_chinese_status_without_ansi() {
    local output help_output
    VPSCTL_QUIET=0 VPSCTL_NO_COLOR=1 VPSCTL_NON_INTERACTIVE=1
    vps_dns_detect_backend() {
        VPS_DNS_BACKEND=plain
        VPS_DNS_NM_CONNECTION=""
        VPS_DNS_NM_DEVICE=""
    }
    vps_dns_effective_servers() { printf '1.1.1.1\n2606:4700:4700::1111\n'; }
    output="$(vps_dns_show)"
    assert_contains "$output" 'DNS 后端：静态 /etc/resolv.conf' "Chinese backend status"
    assert_contains "$output" '活动服务器：1.1.1.1' "Chinese server status"
    assert_not_contains "$output" $'\033[' "no ANSI in non-color status"
    help_output="$(vps_dns_usage)"
    assert_contains "$help_output" '动作：' "Chinese help"
    assert_contains "$help_output" '--no-color' "standalone no-color help"
    VPSCTL_QUIET=1
}

test_backend_detection() {
    ip() { printf 'default via 192.0.2.1 dev eth0 proto dhcp\n'; }
    nmcli() {
        [[ "$*" == *'GENERAL.CONNECTION'* ]] && printf 'primary\n'
    }
    vps_dns_detect_backend
    assert_equal networkmanager "$VPS_DNS_BACKEND" "NetworkManager ownership"
    assert_equal primary "$VPS_DNS_NM_CONNECTION" "default NetworkManager connection"

    ip() { return 1; }
    nmcli() { return 1; }
    resolvectl() { return 0; }
    systemctl() { return 0; }
    vps_dns_detect_backend
    assert_equal plain "$VPS_DNS_BACKEND" "active resolved service without owned resolv.conf"
    mkdir -p "$TEST_SYSTEM_ROOT/run/systemd/resolve"
    printf 'nameserver 127.0.0.53\n' >"$TEST_SYSTEM_ROOT/run/systemd/resolve/stub-resolv.conf"
    rm -f "$TEST_SYSTEM_ROOT/etc/resolv.conf"
    ln -s ../run/systemd/resolve/stub-resolv.conf "$TEST_SYSTEM_ROOT/etc/resolv.conf"
    if [[ -L "$TEST_SYSTEM_ROOT/etc/resolv.conf" ]]; then
        vps_dns_detect_backend
        assert_equal systemd-resolved "$VPS_DNS_BACKEND" "systemd-resolved ownership"
        ip() { printf 'default via 192.0.2.1 dev eth0\n'; }
        nmcli() { [[ "$*" == *'GENERAL.CONNECTION'* ]] && printf 'primary\n'; }
        vps_dns_detect_backend
        assert_equal networkmanager "$VPS_DNS_BACKEND" "NetworkManager with resolved rc-manager stack"
        ip() { return 1; }
        nmcli() { return 1; }
        rm -f "$TEST_SYSTEM_ROOT/etc/resolv.conf"
        ln -s ../mystery-resolv.conf "$TEST_SYSTEM_ROOT/etc/resolv.conf"
        vps_dns_detect_backend
        assert_equal unsafe-symlink "$VPS_DNS_BACKEND" "unknown resolv.conf symlink"
    fi

    resolvectl() { return 1; }
    systemctl() { return 1; }
    resolvconf() { [[ "${1:-}" == --version ]] && printf 'openresolv 3.13\n'; }
    rm -f "$TEST_SYSTEM_ROOT/etc/resolv.conf"
    printf 'nameserver 192.0.2.53\n' >"$TEST_SYSTEM_ROOT/etc/resolv.conf"
    vps_dns_detect_backend
    assert_equal openresolv "$VPS_DNS_BACKEND" "openresolv ownership"

    mkdir -p "$TEST_SYSTEM_ROOT/etc/resolvconf/run"
    resolvconf() { [[ "${1:-}" == --version ]] && printf 'Debian resolvconf 1.91\n'; }
    vps_dns_detect_backend
    assert_equal debian-resolvconf "$VPS_DNS_BACKEND" "legacy Debian resolvconf ownership"
}

test_preflight_failure_does_not_write() {
    local before after status
    before="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    dig() { return 1; }
    VPS_DNS_SERVERS=(9.9.9.9)
    VPS_DNS_TEST_DOMAIN=example.com
    if vps_dns_set; then status=0; else status=$?; fi
    [[ "$status" != 0 ]] || fail "failed preflight returned success"
    after="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_equal "$before" "$after" "failed preflight must not write"
}

test_plain_replacement_preserves_directives() {
    local content count
    printf '# managed locally\n   search svc.example corp.example\nnameserver 192.0.2.1\noptions rotate timeout:1\nnameserver 192.0.2.2\n' >"$TEST_SYSTEM_ROOT/etc/resolv.conf"
    assert_equal 'svc.example corp.example' "$(vps_dns_collect_search)" "leading-space search collection"
    VPS_DNS_SERVERS=(1.1.1.1 2606:4700:4700::1111)
    vps_dns_write_plain
    content="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_contains "$content" 'search svc.example corp.example' "leading-space search preservation"
    assert_contains "$content" 'options rotate timeout:1' "options preservation"
    assert_contains "$content" 'nameserver 1.1.1.1' "IPv4 replacement"
    assert_contains "$content" 'nameserver 2606:4700:4700::1111' "IPv6 replacement"
    assert_not_contains "$content" 'nameserver 192.0.2.1' "old server removal"
    count="$(grep -c '^nameserver ' "$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_equal 2 "$count" "complete server replacement"
}

test_openresolv_replacement() {
    local content
    printf 'dynamic_order="tap0 eth0"\nname_servers="192.0.2.1"\nname_server_blacklist="192.0.2.*"\n' >"$TEST_SYSTEM_ROOT/etc/resolvconf.conf"
    VPS_DNS_SERVERS=(1.1.1.1 8.8.8.8)
    vps_dns_write_openresolv
    content="$(<"$TEST_SYSTEM_ROOT/etc/resolvconf.conf")"
    assert_contains "$content" 'dynamic_order="tap0 eth0"' "openresolv dynamic order preservation"
    assert_contains "$content" 'name_servers="1.1.1.1 8.8.8.8"' "openresolv servers"
    assert_contains "$content" 'name_server_blacklist="*"' "openresolv dynamic server exclusion"
    assert_not_contains "$content" '192.0.2.*' "old openresolv blacklist removal"
}

test_legacy_resolvconf_refusal() {
    local before after status
    mkdir -p "$TEST_SYSTEM_ROOT/etc/resolvconf/run"
    resolvconf() { [[ "${1:-}" == --version ]] && printf 'Debian resolvconf 1.91\n'; }
    dig() { printf '203.0.113.8\n'; }
    VPS_DNS_SERVERS=(8.8.8.8)
    VPS_DNS_TEST_DOMAIN=example.com
    before="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    if vps_dns_set; then status=0; else status=$?; fi
    assert_equal 3 "$status" "legacy resolvconf refusal status"
    after="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_equal "$before" "$after" "legacy resolvconf refusal must not write"
}

test_post_verify_failure_retains_change_and_restore() {
    local status content original
    rmdir "$TEST_SYSTEM_ROOT/etc/resolvconf/run"
    rmdir "$TEST_SYSTEM_ROOT/etc/resolvconf"
    original=$'search before.example\noptions rotate\nnameserver 192.0.2.44'
    printf '%s\n' "$original" >"$TEST_SYSTEM_ROOT/etc/resolv.conf"

    vps_dns_detect_backend() {
        VPS_DNS_BACKEND=plain
        VPS_DNS_NM_CONNECTION=""
        VPS_DNS_NM_DEVICE=""
    }
    vps_dns_refresh_backend() { return 0; }
    vps_cmd_lock() { return 0; }
    vps_cmd_unlock() { return 0; }
    dig() { printf '203.0.113.8\n'; }
    getent() { return 1; }
    VPS_DNS_SERVERS=(1.0.0.1)
    VPS_DNS_TEST_DOMAIN=example.com
    if vps_dns_set; then status=0; else status=$?; fi
    assert_equal 30 "$status" "post-change verify failure status"
    content="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_contains "$content" 'nameserver 1.0.0.1' "failed verification must retain new DNS"
    assert_not_contains "$content" 'nameserver 192.0.2.44' "failed verification must not auto-rollback"

    vps_dns_restore
    content="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_contains "$content" 'nameserver 192.0.2.44' "restore latest backup"
    assert_contains "$content" 'search before.example' "restore preserved search"
}

test_dry_run_does_not_write() {
    local before after lock_calls=0 backup_calls=0
    before="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    VPSCTL_DRY_RUN=1
    VPS_DNS_SERVERS=(9.9.9.9)
    VPS_DNS_TEST_DOMAIN=example.com
    vps_cmd_lock() { lock_calls=$((lock_calls + 1)); }
    vps_dns_backup_current() { backup_calls=$((backup_calls + 1)); }
    vps_dns_set
    VPSCTL_DRY_RUN=0
    after="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_equal "$before" "$after" "dry-run must not write DNS configuration"
    assert_equal 0 "$lock_calls" "dry-run lock creation"
    assert_equal 0 "$backup_calls" "dry-run backup creation"
}

test_verify_rejects_extra_upstream() {
    local status
    VPS_DNS_SERVERS=(1.1.1.1)
    vps_dns_effective_servers() { printf '1.1.1.1\n8.8.8.8\n127.0.0.53\n'; }
    if vps_dns_verify_servers; then status=0; else status=$?; fi
    [[ "$status" != 0 ]] || fail "unexpected non-loopback upstream was accepted"
}

test_explicit_restore_is_confined() {
    local outside status
    outside="$TEST_SYSTEM_ROOT/outside-backup"
    printf 'nameserver 203.0.113.53\n' >"$outside"
    if vps_dns_restore --backup "$outside"; then status=0; else status=$?; fi
    assert_equal 10 "$status" "explicit restore backup confinement"
}

test_nm_refresh_reapplies_device() (
    local calls=""
    VPS_DNS_NM_CONNECTION=primary
    VPS_DNS_NM_DEVICE=eth0
    vps_cmd_run() {
        local IFS=' '
        calls+="$*"$'\n'
    }
    vps_dns_refresh_backend networkmanager
    assert_contains "$calls" 'nmcli connection reload' "NetworkManager reload"
    assert_contains "$calls" 'nmcli device reapply eth0' "NetworkManager device reapply"
    assert_not_contains "$calls" 'connection up' "NetworkManager must not reconnect"
)

test_nm_effective_servers_are_runtime_values() {
    local output

    output="$(
        VPS_DNS_BACKEND=networkmanager
        vps_dns_resolv_link_owner() { printf 'regular\n'; }
        nmcli() {
            [[ "$*" == *'IP4.DNS,IP6.DNS device show'* ]] || return 1
            printf '1.1.1.1\n2606:4700:4700::1111\n'
        }
        vps_dns_effective_servers
    )"
    assert_contains "$output" '1.1.1.1' "NetworkManager active IPv4 server"
    assert_contains "$output" '2606:4700:4700::1111' "NetworkManager active IPv6 server"
}

test_read_only_target_rejected() {
    local status
    findmnt() { printf 'ro,relatime\n'; }
    if vps_dns_require_writable_target /etc/resolv.conf; then status=0; else status=$?; fi
    assert_equal 3 "$status" "read-only mount rejection"
    unset -f findmnt
}

test_managed_ancestor_symlink_rejected() {
    local etc_path="$TEST_SYSTEM_ROOT/etc"
    local saved_etc="$TEST_SYSTEM_ROOT/etc.saved"
    local outside_etc="$TEST_SYSTEM_ROOT/../outside-dns-etc"
    local status=0

    mv -- "$etc_path" "$saved_etc"
    mkdir -p -- "$outside_etc"
    if ln -s "$outside_etc" "$etc_path" 2>/dev/null && [[ -L "$etc_path" ]]; then
        vps_dns_require_writable_target /etc/resolv.conf >/dev/null 2>&1 || status=$?
        assert_equal 3 "$status" "managed DNS ancestor symlink rejection"
        [[ ! -e "$outside_etc/resolv.conf" ]] || fail "DNS path escaped through an ancestor symlink"
        unlink -- "$etc_path" 2>/dev/null || rmdir -- "$etc_path"
    elif [[ -e "$etc_path" || -L "$etc_path" ]]; then
        unlink -- "$etc_path" 2>/dev/null || rmdir -- "$etc_path"
    fi
    mv -- "$saved_etc" "$etc_path"
}

test_refresh_failure_after_write_returns_30() {
    local status
    VPSCTL_DRY_RUN=0
    VPS_DNS_SERVERS=(4.4.4.4)
    VPS_DNS_TEST_DOMAIN=example.com
    dig() { printf '203.0.113.8\n'; }
    vps_dns_detect_backend() {
        VPS_DNS_BACKEND=plain
        VPS_DNS_NM_CONNECTION=""
        VPS_DNS_NM_DEVICE=""
    }
    vps_dns_refresh_backend() { return 20; }
    vps_cmd_lock() { return 0; }
    vps_cmd_unlock() { return 0; }
    vps_dns_backup_current() { return 0; }
    if vps_dns_set; then status=0; else status=$?; fi
    assert_equal 30 "$status" "refresh failure after write"
    assert_contains "$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")" 'nameserver 4.4.4.4' "refresh failure retains write"
}

test_restore_metadata_trust_boundary() {
    local root missing outside status
    root="$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/network/dns"
    mkdir -p "$root/missing-meta"
    missing="$root/missing-meta/resolv.conf"
    printf 'nameserver 1.1.1.1\n' >"$missing"
    if vps_dns_restore --backup "$missing"; then status=0; else status=$?; fi
    assert_equal 10 "$status" "explicit backup without metadata"
    outside="$TEST_SYSTEM_ROOT/forged-backup"
    printf 'nameserver 8.8.8.8\n' >"$outside"
    printf 'backup=%s\n' "$outside" >"$root/latest"
    if vps_dns_restore; then status=0; else status=$?; fi
    assert_equal 10 "$status" "forged latest backup escape"
}

test_nm_restore_rejects_unknown_property() {
    local dir backup status
    dir="$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/network/dns/nm-forged"
    mkdir -p "$dir"
    backup="$dir/.current-state"
    {
        printf 'connection=primary\ndevice=eth0\n'
        printf 'ipv4.gateway=192.0.2.1\n'
    } >"$backup"
    {
        printf 'backend=networkmanager\nkind=networkmanager\ntarget=@networkmanager\nbackup=%s\n' "$backup"
    } >"$dir/metadata"
    vps_dns_detect_backend() {
        VPS_DNS_BACKEND=networkmanager
        VPS_DNS_NM_CONNECTION=primary
        VPS_DNS_NM_DEVICE=eth0
    }
    if vps_dns_restore --backup "$backup"; then status=0; else status=$?; fi
    assert_equal 10 "$status" "unknown NetworkManager restore property"
}

test_address_validation
test_standalone_globals
test_dependency_authorization
test_dry_run_dependency_and_dns_plan
test_backend_detection
test_preflight_failure_does_not_write
test_plain_replacement_preserves_directives
test_openresolv_replacement
test_nm_refresh_reapplies_device
test_nm_effective_servers_are_runtime_values
test_read_only_target_rejected
test_managed_ancestor_symlink_rejected
test_legacy_resolvconf_refusal
test_post_verify_failure_retains_change_and_restore
test_dry_run_does_not_write
test_verify_rejects_extra_upstream
test_explicit_restore_is_confined
test_refresh_failure_after_write_returns_30
test_restore_metadata_trust_boundary
test_nm_restore_rejects_unknown_property
test_chinese_status_without_ansi
printf 'PASS: network DNS tests\n'
