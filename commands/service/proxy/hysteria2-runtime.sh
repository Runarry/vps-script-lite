# shellcheck shell=bash
# HY2 uses one core listener; only the extra public UDP ports are translated.

proxy_hy2_count() {
    local nodes="${1:-${PROXY_MANIFEST:-}}"
    if [[ -f "$nodes" && ! -L "$nodes" ]]; then
        jq '[.nodes[]? | select(.profile == "hysteria2" and (.options.hop_ports // "") != "")] | length' "$nodes"
    else
        printf '0\n'
    fi
}

proxy_hy2_validate_conflicts() {
    local nodes="$1" relay="${2:-${PROXY_RELAY_FILE:-}}" check_system="${3:-0}"
    local node other id other_id ports other_ports hint forward network port sockets="" old_port
    [[ -f "$nodes" && ! -L "$nodes" ]] || return 0
    [[ "$(proxy_hy2_count "$nodes")" != 0 ]] || return 0
    if [[ "$check_system" == 1 ]]; then
        proxy_ensure_tools hy2-ports ss || return $?
        sockets="$(ss -H -lntu 2>/dev/null)" || { vps_cmd_error "读取系统 UDP 监听端口失败"; return 20; }
    fi
    while IFS= read -r node; do
        id="$(jq -r '.id' <<<"$node")"
        ports="$(proxy_hy2_node_ports "$node")" || return $?
        while IFS= read -r other; do
            other_id="$(jq -r '.id' <<<"$other")"
            [[ "$id" != "$other_id" ]] || continue
            case "$(jq -r '.profile' <<<"$other")" in
                hysteria2 | tuic-v5 | shadowsocks-aes-256-gcm | shadowsocks-chacha20-poly1305 | shadowsocks-2022 | shadowsocks-2022-padding) ;;
                *) continue ;;
            esac
            other_ports="$(proxy_hy2_node_ports "$other")" || return $?
            if proxy_hy2_ports_overlap "$ports" "$other_ports"; then
                vps_cmd_error "HY2 跳跃端口 ${id} 与 UDP 节点 ${other_id} 相交"
                return 3
            fi
        done < <(jq -c '.nodes[]' "$nodes")
        if [[ -f "$relay" && ! -L "$relay" ]]; then
            while IFS= read -r forward; do
                network="$(jq -r '.network' <<<"$forward")"
                hint="$(_proxy_relay_forward_exit_hint "$relay" "$(jq -r '.exit_id' <<<"$forward")")" || return $?
                network="$(proxy_relay_forward_effective_network "$network" "$hint")" || return $?
                [[ "$network" != tcp ]] || continue
                other_ports="$(jq -r '"\(.listen_port_start)-\(.listen_port_end)"' <<<"$forward")"
                if proxy_hy2_ports_overlap "$ports" "$other_ports"; then
                    vps_cmd_error "HY2 跳跃端口 ${id} 与 UDP 转发 $(jq -r '.id' <<<"$forward") 相交"
                    return 3
                fi
            done < <(jq -c '.forwards[]?' "$relay")
        fi
        if [[ "$check_system" == 1 ]]; then
            old_port=""
            if [[ -f "${PROXY_MANIFEST:-}" ]]; then
                old_port="$(jq -r --arg id "$id" '.nodes[] | select(.id == $id) | .port' "$PROXY_MANIFEST")" || return 10
            fi
            while IFS= read -r port; do
                [[ -n "$port" && "$port" != "$old_port" ]] || continue
                if proxy_hy2_ports_contains "$ports" "$port"; then
                    vps_cmd_error "HY2 跳跃端口 ${port}/udp 已被系统中的进程监听"
                    return 3
                fi
            done < <(awk '$1 == "udp" { p=$5; sub(/^.*:/,"",p); if (p ~ /^[0-9]+$/) print p }' <<<"$sockets")
        fi
    done < <(jq -c '.nodes[] | select(.profile == "hysteria2" and (.options.hop_ports // "") != "")' "$nodes")
}

