# shellcheck shell=bash
# Private core lifecycle helpers for commands/service/proxy.sh. Sourcing this
# file only defines functions; callers must initialize common.sh first.

_proxy_core_release_repository() {
    case "${1:-}" in
        sing-box) printf 'SagerNet/sing-box' ;;
        xray) printf 'XTLS/Xray-core' ;;
        *) return 2 ;;
    esac
}

_proxy_core_require_name() {
    proxy_core_valid "${1:-}" && return 0
    vps_cmd_error "代理内核必须是 sing-box 或 xray"
    return 2
}

_proxy_core_require_registered() {
    local core="$1" meta binary
    meta="$(proxy_core_meta_path "$core")" || return $?
    binary="$(proxy_core_binary_path "$core")" || return $?
    if [[ -L "$binary" ]]; then
        vps_cmd_error "拒绝使用符号链接形式的 $(proxy_core_label "$core") 二进制：$binary"
        return 3
    fi
    if ! proxy_core_meta_valid "$core" || [[ ! -f "$binary" || ! -x "$binary" ]]; then
        vps_cmd_error "请先安装或登记 $(proxy_core_label "$core") 内核"
        return 3
    fi
    [[ -f "$meta" && ! -L "$meta" ]] || return 3
}

_proxy_core_sha256() {
    local file="$1" value
    command -v sha256sum >/dev/null 2>&1 || {
        vps_cmd_error "代理内核管理需要 sha256sum"
        return 3
    }
    value="$(sha256sum "$file" 2>/dev/null)" || return 20
    value="${value%%[[:space:]]*}"
    value="${value,,}"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 20
    printf '%s' "$value"
}

_proxy_core_binary_version() {
    local core="$1" binary="$2" output version
    case "$core" in
        sing-box) output="$("$binary" version 2>/dev/null)" ;;
        xray) output="$("$binary" version 2>/dev/null)" ;;
        *) return 2 ;;
    esac
    [[ -n "$output" ]] || {
        vps_cmd_error "$(proxy_core_label "$core") 未通过版本冒烟测试"
        return 20
    }
    version="$(printf '%s\n' "$output" | sed -nE 's/.*[^0-9]v?([0-9]+\.[0-9]+\.[0-9]+([._+-][0-9A-Za-z.-]+)?).*/\1/p' | head -n 1)"
    if [[ -z "$version" ]]; then
        version="$(printf '%s\n' "$output" | sed -nE 's/^v?([0-9]+\.[0-9]+\.[0-9]+([._+-][0-9A-Za-z.-]+)?).*/\1/p' | head -n 1)"
    fi
    [[ -n "$version" && "$version" != *$'\n'* ]] || {
        vps_cmd_error "无法识别 $(proxy_core_label "$core") 的版本输出"
        return 20
    }
    printf '%s' "$version"
}

_proxy_core_validate_binary_config() {
    local core="$1" binary="$2" config="$3"
    [[ -f "$binary" && ! -L "$binary" && -x "$binary" ]] || {
        vps_cmd_error "待验证的 $(proxy_core_label "$core") 二进制不安全或不可执行"
        return 3
    }
    [[ -f "$config" && ! -L "$config" ]] || {
        vps_cmd_error "待验证的代理配置不是普通文件"
        return 3
    }
    jq -e . "$config" >/dev/null 2>&1 || {
        vps_cmd_error "$(proxy_core_label "$core") 配置不是有效 JSON"
        return 10
    }
    case "$core" in
        sing-box) "$binary" check -c "$config" >/dev/null 2>&1 ;;
        xray) "$binary" run -test -c "$config" >/dev/null 2>&1 ;;
    esac || {
        vps_cmd_error "新 $(proxy_core_label "$core") 二进制拒绝当前配置"
        return 10
    }
}

_proxy_core_is_musl() {
    local alpine
    alpine="$(vps_cmd_system_path /etc/alpine-release)" || return 1
    [[ -f "$alpine" ]] && return 0
    ldd --version 2>&1 | grep -qi musl
}

_proxy_core_asset_name() {
    local core="$1" version="$2" arch="${PROXY_ARCH}" suffix=""
    case "$core" in
        xray)
            case "$arch" in
                x86_64 | amd64) printf 'Xray-linux-64.zip' ;;
                aarch64 | arm64) printf 'Xray-linux-arm64-v8a.zip' ;;
                armv7l | armv7) printf 'Xray-linux-arm32-v7a.zip' ;;
                *) return 3 ;;
            esac
            ;;
        sing-box)
            case "$arch" in
                x86_64 | amd64) arch=amd64 ;;
                aarch64 | arm64) arch=arm64 ;;
                armv7l | armv7) arch=armv7 ;;
                *) return 3 ;;
            esac
            _proxy_core_is_musl && suffix='-musl'
            printf 'sing-box-%s-linux-%s%s.tar.gz' "$version" "$arch" "$suffix"
            ;;
        *) return 2 ;;
    esac
}

_proxy_core_curl() {
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 \
        --connect-timeout 15 --max-time "$1" -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: vpsctl-proxy' "${@:2}"
}

