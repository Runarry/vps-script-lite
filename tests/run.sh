#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly TEST_ROOT

bash -n \
    "${TEST_ROOT}/bin/vpsctl" \
    "${TEST_ROOT}/lib/environment.sh" \
    "${TEST_ROOT}/lib/command.sh" \
    "${TEST_ROOT}/lib/registry.sh" \
    "${TEST_ROOT}/lib/ui.sh" \
    "${TEST_ROOT}/commands/network/bbr.sh" \
    "${TEST_ROOT}/commands/network/dns.sh" \
    "${TEST_ROOT}/commands/network/rfw.sh" \
    "${TEST_ROOT}/tests/unit/test-libraries.sh" \
    "${TEST_ROOT}/tests/unit/test-command.sh" \
    "${TEST_ROOT}/tests/unit/test-network-bbr.sh" \
    "${TEST_ROOT}/tests/unit/test-network-dns.sh" \
    "${TEST_ROOT}/tests/unit/test-network-rfw.sh" \
    "${TEST_ROOT}/tests/integration/test-vpsctl.sh"

bash "${TEST_ROOT}/tests/unit/test-libraries.sh"
bash "${TEST_ROOT}/tests/unit/test-command.sh"
bash "${TEST_ROOT}/tests/unit/test-network-bbr.sh"
bash "${TEST_ROOT}/tests/unit/test-network-dns.sh"
bash "${TEST_ROOT}/tests/unit/test-network-rfw.sh"
bash "${TEST_ROOT}/tests/integration/test-vpsctl.sh"

printf 'PASS: all tests\n'
