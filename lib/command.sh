# shellcheck shell=bash
# Shared command safety helpers. Sourcing this file only defines functions.

if [[ -z "${VPS_UI_LOADED:-}" ]]; then
    # shellcheck source=ui.sh
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/ui.sh"
fi

VPS_CMD_DEPENDENCIES_PLANNED=0

_vps_cmd_normalize_boolean() {
    local value

    value="$(vps_cmd_trim "${1:-}")"
    value="${value,,}"
    case "$value" in
        1 | true | yes | on) printf '1' ;;
        0 | false | no | off | '') printf '0' ;;
        *) return 2 ;;
    esac
}

_vps_cmd_validate_absolute_path() {
    local path="$1"

    [[ "$path" == /* && "$path" != "/" && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 2
    [[ "/${path#/}/" != *'/../'* ]] || return 2
}

_vps_cmd_validate_feature() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]
}

_vps_cmd_color_enabled() {
    local output_fd="${1:-}"

    [[ "$output_fd" == "1" || "$output_fd" == "2" ]] || return 1
    [[ -t "$output_fd" ]] || return 1
    [[ "${VPSCTL_NO_COLOR:-0}" != "1" ]] || return 1
    [[ -z "${NO_COLOR:-}" ]] || return 1
    [[ "${TERM:-dumb}" != "dumb" ]]
}

_vps_cmd_color_for_style() {
    case "${1:-normal}" in
        normal) printf '' ;;
        info) printf '\033[36m' ;;
        success) printf '\033[32m' ;;
        warning) printf '\033[33m' ;;
        error) printf '\033[31m' ;;
        emphasis) printf '\033[1;35m' ;;
        muted) printf '\033[2m' ;;
        *) return 2 ;;
    esac
}

_vps_cmd_log_named() {
    local command_name="$1"
    local level="$2"
    local style="$3"
    local color=""
    local reset=""
    shift 3

    if _vps_cmd_color_enabled 2; then
        color="$(_vps_cmd_color_for_style "$style")"
        reset=$'\033[0m'
    fi
    {
        printf '%s[%s]%s %s:' "$color" "$level" "$reset" "$command_name"
        if (($# > 0)); then
            printf ' %s' "$@"
        fi
        printf '\n'
    } >&2
}

_vps_cmd_log() {
    local level="$1"
    local style="$2"
    shift 2

    _vps_cmd_log_named "${VPSCTL_COMMAND_NAME:-vpsctl}" "$level" "$style" "$@"
}

_vps_cmd_path_has_symlink_component() {
    local path="$1"
    local component current=""
    local old_ifs="$IFS"
    local -a components=()

    IFS='/' read -r -a components <<<"${path#/}"
    IFS="$old_ifs"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        current="${current}/${component}"
        [[ ! -L "$current" ]] || return 0
    done
    return 1
}

_vps_cmd_add_standard_system_paths() {
    local directory

    for directory in /usr/local/sbin /usr/sbin /sbin; do
        [[ -d "$directory" ]] || continue
        case ":${PATH:-}:" in
            *":${directory}:"*) ;;
            *) PATH="${PATH:+${PATH}:}${directory}" ;;
        esac
    done
    export PATH
}

vps_cmd_require_no_symlink_components() {
    local path="${1:-}"

    _vps_cmd_validate_absolute_path "$path" || {
        vps_cmd_error "路径必须是非根目录的绝对路径: ${path:-<空>}"
        return 2
    }
    if _vps_cmd_path_has_symlink_component "$path"; then
        vps_cmd_error "拒绝包含符号链接组件的路径: $path"
        return 3
    fi
}

vps_cmd_init() {
    local command_name="${1:-}"
    local project_root="${2:-}"
    local normalized

    command_name="$(vps_cmd_trim "$command_name")"
    [[ -n "$command_name" ]] || {
        _vps_cmd_log_named vpsctl "错误" error "命令名称不能为空"
        return 2
    }
    _vps_cmd_validate_absolute_path "$project_root" || {
        _vps_cmd_log_named "$command_name" "错误" error "项目根目录必须是非根目录的绝对路径"
        return 2
    }
    [[ -d "$project_root" ]] || {
        _vps_cmd_log_named "$command_name" "错误" error "项目根目录不是目录: $project_root"
        return 3
    }
    project_root="$(cd -- "$project_root" && pwd -P)"
    _vps_cmd_validate_absolute_path "$project_root" || {
        _vps_cmd_log_named "$command_name" "错误" error "解析后的项目根目录必须保持为非根目录的绝对路径"
        return 2
    }

    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_DRY_RUN:-0}")"; then
        _vps_cmd_log_named "$command_name" "错误" error "VPSCTL_DRY_RUN 必须是 on/off 值"
        return 2
    fi
    VPSCTL_DRY_RUN="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_INSTALL_DEPS:-0}")"; then
        _vps_cmd_log_named "$command_name" "错误" error "VPSCTL_INSTALL_DEPS 必须是 on/off 值"
        return 2
    fi
    VPSCTL_INSTALL_DEPS="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_ASSUME_YES:-0}")"; then
        _vps_cmd_log_named "$command_name" "错误" error "VPSCTL_ASSUME_YES 必须是 on/off 值"
        return 2
    fi
    VPSCTL_ASSUME_YES="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_NON_INTERACTIVE:-0}")"; then
        _vps_cmd_log_named "$command_name" "错误" error "VPSCTL_NON_INTERACTIVE 必须是 on/off 值"
        return 2
    fi
    VPSCTL_NON_INTERACTIVE="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_QUIET:-0}")"; then
        _vps_cmd_log_named "$command_name" "错误" error "VPSCTL_QUIET 必须是 on/off 值"
        return 2
    fi
    VPSCTL_QUIET="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_VERBOSE:-0}")"; then
        _vps_cmd_log_named "$command_name" "错误" error "VPSCTL_VERBOSE 必须是 on/off 值"
        return 2
    fi
    VPSCTL_VERBOSE="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_NO_COLOR:-0}")"; then
        _vps_cmd_log_named "$command_name" "错误" error "VPSCTL_NO_COLOR 必须是 on/off 值"
        return 2
    fi
    VPSCTL_NO_COLOR="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_TESTING:-0}")"; then
        _vps_cmd_log_named "$command_name" "错误" error "VPSCTL_TESTING 必须是 on/off 值"
        return 2
    fi
    VPSCTL_TESTING="$normalized"

    if [[ "$VPSCTL_TESTING" != "1" ]]; then
        _vps_cmd_add_standard_system_paths
    fi

    VPSCTL_COMMAND_NAME="$command_name"
    # Public context consumed by command implementations after this library returns.
    # shellcheck disable=SC2034
    VPSCTL_PROJECT_ROOT="$project_root"
    VPSCTL_SYSTEM_ROOT="${VPSCTL_SYSTEM_ROOT:-}"
    if [[ "$VPSCTL_TESTING" == "1" ]]; then
        _vps_cmd_validate_absolute_path "$VPSCTL_SYSTEM_ROOT" || {
            _vps_cmd_log_named "$command_name" "错误" error "测试模式下 VPSCTL_SYSTEM_ROOT 必须设为非根目录的绝对路径"
            return 2
        }
        [[ -d "$VPSCTL_SYSTEM_ROOT" ]] || {
            _vps_cmd_log_named "$command_name" "错误" error "测试模式下 VPSCTL_SYSTEM_ROOT 必须是已存在的目录"
            return 3
        }
        if _vps_cmd_path_has_symlink_component "$VPSCTL_SYSTEM_ROOT"; then
            _vps_cmd_log_named "$command_name" "错误" error "VPSCTL_SYSTEM_ROOT 不得包含符号链接组件"
            return 2
        fi
        VPSCTL_SYSTEM_ROOT="$(cd -- "$VPSCTL_SYSTEM_ROOT" && pwd -P)"
        _vps_cmd_validate_absolute_path "$VPSCTL_SYSTEM_ROOT" || {
            _vps_cmd_log_named "$command_name" "错误" error "解析后的 VPSCTL_SYSTEM_ROOT 必须保持为非根目录的绝对路径"
            return 2
        }
    else
        VPSCTL_SYSTEM_ROOT=""
    fi
    VPS_CMD_LOCK_FD=""
    VPS_CMD_LOCK_PATH=""
    VPS_CMD_DEPENDENCIES_PLANNED=0
    vps_ui_init
}

vps_cmd_trim() {
    local value="${1:-}"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

vps_cmd_system_path() {
    local path="${1:-}"

    _vps_cmd_validate_absolute_path "$path" || {
        vps_cmd_error "系统路径必须是非根目录的绝对路径: ${path:-<空>}"
        return 2
    }
    if [[ "${VPSCTL_TESTING:-0}" == "1" ]]; then
        [[ -n "${VPSCTL_SYSTEM_ROOT:-}" ]] || {
            vps_cmd_error "测试模式下必须设置 VPSCTL_SYSTEM_ROOT"
            return 2
        }
        printf '%s%s' "${VPSCTL_SYSTEM_ROOT%/}" "$path"
    else
        printf '%s' "$path"
    fi
}

vps_cmd_is_interactive() {
    [[ "${VPSCTL_NON_INTERACTIVE:-0}" != "1" && -t 0 && -t 1 ]]
}

vps_cmd_prompt_select() {
    local prompt="${1:-}" default_value="${2:-}" choice value label index
    local item_no
    local -a values=() labels=() select_values=()

    (($# >= 4 && ($# - 2) % 2 == 0)) || {
        vps_cmd_error "vps_cmd_prompt_select 需要 PROMPT、DEFAULT 和至少一组 VALUE/LABEL"
        return 2
    }
    [[ -n "$prompt" ]] || {
        vps_cmd_error "vps_cmd_prompt_select 的 PROMPT 不能为空"
        return 2
    }
    shift 2
    while (($# > 0)); do
        values+=("$1")
        labels+=("$2")
        shift 2
    done

    vps_ui_ensure_init
    while true; do
        select_values=()
        item_no=0
        printf '\n' >&2
        vps_ui_section "$prompt" >&2
        printf '\n' >&2
        for ((index = 0; index < ${#values[@]}; index++)); do
            value="${values[$index]}"
            label="${labels[$index]}"
            if [[ "$value" == "__section__" ]]; then
                vps_ui_menu_item "" "$label" section >&2
                continue
            fi
            item_no=$((item_no + 1))
            select_values+=("$value")
            if [[ -n "$default_value" && "$value" == "$default_value" ]]; then
                vps_ui_menu_item "$item_no" "${label}（默认）" default >&2
            else
                vps_ui_menu_item "$item_no" "$label" >&2
            fi
        done
        ((${#select_values[@]} > 0)) || {
            vps_cmd_error "vps_cmd_prompt_select 没有可选择的项目"
            return 2
        }
        printf '\n  [q] 返回\n\n' >&2
        vps_ui_prompt "请选择" >&2
        IFS= read -r choice || return 130
        choice="$(vps_cmd_trim "$choice")"
        case "$choice" in
            q | Q | 0) return 130 ;;
            '')
                if [[ -n "$default_value" ]]; then
                    printf '%s' "$default_value"
                    return 0
                fi
                ;;
            *)
                if [[ "$choice" =~ ^[1-9][0-9]{0,3}$ ]] && ((10#$choice <= ${#select_values[@]})); then
                    printf '%s' "${select_values[$((10#$choice - 1))]}"
                    return 0
                fi
                ;;
        esac
        vps_cmd_warning "选择无效，请输入列表中的编号"
    done
}

vps_cmd_prompt_value() {
    local prompt="${1:-}" default_value="${2:-}" value

    (($# == 2)) || {
        vps_cmd_error "vps_cmd_prompt_value 需要 PROMPT 和 DEFAULT"
        return 2
    }
    [[ -n "$prompt" ]] || {
        vps_cmd_error "vps_cmd_prompt_value 的 PROMPT 不能为空"
        return 2
    }
    vps_ui_ensure_init
    if [[ -n "$default_value" ]]; then
        printf '%s%s%s [%s]：' "$VPS_UI_CYAN" "$prompt" "$VPS_UI_RESET" "$default_value" >&2
    else
        printf '%s%s%s：' "$VPS_UI_CYAN" "$prompt" "$VPS_UI_RESET" >&2
    fi
    IFS= read -r value || return 130
    value="$(vps_cmd_trim "$value")"
    printf '%s' "${value:-$default_value}"
}

vps_cmd_require_root() {
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" || "${VPSCTL_TESTING:-0}" == "1" ]] || ((EUID == 0)); then
        return 0
    fi
    vps_cmd_error "此操作需要 root 权限"
    return 4
}

vps_cmd_info() {
    [[ "${VPSCTL_QUIET:-0}" == "1" ]] && return 0
    _vps_cmd_log "信息" info "$@"
}

vps_cmd_success() {
    [[ "${VPSCTL_QUIET:-0}" == "1" ]] && return 0
    _vps_cmd_log "成功" success "$@"
}

vps_cmd_warning() {
    _vps_cmd_log "警告" warning "$@"
}

vps_cmd_error() {
    _vps_cmd_log "错误" error "$@"
}

vps_cmd_verbose() {
    [[ "${VPSCTL_VERBOSE:-0}" == "1" ]] || return 0
    _vps_cmd_log "详细" muted "$@"
}

vps_cmd_status() {
    local label="${1:-}"
    local value="${2:-}"
    local style="${3:-}"
    local label_color=""
    local value_color=""
    local reset=""

    if (($# != 3)); then
        vps_cmd_error "vps_cmd_status 需要 LABEL、VALUE 和 STYLE 三个参数"
        return 2
    fi
    if ! _vps_cmd_color_for_style "$style" >/dev/null; then
        vps_cmd_error "无效的状态样式: $style"
        return 2
    fi
    if _vps_cmd_color_enabled 1; then
        label_color="$(_vps_cmd_color_for_style info)"
        value_color="$(_vps_cmd_color_for_style "$style")"
        reset=$'\033[0m'
    fi
    vps_ui_ensure_init
    printf '  %s%s%s：%s%s%s\n' "$label_color" "$(vps_ui_pad "$label" "$VPS_UI_KV_WIDTH")" "$reset" "$value_color" "$value" "$reset"
}

vps_cmd_run() {
    local argument
    local rendered=""
    local separator=""

    (($# > 0)) || {
        vps_cmd_error "未提供要执行的命令"
        return 2
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        for argument in "$@"; do
            printf -v rendered '%s%s%q' "$rendered" "$separator" "$argument"
            separator=' '
        done
        if _vps_cmd_color_enabled 2; then
            printf '\033[33m[演练]\033[0m %s\n' "$rendered" >&2
        else
            printf '[演练] %s\n' "$rendered" >&2
        fi
        return 0
    fi
    "$@"
}

vps_cmd_detect_package_manager() {
    local configured="${VPSCTL_ENV_PACKAGE_MANAGER:-}"
    local manager

    case "$configured" in
        '' | unknown) ;;
        apt-get | dnf5 | dnf | yum | apk | pacman | zypper)
            if command -v "$configured" >/dev/null 2>&1; then
                printf '%s\n' "$configured"
                return 0
            fi
            ;;
        *)
            vps_cmd_error "无效的软件包管理器：$configured"
            return 2
            ;;
    esac
    for manager in apt-get dnf5 dnf yum apk pacman zypper; do
        if command -v "$manager" >/dev/null 2>&1; then
            printf '%s\n' "$manager"
            return 0
        fi
    done
    vps_cmd_error "未找到受支持的软件包管理器"
    return 3
}

vps_cmd_package_for_tool() {
    local manager="${1:-}"
    local tool="${2:-}"

    (($# == 2)) || {
        vps_cmd_error "vps_cmd_package_for_tool 需要 MANAGER 和 TOOL"
        return 2
    }
    case "$manager" in
        apt-get | dnf5 | dnf | yum | apk | pacman | zypper) ;;
        *)
            vps_cmd_error "无效的软件包管理器：${manager:-<空>}"
            return 2
            ;;
    esac
    case "$tool" in
        dns-query)
            case "$manager" in
                apt-get) printf 'dnsutils\n' ;;
                dnf5 | dnf | yum | zypper) printf 'bind-utils\n' ;;
                apk) printf 'bind-tools\n' ;;
                pacman) printf 'bind\n' ;;
            esac
            ;;
        sysctl)
            case "$manager" in
                dnf5 | dnf | yum | pacman) printf 'procps-ng\n' ;;
                *) printf 'procps\n' ;;
            esac
            ;;
        nft) printf 'nftables\n' ;;
        sudo | visudo) printf 'sudo\n' ;;
        ssh-keygen)
            case "$manager" in
                apt-get) printf 'openssh-client\n' ;;
                dnf5 | dnf | yum | zypper) printf 'openssh-clients\n' ;;
                apk | pacman) printf 'openssh\n' ;;
            esac
            ;;
        sshd)
            case "$manager" in
                apt-get | dnf5 | dnf | yum | zypper) printf 'openssh-server\n' ;;
                apk | pacman) printf 'openssh\n' ;;
            esac
            ;;
        systemctl | systemd-run) printf 'systemd\n' ;;
        useradd | userdel | usermod)
            case "$manager" in
                apt-get) printf 'passwd\n' ;;
                dnf5 | dnf | yum) printf 'shadow-utils\n' ;;
                apk) printf 'shadow\n' ;;
                pacman) printf 'shadow\n' ;;
                zypper) printf 'shadow\n' ;;
            esac
            ;;
        passwd)
            case "$manager" in
                apt-get | dnf5 | dnf | yum) printf 'passwd\n' ;;
                apk | pacman | zypper) printf 'shadow\n' ;;
            esac
            ;;
        ufw) printf 'ufw\n' ;;
        firewall-cmd) printf 'firewalld\n' ;;
        iptables | ip6tables) printf 'iptables\n' ;;
        getent)
            case "$manager" in
                apt-get) printf 'libc-bin\n' ;;
                dnf5 | dnf | yum) printf 'glibc-common\n' ;;
                apk) printf 'musl-utils\n' ;;
                pacman | zypper) printf 'glibc\n' ;;
            esac
            ;;
        modprobe) printf 'kmod\n' ;;
        ip | tc | ss)
            case "$manager" in
                dnf5 | dnf | yum) printf 'iproute\n' ;;
                *) printf 'iproute2\n' ;;
            esac
            ;;
        base64 | sha256sum | tr | mktemp | sort | head | install | od) printf 'coreutils\n' ;;
        awk) printf 'gawk\n' ;;
        flock)
            if [[ "$manager" == apk ]]; then printf 'flock\n'; else printf 'util-linux\n'; fi
            ;;
        mountpoint)
            if [[ "$manager" == apk ]]; then printf 'util-linux-misc\n'; else printf 'util-linux\n'; fi
            ;;
        curl | jq | openssl | unzip | tar | chrony) printf '%s\n' "$tool" ;;
        gpg) printf 'gnupg\n' ;;
        chronyc) printf 'chrony\n' ;;
        *)
            vps_cmd_error "没有工具的软件包映射：${tool:-<空>}"
            return 3
            ;;
    esac
}

vps_cmd_install_packages() {
    local manager="${1:-}"
    local package
    local -a packages=()
    local -A seen=()

    (($# >= 2)) || {
        vps_cmd_error "vps_cmd_install_packages 需要 MANAGER 和至少一个 PACKAGE"
        return 2
    }
    case "$manager" in
        apt-get | dnf5 | dnf | yum | apk | pacman | zypper) ;;
        *)
            vps_cmd_error "无效的软件包管理器：${manager:-<空>}"
            return 2
            ;;
    esac
    shift
    for package in "$@"; do
        [[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] || {
            vps_cmd_error "不安全的软件包名称：${package:-<空>}"
            return 2
        }
        if [[ -z "${seen[$package]+set}" ]]; then
            seen[$package]=1
            packages+=("$package")
        fi
    done
    vps_cmd_require_root || return $?
    case "$manager" in
        apt-get)
            vps_cmd_run apt-get update || return 20
            vps_cmd_run apt-get install -y --no-install-recommends "${packages[@]}" || return 20
            ;;
        dnf5 | dnf | yum)
            vps_cmd_run "$manager" install -y "${packages[@]}" || return 20
            ;;
        apk)
            vps_cmd_run apk add --no-cache "${packages[@]}" || return 20
            ;;
        pacman)
            vps_cmd_run pacman -S --needed --noconfirm "${packages[@]}" || return 20
            ;;
        zypper)
            vps_cmd_run zypper --non-interactive install --no-recommends "${packages[@]}" || return 20
            ;;
    esac
}

_vps_cmd_tool_available() {
    local tool="$1"

    if [[ "$tool" == dns-query ]]; then
        command -v dig >/dev/null 2>&1 || command -v drill >/dev/null 2>&1 || command -v nslookup >/dev/null 2>&1
    else
        command -v "$tool" >/dev/null 2>&1
    fi
}

_vps_cmd_confirm_dependency_install() {
    local reply

    vps_ui_ensure_init
    printf '%s是否安装这些依赖？%s [是/否，输入 y 确认] ' "$VPS_UI_YELLOW" "$VPS_UI_RESET" >&2
    IFS= read -r reply || return 130
    reply="$(vps_cmd_trim "$reply")"
    case "$reply" in
        y | Y | yes | YES) return 0 ;;
        *) return 3 ;;
    esac
}

vps_cmd_ensure_tools() {
    local feature="${1:-}"
    local manager package tool missing_join packages_join confirm_status
    local -a missing=() packages=()
    local -A package_seen=()

    (($# >= 2)) || {
        vps_cmd_error "vps_cmd_ensure_tools 需要 FEATURE 和至少一个 TOOL"
        return 2
    }
    _vps_cmd_validate_feature "$feature" || {
        vps_cmd_error "无效的依赖功能名称：${feature:-<空>}"
        return 2
    }
    shift
    for tool in "$@"; do
        [[ "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
            vps_cmd_error "无效的工具名称：${tool:-<空>}"
            return 2
        }
        _vps_cmd_tool_available "$tool" || missing+=("$tool")
    done
    ((${#missing[@]} > 0)) || return 0
    missing_join="$(
        IFS=' '
        printf '%s' "${missing[*]}"
    )"
    if [[ "${VPSCTL_INSTALL_DEPS:-0}" != "1" ]]; then
        if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] || ! vps_cmd_is_interactive; then
            vps_cmd_error "缺少工具：${missing_join}；请添加 --install-deps 允许安装依赖"
            return 3
        fi
    fi
    manager="$(vps_cmd_detect_package_manager)" || return $?
    for tool in "${missing[@]}"; do
        package="$(vps_cmd_package_for_tool "$manager" "$tool")" || return $?
        if [[ -z "${package_seen[$package]+set}" ]]; then
            package_seen[$package]=1
            packages+=("$package")
        fi
    done
    packages_join="$(
        IFS=' '
        printf '%s' "${packages[*]}"
    )"
    if [[ "${VPSCTL_INSTALL_DEPS:-0}" != 1 ]]; then
        vps_cmd_warning "缺少工具：${missing_join}；需要安装软件包：${packages_join}"
        if _vps_cmd_confirm_dependency_install; then
            :
        else
            confirm_status=$?
            return "$confirm_status"
        fi
    fi
    vps_cmd_info "缺少工具：${missing_join}；将安装软件包：${packages_join}"
    vps_cmd_install_packages "$manager" "${packages[@]}" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        VPS_CMD_DEPENDENCIES_PLANNED=1
        return 0
    fi
    if [[ "${VPSCTL_TESTING:-0}" != "1" ]]; then
        _vps_cmd_add_standard_system_paths
    fi
    hash -r
    for tool in "${missing[@]}"; do
        if ! _vps_cmd_tool_available "$tool"; then
            vps_cmd_error "依赖安装已结束，但工具仍不可用：$tool"
            return 20
        fi
    done
}

vps_cmd_confirm() {
    local prompt="${1:-是否继续？}"
    local reply

    [[ "${VPSCTL_DRY_RUN:-0}" == "1" || "${VPSCTL_ASSUME_YES:-0}" == "1" ]] && return 0
    vps_cmd_is_interactive || {
        vps_cmd_error "确认操作需要交互式终端，或使用 --yes"
        return 3
    }
    vps_ui_ensure_init
    printf '%s%s%s [是/否，输入 y 确认] ' "$VPS_UI_YELLOW" "$prompt" "$VPS_UI_RESET" >&2
    IFS= read -r reply || return 130
    reply="$(vps_cmd_trim "$reply")"
    [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" || "$reply" == "YES" ]]
}

vps_cmd_confirm_token() {
    local prompt="${1:-确认操作}"
    local token="${2:-}"
    local reply

    [[ -n "$token" ]] || {
        vps_cmd_error "确认令牌不能为空"
        return 2
    }
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] && return 0
    vps_cmd_is_interactive || {
        vps_cmd_error "令牌确认需要交互式终端"
        return 3
    }
    vps_ui_ensure_init
    printf '%s%s%s 请输入 %s%s%s 以继续: ' "$VPS_UI_RED" "$prompt" "$VPS_UI_RESET" "$VPS_UI_BOLD" "$token" "$VPS_UI_RESET" >&2
    IFS= read -r reply || return 130
    [[ "$reply" == "$token" ]]
}

vps_cmd_parse_on_off() {
    local value

    value="$(vps_cmd_trim "${1:-}")"
    value="${value,,}"
    case "$value" in
        on | yes | true | 1) printf 'on' ;;
        off | no | false | 0) printf 'off' ;;
        *) return 2 ;;
    esac
}

vps_cmd_lock() {
    local feature="${1:-}"
    local lock_directory

    _vps_cmd_validate_feature "$feature" || {
        vps_cmd_error "无效的锁功能名称: ${feature:-<空>}"
        return 2
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_verbose "演练模式不获取 ${feature} 锁"
        return 0
    fi
    command -v flock >/dev/null 2>&1 || {
        vps_cmd_error "命令锁需要 flock"
        return 3
    }
    [[ -z "${VPS_CMD_LOCK_FD:-}" ]] || {
        vps_cmd_error "当前已持有命令锁: ${VPS_CMD_LOCK_PATH:-未知}"
        return 70
    }
    lock_directory="$(vps_cmd_system_path /run/vpsctl)" || return $?
    vps_cmd_require_no_symlink_components "$lock_directory" || return $?
    mkdir -p -- "$lock_directory" || return 20
    chmod 0755 -- "$lock_directory" || return 20
    VPS_CMD_LOCK_PATH="${lock_directory}/${feature}.lock"
    vps_cmd_require_no_symlink_components "$VPS_CMD_LOCK_PATH" || return $?
    exec {VPS_CMD_LOCK_FD}>"$VPS_CMD_LOCK_PATH" || {
        VPS_CMD_LOCK_FD=""
        return 20
    }
    if ! flock -n "$VPS_CMD_LOCK_FD"; then
        exec {VPS_CMD_LOCK_FD}>&-
        VPS_CMD_LOCK_FD=""
        vps_cmd_error "另一个 ${feature} 操作正在运行"
        return 3
    fi
}

vps_cmd_unlock() {
    if [[ -n "${VPS_CMD_LOCK_FD:-}" ]]; then
        flock -u "$VPS_CMD_LOCK_FD" >/dev/null 2>&1 || true
        exec {VPS_CMD_LOCK_FD}>&-
    fi
    VPS_CMD_LOCK_FD=""
    VPS_CMD_LOCK_PATH=""
}

vps_cmd_backup_file() {
    local feature="${1:-}"
    local logical_source="${2:-}"
    local source_path
    local backup_root
    local backup_directory
    local backup_path
    local timestamp

    _vps_cmd_validate_feature "$feature" || {
        vps_cmd_error "无效的备份功能名称: ${feature:-<空>}"
        return 2
    }
    source_path="$(vps_cmd_system_path "$logical_source")" || return $?
    vps_cmd_require_no_symlink_components "$source_path" || return $?
    [[ -f "$source_path" && ! -L "$source_path" ]] || {
        vps_cmd_error "备份源必须是普通文件且不能是符号链接: $logical_source"
        return 3
    }
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_root="$(vps_cmd_system_path "/var/lib/vpsctl/backups/network/${feature}")" || return $?
    vps_cmd_require_no_symlink_components "$backup_root" || return $?
    mkdir -p -- "$backup_root" || return 20
    vps_cmd_require_no_symlink_components "$backup_root" || return $?
    chmod 0700 -- "$backup_root" || return 20
    backup_directory="$(mktemp -d --tmpdir="$backup_root" "${timestamp}.XXXXXX")" || return 20
    backup_path="${backup_directory}/${logical_source##*/}"
    chmod 0700 -- "$backup_directory" || return 20
    cp -p -- "$source_path" "$backup_path" || return 20
    printf '%s\n' "$backup_path"
}

vps_cmd_atomic_write() {
    local logical_target="${1:-}"
    local mode="${2:-}"
    local target_path
    local target_directory
    local target_name
    local temporary_path=""
    local status=0

    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || {
        vps_cmd_error "无效的文件模式: ${mode:-<空>}"
        return 2
    }
    target_path="$(vps_cmd_system_path "$logical_target")" || return $?
    vps_cmd_require_no_symlink_components "$target_path" || return $?
    target_directory="${target_path%/*}"
    target_name="${target_path##*/}"
    [[ -d "$target_directory" && ! -L "$target_directory" ]] || {
        vps_cmd_error "目标目录必须存在且不能是符号链接: ${logical_target%/*}"
        return 3
    }
    temporary_path="$(mktemp --tmpdir="$target_directory" ".${target_name}.tmp.XXXXXX")" || return 20
    if ! cat >"$temporary_path"; then
        status=20
    elif ! chmod "$mode" -- "$temporary_path"; then
        status=20
    elif ! mv -f -- "$temporary_path" "$target_path"; then
        status=20
    else
        temporary_path=""
    fi
    if [[ -n "$temporary_path" ]]; then
        rm -f -- "$temporary_path"
    fi
    return "$status"
}
