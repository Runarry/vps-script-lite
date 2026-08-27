# shellcheck shell=bash
# Shared command safety helpers. Sourcing this file only defines functions.

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

vps_cmd_require_no_symlink_components() {
    local path="${1:-}"

    _vps_cmd_validate_absolute_path "$path" || {
        vps_cmd_error "path must be an absolute non-root path: ${path:-<empty>}"
        return 2
    }
    if _vps_cmd_path_has_symlink_component "$path"; then
        vps_cmd_error "refusing a path with a symbolic-link component: $path"
        return 3
    fi
}

vps_cmd_init() {
    local command_name="${1:-}"
    local project_root="${2:-}"
    local normalized

    command_name="$(vps_cmd_trim "$command_name")"
    [[ -n "$command_name" ]] || {
        printf 'vpsctl: command name must not be empty\n' >&2
        return 2
    }
    _vps_cmd_validate_absolute_path "$project_root" || {
        printf '%s: project root must be an absolute non-root path\n' "$command_name" >&2
        return 2
    }
    [[ -d "$project_root" ]] || {
        printf '%s: project root is not a directory: %s\n' "$command_name" "$project_root" >&2
        return 3
    }
    project_root="$(cd -- "$project_root" && pwd -P)"
    _vps_cmd_validate_absolute_path "$project_root" || {
        printf '%s: resolved project root must remain an absolute non-root path\n' "$command_name" >&2
        return 2
    }

    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_DRY_RUN:-0}")"; then
        printf '%s: VPSCTL_DRY_RUN must be an on/off value\n' "$command_name" >&2
        return 2
    fi
    VPSCTL_DRY_RUN="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_ASSUME_YES:-0}")"; then
        printf '%s: VPSCTL_ASSUME_YES must be an on/off value\n' "$command_name" >&2
        return 2
    fi
    VPSCTL_ASSUME_YES="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_NON_INTERACTIVE:-0}")"; then
        printf '%s: VPSCTL_NON_INTERACTIVE must be an on/off value\n' "$command_name" >&2
        return 2
    fi
    VPSCTL_NON_INTERACTIVE="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_QUIET:-0}")"; then
        printf '%s: VPSCTL_QUIET must be an on/off value\n' "$command_name" >&2
        return 2
    fi
    VPSCTL_QUIET="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_VERBOSE:-0}")"; then
        printf '%s: VPSCTL_VERBOSE must be an on/off value\n' "$command_name" >&2
        return 2
    fi
    VPSCTL_VERBOSE="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_NO_COLOR:-0}")"; then
        printf '%s: VPSCTL_NO_COLOR must be an on/off value\n' "$command_name" >&2
        return 2
    fi
    VPSCTL_NO_COLOR="$normalized"
    if ! normalized="$(_vps_cmd_normalize_boolean "${VPSCTL_TESTING:-0}")"; then
        printf '%s: VPSCTL_TESTING must be an on/off value\n' "$command_name" >&2
        return 2
    fi
    VPSCTL_TESTING="$normalized"

    VPSCTL_COMMAND_NAME="$command_name"
    # Public context consumed by command implementations after this library returns.
    # shellcheck disable=SC2034
    VPSCTL_PROJECT_ROOT="$project_root"
    VPSCTL_SYSTEM_ROOT="${VPSCTL_SYSTEM_ROOT:-}"
    if [[ "$VPSCTL_TESTING" == "1" ]]; then
        _vps_cmd_validate_absolute_path "$VPSCTL_SYSTEM_ROOT" || {
            printf '%s: VPSCTL_SYSTEM_ROOT must be set to an absolute non-root path in testing mode\n' "$command_name" >&2
            return 2
        }
        [[ -d "$VPSCTL_SYSTEM_ROOT" ]] || {
            printf '%s: VPSCTL_SYSTEM_ROOT must already be a directory in testing mode\n' "$command_name" >&2
            return 3
        }
        if _vps_cmd_path_has_symlink_component "$VPSCTL_SYSTEM_ROOT"; then
            printf '%s: VPSCTL_SYSTEM_ROOT must not contain symbolic-link components\n' "$command_name" >&2
            return 2
        fi
        VPSCTL_SYSTEM_ROOT="$(cd -- "$VPSCTL_SYSTEM_ROOT" && pwd -P)"
        _vps_cmd_validate_absolute_path "$VPSCTL_SYSTEM_ROOT" || {
            printf '%s: resolved VPSCTL_SYSTEM_ROOT must remain an absolute non-root path\n' "$command_name" >&2
            return 2
        }
    else
        VPSCTL_SYSTEM_ROOT=""
    fi
    VPS_CMD_LOCK_FD=""
    VPS_CMD_LOCK_PATH=""
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
        vps_cmd_error "system path must be an absolute non-root path: ${path:-<empty>}"
        return 2
    }
    if [[ "${VPSCTL_TESTING:-0}" == "1" ]]; then
        [[ -n "${VPSCTL_SYSTEM_ROOT:-}" ]] || {
            vps_cmd_error "VPSCTL_SYSTEM_ROOT is required in testing mode"
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

vps_cmd_require_root() {
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" || "${VPSCTL_TESTING:-0}" == "1" ]] || ((EUID == 0)); then
        return 0
    fi
    vps_cmd_error "root privileges are required"
    return 4
}

vps_cmd_info() {
    [[ "${VPSCTL_QUIET:-0}" == "1" ]] && return 0
    {
        printf '[INFO] %s:' "${VPSCTL_COMMAND_NAME:-vpsctl}"
        printf ' %s' "$@"
        printf '\n'
    } >&2
}

vps_cmd_warning() {
    {
        printf '[WARN] %s:' "${VPSCTL_COMMAND_NAME:-vpsctl}"
        printf ' %s' "$@"
        printf '\n'
    } >&2
}

vps_cmd_error() {
    {
        printf '[ERROR] %s:' "${VPSCTL_COMMAND_NAME:-vpsctl}"
        printf ' %s' "$@"
        printf '\n'
    } >&2
}

vps_cmd_verbose() {
    [[ "${VPSCTL_VERBOSE:-0}" == "1" ]] || return 0
    {
        printf '[DEBUG] %s:' "${VPSCTL_COMMAND_NAME:-vpsctl}"
        printf ' %s' "$@"
        printf '\n'
    } >&2
}

vps_cmd_run() {
    local argument
    local rendered=""
    local separator=""

    (($# > 0)) || {
        vps_cmd_error "no command was provided"
        return 2
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        for argument in "$@"; do
            printf -v rendered '%s%s%q' "$rendered" "$separator" "$argument"
            separator=' '
        done
        printf '[DRY-RUN] %s\n' "$rendered" >&2
        return 0
    fi
    "$@"
}

vps_cmd_confirm() {
    local prompt="${1:-Continue?}"
    local reply

    [[ "${VPSCTL_DRY_RUN:-0}" == "1" || "${VPSCTL_ASSUME_YES:-0}" == "1" ]] && return 0
    vps_cmd_is_interactive || {
        vps_cmd_error "confirmation requires an interactive terminal or --yes"
        return 3
    }
    printf '%s [y/N] ' "$prompt" >&2
    IFS= read -r reply || return 130
    reply="$(vps_cmd_trim "$reply")"
    [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" || "$reply" == "YES" ]]
}

vps_cmd_confirm_token() {
    local prompt="${1:-Confirm}"
    local token="${2:-}"
    local reply

    [[ -n "$token" ]] || {
        vps_cmd_error "confirmation token must not be empty"
        return 2
    }
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] && return 0
    vps_cmd_is_interactive || {
        vps_cmd_error "token confirmation requires an interactive terminal"
        return 3
    }
    printf '%s Type %s to continue: ' "$prompt" "$token" >&2
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
        vps_cmd_error "invalid lock feature name: ${feature:-<empty>}"
        return 2
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_verbose "dry-run: lock not acquired for ${feature}"
        return 0
    fi
    command -v flock >/dev/null 2>&1 || {
        vps_cmd_error "flock is required for command locking"
        return 3
    }
    [[ -z "${VPS_CMD_LOCK_FD:-}" ]] || {
        vps_cmd_error "a command lock is already held: ${VPS_CMD_LOCK_PATH:-unknown}"
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
        vps_cmd_error "another ${feature} operation is already running"
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
        vps_cmd_error "invalid backup feature name: ${feature:-<empty>}"
        return 2
    }
    source_path="$(vps_cmd_system_path "$logical_source")" || return $?
    vps_cmd_require_no_symlink_components "$source_path" || return $?
    [[ -f "$source_path" && ! -L "$source_path" ]] || {
        vps_cmd_error "backup source must be a regular non-symbolic file: $logical_source"
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
        vps_cmd_error "invalid file mode: ${mode:-<empty>}"
        return 2
    }
    target_path="$(vps_cmd_system_path "$logical_target")" || return $?
    vps_cmd_require_no_symlink_components "$target_path" || return $?
    target_directory="${target_path%/*}"
    target_name="${target_path##*/}"
    [[ -d "$target_directory" && ! -L "$target_directory" ]] || {
        vps_cmd_error "target directory must exist and must not be a symbolic link: ${logical_target%/*}"
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
