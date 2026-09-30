#!/usr/bin/env bash
# Global flags are consumed by the command helper library.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

TCPING_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TCPING_PROJECT_ROOT
# shellcheck source=../../lib/command.sh
source "$TCPING_PROJECT_ROOT/lib/command.sh"
# shellcheck source=../../lib/ufw.sh
source "$TCPING_PROJECT_ROOT/lib/ufw.sh"

readonly TCPING_STATE_LOGICAL='/var/lib/vpsctl/service/tcping/state.json'
readonly TCPING_RUNTIME_LOGICAL='/usr/local/libexec/vpsctl/tcping/listener.py'
readonly TCPING_READY_LOGICAL='/run/vpsctl/tcping-ready.json'
readonly TCPING_LOG_LOGICAL='/var/log/vpsctl/tcping.log'
readonly TCPING_SERVICE='vpsctl-tcping'

tcping_usage() {
    cat <<'EOF'
TCPing 测试站点：提供可由其他机器探测的 TCP 监听端口。

用法：vpsctl [global-options] service tcping [action]
  start [--port PORT]  部署并启动，启用开机启动；首次必须指定端口
  status              查看安装、运行、自启、端口及地址族
  stop                停止并取消自启，保留配置和脚本
  uninstall           停止并清理专属资源及功能下载缓存
  help                查看此帮助

无参数时进入编号菜单；非交互环境只显示帮助。
端口为 1–65535；start --port 可切换端口，失败恢复原服务。
支持 Linux/systemd 和 Alpine/OpenRC，需要 Bash 4.4+。
启动时按需使用 Python 3 标准库；监听全部 IPv4 接口及可用 IPv6。
同端口且服务已就绪时不重新部署监听脚本。需要更新时，先执行 `vpsctl service tcping stop`，
再执行 `vpsctl service tcping start`；后者按保存端口部署当前 listener.py。
启动会联动已有 UFW，停止和卸载释放本模块需求；不会安装或启用 UFW。
云安全组和其他防火墙须另行放行所选 TCP 端口。

全局选项：--dry-run、--install-deps、--yes、--non-interactive、
          --quiet、--verbose、--no-color、--。
变更需要 root；--dry-run 仅展示计划。卸载交互确认一次，自动化用 --yes。
卸载保留系统 Python、共享库及其他功能；源码运行不会删除仓库源码。
退出码沿用项目约定：2 参数，3 前置条件，4 权限，10 配置，20 执行失败，
30 部分完成（按错误提示重试），130 用户中断。
EOF
}

tcping_valid_port() {
    [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

tcping_parse() {
    TCPING_ACTION=menu
    TCPING_PORT=''
    while (($#)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --install-deps) VPSCTL_INSTALL_DEPS=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --no-color) VPSCTL_NO_COLOR=1 ;;
            --)
                shift
                break
                ;;
            *) break ;;
        esac
        shift
    done
    if (($#)); then
        TCPING_ACTION="$1"
        shift
    fi
    case "$TCPING_ACTION" in
        help | -h | --help) TCPING_ACTION=help ;;
        menu | start | status | stop | uninstall) ;;
        *)
            vps_cmd_error "未知动作：$TCPING_ACTION"
            return 2
            ;;
    esac
    while (($#)); do
        case "$1" in
            --port)
                [[ "$TCPING_ACTION" == start && -z "$TCPING_PORT" ]] && (($# >= 2)) && tcping_valid_port "$2" || {
                    vps_cmd_error 'start --port 需要一个 1–65535 的端口，且不能重复指定'
                    return 2
                }
                TCPING_PORT="$((10#$2))"
                shift 2
                ;;
            *)
                vps_cmd_error "未知或不适用的参数：$1"
                return 2
                ;;
        esac
    done
}

tcping_init_paths() {
    TCPING_STATE="$(vps_cmd_system_path "$TCPING_STATE_LOGICAL")" || return $?
    TCPING_RUNTIME="$(vps_cmd_system_path "$TCPING_RUNTIME_LOGICAL")" || return $?
    TCPING_READY="$(vps_cmd_system_path "$TCPING_READY_LOGICAL")" || return $?
    TCPING_LOG="$(vps_cmd_system_path "$TCPING_LOG_LOGICAL")" || return $?
    TCPING_PID="$(vps_cmd_system_path /run/vpsctl-tcping.pid)" || return $?
    TCPING_INIT="${VPSCTL_ENV_INIT:-unknown}"
    case "$TCPING_INIT" in
        openrc-init) TCPING_INIT=openrc ;;
        init*)
            if command -v rc-service >/dev/null 2>&1; then
                TCPING_INIT=openrc
            else TCPING_INIT=unknown; fi
            ;;
    esac
    if [[ "$TCPING_INIT" == unknown ]]; then
        if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
            TCPING_INIT=systemd
        elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then TCPING_INIT=openrc; fi
    fi
    if [[ "$TCPING_INIT" == openrc ]]; then
        TCPING_UNIT_LOGICAL="/etc/init.d/$TCPING_SERVICE"
    else TCPING_UNIT_LOGICAL="/etc/systemd/system/$TCPING_SERVICE.service"; fi
    TCPING_UNIT="$(vps_cmd_system_path "$TCPING_UNIT_LOGICAL")" || return $?
}

