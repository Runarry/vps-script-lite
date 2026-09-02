# shellcheck shell=bash
# Relay state, CRUD, bindings and interactive management for proxy.sh.
# Sourcing this file only defines functions; proxy_relay_init must be called
# after proxy_common_init.

readonly PROXY_RELAY_SCHEMA_VERSION=1
PROXY_RELAY_LOGICAL=""
PROXY_RELAY_FILE=""
PROXY_RELAY_CACHE_LOGICAL=""
PROXY_RELAY_CACHE_FILE=""

proxy_relay_init() {
    PROXY_RELAY_LOGICAL="${PROXY_STATE_LOGICAL}/relay.json"
    PROXY_RELAY_FILE="${PROXY_STATE_DIR}/relay.json"
    PROXY_RELAY_CACHE_LOGICAL="${PROXY_STATE_LOGICAL}/relay-resolved.json"
    PROXY_RELAY_CACHE_FILE="${PROXY_STATE_DIR}/relay-resolved.json"
}

proxy_relay_default() {
    printf '{"schema_version":%d,"exits":[],"bindings":[],"forwards":[]}\n' "$PROXY_RELAY_SCHEMA_VERSION"
}

proxy_relay_cache_default() {
    printf '{"schema_version":1,"resolved":[],"updated_at":"","degraded":[]}\n'
}

proxy_relay_validate_file() {
    local file="$1" nodes_file="${2:-$PROXY_MANIFEST}" exit parsed
    [[ -f "$file" && ! -L "$file" ]] || {
        vps_cmd_error "中转状态不存在或不是安全的普通文件：$file"
        return 3
    }
    jq -e --argjson schema "$PROXY_RELAY_SCHEMA_VERSION" '
        def name: type == "string" and length > 0 and length <= 128 and test("[\\r\\n]") == false;
        def text: type == "string" and length > 0 and length <= 253 and test("[\\r\\n]") == false;
        def uri: type == "string" and length > 0 and length <= 8192 and test("[\\r\\n]") == false;
        def port: type == "number" and floor == . and . >= 1 and . <= 65535;
        . as $root |
        type == "object" and .schema_version == $schema and
        ((.exits | type) == "array") and ((.bindings | type) == "array") and
        ((.forwards | type) == "array") and
        (([.exits[].id] | length) == ([.exits[].id] | unique | length)) and
        (([.exits[].name] | length) == ([.exits[].name] | unique | length)) and
        (([.bindings[].id] | length) == ([.bindings[].id] | unique | length)) and
        (([.bindings[].node_id] | length) == ([.bindings[].node_id] | unique | length)) and
        (([.forwards[].id] | length) == ([.forwards[].id] | unique | length)) and
        (([.forwards[].name] | length) == ([.forwards[].name] | unique | length)) and
        all(.exits[];
            (.id | type == "string" and test("^exit-[a-f0-9]{16}$")) and
            (.name | name) and (.type == "protocol" or .type == "direct") and
            ((.endpoint | type) == "object") and (.endpoint.host | text) and
            (.endpoint.port | port) and
            ((.network_hint // "tcp") == "tcp" or (.network_hint // "tcp") == "udp" or
             (.network_hint // "tcp") == "both") and
            ((.created_at | type) == "string") and ((.updated_at | type) == "string") and
            (if .type == "protocol" then
                (.core == "sing-box" or .core == "xray") and
                (.profile | name) and (.uri | uri) and ((.descriptor | type) == "object")
             else
                ((.core // "") == "") and ((.profile // "") == "") and
                ((.uri // "") == "") and ((.descriptor // {}) | type == "object")
             end)
        ) and
        all(.bindings[];
            (.id | type == "string" and test("^bind-[a-f0-9]{16}$")) and
            (.node_id | type == "string" and test("^node-[a-f0-9]{16}$")) and
            (.exit_id | type == "string" and test("^exit-[a-f0-9]{16}$")) and
            ((.created_at | type) == "string") and ((.updated_at | type) == "string") and
            (.exit_id as $eid | any($root.exits[]; .id == $eid and .type == "protocol"))
        ) and
        all(.forwards[];
            (.id | type == "string" and test("^forward-[a-f0-9]{16}$")) and
            (.name | name) and
            (.exit_id | type == "string" and test("^exit-[a-f0-9]{16}$")) and
            (.listen_port_start | port) and (.listen_port_end | port) and
            (.listen_port_start <= .listen_port_end) and
            (.network == "tcp" or .network == "udp" or .network == "both") and
            ((has("family") | not) or .family == "dual" or .family == "ipv4" or .family == "ipv6") and
            (.publish_address | text) and
            ((.created_at | type) == "string") and ((.updated_at | type) == "string") and
            (.exit_id as $eid | any($root.exits[]; .id == $eid))
        )
    ' "$file" >/dev/null 2>&1 || {
        vps_cmd_error "中转状态格式、唯一性或引用校验失败：$file"
        return 10
    }

    if declare -F proxy_relay_uri_parse >/dev/null 2>&1; then
        while IFS= read -r exit; do
            parsed="$(proxy_relay_uri_parse "$(jq -r '.uri' <<<"$exit")" "$(jq -r '.profile' <<<"$exit")")" || return $?
            jq -e --argjson parsed "$parsed" '
                .descriptor == $parsed and .endpoint == $parsed.endpoint and
                .network_hint == $parsed.network_hint and
                (.core as $core | $parsed.compatible_cores | index($core) != null)
            ' <<<"$exit" >/dev/null 2>&1 || {
                vps_cmd_error "协议出口的 URI、规范化描述或内核选择不一致：$(jq -r '.id' <<<"$exit")"
                return 10
            }
            if declare -F proxy_relay_render_outbound >/dev/null 2>&1; then
                proxy_relay_render_outbound "$(jq -r '.core' <<<"$exit")" "$exit" >/dev/null || {
                    vps_cmd_error "协议出口无法由所选内核安全渲染：$(jq -r '.id' <<<"$exit")"
                    return 10
                }
            fi
        done < <(jq -c '.exits[] | select(.type == "protocol")' "$file")
    fi

    if jq -e '.bindings | length > 0' "$file" >/dev/null 2>&1; then
        [[ -f "$nodes_file" && ! -L "$nodes_file" ]] || {
            vps_cmd_error "中转关联存在，但节点清单不可用"
            return 10
        }
        proxy_manifest_validate_file "$nodes_file" || return $?
        jq -e --slurpfile nodes "$nodes_file" '
            . as $root |
            all(.bindings[];
                .node_id as $nid | .exit_id as $eid |
                ([ $nodes[0].nodes[] | select(.id == $nid) ][0]) as $node |
                ([ $root.exits[] | select(.id == $eid) ][0]) as $exit |
                ($node != null and $exit != null and $exit.type == "protocol" and
                 $node.core == $exit.core)
            )
        ' "$file" >/dev/null 2>&1 || {
            vps_cmd_error "中转入口不存在或入口与出口内核不一致"
            return 10
        }
    fi
    if declare -F proxy_relay_forward_validate_manifest >/dev/null 2>&1; then
        proxy_relay_forward_validate_manifest "$file" "$nodes_file" || return $?
    fi
}

proxy_relay_ensure() {
    proxy_ensure_layout || return $?
    if [[ -e "$PROXY_RELAY_FILE" ]]; then
        proxy_relay_validate_file "$PROXY_RELAY_FILE"
        return $?
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "演练：初始化中转状态 ${PROXY_RELAY_FILE}"
        return 0
    fi
    proxy_relay_default | vps_cmd_atomic_write "$PROXY_RELAY_LOGICAL" 0600 || return 20
    proxy_relay_validate_file "$PROXY_RELAY_FILE"
}

proxy_relay_prepare_state() {
    vps_cmd_require_root || return $?
    proxy_require_platform || return $?
    proxy_ensure_mutation_tools relay-state jq openssl base64 || return $?
    proxy_stop_after_dependency_plan && return 0
    proxy_manifest_ensure || return $?
    proxy_relay_ensure
}

proxy_relay_generate_id() {
    local prefix="$1" id attempt
    case "$prefix" in exit | bind | forward) ;; *) return 2 ;; esac
    for attempt in {1..20}; do
        if command -v openssl >/dev/null 2>&1; then
            id="${prefix}-$(openssl rand -hex 8 2>/dev/null)"
        elif [[ -r /dev/urandom ]]; then
            id="${prefix}-$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
        else
            return 20
        fi
        [[ "$id" =~ ^${prefix}-[a-f0-9]{16}$ ]] || continue
        if [[ ! -f "$PROXY_RELAY_FILE" ]] || ! jq -e --arg id "$id" '
            any((.exits[]?, .bindings[]?, .forwards[]?); .id == $id)
        ' "$PROXY_RELAY_FILE" >/dev/null 2>&1; then
            printf '%s' "$id"
            return 0
        fi
    done
    vps_cmd_error "无法生成唯一中转对象 ID"
    return 20
}

proxy_relay_exit() {
    local id="$1" file="${2:-$PROXY_RELAY_FILE}"
    [[ -f "$file" ]] || return 1
    jq -ce --arg id "$id" '.exits[] | select(.id == $id)' "$file" 2>/dev/null
}

proxy_relay_binding() {
    local id="$1" file="${2:-$PROXY_RELAY_FILE}"
    [[ -f "$file" ]] || return 1
    jq -ce --arg id "$id" '.bindings[] | select(.id == $id)' "$file" 2>/dev/null
}

proxy_relay_forward() {
    local id="$1" file="${2:-$PROXY_RELAY_FILE}"
    [[ -f "$file" ]] || return 1
    jq -ce --arg id "$id" '.forwards[] | select(.id == $id)' "$file" 2>/dev/null
}

proxy_relay_name_available() {
    local collection="$1" name="$2" exclude_id="${3:-}"
    [[ -f "$PROXY_RELAY_FILE" ]] || return 0
    jq -e --arg collection "$collection" --arg name "$name" --arg exclude "$exclude_id" '
        [.[$collection][]? | select(.name == $name and .id != $exclude)] | length == 0
    ' "$PROXY_RELAY_FILE" >/dev/null 2>&1 || {
        vps_cmd_error "名称已存在：$name"
        return 3
    }
}

proxy_relay_select_core() {
    local descriptor="$1" requested="${2:-}" count core
    if [[ -n "$requested" ]]; then
        proxy_core_valid "$requested" || { vps_cmd_error "无效内核：$requested"; return 2; }
        jq -e --arg core "$requested" '.compatible_cores | index($core) != null' \
            <<<"$descriptor" >/dev/null 2>&1 || {
            vps_cmd_error "该协议出口不支持所选内核：$requested"
            return 3
        }
        printf '%s' "$requested"
        return 0
    fi
    count="$(jq -r '.compatible_cores | length' <<<"$descriptor")" || return 10
    if [[ "$count" == "1" ]]; then
        jq -r '.compatible_cores[0]' <<<"$descriptor"
        return
    fi
    if proxy_is_interactive; then
        local -a choices=()
        while IFS= read -r core; do
            choices+=("$core" "$(proxy_core_label "$core")")
        done < <(jq -r '.compatible_cores[]' <<<"$descriptor")
        proxy_prompt_select "请选择协议出口使用的内核" "" "${choices[@]}"
        return
    fi
    vps_cmd_error "该协议可由多个内核使用，非交互调用必须提供 --core"
    return 2
}

proxy_relay_parse_exit_uri() {
    local uri="$1" requested_profile="${2:-}" descriptor status=0 selected
    if [[ -n "$requested_profile" ]]; then
        proxy_relay_uri_parse "$uri" "$requested_profile"
        return $?
    fi
    descriptor="$(proxy_relay_uri_parse "$uri" 2>/dev/null)" || status=$?
    if ((status == 0)); then printf '%s' "$descriptor"; return 0; fi
    if [[ "$status" == 2 ]] && proxy_is_interactive; then
        selected="$(proxy_prompt_select "请选择 URI 对应的 Profile" shadowsocks-2022 \
            shadowsocks-2022 "Shadowsocks 2022" shadowsocks-2022-padding "Shadowsocks 2022 Padding")" || return $?
        proxy_relay_uri_parse "$uri" "$selected"
        return $?
    fi
    proxy_relay_uri_parse "$uri"
}

proxy_relay_write_state_only() {
    local candidate="$1" reason="$2" backup="" failed=0
    proxy_relay_validate_file "$candidate" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "演练：写入中转状态（${reason}）"
        return 0
    fi
    if [[ -f "$PROXY_RELAY_FILE" ]]; then
        backup="$(proxy_backup_file relay "$PROXY_RELAY_LOGICAL" relay.json)" || return 20
    fi
    proxy_atomic_write_from_file "$candidate" "$PROXY_RELAY_LOGICAL" 0600 || failed=1
    if ((failed)); then
        [[ -z "$backup" ]] || proxy_restore_backup "$backup" "$PROXY_RELAY_LOGICAL" 0600 || return 30
        return 20
    fi
}

proxy_relay_commit_candidate() {
    local candidate="$1" reason="$2" core="${3:-}" sync_forward="${4:-0}"
    local candidate_config="" status=0 sync_status=0 rollback_failed=0 rollback_dir=""
    local relay_existed=0 manifest_existed=0 config_existed=0 pending_existed=0
    local config_path="" config_logical="" pending_path="" pending_logical=""
    proxy_relay_validate_file "$candidate" || return $?
    if [[ "$sync_forward" == "1" && "${VPSCTL_DRY_RUN:-0}" != "1" ]]; then
        rollback_dir="$(mktemp -d "${PROXY_STATE_DIR}/.relay-rollback.XXXXXX")" || return 20
        chmod 0700 -- "$rollback_dir" || { rm -rf -- "$rollback_dir"; return 20; }
        if [[ -f "$PROXY_RELAY_FILE" ]]; then
            cp -p -- "$PROXY_RELAY_FILE" "$rollback_dir/relay.json" || { rm -rf -- "$rollback_dir"; return 20; }
            relay_existed=1
        fi
        if [[ -n "$core" ]]; then
            config_path="$(proxy_core_config_path "$core")" || { rm -rf -- "$rollback_dir"; return 20; }
            config_logical="$(proxy_core_config_logical "$core")" || { rm -rf -- "$rollback_dir"; return 20; }
            pending_path="$(proxy_core_pending_path "$core")" || { rm -rf -- "$rollback_dir"; return 20; }
            pending_logical="$(proxy_core_pending_logical "$core")" || { rm -rf -- "$rollback_dir"; return 20; }
            if [[ -f "$PROXY_MANIFEST" ]]; then cp -p -- "$PROXY_MANIFEST" "$rollback_dir/nodes.json" || { rm -rf -- "$rollback_dir"; return 20; }; manifest_existed=1; fi
            if [[ -f "$config_path" ]]; then cp -p -- "$config_path" "$rollback_dir/config.json" || { rm -rf -- "$rollback_dir"; return 20; }; config_existed=1; fi
            if [[ -f "$pending_path" ]]; then cp -p -- "$pending_path" "$rollback_dir/pending.json" || { rm -rf -- "$rollback_dir"; return 20; }; pending_existed=1; fi
        fi
    fi
    if [[ -n "$core" ]]; then
        proxy_core_registered "$core" || {
            vps_cmd_error "建立或修改节点中转需要已安装的 $(proxy_core_label "$core")"
            return 3
        }
        candidate_config="$(proxy_mktemp_json "$PROXY_STATE_DIR" relay.config)" || return 20
        proxy_render_config "$core" "$PROXY_MANIFEST" "$candidate" >"$candidate_config" || status=$?
        if ((status == 0)); then
            proxy_commit_manifest_config "$core" "$PROXY_MANIFEST" "$candidate_config" "$reason" "$candidate" || status=$?
        fi
        rm -f -- "$candidate_config"
    else
        proxy_relay_write_state_only "$candidate" "$reason" || status=$?
    fi
    if ((status != 0)); then
        [[ -z "$rollback_dir" ]] || rm -rf -- "$rollback_dir"
        return "$status"
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then return 0; fi
    if [[ "$sync_forward" == "1" ]] && declare -F proxy_relay_forward_sync >/dev/null 2>&1; then
        proxy_relay_forward_sync || sync_status=$?
    fi
    if ((sync_status != 0)); then
        if ((relay_existed)); then
            proxy_atomic_write_from_file "$rollback_dir/relay.json" "$PROXY_RELAY_LOGICAL" 0600 || rollback_failed=1
        else
            rm -f -- "$PROXY_RELAY_FILE" || rollback_failed=1
        fi
        if [[ -n "$core" ]]; then
            if ((manifest_existed)); then proxy_atomic_write_from_file "$rollback_dir/nodes.json" "${PROXY_STATE_LOGICAL}/nodes.json" 0600 || rollback_failed=1
            else rm -f -- "$PROXY_MANIFEST" || rollback_failed=1
            fi
            if ((config_existed)); then proxy_atomic_write_from_file "$rollback_dir/config.json" "$config_logical" 0600 || rollback_failed=1
            else rm -f -- "$config_path" || rollback_failed=1
            fi
            if ((pending_existed)); then proxy_atomic_write_from_file "$rollback_dir/pending.json" "$pending_logical" 0600 || rollback_failed=1
            else rm -f -- "$pending_path" || rollback_failed=1
            fi
        fi
        if ((rollback_failed == 0)); then
            proxy_relay_forward_sync || rollback_failed=1
        fi
        rm -rf -- "$rollback_dir"
        if ((rollback_failed)); then
            vps_cmd_error "中转运行规则提交失败，且旧状态恢复不完整"
            return 30
        fi
        vps_cmd_error "中转运行规则提交失败，已恢复 relay 状态、核心配置与旧规则"
        return "$sync_status"
    fi
    [[ -z "$rollback_dir" ]] || rm -rf -- "$rollback_dir"
}

proxy_relay_exit_references() {
    local id="$1"
    jq -c --arg id "$id" '{
        bindings:[.bindings[] | select(.exit_id == $id)],
        forwards:[.forwards[] | select(.exit_id == $id)]
    }' "$PROXY_RELAY_FILE"
}

