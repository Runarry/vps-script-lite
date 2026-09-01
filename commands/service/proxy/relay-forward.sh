# shellcheck shell=bash
# Private relay-forwarding helpers for commands/service/proxy.sh.  Sourcing this
# file only defines functions; call proxy_relay_forward_init before using paths.
#
# Public API:
#   proxy_relay_forward_init
#   proxy_relay_forward_parse_range RANGE
#   proxy_relay_forward_validate_network NETWORK
#   proxy_relay_forward_effective_network NETWORK NETWORK_HINT
#   proxy_relay_forward_manifest_default
#   proxy_relay_forward_manifest_validate FILE [NODES_FILE]
#   proxy_relay_forward_validate_manifest FILE [NODES_FILE] (integration alias)
#   proxy_relay_forward_validate_conflicts FILE [NODES_FILE]
#   proxy_relay_forward_validate_family_candidate FAMILY HOST PUBLISH_ADDRESS
#   proxy_relay_forward_refresh_cache MANIFEST OLD_CACHE OUTPUT
#   proxy_relay_forward_detect_loops MANIFEST CACHE
#   proxy_relay_forward_render_nft MANIFEST CACHE
#   proxy_relay_forward_nft_check BATCH
#   proxy_relay_forward_nft_apply BATCH
#   proxy_relay_forward_nft_snapshot OUTPUT
#   proxy_relay_forward_nft_clear
#   proxy_relay_forward_nft_restore SNAPSHOT
#   proxy_relay_forward_apply
#   proxy_relay_forward_sync
#   proxy_relay_forward_refresh_runtime [FORWARD_ID]
#   proxy_relay_forward_runtime_status
#   proxy_relay_forward_clear
#   proxy_relay_forward_emit_helper
#   proxy_relay_forward_emit_service
#   proxy_relay_forward_emit_sysctl
#   proxy_relay_forward_install_service
#   proxy_relay_forward_remove_service
#   proxy_relay_forward_on_count_change OLD_COUNT NEW_COUNT
#
# Globals initialized by proxy_relay_forward_init (callers may override the
# *_LOGICAL values before initialization):
#   PROXY_RELAY_FORWARD_MANIFEST[_LOGICAL]
#   PROXY_RELAY_FORWARD_CACHE[_LOGICAL]
#   PROXY_RELAY_FORWARD_HELPER[_LOGICAL]
#   PROXY_RELAY_FORWARD_SERVICE[_LOGICAL]
#   PROXY_RELAY_FORWARD_SYSCTL[_LOGICAL]
#   PROXY_RELAY_FORWARD_RUNTIME[_LOGICAL]
#   PROXY_RELAY_FORWARD_TABLE4 / PROXY_RELAY_FORWARD_TABLE6
#   PROXY_RELAY_FORWARD_VPSCTL_LOGICAL
# Optional test seam: PROXY_RELAY_FORWARD_ALLOW_TEST_RUNTIME=1 permits calls to
# mocked nft/sysctl/init commands while VPSCTL_TESTING=1.  Without it, runtime
# mutations are refused so VPSCTL_SYSTEM_ROOT cannot leak into the host kernel.

proxy_relay_forward_init() {
    [[ -n "${PROXY_STATE_DIR:-}" && -n "${PROXY_STATE_LOGICAL:-}" ]] || {
        vps_cmd_error "relay forward 初始化前必须先调用 proxy_common_init"
        return 2
    }

    PROXY_RELAY_FORWARD_MANIFEST_LOGICAL="${PROXY_RELAY_FORWARD_MANIFEST_LOGICAL:-${PROXY_RELAY_LOGICAL:-${PROXY_STATE_LOGICAL}/relay.json}}"
    PROXY_RELAY_FORWARD_CACHE_LOGICAL="${PROXY_RELAY_FORWARD_CACHE_LOGICAL:-${PROXY_RELAY_CACHE_LOGICAL:-${PROXY_STATE_LOGICAL}/relay-resolved.json}}"
    PROXY_RELAY_FORWARD_HELPER_LOGICAL="${PROXY_RELAY_FORWARD_HELPER_LOGICAL:-/usr/local/libexec/vpsctl-proxy-forward-refresh}"
    PROXY_RELAY_FORWARD_SYSCTL_LOGICAL="${PROXY_RELAY_FORWARD_SYSCTL_LOGICAL:-/etc/sysctl.d/90-vpsctl-proxy-forward.conf}"
    PROXY_RELAY_FORWARD_RUNTIME_LOGICAL="${PROXY_RELAY_FORWARD_RUNTIME_LOGICAL:-/usr/local/libexec/vpsctl-proxy-runtime}"
    PROXY_RELAY_FORWARD_TABLE4="${PROXY_RELAY_FORWARD_TABLE4:-vpsctl_proxy_forward4}"
    PROXY_RELAY_FORWARD_TABLE6="${PROXY_RELAY_FORWARD_TABLE6:-vpsctl_proxy_forward6}"

    case "${PROXY_INIT_SYSTEM:-unknown}" in
        systemd)
            PROXY_RELAY_FORWARD_SERVICE_LOGICAL="${PROXY_RELAY_FORWARD_SERVICE_LOGICAL:-/etc/systemd/system/vpsctl-proxy-forward.service}"
            ;;
        openrc)
            PROXY_RELAY_FORWARD_SERVICE_LOGICAL="${PROXY_RELAY_FORWARD_SERVICE_LOGICAL:-/etc/init.d/vpsctl-proxy-forward}"
            ;;
        *)
            vps_cmd_error "relay forward 仅支持 systemd 或 OpenRC"
            return 3
            ;;
    esac

    PROXY_RELAY_FORWARD_MANIFEST="$(vps_cmd_system_path "$PROXY_RELAY_FORWARD_MANIFEST_LOGICAL")" || return $?
    PROXY_RELAY_FORWARD_CACHE="$(vps_cmd_system_path "$PROXY_RELAY_FORWARD_CACHE_LOGICAL")" || return $?
    PROXY_RELAY_FORWARD_HELPER="$(vps_cmd_system_path "$PROXY_RELAY_FORWARD_HELPER_LOGICAL")" || return $?
    PROXY_RELAY_FORWARD_SERVICE="$(vps_cmd_system_path "$PROXY_RELAY_FORWARD_SERVICE_LOGICAL")" || return $?
    PROXY_RELAY_FORWARD_SYSCTL="$(vps_cmd_system_path "$PROXY_RELAY_FORWARD_SYSCTL_LOGICAL")" || return $?
    PROXY_RELAY_FORWARD_RUNTIME="$(vps_cmd_system_path "$PROXY_RELAY_FORWARD_RUNTIME_LOGICAL")" || return $?
    [[ -z "${PROXY_RELAY_FILE:-}" ]] || PROXY_RELAY_FORWARD_MANIFEST="$PROXY_RELAY_FILE"
    [[ -z "${PROXY_RELAY_CACHE_FILE:-}" ]] || PROXY_RELAY_FORWARD_CACHE="$PROXY_RELAY_CACHE_FILE"
}

proxy_relay_forward_parse_range() {
    local value="${1:-}" start end
    [[ "$value" =~ ^([0-9]{1,5})(-([0-9]{1,5}))?$ ]] || {
        vps_cmd_error "端口范围必须为 START 或 START-END：${value:-<空>}"
        return 2
    }
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
    ((10#$start >= 1 && 10#$start <= 65535 && 10#$end >= 1 && 10#$end <= 65535 && 10#$start <= 10#$end)) || {
        vps_cmd_error "端口范围无效：$value"
        return 2
    }
    printf '%d %d\n' "$((10#$start))" "$((10#$end))"
}

proxy_relay_forward_validate_network() {
    case "${1:-}" in
        auto | tcp | udp | both) return 0 ;;
        *)
            vps_cmd_error "network 必须是 auto、tcp、udp 或 both：${1:-<空>}"
            return 2
            ;;
    esac
}

