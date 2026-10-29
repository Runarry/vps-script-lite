#!/usr/bin/env bash
# Conservative, explicit cache cleanup; no service or package removal.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034
# Preview intentionally changes dry-run only in a subshell; cleanup APIs take no arguments.
# shellcheck disable=SC2030,SC2031,SC2119
set -Eeuo pipefail
IFS=$'\n\t'

CLEAN_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/command.sh
source "$CLEAN_PROJECT_ROOT/lib/command.sh"

CLEAN_ACTION=''
CLEAN_PACKAGE_MANAGER=''
CLEAN_UNAVAILABLE=''
declare -a CLEAN_NATIVE_COMMAND=()

clean_usage() {
    cat <<'EOF'
用法：vpsctl system clean [status | safe | vpsctl | bundles | packages | temp | journal | help]

  status    查看清理范围、缓存占用和可用项目（默认非交互动作）
  safe      推荐清理：vpsctl 废弃残留、软件包下载缓存、过期临时文件
  vpsctl    清理受管历史版本、废弃入口副本和已知下载临时文件
  bundles   单独清空功能包；保留 core、共享库和清理功能，下次使用需下载
  packages  使用包管理器清理下载缓存；不卸载软件或旧内核
  temp      按现有 tmpfiles 规则清理 /tmp、/var/tmp，排除 vpsctl 专属目录
  journal   单独清理 30 天前的归档 journal；不强制轮转当前日志

无参数时，交互终端打开菜单，其他场景显示 status。
实际清理需要 root，确认一次；--yes 可预先授权。safe 不清空功能包或日志。
vpsctl/bundles 仅操作当前受管安装，源码模式的 safe 会跳过 vpsctl 项。
保留配置、状态、备份、证书、Swap、服务程序和更新恢复材料。
清理缓存后可能需要重新下载；删除的缓存和归档日志不提供内容回滚。
支持：--dry-run --yes --non-interactive --install-deps --quiet --verbose --no-color
演练仅展示计划，不创建锁或执行清理；预计释放空间可能无法准确计算。
退出码：0 成功/无需清理，2 参数错误，3 不支持/被占用，4 权限不足，
        20 外部命令失败，30 部分完成，130 取消或中断。
EOF
}

clean_parse_args() {
    local positional=0
    CLEAN_ACTION=''
    while (($#)); do
        if ((positional == 0)); then
            case "$1" in
                --dry-run)
                    VPSCTL_DRY_RUN=1
                    shift
                    continue
                    ;;
                --yes)
                    VPSCTL_ASSUME_YES=1
                    shift
                    continue
                    ;;
                --non-interactive)
                    VPSCTL_NON_INTERACTIVE=1
                    shift
                    continue
                    ;;
                --install-deps)
                    VPSCTL_INSTALL_DEPS=1
                    shift
                    continue
                    ;;
                --quiet)
                    VPSCTL_QUIET=1
                    shift
                    continue
                    ;;
                --verbose)
                    VPSCTL_VERBOSE=1
                    shift
                    continue
                    ;;
                --no-color)
                    VPSCTL_NO_COLOR=1
                    shift
                    continue
                    ;;
                -h | --help)
                    [[ -z "$CLEAN_ACTION" ]] || return 2
                    CLEAN_ACTION=help
                    shift
                    continue
                    ;;
                --)
                    positional=1
                    shift
                    continue
                    ;;
            esac
        fi
        [[ -z "$CLEAN_ACTION" ]] || return 2
        case "$1" in
            status | safe | vpsctl | bundles | packages | temp | journal | help) CLEAN_ACTION="$1" ;;
            *)
                vps_cmd_error "未知清理动作或参数：$1"
                return 2
                ;;
        esac
        shift
    done
}

clean_label() {
    case "$1" in
        vpsctl) printf 'vpsctl 废弃残留' ;;
        bundles) printf '功能包缓存（下次使用需下载）' ;;
        packages) printf '软件包下载缓存' ;;
        temp) printf '过期临时文件（遵循系统规则）' ;;
        journal) printf '30 天前的归档 journal' ;;
    esac
}

