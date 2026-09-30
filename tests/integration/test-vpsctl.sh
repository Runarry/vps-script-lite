#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
readonly VPSCTL=(bash "${TEST_ROOT}/bin/vpsctl" --no-color --no-clear)

test_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

test_contains() {
    local output="$1"
    local expected="$2"
    local message="$3"
    [[ "$output" == *"$expected"* ]] || test_fail "${message}: missing '${expected}'"
}

test_not_contains() {
    local output="$1"
    local unexpected="$2"
    local message="$3"
    [[ "$output" != *"$unexpected"* ]] || test_fail "${message}: unexpected '${unexpected}'"
}

test_no_ansi() {
    local output="$1"
    local message="$2"
    [[ "$output" != *$'\033['* ]] || test_fail "${message}: unexpected ANSI escape"
}

test_cli() {
    local output status option

    output="$("${VPSCTL[@]}" --version)"
    test_contains "$output" "vpsctl $(<"${TEST_ROOT}/VERSION")" "version output"

    output="$("${VPSCTL[@]}" --help)"
    test_contains "$output" "<domain> <action>" "help command model"
    test_contains "$output" "用法" "localized usage heading"
    test_contains "$output" "内置命令" "localized built-in heading"
    test_contains "$output" "--install-deps" "global install-deps help"
    test_no_ansi "$output" "--no-color help output"

    output="$("${VPSCTL[@]}" env)"
    test_contains "$output" "VPS Script Lite" "environment header"
    test_contains "$output" "系统" "environment system field"
    test_contains "$output" "BBR 状态" "BBR status field"
    test_contains "$output" "BBR 版本" "BBR version field"
    test_contains "$output" "拥塞控制" "congestion-control algorithm field"
    test_contains "$output" "兼容性" "environment compatibility field"
    test_contains "$output" "系统族" "environment OS family field"
    test_contains "$output" "代号" "environment codename field"
    test_contains "$output" "用户空间" "environment libc field"
    test_no_ansi "$output" "--no-color environment output"
    [[ "$output" != *"Init / Packages"* ]] || test_fail "removed Init / Packages field is still visible"
    [[ "$output" != *"Session"* ]] || test_fail "removed Session field is still visible"

    output="$(TERM=xterm bash "${TEST_ROOT}/bin/vpsctl" env)"
    test_no_ansi "$output" "non-TTY environment output"
    output="$(NO_COLOR=1 TERM=xterm bash "${TEST_ROOT}/bin/vpsctl" env)"
    test_no_ansi "$output" "NO_COLOR environment output"

    output="$("${VPSCTL[@]}" list)"
    test_contains "$output" "network bbr" "BBR command listing"
    test_contains "$output" "network dns" "DNS command listing"
    test_contains "$output" "network ip-policy" "IP policy command listing"
    test_contains "$output" "network ufw" "UFW command listing"
    test_contains "$output" "network rfw" "RFW command listing"
    test_contains "$output" "system kernel" "kernel command listing"
    test_contains "$output" "system reinstall" "reinstall command listing"
    test_contains "$output" "security access" "access command listing"
    test_contains "$output" "security tls" "tls command listing"
    test_contains "$output" "service proxy" "proxy command listing"
    test_contains "$output" "service tcping" "tcping command listing"
    test_contains "$output" "test nodequality" "NodeQuality command listing"
    test_contains "$output" "test tcpquality" "TCPQuality command listing"
    test_contains "$output" "self status" "self status command listing"
    test_contains "$output" "self update" "self update command listing"
    test_contains "$output" "self uninstall" "self uninstall command listing"

    for option in --dry-run --install-deps --yes --non-interactive --quiet --verbose; do
        status=0
        output="$("${VPSCTL[@]}" "$option" menu 2>&1)" || status=$?
        [[ "$status" == "2" ]] || test_fail "menu option $option should return 2, got ${status}"
        test_contains "$output" "$option" "menu execution-option rejection"
        test_contains "$output" "交互菜单不能使用执行型全局选项" "localized menu option rejection"
    done

    status=0
    output="$(bash "${TEST_ROOT}/bin/vpsctl" --no-color --no-clear menu 2>&1)" || status=$?
    [[ "$status" == "2" ]] || test_fail "non-TTY menu should return 2, got ${status}"
    test_contains "$output" "交互菜单需要终端" "display-only menu options remain accepted"
    test_not_contains "$output" "不能使用执行型全局选项" "display-only menu option rejection"

    status=0
    output="$("${VPSCTL[@]}" system missing 2>&1)" || status=$?
    [[ "$status" == "2" ]] || test_fail "unknown command should return 2, got ${status}"
    test_contains "$output" "未知命令" "localized unknown-command error"
    test_no_ansi "$output" "--no-color unknown-command error"

    status=0
    output="$("${VPSCTL[@]}" --unknown 2>&1)" || status=$?
    [[ "$status" == "2" ]] || test_fail "unknown option should return 2, got ${status}"
    test_contains "$output" "未知全局选项" "localized unknown-option error"
    test_no_ansi "$output" "--no-color unknown-option error"
}