proxy_relay_forward_effective_network() {
    local network="${1:-}" hint="${2:-}"
    proxy_relay_forward_validate_network "$network" || return $?
    if [[ "$network" != auto ]]; then
        printf '%s\n' "$network"
        return 0
    fi
    case "$hint" in
        tcp | udp | both) printf '%s\n' "$hint" ;;
        *)
            vps_cmd_error "network=auto 时出口 protocol.network_hint 必须是 tcp、udp 或 both"
            return 2
            ;;
    esac
}

_proxy_relay_forward_network_mask() {
    case "${1:-}" in
        tcp) printf '1' ;;
        udp) printf '2' ;;
        both) printf '3' ;;
        *) return 2 ;;
    esac
}

_proxy_relay_forward_node_network_hint() {
    case "${1:-}" in
        hysteria2 | tuic-v5) printf 'udp' ;;
        shadowsocks-aes-256-gcm | shadowsocks-chacha20-poly1305 | \
            shadowsocks-2022 | shadowsocks-2022-padding) printf 'both' ;;
        *) printf 'tcp' ;;
    esac
}

_proxy_relay_forward_exit_hint() {
    local manifest="${1:-}" exit_id="${2:-}"
    jq -r --arg id "$exit_id" '.exits[] | select(.id == $id) | (.protocol.network_hint // .network_hint // empty)' "$manifest"
}

proxy_relay_forward_manifest_default() {
    printf '{"schema_version":1,"exits":[],"bindings":[],"forwards":[]}\n'
}

