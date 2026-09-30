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
if [[ -n "${MOCK_TREE_DIR:-}" ]]; then
    cat >"$PWD/tree-worker.sh" <<'WORKER'
#!/usr/bin/env bash
trap '' HUP INT TERM
printf '%s\n' "$BASHPID" >"$MOCK_TREE_DIR/$1.pid"
if [[ "$1" == branch ]]; then
    trap 'bash "$0" late &' TERM
    bash "$0" leaf &
else
    sleep 120 &
    printf '%s\n' "$!" >"$MOCK_TREE_DIR/$1-sleep.pid"
fi
while :; do wait || true; done
WORKER
    trap 'printf "exited\n" >"$MOCK_TREE_DIR/root-exited"; exit 143' TERM
    printf '%s\n' "$BASHPID" >"$MOCK_TREE_DIR/root.pid"
    printf '%s\n' "$PWD" >"$MOCK_TREE_DIR/run-dir"
    bash "$PWD/tree-worker.sh" branch &
    wait
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
        MOCK_TREE_DIR="${MOCK_TREE_DIR:-}" \
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

fixture_process_is_running() {
    local state

    state="$(ps -o stat= -p "$1")" || return 1
    [[ -n "$state" && "$state" != Z* && "$state" != X* ]]
}

test_signal_descendant_cleanup() (
    local tree="${TEST_TEMP}/signal-tree" wrapper="" outsider="" pid path status=0 run_dir
    local started elapsed

    mkdir -p "$tree"
    trap '
        [[ -z "$wrapper" ]] || kill -KILL "$wrapper" 2>/dev/null || true
        [[ -z "$outsider" ]] || kill -KILL "$outsider" 2>/dev/null || true
        for path in "$tree"/*.pid; do
            [[ -f "$path" ]] || continue
            pid="$(<"$path")"
            kill -KILL "$pid" 2>/dev/null || true
        done
        wait 2>/dev/null || true
    ' EXIT

    sleep 120 &
    outsider=$!
    env PATH="${MOCK_BIN}:$PATH" VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$SYSTEM_ROOT" \
        VPS_SERVER_TEST_TMP_BASE="$RUN_BASE" MOCK_LOG="$MOCK_LOG" MOCK_KIND=nodequality \
        MOCK_CURL_STATUS=0 MOCK_UPSTREAM_STATUS=0 MOCK_TREE_DIR="$tree" \
        bash "${TEST_ROOT}/commands/test/nodequality.sh" --no-color >"$tree/output" 2>&1 &
    wrapper=$!
    wait_for_fixture_file "$tree/leaf-sleep.pid" || fail "multi-level signal fixture did not start"
    run_dir="$(<"$tree/run-dir")"
    assert_equal "$(ps -o pgid= -p "$outsider")" "$(ps -o pgid= -p "$wrapper")" "unrelated fixture shares process group"
    started=$SECONDS
    kill -TERM "$wrapper"
    wait_for_fixture_file "$tree/root-exited" || fail "upstream did not exit before stubborn descendants"
    wait_for_fixture_file "$tree/late-sleep.pid" || fail "TERM handler did not create a late descendant"
    [[ -d "$run_dir" ]] || fail "run directory removed before descendant shutdown"
    fixture_process_is_running "$(<"$tree/leaf.pid")" || fail "TERM-ignoring leaf exited before KILL"
    kill -HUP "$wrapper"
    kill -TERM "$wrapper"
    wait "$wrapper" || status=$?
    wrapper=""
    elapsed=$((SECONDS - started))
    assert_equal 143 "$status" "first signal status survives repeated interruption"
    ((elapsed >= 5 && elapsed <= 15)) || fail "descendant shutdown did not respect bounded grace: ${elapsed}s"
    for path in "$tree"/*.pid; do
        pid="$(<"$path")"
        if fixture_process_is_running "$pid"; then
            fail "descendant remained active after interrupted cleanup: $pid ($path)"
        fi
    done
    fixture_process_is_running "$outsider" || fail "unrelated process in caller group was signalled"
    [[ ! -e "$run_dir" ]] || fail "descendant cleanup left run directory"
)

test_process_identity_checks() (
    local pid="" status=0 actual_start

    trap '[[ -z "$pid" ]] || kill -KILL "$pid" 2>/dev/null || true; wait 2>/dev/null || true' EXIT
    sleep 120 &
    pid=$!
    vps_server_test_read_process "$pid" || fail "could not read live fixture identity"
    actual_start="$VPS_SERVER_TEST_PROC_STARTTIME"
    VPS_SERVER_TEST_PROCESSES=(["$pid"]="$((actual_start + 1))")
    vps_server_test_kill_child TERM
    fixture_process_is_running "$pid" || fail "starttime mismatch signalled a reused PID"
    vps_server_test_child_is_running && fail "starttime mismatch counted as this run's process"

    VPS_SERVER_TEST_PROCESSES=(["$pid"]="")
    vps_server_test_kill_child KILL
    fixture_process_is_running "$pid" || fail "unknown starttime was signalled"
    vps_server_test_child_is_running || fail "unknown live identity treated as exited"
    vps_server_test_process_is_running "$pid" "" || status=$?
    assert_equal 2 "$status" "unknown identity status"

    kill -KILL "$pid"
    wait "$pid" 2>/dev/null || true
    status=0
    vps_server_test_read_process "$pid" || status=$?
    assert_equal 1 "$status" "missing proc entry confirms exit"
    pid=""

    # A process whose launch identity was unreadable may already be a zombie
    # when /proc becomes readable again. It cannot keep the run active.
    # The sourced process-state helper calls this override.
    # shellcheck disable=SC2317
    vps_server_test_read_process() {
        VPS_SERVER_TEST_PROC_STATE=Z
        VPS_SERVER_TEST_PROC_STARTTIME=fixture-start
    }
    status=0
    vps_server_test_process_is_running 99999999 "" || status=$?
    assert_equal 1 "$status" "zombie with unknown launch identity is not running"
)

test_signal_during_identity_registration() (
    local pid status=0 run_dir="${RUN_BASE}/vpsctl-server-test.nodequality.Start123"

    mkdir -p "$run_dir"
    printf '#!/usr/bin/env bash\nexec sleep 120\n' >"$run_dir/upstream.sh"
    VPS_SERVER_TEST_RUN_BASE="$RUN_BASE"
    VPS_SERVER_TEST_RUN_KIND=nodequality
    VPS_SERVER_TEST_RUN_DIR="$run_dir"
    # Interrupt at the exact launch/identity-registration boundary. The real
    # reader then fills the same identity, and the pending signal skips wait.
    eval "$(declare -f vps_server_test_read_process | sed '1s/vps_server_test_read_process/fixture_read_process/')"
    # The sourced upstream runner calls this override during registration.
    # shellcheck disable=SC2317
    vps_server_test_read_process() {
        if [[ -z "$VPS_SERVER_TEST_CHILD_STARTTIME" ]]; then
            kill -TERM "$BASHPID"
        fi
        fixture_read_process "$@"
    }
    trap 'vps_server_test_handle_signal TERM 143' TERM
    vps_server_test_run_upstream nodequality "$run_dir/upstream.sh" || status=$?
    pid="$VPS_SERVER_TEST_CHILD_PID"
    assert_equal 143 "$status" "signal during identity registration status"
    [[ -n "$VPS_SERVER_TEST_CHILD_STARTTIME" ]] || fail "interrupted launch lost child identity"
    fixture_process_is_running "$pid" && fail "interrupted launch left upstream running"
    vps_server_test_cleanup_run_dir || fail "interrupted launch did not clean run directory"
)

test_signal_before_wait() (
    local scenario="$1" run_dir="${RUN_BASE}/vpsctl-server-test.nodequality.Wait${1}123"
    local output="${TEST_TEMP}/before-wait-${scenario}.log" pid_file="${TEST_TEMP}/before-wait-${scenario}.pid"
    local wait_marker="${TEST_TEMP}/before-wait-${scenario}.entered" status=0 pid

    mkdir -p "$run_dir"
    printf '#!/usr/bin/env bash\nexec sleep 120\n' >"$run_dir/upstream.sh"
    (
        local injected=0
        VPS_SERVER_TEST_RUN_BASE="$RUN_BASE"
        VPS_SERVER_TEST_RUN_KIND=nodequality
        VPS_SERVER_TEST_RUN_DIR="$run_dir"
        VPS_SERVER_TEST_EXIT_CLEANUP_ACTIVE=1
        # The sourced upstream runner calls wait and the nested reader override.
        # shellcheck disable=SC2317
        wait() {
            if ((injected == 0)); then
                injected=1
                printf '%s\n' "$VPS_SERVER_TEST_CHILD_PID" >"$pid_file"
                if [[ "$scenario" == Failure ]]; then
                    # Preserve the real launched process, but make its identity
                    # unconfirmable after registration. The trap must exit 30.
                    vps_server_test_read_process() { return 2; }
                fi
                kill -TERM "$BASHPID"
                : >"$wait_marker"
            fi
            builtin wait "$@"
        }
        trap vps_server_test_exit_cleanup EXIT
        trap 'vps_server_test_handle_signal TERM 143' TERM
        vps_server_test_run_upstream nodequality "$run_dir/upstream.sh" || status=$?
        exit "$status"
    ) >"$output" 2>&1 || status=$?
    pid="$(<"$pid_file")"
    if [[ "$scenario" == Failure ]]; then
        # The wrapper deliberately leaves this fixture alive on uncertainty.
        kill -KILL "$pid" 2>/dev/null || true
        assert_equal 30 "$status" "failed shutdown before wait status"
        [[ ! -e "$wait_marker" ]] || fail "failed signal cleanup proceeded to blocking wait"
        [[ -d "$run_dir" ]] || fail "failed shutdown before wait removed directory"
        assert_file_contains "$output" "$run_dir" "failed shutdown before wait directory diagnostic"
        rm -rf -- "$run_dir"
    else
        assert_equal 143 "$status" "signal before wait status"
        [[ -e "$wait_marker" ]] || fail "successful signal cleanup did not resume wait"
        fixture_process_is_running "$pid" && fail "signal before wait left upstream running"
        [[ ! -e "$run_dir" ]] || fail "signal before wait did not clean directory"
    fi
)

test_process_cleanup_failure_preserves_directory() (
    local scenario="$1" run_dir="${RUN_BASE}/vpsctl-server-test.nodequality.Fail${1}123"
    local output="${TEST_TEMP}/cleanup-failure-${scenario}.log" status=0
    local pid="$BASHPID" signal_log="${TEST_TEMP}/cleanup-signals-${scenario}.log"
    local mount_log="${TEST_TEMP}/cleanup-mount-${scenario}.log"

    mkdir -p "$run_dir"
    (
        VPS_SERVER_TEST_RUN_BASE="$RUN_BASE"
        VPS_SERVER_TEST_RUN_KIND=nodequality
        VPS_SERVER_TEST_RUN_DIR="$run_dir"
        VPS_SERVER_TEST_PROCESSES=(["$pid"]="fixture-start")
        VPS_SERVER_TEST_EXIT_CLEANUP_ACTIVE=1
        # The sourced cleanup functions call these test doubles indirectly.
        # shellcheck disable=SC2317
        vps_server_test_collect_processes() { :; }
        # shellcheck disable=SC2317
        vps_server_test_read_process() {
            [[ "$scenario" != Unknown ]] || return 2
            # The sourced state checker consumes these values in this subshell.
            # shellcheck disable=SC2034
            VPS_SERVER_TEST_PROC_STATE=S
            # shellcheck disable=SC2030
            VPS_SERVER_TEST_PROC_STARTTIME=fixture-start
        }
        # shellcheck disable=SC2317
        kill() {
            local IFS=' '
            printf '%s\n' "$*" >>"$signal_log"
        }
        # shellcheck disable=SC2317
        vps_server_test_unmount_run_dir() { : >"$mount_log"; }
        trap vps_server_test_exit_cleanup EXIT
        vps_server_test_wait_for_child_cleanup TERM || status=$?
        assert_equal 30 "$status" "${scenario} shutdown failure status"
        status=0
        vps_server_test_cleanup_run_dir || status=$?
        assert_equal 30 "$status" "${scenario} explicit cleanup failure status"
        # EXIT must reuse the failed outcome instead of trying to remove again.
        exit 17
    ) >"$output" 2>&1 || status=$?
    assert_equal 30 "$status" "${scenario} EXIT cleanup failure overrides original status"
    [[ -d "$run_dir" ]] || fail "${scenario} shutdown failure removed directory"
    [[ ! -e "$mount_log" ]] || fail "${scenario} shutdown failure attempted unmount"
    assert_file_contains "$output" "PID：$pid" "${scenario} shutdown failure PID diagnostic"
    assert_file_contains "$output" "$run_dir" "${scenario} shutdown failure directory diagnostic"
    assert_equal 1 "$(grep -c '无法确认退出' "$output")" "${scenario} cleanup result reused by EXIT"
    if [[ "$scenario" == Alive ]]; then
        assert_equal 2 "$(wc -l <"$signal_log")" "TERM and KILL sent only once"
    else
        [[ ! -e "$signal_log" ]] || fail "unknown process identity received a signal"
    fi
    rm -rf -- "$run_dir"
)

test_abnormal_exit_process_cleanup() (
    local run_dir="${RUN_BASE}/vpsctl-server-test.nodequality.Exit123" status=0 pid
    local ready="${TEST_TEMP}/exit-process.pid"

    mkdir -p "$run_dir"
    (
        VPS_SERVER_TEST_RUN_BASE="$RUN_BASE"
        VPS_SERVER_TEST_RUN_KIND=nodequality
        VPS_SERVER_TEST_RUN_DIR="$run_dir"
        # The sourced EXIT handler consumes this flag.
        # shellcheck disable=SC2034
        VPS_SERVER_TEST_EXIT_CLEANUP_ACTIVE=1
        sleep 120 &
        VPS_SERVER_TEST_CHILD_PID=$!
        printf '%s\n' "$VPS_SERVER_TEST_CHILD_PID" >"$ready"
        vps_server_test_read_process "$VPS_SERVER_TEST_CHILD_PID"
        # The reader above sets a fresh value in this test's own subshell.
        # shellcheck disable=SC2031
        VPS_SERVER_TEST_CHILD_STARTTIME="$VPS_SERVER_TEST_PROC_STARTTIME"
        # The sourced EXIT handler consumes this process identity map.
        # shellcheck disable=SC2034
        VPS_SERVER_TEST_PROCESSES=(["$VPS_SERVER_TEST_CHILD_PID"]="$VPS_SERVER_TEST_CHILD_STARTTIME")
        trap vps_server_test_exit_cleanup EXIT
        exit 17
    ) >/dev/null 2>&1 || status=$?
    pid="$(<"$ready")"
    assert_equal 17 "$status" "successful abnormal EXIT cleanup preserves original status"
    fixture_process_is_running "$pid" && fail "abnormal EXIT left upstream running"
    [[ ! -e "$run_dir" ]] || fail "abnormal EXIT did not clean run directory"
)

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
test_signal_descendant_cleanup
test_process_identity_checks
test_signal_during_identity_registration
test_signal_before_wait Success
test_signal_before_wait Failure
test_process_cleanup_failure_preserves_directory Alive
test_process_cleanup_failure_preserves_directory Unknown
test_abnormal_exit_process_cleanup
test_tcp_output_cleanup_ownership
test_tcp_overlapping_cleanup
test_mount_residue_blocks_removal
printf 'PASS: server-test unit tests\n'
