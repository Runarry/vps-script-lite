# shellcheck shell=bash
# Parsed command state is consumed by the entry point and menu.
# shellcheck disable=SC2034

declare -A UFW_RULE=()
declare -A UFW_RULE_SET=()
UFW_RULE_ID=''
UFW_RULE_NUMBER=''
UFW_RULE_OPERATION=''
UFW_RULE_COMMAND=()

ufw_cli_rule_parse() {
    UFW_RULE_OPERATION="$1"
    shift
    UFW_RULE_ID=''
    UFW_RULE_NUMBER=''
    UFW_RULE=([action]=allow [direction]=in [proto]=tcp [port]='' [source]=any [destination]=any [source_port]='' [in]='' [out]='' [comment]='' [position]='' [family]=both [app]='' [source_app]='' [log]='')
    UFW_RULE_SET=()
    local key
    while (($#)); do
        case "$1" in
            --id | --number | --action | --direction | --proto | --protocol | --port | --ports | --source | --from | --destination | --to | --source-port | --in-interface | --out-interface | --interface | --comment | --position | --family | --app | --log)
                (($# >= 2)) || {
                    vps_cmd_error "$1 缺少参数"
                    return 2
                }
                case "$1" in
                    --id)
                        [[ -z "$UFW_RULE_ID" ]] || return 2
                        UFW_RULE_ID="$2"
                        shift 2
                        continue
                        ;;
                    --number)
                        [[ -z "$UFW_RULE_NUMBER" ]] || return 2
                        UFW_RULE_NUMBER="$2"
                        shift 2
                        continue
                        ;;
                    --action) key=action ;; --direction) key=direction ;;
                    --proto | --protocol) key=proto ;; --port | --ports) key=port ;;
                    --source | --from) key=source ;; --destination | --to) key=destination ;;
                    --source-port) key=source_port ;;
                    --in-interface | --interface) key=in ;; --out-interface) key=out ;;
                    --comment) key=comment ;; --position) key=position ;; --family) key=family ;;
                    --app) key=app ;; --log) key=log ;;
                esac
                [[ -z "${UFW_RULE_SET[$key]+set}" ]] || {
                    vps_cmd_error "重复规则选项：$1"
                    return 2
                }
                UFW_RULE_SET[$key]=1
                UFW_RULE[$key]="$2"
                shift 2
                ;;
            *)
                if [[ "$UFW_RULE_OPERATION" != add && -z "$UFW_RULE_ID$UFW_RULE_NUMBER" && "$1" != -* ]]; then
                    UFW_RULE_ID="$1"
                    shift
                else
                    vps_cmd_error "未知规则选项：$1"
                    return 2
                fi
                ;;
        esac
    done
    if [[ "$UFW_RULE_OPERATION" == add ]]; then
        [[ -z "$UFW_RULE_ID$UFW_RULE_NUMBER" ]] || return 2
        ((${#UFW_RULE_SET[@]} > 0)) || {
            vps_cmd_error 'rule add 需要规则选项'
            return 2
        }
    else
        [[ -n "$UFW_RULE_ID$UFW_RULE_NUMBER" && ! (-n "$UFW_RULE_ID" && -n "$UFW_RULE_NUMBER") ]] || {
            vps_cmd_error '请指定唯一的 --id 或 --number'
            return 2
        }
        [[ -z "$UFW_RULE_ID" || "$UFW_RULE_ID" =~ ^[a-f0-9]{64}$ ]] || {
            vps_cmd_error '规则 ID 必须来自 rule list'
            return 2
        }
        [[ -z "$UFW_RULE_NUMBER" || "$UFW_RULE_NUMBER" =~ ^[1-9][0-9]{0,5}$ ]] || return 2
    fi
    if [[ "$UFW_RULE_OPERATION" == delete ]]; then
        ((${#UFW_RULE_SET[@]} == 0)) || {
            vps_cmd_error 'delete 只接受规则选择器'
            return 2
        }
    elif [[ "$UFW_RULE_OPERATION" == edit ]]; then
        ((${#UFW_RULE_SET[@]} > 0)) || {
            vps_cmd_error 'edit 至少需要一个修改项'
            return 2
        }
        [[ -z "${UFW_RULE_SET[position]+set}" ]] || {
            vps_cmd_error 'edit 保留原规则顺序，不能指定 --position'
            return 2
        }
    fi
}

ufw_cli_rule_validate() {
    case "${UFW_RULE[action]}" in allow | deny | reject | limit) ;; *)
        vps_cmd_error 'action 必须是 allow、deny、reject 或 limit'
        return 2
        ;;
    esac
    case "${UFW_RULE[direction]}" in in | out | route) ;; *) return 2 ;; esac
    case "${UFW_RULE[family]}" in ipv4 | ipv6 | both) ;; *) return 2 ;; esac
    [[ "${UFW_RULE[proto]}" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || return 2
    local key
    for key in port source_port; do
        [[ -z "${UFW_RULE[$key]}" || "${UFW_RULE[$key]}" == any ]] || ufw_cli_valid_ports "${UFW_RULE[$key]}" || {
            vps_cmd_error "无效端口列表/范围：${UFW_RULE[$key]}"
            return 2
        }
    done
    for key in source destination; do ufw_cli_valid_address "${UFW_RULE[$key]}" || {
        vps_cmd_error "无效 IP/CIDR：${UFW_RULE[$key]}"
        return 2
    }; done
    for key in in out; do [[ -z "${UFW_RULE[$key]}" || "${UFW_RULE[$key]}" =~ ^[A-Za-z0-9_.:+-]{1,15}$ ]] || return 2; done
    [[ "${UFW_RULE[comment]}" != *$'\n'* && "${UFW_RULE[comment]}" != *$'\r'* && ${#UFW_RULE[comment]} -le 128 ]] || return 2
    [[ -z "${UFW_RULE_SET[comment]+set}" || "${UFW_RULE[comment]}" != vpsctl:* ]] || {
        vps_cmd_error 'vpsctl: 注释前缀为服务联动保留'
        return 2
    }
    [[ -z "${UFW_RULE[position]}" || "${UFW_RULE[position]}" =~ ^[1-9][0-9]{0,5}$ ]] || return 2
    case "${UFW_RULE[log]}" in '' | log | log-all) ;; *) return 2 ;; esac
    if [[ -n "${UFW_RULE[app]}${UFW_RULE[source_app]}" ]]; then
        for key in app source_app; do
            [[ "${UFW_RULE[$key]}" != -* && "${UFW_RULE[$key]}" != *$'\n'* && "${UFW_RULE[$key]}" != *$'\r'* ]] || return 2
        done
        [[ -z "${UFW_RULE[app]}" || -z "${UFW_RULE[port]}" ]] || {
            vps_cmd_error '--app 与目标端口不能同时使用'
            return 2
        }
        [[ -z "${UFW_RULE[source_app]}" || -z "${UFW_RULE[source_port]}" ]] || return 2
        [[ -z "${UFW_RULE_SET[proto]+set}" ]] || {
            vps_cmd_error '应用配置自身决定协议，请去掉 --proto'
            return 2
        }
    fi
    if [[ "${UFW_RULE[direction]}" == in && -n "${UFW_RULE[out]}" || "${UFW_RULE[direction]}" == out && -n "${UFW_RULE[in]}" ]]; then
        vps_cmd_error '输入/输出规则仅接受对应方向的网卡；双向网卡请使用 route'
        return 2
    fi
    # The installed UFW parser is the authority on protocol availability and
    # combinations (for example limit+udp, application profiles and IPv6).
}

ufw_cli_rule_command() {
    local source="${UFW_RULE[source]}" destination="${UFW_RULE[destination]}"
    UFW_RULE_COMMAND=()
    [[ "${UFW_RULE[direction]}" != route ]] || UFW_RULE_COMMAND+=(route)
    [[ -z "${UFW_RULE[position]}" ]] || UFW_RULE_COMMAND+=(insert "${UFW_RULE[position]}")
    UFW_RULE_COMMAND+=("${UFW_RULE[action]}")
    if [[ "${UFW_RULE[direction]}" == route ]]; then
        [[ -z "${UFW_RULE[in]}" ]] || UFW_RULE_COMMAND+=(in on "${UFW_RULE[in]}")
        [[ -z "${UFW_RULE[out]}" ]] || UFW_RULE_COMMAND+=(out on "${UFW_RULE[out]}")
    else
        UFW_RULE_COMMAND+=("${UFW_RULE[direction]}")
        [[ -z "${UFW_RULE[${UFW_RULE[direction]}]}" ]] || UFW_RULE_COMMAND+=(on "${UFW_RULE[${UFW_RULE[direction]}]}")
    fi
    [[ -z "${UFW_RULE[log]}" ]] || UFW_RULE_COMMAND+=("${UFW_RULE[log]}")
    [[ -n "${UFW_RULE[app]}${UFW_RULE[source_app]}" || "${UFW_RULE[proto]}" == any ]] || UFW_RULE_COMMAND+=(proto "${UFW_RULE[proto]}")
    case "${UFW_RULE[family]}" in
        ipv4)
            [[ "$source" != any ]] || source=0.0.0.0/0
            [[ "$destination" != any ]] || destination=0.0.0.0/0
            ;;
        ipv6)
            [[ "$source" != any ]] || source=::/0
            [[ "$destination" != any ]] || destination=::/0
            ;;
    esac
    UFW_RULE_COMMAND+=(from "$source")
    if [[ -n "${UFW_RULE[source_app]}" ]]; then
        UFW_RULE_COMMAND+=(app "${UFW_RULE[source_app]}")
    elif [[ -n "${UFW_RULE[source_port]}" && "${UFW_RULE[source_port]}" != any ]]; then UFW_RULE_COMMAND+=(port "${UFW_RULE[source_port]}"); fi
    UFW_RULE_COMMAND+=(to "$destination")
    if [[ -n "${UFW_RULE[app]}" ]]; then
        UFW_RULE_COMMAND+=(app "${UFW_RULE[app]}")
    elif [[ -n "${UFW_RULE[port]}" && "${UFW_RULE[port]}" != any ]]; then UFW_RULE_COMMAND+=(port "${UFW_RULE[port]}"); fi
    [[ -z "${UFW_RULE[comment]}" ]] || UFW_RULE_COMMAND+=(comment "${UFW_RULE[comment]}")
}

