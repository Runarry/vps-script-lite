#!/usr/bin/env bash
# Install and remove the latest stable XanMod kernel carrying Google's BBRv3.
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
readonly KERNEL_DOWNLOAD_USER_AGENT='Mozilla/5.0 (compatible; vpsctl-system-kernel/0.6.0)'
readonly KERNEL_XANMOD_KEY_FINGERPRINT='D38D7D1DA1349567ADED882D86F7D09EE734E623'
readonly KERNEL_REPO_LOGICAL='/etc/apt/sources.list.d/vpsctl-xanmod.sources'
readonly KERNEL_KEY_LOGICAL='/etc/apt/keyrings/vpsctl-xanmod-archive-keyring.gpg'
readonly KERNEL_STATE_LOGICAL='/var/lib/vpsctl/system/kernel-bbrv3/state'
readonly KERNEL_INSTALL_TOKEN='INSTALL-XANMOD-BBRV3'
readonly KERNEL_UNINSTALL_TOKEN='REMOVE-XANMOD-BBRV3'

KERNEL_REPO_FILE=''
KERNEL_KEY_FILE=''
KERNEL_STATE_FILE=''
KERNEL_BOOT_DIR=''
KERNEL_MODULES_DIR=''
KERNEL_CPUINFO_FILE=''
KERNEL_ACTION=''
KERNEL_TRACK='auto'
KERNEL_CPU_LEVEL='auto'
KERNEL_CONFIRM_INSTALL=''
KERNEL_CONFIRM_UNINSTALL=''
KERNEL_TRACK_SET=0
KERNEL_CPU_LEVEL_SET=0
KERNEL_INSTALL_CONFIRM_SET=0
KERNEL_UNINSTALL_CONFIRM_SET=0
KERNEL_LOCKED=0
KERNEL_TMP_DIR=''
KERNEL_REPO_CREATED=0
KERNEL_KEY_CREATED=0
KERNEL_OS_ID='unknown'
KERNEL_OS_CODENAME=''
KERNEL_ARCH='unknown'
KERNEL_VIRTUALIZATION='unknown'
KERNEL_RUNNING_RELEASE='unknown'
KERNEL_EFFECTIVE_LEVEL=''
KERNEL_SELECTED_PACKAGE=''
KERNEL_SELECTED_VERSION=''
KERNEL_ARGS=()
KERNEL_XANMOD_PACKAGES=()

