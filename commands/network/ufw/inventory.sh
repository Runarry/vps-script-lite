# shellcheck shell=bash
# Read only the documented business state contracts. Never source another
# command's private modules or run another public command from global sync.

ufw_cli_inventory_file() {
    local logical="$1" destination="$2" path
    path="$(vps_cmd_system_path "$logical")" || return $?
    vps_cmd_require_no_symlink_components "$path" || return $?
    if [[ -e "$path" ]]; then
        [[ -f "$path" && -r "$path" ]] || return 3
        jq -e 'type == "object" and .schema_version == 1' "$path" >/dev/null || {
            vps_cmd_error "业务清单损坏，拒绝修改防火墙：$logical"
            return 10
        }
        cp -- "$path" "$destination" || return 20
    else
        printf '{"schema_version":1,"nodes":[],"forwards":[],"exits":[]}\n' >"$destination"
    fi
}

ufw_cli_requirement() {
    local owner="$1" kind="$2" family="$3" proto="$4" port="$5" destination="$6"
    ufw_cli_valid_port "$port" || {
        vps_cmd_error "业务清单包含无效端口：$port"
        return 10
    }
    ufw_cli_valid_address "$destination" || return 10
    jq -cn --arg owner "$owner" --arg kind "$kind" --arg family "$family" \
        --arg proto "$proto" --arg port "$port" --arg destination "$destination" \
        '{owner:$owner,kind:$kind,family:$family,proto:$proto,port:$port,source:"any",destination:$destination,temporary:false}'
}

ufw_cli_ssh_desired() {
    local sshd output='' port family='any' line keyword value local_ip server_port
    local -a ports=() families=()
    local -A seen=()
    sshd="$(command -v sshd 2>/dev/null || true)"
    if [[ -n "$sshd" ]]; then
        local config
        config="$(vps_cmd_system_path /etc/ssh/sshd_config)" || return $?
        vps_cmd_require_no_symlink_components "$config" || return $?
        if [[ -f "$config" ]]; then
            output="$(LC_ALL=C "$sshd" -T -f "$config" 2>/dev/null)" || {
                vps_cmd_error '无法读取 sshd -T 有效配置，拒绝推测 SSH 放行端口'
                return 3
            }
        elif [[ "${VPSCTL_TESTING:-0}" != 1 ]]; then
            output="$(LC_ALL=C "$sshd" -T 2>/dev/null)" || return 3
        fi
        while IFS=' ' read -r keyword value; do
            case "$keyword" in port) ports+=("$value") ;; addressfamily) family="$value" ;; esac
        done <<<"$output"
    fi
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        local -a connection=()
        IFS=' ' read -r -a connection <<<"$SSH_CONNECTION"
        ((${#connection[@]} == 4)) || {
            vps_cmd_error 'SSH_CONNECTION 格式无效'
            return 3
        }
        local_ip="${connection[2]}"
        server_port="${connection[3]}"
        ufw_cli_valid_port "$server_port" || return 3
        ports+=("$server_port")
        [[ "$local_ip" != *:* || "$family" != inet ]] || family=any
        [[ "$local_ip" == *:* || "$family" != inet6 ]] || family=any
    fi
    if [[ -n "$sshd" && ${#ports[@]} == 0 ]]; then
        vps_cmd_error 'sshd 未提供有效监听端口，拒绝继续'
        return 3
    fi
    case "$family" in
        inet) families=(ipv4) ;;
        inet6) families=(ipv6) ;;
        any)
            families=(ipv4)
            if vps_ufw_ipv6_available; then families+=(ipv6); fi
            # An existing IPv6 SSH connection must never be omitted.
            if [[ "${local_ip:-}" == *:* && " ${families[*]} " != *ipv6* ]]; then families+=(ipv6); fi
            ;;
        *)
            vps_cmd_error 'sshd AddressFamily 无效'
            return 10
            ;;
    esac
    for port in "${ports[@]}"; do
        ufw_cli_valid_port "$port" || return 10
        [[ -z "${seen[$port]+set}" ]] || continue
        seen[$port]=1
        for line in "${families[@]}"; do ufw_cli_requirement ssh input "$line" tcp "$port" any || return $?; done
    done | jq -s '.'
}

