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

test_assert_no_ansi() {
    local value="$1"
    local message="$2"

    [[ "$value" != *$'\033['* ]] || test_fail "${message}: non-TTY output contains ANSI escapes"
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
    VPSCTL_INSTALL_DEPS=YES
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
    test_assert_equal "1" "$VPSCTL_INSTALL_DEPS" "normalized install-deps"
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
    if (VPSCTL_INSTALL_DEPS=maybe; vps_cmd_init "test-command" "$TEST_ROOT" >/dev/null 2>&1); then
        test_fail "invalid install-deps boolean was accepted"
    fi
}

test_dependency_installation() (
    local manager calls expected status output_file marker installed output
    local -a managers=(apt-get dnf5 dnf yum apk pacman zypper)
    local -A expected_calls=(
        [apt-get]=$'apt-get update\napt-get install -y --no-install-recommends curl jq\n'
        [dnf5]=$'dnf5 install -y curl jq\n'
        [dnf]=$'dnf install -y curl jq\n'
        [yum]=$'yum install -y curl jq\n'
        [apk]=$'apk add --no-cache curl jq\n'
        [pacman]=$'pacman -S --needed --noconfirm curl jq\n'
        [zypper]=$'zypper --non-interactive install --no-recommends curl jq\n'
    )

    VPSCTL_TESTING=1
    VPSCTL_DRY_RUN=0
    vps_cmd_require_root() { return 0; }
    vps_cmd_run() {
        local IFS=' '
        calls+="$*"$'\n'
    }
    for manager in "${managers[@]}"; do
        calls=""
        vps_cmd_install_packages "$manager" curl jq curl
        test_assert_equal "${expected_calls[$manager]}" "$calls" "$manager fixed install argv and deduplication"
    done

    calls=""
    status=0
    vps_cmd_install_packages apt-get 'safe;touch-bad' >/dev/null 2>&1 || status=$?
    test_assert_equal 2 "$status" "unsafe package status"
    test_assert_equal "" "$calls" "unsafe package must not execute"
    status=0
    VPSCTL_ENV_PACKAGE_MANAGER='apt-get;id'
    vps_cmd_detect_package_manager >/dev/null 2>&1 || status=$?
    test_assert_equal 2 "$status" "invalid exported package manager status"

    test_assert_equal dnsutils "$(vps_cmd_package_for_tool apt-get dns-query)" "apt DNS package"
    test_assert_equal bind-utils "$(vps_cmd_package_for_tool dnf dns-query)" "dnf DNS package"
    test_assert_equal bind-tools "$(vps_cmd_package_for_tool apk dns-query)" "apk DNS package"
    test_assert_equal bind "$(vps_cmd_package_for_tool pacman dns-query)" "pacman DNS package"
    test_assert_equal iproute "$(vps_cmd_package_for_tool dnf5 tc)" "dnf5 iproute package"
    test_assert_equal util-linux "$(vps_cmd_package_for_tool apt-get flock)" "apt flock package"
    test_assert_equal flock "$(vps_cmd_package_for_tool apk flock)" "Alpine flock package"
    test_assert_equal util-linux-misc "$(vps_cmd_package_for_tool apk mountpoint)" "Alpine mountpoint package"
    test_assert_equal chrony "$(vps_cmd_package_for_tool apt-get chronyc)" "chronyc package"
    test_assert_equal gnupg "$(vps_cmd_package_for_tool apt-get gpg)" "GnuPG package"
    test_assert_equal coreutils "$(vps_cmd_package_for_tool apt-get install)" "install package"

    VPSCTL_ASSUME_YES=1
    status=0
    _vps_cmd_confirm_dependency_install <<<n >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" "dependency confirmation must ignore --yes"
    _vps_cmd_confirm_dependency_install <<<y >/dev/null 2>&1 || test_fail "dependency confirmation rejected y"
    VPSCTL_ASSUME_YES=0

    # Restore helper definitions after the argv-capture stubs above.
    source "${TEST_ROOT}/lib/command.sh"
    VPSCTL_DRY_RUN=1
    VPSCTL_INSTALL_DEPS=1
    VPSCTL_ENV_PACKAGE_MANAGER=apt-get
    VPS_CMD_DEPENDENCIES_PLANNED=0
    marker="${TEST_TEMP}/dependency-manager-ran"
    output_file="${TEST_TEMP}/dependency-dry-run-output"
    _vps_cmd_tool_available() { return 1; }
    vps_cmd_detect_package_manager() { printf 'apt-get\n'; }
    apt-get() { touch "$marker"; }
    vps_cmd_ensure_tools test-feature curl jq >"$output_file" 2>&1
    test_assert_equal 1 "$VPS_CMD_DEPENDENCIES_PLANNED" "dry-run dependency plan flag"
    [[ ! -e "$marker" ]] || test_fail "dry-run dependency plan executed the package manager"
    calls="$(<"$output_file")"
    [[ "$calls" == *'apt-get update'* && "$calls" == *'apt-get install -y --no-install-recommends curl jq'* ]] || test_fail "dry-run dependency argv"

    VPSCTL_INSTALL_DEPS=0
    status=0
    vps_cmd_ensure_tools test-feature curl >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" "dependency installation authorization status"

    # Available tools require no package mapping or installation work.
    _vps_cmd_tool_available() { return 0; }
    vps_cmd_detect_package_manager() {
        test_fail "package manager was detected for an available tool"
    }
    vps_cmd_ensure_tools test-feature custom-available-tool || test_fail "available custom tool was rejected"

    # A real interactive invocation can authorize this one installation without
    # mutating the exported authorization used by later dependency checks.
    _vps_cmd_tool_available() { [[ "$installed" == "1" ]]; }
    vps_cmd_detect_package_manager() { printf 'apt-get\n'; }
    vps_cmd_is_interactive() { return 0; }
    vps_cmd_install_packages() {
        local IFS=' '
        calls="$*"
        installed=1
    }
    _vps_cmd_confirm_dependency_install() { return 0; }
    VPSCTL_DRY_RUN=0
    VPSCTL_INSTALL_DEPS=0
    calls=""
    installed=0
    output_file="${TEST_TEMP}/dependency-interactive-output"
    vps_cmd_ensure_tools test-feature curl >"$output_file" 2>&1
    output="$(<"$output_file")"
    [[ "$output" == *'缺少工具：curl'* && "$output" == *'需要安装软件包：curl'* ]] || test_fail "interactive dependency summary"
    test_assert_equal "apt-get curl" "$calls" "interactive dependency install"
    test_assert_equal 0 "$VPSCTL_INSTALL_DEPS" "interactive authorization must not leak"

    _vps_cmd_confirm_dependency_install() { return 3; }
    calls=""
    installed=0
    status=0
    vps_cmd_ensure_tools test-feature curl >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" "declined dependency status"
    test_assert_equal "" "$calls" "declined dependency must not install"
    test_assert_equal 0 "$VPSCTL_INSTALL_DEPS" "declined authorization must not leak"

    VPSCTL_DRY_RUN=1
    _vps_cmd_confirm_dependency_install() { test_fail "dry-run dependency check prompted"; }
    status=0
    output_file="${TEST_TEMP}/dependency-unauthorized-dry-run-output"
    vps_cmd_ensure_tools test-feature curl >"$output_file" 2>&1 || status=$?
    test_assert_equal 3 "$status" "unauthorized dry-run dependency status"
    output="$(<"$output_file")"
    [[ "$output" == *'--install-deps'* ]] || test_fail "unauthorized dry-run dependency hint"
    test_assert_equal "" "$calls" "unauthorized dry-run must not install"

    VPSCTL_DRY_RUN=0
    VPSCTL_ASSUME_YES=1
    _vps_cmd_confirm_dependency_install() { return 3; }
    status=0
    vps_cmd_ensure_tools test-feature curl >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" "--yes must not authorize dependency installation"
    test_assert_equal "" "$calls" "--yes must not install dependencies"
)

