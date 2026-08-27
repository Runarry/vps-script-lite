#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly RFW_SCRIPT="${TEST_ROOT}/commands/network/rfw.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-rfw-test.XXXXXX")"
readonly TEST_ROOT TEST_TMP
readonly MOCK_BIN="${TEST_TMP}/mock-bin"
readonly SYSTEM_ROOT="${TEST_TMP}/system-root"
readonly MOCK_LOG="${TEST_TMP}/mock.log"
export SYSTEM_ROOT MOCK_LOG

cleanup() { rm -rf -- "$TEST_TMP"; }
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local value="$1" expected="$2" message="$3"
    [[ "$value" == *"$expected"* ]] || fail "${message}: missing '${expected}'"
}

assert_file_contains() {
    local file="$1" expected="$2" message="$3"
    [[ -f "$file" ]] || fail "${message}: file missing: ${file}"
    grep -Fq -- "$expected" "$file" || fail "${message}: missing '${expected}'"
}

assert_status() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] || fail "${message}: expected status ${expected}, got ${actual}"
}

write_mocks() {
    mkdir -p -- "$MOCK_BIN" "$SYSTEM_ROOT"

    cat >"${MOCK_BIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf '%s\n' "${MOCK_KERNEL:-Linux}" ;;
    -m) printf '%s\n' "${MOCK_ARCH:-x86_64}" ;;
    -r) printf '%s\n' "${MOCK_KERNEL_RELEASE:-6.1.0}" ;;
    *) printf '%s\n' "${MOCK_KERNEL:-Linux}" ;;
esac
EOF

    cat >"${MOCK_BIN}/ip" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" route show default "* ]]; then
    printf 'default via 192.0.2.1 dev ens3\n'
elif [[ " $* " == *" link show dev "* && "${MOCK_INTERFACE_MISSING:-0}" == "1" ]]; then
    exit 1
fi
EOF

    cat >"${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
output=""
url=""
original_args="$*"
while (($#)); do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf 'curl-args %s\n' "$original_args" >> "$MOCK_LOG"
printf 'curl %s\n' "$url" >> "$MOCK_LOG"
case "$url" in
    */releases/latest)
        printf '{"tag_name":"%s","draft":%s,"prerelease":%s}\n' \
            "${MOCK_RELEASE_TAG:-v1.2.3}" "${MOCK_DRAFT:-false}" "${MOCK_PRERELEASE:-false}" > "$output"
        ;;
    */checksums.txt)
        if [[ "${MOCK_BAD_CHECKSUM:-0}" == "1" ]]; then hash="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; else hash="$(< "${SYSTEM_ROOT}/asset-sha")"; fi
        asset="$(sed -n 's|.*/rfw-\([^/]*\)$|rfw-\1|p' "$MOCK_LOG" | tail -n 1)"
        printf '%s  %s\n' "$hash" "$asset" > "$output"
        ;;
    */rfw-*)
        cat > "$output" <<'BIN'
#!/usr/bin/env bash
printf 'binary %s\n' "${1:-none}" >> "${MOCK_LOG}"
if [[ "${1:-}" == "--version" ]]; then printf 'rfw %s\n' "${MOCK_BINARY_VERSION:-1.2.3}"; exit 0; fi
printf 'mock-rfw'
printf ' %s' "$@"
printf '\n'
BIN
        /usr/bin/sha256sum "$output" | sed 's/[[:space:]].*//' > "${SYSTEM_ROOT}/asset-sha"
        ;;
    *) exit 22 ;;
esac
EOF

    cat >"${MOCK_BIN}/sha256sum" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/sha256sum "$@"
