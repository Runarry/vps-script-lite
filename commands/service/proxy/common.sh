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
PROXY_INIT_SYSTEM="unknown"
PROXY_PACKAGE_MANAGER="unknown"
PROXY_ARCH="unknown"

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
    printf '%s [是/否，输入 y 确认] ' "$prompt" >&2
    IFS= read -r reply || return 130
    reply="$(vps_cmd_trim "$reply")"
    [[ "$reply" == "y" || "$reply" == "Y" || "$reply" == "yes" || "$reply" == "YES" ]]
}

proxy_prompt_select() {
    local prompt="${1:-}" default_value="${2:-}" choice value label index
    local -a values=() labels=()
    shift 2 || return 2
    [[ -n "$prompt" ]] && (($# >= 2 && $# % 2 == 0)) || return 2
    while (($#)); do
        values+=("$1")
        labels+=("$2")
        shift 2
    done

    while true; do
        printf '%s\n' "$prompt" >&2
        for ((index = 0; index < ${#values[@]}; index++)); do
            value="${values[$index]}"
            label="${labels[$index]}"
            if [[ -n "$default_value" && "$value" == "$default_value" ]]; then
                printf '  [%d] %s（默认）\n' "$((index + 1))" "$label" >&2
            else
                printf '  [%d] %s\n' "$((index + 1))" "$label" >&2
            fi
        done
        printf '  [q] 返回\n选择：' >&2
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
                if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((10#$choice <= ${#values[@]})); then
                    printf '%s' "${values[$((10#$choice - 1))]}"
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
    proxy_core_valid "$core" || return 2
    safe_label="${label//[^a-zA-Z0-9._-]/_}"
    source="$(vps_cmd_system_path "$logical_source")" || return $?
    vps_cmd_require_no_symlink_components "$source" || return $?
    [[ -f "$source" && ! -L "$source" ]] || return 1
    backup_root="${PROXY_BACKUP_DIR}/${core}"
    vps_cmd_require_no_symlink_components "$backup_root" || return $?
    mkdir -p -- "$backup_root" || return 20
    chmod 0700 -- "$backup_root" || return 20
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_dir="$(mktemp -d --tmpdir="$backup_root" "${timestamp}.XXXXXX")" || return 20
    chmod 0700 -- "$backup_dir" || return 20
    cp -p -- "$source" "${backup_dir}/${safe_label}" || return 20
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
        openrc) rc-update show default 2>/dev/null | awk '{print $1}' | grep -Fxq "$service" ;;
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
    local core="$1" manifest="$2" node rendered inbounds='[]'
    proxy_core_valid "$core" || return 2
    proxy_manifest_validate_file "$manifest" || return $?
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

    case "$core" in
        sing-box)
            jq -n --argjson inbounds "$inbounds" '{
                log: {level: "warn", timestamp: true},
                inbounds: $inbounds,
                outbounds: [{type: "direct", tag: "direct"}],
                route: {final: "direct"}
            }'
            ;;
        xray)
            jq -n --argjson inbounds "$inbounds" '{
                log: {loglevel: "warning"},
                inbounds: $inbounds,
                outbounds: [
                    {protocol: "freedom", tag: "direct"},
                    {protocol: "blackhole", tag: "block"}
                ],
                routing: {rules: []}
            }'
            ;;
    esac
}

proxy_validate_config_with_binary() {
    local core="$1" config="$2" binary
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
            "$binary" check -c "$config" >/dev/null 2>&1 || {
                vps_cmd_error "sing-box 拒绝生成的配置"
                return 10
            }
            ;;
        xray)
            "$binary" run -test -c "$config" >/dev/null 2>&1 || {
                vps_cmd_error "Xray 拒绝生成的配置"
                return 10
            }
            ;;
    esac
}

proxy_write_transaction() {
    local core="$1" manifest_backup="$2" config_backup="$3" manifest_existed="$4" config_existed="$5"
    local json
    json="$(jq -n \
        --arg core "$core" \
        --arg manifest_backup "$manifest_backup" \
        --arg config_backup "$config_backup" \
        --argjson manifest_existed "$manifest_existed" \
        --argjson config_existed "$config_existed" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schema_version:1, core:$core, manifest_backup:$manifest_backup, config_backup:$config_backup, manifest_existed:$manifest_existed, config_existed:$config_existed, created_at:$created_at}')" || return 20
    proxy_atomic_write_json "${PROXY_STATE_LOGICAL}/transaction.json" 0600 "$json"
}

proxy_recover_transaction() {
    local core manifest_backup config_backup manifest_existed config_existed config_logical failed=0
    [[ -e "$PROXY_TRANSACTION" ]] || return 0
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
        ((.config_existed | type) == "boolean")
    ' "$PROXY_TRANSACTION" >/dev/null 2>&1 || {
        vps_cmd_error "发现无法解析的代理事务记录：$PROXY_TRANSACTION"
        return 30
    }
    core="$(jq -r '.core' "$PROXY_TRANSACTION")"
    manifest_backup="$(jq -r '.manifest_backup' "$PROXY_TRANSACTION")"
    config_backup="$(jq -r '.config_backup' "$PROXY_TRANSACTION")"
    manifest_existed="$(jq -r '.manifest_existed' "$PROXY_TRANSACTION")"
    config_existed="$(jq -r '.config_existed' "$PROXY_TRANSACTION")"
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
    ((failed == 0)) || return 30
    rm -f -- "$PROXY_TRANSACTION" || return 30
    vps_cmd_success "未完成事务已恢复"
}

proxy_mark_pending() {
    local core="$1" reason="$2" manifest_backup="${3:-}" config_backup="${4:-}" binary_backup="${5:-}" meta_backup="${6:-}"
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
            ((.meta_backup | type) == "string")
        ' "$pending_path" >/dev/null 2>&1 || {
            vps_cmd_error "待生效状态文件损坏，拒绝合并：$pending_path"
            return 30
        }
        json="$(jq \
            --arg reason "$reason" \
            --arg manifest_backup "$manifest_backup" --arg config_backup "$config_backup" \
            --arg binary_backup "$binary_backup" --arg meta_backup "$meta_backup" '
            .reason = ((.reason // "") | if length == 0 then $reason elif (split(",") | index($reason)) != null then . else . + "," + $reason end) |
            if ((.manifest_backup // "") == "" and $manifest_backup != "") then .manifest_backup=$manifest_backup else . end |
            if ((.config_backup // "") == "" and $config_backup != "") then .config_backup=$config_backup else . end |
            if ((.binary_backup // "") == "" and $binary_backup != "") then .binary_backup=$binary_backup else . end |
            if ((.meta_backup // "") == "" and $meta_backup != "") then .meta_backup=$meta_backup else . end
        ' "$pending_path")" || return 30
        proxy_atomic_write_json "$pending_logical" 0600 "$json"
        return $?
    fi
    json="$(jq -n \
        --arg core "$core" --arg reason "$reason" \
        --arg manifest_backup "$manifest_backup" --arg config_backup "$config_backup" \
        --arg binary_backup "$binary_backup" --arg meta_backup "$meta_backup" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schema_version:1,core:$core,reason:$reason,manifest_backup:$manifest_backup,config_backup:$config_backup,binary_backup:$binary_backup,meta_backup:$meta_backup,created_at:$created_at}')" || return 20
    proxy_atomic_write_json "$pending_logical" 0600 "$json"
}

proxy_clear_pending() {
    local pending
    pending="$(proxy_core_pending_path "$1")" || return 2
    [[ ! -e "$pending" ]] || vps_cmd_run rm -f "$pending"
}

proxy_commit_manifest_config() {
    local core="$1" candidate_manifest="$2" candidate_config="$3" reason="$4"
    local manifest_backup="" config_backup="" manifest_existed=false config_existed=false
    local config_logical config_path failed=0 pending_required=0 active=0 pending_path
    proxy_core_registered "$core" || {
        vps_cmd_error "请先安装或登记 $(proxy_core_label "$core") 内核"
        return 3
    }
    proxy_manifest_validate_file "$candidate_manifest" || return $?
    proxy_validate_config_with_binary "$core" "$candidate_config" || return $?
    config_logical="$(proxy_core_config_logical "$core")" || return 2
    config_path="$(proxy_core_config_path "$core")" || return 2
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "演练：提交 ${core} 节点清单和已验证配置；服务不会自动重启"
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
    proxy_write_transaction "$core" "$manifest_backup" "$config_backup" "$manifest_existed" "$config_existed" || return 20
    if ! proxy_atomic_write_from_file "$candidate_config" "$config_logical" 0600; then
        failed=1
    elif ! proxy_atomic_write_from_file "$candidate_manifest" "${PROXY_STATE_LOGICAL}/nodes.json" 0600; then
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
    if ((pending_required)) && ! proxy_mark_pending "$core" "$reason" "$manifest_backup" "$config_backup" "" ""; then
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
        ((failed == 0)) || return 30
        vps_cmd_error "无法记录待生效状态，已恢复本次提交前的配置"
        return 30
    fi
    if ((active)); then
        vps_cmd_warning "配置已校验并写入；$(proxy_core_label "$core") 正在运行，请显式 restart 应用"
    elif ((pending_required)); then
        vps_cmd_info "配置已校验并合并到待生效状态；将在下次启动 $(proxy_core_label "$core") 时应用"
    else
        vps_cmd_info "配置已校验并写入；将在下次启动 $(proxy_core_label "$core") 时生效"
    fi
}

proxy_save_lkg() {
    local core="$1" lkg config meta binary
    lkg="$(proxy_core_lkg_dir "$core")" || return 2
    config="$(proxy_core_config_path "$core")" || return 2
    meta="$(proxy_core_meta_path "$core")" || return 2
    binary="$(proxy_core_binary_path "$core")" || return 2
    mkdir -p -- "$lkg" || return 20
    chmod 0700 -- "$lkg" || return 20
    [[ ! -f "$config" ]] || cp -p -- "$config" "$lkg/config.json" || return 20
    [[ ! -f "$PROXY_MANIFEST" ]] || cp -p -- "$PROXY_MANIFEST" "$lkg/nodes.json" || return 20
    [[ ! -f "$meta" ]] || cp -p -- "$meta" "$lkg/core.json" || return 20
    [[ ! -x "$binary" || -L "$binary" ]] || cp -p -- "$binary" "$lkg/binary" || return 20
}

proxy_restore_pending() {
    local core="$1" pending manifest_backup config_backup binary_backup meta_backup failed=0
    local binary_logical meta_logical config_logical
    pending="$(proxy_core_pending_path "$core")" || return 2
    [[ -f "$pending" && ! -L "$pending" ]] || return 1
    jq -e --arg core "$core" '
        .schema_version == 1 and .core == $core and
        ((.manifest_backup | type) == "string") and
        ((.config_backup | type) == "string") and
        ((.binary_backup | type) == "string") and
        ((.meta_backup | type) == "string")
    ' "$pending" >/dev/null 2>&1 || {
        vps_cmd_error "待生效状态损坏，拒绝自动回滚：$pending"
        return 30
    }
    manifest_backup="$(jq -r '.manifest_backup // ""' "$pending")"
    config_backup="$(jq -r '.config_backup // ""' "$pending")"
    binary_backup="$(jq -r '.binary_backup // ""' "$pending")"
    meta_backup="$(jq -r '.meta_backup // ""' "$pending")"
    binary_logical="$(proxy_core_binary_logical "$core")" || return 30
    meta_logical="$(proxy_core_meta_logical "$core")" || return 30
    config_logical="$(proxy_core_config_logical "$core")" || return 30
    [[ -z "$manifest_backup" ]] || proxy_restore_backup "$manifest_backup" "${PROXY_STATE_LOGICAL}/nodes.json" 0600 || failed=1
    [[ -z "$config_backup" ]] || proxy_restore_backup "$config_backup" "$config_logical" 0600 || failed=1
    [[ -z "$binary_backup" ]] || proxy_restore_backup "$binary_backup" "$binary_logical" 0755 || failed=1
    [[ -z "$meta_backup" ]] || proxy_restore_backup "$meta_backup" "$meta_logical" 0600 || failed=1
    ((failed == 0)) || return 30
    rm -f -- "$pending" || return 30
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
