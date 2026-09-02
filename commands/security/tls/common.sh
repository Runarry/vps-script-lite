# shellcheck shell=bash
# Private helpers for commands/security/tls.sh. Sourcing this file only
# defines functions; callers must invoke tls_init_paths after vps_cmd_init.

readonly TLS_SCHEMA_VERSION=1
readonly TLS_MARKER='# Managed by vpsctl security tls.'
readonly TLS_STATE_LOGICAL='/var/lib/vpsctl/security/tls'
readonly TLS_BACKUP_LOGICAL='/var/lib/vpsctl/backups/security/tls'
readonly TLS_LEGO_LOGICAL='/usr/local/libexec/vpsctl/lego'
readonly TLS_TIMER_SERVICE_LOGICAL='/etc/systemd/system/vpsctl-tls-renew.service'
readonly TLS_TIMER_UNIT_LOGICAL='/etc/systemd/system/vpsctl-tls-renew.timer'
readonly TLS_UNINSTALL_TOKEN='REMOVE-VPSCTL-TLS'
readonly TLS_LEGO_REPOSITORY='go-acme/lego'
readonly TLS_LEGO_VERSION='v5.4.1'
readonly TLS_RENEW_DAYS=30
readonly TLS_HTTP_PORT=80

TLS_STATE_DIR=''
TLS_BACKUP_DIR=''
TLS_LIVE_DIR=''
TLS_CERTS_DIR=''
TLS_ACCOUNT_DIR=''
TLS_CRED_DIR=''
TLS_LEGO_BIN=''
TLS_LEGO_META=''
TLS_TIMER_SERVICE=''
TLS_TIMER_UNIT=''
TLS_GLOBAL_META=''

TLS_CERT_ID=''
TLS_CERT_NAME=''
TLS_CERT_SOURCE=''
TLS_CERT_CA=''
TLS_CERT_CHALLENGE=''
TLS_CERT_DNS_PROVIDER=''
TLS_CERT_EMAIL=''
TLS_CERT_DOMAINS=''
TLS_CERT_NOT_BEFORE=''
TLS_CERT_NOT_AFTER=''
TLS_CERT_FINGERPRINT=''
TLS_CERT_RELOAD=''
TLS_CERT_STAGING=''

tls_init_paths() {
    TLS_STATE_DIR="$(vps_cmd_system_path "$TLS_STATE_LOGICAL")" || return $?
    TLS_BACKUP_DIR="$(vps_cmd_system_path "$TLS_BACKUP_LOGICAL")" || return $?
    TLS_LIVE_DIR="$(vps_cmd_system_path "${TLS_STATE_LOGICAL}/live")" || return $?
    TLS_CERTS_DIR="$(vps_cmd_system_path "${TLS_STATE_LOGICAL}/certs")" || return $?
    TLS_ACCOUNT_DIR="$(vps_cmd_system_path "${TLS_STATE_LOGICAL}/account")" || return $?
    TLS_CRED_DIR="$(vps_cmd_system_path "${TLS_STATE_LOGICAL}/credentials")" || return $?
    TLS_LEGO_BIN="$(vps_cmd_system_path "$TLS_LEGO_LOGICAL")" || return $?
    TLS_LEGO_META="$(vps_cmd_system_path "${TLS_STATE_LOGICAL}/lego.meta")" || return $?
    TLS_TIMER_SERVICE="$(vps_cmd_system_path "$TLS_TIMER_SERVICE_LOGICAL")" || return $?
    TLS_TIMER_UNIT="$(vps_cmd_system_path "$TLS_TIMER_UNIT_LOGICAL")" || return $?
    TLS_GLOBAL_META="$(vps_cmd_system_path "${TLS_STATE_LOGICAL}/metadata")" || return $?
}

tls_physical_to_logical() {
    local path="$1"
    if [[ "${VPSCTL_TESTING:-0}" == 1 ]]; then
        [[ "$path" == "${VPSCTL_SYSTEM_ROOT%/}/"* ]] || return 2
        printf '/%s\n' "${path#"${VPSCTL_SYSTEM_ROOT%/}/"}"
    else
        printf '%s\n' "$path"
    fi
}