proxy_relay_print_exit_references() {
    local id="$1" bind node_id node exit forward
    while IFS= read -r bind; do
        node_id="$(jq -r '.node_id' <<<"$bind")"
        node="$(proxy_manifest_node "$node_id" 2>/dev/null || true)"
        if [[ -n "$node" ]]; then
            printf '  节点：%s（%s，%s）\n' "$(jq -r '.name' <<<"$node")" "$node_id" \
                "$(proxy_core_label "$(jq -r '.core' <<<"$node")")" >&2
        else
            printf '  节点：%s（状态缺失）\n' "$node_id" >&2
        fi
    done < <(jq -c --arg id "$id" '.bindings[] | select(.exit_id == $id)' "$PROXY_RELAY_FILE")
    while IFS= read -r forward; do
        printf '  端口转发：%s（%s，%s-%s/%s）\n' \
            "$(jq -r '.name' <<<"$forward")" "$(jq -r '.id' <<<"$forward")" \
            "$(jq -r '.listen_port_start' <<<"$forward")" "$(jq -r '.listen_port_end' <<<"$forward")" \
            "$(jq -r '.network' <<<"$forward")" >&2
    done < <(jq -c --arg id "$id" '.forwards[] | select(.exit_id == $id)' "$PROXY_RELAY_FILE")
}

proxy_relay_exit_list() {
    local json=0 arg sing_box_verified=false xray_verified=false
    while (($#)); do
        arg="$1"
        case "$arg" in --json) json=1 ;; *) vps_cmd_error "relay exit list 的未知选项：$arg"; return 2 ;; esac
        shift
    done
    proxy_require_state_access || return $?
    proxy_ensure_tools relay-exit-list jq || return $?
    [[ -f "$PROXY_RELAY_FILE" ]] || { ((json)) && printf '{"schema_version":1,"exits":[]}\n' || printf '当前没有出口。\n'; return 0; }
    proxy_relay_validate_file "$PROXY_RELAY_FILE" || return $?
    proxy_core_registered sing-box && sing_box_verified=true
    proxy_core_registered xray && xray_verified=true
    if ((json)); then
        jq --argjson sing_box_verified "$sing_box_verified" --argjson xray_verified "$xray_verified" '. as $root | {schema_version:1,exits:[.exits[] as $e | {
            id:$e.id,name:$e.name,type:$e.type,core:$e.core,profile:$e.profile,
            endpoint:$e.endpoint,network_hint:$e.network_hint,
            binary_verified:(if $e.type == "direct" then null elif $e.core == "sing-box" then $sing_box_verified else $xray_verified end),
            binding_count:([$root.bindings[] | select(.exit_id == $e.id)] | length),
            forward_count:([$root.forwards[] | select(.exit_id == $e.id)] | length)
        }]}' "$PROXY_RELAY_FILE"
        return
    fi
    local exit type core bindings forwards verified
    while IFS= read -r exit; do
        type="$(jq -r '.type' <<<"$exit")"
        core="$(jq -r '.core // ""' <<<"$exit")"
        verified=""
        if [[ "$type" == protocol ]] && ! proxy_core_registered "$core"; then verified="/尚未二进制验证"; fi
        bindings="$(jq -r --arg id "$(jq -r '.id' <<<"$exit")" '[.bindings[] | select(.exit_id == $id)] | length' "$PROXY_RELAY_FILE")"
        forwards="$(jq -r --arg id "$(jq -r '.id' <<<"$exit")" '[.forwards[] | select(.exit_id == $id)] | length' "$PROXY_RELAY_FILE")"
        printf '%s  %s  [%s%s]  %s:%s  关联=%s 转发=%s\n' \
            "$(jq -r '.id' <<<"$exit")" "$(jq -r '.name' <<<"$exit")" \
            "$([[ "$type" == protocol ]] && printf '协议' || printf '直连')" \
            "$([[ -n "$core" ]] && printf '/%s%s' "$core" "$verified")" \
            "$(jq -r '.endpoint.host' <<<"$exit")" "$(jq -r '.endpoint.port' <<<"$exit")" "$bindings" "$forwards"
    done < <(jq -c '.exits[]' "$PROXY_RELAY_FILE")
}

