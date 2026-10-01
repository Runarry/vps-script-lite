#!/usr/bin/env bash
# Global flags are consumed by the command helper library.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

IPERF3_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly IPERF3_PROJECT_ROOT
# shellcheck source=../../lib/command.sh
source "$IPERF3_PROJECT_ROOT/lib/command.sh"
# shellcheck source=../../lib/ufw.sh
source "$IPERF3_PROJECT_ROOT/lib/ufw.sh"

readonly IPERF3_STATE_LOGICAL='/var/lib/vpsctl/service/iperf3/state.json'
readonly IPERF3_LOG_LOGICAL='/var/log/vpsctl/iperf3.log'
readonly IPERF3_PID_LOGICAL='/run/vpsctl/iperf3.pid'
readonly IPERF3_SERVICE='vpsctl-iperf3'
readonly IPERF3_MARKER='# Managed by vpsctl iperf3.'

iperf3_usage() {
    cat <<'EOF'
iperf3 测速服务端：供其他机器测试本机 TCP/UDP 吞吐量。

用法：vpsctl [global-options] service iperf3 [action]
  start [--port PORT]  按需安装、启动并启用自启；首次默认 5201，后续沿用端口
  status              查看软件版本、受管服务、运行、自启和实际监听
  stop                停止并取消自启，保留配置和软件包
  restart             按保存端口重新启动并启用自启；必须已经部署
  update              更新系统软件包；保持原运行和自启状态
  logs                查看最近 50 行日志
  uninstall           清理受管服务、配置、专属日志和功能缓存，保留软件包
  help                查看此帮助

无参数时进入编号菜单；非交互环境只显示帮助。
端口为 1–65535；start --port 可切换端口，失败恢复原服务。
支持 Linux/systemd 与 OpenRC supervise-daemon，需要 Bash 4.4+。
使用系统软件源，不编译、不添加第三方源；已有 iperf3 可直接使用。
服务监听全部接口，支持 TCP、UDP 和可用的 IPv4/IPv6。
启动联动已有 UFW 的 TCP/UDP 端口；停止和卸载释放本模块需求。
不会安装或启用 UFW；云安全组和其他防火墙需另行放行。
测速会占用真实带宽和流量；本模块不主动发起测试或修改网络调优参数。

全局选项：--dry-run、--install-deps、--yes、--non-interactive、
          --quiet、--verbose、--no-color、--。
变更需要 root；缺少依赖时交互确认一次，自动化使用 --install-deps。
--dry-run 只显示计划；卸载确认一次，自动化使用 --yes。
退出码：2 参数，3 前置条件，4 权限，10 配置，20 执行失败，
30 部分完成（按错误提示重试），130 用户中断。
EOF
}

iperf3_valid_port() {
    [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

iperf3_parse() {
    IPERF3_ACTION=menu
    IPERF3_PORT=''
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
        IPERF3_ACTION="$1"
        shift
    fi
    case "$IPERF3_ACTION" in
        help | -h | --help) IPERF3_ACTION=help ;;
        menu | start | status | stop | restart | update | logs | uninstall) ;;
        *)
            vps_cmd_error "未知动作：$IPERF3_ACTION"
            return 2
            ;;
    esac
    while (($#)); do
        case "$1" in
            --port)
                [[ "$IPERF3_ACTION" == start && -z "$IPERF3_PORT" ]] && (($# >= 2)) && iperf3_valid_port "$2" || {
                    vps_cmd_error 'start --port 需要一个 1–65535 的端口，且不能重复指定'
                    return 2
                }
                IPERF3_PORT="$((10#$2))"
                shift 2
                ;;
            *)
                vps_cmd_error "未知或不适用的参数：$1"
                return 2
                ;;
        esac
    done
}

