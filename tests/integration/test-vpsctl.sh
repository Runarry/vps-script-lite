#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
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
    test_contains "$output" "vpsctl 0.1.0" "version output"

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
    test_contains "$output" "当前尚无已实现的功能命令" "empty command list"

    status=0
    "${VPSCTL[@]}" system missing >/dev/null 2>&1 || status=$?
    [[ "$status" == "2" ]] || test_fail "unknown command should return 2, got ${status}"

    status=0
    "${VPSCTL[@]}" --unknown >/dev/null 2>&1 || status=$?
    [[ "$status" == "2" ]] || test_fail "unknown option should return 2, got ${status}"
}

test_cli
printf 'PASS: vpsctl integration tests\n'
