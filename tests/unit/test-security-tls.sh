#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-tls-test.XXXXXX")"
readonly TEST_ROOT TEST_TMP
readonly MOCK_BIN="${TEST_TMP}/mock-bin"
readonly SYSTEM_ROOT="${TEST_TMP}/system-root"
readonly FIXTURES="${TEST_TMP}/fixtures"
readonly MOCK_LOG="${TEST_TMP}/mock.log"

cleanup() { rm -rf -- "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2'"; }
assert_status() {
    local expected="$1" message="$2" output status=0
    shift 2
    output="$("$@" 2>&1)" || status=$?
    [[ "$status" == "$expected" ]] || fail "$message: expected $expected, got $status; output: $output"
    TLS_TEST_OUTPUT="$output"
}
assert_file() { [[ -f "$1" && ! -L "$1" ]] || fail "$2: missing regular file $1"; }

make_mock() {
    local name="$1"
    shift
    printf '#!/usr/bin/env bash\n%s\n' "$*" >"${MOCK_BIN}/${name}"
    chmod +x -- "${MOCK_BIN}/${name}"
}

mkdir -p -- "$MOCK_BIN" "$SYSTEM_ROOT" "$FIXTURES"
: >"$MOCK_LOG"

make_mock systemctl '
printf "systemctl" >>"${MOCK_LOG}"
printf " %s" "$@" >>"${MOCK_LOG}"
printf "\n" >>"${MOCK_LOG}"
case "${1:-}" in
    is-active) [[ -e "${VPSCTL_SYSTEM_ROOT}/run/tls-timer-active" ]] ;;
    is-enabled) [[ -e "${VPSCTL_SYSTEM_ROOT}/run/tls-timer-enabled" ]] ;;
    cat)
        [[ -e "${VPSCTL_SYSTEM_ROOT}/run/mock-systemd/${2:-}" ]] || exit 1
        ;;
    enable)
        : >"${VPSCTL_SYSTEM_ROOT}/run/tls-timer-enabled"
        [[ " $* " != *" --now "* ]] || : >"${VPSCTL_SYSTEM_ROOT}/run/tls-timer-active"
        ;;
    disable)
        rm -f -- "${VPSCTL_SYSTEM_ROOT}/run/tls-timer-enabled"
        [[ " $* " != *" --now "* ]] || rm -f -- "${VPSCTL_SYSTEM_ROOT}/run/tls-timer-active"
        ;;
    daemon-reload) ;;
    try-reload-or-restart|restart) ;;
    *) exit 0 ;;
esac'

make_mock ss '
if [[ -e "${VPSCTL_SYSTEM_ROOT}/run/port80" ]]; then
    printf "LISTEN 0 128 *:80\n"
fi
exit 0'

make_mock curl '
printf "curl" >>"${MOCK_LOG}"
printf " %s" "$@" >>"${MOCK_LOG}"
printf "\n" >>"${MOCK_LOG}"
exit 1'

make_mock flock 'exit 0'

make_mock lego '
path=""
domain=""
cmd=""
while (($# > 0)); do
    case "$1" in
        --path) path="$2"; shift 2 ;;
        --domains) domain="$2"; shift 2 ;;
        run|renew) cmd="$1"; shift ;;
        *) shift ;;
    esac
done
[[ -n "$path" && -n "$domain" && -n "${MOCK_LEGO_CERT:-}" && -n "${MOCK_LEGO_KEY:-}" ]] || exit 1
base="${domain//\*/_}"
mkdir -p -- "${path}/certificates"
cp -- "$MOCK_LEGO_CERT" "${path}/certificates/${base}.pem"
cp -- "$MOCK_LEGO_CERT" "${path}/certificates/${base}.crt"
cp -- "$MOCK_LEGO_KEY" "${path}/certificates/${base}.key"
exit 0'