iperf3_init_paths() {
    IPERF3_STATE="$(vps_cmd_system_path "$IPERF3_STATE_LOGICAL")" || return $?
    IPERF3_LOG="$(vps_cmd_system_path "$IPERF3_LOG_LOGICAL")" || return $?
    IPERF3_PID="$(vps_cmd_system_path "$IPERF3_PID_LOGICAL")" || return $?
    IPERF3_SUPERVISOR_PID="$(vps_cmd_system_path /run/vpsctl-iperf3.pid)" || return $?
    IPERF3_INIT="${VPSCTL_ENV_INIT:-unknown}"
    case "$IPERF3_INIT" in
        openrc-init) IPERF3_INIT=openrc ;;
        init*)
            if command -v rc-service >/dev/null 2>&1; then
                IPERF3_INIT=openrc
            else IPERF3_INIT=unknown; fi
            ;;
    esac
    if [[ "$IPERF3_INIT" == unknown ]]; then
        if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
            IPERF3_INIT=systemd
        elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then IPERF3_INIT=openrc; fi
    fi
    if [[ "$IPERF3_INIT" == openrc ]]; then
        IPERF3_UNIT_LOGICAL="/etc/init.d/$IPERF3_SERVICE"
    else IPERF3_UNIT_LOGICAL="/etc/systemd/system/$IPERF3_SERVICE.service"; fi
    IPERF3_UNIT="$(vps_cmd_system_path "$IPERF3_UNIT_LOGICAL")" || return $?
}

iperf3_check_paths() {
    local path parent
    for path in "$IPERF3_STATE" "$IPERF3_UNIT" "$IPERF3_LOG" "$IPERF3_PID" "$IPERF3_SUPERVISOR_PID"; do
        parent="${path%/*}"
        while [[ -n "$parent" ]]; do
            if [[ -d "$parent" && ! -x "$parent" ]]; then
                vps_cmd_error '无法读取受保护的状态目录；请使用 root 查看 iperf3 状态'
                return 4
            fi
            parent="${parent%/*}"
        done
        vps_cmd_require_no_symlink_components "$path" || return $?
        [[ ! -e "$path" || -f "$path" ]] || {
            vps_cmd_error "预期普通文件：$path"
            return 3
        }
        [[ ! -f "$path" || -r "$path" ]] || {
            vps_cmd_error "无法读取 $path；请使用 root"
            return 4
        }
    done
    if [[ -f "$IPERF3_UNIT" ]] && ! head -n 3 "$IPERF3_UNIT" | grep -Fxq "$IPERF3_MARKER"; then
        vps_cmd_error "拒绝覆盖或删除非受管服务：$IPERF3_UNIT"
        return 3
    fi
}

iperf3_load_state() {
    IPERF3_SAVED_PORT=''
    IPERF3_ENABLED=false
    [[ -e "$IPERF3_STATE" ]] || return 0
    command -v jq >/dev/null 2>&1 || {
        vps_cmd_error '读取 iperf3 配置需要 jq'
        return 3
    }
    jq -e '.schema_version == 1 and (.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
        (.enabled | type == "boolean")' "$IPERF3_STATE" >/dev/null || {
        vps_cmd_error "iperf3 状态无效，请检查 $IPERF3_STATE"
        return 10
    }
    IPERF3_SAVED_PORT="$(jq -r '.port' "$IPERF3_STATE")" || return 10
    IPERF3_ENABLED="$(jq -r '.enabled' "$IPERF3_STATE")" || return 10
}

iperf3_service_active() {
    case "$IPERF3_INIT" in
        systemd) systemctl is-active --quiet "$IPERF3_SERVICE.service" ;;
        openrc) rc-service "$IPERF3_SERVICE" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

iperf3_service_enabled() {
    case "$IPERF3_INIT" in
        systemd) systemctl is-enabled --quiet "$IPERF3_SERVICE.service" ;;
        openrc) [[ -L "$(vps_cmd_system_path "/etc/runlevels/default/$IPERF3_SERVICE")" ]] ;;
        *) return 1 ;;
    esac
}

iperf3_service() {
    local action="$1"
    case "$IPERF3_INIT:$action" in
        systemd:reload) systemctl daemon-reload ;;
        systemd:*) systemctl "$action" "$IPERF3_SERVICE.service" ;;
        openrc:reload) return 0 ;;
        openrc:enable) rc-update add "$IPERF3_SERVICE" default ;;
        openrc:disable) rc-update del "$IPERF3_SERVICE" default ;;
        openrc:*) rc-service "$IPERF3_SERVICE" "$action" ;;
        *) return 3 ;;
    esac
}

iperf3_service_pid() {
    local pid=''
    case "$IPERF3_INIT" in
        systemd) pid="$(systemctl show "$IPERF3_SERVICE.service" -p MainPID --value)" || return 1 ;;
        openrc)
            [[ -f "$IPERF3_PID" ]] || return 1
            pid="$(<"$IPERF3_PID")"
            ;;
        *) return 1 ;;
    esac
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && -d "/proc/$pid" ]] || return 1
    printf '%s\n' "$pid"
}