test_prompt_helpers() {
    local selected value status output_file

    output_file="${TEST_TEMP}/prompt-select-output"
    selected="$(vps_cmd_prompt_select "选择模式" quick quick "快速" custom "自定义" 2>"$output_file" <<<"")"
    test_assert_equal quick "$selected" "selection default"
    [[ "$(<"$output_file")" == *'快速（默认）'* ]] || test_fail "selection default marker"

    selected="$(vps_cmd_prompt_select "选择模式" quick quick "快速" custom "自定义" 2>"$output_file" <<< $'99\n2')"
    test_assert_equal custom "$selected" "selection retry"
    [[ "$(<"$output_file")" == *'选择无效'* ]] || test_fail "selection retry warning"

    status=0
    vps_cmd_prompt_select "选择模式" quick quick "快速" custom "自定义" <<<q >/dev/null 2>&1 || status=$?
    test_assert_equal 130 "$status" "selection quit status"
    status=0
    vps_cmd_prompt_select "选择模式" quick quick "快速" custom "自定义" </dev/null >/dev/null 2>&1 || status=$?
    test_assert_equal 130 "$status" "selection EOF status"

    value="$(vps_cmd_prompt_value "监听端口" 443 2>"$output_file" <<<"")"
    test_assert_equal 443 "$value" "open input default"
    value="$(vps_cmd_prompt_value "监听端口" 443 2>"$output_file" <<<"8443")"
    test_assert_equal 8443 "$value" "open input value"
    status=0
    vps_cmd_prompt_value "监听端口" 443 </dev/null >/dev/null 2>&1 || status=$?
    test_assert_equal 130 "$status" "open input EOF status"

    selected="$(vps_cmd_prompt_select "分组" "" \
        __section__ "一组" a "甲" __section__ "二组" b "乙" 2>"$output_file" <<<2)"
    test_assert_equal b "$selected" "section headers are not numbered"
    [[ "$(<"$output_file")" == *'一组'* && "$(<"$output_file")" == *'二组'* ]] || test_fail "section headers are visible"
}