proxy_relay_exit_show() {
    local id="" show_uri=0 arg exit
    while (($#)); do
        arg="$1"
        case "$arg" in
            --id) (($# >= 2)) || return 2; id="$2"; shift 2; continue ;;
            --uri) show_uri=1 ;;
            *) vps_cmd_error "relay exit show 的未知选项：$arg"; return 2 ;;
        esac
        shift
    done
    [[ "$id" =~ ^exit-[a-f0-9]{16}$ ]] || { vps_cmd_error "relay exit show 需要有效 --id"; return 2; }
    proxy_require_state_access || return $?
    proxy_ensure_tools relay-exit-show jq || return $?
    exit="$(proxy_relay_exit "$id")" || { vps_cmd_error "未找到出口：$id"; return 3; }
    if ((show_uri)); then
        [[ "$(jq -r '.type' <<<"$exit")" == protocol ]] || { vps_cmd_error "直连出口没有节点 URI"; return 3; }
        jq -r '.uri' <<<"$exit"
        return
    fi
    printf '出口详情\n  名称：%s\n  ID：%s\n  类型：%s\n' \
        "$(jq -r '.name' <<<"$exit")" "$id" "$([[ "$(jq -r '.type' <<<"$exit")" == protocol ]] && printf '协议' || printf '直连')"
    if [[ "$(jq -r '.type' <<<"$exit")" == protocol ]]; then
        printf '  内核：%s\n  Profile：%s\n' "$(jq -r '.core' <<<"$exit")" "$(jq -r '.profile' <<<"$exit")"
        if proxy_core_registered "$(jq -r '.core' <<<"$exit")"; then printf '  二进制验证：可用\n'; else printf '  二进制验证：尚未验证（建立关联前需安装内核）\n'; fi
    fi
    printf '  目标：%s:%s\n  网络建议：%s\n' "$(jq -r '.endpoint.host' <<<"$exit")" \
        "$(jq -r '.endpoint.port' <<<"$exit")" "$(jq -r '.network_hint' <<<"$exit")"
    proxy_relay_print_exit_references "$id"
}

proxy_relay_candidate_file() {
    local prefix="${1:-state}" directory="$PROXY_STATE_DIR"
    [[ -d "$directory" ]] || directory="${TMPDIR:-/tmp}"
    proxy_mktemp_json "$directory" "relay.${prefix}"
}

proxy_relay_copy_current() {
    local target="$1"
    if [[ -f "$PROXY_RELAY_FILE" ]]; then
        cp -p -- "$PROXY_RELAY_FILE" "$target"
    else
        proxy_relay_default >"$target"
    fi
}

proxy_relay_exit_add() (
    local name="" uri="" profile="" requested_core="" target="" target_port="" arg
    local id descriptor="" core="" type exit_json candidate now status=0
    while (($#)); do
        arg="$1"
        case "$arg" in
            --name) (($# >= 2)) || return 2; name="$2"; shift 2; continue ;;
            --uri) (($# >= 2)) || return 2; uri="$2"; shift 2; continue ;;
            --profile) (($# >= 2)) || return 2; profile="$2"; shift 2; continue ;;
            --core) (($# >= 2)) || return 2; requested_core="$2"; shift 2; continue ;;
            --target) (($# >= 2)) || return 2; target="$2"; shift 2; continue ;;
            --target-port) (($# >= 2)) || return 2; target_port="$2"; shift 2; continue ;;
            *) vps_cmd_error "relay exit add 的未知选项：$arg"; return 2 ;;
        esac
    done
    if proxy_is_interactive; then
        local mode
        mode="$(proxy_prompt_select "出口类型" protocol protocol "协议 URI 出口" direct "直连地址出口")" || return $?
        name="$(proxy_prompt_value "出口名称" "$name")" || return $?
        if [[ "$mode" == protocol ]]; then
            uri="$(proxy_prompt_value "落地节点 URI" "$uri")" || return $?
        else
            target="$(proxy_prompt_value "落地地址（IP 或域名）" "$target")" || return $?
            target_port="$(proxy_prompt_value "落地端口" "$target_port")" || return $?
        fi
    fi
    proxy_valid_name "$name" || { vps_cmd_error "出口名称不能为空、不能换行且最多 128 个字符"; return 2; }
    [[ -z "$uri" || ( -z "$target" && -z "$target_port" ) ]] || {
        vps_cmd_error "--uri 与 --target/--target-port 互斥"
        return 2
    }
    proxy_relay_prepare_state || return $?
    proxy_stop_after_dependency_plan && return 0
    if [[ -n "$uri" ]]; then
        [[ -z "$target$target_port" ]] || return 2
        type="protocol"
        declare -F proxy_relay_uri_parse >/dev/null 2>&1 || { vps_cmd_error "URI 解析模块不可用"; return 20; }
        descriptor="$(proxy_relay_parse_exit_uri "$uri" "$profile")" || return $?
        core="$(proxy_relay_select_core "$descriptor" "$requested_core")" || return $?
        profile="$(jq -r '.profile' <<<"$descriptor")" || return 10
    else
        type="direct"
        [[ -n "$target" && -n "$target_port" ]] || {
            vps_cmd_error "直连出口需要 --target 和 --target-port"
            return 2
        }
        [[ -z "$profile$requested_core" ]] || { vps_cmd_error "直连出口不能指定 --profile/--core"; return 2; }
        proxy_valid_host "$target" || { vps_cmd_error "目标地址无效"; return 2; }
        proxy_valid_port "$target_port" || { vps_cmd_error "目标端口无效"; return 2; }
        target_port=$((10#$target_port))
        descriptor='{}'
    fi
    proxy_relay_name_available exits "$name" || return $?
    id="$(proxy_relay_generate_id exit)" || return $?
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$type" == protocol ]]; then
        exit_json="$(jq -cn --arg id "$id" --arg name "$name" --arg core "$core" \
            --arg profile "$profile" --arg uri "$uri" --arg now "$now" --argjson descriptor "$descriptor" '
            {id:$id,name:$name,type:"protocol",core:$core,profile:$profile,uri:$uri,
             descriptor:$descriptor,endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint,
             created_at:$now,updated_at:$now}')" || return 10
    else
        exit_json="$(jq -cn --arg id "$id" --arg name "$name" --arg host "$target" \
            --argjson port "$target_port" --arg now "$now" '
            {id:$id,name:$name,type:"direct",core:"",profile:"",uri:"",descriptor:{},
             endpoint:{host:$host,port:$port},network_hint:"tcp",created_at:$now,updated_at:$now}')" || return 10
    fi

    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    proxy_relay_name_available exits "$name" || return $?
    candidate="$(proxy_relay_candidate_file exit-add)" || return 20
    trap 'rm -f -- "$candidate"; vps_cmd_unlock' EXIT
    proxy_relay_copy_current "$candidate" || return 20
    jq --argjson item "$exit_json" '.exits += [$item]' "$candidate" >"${candidate}.new" || return 10
    mv -f -- "${candidate}.new" "$candidate" || return 20
    proxy_relay_commit_candidate "$candidate" relay-exit-add "" 0 || status=$?
    rm -f -- "$candidate"
    trap 'vps_cmd_unlock' EXIT
    ((status == 0)) || return "$status"
    vps_cmd_success "出口 ${name} 已创建（${id}）"
)

proxy_relay_exit_edit() (
    local id="" name="" uri="" profile="" requested_core="" target="" target_port="" arg
    local old current type descriptor="" core old_core refs binding_count forward_count candidate updated status=0 now
    local parse_profile="" explicit=0 uri_changed=0 profile_changed=0
    while (($#)); do
        arg="$1"
        case "$arg" in
            --id) (($# >= 2)) || return 2; id="$2"; shift 2; continue ;;
            --name) (($# >= 2)) || return 2; name="$2"; explicit=1; shift 2; continue ;;
            --uri) (($# >= 2)) || return 2; uri="$2"; explicit=1; uri_changed=1; shift 2; continue ;;
            --profile) (($# >= 2)) || return 2; profile="$2"; explicit=1; profile_changed=1; shift 2; continue ;;
            --core) (($# >= 2)) || return 2; requested_core="$2"; explicit=1; shift 2; continue ;;
            --target) (($# >= 2)) || return 2; target="$2"; explicit=1; shift 2; continue ;;
            --target-port) (($# >= 2)) || return 2; target_port="$2"; explicit=1; shift 2; continue ;;
            *) vps_cmd_error "relay exit edit 的未知选项：$arg"; return 2 ;;
        esac
    done
    [[ "$id" =~ ^exit-[a-f0-9]{16}$ ]] || { vps_cmd_error "relay exit edit 需要有效 --id"; return 2; }
    ((explicit)) || { vps_cmd_error "relay exit edit 至少需要一个变更字段"; return 2; }
    proxy_relay_prepare_state || return $?
    proxy_stop_after_dependency_plan && return 0
    old="$(proxy_relay_exit "$id")" || { vps_cmd_error "未找到出口：$id"; return 3; }
    type="$(jq -r '.type' <<<"$old")"
    old_core="$(jq -r '.core // ""' <<<"$old")"
    name="${name:-$(jq -r '.name' <<<"$old")}"
    proxy_valid_name "$name" || { vps_cmd_error "出口名称无效"; return 2; }
    proxy_relay_name_available exits "$name" "$id" || return $?
    refs="$(proxy_relay_exit_references "$id")" || return 10
    binding_count="$(jq -r '.bindings | length' <<<"$refs")"
    forward_count="$(jq -r '.forwards | length' <<<"$refs")"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$type" == protocol ]]; then
        [[ -z "$target$target_port" ]] || { vps_cmd_error "协议出口不能使用 --target/--target-port 编辑"; return 2; }
        uri="${uri:-$(jq -r '.uri' <<<"$old")}"
        if ((profile_changed)); then
            parse_profile="$profile"
        elif ((uri_changed == 0)); then
            parse_profile="$(jq -r '.profile' <<<"$old")"
        fi
        descriptor="$(proxy_relay_parse_exit_uri "$uri" "$parse_profile")" || return $?
        if [[ -n "$requested_core" ]]; then
            core="$(proxy_relay_select_core "$descriptor" "$requested_core")" || return $?
        elif jq -e --arg core "$old_core" '.compatible_cores | index($core) != null' <<<"$descriptor" >/dev/null 2>&1; then
            core="$old_core"
        else
            core="$(proxy_relay_select_core "$descriptor")" || return $?
        fi
        if ((binding_count > 0 || forward_count > 0)) && [[ "$core" != "$old_core" ]]; then
            vps_cmd_error "出口仍被引用，不能修改所属内核"
            proxy_relay_print_exit_references "$id"
            return 3
        fi
        profile="$(jq -r '.profile' <<<"$descriptor")"
        updated="$(jq --arg name "$name" --arg core "$core" --arg profile "$profile" --arg uri "$uri" \
            --arg now "$now" --argjson descriptor "$descriptor" '
            .name=$name | .core=$core | .profile=$profile | .uri=$uri | .descriptor=$descriptor |
            .endpoint=$descriptor.endpoint | .network_hint=$descriptor.network_hint | .updated_at=$now
        ' <<<"$old")" || return 10
    else
        [[ -z "$uri$profile$requested_core" ]] || { vps_cmd_error "直连出口不能使用 URI/profile/core 编辑"; return 2; }
        target="${target:-$(jq -r '.endpoint.host' <<<"$old")}"
        target_port="${target_port:-$(jq -r '.endpoint.port' <<<"$old")}"
        proxy_valid_host "$target" || { vps_cmd_error "目标地址无效"; return 2; }
        proxy_valid_port "$target_port" || { vps_cmd_error "目标端口无效"; return 2; }
        target_port=$((10#$target_port))
        updated="$(jq --arg name "$name" --arg host "$target" --argjson port "$target_port" --arg now "$now" '
            .name=$name | .endpoint={host:$host,port:$port} | .updated_at=$now
        ' <<<"$old")" || return 10
        core=""
    fi

    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    current="$(proxy_relay_exit "$id")" || { vps_cmd_error "出口已被删除，请重试"; return 3; }
    [[ "$current" == "$old" ]] || { vps_cmd_error "出口已发生变化，请重新读取后重试"; return 3; }
    proxy_relay_name_available exits "$name" "$id" || return $?
    candidate="$(proxy_relay_candidate_file exit-edit)" || return 20
    trap 'rm -f -- "$candidate"; vps_cmd_unlock' EXIT
    jq --arg id "$id" --argjson item "$updated" '(.exits[] | select(.id == $id))=$item' \
        "$PROXY_RELAY_FILE" >"$candidate" || return 10
    proxy_relay_commit_candidate "$candidate" relay-exit-edit \
        "$([[ "$binding_count" != 0 ]] && printf '%s' "$old_core")" \
        "$([[ "$forward_count" != 0 ]] && printf 1 || printf 0)" || status=$?
    rm -f -- "$candidate"
    trap 'vps_cmd_unlock' EXIT
    ((status == 0)) || return "$status"
    vps_cmd_success "出口 ${name} 已更新"
)

proxy_relay_exit_delete() (
    local id="" cascade=0 confirmed=0 arg exit refs binding_count forward_count core="" candidate status=0
    while (($#)); do
        arg="$1"
        case "$arg" in
            --id) (($# >= 2)) || return 2; id="$2"; shift 2; continue ;;
            --cascade) cascade=1 ;;
            --confirm-cascade) confirmed=1 ;;
            *) vps_cmd_error "relay exit delete 的未知选项：$arg"; return 2 ;;
        esac
        shift
    done
    [[ "$id" =~ ^exit-[a-f0-9]{16}$ ]] || { vps_cmd_error "relay exit delete 需要有效 --id"; return 2; }
    proxy_relay_prepare_state || return $?
    proxy_stop_after_dependency_plan && return 0
    exit="$(proxy_relay_exit "$id")" || { vps_cmd_error "未找到出口：$id"; return 3; }
    refs="$(proxy_relay_exit_references "$id")" || return 10
    binding_count="$(jq -r '.bindings | length' <<<"$refs")"
    forward_count="$(jq -r '.forwards | length' <<<"$refs")"
    if ((binding_count > 0 || forward_count > 0)); then
        if ((cascade == 0)); then
            vps_cmd_error "出口仍被引用，必须先解绑，或显式使用 --cascade"
            proxy_relay_print_exit_references "$id"
            return 3
        fi
        if [[ "${VPSCTL_DRY_RUN:-0}" != 1 && "$confirmed" != 1 ]]; then
            if proxy_is_interactive; then
                proxy_confirm "级联删除出口及 ${binding_count} 个节点关联、${forward_count} 条端口转发？" || return $?
            else
                vps_cmd_error "非交互级联删除需要 --confirm-cascade"
                return 3
            fi
        fi
    fi
    if ((binding_count > 0)); then core="$(jq -r '.core' <<<"$exit")"; fi
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    [[ "$(proxy_relay_exit "$id")" == "$exit" ]] || { vps_cmd_error "出口已发生变化，请重试"; return 3; }
    candidate="$(proxy_relay_candidate_file exit-delete)" || return 20
    trap 'rm -f -- "$candidate"; vps_cmd_unlock' EXIT
    jq --arg id "$id" '
        del(.bindings[] | select(.exit_id == $id)) |
        del(.forwards[] | select(.exit_id == $id)) |
        del(.exits[] | select(.id == $id))
    ' "$PROXY_RELAY_FILE" >"$candidate" || return 10
    proxy_relay_commit_candidate "$candidate" relay-exit-delete "$core" \
        "$([[ "$forward_count" != 0 ]] && printf 1 || printf 0)" || status=$?
    rm -f -- "$candidate"
    trap 'vps_cmd_unlock' EXIT
    ((status == 0)) || return "$status"
    vps_cmd_success "出口 $(jq -r '.name' <<<"$exit") 已删除"
)

proxy_relay_bind_list() {
    local core="all" json=0 arg
    while (($#)); do
        arg="$1"
        case "$arg" in
            --core) (($# >= 2)) || return 2; core="$2"; shift 2; continue ;;
            --json) json=1 ;;
            *) vps_cmd_error "relay bind list 的未知选项：$arg"; return 2 ;;
        esac
        shift
    done
    [[ "$core" == all ]] || proxy_core_valid "$core" || { vps_cmd_error "无效内核：$core"; return 2; }
    proxy_require_state_access || return $?
    proxy_ensure_tools relay-bind-list jq || return $?
    if [[ ! -f "$PROXY_RELAY_FILE" ]]; then
        ((json)) && printf '{"schema_version":1,"bindings":[]}\n' || printf '当前没有节点中转关联。\n'
        return 0
    fi
    proxy_relay_validate_file "$PROXY_RELAY_FILE" || return $?
    if ((json)); then
        jq --slurpfile nodes "$PROXY_MANIFEST" --arg core "$core" '. as $root | {schema_version:1,bindings:[
            .bindings[] as $b |
            ([ $nodes[0].nodes[] | select(.id == $b.node_id) ][0]) as $n |
            ([ $root.exits[] | select(.id == $b.exit_id) ][0]) as $e |
            select($core == "all" or $n.core == $core) |
            {id:$b.id,node:{id:$n.id,name:$n.name,core:$n.core,profile:$n.profile},
             exit:{id:$e.id,name:$e.name,profile:$e.profile},created_at:$b.created_at,updated_at:$b.updated_at}
        ]}' "$PROXY_RELAY_FILE"
        return
    fi
    local bind node exit
    while IFS= read -r bind; do
        node="$(proxy_manifest_node "$(jq -r '.node_id' <<<"$bind")")" || continue
        [[ "$core" == all || "$(jq -r '.core' <<<"$node")" == "$core" ]] || continue
        exit="$(proxy_relay_exit "$(jq -r '.exit_id' <<<"$bind")")" || continue
        printf '%s  节点=%s（%s/%s） -> 出口=%s（%s）\n' \
            "$(jq -r '.id' <<<"$bind")" "$(jq -r '.name' <<<"$node")" \
            "$(jq -r '.core' <<<"$node")" "$(jq -r '.id' <<<"$node")" \
            "$(jq -r '.name' <<<"$exit")" "$(jq -r '.id' <<<"$exit")"
    done < <(jq -c '.bindings[]' "$PROXY_RELAY_FILE")
}

proxy_relay_bind_show() {
    local id="" arg bind node exit
    while (($#)); do
        arg="$1"
        case "$arg" in --id) (($# >= 2)) || return 2; id="$2"; shift 2; continue ;; *) vps_cmd_error "relay bind show 的未知选项：$arg"; return 2 ;; esac
    done
    [[ "$id" =~ ^bind-[a-f0-9]{16}$ ]] || { vps_cmd_error "relay bind show 需要有效 --id"; return 2; }
    proxy_require_state_access || return $?
    proxy_ensure_tools relay-bind-show jq || return $?
    bind="$(proxy_relay_binding "$id")" || { vps_cmd_error "未找到节点中转关联：$id"; return 3; }
    node="$(proxy_manifest_node "$(jq -r '.node_id' <<<"$bind")")" || return 10
    exit="$(proxy_relay_exit "$(jq -r '.exit_id' <<<"$bind")")" || return 10
    printf '节点中转关联\n  ID：%s\n  入口节点：%s（%s，%s/%s）\n  出口：%s（%s，%s）\n' \
        "$id" "$(jq -r '.name' <<<"$node")" "$(jq -r '.id' <<<"$node")" \
        "$(jq -r '.core' <<<"$node")" "$(jq -r '.profile' <<<"$node")" \
        "$(jq -r '.name' <<<"$exit")" "$(jq -r '.id' <<<"$exit")" "$(jq -r '.profile' <<<"$exit")"
}

proxy_relay_bind_add() (
    local node_id="" exit_id="" arg node exit core id now item candidate status=0
    while (($#)); do
        arg="$1"
        case "$arg" in
            --node-id) (($# >= 2)) || return 2; node_id="$2"; shift 2; continue ;;
            --exit-id) (($# >= 2)) || return 2; exit_id="$2"; shift 2; continue ;;
            *) vps_cmd_error "relay bind add 的未知选项：$arg"; return 2 ;;
        esac
    done
    [[ "$node_id" =~ ^node-[a-f0-9]{16}$ && "$exit_id" =~ ^exit-[a-f0-9]{16}$ ]] || {
        vps_cmd_error "relay bind add 需要有效 --node-id 和 --exit-id"
        return 2
    }
    proxy_relay_prepare_state || return $?
    proxy_stop_after_dependency_plan && return 0
    node="$(proxy_manifest_node "$node_id")" || { vps_cmd_error "未找到入口节点：$node_id"; return 3; }
    exit="$(proxy_relay_exit "$exit_id")" || { vps_cmd_error "未找到出口：$exit_id"; return 3; }
    [[ "$(jq -r '.type' <<<"$exit")" == protocol ]] || { vps_cmd_error "节点中转只能使用协议出口"; return 3; }
    core="$(jq -r '.core' <<<"$node")"
    [[ "$core" == "$(jq -r '.core' <<<"$exit")" ]] || {
        vps_cmd_error "入口与出口必须使用同一内核（入口=${core}，出口=$(jq -r '.core' <<<"$exit")）"
        return 3
    }
    proxy_core_registered "$core" || { vps_cmd_error "请先安装或登记 $(proxy_core_label "$core")"; return 3; }
    if jq -e --arg id "$node_id" '.bindings[]? | select(.node_id == $id)' "$PROXY_RELAY_FILE" >/dev/null 2>&1; then
        vps_cmd_error "该入口节点已经关联出口：$node_id"
        return 3
    fi
    id="$(proxy_relay_generate_id bind)" || return $?
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    item="$(jq -cn --arg id "$id" --arg node "$node_id" --arg exit "$exit_id" --arg now "$now" \
        '{id:$id,node_id:$node,exit_id:$exit,created_at:$now,updated_at:$now}')" || return 10
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    jq -e --arg id "$node_id" '[.bindings[]? | select(.node_id == $id)] | length == 0' "$PROXY_RELAY_FILE" >/dev/null || {
        vps_cmd_error "入口节点在操作期间已被关联，请重试"
        return 3
    }
    candidate="$(proxy_relay_candidate_file bind-add)" || return 20
    trap 'rm -f -- "$candidate"; vps_cmd_unlock' EXIT
    jq --argjson item "$item" '.bindings += [$item]' "$PROXY_RELAY_FILE" >"$candidate" || return 10
    proxy_relay_commit_candidate "$candidate" relay-bind-add "$core" 0 || status=$?
    rm -f -- "$candidate"
    trap 'vps_cmd_unlock' EXIT
    ((status == 0)) || return "$status"
    vps_cmd_success "节点 $(jq -r '.name' <<<"$node") 已关联出口 $(jq -r '.name' <<<"$exit")"
)

proxy_relay_bind_delete() (
    local id="" confirmed=0 arg bind node exit core candidate status=0 confirm_status=0
    while (($#)); do
        arg="$1"
        case "$arg" in
            --id) (($# >= 2)) || return 2; id="$2"; shift 2; continue ;;
            --confirm-delete) confirmed=1 ;;
            *) vps_cmd_error "relay bind delete 的未知选项：$arg"; return 2 ;;
        esac
        shift
    done
    [[ "$id" =~ ^bind-[a-f0-9]{16}$ ]] || { vps_cmd_error "relay bind delete 需要有效 --id"; return 2; }
    proxy_relay_prepare_state || return $?
    proxy_stop_after_dependency_plan && return 0
    bind="$(proxy_relay_binding "$id")" || { vps_cmd_error "未找到节点中转关联：$id"; return 3; }
    node="$(proxy_manifest_node "$(jq -r '.node_id' <<<"$bind")")" || return 10
    exit="$(proxy_relay_exit "$(jq -r '.exit_id' <<<"$bind")")" || return 10
    core="$(jq -r '.core' <<<"$node")"
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 && "$confirmed" != 1 ]]; then
        if proxy_is_interactive; then
            proxy_confirm "取消节点 $(jq -r '.name' <<<"$node") 到出口 $(jq -r '.name' <<<"$exit") 的中转？" || confirm_status=$?
            ((confirm_status == 0)) || return "$confirm_status"
        else
            vps_cmd_error "非交互删除节点关联需要 --confirm-delete"
            return 3
        fi
    fi
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    [[ "$(proxy_relay_binding "$id")" == "$bind" ]] || { vps_cmd_error "关联已发生变化，请重试"; return 3; }
    candidate="$(proxy_relay_candidate_file bind-delete)" || return 20
    trap 'rm -f -- "$candidate"; vps_cmd_unlock' EXIT
    jq --arg id "$id" 'del(.bindings[] | select(.id == $id))' "$PROXY_RELAY_FILE" >"$candidate" || return 10
    proxy_relay_commit_candidate "$candidate" relay-bind-delete "$core" 0 || status=$?
    rm -f -- "$candidate"
    trap 'vps_cmd_unlock' EXIT
    ((status == 0)) || return "$status"
    vps_cmd_success "节点中转关联已删除：$id"
)

proxy_relay_node_binding() {
    local node_id="$1"
    [[ -f "$PROXY_RELAY_FILE" ]] || return 1
    jq -ce --arg node "$node_id" '.bindings[] | select(.node_id == $node)' "$PROXY_RELAY_FILE" 2>/dev/null
}

proxy_relay_require_node_unbound() {
    local node_id="$1" binding exit
    binding="$(proxy_relay_node_binding "$node_id" 2>/dev/null || true)"
    [[ -z "$binding" ]] && return 0
    exit="$(proxy_relay_exit "$(jq -r '.exit_id' <<<"$binding")" 2>/dev/null || true)"
    vps_cmd_error "节点仍作为中转入口，删除前必须先解绑：$node_id"
    [[ -z "$exit" ]] || printf '  出口：%s（%s）\n' "$(jq -r '.name' <<<"$exit")" "$(jq -r '.id' <<<"$exit")" >&2
    return 3
}

proxy_relay_require_core_purge_safe() {
    local core="$1" count exit id
    [[ -f "$PROXY_RELAY_FILE" ]] || return 0
    proxy_relay_validate_file "$PROXY_RELAY_FILE" || return $?
    count="$(jq -r --arg core "$core" '[.exits[] | select(.type == "protocol" and .core == $core)] | length' "$PROXY_RELAY_FILE")"
    [[ "$count" == 0 ]] && return 0
    vps_cmd_error "$(proxy_core_label "$core") 仍有关联的中转出口，拒绝彻底卸载"
    while IFS= read -r exit; do
        id="$(jq -r '.id' <<<"$exit")"
        printf '出口：%s（%s，%s）\n' "$(jq -r '.name' <<<"$exit")" "$id" "$(jq -r '.profile' <<<"$exit")" >&2
        proxy_relay_print_exit_references "$id"
    done < <(jq -c --arg core "$core" '.exits[] | select(.type == "protocol" and .core == $core)' "$PROXY_RELAY_FILE")
    return 3
}

proxy_relay_parse_port_range() {
    local value="${1:-}" start end
    if [[ "$value" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
        start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    elif [[ "$value" =~ ^[0-9]{1,5}$ ]]; then
        start="$value"; end="$value"
    else
        vps_cmd_error "入口端口必须是 PORT 或 START-END"
        return 2
    fi
    if ! proxy_valid_port "$start" || ! proxy_valid_port "$end" || ((10#$start > 10#$end)); then
        vps_cmd_error "入口端口范围无效：$value"
        return 2
    fi
    PROXY_RELAY_PORT_START=$((10#$start))
    PROXY_RELAY_PORT_END=$((10#$end))
}

proxy_relay_forward_list() {
    local json=0 arg
    while (($#)); do
        arg="$1"
        case "$arg" in --json) json=1 ;; *) vps_cmd_error "relay forward list 的未知选项：$arg"; return 2 ;; esac
        shift
    done
    proxy_require_state_access || return $?
    proxy_ensure_tools relay-forward-list jq || return $?
    if [[ ! -f "$PROXY_RELAY_FILE" ]]; then
        ((json)) && printf '{"schema_version":1,"forwards":[]}\n' || printf '当前没有端口转发。\n'
        return 0
    fi
    proxy_relay_validate_file "$PROXY_RELAY_FILE" || return $?
    if ((json)); then
        jq 'def literal_ip: test(":") or test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$");
            . as $root | {schema_version:1,forwards:[.forwards[] as $f |
            ([ $root.exits[] | select(.id == $f.exit_id) ][0]) as $e |
            ($f.publish_address | literal_ip) as $publish_literal |
            {id:$f.id,name:$f.name,kind:"port-forward",exit:{id:$e.id,name:$e.name,type:$e.type,core:$e.core,profile:$e.profile},
             listen_port_start:$f.listen_port_start,listen_port_end:$f.listen_port_end,
             network:$f.network,family:($f.family // "dual"),publish_address:$f.publish_address,target:$e.endpoint,
             publish_address_dns_managed_externally:($publish_literal | not),
             publish_address_note:(if $publish_literal then "" else "发布域名的 DNS 记录由用户负责" end),
             has_uri_template:($e.type == "protocol"),created_at:$f.created_at,updated_at:$f.updated_at}
        ]}' "$PROXY_RELAY_FILE"
        return
    fi
    local forward exit
    while IFS= read -r forward; do
        exit="$(proxy_relay_exit "$(jq -r '.exit_id' <<<"$forward")")" || continue
        printf '%s  %s  [端口转发/%s/%s]  %s:%s-%s -> %s:%s  出口=%s\n' \
            "$(jq -r '.id' <<<"$forward")" "$(jq -r '.name' <<<"$forward")" "$(jq -r '.network' <<<"$forward")" \
            "$(jq -r '.family // "dual"' <<<"$forward")" \
            "$(jq -r '.publish_address' <<<"$forward")" "$(jq -r '.listen_port_start' <<<"$forward")" \
            "$(jq -r '.listen_port_end' <<<"$forward")" "$(jq -r '.endpoint.host' <<<"$exit")" \
            "$(jq -r '.endpoint.port' <<<"$exit")" "$(jq -r '.name' <<<"$exit")"
    done < <(jq -c '.forwards[]' "$PROXY_RELAY_FILE")
}

proxy_relay_forward_show() {
    local id="" show_uris=0 json=0 arg forward exit start end port publish uri publish_literal=false
    while (($#)); do
        arg="$1"
        case "$arg" in
            --id) (($# >= 2)) || return 2; id="$2"; shift 2; continue ;;
            --uris) show_uris=1 ;;
            --json) json=1 ;;
            *) vps_cmd_error "relay forward show 的未知选项：$arg"; return 2 ;;
        esac
        shift
    done
    [[ "$id" =~ ^forward-[a-f0-9]{16}$ ]] || { vps_cmd_error "relay forward show 需要有效 --id"; return 2; }
    proxy_require_state_access || return $?
    proxy_ensure_tools relay-forward-show jq base64 || return $?
    forward="$(proxy_relay_forward "$id")" || { vps_cmd_error "未找到端口转发：$id"; return 3; }
    exit="$(proxy_relay_exit "$(jq -r '.exit_id' <<<"$forward")")" || return 10
    ((show_uris == 0 || json == 0)) || { vps_cmd_error "--uris 与 --json 不能同时使用"; return 2; }
    if ((show_uris)); then
        [[ "$(jq -r '.type' <<<"$exit")" == protocol ]] || { vps_cmd_error "直连出口没有 URI 模板"; return 3; }
        publish="$(jq -r '.publish_address' <<<"$forward")"
        start="$(jq -r '.listen_port_start' <<<"$forward")"; end="$(jq -r '.listen_port_end' <<<"$forward")"
        uri="$(jq -r '.uri' <<<"$exit")"
        for ((port = start; port <= end; port++)); do
            proxy_relay_uri_rewrite "$uri" "$publish" "$port" || return $?
            printf '\n'
        done
        return
    fi
    if ((json)); then
        if _proxy_relay_forward_address_family "$(jq -r '.publish_address' <<<"$forward")" >/dev/null 2>&1; then
            publish_literal=true
        fi
        jq -n --argjson forward "$forward" --argjson exit "$exit" --argjson publish_literal "$publish_literal" '
            {schema_version:1,forward:{
                id:$forward.id,name:$forward.name,kind:"port-forward",
                exit:{id:$exit.id,name:$exit.name,type:$exit.type,core:$exit.core,profile:$exit.profile},
                listen_port_start:$forward.listen_port_start,listen_port_end:$forward.listen_port_end,
                network:$forward.network,family:($forward.family // "dual"),
                publish_address:$forward.publish_address,target:$exit.endpoint,
                publish_address_dns_managed_externally:($publish_literal | not),
                publish_address_note:(if $publish_literal then "" else "发布域名的 DNS 记录由用户负责" end),
                has_uri_template:($exit.type == "protocol"),
                created_at:$forward.created_at,updated_at:$forward.updated_at
            }}'
        return
    fi
    printf '端口转发详情\n  名称：%s\n  ID：%s\n  类型：端口转发\n  出口：%s（%s）\n' \
        "$(jq -r '.name' <<<"$forward")" "$id" "$(jq -r '.name' <<<"$exit")" "$(jq -r '.id' <<<"$exit")"
    printf '  发布：%s:%s-%s/%s\n  地址族：%s\n  目标：%s:%s\n  URI 模板：%s\n' \
        "$(jq -r '.publish_address' <<<"$forward")" "$(jq -r '.listen_port_start' <<<"$forward")" \
        "$(jq -r '.listen_port_end' <<<"$forward")" "$(jq -r '.network' <<<"$forward")" \
        "$(jq -r '.family // "dual"' <<<"$forward")" \
        "$(jq -r '.endpoint.host' <<<"$exit")" "$(jq -r '.endpoint.port' <<<"$exit")" \
        "$([[ "$(jq -r '.type' <<<"$exit")" == protocol ]] && printf '可用（使用 --uris 展开）' || printf '无')"
    if ! _proxy_relay_forward_address_family "$(jq -r '.publish_address' <<<"$forward")" >/dev/null 2>&1; then
        printf '  发布地址提示：域名 DNS 记录由用户负责\n'
    fi
}

proxy_relay_forward_add() (
    local name="" exit_id="" ports="" network="auto" family="dual" address="" arg exit id now item candidate status=0
    while (($#)); do
        arg="$1"
        case "$arg" in
            --name) (($# >= 2)) || return 2; name="$2"; shift 2; continue ;;
            --exit-id) (($# >= 2)) || return 2; exit_id="$2"; shift 2; continue ;;
            --listen-ports) (($# >= 2)) || return 2; ports="$2"; shift 2; continue ;;
            --network) (($# >= 2)) || return 2; network="$2"; shift 2; continue ;;
            --family) (($# >= 2)) || return 2; family="$2"; shift 2; continue ;;
            --address) (($# >= 2)) || return 2; address="$2"; shift 2; continue ;;
            *) vps_cmd_error "relay forward add 的未知选项：$arg"; return 2 ;;
        esac
    done
    [[ "$exit_id" =~ ^exit-[a-f0-9]{16}$ ]] || { vps_cmd_error "relay forward add 需要有效 --exit-id"; return 2; }
    proxy_valid_name "$name" || { vps_cmd_error "端口转发名称无效"; return 2; }
    proxy_relay_parse_port_range "$ports" || return $?
    case "$network" in auto | tcp | udp | both) ;; *) vps_cmd_error "--network 仅支持 auto|tcp|udp|both"; return 2 ;; esac
    case "$family" in dual | ipv4 | ipv6) ;; *) vps_cmd_error "--family 仅支持 dual|ipv4|ipv6"; return 2 ;; esac
    proxy_relay_prepare_state || return $?
    proxy_stop_after_dependency_plan && return 0
    proxy_ensure_mutation_tools relay-forward jq openssl nft ip getent || return $?
    proxy_stop_after_dependency_plan && return 0
    exit="$(proxy_relay_exit "$exit_id")" || { vps_cmd_error "未找到出口：$exit_id"; return 3; }
    if [[ "$network" == auto ]]; then
        [[ "$(jq -r '.type' <<<"$exit")" == protocol ]] || {
            vps_cmd_error "直连出口必须显式指定 --network tcp|udp|both"
            return 2
        }
        network="$(jq -r '.network_hint' <<<"$exit")"
    fi
    address="${address:-$(proxy_default_address)}"
    _proxy_relay_forward_valid_host_value "$address" || { vps_cmd_error "无法探测或验证发布地址，请使用有效的 IP 或 DNS 主机名"; return 2; }
    proxy_relay_forward_validate_family_candidate "$family" "$(jq -r '.endpoint.host' <<<"$exit")" "$address" || return $?
    proxy_relay_name_available forwards "$name" || return $?
    id="$(proxy_relay_generate_id forward)" || return $?
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    item="$(jq -cn --arg id "$id" --arg name "$name" --arg exit "$exit_id" \
        --argjson start "$PROXY_RELAY_PORT_START" --argjson end "$PROXY_RELAY_PORT_END" \
        --arg network "$network" --arg family "$family" --arg address "$address" --arg now "$now" '
        {id:$id,name:$name,exit_id:$exit,listen_port_start:$start,listen_port_end:$end,
         network:$network,family:$family,publish_address:$address,created_at:$now,updated_at:$now}')" || return 10
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    proxy_relay_name_available forwards "$name" || return $?
    candidate="$(proxy_relay_candidate_file forward-add)" || return 20
    trap 'rm -f -- "$candidate"; vps_cmd_unlock' EXIT
    jq --argjson item "$item" '.forwards += [$item]' "$PROXY_RELAY_FILE" >"$candidate" || return 10
    proxy_relay_commit_candidate "$candidate" relay-forward-add "" 1 || status=$?
    rm -f -- "$candidate"
    trap 'vps_cmd_unlock' EXIT
    ((status == 0)) || return "$status"
    vps_cmd_success "端口转发 ${name} 已创建（${id}），nftables 已立即应用"
    [[ "$(jq -r '.type' <<<"$exit")" != protocol ]] || vps_cmd_info "使用 relay forward show --id ${id} --uris 展开新节点链接"
)

proxy_relay_forward_edit() (
    local id="" name="" exit_id="" ports="" network="" family="" address="" arg explicit=0
    local old current exit candidate updated now status=0
    while (($#)); do
        arg="$1"
        case "$arg" in
            --id) (($# >= 2)) || return 2; id="$2"; shift 2; continue ;;
            --name) (($# >= 2)) || return 2; name="$2"; explicit=1; shift 2; continue ;;
            --exit-id) (($# >= 2)) || return 2; exit_id="$2"; explicit=1; shift 2; continue ;;
            --listen-ports) (($# >= 2)) || return 2; ports="$2"; explicit=1; shift 2; continue ;;
            --network) (($# >= 2)) || return 2; network="$2"; explicit=1; shift 2; continue ;;
            --family) (($# >= 2)) || return 2; family="$2"; explicit=1; shift 2; continue ;;
            --address) (($# >= 2)) || return 2; address="$2"; explicit=1; shift 2; continue ;;
            *) vps_cmd_error "relay forward edit 的未知选项：$arg"; return 2 ;;
        esac
    done
    [[ "$id" =~ ^forward-[a-f0-9]{16}$ ]] || { vps_cmd_error "relay forward edit 需要有效 --id"; return 2; }
    ((explicit)) || { vps_cmd_error "relay forward edit 至少需要一个变更字段"; return 2; }
    proxy_relay_prepare_state || return $?
    proxy_stop_after_dependency_plan && return 0
    proxy_ensure_mutation_tools relay-forward jq openssl nft ip getent || return $?
    proxy_stop_after_dependency_plan && return 0
    old="$(proxy_relay_forward "$id")" || { vps_cmd_error "未找到端口转发：$id"; return 3; }
    name="${name:-$(jq -r '.name' <<<"$old")}"
    exit_id="${exit_id:-$(jq -r '.exit_id' <<<"$old")}"
    network="${network:-$(jq -r '.network' <<<"$old")}"
    family="${family:-$(jq -r '.family // "dual"' <<<"$old")}"
    address="${address:-$(jq -r '.publish_address' <<<"$old")}"
    if [[ -n "$ports" ]]; then proxy_relay_parse_port_range "$ports" || return $?; else
        PROXY_RELAY_PORT_START="$(jq -r '.listen_port_start' <<<"$old")"
        PROXY_RELAY_PORT_END="$(jq -r '.listen_port_end' <<<"$old")"
    fi
    if ! proxy_valid_name "$name" || ! _proxy_relay_forward_valid_host_value "$address"; then vps_cmd_error "名称或发布地址无效"; return 2; fi
    case "$network" in auto | tcp | udp | both) ;; *) vps_cmd_error "网络模式无效"; return 2 ;; esac
    case "$family" in dual | ipv4 | ipv6) ;; *) vps_cmd_error "地址族模式无效"; return 2 ;; esac
    exit="$(proxy_relay_exit "$exit_id")" || { vps_cmd_error "未找到出口：$exit_id"; return 3; }
    if [[ "$network" == auto ]]; then
        [[ "$(jq -r '.type' <<<"$exit")" == protocol ]] || { vps_cmd_error "直连出口不能使用 auto 网络"; return 2; }
        network="$(jq -r '.network_hint' <<<"$exit")"
    fi
    proxy_relay_forward_validate_family_candidate "$family" "$(jq -r '.endpoint.host' <<<"$exit")" "$address" || return $?
    proxy_relay_name_available forwards "$name" "$id" || return $?
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    updated="$(jq --arg name "$name" --arg exit "$exit_id" --argjson start "$PROXY_RELAY_PORT_START" \
        --argjson end "$PROXY_RELAY_PORT_END" --arg network "$network" --arg family "$family" --arg address "$address" --arg now "$now" '
        .name=$name | .exit_id=$exit | .listen_port_start=$start | .listen_port_end=$end |
        .network=$network | .family=$family | .publish_address=$address | .updated_at=$now
    ' <<<"$old")" || return 10
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    current="$(proxy_relay_forward "$id")" || { vps_cmd_error "端口转发已被删除，请重试"; return 3; }
    [[ "$current" == "$old" ]] || { vps_cmd_error "端口转发已发生变化，请重试"; return 3; }
    proxy_relay_name_available forwards "$name" "$id" || return $?
    candidate="$(proxy_relay_candidate_file forward-edit)" || return 20
    trap 'rm -f -- "$candidate"; vps_cmd_unlock' EXIT
    jq --arg id "$id" --argjson item "$updated" '(.forwards[] | select(.id == $id))=$item' \
        "$PROXY_RELAY_FILE" >"$candidate" || return 10
    proxy_relay_commit_candidate "$candidate" relay-forward-edit "" 1 || status=$?
    rm -f -- "$candidate"
    trap 'vps_cmd_unlock' EXIT
    ((status == 0)) || return "$status"
    vps_cmd_success "端口转发 ${name} 已更新，nftables 已立即应用"
)

proxy_relay_forward_delete() (
    local id="" confirmed=0 arg old candidate status=0 confirm_status=0
    while (($#)); do
        arg="$1"
        case "$arg" in
            --id) (($# >= 2)) || return 2; id="$2"; shift 2; continue ;;
            --confirm-delete) confirmed=1 ;;
            *) vps_cmd_error "relay forward delete 的未知选项：$arg"; return 2 ;;
        esac
        shift
    done
    [[ "$id" =~ ^forward-[a-f0-9]{16}$ ]] || { vps_cmd_error "relay forward delete 需要有效 --id"; return 2; }
    proxy_relay_prepare_state || return $?
    proxy_stop_after_dependency_plan && return 0
    proxy_ensure_mutation_tools relay-forward jq nft ip getent || return $?
    proxy_stop_after_dependency_plan && return 0
    old="$(proxy_relay_forward "$id")" || { vps_cmd_error "未找到端口转发：$id"; return 3; }
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 && "$confirmed" != 1 ]]; then
        if proxy_is_interactive; then
            proxy_confirm "删除端口转发 $(jq -r '.name' <<<"$old") 并立即撤销 nftables 规则？" || confirm_status=$?
            ((confirm_status == 0)) || return "$confirm_status"
        else
            vps_cmd_error "非交互删除端口转发需要 --confirm-delete"
            return 3
        fi
    fi
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    [[ "$(proxy_relay_forward "$id")" == "$old" ]] || { vps_cmd_error "端口转发已发生变化，请重试"; return 3; }
    candidate="$(proxy_relay_candidate_file forward-delete)" || return 20
    trap 'rm -f -- "$candidate"; vps_cmd_unlock' EXIT
    jq --arg id "$id" 'del(.forwards[] | select(.id == $id))' "$PROXY_RELAY_FILE" >"$candidate" || return 10
    proxy_relay_commit_candidate "$candidate" relay-forward-delete "" 1 || status=$?
    rm -f -- "$candidate"
    trap 'vps_cmd_unlock' EXIT
    ((status == 0)) || return "$status"
    vps_cmd_success "端口转发 $(jq -r '.name' <<<"$old") 已删除"
)

proxy_relay_forward_refresh() (
    local id="" arg count
    while (($#)); do
        arg="$1"
        case "$arg" in --id) (($# >= 2)) || return 2; id="$2"; shift 2; continue ;; *) vps_cmd_error "relay forward refresh 的未知选项：$arg"; return 2 ;; esac
    done
    [[ -z "$id" || "$id" =~ ^forward-[a-f0-9]{16}$ ]] || { vps_cmd_error "--id 无效"; return 2; }
    proxy_relay_prepare_state || return $?
    proxy_stop_after_dependency_plan && return 0
    [[ -z "$id" ]] || proxy_relay_forward "$id" >/dev/null || { vps_cmd_error "未找到端口转发：$id"; return 3; }
    count="$(jq -r '.forwards | length' "$PROXY_RELAY_FILE")" || return 10
    if ((count == 0)); then
        vps_cmd_info "当前没有端口转发，无需刷新"
        return 0
    fi
    proxy_ensure_mutation_tools relay-forward-refresh jq nft getent ip || return $?
    proxy_stop_after_dependency_plan && return 0
    declare -F proxy_relay_forward_refresh_runtime >/dev/null 2>&1 || { vps_cmd_error "端口转发刷新后端不可用"; return 20; }
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    proxy_relay_forward_refresh_runtime "$id"
)

proxy_relay_subscription_link_count() {
    local core="${1:-all}" total=0 forward exit start end
    [[ -f "$PROXY_RELAY_FILE" ]] || { printf '0'; return 0; }
    while IFS= read -r forward; do
        exit="$(proxy_relay_exit "$(jq -r '.exit_id' <<<"$forward")" 2>/dev/null || true)"
        [[ -n "$exit" && "$(jq -r '.type' <<<"$exit")" == protocol ]] || continue
        [[ "$core" == all || "$(jq -r '.core' <<<"$exit")" == "$core" ]] || continue
        start="$(jq -r '.listen_port_start' <<<"$forward")"; end="$(jq -r '.listen_port_end' <<<"$forward")"
        total=$((total + end - start + 1))
    done < <(jq -c '.forwards[]?' "$PROXY_RELAY_FILE" 2>/dev/null)
    printf '%s' "$total"
}

proxy_relay_status() {
    local json=0 arg state runtime='{"installed":false,"active":false,"enabled":false,"degraded":[]}'
    local unverified='[]' exit sing_box_pending=false xray_pending=false pending
    while (($#)); do
        arg="$1"
        case "$arg" in --json) json=1 ;; *) vps_cmd_error "relay status 的未知选项：$arg"; return 2 ;; esac
        shift
    done
    proxy_require_state_access || return $?
    proxy_ensure_tools relay-status jq || return $?
    if [[ -f "$PROXY_RELAY_FILE" ]]; then
        proxy_relay_validate_file "$PROXY_RELAY_FILE" || return $?
        state="$(<"$PROXY_RELAY_FILE")"
    else
        state="$(proxy_relay_default)"
    fi
    if declare -F proxy_relay_forward_runtime_status >/dev/null 2>&1; then
        runtime="$(proxy_relay_forward_runtime_status 2>/dev/null || printf '%s' "$runtime")"
    fi
    runtime="$(jq -c '
        . + {partial_dual:any((.degraded // [])[]?;
            ((.retained // false) == false) and ((.family // "") != ""))}
    ' <<<"$runtime")" || return 10
    while IFS= read -r exit; do
        [[ -n "$exit" ]] || continue
        if ! proxy_core_registered "$(jq -r '.core' <<<"$exit")"; then
            unverified="$(jq -cn --argjson current "$unverified" --argjson item "$exit" \
                '$current + [{id:$item.id,name:$item.name,core:$item.core,profile:$item.profile}]')" || return 10
        fi
    done < <(jq -c '.exits[] | select(.type == "protocol")' <<<"$state")
    pending="$(proxy_core_pending_path sing-box)" || return 10
    [[ ! -e "$pending" ]] || sing_box_pending=true
    pending="$(proxy_core_pending_path xray)" || return 10
    [[ ! -e "$pending" ]] || xray_pending=true
    if ((json)); then
        jq -n --argjson state "$state" --argjson runtime "$runtime" --argjson unverified "$unverified" \
            --argjson sing_box_pending "$sing_box_pending" --argjson xray_pending "$xray_pending" '{
            schema_version:1,
            exits:($state.exits|length),bindings:($state.bindings|length),forwards:($state.forwards|length),
            protocol_exits:([$state.exits[]|select(.type=="protocol")]|length),
            direct_exits:([$state.exits[]|select(.type=="direct")]|length),
            unverified_protocol_exits:$unverified,
            core_pending:{"sing-box":$sing_box_pending,xray:$xray_pending},
            data_planes:{node_relay:"restart-required",port_forward:"immediate"},
            forward_runtime:$runtime
        }'
        return
    fi
    printf '中转状态\n'
    printf '  出口：%s（协议 %s，直连 %s）\n' \
        "$(jq -r '.exits|length' <<<"$state")" \
        "$(jq -r '[.exits[]|select(.type=="protocol")]|length' <<<"$state")" \
        "$(jq -r '[.exits[]|select(.type=="direct")]|length' <<<"$state")"
    printf '  节点关联：%s\n  端口转发：%s\n' "$(jq -r '.bindings|length' <<<"$state")" "$(jq -r '.forwards|length' <<<"$state")"
    printf '  nftables 服务：%s / 开机启动：%s\n' \
        "$([[ "$(jq -r '.active // false' <<<"$runtime")" == true ]] && printf '运行中' || printf '未运行')" \
        "$([[ "$(jq -r '.enabled // false' <<<"$runtime")" == true ]] && printf '已启用' || printf '未启用')"
    if [[ "$(jq -r '(.degraded // []) | length' <<<"$runtime")" != 0 ]]; then
        if [[ "$(jq -r '.partial_dual // false' <<<"$runtime")" == true ]]; then
            printf '  双栈状态：partial（至少一条 dual 转发仅部署单一地址族）\n'
        fi
        printf '  解析/地址族状态：degraded\n'
        jq -r '.degraded[]? | "    - " + ((.host // .exit_id // "runtime") | tostring) +
            (if (.family // "") == "" then "" else "/" + .family end) + ": " + (.reason // "unknown") +
            (if (.retained // false) then "（保留最后可用地址）" else "" end)' <<<"$runtime"
    else
        printf '  解析/地址族状态：正常\n'
    fi
    if [[ "$(jq -r 'length' <<<"$unverified")" != 0 ]]; then
        printf '  尚未二进制验证的协议出口：\n'
        jq -r '.[] | "    - " + .name + "（" + .id + "，" + .core + "/" + .profile + "）"' <<<"$unverified"
    fi
    local core
    for core in sing-box xray; do
        pending="$(proxy_core_pending_path "$core")" || continue
        if [[ -e "$pending" ]]; then
            printf '  %s 配置：待显式重启应用\n' "$(proxy_core_label "$core")"
        fi
    done
}

proxy_relay_select_exit() {
    local prompt="$1" filter="${2:-all}" exit id type
    local -a choices=()
    [[ -f "$PROXY_RELAY_FILE" ]] || { vps_cmd_error "当前没有出口"; return 3; }
    while IFS= read -r exit; do
        type="$(jq -r '.type' <<<"$exit")"
        [[ "$filter" == all || "$filter" == "$type" ]] || continue
        id="$(jq -r '.id' <<<"$exit")"
        choices+=("$id" "$(jq -r '.name' <<<"$exit")（$([[ "$type" == protocol ]] && printf '协议/%s' "$(jq -r '.core' <<<"$exit")" || printf '直连')，$(jq -r '.endpoint.host' <<<"$exit"):$(jq -r '.endpoint.port' <<<"$exit")）")
    done < <(jq -c '.exits[]' "$PROXY_RELAY_FILE")
    ((${#choices[@]} > 0)) || { vps_cmd_error "没有可选出口"; return 3; }
    proxy_prompt_select "$prompt" "" "${choices[@]}"
}

proxy_relay_select_binding() {
    local prompt="$1" bind node exit id
    local -a choices=()
    while IFS= read -r bind; do
        node="$(proxy_manifest_node "$(jq -r '.node_id' <<<"$bind")" 2>/dev/null || true)"
        exit="$(proxy_relay_exit "$(jq -r '.exit_id' <<<"$bind")" 2>/dev/null || true)"
        [[ -n "$node" && -n "$exit" ]] || continue
        id="$(jq -r '.id' <<<"$bind")"
        choices+=("$id" "$(jq -r '.name' <<<"$node") -> $(jq -r '.name' <<<"$exit")")
    done < <(jq -c '.bindings[]?' "$PROXY_RELAY_FILE" 2>/dev/null)
    ((${#choices[@]} > 0)) || { vps_cmd_error "没有可选节点关联"; return 3; }
    proxy_prompt_select "$prompt" "" "${choices[@]}"
}

proxy_relay_select_forward() {
    local prompt="$1" forward id
    local -a choices=()
    while IFS= read -r forward; do
        id="$(jq -r '.id' <<<"$forward")"
        choices+=("$id" "$(jq -r '.name' <<<"$forward")（$(jq -r '.listen_port_start' <<<"$forward")-$(jq -r '.listen_port_end' <<<"$forward")/$(jq -r '.network' <<<"$forward")/$(jq -r '.family // "dual"' <<<"$forward")）")
    done < <(jq -c '.forwards[]?' "$PROXY_RELAY_FILE" 2>/dev/null)
    ((${#choices[@]} > 0)) || { vps_cmd_error "没有可选端口转发"; return 3; }
    proxy_prompt_select "$prompt" "" "${choices[@]}"
}

proxy_relay_menu_exit_show() {
    local id action
    id="$(proxy_relay_select_exit "请选择出口")" || return $?
    action="$(proxy_prompt_select "请选择查看内容" details details "出口详情（凭据脱敏）" uri "原始节点 URI")" || return $?
    if [[ "$action" == details ]]; then proxy_relay_exit_show --id "$id"; else proxy_relay_exit_show --id "$id" --uri; fi
}

proxy_relay_menu_exit_edit() {
    local id exit type field value
    id="$(proxy_relay_select_exit "请选择要编辑的出口")" || return $?
    exit="$(proxy_relay_exit "$id")" || return 3
    type="$(jq -r '.type' <<<"$exit")"
    if [[ "$type" == protocol ]]; then
        field="$(proxy_prompt_select "编辑字段" name name "名称" uri "节点 URI")" || return $?
    else
        field="$(proxy_prompt_select "编辑字段" name name "名称" target "目标地址" port "目标端口")" || return $?
    fi
    case "$field" in
        name) value="$(proxy_prompt_value "新名称" "$(jq -r '.name' <<<"$exit")")" || return $?; proxy_relay_exit_edit --id "$id" --name "$value" ;;
        uri) value="$(proxy_prompt_value "新节点 URI" "")" || return $?; proxy_relay_exit_edit --id "$id" --uri "$value" ;;
        target) value="$(proxy_prompt_value "新目标地址" "$(jq -r '.endpoint.host' <<<"$exit")")" || return $?; proxy_relay_exit_edit --id "$id" --target "$value" ;;
        port) value="$(proxy_prompt_value "新目标端口" "$(jq -r '.endpoint.port' <<<"$exit")")" || return $?; proxy_relay_exit_edit --id "$id" --target-port "$value" ;;
    esac
}

proxy_relay_menu_exit_delete() {
    local id refs cascade=0
    id="$(proxy_relay_select_exit "请选择要删除的出口")" || return $?
    refs="$(proxy_relay_exit_references "$id")" || return 10
    if [[ "$(jq -r '(.bindings|length)+(.forwards|length)' <<<"$refs")" != 0 ]]; then
        proxy_confirm "出口仍被引用，是否级联删除全部关系和转发？" || return $?
        cascade=1
    fi
    if ((cascade)); then proxy_relay_exit_delete --id "$id" --cascade --confirm-cascade; else proxy_relay_exit_delete --id "$id"; fi
}

proxy_relay_exit_menu_run() {
    local action status=0 rc
    while true; do
        action="$(proxy_prompt_select "出口管理" list add "添加出口" list "查看出口列表" show "查看出口" edit "编辑出口" delete "删除出口" back "返回中转管理")" || {
            rc=$?; [[ "$rc" == 130 ]] && return "$status"; return "$rc";
        }
        case "$action" in
            add) proxy_menu_action proxy_relay_exit_add || status=$? ;;
            list) proxy_menu_action proxy_relay_exit_list || status=$? ;;
            show) proxy_menu_action proxy_relay_menu_exit_show || status=$? ;;
            edit) proxy_menu_action proxy_relay_menu_exit_edit || status=$? ;;
            delete) proxy_menu_action proxy_relay_menu_exit_delete || status=$? ;;
            back) return "$status" ;;
        esac
    done
}

proxy_relay_menu_bind_add() {
    local node_id exit_id
    node_id="$(proxy_node_select_interactive "请选择本机入口节点")" || return $?
    exit_id="$(proxy_relay_select_exit "请选择同内核协议出口" protocol)" || return $?
    proxy_relay_bind_add --node-id "$node_id" --exit-id "$exit_id"
}

proxy_relay_bind_menu_run() {
    local action id status=0 rc
    while true; do
        action="$(proxy_prompt_select "节点中转" list add "建立关联" list "查看关联列表" show "查看关联" delete "删除关联" back "返回中转管理")" || {
            rc=$?; [[ "$rc" == 130 ]] && return "$status"; return "$rc";
        }
        case "$action" in
            add) proxy_menu_action proxy_relay_menu_bind_add || status=$? ;;
            list) proxy_menu_action proxy_relay_bind_list || status=$? ;;
            show) id="$(proxy_relay_select_binding "请选择关联")" && proxy_menu_action proxy_relay_bind_show --id "$id" || status=$? ;;
            delete) id="$(proxy_relay_select_binding "请选择要删除的关联")" && proxy_menu_action proxy_relay_bind_delete --id "$id" --confirm-delete || status=$? ;;
            back) return "$status" ;;
        esac
    done
}

proxy_relay_menu_forward_add() {
    local name exit_id ports network family address
    name="$(proxy_prompt_value "端口转发名称" "")" || return $?
    exit_id="$(proxy_relay_select_exit "请选择出口")" || return $?
    ports="$(proxy_prompt_value "本机入口端口（PORT 或 START-END）" "")" || return $?
    network="$(proxy_prompt_select "转发网络" auto auto "按协议自动推荐" tcp TCP udp UDP both "TCP + UDP")" || return $?
    family="$(proxy_prompt_select "地址族" dual dual "IPv4 + IPv6（可用族）" ipv4 "仅 IPv4" ipv6 "仅 IPv6")" || return $?
    address="$(proxy_default_address)"
    address="$(proxy_prompt_value "发布地址（写入新节点 URI）" "$address")" || return $?
    proxy_relay_forward_add --name "$name" --exit-id "$exit_id" --listen-ports "$ports" --network "$network" --family "$family" --address "$address"
}

proxy_relay_menu_forward_show() {
    local id action
    id="$(proxy_relay_select_forward "请选择端口转发")" || return $?
    action="$(proxy_prompt_select "查看内容" details details "端口转发详情" uris "展开全部新节点 URI")" || return $?
    if [[ "$action" == details ]]; then proxy_relay_forward_show --id "$id"; else proxy_relay_forward_show --id "$id" --uris; fi
}

proxy_relay_menu_forward_edit() {
    local id forward field value
    id="$(proxy_relay_select_forward "请选择要编辑的端口转发")" || return $?
    forward="$(proxy_relay_forward "$id")" || return 3
    field="$(proxy_prompt_select "编辑字段" ports name "名称" exit "出口" ports "入口端口范围" network "TCP/UDP" family "地址族" address "发布地址")" || return $?
    case "$field" in
        name) value="$(proxy_prompt_value "新名称" "$(jq -r '.name' <<<"$forward")")" || return $?; proxy_relay_forward_edit --id "$id" --name "$value" ;;
        exit) value="$(proxy_relay_select_exit "请选择新出口")" || return $?; proxy_relay_forward_edit --id "$id" --exit-id "$value" ;;
        ports) value="$(proxy_prompt_value "新入口端口范围" "$(jq -r '.listen_port_start' <<<"$forward")-$(jq -r '.listen_port_end' <<<"$forward")")" || return $?; proxy_relay_forward_edit --id "$id" --listen-ports "$value" ;;
        network) value="$(proxy_prompt_select "转发网络" "$(jq -r '.network' <<<"$forward")" tcp TCP udp UDP both "TCP + UDP")" || return $?; proxy_relay_forward_edit --id "$id" --network "$value" ;;
        family) value="$(proxy_prompt_select "地址族" "$(jq -r '.family // "dual"' <<<"$forward")" dual "IPv4 + IPv6（可用族）" ipv4 "仅 IPv4" ipv6 "仅 IPv6")" || return $?; proxy_relay_forward_edit --id "$id" --family "$value" ;;
        address) value="$(proxy_prompt_value "新发布地址" "$(jq -r '.publish_address' <<<"$forward")")" || return $?; proxy_relay_forward_edit --id "$id" --address "$value" ;;
    esac
}

proxy_relay_forward_menu_run() {
    local action id status=0 rc
    while true; do
        action="$(proxy_prompt_select "纯端口转发" list add "添加端口转发" list "查看转发列表" show "查看转发" edit "编辑转发" delete "删除转发" refresh "刷新域名与规则" back "返回中转管理")" || {
            rc=$?; [[ "$rc" == 130 ]] && return "$status"; return "$rc";
        }
        case "$action" in
            add) proxy_menu_action proxy_relay_menu_forward_add || status=$? ;;
            list) proxy_menu_action proxy_relay_forward_list || status=$? ;;
            show) proxy_menu_action proxy_relay_menu_forward_show || status=$? ;;
            edit) proxy_menu_action proxy_relay_menu_forward_edit || status=$? ;;
            delete) id="$(proxy_relay_select_forward "请选择要删除的端口转发")" && proxy_menu_action proxy_relay_forward_delete --id "$id" --confirm-delete || status=$? ;;
            refresh) proxy_menu_action proxy_relay_forward_refresh || status=$? ;;
            back) return "$status" ;;
        esac
    done
}

proxy_relay_status_menu_run() {
    local action status=0 rc
    while true; do
        action="$(proxy_prompt_select "状态与刷新" status status "查看中转状态" refresh "立即刷新 DNS 与 nftables" back "返回中转管理")" || {
            rc=$?; [[ "$rc" == 130 ]] && return "$status"; return "$rc";
        }
        case "$action" in
            status) proxy_menu_action proxy_relay_status || status=$? ;;
            refresh) proxy_menu_action proxy_relay_forward_refresh || status=$? ;;
            back) return "$status" ;;
        esac
    done
}

proxy_relay_menu_run() {
    local action status=0 rc
    while true; do
        vps_ui_page "中转管理"
        proxy_relay_status || true
        action="$(proxy_prompt_select "中转能力" "" exits "出口管理" bindings "节点中转" forwards "纯端口转发" status "状态与刷新" back "返回代理管理")" || {
            rc=$?; [[ "$rc" == 130 ]] && return "$status"; return "$rc";
        }
        case "$action" in
            exits) proxy_relay_exit_menu_run || status=$? ;;
            bindings) proxy_relay_bind_menu_run || status=$? ;;
            forwards) proxy_relay_forward_menu_run || status=$? ;;
            status) proxy_relay_status_menu_run || status=$? ;;
            back) return "$status" ;;
        esac
    done
}

proxy_relay_dispatch() {
    local group="${1:-}" action="${2:-}"
    [[ -n "$group" ]] || { vps_cmd_error "relay 需要 status|exit|bind|forward"; return 2; }
    shift
    case "$group" in
        status) proxy_relay_status "$@" ;;
        exit | bind | forward)
            (($# >= 1)) || { vps_cmd_error "relay ${group} 缺少动作"; return 2; }
            action="$1"; shift
            case "${group}:${action}" in
                exit:list) proxy_relay_exit_list "$@" ;;
                exit:show) proxy_relay_exit_show "$@" ;;
                exit:add) proxy_relay_exit_add "$@" ;;
                exit:edit) proxy_relay_exit_edit "$@" ;;
                exit:delete) proxy_relay_exit_delete "$@" ;;
                bind:list) proxy_relay_bind_list "$@" ;;
                bind:show) proxy_relay_bind_show "$@" ;;
                bind:add) proxy_relay_bind_add "$@" ;;
                bind:delete) proxy_relay_bind_delete "$@" ;;
                forward:list) proxy_relay_forward_list "$@" ;;
                forward:show) proxy_relay_forward_show "$@" ;;
                forward:add) proxy_relay_forward_add "$@" ;;
                forward:edit) proxy_relay_forward_edit "$@" ;;
                forward:delete) proxy_relay_forward_delete "$@" ;;
                forward:refresh) proxy_relay_forward_refresh "$@" ;;
                forward:clear) proxy_relay_forward_clear "$@" ;;
                *) vps_cmd_error "未知 relay 动作：${group} ${action}"; return 2 ;;
            esac
            ;;
        *) vps_cmd_error "未知 relay 分组：$group"; return 2 ;;
    esac
}