tcping_check_paths() {
    local path
    for path in "$TCPING_STATE" "$TCPING_RUNTIME" "$TCPING_UNIT" "$TCPING_READY" "$TCPING_LOG" "$TCPING_PID"; do
        vps_cmd_require_no_symlink_components "$path" || return $?
        [[ ! -e "$path" || -f "$path" ]] || {
            vps_cmd_error "预期普通文件：$path"
            return 3
        }
    done
    for path in "$TCPING_UNIT" "$TCPING_RUNTIME"; do
        if [[ -f "$path" ]] && ! head -n 3 "$path" | grep -Fxq '# Managed by vpsctl tcping.'; then
            vps_cmd_error "拒绝覆盖或删除非受管文件：$path"
            return 3
        fi
    done
}

tcping_load_state() {
    TCPING_SAVED_PORT=''
    TCPING_ENABLED=false
    [[ -e "$TCPING_STATE" ]] || return 0
    command -v jq >/dev/null 2>&1 || {
        vps_cmd_error '读取已安装 TCPing 配置需要 jq'
        return 3
    }
    jq -e '.schema_version == 1 and (.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
        (.enabled | type == "boolean")' "$TCPING_STATE" >/dev/null || {
        vps_cmd_error "TCPing 状态无效，请检查 $TCPING_STATE"
        return 10
    }
    TCPING_SAVED_PORT="$(jq -r '.port' "$TCPING_STATE")" || return 10
    TCPING_ENABLED="$(jq -r '.enabled' "$TCPING_STATE")" || return 10
}

tcping_service_active() {
    case "$TCPING_INIT" in
        systemd) systemctl is-active --quiet "$TCPING_SERVICE.service" ;;
        openrc) rc-service "$TCPING_SERVICE" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

tcping_service_enabled() {
    case "$TCPING_INIT" in
        systemd) systemctl is-enabled --quiet "$TCPING_SERVICE.service" ;;
        openrc) [[ -L "$(vps_cmd_system_path "/etc/runlevels/default/$TCPING_SERVICE")" ]] ;;
        *) return 1 ;;
    esac
}

tcping_service() {
    local action="$1"
    case "$TCPING_INIT:$action" in
        systemd:reload) systemctl daemon-reload ;;
        systemd:*) systemctl "$action" "$TCPING_SERVICE.service" ;;
        openrc:reload) return 0 ;;
        openrc:enable) rc-update add "$TCPING_SERVICE" default ;;
        openrc:disable) rc-update del "$TCPING_SERVICE" default ;;
        openrc:*) rc-service "$TCPING_SERVICE" "$action" ;;
        *) return 3 ;;
    esac
}

tcping_ready() {
    local pid
    [[ -f "$TCPING_READY" && ! -L "$TCPING_READY" ]] || return 1
    pid="$(jq -er --argjson port "$1" 'select(.port == $port and
        (.pid | type == "number" and floor == . and . > 1) and
        (.families | type == "array" and length > 0 and all(. == "ipv4" or . == "ipv6"))) | .pid' "$TCPING_READY" 2>/dev/null)" || return 1
    # Read-only status must also work for users who cannot signal a root service.
    [[ -d "/proc/$pid" ]]
}