clean_load_distribution() {
    # Kept in core; loading the library does not download other features.
    # shellcheck source=../../lib/distribution.sh
    source "$CLEAN_PROJECT_ROOT/lib/distribution.sh"
}

clean_package_command() {
    CLEAN_NATIVE_COMMAND=()
    CLEAN_PACKAGE_MANAGER="$(vps_cmd_detect_package_manager)" || return $?
    case "$CLEAN_PACKAGE_MANAGER" in
        apt-get) CLEAN_NATIVE_COMMAND=(apt-get clean) ;;
        dnf5 | dnf | yum) CLEAN_NATIVE_COMMAND=("$CLEAN_PACKAGE_MANAGER" clean packages) ;;
        apk) CLEAN_NATIVE_COMMAND=(apk --no-network cache clean) ;;
        pacman) CLEAN_NATIVE_COMMAND=(pacman --noconfirm -Sc) ;;
        zypper) CLEAN_NATIVE_COMMAND=(zypper --non-interactive clean) ;;
        *) return 3 ;;
    esac
}

clean_supported() {
    local help
    CLEAN_UNAVAILABLE=''
    case "$1" in
        vpsctl | bundles)
            if [[ "${VPSCTL_DISTRIBUTED:-0}" != 1 ]]; then
                CLEAN_UNAVAILABLE='源码模式不操作安装缓存'
            fi
            ;;
        packages)
            if ! clean_package_command; then CLEAN_UNAVAILABLE='没有可用的受支持包管理器'; fi
            ;;
        temp)
            if ! command -v systemd-tmpfiles >/dev/null 2>&1; then
                CLEAN_UNAVAILABLE='未安装 systemd-tmpfiles'
            elif ! help="$(systemd-tmpfiles --help 2>&1)" || [[ "$help" != *--prefix* || "$help" != *--cat-config* ]] || ! command -v awk >/dev/null 2>&1; then
                CLEAN_UNAVAILABLE='systemd-tmpfiles 缺少路径限制、配置读取能力或 awk'
            fi
            ;;
        journal)
            if ! command -v journalctl >/dev/null 2>&1; then CLEAN_UNAVAILABLE='未安装 journalctl'; fi
            ;;
    esac
    [[ -z "$CLEAN_UNAVAILABLE" ]]
}

clean_print_command() {
    printf '  命令：'
    printf '%q ' "$@"
    printf '\n'
}

clean_tmpfiles_command() {
    # Explicit stdin is the entire effective configuration, not an extra file:
    # an x rule alone does not override a separate d/e cleanup rule below it.
    CLEAN_NATIVE_COMMAND=(systemd-tmpfiles --clean --prefix=/tmp --prefix=/var/tmp -)
}