test_entry_version() (
    local sandbox output status value marker menu_command
    local -a reader=(bash)
    sandbox="$(mktemp -d)"
    trap 'rm -rf -- "$sandbox"' EXIT
    mkdir -p "$sandbox/bin" "$sandbox/lib"
    cp "$TEST_ROOT/bin/vpsctl" "$sandbox/bin/vpsctl"
    cp "$TEST_ROOT"/lib/*.sh "$sandbox/lib/"
    printf '9.8.7\n' >"$sandbox/VERSION"
    output="$(bash "$sandbox/bin/vpsctl" --no-color --version)"
    [[ "$output" == 'vpsctl 9.8.7' ]] || test_fail "temporary VERSION did not control CLI: $output"
    output="$(bash "$sandbox/bin/vpsctl" --no-color env)"
    test_contains "$output" 'v9.8.7' 'temporary VERSION controls environment panel'
    if command -v script >/dev/null 2>&1; then
        printf -v menu_command 'TERM=xterm bash %q --no-color --no-clear menu' "$sandbox/bin/vpsctl"
        output="$(printf 'q\n' | script -q -e -f -c "$menu_command" /dev/null 2>&1)"
        test_contains "$output" 'v9.8.7' 'temporary VERSION controls TTY menu'
    else
        printf 'SKIP: version menu test requires script\n'
    fi
    printf '9.8.7' >"$sandbox/VERSION"
    output="$(bash "$sandbox/bin/vpsctl" --version)"
    [[ "$output" == 'vpsctl 9.8.7' ]] || test_fail 'valid VERSION without a final newline was rejected'

    # If startup reaches even its first library, record it and fail differently.
    marker="$sandbox/library-loaded"
    printf 'printf loaded >%q\nexit 99\n' "$marker" >"$sandbox/lib/environment.sh"
    assert_version_rejected() {
        local description="$1" option
        local -a command_args=()
        for option in --version env dispatch; do
            command_args=("$option")
            [[ "$option" != dispatch ]] || command_args=(network bbr status)
            status=0
            output="$("${reader[@]}" "$sandbox/bin/vpsctl" "${command_args[@]}" 2>&1)" || status=$?
            [[ "$status" == 3 ]] || test_fail "$description should return 3, got $status: $output"
            [[ ! -e "$marker" ]] || test_fail "$description loaded libraries before rejecting VERSION"
            test_contains "$output" VERSION "$description diagnostic identifies VERSION"
        done
    }
    rm -- "$sandbox/VERSION"
    assert_version_rejected 'missing VERSION'
    for value in '' '9.8' 'v9.8.7' '9.8.7-beta' ' 9.8.7' $'9.8.7\n1.2.3'; do
        printf '%s' "$value" >"$sandbox/VERSION"
        assert_version_rejected "empty or malformed VERSION <$value>"
    done
    rm -- "$sandbox/VERSION"
    mkdir "$sandbox/VERSION"
    assert_version_rejected 'non-regular VERSION'
    rmdir "$sandbox/VERSION"
    printf '9.8.7\n' >"$sandbox/VERSION"
    chmod 0000 "$sandbox/VERSION"
    if ((EUID != 0)); then
        assert_version_rejected 'unreadable VERSION'
    elif command -v setpriv >/dev/null 2>&1; then
        reader=(setpriv '--bounding-set=-dac_override,-dac_read_search' bash)
        assert_version_rejected 'unreadable VERSION without DAC override'
    else
        printf 'SKIP: unreadable VERSION as root requires setpriv\n'
    fi
    chmod 0600 "$sandbox/VERSION"
)

test_dispatch_security() {
    local sandbox output status marker menu_command download_marker core invalid
    local -a invalid_args=()

    [[ "$(uname -s)" == "Linux" ]] || return 0
    sandbox="$(mktemp -d)"
    mkdir -p "$sandbox/bin" "$sandbox/lib" "$sandbox/commands/network" "$sandbox/commands/system" "$sandbox/commands/security" "$sandbox/commands/service/proxy" "$sandbox/commands/test"
    cp "$TEST_ROOT/bin/vpsctl" "$sandbox/bin/vpsctl"
    cp "$TEST_ROOT"/lib/*.sh "$sandbox/lib/"
    cp "$TEST_ROOT/VERSION" "$sandbox/VERSION"
    cat >>"$sandbox/lib/distribution.sh" <<'EOF'

vps_distribution_ensure_command() {
    if [[ -n "${VPSCTL_DOWNLOAD_MARKER:-}" ]]; then
        printf '%s\n' "$1" >>"$VPSCTL_DOWNLOAD_MARKER"
    fi
}
EOF
    cat >>"$sandbox/lib/environment.sh" <<'EOF'

# Make dispatch capability checks hermetic: this fixture deliberately exposes
# Linux and no init/service capability, regardless of the integration host.
vps_env_detect() {
    VPS_ENV[hostname]="fixture"
    VPS_ENV[user]="fixture"
    VPS_ENV[session]="non-interactive"
    VPS_ENV[interactive]="no"
    VPS_ENV[kernel_name]="Linux"
    VPS_ENV[kernel_release]="fixture"
    VPS_ENV[architecture]="x86_64"
    VPS_ENV[os_id]="fixture"
    VPS_ENV[os_id_like]=""
    VPS_ENV[os_version_id]="1"
    VPS_ENV[os_codename]="fixture"
    VPS_ENV[os_pretty_name]="Fixture Linux"
    VPS_ENV[libc]="musl"
    VPS_ENV[bash_version]="${BASH_VERSION}"
    VPS_ENV[cpu_model]="fixture"
    VPS_ENV[cpu_cores]="1"
    VPS_ENV[memory_total]="1.0 GiB"
    VPS_ENV[uptime]="1 分钟"
    VPS_ENV[root_disk_total]="1.0 GiB"
    VPS_ENV[root_disk_available]="1.0 GiB"
    VPS_ENV[root_disk_used_percent]="0%"
    VPS_ENV[ipv4]="192.0.2.1"
    VPS_ENV[ipv6]="unavailable"
    VPS_ENV[init_system]="none"
    VPS_ENV[service_manager]="none"
    VPS_ENV[package_manager]="unknown"
    VPS_ENV[timezone]="UTC"
    VPS_ENV[virtualization]="unknown"
    VPS_ENV[is_root]="no"
    VPS_ENV[bbr_status]="disabled"
    VPS_ENV[bbr_version]="unavailable"
    VPS_ENV[congestion_control]="unknown"
    VPS_ENV[available_congestion_controls]="unknown"
    VPS_ENV[compatibility]="limited"
    VPS_ENV[compatibility_detail]="fixture"
}

vps_env_requirements_met() {
    VPS_ENV_MISSING_REQUIREMENTS=""
    if [[ "${1:-}" == "linux" ]]; then
        return 0
    fi
    VPS_ENV_MISSING_REQUIREMENTS="${1:-unknown}"
    return 1
}
EOF
    cat >"$sandbox/commands/network/bbr.sh" <<'EOF'
#!/usr/bin/env bash
printf 'no_color=%s\n' "${VPSCTL_NO_COLOR:-missing}"
printf 'install_deps=%s\n' "${VPSCTL_INSTALL_DEPS:-missing}"
printf 'libc=%s\n' "${VPSCTL_ENV_LIBC:-missing}"
printf 'bbr_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'bbr:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
exit "${VPSCTL_DISPATCH_STATUS:-0}"
EOF
    chmod 0644 "$sandbox/commands/network/bbr.sh"

    cat >"$sandbox/commands/network/ip-policy.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ip_policy_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'ip-policy:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
EOF
    chmod 0644 "$sandbox/commands/network/ip-policy.sh"

    cat >"$sandbox/commands/network/rfw.sh" <<'EOF'
#!/usr/bin/env bash
printf 'rfw_no_color=%s\n' "${VPSCTL_NO_COLOR:-missing}"
printf 'rfw_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'rfw:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
EOF
    chmod 0644 "$sandbox/commands/network/rfw.sh"

    cat >"$sandbox/commands/system/kernel.sh" <<'EOF'
#!/usr/bin/env bash
printf 'kernel_no_color=%s\n' "${VPSCTL_NO_COLOR:-missing}"
printf 'kernel_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'kernel:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
EOF
    chmod 0644 "$sandbox/commands/system/kernel.sh"

    cat >"$sandbox/commands/system/reinstall.sh" <<'EOF'
#!/usr/bin/env bash
printf 'reinstall_noninteractive=%s\n' "${VPSCTL_NON_INTERACTIVE:-missing}"
printf 'reinstall_arg=<%s>\n' "$@"
exit "${VPSCTL_DISPATCH_STATUS:-0}"
EOF
    chmod 0644 "$sandbox/commands/system/reinstall.sh"

    cat >"$sandbox/commands/security/access.sh" <<'EOF'
#!/usr/bin/env bash
printf 'access_no_color=%s\n' "${VPSCTL_NO_COLOR:-missing}"
printf 'access_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'access:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
EOF
    chmod 0644 "$sandbox/commands/security/access.sh"

    cat >"$sandbox/commands/security/fail2ban.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fail2ban_no_color=%s\n' "${VPSCTL_NO_COLOR:-missing}"
printf 'fail2ban_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'fail2ban:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
EOF
    chmod 0644 "$sandbox/commands/security/fail2ban.sh"

    cat >"$sandbox/commands/service/proxy.sh" <<'EOF'
#!/usr/bin/env bash
printf 'proxy_no_color=%s\n' "${VPSCTL_NO_COLOR:-missing}"
printf 'proxy_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'proxy:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
EOF
    for module in common protocols-sing-box protocols-xray nodes core time; do
        printf '# safe proxy module fixture: %s\n' "$module" >"$sandbox/commands/service/proxy/${module}.sh"
        chmod 0644 "$sandbox/commands/service/proxy/${module}.sh"
    done
    chmod 0644 "$sandbox/commands/service/proxy.sh"

    cat >"$sandbox/commands/service/tcping.sh" <<'EOF'
#!/usr/bin/env bash
printf 'tcping_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'tcping:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
EOF
    chmod 0644 "$sandbox/commands/service/tcping.sh"

    cat >"$sandbox/commands/test/nodequality.sh" <<'EOF'
#!/usr/bin/env bash
printf 'nodequality_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'nodequality:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
EOF
    cat >"$sandbox/commands/test/tcpquality.sh" <<'EOF'
#!/usr/bin/env bash
printf 'tcpquality_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'tcpquality:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
EOF
    chmod 0644 "$sandbox/commands/test/nodequality.sh" "$sandbox/commands/test/tcpquality.sh"

    output="$(bash "$sandbox/bin/vpsctl" --no-color network bbr status)"
    test_contains "$output" "no_color=1" "no-color child context"
    output="$(bash "$sandbox/bin/vpsctl" --install-deps network bbr status)"
    test_contains "$output" "install_deps=1" "install-deps child context"
    test_contains "$output" "libc=musl" "libc child context"

    if command -v script >/dev/null 2>&1; then
        marker="$sandbox/menu-executed"
        printf -v menu_command 'env VPSCTL_DISPATCH_MARKER=%q VPSCTL_DISPATCH_STATUS=7 bash %q --no-color --no-clear menu' "$marker" "$sandbox/bin/vpsctl"
        status=0
        output="$(printf '1\n1\n\nb\nq\n' | script -q -e -f -c "$menu_command" /dev/null 2>&1)" || status=$?
        [[ "$status" == "7" ]] || test_fail "menu should preserve feature status 7, got ${status}"
        test_contains "$output" "bbr_args=" "menu zero-argument dispatch"
        test_not_contains "$output" "命令详情" "removed command detail screen"
        test_not_contains "$output" "[r] 无附加参数运行" "removed run confirmation"
        [[ -f "$marker" && "$(<"$marker")" == "bbr:" ]] || test_fail "menu did not dispatch the selected feature without arguments"
    fi

    marker="$sandbox/executed"
    download_marker="$sandbox/downloaded"
    output="$(VPSCTL_DOWNLOAD_MARKER="$download_marker" VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" network ip-policy --help)"
    test_contains "$output" "ip_policy_args=--help" "IP policy help dispatch without glibc capability"
    [[ -f "$download_marker" ]] || test_fail 'allowed help did not load its command bundle'
    rm -f -- "$marker" "$download_marker"
    status=0
    VPSCTL_DOWNLOAD_MARKER="$download_marker" VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" network ip-policy status >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "IP policy status without glibc capability should return 3, got ${status}"
    [[ ! -e "$download_marker" ]] || test_fail 'unsupported platform loaded a command bundle before rejection'
    [[ ! -e "$marker" ]] || test_fail "IP policy status bypassed the glibc capability gate"

    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --no-color network rfw --help)"
    test_contains "$output" "rfw_args=--help" "RFW global help dispatch without init capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" network rfw help)"
    test_contains "$output" "rfw_args=help" "RFW help dispatch without init capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" network rfw status)"
    test_contains "$output" "rfw_args=status" "RFW status dispatch without init capability"

    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --no-color system kernel status)"
    test_contains "$output" "kernel_no_color=1" "kernel no-color child context"
    test_contains "$output" "kernel_args=status" "kernel status dispatch"
    output="$(bash "$sandbox/bin/vpsctl" --non-interactive system reinstall run -- windows --image-name 'Windows 11 Enterprise LTSC 2024' --iso 'https://example.invalid/a.iso?x=1&y=two' --password 'a $b; c')"
    test_contains "$output" 'reinstall_noninteractive=1' "reinstall global context"
    test_contains "$output" 'reinstall_arg=<-->' "reinstall upstream separator"
    test_contains "$output" 'reinstall_arg=<Windows 11 Enterprise LTSC 2024>' "reinstall spaced argument"
    test_contains "$output" 'reinstall_arg=<https://example.invalid/a.iso?x=1&y=two>' "reinstall URL argument"
    # shellcheck disable=SC2016 # The dollar sign must remain literal in forwarded arguments.
    test_contains "$output" 'reinstall_arg=<a $b; c>' "reinstall literal shell characters"
    status=0
    VPSCTL_DISPATCH_STATUS=17 bash "$sandbox/bin/vpsctl" system reinstall run dd >/dev/null 2>&1 || status=$?
    [[ "$status" == 17 ]] || test_fail "reinstall exit status was not preserved: $status"
    rm -f -- "$marker"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --dry-run system kernel install >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "kernel install outside Debian family should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "kernel install bypassed the Debian-family capability gate"

    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --no-color security access status)"
    test_contains "$output" "access_no_color=1" "access no-color child context"
    test_contains "$output" "access_args=status" "access status dispatch"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" security access status --user alice --json)"
    test_contains "$output" "access_args=status --user alice --json" "access parameterized status dispatch without init capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" security access session verify --transaction tx-test)"
    test_contains "$output" "access_args=session verify --transaction tx-test" "access proof dispatch without init capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" security access --help)"
    test_contains "$output" "access_args=--help" "access help dispatch without init capability"

    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --no-color security fail2ban status)"
    test_contains "$output" "fail2ban_no_color=1" "Fail2ban no-color child context"
    test_contains "$output" "fail2ban_args=status" "Fail2ban status dispatch"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" security fail2ban status --json)"
    test_contains "$output" "fail2ban_args=status --json" "Fail2ban JSON status dispatch without init capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" security fail2ban --help)"
    test_contains "$output" "fail2ban_args=--help" "Fail2ban help dispatch without init capability"

    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --no-color service proxy status)"
    test_contains "$output" "proxy_no_color=1" "proxy no-color child context"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service proxy status --json)"
    test_contains "$output" 'proxy_args=status --json' 'proxy JSON status without service capability'
    for core in all sing-box xray; do
        output="$(bash "$sandbox/bin/vpsctl" service proxy status --core "$core")"
        test_contains "$output" "proxy_args=status --core $core" 'proxy selected-core status without service capability'
        output="$(bash "$sandbox/bin/vpsctl" service proxy status --core "$core" --json)"
        test_contains "$output" "proxy_args=status --core $core --json" 'proxy selected-core JSON status without service capability'
        output="$(bash "$sandbox/bin/vpsctl" service proxy status --json --core "$core")"
        test_contains "$output" "proxy_args=status --json --core $core" 'proxy reordered JSON status without service capability'
    done
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service proxy --help)"
    test_contains "$output" "proxy_args=--help" "proxy global help dispatch without service capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service proxy help)"
    test_contains "$output" "proxy_args=help" "proxy help dispatch without service capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service proxy profiles)"
    test_contains "$output" "proxy_args=profiles" "proxy profiles dispatch without service capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service proxy time status)"
    test_contains "$output" "proxy_args=time status" "proxy time status dispatch without service capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service proxy time status --json)"
    test_contains "$output" "proxy_args=time status --json" "proxy JSON time status dispatch without service capability"

    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service tcping --help)"
    test_contains "$output" "tcping_args=--help" "tcping help dispatch without service capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service tcping status)"
    test_contains "$output" "tcping_args=status" "tcping status dispatch without service capability"

    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" test nodequality help)"
    test_contains "$output" "nodequality_args=help" "NodeQuality help dispatch without root capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" test tcpquality --help)"
    test_contains "$output" "tcpquality_args=--help" "TCPQuality help dispatch without root capability"

    rm -f -- "$marker"
    status=0
    VPSCTL_DOWNLOAD_MARKER="$download_marker" VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" test nodequality >/dev/null 2>&1 || status=$?
    [[ "$status" == "4" ]] || test_fail "NodeQuality execution without root capability should return 4, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "NodeQuality execution bypassed the root capability gate"
    [[ ! -e "$download_marker" ]] || test_fail 'unprivileged execution loaded a bundle before rejection'
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" test tcpquality help extra >/dev/null 2>&1 || status=$?
    [[ "$status" == "4" ]] || test_fail "malformed TCPQuality help without root capability should return 4, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "malformed TCPQuality help bypassed the root capability gate"

    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --dry-run network rfw install >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "RFW dry-run install without init capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "RFW dry-run install bypassed the capability gate"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" network rfw status extra >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "RFW malformed status without init capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "RFW malformed status bypassed the capability gate"
    status=0
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" security access 2>&1)" || status=$?
    [[ "$status" == "3" ]] || test_fail "access menu without init capability should return 3, got ${status}"
    test_not_contains "$output" "unbound variable" "access menu without subcommand"
    test_contains "$output" "init:systemd" "access menu retains init capability requirement"
    [[ ! -e "$marker" ]] || test_fail "access menu bypassed the capability gate"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" security access status --unknown >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "access malformed status without init capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "access malformed status bypassed the capability gate"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" security fail2ban status --unknown >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "Fail2ban malformed status without init capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "Fail2ban malformed status bypassed the capability gate"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --dry-run security fail2ban install >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "Fail2ban install without init capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "Fail2ban install bypassed the capability gate"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --dry-run security access ssh prepare --port 2222 --firewall manual >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "access prepare without init capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "access prepare bypassed the capability gate"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --dry-run service proxy update >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "proxy dry-run update without service capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "proxy dry-run update bypassed the capability gate"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --dry-run service proxy install >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "proxy dry-run install without service capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "proxy dry-run install bypassed the capability gate"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service proxy start >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "proxy start without service capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "proxy start bypassed the capability gate"
    for invalid in '--json --json' '--core xray --core all' '--core' '--core --json' '--core unknown' '--json extra' '--unknown'; do
        IFS=' ' read -r -a invalid_args <<<"$invalid"
        status=0
        VPSCTL_DOWNLOAD_MARKER="$download_marker" VPSCTL_DISPATCH_MARKER="$marker" \
            bash "$sandbox/bin/vpsctl" service proxy status "${invalid_args[@]}" >/dev/null 2>&1 || status=$?
        [[ "$status" == 3 ]] || test_fail "malformed proxy status bypassed service capability: $invalid (rc=$status)"
        [[ ! -e "$marker" && ! -e "$download_marker" ]] || test_fail "malformed proxy status loaded or ran a command: $invalid"
    done
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service proxy profiles extra >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "proxy malformed profiles without service capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "proxy malformed profiles bypassed the capability gate"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service tcping install >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "tcping install without service capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "tcping install bypassed the capability gate"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service tcping status extra >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "tcping malformed status without service capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "tcping malformed status bypassed the capability gate"

    rm -rf -- "$sandbox/commands/network"
    mkdir -p "$sandbox/outside"
    cat >"$sandbox/outside/bbr.sh" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
    ln -s ../outside "$sandbox/commands/network"
    status=0
    bash "$sandbox/bin/vpsctl" network bbr status >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "symlinked command ancestor should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "symlinked command ancestor was executed"
    rm -rf -- "$sandbox"
}

test_menu_self_lifecycle() (
    [[ "$(uname -s)" == Linux ]] || return 0
    command -v script >/dev/null 2>&1 || { printf 'SKIP: self menu tests require script\n'; return 0; }
    local sandbox install template scenario command output status expected action input domain_index index
    local self_index status_index update_index uninstall_index
    sandbox="$(mktemp -d)"
    trap 'rm -rf -- "$sandbox"' EXIT
    install="$sandbox/install"
    template="$sandbox/template"
    mkdir -p "$template/bin" "$template/lib" "$template/commands/self"
    cp "$TEST_ROOT/bin/vpsctl" "$template/bin/vpsctl"
    cp "$TEST_ROOT"/lib/*.sh "$template/lib/"
    cp "$TEST_ROOT/VERSION" "$template/VERSION"
    cat >>"$template/lib/distribution.sh" <<'EOF'

# Exercise the real menu and dispatch with lifecycle operations isolated to
# this fixture. Bundle activation itself has separate distribution coverage.
vps_distribution_ensure_command() { return 0; }
EOF
    cat >"$template/commands/self/status.sh" <<'EOF'
printf 'menu-status:%s color=%s clear=%s\n' "${VPSCTL_PROJECT_ROOT##*/}" "$VPSCTL_NO_COLOR" "$VPSCTL_CLEAR"
EOF
    cat >"$template/commands/self/update.sh" <<'EOF'
