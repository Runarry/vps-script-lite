# shellcheck shell=bash

ufw_cli_menu_select_rule() {
    local inventory row id label
    local -a choices=()
    inventory="$(vps_ufw_inventory)" || return $?
    while IFS= read -r row; do
        id="$(jq -r '.id' <<<"$row")"
        label="$(jq -r '"\(.number). \(.family) \(.kind) \(.action) \(.port)/\(.proto) \(.source) → \(.destination)"' <<<"$row")"
        choices+=("$id" "$label")
    done < <(jq -c 'unique_by(.number)[]' <<<"$inventory")
    ((${#choices[@]} > 0)) || {
        vps_cmd_warning '没有可选择的规则'
        return 130
    }
    vps_cmd_prompt_select '请选择规则' '' "${choices[@]}"
}

# arguments, initial and operation are deliberately local to menu_rule; Bash's
# dynamic scope lets this helper append only the fields the operator changed.
ufw_cli_menu_rule_option() {
    local key="$1" value="$2" option="$3"
    if [[ "$operation" == add || "$value" != "${initial[$key]}" ]]; then
        arguments+=("$option" "$value")
    fi
}

ufw_cli_menu_rule() {
    local mode="$1" operation="$2" id='' port proto action direction source destination in_interface out_interface position comment family app log source_port record key inventory
    local -a arguments=(rule "$operation")
    local -A initial=([port]='' [proto]=tcp [action]=allow [direction]=in [source]=any [destination]=any [in]='' [out]='' [comment]='' [family]=both [app]='' [log]='' [source_port]=any)
    if [[ "$operation" != add ]]; then
        id="$(ufw_cli_menu_select_rule)" || return $?
        arguments+=(--id "$id")
        inventory="$(vps_ufw_inventory)" || return $?
        record="$(jq -ce --arg id "$id" '.[]|select(.id==$id)' <<<"$inventory")" || return 3
        for key in port proto action source destination comment family app log source_port; do initial[$key]="$(jq -r --arg key "$key" '.[$key] // ""' <<<"$record")"; done
        for key in in out; do initial[$key]="$(jq -r --arg key "$key" '.interfaces[$key] // ""' <<<"$record")"; done
        case "$(jq -r '.kind' <<<"$record")" in input) initial[direction]=in ;; output) initial[direction]=out ;; route) initial[direction]=route ;; *) return 3 ;; esac
        if jq -e --argjson number "$(jq '.number' <<<"$record")" '[.[]|select(.number==$number)|.proto]|unique|length>1' <<<"$inventory" >/dev/null; then
            initial[proto]=any
        fi
    fi
    if [[ "$operation" == delete ]]; then
        vps_cmd_confirm '删除所选规则？' || return $?
        ufw_cli_dispatch "${arguments[@]}"
        return $?
    fi
    if [[ "$mode" == simple ]]; then
        port="$(vps_cmd_prompt_value '端口、逗号列表或范围（例如 443 或 8000:8010）' "${initial[port]}")" || return $?
        [[ -n "$port" ]] || return 130
        proto="$(vps_cmd_prompt_select '协议' "${initial[proto]}" tcp TCP udp UDP any 'TCP 和 UDP')" || return $?
        ufw_cli_menu_rule_option port "$port" --port
        ufw_cli_menu_rule_option proto "$proto" --proto
        if [[ -n "${initial[app]}" && "$port" != "${initial[port]}" && "$proto" == "${initial[proto]}" ]]; then
            arguments+=(--proto "$proto")
        fi
    else
        action="$(vps_cmd_prompt_select '规则动作' "${initial[action]}" allow '允许' deny '丢弃' reject '拒绝' limit '限制连接速率')" || return $?
        direction="$(vps_cmd_prompt_select '规则方向' "${initial[direction]}" in '输入' out '输出' route '路由转发')" || return $?
        app="$(vps_cmd_prompt_value '应用配置名称（- 表示改用端口）' "${initial[app]}")" || return $?
        [[ "$app" != - ]] || app=''
        ufw_cli_menu_rule_option action "$action" --action
        ufw_cli_menu_rule_option direction "$direction" --direction
        ufw_cli_menu_rule_option app "$app" --app
        if [[ -n "$app" ]]; then
            :
        else
            proto="$(vps_cmd_prompt_value '协议（tcp、udp、any 或 UFW 支持的协议）' "${initial[proto]}")" || return $?
            port="$(vps_cmd_prompt_value '目标端口/列表/范围（any 为全部）' "${initial[port]:-any}")" || return $?
            source_port="$(vps_cmd_prompt_value '来源端口/列表/范围' "${initial[source_port]}")" || return $?
            if [[ "$operation" == edit && -n "${initial[app]}" ]]; then
                arguments+=(--proto "$proto" --port "$port")
            else
                ufw_cli_menu_rule_option proto "$proto" --proto
                ufw_cli_menu_rule_option port "$port" --port
            fi
            ufw_cli_menu_rule_option source_port "$source_port" --source-port
        fi
        source="$(vps_cmd_prompt_value '来源 IP/CIDR' "${initial[source]}")" || return $?
        destination="$(vps_cmd_prompt_value '目标 IP/CIDR' "${initial[destination]}")" || return $?
        ufw_cli_menu_rule_option source "$source" --source
        ufw_cli_menu_rule_option destination "$destination" --destination
        in_interface=''
        out_interface=''
        if [[ "$direction" == in || "$direction" == route ]]; then
            in_interface="$(vps_cmd_prompt_value '输入网卡（- 表示任意）' "${initial[in]}")" || return $?
            [[ "$in_interface" != - ]] || in_interface=''
        fi
        if [[ "$direction" == out || "$direction" == route ]]; then
            out_interface="$(vps_cmd_prompt_value '输出网卡（- 表示任意）' "${initial[out]}")" || return $?
            [[ "$out_interface" != - ]] || out_interface=''
        fi
        ufw_cli_menu_rule_option in "$in_interface" --in-interface
        ufw_cli_menu_rule_option out "$out_interface" --out-interface
        if [[ "$operation" == add ]]; then
            family="$(vps_cmd_prompt_select '地址族' both both 'IPv4 / IPv6（遵循 UFW 配置）' ipv4 IPv4 ipv6 IPv6)" || return $?
            position="$(vps_cmd_prompt_value '插入位置（留空追加）' '')" || return $?
            arguments+=(--family "$family")
            [[ -z "$position" ]] || arguments+=(--position "$position")
        fi
        log="$(vps_cmd_prompt_select '规则日志' "${initial[log]:-none}" none '关闭' log '记录新连接' log-all '记录所有数据包')" || return $?
        [[ "$log" != none ]] || log=''
        ufw_cli_menu_rule_option log "$log" --log
    fi
    comment="$(vps_cmd_prompt_value '注释（- 表示清空）' "${initial[comment]}")" || return $?
    [[ "$comment" != - ]] || comment=''
    ufw_cli_menu_rule_option comment "$comment" --comment
    if [[ "$operation" == edit && ${#arguments[@]} == 4 ]]; then
        vps_cmd_info '规则未变更'
        return 0
    fi
    ufw_cli_dispatch "${arguments[@]}"
}

ufw_cli_menu_link() {
    local operation owner links row
    local -a choices=()
    ufw_cli_links_list || return $?
    operation="$(vps_cmd_prompt_select '服务联动' list list '返回' detach '解除联动' attach '恢复联动')" || return $?
    [[ "$operation" != list ]] || return 0
    links="$(vps_ufw_links)" || return $?
    while IFS= read -r row; do
        owner="$(jq -r '.owner' <<<"$row")"
        choices+=("$owner" "$owner")
    done < <(jq -c '.[]' <<<"$links")
    ((${#choices[@]} > 0)) || {
        vps_cmd_warning '没有服务联动，请先同步'
        return 0
    }
    owner="$(vps_cmd_prompt_select '选择服务' '' "${choices[@]}")" || return $?
    ufw_cli_dispatch link "$operation" "$owner"
}

ufw_cli_advanced_menu() {
    local choice direction policy value name operation status
    while true; do
        choice="$(vps_cmd_prompt_select 'UFW 高级管理' '' \
            list '完整规则列表' add '添加高级规则' edit '修改高级规则' delete '删除规则' \
            app '应用配置管理' default '默认策略' ipv6 'IPv6 防护' logging '日志级别' reload '重新加载' reset '重置规则')" || return 0
        status=0
        case "$choice" in
            list) ufw_cli_dispatch rule list || status=$? ;;
            add | edit | delete) ufw_cli_menu_rule advanced "$choice" || status=$? ;;
            default)
                direction="$(vps_cmd_prompt_select '默认策略方向' incoming incoming '输入' outgoing '输出' routed '路由转发')" || continue
                policy="$(vps_cmd_prompt_select '默认策略' deny deny '丢弃' allow '允许' reject '拒绝')" || continue
                ufw_cli_dispatch default "$direction" "$policy" || status=$?
                ;;
            ipv6)
                value="$(vps_cmd_prompt_select 'IPv6 防护' on on '开启' off '关闭')" || continue
                ufw_cli_dispatch ipv6 "$value" || status=$?
                ;;
            logging)
                value="$(vps_cmd_prompt_select '日志级别' low off '关闭' low '低' medium '中' high '高' full '完整')" || continue
                ufw_cli_dispatch logging "$value" || status=$?
                ;;
            app)
                operation="$(vps_cmd_prompt_select 'UFW 应用配置' list list '列出配置' info '查看配置' default '默认应用策略' update '更新配置规则')" || continue
                case "$operation" in
                    list) ufw_cli_dispatch app list || status=$? ;;
                    info | update)
                        name="$(vps_cmd_prompt_value '应用配置名称（update 可填 all）' '')" || continue
                        [[ -n "$name" ]] || continue
                        ufw_cli_dispatch app "$operation" "$name" || status=$?
                        ;;
                    default)
                        policy="$(vps_cmd_prompt_select '默认应用策略' skip skip '跳过' allow '允许' deny '丢弃' reject '拒绝')" || continue
                        ufw_cli_dispatch app default "$policy" || status=$?
                        ;;
                esac
                ;;
            reload | reset) ufw_cli_dispatch "$choice" || status=$? ;;
        esac
        ((status == 0 || status == 130)) || vps_cmd_warning "操作未完成（退出码 $status）"
        vps_ui_pause
    done
}