EOF

    cat >"${MOCK_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
{
    printf 'systemctl'
    printf ' %s' "$@"
    printf '\n'
} >> "$MOCK_LOG"
case "${1:-}" in
    is-active)
        if [[ "${MOCK_ACTIVE:-}" == "1" || -e "${SYSTEM_ROOT}/service-active" ]]; then
            [[ "${2:-}" == "--quiet" ]] || printf 'active\n'
            exit 0
        fi
        [[ "${2:-}" == "--quiet" ]] || printf 'inactive\n'
        exit 3
        ;;
    is-enabled)
        if [[ "${MOCK_WAS_ENABLED:-0}" == "1" || -e "${SYSTEM_ROOT}/service-enabled" ]]; then
            [[ "${2:-}" == "--quiet" ]] || printf 'enabled\n'
            exit 0
        fi
        [[ "${2:-}" == "--quiet" ]] || printf 'disabled\n'
        exit 1
        ;;
    start)
        if [[ "${MOCK_START_FAIL:-0}" == "1" ]]; then exit 1; fi
        : > "${SYSTEM_ROOT}/service-active"
        ;;
    stop) rm -f "${SYSTEM_ROOT}/service-active" ;;
    enable)
        : > "${SYSTEM_ROOT}/service-enabled"
        [[ "${MOCK_ENABLE_FAIL:-0}" == "1" ]] && exit 1
        exit 0
        ;;
    disable) rm -f "${SYSTEM_ROOT}/service-enabled" ;;
    restart)
        if [[ "${MOCK_RESTART_FAIL_ONCE:-0}" == "1" && ! -e "${SYSTEM_ROOT}/restart-failed" ]]; then
            : > "${SYSTEM_ROOT}/restart-failed"
            [[ "${MOCK_RESTART_LEAVES_INACTIVE:-0}" != "1" ]] || rm -f "${SYSTEM_ROOT}/service-active"
            exit 1
        fi
        : > "${SYSTEM_ROOT}/service-active"
        ;;
esac
EOF

    cat >"${MOCK_BIN}/journalctl" <<'EOF'
#!/usr/bin/env bash
{
    printf 'journalctl'
    printf ' %s' "$@"
    printf '\n'
} >> "$MOCK_LOG"
EOF

    cat >"${MOCK_BIN}/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

    cat >"${MOCK_BIN}/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "${MOCK_BPFFS:-1}" == "1" ]]
EOF

    cat >"${MOCK_BIN}/mv" <<'EOF'
#!/usr/bin/env bash
target="${@: -1}"
if [[ -n "${MOCK_FAIL_TARGET:-}" && "$target" == *"${MOCK_FAIL_TARGET}" && ! -e "${SYSTEM_ROOT}/mv-failed-once" ]]; then
    : > "${SYSTEM_ROOT}/mv-failed-once"
    exit 1