export PATH="${MOCK_BIN}:/usr/bin:/bin"
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$SYSTEM_ROOT"
export VPSCTL_ENV_KERNEL_NAME=Linux VPSCTL_ENV_INIT=systemd VPSCTL_ENV_ARCH=x86_64
export VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0 VPSCTL_ASSUME_YES=1 VPSCTL_NON_INTERACTIVE=1
export VPSCTL_QUIET=0 VPSCTL_VERBOSE=0 VPSCTL_NO_COLOR=1
export MOCK_LOG

run_tls() {
    bash "$TEST_ROOT/commands/security/tls.sh" --no-color --non-interactive "$@"
}

reset_system() {
    rm -rf -- "$SYSTEM_ROOT"
    mkdir -p -- "$SYSTEM_ROOT/run" "$SYSTEM_ROOT/usr/local/libexec/vpsctl" "$FIXTURES"
    : >"$MOCK_LOG"
}

make_cert() {
    local name="$1" days="${2:-2}"
    local dir="${FIXTURES}/${name}"
    mkdir -p -- "$dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days "$days" -subj "/CN=${name}" \
        -addext "subjectAltName=DNS:${name}" \
        -keyout "$dir/key.pem" -out "$dir/cert.pem" >/dev/null 2>&1 \
        || fail "failed to generate fixture certificate $name"
}

make_expired_cert() {
    local dir="${FIXTURES}/expired.example"
    mkdir -p -- "$dir"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -subj "/CN=expired.example" \
        -addext "subjectAltName=DNS:expired.example" \
        -not_before 19990101000000Z -not_after 20000102000000Z \
        -keyout "$dir/key.pem" -out "$dir/cert.pem" >/dev/null 2>&1 \
        || fail "failed to generate expired certificate"
}

plant_lego() {
    local sha
    install -m 0755 -- "${MOCK_BIN}/lego" "${SYSTEM_ROOT}/usr/local/libexec/vpsctl/lego"
    mkdir -p -- "${SYSTEM_ROOT}/var/lib/vpsctl/security/tls"
    sha="$(sha256sum -- "${SYSTEM_ROOT}/usr/local/libexec/vpsctl/lego" | awk '{print $1}')"
    printf 'tag=v5.4.1\nasset=lego_v5.4.1_linux_amd64.tar.gz\nsha256=%s\n' "$sha" \
        >"${SYSTEM_ROOT}/var/lib/vpsctl/security/tls/lego.meta"
}

imported_id() {
    grep -Eo 'crt-[0-9a-f]{16}' <<<"$1" | head -n 1
}

test_help_and_status() {
    local output
    reset_system
    output="$(run_tls --help)"
    assert_contains "$output" "import" "help lists import"
    assert_contains "$output" "issue" "help lists issue"
    assert_status 2 "unknown action" run_tls nope
    output="$(run_tls status --json)"
    assert_contains "$output" '"schema_version":1' "empty json schema"
    assert_contains "$output" '"total":0' "empty count"
    assert_not_contains "$output" "BEGIN PRIVATE" "status json has no private key"
    assert_status 2 "duplicate json" run_tls status --json --json
}

