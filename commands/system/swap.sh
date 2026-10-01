#!/usr/bin/env bash
# Manage ordinary disk swap as a recoverable fstab transaction.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'

SWAP_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/command.sh
# shellcheck disable=SC1091
source "${SWAP_PROJECT_ROOT}/lib/command.sh"

SWAP_MARKER='# Managed by vpsctl system swap.'
SWAP_ACTION=''
SWAP_SIZE=auto
SWAP_RESERVE_BYTES=268435456

swap_usage() {
    cat <<'EOF'
用法：vpsctl system swap [status | set [--size auto|整数M|整数G] | disable | help]

  status   查看内存、活动 swap 与 fstab（不需要 root）
  set      迁移到一个受管理的 swap 文件；默认 --size auto
  disable  停用磁盘 swap、移除 swap 文件，保留分区并禁用其自动启用
  auto     内存的两倍，向上取整到 GiB，限制在 1–8 GiB

手动大小至少 64M，M/G 按 MiB/GiB 计算。不修改 swappiness。
迁移成功后删除旧的普通 swap 文件；分区数据不变。
支持 ext2/ext3/ext4/XFS，新旧文件共存期间另保留 256 MiB 磁盘空间。
支持 systemd / OpenRC；拒绝 zram、独立 swap 管理器和自定义 swap 单元。
无参数时：交互终端打开菜单，其他场景显示状态。
全局选项：--dry-run --yes --non-interactive --install-deps --quiet --verbose --no-color
EOF
}

swap_parse_args() {
    local size_seen=0
    SWAP_ACTION=''
    SWAP_SIZE=auto
    while (($#)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --install-deps) VPSCTL_INSTALL_DEPS=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --no-color) VPSCTL_NO_COLOR=1 ;;
            --)
                shift
                (($#)) || break
                [[ -z "$SWAP_ACTION" ]] || return 2
                case "$1" in status | set | disable | help) SWAP_ACTION="$1" ;; *) return 2 ;; esac
                ;;
            -h | --help) SWAP_ACTION=help ;;
            status | set | disable | help)
                [[ -z "$SWAP_ACTION" ]] || return 2
                SWAP_ACTION="$1"
                ;;
            --size)
                (($# >= 2 && size_seen == 0)) || return 2
                SWAP_SIZE="$2"
                size_seen=1
                shift
                ;;
            --size=*)
                ((size_seen == 0)) || return 2
                SWAP_SIZE="${1#*=}"
                size_seen=1
                ;;
            *)
                vps_cmd_error "未知参数：$1"
                return 2
                ;;
        esac
        shift
    done
    ((size_seen == 0)) || [[ "$SWAP_ACTION" == set ]] || return 2
}

swap_init_paths() {
    SWAP_FSTAB="$(vps_cmd_system_path /etc/fstab)" || return $?
    SWAP_MEMINFO="$(vps_cmd_system_path /proc/meminfo)" || return $?
    SWAP_DIRECTORY="$(vps_cmd_system_path /var/lib/vpsctl/system/swap)" || return $?
    SWAP_BACKUP_ROOT="$(vps_cmd_system_path /var/lib/vpsctl/backups/system/swap)" || return $?
    SWAP_OPENRC_CONFIG="$(vps_cmd_system_path /etc/conf.d/swap)" || return $?
}

