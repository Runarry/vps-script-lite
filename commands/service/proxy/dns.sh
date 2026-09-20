# shellcheck shell=bash
# sing-box DNS settings, rendering, and transactional CLI/menu helpers.

# Load only the pure address validators so standalone common.sh callers do not
# gain forwarding callbacks that require the full proxy command environment.
if ! declare -F _proxy_relay_forward_valid_host_value >/dev/null 2>&1; then
    # shellcheck source=address.sh
    source "${BASH_SOURCE[0]%/*}/address.sh"
fi

proxy_dns_settings_default() {
    printf '%s\n' '{"mode":"system","server":null,"port":null,"tls_server_name":null,"path":null,"bootstrap":null}'
}

_proxy_dns_is_ip() {
    _proxy_relay_forward_valid_ipv4 "${1:-}" || _proxy_relay_forward_valid_ipv6 "${1:-}"
}

_proxy_dns_path_valid() {
    proxy_valid_path "${1:-}" && [[ "$1" != *[[:space:][:cntrl:]#]* ]]
}

proxy_dns_settings_validate() {
    local settings="${1:-}" mode server tls_server_name path bootstrap
    jq -e '
        type == "object" and
        keys == ["bootstrap", "mode", "path", "port", "server", "tls_server_name"] and
        (.mode == "system" or .mode == "system-native" or .mode == "udp" or
         .mode == "tcp" or .mode == "dot" or .mode == "doh") and
        all(.server, .tls_server_name, .path, .bootstrap;
            . == null or (type == "string" and length > 0 and
                          (test("[[:space:][:cntrl:]]") | not))) and
        (if .mode == "system" or .mode == "system-native" then
             .server == null and .port == null and .tls_server_name == null and
             .path == null and .bootstrap == null
         else
             (.server | type) == "string" and (.port | type) == "number" and
             .port == (.port | floor) and .port >= 1 and .port <= 65535 and
             (if .mode == "doh" then (.path | type) == "string" else .path == null end) and
             (if .mode == "udp" or .mode == "tcp" then .tls_server_name == null else true end)
         end)
    ' <<<"$settings" >/dev/null 2>&1 || {
        vps_cmd_error "DNS 设置格式无效或包含不适用于该模式的字段"
        return 10
    }
    mode="$(jq -r '.mode' <<<"$settings")" || return 10
    case "$mode" in system | system-native) return 0 ;; esac
    server="$(jq -r '.server' <<<"$settings")" || return 10
    tls_server_name="$(jq -r '.tls_server_name // empty' <<<"$settings")" || return 10
    path="$(jq -r '.path // empty' <<<"$settings")" || return 10
    bootstrap="$(jq -r '.bootstrap // empty' <<<"$settings")" || return 10
    _proxy_relay_forward_valid_host_value "$server" || {
        vps_cmd_error "DNS 上游必须为有效 IP 或域名，不接受 URL、端口或方括号：$server"
        return 10
    }
    if [[ -n "$tls_server_name" ]] && ! _proxy_relay_forward_valid_host_value "$tls_server_name"; then
        vps_cmd_error "DNS TLS server name 必须为有效域名或 IP"
        return 10
    fi
    if [[ "$mode" == doh ]] && ! _proxy_dns_path_valid "$path"; then
        vps_cmd_error "DoH 路径必须以 / 开头，最长 256 字符，不能含空白、控制字符或 #"
        return 10
    fi
    if [[ -n "$bootstrap" ]]; then
        _proxy_dns_is_ip "$bootstrap" || {
            vps_cmd_error "DNS bootstrap 必须为 IP 地址（使用 UDP 53）"
            return 10
        }
        if _proxy_dns_is_ip "$server"; then
            vps_cmd_error "IP 上游无需 bootstrap；该选项只适用于域名上游"
            return 10
        fi
    fi
}

proxy_dns_settings_get() {
    local manifest="${1:-}" settings
    if [[ ! -e "$manifest" && ! -L "$manifest" ]]; then
        proxy_dns_settings_default
        return
    fi
    [[ -f "$manifest" && ! -L "$manifest" ]] || return 10
    settings="$(jq -ce '
        if (.settings.sing_box | type) == "object" and (.settings.sing_box | has("dns"))
        then .settings.sing_box.dns
        else {mode:"system",server:null,port:null,tls_server_name:null,path:null,bootstrap:null} end
    ' "$manifest")" || return 10
    proxy_dns_settings_validate "$settings" || return $?
    printf '%s\n' "$settings"
}

proxy_dns_render() {
    local settings="${1:-}" version="${2:-}" server="" use_go=false needs_bootstrap=false
    proxy_dns_settings_validate "$settings" || return $?
    proxy_core_version_at_least "$version" 1.12.0 || {
        vps_cmd_error "sing-box DNS 设置需要 1.12.0 或更高版本"
        return 10
    }
    proxy_core_version_at_least "$version" 1.13.0 && use_go=true
    server="$(jq -r '.server // empty' <<<"$settings")" || return 10
    if [[ -n "$server" ]] && ! _proxy_dns_is_ip "$server"; then
        needs_bootstrap=true
    fi
    jq -cn --argjson settings "$settings" --argjson use_go "$use_go" \
        --argjson needs_bootstrap "$needs_bootstrap" '
        def local_server($tag; $prefer_go):
            {type:"local",tag:$tag} + (if $prefer_go then {prefer_go:true} else {} end);
        $settings as $s |
        (if $s.mode == "system" or $s.mode == "system-native" then
             local_server("proxy-dns"; ($use_go and $s.mode == "system"))
         else
             {type:(if $s.mode == "dot" then "tls" elif $s.mode == "doh" then "https" else $s.mode end),
              tag:"proxy-dns",server:$s.server,server_port:$s.port} +
             (if $s.mode == "dot" or $s.mode == "doh" then
                  {tls:({enabled:true} + (if $s.tls_server_name != null then {server_name:$s.tls_server_name} else {} end))}
              else {} end) +
             (if $s.mode == "doh" then {path:$s.path} else {} end) +
             (if $needs_bootstrap then {domain_resolver:"proxy-dns-bootstrap"} else {} end)
         end) as $upstream |
        (if $needs_bootstrap then
             [if $s.bootstrap == null then local_server("proxy-dns-bootstrap"; $use_go)
              else {type:"udp",tag:"proxy-dns-bootstrap",server:$s.bootstrap,server_port:53} end]
         else [] end) as $bootstrap |
        {dns:{servers:([$upstream] + $bootstrap),final:"proxy-dns"},
         route:{default_domain_resolver:"proxy-dns"}}
    ' || return 10
}

_proxy_dns_core_valid() {
    [[ "${1:-}" == sing-box ]] || {
        vps_cmd_error "DNS 设置仅支持 --core sing-box"
        return 2
    }
}

_proxy_dns_require_core() {
    local version
    proxy_core_registered sing-box || {
        vps_cmd_error "请先安装或登记 sing-box 内核"
        return 3
    }
    version="$(proxy_core_config_version sing-box)" || return $?
    proxy_core_version_at_least "$version" 1.12.0 || {
        vps_cmd_error "DNS 设置需要 sing-box 1.12.0 或更高版本（当前：${version:-未知}）"
        return 3
    }
}

proxy_dns_show() {
    local core=sing-box core_seen=0 output_json=0 settings source=default version="" installed=false
    local effective pending pending_restart=false pending_reason=null rendered mode server bootstrap
    while (($#)); do
        case "$1" in
            --core)
                ((core_seen == 0)) || { vps_cmd_error "参数不可重复：--core"; return 2; }
                if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
                    vps_cmd_error "--core 需要一个非空值"; return 2
                fi
                core="$2"; core_seen=1; shift 2
                ;;
            --json)
                ((output_json == 0)) || { vps_cmd_error "参数不可重复：--json"; return 2; }
                output_json=1; shift
                ;;
            *) vps_cmd_error "未知 dns show 参数：$1"; return 2 ;;
        esac
    done
    _proxy_dns_core_valid "$core" || return $?
    vps_cmd_require_root || return $?
    command -v jq >/dev/null 2>&1 || { vps_cmd_error "查看 DNS 设置需要 jq"; return 3; }
    if [[ -e "$PROXY_MANIFEST" || -L "$PROXY_MANIFEST" ]]; then
        proxy_manifest_validate_file "$PROXY_MANIFEST" || return $?
        if jq -e '(.settings.sing_box | type) == "object" and (.settings.sing_box | has("dns"))' "$PROXY_MANIFEST" >/dev/null; then
            source=saved
        fi
    fi
    settings="$(proxy_dns_settings_get "$PROXY_MANIFEST")" || return $?
    if proxy_core_registered sing-box; then
        installed=true
        version="$(proxy_core_config_version sing-box)" || return $?
        if proxy_core_version_at_least "$version" 1.12.0; then
            effective="$(proxy_dns_render "$settings" "$version")" || return $?
        elif [[ "$source" == saved ]]; then
            vps_cmd_error "已保存的 DNS 设置需要 sing-box 1.12.0 或更高版本"
            return 10
        elif [[ -f "$PROXY_MANIFEST" ]]; then
            rendered="$(proxy_render_config sing-box "$PROXY_MANIFEST")" || return $?
            effective="$(jq -c '{dns:(.dns // null),route:(.route | {default_domain_resolver} | with_entries(select(.value != null)))}' <<<"$rendered")" || return 10
        else
            effective='{"dns":null,"route":{}}'
        fi
    else
        # Preview current defaults without inventing installed core metadata.
        effective="$(proxy_dns_render "$settings" 1.13.0)" || return $?
    fi
    pending="$(proxy_core_pending_path sing-box)" || return $?
    if [[ -f "$pending" && ! -L "$pending" ]]; then
        pending_restart=true
        pending_reason="$(jq -c '.reason // null' "$pending")" || return 10
    fi
    if ((output_json)); then
        jq -n --arg core "$core" --arg version "$version" --arg source "$source" \
            --argjson installed "$installed" --argjson settings "$settings" --argjson effective "$effective" \
            --argjson pending_restart "$pending_restart" --argjson pending_reason "$pending_reason" '
            {schema_version:1,core:$core,version:(if $version == "" then null else $version end),
             installed:$installed,source:$source,settings:$settings,effective:$effective,
             pending_restart:$pending_restart,pending_reason:$pending_reason}'
        return
    fi
    mode="$(jq -r '.mode' <<<"$settings")"
    server="$(jq -r '.server // empty' <<<"$settings")"
    bootstrap="$(jq -r '.bootstrap // empty' <<<"$settings")"
    vps_cmd_status "DNS 内核" "sing-box ${version:-未安装（显示默认预览）}" info
    vps_cmd_status "设置来源" "$([[ "$source" == saved ]] && printf '已保存' || printf '默认')" info
    vps_cmd_status "DNS 模式" "$mode" info
    if [[ -n "$server" ]]; then
        vps_cmd_status "DNS 上游" "$(proxy_bracket_host "$server"):$(jq -r '.port' <<<"$settings")" info
        if ! _proxy_dns_is_ip "$server"; then
            vps_cmd_status "Bootstrap" "${bootstrap:-系统 DNS（兼容模式）}" info
        fi
    else
        vps_cmd_status "DNS 上游" "系统 DNS" info
    fi
    if [[ "$mode" == system ]]; then
        vps_cmd_info "系统 DNS 兼容模式：sing-box 1.13+ 使用 prefer_go，1.12 省略该字段"
    elif [[ "$mode" == system-native ]]; then
        vps_cmd_info "系统 DNS 原生模式：不设置 prefer_go"
    fi
    [[ "$installed" != true ]] || proxy_core_version_at_least "$version" 1.12.0 ||
        vps_cmd_warning "当前旧版内核保留原有 DNS 行为；修改 DNS 设置前请升级至 1.12.0+"
    vps_cmd_status "待重启" "$([[ "$pending_restart" == true ]] && printf '是' || printf '否')" \
        "$([[ "$pending_restart" == true ]] && printf 'warning' || printf 'info')"
    printf '%s\n' "$effective" | jq .
}