set -Eeuo pipefail
case "$VPSCTL_MENU_CASE" in
    update | partial-new | invalid-entry)
        ln -sfn -- "$VPSCTL_INSTALL_ROOT/releases/new" "$VPSCTL_INSTALL_ROOT/current"
        rm -rf -- "$VPSCTL_INSTALL_ROOT/releases/old"
        if [[ "$VPSCTL_MENU_CASE" == invalid-entry ]]; then
            printf '#!/nonexistent/vpsctl-menu-interpreter\n' >"$VPSCTL_MANAGED_ENTRY"
        fi
        [[ "$VPSCTL_MENU_CASE" != partial-new ]] || exit 30
        ;;
    fail) exit 20 ;;
    partial-old) exit 30 ;;
    no-entry) rm -- "$VPSCTL_MANAGED_ENTRY" ;;
    uninstall) rm -- "$VPSCTL_MANAGED_ENTRY" "$VPSCTL_INSTALL_ROOT/current" ;;
    partial-uninstall) rm -- "$VPSCTL_MANAGED_ENTRY"; exit 20 ;;
    same | cancel-update | cancel-uninstall) ;;
    *) exit 99 ;;
esac
EOF
    cp "$template/commands/self/update.sh" "$template/commands/self/uninstall.sh"

    # shellcheck source=../../lib/registry.sh
    source "$TEST_ROOT/lib/registry.sh"
    vps_registry_init
    for domain_index in "${!VPS_DOMAIN_IDS[@]}"; do
        [[ "${VPS_DOMAIN_IDS[$domain_index]}" != self ]] || self_index=$((domain_index + 1))
    done
    vps_registry_commands_for_domain self
    for index in "${!VPS_REGISTRY_RESULTS[@]}"; do
        case "${VPS_REGISTRY_RESULTS[$index]}" in
            self:status) status_index=$((index + 1)) ;;
            self:update) update_index=$((index + 1)) ;;
            self:uninstall) uninstall_index=$((index + 1)) ;;
        esac
    done

    for scenario in update same cancel-update fail partial-old partial-new no-entry invalid-entry uninstall cancel-uninstall partial-uninstall; do
        rm -rf -- "$install"
        mkdir -p "$install/releases"
        cp -a -- "$template" "$install/releases/old"
        cp -a -- "$template" "$install/releases/new"
        ln -s -- "$install/releases/old" "$install/current"
        cat >"$install/entry" <<'EOF'