kernel_usage() {
    cat <<'EOF'
安装、更新或安全卸载 XanMod 提供的最新稳定 BBRv3 内核。

用法：
  kernel.sh [global-options] [status]
  kernel.sh [global-options] install [--track auto|main|lts]
      [--cpu-level auto|v1|v2|v3]
      [--confirm-install INSTALL-XANMOD-BBRV3]
  kernel.sh [global-options] uninstall
      [--confirm-uninstall REMOVE-XANMOD-BBRV3]

动作：
  status      查看运行内核、XanMod 包、BBR/qdisc、CPU 等级和回退内核
  install     从 XanMod 官方 APT 源安装或更新当前 CPU 可用的最新候选版本
  uninstall   精确卸载全部 XanMod 内核包；至少保留一个可启动的非 XanMod 内核

安装范围：
  仅支持 Debian/Ubuntu amd64；明确拒绝 ARM、容器、WSL、Secure Boot 和
  XanMod 官方已停止支持的发行版。auto 优先稳定 main，缺包时回退 LTS；
  x86-64-v1 只使用 LTS。不会自动重启，也不会执行任何下载到本地的脚本。

安全边界：
  下载的官方仓库密钥必须匹配完整指纹
  D38D7D1DA1349567ADED882D86F7D09EE734E623。
  安装和卸载都需要强确认；--yes 不能绕过。卸载不会运行 autoremove，
  不会删除非 XanMod 内核。操作完成后需由用户自行重启并检查 uname -r。

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

kernel_parse_args() {
    local -a positional=()

    KERNEL_ACTION=''
    KERNEL_TRACK='auto'
    KERNEL_CPU_LEVEL='auto'
    KERNEL_CONFIRM_INSTALL=''
    KERNEL_CONFIRM_UNINSTALL=''
    KERNEL_TRACK_SET=0
    KERNEL_CPU_LEVEL_SET=0
    KERNEL_INSTALL_CONFIRM_SET=0
    KERNEL_UNINSTALL_CONFIRM_SET=0
    while (($# > 0)); do
        case "$1" in
            --track)
                (($# >= 2)) || {
                    kernel_die_usage '--track 缺少参数值'
                    return $?
                }
                KERNEL_TRACK="$2"
                KERNEL_TRACK_SET=1
                shift 2
                ;;
            --cpu-level)
                (($# >= 2)) || {
                    kernel_die_usage '--cpu-level 缺少参数值'
                    return $?
                }
                KERNEL_CPU_LEVEL="$2"
                KERNEL_CPU_LEVEL_SET=1
                shift 2
                ;;
            --confirm-install)
                (($# >= 2)) || {
                    kernel_die_usage '--confirm-install 缺少参数值'
                    return $?
                }
                KERNEL_CONFIRM_INSTALL="$2"
                KERNEL_INSTALL_CONFIRM_SET=1
                shift 2
                ;;
            --confirm-uninstall)
                (($# >= 2)) || {
                    kernel_die_usage '--confirm-uninstall 缺少参数值'
                    return $?
                }
                KERNEL_CONFIRM_UNINSTALL="$2"
                KERNEL_UNINSTALL_CONFIRM_SET=1
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
    if [[ -n "$KERNEL_CONFIRM_INSTALL" && "$KERNEL_CONFIRM_INSTALL" != "$KERNEL_INSTALL_TOKEN" ]]; then
        kernel_die_usage '--confirm-install 的确认短语不正确'
        return $?
    fi
    if [[ -n "$KERNEL_CONFIRM_UNINSTALL" && "$KERNEL_CONFIRM_UNINSTALL" != "$KERNEL_UNINSTALL_TOKEN" ]]; then
        kernel_die_usage '--confirm-uninstall 的确认短语不正确'
        return $?
    fi
}

kernel_init_paths() {
    KERNEL_REPO_FILE="$(vps_cmd_system_path "$KERNEL_REPO_LOGICAL")" || return $?
    KERNEL_KEY_FILE="$(vps_cmd_system_path "$KERNEL_KEY_LOGICAL")" || return $?
    KERNEL_STATE_FILE="$(vps_cmd_system_path "$KERNEL_STATE_LOGICAL")" || return $?
    KERNEL_BOOT_DIR="$(vps_cmd_system_path /boot)" || return $?
    KERNEL_MODULES_DIR="$(vps_cmd_system_path /lib/modules)" || return $?
    KERNEL_CPUINFO_FILE="$(vps_cmd_system_path /proc/cpuinfo)" || return $?
}

kernel_require_safe_paths() {
    local path
    # /lib is commonly a merged-/usr symlink on Debian.  Boot and module paths
    # are read-only probes; only reject links in paths this command writes.
    for path in "$KERNEL_REPO_FILE" "$KERNEL_KEY_FILE" "$KERNEL_STATE_FILE"; do
        vps_cmd_require_no_symlink_components "$path" || return $?
    done
}

kernel_read_os_release() {
    local os_release key value
    os_release="$(vps_cmd_system_path /etc/os-release)" || return $?
    [[ -r "$os_release" ]] || return 0
    while IFS='=' read -r key value; do
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"
        case "$key" in
            ID) [[ "$KERNEL_OS_ID" == unknown ]] && KERNEL_OS_ID="${value,,}" ;;
            VERSION_CODENAME) [[ -z "$KERNEL_OS_CODENAME" ]] && KERNEL_OS_CODENAME="${value,,}" ;;
        esac
    done <"$os_release"
    return 0
}

kernel_load_platform() {
    KERNEL_OS_ID="${VPSCTL_ENV_OS_ID:-unknown}"
    KERNEL_OS_ID="${KERNEL_OS_ID,,}"
    KERNEL_OS_CODENAME="${VPSCTL_ENV_OS_CODENAME:-}"
    KERNEL_OS_CODENAME="${KERNEL_OS_CODENAME,,}"
    kernel_read_os_release || return $?
    KERNEL_ARCH="${VPSCTL_ENV_ARCH:-$(uname -m 2>/dev/null || printf unknown)}"
    KERNEL_ARCH="${KERNEL_ARCH,,}"
    KERNEL_RUNNING_RELEASE="$(uname -r 2>/dev/null || printf unknown)"
    KERNEL_VIRTUALIZATION="${VPSCTL_ENV_VIRTUALIZATION:-unknown}"
    KERNEL_VIRTUALIZATION="${KERNEL_VIRTUALIZATION,,}"
    if [[ "$KERNEL_VIRTUALIZATION" == unknown && "${VPSCTL_TESTING:-0}" != 1 ]] && command -v systemd-detect-virt >/dev/null 2>&1; then
        KERNEL_VIRTUALIZATION="$(systemd-detect-virt 2>/dev/null || printf unknown)"
        [[ "$KERNEL_VIRTUALIZATION" == none ]] && KERNEL_VIRTUALIZATION=bare-metal
    fi
}

kernel_codename_supported() {
    case "${1:-}" in
        bookworm | trixie | forky | sid | noble | plucky | questing | resolute | stonking) return 0 ;;
        *) return 1 ;;
    esac
}

kernel_container_like() {
    case "${1:-}" in
        docker | lxc | container | wsl | openvz | podman | systemd-nspawn) return 0 ;;
        *) return 1 ;;
    esac
}