proxy_dns_set() {
    local core=sing-box mode="" server="" port="" tls_server_name="" path="" bootstrap="" preset=""
    local settings key value custom=0
    local -A seen=()
    while (($#)); do
        key="$1"
        case "$key" in
            --core | --mode | --server | --port | --tls-server-name | --path | --bootstrap | --preset)
                if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
                    vps_cmd_error "${key} 需要一个非空值"; return 2
                fi
                [[ -z "${seen[$key]:-}" ]] || { vps_cmd_error "参数不可重复：$key"; return 2; }
                seen[$key]=1
                value="$2"
                case "$key" in
                    --core) core="$value" ;;
                    --preset) preset="$value" ;;
                    --mode) mode="$value"; custom=1 ;;
                    --server) server="$value"; custom=1 ;;
                    --port) port="$value"; custom=1 ;;
                    --tls-server-name) tls_server_name="$value"; custom=1 ;;
                    --path) path="$value"; custom=1 ;;
                    --bootstrap) bootstrap="$value"; custom=1 ;;
                esac
                shift 2
                ;;
            *) vps_cmd_error "未知 dns set 参数：$1"; return 2 ;;
        esac
    done
    _proxy_dns_core_valid "$core" || return $?
    if [[ -n "$preset" ]]; then
        ((custom == 0)) || { vps_cmd_error "--preset 不能与自定义 DNS 选项一起使用"; return 2; }
        [[ "$preset" == cloudflare-doh ]] || { vps_cmd_error "未知 DNS 预设：$preset"; return 2; }
        mode=doh server=1.1.1.1 port=443 tls_server_name=cloudflare-dns.com path=/dns-query
    fi
    case "$mode" in
        system | system-native)
            [[ -z "$server$port$tls_server_name$path$bootstrap" ]] || {
                vps_cmd_error "系统 DNS 模式不接受上游、端口、TLS、路径或 bootstrap 选项"; return 2;
            }
            ;;
        udp | tcp | dot | doh)
            [[ -n "$server" ]] || { vps_cmd_error "${mode} 模式需要 --server IP或域名"; return 2; }
            case "$mode" in
                udp | tcp) port="${port:-53}" ;;
                dot) port="${port:-853}" ;;
                doh) port="${port:-443}"; path="${path:-/dns-query}" ;;
            esac
            proxy_valid_port "$port" || { vps_cmd_error "DNS 端口必须为 1–65535"; return 2; }
            ;;
        *) vps_cmd_error "--mode 必须为 system|system-native|udp|tcp|dot|doh，或使用 --preset cloudflare-doh"; return 2 ;;
    esac
    proxy_ensure_mutation_tools dns jq || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    settings="$(jq -cn --arg mode "$mode" --arg server "$server" --arg port "$port" \
        --arg tls_server_name "$tls_server_name" --arg path "$path" --arg bootstrap "$bootstrap" '
        def optional: if . == "" then null else . end;
        {mode:$mode,server:($server | optional),port:($port | optional | if . == null then null else tonumber end),
         tls_server_name:($tls_server_name | optional),path:($path | optional),bootstrap:($bootstrap | optional)}
    ')" || return 2
    proxy_dns_settings_validate "$settings" || return 2
    _proxy_dns_apply set "$settings"
}