_proxy_relay_forward_valid_ipv4() {
    local value="${1:-}" part
    local -a parts=()
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<<"$value"
    ((${#parts[@]} == 4)) || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] && ((10#$part <= 255)) || return 1
    done
}

_proxy_relay_forward_valid_ipv6() {
    local value="${1:-}" normalized left right side part ipv4_tail="" compressed=0 count=0
    local -a parts=()

    [[ "$value" == *:* && "$value" != *%* ]] || return 1
    normalized="$value"
    if [[ "$normalized" == *.* ]]; then
        ipv4_tail="${normalized##*:}"
        _proxy_relay_forward_valid_ipv4 "$ipv4_tail" || return 1
        normalized="${normalized%:*}:0:0"
    fi
    [[ "$normalized" =~ ^[0-9A-Fa-f:]+$ && "$normalized" != *:::* ]] || return 1
    if [[ "$normalized" == *::* ]]; then
        compressed=1
        left="${normalized%%::*}"
        right="${normalized#*::}"
        [[ "$right" != *::* ]] || return 1
    else
        left="$normalized"
        right=""
        [[ "$left" != :* && "$left" != *: ]] || return 1
    fi
    for side in "$left" "$right"; do
        [[ -n "$side" ]] || continue
        [[ "$side" != :* && "$side" != *: ]] || return 1
        IFS=: read -r -a parts <<<"$side"
        for part in "${parts[@]}"; do
            [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            count=$((count + 1))
        done
    done
    if ((compressed)); then
        ((count < 8))
    else
        ((count == 8))
    fi
}

_proxy_relay_forward_valid_hostname() {
    local value="${1:-}" label
    local -a labels=()

    [[ -n "$value" && ${#value} -le 253 && "$value" != *:* ]] || return 1
    value="${value%.}"
    [[ -n "$value" && "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    IFS=. read -r -a labels <<<"$value"
    for label in "${labels[@]}"; do
        ((${#label} >= 1 && ${#label} <= 63)) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
}

_proxy_relay_forward_valid_host_value() {
    local value="${1:-}"
    if [[ "$value" == *:* ]]; then
        _proxy_relay_forward_valid_ipv6 "$value"
    elif [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _proxy_relay_forward_valid_ipv4 "$value"
    else
        _proxy_relay_forward_valid_hostname "$value"
    fi
}

_proxy_relay_forward_address_family() {
    if _proxy_relay_forward_valid_ipv4 "${1:-}"; then
        printf 'ipv4'
    elif _proxy_relay_forward_valid_ipv6 "${1:-}"; then
        printf 'ipv6'
    else
        return 1
    fi
}

proxy_relay_forward_validate_conflicts() {
    local manifest="${1:-}" nodes="${2:-${PROXY_MANIFEST:-}}"
    local count index other start end other_start other_end network hint effective mask other_network other_hint other_effective other_mask
    local id other_id node port node_hint node_mask

    [[ -f "$manifest" && ! -L "$manifest" ]] || return 3
    count="$(jq -r '.forwards | length' "$manifest")" || return 10
    for ((index = 0; index < count; index++)); do
        id="$(jq -r ".forwards[$index].id" "$manifest")"
        start="$(jq -r ".forwards[$index].listen_port_start" "$manifest")"
        end="$(jq -r ".forwards[$index].listen_port_end" "$manifest")"
        network="$(jq -r ".forwards[$index].network" "$manifest")"
        hint="$(_proxy_relay_forward_exit_hint "$manifest" "$(jq -r ".forwards[$index].exit_id" "$manifest")")"
        effective="$(proxy_relay_forward_effective_network "$network" "$hint")" || return $?
        mask="$(_proxy_relay_forward_network_mask "$effective")" || return 10

        for ((other = index + 1; other < count; other++)); do
            other_id="$(jq -r ".forwards[$other].id" "$manifest")"
            other_start="$(jq -r ".forwards[$other].listen_port_start" "$manifest")"
            other_end="$(jq -r ".forwards[$other].listen_port_end" "$manifest")"
            other_network="$(jq -r ".forwards[$other].network" "$manifest")"
            other_hint="$(_proxy_relay_forward_exit_hint "$manifest" "$(jq -r ".forwards[$other].exit_id" "$manifest")")"
            other_effective="$(proxy_relay_forward_effective_network "$other_network" "$other_hint")" || return $?
            other_mask="$(_proxy_relay_forward_network_mask "$other_effective")" || return 10
            if ((start <= other_end && other_start <= end && (mask & other_mask) != 0)); then
                vps_cmd_error "转发 ${id} 与 ${other_id} 的端口区间及网络相交"
                return 10
            fi
        done

        if [[ -n "$nodes" && -f "$nodes" && ! -L "$nodes" ]]; then
            while IFS= read -r node; do
                [[ -n "$node" ]] || continue
                port="$(jq -r '.port' <<<"$node")"
                node_hint="$(_proxy_relay_forward_node_network_hint "$(jq -r '.profile' <<<"$node")")"
                node_mask="$(_proxy_relay_forward_network_mask "$node_hint")" || return 10
                if ((port >= start && port <= end && (mask & node_mask) != 0)); then
                    vps_cmd_error "转发 ${id} 与受管节点 $(jq -r '.id' <<<"$node") 的端口及网络相交（${port}/${node_hint}）"
                    return 10
                fi
            done < <(jq -c '.nodes[]?' "$nodes")
        fi
    done
}

proxy_relay_forward_manifest_validate() {
    local file="${1:-}" nodes="${2:-${PROXY_MANIFEST:-}}"
    command -v jq >/dev/null 2>&1 || {
        vps_cmd_error "relay forward 需要 jq"
        return 3
    }
    [[ -f "$file" && ! -L "$file" ]] || {
        vps_cmd_error "relay 清单不存在或不是普通文件：${file:-<空>}"
        return 3
    }
    jq -e '
        . as $root |
        type == "object" and
        .schema_version == 1 and
        ((.exits | type) == "array") and
        ((.bindings | type) == "array") and
        ((.forwards | type) == "array") and
        (([.exits[].id] | length) == ([.exits[].id] | unique | length)) and
        (([.forwards[].id] | length) == ([.forwards[].id] | unique | length)) and
        (([.forwards[].name] | length) == ([.forwards[].name] | unique | length)) and
        all(.exits[];
            ((.id | type) == "string" and (.id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))) and
            ((.type | type) == "string" and (.type | length) > 0 and (.type | length) <= 64) and
            ((.endpoint | type) == "object") and
            ((.endpoint.host | type) == "string" and (.endpoint.host | length) > 0 and (.endpoint.host | length) <= 253 and (.endpoint.host | test("[[:space:]/]")) == false) and
            ((.endpoint.port | type) == "number" and (.endpoint.port | floor) == .endpoint.port and .endpoint.port >= 1 and .endpoint.port <= 65535) and
            (((.protocol.network_hint // .network_hint) == "tcp") or
             ((.protocol.network_hint // .network_hint) == "udp") or
             ((.protocol.network_hint // .network_hint) == "both"))
        ) and
        all(.bindings[];
            . as $binding |
            (type == "object") and
            ((has("id") | not) or ((.id | type) == "string" and (.id | length) > 0 and (.id | length) <= 128)) and
            ((has("exit_id") | not) or ((.exit_id | type) == "string" and ([ $root.exits[].id ] | index($binding.exit_id)) != null))
        ) and
        all(.forwards[];
            ((.id | type) == "string" and (.id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))) and
            ((.name | type) == "string" and (.name | length) > 0 and (.name | length) <= 128 and (.name | test("[\\r\\n]")) == false) and
            ((.exit_id | type) == "string") and
            (.exit_id as $id | ([ $root.exits[].id ] | index($id)) != null) and
            ((.listen_port_start | type) == "number" and (.listen_port_start | floor) == .listen_port_start and .listen_port_start >= 1 and .listen_port_start <= 65535) and
            ((.listen_port_end | type) == "number" and (.listen_port_end | floor) == .listen_port_end and .listen_port_end >= .listen_port_start and .listen_port_end <= 65535) and
            (.network == "auto" or .network == "tcp" or .network == "udp" or .network == "both") and
            ((has("family") | not) or .family == "dual" or .family == "ipv4" or .family == "ipv6") and
            ((.publish_address | type) == "string" and (.publish_address | length) > 0 and (.publish_address | length) <= 253 and (.publish_address | test("[[:space:]/]")) == false)
        )
    ' "$file" >/dev/null 2>&1 || {
        vps_cmd_error "relay 清单格式、引用或唯一性校验失败：$file"
        return 10
    }

    local forward forward_id exit_id family host publish host_family publish_family
    while IFS= read -r forward; do
        [[ -n "$forward" ]] || continue
        forward_id="$(jq -r '.id' <<<"$forward")"
        exit_id="$(jq -r '.exit_id' <<<"$forward")"
        family="$(jq -r '.family // "dual"' <<<"$forward")"
        host="$(jq -r --arg id "$exit_id" '.exits[] | select(.id == $id) | .endpoint.host' "$file")"
        publish="$(jq -r '.publish_address' <<<"$forward")"
        _proxy_relay_forward_valid_host_value "$host" || {
            vps_cmd_error "转发 ${forward_id} 的出口主机无效：${host}"
            return 10
        }
        _proxy_relay_forward_valid_host_value "$publish" || {
            vps_cmd_error "转发 ${forward_id} 的发布地址无效：${publish}"
            return 10
        }
        host_family="$(_proxy_relay_forward_address_family "$host" 2>/dev/null || true)"
        publish_family="$(_proxy_relay_forward_address_family "$publish" 2>/dev/null || true)"
        if [[ "$family" != dual ]]; then
            if [[ -n "$host_family" && "$host_family" != "$family" ]]; then
                vps_cmd_error "转发 ${forward_id} 的 ${family} 模式与出口字面量 ${host} 地址族不一致"
                return 10
            fi
            if [[ -n "$publish_family" && "$publish_family" != "$family" ]]; then
                vps_cmd_error "转发 ${forward_id} 的 ${family} 模式与发布地址字面量 ${publish} 地址族不一致"
                return 10
            fi
        fi
    done < <(jq -c '.forwards[]' "$file")

    if [[ -n "$nodes" && -e "$nodes" ]]; then
        [[ -f "$nodes" && ! -L "$nodes" ]] || {
            vps_cmd_error "节点清单不是安全的普通文件：$nodes"
            return 3
        }
        jq -e '((.nodes | type) == "array") and all(.nodes[]; (.port | type) == "number" and (.port | floor) == .port and .port >= 1 and .port <= 65535)' "$nodes" >/dev/null 2>&1 || {
            vps_cmd_error "节点清单端口格式无效：$nodes"
            return 10
        }
    fi
    proxy_relay_forward_validate_conflicts "$file" "$nodes"
}

proxy_relay_forward_validate_manifest() {
    proxy_relay_forward_manifest_validate "$@"
}

proxy_relay_forward_resolve_family() {
    local host="${1:-}" family="${2:-}" database
    case "$family" in
        ipv4)
            if _proxy_relay_forward_valid_ipv4 "$host"; then printf '%s\n' "$host"; return 0; fi
            database=ahostsv4
            ;;
        ipv6)
            if _proxy_relay_forward_valid_ipv6 "$host"; then printf '%s\n' "$host"; return 0; fi
            database=ahostsv6
            ;;
        *) return 2 ;;
    esac
    getent "$database" "$host" 2>/dev/null | awk '{print $1}' | LC_ALL=C sort -u
}

proxy_relay_forward_validate_family_candidate() {
    local family="${1:-}" host="${2:-}" publish="${3:-}"
    local host_family publish_family requested resolved available=0
    case "$family" in dual | ipv4 | ipv6) ;; *) return 2 ;; esac
    _proxy_relay_forward_valid_host_value "$host" || {
        vps_cmd_error "出口主机不是有效的 IP 字面量或 DNS 主机名：${host}"
        return 2
    }
    _proxy_relay_forward_valid_host_value "$publish" || {
        vps_cmd_error "发布地址不是有效的 IP 字面量或 DNS 主机名：${publish}"
        return 2
    }

    host_family="$(_proxy_relay_forward_address_family "$host" 2>/dev/null || true)"
    publish_family="$(_proxy_relay_forward_address_family "$publish" 2>/dev/null || true)"
    if [[ "$family" != dual && -n "$publish_family" && "$publish_family" != "$family" ]]; then
        vps_cmd_error "${family} 转发的发布地址字面量必须使用同一地址族：${publish}"
        return 2
    fi
    if [[ -n "$host_family" ]]; then
        if [[ "$family" != dual && "$host_family" != "$family" ]]; then
            vps_cmd_error "${family} 转发不能使用相反地址族的出口字面量：${host}"
            return 2
        fi
        return 0
    fi

    for requested in ipv4 ipv6; do
        [[ "$family" == dual || "$family" == "$requested" ]] || continue
        resolved="$(proxy_relay_forward_resolve_family "$host" "$requested" | _proxy_relay_forward_first_valid_address "$requested" || true)"
        [[ -z "$resolved" ]] || available=$((available + 1))
    done
    if ((available == 0)); then
        vps_cmd_error "出口域名 ${host} 没有 ${family} 模式所需的可用地址"
        return 3
    fi
}

_proxy_relay_forward_first_valid_address() {
    local family="$1" address
    while IFS= read -r address; do
        case "$family" in
            ipv4) _proxy_relay_forward_valid_ipv4 "$address" || continue ;;
            ipv6) _proxy_relay_forward_valid_ipv6 "$address" || continue ;;
            *) return 2 ;;
        esac
        printf '%s' "$address"
        return 0
    done
    return 1
}

proxy_relay_forward_refresh_cache() {
    local manifest="${1:-}" old_cache="${2:-}" output="${3:-}"
    local cache='{"schema_version":1,"exits":{}}' degraded='[]' resolved_list exit id host family resolved old_address now entry retained literal_family="" required_families
    [[ -f "$manifest" && ! -L "$manifest" && -n "$output" ]] || return 2
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    while IFS= read -r exit; do
        [[ -n "$exit" ]] || continue
        id="$(jq -r '.id' <<<"$exit")"
        host="$(jq -r '.endpoint.host' <<<"$exit")"
        literal_family=""
        if _proxy_relay_forward_valid_ipv4 "$host"; then literal_family=ipv4
        elif _proxy_relay_forward_valid_ipv6 "$host"; then literal_family=ipv6
        fi
        required_families="$(jq -r --arg id "$id" '[.forwards[] | select(.exit_id == $id) | (.family // "dual") | if . == "dual" then "ipv4", "ipv6" else . end] | unique[]' "$manifest")" || return 20
        entry='{}'
        for family in ipv4 ipv6; do
            grep -Fxq "$family" <<<"$required_families" || continue
            retained=false
            if [[ -n "$literal_family" && "$family" != "$literal_family" ]]; then
                degraded="$(jq -cn --argjson current "$degraded" --arg id "$id" --arg host "$host" --arg family "$family" '$current + [{exit_id:$id,host:$host,family:$family,reason:"family-unavailable",retained:false}]')" || return 20
                continue
            fi
            resolved="$(proxy_relay_forward_resolve_family "$host" "$family" | LC_ALL=C sort -u | _proxy_relay_forward_first_valid_address "$family" || true)"
            if [[ -z "$resolved" && -n "$old_cache" && -f "$old_cache" ]]; then
                old_address="$(jq -r --arg id "$id" --arg host "$host" --arg family "$family" '.exits[$id] | select(.host == $host) | .[$family] // empty' "$old_cache" 2>/dev/null || true)"
                case "$family" in
                    ipv4) _proxy_relay_forward_valid_ipv4 "$old_address" || old_address="" ;;
                    ipv6) _proxy_relay_forward_valid_ipv6 "$old_address" || old_address="" ;;
                esac
                resolved="$old_address"
                if [[ -n "$resolved" ]]; then
                    retained=true
                    vps_cmd_warning "${host} 的 ${family} 解析失败，保留缓存地址 ${resolved}"
                fi
            fi
            if [[ -z "$resolved" || "$retained" == true ]]; then
                degraded="$(jq -cn --argjson current "$degraded" --arg id "$id" --arg host "$host" --arg family "$family" --argjson retained "$retained" '$current + [{exit_id:$id,host:$host,family:$family,reason:"dns-failed",retained:$retained}]')" || return 20
            fi
            entry="$(jq -cn --argjson current "$entry" --arg key "$family" --arg value "$resolved" '$current + {($key): (if $value == "" then null else $value end)}')" || return 20
        done
        entry="$(jq -cn --argjson current "$entry" --arg host "$host" --arg updated "$now" '$current + {host:$host,updated_at:$updated}')" || return 20
        cache="$(jq -cn --argjson current "$cache" --arg id "$id" --argjson entry "$entry" '$current | .exits[$id]=$entry')" || return 20
    done < <(jq -c '. as $root | .exits[] as $exit |
        select(any($root.forwards[]; .exit_id == $exit.id)) | $exit' "$manifest")

    resolved_list="$(jq -c '[.exits | to_entries[] | {exit_id:.key,host:.value.host,ipv4:(.value.ipv4 // null),ipv6:(.value.ipv6 // null)}]' <<<"$cache")" || return 20
    jq -n --argjson cache "$cache" --argjson resolved "$resolved_list" --argjson degraded "$degraded" --arg generated "$now" '$cache + {resolved:$resolved,degraded:$degraded,updated_at:$generated,generated_at:$generated}' >"$output" || return 20
    chmod 0600 -- "$output" || return 20
}

_proxy_relay_forward_local_addresses() {
    printf '%s\n' 127.0.0.1 ::1
    command -v ip >/dev/null 2>&1 || return 0
    ip -o address show 2>/dev/null | awk '{address=$4; sub(/\/.*/, "", address); print address}' | LC_ALL=C sort -u
}

proxy_relay_forward_detect_loops() {
    local manifest="${1:-}" cache="${2:-}" forward exit_id address family forward_family local_address
    local -a local_addresses=()
    while IFS= read -r local_address; do
        [[ -n "$local_address" ]] && local_addresses+=("$local_address")
    done < <(_proxy_relay_forward_local_addresses)
    while IFS= read -r forward; do
        [[ -n "$forward" ]] || continue
        exit_id="$(jq -r '.exit_id' <<<"$forward")"
        forward_family="$(jq -r '.family // "dual"' <<<"$forward")"
        for family in ipv4 ipv6; do
            [[ "$forward_family" == dual || "$forward_family" == "$family" ]] || continue
            address="$(jq -r --arg id "$exit_id" --arg family "$family" '.exits[$id][$family] // empty' "$cache")"
            [[ -n "$address" ]] || continue
            for local_address in "${local_addresses[@]}"; do
                if [[ "$address" == "$local_address" ]]; then
                    vps_cmd_error "转发 $(jq -r '.id' <<<"$forward") 的出口 ${address} 是本机地址，可能形成 DNAT 循环"
                    return 10
                fi
            done
        done
    done < <(jq -c '.forwards[]' "$manifest")
}

_proxy_relay_forward_nft_range() {
    local start="$1" end="$2"
    if [[ "$start" == "$end" ]]; then printf '%s' "$start"; else printf '%s-%s' "$start" "$end"; fi
}

_proxy_relay_forward_publish_match() {
    # publish_address belongs to generated client URIs and may be a public NAT
    # address or hostname that is not assigned to this machine.  nft matching
    # is therefore limited with `fib daddr type local`, never by this value.
    return 0
}

_proxy_relay_forward_emit_rule_set() {
    local family="$1" table="$2" target="$3" target_port="$4" publish="$5" protocol="$6" start="$7" end="$8" id="$9"
    local range match destination
    range="$(_proxy_relay_forward_nft_range "$start" "$end")"
    match="$(_proxy_relay_forward_publish_match "$family" "$publish")" || return 0
    if [[ "$family" == ip6 ]]; then destination="[${target}]:${target_port}"; else destination="${target}:${target_port}"; fi
    printf 'add rule %s %s prerouting fib daddr type local %s%s dport %s counter dnat to %s comment "vpsctl:%s"\n' "$family" "$table" "$match" "$protocol" "$range" "$destination" "$id"
    printf 'add rule %s %s forward ct status dnat %s daddr %s %s dport %s ct state { new, established, related } counter accept comment "vpsctl:%s"\n' "$family" "$table" "$family" "$target" "$protocol" "$target_port" "$id"
    printf 'add rule %s %s forward ct status dnat ct direction reply ct original proto-dst %s meta l4proto %s ct state { established, related } counter accept comment "vpsctl:%s:return"\n' "$family" "$table" "$range" "$protocol" "$id"
    printf 'add rule %s %s postrouting ct status dnat %s daddr %s %s dport %s counter masquerade comment "vpsctl:%s"\n' "$family" "$table" "$family" "$target" "$protocol" "$target_port" "$id"
}

proxy_relay_forward_render_nft() {
    local manifest="${1:-}" cache="${2:-}" forward id exit_id network hint effective start end publish family forward_family target target_port table protocol
    [[ -f "$manifest" && ! -L "$manifest" && -f "$cache" && ! -L "$cache" ]] || return 2
    printf 'destroy table ip %s\nadd table ip %s\n' "$PROXY_RELAY_FORWARD_TABLE4" "$PROXY_RELAY_FORWARD_TABLE4"
    printf 'add chain ip %s prerouting { type nat hook prerouting priority dstnat; policy accept; }\n' "$PROXY_RELAY_FORWARD_TABLE4"
    printf 'add chain ip %s forward { type filter hook forward priority filter; policy accept; }\n' "$PROXY_RELAY_FORWARD_TABLE4"
    printf 'add chain ip %s postrouting { type nat hook postrouting priority srcnat; policy accept; }\n' "$PROXY_RELAY_FORWARD_TABLE4"
    printf 'destroy table ip6 %s\nadd table ip6 %s\n' "$PROXY_RELAY_FORWARD_TABLE6" "$PROXY_RELAY_FORWARD_TABLE6"
    printf 'add chain ip6 %s prerouting { type nat hook prerouting priority dstnat; policy accept; }\n' "$PROXY_RELAY_FORWARD_TABLE6"
    printf 'add chain ip6 %s forward { type filter hook forward priority filter; policy accept; }\n' "$PROXY_RELAY_FORWARD_TABLE6"
    printf 'add chain ip6 %s postrouting { type nat hook postrouting priority srcnat; policy accept; }\n' "$PROXY_RELAY_FORWARD_TABLE6"

    while IFS= read -r forward; do
        [[ -n "$forward" ]] || continue
        id="$(jq -r '.id' <<<"$forward")"
        exit_id="$(jq -r '.exit_id' <<<"$forward")"
        network="$(jq -r '.network' <<<"$forward")"
        hint="$(_proxy_relay_forward_exit_hint "$manifest" "$exit_id")"
        effective="$(proxy_relay_forward_effective_network "$network" "$hint")" || return $?
        start="$(jq -r '.listen_port_start' <<<"$forward")"
        end="$(jq -r '.listen_port_end' <<<"$forward")"
        publish="$(jq -r '.publish_address' <<<"$forward")"
        forward_family="$(jq -r '.family // "dual"' <<<"$forward")"
        target_port="$(jq -r --arg id "$exit_id" '.exits[] | select(.id == $id) | .endpoint.port' "$manifest")"
        for family in ip ip6; do
            if [[ "$family" == ip ]]; then
                [[ "$forward_family" == dual || "$forward_family" == ipv4 ]] || continue
                target="$(jq -r --arg id "$exit_id" '.exits[$id].ipv4 // empty' "$cache")"
                table="$PROXY_RELAY_FORWARD_TABLE4"
            else
                [[ "$forward_family" == dual || "$forward_family" == ipv6 ]] || continue
                target="$(jq -r --arg id "$exit_id" '.exits[$id].ipv6 // empty' "$cache")"
                table="$PROXY_RELAY_FORWARD_TABLE6"
            fi
            [[ -n "$target" ]] || continue
            case "$effective" in
                tcp) _proxy_relay_forward_emit_rule_set "$family" "$table" "$target" "$target_port" "$publish" tcp "$start" "$end" "$id" ;;
                udp) _proxy_relay_forward_emit_rule_set "$family" "$table" "$target" "$target_port" "$publish" udp "$start" "$end" "$id" ;;
                both)
                    for protocol in tcp udp; do
                        _proxy_relay_forward_emit_rule_set "$family" "$table" "$target" "$target_port" "$publish" "$protocol" "$start" "$end" "$id"
                    done
                    ;;
                *) return 10 ;;
            esac
        done
    done < <(jq -c '.forwards[]' "$manifest")
}

_proxy_relay_forward_runtime_allowed() {
    if [[ "${VPSCTL_TESTING:-0}" == 1 && "${PROXY_RELAY_FORWARD_ALLOW_TEST_RUNTIME:-0}" != 1 ]]; then
        vps_cmd_error "测试系统根模式拒绝修改宿主机 nft/sysctl/init 状态；请显式使用 mock 并设置 PROXY_RELAY_FORWARD_ALLOW_TEST_RUNTIME=1"
        return 3
    fi
}

proxy_relay_forward_nft_check() {
    local batch="${1:-}"
    [[ -f "$batch" && ! -L "$batch" ]] || return 2
    _proxy_relay_forward_runtime_allowed || return $?
    nft -c -f "$batch" >/dev/null 2>&1 || {
        vps_cmd_error "nftables 拒绝 relay forward 候选批次"
        return 10
    }
}

proxy_relay_forward_nft_apply() {
    local batch="${1:-}"
    [[ -f "$batch" && ! -L "$batch" ]] || return 2
    _proxy_relay_forward_runtime_allowed || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_run nft -f "$batch"
        return $?
    fi
    nft -f "$batch" || {
        vps_cmd_error "原子应用 relay forward nftables 批次失败，内核未提交部分规则"
        return 20
    }
}

proxy_relay_forward_nft_snapshot() {
    local output="${1:-}" tmp found=0 tables has4 has6
    [[ -n "$output" ]] || return 2
    _proxy_relay_forward_runtime_allowed || return $?
    tmp="${output}.part"
    : >"$tmp" || return 20
    tables="$(nft -j list tables 2>/dev/null)" || {
        rm -f -- "$tmp"
        vps_cmd_error "无法枚举 nftables 表，拒绝在缺少可靠快照时替换转发规则"
        return 20
    }
    has4="$(jq -r --arg family ip --arg name "$PROXY_RELAY_FORWARD_TABLE4" '
        any(.nftables[]?.table?; .family == $family and .name == $name)
    ' <<<"$tables")" || { rm -f -- "$tmp"; return 20; }
    has6="$(jq -r --arg family ip6 --arg name "$PROXY_RELAY_FORWARD_TABLE6" '
        any(.nftables[]?.table?; .family == $family and .name == $name)
    ' <<<"$tables")" || { rm -f -- "$tmp"; return 20; }
    if [[ "$has4" == true ]]; then
        nft list table ip "$PROXY_RELAY_FORWARD_TABLE4" >>"$tmp" 2>/dev/null || {
            rm -f -- "$tmp"
            vps_cmd_error "读取 IPv4 受管 nftables 表失败，拒绝替换"
            return 20
        }
        found=1
    fi
    if [[ "$has6" == true ]]; then
        nft list table ip6 "$PROXY_RELAY_FORWARD_TABLE6" >>"$tmp" 2>/dev/null || {
            rm -f -- "$tmp"
            vps_cmd_error "读取 IPv6 受管 nftables 表失败，拒绝替换"
            return 20
        }
        found=1
    fi
    if ((found == 0)); then
        rm -f -- "$tmp"
        return 1
    fi
    mv -- "$tmp" "$output" || return 20
    chmod 0600 -- "$output" || return 20
    return 0
}

_proxy_relay_forward_warn_external_policy() {
    local rules
    rules="$(nft -j list ruleset 2>/dev/null || true)"
    [[ -n "$rules" ]] || return 0
    if jq -e --arg table4 "$PROXY_RELAY_FORWARD_TABLE4" --arg table6 "$PROXY_RELAY_FORWARD_TABLE6" '
        any(.nftables[]?.chain;
            .hook == "forward" and (.policy == "drop" or .policy == "reject") and
            .table != $table4 and .table != $table6)
    ' <<<"$rules" >/dev/null 2>&1; then
        vps_cmd_warning "检测到其他 nftables FORWARD 链的拒绝策略；若中转不通，请检查 UFW/firewalld/自定义防火墙的后续链"
    fi
}

proxy_relay_forward_nft_clear() {
    local tmp has=0
    _proxy_relay_forward_runtime_allowed || return $?
    tmp="$(mktemp "${TMPDIR:-/tmp}/vpsctl-relay-forward.clear.XXXXXX")" || return 20
    if nft list table ip "$PROXY_RELAY_FORWARD_TABLE4" >/dev/null 2>&1; then
        printf 'delete table ip %s\n' "$PROXY_RELAY_FORWARD_TABLE4" >>"$tmp"
        has=1
    fi
    if nft list table ip6 "$PROXY_RELAY_FORWARD_TABLE6" >/dev/null 2>&1; then
        printf 'delete table ip6 %s\n' "$PROXY_RELAY_FORWARD_TABLE6" >>"$tmp"
        has=1
    fi
    if ((has)); then
        proxy_relay_forward_nft_check "$tmp" && proxy_relay_forward_nft_apply "$tmp"
        local status=$?
        rm -f -- "$tmp"
        return "$status"
    fi
    rm -f -- "$tmp"
}

proxy_relay_forward_nft_restore() {
    local snapshot="${1:-}" batch status
    [[ -f "$snapshot" && ! -L "$snapshot" ]] || return 2
    _proxy_relay_forward_runtime_allowed || return $?
    batch="$(mktemp "${TMPDIR:-/tmp}/vpsctl-relay-forward.restore.XXXXXX")" || return 20
    {
        printf 'destroy table ip %s\n' "$PROXY_RELAY_FORWARD_TABLE4"
        printf 'destroy table ip6 %s\n' "$PROXY_RELAY_FORWARD_TABLE6"
        cat -- "$snapshot"
    } >"$batch" || { rm -f -- "$batch"; return 20; }
    if proxy_relay_forward_nft_check "$batch" && proxy_relay_forward_nft_apply "$batch"; then
        status=0
    else
        status=$?
    fi
    rm -f -- "$batch"
    return "$status"
}

_proxy_relay_forward_require_safe_paths() {
    local path
    for path in "$PROXY_RELAY_FORWARD_MANIFEST" "$PROXY_RELAY_FORWARD_CACHE" "$PROXY_RELAY_FORWARD_HELPER" "$PROXY_RELAY_FORWARD_SERVICE" "$PROXY_RELAY_FORWARD_SYSCTL" "$PROXY_RELAY_FORWARD_RUNTIME"; do
        vps_cmd_require_no_symlink_components "$path" || return $?
    done
}

_proxy_relay_forward_file_is_managed() {
    local path="${1:-}"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    head -n 3 -- "$path" | grep -Fq 'Managed by vpsctl proxy relay-forward.'
}

_proxy_relay_forward_require_managed_targets() {
    local path
    for path in "$PROXY_RELAY_FORWARD_HELPER" "$PROXY_RELAY_FORWARD_SERVICE" "$PROXY_RELAY_FORWARD_SYSCTL"; do
        [[ ! -e "$path" ]] || _proxy_relay_forward_file_is_managed "$path" || {
            vps_cmd_error "拒绝覆盖不受 vpsctl 管理的文件：$path"
            return 3
        }
    done
}

_proxy_relay_forward_ensure_layout() {
    local directory
    vps_cmd_require_root || return $?
    _proxy_relay_forward_require_safe_paths || return $?
    for directory in "$(dirname -- "$PROXY_RELAY_FORWARD_MANIFEST")" "$(dirname -- "$PROXY_RELAY_FORWARD_HELPER")" "$(dirname -- "$PROXY_RELAY_FORWARD_SERVICE")" "$(dirname -- "$PROXY_RELAY_FORWARD_SYSCTL")" \
        "$PROXY_RELAY_FORWARD_RUNTIME/lib" "$PROXY_RELAY_FORWARD_RUNTIME/commands/service/proxy"; do
        if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
            vps_cmd_run mkdir -p "$directory" || return 20
        else
            mkdir -p -- "$directory" || return 20
            vps_cmd_require_no_symlink_components "$directory" || return $?
        fi
    done
}

proxy_relay_forward_install_runtime() {
    local relative source logical_target physical_target mode
    local -a files=(
        lib/command.sh
        lib/ui.sh
        commands/service/proxy.sh
        commands/service/proxy/common.sh
        commands/service/proxy/protocols-sing-box.sh
        commands/service/proxy/protocols-xray.sh
        commands/service/proxy/nodes.sh
        commands/service/proxy/relay-uri.sh
        commands/service/proxy/relay-forward.sh
        commands/service/proxy/relay.sh
        commands/service/proxy/core.sh
        commands/service/proxy/time.sh
    )
    proxy_relay_forward_init || return $?
    _proxy_relay_forward_ensure_layout || return $?
    for relative in "${files[@]}"; do
        source="${PROXY_PROJECT_ROOT}/${relative}"
        [[ -f "$source" && -r "$source" && ! -L "$source" ]] || {
            vps_cmd_error "无法安全安装 relay forward 运行时文件：$source"
            return 3
        }
        vps_cmd_require_no_symlink_components "$source" || return $?
        logical_target="${PROXY_RELAY_FORWARD_RUNTIME_LOGICAL}/${relative}"
        physical_target="${PROXY_RELAY_FORWARD_RUNTIME}/${relative}"
        mode=0644
        [[ "$relative" != commands/service/proxy.sh ]] || mode=0755
        [[ "$source" != "$physical_target" ]] || continue
        if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
            vps_cmd_info "演练：安装 relay forward 运行时 ${logical_target}"
        else
            proxy_atomic_write_from_file "$source" "$logical_target" "$mode" || return 20
        fi
    done
}

proxy_relay_forward_emit_helper() {
    cat <<EOF
#!/usr/bin/env bash
# Managed by vpsctl proxy relay-forward.
set -Eeuo pipefail
mode="\${1:-refresh}"
case "\$mode" in
    refresh) exec bash ${PROXY_RELAY_FORWARD_RUNTIME_LOGICAL}/commands/service/proxy.sh --non-interactive --quiet relay forward refresh ;;
    clear) exec bash ${PROXY_RELAY_FORWARD_RUNTIME_LOGICAL}/commands/service/proxy.sh --non-interactive relay forward clear ;;
    watch)
        trap 'exit 0' INT TERM
        while :; do
            bash ${PROXY_RELAY_FORWARD_RUNTIME_LOGICAL}/commands/service/proxy.sh --non-interactive --quiet relay forward refresh || true
            sleep 300 &
            wait \$! || exit 0
        done
        ;;
    *) echo "usage: \$0 refresh|clear|watch" >&2; exit 2 ;;
esac
EOF
}

