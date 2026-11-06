#!/usr/bin/env bash
# Opt-in acceptance using real sshd and a temporary login account.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT

[[ "${VPSCTL_REAL_ACCESS_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_ACCESS_TEST=1 on the dedicated host\n'
    exit 0
}
[[ "$EUID" == 0 ]] || exit 4
[[ ! -e /var/lib/vpsctl/security/access/active ]] || exit 3
managed=/etc/ssh/sshd_config.d/00-vpsctl-access.conf
disabled=/etc/ssh/sshd_config.d/01-vpsctl-pubkey-test.conf
[[ ! -e "$managed" && ! -L "$managed" && ! -e "$disabled" && ! -L "$disabled" ]] || {
    printf 'FAIL: acceptance requires unused managed/test drop-in paths\n' >&2
    exit 3
}
work="$(mktemp -d /tmp/vpsctl-pubkey-real.XXXXXX)"
user="vpskey$(date +%s)"
created=0
service=ssh.service
init=systemd
if [[ -f /etc/alpine-release && -d /run/openrc ]]; then
    init=openrc
    service=sshd
    rc-service "$service" status
else
    systemctl is-active --quiet "$service" || service=sshd.service
    systemctl is-active --quiet "$service"
fi

reload_ssh() {
    if [[ "$init" == openrc ]]; then rc-service "$service" reload; else systemctl reload "$service"; fi
}

cleanup() {
    local status=$? attempt
    trap - EXIT
    rm -f -- "$managed" "$disabled"
    if ! sshd -t || ! reload_ssh; then
        printf 'FAIL: SSH restoration failed; recovery directory: %s\n' "$work" >&2
        exit 30
    fi
    if [[ -f "$work/before" ]]; then
        sshd -T >"$work/restored" || status=30
        diff -u "$work/before" "$work/restored" || status=30
    fi
    if [[ "$created" == 1 ]]; then
        # PAM/systemd may still be closing the short-lived SSH session.
        [[ "$init" != systemd ]] || loginctl terminate-user "$user" >/dev/null 2>&1 || true
        for ((attempt = 0; attempt < 5; attempt++)); do
            if [[ "$init" == openrc ]]; then
                if deluser --remove-home "$user" >"$work/userdel.log" 2>&1; then break; fi
            elif userdel -r -- "$user" >"$work/userdel.log" 2>&1; then
                break
            fi
            sleep 1
        done
        if getent passwd "$user" >/dev/null; then
            cat "$work/userdel.log" >&2
            status=30
        fi
    fi
    if ((status == 0)); then
        rm -rf -- "$work"
    else
        printf 'Acceptance artifacts retained: %s\n' "$work" >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

sshd -T >"$work/before"
port="$(awk '$1 == "port" {print $2}' "$work/before")"
[[ "$port" =~ ^[0-9]+$ ]] || exit 10
getent passwd "$user" >/dev/null && exit 3
if [[ "$init" == openrc ]]; then
    adduser -D -s /bin/sh "$user"
    created=1
    printf '%s:%s\n' "$user" "$(openssl rand -hex 32)" | chpasswd
else
    useradd -m -s /bin/bash -p "$(openssl passwd -6 "$(openssl rand -hex 32)")" -- "$user"
    created=1
fi
ssh-keygen -q -t ed25519 -N '' -f "$work/key"

# Stage a disabled on-disk baseline without reloading it: existing SSH access
# stays available while the command must replace this effective setting.
printf 'PubkeyAuthentication no\n' >"$disabled"
sshd -t
sshd -T >"$work/disabled"
grep -qx 'pubkeyauthentication no' "$work/disabled"
ln -s key.pub "$work/key-link.pub"
bash "$TEST_ROOT/bin/vpsctl" --no-color --dry-run security access key add --user "$user" --public-key-file "$work/key-link.pub"
[[ ! -e "$managed" && ! -e "/home/$user/.ssh/authorized_keys" ]]
bash "$TEST_ROOT/bin/vpsctl" --no-color security access key add --user "$user" --public-key-file "$work/key-link.pub"
sshd -T >"$work/after"
grep -qx 'pubkeyauthentication yes' "$work/after"
diff -u <(sed '/^pubkeyauthentication /d' "$work/disabled") <(sed '/^pubkeyauthentication /d' "$work/after")
timeout 15 ssh -i "$work/key" -p "$port" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@127.0.0.1" true
[[ "$(stat -c %a "/home/$user/.ssh")" == 700 && "$(stat -c %a "/home/$user/.ssh/authorized_keys")" == 600 ]]
[[ "$(stat -c %u:%g "/home/$user/.ssh/authorized_keys")" == "$(id -u "$user"):$(id -g "$user")" ]]

sha256sum "$managed" "/home/$user/.ssh/authorized_keys" >"$work/first"
bash "$TEST_ROOT/bin/vpsctl" --no-color security access key add --user "$user" --public-key-file "$work/key.pub"
sha256sum "$managed" "/home/$user/.ssh/authorized_keys" >"$work/second"
diff -u "$work/first" "$work/second"
output="$(bash "$TEST_ROOT/bin/vpsctl" --no-color --yes security access ssh apply --password-login deny)"
backup="$(grep -Eo 'bak-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}' <<<"$output" | tail -n 1)"
[[ -n "$backup" ]]
sshd -T >"$work/key-only"
grep -qx 'passwordauthentication no' "$work/key-only"
grep -qx 'kbdinteractiveauthentication no' "$work/key-only"
timeout 15 ssh -i "$work/key" -p "$port" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@127.0.0.1" true
printf -v command 'bash %q --no-color security access restore --backup %q' "$TEST_ROOT/bin/vpsctl" "$backup"
printf '%s\n' "$backup" | script -q -e -c "$command" /dev/null
sshd -T >"$work/policy-restored"
diff -u "$work/after" "$work/policy-restored"
# Force the real ssh-keygen to request its empty test passphrase through askpass,
# leaving the TTY input for the product's explicit save/cancel confirmation.
printf '#!/bin/sh\nprintf "\\n"\n' >"$work/askpass"
chmod 0700 "$work/askpass"
printf -v command 'env SSH_ASKPASS_REQUIRE=force SSH_ASKPASS=%q DISPLAY=:999 bash %q --no-color security access key generate --user %q' \
    "$work/askpass" "$TEST_ROOT/bin/vpsctl" "$user"
# Keep the private-key terminal output out of the acceptance log. Use the
# displayed key for a real login, then remove it with the other test secrets.
output="$(printf 'SAVED\n' | timeout 30 script -q -e -c "$command" /dev/null)"
sed -n '/-----BEGIN OPENSSH PRIVATE KEY-----/,/-----END OPENSSH PRIVATE KEY-----/p' <<<"$output" | tr -d '\r' >"$work/generated-key"
chmod 0600 "$work/generated-key"
ssh-keygen -y -f "$work/generated-key" >/dev/null
timeout 15 ssh -i "$work/generated-key" -p "$port" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@127.0.0.1" true
sha256sum "/home/$user/.ssh/authorized_keys" >"$work/generated"
status=0
output="$(printf 'CANCEL\n' | timeout 30 script -q -e -c "$command" /dev/null)" || status=$?
[[ "$status" == 130 ]]
sha256sum "/home/$user/.ssh/authorized_keys" >"$work/cancelled"
diff -u "$work/generated" "$work/cancelled"
printf 'PASS: %s pubkey dry-run, permissions, real imported/generated key login, cancellation, idempotence, password deny and policy restore\n' "$init"
