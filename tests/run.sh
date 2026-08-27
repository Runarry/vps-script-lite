#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

bash -n \
    "${TEST_ROOT}/bin/vpsctl" \
    "${TEST_ROOT}/lib/environment.sh" \
    "${TEST_ROOT}/lib/registry.sh" \
    "${TEST_ROOT}/lib/ui.sh" \
    "${TEST_ROOT}/tests/unit/test-libraries.sh" \
    "${TEST_ROOT}/tests/integration/test-vpsctl.sh"

bash "${TEST_ROOT}/tests/unit/test-libraries.sh"
bash "${TEST_ROOT}/tests/integration/test-vpsctl.sh"

printf 'PASS: all tests\n'