proxy_relay_forward_emit_service() {
    case "${PROXY_INIT_SYSTEM:-unknown}" in
        systemd)
            cat <<EOF
# Managed by vpsctl proxy relay-forward.
[Unit]
Description=vpsctl managed relay port forwarding
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${PROXY_RELAY_FORWARD_HELPER_LOGICAL} watch
ExecReload=${PROXY_RELAY_FORWARD_HELPER_LOGICAL} refresh
ExecStopPost=-${PROXY_RELAY_FORWARD_HELPER_LOGICAL} clear
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
            ;;
        openrc)
            cat <<EOF
#!/sbin/openrc-run
# Managed by vpsctl proxy relay-forward.
description="vpsctl managed relay port forwarding"
command="${PROXY_RELAY_FORWARD_HELPER_LOGICAL}"
command_args="watch"
command_background="yes"
pidfile="/run/vpsctl-proxy-forward.pid"

depend() {
    need net
}

reload() {
    ${PROXY_RELAY_FORWARD_HELPER_LOGICAL} refresh
}

stop_post() {
    ${PROXY_RELAY_FORWARD_HELPER_LOGICAL} clear || true
}
EOF
            ;;
        *) return 3 ;;
    esac
}

proxy_relay_forward_emit_sysctl() {
    cat <<'EOF'
# Managed by vpsctl proxy relay-forward.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
}

