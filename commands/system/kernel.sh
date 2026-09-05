#!/usr/bin/env bash
# Install, select and remove Debian/Ubuntu kernels without removing a live kernel.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

KERNEL_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly KERNEL_PROJECT_ROOT
# shellcheck source=../../lib/command.sh
# shellcheck disable=SC1091
source "${KERNEL_PROJECT_ROOT}/lib/command.sh"

readonly KERNEL_MANAGED_MARKER='# Managed by vpsctl system kernel.'
readonly KERNEL_XANMOD_KEY_URL='https://dl.xanmod.org/archive.key'
readonly KERNEL_XANMOD_REPO_URL='https://deb.xanmod.org'
readonly KERNEL_DOWNLOAD_USER_AGENT='Mozilla/5.0 (compatible; vpsctl-system-kernel/0.7.0)'
readonly KERNEL_XANMOD_KEY_FINGERPRINT='D38D7D1DA1349567ADED882D86F7D09EE734E623'
readonly KERNEL_REPO_LOGICAL='/etc/apt/sources.list.d/vpsctl-xanmod.sources'
readonly KERNEL_KEY_LOGICAL='/etc/apt/keyrings/vpsctl-xanmod-archive-keyring.gpg'
readonly KERNEL_STATE_LOGICAL='/var/lib/vpsctl/system/kernel-bbrv3/state'
readonly KERNEL_OFFICIAL_STATE_LOGICAL='/var/lib/vpsctl/system/kernel/install-state'
readonly KERNEL_INSTALL_TOKEN='INSTALL-KERNEL'
readonly KERNEL_SWITCH_TOKEN='SWITCH-KERNEL'
readonly KERNEL_UNINSTALL_TOKEN='REMOVE-KERNEL'
readonly KERNEL_LEGACY_INSTALL_TOKEN='INSTALL-XANMOD-BBRV3'

KERNEL_REPO_FILE=''
KERNEL_KEY_FILE=''
KERNEL_STATE_FILE=''
KERNEL_OFFICIAL_STATE_FILE=''
KERNEL_BOOT_DIR=''
KERNEL_MODULES_DIR=''
KERNEL_CPUINFO_FILE=''
KERNEL_ACTION=''
KERNEL_TYPE='xanmod'
KERNEL_TRACK='auto'
KERNEL_CPU_LEVEL='auto'
KERNEL_RELEASE=''
KERNEL_CONFIRM_INSTALL=''
KERNEL_CONFIRM_SWITCH=''
KERNEL_CONFIRM_UNINSTALL=''
KERNEL_TYPE_SET=0
KERNEL_TRACK_SET=0
KERNEL_CPU_LEVEL_SET=0
KERNEL_RELEASE_SET=0
KERNEL_INSTALL_CONFIRM_SET=0
KERNEL_SWITCH_CONFIRM_SET=0
KERNEL_UNINSTALL_CONFIRM_SET=0
KERNEL_LOCKED=0
KERNEL_TMP_DIR=''
KERNEL_REPO_CREATED=0
KERNEL_KEY_CREATED=0
KERNEL_OS_ID='unknown'
KERNEL_OS_CODENAME=''
KERNEL_OS_VERSION_ID=''
KERNEL_OS_VERSION=''
KERNEL_ARCH='unknown'
KERNEL_VIRTUALIZATION='unknown'
KERNEL_RUNNING_RELEASE='unknown'
KERNEL_EFFECTIVE_LEVEL=''
KERNEL_SELECTED_PACKAGE=''
KERNEL_SELECTED_VERSION=''
KERNEL_ACTION_REASON=''
KERNEL_ARGS=()
KERNEL_XANMOD_PACKAGES=()

# These are private modules, loaded only through this registered entry point.
# shellcheck source=kernel/providers.sh
# shellcheck disable=SC1091
source "${KERNEL_PROJECT_ROOT}/commands/system/kernel/providers.sh"
# shellcheck source=kernel/inventory.sh
# shellcheck disable=SC1091
source "${KERNEL_PROJECT_ROOT}/commands/system/kernel/inventory.sh"
# shellcheck source=kernel/grub.sh
# shellcheck disable=SC1091
source "${KERNEL_PROJECT_ROOT}/commands/system/kernel/grub.sh"

kernel_parse_globals() {
    KERNEL_ARGS=()
    while (($# > 0)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --install-deps) VPSCTL_INSTALL_DEPS=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --no-color) VPSCTL_NO_COLOR=1 ;;
            -h | --help)
                (($# == 1)) || return 2
                KERNEL_ARGS=(help)
                return 0
                ;;
            --)
                shift
                KERNEL_ARGS=("$@")
                return 0
                ;;
            -*)
                kernel_die_usage "未知全局选项：$1"
                return $?
                ;;
            *)
                KERNEL_ARGS=("$@")
                return 0
                ;;
        esac
        shift
    done
}

kernel_query_xanmod_packages() {
    local mode="${1:-}" output status package query_status
    KERNEL_XANMOD_PACKAGES=()
    case "$mode" in installed | purge) ;; *) return 2 ;; esac
    if output="$(LC_ALL=C dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\n' 2>&1)"; then
        :
    else
        query_status=$?
        vps_cmd_error "dpkg 数据库查询失败（退出码 $query_status）：$output"
        return 20
    fi
    while IFS=$'\t' read -r status package; do
        [[ -n "$package" && "$package" == *xanmod* ]] || continue
        [[ "$package" =~ ^linux-[A-Za-z0-9.+:-]*xanmod[A-Za-z0-9.+:-]*$ ]] || {
            vps_cmd_error "dpkg 返回了不安全的 XanMod 包名：$package"
            return 30
        }
        case "${mode}:${status}" in
            installed:'ii ' | installed:'hi ' | purge:'ii ' | purge:'hi ' | purge:'ri ' | purge:'pi ' | purge:'rc ')
                KERNEL_XANMOD_PACKAGES+=("$package")
                ;;
            installed:'rc ' | installed:'un ' | installed:'pn ' | purge:'un ' | purge:'pn ') ;;
            *)
                vps_cmd_error "XanMod 包 $package 处于未完成的 dpkg 状态 '${status}'；请先修复 dpkg"
                return 30
                ;;
        esac
    done <<<"$output"
}

