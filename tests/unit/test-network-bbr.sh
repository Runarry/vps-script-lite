#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
readonly TEST_ROOT TEST_TEMP
readonly TEST_SYSTEM_ROOT="${TEST_TEMP}/system"
readonly TEST_FAKE_BIN="${TEST_TEMP}/bin"
readonly TEST_NO_MODPROBE_BIN="${TEST_TEMP}/bin-no-modprobe"
readonly TEST_BBR="${TEST_ROOT}/commands/network/bbr.sh"
readonly TEST_BASH="$(command -v bash)"
readonly TEST_CAT="$(command -v cat)"
readonly TEST_DIRNAME="$(command -v dirname)"
readonly TEST_BASE64="$(command -v base64)"
trap 'rm -rf -- "$TEST_TEMP"' EXIT

test_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

test_assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$expected" == "$actual" ]] || test_fail "${message}: expected '${expected}', got '${actual}'"
}

test_assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    [[ "$haystack" == *"$needle"* ]] || test_fail "${message}: missing '${needle}'"
}

test_assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local message="$3"
    [[ "$haystack" != *"$needle"* ]] || test_fail "${message}: unexpectedly found '${needle}'"
}

mkdir -p \
    "${TEST_FAKE_BIN}" \
    "${TEST_NO_MODPROBE_BIN}" \
    "${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4" \
    "${TEST_SYSTEM_ROOT}/proc/sys/net/core" \
    "${TEST_SYSTEM_ROOT}/etc/sysctl.d" \
    "${TEST_SYSTEM_ROOT}/etc/modules-load.d"
printf 'cubic\n' >"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control"
printf 'reno cubic bbr\n' >"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_available_congestion_control"
printf 'fq_codel\n' >"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc"
printf 'fq_codel\n' >"${TEST_SYSTEM_ROOT}/tc-root-qdisc"

cat >"${TEST_FAKE_BIN}/sysctl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == "-n" ]]; then
    key="$2"
    path="${VPSCTL_SYSTEM_ROOT}/proc/sys/${key//./\/}"
    [[ -r "$path" ]] || exit 1
    cat "$path"
    exit 0
fi
if [[ "$1" == "-w" ]]; then
    assignment="$2"
    key="${assignment%%=*}"
    value="${assignment#*=}"
    path="${VPSCTL_SYSTEM_ROOT}/proc/sys/${key//./\/}"
    if [[ -f "${VPSCTL_SYSTEM_ROOT}/fail-qdisc" && "$key" == "net.core.default_qdisc" && "$value" == "cake" ]]; then
        exit 20
    fi
    mkdir -p "${path%/*}"
    printf '%s\n' "$value" >"$path"
    printf '%s = %s\n' "$key" "$value"
    exit 0
fi
exit 2
EOF

cat >"${TEST_FAKE_BIN}/modprobe" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${VPSCTL_SYSTEM_ROOT}/modprobe.log"
EOF

cat >"${TEST_FAKE_BIN}/ip" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == "route" ]]; then
    printf 'default via 192.0.2.1 dev eth0 proto static\n'
    exit 0
fi
if [[ "$1" == "link" && "$2" == "show" && "$3" == "dev" && "$4" == "eth0" ]]; then
    [[ ! -f "${VPSCTL_SYSTEM_ROOT}/missing-eth0" ]] || exit 1
    printf '2: eth0: <UP> mtu 1500\n'
    exit 0
fi
exit 2
EOF

cat >"${TEST_FAKE_BIN}/tc" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == "qdisc show dev eth0" ]]; then
    printf 'qdisc %s 0: root refcnt 2\n' "$(<"${VPSCTL_SYSTEM_ROOT}/tc-root-qdisc")"
    exit 0
fi
printf '%s\n' "$*" >>"${VPSCTL_SYSTEM_ROOT}/tc.log"
if [[ "$1" == "qdisc" && "$2" == "replace" ]]; then
    printf '%s\n' "$6" >"${VPSCTL_SYSTEM_ROOT}/tc-root-qdisc"
    if [[ -f "${VPSCTL_SYSTEM_ROOT}/fail-live-qdisc" && "$6" == "fq" ]]; then
        exit 20
    fi