_proxy_relay_forward_service_action() {
    local action="${1:-}"
    _proxy_relay_forward_runtime_allowed || return $?
    case "${PROXY_INIT_SYSTEM:-unknown}:$action" in
        systemd:reload-manager) vps_cmd_run systemctl daemon-reload ;;
        systemd:enable-now) vps_cmd_run systemctl enable --now vpsctl-proxy-forward.service ;;
        systemd:disable-now) vps_cmd_run systemctl disable --now vpsctl-proxy-forward.service ;;
        systemd:reload) vps_cmd_run systemctl reload vpsctl-proxy-forward.service ;;
        openrc:reload-manager) return 0 ;;
        openrc:enable-now) vps_cmd_run rc-update add vpsctl-proxy-forward default && vps_cmd_run rc-service vpsctl-proxy-forward start ;;
        openrc:disable-now)
            if rc-service vpsctl-proxy-forward status >/dev/null 2>&1; then
                vps_cmd_run rc-service vpsctl-proxy-forward stop || return $?
            fi
            if rc-update show default 2>/dev/null |
                awk '$1 == "vpsctl-proxy-forward" { found=1 } END { exit(found ? 0 : 1) }'; then
                vps_cmd_run rc-update del vpsctl-proxy-forward default || return $?
            fi
            ;;
        openrc:reload) vps_cmd_run rc-service vpsctl-proxy-forward reload ;;
        *) return 2 ;;
    esac
}

