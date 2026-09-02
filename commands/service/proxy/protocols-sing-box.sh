# shellcheck shell=bash
# shellcheck disable=SC2016
# Private sing-box protocol mappings for commands/service/proxy.sh.
# Sourcing this file only defines functions.

proxy_sb_profiles() {
    cat <<'EOF'
vless-reality-vision	VLESS + REALITY + XTLS Vision
vless-ws-tls	VLESS + WebSocket + TLS
trojan-ws-tls	Trojan + WebSocket + TLS
vless-grpc-tls	VLESS + gRPC + TLS
anytls-tls	AnyTLS + TLS
anytls-reality	AnyTLS + REALITY
hysteria2	Hysteria2
tuic-v5	TUIC v5
shadowsocks-aes-256-gcm	Shadowsocks AES-256-GCM
shadowsocks-chacha20-poly1305	Shadowsocks ChaCha20-Poly1305
shadowsocks-2022	Shadowsocks 2022
shadowsocks-2022-padding	Shadowsocks 2022 Padding
shadowsocks-2022-shadowtls	Shadowsocks 2022 + ShadowTLS
vless-tcp	VLESS + TCP
socks5	SOCKS5
EOF
}

proxy_sb_supports_profile() {
    case "${1:-}" in
        vless-reality-vision | vless-ws-tls | trojan-ws-tls | vless-grpc-tls | \
            anytls-tls | anytls-reality | hysteria2 | tuic-v5 | \
            shadowsocks-aes-256-gcm | shadowsocks-chacha20-poly1305 | \
            shadowsocks-2022 | shadowsocks-2022-padding | \
            shadowsocks-2022-shadowtls | vless-tcp | socks5) return 0 ;;
        *) return 1 ;;
    esac
}

proxy_sb_profile_label() {
    local wanted="${1:-}" id label
    while IFS=$'\t' read -r id label; do
        if [[ "$id" == "$wanted" ]]; then
            printf '%s' "$label"
            return 0
        fi
    done < <(proxy_sb_profiles)
    return 2
}

