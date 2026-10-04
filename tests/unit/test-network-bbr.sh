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
TEST_MV="$(command -v mv)"
readonly TEST_MV
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
    printf '%s\n' "$*" >>"${VPSCTL_SYSTEM_ROOT}/sysctl.log"
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
printf '%s\n' "$*" >>"${VPSCTL_SYSTEM_ROOT}/ip.log"
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
    printf '%s\n' "$*" >>"${VPSCTL_SYSTEM_ROOT}/tc-query.log"
    printf 'qdisc %s 0: root refcnt 2\n' "$(<"${VPSCTL_SYSTEM_ROOT}/tc-root-qdisc")"
    if [[ -f "${VPSCTL_SYSTEM_ROOT}/fail-live-qdisc-read" ]]; then
        rm -f -- "${VPSCTL_SYSTEM_ROOT}/fail-live-qdisc-read"
        exit 20
    fi
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
printf '%s\n' "$*" >>"${VPSCTL_SYSTEM_ROOT}/flock.log"
exit 0
EOF
cat >"${TEST_FAKE_BIN}/mv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${VPSCTL_SYSTEM_ROOT}/writes.log"
exec "$VPSCTL_TEST_REAL_MV" "$@"
EOF
cat >"${TEST_FAKE_BIN}/base64" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "${VPSCTL_SYSTEM_ROOT}/etc/sysctl.d/90-vpsctl-bbr.conf" && -f "${VPSCTL_SYSTEM_ROOT}/fail-comparison-read" ]]; then
    rm -f -- "${VPSCTL_SYSTEM_ROOT}/fail-comparison-read"
    exit 1
fi
exec "$VPSCTL_TEST_REAL_BASE64" "$@"
EOF
chmod +x \
    "${TEST_FAKE_BIN}/sysctl" \
    "${TEST_FAKE_BIN}/modprobe" \
    "${TEST_FAKE_BIN}/ip" \
    "${TEST_FAKE_BIN}/tc" \
    "${TEST_FAKE_BIN}/flock" \
    "${TEST_FAKE_BIN}/mv" \
    "${TEST_FAKE_BIN}/base64"
ln -s "$TEST_BASH" "${TEST_NO_MODPROBE_BIN}/bash"
ln -s "$TEST_CAT" "${TEST_NO_MODPROBE_BIN}/cat"
ln -s "$TEST_DIRNAME" "${TEST_NO_MODPROBE_BIN}/dirname"
ln -s "${TEST_FAKE_BIN}/sysctl" "${TEST_NO_MODPROBE_BIN}/sysctl"
ln -s "$TEST_BASE64" "${TEST_NO_MODPROBE_BIN}/base64"
cat >"${TEST_NO_MODPROBE_BIN}/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${VPSCTL_SYSTEM_ROOT}/apt-get.log"
EOF
chmod +x "${TEST_NO_MODPROBE_BIN}/apt-get"

export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_TEST_REAL_MV="$TEST_MV"
export VPSCTL_TEST_REAL_BASE64="$TEST_BASE64"
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

reset_bbr_effect_logs() {
    local log
    for log in writes sysctl modprobe tc ip tc-query flock; do
        : >"${TEST_SYSTEM_ROOT}/${log}.log"
    done
}

test_assert_no_bbr_effects() {
    local message="$1" log
    for log in writes sysctl modprobe tc; do
        [[ ! -s "${TEST_SYSTEM_ROOT}/${log}.log" ]] || test_fail "${message}: unexpected ${log} command"
    done
}

