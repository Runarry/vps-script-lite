# shellcheck shell=bash
# ACME issue/renew via pinned lego, DNS credentials, and optional proxy reload.

tls_maybe_reload() {
    local reload="${1:-none}" unit path
    [[ "$reload" == proxy ]] || return 0
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：续期后重载 vpsctl-proxy-sing-box / vpsctl-proxy-xray"
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1 && [[ "$(tls_init_detected)" == systemd ]]; then
        for unit in vpsctl-proxy-sing-box.service vpsctl-proxy-xray.service; do
            if systemctl cat "$unit" >/dev/null 2>&1; then
                vps_cmd_info "重载 $unit"
                vps_cmd_run systemctl try-reload-or-restart "$unit" || vps_cmd_run systemctl restart "$unit" || {
                    vps_cmd_warning "重载 $unit 失败"
                    return 30
                }
            fi
        done
        return 0
    fi
    for unit in vpsctl-proxy-sing-box vpsctl-proxy-xray; do
        path="$(vps_cmd_system_path "/etc/init.d/$unit" 2>/dev/null || true)"
        if [[ -n "$path" && -x "$path" && ! -L "$path" ]] && command -v rc-service >/dev/null 2>&1; then
            vps_cmd_info "重启 $unit"
            vps_cmd_run rc-service "$unit" restart || {
                vps_cmd_warning "重启 $unit 失败"
                return 30
            }
        fi
    done
}

tls_http_port_busy() {
    local port="${1:-80}" hex
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .
        return $?
    fi
    printf -v hex '%04X' "$port"
    grep -Eq "^[[:space:]]*[0-9]+:[[:space:]]+[0-9A-Fa-f]+:${hex}[[:space:]]" /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

tls_lego_asset_name() {
    local arch
    arch="$(tls_lego_arch)" || return $?
    printf 'lego_%s_linux_%s.tar.gz' "$TLS_LEGO_VERSION" "$arch"
}

tls_checksum_for_asset() {
    local checksums="$1" asset="$2" line hash name found=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^([0-9A-Fa-f]{64})[[:space:]]+[*]?([^[:space:]]+)$ ]]; then
            hash="${BASH_REMATCH[1],,}"
            name="${BASH_REMATCH[2]}"
            name="${name##*/}"
            if [[ "$name" == "$asset" ]]; then
                [[ -z "$found" ]] || {
                    vps_cmd_error "checksums 中 ${asset} 条目重复"
                    return 20
                }
                found="$hash"
            fi
        fi
    done <"$checksums"
    [[ -n "$found" ]] || {
        vps_cmd_error "checksums 中没有 ${asset}"
        return 20
    }
    printf '%s\n' "$found"
}

tls_extract_lego_member() {
    local archive="$1" member
    local -a members=()
    mapfile -t members < <(tar -tzf "$archive" 2>/dev/null) || return 20
    for member in "${members[@]}"; do
        [[ "$member" == lego || "$member" == */lego ]] || continue
        [[ "$member" != */ ]] || continue
        printf '%s\n' "$member"
        return 0
    done
    vps_cmd_error "lego 归档中没有 lego 二进制"
    return 20
}