# Bound decimal strings before Bash arithmetic (including leading zeros).
swap_decimal() {
    local number="$1" limit="$2"
    [[ "$number" =~ ^[0-9]+$ ]] || return 2
    while [[ ${#number} -gt 1 && "$number" == 0* ]]; do number="${number#0}"; done
    ((${#number} < ${#limit})) || {
        ((${#number} == ${#limit})) && [[ "$number" < "$limit" || "$number" == "$limit" ]] || return 2
    }
    printf '%s\n' "$number"
}

swap_mem_kib() {
    local wanted="$1" key value unit rest
    while IFS=$' \t' read -r key value unit rest; do
        [[ "$key" == "${wanted}:" ]] || continue
        [[ "$unit" == kB && -z "$rest" ]] || return 3
        swap_decimal "$value" 9007199254740991
        return $?
    done <"$SWAP_MEMINFO"
    return 3
}

swap_size_bytes() {
    local value="$1" memory="${2:-}" number factor gib
    if [[ "$value" == auto ]]; then
        [[ -n "$memory" ]] || memory="$(swap_mem_kib MemTotal)" || return 3
        memory="$(swap_decimal "$memory" 9007199254740991)" || return 2
        ((memory > 0)) || return 2
        # Saturate before multiplication; at 4 GiB RAM the result is 8 GiB.
        if ((memory >= 4194304)); then gib=8; else gib=$(((memory * 2 + 1048575) / 1048576)); fi
        ((gib >= 1)) || gib=1
        printf '%s\n' "$((gib * 1073741824))"
        return 0
    fi
    [[ "$value" =~ ^([0-9]+)([MG])$ ]] || return 2
    number="${BASH_REMATCH[1]}"
    if [[ "${BASH_REMATCH[2]}" == M ]]; then
        factor=1048576
        number="$(swap_decimal "$number" 8796093021951)" || return 2
    else
        factor=1073741824
        number="$(swap_decimal "$number" 8589934591)" || return 2
    fi
    # Leave space for reserve arithmetic as well as the file length itself.
    ((number > 0 && number <= (9223372036854775807 - SWAP_RESERVE_BYTES) / factor)) || return 2
    number=$((number * factor))
    ((number >= 67108864)) || return 2
    printf '%s\n' "$number"
}

swap_fstab_decode() {
    local value="$1" result='' char code
    while [[ -n "$value" ]]; do
        char="${value:0:1}"
        value="${value:1}"
        if [[ "$char" == \\ ]]; then
            code="${value:0:3}"
            case "$code" in 040) char=' ' ;; 011) char=$'\t' ;; 134) char=$'\\' ;; 043) char='#' ;; *) return 3 ;; esac
            value="${value:3}"
        fi
        result+="$char"
    done
    [[ "$result" != *$'\n'* && "$result" != *$'\r'* ]] || return 3
    printf '%s' "$result"
}

swap_fstab_encode() {
    local value="$1"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 3
    value="${value//\\/\\134}"
    value="${value// /\\040}"
    value="${value//$'\t'/\\011}"
    value="${value//#/\\043}"
    printf '%s' "$value"
}

swap_raw_decode() {
    local value="$1" result='' char code
    while [[ -n "$value" ]]; do
        char="${value:0:1}"
        value="${value:1}"
        if [[ "$char" == \\ ]]; then
            [[ "$value" =~ ^x([0-9a-fA-F]{2}) ]] || return 3
            code="${BASH_REMATCH[1]}"
            [[ "$code" != 00 && "$code" != 0[aAdD] ]] || return 3
            printf -v char '%b' "\\x$code"
            value="${value:3}"
        fi
        result+="$char"
    done
    [[ "$result" == /* && "$result" != *$'\n'* && "$result" != *$'\r'* ]] || return 3
    printf '%s' "$result"
}

swap_logical_path() {
    local path="$1"
    if [[ "${VPSCTL_TESTING:-0}" == 1 && "$path" == "$VPSCTL_SYSTEM_ROOT/"* ]]; then
        printf '%s' "${path#"$VPSCTL_SYSTEM_ROOT"}"
    else
        printf '%s' "$path"
    fi
}

swap_resolve_source() {
    local source="$1" resolved matches
    case "$source" in
        UUID=* | LABEL=* | PARTUUID=* | PARTLABEL=*)
            matches="$(blkid -t "$source" -o device)" || return 3
            [[ -n "$matches" && "$matches" != *$'\n'* ]] || {
                vps_cmd_error "无法唯一解析 swap 来源：$source"
                return 3
            }
            source="$matches"
            ;;
        /*) ;;
        *)
            vps_cmd_error "不支持的 swap 来源：$source"
            return 3
            ;;
    esac
    if [[ "${VPSCTL_TESTING:-0}" == 1 && "$source" != "$VPSCTL_SYSTEM_ROOT/"* ]]; then
        source="$(vps_cmd_system_path "$source")" || return $?
    fi
    if [[ -f "$source" ]]; then
        vps_cmd_require_no_symlink_components "$source" || return $?
    fi
    resolved="$(readlink -f -- "$source")" || {
        vps_cmd_error "swap 来源不存在：$source"
        return 3
    }
    [[ -e "$resolved" && "$resolved" == /* && "$resolved" != *$'\n'* && "$resolved" != *$'\r'* ]] || return 3
    printf '%s' "$resolved"
}

swap_read_fstab() {
    local file="$1" line trimmed index=0
    local -a fields=()
    SWAP_FSTAB_LINES=()
    SWAP_FSTAB_SOURCE=()
    SWAP_FSTAB_TYPE=()
    SWAP_FSTAB_OPTIONS=()
    SWAP_FSTAB_CANONICAL=()
    SWAP_FSTAB_FINAL_NEWLINE=1
    [[ -r "$file" && -f "$file" ]] || {
        vps_cmd_error "无法读取 fstab：$file"
        return 3
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        SWAP_FSTAB_LINES+=("$line")
        trimmed="$(vps_cmd_trim "$line")"
        if [[ -n "$trimmed" && "$trimmed" != \#* ]]; then
            IFS=$' \t' read -r -a fields <<<"$line"
            if [[ "${fields[2]:-}" == swap ]]; then
                ((${#fields[@]} >= 4)) || return 3
                SWAP_FSTAB_SOURCE[index]="$(swap_fstab_decode "${fields[0]}")" || return 3
                SWAP_FSTAB_TYPE[index]=swap
                SWAP_FSTAB_OPTIONS[index]="${fields[3]}"
            fi
        fi
        index=$((index + 1))
    done <"$file"
    # read keeps every unrelated line intact, including an absent last newline.
    if [[ -s "$file" && "$(vps_cmd_trim "$(tail -c 1 -- "$file" | od -An -tu1)")" != 10 ]]; then SWAP_FSTAB_FINAL_NEWLINE=0; fi
}

swap_active_load() {
    local output name type size used priority extra resolved
    local -A seen=()
    SWAP_ACTIVE_PATHS=()
    SWAP_ACTIVE_TYPES=()
    SWAP_ACTIVE_SIZES=()
    SWAP_ACTIVE_USED=()
    SWAP_ACTIVE_PRIORITIES=()
    output="$(LC_ALL=C swapon --show=NAME,TYPE,SIZE,USED,PRIO --bytes --raw --noheadings)" || return 20
    SWAP_ACTIVE_RAW="$output"
    while IFS=$' \t' read -r name type size used priority extra; do
        [[ -n "$name" ]] || continue
        [[ -z "$extra" && "$priority" =~ ^-?[0-9]+$ ]] || return 3
        size="$(swap_decimal "$size" 9223372036854775807)" || return 3
        used="$(swap_decimal "$used" "$size")" || return 3
        name="$(swap_raw_decode "$name")" || return 3
        resolved="$(swap_resolve_source "$name")" || return 3
        [[ -z "${seen[$resolved]+set}" ]] || continue
        seen[$resolved]=1
        SWAP_ACTIVE_PATHS+=("$resolved")
        SWAP_ACTIVE_TYPES+=("$type")
        SWAP_ACTIVE_SIZES+=("$size")
        SWAP_ACTIVE_USED+=("$used")
        SWAP_ACTIVE_PRIORITIES+=("$priority")
    done <<<"$output"
}

swap_file_identity() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 3
    vps_cmd_require_no_symlink_components "$path" || return $?
    [[ "$(stat -c %h -- "$path")" == 1 ]] || {
        vps_cmd_error "拒绝删除有多个硬链接的 swap 文件：$path"
        return 3
    }
    stat -c '%d:%i:%s:%h:%u:%a' -- "$path"
}

swap_source_kind() {
    local path="$1" type parent
    if [[ -f "$path" ]]; then
        printf file
    elif [[ -b "$path" ]]; then
        case "${path##*/}" in zram* | loop* | ram*)
            vps_cmd_error "不支持内存或 loop swap：$path"
            return 3
            ;;
        esac
        type="$(lsblk -dn -o TYPE -- "$path")" || return 3
        parent="$(lsblk -dn -o PKNAME -- "$path")" || return 3
        [[ "$type" == part && "$parent" != loop* && "$parent" != zram* && "$parent" != ram* ]] || {
            vps_cmd_error "只支持普通磁盘分区或文件：$path"
            return 3
        }
        printf partition
    else
        vps_cmd_error "不是普通 swap 文件或磁盘分区：$path"
        return 3
    fi
}

swap_inventory_load() {
    local index path kind signature
    local -A seen=()
    SWAP_OLD_PATHS=()
    SWAP_OLD_KINDS=()
    SWAP_OLD_IDENTITIES=()
    swap_read_fstab "$SWAP_FSTAB" || return $?
    swap_active_load || return $?
    SWAP_ORIGINAL_PATHS=("${SWAP_ACTIVE_PATHS[@]}")
    SWAP_ORIGINAL_TYPES=("${SWAP_ACTIVE_TYPES[@]}")
    SWAP_ORIGINAL_SIZES=("${SWAP_ACTIVE_SIZES[@]}")
    SWAP_ORIGINAL_PRIORITIES=("${SWAP_ACTIVE_PRIORITIES[@]}")
    SWAP_ORIGINAL_RAW="$SWAP_ACTIVE_RAW"
    for index in "${!SWAP_FSTAB_SOURCE[@]}"; do
        path="$(swap_resolve_source "${SWAP_FSTAB_SOURCE[$index]}")" || return $?
        SWAP_FSTAB_CANONICAL[index]="$path"
    done
    for path in "${SWAP_ACTIVE_PATHS[@]}" "${SWAP_FSTAB_CANONICAL[@]}"; do
        [[ -z "${seen[$path]+set}" ]] || continue
        seen[$path]=1
        kind="$(swap_source_kind "$path")" || return $?
        signature="$(blkid -p -s TYPE -o value -- "$path")" || {
            vps_cmd_error "无法验证 swap 签名：$path"
            return 3
        }
        [[ "$signature" == swap ]] || {
            vps_cmd_error "不是有效 swap：$path"
            return 3
        }
        SWAP_OLD_PATHS+=("$path")
        SWAP_OLD_KINDS+=("$kind")
        if [[ "$kind" == file ]]; then
            SWAP_OLD_IDENTITIES+=("$(swap_file_identity "$path")") || return $?
        else
            SWAP_OLD_IDENTITIES+=("$(stat -c '%t:%T' -- "$path")") || return $?
        fi
    done
}

swap_detect_init() {
    SWAP_INIT="${VPSCTL_ENV_INIT:-unknown}"
    case "$SWAP_INIT" in systemd) ;; openrc | openrc-init) SWAP_INIT=openrc ;;
    *)
        if [[ -d "$(vps_cmd_system_path /run/systemd/system)" ]]; then
            SWAP_INIT=systemd
        elif command -v rc-update >/dev/null 2>&1; then
            SWAP_INIT=openrc
        else
            vps_cmd_error 'swap 持久化需要 systemd 或 OpenRC'
            return 3
        fi
        ;;
    esac
}

swap_ensure_tools() {
    local action="$1"
    if [[ "$action" == status ]]; then
        _vps_cmd_tool_available swapon || {
            vps_cmd_error '查看状态需要 util-linux swapon；status 不安装或更改系统'
            return 3
        }
        return 0
    fi
    vps_cmd_ensure_tools system-swap swapon swapoff findmnt blkid lsblk flock readlink stat df install mktemp cp mv rm chmod chown cmp sha256sum date cat tail od || return $?
    [[ "$action" != set ]] || vps_cmd_ensure_tools system-swap-create dd mkswap || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
    swap_detect_init || return $?
    case "$SWAP_INIT" in
        systemd) vps_cmd_ensure_tools system-swap-systemd systemctl systemd-escape ;;
        openrc) vps_cmd_ensure_tools system-swap-openrc rc-update ;;
    esac
}