test_import_replace_delete() {
    local output id live_cert live_key
    reset_system
    make_cert example.com
    assert_status 2 "import missing files" run_tls import --name example
    assert_status 2 "relative cert path" run_tls import --name example \
        --cert-file cert.pem --key-file "${FIXTURES}/example.com/key.pem"
    output="$(run_tls import --name example --cert-file "${FIXTURES}/example.com/cert.pem" \
        --key-file "${FIXTURES}/example.com/key.pem")"
    id="$(imported_id "$output")"
    [[ "$id" =~ ^crt-[0-9a-f]{16}$ ]] || fail "import did not print certificate id"
    live_cert="${SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live/${id}/fullchain.pem"
    live_key="${SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live/${id}/privkey.pem"
    assert_file "$live_cert" "imported fullchain"
    assert_file "$live_key" "imported privkey"
    [[ "$(stat -c '%a' "$live_key")" == 600 ]] || fail "privkey mode is not 0600"
    output="$(run_tls show --id "$id")"
    assert_contains "$output" "example.com" "show lists domain"
    output="$(run_tls paths --id "$id")"
    assert_contains "$output" "/var/lib/vpsctl/security/tls/live/${id}/fullchain.pem" "paths fullchain"
    assert_contains "$output" "/var/lib/vpsctl/security/tls/live/${id}/privkey.pem" "paths privkey"
    output="$(run_tls status --json)"
    assert_contains "$output" '"imported":1' "json imported count"
    assert_not_contains "$output" "BEGIN PRIVATE" "json still has no key"

    make_cert www.example.com
    run_tls replace --id "$id" --cert-file "${FIXTURES}/www.example.com/cert.pem" \
        --key-file "${FIXTURES}/www.example.com/key.pem"
    output="$(run_tls show --id "$id")"
    assert_contains "$output" "www.example.com" "replace updated SAN"

    assert_status 2 "delete without confirm" run_tls delete --id "$id"
    run_tls delete --id "$id" --confirm-delete
    assert_status 3 "deleted cert missing" run_tls show --id "$id"
}

test_validation_failures() {
    reset_system
    make_expired_cert
    assert_status 10 "expired cert rejected" run_tls import --name expired \
        --cert-file "${FIXTURES}/expired.example/cert.pem" \
        --key-file "${FIXTURES}/expired.example/key.pem"

    make_cert a.example
    make_cert b.example
    assert_status 10 "mismatched key rejected" run_tls import --name mismatch \
        --cert-file "${FIXTURES}/a.example/cert.pem" \
        --key-file "${FIXTURES}/b.example/key.pem"

    openssl genrsa -aes128 -passout pass:secret -out "${FIXTURES}/enc.key" 2048 >/dev/null 2>&1 \
        || fail "encrypted key fixture"
    assert_status 10 "encrypted key rejected" run_tls import --name enc \
        --cert-file "${FIXTURES}/a.example/cert.pem" --key-file "${FIXTURES}/enc.key"
}