ufw_cli_rule_resolve() {
    local inventory="$1" matches count
    matches="$(jq -c --arg id "$UFW_RULE_ID" --arg number "$UFW_RULE_NUMBER" \
        '[.[] | select((($id != "") and .id == $id) or (($number != "") and (.number | tostring) == $number))]' <<<"$inventory")" || return 10
    count="$(jq -r 'length' <<<"$matches")"
    if [[ "$count" != 1 ]]; then
        jq -e 'length > 1 and (.[0].app_group != null) and ([.[].app_group]|unique|length)==1 and ([.[].number]|unique|length)==1' <<<"$matches" >/dev/null || {
            vps_cmd_error '规则不存在或 ID 不唯一，请重新运行 rule list'
            return 3
        }
    fi
    jq -c '.[0]' <<<"$matches"
}

ufw_cli_rule_verify_removed() {
    local before="$1" current="$2" removed="$3"
    jq -e --argjson before "$before" --argjson removed "$removed" \
        'map(.id) == ($before | map(select(.id as $id | ($removed | index($id)) == null)) | map(.id))' \
        <<<"$current" >/dev/null || {
        vps_cmd_error 'UFW 删除后的规则清单不符合预期'
        return 20
    }
}

ufw_cli_rule_unprotected() {
    local status=0
    vps_ufw_rule_protected "$1" || status=$?
    if ((status == 0)); then
        vps_cmd_error '该规则仍被服务引用；请先用 link list 查看引用，再 link detach OWNER 解除联动'
        return 3
    fi
    ((status == 1)) || return "$status"
}