_proxy_core_xray_dgst_sha256() {
    local file="$1" asset="$2" value=""
    value="$(sed -nE 's/^[[:space:]]*SHA2-256[[:space:]]*=[[:space:]]*([0-9A-Fa-f]{64})[[:space:]]*$/\1/p' "$file" | head -n 1)"
    if [[ -z "$value" ]]; then
        value="$(sed -nE "s|^([0-9A-Fa-f]{64})[[:space:]]+\\*?${asset//./\\.}[[:space:]]*$|\\1|p" "$file" | head -n 1)"
    fi
    value="${value,,}"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || {
        vps_cmd_error "Xray 摘要文件不含可验证的 SHA256"
        return 20
    }
    printf '%s' "$value"
}

# Writes a verified, extracted executable to OUTPUT and release details to INFO.
_proxy_core_fetch_release() {
    local core="$1" requested_tag="$2" output="$3" info="$4" repository api
    local release_json asset_json tag version asset url digest expected actual archive dgst_url dgst extract candidate="" member
    repository="$(_proxy_core_release_repository "$core")" || return $?
    command -v curl >/dev/null 2>&1 || { vps_cmd_error "代理内核下载需要 curl"; return 3; }
    command -v jq >/dev/null 2>&1 || { vps_cmd_error "代理内核下载需要 jq"; return 3; }
    command -v sha256sum >/dev/null 2>&1 || { vps_cmd_error "代理内核下载需要 sha256sum"; return 3; }
    if [[ -n "$requested_tag" ]]; then
        [[ "$requested_tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] || {
            vps_cmd_error "Release tag 格式无效：$requested_tag"
            return 2
        }
        api="https://api.github.com/repos/${repository}/releases/tags/${requested_tag}"
    else
        api="https://api.github.com/repos/${repository}/releases/latest"
    fi
    release_json="${output}.release.json"
    _proxy_core_curl 120 -o "$release_json" "$api" || {
        vps_cmd_error "查询 $(proxy_core_label "$core") 官方 Release 失败"
        return 20
    }
    jq -e '.draft == false and .prerelease == false and ((.tag_name | type) == "string" and (.tag_name | length) > 0) and ((.assets | type) == "array")' \
        "$release_json" >/dev/null 2>&1 || {
        vps_cmd_error "$(proxy_core_label "$core") Release 不是明确声明的稳定版本"
        return 20
    }
    tag="$(jq -r '.tag_name' "$release_json")"
    [[ -z "$requested_tag" || "$tag" == "$requested_tag" ]] || {
        vps_cmd_error "Release API 返回了非请求版本：$tag"
        return 20
    }
    version="${tag#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([._+-][0-9A-Za-z.-]+)?$ ]] || {
        vps_cmd_error "稳定 Release tag 格式不受支持：$tag"
        return 20
    }
    asset="$(_proxy_core_asset_name "$core" "$version")" || {
        vps_cmd_error "当前平台没有受支持的 $(proxy_core_label "$core") Release 资产"
        return 3
    }
    asset_json="$(jq -ce --arg name "$asset" '[.assets[] | select(.name == $name)] | if length == 1 then .[0] else empty end' "$release_json" 2>/dev/null || true)"
    if [[ -z "$asset_json" && "$core" == "sing-box" && "$asset" == *-musl.tar.gz ]]; then
        local musl_alt prefix arch_part
        prefix="sing-box-${version}-linux-"
        arch_part="${asset#"$prefix"}"
        arch_part="${arch_part%-musl.tar.gz}"
        musl_alt="sing-box-${version}-linux-musl-${arch_part}.tar.gz"
        asset_json="$(jq -ce --arg name "$musl_alt" '[.assets[] | select(.name == $name)] | if length == 1 then .[0] else empty end' "$release_json" 2>/dev/null || true)"
        if [[ -n "$asset_json" ]]; then
            asset="$musl_alt"
        fi
    fi
    [[ -n "$asset_json" ]] || {
        vps_cmd_error "官方 Release 中没有唯一的目标资产：$asset"
        return 20
    }
    url="$(jq -r '.browser_download_url' <<<"$asset_json")"
    digest="$(jq -r '.digest // ""' <<<"$asset_json")"
    [[ "$url" == https://github.com/* ]] || {
        vps_cmd_error "Release 资产下载地址不是受信任的 GitHub HTTPS 地址"
        return 20
    }
    archive="${output}.archive"
    _proxy_core_curl 300 -o "$archive" "$url" || {
        vps_cmd_error "下载 $asset 失败"
        return 20
    }
    if [[ "$digest" =~ ^sha256:([0-9A-Fa-f]{64})$ ]]; then
        expected="${BASH_REMATCH[1],,}"
    elif [[ "$core" == "xray" ]]; then
        dgst_url="$(jq -r --arg name "${asset}.dgst" '[.assets[] | select(.name == $name)] | if length == 1 then .[0].browser_download_url else empty end' "$release_json")"
        [[ "$dgst_url" == https://github.com/* ]] || {
            vps_cmd_error "Xray Release 没有可验证的 asset digest 或 .dgst"
            return 20
        }
        dgst="${output}.dgst"
        _proxy_core_curl 120 -o "$dgst" "$dgst_url" || {
            vps_cmd_error "下载 Xray 摘要文件失败"
            return 20
        }
        expected="$(_proxy_core_xray_dgst_sha256 "$dgst" "$asset")" || return $?
    else
        vps_cmd_error "sing-box Release 资产没有可验证的 SHA256 digest"
        return 20
    fi
    actual="$(_proxy_core_sha256 "$archive")" || return $?
    [[ "$actual" == "$expected" ]] || {
        vps_cmd_error "$asset 的 SHA256 校验失败"
        return 20
    }
    extract="${output}.extract"
    mkdir -p -- "$extract" || return 20
    case "$core" in
        xray)
            command -v unzip >/dev/null 2>&1 || { vps_cmd_error "安装 Xray 需要 unzip"; return 3; }
            unzip -q "$archive" xray -d "$extract" >/dev/null 2>&1 || {
                vps_cmd_error "解压 Xray 资产失败"
                return 20
            }
            candidate="${extract}/xray"
            ;;
        sing-box)
            command -v tar >/dev/null 2>&1 || { vps_cmd_error "安装 sing-box 需要 tar"; return 3; }
            member="${asset%.tar.gz}/sing-box"
            tar -xzf "$archive" -C "$extract" "$member" >/dev/null 2>&1 || {
                vps_cmd_error "解压 sing-box 资产失败"
                return 20
            }
            candidate="${extract}/${member}"
            ;;
    esac
    [[ -f "$candidate" && ! -L "$candidate" ]] || {
        vps_cmd_error "Release 资产没有安全的目标可执行文件"
        return 20
    }
    chmod 0755 -- "$candidate" || return 20
    version="$(_proxy_core_binary_version "$core" "$candidate")" || return $?
    [[ "$version" == "${tag#v}" ]] || {
        vps_cmd_error "二进制版本 $version 与 Release $tag 不一致"
        return 20
    }
    cp -- "$candidate" "$output" || return 20
    chmod 0755 -- "$output" || return 20
    actual="$(_proxy_core_sha256 "$output")" || return $?
    jq -n --arg version "$version" --arg release_tag "$tag" --arg sha256 "$actual" \
        '{version:$version,release_tag:$release_tag,sha256:$sha256}' >"$info" || return 20
}

_proxy_core_external_binary() {
    local core="$1" logical path
    for logical in "/usr/local/bin/${core}" "/usr/bin/${core}"; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        if [[ -f "$path" && ! -L "$path" && -x "$path" ]]; then
            printf '%s' "$logical"
            return 0
        fi
    done
    return 1
}

_proxy_core_service_is_managed() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 1
    head -n 2 "$file" | grep -Fqx '# Managed by vpsctl proxy.'
}