clean_tmpfiles_exclusions() {
    local config
    if ! config="$(systemd-tmpfiles --cat-config --no-pager)"; then
        vps_cmd_error '无法读取有效 tmpfiles 配置，未执行临时文件清理'
        return 20
    fi
    # Parse only type/path; leave all other fields and ordering with tmpfiles.
    # A replaced rule remains an x boundary, so a parent with a shorter age
    # cannot start cleaning the rule's matches. Ambiguous glob/specifier/escape
    # paths are retained conservatively instead of trying to expand them here.
    awk '
        function invalid() {
            print "vpsctl：无法安全解析 tmpfiles 路径（第 " NR " 行），未执行清理" > "/dev/stderr"
            exit 3
        }
        function field(    start, quote, c, result) {
            while (substr($0, pos, 1) ~ /[ \t]/) pos++
            start = pos
            quote = substr($0, pos, 1)
            if (quote == "\"" || quote == "\047") pos++
            else quote = ""
            result = ""
            while (pos <= length($0)) {
                c = substr($0, pos++, 1)
                if (c == "\\") {
                    if (pos > length($0)) invalid()
                    result = result c substr($0, pos++, 1)
                } else if (quote != "" && c == quote) {
                    if (pos <= length($0) && substr($0, pos, 1) !~ /[ \t]/) invalid()
                    raw = substr($0, start, pos - start)
                    return result
                } else if (quote == "" && c ~ /[ \t]/) {
                    pos--
                    raw = substr($0, start, pos - start)
                    return result
                } else if (quote == "" && (c == "\"" || c == "\047")) invalid()
                else result = result c
            }
            if (quote != "") invalid()
            raw = substr($0, start, pos - start)
            return result
        }
        /^[ \t]*(#|$)/ { print; next }
        {
            pos = 1
            type = field()
            if (type ~ /\\/) invalid()
            if (type !~ /^[dDevqQCrRxX]/) { print; next }
            path = field()
            if (path == "") invalid()
            rawpath = raw
            ambiguous = path ~ /[%\\]/ || path ~ /\/\// || path ~ /(^|\/)\.\.?($|\/)/
            sub(/\/$/, "", path)
            if (!ambiguous && (path == "/tmp" || path == "/var/tmp")) { print; next }
            prefix = path
            for (i = 1; i <= length(prefix); i++) {
                c = substr(prefix, i, 1)
                if (c == "*" || c == "?" || c == "[") { prefix = substr(prefix, 1, i - 1); break }
            }
            if (ambiguous || index("/tmp/vpsctl", prefix) == 1 || index(prefix, "/tmp/vpsctl") == 1 ||
                index("/var/tmp/vpsctl", prefix) == 1 || index(prefix, "/var/tmp/vpsctl") == 1) {
                print "x " rawpath " - - - -"
            } else print
        }
        END {
            print "x /tmp/vpsctl* - - - -"
            print "x /var/tmp/vpsctl* - - - -"
        }
    ' <<<"$config"
}

clean_preview_one() {
    printf '\n%s\n' "$(clean_label "$1")"
    case "$1" in
        vpsctl)
            clean_load_distribution
            (
                VPSCTL_DRY_RUN=1
                vps_distribution_clean_residue
            )
            ;;
        bundles)
            clean_load_distribution
            (
                VPSCTL_DRY_RUN=1
                vps_distribution_clean_bundles
            )
            ;;
        packages)
            clean_package_command || return $?
            clean_print_command "${CLEAN_NATIVE_COMMAND[@]}"
            printf '  仅清理下载缓存；后续安装可能需要重新下载。\n'
            ;;
        temp)
            clean_tmpfiles_exclusions >/dev/null || return $?
            clean_tmpfiles_command
            clean_print_command "${CLEAN_NATIVE_COMMAND[@]}"
            printf '  沿用系统过期与排除规则；额外保留 /tmp/vpsctl*、/var/tmp/vpsctl*。\n'
            ;;
        journal)
            clean_print_command journalctl --vacuum-time=30d
            printf '  仅删除归档 journal；保留活动日志，不更改长期保留策略。\n'
            ;;
    esac
}

clean_usage_kib() {
    local path="$1" output
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        printf '0 KiB'
        return 0
    fi
    if ! vps_cmd_require_no_symlink_components "$path" >/dev/null 2>&1; then
        printf '路径异常，未统计'
    elif output="$(du -skx -- "$path" 2>/dev/null)"; then
        printf '%s KiB' "${output%%$'\t'*}"
    else
        printf '无法读取'
    fi
}

