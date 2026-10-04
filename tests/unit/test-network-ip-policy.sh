#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
readonly TEST_ROOT TEST_TEMP
readonly TEST_SYSTEM_ROOT="${TEST_TEMP}/system"
readonly TEST_FAKE_BIN="${TEST_TEMP}/bin"
readonly TEST_IP_POLICY="${TEST_ROOT}/commands/network/ip-policy.sh"
trap 'rm -rf -- "$TEST_TEMP"' EXIT

test_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

test_assert_equal() {
    local expected="$1" actual="$2" message="$3"
    [[ "$expected" == "$actual" ]] || test_fail "${message}: expected '${expected}', got '${actual}'${RUN_OUTPUT:+; output: $RUN_OUTPUT}"
}

test_assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    [[ "$haystack" == *"$needle"* ]] || test_fail "${message}: missing '${needle}'"
}

test_assert_file_contains() {
    local file="$1" needle="$2" message="$3"
    [[ -f "$file" ]] || test_fail "${message}: missing file ${file}"
    grep -Fq -- "$needle" "$file" || test_fail "${message}: missing '${needle}'"
}

mkdir -p "$TEST_FAKE_BIN"
cat >"${TEST_FAKE_BIN}/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-o -4 address show scope global") printf '2: eth0    inet 192.0.2.10/24 scope global eth0\n' ;;
    "-o -6 address show scope global") printf '2: eth0    inet6 2001:db8::10/64 scope global eth0\n' ;;
    "-4 route show default") printf 'default via 192.0.2.1 dev eth0\n' ;;
    "-6 route show default") printf 'default via 2001:db8::1 dev eth0\n' ;;
    *) exit 2 ;;
esac
EOF
chmod +x "${TEST_FAKE_BIN}/ip"

export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_NON_INTERACTIVE=1
export VPSCTL_ASSUME_YES=1
export VPSCTL_DRY_RUN=0
export VPSCTL_NO_COLOR=1
export VPSCTL_QUIET=0
export VPSCTL_VERBOSE=0
export VPSCTL_ENV_LIBC=glibc
export PATH="${TEST_FAKE_BIN}:${PATH}"

RUN_STATUS=0
RUN_OUTPUT=""
run_policy() {
    if RUN_OUTPUT="$(bash "$TEST_IP_POLICY" "$@" 2>&1)"; then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
}

reset_root() {
    rm -rf -- "$TEST_SYSTEM_ROOT"
    mkdir -p "$TEST_SYSTEM_ROOT/etc" "$TEST_SYSTEM_ROOT/run"
}

gai_path() { printf '%s' "$TEST_SYSTEM_ROOT/etc/gai.conf"; }
state_path() { printf '%s' "$TEST_SYSTEM_ROOT/var/lib/vpsctl/network/ip-policy/state.json"; }

test_arguments_and_unmanaged_status() {
    local output
    reset_root
    run_policy set
    test_assert_equal 2 "$RUN_STATUS" "missing policy"
    run_policy set --policy ipv4_only
    test_assert_equal 2 "$RUN_STATUS" "unsupported global single-stack policy"
    run_policy status --json
    test_assert_equal 0 "$RUN_STATUS" "unmanaged JSON status"
    output="$RUN_OUTPUT"
    jq -e '
        .scope == "glibc_getaddrinfo_order" and .policy == "unmanaged" and
        .managed == false and .ownership == "unmanaged" and .state_saved == false and
        (.diagnostics.ipv4_addresses | contains("192.0.2.10/24")) and
        (.diagnostics.ipv6_addresses | contains("2001:db8::10/64"))
    ' >/dev/null <<<"$output" || test_fail "unmanaged status JSON fields"
    run_policy status
    test_assert_equal 0 "$RUN_STATUS" "unmanaged human status"
    test_assert_contains "$RUN_OUTPUT" 'glibc_getaddrinfo_order' "human status scope"
}

test_musl_platform_refusal() {
    local before

    reset_root
    printf '# Alpine resolver policy must remain untouched\n' >"$(gai_path)"
    before="$(<"$(gai_path)")"
    VPSCTL_ENV_LIBC=musl run_policy status
    test_assert_equal 3 "$RUN_STATUS" "musl status refusal"
    test_assert_contains "$RUN_OUTPUT" "仅适用于 glibc" "musl refusal message"
    test_assert_equal "$before" "$(<"$(gai_path)")" "musl status zero write"
    [[ ! -e "$(state_path)" ]] || test_fail "musl status wrote state"

    VPSCTL_ENV_LIBC=musl run_policy --help
    test_assert_equal 0 "$RUN_STATUS" "musl help availability"
}

