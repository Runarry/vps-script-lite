#!/usr/bin/env bash
# Kernel provider, platform, and package-candidate helpers.
# shellcheck disable=SC2034

declare -Ag KERNEL_INSTALL_EXPECTED_VERSIONS=()

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
            VERSION_ID) [[ -z "$KERNEL_OS_VERSION_ID" ]] && KERNEL_OS_VERSION_ID="$value" ;;
            VERSION) [[ -z "$KERNEL_OS_VERSION" ]] && KERNEL_OS_VERSION="$value" ;;
            VERSION_CODENAME) [[ -z "$KERNEL_OS_CODENAME" ]] && KERNEL_OS_CODENAME="${value,,}" ;;
        esac
    done <"$os_release"
    return 0
}

kernel_load_platform() {
    KERNEL_OS_ID="${VPSCTL_ENV_OS_ID:-unknown}"
    KERNEL_OS_ID="${KERNEL_OS_ID,,}"
    KERNEL_OS_VERSION_ID="${VPSCTL_ENV_OS_VERSION_ID:-}"
    KERNEL_OS_VERSION="${VPSCTL_ENV_OS_VERSION:-}"
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
    return 0
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

_kernel_require_common_platform() {
    [[ "${VPSCTL_ENV_KERNEL_NAME:-Linux}" == Linux ]] || {
        vps_cmd_error 'system kernel 仅支持 Linux'
        return 3
    }
    case "$KERNEL_ARCH" in
        x86_64 | amd64) ;;
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
    if kernel_container_like "$KERNEL_VIRTUALIZATION"; then
        vps_cmd_error "${KERNEL_VIRTUALIZATION} 不能替换宿主机内核"
        return 3
    fi
    [[ "${VPSCTL_ENV_PACKAGE_MANAGER:-apt-get}" == apt-get || -z "${VPSCTL_ENV_PACKAGE_MANAGER:-}" ]] || {
        vps_cmd_error '内核管理仅支持 APT/dpkg'
        return 3
    }
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
        vps_cmd_error '缺少 apt-get 或 dpkg-query'
        return 3
    fi
}

_kernel_require_provider_platform() {
    case "${KERNEL_TYPE:-xanmod}" in
        xanmod)
            kernel_codename_supported "$KERNEL_OS_CODENAME" || {
                vps_cmd_error "XanMod 官方 APT 源不支持当前发行版代号：${KERNEL_OS_CODENAME:-未知}"
                return 3
            }
            ;;
        official) ;;
        cloud)
            [[ "$KERNEL_OS_ID" == debian ]] || {
                vps_cmd_error 'cloud 内核类型仅支持 Debian'
                return 3
            }
            ;;
        hwe)
            [[ "$KERNEL_OS_ID" == ubuntu ]] || {
                vps_cmd_error 'HWE 内核类型仅支持 Ubuntu'
                return 3
            }
            [[ "$KERNEL_OS_VERSION" == *LTS* ]] || {
                vps_cmd_error 'HWE 内核仅支持 Ubuntu LTS 版本'
                return 3
            }
            [[ "$KERNEL_OS_VERSION_ID" =~ ^[0-9]{2}\.[0-9]{2}$ ]] || {
                vps_cmd_error "无法从 VERSION_ID 生成安全的 HWE 元包名：${KERNEL_OS_VERSION_ID:-未知}"
                return 3
            }
            ;;
        *)
            vps_cmd_error "未知内核类型：${KERNEL_TYPE:-}"
            return 3
            ;;
    esac
}

kernel_require_install_platform() {
    local secure_boot_status=0
    _kernel_require_common_platform || return $?
    command -v apt-cache >/dev/null 2>&1 || {
        vps_cmd_error '缺少 apt-cache'
        return 3
    }
    _kernel_require_provider_platform || return $?
    [[ "${KERNEL_TYPE:-xanmod}" == xanmod ]] || return 0
    kernel_secure_boot_enabled || secure_boot_status=$?
    case "$secure_boot_status" in
        0)
            vps_cmd_error '检测到 Secure Boot 已启用；XanMod 内核可能无法启动，已拒绝安装'
            return 3
            ;;
        1) return 0 ;;
        *)
            vps_cmd_error '无法可靠验证 Secure Boot 状态；为避免安装不可启动的内核，已拒绝安装'
            return 3
            ;;
    esac
}

