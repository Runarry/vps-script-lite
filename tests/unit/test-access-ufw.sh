#!/usr/bin/env bash
# Exercise SSH transaction ordering against the shared UFW API. The UFW engine's
# real inventory, adoption and cross-owner behavior are covered by its own suite.
# shellcheck disable=SC2317,SC2034

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
readonly TEST_ROOT TEST_TEMP
# shellcheck source=../../commands/security/access.sh
source "$TEST_ROOT/commands/security/access.sh"
trap 'rm -rf -- "$TEST_TEMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
log_event() { printf '%s\n' "$*" >>"$EVENTS"; }
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_before() {
    local first second
    first="$(awk -v event="$1" '$0 == event {print NR; exit}' "$EVENTS")"
    second="$(awk -v event="$2" '$0 == event {print NR; exit}' "$EVENTS")"
    [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]] || fail "$1 must precede $2"
}
assert_status() {
    local expected="$1" actual=0
    shift
    "$@" >"$FIXTURE/output" 2>&1 || actual=$?
    assert_equal "$expected" "$actual" "$*"
}

vps_cmd_require_root() { return 0; }
vps_cmd_lock() { log_event security.lock; }
vps_cmd_unlock() { log_event security.unlock; }
vps_cmd_confirm_token() { return 0; }
vps_ufw_init() { return 0; }
vps_ufw_require_tools() { return 0; }
vps_ufw_ipv6_available() { [[ "$MOCK_IPV6" == 1 ]]; }
vps_ufw_owner_detached() { [[ "$MOCK_DETACHED" == 1 ]]; }
vps_ufw_lock() {
    UFW_LOCKS=$((UFW_LOCKS + 1))
    log_event ufw.lock
}
vps_ufw_unlock() {
    UFW_LOCKS=$((UFW_LOCKS - 1))
    log_event ufw.unlock
}
vps_ufw_scope_desired() { cat -- "$FIXTURE/scope.json"; }
vps_ufw_inventory() { cat -- "$FIXTURE/inventory.json"; }
vps_ufw_scope_snapshot() {
    [[ "$1" == ssh && "$UFW_LOCKS" -gt 0 ]] || fail 'snapshot must hold the shared lock'
    log_event ufw.snapshot
    cp -- "$FIXTURE/scope.json" "$2"
    chmod 0600 -- "$2"
}
vps_ufw_begin() {
    [[ "$1" == ssh ]] || fail 'SSH changed another scope'
    log_event ufw.begin
    ((MOCK_BEGIN_FAIL == 0)) || return 3
    UFW_LOCKS=$((UFW_LOCKS + 1))
    cp -- "$FIXTURE/scope.json" "$FIXTURE/before.json"
    if [[ "$MOCK_DETACHED" == 1 ]]; then
        printf '[]\n' >"$FIXTURE/pending.json"
    else
        cp -- "$2" "$FIXTURE/pending.json"
    fi
}
vps_ufw_commit() {
    log_event ufw.commit
    UFW_LOCKS=$((UFW_LOCKS - 1))
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        cp -- "$FIXTURE/pending.json" "$FIXTURE/scope.json"
    fi
    ((MOCK_COMMIT_FAIL == 0)) || return 30
}
vps_ufw_scope_restore_begin() {
    log_event ufw.restore
    vps_ufw_begin "$1" "$2"
}
vps_ufw_rollback() {
    log_event ufw.rollback
    UFW_LOCKS=$((UFW_LOCKS - 1))
    cp -- "$FIXTURE/before.json" "$FIXTURE/scope.json"
}

access_sshd_validate_candidate() { return 0; }
access_sshd_validate_standard() { return 0; }
access_sshd_assert_effective() { return 0; }
access_sshd_install_candidate() {
    log_event ssh.install
    cp -- "$1" "$ACCESS_CONFIG"
}
access_sshd_restore_backup_config() {
    log_event ssh.restore
    printf 'restored\n' >"$ACCESS_CONFIG"
}
access_sshd_reload() {
    log_event ssh.reload
    ((MOCK_RELOAD_FAIL == 0))
}
access_sshd_port_listening() {
    log_event "ssh.listen.$1"
    ((MOCK_LISTEN_FAIL == 0))
}
access_sshd_verify_ports() {
    log_event "ssh.verify.$2"
    ((MOCK_LISTEN_FAIL == 0))
}
access_sshd_find_proof() { printf '%s\n' "$TX_DIR/proofs/proof.1001"; }
access_sshd_proof_policy() { return 0; }
access_sshd_cancel_abort() { log_event timer.cancel; }
access_sshd_print_recovery() { log_event recovery; }