ufw_cli_validate_requirements() {
    local desired="$1" row port destination
    while IFS= read -r row; do
        port="$(jq -r '.port' <<<"$row")"
        destination="$(jq -r '.destination' <<<"$row")"
        ufw_cli_valid_port "$port" || {
            vps_cmd_error "业务清单包含无效端口：$port"
            return 10
        }
        ufw_cli_valid_address "$destination" || return 10
    done < <(jq -c '.[]' <<<"$desired")
}

ufw_cli_nodes_desired() {
    local manifest="$1" node id profile manifest_json desired ipv6=false
    jq -e '.nodes | type == "array"' "$manifest" >/dev/null || return 10
    while IFS= read -r node; do
        id="$(jq -r '.id' <<<"$node")"
        profile="$(jq -r '.profile' <<<"$node")"
        [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ && "$profile" != null ]] || return 10
    done < <(jq -c '.nodes[]' "$manifest")
    # Unlike the proxy entry, this inventory accepts an empty listener as ::,
    # but a missing listener stays invalid rather than taking that default.
    manifest_json="$(jq '.nodes |= map(.id |= tostring |
        .listen |= (if . == "" then "::" else tostring end))' "$manifest")" || return 10
    vps_ufw_ipv6_available && ipv6=true
    desired="$(vps_ufw_proxy_nodes_requirements "$manifest_json" "$ipv6")" || return 10
    ufw_cli_validate_requirements "$desired" || return $?
    printf '%s\n' "$desired"
}

ufw_cli_forwards_desired() {
    local manifest="$1" cache="$2" forward exit id exit_id wanted host cached_host
    local manifest_json cache_json desired
    jq -e '(.forwards | type == "array") and (.exits | type == "array")' "$manifest" >/dev/null || return 10
    while IFS= read -r forward; do
        id="$(jq -r '.id' <<<"$forward")"
        exit_id="$(jq -r '.exit_id' <<<"$forward")"
        [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || return 10
        exit="$(jq -c --arg id "$exit_id" '.exits[] | select(.id == $id)' "$manifest")"
        [[ -n "$exit" ]] || {
            vps_cmd_error "转发 $id 引用了不存在的出口"
            return 10
        }
        host="$(jq -r '.endpoint.host' <<<"$exit")"
        cache_json="$(<"$cache")" || return 10
        cached_host="$(jq -r --arg id "$exit_id" '.exits[$id].host // empty' <<<"$cache_json")" || return 10
        [[ -n "$host" && "$host" != null && "$host" == "$cached_host" ]] || {
            vps_cmd_error "转发 $id 的解析缓存与当前出口不一致；请先刷新代理转发"
            return 3
        }
        wanted="$(jq -r '.family // "dual"' <<<"$forward")"
        case "$wanted" in dual | ipv4 | ipv6) ;; *) return 10 ;; esac
        manifest_json="$(jq -cn --argjson forward "$forward" --argjson exit "$exit" \
            --arg id "$id" --arg family "$wanted" \
            '{exits:[$exit],forwards:[$forward | .id=$id | .family=$family | .network //= "auto"]}')" || return 10
        desired="$(vps_ufw_proxy_forwards_requirements "$manifest_json" "$cache_json")" || return 10
        jq -e 'length > 0' <<<"$desired" >/dev/null || {
            vps_cmd_error "转发 $id 缺少已解析目标；请先刷新代理转发"
            return 3
        }
        ufw_cli_validate_requirements "$desired" || return $?
        jq -c '.[]' <<<"$desired"
    done < <(jq -c '.forwards[]' "$manifest") | jq -s '.'
}

ufw_cli_tcping_desired() {
    local state ipv6=false
    state="$(vps_cmd_system_path /var/lib/vpsctl/service/tcping/state.json)" || return $?
    vps_cmd_require_no_symlink_components "$state" || return $?
    if [[ ! -e "$state" ]]; then
        printf '[]\n'
        return 0
    fi
    [[ -f "$state" && -r "$state" ]] || return 3
    jq -e '.schema_version == 1 and (.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
        (.enabled | type == "boolean")' "$state" >/dev/null || {
        vps_cmd_error 'TCPing 状态损坏，拒绝猜测放行端口'
        return 10
    }
    vps_ufw_ipv6_available && ipv6=true
    jq --argjson ipv6 "$ipv6" 'if .enabled then .port as $port |
        (["ipv4"] + if $ipv6 then ["ipv6"] else [] end) |
        map({owner:"tcping",kind:"input",family:.,proto:"tcp",port:($port|tostring),
            source:"any",destination:"any",temporary:false,preserve_existing:true}) else [] end' "$state"
}