tls_require_linux() {
    local kernel
    if [[ "${VPSCTL_TESTING:-0}" == 1 ]]; then
        kernel="${VPSCTL_ENV_KERNEL_NAME:-Linux}"
    else
        kernel="${VPSCTL_ENV_KERNEL_NAME:-$(uname -s 2>/dev/null || true)}"
    fi
    [[ "$kernel" == Linux ]] || {
        vps_cmd_error "security tls 仅支持 Linux"
        return 3
    }
}

tls_init_detected() {
    local init
    if [[ "${VPSCTL_TESTING:-0}" == 1 ]]; then
        init="${VPSCTL_ENV_INIT:-systemd}"
    else
        init="${VPSCTL_ENV_INIT:-}"
        [[ -n "$init" ]] || { [[ -d /run/systemd/system ]] && init=systemd; }
    fi
    printf '%s\n' "${init:-unknown}"
}

tls_require_systemd() {
    local init
    init="$(tls_init_detected)"
    [[ "$init" == systemd ]] || {
        vps_cmd_error "续期 timer 仅支持 systemd；当前 init 为 ${init}"
        return 3
    }
    command -v systemctl >/dev/null 2>&1 || {
        vps_cmd_error "未找到 systemctl"
        return 3
    }
}

tls_ensure_tools() {
    local feature="${1:-}"
    shift || return 2
    vps_cmd_ensure_tools "tls-${feature}" "$@"
}

tls_json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

tls_sha256() {
    local output
    output="$(sha256sum -- "$1" 2>/dev/null)" || return 20
    output="${output%%[[:space:]]*}"
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || return 20
    printf '%s\n' "$output"
}

tls_random_hex() {
    local bytes="${1:-8}" value
    value="$(od -An -N"$bytes" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || return 20
    [[ "$value" =~ ^[0-9a-f]+$ && ${#value} -eq $((bytes * 2)) ]] || return 20
    printf '%s\n' "$value"
}

tls_new_id() {
    local random
    random="$(tls_random_hex 8)" || return $?
    printf 'crt-%s\n' "$random"
}

tls_valid_id() {
    [[ "${1:-}" =~ ^crt-[0-9a-f]{16}$ ]]
}

tls_valid_name() {
    local value="${1:-}"
    [[ -n "$value" && ${#value} -le 64 && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]]
}

tls_valid_email() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

tls_valid_domain() {
    local value="${1:-}" label
    local -a parts=()
    [[ -n "$value" && ${#value} -le 253 && "$value" != *[[:space:]/]* && "$value" != *$'\n'* ]] || return 1
    if [[ "$value" == \*.* ]]; then
        value="${value:2}"
        [[ "$value" != *'*'* ]] || return 1
    else
        [[ "$value" != *'*'* ]] || return 1
    fi
    [[ "$value" == *.* && "$value" != .* && "$value" != *. ]] || return 1
    IFS=. read -r -a parts <<<"$value"
    ((${#parts[@]} >= 2)) || return 1
    for label in "${parts[@]}"; do
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
    return 0
}

tls_valid_reload() {
    case "${1:-}" in none | proxy) return 0 ;; *) return 1 ;; esac
}

tls_dns_provider_lego() {
    case "${1:-}" in
        cloudflare) printf 'cloudflare' ;;
        aliyun) printf 'alidns' ;;
        tencent) printf 'tencentcloud' ;;
        dnspod) printf 'dnspod' ;;
        huawei) printf 'huaweicloud' ;;
        *) return 2 ;;
    esac
}

tls_dns_provider_keys() {
    case "${1:-}" in
        cloudflare) printf '%s\n' CF_DNS_API_TOKEN ;;
        aliyun) printf '%s\n' ALICLOUD_ACCESS_KEY ALICLOUD_SECRET_KEY ;;
        tencent) printf '%s\n' TENCENTCLOUD_SECRET_ID TENCENTCLOUD_SECRET_KEY ;;
        dnspod) printf '%s\n' DNSPOD_API_KEY ;;
        huawei) printf '%s\n' HUAWEICLOUD_ACCESS_KEY_ID HUAWEICLOUD_SECRET_ACCESS_KEY ;;
        *) return 2 ;;
    esac
}