kernel_secure_boot_enabled() {
    local output efi_directory efivar_directory efivar value
    local known_value=0
    local -a efivars=()
    if [[ "${VPSCTL_TESTING:-0}" != 1 ]] && command -v mokutil >/dev/null 2>&1; then
        output="$(mokutil --sb-state 2>/dev/null || true)"
        case "${output,,}" in
            *'secureboot enabled'*) return 0 ;;
            *'secureboot disabled'*) return 1 ;;
        esac
    fi
    efi_directory="$(vps_cmd_system_path /sys/firmware/efi)" || return 2
    [[ -d "$efi_directory" ]] || return 1
    command -v od >/dev/null 2>&1 || return 2
    efivar_directory="${efi_directory}/efivars"
    [[ -d "$efivar_directory" && -r "$efivar_directory" ]] || return 2
    shopt -s nullglob
    efivars=("$efivar_directory"/SecureBoot-*)
    shopt -u nullglob
    ((${#efivars[@]} > 0)) || return 2
    for efivar in "${efivars[@]}"; do
        [[ -r "$efivar" ]] || continue
        value="$(od -An -j4 -N1 -tu1 -- "$efivar" 2>/dev/null || true)"
        value="${value//[[:space:]]/}"
        case "$value" in
            1) return 0 ;;
            0) known_value=1 ;;
        esac
    done
    ((known_value == 1)) && return 1
    return 2
}

kernel_require_install_platform() {
    [[ "${VPSCTL_ENV_KERNEL_NAME:-Linux}" == Linux ]] || {
        vps_cmd_error 'system kernel 仅支持 Linux'
        return 3
    }
    case "$KERNEL_ARCH" in
        x86_64 | amd64) ;;
        aarch64 | arm64)
            vps_cmd_error 'XanMod 官方没有 ARM64 构建；拒绝执行不受信任的第三方 ARM 安装器'
            return 3
            ;;
        *)
            vps_cmd_error "不支持的架构：$KERNEL_ARCH（仅支持 amd64）"
            return 3
            ;;
    esac
    case "$KERNEL_OS_ID" in debian | ubuntu) ;; *)
        vps_cmd_error "仅支持 Debian/Ubuntu（当前：$KERNEL_OS_ID）"
        return 3
        ;;
    esac
    kernel_codename_supported "$KERNEL_OS_CODENAME" || {
        vps_cmd_error "XanMod 官方 APT 源不支持当前发行版代号：${KERNEL_OS_CODENAME:-未知}"
        return 3
    }
    if kernel_container_like "$KERNEL_VIRTUALIZATION"; then
        vps_cmd_error "${KERNEL_VIRTUALIZATION} 不能替换宿主机内核"
        return 3
    fi
    [[ "${VPSCTL_ENV_PACKAGE_MANAGER:-apt-get}" == apt-get || -z "${VPSCTL_ENV_PACKAGE_MANAGER:-}" ]] || {
        vps_cmd_error 'XanMod 内核安装仅支持 APT/dpkg'
        return 3
    }
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v apt-cache >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
        vps_cmd_error '缺少 apt-get、apt-cache 或 dpkg-query'
        return 3
    fi
    local secure_boot_status=0
    kernel_secure_boot_enabled || secure_boot_status=$?
    case "$secure_boot_status" in
        0)
            vps_cmd_error '检测到 Secure Boot 已启用；XanMod 内核可能无法启动，已拒绝安装'
            return 3
            ;;
        1) ;;
        *)
            vps_cmd_error '无法可靠验证 Secure Boot 状态；为避免安装不可启动的内核，已拒绝安装'
            return 3
            ;;
    esac
}

kernel_require_uninstall_platform() {
    [[ "${VPSCTL_ENV_KERNEL_NAME:-Linux}" == Linux ]] || return 3
    if kernel_container_like "$KERNEL_VIRTUALIZATION"; then
        vps_cmd_error "${KERNEL_VIRTUALIZATION} 不能管理宿主机内核"
        return 3
    fi
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
        vps_cmd_error '卸载 XanMod 需要 apt-get 和 dpkg-query'
        return 3
    fi
}

kernel_detect_psabi_level() {
    local flags flag level=0
    local -a required=()

    [[ -r "$KERNEL_CPUINFO_FILE" ]] || {
        vps_cmd_error '无法读取 /proc/cpuinfo，不能安全选择 CPU 指令集等级'
        return 3
    }
    flags="$(awk -F: '$1 ~ /^[[:space:]]*flags[[:space:]]*$/ {print " " $2 " "; exit}' "$KERNEL_CPUINFO_FILE" 2>/dev/null || true)"
    [[ -n "$flags" ]] || {
        vps_cmd_error '未能读取 x86 CPU flags'
        return 3
    }

    required=(lm cmov cx8 fpu fxsr mmx syscall sse2)
    for flag in "${required[@]}"; do [[ "$flags" == *" $flag "* ]] || {
        printf '0\n'
        return 0
    }; done
    level=1
    required=(cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3)
    for flag in "${required[@]}"; do [[ "$flags" == *" $flag "* ]] || {
        printf '%s\n' "$level"
        return 0
    }; done
    level=2
    required=(avx avx2 bmi1 bmi2 f16c fma movbe xsave)
    for flag in "${required[@]}"; do [[ "$flags" == *" $flag "* ]] || {
        printf '%s\n' "$level"
        return 0
    }; done
    if [[ "$flags" != *' abm '* && "$flags" != *' lzcnt '* ]]; then
        printf '%s\n' "$level"
        return 0
    fi
    printf '3\n'
}