tcping_wait_ready() {
    local attempt
    for ((attempt = 0; attempt < 50; attempt++)); do
        if tcping_service_active && tcping_ready "$1"; then return 0; fi
        sleep 0.1
    done
    vps_cmd_error 'TCPing 服务未就绪；请查看 systemd 日志或 /var/log/vpsctl/tcping.log'
    return 20
}

tcping_status() {
    local installed='未安装' active='已停止' enabled='否' families='未监听' path parent
    # Other features can intentionally keep these shared parents private. Do
    # not weaken their permissions or mistake an inaccessible file for absence.
    for path in "$TCPING_STATE" "$TCPING_RUNTIME" "$TCPING_UNIT" "$TCPING_READY"; do
        parent="${path%/*}"
        while [[ -n "$parent" ]]; do
            if [[ -d "$parent" && ! -x "$parent" ]]; then
                vps_cmd_error '无法读取受保护的状态目录；请使用 root 查看 TCPing 状态'
                return 4
            fi
            parent="${parent%/*}"
        done
        if [[ -f "$path" && ! -r "$path" ]]; then
            vps_cmd_error '无法读取受保护的状态文件；请使用 root 查看 TCPing 状态'
            return 4
        fi
    done
    tcping_check_paths || return $?
    tcping_load_state || return $?
    [[ ! -f "$TCPING_RUNTIME" || ! -f "$TCPING_UNIT" ]] || installed='已安装'
    if command -v jq >/dev/null 2>&1 && tcping_service_active; then
        active='运行中（尚未就绪）'
        if [[ -n "$TCPING_SAVED_PORT" ]] && tcping_ready "$TCPING_SAVED_PORT"; then
            active='运行中'
            families="$(jq -r '.families | join(", ")' "$TCPING_READY")"
        fi
    fi
    if tcping_service_enabled; then enabled='是'; fi
    vps_cmd_status '安装状态' "$installed" normal
    vps_cmd_status '运行状态' "$active" normal
    vps_cmd_status '开机启动' "$enabled" normal
    vps_cmd_status 'TCP 端口' "${TCPING_SAVED_PORT:-未设置}" normal
    vps_cmd_status '监听地址族' "$families" normal
}

tcping_emit_unit() {
    local port="$1" python="$2"
    if [[ "$TCPING_INIT" == systemd ]]; then
        cat <<EOF
# Managed by vpsctl tcping.
[Unit]
Description=vpsctl TCPing test listener
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/vpsctl
ExecStart=$python -B $TCPING_RUNTIME_LOGICAL --port $port --ready-file $TCPING_READY_LOGICAL
Restart=on-failure
RestartSec=2
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    else
        cat <<EOF
#!/sbin/openrc-run
# Managed by vpsctl tcping.
description="vpsctl TCPing test listener"
command="$python"
command_args="-B $TCPING_RUNTIME_LOGICAL --port $port --ready-file $TCPING_READY_LOGICAL"
supervisor="supervise-daemon"
pidfile="/run/vpsctl-tcping.pid"
respawn_delay=2
respawn_max=0
output_log="$TCPING_LOG_LOGICAL"
error_log="$TCPING_LOG_LOGICAL"
start_pre() {
    checkpath --directory --mode 0755 /run/vpsctl /var/log/vpsctl
}
depend() {
    need net
}
EOF
    fi
}

tcping_desired() {
    local port="$1" enabled="$2" ipv6=false
    vps_ufw_ipv6_available && ipv6=true
    jq -n --arg port "$port" --argjson enabled "$enabled" --argjson ipv6 "$ipv6" '
        if $enabled then (["ipv4"] + if $ipv6 then ["ipv6"] else [] end) |
            map({owner:"tcping",kind:"input",family:.,proto:"tcp",port:$port,
                source:"any",destination:"any",temporary:false,preserve_existing:true}) else [] end'
}

tcping_save_state() {
    jq -n --argjson port "$1" --argjson enabled "$2" '{schema_version:1,port:$port,enabled:$enabled}' |
        vps_cmd_atomic_write "$TCPING_STATE_LOGICAL" 0644
}