iperf3_ready() {
    local pid sockets
    iperf3_service_active || return 1
    pid="$(iperf3_service_pid)" || return 1
    sockets="$(ss -H -ltnp "sport = :$1")" || return 1
    [[ "$sockets" == *"pid=$pid,"* ]]
}

iperf3_wait_ready() {
    local attempt
    for ((attempt = 0; attempt < 50; attempt++)); do
        if iperf3_ready "$1"; then return 0; fi
        sleep 0.1
    done
    vps_cmd_error 'iperf3 未就绪；请执行 service iperf3 logs 查看日志'
    return 20
}

iperf3_check_port() {
    local port="$1" own_pid='' sockets line protocol
    if [[ "$port" == "$IPERF3_SAVED_PORT" ]] && iperf3_service_active; then
        own_pid="$(iperf3_service_pid)" || return 3
    fi
    for protocol in tcp udp; do
        if [[ "$protocol" == tcp ]]; then
            sockets="$(ss -H -ltnp "sport = :$port")" || return 20
        else sockets="$(ss -H -uanp "sport = :$port")" || return 20; fi
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            if [[ -n "$own_pid" && "$line" == *"pid=$own_pid,"* ]]; then continue; fi
            vps_cmd_error "$protocol $port 已被其他程序占用；原服务保持不变"
            return 3
        done <<<"$sockets"
    done
}

iperf3_version() {
    local version
    command -v iperf3 >/dev/null 2>&1 || {
        printf '未安装\n'
        return 0
    }
    version="$(iperf3 --version 2>&1)" || return 20
    printf '%s\n' "${version%%$'\n'*}"
}

iperf3_status() {
    local deployed='未部署' active='已停止' enabled='否' sockets='' version
    iperf3_check_paths || return $?
    iperf3_load_state || return $?
    version="$(iperf3_version)" || return $?
    [[ ! -f "$IPERF3_UNIT" || ! -f "$IPERF3_STATE" ]] || deployed='已部署'
    if iperf3_service_active; then active='运行中'; fi
    if iperf3_service_enabled; then enabled='是'; fi
    vps_cmd_status '软件版本' "$version" normal
    vps_cmd_status '受管服务' "$deployed" normal
    vps_cmd_status '运行状态' "$active" normal
    vps_cmd_status '开机启动' "$enabled" normal
    vps_cmd_status 'TCP/UDP 端口' "${IPERF3_SAVED_PORT:-未设置}" normal
    if [[ -n "$IPERF3_SAVED_PORT" ]] && command -v ss >/dev/null 2>&1; then
        sockets="$(ss -H -ltn "sport = :$IPERF3_SAVED_PORT")" || return 20
    fi
    vps_cmd_status '实际 TCP 监听' "${sockets:-未发现监听}" normal
    if [[ "$active" == 运行中 && -n "$IPERF3_SAVED_PORT" && "$EUID" == 0 ]]; then
        if ! iperf3_ready "$IPERF3_SAVED_PORT"; then vps_cmd_warning '受管进程尚未确认监听，请查看日志'; fi
    fi
}

iperf3_logs() {
    iperf3_check_paths || return $?
    case "$IPERF3_INIT" in
        systemd) journalctl -u "$IPERF3_SERVICE.service" -n 50 --no-pager ;;
        openrc)
            if [[ -f "$IPERF3_LOG" ]]; then
                tail -n 50 -- "$IPERF3_LOG"
            else vps_cmd_info '尚无 iperf3 日志'; fi
            ;;
        *)
            vps_cmd_error '读取服务日志需要 systemd 或 OpenRC'
            return 3
            ;;
    esac
}