kernel_require_uninstall_platform() {
    _kernel_require_common_platform || return $?
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
    [[ "${KERNEL_TYPE:-xanmod}" == xanmod ]] || {
        KERNEL_EFFECTIVE_LEVEL=''
        return 0
    }
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
    local level prefix current minimum
    local -a prefixes=()
    case "${KERNEL_TYPE:-xanmod}" in
        official)
            case "$KERNEL_OS_ID" in
                debian) printf 'linux-image-amd64\n' ;;
                ubuntu) printf 'linux-generic\n' ;;
                *) return 3 ;;
            esac
            return 0
            ;;
        cloud)
            [[ "$KERNEL_OS_ID" == debian ]] || return 3
            printf 'linux-image-cloud-amd64\n'
            return 0
            ;;
        hwe)
            [[ "$KERNEL_OS_ID" == ubuntu && "$KERNEL_OS_VERSION" == *LTS* && "$KERNEL_OS_VERSION_ID" =~ ^[0-9]{2}\.[0-9]{2}$ ]] || return 3
            printf 'linux-generic-hwe-%s\n' "$KERNEL_OS_VERSION_ID"
            return 0
            ;;
        xanmod) ;;
        *) return 3 ;;
    esac

    level="$KERNEL_EFFECTIVE_LEVEL"
    case "$KERNEL_TRACK" in
        auto) prefixes=(linux-xanmod linux-xanmod-lts) ;;
        main) prefixes=(linux-xanmod) ;;
        lts) prefixes=(linux-xanmod-lts) ;;
        *) return 3 ;;
    esac
    for prefix in "${prefixes[@]}"; do
        minimum=1
        [[ "$prefix" == linux-xanmod ]] && minimum=2
        for ((current = 10#$level; current >= minimum; current--)); do
            printf '%s-x64v%s\n' "$prefix" "$current"
        done
    done
}

_kernel_official_index_descriptions() {
    local output line key value description='' identifier='' trusted='' codename='' suite='' release='' origin='' label=''
    local expected_origin expected_label_pattern
    if ! output="$(LC_ALL=C apt-get indextargets 2>&1)"; then
        vps_cmd_error "APT 索引元数据查询失败：$output"
        return 20
    fi
    case "$KERNEL_OS_ID" in
        debian)
            expected_origin=Debian
            expected_label_pattern='Debian|Debian-Security'
            ;;
        ubuntu)
            expected_origin=Ubuntu
            expected_label_pattern=Ubuntu
            ;;
        *) return 3 ;;
    esac
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            if [[ "$identifier" == Packages && "$trusted" == yes && "$origin" == "$expected_origin" && "$label" =~ ^($expected_label_pattern)$ ]]; then
                if [[ "$KERNEL_OS_ID" == ubuntu ]]; then
                    case "$suite" in
                        "$KERNEL_OS_CODENAME" | "$KERNEL_OS_CODENAME-updates" | "$KERNEL_OS_CODENAME-security") ;;
                        *) suite='' ;;
                    esac
                    case "$release" in
                        "$KERNEL_OS_CODENAME" | "$KERNEL_OS_CODENAME-updates" | "$KERNEL_OS_CODENAME-security") ;;
                        *) release='' ;;
                    esac
                    [[ "$codename" == "$KERNEL_OS_CODENAME" && -n "$suite" && -n "$release" && -n "$description" ]] && printf '%s\n' "$description"
                else
                    case "$codename" in
                        "$KERNEL_OS_CODENAME" | "$KERNEL_OS_CODENAME-updates" | "$KERNEL_OS_CODENAME-security")
                            [[ -n "$description" ]] && printf '%s\n' "$description"
                            ;;
                    esac
                fi
            fi
            description=''
            identifier=''
            trusted=''
            codename=''
            suite=''
            release=''
            origin=''
            label=''
            continue
        fi
        key="${line%%:*}"
        value="${line#*:}"
        value="${value# }"
        case "$key" in
            Description) description="$value" ;;
            Identifier) identifier="$value" ;;
            Trusted) trusted="${value,,}" ;;
            Codename) codename="${value,,}" ;;
            Suite) suite="${value,,}" ;;
            Release) release="${value,,}" ;;
            Origin) origin="$value" ;;
            Label) label="$value" ;;
        esac
    done <<<"${output}"$'\n'
}