kernel_fallback_releases() {
    local image release
    local -a images=()
    shopt -s nullglob
    images=("$KERNEL_BOOT_DIR"/vmlinuz-*)
    shopt -u nullglob
    for image in "${images[@]}"; do
        [[ -s "$image" ]] || continue
        release="${image##*/vmlinuz-}"
        [[ -n "$release" && "${release,,}" != *xanmod* ]] || continue
        [[ -s "$KERNEL_BOOT_DIR/initrd.img-$release" && -d "$KERNEL_MODULES_DIR/$release" ]] || continue
        printf '%s\n' "$release"
    done
}

kernel_repo_is_managed() {
    [[ -f "$KERNEL_REPO_FILE" && ! -L "$KERNEL_REPO_FILE" ]] && grep -Fqx "$KERNEL_MANAGED_MARKER" "$KERNEL_REPO_FILE"
}

kernel_state_is_managed() {
    [[ -f "$KERNEL_STATE_FILE" && ! -L "$KERNEL_STATE_FILE" ]] && grep -Fqx "$KERNEL_MANAGED_MARKER" "$KERNEL_STATE_FILE"
}

kernel_primary_key_fingerprint() {
    local file="$1" listing record old_ifs="$IFS" pub_count=0 fingerprint=''
    local -a fields=()
    listing="$(gpg --batch --with-colons --show-keys -- "$file" 2>/dev/null)" || return 1
    while IFS= read -r record; do
        IFS=':' read -r -a fields <<<"$record"
        IFS="$old_ifs"
        case "${fields[0]:-}" in
            pub) pub_count=$((pub_count + 1)) ;;
            fpr) [[ -n "$fingerprint" ]] || fingerprint="${fields[9]:-}" ;;
        esac
    done <<<"$listing"
    IFS="$old_ifs"
    ((pub_count == 1)) && [[ -n "$fingerprint" ]] || return 1
    printf '%s\n' "${fingerprint^^}"
}

kernel_cleanup() {
    if [[ -n "${KERNEL_TMP_DIR:-}" && -d "$KERNEL_TMP_DIR" ]]; then
        rm -rf -- "$KERNEL_TMP_DIR"
        KERNEL_TMP_DIR=''
    fi
    if [[ "${KERNEL_LOCKED:-0}" == 1 ]]; then
        vps_cmd_unlock || true
        KERNEL_LOCKED=0
    fi
}

kernel_take_lock() {
    kernel_require_safe_paths || return $?
    vps_cmd_lock system-kernel || return $?
    KERNEL_LOCKED=1
    trap kernel_cleanup EXIT
}

kernel_rollback_new_repository() {
    [[ "$KERNEL_REPO_CREATED" == 0 ]] || rm -f -- "$KERNEL_REPO_FILE"
    [[ "$KERNEL_KEY_CREATED" == 0 ]] || rm -f -- "$KERNEL_KEY_FILE"
}

kernel_join_values() {
    local value joined=''
    for value in "$@"; do
        [[ -z "$joined" ]] || joined+=', '
        joined+="$value"
    done
    printf '%s' "$joined"
}

kernel_cleanup_owned_files() {
    local repo_owned=0 state_owned=0 partial=0
    kernel_repo_is_managed && repo_owned=1
    kernel_state_is_managed && state_owned=1
    if [[ -e "$KERNEL_REPO_FILE" ]]; then
        if [[ "$repo_owned" == 1 ]]; then
            vps_cmd_run rm -f -- "$KERNEL_REPO_FILE" || return 20
        else
            vps_cmd_warning "$KERNEL_REPO_LOGICAL 不属于 vpsctl，已保留"
            partial=1
        fi
    fi
    if [[ -e "$KERNEL_KEY_FILE" ]]; then
        if [[ "$repo_owned" == 1 || "$state_owned" == 1 ]]; then
            vps_cmd_run rm -f -- "$KERNEL_KEY_FILE" || return 20
        else
            vps_cmd_warning "$KERNEL_KEY_LOGICAL 的所有权无法证明，已保留"
            partial=1
        fi
    fi
    if [[ -e "$KERNEL_STATE_FILE" ]]; then
        if [[ "$state_owned" == 1 ]]; then
            vps_cmd_run rm -f -- "$KERNEL_STATE_FILE" || return 20
        else
            vps_cmd_warning "$KERNEL_STATE_LOGICAL 不属于 vpsctl，已保留"
            partial=1
        fi
    fi
    ((partial == 0)) || return 30
}

kernel_usage() {
    cat <<'EOF'
系统内核管理：安装官方/Cloud/HWE/XanMod 内核，永久切换默认启动版本，精确卸载旧版本。

用法：
  kernel.sh [global-options] [status]
  kernel.sh [global-options] install [--type official|cloud|hwe|xanmod]
      [--track auto|main|lts] [--cpu-level auto|v1|v2|v3]
      [--confirm-install INSTALL-KERNEL]
  kernel.sh [global-options] switch --release RELEASE
      [--confirm-switch SWITCH-KERNEL]
  kernel.sh [global-options] uninstall --release RELEASE
      [--confirm-uninstall REMOVE-KERNEL]

选项与范围：
  official    Debian linux-image-amd64 / Ubuntu linux-generic（菜单默认推荐）
  cloud       Debian linux-image-cloud-amd64
  hwe         Ubuntu LTS 对应的 linux-generic-hwe-VERSION_ID
  xanmod      XanMod BBRv3；CLI 省略 --type 时保持此默认
  --track / --cpu-level  仅用于 XanMod，auto 优先 main，缺包时回退 LTS
  --release   完整内核版本（与 uname -r 的格式相同），不接受包名或通配符

仅支持 Debian/Ubuntu amd64、APT/dpkg；容器和 WSL 不能管理宿主机内核。
官方内核使用发行版已配置的受信源；XanMod 验证完整密钥指纹并拒绝
Secure Boot 启用或状态未知的环境。切换及安全卸载需要可识别的标准 GRUB 2。

永久切换固定具体版本，由用户自行重启。安装不会卸载旧版本；先切换并
重启，再卸载旧版本。当前运行、默认启动、已有下一次启动目标均不可卸载。
卸载可能连带移除负责跟随更新的同系列元包，确认前会列出完整清单。
不会自动重启，不使用通配符卸载或 autoremove。

真实变更需要对应强确认，--yes 不能绕过。旧 INSTALL-XANMOD-BBRV3
仅兼容 XanMod 安装；旧的无目标“卸载全部 XanMod”接口已取消。

全局选项（必须位于动作之前）：
  --dry-run --install-deps --yes --non-interactive --quiet --verbose --no-color
  -h, --help
EOF
}

