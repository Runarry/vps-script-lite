# shellcheck shell=bash
# Node manifest, certificate, CRUD and subscription operations for proxy.sh.
# Sourcing this file only defines functions.

proxy_all_profiles() {
    local profile label
    local -A seen=()
    while IFS=$'\t' read -r profile label; do
        [[ -n "$profile" && -z "${seen[$profile]:-}" ]] || continue
        seen[$profile]=1
        printf '%s\t%s\n' "$profile" "$label"
    done < <({ proxy_sb_profiles; proxy_xray_profiles; })
}

proxy_profiles_show() {
    local profile label cores joined core
    printf '支持的代理节点配置\n'
    while IFS=$'\t' read -r profile label; do
        cores=""
        while IFS= read -r core; do
            [[ -n "$cores" ]] && cores+=","
            cores+="$core"
        done < <(proxy_profile_cores "$profile")
        joined="${cores:-无}"
        printf '  %-34s %-32s [%s]\n' "$profile" "$label" "$joined"
    done < <(proxy_all_profiles)
}

proxy_profile_requires_tls_certificate() {
    case "${1:-}" in
        vless-ws-tls | trojan-ws-tls | vless-grpc-tls | anytls-tls | hysteria2 | tuic-v5 | vless-xhttp-tls | trojan-grpc-tls) return 0 ;;
        *) return 1 ;;
    esac
}

proxy_profile_uses_reality() {
    case "${1:-}" in
        vless-reality-vision | anytls-reality | vless-grpc-reality | trojan-xhttp-reality | trojan-grpc-reality) return 0 ;;
        *) return 1 ;;
    esac
}

proxy_profile_uses_uuid() {
    case "${1:-}" in
        vless-* | tuic-v5) return 0 ;;
        *) return 1 ;;
    esac
}

proxy_profile_uses_password() {
    case "${1:-}" in
        trojan-* | anytls-* | hysteria2 | tuic-v5 | shadowsocks-* | socks5) return 0 ;;
        *) return 1 ;;
    esac
}

proxy_profile_default_transport() {
    case "${1:-}" in
        vless-ws-tls | trojan-ws-tls) printf 'ws' ;;
        vless-grpc-tls | vless-grpc-reality | trojan-grpc-reality | trojan-grpc-tls) printf 'grpc' ;;
        vless-xhttp-tls | trojan-xhttp-reality) printf 'xhttp' ;;
        *) printf 'tcp' ;;
    esac
}

proxy_profile_default_name() {
    local profile="$1" port="$2"
    printf '%s-%s' "$profile" "$port"
}

proxy_ip_strategy_label() {
    case "${1:-auto}" in
        auto) printf '自动' ;;
        prefer_ipv4) printf '优先 IPv4' ;;
        prefer_ipv6) printf '优先 IPv6' ;;
        ipv4_only) printf '仅 IPv4' ;;
        ipv6_only) printf '仅 IPv6' ;;
        *) printf '%s' "${1:-auto}" ;;
    esac
}

proxy_prompt_ip_strategy() {
    proxy_prompt_select "出站 IP 策略" "${1:-auto}" \
        auto "自动（内核默认）" \
        prefer_ipv4 "优先 IPv4" \
        prefer_ipv6 "优先 IPv6" \
        ipv4_only "仅 IPv4" \
        ipv6_only "仅 IPv6"
}

proxy_choose_core_for_profile() {
    local profile="$1" requested="${2:-}" core selected confirm_status=0 installed_count=0
    local -a candidates=() supported=() choices=()
    while IFS= read -r core; do
        [[ -n "$core" ]] && installed_count=$((installed_count + 1))
    done < <(proxy_installed_cores)
    while IFS= read -r core; do
        supported+=("$core")
        proxy_core_registered "$core" && candidates+=("$core")
    done < <(proxy_profile_cores "$profile")

    if [[ -n "$requested" ]]; then
        proxy_core_valid "$requested" || {
            vps_cmd_error "无效内核：$requested"
            return 2
        }
        proxy_core_registered "$requested" || {
            vps_cmd_error "内核尚未登记：$requested"
            return 3
        }
        if ! proxy_profile_cores "$profile" | grep -Fxq "$requested"; then
            vps_cmd_error "${requested} 不支持节点配置 ${profile}"
            return 3
        fi
        printf '%s' "$requested"
        return 0
    fi

    case "${#candidates[@]}" in
        0)
            if ! proxy_is_interactive; then
                vps_cmd_error "没有已安装且支持 ${profile} 的内核；请先安装兼容内核"
                return 3
            fi
            ((${#supported[@]} > 0)) || {
                vps_cmd_error "没有内核支持节点配置 ${profile}"
                return 3
            }
            if ((${#supported[@]} == 1)); then
                selected="${supported[0]}"
                proxy_confirm "${profile} 需要尚未安装的 $(proxy_core_label "$selected")，现在安装？" || confirm_status=$?
                if ((confirm_status != 0)); then
                    [[ "$confirm_status" == "130" ]] && return 130
                    vps_cmd_info "已取消添加节点"
                    return 130
                fi
            else
                for core in "${supported[@]}"; do
                    choices+=("$core" "$(proxy_core_label "$core")（安装后使用）")
                done
                selected="$(proxy_prompt_select "请选择要安装的兼容内核" "" "${choices[@]}")" || return $?
            fi
            # This helper is consumed through command substitution; keep install
            # progress visible without mixing it into the selected core value.
            proxy_core_install "$selected" >&2 || return $?
            [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] || proxy_core_registered "$selected" || {
                vps_cmd_error "$(proxy_core_label "$selected") 安装后仍未登记"
                return 20
            }
            printf '%s' "$selected"
            ;;
        1)
            if ((installed_count > 1)) && proxy_is_interactive; then
                proxy_confirm "${profile} 仅由 $(proxy_core_label "${candidates[0]}") 提供，确认使用该内核？" || confirm_status=$?
                if ((confirm_status != 0)); then
                    [[ "$confirm_status" == "130" ]] && return 130
                    vps_cmd_info "已取消添加节点"
                    return 130
                fi
            fi
            printf '%s' "${candidates[0]}"
            ;;
        *)
            if ! proxy_is_interactive; then
                vps_cmd_error "多个已安装内核支持 ${profile}，请使用 --core sing-box|xray"
                return 2
            fi
            for core in "${candidates[@]}"; do
                choices+=("$core" "$(proxy_core_label "$core")")
            done
            proxy_prompt_select "请选择运行 $(proxy_profile_label "$profile") 的内核" "" "${choices[@]}"
            ;;
    esac
}

proxy_prompt_profile() {
    local profile label
    local -a choices=()
    while IFS=$'\t' read -r profile label; do
        choices+=("$profile" "${label}（${profile}）")
    done < <(proxy_all_profiles)
    ((${#choices[@]} > 0)) || {
        vps_cmd_error "当前没有可用的节点配置"
        return 3
    }
    proxy_prompt_select "请选择协议配置" "${choices[0]}" "${choices[@]}"
}

proxy_prompt_value() {
    local prompt="$1" default="${2:-}" value
    if declare -F vps_cmd_prompt_value >/dev/null 2>&1; then
        vps_cmd_prompt_value "$prompt" "$default"
        return
    fi
    if [[ -n "$default" ]]; then
        printf '%s [%s]：' "$prompt" "$default" >&2
    else
        printf '%s：' "$prompt" >&2
    fi
    IFS= read -r value || return 130
    value="$(vps_cmd_trim "$value")"
    printf '%s' "${value:-$default}"
}

proxy_prepare_manifest_state() (
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_manifest_ensure || return $?
    proxy_recover_transaction
)

proxy_port_conflicts_manifest() {
    local port="$1" ignore_id="${2:-}"
    [[ -f "$PROXY_MANIFEST" ]] || return 1
    jq -e --arg port "$port" --arg ignore "$ignore_id" '.nodes[] | select(.port == ($port | tonumber) and .id != $ignore)' "$PROXY_MANIFEST" >/dev/null 2>&1
}

proxy_port_is_listening() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lntu 2>/dev/null | awk -v wanted="$port" '
        {
            address=$5
            sub(/^.*:/, "", address)
            gsub(/[^0-9].*$/, "", address)
            if (address == wanted) found=1
        }
        END { exit(found ? 0 : 1) }
    '
}

proxy_require_available_port() {
    local port="$1" ignore_id="${2:-}" old_port="${3:-}"
    proxy_valid_port "$port" || {
        vps_cmd_error "监听端口无效：$port"
        return 2
    }
    if proxy_port_conflicts_manifest "$port" "$ignore_id"; then
        vps_cmd_error "端口 ${port} 已被另一个受管节点使用"
        return 3
    fi
    if [[ "$port" != "$old_port" ]]; then
        command -v ss >/dev/null 2>&1 || {
            vps_cmd_error "检查端口占用需要 ss（通常由 iproute2 提供）"
            return 3
        }
        if proxy_port_is_listening "$port"; then
            vps_cmd_error "端口 ${port} 已被系统中的进程监听"
            return 3
        fi
    fi
}

proxy_require_unique_name() {
    local name="$1" ignore_id="${2:-}"
    proxy_valid_name "$name" || {
        vps_cmd_error "节点名称不能为空、不能换行且最多 128 个字符"
        return 2
    }
    if [[ -f "$PROXY_MANIFEST" ]] && jq -e --arg name "$name" --arg ignore "$ignore_id" '.nodes[] | select(.name == $name and .id != $ignore)' "$PROXY_MANIFEST" >/dev/null 2>&1; then
        vps_cmd_error "节点名称已存在：$name"
        return 3
    fi
}

proxy_generate_reality_keys() {
    local core="$1" binary="$2" output private_key="" public_key=""
    case "$core" in
        sing-box)
            output="$("$binary" generate reality-keypair 2>&1)" || return 20
            private_key="$(printf '%s\n' "$output" | awk -F': *' '/PrivateKey|Private key/ {print $2; exit}')"
            public_key="$(printf '%s\n' "$output" | awk -F': *' '/PublicKey|Public key/ {print $2; exit}')"
            ;;
        xray)
            output="$("$binary" x25519 2>&1)" || return 20
            private_key="$(printf '%s\n' "$output" | awk -F': *' '/PrivateKey|Private key/ {print $2; exit}')"
            public_key="$(printf '%s\n' "$output" | awk -F': *' '/PublicKey|Public key|Password/ {print $2; exit}')"
            if [[ -z "$private_key" || -z "$public_key" ]]; then
                private_key="$(printf '%s\n' "$output" | awk 'NR==1 {print $NF}')"
                public_key="$(printf '%s\n' "$output" | awk 'NR==2 {print $NF}')"
            fi
            ;;
        *) return 2 ;;
    esac
    [[ -n "$private_key" && -n "$public_key" && "$private_key" != "$public_key" ]] || {
        vps_cmd_error "$(proxy_core_label "$core") REALITY 密钥生成失败"
        return 20
    }
    PROXY_REALITY_PRIVATE_KEY="$private_key"
    PROXY_REALITY_PUBLIC_KEY="$public_key"
}

proxy_certificate_logical_dir() {
    local core="$1" id="$2"
    printf '%s/%s/certs/%s' "$PROXY_ETC_LOGICAL" "$core" "$id"
}

