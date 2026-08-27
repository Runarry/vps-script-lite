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

test_cli() {
    local output status

    output="$("${VPSCTL[@]}" --version)"
    test_contains "$output" "vpsctl 0.2.0" "version output"

    output="$("${VPSCTL[@]}" --help)"
    test_contains "$output" "<domain> <action>" "help command model"

    output="$("${VPSCTL[@]}" env)"
    test_contains "$output" "VPS Script Lite" "environment header"
    test_contains "$output" "System" "environment system field"
    test_contains "$output" "BBR status" "BBR status field"
    test_contains "$output" "BBR version" "BBR version field"
    test_contains "$output" "CC algorithm" "congestion-control algorithm field"
    test_contains "$output" "Compatibility" "environment compatibility field"
    [[ "$output" != *"Init / Packages"* ]] || test_fail "removed Init / Packages field is still visible"
    [[ "$output" != *"Session"* ]] || test_fail "removed Session field is still visible"

    output="$("${VPSCTL[@]}" list)"
    test_contains "$output" "network bbr" "BBR command listing"
    test_contains "$output" "network dns" "DNS command listing"
    test_contains "$output" "network rfw" "RFW command listing"

    status=0
    "${VPSCTL[@]}" system missing >/dev/null 2>&1 || status=$?
    [[ "$status" == "2" ]] || test_fail "unknown command should return 2, got ${status}"

    status=0
    "${VPSCTL[@]}" --unknown >/dev/null 2>&1 || status=$?
    [[ "$status" == "2" ]] || test_fail "unknown option should return 2, got ${status}"
}

test_dispatch_security() {
    local sandbox output status marker

    [[ "$(uname -s)" == "Linux" ]] || return 0
    sandbox="$(mktemp -d)"
    mkdir -p "$sandbox/bin" "$sandbox/lib" "$sandbox/commands/network"
    cp "$TEST_ROOT/bin/vpsctl" "$sandbox/bin/vpsctl"
    cp "$TEST_ROOT"/lib/*.sh "$sandbox/lib/"
    cat >"$sandbox/commands/network/bbr.sh" <<'EOF'
#!/usr/bin/env bash
printf 'no_color=%s\n' "${VPSCTL_NO_COLOR:-missing}"
EOF
    chmod 0644 "$sandbox/commands/network/bbr.sh"

    output="$(bash "$sandbox/bin/vpsctl" --no-color network bbr status)"
    test_contains "$output" "no_color=1" "no-color child context"

    rm -rf -- "$sandbox/commands/network"
    mkdir -p "$sandbox/outside"
    marker="$sandbox/executed"
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