fi
EOF

cat >"${TEST_FAKE_BIN}/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x \
    "${TEST_FAKE_BIN}/sysctl" \
    "${TEST_FAKE_BIN}/modprobe" \
    "${TEST_FAKE_BIN}/ip" \
    "${TEST_FAKE_BIN}/tc" \
    "${TEST_FAKE_BIN}/flock"
ln -s "$TEST_BASH" "${TEST_NO_MODPROBE_BIN}/bash"
ln -s "$TEST_CAT" "${TEST_NO_MODPROBE_BIN}/cat"
ln -s "$TEST_DIRNAME" "${TEST_NO_MODPROBE_BIN}/dirname"
ln -s "${TEST_FAKE_BIN}/sysctl" "${TEST_NO_MODPROBE_BIN}/sysctl"
ln -s "$TEST_BASE64" "${TEST_NO_MODPROBE_BIN}/base64"
cat >"${TEST_NO_MODPROBE_BIN}/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TEST_NO_MODPROBE_BIN}/apt-get"

export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_DRY_RUN=0
export VPSCTL_ASSUME_YES=0
export VPSCTL_NON_INTERACTIVE=1
export VPSCTL_QUIET=0
export VPSCTL_VERBOSE=0
export VPSCTL_NO_COLOR=0
export PATH="${TEST_FAKE_BIN}:${PATH}"

RUN_STATUS=0
RUN_OUTPUT=""
run_bbr() {
    if RUN_OUTPUT="$(PATH="${RUN_BBR_PATH:-$PATH}" "$TEST_BASH" "$TEST_BBR" "$@" 2>&1)"; then
        RUN_STATUS=0
    else
        RUN_STATUS=$?
    fi
}

test_status_and_arguments() {
    run_bbr
    test_assert_equal 0 "$RUN_STATUS" "non-interactive default exit code"
    test_assert_contains "$RUN_OUTPUT" "当前拥塞控制算法" "non-interactive default status label"
    test_assert_contains "$RUN_OUTPUT" "cubic" "non-interactive default status value"
    [[ "$RUN_OUTPUT" != *$'\033['* ]] || test_fail "non-TTY status emitted ANSI escapes"

    run_bbr status
    test_assert_equal 0 "$RUN_STATUS" "status exit code"
    test_assert_contains "$RUN_OUTPUT" "当前拥塞控制算法" "status algorithm label"
    test_assert_contains "$RUN_OUTPUT" "默认 qdisc" "status qdisc label"
    test_assert_contains "$RUN_OUTPUT" "reno cubic bbr" "available algorithms"
    test_assert_contains "$RUN_OUTPUT" "BBR 模块" "BBR module label"
    test_assert_contains "$RUN_OUTPUT" "可用" "BBR module state"
    test_assert_contains "$RUN_OUTPUT" "默认路由网卡" "default interface label"
    test_assert_contains "$RUN_OUTPUT" "eth0" "default interface value"
    test_assert_contains "$RUN_OUTPUT" "网卡 root qdisc" "interface root qdisc label"
    test_assert_contains "$RUN_OUTPUT" "fq_codel" "interface root qdisc value"

    run_bbr -- status
    test_assert_equal 0 "$RUN_STATUS" "option terminator exit code"
    run_bbr --quiet status
    test_assert_equal 0 "$RUN_STATUS" "quiet option exit code"
    run_bbr --verbose status
    test_assert_equal 0 "$RUN_STATUS" "verbose option exit code"
    run_bbr --no-color status
    test_assert_equal 0 "$RUN_STATUS" "no-color option exit code"
    [[ "$RUN_OUTPUT" != *$'\033['* ]] || test_fail "--no-color status emitted ANSI escapes"

    run_bbr --help
    test_assert_equal 0 "$RUN_STATUS" "help exit code"
    test_assert_contains "$RUN_OUTPUT" "set --algorithm ALG --qdisc QDISC" "help syntax"
    test_assert_contains "$RUN_OUTPUT" "管理 TCP 拥塞控制算法" "Chinese help heading"
    test_assert_contains "$RUN_OUTPUT" "--no-color" "no-color help option"
    test_assert_contains "$RUN_OUTPUT" "--install-deps" "install-deps help option"
    RUN_BBR_PATH="$TEST_NO_MODPROBE_BIN" run_bbr --install-deps --help
    test_assert_equal 0 "$RUN_STATUS" "install-deps help exit code"
    test_assert_not_contains "$RUN_OUTPUT" "apt-get" "help dependency install plan"

    run_bbr --install-deps status
    test_assert_equal 0 "$RUN_STATUS" "install-deps direct global option exit code"
    run_bbr --install-deps
    test_assert_equal 0 "$RUN_STATUS" "install-deps default query exit code"

    run_bbr status --bogus
    test_assert_equal 2 "$RUN_STATUS" "unknown option exit code"
    run_bbr set --algorithm bbr
    test_assert_equal 2 "$RUN_STATUS" "missing qdisc exit code"
    run_bbr --yes set --algorithm bad.name --qdisc fq
    test_assert_equal 10 "$RUN_STATUS" "unsafe algorithm name exit code"
    run_bbr status extra
    test_assert_equal 2 "$RUN_STATUS" "extra action exit code"
}

