# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034
NFT_CLI_KIND=''
NFT_CLI_OPERATION=''
NFT_CLI_ID=''
NFT_CLI_PATCH='{}'

nft_cli_ttl() {
    local value="$1" count multiplier=1
    [[ "$value" =~ ^([0-9]{1,9})([smhd]?)$ ]] || return 2
    count="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in m) multiplier=60 ;; h) multiplier=3600 ;; d) multiplier=86400 ;; esac
    if ((10#$count == 0)); then printf '0\n'; else printf '%s\n' "$(($(date +%s) + 10#$count * multiplier))"; fi
}

nft_cli_rule_parse() {
    NFT_CLI_KIND="$1"
    NFT_CLI_OPERATION="$2"
    NFT_CLI_ID=''
    NFT_CLI_PATCH='{}'
    shift 2
    local option value key expiry
    local -A seen=() fields=()
    while (($#)); do
        option="$1"
        [[ "$option" == --?* ]] || return 2
        (($# >= 2)) || {
            vps_cmd_error "选项缺少值：$option"
            return 2
        }
        value="$2"
        [[ -z "${seen[$option]+set}" ]] || {
            vps_cmd_error "重复选项：$option"
            return 2
        }
        seen[$option]=1
        shift 2
        key="${option#--}"
        case "$option" in
            --id)
                [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$ ]] || return 2
                NFT_CLI_ID="$value"
                continue
                ;;
            --action)
                [[ "$NFT_CLI_KIND" == rule ]] || return 2
                case "$value" in allow | deny | allow-only) ;; *) return 2 ;; esac
                ;;
            --proto)
                case "$NFT_CLI_KIND:$value" in rule:tcp | rule:udp | rule:both | rule:any | limit:tcp | limit:udp) ;; *) return 2 ;; esac
                ;;
            --port) nft_cli_valid_ports "$value" || {
                vps_cmd_error '端口应为 1-65535、逗号列表、连字符范围或 any'
                return 2
            } ;;
            --source) nft_cli_valid_address "$value" || {
                vps_cmd_error '来源应为 IP/CIDR 逗号列表或 any'
                return 2
            } ;;
            --family) case "$value" in both | ipv4 | ipv6) ;; *) return 2 ;; esac ;;
            --service) [[ -z "$value" || "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || return 2 ;;
            --comment) [[ "$NFT_CLI_KIND" == rule && "$value" != *$'\n'* && "$value" != *$'\r'* && ${#value} -le 256 ]] || return 2 ;;
            --ttl)
                [[ "$NFT_CLI_KIND" == rule ]] || return 2
                expiry="$(nft_cli_ttl "$value")" || {
                    vps_cmd_error 'TTL 应为秒数或 30m、2h、7d，0 表示永久'
                    return 2
                }
                fields[expires_at]="$expiry"
                continue
                ;;
            --rate)
                [[ "$NFT_CLI_KIND" == limit ]] || return 2
                [[ -z "$value" || "$value" =~ ^[1-9][0-9]{0,8}/(second|minute|hour)$ ]] || return 2
                ;;
            --burst | --connections)
                [[ "$NFT_CLI_KIND" == limit && "$value" =~ ^[0-9]{1,9}$ ]] || return 2
                fields[$key]="$((10#$value))"
                continue
                ;;
            *)
                vps_cmd_error "未知规则选项：$option"
                return 2
                ;;
        esac
        fields[$key]="$value"
    done
    if [[ "$NFT_CLI_OPERATION" == edit || "$NFT_CLI_OPERATION" == delete ]]; then
        [[ -n "$NFT_CLI_ID" ]] || {
            vps_cmd_error '需要 --id（通过 list 查看）'
            return 2
        }
    fi
    [[ "$NFT_CLI_OPERATION" != delete || ${#fields[@]} == 0 ]] || return 2
    [[ "$NFT_CLI_OPERATION" != edit || ${#fields[@]} != 0 ]] || return 2
    vps_cmd_ensure_tools network-nftables jq || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
    for key in "${!fields[@]}"; do
        case "$key" in
            expires_at | burst | connections)
                NFT_CLI_PATCH="$(jq -c --arg key "$key" --argjson value "${fields[$key]}" '.[$key]=$value' <<<"$NFT_CLI_PATCH")" || return 2
                ;;
            *) NFT_CLI_PATCH="$(jq -c --arg key "$key" --arg value "${fields[$key]}" '.[$key]=$value' <<<"$NFT_CLI_PATCH")" || return 2 ;;
        esac
    done
}

nft_cli_rule_candidate() {
    local state="$1" key="${NFT_CLI_KIND}s" id="$NFT_CLI_ID" exists defaults patch="$NFT_CLI_PATCH" service
    service="$(jq -r '.service//empty' <<<"$patch")" || return 2
    if [[ -n "$service" ]]; then
        jq -e --arg owner "$service" '.links|has($owner)' <<<"$state" >/dev/null || {
            vps_cmd_error '未知服务 OWNER；请先 sync 并查看 link list'
            return 2
        }
    fi
    if [[ -z "$id" ]]; then id="${NFT_CLI_KIND}-$(date -u +%s)-${RANDOM}${RANDOM}"; fi
    exists="$(jq --arg key "$key" --arg id "$id" '[.[$key][] | select(.id==$id)] | length' <<<"$state")" || return 3
    case "$NFT_CLI_OPERATION:$exists" in
        add:0 | set:0) ;;
        edit:1 | delete:1 | set:1) ;;
        *)
            vps_cmd_error '规则 ID 不存在或已被使用'
            return 2
            ;;
    esac
    if [[ "$NFT_CLI_OPERATION" == delete ]]; then
        jq --arg key "$key" --arg id "$id" '.[$key] |= map(select(.id!=$id)) | .revision+=1' <<<"$state"
        return $?
    fi
    if [[ "$NFT_CLI_KIND" == rule ]]; then
        defaults='{"action":"allow","proto":"tcp","port":"any","source":"any","family":"both","service":"","comment":"","expires_at":0}'
    else defaults='{"proto":"tcp","port":"any","source":"any","family":"both","service":"","rate":"","burst":5,"connections":0}'; fi
    jq --arg key "$key" --arg id "$id" --argjson patch "$patch" --argjson defaults "$defaults" '
        if any(.[$key][]; .id==$id) then .[$key] |= map(if .id==$id then .+$patch else . end)
        else .[$key] += [$defaults+$patch+{id:$id}] end | .revision+=1' <<<"$state"
}

nft_cli_rule_apply_locked() {
    local state candidate
    state="$(vps_nft_state)" || return $?
    candidate="$(nft_cli_rule_candidate "$state")" || return $?
    nft_cli_save_json "$candidate" || return $?
    vps_cmd_success '规则已更新'
}

nft_cli_list() {
    local kind="$1" json="$2" state
    nft_cli_read_tools || return $?
    state="$(vps_nft_state)" || return $?
    if [[ "$json" == 1 ]]; then
        jq --arg key "${kind}s" '{schema_version:1,revision,enabled,($key):.[$key]}' <<<"$state"
    elif [[ "$kind" == rule ]]; then
        printf 'ID\t动作\t协议\t端口\t来源\t地址族\t服务\t到期时间\n'
        jq -r '.rules[] | [.id,.action,.proto,.port,.source,.family,.service,.expires_at] | @tsv' <<<"$state"
    else
        printf 'ID\t协议\t端口\t来源\t速率\t突发\t连接数\n'
        jq -r '.limits[] | [.id,.proto,.port,.source,.rate,.burst,.connections] | @tsv' <<<"$state"
    fi
}
