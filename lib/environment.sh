# shellcheck shell=bash
# shellcheck disable=SC2034
# Environment detection for vpsctl. This file is a library and has no side effects
# beyond defining functions and data structures when sourced.

declare -gA VPS_ENV=()
declare -gA VPS_CAPABILITY=()
declare -g VPS_ENV_MISSING_REQUIREMENTS=""

vps_env_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

vps_env_format_kib() {
    local kib="${1:-0}"
    local unit divisor whole decimal

    if [[ ! "$kib" =~ ^[0-9]+$ ]]; then
        printf '未知'
        return 0
    fi

    if ((kib >= 1073741824)); then
        unit="TiB"
        divisor=1073741824
    elif ((kib >= 1048576)); then
        unit="GiB"
        divisor=1048576
    elif ((kib >= 1024)); then
        unit="MiB"
        divisor=1024
    else
        printf '%s KiB' "$kib"
        return 0
    fi

    whole=$((kib / divisor))
    decimal=$(((kib % divisor) * 10 / divisor))
    printf '%s.%s %s' "$whole" "$decimal" "$unit"
}

vps_env_format_uptime() {
    local seconds="${1:-0}"
    local days hours minutes result=""

    [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0
    days=$((seconds / 86400))
    hours=$(((seconds % 86400) / 3600))
    minutes=$(((seconds % 3600) / 60))

    ((days > 0)) && result+="${days} 天 "
    ((hours > 0 || days > 0)) && result+="${hours} 小时 "
    result+="${minutes} 分钟"
    printf '%s' "$result"
}

vps_env_read_os_release() {
    local key value

    [[ -r /etc/os-release ]] || return 0

    while IFS='=' read -r key value; do
        value="${value%$'\r'}"
        if ((${#value} >= 2)) && [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            value="${value:1:${#value}-2}"
            value="${value//\\\"/\"}"
            value="${value//\\\\/\\}"
        fi

        case "$key" in
            ID) VPS_ENV[os_id]="$value" ;;
            ID_LIKE) VPS_ENV[os_id_like]="$value" ;;
            VERSION_ID) VPS_ENV[os_version_id]="$value" ;;
            VERSION_CODENAME) VPS_ENV[os_codename]="$value" ;;
            PRETTY_NAME) VPS_ENV[os_pretty_name]="$value" ;;
        esac
    done </etc/os-release
}

vps_env_detect_package_manager() {
    local candidate

    VPS_ENV[package_manager]="unknown"
    for candidate in apt-get dnf5 dnf yum apk pacman zypper; do
        if command -v "$candidate" >/dev/null 2>&1; then
            VPS_ENV[package_manager]="$candidate"
            VPS_CAPABILITY["pkg:any"]=1
            VPS_CAPABILITY["pkg:${candidate}"]=1
            return 0
        fi
    done
}

vps_env_detect_libc() {
    local output="" loader

    VPS_ENV[libc]="unknown"
    if command -v getconf >/dev/null 2>&1; then
        output="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
        case "${output,,}" in
            glibc\ *) VPS_ENV[libc]="glibc" ;;
        esac
    fi
    if [[ "${VPS_ENV[libc]}" == "unknown" ]] && command -v ldd >/dev/null 2>&1; then
        output="$(LC_ALL=C ldd --version 2>&1 || true)"
        case "${output,,}" in
            *musl*) VPS_ENV[libc]="musl" ;;
            *glibc* | *"gnu libc"* | *"gnu c library"*) VPS_ENV[libc]="glibc" ;;
        esac
    fi
    if [[ "${VPS_ENV[libc]}" == "unknown" ]]; then
        for loader in /lib/ld-musl-*.so.1 /lib64/ld-musl-*.so.1; do
            if [[ -e "$loader" ]]; then
                VPS_ENV[libc]="musl"
                break
            fi
        done
    fi
    case "${VPS_ENV[libc]}" in
        glibc | musl) VPS_CAPABILITY["libc:${VPS_ENV[libc]}"]=1 ;;
    esac
}

