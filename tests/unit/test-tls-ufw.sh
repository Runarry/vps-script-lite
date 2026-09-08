#!/usr/bin/env bash
# Focused lifecycle checks; the shared UFW suite owns real rule reconciliation.
set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TMP="$(mktemp -d)"
export TEST_TMP
trap 'rm -rf -- "$TEST_TMP"' EXIT
# shellcheck source=../../commands/security/tls/ufw.sh
source "${TEST_ROOT}/commands/security/tls/ufw.sh"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
vps_cmd_warning() { :; }
vps_cmd_info() { :; }
vps_cmd_unlock() { :; }
vps_ufw_require_tools() { printf 'tools\n' >>"$TEST_TMP/events"; }
vps_ufw_init() { :; }
vps_ufw_rollback() { :; }
vps_ufw_ipv6_available() { [[ "${TLS_TEST_IPV6:-1}" == 1 ]]; }
vps_ufw_begin() {
    if [[ "$(cat "$2")" == '[]' ]]; then
        printf 'release\n' >>"$TEST_TMP/events"
    else
        jq -e --argjson ipv6 "${TLS_TEST_IPV6:-1}" '
            (map(.family) == if $ipv6 == 1 then ["ipv4", "ipv6"] else ["ipv4"] end)
            and all(.[]; .port == "80" and .proto == "tcp" and .temporary == true)' "$2" >/dev/null || return 70
        printf 'acquire\n' >>"$TEST_TMP/events"
    fi
}
vps_ufw_commit() { printf 'commit\n' >>"$TEST_TMP/events"; }
tls_run_lego() { printf 'dns-or-dry\n' >>"$TEST_TMP/events"; }
TLS_LEGO_BIN="$TEST_TMP/lego"
cat >"$TLS_LEGO_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'lego\n' >>"$TEST_TMP/events"
if [[ "${TLS_TEST_SIGNAL:-0}" == 1 ]]; then
    kill -TERM "$TLS_TEST_HOLDER_PID"
    exec sleep 20
fi
exit "${TLS_TEST_RESULT:-0}"
EOF
chmod +x "$TLS_LEGO_BIN"

for TLS_TEST_IPV6 in 0 1; do
    for expected in 0 17; do
        : >"$TEST_TMP/events"
        export TLS_TEST_RESULT="$expected"
        status=0
        tls_run_challenge http-01 '' run || status=$?
        [[ "$status" == "$expected" ]] || fail "lego status not preserved: $status"
        [[ "$(cat "$TEST_TMP/events")" == $'tools\nacquire\ncommit\nlego\nrelease\ncommit' ]] || fail 'lease lifetime/order'
        [[ -z "$TLS_UFW_SCOPE$TLS_UFW_DESIRED$TLS_HTTP_CHILD_PID" ]] || fail 'lease globals not cleared'
    done
done

for challenge in dns-01 http-01; do
    : >"$TEST_TMP/events"
    VPSCTL_DRY_RUN=1 tls_run_challenge "$challenge" '' run
    [[ "$(cat "$TEST_TMP/events")" == dns-or-dry ]] || fail 'dry-run called UFW'
done
: >"$TEST_TMP/events"
tls_run_challenge dns-01 '' run
[[ "$(cat "$TEST_TMP/events")" == dns-or-dry ]] || fail 'DNS called UFW'

# Explicit BASHPID targets the lease holder even inside a Bash subshell.
: >"$TEST_TMP/events"
status=0
(
    tls_install_cleanup_traps
    export TLS_TEST_HOLDER_PID="$BASHPID"
    export TLS_TEST_SIGNAL=1
    tls_run_challenge http-01 '' run
) || status=$?
[[ "$status" == 143 ]] || fail "TERM status not preserved: $status"
[[ "$(cat "$TEST_TMP/events")" == $'tools\nacquire\ncommit\nlego\nrelease\ncommit' ]] || fail 'TERM did not release lease'

for original in 0 17; do
    status=0
    (
        tls_install_cleanup_traps
        # Invoked indirectly by the EXIT cleanup installed above.
        # shellcheck disable=SC2317
        tls_ufw_release() { return 30; }
        exit "$original"
    ) || status=$?
    expected="$original"
    ((original != 0)) || expected=30
    [[ "$status" == "$expected" ]] || fail "EXIT cleanup status: expected $expected, got $status"
done
printf 'PASS: TLS UFW lease lifecycle\n'
