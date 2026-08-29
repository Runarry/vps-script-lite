#!/usr/bin/env bash
# The access command is exercised through its public CLI with a synthetic
# system root and command mocks. TTY-only branches use util-linux script when
# it is available on the integration host.
# shellcheck disable=SC2317

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
TEST_TEMP="$(mktemp -d)"
readonly TEST_TEMP
TEST_SYSTEM_ROOT="${TEST_TEMP}/system"
MOCK_BIN="${TEST_TEMP}/bin"
readonly TEST_SYSTEM_ROOT MOCK_BIN
trap 'rm -rf -- "$TEST_TEMP"' EXIT

mkdir -p -- "$TEST_SYSTEM_ROOT" "$MOCK_BIN"

make_mock() {
    local name="$1"
    shift
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        printf '%s\n' "$@"
    } >"${MOCK_BIN}/${name}"
    chmod 0755 -- "${MOCK_BIN}/${name}"
}

make_mock systemctl '
case "${1:-}" in
    is-active) exit 0 ;;
    is-enabled)
        [[ " $* " == *" nftables.service " && -e "${VPSCTL_SYSTEM_ROOT}/run/nft-persistent" ]] ||
            [[ " $* " == *" netfilter-persistent.service " && -e "${VPSCTL_SYSTEM_ROOT}/run/iptables-persistent" ]]
        ;;
    reload)
        printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/systemctl.log"
        if [[ -e "${VPSCTL_SYSTEM_ROOT}/run/fail-reload-once" ]]; then
            rm -f -- "${VPSCTL_SYSTEM_ROOT}/run/fail-reload-once"
            exit 1
        fi
        ;;
    *) exit 0 ;;
esac'

make_mock systemd-run '
printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/systemd-run.log"'

make_mock getent '
case "${1:-}:${2:-}" in
    passwd:root) printf "root:x:0:0:root:/root:/bin/bash\n" ;;
    passwd:alice) printf "alice:x:1001:1001:Alice:/home/alice:/bin/bash\n" ;;
    passwd:daemon) printf "daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n" ;;
    group:sudo) printf "sudo:x:27:alice\n" ;;
    group:wheel) printf "wheel:x:10:alice\n" ;;
    *) exit 2 ;;
esac'

make_mock useradd '
printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/useradd.log"'

make_mock passwd '
printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/passwd.log"'

make_mock chown 'exit 0'

make_mock sudo '
case "${1:-}" in
    -v | -l) exit 0 ;;
    install) shift; exec /usr/bin/install "$@" ;;
    rm) shift; exec /usr/bin/rm "$@" ;;
    stat) shift; exec /usr/bin/stat "$@" ;;
    *) exit 0 ;;
esac'

make_mock userdel '
printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/userdel.log"'

make_mock id '
case "${1:-}" in
    -u) printf "1001\n" ;;
    -un) printf "alice\n" ;;
    -nG)
        if [[ "${VPSCTL_ENV_OS_ID:-}" == rocky ]]; then printf "deploy wheel\n"; else printf "deploy sudo\n"; fi
        ;;
    *) exit 2 ;;
esac'

make_mock stat '
target="${!#}"
if [[ "${1:-} ${2:-}" == "-c %u" && "$target" == */*auth-info ]]; then
    printf "1001\n"
    exit 0
fi
if [[ "${1:-} ${2:-}" == "-c %u" && "$target" == */proof.1001 ]]; then
    if [[ -e "${VPSCTL_SYSTEM_ROOT}/run/proof-owner-user" ]]; then printf "1001\n"; else printf "0\n"; fi
    exit 0
fi
exec /usr/bin/stat "$@"'

