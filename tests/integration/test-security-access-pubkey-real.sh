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
systemctl is-active --quiet "$service" || service=sshd.service
systemctl is-active --quiet "$service"

cleanup() {
    local status=$? attempt
    trap - EXIT
    rm -f -- "$managed" "$disabled"
    if ! sshd -t || ! systemctl reload "$service"; then
        printf 'FAIL: SSH restoration failed; recovery directory: %s\n' "$work" >&2
        exit 30
    fi
    if [[ -f "$work/before" ]]; then
        sshd -T >"$work/restored" || status=30
        diff -u "$work/before" "$work/restored" || status=30
    fi
    if [[ "$created" == 1 ]]; then
        # PAM/systemd may still be closing the short-lived SSH session.
        loginctl terminate-user "$user" >/dev/null 2>&1 || true
        for ((attempt = 0; attempt < 5; attempt++)); do
            if userdel -r -- "$user" >"$work/userdel.log" 2>&1; then break; fi
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
useradd -m -s /bin/bash -p "$(openssl passwd -6 "$(openssl rand -hex 32)")" -- "$user"
created=1
ssh-keygen -q -t ed25519 -N '' -f "$work/key"

# Stage a disabled on-disk baseline without reloading it: existing SSH access
# stays available while the command must replace this effective setting.
printf 'PubkeyAuthentication no\n' >"$disabled"
sshd -t
sshd -T >"$work/disabled"
grep -qx 'pubkeyauthentication no' "$work/disabled"
ln -s key.pub "$work/key-link.pub"
bash "$TEST_ROOT/bin/vpsctl" --no-color security access key add --user "$user" --public-key-file "$work/key-link.pub"
sshd -T >"$work/after"
grep -qx 'pubkeyauthentication yes' "$work/after"
diff -u <(sed '/^pubkeyauthentication /d' "$work/disabled") <(sed '/^pubkeyauthentication /d' "$work/after")
timeout 15 ssh -i "$work/key" -p "$port" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$user@127.0.0.1" true

sha256sum "$managed" "/home/$user/.ssh/authorized_keys" >"$work/first"
bash "$TEST_ROOT/bin/vpsctl" --no-color security access key add --user "$user" --public-key-file "$work/key.pub"
sha256sum "$managed" "/home/$user/.ssh/authorized_keys" >"$work/second"
diff -u "$work/first" "$work/second"
printf 'PASS: linked public key installation enables pubkey authentication, preserves policy, permits login, and is idempotent\n'