proxy_sb_validate_node() {
    local node="${1:-}" profile=""
    profile="$(jq -r 'if type == "object" then .profile // "" else "" end' <<<"$node" 2>/dev/null)" || profile=""
    if ! proxy_sb_supports_profile "$profile"; then
        printf 'sing-box 不支持节点配置：%s\n' "${profile:-<缺失>}" >&2
        return 10
    fi

    jq -e --arg profile "$profile" '
        def text: type == "string" and length > 0;
        def boolean: type == "boolean";
        def base:
            type == "object" and
            (.id | text) and .core == "sing-box" and .profile == $profile and
            (.name | text) and (.listen | text) and
            ((.port | type) == "number" and (.port | floor) == .port and .port >= 1 and .port <= 65535) and
            (.address | text) and ((.credentials | type) == "object") and
            ((.tls | type) == "object") and ((.transport | type) == "object") and
            ((.options | type) == "object");
        def credential($key): .credentials[$key] | text;
        def uuid: credential("uuid");
        def password: credential("password");
        def tls_common:
            .tls.enabled == true and
            (.tls.mode == "self-signed" or .tls.mode == "imported" or .tls.mode == "managed") and
            (.tls.server_name | text) and
            (.tls.certificate_path | text) and (.tls.key_path | text) and
            (.tls.insecure | boolean) and
            ((.tls.certificate_sha256 | type) == "string" and (.tls.certificate_sha256 | test("^[A-Fa-f0-9]{64}$"))) and
            (if .tls.mode == "managed" then
                ((.tls.certificate_id // "") | test("^crt-[0-9a-f]{16}$"))
             else true end);
        def reality:
            .tls.enabled == true and .tls.mode == "reality" and
            (.tls.server_name | text) and credential("private_key") and
            credential("public_key") and credential("short_id");
        def ws: .transport.type == "ws" and (.transport.path | text) and (.transport.path | startswith("/"));
        def grpc: .transport.type == "grpc" and (.transport.service_name | text);
        base and
        if $profile == "vless-reality-vision" then
            uuid and reality and .transport.type == "tcp" and .transport.flow == "xtls-rprx-vision"
        elif $profile == "vless-ws-tls" then uuid and tls_common and ws
        elif $profile == "trojan-ws-tls" then password and tls_common and ws
        elif $profile == "vless-grpc-tls" then uuid and tls_common and grpc
        elif $profile == "anytls-tls" then password and tls_common
        elif $profile == "anytls-reality" then password and reality
        elif $profile == "hysteria2" then
            password and tls_common and
            (.options.obfs_type == "none" or
             (.options.obfs_type == "salamander" and (.options.obfs_password | text))) and
            ((.options.up_mbps | type) == "number" and (.options.up_mbps | floor) == .options.up_mbps and .options.up_mbps > 0) and
            ((.options.down_mbps | type) == "number" and (.options.down_mbps | floor) == .options.down_mbps and .options.down_mbps > 0)
        elif $profile == "tuic-v5" then
            uuid and password and tls_common and
            (.options.congestion_control == "bbr" or
             .options.congestion_control == "cubic" or
             .options.congestion_control == "new_reno")
        elif $profile == "shadowsocks-aes-256-gcm" then
            password and .options.method == "aes-256-gcm"
        elif $profile == "shadowsocks-chacha20-poly1305" then
            password and .options.method == "chacha20-ietf-poly1305"
        elif $profile == "shadowsocks-2022" then
            password and .options.method == "2022-blake3-aes-256-gcm" and .options.padding == false and .options.shadowtls == false
        elif $profile == "shadowsocks-2022-padding" then
            password and .options.method == "2022-blake3-aes-256-gcm" and .options.padding == true
        elif $profile == "shadowsocks-2022-shadowtls" then
            password and credential("shadowtls_password") and
            .options.method == "2022-blake3-aes-256-gcm" and .options.shadowtls == true and
            (.tls.server_name | text)
        elif $profile == "vless-tcp" then uuid and .transport.type == "tcp"
        elif $profile == "socks5" then credential("username") and password
        else false
        end
    ' <<<"$node" >/dev/null 2>&1 || {
        printf 'sing-box 节点 %s（%s）的字段校验失败。\n' "$(jq -r '.id // "<未知>"' <<<"$node" 2>/dev/null || printf '<未知>')" "$profile" >&2
        return 10
    }
}

proxy_sb_render_node() {
    local node="${1:-}" profile
    proxy_sb_validate_node "$node" || return $?
    profile="$(jq -r '.profile' <<<"$node")" || return 10

    case "$profile" in
        vless-reality-vision)
            jq -n --argjson n "$node" '[{
                type:"vless", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                users:[{uuid:$n.credentials.uuid, flow:$n.transport.flow}],
                tls:{enabled:true, server_name:$n.tls.server_name, reality:{
                    enabled:true,
                    handshake:{server:$n.tls.server_name, server_port:443},
                    private_key:$n.credentials.private_key,
                    short_id:[$n.credentials.short_id]
                }}
            }]'
            ;;
        vless-ws-tls)
            jq -n --argjson n "$node" '[{
                type:"vless", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                users:[{uuid:$n.credentials.uuid, flow:""}],
                tls:{enabled:true, server_name:$n.tls.server_name,
                     certificate_path:$n.tls.certificate_path, key_path:$n.tls.key_path},
                transport:{type:"ws", path:$n.transport.path}
            }]'
            ;;
        trojan-ws-tls)
            jq -n --argjson n "$node" '[{
                type:"trojan", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                users:[{password:$n.credentials.password}],
                tls:{enabled:true, server_name:$n.tls.server_name,
                     certificate_path:$n.tls.certificate_path, key_path:$n.tls.key_path},
                transport:{type:"ws", path:$n.transport.path}
            }]'
            ;;
        vless-grpc-tls)
            jq -n --argjson n "$node" '[{
                type:"vless", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                users:[{uuid:$n.credentials.uuid, flow:""}],
                tls:{enabled:true, server_name:$n.tls.server_name, alpn:["h2"],
                     certificate_path:$n.tls.certificate_path, key_path:$n.tls.key_path},
                transport:{type:"grpc", service_name:$n.transport.service_name}
            }]'
            ;;
        anytls-tls)
            jq -n --argjson n "$node" '[{
                type:"anytls", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                users:[{name:"default", password:$n.credentials.password}],
                padding_scheme:["stop=2", "0=100-200", "1=100-200"],
                tls:{enabled:true, server_name:$n.tls.server_name, alpn:["http/1.1"],
                     certificate_path:$n.tls.certificate_path, key_path:$n.tls.key_path}
            }]'
            ;;
        anytls-reality)
            jq -n --argjson n "$node" '[{
                type:"anytls", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                users:[{name:"default", password:$n.credentials.password}], padding_scheme:[],
                tls:{enabled:true, server_name:$n.tls.server_name, reality:{
                    enabled:true,
                    handshake:{server:$n.tls.server_name, server_port:443},
                    private_key:$n.credentials.private_key,
                    short_id:[$n.credentials.short_id]
                }}
            }]'
            ;;
        hysteria2)
            jq -n --argjson n "$node" '[{
                type:"hysteria2", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                up_mbps:$n.options.up_mbps, down_mbps:$n.options.down_mbps,
                users:[{password:$n.credentials.password}],
                tls:{enabled:true, alpn:["h3"],
                     certificate_path:$n.tls.certificate_path, key_path:$n.tls.key_path}
            } | if $n.options.obfs_type == "salamander" then
                .obfs={type:"salamander", password:$n.options.obfs_password}
            else . end]'
            ;;
        tuic-v5)
            jq -n --argjson n "$node" '[{
                type:"tuic", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                users:[{uuid:$n.credentials.uuid, password:$n.credentials.password}],
                congestion_control:$n.options.congestion_control,
                tls:{enabled:true, alpn:["h3"],
                     certificate_path:$n.tls.certificate_path, key_path:$n.tls.key_path}
            }]'
            ;;
        shadowsocks-2022-shadowtls)
            jq -n --argjson n "$node" '[
                {
                    type:"shadowtls", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                    version:3, users:[{password:$n.credentials.shadowtls_password}],
                    handshake:{server:$n.tls.server_name, server_port:443},
                    detour:($n.id + "-ss")
                },
                {
                    type:"shadowsocks", tag:($n.id + "-ss"),
                    method:$n.options.method, password:$n.credentials.password
                }
            ]'
            ;;
        shadowsocks-2022-padding)
            jq -n --argjson n "$node" '[{
                type:"shadowsocks", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                method:$n.options.method, password:$n.credentials.password,
                multiplex:{enabled:true, padding:true}
            }]'
            ;;
        shadowsocks-aes-256-gcm | shadowsocks-chacha20-poly1305 | shadowsocks-2022)
            jq -n --argjson n "$node" '[{
                type:"shadowsocks", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                method:$n.options.method, password:$n.credentials.password
            }]'
            ;;
        vless-tcp)
            jq -n --argjson n "$node" '[{
                type:"vless", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                users:[{uuid:$n.credentials.uuid, flow:""}], tls:{enabled:false}
            }]'
            ;;
        socks5)
            jq -n --argjson n "$node" '[{
                type:"socks", tag:$n.id, listen:($n.listen // "::"), listen_port:$n.port,
                users:[{username:$n.credentials.username, password:$n.credentials.password}]
            }]'
            ;;
        *) return 2 ;;
    esac
}