vps_env_detect_init() {
    local init_name="unknown"

    if [[ -r /proc/1/comm ]]; then
        IFS= read -r init_name </proc/1/comm || true
        init_name="$(vps_env_trim "$init_name")"
    fi
    [[ "$init_name" == init\(* ]] && init_name="init"
    [[ -n "$init_name" ]] || init_name="unknown"
    VPS_ENV[init_system]="$init_name"

    case "$init_name" in
        systemd)
            VPS_CAPABILITY["init:systemd"]=1
            if command -v systemctl >/dev/null 2>&1; then
                VPS_ENV[service_manager]="systemctl"
                VPS_CAPABILITY["service:any"]=1
            fi
            ;;
        init* | openrc-init)
            if command -v rc-service >/dev/null 2>&1; then
                VPS_ENV[service_manager]="rc-service"
                VPS_CAPABILITY["init:openrc"]=1
                VPS_CAPABILITY["service:any"]=1
            elif command -v service >/dev/null 2>&1; then
                VPS_ENV[service_manager]="service"
                VPS_CAPABILITY["init:sysv"]=1
                VPS_CAPABILITY["service:any"]=1
            fi
            ;;
    esac

}

vps_env_detect_virtualization() {
    local detected=""
    local cgroup=""

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        detected="$(systemd-detect-virt 2>/dev/null || true)"
        [[ "$detected" == "none" ]] && detected="bare-metal"
    fi

    if [[ -z "$detected" && -r /proc/1/cgroup ]]; then
        cgroup="$(</proc/1/cgroup)"
        case "$cgroup" in
            *docker*) detected="docker" ;;
            *lxc*) detected="lxc" ;;
            *kubepods* | *libpod* | *podman*) detected="container" ;;
        esac
    fi
    if [[ -z "$detected" && ( -e /.dockerenv || -e /run/.containerenv ) ]]; then
        detected="container"
    fi

    VPS_ENV[virtualization]="${detected:-unknown}"
}

vps_env_detect_cpu() {
    local key value cores="" model=""

    if command -v getconf >/dev/null 2>&1; then
        cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    elif command -v nproc >/dev/null 2>&1; then
        cores="$(nproc 2>/dev/null || true)"
    fi
    [[ "$cores" =~ ^[0-9]+$ ]] || cores="unknown"

    if [[ -r /proc/cpuinfo ]]; then
        while IFS=':' read -r key value; do
            key="$(vps_env_trim "$key")"
            case "$key" in
                "model name" | Hardware | Processor)
                    model="$(vps_env_trim "$value")"
                    [[ -n "$model" ]] && break
                    ;;
            esac
        done </proc/cpuinfo
    fi

    VPS_ENV[cpu_cores]="$cores"
    VPS_ENV[cpu_model]="${model:-unknown}"
}

vps_env_detect_memory() {
    local key value unit

    VPS_ENV[memory_total]="unknown"
    [[ -r /proc/meminfo ]] || return 0

    while IFS=$' \t' read -r key value unit; do
        if [[ "$key" == "MemTotal:" ]]; then
            VPS_ENV[memory_total]="$(vps_env_format_kib "$value")"
            return 0
        fi
    done </proc/meminfo
}

vps_env_detect_disk() {
    local header filesystem blocks used available percent mountpoint

    VPS_ENV[root_disk_total]="unknown"
    VPS_ENV[root_disk_available]="unknown"
    VPS_ENV[root_disk_used_percent]="unknown"
    command -v df >/dev/null 2>&1 || return 0

    {
        IFS= read -r header || true
        IFS=$' \t' read -r filesystem blocks used available percent mountpoint || true
    } < <(df -Pk / 2>/dev/null || true)

    if [[ "${blocks:-}" =~ ^[0-9]+$ && "${available:-}" =~ ^[0-9]+$ ]]; then
        VPS_ENV[root_disk_total]="$(vps_env_format_kib "$blocks")"
        VPS_ENV[root_disk_available]="$(vps_env_format_kib "$available")"
        VPS_ENV[root_disk_used_percent]="${percent:-unknown}"
    fi
}