kernel_resolve_cpu_level() {
    local detected requested
    detected="$(kernel_detect_psabi_level)" || return $?
    [[ "$detected" =~ ^[1-3]$ ]] || {
        vps_cmd_error 'CPU 不满足 XanMod x86-64-v1 的最低要求'
        return 3
    }
    if [[ "$KERNEL_CPU_LEVEL" == auto ]]; then
        KERNEL_EFFECTIVE_LEVEL="$detected"
    else
        requested="${KERNEL_CPU_LEVEL#v}"
        ((10#$requested <= 10#$detected)) || {
            vps_cmd_error "CPU 最高支持 x86-64-v${detected}，不能安装 v${requested}"
            return 3
        }
        KERNEL_EFFECTIVE_LEVEL="$requested"
    fi
    if [[ "$KERNEL_TRACK" == main && "$KERNEL_EFFECTIVE_LEVEL" == 1 ]]; then
        vps_cmd_error 'XanMod stable main 不提供 x86-64-v1；请使用 --track lts 或 auto'
        return 3
    fi
}

kernel_candidate_packages() {
    local level="$KERNEL_EFFECTIVE_LEVEL" prefix current minimum
    local -a prefixes=()
    case "$KERNEL_TRACK" in
        auto) prefixes=(linux-xanmod linux-xanmod-lts) ;;
        main) prefixes=(linux-xanmod) ;;
        lts) prefixes=(linux-xanmod-lts) ;;
    esac
    for prefix in "${prefixes[@]}"; do
        minimum=1
        [[ "$prefix" == linux-xanmod ]] && minimum=2
        for ((current = 10#$level; current >= minimum; current--)); do
            printf '%s-x64v%s\n' "$prefix" "$current"
        done
    done
}

kernel_package_candidate_version() {
    local package="$1" output candidate line trimmed version priority source_priority source
    local in_candidate=0 official_at_priority=0 foreign_at_priority=0 candidate_priority=''
    output="$(LC_ALL=C apt-cache policy "$package" 2>/dev/null || true)"
    candidate="$(awk '$1 == "Candidate:" {print $2; exit}' <<<"$output")"
    [[ -n "$candidate" && "$candidate" != '(none)' ]] || return 1
    while IFS= read -r line; do
        trimmed="$(vps_cmd_trim "$line")"
        if [[ "$trimmed" =~ ^(\*\*\*[[:space:]]+)?([^[:space:]]+)[[:space:]]+([0-9]+)$ ]]; then
            version="${BASH_REMATCH[2]}"
            priority="${BASH_REMATCH[3]}"
            if [[ "$version" == "$candidate" ]]; then
                in_candidate=1
                candidate_priority="$priority"
            else
                in_candidate=0
            fi
            continue
        fi
        ((in_candidate == 1)) || continue
        if [[ "$trimmed" =~ ^([0-9]+)[[:space:]]+([^[:space:]]+) ]]; then
            source_priority="${BASH_REMATCH[1]}"
            source="${BASH_REMATCH[2]}"
            [[ "$source_priority" == "$candidate_priority" ]] || continue
            if [[ "$source" == "$KERNEL_XANMOD_REPO_URL" ]]; then
                official_at_priority=1
            elif [[ "$source" != /var/lib/dpkg/status ]]; then
                foreign_at_priority=1
            fi
        fi
    done <<<"$output"
    if ((official_at_priority != 1 || foreign_at_priority != 0)); then
        vps_cmd_warning "$package 的 APT 候选 $candidate 并非唯一来自 $KERNEL_XANMOD_REPO_URL，已拒绝"
        return 1
    fi
    printf '%s\n' "$candidate"
}

kernel_select_package() {
    local package version
    KERNEL_SELECTED_PACKAGE=''
    KERNEL_SELECTED_VERSION=''
    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        if version="$(kernel_package_candidate_version "$package")"; then
            KERNEL_SELECTED_PACKAGE="$package"
            KERNEL_SELECTED_VERSION="$version"
            return 0
        fi
    done < <(kernel_candidate_packages)
    vps_cmd_error "XanMod 仓库没有适配 x86-64-v${KERNEL_EFFECTIVE_LEVEL} / ${KERNEL_TRACK} 的内核元包"
    return 3
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

kernel_package_is_installed() {
    local expected="$1" installed
    kernel_query_xanmod_packages installed || return $?
    for installed in "${KERNEL_XANMOD_PACKAGES[@]}"; do
        [[ "${installed%%:*}" == "$expected" ]] && return 0
    done
    return 1
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

kernel_ensure_install_dependencies() {
    vps_cmd_ensure_tools system-kernel curl gpg awk install mktemp flock od || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info '依赖安装仍处于演练计划；请安装后重新运行内核安装'
        return 64
    fi
}

kernel_ensure_uninstall_dependencies() {
    vps_cmd_ensure_tools system-kernel flock || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info '依赖安装仍处于演练计划；请安装后重新运行卸载'
        return 64
    fi
}

kernel_confirm_install_action() {
    [[ "${VPSCTL_DRY_RUN:-0}" == 1 || "$KERNEL_CONFIRM_INSTALL" == "$KERNEL_INSTALL_TOKEN" ]] && return 0
    vps_cmd_is_interactive || {
        vps_cmd_error "非交互安装必须提供 --confirm-install $KERNEL_INSTALL_TOKEN"
        return 3
    }
    vps_cmd_warning '内核安装可能造成重启后无法启动；请先确认控制台或救援入口可用'
    vps_cmd_confirm_token '确认安装/更新 XanMod BBRv3 内核。' "$KERNEL_INSTALL_TOKEN" || {
        vps_cmd_warning '已取消内核安装'
        return 130
    }
}

kernel_confirm_uninstall_action() {
    [[ "${VPSCTL_DRY_RUN:-0}" == 1 || "$KERNEL_CONFIRM_UNINSTALL" == "$KERNEL_UNINSTALL_TOKEN" ]] && return 0
    vps_cmd_is_interactive || {
        vps_cmd_error "非交互卸载必须提供 --confirm-uninstall $KERNEL_UNINSTALL_TOKEN"
        return 3
    }
    vps_cmd_confirm_token '确认卸载全部 XanMod 内核包。' "$KERNEL_UNINSTALL_TOKEN" || {
        vps_cmd_warning '已取消内核卸载'
        return 130
    }
}

kernel_rollback_new_repository() {
    [[ "$KERNEL_REPO_CREATED" == 0 ]] || rm -f -- "$KERNEL_REPO_FILE"
    [[ "$KERNEL_KEY_CREATED" == 0 ]] || rm -f -- "$KERNEL_KEY_FILE"
}

kernel_prepare_repository() {
    local key_asc key_gpg fingerprint repo_directory key_directory

    if [[ -e "$KERNEL_REPO_FILE" ]] && ! kernel_repo_is_managed; then
        vps_cmd_error "$KERNEL_REPO_LOGICAL 已存在但不属于 vpsctl，拒绝覆盖"
        return 10
    fi
    if [[ -e "$KERNEL_KEY_FILE" ]]; then
        [[ -f "$KERNEL_KEY_FILE" && ! -L "$KERNEL_KEY_FILE" ]] || {
            vps_cmd_error "$KERNEL_KEY_LOGICAL 不是普通文件，拒绝覆盖"
            return 10
        }
        fingerprint="$(kernel_primary_key_fingerprint "$KERNEL_KEY_FILE" 2>/dev/null || true)"
        [[ "$fingerprint" == "$KERNEL_XANMOD_KEY_FINGERPRINT" ]] || {
            vps_cmd_error "$KERNEL_KEY_LOGICAL 的密钥指纹异常，拒绝覆盖"
            return 10
        }
    fi

    [[ -e "$KERNEL_REPO_FILE" ]] || KERNEL_REPO_CREATED=1
    [[ -e "$KERNEL_KEY_FILE" ]] || KERNEL_KEY_CREATED=1
    repo_directory="${KERNEL_REPO_FILE%/*}"
    key_directory="${KERNEL_KEY_FILE%/*}"
    vps_cmd_run install -d -m 0755 -- "$repo_directory" "$key_directory" "${KERNEL_STATE_FILE%/*}" || return 20

    KERNEL_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-kernel.XXXXXX")" || return 20
    chmod 0700 -- "$KERNEL_TMP_DIR" || return 20
    key_asc="${KERNEL_TMP_DIR}/archive.key"
    key_gpg="${KERNEL_TMP_DIR}/archive.gpg"
    vps_cmd_run curl -fsSL --user-agent "$KERNEL_DOWNLOAD_USER_AGENT" --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 120 --retry 2 \
        -o "$key_asc" "$KERNEL_XANMOD_KEY_URL" || return 20
    fingerprint="$(kernel_primary_key_fingerprint "$key_asc" 2>/dev/null || true)"
    [[ "$fingerprint" == "$KERNEL_XANMOD_KEY_FINGERPRINT" ]] || {
        vps_cmd_error "XanMod 仓库密钥指纹不匹配（得到：${fingerprint:-无法读取}）"
        return 20
    }
    vps_cmd_run gpg --batch --yes --dearmor --output "$key_gpg" "$key_asc" || return 20
    vps_cmd_atomic_write "$KERNEL_KEY_LOGICAL" 0644 <"$key_gpg" || return 20
    {
        printf '%s\n' "$KERNEL_MANAGED_MARKER"
        printf 'Types: deb\n'
        printf 'URIs: %s\n' "$KERNEL_XANMOD_REPO_URL"
        printf 'Suites: %s\n' "$KERNEL_OS_CODENAME"
        printf 'Components: main\n'
        printf 'Architectures: amd64\n'
        printf 'Signed-By: %s\n' "$KERNEL_KEY_LOGICAL"
    } | vps_cmd_atomic_write "$KERNEL_REPO_LOGICAL" 0644 || return 20
}

kernel_write_state() {
    local package="$1" candidate="$2"
    {
        printf '%s\n' "$KERNEL_MANAGED_MARKER"
        printf 'schema=1\n'
        printf 'provider=xanmod\n'
        printf 'package=%s\n' "$package"
        printf 'candidate=%s\n' "$candidate"
        printf 'suite=%s\n' "$KERNEL_OS_CODENAME"
        printf 'track=%s\n' "$KERNEL_TRACK"
        printf 'cpu_level=v%s\n' "$KERNEL_EFFECTIVE_LEVEL"
        printf 'key_fingerprint=%s\n' "$KERNEL_XANMOD_KEY_FINGERPRINT"
    } | vps_cmd_atomic_write "$KERNEL_STATE_LOGICAL" 0600
}

kernel_refresh_bootloader() {
    if command -v update-grub >/dev/null 2>&1; then
        vps_cmd_run update-grub || return 20
    else
        vps_cmd_warning '未找到 update-grub；将依赖内核包的启动器钩子，请在重启前检查启动项'
    fi
}

kernel_join_values() {
    local value joined=''
    for value in "$@"; do
        [[ -z "$joined" ]] || joined+=', '
        joined+="$value"
    done
    printf '%s' "$joined"
}

kernel_status() {
    local running_state='未运行' installed_state='未安装' repo_state='未受管' bbr='未知' qdisc='未知'
    local cpu_level='不可用' fallback_state='无' packages_state='无'
    local installed_style='muted' fallback_style='error'
    local -a packages=() fallbacks=()
    local proc_path query_status

    case "$KERNEL_OS_ID" in
        debian | ubuntu)
            if command -v dpkg-query >/dev/null 2>&1; then
                if kernel_query_xanmod_packages installed; then
                    packages=("${KERNEL_XANMOD_PACKAGES[@]}")
                else
                    query_status=$?
                    return "$query_status"
                fi
            else
                installed_state='不可用（缺少 dpkg-query）'
                packages_state='无法读取 Debian/Ubuntu 软件包状态'
            fi
            ;;
        *)
            installed_state='不适用（仅 Debian/Ubuntu）'
            packages_state='当前平台不管理 XanMod 软件包'
            ;;
    esac
    mapfile -t fallbacks < <(kernel_fallback_releases)
    ((${#packages[@]} == 0)) || {
        installed_state="已安装（${#packages[@]} 个包）"
        packages_state="$(kernel_join_values "${packages[@]}")"
        installed_style='success'
    }
    [[ "${KERNEL_RUNNING_RELEASE,,}" != *xanmod* ]] || running_state='正在运行 XanMod BBRv3'
    kernel_repo_is_managed && repo_state='vpsctl 已配置'
    ((${#fallbacks[@]} == 0)) || {
        fallback_state="$(kernel_join_values "${fallbacks[@]}")"
        fallback_style='success'
    }
    cpu_level="$(kernel_detect_psabi_level 2>/dev/null || printf '不可用')"
    [[ "$cpu_level" =~ ^[1-3]$ ]] && cpu_level="x86-64-v${cpu_level}"
    proc_path="$(vps_cmd_system_path /proc/sys/net/ipv4/tcp_congestion_control)"
    [[ ! -r "$proc_path" ]] || IFS= read -r bbr <"$proc_path" || true
    proc_path="$(vps_cmd_system_path /proc/sys/net/core/default_qdisc)"
    [[ ! -r "$proc_path" ]] || IFS= read -r qdisc <"$proc_path" || true

    vps_cmd_status '当前内核' "$KERNEL_RUNNING_RELEASE" normal
    vps_cmd_status 'XanMod 运行态' "$running_state" "$([[ "$running_state" == 未运行 ]] && printf muted || printf success)"
    vps_cmd_status 'XanMod 包' "$installed_state" "$installed_style"
    vps_cmd_status '已装包明细' "$packages_state" muted
    vps_cmd_status '拥塞控制' "$bbr" "$([[ "$bbr" == bbr ]] && printf success || printf warning)"
    vps_cmd_status '默认 qdisc' "$qdisc" "$([[ "$qdisc" == fq ]] && printf success || printf warning)"
    vps_cmd_status 'CPU 等级' "$cpu_level" normal
    vps_cmd_status '回退内核' "$fallback_state" "$fallback_style"
    vps_cmd_status 'XanMod 软件源' "$repo_state" "$([[ "$repo_state" == vpsctl* ]] && printf success || printf muted)"
}

kernel_dry_run_install_plan() {
    local preferred candidates
    local -a candidate_list=()
    mapfile -t candidate_list < <(kernel_candidate_packages)
    ((${#candidate_list[@]} > 0)) || {
        vps_cmd_error "${KERNEL_TRACK} 没有适配 x86-64-v${KERNEL_EFFECTIVE_LEVEL} 的候选元包"
        return 3
    }
    preferred="${candidate_list[0]}"
    candidates="$(kernel_join_values "${candidate_list[@]}")"
    vps_cmd_info "将按顺序查询候选元包：$candidates"
    vps_cmd_run install -d -m 0755 -- "${KERNEL_REPO_FILE%/*}" "${KERNEL_KEY_FILE%/*}" "${KERNEL_STATE_FILE%/*}"
    vps_cmd_run curl -fsSL --user-agent "$KERNEL_DOWNLOAD_USER_AGENT" --proto '=https' --tlsv1.2 -o /tmp/vpsctl-xanmod-archive.key "$KERNEL_XANMOD_KEY_URL"
    vps_cmd_run gpg --batch --with-colons --show-keys /tmp/vpsctl-xanmod-archive.key
    vps_cmd_info "密钥必须匹配完整指纹 $KERNEL_XANMOD_KEY_FINGERPRINT"
    vps_cmd_info "将写入受管 DEB822 软件源：$KERNEL_REPO_LOGICAL（suite=$KERNEL_OS_CODENAME）"
    vps_cmd_run apt-get update
    vps_cmd_run apt-cache policy "$preferred"
    vps_cmd_run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$preferred"
    command -v update-grub >/dev/null 2>&1 && vps_cmd_run update-grub
    vps_cmd_info '演练不会写文件、下载密钥、刷新 APT 或安装内核'
}

kernel_install() (
    local dependency_status package
    kernel_require_install_platform || return $?
    kernel_resolve_cpu_level || return $?
    if kernel_ensure_install_dependencies; then
        :
    else
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
    vps_cmd_info '正在刷新 XanMod 官方 APT 元数据'
    if ! vps_cmd_run apt-get update; then
        kernel_rollback_new_repository
        vps_cmd_error 'APT 元数据刷新失败；已撤销本次新建的软件源文件'
        return 20
    fi
    kernel_select_package || {
        dependency_status=$?
        kernel_rollback_new_repository
        return "$dependency_status"
    }
    package="$KERNEL_SELECTED_PACKAGE"
    vps_cmd_info "选择 $package，仓库候选版本 $KERNEL_SELECTED_VERSION"
    if ! vps_cmd_run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$package"; then
        vps_cmd_error "内核包安装失败；保留受管软件源以便检查或重试：$KERNEL_REPO_LOGICAL"
        return 20
    fi
    if ! kernel_package_is_installed "$package"; then
        vps_cmd_error 'APT 已返回成功，但未能验证 XanMod 元包处于已安装状态'
        return 30
    fi
    kernel_write_state "$package" "$KERNEL_SELECTED_VERSION" || {
        vps_cmd_error '内核已安装，但写入 vpsctl 状态失败'
        return 30
    }
    kernel_refresh_bootloader || {
        vps_cmd_error '内核已安装，但启动菜单刷新失败；重启前必须人工检查'
        return 30
    }
    vps_cmd_success "已安装/更新最新 XanMod BBRv3 候选：$package ($KERNEL_SELECTED_VERSION)"
    vps_cmd_warning '当前运行内核尚未改变。请确认控制台/救援入口后自行 reboot，再用 uname -r 验证 xanmod 后缀'
)

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

kernel_uninstall() (
    local dependency_status cleanup_status=0
    local -a packages=() fallbacks=() remaining=()
    kernel_require_uninstall_platform || return $?
    if kernel_ensure_uninstall_dependencies; then
        :
    else
        dependency_status=$?
        ((dependency_status == 64)) && return 0
        return "$dependency_status"
    fi
    vps_cmd_require_root || return $?
    kernel_take_lock || return $?
    kernel_query_xanmod_packages purge || return $?
    packages=("${KERNEL_XANMOD_PACKAGES[@]}")
    if ((${#packages[@]} == 0)); then
        kernel_cleanup_owned_files || cleanup_status=$?
        ((cleanup_status == 0)) || return "$cleanup_status"
        if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
            vps_cmd_info '演练：未检测到 XanMod 内核包；只展示受管文件清理计划'
        else
            vps_cmd_success '未检测到 XanMod 内核包；受管软件源已清理'
        fi
        return 0
    fi
    mapfile -t fallbacks < <(kernel_fallback_releases)
    ((${#fallbacks[@]} > 0)) || {
        vps_cmd_error '未找到同时具有 vmlinuz、initrd 和 modules 的非 XanMod 回退内核，拒绝卸载'
        vps_cmd_error '请先安装发行版内核（Debian: linux-image-amd64；Ubuntu: linux-image-generic）'
        return 3
    }
    vps_cmd_warning "将卸载：$(kernel_join_values "${packages[@]}")"
    vps_cmd_info "已验证回退内核：$(kernel_join_values "${fallbacks[@]}")"
    if [[ "${KERNEL_RUNNING_RELEASE,,}" == *xanmod* ]]; then
        vps_cmd_warning '当前仍在运行 XanMod；卸载后本次会话可继续，但下次启动必须使用回退内核'
    fi
    kernel_confirm_uninstall_action || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages[@]}"
        command -v update-grub >/dev/null 2>&1 && vps_cmd_run update-grub
        kernel_cleanup_owned_files || cleanup_status=$?
        ((cleanup_status == 0)) || return "$cleanup_status"
        vps_cmd_info '演练不会卸载软件包或删除受管文件'
        return 0
    fi
    if ! vps_cmd_run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages[@]}"; then
        vps_cmd_error 'XanMod 包卸载失败；软件源和状态已保留，便于检查后重试'
        return 20
    fi
    kernel_query_xanmod_packages purge || return $?
    remaining=("${KERNEL_XANMOD_PACKAGES[@]}")
    if ((${#remaining[@]} > 0)); then
        vps_cmd_error "仍有 XanMod 包未清理：$(kernel_join_values "${remaining[@]}")"
        return 30
    fi
    kernel_refresh_bootloader || {
        vps_cmd_error 'XanMod 包已卸载，但启动菜单刷新失败；重启前必须人工修复'
        return 30
    }
    kernel_cleanup_owned_files || cleanup_status=$?
    ((cleanup_status == 0)) || return "$cleanup_status"
    vps_cmd_success 'XanMod BBRv3 内核包已全部卸载；非 XanMod 回退内核保持不变'
    vps_cmd_warning '请在重启前复核启动项；重启后用 uname -r 确认已切回发行版内核'
)

kernel_menu_snapshot() {
    local count=0
    if kernel_query_xanmod_packages installed; then
        count="${#KERNEL_XANMOD_PACKAGES[@]}"
    else
        printf '当前 %s · XanMod 包状态未知' "$KERNEL_RUNNING_RELEASE"
        return 0
    fi
    printf '当前 %s · XanMod %s' "$KERNEL_RUNNING_RELEASE" "$([[ "$count" == 0 ]] && printf '未安装' || printf '已装 %s 包' "$count")"
}

kernel_interactive_menu() {
    local choice prompt_status action_status snapshot status=0
    while true; do
        snapshot="$(kernel_menu_snapshot)"
        printf ' %s\n' "$snapshot" >&2
        choice="$(vps_cmd_prompt_select \
            '系统内核管理' status \
            status '查看内核状态' \
            install '安装/更新最新 BBRv3 内核' \
            uninstall '卸载 BBRv3 内核' \
            quit '退出')" || {
            prompt_status=$?
            ((prompt_status == 130)) && return "$status"
            return "$prompt_status"
        }
        case "$choice" in
            status) kernel_status || status=$? ;;
            install)
                kernel_install || {
                    action_status=$?
                    ((action_status == 130)) || status=$action_status
                }
                ;;
            uninstall)
                kernel_uninstall || {
                    action_status=$?
                    ((action_status == 130)) || status=$action_status
                }
                ;;
            quit) return "$status" ;;
            *)
                vps_cmd_error "交互选择返回未知动作：$choice"
                return 70
                ;;
        esac
    done
}

kernel_validate_action_options() {
    case "$KERNEL_ACTION" in
        '')
            ((KERNEL_TRACK_SET == 0 && KERNEL_CPU_LEVEL_SET == 0 && KERNEL_INSTALL_CONFIRM_SET == 0 && KERNEL_UNINSTALL_CONFIRM_SET == 0)) || {
                kernel_die_usage '无动作时不能使用动作选项'
                return $?
            }
            ;;
        status | help)
            ((KERNEL_TRACK_SET == 0 && KERNEL_CPU_LEVEL_SET == 0 && KERNEL_INSTALL_CONFIRM_SET == 0 && KERNEL_UNINSTALL_CONFIRM_SET == 0)) || {
                kernel_die_usage "$KERNEL_ACTION 不接受动作选项"
                return $?
            }
            ;;
        install)
            ((KERNEL_UNINSTALL_CONFIRM_SET == 0)) || {
                kernel_die_usage 'install 不接受 --confirm-uninstall'
                return $?
            }
            ;;
        uninstall)
            ((KERNEL_TRACK_SET == 0 && KERNEL_CPU_LEVEL_SET == 0 && KERNEL_INSTALL_CONFIRM_SET == 0)) || {
                kernel_die_usage 'uninstall 只接受 --confirm-uninstall'
                return $?
            }
            ;;
        *)
            kernel_die_usage "未知操作：$KERNEL_ACTION"
            return $?
            ;;
    esac
}

kernel_main() {
    local init_status
    if vps_cmd_init system-kernel "$KERNEL_PROJECT_ROOT"; then :; else
        init_status=$?
        return "$init_status"
    fi
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
        uninstall) kernel_uninstall ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    kernel_main "$@"
fi