ufw_cli_iperf3_desired() {
    local state ipv6=false
    state="$(vps_cmd_system_path /var/lib/vpsctl/service/iperf3/state.json)" || return $?
    vps_cmd_require_no_symlink_components "$state" || return $?
    if [[ ! -e "$state" ]]; then
        printf '[]\n'
        return 0
    fi
    [[ -f "$state" && -r "$state" ]] || return 3
    jq -e 'type == "object" and .schema_version == 1 and
        (.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
        (.enabled | type == "boolean")' "$state" >/dev/null || {
        vps_cmd_error 'iperf3 状态损坏，拒绝猜测放行端口'
        return 10
    }
    vps_ufw_ipv6_available && ipv6=true
    jq --argjson ipv6 "$ipv6" 'if .enabled then .port as $port |
        [( ["ipv4"] + if $ipv6 then ["ipv6"] else [] end )[] as $family |
          ("tcp", "udp") as $proto |
          {owner:"iperf3",kind:"input",family:$family,proto:$proto,port:($port|tostring),
           source:"any",destination:"any",temporary:false,preserve_existing:true}] else [] end' "$state"
}

ufw_cli_sync_locked() {
    local mode="${1:-0}" temporary='' status=0 cache
    ufw_cli_no_ssh_transaction || return $?
    # Temporary candidates are calculation inputs, never managed state. The
    # shared library owns dry-run behavior and will not persist these files.
    temporary="$(mktemp -d /tmp/vpsctl-ufw-inventory.XXXXXX)" || return 20
    ufw_cli_inventory_file /var/lib/vpsctl/service/proxy/nodes.json "$temporary/nodes.json" || status=$?
    if ((status == 0)); then ufw_cli_inventory_file /var/lib/vpsctl/service/proxy/relay.json "$temporary/relay.json" || status=$?; fi
    cache="$(vps_cmd_system_path /var/lib/vpsctl/service/proxy/relay-resolved.json)" || status=$?
    if ((status == 0)); then
        vps_cmd_require_no_symlink_components "$cache" || status=$?
        if [[ -f "$cache" ]]; then
            cp -- "$cache" "$temporary/cache.json" || status=20
            jq -e '.schema_version == 1 and (.exits | type == "object")' "$temporary/cache.json" >/dev/null || status=10
        else
            printf '{"schema_version":1,"exits":{}}\n' >"$temporary/cache.json"
        fi
    fi
    if ((status == 0)); then ufw_cli_ssh_desired >"$temporary/ssh.json" || status=$?; fi
    if ((status == 0)); then ufw_cli_nodes_desired "$temporary/nodes.json" >"$temporary/proxy-nodes.json" || status=$?; fi
    if ((status == 0)); then ufw_cli_forwards_desired "$temporary/relay.json" "$temporary/cache.json" >"$temporary/proxy-forwards.json" || status=$?; fi
    if ((status == 0)); then ufw_cli_tcping_desired >"$temporary/tcping.json" || status=$?; fi
    if ((status == 0)); then ufw_cli_iperf3_desired >"$temporary/iperf3.json" || status=$?; fi
    if ((status == 0)); then
        local scope begun=0
        for scope in ssh proxy-nodes proxy-forwards tcping iperf3; do
            vps_ufw_begin "$scope" "$temporary/$scope.json" "$mode" || {
                status=$?
                break
            }
            begun=$((begun + 1))
        done
        if ((status == 0)); then
            while ((begun > 0)); do
                vps_ufw_commit || {
                    status=$?
                    break
                }
                begun=$((begun - 1))
            done
        fi
        if ((status != 0)); then
            while ((begun > 0)); do
                vps_ufw_rollback || true
                begun=$((begun - 1))
            done
        fi
    fi
    rm -rf -- "$temporary"
    ((status != 0)) || vps_cmd_success '已同步 SSH、代理节点、代理转发、TCPing 和 iperf3 需求；活动 TLS 租约保持不变'
    return "$status"
}