proxy_sb_render_uri() {
    local node="${1:-}"
    proxy_sb_validate_node "$node" || return $?
    jq -r '
        def enc: tostring | @uri;
        def host:
            if ((.address | startswith("[")) and (.address | endswith("]"))) then .address
            elif (.address | contains(":")) then "[" + .address + "]"
            else .address end;
        def endpoint: host + ":" + (.port | tostring);
        def query($items): $items | map(.[0] + "=" + (.[1] | enc)) | join("&");
        def tls_extra:
            (if .tls.insecure then [["insecure", "1"]] else [] end) +
            (if .tls.certificate_sha256 != "" then [["pcs", .tls.certificate_sha256]] else [] end);
        def ss_userinfo:
            (.options.method + ":" + .credentials.password) | @base64 |
            gsub("="; "") | gsub("\\+"; "-") | gsub("/"; "_");
        if .profile == "vless-reality-vision" then
            "vless://" + (.credentials.uuid | enc) + "@" + endpoint + "?" + query([
                ["security", "reality"], ["encryption", "none"], ["pbk", .credentials.public_key],
                ["fp", "chrome"], ["type", "tcp"], ["flow", .transport.flow],
                ["sni", .tls.server_name], ["sid", .credentials.short_id]
            ]) + "#" + (.name | enc)
        elif .profile == "vless-ws-tls" then
            "vless://" + (.credentials.uuid | enc) + "@" + endpoint + "?" + query(([
                ["security", "tls"], ["encryption", "none"], ["type", "ws"],
                ["host", .tls.server_name], ["path", .transport.path], ["sni", .tls.server_name]
            ] + tls_extra)) + "#" + (.name | enc)
        elif .profile == "trojan-ws-tls" then
            "trojan://" + (.credentials.password | enc) + "@" + endpoint + "?" + query(([
                ["security", "tls"], ["type", "ws"], ["host", .tls.server_name],
                ["path", .transport.path], ["sni", .tls.server_name]
            ] + tls_extra)) + "#" + (.name | enc)
        elif .profile == "vless-grpc-tls" then
            "vless://" + (.credentials.uuid | enc) + "@" + endpoint + "?" + query(([
                ["security", "tls"], ["encryption", "none"], ["type", "grpc"],
                ["serviceName", .transport.service_name], ["authority", .tls.server_name],
                ["sni", .tls.server_name]
            ] + tls_extra)) + "#" + (.name | enc)
        elif .profile == "anytls-tls" then
            "anytls://" + (.credentials.password | enc) + "@" + endpoint + "?" + query(([
                ["security", "tls"], ["sni", .tls.server_name], ["type", "tcp"]
            ] + tls_extra)) + "#" + (.name | enc)
        elif .profile == "anytls-reality" then
            "anytls://" + (.credentials.password | enc) + "@" + endpoint + "?" + query([
                ["security", "reality"], ["sni", .tls.server_name], ["fp", "chrome"],
                ["pbk", .credentials.public_key], ["sid", .credentials.short_id],
                ["type", "tcp"], ["headerType", "none"]
            ]) + "#" + (.name | enc)
        elif .profile == "hysteria2" then
            "hysteria2://" + (.credentials.password | enc) + "@" + endpoint + "?" + query(([
                ["sni", .tls.server_name]
            ] + (if .tls.insecure then [["insecure", "1"]] else [] end) +
                (if .options.obfs_type == "salamander" then
                    [["obfs", "salamander"], ["obfs-password", .options.obfs_password]] else [] end) +
                (if .tls.certificate_sha256 != "" then
                    [["pinSHA256", .tls.certificate_sha256]] else [] end))) + "#" + (.name | enc)
        elif .profile == "tuic-v5" then
            "tuic://" + (.credentials.uuid | enc) + ":" + (.credentials.password | enc) + "@" + endpoint + "?" + query(([
                ["sni", .tls.server_name], ["alpn", "h3"],
                ["congestion_control", .options.congestion_control],
                ["udp_relay_mode", "native"]
            ] + (if .tls.insecure then [["allow_insecure", "1"]] else [] end) +
                (if .tls.certificate_sha256 != "" then
                    [["pinSHA256", .tls.certificate_sha256]] else [] end))) + "#" + (.name | enc)
        elif (.profile | startswith("shadowsocks-")) then
            "ss://" + ss_userinfo + "@" + endpoint +
            (if .profile == "shadowsocks-2022-shadowtls" then
                "?" + query([["plugin", "shadow-tls;version=3;host=" + .tls.server_name +
                    ";password=" + .credentials.shadowtls_password]])
             else "" end) + "#" + (.name | enc)
        elif .profile == "vless-tcp" then
            "vless://" + (.credentials.uuid | enc) + "@" + endpoint + "?" + query([
                ["encryption", "none"], ["type", "tcp"]
            ]) + "#" + (.name | enc)
        elif .profile == "socks5" then
            "socks5://" + (.credentials.username | enc) + ":" + (.credentials.password | enc) +
            "@" + endpoint + "#" + (.name | enc)
        else error("unsupported sing-box profile") end
    ' <<<"$node"
}