kernel_die_usage() {
    vps_cmd_error "$1"
    kernel_usage >&2
    return 2
}

kernel_parse_args() {
    local option value
    local -a positional=()
    KERNEL_ACTION=''
    KERNEL_TYPE=xanmod
    KERNEL_TRACK=auto
    KERNEL_CPU_LEVEL=auto
    KERNEL_RELEASE=''
    KERNEL_CONFIRM_INSTALL=''
    KERNEL_CONFIRM_SWITCH=''
    KERNEL_CONFIRM_UNINSTALL=''
    KERNEL_TYPE_SET=0
    KERNEL_TRACK_SET=0
    KERNEL_CPU_LEVEL_SET=0
    KERNEL_RELEASE_SET=0
    KERNEL_INSTALL_CONFIRM_SET=0
    KERNEL_SWITCH_CONFIRM_SET=0
    KERNEL_UNINSTALL_CONFIRM_SET=0
    while (($# > 0)); do
        case "$1" in
            --type | --track | --cpu-level | --release | --confirm-install | --confirm-switch | --confirm-uninstall)
                option="$1"
                (($# >= 2)) || {
                    kernel_die_usage "$option 缺少参数值"
                    return $?
                }
                value="$2"
                [[ -n "$value" ]] || {
                    kernel_die_usage "$option 不接受空值"
                    return $?
                }
                case "$option" in
                    --type)
                        KERNEL_TYPE="$value"
                        KERNEL_TYPE_SET=1
                        ;;
                    --track)
                        KERNEL_TRACK="$value"
                        KERNEL_TRACK_SET=1
                        ;;
                    --cpu-level)
                        KERNEL_CPU_LEVEL="$value"
                        KERNEL_CPU_LEVEL_SET=1
                        ;;
                    --release)
                        KERNEL_RELEASE="$value"
                        KERNEL_RELEASE_SET=1
                        ;;
                    --confirm-install)
                        KERNEL_CONFIRM_INSTALL="$value"
                        KERNEL_INSTALL_CONFIRM_SET=1
                        ;;
                    --confirm-switch)
                        KERNEL_CONFIRM_SWITCH="$value"
                        KERNEL_SWITCH_CONFIRM_SET=1
                        ;;
                    --confirm-uninstall)
                        KERNEL_CONFIRM_UNINSTALL="$value"
                        KERNEL_UNINSTALL_CONFIRM_SET=1
                        ;;
                esac
                shift 2
                ;;
            -h | --help | help)
                positional+=(help)
                shift
                ;;
            --)
                shift
                positional+=("$@")
                break
                ;;
            -*)
                kernel_die_usage "未知选项：$1"
                return $?
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done
    ((${#positional[@]} <= 1)) || {
        kernel_die_usage "多余参数：${positional[1]}"
        return $?
    }
    ((${#positional[@]} == 0)) || KERNEL_ACTION="${positional[0]}"
    case "$KERNEL_TYPE" in official | cloud | hwe | xanmod) ;; *)
        kernel_die_usage "无效内核类型：$KERNEL_TYPE"
        return $?
        ;;
    esac
    case "$KERNEL_TRACK" in auto | main | lts) ;; *)
        kernel_die_usage "无效 track：$KERNEL_TRACK"
        return $?
        ;;
    esac
    case "$KERNEL_CPU_LEVEL" in auto | v1 | v2 | v3) ;; *)
        kernel_die_usage "无效 CPU 等级：$KERNEL_CPU_LEVEL"
        return $?
        ;;
    esac
    if ((KERNEL_RELEASE_SET)) && ! kernel_release_valid "$KERNEL_RELEASE"; then
        kernel_die_usage '无效 --release：必须提供完整内核版本，不接受路径、包名或通配符'
        return $?
    fi
    if ((KERNEL_INSTALL_CONFIRM_SET)) && [[ "$KERNEL_CONFIRM_INSTALL" != "$KERNEL_INSTALL_TOKEN" ]]; then
        [[ "$KERNEL_TYPE" == xanmod && "$KERNEL_CONFIRM_INSTALL" == "$KERNEL_LEGACY_INSTALL_TOKEN" ]] || {
            kernel_die_usage '--confirm-install 的确认短语不正确'
            return $?
        }
    fi
    if ((KERNEL_SWITCH_CONFIRM_SET)) && [[ "$KERNEL_CONFIRM_SWITCH" != "$KERNEL_SWITCH_TOKEN" ]]; then
        kernel_die_usage '--confirm-switch 的确认短语不正确'
        return $?
    fi
    if ((KERNEL_UNINSTALL_CONFIRM_SET)) && [[ "$KERNEL_CONFIRM_UNINSTALL" != "$KERNEL_UNINSTALL_TOKEN" ]]; then
        kernel_die_usage '--confirm-uninstall 请使用 REMOVE-KERNEL，并明确选择 --release'
        return $?
    fi
}

