#!/usr/bin/env bash
# Standalone IPv4 relay manager. This file deliberately has no repository imports.

PO0_STATE_FILE=/etc/po0-relay/state.tsv
PO0_NFT_FILE=/etc/nftables.conf
PO0_SYSCTL_FILE=/etc/sysctl.d/99-po0-relay.conf
PO0_BACKUP_DIR=/etc/po0-relay/backups
PO0_LOCK_FILE=/run/lock/po0-relay.lock
PO0_MODE=fresh
PO0_IFACE=''
PO0_RELAY_IP=''
PO0_NEXT_ID=1
PO0_BASE_STATE=''
PO0_BASE_CONFIG=''
PO0_ANSWER=''
PO0_CHOSEN_PORT=''
declare -a PO0_IDS=() PO0_SSH_PORTS=(22) PO0_LISTEN_TCP=() PO0_LISTEN_UDP=() PO0_LOCAL_IPS=()
declare -A PO0_NAME=() PO0_ENABLED=() PO0_PROTO=() PO0_PORT=() PO0_DEST_IP=() PO0_DEST_PORT=()

po0_error() { printf '[ERROR] %s\n' "$*" >&2; }

po0_reset_state() {
    PO0_IDS=() PO0_NAME=() PO0_ENABLED=() PO0_PROTO=() PO0_PORT=() PO0_DEST_IP=() PO0_DEST_PORT=()
    PO0_IFACE='' PO0_RELAY_IP='' PO0_NEXT_ID=1 PO0_SSH_PORTS=(22)
}

po0_valid_port() {
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535))
}

