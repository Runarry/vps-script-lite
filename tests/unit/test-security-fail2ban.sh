#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-fail2ban-test.XXXXXX")"
readonly TEST_ROOT TEST_TMP
readonly MOCK_BIN="${TEST_TMP}/mock-bin"
readonly SYSTEM_ROOT="${TEST_TMP}/system-root"
readonly MOCK_LOG="${TEST_TMP}/mock.log"

cleanup() { rm -rf -- "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_status() {
    local expected="$1" message="$2" output status=0
    shift 2
    output="$("$@" 2>&1)" || status=$?
    [[ "$status" == "$expected" ]] || fail "$message: expected $expected, got $status; output: $output"
    FAIL2BAN_TEST_OUTPUT="$output"
}
assert_file_contains() { grep -Fq -- "$2" "$1" || fail "$3: missing '$2' in $1"; }

make_mock() {
    local name="$1"
    shift
    printf '#!/usr/bin/env bash\n%s\n' "$*" >"${MOCK_BIN}/${name}"
    chmod +x -- "${MOCK_BIN}/${name}"
}

mkdir -p -- "$MOCK_BIN" "$SYSTEM_ROOT"
: >"$MOCK_LOG"

make_mock systemctl '
printf "systemctl" >>"${MOCK_LOG}"
printf " %s" "$@" >>"${MOCK_LOG}"
printf "\n" >>"${MOCK_LOG}"
case "${1:-}" in
    is-active) [[ -e "${VPSCTL_SYSTEM_ROOT}/run/fail2ban-active" ]] ;;
    is-enabled) [[ -e "${VPSCTL_SYSTEM_ROOT}/run/fail2ban-enabled" ]] ;;
    enable)
        : >"${VPSCTL_SYSTEM_ROOT}/run/fail2ban-enabled"
        [[ " $* " != *" --now "* ]] || : >"${VPSCTL_SYSTEM_ROOT}/run/fail2ban-active"
        ;;
    start|restart) : >"${VPSCTL_SYSTEM_ROOT}/run/fail2ban-active" ;;
    stop) rm -f -- "${VPSCTL_SYSTEM_ROOT}/run/fail2ban-active" ;;
    disable) rm -f -- "${VPSCTL_SYSTEM_ROOT}/run/fail2ban-enabled" ;;
esac'

make_mock fail2ban-client '
printf "fail2ban-client" >>"${MOCK_LOG}"
printf " %s" "$@" >>"${MOCK_LOG}"
printf "\n" >>"${MOCK_LOG}"
case "${1:-}" in
    -V) printf "%s\n" "${MOCK_FAIL2BAN_VERSION_OUTPUT:-Fail2Ban v1.0.2}" ;;
    -t) [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-config-test" ]] ;;
    reload)
        if [[ -e "${VPSCTL_SYSTEM_ROOT}/run/fail-reload-once" ]]; then
            rm -f -- "${VPSCTL_SYSTEM_ROOT}/run/fail-reload-once"
            exit 1
        fi
        ;;
    ping) [[ -e "${VPSCTL_SYSTEM_ROOT}/run/fail2ban-active" ]] ;;
    status)
        [[ "${2:-}" == sshd && -e "${VPSCTL_SYSTEM_ROOT}/run/fail2ban-active" ]] || exit 1
        printf "Status for the jail: sshd\n"
        if [[ -s "${VPSCTL_SYSTEM_ROOT}/run/banned" ]]; then
            printf "Currently banned: 1\nTotal banned: 1\nBanned IP list: %s\n" "$(<"${VPSCTL_SYSTEM_ROOT}/run/banned")"
        else
            printf "Currently banned: 0\nTotal banned: 0\nBanned IP list:\n"
        fi
        ;;
    set)
        [[ "${2:-}" == sshd ]] || exit 1
        case "${3:-}" in
            banip)
                if [[ ! -f "${VPSCTL_SYSTEM_ROOT}/run/banned" ]] || ! grep -Fqx -- "$4" "${VPSCTL_SYSTEM_ROOT}/run/banned"; then
                    printf "%s\n" "$4" >>"${VPSCTL_SYSTEM_ROOT}/run/banned"
                    count=0; [[ ! -f "${VPSCTL_SYSTEM_ROOT}/run/total-bans" ]] || count="$(<"${VPSCTL_SYSTEM_ROOT}/run/total-bans")"
                    printf "%s\n" "$((count + 1))" >"${VPSCTL_SYSTEM_ROOT}/run/total-bans"
                fi
                ;;
            unbanip)
                [[ -f "${VPSCTL_SYSTEM_ROOT}/run/banned" ]] || exit 0
                grep -Fvx -- "$4" "${VPSCTL_SYSTEM_ROOT}/run/banned" >"${VPSCTL_SYSTEM_ROOT}/run/banned.tmp" || true
                mv -f -- "${VPSCTL_SYSTEM_ROOT}/run/banned.tmp" "${VPSCTL_SYSTEM_ROOT}/run/banned"
                ;;
            *) exit 1 ;;
        esac
        ;;
    get)
        [[ "${2:-}" == sshd && "${4:-}" == banned ]] || exit 1
        case "${3:-}" in
            currently) if [[ -s "${VPSCTL_SYSTEM_ROOT}/run/banned" ]]; then grep -c . "${VPSCTL_SYSTEM_ROOT}/run/banned"; else printf "0\n"; fi ;;
            total) if [[ -f "${VPSCTL_SYSTEM_ROOT}/run/total-bans" ]]; then cat "${VPSCTL_SYSTEM_ROOT}/run/total-bans"; else printf "0\n"; fi ;;
            *) exit 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac'