fi
exec /usr/bin/mv "$@"
EOF

    chmod +x "${MOCK_BIN}"/*
}

reset_case() {
    rm -rf -- "$SYSTEM_ROOT"
    mkdir -p -- "$SYSTEM_ROOT"
    : >"$MOCK_LOG"
}

rfw() {
    local -a shell_args=()
    [[ "${RFW_INNER_XTRACE:-0}" == "1" ]] && shell_args=(-x)
    PATH="${MOCK_BIN}:$PATH" \
        VPSCTL_PROJECT_ROOT="$TEST_ROOT" \
        VPSCTL_TESTING=1 \
        VPSCTL_SYSTEM_ROOT="$SYSTEM_ROOT" \
        VPSCTL_ENV_KERNEL_NAME="${MOCK_KERNEL:-Linux}" \
        VPSCTL_ENV_KERNEL_RELEASE="${MOCK_KERNEL_RELEASE:-6.1.0}" \
        VPSCTL_ENV_ARCH="${MOCK_ARCH:-x86_64}" \
        VPSCTL_ENV_INIT=systemd \
        VPSCTL_NON_INTERACTIVE=1 \
        VPSCTL_NO_COLOR=1 \
        MOCK_FAIL_TARGET="${MOCK_FAIL_TARGET:-}" \
        MOCK_ENABLE_FAIL="${MOCK_ENABLE_FAIL:-0}" \
        MOCK_START_FAIL="${MOCK_START_FAIL:-0}" \
        MOCK_RESTART_FAIL_ONCE="${MOCK_RESTART_FAIL_ONCE:-0}" \
        MOCK_RESTART_LEAVES_INACTIVE="${MOCK_RESTART_LEAVES_INACTIVE:-0}" \
        MOCK_ACTIVE="${MOCK_ACTIVE:-}" \
        MOCK_WAS_ENABLED="${MOCK_WAS_ENABLED:-0}" \
        MOCK_BPFFS="${MOCK_BPFFS:-1}" \
        MOCK_INTERFACE_MISSING="${MOCK_INTERFACE_MISSING:-0}" \
        MOCK_BAD_CHECKSUM="${MOCK_BAD_CHECKSUM:-0}" \
        MOCK_DRAFT="${MOCK_DRAFT:-false}" \
        MOCK_PRERELEASE="${MOCK_PRERELEASE:-false}" \
        MOCK_RELEASE_TAG="${MOCK_RELEASE_TAG:-v1.2.3}" \
        MOCK_BINARY_VERSION="${MOCK_BINARY_VERSION:-1.2.3}" \
        bash "${shell_args[@]}" "$RFW_SCRIPT" "$@"
}

test_architecture_and_install() {
    local status=0
    reset_case
    MOCK_ARCH=x86_64 rfw install
    assert_file_contains "$MOCK_LOG" "rfw-x86_64-unknown-linux-musl" "x86_64 asset mapping"
    [[ "$(grep -Fc 'curl-args -fsSL --proto =https --proto-redir =https' "$MOCK_LOG")" == "3" ]] || fail "RFW downloads were not restricted to HTTPS redirects"
    [[ -x "${SYSTEM_ROOT}/usr/local/bin/rfw" ]] || fail "installed binary is not executable"
    [[ -f "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/install.meta" ]] || fail "install metadata missing"

    reset_case
    MOCK_ARCH=aarch64 rfw install
    assert_file_contains "$MOCK_LOG" "rfw-aarch64-unknown-linux-musl" "aarch64 asset mapping"

    reset_case
    MOCK_ARCH=i686 rfw install >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "unsupported architecture"
    [[ ! -e "${SYSTEM_ROOT}/usr/local/bin/rfw" ]] || fail "unsupported architecture wrote a binary"
}

test_default_config_unit_and_pending() {
    local config unit
    reset_case
    rfw install
    : >"$MOCK_LOG"
    rfw install
    if grep -Fq '^curl ' "$MOCK_LOG"; then fail "idempotent install fetched or rewrote release"; fi
    config="${SYSTEM_ROOT}/etc/vpsctl/rfw.conf"
    unit="${SYSTEM_ROOT}/etc/systemd/system/rfw.service"
    assert_file_contains "$config" "interface=ens3" "default interface"
    assert_file_contains "$config" "fet=off" "safe default FET"
    assert_file_contains "$config" "block_all=off" "safe block-all default"
    assert_file_contains "$config" "block_http=off" "safe default HTTP rule"
    assert_file_contains "$config" "log=off" "safe default logging"
    assert_file_contains "$unit" "ExecStart=/usr/local/bin/rfw --iface ens3 --xdp-mode auto" "fixed ExecStart"
    if grep -Fq -- "--block-" "$unit" || grep -Fq -- "--log-port-access" "$unit"; then
        fail "safe default unit unexpectedly enabled filtering or logging"
    fi
    assert_file_contains "$unit" "KillSignal=SIGINT" "graceful systemd stop"
    assert_file_contains "$unit" "LimitMEMLOCK=infinity" "memlock limit"
    assert_file_contains "$unit" "After=network-online.target" "network ordering"
    assert_file_contains "$unit" "Restart=on-failure" "restart policy"
    [[ ! -e "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending" ]] || fail "install wrote state beyond binary/config/unit"
    if grep -Fq "systemctl start" "$MOCK_LOG" || grep -Fq "systemctl enable" "$MOCK_LOG"; then
        fail "install changed service state"
    fi
}

test_config_parser_and_preservation() {
    local config unit status=0
    reset_case
    rfw install
    config="${SYSTEM_ROOT}/etc/vpsctl/rfw.conf"
    unit="${SYSTEM_ROOT}/etc/systemd/system/rfw.service"
    rfw configure --geo-mode whitelist --countries us,jp --block-http off --fet loose --xdp-mode skb --log-port-access off
    assert_file_contains "$config" "interface=ens3" "configure preserved interface"
    assert_file_contains "$config" "countries=US,JP" "countries normalization"
    assert_file_contains "$config" "block_email=off" "configure preserved unspecified switch"
    assert_file_contains "$unit" "--allow-only-countries US,JP" "whitelist unit mapping"
    assert_file_contains "$unit" "--block-fet-loose" "loose FET unit mapping"
    if grep -Fq -- "--block-http" "$unit"; then fail "disabled HTTP rule remained in unit"; fi
    [[ -f "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending" ]] || fail "configure did not create pending marker"

    printf 'BAD=$(touch /tmp/should-not-run)\n' >>"$config"
    status=0
    rfw configure --block-http on >/dev/null 2>&1 || status=$?
    assert_status 10 "$status" "invalid configuration exit code"
    status=0
    rfw status >/dev/null 2>&1 || status=$?
    assert_status 0 "$status" "status handles invalid configuration"
    output="$(rfw status)"
    assert_contains "$output" "Config:    invalid" "strict parser rejection"

    reset_case
    rfw install
    config="${SYSTEM_ROOT}/etc/vpsctl/rfw.conf"
    sed -i '/^block_quic=/d' "$config"
    status=0
    rfw configure --block-http on >/dev/null 2>&1 || status=$?
    assert_status 10 "$status" "missing configuration key rejection"
    reset_case
    rfw install
    status=0
    rfw configure --geo-mode blocklist --countries ZZ >/dev/null 2>&1 || status=$?
    assert_status 10 "$status" "non-ISO country code rejection"
}

test_checksum_failure() {
    local status=0
    reset_case
    MOCK_BAD_CHECKSUM=1 rfw install >/dev/null 2>&1 || status=$?
    assert_status 20 "$status" "checksum mismatch status"
    [[ ! -e "${SYSTEM_ROOT}/usr/local/bin/rfw" ]] || fail "checksum failure installed binary"
}

test_update_preserves_state_without_restart() {
    local config before after pending_before pending_after curl_after
    local -a backups=()
    reset_case
    rfw install
    config="${SYSTEM_ROOT}/etc/vpsctl/rfw.conf"
    before="$(sha256sum "$config")"
    : >"$MOCK_LOG"
    rfw update --force
    after="$(sha256sum "$config")"
    [[ "$before" == "$after" ]] || fail "update changed the existing configuration"
    [[ -f "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending" ]] || fail "update did not create pending marker"
    shopt -s nullglob
    backups=("${SYSTEM_ROOT}"/var/lib/vpsctl/backups/network/rfw/*/rfw)
    shopt -u nullglob
    ((${#backups[@]} >= 1)) || fail "update did not preserve the old binary"
    if grep -Fq "systemctl restart" "$MOCK_LOG" || grep -Fq "systemctl start" "$MOCK_LOG"; then
        fail "update started or restarted the service"
    fi
    pending_before="$(/usr/bin/sha256sum "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending")"
    rfw configure --block-http off
    pending_after="$(/usr/bin/sha256sum "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending")"
    [[ "$pending_before" == "$pending_after" ]] || fail "no-op configure changed existing update pending state"
    : >"$MOCK_LOG"
    rfw update
    curl_after="$(grep -c '^curl ' "$MOCK_LOG" || true)"
    [[ "$curl_after" == "3" ]] || fail "current-version update did not perform exactly one verification fetch"
    [[ "$pending_before" == "$(/usr/bin/sha256sum "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending")" ]] || fail "no-op update changed pending state"
}

test_dry_run_has_no_managed_writes() {
    local binary
    reset_case
    binary="${SYSTEM_ROOT}/usr/local/bin/rfw"
    mkdir -p "$(dirname -- "$binary")"
    printf 'foreign\n' >"$binary"
    rfw --dry-run install
    assert_file_contains "$binary" "foreign" "dry-run overwrote unmanaged binary"
    [[ ! -e "${SYSTEM_ROOT}/etc/vpsctl/rfw.conf" ]] || fail "dry-run wrote configuration"
    [[ ! -e "${SYSTEM_ROOT}/etc/systemd/system/rfw.service" ]] || fail "dry-run wrote a unit"

    reset_case
    rfw install
    rfw configure --fet strict
    rfw --dry-run start
    [[ ! -e "${SYSTEM_ROOT}/service-active" ]] || fail "dry-run started service"
    rfw --dry-run uninstall --purge
    [[ -e "${SYSTEM_ROOT}/usr/local/bin/rfw" ]] || fail "dry-run purge removed binary"
}

test_managed_ancestor_symlink_guard() {
    local outside_usr="${TEST_TMP}/outside-rfw-usr"
    local status=0

    reset_case
    mkdir -p -- "$outside_usr"
    if ln -s "$outside_usr" "${SYSTEM_ROOT}/usr" 2>/dev/null && [[ -L "${SYSTEM_ROOT}/usr" ]]; then
        rfw --dry-run install --force >/dev/null 2>&1 || status=$?
        assert_status 3 "$status" "managed RFW ancestor symlink rejection"
        [[ ! -e "${outside_usr}/local/bin/rfw" ]] || fail "RFW write escaped through an ancestor symlink"
        unlink -- "${SYSTEM_ROOT}/usr" 2>/dev/null || rmdir -- "${SYSTEM_ROOT}/usr"
    fi
}

test_global_options_and_release_validation() {
    local output status=0
    reset_case
    output="$(rfw --quiet --verbose --non-interactive status)"
    assert_contains "$output" "RFW status" "global options before action"
    rfw -- --not-an-action >/dev/null 2>&1 || status=$?
    assert_status 2 "$status" "global option delimiter"
    status=0
    rfw --help extra >/dev/null 2>&1 || status=$?
    assert_status 2 "$status" "global help extra argument rejection"

    reset_case
    status=0
    MOCK_DRAFT=true rfw install >/dev/null 2>&1 || status=$?
    assert_status 20 "$status" "draft release rejection"
    reset_case
    status=0
    MOCK_PRERELEASE=true rfw install >/dev/null 2>&1 || status=$?
    assert_status 20 "$status" "prerelease rejection"
    reset_case
    status=0
    MOCK_RELEASE_TAG=v1.2.3-rc.1 rfw install >/dev/null 2>&1 || status=$?
    assert_status 20 "$status" "unstable tag rejection"
    reset_case
    status=0
    MOCK_BINARY_VERSION=9.9.9 rfw install >/dev/null 2>&1 || status=$?
    assert_status 20 "$status" "release/binary version mismatch"
    reset_case
    rfw install
    assert_file_contains "$MOCK_LOG" "binary --version" "downloaded binary smoke test"
}

test_runtime_preconditions() {
    local status=0
    reset_case
    rfw install
    rfw start >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "empty policy start rejection"

    rfw configure --block-http on
    status=0
    MOCK_KERNEL_RELEASE=5.14.99 rfw start >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "old kernel rejection"
    MOCK_KERNEL_RELEASE=5.15.0 rfw start
    rfw stop
    status=0
    MOCK_INTERFACE_MISSING=1 rfw start >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "missing interface rejection"
    rfw configure --log-port-access on
    status=0
    MOCK_BPFFS=0 rfw start >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "missing bpffs rejection"
}

test_managed_boundaries_and_stats_guards() {
    local status=0 output unit binary config
    reset_case
    unit="${SYSTEM_ROOT}/etc/systemd/system/rfw.service"
    binary="${SYSTEM_ROOT}/usr/local/bin/rfw"
    config="${SYSTEM_ROOT}/etc/vpsctl/rfw.conf"
    mkdir -p "$(dirname -- "$unit")" "$(dirname -- "$binary")"
    printf '[Unit]\nDescription=foreign\n' >"$unit"
    cat >"$binary" <<'EOF'
#!/usr/bin/env bash
printf 'UNMANAGED-EXECUTED\n' >> "$MOCK_LOG"
EOF
    chmod +x "$binary"
    output="$(rfw status)"
    assert_contains "$output" "not installed or unmanaged" "unmanaged status label"
    if grep -Fq "UNMANAGED-EXECUTED" "$MOCK_LOG"; then fail "status executed unmanaged binary"; fi
    status=0
    rfw configure --block-http on >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "configure without managed install"

    reset_case
    rfw install
    cat >"$binary" <<'EOF'
#!/usr/bin/env bash
printf 'TAMPERED-EXECUTED\n' >> "$MOCK_LOG"
EOF
    chmod +x "$binary"
    output="$(rfw status)"
    assert_contains "$output" "not installed or unmanaged" "tampered binary status label"
    if grep -Fq "TAMPERED-EXECUTED" "$MOCK_LOG"; then fail "status executed checksum-mismatched binary"; fi
    rfw install --force
    output="$(rfw status)"
    assert_contains "$output" "Version:   rfw 1.2.3 [v1.2.3]" "forced repair of a tampered managed binary"
    reset_case
    rfw install
    status=0
    rfw stats --ip 192.0.2.1 >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "stats log-off guard"
    rfw configure --log-port-access on
    status=0
    rfw stats --ip 192.0.2.1 >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "stats inactive-service guard"
    rfw start
    status=0
    rfw stats --ip 999.1.2.3 >/dev/null 2>&1 || status=$?
    assert_status 2 "$status" "stats strict IPv4 validation"

    rfw stop
    rm -f "$config"
    mkdir -p "$(dirname -- "$config")"
    if ln -s /tmp/foreign-rfw-config "$config" 2>/dev/null; then
        status=0
        rfw configure --block-http on >/dev/null 2>&1 || status=$?
        assert_status 3 "$status" "configure config-symlink boundary"
    fi
}

test_start_order_failure_and_pending_rollback() {
    local status=0 config start_line enable_line pending
    reset_case
    rfw install
    rfw configure --block-http on
    : >"$MOCK_LOG"
    rfw start --enable
    start_line="$(grep -n 'systemctl start rfw.service' "$MOCK_LOG" | head -n 1 | cut -d: -f1)"
    enable_line="$(grep -n 'systemctl enable rfw.service' "$MOCK_LOG" | head -n 1 | cut -d: -f1)"
    ((start_line < enable_line)) || fail "start --enable enabled before active start"
    : >"$MOCK_LOG"
    rfw start --enable
    if grep -Fq "systemctl start rfw.service" "$MOCK_LOG"; then fail "idempotent active start invoked systemctl start"; fi
    rfw configure --block-quic on
    status=0
    rfw start >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "active service with pending start rejection"
    rfw restart
    rfw stop --disable

    status=0
    MOCK_ENABLE_FAIL=1 rfw start --enable >/dev/null 2>&1 || status=$?
    assert_status 20 "$status" "enable failure status"
    [[ ! -e "${SYSTEM_ROOT}/service-active" ]] || fail "enable failure left service active"
    [[ ! -e "${SYSTEM_ROOT}/service-enabled" ]] || fail "enable failure left new enable state"

    rfw start
    rfw stop
    rfw configure --block-http off --block-quic on
    config="${SYSTEM_ROOT}/etc/vpsctl/rfw.conf"
    status=0
    MOCK_START_FAIL=1 rfw start >/dev/null 2>&1 || status=$?
    assert_status 20 "$status" "pending start failure status"
    [[ ! -e "${SYSTEM_ROOT}/service-active" ]] || fail "failed pending start did not remain stopped"
    assert_file_contains "$config" "block_http=on" "start rollback restored successful config"

    rfw configure --block-quic off
    pending="${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending"
    sed -i 's|^binary_backup=.*|binary_backup=/tmp/unsafe-rfw|' "$pending"
    status=0
    rfw start >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "unsafe pending backup rejection"
}

test_transaction_rollbacks() {
    local status=0 config binary old_hash new_hash
    reset_case
    status=0
    MOCK_FAIL_TARGET=rfw.service rfw install >/dev/null 2>&1 || status=$?
    assert_status 20 "$status" "install transaction failure status"
    [[ ! -e "${SYSTEM_ROOT}/usr/local/bin/rfw" ]] || fail "failed install left binary"
    [[ ! -e "${SYSTEM_ROOT}/etc/vpsctl/rfw.conf" ]] || fail "failed install left config"

    reset_case
    rfw install
    config="${SYSTEM_ROOT}/etc/vpsctl/rfw.conf"
    old_hash="$(/usr/bin/sha256sum "$config")"
    status=0
    MOCK_FAIL_TARGET=rfw.service rfw configure --block-http on >/dev/null 2>&1 || status=$?
    assert_status 20 "$status" "configure transaction failure status"
    new_hash="$(/usr/bin/sha256sum "$config")"
    [[ "$old_hash" == "$new_hash" ]] || fail "configure failure did not restore configuration"

    reset_case
    rfw install
    status=0
    MOCK_RELEASE_TAG=v1.2.4 MOCK_BINARY_VERSION=1.2.4 MOCK_FAIL_TARGET=pending rfw update --force >/dev/null 2>&1 || status=$?
    assert_status 20 "$status" "update pending transaction failure status"
    assert_file_contains "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/install.meta" "tag=v1.2.3" "update failure restored old metadata"
}

test_disruptive_confirmation_and_service_flags() {
    local status=0
    reset_case
    rfw install
    rfw configure --fet strict
    VPSCTL_ASSUME_YES=1 rfw start --enable >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "--yes bypassed disruptive confirmation"
    rfw start --enable --confirm-disruptive
    assert_file_contains "$MOCK_LOG" "systemctl enable rfw.service" "start --enable"
    assert_file_contains "$MOCK_LOG" "systemctl start rfw.service" "service start"
    [[ ! -e "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending" ]] || fail "successful start did not clear pending"
    rfw stop --disable
    assert_file_contains "$MOCK_LOG" "systemctl disable rfw.service" "stop --disable"
}

test_restart_rollback() {
    local status=0 config
    reset_case
    rfw install
    rfw configure --block-http on
    rfw start --confirm-disruptive
    rfw configure --block-http off --block-quic on
    config="${SYSTEM_ROOT}/etc/vpsctl/rfw.conf"
    assert_file_contains "$config" "block_http=off" "pending config before rollback"
    MOCK_RESTART_FAIL_ONCE=1 rfw restart --confirm-disruptive >/dev/null 2>&1 || status=$?
    assert_status 20 "$status" "failed restart status"
    assert_file_contains "$config" "block_http=on" "last-known-good config rollback"
    [[ ! -e "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending" ]] || fail "rollback left stale pending marker"

    status=0
    rm -f "${SYSTEM_ROOT}/restart-failed"
    MOCK_RESTART_FAIL_ONCE=1 MOCK_RESTART_LEAVES_INACTIVE=1 rfw restart >/dev/null 2>&1 || status=$?
    assert_status 30 "$status" "restart without pending left inactive"
}

test_stats_logs_status_and_ipv6_warning() {
    local output
    reset_case
    rfw install
    rfw configure --log-port-access on
    rfw start
    output="$(rfw stats --port 443 --blocked-only --group-by-port)"
    assert_contains "$output" "stats --port 443 --blocked-only --group-by-port" "stats argument mapping"
    rfw logs --lines 25 --since today
    assert_file_contains "$MOCK_LOG" "journalctl -u rfw.service --no-pager -n 25 --since today" "journal mapping"
    mkdir -p "${SYSTEM_ROOT}/proc/net"
    printf 'ipv6-present\n' >"${SYSTEM_ROOT}/proc/net/if_inet6"
    output="$(rfw status)"
    assert_contains "$output" "Version:   rfw 1.2.3" "status version"
    assert_contains "$output" "Service:   active" "status service"
    assert_contains "$output" "Autostart: disabled" "status autostart"
    assert_contains "$output" "IPv4 only" "IPv6 warning"
}

test_uninstall_boundaries() {
    local status=0 config unit binary
    reset_case
    rfw install
    config="${SYSTEM_ROOT}/etc/vpsctl/rfw.conf"
    unit="${SYSTEM_ROOT}/etc/systemd/system/rfw.service"
    binary="${SYSTEM_ROOT}/usr/local/bin/rfw"
    mkdir -p "${SYSTEM_ROOT}/var/lib/vpsctl/backups/network/rfw/manual"
    printf 'backup\n' >"${SYSTEM_ROOT}/var/lib/vpsctl/backups/network/rfw/manual/rfw"
    rfw update --force
    rfw uninstall
    [[ -f "$config" ]] || fail "default uninstall removed configuration"
    [[ ! -e "$unit" && ! -e "$binary" ]] || fail "default uninstall retained binary or unit"
    [[ -e "${SYSTEM_ROOT}/var/lib/vpsctl/backups/network/rfw/manual/rfw" ]] || fail "default uninstall removed backups"
    [[ -e "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/install.meta" ]] || fail "default uninstall removed metadata state"
    [[ -e "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending" ]] || fail "default uninstall removed pending state"
    rfw uninstall
    rfw uninstall --purge --confirm-purge
    [[ ! -e "$config" ]] || fail "purge retained configuration"
    [[ ! -e "${SYSTEM_ROOT}/var/lib/vpsctl/backups/network/rfw" ]] || fail "purge retained RFW backups"

    reset_case
    mkdir -p "$(dirname -- "$unit")" "$(dirname -- "$binary")"
    printf '[Unit]\nDescription=foreign\n' >"$unit"
    printf '#!/usr/bin/env bash\n' >"$binary"
    chmod +x "$binary"
    rfw uninstall >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "unmanaged unit uninstall boundary"
    [[ -e "$unit" && -e "$binary" ]] || fail "uninstall removed unmanaged files"
}

write_mocks
if [[ -n "${RFW_TEST_ONLY:-}" ]]; then
    "$RFW_TEST_ONLY"
    printf 'PASS: %s\n' "$RFW_TEST_ONLY"
    exit 0
fi
test_architecture_and_install
test_default_config_unit_and_pending
test_config_parser_and_preservation
test_checksum_failure
test_update_preserves_state_without_restart
test_dry_run_has_no_managed_writes
test_managed_ancestor_symlink_guard
test_global_options_and_release_validation
test_runtime_preconditions
test_managed_boundaries_and_stats_guards
test_disruptive_confirmation_and_service_flags
test_start_order_failure_and_pending_rollback
test_restart_rollback
test_transaction_rollbacks
test_stats_logs_status_and_ipv6_warning
test_uninstall_boundaries
printf 'PASS: network rfw tests\n'