test_dry_run_does_not_write() {
    local leftover
    reset_system
    make_cert dry.example
    run_tls --dry-run import --name dry \
        --cert-file "${FIXTURES}/dry.example/cert.pem" \
        --key-file "${FIXTURES}/dry.example/key.pem"
    leftover="$(find "${SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live" -type f 2>/dev/null || true)"
    [[ -z "$leftover" ]] || fail "dry-run import wrote live files"
}

test_drift_rejects_writes() {
    local output id live
    reset_system
    make_cert drift.example
    output="$(run_tls import --name drift --cert-file "${FIXTURES}/drift.example/cert.pem" \
        --key-file "${FIXTURES}/drift.example/key.pem")"
    id="$(imported_id "$output")"
    live="${SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live/${id}/fullchain.pem"
    make_cert other.example
    cp -- "${FIXTURES}/other.example/cert.pem" "$live"
    assert_status 30 "drift blocks replace" run_tls replace --id "$id" \
        --cert-file "${FIXTURES}/other.example/cert.pem" \
        --key-file "${FIXTURES}/other.example/key.pem"
    assert_contains "$TLS_TEST_OUTPUT" "状态为 drift" "drift diagnostic"
}

test_issue_renew_and_timer() {
    local output id
    reset_system
    make_cert acme.example 40
    plant_lego
    export MOCK_LEGO_CERT="${FIXTURES}/acme.example/cert.pem"
    export MOCK_LEGO_KEY="${FIXTURES}/acme.example/key.pem"
    output="$(run_tls issue --domain acme.example --challenge http-01 \
        --email ops@example.com --reload none)"
    id="$(imported_id "$output")"
    [[ -n "$id" ]] || fail "issue did not print id"
    assert_file "${SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live/${id}/fullchain.pem" "issued live cert"
    assert_file "${SYSTEM_ROOT}/etc/systemd/system/vpsctl-tls-renew.timer" "timer unit written"
    assert_contains "$(<"${SYSTEM_ROOT}/etc/systemd/system/vpsctl-tls-renew.timer")" "Managed by vpsctl security tls" "timer marker"
    [[ -e "${SYSTEM_ROOT}/run/tls-timer-enabled" ]] || fail "issue did not enable timer"

    output="$(run_tls renew --id "$id" 2>&1)"
    assert_contains "$output" "跳过续期" "fresh cert skipped"

    run_tls renew --id "$id" --force
    output="$(run_tls show --json --id "$id")"
    assert_contains "$output" '"source":"acme"' "forced renew keeps acme source"

    : >"${SYSTEM_ROOT}/run/port80"
    assert_status 3 "http-01 busy port" run_tls issue --domain busy.example --challenge http-01 --email ops@example.com
    rm -f -- "${SYSTEM_ROOT}/run/port80"

    run_tls timer disable
    [[ ! -e "${SYSTEM_ROOT}/run/tls-timer-enabled" ]] || fail "timer disable left enabled"
    run_tls timer enable
    [[ -e "${SYSTEM_ROOT}/run/tls-timer-enabled" ]] || fail "timer enable failed"
    unset MOCK_LEGO_CERT MOCK_LEGO_KEY
}

test_dns_credentials_and_secrets() {
    local output id cred cred_mode
    reset_system
    make_cert dns.example 40
    plant_lego
    export MOCK_LEGO_CERT="${FIXTURES}/dns.example/cert.pem"
    export MOCK_LEGO_KEY="${FIXTURES}/dns.example/key.pem"
    cred="${FIXTURES}/cf.env"
    printf 'CF_DNS_API_TOKEN=super-secret-token\nUNKNOWN=1\n' >"$cred"
    assert_status 10 "unknown credential key" run_tls issue --domain dns.example --challenge dns-01 \
        --dns-provider cloudflare --dns-credential-file "$cred" --email ops@example.com
    printf 'CF_DNS_API_TOKEN=super-secret-token\n' >"$cred"
    output="$(run_tls issue --domain dns.example --challenge dns-01 --dns-provider cloudflare --dns-credential-file "$cred" --email ops@example.com)"
    id="$(imported_id "$output")"
    assert_not_contains "$output" "super-secret-token" "issue output leaked token"
    cred_mode="$(stat -c '%a' "${SYSTEM_ROOT}/var/lib/vpsctl/security/tls/credentials/${id}.env")"
    [[ "$cred_mode" == 600 ]] || fail "credential file mode is not 0600"
    unset MOCK_LEGO_CERT MOCK_LEGO_KEY
}

test_uninstall_keeps_backups() {
    local output id
    reset_system
    make_cert keep.example
    output="$(run_tls import --name keep --cert-file "${FIXTURES}/keep.example/cert.pem" \
        --key-file "${FIXTURES}/keep.example/key.pem")"
    id="$(imported_id "$output")"
    assert_status 2 "uninstall token required" run_tls uninstall
    run_tls uninstall --confirm-uninstall REMOVE-VPSCTL-TLS
    assert_file "${SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live/${id}/fullchain.pem" "plain uninstall kept cert"
    run_tls uninstall --purge --confirm-uninstall REMOVE-VPSCTL-TLS --confirm-purge
    [[ ! -e "${SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live/${id}/fullchain.pem" ]] || fail "purge left live cert"
    [[ -d "${SYSTEM_ROOT}/var/lib/vpsctl/backups/security/tls" ]] || fail "purge removed backups"
}

test_help_and_status
test_import_replace_delete
test_validation_failures
test_dry_run_does_not_write
test_drift_rejects_writes
test_issue_renew_and_timer
test_dns_credentials_and_secrets
test_uninstall_keeps_backups
printf 'PASS: security tls unit tests\n'
