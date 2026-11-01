# shellcheck shell=bash
# shellcheck disable=SC2016
nft_cli_prompt_validated() {
    local prompt="$1" initial="$2" validator="$3" value
    while true; do
        value="$(vps_cmd_prompt_value "$prompt" "$initial")" || return $?
        [[ "$value" != q && "$value" != Q ]] || return 130
        if "$validator" "$value"; then
            printf '%s' "$value"
            return 0
        fi
        vps_cmd_warning '输入无效，请按提示重新输入（q 返回）'
    done
}

nft_cli_valid_ttl() { nft_cli_ttl "$1" >/dev/null; }
nft_cli_valid_count() { [[ "$1" =~ ^[0-9]{1,9}$ ]]; }
nft_cli_valid_burst() { nft_cli_valid_count "$1" && ((10#$1 > 0)); }
nft_cli_valid_rate() { [[ "$1" == 0 || "$1" =~ ^[1-9][0-9]{0,8}/(second|minute|hour)$ ]]; }
nft_cli_valid_comment() { [[ "$1" != *$'\n'* && "$1" != *$'\r'* && ${#1} -le 256 ]]; }

nft_cli_menu_service() {
    local initial="${1:-}" links owner choice
    local -a choices=(all '全部端口 / 手工指定范围')
    links="$(vps_nft_links)" || return $?
    while IFS= read -r owner; do choices+=("$owner" "$owner"); done < <(jq -r '.[].owner' <<<"$links")
    choice="$(vps_cmd_prompt_select '规则范围' "${initial:-all}" "${choices[@]}")" || return $?
    [[ "$choice" == all ]] || printf '%s' "$choice"
}

nft_cli_menu_pick_rule() {
    local kind="$1" state row
    local -a choices=()
    state="$(vps_nft_state)" || return $?
    while IFS= read -r row; do
        choices+=("$(jq -r '.id' <<<"$row")" "$(jq -r '[.id,(.action//.rate//""),.proto,.port,.source]|join(" · ")' <<<"$row")")
    done < <(jq -c --arg key "${kind}s" '.[$key][]' <<<"$state")
    ((${#choices[@]})) || {
        vps_cmd_warning '暂无可选择的规则'
        return 130
    }
    vps_cmd_prompt_select '选择规则' '' "${choices[@]}"
}

nft_cli_menu_rule_form() {
    local area="$1" operation="$2" id="${3:-}" current='{}' state action proto port source family ttl=keep comment service choice field scope expiry
    local -a args=()
    if [[ -n "$id" ]]; then
        state="$(vps_nft_state)" || return $?
        current="$(jq -c --arg id "$id" '.rules[]|select(.id==$id)' <<<"$state")" || return $?
        args+=(--id "$id")
    fi
    action="$(jq -r '.action//"allow"' <<<"$current")"
    proto="$(jq -r '.proto//"tcp"' <<<"$current")"
    port="$(jq -r '.port//"any"' <<<"$current")"
    source="$(jq -r '.source//"any"' <<<"$current")"
    family="$(jq -r '.family//"both"' <<<"$current")"
    service="$(jq -r '.service//empty' <<<"$current")"
    comment="$(jq -r '.comment//empty' <<<"$current")"
    expiry="$(jq -r 'if (.expires_at//0)==0 then "永久" else (.expires_at|tostring) end' <<<"$current")"
    if [[ "$operation" == add ]]; then
        action="$(vps_cmd_prompt_select '访问方式' allow allow '允许' deny '拒绝' allow-only '仅允许指定来源')" || return $?
        if [[ "$area" == ips ]]; then
            source="$(nft_cli_prompt_validated '来源 IP/CIDR，多个用逗号分隔' any nft_cli_valid_address)" || return $?
            scope="$(vps_cmd_prompt_select '控制范围' ports ports '指定端口' all '全部流量' service '指定服务')" || return $?
            case "$scope" in
                all) proto=any ;;
                service)
                    service="$(nft_cli_menu_service)" || return $?
                    proto=both
                    ;;
            esac
        else scope=ports; fi
        if [[ "$scope" == ports ]]; then
            port="$(nft_cli_prompt_validated '端口 / 逗号列表 / 范围 8000-8010' '' nft_cli_valid_ports)" || return $?
            proto="$(vps_cmd_prompt_select '协议' tcp tcp TCP udp UDP both 'TCP 和 UDP')" || return $?
        fi
        if [[ "$action" == allow-only && "$source" == any ]]; then
            source="$(nft_cli_prompt_validated '仅允许的来源 IP/CIDR，多个用逗号分隔' '' nft_cli_valid_address)" || return $?
        fi
    fi
    while true; do
        printf '\n动作：%s　端口：%s/%s　来源：%s\n地址族：%s　服务：%s　有效期：%s\n' \
            "$action" "$port" "$proto" "$source" "$family" "${service:-全部}" "$expiry"
        if [[ "$operation" == add ]]; then
            choice="$(vps_cmd_prompt_select '规则设置' apply apply '保存规则' advanced '高级选项')" || return $?
            [[ "$choice" != apply ]] || break
        fi
        field="$(vps_cmd_prompt_select '选择要修改的字段' apply apply '保存规则' action '访问方式' port '端口' proto '协议' source '来源 IP' service '服务范围' family '地址族' ttl '有效期' comment '备注')" || return $?
        case "$field" in
            apply) break ;;
            action) action="$(vps_cmd_prompt_select '访问方式' "$action" allow '允许' deny '拒绝' allow-only '仅允许指定来源')" || return $? ;;
            port) port="$(nft_cli_prompt_validated '端口 / 逗号列表 / 连字符范围 / any' "$port" nft_cli_valid_ports)" || return $? ;;
            proto) proto="$(vps_cmd_prompt_select '协议' "$proto" tcp TCP udp UDP both 'TCP 和 UDP' any '全部协议')" || return $? ;;
            source) source="$(nft_cli_prompt_validated '来源 IP/CIDR / 逗号列表 / any' "$source" nft_cli_valid_address)" || return $? ;;
            service) service="$(nft_cli_menu_service "$service")" || return $? ;;
            family) family="$(vps_cmd_prompt_select '地址族' "$family" both 'IPv4 和 IPv6' ipv4 IPv4 ipv6 IPv6)" || return $? ;;
            ttl)
                ttl="$(nft_cli_prompt_validated '有效时长：秒数、30m、2h、7d；0 永久' 0 nft_cli_valid_ttl)" || return $?
                expiry="$ttl"
                [[ "$ttl" != 0 ]] || expiry=永久
                ;;
            comment)
                comment="$(nft_cli_prompt_validated '备注（- 清空）' "${comment:--}" nft_cli_valid_comment)" || return $?
                [[ "$comment" != - ]] || comment=''
                ;;
        esac
        if [[ "$proto" == any && "$port" != any ]]; then
            vps_cmd_warning '指定端口需要 TCP 或 UDP，请选择协议'
            proto="$(vps_cmd_prompt_select '协议' both tcp TCP udp UDP both 'TCP 和 UDP')" || return $?
        fi
        while ! nft_cli_valid_address "$source" "$family"; do
            vps_cmd_warning '来源与地址族不一致，请调整地址族'
            family="$(vps_cmd_prompt_select '地址族' both both 'IPv4 和 IPv6' ipv4 IPv4 ipv6 IPv6)" || return $?
        done
    done
    args+=(--action "$action" --proto "$proto" --port "$port" --source "$source" --family "$family" --comment "$comment" --service "$service")
    [[ "$ttl" == keep ]] || args+=(--ttl "$ttl")
    nft_cli_dispatch rule "$operation" "${args[@]}"
}