test_assert_bbr_applied() {
    local algorithm="$1" qdisc="$2" message="$3"
    test_assert_equal 0 "$RUN_STATUS" "${message} exit code"
    test_assert_contains "$RUN_OUTPUT" "已应用 TCP 算法" "${message} apply message"
    test_assert_not_contains "$RUN_OUTPUT" "无需重复应用" "${message} did not short-circuit"
    [[ -s "${TEST_SYSTEM_ROOT}/writes.log" ]] || test_fail "${message}: no persistence writes"
    test_assert_contains "$(<"${TEST_SYSTEM_ROOT}/modprobe.log")" "sch_${qdisc}" "${message} qdisc module"
    test_assert_contains "$(<"${TEST_SYSTEM_ROOT}/sysctl.log")" "net.ipv4.tcp_congestion_control=${algorithm}" "${message} runtime algorithm command"
    test_assert_contains "$(<"${TEST_SYSTEM_ROOT}/sysctl.log")" "net.core.default_qdisc=${qdisc}" "${message} runtime qdisc command"
    test_assert_equal "$algorithm" "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control")" "${message} runtime algorithm"
    test_assert_equal "$qdisc" "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc")" "${message} runtime qdisc"
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

test_interactive_menu() (
    local menu_marker="${TEST_SYSTEM_ROOT}/bbr-menu-marker"
    local captured status=0 failure_marker="${TEST_SYSTEM_ROOT}/bbr-menu-failure-marker"

    # shellcheck source=../../commands/network/bbr.sh
    source "$TEST_BBR"
    bbr_available_algorithms() { printf 'reno cubic bbr\n'; }
    bbr_current_algorithm() { printf 'cubic\n'; }
    bbr_current_qdisc() { printf 'fq_codel\n'; }
    vps_cmd_prompt_select() {
        case "$1" in
            "BBR 网络管理")
                test_assert_equal status "$2" "BBR menu default action"
                test_assert_equal set "$7" "BBR menu set action value"
                test_assert_equal "选择算法和 qdisc" "$8" "BBR menu set action label"
                if [[ -e "$menu_marker" ]]; then
                    printf quit
                else
                    : >"$menu_marker"
                    printf set
                fi
                ;;
            "选择 TCP 拥塞控制算法")
                test_assert_equal cubic "$2" "current algorithm is menu default"
                test_assert_equal reno "$3" "first available algorithm value"
                test_assert_equal cubic "$5" "current available algorithm value"
                test_assert_equal "cubic（当前）" "$6" "current algorithm label"
                test_assert_equal bbr "$7" "last available algorithm value"
                printf bbr
                ;;
            "选择默认 qdisc")
                test_assert_equal fq_codel "$2" "current qdisc is menu default"
                test_assert_equal fq "$3" "fq qdisc option"
                test_assert_equal fq_codel "$5" "fq_codel qdisc option"
                test_assert_equal manual "$7" "manual qdisc option"
                test_assert_equal 8 "$#" "current qdisc is deduplicated"
                printf manual
                ;;
            "是否立即应用到默认路由网卡的 root qdisc")
                test_assert_equal keep "$2" "live qdisc safe default"
                test_assert_equal apply "$5" "live qdisc explicit apply value"
                printf apply
                ;;
            *) test_fail "unexpected select prompt: $1" ;;
        esac
    }
    vps_cmd_prompt_value() {
        test_assert_equal "输入默认 qdisc" "$1" "manual qdisc prompt"
        test_assert_equal fq_codel "$2" "manual qdisc current default"
        printf cake
    }
    vps_cmd_confirm() {
        test_fail "parameter selection unexpectedly requested confirmation: $1"
    }
    bbr_apply_settings() {
        printf '%s|%s|%s\n' "$1" "$2" "$BBR_APPLY_LIVE_QDISC" >"${TEST_SYSTEM_ROOT}/bbr-menu-captured"
    }

    bbr_interactive_menu
    captured="$(<"${TEST_SYSTEM_ROOT}/bbr-menu-captured")"
    test_assert_equal 'bbr|cake|1' "$captured" "interactive BBR selections"

    vps_cmd_prompt_select() {
        [[ "$1" == "BBR 网络管理" ]] || test_fail "unexpected failure-path prompt: $1"
        if [[ -e "$failure_marker" ]]; then printf quit; else : >"$failure_marker"; printf status; fi
    }
    bbr_status() { return 3; }
    bbr_interactive_menu >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" "interactive BBR failure status propagation"
)