#!/usr/bin/env bash
exec bash "$VPSCTL_INSTALL_ROOT/current/bin/vpsctl" "$@"
EOF
        chmod 0755 "$install/entry"
        action="$update_index"
        expected=0
        case "$scenario" in
            uninstall | cancel-uninstall | partial-uninstall) action="$uninstall_index" ;;
        esac
        case "$scenario" in
            partial-old | partial-new) expected=30 ;;
            no-entry | invalid-entry | partial-uninstall) expected=20 ;;
        esac
        if [[ "$scenario" == update ]]; then
            printf -v input '%s\n%s\n%s\n%s\n\nq\n' "$self_index" "$action" "$self_index" "$status_index"
        else
            printf -v input '%s\n%s\n\n%s\n\nq\n' "$self_index" "$action" "$status_index"
        fi
        printf -v command 'env VPSCTL_DISTRIBUTED=1 VPSCTL_INSTALL_ROOT=%q VPSCTL_MANAGED_ENTRY=%q VPSCTL_MENU_CASE=%q TERM=xterm bash %q --no-color --no-clear menu' \
            "$install" "$install/entry" "$scenario" "$install/releases/old/bin/vpsctl"
        status=0
        output="$(printf '%s' "$input" | script -q -e -f -c "$command" /dev/null 2>&1)" || status=$?
        [[ "$status" == "$expected" ]] || test_fail "self menu $scenario: expected $expected, got $status: $output"
        test_no_ansi "$output" "self menu $scenario display options"
        case "$scenario" in
            update)
                test_contains "$output" 'menu-status:new color=1 clear=0' 'updated menu dispatch and display options'
                test_not_contains "$output" 'menu-status:old' 'old menu must not resume after update'
                [[ ! -e "$install/releases/old" ]] || test_fail 'update fixture retained old release'
                ;;
            same | cancel-update | fail | cancel-uninstall)
                test_contains "$output" 'menu-status:old color=1 clear=0' "self menu $scenario continuation"
                test_not_contains "$output" '正在进入新版本主菜单' "self menu $scenario should not restart"
                ;;
            *) test_not_contains "$output" 'menu-status:' "self menu $scenario must exit before another command" ;;
        esac
        if [[ "$scenario" == invalid-entry ]]; then
            test_contains "$output" '无法启动更新后的受管入口' 'new entry execution failure'
        fi
    done
)

if [[ "${VPSCTL_TEST_ONLY:-}" == entry-version ]]; then
    test_entry_version
    printf 'PASS: vpsctl entry version tests\n'
    exit 0
fi

test_cli
test_entry_version
test_dispatch_security
test_menu_self_lifecycle
printf 'PASS: vpsctl integration tests\n'