kernel_validate_action_options() {
    local install_options=$((KERNEL_TYPE_SET + KERNEL_TRACK_SET + KERNEL_CPU_LEVEL_SET + KERNEL_INSTALL_CONFIRM_SET))
    case "$KERNEL_ACTION" in
        '' | status | help)
            ((install_options + KERNEL_RELEASE_SET + KERNEL_SWITCH_CONFIRM_SET + KERNEL_UNINSTALL_CONFIRM_SET == 0)) || {
                kernel_die_usage "${KERNEL_ACTION:-无动作} 不接受动作选项"
                return $?
            }
            ;;
        install)
            ((KERNEL_RELEASE_SET + KERNEL_SWITCH_CONFIRM_SET + KERNEL_UNINSTALL_CONFIRM_SET == 0)) || {
                kernel_die_usage 'install 不接受 --release 或其他动作的确认选项'
                return $?
            }
            if [[ "$KERNEL_TYPE" != xanmod ]] && ((KERNEL_TRACK_SET + KERNEL_CPU_LEVEL_SET > 0)); then
                kernel_die_usage '--track 和 --cpu-level 仅用于 XanMod'
                return $?
            fi
            ;;
        switch | uninstall)
            ((install_options == 0)) || {
                kernel_die_usage "$KERNEL_ACTION 不接受安装选项"
                return $?
            }
            if [[ "$KERNEL_ACTION" == switch ]]; then
                ((KERNEL_UNINSTALL_CONFIRM_SET == 0)) || {
                    kernel_die_usage 'switch 不接受 --confirm-uninstall'
                    return $?
                }
            else
                ((KERNEL_SWITCH_CONFIRM_SET == 0)) || {
                    kernel_die_usage 'uninstall 不接受 --confirm-switch'
                    return $?
                }
            fi
            if [[ -z "$KERNEL_RELEASE" ]] && ! vps_cmd_is_interactive; then
                kernel_die_usage "$KERNEL_ACTION 必须用 --release 指定完整内核版本"
                return $?
            fi
            ;;
        *)
            kernel_die_usage "未知操作：$KERNEL_ACTION"
            return $?
            ;;
    esac
}

kernel_init_paths() {
    KERNEL_REPO_FILE="$(vps_cmd_system_path "$KERNEL_REPO_LOGICAL")" || return $?
    KERNEL_KEY_FILE="$(vps_cmd_system_path "$KERNEL_KEY_LOGICAL")" || return $?
    KERNEL_STATE_FILE="$(vps_cmd_system_path "$KERNEL_STATE_LOGICAL")" || return $?
    KERNEL_OFFICIAL_STATE_FILE="$(vps_cmd_system_path "$KERNEL_OFFICIAL_STATE_LOGICAL")" || return $?
    KERNEL_BOOT_DIR="$(vps_cmd_system_path /boot)" || return $?
    KERNEL_MODULES_DIR="$(vps_cmd_system_path /lib/modules)" || return $?
    KERNEL_CPUINFO_FILE="$(vps_cmd_system_path /proc/cpuinfo)" || return $?
    kernel_grub_init_paths
}

kernel_require_safe_paths() {
    local path
    if [[ "$KERNEL_ACTION" == install && "$KERNEL_TYPE" != xanmod ]]; then
        vps_cmd_require_no_symlink_components "$KERNEL_OFFICIAL_STATE_FILE"
        return $?
    fi
    if [[ "$KERNEL_ACTION" == install ]]; then
        for path in "$KERNEL_REPO_FILE" "$KERNEL_KEY_FILE" "$KERNEL_STATE_FILE"; do
            vps_cmd_require_no_symlink_components "$path" || return $?
        done
    fi
}

kernel_ensure_install_dependencies() {
    local -a required=(awk install mktemp flock sort readlink)
    [[ "$KERNEL_TYPE" != xanmod ]] || required+=(curl gpg od)
    vps_cmd_ensure_tools system-kernel "${required[@]}" || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info '依赖安装仍处于演练计划；请安装后重新运行内核安装'
        return 64
    fi
}

kernel_ensure_uninstall_dependencies() {
    local -a required=(awk flock sort readlink od)
    [[ ! -d "$(vps_cmd_system_path /sys/firmware/efi)" ]] || required+=(efibootmgr)
    vps_cmd_ensure_tools system-kernel "${required[@]}" || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info '依赖安装仍处于演练计划；请安装后重新运行当前内核动作'
        return 64
    fi
}

kernel_confirm_action() {
    local action="$1" provided="$2" token="$3" prompt="$4"
    [[ "${VPSCTL_DRY_RUN:-0}" == 1 || "$provided" == "$token" ]] && return 0
    if [[ "$action" == install && "$KERNEL_TYPE" == xanmod && "$provided" == "$KERNEL_LEGACY_INSTALL_TOKEN" ]]; then return 0; fi
    vps_cmd_is_interactive || {
        vps_cmd_error "非交互 $action 必须提供 --confirm-$action $token"
        return 3
    }
    vps_cmd_confirm_token "$prompt" "$token" || {
        vps_cmd_warning '已取消内核操作'
        return 130
    }
}

kernel_confirm_install_action() {
    kernel_confirm_action install "$KERNEL_CONFIRM_INSTALL" "$KERNEL_INSTALL_TOKEN" '确认安装/更新内核。请先确认控制台或救援入口可用。'
}

kernel_confirm_uninstall_action() {
    kernel_confirm_action uninstall "$KERNEL_CONFIRM_UNINSTALL" "$KERNEL_UNINSTALL_TOKEN" "确认卸载 $KERNEL_RELEASE 及上列关联软件包。"
}

kernel_package_is_installed() {
    kernel_inventory_package_installed "$1"
}

kernel_refresh_bootloader() {
    if command -v update-grub >/dev/null 2>&1; then
        vps_cmd_run update-grub || return 20
    else
        vps_cmd_warning '未找到 update-grub；依赖内核包的启动器钩子，重启前请人工检查启动项'
    fi
}

kernel_refresh_inventory() {
    kernel_inventory_load || return $?
    kernel_grub_load || return $?
}