make_mock sshd '
[[ "${1:-}" == -T ]] || exit 1
while IFS= read -r port; do printf "port %s\n" "$port"; done <"${VPSCTL_SYSTEM_ROOT}/run/ssh-port"'

make_mock firewall-cmd 'exit 1'
make_mock ufw 'printf "Status: inactive\n"'
make_mock nft 'exit 0'
make_mock journalctl '
printf "journalctl" >>"${MOCK_LOG}"
printf " %s" "$@" >>"${MOCK_LOG}"
printf "\n" >>"${MOCK_LOG}"
printf "mock fail2ban log\n"'
make_mock flock 'exit 0'
make_mock apt-get '
printf "apt-get" >>"${MOCK_LOG}"
printf " %s" "$@" >>"${MOCK_LOG}"
printf "\n" >>"${MOCK_LOG}"'

export PATH="${MOCK_BIN}:/usr/bin:/bin"
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$SYSTEM_ROOT"
export VPSCTL_ENV_KERNEL_NAME=Linux VPSCTL_ENV_INIT=systemd VPSCTL_ENV_PACKAGE_MANAGER=apt-get
export VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0 VPSCTL_ASSUME_YES=1 VPSCTL_NON_INTERACTIVE=1
export VPSCTL_QUIET=0 VPSCTL_VERBOSE=0 VPSCTL_NO_COLOR=1
export MOCK_LOG

run_fail2ban() {
    bash "$TEST_ROOT/commands/security/fail2ban.sh" --no-color --non-interactive "$@"
}

reset_system() {
    rm -rf -- "$SYSTEM_ROOT"
    mkdir -p -- "$SYSTEM_ROOT/etc/fail2ban/jail.d" "$SYSTEM_ROOT/run"
    printf '22\n' >"$SYSTEM_ROOT/run/ssh-port"
    : >"$MOCK_LOG"
}

first_backup() {
    local manifest
    for manifest in "$SYSTEM_ROOT"/var/lib/vpsctl/backups/security/fail2ban/bak-*/manifest; do
        [[ -e "$manifest" ]] || continue
        grep -Fqx $'config_existed\t0' "$manifest" || continue
        printf '%s\n' "${manifest%/manifest}" | sed 's|.*/||'
        return 0
    done
    return 1
}

