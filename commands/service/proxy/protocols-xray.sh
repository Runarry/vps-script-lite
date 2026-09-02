# shellcheck shell=bash
# Private Xray protocol helpers for commands/service/proxy.sh.
# Sourcing this file only defines functions.

proxy_xray_profiles() {
    cat <<'EOF'
vless-reality-vision	VLESS + REALITY + XTLS Vision
vless-grpc-reality	VLESS + gRPC + REALITY
trojan-xhttp-reality	Trojan + XHTTP + REALITY
trojan-grpc-reality	Trojan + gRPC + REALITY
vless-xhttp-tls	VLESS + XHTTP + TLS
vless-grpc-tls	VLESS + gRPC + TLS
trojan-grpc-tls	Trojan + gRPC + TLS
shadowsocks-aes-256-gcm	Shadowsocks AES-256-GCM
shadowsocks-chacha20-poly1305	Shadowsocks ChaCha20-Poly1305
shadowsocks-2022	Shadowsocks 2022
shadowsocks-2022-padding	Shadowsocks 2022 Padding
EOF
}

proxy_xray_supports_profile() {
    case "${1:-}" in
        vless-reality-vision | vless-grpc-reality | trojan-xhttp-reality | trojan-grpc-reality | \
            vless-xhttp-tls | vless-grpc-tls | trojan-grpc-tls | \
            shadowsocks-aes-256-gcm | shadowsocks-chacha20-poly1305 | \
            shadowsocks-2022 | shadowsocks-2022-padding) return 0 ;;
        *) return 1 ;;
    esac
}

proxy_xray_profile_label() {
    local wanted="${1:-}" id label
    while IFS=$'\t' read -r id label; do
        if [[ "$id" == "$wanted" ]]; then
            printf '%s' "$label"
            return 0
        fi
    done < <(proxy_xray_profiles)
    return 2
}

