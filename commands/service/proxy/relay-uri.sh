# shellcheck shell=bash
# Private protocol-exit URI helpers. Sourcing this file only defines functions.
#
# Public contract:
#   proxy_relay_uri_parse URI [PROFILE]
#       Print a schema_version=1 neutral JSON object. PROFILE is optional, but is
#       required to select shadowsocks-2022-padding because SIP002 has no padding
#       flag. Returns 2 for bad arguments and 10 for a malformed/unsupported URI.
#   proxy_relay_render_outbound CORE EXIT_JSON
#       Validate a protocol exit object and print {outbounds:[...],target_tag:"..."}
#       for sing-box or Xray. EXIT_JSON.id is used to derive all outbound tags.
#   proxy_relay_uri_rewrite URI HOST PORT
#       Validate URI and the replacement endpoint, then print a URI whose host and
#       port alone are changed. SIP002 and legacy whole-payload Base64 SS forms are
#       both supported. Returns 2 for bad arguments and 10 for invalid input.
#
# Errors are deliberately generic: none of the public functions writes URI,
# credentials, or decoded userinfo to stderr.

_proxy_relay_uri_error() {
    printf 'protocol exit URI: %s\n' "${1:-invalid input}" >&2
}

_proxy_relay_uri_no_control() {
    local value="${1-}"
    jq -ne --arg value "$value" '$value | test("[\u0000-\u001f\u007f]") | not' >/dev/null 2>&1
}