test_cli_and_install() {
    local config="$SYSTEM_ROOT/etc/fail2ban/jail.d/99-vpsctl-sshd.local" output
    reset_system
    output="$(run_fail2ban status --json)"
    assert_contains "$output" '"installed":true' "installed status"
    assert_contains "$output" '"state":"missing"' "missing config status"
    assert_status 2 "unknown status option" run_fail2ban status --bad
    assert_status 2 "invalid maxretry" run_fail2ban configure --maxretry 101
    assert_status 2 "missing install ignore value" run_fail2ban install --ignore-ip

    run_fail2ban install --ignore-ip 198.51.100.0/24 --ignore-ip 198.51.100.0/24
    assert_file_contains "$config" '# Managed by vpsctl security fail2ban.' "managed marker"
    assert_file_contains "$config" 'ignoreip = 127.0.0.1/8 ::1 198.51.100.0/24' "default and deduplicated ignore addresses"
    assert_file_contains "$config" 'maxretry = 5' "default maxretry"
    assert_file_contains "$config" 'findtime = 10m' "default findtime"
    assert_file_contains "$config" 'bantime = 1h' "default bantime"
    assert_file_contains "$config" 'bantime.increment = true' "default incremental bans"
    assert_file_contains "$config" 'bantime.maxtime = 1w' "default maximum ban"
    assert_file_contains "$config" 'usedns = no' "disabled DNS lookup"
    assert_file_contains "$config" 'banaction = nftables-multiport' "nftables selection"
    [[ "$(grep -c '^\[sshd\]$' "$config")" == 1 ]] || fail "managed config did not define exactly one sshd section"
    ! grep -Fq '[DEFAULT]' "$config" || fail "managed settings leaked into DEFAULT"
    [[ -s "$SYSTEM_ROOT/var/lib/vpsctl/security/fail2ban/config.sha256" ]] || fail "managed hash not recorded"
    assert_file_contains "$SYSTEM_ROOT/var/lib/vpsctl/security/fail2ban/metadata" $'schema_version\t1' "state metadata schema"
    [[ -e "$SYSTEM_ROOT/run/fail2ban-active" ]] || fail "install did not start fail2ban"
    assert_contains "$(<"$MOCK_LOG")" 'fail2ban-client -t' "config test"
    assert_contains "$(<"$MOCK_LOG")" 'fail2ban-client status sshd' "post-apply jail status"
    assert_contains "$(<"$MOCK_LOG")" 'apt-get install -y --no-install-recommends fail2ban python3-systemd' "apt package plan"
}

test_config_ignore_sync_and_services() {
    local config="$SYSTEM_ROOT/etc/fail2ban/jail.d/99-vpsctl-sshd.local" output
    reset_system
    run_fail2ban install
    run_fail2ban configure --bantime 2h --findtime 20m --maxretry 8 --increment off --max-bantime 2w
    assert_file_contains "$config" 'bantime = 2h' "configured bantime"
    assert_file_contains "$config" 'maxretry = 8' "configured maxretry"
    assert_file_contains "$config" 'bantime.increment = false' "disabled increment"
    assert_status 2 "duplicate configure option" run_fail2ban configure --bantime 1h --bantime 2h
    assert_status 2 "increment maxtime lower than bantime" run_fail2ban configure --increment on --bantime 2w --max-bantime 1w

    run_fail2ban ignore add --ip 203.0.113.7
    output="$(run_fail2ban ignore list)"
    assert_contains "$output" '203.0.113.7' "ignore add/list"
    run_fail2ban ignore remove --ip 203.0.113.7
    assert_status 3 "loopback ignore is immutable" run_fail2ban ignore remove --ip ::1

    printf '2222\n22\n2222\n' >"$SYSTEM_ROOT/run/ssh-port"
    run_fail2ban sync-ssh-port
    assert_file_contains "$config" 'port = 22,2222' "normalized multi-port synchronization"
    output="$(run_fail2ban status --json)"
    assert_contains "$output" '"version":"1.0.2"' "JSON version"
    assert_contains "$output" '"current_ports":[22,2222]' "JSON current ports"
    assert_contains "$output" '"managed_ports":[22,2222]' "JSON managed ports"
    assert_contains "$output" '"ports_synced":true' "JSON port synchronization"
    assert_contains "$output" '"ignoreip":["127.0.0.1/8","::1"]' "JSON ignore array"

    run_fail2ban stop
    [[ ! -e "$SYSTEM_ROOT/run/fail2ban-active" ]] || fail "stop left service active"
    run_fail2ban start
    run_fail2ban restart
    run_fail2ban unban --ip 192.0.2.44
    output="$(run_fail2ban logs --lines 25)"
    assert_contains "$output" 'mock fail2ban log' "journal output"
    assert_contains "$(<"$MOCK_LOG")" 'journalctl -u fail2ban.service --no-pager -n 25' "journal arguments"
}