_proxy_core_emit_service() {
    local core="$1" binary="$2" config log
    config="$(proxy_core_config_logical "$core")" || return $?
    log="$(proxy_core_log_logical "$core")" || return $?
    case "$PROXY_INIT_SYSTEM" in
        systemd)
            printf '%s\n' '# Managed by vpsctl proxy.'
            cat <<EOF
[Unit]
Description=vpsctl managed $(proxy_core_label "$core") proxy core
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${binary} run -c ${config}
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
            ;;
        openrc)
            cat <<EOF
#!/sbin/openrc-run
# Managed by vpsctl proxy.
description="vpsctl managed $(proxy_core_label "$core") proxy core"
command="${binary}"
command_args="run -c ${config}"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
output_log="${log}"
error_log="${log}"

depend() {
    need net
}
EOF
            ;;
        *) return 3 ;;
    esac
}

_proxy_core_write_meta() {
    local core="$1" binary="$2" owned="$3" version="$4" tag="$5" sha="$6" installed_at="$7"
    local service now json logical
    service="$(proxy_core_service_name "$core")" || return $?
    logical="$(proxy_core_meta_logical "$core")" || return $?
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -n "$installed_at" ]] || installed_at="$now"
    json="$(jq -n --argjson schema "$PROXY_SCHEMA_VERSION" --arg core "$core" --arg binary "$binary" \
        --argjson owned "$owned" --arg version "$version" --arg release_tag "$tag" --arg sha256 "$sha" \
        --arg service "$service" --arg installed_at "$installed_at" --arg updated_at "$now" \
        '{schema_version:$schema,core:$core,binary:$binary,owned:$owned,version:$version,release_tag:$release_tag,sha256:$sha256,service:$service,installed_at:$installed_at,updated_at:$updated_at}')" || return 20
    proxy_atomic_write_json "$logical" 0600 "$json"
}

_proxy_core_render_candidate() {
    local core="$1" output="$2"
    proxy_manifest_ensure || return $?
    proxy_render_config "$core" "$PROXY_MANIFEST" >"$output" || return $?
    chmod 0600 -- "$output" || return 20
}

_proxy_core_remove_tmp() {
    local path="$1" base="${TMPDIR:-/tmp}"
    [[ -n "$path" && "$path" == "${base%/}/vpsctl-proxy."* ]] || return 1
    rm -rf -- "$path"
}

_proxy_core_restore_or_remove() {
    local backup="$1" logical="$2" mode="$3" path
    if [[ -n "$backup" ]]; then
        proxy_restore_backup "$backup" "$logical" "$mode"
    else
        path="$(vps_cmd_system_path "$logical")" || return $?
        rm -f -- "$path"
    fi
}