tcping_snapshot() {
    local path index=0
    TCPING_WORK="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-tcping.XXXXXX")" || return 20
    TCPING_OLD_ACTIVE=0
    TCPING_OLD_ENABLED=0
    if tcping_service_active; then TCPING_OLD_ACTIVE=1; fi
    if tcping_service_enabled; then TCPING_OLD_ENABLED=1; fi
    for path in "$TCPING_STATE" "$TCPING_RUNTIME" "$TCPING_UNIT"; do
        if [[ -f "$path" ]]; then cp -p -- "$path" "$TCPING_WORK/$index" || return 20; fi
        index=$((index + 1))
    done
    TCPING_SNAPSHOT=1
}

tcping_restore() {
    local path index=0 status=0
    if [[ "$TCPING_TOUCHED" == 1 ]]; then
        if [[ -f "$TCPING_UNIT" ]]; then
            if [[ "$TCPING_INIT" == systemd ]] || tcping_service_active || [[ -f "$TCPING_PID" ]]; then
                tcping_service stop || return 30
            fi
            if [[ "$TCPING_OLD_ENABLED" == 0 ]] && tcping_service_enabled; then tcping_service disable || return 30; fi
        fi
        tcping_service_active && return 30
        for path in "$TCPING_STATE" "$TCPING_RUNTIME" "$TCPING_UNIT"; do
            if [[ -f "$TCPING_WORK/$index" ]]; then
                cp -p -- "$TCPING_WORK/$index" "$path" || status=30
            else rm -f -- "$path" || status=30; fi
            index=$((index + 1))
        done
        tcping_service reload || status=30
        if [[ -f "$TCPING_UNIT" ]]; then
            if [[ "$TCPING_OLD_ENABLED" == 1 ]]; then
                tcping_service enable || status=30
            elif tcping_service_enabled; then tcping_service disable || status=30; fi
            if [[ "$TCPING_OLD_ACTIVE" == 1 ]]; then
                tcping_service start || status=30
                tcping_wait_ready "$TCPING_SAVED_PORT" || status=30
            fi
        fi
        if [[ "$TCPING_OLD_ACTIVE" == 0 ]]; then rm -f -- "$TCPING_READY" || status=30; fi
    fi
    vps_ufw_rollback || status=30
    return "$status"
}

tcping_cleanup() {
    local result="$1" restored=0
    trap '' INT TERM HUP
    if [[ "$TCPING_COMMITTED" == 0 && "$TCPING_SNAPSHOT" == 1 ]]; then
        tcping_restore || restored=$?
        if ((restored != 0)); then
            vps_cmd_error "恢复不完整，备份保留于 $TCPING_WORK；修复后重试 start 或 stop"
            result=30
        fi
    elif [[ "$TCPING_COMMITTED" == 1 && "${VPS_UFW_DEPTH:-0}" != 0 ]]; then
        # A signal between the business commit and the firewall commit must
        # retain the rules for the now-persisted service, not leave a prepared journal.
        vps_ufw_commit || result=30
    fi
    if [[ -n "$TCPING_WORK" && "$restored" == 0 ]]; then rm -rf -- "$TCPING_WORK" || result=30; fi
    vps_cmd_unlock
    return "$result"
}

tcping_remove_runtime() {
    local path
    # Files are checked before any service or firewall change; do not remove parents recursively.
    for path in "$TCPING_UNIT" "$TCPING_RUNTIME" "$TCPING_STATE" "$TCPING_READY" "$TCPING_LOG" "$TCPING_PID"; do
        if ! rm -f -- "$path"; then
            vps_cmd_error "卸载清理失败：$path；请重试 uninstall"
            return 30
        fi
    done
    tcping_service reload || return 30
    for path in "${TCPING_RUNTIME%/*}" "${TCPING_STATE%/*}"; do
        if [[ -d "$path" ]]; then
            rmdir -- "$path" || {
                vps_cmd_error "目录仍有残留，请检查后重试：$path"
                return 30
            }
        fi
    done
    # shellcheck source=../../lib/distribution.sh
    source "$TCPING_PROJECT_ROOT/lib/distribution.sh"
    vps_distribution_remove_command_cache service:tcping || return 30
}

