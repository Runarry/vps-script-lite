# shellcheck shell=bash
# Certificate inventory: import, replace, delete, list, show, paths, status.

tls_commit_material() {
    local id="$1" name="$2" source="$3" fullchain="$4" key="$5"
    local ca="${6:-}" challenge="${7:-}" dns_provider="${8:-}" email="${9:-}"
    local reload="${10:-none}" staging="${11:-0}"
    shift 11 || true
    local fingerprint not_before not_after backup_id="" status=0
    local -a domains=()

    ((${#@} > 0)) || {
        vps_cmd_error "证书缺少域名"
        return 10
    }
    domains=("$@")
    tls_validate_certificate_pair "$fullchain" "$key" || return $?
    tls_domains_covered "$fullchain" "${domains[@]}" || return $?
    fingerprint="$(tls_cert_fingerprint "$fullchain")" || return $?
    not_before="$(tls_cert_startdate "$fullchain")" || return $?
    not_after="$(tls_cert_enddate "$fullchain")" || return $?
    tls_valid_reload "$reload" || reload=none

    TLS_CERT_ID="$id"
    TLS_CERT_NAME="$name"
    TLS_CERT_SOURCE="$source"
    TLS_CERT_CA="$ca"
    TLS_CERT_CHALLENGE="$challenge"
    TLS_CERT_DNS_PROVIDER="$dns_provider"
    TLS_CERT_EMAIL="$email"
    TLS_CERT_DOMAINS="$(tls_join_domains "${domains[@]}")"
    TLS_CERT_NOT_BEFORE="$not_before"
    TLS_CERT_NOT_AFTER="$not_after"
    TLS_CERT_FINGERPRINT="$fingerprint"
    TLS_CERT_RELOAD="$reload"
    TLS_CERT_STAGING="$staging"

    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：写入证书 $id（$name）到 $(tls_live_fullchain_logical "$id")"
        return 0
    fi

    tls_ensure_state_dirs || return $?
    if [[ -f "$(tls_metadata_path "$id")" ]]; then
        backup_id="$(tls_backup_record "$id")" || return $?
        vps_cmd_info "已备份当前证书：$backup_id"
    fi
    tls_archive_material "$id" "$fingerprint" "$fullchain" "$key" || return $?
    tls_install_live "$id" "$fullchain" "$key" || {
        status=$?
        vps_cmd_error "写入 live 证书失败${backup_id:+；备份 ID $backup_id}"
        return "$status"
    }
    tls_write_record "$id" || {
        status=$?
        vps_cmd_error "写入证书 metadata 失败${backup_id:+；备份 ID $backup_id}"
        return 30
    }
}

tls_prepare_fullchain() {
    local cert="$1" chain="${2:-}" dest="$3"
    cat -- "$cert" >"$dest" || return 20
    if [[ -n "$chain" ]]; then
        printf '\n' >>"$dest" || return 20
        cat -- "$chain" >>"$dest" || return 20
    fi
}

tls_import() {
    local name="" cert_file="" key_file="" chain_file="" reload=none
    local resolved_cert resolved_key resolved_chain="" id temp_dir status=0 domains_text
    local -a domains=()
    while (($#)); do
        case "$1" in
            --name) (($# >= 2)) || { vps_cmd_error "--name 需要值"; return 2; }; [[ -z "$name" ]] || { vps_cmd_error "重复指定 --name"; return 2; }; name="$2"; shift 2 ;;
            --cert-file) (($# >= 2)) || { vps_cmd_error "--cert-file 需要值"; return 2; }; [[ -z "$cert_file" ]] || { vps_cmd_error "重复指定 --cert-file"; return 2; }; cert_file="$2"; shift 2 ;;
            --key-file) (($# >= 2)) || { vps_cmd_error "--key-file 需要值"; return 2; }; [[ -z "$key_file" ]] || { vps_cmd_error "重复指定 --key-file"; return 2; }; key_file="$2"; shift 2 ;;
            --chain-file) (($# >= 2)) || { vps_cmd_error "--chain-file 需要值"; return 2; }; [[ -z "$chain_file" ]] || { vps_cmd_error "重复指定 --chain-file"; return 2; }; chain_file="$2"; shift 2 ;;
            --reload) (($# >= 2)) || { vps_cmd_error "--reload 需要值"; return 2; }; reload="$2"; shift 2 ;;
            *) vps_cmd_error "import 未知选项：$1"; return 2 ;;
        esac
    done
    tls_valid_name "$name" || { vps_cmd_error "--name 无效或缺失"; return 2; }
    [[ -n "$cert_file" && -n "$key_file" ]] || { vps_cmd_error "import 需要 --cert-file 与 --key-file"; return 2; }
    tls_valid_reload "$reload" || { vps_cmd_error "--reload 仅支持 none|proxy"; return 2; }
    vps_cmd_require_root || return $?
    tls_ensure_tools import openssl sha256sum flock || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info "依赖仅完成安装计划；请安装依赖后重跑"
        return 0
    fi
    resolved_cert="$(tls_resolve_import_file "$cert_file")" || return $?
    resolved_key="$(tls_resolve_import_file "$key_file")" || return $?
    if [[ -n "$chain_file" ]]; then
        resolved_chain="$(tls_resolve_import_file "$chain_file")" || return $?
    fi
    domains_text="$(tls_cert_sans "$resolved_cert")" || return $?
    mapfile -t domains <<<"$domains_text"
    ((${#domains[@]} > 0)) || { vps_cmd_error "证书没有可用的 DNS SAN 或 CN"; return 10; }

    vps_cmd_lock security-tls || return $?
    id="$(tls_new_id)" || return $?
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-tls-import.XXXXXX")" || return 20
    chmod 0700 -- "$temp_dir" || { rm -rf -- "$temp_dir"; return 20; }
    tls_prepare_fullchain "$resolved_cert" "$resolved_chain" "$temp_dir/fullchain.pem" || {
        status=$?
        rm -rf -- "$temp_dir"
        return "$status"
    }
    cp -- "$resolved_key" "$temp_dir/key.pem" || { rm -rf -- "$temp_dir"; return 20; }
    chmod 0600 -- "$temp_dir/fullchain.pem" "$temp_dir/key.pem" || { rm -rf -- "$temp_dir"; return 20; }
    tls_commit_material "$id" "$name" imported "$temp_dir/fullchain.pem" "$temp_dir/key.pem" \
        "" "" "" "" "$reload" 0 "${domains[@]}" || {
        status=$?
        rm -rf -- "$temp_dir"
        return "$status"
    }
    rm -rf -- "$temp_dir"
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：导入证书 $name"
        return 0
    fi
    vps_cmd_success "已导入证书 $id（$name）"
    tls_maybe_reload "$reload" || return $?
    tls_show_human "$id"
}

tls_replace() {
    local id="" cert_file="" key_file="" chain_file="" reload=""
    local resolved_cert resolved_key resolved_chain="" temp_dir status=0 domains_text
    local -a domains=()
    while (($#)); do
        case "$1" in
            --id) (($# >= 2)) || { vps_cmd_error "--id 需要值"; return 2; }; [[ -z "$id" ]] || { vps_cmd_error "重复指定 --id"; return 2; }; id="$2"; shift 2 ;;
            --cert-file) (($# >= 2)) || { vps_cmd_error "--cert-file 需要值"; return 2; }; [[ -z "$cert_file" ]] || { vps_cmd_error "重复指定 --cert-file"; return 2; }; cert_file="$2"; shift 2 ;;
            --key-file) (($# >= 2)) || { vps_cmd_error "--key-file 需要值"; return 2; }; [[ -z "$key_file" ]] || { vps_cmd_error "重复指定 --key-file"; return 2; }; key_file="$2"; shift 2 ;;
            --chain-file) (($# >= 2)) || { vps_cmd_error "--chain-file 需要值"; return 2; }; [[ -z "$chain_file" ]] || { vps_cmd_error "重复指定 --chain-file"; return 2; }; chain_file="$2"; shift 2 ;;
            --reload) (($# >= 2)) || { vps_cmd_error "--reload 需要值"; return 2; }; reload="$2"; shift 2 ;;
            *) vps_cmd_error "replace 未知选项：$1"; return 2 ;;
        esac
    done
    tls_valid_id "$id" || { vps_cmd_error "replace 需要有效的 --id"; return 2; }
    [[ -n "$cert_file" && -n "$key_file" ]] || { vps_cmd_error "replace 需要 --cert-file 与 --key-file"; return 2; }
    [[ -z "$reload" ]] || tls_valid_reload "$reload" || { vps_cmd_error "--reload 仅支持 none|proxy"; return 2; }
    vps_cmd_require_root || return $?
    tls_ensure_tools replace openssl sha256sum flock || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info "依赖仅完成安装计划；请安装依赖后重跑"
        return 0
    fi
    resolved_cert="$(tls_resolve_import_file "$cert_file")" || return $?
    resolved_key="$(tls_resolve_import_file "$key_file")" || return $?
    if [[ -n "$chain_file" ]]; then
        resolved_chain="$(tls_resolve_import_file "$chain_file")" || return $?
    fi

    vps_cmd_lock security-tls || return $?
    tls_require_record "$id" || return $?
    [[ -n "$reload" ]] || reload="$TLS_CERT_RELOAD"
    domains_text="$(tls_cert_sans "$resolved_cert")" || return $?
    mapfile -t domains <<<"$domains_text"
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-tls-replace.XXXXXX")" || return 20
    chmod 0700 -- "$temp_dir" || { rm -rf -- "$temp_dir"; return 20; }
    tls_prepare_fullchain "$resolved_cert" "$resolved_chain" "$temp_dir/fullchain.pem" || {
        status=$?
        rm -rf -- "$temp_dir"
        return "$status"
    }
    cp -- "$resolved_key" "$temp_dir/key.pem" || { rm -rf -- "$temp_dir"; return 20; }
    tls_commit_material "$id" "$TLS_CERT_NAME" imported "$temp_dir/fullchain.pem" "$temp_dir/key.pem" \
        "" "" "" "" "$reload" 0 "${domains[@]}" || {
        status=$?
        rm -rf -- "$temp_dir"
        return "$status"
    }
    rm -rf -- "$temp_dir"
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：替换证书 $id"
        return 0
    fi
    vps_cmd_success "已替换证书 $id"
    tls_maybe_reload "$reload" || return $?
}

tls_delete() {
    local id="" confirm=0 live_dir record_dir cred
    while (($#)); do
        case "$1" in
            --id) (($# >= 2)) || { vps_cmd_error "--id 需要值"; return 2; }; [[ -z "$id" ]] || { vps_cmd_error "重复指定 --id"; return 2; }; id="$2"; shift 2 ;;
            --confirm-delete) confirm=1; shift ;;
            *) vps_cmd_error "delete 未知选项：$1"; return 2 ;;
        esac
    done
    tls_valid_id "$id" || { vps_cmd_error "delete 需要有效的 --id"; return 2; }
    ((confirm)) || {
        vps_cmd_error "非菜单删除必须传入 --confirm-delete"
        return 2
    }
    vps_cmd_require_root || return $?
    tls_ensure_tools delete flock || return $?
    if [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" == 1 ]]; then
        vps_cmd_info "依赖仅完成安装计划；请安装依赖后重跑"
        return 0
    fi
    vps_cmd_lock security-tls || return $?
    tls_load_record "$id" || return $?
    if tls_proxy_references "$id"; then
        vps_cmd_error "代理节点仍引用证书 $id；请先把节点改为其他证书模式"
        return 3
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：删除证书 $id"
        return 0
    fi
    tls_backup_record "$id" >/dev/null || true
    live_dir="$(tls_live_dir "$id")"
    record_dir="${TLS_CERTS_DIR}/${id}"
    cred="${TLS_CRED_DIR}/${id}.env"
    rm -rf -- "$live_dir" "$record_dir"
    rm -f -- "$cred"
    vps_cmd_success "已删除证书 $id"
}

tls_show_human() {
    local id="$1" state days live_cert style=normal
    tls_load_record "$id" || return $?
    state="$(tls_record_state "$id")"
    live_cert="$(tls_live_fullchain "$id")"
    days=""
    [[ -f "$live_cert" ]] && days="$(tls_days_remaining "$live_cert" 2>/dev/null || true)"
    [[ "$state" == managed ]] && style=success
    [[ "$state" == drift || "$state" == missing ]] && style=warning
    [[ -n "$days" && "$days" -le $TLS_RENEW_DAYS ]] && style=warning
    vps_cmd_status "ID" "$TLS_CERT_ID" emphasis
    vps_cmd_status "名称" "$TLS_CERT_NAME" normal
    vps_cmd_status "来源" "$TLS_CERT_SOURCE" normal
    vps_cmd_status "域名" "$TLS_CERT_DOMAINS" normal
    vps_cmd_status "状态" "$state" "$style"
    vps_cmd_status "指纹" "$TLS_CERT_FINGERPRINT" muted
    vps_cmd_status "到期" "$TLS_CERT_NOT_AFTER" normal
    [[ -z "$days" ]] || vps_cmd_status "剩余天数" "$days" "$style"
    vps_cmd_status "重载" "$TLS_CERT_RELOAD" normal
    vps_cmd_status "fullchain" "$(tls_live_fullchain_logical "$id")" normal
    vps_cmd_status "privkey" "$(tls_live_privkey_logical "$id")" normal
}

tls_show_json_one() {
    local id="$1" state days live_cert
    local -a domains=()
    tls_load_record "$id" || return $?
    state="$(tls_record_state "$id")"
    live_cert="$(tls_live_fullchain "$id")"
    days=""
    [[ -f "$live_cert" ]] && days="$(tls_days_remaining "$live_cert" 2>/dev/null || true)"
    IFS=',' read -r -a domains <<<"$TLS_CERT_DOMAINS"
    printf '{"id":"%s","name":"%s","source":"%s","ca":' \
        "$(tls_json_escape "$TLS_CERT_ID")" "$(tls_json_escape "$TLS_CERT_NAME")" "$(tls_json_escape "$TLS_CERT_SOURCE")"
    if [[ -n "$TLS_CERT_CA" ]]; then printf '"%s"' "$(tls_json_escape "$TLS_CERT_CA")"; else printf 'null'; fi
    printf ',"challenge":'
    if [[ -n "$TLS_CERT_CHALLENGE" ]]; then printf '"%s"' "$(tls_json_escape "$TLS_CERT_CHALLENGE")"; else printf 'null'; fi
    printf ',"dns_provider":'
    if [[ -n "$TLS_CERT_DNS_PROVIDER" ]]; then printf '"%s"' "$(tls_json_escape "$TLS_CERT_DNS_PROVIDER")"; else printf 'null'; fi
    printf ',"domains":'
    tls_json_string_array "${domains[@]}"
    printf ',"state":"%s","fingerprint":"%s","not_before":"%s","not_after":"%s","days_remaining":' \
        "$(tls_json_escape "$state")" "$(tls_json_escape "$TLS_CERT_FINGERPRINT")" \
        "$(tls_json_escape "$TLS_CERT_NOT_BEFORE")" "$(tls_json_escape "$TLS_CERT_NOT_AFTER")"
    if [[ "$days" =~ ^[0-9]+$ ]]; then printf '%s' "$days"; else printf 'null'; fi
    printf ',"expiring_soon":%s,"reload":"%s","staging":%s,"paths":{"fullchain":"%s","privkey":"%s"}}' \
        "$([[ "$days" =~ ^[0-9]+$ && "$days" -le $TLS_RENEW_DAYS ]] && printf true || printf false)" \
        "$(tls_json_escape "$TLS_CERT_RELOAD")" \
        "$([[ "$TLS_CERT_STAGING" == 1 ]] && printf true || printf false)" \
        "$(tls_json_escape "$(tls_live_fullchain_logical "$id")")" \
        "$(tls_json_escape "$(tls_live_privkey_logical "$id")")"
}

tls_show() {
    local id="" json=0
    while (($#)); do
        case "$1" in
            --id) (($# >= 2)) || { vps_cmd_error "--id 需要值"; return 2; }; [[ -z "$id" ]] || { vps_cmd_error "重复指定 --id"; return 2; }; id="$2"; shift 2 ;;
            --json) [[ "$json" == 0 ]] || { vps_cmd_error "重复指定 --json"; return 2; }; json=1; shift ;;
            *) vps_cmd_error "show 未知选项：$1"; return 2 ;;
        esac
    done
    tls_valid_id "$id" || { vps_cmd_error "show 需要有效的 --id"; return 2; }
    if ((json)); then
        tls_show_json_one "$id"
        printf '\n'
    else
        tls_show_human "$id"
    fi
}

tls_paths() {
    local id=""
    while (($#)); do
        case "$1" in
            --id) (($# >= 2)) || { vps_cmd_error "--id 需要值"; return 2; }; [[ -z "$id" ]] || { vps_cmd_error "重复指定 --id"; return 2; }; id="$2"; shift 2 ;;
            *) vps_cmd_error "paths 未知选项：$1"; return 2 ;;
        esac
    done
    tls_valid_id "$id" || { vps_cmd_error "paths 需要有效的 --id"; return 2; }
    tls_load_record "$id" || return $?
    printf 'fullchain %s\n' "$(tls_live_fullchain_logical "$id")"
    printf 'privkey %s\n' "$(tls_live_privkey_logical "$id")"
}

tls_list() {
    local json=0 id first=1
    local -a ids=()
    while (($#)); do
        case "$1" in
            --json) [[ "$json" == 0 ]] || { vps_cmd_error "重复指定 --json"; return 2; }; json=1; shift ;;
            *) vps_cmd_error "list 未知选项：$1"; return 2 ;;
        esac
    done
    mapfile -t ids < <(tls_list_ids | sort)
    if ((json)); then
        printf '{"schema_version":1,"certificates":['
        for id in "${ids[@]}"; do
            ((first)) || printf ','
            first=0
            tls_show_json_one "$id" || return $?
        done
        printf ']}\n'
        return 0
    fi
    if ((${#ids[@]} == 0)); then
        printf '尚未导入或申请证书。\n'
        return 0
    fi
    for id in "${ids[@]}"; do
        tls_show_human "$id" || return $?
        printf '\n'
    done
}

tls_lego_installed() {
    local tag actual expected
    [[ -f "$TLS_LEGO_BIN" && -x "$TLS_LEGO_BIN" && ! -L "$TLS_LEGO_BIN" ]] || return 1
    [[ -f "$TLS_LEGO_META" && ! -L "$TLS_LEGO_META" ]] || return 1
    tag="$(tls_kv_get "$TLS_LEGO_META" tag 2>/dev/null || true)"
    expected="$(tls_kv_get "$TLS_LEGO_META" sha256 2>/dev/null || true)"
    [[ "$tag" == "$TLS_LEGO_VERSION" && "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual="$(tls_sha256 "$TLS_LEGO_BIN" 2>/dev/null || true)"
    [[ "$actual" == "$expected" ]]
}

tls_timer_flags() {
    local enabled=false active=false supported=false
    if [[ "$(tls_init_detected)" == systemd ]] && command -v systemctl >/dev/null 2>&1; then
        supported=true
        systemctl is-enabled --quiet vpsctl-tls-renew.timer >/dev/null 2>&1 && enabled=true
        systemctl is-active --quiet vpsctl-tls-renew.timer >/dev/null 2>&1 && active=true
    fi
    TLS_TIMER_SUPPORTED="$supported"
    TLS_TIMER_ENABLED="$enabled"
    TLS_TIMER_ACTIVE="$active"
}

tls_status() {
    local json="$1" id days
    local -a ids=()
    local total=0 imported=0 acme=0 expiring=0 first=1
    mapfile -t ids < <(tls_list_ids | sort)
    total=${#ids[@]}
    for id in "${ids[@]}"; do
        tls_load_record "$id" || continue
        [[ "$TLS_CERT_SOURCE" == imported ]] && imported=$((imported + 1))
        [[ "$TLS_CERT_SOURCE" == acme ]] && acme=$((acme + 1))
        if [[ -f "$(tls_live_fullchain "$id")" ]]; then
            days="$(tls_days_remaining "$(tls_live_fullchain "$id")" 2>/dev/null || true)"
            [[ "$days" =~ ^[0-9]+$ && "$days" -le $TLS_RENEW_DAYS ]] && expiring=$((expiring + 1))
        fi
    done
    tls_timer_flags
    if [[ "$json" == 1 ]]; then
        printf '{"schema_version":1,"lego_installed":%s,"lego_version":' \
            "$(tls_lego_installed && printf true || printf false)"
        if tls_lego_installed; then printf '"%s"' "$TLS_LEGO_VERSION"; else printf 'null'; fi
        printf ',"timer":{"supported":%s,"enabled":%s,"active":%s},"counts":{"total":%s,"imported":%s,"acme":%s,"expiring_soon":%s},"certificates":[' \
            "$TLS_TIMER_SUPPORTED" "$TLS_TIMER_ENABLED" "$TLS_TIMER_ACTIVE" "$total" "$imported" "$acme" "$expiring"
        for id in "${ids[@]}"; do
            ((first)) || printf ','
            first=0
            tls_show_json_one "$id" || return $?
        done
        printf ']}\n'
        return 0
    fi
    vps_cmd_status "证书数量" "$total" normal
    vps_cmd_status "导入 / ACME" "${imported} / ${acme}" normal
    vps_cmd_status "即将到期" "$expiring" "$([[ "$expiring" == 0 ]] && printf success || printf warning)"
    vps_cmd_status "lego" "$(tls_lego_installed && printf "已安装 $TLS_LEGO_VERSION" || printf 未安装)" \
        "$(tls_lego_installed && printf success || printf muted)"
    vps_cmd_status "续期 timer" \
        "$([[ "$TLS_TIMER_SUPPORTED" == true ]] && { [[ "$TLS_TIMER_ENABLED" == true ]] && printf 已启用 || printf 未启用; } || printf 需要 systemd)" \
        "$([[ "$TLS_TIMER_ENABLED" == true ]] && printf success || printf warning)"
}

tls_dispatch_status() {
    local json=0
    while (($#)); do
        case "$1" in
            --json) [[ "$json" == 0 ]] || { vps_cmd_error "重复指定 --json"; return 2; }; json=1; shift ;;
            *) vps_cmd_error "status 未知选项：$1"; return 2 ;;
        esac
    done
    tls_status "$json"
}