_kernel_xanmod_index_descriptions() {
    local output line key value description='' identifier='' trusted='' codename='' site='' signed_by='' fingerprint
    if ! output="$(LC_ALL=C apt-get indextargets 2>&1)"; then
        vps_cmd_error "APT 索引元数据查询失败：$output"
        return 20
    fi
    fingerprint="$(kernel_primary_key_fingerprint "$KERNEL_KEY_FILE" 2>/dev/null || true)"
    [[ "$fingerprint" == "$KERNEL_XANMOD_KEY_FINGERPRINT" ]] || {
        vps_cmd_error 'XanMod APT 源密钥指纹无法验证'
        return 30
    }
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            if [[ "$identifier" == Packages && "$trusted" == yes && "$codename" == "$KERNEL_OS_CODENAME" && "$site" == "$KERNEL_XANMOD_REPO_URL" && "$signed_by" == "$KERNEL_KEY_LOGICAL" && -n "$description" ]]; then
                printf '%s\n' "$description"
            fi
            description=''
            identifier=''
            trusted=''
            codename=''
            site=''
            signed_by=''
            continue
        fi
        key="${line%%:*}"
        value="${line#*:}"
        value="${value# }"
        case "$key" in
            Description) description="$value" ;;
            Identifier) identifier="$value" ;;
            Trusted) trusted="${value,,}" ;;
            Codename) codename="${value,,}" ;;
            Site) site="${value%/}" ;;
            Signed-By) signed_by="$value" ;;
        esac
    done <<<"${output}"$'\n'
}

_kernel_xanmod_candidate_version() {
    local package="$1" output candidate line trimmed version source
    local in_candidate=0 official_source=0 foreign_source=0
    if ! output="$(LC_ALL=C apt-cache policy "$package" 2>&1)"; then
        vps_cmd_error "APT 候选查询失败：$output"
        return 20
    fi
    candidate="$(awk '$1 == "Candidate:" {print $2; exit}' <<<"$output")"
    [[ -n "$candidate" && "$candidate" != '(none)' ]] || return 1
    while IFS= read -r line; do
        trimmed="$(vps_cmd_trim "$line")"
        if [[ "$trimmed" =~ ^(\*\*\*[[:space:]]+)?([^[:space:]]+)[[:space:]]+([0-9]+)$ ]]; then
            version="${BASH_REMATCH[2]}"
            [[ "$version" == "$candidate" ]] && in_candidate=1 || in_candidate=0
            continue
        fi
        ((in_candidate == 1)) || continue
        if [[ "$trimmed" =~ ^([0-9]+)[[:space:]]+([^[:space:]]+) ]]; then
            source="${BASH_REMATCH[2]}"
            if [[ "$source" == "$KERNEL_XANMOD_REPO_URL" ]]; then
                official_source=1
            elif [[ "$source" != /var/lib/dpkg/status ]]; then
                foreign_source=1
            fi
        fi
    done <<<"$output"
    if ((official_source != 1 || foreign_source != 0)); then
        vps_cmd_warning "$package 的 APT 候选 $candidate 并非唯一来自 $KERNEL_XANMOD_REPO_URL，已拒绝"
        return 1
    fi
    printf '%s\n' "$candidate"
}