ufw_cli_rule_apply_locked() {
    local before old='' current id='' old_family='' key field number count_before count_after selected removed part
    ufw_cli_require_installed || return $?
    before="$(vps_ufw_inventory)" || return $?
    if [[ "$UFW_RULE_OPERATION" != add ]]; then
        old="$(ufw_cli_rule_resolve "$before")" || return $?
        id="$(jq -r '.id' <<<"$old")"
        number="$(jq -r '.number' <<<"$old")"
        selected="$(jq -c --argjson number "$number" '[.[]|select(.number==$number)]' <<<"$before")"
        removed="$(jq -c 'map(.id)' <<<"$selected")"
        while IFS= read -r part; do ufw_cli_rule_unprotected "$part" || return $?; done < <(jq -r '.[]' <<<"$removed")
        if [[ "$(jq length <<<"$selected")" != 1 ]]; then
            vps_cmd_info "该应用规则包含多个协议，按 UFW 编号 $number 一并处理"
        fi
        if [[ "$UFW_RULE_OPERATION" == delete ]]; then
            vps_cmd_run env LC_ALL=C ufw --force delete "$number" || return 20
            if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
                current="$(vps_ufw_inventory)" || return $?
                ufw_cli_rule_verify_removed "$before" "$current" "$removed" || return $?
            fi
            return 0
        fi
        if jq -e 'any(.[]; .opaque == true)' <<<"$selected" >/dev/null; then
            vps_cmd_error '该规则含 UFW 标准字段以外的扩展，无法安全重建；请检查原生规则配置'
            return 3
        fi
        old_family="$(jq -r '.family' <<<"$old")"
        for key in action proto port source destination source_port comment family log; do
            [[ -n "${UFW_RULE_SET[$key]+set}" ]] || UFW_RULE[$key]="$(jq -r --arg key "$key" '.[$key] // ""' <<<"$old")"
        done
        if [[ -n "${UFW_RULE_SET[app]+set}" ]]; then
            [[ -n "${UFW_RULE_SET[port]+set}" ]] || UFW_RULE[port]=''
        elif [[ -z "${UFW_RULE_SET[port]+set}${UFW_RULE_SET[proto]+set}" ]]; then
            UFW_RULE[app]="$(jq -r '.app // .dapp // ""' <<<"$old")"
            [[ -z "${UFW_RULE[app]}" ]] || UFW_RULE[port]=''
        fi
        if [[ -z "${UFW_RULE_SET[source_port]+set}${UFW_RULE_SET[proto]+set}" ]]; then
            UFW_RULE[source_app]="$(jq -r '.source_app // .sapp // ""' <<<"$old")"
            [[ -z "${UFW_RULE[source_app]}" ]] || UFW_RULE[source_port]=''
        fi
        if [[ -z "${UFW_RULE_SET[direction]+set}" ]]; then
            field="$(jq -r '.kind' <<<"$old")"
            case "$field" in input) UFW_RULE[direction]=in ;; output) UFW_RULE[direction]=out ;; route) UFW_RULE[direction]=route ;; *) return 10 ;; esac
        fi
        for key in in out; do [[ -n "${UFW_RULE_SET[$key]+set}" ]] || UFW_RULE[$key]="$(jq -r --arg key "$key" '.interfaces[$key] // ""' <<<"$old")"; done
        [[ "${UFW_RULE[family]}" == "$old_family" ]] || {
            vps_cmd_error 'edit 必须保留原地址族；变更地址族请添加新规则后删除旧规则'
            return 2
        }
        UFW_RULE[position]="$number"
        # UFW insert accepts an existing position, never length+1. When the
        # selected item is the last rule in its address family, deleting it
        # makes its former position invalid; append restores that exact slot.
        if ! jq -e --arg family "$old_family" --argjson number "$number" \
            'any(.[]; .family == $family and .number > $number)' <<<"$before" >/dev/null; then
            UFW_RULE[position]=''
        fi
    fi
    ufw_cli_rule_validate || return $?
    ufw_cli_rule_command
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        if [[ "$UFW_RULE_OPERATION" == edit ]]; then
            vps_cmd_info "演练：验证替换规则并保存快照后，按 ID $id 删除旧规则、原位插入；失败恢复快照"
            vps_cmd_run env LC_ALL=C ufw --force delete "$number" || return $?
        fi
        vps_cmd_run env LC_ALL=C ufw "${UFW_RULE_COMMAND[@]}" || return $?
        return 0
    fi
    if ! LC_ALL=C ufw --dry-run "${UFW_RULE_COMMAND[@]}" >"$UFW_CLI_TMP/rule-validation" 2>&1; then
        cat -- "$UFW_CLI_TMP/rule-validation" >&2
        return 2
    fi
    if [[ "$UFW_RULE_OPERATION" == edit ]]; then
        # UFW refuses insert/prepend comment updates as duplicate rules. Delete
        # only the selected unprotected rule, then restore the validated rule at
        # its original position; the outer snapshot covers either failure.
        vps_cmd_run env LC_ALL=C ufw --force delete "$number" || return 20
        current="$(vps_ufw_inventory)" || return $?
        ufw_cli_rule_verify_removed "$before" "$current" "$removed" || return $?
    fi
    vps_cmd_run env LC_ALL=C ufw "${UFW_RULE_COMMAND[@]}" || return 20
    current="$(vps_ufw_inventory)" || return $?
    if [[ "$UFW_RULE_OPERATION" == edit ]]; then
        count_before="$(jq -r '[.[].number]|unique|length' <<<"$before")"
        count_after="$(jq -r '[.[].number]|unique|length' <<<"$current")"
        ((count_after == count_before)) || {
            vps_cmd_error 'UFW 未按预期插入替换规则'
            return 20
        }
        jq -e --argjson number "$number" --arg family "$old_family" --argjson before "$before" \
            '([.[]|select(.number==$number)]|length)>0 and all(.[]|select(.number==$number); .family==$family) and
             ([.[]|select(.number!=$number)|.id] == [$before[]|select(.number!=$number)|.id])' \
            <<<"$current" >/dev/null || {
            vps_cmd_error 'UFW 未保留规则位置或影响了其他规则'
            return 20
        }
    fi
    vps_cmd_success '规则已更新'
}

ufw_cli_rule_list() {
    local json="${1:-0}" inventory
    vps_ufw_require_tools || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
    inventory="$(vps_ufw_inventory)" || return $?
    if [[ "$json" == 1 ]]; then
        printf '%s\n' "$inventory"
        return 0
    fi
    printf '编号\t地址族\t方向\t动作\t协议\t端口\t来源 → 目标\t服务引用\t注释\n'
    jq -r '.[] | [.number,.family,.kind,.action,.proto,.port,(.source + " → " + .destination),(.owners | join(",")),.comment] | @tsv' <<<"$inventory"
    printf '\n稳定规则 ID（修改和删除时使用）：\n'
    jq -r '.[] | "  \(.number)  \(.id)"' <<<"$inventory"
}