tcping_mutate() (
    local action="$1" port="${2:-}" python='' mode=0644 confirm_status reused_existing_runtime=0
    TCPING_WORK=''
    TCPING_SNAPSHOT=0
    TCPING_TOUCHED=0
    TCPING_COMMITTED=0
    [[ "$(uname -s)" == Linux ]] || {
        vps_cmd_error 'TCPing 仅支持 Linux'
        return 3
    }
    case "$TCPING_INIT" in
        systemd) command -v systemctl >/dev/null 2>&1 || return 3 ;;
        openrc) command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 && command -v supervise-daemon >/dev/null 2>&1 || return 3 ;;
        *)
            vps_cmd_error 'TCPing 需要 systemd 或 OpenRC'
            return 3
            ;;
    esac
    vps_cmd_require_root || return $?
    tcping_check_paths || return $?
    if [[ "$action" == start && -z "$port" && ! -f "$TCPING_STATE" ]]; then
        vps_cmd_error '首次启动必须指定 --port PORT'
        return 2
    fi
    if [[ "$action" == uninstall ]]; then
        if vps_cmd_confirm '停止 TCPing 并删除专属脚本、配置和功能缓存？'; then :; else
            confirm_status=$?
            [[ "$confirm_status" != 1 ]] || confirm_status=130
            return "$confirm_status"
        fi
    fi
    if [[ "$action" == start ]]; then
        vps_cmd_ensure_tools tcping python3 jq flock sha256sum || return $?
    else vps_cmd_ensure_tools tcping jq flock sha256sum || return $?; fi
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info '依赖仅完成安装计划；安装后可重跑完整演练'
        return 0
    fi
    tcping_load_state || return $?
    [[ -n "$port" ]] || port="$TCPING_SAVED_PORT"
    if [[ "$VPSCTL_DRY_RUN" == 1 ]]; then
        vps_cmd_info "演练：TCPing $action，端口 ${port:-未设置}；同步该模块的 UFW 需求，不启用防火墙"
        if [[ "$action" == start ]]; then
            vps_cmd_info '部署监听脚本、启动服务并启用开机启动'
        elif [[ "$action" == stop ]]; then
            vps_cmd_info '停止服务、取消开机启动，保留配置与脚本'
        else vps_cmd_info '停止并取消自启，删除专属资源及受管功能缓存；保留共享库和系统 Python'; fi
        return 0
    fi
    vps_cmd_lock tcping || return $?
    trap 'if tcping_cleanup "$?"; then exit 0; else exit "$?"; fi' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    # Re-read after taking the same business lock as global UFW synchronization.
    tcping_check_paths || return $?
    tcping_load_state || return $?
    [[ -n "${2:-}" ]] || port="$TCPING_SAVED_PORT"
    if [[ ! -f "$TCPING_UNIT" ]] && { tcping_service_active || tcping_service_enabled; }; then
        vps_cmd_error '同名服务并非本模块受管服务，拒绝操作'
        return 3
    fi
    if [[ "$action" == start ]]; then
        [[ -n "$port" ]] || {
            vps_cmd_error '首次启动必须指定 --port PORT'
            return 2
        }
        python="$(command -v python3)" || return 3
        [[ "$python" =~ ^/[a-zA-Z0-9_./+-]+$ ]] || {
            vps_cmd_error 'Python 路径无法安全写入服务定义'
            return 3
        }
        if [[ "$port" != "$TCPING_SAVED_PORT" ]] || ! tcping_service_active; then
            if ! "$python" -B "$TCPING_PROJECT_ROOT/commands/service/tcping/listener.py" --port "$port" --check; then
                vps_cmd_error "TCP $port 无法监听（可能已被占用）；原服务保持不变"
                return 3
            fi
        fi
    fi
    tcping_snapshot || return $?
    tcping_desired "$port" "$([[ "$action" == start ]] && printf true || printf false)" >"$TCPING_WORK/desired.json" || return 20
    vps_ufw_begin tcping "$TCPING_WORK/desired.json" || return $?
    if [[ "$action" == start ]]; then
        mkdir -p -- "${TCPING_STATE%/*}" "${TCPING_RUNTIME%/*}" "${TCPING_UNIT%/*}" "${TCPING_LOG%/*}" || return 20
        if [[ "$port" != "$TCPING_SAVED_PORT" ]] || ! tcping_service_active || ! tcping_ready "$port"; then
            TCPING_TOUCHED=1
            if tcping_service_active; then tcping_service stop || return 20; fi
            tcping_service_active && return 20
            rm -f -- "$TCPING_READY" || return 20
            vps_cmd_atomic_write "$TCPING_RUNTIME_LOGICAL" 0644 <"$TCPING_PROJECT_ROOT/commands/service/tcping/listener.py" || return $?
            [[ "$TCPING_INIT" != openrc ]] || mode=0755
            tcping_emit_unit "$port" "$python" | vps_cmd_atomic_write "$TCPING_UNIT_LOGICAL" "$mode" || return $?
            tcping_service reload || return 20
            tcping_service start || return 20
            tcping_wait_ready "$port" || return $?
        else
            reused_existing_runtime=1
        fi
        TCPING_TOUCHED=1
        if ! tcping_service_enabled; then tcping_service enable || return 20; fi
        tcping_save_state "$port" true || return $?
    else
        TCPING_TOUCHED=1
        if [[ -f "$TCPING_UNIT" ]]; then
            # stop also cancels a pending automatic restart after a failed start.
            if [[ "$TCPING_INIT" == systemd ]] || tcping_service_active || [[ -f "$TCPING_PID" ]]; then
                tcping_service stop || return 20
            fi
            if tcping_service_enabled; then tcping_service disable || return 20; fi
        fi
        tcping_service_active && return 20
        rm -f -- "$TCPING_READY" || return 20
        if [[ -n "$port" ]]; then tcping_save_state "$port" false || return $?; fi
    fi
    TCPING_COMMITTED=1
    vps_ufw_commit || return $?
    if [[ "$action" == uninstall ]]; then
        tcping_remove_runtime || return $?
        vps_cmd_success 'TCPing 已卸载；专属资源和功能缓存已清理'
    elif [[ "$action" == start ]]; then
        vps_cmd_success "TCPing 已启动并启用开机启动，TCP 端口 $port"
        if [[ "$reused_existing_runtime" == 1 ]]; then
            # Command names are literal guidance, not command substitutions.
            # shellcheck disable=SC2016
            vps_cmd_info 'TCPing 已在该端口运行，本次未重新部署监听脚本。需要更新脚本时，请先执行 `vpsctl service tcping stop`，再执行 `vpsctl service tcping start`。'
        fi
        vps_cmd_info "可使用本机地址和 TCP $port 探测；云安全组及其他防火墙需另行放行"
    else vps_cmd_success 'TCPing 已停止并取消开机启动；端口配置已保留'; fi
)