_proxy_relay_uri_decode() {
    local encoded="${1-}" decoded="" byte hex restored
    while [[ -n "$encoded" ]]; do
        byte="${encoded:0:1}"
        if [[ "$byte" == '%' ]]; then
            ((${#encoded} >= 3)) || return 10
            hex="${encoded:1:2}"
            [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ && "$hex" != '00' ]] || return 10
            printf -v byte '%b' "\\x$hex" || return 10
            decoded+="$byte"
            encoded="${encoded:3}"
        else
            decoded+="$byte"
            encoded="${encoded:1}"
        fi
    done
    _proxy_relay_uri_no_control "$decoded" || return 10
    restored="$(jq -nr --arg value "$decoded" '$value' 2>/dev/null)" || return 10
    [[ "$restored" == "$decoded" ]] || return 10
    printf '%s' "$decoded"
}

_proxy_relay_uri_encode() {
    jq -nr --arg value "${1-}" '$value | @uri' 2>/dev/null
}

_proxy_relay_b64_decode() {
    local encoded="${1-}" normalized decoded restored reencoded
    [[ -n "$encoded" && "$encoded" =~ ^[-A-Za-z0-9_+/]+={0,2}$ ]] || return 10
    normalized="${encoded//-/+}"
    normalized="${normalized//_/\/}"
    normalized="${normalized%%=*}"
    case $((${#normalized} % 4)) in
        0) ;;
        2) normalized+='==' ;;
        3) normalized+='=' ;;
        *) return 10 ;;
    esac
    decoded="$(printf '%s' "$normalized" | base64 -d 2>/dev/null)" || return 10
    [[ -n "$decoded" ]] || return 10
    reencoded="$(printf '%s' "$decoded" | base64 | tr -d '\r\n')" || return 10
    [[ "$reencoded" == "$normalized" ]] || return 10
    _proxy_relay_uri_no_control "$decoded" || return 10
    restored="$(jq -nr --arg value "$decoded" '$value' 2>/dev/null)" || return 10
    [[ "$restored" == "$decoded" ]] || return 10
    printf '%s' "$decoded"
}

_proxy_relay_b64_encode_like() {
    local value="${1-}" example="${2-}" encoded
    encoded="$(printf '%s' "$value" | base64 | tr -d '\r\n')" || return 10
    if [[ "$example" == *[-_]* ]]; then
        encoded="${encoded//+/-}"
        encoded="${encoded//\//_}"
    fi
    [[ "$example" == *= ]] || encoded="${encoded%%=*}"
    printf '%s' "$encoded"
}

_proxy_relay_valid_ipv4() {
    local address="${1-}" part
    local -a parts=()
    IFS='.' read -r -a parts <<<"$address"
    ((${#parts[@]} == 4)) || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$part <= 255)) || return 1
    done
}

_proxy_relay_valid_ipv6() {
    local address="${1-}" left right item ipv4="" count=0
    local -a left_parts=() right_parts=()
    [[ "$address" =~ ^[0-9A-Fa-f:.]+$ && "$address" == *:* && "$address" != *:::* ]] || return 1
    if [[ "$address" == *.* ]]; then
        ipv4="${address##*:}"
        _proxy_relay_valid_ipv4 "$ipv4" || return 1
        address="${address%:*}:v4"
    fi
    if [[ "$address" == *::* ]]; then
        [[ "${address#*::}" != *::* ]] || return 1
        left="${address%%::*}"
        right="${address#*::}"
        [[ -z "$left" ]] || IFS=':' read -r -a left_parts <<<"$left"
        [[ -z "$right" ]] || IFS=':' read -r -a right_parts <<<"$right"
        count=$((${#left_parts[@]} + ${#right_parts[@]}))
        [[ -z "$ipv4" ]] || count=$((count + 1))
        ((count < 8)) || return 1
    else
        IFS=':' read -r -a left_parts <<<"$address"
        count=${#left_parts[@]}
        [[ -z "$ipv4" ]] || count=$((count + 1))
        ((count == 8)) || return 1
    fi
    for item in "${left_parts[@]}" "${right_parts[@]}"; do
        [[ -z "$item" || "$item" == v4 || "$item" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
}

_proxy_relay_valid_host() {
    local host="${1-}" label
    local -a labels=()
    [[ -n "$host" ]] && _proxy_relay_uri_no_control "$host" || return 1
    if [[ "$host" == *:* ]]; then
        _proxy_relay_valid_ipv6 "$host"
        return
    fi
    _proxy_relay_valid_ipv4 "$host" && return 0
    [[ ${#host} -le 253 && "$host" =~ ^[A-Za-z0-9._-]+$ && "$host" != .* && "$host" != *. && "$host" != *'..'* ]] || return 1
    IFS='.' read -r -a labels <<<"$host"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
    done
}

_proxy_relay_parse_authority() {
    local authority="${1-}" host port
    if [[ "$authority" == \[* ]]; then
        [[ "$authority" =~ ^\[([^][]+)\]:([0-9]+)$ ]] || return 10
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        _proxy_relay_valid_ipv6 "$host" || return 10
    else
        [[ "$authority" =~ ^([^:@/?#]+):([0-9]+)$ ]] || return 10
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        _proxy_relay_valid_host "$host" || return 10
    fi
    [[ "$port" =~ ^[0-9]+$ && ${#port} -le 5 ]] && ((10#$port >= 1 && 10#$port <= 65535)) || return 10
    printf '%s\t%d' "$host" "$((10#$port))"
}

_proxy_relay_format_authority() {
    local host="${1-}" port="${2-}"
    if [[ "$host" == *:* ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

_proxy_relay_query_json() {
    local query="${1-}" pair key value object='{}'
    local -a pairs=()
    [[ -n "$query" ]] || {
        printf '{}'
        return 0
    }
    IFS='&' read -r -a pairs <<<"$query"
    for pair in "${pairs[@]}"; do
        [[ -n "$pair" && "$pair" == *=* ]] || return 10
        key="$(_proxy_relay_uri_decode "${pair%%=*}")" || return 10
        value="$(_proxy_relay_uri_decode "${pair#*=}")" || return 10
        [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || return 10
        jq -e --arg key "$key" 'has($key) | not' <<<"$object" >/dev/null 2>&1 || return 10
        object="$(jq -c --arg key "$key" --arg value "$value" '. + {($key):$value}' <<<"$object" 2>/dev/null)" || return 10
    done
    printf '%s' "$object"
}

_proxy_relay_query_value() {
    jq -r --arg key "${2-}" '.[$key] // ""' <<<"${1-}" 2>/dev/null
}

_proxy_relay_query_keys_allowed() {
    local query_json="${1-}" allowed='|' key
    shift || return 10
    for key in "$@"; do allowed+="$key|"; done
    while IFS= read -r key; do
        if [[ "$allowed" != *"|$key|"* ]]; then
            _proxy_relay_uri_error "unsupported query parameter: ${key}"
            return 10
        fi
    done < <(jq -r 'keys[]' <<<"$query_json" 2>/dev/null) || return 10
}

_proxy_relay_bool_json() {
    case "${1-}" in
        '' | 0 | false) printf 'false' ;;
        1 | true) printf 'true' ;;
        *) return 10 ;;
    esac
}

_proxy_relay_profile_cores_json() {
    case "${1-}" in
        vless-reality-vision | vless-grpc-tls | shadowsocks-aes-256-gcm | \
            shadowsocks-chacha20-poly1305 | shadowsocks-2022 | shadowsocks-2022-padding)
            printf '["sing-box","xray"]'
            ;;
        vless-ws-tls | trojan-ws-tls | anytls-tls | anytls-reality | hysteria2 | tuic-v5 | \
            shadowsocks-2022-shadowtls | vless-tcp | socks5)
            printf '["sing-box"]'
            ;;
        vless-grpc-reality | trojan-xhttp-reality | trojan-grpc-reality | \
            vless-xhttp-tls | trojan-grpc-tls)
            printf '["xray"]'
            ;;
        *) return 10 ;;
    esac
}

_proxy_relay_parse_ss_plugin() {
    local plugin="${1-}" token key value version='' host='' password=''
    local -a tokens=()
    IFS=';' read -r -a tokens <<<"$plugin"
    [[ "${tokens[0]:-}" == shadow-tls || "${tokens[0]:-}" == shadowtls ]] || return 10
    unset 'tokens[0]'
    for token in "${tokens[@]}"; do
        [[ "$token" == *=* ]] || return 10
        key="${token%%=*}"
        value="${token#*=}"
        case "$key" in
            version) [[ -z "$version" ]] || return 10; version="$value" ;;
            host) [[ -z "$host" ]] || return 10; host="$value" ;;
            password) [[ -z "$password" ]] || return 10; password="$value" ;;
            *) return 10 ;;
        esac
    done
    [[ "$version" == 3 && -n "$password" ]] || return 10
    _proxy_relay_valid_host "$host" || return 10
    _proxy_relay_uri_no_control "$password" || return 10
    jq -cn --arg host "$host" --arg password "$password" '{host:$host,password:$password}' 2>/dev/null
}

proxy_relay_uri_parse() {
    local uri="${1-}" requested_profile="${2-}" scheme rest body query='' fragment='' name=''
    local userinfo authority endpoint host port query_json='{}' profile='' cores_json
    local security type encryption flow sni public_key short_id path service_name ws_host grpc_authority mode
    local username='' password='' uuid='' method='' plugin='' plugin_json='{}' shadowtls_password=''
    local tls_enabled='false' tls_mode='none' insecure='false' certificate_sha256='' alpn='[]'
    local transport='tcp' network_hint='tcp' padding='false' shadowtls='false' uri_format='standard'
    local obfs_type='none' obfs_password='' congestion_control='' udp_relay_mode=''
    local parse_valid='true' fp alpn_value header_type

    [[ $# -ge 1 && $# -le 2 && -n "$uri" ]] || {
        _proxy_relay_uri_error 'missing or extra argument'
        return 2
    }
    _proxy_relay_uri_no_control "$uri" || {
        _proxy_relay_uri_error 'control character rejected'
        return 10
    }
    [[ "$uri" =~ ^([A-Za-z][A-Za-z0-9+.-]*)://(.+)$ ]] || {
        _proxy_relay_uri_error 'malformed URI'
        return 10
    }
    scheme="${BASH_REMATCH[1],,}"
    rest="${BASH_REMATCH[2]}"
    case "$scheme" in
        vless | trojan | anytls | hysteria2 | hy2 | tuic | ss | socks5) ;;
        *) _proxy_relay_uri_error 'unsupported scheme'; return 10 ;;
    esac
    if [[ "$rest" == *'#'* ]]; then
        fragment="${rest#*#}"
        rest="${rest%%#*}"
        name="$(_proxy_relay_uri_decode "$fragment")" || {
            _proxy_relay_uri_error 'invalid fragment encoding'
            return 10
        }
    fi
    if [[ "$rest" == *'?'* ]]; then
        query="${rest#*\?}"
        body="${rest%%\?*}"
    else
        body="$rest"
    fi
    query_json="$(_proxy_relay_query_json "$query")" || {
        _proxy_relay_uri_error 'invalid query'
        return 10
    }

    if [[ "$scheme" == ss && "$body" != *@* ]]; then
        body="$(_proxy_relay_b64_decode "$body")" || {
            _proxy_relay_uri_error 'invalid legacy Shadowsocks payload'
            return 10
        }
        uri_format='legacy-base64'
    fi
    [[ "$body" == *@* ]] || {
        _proxy_relay_uri_error 'missing URI authority'
        return 10
    }
    authority="${body##*@}"
    userinfo="${body%"@$authority"}"
    [[ "$userinfo" != *@* && -n "$userinfo" ]] || {
        _proxy_relay_uri_error 'invalid userinfo'
        return 10
    }
    endpoint="$(_proxy_relay_parse_authority "$authority")" || {
        _proxy_relay_uri_error 'invalid host or port'
        return 10
    }
    IFS=$'\t' read -r host port <<<"$endpoint"

    security="$(_proxy_relay_query_value "$query_json" security)" || return 10
    type="$(_proxy_relay_query_value "$query_json" type)" || return 10
    encryption="$(_proxy_relay_query_value "$query_json" encryption)" || return 10
    flow="$(_proxy_relay_query_value "$query_json" flow)" || return 10
    sni="$(_proxy_relay_query_value "$query_json" sni)" || return 10
    public_key="$(_proxy_relay_query_value "$query_json" pbk)" || return 10
    short_id="$(_proxy_relay_query_value "$query_json" sid)" || return 10
    path="$(_proxy_relay_query_value "$query_json" path)" || return 10
    service_name="$(_proxy_relay_query_value "$query_json" serviceName)" || return 10
    ws_host="$(_proxy_relay_query_value "$query_json" host)" || return 10
    grpc_authority="$(_proxy_relay_query_value "$query_json" authority)" || return 10
    mode="$(_proxy_relay_query_value "$query_json" mode)" || return 10
    fp="$(_proxy_relay_query_value "$query_json" fp)" || return 10
    alpn_value="$(_proxy_relay_query_value "$query_json" alpn)" || return 10
    header_type="$(_proxy_relay_query_value "$query_json" headerType)" || return 10
    certificate_sha256="$(_proxy_relay_query_value "$query_json" pcs)" || return 10
    [[ -n "$certificate_sha256" ]] || certificate_sha256="$(_proxy_relay_query_value "$query_json" pinSHA256)" || return 10

    case "$scheme" in
        vless)
            uuid="$(_proxy_relay_uri_decode "$userinfo")" || parse_valid='false'
            [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || parse_valid='false'
            [[ -z "$encryption" || "$encryption" == none ]] || parse_valid='false'
            type="${type:-tcp}"
            case "$security:$type:$flow" in
                reality:tcp:xtls-rprx-vision) profile='vless-reality-vision'; transport='tcp' ;;
                reality:grpc:) profile='vless-grpc-reality'; transport='grpc' ;;
                tls:ws:) profile='vless-ws-tls'; transport='ws' ;;
                tls:grpc:) profile='vless-grpc-tls'; transport='grpc' ;;
                tls:xhttp:) profile='vless-xhttp-tls'; transport='xhttp' ;;
                :tcp: | none:tcp:) profile='vless-tcp'; transport='tcp' ;;
                *) profile='invalid' ;;
            esac
            ;;
        trojan)
            password="$(_proxy_relay_uri_decode "$userinfo")" || parse_valid='false'
            [[ -n "$password" ]] || parse_valid='false'
            case "$security:${type:-tcp}" in
                tls:ws) profile='trojan-ws-tls'; transport='ws' ;;
                tls:grpc) profile='trojan-grpc-tls'; transport='grpc' ;;
                reality:grpc) profile='trojan-grpc-reality'; transport='grpc' ;;
                reality:xhttp) profile='trojan-xhttp-reality'; transport='xhttp' ;;
                *) profile='invalid' ;;
            esac
            ;;
        anytls)
            password="$(_proxy_relay_uri_decode "$userinfo")" || parse_valid='false'
            [[ -n "$password" && ( -z "$type" || "$type" == tcp ) ]] || parse_valid='false'
            case "$security" in
                tls) profile='anytls-tls' ;;
                reality) profile='anytls-reality' ;;
                *) profile='invalid' ;;
            esac
            ;;
        hysteria2 | hy2)
            password="$(_proxy_relay_uri_decode "$userinfo")" || parse_valid='false'
            [[ -n "$password" ]] || parse_valid='false'
            profile='hysteria2'
            network_hint='udp'
            tls_enabled='true'
            tls_mode='tls'
            alpn='["h3"]'
            obfs_type="$(_proxy_relay_query_value "$query_json" obfs)" || return 10
            obfs_type="${obfs_type:-none}"
            obfs_password="$(_proxy_relay_query_value "$query_json" obfs-password)" || return 10
            [[ "$obfs_type" == none || ( "$obfs_type" == salamander && -n "$obfs_password" ) ]] || parse_valid='false'
            ;;
        tuic)
            [[ "$userinfo" == *:* ]] || parse_valid='false'
            uuid="$(_proxy_relay_uri_decode "${userinfo%%:*}")" || parse_valid='false'
            password="$(_proxy_relay_uri_decode "${userinfo#*:}")" || parse_valid='false'
            [[ "$uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ && -n "$password" ]] || parse_valid='false'
            profile='tuic-v5'
            network_hint='udp'
            tls_enabled='true'
            tls_mode='tls'
            alpn='["h3"]'
            congestion_control="$(_proxy_relay_query_value "$query_json" congestion_control)" || return 10
            congestion_control="${congestion_control:-bbr}"
            udp_relay_mode="$(_proxy_relay_query_value "$query_json" udp_relay_mode)" || return 10
            udp_relay_mode="${udp_relay_mode:-native}"
            [[ "$congestion_control" == bbr || "$congestion_control" == cubic || "$congestion_control" == new_reno ]] || parse_valid='false'
            [[ "$udp_relay_mode" == native ]] || parse_valid='false'
            ;;
        ss)
            if [[ "$uri_format" == legacy-base64 ]]; then
                [[ "$userinfo" == *:* ]] || parse_valid='false'
                method="${userinfo%%:*}"
                password="${userinfo#*:}"
            else
                uri_format='sip002'
                if [[ "$userinfo" == *:* ]]; then
                    method="$(_proxy_relay_uri_decode "${userinfo%%:*}")" || parse_valid='false'
                    password="$(_proxy_relay_uri_decode "${userinfo#*:}")" || parse_valid='false'
                else
                    userinfo="$(_proxy_relay_b64_decode "$userinfo")" || parse_valid='false'
                    [[ "$userinfo" == *:* ]] || parse_valid='false'
                    method="${userinfo%%:*}"
                    password="${userinfo#*:}"
                fi
            fi
            [[ -n "$password" ]] || parse_valid='false'
            plugin="$(_proxy_relay_query_value "$query_json" plugin)" || return 10
            case "$method" in
                aes-256-gcm) profile='shadowsocks-aes-256-gcm' ;;
                chacha20-ietf-poly1305) profile='shadowsocks-chacha20-poly1305' ;;
                2022-blake3-aes-256-gcm) profile='shadowsocks-2022' ;;
                *) profile='invalid' ;;
            esac
            if [[ -n "$plugin" ]]; then
                plugin_json="$(_proxy_relay_parse_ss_plugin "$plugin")" || parse_valid='false'
                [[ "$method" == 2022-blake3-aes-256-gcm ]] || parse_valid='false'
                profile='shadowsocks-2022-shadowtls'
                shadowtls='true'
                tls_enabled='true'
                tls_mode='shadowtls'
                sni="$(jq -r '.host' <<<"$plugin_json" 2>/dev/null)" || return 10
                shadowtls_password="$(jq -r '.password' <<<"$plugin_json" 2>/dev/null)" || return 10
            elif [[ "$method" == 2022-blake3-aes-256-gcm && -z "$requested_profile" ]]; then
                _proxy_relay_uri_error 'Shadowsocks 2022 URI cannot distinguish ordinary and Padding profiles; select --profile'
                return 2
            elif [[ "$requested_profile" == shadowsocks-2022-padding ]]; then
                [[ "$method" == 2022-blake3-aes-256-gcm ]] || parse_valid='false'
                profile='shadowsocks-2022-padding'
                padding='true'
            fi
            [[ "$profile" == shadowsocks-2022-shadowtls ]] || network_hint='both'
            ;;
        socks5)
            [[ "$userinfo" == *:* ]] || parse_valid='false'
            username="$(_proxy_relay_uri_decode "${userinfo%%:*}")" || parse_valid='false'
            password="$(_proxy_relay_uri_decode "${userinfo#*:}")" || parse_valid='false'
            [[ -n "$username" && -n "$password" ]] || parse_valid='false'
            profile='socks5'
            network_hint='tcp'
            ;;
    esac

    [[ "$profile" != invalid && "$parse_valid" == true ]] || {
        _proxy_relay_uri_error 'unsupported protocol combination'
        return 10
    }
    if [[ -n "$requested_profile" && "$requested_profile" != "$profile" ]]; then
        _proxy_relay_uri_error 'URI does not match requested profile'
        return 10
    fi

    case "$profile" in
        vless-reality-vision | vless-grpc-reality | trojan-xhttp-reality | trojan-grpc-reality | anytls-reality)
            tls_enabled='true'; tls_mode='reality'
            [[ -n "$sni" && "$public_key" =~ ^[A-Za-z0-9_-]{32,64}$ && "$short_id" =~ ^([0-9A-Fa-f]{2}){1,8}$ ]] || {
                _proxy_relay_uri_error 'invalid REALITY parameters'; return 10;
            }
            ;;
        vless-ws-tls | trojan-ws-tls | vless-grpc-tls | vless-xhttp-tls | trojan-grpc-tls | anytls-tls)
            tls_enabled='true'; tls_mode='tls'
            [[ -n "$sni" ]] || { _proxy_relay_uri_error 'missing TLS server name'; return 10; }
            ;;
    esac
    if [[ "$tls_enabled" == true ]]; then
        _proxy_relay_valid_host "$sni" || { _proxy_relay_uri_error 'invalid TLS server name'; return 10; }
    fi
    [[ -z "$fp" || "$fp" == chrome ]] || { _proxy_relay_uri_error 'unsupported TLS fingerprint'; return 10; }
    [[ -z "$ws_host" ]] || _proxy_relay_valid_host "$ws_host" || { _proxy_relay_uri_error 'invalid transport host'; return 10; }
    [[ -z "$grpc_authority" ]] || _proxy_relay_valid_host "$grpc_authority" || { _proxy_relay_uri_error 'invalid gRPC authority'; return 10; }
    case "$transport" in
        ws | xhttp) [[ "$path" == /* ]] || { _proxy_relay_uri_error 'invalid transport path'; return 10; } ;;
        grpc) [[ "$service_name" =~ ^[A-Za-z0-9._/-]{1,128}$ ]] || { _proxy_relay_uri_error 'invalid gRPC service'; return 10; } ;;
    esac
    case "$profile" in
        vless-reality-vision)
            _proxy_relay_query_keys_allowed "$query_json" security encryption pbk fp type flow sni sid headerType || return 10 ;;
        vless-grpc-reality | trojan-grpc-reality)
            _proxy_relay_query_keys_allowed "$query_json" security encryption pbk fp type serviceName authority sni sid || return 10 ;;
        trojan-xhttp-reality)
            _proxy_relay_query_keys_allowed "$query_json" security pbk fp type path sni sid || return 10 ;;
        vless-ws-tls | trojan-ws-tls)
            _proxy_relay_query_keys_allowed "$query_json" security encryption type host path sni insecure pcs || return 10 ;;
        vless-grpc-tls | trojan-grpc-tls)
            _proxy_relay_query_keys_allowed "$query_json" security encryption type serviceName authority sni insecure pcs || return 10 ;;
        vless-xhttp-tls)
            _proxy_relay_query_keys_allowed "$query_json" security encryption type alpn mode path host sni insecure pcs || return 10
            [[ -z "$mode" || "$mode" == stream-one ]] || return 10
            ;;
        anytls-tls)
            _proxy_relay_query_keys_allowed "$query_json" security sni type insecure pcs || return 10 ;;
        anytls-reality)
            _proxy_relay_query_keys_allowed "$query_json" security sni fp pbk sid type headerType || return 10 ;;
        hysteria2)
            _proxy_relay_query_keys_allowed "$query_json" sni insecure obfs obfs-password pinSHA256 || return 10 ;;
        tuic-v5)
            _proxy_relay_query_keys_allowed "$query_json" sni alpn congestion_control udp_relay_mode allow_insecure pinSHA256 || return 10 ;;
        shadowsocks-*)
            _proxy_relay_query_keys_allowed "$query_json" plugin || return 10 ;;
        vless-tcp)
            _proxy_relay_query_keys_allowed "$query_json" encryption type security headerType || return 10 ;;
        socks5)
            _proxy_relay_query_keys_allowed "$query_json" || return 10 ;;
    esac
    case "$profile" in
        vless-reality-vision | vless-tcp | anytls-reality)
            [[ -z "$header_type" || "$header_type" == none ]] || {
                _proxy_relay_uri_error 'unsupported header type'; return 10;
            }
            ;;
    esac
    [[ "$profile" != tuic-v5 || -z "$alpn_value" || "$alpn_value" == h3 ]] || {
        _proxy_relay_uri_error 'unsupported TUIC ALPN'; return 10;
    }
    [[ "$scheme" != ss || -n "$plugin" || "$query" != *plugin=* ]] || {
        _proxy_relay_uri_error 'empty Shadowsocks plugin'; return 10;
    }

    if [[ "$profile" == tuic-v5 ]]; then
        insecure="$(_proxy_relay_bool_json "$(_proxy_relay_query_value "$query_json" allow_insecure)")" || {
            _proxy_relay_uri_error 'invalid insecure flag'; return 10;
        }
    else
        insecure="$(_proxy_relay_bool_json "$(_proxy_relay_query_value "$query_json" insecure)")" || {
            _proxy_relay_uri_error 'invalid insecure flag'; return 10;
        }
    fi
    [[ -z "$certificate_sha256" || "$certificate_sha256" =~ ^[0-9A-Fa-f]{64}$ ]] || {
        _proxy_relay_uri_error 'invalid certificate pin'; return 10;
    }
    cores_json="$(_proxy_relay_profile_cores_json "$profile")" || return 10

    jq -cn \
        --arg profile "$profile" --argjson cores "$cores_json" \
        --arg host "$host" --argjson port "$port" --arg network "$network_hint" --arg name "$name" \
        --arg uuid "$uuid" --arg username "$username" --arg password "$password" \
        --arg public_key "$public_key" --arg short_id "$short_id" --arg shadowtls_password "$shadowtls_password" \
        --argjson tls_enabled "$tls_enabled" --arg tls_mode "$tls_mode" --arg sni "$sni" \
        --argjson insecure "$insecure" --arg pin "$certificate_sha256" --argjson alpn "$alpn" \
        --arg transport "$transport" --arg path "$path" --arg transport_host "$ws_host" \
        --arg service_name "$service_name" --arg authority "$grpc_authority" --arg flow "$flow" --arg mode "$mode" \
        --arg method "$method" --argjson padding "$padding" --argjson shadowtls "$shadowtls" \
        --arg obfs_type "$obfs_type" --arg obfs_password "$obfs_password" \
        --arg congestion "$congestion_control" --arg udp_mode "$udp_relay_mode" --arg uri_format "$uri_format" '
        {
            schema_version:1, profile:$profile, compatible_cores:$cores,
            endpoint:{host:$host,port:$port}, network_hint:$network, name:$name,
            credentials:{uuid:$uuid,username:$username,password:$password,public_key:$public_key,
                short_id:$short_id,shadowtls_password:$shadowtls_password},
            tls:{enabled:$tls_enabled,mode:$tls_mode,server_name:$sni,insecure:$insecure,
                certificate_sha256:$pin,alpn:$alpn},
            transport:{type:$transport,path:$path,host:$transport_host,service_name:$service_name,
                authority:$authority,flow:$flow,mode:$mode},
            options:{method:$method,padding:$padding,shadowtls:$shadowtls,obfs_type:$obfs_type,
                obfs_password:$obfs_password,congestion_control:$congestion,
                udp_relay_mode:$udp_mode,uri_format:$uri_format}
        }' 2>/dev/null || {
            _proxy_relay_uri_error 'could not create normalized JSON'
            return 20
        }
}

_proxy_relay_render_outbound_from_uri() {
    local core="${1-}" exit_id="${2-}" uri="${3-}" profile="${4-}" node tag
    [[ $# -ge 3 && $# -le 4 ]] || { _proxy_relay_uri_error 'missing or extra argument'; return 2; }
    [[ "$core" == sing-box || "$core" == xray ]] || { _proxy_relay_uri_error 'unsupported core'; return 2; }
    [[ "$exit_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || { _proxy_relay_uri_error 'invalid exit id'; return 2; }
    node="$(proxy_relay_uri_parse "$uri" "$profile")" || return $?
    jq -e --arg core "$core" '.compatible_cores | index($core) != null' <<<"$node" >/dev/null 2>&1 || {
        _proxy_relay_uri_error 'profile is not supported by selected core'
        return 10
    }
    if [[ "$core" == xray ]] && jq -e '
        .tls.enabled and .tls.mode == "tls" and .tls.insecure and
        .tls.certificate_sha256 == ""
    ' <<<"$node" >/dev/null 2>&1; then
        _proxy_relay_uri_error 'Xray insecure TLS requires a certificate pin'
        return 10
    fi
    tag="relay-exit-$exit_id"
    if [[ "$core" == sing-box ]]; then
        jq -cn --argjson n "$node" --arg tag "$tag" '
            def tls:
                {enabled:true,server_name:$n.tls.server_name,insecure:$n.tls.insecure} +
                (if ($n.tls.alpn|length)>0 then {alpn:$n.tls.alpn} else {} end);
            def reality_tls:
                tls + {utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,
                    public_key:$n.credentials.public_key,short_id:$n.credentials.short_id}};
            def transport:
                if $n.transport.type == "ws" then {type:"ws",path:$n.transport.path} +
                    (if $n.transport.host != "" then {headers:{Host:$n.transport.host}} else {} end)
                elif $n.transport.type == "grpc" then {type:"grpc",service_name:$n.transport.service_name}
                elif $n.transport.type == "xhttp" then {type:"http",path:$n.transport.path}
                else null end;
            def base($type): {type:$type,tag:$tag,server:$n.endpoint.host,server_port:$n.endpoint.port};
            if ($n.profile|startswith("vless-")) then
                [base("vless") + {uuid:$n.credentials.uuid} +
                    (if $n.transport.flow != "" then {flow:$n.transport.flow} else {} end) +
                    (if $n.tls.mode == "reality" then {tls:reality_tls}
                     elif $n.tls.enabled then {tls:tls} else {} end) +
                    (if transport != null then {transport:transport} else {} end)]
            elif ($n.profile|startswith("trojan-")) then
                [base("trojan") + {password:$n.credentials.password} +
                    {tls:(if $n.tls.mode == "reality" then reality_tls else tls end)} +
                    (if transport != null then {transport:transport} else {} end)]
            elif ($n.profile|startswith("anytls-")) then
                [base("anytls") + {password:$n.credentials.password,
                    tls:(if $n.tls.mode == "reality" then reality_tls else tls end)}]
            elif $n.profile == "hysteria2" then
                [base("hysteria2") + {password:$n.credentials.password,tls:tls} +
                    (if $n.options.obfs_type == "salamander" then
                        {obfs:{type:"salamander",password:$n.options.obfs_password}} else {} end)]
            elif $n.profile == "tuic-v5" then
                [base("tuic") + {uuid:$n.credentials.uuid,password:$n.credentials.password,
                    congestion_control:$n.options.congestion_control,udp_relay_mode:$n.options.udp_relay_mode,tls:tls}]
            elif $n.profile == "shadowsocks-2022-shadowtls" then
                [{type:"shadowsocks",tag:$tag,method:$n.options.method,password:$n.credentials.password,
                    detour:($tag+"-shadowtls")},
                 {type:"shadowtls",tag:($tag+"-shadowtls"),server:$n.endpoint.host,
                    server_port:$n.endpoint.port,version:3,password:$n.credentials.shadowtls_password,tls:tls}]
            elif ($n.profile|startswith("shadowsocks-")) then
                [base("shadowsocks") + {method:$n.options.method,password:$n.credentials.password} +
                    (if $n.options.padding then {multiplex:{enabled:true,padding:true}} else {} end)]
            elif $n.profile == "socks5" then
                [base("socks") + {version:"5",username:$n.credentials.username,password:$n.credentials.password}]
            else error("unsupported sing-box profile") end
            | {outbounds:.,target_tag:$tag}' 2>/dev/null || {
                _proxy_relay_uri_error 'could not render sing-box outbound'; return 20;
            }
    else
        jq -cn --argjson n "$node" --arg tag "$tag" '
            def tls_settings:
                {serverName:$n.tls.server_name} +
                (if $n.tls.certificate_sha256 != "" then
                    {pinnedPeerCertSha256:$n.tls.certificate_sha256} else {} end) +
                (if ($n.tls.alpn|length)>0 then {alpn:$n.tls.alpn} else {} end);
            def stream:
                {network:$n.transport.type,security:$n.tls.mode} +
                (if $n.tls.mode == "reality" then {realitySettings:{serverName:$n.tls.server_name,
                    fingerprint:"chrome",publicKey:$n.credentials.public_key,shortId:$n.credentials.short_id,spiderX:""}}
                 elif $n.tls.enabled then {tlsSettings:tls_settings} else {} end) +
                (if $n.transport.type == "grpc" then {grpcSettings:({serviceName:$n.transport.service_name} +
                    (if $n.transport.authority != "" then {authority:$n.transport.authority} else {} end))}
                 elif $n.transport.type == "xhttp" then {xhttpSettings:{mode:(if $n.transport.mode == "" then "stream-one" else $n.transport.mode end),
                    host:$n.transport.host,path:$n.transport.path}}
                 elif $n.transport.type == "ws" then {wsSettings:{path:$n.transport.path,
                    headers:{Host:$n.transport.host}}} else {} end);
            if ($n.profile|startswith("vless-")) then
                [{tag:$tag,protocol:"vless",settings:{vnext:[{address:$n.endpoint.host,port:$n.endpoint.port,
                    users:[{id:$n.credentials.uuid,encryption:"none"} +
                        (if $n.transport.flow != "" then {flow:$n.transport.flow} else {} end)]}]},streamSettings:stream}]
            elif ($n.profile|startswith("trojan-")) then
                [{tag:$tag,protocol:"trojan",settings:{address:$n.endpoint.host,
                    port:$n.endpoint.port,password:$n.credentials.password},streamSettings:stream}]
            elif ($n.profile|startswith("shadowsocks-")) then
                [{tag:$tag,protocol:"shadowsocks",settings:{servers:[{address:$n.endpoint.host,
                    port:$n.endpoint.port,method:$n.options.method,password:$n.credentials.password}]}}]
            else error("unsupported Xray profile") end
            | {outbounds:.,target_tag:$tag}' 2>/dev/null || {
                _proxy_relay_uri_error 'could not render Xray outbound'; return 20;
            }
    fi
}

proxy_relay_render_outbound() {
    local core="${1-}" exit_json="${2-}" exit_id uri profile
    [[ $# -eq 2 ]] || { _proxy_relay_uri_error 'missing or extra argument'; return 2; }
    [[ "$core" == sing-box || "$core" == xray ]] || { _proxy_relay_uri_error 'unsupported core'; return 2; }
    jq -e --arg core "$core" '
        type == "object" and .type == "protocol" and .core == $core and
        (.id | type == "string" and test("^exit-[a-f0-9]{16}$")) and
        (.uri | type == "string" and length > 0) and
        (.profile | type == "string" and length > 0)
    ' <<<"$exit_json" >/dev/null 2>&1 || {
        _proxy_relay_uri_error 'invalid protocol exit object'
        return 10
    }
    exit_id="$(jq -r '.id' <<<"$exit_json" 2>/dev/null)" || return 10
    uri="$(jq -r '.uri' <<<"$exit_json" 2>/dev/null)" || return 10
    profile="$(jq -r '.profile' <<<"$exit_json" 2>/dev/null)" || return 10
    _proxy_relay_render_outbound_from_uri "$core" "$exit_id" "$uri" "$profile"
}

proxy_relay_uri_rewrite() {
    local uri="${1-}" new_host="${2-}" new_port="${3-}"
    local scheme rest fragment='' query='' body authority userinfo new_authority decoded encoded parse_status=0
    [[ $# -eq 3 && -n "$uri" ]] || { _proxy_relay_uri_error 'missing or extra argument'; return 2; }
    _proxy_relay_valid_host "$new_host" || { _proxy_relay_uri_error 'invalid replacement host'; return 2; }
    if [[ ! "$new_port" =~ ^[0-9]+$ || ${#new_port} -gt 5 ]] || ((10#$new_port < 1 || 10#$new_port > 65535)); then
        _proxy_relay_uri_error 'invalid replacement port'; return 2;
    fi
    scheme="${uri%%://*}"
    proxy_relay_uri_parse "$uri" >/dev/null 2>&1 || parse_status=$?
    if ((parse_status != 0)); then
        if [[ "$parse_status" == 2 && "${scheme,,}" == ss ]]; then
            proxy_relay_uri_parse "$uri" shadowsocks-2022 >/dev/null || return $?
        else
            proxy_relay_uri_parse "$uri" >/dev/null
            return $?
        fi
    fi
    rest="${uri#*://}"
    if [[ "$rest" == *'#'* ]]; then fragment="#${rest#*#}"; rest="${rest%%#*}"; fi
    if [[ "$rest" == *'?'* ]]; then query="?${rest#*\?}"; body="${rest%%\?*}"; else body="$rest"; fi
    new_authority="$(_proxy_relay_format_authority "$new_host" "$((10#$new_port))")"
    if [[ "${scheme,,}" == ss && "$body" != *@* ]]; then
        decoded="$(_proxy_relay_b64_decode "$body")" || return 10
        authority="${decoded##*@}"
        userinfo="${decoded%"@$authority"}"
        encoded="$(_proxy_relay_b64_encode_like "$userinfo@$new_authority" "$body")" || return 20
        printf '%s://%s%s%s' "$scheme" "$encoded" "$query" "$fragment"
        return 0
    fi
    authority="${body##*@}"
    userinfo="${body%"@$authority"}"
    printf '%s://%s@%s%s%s' "$scheme" "$userinfo" "$new_authority" "$query" "$fragment"
}