tls_dns_provider_optional_keys() {
    case "${1:-}" in
        cloudflare) printf '%s\n' CF_ZONE_API_TOKEN CF_API_EMAIL CF_API_KEY ;;
        aliyun) printf '%s\n' ALICLOUD_REGION_ID ;;
        tencent) printf '%s\n' TENCENTCLOUD_REGION ;;
        dnspod) printf '%s\n' DNSPOD_HTTP_TIMEOUT ;;
        huawei) printf '%s\n' HUAWEICLOUD_REGION ;;
        *) return 0 ;;
    esac
}

tls_kv_get() {
    local file="$1" key="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    awk -F= -v wanted="$key" '$1 == wanted { print substr($0, length($1) + 2); found=1; exit } END { if (!found) exit 1 }' "$file"
}

tls_atomic_file() {
    local logical="$1" mode="$2"
    vps_cmd_atomic_write "$logical" "$mode"
}

tls_ensure_state_dirs() {
    local path
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：创建证书状态目录"
        return 0
    fi
    for path in "$TLS_STATE_DIR" "$TLS_LIVE_DIR" "$TLS_CERTS_DIR" "$TLS_ACCOUNT_DIR" "$TLS_CRED_DIR" "$TLS_BACKUP_DIR"; do
        mkdir -p -- "$path" || return 20
        vps_cmd_require_no_symlink_components "$path" || return $?
        chmod 0700 -- "$path" || return 20
    done
}