iperf3_emit_unit() {
    local port="$1" binary="$2"
    if [[ "$IPERF3_INIT" == systemd ]]; then
        cat <<EOF
$IPERF3_MARKER
[Unit]
Description=vpsctl iperf3 measurement server
After=network.target

[Service]
Type=simple
ExecStart=$binary -s -p $port --forceflush
Restart=on-failure
RestartSec=2
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    else
        cat <<EOF
#!/sbin/openrc-run
$IPERF3_MARKER
description="vpsctl iperf3 measurement server"
command="$binary"
command_args="-s -p $port --forceflush -I $IPERF3_PID_LOGICAL"
supervisor="supervise-daemon"
pidfile="/run/vpsctl-iperf3.pid"
respawn_delay=2
respawn_max=0
output_log="$IPERF3_LOG_LOGICAL"
error_log="$IPERF3_LOG_LOGICAL"
start_pre() {
    checkpath --directory --mode 0755 /run/vpsctl /var/log/vpsctl
}
depend() {
    need net
}
EOF
    fi
}

# Unlike generic dependencies, installing this package can start a second server.
# Resolve and approve the entire missing-tool set once, then prepare only iperf3.
iperf3_ensure_tools() {
    local tool manager package need_server=0 native_present=0 missing_text packages_text
    local -a missing=() packages=()
    local -A seen=()
    for tool in "$@"; do
        _vps_cmd_tool_available "$tool" || missing+=("$tool")
    done
    ((${#missing[@]} > 0)) || return 0
    missing_text="$(
        IFS=' '
        printf '%s' "${missing[*]}"
    )"
    if [[ "$VPSCTL_DRY_RUN" != 1 && "$VPSCTL_INSTALL_DEPS" != 1 ]] && ! vps_cmd_is_interactive; then
        vps_cmd_error "缺少工具：$missing_text；请添加 --install-deps 允许安装依赖"
        return 3
    fi
    manager="$(vps_cmd_detect_package_manager)" || return $?
    for tool in "${missing[@]}"; do
        [[ "$tool" != iperf3 ]] || need_server=1
        package="$(vps_cmd_package_for_tool "$manager" "$tool")" || return $?
        if [[ -z "${seen[$package]+set}" ]]; then
            seen[$package]=1
            packages+=("$package")
        fi
    done
    packages_text="$(
        IFS=' '
        printf '%s' "${packages[*]}"
    )"
    vps_cmd_info "缺少工具：$missing_text；将安装软件包：$packages_text"
    if [[ "$VPSCTL_DRY_RUN" != 1 && "$VPSCTL_INSTALL_DEPS" != 1 ]]; then
        _vps_cmd_confirm_dependency_install || return $?
    fi
    if ((need_server == 1)); then
        if [[ "$IPERF3_INIT" == systemd ]]; then
            if systemctl cat iperf3.service >/dev/null 2>&1; then native_present=1; fi
        elif [[ -e "$(vps_cmd_system_path /etc/init.d/iperf3)" ]]; then native_present=1; fi
        if [[ "$manager" == apt-get && "$native_present" == 0 ]]; then
            if [[ "$VPSCTL_DRY_RUN" == 1 ]]; then
                vps_cmd_info '演练：设置 iperf3/start_daemon=false，禁止软件包默认服务自启'
            else
                command -v debconf-set-selections >/dev/null 2>&1 || {
                    vps_cmd_error '需要 debconf-set-selections 关闭默认服务'
                    return 3
                }
                printf 'iperf3 iperf3/start_daemon boolean false\n' | debconf-set-selections || return 20
            fi
        fi
    fi
    # A subshell keeps the noninteractive package frontend local to this operation.
    (
        export DEBIAN_FRONTEND=noninteractive
        vps_cmd_install_packages "$manager" "${packages[@]}"
    ) || return $?
    if [[ "$VPSCTL_DRY_RUN" == 1 ]]; then
        VPS_CMD_DEPENDENCIES_PLANNED=1
        return 0
    fi
    if [[ "${VPSCTL_TESTING:-0}" != 1 ]]; then _vps_cmd_add_standard_system_paths; fi
    hash -r
    if ((need_server == 1 && native_present == 0)); then
        case "$IPERF3_INIT" in
            systemd)
                if systemctl cat iperf3.service >/dev/null 2>&1; then
                    systemctl stop iperf3.service || return 20
                    systemctl disable iperf3.service || return 20
                fi
                ;;
            openrc)
                if [[ -f "$(vps_cmd_system_path /etc/init.d/iperf3)" ]]; then
                    if rc-service iperf3 status >/dev/null 2>&1; then rc-service iperf3 stop || return 20; fi
                    if [[ -L "$(vps_cmd_system_path /etc/runlevels/default/iperf3)" ]]; then rc-update del iperf3 default || return 20; fi
                fi
                ;;
        esac
    fi
    for tool in "${missing[@]}"; do
        _vps_cmd_tool_available "$tool" || {
            vps_cmd_error "依赖安装后仍不可用：$tool"
            return 20
        }
    done
}