tls_install_lego() {
    local asset tmp_dir archive checksums expected actual member extracted
    if tls_lego_installed; then
        return 0
    fi
    tls_lego_arch >/dev/null || return $?
    tls_ensure_tools lego-install curl tar sha256sum flock || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info "依赖仅完成安装计划；请安装依赖后重跑"
        return 0
    fi
    asset="$(tls_lego_asset_name)" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：下载 lego ${TLS_LEGO_VERSION}（$asset）到 $TLS_LEGO_LOGICAL"
        return 0
    fi
    tls_ensure_state_dirs || return $?
    mkdir -p -- "$(dirname -- "$TLS_LEGO_BIN")" || return 20
    vps_cmd_require_no_symlink_components "$(dirname -- "$TLS_LEGO_BIN")" || return $?
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-tls-lego.XXXXXX")" || return 20
    chmod 0700 -- "$tmp_dir" || { rm -rf -- "$tmp_dir"; return 20; }
    archive="${tmp_dir}/${asset}"
    checksums="${tmp_dir}/checksums.txt"
    if ! curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 15 --max-time 300 -o "$archive" \
        "https://github.com/${TLS_LEGO_REPOSITORY}/releases/download/${TLS_LEGO_VERSION}/${asset}"; then
        rm -rf -- "$tmp_dir"
        vps_cmd_error "下载 lego 资产失败：$asset"
        return 20
    fi
    if ! curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 15 --max-time 120 -o "$checksums" \
        "https://github.com/${TLS_LEGO_REPOSITORY}/releases/download/${TLS_LEGO_VERSION}/lego_${TLS_LEGO_VERSION}_checksums.txt" &&
        ! curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --retry 3 --connect-timeout 15 --max-time 120 -o "$checksums" \
            "https://github.com/${TLS_LEGO_REPOSITORY}/releases/download/${TLS_LEGO_VERSION}/lego_${TLS_LEGO_VERSION#v}_checksums.txt"; then
        rm -rf -- "$tmp_dir"
        vps_cmd_error "下载 lego checksums 失败"
        return 20
    fi
    expected="$(tls_checksum_for_asset "$checksums" "$asset")" || {
        rm -rf -- "$tmp_dir"
        return 20
    }
    actual="$(tls_sha256 "$archive")" || {
        rm -rf -- "$tmp_dir"
        return 20
    }
    [[ "$actual" == "$expected" ]] || {
        rm -rf -- "$tmp_dir"
        vps_cmd_error "lego 归档 checksum 校验失败"
        return 20
    }
    member="$(tls_extract_lego_member "$archive")" || {
        rm -rf -- "$tmp_dir"
        return 20
    }
    extracted="${tmp_dir}/lego.bin"
    tar -xOf "$archive" "$member" >"$extracted" || {
        rm -rf -- "$tmp_dir"
        vps_cmd_error "展开 lego 二进制失败"
        return 20
    }
    chmod 0755 -- "$extracted" || {
        rm -rf -- "$tmp_dir"
        return 20
    }
    mkdir -p -- "$(dirname -- "$TLS_LEGO_BIN")" || {
        rm -rf -- "$tmp_dir"
        return 20
    }
    tls_atomic_file "$TLS_LEGO_LOGICAL" 0755 <"$extracted" || {
        rm -rf -- "$tmp_dir"
        return 20
    }
    {
        printf 'tag=%s\n' "$TLS_LEGO_VERSION"
        printf 'asset=%s\n' "$asset"
        printf 'sha256=%s\n' "$(tls_sha256 "$TLS_LEGO_BIN")"
    } | tls_atomic_file "${TLS_STATE_LOGICAL}/lego.meta" 0600 || {
        rm -rf -- "$tmp_dir"
        return 20
    }
    rm -rf -- "$tmp_dir"
    vps_cmd_success "已安装 lego ${TLS_LEGO_VERSION}"
}

