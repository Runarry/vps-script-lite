#!/usr/bin/env bash
# Thin Linux entry point for bin456789/reinstall. Sourcing only defines functions.
# shellcheck source-path=SCRIPTDIR

reinstall_usage() {
    cat <<'EOF'
用法：vpsctl system reinstall [全局选项] [help|status|run [--] 上游参数...|reset|uninstall]

  help / --help  显示本地帮助；不传动作时也显示帮助
  status         只读查看重装脚本、启动项和残留文件
  run            每次下载最新上游脚本，原样传递其后的所有参数
  reset          使用保留的上游脚本撤销重装引导；缺失时重新下载
  uninstall      必要时先运行上游 reset，再清理固定重装文件

全局选项必须放在动作之前：--yes --non-interactive --install-deps
                          --quiet --verbose --no-color
不支持 --dry-run。run/reset/uninstall 仅支持 Linux，且需要 root。
--non-interactive 将上游标准输入接到 /dev/null；--yes 只确认本地卸载。
上游参数及确认交给上游处理；不会自动重启，也不会在 run 后清理启动资源。

示例：vpsctl system reinstall run debian 12 --password 'your password'
      vpsctl --yes system reinstall uninstall
上游：https://github.com/bin456789/reinstall
EOF
}

reinstall_parse_args() {
    REINSTALL_ACTION=help
    REINSTALL_ARGS=()
    while (($#)); do
        case "$1" in
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --install-deps) VPSCTL_INSTALL_DEPS=1 ;;
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --no-color) VPSCTL_NO_COLOR=1 ;;
            --)
                shift
                REINSTALL_ACTION="${1:-help}"
                if (($#)); then shift; fi
                break
                ;;
            -h | --help)
                REINSTALL_ACTION=help
                shift
                break
                ;;
            -*)
                vps_cmd_error '未知全局选项；请使用 help'
                return 2
                ;;
            *)
                REINSTALL_ACTION="$1"
                shift
                break
                ;;
        esac
        shift
    done
    case "$REINSTALL_ACTION" in
        run)
            if [[ "${1:-}" == -- ]]; then shift; fi
            REINSTALL_ARGS=("$@")
            ;;
        help | status | reset | uninstall)
            (($# == 0)) || {
                vps_cmd_error '此动作不接受额外参数'
                return 2
            }
            ;;
        *)
            vps_cmd_error '未知动作；请使用 help'
            return 2
            ;;
    esac
}

reinstall_init_paths() {
    REINSTALL_STATE="$(vps_cmd_system_path /var/lib/vpsctl/reinstall)" || return $?
    REINSTALL_SCRIPT="$REINSTALL_STATE/reinstall.sh"
    REINSTALL_PROC="$(vps_cmd_system_path /proc)" || return $?
    REINSTALL_BOOT="$(vps_cmd_system_path /boot)" || return $?
    REINSTALL_PATHS=(/var/lib/vpsctl/reinstall /reinstall-tmp /reinstall.log
        /reinstall-vmlinuz /reinstall-initrd /reinstall-firmware
        /boot/reinstall-vmlinuz /boot/reinstall-initrd /boot/reinstall-firmware)
}