make_mock ssh-keygen '
if [[ "${1:-}" == -l ]]; then exit 0; fi
key_file=""
while (($# > 0)); do
    if [[ "$1" == -f ]]; then key_file="$2"; shift; fi
    shift
done
[[ -n "$key_file" ]] || exit 2
printf "MOCK-PRIVATE-KEY\n" >"$key_file"
printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGenerated vpsctl-generated\n" >"${key_file}.pub"'

make_mock sshd '
printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/sshd.log"
if [[ " $* " == *" -T "* ]]; then
    managed="${VPSCTL_SYSTEM_ROOT}/etc/ssh/sshd_config.d/00-vpsctl-access.conf"
    if [[ -f "$managed" ]]; then
        awk '\''
            $1 == "Port" {print "port " $2}
            $1 == "PermitRootLogin" {print "permitrootlogin " $2}
            $1 == "PasswordAuthentication" {print "passwordauthentication " $2}
            $1 == "KbdInteractiveAuthentication" {print "kbdinteractiveauthentication " $2}
            $1 == "PubkeyAuthentication" {print "pubkeyauthentication " $2}
            $1 == "ExposeAuthInfo" {print "exposeauthinfo " $2}
        '\'' "$managed"
    else
        cat -- "${VPSCTL_SYSTEM_ROOT}/run/sshd-effective"
    fi
fi
exit 0'

make_mock ss '
[[ "$*" =~ :([0-9]+) ]] || exit 2
port="${BASH_REMATCH[1]}"
managed="${VPSCTL_SYSTEM_ROOT}/etc/ssh/sshd_config.d/00-vpsctl-access.conf"
if [[ -f "$managed" ]]; then
    grep -Eq "^Port[[:space:]]+${port}$" "$managed" || exit 0
elif [[ "$port" != 22 ]]; then
    exit 0
fi
printf "LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:((\\\"sshd\\\",pid=1,fd=3))\n" "$port"'

make_mock nft '
printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/nft.log"
if [[ " $* " == *" list ruleset "* ]]; then
    family=inet
    [[ ! -f "${VPSCTL_SYSTEM_ROOT}/run/nft-family" ]] || family="$(<"${VPSCTL_SYSTEM_ROOT}/run/nft-family")"
    if [[ -e "${VPSCTL_SYSTEM_ROOT}/run/nft-forward-only" ]]; then
        printf "table inet containers {\n    chain forward {\n        type filter hook forward priority filter; policy accept;\n    }\n}\n"
    elif [[ -e "${VPSCTL_SYSTEM_ROOT}/run/nft-input-accept-empty" ]]; then
        printf "table inet netavark {\n    chain INPUT {\n        type filter hook input priority filter; policy accept;\n    }\n}\n"
    elif [[ -e "${VPSCTL_SYSTEM_ROOT}/run/nft-active" ]]; then
        printf "table %s filter {\n    chain input {\n        type filter hook input priority filter; policy drop;\n" "$family"
        if [[ -f "${VPSCTL_SYSTEM_ROOT}/run/nft-vpsctl-ports" ]]; then
            handle=0
            while IFS= read -r port; do handle=$((handle + 1)); [[ -n "$port" ]] && printf "        tcp dport %s accept comment \x22vpsctl-access-%s\x22 # handle %s\n" "$port" "$port" "$handle"; done <"${VPSCTL_SYSTEM_ROOT}/run/nft-vpsctl-ports"
        fi
        [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/nft-user-rule" ]] || printf "        tcp dport 9999 accept comment \x22administrator-rule\x22 # handle 99\n"
        printf "    }\n}\n"
    fi
    exit 0
fi
if [[ "${2:-} ${3:-}" == "list chain" ]]; then
    handle=0
    if [[ -f "${VPSCTL_SYSTEM_ROOT}/run/nft-vpsctl-ports" ]]; then
        while IFS= read -r port; do handle=$((handle + 1)); [[ -n "$port" ]] && printf "tcp dport %s accept comment \x22vpsctl-access-%s\x22 # handle %s\n" "$port" "$port" "$handle"; done <"${VPSCTL_SYSTEM_ROOT}/run/nft-vpsctl-ports"
    fi
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/nft-user-rule" ]] || printf "tcp dport 9999 accept comment \x22administrator-rule\x22 # handle 99\n"
    exit 0
fi
if [[ "${1:-}" == -c && "${2:-}" == -f ]]; then exit 0; fi
if [[ "${1:-}" == -f ]]; then
    awk '"'"'/insert rule/ {for (i=1; i<=NF; i++) if ($i == "dport") print $(i+1)}'"'"' "$2" >"${VPSCTL_SYSTEM_ROOT}/run/nft-vpsctl-ports"
    exit 0
fi
if [[ " $* " == *" delete rule "*" handle "* ]]; then
    handle="${!#}"
    awk -v remove="$handle" '"'"'NR != remove'"'"' "${VPSCTL_SYSTEM_ROOT}/run/nft-vpsctl-ports" >"${VPSCTL_SYSTEM_ROOT}/run/nft-vpsctl-ports.tmp"
    mv -f -- "${VPSCTL_SYSTEM_ROOT}/run/nft-vpsctl-ports.tmp" "${VPSCTL_SYSTEM_ROOT}/run/nft-vpsctl-ports"
    exit 0
fi
exit 0'

make_mock ufw '
if [[ "${1:-}" == status ]]; then
    [[ -e "${VPSCTL_SYSTEM_ROOT}/run/ufw-active" ]] || { printf "Status: inactive\n"; exit 0; }
    printf "Status: active\n"
    number=0
    if [[ -f "${VPSCTL_SYSTEM_ROOT}/run/ufw-vpsctl-port" ]]; then
        port="$(<"${VPSCTL_SYSTEM_ROOT}/run/ufw-vpsctl-port")"
        if [[ "${2:-}" == numbered ]]; then number=$((number + 1)); printf "[ %s] %s/tcp ALLOW IN Anywhere # vpsctl security access\n" "$number" "$port"
        else printf "%s/tcp ALLOW IN Anywhere # vpsctl security access\n" "$port"; fi
    fi
    if [[ -f "${VPSCTL_SYSTEM_ROOT}/run/ufw-user-port" ]]; then
        port="$(<"${VPSCTL_SYSTEM_ROOT}/run/ufw-user-port")"
        if [[ "${2:-}" == numbered ]]; then number=$((number + 1)); printf "[ %s] %s/tcp ALLOW IN Anywhere # administrator rule\n" "$number" "$port"
        else printf "%s/tcp ALLOW IN Anywhere # administrator rule\n" "$port"; fi
    fi
    exit 0
fi
if [[ "${1:-}" == allow ]]; then
    printf "%s\n" "${2%/tcp}" >"${VPSCTL_SYSTEM_ROOT}/run/ufw-vpsctl-port"
    exit 0
fi
if [[ "${1:-} ${2:-}" == "--force delete" ]]; then
    printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/ufw-delete.log"
    if [[ -f "${VPSCTL_SYSTEM_ROOT}/run/ufw-vpsctl-port" && "${3:-}" == 1 ]]; then
        rm -f -- "${VPSCTL_SYSTEM_ROOT}/run/ufw-vpsctl-port"
    else
        : >"${VPSCTL_SYSTEM_ROOT}/run/ufw-user-deleted"
    fi
    exit 0
fi
exit 1'

make_mock firewall-cmd '
if [[ "${1:-}" == --state && -e "${VPSCTL_SYSTEM_ROOT}/run/firewalld-active" ]]; then exit 0; fi
if [[ "${1:-}" == --get-active-zones ]]; then printf "public\n  interfaces: eth0\n"; exit 0; fi
if [[ "${1:-}" == --get-default-zone ]]; then printf "public\n"; exit 0; fi
if [[ "${1:-}" == --get-zones ]]; then printf "public\n"; exit 0; fi
scope=runtime
[[ " $* " != *" --permanent "* ]] || scope=permanent
port_pattern='"'"'port="([0-9]+)"'"'"'
if [[ "$*" =~ $port_pattern ]]; then port="${BASH_REMATCH[1]}"; else port=""; fi
if [[ " $* " == *" --query-rich-rule="* ]]; then
    [[ -n "$port" && -f "${VPSCTL_SYSTEM_ROOT}/run/firewalld-vpsctl-${scope}" && "$(<"${VPSCTL_SYSTEM_ROOT}/run/firewalld-vpsctl-${scope}")" == "$port" ]]
    exit
fi
if [[ " $* " == *" --query-port="* ]]; then
    query="${*#*--query-port=}"; query="${query%% *}"; query="${query%/tcp}"
    [[ -f "${VPSCTL_SYSTEM_ROOT}/run/firewalld-user-${scope}" && "$(<"${VPSCTL_SYSTEM_ROOT}/run/firewalld-user-${scope}")" == "$query" ]]
    exit
fi
if [[ " $* " == *" --add-rich-rule="* ]]; then
    printf "%s\n" "$port" >"${VPSCTL_SYSTEM_ROOT}/run/firewalld-vpsctl-${scope}"
    printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/firewalld.log"
    exit 0
fi
if [[ " $* " == *" --remove-rich-rule="* ]]; then
    rm -f -- "${VPSCTL_SYSTEM_ROOT}/run/firewalld-vpsctl-${scope}"
    printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/firewalld.log"
    exit 0
fi
if [[ " $* " == *" --remove-port="* ]]; then : >"${VPSCTL_SYSTEM_ROOT}/run/firewalld-user-deleted"; exit 0; fi
exit 1'

make_mock iptables '
if [[ "${1:-}" == --version ]]; then printf "iptables v1.8.9 (legacy)\n"; exit 0; fi
if [[ "${1:-}" == -S ]]; then
    printf "%s\n" "-P INPUT ACCEPT" "-P FORWARD ACCEPT" "-P OUTPUT ACCEPT"
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/iptables-active" ]] || printf "%s\n" "-A INPUT -j DROP"
    [[ ! -f "${VPSCTL_SYSTEM_ROOT}/run/iptables-vpsctl-port" ]] || printf "%s\n" "-A INPUT -p tcp --dport $(<"${VPSCTL_SYSTEM_ROOT}/run/iptables-vpsctl-port") -m comment --comment vpsctl-access -j ACCEPT"
    exit 0
fi
if [[ "${1:-}" == -C ]]; then [[ -f "${VPSCTL_SYSTEM_ROOT}/run/iptables-vpsctl-port" && " $* " == *" --dport $(<"${VPSCTL_SYSTEM_ROOT}/run/iptables-vpsctl-port") "* ]]; exit; fi
if [[ "${1:-}" == -I ]]; then for ((i=1; i<=$#; i++)); do [[ "${!i}" != --dport ]] || { j=$((i + 1)); printf "%s\n" "${!j}" >"${VPSCTL_SYSTEM_ROOT}/run/iptables-vpsctl-port"; }; done; exit 0; fi
if [[ "${1:-}" == -D ]]; then rm -f -- "${VPSCTL_SYSTEM_ROOT}/run/iptables-vpsctl-port"; printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/iptables.log"; exit 0; fi
exit 1'

make_mock ip6tables '
if [[ "${1:-}" == -S ]]; then printf "%s\n" "-P INPUT ACCEPT"; exit 0; fi
if [[ "${1:-}" == -C ]]; then [[ -f "${VPSCTL_SYSTEM_ROOT}/run/ip6tables-vpsctl-port" && " $* " == *" --dport $(<"${VPSCTL_SYSTEM_ROOT}/run/ip6tables-vpsctl-port") "* ]]; exit; fi
if [[ "${1:-}" == -I ]]; then for ((i=1; i<=$#; i++)); do [[ "${!i}" != --dport ]] || { j=$((i + 1)); printf "%s\n" "${!j}" >"${VPSCTL_SYSTEM_ROOT}/run/ip6tables-vpsctl-port"; }; done; exit 0; fi
if [[ "${1:-}" == -D ]]; then rm -f -- "${VPSCTL_SYSTEM_ROOT}/run/ip6tables-vpsctl-port"; printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/iptables.log"; exit 0; fi
exit 1'

make_mock netfilter-persistent '
[[ "${1:-}" == save ]] || exit 1
printf "%s\n" "$*" >>"${VPSCTL_SYSTEM_ROOT}/run/netfilter-persistent.log"'

export PATH="${MOCK_BIN}:/usr/sbin:/usr/bin:/sbin:/bin"
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0 VPSCTL_ASSUME_YES=1 VPSCTL_NON_INTERACTIVE=1
export VPSCTL_QUIET=1 VPSCTL_VERBOSE=0 VPSCTL_NO_COLOR=1
export VPSCTL_ENV_OS_ID=ubuntu VPSCTL_ENV_INIT=systemd

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_equal() {
    [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"
}

assert_file_contains() {
    grep -Fq -- "$2" "$1" || fail "$3: missing '$2' in $1"
}

assert_status() {
    local expected="$1" message="$2" output status=0
    shift 2
    output="$("$@" 2>&1)" || status=$?
    [[ "$status" == "$expected" ]] || fail "$message: expected status $expected, got $status; output: $output"
    ACCESS_TEST_OUTPUT="$output"
}

run_access() {
    bash "$TEST_ROOT/commands/security/access.sh" --no-color --non-interactive "$@"
}

reset_system() {
    rm -rf -- "$TEST_SYSTEM_ROOT"
    mkdir -p -- "$TEST_SYSTEM_ROOT/etc/ssh/sshd_config.d" "$TEST_SYSTEM_ROOT/home/alice" "$TEST_SYSTEM_ROOT/run"
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n' >"$TEST_SYSTEM_ROOT/etc/ssh/sshd_config"
    printf 'port 22\npermitrootlogin yes\npasswordauthentication yes\nkbdinteractiveauthentication yes\npubkeyauthentication yes\nexposeauthinfo no\n' \
        >"$TEST_SYSTEM_ROOT/run/sshd-effective"
}

seed_alice_key() {
    mkdir -p -- "$TEST_SYSTEM_ROOT/home/alice/.ssh"
    chmod 0700 -- "$TEST_SYSTEM_ROOT/home/alice/.ssh"
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest alice@example\n' >"$TEST_SYSTEM_ROOT/home/alice/.ssh/authorized_keys"
    chmod 0600 -- "$TEST_SYSTEM_ROOT/home/alice/.ssh/authorized_keys"
}

extract_id() {
    local prefix="$1" value="$2"
    grep -Eo "${prefix}-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}" <<<"$value" | tail -n 1
}

prepare_transaction() {
    local port="$1" output status=0 arg nft_log='' nft_ports=''
    local -a firewall_args=(--firewall manual)
    shift
    for arg in "$@"; do
        [[ "$arg" != --firewall ]] || firewall_args=()
    done
    output="$(run_access ssh prepare --port "$port" "${firewall_args[@]}" "$@" 2>&1)" || status=$?
    [[ ! -f "$TEST_SYSTEM_ROOT/run/nft.log" ]] || nft_log="$(tr '\n' ';' <"$TEST_SYSTEM_ROOT/run/nft.log")"
    [[ ! -f "$TEST_SYSTEM_ROOT/run/nft-vpsctl-ports" ]] || nft_ports="$(tr '\n' ',' <"$TEST_SYSTEM_ROOT/run/nft-vpsctl-ports")"
    [[ "$status" == 0 ]] || fail "prepare transaction on port $port failed with $status: $output nft=$nft_log ports=$nft_ports"
    ACCESS_TEST_TX="$(extract_id tx "$output")"
    [[ -n "$ACCESS_TEST_TX" ]] || fail "prepare output did not contain a transaction ID: $output"
}

verify_transaction() {
    local tx_id="$1" port="$2" auth_file="$TEST_SYSTEM_ROOT/run/auth-info" command
    printf 'publickey ssh-ed25519 SHA256:test\n' >"$auth_file"
    chmod 0600 -- "$auth_file"
    command -v script >/dev/null 2>&1 || fail "session verification tests require util-linux script"
    printf -v command 'env SSH_CONNECTION=%q SSH_TTY=/dev/pts/9 SSH_USER_AUTH=%q bash %q --no-color session verify --transaction %q' \
        "192.0.2.10 43100 192.0.2.20 $port" "$auth_file" "$TEST_ROOT/commands/security/access.sh" "$tx_id"
    assert_status 0 "session verification" script -q -e -c "$command" /dev/null
}

test_cli_validation_and_status() {
    local output

    reset_system
    output="$(run_access status --user alice --json)"
    assert_contains "$output" '"port": "22"' "status port"
    assert_contains "$output" '"listening": true' "status listening"
    assert_contains "$output" '"firewall":' "status firewall"
    assert_contains "$output" '"name": "alice"' "status user"
    assert_contains "$output" '"exists": true' "status existing user"

    assert_status 2 "status rejects unknown option" run_access status --extra
    assert_status 2 "status rejects invalid username" run_access status --user 'Alice!'
    assert_status 2 "user add requires name" run_access user add
    assert_status 2 "user add rejects root" run_access user add --name root
    assert_status 2 "user add rejects invalid name" run_access user add --name 'Bad.User'
    assert_status 2 "password set requires user" run_access password set
    assert_status 3 "password rejects service account" run_access password set --user daemon
    assert_status 2 "key add requires source" run_access key add --user alice
    assert_status 3 "key rejects service account" bash -c \
        'printf "%s\n" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest daemon" | "$@" key add --user daemon --stdin' \
        _ bash "$TEST_ROOT/commands/security/access.sh" --no-color --non-interactive
    assert_status 2 "key add rejects conflicting sources" run_access key add --user alice --stdin --public-key-file /dev/null
    assert_status 2 "prepare requires a policy" run_access ssh prepare
    assert_status 2 "prepare rejects port zero" run_access ssh prepare --port 0
    assert_status 2 "prepare rejects port above range" run_access ssh prepare --port 65536
    assert_status 2 "prepare rejects invalid root policy" run_access ssh prepare --root-login maybe
    assert_status 2 "prepare rejects invalid firewall policy" run_access ssh prepare --firewall nftables
    assert_status 2 "session verify requires transaction" run_access session verify
    assert_status 2 "commit requires explicit confirmation" run_access ssh commit --transaction tx-invalid
    assert_status 2 "restore requires backup" run_access restore

    assert_status 0 "upper boundary port is accepted" run_access --dry-run ssh prepare --port 65535 --firewall manual
}

test_user_password_and_keys() {
    local authorized key_file key_backup manifest lines mode command output status=0 authorized_sha manifest_sha
    local -a key_manifests=()

    reset_system
    assert_status 0 "user add" run_access user add --name deploy
    assert_file_contains "$TEST_SYSTEM_ROOT/run/useradd.log" '-- deploy' "useradd terminates options before username"
    assert_file_contains "$TEST_SYSTEM_ROOT/run/useradd.log" '--groups sudo' "useradd administrator group"
    rm -f -- "$TEST_SYSTEM_ROOT/run/useradd.log"
    assert_status 0 "user add with password dry-run" run_access --dry-run user add --name deploy --set-password
    [[ ! -e "$TEST_SYSTEM_ROOT/run/useradd.log" ]] || fail "user add dry-run invoked useradd"

    assert_status 3 "password set refuses non-TTY" run_access password set --user alice
    [[ ! -e "$TEST_SYSTEM_ROOT/run/passwd.log" ]] || fail "passwd was invoked without a TTY"
    assert_status 0 "password set dry-run does not require a TTY" run_access --dry-run password set --user alice
    if command -v script >/dev/null 2>&1; then
        printf -v command 'bash %q --no-color --non-interactive password set --user alice' "$TEST_ROOT/commands/security/access.sh"
        output="$(script -q -e -c "$command" /dev/null 2>&1)" || status=$?
        [[ "$status" == 0 ]] || fail "TTY password set failed with $status: $output"
        assert_file_contains "$TEST_SYSTEM_ROOT/run/passwd.log" '-- alice' "password target"
    fi

    authorized="$TEST_SYSTEM_ROOT/home/alice/.ssh/authorized_keys"
    status=0
    output="$(printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest first-comment\n' | run_access key add --user alice --stdin 2>&1)" || status=$?
    [[ "$status" == 0 ]] || fail "stdin key add failed with $status: $output"
    key_manifests=("$TEST_SYSTEM_ROOT"/var/lib/vpsctl/backups/security/access/bak-*/manifest)
    ((${#key_manifests[@]} == 1)) && [[ -f "${key_manifests[0]}" ]] || fail "key add did not create exactly one backup manifest"
    manifest="${key_manifests[0]}"
    key_backup="${manifest%/manifest}"
    key_backup="${key_backup##*/}"
    authorized_sha="$(sha256sum "$authorized")"
    manifest_sha="$(sha256sum "$manifest")"
    assert_status 0 "authorized_keys restore dry-run" run_access --dry-run restore --backup "$key_backup"
    assert_equal "$authorized_sha" "$(sha256sum "$authorized")" "authorized_keys dry-run content"
    assert_equal "$manifest_sha" "$(sha256sum "$manifest")" "authorized_keys dry-run manifest"
    status=0
    output="$(printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest changed-comment\n' | run_access key add --user alice --stdin 2>&1)" || status=$?
    [[ "$status" == 0 ]] || fail "duplicate stdin key add failed with $status: $output"
    lines="$(grep -c '^ssh-' "$authorized")"
    assert_equal 1 "$lines" "authorized_keys deduplication"
    mode="$(stat -c %a -- "${authorized%/*}")"
    assert_equal 700 "$mode" ".ssh permissions"
    mode="$(stat -c %a -- "$authorized")"
    assert_equal 600 "$mode" "authorized_keys permissions"

    key_file="$TEST_TEMP/alice-secondary.pub"
    printf 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCsecondary alice-secondary\n' >"$key_file"
    assert_status 0 "public key file add" run_access key add --user alice --public-key-file "$key_file"
    lines="$(grep -c '^ssh-' "$authorized")"
    assert_equal 2 "$lines" "public key file append"
    assert_status 10 "authorized_keys options are rejected" bash -c \
        'printf "%s\n" "from=192.0.2.1 ssh-ed25519 AAAATest" | "$@" key add --user alice --stdin' \
        _ bash "$TEST_ROOT/commands/security/access.sh" --no-color --non-interactive
    assert_status 2 "stdin rejects a blank second line" bash -c \
        'printf "%s\n\n" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIthird" | "$@" key add --user alice --stdin' \
        _ bash "$TEST_ROOT/commands/security/access.sh" --no-color --non-interactive
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIthird first\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIfourth second' >"$key_file"
    assert_status 10 "public key file rejects final unterminated second line" run_access key add --user alice --public-key-file "$key_file"

    assert_status 3 "key generation refuses non-TTY output" run_access key generate --user alice
    assert_status 0 "key generation dry-run does not require TTY output" run_access --dry-run key generate --user alice
    if command -v script >/dev/null 2>&1; then
        status=0
        printf -v command 'bash %q --no-color --non-interactive key generate --user alice' "$TEST_ROOT/commands/security/access.sh"
        output="$(printf 'SAVED\n' | script -q -e -c "$command" /dev/null 2>&1)" || status=$?
        [[ "$status" == 0 ]] || fail "TTY key generation failed with $status: $output"
        assert_contains "$output" 'MOCK-PRIVATE-KEY' "one-time private key output"
    fi
}

test_sshd_shape_and_firewall_rejections() {
    local tx managed state family port

    reset_system
    printf 'Include /etc/ssh/other/*.conf\n' >"$TEST_SYSTEM_ROOT/etc/ssh/sshd_config"
    assert_status 10 "non-standard Include rejection" run_access ssh prepare --port 2222 --firewall manual
    assert_contains "$ACCESS_TEST_OUTPUT" '非标准 Include' "non-standard Include diagnostic"

    reset_system
    printf 'Include /etc/ssh/sshd_config.d/*.conf\nMatch User alice\n    PasswordAuthentication no\n' >"$TEST_SYSTEM_ROOT/etc/ssh/sshd_config"
    assert_status 10 "Match block rejection" run_access ssh prepare --port 2222 --firewall manual
    assert_contains "$ACCESS_TEST_OUTPUT" 'Match' "Match diagnostic"

    reset_system
    printf 'Match User alice\n' >"$TEST_SYSTEM_ROOT/etc/ssh/sshd_config.d/50-complex.conf"
    assert_status 10 "complex drop-in rejection" run_access ssh prepare --port 2222 --firewall manual
    assert_contains "$ACCESS_TEST_OUTPUT" '复杂指令' "complex drop-in diagnostic"

    reset_system
    printf 'port 22\npermitrootlogin prohibit-password\npasswordauthentication yes\nkbdinteractiveauthentication no\npubkeyauthentication yes\nexposeauthinfo no\n' \
        >"$TEST_SYSTEM_ROOT/run/sshd-effective"
    prepare_transaction 2299
    tx="$ACCESS_TEST_TX"
    managed="$TEST_SYSTEM_ROOT/etc/ssh/sshd_config.d/00-vpsctl-access.conf"
    assert_file_contains "$managed" 'PermitRootLogin prohibit-password' "unrequested root policy preservation"
    assert_file_contains "$managed" 'PasswordAuthentication yes' "unrequested password policy preservation"
    assert_file_contains "$managed" 'KbdInteractiveAuthentication no' "unrequested keyboard-interactive policy preservation"
    assert_file_contains "$managed" 'PubkeyAuthentication yes' "unrequested pubkey policy preservation"
    assert_status 0 "abort preservation transaction" run_access ssh abort --transaction "$tx"

    reset_system
    : >"$TEST_SYSTEM_ROOT/run/nft-active"
    assert_contains "$(nft list ruleset)" 'table inet filter' "nftables active backend fixture"
    prepare_transaction 2222 --firewall auto
    tx="$ACCESS_TEST_TX"
    state="$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/transactions/$tx/state"
    assert_file_contains "$state" $'firewall_added\tnft-runtime' "non-persistent nftables runtime mode"
    assert_file_contains "$TEST_SYSTEM_ROOT/run/nft-vpsctl-ports" '2222' "runtime nftables candidate port"
    [[ ! -e "$TEST_SYSTEM_ROOT/etc/nftables.d/zz-vpsctl-access.nft" ]] || fail "runtime nftables mode wrote a persistence file"
    assert_status 0 "runtime nftables abort" run_access ssh abort --transaction "$tx"
    [[ ! -s "$TEST_SYSTEM_ROOT/run/nft-vpsctl-ports" ]] || fail "runtime nftables abort retained managed rules"

    reset_system
    : >"$TEST_SYSTEM_ROOT/run/nft-forward-only"
    prepare_transaction 2223 --firewall auto
    tx="$ACCESS_TEST_TX"
    state="$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/transactions/$tx/state"
    assert_file_contains "$state" $'firewall_backend\tnone' "non-INPUT nftables rules are not an SSH firewall"
    [[ ! -e "$TEST_SYSTEM_ROOT/run/nft-vpsctl-ports" ]] || fail "container-only nftables rules triggered an INPUT modification"
    assert_status 0 "container-only nftables transaction abort" run_access ssh abort --transaction "$tx"

    reset_system
    : >"$TEST_SYSTEM_ROOT/run/nft-input-accept-empty"
    prepare_transaction 2233 --firewall auto
    tx="$ACCESS_TEST_TX"
    state="$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/transactions/$tx/state"
    assert_file_contains "$state" $'firewall_backend\tnone' "empty accept INPUT chain needs no SSH allow rule"
    [[ ! -e "$TEST_SYSTEM_ROOT/run/nft-vpsctl-ports" ]] || fail "empty accept INPUT chain triggered an unnecessary nftables rule"
    assert_status 0 "empty accept INPUT transaction abort" run_access ssh abort --transaction "$tx"

    port=2224
    for family in ip ip6; do
        reset_system
        : >"$TEST_SYSTEM_ROOT/run/nft-active"
        printf '%s\n' "$family" >"$TEST_SYSTEM_ROOT/run/nft-family"
        prepare_transaction "$port" --firewall auto
        tx="$ACCESS_TEST_TX"
        assert_file_contains "$TEST_SYSTEM_ROOT/run/nft.log" "list chain $family filter input" "nftables $family INPUT target"
        assert_status 0 "nftables $family runtime abort" run_access ssh abort --transaction "$tx"
        port=$((port + 1))
    done

    reset_system
    : >"$TEST_SYSTEM_ROOT/run/ufw-active"
    : >"$TEST_SYSTEM_ROOT/run/firewalld-active"
    assert_status 3 "multiple active firewall rejection" run_access ssh prepare --port 2222 --firewall auto
    assert_contains "$ACCESS_TEST_OUTPUT" '多个活动防火墙' "multiple firewall diagnostic"
}

test_abort_expiry_and_reload_rollback() {
    local tx state managed state_sha managed_sha

    reset_system
    prepare_transaction 2201
    tx="$ACCESS_TEST_TX"
    managed="$TEST_SYSTEM_ROOT/etc/ssh/sshd_config.d/00-vpsctl-access.conf"
    state="$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/transactions/$tx/state"
    assert_file_contains "$managed" 'Port 2201' "pending new port"
    assert_file_contains "$managed" 'Port 22' "pending old port"
    managed_sha="$(sha256sum "$managed")"
    state_sha="$(sha256sum "$state")"
    assert_status 0 "abort dry-run" run_access --dry-run ssh abort --transaction "$tx"
    assert_equal "$managed_sha" "$(sha256sum "$managed")" "abort dry-run managed config"
    assert_equal "$state_sha" "$(sha256sum "$state")" "abort dry-run state"
    [[ -f "$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/active" ]] || fail "abort dry-run cleared active transaction"
    assert_status 0 "abort prepared transaction" run_access ssh abort --transaction "$tx"
    [[ ! -e "$TEST_SYSTEM_ROOT/etc/ssh/sshd_config.d/00-vpsctl-access.conf" ]] || fail "abort did not restore absent managed config"
    [[ ! -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/active" ]] || fail "abort left active transaction marker"
    state="$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/transactions/$tx/state"
    assert_file_contains "$state" $'status\taborted' "aborted transaction state"
    assert_status 3 "abort replay rejection" run_access ssh abort --transaction "$tx"

    reset_system
    seed_alice_key
    prepare_transaction 2202 --root-login deny --password-login deny --fallback-user alice
    tx="$ACCESS_TEST_TX"
    state="$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/transactions/$tx/state"
    sed -i 's/^expires_epoch\t.*/expires_epoch\t1/' "$state"
    assert_status 3 "expired session proof rejection" run_access session verify --transaction "$tx"
    assert_contains "$ACCESS_TEST_OUTPUT" '超过 15 分钟' "expired proof diagnostic"
    assert_status 3 "expired commit rejection" run_access ssh commit --transaction "$tx" --confirm-apply "$tx"
    assert_status 0 "expired transaction remains abortable" run_access ssh abort --transaction "$tx"

    reset_system
    : >"$TEST_SYSTEM_ROOT/run/fail-reload-once"
    assert_status 20 "reload failure triggers rollback" run_access ssh prepare --port 2203 --firewall manual
    [[ ! -e "$TEST_SYSTEM_ROOT/etc/ssh/sshd_config.d/00-vpsctl-access.conf" ]] || fail "reload failure did not roll back managed config"
    [[ ! -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/active" ]] || fail "reload failure left active transaction marker"
}

test_verify_commit_replay_and_restore() {
    local tx backup state managed manifest command output status=0 managed_sha manifest_sha

    reset_system
    seed_alice_key
    prepare_transaction 2222 --root-login deny --password-login deny --fallback-user alice
    tx="$ACCESS_TEST_TX"
    assert_status 2 "commit confirmation must equal transaction" run_access ssh commit --transaction "$tx" --confirm-apply tx-20000101T000000Z-0000000000000000
    assert_file_contains "$TEST_SYSTEM_ROOT/run/sshd.log" '-C user=root,host=localhost,addr=127.0.0.1' "root sshd context validation"
    assert_file_contains "$TEST_SYSTEM_ROOT/run/sshd.log" '-C user=alice,host=localhost,addr=127.0.0.1' "fallback sshd context validation"
    verify_transaction "$tx" 2222
    state="$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/transactions/$tx/state"
    assert_file_contains "$state" $'status\tprepared' "verified transaction remains prepared"
    managed="$TEST_SYSTEM_ROOT/etc/ssh/sshd_config.d/00-vpsctl-access.conf"
    managed_sha="$(sha256sum "$managed")"
    assert_status 0 "commit dry-run" run_access --dry-run ssh commit --transaction "$tx" --confirm-apply "$tx"
    assert_equal "$managed_sha" "$(sha256sum "$managed")" "commit dry-run managed config"
    assert_file_contains "$state" $'status\tprepared' "commit dry-run state"
    [[ -f "$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/transactions/$tx/proofs/proof.1001" ]] || fail "commit dry-run consumed proof"

    assert_status 0 "commit verified transaction" run_access ssh commit --transaction "$tx" --confirm-apply "$tx"
    backup="$(extract_id bak "$ACCESS_TEST_OUTPUT")"
    [[ -n "$backup" ]] || fail "commit output did not contain backup ID: $ACCESS_TEST_OUTPUT"
    managed="$TEST_SYSTEM_ROOT/etc/ssh/sshd_config.d/00-vpsctl-access.conf"
    assert_file_contains "$managed" 'Port 2222' "committed new port"
    [[ "$(grep -c '^Port ' "$managed")" == 1 ]] || fail "commit retained the old SSH port"
    assert_file_contains "$managed" 'ExposeAuthInfo no' "commit disables proof exposure"
    assert_file_contains "$state" $'status\tcommitted' "committed transaction state"
    [[ ! -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/active" ]] || fail "commit left active transaction marker"

    manifest="$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/security/access/$backup/manifest"
    managed_sha="$(sha256sum "$managed")"
    manifest_sha="$(sha256sum "$manifest")"
    assert_status 0 "SSH restore dry-run" run_access --dry-run restore --backup "$backup"
    assert_equal "$managed_sha" "$(sha256sum "$managed")" "SSH restore dry-run config"
    assert_equal "$manifest_sha" "$(sha256sum "$manifest")" "SSH restore dry-run manifest"

    assert_status 3 "session proof replay rejection" env \
        SSH_CONNECTION='192.0.2.10 43100 192.0.2.20 2222' SSH_TTY=/dev/pts/9 \
        SSH_USER_AUTH="$TEST_SYSTEM_ROOT/run/auth-info" \
        bash "$TEST_ROOT/commands/security/access.sh" --no-color --non-interactive \
        session verify --transaction "$tx"
    assert_status 3 "commit replay rejection" run_access ssh commit --transaction "$tx" --confirm-apply "$tx"

    assert_status 3 "restore refuses non-TTY confirmation" run_access restore --backup "$backup"
    command -v script >/dev/null 2>&1 || fail "restore tests require util-linux script"
    printf -v command 'env VPSCTL_NON_INTERACTIVE=0 bash %q --no-color restore --backup %q' "$TEST_ROOT/commands/security/access.sh" "$backup"
    output="$(printf '%s\n' "$backup" | script -q -e -c "$command" /dev/null 2>&1)" || status=$?
    [[ "$status" == 0 ]] || fail "restore committed backup failed with $status: $output"
    [[ ! -e "$managed" ]] || fail "restore did not reinstate absence of managed config"
    assert_file_contains "$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/security/access/$backup/manifest" $'lifecycle\trestored' "restored backup lifecycle"
    assert_status 3 "restore replay rejection" run_access restore --backup "$backup"
}

test_firewall_owned_rule_cleanup() {
    local tx

    reset_system
    : >"$TEST_SYSTEM_ROOT/run/firewalld-active"
    assert_status 0 "firewalld auto dry-run" run_access --dry-run ssh prepare --port 2240 --firewall auto
    [[ ! -e "$TEST_SYSTEM_ROOT/run/firewalld-vpsctl-runtime" && ! -e "$TEST_SYSTEM_ROOT/run/firewalld-vpsctl-permanent" ]] || fail "firewalld dry-run added a rule"
    [[ ! -e "$TEST_SYSTEM_ROOT/etc/ssh/sshd_config.d/00-vpsctl-access.conf" ]] || fail "firewalld dry-run wrote SSH config"

    reset_system
    : >"$TEST_SYSTEM_ROOT/run/ufw-active"
    prepare_transaction 2241 --firewall auto
    tx="$ACCESS_TEST_TX"
    printf '2241\n' >"$TEST_SYSTEM_ROOT/run/ufw-user-port"
    assert_status 0 "UFW abort removes only marked rule" run_access ssh abort --transaction "$tx"
    [[ -f "$TEST_SYSTEM_ROOT/run/ufw-user-port" ]] || fail "UFW abort removed the administrator rule"
    [[ ! -e "$TEST_SYSTEM_ROOT/run/ufw-user-deleted" ]] || fail "UFW abort targeted an unowned rule"
    [[ ! -e "$TEST_SYSTEM_ROOT/run/ufw-vpsctl-port" ]] || fail "UFW abort retained the vpsctl rule"
    assert_file_contains "$TEST_SYSTEM_ROOT/run/ufw-delete.log" '--force delete 1' "UFW numbered ownership deletion"

    reset_system
    : >"$TEST_SYSTEM_ROOT/run/firewalld-active"
    prepare_transaction 2242 --firewall auto
    tx="$ACCESS_TEST_TX"
    printf '2242\n' >"$TEST_SYSTEM_ROOT/run/firewalld-user-runtime"
    printf '2242\n' >"$TEST_SYSTEM_ROOT/run/firewalld-user-permanent"
    assert_status 0 "firewalld abort removes only rich rule" run_access ssh abort --transaction "$tx"
    [[ -f "$TEST_SYSTEM_ROOT/run/firewalld-user-runtime" && -f "$TEST_SYSTEM_ROOT/run/firewalld-user-permanent" ]] || fail "firewalld abort removed an administrator rule"
    [[ ! -e "$TEST_SYSTEM_ROOT/run/firewalld-user-deleted" ]] || fail "firewalld abort used unowned remove-port"
    [[ ! -e "$TEST_SYSTEM_ROOT/run/firewalld-vpsctl-runtime" && ! -e "$TEST_SYSTEM_ROOT/run/firewalld-vpsctl-permanent" ]] || fail "firewalld abort retained a vpsctl rich rule"
    assert_file_contains "$TEST_SYSTEM_ROOT/run/firewalld.log" '--remove-rich-rule=' "firewalld exact ownership deletion"

    reset_system
    : >"$TEST_SYSTEM_ROOT/run/nft-active"
    : >"$TEST_SYSTEM_ROOT/run/nft-persistent"
    mkdir -p -- "$TEST_SYSTEM_ROOT/etc/nftables.d"
    printf 'include "/etc/nftables.d/*.nft"\n' >"$TEST_SYSTEM_ROOT/etc/nftables.conf"
    VPSCTL_QUIET=0
    prepare_transaction 2243 --firewall auto
    VPSCTL_QUIET=1
    tx="$ACCESS_TEST_TX"
    assert_file_contains "$TEST_SYSTEM_ROOT/etc/nftables.d/zz-vpsctl-access.nft" 'insert rule inet filter input' "nftables anchored rule"
    : >"$TEST_SYSTEM_ROOT/run/nft-user-rule"
    assert_status 0 "nftables abort removes only marked rules" run_access ssh abort --transaction "$tx"
    [[ -e "$TEST_SYSTEM_ROOT/run/nft-user-rule" ]] || fail "nftables abort removed an administrator rule"
    [[ ! -e "$TEST_SYSTEM_ROOT/etc/nftables.d/zz-vpsctl-access.nft" ]] || fail "nftables abort retained the vpsctl persistence file"

    reset_system
    : >"$TEST_SYSTEM_ROOT/run/iptables-active"
    : >"$TEST_SYSTEM_ROOT/run/iptables-persistent"
    : >"$TEST_SYSTEM_ROOT/run/iptables-user-rule"
    prepare_transaction 2244 --firewall auto
    tx="$ACCESS_TEST_TX"
    assert_status 0 "iptables abort removes only comment rules" run_access ssh abort --transaction "$tx"
    [[ -e "$TEST_SYSTEM_ROOT/run/iptables-user-rule" ]] || fail "iptables abort removed an administrator rule"
    [[ ! -e "$TEST_SYSTEM_ROOT/run/iptables-vpsctl-port" && ! -e "$TEST_SYSTEM_ROOT/run/ip6tables-vpsctl-port" ]] || fail "iptables abort retained a vpsctl rule"
    assert_file_contains "$TEST_SYSTEM_ROOT/run/netfilter-persistent.log" 'save' "iptables persistence save"
}

test_rhel_platform_branches() {
    local output

    reset_system
    VPSCTL_ENV_OS_ID=''
    output="$(run_access status --json)"
    assert_contains "$output" '"service": "ssh.service"' "detected Debian-family platform is propagated to SSH service selection"
    VPSCTL_ENV_OS_ID=ubuntu

    reset_system
    VPSCTL_ENV_OS_ID=rocky
    mkdir -p -- "$TEST_SYSTEM_ROOT/etc/crypto-policies/back-ends"
    printf 'Include /etc/crypto-policies/back-ends/opensshserver.config\n' >"$TEST_SYSTEM_ROOT/etc/ssh/sshd_config.d/50-redhat.conf"
    printf 'Ciphers aes256-gcm@openssh.com\n' >"$TEST_SYSTEM_ROOT/etc/crypto-policies/back-ends/opensshserver.config"
    output="$(run_access status --json)"
    assert_contains "$output" '"service": "sshd.service"' "RHEL SSH service"
    assert_contains "$output" '"config_shape": "standard"' "RHEL crypto policy include"
    assert_status 0 "RHEL administrator user" run_access user add --name deploy
    assert_file_contains "$TEST_SYSTEM_ROOT/run/useradd.log" '--groups wheel' "RHEL wheel administrator group"
    VPSCTL_ENV_OS_ID=ubuntu
}

test_proof_and_configuration_integrity() {
    local tx proof auth_file command

    reset_system
    seed_alice_key
    prepare_transaction 2231 --root-login deny --password-login deny --fallback-user alice
    tx="$ACCESS_TEST_TX"
    auth_file="$TEST_SYSTEM_ROOT/run/stale-auth-info"
    printf 'publickey ssh-ed25519 SHA256:stale\n' >"$auth_file"
    chmod 0600 -- "$auth_file"
    touch -d @1 "$auth_file"
    printf -v command 'env SSH_CONNECTION=%q SSH_TTY=/dev/pts/9 SSH_USER_AUTH=%q bash %q --no-color session verify --transaction %q' \
        '192.0.2.10 43100 192.0.2.20 2231' "$auth_file" "$TEST_ROOT/commands/security/access.sh" "$tx"
    assert_status 3 "stale authentication proof rejection" script -q -e -c "$command" /dev/null
    assert_contains "$ACCESS_TEST_OUTPUT" '早于事务创建时间' "stale authentication proof diagnostic"
    assert_status 0 "abort after stale authentication proof" run_access ssh abort --transaction "$tx"

    reset_system
    seed_alice_key
    prepare_transaction 2232 --root-login deny --password-login deny --fallback-user alice
    tx="$ACCESS_TEST_TX"
    verify_transaction "$tx" 2232
    proof="$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/transactions/$tx/proofs/proof.1001"
    chmod 0644 -- "$proof"
    assert_status 3 "wrong proof mode rejection" run_access ssh commit --transaction "$tx" --confirm-apply "$tx"
    assert_status 0 "abort after wrong proof mode" run_access ssh abort --transaction "$tx"

    reset_system
    seed_alice_key
    prepare_transaction 2233 --root-login deny --password-login deny --fallback-user alice
    tx="$ACCESS_TEST_TX"
    verify_transaction "$tx" 2233
    : >"$TEST_SYSTEM_ROOT/run/proof-owner-user"
    assert_status 3 "wrong proof owner rejection" run_access ssh commit --transaction "$tx" --confirm-apply "$tx"
    rm -f -- "$TEST_SYSTEM_ROOT/run/proof-owner-user"
    assert_status 0 "abort after wrong proof owner" run_access ssh abort --transaction "$tx"

    reset_system
    seed_alice_key
    prepare_transaction 2234 --root-login deny --password-login deny --fallback-user alice
    tx="$ACCESS_TEST_TX"
    verify_transaction "$tx" 2234
    proof="$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/access/transactions/$tx/proofs/proof.1001"
    sed -i 's/^verified_epoch\t.*/verified_epoch\t1/' "$proof"
    assert_status 30 "out-of-window proof timestamp rejection" run_access ssh commit --transaction "$tx" --confirm-apply "$tx"
    assert_contains "$ACCESS_TEST_OUTPUT" '证明时间无效' "proof timestamp diagnostic"
    assert_status 0 "abort after invalid proof timestamp" run_access ssh abort --transaction "$tx"

    reset_system
    seed_alice_key
    prepare_transaction 2235 --root-login deny --password-login deny --fallback-user alice
    tx="$ACCESS_TEST_TX"
    verify_transaction "$tx" 2235
    printf '# unexpected drift\n' >>"$TEST_SYSTEM_ROOT/etc/ssh/sshd_config.d/00-vpsctl-access.conf"
    assert_status 30 "managed configuration drift rejection" run_access ssh commit --transaction "$tx" --confirm-apply "$tx"
    assert_contains "$ACCESS_TEST_OUTPUT" '配置发生漂移' "managed configuration drift diagnostic"
    assert_status 0 "abort after configuration drift" run_access ssh abort --transaction "$tx"
}

test_cli_validation_and_status
test_user_password_and_keys
test_sshd_shape_and_firewall_rejections
test_abort_expiry_and_reload_rollback
test_verify_commit_replay_and_restore
test_proof_and_configuration_integrity
test_firewall_owned_rule_cleanup
test_rhel_platform_branches
printf 'PASS: security access unit tests\n'
