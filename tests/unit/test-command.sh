#!/usr/bin/env bash
# Tests intentionally exercise public globals from the sourced command library.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
readonly TEST_ROOT TEST_TEMP
trap 'rm -rf -- "$TEST_TEMP"' EXIT

# shellcheck source=/dev/null
source "${TEST_ROOT}/lib/command.sh"

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

test_assert_file_mode() {
    local expected="$1"
    local path="$2"
    local actual

    case "$(uname -s)" in
        MINGW* | MSYS*) return 0 ;;
    esac
    actual="$(stat -c '%a' "$path")"
    test_assert_equal "$expected" "$actual" "mode for $path"
}

test_init_and_paths() {
    local escaped_root_link="${TEST_TEMP}/escaped-root"
    VPSCTL_DRY_RUN=yes
    VPSCTL_ASSUME_YES=off
    VPSCTL_NON_INTERACTIVE=false
    VPSCTL_QUIET=0
    VPSCTL_VERBOSE=true
    VPSCTL_NO_COLOR=1
    VPSCTL_TESTING=1
    VPSCTL_SYSTEM_ROOT="${TEST_TEMP}/system"
    mkdir -p -- "$VPSCTL_SYSTEM_ROOT"

    vps_cmd_init " test-command " "$TEST_ROOT"
    test_assert_equal "test-command" "$VPSCTL_COMMAND_NAME" "trimmed command name"
    test_assert_equal "1" "$VPSCTL_DRY_RUN" "normalized dry-run"
    test_assert_equal "0" "$VPSCTL_ASSUME_YES" "normalized assume-yes"
    test_assert_equal "1" "$VPSCTL_VERBOSE" "normalized verbose"
    test_assert_equal "${TEST_TEMP}/system/etc/example.conf" "$(vps_cmd_system_path /etc/example.conf)" "test system path"
    VPSCTL_TESTING=0
    test_assert_equal "/etc/example.conf" "$(vps_cmd_system_path /etc/example.conf)" "production system path"
    VPSCTL_TESTING=1
    if vps_cmd_system_path ../etc/passwd >/dev/null 2>&1; then
        test_fail "relative system path was accepted"
    fi
    if vps_cmd_system_path /etc/../passwd >/dev/null 2>&1; then
        test_fail "parent traversal system path was accepted"
    fi
    if ln -s / "$escaped_root_link" 2>/dev/null && [[ -L "$escaped_root_link" ]]; then
        VPSCTL_SYSTEM_ROOT="$escaped_root_link"
        if vps_cmd_init "test-command" "$TEST_ROOT" >/dev/null 2>&1; then
            test_fail "a test-root symlink resolving to / was accepted"
        fi
        VPSCTL_SYSTEM_ROOT="${TEST_TEMP}/system"
        vps_cmd_init "test-command" "$TEST_ROOT"
    fi
    if ln -s "${TEST_TEMP}/system" "${TEST_TEMP}/linked-system" 2>/dev/null && [[ -L "${TEST_TEMP}/linked-system" ]]; then
        VPSCTL_SYSTEM_ROOT="${TEST_TEMP}/linked-system"
        if vps_cmd_init "test-command" "$TEST_ROOT" >/dev/null 2>&1; then
            test_fail "a test root containing a symbolic-link component was accepted"
        fi
        VPSCTL_SYSTEM_ROOT="${TEST_TEMP}/system"
        vps_cmd_init "test-command" "$TEST_ROOT"
    fi
    vps_cmd_require_root || test_fail "testing mode should authorize root requirement"
    test_assert_equal "trim me" "$(vps_cmd_trim $' \ttrim me \n')" "trim"
    test_assert_equal "on" "$(vps_cmd_parse_on_off YES)" "on parser"
    test_assert_equal "off" "$(vps_cmd_parse_on_off 0)" "off parser"
    if vps_cmd_parse_on_off maybe >/dev/null; then
        test_fail "invalid on/off value was accepted"
    fi
}

test_logging_and_run() {
    local output
    local marker="${TEST_TEMP}/ran"

    output="$(vps_cmd_info hello world 2>&1)"
    [[ "$output" == *'[INFO] test-command: hello world'* ]] || test_fail "info log format"
    output="$(vps_cmd_verbose details 2>&1)"
    [[ "$output" == *'[DEBUG] test-command: details'* ]] || test_fail "verbose log format"
    output="$(vps_cmd_warning caution 2>&1)"
    [[ "$output" == *'[WARN] test-command: caution'* ]] || test_fail "warning log format"
    output="$(vps_cmd_error failure 2>&1)"
    [[ "$output" == *'[ERROR] test-command: failure'* ]] || test_fail "error log format"
    VPSCTL_QUIET=1
    test_assert_equal "" "$(vps_cmd_info hidden 2>&1)" "quiet info"
    VPSCTL_QUIET=0

    VPSCTL_DRY_RUN=1
    output="$(vps_cmd_run touch "$marker" 'argument with spaces' 2>&1)"
    [[ "$output" == *'touch '* && "$output" == *'argument\ with\ spaces'* ]] || test_fail "dry-run escaping"
    [[ ! -e "$marker" ]] || test_fail "dry-run executed its command"
    VPSCTL_DRY_RUN=0
    vps_cmd_run touch "$marker"
    [[ -f "$marker" ]] || test_fail "normal command did not execute"
}