# /proc mountinfo detects nested mounts, including bind mounts on the same device.
reinstall_check_mounts() {
    local target="$1" line mount_path
    local -a fields=()
    [[ -r "$REINSTALL_PROC/self/mountinfo" ]] || {
        vps_cmd_error '无法读取挂载信息；拒绝操作重装文件'
        return 3
    }
    while IFS= read -r line; do
        IFS=' ' read -r -a fields <<<"$line"
        ((${#fields[@]} >= 6)) || continue
        printf -v mount_path '%b' "${fields[4]}"
        if [[ "$mount_path" == "$target" || "$mount_path" == "$target/"* ]]; then
            vps_cmd_error "重装路径存在挂载点，拒绝操作：$mount_path"
            return 3
        fi
    done <"$REINSTALL_PROC/self/mountinfo"
}

reinstall_efi_paths() {
    local base root entry
    for base in /efi /boot/efi /boot; do
        root="$(vps_cmd_system_path "$base")" || return $?
        printf '%s\n' "$root/EFI/reinstall"
        for entry in "$root"/[Ee][Ff][Ii]/[Rr][Ee][Ii][Nn][Ss][Tt][Aa][Ll][Ll]; do
            [[ -e "$entry" || -L "$entry" ]] || continue
            printf '%s\n' "$entry"
        done
    done
}

reinstall_check_boundaries() {
    local logical path base
    local -a paths=()
    for logical in "${REINSTALL_PATHS[@]}"; do
        paths+=("$(vps_cmd_system_path "$logical")")
    done
    # Upstream reset may also remove these files and EFI directories.
    for base in /efi /boot/efi; do
        paths+=("$(vps_cmd_system_path "$base/reinstall-vmlinuz")"
        "$(vps_cmd_system_path "$base/reinstall-initrd")")
    done
    while IFS= read -r path; do paths+=("$path"); done < <(reinstall_efi_paths)
    for path in "${paths[@]}" "$REINSTALL_SCRIPT"; do
        vps_cmd_require_no_symlink_components "$path" || return $?
        reinstall_check_mounts "$path" || return $?
    done
    if [[ -e "$REINSTALL_STATE" && ! -d "$REINSTALL_STATE" ]]; then
        vps_cmd_error '重装脚本目录不是普通目录'
        return 3
    fi
    if [[ -e "$REINSTALL_SCRIPT" && ! -f "$REINSTALL_SCRIPT" ]]; then
        vps_cmd_error '保留的重装脚本不是普通文件'
        return 3
    fi
}

reinstall_check_environment() {
    local file name command_line='' line fs mount_path candidate index
    local -a argv=() fields=()
    if [[ -r "$REINSTALL_PROC/cmdline" ]]; then
        IFS= read -r command_line <"$REINSTALL_PROC/cmdline" || true
    fi
    if [[ "$command_line" =~ (^|[[:space:]])(finalos_[[:alnum:]_]+=|extra_confhome=|rd.live.image|boot=live|root=live:) ]] ||
        [[ -e "$(vps_cmd_system_path /trans.sh)" || -d "$(vps_cmd_system_path /run/initramfs/live)" ]]; then
        vps_cmd_error '当前处于安装或 Live 环境，拒绝操作重装文件'
        return 3
    fi
    if [[ -r "$REINSTALL_PROC/self/mountinfo" ]]; then
        while IFS= read -r line; do
            IFS=' ' read -r -a fields <<<"$line"
            ((${#fields[@]} >= 7)) || continue
            printf -v mount_path '%b' "${fields[4]}"
            [[ "$mount_path" == "${VPSCTL_SYSTEM_ROOT:-}/" || "$mount_path" == "${VPSCTL_SYSTEM_ROOT:-}" ]] || continue
            fs="${line#* - }"
            fs="${fs%% *}"
            case "$fs" in tmpfs | ramfs | rootfs | overlay | squashfs)
                vps_cmd_error "当前根目录是 $fs 安装/Live 文件系统，拒绝操作"
                return 3
                ;;
            esac
        done <"$REINSTALL_PROC/self/mountinfo"
    fi
    for file in "$REINSTALL_PROC"/[0-9]*/cmdline; do
        [[ -r "$file" ]] || continue
        name="${file%/cmdline}"
        name="${name##*/}"
        [[ "$name" != "$$" && "$name" != "$BASHPID" ]] || continue
        argv=()
        mapfile -d '' -t argv <"$file" 2>/dev/null || continue
        ((${#argv[@]})) || continue
        candidate="${argv[0]}"
        case "${candidate##*/}" in
            bash | sh | ash | dash | zsh | ksh)
                candidate=''
                for ((index = 1; index < ${#argv[@]}; index++)); do
                    case "${argv[index]}" in
                        -c* | -[!-]*c*) break ;;
                        -o | +o | -O | +O | --rcfile | --init-file)
                            index=$((index + 1))
                            continue
                            ;;
                        --)
                            index=$((index + 1))
                            candidate="${argv[index]:-}"
                            break
                            ;;
                        -*) continue ;;
                        *)
                            candidate="${argv[index]}"
                            break
                            ;;
                    esac
                done
                ;;
        esac
        [[ "$candidate" != "$REINSTALL_PROJECT_ROOT/commands/system/reinstall.sh" ]] || continue
        case "${candidate##*/}" in
            reinstall.sh | trans.sh | trans.start)
                vps_cmd_error "检测到正在运行的重装进程 PID $name；请等待其结束"
                return 3
                ;;
        esac
    done
}

# Only inspect known boot configuration locations. Resolve common grub2 -> grub
# links for reads, but refuse a configuration that escapes the boot directory.
reinstall_boot_configs() {
    local file resolved directory output
    local -a files=()
    if [[ -d "$REINSTALL_BOOT" ]]; then
        output="$(find "$REINSTALL_BOOT" -xdev \( -type f -o -type l \) -name extlinux.conf -print)" || {
            vps_cmd_error '无法完整读取 /boot 中的 Extlinux 配置'
            return 3
        }
        while IFS= read -r file; do [[ -z "$file" ]] || files+=("$file"); done <<<"$output"
    fi
    for directory in "$REINSTALL_BOOT"/grub*; do
        [[ -d "$directory" ]] || continue
        resolved="$(readlink -f -- "$directory")" || return 3
        case "$resolved" in "$REINSTALL_BOOT/"*) ;; *)
            vps_cmd_error "GRUB 目录超出 /boot 边界：$directory"
            return 3
            ;;
        esac
        output="$(find "$resolved" -xdev \( -type f -o -type l \) \( -name grub.cfg -o -name custom.cfg \) -print)" || {
            vps_cmd_error '无法完整读取 GRUB 配置'
            return 3
        }
        while IFS= read -r file; do [[ -z "$file" ]] || files+=("$file"); done <<<"$output"
    done
    files+=("$REINSTALL_BOOT/grub.cfg")
    for file in "${files[@]}"; do
        [[ -e "$file" || -L "$file" ]] || continue
        resolved="$(readlink -f -- "$file")" || return 3
        case "$resolved" in "$REINSTALL_BOOT/"*) ;; *)
            vps_cmd_error "启动配置超出 /boot 边界：$file"
            return 3
            ;;
        esac
        [[ -f "$resolved" && -r "$resolved" ]] || {
            vps_cmd_error "无法读取启动配置：$file"
            return 3
        }
        printf '%s\n' "$resolved"
    done
}