proxy_core_install() (
    local core="${1:-}" requested_tag="" version_set=0 arg external="" binary_logical owned=true
    local tmp="" candidate_config downloaded info version tag sha service_path service_logical config_logical meta_path pending_path
    local config_backup="" service_backup="" failed=0
    (($# >= 1)) || { vps_cmd_error "install 需要 CORE"; return 2; }
    shift
    while (($#)); do
        arg="$1"
        case "$arg" in
            --version)
                (($# >= 2)) || { vps_cmd_error "--version 需要 TAG"; return 2; }
                ((version_set == 0)) || { vps_cmd_error "--version 不能重复"; return 2; }
                [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] || { vps_cmd_error "Release tag 格式无效：${2:-<空>}"; return 2; }
                requested_tag="$2"; version_set=1; shift 2; continue ;;
            *) vps_cmd_error "install 的未知选项：$arg"; return 2 ;;
        esac
    done
    _proxy_core_require_name "$core" || return $?
    proxy_require_platform || return $?
    vps_cmd_require_root || return $?
    command -v jq >/dev/null 2>&1 || { vps_cmd_error "代理内核管理需要 jq"; return 3; }
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    proxy_ensure_layout || return $?
    meta_path="$(proxy_core_meta_path "$core")" || return $?
    pending_path="$(proxy_core_pending_path "$core")" || return $?
    if proxy_core_registered "$core"; then
        vps_cmd_success "$(proxy_core_label "$core") 已安装，无需更改"
        return 0
    fi
    [[ ! -e "$meta_path" ]] || {
        vps_cmd_error "发现无效的 $(proxy_core_label "$core") 元数据，拒绝覆盖"
        return 3
    }
    [[ ! -e "$pending_path" && ! -L "$pending_path" ]] || {
        vps_cmd_error "发现未处理的 $(proxy_core_label "$core") 待生效状态，请先人工恢复或清理"
        return 30
    }
    external="$(_proxy_core_external_binary "$core" 2>/dev/null || true)"
    if [[ -n "$external" ]]; then
        binary_logical="$external"
        owned=false
    else
        binary_logical="$(proxy_core_default_binary_logical "$core")" || return $?
        local binary_path
        binary_path="$(vps_cmd_system_path "$binary_logical")" || return $?
        [[ ! -e "$binary_path" ]] || {
            vps_cmd_error "目标二进制路径已存在但不是可复用的普通可执行文件：$binary_path"
            return 3
        }
    fi
    service_path="$(proxy_core_service_path "$core")" || return $?
    service_logical="$(proxy_core_service_logical "$core")" || return $?
    config_logical="$(proxy_core_config_logical "$core")" || return $?
    if [[ -e "$service_path" ]] && ! _proxy_core_service_is_managed "$service_path"; then
        vps_cmd_error "拒绝覆盖不受 vpsctl 管理的服务文件：$service_path"
        return 3
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        if [[ "$owned" == "true" ]]; then
            vps_cmd_info "演练：下载并验证 $(proxy_core_label "$core") 官方稳定 Release"
        else
            vps_cmd_info "演练：复用外部普通可执行文件 $binary_logical（owned=false）"
        fi
        vps_cmd_info "演练：写入 $config_logical、$service_logical 和内核元数据；不启动、不启用服务"
        return 0
    fi
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-proxy.XXXXXX")" || return 20
    candidate_config="${tmp}/config.json"
    downloaded="${tmp}/${core}"
    info="${tmp}/release-info.json"
    _proxy_core_render_candidate "$core" "$candidate_config" || { local rc=$?; _proxy_core_remove_tmp "$tmp"; return "$rc"; }
    if [[ "$owned" == "true" ]]; then
        _proxy_core_fetch_release "$core" "$requested_tag" "$downloaded" "$info" || { local rc=$?; _proxy_core_remove_tmp "$tmp"; return "$rc"; }
        version="$(jq -r '.version' "$info")"; tag="$(jq -r '.release_tag' "$info")"; sha="$(jq -r '.sha256' "$info")"
        _proxy_core_validate_binary_config "$core" "$downloaded" "$candidate_config" || { local rc=$?; _proxy_core_remove_tmp "$tmp"; return "$rc"; }
    else
        local external_path
        external_path="$(vps_cmd_system_path "$binary_logical")" || { _proxy_core_remove_tmp "$tmp"; return 3; }
        version="$(_proxy_core_binary_version "$core" "$external_path")" || { local rc=$?; _proxy_core_remove_tmp "$tmp"; return "$rc"; }
        if [[ -n "$requested_tag" && "$version" != "${requested_tag#v}" ]]; then
            vps_cmd_error "外部二进制版本 ${version} 与请求的 ${requested_tag} 不一致；请先单独登记，再使用带强确认的 update"
            _proxy_core_remove_tmp "$tmp"
            return 3
        fi
        sha="$(_proxy_core_sha256 "$external_path")" || { local rc=$?; _proxy_core_remove_tmp "$tmp"; return "$rc"; }
        tag=""
        _proxy_core_validate_binary_config "$core" "$external_path" "$candidate_config" || { local rc=$?; _proxy_core_remove_tmp "$tmp"; return "$rc"; }
    fi
    mkdir -p -- "$(dirname -- "$(proxy_core_config_path "$core")")" "$(dirname -- "$service_path")" \
        "$(dirname -- "$(vps_cmd_system_path "$binary_logical")")" || { _proxy_core_remove_tmp "$tmp"; return 20; }
    [[ ! -f "$(proxy_core_config_path "$core")" ]] || config_backup="$(proxy_backup_file "$core" "$config_logical" config.json)" || { _proxy_core_remove_tmp "$tmp"; return 20; }
    [[ ! -f "$service_path" ]] || service_backup="$(proxy_backup_file "$core" "$service_logical" service)" || { _proxy_core_remove_tmp "$tmp"; return 20; }
    if [[ "$owned" == "true" ]]; then
        proxy_atomic_write_from_file "$downloaded" "$binary_logical" 0755 || failed=1
    fi
    ((failed)) || proxy_atomic_write_from_file "$candidate_config" "$config_logical" 0600 || failed=1
    if ((failed == 0)); then
        _proxy_core_emit_service "$core" "$binary_logical" >"${tmp}/service" || failed=1
    fi
    ((failed)) || proxy_atomic_write_from_file "${tmp}/service" "$service_logical" "$( [[ "$PROXY_INIT_SYSTEM" == systemd ]] && printf 0644 || printf 0755 )" || failed=1
    ((failed)) || _proxy_core_write_meta "$core" "$binary_logical" "$owned" "$version" "$tag" "$sha" "" || failed=1
    ((failed)) || proxy_service_action "$core" reload-manager || failed=1
    if ((failed)); then
        _proxy_core_restore_or_remove "$config_backup" "$config_logical" 0600 || failed=2
        _proxy_core_restore_or_remove "$service_backup" "$service_logical" "$( [[ "$PROXY_INIT_SYSTEM" == systemd ]] && printf 0644 || printf 0755 )" || failed=2
        rm -f -- "$meta_path" || failed=2
        [[ "$owned" != "true" ]] || rm -f -- "$(vps_cmd_system_path "$binary_logical")" || failed=2
        proxy_service_action "$core" reload-manager >/dev/null 2>&1 || failed=2
        _proxy_core_remove_tmp "$tmp"
        ((failed == 2)) && return 30
        return 20
    fi
    _proxy_core_remove_tmp "$tmp"
    vps_cmd_success "$(proxy_core_label "$core") $version 已安装；服务未启动或启用"
    [[ "$owned" == "true" ]] || vps_cmd_info "已复用外部二进制 $binary_logical（owned=false）"
)

_proxy_core_confirm_external_update() {
    local core="$1" confirmed="$2" status token
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] && return 0
    token="UPDATE-EXTERNAL-${core^^}"
    token="${token//-BOX/-BOX}"
    if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == "1" || ! -t 0 || ! -t 1 ]]; then
        [[ "$confirmed" == "1" ]] && return 0
        vps_cmd_error "更新外部二进制要求显式传入 --confirm-external-update"
        return 3
    fi
    vps_cmd_confirm_token "将原地替换并保留外部所有权的 $(proxy_core_label "$core") 二进制" "$token" && return 0
    status=$?
    [[ "$status" == "130" ]] && return 130
    vps_cmd_info "已取消外部二进制更新，未做更改"
    return 1
}

proxy_core_update() (
    local core="${1:-}" requested_tag="" version_set=0 confirmed=0 arg meta binary_logical binary_path owned installed_at
    local tmp downloaded info config version tag sha old_sha binary_backup meta_backup active=0 failed=0 rc
    (($# >= 1)) || { vps_cmd_error "update 需要 CORE"; return 2; }
    shift
    while (($#)); do
        arg="$1"
        case "$arg" in
            --version)
                (($# >= 2)) || { vps_cmd_error "--version 需要 TAG"; return 2; }
                ((version_set == 0)) || { vps_cmd_error "--version 不能重复"; return 2; }
                [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] || { vps_cmd_error "Release tag 格式无效：${2:-<空>}"; return 2; }
                requested_tag="$2"; version_set=1; shift 2; continue ;;
            --confirm-external-update) confirmed=1 ;;
            *) vps_cmd_error "update 的未知选项：$arg"; return 2 ;;
        esac
        shift
    done
    _proxy_core_require_name "$core" || return $?
    proxy_require_platform || return $?
    vps_cmd_require_root || return $?
    _proxy_core_require_registered "$core" || return $?
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    meta="$(proxy_core_meta_path "$core")" || return $?
    binary_logical="$(jq -r '.binary' "$meta")"
    binary_path="$(vps_cmd_system_path "$binary_logical")" || return $?
    owned="$(jq -r '.owned' "$meta")"
    installed_at="$(jq -r '.installed_at // ""' "$meta")"
    [[ ! -L "$binary_path" ]] || { vps_cmd_error "拒绝原地更新符号链接二进制"; return 3; }
    if [[ "$owned" == "false" ]]; then
        if _proxy_core_confirm_external_update "$core" "$confirmed"; then
            :
        else
            rc=$?
            [[ "$rc" == "1" ]] && return 0
            return "$rc"
        fi
    fi
    config="$(proxy_core_config_path "$core")" || return $?
    [[ -f "$config" && ! -L "$config" ]] || { vps_cmd_error "现有配置不安全或不存在：$config"; return 3; }
    if [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]]; then
        vps_cmd_info "演练：下载、校验并原子更新 $binary_logical；不重启服务"
        return 0
    fi
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-proxy.XXXXXX")" || return 20
    downloaded="${tmp}/${core}"; info="${tmp}/release-info.json"
    _proxy_core_fetch_release "$core" "$requested_tag" "$downloaded" "$info" || { rc=$?; _proxy_core_remove_tmp "$tmp"; return "$rc"; }
    _proxy_core_validate_binary_config "$core" "$downloaded" "$config" || { rc=$?; _proxy_core_remove_tmp "$tmp"; return "$rc"; }
    version="$(jq -r '.version' "$info")"; tag="$(jq -r '.release_tag' "$info")"; sha="$(jq -r '.sha256' "$info")"
    old_sha="$(_proxy_core_sha256 "$binary_path")" || { rc=$?; _proxy_core_remove_tmp "$tmp"; return "$rc"; }
    if [[ "$sha" == "$old_sha" ]]; then
        _proxy_core_remove_tmp "$tmp"
        vps_cmd_success "$(proxy_core_label "$core") $version 已是目标版本，无需更改"
        return 0
    fi
    proxy_service_is_active "$core" && active=1
    binary_backup="$(proxy_backup_file "$core" "$binary_logical" binary)" || { _proxy_core_remove_tmp "$tmp"; return 20; }
    meta_backup="$(proxy_backup_file "$core" "$(proxy_core_meta_logical "$core")" core.json)" || { _proxy_core_remove_tmp "$tmp"; return 20; }
    proxy_atomic_write_from_file "$downloaded" "$binary_logical" 0755 || failed=1
    ((failed)) || _proxy_core_write_meta "$core" "$binary_logical" "$owned" "$version" "$tag" "$sha" "$installed_at" || failed=1
    if ((failed)); then
        proxy_restore_backup "$binary_backup" "$binary_logical" 0755 || failed=2
        proxy_restore_backup "$meta_backup" "$(proxy_core_meta_logical "$core")" 0600 || failed=2
        _proxy_core_remove_tmp "$tmp"
        ((failed == 2)) && return 30
        return 20
    fi
    proxy_mark_pending "$core" "core-update" "" "" "$binary_backup" "$meta_backup" || {
        proxy_restore_backup "$binary_backup" "$binary_logical" 0755 || failed=2
        proxy_restore_backup "$meta_backup" "$(proxy_core_meta_logical "$core")" 0600 || failed=2
        _proxy_core_remove_tmp "$tmp"
        ((failed == 2)) && return 30
        return 20
    }
    if ((active)); then
        vps_cmd_warning "内核已更新但服务仍运行旧进程；请显式 restart 应用"
    else
        vps_cmd_info "已记录更新回滚点；下次 start 将应用新版本"
    fi
    _proxy_core_remove_tmp "$tmp"
    vps_cmd_success "$(proxy_core_label "$core") 已更新到 $version；服务未自动重启"
)

_proxy_core_confirm_restart() {
    local core="$1" confirmed="$2" status token
    token="RESTART-${core^^}"
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] && return 0
    if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == "1" || ! -t 0 || ! -t 1 ]]; then
        [[ "$confirmed" == "1" ]] && return 0
        vps_cmd_error "restart 是中断性操作；非交互模式需 --confirm-disruptive"
        return 3
    fi
    vps_cmd_confirm_token "重启会短暂中断 $(proxy_core_label "$core") 连接" "$token" && return 0
    status=$?
    [[ "$status" == "130" ]] && return 130
    vps_cmd_info "已取消重启，服务状态未改变"
    return 1
}

