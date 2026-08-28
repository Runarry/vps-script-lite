#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly RFW_SCRIPT="${TEST_ROOT}/commands/network/rfw.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-rfw-test.XXXXXX")"
readonly TEST_ROOT TEST_TMP
readonly MOCK_BIN="${TEST_TMP}/mock-bin"
readonly NO_DOWNLOAD_DEPS_BIN="${TEST_TMP}/no-download-deps-bin"
readonly NO_RUNTIME_DEPS_BIN="${TEST_TMP}/no-runtime-deps-bin"
readonly SYSTEM_ROOT="${TEST_TMP}/system-root"
readonly MOCK_LOG="${TEST_TMP}/mock.log"
readonly TEST_BASH="$(command -v bash)"
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

assert_not_contains() {
    local value="$1" unexpected="$2" message="$3"
    [[ "$value" != *"$unexpected"* ]] || fail "${message}: unexpectedly found '${unexpected}'"
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
    local command_name command_path limited_path
    mkdir -p -- "$MOCK_BIN" "$NO_DOWNLOAD_DEPS_BIN" "$NO_RUNTIME_DEPS_BIN" "$SYSTEM_ROOT"

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

    cat >"${MOCK_BIN}/apt-get" <<'EOF'
#!/usr/bin/env bash
{
    printf 'apt-get'
    printf ' %s' "$@"
    printf '\n'
} >> "$MOCK_LOG"
EOF

    chmod +x "${MOCK_BIN}"/*

    for limited_path in "$NO_DOWNLOAD_DEPS_BIN" "$NO_RUNTIME_DEPS_BIN"; do
        ln -s "$TEST_BASH" "${limited_path}/bash"
        for command_name in dirname readlink sed; do
            command_path="$(command -v "$command_name")"
            ln -s "$command_path" "${limited_path}/${command_name}"
        done
        ln -s "${MOCK_BIN}/systemctl" "${limited_path}/systemctl"
        ln -s "${MOCK_BIN}/apt-get" "${limited_path}/apt-get"
    done
    for command_name in flock mountpoint; do
        ln -s "${MOCK_BIN}/${command_name}" "${NO_DOWNLOAD_DEPS_BIN}/${command_name}"
    done
    ln -s "${MOCK_BIN}/sha256sum" "${NO_RUNTIME_DEPS_BIN}/sha256sum"
    ln -s "${MOCK_BIN}/flock" "${NO_RUNTIME_DEPS_BIN}/flock"
}

reset_case() {
    rm -rf -- "$SYSTEM_ROOT"
    mkdir -p -- "$SYSTEM_ROOT"
    : >"$MOCK_LOG"
}

rfw() {
    local -a shell_args=()
    [[ "${RFW_INNER_XTRACE:-0}" == "1" ]] && shell_args=(-x)
    PATH="${RFW_TEST_PATH:-${MOCK_BIN}:$PATH}" \
        VPSCTL_PROJECT_ROOT="$TEST_ROOT" \
        VPSCTL_TESTING=1 \
        VPSCTL_SYSTEM_ROOT="$SYSTEM_ROOT" \
        VPSCTL_ENV_KERNEL_NAME="${MOCK_KERNEL:-Linux}" \
        VPSCTL_ENV_KERNEL_RELEASE="${MOCK_KERNEL_RELEASE:-6.1.0}" \
        VPSCTL_ENV_ARCH="${MOCK_ARCH:-x86_64}" \
        VPSCTL_ENV_INIT="${MOCK_INIT:-systemd}" \
        VPSCTL_ENV_PACKAGE_MANAGER="${MOCK_PACKAGE_MANAGER:-}" \
        VPSCTL_INSTALL_DEPS="${MOCK_INSTALL_DEPS:-0}" \
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
        "$TEST_BASH" "${shell_args[@]}" "$RFW_SCRIPT" "$@"
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
    assert_file_contains "$unit" "Description=RFW eBPF/XDP 防火墙" "localized systemd description"
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
    assert_contains "$output" "配置" "strict parser status label"
    assert_contains "$output" "无效" "strict parser rejection"

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
    output="$(rfw --quiet --verbose --non-interactive --no-color status)"
    assert_contains "$output" "RFW 状态" "global options before action"
    [[ "$output" != *$'\033['* ]] || fail "non-TTY status emitted ANSI color"
    output="$(rfw help)"
    assert_contains "$output" "管理 narwhal-cloud/rfw XDP 防火墙" "localized help summary"
    assert_contains "$output" "全局选项" "localized global-options heading"
    assert_contains "$output" "--install-deps" "install-deps help option"
    output="$(rfw --install-deps status)"
    assert_contains "$output" "RFW 状态" "install-deps direct global option"
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

test_kernel_version_parsing() (
    local release output status
    local -a supported_releases=(
        "6.12.105+deb13-amd64"
        "6.12.105+deb13"
        "6.8.0-31-generic"
        "5.15.0-1-amd64"
        "6.1.0"
    )
    local -a invalid_releases=(
        "not-a-version"
        "6.x.1"
        "6.12.105 deb13"
    )

    reset_case
    VPSCTL_PROJECT_ROOT="$TEST_ROOT"
    VPSCTL_TESTING=1
    VPSCTL_SYSTEM_ROOT="$SYSTEM_ROOT"
    VPSCTL_ENV_KERNEL_NAME=Linux
    VPSCTL_ENV_KERNEL_RELEASE=6.1.0
    VPSCTL_ENV_ARCH=x86_64
    VPSCTL_ENV_INIT=systemd
    VPSCTL_NON_INTERACTIVE=1
    VPSCTL_NO_COLOR=1
    export VPSCTL_PROJECT_ROOT VPSCTL_TESTING VPSCTL_SYSTEM_ROOT
    export VPSCTL_ENV_KERNEL_NAME VPSCTL_ENV_KERNEL_RELEASE VPSCTL_ENV_ARCH VPSCTL_ENV_INIT
    export VPSCTL_NON_INTERACTIVE VPSCTL_NO_COLOR
    # shellcheck source=../../commands/network/rfw.sh
    source "$RFW_SCRIPT" help >/dev/null

    for release in "${supported_releases[@]}"; do
        VPSCTL_ENV_KERNEL_RELEASE="$release"
        rfw_kernel_supported || fail "supported kernel release rejected: ${release}"
    done

    VPSCTL_ENV_KERNEL_RELEASE="5.14.99+deb13-amd64"
    status=0
    output="$(rfw_kernel_supported 2>&1)" || status=$?
    assert_status 3 "$status" "old Debian kernel rejection"
    assert_contains "$output" "当前 5.14.99+deb13-amd64" "old Debian kernel error retained full release"

    for release in "${invalid_releases[@]}"; do
        VPSCTL_ENV_KERNEL_RELEASE="$release"
        status=0
        output="$(rfw_kernel_supported 2>&1)" || status=$?
        assert_status 3 "$status" "invalid kernel release rejection: ${release}"
        assert_contains "$output" "无法验证内核版本：${release}" "invalid kernel error retained full release: ${release}"
    done
)

test_dependency_install_controls() {
    local output status=0 config_hash pending_hash

    reset_case
    output="$(RFW_TEST_PATH="$NO_DOWNLOAD_DEPS_BIN" rfw install 2>&1)" || status=$?
    assert_status 3 "$status" "install missing download tools without authorization"
    assert_contains "$output" "--install-deps" "missing download tools authorization hint"
    [[ "$(grep -o -- '--install-deps' <<<"$output" | wc -l)" == "1" ]] || fail "missing dependency guidance was duplicated"
    assert_not_contains "$output" "apt-get" "unauthorized dependency installation"
    [[ ! -e "${SYSTEM_ROOT}/usr/local/bin/rfw" ]] || fail "missing tools install wrote binary"
    [[ ! -e "${SYSTEM_ROOT}/etc/vpsctl/rfw.conf" ]] || fail "missing tools install wrote configuration"

    reset_case
    status=0
    output="$(RFW_TEST_PATH="$NO_DOWNLOAD_DEPS_BIN" MOCK_PACKAGE_MANAGER=apt-get rfw --dry-run --install-deps install 2>&1)" || status=$?
    assert_status 0 "$status" "authorized dry-run dependency plan"
    assert_contains "$output" "apt-get update" "fixed apt dependency refresh plan"
    assert_contains "$output" "apt-get install -y --no-install-recommends curl coreutils" "fixed apt download dependency plan"
    assert_contains "$output" "iproute2" "install default-interface dependency plan"
    assert_contains "$output" "安装依赖后重新运行" "dependency plan rerun guidance"
    assert_not_contains "$(<"$MOCK_LOG")" "curl " "dependency-only plan downloaded release"
    [[ ! -e "${SYSTEM_ROOT}/usr/local/bin/rfw" ]] || fail "dependency-only plan wrote binary"
    [[ ! -e "${SYSTEM_ROOT}/etc/vpsctl/rfw.conf" ]] || fail "dependency-only plan wrote configuration"
    [[ ! -e "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw" ]] || fail "dependency-only plan wrote managed state"

    reset_case
    status=0
    output="$(RFW_TEST_PATH="$NO_DOWNLOAD_DEPS_BIN" MOCK_PACKAGE_MANAGER=apt-get MOCK_INIT=openrc rfw --dry-run --install-deps install 2>&1)" || status=$?
    assert_status 3 "$status" "non-systemd dependency gate"
    assert_not_contains "$output" "apt-get" "non-systemd attempted dependency installation"

    reset_case
    status=0
    output="$(RFW_TEST_PATH="$NO_DOWNLOAD_DEPS_BIN" MOCK_PACKAGE_MANAGER=apt-get MOCK_ARCH=i686 rfw --dry-run --install-deps install 2>&1)" || status=$?
    assert_status 3 "$status" "unsupported architecture dependency gate"
    assert_not_contains "$output" "apt-get" "unsupported architecture attempted dependency installation"

    reset_case
    status=0
    output="$(RFW_TEST_PATH="$NO_DOWNLOAD_DEPS_BIN" MOCK_PACKAGE_MANAGER=apt-get MOCK_KERNEL_RELEASE=5.14.0 rfw --dry-run --install-deps install 2>&1)" || status=$?
    assert_status 3 "$status" "old kernel dependency gate"
    assert_not_contains "$output" "apt-get" "old kernel attempted dependency installation"

    reset_case
    rfw install
    rfw configure --block-http on --log-port-access on
    config_hash="$(/usr/bin/sha256sum "${SYSTEM_ROOT}/etc/vpsctl/rfw.conf")"
    pending_hash="$(/usr/bin/sha256sum "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending")"
    : >"$MOCK_LOG"
    status=0
    output="$(RFW_TEST_PATH="$NO_RUNTIME_DEPS_BIN" MOCK_PACKAGE_MANAGER=apt-get rfw --dry-run --install-deps start 2>&1)" || status=$?
    assert_status 0 "$status" "logged start dependency plan"
    assert_contains "$output" "apt-get install -y --no-install-recommends iproute2 util-linux" "logged start ip and mountpoint dependency plan"
    assert_contains "$output" "安装依赖后重新运行" "logged start dependency rerun guidance"
    assert_not_contains "$(<"$MOCK_LOG")" "curl " "logged start dependency plan downloaded release"
    [[ "$config_hash" == "$(/usr/bin/sha256sum "${SYSTEM_ROOT}/etc/vpsctl/rfw.conf")" ]] || fail "logged start dependency plan changed configuration"
    [[ "$pending_hash" == "$(/usr/bin/sha256sum "${SYSTEM_ROOT}/var/lib/vpsctl/network/rfw/pending")" ]] || fail "logged start dependency plan changed pending state"
    [[ ! -e "${SYSTEM_ROOT}/service-active" ]] || fail "logged start dependency plan started service"
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
    assert_contains "$output" "未安装或不受管" "unmanaged status label"
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
    assert_contains "$output" "未安装或不受管" "tampered binary status label"
    if grep -Fq "TAMPERED-EXECUTED" "$MOCK_LOG"; then fail "status executed checksum-mismatched binary"; fi
    rfw install --force
    output="$(rfw status)"
    assert_contains "$output" "rfw 1.2.3 [v1.2.3]" "forced repair of a tampered managed binary"
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
    assert_contains "$output" "rfw 1.2.3" "status version"
    assert_contains "$output" "运行中" "status service"
    assert_contains "$output" "未启用" "status autostart"
    assert_contains "$output" "网卡=ens3" "localized config interface"
    assert_contains "$output" "访问日志=开启" "localized config switch"
    [[ "$output" != *"interface=ens3"* ]] || fail "status leaked English configuration labels"
    assert_contains "$output" "IPv6 流量不受保护" "IPv6 warning"
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

test_interactive_ui() (
    local output capture="${TEST_TMP}/rfw-interactive-output"

    reset_case
    PATH="${MOCK_BIN}:$PATH"
    VPSCTL_PROJECT_ROOT="$TEST_ROOT"
    VPSCTL_TESTING=1
    VPSCTL_SYSTEM_ROOT="$SYSTEM_ROOT"
    VPSCTL_ENV_KERNEL_NAME=Linux
    VPSCTL_ENV_KERNEL_RELEASE=6.1.0
    VPSCTL_ENV_ARCH=x86_64
    VPSCTL_ENV_INIT=systemd
    VPSCTL_NON_INTERACTIVE=0
    VPSCTL_NO_COLOR=1
    export PATH VPSCTL_PROJECT_ROOT VPSCTL_TESTING VPSCTL_SYSTEM_ROOT
    export VPSCTL_ENV_KERNEL_NAME VPSCTL_ENV_KERNEL_RELEASE VPSCTL_ENV_ARCH VPSCTL_ENV_INIT
    export VPSCTL_NON_INTERACTIVE VPSCTL_NO_COLOR
    # shellcheck source=../../commands/network/rfw.sh
    source "$RFW_SCRIPT" help >/dev/null

    vps_cmd_confirm() {
        local prompt="$1" reply
        printf 'CONFIRM:%s\n' "$prompt"
        IFS= read -r reply || return 130
        [[ "$reply" == y ]]
    }

    rfw_defaults
    RFW_CFG[geo_mode]=blocklist
    RFW_CFG[countries]=US
    rfw_configure_wizard <<< $'bad interface\nens5\n1\n2\n\n\n\n\n\n\n2\n3\n5\ny' >"$capture" 2>&1
    output="$(<"$capture")"
    assert_contains "$output" "网络接口格式无效" "wizard interface validation"
    assert_contains "$output" "即将保存的 RFW 配置" "wizard save summary"
    assert_contains "$output" "确认保存以上配置" "wizard summary confirmation"
    [[ "${RFW_CFG[interface]}" == "ens5" ]] || fail "wizard did not save validated interface"
    [[ "${RFW_CFG[geo_mode]}" == "none" && -z "${RFW_CFG[countries]}" ]] || fail "geo none did not clear countries"
    [[ "${RFW_CFG[block_email]}" == "on" ]] || fail "wizard numbered switch selection"
    [[ "${RFW_CFG[fet]}" == "loose" ]] || fail "wizard numbered FET selection"
    [[ "${RFW_CFG[xdp_mode]}" == "drv" ]] || fail "wizard numbered XDP selection"
    [[ "${RFW_CFG[RUST_LOG]}" == "debug" ]] || fail "wizard numbered log-level selection"

    RFW_CFG[countries]=""
    rfw_prompt_countries <<< $'ZZ\nus,ca' >"$capture" 2>&1
    output="$(<"$capture")"
    assert_contains "$output" "ISO 3166-1" "wizard country validation"
    [[ "${RFW_CFG[countries]}" == "US,CA" ]] || fail "wizard did not normalize country codes"

    rfw_service_start() { printf 'start'; printf ' %s' "$@"; printf '\n'; }
    rfw_service_stop() { printf 'stop'; printf ' %s' "$@"; printf '\n'; }
    rfw_stats() { printf 'stats'; printf ' %s' "$@"; printf '\n'; }
    rfw_logs() { printf 'logs'; printf ' %s' "$@"; printf '\n'; }
    rfw_uninstall() { printf 'uninstall'; printf ' %s' "$@"; printf '\n'; }

    output="$(rfw_menu_start <<<2 2>&1)"
    assert_contains "$output" "start --enable" "menu start and enable mapping"
    output="$(rfw_menu_stop <<<2 2>&1)"
    assert_contains "$output" "stop --disable" "menu stop and disable mapping"
    output="$(rfw_menu_stats <<< $'3\n2\n70000\n443\n2\n999.1.2.3\n192.0.2.8\n2' 2>&1)"
    assert_contains "$output" "端口无效" "menu stats port validation"
    assert_contains "$output" "IPv4 地址无效" "menu stats IP validation"
    assert_contains "$output" "stats --allowed-only --port 443 --ip 192.0.2.8 --group-by-port" "menu stats argument mapping"
    output="$(rfw_menu_logs <<< $'5\n1000001\n25\n2\n2\n1 hour ago' 2>&1)"
    assert_contains "$output" "日志行数无效" "menu logs line validation"
    assert_contains "$output" "logs --lines 25 --follow --since 1 hour ago" "menu logs argument mapping"
    output="$(rfw_menu_uninstall <<<2 2>&1)"
    assert_contains "$output" "uninstall --purge" "menu purge mapping"
    assert_not_contains "$output" "--confirm-purge" "menu exposed purge confirmation bypass"

    output="$(rfw_menu <<<q 2>&1)"
    assert_contains "$output" "访问统计" "numbered RFW main menu"
    assert_not_contains "$output" "--force" "menu exposed force option"
    assert_not_contains "$output" "--install-deps" "menu repeated dependency option"
    assert_not_contains "$output" "--confirm" "menu exposed confirmation option"
)

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
test_kernel_version_parsing
test_dependency_install_controls
test_runtime_preconditions
test_managed_boundaries_and_stats_guards
test_disruptive_confirmation_and_service_flags
test_start_order_failure_and_pending_rollback
test_restart_rollback
test_transaction_rollbacks
test_stats_logs_status_and_ipv6_warning
test_uninstall_boundaries
test_interactive_ui
printf 'PASS: network rfw tests\n'