kernel_release_actionable() {
    local action="$1" release="$2" selector
    KERNEL_ACTION_REASON=''
    if [[ "${KERNEL_RELEASE_MANAGED[$release]:-0}" != 1 ]]; then
        KERNEL_ACTION_REASON="${KERNEL_RELEASE_REASON[$release]:-软件包归属或状态无法证明}"
    elif [[ "${KERNEL_GRUB_SUPPORTED:-0}" != 1 ]]; then
        KERNEL_ACTION_REASON="${KERNEL_GRUB_REASON:-无法识别活动 GRUB}"
    elif [[ -z "${KERNEL_GRUB_DEFAULT_RELEASE:-}" ]]; then
        KERNEL_ACTION_REASON='默认启动内核无法解析'
    elif [[ -n "${KERNEL_GRUB_NEXT_ID:-}" && -z "${KERNEL_GRUB_NEXT_RELEASE:-}" ]]; then
        KERNEL_ACTION_REASON='下一次启动目标无法解析'
    elif [[ "$action" == switch ]]; then
        if [[ "${KERNEL_RELEASE_COMPLETE[$release]:-0}" != 1 || -z "${KERNEL_GRUB_ENTRY[$release]:-}" ]]; then
            KERNEL_ACTION_REASON='启动文件或普通 GRUB 启动项不完整'
        fi
    elif [[ "$release" == "$KERNEL_RUNNING_RELEASE" ]]; then
        KERNEL_ACTION_REASON='当前运行内核受保护；切换并重启后再卸载'
    elif [[ "$release" == "$KERNEL_GRUB_DEFAULT_RELEASE" ]]; then
        KERNEL_ACTION_REASON='默认启动内核受保护；请先切换默认版本'
    elif [[ "$release" == "${KERNEL_GRUB_NEXT_RELEASE:-}" ]]; then
        KERNEL_ACTION_REASON='下一次启动目标受保护；请先切换默认版本以清除覆盖'
    elif [[ "${KERNEL_RELEASE_COMPLETE[$KERNEL_GRUB_DEFAULT_RELEASE]:-0}" != 1 || "${KERNEL_RELEASE_MANAGED[$KERNEL_GRUB_DEFAULT_RELEASE]:-0}" != 1 || -z "${KERNEL_GRUB_ENTRY[$KERNEL_GRUB_DEFAULT_RELEASE]:-}" ]]; then
        KERNEL_ACTION_REASON='无法证明保留的默认内核启动文件与软件包完整'
    else
        for selector in "${KERNEL_GRUB_DEFAULT_SELECTOR:-}" "${KERNEL_GRUB_NEXT_SELECTOR:-}"; do
            if [[ "$selector" =~ ^[0-9]+(\>[0-9]+)*$ && "$selector" != 0 ]]; then
                KERNEL_ACTION_REASON='启动项使用会随删除变化的编号；请先 switch 固定默认内核'
            fi
        done
    fi
    [[ -z "$KERNEL_ACTION_REASON" ]]
}

kernel_status() {
    local release flags source package package_text meta_text proc_path bbr=未知 qdisc=未知
    vps_cmd_status '当前内核' "$KERNEL_RUNNING_RELEASE" normal
    case "$KERNEL_OS_ID" in debian | ubuntu) ;; *)
        vps_cmd_status '内核包管理' '不适用（仅 Debian/Ubuntu）' muted
        vps_cmd_info '当前平台只显示运行内核，不管理内核软件包'
        return 0
        ;;
    esac
    kernel_refresh_inventory || return $?
    vps_cmd_status '默认启动内核' "${KERNEL_GRUB_DEFAULT_RELEASE:-未知}" normal
    vps_cmd_status '下一次启动覆盖' "${KERNEL_GRUB_NEXT_RELEASE:-${KERNEL_GRUB_NEXT_ID:-无}}" muted
    [[ "${KERNEL_GRUB_SUPPORTED:-0}" == 1 ]] || vps_cmd_status '启动器' "${KERNEL_GRUB_REASON:-无法识别}" warning
    for release in "${KERNEL_RELEASES[@]}"; do
        flags=''
        [[ "$release" != "$KERNEL_RUNNING_RELEASE" ]] || flags+='当前运行；'
        [[ "$release" != "${KERNEL_GRUB_DEFAULT_RELEASE:-}" ]] || flags+='默认启动；'
        [[ "$release" != "${KERNEL_GRUB_NEXT_RELEASE:-}" ]] || flags+='下一次启动；'
        if [[ "${KERNEL_RELEASE_COMPLETE[$release]:-0}" == 1 ]]; then flags+='启动文件完整；'; else flags+='启动文件不完整；'; fi
        if kernel_release_actionable uninstall "$release"; then flags+='可卸载'; else flags+="不可卸载：$KERNEL_ACTION_REASON"; fi
        source="${KERNEL_RELEASE_SOURCE[$release]:-未知}"
        case "${KERNEL_RELEASE_SERIES[$release]:-}" in
            ubuntu:official) source='Ubuntu 官方' ;;
            ubuntu:hwe) source='Ubuntu HWE' ;;
        esac
        vps_cmd_status "$release" "$source · $flags" normal
        package_text="${KERNEL_RELEASE_PACKAGES[$release]:-}"
        package_text="${package_text//$'\n'/, }"
        vps_cmd_status '关联包' "${package_text:-无可证明归属的软件包}" muted
        meta_text=''
        for package in "${!KERNEL_PKG_IS_META[@]}"; do
            [[ "${KERNEL_PKG_IS_META[$package]}" == 1 && "${KERNEL_PKG_RELEASE[$package]:-}" == "$release" ]] || continue
            kernel_inventory_package_installed "$package" || continue
            [[ -z "$meta_text" ]] || meta_text+=', '
            meta_text+="$package"
        done
        [[ -z "$meta_text" ]] || vps_cmd_status '更新元包' "$meta_text" muted
    done
    proc_path="$(vps_cmd_system_path /proc/sys/net/ipv4/tcp_congestion_control)" || return $?
    [[ ! -r "$proc_path" ]] || IFS= read -r bbr <"$proc_path" || true
    proc_path="$(vps_cmd_system_path /proc/sys/net/core/default_qdisc)" || return $?
    [[ ! -r "$proc_path" ]] || IFS= read -r qdisc <"$proc_path" || true
    vps_cmd_status '拥塞控制' "$bbr" normal
    vps_cmd_status '默认 qdisc' "$qdisc" normal
}