_proxy_core_validate_current_config() {
    local core="$1" config
    proxy_recover_transaction || return $?
    if declare -F proxy_cleanup_orphan_certs >/dev/null 2>&1; then
        proxy_cleanup_orphan_certs "$core" || return $?
    fi
    config="$(proxy_core_config_path "$core")" || return $?
    [[ -f "$config" && ! -L "$config" ]] || {
        vps_cmd_error "当前 $(proxy_core_label "$core") 配置不存在或不是安全的普通文件：$config"
        return 3
    }
    proxy_validate_config_with_binary "$core" "$config"
}

_proxy_core_cleanup_certs_if_available() {
    local core="$1"
    if declare -F proxy_cleanup_orphan_certs >/dev/null 2>&1; then
        proxy_cleanup_orphan_certs "$core"
    fi
}

proxy_core_start() (
    local core="${1:-}" enable=0 arg pending
    (($# >= 1)) || { vps_cmd_error "start 需要 CORE"; return 2; }
    shift
    while (($#)); do
        arg="$1"
        case "$arg" in --enable) enable=1 ;; *) vps_cmd_error "start 的未知选项：$arg"; return 2 ;; esac
        shift
    done
    _proxy_core_require_name "$core" || return $?
    proxy_require_platform || return $?
    vps_cmd_require_root || return $?
    _proxy_core_require_registered "$core" || return $?
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    _proxy_core_validate_current_config "$core" || return $?
    pending="$(proxy_core_pending_path "$core")" || return $?
    if proxy_service_is_active "$core"; then
        [[ ! -e "$pending" ]] || { vps_cmd_error "存在待生效更改；请使用 restart 安全应用"; return 3; }
        ((enable == 0)) || proxy_service_is_enabled "$core" || proxy_service_action "$core" enable || return 20
        vps_cmd_success "$(proxy_core_label "$core") 已在运行"
        return 0
    fi
    proxy_service_action "$core" reload-manager || return 20
    if ! proxy_service_action "$core" start || { [[ "${VPSCTL_DRY_RUN:-0}" != "1" ]] && ! proxy_service_is_active "$core"; }; then
        proxy_service_action "$core" stop >/dev/null 2>&1 || true
        if [[ -e "$pending" ]]; then
            proxy_restore_pending "$core" || return 30
            if proxy_service_action "$core" start && proxy_service_is_active "$core"; then
                _proxy_core_cleanup_certs_if_available "$core" || return 20
                vps_cmd_error "启动失败；已恢复并启动上一版 $(proxy_core_label "$core")"
                return 20
            fi
            vps_cmd_error "启动失败；已回滚文件但无法恢复上一版服务"
            return 30
        fi
        return 20
    fi
    if ((enable)); then
        proxy_service_action "$core" enable || { proxy_service_action "$core" stop >/dev/null 2>&1 || true; return 20; }
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != "1" ]]; then
        proxy_save_lkg "$core" || return 30
        proxy_clear_pending "$core" || return 30
        _proxy_core_cleanup_certs_if_available "$core" || return 20
    fi
    vps_cmd_success "$(proxy_core_label "$core") 已启动"
)