reinstall_detect_boot_entries() {
    local resolved root output configs file name
    REINSTALL_PENDING=0
    configs="$(reinstall_boot_configs)" || return $?
    while IFS= read -r resolved; do
        [[ -n "$resolved" ]] || continue
        if grep -Eq '### (BEGIN|END) reinstall\.sh ###|reinstall-(vmlinuz|initrd)|^[[:space:]]*LABEL[[:space:]]+reinstall([[:space:]]|$)' "$resolved"; then
            REINSTALL_PENDING=1
        fi
    done <<<"$configs"
    while IFS= read -r root; do
        for file in "$root"/*; do
            [[ -f "$file" ]] || continue
            name="${file##*/}"
            case "${name,,}" in
                grub.cfg | grubx64.efi | grubaa64.efi | netboot.xyz.efi | netboot.xyz-arm64.efi)
                    REINSTALL_PENDING=1
                    ;;
            esac
        done
    done < <(reinstall_efi_paths)
    root="$(vps_cmd_system_path /sys/firmware/efi/efivars)" || return $?
    if [[ -d "$root" ]]; then
        if ! command -v efibootmgr >/dev/null 2>&1; then
            vps_cmd_error 'UEFI 启动项检测需要 efibootmgr（可用 --install-deps 安装）'
            return 3
        fi
        if ! output="$(efibootmgr -v 2>/dev/null)"; then
            vps_cmd_error '无法读取 UEFI 启动项，不能确定是否仍有重装引导'
            return 3
        fi
        if grep -Eiq '^Boot[[:xdigit:]]{4}.*reinstall' <<<"$output"; then
            REINSTALL_PENDING=1
        fi
    fi
}

reinstall_valid_script() {
    local script="$1" first=''
    [[ -f "$script" && ! -L "$script" && -s "$script" ]] || return 1
    IFS= read -r first <"$script" || return 1
    [[ "$first" == '#!'* && "$first" =~ (ba)?sh([[:space:]]|$) ]] || return 1
    bash -n -- "$script" >/dev/null 2>&1
}