_kernel_distribution_candidate_version() {
    local package="$1" output candidate allowed_output status line trimmed version descriptor
    local in_candidate=0 official_source=0 foreign_source=0
    local -a allowed_descriptions=()
    if ! output="$(LC_ALL=C apt-cache policy "$package" 2>&1)"; then
        vps_cmd_error "APT 候选查询失败：$output"
        return 20
    fi
    candidate="$(awk '$1 == "Candidate:" {print $2; exit}' <<<"$output")"
    [[ -n "$candidate" && "$candidate" != '(none)' ]] || return 1
    if allowed_output="$(_kernel_official_index_descriptions)"; then
        mapfile -t allowed_descriptions <<<"$allowed_output"
    else
        status=$?
        return "$status"
    fi
    while IFS= read -r line; do
        trimmed="$(vps_cmd_trim "$line")"
        if [[ "$trimmed" =~ ^(\*\*\*[[:space:]]+)?([^[:space:]]+)[[:space:]]+([0-9]+)$ ]]; then
            version="${BASH_REMATCH[2]}"
            [[ "$version" == "$candidate" ]] && in_candidate=1 || in_candidate=0
            continue
        fi
        ((in_candidate == 1)) || continue
        [[ "$trimmed" =~ ^[0-9]+[[:space:]]+(.+)$ ]] || continue
        descriptor="${BASH_REMATCH[1]}"
        [[ "$descriptor" == /var/lib/dpkg/status ]] && continue
        local allowed matched=0
        for allowed in "${allowed_descriptions[@]}"; do
            if [[ "$descriptor" == "$allowed" ]]; then
                matched=1
                break
            fi
        done
        if ((matched == 1)); then
            official_source=1
        else
            foreign_source=1
        fi
    done <<<"$output"
    if ((official_source != 1 || foreign_source != 0)); then
        vps_cmd_warning "$package 的 APT 候选 $candidate 混入非本机发行版可信索引，已拒绝"
        return 1
    fi
    printf '%s\n' "$candidate"
}

kernel_package_candidate_version() {
    case "${KERNEL_TYPE:-xanmod}" in
        xanmod) _kernel_xanmod_candidate_version "$1" ;;
        official | cloud | hwe) _kernel_distribution_candidate_version "$1" ;;
        *) return 3 ;;
    esac
}

kernel_select_package() {
    local package version status candidates
    KERNEL_SELECTED_PACKAGE=''
    KERNEL_SELECTED_VERSION=''
    if candidates="$(kernel_candidate_packages)"; then
        :
    else
        status=$?
        return "$status"
    fi
    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        if version="$(kernel_package_candidate_version "$package")"; then
            KERNEL_SELECTED_PACKAGE="$package"
            KERNEL_SELECTED_VERSION="$version"
            return 0
        else
            status=$?
            ((status == 20)) && return 20
        fi
    done <<<"$candidates"
    if [[ "${KERNEL_TYPE:-xanmod}" == xanmod ]]; then
        vps_cmd_error "XanMod 仓库没有适配 x86-64-v${KERNEL_EFFECTIVE_LEVEL} / ${KERNEL_TRACK} 的内核元包"
    else
        vps_cmd_error "发行版可信 APT 源没有 ${KERNEL_TYPE} 内核元包候选"
    fi
    return 3
}

_kernel_validate_policy_version_sources() {
    local package="$1" target_version="$2" mode="$3" distribution_output="$4" xanmod_output="$5"
    local output line trimmed version descriptor allowed matched source_count=0 foreign_source=0
    local in_target=0 distribution_source=0 xanmod_source=0
    local -a distribution_descriptions=() xanmod_descriptions=()
    mapfile -t distribution_descriptions <<<"$distribution_output"
    mapfile -t xanmod_descriptions <<<"$xanmod_output"
    if ! output="$(LC_ALL=C apt-cache policy "$package" 2>&1)"; then
        vps_cmd_error "APT 版本来源查询失败：$output"
        return 20
    fi
    while IFS= read -r line; do
        trimmed="$(vps_cmd_trim "$line")"
        if [[ "$trimmed" =~ ^(\*\*\*[[:space:]]+)?([^[:space:]]+)[[:space:]]+([0-9]+)$ ]]; then
            version="${BASH_REMATCH[2]}"
            [[ "$version" == "$target_version" ]] && in_target=1 || in_target=0
            continue
        fi
        ((in_target == 1)) || continue
        [[ "$trimmed" =~ ^[0-9]+[[:space:]]+(.+)$ ]] || continue
        descriptor="${BASH_REMATCH[1]}"
        [[ "$descriptor" == /var/lib/dpkg/status ]] && continue
        source_count=$((source_count + 1))
        matched=0
        for allowed in "${distribution_descriptions[@]}"; do
            if [[ -n "$allowed" && "$descriptor" == "$allowed" ]]; then
                distribution_source=1
                matched=1
                break
            fi
        done
        if ((matched == 0)); then
            for allowed in "${xanmod_descriptions[@]}"; do
                if [[ -n "$allowed" && "$descriptor" == "$allowed" ]]; then
                    xanmod_source=1
                    matched=1
                    break
                fi
            done
        fi
        ((matched == 1)) || foreign_source=1
    done <<<"$output"
    case "$mode" in
        distribution)
            ((source_count > 0 && distribution_source == 1 && xanmod_source == 0 && foreign_source == 0))
            ;;
        xanmod)
            ((source_count > 0 && distribution_source == 0 && xanmod_source == 1 && foreign_source == 0))
            ;;
        distribution-or-xanmod)
            ((source_count > 0 && (distribution_source == 1 || xanmod_source == 1) && foreign_source == 0))
            ;;
        *) return 2 ;;
    esac || {
        vps_cmd_error "$package=$target_version 的 APT 来源不符合 ${mode} 信任策略"
        return 30
    }
}