tls_parse_credential_file() {
    local file="$1" provider="$2" dest="$3" line key value allowed
    local -a required=() optional=() present=()
    local -A allow=() values=()
    mapfile -t required < <(tls_dns_provider_keys "$provider") || return 2
    mapfile -t optional < <(tls_dns_provider_optional_keys "$provider")
    for key in "${required[@]}" "${optional[@]}"; do
        [[ -n "$key" ]] || continue
        allow["$key"]=1
    done
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="$(vps_cmd_trim "$line")"
        [[ -n "$line" && "$line" != \#* ]] || continue
        [[ "$line" == *=* ]] || {
            vps_cmd_error "凭证文件包含无法解析的行"
            return 10
        }
        key="${line%%=*}"
        value="${line#*=}"
        key="$(vps_cmd_trim "$key")"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || {
            vps_cmd_error "凭证键名无效"
            return 10
        }
        [[ -n "${allow[$key]:-}" ]] || {
            vps_cmd_error "凭证包含未允许的键：$key"
            return 10
        }
        values["$key"]="$value"
        present+=("$key")
    done <"$file"
    for key in "${required[@]}"; do
        [[ -n "${values[$key]:-}" ]] || {
            vps_cmd_error "凭证缺少必需键：$key"
            return 10
        }
    done
    [[ -n "$dest" ]] || return 0
    : >"$dest" || return 20
    for key in "${!values[@]}"; do
        printf '%s=%s\n' "$key" "${values[$key]}" >>"$dest" || return 20
    done
    chmod 0600 -- "$dest" || return 20
}

tls_install_credentials() {
    local id="$1" provider="$2" source="$3" resolved dest
    resolved="$(tls_resolve_import_file "$source")" || return $?
    dest="${TLS_CRED_DIR}/${id}.env"
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：保存 DNS 凭证到 ${TLS_STATE_LOGICAL}/credentials/${id}.env"
        tls_parse_credential_file "$resolved" "$provider" "" || return $?
        return 0
    fi
    mkdir -p -- "$TLS_CRED_DIR" || return 20
    chmod 0700 -- "$TLS_CRED_DIR" || return 20
    tls_parse_credential_file "$resolved" "$provider" "$dest" || return $?
}

tls_run_lego() {
    local cred="${1:-}"
    shift
    local key value line
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_run "$TLS_LEGO_BIN" "$@"
        return $?
    fi
    (
        if [[ -n "$cred" && -f "$cred" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" == *=* ]] || continue
                key="${line%%=*}"
                value="${line#*=}"
                export "${key}=${value}"
            done <"$cred"
        fi
        exec "$TLS_LEGO_BIN" "$@"
    )
}

tls_lego_basename() {
    local domain="$1"
    domain="${domain//\*/_}"
    printf '%s\n' "$domain"
}

tls_lego_server() {
    local ca="$1" staging="$2"
    case "$ca" in
        letsencrypt)
            if [[ "$staging" == 1 ]]; then
                printf 'https://acme-staging-v02.api.letsencrypt.org/directory'
            else
                printf 'https://acme-v02.api.letsencrypt.org/directory'
            fi
            ;;
        zerossl) printf 'https://acme.zerossl.com/v2/DV90' ;;
        *) return 2 ;;
    esac
}

tls_issue() {
    local challenge="" ca=letsencrypt email="" dns_provider="" cred_file="" staging=0 reload=none
    local id temp_dir status=0 server cred="" lego_path base crt key domains_text
    local -a domains=() lego_args=()
    while (($#)); do
        case "$1" in
            --domain) (($# >= 2)) || { vps_cmd_error "--domain 需要值"; return 2; }; domains+=("$2"); shift 2 ;;
            --challenge) (($# >= 2)) || { vps_cmd_error "--challenge 需要值"; return 2; }; [[ -z "$challenge" || "$challenge" == "$2" ]] || { vps_cmd_error "重复指定 --challenge"; return 2; }; challenge="$2"; shift 2 ;;
            --ca) (($# >= 2)) || { vps_cmd_error "--ca 需要值"; return 2; }; ca="$2"; shift 2 ;;
            --email) (($# >= 2)) || { vps_cmd_error "--email 需要值"; return 2; }; email="$2"; shift 2 ;;
            --dns-provider) (($# >= 2)) || { vps_cmd_error "--dns-provider 需要值"; return 2; }; dns_provider="$2"; shift 2 ;;
            --dns-credential-file) (($# >= 2)) || { vps_cmd_error "--dns-credential-file 需要值"; return 2; }; cred_file="$2"; shift 2 ;;
            --staging) staging=1; shift ;;
            --reload) (($# >= 2)) || { vps_cmd_error "--reload 需要值"; return 2; }; reload="$2"; shift 2 ;;
            *) vps_cmd_error "issue 未知选项：$1"; return 2 ;;
        esac
    done
    domains_text="$(tls_dedupe_domains "${domains[@]}")" || return $?
    mapfile -t domains <<<"$domains_text"
    [[ "$challenge" == http-01 || "$challenge" == dns-01 ]] || { vps_cmd_error "--challenge 必须是 http-01 或 dns-01"; return 2; }
    [[ "$ca" == letsencrypt || "$ca" == zerossl ]] || { vps_cmd_error "--ca 仅支持 letsencrypt|zerossl"; return 2; }
    tls_valid_email "$email" || { vps_cmd_error "ACME 申请需要有效 --email"; return 2; }
    tls_valid_reload "$reload" || { vps_cmd_error "--reload 仅支持 none|proxy"; return 2; }
    [[ "$staging" == 0 || "$ca" == letsencrypt ]] || { vps_cmd_error "--staging 仅适用于 Let's Encrypt"; return 2; }
    for domain in "${domains[@]}"; do
        if [[ "$domain" == \*.* && "$challenge" != dns-01 ]]; then
            vps_cmd_error "通配符域名必须使用 DNS-01：$domain"
            return 2
        fi
    done
    if [[ "$challenge" == dns-01 ]]; then
        tls_dns_provider_lego "$dns_provider" >/dev/null || {
            vps_cmd_error "--dns-provider 必须是 cloudflare|aliyun|tencent|dnspod|huawei"
            return 2
        }
        [[ -n "$cred_file" ]] || { vps_cmd_error "DNS-01 需要 --dns-credential-file"; return 2; }
    else
        [[ -z "$dns_provider$cred_file" ]] || { vps_cmd_error "HTTP-01 不使用 DNS 提供商选项"; return 2; }
    fi
    vps_cmd_require_root || return $?
    tls_install_lego || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then return 0; fi
    tls_ensure_tools issue openssl sha256sum flock || return $?
    if [[ "$challenge" == http-01 ]]; then
        tls_ensure_tools issue-http ss || return $?
        if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then return 0; fi
        if tls_http_port_busy "$TLS_HTTP_PORT"; then
            vps_cmd_error "TCP ${TLS_HTTP_PORT} 已被占用，无法使用 HTTP-01；请改用 DNS-01"
            return 3
        fi
    fi
    server="$(tls_lego_server "$ca" "$staging")" || return 2
    vps_cmd_lock security-tls || return $?
    id="$(tls_new_id)" || return $?
    tls_ensure_state_dirs || return $?
    if [[ "$challenge" == dns-01 ]]; then
        tls_install_credentials "$id" "$dns_provider" "$cred_file" || return $?
        cred="${TLS_CRED_DIR}/${id}.env"
    fi
    lego_path="$TLS_ACCOUNT_DIR"
    lego_args=(--accept-tos --email "$email" --server "$server" --path "$lego_path" --pem)
    for domain in "${domains[@]}"; do
        lego_args+=(--domains "$domain")
    done
    if [[ "$challenge" == http-01 ]]; then
        lego_args+=(--http --http.port ":${TLS_HTTP_PORT}")
    else
        lego_args+=(--dns "$(tls_dns_provider_lego "$dns_provider")")
    fi
    lego_args+=(run)
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：为 ${domains[*]} 申请 $ca 证书（$challenge）"
        tls_run_lego "$cred" "${lego_args[@]}"
        return 0
    fi
    tls_run_lego "$cred" "${lego_args[@]}" || {
        vps_cmd_error "lego 申请证书失败"
        [[ -n "$cred" ]] && rm -f -- "$cred"
        return 20
    }
    base="$(tls_lego_basename "${domains[0]}")"
    crt="${lego_path}/certificates/${base}.pem"
    [[ -f "$crt" ]] || crt="${lego_path}/certificates/${base}.crt"
    key="${lego_path}/certificates/${base}.key"
    [[ -f "$crt" && -f "$key" && ! -L "$crt" && ! -L "$key" ]] || {
        vps_cmd_error "lego 未写出预期的证书文件"
        return 20
    }
    tls_commit_material "$id" "${domains[0]}" acme "$crt" "$key" \
        "$ca" "$challenge" "$dns_provider" "$email" "$reload" "$staging" "${domains[@]}" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：申请证书 ${domains[0]}"
        return 0
    fi
    vps_cmd_success "已申请证书 $id（${domains[0]}）"
    tls_timer_enable_quiet || vps_cmd_warning "证书已签发，但未能启用续期 timer"
    tls_maybe_reload "$reload" || return $?
    tls_show_human "$id"
}

tls_renew_one() {
    local id="$1" force="${2:-0}" days cred="" server lego_args=() base crt key renew_days="$TLS_RENEW_DAYS"
    local -a domains=()
    tls_require_record "$id" || return $?
    [[ "$TLS_CERT_SOURCE" == acme ]] || {
        vps_cmd_info "跳过导入证书 $id"
        return 0
    }
    IFS=',' read -r -a domains <<<"$TLS_CERT_DOMAINS"
    if ((force == 0)); then
        days="$(tls_days_remaining "$(tls_live_fullchain "$id")" 2>/dev/null || printf 0)"
        if [[ "$days" =~ ^[0-9]+$ ]] && ((days > TLS_RENEW_DAYS)); then
            vps_cmd_info "证书 $id 剩余 ${days} 天，跳过续期"
            return 0
        fi
    fi
    tls_lego_installed || {
        vps_cmd_error "尚未安装 lego，无法续期"
        return 3
    }
    tls_valid_email "$TLS_CERT_EMAIL" || {
        vps_cmd_error "证书 $id 缺少有效 email，无法续期"
        return 10
    }
    server="$(tls_lego_server "${TLS_CERT_CA:-letsencrypt}" "${TLS_CERT_STAGING:-0}")" || return 10
    lego_args=(--accept-tos --email "$TLS_CERT_EMAIL" --server "$server" --path "$TLS_ACCOUNT_DIR" --pem)
    for domain in "${domains[@]}"; do
        lego_args+=(--domains "$domain")
    done
    if [[ "$TLS_CERT_CHALLENGE" == http-01 ]]; then
        if tls_http_port_busy "$TLS_HTTP_PORT"; then
            vps_cmd_error "TCP ${TLS_HTTP_PORT} 已被占用，无法续期 $id"
            return 3
        fi
        lego_args+=(--http --http.port ":${TLS_HTTP_PORT}")
    else
        cred="${TLS_CRED_DIR}/${id}.env"
        [[ -f "$cred" && ! -L "$cred" ]] || {
            vps_cmd_error "证书 $id 缺少 DNS 凭证，请先运行 credentials"
            return 3
        }
        lego_args+=(--dns "$(tls_dns_provider_lego "$TLS_CERT_DNS_PROVIDER")")
    fi
    [[ "$force" == 1 ]] && renew_days=10950
    lego_args+=(renew --days "$renew_days")
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：续期 $id"
        tls_run_lego "$cred" "${lego_args[@]}"
        return 0
    fi
    tls_run_lego "$cred" "${lego_args[@]}" || {
        vps_cmd_error "lego 续期失败：$id"
        return 20
    }
    base="$(tls_lego_basename "${domains[0]}")"
    crt="${TLS_ACCOUNT_DIR}/certificates/${base}.pem"
    [[ -f "$crt" ]] || crt="${TLS_ACCOUNT_DIR}/certificates/${base}.crt"
    key="${TLS_ACCOUNT_DIR}/certificates/${base}.key"
    [[ -f "$crt" && -f "$key" ]] || {
        vps_cmd_error "续期后未找到 lego 证书文件：$id"
        return 20
    }
    tls_commit_material "$id" "$TLS_CERT_NAME" acme "$crt" "$key" \
        "$TLS_CERT_CA" "$TLS_CERT_CHALLENGE" "$TLS_CERT_DNS_PROVIDER" "$TLS_CERT_EMAIL" \
        "$TLS_CERT_RELOAD" "$TLS_CERT_STAGING" "${domains[@]}" || return $?
    vps_cmd_success "已续期证书 $id"
    tls_maybe_reload "$TLS_CERT_RELOAD" || return $?
}

tls_renew() {
    local id="" all=0 force=0 failed=0
    local -a ids=()
    while (($#)); do
        case "$1" in
            --id) (($# >= 2)) || { vps_cmd_error "--id 需要值"; return 2; }; [[ -z "$id" ]] || { vps_cmd_error "重复指定 --id"; return 2; }; id="$2"; shift 2 ;;
            --all) all=1; shift ;;
            --force) force=1; shift ;;
            *) vps_cmd_error "renew 未知选项：$1"; return 2 ;;
        esac
    done
    if [[ -n "$id" && "$all" == 1 ]]; then
        vps_cmd_error "--id 与 --all 不能同时使用"
        return 2
    fi
    if [[ -z "$id" && "$all" != 1 ]]; then
        vps_cmd_error "renew 需要 --id 或 --all"
        return 2
    fi
    vps_cmd_require_root || return $?
    tls_ensure_tools renew openssl sha256sum flock || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then return 0; fi
    vps_cmd_lock security-tls || return $?
    if [[ -n "$id" ]]; then
        ids=("$id")
    else
        mapfile -t ids < <(tls_list_ids | sort)
    fi
    ((${#ids[@]} > 0)) || {
        vps_cmd_info "没有可续期的证书"
        return 0
    }
    for id in "${ids[@]}"; do
        if tls_renew_one "$id" "$force"; then
            :
        else
            failed=1
            vps_cmd_warning "证书 $id 续期未完成"
        fi
    done
    ((failed == 0)) || return 30
}

tls_credentials() {
    local id="" file=""
    while (($#)); do
        case "$1" in
            --id) (($# >= 2)) || { vps_cmd_error "--id 需要值"; return 2; }; id="$2"; shift 2 ;;
            --dns-credential-file) (($# >= 2)) || { vps_cmd_error "--dns-credential-file 需要值"; return 2; }; file="$2"; shift 2 ;;
            *) vps_cmd_error "credentials 未知选项：$1"; return 2 ;;
        esac
    done
    tls_valid_id "$id" || { vps_cmd_error "credentials 需要有效的 --id"; return 2; }
    [[ -n "$file" ]] || { vps_cmd_error "credentials 需要 --dns-credential-file"; return 2; }
    vps_cmd_require_root || return $?
    tls_ensure_tools credentials flock || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then return 0; fi
    vps_cmd_lock security-tls || return $?
    tls_require_record "$id" || return $?
    [[ "$TLS_CERT_SOURCE" == acme && "$TLS_CERT_CHALLENGE" == dns-01 ]] || {
        vps_cmd_error "只有 DNS-01 ACME 证书可以更新凭证"
        return 3
    }
    tls_install_credentials "$id" "$TLS_CERT_DNS_PROVIDER" "$file" || return $?
    vps_cmd_success "已更新证书 $id 的 DNS 凭证"
}