proxy_hy2_require_node_ports() {
    local node="$1" old="${2:-}" manifest="${3:-${PROXY_MANIFEST:-}}" candidate status=0 id
    if [[ "$(jq -r '.options.hop_ports // ""' <<<"$node")" == "" && "$(proxy_hy2_count "$manifest")" == 0 ]]; then return 0; fi
    id="$(jq -r '.id // "hy2-candidate"' <<<"$node")" || return 2
    [[ -n "$id" ]] || id=hy2-candidate
    [[ -z "$old" ]] || id="$(jq -r '.id' <<<"$old")" || return 2
    candidate="$(mktemp "${TMPDIR:-/tmp}/vpsctl-hy2-ports.XXXXXX")" || return 20
    if [[ -f "$manifest" ]]; then
        jq --arg id "$id" --argjson node "$node" '.nodes = ([.nodes[] | select(.id != $id)] + [$node + {id:$id}])' "$manifest" >"$candidate" || status=10
    else
        jq -n --arg id "$id" --argjson node "$node" '{nodes:[$node + {id:$id}]}' >"$candidate" || status=10
    fi
    if ((status == 0)); then proxy_hy2_validate_conflicts "$candidate" "${PROXY_RELAY_FILE:-}" 1 || status=$?; fi
    rm -f -- "$candidate"
    return "$status"
}