reinstall_download() {
    local status=0
    vps_cmd_ensure_tools system-reinstall curl mktemp || return $?
    reinstall_check_boundaries || return $?
    mkdir -p -- "$REINSTALL_STATE" || return 20
    chmod 0700 -- "$REINSTALL_STATE" || return 20
    REINSTALL_TEMP="$(mktemp "$REINSTALL_STATE/.reinstall.XXXXXX")" || return 20
    vps_cmd_info '正在下载最新上游 reinstall.sh'
    if ! curl -q --fail --location --silent --show-error --connect-timeout 15 \
        --max-time 180 --retry 2 --proto '=https' --proto-redir '=https' \
        --output "$REINSTALL_TEMP" https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh; then
        vps_cmd_error '上游下载失败；保留旧脚本，本次不会执行它'
        status=20
    elif ! reinstall_valid_script "$REINSTALL_TEMP"; then
        vps_cmd_error '下载结果不是有效的非空 shell 脚本；保留旧脚本'
        status=20
    elif ! chmod 0700 -- "$REINSTALL_TEMP" || ! mv -f -- "$REINSTALL_TEMP" "$REINSTALL_SCRIPT"; then
        status=20
    fi
    if [[ -e "$REINSTALL_TEMP" ]]; then rm -f -- "$REINSTALL_TEMP" || return 20; fi
    REINSTALL_TEMP=''
    return "$status"
}

reinstall_prepare_reset() {
    if [[ ! -e "$REINSTALL_SCRIPT" ]]; then reinstall_download || return $?; fi
    if ! reinstall_valid_script "$REINSTALL_SCRIPT"; then
        vps_cmd_error '保留的上游脚本无效；未执行 reset，也未删除恢复文件'
        return 3
    fi
}

reinstall_execute_upstream() {
    # exec keeps the foreground terminal, exit status and signal behavior. The
    # inherited flock descriptor stays open for the complete upstream process.
    if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == 1 ]]; then
        exec bash "$REINSTALL_SCRIPT" "$@" </dev/null
    else
        exec bash "$REINSTALL_SCRIPT" "$@"
    fi
}

reinstall_allocated_bytes() {
    local logical path output total=0
    reinstall_check_boundaries || return 30
    for logical in "${REINSTALL_PATHS[@]}"; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        [[ -e "$path" || -L "$path" ]] || continue
        output="$(du -sk -- "$path")" || return 30
        total=$((total + ${output%%[[:space:]]*} * 1024))
    done
    printf '%s\n' "$total"
}

reinstall_report_reclaimed() {
    local before="$1" after
    if ! after="$(reinstall_allocated_bytes)"; then
        vps_cmd_warning '已回收分配空间：无法确定'
        return 30
    fi
    vps_cmd_info "已回收分配空间：$((before > after ? before - after : 0)) 字节"
}

reinstall_uninstall() {
    local before path logical status=0 reset_status
    vps_cmd_confirm '撤销重装引导并清理固定重装文件？' || return $?
    reinstall_check_environment || return $?
    reinstall_check_boundaries || return $?
    reinstall_detect_boot_entries || return $?
    before="$(reinstall_allocated_bytes)" || return $?
    if ((REINSTALL_PENDING)); then
        reinstall_prepare_reset || return $?
        # Download and confirmation may take time; recheck before upstream rm.
        reinstall_check_environment || return $?
        reinstall_check_boundaries || return $?
        vps_cmd_info '检测到重装启动项，先调用上游 reset'
        if (reinstall_execute_upstream reset); then
            :
        else
            reset_status=$?
            vps_cmd_error "上游 reset 失败（退出码 $reset_status）；停止清理并保留剩余恢复文件"
            reinstall_report_reclaimed "$before" || true
            return 30
        fi
        if ! reinstall_check_boundaries || ! reinstall_detect_boot_entries; then
            reinstall_report_reclaimed "$before" || true
            return 30
        fi
        if ((REINSTALL_PENDING)); then
            vps_cmd_error '上游 reset 后仍检测到重装启动项；停止清理并保留剩余恢复文件'
            reinstall_report_reclaimed "$before" || true
            return 30
        fi
    fi
    reinstall_check_environment || return 30
    reinstall_check_boundaries || return 30
    for logical in "${REINSTALL_PATHS[@]}"; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        [[ -e "$path" || -L "$path" ]] || continue
        if ! rm -rf -- "$path"; then
            vps_cmd_error "清理失败：$logical"
            status=30
        elif [[ -e "$path" || -L "$path" ]]; then
            vps_cmd_error "清理后仍存在：$logical"
            status=30
        else
            vps_cmd_info "已清理：$logical"
        fi
    done
    reinstall_report_reclaimed "$before" || return 30
    if ((status == 0)); then vps_cmd_success '重装文件已清理（没有残留时无需操作）'; fi
    return "$status"
}