test_dry_run() {
    local available_path="${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_available_congestion_control"

    run_bbr --dry-run --yes set --algorithm bbr --qdisc fq
    test_assert_equal 0 "$RUN_STATUS" "dry-run exit code"
    test_assert_contains "$RUN_OUTPUT" "[演练]" "dry-run plan"
    test_assert_equal cubic "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control")" "dry-run algorithm"
    test_assert_equal fq_codel "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc")" "dry-run qdisc"
    [[ ! -e "${TEST_SYSTEM_ROOT}/etc/sysctl.d/90-vpsctl-bbr.conf" ]] || test_fail "dry-run wrote sysctl config"
    [[ ! -e "${TEST_SYSTEM_ROOT}/etc/modules-load.d/90-vpsctl-bbr.conf" ]] || test_fail "dry-run wrote modules config"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/network/bbr/original.conf" ]] || test_fail "dry-run saved original state"

    run_bbr --dry-run --yes set --algorithm cubic --qdisc fq_codel --apply-live-qdisc
    test_assert_equal 0 "$RUN_STATUS" "non-interactive live-qdisc dry-run exit code"
    test_assert_contains "$RUN_OUTPUT" "tc qdisc replace dev eth0 root fq_codel" "live qdisc plan"

    printf 'reno cubic\n' >"$available_path"
    RUN_BBR_PATH="$TEST_NO_MODPROBE_BIN" run_bbr --dry-run --yes set --algorithm bbr --qdisc fq
    test_assert_equal 3 "$RUN_STATUS" "missing modprobe dry-run exit code"
    test_assert_contains "$RUN_OUTPUT" "--install-deps" "missing modprobe install hint"
    test_assert_not_contains "$RUN_OUTPUT" "变更失败，正在恢复" "missing modprobe dry-run rollback warning"
    test_assert_not_contains "$RUN_OUTPUT" "net.ipv4.tcp_congestion_control=cubic" "missing modprobe dry-run rollback plan"

    RUN_BBR_PATH="$TEST_NO_MODPROBE_BIN" run_bbr --dry-run --install-deps --yes set --algorithm bbr --qdisc fq
    test_assert_equal 0 "$RUN_STATUS" "planned modprobe dependency exit code"
    test_assert_contains "$RUN_OUTPUT" "apt-get" "planned dependency package manager"
    test_assert_contains "$RUN_OUTPUT" "kmod" "planned modprobe package"
    test_assert_contains "$RUN_OUTPUT" "重新运行以查看完整计划" "planned dependency stop message"
    test_assert_not_contains "$RUN_OUTPUT" "变更失败，正在恢复" "planned dependency rollback warning"
    test_assert_not_contains "$RUN_OUTPUT" "原子写入" "planned dependency managed write"
    [[ ! -e "${TEST_SYSTEM_ROOT}/etc/sysctl.d/90-vpsctl-bbr.conf" ]] || test_fail "planned dependency wrote sysctl config"
    [[ ! -e "${TEST_SYSTEM_ROOT}/etc/modules-load.d/90-vpsctl-bbr.conf" ]] || test_fail "planned dependency wrote modules config"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/network/bbr/original.conf" ]] || test_fail "planned dependency saved original state"

    run_bbr --dry-run --yes set --algorithm vegas --qdisc fq
    test_assert_equal 3 "$RUN_STATUS" "unavailable algorithm dry-run exit code"
    test_assert_contains "$RUN_OUTPUT" "当前运行内核不可用" "unavailable algorithm dry-run message"
    test_assert_not_contains "$RUN_OUTPUT" "变更失败，正在恢复" "unavailable algorithm dry-run rollback warning"
    test_assert_not_contains "$RUN_OUTPUT" "net.ipv4.tcp_congestion_control=cubic" "unavailable algorithm dry-run rollback plan"
    printf 'reno cubic bbr\n' >"$available_path"
}