proxy_xray_validate_node() {
    local node_json="${1:-}" profile="unknown"
    command -v jq >/dev/null 2>&1 || {
        printf 'Xray 节点校验需要 jq。\n' >&2
        return 10
    }

    profile="$(jq -r 'if type == "object" then (.profile // "unknown") else "unknown" end' \
        <<<"$node_json" 2>/dev/null)" || profile="unknown"
    if ! jq -e '
        def nonempty: type == "string" and length > 0;
        def common:
            type == "object" and
            (.id | nonempty) and
            .core == "xray" and
            (.profile | nonempty) and
            (.name | nonempty) and
            (.listen | nonempty) and
            ((.port | type) == "number" and (.port | floor) == .port and .port >= 1 and .port <= 65535) and
            (.address | nonempty) and
            ((.credentials | type) == "object") and
            ((.tls | type) == "object") and
            ((.transport | type) == "object") and
            ((.options | type) == "object");
        def uuid: .credentials.uuid | nonempty;
        def password: .credentials.password | nonempty;
        def reality:
            .tls.enabled == true and .tls.mode == "reality" and
            (.tls.server_name | nonempty) and
            (.credentials.private_key | nonempty) and
            (.credentials.public_key | nonempty) and
            (.credentials.short_id | nonempty);
        def certificate_tls:
            .tls.enabled == true and
            (.tls.mode == "self-signed" or .tls.mode == "imported" or .tls.mode == "managed") and
            (.tls.server_name | nonempty) and
            (.tls.certificate_path | nonempty) and
            (.tls.key_path | nonempty) and
            ((.tls.insecure | type) == "boolean") and
            (((.tls.certificate_sha256 // "") | type) == "string") and
            (if .tls.mode == "managed" then
                ((.tls.certificate_id // "") | test("^crt-[0-9a-f]{16}$"))
             else true end);
        common and
        if .profile == "vless-reality-vision" then
            uuid and reality and .transport.type == "tcp" and
            .transport.flow == "xtls-rprx-vision"
        elif .profile == "vless-grpc-reality" then
            uuid and reality and .transport.type == "grpc" and
            (.transport.service_name | nonempty)
        elif .profile == "trojan-xhttp-reality" then
            password and reality and .transport.type == "xhttp" and
            ((.transport.path | type) == "string" and (.transport.path | startswith("/")))
        elif .profile == "trojan-grpc-reality" then
            password and reality and .transport.type == "grpc" and
            (.transport.service_name | nonempty)
        elif .profile == "vless-xhttp-tls" then
            uuid and certificate_tls and .transport.type == "xhttp" and
            ((.transport.path | type) == "string" and (.transport.path | startswith("/")))
        elif .profile == "vless-grpc-tls" then
            uuid and certificate_tls and .transport.type == "grpc" and
            (.transport.service_name | nonempty)
        elif .profile == "trojan-grpc-tls" then
            password and certificate_tls and .transport.type == "grpc" and
            (.transport.service_name | nonempty)
        elif .profile == "shadowsocks-aes-256-gcm" then
            password and .options.method == "aes-256-gcm" and .options.padding == false
        elif .profile == "shadowsocks-chacha20-poly1305" then
            password and .options.method == "chacha20-ietf-poly1305" and .options.padding == false
        elif .profile == "shadowsocks-2022" then
            password and .options.method == "2022-blake3-aes-256-gcm" and .options.padding == false
        elif .profile == "shadowsocks-2022-padding" then
            password and .options.method == "2022-blake3-aes-256-gcm" and .options.padding == true
        else false
        end
    ' <<<"$node_json" >/dev/null 2>&1; then
        printf 'Xray 节点字段校验失败（profile=%s）。\n' "$profile" >&2
        return 10
    fi
}

proxy_xray_render_node() {
    local node_json="${1:-}"
    proxy_xray_validate_node "$node_json" || return $?

    jq -cn --argjson node "$node_json" '
        def reality_stream($network; $extra): {
            network: $network,
            security: "reality",
            realitySettings: {
                show: false,
                dest: ($node.tls.server_name + ":443"),
                xver: 0,
                serverNames: [$node.tls.server_name],
                privateKey: $node.credentials.private_key,
                shortIds: [$node.credentials.short_id]
            }
        } + $extra;
        def tls_settings: {
            certificates: [{
                certificateFile: $node.tls.certificate_path,
                keyFile: $node.tls.key_path
            }],
            alpn: ["h2"]
        };
        def vless($stream; $flow): [{
            tag: $node.id,
            listen: $node.listen,
            port: $node.port,
            protocol: "vless",
            settings: {
                clients: [{id: $node.credentials.uuid, flow: $flow}],
                decryption: "none"
            },
            streamSettings: $stream
        }];
        def trojan($stream): [{
            tag: $node.id,
            listen: $node.listen,
            port: $node.port,
            protocol: "trojan",
            settings: {clients: [{password: $node.credentials.password}]},
            streamSettings: $stream
        }];
        if $node.profile == "vless-reality-vision" then
            vless(reality_stream("tcp"; {}); $node.transport.flow)
        elif $node.profile == "vless-grpc-reality" then
            vless(reality_stream("grpc"; {
                grpcSettings: {serviceName: $node.transport.service_name}
            }); "")
        elif $node.profile == "trojan-xhttp-reality" then
            trojan(reality_stream("xhttp"; {
                xhttpSettings: {path: $node.transport.path}
            }))
        elif $node.profile == "trojan-grpc-reality" then
            trojan(reality_stream("grpc"; {
                grpcSettings: {serviceName: $node.transport.service_name}
            }))
        elif $node.profile == "vless-xhttp-tls" then
            vless({
                network: "xhttp",
                security: "tls",
                tlsSettings: tls_settings,
                xhttpSettings: {
                    mode: "stream-one",
                    host: $node.tls.server_name,
                    path: $node.transport.path
                }
            }; "")
        elif $node.profile == "vless-grpc-tls" then
            vless({
                network: "grpc",
                security: "tls",
                tlsSettings: tls_settings,
                grpcSettings: {serviceName: $node.transport.service_name}
            }; "")
        elif $node.profile == "trojan-grpc-tls" then
            trojan({
                network: "grpc",
                security: "tls",
                tlsSettings: tls_settings,
                grpcSettings: {serviceName: $node.transport.service_name}
            })
        else [{
            tag: $node.id,
            listen: $node.listen,
            port: $node.port,
            protocol: "shadowsocks",
            settings: {
                method: $node.options.method,
                password: $node.credentials.password,
                network: "tcp,udp"
            }
        }]
        end
    ' || return 10
}

_proxy_xray_urlencode() {
    jq -nr --arg value "${1:-}" '$value | @uri'
}

_proxy_xray_ss_userinfo() {
    jq -nr --arg value "${1:-}" '$value | @base64 | gsub("=+$"; "")'
}

_proxy_xray_query_add() {
    local current="$1" key="$2" value="$3" encoded
    encoded="$(_proxy_xray_urlencode "$value")" || return 10
    printf '%s%s%s=%s' "$current" "${current:+&}" "$key" "$encoded"
}

proxy_xray_render_uri() {
    local node_json="${1:-}" profile address host port name fragment query="" scheme userinfo
    local uuid password public_key short_id sni transport path service_name flow
    local method insecure certificate_sha256
    proxy_xray_validate_node "$node_json" || return $?

    profile="$(jq -r '.profile' <<<"$node_json")" || return 10
    address="$(jq -r '.address' <<<"$node_json")" || return 10
    port="$(jq -r '.port' <<<"$node_json")" || return 10
    name="$(jq -r '.name' <<<"$node_json")" || return 10
    fragment="$(_proxy_xray_urlencode "$name")" || return 10
    if [[ "$address" == *:* && "$address" != \[*\] ]]; then
        host="[$address]"
    else
        host="$address"
    fi

    case "$profile" in
        shadowsocks-*)
            method="$(jq -r '.options.method' <<<"$node_json")" || return 10
            password="$(jq -r '.credentials.password' <<<"$node_json")" || return 10
            userinfo="$(_proxy_xray_ss_userinfo "${method}:${password}")" || return 10
            printf 'ss://%s@%s:%s#%s\n' "$userinfo" "$host" "$port" "$fragment"
            return 0
            ;;
        vless-*)
            scheme="vless"
            uuid="$(jq -r '.credentials.uuid' <<<"$node_json")" || return 10
            userinfo="$(_proxy_xray_urlencode "$uuid")" || return 10
            ;;
        trojan-*)
            scheme="trojan"
            password="$(jq -r '.credentials.password' <<<"$node_json")" || return 10
            userinfo="$(_proxy_xray_urlencode "$password")" || return 10
            ;;
        *) return 2 ;;
    esac

    sni="$(jq -r '.tls.server_name' <<<"$node_json")" || return 10
    transport="$(jq -r '.transport.type' <<<"$node_json")" || return 10
    if [[ "$profile" == *-reality || "$profile" == "vless-reality-vision" ]]; then
        public_key="$(jq -r '.credentials.public_key' <<<"$node_json")" || return 10
        short_id="$(jq -r '.credentials.short_id' <<<"$node_json")" || return 10
        query="$(_proxy_xray_query_add "$query" security reality)" || return 10
        [[ "$scheme" != "vless" ]] || query="$(_proxy_xray_query_add "$query" encryption none)" || return 10
        query="$(_proxy_xray_query_add "$query" pbk "$public_key")" || return 10
        query="$(_proxy_xray_query_add "$query" fp chrome)" || return 10
        query="$(_proxy_xray_query_add "$query" type "$transport")" || return 10
        if [[ "$profile" == "vless-reality-vision" ]]; then
            flow="$(jq -r '.transport.flow' <<<"$node_json")" || return 10
            query="$(_proxy_xray_query_add "$query" flow "$flow")" || return 10
        elif [[ "$transport" == "grpc" ]]; then
            service_name="$(jq -r '.transport.service_name' <<<"$node_json")" || return 10
            query="$(_proxy_xray_query_add "$query" serviceName "$service_name")" || return 10
            query="$(_proxy_xray_query_add "$query" authority "$sni")" || return 10
        else
            path="$(jq -r '.transport.path' <<<"$node_json")" || return 10
            query="$(_proxy_xray_query_add "$query" path "$path")" || return 10
        fi
        query="$(_proxy_xray_query_add "$query" sni "$sni")" || return 10
        query="$(_proxy_xray_query_add "$query" sid "$short_id")" || return 10
    else
        query="$(_proxy_xray_query_add "$query" security tls)" || return 10
        [[ "$scheme" != "vless" ]] || query="$(_proxy_xray_query_add "$query" encryption none)" || return 10
        query="$(_proxy_xray_query_add "$query" sni "$sni")" || return 10
        query="$(_proxy_xray_query_add "$query" type "$transport")" || return 10
        if [[ "$transport" == "grpc" ]]; then
            service_name="$(jq -r '.transport.service_name' <<<"$node_json")" || return 10
            query="$(_proxy_xray_query_add "$query" serviceName "$service_name")" || return 10
            query="$(_proxy_xray_query_add "$query" authority "$sni")" || return 10
        else
            path="$(jq -r '.transport.path' <<<"$node_json")" || return 10
            query="$(_proxy_xray_query_add "$query" alpn h2)" || return 10
            query="$(_proxy_xray_query_add "$query" mode stream-one)" || return 10
            query="$(_proxy_xray_query_add "$query" path "$path")" || return 10
            query="$(_proxy_xray_query_add "$query" host "$sni")" || return 10
        fi
        insecure="$(jq -r '.tls.insecure' <<<"$node_json")" || return 10
        certificate_sha256="$(jq -r '.tls.certificate_sha256 // ""' <<<"$node_json")" || return 10
        if [[ "$insecure" == "true" ]]; then
            query="$(_proxy_xray_query_add "$query" insecure 1)" || return 10
        fi
        if [[ -n "$certificate_sha256" ]]; then
            query="$(_proxy_xray_query_add "$query" pcs "$certificate_sha256")" || return 10
        fi
    fi

    printf '%s://%s@%s:%s?%s#%s\n' "$scheme" "$userinfo" "$host" "$port" "$query" "$fragment"
}