proxy_cert_host_san() {
    local host="$1"
    if [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$host" == *:* ]]; then
        printf 'IP:%s' "$host"
    else
        printf 'DNS:%s' "$host"
    fi
}

proxy_validate_certificate_pair() {
    local certificate="$1" key="$2" sni="$3" cert_pub key_pub check_option x509_help
    openssl x509 -in "$certificate" -noout >/dev/null 2>&1 || {
        vps_cmd_error "无法解析证书：$certificate"
        return 10
    }
    openssl x509 -in "$certificate" -noout -checkend 0 >/dev/null 2>&1 || {
        vps_cmd_error "证书已经过期：$certificate"
        return 10
    }
    openssl pkey -in "$key" -passin pass: -noout >/dev/null 2>&1 || {
        vps_cmd_error "无法解析私钥（仅支持未加密私钥）：$key"
        return 10
    }
    cert_pub="$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    key_pub="$(openssl pkey -in "$key" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || {
        vps_cmd_error "证书与私钥不匹配"
        return 10
    }
    if [[ "$sni" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$sni" == *:* ]]; then
        check_option="-checkip"
    else
        check_option="-checkhost"
    fi
    x509_help="$(openssl x509 -help 2>&1 || true)"
    if grep -q -- "$check_option" <<<"$x509_help"; then
        openssl x509 -in "$certificate" -noout "$check_option" "$sni" >/dev/null 2>&1 || {
            vps_cmd_error "证书不覆盖 SNI：$sni"
            return 10
        }
    else
        vps_cmd_warning "当前 OpenSSL 不支持 ${check_option}，已跳过证书主机名校验"
    fi
}

proxy_resolve_import_file() {
    local source="$1" resolved=""
    [[ "$source" == /* ]] || {
        vps_cmd_error "导入证书和私钥必须使用绝对路径"
        return 2
    }
    if command -v realpath >/dev/null 2>&1; then
        resolved="$(realpath -e -- "$source" 2>/dev/null)" || resolved=""
    elif command -v readlink >/dev/null 2>&1; then
        resolved="$(readlink -f -- "$source" 2>/dev/null)" || resolved=""
    fi
    [[ -n "$resolved" && -f "$resolved" && ! -L "$resolved" ]] || {
        vps_cmd_error "无法解析导入文件：$source"
        return 3
    }
    printf '%s' "$resolved"
}

proxy_prepare_certificate() {
    local core="$1" id="$2" mode="$3" sni="$4" import_cert="${5:-}" import_key="${6:-}"
    local logical_dir physical_dir cert_logical key_logical cert_path key_path temp_dir config san fingerprint
    local resolved_cert="" resolved_key="" existing_fingerprint="" status=0
    [[ "$mode" == "self-signed" || "$mode" == "imported" ]] || {
        vps_cmd_error "证书模式必须是 self-signed 或 imported"
        return 2
    }
    proxy_valid_host "$sni" || {
        vps_cmd_error "TLS SNI/域名无效：$sni"
        return 2
    }
    command -v openssl >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1 || {
        vps_cmd_error "证书操作需要 openssl 和 sha256sum"
        return 3
    }
    logical_dir="$(proxy_certificate_logical_dir "$core" "$id")"
    physical_dir="$(vps_cmd_system_path "$logical_dir")" || return $?
    vps_cmd_require_no_symlink_components "$physical_dir" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        cert_logical="${logical_dir}/cert-dry-run.pem"
        key_logical="${logical_dir}/key-dry-run.pem"
        PROXY_CERTIFICATE_LOGICAL="$cert_logical"
        PROXY_KEY_LOGICAL="$key_logical"
        PROXY_CERTIFICATE_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
        PROXY_CERTIFICATE_INSECURE=$([[ "$mode" == "self-signed" ]] && printf true || printf false)
        return 0
    fi
    mkdir -p -- "$physical_dir" || return 20
    chmod 0700 -- "$physical_dir" || return 20
    temp_dir="$(mktemp -d "${physical_dir}/.prepare.XXXXXX")" || return 20
    chmod 0700 -- "$temp_dir" || { rm -rf -- "$temp_dir"; return 20; }
    if [[ "$mode" == "imported" ]]; then
        resolved_cert="$(proxy_resolve_import_file "$import_cert")" || {
            status=$?
            rm -rf -- "$temp_dir"
            return "$status"
        }
        resolved_key="$(proxy_resolve_import_file "$import_key")" || {
            status=$?
            rm -rf -- "$temp_dir"
            return "$status"
        }
        local validation_status=0
        proxy_validate_certificate_pair "$resolved_cert" "$resolved_key" "$sni" || validation_status=$?
        if ((validation_status != 0)); then
            rm -rf -- "$temp_dir"
            return "$validation_status"
        fi
        cp -- "$resolved_cert" "$temp_dir/cert.pem" || { rm -rf -- "$temp_dir"; return 20; }
        cp -- "$resolved_key" "$temp_dir/key.pem" || { rm -rf -- "$temp_dir"; return 20; }
    else
        config="$temp_dir/openssl.cnf"
        san="$(proxy_cert_host_san "$sni")"
        {
            printf '[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n'
            printf '[dn]\nCN=%s\n' "$sni"
            printf '[ext]\nsubjectAltName=%s\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$san"
        } >"$config" || { rm -rf -- "$temp_dir"; return 20; }
        openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
            -config "$config" -keyout "$temp_dir/key.pem" -out "$temp_dir/cert.pem" >/dev/null 2>&1 || {
            rm -rf -- "$temp_dir"
            vps_cmd_error "生成自签名证书失败"
            return 20
        }
    fi
    chmod 0600 -- "$temp_dir/cert.pem" "$temp_dir/key.pem" || { rm -rf -- "$temp_dir"; return 20; }
    fingerprint="$(openssl x509 -in "$temp_dir/cert.pem" -noout -fingerprint -sha256 2>/dev/null | awk -F= 'NR==1 {gsub(":", "", $2); print tolower($2)}')"
    [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || { rm -rf -- "$temp_dir"; return 20; }
    cert_logical="${logical_dir}/cert-${fingerprint}.pem"
    key_logical="${logical_dir}/key-${fingerprint}.pem"
    cert_path="$(vps_cmd_system_path "$cert_logical")" || {
        status=$?
        rm -rf -- "$temp_dir"
        return "$status"
    }
    key_path="$(vps_cmd_system_path "$key_logical")" || {
        status=$?
        rm -rf -- "$temp_dir"
        return "$status"
    }
    if [[ -e "$cert_path" || -e "$key_path" ]]; then
        [[ -f "$cert_path" && ! -L "$cert_path" && -f "$key_path" && ! -L "$key_path" ]] || {
            rm -rf -- "$temp_dir"
            vps_cmd_error "已存在的受管证书对不完整或不安全：$logical_dir"
            return 30
        }
        proxy_validate_certificate_pair "$cert_path" "$key_path" "$sni" || {
            status=$?
            rm -rf -- "$temp_dir"
            return "$status"
        }
        existing_fingerprint="$(openssl x509 -in "$cert_path" -noout -fingerprint -sha256 2>/dev/null | awk -F= 'NR==1 {gsub(":", "", $2); print tolower($2)}')"
        [[ "$existing_fingerprint" == "$fingerprint" ]] || {
            rm -rf -- "$temp_dir"
            vps_cmd_error "受管证书文件名与内容指纹不一致：$cert_path"
            return 30
        }
    else
        mv -- "$temp_dir/cert.pem" "$cert_path" || { rm -rf -- "$temp_dir"; return 20; }
        if ! mv -- "$temp_dir/key.pem" "$key_path"; then
            rm -f -- "$cert_path"
            rm -rf -- "$temp_dir"
            return 20
        fi
        chmod 0600 -- "$cert_path" "$key_path" || {
            rm -f -- "$cert_path" "$key_path"
            rm -rf -- "$temp_dir"
            return 20
        }
    fi
    rm -rf -- "$temp_dir"
    PROXY_CERTIFICATE_LOGICAL="$cert_logical"
    PROXY_KEY_LOGICAL="$key_logical"
    PROXY_CERTIFICATE_SHA256="$fingerprint"
    PROXY_CERTIFICATE_INSECURE=$([[ "$mode" == "self-signed" ]] && printf true || printf false)
}

proxy_prepare_node_json() {
    local core="$1" profile="$2" id="$3" name="$4" listen="$5" port="$6" address="$7"
    local sni="$8" path="$9" service_name="${10}" cert_mode="${11}" import_cert="${12}" import_key="${13}"
    local obfs_type="${14}" up_mbps="${15}" down_mbps="${16}" congestion_control="${17}" ip_strategy="${18:-auto}"
    local binary uuid="" password="" username="" private_key="" public_key="" short_id="" shadowtls_password=""
    local method="" padding=false shadowtls=false obfs_password="" transport flow="" tls_enabled=false tls_mode="none"
    local cert_path="" key_path="" cert_sha="" insecure=false created_at
    binary="$(proxy_core_binary_path "$core")" || return 3
    transport="$(proxy_profile_default_transport "$profile")"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if proxy_profile_uses_uuid "$profile"; then
        uuid="$(proxy_generate_uuid "$binary" "$core")" || return 20
    fi
    if proxy_profile_uses_password "$profile"; then
        case "$profile" in
            shadowsocks-aes-256-gcm | shadowsocks-chacha20-poly1305) password="$(proxy_random_hex 16)" || return 20 ;;
            shadowsocks-2022 | shadowsocks-2022-padding | shadowsocks-2022-shadowtls) password="$(proxy_random_base64 32)" || return 20 ;;
            *) password="$(proxy_random_hex 16)" || return 20 ;;
        esac
    fi
    if [[ "$profile" == "socks5" ]]; then
        username="user-$(proxy_random_hex 4)" || return 20
    fi
    if proxy_profile_uses_reality "$profile"; then
        proxy_generate_reality_keys "$core" "$binary" || return $?
        private_key="$PROXY_REALITY_PRIVATE_KEY"
        public_key="$PROXY_REALITY_PUBLIC_KEY"
        short_id="$(proxy_random_hex 8)" || return 20
        tls_enabled=true
        tls_mode="reality"
    elif proxy_profile_requires_tls_certificate "$profile"; then
        tls_enabled=true
        tls_mode="$cert_mode"
        proxy_prepare_certificate "$core" "$id" "$cert_mode" "$sni" "$import_cert" "$import_key" || return $?
        cert_path="$PROXY_CERTIFICATE_LOGICAL"
        key_path="$PROXY_KEY_LOGICAL"
        cert_sha="$PROXY_CERTIFICATE_SHA256"
        insecure="$PROXY_CERTIFICATE_INSECURE"
    fi

    case "$profile" in
        vless-reality-vision) flow="xtls-rprx-vision" ;;
        shadowsocks-aes-256-gcm) method="aes-256-gcm" ;;
        shadowsocks-chacha20-poly1305) method="chacha20-ietf-poly1305" ;;
        shadowsocks-2022) method="2022-blake3-aes-256-gcm" ;;
        shadowsocks-2022-padding)
            method="2022-blake3-aes-256-gcm"
            padding=true
            ;;
        shadowsocks-2022-shadowtls)
            method="2022-blake3-aes-256-gcm"
            shadowtls=true
            shadowtls_password="$(proxy_random_hex 16)" || return 20
            ;;
    esac
    if [[ "$profile" == "hysteria2" && "$obfs_type" != "none" ]]; then
        obfs_password="$(proxy_random_hex 16)" || return 20
    fi

    jq -n \
        --arg id "$id" --arg core "$core" --arg profile "$profile" --arg name "$name" \
        --arg listen "$listen" --argjson port "$port" --arg address "$address" \
        --arg uuid "$uuid" --arg password "$password" --arg username "$username" \
        --arg private_key "$private_key" --arg public_key "$public_key" --arg short_id "$short_id" \
        --arg shadowtls_password "$shadowtls_password" --arg sni "$sni" \
        --arg cert_mode "$tls_mode" --arg certificate_path "$cert_path" --arg key_path "$key_path" \
        --arg certificate_sha256 "$cert_sha" --arg transport "$transport" --arg path "$path" \
        --arg service_name "$service_name" --arg flow "$flow" --arg method "$method" \
        --arg obfs_type "$obfs_type" --arg obfs_password "$obfs_password" \
        --argjson tls_enabled "$tls_enabled" --argjson insecure "$insecure" \
        --argjson padding "$padding" --argjson shadowtls "$shadowtls" \
        --argjson up_mbps "$up_mbps" --argjson down_mbps "$down_mbps" \
        --arg congestion_control "$congestion_control" --arg ip_strategy "$ip_strategy" --arg created_at "$created_at" \
        '{
            id:$id, core:$core, profile:$profile, name:$name, listen:$listen,
            port:$port, address:$address, ip_strategy:$ip_strategy, created_at:$created_at, updated_at:$created_at,
            credentials:{uuid:$uuid,password:$password,username:$username,private_key:$private_key,public_key:$public_key,short_id:$short_id,shadowtls_password:$shadowtls_password},
            tls:{enabled:$tls_enabled,mode:$cert_mode,server_name:$sni,certificate_path:$certificate_path,key_path:$key_path,insecure:$insecure,certificate_sha256:$certificate_sha256},
            transport:{type:$transport,path:$path,service_name:$service_name,flow:$flow},
            options:{method:$method,padding:$padding,shadowtls:$shadowtls,obfs_type:$obfs_type,obfs_password:$obfs_password,up_mbps:$up_mbps,down_mbps:$down_mbps,congestion_control:$congestion_control}
        }'
}

proxy_node_add() (
    local profile="" requested_core="" name="" listen="::" port="" address="" sni="www.amd.com"
    local path="" service_name="" cert_mode="self-signed" import_cert="" import_key=""
    local obfs_type="none" up_mbps=10000 down_mbps=10000 congestion_control="bbr" ip_strategy="auto" arg core id node
    local candidate_manifest candidate_config status=0 mode detected_address address_choice transport
    local -a required_tools=(jq openssl ss)
    while (($#)); do
        arg="$1"
        case "$arg" in
            --profile) (($# >= 2)) || return 2; profile="$2"; shift 2 ;;
            --core) (($# >= 2)) || return 2; requested_core="$2"; shift 2 ;;
            --name) (($# >= 2)) || return 2; name="$2"; shift 2 ;;
            --listen) (($# >= 2)) || return 2; listen="$2"; shift 2 ;;
            --port) (($# >= 2)) || return 2; port="$2"; shift 2 ;;
            --address) (($# >= 2)) || return 2; address="$2"; shift 2 ;;
            --sni) (($# >= 2)) || return 2; sni="$2"; shift 2 ;;
            --path) (($# >= 2)) || return 2; path="$2"; shift 2 ;;
            --service-name) (($# >= 2)) || return 2; service_name="$2"; shift 2 ;;
            --cert-mode) (($# >= 2)) || return 2; cert_mode="$2"; shift 2 ;;
            --cert-file) (($# >= 2)) || return 2; import_cert="$2"; shift 2 ;;
            --key-file) (($# >= 2)) || return 2; import_key="$2"; shift 2 ;;
            --obfs) (($# >= 2)) || return 2; obfs_type="$2"; shift 2 ;;
            --up-mbps) (($# >= 2)) || return 2; up_mbps="$2"; shift 2 ;;
            --down-mbps) (($# >= 2)) || return 2; down_mbps="$2"; shift 2 ;;
            --congestion-control) (($# >= 2)) || return 2; congestion_control="$2"; shift 2 ;;
            --ip-strategy) (($# >= 2)) || return 2; ip_strategy="$2"; shift 2 ;;
            -h | --help) return 2 ;;
            *) vps_cmd_error "node add 的未知选项：$arg"; return 2 ;;
        esac
    done
    if [[ -z "$profile" ]] && proxy_is_interactive; then
        profile="$(proxy_prompt_profile)" || return $?
    fi
    [[ -n "$profile" ]] || { vps_cmd_error "node add 需要 --profile"; return 2; }
    proxy_profile_cores "$profile" >/dev/null || { vps_cmd_error "未知节点配置：$profile"; return 2; }
    if [[ -n "$requested_core" ]]; then
        proxy_core_valid "$requested_core" || { vps_cmd_error "无效内核：$requested_core"; return 2; }
        proxy_profile_cores "$profile" | grep -Fxq "$requested_core" || {
            vps_cmd_error "${requested_core} 不支持节点配置 ${profile}"
            return 3
        }
    fi
    [[ -z "$name" ]] || proxy_valid_name "$name" || { vps_cmd_error "节点名称不能为空、不能换行且最多 128 个字符"; return 2; }
    [[ -z "$port" ]] || proxy_valid_port "$port" || { vps_cmd_error "监听端口无效：$port"; return 2; }
    if [[ -z "$port" ]] && ! proxy_is_interactive; then
        vps_cmd_error "非交互添加节点需要 --port"
        return 2
    fi
    [[ -z "$address" ]] || proxy_valid_host "$address" || { vps_cmd_error "客户端连接地址无效：$address"; return 2; }
    [[ "$listen" == "::" || "$listen" == "0.0.0.0" || "$listen" =~ ^[A-Fa-f0-9:.]+$ ]] || { vps_cmd_error "监听地址无效：$listen"; return 2; }
    if proxy_profile_uses_reality "$profile" || proxy_profile_requires_tls_certificate "$profile" || [[ "$profile" == "shadowsocks-2022-shadowtls" ]]; then
        proxy_valid_host "$sni" || { vps_cmd_error "SNI 无效：$sni"; return 2; }
    fi
    transport="$(proxy_profile_default_transport "$profile")"
    if [[ -n "$path" && ( "$transport" == ws || "$transport" == xhttp ) ]]; then
        proxy_valid_path "$path" || { vps_cmd_error "传输路径必须以 / 开头且不超过 256 字符"; return 2; }
    fi
    if [[ -n "$service_name" && "$transport" == grpc && ! "$service_name" =~ ^[A-Za-z0-9._/-]{1,128}$ ]]; then
        vps_cmd_error "gRPC serviceName 无效"
        return 2
    fi
    [[ "$cert_mode" == "self-signed" || "$cert_mode" == "imported" ]] || { vps_cmd_error "--cert-mode 仅支持 self-signed|imported"; return 2; }
    if ! proxy_profile_requires_tls_certificate "$profile" && [[ "$cert_mode" != "self-signed" || -n "$import_cert$import_key" ]]; then
        vps_cmd_error "${profile} 不使用受管 TLS 证书，不能指定导入证书选项"
        return 2
    fi
    if [[ "$cert_mode" == "imported" ]] && proxy_profile_requires_tls_certificate "$profile"; then
        [[ -n "$import_cert" && -n "$import_key" ]] || { vps_cmd_error "导入证书需要 --cert-file 和 --key-file"; return 2; }
    fi
    [[ "$obfs_type" == "none" || "$obfs_type" == "salamander" ]] || { vps_cmd_error "--obfs 仅支持 none|salamander"; return 2; }
    [[ "$up_mbps" =~ ^[1-9][0-9]*$ && "$down_mbps" =~ ^[1-9][0-9]*$ ]] || { vps_cmd_error "带宽必须是正整数 Mbps"; return 2; }
    case "$congestion_control" in bbr | cubic | new_reno) ;; *) vps_cmd_error "拥塞控制仅支持 bbr|cubic|new_reno"; return 2 ;; esac
    proxy_ip_strategy_valid "$ip_strategy" || { vps_cmd_error "--ip-strategy 仅支持 auto|prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only"; return 2; }
    vps_cmd_require_root || return $?
    proxy_require_platform || return $?
    if proxy_profile_requires_tls_certificate "$profile"; then
        required_tools+=(sha256sum)
    fi
    proxy_ensure_mutation_tools node-add "${required_tools[@]}" || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    core="$(proxy_choose_core_for_profile "$profile" "$requested_core")" || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    proxy_prepare_manifest_state || return $?

    if proxy_is_interactive; then
        port="$(proxy_prompt_value "监听端口" "$port")" || return $?
        [[ -n "$port" ]] || {
            vps_cmd_error "监听端口不能为空"
            return 2
        }
        detected_address="${address:-$(proxy_default_address)}"
        if [[ -n "$detected_address" ]]; then
            address_choice="$(proxy_prompt_select "客户端连接地址" "detected" \
                detected "使用探测地址 ${detected_address}" manual "手动输入")" || return $?
            if [[ "$address_choice" == "detected" ]]; then
                address="$detected_address"
            else
                address="$(proxy_prompt_value "客户端连接地址（IP 或域名）" "")" || return $?
            fi
        else
            vps_cmd_warning "未探测到本机全局地址"
            address="$(proxy_prompt_value "客户端连接地址（IP 或域名）" "")" || return $?
        fi
        mode="$(proxy_prompt_mode "请选择添加模式")" || return $?
        if [[ "$mode" == "custom" ]]; then
            name="$(proxy_prompt_value "节点名称" "${name:-$(proxy_profile_default_name "$profile" "$port")}")" || return $?
            local listen_choice listen_default="$listen"
            case "$listen_default" in
                :: | 0.0.0.0) ;;
                *) listen_default=manual ;;
            esac
            listen_choice="$(proxy_prompt_select "监听模式" "$listen_default" \
                :: "IPv4 + IPv6（::）" 0.0.0.0 "仅 IPv4（0.0.0.0）" manual "手动输入监听地址")" || return $?
            if [[ "$listen_choice" == manual ]]; then
                listen="$(proxy_prompt_value "监听地址" "$listen")" || return $?
            else
                listen="$listen_choice"
            fi
            if proxy_profile_uses_reality "$profile" || proxy_profile_requires_tls_certificate "$profile" || [[ "$profile" == "shadowsocks-2022-shadowtls" ]]; then
                sni="$(proxy_prompt_value "SNI/伪装域名" "$sni")" || return $?
            fi
            case "$(proxy_profile_default_transport "$profile")" in
                ws | xhttp) path="$(proxy_prompt_value "传输路径" "${path:-/$(proxy_random_hex 6)}")" || return $? ;;
                grpc) service_name="$(proxy_prompt_value "gRPC serviceName" "${service_name:-grpc-$(proxy_random_hex 4)}")" || return $? ;;
            esac
            if proxy_profile_requires_tls_certificate "$profile"; then
                cert_mode="$(proxy_prompt_select "证书方式" "$cert_mode" \
                    self-signed "生成自签名证书" imported "导入现有证书")" || return $?
                if [[ "$cert_mode" == "imported" ]]; then
                    import_cert="$(proxy_prompt_value "证书文件绝对路径" "$import_cert")" || return $?
                    import_key="$(proxy_prompt_value "私钥文件绝对路径" "$import_key")" || return $?
                fi
            fi
            if [[ "$profile" == "hysteria2" ]]; then
                obfs_type="$(proxy_prompt_select "混淆方式" "$obfs_type" \
                    none "不使用混淆" salamander "Salamander")" || return $?
                up_mbps="$(proxy_prompt_value "上行 Mbps" "$up_mbps")" || return $?
                down_mbps="$(proxy_prompt_value "下行 Mbps" "$down_mbps")" || return $?
            elif [[ "$profile" == "tuic-v5" ]]; then
                congestion_control="$(proxy_prompt_select "拥塞控制" "$congestion_control" \
                    bbr BBR cubic CUBIC new_reno "New Reno")" || return $?
            fi
            ip_strategy="$(proxy_prompt_ip_strategy "$ip_strategy")" || return $?
        fi
    else
        address="${address:-$(proxy_default_address)}"
    fi

    [[ -n "$address" ]] || { vps_cmd_error "无法探测本机全局地址，请使用 --address"; return 2; }
    proxy_valid_host "$address" || { vps_cmd_error "客户端连接地址无效：$address"; return 2; }
    proxy_require_available_port "$port" || return $?
    name="${name:-$(proxy_profile_default_name "$profile" "$port")}"
    proxy_require_unique_name "$name" || return $?
    [[ "$listen" == "::" || "$listen" == "0.0.0.0" || "$listen" =~ ^[A-Fa-f0-9:.]+$ ]] || { vps_cmd_error "监听地址无效：$listen"; return 2; }
    if proxy_profile_uses_reality "$profile" || proxy_profile_requires_tls_certificate "$profile" || [[ "$profile" == "shadowsocks-2022-shadowtls" ]]; then
        proxy_valid_host "$sni" || { vps_cmd_error "SNI 无效：$sni"; return 2; }
    fi
    case "$(proxy_profile_default_transport "$profile")" in
        ws | xhttp)
            path="${path:-/$(proxy_random_hex 6)}"
            proxy_valid_path "$path" || { vps_cmd_error "传输路径必须以 / 开头且不超过 256 字符"; return 2; }
            ;;
        grpc)
            service_name="${service_name:-grpc-$(proxy_random_hex 4)}"
            [[ "$service_name" =~ ^[A-Za-z0-9._/-]{1,128}$ ]] || { vps_cmd_error "gRPC serviceName 无效"; return 2; }
            ;;
    esac
    [[ "$cert_mode" == "self-signed" || "$cert_mode" == "imported" ]] || { vps_cmd_error "--cert-mode 仅支持 self-signed|imported"; return 2; }
    if ! proxy_profile_requires_tls_certificate "$profile" && \
        [[ "$cert_mode" != "self-signed" || -n "$import_cert$import_key" ]]; then
        vps_cmd_error "${profile} 不使用受管 TLS 证书，不能指定导入证书选项"
        return 2
    fi
    if [[ "$cert_mode" == "imported" ]] && proxy_profile_requires_tls_certificate "$profile"; then
        [[ -n "$import_cert" && -n "$import_key" ]] || { vps_cmd_error "导入证书需要 --cert-file 和 --key-file"; return 2; }
    fi
    [[ "$obfs_type" == "none" || "$obfs_type" == "salamander" ]] || { vps_cmd_error "--obfs 仅支持 none|salamander"; return 2; }
    [[ "$up_mbps" =~ ^[1-9][0-9]*$ && "$down_mbps" =~ ^[1-9][0-9]*$ ]] || { vps_cmd_error "带宽必须是正整数 Mbps"; return 2; }
    case "$congestion_control" in bbr | cubic | new_reno) ;; *) vps_cmd_error "拥塞控制仅支持 bbr|cubic|new_reno"; return 2 ;; esac
    proxy_ip_strategy_valid "$ip_strategy" || { vps_cmd_error "--ip-strategy 仅支持 auto|prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only"; return 2; }
    port=$((10#$port))
    up_mbps=$((10#$up_mbps))
    down_mbps=$((10#$down_mbps))

    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "演练：向 $(proxy_core_label "$core") 添加 ${profile} 节点 ${name}（${listen}:${port}，客户端地址 ${address}，IP 策略 ${ip_strategy}）；不生成凭据、证书或配置"
        return 0
    fi

    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    proxy_manifest_validate_file "$PROXY_MANIFEST" || return $?
    proxy_require_available_port "$port" || return $?
    proxy_require_unique_name "$name" || return $?
    id="$(proxy_generate_node_id)" || return $?
    node="$(proxy_prepare_node_json "$core" "$profile" "$id" "$name" "$listen" "$port" "$address" "$sni" "$path" "$service_name" "$cert_mode" "$import_cert" "$import_key" "$obfs_type" "$up_mbps" "$down_mbps" "$congestion_control" "$ip_strategy")" || {
        status=$?
        proxy_cleanup_orphan_certs "$core" >/dev/null 2>&1 || true
        return "$status"
    }
    candidate_manifest="$(mktemp "${PROXY_STATE_DIR}/.nodes.add.XXXXXX")" || {
        proxy_cleanup_orphan_certs "$core" >/dev/null 2>&1 || true
        return 20
    }
    candidate_config="$(proxy_mktemp_json "$PROXY_STATE_DIR" config.add)" || {
        rm -f -- "$candidate_manifest"
        proxy_cleanup_orphan_certs "$core" >/dev/null 2>&1 || true
        return 20
    }
    trap 'rm -f -- "$candidate_manifest" "$candidate_config"; vps_cmd_unlock' EXIT
    if ! jq --argjson node "$node" '.nodes += [$node]' "$PROXY_MANIFEST" >"$candidate_manifest"; then
        status=10
    fi
    if ((status == 0)); then
        proxy_manifest_validate_file "$candidate_manifest" || status=$?
    fi
    if ((status == 0)); then
        proxy_render_config "$core" "$candidate_manifest" >"$candidate_config" || status=$?
    fi
    if ((status == 0)); then
        proxy_commit_manifest_config "$core" "$candidate_manifest" "$candidate_config" "node-add" || status=$?
    fi
    rm -f -- "$candidate_manifest" "$candidate_config"
    trap 'vps_cmd_unlock' EXIT
    if ((status != 0)); then
        proxy_cleanup_orphan_certs "$core" >/dev/null 2>&1 || status=30
        return "$status"
    fi
    vps_cmd_success "节点 ${name} 已添加到 $(proxy_core_label "$core")；ID：${id}"
    case "$core" in
        sing-box) proxy_sb_render_uri "$node" ;;
        xray) proxy_xray_render_uri "$node" ;;
    esac
)

proxy_node_list() {
    local core="all" json=0 arg count total node profile label ip_strategy relay_bound strategy_suffix bindings='[]'
    while (($#)); do
        arg="$1"
        case "$arg" in
            --core) (($# >= 2)) || return 2; core="$2"; shift 2 ;;
            --json) json=1; shift ;;
            *) vps_cmd_error "node list 的未知选项：$arg"; return 2 ;;
        esac
    done
    [[ "$core" == "all" ]] || proxy_core_valid "$core" || { vps_cmd_error "无效内核：$core"; return 2; }
    proxy_require_state_access || return $?
    proxy_ensure_tools node-list jq || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    [[ -f "$PROXY_MANIFEST" ]] || {
        ((json == 0)) && printf '当前没有受管节点。\n' || printf '{"schema_version":1,"total":0,"nodes":[]}\n'
        return 0
    }
    proxy_manifest_validate_file "$PROXY_MANIFEST" || return $?
    if [[ -n "${PROXY_RELAY_FILE:-}" && -f "$PROXY_RELAY_FILE" && ! -L "$PROXY_RELAY_FILE" ]]; then
        bindings="$(jq -c '.bindings // []' "$PROXY_RELAY_FILE" 2>/dev/null)" || bindings='[]'
    fi
    if ((json)); then
        jq --arg core "$core" --argjson bindings "$bindings" '{
            schema_version: 1,
            nodes: [.nodes[] | select($core == "all" or .core == $core) | . as $node |
                (any($bindings[]; .node_id == $node.id)) as $relay_bound |
                ($node.ip_strategy // "auto") as $strategy |
                {id,core,profile,name,listen,port,address,ip_strategy:$strategy,
                 relay_bound:$relay_bound,
                 ip_strategy_effective:(($relay_bound and $strategy != "auto") | not),
                 ip_strategy_status:(if $relay_bound and $strategy != "auto" then "relay_bound" else "active" end),
                 ip_strategy_note:(if $relay_bound and $strategy != "auto" then "已绑定中转，IP 策略暂不生效" else "" end),
                 created_at,updated_at}],
            total: ([.nodes[] | select($core == "all" or .core == $core)] | length)
        }' "$PROXY_MANIFEST"
        return
    fi
    count=0
    while IFS= read -r node; do
        count=$((count + 1))
        profile="$(jq -r '.profile' <<<"$node")"
        label="$(proxy_profile_label "$profile" 2>/dev/null || printf '%s' "$profile")"
        printf '[%d] %s\n' "$count" "$(jq -r '.name' <<<"$node")"
        printf '    ID：%s  内核：%s  配置：%s\n' \
            "$(jq -r '.id' <<<"$node")" "$(proxy_core_label "$(jq -r '.core' <<<"$node")")" "$label"
        printf '    监听：%s:%s  连接地址：%s\n' \
            "$(jq -r '.listen' <<<"$node")" "$(jq -r '.port' <<<"$node")" "$(jq -r '.address' <<<"$node")"
        ip_strategy="$(jq -r '.ip_strategy // "auto"' <<<"$node")"
        relay_bound=0
        if [[ "$ip_strategy" != "auto" ]] && declare -F proxy_relay_node_binding >/dev/null 2>&1 && \
            proxy_relay_node_binding "$(jq -r '.id' <<<"$node")" >/dev/null 2>&1; then
            relay_bound=1
        fi
        strategy_suffix=""
        [[ "$relay_bound" != 1 ]] || strategy_suffix='（已绑定中转，暂不生效）'
        printf '    IP 策略：%s%s\n' "$(proxy_ip_strategy_label "$ip_strategy")" "$strategy_suffix"
    done < <(jq -c --arg core "$core" '.nodes[] | select($core == "all" or .core == $core)' "$PROXY_MANIFEST")
    total="$(proxy_manifest_count all)"
    printf '当前筛选：%d 个；节点总数：%s 个\n' "$count" "$total"
}

proxy_node_select_interactive() {
    local prompt="${1:-请选择节点}" node id core profile name label
    local -a choices=()
    proxy_is_interactive || {
        vps_cmd_error "非交互模式必须显式提供节点 ID"
        return 2
    }
    proxy_require_state_access || return $?
    [[ -f "$PROXY_MANIFEST" ]] || {
        vps_cmd_error "当前没有节点"
        return 3
    }
    proxy_manifest_validate_file "$PROXY_MANIFEST" || return $?
    proxy_node_list >&2 || return $?
    while IFS= read -r node; do
        id="$(jq -r '.id' <<<"$node")"
        core="$(jq -r '.core' <<<"$node")"
        profile="$(jq -r '.profile' <<<"$node")"
        name="$(jq -r '.name' <<<"$node")"
        label="$(proxy_profile_label "$profile" 2>/dev/null || printf '%s' "$profile")"
        choices+=("$id" "${name} · $(proxy_core_label "$core") · ${label}")
    done < <(jq -c '.nodes[]' "$PROXY_MANIFEST")
    ((${#choices[@]} > 0)) || {
        vps_cmd_error "当前没有节点"
        return 3
    }
    proxy_prompt_select "$prompt" "${choices[0]}" "${choices[@]}"
}

proxy_node_details_print() {
    local node="$1" profile transport ip_strategy relay_bound=0 strategy_suffix=""
    profile="$(jq -r '.profile' <<<"$node")"
    transport="$(proxy_profile_default_transport "$profile")"
    printf '节点详情\n'
    printf '  名称：%s\n' "$(jq -r '.name' <<<"$node")"
    printf '  ID：%s\n' "$(jq -r '.id' <<<"$node")"
    printf '  内核：%s\n' "$(proxy_core_label "$(jq -r '.core' <<<"$node")")"
    printf '  配置：%s（%s）\n' "$(proxy_profile_label "$profile" 2>/dev/null || printf '%s' "$profile")" "$profile"
    printf '  监听：%s:%s\n' "$(jq -r '.listen' <<<"$node")" "$(jq -r '.port' <<<"$node")"
    printf '  连接地址：%s\n' "$(jq -r '.address' <<<"$node")"
    ip_strategy="$(jq -r '.ip_strategy // "auto"' <<<"$node")"
    if [[ "$ip_strategy" != "auto" ]] && declare -F proxy_relay_node_binding >/dev/null 2>&1 && \
        proxy_relay_node_binding "$(jq -r '.id' <<<"$node")" >/dev/null 2>&1; then
        relay_bound=1
    fi
    [[ "$relay_bound" != 1 ]] || strategy_suffix='（已绑定中转，暂不生效）'
    printf '  IP 策略：%s%s\n' "$(proxy_ip_strategy_label "$ip_strategy")" "$strategy_suffix"
    if proxy_profile_uses_reality "$profile" || proxy_profile_requires_tls_certificate "$profile" || [[ "$profile" == "shadowsocks-2022-shadowtls" ]]; then
        printf '  SNI：%s\n' "$(jq -r '.tls.server_name' <<<"$node")"
    fi
    case "$transport" in
        ws | xhttp) printf '  传输路径：%s\n' "$(jq -r '.transport.path' <<<"$node")" ;;
        grpc) printf '  gRPC serviceName：%s\n' "$(jq -r '.transport.service_name' <<<"$node")" ;;
    esac
    if proxy_profile_requires_tls_certificate "$profile"; then
        printf '  证书方式：%s\n' "$(jq -r '.tls.mode' <<<"$node")"
    fi
    if [[ "$profile" == "hysteria2" ]]; then
        printf '  混淆：%s  带宽：%s/%s Mbps\n' \
            "$(jq -r '.options.obfs_type' <<<"$node")" "$(jq -r '.options.up_mbps' <<<"$node")" "$(jq -r '.options.down_mbps' <<<"$node")"
    elif [[ "$profile" == "tuic-v5" ]]; then
        printf '  拥塞控制：%s\n' "$(jq -r '.options.congestion_control' <<<"$node")"
    fi
    printf '  创建：%s  更新：%s\n' "$(jq -r '.created_at' <<<"$node")" "$(jq -r '.updated_at' <<<"$node")"
}

proxy_node_view_interactive() {
    local id action node core
    proxy_require_state_access || return $?
    proxy_ensure_tools node-show jq || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    id="$(proxy_node_select_interactive "请选择要查看的节点")" || return $?
    node="$(proxy_manifest_node "$id")" || {
        vps_cmd_error "未找到节点：$id"
        return 3
    }
    action="$(proxy_prompt_select "请选择查看内容" details details "节点详情" uri "分享 URI")" || return $?
    if [[ "$action" == "details" ]]; then
        proxy_node_details_print "$node"
        return
    fi
    core="$(jq -r '.core' <<<"$node")"
    case "$core" in
        sing-box) proxy_sb_render_uri "$node" ;;
        xray) proxy_xray_render_uri "$node" ;;
    esac
}

proxy_node_show() {
    local id="" uri=0 arg node core ip_strategy relay_bound=false
    while (($#)); do
        arg="$1"
        case "$arg" in
            --id) (($# >= 2)) || return 2; id="$2"; shift 2 ;;
            --uri) uri=1; shift ;;
            *) vps_cmd_error "node show 的未知选项：$arg"; return 2 ;;
        esac
    done
    if [[ -n "$id" && ! "$id" =~ ^node-[a-f0-9]{16}$ ]]; then
        vps_cmd_error "node show 需要有效 --id"
        return 2
    fi
    if [[ -z "$id" ]] && ! proxy_is_interactive; then
        vps_cmd_error "node show 需要有效 --id"
        return 2
    fi
    proxy_require_state_access || return $?
    proxy_ensure_tools node-show jq || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    if [[ -z "$id" && "$uri" == "0" ]] && proxy_is_interactive; then
        proxy_node_view_interactive
        return
    fi
    if [[ -z "$id" && "$uri" == "1" ]] && proxy_is_interactive; then
        id="$(proxy_node_select_interactive "请选择要输出 URI 的节点")" || return $?
    fi
    [[ "$id" =~ ^node-[a-f0-9]{16}$ ]] || { vps_cmd_error "node show 需要有效 --id"; return 2; }
    [[ -f "$PROXY_MANIFEST" ]] || { vps_cmd_error "当前没有节点"; return 3; }
    proxy_manifest_validate_file "$PROXY_MANIFEST" || return $?
    node="$(proxy_manifest_node "$id")" || { vps_cmd_error "未找到节点：$id"; return 3; }
    if ((uri)); then
        core="$(jq -r '.core' <<<"$node")"
        case "$core" in
            sing-box) proxy_sb_render_uri "$node" ;;
            xray) proxy_xray_render_uri "$node" ;;
        esac
    else
        ip_strategy="$(jq -r '.ip_strategy // "auto"' <<<"$node")"
        if declare -F proxy_relay_node_binding >/dev/null 2>&1 && \
            proxy_relay_node_binding "$id" >/dev/null 2>&1; then
            relay_bound=true
        fi
        jq --arg strategy "$ip_strategy" --argjson relay_bound "$relay_bound" '
            {id,core,profile,name,listen,port,address,ip_strategy:$strategy,
             relay_bound:$relay_bound,
             ip_strategy_effective:(($relay_bound and $strategy != "auto") | not),
             ip_strategy_status:(if $relay_bound and $strategy != "auto" then "relay_bound" else "active" end),
             ip_strategy_note:(if $relay_bound and $strategy != "auto" then "已绑定中转，IP 策略暂不生效" else "" end),
             created_at,updated_at}' <<<"$node"
    fi
}

proxy_subscription() (
    local core="all" arg node node_core uri temp unique forward exit start end port
    while (($#)); do
        arg="$1"
        case "$arg" in
            --core) (($# >= 2)) || return 2; core="$2"; shift 2 ;;
            *) vps_cmd_error "subscription 的未知选项：$arg"; return 2 ;;
        esac
    done
    [[ "$core" == "all" ]] || proxy_core_valid "$core" || { vps_cmd_error "无效内核：$core"; return 2; }
    proxy_require_state_access || return $?
    proxy_ensure_tools subscription jq base64 tr awk mktemp || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    temp="$(mktemp "${TMPDIR:-/tmp}/vpsctl-subscription.XXXXXX")" || return 20
    unique="${temp}.unique"
    trap 'rm -f -- "$temp" "$unique"' EXIT
    if [[ -f "$PROXY_MANIFEST" ]]; then
        proxy_manifest_validate_file "$PROXY_MANIFEST" || return $?
        while IFS= read -r node; do
            node_core="$(jq -r '.core' <<<"$node")"
            case "$node_core" in
                sing-box) uri="$(proxy_sb_render_uri "$node")" || return $? ;;
                xray) uri="$(proxy_xray_render_uri "$node")" || return $? ;;
            esac
            printf '%s\n' "$uri" >>"$temp" || return 20
        done < <(jq -c --arg core "$core" '.nodes[] | select($core == "all" or .core == $core)' "$PROXY_MANIFEST")
    fi
    if [[ -n "${PROXY_RELAY_FILE:-}" && -f "$PROXY_RELAY_FILE" ]]; then
        proxy_relay_validate_file "$PROXY_RELAY_FILE" "$PROXY_MANIFEST" || return $?
        while IFS= read -r forward; do
            exit="$(proxy_relay_exit "$(jq -r '.exit_id' <<<"$forward")")" || return 10
            [[ "$(jq -r '.type' <<<"$exit")" == protocol ]] || continue
            [[ "$core" == all || "$(jq -r '.core' <<<"$exit")" == "$core" ]] || continue
            uri="$(jq -r '.uri' <<<"$exit")"
            start="$(jq -r '.listen_port_start' <<<"$forward")"
            end="$(jq -r '.listen_port_end' <<<"$forward")"
            for ((port = start; port <= end; port++)); do
                proxy_relay_uri_rewrite "$uri" "$(jq -r '.publish_address' <<<"$forward")" "$port" >>"$temp" || return $?
                printf '\n' >>"$temp" || return 20
            done
        done < <(jq -c '.forwards[]' "$PROXY_RELAY_FILE")
    fi
    [[ -s "$temp" ]] || { vps_cmd_error "当前筛选没有节点或带 URI 的端口转发"; return 3; }
    awk '!seen[$0]++' "$temp" >"$unique" || return 20
    base64 "$unique" | tr -d '\r\n' || { vps_cmd_error "生成 Base64 订阅失败"; return 20; }
    printf '\n'
)

proxy_subscription_interactive() {
    local core count selected
    local -a choices=(all "全部节点")
    proxy_require_state_access || return $?
    proxy_ensure_tools subscription jq base64 tr || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    [[ -f "$PROXY_MANIFEST" ]] || { vps_cmd_error "当前没有节点"; return 3; }
    proxy_manifest_validate_file "$PROXY_MANIFEST" || return $?
    for core in sing-box xray; do
        proxy_core_registered "$core" || continue
        count="$(proxy_manifest_count "$core")" || return $?
        if declare -F proxy_relay_subscription_link_count >/dev/null 2>&1; then
            count=$((count + $(proxy_relay_subscription_link_count "$core")))
        fi
        [[ "$count" =~ ^[1-9][0-9]*$ ]] || continue
        choices+=("$core" "$(proxy_core_label "$core")（${count} 个节点）")
    done
    choices+=(back "返回节点菜单")
    selected="$(proxy_prompt_select "请选择订阅节点范围" all "${choices[@]}")" || return $?
    [[ "$selected" == back ]] && return 130
    proxy_subscription --core "$selected"
}

proxy_node_ip_policy_set() (
    local core="" ip_strategy="" selector_mode="" selector_values='[]' arg id profile node
    local all_selected=0 selector_kinds=0 selected_count=0 candidate_manifest="" candidate_config="" status=0
    local -a ids=() profiles=()
    while (($#)); do
        arg="$1"
        case "$arg" in
            --core)
                (($# >= 2)) || { vps_cmd_error "--core 需要值"; return 2; }
                [[ -z "$core" ]] || { vps_cmd_error "--core 只能指定一次"; return 2; }
                core="$2"
                shift 2
                ;;
            --ip-strategy)
                (($# >= 2)) || { vps_cmd_error "--ip-strategy 需要值"; return 2; }
                [[ -z "$ip_strategy" ]] || { vps_cmd_error "--ip-strategy 只能指定一次"; return 2; }
                ip_strategy="$2"
                shift 2
                ;;
            --id)
                (($# >= 2)) || { vps_cmd_error "--id 需要值"; return 2; }
                ids+=("$2")
                shift 2
                ;;
            --profile)
                (($# >= 2)) || { vps_cmd_error "--profile 需要值"; return 2; }
                ((${#profiles[@]} == 0)) || { vps_cmd_error "--profile 只能指定一次"; return 2; }
                profiles+=("$2")
                shift 2
                ;;
            --all)
                ((all_selected == 0)) || { vps_cmd_error "--all 只能指定一次"; return 2; }
                all_selected=1
                shift
                ;;
            *) vps_cmd_error "node ip-policy set 的未知选项：$arg"; return 2 ;;
        esac
    done
    [[ -n "$core" ]] || { vps_cmd_error "node ip-policy set 需要 --core sing-box|xray"; return 2; }
    proxy_core_valid "$core" || { vps_cmd_error "无效内核：$core"; return 2; }
    [[ -n "$ip_strategy" ]] || { vps_cmd_error "node ip-policy set 需要 --ip-strategy"; return 2; }
    proxy_ip_strategy_valid "$ip_strategy" || {
        vps_cmd_error "--ip-strategy 仅支持 auto|prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only"
        return 2
    }
    ((${#ids[@]} == 0)) || selector_kinds=$((selector_kinds + 1))
    ((${#profiles[@]} == 0)) || selector_kinds=$((selector_kinds + 1))
    ((all_selected == 0)) || selector_kinds=$((selector_kinds + 1))
    ((selector_kinds == 1)) || {
        vps_cmd_error "选择器必须且只能使用一类：可重复 --id、单个 --profile 或 --all"
        return 2
    }
    for id in "${ids[@]}"; do
        [[ "$id" =~ ^node-[a-f0-9]{16}$ ]] || { vps_cmd_error "无效节点 ID：$id"; return 2; }
        selector_values="$(jq -cn --argjson current "$selector_values" --arg value "$id" '$current + [$value] | unique')" || return 10
    done
    if ((${#ids[@]} > 0)); then
        selector_mode="id"
    elif ((${#profiles[@]} > 0)); then
        selector_mode="profile"
        for profile in "${profiles[@]}"; do
            proxy_profile_cores "$profile" | grep -Fxq "$core" || {
                vps_cmd_error "${core} 不支持节点配置 ${profile}"
                return 2
            }
            selector_values="$(jq -cn --argjson current "$selector_values" --arg value "$profile" '$current + [$value] | unique')" || return 10
        done
    else
        selector_mode="all"
    fi

    vps_cmd_require_root || return $?
    proxy_require_platform || return $?
    proxy_ensure_mutation_tools node-ip-policy jq || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    proxy_prepare_manifest_state || return $?
    proxy_core_registered "$core" || {
        vps_cmd_error "$(proxy_core_label "$core") 尚未安装登记"
        return 3
    }
    if [[ "$selector_mode" == "id" ]]; then
        while IFS= read -r id; do
            node="$(proxy_manifest_node "$id")" || { vps_cmd_error "未找到节点：$id"; return 3; }
            [[ "$(jq -r '.core' <<<"$node")" == "$core" ]] || {
                vps_cmd_error "节点 ${id} 不属于指定内核 ${core}"
                return 3
            }
        done < <(jq -r '.[]' <<<"$selector_values")
    fi
    selected_count="$(jq -r --arg core "$core" --arg mode "$selector_mode" --argjson values "$selector_values" '
        [.nodes[] | . as $node | select(.core == $core and
            ($mode == "all" or ($mode == "id" and any($values[]; . == $node.id)) or
             ($mode == "profile" and any($values[]; . == $node.profile))))] | length
    ' "$PROXY_MANIFEST")" || return 10
    ((selected_count > 0)) || { vps_cmd_error "选择结果为空，未修改任何节点"; return 3; }
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "演练：将 ${core} 的 ${selected_count} 个节点 IP 策略设为 ${ip_strategy}；不会写入配置"
        return 0
    fi

    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    proxy_manifest_validate_file "$PROXY_MANIFEST" || return $?
    if [[ "$selector_mode" == "id" ]]; then
        while IFS= read -r id; do
            node="$(proxy_manifest_node "$id")" || { vps_cmd_error "节点在批量设置期间已被删除，请重试：$id"; return 3; }
            [[ "$(jq -r '.core' <<<"$node")" == "$core" ]] || {
                vps_cmd_error "节点在批量设置期间已不属于 ${core}，请重试：$id"
                return 3
            }
        done < <(jq -r '.[]' <<<"$selector_values")
    fi
    selected_count="$(jq -r --arg core "$core" --arg mode "$selector_mode" --argjson values "$selector_values" '
        [.nodes[] | . as $node | select(.core == $core and
            ($mode == "all" or ($mode == "id" and any($values[]; . == $node.id)) or
             ($mode == "profile" and any($values[]; . == $node.profile))))] | length
    ' "$PROXY_MANIFEST")" || return 10
    ((selected_count > 0)) || { vps_cmd_error "选择结果为空，未修改任何节点"; return 3; }
    candidate_manifest="$(mktemp "${PROXY_STATE_DIR}/.nodes.ip-policy.XXXXXX")" || return 20
    candidate_config="$(proxy_mktemp_json "$PROXY_STATE_DIR" config.ip-policy)" || {
        rm -f -- "$candidate_manifest"
        return 20
    }
    trap 'rm -f -- "$candidate_manifest" "$candidate_config"; vps_cmd_unlock' EXIT
    if ! jq --arg core "$core" --arg mode "$selector_mode" --arg strategy "$ip_strategy" \
        --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson values "$selector_values" '
        .nodes |= map(. as $node |
            if .core == $core and
               ($mode == "all" or ($mode == "id" and any($values[]; . == $node.id)) or
                ($mode == "profile" and any($values[]; . == $node.profile)))
            then .ip_strategy=$strategy | .updated_at=$updated_at else . end)
    ' "$PROXY_MANIFEST" >"$candidate_manifest"; then
        status=10
    fi
    if ((status == 0)); then
        proxy_manifest_validate_file "$candidate_manifest" || status=$?
    fi
    if ((status == 0)); then
        proxy_render_config "$core" "$candidate_manifest" >"$candidate_config" || status=$?
    fi
    if ((status == 0)); then
        proxy_commit_manifest_config "$core" "$candidate_manifest" "$candidate_config" "node-ip-policy" || status=$?
    fi
    rm -f -- "$candidate_manifest" "$candidate_config"
    trap 'vps_cmd_unlock' EXIT
    ((status == 0)) || return "$status"
    vps_cmd_success "已将 $(proxy_core_label "$core") 的 ${selected_count} 个节点 IP 策略设为 ${ip_strategy}"
)

proxy_node_ip_policy_interactive() {
    local core strategy selector_mode selected profile node id label
    local -a core_choices=() selector_args=() node_choices=() profile_choices=()
    local -A chosen=()
    proxy_require_state_access || return $?
    proxy_ensure_tools node-ip-policy jq || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    [[ -f "$PROXY_MANIFEST" ]] || { vps_cmd_error "当前没有节点"; return 3; }
    proxy_manifest_validate_file "$PROXY_MANIFEST" || return $?
    for core in sing-box xray; do
        [[ "$(proxy_manifest_count "$core")" != 0 ]] || continue
        proxy_core_registered "$core" || continue
        core_choices+=("$core" "$(proxy_core_label "$core")")
    done
    ((${#core_choices[@]} > 0)) || { vps_cmd_error "当前没有可设置的已安装内核节点"; return 3; }
    core="$(proxy_prompt_select "请选择节点所属内核" "${core_choices[0]}" "${core_choices[@]}")" || return $?
    strategy="$(proxy_prompt_ip_strategy auto)" || return $?
    selector_mode="$(proxy_prompt_select "请选择节点范围" ids \
        ids "多选节点" profile "按配置（profile）" all "该内核全部节点")" || return $?
    case "$selector_mode" in
        ids)
            while true; do
                node_choices=()
                while IFS= read -r node; do
                    id="$(jq -r '.id' <<<"$node")"
                    [[ -z "${chosen[$id]:-}" ]] || continue
                    label="$(proxy_profile_label "$(jq -r '.profile' <<<"$node")" 2>/dev/null || jq -r '.profile' <<<"$node")"
                    node_choices+=("$id" "$(jq -r '.name' <<<"$node") · ${label}")
                done < <(jq -c --arg core "$core" '.nodes[] | select(.core == $core)' "$PROXY_MANIFEST")
                ((${#selector_args[@]} == 0)) || node_choices+=("done" "完成选择")
                ((${#node_choices[@]} > 0)) || break
                selected="$(proxy_prompt_select "请选择节点（可连续选择多个）" "${node_choices[0]}" "${node_choices[@]}")" || return $?
                [[ "$selected" == "done" ]] && break
                chosen["$selected"]=1
                selector_args+=(--id "$selected")
            done
            ((${#selector_args[@]} > 0)) || { vps_cmd_error "至少需要选择一个节点"; return 3; }
            ;;
        profile)
            while IFS= read -r profile; do
                [[ -n "$profile" ]] || continue
                profile_choices+=("$profile" "$(proxy_profile_label "$profile" 2>/dev/null || printf '%s' "$profile")")
            done < <(jq -r --arg core "$core" '[.nodes[] | select(.core == $core) | .profile] | unique[]' "$PROXY_MANIFEST")
            profile="$(proxy_prompt_select "请选择配置（profile）" "${profile_choices[0]}" "${profile_choices[@]}")" || return $?
            selector_args=(--profile "$profile")
            ;;
        all) selector_args=(--all) ;;
    esac
    proxy_node_ip_policy_set --core "$core" --ip-strategy "$strategy" "${selector_args[@]}"
}

proxy_node_menu_run() {
    local action status=0 prompt_status=0 ignored
    while true; do
        action="$(proxy_prompt_select "节点管理" view \
            add "添加节点" view "查看节点" edit "编辑节点" delete "删除节点" \
            ip_policy "批量设置出站 IP 策略" subscription "输出节点订阅" back "返回代理管理")" || prompt_status=$?
        if ((prompt_status != 0)); then
            [[ "$prompt_status" == "130" ]] && return "$status"
            return "$prompt_status"
        fi
        case "$action" in
            add) proxy_menu_action proxy_node_add || status=$? ;;
            view) proxy_menu_action proxy_node_view_interactive || status=$? ;;
            edit) proxy_menu_action proxy_node_edit || status=$? ;;
            delete) proxy_menu_action proxy_node_delete || status=$? ;;
            ip_policy) proxy_menu_action proxy_node_ip_policy_interactive || status=$? ;;
            subscription) proxy_menu_action proxy_subscription_interactive || status=$? ;;
            back) return "$status" ;;
        esac
        vps_ui_ensure_init
        printf '\n %s按 Enter 返回节点菜单...%s' "$VPS_UI_CYAN" "$VPS_UI_RESET" >&2
        IFS= read -r ignored || return "$status"
        prompt_status=0
    done
}

proxy_node_edit() (
    local id="" name="" listen="" port="" address="" sni="" path="" service_name=""
    local requested_cert_mode="" import_cert="" import_key="" obfs_type="" up_mbps="" down_mbps="" congestion_control="" ip_strategy="" arg
    local node current_node core profile old_port old_cert_mode cert_mode candidate_node candidate_manifest candidate_config status=0
    local field transport current confirm_status=0 certificate_tools_needed=0
    local -a edit_fields=()
    local -a required_tools=()
    while (($#)); do
        arg="$1"
        case "$arg" in
            --id) (($# >= 2)) || return 2; id="$2"; shift 2 ;;
            --name) (($# >= 2)) || return 2; name="$2"; shift 2 ;;
            --listen) (($# >= 2)) || return 2; listen="$2"; shift 2 ;;
            --port) (($# >= 2)) || return 2; port="$2"; shift 2 ;;
            --address) (($# >= 2)) || return 2; address="$2"; shift 2 ;;
            --sni) (($# >= 2)) || return 2; sni="$2"; shift 2 ;;
            --path) (($# >= 2)) || return 2; path="$2"; shift 2 ;;
            --service-name) (($# >= 2)) || return 2; service_name="$2"; shift 2 ;;
            --cert-mode) (($# >= 2)) || return 2; requested_cert_mode="$2"; shift 2 ;;
            --cert-file) (($# >= 2)) || return 2; import_cert="$2"; shift 2 ;;
            --key-file) (($# >= 2)) || return 2; import_key="$2"; shift 2 ;;
            --obfs) (($# >= 2)) || return 2; obfs_type="$2"; shift 2 ;;
            --up-mbps) (($# >= 2)) || return 2; up_mbps="$2"; shift 2 ;;
            --down-mbps) (($# >= 2)) || return 2; down_mbps="$2"; shift 2 ;;
            --congestion-control) (($# >= 2)) || return 2; congestion_control="$2"; shift 2 ;;
            --ip-strategy) (($# >= 2)) || return 2; ip_strategy="$2"; shift 2 ;;
            *) vps_cmd_error "node edit 的未知选项：$arg"; return 2 ;;
        esac
    done
    local had_explicit_change=0
    [[ -z "$name$listen$port$address$sni$path$service_name$requested_cert_mode$import_cert$import_key$obfs_type$up_mbps$down_mbps$congestion_control$ip_strategy" ]] || had_explicit_change=1
    if [[ -n "$id" && ! "$id" =~ ^node-[a-f0-9]{16}$ ]]; then
        vps_cmd_error "node edit 需要有效 --id"
        return 2
    fi
    if [[ -z "$id" ]] && ! proxy_is_interactive; then
        vps_cmd_error "node edit 需要有效 --id"
        return 2
    fi
    if ((had_explicit_change == 0)) && ! proxy_is_interactive; then
        vps_cmd_error "node edit 至少需要一个变更字段"
        return 2
    fi
    [[ -z "$name" ]] || proxy_valid_name "$name" || { vps_cmd_error "节点名称不能为空、不能换行且最多 128 个字符"; return 2; }
    [[ -z "$port" ]] || proxy_valid_port "$port" || { vps_cmd_error "监听端口无效：$port"; return 2; }
    [[ -z "$address" ]] || proxy_valid_host "$address" || { vps_cmd_error "连接地址无效"; return 2; }
    [[ -z "$listen" || "$listen" == "::" || "$listen" == "0.0.0.0" || "$listen" =~ ^[A-Fa-f0-9:.]+$ ]] || { vps_cmd_error "监听地址无效"; return 2; }
    [[ -z "$sni" ]] || proxy_valid_host "$sni" || { vps_cmd_error "SNI 无效"; return 2; }
    [[ -z "$path" ]] || proxy_valid_path "$path" || { vps_cmd_error "传输路径无效"; return 2; }
    [[ -z "$service_name" || "$service_name" =~ ^[A-Za-z0-9._/-]{1,128}$ ]] || { vps_cmd_error "gRPC serviceName 无效"; return 2; }
    [[ -z "$requested_cert_mode" || "$requested_cert_mode" == "self-signed" || "$requested_cert_mode" == "imported" ]] || { vps_cmd_error "--cert-mode 仅支持 self-signed|imported"; return 2; }
    [[ -z "$import_cert$import_key" || ( -n "$import_cert" && -n "$import_key" ) ]] || { vps_cmd_error "证书和私钥必须成对提供"; return 2; }
    [[ -z "$obfs_type" || "$obfs_type" == "none" || "$obfs_type" == "salamander" ]] || { vps_cmd_error "--obfs 仅支持 none|salamander"; return 2; }
    [[ -z "$up_mbps" || "$up_mbps" =~ ^[1-9][0-9]*$ ]] || { vps_cmd_error "上行带宽必须是正整数 Mbps"; return 2; }
    [[ -z "$down_mbps" || "$down_mbps" =~ ^[1-9][0-9]*$ ]] || { vps_cmd_error "下行带宽必须是正整数 Mbps"; return 2; }
    case "$congestion_control" in '' | bbr | cubic | new_reno) ;; *) vps_cmd_error "拥塞控制仅支持 bbr|cubic|new_reno"; return 2 ;; esac
    [[ -z "$ip_strategy" ]] || proxy_ip_strategy_valid "$ip_strategy" || { vps_cmd_error "--ip-strategy 仅支持 auto|prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only"; return 2; }
    vps_cmd_require_root || return $?
    proxy_require_platform || return $?
    proxy_ensure_mutation_tools node-edit jq || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    proxy_prepare_manifest_state || return $?
    if [[ -z "$id" ]] && proxy_is_interactive; then
        id="$(proxy_node_select_interactive "请选择要编辑的节点")" || return $?
    fi
    [[ "$id" =~ ^node-[a-f0-9]{16}$ ]] || { vps_cmd_error "node edit 需要有效 --id"; return 2; }
    node="$(proxy_manifest_node "$id")" || { vps_cmd_error "未找到节点：$id"; return 3; }
    core="$(jq -r '.core' <<<"$node")"
    profile="$(jq -r '.profile' <<<"$node")"
    old_port="$(jq -r '.port' <<<"$node")"
    if ((had_explicit_change == 0)); then
        proxy_is_interactive || {
            vps_cmd_error "node edit 至少需要一个变更字段"
            return 2
        }
        transport="$(proxy_profile_default_transport "$profile")"
        edit_fields=(name "节点名称" listen "监听模式" port "监听端口" address "客户端连接地址")
        if proxy_profile_uses_reality "$profile" || proxy_profile_requires_tls_certificate "$profile" || [[ "$profile" == "shadowsocks-2022-shadowtls" ]]; then
            edit_fields+=(sni "SNI/伪装域名")
        fi
        case "$transport" in
            ws | xhttp) edit_fields+=(path "传输路径") ;;
            grpc) edit_fields+=(service "gRPC serviceName") ;;
        esac
        if proxy_profile_requires_tls_certificate "$profile"; then
            edit_fields+=(certificate "证书方式")
        fi
        if [[ "$profile" == "hysteria2" ]]; then
            edit_fields+=(obfs "混淆方式" up "上行 Mbps" down "下行 Mbps")
        elif [[ "$profile" == "tuic-v5" ]]; then
            edit_fields+=(congestion "拥塞控制")
        fi
        edit_fields+=(ip_strategy "出站 IP 策略")
        edit_fields+=(save "预览并保存" cancel "取消编辑")
        while true; do
            field="$(proxy_prompt_select "请选择要修改的字段" save "${edit_fields[@]}")" || return $?
            case "$field" in
                name)
                    current="${name:-$(jq -r '.name' <<<"$node")}"
                    name="$(proxy_prompt_value "节点名称" "$current")" || return $?
                    had_explicit_change=1
                    ;;
                listen)
                    current="${listen:-$(jq -r '.listen' <<<"$node")}"
                    local listen_choice listen_default="$current"
                    case "$listen_default" in
                        :: | 0.0.0.0) ;;
                        *) listen_default=manual ;;
                    esac
                    listen_choice="$(proxy_prompt_select "监听模式" "$listen_default" \
                        :: "IPv4 + IPv6（::）" 0.0.0.0 "仅 IPv4（0.0.0.0）" manual "手动输入监听地址")" || return $?
                    if [[ "$listen_choice" == manual ]]; then
                        listen="$(proxy_prompt_value "监听地址" "$current")" || return $?
                    else
                        listen="$listen_choice"
                    fi
                    had_explicit_change=1
                    ;;
                port)
                    port="$(proxy_prompt_value "监听端口" "${port:-$old_port}")" || return $?
                    had_explicit_change=1
                    ;;
                address)
                    address="$(proxy_prompt_value "客户端连接地址" "${address:-$(jq -r '.address' <<<"$node")}")" || return $?
                    had_explicit_change=1
                    ;;
                sni)
                    sni="$(proxy_prompt_value "SNI/伪装域名" "${sni:-$(jq -r '.tls.server_name' <<<"$node")}")" || return $?
                    had_explicit_change=1
                    ;;
                path)
                    path="$(proxy_prompt_value "传输路径" "${path:-$(jq -r '.transport.path' <<<"$node")}")" || return $?
                    had_explicit_change=1
                    ;;
                service)
                    service_name="$(proxy_prompt_value "gRPC serviceName" "${service_name:-$(jq -r '.transport.service_name' <<<"$node")}")" || return $?
                    had_explicit_change=1
                    ;;
                certificate)
                    current="${requested_cert_mode:-$(jq -r '.tls.mode' <<<"$node")}"
                    requested_cert_mode="$(proxy_prompt_select "证书方式" "$current" \
                        self-signed "生成自签名证书" imported "导入现有证书")" || return $?
                    import_cert=""
                    import_key=""
                    if [[ "$requested_cert_mode" == "imported" ]]; then
                        import_cert="$(proxy_prompt_value "证书文件绝对路径" "")" || return $?
                        import_key="$(proxy_prompt_value "私钥文件绝对路径" "")" || return $?
                    fi
                    had_explicit_change=1
                    ;;
                obfs)
                    current="${obfs_type:-$(jq -r '.options.obfs_type' <<<"$node")}"
                    obfs_type="$(proxy_prompt_select "混淆方式" "$current" none "不使用混淆" salamander Salamander)" || return $?
                    had_explicit_change=1
                    ;;
                up)
                    up_mbps="$(proxy_prompt_value "上行 Mbps" "${up_mbps:-$(jq -r '.options.up_mbps' <<<"$node")}")" || return $?
                    had_explicit_change=1
                    ;;
                down)
                    down_mbps="$(proxy_prompt_value "下行 Mbps" "${down_mbps:-$(jq -r '.options.down_mbps' <<<"$node")}")" || return $?
                    had_explicit_change=1
                    ;;
                congestion)
                    current="${congestion_control:-$(jq -r '.options.congestion_control' <<<"$node")}"
                    congestion_control="$(proxy_prompt_select "拥塞控制" "$current" bbr BBR cubic CUBIC new_reno "New Reno")" || return $?
                    had_explicit_change=1
                    ;;
                ip_strategy)
                    current="${ip_strategy:-$(jq -r '.ip_strategy // "auto"' <<<"$node")}"
                    ip_strategy="$(proxy_prompt_ip_strategy "$current")" || return $?
                    had_explicit_change=1
                    ;;
                cancel)
                    vps_cmd_info "已取消编辑"
                    return 0
                    ;;
                save)
                    if ((had_explicit_change == 0)); then
                        vps_cmd_warning "尚未修改任何字段"
                        continue
                    fi
                    old_cert_mode="$(jq -r '.tls.mode' <<<"$node")"
                    cert_mode="${requested_cert_mode:-$old_cert_mode}"
                    if proxy_profile_requires_tls_certificate "$profile" && [[ "$cert_mode" == "imported" ]] && \
                        [[ "${sni:-$(jq -r '.tls.server_name' <<<"$node")}" != "$(jq -r '.tls.server_name' <<<"$node")" ]] && [[ -z "$import_cert" ]]; then
                        vps_cmd_info "导入证书的 SNI 已改变，需要提供匹配的新证书"
                        import_cert="$(proxy_prompt_value "新证书文件绝对路径" "")" || return $?
                        import_key="$(proxy_prompt_value "新私钥文件绝对路径" "")" || return $?
                    fi
                    printf '\n保存预览\n'
                    printf '  节点：%s（%s）\n' "${name:-$(jq -r '.name' <<<"$node")}" "$id"
                    printf '  内核：%s（不可修改）\n' "$(proxy_core_label "$core")"
                    printf '  协议：%s（不可修改）\n' "$(proxy_profile_label "$profile")"
                    printf '  监听：%s:%s\n' "${listen:-$(jq -r '.listen' <<<"$node")}" "${port:-$old_port}"
                    printf '  连接地址：%s\n' "${address:-$(jq -r '.address' <<<"$node")}"
                    [[ -z "$sni" ]] || printf '  SNI：%s\n' "$sni"
                    [[ -z "$path" ]] || printf '  传输路径：%s\n' "$path"
                    [[ -z "$service_name" ]] || printf '  gRPC serviceName：%s\n' "$service_name"
                    [[ -z "$requested_cert_mode" ]] || printf '  证书方式：%s\n' "$requested_cert_mode"
                    [[ -z "$obfs_type" ]] || printf '  混淆：%s\n' "$obfs_type"
                    [[ -z "$up_mbps$down_mbps" ]] || printf '  带宽：%s/%s Mbps\n' \
                        "${up_mbps:-$(jq -r '.options.up_mbps' <<<"$node")}" "${down_mbps:-$(jq -r '.options.down_mbps' <<<"$node")}"
                    [[ -z "$congestion_control" ]] || printf '  拥塞控制：%s\n' "$congestion_control"
                    [[ -z "$ip_strategy" ]] || printf '  IP 策略：%s\n' "$(proxy_ip_strategy_label "$ip_strategy")"
                    confirm_status=0
                    proxy_confirm "确认保存这些修改？" || confirm_status=$?
                    if ((confirm_status == 0)); then
                        break
                    fi
                    [[ "$confirm_status" == "130" ]] && return 130
                    ;;
            esac
        done
    fi
    if proxy_profile_requires_tls_certificate "$profile" && [[ -n "$requested_cert_mode$import_cert$import_key$sni" ]]; then
        certificate_tools_needed=1
    fi
    name="${name:-$(jq -r '.name' <<<"$node")}"
    listen="${listen:-$(jq -r '.listen' <<<"$node")}"
    port="${port:-$old_port}"
    address="${address:-$(jq -r '.address' <<<"$node")}"
    sni="${sni:-$(jq -r '.tls.server_name' <<<"$node")}"
    path="${path:-$(jq -r '.transport.path' <<<"$node")}"
    service_name="${service_name:-$(jq -r '.transport.service_name' <<<"$node")}"
    obfs_type="${obfs_type:-$(jq -r '.options.obfs_type' <<<"$node")}"
    up_mbps="${up_mbps:-$(jq -r '.options.up_mbps' <<<"$node")}"
    down_mbps="${down_mbps:-$(jq -r '.options.down_mbps' <<<"$node")}"
    congestion_control="${congestion_control:-$(jq -r '.options.congestion_control' <<<"$node")}"
    ip_strategy="${ip_strategy:-$(jq -r '.ip_strategy // "auto"' <<<"$node")}"
    proxy_valid_host "$address" || { vps_cmd_error "连接地址无效"; return 2; }
    [[ "$listen" == "::" || "$listen" == "0.0.0.0" || "$listen" =~ ^[A-Fa-f0-9:.]+$ ]] || return 2
    if [[ -n "$path" ]] && ! proxy_valid_path "$path"; then vps_cmd_error "传输路径无效"; return 2; fi
    if [[ -n "$service_name" && ! "$service_name" =~ ^[A-Za-z0-9._/-]{1,128}$ ]]; then vps_cmd_error "gRPC serviceName 无效"; return 2; fi
    [[ "$obfs_type" == "none" || "$obfs_type" == "salamander" ]] || return 2
    [[ "$up_mbps" =~ ^[1-9][0-9]*$ && "$down_mbps" =~ ^[1-9][0-9]*$ ]] || return 2
    case "$congestion_control" in bbr | cubic | new_reno) ;; *) return 2 ;; esac
    proxy_ip_strategy_valid "$ip_strategy" || return 2
    if [[ -n "$requested_cert_mode" && "$requested_cert_mode" != "self-signed" && "$requested_cert_mode" != "imported" ]]; then
        vps_cmd_error "--cert-mode 仅支持 self-signed|imported"
        return 2
    fi
    if ! proxy_profile_requires_tls_certificate "$profile" && [[ -n "$requested_cert_mode$import_cert$import_key" ]]; then
        vps_cmd_error "${profile} 不使用受管 TLS 证书，不能修改证书选项"
        return 2
    fi
    if [[ -n "$port" && "$port" != "$old_port" ]]; then
        required_tools+=(ss)
    fi
    if ((certificate_tools_needed)); then
        required_tools+=(openssl sha256sum)
    fi
    if ((${#required_tools[@]} > 0)); then
        proxy_ensure_tools node-edit "${required_tools[@]}" || return $?
        if proxy_stop_after_dependency_plan; then return 0; fi
    fi
    proxy_require_unique_name "$name" "$id" || return $?
    proxy_require_available_port "$port" "$id" "$old_port" || return $?
    port=$((10#$port))
    up_mbps=$((10#$up_mbps))
    down_mbps=$((10#$down_mbps))

    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    current_node="$(proxy_manifest_node "$id")" || {
        vps_cmd_error "节点在编辑期间已被删除，请重试：$id"
        return 3
    }
    [[ "$current_node" == "$node" ]] || {
        vps_cmd_error "节点在编辑期间已发生变化，请重新读取后重试：$id"
        return 3
    }
    proxy_require_unique_name "$name" "$id" || return $?
    proxy_require_available_port "$port" "$id" "$old_port" || return $?
    candidate_node="$(jq \
        --arg name "$name" --arg listen "$listen" --argjson port "$port" --arg address "$address" \
        --arg sni "$sni" --arg path "$path" --arg service_name "$service_name" \
        --arg obfs_type "$obfs_type" --argjson up_mbps "$up_mbps" --argjson down_mbps "$down_mbps" \
        --arg congestion_control "$congestion_control" --arg ip_strategy "$ip_strategy" --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.name=$name | .listen=$listen | .port=$port | .address=$address | .tls.server_name=$sni |
         .transport.path=$path | .transport.service_name=$service_name | .options.obfs_type=$obfs_type |
         .options.up_mbps=$up_mbps | .options.down_mbps=$down_mbps | .options.congestion_control=$congestion_control |
         .ip_strategy=$ip_strategy | .updated_at=$updated_at' <<<"$node")" || return 10

    if proxy_profile_requires_tls_certificate "$profile"; then
        old_cert_mode="$(jq -r '.tls.mode' <<<"$node")"
        cert_mode="${requested_cert_mode:-$old_cert_mode}"
        if [[ -n "$import_cert" && -z "$requested_cert_mode" ]]; then
            cert_mode="imported"
        fi
        [[ -z "$import_cert$import_key" || ( -n "$import_cert" && -n "$import_key" ) ]] || {
            vps_cmd_error "证书和私钥必须成对提供"
            return 2
        }
        if [[ "$cert_mode" == "imported" && -z "$import_cert" ]] && \
            { [[ "$old_cert_mode" != "imported" ]] || [[ "$sni" != "$(jq -r '.tls.server_name' <<<"$node")" ]]; }; then
            vps_cmd_error "切换到导入证书或修改其 SNI 时必须同时提供新 --cert-file/--key-file"
            return 2
        fi
        if [[ "$cert_mode" == "self-signed" && -n "$import_cert" ]]; then
            vps_cmd_error "--cert-mode self-signed 不能同时使用 --cert-file/--key-file"
            return 2
        fi
        if [[ "$cert_mode" != "$old_cert_mode" || "$sni" != "$(jq -r '.tls.server_name' <<<"$node")" || -n "$import_cert" ]]; then
            proxy_prepare_certificate "$core" "$id" "$cert_mode" "$sni" "$import_cert" "$import_key" || return $?
            candidate_node="$(jq --arg mode "$cert_mode" --arg cert "$PROXY_CERTIFICATE_LOGICAL" --arg key "$PROXY_KEY_LOGICAL" \
                --arg sha "$PROXY_CERTIFICATE_SHA256" --argjson insecure "$PROXY_CERTIFICATE_INSECURE" \
                '.tls.mode=$mode | .tls.certificate_path=$cert | .tls.key_path=$key | .tls.certificate_sha256=$sha | .tls.insecure=$insecure' <<<"$candidate_node")" || {
                status=$?
                proxy_cleanup_orphan_certs "$core" >/dev/null 2>&1 || true
                return "$status"
            }
        fi
    fi
    if [[ "$profile" == "hysteria2" && "$obfs_type" == "salamander" && "$(jq -r '.options.obfs_password' <<<"$candidate_node")" == "" ]]; then
        candidate_node="$(jq --arg password "$(proxy_random_hex 16)" '.options.obfs_password=$password' <<<"$candidate_node")" || return 20
    elif [[ "$profile" == "hysteria2" && "$obfs_type" == "none" ]]; then
        candidate_node="$(jq '.options.obfs_password=""' <<<"$candidate_node")" || return 10
    fi

    candidate_manifest="$(mktemp "${PROXY_STATE_DIR}/.nodes.edit.XXXXXX")" || {
        proxy_cleanup_orphan_certs "$core" >/dev/null 2>&1 || true
        return 20
    }
    candidate_config="$(proxy_mktemp_json "$PROXY_STATE_DIR" config.edit)" || {
        rm -f -- "$candidate_manifest"
        proxy_cleanup_orphan_certs "$core" >/dev/null 2>&1 || true
        return 20
    }
    trap 'rm -f -- "$candidate_manifest" "$candidate_config"; vps_cmd_unlock' EXIT
    if ! jq --arg id "$id" --argjson node "$candidate_node" '(.nodes[] | select(.id == $id)) = $node' "$PROXY_MANIFEST" >"$candidate_manifest"; then
        status=10
    fi
    if ((status == 0)); then
        proxy_manifest_validate_file "$candidate_manifest" || status=$?
    fi
    if ((status == 0)); then
        proxy_render_config "$core" "$candidate_manifest" >"$candidate_config" || status=$?
    fi
    if ((status == 0)); then
        proxy_commit_manifest_config "$core" "$candidate_manifest" "$candidate_config" "node-edit" || status=$?
    fi
    rm -f -- "$candidate_manifest" "$candidate_config"
    trap 'vps_cmd_unlock' EXIT
    if ((status != 0)); then
        proxy_cleanup_orphan_certs "$core" >/dev/null 2>&1 || status=30
        return "$status"
    fi
    vps_cmd_success "节点 ${id} 已更新；凭据与 REALITY 密钥保持不变"
)

proxy_node_delete() (
    local id="" confirmed=0 cascade_relay=0 arg node current_node core name candidate_manifest candidate_config status=0 confirm_status=0
    local binding="" candidate_relay=""
    while (($#)); do
        arg="$1"
        case "$arg" in
            --id) (($# >= 2)) || return 2; id="$2"; shift 2 ;;
            --confirm-delete) confirmed=1; shift ;;
            --cascade-relay) cascade_relay=1; shift ;;
            *) vps_cmd_error "node delete 的未知选项：$arg"; return 2 ;;
        esac
    done
    if [[ -n "$id" && ! "$id" =~ ^node-[a-f0-9]{16}$ ]]; then
        vps_cmd_error "node delete 需要有效 --id"
        return 2
    fi
    if [[ -z "$id" ]] && ! proxy_is_interactive; then
        vps_cmd_error "node delete 需要有效 --id"
        return 2
    fi
    vps_cmd_require_root || return $?
    proxy_require_platform || return $?
    proxy_ensure_mutation_tools node-delete jq || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    proxy_prepare_manifest_state || return $?
    if [[ -z "$id" ]] && proxy_is_interactive; then
        id="$(proxy_node_select_interactive "请选择要删除的节点")" || return $?
    fi
    [[ "$id" =~ ^node-[a-f0-9]{16}$ ]] || { vps_cmd_error "node delete 需要有效 --id"; return 2; }
    node="$(proxy_manifest_node "$id")" || { vps_cmd_error "未找到节点：$id"; return 3; }
    core="$(jq -r '.core' <<<"$node")"
    name="$(jq -r '.name' <<<"$node")"
    if declare -F proxy_relay_node_binding >/dev/null 2>&1; then
        binding="$(proxy_relay_node_binding "$id" 2>/dev/null || true)"
    fi
    if [[ -n "$binding" && "$cascade_relay" != 1 ]]; then
        proxy_relay_require_node_unbound "$id" || return $?
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != "1" && "$confirmed" != "1" ]]; then
        if proxy_is_interactive; then
            proxy_confirm "删除节点 ${name}（${id}）$([[ -n "$binding" ]] && printf '并级联删除中转关联')？" || confirm_status=$?
            if ((confirm_status != 0)); then
                [[ "$confirm_status" == "130" ]] && return 130
                vps_cmd_info "已取消删除"
                return 0
            fi
        else
            vps_cmd_error "非交互删除节点需要 --confirm-delete"
            return 3
        fi
    fi
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    current_node="$(proxy_manifest_node "$id")" || {
        vps_cmd_error "节点在删除确认后已不存在，请重试：$id"
        return 3
    }
    [[ "$current_node" == "$node" ]] || {
        vps_cmd_error "节点在删除确认后已发生变化，请重新确认：$id"
        return 3
    }
    candidate_manifest="$(mktemp "${PROXY_STATE_DIR}/.nodes.delete.XXXXXX")" || return 20
    candidate_config="$(proxy_mktemp_json "$PROXY_STATE_DIR" config.delete)" || { rm -f "$candidate_manifest"; return 20; }
    if [[ -n "$binding" ]]; then
        candidate_relay="$(proxy_mktemp_json "$PROXY_STATE_DIR" relay.node-delete)" || {
            rm -f -- "$candidate_manifest" "$candidate_config"
            return 20
        }
        jq --arg node "$id" 'del(.bindings[] | select(.node_id == $node))' "$PROXY_RELAY_FILE" >"$candidate_relay" || {
            rm -f -- "$candidate_manifest" "$candidate_config" "$candidate_relay"
            return 10
        }
    fi
    trap 'rm -f -- "$candidate_manifest" "$candidate_config" "$candidate_relay"; vps_cmd_unlock' EXIT
    if ! jq --arg id "$id" 'del(.nodes[] | select(.id == $id))' "$PROXY_MANIFEST" >"$candidate_manifest"; then
        status=10
    fi
    if ((status == 0)); then
        proxy_manifest_validate_file "$candidate_manifest" || status=$?
    fi
    if ((status == 0)); then
        proxy_render_config "$core" "$candidate_manifest" "${candidate_relay:-${PROXY_RELAY_FILE:-}}" >"$candidate_config" || status=$?
    fi
    if ((status == 0)); then
        proxy_commit_manifest_config "$core" "$candidate_manifest" "$candidate_config" "node-delete" "$candidate_relay" || status=$?
    fi
    rm -f -- "$candidate_manifest" "$candidate_config" "$candidate_relay"
    trap 'vps_cmd_unlock' EXIT
    ((status == 0)) || return "$status"
    vps_cmd_success "节点 ${name} 已删除"
)

proxy_cleanup_orphan_certs() {
    local core="$1" cert_root entry id pending pending_backup manifest logical physical file base has_reference
    local -a manifests=()
    local -A referenced=()
    proxy_core_valid "$core" || return 2
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "演练：检查并清理 ${core} 的孤立受管证书"
        return 0
    fi
    cert_root="$(vps_cmd_system_path "${PROXY_ETC_LOGICAL}/${core}/certs")" || return 2
    [[ -d "$cert_root" && ! -L "$cert_root" ]] || return 0
    vps_cmd_require_no_symlink_components "$cert_root" || return $?
    if [[ -f "$PROXY_MANIFEST" && ! -L "$PROXY_MANIFEST" ]]; then
        proxy_manifest_validate_file "$PROXY_MANIFEST" || {
            vps_cmd_error "节点清单无效，拒绝清理任何证书"
            return 30
        }
        manifests+=("$PROXY_MANIFEST")
    fi
    pending="$(proxy_core_pending_path "$core")" || return $?
    if [[ -f "$pending" && ! -L "$pending" ]]; then
        pending_backup="$(jq -r '.manifest_backup // ""' "$pending" 2>/dev/null || true)"
        if [[ -n "$pending_backup" && -f "$pending_backup" && ! -L "$pending_backup" ]]; then
            proxy_manifest_validate_file "$pending_backup" || {
                vps_cmd_error "待生效备份清单无效，拒绝清理任何证书"
                return 30
            }
            manifests+=("$pending_backup")
        fi
    fi
    ((${#manifests[@]} > 0)) || {
        vps_cmd_error "缺少可验证的节点清单，拒绝清理任何证书"
        return 30
    }
    for manifest in "${manifests[@]}"; do
        while IFS= read -r logical; do
            [[ "$logical" =~ ^${PROXY_ETC_LOGICAL}/${core}/certs/node-[a-f0-9]{16}/(cert|key)(-[a-f0-9]{64})?\.pem$ ]] || continue
            physical="$(vps_cmd_system_path "$logical")" || continue
            [[ "$physical" == "$cert_root/"* ]] || continue
            referenced["$physical"]=1
        done < <(jq -r --arg core "$core" '
            .nodes[]? | select(.core == $core) |
            .tls.certificate_path, .tls.key_path | select(type == "string" and length > 0)
        ' "$manifest" 2>/dev/null)
    done
    while IFS= read -r entry; do
        [[ -d "$entry" && ! -L "$entry" ]] || continue
        [[ "$entry" == "$cert_root/node-"* ]] || continue
        id="${entry##*/}"
        [[ "$id" =~ ^node-[a-f0-9]{16}$ ]] || continue
        has_reference=0
        for physical in "${!referenced[@]}"; do
            if [[ "$physical" == "$entry/"* ]]; then
                has_reference=1
                break
            fi
        done
        if ((has_reference == 0)); then
            rm -rf -- "$entry" || return 20
            continue
        fi
        while IFS= read -r file; do
            [[ -f "$file" && ! -L "$file" && "$file" == "$entry/"* ]] || continue
            base="${file##*/}"
            [[ "$base" =~ ^(cert|key)(-[a-f0-9]{64})?\.pem$ ]] || continue
            [[ -n "${referenced[$file]:-}" ]] || rm -f -- "$file" || return 20
        done < <(find "$entry" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null)
        rmdir -- "$entry" >/dev/null 2>&1 || true
    done < <(find "$cert_root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null)
}

proxy_purge_core_nodes() {
    local core="$1" candidate_manifest candidate_config status=0
    proxy_core_valid "$core" || return 2
    [[ -f "$PROXY_MANIFEST" ]] || return 0
    candidate_manifest="$(mktemp "${PROXY_STATE_DIR}/.nodes.purge.XXXXXX")" || return 20
    candidate_config="$(proxy_mktemp_json "$PROXY_STATE_DIR" config.purge)" || { rm -f "$candidate_manifest"; return 20; }
    if ! jq --arg core "$core" 'del(.nodes[] | select(.core == $core))' "$PROXY_MANIFEST" >"$candidate_manifest"; then
        status=10
    fi
    if ((status == 0)); then
        proxy_manifest_validate_file "$candidate_manifest" || status=$?
    fi
    if ((status == 0)) && [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "演练：从节点清单清除 ${core} 的全部节点和证书"
        rm -f -- "$candidate_manifest" "$candidate_config"
        return 0
    fi
    if proxy_core_registered "$core"; then
        if ((status == 0)); then
            proxy_render_config "$core" "$candidate_manifest" >"$candidate_config" || status=$?
        fi
        if ((status == 0)); then
            proxy_commit_manifest_config "$core" "$candidate_manifest" "$candidate_config" "core-purge" || status=$?
        fi
    elif ((status == 0)); then
        proxy_atomic_write_from_file "$candidate_manifest" "${PROXY_STATE_LOGICAL}/nodes.json" 0600 || status=$?
    fi
    rm -f -- "$candidate_manifest" "$candidate_config"
    ((status == 0)) || return "$status"
    proxy_cleanup_orphan_certs "$core"
}