clean_status() {
    local item cache_path='' output
    printf '系统清理概览（不执行清理）\n'
    for item in vpsctl bundles packages temp journal; do
        if clean_supported "$item"; then
            printf '  %s：可用\n' "$(clean_label "$item")"
        else
            printf '  %s：跳过（%s）\n' "$(clean_label "$item")" "$CLEAN_UNAVAILABLE"
        fi
    done
    if [[ "${VPSCTL_DISTRIBUTED:-0}" == 1 ]]; then
        printf '  当前分发目录占用：%s（包含保留内容）\n' "$(clean_usage_kib "$CLEAN_PROJECT_ROOT")"
    fi
    if clean_package_command >/dev/null 2>&1; then
        case "$CLEAN_PACKAGE_MANAGER" in
            apt-get) cache_path=/var/cache/apt/archives ;;
            dnf5) cache_path=/var/cache/libdnf5 ;;
            dnf) cache_path=/var/cache/dnf ;;
            yum) cache_path=/var/cache/yum ;;
            apk) cache_path=/var/cache/apk ;;
            pacman) cache_path=/var/cache/pacman/pkg ;;
            zypper) cache_path=/var/cache/zypp/packages ;;
        esac
        printf '  默认包缓存目录占用：%s（含保留内容；自定义缓存路径未计入）\n' \
            "$(clean_usage_kib "$(vps_cmd_system_path "$cache_path")")"
    fi
    if command -v journalctl >/dev/null 2>&1 && output="$(journalctl --disk-usage 2>/dev/null)"; then
        printf '  journal 总占用（含活动日志）：%s\n' "$output"
    fi
    printf '临时文件不递归扫描，以免刷新访问时间影响过期判断。\n'
    printf '占用不等于可释放空间；原生清理工具的删除量无法预先准确估算。\n'
    printf 'safe 不包含 bundles 或 journal；配置、状态、备份及更新恢复材料均保留。\n'
}

clean_run_native() {
    "$@"
}

clean_packages_run() {
    clean_package_command || return $?
    if [[ "$CLEAN_PACKAGE_MANAGER" == apk && ! -d "$(vps_cmd_system_path /etc/apk/cache)" ]]; then
        printf 'APK 未启用本地软件包缓存，无需清理。\n'
        return 0
    fi
    clean_run_native "${CLEAN_NATIVE_COMMAND[@]}" || return 20
}

clean_run_one() {
    local path config
    case "$1" in
        vpsctl)
            clean_load_distribution
            vps_distribution_clean_residue
            ;;
        bundles)
            clean_load_distribution
            vps_distribution_clean_bundles
            ;;
        packages) clean_packages_run ;;
        temp)
            for path in /tmp /var/tmp; do
                vps_cmd_require_no_symlink_components "$(vps_cmd_system_path "$path")" || return $?
            done
            config="$(clean_tmpfiles_exclusions)" || return $?
            clean_tmpfiles_command
            clean_run_native "${CLEAN_NATIVE_COMMAND[@]}" <<<"$config" || return 20
            ;;
        journal) clean_run_native journalctl --vacuum-time=30d || return 20 ;;
    esac
}

clean_free_kib() {
    df -Pk -- "$(vps_cmd_system_path /var)" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }'
}

clean_result() {
    local success="$1" skipped="$2" failed="$3" first_error="$4" partial="$5"
    printf '\n清理汇总：成功 %s 项，跳过 %s 项，失败/未完成 %s 项。\n' "$success" "$skipped" "$failed"
    if ((failed > 0)); then
        if ((success > 0 || partial == 1)); then return 30; else return "$first_error"; fi
    fi
}

