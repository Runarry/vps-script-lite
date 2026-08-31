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
    test_contains "$output" "vpsctl 0.5.0" "version output"

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
    test_contains "$output" "network rfw" "RFW command listing"
    test_contains "$output" "security access" "access command listing"
    test_contains "$output" "service proxy" "proxy command listing"
    test_contains "$output" "test nodequality" "NodeQuality command listing"
    test_contains "$output" "test tcpquality" "TCPQuality command listing"

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

test_dispatch_security() {
    local sandbox output status marker menu_command

    [[ "$(uname -s)" == "Linux" ]] || return 0
    sandbox="$(mktemp -d)"
    mkdir -p "$sandbox/bin" "$sandbox/lib" "$sandbox/commands/network" "$sandbox/commands/security" "$sandbox/commands/service/proxy" "$sandbox/commands/test"
    cp "$TEST_ROOT/bin/vpsctl" "$sandbox/bin/vpsctl"
    cp "$TEST_ROOT"/lib/*.sh "$sandbox/lib/"
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
printf 'bbr_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'bbr:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
exit "${VPSCTL_DISPATCH_STATUS:-0}"
EOF
    chmod 0644 "$sandbox/commands/network/bbr.sh"

    cat >"$sandbox/commands/network/rfw.sh" <<'EOF'
#!/usr/bin/env bash
printf 'rfw_no_color=%s\n' "${VPSCTL_NO_COLOR:-missing}"
printf 'rfw_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'rfw:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
EOF
    chmod 0644 "$sandbox/commands/network/rfw.sh"

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
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --no-color network rfw --help)"
    test_contains "$output" "rfw_args=--help" "RFW global help dispatch without init capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" network rfw help)"
    test_contains "$output" "rfw_args=help" "RFW help dispatch without init capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" network rfw status)"
    test_contains "$output" "rfw_args=status" "RFW status dispatch without init capability"

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

    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" test nodequality help)"
    test_contains "$output" "nodequality_args=help" "NodeQuality help dispatch without root capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" test tcpquality --help)"
    test_contains "$output" "tcpquality_args=--help" "TCPQuality help dispatch without root capability"

    rm -f -- "$marker"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" test nodequality >/dev/null 2>&1 || status=$?
    [[ "$status" == "4" ]] || test_fail "NodeQuality execution without root capability should return 4, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "NodeQuality execution bypassed the root capability gate"
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
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" service proxy profiles extra >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "proxy malformed profiles without service capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "proxy malformed profiles bypassed the capability gate"

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

test_cli
test_dispatch_security
printf 'PASS: vpsctl integration tests\n'