test_drift_rollback_and_verify_cleanup() {
    local config="$SYSTEM_ROOT/etc/fail2ban/jail.d/99-vpsctl-sshd.local" before after
    reset_system
    run_fail2ban install
    before="$(sha256sum "$config")"
    : >"$SYSTEM_ROOT/run/fail-config-test"
    assert_status 20 "config test failure rolls back" run_fail2ban configure --maxretry 9
    after="$(sha256sum "$config")"
    [[ "$before" == "$after" ]] || fail "failed configure changed managed config"
    rm -f -- "$SYSTEM_ROOT/run/fail-config-test"

    printf '192.0.2.1\n' >"$SYSTEM_ROOT/run/banned"
    run_fail2ban verify
    assert_file_contains "$SYSTEM_ROOT/run/banned" '192.0.2.1' "pre-existing TEST-NET ban retained"
    assert_contains "$(<"$MOCK_LOG")" 'set sshd banip 198.51.100.1' "alternate fixed TEST-NET ban"
    assert_contains "$(<"$MOCK_LOG")" 'set sshd unbanip 198.51.100.1' "alternate TEST-NET cleanup"

    printf '# administrator edit\n' >>"$config"
    assert_status 30 "managed hash drift rejection" run_fail2ban configure --maxretry 7
    assert_contains "$FAIL2BAN_TEST_OUTPUT" '哈希漂移' "drift diagnostic"
}

test_adoption_restore_and_uninstall() {
    local config="$SYSTEM_ROOT/etc/fail2ban/jail.d/99-vpsctl-sshd.local" backup
    reset_system
    printf '[sshd]\nenabled = true\n' >"$SYSTEM_ROOT/etc/fail2ban/jail.local"
    assert_status 10 "existing jail requires adoption" run_fail2ban install
    run_fail2ban install --adopt-existing
    run_fail2ban configure --maxretry 6
    backup="$(first_backup)" || fail "no backup created"
    # The first install backup represents an absent managed target and is a valid restore target.
    run_fail2ban restore --backup "$backup" --confirm-restore "$backup"
    [[ ! -e "$config" ]] || fail "restore did not reinstate absent managed target"
    assert_file_contains "$SYSTEM_ROOT/var/lib/vpsctl/backups/security/fail2ban/$backup/manifest" $'lifecycle\trestored' "restore lifecycle"

    run_fail2ban install --adopt-existing
    assert_status 2 "uninstall confirmation token" run_fail2ban uninstall --confirm-uninstall WRONG
    run_fail2ban uninstall --confirm-uninstall REMOVE-VPSCTL-FAIL2BAN
    [[ ! -e "$config" ]] || fail "uninstall retained managed config"
    [[ -e "$SYSTEM_ROOT/run/fail2ban-active" ]] || fail "uninstall stopped service"
    [[ -d "$SYSTEM_ROOT/var/lib/vpsctl/backups/security/fail2ban" ]] || fail "uninstall removed backups"
}

test_missing_backend_package_plan() {
    reset_system
    mv -- "$MOCK_BIN/nft" "$MOCK_BIN/nft.disabled"
    run_fail2ban install
    assert_contains "$(<"$MOCK_LOG")" 'apt-get install -y --no-install-recommends fail2ban python3-systemd nftables' "missing backend installs nftables"
    mv -- "$MOCK_BIN/nft.disabled" "$MOCK_BIN/nft"
}

test_plain_version_output() {
    reset_system
    export MOCK_FAIL2BAN_VERSION_OUTPUT=1.1.0
    run_fail2ban install
    assert_contains "$(run_fail2ban status --json)" '"version":"1.1.0"' "plain fail2ban-client -V output"
    unset MOCK_FAIL2BAN_VERSION_OUTPUT
}

test_readonly_status_without_systemd() {
    local output
    reset_system
    output="$(VPSCTL_ENV_INIT=none run_fail2ban status --json)"
    assert_contains "$output" '"platform":"none"' "status init diagnostic"
    assert_status 3 "install still requires systemd" env VPSCTL_ENV_INIT=none \
        bash "$TEST_ROOT/commands/security/fail2ban.sh" --no-color --non-interactive install
}

test_cli_and_install
test_config_ignore_sync_and_services
test_drift_rollback_and_verify_cleanup
test_adoption_restore_and_uninstall
test_missing_backend_package_plan
test_plain_version_output
test_readonly_status_without_systemd
printf 'PASS: security fail2ban unit tests\n'