test_apply_confirmation() (
    local sysctl_path="${TEST_SYSTEM_ROOT}/etc/sysctl.d/90-vpsctl-bbr.conf"
    local modules_path="${TEST_SYSTEM_ROOT}/etc/modules-load.d/90-vpsctl-bbr.conf"
    local original_path="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/network/bbr/original.conf"
    local backup_path="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/backups/network/bbr"
    local unmanaged live reply status confirmations=0 injected_path="" output

    # shellcheck source=../../commands/network/bbr.sh
    source "$TEST_BBR"
    vps_cmd_init network-bbr "$BBR_PROJECT_ROOT"
    BBR_SYSCTL_FILE="$sysctl_path"
    BBR_MODULES_FILE="$modules_path"
    BBR_ORIGINAL_FILE="$original_path"
    vps_cmd_confirm() {
        confirmations=$((confirmations + 1))
        test_assert_equal "是否应用以上 BBR 变更？" "$1" "single complete confirmation"
        [[ -n "${VPS_CMD_LOCK_FD:-}" ]] || test_fail "confirmation occurred outside the transaction lock"
        test_assert_equal 1 "$BBR_TX_ACTIVE" "read-only snapshot before confirmation"
        test_assert_no_bbr_effects "before confirmation"
        [[ ! -e "$original_path" && ! -e "$backup_path" ]] || test_fail "confirmation already created recovery files"
        if [[ -n "$injected_path" ]]; then
            printf '# appeared during confirmation\n' >"$injected_path"
        fi
        return "$reply"
    }

    for unmanaged in 0 1; do
        for live in 0 1; do
            for reply in 0 1 130; do
                rm -f -- "$sysctl_path" "$modules_path" "$original_path"
                rm -rf -- "$backup_path"
                printf 'cubic\n' >"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control"
                printf 'fq_codel\n' >"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc"
                printf 'fq_codel\n' >"${TEST_SYSTEM_ROOT}/tc-root-qdisc"
                if ((unmanaged)); then
                    printf '# original sysctl\n' >"$sysctl_path"
                    printf '# original modules\n' >"$modules_path"
                fi
                reset_bbr_effect_logs
                BBR_APPLY_LIVE_QDISC="$live"
                confirmations=0
                status=0
                bbr_apply_settings bbr fq >"${TEST_TEMP}/confirmation-output" 2>&1 || status=$?
                output="$(<"${TEST_TEMP}/confirmation-output")"
                test_assert_equal 1 "$confirmations" "confirmation count for unmanaged=$unmanaged live=$live reply=$reply"
                test_assert_contains "$output" 'cubic → bbr' "algorithm summary"
                test_assert_contains "$output" 'fq_codel → fq' "default qdisc summary"
                test_assert_contains "$output" '/etc/sysctl.d/90-vpsctl-bbr.conf' "sysctl path summary"
                test_assert_contains "$output" '/etc/modules-load.d/90-vpsctl-bbr.conf' "modules path summary"
                if ((unmanaged)); then
                    test_assert_contains "$output" '先备份再覆盖' "unmanaged summary"
                    test_assert_contains "$output" '/var/lib/vpsctl/backups/network/bbr/' "backup summary"
                fi
                if ((live)); then
                    test_assert_contains "$output" '网卡 eth0 的 root qdisc：fq_codel → fq' "live qdisc summary"
                    test_assert_contains "$output" '连接中断' "live network risk summary"
                else
                    test_assert_not_contains "$output" '连接中断' "non-live summary"
                fi
                [[ -z "${VPS_CMD_LOCK_FD:-}" ]] || test_fail "confirmation path retained transaction lock"
                test_assert_equal 0 "$BBR_TX_ACTIVE" "confirmation path transaction cleanup"
                if ((reply == 0)); then
                    test_assert_equal 0 "$status" "confirmed apply status"
                    [[ -f "$original_path" ]] || test_fail "confirmed apply omitted original record"
                    test_assert_equal bbr "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control")" "confirmed apply runtime"
                    if ((unmanaged)); then
                        [[ -d "$backup_path" ]] || test_fail "confirmed overwrite omitted backup"
                    fi
                    reset_bbr_effect_logs
                    bbr_apply_settings bbr fq >"${TEST_TEMP}/confirmation-output" 2>&1 || test_fail 'already matching apply failed'
                    test_assert_equal 1 "$confirmations" "no-op does not ask again"
                    test_assert_no_bbr_effects "already matching apply"
                    [[ -z "${VPS_CMD_LOCK_FD:-}" ]] || test_fail "no-op retained transaction lock"
                else
                    if ((reply == 1)); then
                        test_assert_equal 0 "$status" "cancelled apply status"
                    else
                        test_assert_equal 130 "$status" "interrupted confirmation status"
                    fi
                    test_assert_no_bbr_effects "cancelled or interrupted confirmation"
                    [[ ! -e "$original_path" && ! -e "$backup_path" ]] || test_fail "cancelled apply created recovery files"
                    if ((unmanaged)); then
                        test_assert_equal '# original sysctl' "$(<"$sysctl_path")" "cancelled sysctl file"
                        test_assert_equal '# original modules' "$(<"$modules_path")" "cancelled modules file"
                    else
                        [[ ! -e "$sysctl_path" && ! -e "$modules_path" ]] || test_fail "cancelled apply created persistence files"
                    fi
                fi
            done
        done
    done

    # Authorizing one unmanaged file must not silently authorize a second file
    # that appeared while the user was reading the summary.
    rm -f -- "$modules_path"
    injected_path="$modules_path"
    reply=0
    confirmations=0
    status=0
    reset_bbr_effect_logs
    bbr_apply_settings bbr fq >"${TEST_TEMP}/confirmation-output" 2>&1 || status=$?
    test_assert_equal 3 "$status" "new unapproved persistence file status"
    test_assert_contains "$(<"${TEST_TEMP}/confirmation-output")" '确认后出现未受管持久化文件' "new unapproved file error"
    test_assert_equal '# appeared during confirmation' "$(<"$modules_path")" "new unapproved file preserved"
    test_assert_no_bbr_effects "new unapproved persistence file"
    [[ ! -e "$original_path" && ! -e "$backup_path" && -z "${VPS_CMD_LOCK_FD:-}" ]] || test_fail "new file refusal retained effects or lock"

    injected_path=""
    confirmations=0
    status=0
    : >"${TEST_SYSTEM_ROOT}/fail-live-qdisc-read"
    bbr_apply_settings bbr fq >"${TEST_TEMP}/confirmation-output" 2>&1 || status=$?
    test_assert_equal 3 "$status" "failed live preflight status"
    test_assert_equal 0 "$confirmations" "failed preflight does not request authorization"
    test_assert_no_bbr_effects "failed live preflight"
    [[ -z "${VPS_CMD_LOCK_FD:-}" ]] || test_fail "failed preflight retained transaction lock"
    rm -f -- "$sysctl_path" "$modules_path" "$original_path"
)

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
    RUN_BBR_PATH="$TEST_NO_MODPROBE_BIN" run_bbr --yes set --algorithm bbr --qdisc fq
    test_assert_equal 3 "$RUN_STATUS" "missing dependency real execution requires install authorization"
    test_assert_contains "$RUN_OUTPUT" "--install-deps" "missing dependency real execution install hint"
    [[ ! -e "${TEST_SYSTEM_ROOT}/apt-get.log" ]] || test_fail "unauthorized dependency check executed package manager"

    RUN_BBR_PATH="$TEST_NO_MODPROBE_BIN" run_bbr --dry-run set --algorithm bbr --qdisc fq
    test_assert_equal 0 "$RUN_STATUS" "missing modprobe dry-run exit code"
    test_assert_contains "$RUN_OUTPUT" "缺少工具：modprobe" "missing modprobe dependency summary"
    test_assert_contains "$RUN_OUTPUT" "apt-get update" "missing modprobe dependency refresh plan"
    test_assert_contains "$RUN_OUTPUT" "apt-get install -y --no-install-recommends kmod" "missing modprobe dependency install plan"
    test_assert_contains "$RUN_OUTPUT" "重新运行以查看完整计划" "missing modprobe dependency stop message"
    test_assert_not_contains "$RUN_OUTPUT" "变更失败，正在恢复" "missing modprobe dry-run rollback warning"
    test_assert_not_contains "$RUN_OUTPUT" "net.ipv4.tcp_congestion_control=cubic" "missing modprobe dry-run rollback plan"

    RUN_BBR_PATH="$TEST_NO_MODPROBE_BIN" run_bbr --dry-run --install-deps --yes set --algorithm bbr --qdisc fq
    test_assert_equal 0 "$RUN_STATUS" "planned modprobe dependency exit code"
    test_assert_contains "$RUN_OUTPUT" "apt-get" "planned dependency package manager"
    test_assert_contains "$RUN_OUTPUT" "kmod" "planned modprobe package"
    test_assert_contains "$RUN_OUTPUT" "重新运行以查看完整计划" "planned dependency stop message"
    test_assert_not_contains "$RUN_OUTPUT" "变更失败，正在恢复" "planned dependency rollback warning"
    test_assert_not_contains "$RUN_OUTPUT" "原子写入" "planned dependency managed write"
    [[ ! -e "${TEST_SYSTEM_ROOT}/apt-get.log" ]] || test_fail "dependency plan executed package manager"
    [[ ! -e "${TEST_SYSTEM_ROOT}/modprobe.log" ]] || test_fail "dependency plan loaded a module"
    test_assert_equal cubic "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control")" "dependency plan algorithm"
    test_assert_equal fq_codel "$(<"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc")" "dependency plan qdisc"
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