kernel_dry_run_install_plan() {
    local preferred
    local -a candidates=()
    mapfile -t candidates < <(kernel_candidate_packages)
    ((${#candidates[@]} > 0)) || {
        vps_cmd_error '当前类型没有适配候选元包'
        return 3
    }
    preferred="${candidates[0]}"
    vps_cmd_info "候选元包顺序：$(kernel_join_values "${candidates[@]}")"
    if [[ "$KERNEL_TYPE" == xanmod ]]; then
        vps_cmd_run curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/vpsctl-xanmod-archive.key "$KERNEL_XANMOD_KEY_URL"
        vps_cmd_info "密钥必须匹配完整指纹 $KERNEL_XANMOD_KEY_FINGERPRINT"
        vps_cmd_info "将写入受管 XanMod 源 $KERNEL_REPO_LOGICAL（suite=$KERNEL_OS_CODENAME）"
    else
        vps_cmd_info "使用已配置的 $KERNEL_OS_ID 官方受信源；候选必须匹配本机 suite"
    fi
    vps_cmd_run apt-get update
    vps_cmd_run apt-cache policy "$preferred"
    vps_cmd_info '真实执行将校验来源后固定当前候选版本安装，并验证其具体内核文件'
    vps_cmd_run env DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::AutomaticRemove=false install -y --no-remove --no-install-recommends "$preferred"
    command -v update-grub >/dev/null 2>&1 && vps_cmd_run update-grub
    vps_cmd_info '演练不会写文件、下载、刷新 APT、修改启动项或安装内核'
}

kernel_install() (
    local dependency_status package release version planned_package resolved_package
    kernel_require_install_platform || return $?
    if [[ "$KERNEL_TYPE" == xanmod ]]; then kernel_resolve_cpu_level || return $?; fi
    if kernel_ensure_install_dependencies; then :; else
        dependency_status=$?
        ((dependency_status == 64)) && return 0
        return "$dependency_status"
    fi
    vps_cmd_require_root || return $?
    kernel_take_lock || return $?
    kernel_confirm_install_action || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        kernel_dry_run_install_plan
        return $?
    fi
    kernel_prepare_repository || {
        dependency_status=$?
        kernel_rollback_new_repository
        return "$dependency_status"
    }
    if ! vps_cmd_run apt-get update; then
        kernel_rollback_new_repository
        vps_cmd_error 'APT 元数据刷新失败；本次新建的 XanMod 源已撤销'
        return 20
    fi
    kernel_select_package || {
        dependency_status=$?
        kernel_rollback_new_repository
        return "$dependency_status"
    }
    package="$KERNEL_SELECTED_PACKAGE"
    version="$KERNEL_SELECTED_VERSION"
    vps_cmd_info "选择 $package，候选版本 $version"
    kernel_validate_install_plan "$package" "$version" || {
        dependency_status=$?
        kernel_rollback_new_repository
        return "$dependency_status"
    }
    if ! vps_cmd_run env DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::AutomaticRemove=false install -y --no-remove --no-install-recommends "$package=$version"; then
        vps_cmd_error '内核安装未完成；保留软件源与已有内核，请检查 dpkg 后重试'
        return 20
    fi
    kernel_inventory_load || return 30
    for planned_package in "${!KERNEL_INSTALL_EXPECTED_VERSIONS[@]}"; do
        resolved_package="$(_kernel_inventory_resolve_package "$planned_package")" || {
            vps_cmd_error "安装计划中的包未登记：$planned_package"
            return 30
        }
        if ! kernel_inventory_package_installed "$resolved_package" || [[ "${KERNEL_PKG_VERSION[$resolved_package]:-}" != "${KERNEL_INSTALL_EXPECTED_VERSIONS[$planned_package]}" ]]; then
            vps_cmd_error "安装后包版本与已验证来源的计划不一致：$planned_package"
            return 30
        fi
    done
    kernel_package_is_installed "$package" || {
        vps_cmd_error 'APT 返回成功，但未确认目标元包安装完整'
        return 30
    }
    kernel_inventory_meta_releases "$package" || {
        vps_cmd_error '无法验证元包实际安装的内核版本'
        return 30
    }
    ((${#KERNEL_META_RELEASES[@]} > 0)) || {
        vps_cmd_error '元包没有可验证的内核镜像'
        return 30
    }
    for release in "${KERNEL_META_RELEASES[@]}"; do
        [[ "${KERNEL_RELEASE_MANAGED[$release]:-0}" == 1 && "${KERNEL_RELEASE_COMPLETE[$release]:-0}" == 1 ]] || {
            vps_cmd_error "已安装的 $release 启动文件或软件包状态不完整"
            return 30
        }
    done
    kernel_refresh_bootloader || {
        vps_cmd_error '内核已安装，但启动菜单刷新失败；请先修复再重启'
        return 30
    }
    kernel_grub_load || return 30
    if [[ "${KERNEL_GRUB_SUPPORTED:-0}" == 1 ]]; then
        for release in "${KERNEL_META_RELEASES[@]}"; do
            [[ -n "${KERNEL_GRUB_ENTRY[$release]:-}" ]] || {
                vps_cmd_error "$release 缺少可验证的 GRUB 普通启动项"
                return 30
            }
        done
    fi
    kernel_write_state "$package" "$version" || {
        vps_cmd_error '内核已安装，但操作状态保存失败'
        return 30
    }
    vps_cmd_success "已安装/更新 $package ($version)"
    vps_cmd_status '当前运行' "$KERNEL_RUNNING_RELEASE" normal
    vps_cmd_status '默认启动' "${KERNEL_GRUB_DEFAULT_RELEASE:-未知，请人工检查启动器}" normal
    vps_cmd_info '如需固定使用某个版本，请执行 switch；自行重启后再卸载旧版本'
)

kernel_select_release() {
    local action="$1" release
    local -a choices=()
    if [[ -n "$KERNEL_RELEASE" ]]; then
        kernel_release_valid "$KERNEL_RELEASE" || {
            vps_cmd_error '内核版本格式无效'
            return 2
        }
        kernel_release_actionable "$action" "$KERNEL_RELEASE" || {
            vps_cmd_error "$KERNEL_RELEASE：$KERNEL_ACTION_REASON"
            return 3
        }
        return 0
    fi
    vps_cmd_is_interactive || {
        vps_cmd_error "$action 必须提供 --release"
        return 2
    }
    for release in "${KERNEL_RELEASES[@]}"; do
        if kernel_release_actionable "$action" "$release"; then
            choices+=("$release" "$release · ${KERNEL_RELEASE_SOURCE[$release]:-未知}")
        fi
    done
    ((${#choices[@]} > 0)) || {
        vps_cmd_error "没有可执行 $action 的内核版本；请查看状态中的保护原因"
        return 3
    }
    KERNEL_RELEASE="$(vps_cmd_prompt_select "请选择 $action 的内核版本" '' "${choices[@]}")" || return $?
}

kernel_switch() (
    local dependency_status
    kernel_require_uninstall_platform || return $?
    if kernel_ensure_uninstall_dependencies; then :; else
        dependency_status=$?
        ((dependency_status == 64)) && return 0
        return "$dependency_status"
    fi
    vps_cmd_require_root || return $?
    kernel_take_lock || return $?
    kernel_refresh_inventory || return $?
    kernel_grub_require || return $?
    kernel_select_release switch || return $?
    kernel_switch_signature_gate "$KERNEL_RELEASE" || return $?
    vps_cmd_info "将永久固定默认启动内核：$KERNEL_RELEASE（当前运行 $KERNEL_RUNNING_RELEASE）"
    kernel_confirm_action switch "$KERNEL_CONFIRM_SWITCH" "$KERNEL_SWITCH_TOKEN" "确认将 $KERNEL_RELEASE 设为永久默认启动内核。" || return $?
    kernel_grub_switch "$KERNEL_RELEASE" || return $?
    vps_cmd_info '不会自动重启；请自行重启并用 system kernel status 或 uname -r 核对'
)

kernel_switch_signature_gate() {
    local release="$1" package secure_boot_status=0 unsigned=0
    [[ "${KERNEL_RELEASE_SOURCE[$release]:-}" != XanMod ]] || unsigned=1
    while IFS= read -r package; do
        [[ "$package" != *unsigned* ]] || unsigned=1
    done <<<"${KERNEL_RELEASE_PACKAGES[$release]:-}"
    if ((unsigned)); then
        kernel_secure_boot_enabled || secure_boot_status=$?
        [[ "$secure_boot_status" == 1 ]] || {
            vps_cmd_error '目标是 XanMod 或未签名内核，Secure Boot 启用或状态未知时不能切换'
            return 3
        }
    fi
}

kernel_purge_simulate() {
    local output
    if ! output="$(LC_ALL=C apt-get --simulate -o APT::Get::AutomaticRemove=false purge -- "${KERNEL_PURGE_PACKAGES[@]}" 2>&1)"; then
        vps_cmd_error "APT 卸载模拟失败：$output"
        return 20
    fi
    kernel_validate_purge_simulation "$output" || return $?
}

kernel_uninstall() (
    local dependency_status release package before_default before_next source_remaining
    local -a packages=()
    local -A protected_versions=() purge_set=()
    kernel_require_uninstall_platform || return $?
    if kernel_ensure_uninstall_dependencies; then :; else
        dependency_status=$?
        ((dependency_status == 64)) && return 0
        return "$dependency_status"
    fi
    vps_cmd_require_root || return $?
    kernel_take_lock || return $?
    kernel_refresh_inventory || return $?
    kernel_grub_require || return $?
    kernel_select_release uninstall || return $?
    release="$KERNEL_RELEASE"
    before_default="$KERNEL_GRUB_DEFAULT_RELEASE"
    before_next="${KERNEL_GRUB_NEXT_RELEASE:-}"
    kernel_build_purge_packages "$release" || return $?
    packages=("${KERNEL_PURGE_PACKAGES[@]}")
    ((${#packages[@]} > 0)) || {
        vps_cmd_error '所选内核没有可安全卸载的软件包'
        return 3
    }
    for package in "${packages[@]}"; do purge_set["$package"]=1; done
    for package in "${!KERNEL_PKG_STATUS[@]}"; do
        if [[ -z "${purge_set[$package]:-}" && "${KERNEL_PKG_STATUS[$package]:1:1}" == i ]]; then
            protected_versions["$package"]="${KERNEL_PKG_VERSION[$package]:-}"
        fi
    done
    kernel_purge_simulate || return $?
    vps_cmd_warning "将精确卸载 $release：$(kernel_join_values "${packages[@]}")"
    vps_cmd_info "保留当前运行 $KERNEL_RUNNING_RELEASE；默认启动 $before_default"
    if ((${#KERNEL_PURGE_METAPACKAGES[@]} > 0)); then
        vps_cmd_warning "同时移除更新元包：$(kernel_join_values "${KERNEL_PURGE_METAPACKAGES[@]}")；该系列将停止自动跟随更新"
    fi
    kernel_confirm_uninstall_action || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_run env DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::AutomaticRemove=false purge -y -- "${packages[@]}"
        vps_cmd_run update-grub
        vps_cmd_info '演练不会卸载软件包、写备份、刷新启动项或清理软件源'
        return 0
    fi
    # Rebuild and simulate after confirmation: a package manager may have run
    # while the user reviewed the plan. Never apply a changed package set.
    kernel_refresh_inventory || return $?
    kernel_grub_require || return $?
    kernel_release_actionable uninstall "$release" || {
        vps_cmd_error "$KERNEL_ACTION_REASON"
        return 3
    }
    [[ "$before_default" == "$KERNEL_GRUB_DEFAULT_RELEASE" && "$before_next" == "${KERNEL_GRUB_NEXT_RELEASE:-}" ]] || {
        vps_cmd_error '启动选择在确认期间发生变化，请重新查看状态并重试'
        return 3
    }
    kernel_build_purge_packages "$release" || return $?
    [[ "$(kernel_join_values "${packages[@]}")" == "$(kernel_join_values "${KERNEL_PURGE_PACKAGES[@]}")" ]] || {
        vps_cmd_error 'APT 目标包在确认期间发生变化，请重新查看计划并重试'
        return 3
    }
    kernel_purge_simulate || return $?
    if ! vps_cmd_run env DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::AutomaticRemove=false purge -y -- "${packages[@]}"; then
        vps_cmd_error '卸载事务未完成；保留软件源与状态，先检查 dpkg 和启动项再重启'
        return 30
    fi
    kernel_inventory_load || return 30
    for package in "${packages[@]}"; do
        case "${KERNEL_PKG_STATUS[$package]:-}" in '' | 'un ' | 'pn ') ;; *)
            vps_cmd_error "目标包仍未清除：$package"
            return 30
            ;;
        esac
    done
    for package in "${!protected_versions[@]}"; do
        if ! kernel_inventory_package_installed "$package" || [[ "${KERNEL_PKG_VERSION[$package]:-}" != "${protected_versions[$package]}" ]]; then
            vps_cmd_error "受保护包状态发生变化：$package；请检查 dpkg 后再重启"
            return 30
        fi
    done
    kernel_refresh_bootloader || {
        vps_cmd_error '软件包已卸载，但 GRUB 刷新失败；请先修复启动项'
        return 30
    }
    kernel_grub_load || return 30
    kernel_grub_require || return 30
    if [[ "$KERNEL_GRUB_DEFAULT_RELEASE" != "$before_default" || "${KERNEL_GRUB_NEXT_RELEASE:-}" != "$before_next" || "${KERNEL_RELEASE_COMPLETE[$before_default]:-0}" != 1 ]]; then
        vps_cmd_error '卸载后默认启动或保留内核验证失败；请先修复启动配置再重启'
        return 30
    fi
    if [[ -e "$KERNEL_BOOT_DIR/vmlinuz-$release" || -e "$KERNEL_BOOT_DIR/initrd.img-$release" ]] || _kernel_inventory_path_has_entries "$KERNEL_MODULES_DIR/$release"; then
        vps_cmd_error '目标包已卸载，但仍有该版本启动文件或模块；保留现场供检查'
        return 30
    fi
    source_remaining=0
    for package in "${packages[@]}"; do [[ "$package" != *xanmod* ]] || source_remaining=1; done
    if ((source_remaining)); then
        kernel_query_xanmod_packages purge || return $?
        if ((${#KERNEL_XANMOD_PACKAGES[@]} == 0)); then
            for package in "$KERNEL_REPO_FILE" "$KERNEL_KEY_FILE" "$KERNEL_STATE_FILE"; do
                vps_cmd_require_no_symlink_components "$package" || return 30
            done
            kernel_cleanup_owned_files || return $?
        fi
    fi
    vps_cmd_success "已卸载 $release；当前运行和默认启动内核保持完整"
)

kernel_menu_snapshot() {
    printf '当前运行 %s' "$KERNEL_RUNNING_RELEASE"
}

kernel_menu_hwe_available() (
    local package
    KERNEL_TYPE=hwe
    _kernel_require_provider_platform >/dev/null 2>&1 || return 1
    package="$(kernel_candidate_packages)" || return 1
    [[ -n "$package" ]] || return 1
    kernel_package_candidate_version "$package" >/dev/null 2>&1
)

kernel_menu_install() (
    local -a choices=(official '官方标准内核（推荐）')
    case "$KERNEL_OS_ID" in
        debian) choices+=(cloud 'Debian Cloud 内核') ;;
        ubuntu)
            if kernel_menu_hwe_available; then
                choices+=(hwe 'Ubuntu HWE 内核')
            fi
            ;;
    esac
    choices+=(xanmod 'XanMod BBRv3 内核')
    KERNEL_ACTION=install
    KERNEL_TYPE="$(vps_cmd_prompt_select '请选择内核类型' official "${choices[@]}")" || return $?
    KERNEL_TYPE_SET=1
    if [[ "$KERNEL_TYPE" == xanmod ]]; then
        KERNEL_TRACK="$(vps_cmd_prompt_select '请选择 XanMod 分支' auto auto '自动选择 main / LTS' main '稳定 main' lts '长期支持 LTS')" || return $?
        KERNEL_CPU_LEVEL="$(vps_cmd_prompt_select '请选择 XanMod CPU 等级' auto auto '自动检测（推荐）' v1 'x86-64-v1' v2 'x86-64-v2' v3 'x86-64-v3')" || return $?
    fi
    kernel_install
)

kernel_interactive_menu() {
    local choice action_status status=0
    while true; do
        printf ' %s\n' "$(kernel_menu_snapshot)" >&2
        choice="$(vps_cmd_prompt_select '系统内核管理' status status '查看已安装内核与启动状态' install '安装/更新内核' switch '永久切换默认启动内核' uninstall '卸载指定旧版本' quit '退出')" || {
            action_status=$?
            ((action_status == 130)) && return "$status"
            return "$action_status"
        }
        KERNEL_RELEASE=''
        KERNEL_CONFIRM_INSTALL=''
        KERNEL_CONFIRM_SWITCH=''
        KERNEL_CONFIRM_UNINSTALL=''
        KERNEL_ACTION="$choice"
        action_status=0
        case "$choice" in
            status) kernel_status || action_status=$? ;;
            install) kernel_menu_install || action_status=$? ;;
            switch) kernel_switch || action_status=$? ;;
            uninstall) kernel_uninstall || action_status=$? ;;
            quit) return "$status" ;;
            *)
                vps_cmd_error "无效菜单动作：$choice"
                return 70
                ;;
        esac
        ((action_status == 0 || action_status == 130)) || status=$action_status
    done
}

kernel_main() {
    vps_cmd_init system-kernel "$KERNEL_PROJECT_ROOT" || return $?
    kernel_init_paths || return $?
    kernel_parse_globals "$@" || return $?
    kernel_parse_args "${KERNEL_ARGS[@]}" || return $?
    kernel_validate_action_options || return $?
    if [[ "$KERNEL_ACTION" == help ]]; then
        kernel_usage
        return 0
    fi
    kernel_load_platform || return $?
    if [[ -z "$KERNEL_ACTION" ]]; then
        if vps_cmd_is_interactive; then kernel_interactive_menu; else kernel_status; fi
        return $?
    fi
    case "$KERNEL_ACTION" in
        status) kernel_status ;;
        install) kernel_install ;;
        switch) kernel_switch ;;
        uninstall) kernel_uninstall ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    kernel_main "$@"
fi