tls_resolve_import_file() {
    local source="$1" resolved=""
    [[ "$source" == /* ]] || {
        vps_cmd_error "证书和私钥必须使用绝对路径"
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
    vps_cmd_require_no_symlink_components "$resolved" || return $?
    printf '%s' "$resolved"
}

tls_cert_fingerprint() {
    local certificate="$1" fingerprint
    fingerprint="$(openssl x509 -in "$certificate" -noout -fingerprint -sha256 2>/dev/null | awk -F= 'NR==1 { gsub(":", "", $2); print tolower($2) }')"
    [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 20
    printf '%s\n' "$fingerprint"
}

tls_cert_enddate() {
    local certificate="$1" value
    value="$(openssl x509 -in "$certificate" -noout -enddate 2>/dev/null)" || return 20
    value="${value#notAfter=}"
    [[ -n "$value" ]] || return 20
    printf '%s\n' "$value"
}

tls_cert_startdate() {
    local certificate="$1" value
    value="$(openssl x509 -in "$certificate" -noout -startdate 2>/dev/null)" || return 20
    value="${value#notBefore=}"
    [[ -n "$value" ]] || return 20
    printf '%s\n' "$value"
}

tls_days_remaining() {
    local certificate="$1" low=0 high=4000 mid
    openssl x509 -in "$certificate" -noout -checkend 0 >/dev/null 2>&1 || {
        printf '0\n'
        return 0
    }
    while ((low < high)); do
        mid=$(((low + high + 1) / 2))
        if openssl x509 -in "$certificate" -noout -checkend $((mid * 86400)) >/dev/null 2>&1; then
            low=$mid
        else
            high=$((mid - 1))
        fi
    done
    printf '%s\n' "$low"
}

tls_dns_covers() {
    local requested="${1,,}" san="${2,,}" prefix
    [[ "$requested" == "$san" ]] && return 0
    [[ "$san" == \*.* ]] || return 1
    prefix="${requested%"${san:1}"}"
    [[ "$requested" == "${prefix}${san:1}" && -n "$prefix" && "$prefix" != *.* ]]
}

tls_cert_sans() {
    local certificate="$1" output cn
    local -a sans=()
    output="$(openssl x509 -in "$certificate" -noout -ext subjectAltName 2>/dev/null || true)"
    if [[ "$output" != *DNS:* ]]; then
        output="$(openssl x509 -in "$certificate" -noout -text 2>/dev/null || true)"
    fi
    while [[ "$output" =~ DNS:([A-Za-z0-9*.-]+) ]]; do
        sans+=("${BASH_REMATCH[1]}")
        output="${output#*"${BASH_REMATCH[0]}"}"
    done
    if ((${#sans[@]} == 0)); then
        cn="$(openssl x509 -in "$certificate" -noout -subject -nameopt RFC2253 2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p')"
        [[ -n "$cn" ]] && sans+=("$cn")
    fi
    ((${#sans[@]} > 0)) || return 10
    printf '%s\n' "${sans[@]}"
}

tls_domains_covered() {
    local certificate="$1"
    shift
    local requested san covered
    local -a sans=()
    local sans_text
    sans_text="$(tls_cert_sans "$certificate")" || return $?
    mapfile -t sans <<<"$sans_text"
    for requested in "$@"; do
        covered=0
        for san in "${sans[@]}"; do
            if tls_dns_covers "$requested" "$san"; then
                covered=1
                break
            fi
        done
        ((covered)) || {
            vps_cmd_error "证书不覆盖域名：$requested"
            return 10
        }
    done
}

tls_validate_certificate_pair() {
    local certificate="$1" key="$2" cert_pub key_pub
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
}

tls_metadata_path() {
    printf '%s/%s/metadata' "$TLS_CERTS_DIR" "$1"
}

tls_live_dir() {
    printf '%s/%s' "$TLS_LIVE_DIR" "$1"
}

tls_live_fullchain() {
    printf '%s/%s/fullchain.pem' "$TLS_LIVE_DIR" "$1"
}

tls_live_privkey() {
    printf '%s/%s/privkey.pem' "$TLS_LIVE_DIR" "$1"
}

tls_live_fullchain_logical() {
    printf '%s/live/%s/fullchain.pem' "$TLS_STATE_LOGICAL" "$1"
}

tls_live_privkey_logical() {
    printf '%s/live/%s/privkey.pem' "$TLS_STATE_LOGICAL" "$1"
}

tls_list_ids() {
    local meta id
    [[ -d "$TLS_CERTS_DIR" ]] || return 0
    local -a metas=()
    shopt -s nullglob
    metas=("$TLS_CERTS_DIR"/crt-*/metadata)
    shopt -u nullglob
    for meta in "${metas[@]}"; do
        [[ -f "$meta" && ! -L "$meta" ]] || continue
        id="$(basename -- "$(dirname -- "$meta")")"
        tls_valid_id "$id" || continue
        printf '%s\n' "$id"
    done
}

tls_clear_record() {
    TLS_CERT_ID=''
    TLS_CERT_NAME=''
    TLS_CERT_SOURCE=''
    TLS_CERT_CA=''
    TLS_CERT_CHALLENGE=''
    TLS_CERT_DNS_PROVIDER=''
    TLS_CERT_EMAIL=''
    TLS_CERT_DOMAINS=''
    TLS_CERT_NOT_BEFORE=''
    TLS_CERT_NOT_AFTER=''
    TLS_CERT_FINGERPRINT=''
    TLS_CERT_RELOAD='none'
    TLS_CERT_STAGING='0'
}

tls_load_record() {
    local id="$1" meta
    tls_clear_record
    tls_valid_id "$id" || {
        vps_cmd_error "证书 ID 无效：$id"
        return 2
    }
    meta="$(tls_metadata_path "$id")"
    [[ -f "$meta" && ! -L "$meta" ]] || {
        vps_cmd_error "未找到证书：$id"
        return 3
    }
    TLS_CERT_ID="$(tls_kv_get "$meta" id)" || return 10
    TLS_CERT_NAME="$(tls_kv_get "$meta" name)" || return 10
    TLS_CERT_SOURCE="$(tls_kv_get "$meta" source)" || return 10
    TLS_CERT_CA="$(tls_kv_get "$meta" ca 2>/dev/null || true)"
    TLS_CERT_CHALLENGE="$(tls_kv_get "$meta" challenge 2>/dev/null || true)"
    TLS_CERT_DNS_PROVIDER="$(tls_kv_get "$meta" dns_provider 2>/dev/null || true)"
    TLS_CERT_EMAIL="$(tls_kv_get "$meta" email 2>/dev/null || true)"
    TLS_CERT_DOMAINS="$(tls_kv_get "$meta" domains)" || return 10
    TLS_CERT_NOT_BEFORE="$(tls_kv_get "$meta" not_before 2>/dev/null || true)"
    TLS_CERT_NOT_AFTER="$(tls_kv_get "$meta" not_after)" || return 10
    TLS_CERT_FINGERPRINT="$(tls_kv_get "$meta" fingerprint)" || return 10
    TLS_CERT_RELOAD="$(tls_kv_get "$meta" reload 2>/dev/null || printf none)"
    TLS_CERT_STAGING="$(tls_kv_get "$meta" staging 2>/dev/null || printf 0)"
    [[ "$TLS_CERT_ID" == "$id" ]] || return 10
    [[ "$TLS_CERT_SOURCE" == imported || "$TLS_CERT_SOURCE" == acme ]] || return 10
    [[ "$TLS_CERT_FINGERPRINT" =~ ^[a-f0-9]{64}$ ]] || return 10
    tls_valid_reload "$TLS_CERT_RELOAD" || TLS_CERT_RELOAD=none
}

tls_emit_record() {
    printf 'schema_version=%s\n' "$TLS_SCHEMA_VERSION"
    printf 'id=%s\n' "$TLS_CERT_ID"
    printf 'name=%s\n' "$TLS_CERT_NAME"
    printf 'source=%s\n' "$TLS_CERT_SOURCE"
    printf 'ca=%s\n' "$TLS_CERT_CA"
    printf 'challenge=%s\n' "$TLS_CERT_CHALLENGE"
    printf 'dns_provider=%s\n' "$TLS_CERT_DNS_PROVIDER"
    printf 'email=%s\n' "$TLS_CERT_EMAIL"
    printf 'domains=%s\n' "$TLS_CERT_DOMAINS"
    printf 'not_before=%s\n' "$TLS_CERT_NOT_BEFORE"
    printf 'not_after=%s\n' "$TLS_CERT_NOT_AFTER"
    printf 'fingerprint=%s\n' "$TLS_CERT_FINGERPRINT"
    printf 'reload=%s\n' "$TLS_CERT_RELOAD"
    printf 'staging=%s\n' "$TLS_CERT_STAGING"
}

tls_live_fingerprint() {
    local id="$1" cert
    cert="$(tls_live_fullchain "$id")"
    [[ -f "$cert" && ! -L "$cert" ]] || return 1
    tls_cert_fingerprint "$cert"
}

tls_record_state() {
    local id="$1" live_fp
    tls_load_record "$id" || return $?
    live_fp="$(tls_live_fingerprint "$id" 2>/dev/null || true)"
    if [[ -z "$live_fp" ]]; then
        printf 'missing'
        return 0
    fi
    if [[ "$live_fp" != "$TLS_CERT_FINGERPRINT" ]]; then
        printf 'drift'
        return 0
    fi
    printf 'managed'
}

tls_require_record() {
    local id="$1" state
    state="$(tls_record_state "$id")" || return $?
    [[ "$state" == managed ]] || {
        vps_cmd_error "证书 $id 状态为 ${state}；请先审查 live 文件与 metadata"
        return 30
    }
    tls_load_record "$id" || return $?
}

tls_domains_array() {
    local IFS=','
    # shellcheck disable=SC2206
    TLS_DOMAIN_ITEMS=(${TLS_CERT_DOMAINS})
}

tls_join_domains() {
    local IFS=,
    printf '%s' "$*"
}

tls_dedupe_domains() {
    local domain
    local -a out=()
    local -A seen=()
    for domain in "$@"; do
        domain="${domain,,}"
        domain="$(vps_cmd_trim "$domain")"
        [[ -n "$domain" ]] || continue
        tls_valid_domain "$domain" || {
            vps_cmd_error "域名无效：$domain"
            return 2
        }
        [[ -z "${seen[$domain]:-}" ]] || continue
        seen[$domain]=1
        out+=("$domain")
    done
    ((${#out[@]} > 0)) || {
        vps_cmd_error "至少需要一个域名"
        return 2
    }
    printf '%s\n' "${out[@]}"
}

tls_proxy_references() {
    local id="$1" manifest
    manifest="$(vps_cmd_system_path /var/lib/vpsctl/service/proxy/nodes.json 2>/dev/null || true)"
    [[ -n "$manifest" && -f "$manifest" && ! -L "$manifest" ]] || return 1
    grep -Fq -- "$id" "$manifest"
}

tls_backup_record() {
    local id="$1" backup_id directory live_cert live_key meta
    backup_id="bak-$(date -u +%Y%m%dT%H%M%SZ)-$(tls_random_hex 8)" || return 20
    directory="${TLS_BACKUP_DIR}/${backup_id}"
    mkdir -p -- "$directory" || return 20
    chmod 0700 -- "$directory" || return 20
    live_cert="$(tls_live_fullchain "$id")"
    live_key="$(tls_live_privkey "$id")"
    meta="$(tls_metadata_path "$id")"
    [[ -f "$live_cert" && ! -L "$live_cert" ]] && cp -p -- "$live_cert" "$directory/fullchain.pem"
    [[ -f "$live_key" && ! -L "$live_key" ]] && cp -p -- "$live_key" "$directory/privkey.pem"
    [[ -f "$meta" && ! -L "$meta" ]] && cp -p -- "$meta" "$directory/metadata"
    {
        printf 'schema_version\t%s\n' "$TLS_SCHEMA_VERSION"
        printf 'id\t%s\n' "$id"
        printf 'kind\ttls-cert\n'
        printf 'lifecycle\tactive\n'
    } >"$directory/manifest" || return 20
    chmod 0600 -- "$directory/manifest" || return 20
    printf '%s\n' "$backup_id"
}

tls_install_live() {
    local id="$1" fullchain="$2" key="$3" live_dir cert_logical key_logical
    live_dir="$(tls_live_dir "$id")"
    mkdir -p -- "$live_dir" || return 20
    vps_cmd_require_no_symlink_components "$live_dir" || return $?
    chmod 0700 -- "$live_dir" || return 20
    cert_logical="$(tls_live_fullchain_logical "$id")"
    key_logical="$(tls_live_privkey_logical "$id")"
    tls_atomic_file "$cert_logical" 0640 <"$fullchain" || return 20
    tls_atomic_file "$key_logical" 0600 <"$key" || return 20
}

tls_write_record() {
    local id="$1" dir logical
    dir="${TLS_CERTS_DIR}/${id}"
    mkdir -p -- "$dir" || return 20
    chmod 0700 -- "$dir" || return 20
    logical="${TLS_STATE_LOGICAL}/certs/${id}/metadata"
    tls_emit_record | tls_atomic_file "$logical" 0600 || return 20
}

tls_archive_material() {
    local id="$1" fingerprint="$2" fullchain="$3" key="$4" dest
    dest="${TLS_CERTS_DIR}/${id}/archive/${fingerprint}"
    mkdir -p -- "$dest" || return 20
    chmod 0700 -- "$dest" || return 20
    if [[ -f "$dest/fullchain.pem" || -f "$dest/privkey.pem" ]]; then
        [[ -f "$dest/fullchain.pem" && ! -L "$dest/fullchain.pem" && -f "$dest/privkey.pem" && ! -L "$dest/privkey.pem" ]] || {
            vps_cmd_error "归档证书不完整：$dest"
            return 30
        }
        return 0
    fi
    cp -- "$fullchain" "$dest/fullchain.pem" || return 20
    cp -- "$key" "$dest/privkey.pem" || return 20
    chmod 0640 -- "$dest/fullchain.pem" || return 20
    chmod 0600 -- "$dest/privkey.pem" || return 20
}

tls_json_string_array() {
    local first=1 value
    printf '['
    for value in "$@"; do
        ((first)) || printf ','
        first=0
        printf '"%s"' "$(tls_json_escape "$value")"
    done
    printf ']'
}

tls_lego_arch() {
    local arch="${VPSCTL_ENV_ARCH:-}"
    [[ -n "$arch" ]] || arch="$(uname -m 2>/dev/null || true)"
    case "$arch" in
        x86_64 | amd64) printf 'amd64' ;;
        aarch64 | arm64) printf 'arm64' ;;
        *)
            vps_cmd_error "lego 仅支持 x86_64 与 aarch64，当前架构：${arch:-未知}"
            return 3
            ;;
    esac
}

tls_vpsctl_exec_line() {
    local entry
    if [[ -n "${VPSCTL_MANAGED_ENTRY:-}" && -x "${VPSCTL_MANAGED_ENTRY}" && ! -L "${VPSCTL_MANAGED_ENTRY}" ]]; then
        printf '%s --non-interactive --no-color security tls renew --all' "$VPSCTL_MANAGED_ENTRY"
        return 0
    fi
    entry=/usr/local/bin/vpsctl
    if [[ -x "$entry" && ! -L "$entry" ]]; then
        printf '%s --non-interactive --no-color security tls renew --all' "$entry"
        return 0
    fi
    printf '/bin/bash %s --non-interactive --no-color security tls renew --all' "${TLS_PROJECT_ROOT}/bin/vpsctl"
}
