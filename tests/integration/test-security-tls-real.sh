#!/usr/bin/env bash
# Opt-in destructive acceptance for the dedicated host-vps-scripts machine.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT

[[ "${VPSCTL_REAL_TLS_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_TLS_TEST=1 on the dedicated host\n'
    exit 0
}
[[ "${EUID:-$(id -u)}" == 0 ]] || {
    printf 'FAIL: real TLS acceptance requires root\n' >&2
    exit 4
}

for tool in bash openssl sha256sum systemctl; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'FAIL: required acceptance tool is missing: %s\n' "$tool" >&2
        exit 3
    }
done

temp_dir="$(mktemp -d)"
imported=0
timer_enabled=0
id=""

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ -n "$id" ]]; then
        bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive security tls delete \
            --id "$id" --confirm-delete >/dev/null 2>&1 || true
    fi
    if ((timer_enabled == 1)); then
        bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive security tls uninstall \
            --confirm-uninstall REMOVE-VPSCTL-TLS >/dev/null 2>&1 || true
    fi
    rm -rf -- "$temp_dir"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=real.example" \
    -addext "subjectAltName=DNS:real.example" \
    -keyout "$temp_dir/key.pem" -out "$temp_dir/cert.pem" >/dev/null 2>&1

output="$(bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive security tls import \
    --name real-example --cert-file "$temp_dir/cert.pem" --key-file "$temp_dir/key.pem")"
id="$(grep -Eo 'crt-[0-9a-f]{16}' <<<"$output" | head -n 1)"
[[ "$id" =~ ^crt-[0-9a-f]{16}$ ]] || {
    printf 'FAIL: import did not return a certificate id\n' >&2
    exit 20
}
imported=1
[[ -f "/var/lib/vpsctl/security/tls/live/${id}/fullchain.pem" ]] || {
    printf 'FAIL: live fullchain missing after import\n' >&2
    exit 20
}

bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive security tls timer enable
timer_enabled=1
systemctl is-enabled --quiet vpsctl-tls-renew.timer || {
    printf 'FAIL: timer was not enabled\n' >&2
    exit 20
}

if [[ -n "${VPSCTL_TLS_TEST_DOMAIN:-}" ]]; then
    printf 'INFO: VPSCTL_TLS_TEST_DOMAIN is set; HTTP-01 staging issue is operator-run\n' >&2
    printf 'INFO: example: vpsctl security tls issue --domain %s --challenge http-01 --email test@example.test --staging\n' \
        "$VPSCTL_TLS_TEST_DOMAIN" >&2
fi

printf 'PASS: security tls real import and timer\n'
