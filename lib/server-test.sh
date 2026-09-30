# shellcheck shell=bash
# Shared runner for third-party, one-shot server quality tests.
# The caller must source lib/command.sh before this file.

VPS_SERVER_TEST_RUN_DIR=""
VPS_SERVER_TEST_RUN_BASE=""
VPS_SERVER_TEST_RUN_KIND=""
VPS_SERVER_TEST_CHILD_PID=""
VPS_SERVER_TEST_CHILD_STARTTIME=""
VPS_SERVER_TEST_SIGNAL_STATUS=0
VPS_SERVER_TEST_SIGNAL=""
VPS_SERVER_TEST_PROCESS_CLEANUP_DONE=0
VPS_SERVER_TEST_PROCESS_CLEANUP_STATUS=0
VPS_SERVER_TEST_EXIT_CLEANUP_ACTIVE=0
declare -ga VPS_SERVER_TEST_MOUNTS=()
declare -gA VPS_SERVER_TEST_PROCESSES=()
declare -gA VPS_SERVER_TEST_PROCESS_SIGNALLED=()
declare -ga VPS_SERVER_TEST_REMAINING=()
VPS_SERVER_TEST_PROC_STATE=""
VPS_SERVER_TEST_PROC_PPID=""
VPS_SERVER_TEST_PROC_STARTTIME=""

vps_server_test_require_linux() {
    [[ "${VPSCTL_TESTING:-0}" == "1" || "$(uname -s 2>/dev/null || true)" == "Linux" ]] && return 0
    vps_cmd_error "服务器测试仅支持 Linux"
    return 3
}

vps_server_test_require_tools() {
    local tool

    for tool in awk curl df mktemp chmod rm umount sleep; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            vps_cmd_error "服务器测试缺少必需命令：$tool"
            return 3
        fi
    done
}

vps_server_test_validate_kind() {
    case "${1:-}" in
        nodequality | tcpquality) return 0 ;;
        *)
            vps_cmd_error "未知服务器测试类型：${1:-<空>}"
            return 2
            ;;
    esac
}

vps_server_test_validate_url() {
    local kind="$1" url="$2"

    case "$kind:$url" in
        'nodequality:https://run.NodeQuality.com' | 'tcpquality:https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh')
            return 0
            ;;
        *)
            vps_cmd_error "拒绝非官方服务器测试下载地址"
            return 2
            ;;
    esac
}