iperf3_update_package() {
    local manager package binary owner=''
    binary="$(command -v iperf3)" || {
        vps_cmd_error '尚未安装 iperf3，请先 start'
        return 3
    }
    manager="$(vps_cmd_detect_package_manager)" || return $?
    package="$(vps_cmd_package_for_tool "$manager" iperf3)" || return $?
    case "$manager" in
        apt-get)
            owner="$(dpkg-query -S "$binary" 2>/dev/null)" || return 3
            [[ "$owner" == "$package: "* || "$owner" == "$package:"*": "* ]] || return 3
            ;;
        dnf5 | dnf | yum | zypper)
            owner="$(rpm -qf --qf '%{NAME}' "$binary" 2>/dev/null)" || return 3
            [[ "$owner" == "$package" ]] || return 3
            ;;
        apk)
            owner="$(apk info --who-owns "$binary" 2>/dev/null)" || return 3
            [[ "$owner" == *" owned by $package-"* ]] || return 3
            ;;
        pacman)
            owner="$(pacman -Qoq "$binary" 2>/dev/null)" || return 3
            [[ "$owner" == "$package" ]] || return 3
            ;;
    esac
    case "$manager" in
        apt-get)
            vps_cmd_apt_update || return $?
            vps_cmd_run env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade --no-install-recommends "$package" || return 20
            ;;
        dnf5 | dnf | yum) vps_cmd_run "$manager" upgrade -y "$package" || return 20 ;;
        apk) vps_cmd_run apk upgrade "$package" || return 20 ;;
        pacman) vps_cmd_run pacman -S --needed --noconfirm "$package" || return 20 ;;
        zypper) vps_cmd_run zypper --non-interactive update --no-recommends "$package" || return 20 ;;
    esac
}

iperf3_desired() {
    local port="$1" enabled="$2" ipv6=false
    vps_ufw_ipv6_available && ipv6=true
    jq -n --arg port "$port" --argjson enabled "$enabled" --argjson ipv6 "$ipv6" '
        if $enabled then [(["ipv4"] + if $ipv6 then ["ipv6"] else [] end)[] as $family |
            ["tcp","udp"][] | {owner:"iperf3",kind:"input",family:$family,proto:.,port:$port,
                source:"any",destination:"any",temporary:false,preserve_existing:true}] else [] end'
}

iperf3_save_state() {
    jq -n --argjson port "$1" --argjson enabled "$2" '{schema_version:1,port:$port,enabled:$enabled}' |
        vps_cmd_atomic_write "$IPERF3_STATE_LOGICAL" 0644
}

iperf3_snapshot() {
    local path index=0
    IPERF3_WORK="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-iperf3.XXXXXX")" || return 20
    IPERF3_OLD_ACTIVE=0
    IPERF3_OLD_ENABLED=0
    if iperf3_service_active; then IPERF3_OLD_ACTIVE=1; fi
    if iperf3_service_enabled; then IPERF3_OLD_ENABLED=1; fi
    for path in "$IPERF3_STATE" "$IPERF3_UNIT"; do
        if [[ -f "$path" ]]; then cp -p -- "$path" "$IPERF3_WORK/$index" || return 20; fi
        index=$((index + 1))
    done
    IPERF3_SNAPSHOT=1
}