# No calls which install, lock, reload services, or write files occur here.
swap_check_managers() {
    local output unit rest props key value what source fragment drops state canonical path
    local -A units=() generated=() aliases=()
    if [[ "$SWAP_INIT" == systemd ]]; then
        swap_target_available || return $?
        output="$(systemctl list-unit-files --type=service --no-legend --no-pager)" || return 3
        while IFS=$' \t' read -r unit state rest; do
            case "$unit" in
                *swap*.service | *zram*.service)
                    case "$state" in disabled | masked | masked-runtime)
                        if systemctl is-active --quiet "$unit"; then
                            vps_cmd_error "独立 swap 管理器正在运行：$unit"
                            return 3
                        fi
                        ;;
                    *)
                        vps_cmd_error "发现独立 swap 管理器：$unit"
                        return 3
                        ;;
                    esac
                    ;;
            esac
        done <<<"$output"
        output="$(systemctl list-units --all --type=swap --plain --no-legend --no-pager)" || return 3
        while IFS=$' \t' read -r unit rest; do [[ "$unit" == *.swap ]] && units[$unit]=1; done <<<"$output"
        output="$(systemctl list-unit-files --type=swap --no-legend --no-pager)" || return 3
        while IFS=$' \t' read -r unit rest; do [[ "$unit" == *.swap ]] && units[$unit]=1; done <<<"$output"
        for unit in "${!units[@]}"; do
            props="$(systemctl show "$unit" -p What -p SourcePath -p FragmentPath -p DropInPaths -p LoadState)" || return 3
            what='' source='' fragment='' drops='' state=''
            while IFS='=' read -r key value; do
                case "$key" in What) what="$value" ;; SourcePath) source="$value" ;; FragmentPath) fragment="$value" ;; DropInPaths) drops="$value" ;; LoadState) state="$value" ;; esac
            done <<<"$props"
            [[ "$state" != masked && -z "$drops" ]] || {
                vps_cmd_error "自定义或屏蔽的 swap 单元：$unit"
                return 3
            }
            [[ -n "$what" ]] || {
                vps_cmd_error "无法确定 swap 单元来源：$unit"
                return 3
            }
            canonical="$(swap_resolve_source "$what")" || return 3
            if [[ "$source" == /etc/fstab || "$source" == "$SWAP_FSTAB" ]]; then
                [[ "$fragment" == /run/systemd/generator/*.swap || "$fragment" == "$(vps_cmd_system_path /run/systemd/generator)/"*.swap ]] || {
                    vps_cmd_error "自定义 swap 单元：$unit"
                    return 3
                }
                generated[$canonical]=1
            elif [[ -z "$source" && -z "$fragment" ]]; then
                # Kernel aliases may lack SourcePath. Require a canonical
                # fstab-generated sibling, or an ordinary active source.
                aliases[$canonical]="$unit"
            else
                vps_cmd_error "swap 由独立单元管理：$unit"
                return 3
            fi
        done
        for canonical in "${!aliases[@]}"; do
            [[ -n "${generated[$canonical]+set}" ]] && continue
            state=0
            for path in "${SWAP_ACTIVE_PATHS[@]}"; do [[ "$canonical" != "$path" ]] || state=1; done
            ((state == 1)) || {
                vps_cmd_error "无法验证 swap 单元来源：${aliases[$canonical]}"
                return 3
            }
        done
    else
        output="$(rc-update show -v)" || return 3
        while IFS= read -r rest; do
            rest="$(vps_cmd_trim "$rest")"
            unit="${rest%%[[:space:]]*}"
            case "$unit" in *swap* | *zram*) [[ "$unit" == swap ]] || {
                vps_cmd_error "发现 OpenRC swap 管理器：$unit"
                return 3
            } ;; esac
        done <<<"$output"
        path="$(vps_cmd_system_path /etc/init.d/swap)" || return $?
        [[ -f "$path" ]] || {
            vps_cmd_error '未找到 OpenRC 标准 swap 服务'
            return 3
        }
        path="$(vps_cmd_system_path /etc/init.d/localmount)" || return $?
        [[ -f "$path" ]] || {
            vps_cmd_error '未找到 OpenRC 标准 localmount 服务'
            return 3
        }
        vps_cmd_require_no_symlink_components "$SWAP_OPENRC_CONFIG" || return $?
        [[ -d "${SWAP_OPENRC_CONFIG%/*}" && (! -e "$SWAP_OPENRC_CONFIG" || -f "$SWAP_OPENRC_CONFIG") ]] || return 3
        swap_openrc_render set >/dev/null || return $?
    fi
    # Manager processes without a service (including manually started daemons).
    for path in "$(vps_cmd_system_path /proc)"/[0-9]*/comm; do
        [[ -r "$path" ]] || continue
        IFS= read -r unit <"$path" || continue
        case "$unit" in dphys-swapfile | systemd-swap | swapspace | zramswap | zram-config)
            vps_cmd_error "独立 swap 管理器正在运行：$unit"
            return 3
            ;;
        esac
    done
}

swap_options_noauto() {
    local options="$1" option result=''
    local -a parts=()
    IFS=',' read -r -a parts <<<"$options"
    for option in "${parts[@]}"; do
        case "$option" in auto | noauto | x-systemd.* | '') continue ;; esac
        result+="${result:+,}${option}"
    done
    printf '%s' "${result:+${result},}noauto"
}