test_symlink_guards() {
    local sysctl_path="${TEST_SYSTEM_ROOT}/etc/sysctl.d/90-vpsctl-bbr.conf"
    local link_target="${TEST_SYSTEM_ROOT}/unmanaged.conf"
    local modules_parent="${TEST_SYSTEM_ROOT}/etc/modules-load.d"
    local alternate_parent="${TEST_SYSTEM_ROOT}/alternate-modules"
    local etc_path="${TEST_SYSTEM_ROOT}/etc"
    local saved_etc="${TEST_SYSTEM_ROOT}/etc.saved"
    local outside_etc="${TEST_TEMP}/outside-bbr-etc"

    printf 'unmanaged\n' >"$link_target"
    if ln -s "$link_target" "$sysctl_path" 2>/dev/null && [[ -L "$sysctl_path" ]]; then
        run_bbr --yes enable
        test_assert_equal 3 "$RUN_STATUS" "managed-file symlink exit code"
        test_assert_equal unmanaged "$(<"$link_target")" "managed-file symlink target"
        rm -f -- "$sysctl_path"
    else
        rm -f -- "$sysctl_path"
    fi

    mkdir -p "$alternate_parent"
    if rmdir "$modules_parent" && ln -s "$alternate_parent" "$modules_parent" 2>/dev/null && [[ -L "$modules_parent" ]]; then
        run_bbr --yes enable
        test_assert_equal 3 "$RUN_STATUS" "managed-directory symlink exit code"
        rm -f -- "$modules_parent"
        mkdir -p "$modules_parent"
    elif [[ ! -d "$modules_parent" ]]; then
        mkdir -p "$modules_parent"
    fi

    mv -- "$etc_path" "$saved_etc"
    mkdir -p -- "$outside_etc"
    if ln -s "$outside_etc" "$etc_path" 2>/dev/null && [[ -L "$etc_path" ]]; then
        run_bbr --yes enable
        test_assert_equal 3 "$RUN_STATUS" "managed ancestor symlink exit code"
        [[ ! -e "${outside_etc}/sysctl.d/90-vpsctl-bbr.conf" ]] || test_fail "BBR write escaped through an ancestor symlink"
        unlink -- "$etc_path" 2>/dev/null || rmdir -- "$etc_path"
    elif [[ -e "$etc_path" || -L "$etc_path" ]]; then
        unlink -- "$etc_path" 2>/dev/null || rmdir -- "$etc_path"
    fi
    mv -- "$saved_etc" "$etc_path"
}