proxy_relay_forward_apply() (
    local tmp cache_candidate batch referenced_missing snapshot cache_backup
    local had_snapshot=0 cache_existed=0 rollback_failed=0 snapshot_status=0
    proxy_relay_forward_init || return $?
    vps_cmd_require_root || return $?
    proxy_ensure_mutation_tools relay-forward-refresh jq nft getent ip || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    _proxy_relay_forward_require_safe_paths || return $?
    proxy_relay_forward_manifest_validate "$PROXY_RELAY_FORWARD_MANIFEST" "${PROXY_MANIFEST:-}" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：刷新 relay DNS 缓存，预检并原子替换两个受管 nftables 表"
        return 0
    fi
    tmp="$(mktemp -d "${PROXY_STATE_DIR}/.relay-forward.XXXXXX")" || return 20
    chmod 0700 -- "$tmp" || { rm -rf -- "$tmp"; return 20; }
    cache_candidate="$tmp/cache.json"
    batch="$tmp/rules.nft"
    snapshot="$tmp/rules.old.nft"
    cache_backup="$tmp/cache.old.json"
    if proxy_relay_forward_nft_snapshot "$snapshot"; then
        had_snapshot=1
    else
        snapshot_status=$?
        if ((snapshot_status != 1)); then
            rm -rf -- "$tmp"
            return "$snapshot_status"
        fi
    fi
    if [[ -f "$PROXY_RELAY_FORWARD_CACHE" && ! -L "$PROXY_RELAY_FORWARD_CACHE" ]]; then
        cp -p -- "$PROXY_RELAY_FORWARD_CACHE" "$cache_backup" || { rm -rf -- "$tmp"; return 20; }
        cache_existed=1
    fi
    proxy_relay_forward_refresh_cache "$PROXY_RELAY_FORWARD_MANIFEST" "$PROXY_RELAY_FORWARD_CACHE" "$cache_candidate" || { local rc=$?; rm -rf -- "$tmp"; return "$rc"; }
    proxy_relay_forward_detect_loops "$PROXY_RELAY_FORWARD_MANIFEST" "$cache_candidate" || { local rc=$?; rm -rf -- "$tmp"; return "$rc"; }
    referenced_missing="$(jq -r --slurpfile manifest "$PROXY_RELAY_FORWARD_MANIFEST" '
        . as $cache |
        [$manifest[0].forwards[] |
            (.family // "dual") as $family |
            select(if $family == "ipv4" then ($cache.exits[.exit_id].ipv4 // null) == null
                   elif $family == "ipv6" then ($cache.exits[.exit_id].ipv6 // null) == null
                   else (($cache.exits[.exit_id].ipv4 // null) == null and ($cache.exits[.exit_id].ipv6 // null) == null)
                   end) |
            (.id + "/" + $family)] | unique | join(",")
    ' "$cache_candidate")" || { rm -rf -- "$tmp"; return 20; }
    if [[ -n "$referenced_missing" ]]; then
        vps_cmd_error "以下转发没有所需地址族的可用 DNS 地址且无旧缓存：$referenced_missing"
        rm -rf -- "$tmp"
        return 20
    fi
    proxy_relay_forward_render_nft "$PROXY_RELAY_FORWARD_MANIFEST" "$cache_candidate" >"$batch" || { local rc=$?; rm -rf -- "$tmp"; return "$rc"; }
    chmod 0600 -- "$batch" || { rm -rf -- "$tmp"; return 20; }
    proxy_relay_forward_nft_check "$batch" || { local rc=$?; rm -rf -- "$tmp"; return "$rc"; }
    proxy_relay_forward_nft_apply "$batch" || { local rc=$?; rm -rf -- "$tmp"; return "$rc"; }
    if ! proxy_atomic_write_from_file "$cache_candidate" "$PROXY_RELAY_FORWARD_CACHE_LOGICAL" 0600; then
        if ((had_snapshot)); then
            proxy_relay_forward_nft_restore "$snapshot" || rollback_failed=1
        else
            proxy_relay_forward_nft_clear || rollback_failed=1
        fi
        if ((cache_existed)); then
            proxy_atomic_write_from_file "$cache_backup" "$PROXY_RELAY_FORWARD_CACHE_LOGICAL" 0600 || rollback_failed=1
        else
            rm -f -- "$PROXY_RELAY_FORWARD_CACHE" || rollback_failed=1
        fi
        rm -rf -- "$tmp"
        ((rollback_failed == 0)) || return 30
        vps_cmd_error "写入 relay DNS 缓存失败，已恢复旧 nftables 规则与缓存"
        return 20
    fi
    _proxy_relay_forward_warn_external_policy
    rm -rf -- "$tmp"
    vps_cmd_success "relay DNS 缓存与受管 nftables 表已刷新"
)

proxy_relay_forward_clear() {
    proxy_relay_forward_init || return $?
    vps_cmd_require_root || return $?
    proxy_ensure_mutation_tools relay-forward-clear nft || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：原子删除 relay forward 独立受管 nftables 表"
        return 0
    fi
    proxy_relay_forward_nft_clear
}

proxy_relay_forward_refresh_runtime() {
    local forward_id="${1:-}"
    (($# <= 1)) || {
        vps_cmd_error "refresh-runtime 最多接受一个 FORWARD_ID"
        return 2
    }
    proxy_relay_forward_init || return $?
    vps_cmd_require_root || return $?
    proxy_ensure_tools relay-forward-refresh-runtime jq || return $?
    if [[ -n "$forward_id" ]]; then
        [[ "$forward_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
            vps_cmd_error "无效的 relay forward ID：$forward_id"
            return 2
        }
        jq -e --arg id "$forward_id" '.forwards[] | select(.id == $id)' "$PROXY_RELAY_FORWARD_MANIFEST" >/dev/null 2>&1 || {
            vps_cmd_error "未找到 relay forward：$forward_id"
            return 3
        }
    fi
    # nft tables are replaced as one transaction, so even an ID-scoped refresh
    # deliberately re-renders the complete managed ruleset.
    proxy_relay_forward_apply
}

_proxy_relay_forward_runtime_active() {
    [[ "${VPSCTL_TESTING:-0}" != 1 || "${PROXY_RELAY_FORWARD_ALLOW_TEST_RUNTIME:-0}" == 1 ]] || return 1
    case "${PROXY_INIT_SYSTEM:-unknown}" in
        systemd) systemctl is-active --quiet vpsctl-proxy-forward.service ;;
        openrc) rc-service vpsctl-proxy-forward status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

_proxy_relay_forward_runtime_enabled() {
    [[ "${VPSCTL_TESTING:-0}" != 1 || "${PROXY_RELAY_FORWARD_ALLOW_TEST_RUNTIME:-0}" == 1 ]] || return 1
    case "${PROXY_INIT_SYSTEM:-unknown}" in
        systemd) systemctl is-enabled --quiet vpsctl-proxy-forward.service ;;
        openrc)
            rc-update show default 2>/dev/null |
                awk '$1 == "vpsctl-proxy-forward" { found=1 } END { exit(found ? 0 : 1) }'
            ;;
        *) return 1 ;;
    esac
}

proxy_relay_forward_runtime_status() {
    local installed=false active=false enabled=false degraded='[]'
    proxy_relay_forward_init || return $?
    proxy_ensure_tools relay-forward-status jq || return $?
    if [[ -f "$PROXY_RELAY_FORWARD_HELPER" && ! -L "$PROXY_RELAY_FORWARD_HELPER" &&
          -f "$PROXY_RELAY_FORWARD_SERVICE" && ! -L "$PROXY_RELAY_FORWARD_SERVICE" &&
          -f "$PROXY_RELAY_FORWARD_SYSCTL" && ! -L "$PROXY_RELAY_FORWARD_SYSCTL" &&
          -f "$PROXY_RELAY_FORWARD_RUNTIME/lib/ui.sh" && ! -L "$PROXY_RELAY_FORWARD_RUNTIME/lib/ui.sh" &&
          -f "$PROXY_RELAY_FORWARD_RUNTIME/commands/service/proxy.sh" ]]; then
        installed=true
    fi
    _proxy_relay_forward_runtime_active && active=true
    _proxy_relay_forward_runtime_enabled && enabled=true
    if [[ -e "$PROXY_RELAY_FORWARD_CACHE" ]]; then
        if [[ -f "$PROXY_RELAY_FORWARD_CACHE" && ! -L "$PROXY_RELAY_FORWARD_CACHE" ]] &&
           jq -e '.schema_version == 1 and ((.degraded // []) | type) == "array"' "$PROXY_RELAY_FORWARD_CACHE" >/dev/null 2>&1; then
            degraded="$(jq -c '.degraded // []' "$PROXY_RELAY_FORWARD_CACHE")" || return 20
        else
            degraded='[{"reason":"cache-invalid"}]'
        fi
    fi
    jq -n --argjson installed "$installed" --argjson active "$active" --argjson enabled "$enabled" --argjson degraded "$degraded" \
        '{installed:$installed,active:$active,enabled:$enabled,degraded:$degraded}'
}

proxy_relay_forward_install_service() (
    local tmp helper_candidate service_candidate sysctl_candidate count rc
    proxy_relay_forward_init || return $?
    proxy_require_platform || return $?
    vps_cmd_require_root || return $?
    proxy_ensure_mutation_tools relay-forward-install jq nft getent ip sysctl || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    _proxy_relay_forward_ensure_layout || return $?
    _proxy_relay_forward_require_managed_targets || return $?
    proxy_relay_forward_install_runtime || return $?
    if [[ ! -e "$PROXY_RELAY_FORWARD_MANIFEST" ]]; then
        if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
            vps_cmd_info "演练：初始化 relay 清单 $PROXY_RELAY_FORWARD_MANIFEST_LOGICAL"
        else
            proxy_relay_forward_manifest_default | vps_cmd_atomic_write "$PROXY_RELAY_FORWARD_MANIFEST_LOGICAL" 0600 || return 20
        fi
    fi
    if [[ -e "$PROXY_RELAY_FORWARD_MANIFEST" ]]; then
        proxy_relay_forward_manifest_validate "$PROXY_RELAY_FORWARD_MANIFEST" "${PROXY_MANIFEST:-}" || return $?
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：安装 relay forward helper、${PROXY_INIT_SYSTEM} 服务和独立 forwarding sysctl 文件"
        return 0
    fi
    tmp="$(mktemp -d "${PROXY_STATE_DIR}/.relay-forward-install.XXXXXX")" || return 20
    helper_candidate="$tmp/helper"; service_candidate="$tmp/service"; sysctl_candidate="$tmp/sysctl"
    proxy_relay_forward_emit_helper >"$helper_candidate" || { rm -rf -- "$tmp"; return 20; }
    proxy_relay_forward_emit_service >"$service_candidate" || { rm -rf -- "$tmp"; return 20; }
    proxy_relay_forward_emit_sysctl >"$sysctl_candidate" || { rm -rf -- "$tmp"; return 20; }
    chmod 0755 "$helper_candidate" || { rm -rf -- "$tmp"; return 20; }
    proxy_atomic_write_from_file "$helper_candidate" "$PROXY_RELAY_FORWARD_HELPER_LOGICAL" 0755 || { rm -rf -- "$tmp"; return 20; }
    proxy_atomic_write_from_file "$service_candidate" "$PROXY_RELAY_FORWARD_SERVICE_LOGICAL" "$( [[ "$PROXY_INIT_SYSTEM" == systemd ]] && printf 0644 || printf 0755 )" || { rm -rf -- "$tmp"; return 20; }
    proxy_atomic_write_from_file "$sysctl_candidate" "$PROXY_RELAY_FORWARD_SYSCTL_LOGICAL" 0644 || { rm -rf -- "$tmp"; return 20; }
    _proxy_relay_forward_runtime_allowed || { rc=$?; rm -rf -- "$tmp"; return "$rc"; }
    sysctl -p "$PROXY_RELAY_FORWARD_SYSCTL" >/dev/null || { rm -rf -- "$tmp"; return 20; }
    _proxy_relay_forward_service_action reload-manager || { rm -rf -- "$tmp"; return 20; }
    count="$(jq -r '.forwards | length' "$PROXY_RELAY_FORWARD_MANIFEST")"
    if ((count > 0)); then
        proxy_relay_forward_apply || { rc=$?; rm -rf -- "$tmp"; return "$rc"; }
        _proxy_relay_forward_service_action enable-now || { rm -rf -- "$tmp"; return 20; }
    fi
    rm -rf -- "$tmp"
    vps_cmd_success "relay forward 服务组件已安装"
)

proxy_relay_forward_remove_service() {
    proxy_relay_forward_init || return $?
    vps_cmd_require_root || return $?
    _proxy_relay_forward_require_safe_paths || return $?
    _proxy_relay_forward_require_managed_targets || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：停止 relay forward，删除受管 helper、服务与 sysctl 文件"
        return 0
    fi
    _proxy_relay_forward_service_action disable-now || return 20
    proxy_relay_forward_nft_clear || return 20
    rm -f -- "$PROXY_RELAY_FORWARD_HELPER" "$PROXY_RELAY_FORWARD_SERVICE" "$PROXY_RELAY_FORWARD_SYSCTL" || return 20
    _proxy_relay_forward_service_action reload-manager || return 20
}

proxy_relay_forward_on_count_change() {
    local old_count="${1:-}" new_count="${2:-}"
    [[ "$old_count" =~ ^[0-9]+$ && "$new_count" =~ ^[0-9]+$ ]] || return 2
    proxy_relay_forward_init || return $?
    vps_cmd_require_root || return $?
    if ((old_count == 0 && new_count > 0)); then
        proxy_relay_forward_install_service
    elif ((old_count > 0 && new_count == 0)); then
        if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
            vps_cmd_info "演练：最后一条 relay forward 已删除，停止并禁用服务"
            return 0
        fi
        _proxy_relay_forward_service_action disable-now || return 20
        proxy_relay_forward_nft_clear
    elif ((new_count > 0)); then
        proxy_relay_forward_apply
    fi
}

proxy_relay_forward_sync() {
    local count
    proxy_relay_forward_init || return $?
    vps_cmd_require_root || return $?
    proxy_ensure_tools relay-forward-sync jq || return $?
    [[ -f "$PROXY_RELAY_FORWARD_MANIFEST" && ! -L "$PROXY_RELAY_FORWARD_MANIFEST" ]] || return 0
    count="$(jq -r '.forwards | length' "$PROXY_RELAY_FORWARD_MANIFEST")" || return 10
    if ((count == 0)); then
        if [[ -e "$PROXY_RELAY_FORWARD_SERVICE" ]]; then
            if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
                vps_cmd_info "演练：最后一条 relay forward 已删除，停止并禁用服务"
                return 0
            fi
            _proxy_relay_forward_service_action disable-now || return 20
            proxy_relay_forward_clear || return $?
            rm -f -- "$PROXY_RELAY_FORWARD_CACHE" || return 20
            return 0
        fi
        # Binding-only relay changes must not pull nftables into a system that
        # has never configured a port forward.
        [[ -e "$PROXY_RELAY_FORWARD_CACHE" ]] || return 0
        command -v nft >/dev/null 2>&1 || return 0
        proxy_relay_forward_clear || return $?
        rm -f -- "$PROXY_RELAY_FORWARD_CACHE" || return 20
        return 0
    fi
    if [[ ! -e "$PROXY_RELAY_FORWARD_SERVICE" || ! -e "$PROXY_RELAY_FORWARD_HELPER" || ! -e "$PROXY_RELAY_FORWARD_SYSCTL" ]]; then
        proxy_relay_forward_install_service
    else
        proxy_relay_forward_install_runtime || return $?
        proxy_relay_forward_apply || return $?
        [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]] && return 0
        if ! _proxy_relay_forward_runtime_active || ! _proxy_relay_forward_runtime_enabled; then
            _proxy_relay_forward_service_action enable-now || return 20
        fi
    fi
}