vps_env_detect_addresses() {
    local index interface family address remainder count

    VPS_ENV[ipv4]="unavailable"
    VPS_ENV[ipv6]="unavailable"
    command -v ip >/dev/null 2>&1 || return 0

    count=0
    while IFS=$' \t' read -r index interface family address remainder; do
        address="${address%%/*}"
        [[ -n "$address" ]] || continue
        if [[ "${VPS_ENV[ipv4]}" == "unavailable" ]]; then
            VPS_ENV[ipv4]="$address"
        else
            VPS_ENV[ipv4]+=", ${address}"
        fi
        count=$((count + 1))
        ((count >= 3)) && break
    done < <(ip -o -4 address show scope global 2>/dev/null || true)

    count=0
    while IFS=$' \t' read -r index interface family address remainder; do
        address="${address%%/*}"
        [[ -n "$address" ]] || continue
        if [[ "${VPS_ENV[ipv6]}" == "unavailable" ]]; then
            VPS_ENV[ipv6]="$address"
        else
            VPS_ENV[ipv6]+=", ${address}"
        fi
        count=$((count + 1))
        ((count >= 3)) && break
    done < <(ip -o -6 address show scope global 2>/dev/null || true)

    if [[ "${VPS_ENV[ipv4]}" != "unavailable" ]]; then
        VPS_CAPABILITY[ipv4]=1
    fi
    if [[ "${VPS_ENV[ipv6]}" != "unavailable" ]]; then
        VPS_CAPABILITY[ipv6]=1
    fi
    return 0
}

vps_env_classify_bbr_version() {
    local algorithm="${1:-}"
    local module_version="${2:-}"

    if [[ -n "$module_version" ]]; then
        printf '模块 %s' "$module_version"
        return 0
    fi

    case "$algorithm" in
        bbr3) printf 'BBRv3' ;;
        bbr2) printf 'BBRv2' ;;
        bbr) printf '内核实现（未公开版本）' ;;
        *) printf '不可用' ;;
    esac
}

vps_env_detect_bbr() {
    local current_algorithm="unknown"
    local available_algorithms="unknown"
    local detected_bbr_algorithm=""
    local module_version=""
    local algorithm
    local -a algorithm_list=()

    if [[ -r /proc/sys/net/ipv4/tcp_congestion_control ]]; then
        IFS= read -r current_algorithm </proc/sys/net/ipv4/tcp_congestion_control || true
        current_algorithm="$(vps_env_trim "$current_algorithm")"
        [[ -n "$current_algorithm" ]] || current_algorithm="unknown"
    fi

    if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        IFS= read -r available_algorithms </proc/sys/net/ipv4/tcp_available_congestion_control || true
        available_algorithms="$(vps_env_trim "$available_algorithms")"
        [[ -n "$available_algorithms" ]] || available_algorithms="unknown"
    fi

    VPS_ENV[congestion_control]="$current_algorithm"
    VPS_ENV[available_congestion_controls]="$available_algorithms"
    VPS_ENV[bbr_status]="disabled"

    case "$current_algorithm" in
        bbr | bbr2 | bbr3)
            VPS_ENV[bbr_status]="enabled"
            detected_bbr_algorithm="$current_algorithm"
            VPS_CAPABILITY["bbr:enabled"]=1
            ;;
    esac

    if [[ "$available_algorithms" != "unknown" ]]; then
        IFS=$' \t' read -r -a algorithm_list <<<"$available_algorithms"
        for algorithm in "${algorithm_list[@]}"; do
            case "$algorithm" in
                bbr3)
                    detected_bbr_algorithm="bbr3"
                    VPS_CAPABILITY["bbr:available"]=1
                    break
                    ;;
                bbr2)
                    [[ "$detected_bbr_algorithm" != "bbr3" ]] && detected_bbr_algorithm="bbr2"
                    VPS_CAPABILITY["bbr:available"]=1
                    ;;
                bbr)
                    [[ -n "$detected_bbr_algorithm" ]] || detected_bbr_algorithm="bbr"
                    VPS_CAPABILITY["bbr:available"]=1
                    ;;
            esac
        done
    fi

    if [[ -n "$detected_bbr_algorithm" && -r /sys/module/tcp_bbr/version ]]; then
        IFS= read -r module_version </sys/module/tcp_bbr/version || true
        module_version="$(vps_env_trim "$module_version")"
    elif [[ -n "$detected_bbr_algorithm" ]] && command -v modinfo >/dev/null 2>&1; then
        module_version="$(modinfo -F version tcp_bbr 2>/dev/null || true)"
        module_version="$(vps_env_trim "$module_version")"
    fi

    VPS_ENV[bbr_version]="$(vps_env_classify_bbr_version "$detected_bbr_algorithm" "$module_version")"
    if [[ "$current_algorithm" != "unknown" ]]; then
        VPS_CAPABILITY["cc:${current_algorithm}"]=1
    fi
}

