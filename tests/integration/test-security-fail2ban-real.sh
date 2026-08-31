#!/usr/bin/env bash
# Opt-in destructive acceptance for the dedicated host-vps-scripts machine.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT

[[ "${VPSCTL_REAL_FAIL2BAN_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_FAIL2BAN_TEST=1 on the dedicated host\n'
    exit 0
}
[[ "${EUID:-$(id -u)}" == 0 ]] || {
    printf 'FAIL: real Fail2ban acceptance requires root\n' >&2
    exit 4
}

for tool in bash fail2ban-client ip ssh ssh-keygen sshd systemctl timeout; do
    command -v "$tool" >/dev/null 2>&1 || {
        # fail2ban-client is intentionally absent before the install action.
        [[ "$tool" == fail2ban-client ]] && continue
        printf 'FAIL: required acceptance tool is missing: %s\n' "$tool" >&2
        exit 3
    }
done

managed='/etc/fail2ban/jail.d/99-vpsctl-sshd.local'
test_ip='198.18.0.2'
host_ip='198.18.0.1'
suffix="${BASHPID:-$$}"
namespace="vpsf2b-${suffix}"
host_link="f2bh${suffix}"
peer_link="f2bn${suffix}"
temp_dir="$(mktemp -d)"
key_file="$temp_dir/probe-key"
installed=0

[[ ${#host_link} -le 15 && ${#peer_link} -le 15 ]] || {
    printf 'FAIL: generated veth name is too long\n' >&2
    exit 70
}
[[ ! -e "$managed" ]] || {
    printf 'FAIL: real acceptance requires no active vpsctl Fail2ban jail\n' >&2
    exit 3
}

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM

    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client set sshd unbanip "$test_ip" >/dev/null 2>&1 || true
    fi
    ip netns del "$namespace" >/dev/null 2>&1 || true
    ip link del "$host_link" >/dev/null 2>&1 || true

    if ((installed == 1)) && [[ -e "$managed" ]]; then
        bash "$TEST_ROOT/bin/vpsctl" --no-color security fail2ban uninstall \
            --confirm-uninstall REMOVE-VPSCTL-FAIL2BAN >/dev/null 2>&1 || true
    fi
    if [[ -f "$managed" ]] && grep -Fqx '# Managed by vpsctl security fail2ban.' "$managed"; then
        rm -f -- "$managed"
        fail2ban-client -t >/dev/null 2>&1 || true
        fail2ban-client reload >/dev/null 2>&1 || true
    fi
    rm -rf -- "$temp_dir"

    if ((status != 0)); then
        printf 'RECOVERY: Fail2ban package/service are intentionally retained; inspect systemctl status fail2ban and /var/lib/fail2ban before reuse.\n' >&2
    fi
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

bash "$TEST_ROOT/bin/vpsctl" --no-color security fail2ban install --adopt-existing
installed=1

fail2ban-client -t
fail2ban-client ping | grep -Fq 'pong'
fail2ban-client status sshd
systemctl is-enabled --quiet fail2ban.service
systemctl is-active --quiet fail2ban.service
bash "$TEST_ROOT/bin/vpsctl" --no-color security fail2ban status --json |
    grep -Eq '"schema_version"[[:space:]]*:[[:space:]]*1'

port="$(sshd -T | awk '$1 == "port" {print $2; exit}')"
[[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || {
    printf 'FAIL: could not resolve an effective SSH port\n' >&2
    exit 10
}

ip netns add "$namespace"
ip link add "$host_link" type veth peer name "$peer_link"
ip link set "$peer_link" netns "$namespace"
ip addr add "${host_ip}/30" dev "$host_link"
ip link set "$host_link" up
ip -n "$namespace" link set lo up
ip -n "$namespace" addr add "${test_ip}/30" dev "$peer_link"
ip -n "$namespace" link set "$peer_link" up

timeout 3 ip netns exec "$namespace" bash -c "exec 3<>/dev/tcp/${host_ip}/${port}" || {
    printf 'FAIL: temporary source cannot reach SSH before Fail2ban test\n' >&2
    exit 3
}

ssh-keygen -q -t ed25519 -N '' -f "$key_file"
for _ in 1 2 3 4 5 6; do
    timeout 5 ip netns exec "$namespace" ssh -F /dev/null \
        -o BatchMode=yes -o ConnectTimeout=2 -o IdentitiesOnly=yes \
        -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -i "$key_file" -p "$port" \
        vpsctl-fail2ban-probe@"$host_ip" true >/dev/null 2>&1 || true
done

banned=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if fail2ban-client get sshd banip 2>/dev/null | tr ' ' '\n' | grep -Fxq "$test_ip"; then
        banned=1
        break
    fi
    sleep 1
done
((banned == 1)) || {
    printf 'FAIL: Fail2ban did not ban the isolated source after repeated failures\n' >&2
    exit 30
}

if timeout 2 ip netns exec "$namespace" bash -c "exec 3<>/dev/tcp/${host_ip}/${port}"; then
    printf '%s\n' '--- Fail2ban action diagnostics ---' >&2
    fail2ban-client get sshd actions >&2 || true
    if command -v nft >/dev/null 2>&1; then nft -a list ruleset >&2 || true; fi
    if command -v iptables-save >/dev/null 2>&1; then iptables-save >&2 || true; fi
    printf 'FAIL: banned source can still open the SSH TCP port\n' >&2
    exit 30
fi

bash "$TEST_ROOT/bin/vpsctl" --no-color security fail2ban unban --ip "$test_ip"
fail2ban-client get sshd banip 2>/dev/null | tr ' ' '\n' | grep -Fxq "$test_ip" && {
    printf 'FAIL: public unban action retained the test address\n' >&2
    exit 30
}
timeout 3 ip netns exec "$namespace" bash -c "exec 3<>/dev/tcp/${host_ip}/${port}"

bash "$TEST_ROOT/bin/vpsctl" --no-color security fail2ban verify
bash "$TEST_ROOT/bin/vpsctl" --no-color security fail2ban uninstall \
    --confirm-uninstall REMOVE-VPSCTL-FAIL2BAN
[[ ! -e "$managed" ]] || {
    printf 'FAIL: uninstall retained the vpsctl-managed jail\n' >&2
    exit 30
}
command -v fail2ban-client >/dev/null 2>&1
systemctl is-enabled --quiet fail2ban.service
systemctl is-active --quiet fail2ban.service

printf 'PASS: real Fail2ban SSH failures, ban, unblock, verify and managed-only uninstall\n'
printf 'RECOVERY: the Fail2ban package and active service remain installed by design; no vpsctl jail remains.\n'
