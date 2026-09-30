#!/usr/bin/env bash
# The server-test runner is exercised with a hermetic curl and controlled temp
# root. No network request or third-party test script is executed.

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
TEST_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-server-test.XXXXXX")"
readonly TEST_TEMP
readonly MOCK_BIN="${TEST_TEMP}/mock-bin"
readonly MOCK_LOG="${TEST_TEMP}/mock.log"
readonly SYSTEM_ROOT="${TEST_TEMP}/system-root"
readonly RUN_BASE="${TEST_TEMP}/run-base"
readonly TCP_TOKEN="vpsctl-server-test-${BASHPID}"
readonly TCP_EXTERNAL_EXISTING="/tmp/zstatic_nping_${TCP_TOKEN}-existing.csv"
readonly TCP_EXTERNAL_NEW="/tmp/zstatic_nping_${TCP_TOKEN}-new.csv"
readonly TCP_EXTERNAL_OVERLAP="/tmp/zstatic_nping_${TCP_TOKEN}-overlap.csv"

cleanup() {
    rm -f -- "$TCP_EXTERNAL_EXISTING" "$TCP_EXTERNAL_NEW" "$TCP_EXTERNAL_OVERLAP"
    rm -rf -- "$TEST_TEMP"
}
trap cleanup EXIT

mkdir -p "$MOCK_BIN" "$SYSTEM_ROOT" "$RUN_BASE"
: >"$MOCK_LOG"