clean_execute() (
    local item status success=0 skipped=0 failed=0 first_error=0 partial=0 before='' after=''
    local preview_partial=0
    local -a items=() ready=()
    if [[ "$CLEAN_ACTION" == safe ]]; then items=(vpsctl packages temp); else items=("$CLEAN_ACTION"); fi
    if [[ "$VPSCTL_DRY_RUN" != 1 ]]; then vps_cmd_require_root || return $?; fi
    printf '清理范围：%s\n' "$CLEAN_ACTION"
    for item in "${items[@]}"; do
        if ! clean_supported "$item"; then
            printf '跳过 %s：%s。\n' "$(clean_label "$item")" "$CLEAN_UNAVAILABLE"
            skipped=$((skipped + 1))
            [[ "$CLEAN_ACTION" == safe ]] || return 3
            continue
        fi
        status=0
        clean_preview_one "$item" || status=$?
        if ((status == 0 || status == 30)); then
            ready+=("$item")
            ((status != 30)) || preview_partial=1
        else
            failed=$((failed + 1))
            ((first_error != 0)) || first_error="$status"
        fi
    done
    if [[ "$VPSCTL_DRY_RUN" == 1 ]]; then
        printf '\n演练结束，未执行清理或创建锁。可释放空间无法准确预估。\n'
        ((failed == 0)) || return "$first_error"
        ((preview_partial == 0)) || return 30
        ((${#ready[@]} > 0)) || return 3
        return 0
    fi
    if ((${#ready[@]} == 0)); then
        ((first_error != 0)) || first_error=3
        clean_result 0 "$skipped" "$failed" "$first_error" 0 || return $?
        return "$first_error"
    fi
    status=0
    vps_cmd_confirm '确认执行上述清理？删除的缓存和归档日志不提供内容回滚。' || status=$?
    if ((status != 0)); then
        ((status != 1)) || status=130
        return "$status"
    fi
    vps_cmd_ensure_tools system-clean flock || return $?
    vps_cmd_lock system-clean || return $?
    trap 'vps_cmd_unlock' EXIT
    trap 'exit 130' HUP INT TERM
    before="$(clean_free_kib)" || before=''
    for item in "${ready[@]}"; do
        status=0
        # Check capabilities again after the user has reviewed the plan.
        if clean_supported "$item"; then clean_run_one "$item" || status=$?; else status=3; fi
        if ((status == 0)); then
            success=$((success + 1))
            printf '完成：%s\n' "$(clean_label "$item")"
        else
            failed=$((failed + 1))
            ((first_error != 0)) || first_error="$status"
            ((status != 30)) || partial=1
            vps_cmd_error "$(clean_label "$item") 未完成（退出码 $status）；已完成的清理不回滚。"
        fi
    done
    after="$(clean_free_kib)" || after=''
    if [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]]; then
        printf '/var 所在文件系统可用空间变化：%s KiB（观测值，可能受其他进程影响）。\n' "$((after - before))"
    else
        printf '无法读取磁盘可用空间变化；清理结果以上述逐项输出为准。\n'
    fi
    clean_result "$success" "$skipped" "$failed" "$first_error" "$partial"
)

clean_menu() {
    local choice status
    while true; do
        choice="$(vps_cmd_prompt_select '系统清理' status \
            status '查看清理概览' safe '推荐清理（不含功能包、日志）' \
            vpsctl '清理 vpsctl 废弃残留' bundles '清空功能包（下次使用需下载）' \
            packages '清理软件包下载缓存' temp '清理过期临时文件' \
            journal '清理 30 天前归档 journal' quit '返回')" || {
            status=$?
            ((status == 130)) && return 0
            return "$status"
        }
        case "$choice" in
            quit) return 0 ;;
            status) clean_status || return $? ;;
            *)
                CLEAN_ACTION="$choice"
                clean_execute || return $?
                ;;
        esac
    done
}

clean_main() {
    vps_cmd_init system-clean "$CLEAN_PROJECT_ROOT" || return $?
    clean_parse_args "$@" || {
        clean_usage >&2
        return 2
    }
    if [[ "$CLEAN_ACTION" == help ]]; then
        clean_usage
        return 0
    fi
    if [[ "${VPSCTL_TESTING:-0}" != 1 && "$(uname -s)" != Linux ]]; then
        vps_cmd_error 'system clean 仅支持 Linux'
        return 3
    fi
    case "$CLEAN_ACTION" in
        status) clean_status ;;
        '') if vps_cmd_is_interactive; then clean_menu; else clean_status; fi ;;
        *) clean_execute ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then clean_main "$@"; fi