kernel_validate_install_plan() {
    local requested_package="$1" requested_version="$2" output line package version old_version metadata status dependency_state dependency_token
    local distribution_output='' xanmod_output='' source_mode
    local inst_pattern='^Inst[[:space:]]+([^[:space:]]+)([[:space:]]+\[[^]]+\])?[[:space:]]+\(([^[:space:])]+)([[:space:]][^)]*)?\)([[:space:]]+\[([^]]*)\])?$'
    local conf_pattern='^Conf[[:space:]]+([^[:space:]]+)[[:space:]]+\(([^[:space:])]+)([[:space:]][^)]*)?\)$'
    local -A expected_versions=() configured_versions=()
    local -a dependency_tokens=()
    KERNEL_INSTALL_EXPECTED_VERSIONS=()
    [[ "$requested_package" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ && -n "$requested_version" && "$requested_version" != *[[:space:]]* ]] || {
        vps_cmd_error 'APT 安装计划包含无效的包名或版本'
        return 3
    }
    if ! output="$(LC_ALL=C apt-get --simulate -o APT::Get::AutomaticRemove=false install --no-remove --no-install-recommends "$requested_package=$requested_version" 2>&1)"; then
        vps_cmd_error "APT 安装计划解析失败：$output"
        return 20
    fi
    while IFS= read -r line; do
        case "$line" in
            Remv\ * | Purg\ *)
                vps_cmd_error "APT 安装计划包含删除动作：$line"
                return 30
                ;;
            Inst\ *)
                if [[ "$line" =~ $inst_pattern ]]; then
                    package="${BASH_REMATCH[1]}"
                    old_version="${BASH_REMATCH[2]}"
                    version="${BASH_REMATCH[3]}"
                    metadata="${BASH_REMATCH[4]}"
                    dependency_state="${BASH_REMATCH[6]:-}"
                    : "$old_version" "$metadata"
                else
                    vps_cmd_error "无法解析 APT Inst 动作：$line"
                    return 30
                fi
                [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ && -n "$version" ]] || {
                    vps_cmd_error "APT Inst 动作包含无效包名或版本：$line"
                    return 30
                }
                dependency_tokens=()
                if [[ -n "$dependency_state" ]]; then
                    IFS=' ' read -r -a dependency_tokens <<<"$dependency_state"
                    for dependency_token in "${dependency_tokens[@]}"; do
                        [[ "$dependency_token" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ ]] || {
                            vps_cmd_error "APT Inst 依赖状态包含无效包名：$line"
                            return 30
                        }
                    done
                fi
                if [[ -n "${expected_versions["$package"]+set}" && "${expected_versions["$package"]}" != "$version" ]]; then
                    vps_cmd_error "APT 对 $package 选择了多个版本"
                    return 30
                fi
                expected_versions["$package"]="$version"
                ;;
            Conf\ *)
                if [[ "$line" =~ $conf_pattern ]]; then
                    package="${BASH_REMATCH[1]}"
                    version="${BASH_REMATCH[2]}"
                    metadata="${BASH_REMATCH[3]}"
                    : "$metadata"
                else
                    vps_cmd_error "无法解析 APT Conf 动作：$line"
                    return 30
                fi
                [[ "$package" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9]+)?$ && -n "$version" ]] || {
                    vps_cmd_error "APT Conf 动作包含无效包名或版本：$line"
                    return 30
                }
                if [[ -n "${configured_versions["$package"]+set}" && "${configured_versions["$package"]}" != "$version" ]]; then
                    vps_cmd_error "APT 对 $package 配置了多个版本"
                    return 30
                fi
                configured_versions["$package"]="$version"
                ;;
        esac
    done <<<"$output"
    for package in "${!configured_versions[@]}"; do
        if [[ -z "${expected_versions["$package"]+set}" || "${expected_versions["$package"]}" != "${configured_versions["$package"]}" ]]; then
            vps_cmd_error "APT Conf 动作没有同版本 Inst 对应：$package=${configured_versions["$package"]}"
            return 30
        fi
    done
    if [[ -n "${expected_versions["$requested_package"]+set}" && "${expected_versions["$requested_package"]}" != "$requested_version" ]]; then
        vps_cmd_error "APT 未按请求版本安装 $requested_package=$requested_version"
        return 30
    fi
    ((${#expected_versions[@]} == 0)) && return 0
    if distribution_output="$(_kernel_official_index_descriptions)"; then
        :
    else
        status=$?
        return "$status"
    fi
    if [[ "${KERNEL_TYPE:-xanmod}" == xanmod ]]; then
        if xanmod_output="$(_kernel_xanmod_index_descriptions)"; then
            :
        else
            status=$?
            return "$status"
        fi
    fi
    for package in "${!expected_versions[@]}"; do
        if [[ "${KERNEL_TYPE:-xanmod}" != xanmod ]]; then
            source_mode=distribution
        elif [[ "$package" == *xanmod* ]]; then
            source_mode=xanmod
        else
            source_mode=distribution-or-xanmod
        fi
        _kernel_validate_policy_version_sources "$package" "${expected_versions["$package"]}" "$source_mode" "$distribution_output" "$xanmod_output" || return $?
    done
    for package in "${!expected_versions[@]}"; do
        KERNEL_INSTALL_EXPECTED_VERSIONS["$package"]="${expected_versions["$package"]}"
    done
}

_kernel_require_owned_state_target() {
    local logical="$1" path
    path="$(vps_cmd_system_path "$logical")" || return $?
    vps_cmd_require_no_symlink_components "$path" || return $?
    if [[ -e "$path" || -L "$path" ]]; then
        if [[ ! -f "$path" || -L "$path" ]] || ! grep -Fqx "$KERNEL_MANAGED_MARKER" "$path"; then
            vps_cmd_error "$logical 已存在但不属于 vpsctl，拒绝覆盖"
            return 10
        fi
    fi
}

kernel_prepare_repository() {
    local key_asc key_gpg fingerprint repo_directory key_directory state_file
    if [[ "${KERNEL_TYPE:-xanmod}" == xanmod ]]; then
        _kernel_require_owned_state_target "$KERNEL_STATE_LOGICAL" || return $?
    else
        _kernel_require_owned_state_target "$KERNEL_OFFICIAL_STATE_LOGICAL" || return $?
    fi
    if [[ "${KERNEL_TYPE:-xanmod}" != xanmod ]]; then
        state_file="$(vps_cmd_system_path "$KERNEL_OFFICIAL_STATE_LOGICAL")" || return $?
        vps_cmd_run install -d -m 0755 -- "${state_file%/*}" || return 20
        return 0
    fi

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
    local package="$1" candidate="$2" state_logical
    if [[ "${KERNEL_TYPE:-xanmod}" == xanmod ]]; then
        _kernel_require_owned_state_target "$KERNEL_STATE_LOGICAL" || return $?
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
        return $?
    fi
    state_logical="$KERNEL_OFFICIAL_STATE_LOGICAL"
    _kernel_require_owned_state_target "$state_logical" || return $?
    {
        printf '%s\n' "$KERNEL_MANAGED_MARKER"
        printf 'schema=1\n'
        printf 'provider=%s\n' "$KERNEL_TYPE"
        printf 'package=%s\n' "$package"
        printf 'candidate=%s\n' "$candidate"
        printf 'distribution=%s\n' "$KERNEL_OS_ID"
        printf 'suite=%s\n' "$KERNEL_OS_CODENAME"
    } | vps_cmd_atomic_write "$state_logical" 0600
}
