# shellcheck shell=bash
# Private helpers for commands/service/proxy.sh. Sourcing this file only
# defines functions; callers must invoke proxy_common_init explicitly.

readonly PROXY_SCHEMA_VERSION=1
readonly PROXY_ETC_LOGICAL="/etc/vpsctl/proxy"
readonly PROXY_STATE_LOGICAL="/var/lib/vpsctl/service/proxy"
readonly PROXY_BACKUP_LOGICAL="/var/lib/vpsctl/backups/service/proxy"
readonly PROXY_LOG_LOGICAL="/var/log/vpsctl/proxy"

PROXY_ETC_DIR=""
PROXY_STATE_DIR=""
PROXY_BACKUP_DIR=""
PROXY_LOG_DIR=""
PROXY_MANIFEST=""
PROXY_TRANSACTION=""
PROXY_CORE_SWITCH_CERT_TRANSACTION=""
PROXY_INIT_SYSTEM="unknown"
PROXY_PACKAGE_MANAGER="unknown"
PROXY_ARCH="unknown"
PROXY_CORE_SWITCH_COMMITTED=0

proxy_ensure_tools() {
    local feature="${1:-}"
    shift || return 2
    vps_cmd_ensure_tools "proxy-${feature}" "$@"
}

proxy_ensure_mutation_tools() {
    local feature="${1:-}"
    local -a tools=()

    (($# >= 1)) || {
        vps_cmd_error "proxy_ensure_mutation_tools 需要 FEATURE"
        return 2
    }
    shift
    tools=("$@")
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] || tools+=(flock)
    ((${#tools[@]} > 0)) || return 0
    proxy_ensure_tools "$feature" "${tools[@]}"
}

proxy_stop_after_dependency_plan() {
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == "1" ]] || return 1
    vps_cmd_info "依赖仅完成安装计划；请安装依赖后重跑完整计划"
}

proxy_is_interactive() {
    # Capture the real terminal state before any command substitution redirects
    # stdout.  Subshells inherit this scalar without re-testing the pipe.
    [[ "${PROXY_INTERACTIVE:-0}" == "1" ]]
}

proxy_confirm() {
    local prompt="${1:-是否继续？}" reply
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" || "${VPSCTL_ASSUME_YES:-0}" == "1" ]] && return 0
    proxy_is_interactive || {
        vps_cmd_error "确认操作需要交互式终端，或使用 --yes"
        return 3
    }
    vps_ui_ensure_init
    printf '%s%s%s [是/否，输入 y 确认] ' "$VPS_UI_YELLOW" "$prompt" "$VPS_UI_RESET" >&2
    IFS= read -r reply || return 130
    reply="$(vps_cmd_trim "$reply")"
    [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" || "$reply" == "YES" ]]
}

proxy_prompt_select() {
    local prompt="${1:-}" default_value="${2:-}" choice value label index
    local -a values=() labels=()
    shift 2 || return 2
    [[ -n "$prompt" ]] && (($# >= 2 && $# % 2 == 0)) || return 2
    if declare -F vps_cmd_prompt_select >/dev/null 2>&1; then
        vps_cmd_prompt_select "$prompt" "$default_value" "$@"
        return
    fi
    while (($#)); do
        values+=("$1")
        labels+=("$2")
        shift 2
    done

    local item_no
    local -a select_values=()
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
                if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((10#$choice <= ${#select_values[@]})); then
                    printf '%s' "${select_values[$((10#$choice - 1))]}"
                    return 0
                fi
                ;;
        esac
        vps_cmd_warning "选择无效，请输入列表中的编号"
    done
}

proxy_prompt_quick_custom() {
    local prompt="${1:-请选择配置方式}" quick_label="${2:-使用推荐设置}" custom_label="${3:-自定义设置}"
    proxy_prompt_select "$prompt" quick \
        quick "$quick_label" \
        custom "$custom_label"
}

proxy_prompt_quick_or_custom() {
    proxy_prompt_quick_custom "$@"
}

proxy_prompt_mode() {
    proxy_prompt_quick_custom "${1:-请选择配置方式}" "使用推荐设置" "自定义设置"
}

proxy_common_init() {
    PROXY_ETC_DIR="$(vps_cmd_system_path "$PROXY_ETC_LOGICAL")" || return $?
    PROXY_STATE_DIR="$(vps_cmd_system_path "$PROXY_STATE_LOGICAL")" || return $?
    PROXY_BACKUP_DIR="$(vps_cmd_system_path "$PROXY_BACKUP_LOGICAL")" || return $?
    PROXY_LOG_DIR="$(vps_cmd_system_path "$PROXY_LOG_LOGICAL")" || return $?
    PROXY_MANIFEST="${PROXY_STATE_DIR}/nodes.json"
    PROXY_TRANSACTION="${PROXY_STATE_DIR}/transaction.json"
    PROXY_CORE_SWITCH_CERT_TRANSACTION="${PROXY_STATE_DIR}/transaction-core-switch-certs.json"
    PROXY_INIT_SYSTEM="${VPSCTL_ENV_INIT:-unknown}"
    PROXY_PACKAGE_MANAGER="${VPSCTL_ENV_PACKAGE_MANAGER:-unknown}"
    PROXY_ARCH="${VPSCTL_ENV_ARCH:-unknown}"

    case "$PROXY_INIT_SYSTEM" in
        openrc | openrc-init) PROXY_INIT_SYSTEM="openrc" ;;
        init*)
            if command -v rc-service >/dev/null 2>&1; then
                PROXY_INIT_SYSTEM="openrc"
            else
                PROXY_INIT_SYSTEM="unknown"
            fi
            ;;
    esac
    if [[ "$PROXY_INIT_SYSTEM" == "unknown" ]]; then
        if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system || "${VPSCTL_TESTING:-0}" == "1" ]]; then
            PROXY_INIT_SYSTEM="systemd"
        elif command -v rc-service >/dev/null 2>&1; then
            PROXY_INIT_SYSTEM="openrc"
        fi
    fi
    if [[ "$PROXY_PACKAGE_MANAGER" == "unknown" ]]; then
        local candidate
        for candidate in apt-get dnf5 dnf yum apk pacman zypper; do
            if command -v "$candidate" >/dev/null 2>&1; then
                PROXY_PACKAGE_MANAGER="$candidate"
                break
            fi
        done
    fi
    if [[ "$PROXY_ARCH" == "unknown" ]]; then
        PROXY_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"
    fi
}

proxy_mktemp_json() {
    local directory="${1:-}" prefix="${2:-temporary}" temporary target

    [[ "$directory" == /* && -d "$directory" && "$prefix" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
    temporary="$(mktemp "${directory}/.${prefix}.XXXXXX")" || return 20
    target="${temporary}.json"
    if ! mv -- "$temporary" "$target"; then
        rm -f -- "$temporary"
        return 20
    fi
    printf '%s' "$target"
}

proxy_require_platform() {
    case "$PROXY_INIT_SYSTEM" in
        systemd | openrc) ;;
        *)
            vps_cmd_error "代理管理仅支持 systemd 或 OpenRC（当前：${PROXY_INIT_SYSTEM}）"
            return 3
            ;;
    esac
    case "$PROXY_ARCH" in
        x86_64 | amd64 | aarch64 | arm64 | armv7l | armv7) ;;
        *)
            vps_cmd_error "代理内核暂不支持当前架构：${PROXY_ARCH}"
            return 3
            ;;
    esac
}

proxy_require_state_access() {
    if [[ "${VPSCTL_TESTING:-0}" == "1" ]] || ((EUID == 0)); then
        return 0
    fi
    vps_cmd_error "读取代理内核和节点状态需要 root"
    return 4
}

proxy_core_valid() {
    [[ "${1:-}" == "sing-box" || "${1:-}" == "xray" ]]
}

proxy_core_label() {
    case "${1:-}" in
        sing-box) printf 'sing-box' ;;
        xray) printf 'Xray' ;;
        *) return 2 ;;
    esac
}

proxy_core_slug() {
    case "${1:-}" in
        sing-box) printf 'sing-box' ;;
        xray) printf 'xray' ;;
        *) return 2 ;;
    esac
}

proxy_core_default_binary_logical() {
    case "${1:-}" in
        sing-box) printf '/usr/local/bin/sing-box' ;;
        xray) printf '/usr/local/bin/xray' ;;
        *) return 2 ;;
    esac
}

proxy_core_config_logical() {
    local core="${1:-}"
    proxy_core_valid "$core" || return 2
    printf '%s/%s/config.json' "$PROXY_ETC_LOGICAL" "$core"
}

proxy_core_config_path() {
    vps_cmd_system_path "$(proxy_core_config_logical "$1")"
}

proxy_core_meta_logical() {
    local core="${1:-}"
    proxy_core_valid "$core" || return 2
    printf '%s/cores/%s.json' "$PROXY_STATE_LOGICAL" "$core"
}

proxy_core_meta_path() {
    vps_cmd_system_path "$(proxy_core_meta_logical "$1")"
}

proxy_core_pending_logical() {
    local core="${1:-}"
    proxy_core_valid "$core" || return 2
    printf '%s/pending/%s.json' "$PROXY_STATE_LOGICAL" "$core"
}

proxy_core_pending_path() {
    vps_cmd_system_path "$(proxy_core_pending_logical "$1")"
}

proxy_core_service_name() {
    case "${1:-}" in
        sing-box) printf 'vpsctl-proxy-sing-box' ;;
        xray) printf 'vpsctl-proxy-xray' ;;
        *) return 2 ;;
    esac
}

proxy_core_service_logical() {
    local core="${1:-}" service
    service="$(proxy_core_service_name "$core")" || return 2
    case "$PROXY_INIT_SYSTEM" in
        systemd) printf '/etc/systemd/system/%s.service' "$service" ;;
        openrc) printf '/etc/init.d/%s' "$service" ;;
        *) return 3 ;;
    esac
}

proxy_core_service_path() {
    vps_cmd_system_path "$(proxy_core_service_logical "$1")"
}

proxy_core_log_logical() {
    local core="${1:-}"
    proxy_core_valid "$core" || return 2
    printf '%s/%s.log' "$PROXY_LOG_LOGICAL" "$core"
}

proxy_core_log_path() {
    vps_cmd_system_path "$(proxy_core_log_logical "$1")"
}

proxy_core_lkg_dir() {
    local core="${1:-}"
    proxy_core_valid "$core" || return 2
    printf '%s/lkg/%s' "$PROXY_STATE_DIR" "$core"
}

proxy_path_to_logical() {
    local path="${1:-}"
    if [[ "${VPSCTL_TESTING:-0}" == "1" ]]; then
        [[ "$path" == "${VPSCTL_SYSTEM_ROOT%/}/"* ]] || return 2
        printf '/%s' "${path#"${VPSCTL_SYSTEM_ROOT%/}/"}"
    else
        [[ "$path" == /* ]] || return 2
        printf '%s' "$path"
    fi
}

proxy_require_safe_paths() {
    local path
    for path in "$PROXY_ETC_DIR" "$PROXY_STATE_DIR" "$PROXY_BACKUP_DIR" "$PROXY_LOG_DIR"; do
        vps_cmd_require_no_symlink_components "$path" || return $?
    done
}

proxy_ensure_layout() {
    vps_cmd_require_root || return $?
    proxy_require_safe_paths || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_run mkdir -p "$PROXY_ETC_DIR" "$PROXY_STATE_DIR" "$PROXY_BACKUP_DIR" "$PROXY_LOG_DIR"
        return 0
    fi
    mkdir -p -- \
        "$PROXY_ETC_DIR" \
        "$PROXY_STATE_DIR/cores" \
        "$PROXY_STATE_DIR/pending" \
        "$PROXY_STATE_DIR/lkg" \
        "$PROXY_BACKUP_DIR" \
        "$PROXY_LOG_DIR" || return 20
    chmod 0700 -- "$PROXY_ETC_DIR" "$PROXY_STATE_DIR" "$PROXY_STATE_DIR/cores" \
        "$PROXY_STATE_DIR/pending" "$PROXY_STATE_DIR/lkg" "$PROXY_BACKUP_DIR" || return 20
    chmod 0750 -- "$PROXY_LOG_DIR" || return 20
    proxy_require_safe_paths || return $?
}

proxy_atomic_write_from_file() {
    local source="$1" logical_target="$2" mode="$3"
    [[ -f "$source" && ! -L "$source" ]] || {
        vps_cmd_error "原子写入源不是普通文件：$source"
        return 3
    }
    vps_cmd_atomic_write "$logical_target" "$mode" <"$source"
}

proxy_atomic_write_json() {
    local logical_target="$1" mode="$2" json="$3"
    printf '%s\n' "$json" | vps_cmd_atomic_write "$logical_target" "$mode"
}

proxy_manifest_default() {
    printf '{"schema_version":%d,"nodes":[]}\n' "$PROXY_SCHEMA_VERSION"
}

proxy_manifest_validate_file() {
    local file="$1"
    command -v jq >/dev/null 2>&1 || {
        vps_cmd_error "节点管理需要 jq"
        return 3
    }
    [[ -f "$file" && ! -L "$file" ]] || {
        vps_cmd_error "节点清单不存在或不是普通文件：$file"
        return 3
    }
    jq -e --argjson schema "$PROXY_SCHEMA_VERSION" '
        type == "object" and
        .schema_version == $schema and
        ((.nodes | type) == "array") and
        (([.nodes[].id] | length) == ([.nodes[].id] | unique | length)) and
        (([.nodes[].name] | length) == ([.nodes[].name] | unique | length)) and
        (([.nodes[].port] | length) == ([.nodes[].port] | unique | length)) and
        all(.nodes[];
            ((.id | type) == "string" and (.id | test("^node-[a-f0-9]{16}$"))) and
            (.core == "sing-box" or .core == "xray") and
            ((.profile | type) == "string" and (.profile | length) > 0) and
            ((.name | type) == "string" and (.name | length) > 0 and (.name | length) <= 128) and
            ((.listen | type) == "string" and (.listen | length) > 0) and
            ((.port | type) == "number" and (.port | floor) == .port and .port >= 1 and .port <= 65535) and
            ((.address | type) == "string" and (.address | length) > 0) and
            ((has("ip_strategy") | not) or
                (.ip_strategy == "auto" or .ip_strategy == "prefer_ipv4" or
                 .ip_strategy == "prefer_ipv6" or .ip_strategy == "ipv4_only" or
                 .ip_strategy == "ipv6_only")) and
            ((.credentials | type) == "object") and
            ((.tls | type) == "object") and
            ((.transport | type) == "object") and
            ((.options | type) == "object")
        )
    ' "$file" >/dev/null 2>&1 || {
        vps_cmd_error "节点清单格式或唯一性校验失败：$file"
        return 10
    }
}

proxy_manifest_ensure() {
    proxy_ensure_layout || return $?
    if [[ -e "$PROXY_MANIFEST" ]]; then
        proxy_manifest_validate_file "$PROXY_MANIFEST"
        return $?
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "演练：初始化节点清单 ${PROXY_MANIFEST}"
        return 0
    fi
    proxy_manifest_default | vps_cmd_atomic_write "${PROXY_STATE_LOGICAL}/nodes.json" 0600 || return 20
    proxy_manifest_validate_file "$PROXY_MANIFEST"
}

proxy_manifest_count() {
    local core="${1:-all}"
    [[ -f "$PROXY_MANIFEST" ]] || {
        printf '0'
        return 0
    }
    case "$core" in
        all) jq -r '.nodes | length' "$PROXY_MANIFEST" ;;
        sing-box | xray) jq -r --arg core "$core" '[.nodes[] | select(.core == $core)] | length' "$PROXY_MANIFEST" ;;
        *) return 2 ;;
    esac
}

proxy_manifest_node() {
    local id="$1"
    [[ -f "$PROXY_MANIFEST" ]] || return 1
    jq -ce --arg id "$id" '.nodes[] | select(.id == $id)' "$PROXY_MANIFEST" 2>/dev/null
}

proxy_generate_node_id() {
    local id attempt
    for attempt in {1..20}; do
        if command -v openssl >/dev/null 2>&1; then
            id="node-$(openssl rand -hex 8 2>/dev/null)"
        elif [[ -r /dev/urandom ]]; then
            id="node-$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        else
            return 20
        fi
        [[ "$id" =~ ^node-[a-f0-9]{16}$ ]] || continue
        if [[ ! -f "$PROXY_MANIFEST" ]] || ! jq -e --arg id "$id" '.nodes[]? | select(.id == $id)' "$PROXY_MANIFEST" >/dev/null 2>&1; then
            printf '%s' "$id"
            return 0
        fi
    done
    vps_cmd_error "无法生成唯一节点 ID"
    return 20
}

proxy_random_hex() {
    local bytes="${1:-16}"
    [[ "$bytes" =~ ^[1-9][0-9]?$ ]] || return 2
    openssl rand -hex "$bytes" 2>/dev/null
}

proxy_random_base64() {
    local bytes="${1:-32}"
    [[ "$bytes" =~ ^[1-9][0-9]?$ ]] || return 2
    openssl rand -base64 "$bytes" 2>/dev/null | tr -d '\r\n'
}

proxy_generate_uuid() {
    local binary="${1:-}" core="${2:-}" value=""
    if [[ -x "$binary" ]]; then
        case "$core" in
            sing-box) value="$("$binary" generate uuid 2>/dev/null || true)" ;;
            xray) value="$("$binary" uuid 2>/dev/null || true)" ;;
        esac
    fi
    if [[ ! "$value" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[1-5][A-Fa-f0-9]{3}-[89ABab][A-Fa-f0-9]{3}-[A-Fa-f0-9]{12}$ ]] && [[ -r /proc/sys/kernel/random/uuid ]]; then
        value="$(</proc/sys/kernel/random/uuid)"
    fi
    [[ "$value" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[1-5][A-Fa-f0-9]{3}-[89ABab][A-Fa-f0-9]{3}-[A-Fa-f0-9]{12}$ ]] || return 20
    printf '%s' "$value"
}

proxy_urlencode() {
    jq -nr --arg value "${1:-}" '$value | @uri'
}

proxy_bracket_host() {
    local host="${1:-}"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

proxy_valid_name() {
    local value="${1:-}"
    [[ -n "$value" && ${#value} -le 128 && "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

proxy_valid_port() {
    local value="${1:-}"
    [[ "$value" =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#$value >= 1 && 10#$value <= 65535))
}

proxy_valid_host() {
    local value="${1:-}"
    [[ -n "$value" && ${#value} -le 253 && "$value" != *[[:space:]/]* && "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

proxy_valid_path() {
    local value="${1:-}"
    [[ "$value" == /* && ${#value} -le 256 && "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

proxy_ip_strategy_valid() {
    case "${1:-}" in
        auto | prefer_ipv4 | prefer_ipv6 | ipv4_only | ipv6_only) return 0 ;;
        *) return 1 ;;
    esac
}

proxy_default_address() {
    local address=""
    if command -v ip >/dev/null 2>&1; then
        address="$(ip -o -4 address show scope global 2>/dev/null | awk 'NR == 1 {split($4, a, "/"); print a[1]}')"
        if [[ -z "$address" ]]; then
            address="$(ip -o -6 address show scope global 2>/dev/null | awk 'NR == 1 {split($4, a, "/"); print a[1]}')"
        fi
    fi
    printf '%s' "$address"
}

proxy_backup_file() {
    local core="$1" logical_source="$2" label="${3:-file}"
    local source backup_root backup_dir timestamp safe_label
    [[ "$core" == relay ]] || proxy_core_valid "$core" || return 2
    safe_label="${label//[^a-zA-Z0-9._-]/_}"
    source="$(vps_cmd_system_path "$logical_source")" || return $?
    vps_cmd_require_no_symlink_components "$source" || return $?
    [[ -f "$source" && ! -L "$source" ]] || return 1
    backup_root="${PROXY_BACKUP_DIR}/${core}"
    vps_cmd_require_no_symlink_components "$backup_root" || return $?
    mkdir -p -- "$backup_root" || return 20
    chmod 0700 -- "$backup_root" || return 20
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_dir="$(mktemp -d "${backup_root}/${timestamp}.XXXXXX")" || return 20
    chmod 0700 -- "$backup_dir" || return 20
    cp -p -- "$source" "${backup_dir}/${safe_label}" || return 20
    printf '%s' "${backup_dir}/${safe_label}"
}

proxy_backup_runtime_file() {
    local scope="$1" source="$2" label="${3:-file}"
    local backup_root backup_dir timestamp safe_label
    [[ "$scope" == relay ]] || proxy_core_valid "$scope" || return 2
    [[ -f "$source" && ! -L "$source" ]] || return 1
    vps_cmd_require_no_symlink_components "$source" || return $?
    safe_label="${label//[^a-zA-Z0-9._-]/_}"
    backup_root="${PROXY_BACKUP_DIR}/${scope}"
    vps_cmd_require_no_symlink_components "$backup_root" || return $?
    mkdir -p -- "$backup_root" || return 20
    chmod 0700 -- "$backup_root" || return 20
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_dir="$(mktemp -d "${backup_root}/${timestamp}.XXXXXX")" || return 20
    chmod 0700 -- "$backup_dir" || return 20
    cp -p -- "$source" "${backup_dir}/${safe_label}" || return 20
    chmod 0600 -- "${backup_dir}/${safe_label}" || return 20
    printf '%s' "${backup_dir}/${safe_label}"
}

proxy_restore_backup() {
    local backup="$1" logical_target="$2" mode="$3"
    [[ -f "$backup" && ! -L "$backup" ]] || return 1
    proxy_atomic_write_from_file "$backup" "$logical_target" "$mode"
}

proxy_core_meta_valid() {
    local core="$1" meta
    meta="$(proxy_core_meta_path "$core")" || return 2
    [[ -f "$meta" && ! -L "$meta" ]] || return 1
    jq -e --arg core "$core" '
        .schema_version == 1 and .core == $core and
        ((.binary | type) == "string" and (.binary | startswith("/"))) and
        ((.owned | type) == "boolean") and
        ((.version | type) == "string") and
        ((.service | type) == "string")
    ' "$meta" >/dev/null 2>&1
}

proxy_core_binary_logical() {
    local core="$1" meta
    meta="$(proxy_core_meta_path "$core")" || return 2
    if proxy_core_meta_valid "$core"; then
        jq -r '.binary' "$meta"
    else
        proxy_core_default_binary_logical "$core"
    fi
}

proxy_core_binary_path() {
    vps_cmd_system_path "$(proxy_core_binary_logical "$1")"
}

proxy_core_registered() {
    local core="$1" binary
    proxy_core_meta_valid "$core" || return 1
    binary="$(proxy_core_binary_path "$core")" || return 1
    [[ -x "$binary" && ! -L "$binary" ]]
}

proxy_service_is_active() {
    local core="$1" service
    service="$(proxy_core_service_name "$core")" || return 2
    case "$PROXY_INIT_SYSTEM" in
        systemd) systemctl is-active --quiet "${service}.service" ;;
        openrc) rc-service "$service" status >/dev/null 2>&1 ;;
        *) return 3 ;;
    esac
}

proxy_service_is_enabled() {
    local core="$1" service
    service="$(proxy_core_service_name "$core")" || return 2
    case "$PROXY_INIT_SYSTEM" in
        systemd) systemctl is-enabled --quiet "${service}.service" ;;
        openrc)
            rc-update show default 2>/dev/null |
                awk -v wanted="$service" '$1 == wanted { found=1 } END { exit(found ? 0 : 1) }'
            ;;
        *) return 3 ;;
    esac
}

proxy_service_action() {
    local core="$1" action="$2" service
    service="$(proxy_core_service_name "$core")" || return 2
    case "$PROXY_INIT_SYSTEM" in
        systemd)
            case "$action" in
                reload-manager) vps_cmd_run systemctl daemon-reload ;;
                enable | disable | start | stop | restart) vps_cmd_run systemctl "$action" "${service}.service" ;;
                *) return 2 ;;
            esac
            ;;
        openrc)
            case "$action" in
                reload-manager) return 0 ;;
                enable) vps_cmd_run rc-update add "$service" default ;;
                disable) vps_cmd_run rc-update del "$service" default ;;
                start | stop | restart) vps_cmd_run rc-service "$service" "$action" ;;
                *) return 2 ;;
            esac
            ;;
        *) return 3 ;;
    esac
}

proxy_render_config() {
    local core="$1" manifest="$2" relay_manifest="${3:-${PROXY_RELAY_FILE:-}}"
    local node rendered inbounds='[]' relay_state='{"schema_version":1,"exits":[],"bindings":[],"forwards":[]}'
    local exit exit_id outbound_bundle target_tag node_id used_exit_ids
    local relay_outbounds='[]' relay_rules='[]' policy_nodes='[]' policy_outbounds='[]' policy_rules='[]'
    proxy_core_valid "$core" || return 2
    proxy_manifest_validate_file "$manifest" || return $?
    if [[ -n "$relay_manifest" && -f "$relay_manifest" ]]; then
        if declare -F proxy_relay_validate_file >/dev/null 2>&1; then
            proxy_relay_validate_file "$relay_manifest" "$manifest" || return $?
        fi
        relay_state="$(<"$relay_manifest")"
    fi
    while IFS= read -r node; do
        [[ -n "$node" ]] || continue
        case "$core" in
            sing-box)
                proxy_sb_validate_node "$node" || return $?
                rendered="$(proxy_sb_render_node "$node")" || return $?
                ;;
            xray)
                proxy_xray_validate_node "$node" || return $?
                rendered="$(proxy_xray_render_node "$node")" || return $?
                ;;
        esac
        inbounds="$(jq -cn --argjson current "$inbounds" --argjson extra "$rendered" '$current + $extra')" || return 10
    done < <(jq -c --arg core "$core" '.nodes[] | select(.core == $core)' "$manifest")

    used_exit_ids="$(jq -r --arg core "$core" '
        . as $root |
        $root.exits[] |
        select(.type == "protocol" and .core == $core) |
        .id as $id |
        select(any($root.bindings[]; .exit_id == $id)) |
        $id
    ' <<<"$relay_state")" || return 10
    if [[ -n "$used_exit_ids" ]]; then
        declare -F proxy_relay_render_outbound >/dev/null 2>&1 || {
            vps_cmd_error "中转出站渲染模块不可用"
            return 20
        }
        while IFS= read -r exit_id; do
            [[ -n "$exit_id" ]] || continue
            exit="$(jq -ce --arg id "$exit_id" '.exits[] | select(.id == $id)' <<<"$relay_state")" || return 10
            outbound_bundle="$(proxy_relay_render_outbound "$core" "$exit")" || return $?
            jq -e '
                type == "object" and ((.outbounds | type) == "array") and
                ((.target_tag | type) == "string" and (.target_tag | length) > 0)
            ' <<<"$outbound_bundle" >/dev/null 2>&1 || {
                vps_cmd_error "中转出站渲染结果无效：$exit_id"
                return 10
            }
            target_tag="$(jq -r '.target_tag' <<<"$outbound_bundle")"
            relay_outbounds="$(jq -cn --argjson current "$relay_outbounds" --argjson bundle "$outbound_bundle" \
                '$current + $bundle.outbounds')" || return 10
            while IFS= read -r node_id; do
                [[ -n "$node_id" ]] || continue
                case "$core" in
                    sing-box)
                        relay_rules="$(jq -cn --argjson current "$relay_rules" --arg inbound "$node_id" --arg outbound "$target_tag" \
                            '$current + [{inbound:[$inbound],action:"route",outbound:$outbound}]')" || return 10
                        ;;
                    xray)
                        relay_rules="$(jq -cn --argjson current "$relay_rules" --arg inbound "$node_id" --arg outbound "$target_tag" \
                            '$current + [{type:"field",inboundTag:[$inbound],outboundTag:$outbound}]')" || return 10
                        ;;
                esac
            done < <(jq -r --arg id "$exit_id" --arg core "$core" --argjson nodes "$(<"$manifest")" '
                .bindings[] | select(.exit_id == $id) | .node_id as $nid |
                select(any($nodes.nodes[]; .id == $nid and .core == $core)) | $nid
            ' <<<"$relay_state")
        done <<<"$used_exit_ids"
    fi

    policy_nodes="$(jq -cn --arg core "$core" --argjson manifest "$(<"$manifest")" --argjson relay "$relay_state" '
        [$manifest.nodes[] | select(.core == $core) | . as $node |
         select(($node.ip_strategy // "auto") != "auto") |
         select((any($relay.bindings[]; .node_id == $node.id)) | not) |
         {id:$node.id,ip_strategy:($node.ip_strategy // "auto")}]
    ')" || return 10

    case "$core" in
        sing-box)
            policy_outbounds="$(jq -cn --argjson nodes "$policy_nodes" '
                $nodes | map(. as $node |
                    {type:"direct",tag:("direct-" + $node.id),
                     domain_resolver:{server:"local",strategy:$node.ip_strategy}})
            ')" || return 10
            policy_rules="$(jq -cn --argjson nodes "$policy_nodes" '
                $nodes | map({inbound:[.id],action:"route",outbound:("direct-" + .id)})
            ')" || return 10
            jq -n --argjson inbounds "$inbounds" --argjson relay_outbounds "$relay_outbounds" \
                --argjson relay_rules "$relay_rules" --argjson policy_outbounds "$policy_outbounds" \
                --argjson policy_rules "$policy_rules" '
                {
                    log: {level: "warn", timestamp: true},
                    inbounds: $inbounds,
                    outbounds: ([{type: "direct", tag: "direct"}] + $policy_outbounds + $relay_outbounds),
                    route: (if (($relay_rules + $policy_rules) | length) == 0 then {final:"direct"}
                            else {rules:($relay_rules + $policy_rules),final:"direct"} end)
                } + (if ($policy_outbounds | length) == 0 then {}
                     else {dns:{servers:[{type:"local",tag:"local"}]}} end)
            '
            ;;
        xray)
            policy_outbounds="$(jq -cn --argjson nodes "$policy_nodes" '
                def domain_strategy:
                    if . == "prefer_ipv4" then "UseIPv4v6"
                    elif . == "prefer_ipv6" then "UseIPv6v4"
                    elif . == "ipv4_only" then "ForceIPv4"
                    elif . == "ipv6_only" then "ForceIPv6"
                    else error("invalid IP strategy") end;
                $nodes | map(. as $node |
                    {protocol:"freedom",tag:("direct-" + $node.id),
                     settings:{domainStrategy:($node.ip_strategy | domain_strategy)}})
            ')" || return 10
            policy_rules="$(jq -cn --argjson nodes "$policy_nodes" '
                $nodes | map({type:"field",inboundTag:[.id],outboundTag:("direct-" + .id)})
            ')" || return 10
            jq -n --argjson inbounds "$inbounds" --argjson relay_outbounds "$relay_outbounds" \
                --argjson relay_rules "$relay_rules" --argjson policy_outbounds "$policy_outbounds" \
                --argjson policy_rules "$policy_rules" '{
                    log: {loglevel: "warning"},
                    inbounds: $inbounds,
                    outbounds: ([
                        {protocol: "freedom", tag: "direct"},
                        {protocol: "blackhole", tag: "block"}
                    ] + $policy_outbounds + $relay_outbounds),
                    routing: {rules: ($relay_rules + $policy_rules)}
                }'
            ;;
    esac
}

proxy_validate_config_with_binary() {
    local core="$1" config="$2" binary validation_output="" validation_detail=""
    binary="$(proxy_core_binary_path "$core")" || return 3
    [[ -x "$binary" ]] || {
        vps_cmd_error "$(proxy_core_label "$core") 二进制不可执行：$binary"
        return 3
    }
    jq -e . "$config" >/dev/null 2>&1 || {
        vps_cmd_error "生成的 $(proxy_core_label "$core") 配置不是有效 JSON"
        return 10
    }
    case "$core" in
        sing-box)
            validation_output="$("$binary" check -c "$config" 2>&1)" || {
                vps_cmd_error "sing-box 拒绝生成的配置"
                if jq -e 'any(.outbounds[]?; has("domain_resolver"))' "$config" >/dev/null 2>&1; then
                    vps_cmd_error "该节点策略需要支持现代 domain_resolver 的 sing-box；请先更新内核后重试"
                fi
                validation_detail="$(awk 'NF { detail=$0 } END { print detail }' <<<"$validation_output")"
                validation_detail="${validation_detail%$'\r'}"
                if ((${#validation_detail} > 512)); then
                    validation_detail="${validation_detail:0:509}..."
                fi
                [[ -z "$validation_detail" ]] || vps_cmd_error "sing-box 校验详情：$validation_detail"
                return 10
            }
            ;;
        xray)
            validation_output="$("$binary" run -test -c "$config" 2>&1)" || {
                validation_detail="$(awk 'NF { detail=$0 } END { print detail }' <<<"$validation_output")"
                validation_detail="${validation_detail%$'\r'}"
                if ((${#validation_detail} > 512)); then
                    validation_detail="${validation_detail:0:509}..."
                fi
                vps_cmd_error "Xray 拒绝生成的配置"
                [[ -z "$validation_detail" ]] || vps_cmd_error "Xray 校验详情：$validation_detail"
                return 10
            }
            ;;
    esac
}

proxy_write_transaction() {
    local core="$1" manifest_backup="$2" config_backup="$3" manifest_existed="$4" config_existed="$5"
    local relay_backup="${6:-}" relay_existed="${7:-false}" relay_touched="${8:-false}"
    local json
    json="$(jq -n \
        --arg core "$core" \
        --arg manifest_backup "$manifest_backup" \
        --arg config_backup "$config_backup" \
        --argjson manifest_existed "$manifest_existed" \
        --argjson config_existed "$config_existed" \
        --arg relay_backup "$relay_backup" \
        --argjson relay_existed "$relay_existed" \
        --argjson relay_touched "$relay_touched" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schema_version:1, core:$core, manifest_backup:$manifest_backup, config_backup:$config_backup,
          manifest_existed:$manifest_existed, config_existed:$config_existed,
          relay_backup:$relay_backup,relay_existed:$relay_existed,relay_touched:$relay_touched,
          created_at:$created_at}')" || return 20
    proxy_atomic_write_json "${PROXY_STATE_LOGICAL}/transaction.json" 0600 "$json"
}

proxy_remove_core_switch_cert_files() {
    local created_json="${1:-[]}" logical physical directory failed=0
    jq -e 'type == "array" and all(.[]; type == "string")' <<<"$created_json" >/dev/null 2>&1 || return 2
    while IFS= read -r logical; do
        [[ "$logical" =~ ^${PROXY_ETC_LOGICAL}/(sing-box|xray)/certs/node-[a-f0-9]{16}/(cert|key)(-[a-f0-9]{64})?\.pem$ ]] || {
            vps_cmd_error "切核事务包含不安全的证书路径：$logical"
            failed=1
            continue
        }
        physical="$(vps_cmd_system_path "$logical")" || { failed=1; continue; }
        [[ ! -L "$physical" ]] || {
            vps_cmd_error "拒绝删除符号链接证书：$physical"
            failed=1
            continue
        }
        if [[ -e "$physical" ]] && ! rm -f -- "$physical"; then failed=1; fi
        directory="${physical%/*}"
        [[ "$directory" == "$PROXY_ETC_DIR/"*"/certs/node-"* ]] || { failed=1; continue; }
        rmdir -- "$directory" >/dev/null 2>&1 || true
    done < <(jq -r '.[]' <<<"$created_json")
    ((failed == 0))
}

proxy_abort_core_switch_cert_stage() {
    local created_json="${1:-[]}" failed=0
    proxy_remove_core_switch_cert_files "$created_json" || failed=1
    if [[ -e "$PROXY_CORE_SWITCH_CERT_TRANSACTION" || -L "$PROXY_CORE_SWITCH_CERT_TRANSACTION" ]]; then
        [[ -f "$PROXY_CORE_SWITCH_CERT_TRANSACTION" && ! -L "$PROXY_CORE_SWITCH_CERT_TRANSACTION" ]] || return 30
        rm -f -- "$PROXY_CORE_SWITCH_CERT_TRANSACTION" || failed=1
    fi
    ((failed == 0))
}

proxy_recover_core_switch_cert_stage() {
    local created_json
    [[ -f "$PROXY_CORE_SWITCH_CERT_TRANSACTION" && ! -L "$PROXY_CORE_SWITCH_CERT_TRANSACTION" ]] || {
        vps_cmd_error "节点切核证书预备事务不安全：$PROXY_CORE_SWITCH_CERT_TRANSACTION"
        return 30
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_warning "演练检测到未完成的节点切核证书事务；实际执行前必须先恢复"
        return 30
    fi
    jq -e '
        .schema_version == 1 and .kind == "node-core-switch-cert-stage" and
        ((.cert_created | type) == "array") and all(.cert_created[]; type == "string")
    ' "$PROXY_CORE_SWITCH_CERT_TRANSACTION" >/dev/null 2>&1 || {
        vps_cmd_error "节点切核证书预备事务无法解析：$PROXY_CORE_SWITCH_CERT_TRANSACTION"
        return 30
    }
    created_json="$(jq -c '.cert_created' "$PROXY_CORE_SWITCH_CERT_TRANSACTION")"
    proxy_abort_core_switch_cert_stage "$created_json" || return 30
    vps_cmd_success "未完成的节点切核证书预备事务已清理"
}

proxy_core_switch_restore_file() {
    local backup="$1" existed="$2" logical="$3" mode="$4" physical
    if [[ "$existed" == true ]]; then
        proxy_restore_backup "$backup" "$logical" "$mode"
        return
    fi
    physical="$(vps_cmd_system_path "$logical")" || return $?
    [[ ! -L "$physical" ]] || return 30
    rm -f -- "$physical"
}

proxy_core_switch_restore_service() {
    local core="$1" registered="$2" wanted_active="$3" wanted_enabled="$4" failed=0
    [[ "$registered" == true ]] || return 0
    if [[ "$wanted_enabled" == true ]]; then
        proxy_service_is_enabled "$core" || proxy_service_action "$core" enable || failed=1
    elif proxy_service_is_enabled "$core"; then
        proxy_service_action "$core" disable || failed=1
    fi
    if [[ "$wanted_active" == true ]]; then
        proxy_service_action "$core" reload-manager || failed=1
        if ! proxy_service_is_active "$core"; then
            proxy_service_action "$core" start || failed=1
        fi
        proxy_service_is_active "$core" || failed=1
    elif proxy_service_is_active "$core"; then
        proxy_service_action "$core" stop || failed=1
    fi
    ((failed == 0))
}

proxy_recover_core_switch_transaction() {
    local source_core target_core source_registered target_registered
    local source_active source_enabled target_active target_enabled
    local manifest_backup manifest_existed source_config_backup source_config_existed
    local target_config_backup target_config_existed relay_backup relay_existed relay_touched
    local created_json failed=0 core registered
    [[ -f "$PROXY_TRANSACTION" && ! -L "$PROXY_TRANSACTION" ]] || return 30
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_warning "演练检测到未完成的节点切核事务；实际执行前必须先恢复"
        return 30
    fi
    jq -e '
        .schema_version == 2 and .kind == "node-core-switch" and
        (.source_core == "sing-box" or .source_core == "xray") and
        (.target_core == "sing-box" or .target_core == "xray") and
        .source_core != .target_core and
        ((.source_registered | type) == "boolean") and ((.target_registered | type) == "boolean") and
        ((.source_active | type) == "boolean") and ((.source_enabled | type) == "boolean") and
        ((.target_active | type) == "boolean") and ((.target_enabled | type) == "boolean") and
        ((.manifest_backup | type) == "string") and ((.manifest_existed | type) == "boolean") and
        ((.source_config_backup | type) == "string") and ((.source_config_existed | type) == "boolean") and
        ((.target_config_backup | type) == "string") and ((.target_config_existed | type) == "boolean") and
        ((.relay_backup | type) == "string") and ((.relay_existed | type) == "boolean") and
        ((.relay_touched | type) == "boolean") and
        ((.cert_created | type) == "array") and all(.cert_created[]; type == "string")
    ' "$PROXY_TRANSACTION" >/dev/null 2>&1 || {
        vps_cmd_error "发现无法解析的节点切核事务：$PROXY_TRANSACTION"
        return 30
    }
    source_core="$(jq -r '.source_core' "$PROXY_TRANSACTION")"
    target_core="$(jq -r '.target_core' "$PROXY_TRANSACTION")"
    source_registered="$(jq -r '.source_registered' "$PROXY_TRANSACTION")"
    target_registered="$(jq -r '.target_registered' "$PROXY_TRANSACTION")"
    source_active="$(jq -r '.source_active' "$PROXY_TRANSACTION")"
    source_enabled="$(jq -r '.source_enabled' "$PROXY_TRANSACTION")"
    target_active="$(jq -r '.target_active' "$PROXY_TRANSACTION")"
    target_enabled="$(jq -r '.target_enabled' "$PROXY_TRANSACTION")"
    manifest_backup="$(jq -r '.manifest_backup' "$PROXY_TRANSACTION")"
    manifest_existed="$(jq -r '.manifest_existed' "$PROXY_TRANSACTION")"
    source_config_backup="$(jq -r '.source_config_backup' "$PROXY_TRANSACTION")"
    source_config_existed="$(jq -r '.source_config_existed' "$PROXY_TRANSACTION")"
    target_config_backup="$(jq -r '.target_config_backup' "$PROXY_TRANSACTION")"
    target_config_existed="$(jq -r '.target_config_existed' "$PROXY_TRANSACTION")"
    relay_backup="$(jq -r '.relay_backup' "$PROXY_TRANSACTION")"
    relay_existed="$(jq -r '.relay_existed' "$PROXY_TRANSACTION")"
    relay_touched="$(jq -r '.relay_touched' "$PROXY_TRANSACTION")"
    created_json="$(jq -c '.cert_created' "$PROXY_TRANSACTION")"

    vps_cmd_warning "检测到未完成的节点切核事务，正在恢复原配置与服务状态"
    for core in "$source_core" "$target_core"; do
        if [[ "$core" == "$source_core" ]]; then registered="$source_registered"; else registered="$target_registered"; fi
        [[ "$registered" == true ]] || continue
        if proxy_service_is_active "$core"; then proxy_service_action "$core" stop || failed=1; fi
    done
    proxy_core_switch_restore_file "$source_config_backup" "$source_config_existed" \
        "$(proxy_core_config_logical "$source_core")" 0600 || failed=1
    proxy_core_switch_restore_file "$target_config_backup" "$target_config_existed" \
        "$(proxy_core_config_logical "$target_core")" 0600 || failed=1
    proxy_core_switch_restore_file "$manifest_backup" "$manifest_existed" "${PROXY_STATE_LOGICAL}/nodes.json" 0600 || failed=1
    if [[ "$relay_touched" == true ]]; then
        proxy_core_switch_restore_file "$relay_backup" "$relay_existed" "${PROXY_STATE_LOGICAL}/relay.json" 0600 || failed=1
    fi
    proxy_remove_core_switch_cert_files "$created_json" || failed=1
    proxy_core_switch_restore_service "$target_core" "$target_registered" "$target_active" "$target_enabled" || failed=1
    proxy_core_switch_restore_service "$source_core" "$source_registered" "$source_active" "$source_enabled" || failed=1
    if ((failed)); then
        vps_cmd_error "节点切核事务恢复不完整；事务记录已保留"
        return 30
    fi
    rm -f -- "$PROXY_TRANSACTION" || return 30
    if [[ -e "$PROXY_CORE_SWITCH_CERT_TRANSACTION" || -L "$PROXY_CORE_SWITCH_CERT_TRANSACTION" ]]; then
        [[ -f "$PROXY_CORE_SWITCH_CERT_TRANSACTION" && ! -L "$PROXY_CORE_SWITCH_CERT_TRANSACTION" ]] || return 30
        rm -f -- "$PROXY_CORE_SWITCH_CERT_TRANSACTION" || return 30
    fi
    vps_cmd_success "未完成的节点切核事务已恢复"
}

proxy_recover_transaction() {
    local core manifest_backup config_backup manifest_existed config_existed config_logical failed=0
    local relay_backup relay_existed relay_touched
    if [[ ! -e "$PROXY_TRANSACTION" && ! -L "$PROXY_TRANSACTION" ]]; then
        if [[ -e "$PROXY_CORE_SWITCH_CERT_TRANSACTION" || -L "$PROXY_CORE_SWITCH_CERT_TRANSACTION" ]]; then
            proxy_recover_core_switch_cert_stage
            return $?
        fi
        return 0
    fi
    if [[ -f "$PROXY_TRANSACTION" && ! -L "$PROXY_TRANSACTION" ]] &&
       jq -e '.schema_version == 2 and .kind == "node-core-switch"' "$PROXY_TRANSACTION" >/dev/null 2>&1; then
        proxy_recover_core_switch_transaction
        return $?
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_warning "演练检测到未完成的代理配置事务；实际执行前必须先恢复"
        return 30
    fi
    jq -e '
        .schema_version == 1 and
        (.core == "sing-box" or .core == "xray") and
        ((.manifest_backup | type) == "string") and
        ((.config_backup | type) == "string") and
        ((.manifest_existed | type) == "boolean") and
        ((.config_existed | type) == "boolean") and
        (((.relay_backup // "") | type) == "string") and
        (((.relay_existed // false) | type) == "boolean") and
        (((.relay_touched // false) | type) == "boolean")
    ' "$PROXY_TRANSACTION" >/dev/null 2>&1 || {
        vps_cmd_error "发现无法解析的代理事务记录：$PROXY_TRANSACTION"
        return 30
    }
    core="$(jq -r '.core' "$PROXY_TRANSACTION")"
    manifest_backup="$(jq -r '.manifest_backup' "$PROXY_TRANSACTION")"
    config_backup="$(jq -r '.config_backup' "$PROXY_TRANSACTION")"
    manifest_existed="$(jq -r '.manifest_existed' "$PROXY_TRANSACTION")"
    config_existed="$(jq -r '.config_existed' "$PROXY_TRANSACTION")"
    relay_backup="$(jq -r '.relay_backup // ""' "$PROXY_TRANSACTION")"
    relay_existed="$(jq -r '.relay_existed // false' "$PROXY_TRANSACTION")"
    relay_touched="$(jq -r '.relay_touched // false' "$PROXY_TRANSACTION")"
    config_logical="$(proxy_core_config_logical "$core")" || return 30
    vps_cmd_warning "检测到未完成的代理配置事务，正在恢复上一状态"
    if [[ "$config_existed" == "true" ]]; then
        proxy_restore_backup "$config_backup" "$config_logical" 0600 || failed=1
    else
        rm -f -- "$(proxy_core_config_path "$core")" || failed=1
    fi
    if [[ "$manifest_existed" == "true" ]]; then
        proxy_restore_backup "$manifest_backup" "${PROXY_STATE_LOGICAL}/nodes.json" 0600 || failed=1
    else
        rm -f -- "$PROXY_MANIFEST" || failed=1
    fi
    if [[ "$relay_touched" == true ]]; then
        if [[ "$relay_existed" == true ]]; then
            proxy_restore_backup "$relay_backup" "${PROXY_RELAY_LOGICAL}" 0600 || failed=1
        else
            rm -f -- "${PROXY_RELAY_FILE}" || failed=1
        fi
    fi
    ((failed == 0)) || return 30
    rm -f -- "$PROXY_TRANSACTION" || return 30
    if [[ "$relay_touched" == true ]] && declare -F proxy_relay_forward_sync >/dev/null 2>&1; then
        proxy_relay_forward_sync || return 30
    fi
    vps_cmd_success "未完成事务已恢复"
}

proxy_commit_core_switch() {
    local source_core="$1" target_core="$2" candidate_manifest="$3"
    local source_candidate_config="$4" target_candidate_config="$5"
    local candidate_relay="${6:-}" relay_touched="${7:-false}" created_json="${8:-[]}"
    local source_registered=false target_registered=false source_active=false source_enabled=false
    local target_active=false target_enabled=false source_remaining=0 target_want_enabled=false source_want_enabled=false
    local manifest_backup="" manifest_existed=false source_config_backup="" source_config_existed=false
    local target_config_backup="" target_config_existed=false relay_backup="" relay_existed=false
    local source_config_logical target_config_logical source_config_path target_config_path
    local source_pending target_pending transaction_json failed=0 post_commit_failed=0
    PROXY_CORE_SWITCH_COMMITTED=0
    proxy_core_valid "$source_core" && proxy_core_valid "$target_core" && [[ "$source_core" != "$target_core" ]] || return 2
    [[ -f "$candidate_manifest" && -f "$source_candidate_config" && -f "$target_candidate_config" ]] || return 2
    [[ "$relay_touched" == true || "$relay_touched" == false ]] || return 2
    jq -e 'type == "array" and all(.[]; type == "string")' <<<"$created_json" >/dev/null 2>&1 || return 2
    proxy_manifest_validate_file "$candidate_manifest" || return $?
    if [[ "$relay_touched" == true ]]; then
        [[ -n "$candidate_relay" ]] || return 2
        proxy_relay_validate_file "$candidate_relay" "$candidate_manifest" || return $?
    fi
    proxy_core_registered "$target_core" || {
        vps_cmd_error "切换节点前必须先安装或登记 $(proxy_core_label "$target_core")"
        return 3
    }
    target_registered=true
    proxy_core_registered "$source_core" && source_registered=true
    proxy_validate_config_with_binary "$target_core" "$target_candidate_config" || return $?
    if [[ "$source_registered" == true ]]; then
        proxy_validate_config_with_binary "$source_core" "$source_candidate_config" || return $?
    fi
    source_remaining="$(jq -r --arg core "$source_core" '[.nodes[] | select(.core == $core)] | length' "$candidate_manifest")" || return 10
    source_pending="$(proxy_core_pending_path "$source_core")" || return 2
    target_pending="$(proxy_core_pending_path "$target_core")" || return 2
    if [[ -e "$source_pending" || -L "$source_pending" || -e "$target_pending" || -L "$target_pending" ]]; then
        vps_cmd_error "源内核或目标内核存在待生效更改；请先分别 restart 后再切换节点"
        return 3
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "演练：原子写入 ${source_core}/${target_core} 配置与节点清单，随后由目标内核立即接管"
        [[ "$relay_touched" != true ]] || vps_cmd_info "演练：同时迁移节点的独占中转出口到 ${target_core}"
        return 0
    fi
    source_config_logical="$(proxy_core_config_logical "$source_core")" || return 2
    target_config_logical="$(proxy_core_config_logical "$target_core")" || return 2
    source_config_path="$(proxy_core_config_path "$source_core")" || return 2
    target_config_path="$(proxy_core_config_path "$target_core")" || return 2
    if [[ -f "$PROXY_MANIFEST" ]]; then
        manifest_existed=true
        manifest_backup="$(proxy_backup_file "$source_core" "${PROXY_STATE_LOGICAL}/nodes.json" nodes-before-core-switch.json)" || return 20
    fi
    if [[ -f "$source_config_path" ]]; then
        source_config_existed=true
        source_config_backup="$(proxy_backup_file "$source_core" "$source_config_logical" config-before-core-switch.json)" || return 20
    fi
    if [[ -f "$target_config_path" ]]; then
        target_config_existed=true
        target_config_backup="$(proxy_backup_file "$target_core" "$target_config_logical" config-before-core-switch.json)" || return 20
    fi
    if [[ "$relay_touched" == true && -f "${PROXY_RELAY_FILE:-}" ]]; then
        relay_existed=true
        relay_backup="$(proxy_backup_file relay "${PROXY_RELAY_LOGICAL}" relay-before-core-switch.json)" || return 20
    fi
    if [[ "$source_registered" == true ]]; then
        proxy_service_is_active "$source_core" && source_active=true
        proxy_service_is_enabled "$source_core" && source_enabled=true
    fi
    proxy_service_is_active "$target_core" && target_active=true
    proxy_service_is_enabled "$target_core" && target_enabled=true
    [[ "$target_enabled" == true || "$source_enabled" == true ]] && target_want_enabled=true
    [[ "$source_enabled" == true && "$source_remaining" != 0 ]] && source_want_enabled=true
    transaction_json="$(jq -n \
        --arg source_core "$source_core" --arg target_core "$target_core" \
        --argjson source_registered "$source_registered" --argjson target_registered "$target_registered" \
        --argjson source_active "$source_active" --argjson source_enabled "$source_enabled" \
        --argjson target_active "$target_active" --argjson target_enabled "$target_enabled" \
        --arg manifest_backup "$manifest_backup" --argjson manifest_existed "$manifest_existed" \
        --arg source_config_backup "$source_config_backup" --argjson source_config_existed "$source_config_existed" \
        --arg target_config_backup "$target_config_backup" --argjson target_config_existed "$target_config_existed" \
        --arg relay_backup "$relay_backup" --argjson relay_existed "$relay_existed" --argjson relay_touched "$relay_touched" \
        --argjson cert_created "$created_json" --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schema_version:2,kind:"node-core-switch",source_core:$source_core,target_core:$target_core,
          source_registered:$source_registered,target_registered:$target_registered,
          source_active:$source_active,source_enabled:$source_enabled,target_active:$target_active,target_enabled:$target_enabled,
          manifest_backup:$manifest_backup,manifest_existed:$manifest_existed,
          source_config_backup:$source_config_backup,source_config_existed:$source_config_existed,
          target_config_backup:$target_config_backup,target_config_existed:$target_config_existed,
          relay_backup:$relay_backup,relay_existed:$relay_existed,relay_touched:$relay_touched,
          cert_created:$cert_created,created_at:$created_at}')" || return 20
    proxy_atomic_write_json "${PROXY_STATE_LOGICAL}/transaction.json" 0600 "$transaction_json" || return 20
    if [[ -e "$PROXY_CORE_SWITCH_CERT_TRANSACTION" || -L "$PROXY_CORE_SWITCH_CERT_TRANSACTION" ]]; then
        if [[ ! -f "$PROXY_CORE_SWITCH_CERT_TRANSACTION" || -L "$PROXY_CORE_SWITCH_CERT_TRANSACTION" ]] ||
           ! rm -f -- "$PROXY_CORE_SWITCH_CERT_TRANSACTION"; then
            proxy_recover_core_switch_transaction || return 30
            return 20
        fi
    fi
    proxy_atomic_write_from_file "$source_candidate_config" "$source_config_logical" 0600 || failed=1
    ((failed)) || proxy_atomic_write_from_file "$target_candidate_config" "$target_config_logical" 0600 || failed=1
    ((failed)) || proxy_atomic_write_from_file "$candidate_manifest" "${PROXY_STATE_LOGICAL}/nodes.json" 0600 || failed=1
    if ((failed == 0)) && [[ "$relay_touched" == true ]]; then
        proxy_atomic_write_from_file "$candidate_relay" "${PROXY_RELAY_LOGICAL}" 0600 || failed=1
    fi
    if ((failed == 0)) && [[ "$source_active" == true ]]; then
        proxy_service_action "$source_core" stop || failed=1
    fi
    if ((failed == 0)); then
        proxy_service_action "$target_core" reload-manager || failed=1
    fi
    if ((failed == 0)); then
        if [[ "$target_active" == true ]]; then
            proxy_service_action "$target_core" restart || failed=1
        else
            proxy_service_action "$target_core" start || failed=1
        fi
        proxy_service_is_active "$target_core" || failed=1
    fi
    if ((failed == 0)) && [[ "$source_registered" == true && "$source_active" == true && "$source_remaining" != 0 ]]; then
        proxy_service_action "$source_core" reload-manager || failed=1
        proxy_service_action "$source_core" start || failed=1
        proxy_service_is_active "$source_core" || failed=1
    fi
    if ((failed == 0)); then
        if [[ "$target_want_enabled" == true ]]; then
            proxy_service_is_enabled "$target_core" || proxy_service_action "$target_core" enable || failed=1
        elif proxy_service_is_enabled "$target_core"; then
            proxy_service_action "$target_core" disable || failed=1
        fi
    fi
    if ((failed == 0)) && [[ "$source_registered" == true ]]; then
        if [[ "$source_want_enabled" == true ]]; then
            proxy_service_is_enabled "$source_core" || proxy_service_action "$source_core" enable || failed=1
        elif proxy_service_is_enabled "$source_core"; then
            proxy_service_action "$source_core" disable || failed=1
        fi
    fi
    if ((failed)); then
        if ! proxy_recover_core_switch_transaction; then return 30; fi
        return 20
    fi
    if ! rm -f -- "$PROXY_TRANSACTION"; then
        proxy_recover_core_switch_transaction || return 30
        return 20
    fi
    # shellcheck disable=SC2034 # Read by the node command after this helper returns.
    PROXY_CORE_SWITCH_COMMITTED=1
    proxy_save_lkg "$target_core" || post_commit_failed=1
    if [[ "$source_registered" == true && "$source_active" == true && "$source_remaining" != 0 ]]; then
        proxy_save_lkg "$source_core" || post_commit_failed=1
    fi
    if declare -F proxy_cleanup_orphan_certs >/dev/null 2>&1; then
        proxy_cleanup_orphan_certs "$source_core" || post_commit_failed=1
        proxy_cleanup_orphan_certs "$target_core" || post_commit_failed=1
    fi
    if ((post_commit_failed)); then
        vps_cmd_warning "节点已完成切核，但 LKG 或孤立证书整理未完整完成"
        return 30
    fi
}

proxy_mark_pending() {
    local core="$1" reason="$2" manifest_backup="${3:-}" config_backup="${4:-}" binary_backup="${5:-}" meta_backup="${6:-}"
    local relay_backup="${7:-}"
    local relay_existed="${8:-false}" relay_touched="${9:-false}"
    local relay_runtime_touched="${10:-false}" relay_cache_backup="${11:-}" relay_cache_existed="${12:-false}"
    local relay_nft_backup="${13:-}" relay_nft_existed="${14:-false}"
    local pending_logical pending_path json
    pending_logical="$(proxy_core_pending_logical "$core")" || return 2
    pending_path="$(proxy_core_pending_path "$core")" || return 2
    if [[ -e "$pending_path" ]]; then
        [[ -f "$pending_path" && ! -L "$pending_path" ]] || {
            vps_cmd_error "待生效状态文件不安全：$pending_path"
            return 30
        }
        jq -e --arg core "$core" '
            .schema_version == 1 and .core == $core and
            ((.manifest_backup | type) == "string") and
            ((.config_backup | type) == "string") and
            ((.binary_backup | type) == "string") and
            ((.meta_backup | type) == "string") and
            (((.relay_backup // "") | type) == "string") and
            (((.relay_existed // false) | type) == "boolean") and
            (((.relay_touched // false) | type) == "boolean") and
            (((.relay_runtime_touched // false) | type) == "boolean") and
            (((.relay_cache_backup // "") | type) == "string") and
            (((.relay_cache_existed // false) | type) == "boolean") and
            (((.relay_nft_backup // "") | type) == "string") and
            (((.relay_nft_existed // false) | type) == "boolean")
        ' "$pending_path" >/dev/null 2>&1 || {
            vps_cmd_error "待生效状态文件损坏，拒绝合并：$pending_path"
            return 30
        }
        json="$(jq \
            --arg reason "$reason" \
            --arg manifest_backup "$manifest_backup" --arg config_backup "$config_backup" \
            --arg binary_backup "$binary_backup" --arg meta_backup "$meta_backup" --arg relay_backup "$relay_backup" \
            --argjson relay_existed "$relay_existed" --argjson relay_touched "$relay_touched" \
            --argjson relay_runtime_touched "$relay_runtime_touched" \
            --arg relay_cache_backup "$relay_cache_backup" --argjson relay_cache_existed "$relay_cache_existed" \
            --arg relay_nft_backup "$relay_nft_backup" --argjson relay_nft_existed "$relay_nft_existed" '
            .reason = ((.reason // "") | if length == 0 then $reason elif (split(",") | index($reason)) != null then . else . + "," + $reason end) |
            if ((.manifest_backup // "") == "" and $manifest_backup != "") then .manifest_backup=$manifest_backup else . end |
            if ((.config_backup // "") == "" and $config_backup != "") then .config_backup=$config_backup else . end |
            if ((.binary_backup // "") == "" and $binary_backup != "") then .binary_backup=$binary_backup else . end |
            if ((.meta_backup // "") == "" and $meta_backup != "") then .meta_backup=$meta_backup else . end |
            if ((.relay_touched // false) == false and $relay_touched == true) then
                .relay_backup=$relay_backup | .relay_existed=$relay_existed | .relay_touched=true |
                .relay_runtime_touched=$relay_runtime_touched |
                .relay_cache_backup=$relay_cache_backup | .relay_cache_existed=$relay_cache_existed |
                .relay_nft_backup=$relay_nft_backup | .relay_nft_existed=$relay_nft_existed
            else . end
        ' "$pending_path")" || return 30
        proxy_atomic_write_json "$pending_logical" 0600 "$json"
        return $?
    fi
    json="$(jq -n \
        --arg core "$core" --arg reason "$reason" \
        --arg manifest_backup "$manifest_backup" --arg config_backup "$config_backup" \
        --arg binary_backup "$binary_backup" --arg meta_backup "$meta_backup" --arg relay_backup "$relay_backup" \
        --argjson relay_existed "$relay_existed" --argjson relay_touched "$relay_touched" \
        --argjson relay_runtime_touched "$relay_runtime_touched" \
        --arg relay_cache_backup "$relay_cache_backup" --argjson relay_cache_existed "$relay_cache_existed" \
        --arg relay_nft_backup "$relay_nft_backup" --argjson relay_nft_existed "$relay_nft_existed" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schema_version:1,core:$core,reason:$reason,manifest_backup:$manifest_backup,config_backup:$config_backup,
          binary_backup:$binary_backup,meta_backup:$meta_backup,relay_backup:$relay_backup,
          relay_existed:$relay_existed,relay_touched:$relay_touched,
          relay_runtime_touched:$relay_runtime_touched,
          relay_cache_backup:$relay_cache_backup,relay_cache_existed:$relay_cache_existed,
          relay_nft_backup:$relay_nft_backup,relay_nft_existed:$relay_nft_existed,
          created_at:$created_at}')" || return 20
    proxy_atomic_write_json "$pending_logical" 0600 "$json"
}

proxy_clear_pending() {
    local pending
    pending="$(proxy_core_pending_path "$1")" || return 2
    [[ ! -e "$pending" ]] || vps_cmd_run rm -f "$pending"
}

proxy_pending_can_auto_apply() {
    local pending="$1" reasons reason rest
    [[ -f "$pending" && ! -L "$pending" ]] || return 1
    reasons="$(jq -r '.reason // empty' "$pending" 2>/dev/null)" || return 1
    [[ -n "$reasons" ]] || return 1
    rest="${reasons},"
    while [[ -n "$rest" ]]; do
        reason="${rest%%,*}"
        rest="${rest#*,}"
        [[ -n "$reason" ]] || continue
        case "$reason" in
            node-add | node-edit | node-delete | node-ip-policy | relay-bind-add | relay-bind-delete | relay-exit-edit | relay-exit-delete) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

proxy_commit_manifest_config() {
    local core="$1" candidate_manifest="$2" candidate_config="$3" reason="$4"
    local candidate_relay="${5:-}"
    local manifest_backup="" config_backup="" manifest_existed=false config_existed=false
    local relay_backup="" relay_existed=false relay_touched=false
    local relay_runtime_touched=false relay_cache_backup="" relay_cache_existed=false
    local relay_nft_backup="" relay_nft_existed=false relay_nft_snapshot="" current_forward_count=0 candidate_forward_count=0
    local config_logical config_path failed=0 pending_required=0 active=0 pending_path
    proxy_core_registered "$core" || {
        vps_cmd_error "请先安装或登记 $(proxy_core_label "$core") 内核"
        return 3
    }
    proxy_manifest_validate_file "$candidate_manifest" || return $?
    if [[ -n "$candidate_relay" ]]; then
        declare -F proxy_relay_validate_file >/dev/null 2>&1 || return 20
        proxy_relay_validate_file "$candidate_relay" "$candidate_manifest" || return $?
        relay_touched=true
    fi
    proxy_validate_config_with_binary "$core" "$candidate_config" || return $?
    config_logical="$(proxy_core_config_logical "$core")" || return 2
    config_path="$(proxy_core_config_path "$core")" || return 2
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "演练：提交 ${core} 节点清单和已验证配置；运行中的内核在仅配置变更时将自动重启"
        return 0
    fi
    if [[ -f "$PROXY_MANIFEST" ]]; then
        manifest_existed=true
        manifest_backup="$(proxy_backup_file "$core" "${PROXY_STATE_LOGICAL}/nodes.json" nodes.json)" || return 20
    fi
    if [[ -f "$config_path" ]]; then
        config_existed=true
        config_backup="$(proxy_backup_file "$core" "$config_logical" config.json)" || return 20
    fi
    if [[ "$relay_touched" == true && -f "${PROXY_RELAY_FILE}" ]]; then
        relay_existed=true
        relay_backup="$(proxy_backup_file "$core" "${PROXY_RELAY_LOGICAL}" relay.json)" || return 20
    fi
    if [[ "$relay_touched" == true ]]; then
        [[ ! -f "${PROXY_RELAY_FILE}" ]] || current_forward_count="$(jq -r '.forwards | length' "${PROXY_RELAY_FILE}")" || return 20
        candidate_forward_count="$(jq -r '.forwards | length' "$candidate_relay")" || return 20
        if ((current_forward_count > 0 || candidate_forward_count > 0)); then
            relay_runtime_touched=true
            declare -F proxy_relay_forward_init >/dev/null 2>&1 || return 20
            proxy_relay_forward_init || return $?
            if [[ -f "$PROXY_RELAY_FORWARD_CACHE" && ! -L "$PROXY_RELAY_FORWARD_CACHE" ]]; then
                relay_cache_existed=true
                relay_cache_backup="$(proxy_backup_file relay "$PROXY_RELAY_FORWARD_CACHE_LOGICAL" relay-resolved.json)" || return 20
            fi
            relay_nft_snapshot="$(mktemp "${PROXY_STATE_DIR}/.relay-nft.pending.XXXXXX")" || return 20
            if proxy_relay_forward_nft_snapshot "$relay_nft_snapshot"; then
                relay_nft_existed=true
                relay_nft_backup="$(proxy_backup_runtime_file relay "$relay_nft_snapshot" relay-nftables.nft)" || {
                    rm -f -- "$relay_nft_snapshot"
                    return 20
                }
            fi
            rm -f -- "$relay_nft_snapshot"
        fi
    fi
    proxy_write_transaction "$core" "$manifest_backup" "$config_backup" "$manifest_existed" "$config_existed" \
        "$relay_backup" "$relay_existed" "$relay_touched" || return 20
    if ! proxy_atomic_write_from_file "$candidate_config" "$config_logical" 0600; then
        failed=1
    elif ! proxy_atomic_write_from_file "$candidate_manifest" "${PROXY_STATE_LOGICAL}/nodes.json" 0600; then
        failed=1
    elif [[ "$relay_touched" == true ]] && ! proxy_atomic_write_from_file "$candidate_relay" "${PROXY_RELAY_LOGICAL}" 0600; then
        failed=1
    fi
    if ((failed)); then
        proxy_recover_transaction || return 30
        return 20
    fi
    rm -f -- "$PROXY_TRANSACTION" || return 30
    if proxy_service_is_active "$core"; then
        active=1
        pending_required=1
    else
        pending_path="$(proxy_core_pending_path "$core")" || return 30
        [[ ! -e "$pending_path" && ! -L "$pending_path" ]] || pending_required=1
    fi
    if ((pending_required)) && ! proxy_mark_pending "$core" "$reason" "$manifest_backup" "$config_backup" "" "" \
        "$relay_backup" "$relay_existed" "$relay_touched" "$relay_runtime_touched" \
        "$relay_cache_backup" "$relay_cache_existed" "$relay_nft_backup" "$relay_nft_existed"; then
        failed=0
        if [[ "$config_existed" == "true" ]]; then
            proxy_restore_backup "$config_backup" "$config_logical" 0600 || failed=1
        else
            rm -f -- "$config_path" || failed=1
        fi
        if [[ "$manifest_existed" == "true" ]]; then
            proxy_restore_backup "$manifest_backup" "${PROXY_STATE_LOGICAL}/nodes.json" 0600 || failed=1
        else
            rm -f -- "$PROXY_MANIFEST" || failed=1
        fi
        if [[ "$relay_touched" == true ]]; then
            if [[ "$relay_existed" == true ]]; then
                proxy_restore_backup "$relay_backup" "${PROXY_RELAY_LOGICAL}" 0600 || failed=1
            else
                rm -f -- "${PROXY_RELAY_FILE}" || failed=1
            fi
        fi
        ((failed == 0)) || return 30
        vps_cmd_error "无法记录待生效状态，已恢复本次提交前的配置"
        return 30
    fi
    if ((active)); then
        pending_path="$(proxy_core_pending_path "$core")" || return 30
        if proxy_pending_can_auto_apply "$pending_path"; then
            _proxy_core_restart_locked "$core" || return $?
        else
            vps_cmd_warning "配置已校验并写入；$(proxy_core_label "$core") 正在运行，请显式 restart 应用"
        fi
    elif ((pending_required)); then
        vps_cmd_info "配置已校验并合并到待生效状态；将在下次启动 $(proxy_core_label "$core") 时应用"
    else
        vps_cmd_info "配置已校验并写入；将在下次启动 $(proxy_core_label "$core") 时生效"
    fi
}

proxy_save_lkg() {
    local core="$1" lkg config meta binary relay_nft
    lkg="$(proxy_core_lkg_dir "$core")" || return 2
    config="$(proxy_core_config_path "$core")" || return 2
    meta="$(proxy_core_meta_path "$core")" || return 2
    binary="$(proxy_core_binary_path "$core")" || return 2
    mkdir -p -- "$lkg" || return 20
    chmod 0700 -- "$lkg" || return 20
    [[ ! -f "$config" ]] || cp -p -- "$config" "$lkg/config.json" || return 20
    [[ ! -f "$PROXY_MANIFEST" ]] || cp -p -- "$PROXY_MANIFEST" "$lkg/nodes.json" || return 20
    [[ -z "${PROXY_RELAY_FILE:-}" || ! -f "$PROXY_RELAY_FILE" ]] || cp -p -- "$PROXY_RELAY_FILE" "$lkg/relay.json" || return 20
    rm -f -- "$lkg/relay-resolved.json" "$lkg/relay-nftables.nft" || return 20
    if [[ -n "${PROXY_RELAY_FILE:-}" && -f "$PROXY_RELAY_FILE" ]] &&
       [[ "$(jq -r '.forwards | length' "$PROXY_RELAY_FILE")" != 0 ]]; then
        declare -F proxy_relay_forward_init >/dev/null 2>&1 || return 20
        proxy_relay_forward_init || return $?
        [[ ! -f "$PROXY_RELAY_FORWARD_CACHE" ]] || cp -p -- "$PROXY_RELAY_FORWARD_CACHE" "$lkg/relay-resolved.json" || return 20
        relay_nft="$lkg/relay-nftables.nft"
        if ! proxy_relay_forward_nft_snapshot "$relay_nft"; then rm -f -- "$relay_nft"; fi
    fi
    [[ ! -f "$meta" ]] || cp -p -- "$meta" "$lkg/core.json" || return 20
    [[ ! -x "$binary" || -L "$binary" ]] || cp -p -- "$binary" "$lkg/binary" || return 20
}

proxy_restore_pending() {
    local core="$1" pending manifest_backup config_backup binary_backup meta_backup failed=0
    local relay_backup relay_existed relay_touched relay_runtime_touched
    local relay_cache_backup relay_cache_existed relay_nft_backup relay_nft_existed
    local binary_logical meta_logical config_logical
    pending="$(proxy_core_pending_path "$core")" || return 2
    [[ -f "$pending" && ! -L "$pending" ]] || return 1
    jq -e --arg core "$core" '
        .schema_version == 1 and .core == $core and
        ((.manifest_backup | type) == "string") and
        ((.config_backup | type) == "string") and
        ((.binary_backup | type) == "string") and
        ((.meta_backup | type) == "string") and
        (((.relay_backup // "") | type) == "string") and
        (((.relay_existed // false) | type) == "boolean") and
        (((.relay_touched // false) | type) == "boolean") and
        (((.relay_runtime_touched // false) | type) == "boolean") and
        (((.relay_cache_backup // "") | type) == "string") and
        (((.relay_cache_existed // false) | type) == "boolean") and
        (((.relay_nft_backup // "") | type) == "string") and
        (((.relay_nft_existed // false) | type) == "boolean")
    ' "$pending" >/dev/null 2>&1 || {
        vps_cmd_error "待生效状态损坏，拒绝自动回滚：$pending"
        return 30
    }
    manifest_backup="$(jq -r '.manifest_backup // ""' "$pending")"
    config_backup="$(jq -r '.config_backup // ""' "$pending")"
    binary_backup="$(jq -r '.binary_backup // ""' "$pending")"
    meta_backup="$(jq -r '.meta_backup // ""' "$pending")"
    relay_backup="$(jq -r '.relay_backup // ""' "$pending")"
    relay_existed="$(jq -r '.relay_existed // false' "$pending")"
    relay_touched="$(jq -r '.relay_touched // false' "$pending")"
    relay_runtime_touched="$(jq -r '.relay_runtime_touched // false' "$pending")"
    relay_cache_backup="$(jq -r '.relay_cache_backup // ""' "$pending")"
    relay_cache_existed="$(jq -r '.relay_cache_existed // false' "$pending")"
    relay_nft_backup="$(jq -r '.relay_nft_backup // ""' "$pending")"
    relay_nft_existed="$(jq -r '.relay_nft_existed // false' "$pending")"
    binary_logical="$(proxy_core_binary_logical "$core")" || return 30
    meta_logical="$(proxy_core_meta_logical "$core")" || return 30
    config_logical="$(proxy_core_config_logical "$core")" || return 30
    [[ -z "$manifest_backup" ]] || proxy_restore_backup "$manifest_backup" "${PROXY_STATE_LOGICAL}/nodes.json" 0600 || failed=1
    [[ -z "$config_backup" ]] || proxy_restore_backup "$config_backup" "$config_logical" 0600 || failed=1
    [[ -z "$binary_backup" ]] || proxy_restore_backup "$binary_backup" "$binary_logical" 0755 || failed=1
    [[ -z "$meta_backup" ]] || proxy_restore_backup "$meta_backup" "$meta_logical" 0600 || failed=1
    if [[ "$relay_touched" == true ]]; then
        if [[ "$relay_existed" == true ]]; then
            proxy_restore_backup "$relay_backup" "${PROXY_RELAY_LOGICAL}" 0600 || failed=1
        else
            rm -f -- "${PROXY_RELAY_FILE}" || failed=1
        fi
    fi
    if [[ "$relay_runtime_touched" == true ]]; then
        declare -F proxy_relay_forward_init >/dev/null 2>&1 || failed=1
        if ((failed == 0)); then proxy_relay_forward_init || failed=1; fi
        if ((failed == 0)); then
            if [[ "$relay_cache_existed" == true ]]; then
                proxy_restore_backup "$relay_cache_backup" "$PROXY_RELAY_FORWARD_CACHE_LOGICAL" 0600 || failed=1
            else
                rm -f -- "$PROXY_RELAY_FORWARD_CACHE" || failed=1
            fi
            if [[ "$relay_nft_existed" == true ]]; then
                proxy_relay_forward_nft_restore "$relay_nft_backup" || failed=1
            else
                proxy_relay_forward_nft_clear || failed=1
            fi
        fi
    fi
    ((failed == 0)) || return 30
    rm -f -- "$pending" || return 30
    if [[ "$relay_touched" == true && "$relay_runtime_touched" != true ]] && declare -F proxy_relay_forward_sync >/dev/null 2>&1; then
        proxy_relay_forward_sync || return 30
    fi
}

proxy_profile_cores() {
    local profile="$1" found=0
    if proxy_sb_supports_profile "$profile"; then
        printf 'sing-box\n'
        found=1
    fi
    if proxy_xray_supports_profile "$profile"; then
        printf 'xray\n'
        found=1
    fi
    ((found == 1))
}

proxy_profile_label() {
    local profile="$1"
    if proxy_sb_supports_profile "$profile"; then
        proxy_sb_profile_label "$profile"
    elif proxy_xray_supports_profile "$profile"; then
        proxy_xray_profile_label "$profile"
    else
        return 2
    fi
}

proxy_installed_cores() {
    local core
    for core in sing-box xray; do
        proxy_core_registered "$core" && printf '%s\n' "$core"
    done
}