iperf3_restore() {
    local path index=0 status=0
    if [[ "$IPERF3_TOUCHED" == 1 ]]; then
        if [[ -f "$IPERF3_UNIT" ]]; then
            if [[ "$IPERF3_INIT" == systemd ]] || iperf3_service_active || [[ -f "$IPERF3_SUPERVISOR_PID" ]]; then
                iperf3_service stop || return 30
            fi
            if [[ "$IPERF3_OLD_ENABLED" == 0 ]] && iperf3_service_enabled; then iperf3_service disable || return 30; fi
        fi
        iperf3_service_active && return 30
        for path in "$IPERF3_STATE" "$IPERF3_UNIT"; do
            if [[ -f "$IPERF3_WORK/$index" ]]; then
                cp -p -- "$IPERF3_WORK/$index" "$path" || status=30
            else rm -f -- "$path" || status=30; fi
            index=$((index + 1))
        done
        rm -f -- "$IPERF3_PID" || status=30
        iperf3_service reload || status=30
        if [[ -f "$IPERF3_UNIT" ]]; then
            if [[ "$IPERF3_OLD_ENABLED" == 1 ]]; then
                iperf3_service enable || status=30
            elif iperf3_service_enabled; then iperf3_service disable || status=30; fi
            if [[ "$IPERF3_OLD_ACTIVE" == 1 ]]; then
                iperf3_service start || status=30
                iperf3_wait_ready "$IPERF3_SAVED_PORT" || status=30
            fi
        fi
    fi
    if [[ "${VPS_UFW_DEPTH:-0}" != 0 ]]; then vps_ufw_rollback || status=30; fi
    return "$status"
}

iperf3_cleanup() {
    local result="$1" restored=0
    trap '' INT TERM HUP
    if [[ "$IPERF3_COMMITTED" == 0 && "$IPERF3_SNAPSHOT" == 1 ]]; then
        iperf3_restore || restored=$?
        if ((restored != 0)); then
            vps_cmd_error "恢复不完整，备份保留于 $IPERF3_WORK；修复后重试 start 或 stop"
            result=30
        fi
    elif [[ "$IPERF3_COMMITTED" == 1 && "${VPS_UFW_DEPTH:-0}" != 0 ]]; then
        vps_ufw_commit || result=30
    fi
    if [[ -n "$IPERF3_WORK" && "$restored" == 0 ]]; then rm -rf -- "$IPERF3_WORK" || result=30; fi
    vps_cmd_unlock
    return "$result"
}

iperf3_remove_runtime() {
    local path
    for path in "$IPERF3_UNIT" "$IPERF3_STATE" "$IPERF3_LOG" "$IPERF3_PID" "$IPERF3_SUPERVISOR_PID"; do
        if ! rm -f -- "$path"; then
            vps_cmd_error "卸载清理失败：$path；请重试 uninstall"
            return 30
        fi
    done
    iperf3_service reload || return 30
    if [[ -d "${IPERF3_STATE%/*}" ]]; then
        rmdir -- "${IPERF3_STATE%/*}" || {
            vps_cmd_error "目录仍有残留，请检查：${IPERF3_STATE%/*}"
            return 30
        }
    fi
    # shellcheck source=../../lib/distribution.sh
    source "$IPERF3_PROJECT_ROOT/lib/distribution.sh"
    vps_distribution_remove_command_cache service:iperf3 || return 30
}

iperf3_examples() {
    vps_cmd_info "其他机器测速（将 SERVER_ADDRESS 替换为本机地址）："
    printf '  iperf3 -c SERVER_ADDRESS -p %s\n' "$1"
    printf '  iperf3 -c SERVER_ADDRESS -p %s -R\n' "$1"
    printf '  iperf3 -c SERVER_ADDRESS -p %s -u -b 10M\n' "$1"
}