cat >"${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=""
url="${!#}"
while (($# > 0)); do
    if [[ "$1" == -o ]]; then
        output="$2"
        shift 2
        continue
    fi
    shift
done
printf 'curl-url=%s\n' "$url" >>"$MOCK_LOG"
if [[ "${MOCK_CURL_STATUS:-0}" != 0 ]]; then
    exit "$MOCK_CURL_STATUS"
fi
[[ -n "$output" ]] || exit 98
cat >"$output" <<'UPSTREAM'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'upstream-kind=%s args=%s cwd=%s tmpdir=%s rootfs-tmp=%s output-dir=%s\n' \
    "$MOCK_KIND" "$#" "$PWD" "${TMPDIR:-}" "${TCPQUALITY_ROOTFS_TMPDIR:-}" \
    "${TCPQUALITY_OUTPUT_DIR:-}" >>"$MOCK_LOG"
if [[ "$MOCK_KIND" == tcpquality ]]; then
    [[ "${TMPDIR:-}" == "$PWD" && "${TCPQUALITY_ROOTFS_TMPDIR:-}" == "$PWD" && \
        "${TCPQUALITY_OUTPUT_DIR:-}" == "$PWD" ]] || exit 99
fi
if [[ "${MOCK_READ_STDIN:-0}" == 1 ]]; then
    IFS= read -r upstream_input
    printf 'upstream-input=%s\n' "$upstream_input" >>"$MOCK_LOG"
fi
if [[ "${MOCK_SIGNAL_WAIT:-0}" == 1 ]]; then
    trap 'printf "upstream-signal=TERM\n" >>"$MOCK_LOG"; exit 143' TERM
    : >"$MOCK_READY"
    while :; do sleep 0.1; done
fi
if [[ "$MOCK_KIND" == tcpquality && "${MOCK_CREATE_TCP_ARTIFACTS:-0}" == 1 ]]; then
    : >"${TCPQUALITY_OUTPUT_DIR}/zstatic_nping_fixture.csv"
    : >"${TCPQUALITY_OUTPUT_DIR}/tcpquality-report.tar.gz"
    : >"${TCPQUALITY_OUTPUT_DIR}/tcpquality.log"
    if [[ -n "${MOCK_TCP_EXTERNAL_FILE:-}" ]]; then
        : >"$MOCK_TCP_EXTERNAL_FILE"
    fi
    printf '%s\n' "$TCPQUALITY_OUTPUT_DIR" >"$MOCK_READY"
    if [[ -n "${MOCK_TCP_RELEASE:-}" ]]; then
        for ((attempt = 0; attempt < 200; attempt++)); do
            [[ -e "$MOCK_TCP_RELEASE" ]] && break
            sleep 0.05
        done
        [[ -e "$MOCK_TCP_RELEASE" ]] || exit 98
        [[ -f "${TCPQUALITY_OUTPUT_DIR}/zstatic_nping_fixture.csv" && \
            -f "${TCPQUALITY_OUTPUT_DIR}/tcpquality-report.tar.gz" && \
            -f "${TCPQUALITY_OUTPUT_DIR}/tcpquality.log" ]] || exit 97
        [[ -z "${MOCK_TCP_EXTERNAL_FILE:-}" || -f "$MOCK_TCP_EXTERNAL_FILE" ]] || exit 96
        : >"${MOCK_READY}.checked"
    fi
fi
exit "$MOCK_UPSTREAM_STATUS"
UPSTREAM
EOF
chmod 0755 "${MOCK_BIN}/curl"

# shellcheck source=/dev/null
source "${TEST_ROOT}/lib/command.sh"
# shellcheck source=/dev/null
source "${TEST_ROOT}/lib/server-test.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_equal() {
    local expected="$1" actual="$2" message="$3"
    [[ "$actual" == "$expected" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

assert_contains() {
    local value="$1" expected="$2" message="$3"
    [[ "$value" == *"$expected"* ]] || fail "${message}: missing '${expected}'"
}

assert_file_contains() {
    local path="$1" expected="$2" message="$3"
    grep -Fq -- "$expected" "$path" || fail "${message}: missing '${expected}'"
}

curl_call_count() {
    grep -c '^curl-url=' "$MOCK_LOG" || true
}

run_entry() {
    local kind="$1" upstream_status="$2"
    shift 2
    env \
        PATH="${MOCK_BIN}:$PATH" \
        VPSCTL_TESTING=1 \
        VPSCTL_SYSTEM_ROOT="$SYSTEM_ROOT" \
        VPS_SERVER_TEST_TMP_BASE="$RUN_BASE" \
        MOCK_LOG="$MOCK_LOG" \
        MOCK_KIND="$kind" \
        MOCK_CURL_STATUS="${MOCK_CURL_STATUS:-0}" \
        MOCK_UPSTREAM_STATUS="$upstream_status" \
        MOCK_SIGNAL_WAIT="${MOCK_SIGNAL_WAIT:-0}" \
        MOCK_READ_STDIN="${MOCK_READ_STDIN:-0}" \
        MOCK_READY="${MOCK_READY:-${TEST_TEMP}/unused-ready}" \
        MOCK_CREATE_TCP_ARTIFACTS="${MOCK_CREATE_TCP_ARTIFACTS:-0}" \
        MOCK_TCP_EXTERNAL_FILE="${MOCK_TCP_EXTERNAL_FILE:-}" \
        MOCK_TCP_RELEASE="${MOCK_TCP_RELEASE:-}" \
        bash "${TEST_ROOT}/commands/test/${kind}.sh" --no-color "$@"
}

test_upstream_interactive_input() {
    local status=0

    MOCK_READ_STDIN=1 run_entry nodequality 0 <<<"official-choice" >/dev/null 2>&1 || status=$?
    assert_equal 0 "$status" "official upstream stdin status"
    assert_file_contains "$MOCK_LOG" "upstream-input=official-choice" "official upstream stdin forwarding"
    [[ -z "$(find "$RUN_BASE" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "interactive input run directory was not cleaned"
}

test_signal_forwarding_and_cleanup() {
    local pid status=0 attempt
    local ready="${TEST_TEMP}/signal-ready" output="${TEST_TEMP}/signal-output.log"

    env \
        PATH="${MOCK_BIN}:$PATH" \
        VPSCTL_TESTING=1 \
        VPSCTL_SYSTEM_ROOT="$SYSTEM_ROOT" \
        VPS_SERVER_TEST_TMP_BASE="$RUN_BASE" \
        MOCK_LOG="$MOCK_LOG" \
        MOCK_KIND=nodequality \
        MOCK_CURL_STATUS=0 \
        MOCK_UPSTREAM_STATUS=0 \
        MOCK_SIGNAL_WAIT=1 \
        MOCK_READY="$ready" \
        MOCK_CREATE_TCP_ARTIFACTS=0 \
        bash "${TEST_ROOT}/commands/test/nodequality.sh" --no-color >"$output" 2>&1 &
    pid=$!
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -e "$ready" ]] && break
        sleep 0.05
    done
    if [[ ! -e "$ready" ]]; then
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        fail "signal fixture did not start"
    fi
    kill -TERM "$pid"
    wait "$pid" || status=$?

    assert_equal 143 "$status" "TERM status propagation"
    assert_file_contains "$MOCK_LOG" "upstream-signal=TERM" "TERM forwarded to upstream"
    [[ -z "$(find "$RUN_BASE" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "signal-interrupted run directory was not cleaned"
}

test_download_failure_cleanup() {
    local before output status=0

    before="$(curl_call_count)"
    MOCK_CURL_STATUS=22
    output="$(run_entry nodequality 0 2>&1)" || status=$?
    MOCK_CURL_STATUS=0
    assert_equal 20 "$status" "official script download failure status"
    assert_contains "$output" "下载官方服务器测试脚本失败" "official script download failure message"
    assert_equal "$((before + 1))" "$(curl_call_count)" "download failure request count"
    [[ -z "$(find "$RUN_BASE" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "failed download run directory was not cleaned"
}

test_argument_guards() {
    local before output status=0

    before="$(curl_call_count)"
    output="$(run_entry nodequality 0 --help 2>&1)" || status=$?
    assert_equal 0 "$status" "NodeQuality help status"
    assert_contains "$output" "NodeQuality" "NodeQuality help"
    assert_equal "$before" "$(curl_call_count)" "NodeQuality help must not download"

    status=0
    output="$(run_entry tcpquality 0 help 2>&1)" || status=$?
    assert_equal 0 "$status" "TCPQuality help status"
    assert_contains "$output" "TcpQuality" "TCPQuality help"
    assert_equal "$before" "$(curl_call_count)" "TCPQuality help must not download"

    status=0
    output="$(run_entry nodequality 0 --dry-run 2>&1)" || status=$?
    assert_equal 2 "$status" "server-test dry-run rejection"
    assert_contains "$output" "不支持 --dry-run" "server-test dry-run message"
    assert_equal "$before" "$(curl_call_count)" "dry-run rejection must precede download"

    status=0
    output="$(run_entry tcpquality 0 unexpected 2>&1)" || status=$?
    assert_equal 2 "$status" "unknown upstream argument rejection"
    assert_contains "$output" "不接受参数" "unknown upstream argument message"
    assert_equal "$before" "$(curl_call_count)" "unknown argument rejection must precede download"

    status=0
    output="$(run_entry nodequality 0 --non-interactive 2>&1)" || status=$?
    assert_equal 2 "$status" "non-interactive server-test rejection"
    assert_contains "$output" "非交互" "non-interactive server-test message"
    assert_equal "$before" "$(curl_call_count)" "non-interactive rejection must precede download"
}

test_official_download_and_exit_contract() {
    local output status=0

    output="$(run_entry nodequality 1 2>&1)" || status=$?
    assert_equal 0 "$status" "NodeQuality upstream status 1 translation"
    assert_contains "$output" "按成功处理" "NodeQuality status 1 explanation"
    assert_file_contains "$MOCK_LOG" "curl-url=https://run.NodeQuality.com" "NodeQuality official URL"
    assert_file_contains "$MOCK_LOG" "upstream-kind=nodequality args=0 cwd=${RUN_BASE}/vpsctl-server-test.nodequality." "NodeQuality zero args and controlled cwd"
    [[ -z "$(find "$RUN_BASE" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "NodeQuality run directory was not cleaned"

    status=0
    run_entry tcpquality 7 >/dev/null 2>&1 || status=$?
    assert_equal 7 "$status" "TCPQuality upstream non-1 status propagation"
    assert_file_contains "$MOCK_LOG" "curl-url=https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh" "TCPQuality official URL"
    assert_file_contains "$MOCK_LOG" "upstream-kind=tcpquality args=0" "TCPQuality receives no upstream args"
    assert_file_contains "$MOCK_LOG" "tmpdir=${RUN_BASE}/vpsctl-server-test.tcpquality." "TCPQuality controlled TMPDIR"
    assert_file_contains "$MOCK_LOG" "rootfs-tmp=${RUN_BASE}/vpsctl-server-test.tcpquality." "TCPQuality controlled rootfs temp"
    assert_file_contains "$MOCK_LOG" "output-dir=${RUN_BASE}/vpsctl-server-test.tcpquality." "TCPQuality controlled output directory"
    [[ -z "$(find "$RUN_BASE" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "TCPQuality run directory was not cleaned"
}

test_tcp_output_cleanup_ownership() {
    local status=0 run_dir ready="${TEST_TEMP}/tcp-output-ready"

    : >"$TCP_EXTERNAL_EXISTING"
    MOCK_CREATE_TCP_ARTIFACTS=1 MOCK_READY="$ready" MOCK_TCP_EXTERNAL_FILE="$TCP_EXTERNAL_NEW" \
        run_entry tcpquality 0 >/dev/null 2>&1 || status=$?

    assert_equal 0 "$status" "TCPQuality output cleanup status"
    [[ -f "$ready" ]] || fail "TCPQuality output artifacts were not created"
    run_dir="$(<"$ready")"
    [[ "$run_dir" == "${RUN_BASE}/vpsctl-server-test.tcpquality."* ]] || fail "TCPQuality output directory escaped run base"
    [[ ! -e "$run_dir" ]] || fail "TCPQuality output directory was not cleaned"
    [[ -f "$TCP_EXTERNAL_EXISTING" ]] || fail "pre-existing external TCP CSV was removed"
    [[ -f "$TCP_EXTERNAL_NEW" ]] || fail "new external TCP CSV was removed"
}

wait_for_fixture_file() {
    local path="$1" attempt

    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ -s "$path" ]] && return 0
        sleep 0.05
    done
    return 1
}

test_tcp_overlapping_cleanup() (
    local barrier="${TEST_TEMP}/tcp-overlap" pid_a="" pid_b="" status=0 run_dir_a run_dir_b

    mkdir -p "$barrier"
    trap '
        : >"$barrier/a.release"
        : >"$barrier/b.release"
        [[ -z "$pid_a" ]] || wait "$pid_a" 2>/dev/null || true
        [[ -z "$pid_b" ]] || wait "$pid_b" 2>/dev/null || true
    ' EXIT

    MOCK_CREATE_TCP_ARTIFACTS=1 MOCK_READY="$barrier/a.ready" MOCK_TCP_RELEASE="$barrier/a.release" \
        run_entry tcpquality 0 >"$barrier/a.output" 2>&1 &
    pid_a=$!
    wait_for_fixture_file "$barrier/a.ready" || fail "first overlapping TCPQuality fixture did not start"

    MOCK_CREATE_TCP_ARTIFACTS=1 MOCK_READY="$barrier/b.ready" MOCK_TCP_RELEASE="$barrier/b.release" \
        MOCK_TCP_EXTERNAL_FILE="$TCP_EXTERNAL_OVERLAP" run_entry tcpquality 0 >"$barrier/b.output" 2>&1 &
    pid_b=$!
    wait_for_fixture_file "$barrier/b.ready" || fail "second overlapping TCPQuality fixture did not start"

    run_dir_a="$(<"$barrier/a.ready")"
    run_dir_b="$(<"$barrier/b.ready")"
    [[ "$run_dir_a" != "$run_dir_b" ]] || fail "overlapping TCPQuality runs shared an output directory"
    [[ -f "$run_dir_a/zstatic_nping_fixture.csv" && -f "$run_dir_b/zstatic_nping_fixture.csv" ]] || \
        fail "overlapping TCPQuality output artifacts were not created"

    # B stays in its upstream fixture until A has finished cleanup.
    : >"$barrier/a.release"
    wait "$pid_a" || status=$?
    pid_a=""
    assert_equal 0 "$status" "first overlapping TCPQuality cleanup status"
    [[ ! -e "$run_dir_a" ]] || fail "first overlapping TCPQuality output directory was not cleaned"
    [[ -d "$run_dir_b" ]] || fail "first TCPQuality run removed the second run's output directory"

    : >"$barrier/b.release"
    wait "$pid_b" || status=$?
    pid_b=""
    assert_equal 0 "$status" "second overlapping TCPQuality cleanup status"
    [[ -f "$barrier/b.ready.checked" ]] || fail "second TCPQuality run did not check its artifacts after the first finished"
    [[ -f "$TCP_EXTERNAL_OVERLAP" ]] || fail "first TCPQuality run removed the second run's external CSV"
    [[ ! -e "$run_dir_b" ]] || fail "second overlapping TCPQuality output directory was not cleaned"
    [[ -z "$(find "$RUN_BASE" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "overlapping TCPQuality run directory was not cleaned"
)

test_mount_residue_blocks_removal() {
    local status=0 run_dir="${RUN_BASE}/vpsctl-server-test.nodequality.Mount123" rm_log="${TEST_TEMP}/rm.log"

    mkdir -p "$run_dir"
    VPS_SERVER_TEST_RUN_BASE="$RUN_BASE"
    VPS_SERVER_TEST_RUN_KIND=nodequality
    VPS_SERVER_TEST_RUN_DIR="$run_dir"
    vps_server_test_collect_mounts() {
        VPS_SERVER_TEST_MOUNTS=("$1/stuck")
    }
    umount() {
        return 1
    }
    rm() {
        printf 'rm %s\n' "$*" >>"$rm_log"
    }

    vps_server_test_cleanup_run_dir >/dev/null 2>&1 || status=$?
    unset -f vps_server_test_collect_mounts umount rm
    assert_equal 30 "$status" "mount residue cleanup status"
    [[ -d "$run_dir" ]] || fail "mount residue run directory was removed"
    [[ ! -e "$rm_log" ]] || fail "rm was invoked despite mount residue"
    rm -rf -- "$run_dir"
}

test_argument_guards
test_download_failure_cleanup
test_official_download_and_exit_contract
test_upstream_interactive_input
test_signal_forwarding_and_cleanup
test_tcp_output_cleanup_ownership
test_tcp_overlapping_cleanup
test_mount_residue_blocks_removal
printf 'PASS: server-test unit tests\n'