test_repeated_apply() {
    local sysctl_path="${TEST_SYSTEM_ROOT}/etc/sysctl.d/90-vpsctl-bbr.conf"
    local modules_path="${TEST_SYSTEM_ROOT}/etc/modules-load.d/90-vpsctl-bbr.conf"
    local original_path="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/network/bbr/original.conf"
    local path before_metadata first_original

    reset_bbr_effect_logs
    run_bbr --yes enable
    test_assert_bbr_applied bbr fq "initial enable"
    first_original="$(<"$original_path")"
    before_metadata="$(stat -c '%d:%i:%a:%s:%y:%z' -- "$sysctl_path" "$modules_path" "$original_path")"

    reset_bbr_effect_logs
    run_bbr --yes enable
    test_assert_equal 0 "$RUN_STATUS" "repeated enable exit code"
    test_assert_contains "$RUN_OUTPUT" "已处于请求状态，无需重复应用" "repeated enable message"
    test_assert_no_bbr_effects "repeated enable"
    test_assert_equal "$before_metadata" "$(stat -c '%d:%i:%a:%s:%y:%z' -- "$sysctl_path" "$modules_path" "$original_path")" "repeated enable file metadata"
    test_assert_contains "$(<"${TEST_SYSTEM_ROOT}/flock.log")" "-n " "repeated enable acquires lock"
    test_assert_contains "$(<"${TEST_SYSTEM_ROOT}/flock.log")" "-u " "repeated enable releases lock"

    reset_bbr_effect_logs
    run_bbr --yes set --algorithm bbr --qdisc fq
    test_assert_equal 0 "$RUN_STATUS" "repeated set exit code"
    test_assert_contains "$RUN_OUTPUT" "无需重复应用" "repeated set message"
    test_assert_no_bbr_effects "repeated set"
    test_assert_equal "$before_metadata" "$(stat -c '%d:%i:%a:%s:%y:%z' -- "$sysctl_path" "$modules_path" "$original_path")" "repeated set file metadata"

    for path in "$sysctl_path" "$modules_path"; do
        rm -f -- "$path"
        reset_bbr_effect_logs
        run_bbr --yes enable
        test_assert_bbr_applied bbr fq "missing ${path##*/}"
        [[ -f "$path" ]] || test_fail "missing persistence file was not recreated"

        printf '# extra managed-file content\n' >>"$path"
        reset_bbr_effect_logs
        run_bbr --yes enable
        test_assert_bbr_applied bbr fq "modified ${path##*/}"
        test_assert_not_contains "$(<"$path")" "extra managed-file content" "complete persistence content comparison"
    done

    printf 'cubic\n' >"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control"
    reset_bbr_effect_logs
    run_bbr --yes enable
    test_assert_bbr_applied bbr fq "runtime algorithm drift"
    printf 'fq_codel\n' >"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc"
    reset_bbr_effect_logs
    run_bbr --yes enable
    test_assert_bbr_applied bbr fq "runtime default qdisc drift"
    test_assert_equal "$first_original" "$(<"$original_path")" "reapply preserves first original record"

    reset_bbr_effect_logs
    run_bbr --yes set --algorithm cubic --qdisc fq_codel
    test_assert_bbr_applied cubic fq_codel "different requested target"
    test_assert_not_contains "$(<"$modules_path")" "tcp_bbr" "non-BBR module content"
    reset_bbr_effect_logs
    run_bbr --yes set --algorithm cubic --qdisc fq_codel
    test_assert_equal 0 "$RUN_STATUS" "repeated non-BBR set exit code"
    test_assert_contains "$RUN_OUTPUT" "无需重复应用" "repeated non-BBR set message"
    test_assert_no_bbr_effects "repeated non-BBR set"
    reset_bbr_effect_logs
    run_bbr --yes enable
    test_assert_bbr_applied bbr fq "return to BBR target"

    printf 'fq\n' >"${TEST_SYSTEM_ROOT}/tc-root-qdisc"
    reset_bbr_effect_logs
    run_bbr --yes enable --apply-live-qdisc
    test_assert_bbr_applied bbr fq "first matching live snapshot"
    test_assert_contains "$(<"$original_path")" "live_present=1" "first matching live snapshot saved"
    test_assert_contains "$(<"$original_path")" "live_qdisc=fq" "first matching live qdisc saved"
    test_assert_contains "$(<"${TEST_SYSTEM_ROOT}/tc.log")" "qdisc replace dev eth0 root fq" "first live snapshot follows full apply"
    before_metadata="$(stat -c '%d:%i:%a:%s:%y:%z' -- "$sysctl_path" "$modules_path" "$original_path")"

    reset_bbr_effect_logs
    run_bbr --yes enable --apply-live-qdisc
    test_assert_equal 0 "$RUN_STATUS" "repeated live enable exit code"
    test_assert_contains "$RUN_OUTPUT" "无需重复应用" "repeated live enable message"
    test_assert_no_bbr_effects "repeated live enable"
    test_assert_equal "$before_metadata" "$(stat -c '%d:%i:%a:%s:%y:%z' -- "$sysctl_path" "$modules_path" "$original_path")" "repeated live enable file metadata"
    reset_bbr_effect_logs
    run_bbr --yes set --algorithm bbr --qdisc fq --apply-live-qdisc
    test_assert_equal 0 "$RUN_STATUS" "repeated live set exit code"
    test_assert_contains "$RUN_OUTPUT" "无需重复应用" "repeated live set message"
    test_assert_no_bbr_effects "repeated live set"

    printf 'fq_codel\n' >"${TEST_SYSTEM_ROOT}/tc-root-qdisc"
    reset_bbr_effect_logs
    run_bbr --yes enable
    test_assert_equal 0 "$RUN_STATUS" "non-live enable ignores root qdisc drift exit code"
    test_assert_contains "$RUN_OUTPUT" "无需重复应用" "non-live enable ignores root qdisc drift message"
    test_assert_no_bbr_effects "non-live root qdisc drift"
    [[ ! -s "${TEST_SYSTEM_ROOT}/ip.log" && ! -s "${TEST_SYSTEM_ROOT}/tc-query.log" ]] || test_fail "non-live no-op queried live state"
    test_assert_equal fq_codel "$(<"${TEST_SYSTEM_ROOT}/tc-root-qdisc")" "non-live no-op preserves root qdisc"
    reset_bbr_effect_logs
    run_bbr --yes enable --apply-live-qdisc
    test_assert_bbr_applied bbr fq "live root qdisc drift"
    test_assert_equal fq "$(<"${TEST_SYSTEM_ROOT}/tc-root-qdisc")" "live root qdisc drift corrected"

    : >"${TEST_SYSTEM_ROOT}/fail-comparison-read"
    reset_bbr_effect_logs
    run_bbr --yes enable
    test_assert_bbr_applied bbr fq "unconfirmed persistence read"
    : >"${TEST_SYSTEM_ROOT}/fail-live-qdisc-read"
    reset_bbr_effect_logs
    run_bbr --yes enable --apply-live-qdisc
    test_assert_bbr_applied bbr fq "unconfirmed live read with matching output"

    before_metadata="$(stat -c '%d:%i:%a:%s:%y:%z' -- "$sysctl_path" "$modules_path" "$original_path")"
    reset_bbr_effect_logs
    run_bbr --dry-run --yes enable --apply-live-qdisc
    test_assert_equal 0 "$RUN_STATUS" "matching-state dry-run exit code"
    test_assert_contains "$RUN_OUTPUT" "演练" "matching-state dry-run plan"
    test_assert_contains "$RUN_OUTPUT" "modprobe sch_fq" "matching-state dry-run module plan"
    test_assert_contains "$RUN_OUTPUT" "sysctl -w net.ipv4.tcp_congestion_control=bbr" "matching-state dry-run runtime plan"
    test_assert_contains "$RUN_OUTPUT" "tc qdisc replace dev eth0 root fq" "matching-state dry-run live plan"
    test_assert_not_contains "$RUN_OUTPUT" "无需重复应用" "matching-state dry-run does not short-circuit"
    test_assert_no_bbr_effects "matching-state dry-run"
    test_assert_equal "$before_metadata" "$(stat -c '%d:%i:%a:%s:%y:%z' -- "$sysctl_path" "$modules_path" "$original_path")" "matching-state dry-run file metadata"

    rm -f -- "$original_path"
    reset_bbr_effect_logs
    run_bbr --yes enable
    test_assert_bbr_applied bbr fq "matching state without original record"
    test_assert_contains "$(<"$original_path")" "algorithm=bbr" "matching state saved original algorithm"
    test_assert_contains "$(<"$original_path")" "sysctl_present=1" "matching state saved original persistence"
    printf 'unknown_key=value\n' >>"$original_path"
    reset_bbr_effect_logs
    run_bbr --yes enable
    test_assert_equal 10 "$RUN_STATUS" "matching state with damaged original exit code"
    test_assert_contains "$RUN_OUTPUT" "未知键" "matching state with damaged original message"
    test_assert_not_contains "$RUN_OUTPUT" "无需重复应用" "damaged original is not masked by no-op"
    test_assert_no_bbr_effects "damaged original"

    rm -f -- "$sysctl_path" "$modules_path" "$original_path"
    printf 'cubic\n' >"${TEST_SYSTEM_ROOT}/proc/sys/net/ipv4/tcp_congestion_control"
    printf 'fq_codel\n' >"${TEST_SYSTEM_ROOT}/proc/sys/net/core/default_qdisc"
    printf 'fq_codel\n' >"${TEST_SYSTEM_ROOT}/tc-root-qdisc"
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
test_interactive_menu
test_dry_run
test_apply_confirmation
test_symlink_guards
test_unavailable_algorithm
test_transaction_rollback
test_live_qdisc_rollback
test_non_live_then_first_live_snapshot
test_original_state_validation
test_repeated_apply
test_persistence_and_restore
printf 'PASS: network bbr tests\n'
