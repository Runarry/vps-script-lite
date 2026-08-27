#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

# shellcheck source=/dev/null
source "${TEST_ROOT}/lib/environment.sh"
# shellcheck source=/dev/null
source "${TEST_ROOT}/lib/registry.sh"
# shellcheck source=/dev/null
source "${TEST_ROOT}/lib/ui.sh"

test_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

test_assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$expected" == "$actual" ]] || test_fail "${message}: expected '${expected}', got '${actual}'"
}

test_assert_nonempty() {
    local value="$1"
    local message="$2"
    [[ -n "$value" ]] || test_fail "${message}: value is empty"
}

test_environment_detection() {
    vps_env_detect

    test_assert_nonempty "${VPS_ENV[kernel_name]}" "kernel name"
    test_assert_nonempty "${VPS_ENV[architecture]}" "architecture"
    test_assert_nonempty "${VPS_ENV[os_pretty_name]}" "OS display name"
    test_assert_nonempty "${VPS_ENV[memory_total]}" "memory total"
    test_assert_nonempty "${VPS_ENV[root_disk_total]}" "root disk total"
    test_assert_nonempty "${VPS_ENV[compatibility]}" "compatibility"
    test_assert_nonempty "${VPS_ENV[bbr_status]}" "BBR status"
    test_assert_nonempty "${VPS_ENV[bbr_version]}" "BBR version"
    test_assert_nonempty "${VPS_ENV[congestion_control]}" "congestion-control algorithm"
    [[ "${VPS_ENV[memory_total]}" != "unknown" ]] || test_fail "memory detection returned unknown"
    [[ "${VPS_ENV[root_disk_total]}" != "unknown" ]] || test_fail "root disk detection returned unknown"

    test_assert_equal "1.0 GiB" "$(vps_env_format_kib 1048576)" "KiB formatter"
    test_assert_equal "1d 1h 1m" "$(vps_env_format_uptime 90060)" "uptime formatter"
    test_assert_equal "BBRv2" "$(vps_env_classify_bbr_version bbr2 '')" "BBRv2 classifier"
    test_assert_equal "BBRv3" "$(vps_env_classify_bbr_version bbr3 '')" "BBRv3 classifier"
    test_assert_equal "kernel implementation (version not exposed)" "$(vps_env_classify_bbr_version bbr '')" "unversioned BBR classifier"
    test_assert_equal "module 3.1" "$(vps_env_classify_bbr_version bbr 3.1)" "module version classifier"
    vps_env_requirements_met "bash:4.4" || test_fail "current Bash capability should be available"
    if vps_env_requirements_met "capability:that-does-not-exist"; then
        test_fail "unknown capability should not be accepted"
    fi

    ip() {
        local argument
        for argument in "$@"; do
            if [[ "$argument" == "-4" ]]; then
                printf '2: eth0 inet 192.0.2.10/24 scope global eth0\n'
                return 0
            fi
        done
        return 0
    }
    vps_env_detect_addresses
    test_assert_equal "192.0.2.10" "${VPS_ENV[ipv4]}" "IPv4-only detection"
    test_assert_equal "unavailable" "${VPS_ENV[ipv6]}" "missing IPv6 detection"
    unset -f ip
}

test_registry() {
    vps_registry_init

    test_assert_equal "7" "${#VPS_DOMAIN_IDS[@]}" "domain count"
    test_assert_equal "0" "${#VPS_COMMAND_KEYS[@]}" "initial command count"

    vps_registry_register_command \
        "system" \
        "inspect" \
        "Inspect" \
        "Read local system information" \
        "commands/system/inspect.sh" \
        "read-only" \
        "user" \
        "not-applicable" \
        "linux" \
        "experimental"

    vps_registry_has_command "system:inspect" || test_fail "registered command is not discoverable"
    test_assert_equal "commands/system/inspect.sh" "${VPS_COMMAND_PATH[system:inspect]}" "registered path"

    if vps_registry_register_command \
        "system" "unsafe" "Unsafe" "Unsafe path test" \
        "../unsafe.sh" "read-only" "user" "not-applicable" "none" "experimental" 2>/dev/null; then
        test_fail "unsafe command path should be rejected"
    fi
}

test_ui_input() {
    vps_ui_parse_index "1" "7" || test_fail "valid menu index should be accepted"
    test_assert_equal "0" "$VPS_UI_INDEX" "parsed menu index"

    if vps_ui_parse_index "08" "10"; then
        test_fail "leading-zero menu input should be rejected safely"
    fi
    if vps_ui_parse_index "999999999999999999999" "10"; then
        test_fail "oversized menu input should be rejected safely"
    fi
    if vps_ui_parse_index "8" "7"; then
        test_fail "out-of-range menu input should be rejected"
    fi
}

test_environment_detection
test_registry
test_ui_input
printf 'PASS: library tests\n'