test_confirmation_guards() {
    VPSCTL_NON_INTERACTIVE=1
    VPSCTL_ASSUME_YES=1
    vps_cmd_confirm "safe confirmation" || test_fail "--yes did not skip ordinary confirmation"
    if vps_cmd_confirm_token "dangerous confirmation" ERASE 2>/dev/null; then
        test_fail "--yes skipped token confirmation"
    fi
    VPSCTL_ASSUME_YES=0
    if vps_cmd_confirm "non-interactive confirmation" 2>/dev/null; then
        test_fail "non-interactive confirmation was accepted"
    fi
    VPSCTL_TESTING=0
    VPSCTL_DRY_RUN=1
    vps_cmd_require_root || test_fail "dry-run should not require root"
    vps_cmd_confirm "dry-run confirmation" || test_fail "dry-run required ordinary confirmation"
    vps_cmd_confirm_token "dry-run confirmation" ERASE || test_fail "dry-run required token confirmation"
    VPSCTL_TESTING=1
    VPSCTL_DRY_RUN=0
    VPSCTL_NON_INTERACTIVE=0
    if vps_cmd_is_interactive; then
        test_fail "unit test pipe unexpectedly reported an interactive terminal"
    fi
}

test_lock_backup_and_atomic_write() {
    local source_path
    local backup_path
    local backup_path_second
    local backup_path_third

    VPSCTL_DRY_RUN=1
    vps_cmd_lock dry-run-lock 2>/dev/null || test_fail "dry-run lock should be a no-op"
    [[ ! -e "${TEST_TEMP}/system/run/vpsctl/dry-run-lock.lock" ]] || test_fail "dry-run created a lock file"
    VPSCTL_DRY_RUN=0
    local target_path

    if ! command -v flock >/dev/null 2>&1; then
        flock() {
            return 0
        }
    fi
    vps_cmd_lock network
    [[ -f "${TEST_TEMP}/system/run/vpsctl/network.lock" ]] || test_fail "lock file was not created under the test root"
    vps_cmd_unlock
    test_assert_equal "" "${VPS_CMD_LOCK_FD:-}" "lock descriptor after unlock"

    source_path="$(vps_cmd_system_path /etc/network.conf)"
    mkdir -p -- "${source_path%/*}"
    printf 'original\n' >"$source_path"
    chmod 0640 "$source_path"
    backup_path="$(vps_cmd_backup_file network /etc/network.conf)"
    [[ "$backup_path" == "${TEST_TEMP}/system/var/lib/vpsctl/backups/network/network/"*'/network.conf' ]] || test_fail "unexpected backup path: $backup_path"
    test_assert_equal "original" "$(<"$backup_path")" "backup contents"
    test_assert_file_mode 640 "$backup_path"
    backup_path_second="$(vps_cmd_backup_file network /etc/network.conf)"
    backup_path_third="$(vps_cmd_backup_file network /etc/network.conf)"
    [[ "$backup_path_second" != "$backup_path" ]] || test_fail "backup paths must be unique"
    [[ "$backup_path_third" != "$backup_path" && "$backup_path_third" != "$backup_path_second" ]] || test_fail "third backup path must be unique"

    target_path="$(vps_cmd_system_path /etc/atomic.conf)"
    printf 'first value\n' | vps_cmd_atomic_write /etc/atomic.conf 0644
    test_assert_equal "first value" "$(<"$target_path")" "atomic write contents"
    test_assert_file_mode 644 "$target_path"
    [[ -z "$(find "${target_path%/*}" -maxdepth 1 -name '.atomic.conf.tmp.*' -print -quit)" ]] || test_fail "atomic temporary file was left behind"
    if printf 'bad\n' | vps_cmd_atomic_write /etc/atomic.conf invalid 2>/dev/null; then
        test_fail "invalid atomic write mode was accepted"
    fi
    test_assert_equal "first value" "$(<"$target_path")" "target after rejected atomic write"
}

test_internal_symlink_component_guard() {
    local etc_path="${TEST_TEMP}/system/etc"
    local saved_path="${TEST_TEMP}/system/etc.saved"
    local outside_path="${TEST_TEMP}/outside-etc"
    local status=0

    mv -- "$etc_path" "$saved_path"
    mkdir -p -- "$outside_path"
    if ln -s "$outside_path" "$etc_path" 2>/dev/null && [[ -L "$etc_path" ]]; then
        printf 'escape\n' | vps_cmd_atomic_write /etc/escaped.conf 0644 >/dev/null 2>&1 || status=$?
        test_assert_equal 3 "$status" "internal symbolic-link component rejection"
        [[ ! -e "${outside_path}/escaped.conf" ]] || test_fail "atomic write escaped through an internal symbolic-link component"
        unlink -- "$etc_path" 2>/dev/null || rmdir -- "$etc_path"
    elif [[ -e "$etc_path" || -L "$etc_path" ]]; then
        unlink -- "$etc_path" 2>/dev/null || rmdir -- "$etc_path"
    fi
    mv -- "$saved_path" "$etc_path"
}

test_init_and_paths
test_logging_and_run
test_confirmation_guards
test_lock_backup_and_atomic_write
test_internal_symlink_component_guard
printf 'PASS: command library tests\n'