test_managed_tables_update_and_status() {
    local state backup backup_count first_state_hash
    reset_root
    printf '# administrator comment\n\n' >"$(gai_path)"
    chmod 0640 "$(gai_path)"

    run_policy set --policy prefer_ipv4
    test_assert_equal 0 "$RUN_STATUS" "set prefer_ipv4"
    test_assert_equal 9 "$(grep -c '^precedence ' "$(gai_path)")" "complete precedence row count"
    test_assert_file_contains "$(gai_path)" 'precedence ::ffff:0:0/96 100' "IPv4 preference precedence"
    test_assert_file_contains "$(gai_path)" 'precedence ::1/128       50' "loopback precedence"
    state="$(state_path)"
    jq -e '
        .schema_version == 1 and .scope == "glibc_getaddrinfo_order" and
        .target == "/etc/gai.conf" and .original_present == true and
        .original_mode == "640" and .managed_policy == "prefer_ipv4" and
        (.managed_sha256 | test("^[0-9a-f]{64}$"))
    ' "$state" >/dev/null || test_fail "managed state metadata"
    backup="$(jq -r '.backup_file' "$state")"
    [[ -f "${TEST_SYSTEM_ROOT}${backup}" ]] || test_fail "original gai.conf backup missing"
    test_assert_equal '# administrator comment' "$(sed -n '1p' "${TEST_SYSTEM_ROOT}${backup}")" "original backup content"
    first_state_hash="$(sha256sum "$state" | awk '{print $1}')"

    run_policy set --policy prefer_ipv4
    test_assert_equal 0 "$RUN_STATUS" "idempotent prefer_ipv4"
    test_assert_equal "$first_state_hash" "$(sha256sum "$state" | awk '{print $1}')" "idempotent state hash"

    run_policy set --policy prefer_ipv6
    test_assert_equal 0 "$RUN_STATUS" "update prefer_ipv6"
    test_assert_file_contains "$(gai_path)" 'precedence ::ffff:0:0/96 35' "IPv6 preference precedence"
    test_assert_equal prefer_ipv6 "$(jq -r '.managed_policy' "$state")" "updated state policy"
    test_assert_equal "$backup" "$(jq -r '.backup_file' "$state")" "update retains original backup"
    backup_count="$(find "$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/network/ip-policy" -type f -name gai.conf | wc -l | tr -d ' ')"
    test_assert_equal 1 "$backup_count" "single original backup"

    run_policy status --json
    test_assert_equal 0 "$RUN_STATUS" "managed JSON status"
    jq -e '.policy == "prefer_ipv6" and .managed == true and .ownership == "verified" and .state_saved == true' \
        >/dev/null <<<"$RUN_OUTPUT" || test_fail "verified status JSON fields"
}

