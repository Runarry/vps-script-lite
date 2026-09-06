#!/usr/bin/env bash
# Opt-in destructive acceptance on the dedicated host-vps-scripts machine.
# Run there with VPSCTL_REAL_ACCESS_POLICY_TEST=1. No existing password is changed:
# a temporary UID 0 alias exercises OpenSSH's root password policy, while the
# actual root account exercises public-key login. The original 15-minute timer
# is checked, then accelerated by a test-only runtime drop-in to fire after 3s.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT

[[ "${VPSCTL_REAL_ACCESS_POLICY_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_ACCESS_POLICY_TEST=1 on the dedicated host\n'
    exit 0
}
[[ "$EUID" == 0 ]] || {
    printf 'FAIL: real policy acceptance requires root\n' >&2
    exit 4
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 30
}
vps() { bash "$TEST_ROOT/bin/vpsctl" --no-color "$@"; }
kv() { awk -F '\t' -v key="$2" '$1 == key {print $2; exit}' "$1"; }

for tool in ssh sshd ssh-keygen setsid script systemctl systemd-run openssl chpasswd useradd userdel timeout; do
    command -v "$tool" >/dev/null || fail "required tool is missing: $tool"
done
state_root=/var/lib/vpsctl/security/access
backup_root=/var/lib/vpsctl/backups/security/access
managed=/etc/ssh/sshd_config.d/00-vpsctl-access.conf
fixture=/etc/ssh/sshd_config.d/01-vpsctl-policy-test.conf
key_fixture=/etc/ssh/vpsctl-policy-test.keys
[[ ! -e "$state_root/active" && ! -L "$state_root/active" ]] || fail 'an access transaction is already active'
[[ ! -e "$fixture" && ! -L "$fixture" && ! -e "$key_fixture" && ! -L "$key_fixture" ]] || fail 'fixture paths are already occupied'
[[ ! -L "$managed" && ! -L /etc/ssh/sshd_config.d ]] || fail 'SSH config paths must not be symlinks'
service=ssh.service
systemctl is-active --quiet "$service" || service=sshd.service
systemctl is-active --quiet "$service" || fail 'sshd service is not active'
if systemctl is-active --quiet ssh.socket; then fail 'socket-activated SSH is not supported by this acceptance'; fi

work="$(mktemp -d /tmp/vpsctl-policy-real.XXXXXX)"
user="vpspol$(date +%s)$$"
root_alias="${user}r"
user_created=0
alias_created=0
saved=0
tx_id=''
backup_id=''
declare -a transactions=()
shopt -s nullglob
configs=(/etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf)

config_hashes() {
    local file
    for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        sha256sum -- "$file"
        stat -c '%n %u:%g:%a' -- "$file"
    done
}

firewall_snapshot() {
    if command -v nft >/dev/null; then nft -s list ruleset; fi
    if command -v iptables-save >/dev/null; then
        iptables-save | sed -E '/^#/d;s/\[[0-9]+:[0-9]+\]/[0:0]/g'
    fi
    if command -v ip6tables-save >/dev/null; then
        ip6tables-save | sed -E '/^#/d;s/\[[0-9]+:[0-9]+\]/[0:0]/g'
    fi
}

timer_snapshot() {
    systemctl list-units --all --type=timer --no-legend --no-pager 'vpsctl-access-*' |
        awk '{print $1}' | sort
}

transaction_snapshot() {
    if [[ -d "$state_root/transactions" ]]; then
        find "$state_root/transactions" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
    fi
}

listener_snapshot() {
    ss -H -ltnp | awk '/"sshd"/ {print $4}' | sort
}

cleanup() {
    local status=$? file tx attempt failed=0 active=''
    trap - EXIT HUP INT TERM
    set +e
    if [[ -f "$state_root/active" ]]; then IFS= read -r active <"$state_root/active"; fi
    if [[ -n "$active" && "$active" == "$tx_id" ]]; then
        vps --quiet security access ssh abort --transaction "$active" >"$work/cleanup-abort.log" 2>&1 || failed=1
    fi
    for tx in "${transactions[@]}"; do
        systemctl stop "vpsctl-access-$tx.timer" "vpsctl-access-$tx.service" >/dev/null 2>&1
        rm -f -- "/run/systemd/system/vpsctl-access-$tx.timer.d/acceptance.conf"
        rmdir -- "/run/systemd/system/vpsctl-access-$tx.timer.d" >/dev/null 2>&1
        systemctl reset-failed "vpsctl-access-$tx.service" >/dev/null 2>&1
    done
    if ((${#transactions[@]})); then systemctl daemon-reload || failed=1; fi
    if [[ "$saved" == 1 ]]; then
        rm -f -- "$fixture" "$key_fixture"
        [[ -f "$work/original/sshd_config.d/00-vpsctl-access.conf" ]] || rm -f -- "$managed"
        cp -a -- "$work/original/." /etc/ssh/ || failed=1
        if ! sshd -t || ! systemctl reload "$service"; then failed=1; fi
        config_hashes >"$work/configs.restored"
        cmp -s "$work/configs.original" "$work/configs.restored" || failed=1
        sshd -T >"$work/effective.restored"
        cmp -s "$work/effective.original" "$work/effective.restored" || failed=1
        listener_snapshot >"$work/listeners.restored"
        cmp -s "$work/listeners.original" "$work/listeners.restored" || failed=1
        firewall_snapshot >"$work/firewall.restored" 2>"$work/firewall-restore.log" || failed=1
        cmp -s "$work/firewall.original" "$work/firewall.restored" || failed=1
        if [[ -f "$work/firewall.state" ]]; then
            cp -a -- "$work/firewall.state" "$state_root/firewall.state" || failed=1
        else
            rm -f -- "$state_root/firewall.state"
        fi
    fi
    # Never terminate UID 0 processes or remove the alias home recursively.
    if [[ "$alias_created" == 1 ]]; then
        userdel --force -- "$root_alias" >"$work/alias-cleanup.log" 2>&1 || failed=1
        getent passwd "$root_alias" >/dev/null && failed=1
    fi
    if [[ "$user_created" == 1 ]]; then
        loginctl terminate-user "$user" >/dev/null 2>&1
        for ((attempt = 0; attempt < 5; attempt++)); do
            userdel -r -- "$user" >"$work/user-cleanup.log" 2>&1 && break
            sleep 1
        done
        getent passwd "$user" >/dev/null && failed=1
    fi
    getent shadow root | sha256sum >"$work/root-shadow.restored"
    cmp -s "$work/root-shadow.original" "$work/root-shadow.restored" || failed=1
    timer_snapshot >"$work/timers.restored"
    cmp -s "$work/timers.original" "$work/timers.restored" || failed=1
    [[ ! -e "$state_root/active" ]] || failed=1
    if ((failed)); then
        printf 'FAIL: host restoration checks failed; private recovery files: %s\n' "$work" >&2
        exit 30
    fi
    printf 'PASS: original SSH files, effective settings, listeners, firewall, root password and timers restored; temporary accounts removed\n'
    if ((status == 0)); then
        [[ "$work" == /tmp/vpsctl-policy-real.* && -d "$work" && ! -L "$work" ]] && rm -rf -- "$work"
    else
        printf 'Private acceptance artifacts retained: %s\n' "$work" >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

sshd -t
sshd -T >"$work/effective.original"
config_hashes >"$work/configs.original"
listener_snapshot >"$work/listeners.original"
firewall_snapshot >"$work/firewall.original" 2>"$work/firewall.log"
timer_snapshot >"$work/timers.original"
[[ ! -s "$work/timers.original" ]] || fail 'an access rollback timer already exists'
getent shadow root | sha256sum >"$work/root-shadow.original"
[[ ! -f "$state_root/firewall.state" ]] || cp -a -- "$state_root/firewall.state" "$work/firewall.state"
mkdir -p "$work/original/sshd_config.d"
for file in "${configs[@]}"; do
    [[ -f "$file" && ! -L "$file" ]] || fail 'SSH configs must be regular files'
    cp -a -- "$file" "$work/original/${file#/etc/ssh/}"
done
saved=1
port="$(awk '$1 == "port" {print $2}' "$work/effective.original")"
[[ "$port" =~ ^[0-9]+$ ]] || fail 'acceptance requires exactly one SSH port'
candidate_port="${VPSCTL_REAL_ACCESS_POLICY_PORT:-22224}"
[[ "$candidate_port" =~ ^[0-9]+$ && "$candidate_port" -ge 1 && "$candidate_port" -le 65535 && "$candidate_port" != "$port" ]] || fail 'invalid candidate port'
[[ -z "$(ss -H -ltn "( sport = :$candidate_port )")" ]] || fail 'candidate port is occupied'
getent passwd "$user" >/dev/null && fail 'temporary account already exists'
getent passwd "$root_alias" >/dev/null && fail 'temporary UID 0 alias already exists'

ssh-keygen -q -t ed25519 -N '' -f "$work/key"
openssl rand -hex 24 >"$work/password"
useradd -m -U -s /bin/bash -- "$user"
user_created=1
user_uid="$(id -u "$user")"
[[ "$user_uid" -gt 0 ]] || fail 'temporary user must not have UID 0'
mkdir "$work/root-home"
useradd -o -u 0 -g 0 -M -d "$work/root-home" -s /bin/bash -- "$root_alias" >"$work/alias-create.log" 2>&1
alias_created=1
printf '%s:%s\n%s:%s\n' "$user" "$(cat "$work/password")" "$root_alias" "$(cat "$work/password")" | chpasswd
install -m 0644 -- "$work/key.pub" "$key_fixture"
authorized_keys="$(awk '$1 == "authorizedkeysfile" {$1=""; sub(/^ /, ""); print}' "$work/effective.original")"
printf 'AuthorizedKeysFile %s %s\nPubkeyAuthentication yes\n' "$authorized_keys" "$key_fixture" >"$fixture"
chmod 0644 "$fixture"
sshd -t
systemctl reload "$service"
cat >"$work/askpass" <<'ASKPASS'
#!/usr/bin/env bash
cat -- "$VPSCTL_ACCEPTANCE_PASSWORD_FILE"
ASKPASS
chmod 0700 "$work/askpass"

ssh_options=(-F /dev/null -n -T -o ConnectTimeout=5 -o ConnectionAttempts=1
    -o StrictHostKeyChecking=no -o "UserKnownHostsFile=$work/known_hosts"
    -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o IdentityAgent=none
    -o ControlMaster=no -o ControlPath=none -o IdentitiesOnly=yes)

key_ssh() {
    local login="$1" target_port="$2"
    shift 2
    timeout 15 ssh "${ssh_options[@]}" -i "$work/key" -p "$target_port" \
        -o BatchMode=yes -o PreferredAuthentications=publickey "$login@127.0.0.1" "$@"
}

password_ssh() {
    local login="$1" target_port="$2"
    shift 2
    DISPLAY=:0 SSH_ASKPASS="$work/askpass" SSH_ASKPASS_REQUIRE=force \
        VPSCTL_ACCEPTANCE_PASSWORD_FILE="$work/password" timeout 15 setsid -w \
        ssh "${ssh_options[@]}" -p "$target_port" -o BatchMode=no \
        -o PubkeyAuthentication=no -o KbdInteractiveAuthentication=no \
        -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 "$login@127.0.0.1" "$@"
}

login_expect() {
    local method="$1" login="$2" expected="$3" uid="$4" rc=0
    "${method}_ssh" "$login" "$port" id -u >"$work/login.out" 2>"$work/login.err" || rc=$?
    if [[ "$expected" == allow ]]; then
        [[ "$rc" == 0 && "$(cat "$work/login.out")" == "$uid" ]] || fail "$method login should succeed for $login"
    else
        if [[ "$rc" != 255 ]] || ! grep -q 'Permission denied' "$work/login.err"; then
            fail "$method login was not rejected by authentication for $login"
        fi
    fi
}

matrix() {
    local root_mode="$1" password_mode="$2" root_password=deny
    [[ "$root_mode:$password_mode" != allow:allow ]] || root_password=allow
    login_expect key root "$root_mode" 0
    login_expect key "$user" allow "$user_uid"
    login_expect password "$root_alias" "$root_password" 0
    login_expect password "$user" "$password_mode" "$user_uid"
    printf 'PASS: real login matrix root=%s password=%s (root password via temporary UID 0 alias)\n' "$root_mode" "$password_mode"
}

unchanged_policy_resources() {
    local file
    listener_snapshot >"$work/listeners.policy"
    cmp -s "$work/listeners.original" "$work/listeners.policy" || fail 'policy changed SSH listeners'
    firewall_snapshot >"$work/firewall.policy" 2>"$work/firewall-policy.log"
    cmp -s "$work/firewall.original" "$work/firewall.policy" || fail 'policy changed firewall rules'
    if [[ -f "$work/firewall.state" ]]; then
        cmp -s "$work/firewall.state" "$state_root/firewall.state" || fail 'policy changed firewall metadata'
    else
        [[ ! -e "$state_root/firewall.state" ]] || fail 'policy created firewall metadata'
    fi
    timer_snapshot >"$work/timers.policy"
    cmp -s "$work/timers.original" "$work/timers.policy" || fail 'policy created a rollback timer'
    transaction_snapshot >"$work/transactions.policy"
    cmp -s "$work/transactions.before-policy" "$work/transactions.policy" || fail 'policy created a transaction'
    [[ ! -e "$state_root/active" ]] || fail 'policy created an active transaction'
    for file in "${configs[@]}"; do
        [[ "$file" == "$managed" ]] || cmp -s "$file" "$work/original/${file#/etc/ssh/}" || fail 'policy edited an unmanaged SSH file'
    done
}

read_policy_backup() {
    backup_id="$(tr -d '\r' <"$work/apply.log" | grep -E '^bak-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$' | tail -n 1)"
    [[ -n "$backup_id" ]] || fail 'apply did not return a backup ID'
    local manifest="$backup_root/$backup_id/manifest"
    [[ "$(kv "$manifest" kind)" == ssh-policy && "$(kv "$manifest" lifecycle)" == committed ]] || fail 'invalid policy backup metadata'
    [[ "$(kv "$manifest" port_file_count)" == 0 && -z "$(kv "$manifest" transaction_id)" ]] || fail 'policy backup owns port files or a transaction'
    [[ ! -e "$backup_root/$backup_id/firewall.state" ]] || fail 'policy backup captured firewall state'
    unchanged_policy_resources
}

apply_policy() {
    vps --quiet --yes security access ssh apply "$@" >"$work/apply.log" 2>&1 || fail 'direct policy apply failed'
    read_policy_backup
}

tty_command() {
    local reply="$1" command
    shift
    printf -v command '%q ' bash "$TEST_ROOT/bin/vpsctl" --no-color "$@"
    printf '%s\n' "$reply" | timeout 25 script -q -e -c "$command" /dev/null
}

restore_backup() {
    local id="$1"
    tty_command "$id" security access restore --backup "$id" >"$work/restore.log" 2>&1 || fail 'TTY backup restore failed'
    [[ "$(kv "$backup_root/$id/manifest" lifecycle)" == restored ]] || fail 'restore lifecycle was not recorded'
}

transaction_snapshot >"$work/transactions.before-policy"
apply_policy --root-login allow --password-login allow
setup_backup="$backup_id"
matrix allow allow
sshd -T >"$work/policy.baseline"
config_hashes >"$work/configs.baseline"

apply_policy --root-login deny
root_backup="$backup_id"
matrix deny allow
restore_backup "$root_backup"
sshd -T >"$work/policy.restored"
cmp -s "$work/policy.baseline" "$work/policy.restored" || fail 'root policy restore did not restore effective config'

apply_policy --password-login deny
password_backup="$backup_id"
matrix allow deny
restore_backup "$password_backup"

apply_policy --root-login deny --password-login deny
denied_backup="$backup_id"
matrix deny deny
# A single TTY reply confirms both policy changes in one command.
tty_command y security access ssh apply --root-login allow --password-login allow >"$work/apply.log" 2>&1 || fail 'one-confirmation TTY policy apply failed'
read_policy_backup
allowed_backup="$backup_id"
matrix allow allow
rc=0
vps --yes security access restore --backup "$allowed_backup" >"$work/restore-no-tty.log" 2>&1 || rc=$?
[[ "$rc" == 3 ]] || fail 'restore accepted --yes without TTY token confirmation'
restore_backup "$allowed_backup"
matrix deny deny
restore_backup "$denied_backup"
unchanged_policy_resources
config_hashes >"$work/configs.after-policy"
cmp -s "$work/configs.baseline" "$work/configs.after-policy" || fail 'policy restores did not restore SSH files'
printf 'PASS: direct apply, single TTY confirmation, protected TTY restore, unchanged ports/firewall and no policy transactions/timers\n'

port_listening() { ss -H -ltnp "( sport = :$1 )" | grep -q '"sshd"'; }

prepare_port() {
    vps --quiet security access ssh prepare --port "$candidate_port" --firewall manual >"$work/prepare.log" 2>&1 || fail 'port prepare failed'
    tx_id="$(grep -E '^tx-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$' "$work/prepare.log" | tail -n 1)"
    [[ -n "$tx_id" ]] || fail 'prepare did not return a transaction ID'
    transactions+=("$tx_id")
    local state="$state_root/transactions/$tx_id/state" created expires
    [[ "$(cat "$state_root/active")" == "$tx_id" && "$(kv "$state" status)" == prepared ]] || fail 'prepare state is invalid'
    created="$(kv "$state" created_epoch)"
    expires="$(kv "$state" expires_epoch)"
    ((expires - created == 900)) || fail 'transaction deadline is not 15 minutes'
    systemctl is-active --quiet "vpsctl-access-$tx_id.timer" || fail 'prepare did not start a rollback timer'
    systemctl show "vpsctl-access-$tx_id.timer" -p TimersMonotonic --value >"$work/timer.original"
    grep -q 'OnActiveUSec=15min' "$work/timer.original" || fail 'rollback timer is not scheduled for 15 minutes'
    if ! port_listening "$port" || ! port_listening "$candidate_port"; then fail 'prepare did not preserve both ports'; fi
}

transaction_restored() {
    config_hashes >"$work/configs.after-transaction"
    cmp -s "$work/configs.baseline" "$work/configs.after-transaction" || fail 'transaction failed to restore SSH config bytes'
    port_listening "$port" || fail 'original SSH port was not restored'
    if port_listening "$candidate_port"; then fail 'candidate port remains open after restore'; fi
    [[ ! -e "$state_root/active" ]] || fail 'transaction left active state'
    if systemctl is-active --quiet "vpsctl-access-$tx_id.timer"; then fail 'transaction left rollback timer active'; fi
    key_ssh root "$port" true >"$work/restored-login.log" 2>&1 || fail 'root key login failed after port restoration'
}

prepare_port
key_ssh root "$candidate_port" bash "$TEST_ROOT/bin/vpsctl" --no-color security access session verify --transaction "$tx_id" >"$work/verify.log" 2>&1 || fail 'real second-session verification failed'
proof="$state_root/transactions/$tx_id/proofs/proof.0"
[[ -f "$proof" && ! -L "$proof" && "$(stat -c %u:%a "$proof")" == 0:600 && "$(kv "$proof" auth_method)" == publickey ]] || fail 'second-session proof is invalid'
vps --quiet security access ssh commit --transaction "$tx_id" --confirm-apply "$tx_id" >"$work/commit.log" 2>&1 || fail 'port commit failed'
port_backup="$(kv "$state_root/transactions/$tx_id/state" backup_id)"
[[ "$(kv "$state_root/transactions/$tx_id/state" status)" == committed && ! -e "$state_root/active" ]] || fail 'commit state is invalid'
if port_listening "$port"; then fail 'commit left original port open'; fi
key_ssh root "$candidate_port" true >"$work/committed-login.log" 2>&1 || fail 'committed candidate port is not usable'
restore_backup "$port_backup"
transaction_restored
printf 'PASS: real dual-port prepare, new-session proof, commit and TTY port restore\n'

prepare_port
vps --quiet security access ssh abort --transaction "$tx_id" >"$work/abort.log" 2>&1 || fail 'port abort failed'
[[ "$(kv "$state_root/transactions/$tx_id/state" status)" == aborted ]] || fail 'abort state was not recorded'
transaction_restored
printf 'PASS: real port transaction abort\n'

prepare_port
timer_override="/run/systemd/system/vpsctl-access-$tx_id.timer.d"
mkdir -p -- "$timer_override"
printf '[Timer]\nOnActiveSec=\nOnActiveSec=3s\nAccuracySec=1ms\n' >"$timer_override/acceptance.conf"
systemctl daemon-reload
systemctl restart "vpsctl-access-$tx_id.timer"
for ((attempt = 0; attempt < 30; attempt++)); do
    [[ "$(kv "$state_root/transactions/$tx_id/state" status)" != aborted ]] || break
    sleep 1
done
[[ "$(kv "$state_root/transactions/$tx_id/state" status)" == aborted ]] || fail 'real systemd timeout did not abort the transaction'
transaction_restored
printf 'PASS: original 900-second deadline and 15-minute timer checked; original systemd rollback service fired via a test-only 3-second timer override\n'

restore_backup "$setup_backup"
printf 'PASS: real SSH policy and port-transaction acceptance\n'