reinstall_status() {
    local logical path bytes present=0 status=0
    if [[ -f "$REINSTALL_SCRIPT" ]]; then
        vps_cmd_status '保留的上游脚本' "$REINSTALL_SCRIPT" normal
    else
        vps_cmd_status '保留的上游脚本' '无' muted
    fi
    if reinstall_detect_boot_entries; then
        if ((REINSTALL_PENDING)); then
            vps_cmd_status '重装启动项' '存在' warning
        else
            vps_cmd_status '重装启动项' '未发现' normal
        fi
    else
        vps_cmd_status '重装启动项' '无法确定' warning
        status=3
    fi
    for logical in "${REINSTALL_PATHS[@]}"; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        if [[ -e "$path" || -L "$path" ]]; then
            vps_cmd_status '重装文件' "$logical" normal
            present=1
        fi
    done
    if ((present == 0)); then vps_cmd_status '重装文件' '未发现' muted; fi
    if bytes="$(reinstall_allocated_bytes)"; then
        vps_cmd_status '占用的分配空间' "$bytes 字节" normal
    else
        vps_cmd_status '占用的分配空间' '无法确定' warning
        status=3
    fi
    if ! reinstall_check_environment; then
        vps_cmd_status '运行环境' '存在活动重装进程或处于安装环境' warning
    fi
    return "$status"
}

reinstall_cleanup() {
    if [[ -n "${REINSTALL_TEMP:-}" ]]; then rm -f -- "$REINSTALL_TEMP"; fi
    vps_cmd_unlock
}

reinstall_main() {
    local REINSTALL_PROJECT_ROOT REINSTALL_ACTION REINSTALL_STATE REINSTALL_SCRIPT
    local REINSTALL_PROC REINSTALL_BOOT REINSTALL_PENDING=0
    local -a REINSTALL_ARGS=() REINSTALL_PATHS=()
    REINSTALL_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
    # shellcheck source=../../lib/command.sh disable=SC1091
    source "$REINSTALL_PROJECT_ROOT/lib/command.sh"
    reinstall_parse_args "$@" || return $?
    vps_cmd_init system-reinstall "$REINSTALL_PROJECT_ROOT" || return $?
    if [[ "$REINSTALL_ACTION" == help ]]; then
        reinstall_usage
        return 0
    fi
    reinstall_init_paths || return $?
    if [[ "$REINSTALL_ACTION" == status ]]; then
        reinstall_status
        return $?
    fi
    if [[ "$VPSCTL_DRY_RUN" == 1 ]]; then
        vps_cmd_error '系统重装不支持 --dry-run；未下载或执行上游脚本'
        return 2
    fi
    [[ "$(uname -s)" == Linux ]] || {
        vps_cmd_error '系统重装仅支持 Linux'
        return 3
    }
    vps_cmd_require_root || return $?
    reinstall_check_environment || return $?
    reinstall_check_boundaries || return $?
    vps_cmd_ensure_tools system-reinstall flock || return $?
    vps_cmd_lock system-reinstall || return $?
    # Keep the lock file itself: deleting it would allow a second lock inode.
    REINSTALL_TEMP=''
    trap 'reinstall_cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    reinstall_check_environment || return $?
    reinstall_check_boundaries || return $?
    if [[ "$REINSTALL_ACTION" == uninstall && -d "$(vps_cmd_system_path /sys/firmware/efi/efivars)" ]]; then
        vps_cmd_ensure_tools system-reinstall efibootmgr || return $?
    fi
    case "$REINSTALL_ACTION" in
        run)
            reinstall_download || return $?
            reinstall_check_environment || return $?
            reinstall_check_boundaries || return $?
            reinstall_execute_upstream "${REINSTALL_ARGS[@]}"
            ;;
        reset)
            reinstall_prepare_reset || return $?
            reinstall_check_environment || return $?
            reinstall_check_boundaries || return $?
            reinstall_execute_upstream reset
            ;;
        uninstall) reinstall_uninstall ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
    IFS=$'\n\t'
    umask 077
    reinstall_main "$@"
fi