test_existing_configuration_confirmation() {
    local original_hash reply command
    reset_root
    printf 'precedence ::ffff:0:0/96 100\n' >"$(gai_path)"
    original_hash="$(sha256sum "$(gai_path)" | awk '{print $1}')"
    VPSCTL_ASSUME_YES=0 run_policy --non-interactive set --policy prefer_ipv6
    test_assert_equal 3 "$RUN_STATUS" "noninteractive adoption requires confirmation"
    test_assert_contains "$RUN_OUTPUT" '--yes' "noninteractive authorization guidance"
    test_assert_equal "$original_hash" "$(sha256sum "$(gai_path)" | awk '{print $1}')" "unauthorized file unchanged"
    [[ ! -e "$(state_path)" && ! -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/network/ip-policy" ]] ||
        test_fail "unauthorized adoption wrote state or backup"

    printf -v command 'env VPSCTL_ASSUME_YES=0 VPSCTL_NON_INTERACTIVE=0 bash %q set --policy prefer_ipv6' "$TEST_IP_POLICY"
    for reply in '' n y; do
        RUN_STATUS=0
        RUN_OUTPUT="$(printf '%s\n' "$reply" | script -q -e -c "$command" /dev/null 2>&1)" || RUN_STATUS=$?
        test_assert_equal 0 "$RUN_STATUS" "interactive adoption reply '$reply'"
        test_assert_contains "$RUN_OUTPUT" '先备份并完整替换 /etc/gai.conf' "adoption impact explained"
        test_assert_equal 1 "$(grep -c '输入 y 确认' <<<"$RUN_OUTPUT")" "single adoption confirmation"
        if [[ "$reply" != y ]]; then
            test_assert_equal "$original_hash" "$(sha256sum "$(gai_path)" | awk '{print $1}')" "cancelled adoption file unchanged"
            [[ ! -e "$(state_path)" && ! -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/network/ip-policy" ]] ||
                test_fail "cancelled adoption wrote state or backup"
        fi
    done
    test_assert_file_contains "$(gai_path)" 'precedence ::ffff:0:0/96 35' "interactive adoption applied"
    test_assert_equal "$original_hash" "$(jq -r '.backup_sha256' "$(state_path)")" "interactive adoption backup"
}

test_external_modification_and_invalid_state() {
    local state_hash changed_hash

    reset_root
    run_policy set --policy prefer_ipv4
    test_assert_equal 0 "$RUN_STATUS" "fixture managed set"
    state_hash="$(sha256sum "$(state_path)" | awk '{print $1}')"
    printf '# external edit\n' >>"$(gai_path)"
    changed_hash="$(sha256sum "$(gai_path)" | awk '{print $1}')"
    run_policy set --policy prefer_ipv6
    test_assert_equal 3 "$RUN_STATUS" "external modification blocks update"
    test_assert_equal "$state_hash" "$(sha256sum "$(state_path)" | awk '{print $1}')" "blocked update state unchanged"
    test_assert_equal "$changed_hash" "$(sha256sum "$(gai_path)" | awk '{print $1}')" "blocked update file unchanged"
    run_policy restore
    test_assert_equal 3 "$RUN_STATUS" "external modification blocks restore"
    test_assert_equal "$changed_hash" "$(sha256sum "$(gai_path)" | awk '{print $1}')" "blocked restore file unchanged"

    reset_root
    run_policy set --policy prefer_ipv4
    test_assert_equal 0 "$RUN_STATUS" "fixture for invalid state"
    changed_hash="$(sha256sum "$(gai_path)" | awk '{print $1}')"
    printf '{}\n' >"$(state_path)"
    run_policy --yes set --policy prefer_ipv6
    test_assert_equal 10 "$RUN_STATUS" "invalid state blocks authorized update"
    test_assert_equal "$changed_hash" "$(sha256sum "$(gai_path)" | awk '{print $1}')" "invalid state file unchanged"
    test_assert_equal '{}' "$(<"$(state_path)")" "invalid state not replaced"
}

test_exact_restore() {
    local original_hash backup
    reset_root
    printf '# original IPv4 preference\n\nprecedence ::ffff:0:0/96 100\nlabel ::1/128 0\n' >"$(gai_path)"
    chmod 0640 "$(gai_path)"
    original_hash="$(sha256sum "$(gai_path)" | awk '{print $1}')"
    VPSCTL_ASSUME_YES=0 run_policy --yes set --policy prefer_ipv6
    test_assert_equal 0 "$RUN_STATUS" "set before existing-file restore"
    test_assert_file_contains "$(gai_path)" 'precedence ::ffff:0:0/96 35' "adopt existing IPv4 preference as IPv6"
    backup="$(jq -r '.backup_file' "$(state_path)")"
    test_assert_equal "$original_hash" "$(sha256sum "${TEST_SYSTEM_ROOT}${backup}" | awk '{print $1}')" "active original backed up exactly"
    test_assert_equal "$original_hash" "$(jq -r '.backup_sha256' "$(state_path)")" "active original backup digest"
    test_assert_equal 640 "$(stat -c '%a' "${TEST_SYSTEM_ROOT}${backup}")" "active original backup mode"
    run_policy set --policy prefer_ipv4
    test_assert_equal 0 "$RUN_STATUS" "switch after adoption"
    test_assert_equal "$backup" "$(jq -r '.backup_file' "$(state_path)")" "switch retains first active backup"
    run_policy restore
    test_assert_equal 0 "$RUN_STATUS" "restore existing gai.conf"
    test_assert_equal "$original_hash" "$(sha256sum "$(gai_path)" | awk '{print $1}')" "restored exact content"
    test_assert_equal 640 "$(stat -c '%a' "$(gai_path)")" "restored exact mode"
    [[ ! -e "$(state_path)" ]] || test_fail "restore retained active state"

    reset_root
    run_policy set --policy prefer_ipv6
    test_assert_equal 0 "$RUN_STATUS" "set with absent original"
    [[ -f "$(gai_path)" ]] || test_fail "managed gai.conf missing"
    run_policy restore
    test_assert_equal 0 "$RUN_STATUS" "restore absent original"
    [[ ! -e "$(gai_path)" ]] || test_fail "restore should remove originally absent gai.conf"
    [[ ! -e "$(state_path)" ]] || test_fail "absent-original restore retained state"
}

test_adoption_failure_preserves_original() {
    local failure original_hash backup
    for failure in backup state; do
        reset_root
        printf '# administrator policy\nprecedence ::ffff:0:0/96 100\n' >"$(gai_path)"
        chmod 0640 "$(gai_path)"
        original_hash="$(sha256sum "$(gai_path)" | awk '{print $1}')"
        RUN_STATUS=0
        RUN_OUTPUT="$(
            # shellcheck source=../../commands/network/ip-policy.sh
            source "$TEST_IP_POLICY"
            if [[ "$failure" == backup ]]; then
                ip_policy_backup_original() { return 20; }
            else
                ip_policy_write_state() { return 20; }
            fi
            ip_policy_main --yes set --policy prefer_ipv6
        )" || RUN_STATUS=$?
        test_assert_equal 20 "$RUN_STATUS" "$failure failure status"
        test_assert_equal "$original_hash" "$(sha256sum "$(gai_path)" | awk '{print $1}')" "$failure failure preserves original content"
        test_assert_equal 640 "$(stat -c '%a' "$(gai_path)")" "$failure failure preserves original mode"
        [[ ! -e "$(state_path)" ]] || test_fail "$failure failure wrote state"
        if [[ "$failure" == state ]]; then
            backup="$(find "$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/network/ip-policy" -type f -name gai.conf)"
            test_assert_equal "$original_hash" "$(sha256sum "$backup" | awk '{print $1}')" "failed commit retained original backup"
        fi
    done
}

test_dry_run_and_symlink_refusal() {
    local before_hash
    reset_root
    printf '# dry-run original\nprecedence ::ffff:0:0/96 100\n' >"$(gai_path)"
    before_hash="$(sha256sum "$(gai_path)" | awk '{print $1}')"
    run_policy --dry-run set --policy prefer_ipv4
    test_assert_equal 0 "$RUN_STATUS" "set dry-run"
    test_assert_contains "$RUN_OUTPUT" '演练' "dry-run output"
    test_assert_contains "$RUN_OUTPUT" '先原样备份 /etc/gai.conf' "dry-run backup plan"
    test_assert_equal "$before_hash" "$(sha256sum "$(gai_path)" | awk '{print $1}')" "dry-run gai.conf unchanged"
    [[ ! -e "$(state_path)" ]] || test_fail "dry-run wrote state"
    [[ ! -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/network/ip-policy" ]] || test_fail "dry-run wrote backup directory"

    reset_root
    printf '# symlink target\n' >"$TEST_SYSTEM_ROOT/etc/real-gai.conf"
    ln -s real-gai.conf "$(gai_path)"
    run_policy set --policy prefer_ipv4
    test_assert_equal 3 "$RUN_STATUS" "gai.conf symlink refusal"
    test_assert_equal '# symlink target' "$(sed -n '1p' "$TEST_SYSTEM_ROOT/etc/real-gai.conf")" "symlink target unchanged"
    [[ ! -e "$(state_path)" ]] || test_fail "symlink refusal wrote state"
}

test_arguments_and_unmanaged_status
test_musl_platform_refusal
test_managed_tables_update_and_status
test_existing_configuration_confirmation
test_external_modification_and_invalid_state
test_exact_restore
test_adoption_failure_preserves_original
test_dry_run_and_symlink_refusal

printf 'PASS: network ip-policy tests\n'
