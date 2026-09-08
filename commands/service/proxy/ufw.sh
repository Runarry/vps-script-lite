# shellcheck shell=bash
# UFW declarations follow the persisted proxy configuration, including stopped
# and uninstalled cores. Callers hold the proxy lock before opening a UFW frame.

proxy_ufw_nodes_desired() {
    local manifest="$1" ipv6=false
    if [[ ! -e "$manifest" && ! -L "$manifest" ]]; then
        printf '[]\n'
        return 0
    fi
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 3
    vps_cmd_require_no_symlink_components "$manifest" || return $?
    vps_ufw_ipv6_available && ipv6=true
    jq -e --argjson ipv6 "$ipv6" '
        def protocols:
            if . == "hysteria2" or . == "tuic-v5" then ["udp"]
            elif . == "shadowsocks-aes-256-gcm" or . == "shadowsocks-chacha20-poly1305" or
                 . == "shadowsocks-2022" or . == "shadowsocks-2022-padding" then ["tcp","udp"]
            else ["tcp"] end;
        [.nodes[] as $node | ($node.listen // "::") as $listen |
            # REALITY guard listeners are deliberately absent: only .port is public.
            select(($listen | startswith("127.")) | not) | select($listen != "::1") |
            (if $listen == "::" then
                if $ipv6 then ["ipv4","ipv6"] else ["ipv4"] end
             elif $listen | contains(":") then ["ipv6"]
             else ["ipv4"] end)[] as $family |
            ($node.profile | protocols)[] as $proto |
            {owner:("node:" + $node.id),kind:"input",family:$family,proto:$proto,
             port:($node.port | tostring),source:"any",
             destination:(if $listen == "::" or $listen == "0.0.0.0" then "any" else $listen end),
             temporary:false}]
    ' "$manifest" || {
        vps_cmd_error "无法生成代理节点的 UFW 需求；请检查节点清单"
        return 3
    }
}