swap_render_fstab() {
    local new_path="${1:-}" index path kind line encoded options missing_newline=0
    local -A partitions=() emitted=()
    for index in "${!SWAP_OLD_PATHS[@]}"; do
        [[ "${SWAP_OLD_KINDS[$index]}" != partition ]] || partitions[${SWAP_OLD_PATHS[$index]}]=1
    done
    for index in "${!SWAP_FSTAB_LINES[@]}"; do
        line="${SWAP_FSTAB_LINES[$index]}"
        if [[ -n "${SWAP_FSTAB_SOURCE[$index]+set}" ]]; then
            path="${SWAP_FSTAB_CANONICAL[$index]}"
            [[ -n "${partitions[$path]+set}" && -z "${emitted[$path]+set}" ]] || continue
            emitted[$path]=1
            encoded="$(swap_fstab_encode "${SWAP_FSTAB_SOURCE[$index]}")" || return $?
            options="$(swap_options_noauto "${SWAP_FSTAB_OPTIONS[$index]}")"
            printf '%s none swap %s 0 0\n' "$encoded" "$options"
        elif ((index == ${#SWAP_FSTAB_LINES[@]} - 1 && SWAP_FSTAB_FINAL_NEWLINE == 0)); then
            printf '%s' "$line"
            missing_newline=1
        else
            printf '%s\n' "$line"
        fi
    done
    for path in "${!partitions[@]}"; do
        [[ -z "${emitted[$path]+set}" ]] || continue
        if ((missing_newline)); then
            printf '\n'
            missing_newline=0
        fi
        encoded="$(swap_fstab_encode "$(swap_logical_path "$path")")" || return $?
        printf '%s none swap noauto 0 0\n' "$encoded"
    done
    if [[ -n "$new_path" ]]; then
        ((missing_newline == 0)) || printf '\n'
        encoded="$(swap_fstab_encode "$(swap_logical_path "$new_path")")" || return $?
        printf '%s none swap sw 0 0 %s\n' "$encoded" "$SWAP_MARKER"
    fi
}

swap_memory_check() {
    local new_bytes="$1" available used=0 index total=0 need
    for index in "${!SWAP_ACTIVE_PATHS[@]}"; do
        ((SWAP_ACTIVE_USED[index] <= 9223372036854775807 - used && SWAP_ACTIVE_SIZES[index] <= 9223372036854775807 - total)) || return 3
        used=$((used + SWAP_ACTIVE_USED[index]))
        total=$((total + SWAP_ACTIVE_SIZES[index]))
    done
    ((new_bytes < total)) || return 0
    need=$((used > new_bytes ? used - new_bytes : 0))
    ((need > 0)) || return 0
    available="$(swap_mem_kib MemAvailable)" || {
        vps_cmd_error '无法读取 MemAvailable，拒绝迁移'
        return 3
    }
    available=$((available * 1024))
    ((need <= available)) || {
        vps_cmd_error "内存不足以缩小/停用 swap（已用 ${used} 字节；可用内存 ${available} 字节）"
        return 3
    }
}

swap_disk_check() {
    local bytes="$1" path="$SWAP_DIRECTORY" filesystem available output field
    local -a fields=()
    vps_cmd_require_no_symlink_components "$SWAP_DIRECTORY" || return $?
    while [[ ! -e "$path" ]]; do
        path="${path%/*}"
        [[ -n "$path" ]] || path=/
    done
    [[ -d "$path" ]] || return 3
    filesystem="$(findmnt -n -o FSTYPE --target "$path")" || return 3
    case "$filesystem" in ext2 | ext3 | ext4 | xfs) ;; *)
        vps_cmd_error "不支持创建 swap 的文件系统：$filesystem"
        return 3
        ;;
    esac
    output="$(LC_ALL=C df -Pk -- "$path")" || return 3
    field="${output##*$'\n'}"
    IFS=$' \t' read -r -a fields <<<"$field"
    available="$(swap_decimal "${fields[3]:-}" 9007199254740991)" || return 3
    available=$((available * 1024))
    ((available >= bytes + SWAP_RESERVE_BYTES)) || {
        vps_cmd_error "磁盘空间不足：新文件需 ${bytes} 字节，旧文件保留期间另需 256 MiB；当前可用 ${available} 字节"
        return 3
    }
}

swap_owned_unchanged() {
    local bytes="$1" path index count=0 size mode owner expected
    ((${#SWAP_ACTIVE_PATHS[@]} == 1)) || return 1
    path="${SWAP_ACTIVE_PATHS[0]}"
    [[ "$path" == "$SWAP_DIRECTORY/"swap.* && "${SWAP_ACTIVE_TYPES[0]}" == file ]] || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    size="$(stat -c %s -- "$path")" || return 1
    mode="$(stat -c %a -- "$path")" || return 1
    owner="$(stat -c %u -- "$path")" || return 1
    [[ "$size" == "$bytes" && "$mode" == 600 && "$owner" == 0 ]] || return 1
    # swapon reports usable bytes, excluding its header page.
    ((SWAP_ACTIVE_SIZES[0] < bytes && SWAP_ACTIVE_SIZES[0] >= bytes - 65536)) || return 1
    expected="$(swap_fstab_encode "$(swap_logical_path "$path")") none swap sw 0 0 $SWAP_MARKER"
    for index in "${!SWAP_FSTAB_SOURCE[@]}"; do
        if [[ "${SWAP_FSTAB_CANONICAL[$index]}" == "$path" && "${SWAP_FSTAB_LINES[$index]}" == "$expected" ]]; then
            count=$((count + 1))
        elif [[ ",${SWAP_FSTAB_OPTIONS[$index]}," != *,noauto,* ]]; then
            return 1
        fi
    done
    ((count == 1)) || return 1
    for index in "${!SWAP_OLD_PATHS[@]}"; do
        [[ "${SWAP_OLD_KINDS[$index]}" != file || "${SWAP_OLD_PATHS[$index]}" == "$path" ]] || return 1
    done
    swap_verify_boot "$path"
}

swap_target_available() {
    local properties
    properties="$(systemctl show swap.target -p LoadState -p UnitFileState)" || return 3
    properties=$'\n'"$properties"$'\n'
    [[ "$properties" == *$'\nLoadState=loaded\n'* && "$properties" != *$'\nUnitFileState=masked'* ]] || {
        vps_cmd_error 'systemd swap.target 不可用或已被屏蔽'
        return 3
    }
}

# OpenRC's standard swap service runs before localmount by default. Its
# shipped conf.d/swap documents these overrides for local swap files.
# Do not source administrator shell configuration while rendering it.
swap_openrc_render() {
    local operation="$1" line inside=0 block_seen=0 missing_newline=0 index
    local begin='# BEGIN vpsctl system swap local files'
    local end='# END vpsctl system swap local files'
    local -a lines=()
    [[ "$operation" == set || "$operation" == disable ]] || return 2
    if [[ -e "$SWAP_OPENRC_CONFIG" ]]; then
        [[ -f "$SWAP_OPENRC_CONFIG" && -r "$SWAP_OPENRC_CONFIG" ]] || return 3
        while IFS= read -r line || [[ -n "$line" ]]; do lines+=("$line"); done <"$SWAP_OPENRC_CONFIG"
        if [[ -s "$SWAP_OPENRC_CONFIG" && "$(vps_cmd_trim "$(tail -c 1 -- "$SWAP_OPENRC_CONFIG" | od -An -tu1)")" != 10 ]]; then missing_newline=1; fi
    fi
    for index in "${!lines[@]}"; do
        line="${lines[$index]}"
        if [[ "$line" == "$begin" ]]; then
            ((inside == 0 && block_seen == 0)) || {
                vps_cmd_error 'OpenRC swap 配置中的受管理标记重复或不完整'
                return 3
            }
            inside=1
            block_seen=1
        elif [[ "$line" == "$end" ]]; then
            ((inside == 1)) || {
                vps_cmd_error 'OpenRC swap 配置中的受管理标记不完整'
                return 3
            }
            inside=0
        elif ((inside == 0)); then
            if ((index == ${#lines[@]} - 1 && missing_newline == 1)); then
                printf '%s' "$line"
                [[ "$operation" != set ]] || printf '\n'
            else
                printf '%s\n' "$line"
            fi
        fi
    done
    ((inside == 0)) || {
        vps_cmd_error 'OpenRC swap 配置中的受管理标记不完整'
        return 3
    }
    if [[ "$operation" == set ]]; then
        # Expand prior settings only when OpenRC reads this configuration.
        # shellcheck disable=SC2016
        printf '%s\n' "$begin" 'rc_before="${rc_before:-} !localmount"' 'rc_need="${rc_need:-} localmount"' "$end"
    fi
}

swap_openrc_config_matches() {
    local operation="$1" expected actual=''
    expected="$(swap_openrc_render "$operation")" || return $?
    if [[ -e "$SWAP_OPENRC_CONFIG" ]]; then actual="$(cat -- "$SWAP_OPENRC_CONFIG")" || return 3; fi
    [[ "$actual" == "$expected" ]]
}

swap_openrc_commit_config() {
    local operation="$1" mode=644 owner=0 group=0
    if ((SWAP_OPENRC_EXISTED)); then
        cmp -s -- "$SWAP_OPENRC_CONFIG" "$SWAP_BACKUP/openrc-swap" || {
            vps_cmd_error 'OpenRC swap 配置在操作期间发生变化'
            return 3
        }
        mode="$(stat -c %a -- "$SWAP_OPENRC_CONFIG")" || return 20
        owner="$(stat -c %u -- "$SWAP_OPENRC_CONFIG")" || return 20
        group="$(stat -c %g -- "$SWAP_OPENRC_CONFIG")" || return 20
    else
        [[ ! -e "$SWAP_OPENRC_CONFIG" && ! -L "$SWAP_OPENRC_CONFIG" ]] || return 3
        [[ "$operation" != disable ]] || return 0
    fi
    swap_openrc_render "$operation" >"$SWAP_BACKUP/openrc-swap.new" || return $?
    if [[ -f "$SWAP_OPENRC_CONFIG" ]] && cmp -s -- "$SWAP_OPENRC_CONFIG" "$SWAP_BACKUP/openrc-swap.new"; then return 0; fi
    SWAP_OPENRC_TOUCHED=1
    vps_cmd_atomic_write /etc/conf.d/swap "$mode" <"$SWAP_BACKUP/openrc-swap.new" || return $?
    chown "$owner:$group" -- "$SWAP_OPENRC_CONFIG" || return 20
    cmp -s -- "$SWAP_OPENRC_CONFIG" "$SWAP_BACKUP/openrc-swap.new" || return 20
}

swap_openrc_restore_config() {
    local mode owner group
    ((SWAP_OPENRC_TOUCHED)) || return 0
    vps_cmd_require_no_symlink_components "$SWAP_OPENRC_CONFIG" || return 30
    if ((SWAP_OPENRC_EXISTED)); then
        if ! cmp -s -- "$SWAP_OPENRC_CONFIG" "$SWAP_BACKUP/openrc-swap.new" && ! cmp -s -- "$SWAP_OPENRC_CONFIG" "$SWAP_BACKUP/openrc-swap"; then
            vps_cmd_error "OpenRC swap 配置被外部修改；原配置：$SWAP_BACKUP/openrc-swap"
            return 30
        fi
        mode="$(stat -c %a -- "$SWAP_BACKUP/openrc-swap")" || return 30
        owner="$(stat -c %u -- "$SWAP_BACKUP/openrc-swap")" || return 30
        group="$(stat -c %g -- "$SWAP_BACKUP/openrc-swap")" || return 30
        vps_cmd_atomic_write /etc/conf.d/swap "$mode" <"$SWAP_BACKUP/openrc-swap" || return 30
        chown "$owner:$group" -- "$SWAP_OPENRC_CONFIG" || return 30
        cmp -s -- "$SWAP_OPENRC_CONFIG" "$SWAP_BACKUP/openrc-swap" || return 30
    elif [[ -e "$SWAP_OPENRC_CONFIG" ]]; then
        cmp -s -- "$SWAP_OPENRC_CONFIG" "$SWAP_BACKUP/openrc-swap.new" || return 30
        rm -- "$SWAP_OPENRC_CONFIG" || return 30
    fi
}

swap_verify_boot() {
    local path="${1:-}" unit props key value what='' source='' fragment='' drops='' boot linked=0 resolved
    if [[ "$SWAP_INIT" == systemd && -n "$path" ]]; then
        swap_target_available || return $?
        unit="$(systemd-escape --path --suffix=swap "$(swap_logical_path "$path")")" || return 3
        props="$(systemctl show "$unit" -p What -p SourcePath -p FragmentPath -p DropInPaths)" || return 3
        while IFS='=' read -r key value; do
            case "$key" in What) what="$value" ;; SourcePath) source="$value" ;; FragmentPath) fragment="$value" ;; DropInPaths) drops="$value" ;; esac
        done <<<"$props"
        [[ "$source" == /etc/fstab || "$source" == "$SWAP_FSTAB" ]] || return 3
        [[ "$fragment" == /run/systemd/generator/*.swap || "$fragment" == "$(vps_cmd_system_path /run/systemd/generator)/"*.swap ]] || return 3
        [[ -z "$drops" && "$(swap_resolve_source "$what")" == "$path" ]] || return 3
        if [[ "${VPSCTL_TESTING:-0}" == 1 && "$fragment" != "$VPSCTL_SYSTEM_ROOT/"* ]]; then fragment="$(vps_cmd_system_path "$fragment")" || return $?; fi
        for boot in "${fragment%/*}/swap.target.requires/$unit" "${fragment%/*}/swap.target.wants/$unit"; do
            [[ -L "$boot" && -e "$boot" ]] || continue
            resolved="$(readlink -f -- "$boot")" || continue
            [[ "$resolved" != "$fragment" ]] || linked=1
        done
        ((linked)) || {
            vps_cmd_error "新 swap 未加入 systemd 启动依赖：$unit"
            return 3
        }
    elif [[ "$SWAP_INIT" == openrc ]]; then
        boot="$(vps_cmd_system_path /etc/runlevels/boot/swap)" || return $?
        [[ -L "$boot" && -e "$boot" ]] || return 3
        [[ "$(readlink -f -- "$boot")" == "$(vps_cmd_system_path /etc/init.d/swap)" ]] || return 3
        if [[ -n "$path" ]]; then
            swap_openrc_config_matches set || return 3
        else swap_openrc_config_matches disable || return 3; fi
    elif [[ "$SWAP_INIT" == systemd ]]; then
        swap_target_available || return $?
    fi
}

swap_status() {
    local output total available size init boot='未知'
    swap_ensure_tools status || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
    total="$(swap_mem_kib MemTotal)" || return 3
    available="$(swap_mem_kib MemAvailable)" || available=0
    size="$(swap_size_bytes auto "$total")" || return $?
    vps_cmd_status 内存 "$((total / 1024)) MiB；可用 $((available / 1024)) MiB" normal
    vps_cmd_status 自动大小 "$((size / 1073741824)) GiB" normal
    if swap_detect_init 2>/dev/null; then
        init="$SWAP_INIT"
        if [[ "$init" == systemd ]] && command -v systemctl >/dev/null 2>&1; then
            output="$(systemctl show swap.target -p LoadState -p ActiveState --no-pager 2>/dev/null)" || output=''
            if [[ "$output" == *LoadState=loaded* ]]; then
                boot='由 fstab / swap.target 管理'
            else boot='swap.target 不可用'; fi
        elif [[ "$init" == openrc ]]; then
            output="$(vps_cmd_system_path /etc/runlevels/boot/swap)" || return $?
            if [[ -e "$output" || -L "$output" ]]; then
                boot='标准 swap 服务已加入 boot'
            else boot='标准 swap 服务未加入 boot'; fi
        fi
    else init='未识别'; fi
    vps_cmd_status 启动管理 "$init；$boot" normal
    output="$(LC_ALL=C swapon --show=NAME,TYPE,SIZE,USED,PRIO --bytes --raw --noheadings)" || return 20
    vps_cmd_status 活动swap "${output:-无}（列：路径 类型 大小/字节 已用/字节 优先级）" normal
    if [[ -r "$SWAP_FSTAB" ]]; then
        local line
        local -a fields=()
        while IFS= read -r line || [[ -n "$line" ]]; do
            IFS=$' \t' read -r -a fields <<<"$line"
            [[ "${fields[0]:-}" != \#* && "${fields[2]:-}" == swap ]] || continue
            vps_cmd_status fstab "$line" normal
        done <"$SWAP_FSTAB"
    else
        vps_cmd_warning '无法读取 /etc/fstab'
    fi
}

swap_snapshot() {
    local stamp
    vps_cmd_require_no_symlink_components "$SWAP_BACKUP_ROOT" || return $?
    install -d -m 0700 -- "$SWAP_BACKUP_ROOT" || return 20
    stamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 20
    SWAP_BACKUP="$(mktemp -d "$SWAP_BACKUP_ROOT/$stamp.XXXXXX")" || return 20
    cp -p -- "$SWAP_FSTAB" "$SWAP_BACKUP/fstab" || return 20
    printf '%s\n' "$SWAP_ORIGINAL_RAW" >"$SWAP_BACKUP/active-swap" || return 20
    printf '%s\n' "${SWAP_OLD_PATHS[@]}" >"$SWAP_BACKUP/sources" || return 20
    printf '%s\n' "${SWAP_OLD_IDENTITIES[@]}" >"$SWAP_BACKUP/identities" || return 20
    if [[ "$SWAP_INIT" == openrc ]]; then
        SWAP_BOOT_PATH="$(vps_cmd_system_path /etc/runlevels/boot/swap)" || return $?
        if [[ -e "$SWAP_BOOT_PATH" || -L "$SWAP_BOOT_PATH" ]]; then SWAP_BOOT_BEFORE=1; else SWAP_BOOT_BEFORE=0; fi
        if [[ -e "$SWAP_OPENRC_CONFIG" ]]; then
            SWAP_OPENRC_EXISTED=1
            cp -p -- "$SWAP_OPENRC_CONFIG" "$SWAP_BACKUP/openrc-swap" || return 20
        else
            : >"$SWAP_BACKUP/openrc-swap.missing" || return 20
        fi
    fi
    printf 'init=%s\nopenrc_swap_boot=%s\nopenrc_swap_config_existed=%s\n' "$SWAP_INIT" "$SWAP_BOOT_BEFORE" "$SWAP_OPENRC_EXISTED" >"$SWAP_BACKUP/boot-state" || return 20
    vps_cmd_info "配置与活动清单备份：$SWAP_BACKUP"
}

swap_create_file() {
    local bytes="$1"
    vps_cmd_require_no_symlink_components "$SWAP_DIRECTORY" || return $?
    install -d -m 0700 -- "$SWAP_DIRECTORY" || return 20
    SWAP_NEW_FILE="$(mktemp "$SWAP_DIRECTORY/swap.XXXXXXXXXX")" || return 20
    SWAP_NEW_INODE="$(stat -c '%d:%i' -- "$SWAP_NEW_FILE")" || return 20
    # This is its permanent name. Renaming an active swap file is unsafe.
    chmod 0600 -- "$SWAP_NEW_FILE" || return 20
    chown 0:0 -- "$SWAP_NEW_FILE" || return 20
    dd if=/dev/zero "of=$SWAP_NEW_FILE" bs=1M "count=$((bytes / 1048576))" conv=fsync || return 20
    [[ "$(stat -c %s -- "$SWAP_NEW_FILE")" == "$bytes" ]] || return 20
    mkswap -- "$SWAP_NEW_FILE" || return 20
    SWAP_NEW_IDENTITY="$(swap_file_identity "$SWAP_NEW_FILE")" || return $?
    swapon -- "$SWAP_NEW_FILE" || return 20
    swap_active_load || return $?
    swap_is_active "$SWAP_NEW_FILE" || {
        vps_cmd_error '新 swap 未成功激活'
        return 20
    }
}

swap_is_active() {
    local wanted="$1" path
    for path in "${SWAP_ACTIVE_PATHS[@]}"; do [[ "$path" != "$wanted" ]] || return 0; done
    return 1
}

swap_before_swapoff() {
    local path="$1" available index need=0 free capacity
    swap_active_load || return $?
    free=0
    for index in "${!SWAP_ACTIVE_PATHS[@]}"; do
        if [[ "${SWAP_ACTIVE_PATHS[$index]}" == "$path" ]]; then
            need="${SWAP_ACTIVE_USED[$index]}"
        else
            capacity=$((SWAP_ACTIVE_SIZES[index] - SWAP_ACTIVE_USED[index]))
            ((capacity <= 9223372036854775807 - free)) || return 3
            free=$((free + capacity))
        fi
    done
    ((need > free)) || return 0
    available="$(swap_mem_kib MemAvailable)" || return 3
    available=$((available * 1024))
    ((need - free <= available)) || {
        vps_cmd_error "迁移内存不足，无法停用：$path"
        return 3
    }
}

swap_stop_old() {
    local path
    for path in "${SWAP_ORIGINAL_PATHS[@]}"; do
        swap_before_swapoff "$path" || return $?
        swapon_identity_check "$path" || return $?
        swapoff -- "$path" || return 20
        swap_active_load || return $?
        if swap_is_active "$path"; then
            vps_cmd_error "swap 仍在使用：$path"
            return 20
        fi
    done
}

swapon_identity_check() {
    local path="$1" index identity
    for index in "${!SWAP_OLD_PATHS[@]}"; do
        [[ "${SWAP_OLD_PATHS[$index]}" == "$path" ]] || continue
        if [[ "${SWAP_OLD_KINDS[$index]}" == file ]]; then
            identity="$(swap_file_identity "$path")" || return 3
        else
            [[ -b "$path" ]] || return 3
            identity="$(stat -c '%t:%T' -- "$path")" || return 3
        fi
        [[ "$identity" == "${SWAP_OLD_IDENTITIES[$index]}" ]] || {
            vps_cmd_error "swap 来源身份已改变：$path"
            return 3
        }
        return 0
    done
    return 3
}

swap_commit_config() {
    local owner group mode
    cmp -s -- "$SWAP_FSTAB" "$SWAP_BACKUP/fstab" || {
        vps_cmd_error 'fstab 在操作期间发生变化'
        return 3
    }
    swap_render_fstab "$SWAP_NEW_FILE" >"$SWAP_BACKUP/fstab.new" || return $?
    owner="$(stat -c %u -- "$SWAP_FSTAB")" || return 20
    group="$(stat -c %g -- "$SWAP_FSTAB")" || return 20
    mode="$(stat -c %a -- "$SWAP_FSTAB")" || return 20
    SWAP_CONFIG_TOUCHED=1
    vps_cmd_atomic_write /etc/fstab "$mode" <"$SWAP_BACKUP/fstab.new" || return $?
    chown "$owner:$group" -- "$SWAP_FSTAB" || return 20
    cmp -s -- "$SWAP_FSTAB" "$SWAP_BACKUP/fstab.new" || return 20
    case "$SWAP_INIT" in
        systemd) systemctl daemon-reload || return 20 ;;
        openrc)
            if [[ -n "$SWAP_NEW_FILE" ]]; then
                swap_openrc_commit_config set || return $?
            else swap_openrc_commit_config disable || return $?; fi
            if [[ "$SWAP_BOOT_BEFORE" == 0 ]]; then
                SWAP_BOOT_TOUCHED=1
                rc-update add swap boot || return 20
            fi
            rc-update -u || return 20
            ;;
    esac
    swap_verify_boot "$SWAP_NEW_FILE" || {
        vps_cmd_error 'swap 启动配置验证失败'
        return 20
    }
    swap_active_load || return $?
    if [[ -n "$SWAP_NEW_FILE" ]]; then
        ((${#SWAP_ACTIVE_PATHS[@]} == 1)) && [[ "${SWAP_ACTIVE_PATHS[0]}" == "$SWAP_NEW_FILE" ]] || return 20
    else
        ((${#SWAP_ACTIVE_PATHS[@]} == 0)) || return 20
    fi
    SWAP_COMMITTED=1
}

swap_remove_old_files() {
    local index path signature failed=0
    for index in "${!SWAP_OLD_PATHS[@]}"; do
        [[ "${SWAP_OLD_KINDS[$index]}" == file ]] || continue
        path="${SWAP_OLD_PATHS[$index]}"
        if ! swap_active_load || swap_is_active "$path" || ! swapon_identity_check "$path"; then
            vps_cmd_error "保留旧 swap 文件（状态或身份无法确认）：$path"
            failed=1
            continue
        fi
        signature="$(blkid -p -s TYPE -o value -- "$path")" || signature=''
        if [[ "$signature" != swap ]] || ! rm -- "$path"; then
            vps_cmd_error "未能清理旧 swap 文件：$path"
            failed=1
        fi
    done
    ((failed == 0)) || return 30
}

swap_restore_config() {
    local mode owner group
    ((SWAP_CONFIG_TOUCHED)) || return 0
    # Do not overwrite another administrator's later edit.
    if ! cmp -s -- "$SWAP_FSTAB" "$SWAP_BACKUP/fstab.new" && ! cmp -s -- "$SWAP_FSTAB" "$SWAP_BACKUP/fstab"; then
        vps_cmd_error "fstab 被外部修改，保留现场；原配置：$SWAP_BACKUP/fstab"
        return 30
    fi
    mode="$(stat -c %a -- "$SWAP_BACKUP/fstab")" || return 30
    owner="$(stat -c %u -- "$SWAP_BACKUP/fstab")" || return 30
    group="$(stat -c %g -- "$SWAP_BACKUP/fstab")" || return 30
    vps_cmd_atomic_write /etc/fstab "$mode" <"$SWAP_BACKUP/fstab" || return 30
    chown "$owner:$group" -- "$SWAP_FSTAB" || return 30
    cmp -s -- "$SWAP_FSTAB" "$SWAP_BACKUP/fstab" || return 30
}

swap_rollback() {
    local failed=0 index path priority config_restored=1
    vps_cmd_warning '操作未提交，正在恢复原配置和原 swap 活动状态'
    swap_restore_config || {
        failed=1
        config_restored=0
    }
    if [[ "$SWAP_INIT" == systemd ]] && ((SWAP_CONFIG_TOUCHED)); then systemctl daemon-reload || failed=1; fi
    if [[ "$SWAP_INIT" == openrc ]]; then swap_openrc_restore_config || failed=1; fi
    if ((SWAP_BOOT_TOUCHED)); then rc-update del swap boot || failed=1; fi
    if [[ "$SWAP_INIT" == openrc ]] && ((SWAP_OPENRC_TOUCHED || SWAP_BOOT_TOUCHED)); then rc-update -u || failed=1; fi
    # Restore capacity before trying to remove the replacement.
    if swap_active_load; then
        for index in "${!SWAP_ORIGINAL_PATHS[@]}"; do
            path="${SWAP_ORIGINAL_PATHS[$index]}"
            swap_is_active "$path" && continue
            if ! swapon_identity_check "$path"; then
                failed=1
                continue
            fi
            priority="${SWAP_ORIGINAL_PRIORITIES[$index]}"
            if ((priority >= 0)); then
                swapon --priority "$priority" -- "$path" || failed=1
            else swapon -- "$path" || failed=1; fi
        done
    else
        failed=1
    fi
    # Preserve the new file when it is still needed by an unrestored fstab.
    if [[ -n "$SWAP_NEW_FILE" ]] && ((config_restored)); then
        if swap_active_load; then
            if swap_is_active "$SWAP_NEW_FILE"; then
                if ((failed == 0)) && swap_before_swapoff "$SWAP_NEW_FILE"; then
                    swapoff -- "$SWAP_NEW_FILE" || failed=1
                else failed=1; fi
            fi
            if swap_active_load && ! swap_is_active "$SWAP_NEW_FILE"; then
                if [[ -f "$SWAP_NEW_FILE" && ! -L "$SWAP_NEW_FILE" ]]; then
                    # Failed dd/mkswap has no final signature yet, but mktemp
                    # reserved this exact private path for this transaction.
                    if [[ -n "$SWAP_NEW_INODE" && "$(stat -c '%d:%i' -- "$SWAP_NEW_FILE")" == "$SWAP_NEW_INODE" ]] && vps_cmd_require_no_symlink_components "$SWAP_NEW_FILE" && { [[ -z "$SWAP_NEW_IDENTITY" ]] || [[ "$(swap_file_identity "$SWAP_NEW_FILE")" == "$SWAP_NEW_IDENTITY" ]]; }; then
                        rm -- "$SWAP_NEW_FILE" || failed=1
                    else failed=1; fi
                elif [[ -e "$SWAP_NEW_FILE" || -L "$SWAP_NEW_FILE" ]]; then failed=1; fi
            else failed=1; fi
        else failed=1; fi
    fi
    if swap_active_load; then
        for path in "${SWAP_ORIGINAL_PATHS[@]}"; do swap_is_active "$path" || failed=1; done
        if [[ -n "$SWAP_NEW_FILE" ]] && swap_is_active "$SWAP_NEW_FILE"; then failed=1; fi
    else failed=1; fi
    if ((failed)); then
        vps_cmd_error "回滚未完成；备份：${SWAP_BACKUP:-未创建}；新文件：${SWAP_NEW_FILE:-无}"
        return 30
    fi
    vps_cmd_warning '已恢复原 swap 配置与活动状态'
}

swap_exit() {
    local status="$1"
    trap - EXIT INT TERM HUP
    if ((SWAP_TRANSACTION_STARTED && !SWAP_COMMITTED)); then swap_rollback || status=30; fi
    if ((SWAP_COMMITTED && status != 0)); then
        vps_cmd_error "新 swap 配置已生效，清理未完成；备份：$SWAP_BACKUP"
        local index path
        for index in "${!SWAP_OLD_PATHS[@]}"; do
            [[ "${SWAP_OLD_KINDS[$index]}" == file ]] || continue
            path="${SWAP_OLD_PATHS[$index]}"
            [[ ! -e "$path" && ! -L "$path" ]] || vps_cmd_error "待检查的旧 swap 文件：$path"
        done
        status=30
    fi
    vps_cmd_unlock
    exit "$status"
}

swap_mutate() (
    local action="$1" size="${2:-auto}" bytes=0 path before_hash current_hash confirm_status
    local SWAP_BACKUP='' SWAP_NEW_FILE='' SWAP_NEW_IDENTITY='' SWAP_NEW_INODE='' SWAP_BOOT_PATH='' SWAP_BOOT_BEFORE=0
    local SWAP_OPENRC_EXISTED=0 SWAP_OPENRC_TOUCHED=0
    local SWAP_TRANSACTION_STARTED=0 SWAP_COMMITTED=0 SWAP_CONFIG_TOUCHED=0 SWAP_BOOT_TOUCHED=0
    umask 077
    [[ "$action" == set || "$action" == disable ]] || return 2
    if [[ "$action" == set ]]; then bytes="$(swap_size_bytes "$size")" || {
        vps_cmd_error '大小必须为 auto 或至少 64M 的整数 M/G；不得超出整数范围'
        return 2
    }; fi
    vps_cmd_require_root || return $?
    swap_ensure_tools "$action" || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info '依赖安装计划已生成；安装依赖后重新运行以检查 swap 迁移条件'
        return 0
    fi
    trap 'swap_exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    vps_cmd_lock system-swap || return $?
    vps_cmd_require_no_symlink_components "$SWAP_FSTAB" || return $?
    before_hash="$(sha256sum -- "$SWAP_FSTAB")" || return 20
    before_hash="${before_hash%% *}"
    swap_inventory_load || return $?
    swap_check_managers || return $?
    if [[ "$action" == set ]] && swap_owned_unchanged "$bytes"; then
        vps_cmd_success "已存在相同大小且有效的受管理 swap：${SWAP_ACTIVE_PATHS[0]}"
        return 0
    fi
    swap_memory_check "$bytes" || return $?
    [[ "$action" != set ]] || swap_disk_check "$bytes" || return $?
    current_hash="$(sha256sum -- "$SWAP_FSTAB")" || return 20
    [[ "${current_hash%% *}" == "$before_hash" ]] || {
        vps_cmd_error 'fstab 在读取期间发生变化，请重试'
        return 3
    }
    vps_cmd_info "计划：${action}；目标 $((bytes / 1048576)) MiB；旧文件仅在启动配置与活动状态验证成功后删除"
    for path in "${SWAP_OLD_PATHS[@]}"; do vps_cmd_info "原 swap：$path"; done
    vps_cmd_confirm '确认迁移/停用这些 swap，并在成功后删除旧普通 swap 文件（分区保留）？' || {
        confirm_status=$?
        ((confirm_status != 1)) || confirm_status=130
        return "$confirm_status"
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info '演练完成：将备份 fstab 与活动清单，先启用新文件，再逐项停用旧 swap，提交启动配置，最后删除已验证的旧文件'
        return 0
    fi
    current_hash="$(sha256sum -- "$SWAP_FSTAB")" || return 20
    [[ "${current_hash%% *}" == "$before_hash" ]] || {
        vps_cmd_error 'fstab 在确认期间发生变化，请重试'
        return 3
    }
    # Refresh memory use while keeping the original identity and boot snapshot.
    swap_active_load || return $?
    [[ "${SWAP_ACTIVE_PATHS[*]}" == "${SWAP_ORIGINAL_PATHS[*]}" && "${SWAP_ACTIVE_SIZES[*]}" == "${SWAP_ORIGINAL_SIZES[*]}" && "${SWAP_ACTIVE_PRIORITIES[*]}" == "${SWAP_ORIGINAL_PRIORITIES[*]}" ]] || {
        vps_cmd_error '活动 swap 在确认期间发生变化，请重试'
        return 3
    }
    swap_check_managers || return $?
    swap_memory_check "$bytes" || return $?
    for path in "${SWAP_OLD_PATHS[@]}"; do swapon_identity_check "$path" || return $?; done
    swap_snapshot || return $?
    current_hash="$(sha256sum -- "$SWAP_BACKUP/fstab")" || return 20
    [[ "${current_hash%% *}" == "$before_hash" ]] || {
        vps_cmd_error 'fstab 在备份期间发生变化，请重试'
        return 3
    }
    SWAP_TRANSACTION_STARTED=1
    if [[ "$action" == set ]]; then
        swap_disk_check "$bytes" || return $?
        swap_create_file "$bytes" || return $?
    fi
    swap_stop_old || return $?
    swap_commit_config || return $?
    swap_remove_old_files || return 30
    vps_cmd_success "swap ${action} 已完成；配置备份：$SWAP_BACKUP"
)

swap_prompt_size() {
    local recommended size
    recommended="$(swap_size_bytes auto)" || return $?
    recommended="$((recommended / 1073741824))G"
    while true; do
        size="$(vps_cmd_prompt_value 'swap 大小（推荐值如下；可输入 auto 或整数 M/G）' "$recommended")" || return $?
        if swap_size_bytes "$size" >/dev/null; then
            printf '%s' "$size"
            return 0
        fi
        vps_cmd_warning '大小必须为 auto 或至少 64M 的整数 M/G；请重新输入'
    done
}

swap_menu() {
    local choice size status
    while true; do
        choice="$(vps_cmd_prompt_select '系统 swap' status status '查看状态' set '设置 swap 大小' disable '停用 swap' quit '退出')" || {
            status=$?
            ((status == 130)) && return 0
            return "$status"
        }
        case "$choice" in
            status) swap_status || return $? ;;
            set)
                size="$(swap_prompt_size)" || return $?
                swap_mutate set "$size" || return $?
                ;;
            disable) swap_mutate disable || return $? ;;
            quit) return 0 ;;
        esac
    done
}

swap_require_linux() {
    [[ "${VPSCTL_TESTING:-0}" == 1 || "$(uname -s 2>/dev/null || true)" == Linux ]] && return 0
    vps_cmd_error 'system swap 仅支持 Linux'
    return 3
}

swap_main() {
    vps_cmd_init system-swap "$SWAP_PROJECT_ROOT" || return $?
    swap_init_paths || return $?
    swap_parse_args "$@" || {
        swap_usage >&2
        return 2
    }
    if [[ "$SWAP_ACTION" == help ]]; then
        swap_usage
        return 0
    fi
    swap_require_linux || return $?
    case "$SWAP_ACTION" in
        status) swap_status ;;
        set) swap_mutate set "$SWAP_SIZE" ;;
        disable) swap_mutate disable ;;
        '') if vps_cmd_is_interactive; then swap_menu; else swap_status; fi ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    swap_main "$@"
fi