TEST_INDEX=0
TX_ID='tx-20260908T120000Z-0123456789abcdef'
BACKUP_ID='bak-20260908T120000Z-0123456789abcdef'
reset_fixture() {
    TEST_INDEX=$((TEST_INDEX + 1))
    FIXTURE="$TEST_TEMP/$TEST_INDEX"
    EVENTS="$FIXTURE/events"
    export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$FIXTURE/system" VPSCTL_DRY_RUN=0 VPSCTL_NO_COLOR=1
    MOCK_IPV6=1 MOCK_DETACHED=0 MOCK_BEGIN_FAIL=0 MOCK_COMMIT_FAIL=0 MOCK_RELOAD_FAIL=0 MOCK_LISTEN_FAIL=0 UFW_LOCKS=0
    mkdir -p -- "$VPSCTL_SYSTEM_ROOT/etc/ssh/sshd_config.d"
    : >"$EVENTS"
    printf '[]\n' >"$FIXTURE/scope.json"
    printf '[]\n' >"$FIXTURE/inventory.json"
    access_common_init
    access_firewall_init
    access_prepare_layout >/dev/null 2>&1
    TX_DIR="$ACCESS_TRANSACTION_DIR/$TX_ID"
    BACKUP_DIR="$ACCESS_BACKUP_DIR/$BACKUP_ID"
    mkdir -p -- "$TX_DIR/proofs" "$BACKUP_DIR"
    chmod 0700 -- "$BACKUP_DIR" "$TX_DIR/proofs"
    printf 'pending\n' >"$ACCESS_CONFIG"
    access_firewall_write_state ufw 22
    cp -- "$ACCESS_FW_STATE" "$BACKUP_DIR/firewall.state"
    access_firewall_backup_mode_write "$BACKUP_DIR" auto
}

seed_transaction() {
    local now sha
    now="$(date +%s)"
    sha="$(access_sha256_file "$ACCESS_CONFIG")"
    access_sshd_write_transaction "$TX_DIR" prepared "$TX_ID" "$BACKUP_ID" "$((now - 10))" "$((now + 900))" \
        22 2222 yes yes yes yes no '' auto ufw ufw-shared ufw 22 '' "$sha"
    {
        access_kv_put schema_version 1
        access_kv_put kind ssh
        access_kv_put transaction_id "$TX_ID"
        access_kv_put old_port 22
        access_kv_put new_port 2222
        access_kv_put lifecycle prepared
        access_kv_put applied_sha256 ''
    } >"$BACKUP_DIR/manifest"
    {
        access_kv_put transaction_id "$TX_ID"
        access_kv_put server_port 2222
        access_kv_put auth_method publickey
        access_kv_put user alice
        access_kv_put verified_epoch "$now"
    } >"$TX_DIR/proofs/proof.1001"
    access_write_active "$TX_ID"
}

reset_fixture
assert_status 0 access_firewall_open ufw 2222 22 0 "$BACKUP_DIR"
assert_equal '22,2222' "$(jq -r '[.[].port] | unique | join(",")' "$FIXTURE/scope.json")" 'prepare retains both ports'
assert_equal 4 "$(jq length "$FIXTURE/scope.json")" 'prepare covers both available families'
assert_equal ufw-shared "$ACCESS_FW_ADDED" 'shared transaction discriminator'
assert_equal 0 "$UFW_LOCKS" 'prepare releases shared lock before waiting for SSH proof'
assert_before ufw.lock ufw.snapshot
assert_before ufw.snapshot ufw.begin
assert_before ufw.commit ufw.unlock
seed_transaction
: >"$EVENTS"
assert_status 0 access_ssh_commit "$TX_ID" "$TX_ID"
assert_before ssh.reload ssh.verify.2222
assert_before ssh.verify.2222 ufw.begin
assert_equal '2222' "$(jq -r '[.[].port] | unique | join(",")' "$FIXTURE/scope.json")" 'commit releases old SSH requirement'
assert_equal committed "$(access_kv_get "$TX_DIR/state" status)" 'SSH transaction committed'

: >"$EVENTS"
assert_status 0 access_ssh_restore "$BACKUP_ID"
assert_before ufw.restore ssh.restore
assert_before ssh.listen.22 ufw.commit
assert_equal 0 "$(jq length "$FIXTURE/scope.json")" 'restore reinstates original scope'
assert_equal 22 "$(access_kv_get "$ACCESS_FW_STATE" port)" 'restore preserves legacy state snapshot'