ufw_cli_menu() {
    local choice status mode
    while true; do
        choice="$(vps_cmd_prompt_select 'UFW 防火墙' '' \
            status '状态' install '安装' enable '启用（先同步业务端口）' disable '停用' \
            list '端口规则列表' add '添加端口' edit '修改端口' delete '删除端口' \
            link '服务联动状态与管理' sync '立即同步业务需求' advanced '高级管理' uninstall '卸载')" || return 0
        status=0
        case "$choice" in
            list) ufw_cli_dispatch rule list || status=$? ;;
            add | edit | delete) ufw_cli_menu_rule simple "$choice" || status=$? ;;
            link) ufw_cli_menu_link || status=$? ;;
            advanced) ufw_cli_advanced_menu || status=$? ;;
            uninstall)
                mode="$(vps_cmd_prompt_select '卸载选项' keep keep '卸载并保留配置/联动状态' purge '备份后彻底清理配置/联动状态')" || continue
                if [[ "$mode" == purge ]]; then
                    ufw_cli_dispatch uninstall --purge || status=$?
                else ufw_cli_dispatch uninstall || status=$?; fi
                ;;
            *) ufw_cli_dispatch "$choice" || status=$? ;;
        esac
        ((status == 0 || status == 130)) || vps_cmd_warning "操作未完成（退出码 $status）"
        vps_ui_pause
    done
}