proxy_dns_reset() {
    local core=sing-box core_seen=0
    while (($#)); do
        case "$1" in
            --core)
                ((core_seen == 0)) || { vps_cmd_error "参数不可重复：--core"; return 2; }
                if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
                    vps_cmd_error "--core 需要一个非空值"; return 2
                fi
                core="$2"; core_seen=1; shift 2
                ;;
            *) vps_cmd_error "未知 dns reset 参数：$1"; return 2 ;;
        esac
    done
    _proxy_dns_core_valid "$core" || return $?
    proxy_ensure_mutation_tools dns jq || return $?
    if proxy_stop_after_dependency_plan; then return 0; fi
    _proxy_dns_apply reset "$(proxy_dns_settings_default)"
}

_proxy_dns_apply() (
    local action="$1" settings="$2" candidate_manifest="" candidate_config="" source_manifest config
    local temporary_dir="" status=0
    vps_cmd_require_root || return $?
    proxy_require_platform || return $?
    _proxy_dns_require_core || return $?
    proxy_prepare_manifest_state || return $?
    vps_cmd_lock proxy || return $?
    trap '[[ -z "$candidate_manifest" ]] || rm -f -- "$candidate_manifest"; [[ -z "$candidate_config" ]] || rm -f -- "$candidate_config"; [[ -z "$temporary_dir" ]] || rmdir -- "$temporary_dir"; vps_cmd_unlock' EXIT
    proxy_recover_transaction || return $?
    _proxy_dns_require_core || return $?
    if [[ -f "$PROXY_MANIFEST" ]]; then
        proxy_manifest_validate_file "$PROXY_MANIFEST" || return $?
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        temporary_dir="$(mktemp -d)" || return 20
        candidate_manifest="${temporary_dir}/nodes.json"
        candidate_config="${temporary_dir}/config.json"
    else
        candidate_manifest="$(mktemp "${PROXY_STATE_DIR}/.nodes.dns.XXXXXX")" || return 20
        candidate_config="$(proxy_mktemp_json "$PROXY_STATE_DIR" config.dns)" || return 20
    fi
    if [[ -f "$PROXY_MANIFEST" ]]; then source_manifest="$(<"$PROXY_MANIFEST")"
    else source_manifest="$(proxy_manifest_default)"; fi
    if [[ "$action" == reset ]]; then
        jq '
            del(.settings.sing_box.dns) |
            if .settings.sing_box == {} then del(.settings.sing_box) else . end |
            if .settings == {} then del(.settings) else . end
        ' <<<"$source_manifest" >"$candidate_manifest" || return 10
    else
        jq --argjson dns "$settings" '.settings.sing_box.dns = $dns' <<<"$source_manifest" >"$candidate_manifest" || return 10
    fi
    proxy_manifest_validate_file "$candidate_manifest" || return $?
    proxy_render_config sing-box "$candidate_manifest" >"$candidate_config" || return $?
    config="$(proxy_core_config_path sing-box)" || return $?
    if [[ -f "$PROXY_MANIFEST" && -f "$config" ]] &&
       jq -e --slurpfile candidate "$candidate_manifest" '. == $candidate[0]' "$PROXY_MANIFEST" >/dev/null &&
       jq -e --slurpfile candidate "$candidate_config" '. == $candidate[0]' "$config" >/dev/null; then
        vps_cmd_info "DNS 设置和生成配置均未变化"
        return 0
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        proxy_validate_config_with_binary sing-box "$candidate_config" || return $?
        vps_cmd_info "演练：DNS ${action} 候选配置校验通过；将提交配置并按现有待重启状态应用"
        jq -n --argjson settings "$settings" --slurpfile config "$candidate_config" '
            {settings:$settings,effective:{dns:$config[0].dns,
             route:{default_domain_resolver:$config[0].route.default_domain_resolver}}}' || return 10
        return 0
    fi
    proxy_commit_manifest_config sing-box "$candidate_manifest" "$candidate_config" "dns-${action}" || status=$?
    ((status == 0)) || return "$status"
    if [[ "$action" == reset ]]; then
        vps_cmd_success "已恢复默认系统 DNS 兼容模式"
    else
        vps_cmd_success "已保存 sing-box DNS 设置"
    fi
)