test_unavailable_algorithm() {
    run_bbr --yes set --algorithm vegas --qdisc fq
    test_assert_equal 3 "$RUN_STATUS" "unavailable algorithm exit code"
    test_assert_contains "$RUN_OUTPUT" "当前运行内核不可用" "unavailable algorithm message"
    test_assert_not_contains "$RUN_OUTPUT" "变更失败，正在恢复" "unavailable algorithm rollback warning"
    test_assert_equal cubic "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control")" "algorithm after rejection"
    [[ ! -e "${TEST_SYSTEM_ROOT}/etc/sysctl.d/90-vpsctl-bbr.conf" ]] || test_fail "unavailable algorithm wrote persistence"
}

test_transaction_rollback() {
    local sysctl_path="${TEST_SYSTEM_ROOT}/etc/sysctl.d/90-vpsctl-bbr.conf"
    local modules_path="${TEST_SYSTEM_ROOT}/etc/modules-load.d/90-vpsctl-bbr.conf"
    local original_path="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/network/bbr/original.conf"

    : >"${TEST_SYSTEM_ROOT}/fail-qdisc"
    run_bbr --yes set --algorithm cubic --qdisc cake
    rm -f -- "${TEST_SYSTEM_ROOT}/fail-qdisc"
    test_assert_equal 20 "$RUN_STATUS" "failed transaction exit code"
    test_assert_contains "$RUN_OUTPUT" "变更失败，正在恢复" "failed transaction rollback warning"
    test_assert_equal cubic "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control")" "rolled-back algorithm"
    test_assert_equal fq_codel "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc")" "rolled-back qdisc"
    [[ ! -e "$sysctl_path" && ! -e "$modules_path" && ! -e "$original_path" ]] || test_fail "failed transaction left persistent files"
}

test_live_qdisc_rollback() {
    local sysctl_path="${TEST_SYSTEM_ROOT}/etc/sysctl.d/90-vpsctl-bbr.conf"
    local modules_path="${TEST_SYSTEM_ROOT}/etc/modules-load.d/90-vpsctl-bbr.conf"
    local original_path="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/network/bbr/original.conf"

    : >"${TEST_SYSTEM_ROOT}/fail-live-qdisc"
    run_bbr --yes enable --apply-live-qdisc
    rm -f -- "${TEST_SYSTEM_ROOT}/fail-live-qdisc"
    test_assert_equal 20 "$RUN_STATUS" "failed live qdisc exit code"
    test_assert_contains "$RUN_OUTPUT" "变更失败，正在恢复" "failed live qdisc rollback warning"
    test_assert_equal cubic "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control")" "algorithm after live qdisc failure"
    test_assert_equal fq_codel "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc")" "default qdisc after live failure"
    test_assert_equal fq_codel "$(<"${TEST_SYSTEM_ROOT}/tc-root-qdisc")" "restored interface root qdisc"
    [[ ! -e "$sysctl_path" && ! -e "$modules_path" && ! -e "$original_path" ]] || test_fail "live qdisc failure left persistent files"
    test_assert_contains "$(<"${TEST_SYSTEM_ROOT}/tc.log")" "qdisc replace dev eth0 root fq_codel" "live qdisc rollback command"
}

test_non_live_then_first_live_snapshot() {
    local original_path="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/network/bbr/original.conf"
    local before_sysctl_b64 after_sysctl_b64

    run_bbr --yes enable
    test_assert_equal 0 "$RUN_STATUS" "non-live enable exit code"
    test_assert_contains "$(<"$original_path")" "live_present=0" "initial non-live state"
    before_sysctl_b64="$(sed -n 's/^sysctl_b64=//p' "$original_path")"

    run_bbr --yes set --algorithm bbr --qdisc fq --apply-live-qdisc
    test_assert_equal 0 "$RUN_STATUS" "first later live change exit code"
    test_assert_contains "$(<"$original_path")" "version=2" "extended state version"
    test_assert_contains "$(<"$original_path")" "algorithm=cubic" "extended original algorithm"
    test_assert_contains "$(<"$original_path")" "live_present=1" "extended live snapshot"
    test_assert_contains "$(<"$original_path")" "live_interface=eth0" "extended live interface"
    test_assert_contains "$(<"$original_path")" "live_qdisc=fq_codel" "extended live qdisc"
    after_sysctl_b64="$(sed -n 's/^sysctl_b64=//p' "$original_path")"
    test_assert_equal "$before_sysctl_b64" "$after_sysctl_b64" "extended original file snapshot"

    run_bbr --yes restore
    test_assert_equal 0 "$RUN_STATUS" "extended-state restore exit code"
    test_assert_equal fq_codel "$(<"${TEST_SYSTEM_ROOT}/tc-root-qdisc")" "extended-state restored live qdisc"
    rm -f -- "$original_path"
}