test_standard_system_paths() (
    local original_path="$PATH"

    [[ -d /usr/sbin ]] || return 0
    VPSCTL_TESTING=0
    VPSCTL_SYSTEM_ROOT=""
    PATH=/usr/bin:/bin
    vps_cmd_init "path-test" "$TEST_ROOT"
    case ":$PATH:" in
        *:/usr/sbin:*) ;;
        *) test_fail "production initialization did not add /usr/sbin" ;;
    esac
    _vps_cmd_add_standard_system_paths
    [[ "$(awk -F: '{count=0; for (i=1; i<=NF; i++) if ($i=="/usr/sbin") count++; print count}' <<<"$PATH")" == "1" ]] || \
        test_fail "standard system path was added more than once"
    PATH="$original_path"
)

test_logging_and_run() {
    local output
    local marker="${TEST_TEMP}/ran"

    VPSCTL_NO_COLOR=0
    NO_COLOR=""
    TERM=xterm-256color
    output="$(vps_cmd_info hello world 2>&1)"
    [[ "$output" == *'[信息] test-command: hello world'* ]] || test_fail "info log format"
    test_assert_no_ansi "$output" "redirected info log"
    output="$(vps_cmd_verbose details 2>&1)"
    [[ "$output" == *'[详细] test-command: details'* ]] || test_fail "verbose log format"
    output="$(vps_cmd_warning caution 2>&1)"
    [[ "$output" == *'[警告] test-command: caution'* ]] || test_fail "warning log format"
    output="$(vps_cmd_error failure 2>&1)"
    [[ "$output" == *'[错误] test-command: failure'* ]] || test_fail "error log format"
    output="$(vps_cmd_success complete 2>&1)"
    [[ "$output" == *'[成功] test-command: complete'* ]] || test_fail "success log format"
    test_assert_no_ansi "$output" "redirected success log"
    if command -v script >/dev/null 2>&1; then
        output="$(
            env -u TERM script -qec \
                "bash -c 'source \"${TEST_ROOT}/lib/command.sh\"; VPSCTL_NO_COLOR=0; NO_COLOR=; vps_cmd_status 状态 就绪 success'" \
                /dev/null
        )"
        test_assert_no_ansi "$output" "TTY output without TERM"
    fi
    output="$(vps_cmd_status 状态 就绪 success)"
    test_assert_equal "  $(vps_ui_pad "状态" "$VPS_UI_KV_WIDTH")：就绪" "$output" "status output"
    test_assert_no_ansi "$output" "redirected status output"
    output="$(
        _vps_cmd_color_enabled() {
            return 0
        }
        vps_cmd_success complete 2>&1
    )"
    [[ "$output" == *$'\033[32m[成功]\033[0m test-command: complete'* ]] || test_fail "success color"
    output="$(
        _vps_cmd_color_enabled() {
            return 0
        }
        vps_cmd_status 状态 注意 warning
    )"
    test_assert_equal "  "$'\033[36m'"$(vps_ui_pad "状态" "$VPS_UI_KV_WIDTH")"$'\033[0m：\033[33m注意\033[0m' "$output" "status colors"
    output="$(
        _vps_cmd_color_enabled() {
            return 0
        }
        vps_cmd_status 重点 BBR emphasis
    )"
    test_assert_equal "  "$'\033[36m'"$(vps_ui_pad "重点" "$VPS_UI_KV_WIDTH")"$'\033[0m：\033[1;35mBBR\033[0m' "$output" "emphasis color"
    if vps_cmd_status 状态 未知 invalid >/dev/null 2>&1; then
        test_fail "invalid status style was accepted"
    fi
    VPSCTL_QUIET=1
    test_assert_equal "" "$(vps_cmd_info hidden 2>&1)" "quiet info"
    test_assert_equal "" "$(vps_cmd_success hidden 2>&1)" "quiet success"
    VPSCTL_QUIET=0

    VPSCTL_DRY_RUN=1
    output="$(vps_cmd_run touch "$marker" 'argument with spaces' 2>&1)"
    [[ "$output" == *'[演练] touch '* && "$output" == *'argument\ with\ spaces'* ]] || test_fail "dry-run escaping"
    test_assert_no_ansi "$output" "redirected dry-run output"
    [[ ! -e "$marker" ]] || test_fail "dry-run executed its command"
    VPSCTL_DRY_RUN=0
    vps_cmd_run touch "$marker"
    [[ -f "$marker" ]] || test_fail "normal command did not execute"
}

test_confirmation_guards() {
    VPSCTL_NON_INTERACTIVE=1
    VPSCTL_ASSUME_YES=1
    vps_cmd_confirm "安全确认" || test_fail "--yes did not skip ordinary confirmation"
    if vps_cmd_confirm_token "危险确认" ERASE 2>/dev/null; then
        test_fail "--yes skipped token confirmation"
    fi
    VPSCTL_ASSUME_YES=0
    if vps_cmd_confirm "非交互确认" 2>/dev/null; then
        test_fail "non-interactive confirmation was accepted"
    fi
    VPSCTL_TESTING=0
    VPSCTL_DRY_RUN=1
    vps_cmd_require_root || test_fail "dry-run should not require root"
    vps_cmd_confirm "演练确认" || test_fail "dry-run required ordinary confirmation"
    vps_cmd_confirm_token "演练确认" ERASE || test_fail "dry-run required token confirmation"
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
test_dependency_installation
test_prompt_helpers
test_standard_system_paths
test_logging_and_run
test_confirmation_guards
test_lock_backup_and_atomic_write
test_internal_symlink_component_guard
printf 'PASS: command library tests\n'