proxy_ufw_forwards_desired() {
    local manifest="$1" cache="${2:-}" cache_json='{"exits":{}}'
    if [[ ! -e "$manifest" && ! -L "$manifest" ]]; then
        printf '[]\n'
        return 0
    fi
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 3
    vps_cmd_require_no_symlink_components "$manifest" || return $?
    if [[ -n "$cache" && (-e "$cache" || -L "$cache") ]]; then
        [[ -f "$cache" && ! -L "$cache" ]] || return 3
        vps_cmd_require_no_symlink_components "$cache" || return $?
        cache_json="$(<"$cache")"
    fi
    jq -e --argjson cache "$cache_json" '
        . as $root |
        [.forwards[] as $forward |
            ([$root.exits[] | select(.id == $forward.exit_id)][0]) as $exit |
            ($cache.exits[$forward.exit_id] // {}) as $resolved |
            ($forward.family // "dual") as $wanted |
            if $exit == null or $resolved.host != $exit.endpoint.host then
                error("forward DNS cache belongs to a different or missing host")
            elif (if $wanted == "ipv4" then ($resolved.ipv4 // "") == ""
                  elif $wanted == "ipv6" then ($resolved.ipv6 // "") == ""
                  elif $wanted == "dual" then ($resolved.ipv4 // "") == "" and ($resolved.ipv6 // "") == ""
                  else true end) then error("forward has no cached address for its family")
            else . end |
            (if $forward.network == "auto" then ($exit.protocol.network_hint // $exit.network_hint)
             else $forward.network end) as $network |
            (if $network == "both" then ["tcp","udp"]
             elif $network == "tcp" or $network == "udp" then [$network]
             else error("invalid forward protocol") end)[] as $proto |
            (if ($forward.family // "dual") == "dual" then ["ipv4","ipv6"]
             else [$forward.family] end)[] as $family |
            ($cache.exits[$forward.exit_id][$family] // "") as $address |
            select($address != "") |
            {owner:("forward:" + $forward.id),kind:"route",family:$family,proto:$proto,
             destination:$address,port:($exit.endpoint.port | tostring),source:"any",temporary:false}]
    ' "$manifest" || return 10
}

proxy_ufw_nodes_sync() {
    [[ "${PROXY_UFW_NODES_ACTIVE:-0}" == 0 ]] || return 0
    proxy_ufw_nodes_transaction "$PROXY_MANIFEST" true
}

proxy_ufw_nodes_transaction() {
    local manifest="$1" desired actual status=0 cleanup_status=0
    shift
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 || "${PROXY_UFW_NODES_ACTIVE:-0}" == 1 ]]; then
        "$@"
        return $?
    fi
    vps_ufw_init || return $?
    desired="$(mktemp "${PROXY_STATE_DIR}/.ufw-nodes.XXXXXX")" || return 20
    proxy_ufw_nodes_desired "$manifest" >"$desired" || {
        status=$?
        rm -f -- "$desired"
        return "$status"
    }
    vps_ufw_begin proxy-nodes "$desired" || {
        status=$?
        rm -f -- "$desired"
        return "$status"
    }
    local PROXY_UFW_NODES_ACTIVE=1
    "$@" || status=$?
    if ((status != 0)); then
        # Some failures happen after configuration commit (for example saving
        # LKG). Keep the rules when the persisted declaration is still current.
        actual="$(mktemp "${PROXY_STATE_DIR}/.ufw-nodes.actual.XXXXXX")" || {
            rm -f -- "$desired"
            vps_ufw_commit || true
            return 30
        }
        if proxy_ufw_nodes_desired "$PROXY_MANIFEST" >"$actual" && cmp -s -- "$desired" "$actual"; then
            vps_ufw_commit || cleanup_status=$?
        else
            vps_ufw_rollback || cleanup_status=$?
            if ((cleanup_status == 0)); then
                # A pending restart may restore a state older than this frame.
                PROXY_UFW_NODES_ACTIVE=0
                proxy_ufw_nodes_sync || cleanup_status=$?
                if ((cleanup_status == 0)) && [[ -n "${PROXY_RELAY_FILE:-}" && -f "$PROXY_RELAY_FILE" ]]; then
                    proxy_ufw_forwards_sync_cached || cleanup_status=$?
                fi
            fi
        fi
        rm -f -- "$actual"
    else
        vps_ufw_commit || cleanup_status=$?
    fi
    rm -f -- "$desired"
    if ((cleanup_status != 0)); then
        vps_cmd_error "代理配置与 UFW 同步未完整完成；新配置已提交时保留其放行需求，请重试防火墙同步"
        return 30
    fi
    return "$status"
}

proxy_ufw_forwards_begin() {
    local manifest="$1" cache="${2:-}" desired status=0
    vps_ufw_init || return $?
    desired="$(mktemp "${PROXY_STATE_DIR}/.ufw-forwards.XXXXXX")" || return 20
    proxy_ufw_forwards_desired "$manifest" "$cache" >"$desired" || status=$?
    if ((status == 0)); then vps_ufw_begin proxy-forwards "$desired" || status=$?; fi
    rm -f -- "$desired"
    return "$status"
}

proxy_ufw_forwards_sync_cached() {
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    proxy_relay_forward_init || return $?
    proxy_ufw_forwards_begin "$PROXY_RELAY_FORWARD_MANIFEST" "$PROXY_RELAY_FORWARD_CACHE" || return $?
    vps_ufw_commit
}

# Hold an outer frame through relay state, core restart, nft/cache and service
# setup. Nested apply calls replace this initially empty scope without deleting
# old rules until the entire business transaction has succeeded.
proxy_ufw_relay_transaction() {
    local desired status=0 cleanup_status=0
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        "$@"
        return $?
    fi
    vps_ufw_init || return $?
    desired="$(mktemp "${PROXY_STATE_DIR}/.ufw-relay.XXXXXX")" || return 20
    printf '[]\n' >"$desired" || {
        rm -f -- "$desired"
        return 20
    }
    vps_ufw_begin proxy-forwards "$desired" || {
        status=$?
        rm -f -- "$desired"
        return "$status"
    }
    rm -f -- "$desired"
    "$@" || status=$?
    if ((status == 0)); then
        vps_ufw_commit || cleanup_status=$?
    else
        vps_ufw_rollback || cleanup_status=$?
        if ((cleanup_status == 0)); then
            # The existing business recovery may re-resolve the old hostname.
            # Match its recovered cache rather than the failed candidate.
            proxy_ufw_forwards_sync_cached || cleanup_status=$?
        fi
    fi
    if ((cleanup_status != 0)); then
        vps_cmd_error "中转与 UFW 同步未完整完成；已提交的目标放行保留，请重试防火墙同步"
        return 30
    fi
    return "$status"
}

proxy_ufw_restore_pending() {
    local core="$1" pending manifest relay cache runtime=false status=0 cleanup_status=0
    pending="$(proxy_core_pending_path "$core")" || return $?
    [[ -f "$pending" && ! -L "$pending" ]] || return 1
    manifest="$(jq -r '.manifest_backup // ""' "$pending")" || return 30
    manifest="${manifest:-$PROXY_MANIFEST}"
    runtime="$(jq -r '.relay_runtime_touched // false' "$pending")" || return 30
    if [[ "$runtime" != true || "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        proxy_ufw_nodes_transaction "$manifest" _proxy_restore_pending "$core"
        return $?
    fi
    relay="$(jq -r '.relay_backup // ""' "$pending")" || return 30
    cache="$(jq -r '.relay_cache_backup // ""' "$pending")" || return 30
    proxy_ufw_forwards_begin "${relay:-$PROXY_RELAY_FILE}" "$cache" || return $?
    proxy_ufw_nodes_transaction "$manifest" _proxy_restore_pending "$core" || status=$?
    if ((status == 0)); then
        vps_ufw_commit || cleanup_status=$?
    else
        vps_ufw_rollback || cleanup_status=$?
        if ((cleanup_status == 0)); then proxy_ufw_forwards_sync_cached || cleanup_status=$?; fi
    fi
    ((cleanup_status == 0)) || return 30
    return "$status"
}