proxy_core_stop() (
    local core="${1:-}" disable=0 arg
    (($# >= 1)) || { vps_cmd_error "stop 需要 CORE"; return 2; }
    shift
    while (($#)); do
        arg="$1"
        case "$arg" in --disable) disable=1 ;; *) vps_cmd_error "stop 的未知选项：$arg"; return 2 ;; esac
        shift
    done
    _proxy_core_require_name "$core" || return $?
    proxy_require_platform || return $?
    vps_cmd_require_root || return $?
    _proxy_core_require_registered "$core" || return $?
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_service_action "$core" stop || return 20
    ((disable == 0)) || proxy_service_action "$core" disable || return 20
    vps_cmd_success "$(proxy_core_label "$core") 已停止"
)

proxy_core_restart() (
    local core="${1:-}" confirmed=0 arg pending rc
    (($# >= 1)) || { vps_cmd_error "restart 需要 CORE"; return 2; }
    shift
    while (($#)); do
        arg="$1"
        case "$arg" in --confirm-disruptive) confirmed=1 ;; *) vps_cmd_error "restart 的未知选项：$arg"; return 2 ;; esac
        shift
    done
    _proxy_core_require_name "$core" || return $?
    proxy_require_platform || return $?
    vps_cmd_require_root || return $?
    _proxy_core_require_registered "$core" || return $?
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    _proxy_core_validate_current_config "$core" || return $?
    if _proxy_core_confirm_restart "$core" "$confirmed"; then
        :
    else
        rc=$?
        [[ "$rc" == "1" ]] && return 0
        return "$rc"
    fi
    pending="$(proxy_core_pending_path "$core")" || return $?
    proxy_service_action "$core" reload-manager || return 20
    if proxy_service_action "$core" restart && { [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] || proxy_service_is_active "$core"; }; then
        if [[ "${VPSCTL_DRY_RUN:-0}" != "1" ]]; then
            proxy_save_lkg "$core" || return 30
            proxy_clear_pending "$core" || return 30
            _proxy_core_cleanup_certs_if_available "$core" || return 20
        fi
        vps_cmd_success "$(proxy_core_label "$core") 已重启，待生效更改已应用"
        return 0
    fi
    if [[ -f "$pending" && ! -L "$pending" ]]; then
        proxy_service_action "$core" stop >/dev/null 2>&1 || true
        if ! proxy_restore_pending "$core"; then
            vps_cmd_error "重启失败，且待生效状态回滚不完整"
            return 30
        fi
        if proxy_service_action "$core" start && proxy_service_is_active "$core"; then
            _proxy_core_cleanup_certs_if_available "$core" || return 20
            vps_cmd_error "重启失败；已恢复并启动上一版 $(proxy_core_label "$core")"
            return 20
        fi
        vps_cmd_error "重启失败；已回滚文件但无法恢复服务"
        return 30
    fi
    proxy_service_is_active "$core" && return 20
    vps_cmd_error "重启失败，服务当前未运行"
    return 30
)

_proxy_core_status_record() {
    local core="$1" installed=false source="none" version="" tag="" binary="" service config nodes pending=false running=false enabled=false
    local meta pending_path
    service="$(proxy_core_service_name "$core")" || return $?
    config="$(proxy_core_config_logical "$core")" || return $?
    meta="$(proxy_core_meta_path "$core")" || return $?
    pending_path="$(proxy_core_pending_path "$core")" || return $?
    nodes="$(proxy_manifest_count "$core" 2>/dev/null || printf 0)"
    if proxy_core_registered "$core"; then
        installed=true
        source="$(jq -r 'if .owned then "vpsctl" else "external" end' "$meta")"
        version="$(jq -r '.version' "$meta")"
        tag="$(jq -r '.release_tag // ""' "$meta")"
        binary="$(jq -r '.binary' "$meta")"
        proxy_service_is_active "$core" && running=true
        proxy_service_is_enabled "$core" && enabled=true
    fi
    [[ ! -e "$pending_path" ]] || pending=true
    jq -n --arg core "$core" --argjson installed "$installed" --arg source "$source" --arg version "$version" \
        --arg release_tag "$tag" --arg binary "$binary" --arg service "$service" --arg config "$config" \
        --argjson nodes "$nodes" --argjson running "$running" --argjson enabled "$enabled" --argjson pending_restart "$pending" \
        '{core:$core,installed:$installed,source:$source,version:$version,release_tag:$release_tag,binary:$binary,service:$service,running:$running,enabled:$enabled,config:$config,nodes:$nodes,pending_restart:$pending_restart}'
}

proxy_core_status() {
    local target=all target_set=0 json=0 arg core record records='[]' total=0 source installed version running enabled pending config nodes
    while (($#)); do
        arg="$1"
        case "$arg" in
            --json) ((json == 0)) || { vps_cmd_error "--json 不能重复"; return 2; }; json=1 ;;
            all | sing-box | xray) ((target_set == 0)) || { vps_cmd_error "status 只能指定一个 CORE"; return 2; }; target="$arg"; target_set=1 ;;
            *) vps_cmd_error "status 的未知参数：$arg"; return 2 ;;
        esac
        shift
    done
    proxy_require_state_access || return $?
    command -v jq >/dev/null 2>&1 || { vps_cmd_error "status 需要 jq"; return 3; }
    for core in sing-box xray; do
        [[ "$target" == all || "$target" == "$core" ]] || continue
        record="$(_proxy_core_status_record "$core")" || return $?
        records="$(jq -cn --argjson records "$records" --argjson record "$record" '$records + [$record]')" || return 20
        nodes="$(jq -r '.nodes' <<<"$record")"
        total=$((total + nodes))
        ((json)) && continue
        installed="$(jq -r '.installed' <<<"$record")"; source="$(jq -r '.source' <<<"$record")"; version="$(jq -r '.version' <<<"$record")"
        running="$(jq -r '.running' <<<"$record")"; enabled="$(jq -r '.enabled' <<<"$record")"; pending="$(jq -r '.pending_restart' <<<"$record")"; config="$(jq -r '.config' <<<"$record")"
        printf '%s 状态\n' "$(proxy_core_label "$core")"
        if [[ "$installed" == true ]]; then
            printf '  安装来源：%s\n' "$( [[ "$source" == vpsctl ]] && printf 'vpsctl 管理' || printf '外部复用' )"
            printf '  版本：%s\n' "$version"
        else
            printf '  安装来源：未安装\n  版本：未安装\n'
        fi
        printf '  运行状态：%s\n' "$( [[ "$running" == true ]] && printf '运行中' || printf '未运行' )"
        printf '  开机启动：%s\n' "$( [[ "$enabled" == true ]] && printf '已启用' || printf '未启用' )"
        printf '  配置文件：%s\n' "$config"
        printf '  节点数：%s\n' "$nodes"
        printf '  待重启：%s\n' "$( [[ "$pending" == true ]] && printf '是' || printf '否' )"
    done
    if ((json)); then
        jq -n --argjson schema "$PROXY_SCHEMA_VERSION" --argjson cores "$records" --argjson total_nodes "$total" \
            '{schema_version:$schema,cores:$cores,total_nodes:$total_nodes}'
    else
        printf '总节点数：%s\n' "$total"
    fi
}

proxy_core_logs() {
    local core="${1:-}" lines=100 follow=0 since="" lines_set=0 follow_set=0 since_set=0 arg service log_path
    (($# >= 1)) || { vps_cmd_error "logs 需要 CORE"; return 2; }
    shift
    while (($#)); do
        arg="$1"
        case "$arg" in
            --lines)
                (($# >= 2)) || { vps_cmd_error "--lines 需要 N"; return 2; }
                ((lines_set == 0)) || { vps_cmd_error "--lines 不能重复"; return 2; }
                [[ "$2" =~ ^[0-9]+$ && ${#2} -le 7 ]] && ((10#$2 <= 1000000)) || { vps_cmd_error "日志行数无效：$2"; return 2; }
                lines="$2"; lines_set=1; shift 2; continue ;;
            --follow)
                ((follow_set == 0)) || { vps_cmd_error "--follow 不能重复"; return 2; }
                follow=1; follow_set=1
                ;;
            --since)
                (($# >= 2)) || { vps_cmd_error "--since 需要 VALUE"; return 2; }
                ((since_set == 0)) || { vps_cmd_error "--since 不能重复"; return 2; }
                [[ -n "$2" && "$2" != *$'\n'* && "$2" != *$'\r'* ]] || { vps_cmd_error "--since 值无效"; return 2; }
                since="$2"; since_set=1; shift 2; continue ;;
            *) vps_cmd_error "logs 的未知选项：$arg"; return 2 ;;
        esac
        shift
    done
    _proxy_core_require_name "$core" || return $?
    proxy_require_platform || return $?
    service="$(proxy_core_service_name "$core")" || return $?
    case "$PROXY_INIT_SYSTEM" in
        systemd)
            local -a args=(-u "${service}.service" --no-pager -n "$lines")
            ((follow == 0)) || args+=(-f)
            [[ -z "$since" ]] || args+=(--since "$since")
            journalctl "${args[@]}" || return 20
            ;;
        openrc)
            [[ -z "$since" ]] || { vps_cmd_error "OpenRC 文件日志不支持 --since"; return 2; }
            log_path="$(proxy_core_log_path "$core")" || return $?
            [[ -f "$log_path" ]] || { vps_cmd_error "日志文件不存在：$log_path"; return 3; }
            if ((follow)); then tail -n "$lines" -f -- "$log_path"; else tail -n "$lines" -- "$log_path"; fi || return 20
            ;;
    esac
}

_proxy_core_confirm_purge() {
    local core="$1" confirmed="$2" status token
    token="PURGE-${core^^}"
    [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] && return 0
    if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == "1" || ! -t 0 || ! -t 1 ]]; then
        [[ "$confirmed" == "1" ]] && return 0
        vps_cmd_error "彻底清除要求显式传入 --confirm-purge"
        return 3
    fi
    vps_cmd_confirm_token "彻底清除会删除该内核的节点、配置、状态与备份" "$token" && return 0
    status=$?
    [[ "$status" == "130" ]] && return 130
    vps_cmd_info "已取消彻底清除，未做更改"
    return 1
}

proxy_core_uninstall() (
    local core="${1:-}" purge=0 confirmed=0 arg meta binary_logical="" binary_path="" owned=false
    local service_path service_logical failed=0 rc config_dir lkg backup_dir log_path
    (($# >= 1)) || { vps_cmd_error "uninstall 需要 CORE"; return 2; }
    shift
    while (($#)); do
        arg="$1"
        case "$arg" in
            --purge) purge=1 ;;
            --confirm-purge) confirmed=1 ;;
            *) vps_cmd_error "uninstall 的未知选项：$arg"; return 2 ;;
        esac
        shift
    done
    ((confirmed == 0 || purge == 1)) || { vps_cmd_error "--confirm-purge 只能与 --purge 一起使用"; return 2; }
    _proxy_core_require_name "$core" || return $?
    proxy_require_platform || return $?
    vps_cmd_require_root || return $?
    vps_cmd_lock proxy || return $?
    trap 'vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    meta="$(proxy_core_meta_path "$core")" || return $?
    service_path="$(proxy_core_service_path "$core")" || return $?
    service_logical="$(proxy_core_service_logical "$core")" || return $?
    if [[ -e "$service_path" ]] && ! _proxy_core_service_is_managed "$service_path"; then
        vps_cmd_error "拒绝删除不受 vpsctl 管理的服务文件：$service_path"
        return 3
    fi
    if proxy_core_meta_valid "$core"; then
        binary_logical="$(jq -r '.binary' "$meta")"
        owned="$(jq -r '.owned' "$meta")"
        binary_path="$(vps_cmd_system_path "$binary_logical")" || return $?
        [[ ! -L "$binary_path" ]] || { vps_cmd_error "拒绝卸载符号链接二进制"; return 3; }
    elif [[ -e "$meta" ]]; then
        vps_cmd_error "内核元数据无效，拒绝猜测二进制所有权"
        return 3
    fi
    if ((purge)); then
        if _proxy_core_confirm_purge "$core" "$confirmed"; then
            :
        else
            rc=$?
            [[ "$rc" == "1" ]] && return 0
            return "$rc"
        fi
        declare -F proxy_purge_core_nodes >/dev/null 2>&1 || {
            vps_cmd_error "运行时缺少 proxy_purge_core_nodes，无法安全清除节点"
            return 3
        }
    fi
    if proxy_service_is_active "$core"; then
        proxy_service_action "$core" stop || return 20
    fi
    if proxy_service_is_enabled "$core"; then
        proxy_service_action "$core" disable || return 20
    fi
    if ((purge)); then
        proxy_purge_core_nodes "$core" || return $?
    fi
    [[ ! -e "$service_path" ]] || vps_cmd_run rm -f "$service_path" || failed=1
    proxy_service_action "$core" reload-manager || failed=1
    if [[ "$owned" == "true" && -n "$binary_path" && -e "$binary_path" ]]; then
        vps_cmd_run rm -f "$binary_path" || failed=1
    fi
    [[ ! -e "$meta" ]] || vps_cmd_run rm -f "$meta" || failed=1
    local pending_path
    pending_path="$(proxy_core_pending_path "$core")" || return $?
    [[ ! -e "$pending_path" ]] || vps_cmd_run rm -f "$pending_path" || failed=1
    if ((purge)); then
        config_dir="$(dirname -- "$(proxy_core_config_path "$core")")"
        lkg="$(proxy_core_lkg_dir "$core")" || return $?
        backup_dir="${PROXY_BACKUP_DIR}/${core}"
        log_path="$(proxy_core_log_path "$core")" || return $?
        [[ "$config_dir" == "${PROXY_ETC_DIR}/"* ]] || return 30
        [[ "$lkg" == "${PROXY_STATE_DIR}/lkg/"* ]] || return 30
        [[ "$backup_dir" == "${PROXY_BACKUP_DIR}/"* ]] || return 30
        [[ ! -e "$config_dir" ]] || vps_cmd_run rm -rf "$config_dir" || failed=1
        [[ ! -e "$lkg" ]] || vps_cmd_run rm -rf "$lkg" || failed=1
        [[ ! -e "$backup_dir" ]] || vps_cmd_run rm -rf "$backup_dir" || failed=1
        [[ ! -e "$log_path" ]] || vps_cmd_run rm -f "$log_path" || failed=1
    fi
    ((failed == 0)) || return 30
    if ((purge)); then
        vps_cmd_success "$(proxy_core_label "$core") 已卸载，节点、配置、状态与备份已清除"
    else
        vps_cmd_success "$(proxy_core_label "$core") 已卸载；配置、节点与备份均保留"
    fi
)