po0_valid_port_spec() {
    local first=${1%-*} last=${1#*-}
    po0_valid_port "$first" && po0_valid_port "$last" && ((10#$first <= 10#$last))
}

po0_valid_ipv4() {
    local part
    local -a parts
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<<"$1"
    for part in "${parts[@]}"; do
        [[ $part =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((10#$part <= 255)) || return 1
    done
    ((10#${parts[0]} > 0 && 10#${parts[0]} < 224 && 10#${parts[0]} != 127))
}

po0_valid_name() {
    [[ -n $1 && $1 != *[[:cntrl:]]* ]]
}

po0_valid_iface() { [[ $1 =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]]; }
po0_valid_id() { [[ $1 =~ ^[1-9][0-9]{0,9}$ ]] && ((10#$1 < 2147483647)); }

po0_ports_overlap() {
    local a=${1%-*} b=${1#*-} c=${2%-*} d=${2#*-}
    ((10#$a <= 10#$d && 10#$c <= 10#$b))
}

po0_protocols_overlap() { [[ $1 == both || $2 == both || $1 == "$2" ]]; }

# Pure validation: no host probes, file writes, or dependency installation.
# Every term is required; the error branch handles failure of any term.
# shellcheck disable=SC2015
po0_validate_state() {
    local id other ssh_port has_22=0
    local -A seen=()
    po0_valid_iface "$PO0_IFACE" && po0_valid_ipv4 "$PO0_RELAY_IP" && po0_valid_id "$PO0_NEXT_ID" || {
        po0_error '状态中的网卡、内网 IPv4 或 next_id 无效。'
        return 10
    }
    ((${#PO0_SSH_PORTS[@]} > 0)) || {
        po0_error '状态缺少 SSH 保护端口。'
        return 10
    }
    for ssh_port in "${PO0_SSH_PORTS[@]}"; do
        po0_valid_port "$ssh_port" || {
            po0_error '状态中的 SSH 端口无效。'
            return 10
        }
        [[ $ssh_port != 22 ]] || has_22=1
    done
    [[ $has_22 == 1 ]] || {
        po0_error '状态缺少原有 SSH 22 端口。'
        return 10
    }
    for id in "${PO0_IDS[@]}"; do
        po0_valid_id "$id" && [[ ! ${seen[$id]+yes} ]] && ((10#$id < 10#$PO0_NEXT_ID)) || {
            po0_error '规则 ID 重复、无效或 next_id 未递增。'
            return 10
        }
        seen[$id]=1
        po0_valid_name "${PO0_NAME[$id]-}" && [[ ${PO0_ENABLED[$id]-} =~ ^[01]$ ]] &&
            [[ ${PO0_PROTO[$id]-} =~ ^(tcp|udp|both)$ ]] && po0_valid_port_spec "${PO0_PORT[$id]-}" &&
            po0_valid_ipv4 "${PO0_DEST_IP[$id]-}" && po0_valid_port "${PO0_DEST_PORT[$id]-}" || {
            po0_error "规则 $id 有无效字段。"
            return 10
        }
        [[ ${PO0_DEST_IP[$id]} != "$PO0_RELAY_IP" ]] || {
            po0_error "规则 $id 的目标是本机，会形成转发环路。"
            return 10
        }
        [[ ${PO0_ENABLED[$id]} == 1 ]] || continue
        if [[ ${PO0_PROTO[$id]} != udp ]]; then
            for ssh_port in "${PO0_SSH_PORTS[@]}"; do
                if po0_ports_overlap "${PO0_PORT[$id]}" "$ssh_port"; then
                    po0_error "规则 $id 与 SSH TCP/$ssh_port 冲突。"
                    return 10
                fi
            done
        fi
        for other in "${PO0_IDS[@]}"; do
            [[ $other != "$id" && ${PO0_ENABLED[$other]-} == 1 ]] || continue
            # Validate before arithmetic; a later record may itself be malformed.
            po0_valid_port_spec "${PO0_PORT[$other]-}" || {
                po0_error "规则 $other 端口无效。"
                return 10
            }
            if po0_protocols_overlap "${PO0_PROTO[$id]}" "${PO0_PROTO[$other]-}" &&
                po0_ports_overlap "${PO0_PORT[$id]}" "${PO0_PORT[$other]}"; then
                po0_error "规则 $id 与规则 $other 的启用端口/协议重叠。"
                return 10
            fi
        done
    done
}

po0_write_state() {
    local id port
    po0_validate_state || return $?
    printf 'PO0-RELAY\t1\nmeta\tinterface\t%s\nmeta\trelay_ip\t%s\nmeta\tnext_id\t%s\n' "$PO0_IFACE" "$PO0_RELAY_IP" "$PO0_NEXT_ID"
    for port in "${PO0_SSH_PORTS[@]}"; do printf 'ssh\t%s\n' "$port"; done
    for id in "${PO0_IDS[@]}"; do
        printf 'rule\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "${PO0_ENABLED[$id]}" "${PO0_PROTO[$id]}" "${PO0_PORT[$id]}" "${PO0_DEST_IP[$id]}" "${PO0_DEST_PORT[$id]}" "${PO0_NAME[$id]}"
    done
}

po0_load_state() {
    local line n=0 id key
    local -a fields
    local -A meta=() ids=() ssh_seen=()
    po0_reset_state
    PO0_SSH_PORTS=()
    [[ -f $1 && ! -L $1 ]] || {
        po0_error "无法读取普通状态文件: $1"
        return 10
    }
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        if ((n == 1)); then
            [[ $line == $'PO0-RELAY\t1' ]] || {
                po0_error '状态版本不支持。'
                return 10
            }
            continue
        fi
        [[ -n $line && $line != *$'\t\t'* && $line != $'\t'* && $line != *$'\t' ]] || {
            po0_error "状态第 $n 行含空字段。"
            return 10
        }
        IFS=$'\t' read -r -a fields <<<"$line"
        case ${fields[0]} in
            meta)
                [[ ${#fields[@]} == 3 ]] || return 10
                key=${fields[1]}
                [[ ! ${meta[$key]+yes} ]] || {
                    po0_error '状态元数据重复。'
                    return 10
                }
                meta[$key]=1
                case $key in
                    interface) PO0_IFACE=${fields[2]} ;;
                    relay_ip) PO0_RELAY_IP=${fields[2]} ;;
                    next_id) PO0_NEXT_ID=${fields[2]} ;;
                    *)
                        po0_error "未知状态字段: $key"
                        return 10
                        ;;
                esac
                ;;
            ssh)
                [[ ${#fields[@]} == 2 ]] && po0_valid_port "${fields[1]}" || return 10
                [[ ! ${ssh_seen[${fields[1]}]+yes} ]] || return 10
                ssh_seen[${fields[1]}]=1
                PO0_SSH_PORTS+=("${fields[1]}")
                ;;
            rule)
                [[ ${#fields[@]} == 8 ]] || {
                    po0_error "状态第 $n 行字段数错误。"
                    return 10
                }
                id=${fields[1]}
                # Either invalid IDs or duplicates take the same error path.
                # shellcheck disable=SC2015
                po0_valid_id "$id" && [[ ! ${ids[$id]+yes} ]] || {
                    po0_error '状态规则 ID 无效或重复。'
                    return 10
                }
                ids[$id]=1
                PO0_IDS+=("$id") PO0_ENABLED[$id]=${fields[2]} PO0_PROTO[$id]=${fields[3]}
                PO0_PORT[$id]=${fields[4]} PO0_DEST_IP[$id]=${fields[5]} PO0_DEST_PORT[$id]=${fields[6]} PO0_NAME[$id]=${fields[7]}
                ;;
            *)
                po0_error "状态第 $n 行类型未知。"
                return 10
                ;;
        esac
    done <"$1"
    [[ $n -gt 0 && ${#meta[@]} == 3 ]] || {
        po0_error '状态文件不完整。'
        return 10
    }
    po0_validate_state
}

# Used only to recognize the exact old generator. Comments/indentation are inert;
# every executable nft token, including the original global flush, must match.
po0_normalize_legacy() { sed '/^[[:space:]]*#/d' | tr -d '[:space:]'; }

# Dollar-prefixed names in this output are nft variables, not shell variables.
# shellcheck disable=SC2016
po0_render_legacy_template() {
    local id inputs='' mss=''
    printf 'flush ruleset\ndefine RELAY_LAN_IP = %s\n' "$PO0_RELAY_IP"
    for id in "${PO0_IDS[@]}"; do
        printf 'define DEST_IP_%s = %s\ndefine DEST_PORT_%s = %s\ndefine PORT_IN_%s = %s\n' "$id" "${PO0_DEST_IP[$id]}" "$id" "${PO0_DEST_PORT[$id]}" "$id" "${PO0_PORT[$id]}"
        inputs+="${inputs:+, }\$PORT_IN_$id"
        mss+="${mss:+, }\$DEST_IP_$id"
    done
    if ((${#PO0_IDS[@]} > 1)); then mss="{ $mss }"; fi
    cat <<EOF
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state { established, related } accept
        iif "lo" accept
        ip protocol icmp accept
        tcp dport 22 ct state new limit rate 10/minute burst 5 packets accept
        tcp dport 22 ct state established accept
        iifname "$PO0_IFACE" meta l4proto { tcp, udp } th dport { $inputs } accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state { established, related } accept
EOF
    for id in "${PO0_IDS[@]}"; do printf 'ip daddr $DEST_IP_%s meta l4proto { tcp, udp } th dport $DEST_PORT_%s accept\n' "$id" "$id"; done
    printf '}\nchain output { type filter hook output priority 0; policy accept; }\n}\ntable ip nat {\nchain prerouting { type nat hook prerouting priority dstnat; policy accept;\n'
    for id in "${PO0_IDS[@]}"; do printf 'meta l4proto { tcp, udp } th dport $PORT_IN_%s dnat to $DEST_IP_%s:$DEST_PORT_%s\n' "$id" "$id" "$id"; done
    printf '}\nchain postrouting { type nat hook postrouting priority srcnat; policy accept;\n'
    for id in "${PO0_IDS[@]}"; do printf 'ip daddr $DEST_IP_%s meta l4proto { tcp, udp } th dport $DEST_PORT_%s snat to $RELAY_LAN_IP\n' "$id" "$id"; done
    printf '}\n}\ntable ip mangle {\nchain forward { type filter hook forward priority mangle; policy accept;\nip daddr %s tcp flags syn tcp option maxseg size set 1452\n}\n}\n' "$mss"
}

po0_import_legacy() {
    local file=$1 line key value id pending='' iface_count=0 actual expected
    local define_re='^[[:space:]]*define[[:space:]]+(RELAY_LAN_IP|DEST_IP_[1-9][0-9]*|DEST_PORT_[1-9][0-9]*|PORT_IN_[1-9][0-9]*)[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$'
    local iface_re='^[[:space:]]*iifname "([^"]+)" meta l4proto'
    local name_re='^[[:space:]]*#[[:space:]]*\[(.*)\][[:space:]]*$'
    # Match the old nft variable literally, including its dollar sign.
    # shellcheck disable=SC2016
    local dnat_re='^[[:space:]]*meta l4proto.*dnat to \$DEST_IP_([1-9][0-9]*):'
    local -A defs=() names=()
    po0_reset_state
    [[ -f $file && ! -L $file ]] || {
        po0_error '旧 nft 配置不是普通文件。'
        return 10
    }
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ $define_re ]]; then
            key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
            [[ ! ${defs[$key]+yes} ]] || {
                po0_error "旧配置变量重复: $key"
                return 10
            }
            defs[$key]=$value
        elif [[ $line =~ $iface_re ]]; then
            PO0_IFACE=${BASH_REMATCH[1]} iface_count=$((iface_count + 1))
        elif [[ $line =~ $name_re ]]; then
            pending=${BASH_REMATCH[1]}
        elif [[ $line =~ $dnat_re ]]; then
            id=${BASH_REMATCH[1]}
            [[ -n $pending && ! ${names[$id]+yes} ]] || {
                po0_error '旧配置线路注释缺失或重复。'
                return 10
            }
            names[$id]=$pending pending=''
        fi
    done <"$file"
    PO0_RELAY_IP=${defs[RELAY_LAN_IP]-}
    [[ $iface_count == 1 && ${#names[@]} -gt 0 && ${#defs[@]} -eq $((${#names[@]} * 3 + 1)) ]] || {
        po0_error '不是完整的原始 PO0 模板；拒绝接管。'
        return 10
    }
    for ((id = 1; id <= ${#names[@]}; id++)); do
        [[ ${names[$id]+yes} && ${defs[DEST_IP_$id]+yes} && ${defs[DEST_PORT_$id]+yes} && ${defs[PORT_IN_$id]+yes} ]] || {
            po0_error '旧配置线路编号或变量不完整。'
            return 10
        }
        PO0_IDS+=("$id") PO0_NAME[$id]=${names[$id]} PO0_ENABLED[$id]=1 PO0_PROTO[$id]=both
        PO0_PORT[$id]=${defs[PORT_IN_$id]} PO0_DEST_IP[$id]=${defs[DEST_IP_$id]} PO0_DEST_PORT[$id]=${defs[DEST_PORT_$id]}
    done
    PO0_NEXT_ID=$((${#PO0_IDS[@]} + 1))
    po0_validate_state || return $?
    actual=$(po0_normalize_legacy <"$file") || return 20
    expected=$(po0_render_legacy_template | po0_normalize_legacy) || return 20
    [[ $actual == "$expected" ]] || {
        po0_error '旧配置含模板外内容或不完整，原文件保持不变。'
        return 10
    }
}

po0_proto_match() {
    case $1 in tcp) printf 'tcp dport' ;; udp) printf 'udp dport' ;; both) printf 'meta l4proto { tcp, udp } th dport' ;; esac
}

po0_render_rules() {
    local id port match
    po0_validate_state || return $?
    cat <<EOF
table inet filter {
    comment "po0-relay:1"
    chain input {
        type filter hook input priority 0; policy drop;
        ct state { established, related } accept
        iif "lo" accept
        ip protocol icmp accept
EOF
    for port in "${PO0_SSH_PORTS[@]}"; do
        printf '        tcp dport %s ct state new limit rate 10/minute burst 5 packets accept\n        tcp dport %s ct state established accept\n' "$port" "$port"
    done
    for id in "${PO0_IDS[@]}"; do
        [[ ${PO0_ENABLED[$id]} == 1 ]] || continue
        match=$(po0_proto_match "${PO0_PROTO[$id]}")
        printf '        iifname "%s" %s %s accept\n' "$PO0_IFACE" "$match" "${PO0_PORT[$id]}"
    done
    printf '    }\n    chain forward {\n        type filter hook forward priority 0; policy drop;\n        ct state { established, related } accept\n'
    for id in "${PO0_IDS[@]}"; do
        [[ ${PO0_ENABLED[$id]} == 1 ]] || continue
        match=$(po0_proto_match "${PO0_PROTO[$id]}")
        printf '        ip daddr %s %s %s accept\n' "${PO0_DEST_IP[$id]}" "$match" "${PO0_DEST_PORT[$id]}"
    done
    printf '    }\n    chain output { type filter hook output priority 0; policy accept; }\n}\ntable ip nat {\n    comment "po0-relay:1"\n    chain prerouting {\n        type nat hook prerouting priority dstnat; policy accept;\n'
    for id in "${PO0_IDS[@]}"; do
        [[ ${PO0_ENABLED[$id]} == 1 ]] || continue
        match=$(po0_proto_match "${PO0_PROTO[$id]}")
        printf '        iifname "%s" fib daddr type local %s %s dnat to %s:%s\n' "$PO0_IFACE" "$match" "${PO0_PORT[$id]}" "${PO0_DEST_IP[$id]}" "${PO0_DEST_PORT[$id]}"
    done
    printf '    }\n    chain postrouting {\n        type nat hook postrouting priority srcnat; policy accept;\n'
    for id in "${PO0_IDS[@]}"; do
        [[ ${PO0_ENABLED[$id]} == 1 ]] || continue
        match=$(po0_proto_match "${PO0_PROTO[$id]}")
        printf '        ip daddr %s %s %s snat to %s\n' "${PO0_DEST_IP[$id]}" "$match" "${PO0_DEST_PORT[$id]}" "$PO0_RELAY_IP"
    done
    printf '    }\n}\ntable ip mangle {\n    comment "po0-relay:1"\n    chain forward {\n        type filter hook forward priority mangle; policy accept;\n'
    for id in "${PO0_IDS[@]}"; do
        [[ ${PO0_ENABLED[$id]} == 1 && ${PO0_PROTO[$id]} != udp ]] || continue
        printf '        ip daddr %s tcp flags syn tcp option maxseg size set 1452\n' "${PO0_DEST_IP[$id]}"
    done
    printf '    }\n}\n'
}

po0_render_reset() {
    # `add table` is idempotent on supported nftables; the following delete and
    # recreation happen together in one atomic netlink batch, even at boot.
    printf 'add table inet filter\ndelete table inet filter\nadd table ip nat\ndelete table ip nat\nadd table ip mangle\ndelete table ip mangle\n'
}

po0_render_config() {
    printf '#!/usr/sbin/nft -f\n# Managed by po0-relay, schema 1. Edit through po0-relay.sh.\n'
    po0_render_reset
    po0_render_rules
}

po0_file_fingerprint() {
    if [[ -f $1 && ! -L $1 ]]; then
        sha256sum -- "$1" | cut -d ' ' -f 1
    elif [[ ! -e $1 && ! -L $1 ]]; then
        printf 'absent\n'
    else
        po0_error "拒绝非普通文件: $1"
        return 10
    fi
}

po0_is_empty_starter() {
    local text
    [[ ! -e $1 ]] && return 0
    text=$(po0_normalize_legacy <"$1") || return 20
    [[ -z $text || $text == 'flushrulesettableinetfilter{chaininput{typefilterhookinputpriorityfilter;}chainforward{typefilterhookforwardpriorityfilter;}chainoutput{typefilterhookoutputpriorityfilter;}}' ||
        $text == 'flushrulesettableinetfilter{chaininput{typefilterhookinputpriority0;}chainforward{typefilterhookforwardpriority0;}chainoutput{typefilterhookoutputpriority0;}}' ||
        $text == 'flushrulesettableinetfilter{chaininput{typefilterhookinputpriorityfilter;policyaccept;}chainforward{typefilterhookforwardpriorityfilter;policyaccept;}chainoutput{typefilterhookoutputpriorityfilter;policyaccept;}}' ]]
}

po0_load_current() {
    local rendered actual
    PO0_BASE_STATE=$(po0_file_fingerprint "$PO0_STATE_FILE") || return $?
    PO0_BASE_CONFIG=$(po0_file_fingerprint "$PO0_NFT_FILE") || return $?
    if [[ -e $PO0_STATE_FILE ]]; then
        po0_load_state "$PO0_STATE_FILE" || return $?
        [[ -f $PO0_NFT_FILE ]] || {
            po0_error '受管状态存在但 nft 配置缺失；请使用备份恢复。'
            return 10
        }
        rendered=$(po0_render_config) || return $?
        actual=$(cat -- "$PO0_NFT_FILE") || return 20
        [[ $actual == "$rendered" ]] || {
            po0_error 'nft 配置与受管状态不一致；拒绝覆盖，请先检查备份。'
            return 10
        }
        PO0_MODE=managed
    elif po0_is_empty_starter "$PO0_NFT_FILE"; then
        po0_reset_state
        PO0_MODE=fresh
    else
        po0_import_legacy "$PO0_NFT_FILE" || return $?
        PO0_MODE=legacy
    fi
}

po0_require_tools() {
    local tool package reply
    local -a missing=() packages=()
    local -A seen=()
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 && continue
        missing+=("$tool")
        case $tool in
            nft) package=nftables ;;
            ip | ss) package=iproute2 ;;
            flock) package=util-linux ;;
            sysctl) package=procps ;;
            *)
                po0_error "缺少基础命令 $tool，请安装后重试。"
                return 3
                ;;
        esac
        if [[ ! ${seen[$package]+yes} ]]; then
            packages+=("$package")
            seen[$package]=1
        fi
    done
    ((${#missing[@]} > 0)) || return 0
    printf '缺少命令: %s\n需要安装: %s\n' "${missing[*]}" "${packages[*]}" >&2
    # Both a terminal and apt-get are required; either failure is diagnosed.
    # shellcheck disable=SC2015
    [[ -t 0 && -t 1 ]] && command -v apt-get >/dev/null 2>&1 || {
        po0_error '请先安装所列依赖。'
        return 3
    }
    read -r -p '现在使用 apt-get 安装这些依赖？[y/N] ' reply || return 130
    [[ $reply == y || $reply == Y ]] || return 130
    # Failure of either apt operation must report installation failure.
    # shellcheck disable=SC2015
    apt-get update && apt-get install -y -- "${packages[@]}" || {
        po0_error '依赖安装失败。'
        return 20
    }
    for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 || return 3; done
}

# Read-only host discovery. Socket data is intentionally refreshed under the
# apply lock too, so an old menu view cannot silently reuse a newly bound port.
po0_collect_host() {
    local output line proto endpoint port word address unit index=0 relevant
    local -a words=() ingress_ips=()
    local -A ssh_seen=()
    PO0_LISTEN_TCP=() PO0_LISTEN_UDP=() PO0_LOCAL_IPS=()
    output=$(ip -o -4 addr show) || {
        po0_error '无法读取本机 IPv4。'
        return 20
    }
    while IFS= read -r line; do
        IFS=' ' read -r -a words <<<"$line"
        for ((index = 0; index < ${#words[@]} - 1; index++)); do
            word=${words[$index]}
            if [[ $word == inet || $word == brd ]]; then
                endpoint=${words[$((index + 1))]}
                address=${endpoint%/*}
                PO0_LOCAL_IPS+=("$address")
                if [[ $word == inet && $address != 127.* && (-z $PO0_IFACE || ${words[1]%@*} == "$PO0_IFACE") ]]; then
                    ingress_ips+=("$address")
                fi
            fi
        done
    done <<<"$output"
    for port in "${PO0_SSH_PORTS[@]}" 22; do ssh_seen[$port]=1; done
    if [[ -n ${SSH_CONNECTION-} ]]; then
        IFS=' ' read -r -a words <<<"$SSH_CONNECTION"
        if ((${#words[@]} == 4)) && po0_valid_port "${words[3]}"; then ssh_seen[${words[3]}]=1; fi
    fi
    if command -v sshd >/dev/null 2>&1; then
        if output=$(sshd -T 2>/dev/null); then
            while IFS=' ' read -r word port _; do
                if [[ $word == port ]] && po0_valid_port "$port"; then ssh_seen[$port]=1; fi
            done <<<"$output"
        fi
    fi
    output=$(ss -H -lntu) || {
        po0_error '无法检查本机监听端口。'
        return 20
    }
    while IFS=' ' read -r proto _ _ _ endpoint _; do
        [[ -n $proto ]] || continue
        port=${endpoint##*:}
        po0_valid_port "$port" || continue
        address=${endpoint%:*}
        relevant=0
        case $address in '*' | 0.0.0.0 | '[::]' | '::') relevant=1 ;;
        *)
            for word in "${ingress_ips[@]}"; do [[ $address != "$word" ]] || relevant=1; done
            ;;
        esac
        [[ $relevant == 1 ]] || continue
        case $proto in tcp) PO0_LISTEN_TCP+=("$port") ;; udp) PO0_LISTEN_UDP+=("$port") ;; esac
    done <<<"$output"
    output=$(ss -H -lntp) || {
        po0_error '无法检查 SSH 监听端口。'
        return 20
    }
    while IFS= read -r line; do
        [[ $line == *'"sshd"'* ]] || continue
        IFS=' ' read -r -a words <<<"$line"
        ((${#words[@]} >= 4)) || continue
        port=${words[3]##*:}
        if po0_valid_port "$port"; then ssh_seen[$port]=1; fi
    done <<<"$output"
    # On socket-activated systems PID 1 owns the SSH listener. Only query the
    # named SSH socket units: other systemd listeners must not become openings.
    if command -v systemctl >/dev/null 2>&1; then
        for unit in ssh.socket sshd.socket; do
            if output=$(systemctl show "$unit" --property=Listen --value 2>/dev/null); then
                while IFS= read -r line; do
                    IFS=' ' read -r -a words <<<"$line"
                    for word in "${words[@]}"; do
                        port=${word##*:}
                        if po0_valid_port "$port"; then ssh_seen[$port]=1; fi
                    done
                done <<<"$output"
            fi
        done
    fi
    PO0_SSH_PORTS=()
    while IFS= read -r port; do PO0_SSH_PORTS+=("$port"); done < <(printf '%s\n' "${!ssh_seen[@]}" | sort -n)
}

po0_check_target() {
    local address
    po0_valid_ipv4 "$1" || {
        po0_error '请输入有效的 IPv4 单播地址。'
        return 10
    }
    for address in "${PO0_LOCAL_IPS[@]}" "$PO0_RELAY_IP"; do
        [[ $1 != "$address" ]] || {
            po0_error '目标是本机或本机广播地址，会形成环路。'
            return 10
        }
    done
}

po0_check_conflicts() {
    local incoming=$1 protocol=$2 exclude=${3-} id port
    po0_valid_port_spec "$incoming" && [[ $protocol =~ ^(tcp|udp|both)$ ]] || return 10
    for id in "${PO0_IDS[@]}"; do
        [[ $id != "$exclude" && ${PO0_ENABLED[$id]} == 1 ]] || continue
        if po0_protocols_overlap "$protocol" "${PO0_PROTO[$id]}" && po0_ports_overlap "$incoming" "${PO0_PORT[$id]}"; then
            po0_error "端口/协议与规则 $id (${PO0_NAME[$id]}) 重叠。"
            return 10
        fi
    done
    if [[ $protocol != udp ]]; then
        for port in "${PO0_SSH_PORTS[@]}" "${PO0_LISTEN_TCP[@]}"; do
            if po0_ports_overlap "$incoming" "$port"; then
                po0_error "TCP/$port 已由 SSH 或本机监听占用。"
                return 10
            fi
        done
    fi
    if [[ $protocol != tcp ]]; then
        for port in "${PO0_LISTEN_UDP[@]}"; do
            if po0_ports_overlap "$incoming" "$port"; then
                po0_error "UDP/$port 已由本机监听占用。"
                return 10
            fi
        done
    fi
}

po0_check_host_state() {
    local id addresses address found=0
    po0_validate_state || return $?
    ip link show dev "$PO0_IFACE" >/dev/null || {
        po0_error "原网卡 $PO0_IFACE 不存在；拒绝自动替换。"
        return 3
    }
    addresses=$(ip -o -4 addr show dev "$PO0_IFACE") || return 20
    while IFS= read -r address; do
        [[ $address == *" inet $PO0_RELAY_IP/"* ]] && found=1
    done <<<"$addresses"
    [[ $found == 1 ]] || {
        po0_error "原地址 $PO0_RELAY_IP 不在网卡 $PO0_IFACE 上；请先恢复网络配置。"
        return 3
    }
    for id in "${PO0_IDS[@]}"; do
        po0_check_target "${PO0_DEST_IP[$id]}" || return $?
        [[ ${PO0_ENABLED[$id]} == 1 ]] || continue
        po0_check_conflicts "${PO0_PORT[$id]}" "${PO0_PROTO[$id]}" "$id" || return $?
    done
}

po0_atomic_write() {
    local source=$1 target=$2 mode=$3 temporary
    temporary=$(mktemp "${target}.tmp.XXXXXX") || return 20
    if ! cp -- "$source" "$temporary" || ! chmod "$mode" "$temporary" || ! mv -f -- "$temporary" "$target"; then
        rm -f -- "$temporary" || true
        return 20
    fi
}

po0_restore_file() {
    local original=$1 target=$2 temporary
    if [[ -e $original ]]; then
        temporary=$(mktemp "${target}.restore.XXXXXX") || return 20
        if ! cp -p -- "$original" "$temporary" || ! mv -f -- "$temporary" "$target"; then
            rm -f -- "$temporary" || true
            return 20
        fi
    else
        rm -f -- "$target" || return 20
    fi
}

po0_restore_service() {
    case $PO0_OLD_SERVICE in
        enabled) systemctl enable nftables >/dev/null ;;
        enabled-runtime) systemctl disable nftables >/dev/null && systemctl enable --runtime nftables >/dev/null ;;
        disabled) systemctl disable nftables >/dev/null ;;
        *) return 0 ;;
    esac
}

po0_rollback() {
    local failed=0
    if [[ $PO0_RUNTIME_TOUCHED == 1 ]]; then
        nft -c -f "$PO0_TX_DIR/runtime-restore.nft" && nft -f "$PO0_TX_DIR/runtime-restore.nft" || failed=1
    fi
    if [[ $PO0_FILES_TOUCHED == 1 ]]; then
        po0_restore_file "$PO0_TX_DIR/state.before" "$PO0_STATE_FILE" || failed=1
        po0_restore_file "$PO0_TX_DIR/nftables.before" "$PO0_NFT_FILE" || failed=1
        po0_restore_file "$PO0_TX_DIR/sysctl.before" "$PO0_SYSCTL_FILE" || failed=1
    fi
    if [[ $PO0_SYSCTL_TOUCHED == 1 ]]; then sysctl -q -w "net.ipv4.ip_forward=$PO0_OLD_FORWARD" || failed=1; fi
    if [[ $PO0_SERVICE_TOUCHED == 1 ]]; then po0_restore_service || failed=1; fi
    [[ $failed == 0 ]]
}

po0_transaction_exit() {
    local status=$1
    trap - EXIT
    trap '' HUP INT TERM
    if [[ $PO0_COMMITTED != 1 && $PO0_TX_READY == 1 ]]; then
        if po0_rollback; then
            po0_error "操作未提交，已恢复原规则、文件、转发参数和服务启用状态。备份: $PO0_TX_DIR"
        else
            po0_error "自动恢复未完成。请在 root 控制台执行: bash '$PO0_TX_DIR/recover.sh'"
            status=30
        fi
    fi
    exit "$status"
}

# Shell variables in these printf templates expand when the saved recovery
# script runs. Actual paths are inserted with %q, not interpolated as code.
# shellcheck disable=SC2016
po0_make_recovery() {
    local original target
    {
        printf '#!/usr/bin/env bash\nset -euo pipefail\n[[ $EUID == 0 ]] || { echo "Run as root" >&2; exit 4; }\n'
        printf 'exec 9>%q\nflock -w 10 9\nnft -c -f %q\nnft -f %q\n' "$PO0_LOCK_FILE" "$PO0_TX_DIR/runtime-restore.nft" "$PO0_TX_DIR/runtime-restore.nft"
        for original in state nftables sysctl; do
            case $original in state) target=$PO0_STATE_FILE ;; nftables) target=$PO0_NFT_FILE ;; sysctl) target=$PO0_SYSCTL_FILE ;; esac
            if [[ -f $PO0_TX_DIR/$original.before ]]; then
                printf 'temporary=$(mktemp %q)\ncp -p -- %q "$temporary"\nmv -f -- "$temporary" %q\n' "${target}.restore.XXXXXX" "$PO0_TX_DIR/$original.before" "$target"
            else
                printf 'rm -f -- %q\n' "$target"
            fi
        done
        printf 'sysctl -q -w net.ipv4.ip_forward=%q\n' "$PO0_OLD_FORWARD"
        case $PO0_OLD_SERVICE in
            enabled) printf 'systemctl enable nftables\n' ;;
            enabled-runtime) printf 'systemctl disable nftables\nsystemctl enable --runtime nftables\n' ;;
            disabled) printf 'systemctl disable nftables\n' ;;
        esac
        printf 'echo "PO0 previous state restored; foreign nft tables were retained."\n'
    } >"$PO0_TX_DIR/recover.sh" || return 20
    chmod 700 "$PO0_TX_DIR/recover.sh" || return 20
}

# Caller supplies desired in-memory state after po0_load_current. The subshell
# owns the lock and traps; explicit error handling also works inside `if` calls.
po0_apply() (
    set -Eeuo pipefail
    IFS=$'\n\t'
    umask 077
    local lock_fd state_dir tables table family name listing current fingerprint
    PO0_TX_DIR='' PO0_TX_READY=0 PO0_COMMITTED=0 PO0_RUNTIME_TOUCHED=0 PO0_FILES_TOUCHED=0 PO0_SYSCTL_TOUCHED=0 PO0_SERVICE_TOUCHED=0
    [[ $EUID == 0 ]] || {
        po0_error '应用规则需要 root。'
        exit 4
    }
    po0_require_tools nft ip ss flock sysctl systemctl sha256sum mktemp || exit $?
    exec {lock_fd}>"$PO0_LOCK_FILE" || exit 20
    flock -w 10 "$lock_fd" || {
        po0_error '另一个 PO0 操作正在执行，请稍后重试。'
        exit 3
    }
    fingerprint=$(po0_file_fingerprint "$PO0_STATE_FILE") || exit $?
    [[ $fingerprint == "$PO0_BASE_STATE" ]] || {
        po0_error '状态已被其他操作更新；请重新打开操作。'
        exit 10
    }
    fingerprint=$(po0_file_fingerprint "$PO0_NFT_FILE") || exit $?
    [[ $fingerprint == "$PO0_BASE_CONFIG" ]] || {
        po0_error 'nft 配置已改变；拒绝覆盖，请重新加载。'
        exit 10
    }
    po0_collect_host || exit $?
    po0_check_host_state || exit $?
    if [[ -L $PO0_SYSCTL_FILE || (-e $PO0_SYSCTL_FILE && ! -f $PO0_SYSCTL_FILE) ]]; then
        po0_error 'sysctl 文件不是普通文件。'
        exit 10
    fi
    if [[ -f $PO0_SYSCTL_FILE ]]; then
        current=$(cat -- "$PO0_SYSCTL_FILE") || exit 20
        [[ $current == $'# Managed by po0-relay. Existing tuning in other files is preserved.\nnet.ipv4.ip_forward = 1' ]] || {
            po0_error "拒绝覆盖非受管 sysctl 文件: $PO0_SYSCTL_FILE"
            exit 10
        }
    fi
    if PO0_OLD_SERVICE=$(systemctl is-enabled nftables 2>/dev/null); then :; else :; fi
    case $PO0_OLD_SERVICE in enabled | enabled-runtime | disabled) ;;
    *)
        po0_error "nftables 服务状态为 $PO0_OLD_SERVICE；请先确认服务已安装且未被屏蔽。"
        exit 3
        ;;
    esac
    PO0_OLD_FORWARD=$(sysctl -n net.ipv4.ip_forward) || exit 20
    [[ $PO0_OLD_FORWARD =~ ^[01]$ ]] || {
        po0_error '无法确认原 ip_forward。'
        exit 20
    }
    tables=$(nft list tables) || {
        po0_error '无法读取现有 nft 表。'
        exit 20
    }
    for table in 'inet filter' 'ip nat' 'ip mangle'; do
        IFS=' ' read -r family name <<<"$table"
        if [[ $'\n'$tables$'\n' == *$'\n'"table $table"$'\n'* ]]; then
            [[ $PO0_MODE != fresh ]] || {
                po0_error "已有 $table 表；拒绝接管无关防火墙。"
                exit 10
            }
            if [[ $PO0_MODE == managed ]]; then
                listing=$(nft -s list table "$family" "$name") || exit 20
                [[ $listing == *'comment "po0-relay:1"'* ]] || {
                    po0_error "$table 不含 PO0 所有权标记，拒绝覆盖。"
                    exit 10
                }
            fi
        fi
    done
    state_dir=$(dirname -- "$PO0_STATE_FILE") || exit 20
    for current in "$state_dir" "$PO0_BACKUP_DIR" "$(dirname -- "$PO0_NFT_FILE")" "$(dirname -- "$PO0_SYSCTL_FILE")"; do
        [[ ! -L $current ]] || {
            po0_error "拒绝符号链接目录: $current"
            exit 10
        }
    done
    mkdir -p -- "$state_dir" "$PO0_BACKUP_DIR" || exit 20
    chmod 700 "$state_dir" "$PO0_BACKUP_DIR" || exit 20
    PO0_TX_DIR=$(mktemp -d "$PO0_BACKUP_DIR/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || exit 20
    trap 'po0_transaction_exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    [[ ! -f $PO0_STATE_FILE ]] || cp -p -- "$PO0_STATE_FILE" "$PO0_TX_DIR/state.before" || exit 20
    [[ ! -f $PO0_NFT_FILE ]] || cp -p -- "$PO0_NFT_FILE" "$PO0_TX_DIR/nftables.before" || exit 20
    [[ ! -f $PO0_SYSCTL_FILE ]] || cp -p -- "$PO0_SYSCTL_FILE" "$PO0_TX_DIR/sysctl.before" || exit 20
    printf 'ip_forward=%s\nnftables_enabled=%s\nsource_mode=%s\n' "$PO0_OLD_FORWARD" "$PO0_OLD_SERVICE" "$PO0_MODE" >"$PO0_TX_DIR/before.txt" || exit 20
    po0_render_reset >"$PO0_TX_DIR/runtime-restore.nft" || exit 20
    for table in 'inet filter' 'ip nat' 'ip mangle'; do
        IFS=' ' read -r family name <<<"$table"
        if [[ $'\n'$tables$'\n' == *$'\n'"table $table"$'\n'* ]]; then
            nft -s list table "$family" "$name" >>"$PO0_TX_DIR/runtime-restore.nft" || exit 20
        fi
    done
    po0_write_state >"$PO0_TX_DIR/state.candidate" || exit $?
    po0_render_config >"$PO0_TX_DIR/nftables.candidate" || exit $?
    printf '# Managed by po0-relay. Existing tuning in other files is preserved.\nnet.ipv4.ip_forward = 1\n' >"$PO0_TX_DIR/sysctl.candidate" || exit 20
    po0_make_recovery || exit $?
    nft -c -f "$PO0_TX_DIR/nftables.candidate" || {
        po0_error 'nft 候选配置检查失败，未修改运行规则。'
        exit 10
    }
    PO0_TX_READY=1
    # Set flags BEFORE each external operation so signal delivery immediately
    # after a successful operation still causes its rollback.
    PO0_RUNTIME_TOUCHED=1
    nft -f "$PO0_TX_DIR/nftables.candidate" || {
        po0_error 'nft 原子应用失败。'
        exit 20
    }
    if [[ $PO0_OLD_FORWARD != 1 ]]; then
        PO0_SYSCTL_TOUCHED=1
        sysctl -q -w net.ipv4.ip_forward=1 || exit 20
    fi
    PO0_FILES_TOUCHED=1
    po0_atomic_write "$PO0_TX_DIR/sysctl.candidate" "$PO0_SYSCTL_FILE" 644 || exit $?
    po0_atomic_write "$PO0_TX_DIR/nftables.candidate" "$PO0_NFT_FILE" 644 || exit $?
    po0_atomic_write "$PO0_TX_DIR/state.candidate" "$PO0_STATE_FILE" 600 || exit $?
    if [[ $PO0_OLD_SERVICE != enabled ]]; then
        PO0_SERVICE_TOUCHED=1
        systemctl enable nftables || exit 20
    fi
    PO0_COMMITTED=1
    printf '已应用。备份: %s\nroot 控制台恢复: bash %q\n' "$PO0_TX_DIR" "$PO0_TX_DIR/recover.sh"
)

po0_list() {
    local id state mode protocol
    case $PO0_MODE in fresh) mode=未初始化 ;; legacy) mode=旧版配置 ;; managed) mode=已接管 ;; *) mode=$PO0_MODE ;; esac
    printf '\n模式: %s  网卡: %s  SNAT IPv4: %s\n' "$mode" "${PO0_IFACE:-尚未选择}" "${PO0_RELAY_IP:-尚未选择}"
    printf 'ID | 名称 | 状态 | 协议 | 中转端口 → 目标\n'
    for id in "${PO0_IDS[@]}"; do
        state=禁用
        [[ ${PO0_ENABLED[$id]} != 1 ]] || state=启用
        case ${PO0_PROTO[$id]} in tcp) protocol=TCP ;; udp) protocol=UDP ;; both) protocol=TCP+UDP ;; esac
        printf '%s | %s | %s | %s | %s → %s:%s\n' "$id" "${PO0_NAME[$id]}" "$state" "$protocol" "${PO0_PORT[$id]}" "${PO0_DEST_IP[$id]}" "${PO0_DEST_PORT[$id]}"
    done
    ((${#PO0_IDS[@]} > 0)) || printf '暂无规则。\n'
    [[ $PO0_MODE != legacy ]] || printf '旧配置仅导入内存；首次确认变更时才备份并迁移。\n'
}

po0_status() {
    local table family name value
    po0_list
    printf '\n状态文件: %s\nnft 配置: %s\n' "$PO0_STATE_FILE" "$PO0_NFT_FILE"
    if command -v sysctl >/dev/null 2>&1; then
        value=$(sysctl -n net.ipv4.ip_forward) || return 20
        printf 'IPv4 转发: %s\n' "$value"
    else printf 'IPv4 转发: 缺少 sysctl，未查询\n'; fi
    if command -v systemctl >/dev/null 2>&1; then
        if value=$(systemctl is-enabled nftables 2>/dev/null); then :; else :; fi
        printf 'nftables 开机启用状态: %s\n' "${value:-未知}"
        if value=$(systemctl is-active nftables 2>/dev/null); then :; else :; fi
        printf 'nftables 服务状态: %s（运行规则以 nft 为准）\n' "${value:-未知}"
    fi
    if command -v nft >/dev/null 2>&1; then
        for table in 'inet filter' 'ip nat' 'ip mangle'; do
            IFS=' ' read -r family name <<<"$table"
            printf '\n--- %s ---\n' "$table"
            if ! nft -s list table "$family" "$name"; then
                po0_error "$table 不存在或无法读取；可在检查配置后选择重新应用。"
            fi
        done
    else printf '缺少 nft，未查询运行规则；查看状态不会安装依赖。\n'; fi
    printf '\n禁用、删除、修改规则影响新连接；已有连接等待 conntrack 自然过期。\n'
}

# The answer lives in a variable instead of command substitution, so prompts
# and cancellation have no filesystem side effects and validators can retry.
po0_prompt() {
    local label=$1 default=${2-}
    PO0_ANSWER=''
    if [[ -n $default ]]; then label+=" [$default]"; fi
    read -r -p "$label (:q 取消): " PO0_ANSWER || return 130
    [[ $PO0_ANSWER != :q ]] || return 130
    PO0_ANSWER=${PO0_ANSWER:-$default}
}

po0_read_value() {
    local kind=$1 label=$2 default=${3-}
    while :; do
        po0_prompt "$label" "$default" || return $?
        case $kind in
            name)
                po0_valid_name "$PO0_ANSWER" && return 0
                po0_error '名称不能为空，不能包含制表符、换行或其他控制字符。'
                ;;
            target) po0_check_target "$PO0_ANSWER" && return 0 ;;
            port)
                po0_valid_port "$PO0_ANSWER" && return 0
                po0_error '目标端口须为 1–65535 的单个端口。'
                ;;
            *)
                po0_error '内部输入类型错误。'
                return 70
                ;;
        esac
    done
}

po0_random_port() {
    local exclude=${1-} candidate attempt
    for ((attempt = 0; attempt < 256; attempt++)); do
        candidate=$(((((RANDOM << 1) ^ RANDOM) % 50000) + 10000))
        if po0_check_conflicts "$candidate" both "$exclude" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    po0_error '未找到空闲随机端口，请手动填写端口。'
    return 10
}

po0_read_incoming() {
    local default=${1-} protocol=${2:-any} exclude=${3-} enabled=${4:-1} candidate label
    label='中转端口或范围，如 20000 或 20000-20010'
    [[ -n $default ]] || label+='，留空随机'
    while :; do
        po0_prompt "$label" "$default" || return $?
        candidate=$PO0_ANSWER
        if [[ -z $candidate ]]; then candidate=$(po0_random_port "$exclude") || continue; fi
        if ! po0_valid_port_spec "$candidate"; then
            po0_error '中转端口须为 1–65535，范围必须从小到大。'
            continue
        fi
        if [[ $enabled == 1 ]]; then
            # Add asks protocol last; explicit ports get their conflict check
            # at that step. Random choices above must be free for both.
            if [[ $protocol != any ]] && ! po0_check_conflicts "$candidate" "$protocol" "$exclude"; then continue; fi
        fi
        PO0_ANSWER=$candidate
        return 0
    done
}

po0_read_protocol() {
    local old=${1:-both} incoming=$2 exclude=${3-} enabled=${4:-1} allow_port_change=${5:-0} default protocol conflict=0
    PO0_CHOSEN_PORT=$incoming
    case $old in tcp) default=1 ;; udp) default=2 ;; both) default=3 ;; *) return 70 ;; esac
    while :; do
        printf '1) TCP   2) UDP   3) TCP + UDP\n'
        if [[ $allow_port_change == 1 && $conflict == 1 ]]; then printf '4) 修改中转端口（保留其他已填内容）\n'; fi
        po0_prompt '协议编号' "$default" || return $?
        case $PO0_ANSWER in 1) protocol=tcp ;; 2) protocol=udp ;; 3) protocol=both ;;
        4)
            if [[ $allow_port_change == 1 && $conflict == 1 ]]; then
                po0_read_incoming "$incoming" any "$exclude" "$enabled" || return $?
                incoming=$PO0_ANSWER PO0_CHOSEN_PORT=$PO0_ANSWER
                continue
            fi
            po0_error '请选择 1、2 或 3。'
            continue
            ;;
        *)
            po0_error '请选择 1、2 或 3。'
            continue
            ;;
        esac
        if [[ $enabled == 1 ]] && ! po0_check_conflicts "$incoming" "$protocol" "$exclude"; then
            conflict=1
            continue
        fi
        PO0_ANSWER=$protocol
        return 0
    done
}

po0_choose_initial_network() {
    local routes line iface='' address index value
    local -a words=() choices=()
    local -A interfaces=() seen=()
    [[ $PO0_MODE == fresh ]] || return 0
    routes=$(ip -o -4 route show default) || return 20
    while IFS= read -r line; do
        IFS=' ' read -r -a words <<<"$line"
        for ((index = 0; index < ${#words[@]} - 1; index++)); do
            if [[ ${words[$index]} == dev ]]; then
                iface=${words[$((index + 1))]}
                po0_valid_iface "$iface" && interfaces[$iface]=1
            fi
        done
    done <<<"$routes"
    ((${#interfaces[@]} > 0)) || {
        po0_error '找不到 IPv4 默认路由网卡，请先配置默认路由。'
        return 3
    }
    for iface in "${!interfaces[@]}"; do
        routes=$(ip -o -4 addr show dev "$iface" scope global) || return 20
        while IFS= read -r line; do
            IFS=' ' read -r -a words <<<"$line"
            for ((index = 0; index < ${#words[@]} - 1; index++)); do
                [[ ${words[$index]} == inet ]] || continue
                address=${words[$((index + 1))]%/*}
                if po0_valid_ipv4 "$address" && [[ ! ${seen[$iface / $address]+yes} ]]; then
                    choices+=("$iface $address") seen[$iface / $address]=1
                fi
            done
        done <<<"$routes"
    done
    ((${#choices[@]} > 0)) || {
        po0_error '默认网卡没有可用 IPv4 地址。'
        return 3
    }
    if ((${#choices[@]} == 1)); then
        value=${choices[0]}
    else
        printf '发现多个默认路由网卡/地址，请选择本机入站网卡和 SNAT 地址:\n'
        for ((index = 0; index < ${#choices[@]}; index++)); do printf '%s) %s\n' "$((index + 1))" "${choices[$index]}"; done
        while :; do
            po0_prompt '网卡/地址编号' || return $?
            if [[ $PO0_ANSWER =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$PO0_ANSWER <= ${#choices[@]})); then
                value=${choices[$((10#$PO0_ANSWER - 1))]}
                break
            fi
            po0_error '请输入列表中的编号。'
        done
    fi
    IFS=' ' read -r PO0_IFACE PO0_RELAY_IP <<<"$value"
    printf '本次初始化: 网卡 %s，SNAT 地址 %s。\n' "$PO0_IFACE" "$PO0_RELAY_IP"
    po0_collect_host
}

po0_prepare_change() {
    # Installing nftables may create its empty starter configuration. Do this
    # only for a selected mutation, before taking the optimistic-lock snapshot.
    po0_require_tools nft ip ss flock sysctl systemctl sha256sum mktemp || return $?
    po0_load_current || return $?
    po0_collect_host
}

po0_confirm_change() {
    local operation=$1 reply
    po0_validate_state || return $?
    po0_list
    printf '\n本次变更: %s\n' "$operation"
    printf '只更新 inet filter / ip nat / ip mangle；INPUT/FORWARD 默认丢弃。\n'
    printf '保留 SSH TCP 端口: '
    printf '%s ' "${PO0_SSH_PORTS[@]}"
    printf '\nIPv4 转发设为 1，其他现有 sysctl 调优保留；启用 nftables 开机加载。\n'
    printf '已有连接自然过期；不清空 conntrack。备份和 root 恢复脚本将保存在 %s。\n' "$PO0_BACKUP_DIR"
    printf '更改防火墙可能影响 SSH，请保留当前会话及服务商 root 控制台。\n'
    read -r -p '确认这次变更？[y/N] ' reply || return 130
    [[ $reply == y || $reply == Y ]] || return 130
}

po0_select_rule() {
    local id
    ((${#PO0_IDS[@]} > 0)) || {
        po0_error '暂无可操作规则。'
        return 3
    }
    po0_list
    while :; do
        po0_prompt '规则 ID' || return $?
        for id in "${PO0_IDS[@]}"; do [[ $PO0_ANSWER != "$id" ]] || return 0; done
        po0_error '请输入现有规则的 ID。'
    done
}

# Every edit happens in a subshell. Declining any prompt discards all changes,
# including new IDs, discovery metadata and partially entered rule fields.
# shellcheck disable=SC2030
po0_action_add() (
    local id name incoming target port protocol
    po0_prepare_change || return $?
    id=$PO0_NEXT_ID
    po0_read_value name '规则名称' "线路$id" || return $?
    name=$PO0_ANSWER
    po0_read_incoming || return $?
    incoming=$PO0_ANSWER
    po0_read_value target '目标 IPv4' || return $?
    target=$PO0_ANSWER
    po0_read_value port '目标端口（单个固定端口）' || return $?
    port=$PO0_ANSWER
    po0_read_protocol both "$incoming" '' 1 1 || return $?
    protocol=$PO0_ANSWER incoming=$PO0_CHOSEN_PORT
    PO0_IDS+=("$id") PO0_NAME[$id]=$name PO0_ENABLED[$id]=1 PO0_PROTO[$id]=$protocol
    PO0_PORT[$id]=$incoming PO0_DEST_IP[$id]=$target PO0_DEST_PORT[$id]=$port PO0_NEXT_ID=$((id + 1))
    po0_choose_initial_network || return $?
    po0_confirm_change "新增规则 $id" || return $?
    po0_apply
)

# Reload disk state first; only a successful apply persists this subshell's edit.
# shellcheck disable=SC2030,SC2031
po0_action_edit() (
    local id field
    po0_prepare_change || return $?
    po0_select_rule || return $?
    id=$PO0_ANSWER
    while :; do
        printf '1) 名称  2) 中转端口  3) 目标 IPv4  4) 目标端口  5) 协议\n'
        po0_prompt '编辑字段编号' || return $?
        field=$PO0_ANSWER
        [[ $field =~ ^[1-5]$ ]] && break
        po0_error '请选择 1–5。'
    done
    case $field in
        1)
            po0_read_value name '规则名称' "${PO0_NAME[$id]}" || return $?
            PO0_NAME[$id]=$PO0_ANSWER
            ;;
        2)
            po0_read_incoming "${PO0_PORT[$id]}" "${PO0_PROTO[$id]}" "$id" "${PO0_ENABLED[$id]}" || return $?
            PO0_PORT[$id]=$PO0_ANSWER
            ;;
        3)
            po0_read_value target '目标 IPv4' "${PO0_DEST_IP[$id]}" || return $?
            PO0_DEST_IP[$id]=$PO0_ANSWER
            ;;
        4)
            po0_read_value port '目标端口' "${PO0_DEST_PORT[$id]}" || return $?
            PO0_DEST_PORT[$id]=$PO0_ANSWER
            ;;
        5)
            po0_read_protocol "${PO0_PROTO[$id]}" "${PO0_PORT[$id]}" "$id" "${PO0_ENABLED[$id]}" || return $?
            PO0_PROTO[$id]=$PO0_ANSWER
            ;;
    esac
    po0_confirm_change "编辑规则 $id" || return $?
    po0_apply
)

# Previous action subshells are irrelevant: prepare_change reloads disk state.
# shellcheck disable=SC2031
po0_action_toggle() (
    local id action=启用
    po0_prepare_change || return $?
    po0_select_rule || return $?
    id=$PO0_ANSWER
    if [[ ${PO0_ENABLED[$id]} == 1 ]]; then
        PO0_ENABLED[$id]=0
        action=禁用
    else
        po0_check_conflicts "${PO0_PORT[$id]}" "${PO0_PROTO[$id]}" "$id" || return $?
        PO0_ENABLED[$id]=1
    fi
    po0_confirm_change "$action 规则 $id" || return $?
    po0_apply
)

# Previous action subshells are irrelevant: prepare_change reloads disk state.
# shellcheck disable=SC2031
po0_action_delete() (
    local id other
    local -a remaining=()
    po0_prepare_change || return $?
    po0_select_rule || return $?
    id=$PO0_ANSWER
    for other in "${PO0_IDS[@]}"; do [[ $other == "$id" ]] || remaining+=("$other"); done
    PO0_IDS=("${remaining[@]}")
    po0_confirm_change "删除规则 $id (${PO0_NAME[$id]})" || return $?
    po0_apply
)

po0_action_reapply() (
    po0_prepare_change || return $?
    [[ $PO0_MODE != fresh ]] || {
        po0_error '尚未初始化，请先新增规则。'
        return 3
    }
    po0_confirm_change '重新应用全部当前规则' || return $?
    po0_apply
)

po0_help() {
    cat <<'EOF'
PO0 IPv4 中转管理（独立单文件，Ubuntu 22.04/24.04、Debian + systemd + nftables）

用法:
  sudo bash po0-relay.sh            终端交互菜单
  sudo bash po0-relay.sh --status   只读查看，不安装依赖或改写配置
  bash po0-relay.sh --help          本帮助

菜单: 列表、新增、逐字段编辑、启用/禁用、删除、状态、重新应用、退出。
输入 :q 可取消；确认默认否。端口可为单个或范围，统一映射到固定目标端口。
协议用编号选择，默认 TCP+UDP；新增中转端口留空时生成并检查随机端口。
仅支持 IPv4 字面地址；没有域名、IPv6、批量 CLI 或 dry-run 参数。

状态: /etc/po0-relay/state.tsv（版本化纯 TSV，不作为 Shell 执行）
旧版: 完整识别原始 /etc/nftables.conf，查看不落盘；首次确认变更时迁移。
仅管理 inet filter、ip nat、ip mangle，其他表保留；从不全局 flush 或重启 nftables。
INPUT/FORWARD 默认丢弃，保留本机发现的 SSH TCP 端口和原 22、MSS 1452。
仅设置必要的 ip_forward=1，旧 sysctl 优化配置保留；启用 nftables 开机加载。
禁止接管未知 nft 配置/同名表；缺少依赖时在需要时明确询问安装。
禁用/删除/修改影响新连接，已有连接由 conntrack 自然过期。

注意: 更改防火墙可能影响 SSH，请保留当前 SSH 会话及服务商 root 控制台。
每次修改先 nft -c 校验并保留备份，失败或 HUP/INT/TERM 自动回滚。
备份: /etc/po0-relay/backups/<UTC时间.随机串>/
恢复: 在 root 控制台执行 bash /etc/po0-relay/backups/<对应目录>/recover.sh
恢复只替换原三张表，并恢复旧文件、ip_forward 和服务开机启用状态。
断电或 SIGKILL 不能触发 Shell 回滚；如遇文件不一致，用上述脚本恢复后重试。
不支持自动关闭 UFW/firewalld 等其他防火墙，请避免同时管理同一组表。
EOF
}

po0_main() {
    local option status
    if [[ ${1-} == --help && $# == 1 ]]; then
        po0_help
        return 0
    fi
    if [[ ${1-} == -- ]]; then shift; fi
    if [[ $# -gt 1 || ($# == 1 && $1 != --status) ]]; then
        po0_error '只支持 --help、--status 或无参数菜单。'
        return 2
    fi
    option=${1-}
    if [[ -z $option && (! -t 0 || ! -t 1) ]]; then
        po0_error '菜单需要交互终端；只读查询请使用 --status。'
        return 2
    fi
    [[ $EUID == 0 ]] || {
        po0_error '请使用 sudo 或 root 运行菜单/状态查询。'
        return 4
    }
    [[ ${BASH_VERSINFO[0]} -gt 4 || (${BASH_VERSINFO[0]} == 4 && ${BASH_VERSINFO[1]} -ge 4) ]] || {
        po0_error '需要 Bash 4.4 或更新版本。'
        return 3
    }
    [[ $(uname -s) == Linux && -d /run/systemd/system ]] || {
        po0_error '需要 Linux 和 systemd。'
        return 3
    }
    [[ -r /etc/debian_version ]] || {
        po0_error '此脚本面向 Debian/Ubuntu 系统。'
        return 3
    }
    po0_load_current || return $?
    if [[ $option == --status ]]; then
        po0_status
        return $?
    fi
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    while :; do
        printf '\nPO0 中转管理\n1) 列表  2) 新增  3) 编辑  4) 启用/禁用\n5) 删除  6) 状态  7) 重新应用  0) 退出\n'
        read -r -p '请选择: ' option || return 130
        status=0
        case $option in
            1) po0_list || status=$? ;;
            2) po0_action_add || status=$? ;;
            3) po0_action_edit || status=$? ;;
            4) po0_action_toggle || status=$? ;;
            5) po0_action_delete || status=$? ;;
            6) po0_status || status=$? ;;
            7) po0_action_reapply || status=$? ;;
            0) return 0 ;;
            *)
                po0_error '请选择菜单中的编号。'
                continue
                ;;
        esac
        if [[ $status == 130 ]]; then
            printf '已取消。\n'
        elif [[ $status != 0 ]]; then po0_error "操作失败，退出码 $status；请检查上方诊断。"; fi
        po0_load_current || return $?
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -Eeuo pipefail
    IFS=$'\n\t'
    umask 077
    po0_main "$@"
fi
