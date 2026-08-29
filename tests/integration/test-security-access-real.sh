#!/usr/bin/env bash
# Opt-in destructive acceptance for the dedicated host-vps-scripts machine.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT

[[ "${VPSCTL_REAL_ACCESS_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_ACCESS_TEST=1 on the dedicated host\n'
    exit 0
}
[[ "${EUID:-$(id -u)}" == 0 ]] || {
    printf 'FAIL: real access acceptance requires root\n' >&2
    exit 4
}

user="${VPSCTL_REAL_ACCESS_USER:-}"
key_file="${VPSCTL_REAL_ACCESS_KEY_FILE:-}"
public_root="${VPSCTL_REAL_ACCESS_PUBLIC_ROOT:-}"
port="${VPSCTL_REAL_ACCESS_PORT:-22222}"
current_port=''
sshd_effective=''
tx_id=''
before_hashes="$(mktemp)"
after_hashes="$(mktemp)"
shopt -s nullglob
ssh_configs=(/etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf)

cleanup() {
    local active=''

    active="$(bash "$TEST_ROOT/bin/vpsctl" --no-color security access status --json 2>/dev/null |
        sed -n 's/.*"transaction": {"id": "\([^"]*\)".*/\1/p' || true)"
    if [[ -n "$active" && (-z "$tx_id" || "$active" == "$tx_id") ]]; then
        bash "$TEST_ROOT/bin/vpsctl" --no-color security access ssh abort --transaction "$active" || true
    fi
    rm -f -- "$before_hashes" "$after_hashes"
}
trap cleanup EXIT

abort_on_signal() {
    trap - HUP INT TERM
    cleanup
    trap - EXIT
    exit 130
}
trap abort_on_signal HUP INT TERM

[[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$user" != root ]] || {
    printf 'FAIL: set VPSCTL_REAL_ACCESS_USER to a non-root login user\n' >&2
    exit 2
}
[[ "$key_file" =~ ^/[A-Za-z0-9._/-]+$ && -f "$key_file" && ! -L "$key_file" ]] || {
    printf 'FAIL: set VPSCTL_REAL_ACCESS_KEY_FILE to a private key file\n' >&2
    exit 2
}
[[ "$public_root" =~ ^/[A-Za-z0-9._/-]+$ && -r "$public_root/bin/vpsctl" ]] || {
    printf 'FAIL: set VPSCTL_REAL_ACCESS_PUBLIC_ROOT to a user-readable project copy\n' >&2
    exit 2
}
[[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || exit 2
getent passwd "$user" >/dev/null
sshd_effective="$(sshd -T)"
current_port="$(awk '$1 == "port" {print $2; exit}' <<<"$sshd_effective")"
[[ "$current_port" =~ ^[0-9]+$ ]] || exit 10
ssh -tt -i "$key_file" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -p "$current_port" "$user@127.0.0.1" sudo -n true
[[ ! -f /var/lib/vpsctl/security/access/active ]] || {
    printf 'FAIL: an access transaction is already active\n' >&2
    exit 3
}
[[ -z "$(ss -H -ltn "( sport = :${port} )")" ]] || {
    printf 'FAIL: candidate port %s is already in use\n' "$port" >&2
    exit 3
}

sha256sum "${ssh_configs[@]}" >"$before_hashes"
prepare_output="$(bash "$TEST_ROOT/bin/vpsctl" --no-color security access ssh prepare \
    --port "$port" --root-login allow --password-login deny \
    --fallback-user "$user" --firewall manual 2>&1)"
printf '%s\n' "$prepare_output"
tx_id="$(grep -Eo 'tx-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}' <<<"$prepare_output" | tail -n 1)"
[[ -n "$tx_id" ]] || {
    printf 'FAIL: prepare did not return a transaction ID\n' >&2
    exit 20
}

ssh -tt -i "$key_file" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -p "$port" "$user@127.0.0.1" \
    bash "$public_root/bin/vpsctl" --no-color security access session verify --transaction "$tx_id"

uid="$(id -u "$user")"
proof="/var/lib/vpsctl/security/access/transactions/$tx_id/proofs/proof.$uid"
[[ -f "$proof" && ! -L "$proof" && "$(stat -c %u:%a -- "$proof")" == 0:600 ]] || {
    printf 'FAIL: proof is not a root-owned 0600 regular file\n' >&2
    exit 30
}

bash "$TEST_ROOT/bin/vpsctl" --no-color security access ssh abort --transaction "$tx_id"
tx_id=''
[[ ! -e /etc/ssh/sshd_config.d/00-vpsctl-access.conf ]] || {
    printf 'FAIL: abort left the managed SSH drop-in behind\n' >&2
    exit 30
}
sha256sum "${ssh_configs[@]}" >"$after_hashes"
diff -u "$before_hashes" "$after_hashes"
sshd -t
systemctl is-active --quiet ssh.service || systemctl is-active --quiet sshd.service
printf 'PASS: real security access double-port verification and abort\n'