iperf3_mutate() (
    local action="$1" port="${2:-}" binary='' mode=0644 confirm_status update_status=0
    IPERF3_WORK=''
    IPERF3_SNAPSHOT=0
    IPERF3_TOUCHED=0
    IPERF3_COMMITTED=0
    [[ "$(uname -s)" == Linux ]] || {
        vps_cmd_error 'iperf3 管理仅支持 Linux'
        return 3
    }
    vps_cmd_require_root || return $?
    case "$IPERF3_INIT" in
        systemd) command -v systemctl >/dev/null 2>&1 || return 3 ;;
        openrc) command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 && command -v supervise-daemon >/dev/null 2>&1 || return 3 ;;
        *)
            vps_cmd_error 'iperf3 服务需要 systemd 或 OpenRC'
            return 3
            ;;
    esac
    iperf3_check_paths || return $?
    if [[ "$action" == uninstall ]]; then
        if vps_cmd_confirm '停止 iperf3 并删除受管服务、配置、专属日志和功能缓存（保留软件包）？'; then
            :
        else
            confirm_status=$?
            [[ "$confirm_status" != 1 ]] || confirm_status=130
            return "$confirm_status"
        fi
    fi
    case "$action" in
        restart) [[ -f "$IPERF3_STATE" && -f "$IPERF3_UNIT" ]] || {
            vps_cmd_error '尚未部署 iperf3 服务，请先 start'
            return 3
        } ;;
        update) command -v iperf3 >/dev/null 2>&1 || {
            vps_cmd_error '尚未安装 iperf3，请先 start'
            return 3
        } ;;
    esac
    if [[ ! -f "$IPERF3_UNIT" ]] && { iperf3_service_active || iperf3_service_enabled; }; then
        vps_cmd_error '同名服务并非本模块受管服务，拒绝操作'
        return 3
    fi
    case "$action" in
        start | restart) iperf3_ensure_tools iperf3 ss jq flock sha256sum || return $? ;;
        update) iperf3_ensure_tools ss jq flock sha256sum || return $? ;;
        *) iperf3_ensure_tools jq flock sha256sum || return $? ;;
    esac
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info "依赖仅完成安装计划；安装后可重跑 iperf3 $action 的完整演练"
        return 0
    fi
    if [[ "$VPSCTL_DRY_RUN" != 1 ]]; then
        vps_cmd_lock iperf3 || return $?
        trap 'if iperf3_cleanup "$?"; then exit 0; else exit "$?"; fi' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
        iperf3_check_paths || return $?
        if [[ ! -f "$IPERF3_UNIT" ]] && { iperf3_service_active || iperf3_service_enabled; }; then
            vps_cmd_error '同名服务并非本模块受管服务，拒绝操作'
            return 3
        fi
    fi
    if [[ "$action" == restart && (! -f "$IPERF3_STATE" || ! -f "$IPERF3_UNIT") ]]; then
        vps_cmd_error '尚未部署 iperf3 服务，请先 start'
        return 3
    fi
    iperf3_load_state || return $?
    [[ -n "$port" ]] || port="${IPERF3_SAVED_PORT:-5201}"
    if [[ "$VPSCTL_DRY_RUN" == 1 ]]; then
        if [[ "$action" == update ]]; then iperf3_update_package || {
            vps_cmd_error '只能更新由当前系统包管理器安装的 iperf3'
            return 3
        }; fi
        vps_cmd_info "演练：iperf3 $action，端口 $port；不修改配置、服务或防火墙"
        case "$action" in
            start | restart) vps_cmd_info '部署/启动服务并启用自启，同步 TCP/UDP UFW 需求' ;;
            stop) vps_cmd_info '停止并取消自启，释放 UFW 需求，保留配置和软件包' ;;
            update) vps_cmd_info '只更新对应软件包；原服务运行时重启，保持自启状态' ;;
            uninstall) vps_cmd_info '清理受管服务、配置、日志及功能缓存；保留系统软件包' ;;
        esac
        return 0
    fi
    case "$action" in
        start | restart)
            binary="$(command -v iperf3)" || return 3
            [[ "$binary" =~ ^/[a-zA-Z0-9_./+-]+$ ]] || {
                vps_cmd_error 'iperf3 路径无法安全写入服务定义'
                return 3
            }
            iperf3_check_port "$port" || return $?
            ;;
    esac
    iperf3_snapshot || return $?
    if [[ "$action" == update ]]; then
        # Package rollback is the package manager's responsibility; service files
        # and the user's actual running/autostart state remain our responsibility.
        iperf3_update_package || update_status=$?
        if ((update_status != 0)); then
            vps_cmd_error 'iperf3 软件包更新失败或当前程序不属于系统软件包；保留原服务配置'
            return "$update_status"
        fi
        if [[ "$IPERF3_OLD_ACTIVE" == 1 && -f "$IPERF3_UNIT" ]]; then
            IPERF3_TOUCHED=1
            iperf3_service restart || return 20
            iperf3_wait_ready "$IPERF3_SAVED_PORT" || return $?
        fi
        IPERF3_COMMITTED=1
        vps_cmd_success "iperf3 软件包更新完成：$(iperf3_version)"
        return 0
    fi
    iperf3_desired "$port" "$([[ "$action" == start || "$action" == restart ]] && printf true || printf false)" >"$IPERF3_WORK/desired.json" || return 20
    vps_ufw_begin iperf3 "$IPERF3_WORK/desired.json" || return $?
    if [[ "$action" == start || "$action" == restart ]]; then
        mkdir -p -- "${IPERF3_STATE%/*}" "${IPERF3_UNIT%/*}" "${IPERF3_LOG%/*}" || return 20
        if [[ "$action" == restart || "$port" != "$IPERF3_SAVED_PORT" ]] || ! iperf3_ready "$port"; then
            IPERF3_TOUCHED=1
            if [[ -f "$IPERF3_UNIT" ]] && { [[ "$IPERF3_INIT" == systemd ]] || iperf3_service_active || [[ -f "$IPERF3_SUPERVISOR_PID" ]]; }; then
                iperf3_service stop || return 20
            fi
            iperf3_service_active && return 20
            rm -f -- "$IPERF3_PID" || return 20
            [[ "$IPERF3_INIT" != openrc ]] || mode=0755
            iperf3_emit_unit "$port" "$binary" | vps_cmd_atomic_write "$IPERF3_UNIT_LOGICAL" "$mode" || return $?
            iperf3_service reload || return 20
            iperf3_service start || return 20
            iperf3_wait_ready "$port" || return $?
        fi
        IPERF3_TOUCHED=1
        if ! iperf3_service_enabled; then iperf3_service enable || return 20; fi
        iperf3_save_state "$port" true || return $?
    else
        IPERF3_TOUCHED=1
        if [[ -f "$IPERF3_UNIT" ]]; then
            if [[ "$IPERF3_INIT" == systemd ]] || iperf3_service_active || [[ -f "$IPERF3_SUPERVISOR_PID" ]]; then iperf3_service stop || return 20; fi
            if iperf3_service_enabled; then iperf3_service disable || return 20; fi
        fi
        iperf3_service_active && return 20
        rm -f -- "$IPERF3_PID" || return 20
        if [[ -n "$IPERF3_SAVED_PORT" ]]; then iperf3_save_state "$port" false || return $?; fi
    fi
    IPERF3_COMMITTED=1
    vps_ufw_commit || return $?
    case "$action" in
        uninstall)
            iperf3_remove_runtime || return $?
            vps_cmd_success 'iperf3 受管服务已卸载；软件包已保留'
            ;;
        start | restart)
            vps_cmd_success "iperf3 已启动并启用自启，TCP/UDP 端口 $port"
            iperf3_examples "$port"
            vps_cmd_info '云安全组及其他防火墙需另行放行；本机监听成功不代表公网可达'
            ;;
        stop) vps_cmd_success 'iperf3 已停止并取消自启；配置和软件包已保留' ;;
    esac
)

