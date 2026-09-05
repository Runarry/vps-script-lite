#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly TEST_ROOT

for syntax_file in \
    "${TEST_ROOT}/vpsctl.sh" \
    "${TEST_ROOT}/bin/vpsctl" \
    "${TEST_ROOT}/lib/environment.sh" \
    "${TEST_ROOT}/lib/command.sh" \
    "${TEST_ROOT}/lib/distribution.sh" \
    "${TEST_ROOT}/lib/registry.sh" \
    "${TEST_ROOT}/lib/server-test.sh" \
    "${TEST_ROOT}/lib/ui.sh" \
    "${TEST_ROOT}/commands/network/bbr.sh" \
    "${TEST_ROOT}/commands/network/dns.sh" \
    "${TEST_ROOT}/commands/network/ip-policy.sh" \
    "${TEST_ROOT}/commands/network/rfw.sh" \
    "${TEST_ROOT}/commands/system/kernel.sh" \
    "${TEST_ROOT}"/commands/system/kernel/*.sh \
    "${TEST_ROOT}/commands/security/access.sh" \
    "${TEST_ROOT}"/commands/security/access/*.sh \
    "${TEST_ROOT}/commands/security/fail2ban.sh" \
    "${TEST_ROOT}/commands/security/tls.sh" \
    "${TEST_ROOT}"/commands/security/tls/*.sh \
    "${TEST_ROOT}/commands/service/proxy.sh" \
    "${TEST_ROOT}"/commands/service/proxy/*.sh \
    "${TEST_ROOT}"/commands/self/*.sh \
    "${TEST_ROOT}"/commands/test/*.sh \
    "${TEST_ROOT}/scripts/build-release.sh" \
    "${TEST_ROOT}/tests/unit/test-libraries.sh" \
    "${TEST_ROOT}/tests/unit/test-command.sh" \
    "${TEST_ROOT}/tests/unit/test-distribution.sh" \
    "${TEST_ROOT}/tests/unit/test-release-build.sh" \
    "${TEST_ROOT}/tests/unit/test-network-bbr.sh" \
    "${TEST_ROOT}/tests/unit/test-network-dns.sh" \
    "${TEST_ROOT}/tests/unit/test-network-ip-policy.sh" \
    "${TEST_ROOT}/tests/unit/test-network-rfw.sh" \
    "${TEST_ROOT}/tests/unit/test-system-kernel.sh" \
    "${TEST_ROOT}/tests/unit/test-system-kernel-providers.sh" \
    "${TEST_ROOT}/tests/unit/test-system-kernel-inventory.sh" \
    "${TEST_ROOT}/tests/unit/test-system-kernel-grub.sh" \
    "${TEST_ROOT}/tests/unit/test-security-access.sh" \
    "${TEST_ROOT}/tests/unit/test-security-fail2ban.sh" \
    "${TEST_ROOT}/tests/unit/test-security-tls.sh" \
    "${TEST_ROOT}/tests/unit/test-server-test.sh" \
    "${TEST_ROOT}/tests/unit/test-service-proxy.sh" \
    "${TEST_ROOT}/tests/integration/test-service-proxy-relay-connectivity-real.sh" \
    "${TEST_ROOT}/tests/integration/test-distribution-real.sh" \
    "${TEST_ROOT}/tests/integration/test-service-proxy-relay-cores-real.sh" \
    "${TEST_ROOT}/tests/integration/test-service-proxy-relay-real.sh" \
    "${TEST_ROOT}/tests/integration/test-security-fail2ban-real.sh" \
    "${TEST_ROOT}/tests/integration/test-security-tls-real.sh" \
    "${TEST_ROOT}/tests/integration/test-vpsctl.sh"; do
    bash -n "$syntax_file"
done

bash "${TEST_ROOT}/tests/unit/test-libraries.sh"
bash "${TEST_ROOT}/tests/unit/test-command.sh"
bash "${TEST_ROOT}/tests/unit/test-distribution.sh"
bash "${TEST_ROOT}/tests/unit/test-release-build.sh"
bash "${TEST_ROOT}/tests/unit/test-network-bbr.sh"
bash "${TEST_ROOT}/tests/unit/test-network-dns.sh"
bash "${TEST_ROOT}/tests/unit/test-network-ip-policy.sh"
bash "${TEST_ROOT}/tests/unit/test-network-rfw.sh"
bash "${TEST_ROOT}/tests/unit/test-system-kernel.sh"
bash "${TEST_ROOT}/tests/unit/test-system-kernel-providers.sh"
bash "${TEST_ROOT}/tests/unit/test-system-kernel-inventory.sh"
bash "${TEST_ROOT}/tests/unit/test-system-kernel-grub.sh"
bash "${TEST_ROOT}/tests/unit/test-security-access.sh"
bash "${TEST_ROOT}/tests/unit/test-security-fail2ban.sh"
bash "${TEST_ROOT}/tests/unit/test-security-tls.sh"
bash "${TEST_ROOT}/tests/unit/test-server-test.sh"
bash "${TEST_ROOT}/tests/unit/test-service-proxy.sh"
bash "${TEST_ROOT}/tests/integration/test-vpsctl.sh"

printf 'PASS: all tests\n'