reset_fixture
assert_status 0 access_firewall_open ufw 2222 22 0 "$BACKUP_DIR"
seed_transaction
MOCK_RELOAD_FAIL=1
: >"$EVENTS"
assert_status 30 access_ssh_abort "$TX_ID"
assert_before ufw.restore ssh.restore
assert_before ssh.reload ufw.rollback
assert_equal prepared "$(access_kv_get "$TX_DIR/state" status)" 'failed abort remains retryable'
assert_equal '22,2222' "$(jq -r '[.[].port] | unique | join(",")' "$FIXTURE/scope.json")" 'failed rollback keeps both requirements'
assert_equal 0 "$UFW_LOCKS" 'failed abort releases shared lock'
MOCK_RELOAD_FAIL=0
: >"$EVENTS"
assert_status 0 access_ssh_abort "$TX_ID"
assert_before ssh.listen.22 ufw.commit
assert_equal aborted "$(access_kv_get "$TX_DIR/state" status)" 'successful retry aborts transaction'

reset_fixture
before_state="$(cat -- "$ACCESS_FW_STATE")"
assert_status 0 access_firewall_commit none 22 2222 0 ufw 22 '' manual
assert_equal "$before_state" "$(cat -- "$ACCESS_FW_STATE")" 'manual commit preserves existing ownership metadata'
[[ ! -s "$EVENTS" ]] || fail 'manual commit called shared UFW'
access_firewall_backup_mode_write "$BACKUP_DIR" manual
seed_transaction
assert_equal manual "$(access_firewall_backup_mode "$BACKUP_DIR")" 'manual backup mode takes precedence'
sed -i 's/^firewall_mode\tauto$/firewall_mode\tmanual/' "$TX_DIR/state"
rm -f -- "$BACKUP_DIR/firewall.mode"
assert_equal manual "$(access_firewall_backup_mode "$BACKUP_DIR")" 'legacy backup reads original transaction mode'
rm -f -- "$ACCESS_STATE_DIR/active"
access_sshd_backup_mark "$BACKUP_DIR" committed "$(access_sha256_file "$ACCESS_CONFIG")"
# Even an unrelated leftover scope snapshot cannot authorize a manual restore.
printf '[]\n' >"$BACKUP_DIR/ufw.scope.json"
: >"$EVENTS"
assert_status 0 access_ssh_restore "$BACKUP_ID"
if grep -q '^ufw\.' "$EVENTS"; then fail 'manual restore called shared UFW'; fi
assert_equal "$before_state" "$(cat -- "$ACCESS_FW_STATE")" 'manual restore preserves firewall state'

reset_fixture
MOCK_IPV6=0
assert_status 0 access_firewall_open ufw 2222 22 0 "$BACKUP_DIR"
assert_equal ipv4 "$(jq -r '[.[].family] | unique | join(",")' "$FIXTURE/scope.json")" 'IPv6-disabled UFW gets only available family'
MOCK_DETACHED=1
assert_status 0 access_firewall_commit ufw 22 2222 ufw-shared ufw 22 '' auto
[[ ! -e "$ACCESS_FW_STATE" ]] || fail 'commit revived detached SSH ownership state'
assert_equal 0 "$(jq length "$FIXTURE/scope.json")" 'detached SSH is not reattached'

reset_fixture
printf '[{"simple":true,"kind":"input","family":"ipv4","action":"allow","proto":"tcp","port":"2222","source":"any","destination":"any","comment":"vpsctl security access"}]\n' >"$FIXTURE/inventory.json"
assert_status 0 access_firewall_abort ufw 2222 1 ufw 22 '' "$BACKUP_DIR"
assert_equal 0 "$(jq length "$FIXTURE/scope.json")" 'legacy abort releases only imported legacy requirement'
assert_equal 0 "$UFW_LOCKS" 'legacy cleanup releases shared lock'

reset_fixture
MOCK_BEGIN_FAIL=1
assert_status 3 access_firewall_open ufw 2222 22 0 "$BACKUP_DIR"
assert_equal 0 "$UFW_LOCKS" 'failed prepare releases snapshot lock'
assert_equal 0 "$ACCESS_FW_ADDED" 'failed begin is not recorded as an applied change'

printf 'PASS: SSH shared UFW transaction ordering, rollback and manual isolation\n'
