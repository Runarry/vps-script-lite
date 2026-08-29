#!/usr/bin/env bash
# Test resets intentionally assign public globals from sourced libraries, and
# command mocks are invoked indirectly by environment detection.
# shellcheck disable=SC2034,SC2329

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT

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

test_assert_contains() {
    local value="$1"
    local expected="$2"
    local message="$3"
    [[ "$value" == *"$expected"* ]] || test_fail "${message}: missing '${expected}'"
}

test_assert_no_ansi() {
    local value="$1"
    local message="$2"
    [[ "$value" != *$'\033['* ]] || test_fail "${message}: unexpected ANSI escape"
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
    test_assert_equal "1 天 1 小时 1 分钟" "$(vps_env_format_uptime 90060)" "uptime formatter"
    test_assert_equal "BBRv2" "$(vps_env_classify_bbr_version bbr2 '')" "BBRv2 classifier"
    test_assert_equal "BBRv3" "$(vps_env_classify_bbr_version bbr3 '')" "BBRv3 classifier"
    test_assert_equal "内核实现（未公开版本）" "$(vps_env_classify_bbr_version bbr '')" "unversioned BBR classifier"
    test_assert_equal "模块 3.1" "$(vps_env_classify_bbr_version bbr 3.1)" "module version classifier"
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

test_environment_chinese_fallbacks() {
    vps_env_read_os_release() {
        return 0
    }
    vps_env_detect
    test_assert_equal "未知 Linux 系统" "${VPS_ENV[os_pretty_name]}" "localized OS fallback"
}

test_registry() {
    vps_registry_init

    test_assert_equal "2" "${#VPS_DOMAIN_IDS[@]}" "registered domain count"
    test_assert_equal "5" "${#VPS_COMMAND_KEYS[@]}" "registered command count"
    test_assert_equal "network" "${VPS_DOMAIN_IDS[0]}" "network domain id"
    test_assert_equal "service" "${VPS_DOMAIN_IDS[1]}" "service domain id"
    test_assert_equal "commands/network/bbr.sh" "${VPS_COMMAND_PATH["network:bbr"]}" "BBR command path"
    test_assert_equal "commands/network/dns.sh" "${VPS_COMMAND_PATH["network:dns"]}" "DNS command path"
    test_assert_equal "commands/network/ip-policy.sh" "${VPS_COMMAND_PATH["network:ip-policy"]}" "IP policy command path"
    test_assert_equal "commands/network/rfw.sh" "${VPS_COMMAND_PATH["network:rfw"]}" "RFW command path"
    test_assert_equal "change" "${VPS_COMMAND_RISK["network:bbr"]}" "BBR risk"
    test_assert_equal "disruptive" "${VPS_COMMAND_RISK["network:dns"]}" "DNS risk"
    test_assert_equal "disruptive" "${VPS_COMMAND_RISK["network:ip-policy"]}" "IP policy risk"
    test_assert_equal "disruptive" "${VPS_COMMAND_RISK["network:rfw"]}" "RFW risk"
    test_assert_equal "optional-root" "${VPS_COMMAND_PRIVILEGE["network:bbr"]}" "BBR privilege"
    test_assert_equal "supported" "${VPS_COMMAND_DRY_RUN["network:dns"]}" "DNS dry-run"
    test_assert_equal "linux,init:systemd" "${VPS_COMMAND_REQUIREMENTS["network:rfw"]}" "RFW requirements"
    test_assert_equal "experimental" "${VPS_COMMAND_LIFECYCLE["network:rfw"]}" "RFW lifecycle"
    test_assert_equal "commands/service/proxy.sh" "${VPS_COMMAND_PATH["service:proxy"]}" "proxy command path"
    test_assert_equal "disruptive" "${VPS_COMMAND_RISK["service:proxy"]}" "proxy risk"
    test_assert_equal "optional-root" "${VPS_COMMAND_PRIVILEGE["service:proxy"]}" "proxy privilege"
    test_assert_equal "linux,service:any" "${VPS_COMMAND_REQUIREMENTS["service:proxy"]}" "proxy requirements"

    vps_registry_register_domain \
        "test" \
        "Test" \
        "Test-only domain"

    vps_registry_register_command \
        "test" \
        "inspect" \
        "Inspect" \
        "Read local system information" \
        "commands/test/inspect.sh" \
        "read-only" \
        "user" \
        "not-applicable" \
        "linux" \
        "experimental"

    vps_registry_has_command "test:inspect" || test_fail "registered command is not discoverable"
    test_assert_equal "commands/test/inspect.sh" "${VPS_COMMAND_PATH["test:inspect"]}" "registered path"

    if vps_registry_register_command \
        "test" "unsafe" "Unsafe" "Unsafe path test" \
        "../unsafe.sh" "read-only" "user" "not-applicable" "none" "experimental" 2>/dev/null; then
        test_fail "unsafe command path should be rejected"
    fi
}

test_ui_input() {
    local output

    vps_registry_init
    output="$(vps_ui_main_menu)"
    [[ "$output" == *"网络设置"* ]] || test_fail "registered network domain should be visible"
    [[ "$output" == *"(4 个功能)"* ]] || test_fail "network domain command count should be visible"
    [[ "$output" == *"服务管理"* ]] || test_fail "registered service domain should be visible"
    [[ "$output" == *"(1 个功能)"* ]] || test_fail "service domain command count should be visible"

    VPS_UI_GREEN="<绿>"
    VPS_UI_YELLOW="<黄>"
    VPS_UI_RED="<红>"
    VPS_UI_CYAN="<青>"
    VPS_UI_MAGENTA="<品红>"
    VPS_UI_RESET="<重置>"
    VPS_UI_INITIALIZED=1
    test_assert_equal "4" "$(vps_ui_display_width "系统")" "CJK display width"
    test_assert_equal "3" "$(vps_ui_display_width "BBR")" "ASCII display width"
    test_assert_equal "系统  " "$(vps_ui_pad "系统" 6)" "CJK pad"
    test_assert_equal "<绿>可用<重置>" "$(vps_ui_availability_label ready)" "ready label translation"
    test_assert_equal "<黄>受限<重置>" "$(vps_ui_availability_label limited)" "limited label translation"
    test_assert_equal "<黄>变更<重置>" "$(vps_ui_risk_label change)" "change risk translation"
    test_assert_equal "<红>中断性<重置>" "$(vps_ui_risk_label disruptive)" "disruptive risk translation"
    test_assert_equal "<黄>按需 root<重置>" "$(vps_ui_privilege_label optional-root)" "optional-root translation"
    test_assert_equal "<绿>支持<重置>" "$(vps_ui_dry_run_label supported)" "dry-run translation"
    test_assert_equal "<黄>实验性<重置>" "$(vps_ui_lifecycle_label experimental)" "lifecycle translation"
    test_assert_equal "<黄>未知<重置>" "$(vps_ui_value_label unknown)" "unknown value translation"
    test_assert_equal "<绿>已启用<重置>" "$(vps_ui_value_label enabled)" "enabled value translation"
    test_assert_equal "<青>物理机<重置>" "$(vps_ui_value_label bare-metal)" "virtualization translation"
    test_assert_equal "<青>WSL<重置>" "$(vps_ui_value_label wsl)" "WSL translation"
    test_assert_equal "<绿>0 成功<重置>" "$(vps_ui_exit_code 0)" "successful exit-code color"
    test_assert_equal "<黄>30 部分完成<重置>" "$(vps_ui_exit_code 30)" "partial exit-code color"
    test_assert_equal "<红>20 失败<重置>" "$(vps_ui_exit_code 20)" "failed exit-code color"

    VPS_ENV[compatibility]="supported"
    test_assert_equal "<绿>支持<重置>" "$(vps_ui_status_badge)" "supported badge translation"
    VPS_ENV[compatibility]="limited"
    test_assert_equal "<黄>受限<重置>" "$(vps_ui_status_badge)" "limited badge translation"
    VPS_ENV[compatibility]="unsupported"
    test_assert_equal "<红>不支持<重置>" "$(vps_ui_status_badge)" "unsupported badge translation"

    VPS_CAPABILITY=()
    VPS_CAPABILITY[linux]=1
    output="$(vps_ui_registered_commands)"
    test_assert_contains "$output" "network bbr" "registered command listing"
    test_assert_contains "$output" "<绿>可用<重置>" "ready command listing marker"
    test_assert_contains "$output" "network rfw" "limited command listing"
    test_assert_contains "$output" "<黄>受限<重置>" "limited command listing marker"

    output="$(vps_ui_command_details "network:bbr")"
    test_assert_contains "$output" "命令" "localized command field"
    test_assert_contains "$output" "network bbr" "technical command remains unchanged"
    test_assert_contains "$output" "风险" "localized risk field"
    test_assert_contains "$output" "<黄>变更<重置>" "localized colored risk value"
    test_assert_contains "$output" "权限" "localized privilege field"
    test_assert_contains "$output" "演练" "localized dry-run field"
    test_assert_contains "$output" "生命周期" "localized lifecycle field"

    VPS_UI_GREEN=$'\033[32m'
    VPS_UI_RESET=$'\033[0m'
    VPSCTL_NO_COLOR=1
    NO_COLOR=""
    vps_ui_init
    test_assert_equal "" "$VPS_UI_GREEN" "--no-color resets existing colors"
    test_assert_equal "" "$VPS_UI_RESET" "--no-color resets existing reset code"
    output="$(vps_ui_info "测试")"
    test_assert_no_ansi "$output" "--no-color UI output"

    VPS_UI_RED=$'\033[31m'
    VPSCTL_NO_COLOR=0
    NO_COLOR=1
    vps_ui_init
    test_assert_equal "" "$VPS_UI_RED" "NO_COLOR resets existing colors"
    output="$(vps_ui_clear_screen)"
    test_assert_equal "" "$output" "NO_COLOR suppresses ANSI clear sequence"
    unset NO_COLOR
    VPSCTL_NO_COLOR=0

    VPS_DOMAIN_IDS=()
    VPS_DOMAIN_LABEL=()
    VPS_DOMAIN_DESCRIPTION=()
    VPS_COMMAND_KEYS=()
    VPS_COMMAND_DOMAIN=()
    VPS_COMMAND_ACTION=()
    VPS_COMMAND_LABEL=()
    VPS_COMMAND_SUMMARY=()
    VPS_COMMAND_PATH=()
    VPS_COMMAND_RISK=()
    VPS_COMMAND_PRIVILEGE=()
    VPS_COMMAND_DRY_RUN=()
    VPS_COMMAND_REQUIREMENTS=()
    VPS_COMMAND_LIFECYCLE=()
    VPS_REGISTRY_RESULTS=()
    output="$(vps_ui_main_menu)"
    [[ "$output" == *"暂无已登记功能"* ]] || test_fail "empty menu should not invent feature categories"
    [[ "$output" != *"环境详情"* ]] || test_fail "environment details option should not be present"
    [[ "$output" != *"重新检测"* ]] || test_fail "environment refresh option should not be present"

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
test_environment_chinese_fallbacks
test_registry
test_ui_input
printf 'PASS: library tests\n'