nft_cli_menu_rules() {
    local area="$1" choice id status
    while true; do
        nft_cli_list rule 0 || return $?
        choice="$(vps_cmd_prompt_select '规则管理' '' add '新增规则' edit '修改规则' delete '删除规则')" || return $?
        status=0
        case "$choice" in
            add) nft_cli_menu_rule_form "$area" add || status=$? ;;
            edit | delete)
                id="$(nft_cli_menu_pick_rule rule)" || continue
                if [[ "$choice" == edit ]]; then
                    nft_cli_menu_rule_form "$area" edit "$id" || status=$?
                else nft_cli_dispatch rule delete --id "$id" || status=$?; fi
                ;;
        esac
        ((status == 0 || status == 130)) || vps_cmd_warning "规则未更新（退出码 $status）"
    done
}

nft_cli_menu_links() {
    local links row owner operation
    local -a choices=()
    nft_cli_links_list 0 || return $?
    operation="$(vps_cmd_prompt_select '服务联动' '' sync '同步现有服务' attach '恢复联动' detach '解除联动')" || return $?
    if [[ "$operation" == sync ]]; then
        nft_cli_dispatch sync
        return $?
    fi
    links="$(vps_nft_links)" || return $?
    while IFS= read -r row; do
        choices+=("$(jq -r '.owner' <<<"$row")" "$(jq -r '.owner + if .detached then "（已解除）" else "（联动中）" end' <<<"$row")")
    done < <(jq -c '.[]' <<<"$links")
    ((${#choices[@]})) || {
        vps_cmd_warning '暂无服务需求，请先同步'
        return 130
    }
    owner="$(vps_cmd_prompt_select '选择服务' '' "${choices[@]}")" || return $?
    nft_cli_dispatch link "$operation" "$owner"
}

nft_cli_menu_limits() {
    local choice id='' proto port source family rate burst connections service
    local -a args=()
    nft_cli_list limit 0 || return $?
    choice="$(vps_cmd_prompt_select '限速和连接数' '' add '新增限制' edit '替换限制' delete '删除限制')" || return $?
    if [[ "$choice" != add ]]; then
        id="$(nft_cli_menu_pick_rule limit)" || return $?
        args+=(--id "$id")
        if [[ "$choice" == delete ]]; then
            nft_cli_dispatch limit delete "${args[@]}"
            return $?
        fi
    fi
    service="$(nft_cli_menu_service)" || return $?
    proto="$(vps_cmd_prompt_select '协议' tcp tcp 'TCP 新连接' udp 'UDP 数据包')" || return $?
    port="$(nft_cli_prompt_validated '端口 / 列表 / 范围 / any' any nft_cli_valid_ports)" || return $?
    source="$(nft_cli_prompt_validated '来源 IP/CIDR / 逗号列表 / any' any nft_cli_valid_address)" || return $?
    family="$(vps_cmd_prompt_select '地址族' both both 'IPv4 和 IPv6' ipv4 IPv4 ipv6 IPv6)" || return $?
    while ! nft_cli_valid_address "$source" "$family"; do
        vps_cmd_warning '来源地址与地址族不一致'
        source="$(nft_cli_prompt_validated '重新输入来源 IP/CIDR' any nft_cli_valid_address)" || return $?
    done
    rate="$(nft_cli_prompt_validated '速率，例如 10/second、60/minute；0 不限制速率' 10/second nft_cli_valid_rate)" || return $?
    [[ "$rate" != 0 ]] || rate=''
    burst="$(nft_cli_prompt_validated '允许突发数量（大于 0）' 20 nft_cli_valid_burst)" || return $?
    connections=0
    if [[ "$proto" == tcp ]]; then connections="$(nft_cli_prompt_validated '每来源同时连接数；0 不限制' 0 nft_cli_valid_count)" || return $?; fi
    [[ -n "$rate" || "$connections" != 0 ]] || {
        vps_cmd_error '至少需要速率或连接数限制'
        return 2
    }
    nft_cli_dispatch limit set "${args[@]}" --proto "$proto" --port "$port" --source "$source" --family "$family" --rate "$rate" --burst "$burst" --connections "$connections" --service "$service"
}

nft_cli_menu_restore() {
    local root path choice
    local -a choices=()
    root="$(vps_cmd_system_path /var/lib/vpsctl/backups/network/nftables)" || return $?
    for path in "$root"/change-*; do
        [[ -d "$path/snapshot" && -f "$path/boot" ]] || continue
        choices+=("$path" "${path##*/}")
    done
    ((${#choices[@]})) || {
        vps_cmd_warning '暂无恢复快照'
        return 130
    }
    choice="$(vps_cmd_prompt_select '选择恢复时间点' '' "${choices[@]}")" || return $?
    nft_cli_dispatch restore "$choice"
}

nft_cli_menu_logs() {
    local choice
    choice="$(vps_cmd_prompt_select '防火墙日志' '' on '开启拒绝日志' off '关闭拒绝日志' view '查看近期日志')" || return $?
    case "$choice" in
        on | off) nft_cli_dispatch logging "$choice" ;;
        view)
            if command -v journalctl >/dev/null 2>&1; then
                journalctl -k --no-pager -n 100 --grep 'vpsctl'
            else dmesg | awk '/vpsctl/'; fi
            ;;
    esac
}

nft_cli_menu_more() {
    local choice status
    while true; do
        choice="$(vps_cmd_prompt_select '更多管理' '' logs '日志' stats '统计' limits '限速与连接数' recovery '恢复快照' uninstall '卸载')" || return $?
        status=0
        case "$choice" in
            logs) nft_cli_menu_logs || status=$? ;;
            stats) nft_cli_dispatch stats || status=$? ;;
            limits) nft_cli_menu_limits || status=$? ;;
            recovery) nft_cli_menu_restore || status=$? ;;
            uninstall) nft_cli_dispatch uninstall || status=$? ;;
        esac
        ((status == 0 || status == 130)) || vps_cmd_warning "操作未完成（退出码 $status）"
        vps_ui_pause
    done
}

nft_cli_menu() {
    local choice state toggle label status
    while true; do
        vps_ui_page 'nftables 防火墙' "$(nft_cli_status 0 2>/dev/null || printf '尚未安装；启用时安装所需依赖')"
        toggle=enable
        label='启用防火墙'
        if command -v jq >/dev/null 2>&1; then
            state="$(vps_nft_state)" || return $?
            if [[ "$(jq -r '.enabled' <<<"$state")" == true ]]; then
                toggle=disable
                label='停用防火墙'
            fi
        fi
        choice="$(vps_cmd_prompt_select '请选择功能' '' ports '端口放行 / 禁止' ips 'IP 访问控制' links '服务联动' more '更多管理' toggle "$label")" || return 0
        status=0
        case "$choice" in
            ports | ips) nft_cli_menu_rules "$choice" || status=$? ;;
            links) nft_cli_menu_links || status=$? ;;
            more) nft_cli_menu_more || status=$? ;;
            toggle) nft_cli_dispatch "$toggle" || status=$? ;;
        esac
        ((status == 0 || status == 130)) || vps_cmd_warning "操作未完成（退出码 $status）"
    done
}