vps_env_version_at_least() {
    local current="${1:-}" required_major="${2:-}" required_minor="${3:-}"
    local current_major current_minor

    [[ "$current" =~ ^([0-9]+)\.([0-9]+)(\.|$) ]] || return 1
    current_major="${BASH_REMATCH[1]}"
    current_minor="${BASH_REMATCH[2]}"
    [[ "$required_major" =~ ^[0-9]+$ && "$required_minor" =~ ^[0-9]+$ ]] || return 2
    ((10#$current_major > 10#$required_major)) ||
        ((10#$current_major == 10#$required_major && 10#$current_minor >= 10#$required_minor))
}

vps_env_alpine_arch_supported() {
    case "${1:-}" in
        x86_64 | aarch64) return 0 ;;
        *) return 1 ;;
    esac
}

vps_env_set_compatibility() {
    if [[ "${VPS_ENV[kernel_name]}" != "Linux" ]]; then
        VPS_ENV[compatibility]="unsupported"
        VPS_ENV[compatibility_detail]="此版本仅支持 Linux。"
    elif [[ "${VPS_ENV[os_id]}" == "unknown" ]]; then
        VPS_ENV[compatibility]="limited"
        VPS_ENV[compatibility_detail]="已检测到 Linux，但无法识别发行版。"
    elif [[ "${VPS_ENV[os_id]}" == "alpine" ]] && ! vps_env_version_at_least "${VPS_ENV[os_version_id]}" 3 20; then
        VPS_ENV[compatibility]="limited"
        VPS_ENV[compatibility_detail]="Alpine 核心支持要求 3.20 或更高版本（当前：${VPS_ENV[os_version_id]}）。"
    elif [[ "${VPS_ENV[os_id]}" == "alpine" ]] && ! vps_env_alpine_arch_supported "${VPS_ENV[architecture]}"; then
        VPS_ENV[compatibility]="limited"
        VPS_ENV[compatibility_detail]="Alpine 核心支持仅覆盖 x86_64 与 aarch64（当前：${VPS_ENV[architecture]}）。"
    elif [[ "${VPS_ENV[os_id]}" == "alpine" && "${VPS_ENV[libc]}" != "musl" ]]; then
        VPS_ENV[compatibility]="limited"
        VPS_ENV[compatibility_detail]="Alpine 核心支持要求 musl 用户空间（当前：${VPS_ENV[libc]}）。"
    elif [[ "${VPS_ENV[virtualization]}" =~ ^(docker|lxc|container|wsl)$ ]]; then
        VPS_ENV[compatibility]="limited"
        VPS_ENV[compatibility_detail]="已检测到容器或兼容层；主机级命令可能不可用。"
    elif [[ "${VPS_ENV[os_id]}" == "alpine" && "${VPS_ENV[package_manager]}" != "apk" ]]; then
        VPS_ENV[compatibility]="limited"
        VPS_ENV[compatibility_detail]="Alpine 核心支持要求 apk 软件包管理器。"
    elif [[ "${VPS_ENV[os_id]}" == "alpine" && "${VPS_CAPABILITY[init:openrc]:-0}" != "1" ]]; then
        VPS_ENV[compatibility]="limited"
        VPS_ENV[compatibility_detail]="Alpine 核心支持要求由 OpenRC 管理系统服务。"
    elif [[ "${VPS_ENV[package_manager]}" == "unknown" || "${VPS_ENV[service_manager]}" == "unknown" ]]; then
        VPS_ENV[compatibility]="limited"
        VPS_ENV[compatibility_detail]="已检测到核心系统，但部分管理能力不可用。"
    elif [[ "${VPS_ENV[os_id]}" == "alpine" ]]; then
        VPS_ENV[compatibility]="supported"
        VPS_ENV[compatibility_detail]="已支持 Alpine 3.20+（musl、apk、OpenRC）；各功能仍受独立能力门禁约束。"
    else
        VPS_ENV[compatibility]="supported"
        VPS_ENV[compatibility_detail]="核心环境已就绪，可以运行满足能力要求的已登记命令。"
    fi
}

vps_env_detect() {
    local hostname_value uptime_raw uptime_seconds timezone_value current_user

    VPS_ENV=()
    VPS_CAPABILITY=()
    VPS_ENV_MISSING_REQUIREMENTS=""

    VPS_ENV[kernel_name]="$(uname -s 2>/dev/null || printf 'unknown')"
    VPS_ENV[kernel_release]="$(uname -r 2>/dev/null || printf 'unknown')"
    VPS_ENV[architecture]="$(uname -m 2>/dev/null || printf 'unknown')"
    VPS_ENV[bash_version]="$BASH_VERSION"
    VPS_ENV[os_id]="unknown"
    VPS_ENV[os_id_like]=""
    VPS_ENV[os_version_id]="unknown"
    VPS_ENV[os_codename]=""
    VPS_ENV[os_pretty_name]="未知 Linux 系统"
    VPS_ENV[libc]="unknown"
    VPS_ENV[service_manager]="unknown"

    hostname_value="$(hostname 2>/dev/null || true)"
    if [[ -z "$hostname_value" && -r /etc/hostname ]]; then
        IFS= read -r hostname_value </etc/hostname || true
    fi
    VPS_ENV[hostname]="${hostname_value:-unknown}"

    vps_env_read_os_release
    vps_env_detect_libc
    vps_env_detect_package_manager
    vps_env_detect_init
    vps_env_detect_virtualization
    vps_env_detect_cpu
    vps_env_detect_memory
    vps_env_detect_disk
    vps_env_detect_addresses
    vps_env_detect_bbr

    current_user="${USER:-}"
    [[ -n "$current_user" ]] || current_user="$(id -un 2>/dev/null || printf 'unknown')"
    VPS_ENV[user]="$current_user"
    if ((EUID == 0)); then
        VPS_ENV[is_root]="yes"
        VPS_CAPABILITY[root]=1
    else
        VPS_ENV[is_root]="no"
    fi

    if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; then
        VPS_ENV[session]="SSH"
        VPS_CAPABILITY[ssh]=1
    else
        VPS_ENV[session]="local"
    fi
    if [[ -t 0 && -t 1 ]]; then
        VPS_ENV[interactive]="yes"
        VPS_CAPABILITY[interactive]=1
    else
        VPS_ENV[interactive]="no"
    fi

    timezone_value="$(date +%Z 2>/dev/null || true)"
    VPS_ENV[timezone]="${timezone_value:-unknown}"

    uptime_seconds=0
    if [[ -r /proc/uptime ]]; then
        IFS=' ' read -r uptime_raw _ </proc/uptime || true
        uptime_seconds="${uptime_raw%%.*}"
    fi
    VPS_ENV[uptime]="$(vps_env_format_uptime "$uptime_seconds")"

    [[ "${VPS_ENV[kernel_name]}" == "Linux" ]] && VPS_CAPABILITY[linux]=1
    VPS_CAPABILITY["bash:4.4"]=1
    [[ "${VPS_ENV[os_id]}" != "unknown" ]] && VPS_CAPABILITY["os:${VPS_ENV[os_id]}"]=1
    case "${VPS_ENV[os_id]}" in
        debian | ubuntu) VPS_CAPABILITY["os:debian-family"]=1 ;;
    esac

    vps_env_set_compatibility
}

vps_env_has_capability() {
    local capability="$1"
    [[ "${VPS_CAPABILITY[$capability]:-0}" == "1" ]]
}

vps_env_requirements_met() {
    local requirements="${1:-}"
    local requirement
    local -a missing=()
    local -a requirement_list=()

    VPS_ENV_MISSING_REQUIREMENTS=""
    [[ -n "$requirements" && "$requirements" != "none" ]] || return 0

    local old_ifs="$IFS"
    IFS=','
    read -r -a requirement_list <<<"$requirements"
    IFS="$old_ifs"

    for requirement in "${requirement_list[@]}"; do
        requirement="$(vps_env_trim "$requirement")"
        [[ -n "$requirement" ]] || continue
        if ! vps_env_has_capability "$requirement"; then
            missing+=("$requirement")
        fi
    done

    if ((${#missing[@]} > 0)); then
        local joined=""
        for requirement in "${missing[@]}"; do
            [[ -n "$joined" ]] && joined+=", "
            joined+="$requirement"
        done
        VPS_ENV_MISSING_REQUIREMENTS="$joined"
        return 1
    fi
}