vps_server_test_temp_base() {
    local base resolved candidate free best="" best_free=-1

    if [[ "${VPSCTL_TESTING:-0}" == "1" && -n "${VPS_SERVER_TEST_TMP_BASE:-}" ]]; then
        base="$VPS_SERVER_TEST_TMP_BASE"
        [[ "$base" == /* && "$base" != / && -d "$base" && ! -L "$base" ]] || {
            vps_cmd_error "服务器测试临时目录根路径不安全：$base"
            return 3
        }
        resolved="$(cd -- "$base" && pwd -P)" || return 20
        [[ "$resolved" == /* && "$resolved" != / && -d "$resolved" ]] || return 3
        printf '%s\n' "$resolved"
        return 0
    fi

    # VPS installations commonly mount /tmp as a small tmpfs. Prefer the safe
    # candidate with more free space so large upstream rootfs archives do not
    # exhaust memory-backed storage.
    for candidate in /var/tmp /tmp; do
        [[ -d "$candidate" && -w "$candidate" && ! -L "$candidate" ]] || continue
        resolved="$(cd -- "$candidate" && pwd -P)" || continue
        [[ "$resolved" == "$candidate" ]] || continue
        free="$(df -Pk "$resolved" 2>/dev/null | awk 'NR == 2 { print $4; exit }')"
        [[ "$free" =~ ^[0-9]+$ ]] || continue
        if ((free > best_free)); then
            best="$resolved"
            best_free="$free"
        fi
    done
    [[ -n "$best" ]] || {
        vps_cmd_error "找不到安全、可写的服务器测试临时目录"
        return 3
    }
    printf '%s\n' "$best"
}

vps_server_test_create_run_dir() {
    local kind="$1" run_dir base

    base="$(vps_server_test_temp_base)" || return $?
    run_dir="$(mktemp -d "${base}/vpsctl-server-test.${kind}.XXXXXX")" || {
        vps_cmd_error "无法创建服务器测试临时目录"
        return 20
    }
    if ! chmod 0700 -- "$run_dir"; then
        vps_cmd_error "无法限制服务器测试临时目录权限"
        VPS_SERVER_TEST_RUN_BASE="$base"
        VPS_SERVER_TEST_RUN_KIND="$kind"
        VPS_SERVER_TEST_RUN_DIR="$run_dir"
        return 20
    fi

    VPS_SERVER_TEST_RUN_BASE="$base"
    VPS_SERVER_TEST_RUN_KIND="$kind"
    VPS_SERVER_TEST_RUN_DIR="$run_dir"
}

vps_server_test_validate_run_dir() {
    local run_dir="${VPS_SERVER_TEST_RUN_DIR:-}"
    local base="${VPS_SERVER_TEST_RUN_BASE:-}"
    local kind="${VPS_SERVER_TEST_RUN_KIND:-}"
    local resolved name suffix

    vps_server_test_validate_kind "$kind" >/dev/null 2>&1 || return 1
    [[ -n "$run_dir" && -n "$base" && "$run_dir" == /* && "$run_dir" != / ]] || return 1
    [[ "${run_dir%/*}" == "$base" ]] || return 1
    name="${run_dir##*/}"
    [[ "$name" == "vpsctl-server-test.${kind}."* ]] || return 1
    suffix="${name#"vpsctl-server-test.${kind}."}"
    [[ "$suffix" =~ ^[A-Za-z0-9]+$ ]] || return 1
    [[ -d "$run_dir" && ! -L "$run_dir" ]] || return 1
    resolved="$(cd -- "$run_dir" && pwd -P)" || return 1
    [[ "$resolved" == "$run_dir" ]]
}

vps_server_test_collect_mounts() {
    local run_dir="$1" line prefix raw_mount mount_path

    VPS_SERVER_TEST_MOUNTS=()
    [[ -r /proc/self/mountinfo ]] || {
        vps_cmd_warning "无法读取 /proc/self/mountinfo，不能安全确认临时目录挂载状态"
        return 30
    }
    while IFS= read -r line; do
        prefix="${line%% - *}"
        local IFS=' '
        read -r _ _ _ _ raw_mount _ <<<"$prefix"
        [[ -n "${raw_mount:-}" ]] || continue
        printf -v mount_path '%b' "$raw_mount"
        if [[ "$mount_path" == "$run_dir" || "$mount_path" == "$run_dir/"* ]]; then
            VPS_SERVER_TEST_MOUNTS+=("$mount_path")
        fi
    done </proc/self/mountinfo
}

vps_server_test_unmount_run_dir() {
    local run_dir="$1" target candidate longest_index index
    local -a pending=()

    vps_server_test_collect_mounts "$run_dir" || return 30
    pending=("${VPS_SERVER_TEST_MOUNTS[@]}")
    while ((${#pending[@]} > 0)); do
        longest_index=0
        for index in "${!pending[@]}"; do
            candidate="${pending[$index]}"
            if ((${#candidate} > ${#pending[$longest_index]})); then
                longest_index="$index"
            fi
        done
        target="${pending[$longest_index]}"
        unset 'pending[longest_index]'
        pending=("${pending[@]}")
        if ! umount -- "$target"; then
            vps_cmd_warning "无法卸载服务器测试临时挂载：$target"
        fi
    done

    vps_server_test_collect_mounts "$run_dir" || return 30
    if ((${#VPS_SERVER_TEST_MOUNTS[@]} > 0)); then
        vps_cmd_warning "服务器测试仍有挂载残留，保留临时目录：$run_dir"
        return 30
    fi
}

vps_server_test_cleanup_run_dir() {
    local run_dir="${VPS_SERVER_TEST_RUN_DIR:-}"

    ((VPS_SERVER_TEST_PROCESS_CLEANUP_STATUS == 0)) || return 30
    [[ -n "$run_dir" ]] || return 0
    if [[ ! -e "$run_dir" && ! -L "$run_dir" ]]; then
        VPS_SERVER_TEST_RUN_DIR=""
        return 0
    fi
    if ! vps_server_test_validate_run_dir; then
        vps_cmd_warning "服务器测试临时目录未通过安全校验，拒绝删除：$run_dir"
        return 30
    fi
    vps_server_test_unmount_run_dir "$run_dir" || return 30
    if [[ ! -e "$run_dir" && ! -L "$run_dir" ]]; then
        VPS_SERVER_TEST_RUN_DIR=""
        return 0
    fi
    if ! vps_server_test_validate_run_dir; then
        vps_cmd_warning "卸载后临时目录未通过安全校验，拒绝删除：$run_dir"
        return 30
    fi
    if ! rm -rf -- "$run_dir"; then
        vps_cmd_warning "无法清理服务器测试临时目录，已保留：$run_dir"
        return 30
    fi
    VPS_SERVER_TEST_RUN_DIR=""
}

vps_server_test_handle_signal() {
    local signal="$1" signal_status="$2"

    # A signal can arrive just before wait begins. Finish bounded shutdown here
    # once the child is registered, so that window cannot leave wait blocked.
    # Before registration, run_upstream will consume the pending signal.
    if ((VPS_SERVER_TEST_SIGNAL_STATUS == 0)); then
        VPS_SERVER_TEST_SIGNAL_STATUS="$signal_status"
        VPS_SERVER_TEST_SIGNAL="$signal"
        if [[ -n "$VPS_SERVER_TEST_CHILD_PID" ]] &&
            [[ -n "${VPS_SERVER_TEST_PROCESSES[$VPS_SERVER_TEST_CHILD_PID]+known}" ]]; then
            # Failure must leave via EXIT: waiting on an unconfirmed/live child
            # afterwards would turn the bounded shutdown into an unbounded wait.
            vps_server_test_wait_for_child_cleanup "$signal" || exit 30
        fi
    fi
}

vps_server_test_read_process() {
    local pid="$1" stat="" fields_text
    local -a fields=()

    # Return 1 only for a confirmed missing process; unreadable /proc data is
    # uncertainty (2), never proof that it is safe to remove the run directory.
    # Use read rather than $(<file): Bash's optimized substitution can exit an
    # errexit shell on a vanished file even inside a handled conditional.
    if ! { IFS= read -r -d '' stat <"/proc/${pid}/stat"; } 2>/dev/null; then
        # read -d '' normally returns nonzero at EOF, with the full stat record.
        if [[ -z "$stat" ]]; then
            [[ -r /proc/self/stat && ! -d "/proc/$pid" ]] && return 1
            return 2
        fi
    fi
    # comm may contain spaces or ')'; fields after its final ')' start at 3.
    fields_text="${stat##*) }"
    IFS=' ' read -r -a fields <<<"$fields_text"
    [[ "$stat" == "$pid ("* && ${#fields[@]} -ge 20 &&
        "${fields[1]}" =~ ^[0-9]+$ && "${fields[19]}" =~ ^[0-9]+$ ]] || return 2
    VPS_SERVER_TEST_PROC_STATE="${fields[0]}"
    VPS_SERVER_TEST_PROC_PPID="${fields[1]}"
    VPS_SERVER_TEST_PROC_STARTTIME="${fields[19]}"
}

vps_server_test_process_is_running() {
    local pid="$1" starttime="$2" status=0

    vps_server_test_read_process "$pid" || status=$?
    ((status == 0)) || return "$status"
    [[ "$VPS_SERVER_TEST_PROC_STATE" != Z && "$VPS_SERVER_TEST_PROC_STATE" != X ]] || return 1
    [[ -n "$starttime" ]] || return 2
    [[ "$VPS_SERVER_TEST_PROC_STARTTIME" == "$starttime" ]] || return 1
    return 0
}

vps_server_test_collect_processes() {
    local path pid parent changed=1
    local -A parents=() starts=()

    # Snapshot before signalling any parent, while descendants are still linked
    # to it. Previously identified descendants remain ours after reparenting.
    for path in /proc/[0-9]*/stat; do
        pid="${path#/proc/}"
        pid="${pid%/stat}"
        vps_server_test_read_process "$pid" || continue
        parents["$pid"]="$VPS_SERVER_TEST_PROC_PPID"
        starts["$pid"]="$VPS_SERVER_TEST_PROC_STARTTIME"
    done
    while ((changed)); do
        changed=0
        for pid in "${!parents[@]}"; do
            [[ -z "${VPS_SERVER_TEST_PROCESSES[$pid]+known}" ]] || continue
            parent="${parents[$pid]}"
            [[ -n "${VPS_SERVER_TEST_PROCESSES[$parent]:-}" &&
                "${starts[$parent]:-}" == "${VPS_SERVER_TEST_PROCESSES[$parent]}" ]] || continue
            VPS_SERVER_TEST_PROCESSES["$pid"]="${starts[$pid]}"
            changed=1
        done
    done
}

vps_server_test_child_is_running() {
    local pid status

    VPS_SERVER_TEST_REMAINING=()
    for pid in "${!VPS_SERVER_TEST_PROCESSES[@]}"; do
        status=0
        vps_server_test_process_is_running "$pid" "${VPS_SERVER_TEST_PROCESSES[$pid]}" || status=$?
        if ((status != 1)); then
            VPS_SERVER_TEST_REMAINING+=("$pid")
        fi
    done
    ((${#VPS_SERVER_TEST_REMAINING[@]} > 0))
}

vps_server_test_kill_child() {
    local signal="$1" pid

    for pid in "${!VPS_SERVER_TEST_PROCESSES[@]}"; do
        [[ "${VPS_SERVER_TEST_PROCESS_SIGNALLED[$pid]:-}" != "$signal" ]] || continue
        # A reused PID is not ours. Unknown identities are retained for the
        # final failure report, but must not receive a signal.
        vps_server_test_process_is_running "$pid" "${VPS_SERVER_TEST_PROCESSES[$pid]}" || continue
        if kill -s "$signal" -- "$pid" 2>/dev/null; then
            VPS_SERVER_TEST_PROCESS_SIGNALLED["$pid"]="$signal"
        fi
    done
}

vps_server_test_wait_for_child_cleanup() {
    local signal="${1:-TERM}" duration uptime deadline now delay

    if ((VPS_SERVER_TEST_PROCESS_CLEANUP_DONE)); then
        return "$VPS_SERVER_TEST_PROCESS_CLEANUP_STATUS"
    fi
    trap '' HUP INT TERM
    # /proc/uptime supplies a monotonic clock on supported Linux hosts. Include
    # collection time in the 5s grace and 1s KILL confirmation budgets.
    for duration in 500 100; do
        [[ "$duration" != 100 ]] || signal=KILL
        IFS=' ' read -r uptime _ </proc/uptime || break
        deadline=$((10#${uptime/./} + duration))
        while :; do
            vps_server_test_collect_processes
            vps_server_test_kill_child "$signal"
            vps_server_test_child_is_running || break
            IFS=' ' read -r uptime _ </proc/uptime || break
            now=$((10#${uptime/./}))
            ((now < deadline)) || break
            delay=0.1
            if ((deadline - now < 10)); then
                printf -v delay '0.%02d' "$((deadline - now))"
            fi
            sleep "$delay"
        done
        vps_server_test_child_is_running || break
    done
    VPS_SERVER_TEST_PROCESS_CLEANUP_DONE=1
    if vps_server_test_child_is_running; then
        VPS_SERVER_TEST_PROCESS_CLEANUP_STATUS=30
        local IFS=' '
        vps_cmd_warning "服务器测试进程仍存活或无法确认退出（PID：${VPS_SERVER_TEST_REMAINING[*]}），保留临时目录：${VPS_SERVER_TEST_RUN_DIR:-<未创建>}"
        return 30
    fi
    # Never use an unbounded wait on a process we could not stop.
    if [[ "$VPS_SERVER_TEST_CHILD_PID" =~ ^[1-9][0-9]*$ ]]; then
        wait "$VPS_SERVER_TEST_CHILD_PID" 2>/dev/null || true
    fi
    return 0
}

vps_server_test_exit_cleanup() {
    local exit_status=$? cleanup_status=0

    trap - EXIT
    if [[ "${VPS_SERVER_TEST_EXIT_CLEANUP_ACTIVE:-0}" != 1 ]]; then
        exit "$exit_status"
    fi
    VPS_SERVER_TEST_EXIT_CLEANUP_ACTIVE=0
    trap '' HUP INT TERM
    vps_server_test_wait_for_child_cleanup "${VPS_SERVER_TEST_SIGNAL:-TERM}" || cleanup_status=30
    vps_server_test_cleanup_run_dir || cleanup_status=30
    if ((cleanup_status != 0)); then
        exit 30
    fi
    exit "$exit_status"
}

vps_server_test_run_upstream() {
    local kind="$1" script="$2" status=0
    local stdin_fd

    VPS_SERVER_TEST_CHILD_PID=""
    VPS_SERVER_TEST_CHILD_STARTTIME=""
    if ! exec {stdin_fd}<&0; then
        vps_cmd_error "无法保留服务器测试的交互输入"
        return 20
    fi

    (
        exec 0<&"$stdin_fd"
        cd -- "$VPS_SERVER_TEST_RUN_DIR" || exit 20
        if [[ "$kind" == tcpquality ]]; then
            export TMPDIR="$VPS_SERVER_TEST_RUN_DIR"
            export TCPQUALITY_ROOTFS_TMPDIR="$VPS_SERVER_TEST_RUN_DIR"
            export TCPQUALITY_OUTPUT_DIR="$VPS_SERVER_TEST_RUN_DIR"
        fi
        # Keep the caller's controlling terminal. Current TcpQuality releases
        # open /dev/tty for their own menu, which would fail after setsid.
        exec bash "$script"
    ) &
    VPS_SERVER_TEST_CHILD_PID=$!
    if vps_server_test_read_process "$VPS_SERVER_TEST_CHILD_PID"; then
        VPS_SERVER_TEST_CHILD_STARTTIME="$VPS_SERVER_TEST_PROC_STARTTIME"
    fi
    VPS_SERVER_TEST_PROCESSES["$VPS_SERVER_TEST_CHILD_PID"]="$VPS_SERVER_TEST_CHILD_STARTTIME"
    exec {stdin_fd}<&-

    if ((VPS_SERVER_TEST_SIGNAL_STATUS == 0)); then
        wait "$VPS_SERVER_TEST_CHILD_PID" || status=$?
    fi
    trap '' HUP INT TERM
    if ((VPS_SERVER_TEST_SIGNAL_STATUS != 0)); then
        status="$VPS_SERVER_TEST_SIGNAL_STATUS"
        vps_server_test_wait_for_child_cleanup "$VPS_SERVER_TEST_SIGNAL" || status=30
    fi

    trap 'vps_server_test_handle_signal HUP 129' HUP
    trap 'vps_server_test_handle_signal INT 130' INT
    trap 'vps_server_test_handle_signal TERM 143' TERM
    return "$status"
}

vps_server_test_run() {
    local kind="${1:-}" url="${2:-}" script status=0 cleanup_status=0
    local upstream_status=0 upstream_started=0

    (($# == 2)) || {
        vps_cmd_error "vps_server_test_run 需要测试类型和官方 URL"
        return 2
    }
    vps_server_test_validate_kind "$kind" || return $?
    vps_server_test_validate_url "$kind" "$url" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_error "服务器测试不支持 --dry-run"
        return 2
    fi
    if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == "1" ]]; then
        vps_cmd_error "服务器测试需要交互确认，拒绝在非交互（--non-interactive）模式下运行"
        return 2
    fi
    vps_server_test_require_linux || return $?
    vps_cmd_require_root || return $?
    vps_server_test_require_tools || return $?

    VPS_SERVER_TEST_SIGNAL_STATUS=0
    VPS_SERVER_TEST_SIGNAL=""
    VPS_SERVER_TEST_CHILD_PID=""
    VPS_SERVER_TEST_CHILD_STARTTIME=""
    VPS_SERVER_TEST_PROCESSES=()
    VPS_SERVER_TEST_PROCESS_SIGNALLED=()
    VPS_SERVER_TEST_PROCESS_CLEANUP_DONE=0
    VPS_SERVER_TEST_PROCESS_CLEANUP_STATUS=0
    VPS_SERVER_TEST_EXIT_CLEANUP_ACTIVE=1
    trap vps_server_test_exit_cleanup EXIT
    trap 'vps_server_test_handle_signal HUP 129' HUP
    trap 'vps_server_test_handle_signal INT 130' INT
    trap 'vps_server_test_handle_signal TERM 143' TERM

    if vps_server_test_create_run_dir "$kind"; then
        script="${VPS_SERVER_TEST_RUN_DIR}/upstream.sh"
        vps_cmd_info "正在通过 HTTPS 下载官方最新脚本：$url"
        if ! curl -q -fsSL --proto '=https' --proto-redir '=https' --retry 3 \
            --connect-timeout 15 --max-time 300 -o "$script" "$url"; then
            vps_cmd_error "下载官方服务器测试脚本失败"
            status=20
        elif [[ ! -s "$script" || -L "$script" ]]; then
            vps_cmd_error "下载结果不是安全的非空普通文件"
            status=20
        elif ! chmod 0700 -- "$script"; then
            vps_cmd_error "无法设置下载脚本权限"
            status=20
        elif ((VPS_SERVER_TEST_SIGNAL_STATUS != 0)); then
            status="$VPS_SERVER_TEST_SIGNAL_STATUS"
        else
            upstream_started=1
            vps_cmd_info "开始执行官方服务器测试脚本"
            if vps_server_test_run_upstream "$kind" "$script"; then
                upstream_status=0
            else
                upstream_status=$?
            fi
            status="$upstream_status"
        fi
    else
        status=$?
    fi

    vps_server_test_cleanup_run_dir || cleanup_status=30

    VPS_SERVER_TEST_EXIT_CLEANUP_ACTIVE=0
    trap - EXIT
    trap '' HUP INT TERM
    VPS_SERVER_TEST_CHILD_PID=""
    VPS_SERVER_TEST_CHILD_STARTTIME=""
    trap - HUP INT TERM

    if ((cleanup_status != 0)); then
        return 30
    fi
    if ((VPS_SERVER_TEST_SIGNAL_STATUS != 0)); then
        return "$VPS_SERVER_TEST_SIGNAL_STATUS"
    fi
    if [[ "$kind" == nodequality && "$upstream_started" == 1 && "$upstream_status" == 1 ]]; then
        vps_cmd_warning "NodeQuality 上游返回 1；本次临时目录已清理，按成功处理（兼容上游退出码）。"
        return 0
    fi
    return "$status"
}
