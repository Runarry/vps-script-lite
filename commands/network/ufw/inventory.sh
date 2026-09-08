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

# Mirrors proxy's documented transport map; REALITY guard loopback ports are
# deliberately absent. A wildcard IPv6 listener also accepts IPv4 on the proxy.
ufw_cli_profile_protocols() {
    case "$1" in
        hysteria2 | tuic-v5) printf 'udp\n' ;;
        shadowsocks-aes-256-gcm | shadowsocks-chacha20-poly1305 | shadowsocks-2022 | shadowsocks-2022-padding) printf 'tcp\nudp\n' ;;
        *) printf 'tcp\n' ;;
    esac
}

ufw_cli_nodes_desired() {
    local manifest="$1" node id listen port profile family destination proto
    local -a families=()
    jq -e '.nodes | type == "array"' "$manifest" >/dev/null || return 10
    while IFS= read -r node; do
        id="$(jq -r '.id' <<<"$node")"
        listen="$(jq -r '.listen' <<<"$node")"
        port="$(jq -r '.port' <<<"$node")"
        profile="$(jq -r '.profile' <<<"$node")"
        [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ && "$profile" != null ]] || return 10
        destination=any
        case "$listen" in
            127.* | ::1) continue ;;
            0.0.0.0) families=(ipv4) ;;
            :: | '')
                families=(ipv4)
                if vps_ufw_ipv6_available; then families+=(ipv6); fi
                ;;
            *:*)
                families=(ipv6)
                destination="$listen"
                ;;
            *)
                families=(ipv4)
                destination="$listen"
                ;;
        esac
        for family in "${families[@]}"; do
            while IFS= read -r proto; do
                ufw_cli_requirement "node:$id" input "$family" "$proto" "$port" "$destination" || return $?
            done < <(ufw_cli_profile_protocols "$profile")
        done
    done < <(jq -c '.nodes[]' "$manifest") | jq -s '.'
}

ufw_cli_forwards_desired() {
    local manifest="$1" cache="$2" forward exit id exit_id network wanted family destination port proto count host cached_host
    local -a protocols=()
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
        port="$(jq -r '.endpoint.port' <<<"$exit")"
        host="$(jq -r '.endpoint.host' <<<"$exit")"
        cached_host="$(jq -r --arg id "$exit_id" '.exits[$id].host // empty' "$cache")" || return 10
        [[ -n "$host" && "$host" != null && "$host" == "$cached_host" ]] || {
            vps_cmd_error "转发 $id 的解析缓存与当前出口不一致；请先刷新代理转发"
            return 3
        }
        network="$(jq -r '.network // "auto"' <<<"$forward")"
        [[ "$network" != auto ]] || network="$(jq -r '.protocol.network_hint // .network_hint // empty' <<<"$exit")"
        case "$network" in tcp | udp) protocols=("$network") ;; both) protocols=(tcp udp) ;; *) return 10 ;; esac
        wanted="$(jq -r '.family // "dual"' <<<"$forward")"
        case "$wanted" in dual | ipv4 | ipv6) ;; *) return 10 ;; esac
        count=0
        for family in ipv4 ipv6; do
            [[ "$wanted" == dual || "$wanted" == "$family" ]] || continue
            destination="$(jq -r --arg id "$exit_id" --arg family "$family" '.exits[$id][$family] // empty' "$cache")" || return 10
            [[ -n "$destination" ]] || continue
            count=$((count + 1))
            for proto in "${protocols[@]}"; do
                ufw_cli_requirement "forward:$id" route "$family" "$proto" "$port" "$destination" || return $?
            done
        done
        ((count > 0)) || {
            vps_cmd_error "转发 $id 缺少已解析目标；请先刷新代理转发"
            return 3
        }
    done < <(jq -c '.forwards[]' "$manifest") | jq -s '.'
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
    if ((status == 0)); then
        local scope begun=0
        for scope in ssh proxy-nodes proxy-forwards; do
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
    ((status != 0)) || vps_cmd_success '已同步 SSH、代理节点和代理转发需求；活动 TLS 租约保持不变'
    return "$status"
}