iperf3_menu() {
    local choice port result
    vps_cmd_is_interactive || {
        iperf3_usage
        return 0
    }
    while true; do
        iperf3_status || true
        choice="$(vps_cmd_prompt_select 'iperf3 测速服务端' '' start '安装 / 启动 / 修改端口' status '查看状态' restart '重新启动' stop '停止' update '更新软件包' logs '查看日志' uninstall '卸载受管服务')" || return 0
        case "$choice" in
            start)
                while true; do
                    printf 'TCP/UDP 端口（回车使用 %s）：' "${IPERF3_SAVED_PORT:-5201}" >&2
                    IFS= read -r port || return 130
                    port="$(vps_cmd_trim "$port")"
                    [[ -n "$port" ]] || port="${IPERF3_SAVED_PORT:-5201}"
                    if iperf3_valid_port "$port"; then break; fi
                    vps_cmd_warning '请输入 1–65535 的端口'
                done
                iperf3_mutate start "$((10#$port))" || true
                ;;
            status) iperf3_status || true ;;
            logs) iperf3_logs || true ;;
            uninstall)
                result=0
                iperf3_mutate uninstall || result=$?
                ((result != 0)) || return 0
                ;;
            *) iperf3_mutate "$choice" || true ;;
        esac
    done
}

iperf3_main() {
    iperf3_parse "$@" || return $?
    vps_cmd_init 'service iperf3' "$IPERF3_PROJECT_ROOT" || return $?
    [[ "$IPERF3_ACTION" != help ]] || {
        iperf3_usage
        return 0
    }
    iperf3_init_paths || return $?
    case "$IPERF3_ACTION" in
        menu) iperf3_menu ;;
        status) iperf3_status ;;
        logs) iperf3_logs ;;
        *) iperf3_mutate "$IPERF3_ACTION" "$IPERF3_PORT" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then iperf3_main "$@"; fi