_proxy_dns_prompt_value() {
    local prompt="$1" default="$2" validator="$3" optional="${4:-0}" value
    while true; do
        value="$(proxy_prompt_value "$prompt" "$default")" || return $?
        if [[ -z "$value" && "$optional" == 1 ]] || "$validator" "$value"; then
            printf '%s' "$value"
            return 0
        fi
        vps_cmd_warning "输入无效，请重新输入"
    done
}

proxy_dns_set_interactive() {
    local mode server port default_port tls_server_name="" path="" bootstrap="" bootstrap_mode
    local -a args=()
    mode="$(proxy_prompt_select "DNS 模式" system \
        system "系统 DNS（兼容模式，推荐）" system-native "系统 DNS（原生模式）" \
        cloudflare-doh "Cloudflare DoH 预设" udp "自定义 UDP" tcp "自定义 TCP" dot "自定义 DoT" doh "自定义 DoH")" || return $?
    case "$mode" in
        system | system-native) proxy_dns_set --mode "$mode"; return ;;
        cloudflare-doh) proxy_dns_set --preset cloudflare-doh; return ;;
    esac
    server="$(_proxy_dns_prompt_value "DNS 上游 IP 或域名（不含协议和端口）" "" _proxy_relay_forward_valid_host_value)" || return $?
    case "$mode" in udp | tcp) default_port=53 ;; dot) default_port=853 ;; doh) default_port=443 ;; esac
    port="$(_proxy_dns_prompt_value "DNS 上游端口" "$default_port" proxy_valid_port)" || return $?
    args=(--mode "$mode" --server "$server" --port "$port")
    if [[ "$mode" == dot || "$mode" == doh ]]; then
        tls_server_name="$(_proxy_dns_prompt_value "TLS server name（留空按上游地址校验）" "" _proxy_relay_forward_valid_host_value 1)" || return $?
        [[ -z "$tls_server_name" ]] || args+=(--tls-server-name "$tls_server_name")
    fi
    if [[ "$mode" == doh ]]; then
        path="$(_proxy_dns_prompt_value "DoH 路径" /dns-query _proxy_dns_path_valid)" || return $?
        args+=(--path "$path")
    fi
    if ! _proxy_dns_is_ip "$server"; then
        bootstrap_mode="$(proxy_prompt_select "上游域名的 Bootstrap DNS" system system "系统 DNS（兼容模式）" custom "自定义 IP（UDP 53）")" || return $?
        if [[ "$bootstrap_mode" == custom ]]; then
            bootstrap="$(_proxy_dns_prompt_value "Bootstrap IP 地址" "" _proxy_dns_is_ip)" || return $?
            args+=(--bootstrap "$bootstrap")
        fi
    fi
    proxy_dns_set "${args[@]}"
}