test_original_state_validation() {
    local original_path="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/network/bbr/original.conf"

    mkdir -p -- "${original_path%/*}"
    cat >"$original_path" <<'EOF'
version=1
algorithm=cubic
qdisc=fq_codel
sysctl_present=0
sysctl_b64=
modules_present=0
modules_b64=
EOF
    run_bbr --yes restore
    test_assert_equal 0 "$RUN_STATUS" "version 1 compatibility exit code"
    test_assert_contains "$RUN_OUTPUT" "已处于原始状态" "version 1 compatibility behavior"

    printf 'algorithm=reno\n' >>"$original_path"
    run_bbr --yes restore
    test_assert_equal 10 "$RUN_STATUS" "duplicate original-state key exit code"
    test_assert_contains "$RUN_OUTPUT" "重复键" "duplicate original-state key message"

    cat >"$original_path" <<'EOF'
version=1
algorithm=cubic
qdisc=fq_codel
sysctl_present=1
sysctl_b64=%%%
modules_present=0
modules_b64=
EOF
    run_bbr --yes restore
    test_assert_equal 10 "$RUN_STATUS" "invalid original-state base64 exit code"
    test_assert_contains "$RUN_OUTPUT" "无效 base64" "invalid original-state base64 message"

    cat >"$original_path" <<'EOF'
version=1
algorithm=cubic
qdisc=fq_codel
sysctl_present=0
sysctl_b64=
modules_present=0
modules_b64=
unknown_key=value
EOF
    run_bbr --yes restore
    test_assert_equal 10 "$RUN_STATUS" "unknown original-state key exit code"
    test_assert_contains "$RUN_OUTPUT" "未知键" "unknown original-state key message"
    rm -f -- "$original_path"
}

