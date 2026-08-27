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

test_no_ansi() {
    local output="$1"
    local message="$2"
    [[ "$output" != *$'\033['* ]] || test_fail "${message}: unexpected ANSI escape"
}

test_cli() {
    local output status

    output="$("${VPSCTL[@]}" --version)"
    test_contains "$output" "vpsctl 0.3.0" "version output"

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
    test_contains "$output" "network rfw" "RFW command listing"
    test_contains "$output" "service proxy" "proxy command listing"

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
    local sandbox output status marker

    [[ "$(uname -s)" == "Linux" ]] || return 0
    sandbox="$(mktemp -d)"
    mkdir -p "$sandbox/bin" "$sandbox/lib" "$sandbox/commands/network" "$sandbox/commands/service/proxy"
    cp "$TEST_ROOT/bin/vpsctl" "$sandbox/bin/vpsctl"
    cp "$TEST_ROOT"/lib/*.sh "$sandbox/lib/"
    cat >>"$sandbox/lib/environment.sh" <<'EOF'

# Make dispatch capability checks hermetic: this fixture deliberately exposes
# Linux and no init/service capability, regardless of the integration host.
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
EOF
    chmod 0644 "$sandbox/commands/network/bbr.sh"

    cat >"$sandbox/commands/network/rfw.sh" <<'EOF'
#!/usr/bin/env bash
printf 'rfw_no_color=%s\n' "${VPSCTL_NO_COLOR:-missing}"
printf 'rfw_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'rfw:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
EOF
    chmod 0644 "$sandbox/commands/network/rfw.sh"

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

    output="$(bash "$sandbox/bin/vpsctl" --no-color network bbr status)"
    test_contains "$output" "no_color=1" "no-color child context"
    output="$(bash "$sandbox/bin/vpsctl" --install-deps network bbr status)"
    test_contains "$output" "install_deps=1" "install-deps child context"

    marker="$sandbox/executed"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --no-color network rfw --help)"
    test_contains "$output" "rfw_args=--help" "RFW global help dispatch without init capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" network rfw help)"
    test_contains "$output" "rfw_args=help" "RFW help dispatch without init capability"
    output="$(VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" network rfw status)"
    test_contains "$output" "rfw_args=status" "RFW status dispatch without init capability"

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

    rm -f -- "$marker"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" --dry-run network rfw install >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "RFW dry-run install without init capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "RFW dry-run install bypassed the capability gate"
    status=0
    VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" network rfw status extra >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "RFW malformed status without init capability should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "RFW malformed status bypassed the capability gate"
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