proxy_hy2_render_nft() {
    local nodes="${1:-${PROXY_MANIFEST:-}}" family table node id listen base ports match target item start end
    local -a pieces=() ranges=()
    for family in ip ip6; do
        table="vpsctl_proxy_hy2_$([[ "$family" == ip ]] && printf 4 || printf 6)"
        printf 'destroy table %s %s\n' "$family" "$table"
        [[ "$(proxy_hy2_count "$nodes")" != 0 ]] || continue
        printf 'add table %s %s\n' "$family" "$table"
        printf 'add chain %s %s prerouting { type nat hook prerouting priority dstnat; policy accept; }\n' "$family" "$table"
        while IFS= read -r node; do
            listen="$(jq -r '.listen // "::"' <<<"$node")"
            case "$family:$listen" in ip:*:*) [[ "$listen" == :: ]] || continue ;; ip6:*) [[ "$listen" == *:* ]] || continue ;; esac
            base="$(jq -r '.port' <<<"$node")"; id="$(jq -r '.id' <<<"$node")"
            ports="$(proxy_hy2_ports_normalize "$(jq -r '.options.hop_ports' <<<"$node")")" || return $?
            IFS=, read -r -a pieces <<<"$ports"
            ranges=()
            for item in "${pieces[@]}"; do
                start="${item%-*}"; end="${item#*-}"
                if ((base < start || base > end)); then ranges+=("$item")
                else
                    if ((start < base)); then ranges+=("${start}-$((base - 1))"); fi
                    if ((base < end)); then ranges+=("$((base + 1))-${end}"); fi
                fi
            done
            ((${#ranges[@]})) || continue
            ports="$(IFS=,; printf '%s' "${ranges[*]}")"
            match=""; target="redirect to :$base"
            if [[ "$listen" != :: && "$listen" != 0.0.0.0 ]]; then
                match="$family daddr $listen "
                if [[ "$family" == ip6 ]]; then target="dnat to [$listen]:$base"; else target="dnat to $listen:$base"; fi
            fi
            printf 'add rule %s %s prerouting fib daddr type local %sudp dport { %s } counter %s comment "vpsctl:hy2:%s"\n' "$family" "$table" "$match" "$ports" "$target" "$id"
        done < <(jq -c '.nodes[] | select(.profile == "hysteria2" and (.options.hop_ports // "") != "")' "$nodes")
    done
}

# Captured before manifests change, persisted in both transaction and pending
# records. An absent old table is a valid snapshot; enumeration failures are not.
proxy_hy2_runtime_capture() {
    local candidate="$1" old_count new_count snapshot backup="" existed=false active=false enabled=false status
    local cache_backup="" cache_existed=false
    old_count="$(proxy_hy2_count)" || return $?
    new_count="$(proxy_hy2_count "$candidate")" || return $?
    if ((old_count + new_count == 0)); then printf '{}\n'; return 0; fi
    proxy_ensure_mutation_tools hy2-runtime jq nft || return $?
    proxy_relay_forward_init || return $?
    if [[ -f "$PROXY_RELAY_FORWARD_CACHE" && ! -L "$PROXY_RELAY_FORWARD_CACHE" ]]; then
        cache_existed=true
        cache_backup="$(proxy_backup_file relay "$PROXY_RELAY_FORWARD_CACHE_LOGICAL" hy2-relay-resolved.json)" || return 20
    fi
    snapshot="$(mktemp "${PROXY_STATE_DIR}/.hy2-nft.XXXXXX")" || return 20
    if proxy_relay_forward_nft_snapshot "$snapshot"; then
        existed=true
        backup="$(proxy_backup_runtime_file relay "$snapshot" hy2-nftables.nft)" || { rm -f -- "$snapshot"; return 20; }
    else
        status=$?
        if ((status != 1)); then rm -f -- "$snapshot"; return "$status"; fi
    fi
    rm -f -- "$snapshot"
    _proxy_relay_forward_runtime_active && active=true
    _proxy_relay_forward_runtime_enabled && enabled=true
    jq -n --arg backup "$backup" --argjson existed "$existed" --argjson active "$active" --argjson enabled "$enabled" \
        --arg cache_backup "$cache_backup" --argjson cache_existed "$cache_existed" \
        '{touched:true,nft_backup:$backup,nft_existed:$existed,active:$active,enabled:$enabled,cache_backup:$cache_backup,cache_existed:$cache_existed}'
}

proxy_hy2_runtime_restore() {
    local runtime="${1:-}" active enabled
    [[ -n "$runtime" ]] || return 0
    [[ "$(jq -r '.touched // false' <<<"$runtime")" == true ]] || return 0
    proxy_relay_forward_init || return $?
    active="$(jq -r '.active' <<<"$runtime")"; enabled="$(jq -r '.enabled' <<<"$runtime")"
    if [[ -f "$PROXY_RELAY_FORWARD_SERVICE" ]]; then
        if [[ "$active" == true || "$enabled" == true ]]; then
            _proxy_relay_forward_service_action enable-now || return 30
            [[ "$active" == true ]] || _proxy_relay_forward_service_action stop || return 30
            [[ "$enabled" == true ]] || _proxy_relay_forward_service_action disable || return 30
        else
            _proxy_relay_forward_service_action disable-now || return 30
        fi
    fi
    if [[ "$(jq -r '.cache_existed // false' <<<"$runtime")" == true ]]; then
        proxy_restore_backup "$(jq -r '.cache_backup' <<<"$runtime")" "$PROXY_RELAY_FORWARD_CACHE_LOGICAL" 0600 || return 30
    else
        rm -f -- "$PROXY_RELAY_FORWARD_CACHE" || return 30
    fi
    if [[ "$(jq -r '.nft_existed' <<<"$runtime")" == true ]]; then
        proxy_relay_forward_nft_restore "$(jq -r '.nft_backup' <<<"$runtime")"
    else
        proxy_relay_forward_nft_clear
    fi
}

proxy_hy2_apply_only() {
    local batch status=0
    proxy_ensure_mutation_tools hy2-runtime jq nft || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    batch="$(mktemp "${PROXY_STATE_DIR}/.hy2-rules.XXXXXX")" || return 20
    {
        printf 'destroy table ip %s\ndestroy table ip6 %s\n' "$PROXY_RELAY_FORWARD_TABLE4" "$PROXY_RELAY_FORWARD_TABLE6"
        proxy_hy2_render_nft
    } >"$batch" || status=$?
    if ((status == 0)); then proxy_relay_forward_nft_check "$batch" && proxy_relay_forward_nft_apply "$batch" || status=$?; fi
    rm -f -- "$batch"
    return "$status"
}