test_persistence_and_restore() {
    local original_path="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/network/bbr/original.conf"
    local sysctl_path="${TEST_SYSTEM_ROOT}/etc/sysctl.d/90-vpsctl-bbr.conf"
    local modules_path="${TEST_SYSTEM_ROOT}/etc/modules-load.d/90-vpsctl-bbr.conf"
    local first_original
    local managed_sysctl
    local -a backup_files=()
    local -a takeover_backups=()

    printf '# previous sysctl file\n' >"$sysctl_path"
    printf '# previous modules file\n' >"$modules_path"

    run_bbr --yes enable --apply-live-qdisc
    test_assert_equal 0 "$RUN_STATUS" "enable exit code"
    test_assert_contains "$RUN_OUTPUT" "先备份再覆盖" "unmanaged overwrite warning"
    test_assert_contains "$RUN_OUTPUT" "已应用 TCP 算法" "Chinese apply success"
    mapfile -t backup_files < <(find "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/backups/network/bbr" -type f -name '90-vpsctl-bbr.conf' -print)
    ((${#backup_files[@]} == 2)) || test_fail "both unmanaged persistence files were not backed up"
    test_assert_equal bbr "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control")" "enabled algorithm"
    test_assert_equal fq "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc")" "enabled qdisc"
    [[ -f "$sysctl_path" && -f "$modules_path" && -f "$original_path" ]] || test_fail "enable did not write all persistent files"
    test_assert_contains "$(<"$sysctl_path")" "net.ipv4.tcp_congestion_control = bbr" "persisted algorithm"
    test_assert_contains "$(<"$modules_path")" "tcp_bbr" "persisted module"
    test_assert_contains "$(<"${TEST_SYSTEM_ROOT}/tc.log")" "qdisc replace dev eth0 root fq" "live qdisc application"
    test_assert_contains "$(<"$original_path")" "algorithm=cubic" "saved original algorithm"
    test_assert_contains "$(<"$original_path")" "live_present=1" "saved first live snapshot"
    first_original="$(<"$original_path")"

    run_bbr --yes set --algorithm cubic --qdisc fq_codel
    test_assert_equal 0 "$RUN_STATUS" "set exit code"
    test_assert_equal "$first_original" "$(<"$original_path")" "first original state is immutable"

    managed_sysctl="$(<"$sysctl_path")"
    printf '# administrator takeover\n' >"$sysctl_path"
    run_bbr --yes restore
    test_assert_equal 3 "$RUN_STATUS" "restore unmanaged-file exit code"
    test_assert_contains "$RUN_OUTPUT" "不再由 vpsctl 管理" "restore unmanaged-file message"
    test_assert_equal "# administrator takeover" "$(<"$sysctl_path")" "administrator-owned sysctl file"
    printf '%s\n' "$managed_sysctl" >"$sysctl_path"

    run_bbr --yes restore
    test_assert_equal 0 "$RUN_STATUS" "restore exit code"
    test_assert_equal cubic "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control")" "restored algorithm"
    test_assert_equal fq_codel "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc")" "restored qdisc"
    test_assert_equal "# previous sysctl file" "$(<"$sysctl_path")" "restored previous sysctl file"
    test_assert_equal "# previous modules file" "$(<"$modules_path")" "restored previous modules file"
    test_assert_equal fq_codel "$(<"${TEST_SYSTEM_ROOT}/tc-root-qdisc")" "restored saved live root qdisc"
    [[ -f "$original_path" ]] || test_fail "restore discarded the first original state"

    run_bbr --yes restore
    test_assert_equal 0 "$RUN_STATUS" "repeated restore exit code"
    test_assert_contains "$RUN_OUTPUT" "已处于原始状态" "repeated restore idempotent message"

    printf 'fq\n' >"${TEST_SYSTEM_ROOT}/tc-root-qdisc"
    : >"${TEST_SYSTEM_ROOT}/missing-eth0"
    run_bbr --yes restore
    rm -f -- "${TEST_SYSTEM_ROOT}/missing-eth0"
    test_assert_equal 30 "$RUN_STATUS" "missing saved live interface exit code"
    test_assert_contains "$RUN_OUTPUT" "网卡已消失" "missing saved live interface message"
    test_assert_equal cubic "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control")" "partial restore algorithm"
    run_bbr --yes restore
    test_assert_equal 0 "$RUN_STATUS" "live-only restore exit code"
    test_assert_equal fq_codel "$(<"${TEST_SYSTEM_ROOT}/tc-root-qdisc")" "live-only restored root qdisc"

    printf 'bbr\n' >"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control"
    printf 'fq\n' >"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc"
    run_bbr --yes restore
    test_assert_equal 0 "$RUN_STATUS" "runtime-only restore exit code"
    test_assert_equal cubic "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control")" "runtime-only restored algorithm"
    test_assert_equal fq_codel "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc")" "runtime-only restored qdisc"

    printf '# administrator takeover after restore\n' >"$sysctl_path"
    run_bbr --yes enable
    test_assert_equal 0 "$RUN_STATUS" "enable after administrator takeover exit code"
    test_assert_contains "$RUN_OUTPUT" "先备份再覆盖" "post-restore takeover warning"
    mapfile -t takeover_backups < <(grep -R -l -F '# administrator takeover after restore' "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/backups/network/bbr")
    ((${#takeover_backups[@]} == 1)) || test_fail "post-restore administrator file was not backed up exactly once"
    test_assert_contains "$(<"$sysctl_path")" "# Managed by vpsctl network bbr." "managed marker after takeover overwrite"
}

test_status_and_arguments
test_dry_run
test_symlink_guards
test_unavailable_algorithm
test_transaction_rollback
test_live_qdisc_rollback
test_non_live_then_first_live_snapshot
test_original_state_validation
test_persistence_and_restore
printf 'PASS: network bbr tests\n'