tcping_menu() {
    local choice port result
    vps_cmd_is_interactive || {
        tcping_usage
        return 0
    }
    while true; do
        tcping_status || true
        choice="$(vps_cmd_prompt_select 'TCPing 测试站点' '' start '创建 / 启动 / 修改端口' status '查看状态' stop '停止' uninstall '卸载')" || return 0
        case "$choice" in
            start)
                while true; do
                    printf 'TCP 端口%s：' "${TCPING_SAVED_PORT:+（回车沿用 $TCPING_SAVED_PORT）}" >&2
                    IFS= read -r port || return 130
                    port="$(vps_cmd_trim "$port")"
                    [[ -n "$port" ]] || port="$TCPING_SAVED_PORT"
                    if tcping_valid_port "$port"; then break; fi
                    vps_cmd_warning '请输入 1–65535 的端口'
                done
                tcping_mutate start "$((10#$port))" || true
                ;;
            status) tcping_status || true ;;
            stop) tcping_mutate stop || true ;;
            uninstall)
                result=0
                tcping_mutate uninstall || result=$?
                ((result != 0)) || return 0
                ;;
        esac
    done
}

tcping_main() {
    tcping_parse "$@" || return $?
    vps_cmd_init 'service tcping' "$TCPING_PROJECT_ROOT" || return $?
    [[ "$TCPING_ACTION" != help ]] || {
        tcping_usage
        return 0
    }
    tcping_init_paths || return $?
    case "$TCPING_ACTION" in
        menu) tcping_menu ;;
        status) tcping_status ;;
        *) tcping_mutate "$TCPING_ACTION" "$TCPING_PORT" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then tcping_main "$@"; fi