proxy_dns_menu_run() {
    local action status=0 prompt_status=0 REPLY
    while true; do
        action="$(proxy_prompt_select "sing-box DNS" show show "查看 DNS 设置" set "设置 DNS" reset "恢复默认系统 DNS" back "返回代理管理")" || prompt_status=$?
        if ((prompt_status != 0)); then
            [[ "$prompt_status" == 130 ]] && return "$status"
            return "$prompt_status"
        fi
        case "$action" in
            show) proxy_menu_action proxy_dns_show || status=$? ;;
            set) proxy_menu_action proxy_dns_set_interactive || status=$? ;;
            reset) proxy_menu_action proxy_dns_reset || status=$? ;;
            back) return "$status" ;;
        esac
        vps_ui_ensure_init
        printf '\n %s按 Enter 返回 DNS 菜单...%s' "$VPS_UI_CYAN" "$VPS_UI_RESET" >&2
        IFS= read -r || return "$status"
        prompt_status=0
    done
}

proxy_dns_dispatch() {
    local action="${1:-show}"
    (($# == 0)) || shift
    case "$action" in
        show) proxy_dns_show "$@" ;;
        set) proxy_dns_set "$@" ;;
        reset) proxy_dns_reset "$@" ;;
        *) vps_cmd_error "未知 DNS 动作：$action（支持 show|set|reset）"; return 2 ;;
    esac
}
