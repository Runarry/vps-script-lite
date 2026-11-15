#!/usr/bin/env bash
# Standalone IPv4 relay manager. This file deliberately has no repository imports.

PO0_STATE_FILE=/etc/po0-relay/state.tsv
PO0_NFT_FILE=/etc/po0-relay/rules.nft
PO0_LEGACY_NFT_FILE=/etc/nftables.conf
PO0_SERVICE_FILE=/etc/systemd/system/po0-relay.service
PO0_SHARED_STATE=/var/lib/vpsctl/network/nftables/state.json
PO0_SHARED_RUNTIME=/usr/local/lib/vpsctl/nftables/runtime.sh
PO0_SHARED_LOCK=/run/vpsctl/network-nftables.lock
PO0_PROXY_STATE_DIR=/var/lib/vpsctl/service/proxy
PO0_TUNE_PORTS_STATE=/var/lib/vpsctl/network/tune/ports.json
PO0_SYSCTL_FILE=/etc/sysctl.d/99-po0-relay.conf
PO0_BBR_SYSCTL_FILE=/etc/sysctl.d/99-po0-relay-bbr.conf
PO0_BBR_MODULES_FILE=/etc/modules-load.d/99-po0-relay-bbr.conf
PO0_BACKUP_DIR=/etc/po0-relay/backups
PO0_LOCK_FILE=/run/lock/po0-relay.lock
PO0_MODE=fresh
PO0_IFACE=''
PO0_RELAY_IP=''
PO0_PUBLIC_IP=''
PO0_NEXT_ID=1
PO0_BASE_STATE=''
PO0_BASE_CONFIG=''
PO0_BASE_LEGACY=''
PO0_FILTER_OWNER=standalone
PO0_LEGACY_CONFIG=0
PO0_ANSWER=''
PO0_CHOSEN_PORT=''
declare -ga PO0_IDS=() PO0_SSH_PORTS=(22) PO0_LISTEN_TCP=() PO0_LISTEN_UDP=() PO0_LOCAL_IPS=()
declare -gA PO0_NAME=() PO0_ENABLED=() PO0_PROTO=() PO0_PORT=() PO0_DEST_IP=() PO0_DEST_PORT=() PO0_URI=()

po0_message() {
    local color=$1
    shift
    if [[ -t 1 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]]; then
        printf '\033[%sm%s\033[0m\n' "$color" "$*"
    else
        printf '%s\n' "$*"
    fi
}

po0_error() { po0_message 31 "[错误] $*" >&2; }
po0_heading() {
    printf '\n'
    po0_message '1;36' "$*"
}

po0_reset_state() {
    PO0_IDS=() PO0_NAME=() PO0_ENABLED=() PO0_PROTO=() PO0_PORT=() PO0_DEST_IP=() PO0_DEST_PORT=() PO0_URI=()
    PO0_IFACE='' PO0_RELAY_IP='' PO0_PUBLIC_IP='' PO0_NEXT_ID=1 PO0_SSH_PORTS=(22) PO0_FILTER_OWNER=standalone
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

# Structural state validation stays available without Python or network access.
po0_valid_uri() {
    [[ ${1,,} =~ ^(vless|vmess|trojan|ss|hysteria2|hy2|tuic|anytls)://.+$ && $1 != *[[:cntrl:]]* ]]
}

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
    [[ $PO0_FILTER_OWNER == standalone || $PO0_FILTER_OWNER == vpsctl ]] || return 10
    po0_valid_iface "$PO0_IFACE" && po0_valid_ipv4 "$PO0_RELAY_IP" && po0_valid_id "$PO0_NEXT_ID" || {
        po0_error '状态中的网卡、内网 IPv4 或 next_id 无效。'
        return 10
    }
    if [[ -n $PO0_PUBLIC_IP ]] && ! po0_valid_ipv4 "$PO0_PUBLIC_IP"; then
        po0_error '状态中的公网 IPv4 无效。'
        return 10
    fi
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
        if [[ ${PO0_URI[$id]+yes} ]] && ! po0_valid_uri "${PO0_URI[$id]}"; then
            po0_error "规则 $id 的 URI 记录无效。"
            return 10
        fi
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
    for id in "${!PO0_URI[@]}"; do
        [[ ${seen[$id]+yes} ]] || {
            po0_error 'URI 记录没有对应线路。'
            return 10
        }
    done
}

po0_write_state() {
    local id port
    po0_validate_state || return $?
    printf 'PO0-RELAY\t3\nmeta\tinterface\t%s\nmeta\trelay_ip\t%s\nmeta\tnext_id\t%s\nmeta\tfilter_owner\t%s\n' "$PO0_IFACE" "$PO0_RELAY_IP" "$PO0_NEXT_ID" "$PO0_FILTER_OWNER"
    [[ -z $PO0_PUBLIC_IP ]] || printf 'meta\tpublic_ip\t%s\n' "$PO0_PUBLIC_IP"
    for port in "${PO0_SSH_PORTS[@]}"; do printf 'ssh\t%s\n' "$port"; done
    for id in "${PO0_IDS[@]}"; do
        printf 'rule\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "${PO0_ENABLED[$id]}" "${PO0_PROTO[$id]}" "${PO0_PORT[$id]}" "${PO0_DEST_IP[$id]}" "${PO0_DEST_PORT[$id]}" "${PO0_NAME[$id]}"
        [[ ! ${PO0_URI[$id]+yes} ]] || printf 'uri\t%s\t%s\n' "$id" "${PO0_URI[$id]}"
    done
}

po0_load_state() {
    local line n=0 id key version
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
            [[ $line == $'PO0-RELAY\t1' || $line == $'PO0-RELAY\t2' || $line == $'PO0-RELAY\t3' ]] || {
                po0_error '状态版本不支持。'
                return 10
            }
            version=${line##*$'\t'}
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
                    filter_owner)
                        [[ $version == 3 ]] || return 10
                        PO0_FILTER_OWNER=${fields[2]}
                        ;;
                    public_ip)
                        [[ $version != 1 ]] || return 10
                        PO0_PUBLIC_IP=${fields[2]}
                        ;;
                    *)
                        po0_error "未知状态字段: $key"
                        return 10
                        ;;
                esac
                ;;
            uri)
                [[ $version != 1 && ${#fields[@]} == 3 ]] || return 10
                id=${fields[1]}
                po0_valid_id "$id" || return 10
                [[ ! ${PO0_URI[$id]+yes} ]] || return 10
                PO0_URI[$id]=${fields[2]}
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
    [[ $n -gt 0 && ${meta[interface]+yes} && ${meta[relay_ip]+yes} && ${meta[next_id]+yes} ]] || {
        po0_error '状态文件不完整。'
        return 10
    }
    [[ $version != 3 || ${meta[filter_owner]+yes} ]] || return 10
    po0_validate_state
}

# URI data uses a separate descriptor, never Python source or process arguments.
# parse/resolve print host (resolved IPv4 for resolve), port, name, protocol hint.
# rewrite accepts an empty replacement host to retain an upstream domain.
po0_uri() {
    local action=$1 source=${2-}
    command -v python3 >/dev/null 2>&1 || {
        po0_error 'URI 功能需要 python3；线路基本信息仍可查看。'
        return 3
    }
    python3 - "$action" "${@:3}" 3<<<"$source" <<'PY'
import base64
import ipaddress
import json
import os
import re
import signal
import socket
import sys
import urllib.parse
import urllib.request


class Invalid(Exception):
    pass


def require(ok, message="URI 格式、地址或端口无效。"):
    if not ok:
        raise Invalid(message)


def text_ok(value):
    return isinstance(value, str) and not any(ord(c) < 32 or 127 <= ord(c) < 160 for c in value)


def ipv4(value):
    try:
        address = ipaddress.IPv4Address(value)
        first = int(str(address).split('.')[0])
        return 0 < first < 224 and first != 127
    except ipaddress.AddressValueError:
        return False


def host_ok(host):
    require(isinstance(host, str) and host and text_ok(host))
    require(':' not in host, "仅支持 IPv4 目标，不支持 IPv6。")
    if re.fullmatch(r'[0-9.]+', host):
        require(ipv4(host), "目标 IPv4 无效。")
    else:
        name = host.rstrip('.').encode('idna').decode('ascii')
        require(len(name) <= 253 and all(
            re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?', label)
            for label in name.split('.')), "目标域名无效。")
    return host


def port_number(value):
    require(isinstance(value, (str, int)) and not isinstance(value, bool))
    require(re.fullmatch(r'[0-9]{1,5}', str(value)) and 1 <= int(value) <= 65535)
    return int(value)


def ports(value):
    intervals = []
    for part in value.split(','):
        pair = part.split('-')
        require(1 <= len(pair) <= 2)
        start, end = port_number(pair[0]), port_number(pair[-1])
        require(start <= end)
        intervals.append((start, end))
    merged = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return merged


def unquote(value):
    require(not re.search(r'%(?![0-9A-Fa-f]{2})', value))
    value = urllib.parse.unquote(value, errors='strict')
    require(text_ok(value), "URI 含控制字符。")
    return value


def b64decode(value):
    require(re.fullmatch(r'[A-Za-z0-9+/_-]+={0,2}', value) and len(value.rstrip('=')) % 4 != 1)
    return base64.b64decode(value + '=' * (-len(value) % 4), altchars=b'-_', validate=True).decode('utf-8')


def b64encode(value, original):
    raw = value.encode('utf-8')
    encoded = (base64.urlsafe_b64encode(raw) if '-' in original or '_' in original
               else base64.b64encode(raw)).decode('ascii')
    return encoded if original.endswith('=') else encoded.rstrip('=')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "VMess JSON 含重复字段。")
        result[key] = value
    return result


class Node:
    def __init__(self, uri):
        require(text_ok(uri) and '://' in uri)
        self.scheme, rest = uri.split('://', 1)
        self.kind = self.scheme.lower()
        require(self.kind in ('vless', 'vmess', 'trojan', 'ss', 'hysteria2', 'hy2', 'tuic', 'anytls'),
                "不支持此 URI 协议。")
        self.body, mark, self.fragment = rest.partition('#')
        self.fragment = mark + self.fragment
        self.name = unquote(self.fragment[1:]) if mark else ''
        self.hint = 'udp' if self.kind in ('hysteria2', 'hy2', 'tuic') else 'both'
        self.vm = None
        self.query = []
        self.values = {}
        self.legacy = False
        if self.kind == 'vmess':
            self.vm = json.loads(b64decode(self.body), object_pairs_hook=unique_object)
            require(isinstance(self.vm, dict) and isinstance(self.vm.get('id'), str) and self.vm['id'])
            self.host = host_ok(self.vm.get('add'))
            self.port = port_number(self.vm.get('port'))
            self.name = self.vm.get('ps', self.name)
            require(text_ok(self.name))
            return
        self.body, marker, query = self.body.partition('?')
        self.query_marker = marker
        if marker:
            self.query = query.split('&')
            for part in self.query:
                key, _, value = part.partition('=')
                key = unquote(key).lower()
                # Decode only fields needed for endpoint/TLS semantics. Unknown
                # query values keep their exact original bytes and ordering.
                if key in ('sni', 'peer', 'servername', 'host', 'type', 'security', 'mport', 'disable_sni'):
                    require(key not in self.values, "URI 含重复的连接参数。")
                    self.values[key] = unquote(value)
        body = self.body
        if self.kind == 'ss' and '@' not in body:
            self.legacy = True
            body = b64decode(body)
            require(text_ok(body) and '@' in body)
            self.userinfo, endpoint = body.rsplit('@', 1)
            self.path = ''
            require(':' in self.userinfo)
        else:
            authority, slash, tail = body.partition('/')
            self.path = slash + tail
            if '@' in authority:
                self.userinfo, endpoint = authority.rsplit('@', 1)
                require(self.userinfo)
            else:
                require(self.kind in ('hy2', 'hysteria2'))
                self.userinfo, endpoint = '', authority
            if self.kind == 'ss':
                decoded = unquote(self.userinfo) if ':' in self.userinfo else b64decode(self.userinfo)
                require(text_ok(decoded) and ':' in decoded)
        require(not endpoint.startswith('['), "仅支持 IPv4 目标，不支持 IPv6。")
        self.host, sep, port = endpoint.partition(':')
        host_ok(self.host)
        if self.kind in ('hy2', 'hysteria2'):
            native = ports(port if sep else '443')
            if 'mport' in self.values:
                hopping = ports(self.values['mport'])
                require(len(native) == 1 and native[0][0] == native[0][1] or native == hopping,
                        "HY2 两处跳跃端口配置冲突。")
                native = hopping
            self.port = native[0][0]
        else:
            require(sep)
            self.port = port_number(port)

    def rewrite(self, host, port):
        host = host_ok(host or self.host)
        port = port_number(port)
        if self.vm is not None:
            data = self.vm.copy()
            transport = data.get('net', 'tcp')
            http = transport in ('ws', 'h2', 'http', 'httpupgrade', 'xhttp', 'splithttp') or (
                transport == 'tcp' and data.get('type') == 'http')
            if data.get('tls') in ('tls', 'reality') and not data.get('sni'):
                data['sni'] = data.get('host') if http and data.get('host') else self.host
            if http and not data.get('host'):
                data['host'] = self.host
            data['add'] = host
            data['port'] = str(port) if isinstance(data['port'], str) else port
            return self.scheme + '://' + b64encode(
                json.dumps(data, ensure_ascii=False, separators=(',', ':')), self.body) + self.fragment
        query = list(self.query)
        values = self.values
        transport = values.get('type', 'tcp')
        http = self.kind in ('vless', 'trojan') and transport in (
            'ws', 'http', 'h2', 'httpupgrade', 'xhttp', 'splithttp')
        tls = self.kind in ('trojan', 'anytls', 'hysteria2', 'hy2', 'tuic') or (
            self.kind == 'vless' and values.get('security') in ('tls', 'reality'))
        if tls and not any(values.get(k) for k in ('sni', 'peer', 'servername')) and (
                values.get('disable_sni', '').lower() not in ('1', 'true')):
            sni = values.get('host') if http and values.get('host') else self.host
            query = [part for part in query if unquote(part.partition('=')[0]).lower() != 'sni']
            query.append('sni=' + urllib.parse.quote(sni, safe=''))
        if http and not values.get('host'):
            query = [part for part in query if unquote(part.partition('=')[0]).lower() != 'host']
            query.append('host=' + urllib.parse.quote(self.host, safe=''))
        if self.kind in ('hy2', 'hysteria2'):
            query = [part for part in query if unquote(part.partition('=')[0]).lower() != 'mport']
        endpoint = host + ':' + str(port)
        if self.legacy:
            body = b64encode(self.userinfo + '@' + endpoint, self.body)
        else:
            body = (self.userinfo + '@' if self.userinfo else '') + endpoint + self.path
        suffix = '?' + '&'.join(query) if query else ''
        return self.scheme + '://' + body + suffix + self.fragment


def expired(_signum, _frame):
    raise TimeoutError()


def resolve(host, preferred):
    if ipv4(host):
        return host
    signal.alarm(5)
    answers = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
    signal.alarm(0)
    candidates = list(dict.fromkeys(item[4][0] for item in answers if ipv4(item[4][0])))
    require(candidates, "目标域名没有可用的 IPv4 地址。")
    return preferred if preferred in candidates else candidates[0]


try:
    signal.signal(signal.SIGALRM, expired)
    action = sys.argv[1]
    with os.fdopen(3, encoding='utf-8') as stream:
        uri = stream.read()[:-1]  # Bash here-string adds exactly one newline.
    if action == 'public-ip':
        signal.alarm(5)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open('https://api.ipify.org', timeout=5) as response:
            address = response.read(64).decode('ascii').strip()
        signal.alarm(0)
        require(ipv4(address), "公网探测未返回有效 IPv4，请手动填写。")
        print(address)
    else:
        node = Node(uri)
        if action in ('parse', 'resolve'):
            address = resolve(node.host, sys.argv[2] if len(sys.argv) > 2 else '') if action == 'resolve' else node.host
            print(address, node.port, node.name, node.hint, sep='\n')
        elif action == 'rewrite':
            require(len(sys.argv) == 4)
            print(node.rewrite(sys.argv[2], sys.argv[3]))
        else:
            raise Invalid('内部 URI 操作无效。')
except Invalid as error:
    print('[错误] ' + str(error), file=sys.stderr)
    sys.exit(10)
except (ValueError, TypeError, KeyError, OSError, UnicodeError):
    print('[错误] URI 解析或网络查询失败，请检查格式、目标地址和网络后重试。', file=sys.stderr)
    sys.exit(10)
PY
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
    if [[ $PO0_FILTER_OWNER == standalone ]]; then
        cat <<EOF
table inet po0_relay_filter {
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
        printf '    }\n    chain output { type filter hook output priority 0; policy accept; }\n}\n'
    fi
    printf 'table ip po0_relay_nat {\n    comment "po0-relay:1"\n    chain prerouting {\n        type nat hook prerouting priority dstnat; policy accept;\n'
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
    printf '    }\n}\ntable ip po0_relay_mangle {\n    comment "po0-relay:1"\n    chain forward {\n        type filter hook forward priority mangle; policy accept;\n'
    for id in "${PO0_IDS[@]}"; do
        [[ ${PO0_ENABLED[$id]} == 1 && ${PO0_PROTO[$id]} != udp ]] || continue
        printf '        ip daddr %s tcp flags syn tcp option maxseg size set 1452\n' "${PO0_DEST_IP[$id]}"
    done
    printf '    }\n}\n'
}

po0_render_reset() {
    # `add table` is idempotent on supported nftables; the following delete and
    # recreation happen together in one atomic netlink batch, even at boot.
    printf 'add table inet po0_relay_filter\ndelete table inet po0_relay_filter\nadd table ip po0_relay_nat\ndelete table ip po0_relay_nat\nadd table ip po0_relay_mangle\ndelete table ip po0_relay_mangle\n'
}

po0_render_config() {
    printf '#!/usr/sbin/nft -f\n# Managed by po0-relay, schema 2. Edit through po0-relay.sh.\n'
    po0_render_reset
    po0_render_rules
}

# Only used to verify the preceding single-file release before migrating its
# generic table names. Keep its exact renderer/header for ownership checks.
po0_render_previous_config() (
    PO0_FILTER_OWNER=standalone
    po0_render_config | sed 's/po0_relay_filter/filter/g; s/po0_relay_nat/nat/g; s/po0_relay_mangle/mangle/g; s/schema 2/schema 1/'
)

po0_render_service() {
    cat <<EOF
# Managed by po0-relay.
[Unit]
Description=PO0 IPv4 relay rules
After=network-pre.target nftables.service vpsctl-nftables.service
Before=network.target
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f "$PO0_NFT_FILE"
ExecReload=/usr/sbin/nft -f "$PO0_NFT_FILE"
[Install]
WantedBy=multi-user.target
EOF
}

po0_table_names() {
    printf 'inet po0_relay_filter\nip po0_relay_nat\nip po0_relay_mangle\n'
    [[ $PO0_LEGACY_CONFIG != 1 ]] || printf 'inet filter\nip nat\nip mangle\n'
}

po0_extract_table() {
    awk -v wanted="table $1 $2 {" '
        $0 == wanted { active=1 }
        active { print; line=$0; depth+=gsub(/\{/, "", line); line=$0; depth-=gsub(/\}/, "", line); if (!depth) exit }
    '
}

po0_normalize_runtime() {
    # Anonymous sets are unordered; nft sorts their values and folds singletons.
    local line matched values replacement
    local set_pattern='\{[[:space:]]*([[:alnum:]_.:-]+([[:space:]]*,[[:space:]]*[[:alnum:]_.:-]+)*)[[:space:]]*\}'
    while IFS= read -r line; do
        while [[ $line =~ $set_pattern ]]; do
            matched=${BASH_REMATCH[0]}
            values=$(printf '%s' "${BASH_REMATCH[1]}" | tr -d '[:space:]' | tr ',' '\n' | LC_ALL=C sort -u | paste -sd, -) || return 20
            replacement=$values
            [[ $values != *,* ]] || replacement="SET[$values]"
            line=${line/"$matched"/$replacement}
        done
        printf '%s\n' "${line//priority filter/priority 0}"
    done | tr -d '[:space:]'
}

# Compare every executable statement, not just a marker: Docker can append
# chains to these old generic tables even when their PO0 comment survives.
po0_validate_legacy_runtime() (
    local expected actual id table family name
    [[ $PO0_LEGACY_CONFIG == 1 ]] || return 0
    if [[ $PO0_MODE == previous ]]; then
        po0_load_state "$PO0_STATE_FILE" || return $?
        expected=$(po0_render_previous_config) || return $?
    else
        po0_import_legacy "$PO0_LEGACY_NFT_FILE" || return $?
        expected=$(po0_render_legacy_template) || return $?
        expected=${expected//\$RELAY_LAN_IP/$PO0_RELAY_IP}
        # Replace larger IDs first, so $DEST_IP_1 cannot truncate $DEST_IP_10.
        for ((id = ${#PO0_IDS[@]}; id >= 1; id--)); do
            expected=${expected//\$DEST_IP_$id/${PO0_DEST_IP[$id]}}
            expected=${expected//\$DEST_PORT_$id/${PO0_DEST_PORT[$id]}}
            expected=${expected//\$PORT_IN_$id/${PO0_PORT[$id]}}
        done
    fi
    for table in 'inet filter' 'ip nat' 'ip mangle'; do
        IFS=' ' read -r family name <<<"$table"
        if [[ $'\n'$PO0_TABLES$'\n' == *$'\n'"table $table"$'\n'* ]]; then
            actual=$(nft -s list table "$family" "$name" | po0_normalize_runtime) || return 20
            [[ $actual == "$(printf '%s\n' "$expected" | po0_extract_table "$family" "$name" | po0_normalize_runtime)" ]] || {
                po0_error "旧 $table 含非 PO0 规则或已变更；保留原表，请先分离其他规则。"
                return 10
            }
        fi
    done
)

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

po0_load_current() {
    local rendered actual
    PO0_LEGACY_CONFIG=0
    PO0_BASE_STATE=$(po0_file_fingerprint "$PO0_STATE_FILE") || return $?
    PO0_BASE_CONFIG=$(po0_file_fingerprint "$PO0_NFT_FILE") || return $?
    PO0_BASE_LEGACY=$(po0_file_fingerprint "$PO0_LEGACY_NFT_FILE") || return $?
    if [[ -e $PO0_STATE_FILE ]]; then
        po0_load_state "$PO0_STATE_FILE" || return $?
        if [[ ! -e $PO0_NFT_FILE && -f $PO0_LEGACY_NFT_FILE ]]; then
            rendered=$(po0_render_previous_config) || return $?
            actual=$(cat -- "$PO0_LEGACY_NFT_FILE") || return 20
            [[ $actual == "$rendered" ]] || {
                po0_error '旧受管配置与状态不一致；拒绝接管。'
                return 10
            }
            PO0_LEGACY_CONFIG=1 PO0_MODE=previous
            return 0
        fi
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
    elif [[ -e $PO0_NFT_FILE ]]; then
        po0_error '独立规则文件存在但缺少状态；请使用备份恢复。'
        return 10
    elif [[ -f $PO0_LEGACY_NFT_FILE ]] && (po0_import_legacy "$PO0_LEGACY_NFT_FILE") 2>/dev/null; then
        po0_import_legacy "$PO0_LEGACY_NFT_FILE" || return $?
        PO0_MODE=legacy PO0_LEGACY_CONFIG=1
    elif [[ -f $PO0_LEGACY_NFT_FILE ]] && grep -Eq '^[[:space:]]*(define[[:space:]]+RELAY_LAN_IP|#[[:space:]]*Managed by po0-relay)' "$PO0_LEGACY_NFT_FILE"; then
        po0_error '旧 PO0 配置不完整或缺少对应状态；请使用备份恢复。'
        return 10
    else
        po0_reset_state
        PO0_MODE=fresh
    fi
}

po0_require_tools() {
    local tool package reply dry_run=0 install_deps=0 non_interactive=0
    local -a missing=() packages=()
    local -A seen=()
    while (($#)); do
        case $1 in
            --dry-run) dry_run=1 ;;
            --install-deps) install_deps=1 ;;
            --non-interactive) non_interactive=1 ;;
            *) break ;;
        esac
        shift
    done
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 && continue
        missing+=("$tool")
        case $tool in
            nft) package=nftables ;;
            ip | ss | tc) package=iproute2 ;;
            flock) package=util-linux ;;
            sysctl) package=procps ;;
            modprobe) package=kmod ;;
            python3) package=python3 ;;
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
    if [[ $dry_run == 1 ]]; then
        PO0_TUNE_DEPENDENCIES_PLANNED=1
        printf '演练安装计划: apt-get update 后 apt-get install -y --' >&2
        printf ' %s' "${packages[@]}" >&2
        printf '\n' >&2
        return 0
    fi
    # shellcheck disable=SC2015
    command -v apt-get >/dev/null 2>&1 && [[ $install_deps == 1 || ($non_interactive == 0 && -t 0 && -t 1) ]] || {
        po0_error '请先安装所列依赖。'
        return 3
    }
    if [[ $install_deps == 0 ]]; then
        read -r -p '现在使用 apt-get 安装这些依赖？[y/N] ' reply || return 130
        [[ $reply == y || $reply == Y ]] || return 130
    fi
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
    po0_check_configured_conflicts
}

po0_check_configured_conflicts() {
    local records='' file row proto ports port id
    local -a pieces=()
    for file in "$PO0_PROXY_STATE_DIR/relay.json" "$PO0_PROXY_STATE_DIR/nodes.json"; do
        [[ -e $file || -L $file ]] || continue
        [[ -f $file && ! -L $file ]] || return 10
        command -v jq >/dev/null 2>&1 || {
            po0_error '检查已有 vpsctl 端口配置需要 jq。'
            return 3
        }
        if [[ $file == */relay.json ]]; then
            row=$(jq -er '[.forwards[]? | select((.family // "dual") != "ipv6") |
                [.network, "\(.listen_port_start)-\(.listen_port_end)"] | @tsv] | join("\n")' "$file") || return 10
        else
            row=$(jq -er '[.nodes[]? | select((.listen // "::") as $address | $address == "::" or ($address | contains(":") | not)) |
                [(if .profile == "hysteria2" or .profile == "tuic-v5" then "udp"
                  elif (.profile | startswith("shadowsocks-")) then "both" else "tcp" end),
                 ((.port | tostring) + (if (.options.hop_ports // "") != "" then "," + .options.hop_ports else "" end))] | @tsv] | join("\n")' "$file") || return 10
        fi
        records+="${row}"$'\n'
    done
    while IFS=$'\t' read -r proto ports; do
        [[ -n $proto ]] || continue
        [[ $proto =~ ^(tcp|udp|both)$ ]] || return 10
        IFS=, read -r -a pieces <<<"$ports"
        for port in "${pieces[@]}"; do
            po0_valid_port_spec "$port" || return 10
            for id in "${PO0_IDS[@]}"; do
                [[ ${PO0_ENABLED[$id]} == 1 ]] || continue
                if po0_protocols_overlap "$proto" "${PO0_PROTO[$id]}" && po0_ports_overlap "$port" "${PO0_PORT[$id]}"; then
                    po0_error "线路 $id 与 vpsctl 已配置入口 $proto/$port 冲突。"
                    return 10
                fi
            done
        done
    done <<<"$records"
}

po0_requirements_json() {
    po0_write_state | jq -Rn '
        [inputs | split("\t")] as $rows |
        ($rows | map(select(.[0] == "meta" and .[1] == "interface"))[0][2]) as $iface |
        [$rows[] | select(.[0] == "rule" and .[2] == "1") | . as $rule |
         (if .[3] == "both" then ["tcp", "udp"] else [.[3]] end)[] |
         {scope:"po0", owner:("po0:" + $rule[1]), kind:"route", family:"ipv4", proto:.,
          port:$rule[6], source:"any", destination:$rule[5], original_port:$rule[4],
          original_destination:"any", temporary:false, interfaces:{in:$iface,out:""}}]'
}

po0_shared_prepare() {
    local directory=$1 state proto ports port id
    local -a pieces=()
    state=$(vps_nft_state) || return $?
    while IFS=$'\t' read -r proto ports; do
        [[ -n $proto && -n $ports && $ports != any ]] || continue
        IFS=, read -r -a pieces <<<"$ports"
        for port in "${pieces[@]}"; do
            po0_valid_port_spec "$port" || return 10
            for id in "${PO0_IDS[@]}"; do
                [[ ${PO0_ENABLED[$id]} == 1 ]] || continue
                if po0_protocols_overlap "$proto" "${PO0_PROTO[$id]}" && po0_ports_overlap "$port" "${PO0_PORT[$id]}"; then
                    po0_error "线路 $id 与统一管理器的 $proto/$port 入口冲突。"
                    return 10
                fi
            done
        done
    done < <(jq -r '.requirements[] | select(.scope != "po0" and .family == "ipv4") |
        [.proto, (.original_port // .port)] | @tsv' <<<"$state")
    po0_requirements_json >"$directory/requirements.json" || return $?
    jq --slurpfile requirements "$directory/requirements.json" \
        '.revision += 1 |
         .requirements = ([.requirements[] | select(.scope != "po0")] + $requirements[0]) |
         reduce $requirements[0][] as $rule (.;
             .links[$rule.owner] = ((.links[$rule.owner] // {detached:false}) + {scope:"po0"}))' \
        <<<"$state" >"$directory/shared-state.candidate" || return 20
    vps_nft_prepare_state "$directory/shared-state.candidate" "$directory/shared-candidate"
}

# Private cooperation entrypoints. The manager holds all business locks before
# its nft lock; these helpers never acquire locks or invoke public commands.
po0_coop_prepare() (
    local directory=$1
    po0_load_current || return $?
    [[ $PO0_MODE != fresh ]] || return 0
    PO0_COOP_DIR=$directory po0_apply
)

po0_coop_read_before() {
    local key value
    PO0_TX_DIR=$1
    while IFS='=' read -r key value; do
        case $key in
            ip_forward) PO0_OLD_FORWARD=$value ;;
            service_enabled) PO0_OLD_SERVICE=$value ;;
            legacy_config) PO0_LEGACY_CONFIG=$value ;;
        esac
    done <"$PO0_TX_DIR/before.txt"
}

po0_coop_commit() (
    [[ -f $1/present ]] || return 0
    po0_coop_read_before "$1" || return $?
    po0_atomic_write "$PO0_TX_DIR/nftables.candidate" "$PO0_NFT_FILE" 644 || return $?
    po0_atomic_write "$PO0_TX_DIR/state.candidate" "$PO0_STATE_FILE" 600 || return $?
    po0_atomic_write "$PO0_TX_DIR/sysctl.candidate" "$PO0_SYSCTL_FILE" 644 || return $?
    po0_atomic_write "$PO0_TX_DIR/service.candidate" "$PO0_SERVICE_FILE" 644 || return $?
    [[ $PO0_LEGACY_CONFIG != 1 ]] || po0_atomic_write "$PO0_TX_DIR/legacy.candidate" "$PO0_LEGACY_NFT_FILE" 644 || return $?
    sysctl -q -w net.ipv4.ip_forward=1 || return 20
    systemctl daemon-reload && systemctl enable po0-relay.service
)

# Flags are consumed synchronously by po0_rollback in this same subshell.
# shellcheck disable=SC2030
po0_coop_restore() (
    [[ -f $1/present ]] || return 0
    po0_coop_read_before "$1" || return $?
    PO0_RUNTIME_TOUCHED=0 PO0_FILES_TOUCHED=1 PO0_SYSCTL_TOUCHED=1 PO0_SERVICE_TOUCHED=1 PO0_SHARED_TOUCHED=0
    po0_rollback
)

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
        enabled) systemctl enable po0-relay.service >/dev/null ;;
        enabled-runtime) systemctl disable po0-relay.service >/dev/null && systemctl enable --runtime po0-relay.service >/dev/null ;;
        disabled) systemctl disable po0-relay.service >/dev/null ;;
        not-found) systemctl disable po0-relay.service >/dev/null 2>&1 || [[ ! -e $PO0_SERVICE_FILE ]] ;;
        *) return 0 ;;
    esac
}

# Both transaction callers initialize these flags in their own subshell.
# shellcheck disable=SC2031
po0_rollback() {
    local failed=0 batch="$PO0_TX_DIR/runtime-restore.nft"
    if [[ $PO0_RUNTIME_TOUCHED == 1 ]]; then
        if [[ ${PO0_SHARED_TOUCHED:-0} == 1 ]]; then
            vps_nft_prepare_restore "$PO0_TX_DIR/shared-before" "$PO0_TX_DIR/shared-restore" || failed=1
            batch="$PO0_TX_DIR/runtime-rollback.nft"
            [[ $failed != 0 ]] || cat "$PO0_TX_DIR/runtime-restore.nft" "$PO0_TX_DIR/shared-restore/batch.nft" >"$batch" || failed=1
        fi
        if [[ $failed == 0 ]]; then
            nft -c -f "$batch" && nft -f "$batch" || failed=1
            if [[ $failed == 0 && ${PO0_SHARED_TOUCHED:-0} == 1 ]]; then
                vps_nft_commit_prepared "$PO0_TX_DIR/shared-restore" || failed=1
            fi
        fi
    fi
    if [[ $PO0_FILES_TOUCHED == 1 ]]; then
        po0_restore_file "$PO0_TX_DIR/state.before" "$PO0_STATE_FILE" || failed=1
        po0_restore_file "$PO0_TX_DIR/nftables.before" "$PO0_NFT_FILE" || failed=1
        po0_restore_file "$PO0_TX_DIR/sysctl.before" "$PO0_SYSCTL_FILE" || failed=1
        [[ $PO0_LEGACY_CONFIG != 1 ]] || po0_restore_file "$PO0_TX_DIR/legacy.before" "$PO0_LEGACY_NFT_FILE" || failed=1
        po0_restore_file "$PO0_TX_DIR/service.before" "$PO0_SERVICE_FILE" || failed=1
        systemctl daemon-reload || failed=1
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
        printf 'exec 9>%q\nflock -w 10 9\n' "$PO0_LOCK_FILE"
        if [[ ${PO0_SHARED_ACTIVE:-0} == 1 ]]; then
            printf 'source %q\nvps_cmd_init network-nftables %q\nvps_nft_init\nvps_nft_lock\n' "$PO0_SHARED_RUNTIME" "${PO0_SHARED_RUNTIME%/*}"
            printf 'vps_nft_prepare_restore %q %q\ncat %q %q >%q\nnft -c -f %q\nnft -f %q\nvps_nft_commit_prepared %q\n' \
                "$PO0_TX_DIR/shared-before" "$PO0_TX_DIR/manual-shared-restore" \
                "$PO0_TX_DIR/runtime-restore.nft" "$PO0_TX_DIR/manual-shared-restore/batch.nft" "$PO0_TX_DIR/manual-restore.nft" \
                "$PO0_TX_DIR/manual-restore.nft" "$PO0_TX_DIR/manual-restore.nft" "$PO0_TX_DIR/manual-shared-restore"
        else
            printf 'mkdir -p %q\nexec 8>%q\nflock -w 10 8\n' "$(dirname -- "$PO0_SHARED_LOCK")" "$PO0_SHARED_LOCK"
            printf 'nft -c -f %q\nnft -f %q\n' "$PO0_TX_DIR/runtime-restore.nft" "$PO0_TX_DIR/runtime-restore.nft"
        fi
        for original in state nftables sysctl service legacy; do
            case $original in state) target=$PO0_STATE_FILE ;; nftables) target=$PO0_NFT_FILE ;; sysctl) target=$PO0_SYSCTL_FILE ;; service) target=$PO0_SERVICE_FILE ;; legacy)
                [[ $PO0_LEGACY_CONFIG == 1 ]] || continue
                target=$PO0_LEGACY_NFT_FILE
                ;;
            esac
            if [[ -f $PO0_TX_DIR/$original.before ]]; then
                printf 'temporary=$(mktemp %q)\ncp -p -- %q "$temporary"\nmv -f -- "$temporary" %q\n' "${target}.restore.XXXXXX" "$PO0_TX_DIR/$original.before" "$target"
            else
                printf 'rm -f -- %q\n' "$target"
            fi
        done
        printf 'systemctl daemon-reload\n'
        printf 'sysctl -q -w net.ipv4.ip_forward=%q\n' "$PO0_OLD_FORWARD"
        case $PO0_OLD_SERVICE in
            enabled) printf 'systemctl enable po0-relay.service\n' ;;
            enabled-runtime) printf 'systemctl disable po0-relay.service\nsystemctl enable --runtime po0-relay.service\n' ;;
            disabled) printf 'systemctl disable po0-relay.service\n' ;;
            not-found) printf 'systemctl disable po0-relay.service || [[ ! -e %q ]]\n' "$PO0_SERVICE_FILE" ;;
        esac
        printf 'echo "PO0 previous state restored; foreign nft tables were retained."\n'
    } >"$PO0_TX_DIR/recover.sh" || return 20
    chmod 700 "$PO0_TX_DIR/recover.sh" || return 20
}

# Caller supplies desired in-memory state after po0_load_current. The subshell
# owns the lock and traps; explicit error handling also works inside `if` calls.
# shellcheck disable=SC2030
po0_apply() (
    set -Eeuo pipefail
    IFS=$'\n\t'
    umask 077
    local lock_fd nft_lock_fd state_dir table family name listing current fingerprint
    PO0_TX_DIR='' PO0_TX_READY=0 PO0_COMMITTED=0 PO0_RUNTIME_TOUCHED=0 PO0_FILES_TOUCHED=0 PO0_SYSCTL_TOUCHED=0 PO0_SERVICE_TOUCHED=0 PO0_SHARED_TOUCHED=0 PO0_SHARED_ACTIVE=0
    [[ $EUID == 0 ]] || {
        po0_error '应用规则需要 root。'
        exit 4
    }
    po0_require_tools nft ip ss flock sysctl systemctl sha256sum mktemp || exit $?
    if [[ -z ${PO0_COOP_DIR:-} ]]; then
        exec {lock_fd}>"$PO0_LOCK_FILE" || exit 20
        flock -w 10 "$lock_fd" || {
            po0_error '另一个 PO0 操作正在执行，请稍后重试。'
            exit 3
        }
        if [[ -f $PO0_SHARED_STATE ]]; then
            [[ -f $PO0_SHARED_RUNTIME && ! -L $PO0_SHARED_RUNTIME ]] || {
                po0_error '统一 nft 管理器已安装，但私有运行库缺失。'
                exit 3
            }
            # Optional cooperation is the only import; standalone needs none.
            # shellcheck source=/dev/null
            source "$PO0_SHARED_RUNTIME" || exit $?
            vps_cmd_init network-nftables "${PO0_SHARED_RUNTIME%/*}" || exit $?
            vps_nft_init || exit $?
            vps_nft_lock || exit $?
            PO0_SHARED_ACTIVE=1
        else
            mkdir -p -- "$(dirname -- "$PO0_SHARED_LOCK")" || exit 20
            exec {nft_lock_fd}>"$PO0_SHARED_LOCK" || exit 20
            flock -w 10 "$nft_lock_fd" || exit 3
        fi
    fi
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
    fingerprint=$(po0_file_fingerprint "$PO0_LEGACY_NFT_FILE") || exit $?
    [[ $fingerprint == "$PO0_BASE_LEGACY" ]] || exit 10
    if [[ $PO0_SHARED_ACTIVE == 1 || -n ${PO0_COOP_DIR:-} ]]; then PO0_FILTER_OWNER=vpsctl; fi
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
    if PO0_OLD_SERVICE=$(systemctl is-enabled po0-relay.service 2>/dev/null); then :; else :; fi
    [[ -n $PO0_OLD_SERVICE || -e $PO0_SERVICE_FILE ]] || PO0_OLD_SERVICE=not-found
    case $PO0_OLD_SERVICE in enabled | enabled-runtime | disabled | not-found) ;;
    *)
        po0_error "po0-relay 服务状态为 $PO0_OLD_SERVICE；请先确认未被屏蔽。"
        exit 3
        ;;
    esac
    PO0_OLD_FORWARD=$(sysctl -n net.ipv4.ip_forward) || exit 20
    [[ $PO0_OLD_FORWARD =~ ^[01]$ ]] || {
        po0_error '无法确认原 ip_forward。'
        exit 20
    }
    if [[ -e $PO0_SERVICE_FILE || -L $PO0_SERVICE_FILE ]]; then
        [[ -f $PO0_SERVICE_FILE && ! -L $PO0_SERVICE_FILE && $(cat -- "$PO0_SERVICE_FILE") == "$(po0_render_service)" ]] || {
            po0_error '拒绝覆盖非受管 po0-relay.service。'
            exit 10
        }
    fi
    PO0_TABLES=$(nft list tables) || {
        po0_error '无法读取现有 nft 表。'
        exit 20
    }
    po0_validate_legacy_runtime || exit $?
    for table in 'inet po0_relay_filter' 'ip po0_relay_nat' 'ip po0_relay_mangle'; do
        IFS=' ' read -r family name <<<"$table"
        if [[ $'\n'$PO0_TABLES$'\n' == *$'\n'"table $table"$'\n'* ]]; then
            [[ $PO0_MODE != fresh ]] || {
                po0_error "已有 $table 表；拒绝接管无关防火墙。"
                exit 10
            }
            listing=$(nft -s list table "$family" "$name") || exit 20
            [[ $listing == *'comment "po0-relay:1"'* ]] || {
                po0_error "$table 不含 PO0 所有权标记，拒绝覆盖。"
                exit 10
            }
        fi
    done
    state_dir=$(dirname -- "$PO0_STATE_FILE") || exit 20
    for current in "$state_dir" "$PO0_BACKUP_DIR" "$(dirname -- "$PO0_NFT_FILE")" "$(dirname -- "$PO0_SYSCTL_FILE")" "$(dirname -- "$PO0_SERVICE_FILE")"; do
        [[ ! -L $current ]] || {
            po0_error "拒绝符号链接目录: $current"
            exit 10
        }
    done
    mkdir -p -- "$state_dir" "$PO0_BACKUP_DIR" || exit 20
    chmod 700 "$state_dir" "$PO0_BACKUP_DIR" || exit 20
    if [[ -n ${PO0_COOP_DIR:-} ]]; then
        PO0_TX_DIR=$PO0_COOP_DIR
        mkdir -p -- "$PO0_TX_DIR" || exit 20
    else
        PO0_TX_DIR=$(mktemp -d "$PO0_BACKUP_DIR/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || exit 20
    fi
    trap 'po0_transaction_exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    [[ ! -f $PO0_STATE_FILE ]] || cp -p -- "$PO0_STATE_FILE" "$PO0_TX_DIR/state.before" || exit 20
    [[ ! -f $PO0_NFT_FILE ]] || cp -p -- "$PO0_NFT_FILE" "$PO0_TX_DIR/nftables.before" || exit 20
    [[ ! -f $PO0_SYSCTL_FILE ]] || cp -p -- "$PO0_SYSCTL_FILE" "$PO0_TX_DIR/sysctl.before" || exit 20
    [[ ! -f $PO0_SERVICE_FILE ]] || cp -p -- "$PO0_SERVICE_FILE" "$PO0_TX_DIR/service.before" || exit 20
    [[ $PO0_LEGACY_CONFIG != 1 ]] || cp -p -- "$PO0_LEGACY_NFT_FILE" "$PO0_TX_DIR/legacy.before" || exit 20
    printf 'ip_forward=%s\nservice_enabled=%s\nsource_mode=%s\nlegacy_config=%s\n' "$PO0_OLD_FORWARD" "$PO0_OLD_SERVICE" "$PO0_MODE" "$PO0_LEGACY_CONFIG" >"$PO0_TX_DIR/before.txt" || exit 20
    : >"$PO0_TX_DIR/runtime-restore.nft"
    while IFS= read -r table; do
        IFS=' ' read -r family name <<<"$table"
        printf 'add table %s\ndelete table %s\n' "$table" "$table" >>"$PO0_TX_DIR/runtime-restore.nft" || exit 20
        if [[ $'\n'$PO0_TABLES$'\n' == *$'\n'"table $table"$'\n'* ]]; then
            nft -s list table "$family" "$name" >>"$PO0_TX_DIR/runtime-restore.nft" || exit 20
        fi
    done < <(po0_table_names)
    po0_write_state >"$PO0_TX_DIR/state.candidate" || exit $?
    po0_render_config >"$PO0_TX_DIR/nftables.candidate" || exit $?
    po0_render_service >"$PO0_TX_DIR/service.candidate" || exit $?
    cp -- "$PO0_TX_DIR/nftables.candidate" "$PO0_TX_DIR/batch.nft" || exit 20
    if [[ $PO0_LEGACY_CONFIG == 1 ]]; then
        for table in 'inet filter' 'ip nat' 'ip mangle'; do
            printf 'add table %s\ndelete table %s\n' "$table" "$table" >>"$PO0_TX_DIR/batch.nft" || exit 20
        done
        printf '# PO0 rules migrated to %s; loaded by po0-relay.service.\n' "$PO0_NFT_FILE" >"$PO0_TX_DIR/legacy.candidate" || exit 20
    fi
    printf '# Managed by po0-relay. Existing tuning in other files is preserved.\nnet.ipv4.ip_forward = 1\n' >"$PO0_TX_DIR/sysctl.candidate" || exit 20
    if [[ -n ${PO0_COOP_DIR:-} ]]; then
        po0_requirements_json >"$PO0_TX_DIR/requirements.json" || exit $?
        touch "$PO0_TX_DIR/present" || exit 20
        exit 0
    fi
    if [[ $PO0_SHARED_ACTIVE == 1 ]]; then
        vps_nft_snapshot "$PO0_TX_DIR/shared-before" || exit $?
        po0_shared_prepare "$PO0_TX_DIR" || exit $?
        cat "$PO0_TX_DIR/shared-candidate/batch.nft" >>"$PO0_TX_DIR/batch.nft" || exit 20
    fi
    po0_make_recovery || exit $?
    nft -c -f "$PO0_TX_DIR/batch.nft" || {
        po0_error 'nft 候选配置检查失败，未修改运行规则。'
        exit 10
    }
    PO0_TX_READY=1
    # Set flags BEFORE each external operation so signal delivery immediately
    # after a successful operation still causes its rollback.
    PO0_RUNTIME_TOUCHED=1
    PO0_SHARED_TOUCHED=$PO0_SHARED_ACTIVE
    nft -f "$PO0_TX_DIR/batch.nft" || {
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
    po0_atomic_write "$PO0_TX_DIR/service.candidate" "$PO0_SERVICE_FILE" 644 || exit $?
    [[ $PO0_LEGACY_CONFIG != 1 ]] || po0_atomic_write "$PO0_TX_DIR/legacy.candidate" "$PO0_LEGACY_NFT_FILE" 644 || exit $?
    if [[ $PO0_SHARED_ACTIVE == 1 ]]; then vps_nft_commit_prepared "$PO0_TX_DIR/shared-candidate" || exit $?; fi
    systemctl daemon-reload || exit 20
    if [[ $PO0_OLD_SERVICE != enabled ]]; then
        PO0_SERVICE_TOUCHED=1
        systemctl enable po0-relay.service || exit 20
    fi
    PO0_COMMITTED=1
    po0_message 32 "已应用。备份: $PO0_TX_DIR"
    printf 'root 控制台恢复: bash %q\n' "$PO0_TX_DIR/recover.sh"
)

po0_bbr_sysctl_content() {
    printf '# Managed by po0-relay BBR + FQ.\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n'
}

po0_bbr_modules_content() {
    printf '# Managed by po0-relay BBR + FQ.\ntcp_bbr\nsch_fq\n'
}

po0_bbr_status() {
    local algorithm queue
    algorithm=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || algorithm=不可用
    queue=$(sysctl -n net.core.default_qdisc 2>/dev/null) || queue=不可用
    printf 'TCP 拥塞控制: %s；默认队列: %s\n' "$algorithm" "$queue"
}

# Separate tuning files keep forwarding edits and legacy imports independent.
po0_enable_bbr() (
    set -Eeuo pipefail
    IFS=$'\n\t'
    umask 077
    local lock_fd old_algorithm old_queue available expected_sysctl expected_modules path expected reply backup
    local runtime_touched=0 files_touched=0 committed=0
    [[ $EUID == 0 ]] || {
        po0_error '开启 BBR + FQ 需要 root。'
        exit 4
    }
    po0_require_tools sysctl flock mktemp || exit $?
    exec {lock_fd}>"$PO0_LOCK_FILE" || exit 20
    flock -w 10 "$lock_fd" || {
        po0_error '另一个 PO0 操作正在执行，请稍后重试。'
        exit 3
    }
    old_algorithm=$(sysctl -n net.ipv4.tcp_congestion_control) || exit 3
    old_queue=$(sysctl -n net.core.default_qdisc) || {
        po0_error '当前内核或容器没有可设置的默认队列参数。'
        exit 3
    }
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control) || exit 3
    expected_sysctl=$(po0_bbr_sysctl_content)
    expected_modules=$(po0_bbr_modules_content)
    for path in "$PO0_BBR_SYSCTL_FILE" "$PO0_BBR_MODULES_FILE"; do
        [[ ! -L $path && (! -e $path || -f $path) ]] || {
            po0_error "拒绝非普通配置文件: $path"
            exit 10
        }
        if [[ $path == "$PO0_BBR_SYSCTL_FILE" ]]; then expected=$expected_sysctl; else expected=$expected_modules; fi
        if [[ -e $path ]] && [[ $(cat -- "$path") != "$expected" ]]; then
            po0_error "文件含非受管内容，保留原文件: $path"
            exit 10
        fi
    done
    if [[ $old_algorithm == bbr && $old_queue == fq && -f $PO0_BBR_SYSCTL_FILE && -f $PO0_BBR_MODULES_FILE ]]; then
        po0_message 32 'BBR + FQ 已开启，开机配置也已保存，无需重复设置。'
        exit 0
    fi
    if [[ ! $available =~ (^|[[:space:]])bbr($|[[:space:]]) ]]; then
        po0_require_tools modprobe || exit $?
    fi
    printf '\n开启 BBR + FQ：TCP %s → bbr；默认队列 %s → fq。\n' "$old_algorithm" "$old_queue"
    printf '保存开机配置: %s\n加载模块配置: %s\n' "$PO0_BBR_SYSCTL_FILE" "$PO0_BBR_MODULES_FILE"
    printf 'BBR 用于本机新建 TCP 连接；默认 FQ 用于后续创建的队列，现有网卡队列保持当前配置。\n'
    read -r -p '确认开启？[y/N] ' reply || exit 130
    [[ $reply == y || $reply == Y ]] || exit 130
    for path in "$PO0_BACKUP_DIR" "${PO0_BBR_SYSCTL_FILE%/*}" "${PO0_BBR_MODULES_FILE%/*}"; do
        [[ ! -L $path ]] || {
            po0_error "拒绝符号链接目录: $path"
            exit 10
        }
    done
    mkdir -p -- "$PO0_BACKUP_DIR" "${PO0_BBR_SYSCTL_FILE%/*}" "${PO0_BBR_MODULES_FILE%/*}" || exit 20
    chmod 700 "$PO0_BACKUP_DIR" || exit 20
    backup=$(mktemp -d "$PO0_BACKUP_DIR/bbr-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX") || exit 20
    [[ ! -f $PO0_BBR_SYSCTL_FILE ]] || cp -p -- "$PO0_BBR_SYSCTL_FILE" "$backup/sysctl.before" || exit 20
    [[ ! -f $PO0_BBR_MODULES_FILE ]] || cp -p -- "$PO0_BBR_MODULES_FILE" "$backup/modules.before" || exit 20
    printf 'tcp_congestion_control=%s\ndefault_qdisc=%s\n' "$old_algorithm" "$old_queue" >"$backup/before.txt" || exit 20
    po0_bbr_sysctl_content >"$backup/sysctl.candidate" || exit 20
    po0_bbr_modules_content >"$backup/modules.candidate" || exit 20
    # Invoked by the EXIT trap, including failed commands and signals.
    # shellcheck disable=SC2317
    po0_bbr_finish() {
        local status=$1 failed=0
        trap - EXIT
        trap '' HUP INT TERM
        if [[ $committed != 1 ]]; then
            if [[ $runtime_touched == 1 ]]; then
                sysctl -q -w "net.ipv4.tcp_congestion_control=$old_algorithm" || failed=1
                sysctl -q -w "net.core.default_qdisc=$old_queue" || failed=1
            fi
            if [[ $files_touched == 1 ]]; then
                po0_restore_file "$backup/sysctl.before" "$PO0_BBR_SYSCTL_FILE" || failed=1
                po0_restore_file "$backup/modules.before" "$PO0_BBR_MODULES_FILE" || failed=1
            fi
            if [[ $failed == 1 ]]; then
                po0_error "恢复未完成，原值为 TCP=$old_algorithm、默认队列=$old_queue；恢复材料: $backup"
                status=30
            elif [[ $runtime_touched == 1 || $files_touched == 1 ]]; then
                po0_error "BBR + FQ 未提交，已恢复原参数和文件。备份: $backup"
            fi
        fi
        exit "$status"
    }
    trap 'po0_bbr_finish $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if [[ ! $available =~ (^|[[:space:]])bbr($|[[:space:]]) ]]; then
        modprobe tcp_bbr || {
            po0_error '当前内核无法加载 BBR，请使用支持 BBR 的内核。'
            exit 3
        }
        available=$(sysctl -n net.ipv4.tcp_available_congestion_control) || exit 3
        [[ $available =~ (^|[[:space:]])bbr($|[[:space:]]) ]] || {
            po0_error '加载模块后 BBR 仍不可用。'
            exit 3
        }
    fi
    if command -v modprobe >/dev/null 2>&1 && ! modprobe sch_fq; then
        printf 'sch_fq 未能作为模块加载，将以实际 sysctl 设置结果检查内核支持。\n' >&2
    fi
    runtime_touched=1
    sysctl -q -w net.core.default_qdisc=fq || {
        po0_error '内核不支持设置 FQ 默认队列。'
        exit 20
    }
    sysctl -q -w net.ipv4.tcp_congestion_control=bbr || {
        po0_error '设置 BBR 失败。'
        exit 20
    }
    [[ $(sysctl -n net.core.default_qdisc) == fq && $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]] || {
        po0_error 'BBR + FQ 运行参数复核失败。'
        exit 20
    }
    files_touched=1
    po0_atomic_write "$backup/sysctl.candidate" "$PO0_BBR_SYSCTL_FILE" 644 || exit $?
    po0_atomic_write "$backup/modules.candidate" "$PO0_BBR_MODULES_FILE" 644 || exit $?
    committed=1
    po0_message 32 "BBR + FQ 已开启并保存开机配置。原参数与文件备份: $backup"
)

po0_overview() {
    local mode id enabled=0
    case $PO0_MODE in fresh) mode=未初始化 ;; legacy) mode=旧版配置 ;; managed) mode=已接管 ;; *) mode=$PO0_MODE ;; esac
    for id in "${PO0_IDS[@]}"; do [[ ${PO0_ENABLED[$id]} != 1 ]] || enabled=$((enabled + 1)); done
    printf '模式: %s  |  线路: %s  启用: %s  停用: %s\n' "$mode" "${#PO0_IDS[@]}" "$enabled" "$((${#PO0_IDS[@]} - enabled))"
    printf '公网 IPv4: %s\n网卡: %s  |  SNAT 地址: %s\n' "${PO0_PUBLIC_IP:-未设置}" "${PO0_IFACE:-尚未选择}" "${PO0_RELAY_IP:-尚未选择}"
}

po0_menu() {
    po0_heading 'PO0 中转管理'
    po0_overview
    po0_heading '线路管理'
    printf '  1) 查看线路与 URI\n  2) 新增线路\n  3) 编辑线路\n  4) 启用 / 停用线路\n  5) 删除线路\n'
    po0_heading '状态与维护'
    printf '  6) 查看运行状态\n  7) 刷新目标并重新应用\n'
    po0_heading '全局设置'
    printf '  8) 开启 BBR + FQ\n  9) 公网 IP 设置\n  10) 网络调优\n\n  0) 退出\n\n'
}

po0_share_uri() {
    local id=$1
    [[ -n ${PO0_URI[$id]-} ]] || {
        po0_error '此线路未关联 URI。'
        return 3
    }
    [[ -n $PO0_PUBLIC_IP ]] || {
        po0_error '尚未设置公网 IPv4。'
        return 3
    }
    po0_uri rewrite "${PO0_URI[$id]}" "$PO0_PUBLIC_IP" "${PO0_PORT[$id]%-*}"
}

po0_show_share() {
    local id=$1 share
    if [[ -z ${PO0_URI[$id]-} ]]; then
        printf '  URI: 未关联 URI，可在编辑中补录。\n'
    elif [[ -z $PO0_PUBLIC_IP ]]; then
        printf '  URI: 请先通过菜单 9 设置公网 IPv4。\n'
    elif ! command -v python3 >/dev/null 2>&1; then
        printf '  URI: 缺少 python3，无法生成；查看不会安装依赖。\n'
    elif share=$(po0_share_uri "$id"); then
        printf '  中转 URI'
        [[ ${PO0_PORT[$id]} != *-* ]] || printf '（使用区间起始端口 %s）' "${PO0_PORT[$id]%-*}"
        printf ':\n%s\n' "$share"
    else
        printf '  URI: 无法生成，请编辑并检查此线路的 URI。\n'
    fi
}

po0_list() {
    local id state protocol format=${1:-full}
    po0_heading '中转线路'
    po0_overview
    for id in "${PO0_IDS[@]}"; do
        state=停用
        [[ ${PO0_ENABLED[$id]} != 1 ]] || state=启用
        case ${PO0_PROTO[$id]} in tcp) protocol=TCP ;; udp) protocol=UDP ;; both) protocol=TCP+UDP ;; esac
        printf '\n[%s] %s  |  %s  |  %s\n' "$id" "${PO0_NAME[$id]}" "$state" "$protocol"
        printf '  入站: %s:%s\n  目标: %s:%s\n' "${PO0_PUBLIC_IP:-本机}" "${PO0_PORT[$id]}" "${PO0_DEST_IP[$id]}" "${PO0_DEST_PORT[$id]}"
        [[ $format == brief ]] || po0_show_share "$id"
    done
    ((${#PO0_IDS[@]} > 0)) || printf '暂无规则。\n'
    [[ $PO0_MODE != legacy ]] || printf '旧配置仅导入内存；首次确认变更时才备份并迁移。\n'
}

# Every status action reloads the persisted owner; apply's subshell is isolated.
# shellcheck disable=SC2031
po0_status() {
    local table family name value
    po0_list
    printf '\n状态文件: %s\nnft 配置: %s\n访问控制归属: %s\n' "$PO0_STATE_FILE" "$PO0_NFT_FILE" "$PO0_FILTER_OWNER"
    if command -v sysctl >/dev/null 2>&1; then
        value=$(sysctl -n net.ipv4.ip_forward) || return 20
        printf 'IPv4 转发: %s\n' "$value"
        po0_bbr_status
    else printf 'IPv4 转发: 缺少 sysctl，未查询\n'; fi
    if command -v systemctl >/dev/null 2>&1; then
        if value=$(systemctl is-enabled po0-relay.service 2>/dev/null); then :; else :; fi
        printf 'po0-relay 开机启用状态: %s\n' "${value:-未知}"
        if value=$(systemctl is-active po0-relay.service 2>/dev/null); then :; else :; fi
        printf 'po0-relay 服务状态: %s（运行规则以 nft 为准）\n' "${value:-未知}"
    fi
    if command -v nft >/dev/null 2>&1; then
        while IFS= read -r table; do
            IFS=' ' read -r family name <<<"$table"
            printf '\n--- %s ---\n' "$table"
            if ! nft -s list table "$family" "$name"; then
                po0_error "$table 不存在或无法读取；可在检查配置后选择重新应用。"
            fi
        done < <(po0_table_names)
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
            public)
                po0_valid_ipv4 "$PO0_ANSWER" && return 0
                po0_error '请输入有效的公网 IPv4 地址。'
                ;;
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

# One source prompt serves new lines and attaching/replacing an existing URI.
po0_read_source() {
    local existing=${1-} preferred=${2-} mode=${3:-any} candidate result action label='节点 URI 或目标 IPv4'
    local -a values=()
    PO0_SOURCE_URI='' PO0_SOURCE_IP='' PO0_SOURCE_PORT='' PO0_SOURCE_NAME='' PO0_SOURCE_PROTO=both
    [[ $mode != uri ]] || label='节点 URI'
    [[ -z $existing ]] || label+='（回车保留已有 URI）'
    while :; do
        po0_prompt "$label" || return $?
        candidate=${PO0_ANSWER:-$existing}
        if [[ $candidate == *://* ]]; then
            po0_require_tools python3 || return $?
            action=resolve
            if [[ -z $PO0_ANSWER && -n $existing && -n $preferred ]]; then action=parse; fi
            if ! result=$(po0_uri "$action" "$candidate" "$preferred"); then continue; fi
            mapfile -t values <<<"$result"
            [[ $action != parse ]] || values[0]=$preferred
            po0_check_target "${values[0]}" || continue
            PO0_SOURCE_URI=$candidate PO0_SOURCE_IP=${values[0]} PO0_SOURCE_PORT=${values[1]}
            PO0_SOURCE_NAME=${values[2]} PO0_SOURCE_PROTO=${values[3]}
            printf '已识别目标: %s:%s\n' "$PO0_SOURCE_IP" "$PO0_SOURCE_PORT"
            return 0
        fi
        if [[ $mode == uri || -n $existing ]]; then
            po0_error '请填写支持的节点 URI，或回车保留。'
            continue
        fi
        po0_check_target "$candidate" || continue
        PO0_SOURCE_IP=$candidate
        po0_read_value port '目标端口（单个固定端口）' || return $?
        PO0_SOURCE_PORT=$PO0_ANSWER
        return 0
    done
}

po0_read_public_ip() {
    local suggested=${PO0_PUBLIC_IP:-}
    if [[ ${1:-detect} == detect ]]; then
        po0_require_tools python3 || return $?
        printf '正在探测公网 IPv4（最多 5 秒）…\n'
        if ! suggested=$(po0_uri public-ip); then
            suggested=${PO0_PUBLIC_IP:-}
            po0_message 33 '公网探测失败，请手动填写；已有设置不会自动改变。'
        fi
    fi
    po0_read_value public 'PO0 公网 IPv4（可更正；公网端口须与入站端口相同）' "$suggested" || return $?
    PO0_PUBLIC_IP=$PO0_ANSWER
}

po0_update_source_endpoint() {
    local id=$1 host=$2 port=$3 updated
    [[ -n ${PO0_URI[$id]-} ]] || return 0
    po0_require_tools python3 || return $?
    updated=$(po0_uri rewrite "${PO0_URI[$id]}" "$host" "$port") || return $?
    PO0_URI[$id]=$updated
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
    po0_list brief
    printf '\n本次变更: %s\n' "$operation"
    printf '只更新 PO0 专用表；独立模式保留 INPUT/FORWARD 默认丢弃，协作模式由 vpsctl 管理访问控制。\n'
    printf '保留 SSH TCP 端口: '
    printf '%s ' "${PO0_SSH_PORTS[@]}"
    printf '\nIPv4 转发设为 1，其他现有 sysctl 调优保留；启用 po0-relay.service 开机加载。\n'
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
    po0_list brief
    while :; do
        po0_prompt '规则 ID' || return $?
        for id in "${PO0_IDS[@]}"; do [[ $PO0_ANSWER != "$id" ]] || return 0; done
        po0_error '请输入现有规则的 ID。'
    done
}

# A relay response may use the translated public service port after SNAT.
# Read the saved caps for both the original and proposed relay selectors.
po0_warn_tune_ports() {
    local path=$PO0_TUNE_PORTS_STATE
    [[ -e $path || -L $path ]] || return 0
    if [[ -f $path && ! -L $path ]] && command -v python3 >/dev/null 2>&1 &&
        python3 -I - "$path" "$PO0_IFACE" "$@" >&2 <<'PY'
import json
import re
import sys

path, interface, *values = sys.argv[1:]
selectors = []
for port_spec, protocol in zip(values[::2], values[1::2]):
    first, _, last = port_spec.partition("-")
    selectors.append((int(first), int(last or first), protocol))

try:
    with open(path, encoding="utf-8") as state:
        data = json.load(state)
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise ValueError
    rules = data.get("rules")
    if not isinstance(rules, dict):
        raise ValueError
    for identifier, rule in rules.items():
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,47}", identifier) or not isinstance(rule, dict):
            raise ValueError
        port, protocol, family = rule.get("port"), rule.get("protocol"), rule.get("family")
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError
        if protocol not in ("tcp", "udp", "both") or family not in ("ipv4", "ipv6", "both"):
            raise ValueError
        if rule.get("interface") != interface or family == "ipv6":
            continue
        if any(first <= port <= last and (protocol in (relay_proto, "both") or relay_proto == "both")
               for first, last, relay_proto in selectors):
            print(f"[提示] 网络调优静态限速 {identifier} 匹配 {interface} 源端口 {port}/{protocol}。"
                  "线路变更后请按需在 tune port 中调整该限速。")
except (OSError, ValueError):
    sys.exit(1)
PY
    then
        return 0
    fi
    po0_message 33 '[提示] 无法检查已保存的网络调优端口限速，请按需查询 tune port list。' >&2
}

# Every edit happens in a subshell. Declining any prompt discards all changes,
# including new IDs, discovery metadata and partially entered rule fields.
# shellcheck disable=SC2030
po0_action_add() (
    local id name incoming target port protocol uri
    po0_prepare_change || return $?
    id=$PO0_NEXT_ID
    po0_heading '新增线路 · 目标'
    po0_read_source || return $?
    target=$PO0_SOURCE_IP port=$PO0_SOURCE_PORT uri=$PO0_SOURCE_URI
    po0_heading '新增线路 · 入口'
    po0_read_value name '规则名称' "${PO0_SOURCE_NAME:-线路$id}" || return $?
    name=$PO0_ANSWER
    po0_read_incoming || return $?
    incoming=$PO0_ANSWER
    po0_read_protocol "$PO0_SOURCE_PROTO" "$incoming" '' 1 1 || return $?
    protocol=$PO0_ANSWER incoming=$PO0_CHOSEN_PORT
    if [[ -n $uri && -z $PO0_PUBLIC_IP ]]; then po0_read_public_ip || return $?; fi
    PO0_IDS+=("$id") PO0_NAME[$id]=$name PO0_ENABLED[$id]=1 PO0_PROTO[$id]=$protocol
    PO0_PORT[$id]=$incoming PO0_DEST_IP[$id]=$target PO0_DEST_PORT[$id]=$port PO0_NEXT_ID=$((id + 1))
    [[ -z $uri ]] || PO0_URI[$id]=$uri
    po0_choose_initial_network || return $?
    po0_confirm_change "新增规则 $id" || return $?
    po0_apply || return $?
    [[ -z $uri ]] || po0_show_share "$id"
)

# Reload disk state first; only a successful apply persists this subshell's edit.
# shellcheck disable=SC2030,SC2031
po0_action_edit() (
    local id field old_port old_proto
    po0_prepare_change || return $?
    po0_select_rule || return $?
    id=$PO0_ANSWER
    old_port=${PO0_PORT[$id]} old_proto=${PO0_PROTO[$id]}
    while :; do
        po0_heading '编辑线路'
        printf '  1) 名称\n  2) 中转端口\n  3) 目标 IPv4\n  4) 目标端口\n  5) 协议\n  6) 补录 / 替换节点 URI\n'
        po0_prompt '编辑字段编号' || return $?
        field=$PO0_ANSWER
        [[ $field =~ ^[1-6]$ ]] && break
        po0_error '请选择 1–6。'
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
            if [[ $PO0_ANSWER != "${PO0_DEST_IP[$id]}" ]]; then
                po0_update_source_endpoint "$id" "$PO0_ANSWER" "${PO0_DEST_PORT[$id]}" || return $?
            fi
            PO0_DEST_IP[$id]=$PO0_ANSWER
            ;;
        4)
            po0_read_value port '目标端口' "${PO0_DEST_PORT[$id]}" || return $?
            if [[ $PO0_ANSWER != "${PO0_DEST_PORT[$id]}" ]]; then
                po0_update_source_endpoint "$id" '' "$PO0_ANSWER" || return $?
            fi
            PO0_DEST_PORT[$id]=$PO0_ANSWER
            ;;
        5)
            po0_read_protocol "${PO0_PROTO[$id]}" "${PO0_PORT[$id]}" "$id" "${PO0_ENABLED[$id]}" || return $?
            PO0_PROTO[$id]=$PO0_ANSWER
            ;;
        6)
            po0_read_source "${PO0_URI[$id]-}" "${PO0_DEST_IP[$id]}" uri || return $?
            [[ -n $PO0_SOURCE_URI ]] || {
                po0_error '补录需要节点 URI。'
                return 10
            }
            PO0_URI[$id]=$PO0_SOURCE_URI PO0_DEST_IP[$id]=$PO0_SOURCE_IP PO0_DEST_PORT[$id]=$PO0_SOURCE_PORT
            if [[ -z $PO0_PUBLIC_IP ]]; then po0_read_public_ip || return $?; fi
            ;;
    esac
    po0_warn_tune_ports "$old_port" "$old_proto" "${PO0_PORT[$id]}" "${PO0_PROTO[$id]}"
    po0_confirm_change "编辑规则 $id" || return $?
    po0_apply || return $?
    [[ -z ${PO0_URI[$id]-} ]] || po0_show_share "$id"
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
# shellcheck disable=SC2030,SC2031
po0_action_delete() (
    local id other
    local -a remaining=()
    po0_prepare_change || return $?
    po0_select_rule || return $?
    id=$PO0_ANSWER
    po0_warn_tune_ports "${PO0_PORT[$id]}" "${PO0_PROTO[$id]}"
    for other in "${PO0_IDS[@]}"; do [[ $other == "$id" ]] || remaining+=("$other"); done
    PO0_IDS=("${remaining[@]}")
    unset 'PO0_URI[$id]'
    po0_confirm_change "删除规则 $id (${PO0_NAME[$id]})" || return $?
    po0_apply
)

# Each action reloads disk state; previous action subshell edits are discarded.
# shellcheck disable=SC2031
po0_action_reapply() (
    local id result
    local -a values=()
    po0_prepare_change || return $?
    [[ $PO0_MODE != fresh ]] || {
        po0_error '尚未初始化，请先新增规则。'
        return 3
    }
    for id in "${PO0_IDS[@]}"; do
        [[ -n ${PO0_URI[$id]-} ]] || continue
        po0_require_tools python3 || return $?
        result=$(po0_uri resolve "${PO0_URI[$id]}" "${PO0_DEST_IP[$id]}") || return $?
        mapfile -t values <<<"$result"
        po0_check_target "${values[0]}" || return $?
        PO0_DEST_IP[$id]=${values[0]} PO0_DEST_PORT[$id]=${values[1]}
    done
    po0_confirm_change '刷新 URI 目标并重新应用全部当前规则' || return $?
    po0_apply
)

# Public addressing is metadata in the same state/backup transaction as rules.
po0_action_public_ip() (
    local option
    po0_prepare_change || return $?
    [[ $PO0_MODE != fresh ]] || {
        po0_error '请先新增线路；首次添加 URI 时会配置公网 IPv4。'
        return 3
    }
    po0_heading '公网 IP 设置'
    printf '当前公网 IPv4: %s\n  1) 手动填写\n  2) 重新探测\n' "${PO0_PUBLIC_IP:-未设置}"
    while :; do
        po0_prompt '操作编号' 1 || return $?
        option=$PO0_ANSWER
        [[ $option == 1 || $option == 2 ]] && break
        po0_error '请选择 1 或 2。'
    done
    if [[ $option == 2 ]]; then po0_read_public_ip detect || return $?; else po0_read_public_ip manual || return $?; fi
    po0_confirm_change '修改分享 URI 使用的公网 IPv4' || return $?
    po0_apply
)

# Regenerate this payload with scripts/embed-network-tune.py.
po0_tune_archive() {
    python3 -I -m base64 -d <<'PO0_NETWORK_TUNE_PAYLOAD'
UEsDBBQAAAAAAAAAIVAjVexnOwAAADsAAAALAAAAX19tYWluX18ucHlmcm9tIG5ldHdvcmtfdHVu
ZS5jbGkgaW1wb3J0IG1haW4KcmFpc2UgU3lzdGVtRXhpdChtYWluKCkpClBLAwQUAAAAAAAAACFQ
FtZweEkAAABJAAAAGAAAAG5ldHdvcmtfdHVuZS9fX2luaXRfXy5weSIiIk5ldHdvcmsgdHVuaW5n
OiBidWZmZXIgcG9saWN5LCBpbnRlcmZhY2Ugc2hhcGluZywgYW5kIHBvcnQgcGFjaW5nLiIiIgpQ
SwMEFAAAAAAAAAAhUHbWw+o7AQAAOwEAABgAAABuZXR3b3JrX3R1bmUvX19tYWluX18ucHkiIiJT
b3VyY2UtdHJlZSBhbmQgcGFja2FnZWQgZW50cnkgcG9pbnQ7IG5ldmVyIHJ1biBwcm9qZWN0IGNv
ZGUgb24gdGhlIGVkaXRvciBob3N0LiIiIgppbXBvcnQgb3MKaW1wb3J0IHN5cwoKaWYgX19wYWNr
YWdlX18gaW4gKE5vbmUsICIiKToKICAgIHN5cy5wYXRoLmluc2VydCgwLCBvcy5wYXRoLmRpcm5h
bWUob3MucGF0aC5kaXJuYW1lKG9zLnBhdGguYWJzcGF0aChfX2ZpbGVfXykpKSkKCmZyb20gbmV0
d29ya190dW5lLmNsaSBpbXBvcnQgbWFpbgoKaWYgX19uYW1lX18gPT0gIl9fbWFpbl9fIjoKICAg
IHJhaXNlIFN5c3RlbUV4aXQobWFpbigpKQpQSwMEFAAAAAAAAAAhUGJ86kN6WgAAeloAABcAAABu
ZXR3b3JrX3R1bmUvYnVmZmVycy5weSIiIlRDUCBzb2NrZXQgYnVmZmVyIGVzdGltYXRlcyBhbmQg
dGFyZ2V0ZWQgc3lzY3RsIG1hbmFnZW1lbnQuIiIiCgppbXBvcnQgYmFzZTY0CmZyb20gZGVjaW1h
bCBpbXBvcnQgRGVjaW1hbCwgbG9jYWxjb250ZXh0CmZyb20gZm5tYXRjaCBpbXBvcnQgZm5tYXRj
aGNhc2UKaW1wb3J0IG9zCmltcG9ydCByZQoKZnJvbSAuY29tbW9uIGltcG9ydCBNQU5BR0VEX01B
UktFUiwgTUlCLCBTQ0hFTUFfVkVSU0lPTiwgVHVuZUVycm9yLCBwYXJzZV9tYnBzLCBwYXJzZV9z
aXplLCByZWFkX3N5c2N0bCwgc2V0X3N5c2N0bAoKCl9JTlRfTUFYID0gMiAqKiAzMSAtIDEKX0RJ
UkVDVElPTlMgPSB7CiAgICAidHgiOiAoIm5ldC5pcHY0LnRjcF93bWVtIiwgIm5ldC5jb3JlLndt
ZW1fbWF4IiksCiAgICAicngiOiAoIm5ldC5pcHY0LnRjcF9ybWVtIiwgIm5ldC5jb3JlLnJtZW1f
bWF4IiksCn0KX1RSSVBMRVRTID0ge3RjcCBmb3IgdGNwLCBfIGluIF9ESVJFQ1RJT05TLnZhbHVl
cygpfQpfQ09SRV9NQVhJTUEgPSB7Y29yZSBmb3IgXywgY29yZSBpbiBfRElSRUNUSU9OUy52YWx1
ZXMoKX0KX1NXSVRDSF9NQVhJTUEgPSB7CiAgICAibmV0LmlwdjQudGNwX3NhY2siOiAxLAogICAg
Im5ldC5pcHY0LnRjcF90aW1lc3RhbXBzIjogMiwKICAgICJuZXQuaXB2NC50Y3Bfd2luZG93X3Nj
YWxpbmciOiAxLAogICAgIm5ldC5pcHY0LnRjcF9tb2RlcmF0ZV9yY3ZidWYiOiAxLAogICAgIm5l
dC5pcHY0LnRjcF9tdHVfcHJvYmluZyI6IDIsCn0KX0tFWVMgPSBfVFJJUExFVFMgfCBfQ09SRV9N
QVhJTUEgfCBfU1dJVENIX01BWElNQS5rZXlzKCkKX0ZSQUdNRU5UID0gIi9ldGMvc3lzY3RsLmQv
OTktdnBzY3RsLW5ldHdvcmstdHVuZS5jb25mIgpfRlJBR01FTlRfTkFNRSA9IF9GUkFHTUVOVC5y
c3BsaXQoIi8iLCAxKVstMV0KX1NPVVJDRV9ESVJTID0gKCIvZXRjL3N5c2N0bC5kIiwgIi9ydW4v
c3lzY3RsLmQiLCAiL3Vzci9sb2NhbC9saWIvc3lzY3RsLmQiLCAiL3Vzci9saWIvc3lzY3RsLmQi
LCAiL2xpYi9zeXNjdGwuZCIpCl9LRVlfU0VQQVJBVE9SUyA9IHN0ci5tYWtldHJhbnMoIi4vIiwg
Ii8uIikKCgpkZWYgX2ludGVnZXJzKHZhbHVlcyk6CiAgICByZXR1cm4gIiAiLmpvaW4oc3RyKHZh
bHVlKSBmb3IgdmFsdWUgaW4gdmFsdWVzKQoKCmRlZiBfbnVtZXJpY192YWx1ZShrZXksIHZhbHVl
KToKICAgICIiIkNhbm9uaWNhbGl6ZSBhIGtlcm5lbCB2YWx1ZSB3aXRob3V0IGVuZm9yY2luZyBh
IHBvbGljeSBvbiBpdHMgb3JpZ2luYWwgdmFsdWVzLiIiIgogICAgcGFydHMgPSB2YWx1ZS5zcGxp
dCgpIGlmIGlzaW5zdGFuY2UodmFsdWUsIHN0cikgZWxzZSBbXQogICAgY291bnQgPSAzIGlmIGtl
eSBpbiBfVFJJUExFVFMgZWxzZSAxCiAgICBpZiBsZW4ocGFydHMpICE9IGNvdW50IG9yIGFueShu
b3QgcmUuZnVsbG1hdGNoKHIiLT9bMC05XXsxLDEwfSIsIHBhcnQpIGZvciBwYXJ0IGluIHBhcnRz
KToKICAgICAgICByYWlzZSBWYWx1ZUVycm9yKHZhbHVlKQogICAgdmFsdWVzID0gW2ludChwYXJ0
KSBmb3IgcGFydCBpbiBwYXJ0c10KICAgIGlmIGFueShudW1iZXIgPCAtX0lOVF9NQVggLSAxIG9y
IG51bWJlciA+IF9JTlRfTUFYIGZvciBudW1iZXIgaW4gdmFsdWVzKToKICAgICAgICByYWlzZSBW
YWx1ZUVycm9yKHZhbHVlKQogICAgcmV0dXJuIF9pbnRlZ2Vycyh2YWx1ZXMpCgoKZGVmIF9zaXpl
KHZhbHVlKToKICAgIHNpemUgPSBwYXJzZV9zaXplKHZhbHVlKQogICAgaWYgbm90IDAgPCBzaXpl
IDw9IF9JTlRfTUFYOgogICAgICAgIHJhaXNlIFR1bmVFcnJvcihmIue8k+WGsuWMuuWkp+Wwj+W/
hemhu+S4uiAxIOiHsyB7X0lOVF9NQVh9IOWtl+iKgu+8mnt2YWx1ZX0iLCAyKQogICAgcmV0dXJu
IHNpemUKCgpkZWYgX3RyaXBsZXQodmFsdWUpOgogICAgaWYgaXNpbnN0YW5jZSh2YWx1ZSwgKGxp
c3QsIHR1cGxlKSk6CiAgICAgICAgcGFydHMgPSB2YWx1ZQogICAgZWxpZiAiLCIgaW4gdmFsdWU6
CiAgICAgICAgcGFydHMgPSBbcGFydC5zdHJpcCgpIGZvciBwYXJ0IGluIHZhbHVlLnNwbGl0KCIs
IildCiAgICBlbHNlOgogICAgICAgIHBhcnRzID0gdmFsdWUuc3BsaXQoKQogICAgaWYgbGVuKHBh
cnRzKSAhPSAzOgogICAgICAgIHJhaXNlIFR1bmVFcnJvcigiVENQIOe8k+WGsuWMuuS4ieWFg+e7
hOmcgOimgeS+neasoeaPkOS+m+acgOWwj+WAvOOAgem7mOiupOWAvOWSjOacgOWkp+WAvCIsIDIp
CiAgICBzaXplcyA9IFtfc2l6ZShwYXJ0KSBmb3IgcGFydCBpbiBwYXJ0c10KICAgIGlmIG5vdCBz
aXplc1swXSA8PSBzaXplc1sxXSA8PSBzaXplc1syXToKICAgICAgICByYWlzZSBUdW5lRXJyb3Io
IlRDUCDnvJPlhrLljLrkuInlhYPnu4Tlv4Xpobvmu6HotrPmnIDlsI/lgLwg4omkIOm7mOiupOWA
vCDiiaQg5pyA5aSn5YC8IiwgMikKICAgIHJldHVybiBfaW50ZWdlcnMoc2l6ZXMpCgoKZGVmIF9t
YW51YWxfc2V0dGluZyhrZXksIHZhbHVlKToKICAgIGlmIGtleSBpbiBfVFJJUExFVFM6CiAgICAg
ICAgcmV0dXJuIF90cmlwbGV0KHZhbHVlKQogICAgaWYga2V5IGluIF9DT1JFX01BWElNQToKICAg
ICAgICByZXR1cm4gc3RyKF9zaXplKHZhbHVlKSkKICAgIGxpbWl0ID0gX1NXSVRDSF9NQVhJTUFb
a2V5XQogICAgaWYgdmFsdWUgbm90IGluIHtzdHIobnVtYmVyKSBmb3IgbnVtYmVyIGluIHJhbmdl
KGxpbWl0ICsgMSl9OgogICAgICAgIHJhaXNlIFR1bmVFcnJvcihmIntrZXl9IOW/hemhu+S4uiAw
IOiHsyB7bGltaXR9IOeahOaVtOaVsCIsIDIpCiAgICByZXR1cm4gdmFsdWUKCgpkZWYgX2ZyYWdt
ZW50X2NvbnRlbnQodmFsdWVzKToKICAgIHJldHVybiAoZiIjIHtNQU5BR0VEX01BUktFUn0gYnVm
ZmVycy5cbiIgKyAiIi5qb2luKAogICAgICAgIGYie2tleX0gPSB7dmFsdWV9XG4iIGZvciBrZXks
IHZhbHVlIGluIHNvcnRlZCh2YWx1ZXMuaXRlbXMoKSkKICAgICkpLmVuY29kZSgidXRmLTgiKQoK
CmRlZiBfc291cmNlX2tleShrZXkpOgogICAga2V5ID0ga2V5LnN0cmlwKCkKICAgIGRvdCA9IGtl
eS5maW5kKCIuIikKICAgIHNsYXNoID0ga2V5LmZpbmQoIi8iKQogICAgaWYgZG90ID49IDAgYW5k
IChzbGFzaCA9PSAtMSBvciBkb3QgPCBzbGFzaCk6CiAgICAgICAga2V5ID0ga2V5LnRyYW5zbGF0
ZShfS0VZX1NFUEFSQVRPUlMpCiAgICByZXR1cm4gIi8iLmpvaW4ocGFydCBmb3IgcGFydCBpbiBr
ZXkuc3BsaXQoIi8iKSBpZiBwYXJ0KQoKCmRlZiBfbWF0Y2hlcyhwYXR0ZXJuLCBrZXkpOgogICAg
aWYgcGF0dGVybiA9PSBrZXk6CiAgICAgICAgcmV0dXJuIFRydWUKICAgIHBhdHRlcm5fcGFydHMg
PSBwYXR0ZXJuLnNwbGl0KCIvIikKICAgIGtleV9wYXJ0cyA9IGtleS5zcGxpdCgiLyIpCiAgICBy
ZXR1cm4gbGVuKHBhdHRlcm5fcGFydHMpID09IGxlbihrZXlfcGFydHMpIGFuZCBhbGwoCiAgICAg
ICAgZm5tYXRjaGNhc2UocGFydCwgcGF0dGVybl9wYXJ0KSBmb3IgcGFydCwgcGF0dGVybl9wYXJ0
IGluIHppcChrZXlfcGFydHMsIHBhdHRlcm5fcGFydHMpCiAgICApCgoKZGVmIF9lZmZlY3RpdmVf
c291cmNlKGtleSwgZW50cmllcyk6CiAgICBwYXRoX2tleSA9IGtleS5yZXBsYWNlKCIuIiwgIi8i
KQogICAgcGF0dGVybnMgPSB7fQogICAgZm9yIGVudHJ5IGluIGVudHJpZXM6CiAgICAgICAgcGF0
dGVybiA9IGVudHJ5WyJwYXR0ZXJuIl0KICAgICAgICBwcmV2aW91cyA9IHBhdHRlcm5zLmdldChw
YXR0ZXJuKQogICAgICAgIGlmIHByZXZpb3VzIGlzIG5vdCBOb25lIGFuZCBwcmV2aW91c1sidmFs
dWUiXSAhPSBlbnRyeVsidmFsdWUiXToKICAgICAgICAgICAgZGVsIHBhdHRlcm5zW3BhdHRlcm5d
CiAgICAgICAgcGF0dGVybnNbcGF0dGVybl0gPSBlbnRyeQogICAgIyBzeXN0ZW1kIGV4Y2x1ZGVz
IGxpdGVyYWwgYXNzaWdubWVudHMgYW5kIGV4cGxpY2l0IG5lZ2F0aXZlIG1hdGNoZXMgZnJvbSBn
bG9icy4KICAgIGlmIHBhdGhfa2V5IGluIHBhdHRlcm5zOgogICAgICAgIHJldHVybiBwYXR0ZXJu
c1twYXRoX2tleV0KICAgIHJldHVybiBuZXh0KChlbnRyeSBmb3IgZW50cnkgaW4gcmV2ZXJzZWQo
cGF0dGVybnMudmFsdWVzKCkpIGlmIGVudHJ5WyJ2YWx1ZSJdIGlzIG5vdCBOb25lKSwgTm9uZSkK
CgpjbGFzcyBCdWZmZXJNYW5hZ2VyOgogICAgZGVmIF9faW5pdF9fKHNlbGYsIGN0eCk6CiAgICAg
ICAgc2VsZi5jdHggPSBjdHgKICAgICAgICBzZWxmLmNvbmZpZ19maWxlID0gY3R4LnBhdGgoX0ZS
QUdNRU5UKQogICAgICAgIHNlbGYuc3RhdGVfZmlsZSA9IGN0eC5zdGF0ZV9kaXIgLyAiYnVmZmVy
cy5qc29uIgoKICAgIGRlZiBfcnVudGltZV92YWx1ZShzZWxmLCBrZXkpOgogICAgICAgIHRyeToK
ICAgICAgICAgICAgcmV0dXJuIF9udW1lcmljX3ZhbHVlKGtleSwgcmVhZF9zeXNjdGwoc2VsZi5j
dHgsIGtleSkpCiAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3IgYXMgZXJyb3I6CiAgICAgICAgICAg
IHJhaXNlIFR1bmVFcnJvcihmIuaXoOazleivhuWIqyB7a2V5fSDnmoTlvZPliY3lgLzvvJp7ZXJy
b3J9IikgZnJvbSBlcnJvcgoKICAgIGRlZiBfd3JpdGVfdmFsdWUoc2VsZiwga2V5LCB2YWx1ZSk6
CiAgICAgICAgc2V0X3N5c2N0bChzZWxmLmN0eCwga2V5LCB2YWx1ZSkKICAgICAgICBvYnNlcnZl
ZCA9IHNlbGYuX3J1bnRpbWVfdmFsdWUoa2V5KQogICAgICAgIGlmIG9ic2VydmVkICE9IHZhbHVl
OgogICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoZiJ7a2V5fSDlhpnlhaXlkI7kuLoge29ic2Vy
dmVkfe+8jOmihOacn+S4uiB7dmFsdWV9IiwgMjApCgogICAgZGVmIF9jb25maWdfYXNzaWdubWVu
dHMoc2VsZiwga2V5cywgKiwgcHJvcG9zZWQ9Tm9uZSwgd2l0aG91dF9vd25lZD1GYWxzZSwgY3Jl
YXRpbmc9RmFsc2UpOgogICAgICAgIGZpbGVzID0ge30KICAgICAgICBmb3IgbG9naWNhbCBpbiBf
U09VUkNFX0RJUlM6CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIGZvciBwYXRoIGlu
IHNlbGYuY3R4LnBhdGgobG9naWNhbCkuaXRlcmRpcigpOgogICAgICAgICAgICAgICAgICAgIGlm
IHBhdGgubmFtZS5zdGFydHN3aXRoKCIuIikgb3IgcGF0aC5zdWZmaXggIT0gIi5jb25mIiBvciBw
YXRoLm5hbWUgaW4gZmlsZXM6CiAgICAgICAgICAgICAgICAgICAgICAgIGNvbnRpbnVlCiAgICAg
ICAgICAgICAgICAgICAgaWYgcGF0aCA9PSBzZWxmLmNvbmZpZ19maWxlIGFuZCAod2l0aG91dF9v
d25lZCBvciBwcm9wb3NlZCBpcyBub3QgTm9uZSk6CiAgICAgICAgICAgICAgICAgICAgICAgIGNv
bnRpbnVlCiAgICAgICAgICAgICAgICAgICAgaWYgcGF0aC5pc19zeW1saW5rKCkgb3IgcGF0aC5p
c19maWxlKCk6CiAgICAgICAgICAgICAgICAgICAgICAgIGZpbGVzW3BhdGgubmFtZV0gPSAoZiJ7
bG9naWNhbH0ve3BhdGgubmFtZX0iLCBwYXRoKQogICAgICAgICAgICBleGNlcHQgRmlsZU5vdEZv
dW5kRXJyb3I6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBleGNlcHQgT1NF
cnJvciBhcyBlcnJvcjoKICAgICAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcihmIuaXoOazleiv
u+WPliBzeXNjdGwuZCDnm67lvZUge2xvZ2ljYWx977yae2Vycm9yfSIpIGZyb20gZXJyb3IKICAg
ICAgICBpZiBwcm9wb3NlZCBpcyBub3QgTm9uZToKICAgICAgICAgICAgc2hhZG93ZWQgPSBmaWxl
cy5nZXQoX0ZSQUdNRU5UX05BTUUpCiAgICAgICAgICAgIGlmIGNyZWF0aW5nIGFuZCBzaGFkb3dl
ZCBhbmQgc2hhZG93ZWRbMV0uaXNfZmlsZSgpOgogICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVy
cm9yKGYi5Yib5bu6IHtfRlJBR01FTlR9IOS8mumBruiUveeOsOaciemFjee9riB7c2hhZG93ZWRb
MF19IikKICAgICAgICAgICAgZmlsZXNbX0ZSQUdNRU5UX05BTUVdID0gKF9GUkFHTUVOVCwgTm9u
ZSkKCiAgICAgICAgbm9ybWFsaXplZCA9IHtrZXk6IGtleS5yZXBsYWNlKCIuIiwgIi8iKSBmb3Ig
a2V5IGluIGtleXN9CiAgICAgICAgcmVzdWx0ID0ge2tleTogW10gZm9yIGtleSBpbiBrZXlzfQog
ICAgICAgIGZvciBuYW1lIGluIHNvcnRlZChmaWxlcywga2V5PW9zLmZzZW5jb2RlKToKICAgICAg
ICAgICAgbG9naWNhbCwgcGF0aCA9IGZpbGVzW25hbWVdCiAgICAgICAgICAgIHRyeToKICAgICAg
ICAgICAgICAgIGlmIHBhdGggaXMgTm9uZToKICAgICAgICAgICAgICAgICAgICBjb250ZW50ID0g
X2ZyYWdtZW50X2NvbnRlbnQocHJvcG9zZWQpLmRlY29kZSgidXRmLTgiKQogICAgICAgICAgICAg
ICAgZWxpZiBwYXRoLmlzX2ZpbGUoKToKICAgICAgICAgICAgICAgICAgICBjb250ZW50ID0gcGF0
aC5yZWFkX3RleHQoZW5jb2Rpbmc9InV0Zi04IiwgZXJyb3JzPSJzdXJyb2dhdGVlc2NhcGUiKQog
ICAgICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAgICAgICAjIEEgc3ltbGluayB0byAv
ZGV2L251bGwgbWFza3MgYSBsb3dlci1wcmlvcml0eSBmaWxlIHdpdGggdGhlIHNhbWUgbmFtZS4K
ICAgICAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBleGNlcHQgT1NFcnJvciBh
cyBlcnJvcjoKICAgICAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcihmIuaXoOazleivu+WPliBz
eXNjdGwg6YWN572uIHtsb2dpY2Fsfe+8mntlcnJvcn0iKSBmcm9tIGVycm9yCiAgICAgICAgICAg
IGZvciBudW1iZXIsIGxpbmUgaW4gZW51bWVyYXRlKGNvbnRlbnQuc3BsaXRsaW5lcygpLCAxKToK
ICAgICAgICAgICAgICAgIGxpbmUgPSBsaW5lLnN0cmlwKCkKICAgICAgICAgICAgICAgIGlmIG5v
dCBsaW5lIG9yIGxpbmUuc3RhcnRzd2l0aCgoIiMiLCAiOyIpKToKICAgICAgICAgICAgICAgICAg
ICBjb250aW51ZQogICAgICAgICAgICAgICAgc2V0dGluZ19rZXksIGVxdWFscywgdmFsdWUgPSBs
aW5lLnJlbW92ZXByZWZpeCgiLSIpLnBhcnRpdGlvbigiPSIpCiAgICAgICAgICAgICAgICBpZiBu
b3QgZXF1YWxzIGFuZCBub3QgbGluZS5zdGFydHN3aXRoKCItIik6CiAgICAgICAgICAgICAgICAg
ICAgY29udGludWUKICAgICAgICAgICAgICAgIHBhdHRlcm4gPSBfc291cmNlX2tleShzZXR0aW5n
X2tleSkKICAgICAgICAgICAgICAgIGZvciBrZXksIHBhdGhfa2V5IGluIG5vcm1hbGl6ZWQuaXRl
bXMoKToKICAgICAgICAgICAgICAgICAgICBpZiBfbWF0Y2hlcyhwYXR0ZXJuLCBwYXRoX2tleSk6
CiAgICAgICAgICAgICAgICAgICAgICAgIHJlc3VsdFtrZXldLmFwcGVuZCh7ImZpbGUiOiBsb2dp
Y2FsLCAibGluZSI6IG51bWJlciwgInBhdHRlcm4iOiBwYXR0ZXJuLAogICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICJ2YWx1ZSI6IHZhbHVlLnN0cmlwKCkgaWYgZXF1
YWxzIGVsc2UgTm9uZX0pCiAgICAgICAgcmV0dXJuIHJlc3VsdAoKICAgIGRlZiBfZXhpc3Rpbmco
c2VsZiwgKiwgcmVxdWlyZV9vd25lZD1UcnVlKToKICAgICAgICBzdGF0ZV9zbmFwc2hvdCA9IHNl
bGYuY3R4LnNuYXBzaG90X2ZpbGUoc2VsZi5zdGF0ZV9maWxlKQogICAgICAgIGNvbmZpZ19zbmFw
c2hvdCA9IHNlbGYuY3R4LnNuYXBzaG90X2ZpbGUoc2VsZi5jb25maWdfZmlsZSkKICAgICAgICBz
dGF0ZSA9IHNlbGYuY3R4LnJlYWRfanNvbihzZWxmLnN0YXRlX2ZpbGUsIGRlZmF1bHQ9Tm9uZSkK
ICAgICAgICBpZiBzdGF0ZV9zbmFwc2hvdFsiZXhpc3RzIl06CiAgICAgICAgICAgIHZlcnNpb24g
PSBzdGF0ZS5nZXQoInNjaGVtYV92ZXJzaW9uIikgaWYgaXNpbnN0YW5jZShzdGF0ZSwgZGljdCkg
ZWxzZSBOb25lCiAgICAgICAgICAgIGlmIHR5cGUodmVyc2lvbikgaXMgbm90IGludCBvciB2ZXJz
aW9uICE9IFNDSEVNQV9WRVJTSU9OOgogICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLm
l6Dms5Xor4bliKsgVENQIOe8k+WGsuWMuueKtuaAgeeahOeJiOacrCIpCiAgICAgICAgICAgIGRl
c2lyZWQsIG9yaWdpbmFsID0gc3RhdGUuZ2V0KCJkZXNpcmVkIiksIHN0YXRlLmdldCgib3JpZ2lu
YWwiKQogICAgICAgICAgICBpZiBub3QgaXNpbnN0YW5jZShkZXNpcmVkLCBkaWN0KSBvciBub3Qg
aXNpbnN0YW5jZShvcmlnaW5hbCwgZGljdCkgb3Igbm90IGRlc2lyZWQ6CiAgICAgICAgICAgICAg
ICByYWlzZSBUdW5lRXJyb3IoIlRDUCDnvJPlhrLljLrnirbmgIHnvLrlsJHlt7LnrqHnkIbnmoTl
j4LmlbAiKQogICAgICAgICAgICBpZiBkZXNpcmVkLmtleXMoKSAhPSBvcmlnaW5hbC5rZXlzKCkg
b3Igbm90IGRlc2lyZWQua2V5cygpIDw9IF9LRVlTOgogICAgICAgICAgICAgICAgcmFpc2UgVHVu
ZUVycm9yKCJUQ1Ag57yT5Yay5Yy654q25oCB5YyF5ZCr5LiN5Yy56YWN55qE5Y+C5pWwIikKICAg
ICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgaWYgYW55KF9udW1lcmljX3ZhbHVlKGtleSwg
dmFsdWUpICE9IHZhbHVlIGZvciB2YWx1ZXMgaW4gKGRlc2lyZWQsIG9yaWdpbmFsKSBmb3Iga2V5
LCB2YWx1ZSBpbiB2YWx1ZXMuaXRlbXMoKSk6CiAgICAgICAgICAgICAgICAgICAgcmFpc2UgVmFs
dWVFcnJvcgogICAgICAgICAgICBleGNlcHQgVmFsdWVFcnJvciBhcyBlcnJvcjoKICAgICAgICAg
ICAgICAgIHJhaXNlIFR1bmVFcnJvcigiVENQIOe8k+WGsuWMuueKtuaAgeWMheWQq+aXoOaViOea
hOWPguaVsOWAvCIpIGZyb20gZXJyb3IKICAgICAgICBlbHNlOgogICAgICAgICAgICBzdGF0ZSA9
IE5vbmUKCiAgICAgICAgb3duZWQgPSBib29sKHN0YXRlIGFuZCBjb25maWdfc25hcHNob3RbImV4
aXN0cyJdIGFuZAogICAgICAgICAgICAgICAgICAgICBiYXNlNjQuYjY0ZGVjb2RlKGNvbmZpZ19z
bmFwc2hvdFsiZGF0YSJdKSA9PSBfZnJhZ21lbnRfY29udGVudChzdGF0ZVsiZGVzaXJlZCJdKSkK
ICAgICAgICBpZiByZXF1aXJlX293bmVkIGFuZCBjb25maWdfc25hcHNob3RbImV4aXN0cyJdIGFu
ZCBub3Qgb3duZWQ6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcihmIntfRlJBR01FTlR9IOW3
suWtmOWcqOS4lOWGheWuueS4jiBUQ1Ag57yT5Yay5Yy654q25oCB5LiN5Yy56YWNIikKICAgICAg
ICByZXR1cm4gc3RhdGUsIHN0YXRlX3NuYXBzaG90LCBjb25maWdfc25hcHNob3QsIG93bmVkCgog
ICAgZGVmIGVzdGltYXRlKHNlbGYsIGFyZ3MpOgogICAgICAgIHJhdGVfYXJndW1lbnRzID0ge2Rp
cmVjdGlvbjogZ2V0YXR0cihhcmdzLCBmIntkaXJlY3Rpb259X21icHMiLCBOb25lKSBmb3IgZGly
ZWN0aW9uIGluIF9ESVJFQ1RJT05TfQogICAgICAgIHJhdGVfYXJndW1lbnRzID0ge2RpcmVjdGlv
bjogdmFsdWUgZm9yIGRpcmVjdGlvbiwgdmFsdWUgaW4gcmF0ZV9hcmd1bWVudHMuaXRlbXMoKSBp
ZiB2YWx1ZSBpcyBub3QgTm9uZX0KICAgICAgICBydHRfdGV4dCA9IHN0cihnZXRhdHRyKGFyZ3Ms
ICJydHRfbXMiLCAiIikpLnN0cmlwKCkKICAgICAgICBpZiBub3QgcmF0ZV9hcmd1bWVudHMgb3Ig
bm90IHJlLmZ1bGxtYXRjaChyIlswLTldKyg/OlwuWzAtOV0qKT98XC5bMC05XSsiLCBydHRfdGV4
dCk6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5Lyw566X6ZyA6KaB5q2j5pWwIC0tcnR0
LW1zIOWSjOiHs+WwkeS4gOS4quaWueWQkeeahOmAn+eOhyIsIDIpCiAgICAgICAgcnR0ID0gRGVj
aW1hbChydHRfdGV4dCkKICAgICAgICBpZiBydHQgPD0gMDoKICAgICAgICAgICAgcmFpc2UgVHVu
ZUVycm9yKCItLXJ0dC1tcyDlv4XpobvlpKfkuo4gMCIsIDIpCiAgICAgICAgcmF0ZXMgPSB7ZGly
ZWN0aW9uOiBwYXJzZV9tYnBzKHZhbHVlKSBmb3IgZGlyZWN0aW9uLCB2YWx1ZSBpbiByYXRlX2Fy
Z3VtZW50cy5pdGVtcygpfQogICAgICAgIHNlbGYuY3R4LnJlcXVpcmVfdG9vbHMoInN5c2N0bCIp
CiAgICAgICAgbWVtb3J5ID0gc2VsZi5jdHgubWVtb3J5X2J5dGVzKCkKICAgICAgICBidWRnZXQg
PSBtZW1vcnkgLy8gKDE2ICogTUlCKSAqIE1JQgogICAgICAgIGNhcCA9IG1pbihidWRnZXQsIF9J
TlRfTUFYIC8vIE1JQiAqIE1JQikKICAgICAgICByZXN1bHQgPSB7InJ0dF9tcyI6IHJ0dF90ZXh0
LCAibWVtb3J5X2J5dGVzIjogbWVtb3J5LCAiYnVkZ2V0X2J5dGVzIjogYnVkZ2V0fQogICAgICAg
IGZvciBkaXJlY3Rpb24sIGJwcyBpbiByYXRlcy5pdGVtcygpOgogICAgICAgICAgICB0Y3AsIGNv
cmUgPSBfRElSRUNUSU9OU1tkaXJlY3Rpb25dCiAgICAgICAgICAgICMgTWJwcyDDlyBtaWxsaXNl
Y29uZHMgw5cgMTI1IGlzIGVxdWl2YWxlbnQgdG8gYnBzIMOXIG1pbGxpc2Vjb25kcyDDlyAwLjAw
MDEyNS4KICAgICAgICAgICAgd2l0aCBsb2NhbGNvbnRleHQoKSBhcyBkZWNpbWFsX2NvbnRleHQ6
CiAgICAgICAgICAgICAgICBkZWNpbWFsX2NvbnRleHQucHJlYyA9IGxlbihydHQuYXNfdHVwbGUo
KS5kaWdpdHMpICsgbGVuKHN0cihicHMpKSArIDMKICAgICAgICAgICAgICAgIGJkcCA9IHJ0dCAq
IGJwcyAqIERlY2ltYWwoIjAuMDAwMTI1IikKICAgICAgICAgICAgbnVtZXJhdG9yLCBkZW5vbWlu
YXRvciA9IGJkcC5hc19pbnRlZ2VyX3JhdGlvKCkKICAgICAgICAgICAgbWliX2Rpdmlzb3IgPSBk
ZW5vbWluYXRvciAqIE1JQgogICAgICAgICAgICBuZWVkID0gbWF4KDQsIDIgKyAoMiAqIG51bWVy
YXRvciArIG1pYl9kaXZpc29yIC0gMSkgLy8gbWliX2Rpdmlzb3IpICogTUlCCiAgICAgICAgICAg
IGN1cnJlbnQgPSBbaW50KHBhcnQpIGZvciBwYXJ0IGluIHNlbGYuX3J1bnRpbWVfdmFsdWUodGNw
KS5zcGxpdCgpXQogICAgICAgICAgICByZWFzb24gPSBOb25lCiAgICAgICAgICAgIHN1Z2dlc3Rp
b24gPSBOb25lCiAgICAgICAgICAgIGlmIG5vdCAwIDw9IGN1cnJlbnRbMF0gPD0gY3VycmVudFsx
XToKICAgICAgICAgICAgICAgIHJlYXNvbiA9ICLnjrDmnInmnIDlsI/lgLzlkozpu5jorqTlgLzm
l6Dms5Xnu4TmiJDmnInmlYjnmoTnvJPlhrLljLrkuInlhYPnu4QiCiAgICAgICAgICAgIGVsaWYg
Y2FwID09IDAgb3IgY3VycmVudFsxXSA+IGNhcDoKICAgICAgICAgICAgICAgIHJlYXNvbiA9ICLl
j6/nlKjkuIrpmZDml6Dms5Xkv53nlZnnjrDmnInmnIDlsI/lgLzlkozpu5jorqTlgLwiCiAgICAg
ICAgICAgIGVsc2U6CiAgICAgICAgICAgICAgICBzdWdnZXN0aW9uID0gY3VycmVudFs6Ml0gKyBb
bWF4KGN1cnJlbnRbMV0sIG1pbihuZWVkLCBjYXApKV0KICAgICAgICAgICAgICAgIGlmIHN1Z2dl
c3Rpb25bMl0gPCBuZWVkOgogICAgICAgICAgICAgICAgICAgIHJlYXNvbiA9ICLlu7rorq7kuIrp
mZDlj5flhoXlrZjpooTnrpfmiJblhoXmoLjmlbTmlbDojIPlm7TpmZDliLYiCiAgICAgICAgICAg
IHJlc3VsdFtkaXJlY3Rpb25dID0gewogICAgICAgICAgICAgICAgInJhdGVfYnBzIjogYnBzLCAi
YmRwX2J5dGVzIjogZm9ybWF0KGJkcCwgImYiKSwgIm5lZWRlZF9tYXhfYnl0ZXMiOiBuZWVkLAog
ICAgICAgICAgICAgICAgInN1Z2dlc3RlZF9tYXhfYnl0ZXMiOiBzdWdnZXN0aW9uWzJdIGlmIHN1
Z2dlc3Rpb24gZWxzZSBOb25lLAogICAgICAgICAgICAgICAgImN1cnJlbnRfdHJpcGxldCI6IGN1
cnJlbnQsICJzdWdnZXN0ZWRfdHJpcGxldCI6IHN1Z2dlc3Rpb24sICJyZWFzb24iOiByZWFzb24s
CiAgICAgICAgICAgICAgICAia2V5IjogdGNwLCAiY29yZV9rZXkiOiBjb3JlIGlmIGdldGF0dHIo
YXJncywgInN5bmNfY29yZSIsIEZhbHNlKSBlbHNlIE5vbmUsCiAgICAgICAgICAgIH0KICAgICAg
ICByZXN1bHRbIm1lc3NhZ2UiXSA9ICJUQ1Ag57yT5Yay5Yy65Lyw566XIgogICAgICAgIHJldHVy
biByZXN1bHQKCiAgICBkZWYgX21hbnVhbF92YWx1ZXMoc2VsZiwgYXJncywgc3luYyk6CiAgICAg
ICAgdXBkYXRlcyA9IHt9CiAgICAgICAgYmVmb3JlID0ge30KCiAgICAgICAgZGVmIGFkZChrZXks
IHZhbHVlKToKICAgICAgICAgICAgaWYga2V5IGluIHVwZGF0ZXM6CiAgICAgICAgICAgICAgICBy
YWlzZSBUdW5lRXJyb3IoZiLph43lpI3orr7nva4ge2tleX0iLCAyKQogICAgICAgICAgICB1cGRh
dGVzW2tleV0gPSB2YWx1ZQoKICAgICAgICBmb3Igc2V0dGluZyBpbiBnZXRhdHRyKGFyZ3MsICJz
ZXR0aW5ncyIsIE5vbmUpIG9yIFtdOgogICAgICAgICAgICBrZXksIGVxdWFscywgdmFsdWUgPSBz
ZXR0aW5nLnBhcnRpdGlvbigiPSIpCiAgICAgICAgICAgIGtleSA9IGtleS5zdHJpcCgpCiAgICAg
ICAgICAgIGlmIG5vdCBlcXVhbHMgb3Iga2V5IG5vdCBpbiBfS0VZUzoKICAgICAgICAgICAgICAg
IHJhaXNlIFR1bmVFcnJvcihmIuS4jeaUr+aMgeeahCBUQ1Ag57yT5Yay5Yy66K6+572u77yae3Nl
dHRpbmd9IiwgMikKICAgICAgICAgICAgYWRkKGtleSwgX21hbnVhbF9zZXR0aW5nKGtleSwgdmFs
dWUuc3RyaXAoKSkpCiAgICAgICAgc2VsZWN0ZWRfbWF4ID0gRmFsc2UKICAgICAgICBmb3IgZGly
ZWN0aW9uLCAodGNwLCBjb3JlKSBpbiBfRElSRUNUSU9OUy5pdGVtcygpOgogICAgICAgICAgICBt
YXhpbXVtID0gZ2V0YXR0cihhcmdzLCBmIntkaXJlY3Rpb259X21heCIsIE5vbmUpCiAgICAgICAg
ICAgIHRyaXBsZXQgPSBnZXRhdHRyKGFyZ3MsIGYie2RpcmVjdGlvbn1fdHJpcGxldCIsIE5vbmUp
CiAgICAgICAgICAgIGlmIG1heGltdW0gaXMgbm90IE5vbmUgYW5kIHRyaXBsZXQgaXMgbm90IE5v
bmU6CiAgICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoZiItLXtkaXJlY3Rpb259LW1heCDl
kowgLS17ZGlyZWN0aW9ufS10cmlwbGV0IOWPquiDveS9v+eUqOS4gOS4qiIsIDIpCiAgICAgICAg
ICAgIGlmIG1heGltdW0gaXMgbm90IE5vbmU6CiAgICAgICAgICAgICAgICBtYXhpbXVtID0gX3Np
emUobWF4aW11bSkKICAgICAgICAgICAgICAgIGN1cnJlbnQgPSBiZWZvcmVbdGNwXSA9IHNlbGYu
X3J1bnRpbWVfdmFsdWUodGNwKQogICAgICAgICAgICAgICAgbWluaW11bSwgZGVmYXVsdCwgXyA9
IChpbnQocGFydCkgZm9yIHBhcnQgaW4gY3VycmVudC5zcGxpdCgpKQogICAgICAgICAgICAgICAg
aWYgbm90IDAgPD0gbWluaW11bSA8PSBkZWZhdWx0IDw9IG1heGltdW06CiAgICAgICAgICAgICAg
ICAgICAgcmFpc2UgVHVuZUVycm9yKGYiLS17ZGlyZWN0aW9ufS1tYXgg5peg5rOV5L+d55WZ5b2T
5YmN5pyA5bCP5YC85ZKM6buY6K6k5YC8IHttaW5pbXVtfSB7ZGVmYXVsdH3vvIzlj6/mj5Dkvpvl
rozmlbTkuInlhYPnu4QiLCAyKQogICAgICAgICAgICAgICAgYWRkKHRjcCwgX2ludGVnZXJzKCht
aW5pbXVtLCBkZWZhdWx0LCBtYXhpbXVtKSkpCiAgICAgICAgICAgICAgICBpZiBzeW5jOgogICAg
ICAgICAgICAgICAgICAgIGFkZChjb3JlLCBzdHIobWF4aW11bSkpCiAgICAgICAgICAgICAgICBz
ZWxlY3RlZF9tYXggPSBUcnVlCiAgICAgICAgICAgIGlmIHRyaXBsZXQgaXMgbm90IE5vbmU6CiAg
ICAgICAgICAgICAgICBhZGQodGNwLCBfdHJpcGxldCh0cmlwbGV0KSkKICAgICAgICBpZiBzeW5j
IGFuZCBub3Qgc2VsZWN0ZWRfbWF4OgogICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIi0tc3lu
Yy1jb3JlIOmcgOimgeaMh+WumiAtLXR4LW1heOOAgS0tcngtbWF4IOaIliAtLXJlY29tbWVuZGVk
IiwgMikKICAgICAgICBpZiBub3QgdXBkYXRlczoKICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9y
KCLpnIDopoHmjIflrprlu7rorq7lgLzjgIHnvJPlhrLljLrkuIrpmZDjgIHkuInlhYPnu4TmiJbp
q5jnuqflj4LmlbAiLCAyKQogICAgICAgIHJldHVybiB1cGRhdGVzLCBiZWZvcmUKCiAgICBkZWYg
X3ZlcmlmeV9wZXJzaXN0ZW5jZShzZWxmLCBkZXNpcmVkLCBzZWxlY3RlZCwgKiwgY3JlYXRpbmcp
OgogICAgICAgIHNvdXJjZXMgPSBzZWxmLl9jb25maWdfYXNzaWdubWVudHMoc2VsZWN0ZWQsIHBy
b3Bvc2VkPWRlc2lyZWQsIGNyZWF0aW5nPWNyZWF0aW5nKQogICAgICAgIGZvciBrZXksIGVudHJp
ZXMgaW4gc291cmNlcy5pdGVtcygpOgogICAgICAgICAgICBlZmZlY3RpdmUgPSBfZWZmZWN0aXZl
X3NvdXJjZShrZXksIGVudHJpZXMpCiAgICAgICAgICAgIGlmIGVmZmVjdGl2ZSBpcyBOb25lOgog
ICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKGYie19GUkFHTUVOVH0g57y65bCRIHtrZXl9
IOeahOaMgeS5heWMluWAvCIpCiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIGlmIF9u
dW1lcmljX3ZhbHVlKGtleSwgZWZmZWN0aXZlWyJ2YWx1ZSJdKSA9PSBkZXNpcmVkW2tleV06CiAg
ICAgICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3I6
CiAgICAgICAgICAgICAgICBwYXNzCiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcihmIntlZmZl
Y3RpdmVbJ2ZpbGUnXX06e2VmZmVjdGl2ZVsnbGluZSddfSDnmoQge2tleX0g5Lya6KaG55uWIHtf
RlJBR01FTlR9IikKCiAgICBkZWYgX3Jlc3RvcmVfdmFsdWVzKHNlbGYsIG9yaWdpbmFsKToKICAg
ICAgICBjb25maWd1cmVkID0gc2VsZi5fY29uZmlnX2Fzc2lnbm1lbnRzKG9yaWdpbmFsLCB3aXRo
b3V0X293bmVkPVRydWUpCiAgICAgICAgdmFsdWVzID0ge30KICAgICAgICBzb3VyY2VzID0ge30K
ICAgICAgICBmb3Iga2V5LCB2YWx1ZSBpbiBvcmlnaW5hbC5pdGVtcygpOgogICAgICAgICAgICBl
ZmZlY3RpdmUgPSBfZWZmZWN0aXZlX3NvdXJjZShrZXksIGNvbmZpZ3VyZWRba2V5XSkKICAgICAg
ICAgICAgaWYgZWZmZWN0aXZlIGFuZCBlZmZlY3RpdmVbInZhbHVlIl0gaXMgbm90IE5vbmU6CiAg
ICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgdmFsdWUgPSBfbnVtZXJpY192
YWx1ZShrZXksIGVmZmVjdGl2ZVsidmFsdWUiXSkKICAgICAgICAgICAgICAgIGV4Y2VwdCBWYWx1
ZUVycm9yIGFzIGVycm9yOgogICAgICAgICAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcihmIuaX
oOazlei/mOWOnyB7ZWZmZWN0aXZlWydmaWxlJ119OntlZmZlY3RpdmVbJ2xpbmUnXX0g5Lit55qE
IHtrZXl977ya5YC85peg5pWIIikgZnJvbSBlcnJvcgogICAgICAgICAgICAgICAgc291cmNlc1tr
ZXldID0gZWZmZWN0aXZlWyJmaWxlIl0KICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAg
IHNvdXJjZXNba2V5XSA9IE5vbmUKICAgICAgICAgICAgdmFsdWVzW2tleV0gPSB2YWx1ZQogICAg
ICAgIHJldHVybiB2YWx1ZXMsIHNvdXJjZXMKCiAgICBkZWYgX2FwcGx5KHNlbGYsIGJlZm9yZSwg
dmFsdWVzLCBzdGF0ZSwgc3RhdGVfc25hcHNob3QsIGNvbmZpZ19zbmFwc2hvdCk6CiAgICAgICAg
YXR0ZW1wdGVkID0gW10KICAgICAgICB0b3VjaGVkID0gW10KICAgICAgICB0cnk6CiAgICAgICAg
ICAgIGZvciBrZXkgaW4gc29ydGVkKHZhbHVlcyk6CiAgICAgICAgICAgICAgICBpZiBiZWZvcmVb
a2V5XSAhPSB2YWx1ZXNba2V5XToKICAgICAgICAgICAgICAgICAgICBhdHRlbXB0ZWQuYXBwZW5k
KGtleSkKICAgICAgICAgICAgICAgICAgICBzZWxmLl93cml0ZV92YWx1ZShrZXksIHZhbHVlc1tr
ZXldKQogICAgICAgICAgICBpZiBzdGF0ZSBpcyBOb25lOgogICAgICAgICAgICAgICAgaWYgY29u
ZmlnX3NuYXBzaG90WyJleGlzdHMiXToKICAgICAgICAgICAgICAgICAgICB0b3VjaGVkLmFwcGVu
ZCgoc2VsZi5jb25maWdfZmlsZSwgY29uZmlnX3NuYXBzaG90KSkKICAgICAgICAgICAgICAgICAg
ICBzZWxmLmN0eC5yZW1vdmVfZmlsZShzZWxmLmNvbmZpZ19maWxlKQogICAgICAgICAgICAgICAg
dG91Y2hlZC5hcHBlbmQoKHNlbGYuc3RhdGVfZmlsZSwgc3RhdGVfc25hcHNob3QpKQogICAgICAg
ICAgICAgICAgc2VsZi5jdHgucmVtb3ZlX2ZpbGUoc2VsZi5zdGF0ZV9maWxlKQogICAgICAgICAg
ICBlbHNlOgogICAgICAgICAgICAgICAgY29udGVudCA9IF9mcmFnbWVudF9jb250ZW50KHN0YXRl
WyJkZXNpcmVkIl0pCiAgICAgICAgICAgICAgICBpZiBub3QgY29uZmlnX3NuYXBzaG90WyJleGlz
dHMiXSBvciBiYXNlNjQuYjY0ZGVjb2RlKGNvbmZpZ19zbmFwc2hvdFsiZGF0YSJdKSAhPSBjb250
ZW50OgogICAgICAgICAgICAgICAgICAgIHRvdWNoZWQuYXBwZW5kKChzZWxmLmNvbmZpZ19maWxl
LCBjb25maWdfc25hcHNob3QpKQogICAgICAgICAgICAgICAgICAgIHNlbGYuY3R4LmF0b21pY193
cml0ZShzZWxmLmNvbmZpZ19maWxlLCBjb250ZW50LCBtb2RlPTBvNjQ0KQogICAgICAgICAgICAg
ICAgaWYgc2VsZi5jdHgucmVhZF9qc29uKHNlbGYuc3RhdGVfZmlsZSwgZGVmYXVsdD1Ob25lKSAh
PSBzdGF0ZToKICAgICAgICAgICAgICAgICAgICB0b3VjaGVkLmFwcGVuZCgoc2VsZi5zdGF0ZV9m
aWxlLCBzdGF0ZV9zbmFwc2hvdCkpCiAgICAgICAgICAgICAgICAgICAgc2VsZi5jdHgud3JpdGVf
anNvbihzZWxmLnN0YXRlX2ZpbGUsIHN0YXRlKQogICAgICAgIGV4Y2VwdCAoRXhjZXB0aW9uLCBL
ZXlib2FyZEludGVycnVwdCkgYXMgZXJyb3I6CiAgICAgICAgICAgIGZhaWx1cmVzID0gW10KICAg
ICAgICAgICAgZm9yIHBhdGgsIHNuYXBzaG90IGluIHJldmVyc2VkKHRvdWNoZWQpOgogICAgICAg
ICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgICAgIHNlbGYuY3R4LnJlc3RvcmVfZmlsZShw
YXRoLCBzbmFwc2hvdCkKICAgICAgICAgICAgICAgIGV4Y2VwdCAoRXhjZXB0aW9uLCBLZXlib2Fy
ZEludGVycnVwdCkgYXMgcm9sbGJhY2tfZXJyb3I6CiAgICAgICAgICAgICAgICAgICAgZmFpbHVy
ZXMuYXBwZW5kKGYie3BhdGh977yae3JvbGxiYWNrX2Vycm9yfSIpCiAgICAgICAgICAgIGZvciBr
ZXkgaW4gcmV2ZXJzZWQoYXR0ZW1wdGVkKToKICAgICAgICAgICAgICAgIHRyeToKICAgICAgICAg
ICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgICAgIGN1cnJlbnQgPSBzZWxmLl9y
dW50aW1lX3ZhbHVlKGtleSkKICAgICAgICAgICAgICAgICAgICBleGNlcHQgVHVuZUVycm9yOgog
ICAgICAgICAgICAgICAgICAgICAgICBjdXJyZW50ID0gTm9uZQogICAgICAgICAgICAgICAgICAg
IGlmIGN1cnJlbnQgIT0gYmVmb3JlW2tleV06CiAgICAgICAgICAgICAgICAgICAgICAgIHNlbGYu
X3dyaXRlX3ZhbHVlKGtleSwgYmVmb3JlW2tleV0pCiAgICAgICAgICAgICAgICBleGNlcHQgKEV4
Y2VwdGlvbiwgS2V5Ym9hcmRJbnRlcnJ1cHQpIGFzIHJvbGxiYWNrX2Vycm9yOgogICAgICAgICAg
ICAgICAgICAgIGZhaWx1cmVzLmFwcGVuZChmIntrZXl977yae3JvbGxiYWNrX2Vycm9yfSIpCiAg
ICAgICAgICAgIGlmIGZhaWx1cmVzOgogICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKGYi
VENQIOe8k+WGsuWMuuaTjeS9nOWksei0peS4lOWbnua7muS4jeWujOaVtO+8iHtlcnJvcn3vvInv
vJp7J++8mycuam9pbihmYWlsdXJlcyl9IiwgMzApIGZyb20gZXJyb3IKICAgICAgICAgICAgcmFp
c2UKCiAgICBkZWYgX2NvbmZpcm0oc2VsZiwgYWN0aW9uLCBiZWZvcmUsIHZhbHVlcywgc3RhdGVf
c25hcHNob3QsIGNvbmZpZ19zbmFwc2hvdCk6CiAgICAgICAgc2VsZi5jdHgucmVxdWlyZV9tdXRh
dGlvbigpCiAgICAgICAgY2hhbmdlcyA9ICJcbiIuam9pbihmIiAge2tleX0gPSB7YmVmb3JlW2tl
eV19IOKGkiB7dmFsdWV9IiBmb3Iga2V5LCB2YWx1ZSBpbiBzb3J0ZWQodmFsdWVzLml0ZW1zKCkp
KQogICAgICAgIHNlbGYuY3R4LmNvbmZpcm0oZiJ7YWN0aW9ufSBUQ1Ag57yT5Yay5Yy65Y+C5pWw
XG57Y2hhbmdlc31cbumFjee9ruaWh+S7tiB7X0ZSQUdNRU5UfSIpCiAgICAgICAgaWYgKHNlbGYu
Y3R4LnNuYXBzaG90X2ZpbGUoc2VsZi5zdGF0ZV9maWxlKSAhPSBzdGF0ZV9zbmFwc2hvdCBvcgog
ICAgICAgICAgICAgICAgc2VsZi5jdHguc25hcHNob3RfZmlsZShzZWxmLmNvbmZpZ19maWxlKSAh
PSBjb25maWdfc25hcHNob3Qgb3IKICAgICAgICAgICAgICAgIGFueShzZWxmLl9ydW50aW1lX3Zh
bHVlKGtleSkgIT0gdmFsdWUgZm9yIGtleSwgdmFsdWUgaW4gYmVmb3JlLml0ZW1zKCkpKToKICAg
ICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCJUQ1Ag57yT5Yay5Yy66YWN572u5oiW5b2T5YmN5YC8
5Zyo56Gu6K6k5pyf6Ze05pS55Y+Y77yM6K+36YeN5paw6L+Q6KGMIikKCiAgICBkZWYgc2V0KHNl
bGYsIGFyZ3MpOgogICAgICAgIHN5bmMgPSBnZXRhdHRyKGFyZ3MsICJzeW5jX2NvcmUiLCBGYWxz
ZSkKICAgICAgICByZWNvbW1lbmRlZCA9IGdldGF0dHIoYXJncywgInJlY29tbWVuZGVkIiwgRmFs
c2UpCiAgICAgICAgbWFudWFsX2ZsYWdzID0gKGYie2RpcmVjdGlvbn1fe2tpbmR9IiBmb3IgZGly
ZWN0aW9uIGluIF9ESVJFQ1RJT05TIGZvciBraW5kIGluICgibWF4IiwgInRyaXBsZXQiKSkKICAg
ICAgICBtYW51YWwgPSBnZXRhdHRyKGFyZ3MsICJzZXR0aW5ncyIsIE5vbmUpIG9yIGFueShnZXRh
dHRyKGFyZ3MsIGZsYWcsIE5vbmUpIGlzIG5vdCBOb25lIGZvciBmbGFnIGluIG1hbnVhbF9mbGFn
cykKICAgICAgICBlc3RpbWF0ZV9mbGFncyA9ICgicnR0X21zIiwgInR4X21icHMiLCAicnhfbWJw
cyIpCiAgICAgICAgaWYgcmVjb21tZW5kZWQgYW5kIG1hbnVhbDoKICAgICAgICAgICAgcmFpc2Ug
VHVuZUVycm9yKCItLXJlY29tbWVuZGVkIOWSjOaJi+WKqOWPguaVsOWPquiDveS9v+eUqOS4gOen
jSIsIDIpCiAgICAgICAgaWYgbm90IHJlY29tbWVuZGVkIGFuZCBhbnkoZ2V0YXR0cihhcmdzLCBm
bGFnLCBOb25lKSBpcyBub3QgTm9uZSBmb3IgZmxhZyBpbiBlc3RpbWF0ZV9mbGFncyk6CiAgICAg
ICAgICAgIHJhaXNlIFR1bmVFcnJvcigiLS1ydHQtbXPjgIEtLXR4LW1icHMg5ZKMIC0tcngtbWJw
cyDpnIDopoHkuI4gLS1yZWNvbW1lbmRlZCDkuIDotbfkvb/nlKgiLCAyKQogICAgICAgIGVzdGlt
YXRlID0gTm9uZQogICAgICAgIHNlbGYuY3R4LnJlcXVpcmVfdG9vbHMoInN5c2N0bCIpCiAgICAg
ICAgaWYgcmVjb21tZW5kZWQ6CiAgICAgICAgICAgIGVzdGltYXRlID0gc2VsZi5lc3RpbWF0ZShh
cmdzKQogICAgICAgICAgICB1cGRhdGVzLCBiZWZvcmUgPSB7fSwge30KICAgICAgICAgICAgZm9y
IGRpcmVjdGlvbiwgKHRjcCwgY29yZSkgaW4gX0RJUkVDVElPTlMuaXRlbXMoKToKICAgICAgICAg
ICAgICAgIHBsYW4gPSBlc3RpbWF0ZS5nZXQoZGlyZWN0aW9uLCB7fSkKICAgICAgICAgICAgICAg
IGlmIHBsYW4uZ2V0KCJzdWdnZXN0ZWRfdHJpcGxldCIpIGlzIG5vdCBOb25lOgogICAgICAgICAg
ICAgICAgICAgIHVwZGF0ZXNbdGNwXSA9IF9pbnRlZ2VycyhwbGFuWyJzdWdnZXN0ZWRfdHJpcGxl
dCJdKQogICAgICAgICAgICAgICAgICAgIGJlZm9yZVt0Y3BdID0gX2ludGVnZXJzKHBsYW5bImN1
cnJlbnRfdHJpcGxldCJdKQogICAgICAgICAgICAgICAgICAgIGlmIHN5bmM6CiAgICAgICAgICAg
ICAgICAgICAgICAgIHVwZGF0ZXNbY29yZV0gPSBzdHIocGxhblsic3VnZ2VzdGVkX21heF9ieXRl
cyJdKQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHVwZGF0ZXMsIGJlZm9yZSA9IHNlbGYuX21h
bnVhbF92YWx1ZXMoYXJncywgc3luYykKICAgICAgICByZXN1bHQgPSB7ImNoYW5nZWQiOiBGYWxz
ZSwgIndvdWxkX2NoYW5nZSI6IEZhbHNlLCAiZHJ5X3J1biI6IHNlbGYuY3R4LmRyeV9ydW4sICJ2
YWx1ZXMiOiB1cGRhdGVzfQogICAgICAgIGlmIGVzdGltYXRlIGlzIG5vdCBOb25lOgogICAgICAg
ICAgICByZXN1bHRbImVzdGltYXRlIl0gPSBlc3RpbWF0ZQogICAgICAgIGlmIG5vdCB1cGRhdGVz
OgogICAgICAgICAgICByZXR1cm4geyoqcmVzdWx0LCAibWVzc2FnZSI6ICLmiYDpgInmlrnlkJHm
sqHmnInlj6/lupTnlKjnmoQgVENQIOe8k+WGsuWMuuW7uuiuriJ9CgogICAgICAgIG9sZF9zdGF0
ZSwgc3RhdGVfc25hcHNob3QsIGNvbmZpZ19zbmFwc2hvdCwgb3duZWQgPSBzZWxmLl9leGlzdGlu
ZygpCiAgICAgICAgZGVzaXJlZCA9IHsqKihvbGRfc3RhdGVbImRlc2lyZWQiXSBpZiBvbGRfc3Rh
dGUgZWxzZSB7fSksICoqdXBkYXRlc30KICAgICAgICBvcmlnaW5hbCA9IGRpY3Qob2xkX3N0YXRl
WyJvcmlnaW5hbCJdKSBpZiBvbGRfc3RhdGUgZWxzZSB7fQogICAgICAgIGZvciBrZXkgaW4gdXBk
YXRlczoKICAgICAgICAgICAgaWYga2V5IG5vdCBpbiBiZWZvcmU6CiAgICAgICAgICAgICAgICBi
ZWZvcmVba2V5XSA9IHNlbGYuX3J1bnRpbWVfdmFsdWUoa2V5KQogICAgICAgICAgICBvcmlnaW5h
bC5zZXRkZWZhdWx0KGtleSwgYmVmb3JlW2tleV0pCiAgICAgICAgc3RhdGUgPSB7InNjaGVtYV92
ZXJzaW9uIjogU0NIRU1BX1ZFUlNJT04sICJkZXNpcmVkIjogZGVzaXJlZCwgIm9yaWdpbmFsIjog
b3JpZ2luYWx9CiAgICAgICAgY3JlYXRpbmcgPSBub3QgY29uZmlnX3NuYXBzaG90WyJleGlzdHMi
XQogICAgICAgIHNlbGYuX3ZlcmlmeV9wZXJzaXN0ZW5jZShkZXNpcmVkLCB1cGRhdGVzLCBjcmVh
dGluZz1jcmVhdGluZykKICAgICAgICBpZiBvd25lZCBhbmQgc3RhdGUgPT0gb2xkX3N0YXRlIGFu
ZCBiZWZvcmUgPT0gdXBkYXRlczoKICAgICAgICAgICAgcmV0dXJuIHsqKnJlc3VsdCwgIm1lc3Nh
Z2UiOiAiVENQIOe8k+WGsuWMuuWPguaVsOW3sueUn+aViCJ9CiAgICAgICAgaWYgc2VsZi5jdHgu
ZHJ5X3J1bjoKICAgICAgICAgICAgcmV0dXJuIHsqKnJlc3VsdCwgIndvdWxkX2NoYW5nZSI6IFRy
dWUsICJtZXNzYWdlIjogIuiuoeWIkuiuvue9riBUQ1Ag57yT5Yay5Yy65Y+C5pWwIn0KICAgICAg
ICBzZWxmLl9jb25maXJtKCLorr7nva4iLCBiZWZvcmUsIHVwZGF0ZXMsIHN0YXRlX3NuYXBzaG90
LCBjb25maWdfc25hcHNob3QpCiAgICAgICAgc2VsZi5fdmVyaWZ5X3BlcnNpc3RlbmNlKGRlc2ly
ZWQsIHVwZGF0ZXMsIGNyZWF0aW5nPWNyZWF0aW5nKQogICAgICAgIHNlbGYuX2FwcGx5KGJlZm9y
ZSwgdXBkYXRlcywgc3RhdGUsIHN0YXRlX3NuYXBzaG90LCBjb25maWdfc25hcHNob3QpCiAgICAg
ICAgcmV0dXJuIHsqKnJlc3VsdCwgImNoYW5nZWQiOiBUcnVlLCAibWVzc2FnZSI6ICLlt7Lorr7n
va4gVENQIOe8k+WGsuWMuuWPguaVsCJ9CgogICAgZGVmIHJlc3RvcmUoc2VsZiwgYXJncyk6CiAg
ICAgICAgc3RhdGUsIHN0YXRlX3NuYXBzaG90LCBjb25maWdfc25hcHNob3QsIF8gPSBzZWxmLl9l
eGlzdGluZygpCiAgICAgICAgcmVzdWx0ID0geyJjaGFuZ2VkIjogRmFsc2UsICJ3b3VsZF9jaGFu
Z2UiOiBGYWxzZSwgImRyeV9ydW4iOiBzZWxmLmN0eC5kcnlfcnVuLCAidmFsdWVzIjoge319CiAg
ICAgICAgaWYgc3RhdGUgaXMgTm9uZToKICAgICAgICAgICAgcmV0dXJuIHsqKnJlc3VsdCwgIm1l
c3NhZ2UiOiAi5rKh5pyJ6ZyA6KaB6L+Y5Y6f55qEIFRDUCDnvJPlhrLljLrlj4LmlbAifQogICAg
ICAgIHNlbGYuY3R4LnJlcXVpcmVfdG9vbHMoInN5c2N0bCIpCiAgICAgICAgdmFsdWVzLCBzb3Vy
Y2VzID0gc2VsZi5fcmVzdG9yZV92YWx1ZXMoc3RhdGVbIm9yaWdpbmFsIl0pCiAgICAgICAgYmVm
b3JlID0ge2tleTogc2VsZi5fcnVudGltZV92YWx1ZShrZXkpIGZvciBrZXkgaW4gdmFsdWVzfQog
ICAgICAgIHJlc3VsdC51cGRhdGUodmFsdWVzPXZhbHVlcywgc291cmNlcz1zb3VyY2VzKQogICAg
ICAgIGlmIHNlbGYuY3R4LmRyeV9ydW46CiAgICAgICAgICAgIHJldHVybiB7KipyZXN1bHQsICJ3
b3VsZF9jaGFuZ2UiOiBUcnVlLCAibWVzc2FnZSI6ICLorqHliJLov5jljp8gVENQIOe8k+WGsuWM
uuWPguaVsCJ9CiAgICAgICAgc2VsZi5fY29uZmlybSgi6L+Y5Y6fIiwgYmVmb3JlLCB2YWx1ZXMs
IHN0YXRlX3NuYXBzaG90LCBjb25maWdfc25hcHNob3QpCiAgICAgICAgaWYgc2VsZi5fcmVzdG9y
ZV92YWx1ZXMoc3RhdGVbIm9yaWdpbmFsIl0pICE9ICh2YWx1ZXMsIHNvdXJjZXMpOgogICAgICAg
ICAgICByYWlzZSBUdW5lRXJyb3IoIuWklumDqCBUQ1Ag57yT5Yay5Yy66YWN572u5Zyo56Gu6K6k
5pyf6Ze05pS55Y+Y77yM6K+36YeN5paw6L+Q6KGMIikKICAgICAgICBzZWxmLl9hcHBseShiZWZv
cmUsIHZhbHVlcywgTm9uZSwgc3RhdGVfc25hcHNob3QsIGNvbmZpZ19zbmFwc2hvdCkKICAgICAg
ICByZXR1cm4geyoqcmVzdWx0LCAiY2hhbmdlZCI6IFRydWUsICJtZXNzYWdlIjogIuW3sui/mOWO
nyBUQ1Ag57yT5Yay5Yy65Y+C5pWwIn0KCiAgICBkZWYgc3RhdHVzKHNlbGYpOgogICAgICAgIHNl
bGYuY3R4LnJlcXVpcmVfdG9vbHMoInN5c2N0bCIpCiAgICAgICAgc3RhdGUsIF8sIGNvbmZpZ19z
bmFwc2hvdCwgb3duZWQgPSBzZWxmLl9leGlzdGluZyhyZXF1aXJlX293bmVkPUZhbHNlKQogICAg
ICAgIGRlc2lyZWQgPSBzdGF0ZVsiZGVzaXJlZCJdIGlmIHN0YXRlIGVsc2Uge30KICAgICAgICBk
cmlmdCA9IGJvb2woKHN0YXRlIG9yIGNvbmZpZ19zbmFwc2hvdFsiZXhpc3RzIl0pIGFuZCBub3Qg
b3duZWQpCiAgICAgICAga2V5cyA9IHt9CiAgICAgICAgZm9yIGtleSwgc291cmNlcyBpbiBzb3J0
ZWQoc2VsZi5fY29uZmlnX2Fzc2lnbm1lbnRzKF9LRVlTKS5pdGVtcygpKToKICAgICAgICAgICAg
aXRlbSA9IHsicnVudGltZSI6IE5vbmUsICJkZXNpcmVkIjogZGVzaXJlZC5nZXQoa2V5KSwgInBl
cnNpc3RlbnQiOiBOb25lLCAic291cmNlcyI6IHNvdXJjZXN9CiAgICAgICAgICAgIHRyeToKICAg
ICAgICAgICAgICAgIGl0ZW1bInJ1bnRpbWUiXSA9IHNlbGYuX3J1bnRpbWVfdmFsdWUoa2V5KQog
ICAgICAgICAgICBleGNlcHQgVHVuZUVycm9yIGFzIGVycm9yOgogICAgICAgICAgICAgICAgaXRl
bVsiZXJyb3IiXSA9IHN0cihlcnJvcikKICAgICAgICAgICAgZWZmZWN0aXZlID0gX2VmZmVjdGl2
ZV9zb3VyY2Uoa2V5LCBzb3VyY2VzKQogICAgICAgICAgICBpZiBlZmZlY3RpdmUgYW5kIGVmZmVj
dGl2ZVsidmFsdWUiXSBpcyBub3QgTm9uZToKICAgICAgICAgICAgICAgIGl0ZW1bInNvdXJjZSJd
ID0gZWZmZWN0aXZlWyJmaWxlIl0KICAgICAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAg
ICAgICBpdGVtWyJwZXJzaXN0ZW50Il0gPSBfbnVtZXJpY192YWx1ZShrZXksIGVmZmVjdGl2ZVsi
dmFsdWUiXSkKICAgICAgICAgICAgICAgIGV4Y2VwdCBWYWx1ZUVycm9yOgogICAgICAgICAgICAg
ICAgICAgIGl0ZW1bInBlcnNpc3RlbnQiXSA9IGVmZmVjdGl2ZVsidmFsdWUiXQogICAgICAgICAg
ICAgICAgICAgIGl0ZW1bInBlcnNpc3RlbnRfZXJyb3IiXSA9ICLphY3nva7kuK3nmoTlj4LmlbDl
gLzml6DmlYgiCiAgICAgICAgICAgIGlmIGtleSBpbiBkZXNpcmVkIGFuZCAoaXRlbVsicnVudGlt
ZSJdICE9IGRlc2lyZWRba2V5XSBvciBpdGVtWyJwZXJzaXN0ZW50Il0gIT0gZGVzaXJlZFtrZXld
KToKICAgICAgICAgICAgICAgIGRyaWZ0ID0gVHJ1ZQogICAgICAgICAgICBrZXlzW2tleV0gPSBp
dGVtCiAgICAgICAgcmV0dXJuIHsibWFuYWdlZCI6IHN0YXRlIGlzIG5vdCBOb25lLCAiY29uZmln
X3BhdGgiOiBfRlJBR01FTlQsICJrZXlzIjoga2V5cywgImRyaWZ0IjogZHJpZnQsCiAgICAgICAg
ICAgICAgICAibWVzc2FnZSI6ICJUQ1Ag57yT5Yay5Yy654q25oCBIn0KUEsDBBQAAAAAAAAAIVAr
Zxzg2ncAANp3AAATAAAAbmV0d29ya190dW5lL2NsaS5weSIiIlVzZXIgaW50ZXJmYWNlcyBhbmQg
cGFzc2l2ZSBkaWFnbm9zdGljcyBmb3IgbmV0d29yayB0dW5pbmcuIiIiCmZyb20gX19mdXR1cmVf
XyBpbXBvcnQgYW5ub3RhdGlvbnMKCmltcG9ydCBhcmdwYXJzZQppbXBvcnQgY29udGV4dGxpYgpp
bXBvcnQgZGF0ZXRpbWUKaW1wb3J0IGpzb24KaW1wb3J0IG9zCmZyb20gcGF0aGxpYiBpbXBvcnQg
UGF0aAppbXBvcnQgcmUKaW1wb3J0IHNpZ25hbAppbXBvcnQgc3VicHJvY2VzcwppbXBvcnQgc3lz
CmltcG9ydCB0aW1lCgpmcm9tIC5jb21tb24gaW1wb3J0IENvbnRleHQsIFR1bmVFcnJvciwgcmVh
ZF9zeXNjdGwsIHZhbGlkX2ludGVyZmFjZQpmcm9tIC5idWZmZXJzIGltcG9ydCBCdWZmZXJNYW5h
Z2VyCmZyb20gLmVncmVzcyBpbXBvcnQgRWdyZXNzTWFuYWdlcgpmcm9tIC5wb3J0cyBpbXBvcnQg
UG9ydE1hbmFnZXIKCgpjbGFzcyBUdW5lUGFyc2VyKGFyZ3BhcnNlLkFyZ3VtZW50UGFyc2VyKToK
ICAgIGRlZiBfX2luaXRfXyhzZWxmLCAqYXJncywgKiprd2FyZ3MpOgogICAgICAgIGt3YXJncy5z
ZXRkZWZhdWx0KCJhbGxvd19hYmJyZXYiLCBGYWxzZSkKICAgICAgICBzdXBlcigpLl9faW5pdF9f
KCphcmdzLCAqKmt3YXJncykKCgpkZWYgZ2xvYmFsc19mb3IocGFyc2VyKToKICAgIGZvciBmbGFn
IGluICgiZHJ5LXJ1biIsICJ5ZXMiLCAibm9uLWludGVyYWN0aXZlIiwgImluc3RhbGwtZGVwcyIs
ICJxdWlldCIsICJ2ZXJib3NlIiwgIm5vLWNvbG9yIiwgImpzb24iKToKICAgICAgICBwYXJzZXIu
YWRkX2FyZ3VtZW50KCItLSIgKyBmbGFnLCBhY3Rpb249InN0b3JlX3RydWUiLCBkZWZhdWx0PWFy
Z3BhcnNlLlNVUFBSRVNTKQogICAgcmV0dXJuIHBhcnNlcgoKCmRlZiBwYXJzZXIoKToKICAgIHJv
b3QgPSBnbG9iYWxzX2ZvcihUdW5lUGFyc2VyKAogICAgICAgIHByb2c9Im5ldHdvcmsgdHVuZSIs
IGRlc2NyaXB0aW9uPSLnrqHnkIYgVENQIOe8k+WGsuWMuuOAgee9keWNoeWHuuWPo+aVtOW9ouWS
jOi/lOWbnuWuouaIt+err+eahOerr+WPo+mZkOmAn++8m+S4jeiHquWKqOa1i+mAn+aIluS/ruaU
ueS7o+eQhuiKgueCueOAgiIpKQogICAgZ3JvdXBzID0gcm9vdC5hZGRfc3VicGFyc2VycyhkZXN0
PSJncm91cCIsIG1ldGF2YXI9IntzdGF0dXMsZGlhZ25vc2UsYnVmZmVyLGVncmVzcyxwb3J0fSIp
CiAgICBmb3IgY29tbWFuZCwgdGV4dCBpbiAoKCJzdGF0dXMiLCAi5p+l55yL6YWN572u44CB5a6e
6ZmF6Zif5YiX5ZKM5oyB5LmF5YyW5p2l5rqQIiksICgiZGlhZ25vc2UiLCAi6KKr5Yqo6KeC5a+f
6LWE5rqQ5ZKM5Lii5YyF5aKe6YeP77yM5LiN5Lqn55Sf5rWL6K+V5rWB6YePIikpOgogICAgICAg
IGFjdGlvbiA9IGdsb2JhbHNfZm9yKGdyb3Vwcy5hZGRfcGFyc2VyKGNvbW1hbmQsIGhlbHA9dGV4
dCkpCiAgICAgICAgYWN0aW9uLmFkZF9hcmd1bWVudCgiLS1pbnRlcmZhY2UiKQogICAgICAgIGlm
IGNvbW1hbmQgPT0gImRpYWdub3NlIjoKICAgICAgICAgICAgYWN0aW9uLmFkZF9hcmd1bWVudCgi
LS1zZWNvbmRzIiwgdHlwZT1pbnQsIGRlZmF1bHQ9MTApCiAgICBidWZmZXJzID0gZ2xvYmFsc19m
b3IoZ3JvdXBzLmFkZF9wYXJzZXIoImJ1ZmZlciIsIGhlbHA9IlRDUCDnvJPlhrLljLrkvLDnrpfj
gIHorr7nva7lkozmgaLlpI0iKSkKICAgIGFjdGlvbnMgPSBidWZmZXJzLmFkZF9zdWJwYXJzZXJz
KGRlc3Q9ImFjdGlvbiIsIHJlcXVpcmVkPVRydWUpCiAgICBlc3RpbWF0ZSA9IGdsb2JhbHNfZm9y
KGFjdGlvbnMuYWRkX3BhcnNlcigiZXN0aW1hdGUiLCBoZWxwPSLmoLnmja7nnJ/lrp4gUlRU44CB
55uu5qCH5bim5a695ZKM54mp55CG5YaF5a2Y6K6h566X5bu66K6uIikpCiAgICBmb3Igb3B0aW9u
IGluICgicnR0LW1zIiwgInR4LW1icHMiLCAicngtbWJwcyIpOgogICAgICAgIGVzdGltYXRlLmFk
ZF9hcmd1bWVudCgiLS0iICsgb3B0aW9uKQogICAgY2hhbmdlID0gZ2xvYmFsc19mb3IoYWN0aW9u
cy5hZGRfcGFyc2VyKCJzZXQiLCBoZWxwPSLorr7nva7mjqjojZDmiJbmiYvliqjnvJPlhrLljLoi
KSkKICAgIGZvciBvcHRpb24gaW4gKCJydHQtbXMiLCAidHgtbWJwcyIsICJyeC1tYnBzIiwgInR4
LW1heCIsICJyeC1tYXgiLCAidHgtdHJpcGxldCIsICJyeC10cmlwbGV0Iik6CiAgICAgICAgY2hh
bmdlLmFkZF9hcmd1bWVudCgiLS0iICsgb3B0aW9uKQogICAgY2hhbmdlLmFkZF9hcmd1bWVudCgi
LS1yZWNvbW1lbmRlZCIsIGFjdGlvbj0ic3RvcmVfdHJ1ZSIpCiAgICBjaGFuZ2UuYWRkX2FyZ3Vt
ZW50KCItLXN5bmMtY29yZSIsIGFjdGlvbj0ic3RvcmVfdHJ1ZSIsIGhlbHA9IuaYjuehruWQjOat
peaJgOmAieaWueWQkeeahCBuZXQuY29yZS4qbWVtX21heCIpCiAgICBjaGFuZ2UuYWRkX2FyZ3Vt
ZW50KCItLXNldCIsIGRlc3Q9InNldHRpbmdzIiwgYWN0aW9uPSJhcHBlbmQiLCBkZWZhdWx0PVtd
LCBtZXRhdmFyPSJLRVk9VkFMVUUiKQogICAgZ2xvYmFsc19mb3IoYWN0aW9ucy5hZGRfcGFyc2Vy
KCJyZXN0b3JlIiwgaGVscD0i56e76Zmk5Y+X566h6KaG55uW5bm25oGi5aSN5aSW6YOo5pyJ5pWI
6YWN572u5oiW5Y6f5YC8IikpCiAgICBlZ3Jlc3MgPSBnbG9iYWxzX2Zvcihncm91cHMuYWRkX3Bh
cnNlcigiZWdyZXNzIiwgaGVscD0i572R5Y2h5Ye65Y+j6Zif5YiXIikpCiAgICBhY3Rpb25zID0g
ZWdyZXNzLmFkZF9zdWJwYXJzZXJzKGRlc3Q9ImFjdGlvbiIsIHJlcXVpcmVkPVRydWUpCiAgICBm
b3IgY29tbWFuZCBpbiAoInNldCIsICJjbGVhciIsICJyZXN0b3JlIiwgImFkb3B0Iik6CiAgICAg
ICAgYWN0aW9uID0gZ2xvYmFsc19mb3IoYWN0aW9ucy5hZGRfcGFyc2VyKGNvbW1hbmQpKQogICAg
ICAgIGFjdGlvbi5hZGRfYXJndW1lbnQoIi0taW50ZXJmYWNlIiwgaGVscD0i55yB55Wl5pe25LuF
5Zyo6buY6K6k572R5Y2h5ZSv5LiA5pe26Ieq5Yqo6YCJ5oupIikKICAgICAgICBpZiBjb21tYW5k
ID09ICJzZXQiOgogICAgICAgICAgICBhY3Rpb24uYWRkX2FyZ3VtZW50KCItLW1vZGUiLCByZXF1
aXJlZD1UcnVlLCBjaG9pY2VzPSgidGJmIiwgInRiZi1mcSIsICJmcSIpKQogICAgICAgICAgICBm
b3Igb3B0aW9uIGluICgicmF0ZS1tYnBzIiwgIm1heHJhdGUtbWJwcyIsICJidXJzdC1raWIiLCAi
bGF0ZW5jeS1tcyIsICJxdWV1ZS1wYWNrZXRzIiwgImZsb3ctbGltaXQiKToKICAgICAgICAgICAg
ICAgIGFjdGlvbi5hZGRfYXJndW1lbnQoIi0tIiArIG9wdGlvbikKICAgICAgICBpZiBjb21tYW5k
ID09ICJhZG9wdCI6CiAgICAgICAgICAgIGFjdGlvbi5hZGRfYXJndW1lbnQoIi0tc2VydmljZSIp
CiAgICBwb3J0cyA9IGdsb2JhbHNfZm9yKGdyb3Vwcy5hZGRfcGFyc2VyKCJwb3J0IiwgaGVscD0i
5oyJ5pyN5Yqh5rqQ56uv5Y+j6ZmQ5Yi26L+U5Zue5a6i5oi356uv55qE5Ye656uZ5rWB6YePIikp
CiAgICBhY3Rpb25zID0gcG9ydHMuYWRkX3N1YnBhcnNlcnMoZGVzdD0iYWN0aW9uIiwgcmVxdWly
ZWQ9VHJ1ZSkKICAgIGdsb2JhbHNfZm9yKGFjdGlvbnMuYWRkX3BhcnNlcigibGlzdCIpKQogICAg
YWN0aW9uID0gZ2xvYmFsc19mb3IoYWN0aW9ucy5hZGRfcGFyc2VyKCJzZXQiKSkKICAgIGFjdGlv
bi5hZGRfYXJndW1lbnQoIi0taWQiLCByZXF1aXJlZD1UcnVlKQogICAgYWN0aW9uLmFkZF9hcmd1
bWVudCgiLS1pbnRlcmZhY2UiKQogICAgYWN0aW9uLmFkZF9hcmd1bWVudCgiLS1wb3J0IiwgcmVx
dWlyZWQ9VHJ1ZSwgdHlwZT1pbnQpCiAgICBhY3Rpb24uYWRkX2FyZ3VtZW50KCItLXByb3RvY29s
IiwgY2hvaWNlcz0oInRjcCIsICJ1ZHAiLCAiYm90aCIpLCBkZWZhdWx0PSJ0Y3AiKQogICAgYWN0
aW9uLmFkZF9hcmd1bWVudCgiLS1mYW1pbHkiLCBjaG9pY2VzPSgiaXB2NCIsICJpcHY2IiwgImJv
dGgiKSwgZGVmYXVsdD0iYm90aCIpCiAgICBmb3Igb3B0aW9uIGluICgidG90YWwtbWJwcyIsICJm
bG93LW1icHMiLCAiYnVyc3Qta2liIiwgImxhdGVuY3ktbXMiLCAicXVldWUtcGFja2V0cyIsICJm
bG93LWxpbWl0Iik6CiAgICAgICAgYWN0aW9uLmFkZF9hcmd1bWVudCgiLS0iICsgb3B0aW9uKQog
ICAgYWN0aW9uID0gZ2xvYmFsc19mb3IoYWN0aW9ucy5hZGRfcGFyc2VyKCJkZWxldGUiKSkKICAg
IGFjdGlvbi5hZGRfYXJndW1lbnQoIi0taWQiLCByZXF1aXJlZD1UcnVlKQogICAgaW50ZXJuYWwg
PSBncm91cHMuYWRkX3BhcnNlcigiaW50ZXJuYWwiLCBoZWxwPWFyZ3BhcnNlLlNVUFBSRVNTKQog
ICAgYWN0aW9ucyA9IGludGVybmFsLmFkZF9zdWJwYXJzZXJzKGRlc3Q9ImFjdGlvbiIsIHJlcXVp
cmVkPVRydWUpCiAgICBhY3Rpb25zLmFkZF9wYXJzZXIoImVncmVzcy1hcHBseSIpLmFkZF9hcmd1
bWVudCgiaW50ZXJmYWNlIikKICAgIGFjdGlvbnMuYWRkX3BhcnNlcigicG9ydHMtYXBwbHkiKS5h
ZGRfYXJndW1lbnQoIi0taW50ZXJmYWNlIikKICAgIGdyb3Vwcy5fY2hvaWNlc19hY3Rpb25zID0g
W2Nob2ljZSBmb3IgY2hvaWNlIGluIGdyb3Vwcy5fY2hvaWNlc19hY3Rpb25zIGlmIGNob2ljZS5k
ZXN0ICE9ICJpbnRlcm5hbCJdCiAgICByZXR1cm4gcm9vdAoKCmRlZiBfc2FmZV9wcm9iZShjYWxs
KToKICAgIHRyeToKICAgICAgICByZXR1cm4gY2FsbCgpCiAgICBleGNlcHQgKFR1bmVFcnJvciwg
T1NFcnJvciwgVmFsdWVFcnJvcikgYXMgZXJyb3I6CiAgICAgICAgcmV0dXJuIHsidW5hdmFpbGFi
bGUiOiBzdHIoZXJyb3IpLCAiY29kZSI6IGdldGF0dHIoZXJyb3IsICJjb2RlIiwgMyl9CgoKZGVm
IF9qc29uX2NvbW1hbmQoY3R4LCBhcmdzKToKICAgIHJlc3VsdCA9IGN0eC5ydW4oYXJncykKICAg
IHRyeToKICAgICAgICByZXR1cm4ganNvbi5sb2FkcyhyZXN1bHQuc3Rkb3V0KQogICAgZXhjZXB0
IFZhbHVlRXJyb3I6CiAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLns7vnu5/lkb3ku6TmnKrov5Tl
m57mnInmlYggSlNPTu+8miIgKyBhcmdzWzBdLCAzKQoKCmRlZiBfaW50ZXJmYWNlKGN0eCwgdmFs
dWU9Tm9uZSk6CiAgICBpZiB2YWx1ZToKICAgICAgICB2YWxpZF9pbnRlcmZhY2UodmFsdWUpCiAg
ICAgICAgY3R4LnJ1bihbImlwIiwgImxpbmsiLCAic2hvdyIsICJkZXYiLCB2YWx1ZV0pCiAgICAg
ICAgcmV0dXJuIHZhbHVlCiAgICBkZXZpY2VzID0gc2V0KCkKICAgIGZvciBmYW1pbHkgaW4gKCIt
NCIsICItNiIpOgogICAgICAgIHJvdXRlcyA9IF9qc29uX2NvbW1hbmQoY3R4LCBbImlwIiwgIi1q
IiwgZmFtaWx5LCAicm91dGUiLCAic2hvdyIsICJkZWZhdWx0Il0pCiAgICAgICAgZGV2aWNlcy51
cGRhdGUocm93WyJkZXYiXSBmb3Igcm93IGluIHJvdXRlcyBpZiByb3cuZ2V0KCJkZXYiKSkKICAg
IGlmIGxlbihkZXZpY2VzKSAhPSAxOgogICAgICAgIHJhaXNlIFR1bmVFcnJvcigi6buY6K6k5Ye6
5Y+j572R5Y2h5LiN5ZSv5LiA5oiW5LiN5a2Y5Zyo77yM6K+35piO56Gu5o+Q5L6bIC0taW50ZXJm
YWNlIiwgMikKICAgIHJldHVybiB2YWxpZF9pbnRlcmZhY2UobmV4dChpdGVyKGRldmljZXMpKSkK
CgpkZWYgX2tlcm5lbChjdHgpOgogICAgcmVzdWx0ID0geyJyZWxlYXNlIjogb3MudW5hbWUoKS5y
ZWxlYXNlLCAic3lzdGVtZCI6IGN0eC5wYXRoKCIvcnVuL3N5c3RlbWQvc3lzdGVtIikuaXNfZGly
KCl9CiAgICBmb3IgbmFtZSBpbiAoInRjcF9jb25nZXN0aW9uX2NvbnRyb2wiLCAidGNwX2F2YWls
YWJsZV9jb25nZXN0aW9uX2NvbnRyb2wiLCAidGNwX3NhY2siLCAidGNwX3RpbWVzdGFtcHMiLCAi
dGNwX3dpbmRvd19zY2FsaW5nIik6CiAgICAgICAgcmVzdWx0W25hbWVdID0gX3NhZmVfcHJvYmUo
bGFtYmRhIG5hbWU9bmFtZTogcmVhZF9zeXNjdGwoY3R4LCAibmV0LmlwdjQuIiArIG5hbWUpKQog
ICAgcmVzdWx0WyJkZWZhdWx0X3FkaXNjIl0gPSBfc2FmZV9wcm9iZShsYW1iZGE6IHJlYWRfc3lz
Y3RsKGN0eCwgIm5ldC5jb3JlLmRlZmF1bHRfcWRpc2MiKSkKICAgIG1vZHVsZSA9IF9zYWZlX3By
b2JlKGxhbWJkYTogY3R4LnJ1bihbIm1vZGluZm8iLCAiLUYiLCAidmVyc2lvbiIsICJ0Y3BfYmJy
Il0pLnN0ZG91dC5zdHJpcCgpKQogICAgcmVzdWx0WyJiYnJfbW9kdWxlX3ZlcnNpb24iXSA9IG1v
ZHVsZSBpZiBpc2luc3RhbmNlKG1vZHVsZSwgc3RyKSBhbmQgbW9kdWxlIGVsc2UgIuacquaatOmc
si/mnKrnn6UiCiAgICByZXR1cm4gcmVzdWx0CgoKZGVmIF9wdWJsaWNfZWdyZXNzKGRhdGEpOgog
ICAgaWYgImludGVyZmFjZXMiIG5vdCBpbiBkYXRhOgogICAgICAgIHJldHVybiBkYXRhCiAgICBj
bGVhbmVkID0geyJpbnRlcmZhY2VzIjoge319CiAgICBmb3IgbmFtZSwgaXRlbSBpbiBkYXRhWyJp
bnRlcmZhY2VzIl0uaXRlbXMoKToKICAgICAgICByZWNvcmQgPSBpdGVtLmdldCgicmVjb3JkIikg
b3Ige30KICAgICAgICBzZXJ2aWNlID0gaXRlbS5nZXQoInNlcnZpY2UiKSBvciB7fQogICAgICAg
IGNsZWFuZWRbImludGVyZmFjZXMiXVtuYW1lXSA9IHsKICAgICAgICAgICAgIm1hbmFnZWQiOiBp
dGVtLmdldCgibWFuYWdlZCIsIEZhbHNlKSwgImVuYWJsZWQiOiByZWNvcmQuZ2V0KCJlbmFibGVk
IiwgRmFsc2UpLAogICAgICAgICAgICAicHJvZmlsZSI6IHJlY29yZC5nZXQoInByb2ZpbGUiKSwg
Im1hdGNoZXMiOiBpdGVtLmdldCgibWF0Y2hlcyIpLAogICAgICAgICAgICAidHJlZSI6IGl0ZW0u
Z2V0KCJ0cmVlIiwgW10pLAogICAgICAgICAgICAic2VydmljZSI6IHtrZXk6IHZhbHVlIGZvciBr
ZXksIHZhbHVlIGluIHNlcnZpY2UuaXRlbXMoKSBpZiBrZXkgIT0gImZpbGUifSwKICAgICAgICB9
CiAgICByZXR1cm4gY2xlYW5lZAoKCmRlZiBzdGF0dXMoY3R4LCBpbnRlcmZhY2U9Tm9uZSk6CiAg
ICBpZiBpbnRlcmZhY2U6CiAgICAgICAgdmFsaWRfaW50ZXJmYWNlKGludGVyZmFjZSkKICAgIGlu
dGVyZmFjZXMgPSBfc2FmZV9wcm9iZShsYW1iZGE6IF9qc29uX2NvbW1hbmQoY3R4LCBbImlwIiwg
Ii1qIiwgImxpbmsiLCAic2hvdyJdKSkKICAgIHNoYXBlZCA9IF9zYWZlX3Byb2JlKGxhbWJkYTog
RWdyZXNzTWFuYWdlcihjdHgpLnN0YXR1cyhpbnRlcmZhY2UpKQogICAgaWYgaXNpbnN0YW5jZShz
aGFwZWQsIGRpY3QpOgogICAgICAgIHNoYXBlZCA9IF9wdWJsaWNfZWdyZXNzKHNoYXBlZCkKICAg
IHJldHVybiB7InRpbWVfdXRjIjogZGF0ZXRpbWUuZGF0ZXRpbWUubm93KGRhdGV0aW1lLnRpbWV6
b25lLnV0YykuaXNvZm9ybWF0KCksCiAgICAgICAgICAgICJrZXJuZWwiOiBfa2VybmVsKGN0eCks
ICJsaW5rcyI6IGludGVyZmFjZXMsCiAgICAgICAgICAgICJidWZmZXJzIjogX3NhZmVfcHJvYmUo
bGFtYmRhOiBCdWZmZXJNYW5hZ2VyKGN0eCkuc3RhdHVzKCkpLAogICAgICAgICAgICAiZWdyZXNz
Ijogc2hhcGVkLCAicG9ydHMiOiBfc2FmZV9wcm9iZShsYW1iZGE6IFBvcnRNYW5hZ2VyKGN0eCku
c3RhdHVzKCkpLAogICAgICAgICAgICAibm90ZXMiOiBbCiAgICAgICAgICAgICAgICAiVENQIOWP
guaVsOS9nOeUqOS6juacrOacuue7iOatoueahOi/nuaOpe+8jOS4jeebtOaOpeaUueWPmOe6r+i9
rOWPkei/nuaOpeeahOerr+WIsOerr+eql+WPo+OAgiIsCiAgICAgICAgICAgICAgICAi5pys5py6
5ZCv55SoIFNBQ0sv5pe26Ze05oiz5LiN562J5LqO6ZO+6Lev5bey5Y2P5ZWG5oiQ5Yqf77yM57yT
5a2Y5Lyw566X5LiN6IO95L+u5aSN5o+h5omL5pS55YaZ44CCIiwKICAgICAgICAgICAgICAgICLl
h7rnq5npmZDpgJ/lj6rnuqbmnZ/ov5Tlm57lrqLmiLfnq6/nmoTmnI3liqHnq6/lj6PvvIzkuI3m
mK/lhaXmlrnlkJHpmZDpgJ/jgIIiLAogICAgICAgICAgICAgICAgIumZkOmAn+WAvOaYr+WPkemA
geS4iumZkO+8jOS4jeaYr+WQnuWQkOaIluacgOS9juW4puWuveS/neivge+8m0lGQiDnu5/orqHk
uI3lj6/kuI7niannkIblh7rlj6Pnm7jliqDjgIIiLAogICAgICAgICAgICBdfQoKCmRlZiBfcGFz
c2l2ZV9zbmFwc2hvdChjdHgsIGludGVyZmFjZT1Ob25lKToKICAgIGRlZiBwcm9jKG5hbWUpOgog
ICAgICAgIHRyeToKICAgICAgICAgICAgcmV0dXJuIGN0eC5wYXRoKG5hbWUpLnJlYWRfdGV4dCgp
CiAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgIHJldHVybiAiIgogICAgcWRpc2Nf
YXJncyA9IFsidGMiLCAiLWoiLCAiLXMiLCAicWRpc2MiLCAic2hvdyJdCiAgICBpZiBpbnRlcmZh
Y2U6CiAgICAgICAgcWRpc2NfYXJncyArPSBbImRldiIsIHZhbGlkX2ludGVyZmFjZShpbnRlcmZh
Y2UpXQogICAgc29ja2V0cyA9IF9zYWZlX3Byb2JlKGxhbWJkYTogY3R4LnJ1bihbInNzIiwgIi10
aW4iXSkuc3Rkb3V0KQogICAgc29ja2V0X21hcCA9IHt9CiAgICBpZiBpc2luc3RhbmNlKHNvY2tl
dHMsIHN0cik6CiAgICAgICAgZm9yIGVudHJ5IGluIHJlLnNwbGl0KHIiKD9tKV4oPz1FU1RBQnxD
TE9TRS1XQUlUfEZJTi1XQUlUKSIsIHNvY2tldHMpOgogICAgICAgICAgICBpZiBub3QgZW50cnku
c3RhcnRzd2l0aCgoIkVTVEFCIiwgIkNMT1NFLVdBSVQiLCAiRklOLVdBSVQiKSk6CiAgICAgICAg
ICAgICAgICBjb250aW51ZQogICAgICAgICAgICBmaWVsZHMgPSBlbnRyeS5zcGxpdGxpbmVzKClb
MF0uc3BsaXQoKQogICAgICAgICAgICBpZiBsZW4oZmllbGRzKSA+PSA1OgogICAgICAgICAgICAg
ICAgbWF0Y2ggPSByZS5zZWFyY2gociJcYmJ5dGVzX3JldHJhbnM6KFxkKykiLCBlbnRyeSkKICAg
ICAgICAgICAgICAgIHNvY2tldF9tYXBbIiAiLmpvaW4oZmllbGRzWzM6NV0pXSA9IGludChtYXRj
aC5ncm91cCgxKSkgaWYgbWF0Y2ggZWxzZSAwCiAgICBjcHUgPSBwcm9jKCIvcHJvYy9zdGF0Iiku
c3BsaXRsaW5lcygpCiAgICBtZW1vcnkgPSBwcm9jKCIvcHJvYy9tZW1pbmZvIikKICAgIHJldHVy
biB7InRpbWUiOiB0aW1lLm1vbm90b25pYygpLCAiY3B1IjogY3B1WzBdIGlmIGNwdSBlbHNlICIi
LAogICAgICAgICAgICAibWVtb3J5Ijoge2tleTogaW50KHZhbHVlKSAqIDEwMjQgZm9yIGtleSwg
dmFsdWUgaW4KICAgICAgICAgICAgICAgICAgICAgICByZS5maW5kYWxsKHIiXihNZW1Ub3RhbHxN
ZW1BdmFpbGFibGV8U3dhcFRvdGFsfFN3YXBGcmVlKTpccysoXGQrKSIsIG1lbW9yeSwgcmUuTVVM
VElMSU5FKX0sCiAgICAgICAgICAgICJxZGlzY3MiOiBfc2FmZV9wcm9iZShsYW1iZGE6IF9qc29u
X2NvbW1hbmQoY3R4LCBxZGlzY19hcmdzKSksCiAgICAgICAgICAgICJsaW5rcyI6IF9zYWZlX3By
b2JlKGxhbWJkYTogX2pzb25fY29tbWFuZChjdHgsIFsiaXAiLCAiLWoiLCAiLXMiLCAiLWQiLCAi
bGluayIsICJzaG93Il0pKSwKICAgICAgICAgICAgInNvY2tldHMiOiBzb2NrZXRfbWFwfQoKCmRl
ZiBkaWFnbm9zZShjdHgsIGFyZ3MpOgogICAgaWYgbm90IDEgPD0gYXJncy5zZWNvbmRzIDw9IDYw
OgogICAgICAgIHJhaXNlIFR1bmVFcnJvcigiLS1zZWNvbmRzIOW/hemhu+S4uiAxIOiHsyA2MCDn
p5IiLCAyKQogICAgYmVmb3JlID0gX3Bhc3NpdmVfc25hcHNob3QoY3R4LCBhcmdzLmludGVyZmFj
ZSkKICAgIHRpbWUuc2xlZXAoYXJncy5zZWNvbmRzKQogICAgYWZ0ZXIgPSBfcGFzc2l2ZV9zbmFw
c2hvdChjdHgsIGFyZ3MuaW50ZXJmYWNlKQogICAgZGVsdGFzID0gW10KICAgIGlmIGlzaW5zdGFu
Y2UoYmVmb3JlWyJxZGlzY3MiXSwgbGlzdCkgYW5kIGlzaW5zdGFuY2UoYWZ0ZXJbInFkaXNjcyJd
LCBsaXN0KToKICAgICAgICBrZXlzID0gbGFtYmRhIHJvdzogKHJvdy5nZXQoImRldiIpLCByb3cu
Z2V0KCJoYW5kbGUiKSwgcm93LmdldCgicGFyZW50IiksIHJvdy5nZXQoImtpbmQiKSkKICAgICAg
ICBvbGQgPSB7a2V5cyhyb3cpOiByb3cgZm9yIHJvdyBpbiBiZWZvcmVbInFkaXNjcyJdfQogICAg
ICAgIGZvciByb3cgaW4gYWZ0ZXJbInFkaXNjcyJdOgogICAgICAgICAgICBwcmV2aW91cyA9IG9s
ZC5nZXQoa2V5cyhyb3cpKQogICAgICAgICAgICBpZiBwcmV2aW91czoKICAgICAgICAgICAgICAg
IGRlbHRhID0ge2ZpZWxkOiByb3cuZ2V0KGZpZWxkLCAwKSAtIHByZXZpb3VzLmdldChmaWVsZCwg
MCkKICAgICAgICAgICAgICAgICAgICAgICAgIGZvciBmaWVsZCBpbiAoImJ5dGVzIiwgInBhY2tl
dHMiLCAiZHJvcHMiLCAib3ZlcmxpbWl0cyIsICJyZXF1ZXVlcyIpfQogICAgICAgICAgICAgICAg
ZGVsdGFzLmFwcGVuZCh7ImludGVyZmFjZSI6IHJvdy5nZXQoImRldiIpLCAiaGFuZGxlIjogcm93
LmdldCgiaGFuZGxlIiksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAia2luZCI6IHJv
dy5nZXQoImtpbmQiKSwgImNvdW50ZXJfcmVzZXQiOiBhbnkodiA8IDAgZm9yIHYgaW4gZGVsdGEu
dmFsdWVzKCkpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgImRlbHRhIjogZGVsdGF9
KQogICAgbm9uaWRsZSA9IE5vbmUKICAgIHRyeToKICAgICAgICBvbGQgPSBsaXN0KG1hcChpbnQs
IGJlZm9yZVsiY3B1Il0uc3BsaXQoKVsxOjldKSkKICAgICAgICBuZXcgPSBsaXN0KG1hcChpbnQs
IGFmdGVyWyJjcHUiXS5zcGxpdCgpWzE6OV0pKQogICAgICAgIGRlbHRhID0gW2IgLSBhIGZvciBh
LCBiIGluIHppcChvbGQsIG5ldyldCiAgICAgICAgaWYgbGVuKGRlbHRhKSA9PSA4IGFuZCBtaW4o
ZGVsdGEpID49IDAgYW5kIHN1bShkZWx0YSk6CiAgICAgICAgICAgIG5vbmlkbGUgPSAxMDAgKiAo
c3VtKGRlbHRhKSAtIGRlbHRhWzNdIC0gZGVsdGFbNF0pIC8gc3VtKGRlbHRhKQogICAgZXhjZXB0
IFZhbHVlRXJyb3I6CiAgICAgICAgcGFzcwogICAgY29tbW9uID0gc2V0KGJlZm9yZVsic29ja2V0
cyJdKSAmIHNldChhZnRlclsic29ja2V0cyJdKQogICAgcmV0cmFucyA9IHN1bShtYXgoMCwgYWZ0
ZXJbInNvY2tldHMiXVtrZXldIC0gYmVmb3JlWyJzb2NrZXRzIl1ba2V5XSkgZm9yIGtleSBpbiBj
b21tb24pCiAgICByZXR1cm4geyJzZWNvbmRzIjogYWZ0ZXJbInRpbWUiXSAtIGJlZm9yZVsidGlt
ZSJdLCAiY3B1X25vbmlkbGVfcGVyY2VudCI6IG5vbmlkbGUsCiAgICAgICAgICAgICJtZW1vcnki
OiBhZnRlclsibWVtb3J5Il0sICJxZGlzY19kZWx0YXMiOiBkZWx0YXMsCiAgICAgICAgICAgICJj
b250aW51aW5nX3RjcF9jb25uZWN0aW9ucyI6IGxlbihjb21tb24pLCAiY29udGludWluZ190Y3Bf
cmV0cmFuc21pdHRlZF9ieXRlcyI6IHJldHJhbnMsCiAgICAgICAgICAgICJ3YXJuaW5ncyI6IFsi
6KKr5Yqo6KeC5rWL5LiN5Lqn55Sf5rWL6K+V5rWB6YeP77yM5LiN6IO95o2u5q2k5L+d6K+B5bim
5a696L6+5qCH44CCIiwKICAgICAgICAgICAgICAgICAgICAgICAgICLku4Xmr5TovoPmjIHnu63l
rZjmtLvnmoQgVENQIOi/nuaOpe+8m+aWsOW7uuOAgeW3sue7k+adn+i/nuaOpeS4jeWcqOmHjeS8
oOWinumHj+S4reOAgiIsCiAgICAgICAgICAgICAgICAgICAgICAgICAi54i25a2Q6Zif5YiX6K6h
5pWw5Y+v6IO95YyF5ZCr5ZCM5LiA5oql5paH77yM6K+35Yu/55u45Yqg44CCIiwKICAgICAgICAg
ICAgICAgICAgICAgICAgICLpnIDopoHnu4/lrp7pmYXkuJrliqHot6/lvoTpqozor4HvvJvmnKzm
nLrlvIDlhbPmraPluLjkuI3og73mjpLpmaTkuK3pl7Torr7lpIfmlLnlhpnmj6HmiYvjgIIiXX0K
CgpkZWYgZGlzcGF0Y2goY3R4LCBhcmdzKToKICAgIGdyb3VwID0gYXJncy5ncm91cCBvciAic3Rh
dHVzIgogICAgaWYgZ3JvdXAgPT0gInN0YXR1cyI6CiAgICAgICAgcmV0dXJuIHN0YXR1cyhjdHgs
IGdldGF0dHIoYXJncywgImludGVyZmFjZSIsIE5vbmUpKQogICAgaWYgZ3JvdXAgPT0gImRpYWdu
b3NlIjoKICAgICAgICByZXR1cm4gZGlhZ25vc2UoY3R4LCBhcmdzKQogICAgaWYgZ3JvdXAgPT0g
ImJ1ZmZlciI6CiAgICAgICAgbWFuYWdlciA9IEJ1ZmZlck1hbmFnZXIoY3R4KQogICAgICAgIGlm
IGFyZ3MuYWN0aW9uID09ICJlc3RpbWF0ZSI6CiAgICAgICAgICAgIHJldHVybiBtYW5hZ2VyLmVz
dGltYXRlKGFyZ3MpCiAgICAgICAgY3R4LnJlcXVpcmVfbXV0YXRpb24oKQogICAgICAgIHdpdGgg
Y3R4LmxvY2soIm5ldHdvcmstdHVuZSIpOgogICAgICAgICAgICByZXR1cm4gZ2V0YXR0cihtYW5h
Z2VyLCBhcmdzLmFjdGlvbikoYXJncykKICAgIGlmIGdyb3VwID09ICJwb3J0IiBhbmQgYXJncy5h
Y3Rpb24gPT0gImxpc3QiOgogICAgICAgIHJldHVybiBQb3J0TWFuYWdlcihjdHgpLmxpc3QoKQog
ICAgY3R4LnJlcXVpcmVfbXV0YXRpb24oKQogICAgaWYgZ3JvdXAgPT0gImVncmVzcyIgb3IgKGdy
b3VwID09ICJwb3J0IiBhbmQgYXJncy5hY3Rpb24gPT0gInNldCIpOgogICAgICAgIGFyZ3MuaW50
ZXJmYWNlID0gX2ludGVyZmFjZShjdHgsIGFyZ3MuaW50ZXJmYWNlKQogICAgaWYgZ3JvdXAgPT0g
ImludGVybmFsIjoKICAgICAgICBjdHgubG9ja193YWl0X3NlY29uZHMgPSA2MAogICAgd2l0aCBj
dHgudW5pdF9yZXN0b3JlX3Njb3BlKCksIGN0eC5sb2NrKCJuZXR3b3JrLXR1bmUiKSwgY3R4Lmxv
Y2soIm5ldHdvcmstcWRpc2MiKSwgY3R4LnJ1bnRpbWVfdHJhbnNhY3Rpb24oKToKICAgICAgICBp
ZiBncm91cCA9PSAiZWdyZXNzIjoKICAgICAgICAgICAgcmV0dXJuIGdldGF0dHIoRWdyZXNzTWFu
YWdlcihjdHgpLCBhcmdzLmFjdGlvbikoYXJncykKICAgICAgICBpZiBncm91cCA9PSAicG9ydCI6
CiAgICAgICAgICAgIHdpdGggY3R4LmxvY2soIm5ldHdvcmstbmZ0YWJsZXMiKToKICAgICAgICAg
ICAgICAgIHJldHVybiBnZXRhdHRyKFBvcnRNYW5hZ2VyKGN0eCksIGFyZ3MuYWN0aW9uKShhcmdz
KQogICAgICAgIGlmIGdyb3VwID09ICJpbnRlcm5hbCI6CiAgICAgICAgICAgIGlmIGFyZ3MuYWN0
aW9uID09ICJlZ3Jlc3MtYXBwbHkiOgogICAgICAgICAgICAgICAgcmV0dXJuIEVncmVzc01hbmFn
ZXIoY3R4KS5ib290KGFyZ3MuaW50ZXJmYWNlKQogICAgICAgICAgICB3aXRoIGN0eC5sb2NrKCJu
ZXR3b3JrLW5mdGFibGVzIik6CiAgICAgICAgICAgICAgICByZXR1cm4gUG9ydE1hbmFnZXIoY3R4
KS5ib290KGFyZ3MuaW50ZXJmYWNlKQogICAgcmFpc2UgVHVuZUVycm9yKCLmnKrnn6XnvZHnu5zo
sIPkvJjliqjkvZwiLCAyKQoKCmRlZiBfc2l6ZSh2YWx1ZSk6CiAgICBpZiB2YWx1ZSBpcyBOb25l
OgogICAgICAgIHJldHVybiAi5LiN5Y+v55SoIgogICAgcmV0dXJuIGYie3ZhbHVlIC8gMTA0ODU3
NjouMmZ9IE1pQiIKCgpkZWYgX3JhdGUodmFsdWUpOgogICAgcmV0dXJuICLml6Dpop3lpJbkuIrp
mZAiIGlmIHZhbHVlIGlzIE5vbmUgZWxzZSBmInt2YWx1ZSAvIDFfMDAwXzAwMDpnfSBNYnBzIgoK
CmRlZiBfcHJvZmlsZSh2YWx1ZSk6CiAgICBpZiBub3QgdmFsdWU6CiAgICAgICAgcmV0dXJuICLm
nKrmiZjnrqEiCiAgICBtb2RlID0gdmFsdWUuZ2V0KCJtb2RlIikKICAgIGlmIG1vZGUgPT0gImZx
IjoKICAgICAgICByZXR1cm4gIuavj+a1gSBmce+8jCIgKyBfcmF0ZSh2YWx1ZS5nZXQoIm1heHJh
dGVfYnBzIikpCiAgICB0ZXh0ID0gIuaAu+WHuuWPoyAiICsgX3JhdGUodmFsdWUuZ2V0KCJyYXRl
X2JwcyIpKSArIGYi77yM56qB5Y+RIHt2YWx1ZS5nZXQoJ2J1cnN0X2J5dGVzJywgMCkgLyAxMDI0
Omd9IEtpQiIKICAgIGlmIG1vZGUgPT0gInRiZiI6CiAgICAgICAgcmV0dXJuIHRleHQgKyBmIu+8
jEZJRk8g5o6S6Zif6aKE566XIHt2YWx1ZS5nZXQoJ2xhdGVuY3lfbXMnKX0gbXMiCiAgICByZXR1
cm4gdGV4dCArIGYi77yMZnEg6ZmQ6ZW/IHt2YWx1ZS5nZXQoJ2xpbWl0X3BhY2tldHMnKX0g5YyF
77yI5LiN5om/6K+65Zu65a6a562J5b6F5pe26ZmQ77yJIgoKCmRlZiBfcnVsZXMocnVsZXMpOgog
ICAgaWYgbm90IHJ1bGVzOgogICAgICAgIHByaW50KCLlsJrmnKrorr7nva7nq6/lj6PpmZDpgJ/j
gIIiKQogICAgZm9yIHJ1bGVfaWQsIHJ1bGUgaW4gc29ydGVkKHJ1bGVzLml0ZW1zKCkpOgogICAg
ICAgIHByaW50KGYiICB7cnVsZV9pZH06IHtydWxlWydpbnRlcmZhY2UnXX0g5rqQ56uv5Y+jIHty
dWxlWydwb3J0J119IC8ge3J1bGVbJ3Byb3RvY29sJ119IC8ge3J1bGVbJ2ZhbWlseSddfSIpCiAg
ICAgICAgcHJvZmlsZSA9IHJ1bGVbInByb2ZpbGUiXQogICAgICAgIHByaW50KCIgICAg5rGH5oC7
77yaIiArIF9yYXRlKHByb2ZpbGUuZ2V0KCJyYXRlX2JwcyIpKSArICLvvJvmr48gVENQIOa1ge+8
miIgKyBfcmF0ZShwcm9maWxlLmdldCgibWF4cmF0ZV9icHMiKSkpCgoKZGVmIHJlbmRlcihyZXN1
bHQsIGFyZ3MsIGN0eCk6CiAgICBpZiBjdHguanNvbl9vdXRwdXQ6CiAgICAgICAgcHJpbnQoanNv
bi5kdW1wcyhyZXN1bHQsIGVuc3VyZV9hc2NpaT1GYWxzZSwgaW5kZW50PTIsIHNvcnRfa2V5cz1U
cnVlKSkKICAgICAgICByZXR1cm4KICAgIGlmIHJlc3VsdC5nZXQoImRyeV9ydW4iKSBvciBjdHgu
ZHJ5X3J1bjoKICAgICAgICBwcmludCgi5ryU57uD77ya5pyq5L+u5pS557O757uf6YWN572u44CC
IikKICAgIGlmICJrZXJuZWwiIGluIHJlc3VsdDoKICAgICAgICBrZXJuZWwgPSByZXN1bHRbImtl
cm5lbCJdCiAgICAgICAgcHJpbnQoZiLnvZHnu5zosIPkvJjnirbmgIHvvJrlhoXmoLgge2tlcm5l
bFsncmVsZWFzZSddfe+8m0JCUiDniYjmnKwge2tlcm5lbFsnYmJyX21vZHVsZV92ZXJzaW9uJ119
IikKICAgICAgICBwcmludCgi5oul5aGe5o6n5Yi277yaIiArIHN0cihrZXJuZWwuZ2V0KCJ0Y3Bf
Y29uZ2VzdGlvbl9jb250cm9sIikpKQogICAgICAgIGJ1ZmZlcnMgPSByZXN1bHRbImJ1ZmZlcnMi
XQogICAgICAgIHByaW50KCJcblRDUCDlj4LmlbDvvJoiKQogICAgICAgIGlmICJ1bmF2YWlsYWJs
ZSIgaW4gYnVmZmVyczoKICAgICAgICAgICAgcHJpbnQoIiAg5LiN5Y+v6K+75Y+W77yaIiArIGJ1
ZmZlcnNbInVuYXZhaWxhYmxlIl0pCiAgICAgICAgZWxzZToKICAgICAgICAgICAgZm9yIG5hbWUs
IHZhbHVlIGluIHNvcnRlZChidWZmZXJzLmdldCgia2V5cyIsIHt9KS5pdGVtcygpKToKICAgICAg
ICAgICAgICAgIHByaW50KGYiICB7bmFtZX0gPSB7dmFsdWUuZ2V0KCdydW50aW1lJywgJ+S4jeWP
r+eUqCcpfSIpCiAgICAgICAgICAgICAgICBpZiB2YWx1ZS5nZXQoInNvdXJjZSIpOgogICAgICAg
ICAgICAgICAgICAgIHByaW50KCIgICAg5oyB5LmF5YyW5p2l5rqQ77yaIiArIHZhbHVlWyJzb3Vy
Y2UiXSkKICAgICAgICAgICAgaWYgYnVmZmVycy5nZXQoImRyaWZ0Iik6CiAgICAgICAgICAgICAg
ICBwcmludCgiICDms6jmhI/vvJrlj5fnrqHlj4LmlbDmiJbmjIHkuYXphY3nva7lrZjlnKjlt67l
vILjgIIiKQogICAgICAgIHByaW50KCJcbuWHuuWPo+mYn+WIl++8miIpCiAgICAgICAgZWdyZXNz
ID0gcmVzdWx0WyJlZ3Jlc3MiXQogICAgICAgIGlmICJ1bmF2YWlsYWJsZSIgaW4gZWdyZXNzOgog
ICAgICAgICAgICBwcmludCgiICDkuI3lj6/or7vlj5bvvJoiICsgZWdyZXNzWyJ1bmF2YWlsYWJs
ZSJdKQogICAgICAgIGVsaWYgbm90IGVncmVzcy5nZXQoImludGVyZmFjZXMiKToKICAgICAgICAg
ICAgcHJpbnQoIiAg5bCa5pyq5omY566h5Ye65Y+j6Zif5YiX77yb5oyH5a6aIC0taW50ZXJmYWNl
IOWPr+afpeeci+eOsOaciemYn+WIl+OAgiIpCiAgICAgICAgZm9yIG5hbWUsIGl0ZW0gaW4gZWdy
ZXNzLmdldCgiaW50ZXJmYWNlcyIsIHt9KS5pdGVtcygpOgogICAgICAgICAgICBwcmludChmIiAg
e25hbWV9OiAiICsgX3Byb2ZpbGUoaXRlbS5nZXQoInByb2ZpbGUiKSkpCiAgICAgICAgICAgIHBy
aW50KGYiICAgIOWunumZhemYn+WIl++8mnsnLCAnLmpvaW4ocm93WydraW5kJ10gZm9yIHJvdyBp
biBpdGVtLmdldCgndHJlZScsIFtdKSl977yb6YWN572u5Yy56YWN77yae2l0ZW0uZ2V0KCdtYXRj
aGVzJyl9IikKICAgICAgICAgICAgaWYgaXRlbS5nZXQoInNlcnZpY2UiKToKICAgICAgICAgICAg
ICAgIHByaW50KCIgICAg5byA5py65ZCv55So77yaIiArICgi5pivIiBpZiBpdGVtWyJzZXJ2aWNl
Il0uZ2V0KCJlbmFibGVkIikgZWxzZSAi5ZCmIikpCiAgICAgICAgcHJpbnQoIlxu56uv5Y+j6ZmQ
6YCf77yaIikKICAgICAgICBwb3J0cyA9IHJlc3VsdFsicG9ydHMiXQogICAgICAgIGlmICJ1bmF2
YWlsYWJsZSIgaW4gcG9ydHM6CiAgICAgICAgICAgIHByaW50KCIgIOS4jeWPr+ivu+WPlu+8miIg
KyBwb3J0c1sidW5hdmFpbGFibGUiXSkKICAgICAgICBlbHNlOgogICAgICAgICAgICBfcnVsZXMo
cG9ydHMuZ2V0KCJydWxlcyIsIHt9KSkKICAgICAgICAgICAgZm9yIHdhcm5pbmcgaW4gcG9ydHMu
Z2V0KCJkcmlmdCIsIFtdKToKICAgICAgICAgICAgICAgIHByaW50KCIgIOazqOaEj++8miIgKyB3
YXJuaW5nKQogICAgICAgIGZvciBub3RlIGluIHJlc3VsdFsibm90ZXMiXToKICAgICAgICAgICAg
cHJpbnQoIuivtOaYju+8miIgKyBub3RlKQogICAgICAgIHJldHVybgogICAgaWYgImJ1ZGdldF9i
eXRlcyIgaW4gcmVzdWx0OgogICAgICAgIHByaW50KCJUQ1Ag57yT5Yay5Yy65bu66K6u77ya54mp
55CG5YaF5a2YICIgKyBfc2l6ZShyZXN1bHQuZ2V0KCJtZW1vcnlfYnl0ZXMiKSkgKwogICAgICAg
ICAgICAgICLvvIzljZXmlrnlkJHlu7rorq7pooTnrpcgIiArIF9zaXplKHJlc3VsdFsiYnVkZ2V0
X2J5dGVzIl0pKQogICAgICAgIGZvciBrZXksIGxhYmVsIGluICgoInR4IiwgIuWPkemAgSIpLCAo
InJ4IiwgIuaOpeaUtiIpKToKICAgICAgICAgICAgdmFsdWUgPSByZXN1bHQuZ2V0KGtleSkKICAg
ICAgICAgICAgaWYgbm90IHZhbHVlOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAg
ICAgcHJpbnQobGFiZWwgKyAi5pa55ZCR77yaIikKICAgICAgICAgICAgcHJpbnQoZiIgIEJEUO+8
mnt2YWx1ZS5nZXQoJ2JkcF9ieXRlcycpfSDlrZfoioLvvJvnkIborrrlu7rorq7vvJp7X3NpemUo
dmFsdWUuZ2V0KCduZWVkZWRfbWF4X2J5dGVzJykpfSIpCiAgICAgICAgICAgIHByaW50KCIgIOW7
uuiuruS4iumZkO+8miIgKyBfc2l6ZSh2YWx1ZS5nZXQoInN1Z2dlc3RlZF9tYXhfYnl0ZXMiKSkp
CiAgICAgICAgICAgIGlmIHZhbHVlLmdldCgicmVhc29uIik6CiAgICAgICAgICAgICAgICBwcmlu
dCgiICAiICsgc3RyKHZhbHVlWyJyZWFzb24iXSkpCiAgICAgICAgICAgIGlmIHZhbHVlLmdldCgi
c3VnZ2VzdGVkX3RyaXBsZXQiKToKICAgICAgICAgICAgICAgIHByaW50KCIgIOS4ieWFg+e7hO+8
miIgKyAiICIuam9pbihtYXAoc3RyLCB2YWx1ZVsic3VnZ2VzdGVkX3RyaXBsZXQiXSkpKQogICAg
ICAgIHByaW50KCLov5nmmK/oh6rliqjosIPoioLkuIrpmZDvvIzkuI3mmK/pooTliIbphY3lhoXl
rZjvvJvmiYvliqjlgLzlj6/opobnm5blu7rorq7vvIznvJPlrZjkuI3og73kv67lpI3pk77ot6/k
uKLljIXmiJbmj6HmiYvmlLnlhpnjgIIiKQogICAgICAgIHJldHVybgogICAgaWYgInFkaXNjX2Rl
bHRhcyIgaW4gcmVzdWx0OgogICAgICAgIHByaW50KGYi6KKr5Yqo6KeC5rWLIHtyZXN1bHRbJ3Nl
Y29uZHMnXTouMWZ9IOenku+8m0NQVSDpnZ7nqbrpl7Ige3Jlc3VsdFsnY3B1X25vbmlkbGVfcGVy
Y2VudCddfSUiKQogICAgICAgIHByaW50KCLlj6/nlKjlhoXlrZjvvJoiICsgX3NpemUocmVzdWx0
LmdldCgibWVtb3J5Iiwge30pLmdldCgiTWVtQXZhaWxhYmxlIikpKQogICAgICAgIGZvciByb3cg
aW4gcmVzdWx0WyJxZGlzY19kZWx0YXMiXToKICAgICAgICAgICAgcHJpbnQoZiIgIHtyb3dbJ2lu
dGVyZmFjZSddfSB7cm93WydraW5kJ119IHtyb3dbJ2hhbmRsZSddfTogIgogICAgICAgICAgICAg
ICAgICBmIuWPkemAgeWinumHjyB7cm93WydkZWx0YSddWydieXRlcyddfSBC77yM5Lii5byD5aKe
6YePIHtyb3dbJ2RlbHRhJ11bJ2Ryb3BzJ119IiArCiAgICAgICAgICAgICAgICAgICgi77yI6K6h
5pWw5Zmo6YeN572u77yM5LiN6IO95L2c5beu77yJIiBpZiByb3dbImNvdW50ZXJfcmVzZXQiXSBl
bHNlICIiKSkKICAgICAgICBwcmludChmIuaMgee7reWtmOa0u+i/nuaOpSB7cmVzdWx0Wydjb250
aW51aW5nX3RjcF9jb25uZWN0aW9ucyddfe+8m+mHjeS8oOWtl+iKguWinumHjyB7cmVzdWx0Wydj
b250aW51aW5nX3RjcF9yZXRyYW5zbWl0dGVkX2J5dGVzJ119IikKICAgICAgICBmb3Igd2Fybmlu
ZyBpbiByZXN1bHRbIndhcm5pbmdzIl06CiAgICAgICAgICAgIHByaW50KCLor7TmmI7vvJoiICsg
d2FybmluZykKICAgICAgICByZXR1cm4KICAgIGlmICJydWxlcyIgaW4gcmVzdWx0OgogICAgICAg
IF9ydWxlcyhyZXN1bHRbInJ1bGVzIl0pCiAgICBlbGlmICJydWxlIiBpbiByZXN1bHQ6CiAgICAg
ICAgX3J1bGVzKHtyZXN1bHRbInJ1bGUiXVsiaWQiXTogcmVzdWx0WyJydWxlIl19KQogICAgaWYg
ImRlbGV0ZWQiIGluIHJlc3VsdDoKICAgICAgICBwcmludCgi5Yig6Zmk6KeE5YiZ77yaIiArIHJl
c3VsdFsiZGVsZXRlZCJdKQogICAgaWYgInByb2ZpbGUiIGluIHJlc3VsdDoKICAgICAgICBwcmlu
dChzdHIocmVzdWx0LmdldCgiaW50ZXJmYWNlIiwgIiIpKSArICLvvJoiICsgX3Byb2ZpbGUocmVz
dWx0WyJwcm9maWxlIl0pKQogICAgZWxpZiAiaW50ZXJmYWNlIiBpbiByZXN1bHQgYW5kIGFueShr
ZXkgaW4gcmVzdWx0IGZvciBrZXkgaW4gKCJyZXN0b3JlIiwgInJlc3RvcmVkIiwgImNsZWFyZWQi
KSk6CiAgICAgICAgcmVzdG9yaW5nID0gcmVzdWx0LmdldCgicmVzdG9yZSIsIHJlc3VsdC5nZXQo
InJlc3RvcmVkIiwgRmFsc2UpKQogICAgICAgIHByaW50KHJlc3VsdFsiaW50ZXJmYWNlIl0gKyAo
Iu+8muaBouWkjeaOpeeuoeWJjemYn+WIl+WPiuaXp+acjeWKoe+8jOWPr+iDvemHjeaWsOWQr+eU
qOaXp+mZkOmAn+OAgiIgaWYgcmVzdG9yaW5nIGVsc2UKICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgIu+8muWPlua2iOWHuuWPo+aVtOW9ou+8jOaBouWkjeWGheaguOm7mOiupOmY
n+WIl++8m+S/neeVmeeLrOeri+err+WPo+inhOWImeOAgiIpKQogICAgaWYgInZhbHVlcyIgaW4g
cmVzdWx0OgogICAgICAgIGZvciBuYW1lLCB2YWx1ZSBpbiByZXN1bHRbInZhbHVlcyJdLml0ZW1z
KCk6CiAgICAgICAgICAgIHByaW50KCIgICIgKyBuYW1lICsgIiA9ICIgKyBzdHIodmFsdWUpKQog
ICAgcHJpbnQocmVzdWx0LmdldCgibWVzc2FnZSIpIG9yICgi5pON5L2c5bey5a6M5oiQ44CCIiBp
ZiByZXN1bHQuZ2V0KCJjaGFuZ2VkIikgZWxzZQogICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgIuW3suaYvuekuuiuoeWIkuOAgiIgaWYgY3R4LmRyeV9ydW4gZWxzZSAi5pON5L2c5a6M
5oiQ77yM6YWN572u5peg6ZyA6YeN5aSN5bqU55So44CCIikpCgoKZGVmIF9jaG9vc2UodGl0bGUs
IG9wdGlvbnMpOgogICAgcHJpbnQoIlxuIiArIHRpdGxlKQogICAgZm9yIGluZGV4LCAoXywgdGV4
dCkgaW4gZW51bWVyYXRlKG9wdGlvbnMsIDEpOgogICAgICAgIHByaW50KGYiICB7aW5kZXh9KSB7
dGV4dH0iKQogICAgcHJpbnQoIiAgMCkg6L+U5ZueIikKICAgIHdoaWxlIFRydWU6CiAgICAgICAg
dHJ5OgogICAgICAgICAgICBhbnN3ZXIgPSBpbnB1dCgi6K+36YCJ5oup77yaIikuc3RyaXAoKQog
ICAgICAgIGV4Y2VwdCBFT0ZFcnJvcjoKICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLovpPl
haXlt7Lnu5PmnZ8iLCAxMzApCiAgICAgICAgaWYgYW5zd2VyID09ICIwIjoKICAgICAgICAgICAg
cmV0dXJuIE5vbmUKICAgICAgICBpZiBhbnN3ZXIuaXNkaWdpdCgpIGFuZCAxIDw9IGludChhbnN3
ZXIpIDw9IGxlbihvcHRpb25zKToKICAgICAgICAgICAgcmV0dXJuIG9wdGlvbnNbaW50KGFuc3dl
cikgLSAxXVswXQogICAgICAgIHByaW50KCLor7fovpPlhaXliJfooajkuK3nmoTnvJblj7fjgIIi
KQoKCmRlZiBfYXNrKGxhYmVsLCBkZWZhdWx0PU5vbmUpOgogICAgcHJvbXB0ID0gbGFiZWwgKyAo
ZiIgW3tkZWZhdWx0fV0iIGlmIGRlZmF1bHQgaXMgbm90IE5vbmUgZWxzZSAiIikgKyAi77yaIgog
ICAgdHJ5OgogICAgICAgIHZhbHVlID0gaW5wdXQocHJvbXB0KS5zdHJpcCgpCiAgICBleGNlcHQg
RU9GRXJyb3I6CiAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLovpPlhaXlt7Lnu5PmnZ8iLCAxMzAp
CiAgICBpZiB2YWx1ZSA9PSAiOnEiOgogICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5pON5L2c5bey
5Y+W5raIIiwgMTMwKQogICAgcmV0dXJuIHZhbHVlIG9yIChzdHIoZGVmYXVsdCkgaWYgZGVmYXVs
dCBpcyBub3QgTm9uZSBlbHNlICIiKQoKCmRlZiBfc2VsZWN0X2ludGVyZmFjZShjdHgpOgogICAg
bGlua3MgPSBfanNvbl9jb21tYW5kKGN0eCwgWyJpcCIsICItaiIsICItZCIsICJsaW5rIiwgInNo
b3ciXSkKICAgIGVudHJpZXMgPSBbKHJvd1siaWZuYW1lIl0sIHJvd1siaWZuYW1lIl0gKyAiIC8g
IiArIHJvdy5nZXQoIm9wZXJzdGF0ZSIsICLmnKrnn6UiKSkKICAgICAgICAgICAgICAgZm9yIHJv
dyBpbiBsaW5rcyBpZiByb3dbImlmbmFtZSJdICE9ICJsbyIgYW5kCiAgICAgICAgICAgICAgIHJv
dy5nZXQoImxpbmtpbmZvIiwge30pLmdldCgiaW5mb19raW5kIikgIT0gImlmYiJdCiAgICBzZWxl
Y3RlZCA9IF9jaG9vc2UoIumAieaLqeS9nOeUqOe9keWNoSIsIGVudHJpZXMpCiAgICByZXR1cm4g
c2VsZWN0ZWQKCgpkZWYgX21lbnVfYWN0aW9uKGFyZ3VtZW50cywgY3R4KToKICAgIHBhdGggPSBv
cy5lbnZpcm9uLmdldCgiVlBTQ1RMX1RVTkVfRlJPTlRFTkRfUEFUSCIpCiAgICBraW5kID0gb3Mu
ZW52aXJvbi5nZXQoIlZQU0NUTF9UVU5FX0ZST05URU5EX0tJTkQiKQogICAgaWYgcGF0aCBhbmQg
a2luZCBpbiAoInZwc2N0bCIsICJwbzAiKSBhbmQgUGF0aChwYXRoKS5pc19maWxlKCk6CiAgICAg
ICAgY29tbWFuZCA9IFsiYmFzaCIsIHBhdGhdICsgKFsidHVuZSJdIGlmIGtpbmQgPT0gInBvMCIg
ZWxzZSBbXSkKICAgICAgICBmbGFncyA9IFtdCiAgICAgICAgaWYgY3R4LmRyeV9ydW46CiAgICAg
ICAgICAgIGZsYWdzLmFwcGVuZCgiLS1kcnktcnVuIikKICAgICAgICBpZiB0cnV0aF9lbnYoIlZQ
U0NUTF9JTlNUQUxMX0RFUFMiKToKICAgICAgICAgICAgZmxhZ3MuYXBwZW5kKCItLWluc3RhbGwt
ZGVwcyIpCiAgICAgICAgcmVzdWx0ID0gc3VicHJvY2Vzcy5ydW4oY29tbWFuZCArIGZsYWdzICsg
YXJndW1lbnRzLCBjaGVjaz1GYWxzZSkKICAgICAgICBpZiByZXN1bHQucmV0dXJuY29kZSBub3Qg
aW4gKDAsIDEzMCk6CiAgICAgICAgICAgIHByaW50KCLor6Xmk43kvZzmnKrmiJDlip/vvIzor7fm
n6XnnIvkuIrmlrnljp/lm6DjgIIiLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0dXJuCiAg
ICBzZWxlY3RlZCA9IHBhcnNlcigpLnBhcnNlX2FyZ3MoYXJndW1lbnRzKQogICAgc2VsZWN0ZWRf
Y3R4ID0gQ29udGV4dChkcnlfcnVuPWN0eC5kcnlfcnVuLCBhc3N1bWVfeWVzPWN0eC5hc3N1bWVf
eWVzLAogICAgICAgICAgICAgICAgICAgICAgICAgICBub25faW50ZXJhY3RpdmU9Y3R4Lm5vbl9p
bnRlcmFjdGl2ZSkKICAgIHJlbmRlcihkaXNwYXRjaChzZWxlY3RlZF9jdHgsIHNlbGVjdGVkKSwg
c2VsZWN0ZWQsIHNlbGVjdGVkX2N0eCkKCgpkZWYgdHJ1dGhfZW52KG5hbWUpOgogICAgcmV0dXJu
IG9zLmVudmlyb24uZ2V0KG5hbWUsICIiKS5sb3dlcigpIGluICgiMSIsICJ5ZXMiLCAidHJ1ZSIs
ICJvbiIpCgoKZGVmIF9idWZmZXJfbWVudShjdHgpOgogICAgc2VsZWN0aW9uID0gX2Nob29zZSgi
VENQIOe8k+WGsuWMuiIsIFsKICAgICAgICAoInN0YXR1cyIsICLmn6XnnIvlvZPliY3lj4LmlbAi
KSwgKCJlc3RpbWF0ZSIsICLku4XorqHnrpflu7rorq4iKSwKICAgICAgICAoInJlY29tbWVuZGVk
IiwgIuiuoeeul+W7uuiuruW5tuiuvue9riIpLCAoIm1hbnVhbCIsICLmiYvliqjorr7nva7mlLbl
j5HkuIrpmZAiKSwKICAgICAgICAoImFkdmFuY2VkIiwgIumrmOe6pyBUQ1Ag5Y+C5pWwIiksICgi
cmVzdG9yZSIsICLmgaLlpI3lpJbpg6jmnInmlYjphY3nva4v5Y6f5YC8IiksCiAgICBdKQogICAg
aWYgc2VsZWN0aW9uIGlzIE5vbmU6CiAgICAgICAgcmV0dXJuCiAgICBpZiBzZWxlY3Rpb24gPT0g
InN0YXR1cyI6CiAgICAgICAgcmV0dXJuIF9tZW51X2FjdGlvbihbInN0YXR1cyJdLCBjdHgpCiAg
ICBpZiBzZWxlY3Rpb24gPT0gInJlc3RvcmUiOgogICAgICAgIHJldHVybiBfbWVudV9hY3Rpb24o
WyJidWZmZXIiLCAicmVzdG9yZSJdLCBjdHgpCiAgICBpZiBzZWxlY3Rpb24gaW4gKCJlc3RpbWF0
ZSIsICJyZWNvbW1lbmRlZCIpOgogICAgICAgIHByaW50KCLloavlhpnlrp7pmYXpk77ot68gUlRU
77yb5LiN6KaB5L2/55So6KKr5Lit6Ze0572R5YWz5o+Q5YmN5bqU562U55qE5bu66L+e6ICX5pe2
44CC5bim5a695oyJ5pys5py65Y+R6YCBL+aOpeaUtuWIhuWIq+Whq+WGmeOAgiIpCiAgICAgICAg
dmFsdWVzID0gWyItLXJ0dC1tcyIsIF9hc2soIlJUVO+8iOavq+enku+8iSIpXQogICAgICAgIGZv
ciBrZXksIGxhYmVsIGluICgoInR4LW1icHMiLCAi55uu5qCH5Y+R6YCBIE1icHPvvIznlZnnqbrk
uI3kv67mlLkiKSwgKCJyeC1tYnBzIiwgIuebruagh+aOpeaUtiBNYnBz77yM55WZ56m65LiN5L+u
5pS5IikpOgogICAgICAgICAgICB2YWx1ZSA9IF9hc2sobGFiZWwpCiAgICAgICAgICAgIGlmIHZh
bHVlOgogICAgICAgICAgICAgICAgdmFsdWVzICs9IFsiLS0iICsga2V5LCB2YWx1ZV0KICAgICAg
ICBhY3Rpb24gPSBbImJ1ZmZlciIsICJlc3RpbWF0ZSJdIGlmIHNlbGVjdGlvbiA9PSAiZXN0aW1h
dGUiIGVsc2UgWyJidWZmZXIiLCAic2V0IiwgIi0tcmVjb21tZW5kZWQiXQogICAgICAgIGlmIHNl
bGVjdGlvbiA9PSAicmVjb21tZW5kZWQiOgogICAgICAgICAgICBzeW5jID0gX2Nob29zZSgi5piv
5ZCm5ZCM5q2l5qC45b+DIHNvY2tldCDkuIrpmZAiLCBbKCJubyIsICLkv53mjIEgbmV0LmNvcmUu
Km1lbV9tYXgiKSwgKCJ5ZXMiLCAi5ZCM5q2l5omA6YCJ5pa55ZCRIG5ldC5jb3JlLiptZW1fbWF4
IildKQogICAgICAgICAgICBpZiBzeW5jIGlzIE5vbmU6CiAgICAgICAgICAgICAgICByZXR1cm4K
ICAgICAgICAgICAgaWYgc3luYyA9PSAieWVzIjoKICAgICAgICAgICAgICAgIHZhbHVlcyArPSBb
Ii0tc3luYy1jb3JlIl0KICAgICAgICByZXR1cm4gX21lbnVfYWN0aW9uKGFjdGlvbiArIHZhbHVl
cywgY3R4KQogICAgaWYgc2VsZWN0aW9uID09ICJtYW51YWwiOgogICAgICAgIHZhbHVlcyA9IFtd
CiAgICAgICAgZm9yIGtleSwgbGFiZWwgaW4gKCgidHgtbWF4IiwgIuWPkemAgeS4iumZkO+8jOWm
giAxNk1pQu+8m+eVmeepuuS/neaMgSIpLCAoInJ4LW1heCIsICLmjqXmlLbkuIrpmZDvvIzlpoIg
MTZNaULvvJvnlZnnqbrkv53mjIEiKSk6CiAgICAgICAgICAgIHZhbHVlID0gX2FzayhsYWJlbCkK
ICAgICAgICAgICAgaWYgdmFsdWU6CiAgICAgICAgICAgICAgICB2YWx1ZXMgKz0gWyItLSIgKyBr
ZXksIHZhbHVlXQogICAgICAgIGlmIHZhbHVlczoKICAgICAgICAgICAgc3luYyA9IF9jaG9vc2Uo
IuaYr+WQpuWQjOatpeaguOW/gyBzb2NrZXQg5LiK6ZmQIiwgWygibm8iLCAi5L+d5oyBIG5ldC5j
b3JlLiptZW1fbWF4IiksICgieWVzIiwgIuWQjOatpeaJgOmAieaWueWQkSBuZXQuY29yZS4qbWVt
X21heCIpXSkKICAgICAgICAgICAgaWYgc3luYyBpcyBOb25lOgogICAgICAgICAgICAgICAgcmV0
dXJuCiAgICAgICAgICAgIGlmIHN5bmMgPT0gInllcyI6CiAgICAgICAgICAgICAgICB2YWx1ZXMg
Kz0gWyItLXN5bmMtY29yZSJdCiAgICAgICAgICAgIHJldHVybiBfbWVudV9hY3Rpb24oWyJidWZm
ZXIiLCAic2V0Il0gKyB2YWx1ZXMsIGN0eCkKICAgICAgICByZXR1cm4KICAgIGZpZWxkcyA9IFsK
ICAgICAgICAoIm5ldC5pcHY0LnRjcF9ybWVtIiwgIuaOpeaUtuWujOaVtOS4ieWFg+e7hO+8muac
gOWwjy/liJ3lp4sv5pyA5aSnIiksCiAgICAgICAgKCJuZXQuaXB2NC50Y3Bfd21lbSIsICLlj5Hp
gIHlrozmlbTkuInlhYPnu4TvvJrmnIDlsI8v5Yid5aeLL+acgOWkpyIpLAogICAgICAgICgibmV0
LmNvcmUucm1lbV9tYXgiLCAi5qC45b+D5o6l5pS2IHNvY2tldCDkuIrpmZAiKSwKICAgICAgICAo
Im5ldC5jb3JlLndtZW1fbWF4IiwgIuaguOW/g+WPkemAgSBzb2NrZXQg5LiK6ZmQIiksCiAgICAg
ICAgKCJuZXQuaXB2NC50Y3Bfc2FjayIsICJTQUNLIiksICgibmV0LmlwdjQudGNwX3RpbWVzdGFt
cHMiLCAiVENQIOaXtumXtOaIsyIpLAogICAgICAgICgibmV0LmlwdjQudGNwX3dpbmRvd19zY2Fs
aW5nIiwgIlRDUCDnqpflj6PnvKnmlL4iKSwKICAgICAgICAoIm5ldC5pcHY0LnRjcF9tb2RlcmF0
ZV9yY3ZidWYiLCAi5o6l5pS257yT5Yay5Yy66Ieq5Yqo6LCD6IqCIiksCiAgICAgICAgKCJuZXQu
aXB2NC50Y3BfbXR1X3Byb2JpbmciLCAiTVRVIOm7kea0nuaOoua1iyIpLAogICAgXQogICAgZmll
bGQgPSBfY2hvb3NlKCLpgInmi6nopoHmmI7noa7kv67mlLnnmoTlj4LmlbAiLCBmaWVsZHMpCiAg
ICBpZiBub3QgZmllbGQ6CiAgICAgICAgcmV0dXJuCiAgICBpZiBmaWVsZC5lbmRzd2l0aCgoInRj
cF9ybWVtIiwgInRjcF93bWVtIikpOgogICAgICAgIHZhbHVlID0gX2Fzaygi5pyA5bCPIOWIneWn
iyDmnIDlpKfvvIzlpoIgNDA5NiAxMzEwNzIgMTZNaUIiKQogICAgZWxpZiBmaWVsZC5zdGFydHN3
aXRoKCJuZXQuY29yZS4iKToKICAgICAgICB2YWx1ZSA9IF9hc2soIuS4iumZkO+8jOWmgiAxNk1p
QiIpCiAgICBlbGlmIGZpZWxkLmVuZHN3aXRoKCJ0Y3BfdGltZXN0YW1wcyIpOgogICAgICAgIHZh
bHVlID0gX2Nob29zZSgi5pe26Ze05oiz5qih5byPIiwgWygiMSIsICLlvIDlkK/vvIzkvb/nlKjp
mo/mnLrlgY/np7siKSwgKCIyIiwgIuW8gOWQr++8jOS4jeS9v+eUqOmaj+acuuWBj+enuyIpLCAo
IjAiLCAi5YWz6ZetIildKQogICAgZWxpZiBmaWVsZC5lbmRzd2l0aCgidGNwX210dV9wcm9iaW5n
Iik6CiAgICAgICAgdmFsdWUgPSBfY2hvb3NlKCLmjqLmtYvmqKHlvI8iLCBbKCIxIiwgIuWPkeeO
sOm7kea0nuaXtuWQr+eUqCIpLCAoIjIiLCAi5aeL57uI5ZCv55SoIiksICgiMCIsICLlhbPpl60i
KV0pCiAgICBlbHNlOgogICAgICAgIHZhbHVlID0gX2Nob29zZSgi5Y+C5pWw54q25oCBIiwgWygi
MSIsICLlvIDlkK8iKSwgKCIwIiwgIuWFs+mXrSIpXSkKICAgIGlmIHZhbHVlIGlzIG5vdCBOb25l
OgogICAgICAgIF9tZW51X2FjdGlvbihbImJ1ZmZlciIsICJzZXQiLCAiLS1zZXQiLCBmaWVsZCAr
ICI9IiArIHZhbHVlXSwgY3R4KQoKCmRlZiBfZWdyZXNzX21lbnUoY3R4KToKICAgIHNlbGVjdGlv
biA9IF9jaG9vc2UoIue9keWNoeWHuuWPo+aVtOW9oiIsIFsKICAgICAgICAoInNldCIsICLorr7n
va7mgLvlh7rlj6Mv5q+P5rWB6IqC5aWPIiksICgiYWRvcHQiLCAi5o6l566h5bey6K+G5Yir55qE
5pen5LyY5YyW5pyN5YqhIiksCiAgICAgICAgKCJjbGVhciIsICLlj5bmtojmnKzmqKHlnZfmlbTl
vaLvvIzmgaLlpI3lhoXmoLjpu5jorqTpmJ/liJciKSwKICAgICAgICAoInJlc3RvcmUiLCAi5oGi
5aSN6aaW5qyh5o6l566h5YmN6Zif5YiX5Y+K5pyN5Yqh77yI5Y+v6IO96YeN5paw5ZCv55So5pen
6ZmQ6YCf77yJIiksCiAgICBdKQogICAgaWYgbm90IHNlbGVjdGlvbjoKICAgICAgICByZXR1cm4K
ICAgIGludGVyZmFjZSA9IF9zZWxlY3RfaW50ZXJmYWNlKGN0eCkKICAgIGlmIG5vdCBpbnRlcmZh
Y2U6CiAgICAgICAgcmV0dXJuCiAgICB2YWx1ZXMgPSBbImVncmVzcyIsIHNlbGVjdGlvbiwgIi0t
aW50ZXJmYWNlIiwgaW50ZXJmYWNlXQogICAgaWYgc2VsZWN0aW9uID09ICJzZXQiOgogICAgICAg
IG1vZGUgPSBfY2hvb3NlKCLpgInmi6npmJ/liJfmqKHlvI8iLCBbKCJ0YmYiLCAi5oC75Ye65Y+j
77yLRklGTyIpLCAoInRiZi1mcSIsICLmgLvlh7rlj6PvvItmcSIpLCAoImZxIiwgIuWFqOe9keWN
oeavj+a1geWPkemAgeiKguWljyIpXSkKICAgICAgICBpZiBub3QgbW9kZToKICAgICAgICAgICAg
cmV0dXJuCiAgICAgICAgdmFsdWVzICs9IFsiLS1tb2RlIiwgbW9kZV0KICAgICAgICBpZiBtb2Rl
ID09ICJmcSI6CiAgICAgICAgICAgIHZhbHVlcyArPSBbIi0tbWF4cmF0ZS1tYnBzIiwgX2Fzaygi
5q+P5rWBIE1icHPvvIzovpPlhaUgbm9uZSDlj5bmtojpop3lpJbkuIrpmZAiLCAibm9uZSIpXQog
ICAgICAgIGVsc2U6CiAgICAgICAgICAgIHZhbHVlcyArPSBbIi0tcmF0ZS1tYnBzIiwgX2Fzaygi
572R5Y2h5oC75Ye65Y+jIE1icHMiKSwKICAgICAgICAgICAgICAgICAgICAgICAiLS1idXJzdC1r
aWIiLCBfYXNrKCLlhYHorrjnqoHlj5Hph48gS2lC77yI5Y+v57yW6L6R6LW354K577yJIiwgIjY0
IildCiAgICAgICAgICAgIGlmIG1vZGUgPT0gInRiZiI6CiAgICAgICAgICAgICAgICB2YWx1ZXMg
Kz0gWyItLWxhdGVuY3ktbXMiLCBfYXNrKCJGSUZPIOaOkumYn+mihOeulyBtc++8iOS4jeaYr+er
r+WIsOerr+aXtuW7tu+8iSIsICI1MCIpXQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAg
ICAgdmFsdWVzICs9IFsiLS1xdWV1ZS1wYWNrZXRzIiwgX2FzaygiZnEg5oC76ZmQ6ZW/77yM5YyF
5pWwIiwgIjEwMjQiKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIi0tZmxvdy1saW1pdCIs
IF9hc2soImZxIOavj+a1gemZkOmVv++8jOWMheaVsCIsICIxMDAiKV0KICAgICAgICAgICAgICAg
IHByaW50KCLkvb/nlKggZnEg5a2Q6Zif5YiX5ZCO5oyJ5YyF5pWw5o6S6Zif77yM5LiN5om/6K+6
5Zu65a6a5q+r56eS562J5b6F5LiK6ZmQ44CCIikKICAgIF9tZW51X2FjdGlvbih2YWx1ZXMsIGN0
eCkKCgpkZWYgX3BvcnRfbWVudShjdHgpOgogICAgc2VsZWN0aW9uID0gX2Nob29zZSgi6L+U5Zue
5a6i5oi356uv55qE56uv5Y+j6ZmQ6YCfIiwgWygibGlzdCIsICLmn6XnnIvop4TliJkiKSwgKCJz
ZXQiLCAi5re75Yqg5oiW5L+u5pS56KeE5YiZIiksICgiZGVsZXRlIiwgIuWIoOmZpOinhOWImSIp
XSkKICAgIGlmIG5vdCBzZWxlY3Rpb246CiAgICAgICAgcmV0dXJuCiAgICBpZiBzZWxlY3Rpb24g
PT0gImxpc3QiOgogICAgICAgIHJldHVybiBfbWVudV9hY3Rpb24oWyJwb3J0IiwgImxpc3QiXSwg
Y3R4KQogICAgaWYgc2VsZWN0aW9uID09ICJkZWxldGUiOgogICAgICAgIHJ1bGVzID0gUG9ydE1h
bmFnZXIoY3R4KS5saXN0KCkuZ2V0KCJydWxlcyIsIHt9KQogICAgICAgIHJ1bGVfaWQgPSBfY2hv
b3NlKCLpgInmi6nop4TliJkiLCBbKGtleSwgZiJ7a2V5fToge3J1bGVbJ2ludGVyZmFjZSddfTp7
cnVsZVsncG9ydCddfS97cnVsZVsncHJvdG9jb2wnXX0iKSBmb3Iga2V5LCBydWxlIGluIHNvcnRl
ZChydWxlcy5pdGVtcygpKV0pCiAgICAgICAgaWYgcnVsZV9pZDoKICAgICAgICAgICAgcmV0dXJu
IF9tZW51X2FjdGlvbihbInBvcnQiLCAiZGVsZXRlIiwgIi0taWQiLCBydWxlX2lkXSwgY3R4KQog
ICAgICAgIHJldHVybgogICAgaW50ZXJmYWNlID0gX3NlbGVjdF9pbnRlcmZhY2UoY3R4KQogICAg
aWYgbm90IGludGVyZmFjZToKICAgICAgICByZXR1cm4KICAgIHJ1bGVfaWQgPSBfYXNrKCLop4Tl
iJnlkI3np7AgSUTvvIjnm7jlkIwgSUQg6KGo56S65L+u5pS577yJIikKICAgIHBvcnQgPSBfYXNr
KCLmnKzmnLrmnI3liqHmupDnq6/lj6PvvJtwbzAg5aGr6L+U5Zue5a6i5oi356uv55qE5YWl5Y+j
56uv5Y+jIikKICAgIHByb3RvY29sID0gX2Nob29zZSgi5Y2P6K6uIiwgWygidGNwIiwgIlRDUCIp
LCAoInVkcCIsICJVRFAg5rGH5oC7IiksICgiYm90aCIsICJUQ1DvvItVRFAg5YWx5Lqr5rGH5oC7
IildKQogICAgaWYgbm90IHByb3RvY29sOgogICAgICAgIHJldHVybgogICAgZmFtaWx5ID0gX2No
b29zZSgi5Zyw5Z2A5pePIiwgWygiYm90aCIsICJJUHY077yLSVB2NiDlhbHkuqvkuIrpmZAiKSwg
KCJpcHY0IiwgIklQdjQiKSwgKCJpcHY2IiwgIklQdjYiKV0pCiAgICBpZiBub3QgZmFtaWx5Ogog
ICAgICAgIHJldHVybgogICAgbW9kZSA9ICJ0b3RhbCIKICAgIGlmIHByb3RvY29sID09ICJ0Y3Ai
OgogICAgICAgIG1vZGUgPSBfY2hvb3NlKCLpmZDpgJ/mlrnlvI8iLCBbKCJ0b3RhbCIsICLmiYDm
nInov57mjqXlhbHkuqvnq6/lj6PmgLvpop0iKSwgKCJmbG93IiwgIuavj+adoSBUQ1Ag6L+e5o6l
5Y+R6YCB6IqC5aWPIiksICgiYm90aCIsICLnq6/lj6PmgLvpop3kuI7mr4/ov57mjqXkuIrpmZDl
kIzml7borr7nva4iKV0pCiAgICAgICAgaWYgbm90IG1vZGU6CiAgICAgICAgICAgIHJldHVybgog
ICAgdmFsdWVzID0gWyJwb3J0IiwgInNldCIsICItLWlkIiwgcnVsZV9pZCwgIi0taW50ZXJmYWNl
IiwgaW50ZXJmYWNlLAogICAgICAgICAgICAgICItLXBvcnQiLCBwb3J0LCAiLS1wcm90b2NvbCIs
IHByb3RvY29sLCAiLS1mYW1pbHkiLCBmYW1pbHldCiAgICBpZiBtb2RlIGluICgidG90YWwiLCAi
Ym90aCIpOgogICAgICAgIHZhbHVlcyArPSBbIi0tdG90YWwtbWJwcyIsIF9hc2soIuerr+WPo+ax
h+aAuyBNYnBzIildCiAgICBpZiBtb2RlIGluICgiZmxvdyIsICJib3RoIik6CiAgICAgICAgdmFs
dWVzICs9IFsiLS1mbG93LW1icHMiLCBfYXNrKCLmr48gVENQIOa1gSBNYnBzIildCiAgICBwcmlu
dCgi6K+l6KeE5YiZ5LiN6ZmQ5Yi25YWl5pa55ZCR77yM5Lmf5LiN5Lya6Ieq5Yqo6Lef6ZqP5Luj
55CG6IqC54K556uv5Y+j5Y+Y5YyW44CCIikKICAgIF9tZW51X2FjdGlvbih2YWx1ZXMsIGN0eCkK
CgpkZWYgbWVudShjdHgpOgogICAgd2hpbGUgVHJ1ZToKICAgICAgICBzZWxlY3Rpb24gPSBfY2hv
b3NlKCLnvZHnu5zosIPkvJgiLCBbCiAgICAgICAgICAgICgiYnVmZmVyIiwgIlRDUCDnvJPlhrLl
jLoiKSwgKCJlZ3Jlc3MiLCAi5Ye65Y+j5pW05b2iIiksCiAgICAgICAgICAgICgicG9ydCIsICLn
q6/lj6PpmZDpgJ8iKSwgKCJzdGF0dXMiLCAi5p+l55yL5a6M5pW054q25oCBIiksCiAgICAgICAg
ICAgICgiZGlhZ25vc2UiLCAi6KKr5Yqo6K+K5pat77yI5LiN5rWL6YCf77yJIiksCiAgICAgICAg
XSkKICAgICAgICBpZiBzZWxlY3Rpb24gaXMgTm9uZToKICAgICAgICAgICAgcmV0dXJuIDAKICAg
ICAgICB0cnk6CiAgICAgICAgICAgIGlmIHNlbGVjdGlvbiA9PSAiYnVmZmVyIjoKICAgICAgICAg
ICAgICAgIF9idWZmZXJfbWVudShjdHgpCiAgICAgICAgICAgIGVsaWYgc2VsZWN0aW9uID09ICJl
Z3Jlc3MiOgogICAgICAgICAgICAgICAgX2VncmVzc19tZW51KGN0eCkKICAgICAgICAgICAgZWxp
ZiBzZWxlY3Rpb24gPT0gInBvcnQiOgogICAgICAgICAgICAgICAgX3BvcnRfbWVudShjdHgpCiAg
ICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAgICB2YWx1ZXMgPSBbc2VsZWN0aW9uXQogICAg
ICAgICAgICAgICAgaWYgc2VsZWN0aW9uID09ICJkaWFnbm9zZSI6CiAgICAgICAgICAgICAgICAg
ICAgdmFsdWVzICs9IFsiLS1zZWNvbmRzIiwgX2Fzaygi6KeC5a+f56eS5pWw77yMMSDoh7MgNjAi
LCAiMTAiKV0KICAgICAgICAgICAgICAgIF9tZW51X2FjdGlvbih2YWx1ZXMsIGN0eCkKICAgICAg
ICBleGNlcHQgVHVuZUVycm9yIGFzIGVycm9yOgogICAgICAgICAgICBwcmludCgiW+mUmeivr10g
IiArIHN0cihlcnJvciksIGZpbGU9c3lzLnN0ZGVycikKCgpkZWYgX2ludGVycnVwdGVkKHNpZ251
bSwgZnJhbWUpOgogICAgcmFpc2UgVHVuZUVycm9yKCLmk43kvZzooqvkuK3mlq0iLCAxMzApCgoK
ZGVmIG1haW4oYXJndj1Ob25lKToKICAgIHRyeToKICAgICAgICBpZiBzeXMudmVyc2lvbl9pbmZv
IDwgKDMsIDkpOgogICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIue9kee7nOiwg+S8mOmcgOim
gSBQeXRob24gMy45IOaIluabtOaWsOeJiOacrCIsIDMpCiAgICAgICAgYXJncyA9IHBhcnNlcigp
LnBhcnNlX2FyZ3MoYXJndikKICAgICAgICBmb3IgZmxhZywgbmFtZSBpbiAoKCJxdWlldCIsICJW
UFNDVExfUVVJRVQiKSwgKCJ2ZXJib3NlIiwgIlZQU0NUTF9WRVJCT1NFIiksCiAgICAgICAgICAg
ICAgICAgICAgICAgICAgICgibm9fY29sb3IiLCAiVlBTQ1RMX05PX0NPTE9SIiksICgiaW5zdGFs
bF9kZXBzIiwgIlZQU0NUTF9JTlNUQUxMX0RFUFMiKSk6CiAgICAgICAgICAgIGlmIGdldGF0dHIo
YXJncywgZmxhZywgRmFsc2UpOgogICAgICAgICAgICAgICAgb3MuZW52aXJvbltuYW1lXSA9ICIx
IgogICAgICAgIGN0eCA9IENvbnRleHQoZHJ5X3J1bj1nZXRhdHRyKGFyZ3MsICJkcnlfcnVuIiwg
Tm9uZSksIGFzc3VtZV95ZXM9Z2V0YXR0cihhcmdzLCAieWVzIiwgTm9uZSksCiAgICAgICAgICAg
ICAgICAgICAgICBub25faW50ZXJhY3RpdmU9Z2V0YXR0cihhcmdzLCAibm9uX2ludGVyYWN0aXZl
IiwgTm9uZSksCiAgICAgICAgICAgICAgICAgICAgICBqc29uX291dHB1dD1nZXRhdHRyKGFyZ3Ms
ICJqc29uIiwgRmFsc2UpKQogICAgICAgIGZvciBuYW1lIGluICgiU0lHSU5UIiwgIlNJR1RFUk0i
LCAiU0lHSFVQIik6CiAgICAgICAgICAgIGlmIGhhc2F0dHIoc2lnbmFsLCBuYW1lKToKICAgICAg
ICAgICAgICAgIHNpZ25hbC5zaWduYWwoZ2V0YXR0cihzaWduYWwsIG5hbWUpLCBfaW50ZXJydXB0
ZWQpCiAgICAgICAgaWYgbm90IGFyZ3MuZ3JvdXAgYW5kIHN5cy5zdGRpbi5pc2F0dHkoKSBhbmQg
c3lzLnN0ZG91dC5pc2F0dHkoKSBhbmQgbm90IGN0eC5ub25faW50ZXJhY3RpdmUgYW5kIG5vdCBj
dHguanNvbl9vdXRwdXQ6CiAgICAgICAgICAgIHJldHVybiBtZW51KGN0eCkKICAgICAgICBpZiBh
cmdzLmdyb3VwID09ICJpbnRlcm5hbCI6CiAgICAgICAgICAgIGN0eC5hc3N1bWVfeWVzID0gVHJ1
ZQogICAgICAgICAgICBjdHgubm9uX2ludGVyYWN0aXZlID0gVHJ1ZQogICAgICAgIHJlc3VsdCA9
IGRpc3BhdGNoKGN0eCwgYXJncykKICAgICAgICByZW5kZXIocmVzdWx0LCBhcmdzLCBjdHgpCiAg
ICAgICAgcmV0dXJuIDAKICAgIGV4Y2VwdCBUdW5lRXJyb3IgYXMgZXJyb3I6CiAgICAgICAgcHJp
bnQoIlvplJnor69dICIgKyBzdHIoZXJyb3IpLCBmaWxlPXN5cy5zdGRlcnIpCiAgICAgICAgcmV0
dXJuIGVycm9yLmNvZGUKICAgIGV4Y2VwdCBLZXlib2FyZEludGVycnVwdDoKICAgICAgICBwcmlu
dCgi5pON5L2c5bey5Y+W5raI44CCIiwgZmlsZT1zeXMuc3RkZXJyKQogICAgICAgIHJldHVybiAx
MzAKICAgIGV4Y2VwdCBCcm9rZW5QaXBlRXJyb3I6CiAgICAgICAgcmV0dXJuIDEzMApQSwMEFAAA
AAAAAAAhUDBXD41JRAAASUQAABYAAABuZXR3b3JrX3R1bmUvY29tbW9uLnB5IiIiU2hhcmVkIHN0
YW5kYXJkLWxpYnJhcnkgcnVudGltZSBmb3IgbG9jYWwgbmV0d29yayB0dW5pbmcuIiIiCmZyb20g
X19mdXR1cmVfXyBpbXBvcnQgYW5ub3RhdGlvbnMKCmltcG9ydCBiYXNlNjQKaW1wb3J0IGNvbnRl
eHRsaWIKaW1wb3J0IGRlY2ltYWwKaW1wb3J0IGZjbnRsCmltcG9ydCBoYXNobGliCmltcG9ydCBp
bXBvcnRsaWIucmVzb3VyY2VzCmltcG9ydCBpbwppbXBvcnQganNvbgppbXBvcnQgb3MKZnJvbSBw
YXRobGliIGltcG9ydCBQYXRoCmltcG9ydCByZQppbXBvcnQgc2h1dGlsCmltcG9ydCBzdGF0Cmlt
cG9ydCBzdWJwcm9jZXNzCmltcG9ydCBzeXMKaW1wb3J0IHRlbXBmaWxlCmltcG9ydCB0aW1lCmlt
cG9ydCB6aXBmaWxlCgpTQ0hFTUFfVkVSU0lPTiA9IDEKUEFDS0FHRV9GSUxFUyA9ICgKICAgICJf
X2luaXRfXy5weSIsICJfX21haW5fXy5weSIsICJjb21tb24ucHkiLCAiYnVmZmVycy5weSIsCiAg
ICAiZWdyZXNzLnB5IiwgInBvcnRzLnB5IiwgImNsaS5weSIsCikKTUlCID0gMTAyNCAqIDEwMjQK
TUFOQUdFRF9NQVJLRVIgPSAiTWFuYWdlZCBieSB2cHNjdGwgbmV0d29yayB0dW5lIgpSVU5USU1F
X01BUktFUiA9IChNQU5BR0VEX01BUktFUiArICIgcnVudGltZSB2MSIpLmVuY29kZSgiYXNjaWki
KQoKCmNsYXNzIFR1bmVFcnJvcihFeGNlcHRpb24pOgogICAgZGVmIF9faW5pdF9fKHNlbGYsIG1l
c3NhZ2UsIGNvZGU9MTApOgogICAgICAgIHN1cGVyKCkuX19pbml0X18obWVzc2FnZSkKICAgICAg
ICBzZWxmLmNvZGUgPSBjb2RlCgoKZGVmIHRydXRoKHZhbHVlKToKICAgIHJldHVybiBzdHIodmFs
dWUgb3IgIiIpLmxvd2VyKCkgaW4gKCIxIiwgInRydWUiLCAieWVzIiwgIm9uIikKCgpkZWYgcGFy
c2VfbWJwcyh2YWx1ZSk6CiAgICB0cnk6CiAgICAgICAgbnVtYmVyID0gZGVjaW1hbC5EZWNpbWFs
KHN0cih2YWx1ZSkpCiAgICAgICAgaWYgbm90IG51bWJlci5pc19maW5pdGUoKSBvciBudW1iZXIg
PD0gMDoKICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJvcgogICAgICAgIGlmIG51bWJlciA8IGRl
Y2ltYWwuRGVjaW1hbCgnMC4wMDAwMDEnKSBvciBudW1iZXIgPiBkZWNpbWFsLkRlY2ltYWwoMioq
NjMgLSAxKS5zY2FsZWIoLTYpOgogICAgICAgICAgICByYWlzZSBWYWx1ZUVycm9yCiAgICAgICAg
d2l0aCBkZWNpbWFsLmxvY2FsY29udGV4dCgpIGFzIHByZWNpc2lvbjoKICAgICAgICAgICAgcHJl
Y2lzaW9uLnByZWMgPSBtYXgoMjgsIGxlbihudW1iZXIuYXNfdHVwbGUoKS5kaWdpdHMpICsgMTIp
CiAgICAgICAgICAgIHJlc3VsdCA9IG51bWJlciAqIDFfMDAwXzAwMAogICAgICAgICAgICBpZiBy
ZXN1bHQgIT0gcmVzdWx0LnRvX2ludGVncmFsX3ZhbHVlKCk6CiAgICAgICAgICAgICAgICByYWlz
ZSBWYWx1ZUVycm9yCiAgICAgICAgcmV0dXJuIGludChyZXN1bHQpCiAgICBleGNlcHQgKGRlY2lt
YWwuSW52YWxpZE9wZXJhdGlvbiwgVmFsdWVFcnJvciwgVHlwZUVycm9yKToKICAgICAgICByYWlz
ZSBUdW5lRXJyb3IoIuW4puWuveW/hemhu+aYr+ato+aVsCBNYnBz77yM57K+5bqm5LiN6IO95bCP
5LqOIDEgYml0L3MiLCAyKQoKCmRlZiBwYXJzZV9zaXplKHZhbHVlKToKICAgIGlmIGlzaW5zdGFu
Y2UodmFsdWUsIGludCk6CiAgICAgICAgaWYgdmFsdWUgPCAwOgogICAgICAgICAgICByYWlzZSBU
dW5lRXJyb3IoIuWuuemHj+S4jeiDveS4uui0n+aVsCIsIDIpCiAgICAgICAgcmV0dXJuIHZhbHVl
CiAgICBtYXRjaCA9IHJlLmZ1bGxtYXRjaChyIlxzKihcZCsoPzpcLlxkKyk/KVxzKihCfEtpQnxN
aUJ8R2lCfEt8TXxHKT9ccyoiLAogICAgICAgICAgICAgICAgICAgICAgICAgc3RyKHZhbHVlKSwg
cmUuSUdOT1JFQ0FTRSkKICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICByYWlzZSBUdW5lRXJyb3Io
IuWuuemHj+agvOW8j+aXoOaViO+8m+S9v+eUqOWtl+iKguaVtOaVsOaIliBLaUIvTWlCL0dpQiIs
IDIpCiAgICB1bml0ID0gKG1hdGNoLmdyb3VwKDIpIG9yICJiIikubG93ZXIoKQogICAgcG93ZXIg
PSB7ImIiOiAwLCAiayI6IDEsICJraWIiOiAxLCAibSI6IDIsICJtaWIiOiAyLCAiZyI6IDMsICJn
aWIiOiAzfVt1bml0XQogICAgY29lZmZpY2llbnQgPSBkZWNpbWFsLkRlY2ltYWwobWF0Y2guZ3Jv
dXAoMSkpCiAgICB3aXRoIGRlY2ltYWwubG9jYWxjb250ZXh0KCkgYXMgcHJlY2lzaW9uOgogICAg
ICAgIHByZWNpc2lvbi5wcmVjID0gbWF4KDI4LCBsZW4oY29lZmZpY2llbnQuYXNfdHVwbGUoKS5k
aWdpdHMpICsgMTIpCiAgICAgICAgbnVtYmVyID0gY29lZmZpY2llbnQgKiAoMTAyNCAqKiBwb3dl
cikKICAgICAgICBpZiBudW1iZXIgIT0gbnVtYmVyLnRvX2ludGVncmFsX3ZhbHVlKCkgb3IgbnVt
YmVyID4gMioqNjMgLSAxOgogICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuWuuemHj+W/hemh
u+iDveihqOekuuS4uuWujOaVtOWtl+iKguS4lOWcqOaUr+aMgeiMg+WbtOWGhSIsIDIpCiAgICBy
ZXR1cm4gaW50KG51bWJlcikKCgpkZWYgdmFsaWRfaW50ZXJmYWNlKHZhbHVlKToKICAgIGlmIG5v
dCBpc2luc3RhbmNlKHZhbHVlLCBzdHIpIG9yIG5vdCByZS5mdWxsbWF0Y2gociJbQS1aYS16MC05
X11bQS1aYS16MC05Xy46LV17MCwxNH0iLCB2YWx1ZSk6CiAgICAgICAgcmFpc2UgVHVuZUVycm9y
KCLnvZHljaHlkI3np7Dml6DmlYgiLCAyKQogICAgcmV0dXJuIHZhbHVlCgoKZGVmIHZhbGlkX2lk
KHZhbHVlKToKICAgIGlmIG5vdCBpc2luc3RhbmNlKHZhbHVlLCBzdHIpIG9yIG5vdCByZS5mdWxs
bWF0Y2gociJbQS1aYS16MC05XVtBLVphLXowLTlfLi1dezAsNDd9IiwgdmFsdWUpOgogICAgICAg
IHJhaXNlIFR1bmVFcnJvcigi6KeE5YiZIElEIOWPquiDveWMheWQq+Wtl+avjeOAgeaVsOWtl+OA
geeCueOAgeefreaoque6v+WSjOS4i+WIkue6v++8jOacgOmVvyA0OCDlrZfnrKYiLCAyKQogICAg
cmV0dXJuIHZhbHVlCgoKZGVmIHJ1bnRpbWVfYXJjaGl2ZSgpOgogICAgIiIiRGV0ZXJtaW5pc3Rp
YyBleGVjdXRhYmxlIHppcCwgYWxzbyBlbWJlZGRlZCBpbiB0aGUgc3RhbmRhbG9uZSBQTzAgZmls
ZS4iIiIKICAgIGRhdGEgPSBpby5CeXRlc0lPKCkKICAgIHJvb3RfbWFpbiA9IGIiZnJvbSBuZXR3
b3JrX3R1bmUuY2xpIGltcG9ydCBtYWluXG5yYWlzZSBTeXN0ZW1FeGl0KG1haW4oKSlcbiIKICAg
IHdpdGggemlwZmlsZS5aaXBGaWxlKGRhdGEsICJ3IiwgY29tcHJlc3Npb249emlwZmlsZS5aSVBf
U1RPUkVEKSBhcyBhcmNoaXZlOgogICAgICAgIGFyY2hpdmUuY29tbWVudCA9IFJVTlRJTUVfTUFS
S0VSCiAgICAgICAgbWVtYmVycyA9IHsiX19tYWluX18ucHkiOiByb290X21haW59CiAgICAgICAg
cGFja2FnZSA9IGltcG9ydGxpYi5yZXNvdXJjZXMuZmlsZXMoIm5ldHdvcmtfdHVuZSIpCiAgICAg
ICAgZm9yIG5hbWUgaW4gUEFDS0FHRV9GSUxFUzoKICAgICAgICAgICAgbWVtYmVyc1sibmV0d29y
a190dW5lLyIgKyBuYW1lXSA9IHBhY2thZ2Uuam9pbnBhdGgobmFtZSkucmVhZF9ieXRlcygpCiAg
ICAgICAgZm9yIG5hbWUsIGNvbnRlbnQgaW4gc29ydGVkKG1lbWJlcnMuaXRlbXMoKSk6CiAgICAg
ICAgICAgIGluZm8gPSB6aXBmaWxlLlppcEluZm8obmFtZSwgZGF0ZV90aW1lPSgyMDIwLCAxLCAx
LCAwLCAwLCAwKSkKICAgICAgICAgICAgaW5mby5jb21wcmVzc190eXBlID0gemlwZmlsZS5aSVBf
U1RPUkVECiAgICAgICAgICAgIGluZm8uY3JlYXRlX3N5c3RlbSA9IDMKICAgICAgICAgICAgaW5m
by5leHRlcm5hbF9hdHRyID0gMG8xMDA2NDQgPDwgMTYKICAgICAgICAgICAgYXJjaGl2ZS53cml0
ZXN0cihpbmZvLCBjb250ZW50LCBjb21wcmVzc190eXBlPXppcGZpbGUuWklQX1NUT1JFRCkKICAg
IHJldHVybiBkYXRhLmdldHZhbHVlKCkKCgpjbGFzcyBDb250ZXh0OgogICAgZGVmIF9faW5pdF9f
KHNlbGYsIGRyeV9ydW49Tm9uZSwgYXNzdW1lX3llcz1Ob25lLCBub25faW50ZXJhY3RpdmU9Tm9u
ZSwganNvbl9vdXRwdXQ9RmFsc2UpOgogICAgICAgIHNlbGYudGVzdGluZyA9IG9zLmVudmlyb24u
Z2V0KCJWUFNDVExfVEVTVElORyIpID09ICIxIgogICAgICAgIHJvb3QgPSBvcy5lbnZpcm9uLmdl
dCgiVlBTQ1RMX1NZU1RFTV9ST09UIiwgIiIpIGlmIHNlbGYudGVzdGluZyBlbHNlICIiCiAgICAg
ICAgaWYgc2VsZi50ZXN0aW5nIGFuZCByb290OgogICAgICAgICAgICBjYW5kaWRhdGUgPSBQYXRo
KHJvb3QpCiAgICAgICAgICAgIGlmIG5vdCBjYW5kaWRhdGUuaXNfYWJzb2x1dGUoKSBvciAiLi4i
IGluIGNhbmRpZGF0ZS5wYXJ0cyBvciBjYW5kaWRhdGUgPT0gUGF0aCgiLyIpOgogICAgICAgICAg
ICAgICAgcmFpc2UgVHVuZUVycm9yKCLmtYvor5Xns7vnu5/moLnnm67lvZXlv4XpobvkuLrmmI7n
oa7nmoTnu53lr7npmpTnprvnm67lvZUiLCAyKQogICAgICAgICAgICBzZWxmLnJvb3QgPSBjYW5k
aWRhdGUKICAgICAgICBlbHNlOgogICAgICAgICAgICBzZWxmLnJvb3QgPSBQYXRoKCIvIikKICAg
ICAgICBzZWxmLmRyeV9ydW4gPSB0cnV0aChvcy5lbnZpcm9uLmdldCgiVlBTQ1RMX0RSWV9SVU4i
KSkgaWYgZHJ5X3J1biBpcyBOb25lIGVsc2UgZHJ5X3J1bgogICAgICAgIHNlbGYuYXNzdW1lX3ll
cyA9IHRydXRoKG9zLmVudmlyb24uZ2V0KCJWUFNDVExfQVNTVU1FX1lFUyIpKSBpZiBhc3N1bWVf
eWVzIGlzIE5vbmUgZWxzZSBhc3N1bWVfeWVzCiAgICAgICAgc2VsZi5ub25faW50ZXJhY3RpdmUg
PSB0cnV0aChvcy5lbnZpcm9uLmdldCgiVlBTQ1RMX05PTl9JTlRFUkFDVElWRSIpKSBpZiBub25f
aW50ZXJhY3RpdmUgaXMgTm9uZSBlbHNlIG5vbl9pbnRlcmFjdGl2ZQogICAgICAgIHNlbGYuanNv
bl9vdXRwdXQgPSBqc29uX291dHB1dAogICAgICAgIHNlbGYucXVpZXQgPSB0cnV0aChvcy5lbnZp
cm9uLmdldCgiVlBTQ1RMX1FVSUVUIikpCiAgICAgICAgc2VsZi5zdGF0ZV9kaXIgPSBzZWxmLnBh
dGgoIi92YXIvbGliL3Zwc2N0bC9uZXR3b3JrL3R1bmUiKQogICAgICAgIHNlbGYucnVudGltZV9w
YXRoID0gc2VsZi5wYXRoKCIvdXNyL2xvY2FsL2xpYi92cHNjdGwvbmV0d29yay10dW5lL3J1bnRp
bWUucHl6IikKICAgICAgICBzZWxmLmxvY2tfd2FpdF9zZWNvbmRzID0gMAogICAgICAgIHNlbGYu
X2RlZmVycmVkX3VuaXRfc3RhcnRzID0gTm9uZQoKICAgIGRlZiBwYXRoKHNlbGYsIGxvZ2ljYWwp
OgogICAgICAgIHZhbHVlID0gUGF0aChsb2dpY2FsKQogICAgICAgIGlmIG5vdCB2YWx1ZS5pc19h
YnNvbHV0ZSgpIG9yICIuLiIgaW4gdmFsdWUucGFydHM6CiAgICAgICAgICAgIHJhaXNlIFR1bmVF
cnJvcigi57O757uf6Lev5b6E5b+F6aG75Li65LiN5ZCr5LiK57qn6Lez6L2s55qE57ud5a+56Lev
5b6EIiwgMTApCiAgICAgICAgcmV0dXJuIHNlbGYucm9vdCAvIHN0cih2YWx1ZSkubHN0cmlwKCIv
IikgaWYgc2VsZi5yb290ICE9IFBhdGgoIi8iKSBlbHNlIHZhbHVlCgogICAgZGVmIHNhZmVfcGF0
aChzZWxmLCBwYXRoKToKICAgICAgICBwYXRoID0gUGF0aChwYXRoKQogICAgICAgIGlmIG5vdCBw
YXRoLmlzX2Fic29sdXRlKCkgb3IgIi4uIiBpbiBwYXRoLnBhcnRzOgogICAgICAgICAgICByYWlz
ZSBUdW5lRXJyb3IoIuaLkue7neS4jeWuieWFqOeahOaWh+S7tui3r+W+hCIsIDEwKQogICAgICAg
IGlmIHNlbGYucm9vdCAhPSBQYXRoKCIvIikgYW5kIHBhdGggIT0gc2VsZi5yb290IGFuZCBzZWxm
LnJvb3Qgbm90IGluIHBhdGgucGFyZW50czoKICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLm
tYvor5Xmk43kvZzotoXlh7rpmpTnprvns7vnu5/nm67lvZUiLCAxMCkKICAgICAgICBmb3IgY3Vy
cmVudCBpbiBbcGF0aCwgKnBhdGgucGFyZW50c106CiAgICAgICAgICAgIGlmIGN1cnJlbnQuaXNf
c3ltbGluaygpOgogICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLlj5fnrqHmlofku7bo
t6/lvoTljIXlkKvnrKblj7fpk77mjqXvvJoiICsgc3RyKGN1cnJlbnQpLCAxMCkKICAgICAgICBy
ZXR1cm4gcGF0aAoKICAgIGRlZiBydW4oc2VsZiwgYXJndiwgY2hlY2s9VHJ1ZSwgaW5wdXQ9Tm9u
ZSwgdGltZW91dD0xNSk6CiAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UoYXJndiwgKHR1cGxlLCBs
aXN0KSkgb3Igbm90IGFyZ3Y6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5YaF6YOo5ZG9
5Luk5b+F6aG75L2/55So5piO56Gu5Y+C5pWw5YiX6KGoIiwgNzApCiAgICAgICAgY29tbWFuZCA9
IFtzdHIoeCkgZm9yIHggaW4gYXJndl0KICAgICAgICB0cnk6CiAgICAgICAgICAgIHJlc3VsdCA9
IHN1YnByb2Nlc3MucnVuKGNvbW1hbmQsIGlucHV0PWlucHV0LCB0ZXh0PVRydWUsIGNhcHR1cmVf
b3V0cHV0PVRydWUsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHRpbWVvdXQ9
dGltZW91dCwgZW52PW9zLmVudmlyb24uY29weSgpKQogICAgICAgIGV4Y2VwdCBGaWxlTm90Rm91
bmRFcnJvcjoKICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLnvLrlsJHlkb3ku6TvvJoiICsg
Y29tbWFuZFswXSwgMykKICAgICAgICBleGNlcHQgc3VicHJvY2Vzcy5UaW1lb3V0RXhwaXJlZDoK
ICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLlkb3ku6TotoXml7bvvJoiICsgIiAiLmpvaW4o
Y29tbWFuZFs6NV0pLCAyMCkKICAgICAgICBpZiBjaGVjayBhbmQgcmVzdWx0LnJldHVybmNvZGU6
CiAgICAgICAgICAgIGRldGFpbCA9IChyZXN1bHQuc3RkZXJyIG9yIHJlc3VsdC5zdGRvdXQpLnN0
cmlwKClbOjE4MDBdCiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5ZG95Luk5aSx6LSl77ya
IiArICIgIi5qb2luKGNvbW1hbmRbOjZdKSArICgiOiAiICsgZGV0YWlsIGlmIGRldGFpbCBlbHNl
ICIiKSwgMjApCiAgICAgICAgcmV0dXJuIHJlc3VsdAoKICAgIGRlZiBtdXRhdGUoc2VsZiwgYXJn
diwgKiprd2FyZ3MpOgogICAgICAgIGlmIHNlbGYuZHJ5X3J1bjoKICAgICAgICAgICAgcmFpc2Ug
VHVuZUVycm9yKCLlhoXpg6jplJnor6/vvJrmvJTnu4PkuK3lsJ3or5XmiafooYzlhpnlkb3ku6Qi
LCA3MCkKICAgICAgICByZXR1cm4gc2VsZi5ydW4oYXJndiwgKiprd2FyZ3MpCgogICAgZGVmIHJl
YWRfanNvbihzZWxmLCBwYXRoLCBkZWZhdWx0PU5vbmUpOgogICAgICAgIHBhdGggPSBzZWxmLnNh
ZmVfcGF0aChwYXRoKQogICAgICAgIGlmIG5vdCBwYXRoLmV4aXN0cygpOgogICAgICAgICAgICBy
ZXR1cm4gZGVmYXVsdAogICAgICAgIGlmIG5vdCBwYXRoLmlzX2ZpbGUoKToKICAgICAgICAgICAg
cmFpc2UgVHVuZUVycm9yKCLlj5fnrqHnirbmgIHkuI3mmK/mma7pgJrmlofku7bvvJoiICsgc3Ry
KHBhdGgpLCAxMCkKICAgICAgICB0cnk6CiAgICAgICAgICAgIHJldHVybiBqc29uLmxvYWRzKHBh
dGgucmVhZF90ZXh0KGVuY29kaW5nPSJ1dGYtOCIpKQogICAgICAgIGV4Y2VwdCBQZXJtaXNzaW9u
RXJyb3I6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5peg5p2D6K+75Y+W5Y+X566h54q2
5oCB77yaIiArIHN0cihwYXRoKSwgNCkKICAgICAgICBleGNlcHQgKFZhbHVlRXJyb3IsIE9TRXJy
b3IpIGFzIGVycm9yOgogICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaXoOazleivu+WPluWP
l+euoeeKtuaAge+8miIgKyBzdHIocGF0aCkgKyAiOiAiICsgc3RyKGVycm9yKSwgMTApCgogICAg
ZGVmIGF0b21pY193cml0ZShzZWxmLCBwYXRoLCBjb250ZW50LCBtb2RlPTBvNjAwKToKICAgICAg
ICBpZiBzZWxmLmRyeV9ydW46CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5YaF6YOo6ZSZ
6K+v77ya5ryU57uD5Lit5bCd6K+V5YaZ5paH5Lu2IiwgNzApCiAgICAgICAgcGF0aCA9IHNlbGYu
c2FmZV9wYXRoKHBhdGgpCiAgICAgICAgaWYgcGF0aC5leGlzdHMoKSBhbmQgbm90IHBhdGguaXNf
ZmlsZSgpOgogICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuWPl+euoeebruagh+S4jeaYr+aZ
rumAmuaWh+S7tu+8miIgKyBzdHIocGF0aCksIDEwKQogICAgICAgIHJhdyA9IGNvbnRlbnQuZW5j
b2RlKCJ1dGYtOCIpIGlmIGlzaW5zdGFuY2UoY29udGVudCwgc3RyKSBlbHNlIGNvbnRlbnQKICAg
ICAgICBwYXRoLnBhcmVudC5ta2RpcihwYXJlbnRzPVRydWUsIGV4aXN0X29rPVRydWUpCiAgICAg
ICAgZGVzY3JpcHRvciwgbmFtZSA9IHRlbXBmaWxlLm1rc3RlbXAocHJlZml4PSIuIiArIHBhdGgu
bmFtZSArICIuIiwgZGlyPXBhdGgucGFyZW50KQogICAgICAgIHRlbXBvcmFyeSA9IFBhdGgobmFt
ZSkKICAgICAgICB0cnk6CiAgICAgICAgICAgIHdpdGggb3MuZmRvcGVuKGRlc2NyaXB0b3IsICJ3
YiIpIGFzIG91dHB1dDoKICAgICAgICAgICAgICAgIG9zLmZjaG1vZChvdXRwdXQuZmlsZW5vKCks
IG1vZGUpCiAgICAgICAgICAgICAgICBvdXRwdXQud3JpdGUocmF3KQogICAgICAgICAgICAgICAg
b3V0cHV0LmZsdXNoKCkKICAgICAgICAgICAgICAgIG9zLmZzeW5jKG91dHB1dC5maWxlbm8oKSkK
ICAgICAgICAgICAgb3MucmVwbGFjZSh0ZW1wb3JhcnksIHBhdGgpCiAgICAgICAgZmluYWxseToK
ICAgICAgICAgICAgaWYgdGVtcG9yYXJ5LmV4aXN0cygpOgogICAgICAgICAgICAgICAgdGVtcG9y
YXJ5LnVubGluaygpCgogICAgZGVmIHdyaXRlX2pzb24oc2VsZiwgcGF0aCwgZGF0YSwgbW9kZT0w
bzYwMCk6CiAgICAgICAgc2VsZi5hdG9taWNfd3JpdGUocGF0aCwganNvbi5kdW1wcyhkYXRhLCBl
bnN1cmVfYXNjaWk9RmFsc2UsIGluZGVudD0yLCBzb3J0X2tleXM9VHJ1ZSkgKyAiXG4iLCBtb2Rl
KQoKICAgIGRlZiByZW1vdmVfZmlsZShzZWxmLCBwYXRoKToKICAgICAgICBpZiBzZWxmLmRyeV9y
dW46CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5YaF6YOo6ZSZ6K+v77ya5ryU57uD5Lit
5bCd6K+V5Yig6Zmk5paH5Lu2IiwgNzApCiAgICAgICAgcGF0aCA9IHNlbGYuc2FmZV9wYXRoKHBh
dGgpCiAgICAgICAgaWYgcGF0aC5leGlzdHMoKToKICAgICAgICAgICAgaWYgbm90IHBhdGguaXNf
ZmlsZSgpOgogICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLmi5Lnu53liKDpmaTpnZ7m
ma7pgJrlj5fnrqHmlofku7bvvJoiICsgc3RyKHBhdGgpLCAxMCkKICAgICAgICAgICAgcGF0aC51
bmxpbmsoKQoKICAgIGRlZiBzbmFwc2hvdF9maWxlKHNlbGYsIHBhdGgpOgogICAgICAgIHBhdGgg
PSBzZWxmLnNhZmVfcGF0aChwYXRoKQogICAgICAgIGlmIG5vdCBwYXRoLmV4aXN0cygpOgogICAg
ICAgICAgICByZXR1cm4geyJleGlzdHMiOiBGYWxzZX0KICAgICAgICBpZiBub3QgcGF0aC5pc19m
aWxlKCk6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5LiN6IO95L+d5a2Y6Z2e5pmu6YCa
5paH5Lu277yaIiArIHN0cihwYXRoKSwgMTApCiAgICAgICAgcmV0dXJuIHsiZXhpc3RzIjogVHJ1
ZSwgImRhdGEiOiBiYXNlNjQuYjY0ZW5jb2RlKHBhdGgucmVhZF9ieXRlcygpKS5kZWNvZGUoImFz
Y2lpIiksCiAgICAgICAgICAgICAgICAibW9kZSI6IHN0YXQuU19JTU9ERShwYXRoLnN0YXQoKS5z
dF9tb2RlKX0KCiAgICBkZWYgcmVzdG9yZV9maWxlKHNlbGYsIHBhdGgsIHNuYXBzaG90KToKICAg
ICAgICBpZiBub3QgaXNpbnN0YW5jZShzbmFwc2hvdCwgZGljdCkgb3Igbm90IGlzaW5zdGFuY2Uo
c25hcHNob3QuZ2V0KCJleGlzdHMiKSwgYm9vbCk6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJv
cigi5paH5Lu25oGi5aSN6K6w5b2V5peg5pWIIiwgMTApCiAgICAgICAgaWYgc25hcHNob3RbImV4
aXN0cyJdOgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICByYXcgPSBiYXNlNjQuYjY0
ZGVjb2RlKHNuYXBzaG90WyJkYXRhIl0sIHZhbGlkYXRlPVRydWUpCiAgICAgICAgICAgICAgICBt
b2RlID0gaW50KHNuYXBzaG90WyJtb2RlIl0pCiAgICAgICAgICAgICAgICBpZiBtb2RlIDwgMCBv
ciBtb2RlID4gMG83Nzc6CiAgICAgICAgICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJvcigibW9k
ZSIpCiAgICAgICAgICAgIGV4Y2VwdCAoS2V5RXJyb3IsIFZhbHVlRXJyb3IsIFR5cGVFcnJvcik6
CiAgICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaWh+S7tuaBouWkjeiusOW9leaNn+Wd
jyIsIDEwKQogICAgICAgICAgICBzZWxmLmF0b21pY193cml0ZShwYXRoLCByYXcsIG1vZGUpCiAg
ICAgICAgZWxzZToKICAgICAgICAgICAgc2VsZi5yZW1vdmVfZmlsZShwYXRoKQoKICAgIGRlZiBj
b25maXJtKHNlbGYsIHN1bW1hcnkpOgogICAgICAgIGlmIHNlbGYuZHJ5X3J1bjoKICAgICAgICAg
ICAgcmV0dXJuCiAgICAgICAgaWYgbm90IHNlbGYucXVpZXQ6CiAgICAgICAgICAgIHByaW50KHN1
bW1hcnksIGZpbGU9c3lzLnN0ZGVycikKICAgICAgICBpZiBzZWxmLmFzc3VtZV95ZXM6CiAgICAg
ICAgICAgIHJldHVybgogICAgICAgIGlmIHNlbGYubm9uX2ludGVyYWN0aXZlIG9yIG5vdCBzeXMu
c3RkaW4uaXNhdHR5KCk6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi6Z2e5Lqk5LqS5YaZ
5pON5L2c6ZyA6KaBIC0teWVz77yb5Y+v5YWI5L2/55SoIC0tZHJ5LXJ1biDmn6XnnIvorqHliJIi
LCAyKQogICAgICAgIHRyeToKICAgICAgICAgICAgYW5zd2VyID0gaW5wdXQoIuehruiupOW6lOeU
qOS7peS4iuWPmOabtO+8n1t5L05dICIpLnN0cmlwKCkubG93ZXIoKQogICAgICAgIGV4Y2VwdCAo
RU9GRXJyb3IsIEtleWJvYXJkSW50ZXJydXB0KToKICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9y
KCLmk43kvZzlt7Llj5bmtogiLCAxMzApCiAgICAgICAgaWYgYW5zd2VyIG5vdCBpbiAoInkiLCAi
eWVzIik6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5pON5L2c5bey5Y+W5raIIiwgMTMw
KQoKICAgIGRlZiByZXF1aXJlX211dGF0aW9uKHNlbGYpOgogICAgICAgIGlmIG5vdCBzeXMucGxh
dGZvcm0uc3RhcnRzd2l0aCgibGludXgiKToKICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLn
vZHnu5zosIPkvJjlhpnmk43kvZzku4XmlK/mjIEgTGludXgvc3lzdGVtZCIsIDMpCiAgICAgICAg
aWYgbm90IHNlbGYudGVzdGluZyBhbmQgbm90IHNlbGYuZHJ5X3J1biBhbmQgb3MuZ2V0ZXVpZCgp
ICE9IDA6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi572R57uc6LCD5LyY5YaZ5pON5L2c
6ZyA6KaBIHJvb3Qg5p2D6ZmQIiwgNCkKICAgICAgICBpZiBub3Qgc2VsZi5wYXRoKCIvcnVuL3N5
c3RlbWQvc3lzdGVtIikuaXNfZGlyKCk6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi572R
57uc6LCD5LyY5YaZ5pON5L2c6ZyA6KaBIHN5c3RlbWTvvJvlhbbku5YgTGludXgg5LuF5o+Q5L6b
5Y+q6K+75p+l6K+iIiwgMykKCiAgICBkZWYgcmVxdWlyZV90b29scyhzZWxmLCAqbmFtZXMpOgog
ICAgICAgIG1pc3NpbmcgPSBbbmFtZSBmb3IgbmFtZSBpbiBuYW1lcyBpZiBzaHV0aWwud2hpY2go
bmFtZSkgaXMgTm9uZV0KICAgICAgICBpZiBtaXNzaW5nOgogICAgICAgICAgICByYWlzZSBUdW5l
RXJyb3IoIue8uuWwkeW3peWFt++8miIgKyAi44CBIi5qb2luKG1pc3NpbmcpICsgIu+8m+ivt+S9
v+eUqCAtLWluc3RhbGwtZGVwcyDlronoo4XmiYDpnIDkvp3otZYiLCAzKQoKICAgIEBjb250ZXh0
bGliLmNvbnRleHRtYW5hZ2VyCiAgICBkZWYgbG9jayhzZWxmLCBuYW1lKToKICAgICAgICBpZiBz
ZWxmLmRyeV9ydW46CiAgICAgICAgICAgIHlpZWxkCiAgICAgICAgICAgIHJldHVybgogICAgICAg
IGlmIG5vdCByZS5mdWxsbWF0Y2gociJbYS16MC05LV0rIiwgbmFtZSk6CiAgICAgICAgICAgIHJh
aXNlIFR1bmVFcnJvcigi6ZSB5ZCN56ew5peg5pWIIiwgNzApCiAgICAgICAgdGFyZ2V0ID0gc2Vs
Zi5zYWZlX3BhdGgoc2VsZi5wYXRoKCIvcnVuL3Zwc2N0bC8iICsgbmFtZSArICIubG9jayIpKQog
ICAgICAgIHRhcmdldC5wYXJlbnQubWtkaXIocGFyZW50cz1UcnVlLCBleGlzdF9vaz1UcnVlKQog
ICAgICAgIGRlc2NyaXB0b3IgPSBvcy5vcGVuKHRhcmdldCwgb3MuT19DUkVBVCB8IG9zLk9fUkRX
UiB8IG9zLk9fTk9GT0xMT1csIDBvNjAwKQogICAgICAgIHRyeToKICAgICAgICAgICAgZGVhZGxp
bmUgPSB0aW1lLm1vbm90b25pYygpICsgc2VsZi5sb2NrX3dhaXRfc2Vjb25kcwogICAgICAgICAg
ICB3aGlsZSBUcnVlOgogICAgICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgICAgIGZj
bnRsLmZsb2NrKGRlc2NyaXB0b3IsIGZjbnRsLkxPQ0tfRVggfCBmY250bC5MT0NLX05CKQogICAg
ICAgICAgICAgICAgICAgIGJyZWFrCiAgICAgICAgICAgICAgICBleGNlcHQgQmxvY2tpbmdJT0Vy
cm9yOgogICAgICAgICAgICAgICAgICAgIGlmIHRpbWUubW9ub3RvbmljKCkgPj0gZGVhZGxpbmU6
CiAgICAgICAgICAgICAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5Y+m5LiA5Liq5pON5L2c
5q2j5Zyo5L2/55So5q2k6YWN572u77yM6K+356iN5ZCO6YeN6K+V77yaIiArIG5hbWUsIDEwKQog
ICAgICAgICAgICAgICAgICAgIHRpbWUuc2xlZXAoMC4xKQogICAgICAgICAgICB5aWVsZAogICAg
ICAgIGZpbmFsbHk6CiAgICAgICAgICAgIGZjbnRsLmZsb2NrKGRlc2NyaXB0b3IsIGZjbnRsLkxP
Q0tfVU4pCiAgICAgICAgICAgIG9zLmNsb3NlKGRlc2NyaXB0b3IpCgogICAgZGVmIGluc3RhbGxf
cnVudGltZShzZWxmKToKICAgICAgICBkYXRhID0gcnVudGltZV9hcmNoaXZlKCkKICAgICAgICB0
YXJnZXQgPSBzZWxmLnNhZmVfcGF0aChzZWxmLnJ1bnRpbWVfcGF0aCkKICAgICAgICBpZiB0YXJn
ZXQuZXhpc3RzKCk6CiAgICAgICAgICAgIGlmIHRhcmdldC5yZWFkX2J5dGVzKCkgPT0gZGF0YToK
ICAgICAgICAgICAgICAgIHJldHVybiAiL3Vzci9sb2NhbC9saWIvdnBzY3RsL25ldHdvcmstdHVu
ZS9ydW50aW1lLnB5eiIKICAgICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgd2l0aCB6aXBm
aWxlLlppcEZpbGUodGFyZ2V0KSBhcyBhcmNoaXZlOgogICAgICAgICAgICAgICAgICAgIG93bmVk
ID0gYXJjaGl2ZS5jb21tZW50ID09IFJVTlRJTUVfTUFSS0VSCiAgICAgICAgICAgIGV4Y2VwdCAo
T1NFcnJvciwgemlwZmlsZS5CYWRaaXBGaWxlKToKICAgICAgICAgICAgICAgIG93bmVkID0gRmFs
c2UKICAgICAgICAgICAgaWYgbm90IG93bmVkOgogICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVy
cm9yKCLlkIzlkI3ov5DooYzml7bmlofku7bkuI3lsZ7kuo7nvZHnu5zosIPkvJjmqKHlnZfvvJoi
ICsgc3RyKHRhcmdldCksIDEwKQogICAgICAgIHNlbGYuYXRvbWljX3dyaXRlKHRhcmdldCwgZGF0
YSwgMG82NDQpCiAgICAgICAgcmV0dXJuICIvdXNyL2xvY2FsL2xpYi92cHNjdGwvbmV0d29yay10
dW5lL3J1bnRpbWUucHl6IgoKICAgIEBjb250ZXh0bGliLmNvbnRleHRtYW5hZ2VyCiAgICBkZWYg
cnVudGltZV90cmFuc2FjdGlvbihzZWxmKToKICAgICAgICBpZiBzZWxmLmRyeV9ydW46CiAgICAg
ICAgICAgIHlpZWxkCiAgICAgICAgICAgIHJldHVybgogICAgICAgIHNhdmVkID0gc2VsZi5zbmFw
c2hvdF9maWxlKHNlbGYucnVudGltZV9wYXRoKQogICAgICAgIHRyeToKICAgICAgICAgICAgeWll
bGQKICAgICAgICBleGNlcHQgQmFzZUV4Y2VwdGlvbiBhcyBlcnJvcjoKICAgICAgICAgICAgdHJ5
OgogICAgICAgICAgICAgICAgaWYgc2VsZi5zbmFwc2hvdF9maWxlKHNlbGYucnVudGltZV9wYXRo
KSAhPSBzYXZlZDoKICAgICAgICAgICAgICAgICAgICBzZWxmLnJlc3RvcmVfZmlsZShzZWxmLnJ1
bnRpbWVfcGF0aCwgc2F2ZWQpCiAgICAgICAgICAgIGV4Y2VwdCBCYXNlRXhjZXB0aW9uIGFzIGZh
aWx1cmU6CiAgICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaTjeS9nOWksei0peS4lOWF
seS6q+i/kOihjOaXtuaBouWkjeWksei0pe+8miIgKyBzdHIoZmFpbHVyZSksIDMwKSBmcm9tIGVy
cm9yCiAgICAgICAgICAgIHJhaXNlCgogICAgQGNvbnRleHRsaWIuY29udGV4dG1hbmFnZXIKICAg
IGRlZiB1bml0X3Jlc3RvcmVfc2NvcGUoc2VsZik6CiAgICAgICAgIiIiUmVzdGFydCBvdXIgcmVz
dG9yZWQgdW5pdHMgYWZ0ZXIgdGhlIGNhbGxlciByZWxlYXNlcyBpdHMgc2hhcmVkIGxvY2tzLiIi
IgogICAgICAgIHByZXZpb3VzID0gc2VsZi5fZGVmZXJyZWRfdW5pdF9zdGFydHMKICAgICAgICBz
ZWxmLl9kZWZlcnJlZF91bml0X3N0YXJ0cyA9IHNldCgpCiAgICAgICAgZmFpbHVyZSA9IE5vbmUK
ICAgICAgICB0cnk6CiAgICAgICAgICAgIHlpZWxkCiAgICAgICAgZXhjZXB0IEJhc2VFeGNlcHRp
b24gYXMgZXJyb3I6CiAgICAgICAgICAgIGZhaWx1cmUgPSBlcnJvcgogICAgICAgICAgICByYWlz
ZQogICAgICAgIGZpbmFsbHk6CiAgICAgICAgICAgIHN0YXJ0cyA9IHNlbGYuX2RlZmVycmVkX3Vu
aXRfc3RhcnRzCiAgICAgICAgICAgIHNlbGYuX2RlZmVycmVkX3VuaXRfc3RhcnRzID0gcHJldmlv
dXMKICAgICAgICAgICAgZXJyb3JzID0gW10KICAgICAgICAgICAgZm9yIG5hbWUgaW4gc29ydGVk
KHN0YXJ0cyk6CiAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgc2VsZi5y
dW4oWyJzeXN0ZW1jdGwiLCAic3RhcnQiLCBuYW1lXSwgdGltZW91dD05MCkKICAgICAgICAgICAg
ICAgIGV4Y2VwdCBCYXNlRXhjZXB0aW9uIGFzIGVycm9yOgogICAgICAgICAgICAgICAgICAgIGVy
cm9ycy5hcHBlbmQoc3RyKGVycm9yKSkKICAgICAgICAgICAgaWYgZXJyb3JzOgogICAgICAgICAg
ICAgICAgcmFpc2UgVHVuZUVycm9yKCLmgaLlpI3mnI3liqHlkK/liqjlpLHotKXvvJoiICsgIjsg
Ii5qb2luKGVycm9ycyksIDMwKSBmcm9tIGZhaWx1cmUKCiAgICBkZWYgdW5pdF9wYXRoKHNlbGYs
IG5hbWUpOgogICAgICAgIGlmIG5vdCByZS5mdWxsbWF0Y2gociJbQS1aYS16MC05Xy5AOlxcLV0r
XC5zZXJ2aWNlIiwgbmFtZSk6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5pyN5Yqh5ZCN
56ew5peg5pWIIiwgMTApCiAgICAgICAgcmV0dXJuIHNlbGYucGF0aCgiL2V0Yy9zeXN0ZW1kL3N5
c3RlbS8iICsgbmFtZSkKCiAgICBkZWYgc3lzdGVtY3RsKHNlbGYsICphcmdzLCBjaGVjaz1UcnVl
KToKICAgICAgICByZXR1cm4gc2VsZi5ydW4oWyJzeXN0ZW1jdGwiLCAqYXJnc10sIGNoZWNrPWNo
ZWNrLCB0aW1lb3V0PTMwKQoKICAgIGRlZiB1bml0X3N0YXRlKHNlbGYsIG5hbWUpOgogICAgICAg
IGZpbGUgPSBzZWxmLnNuYXBzaG90X2ZpbGUoc2VsZi51bml0X3BhdGgobmFtZSkpCiAgICAgICAg
cmVzdWx0ID0gc2VsZi5zeXN0ZW1jdGwoInNob3ciLCBuYW1lLCAiLXAiLCAiTG9hZFN0YXRlIiwg
Ii1wIiwgIkFjdGl2ZVN0YXRlIiwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiLXAi
LCAiVW5pdEZpbGVTdGF0ZSIsIGNoZWNrPUZhbHNlKQogICAgICAgIHZhbHVlcyA9IGRpY3QobGlu
ZS5zcGxpdCgiPSIsIDEpIGZvciBsaW5lIGluIHJlc3VsdC5zdGRvdXQuc3BsaXRsaW5lcygpIGlm
ICI9IiBpbiBsaW5lKQogICAgICAgIHJldHVybiB7ImV4aXN0cyI6IGZpbGVbImV4aXN0cyJdLCAi
ZmlsZSI6IGZpbGUsCiAgICAgICAgICAgICAgICAiYWN0aXZlIjogdmFsdWVzLmdldCgiQWN0aXZl
U3RhdGUiKSA9PSAiYWN0aXZlIiwKICAgICAgICAgICAgICAgICJlbmFibGVkIjogdmFsdWVzLmdl
dCgiVW5pdEZpbGVTdGF0ZSIpIGluICgiZW5hYmxlZCIsICJlbmFibGVkLXJ1bnRpbWUiKSwKICAg
ICAgICAgICAgICAgICJsb2FkX3N0YXRlIjogdmFsdWVzLmdldCgiTG9hZFN0YXRlIiwgIm5vdC1m
b3VuZCIpLAogICAgICAgICAgICAgICAgImFjdGl2ZV9zdGF0ZSI6IHZhbHVlcy5nZXQoIkFjdGl2
ZVN0YXRlIiwgImluYWN0aXZlIiksCiAgICAgICAgICAgICAgICAidW5pdF9maWxlX3N0YXRlIjog
dmFsdWVzLmdldCgiVW5pdEZpbGVTdGF0ZSIsICIiKX0KCiAgICBkZWYgd3JpdGVfdW5pdChzZWxm
LCBuYW1lLCBjb250ZW50KToKICAgICAgICBzZWxmLmF0b21pY193cml0ZShzZWxmLnVuaXRfcGF0
aChuYW1lKSwgY29udGVudCwgMG82NDQpCiAgICAgICAgc2VsZi5zeXN0ZW1jdGwoImRhZW1vbi1y
ZWxvYWQiKQoKICAgIGRlZiByZXN0b3JlX3VuaXQoc2VsZiwgbmFtZSwgc25hcHNob3QpOgogICAg
ICAgIGN1cnJlbnQgPSBzZWxmLnVuaXRfc3RhdGUobmFtZSkKICAgICAgICBpZiBjdXJyZW50WyJh
Y3RpdmUiXSBhbmQgbm90IHNuYXBzaG90LmdldCgiYWN0aXZlIik6CiAgICAgICAgICAgIHNlbGYu
c3lzdGVtY3RsKCJzdG9wIiwgbmFtZSkKICAgICAgICBpZiBjdXJyZW50WyJlbmFibGVkIl06CiAg
ICAgICAgICAgIHNlbGYuc3lzdGVtY3RsKCJkaXNhYmxlIiwgbmFtZSkKICAgICAgICBzZWxmLnJl
c3RvcmVfZmlsZShzZWxmLnVuaXRfcGF0aChuYW1lKSwgc25hcHNob3RbImZpbGUiXSkKICAgICAg
ICBzZWxmLnN5c3RlbWN0bCgiZGFlbW9uLXJlbG9hZCIpCiAgICAgICAgaWYgc25hcHNob3QuZ2V0
KCJlbmFibGVkIik6CiAgICAgICAgICAgIHNlbGYuc3lzdGVtY3RsKCJlbmFibGUiLCBuYW1lKQog
ICAgICAgIGlmIHNuYXBzaG90LmdldCgiYWN0aXZlIik6CiAgICAgICAgICAgIGlmIG5hbWUuc3Rh
cnRzd2l0aCgidnBzY3RsLW5ldHdvcmstdHVuZS0iKSBhbmQgc2VsZi5fZGVmZXJyZWRfdW5pdF9z
dGFydHMgaXMgbm90IE5vbmU6CiAgICAgICAgICAgICAgICBzZWxmLl9kZWZlcnJlZF91bml0X3N0
YXJ0cy5hZGQobmFtZSkKICAgICAgICAgICAgZWxzZToKICAgICAgICAgICAgICAgIHNlbGYuc3lz
dGVtY3RsKCJzdGFydCIsIG5hbWUpCgogICAgZGVmIG1lbW9yeV9ieXRlcyhzZWxmKToKICAgICAg
ICB0cnk6CiAgICAgICAgICAgIGNvbnRlbnRzID0gc2VsZi5wYXRoKCIvcHJvYy9tZW1pbmZvIiku
cmVhZF90ZXh0KCkKICAgICAgICAgICAgdmFsdWUgPSByZS5zZWFyY2gociJeTWVtVG90YWw6XHMr
KFxkKylccytrQiIsIGNvbnRlbnRzLCByZS5NVUxUSUxJTkUpCiAgICAgICAgICAgIGlmIHZhbHVl
OgogICAgICAgICAgICAgICAgcmV0dXJuIGludCh2YWx1ZS5ncm91cCgxKSkgKiAxMDI0CiAgICAg
ICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgIHBhc3MKICAgICAgICByYWlzZSBUdW5lRXJy
b3IoIuaXoOazleivu+WPlueJqeeQhuWGheWtmO+8jOS4jeiDveeUn+aIkOWPl+mihOeul+e6puad
n+eahOe8k+WtmOW7uuiuriIsIDMpCgoKZGVmIHJlYWRfc3lzY3RsKGN0eCwga2V5KToKICAgIGlm
IG5vdCByZS5mdWxsbWF0Y2gociJbYS16QS1aMC05Xy5dKyIsIGtleSk6CiAgICAgICAgcmFpc2Ug
VHVuZUVycm9yKCLlhoXmoLjlj4LmlbDlkI3np7Dml6DmlYgiLCAyKQogICAgcmV0dXJuIGN0eC5y
dW4oWyJzeXNjdGwiLCAiLW4iLCBrZXldKS5zdGRvdXQuc3RyaXAoKQoKCmRlZiBzZXRfc3lzY3Rs
KGN0eCwga2V5LCB2YWx1ZSk6CiAgICBpZiBub3QgcmUuZnVsbG1hdGNoKHIiW2EtekEtWjAtOV8u
XSsiLCBrZXkpIG9yICJcbiIgaW4gc3RyKHZhbHVlKSBvciAiXHIiIGluIHN0cih2YWx1ZSk6CiAg
ICAgICAgcmFpc2UgVHVuZUVycm9yKCLlhoXmoLjlj4LmlbDmoLzlvI/ml6DmlYgiLCAyKQogICAg
Y3R4Lm11dGF0ZShbInN5c2N0bCIsICItdyIsIGtleSArICI9IiArIHN0cih2YWx1ZSldKQoKCmRl
ZiBzaGEyNTZfZmlsZShwYXRoKToKICAgIHJldHVybiBoYXNobGliLnNoYTI1NihQYXRoKHBhdGgp
LnJlYWRfYnl0ZXMoKSkuaGV4ZGlnZXN0KCkKUEsDBBQAAAAAAAAAIVAFLBNm85EAAPORAAAWAAAA
bmV0d29ya190dW5lL2VncmVzcy5weSIiIlJvb3QgcXVldWUgcHJvZmlsZXMgYW5kIHJldmVyc2li
bGUgb3duZXJzaGlwIG9mIHRoZWlyIGJvb3Qgc2VydmljZS4iIiIKCmltcG9ydCBjb3B5CmltcG9y
dCBqc29uCmltcG9ydCBtYXRoCmltcG9ydCByZQppbXBvcnQgc2hsZXgKCmZyb20gLmNvbW1vbiBp
bXBvcnQgVHVuZUVycm9yLCBwYXJzZV9tYnBzLCB2YWxpZF9pbnRlcmZhY2UKCgpMRUdBQ1lfVU5J
VFMgPSAoCiAgICAibmV0d29yay10dW5pbmctZnEuc2VydmljZSIsCiAgICAibmV0d29yay10dW5p
bmctcG8wLXNoYXBlci5zZXJ2aWNlIiwKICAgICJuZXR3b3JrLXR1bmluZy11cy1zaGFwZXIuc2Vy
dmljZSIsCikKTUFSS0VSID0gIiMgTWFuYWdlZCBieSB2cHNjdGwgbmV0d29yayB0dW5lIGVncmVz
cy4iCl9GUV9JTlRTID0geyJsaW1pdCIsICJmbG93X2xpbWl0IiwgImJ1Y2tldHMiLCAib3JwaGFu
X21hc2siLCAicXVhbnR1bSIsICJpbml0aWFsX3F1YW50dW0ifQpfRlFfUkFURVMgPSB7Im1heHJh
dGUiLCAiZGVmcmF0ZSIsICJsb3dfcmF0ZV90aHJlc2hvbGQifQpfRlFfVElNRVMgPSB7InJlZmls
bF9kZWxheSIsICJjZV90aHJlc2hvbGQiLCAiaG9yaXpvbiIsICJvZmZsb2FkX2hvcml6b24ifQpf
Q09ERUxfSU5UUyA9IHsibGltaXQiLCAiZmxvd3MiLCAicXVhbnR1bSIsICJtZW1vcnlfbGltaXQi
LCAiZHJvcF9iYXRjaCJ9Cl9IQU5ETEUgPSByZS5jb21waWxlKHIiXlswLTlhLWZBLUZdezAsNH06
WzAtOWEtZkEtRl17MCw0fSQiKQoKCmRlZiBfanNvbl9ydW4oY3R4LCBhcmd2KToKICAgIHJlc3Vs
dCA9IGN0eC5ydW4oYXJndikKICAgIHRyeToKICAgICAgICB2YWx1ZSA9IGpzb24ubG9hZHMocmVz
dWx0LnN0ZG91dCkKICAgIGV4Y2VwdCAoVHlwZUVycm9yLCBWYWx1ZUVycm9yKSBhcyBleGM6CiAg
ICAgICAgcmFpc2UgVHVuZUVycm9yKCLml6Dms5Xop6PmnpAgdGMgSlNPTiDovpPlh7oiLCAzKSBm
cm9tIGV4YwogICAgaWYgbm90IGlzaW5zdGFuY2UodmFsdWUsIGxpc3QpIG9yIGFueShub3QgaXNp
bnN0YW5jZShpdGVtLCBkaWN0KSBmb3IgaXRlbSBpbiB2YWx1ZSk6CiAgICAgICAgcmFpc2UgVHVu
ZUVycm9yKCJ0YyBKU09OIOi+k+WHuuagvOW8j+S4jeWPl+aUr+aMgSIsIDMpCiAgICByZXR1cm4g
dmFsdWUKCgpkZWYgcmVhZF90cmVlKGN0eCwgaWZhY2UsIHN0YXRzPUZhbHNlKToKICAgICIiIlJl
dHVybiBvbmx5IHRoZSByb290IHRyZWU7IGNsc2FjdC9pbmdyZXNzIHJlbWFpbiBpbmRlcGVuZGVu
dGx5IG93bmVkLiIiIgogICAgaWZhY2UgPSB2YWxpZF9pbnRlcmZhY2UoaWZhY2UpCiAgICBhcmd2
ID0gWyJ0YyIsICItaiJdICsgKFsiLXMiXSBpZiBzdGF0cyBlbHNlIFtdKSArIFsicWRpc2MiLCAi
c2hvdyIsICJkZXYiLCBpZmFjZV0KICAgIHRyZWUgPSBfanNvbl9ydW4oY3R4LCBhcmd2KQogICAg
dGJmcyA9IFtub2RlIGZvciBub2RlIGluIHRyZWUgaWYgbm9kZS5nZXQoImtpbmQiKSA9PSAidGJm
Il0KICAgIGlmIHRiZnM6CiAgICAgICAgIyBPcmRpbmFyeSB0YyBKU09OIG9taXRzIHRoZSBieXRl
IGxpbWl0LCBtcHUgYW5kIHJhdGUtdGFibGUgY2VsbCBzaXplLgogICAgICAgICMgS2VlcCBpdHMg
ZXhhY3QgbnVtZXJpYyBidXJzdCwgbWVyZ2luZyB0aGUgbWlzc2luZyBkZXRhaWxlZCBmaWVsZHMu
CiAgICAgICAgZGV0YWlsZWQgPSBfanNvbl9ydW4oY3R4LCBbInRjIiwgIi1qIiwgIi1kIiwgIi1y
IiwgInFkaXNjIiwgInNob3ciLCAiZGV2IiwgaWZhY2VdKQogICAgICAgIGZvciBub2RlIGluIHRi
ZnM6CiAgICAgICAgICAgIG90aGVyID0gbmV4dCgoaXRlbSBmb3IgaXRlbSBpbiBkZXRhaWxlZCBp
ZiBpdGVtLmdldCgia2luZCIpID09ICJ0YmYiIGFuZCBpdGVtLmdldCgiaGFuZGxlIikgPT0gbm9k
ZS5nZXQoImhhbmRsZSIpKSwgTm9uZSkKICAgICAgICAgICAgaWYgb3RoZXIgaXMgTm9uZToKICAg
ICAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi6K+75Y+WIFRCRiDor6bnu4blv6vnhafml7bp
mJ/liJflj5HnlJ/lj5jljJYiLCAxMCkKICAgICAgICAgICAgb3B0cyA9IG5vZGUuc2V0ZGVmYXVs
dCgib3B0aW9ucyIsIHt9KQogICAgICAgICAgICBkZXRhaWwgPSBfb3B0aW9ucyhvdGhlcikKICAg
ICAgICAgICAgaWYgIm1pbmJ1cnN0IiBpbiBvcHRzIG9yICJtdHUiIGluIGRldGFpbCBvciAicGVh
a3JhdGUiIGluIG9wdHM6CiAgICAgICAgICAgICAgICAjIGlwcm91dGUyIHByaW50cyBwZWFrcmF0
ZSBvbmx5IGluIG5vbi1KU09OIG91dHB1dC4gUmVmdXNlCiAgICAgICAgICAgICAgICAjIHRoaXMg
dW5zdXBwb3J0ZWQgdmFyaWFudCBpbnN0ZWFkIG9mIGxvc2luZyB0aGUgaGlkZGVuIHJhdGUuCiAg
ICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuS4jeaUr+aMgeWujOaVtOS/neWtmOW4piBw
ZWFrcmF0ZSDnmoQgVEJGIiwgMykKICAgICAgICAgICAgYnVyc3QgPSBkZXRhaWwuZ2V0KCJidXJz
dCIpCiAgICAgICAgICAgIGlmIGlzaW5zdGFuY2UoYnVyc3QsIHN0cik6CiAgICAgICAgICAgICAg
ICBjZWxsID0gcmUuc2VhcmNoKHIiLyhcZCspJCIsIGJ1cnN0KQogICAgICAgICAgICAgICAgaWYg
bm90IGNlbGw6CiAgICAgICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCJUQkYg6K+m57uG
IGJ1cnN0IOagvOW8j+S4jeWPl+aUr+aMgSIsIDMpCiAgICAgICAgICAgICAgICBvcHRzWyJidXJz
dF9jZWxsIl0gPSBpbnQoY2VsbFsxXSkKICAgICAgICAgICAgaWYgImJ1cnN0X3JhdyIgaW4gZGV0
YWlsOgogICAgICAgICAgICAgICAgb3B0c1siYnVyc3RfcmVzdG9yZV9ieXRlcyJdID0gX3RiZl9p
bnB1dF9ieXRlcyhjdHgsIG9wdHNbInJhdGUiXSwgZGV0YWlsWyJidXJzdF9yYXciXSkKICAgICAg
ICAgICAgb3B0cy51cGRhdGUoe2tleTogdmFsdWUgZm9yIGtleSwgdmFsdWUgaW4gZGV0YWlsLml0
ZW1zKCkgaWYga2V5IG5vdCBpbiAoImJ1cnN0IiwgImJ1cnN0X3JhdyIpfSkKICAgIHJldHVybiBb
aXRlbSBmb3IgaXRlbSBpbiB0cmVlIGlmIGl0ZW0uZ2V0KCJraW5kIikgbm90IGluICgiY2xzYWN0
IiwgImluZ3Jlc3MiKQogICAgICAgICAgICBhbmQgbm90IHN0cihpdGVtLmdldCgicGFyZW50Iiwg
IiIpKS5zdGFydHN3aXRoKCJmZmZmOiIpXQoKCmRlZiBfb3B0aW9ucyhub2RlKToKICAgIG9wdGlv
bnMgPSBub2RlLmdldCgib3B0aW9ucyIsIHt9KQogICAgaWYgbm90IGlzaW5zdGFuY2Uob3B0aW9u
cywgZGljdCk6CiAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLpmJ/liJfpgInpobnmoLzlvI/kuI3l
j5fmlK/mjIEiLCAzKQogICAgIyBpcHJvdXRlMiBlbWl0cyB0cmFpbGluZyBzcGFjZXMgaW4gdGhl
c2UgdHdvIEpTT04gZmllbGQgbmFtZXMuCiAgICByZXN1bHQgPSB7a2V5LnN0cmlwKCk6IHZhbHVl
IGZvciBrZXksIHZhbHVlIGluIG9wdGlvbnMuaXRlbXMoKX0KICAgIGlmIG5vZGUuZ2V0KCJraW5k
IikgPT0gImZxX2NvZGVsIjoKICAgICAgICByZXN1bHQuc2V0ZGVmYXVsdCgiZWNuIiwgRmFsc2Up
CiAgICByZXR1cm4gcmVzdWx0CgoKZGVmIF9udW1iZXIodmFsdWUsIGxhYmVsLCBtaW5pbXVtPTAp
OgogICAgaWYgaXNpbnN0YW5jZSh2YWx1ZSwgYm9vbCkgb3Igbm90IGlzaW5zdGFuY2UodmFsdWUs
IChpbnQsIGZsb2F0KSkgb3Igbm90IG1hdGguaXNmaW5pdGUodmFsdWUpIG9yIHZhbHVlIDwgbWlu
aW11bToKICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaXoOaViOeahOmYn+WIl+WPguaVsO+8miIg
KyBsYWJlbCwgMykKICAgIHJldHVybiBmb3JtYXQodmFsdWUsICIuMTJnIikKCgpkZWYgX2NvZGVs
X2lucHV0X3VzKHZhbHVlKToKICAgICIiIkludmVydCBmcV9jb2RlbCdzIGZsb29yZWQgMTAyNCBu
cyB0aWNrIC0+IGludGVnZXIgdXMgZHVtcC4iIiIKICAgIF9udW1iZXIodmFsdWUsICJDb0RlbCB0
aW1lIikKICAgIGlmIGludCh2YWx1ZSkgIT0gdmFsdWU6CiAgICAgICAgcmFpc2UgVHVuZUVycm9y
KCJDb0RlbCDlv6vnhafml7bpl7Tlv4XpobvkuLrmlbTmlbDlvq7np5IiLCAzKQogICAgdGlja3Mg
PSAoaW50KHZhbHVlKSAqIDEwMDAgKyAxMDIzKSAvLyAxMDI0CiAgICByZXR1cm4gKHRpY2tzICog
MTAyNCArIDk5OSkgLy8gMTAwMAoKCmRlZiBfdGJmX2lucHV0X2J5dGVzKGN0eCwgcmF0ZSwgcmF3
X3RpY2tzKToKICAgICIiIlJlY292ZXIgdGhlIGxlYXN0IHdob2xlLWJ5dGUgYnVyc3QgdGhhdCBk
dW1wcyB0aGUgc2F2ZWQgcHNjaGVkIHRpY2suIiIiCiAgICB0cnk6CiAgICAgICAgdGlja3MgPSBp
bnQocmF3X3RpY2tzLCAxNikgaWYgaXNpbnN0YW5jZShyYXdfdGlja3MsIHN0cikgZWxzZSBpbnQo
cmF3X3RpY2tzKQogICAgICAgIGZpZWxkcyA9IGN0eC5ydW4oWyJjYXQiLCAiL3Byb2MvbmV0L3Bz
Y2hlZCJdKS5zdGRvdXQuc3BsaXQoKQogICAgICAgIHQydXMsIHVzMnQsIGNsb2NrX3JlcyA9IChp
bnQodmFsdWUsIDE2KSBmb3IgdmFsdWUgaW4gZmllbGRzWzozXSkKICAgICAgICBpZiBjbG9ja19y
ZXMgPT0gMV8wMDBfMDAwXzAwMDoKICAgICAgICAgICAgdDJ1cyA9IHVzMnQKICAgICAgICBudW1l
cmF0b3IsIGRlbm9taW5hdG9yID0gdGlja3MgKiBpbnQocmF0ZSkgKiB1czJ0LCB0MnVzICogY2xv
Y2tfcmVzCiAgICAgICAgaWYgbWluKHRpY2tzLCByYXRlLCB1czJ0LCBkZW5vbWluYXRvcikgPD0g
MDoKICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJvcgogICAgICAgIHJldHVybiAobnVtZXJhdG9y
ICsgZGVub21pbmF0b3IgLSAxKSAvLyBkZW5vbWluYXRvcgogICAgZXhjZXB0IChWYWx1ZUVycm9y
LCBUeXBlRXJyb3IsIFplcm9EaXZpc2lvbkVycm9yKSBhcyBleGM6CiAgICAgICAgcmFpc2UgVHVu
ZUVycm9yKCLml6Dms5Xov5jljp8gVEJGIHBzY2hlZCBidXJzdCDnsr7luqYiLCAzKSBmcm9tIGV4
YwoKCmRlZiBfb3B0aW9uX2FyZ3Mobm9kZSwgY29tcGxldGU9VHJ1ZSk6CiAgICAiIiJTZXJpYWxp
emUgZXZlcnkgdW5kZXJzdG9vZCBvcHRpb247IG5ldmVyIHNpbGVudGx5IGRyb3AgdW5rbm93biBv
cHRpb25zLiIiIgogICAga2luZCwgb3B0cyA9IG5vZGUuZ2V0KCJraW5kIiksIF9vcHRpb25zKG5v
ZGUpCiAgICBhcmdzID0gW10KICAgIGlmIGtpbmQgaW4gKCJtcSIsICJub3F1ZXVlIik6CiAgICAg
ICAgYWxsb3dlZCA9IHNldCgpCiAgICBlbGlmIGtpbmQgPT0gImZxIjoKICAgICAgICBhbGxvd2Vk
ID0gX0ZRX0lOVFMgfCBfRlFfUkFURVMgfCBfRlFfVElNRVMgfCB7CiAgICAgICAgICAgICJwYWNp
bmciLCAidGltZXJfc2xhY2siLCAiaG9yaXpvbl9kcm9wIiwgImhvcml6b25fY2FwIiwgImJhbmRz
IiwgInByaW9tYXAiLCAid2VpZ2h0cyJ9CiAgICAgICAgZm9yIGtleSBpbiBzb3J0ZWQoX0ZRX0lO
VFMgJiBvcHRzLmtleXMoKSk6CiAgICAgICAgICAgIGFyZ3MgKz0gW2tleSwgX251bWJlcihvcHRz
W2tleV0sIGtleSldCiAgICAgICAgZm9yIGtleSBpbiBzb3J0ZWQoX0ZRX1JBVEVTICYgb3B0cy5r
ZXlzKCkpOgogICAgICAgICAgICBhcmdzICs9IFtrZXksIF9udW1iZXIob3B0c1trZXldICogOCwg
a2V5KSArICJiaXQiXQogICAgICAgIGlmIGNvbXBsZXRlIGFuZCAibG93X3JhdGVfdGhyZXNob2xk
IiBub3QgaW4gb3B0czoKICAgICAgICAgICAgIyB0YyBvbWl0cyB0aGlzIGZpZWxkIHdoZW4gaXQg
aXMgZXhwbGljaXRseSB6ZXJvLgogICAgICAgICAgICBhcmdzICs9IFsibG93X3JhdGVfdGhyZXNo
b2xkIiwgIjBiaXQiXQogICAgICAgIGZvciBrZXkgaW4gc29ydGVkKF9GUV9USU1FUyAmIG9wdHMu
a2V5cygpKToKICAgICAgICAgICAgYXJncyArPSBba2V5LCBfbnVtYmVyKG9wdHNba2V5XSwga2V5
KSArICJ1cyJdCiAgICAgICAgaWYgInRpbWVyX3NsYWNrIiBpbiBvcHRzOgogICAgICAgICAgICBh
cmdzICs9IFsidGltZXJfc2xhY2siLCBfbnVtYmVyKG9wdHNbInRpbWVyX3NsYWNrIl0sICJ0aW1l
cl9zbGFjayIpICsgIm5zIl0KICAgICAgICBhcmdzICs9IFsicGFjaW5nIiBpZiBvcHRzLmdldCgi
cGFjaW5nIiwgVHJ1ZSkgZWxzZSAibm9wYWNpbmciXQogICAgICAgIGZvciBrZXkgaW4gKCJob3Jp
em9uX2Ryb3AiLCAiaG9yaXpvbl9jYXAiKToKICAgICAgICAgICAgaWYga2V5IGluIG9wdHM6CiAg
ICAgICAgICAgICAgICBhcmdzLmFwcGVuZChrZXkpCiAgICAgICAgaWYgImJhbmRzIiBpbiBvcHRz
IG9yICJwcmlvbWFwIiBpbiBvcHRzOgogICAgICAgICAgICBpZiBvcHRzLmdldCgiYmFuZHMiKSAh
PSAzIG9yIGxlbihvcHRzLmdldCgicHJpb21hcCIsIFtdKSkgIT0gMTY6CiAgICAgICAgICAgICAg
ICByYWlzZSBUdW5lRXJyb3IoIuaXoOazleWujOaVtOaBouWkjSBmcSBiYW5kcy9wcmlvbWFwIiwg
MykKICAgICAgICAgICAgYXJncyArPSBbImJhbmRzIiwgIjMiLCAicHJpb21hcCJdICsgW19udW1i
ZXIodiwgInByaW9tYXAiKSBmb3IgdiBpbiBvcHRzWyJwcmlvbWFwIl1dCiAgICAgICAgaWYgIndl
aWdodHMiIGluIG9wdHM6CiAgICAgICAgICAgIGlmIG5vdCBpc2luc3RhbmNlKG9wdHNbIndlaWdo
dHMiXSwgbGlzdCkgb3IgbGVuKG9wdHNbIndlaWdodHMiXSkgIT0gMzoKICAgICAgICAgICAgICAg
IHJhaXNlIFR1bmVFcnJvcigi5peg5rOV5a6M5pW05oGi5aSNIGZxIHdlaWdodHMiLCAzKQogICAg
ICAgICAgICBhcmdzICs9IFsid2VpZ2h0cyJdICsgW19udW1iZXIodiwgIndlaWdodHMiLCAxKSBm
b3IgdiBpbiBvcHRzWyJ3ZWlnaHRzIl1dCiAgICBlbGlmIGtpbmQgPT0gImZxX2NvZGVsIjoKICAg
ICAgICBhbGxvd2VkID0gX0NPREVMX0lOVFMgfCB7InRhcmdldCIsICJpbnRlcnZhbCIsICJlY24i
LCAiY2VfdGhyZXNob2xkIiwgImNlX3RocmVzaG9sZF9zZWxlY3RvciIsICJjZV90aHJlc2hvbGRf
bWFzayJ9CiAgICAgICAgZm9yIGtleSBpbiBzb3J0ZWQoX0NPREVMX0lOVFMgJiBvcHRzLmtleXMo
KSk6CiAgICAgICAgICAgIGFyZ3MgKz0gW2tleSwgX251bWJlcihvcHRzW2tleV0sIGtleSldCiAg
ICAgICAgZm9yIGtleSBpbiAoInRhcmdldCIsICJpbnRlcnZhbCIsICJjZV90aHJlc2hvbGQiKToK
ICAgICAgICAgICAgaWYga2V5IGluIG9wdHM6CiAgICAgICAgICAgICAgICBhcmdzICs9IFtrZXks
IHN0cihfY29kZWxfaW5wdXRfdXMob3B0c1trZXldKSkgKyAidXMiXQogICAgICAgICMgbm9lY24g
aXMgcmVwcmVzZW50ZWQgYnkgdGhlIGFic2VuY2Ugb2YgdGhlIEpTT04gZWNuIGZpZWxkLgogICAg
ICAgIGFyZ3MgKz0gWyJlY24iIGlmIG9wdHMuZ2V0KCJlY24iLCBGYWxzZSkgZWxzZSAibm9lY24i
XQogICAgICAgIGlmICJjZV90aHJlc2hvbGRfc2VsZWN0b3IiIGluIG9wdHMgb3IgImNlX3RocmVz
aG9sZF9tYXNrIiBpbiBvcHRzOgogICAgICAgICAgICBzZWxlY3RvciwgbWFzayA9IG9wdHMuZ2V0
KCJjZV90aHJlc2hvbGRfc2VsZWN0b3IiLCAwKSwgb3B0cy5nZXQoImNlX3RocmVzaG9sZF9tYXNr
IiwgMCkKICAgICAgICAgICAgaWYgYW55KG5vdCBpc2luc3RhbmNlKHZhbHVlLCBpbnQpIG9yIG5v
dCAwIDw9IHZhbHVlIDw9IDI1NSBmb3IgdmFsdWUgaW4gKHNlbGVjdG9yLCBtYXNrKSk6CiAgICAg
ICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaXoOazleaBouWkjSBmcV9jb2RlbCBjZV90aHJl
c2hvbGRfc2VsZWN0b3IiLCAzKQogICAgICAgICAgICBhcmdzICs9IFsiY2VfdGhyZXNob2xkX3Nl
bGVjdG9yIiwgc3RyKHNlbGVjdG9yKSArICIvIiArIHN0cihtYXNrKV0KICAgIGVsaWYga2luZCA9
PSAidGJmIjoKICAgICAgICBhbGxvd2VkID0geyJyYXRlIiwgImJ1cnN0IiwgImJ1cnN0X2NlbGwi
LCAiYnVyc3RfcmVzdG9yZV9ieXRlcyIsICJsYXQiLCAibGltaXQiLCAibXB1IiwgIm92ZXJoZWFk
IiwgImxpbmtsYXllciJ9CiAgICAgICAgZm9yIGtleSBpbiAoInJhdGUiLCAiYnVyc3QiKToKICAg
ICAgICAgICAgaWYga2V5IG5vdCBpbiBvcHRzOgogICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVy
cm9yKCJUQkYg5b+r54Wn57y65bCRICIgKyBrZXksIDMpCiAgICAgICAgYnVyc3QgPSBfbnVtYmVy
KG9wdHMuZ2V0KCJidXJzdF9yZXN0b3JlX2J5dGVzIiwgb3B0c1siYnVyc3QiXSksICJidXJzdCIs
IDEpCiAgICAgICAgaWYgImJ1cnN0X2NlbGwiIGluIG9wdHM6CiAgICAgICAgICAgIGNlbGwgPSBv
cHRzWyJidXJzdF9jZWxsIl0KICAgICAgICAgICAgaWYgbm90IGlzaW5zdGFuY2UoY2VsbCwgaW50
KSBvciBjZWxsIDwgMSBvciBjZWxsICYgKGNlbGwgLSAxKToKICAgICAgICAgICAgICAgIHJhaXNl
IFR1bmVFcnJvcigiVEJGIGJ1cnN0IGNlbGwg5b+F6aG75Li6IDIg55qE5bmCIiwgMykKICAgICAg
ICAgICAgYnVyc3QgKz0gIi8iICsgc3RyKGNlbGwpCiAgICAgICAgYXJncyArPSBbInJhdGUiLCBf
bnVtYmVyKG9wdHNbInJhdGUiXSAqIDgsICJyYXRlIiwgMSkgKyAiYml0IiwgImJ1cnN0IiwgYnVy
c3RdCiAgICAgICAgaWYgImxpbWl0IiBpbiBvcHRzOgogICAgICAgICAgICBhcmdzICs9IFsibGlt
aXQiLCBfbnVtYmVyKG9wdHNbImxpbWl0Il0sICJsaW1pdCIsIDEpXQogICAgICAgIGVsaWYgImxh
dCIgaW4gb3B0czoKICAgICAgICAgICAgYXJncyArPSBbImxhdGVuY3kiLCBfbnVtYmVyKG9wdHNb
ImxhdCJdLCAibGF0IikgKyAidXMiXQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHJhaXNlIFR1
bmVFcnJvcigiVEJGIOW/q+eFp+e8uuWwkemYn+WIl+mVv+W6pi/lu7bov58iLCAzKQogICAgICAg
IGZvciBrZXkgaW4gKCJtcHUiLCAib3ZlcmhlYWQiKToKICAgICAgICAgICAgaWYga2V5IGluIG9w
dHM6CiAgICAgICAgICAgICAgICBhcmdzICs9IFtrZXksIF9udW1iZXIob3B0c1trZXldLCBrZXkp
XQogICAgICAgIGlmICJsaW5rbGF5ZXIiIGluIG9wdHM6CiAgICAgICAgICAgIGlmIG9wdHNbImxp
bmtsYXllciJdIG5vdCBpbiAoImV0aGVybmV0IiwgImF0bSIpOgogICAgICAgICAgICAgICAgcmFp
c2UgVHVuZUVycm9yKCLml6Dms5XmgaLlpI0gVEJGIGxpbmtsYXllciIsIDMpCiAgICAgICAgICAg
IGFyZ3MgKz0gWyJsaW5rbGF5ZXIiLCBvcHRzWyJsaW5rbGF5ZXIiXV0KICAgIGVsc2U6CiAgICAg
ICAgcmFpc2UgVHVuZUVycm9yKCLml6Dms5XlrozmlbTkv53lrZgv5oGi5aSN5q2k6Zif5YiX77ya
IiArIHN0cihraW5kKSwgMykKICAgIHVua25vd24gPSBvcHRzLmtleXMoKSAtIGFsbG93ZWQKICAg
IGlmIHVua25vd246CiAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLpmJ/liJfljIXlkKvkuI3mlK/m
jIHnmoTpgInpobnvvJoiICsgIiwgIi5qb2luKHNvcnRlZCh1bmtub3duKSksIDMpCiAgICByZXR1
cm4gYXJncwoKCmRlZiBfdmFsaWRhdGVfdHJlZSh0cmVlKToKICAgIHJvb3RzID0gW25vZGUgZm9y
IG5vZGUgaW4gdHJlZSBpZiBub2RlLmdldCgicm9vdCIpXQogICAgaWYgbGVuKHJvb3RzKSAhPSAx
OgogICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5peg5rOV6K+G5Yir5ZSv5LiAIHJvb3QgcWRpc2Mi
LCAzKQogICAgcm9vdCA9IHJvb3RzWzBdCiAgICBjaGlsZHJlbiA9IFtub2RlIGZvciBub2RlIGlu
IHRyZWUgaWYgbm90IG5vZGUuZ2V0KCJyb290IildCiAgICBmb3Igbm9kZSBpbiB0cmVlOgogICAg
ICAgIGlmIG5vdCBfSEFORExFLmZ1bGxtYXRjaChub2RlLmdldCgiaGFuZGxlIiwgIiIpKToKICAg
ICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLpmJ/liJflj6Xmn4Tml6DmlYgiLCAzKQogICAgICAg
IF9vcHRpb25fYXJncyhub2RlKQogICAgaWYgY2hpbGRyZW46CiAgICAgICAgcHJlZml4ID0gcm9v
dFsiaGFuZGxlIl0uc3BsaXQoIjoiKVswXQogICAgICAgIGlmIHJvb3RbImtpbmQiXSBub3QgaW4g
KCJtcSIsICJ0YmYiKToKICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLkuI3mlK/mjIHmraQg
cm9vdCDnmoTlrZDpmJ/liJfmi5PmiZEiLCAzKQogICAgICAgIHBhcmVudHMgPSBzZXQoKQogICAg
ICAgIGZvciBub2RlIGluIGNoaWxkcmVuOgogICAgICAgICAgICBwYXJlbnQgPSBub2RlLmdldCgi
cGFyZW50IiwgIiIpCiAgICAgICAgICAgIGlmIG5vdCBfSEFORExFLmZ1bGxtYXRjaChwYXJlbnQp
IG9yIHBhcmVudC5zcGxpdCgiOiIpWzBdIG5vdCBpbiAocHJlZml4LCAiIiBpZiBwcmVmaXggPT0g
IjAiIGVsc2UgcHJlZml4KToKICAgICAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5LiN5pSv
5oyB5bWM5aWXL+iEseemuyByb290IOeahOmYn+WIlyIsIDMpCiAgICAgICAgICAgIGlmIHBhcmVu
dCBpbiBwYXJlbnRzIG9yIG5vZGVbImtpbmQiXSBub3QgaW4gKCJmcSIsICJmcV9jb2RlbCIsICJu
b3F1ZXVlIik6CiAgICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuS4jeaUr+aMgeeahOWt
kOmYn+WIlyIsIDMpCiAgICAgICAgICAgIHBhcmVudHMuYWRkKHBhcmVudCkKICAgICAgICBpZiBy
b290WyJraW5kIl0gPT0gInRiZiIgYW5kIChsZW4oY2hpbGRyZW4pICE9IDEgb3IgY2hpbGRyZW5b
MF1bImtpbmQiXSAhPSAiZnEiIG9yIGNoaWxkcmVuWzBdWyJwYXJlbnQiXS5zcGxpdCgiOiIpWzFd
ICE9ICIxIik6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5LuF5pSv5oyBIFRCRiDlhoXn
va7pmJ/liJfmiJYgVEJGK2ZxIiwgMykKICAgIHJldHVybiByb290LCBjaGlsZHJlbgoKCmRlZiBj
YXB0dXJlX3NuYXBzaG90KGN0eCwgaWZhY2UpOgogICAgdHJlZSA9IHJlYWRfdHJlZShjdHgsIGlm
YWNlKQogICAgcm9vdCwgXyA9IF92YWxpZGF0ZV90cmVlKHRyZWUpCiAgICBwYXJlbnRzID0gWyJy
b290Il0KICAgIGlmIHJvb3RbImhhbmRsZSJdICE9ICIwOiI6CiAgICAgICAgcGFyZW50cy5hcHBl
bmQocm9vdFsiaGFuZGxlIl0pCiAgICBmb3IgcGFyZW50IGluIHBhcmVudHM6CiAgICAgICAgYXJn
diA9IFsidGMiLCAiLWoiLCAiZmlsdGVyIiwgInNob3ciLCAiZGV2IiwgaWZhY2VdCiAgICAgICAg
YXJndiArPSBbInJvb3QiXSBpZiBwYXJlbnQgPT0gInJvb3QiIGVsc2UgWyJwYXJlbnQiLCBwYXJl
bnRdCiAgICAgICAgaWYgX2pzb25fcnVuKGN0eCwgYXJndik6CiAgICAgICAgICAgIHJhaXNlIFR1
bmVFcnJvcigicm9vdCDpmJ/liJflrZjlnKjlpJbpg6jov4fmu6TlmajvvIzmi5Lnu53mm7/mjaIi
LCAxMCkKICAgIHJldHVybiB7InNjaGVtYV92ZXJzaW9uIjogMSwgInRyZWUiOiBbCiAgICAgICAg
e2tleTogY29weS5kZWVwY29weShub2RlW2tleV0pIGZvciBrZXkgaW4gKCJraW5kIiwgImhhbmRs
ZSIsICJyb290IiwgInBhcmVudCIsICJvcHRpb25zIikgaWYga2V5IGluIG5vZGV9CiAgICAgICAg
Zm9yIG5vZGUgaW4gdHJlZV19CgoKZGVmIF9idXJzdF90b2xlcmFuY2UocmF0ZV9ieXRlcyk6CiAg
ICAjIHRjIGNvbnZlcnRzIHRoZSB0b2tlbiBidWNrZXQgdGhyb3VnaCBpbnRlZ2VyIG1pY3Jvc2Vj
b25kcy9wc2NoZWQgdGlja3MuCiAgICByZXR1cm4gbWF4KDEsIG1hdGguY2VpbChyYXRlX2J5dGVz
IC8gMV8wMDBfMDAwKSkKCgpkZWYgX3NhbWVfb3B0aW9ucyhleHBlY3RlZCwgYWN0dWFsLCBraW5k
LCBjb21wbGV0ZT1UcnVlKToKICAgIGZvciBrZXksIHZhbHVlIGluIGV4cGVjdGVkLml0ZW1zKCk6
CiAgICAgICAgaWYga2V5IG5vdCBpbiBhY3R1YWw6CiAgICAgICAgICAgIHJldHVybiBGYWxzZQog
ICAgICAgIHRvbGVyYW5jZSA9IDAKICAgICAgICBpZiBraW5kID09ICJ0YmYiIGFuZCBrZXkgPT0g
ImJ1cnN0IjoKICAgICAgICAgICAgdG9sZXJhbmNlID0gX2J1cnN0X3RvbGVyYW5jZShleHBlY3Rl
ZC5nZXQoInJhdGUiLCAwKSkKICAgICAgICBlbGlmIGtpbmQgPT0gInRiZiIgYW5kIGtleSA9PSAi
bGF0IjoKICAgICAgICAgICAgdG9sZXJhbmNlID0gMgogICAgICAgIGlmIHRvbGVyYW5jZToKICAg
ICAgICAgICAgaWYgYWJzKHZhbHVlIC0gYWN0dWFsW2tleV0pID4gdG9sZXJhbmNlOgogICAgICAg
ICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgZWxpZiBhY3R1YWxba2V5XSAhPSB2YWx1ZToK
ICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBpZiBraW5kID09ICJmcSI6CiAgICAgICAgaWYg
YWN0dWFsLmdldCgibWF4cmF0ZSIpICE9IGV4cGVjdGVkLmdldCgibWF4cmF0ZSIpOgogICAgICAg
ICAgICByZXR1cm4gRmFsc2UKICAgICAgICBpZiBhY3R1YWwuZ2V0KCJwYWNpbmciLCBUcnVlKSAh
PSBleHBlY3RlZC5nZXQoInBhY2luZyIsIFRydWUpOgogICAgICAgICAgICByZXR1cm4gRmFsc2UK
ICAgICAgICBpZiBjb21wbGV0ZSBhbmQgYW55KGFjdHVhbC5nZXQoa2V5LCAwKSAhPSBleHBlY3Rl
ZC5nZXQoa2V5LCAwKSBmb3Iga2V5IGluICgiZGVmcmF0ZSIsICJsb3dfcmF0ZV90aHJlc2hvbGQi
KSk6CiAgICAgICAgICAgIHJldHVybiBGYWxzZQogICAgaWYga2luZCA9PSAiZnFfY29kZWwiIGFu
ZCBhY3R1YWwuZ2V0KCJlY24iLCBGYWxzZSkgIT0gZXhwZWN0ZWQuZ2V0KCJlY24iLCBGYWxzZSk6
CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICByZXR1cm4gVHJ1ZQoKCmRlZiBfc25hcHNob3RfbWF0
Y2hlcyhjdHgsIGlmYWNlLCBzbmFwc2hvdCk6CiAgICBleHBlY3RlZCA9IHNuYXBzaG90WyJ0cmVl
Il0KICAgIGFjdHVhbCA9IHJlYWRfdHJlZShjdHgsIGlmYWNlKQogICAgZXJvb3QsIGVjaGlsZHJl
biA9IF92YWxpZGF0ZV90cmVlKGV4cGVjdGVkKQogICAgdHJ5OgogICAgICAgIGFyb290LCBhY2hp
bGRyZW4gPSBfdmFsaWRhdGVfdHJlZShhY3R1YWwpCiAgICBleGNlcHQgVHVuZUVycm9yOgogICAg
ICAgIHJldHVybiBGYWxzZQogICAgaWYgbGVuKGV4cGVjdGVkKSAhPSBsZW4oYWN0dWFsKSBvciBl
cm9vdFsia2luZCJdICE9IGFyb290WyJraW5kIl06CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBw
YWlycyA9IFsoZXJvb3QsIGFyb290KV0KICAgIGJ5X21pbm9yID0ge25vZGVbInBhcmVudCJdLnNw
bGl0KCI6IilbMV06IG5vZGUgZm9yIG5vZGUgaW4gYWNoaWxkcmVufQogICAgZm9yIG5vZGUgaW4g
ZWNoaWxkcmVuOgogICAgICAgIG90aGVyID0gYnlfbWlub3IuZ2V0KG5vZGVbInBhcmVudCJdLnNw
bGl0KCI6IilbMV0pCiAgICAgICAgaWYgb3RoZXIgaXMgTm9uZSBvciBub2RlWyJraW5kIl0gIT0g
b3RoZXJbImtpbmQiXToKICAgICAgICAgICAgcmV0dXJuIEZhbHNlCiAgICAgICAgcGFpcnMuYXBw
ZW5kKChub2RlLCBvdGhlcikpCiAgICByZXR1cm4gYWxsKF9zYW1lX29wdGlvbnMoX29wdGlvbnMo
YSksIF9vcHRpb25zKGIpLCBhWyJraW5kIl0pIGZvciBhLCBiIGluIHBhaXJzKQoKCmRlZiBfZnJl
ZV9oYW5kbGUodHJlZSwgcHJlZmVycmVkPSJhMTAwOiIpOgogICAgaWYgbm90IHJlLmZ1bGxtYXRj
aChyIlswLTlhLWZBLUZdezEsNH06IiwgcHJlZmVycmVkKToKICAgICAgICByYWlzZSBUdW5lRXJy
b3IoIuaXoOaViOeahOmYn+WIl+WPpeafhCIsIDIpCiAgICBvY2N1cGllZCA9IHtub2RlLmdldCgi
aGFuZGxlIikgZm9yIG5vZGUgaW4gdHJlZX0KICAgIHN0YXJ0ID0gaW50KHByZWZlcnJlZFs6LTFd
LCAxNikKICAgIGZvciBvZmZzZXQgaW4gcmFuZ2UoNjU1MzQpOgogICAgICAgIHZhbHVlID0gMSAr
ICgoc3RhcnQgLSAxICsgb2Zmc2V0KSAlIDY1NTM0KQogICAgICAgIGhhbmRsZSA9IGYie3ZhbHVl
Onh9OiIKICAgICAgICBpZiBoYW5kbGUgbm90IGluIG9jY3VwaWVkOgogICAgICAgICAgICByZXR1
cm4gaGFuZGxlCiAgICByYWlzZSBUdW5lRXJyb3IoIuayoeacieWPr+eUqOmYn+WIl+WPpeafhCIs
IDEwKQoKCmRlZiBfcmVzZXRfcm9vdChjdHgsIGlmYWNlKToKICAgIHRyZWUgPSByZWFkX3RyZWUo
Y3R4LCBpZmFjZSkKICAgIHJvb3RzID0gW25vZGUgZm9yIG5vZGUgaW4gdHJlZSBpZiBub2RlLmdl
dCgicm9vdCIpXQogICAgaWYgbGVuKHJvb3RzKSA9PSAxIGFuZCByb290c1swXS5nZXQoImtpbmQi
KSA9PSAibm9xdWV1ZSI6CiAgICAgICAgcmV0dXJuCiAgICBpZiBsZW4ocm9vdHMpID09IDEgYW5k
IHJvb3RzWzBdLmdldCgiaGFuZGxlIikgPT0gIjA6IjoKICAgICAgICAjIEEga2VybmVsLWNyZWF0
ZWQgaGFuZGxlIHplcm8gY2Fubm90IGJlIGRlbGV0ZWQuIEEgdGVtcG9yYXJ5IG93bmVkCiAgICAg
ICAgIyBoYW5kbGUgbGV0cyBkZWxldGlvbiByZWNyZWF0ZSB0aGUgZGV2aWNlJ3MgYWN0dWFsIGtl
cm5lbCBkZWZhdWx0LgogICAgICAgIGN0eC5tdXRhdGUoWyJ0YyIsICJxZGlzYyIsICJyZXBsYWNl
IiwgImRldiIsIGlmYWNlLCAicm9vdCIsICJoYW5kbGUiLCBfZnJlZV9oYW5kbGUodHJlZSksICJm
cSJdKQogICAgY3R4Lm11dGF0ZShbInRjIiwgInFkaXNjIiwgImRlbCIsICJkZXYiLCBpZmFjZSwg
InJvb3QiXSkKCgpkZWYgcmVzdG9yZV9zbmFwc2hvdChjdHgsIGlmYWNlLCBzbmFwc2hvdCk6CiAg
ICBpZmFjZSA9IHZhbGlkX2ludGVyZmFjZShpZmFjZSkKICAgIGlmIG5vdCBpc2luc3RhbmNlKHNu
YXBzaG90LCBkaWN0KSBvciBzbmFwc2hvdC5nZXQoInNjaGVtYV92ZXJzaW9uIikgIT0gMToKICAg
ICAgICByYWlzZSBUdW5lRXJyb3IoIuaXoOaViOeahOmYn+WIl+W/q+eFpyIsIDEwKQogICAgcm9v
dCwgY2hpbGRyZW4gPSBfdmFsaWRhdGVfdHJlZShzbmFwc2hvdC5nZXQoInRyZWUiLCBbXSkpCiAg
ICBpZiBfc25hcHNob3RfbWF0Y2hlcyhjdHgsIGlmYWNlLCBzbmFwc2hvdCk6CiAgICAgICAgcmV0
dXJuCiAgICBjb21tYW5kcyA9IFtdCiAgICBjdXJyZW50ID0gcmVhZF90cmVlKGN0eCwgaWZhY2Up
CiAgICByb290X2hhbmRsZSA9IF9mcmVlX2hhbmRsZShjdXJyZW50LCByb290WyJoYW5kbGUiXSBp
ZiByb290WyJoYW5kbGUiXSAhPSAiMDoiIGVsc2UgImEyMDA6IikKICAgIGlmIHJvb3RbImtpbmQi
XSAhPSAibm9xdWV1ZSI6CiAgICAgICAgY29tbWFuZHMuYXBwZW5kKFsidGMiLCAicWRpc2MiLCAi
cmVwbGFjZSIsICJkZXYiLCBpZmFjZSwgInJvb3QiLCAiaGFuZGxlIiwgcm9vdF9oYW5kbGUsIHJv
b3RbImtpbmQiXV0gKyBfb3B0aW9uX2FyZ3Mocm9vdCkpCiAgICAgICAgaGFuZGxlcyA9IHtyb290
X2hhbmRsZSwgKihub2RlLmdldCgiaGFuZGxlIikgZm9yIG5vZGUgaW4gY3VycmVudCl9CiAgICAg
ICAgZm9yIG5vZGUgaW4gc29ydGVkKGNoaWxkcmVuLCBrZXk9bGFtYmRhIGl0ZW06IGludChpdGVt
WyJwYXJlbnQiXS5zcGxpdCgiOiIpWzFdLCAxNikpOgogICAgICAgICAgICBoYW5kbGUgPSBub2Rl
WyJoYW5kbGUiXQogICAgICAgICAgICBpZiBoYW5kbGUgPT0gIjA6IiBvciBoYW5kbGUgaW4gaGFu
ZGxlczoKICAgICAgICAgICAgICAgIGhhbmRsZSA9IF9mcmVlX2hhbmRsZShbeyJoYW5kbGUiOiB2
YWx1ZX0gZm9yIHZhbHVlIGluIGhhbmRsZXNdLCAiYTIwMToiKQogICAgICAgICAgICBoYW5kbGVz
LmFkZChoYW5kbGUpCiAgICAgICAgICAgIHBhcmVudCA9IHJvb3RfaGFuZGxlICsgbm9kZVsicGFy
ZW50Il0uc3BsaXQoIjoiKVsxXQogICAgICAgICAgICBjb21tYW5kcy5hcHBlbmQoWyJ0YyIsICJx
ZGlzYyIsICJyZXBsYWNlIiwgImRldiIsIGlmYWNlLCAicGFyZW50IiwgcGFyZW50LCAiaGFuZGxl
IiwgaGFuZGxlLCBub2RlWyJraW5kIl1dICsgX29wdGlvbl9hcmdzKG5vZGUpKQogICAgIyBBIGZy
ZXNoIGhhbmRsZSByZXBsYWNlcyB0aGUgd2hvbGUgcm9vdCB0cmVlIHdpdGhvdXQgaW5oZXJpdGlu
ZyBvcHRpb25zLgogICAgIyBub3F1ZXVlIGlzIGludHJpbnNpYyB0byB0aGUgZGV2aWNlIGFuZCBp
cyByZXN0b3JlZCBieSBkZWxldGluZyBvdXIgcm9vdC4KICAgIGlmIHJvb3RbImtpbmQiXSA9PSAi
bm9xdWV1ZSI6CiAgICAgICAgX3Jlc2V0X3Jvb3QoY3R4LCBpZmFjZSkKICAgIGludHJpbnNpY19j
aGlsZHJlbiA9IHt9CiAgICBleHBlY3RlZF9jaGlsZHJlbiA9IHtub2RlWyJwYXJlbnQiXS5zcGxp
dCgiOiIpWzFdOiBub2RlIGZvciBub2RlIGluIGNoaWxkcmVufQogICAgZm9yIGFyZ3YgaW4gY29t
bWFuZHM6CiAgICAgICAgaWYgcm9vdFsia2luZCJdID09ICJtcSIgYW5kICJwYXJlbnQiIGluIGFy
Z3Y6CiAgICAgICAgICAgIHBhcmVudCA9IGFyZ3ZbYXJndi5pbmRleCgicGFyZW50IikgKyAxXQog
ICAgICAgICAgICBleHBlY3RlZCA9IGV4cGVjdGVkX2NoaWxkcmVuW3BhcmVudC5zcGxpdCgiOiIp
WzFdXQogICAgICAgICAgICBpbnRyaW5zaWMgPSBpbnRyaW5zaWNfY2hpbGRyZW4uZ2V0KHBhcmVu
dCkKICAgICAgICAgICAgaWYgKGV4cGVjdGVkWyJoYW5kbGUiXSA9PSAiMDoiIGFuZCBpbnRyaW5z
aWMgYW5kIGludHJpbnNpYy5nZXQoImhhbmRsZSIpID09ICIwOiIKICAgICAgICAgICAgICAgICAg
ICBhbmQgaW50cmluc2ljWyJraW5kIl0gPT0gZXhwZWN0ZWRbImtpbmQiXQogICAgICAgICAgICAg
ICAgICAgIGFuZCBfc2FtZV9vcHRpb25zKF9vcHRpb25zKGV4cGVjdGVkKSwgX29wdGlvbnMoaW50
cmluc2ljKSwgZXhwZWN0ZWRbImtpbmQiXSkpOgogICAgICAgICAgICAgICAgIyBtcSBoYXMgYWxy
ZWFkeSByZWNyZWF0ZWQgdGhpcyBleGFjdCBpbnRyaW5zaWMgZGVmYXVsdCBsZWFmLgogICAgICAg
ICAgICAgICAgY29udGludWUKICAgICAgICB0cnk6CiAgICAgICAgICAgIGN0eC5tdXRhdGUoYXJn
dikKICAgICAgICBleGNlcHQgVHVuZUVycm9yIGFzIGV4YzoKICAgICAgICAgICAgaWYgIndlaWdo
dHMiIG5vdCBpbiBhcmd2IG9yICJOb3QgZW5vdWdoIGVsZW1lbnRzIGluIHdlaWdodHMiIG5vdCBp
biBzdHIoZXhjKToKICAgICAgICAgICAgICAgIHJhaXNlCiAgICAgICAgICAgICMgaXByb3V0ZTIg
YmVmb3JlIDYuMTYgaGFzIGFuIGV4dHJhIE5FWFRfQVJHIGluIHRoZSB3ZWlnaHRzCiAgICAgICAg
ICAgICMgcGFyc2VyLiBJdHMgZXJyb3Igb2NjdXJzIGJlZm9yZSBhbnkgbmV0bGluayBtdXRhdGlv
bi4gUmV0cnkKICAgICAgICAgICAgIyBvbmx5IHRoYXQgZXhhY3QgZXJyb3IsIHN1cHBseWluZyBp
dHMgc2tpcHBlZCBmaXJzdCBhcmd1bWVudC4KICAgICAgICAgICAgaW5kZXggPSBhcmd2LmluZGV4
KCJ3ZWlnaHRzIikgKyAxCiAgICAgICAgICAgIGN0eC5tdXRhdGUoYXJndls6aW5kZXhdICsgW2Fy
Z3ZbaW5kZXhdXSArIGFyZ3ZbaW5kZXg6XSkKICAgICAgICBpZiByb290WyJraW5kIl0gPT0gIm1x
IiBhbmQgInJvb3QiIGluIGFyZ3Y6CiAgICAgICAgICAgIGludHJpbnNpY19jaGlsZHJlbiA9IHtu
b2RlWyJwYXJlbnQiXTogbm9kZSBmb3Igbm9kZSBpbiByZWFkX3RyZWUoY3R4LCBpZmFjZSkgaWYg
InBhcmVudCIgaW4gbm9kZX0KICAgIGlmIG5vdCBfc25hcHNob3RfbWF0Y2hlcyhjdHgsIGlmYWNl
LCBzbmFwc2hvdCk6CiAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLmgaLlpI3lkI7nmoTlrozmlbTp
mJ/liJfphY3nva7kuI7lv6vnhafkuI3kuIDoh7QiLCAyMCkKCgpkZWYgX3ZhbGlkYXRlX3Byb2Zp
bGUocHJvZmlsZSk6CiAgICBtb2RlID0gcHJvZmlsZS5nZXQoIm1vZGUiKQogICAgaWYgbW9kZSBu
b3QgaW4gKCJmcSIsICJ0YmYiLCAidGJmLWZxIik6CiAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLk
uI3mlK/mjIHnmoTlh7rlj6PmqKHlvI8iLCAyKQogICAgaWYgbW9kZSAhPSAiZnEiOgogICAgICAg
IGZvciBrZXkgaW4gKCJyYXRlX2JwcyIsICJidXJzdF9ieXRlcyIsICJsYXRlbmN5X21zIik6CiAg
ICAgICAgICAgIF9udW1iZXIocHJvZmlsZS5nZXQoa2V5KSwga2V5LCAxIGlmIGtleSAhPSAibGF0
ZW5jeV9tcyIgZWxzZSAwLjAwMSkKICAgIGZvciBrZXkgaW4gKCJtYXhyYXRlX2JwcyIsICJsaW1p
dF9wYWNrZXRzIiwgImZsb3dfbGltaXQiLCAib3JwaGFuX21hc2siKToKICAgICAgICBpZiBwcm9m
aWxlLmdldChrZXkpIGlzIG5vdCBOb25lOgogICAgICAgICAgICBfbnVtYmVyKHByb2ZpbGVba2V5
XSwga2V5LCAwIGlmIGtleSA9PSAib3JwaGFuX21hc2siIGVsc2UgMSkKICAgIGlmIHByb2ZpbGUu
Z2V0KCJtYXhyYXRlX2JwcyIsIDApIGlzIG5vdCBOb25lIGFuZCBwcm9maWxlLmdldCgibWF4cmF0
ZV9icHMiLCAwKSA+PSAweEZGRkZGRkZGICogODoKICAgICAgICByYWlzZSBUdW5lRXJyb3IoImZx
IG1heHJhdGUg6LaF6L+H5YaF5qC45pSv5oyB6IyD5Zu0IiwgMikKCgpkZWYgX2ZxX3Byb2ZpbGVf
b3B0aW9ucyhwcm9maWxlKToKICAgIG9wdHMgPSB7fQogICAgZm9yIGtleSwgdGNfa2V5IGluICgo
ImxpbWl0X3BhY2tldHMiLCAibGltaXQiKSwgKCJmbG93X2xpbWl0IiwgImZsb3dfbGltaXQiKSwg
KCJvcnBoYW5fbWFzayIsICJvcnBoYW5fbWFzayIpKToKICAgICAgICBpZiBwcm9maWxlLmdldChr
ZXkpIGlzIG5vdCBOb25lOgogICAgICAgICAgICBvcHRzW3RjX2tleV0gPSBwcm9maWxlW2tleV0K
ICAgIGlmIHByb2ZpbGUuZ2V0KCJtYXhyYXRlX2JwcyIpIGlzIG5vdCBOb25lOgogICAgICAgIG9w
dHNbIm1heHJhdGUiXSA9IHByb2ZpbGVbIm1heHJhdGVfYnBzIl0gLy8gOAogICAgcmV0dXJuIG9w
dHMKCgpkZWYgcHJvZmlsZV9tYXRjaGVzKGN0eCwgaWZhY2UsIHByb2ZpbGUpOgogICAgX3ZhbGlk
YXRlX3Byb2ZpbGUocHJvZmlsZSkKICAgIHRyeToKICAgICAgICByb290LCBjaGlsZHJlbiA9IF92
YWxpZGF0ZV90cmVlKHJlYWRfdHJlZShjdHgsIGlmYWNlKSkKICAgIGV4Y2VwdCBUdW5lRXJyb3I6
CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBtb2RlID0gcHJvZmlsZVsibW9kZSJdCiAgICBpZiBt
b2RlID09ICJmcSI6CiAgICAgICAgcmV0dXJuIHJvb3RbImtpbmQiXSA9PSAiZnEiIGFuZCBub3Qg
Y2hpbGRyZW4gYW5kIF9zYW1lX29wdGlvbnMoX2ZxX3Byb2ZpbGVfb3B0aW9ucyhwcm9maWxlKSwg
X29wdGlvbnMocm9vdCksICJmcSIsIGNvbXBsZXRlPUZhbHNlKQogICAgaWYgcm9vdFsia2luZCJd
ICE9ICJ0YmYiIG9yIGxlbihjaGlsZHJlbikgIT0gKDEgaWYgbW9kZSA9PSAidGJmLWZxIiBlbHNl
IDApOgogICAgICAgIHJldHVybiBGYWxzZQogICAgb3B0cyA9IF9vcHRpb25zKHJvb3QpCiAgICB3
YW50ZWQgPSB7InJhdGUiOiBwcm9maWxlWyJyYXRlX2JwcyJdIC8vIDgsICJidXJzdCI6IHByb2Zp
bGVbImJ1cnN0X2J5dGVzIl0sICJsYXQiOiBwcm9maWxlWyJsYXRlbmN5X21zIl0gKiAxMDAwfQog
ICAgaWYgbm90IF9zYW1lX29wdGlvbnMod2FudGVkLCBvcHRzLCAidGJmIik6CiAgICAgICAgcmV0
dXJuIEZhbHNlCiAgICByZXR1cm4gbW9kZSA9PSAidGJmIiBvciAoY2hpbGRyZW5bMF1bImtpbmQi
XSA9PSAiZnEiIGFuZCBfc2FtZV9vcHRpb25zKF9mcV9wcm9maWxlX29wdGlvbnMocHJvZmlsZSks
IF9vcHRpb25zKGNoaWxkcmVuWzBdKSwgImZxIiwgY29tcGxldGU9RmFsc2UpKQoKCmRlZiBhcHBs
eV9wcm9maWxlKGN0eCwgaWZhY2UsIHByb2ZpbGUsIGhhbmRsZT0iYTEwMDoiKToKICAgIGlmYWNl
ID0gdmFsaWRfaW50ZXJmYWNlKGlmYWNlKQogICAgX3ZhbGlkYXRlX3Byb2ZpbGUocHJvZmlsZSkK
ICAgIGlmIHByb2ZpbGVfbWF0Y2hlcyhjdHgsIGlmYWNlLCBwcm9maWxlKToKICAgICAgICByZXR1
cm4KICAgIHRyZWUgPSByZWFkX3RyZWUoY3R4LCBpZmFjZSkKICAgIHJvb3RfaGFuZGxlID0gX2Zy
ZWVfaGFuZGxlKHRyZWUsIGhhbmRsZSkKICAgIG1vZGUgPSBwcm9maWxlWyJtb2RlIl0KICAgIGFy
Z3YgPSBbInRjIiwgInFkaXNjIiwgInJlcGxhY2UiLCAiZGV2IiwgaWZhY2UsICJyb290IiwgImhh
bmRsZSIsIHJvb3RfaGFuZGxlXQogICAgaWYgbW9kZSA9PSAiZnEiOgogICAgICAgIGFyZ3YgKz0g
WyJmcSJdICsgX29wdGlvbl9hcmdzKHsia2luZCI6ICJmcSIsICJvcHRpb25zIjogX2ZxX3Byb2Zp
bGVfb3B0aW9ucyhwcm9maWxlKX0sIGNvbXBsZXRlPUZhbHNlKQogICAgZWxzZToKICAgICAgICBh
cmd2ICs9IFsidGJmIiwgInJhdGUiLCBzdHIocHJvZmlsZVsicmF0ZV9icHMiXSkgKyAiYml0Iiwg
ImJ1cnN0Iiwgc3RyKHByb2ZpbGVbImJ1cnN0X2J5dGVzIl0pLAogICAgICAgICAgICAgICAgICJs
YXRlbmN5IiwgZm9ybWF0KHByb2ZpbGVbImxhdGVuY3lfbXMiXSwgIi4xMmciKSArICJtcyJdCiAg
ICBjdHgubXV0YXRlKGFyZ3YpCiAgICBpZiBtb2RlID09ICJ0YmYtZnEiOgogICAgICAgIGNoaWxk
X2hhbmRsZSA9IF9mcmVlX2hhbmRsZSh0cmVlICsgW3siaGFuZGxlIjogcm9vdF9oYW5kbGV9XSwg
cm9vdF9oYW5kbGUpCiAgICAgICAgY3R4Lm11dGF0ZShbInRjIiwgInFkaXNjIiwgInJlcGxhY2Ui
LCAiZGV2IiwgaWZhY2UsICJwYXJlbnQiLCByb290X2hhbmRsZSArICIxIiwgImhhbmRsZSIsIGNo
aWxkX2hhbmRsZSwKICAgICAgICAgICAgICAgICAgICAiZnEiXSArIF9vcHRpb25fYXJncyh7Imtp
bmQiOiAiZnEiLCAib3B0aW9ucyI6IF9mcV9wcm9maWxlX29wdGlvbnMocHJvZmlsZSl9LCBjb21w
bGV0ZT1GYWxzZSkpCiAgICBpZiBub3QgcHJvZmlsZV9tYXRjaGVzKGN0eCwgaWZhY2UsIHByb2Zp
bGUpOgogICAgICAgIHJhaXNlIFR1bmVFcnJvcigi6Zif5YiX5bqU55So5ZCO6K+75Zue5qCh6aqM
5aSx6LSlIiwgMjApCgoKZGVmIF9wb3NpdGl2ZSh2YWx1ZSwgbmFtZSwgZGVmYXVsdD1Ob25lKToK
ICAgIHZhbHVlID0gZGVmYXVsdCBpZiB2YWx1ZSBpcyBOb25lIGVsc2UgdmFsdWUKICAgIHRyeToK
ICAgICAgICByZXN1bHQgPSBmbG9hdCh2YWx1ZSkKICAgIGV4Y2VwdCAoVHlwZUVycm9yLCBWYWx1
ZUVycm9yKSBhcyBleGM6CiAgICAgICAgcmFpc2UgVHVuZUVycm9yKG5hbWUgKyAiIOW/hemhu+S4
uuato+aVsCIsIDIpIGZyb20gZXhjCiAgICBpZiBub3QgbWF0aC5pc2Zpbml0ZShyZXN1bHQpIG9y
IHJlc3VsdCA8PSAwOgogICAgICAgIHJhaXNlIFR1bmVFcnJvcihuYW1lICsgIiDlv4XpobvkuLrm
raPmlbAiLCAyKQogICAgcmV0dXJuIHJlc3VsdAoKCmRlZiBfcHJvZmlsZV9mcm9tX2FyZ3MoYXJn
cyk6CiAgICBtb2RlID0gYXJncy5tb2RlCiAgICBwcm9maWxlID0geyJtb2RlIjogbW9kZX0KICAg
IGlmIG1vZGUgIT0gImZxIjoKICAgICAgICBpZiBnZXRhdHRyKGFyZ3MsICJyYXRlX21icHMiLCBO
b25lKSBpcyBOb25lOgogICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIlRCRiDlv4XpobvmjIfl
rpogLS1yYXRlLW1icHMiLCAyKQogICAgICAgIHByb2ZpbGUudXBkYXRlKHJhdGVfYnBzPXBhcnNl
X21icHMoYXJncy5yYXRlX21icHMpLAogICAgICAgICAgICAgICAgICAgICAgIGJ1cnN0X2J5dGVz
PWludChfcG9zaXRpdmUoZ2V0YXR0cihhcmdzLCAiYnVyc3Rfa2liIiwgTm9uZSksICJidXJzdC1r
aWIiLCA2NCkgKiAxMDI0KSwKICAgICAgICAgICAgICAgICAgICAgICBsYXRlbmN5X21zPV9wb3Np
dGl2ZShnZXRhdHRyKGFyZ3MsICJsYXRlbmN5X21zIiwgTm9uZSksICJsYXRlbmN5LW1zIiwgMjAg
aWYgbW9kZSA9PSAidGJmLWZxIiBlbHNlIDUwKSkKICAgIGVsaWYgYW55KGdldGF0dHIoYXJncywg
a2V5LCBOb25lKSBpcyBub3QgTm9uZSBmb3Iga2V5IGluICgicmF0ZV9tYnBzIiwgImJ1cnN0X2tp
YiIsICJsYXRlbmN5X21zIikpOgogICAgICAgIHJhaXNlIFR1bmVFcnJvcigiZnEg5LiN5o6l5Y+X
5oC76YCf546HL2J1cnN0L2xhdGVuY3kg5Y+C5pWwIiwgMikKICAgIG1heHJhdGUgPSBnZXRhdHRy
KGFyZ3MsICJtYXhyYXRlX21icHMiLCBOb25lKQogICAgaWYgbW9kZSA9PSAidGJmIiBhbmQgYW55
KGdldGF0dHIoYXJncywga2V5LCBOb25lKSBpcyBub3QgTm9uZSBmb3Iga2V5IGluICgibWF4cmF0
ZV9tYnBzIiwgInF1ZXVlX3BhY2tldHMiLCAiZmxvd19saW1pdCIpKToKICAgICAgICByYWlzZSBU
dW5lRXJyb3IoIue6ryBUQkYg5LiN5o6l5Y+XIGZxIOWPguaVsCIsIDIpCiAgICBpZiBtb2RlICE9
ICJ0YmYiOgogICAgICAgIHByb2ZpbGVbIm1heHJhdGVfYnBzIl0gPSBOb25lIGlmIG1heHJhdGUg
aXMgTm9uZSBvciBzdHIobWF4cmF0ZSkubG93ZXIoKSA9PSAibm9uZSIgZWxzZSBwYXJzZV9tYnBz
KG1heHJhdGUpCiAgICAgICAgZm9yIGtleSwgZGVzdCwgZGVmYXVsdCBpbiAoKCJxdWV1ZV9wYWNr
ZXRzIiwgImxpbWl0X3BhY2tldHMiLCAxMDI0KSwgKCJmbG93X2xpbWl0IiwgImZsb3dfbGltaXQi
LCAxMDApKToKICAgICAgICAgICAgdmFsdWUgPSBnZXRhdHRyKGFyZ3MsIGtleSwgTm9uZSkKICAg
ICAgICAgICAgaWYgdmFsdWUgaXMgbm90IE5vbmUgb3IgbW9kZSA9PSAidGJmLWZxIjoKICAgICAg
ICAgICAgICAgIG51bWJlciA9IF9wb3NpdGl2ZSh2YWx1ZSwga2V5LCBkZWZhdWx0KQogICAgICAg
ICAgICAgICAgaWYgbm90IG51bWJlci5pc19pbnRlZ2VyKCk6CiAgICAgICAgICAgICAgICAgICAg
cmFpc2UgVHVuZUVycm9yKGtleSArICIg5b+F6aG75Li65pW05pWwIiwgMikKICAgICAgICAgICAg
ICAgIHByb2ZpbGVbZGVzdF0gPSBpbnQobnVtYmVyKQogICAgX3ZhbGlkYXRlX3Byb2ZpbGUocHJv
ZmlsZSkKICAgIHJldHVybiBwcm9maWxlCgoKZGVmIF91bml0X25hbWUoaWZhY2UpOgogICAgIyBz
eXN0ZW1kLWVzY2FwZSdzIGluc3RhbmNlIGVzY2FwaW5nLCB3aXRob3V0IGFuIGV4dHJhIHJ1bnRp
bWUgZGVwZW5kZW5jeS4KICAgIGVzY2FwZWQgPSAiIi5qb2luKGNoYXIgaWYgY2hhci5pc2FzY2lp
KCkgYW5kIChjaGFyLmlzYWxudW0oKSBvciBjaGFyIGluICJfOi4iKSBlbHNlICJcXHgiICsgZm9y
bWF0KG9yZChjaGFyKSwgIjAyeCIpIGZvciBjaGFyIGluIGlmYWNlKQogICAgaWYgZXNjYXBlZC5z
dGFydHN3aXRoKCIuIik6CiAgICAgICAgZXNjYXBlZCA9ICJcXHgyZSIgKyBlc2NhcGVkWzE6XQog
ICAgcmV0dXJuICJ2cHNjdGwtbmV0d29yay10dW5lLWVncmVzc0AiICsgZXNjYXBlZCArICIuc2Vy
dmljZSIKCgpkZWYgX3VuaXRfY29udGVudChpZmFjZSk6CiAgICByZXR1cm4gKE1BUktFUiArICJc
bltVbml0XVxuRGVzY3JpcHRpb249dnBzY3RsIGVncmVzcyB0dW5pbmcgIiArIGlmYWNlICsKICAg
ICAgICAgICAgIlxuV2FudHM9bmV0d29yay1vbmxpbmUudGFyZ2V0XG5BZnRlcj1uZXR3b3JrLW9u
bGluZS50YXJnZXRcblxuW1NlcnZpY2VdXG5UeXBlPW9uZXNob3RcblJlbWFpbkFmdGVyRXhpdD15
ZXNcbiIKICAgICAgICAgICAgIkV4ZWNTdGFydD0vdXNyL2Jpbi9weXRob24zIC91c3IvbG9jYWwv
bGliL3Zwc2N0bC9uZXR3b3JrLXR1bmUvcnVudGltZS5weXogaW50ZXJuYWwgZWdyZXNzLWFwcGx5
ICIgKyBpZmFjZSArCiAgICAgICAgICAgICJcblxuW0luc3RhbGxdXG5XYW50ZWRCeT1tdWx0aS11
c2VyLnRhcmdldFxuIikKCgpjbGFzcyBFZ3Jlc3NNYW5hZ2VyOgogICAgZGVmIF9faW5pdF9fKHNl
bGYsIGN0eCk6CiAgICAgICAgc2VsZi5jdHggPSBjdHgKICAgICAgICBzZWxmLnN0YXRlX3BhdGgg
PSBjdHguc3RhdGVfZGlyIC8gImVncmVzcy5qc29uIgoKICAgIGRlZiBfbG9hZChzZWxmKToKICAg
ICAgICBzdGF0ZSA9IHNlbGYuY3R4LnJlYWRfanNvbihzZWxmLnN0YXRlX3BhdGgsIHsic2NoZW1h
X3ZlcnNpb24iOiAxLCAiaW50ZXJmYWNlcyI6IHt9fSkKICAgICAgICBpZiBub3QgaXNpbnN0YW5j
ZShzdGF0ZSwgZGljdCkgb3Igc3RhdGUuZ2V0KCJzY2hlbWFfdmVyc2lvbiIpICE9IDEgb3Igbm90
IGlzaW5zdGFuY2Uoc3RhdGUuZ2V0KCJpbnRlcmZhY2VzIiksIGRpY3QpOgogICAgICAgICAgICBy
YWlzZSBUdW5lRXJyb3IoIuWHuuWPo+eKtuaAgeaWh+S7tuagvOW8j+aXoOaViCIsIDEwKQogICAg
ICAgIHJldHVybiBzdGF0ZQoKICAgIGRlZiBfcmVhZHkoc2VsZiwgaWZhY2UpOgogICAgICAgIHZh
bGlkX2ludGVyZmFjZShpZmFjZSkKICAgICAgICBzZWxmLmN0eC5yZXF1aXJlX211dGF0aW9uKCkK
ICAgICAgICBzZWxmLmN0eC5yZXF1aXJlX3Rvb2xzKCJ0YyIsICJpcCIsICJzeXN0ZW1jdGwiKQog
ICAgICAgIHNlbGYuY3R4LnJ1bihbImlwIiwgImxpbmsiLCAic2hvdyIsICJkZXYiLCBpZmFjZV0p
CgogICAgZGVmIF9vd25lZF91bml0KHNlbGYsIG5hbWUpOgogICAgICAgIHNuYXBzaG90ID0gc2Vs
Zi5jdHgudW5pdF9zdGF0ZShuYW1lKQogICAgICAgIHBhdGggPSBzZWxmLmN0eC51bml0X3BhdGgo
bmFtZSkKICAgICAgICBpZiBub3Qgc25hcHNob3QuZ2V0KCJleGlzdHMiKSBhbmQgc25hcHNob3Qu
Z2V0KCJsb2FkX3N0YXRlIikgbm90IGluIChOb25lLCAiIiwgIm5vdC1mb3VuZCIpOgogICAgICAg
ICAgICByYWlzZSBUdW5lRXJyb3IoIuWQjOWQjeWHuuWPo+acjeWKoeadpeiHquWPl+euoei3r+W+
hOS7peWklu+8miIgKyBuYW1lLCAxMCkKICAgICAgICBpZiBzbmFwc2hvdC5nZXQoImV4aXN0cyIp
IGFuZCBNQVJLRVIgbm90IGluIHBhdGgucmVhZF90ZXh0KCk6CiAgICAgICAgICAgIHJhaXNlIFR1
bmVFcnJvcigi5Ye65Y+j5oyB5LmF5YyW5Y2V5YWD5bey6KKr5aSW6YOo5o6l566h77yaIiArIG5h
bWUsIDEwKQogICAgICAgIHJldHVybiBzbmFwc2hvdAoKICAgIGRlZiBfbGVnYWN5X2NhbmRpZGF0
ZXMoc2VsZik6CiAgICAgICAgcmVzdWx0ID0ge30KICAgICAgICBmb3IgbmFtZSBpbiBMRUdBQ1lf
VU5JVFM6CiAgICAgICAgICAgIHNuYXBzaG90ID0gc2VsZi5jdHgudW5pdF9zdGF0ZShuYW1lKQog
ICAgICAgICAgICBpZiBzbmFwc2hvdC5nZXQoImV4aXN0cyIpIGFuZCAoc25hcHNob3QuZ2V0KCJh
Y3RpdmUiKSBvciBzbmFwc2hvdC5nZXQoImVuYWJsZWQiKSk6CiAgICAgICAgICAgICAgICByZXN1
bHRbbmFtZV0gPSBzbmFwc2hvdAogICAgICAgIHJldHVybiByZXN1bHQKCiAgICBkZWYgX3JvbGxi
YWNrKHNlbGYsIGlmYWNlLCB0cmVlLCBzdGF0ZV9maWxlLCB1bml0X25hbWUsIHVuaXQsIGxlZ2Fj
eSwgZHJvcGlucywgb3JpZ2luYWxfZXJyb3IpOgogICAgICAgIGVycm9ycyA9IFtdCiAgICAgICAg
Zm9yIG5hbWUsIHNuYXBzaG90IGluIGxlZ2FjeS5pdGVtcygpOgogICAgICAgICAgICB0cnk6CiAg
ICAgICAgICAgICAgICBzZWxmLmN0eC5yZXN0b3JlX3VuaXQobmFtZSwgc25hcHNob3QpCiAgICAg
ICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZXhjOgogICAgICAgICAgICAgICAgZXJyb3JzLmFw
cGVuZChzdHIoZXhjKSkKICAgICAgICBmb3IgcGF0aCwgc25hcHNob3QgaW4gZHJvcGluczoKICAg
ICAgICAgICAgdHJ5OgogICAgICAgICAgICAgICAgc2VsZi5jdHgucmVzdG9yZV9maWxlKHBhdGgs
IHNuYXBzaG90KQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGV4YzoKICAgICAgICAg
ICAgICAgIGVycm9ycy5hcHBlbmQoc3RyKGV4YykpCiAgICAgICAgZm9yIGFjdGlvbiBpbiAobGFt
YmRhOiBzZWxmLmN0eC5yZXN0b3JlX2ZpbGUoc2VsZi5zdGF0ZV9wYXRoLCBzdGF0ZV9maWxlKSwK
ICAgICAgICAgICAgICAgICAgICAgICBsYW1iZGE6IHNlbGYuY3R4LnJlc3RvcmVfdW5pdCh1bml0
X25hbWUsIHVuaXQpLAogICAgICAgICAgICAgICAgICAgICAgIGxhbWJkYTogc2VsZi5jdHguc3lz
dGVtY3RsKCJkYWVtb24tcmVsb2FkIiksCiAgICAgICAgICAgICAgICAgICAgICAgbGFtYmRhOiBy
ZXN0b3JlX3NuYXBzaG90KHNlbGYuY3R4LCBpZmFjZSwgdHJlZSkpOgogICAgICAgICAgICB0cnk6
CiAgICAgICAgICAgICAgICBhY3Rpb24oKQogICAgICAgICAgICBleGNlcHQgRXhjZXB0aW9uIGFz
IGV4YzoKICAgICAgICAgICAgICAgIGVycm9ycy5hcHBlbmQoc3RyKGV4YykpCiAgICAgICAgaWYg
ZXJyb3JzOgogICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuWHuuWPo+aTjeS9nOWksei0pe+8
jOWbnua7muacquWujOaIkO+8miIgKyAiOyAiLmpvaW4oZXJyb3JzKSwgMzApIGZyb20gb3JpZ2lu
YWxfZXJyb3IKICAgICAgICByYWlzZSBvcmlnaW5hbF9lcnJvcgoKICAgIGRlZiBfaW5zdGFsbChz
ZWxmLCBpZmFjZSwgcHJvZmlsZSwgc3RhdGUsIG9yaWdpbmFsLCBsZWdhY3k9Tm9uZSk6CiAgICAg
ICAgY3R4LCBuYW1lID0gc2VsZi5jdHgsIF91bml0X25hbWUoaWZhY2UpCiAgICAgICAgdW5pdCA9
IHNlbGYuX293bmVkX3VuaXQobmFtZSkKICAgICAgICBiZWZvcmUgPSBjYXB0dXJlX3NuYXBzaG90
KGN0eCwgaWZhY2UpCiAgICAgICAgc3RhdGVfZmlsZSA9IGN0eC5zbmFwc2hvdF9maWxlKHNlbGYu
c3RhdGVfcGF0aCkKICAgICAgICBsZWdhY3kgPSBsZWdhY3kgb3Ige30KICAgICAgICBkcm9waW5z
ID0gW10KICAgICAgICB0cnk6CiAgICAgICAgICAgIGN0eC5pbnN0YWxsX3J1bnRpbWUoKQogICAg
ICAgICAgICBmb3Igb2xkX25hbWUgaW4gbGVnYWN5OgogICAgICAgICAgICAgICAgcGF0aCA9IGN0
eC5wYXRoKCIvcnVuL3N5c3RlbWQvc3lzdGVtLyIgKyBvbGRfbmFtZSArICIuZC85MC12cHNjdGwt
bmV0d29yay10dW5lLWFkb3B0LmNvbmYiKQogICAgICAgICAgICAgICAgc2F2ZWQgPSBjdHguc25h
cHNob3RfZmlsZShwYXRoKQogICAgICAgICAgICAgICAgaWYgc2F2ZWQuZ2V0KCJleGlzdHMiKToK
ICAgICAgICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaOpeeuoeeUqOS4tOaXtiBkcm9w
LWluIOW3suWtmOWcqO+8miIgKyBzdHIocGF0aCksIDEwKQogICAgICAgICAgICAgICAgZHJvcGlu
cy5hcHBlbmQoKHBhdGgsIHNhdmVkKSkKICAgICAgICAgICAgICAgIGN0eC5hdG9taWNfd3JpdGUo
cGF0aCwgIltTZXJ2aWNlXVxuRXhlY1N0b3A9XG5FeGVjU3RvcFBvc3Q9XG4iLCAwbzY0NCkKICAg
ICAgICAgICAgaWYgbGVnYWN5OgogICAgICAgICAgICAgICAgY3R4LnN5c3RlbWN0bCgiZGFlbW9u
LXJlbG9hZCIpCiAgICAgICAgICAgIGZvciBvbGRfbmFtZSBpbiBsZWdhY3k6CiAgICAgICAgICAg
ICAgICBjdHguc3lzdGVtY3RsKCJzdG9wIiwgb2xkX25hbWUpCiAgICAgICAgICAgICAgICBjdHgu
c3lzdGVtY3RsKCJkaXNhYmxlIiwgb2xkX25hbWUpCiAgICAgICAgICAgIGFwcGx5X3Byb2ZpbGUo
Y3R4LCBpZmFjZSwgcHJvZmlsZSkKICAgICAgICAgICAgcmVjb3JkID0geyJwcm9maWxlIjogcHJv
ZmlsZSwgIm9yaWdpbmFsIjogb3JpZ2luYWwsICJlbmFibGVkIjogVHJ1ZX0KICAgICAgICAgICAg
cHJldmlvdXMgPSBzdGF0ZVsiaW50ZXJmYWNlcyJdLmdldChpZmFjZSwge30pCiAgICAgICAgICAg
IGlmIHByZXZpb3VzLmdldCgibGVnYWN5X3VuaXRzIikgb3IgbGVnYWN5OgogICAgICAgICAgICAg
ICAgcmVjb3JkWyJsZWdhY3lfdW5pdHMiXSA9IHByZXZpb3VzLmdldCgibGVnYWN5X3VuaXRzIiwg
bGVnYWN5KQogICAgICAgICAgICBzdGF0ZVsiaW50ZXJmYWNlcyJdW2lmYWNlXSA9IHJlY29yZAog
ICAgICAgICAgICBjdHgud3JpdGVfanNvbihzZWxmLnN0YXRlX3BhdGgsIHN0YXRlKQogICAgICAg
ICAgICBjdHgud3JpdGVfdW5pdChuYW1lLCBfdW5pdF9jb250ZW50KGlmYWNlKSkKICAgICAgICAg
ICAgY3R4LnN5c3RlbWN0bCgiZGFlbW9uLXJlbG9hZCIpCiAgICAgICAgICAgICMgRG8gbm90IHN0
YXJ0IGhlcmU6IEV4ZWNTdGFydCB0YWtlcyB0aGUgc2FtZSBsb2NrcyBhbmQgdGhlIHByb2ZpbGUK
ICAgICAgICAgICAgIyBpcyBhbHJlYWR5IGFwcGxpZWQuIFRoZSBlbmFibGVkIHVuaXQgcmVjb25j
aWxlcyBvbiB0aGUgbmV4dCBib290LgogICAgICAgICAgICBjdHguc3lzdGVtY3RsKCJlbmFibGUi
LCBuYW1lKQogICAgICAgICAgICBmb3IgcGF0aCwgc2F2ZWQgaW4gZHJvcGluczoKICAgICAgICAg
ICAgICAgIGN0eC5yZXN0b3JlX2ZpbGUocGF0aCwgc2F2ZWQpCiAgICAgICAgICAgIGlmIGRyb3Bp
bnM6CiAgICAgICAgICAgICAgICBjdHguc3lzdGVtY3RsKCJkYWVtb24tcmVsb2FkIikKICAgICAg
ICBleGNlcHQgQmFzZUV4Y2VwdGlvbiBhcyBleGM6CiAgICAgICAgICAgIHNlbGYuX3JvbGxiYWNr
KGlmYWNlLCBiZWZvcmUsIHN0YXRlX2ZpbGUsIG5hbWUsIHVuaXQsIGxlZ2FjeSwgZHJvcGlucywg
ZXhjKQogICAgICAgIHJldHVybiB7ImNoYW5nZWQiOiBUcnVlLCAiaW50ZXJmYWNlIjogaWZhY2Us
ICJwcm9maWxlIjogcHJvZmlsZSwgInNlcnZpY2UiOiBuYW1lLCAiYWRvcHRlZCI6IGxpc3QobGVn
YWN5KX0KCiAgICBkZWYgc2V0KHNlbGYsIGFyZ3MpOgogICAgICAgIGlmYWNlLCBwcm9maWxlID0g
dmFsaWRfaW50ZXJmYWNlKGFyZ3MuaW50ZXJmYWNlKSwgX3Byb2ZpbGVfZnJvbV9hcmdzKGFyZ3Mp
CiAgICAgICAgc2VsZi5fcmVhZHkoaWZhY2UpCiAgICAgICAgc3RhdGUgPSBzZWxmLl9sb2FkKCkK
ICAgICAgICBwcmV2aW91cyA9IHN0YXRlWyJpbnRlcmZhY2VzIl0uZ2V0KGlmYWNlKQogICAgICAg
IHNuYXBzaG90ID0gY2FwdHVyZV9zbmFwc2hvdChzZWxmLmN0eCwgaWZhY2UpCiAgICAgICAgbGVn
YWN5ID0gc2VsZi5fbGVnYWN5X2NhbmRpZGF0ZXMoKQogICAgICAgIGlmIGxlZ2FjeToKICAgICAg
ICAgICAgcmFpc2UgVHVuZUVycm9yKCLmo4DmtYvliLDml6fmlbTlvaLmnI3liqHvvIzor7flhYjk
vb/nlKggZWdyZXNzIGFkb3B077yaIiArICIsICIuam9pbihsZWdhY3kpLCAxMCkKICAgICAgICB1
bml0ID0gc2VsZi5fb3duZWRfdW5pdChfdW5pdF9uYW1lKGlmYWNlKSkKICAgICAgICB1bml0X21h
dGNoZXMgPSB1bml0LmdldCgiZXhpc3RzIikgYW5kIHNlbGYuY3R4LnVuaXRfcGF0aChfdW5pdF9u
YW1lKGlmYWNlKSkucmVhZF90ZXh0KCkgPT0gX3VuaXRfY29udGVudChpZmFjZSkKICAgICAgICBp
ZiBwcmV2aW91cyBhbmQgcHJldmlvdXMuZ2V0KCJlbmFibGVkIikgYW5kIHByZXZpb3VzLmdldCgi
cHJvZmlsZSIpID09IHByb2ZpbGUgYW5kIHVuaXQuZ2V0KCJlbmFibGVkIikgYW5kIHVuaXRfbWF0
Y2hlcyBhbmQgcHJvZmlsZV9tYXRjaGVzKHNlbGYuY3R4LCBpZmFjZSwgcHJvZmlsZSk6CiAgICAg
ICAgICAgIHJldHVybiB7ImNoYW5nZWQiOiBGYWxzZSwgImludGVyZmFjZSI6IGlmYWNlLCAicHJv
ZmlsZSI6IHByb2ZpbGV9CiAgICAgICAgc2VsZi5jdHguY29uZmlybSgi5bqU55SoICIgKyBpZmFj
ZSArICIg5Ye65Y+j6Zif5YiXICIgKyBqc29uLmR1bXBzKHByb2ZpbGUsIGVuc3VyZV9hc2NpaT1G
YWxzZSkpCiAgICAgICAgaWYgc2VsZi5jdHguZHJ5X3J1bjoKICAgICAgICAgICAgcmV0dXJuIHsi
ZHJ5X3J1biI6IFRydWUsICJpbnRlcmZhY2UiOiBpZmFjZSwgInByb2ZpbGUiOiBwcm9maWxlfQog
ICAgICAgIHJldHVybiBzZWxmLl9pbnN0YWxsKGlmYWNlLCBwcm9maWxlLCBzdGF0ZSwgcHJldmlv
dXNbIm9yaWdpbmFsIl0gaWYgcHJldmlvdXMgZWxzZSBzbmFwc2hvdCkKCiAgICBkZWYgY2xlYXIo
c2VsZiwgYXJncyk6CiAgICAgICAgcmV0dXJuIHNlbGYuX3JlbW92ZShhcmdzLCByZXN0b3JlPUZh
bHNlKQoKICAgIGRlZiByZXN0b3JlKHNlbGYsIGFyZ3MpOgogICAgICAgIHJldHVybiBzZWxmLl9y
ZW1vdmUoYXJncywgcmVzdG9yZT1UcnVlKQoKICAgIGRlZiBfcmVtb3ZlKHNlbGYsIGFyZ3MsIHJl
c3RvcmUpOgogICAgICAgIGlmYWNlID0gdmFsaWRfaW50ZXJmYWNlKGFyZ3MuaW50ZXJmYWNlKQog
ICAgICAgIHNlbGYuX3JlYWR5KGlmYWNlKQogICAgICAgIHN0YXRlID0gc2VsZi5fbG9hZCgpCiAg
ICAgICAgcmVjb3JkID0gc3RhdGVbImludGVyZmFjZXMiXS5nZXQoaWZhY2UpCiAgICAgICAgaWYg
cmVjb3JkIGlzIE5vbmU6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi6K+l572R5Y2h5rKh
5pyJ5Y+v5oGi5aSN55qE5Y+X566h5Ye65Y+j54q25oCBIiwgMTApCiAgICAgICAgaWYgbm90IHJl
c3RvcmUgYW5kIG5vdCByZWNvcmQuZ2V0KCJlbmFibGVkIik6CiAgICAgICAgICAgIHJldHVybiB7
ImNoYW5nZWQiOiBGYWxzZSwgImludGVyZmFjZSI6IGlmYWNlLCAiY2xlYXJlZCI6IFRydWV9CiAg
ICAgICAgYmVmb3JlID0gY2FwdHVyZV9zbmFwc2hvdChzZWxmLmN0eCwgaWZhY2UpCiAgICAgICAg
bmFtZSA9IF91bml0X25hbWUoaWZhY2UpCiAgICAgICAgdW5pdCA9IHNlbGYuX293bmVkX3VuaXQo
bmFtZSkKICAgICAgICBzdGF0ZV9maWxlID0gc2VsZi5jdHguc25hcHNob3RfZmlsZShzZWxmLnN0
YXRlX3BhdGgpCiAgICAgICAgbGVnYWN5ID0ge29sZF9uYW1lOiBzZWxmLmN0eC51bml0X3N0YXRl
KG9sZF9uYW1lKSBmb3Igb2xkX25hbWUgaW4gcmVjb3JkLmdldCgibGVnYWN5X3VuaXRzIiwge30p
fQogICAgICAgIHNlbGYuY3R4LmNvbmZpcm0oKCLmgaLlpI3ljp/lp4vlrozmlbTpmJ/liJflj4rm
l6fmnI3liqHvvJoiIGlmIHJlc3RvcmUgZWxzZSAi5riF6Zmk5Ye65Y+j6ZmQ5Yi277yM5oGi5aSN
5YaF5qC46buY6K6k6Zif5YiX77yI5L+d55WZ5oGi5aSN5b+r54Wn77yJ77yaIikgKyBpZmFjZSkK
ICAgICAgICBpZiBzZWxmLmN0eC5kcnlfcnVuOgogICAgICAgICAgICByZXR1cm4geyJkcnlfcnVu
IjogVHJ1ZSwgImludGVyZmFjZSI6IGlmYWNlLCAicmVzdG9yZSI6IHJlc3RvcmV9CiAgICAgICAg
dHJ5OgogICAgICAgICAgICBpZiB1bml0LmdldCgiZXhpc3RzIik6CiAgICAgICAgICAgICAgICBz
ZWxmLmN0eC5zeXN0ZW1jdGwoImRpc2FibGUiLCBuYW1lKQogICAgICAgICAgICAgICAgc2VsZi5j
dHguc3lzdGVtY3RsKCJzdG9wIiwgbmFtZSkKICAgICAgICAgICAgaWYgcmVzdG9yZToKICAgICAg
ICAgICAgICAgIGZvciBvbGRfbmFtZSwgc2F2ZWQgaW4gcmVjb3JkLmdldCgibGVnYWN5X3VuaXRz
Iiwge30pLml0ZW1zKCk6CiAgICAgICAgICAgICAgICAgICAgc2VsZi5jdHgucmVzdG9yZV91bml0
KG9sZF9uYW1lLCBzYXZlZCkKICAgICAgICAgICAgICAgIHJlc3RvcmVfc25hcHNob3Qoc2VsZi5j
dHgsIGlmYWNlLCByZWNvcmRbIm9yaWdpbmFsIl0pCiAgICAgICAgICAgICAgICBkZWwgc3RhdGVb
ImludGVyZmFjZXMiXVtpZmFjZV0KICAgICAgICAgICAgICAgIHNlbGYuY3R4LnJlbW92ZV9maWxl
KHNlbGYuY3R4LnVuaXRfcGF0aChuYW1lKSkKICAgICAgICAgICAgICAgIHNlbGYuY3R4LnN5c3Rl
bWN0bCgiZGFlbW9uLXJlbG9hZCIpCiAgICAgICAgICAgIGVsc2U6CiAgICAgICAgICAgICAgICBf
cmVzZXRfcm9vdChzZWxmLmN0eCwgaWZhY2UpCiAgICAgICAgICAgICAgICByZWNvcmRbImVuYWJs
ZWQiXSA9IEZhbHNlCiAgICAgICAgICAgIHNlbGYuY3R4LndyaXRlX2pzb24oc2VsZi5zdGF0ZV9w
YXRoLCBzdGF0ZSkKICAgICAgICBleGNlcHQgQmFzZUV4Y2VwdGlvbiBhcyBleGM6CiAgICAgICAg
ICAgIHNlbGYuX3JvbGxiYWNrKGlmYWNlLCBiZWZvcmUsIHN0YXRlX2ZpbGUsIG5hbWUsIHVuaXQs
IGxlZ2FjeSwgW10sIGV4YykKICAgICAgICByZXR1cm4geyJjaGFuZ2VkIjogVHJ1ZSwgImludGVy
ZmFjZSI6IGlmYWNlLCAicmVzdG9yZWQiOiByZXN0b3JlLCAiY2xlYXJlZCI6IG5vdCByZXN0b3Jl
fQoKICAgIGRlZiBhZG9wdChzZWxmLCBhcmdzKToKICAgICAgICBpZmFjZSA9IHZhbGlkX2ludGVy
ZmFjZShhcmdzLmludGVyZmFjZSkKICAgICAgICBzZWxmLl9yZWFkeShpZmFjZSkKICAgICAgICBz
dGF0ZSA9IHNlbGYuX2xvYWQoKQogICAgICAgIGlmIGlmYWNlIGluIHN0YXRlWyJpbnRlcmZhY2Vz
Il06CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi572R5Y2h5bey5Y+X566h77yM5LiN6IO9
6YeN5aSN5o6l566h5pen5pyN5YqhIiwgMTApCiAgICAgICAgcmVxdWVzdGVkID0gZ2V0YXR0cihh
cmdzLCAic2VydmljZSIsIE5vbmUpCiAgICAgICAgaWYgcmVxdWVzdGVkIGFuZCBub3QgcmVxdWVz
dGVkLmVuZHN3aXRoKCIuc2VydmljZSIpOgogICAgICAgICAgICByZXF1ZXN0ZWQgKz0gIi5zZXJ2
aWNlIgogICAgICAgIGlmIHJlcXVlc3RlZCBhbmQgcmVxdWVzdGVkIG5vdCBpbiBMRUdBQ1lfVU5J
VFM6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5LuF5pSv5oyB5o6l566h5bey55+lIG5l
dHdvcmstdHVuaW5nIOacjeWKoSIsIDIpCiAgICAgICAgY2FuZGlkYXRlcyA9IHNlbGYuX2xlZ2Fj
eV9jYW5kaWRhdGVzKCkKICAgICAgICBpZiByZXF1ZXN0ZWQ6CiAgICAgICAgICAgIGNhbmRpZGF0
ZXMgPSB7cmVxdWVzdGVkOiBjYW5kaWRhdGVzW3JlcXVlc3RlZF19IGlmIHJlcXVlc3RlZCBpbiBj
YW5kaWRhdGVzIGVsc2Uge30KICAgICAgICBpZiBub3QgY2FuZGlkYXRlczoKICAgICAgICAgICAg
cmFpc2UgVHVuZUVycm9yKCLmsqHmnInlj6/mjqXnrqHnmoTlt7Lnn6XmtLvliqgv5ZCv55So5pyN
5YqhIiwgMTApCiAgICAgICAgcHJvZmlsZXMgPSBbXQogICAgICAgIHNlbGVjdGVkID0ge30KICAg
ICAgICBmb3IgbmFtZSwgc2F2ZWQgaW4gY2FuZGlkYXRlcy5pdGVtcygpOgogICAgICAgICAgICBj
b250ZW50ID0gc2VsZi5jdHguc3lzdGVtY3RsKCJjYXQiLCBuYW1lKS5zdGRvdXQKICAgICAgICAg
ICAgcHJvZmlsZSA9IF9sZWdhY3lfcHJvZmlsZShjb250ZW50LCBpZmFjZSkKICAgICAgICAgICAg
aWYgcHJvZmlsZSBpcyBub3QgTm9uZToKICAgICAgICAgICAgICAgIHByb2ZpbGVzLmFwcGVuZChw
cm9maWxlKQogICAgICAgICAgICAgICAgc2F2ZWRbInVuaXRfdGV4dCJdID0gY29udGVudAogICAg
ICAgICAgICAgICAgc2VsZWN0ZWRbbmFtZV0gPSBzYXZlZAogICAgICAgIGlmIGxlbihwcm9maWxl
cykgIT0gMToKICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLml6Dms5XllK/kuIDnoa7lrpro
r6XnvZHljaHnmoTml6fmlbTlvaLmnI3liqEiLCAxMCkKICAgICAgICBwcm9maWxlID0gcHJvZmls
ZXNbMF0KICAgICAgICBpZiBub3QgcHJvZmlsZV9tYXRjaGVzKHNlbGYuY3R4LCBpZmFjZSwgcHJv
ZmlsZSk6CiAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5pen5pyN5Yqh5ZG95Luk5LiO5a6e
6ZmF6Zif5YiX5LiN5LiA6Ie077yM5ouS57ud54yc5rWL5o6l566h5Y+C5pWwIiwgMTApCiAgICAg
ICAgb3JpZ2luYWwgPSBjYXB0dXJlX3NuYXBzaG90KHNlbGYuY3R4LCBpZmFjZSkKICAgICAgICBz
ZWxmLmN0eC5jb25maXJtKCLmjqXnrqEgIiArICIsICIuam9pbihzZWxlY3RlZCkgKyAi77yM5L+d
55WZ5b2T5YmN5Ye65Y+j5Y+C5pWw5Y+K5a6M5pW05oGi5aSN5b+r54WnIikKICAgICAgICBpZiBz
ZWxmLmN0eC5kcnlfcnVuOgogICAgICAgICAgICByZXR1cm4geyJkcnlfcnVuIjogVHJ1ZSwgImlu
dGVyZmFjZSI6IGlmYWNlLCAicHJvZmlsZSI6IHByb2ZpbGUsICJhZG9wdGVkIjogbGlzdChzZWxl
Y3RlZCl9CiAgICAgICAgcmV0dXJuIHNlbGYuX2luc3RhbGwoaWZhY2UsIHByb2ZpbGUsIHN0YXRl
LCBvcmlnaW5hbCwgc2VsZWN0ZWQpCgogICAgZGVmIHN0YXR1cyhzZWxmLCBpbnRlcmZhY2U9Tm9u
ZSk6CiAgICAgICAgc3RhdGUgPSBzZWxmLl9sb2FkKCkKICAgICAgICBuYW1lcyA9IFt2YWxpZF9p
bnRlcmZhY2UoaW50ZXJmYWNlKV0gaWYgaW50ZXJmYWNlIGVsc2Ugc29ydGVkKHN0YXRlWyJpbnRl
cmZhY2VzIl0pCiAgICAgICAgaW50ZXJmYWNlcyA9IHt9CiAgICAgICAgZm9yIGlmYWNlIGluIG5h
bWVzOgogICAgICAgICAgICByZWNvcmQgPSBzdGF0ZVsiaW50ZXJmYWNlcyJdLmdldChpZmFjZSkK
ICAgICAgICAgICAgaXRlbSA9IHsibWFuYWdlZCI6IHJlY29yZCBpcyBub3QgTm9uZSwgInJlY29y
ZCI6IHJlY29yZCwgInRyZWUiOiByZWFkX3RyZWUoc2VsZi5jdHgsIGlmYWNlLCBzdGF0cz1UcnVl
KX0KICAgICAgICAgICAgaWYgcmVjb3JkOgogICAgICAgICAgICAgICAgaXRlbVsibWF0Y2hlcyJd
ID0gcHJvZmlsZV9tYXRjaGVzKHNlbGYuY3R4LCBpZmFjZSwgcmVjb3JkWyJwcm9maWxlIl0pIGlm
IHJlY29yZC5nZXQoImVuYWJsZWQiKSBlbHNlIE5vbmUKICAgICAgICAgICAgICAgIGl0ZW1bInNl
cnZpY2UiXSA9IHNlbGYuY3R4LnVuaXRfc3RhdGUoX3VuaXRfbmFtZShpZmFjZSkpCiAgICAgICAg
ICAgIGludGVyZmFjZXNbaWZhY2VdID0gaXRlbQogICAgICAgIHJldHVybiB7ImludGVyZmFjZXMi
OiBpbnRlcmZhY2VzfQoKICAgIGRlZiBib290KHNlbGYsIGludGVyZmFjZSk6CiAgICAgICAgaWZh
Y2UgPSB2YWxpZF9pbnRlcmZhY2UoaW50ZXJmYWNlKQogICAgICAgIHNlbGYuX3JlYWR5KGlmYWNl
KQogICAgICAgIHJlY29yZCA9IHNlbGYuX2xvYWQoKVsiaW50ZXJmYWNlcyJdLmdldChpZmFjZSkK
ICAgICAgICBpZiBub3QgcmVjb3JkIG9yIG5vdCByZWNvcmQuZ2V0KCJlbmFibGVkIik6CiAgICAg
ICAgICAgIHJldHVybiB7ImNoYW5nZWQiOiBGYWxzZSwgImludGVyZmFjZSI6IGlmYWNlfQogICAg
ICAgIGJlZm9yZSA9IGNhcHR1cmVfc25hcHNob3Qoc2VsZi5jdHgsIGlmYWNlKQogICAgICAgIG1h
dGNoZXMgPSBwcm9maWxlX21hdGNoZXMoc2VsZi5jdHgsIGlmYWNlLCByZWNvcmRbInByb2ZpbGUi
XSkKICAgICAgICB0cnk6CiAgICAgICAgICAgIGFwcGx5X3Byb2ZpbGUoc2VsZi5jdHgsIGlmYWNl
LCByZWNvcmRbInByb2ZpbGUiXSkKICAgICAgICBleGNlcHQgQmFzZUV4Y2VwdGlvbiBhcyBleGM6
CiAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgIHJlc3RvcmVfc25hcHNob3Qoc2VsZi5j
dHgsIGlmYWNlLCBiZWZvcmUpCiAgICAgICAgICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgcm9sbGJh
Y2s6CiAgICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuW8gOacuuW6lOeUqOWksei0peS4
lOmYn+WIl+Wbnua7muWksei0pe+8miIgKyBzdHIocm9sbGJhY2spLCAzMCkgZnJvbSBleGMKICAg
ICAgICAgICAgcmFpc2UKICAgICAgICByZXR1cm4geyJjaGFuZ2VkIjogbm90IG1hdGNoZXMsICJp
bnRlcmZhY2UiOiBpZmFjZX0KCgpkZWYgX3RjX3JhdGUodmFsdWUpOgogICAgbWF0Y2ggPSByZS5m
dWxsbWF0Y2gociIoXGQrKD86XC5cZCspPykoW2ttZ10/KSg/OmJpdHxicHMpIiwgdmFsdWUubG93
ZXIoKSkKICAgIGlmIG5vdCBtYXRjaDoKICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaXp+acjeWK
oemAn+eOh+WPguaVsOaXoOazleivhuWIqyIsIDEwKQogICAgcmV0dXJuIGludChmbG9hdChtYXRj
aFsxXSkgKiB7IiI6IDEsICJrIjogMTAwMCwgIm0iOiAxXzAwMF8wMDAsICJnIjogMV8wMDBfMDAw
XzAwMH1bbWF0Y2hbMl1dKQoKCmRlZiBfbGVnYWN5X3Byb2ZpbGUoY29udGVudCwgaWZhY2UpOgog
ICAgc3RhcnRzID0gW10KICAgIGZvciBsaW5lIGluIGNvbnRlbnQuc3BsaXRsaW5lcygpOgogICAg
ICAgIGlmIGxpbmUuc3RhcnRzd2l0aCgiRXhlY1N0YXJ0PSIpOgogICAgICAgICAgICB2YWx1ZSA9
IGxpbmUucGFydGl0aW9uKCI9IilbMl0uc3RyaXAoKQogICAgICAgICAgICBpZiBub3QgdmFsdWU6
CiAgICAgICAgICAgICAgICBzdGFydHMgPSBbXQogICAgICAgICAgICBlbHNlOgogICAgICAgICAg
ICAgICAgc3RhcnRzLmFwcGVuZChzaGxleC5zcGxpdCh2YWx1ZSkpCiAgICBpZiBub3Qgc3RhcnRz
IG9yIGFueShsZW4oYXJndikgPCA5IG9yIGFyZ3ZbMF0gbm90IGluICgiL3Vzci9zYmluL3RjIiwg
Ii9zYmluL3RjIiwgIi91c3IvYmluL3RjIikgb3IgYXJndlsxOjRdICE9IFsicWRpc2MiLCAicmVw
bGFjZSIsICJkZXYiXSBmb3IgYXJndiBpbiBzdGFydHMpOgogICAgICAgIHJhaXNlIFR1bmVFcnJv
cigi5pen5pyN5Yqh5LiN5piv5Y+X5pSv5oyB55qE55u05o6lIHRjIOWRveS7pCIsIDEwKQogICAg
aWYgYWxsKGFyZ3ZbNF0gIT0gaWZhY2UgZm9yIGFyZ3YgaW4gc3RhcnRzKToKICAgICAgICByZXR1
cm4gTm9uZQogICAgaWYgYW55KGFyZ3ZbNF0gIT0gaWZhY2UgZm9yIGFyZ3YgaW4gc3RhcnRzKSBv
ciBzdGFydHNbMF1bNTo3XSAhPSBbInJvb3QiLCAiaGFuZGxlIl06CiAgICAgICAgcmFpc2UgVHVu
ZUVycm9yKCLml6fmnI3liqHkv67mlLnlpJrkuKrnvZHljaHmiJbkvb/nlKjmnKrnn6Xmi5PmiZEi
LCAxMCkKICAgIHJvb3QgPSBzdGFydHNbMF0KICAgIG1vZGUgPSByb290WzhdCiAgICBpZiBtb2Rl
IG5vdCBpbiAoInRiZiIsICJmcSIpOgogICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5pen5pyN5Yqh
6Zif5YiX57G75Z6L5LiN5Y+X5pSv5oyBIiwgMTApCiAgICBpZiBsZW4ocm9vdFs5Ol0pICUgMjoK
ICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaXp+acjeWKoemYn+WIl+WPguaVsOaXoOazleivhuWI
qyIsIDEwKQogICAgb3B0cyA9IGRpY3QoemlwKHJvb3RbOTo6Ml0sIHJvb3RbMTA6OjJdKSkKICAg
IHByb2ZpbGUgPSB7Im1vZGUiOiBtb2RlfQogICAgaWYgbW9kZSA9PSAiZnEiOgogICAgICAgIGlm
IHNldChvcHRzKSAtIHsibWF4cmF0ZSIsICJsaW1pdCIsICJmbG93X2xpbWl0IiwgIm9ycGhhbl9t
YXNrIn0gb3IgbGVuKHN0YXJ0cykgIT0gMToKICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLm
l6cgZnEg5pyN5Yqh5YyF5ZCr5pyq55+l5Y+C5pWwIiwgMTApCiAgICAgICAgcHJvZmlsZVsibWF4
cmF0ZV9icHMiXSA9IF90Y19yYXRlKG9wdHNbIm1heHJhdGUiXSkgaWYgIm1heHJhdGUiIGluIG9w
dHMgZWxzZSBOb25lCiAgICBlbHNlOgogICAgICAgIGlmIHNldChvcHRzKSAhPSB7InJhdGUiLCAi
YnVyc3QiLCAibGF0ZW5jeSJ9OgogICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaXpyBUQkYg
5pyN5Yqh5YyF5ZCr5pyq55+l5Y+C5pWwIiwgMTApCiAgICAgICAgYnVyc3QgPSByZS5mdWxsbWF0
Y2gociIoXGQrKShrYnxrfGIpPyIsIG9wdHNbImJ1cnN0Il0ubG93ZXIoKSkKICAgICAgICBsYXRl
bmN5ID0gcmUuZnVsbG1hdGNoKHIiKFxkKyg/OlwuXGQrKT8pKG1zfHVzfHMpIiwgb3B0c1sibGF0
ZW5jeSJdLmxvd2VyKCkpCiAgICAgICAgaWYgbm90IGJ1cnN0IG9yIG5vdCBsYXRlbmN5OgogICAg
ICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaXpyBUQkYgYnVyc3QvbGF0ZW5jeSDml6Dms5Xor4bl
iKsiLCAxMCkKICAgICAgICBwcm9maWxlLnVwZGF0ZShyYXRlX2Jwcz1fdGNfcmF0ZShvcHRzWyJy
YXRlIl0pLCBidXJzdF9ieXRlcz1pbnQoYnVyc3RbMV0pICogKDEwMjQgaWYgYnVyc3RbMl0gaW4g
KCJrYiIsICJrIikgZWxzZSAxKSwKICAgICAgICAgICAgICAgICAgICAgICBsYXRlbmN5X21zPWZs
b2F0KGxhdGVuY3lbMV0pICogeyJtcyI6IDEsICJ1cyI6IDAuMDAxLCAicyI6IDEwMDB9W2xhdGVu
Y3lbMl1dKQogICAgICAgIGlmIGxlbihzdGFydHMpID09IDI6CiAgICAgICAgICAgIGNoaWxkID0g
c3RhcnRzWzFdCiAgICAgICAgICAgIGlmIGNoaWxkWzU6N10gIT0gWyJwYXJlbnQiLCByb290Wzdd
ICsgIjEiXSBvciBjaGlsZFs3XSAhPSAiaGFuZGxlIiBvciBjaGlsZFs5XSAhPSAiZnEiIG9yIGxl
bihjaGlsZFsxMDpdKSAlIDI6CiAgICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaXpyBU
QkYg5a2Q6Zif5YiX5peg5rOV6K+G5YirIiwgMTApCiAgICAgICAgICAgIG9wdHMgPSBkaWN0KHpp
cChjaGlsZFsxMDo6Ml0sIGNoaWxkWzExOjoyXSkpCiAgICAgICAgICAgIGlmIHNldChvcHRzKSAt
IHsibWF4cmF0ZSIsICJsaW1pdCIsICJmbG93X2xpbWl0IiwgIm9ycGhhbl9tYXNrIn06CiAgICAg
ICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaXpyBUQkYrZnEg5a2Q6Zif5YiX5Y+C5pWw5LiN
5Y+X5pSv5oyBIiwgMTApCiAgICAgICAgICAgIHByb2ZpbGUudXBkYXRlKG1vZGU9InRiZi1mcSIs
IG1heHJhdGVfYnBzPV90Y19yYXRlKG9wdHNbIm1heHJhdGUiXSkgaWYgIm1heHJhdGUiIGluIG9w
dHMgZWxzZSBOb25lLAogICAgICAgICAgICAgICAgICAgICAgICAgICBsaW1pdF9wYWNrZXRzPWlu
dChvcHRzLmdldCgibGltaXQiLCAxMDAwMCkpLCBmbG93X2xpbWl0PWludChvcHRzLmdldCgiZmxv
d19saW1pdCIsIDEwMCkpKQogICAgICAgIGVsaWYgbGVuKHN0YXJ0cykgIT0gMToKICAgICAgICAg
ICAgcmFpc2UgVHVuZUVycm9yKCLml6fmnI3liqHljIXlkKvpop3lpJblkK/liqjlkb3ku6QiLCAx
MCkKICAgIGlmIHByb2ZpbGVbIm1vZGUiXSAhPSAidGJmIjoKICAgICAgICBmb3Iga2V5LCBkZXN0
IGluICgoImxpbWl0IiwgImxpbWl0X3BhY2tldHMiKSwgKCJmbG93X2xpbWl0IiwgImZsb3dfbGlt
aXQiKSwgKCJvcnBoYW5fbWFzayIsICJvcnBoYW5fbWFzayIpKToKICAgICAgICAgICAgaWYga2V5
IGluIG9wdHM6CiAgICAgICAgICAgICAgICBwcm9maWxlW2Rlc3RdID0gaW50KG9wdHNba2V5XSkK
ICAgIF92YWxpZGF0ZV9wcm9maWxlKHByb2ZpbGUpCiAgICByZXR1cm4gcHJvZmlsZQpQSwMEFAAA
AAAAAAAhUEBGZ8cjgwAAI4MAABUAAABuZXR3b3JrX3R1bmUvcG9ydHMucHkiIiJJbmRlcGVuZGVu
dCBwb3N0LVNOQVQgc2VydmljZS1wb3J0IHNoYXBpbmcsIHdpdGggZXhwbGljaXRseSBvd25lZCBy
ZXNvdXJjZXMuIiIiCgppbXBvcnQgY29weQppbXBvcnQgaGFzaGxpYgppbXBvcnQganNvbgppbXBv
cnQgbWF0aAppbXBvcnQgc2hsZXgKCmZyb20gLmNvbW1vbiBpbXBvcnQgVHVuZUVycm9yLCBwYXJz
ZV9tYnBzLCB2YWxpZF9pZCwgdmFsaWRfaW50ZXJmYWNlCmZyb20gLmVncmVzcyBpbXBvcnQgYXBw
bHlfcHJvZmlsZSwgY2FwdHVyZV9zbmFwc2hvdCwgcHJvZmlsZV9tYXRjaGVzLCByZXN0b3JlX3Nu
YXBzaG90CgoKVEFCTEUgPSAidnBzY3RsX3R1bmVfcG9ydHMiCk9XTkVSID0gInZwc2N0bC1uZXR3
b3JrLXR1bmU6cG9ydHM6djEiClVOSVQgPSAidnBzY3RsLW5ldHdvcmstdHVuZS1wb3J0cy5zZXJ2
aWNlIgpNQVNLID0gMHhmZmZmMDAwMApQUkVGX0JBU0UgPSA0OTE1MgpNQVhfU0xPVCA9IDgxOTEK
X0RZTkFNSUMgPSB7ImhhbmRsZSIsICJpbmRleCIsICJzdGF0cyIsICJzdGF0czIiLCAicmVmIiwg
ImJpbmQiLCAidXNlZCIsCiAgICAgICAgICAgICJsYXN0dXNlIiwgImZpcnN0dXNlZCIsICJsYXN0
X3VzZWQiLCAiZmlyc3RfdXNlZCIsICJpbnN0YWxsZWQiLCAiaW5faHdfY291bnQifQoKCmRlZiBf
bm9ybWFsKHZhbHVlLCBuZnQ9RmFsc2UpOgogICAgaWYgaXNpbnN0YW5jZSh2YWx1ZSwgZGljdCk6
CiAgICAgICAgcmV0dXJuIHtrZXk6IF9ub3JtYWwoaXRlbSwgbmZ0KSBmb3Iga2V5LCBpdGVtIGlu
IHZhbHVlLml0ZW1zKCkKICAgICAgICAgICAgICAgIGlmIGtleSBub3QgaW4gKF9EWU5BTUlDIGlm
IG5mdCBlbHNlIF9EWU5BTUlDIC0geyJoYW5kbGUifSl9CiAgICBpZiBpc2luc3RhbmNlKHZhbHVl
LCBsaXN0KToKICAgICAgICByZXR1cm4gW19ub3JtYWwoaXRlbSwgbmZ0KSBmb3IgaXRlbSBpbiB2
YWx1ZV0KICAgIHJldHVybiB2YWx1ZQoKCmRlZiBfZmluZ2VycHJpbnQodmFsdWUsIG5mdD1GYWxz
ZSk6CiAgICByZXR1cm4ganNvbi5kdW1wcyhfbm9ybWFsKHZhbHVlLCBuZnQpLCBzb3J0X2tleXM9
VHJ1ZSwgc2VwYXJhdG9ycz0oIiwiLCAiOiIpKQoKCmRlZiBfaWZiKHJ1bGVfaWQpOgogICAgcmV0
dXJuICJ2dHQiICsgaGFzaGxpYi5zaGEyNTYocnVsZV9pZC5lbmNvZGUoInV0Zi04IikpLmhleGRp
Z2VzdCgpWzoxMF0KCgpkZWYgX2FsaWFzKHJ1bGVfaWQpOgogICAgcmV0dXJuIE9XTkVSICsgIjoi
ICsgcnVsZV9pZAoKCmRlZiBfcG9zaXRpdmUodmFsdWUsIG5hbWUsIG1heGltdW09Tm9uZSk6CiAg
ICB0cnk6CiAgICAgICAgcmVzdWx0ID0gaW50KHZhbHVlKQogICAgICAgIGlmIGlzaW5zdGFuY2Uo
dmFsdWUsIGJvb2wpIG9yIHN0cihyZXN1bHQpICE9IHN0cih2YWx1ZSkgb3IgcmVzdWx0IDw9IDA6
CiAgICAgICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoKQogICAgZXhjZXB0IChWYWx1ZUVycm9yLCBU
eXBlRXJyb3IpOgogICAgICAgIHJhaXNlIFR1bmVFcnJvcihuYW1lICsgIiDlv4XpobvmmK/mraPm
lbTmlbAiLCAyKQogICAgaWYgbWF4aW11bSBpcyBub3QgTm9uZSBhbmQgcmVzdWx0ID4gbWF4aW11
bToKICAgICAgICByYWlzZSBUdW5lRXJyb3IobmFtZSArICIg6LaF5Ye66IyD5Zu0IiwgMikKICAg
IHJldHVybiByZXN1bHQKCgpkZWYgX2RlZmF1bHQoYXJncywgbmFtZSwgdmFsdWUpOgogICAgc3Vw
cGxpZWQgPSBnZXRhdHRyKGFyZ3MsIG5hbWUsIE5vbmUpCiAgICByZXR1cm4gdmFsdWUgaWYgc3Vw
cGxpZWQgaXMgTm9uZSBlbHNlIHN1cHBsaWVkCgoKZGVmIF9wb3NpdGl2ZV9udW1iZXIodmFsdWUs
IG5hbWUpOgogICAgdHJ5OgogICAgICAgIG51bWJlciA9IGZsb2F0KHZhbHVlKQogICAgICAgIGlm
IGlzaW5zdGFuY2UodmFsdWUsIGJvb2wpIG9yIG5vdCBtYXRoLmlzZmluaXRlKG51bWJlcikgb3Ig
bnVtYmVyIDw9IDA6CiAgICAgICAgICAgIHJhaXNlIFZhbHVlRXJyb3IoKQogICAgICAgIHJldHVy
biBudW1iZXIKICAgIGV4Y2VwdCAoVmFsdWVFcnJvciwgVHlwZUVycm9yKToKICAgICAgICByYWlz
ZSBUdW5lRXJyb3IobmFtZSArICIg5b+F6aG75piv5q2j5pWwIiwgMikKCgpkZWYgX3J1bGUoYXJn
cywgc2xvdCk6CiAgICBydWxlX2lkID0gdmFsaWRfaWQoYXJncy5pZCkKICAgIGludGVyZmFjZSA9
IHZhbGlkX2ludGVyZmFjZShhcmdzLmludGVyZmFjZSkKICAgIHByb3RvY29sID0gZ2V0YXR0cihh
cmdzLCAicHJvdG9jb2wiLCBOb25lKSBvciAidGNwIgogICAgZmFtaWx5ID0gZ2V0YXR0cihhcmdz
LCAiZmFtaWx5IiwgTm9uZSkgb3IgImJvdGgiCiAgICBpZiBwcm90b2NvbCBub3QgaW4gKCJ0Y3Ai
LCAidWRwIiwgImJvdGgiKSBvciBmYW1pbHkgbm90IGluICgiaXB2NCIsICJpcHY2IiwgImJvdGgi
KToKICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaXoOaViOeahOWNj+iuruaIluWcsOWdgOaXjyIs
IDIpCiAgICBwb3J0ID0gX3Bvc2l0aXZlKGFyZ3MucG9ydCwgInBvcnQiLCA2NTUzNSkKICAgIHRv
dGFsID0gZ2V0YXR0cihhcmdzLCAidG90YWxfbWJwcyIsIE5vbmUpCiAgICBmbG93ID0gZ2V0YXR0
cihhcmdzLCAiZmxvd19tYnBzIiwgTm9uZSkKICAgIGlmIHRvdGFsIGlzIE5vbmUgYW5kIGZsb3cg
aXMgTm9uZToKICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuiHs+WwkeaMh+WumiAtLXRvdGFsLW1i
cHMg5oiWIC0tZmxvdy1tYnBzIiwgMikKICAgIGlmIGZsb3cgaXMgbm90IE5vbmUgYW5kIHByb3Rv
Y29sICE9ICJ0Y3AiOgogICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5q+P5rWB6ZmQ6YCf5LuF5pSv
5oyBIFRDUO+8m1VEUC9ib3RoIOivt+S9v+eUqOWFseS6q+aAu+mZkOmAnyIsIDIpCiAgICBwcm9m
aWxlID0geyJtb2RlIjogInRiZi1mcSIgaWYgdG90YWwgaXMgbm90IE5vbmUgYW5kIGZsb3cgaXMg
bm90IE5vbmUgZWxzZQogICAgICAgICAgICAgICAidGJmIiBpZiB0b3RhbCBpcyBub3QgTm9uZSBl
bHNlICJmcSJ9CiAgICBpZiB0b3RhbCBpcyBub3QgTm9uZToKICAgICAgICBwcm9maWxlLnVwZGF0
ZShyYXRlX2Jwcz1wYXJzZV9tYnBzKHRvdGFsKSwKICAgICAgICAgICAgICAgICAgICAgICBidXJz
dF9ieXRlcz1fcG9zaXRpdmUoX2RlZmF1bHQoYXJncywgImJ1cnN0X2tpYiIsIDY0KSwgImJ1cnN0
LWtpYiIpICogMTAyNCwKICAgICAgICAgICAgICAgICAgICAgICBsYXRlbmN5X21zPV9wb3NpdGl2
ZV9udW1iZXIoX2RlZmF1bHQoYXJncywgImxhdGVuY3lfbXMiLCA1MCksICJsYXRlbmN5LW1zIikp
CiAgICBpZiBmbG93IGlzIG5vdCBOb25lOgogICAgICAgIHByb2ZpbGUudXBkYXRlKG1heHJhdGVf
YnBzPXBhcnNlX21icHMoZmxvdyksIG9ycGhhbl9tYXNrPTB4ZmZmZmZmZmYsCiAgICAgICAgICAg
ICAgICAgICAgICAgbGltaXRfcGFja2V0cz1fcG9zaXRpdmUoX2RlZmF1bHQoYXJncywgInF1ZXVl
X3BhY2tldHMiLCAxMDI0KSwgInF1ZXVlLXBhY2tldHMiKSwKICAgICAgICAgICAgICAgICAgICAg
ICBmbG93X2xpbWl0PV9wb3NpdGl2ZShfZGVmYXVsdChhcmdzLCAiZmxvd19saW1pdCIsIDEwMCks
ICJmbG93LWxpbWl0IikpCiAgICBlbGlmIGdldGF0dHIoYXJncywgInF1ZXVlX3BhY2tldHMiLCBO
b25lKSBpcyBub3QgTm9uZSBvciBnZXRhdHRyKGFyZ3MsICJmbG93X2xpbWl0IiwgTm9uZSkgaXMg
bm90IE5vbmU6CiAgICAgICAgcmFpc2UgVHVuZUVycm9yKCJxdWV1ZS1wYWNrZXRzL2Zsb3ctbGlt
aXQg6ZyA6KaBIFRDUCDmr4/mtYHpmZDpgJ8iLCAyKQogICAgcmV0dXJuIHsiaWQiOiBydWxlX2lk
LCAiaW50ZXJmYWNlIjogaW50ZXJmYWNlLCAicG9ydCI6IHBvcnQsICJwcm90b2NvbCI6IHByb3Rv
Y29sLAogICAgICAgICAgICAiZmFtaWx5IjogZmFtaWx5LCAicHJvZmlsZSI6IHByb2ZpbGUsICJz
bG90Ijogc2xvdCwgImlmYiI6IF9pZmIocnVsZV9pZCl9CgoKZGVmIF9rZXlzKHJ1bGUpOgogICAg
cHJvdG9jb2xzID0gKCJ0Y3AiLCAidWRwIikgaWYgcnVsZVsicHJvdG9jb2wiXSA9PSAiYm90aCIg
ZWxzZSAocnVsZVsicHJvdG9jb2wiXSwpCiAgICBmYW1pbGllcyA9ICgiaXB2NCIsICJpcHY2Iikg
aWYgcnVsZVsiZmFtaWx5Il0gPT0gImJvdGgiIGVsc2UgKHJ1bGVbImZhbWlseSJdLCkKICAgIHJl
dHVybiB7KHJ1bGVbImludGVyZmFjZSJdLCBwcm90b2NvbCwgZmFtaWx5LCBydWxlWyJwb3J0Il0p
CiAgICAgICAgICAgIGZvciBwcm90b2NvbCBpbiBwcm90b2NvbHMgZm9yIGZhbWlseSBpbiBmYW1p
bGllc30KCgpkZWYgX3NhbWVfcnVsZShhLCBiKToKICAgIHJldHVybiBhbGwoYS5nZXQoa2V5KSA9
PSBiLmdldChrZXkpIGZvciBrZXkgaW4KICAgICAgICAgICAgICAgKCJpZCIsICJpbnRlcmZhY2Ui
LCAicG9ydCIsICJwcm90b2NvbCIsICJmYW1pbHkiLCAicHJvZmlsZSIsICJzbG90IiwgImlmYiIp
KQoKCmRlZiBfbmZ0X3NjcmlwdChydWxlcywgZXhpc3RzKToKICAgIGxpbmVzID0gWyJkZWxldGUg
dGFibGUgaW5ldCAiICsgVEFCTEVdIGlmIGV4aXN0cyBlbHNlIFtdCiAgICBpZiBub3QgcnVsZXM6
CiAgICAgICAgcmV0dXJuICJcbiIuam9pbihsaW5lcykgKyAiXG4iCiAgICBsaW5lcyArPSBbImFk
ZCB0YWJsZSBpbmV0ICIgKyBUQUJMRSArICIgeyBjb21tZW50ICIgKyBqc29uLmR1bXBzKE9XTkVS
KSArICI7IH0iLAogICAgICAgICAgICAgICJhZGQgY2hhaW4gaW5ldCAiICsgVEFCTEUgKyAiIHBv
c3Ryb3V0aW5nIHsgdHlwZSBmaWx0ZXIgaG9vayBwb3N0cm91dGluZyBwcmlvcml0eSAxMTA7IHBv
bGljeSBhY2NlcHQ7IH0iXQogICAgZm9yIHJ1bGVfaWQsIHJ1bGUgaW4gc29ydGVkKHJ1bGVzLml0
ZW1zKCkpOgogICAgICAgIGZvciBfLCBwcm90b2NvbCwgZmFtaWx5LCBwb3J0IGluIHNvcnRlZChf
a2V5cyhydWxlKSk6CiAgICAgICAgICAgICMgVGhlIGN0IGV4cHJlc3Npb24gcmVnaXN0ZXJzIGNv
bm50cmFjay9kZWZyYWdtZW50YXRpb24gZm9yIGJvdGggaW5ldAogICAgICAgICAgICAjIGZhbWls
aWVzLiBJdCBwcmVjZWRlcyB0aGUgdHJhbnNwb3J0LWhlYWRlciBsb29rdXAsIGluY2x1ZGluZyBm
b3IKICAgICAgICAgICAgIyBmb3J3YXJkZWQgSVB2NC9JUHY2IGZyYWdtZW50cy4gTG9jYWxseSBw
cm9kdWNlZCBmcmFnbWVudHMgaW5oZXJpdAogICAgICAgICAgICAjIHRoZSBtYXJrIHdoZW4gZnJh
Z21lbnRhdGlvbiBvY2N1cnMgYWZ0ZXIgcG9zdHJvdXRpbmcuCiAgICAgICAgICAgIGxpbmVzLmFw
cGVuZCgiYWRkIHJ1bGUgaW5ldCAiICsgVEFCTEUgKyAiIHBvc3Ryb3V0aW5nICIKICAgICAgICAg
ICAgICAgICAgICAgICAgICJjdCBzdGF0ZSB7IGludmFsaWQsIG5ldywgZXN0YWJsaXNoZWQsIHJl
bGF0ZWQsIHVudHJhY2tlZCB9ICIKICAgICAgICAgICAgICAgICAgICAgICAgICJvaWZuYW1lICIg
KyBqc29uLmR1bXBzKHJ1bGVbImludGVyZmFjZSJdKSArICIgbWV0YSBuZnByb3RvICIgKyBmYW1p
bHkgKwogICAgICAgICAgICAgICAgICAgICAgICAgIiBtZXRhIGw0cHJvdG8gIiArIHByb3RvY29s
ICsgIiAiICsgcHJvdG9jb2wgKyAiIHNwb3J0ICIgKyBzdHIocG9ydCkgKwogICAgICAgICAgICAg
ICAgICAgICAgICAgIiBtZXRhIG1hcmsgc2V0IChtZXRhIG1hcmsgJiAweDAwMDBmZmZmKSB8ICIg
KyBoZXgocnVsZVsic2xvdCJdIDw8IDE2KSArCiAgICAgICAgICAgICAgICAgICAgICAgICAiIGNv
bW1lbnQgIiArIGpzb24uZHVtcHMoT1dORVIgKyAiOiIgKyBydWxlX2lkKSkKICAgIHJldHVybiAi
XG4iLmpvaW4obGluZXMpICsgIlxuIgoKCmRlZiBfY29udGFpbnNfbWFyayh2YWx1ZSk6CiAgICBp
ZiBpc2luc3RhbmNlKHZhbHVlLCBkaWN0KToKICAgICAgICBpZiB2YWx1ZS5nZXQoIm1ldGEiLCB7
fSkuZ2V0KCJrZXkiKSA9PSAibWFyayI6CiAgICAgICAgICAgIHJldHVybiBUcnVlCiAgICAgICAg
cmV0dXJuIGFueShfY29udGFpbnNfbWFyayhpdGVtKSBmb3IgaXRlbSBpbiB2YWx1ZS52YWx1ZXMo
KSkKICAgIHJldHVybiBpc2luc3RhbmNlKHZhbHVlLCBsaXN0KSBhbmQgYW55KF9jb250YWluc19t
YXJrKGl0ZW0pIGZvciBpdGVtIGluIHZhbHVlKQoKCmRlZiBfaW50KHZhbHVlKToKICAgIHRyeToK
ICAgICAgICByZXR1cm4gaW50KHZhbHVlLCAwKSBpZiBpc2luc3RhbmNlKHZhbHVlLCBzdHIpIGVs
c2UgaW50KHZhbHVlKQogICAgZXhjZXB0IChUeXBlRXJyb3IsIFZhbHVlRXJyb3IpOgogICAgICAg
IHJldHVybiBOb25lCgoKZGVmIF9wcmVzZXJ2ZXNfaGlnaCh2YWx1ZSk6CiAgICAiIiJSZWNvZ25p
emUgd3JpdGVzIHRoYXQgcHJvdmFibHkgbGVhdmUgZXZlcnkgcmVzZXJ2ZWQgYml0IHVuY2hhbmdl
ZC4iIiIKICAgIGlmIHZhbHVlID09IHsibWV0YSI6IHsia2V5IjogIm1hcmsifX06CiAgICAgICAg
cmV0dXJuIFRydWUKICAgIGlmIG5vdCBpc2luc3RhbmNlKHZhbHVlLCBkaWN0KSBvciBsZW4odmFs
dWUpICE9IDE6CiAgICAgICAgcmV0dXJuIEZhbHNlCiAgICBvcCwgb3BlcmFuZHMgPSBuZXh0KGl0
ZXIodmFsdWUuaXRlbXMoKSkpCiAgICBpZiBvcCBub3QgaW4gKCImIiwgInwiLCAiXiIpIG9yIG5v
dCBpc2luc3RhbmNlKG9wZXJhbmRzLCBsaXN0KSBvciBsZW4ob3BlcmFuZHMpICE9IDI6CiAgICAg
ICAgcmV0dXJuIEZhbHNlCiAgICBmb3IgZXhwcmVzc2lvbiwgY29uc3RhbnQgaW4gKG9wZXJhbmRz
LCBvcGVyYW5kc1s6Oi0xXSk6CiAgICAgICAgbnVtYmVyID0gX2ludChjb25zdGFudCkKICAgICAg
ICBpZiBudW1iZXIgaXMgbm90IE5vbmUgYW5kIF9wcmVzZXJ2ZXNfaGlnaChleHByZXNzaW9uKToK
ICAgICAgICAgICAgcmV0dXJuIChudW1iZXIgJiBNQVNLID09IE1BU0spIGlmIG9wID09ICImIiBl
bHNlIChudW1iZXIgJiBNQVNLID09IDApCiAgICByZXR1cm4gRmFsc2UKCgpkZWYgX2xvd19tYXJr
X29ubHkodmFsdWUpOgogICAgaWYgbm90IF9jb250YWluc19tYXJrKHZhbHVlKToKICAgICAgICBy
ZXR1cm4gVHJ1ZQogICAgaWYgdmFsdWUgPT0geyJtZXRhIjogeyJrZXkiOiAibWFyayJ9fToKICAg
ICAgICByZXR1cm4gRmFsc2UKICAgIGlmIGlzaW5zdGFuY2UodmFsdWUsIGRpY3QpOgogICAgICAg
IGlmICImIiBpbiB2YWx1ZToKICAgICAgICAgICAgb3BlcmFuZHMgPSB2YWx1ZVsiJiJdCiAgICAg
ICAgICAgIGlmIGlzaW5zdGFuY2Uob3BlcmFuZHMsIGxpc3QpIGFuZCBsZW4ob3BlcmFuZHMpID09
IDI6CiAgICAgICAgICAgICAgICBmb3IgZXhwcmVzc2lvbiwgY29uc3RhbnQgaW4gKG9wZXJhbmRz
LCBvcGVyYW5kc1s6Oi0xXSk6CiAgICAgICAgICAgICAgICAgICAgbnVtYmVyID0gX2ludChjb25z
dGFudCkKICAgICAgICAgICAgICAgICAgICBpZiBudW1iZXIgaXMgbm90IE5vbmUgYW5kIG51bWJl
ciAmIE1BU0sgPT0gMDoKICAgICAgICAgICAgICAgICAgICAgICAgaWYgZXhwcmVzc2lvbiA9PSB7
Im1ldGEiOiB7ImtleSI6ICJtYXJrIn19OgogICAgICAgICAgICAgICAgICAgICAgICAgICAgcmV0
dXJuIFRydWUKICAgICAgICByZXR1cm4gYWxsKF9sb3dfbWFya19vbmx5KGl0ZW0pIGZvciBpdGVt
IGluIHZhbHVlLnZhbHVlcygpKQogICAgaWYgaXNpbnN0YW5jZSh2YWx1ZSwgbGlzdCk6CiAgICAg
ICAgcmV0dXJuIGFsbChfbG93X21hcmtfb25seShpdGVtKSBmb3IgaXRlbSBpbiB2YWx1ZSkKICAg
IHJldHVybiBUcnVlCgoKZGVmIF9mb3JlaWduX21hcmtfY29uZmxpY3QodmFsdWUpOgogICAgaWYg
bm90IF9jb250YWluc19tYXJrKHZhbHVlKToKICAgICAgICByZXR1cm4gRmFsc2UKICAgIGlmIHZh
bHVlID09IHsibWV0YSI6IHsia2V5IjogIm1hcmsifX06CiAgICAgICAgcmV0dXJuIFRydWUKICAg
IGlmIGlzaW5zdGFuY2UodmFsdWUsIGRpY3QpIGFuZCAibWFuZ2xlIiBpbiB2YWx1ZToKICAgICAg
ICBhc3NpZ25tZW50ID0gdmFsdWVbIm1hbmdsZSJdCiAgICAgICAgaWYgYXNzaWdubWVudC5nZXQo
ImtleSIpID09IHsibWV0YSI6IHsia2V5IjogIm1hcmsifX06CiAgICAgICAgICAgIHJldHVybiBu
b3QgX3ByZXNlcnZlc19oaWdoKGFzc2lnbm1lbnQuZ2V0KCJ2YWx1ZSIpKQogICAgaWYgaXNpbnN0
YW5jZSh2YWx1ZSwgZGljdCk6CiAgICAgICAgcmV0dXJuIGFueShfZm9yZWlnbl9tYXJrX2NvbmZs
aWN0KGl0ZW0pIGZvciBpdGVtIGluIHZhbHVlLnZhbHVlcygpKSBpZiBub3QgX2xvd19tYXJrX29u
bHkodmFsdWUpIGVsc2UgRmFsc2UKICAgIGlmIGlzaW5zdGFuY2UodmFsdWUsIGxpc3QpOgogICAg
ICAgIHJldHVybiBhbnkoX2ZvcmVpZ25fbWFya19jb25mbGljdChpdGVtKSBmb3IgaXRlbSBpbiB2
YWx1ZSkKICAgIHJldHVybiBGYWxzZQoKCmRlZiBfbGVnYWN5X21hcmtfY29uZmxpY3QobGluZSk6
CiAgICB0b2tlbnMgPSBzaGxleC5zcGxpdChsaW5lKQogICAgZGVmIGFyZ3VtZW50KG5hbWUsIGRl
ZmF1bHQ9Tm9uZSk6CiAgICAgICAgaWYgbmFtZSBub3QgaW4gdG9rZW5zOgogICAgICAgICAgICBy
ZXR1cm4gZGVmYXVsdAogICAgICAgIGluZGV4ID0gdG9rZW5zLmluZGV4KG5hbWUpICsgMQogICAg
ICAgIHJldHVybiB0b2tlbnNbaW5kZXhdIGlmIGluZGV4IDwgbGVuKHRva2VucykgZWxzZSBOb25l
CiAgICBwYWNrZXRfbWF0Y2ggPSBhbnkodG9rZW5zW2luZGV4OmluZGV4ICsgMl0gPT0gWyItbSIs
ICJtYXJrIl0gZm9yIGluZGV4IGluIHJhbmdlKGxlbih0b2tlbnMpIC0gMSkpCiAgICBpZiBwYWNr
ZXRfbWF0Y2ggYW5kICItLW1hcmsiIGluIHRva2VuczoKICAgICAgICB2YWx1ZSA9IGFyZ3VtZW50
KCItLW1hcmsiKQogICAgICAgIHBhcnRzID0gdmFsdWUuc3BsaXQoIi8iLCAxKSBpZiB2YWx1ZSBl
bHNlIFtdCiAgICAgICAgbWFzayA9IF9pbnQocGFydHNbMV0pIGlmIGxlbihwYXJ0cykgPT0gMiBl
bHNlIDB4ZmZmZmZmZmYKICAgICAgICBpZiBtYXNrIGlzIE5vbmUgb3IgbWFzayAmIE1BU0s6CiAg
ICAgICAgICAgIHJldHVybiBUcnVlCiAgICB0YXJnZXQgPSBhcmd1bWVudCgiLWoiLCBhcmd1bWVu
dCgiLS1qdW1wIikpCiAgICBpZiB0YXJnZXQgPT0gIkNPTk5NQVJLIjoKICAgICAgICAjIFJlc3Rv
cmUvc2F2ZSBjYW4gZXhjaGFuZ2UgcGFja2V0IGFuZCBjb25uZWN0aW9uIG1hcmtzLiBPbmx5IGV4
cGxpY2l0bHkKICAgICAgICAjIGxvdy1iaXQgbWFza3MgcHJvdmUgdGhlIHJlc2VydmVkIHBhY2tl
dCBiaXRzIHJlbWFpbiBpbmRlcGVuZGVudC4KICAgICAgICBpZiAiLS1yZXN0b3JlLW1hcmsiIGlu
IHRva2VucyBvciAiLS1zYXZlLW1hcmsiIGluIHRva2VuczoKICAgICAgICAgICAgbWFzayA9IF9p
bnQoYXJndW1lbnQoIi0tbmZtYXNrIiwgYXJndW1lbnQoIi0tbWFzayIsICIweGZmZmZmZmZmIikp
KQogICAgICAgICAgICBpZiBtYXNrIGlzIE5vbmUgb3IgbWFzayAmIE1BU0s6CiAgICAgICAgICAg
ICAgICByZXR1cm4gVHJ1ZQogICAgICAgICAgICBpZiAiLS1yZXN0b3JlLW1hcmsiIGluIHRva2Vu
czoKICAgICAgICAgICAgICAgIGN0bWFzayA9IF9pbnQoYXJndW1lbnQoIi0tY3RtYXNrIiwgYXJn
dW1lbnQoIi0tbWFzayIsICIweGZmZmZmZmZmIikpKQogICAgICAgICAgICAgICAgaWYgY3RtYXNr
IGlzIE5vbmUgb3IgY3RtYXNrICYgTUFTSzoKICAgICAgICAgICAgICAgICAgICByZXR1cm4gVHJ1
ZQogICAgICAgIHJldHVybiBGYWxzZQogICAgaWYgdGFyZ2V0ID09ICJNQVJLIjoKICAgICAgICBy
ZWNvZ25pemVkID0gRmFsc2UKICAgICAgICBmb3IgZmxhZyBpbiAoIi0tc2V0LXhtYXJrIiwgIi0t
c2V0LW1hcmsiLCAiLS1hbmQtbWFyayIsICItLW9yLW1hcmsiLCAiLS14b3ItbWFyayIpOgogICAg
ICAgICAgICB2YWx1ZSA9IGFyZ3VtZW50KGZsYWcpCiAgICAgICAgICAgIGlmIHZhbHVlIGlzIE5v
bmU6CiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICByZWNvZ25pemVkID0gVHJ1
ZQogICAgICAgICAgICBwYXJ0cyA9IHZhbHVlLnNwbGl0KCIvIiwgMSkKICAgICAgICAgICAgbnVt
YmVyID0gX2ludChwYXJ0c1swXSkKICAgICAgICAgICAgaWYgbnVtYmVyIGlzIE5vbmU6CiAgICAg
ICAgICAgICAgICByZXR1cm4gVHJ1ZQogICAgICAgICAgICBpZiBmbGFnIGluICgiLS1zZXQteG1h
cmsiLCAiLS1zZXQtbWFyayIpOgogICAgICAgICAgICAgICAgbWFzayA9IF9pbnQocGFydHNbMV0p
IGlmIGxlbihwYXJ0cykgPT0gMiBlbHNlIDB4ZmZmZmZmZmYKICAgICAgICAgICAgICAgIGlmIG1h
c2sgaXMgTm9uZSBvciAobnVtYmVyIHwgbWFzaykgJiBNQVNLOgogICAgICAgICAgICAgICAgICAg
IHJldHVybiBUcnVlCiAgICAgICAgICAgIGVsaWYgZmxhZyA9PSAiLS1hbmQtbWFyayI6CiAgICAg
ICAgICAgICAgICBpZiBudW1iZXIgJiBNQVNLICE9IE1BU0s6CiAgICAgICAgICAgICAgICAgICAg
cmV0dXJuIFRydWUKICAgICAgICAgICAgZWxpZiBudW1iZXIgJiBNQVNLOgogICAgICAgICAgICAg
ICAgcmV0dXJuIFRydWUKICAgICAgICBpZiBub3QgcmVjb2duaXplZDoKICAgICAgICAgICAgcmV0
dXJuIFRydWUKICAgIHJldHVybiBGYWxzZQoKCmNsYXNzIFBvcnRNYW5hZ2VyOgogICAgZGVmIF9f
aW5pdF9fKHNlbGYsIGN0eCk6CiAgICAgICAgc2VsZi5jdHggPSBjdHgKICAgICAgICBzZWxmLnN0
YXRlX3BhdGggPSBjdHguc3RhdGVfZGlyIC8gInBvcnRzLmpzb24iCgogICAgZGVmIF9sb2FkKHNl
bGYpOgogICAgICAgIHN0YXRlID0gc2VsZi5jdHgucmVhZF9qc29uKHNlbGYuc3RhdGVfcGF0aCwg
eyJzY2hlbWFfdmVyc2lvbiI6IDEsICJydWxlcyI6IHt9LCAiY2xzYWN0X293bmVkIjogW119KQog
ICAgICAgIGlmIG5vdCBpc2luc3RhbmNlKHN0YXRlLCBkaWN0KSBvciBzdGF0ZS5nZXQoInNjaGVt
YV92ZXJzaW9uIikgIT0gMSBvciBub3QgaXNpbnN0YW5jZShzdGF0ZS5nZXQoInJ1bGVzIiksIGRp
Y3QpOgogICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuerr+WPo+mZkOmAn+eKtuaAgeagvOW8
j+aXoOaViCIpCiAgICAgICAgc2Vlbiwgc2xvdHMsIGRldmljZXMgPSBzZXQoKSwgc2V0KCksIHNl
dCgpCiAgICAgICAgZm9yIHJ1bGVfaWQsIHJlY29yZCBpbiBzdGF0ZVsicnVsZXMiXS5pdGVtcygp
OgogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBpZiAodmFsaWRfaWQocnVsZV9pZCkg
IT0gcmVjb3JkWyJpZCJdIG9yIHJlY29yZFsiaWZiIl0gIT0gX2lmYihydWxlX2lkKSBvcgogICAg
ICAgICAgICAgICAgICAgICAgICB2YWxpZF9pbnRlcmZhY2UocmVjb3JkWyJpbnRlcmZhY2UiXSkg
IT0gcmVjb3JkWyJpbnRlcmZhY2UiXSBvcgogICAgICAgICAgICAgICAgICAgICAgICByZWNvcmRb
InByb3RvY29sIl0gbm90IGluICgidGNwIiwgInVkcCIsICJib3RoIikgb3IKICAgICAgICAgICAg
ICAgICAgICAgICAgcmVjb3JkWyJmYW1pbHkiXSBub3QgaW4gKCJpcHY0IiwgImlwdjYiLCAiYm90
aCIpIG9yCiAgICAgICAgICAgICAgICAgICAgICAgIG5vdCAxIDw9IHJlY29yZFsicG9ydCJdIDw9
IDY1NTM1IG9yIG5vdCAxIDw9IHJlY29yZFsic2xvdCJdIDw9IE1BWF9TTE9UIG9yCiAgICAgICAg
ICAgICAgICAgICAgICAgIHJlY29yZFsic2xvdCJdIGluIHNsb3RzIG9yIHJlY29yZFsiaWZiIl0g
aW4gZGV2aWNlcyBvcgogICAgICAgICAgICAgICAgICAgICAgICByZWNvcmRbInByb2ZpbGUiXVsi
bW9kZSJdIG5vdCBpbiAoInRiZiIsICJ0YmYtZnEiLCAiZnEiKSk6CiAgICAgICAgICAgICAgICAg
ICAgcmFpc2UgVmFsdWVFcnJvcigpCiAgICAgICAgICAgICAgICBleHBhbmRlZCA9IF9rZXlzKHJl
Y29yZCkKICAgICAgICAgICAgICAgIGlmIHNlZW4gJiBleHBhbmRlZDoKICAgICAgICAgICAgICAg
ICAgICByYWlzZSBWYWx1ZUVycm9yKCkKICAgICAgICAgICAgICAgIHNlZW4gfD0gZXhwYW5kZWQK
ICAgICAgICAgICAgICAgIHNsb3RzLmFkZChyZWNvcmRbInNsb3QiXSkKICAgICAgICAgICAgICAg
IGRldmljZXMuYWRkKHJlY29yZFsiaWZiIl0pCiAgICAgICAgICAgIGV4Y2VwdCAoS2V5RXJyb3Is
IFR5cGVFcnJvciwgVmFsdWVFcnJvciwgVHVuZUVycm9yKToKICAgICAgICAgICAgICAgIHJhaXNl
IFR1bmVFcnJvcigi56uv5Y+j6ZmQ6YCf6KeE5YiZ54q25oCB5o2f5Z2P77yaIiArIHN0cihydWxl
X2lkKSkKICAgICAgICByZXR1cm4gc3RhdGUKCiAgICBkZWYgX2pzb24oc2VsZiwgYXJndik6CiAg
ICAgICAgcmVzdWx0ID0gc2VsZi5jdHgucnVuKGFyZ3YpCiAgICAgICAgdHJ5OgogICAgICAgICAg
ICByZXR1cm4ganNvbi5sb2FkcyhyZXN1bHQuc3Rkb3V0KQogICAgICAgIGV4Y2VwdCAoVmFsdWVF
cnJvciwgVHlwZUVycm9yKToKICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLlkb3ku6TmnKro
v5Tlm57mnInmlYggSlNPTu+8miIgKyAiICIuam9pbihhcmd2KSwgMjApCgogICAgZGVmIF9saW5r
KHNlbGYsIG5hbWUpOgogICAgICAgIGxpbmtzID0gc2VsZi5fanNvbihbImlwIiwgIi1qIiwgIi1k
IiwgImxpbmsiLCAic2hvdyJdKQogICAgICAgIHJldHVybiBuZXh0KChsaW5rIGZvciBsaW5rIGlu
IGxpbmtzIGlmIGxpbmsuZ2V0KCJpZm5hbWUiKSA9PSBuYW1lKSwgTm9uZSkKCiAgICBkZWYgX3Rh
YmxlKHNlbGYsIHJ1bGVzZXQpOgogICAgICAgIGVudHJpZXMgPSBbXQogICAgICAgIHRhYmxlID0g
Tm9uZQogICAgICAgIGZvciBpdGVtIGluIHJ1bGVzZXQuZ2V0KCJuZnRhYmxlcyIsIFtdKToKICAg
ICAgICAgICAgZm9yIGtpbmQsIHZhbHVlIGluIGl0ZW0uaXRlbXMoKToKICAgICAgICAgICAgICAg
IGlmIG5vdCBpc2luc3RhbmNlKHZhbHVlLCBkaWN0KToKICAgICAgICAgICAgICAgICAgICBjb250
aW51ZQogICAgICAgICAgICAgICAgb3duID0gdmFsdWUuZ2V0KCJmYW1pbHkiKSA9PSAiaW5ldCIg
YW5kICh2YWx1ZS5nZXQoInRhYmxlIikgPT0gVEFCTEUgb3IKICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAga2luZCA9PSAidGFibGUiIGFuZCB2
YWx1ZS5nZXQoIm5hbWUiKSA9PSBUQUJMRSkKICAgICAgICAgICAgICAgIGlmIG93bjoKICAgICAg
ICAgICAgICAgICAgICBlbnRyaWVzLmFwcGVuZChpdGVtKQogICAgICAgICAgICAgICAgICAgIGlm
IGtpbmQgPT0gInRhYmxlIjoKICAgICAgICAgICAgICAgICAgICAgICAgdGFibGUgPSB2YWx1ZQog
ICAgICAgICAgICAgICAgZWxpZiBfZm9yZWlnbl9tYXJrX2NvbmZsaWN0KHZhbHVlKToKICAgICAg
ICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuW3suaciSBuZnQgcGFja2V0IG1hcmsg5L2/
55So77yM5peg5rOV56Gu6K6k5L+d55WZ6auYIDE2IOS9jeepuumXsiIpCiAgICAgICAgaWYgZW50
cmllcyBhbmQgKHRhYmxlIGlzIE5vbmUgb3IgdGFibGUuZ2V0KCJjb21tZW50IikgIT0gT1dORVIp
OgogICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuWQjOWQjSBuZnQg6KGo5LiN5bGe5LqO56uv
5Y+j6ZmQ6YCf5Yqf6IO9IikKICAgICAgICByZXR1cm4gZW50cmllcwoKICAgIGRlZiBfbGVnYWN5
X21hcmtzKHNlbGYpOgogICAgICAgIGZvciBmYW1pbHksIGNvbW1hbmQgaW4gKCgiaXAiLCAiaXB0
YWJsZXMtc2F2ZSIpLCAoImlwNiIsICJpcDZ0YWJsZXMtc2F2ZSIpKToKICAgICAgICAgICAgcGF0
aCA9IHNlbGYuY3R4LnBhdGgoIi9wcm9jL25ldC8iICsgZmFtaWx5ICsgIl90YWJsZXNfbmFtZXMi
KQogICAgICAgICAgICBpZiBub3QgcGF0aC5leGlzdHMoKSBvciAibWFuZ2xlIiBub3QgaW4gcGF0
aC5yZWFkX3RleHQoKS5zcGxpdCgpOgogICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAg
ICAgc2VsZi5jdHgucmVxdWlyZV90b29scyhjb21tYW5kKQogICAgICAgICAgICB2ZXJzaW9uID0g
c2VsZi5jdHgucnVuKFtjb21tYW5kLCAiLS12ZXJzaW9uIl0pLnN0ZG91dAogICAgICAgICAgICBp
ZiAibmZfdGFibGVzIiBpbiB2ZXJzaW9uOgogICAgICAgICAgICAgICAgY29tbWFuZCA9IGNvbW1h
bmQucmVwbGFjZSgiLXNhdmUiLCAiLWxlZ2FjeS1zYXZlIikKICAgICAgICAgICAgICAgIHNlbGYu
Y3R4LnJlcXVpcmVfdG9vbHMoY29tbWFuZCkKICAgICAgICAgICAgb3V0cHV0ID0gc2VsZi5jdHgu
cnVuKFtjb21tYW5kLCAiLXQiLCAibWFuZ2xlIl0pLnN0ZG91dAogICAgICAgICAgICBpZiBhbnko
X2xlZ2FjeV9tYXJrX2NvbmZsaWN0KGxpbmUpIGZvciBsaW5lIGluIG91dHB1dC5zcGxpdGxpbmVz
KCkgaWYgbGluZS5zdGFydHN3aXRoKCItQSAiKSk6CiAgICAgICAgICAgICAgICByYWlzZSBUdW5l
RXJyb3IoIuW3suaciSBsZWdhY3kgIiArIGNvbW1hbmQgKyAiIG1hcmsg6KeE5YiZ77yM5LiN6IO9
56Gu6K6k6auYIDE2IOS9jeepuumXsiIpCgogICAgZGVmIF9maWx0ZXJzKHNlbGYsIGludGVyZmFj
ZSk6CiAgICAgICAgY2hhaW5zID0gc2VsZi5fanNvbihbInRjIiwgIi1qIiwgImNoYWluIiwgInNo
b3ciLCAiZGV2IiwgaW50ZXJmYWNlLCAiZWdyZXNzIl0pCiAgICAgICAgaWYgYW55KGludChjaGFp
bi5nZXQoImNoYWluIiwgMCkpICE9IDAgZm9yIGNoYWluIGluIGNoYWlucyk6CiAgICAgICAgICAg
IHJhaXNlIFR1bmVFcnJvcihpbnRlcmZhY2UgKyAiIOWtmOWcqOWklumDqCBlZ3Jlc3MgY2hhaW4i
KQogICAgICAgIHJldHVybiBzZWxmLl9qc29uKFsidGMiLCAiLWoiLCAiZmlsdGVyIiwgInNob3ci
LCAiZGV2IiwgaW50ZXJmYWNlLCAiZWdyZXNzIl0pCgogICAgZGVmIF9wcmVmbGlnaHQoc2VsZiwg
c3RhdGUsIGRlc2lyZWQsIGJvb3Q9RmFsc2UpOgogICAgICAgIHNlbGYuY3R4LnJlcXVpcmVfdG9v
bHMoImlwIiwgInRjIiwgIm5mdCIpCiAgICAgICAgdW5pdCA9IHNlbGYuY3R4LnVuaXRfcGF0aChV
TklUKQogICAgICAgIHVuaXRfc3RhdGUgPSBzZWxmLmN0eC51bml0X3N0YXRlKFVOSVQpCiAgICAg
ICAgaWYgdW5pdC5leGlzdHMoKToKICAgICAgICAgICAgc2VsZi5jdHguc25hcHNob3RfZmlsZSh1
bml0KQogICAgICAgICAgICBpZiBPV05FUiBub3QgaW4gdW5pdC5yZWFkX3RleHQoKToKICAgICAg
ICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5ZCM5ZCN5ZCv5Yqo5pyN5Yqh5LiN5bGe5LqO56uv
5Y+j6ZmQ6YCf5Yqf6IO9IikKICAgICAgICBlbGlmIHVuaXRfc3RhdGUuZ2V0KCJsb2FkX3N0YXRl
IiwgIm5vdC1mb3VuZCIpICE9ICJub3QtZm91bmQiOgogICAgICAgICAgICByYWlzZSBUdW5lRXJy
b3IoIuezu+e7n+S4reW3suacieWFtuS7luS9jee9ruaPkOS+m+eahOWQjOWQjeWQr+WKqOacjeWK
oSIpCiAgICAgICAgcnVsZXNldCA9IHNlbGYuX2pzb24oWyJuZnQiLCAiLWoiLCAibGlzdCIsICJy
dWxlc2V0Il0pCiAgICAgICAgdGFibGUgPSBzZWxmLl90YWJsZShydWxlc2V0KQogICAgICAgIHNl
bGYuX2xlZ2FjeV9tYXJrcygpCiAgICAgICAgaW50ZXJmYWNlcyA9IHtydWxlWyJpbnRlcmZhY2Ui
XSBmb3IgcnVsZSBpbiBsaXN0KHN0YXRlWyJydWxlcyJdLnZhbHVlcygpKSArIGxpc3QoZGVzaXJl
ZC52YWx1ZXMoKSl9CiAgICAgICAgZm9yIGl0ZW0gaW4gcnVsZXNldC5nZXQoIm5mdGFibGVzIiwg
W10pOgogICAgICAgICAgICBmbG93dGFibGUgPSBpdGVtLmdldCgiZmxvd3RhYmxlIiwge30pCiAg
ICAgICAgICAgIGRldmljZXMgPSBmbG93dGFibGUuZ2V0KCJkZXYiLCBmbG93dGFibGUuZ2V0KCJk
ZXZpY2VzIiwgW10pKQogICAgICAgICAgICBpZiBpc2luc3RhbmNlKGRldmljZXMsIHN0cik6CiAg
ICAgICAgICAgICAgICBkZXZpY2VzID0gW2RldmljZXNdCiAgICAgICAgICAgIGlmIGludGVyZmFj
ZXMuaW50ZXJzZWN0aW9uKGRldmljZXMpOgogICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9y
KCLnm67moIfmjqXlj6Plt7LmnIkgbmZ0IGZsb3d0YWJsZe+8jOS8mue7lei/h+err+WPo+WIhuex
uyIpCiAgICAgICAgZm9yIGZhbWlseSBpbiAoIi00IiwgIi02Iik6CiAgICAgICAgICAgIGZvciBw
b2xpY3kgaW4gc2VsZi5fanNvbihbImlwIiwgIi1qIiwgZmFtaWx5LCAicnVsZSIsICJzaG93Il0p
OgogICAgICAgICAgICAgICAgb3V0cHV0ID0gcG9saWN5LmdldCgib2lmIiwgcG9saWN5LmdldCgi
b2lmbmFtZSIpKQogICAgICAgICAgICAgICAgaWYgb3V0cHV0IGFuZCBvdXRwdXQgbm90IGluIGlu
dGVyZmFjZXM6CiAgICAgICAgICAgICAgICAgICAgY29udGludWUKICAgICAgICAgICAgICAgIGlm
ICJmd21hcmsiIGluIHBvbGljeToKICAgICAgICAgICAgICAgICAgICB2YWx1ZSA9IHBvbGljeVsi
ZndtYXJrIl0KICAgICAgICAgICAgICAgICAgICBpbmxpbmVfbWFzayA9IHZhbHVlLnNwbGl0KCIv
IiwgMSlbMV0gaWYgaXNpbnN0YW5jZSh2YWx1ZSwgc3RyKSBhbmQgIi8iIGluIHZhbHVlIGVsc2Ug
MHhmZmZmZmZmZgogICAgICAgICAgICAgICAgICAgIG1hc2sgPSBfaW50KHBvbGljeS5nZXQoImZ3
bWFzayIsIGlubGluZV9tYXNrKSkKICAgICAgICAgICAgICAgICAgICBpZiBtYXNrIGlzIE5vbmUg
b3IgbWFzayAmIE1BU0s6CiAgICAgICAgICAgICAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi
562W55Wl6Lev55Sx5bey57uP5L2/55So5L+d55WZ55qEIHBhY2tldCBtYXJrIOmrmCAxNiDkvY0i
KQogICAgICAgIGlmIHRhYmxlOgogICAgICAgICAgICBleHBlY3RlZCA9IHN0YXRlLmdldCgibmZ0
X2ZpbmdlcnByaW50IikKICAgICAgICAgICAgaWYgbm90IGV4cGVjdGVkIG9yIGV4cGVjdGVkICE9
IF9maW5nZXJwcmludCh0YWJsZSwgbmZ0PVRydWUpOgogICAgICAgICAgICAgICAgcmFpc2UgVHVu
ZUVycm9yKCLnq6/lj6PpmZDpgJ8gbmZ0IOihqOW3suWPkeeUn+WklumDqOS/ruaUuSIpCiAgICAg
ICAgZWxpZiBzdGF0ZVsicnVsZXMiXSBhbmQgbm90IGJvb3Q6CiAgICAgICAgICAgIHJhaXNlIFR1
bmVFcnJvcigi56uv5Y+j6ZmQ6YCfIG5mdCDooajkuKLlpLHvvIzor7fpgJrov4flkK/liqjmgaLl
pI3lkI7ph43or5UiKQogICAgICAgIGxpdmUgPSB7InRhYmxlIjogdGFibGUsICJsaW5rcyI6IHt9
LCAiZmlsdGVycyI6IHt9LCAiY2xzYWN0Ijoge30sICJ1bml0IjogdW5pdF9zdGF0ZX0KICAgICAg
ICBmb3IgaW50ZXJmYWNlIGluIHNvcnRlZChpbnRlcmZhY2VzKToKICAgICAgICAgICAgbGluayA9
IHNlbGYuX2xpbmsoaW50ZXJmYWNlKQogICAgICAgICAgICBpZiBsaW5rIGlzIE5vbmU6CiAgICAg
ICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuaOpeWPo+S4jeWtmOWcqO+8miIgKyBpbnRlcmZh
Y2UsIDMpCiAgICAgICAgICAgIGxpdmVbImxpbmtzIl1baW50ZXJmYWNlXSA9IGxpbmsKICAgICAg
ICAgICAgcXVldWVzID0gc2VsZi5fanNvbihbInRjIiwgIi1qIiwgInFkaXNjIiwgInNob3ciLCAi
ZGV2IiwgaW50ZXJmYWNlXSkKICAgICAgICAgICAgaWYgYW55KHF1ZXVlLmdldCgia2luZCIpID09
ICJpbmdyZXNzIiBmb3IgcXVldWUgaW4gcXVldWVzKToKICAgICAgICAgICAgICAgIHJhaXNlIFR1
bmVFcnJvcihpbnRlcmZhY2UgKyAiIOW3suaciSBpbmdyZXNzIHFkaXNj77yM5LiN6IO95pu/5o2i
5Li6IGNsc2FjdCIpCiAgICAgICAgICAgIGxpdmVbImNsc2FjdCJdW2ludGVyZmFjZV0gPSBhbnko
cXVldWUuZ2V0KCJraW5kIikgPT0gImNsc2FjdCIgZm9yIHF1ZXVlIGluIHF1ZXVlcykKICAgICAg
ICAgICAgZmlsdGVycyA9IHNlbGYuX2ZpbHRlcnMoaW50ZXJmYWNlKSBpZiBsaXZlWyJjbHNhY3Qi
XVtpbnRlcmZhY2VdIGVsc2UgW10KICAgICAgICAgICAgZXhwZWN0ZWQgPSB7UFJFRl9CQVNFICsg
cnVsZVsic2xvdCJdOiBydWxlIGZvciBydWxlIGluIHN0YXRlWyJydWxlcyJdLnZhbHVlcygpCiAg
ICAgICAgICAgICAgICAgICAgICAgIGlmIHJ1bGVbImludGVyZmFjZSJdID09IGludGVyZmFjZX0K
ICAgICAgICAgICAgZm9yIGl0ZW0gaW4gZmlsdGVyczoKICAgICAgICAgICAgICAgIHJlY29yZCA9
IGV4cGVjdGVkLmdldChpdGVtLmdldCgicHJlZiIpKQogICAgICAgICAgICAgICAgaWYgcmVjb3Jk
IGlzIE5vbmUgb3IgaXRlbS5nZXQoImtpbmQiKSAhPSAiZnciOgogICAgICAgICAgICAgICAgICAg
IHJhaXNlIFR1bmVFcnJvcihpbnRlcmZhY2UgKyAiIOWtmOWcqOWklumDqCBlZ3Jlc3Mg5YiG57G7
5ZmoIikKICAgICAgICAgICAgZm9yIHByZWYsIHJlY29yZCBpbiBleHBlY3RlZC5pdGVtcygpOgog
ICAgICAgICAgICAgICAgYWN0dWFsID0gW2l0ZW0gZm9yIGl0ZW0gaW4gZmlsdGVycyBpZiBpdGVt
LmdldCgicHJlZiIpID09IHByZWZdCiAgICAgICAgICAgICAgICBpZiBhY3R1YWwgYW5kIF9maW5n
ZXJwcmludChhY3R1YWwpICE9IHJlY29yZC5nZXQoImZpbHRlcl9maW5nZXJwcmludCIpOgogICAg
ICAgICAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcihpbnRlcmZhY2UgKyAiIOeahOerr+WPo+WI
huexu+WZqOW3suWPkeeUn+WklumDqOS/ruaUuSIpCiAgICAgICAgICAgICAgICBpZiBub3QgYWN0
dWFsIGFuZCBub3QgYm9vdDoKICAgICAgICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoaW50
ZXJmYWNlICsgIiDnmoTnq6/lj6PliIbnsbvlmajkuKLlpLEiKQogICAgICAgICAgICBsaXZlWyJm
aWx0ZXJzIl1baW50ZXJmYWNlXSA9IGZpbHRlcnMKICAgICAgICBmb3IgcnVsZV9pZCwgcnVsZSBp
biB7KipzdGF0ZVsicnVsZXMiXSwgKipkZXNpcmVkfS5pdGVtcygpOgogICAgICAgICAgICBkZXZp
Y2UgPSBzZWxmLl9saW5rKHJ1bGVbImlmYiJdKQogICAgICAgICAgICBsaXZlWyJsaW5rcyJdW3J1
bGVbImlmYiJdXSA9IGRldmljZQogICAgICAgICAgICBpZiBkZXZpY2UgaXMgTm9uZToKICAgICAg
ICAgICAgICAgIGlmIHJ1bGVfaWQgaW4gc3RhdGVbInJ1bGVzIl0gYW5kIG5vdCBib290OgogICAg
ICAgICAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi56uv5Y+j6ZmQ6YCfIElGQiDkuKLlpLHv
vJoiICsgcnVsZVsiaWZiIl0pCiAgICAgICAgICAgICAgICBjb250aW51ZQogICAgICAgICAgICBp
ZiAoZGV2aWNlLmdldCgiaWZhbGlhcyIpICE9IF9hbGlhcyhydWxlX2lkKSBvcgogICAgICAgICAg
ICAgICAgICAgIGRldmljZS5nZXQoImxpbmtpbmZvIiwge30pLmdldCgiaW5mb19raW5kIikgIT0g
ImlmYiIpOgogICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLlkIzlkI3orr7lpIfkuI3l
sZ7kuo7nq6/lj6PpmZDpgJ/lip/og73vvJoiICsgcnVsZVsiaWZiIl0pCiAgICAgICAgICAgIGlm
IHJ1bGVfaWQgbm90IGluIHN0YXRlWyJydWxlcyJdOgogICAgICAgICAgICAgICAgcmFpc2UgVHVu
ZUVycm9yKCLlj5HnjrDmsqHmnInlt7Lkv53lrZjop4TliJnnmoTlkIzlkI0gSUZC77yaIiArIHJ1
bGVbImlmYiJdKQogICAgICAgICAgICBvbGQgPSBzdGF0ZVsicnVsZXMiXVtydWxlX2lkXQogICAg
ICAgICAgICBpZiBkZXZpY2UuZ2V0KCJtdHUiKSAhPSBsaXZlWyJsaW5rcyJdW29sZFsiaW50ZXJm
YWNlIl1dLmdldCgibXR1Iik6CiAgICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIklGQiBN
VFUg5LiO54mp55CG5o6l5Y+j5LiN5LiA6Ie077yaIiArIHJ1bGVbImlmYiJdKQogICAgICAgICAg
ICBpZiAiVVAiIG5vdCBpbiBkZXZpY2UuZ2V0KCJmbGFncyIsIFtdKSBhbmQgbm90IGJvb3Q6CiAg
ICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuerr+WPo+mZkOmAnyBJRkIg5pyq5ZCv55So
77yaIiArIHJ1bGVbImlmYiJdKQogICAgICAgICAgICBpZiBub3QgcHJvZmlsZV9tYXRjaGVzKHNl
bGYuY3R4LCBydWxlWyJpZmIiXSwgb2xkWyJwcm9maWxlIl0pOgogICAgICAgICAgICAgICAgcmFp
c2UgVHVuZUVycm9yKCJJRkIg6Zif5YiX6YWN572u5bey5Y+R55Sf5aSW6YOo5L+u5pS577yaIiAr
IHJ1bGVbImlmYiJdKQogICAgICAgICAgICBmb3IgZGlyZWN0aW9uIGluICgiaW5ncmVzcyIsICJl
Z3Jlc3MiKToKICAgICAgICAgICAgICAgIGZpbHRlcnMgPSBzZWxmLl9qc29uKFsidGMiLCAiLWoi
LCAiZmlsdGVyIiwgInNob3ciLCAiZGV2IiwgcnVsZVsiaWZiIl0sIGRpcmVjdGlvbl0pCiAgICAg
ICAgICAgICAgICBpZiBmaWx0ZXJzOgogICAgICAgICAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJv
cigiSUZCIOWtmOWcqOWklumDqOWIhuexu+WZqO+8miIgKyBydWxlWyJpZmIiXSkKICAgICAgICAg
ICAgIyBTbmFwc2hvdCBjaGVja3MgcmVqZWN0IHVub3duZWQgcm9vdCBmaWx0ZXJzIG9yIHVuc3Vw
cG9ydGVkIGNoaWxkcmVuLgogICAgICAgICAgICBjYXB0dXJlX3NuYXBzaG90KHNlbGYuY3R4LCBy
dWxlWyJpZmIiXSkKICAgICAgICByZXR1cm4gbGl2ZQoKICAgIGRlZiBsaXN0KHNlbGYpOgogICAg
ICAgIHN0YXRlID0gc2VsZi5fbG9hZCgpCiAgICAgICAgcmV0dXJuIHsiZmVhdHVyZSI6ICJwb3J0
cyIsICJydWxlcyI6IGNvcHkuZGVlcGNvcHkoc3RhdGVbInJ1bGVzIl0pfQoKICAgIGRlZiBzdGF0
dXMoc2VsZik6CiAgICAgICAgc3RhdGUgPSBzZWxmLl9sb2FkKCkKICAgICAgICByZXN1bHQgPSB7
ImZlYXR1cmUiOiAicG9ydHMiLCAicnVsZXMiOiBjb3B5LmRlZXBjb3B5KHN0YXRlWyJydWxlcyJd
KSwKICAgICAgICAgICAgICAgICAgIm1hbmFnZWQiOiBib29sKHN0YXRlWyJydWxlcyJdKSwgImRy
aWZ0IjogW119CiAgICAgICAgaWYgc3RhdGVbInJ1bGVzIl06CiAgICAgICAgICAgIHRyeToKICAg
ICAgICAgICAgICAgIHNlbGYuX3ByZWZsaWdodChzdGF0ZSwgc3RhdGVbInJ1bGVzIl0pCiAgICAg
ICAgICAgIGV4Y2VwdCBUdW5lRXJyb3IgYXMgZXJyb3I6CiAgICAgICAgICAgICAgICByZXN1bHRb
ImRyaWZ0Il0uYXBwZW5kKHN0cihlcnJvcikpCiAgICAgICAgcmV0dXJuIHJlc3VsdAoKICAgIGRl
ZiBzZXQoc2VsZiwgYXJncyk6CiAgICAgICAgc3RhdGUgPSBzZWxmLl9sb2FkKCkKICAgICAgICBy
dWxlX2lkID0gdmFsaWRfaWQoYXJncy5pZCkKICAgICAgICBwcmV2aW91cyA9IHN0YXRlWyJydWxl
cyJdLmdldChydWxlX2lkKQogICAgICAgIHNsb3RzID0ge3JlY29yZFsic2xvdCJdIGZvciByZWNv
cmQgaW4gc3RhdGVbInJ1bGVzIl0udmFsdWVzKCl9CiAgICAgICAgc2xvdCA9IHByZXZpb3VzWyJz
bG90Il0gaWYgcHJldmlvdXMgZWxzZSBuZXh0KChpIGZvciBpIGluIHJhbmdlKDEsIE1BWF9TTE9U
ICsgMSkgaWYgaSBub3QgaW4gc2xvdHMpLCBOb25lKQogICAgICAgIGlmIHNsb3QgaXMgTm9uZToK
ICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLnq6/lj6PpmZDpgJ/op4TliJnmlbDph4/lt7Lo
vr7liLDkuIrpmZAiKQogICAgICAgIHJlY29yZCA9IF9ydWxlKGFyZ3MsIHNsb3QpCiAgICAgICAg
Zm9yIG90aGVyX2lkLCBvdGhlciBpbiBzdGF0ZVsicnVsZXMiXS5pdGVtcygpOgogICAgICAgICAg
ICBpZiBvdGhlcl9pZCAhPSBydWxlX2lkIGFuZCBfa2V5cyhyZWNvcmQpICYgX2tleXMob3RoZXIp
OgogICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVycm9yKCLnq6/lj6PpmZDpgJ/op4TliJnph43l
j6DvvJoiICsgb3RoZXJfaWQpCiAgICAgICAgZGVzaXJlZCA9IGNvcHkuZGVlcGNvcHkoc3RhdGVb
InJ1bGVzIl0pCiAgICAgICAgZGVzaXJlZFtydWxlX2lkXSA9IHJlY29yZAogICAgICAgIGxpdmUg
PSBzZWxmLl9wcmVmbGlnaHQoc3RhdGUsIGRlc2lyZWQpCiAgICAgICAgaWYgcHJldmlvdXMgYW5k
IF9zYW1lX3J1bGUocHJldmlvdXMsIHJlY29yZCk6CiAgICAgICAgICAgIHJldHVybiB7ImZlYXR1
cmUiOiAicG9ydHMiLCAiY2hhbmdlZCI6IEZhbHNlLCAicnVsZSI6IHByZXZpb3VzfQogICAgICAg
IGlmIHNlbGYuY3R4LmRyeV9ydW46CiAgICAgICAgICAgIHJldHVybiB7ImZlYXR1cmUiOiAicG9y
dHMiLCAiZHJ5X3J1biI6IFRydWUsICJydWxlIjogcmVjb3JkfQogICAgICAgIGNhcHMgPSBbXQog
ICAgICAgIGZvciBrZXksIGxhYmVsIGluICgoInJhdGVfYnBzIiwgIuaAu+mZkOmAnyIpLCAoIm1h
eHJhdGVfYnBzIiwgIuavj+adoSBUQ1Ag5rWB6ZmQ6YCfIikpOgogICAgICAgICAgICByYXRlID0g
cmVjb3JkWyJwcm9maWxlIl0uZ2V0KGtleSkKICAgICAgICAgICAgdmFsdWUgPSAoZiJ7cmF0ZSAv
LyAxXzAwMF8wMDB9LntyYXRlICUgMV8wMDBfMDAwOjA2ZH0iLnJzdHJpcCgiMCIpLnJzdHJpcCgi
LiIpICsgIiBNYnBzIgogICAgICAgICAgICAgICAgICAgICBpZiByYXRlIGlzIG5vdCBOb25lIGVs
c2UgIuacquiuvue9riIpCiAgICAgICAgICAgIGNhcHMuYXBwZW5kKGxhYmVsICsgIu+8miIgKyB2
YWx1ZSkKICAgICAgICBwcm90b2NvbCA9IHsidGNwIjogIlRDUCIsICJ1ZHAiOiAiVURQIiwgImJv
dGgiOiAiVENQK1VEUCJ9W3JlY29yZFsicHJvdG9jb2wiXV0KICAgICAgICBmYW1pbHkgPSB7Imlw
djQiOiAiSVB2NCIsICJpcHY2IjogIklQdjYiLCAiYm90aCI6ICJJUHY0K0lQdjYifVtyZWNvcmRb
ImZhbWlseSJdXQogICAgICAgIHNlbGYuY3R4LmNvbmZpcm0oIuiuvue9ruerr+WPo+mZkOmAnyAi
ICsgcnVsZV9pZCArICLvvIzmjqXlj6MgIiArIHJlY29yZFsiaW50ZXJmYWNlIl0gKyAi77yM5rqQ
56uv5Y+jICIgKyBzdHIocmVjb3JkWyJwb3J0Il0pICsKICAgICAgICAgICAgICAgICAgICAgICAg
ICLvvIzljY/orq4gIiArIHByb3RvY29sICsgIu+8jOWcsOWdgOaXjyAiICsgZmFtaWx5ICsgIu+8
myIgKyAi77ybIi5qb2luKGNhcHMpKQogICAgICAgIHJldHVybiBzZWxmLl9jb21taXQoc3RhdGUs
IGRlc2lyZWQsIGxpdmUpCgogICAgZGVmIGRlbGV0ZShzZWxmLCBhcmdzKToKICAgICAgICBzdGF0
ZSA9IHNlbGYuX2xvYWQoKQogICAgICAgIHJ1bGVfaWQgPSB2YWxpZF9pZChhcmdzLmlkKQogICAg
ICAgIGlmIHJ1bGVfaWQgbm90IGluIHN0YXRlWyJydWxlcyJdOgogICAgICAgICAgICByZXR1cm4g
eyJmZWF0dXJlIjogInBvcnRzIiwgImNoYW5nZWQiOiBGYWxzZSwgImRlbGV0ZWQiOiBydWxlX2lk
fQogICAgICAgIGRlc2lyZWQgPSBjb3B5LmRlZXBjb3B5KHN0YXRlWyJydWxlcyJdKQogICAgICAg
IGRlbCBkZXNpcmVkW3J1bGVfaWRdCiAgICAgICAgbGl2ZSA9IHNlbGYuX3ByZWZsaWdodChzdGF0
ZSwgZGVzaXJlZCkKICAgICAgICBpZiBzZWxmLmN0eC5kcnlfcnVuOgogICAgICAgICAgICByZXR1
cm4geyJmZWF0dXJlIjogInBvcnRzIiwgImRyeV9ydW4iOiBUcnVlLCAiZGVsZXRlZCI6IHJ1bGVf
aWR9CiAgICAgICAgcHJldmlvdXMgPSBzdGF0ZVsicnVsZXMiXVtydWxlX2lkXQogICAgICAgIHNl
bGYuY3R4LmNvbmZpcm0oIuWIoOmZpOerr+WPo+mZkOmAnyAiICsgcnVsZV9pZCArICLvvIzmjqXl
j6MgIiArIHByZXZpb3VzWyJpbnRlcmZhY2UiXSArICLvvIzmupDnq6/lj6MgIiArIHN0cihwcmV2
aW91c1sicG9ydCJdKSkKICAgICAgICByZXR1cm4gc2VsZi5fY29tbWl0KHN0YXRlLCBkZXNpcmVk
LCBsaXZlKQoKICAgIGRlZiBib290KHNlbGYsIGludGVyZmFjZT1Ob25lKToKICAgICAgICBzdGF0
ZSA9IHNlbGYuX2xvYWQoKQogICAgICAgIGlmIG5vdCBzdGF0ZVsicnVsZXMiXToKICAgICAgICAg
ICAgcmV0dXJuIHsiZmVhdHVyZSI6ICJwb3J0cyIsICJjaGFuZ2VkIjogRmFsc2V9CiAgICAgICAg
aWYgaW50ZXJmYWNlIGlzIG5vdCBOb25lOgogICAgICAgICAgICB2YWxpZF9pbnRlcmZhY2UoaW50
ZXJmYWNlKQogICAgICAgIGxpdmUgPSBzZWxmLl9wcmVmbGlnaHQoc3RhdGUsIHN0YXRlWyJydWxl
cyJdLCBib290PVRydWUpCiAgICAgICAgY29tcGxldGUgPSBib29sKGxpdmVbInRhYmxlIl0pIGFu
ZCBhbGwobGl2ZVsibGlua3MiXS5nZXQocnVsZVsiaWZiIl0pIGFuZAogICAgICAgICAgICAgICAg
ICAgIGFueShpdGVtLmdldCgicHJlZiIpID09IFBSRUZfQkFTRSArIHJ1bGVbInNsb3QiXSBmb3Ig
aXRlbSBpbiBsaXZlWyJmaWx0ZXJzIl1bcnVsZVsiaW50ZXJmYWNlIl1dKQogICAgICAgICAgICAg
ICAgICAgIGZvciBydWxlIGluIHN0YXRlWyJydWxlcyJdLnZhbHVlcygpKQogICAgICAgIGlmIGNv
bXBsZXRlOgogICAgICAgICAgICByZXR1cm4geyJmZWF0dXJlIjogInBvcnRzIiwgImNoYW5nZWQi
OiBGYWxzZX0KICAgICAgICBpZiBzZWxmLmN0eC5kcnlfcnVuOgogICAgICAgICAgICByZXR1cm4g
eyJmZWF0dXJlIjogInBvcnRzIiwgImRyeV9ydW4iOiBUcnVlfQogICAgICAgIHJldHVybiBzZWxm
Ll9jb21taXQoc3RhdGUsIGNvcHkuZGVlcGNvcHkoc3RhdGVbInJ1bGVzIl0pLCBsaXZlLCBib290
PVRydWUpCgogICAgZGVmIF9hZGRfZmlsdGVyKHNlbGYsIHJ1bGUpOgogICAgICAgIHNlbGYuY3R4
Lm11dGF0ZShbInRjIiwgImZpbHRlciIsICJhZGQiLCAiZGV2IiwgcnVsZVsiaW50ZXJmYWNlIl0s
ICJlZ3Jlc3MiLCAicHJvdG9jb2wiLCAiYWxsIiwKICAgICAgICAgICAgICAgICAgICAgICAgICJw
cmVmIiwgc3RyKFBSRUZfQkFTRSArIHJ1bGVbInNsb3QiXSksICJoYW5kbGUiLCBoZXgocnVsZVsi
c2xvdCJdIDw8IDE2KSArICIvMHhmZmZmMDAwMCIsCiAgICAgICAgICAgICAgICAgICAgICAgICAi
ZnciLCAiYWN0aW9uIiwgInNrYmVkaXQiLCAibWFyayIsICIwLzB4ZmZmZjAwMDAiLCAicGlwZSIs
ICJhY3Rpb24iLCAibWlycmVkIiwKICAgICAgICAgICAgICAgICAgICAgICAgICJlZ3Jlc3MiLCAi
cmVkaXJlY3QiLCAiZGV2IiwgcnVsZVsiaWZiIl1dKQoKICAgIGRlZiBfZGVsZXRlX2ZpbHRlcihz
ZWxmLCBydWxlKToKICAgICAgICBzZWxmLmN0eC5tdXRhdGUoWyJ0YyIsICJmaWx0ZXIiLCAiZGVs
IiwgImRldiIsIHJ1bGVbImludGVyZmFjZSJdLCAiZWdyZXNzIiwgInByb3RvY29sIiwgImFsbCIs
CiAgICAgICAgICAgICAgICAgICAgICAgICAicHJlZiIsIHN0cihQUkVGX0JBU0UgKyBydWxlWyJz
bG90Il0pLCAiaGFuZGxlIiwgaGV4KHJ1bGVbInNsb3QiXSA8PCAxNikgKyAiLzB4ZmZmZjAwMDAi
LCAiZnciXSkKCiAgICBkZWYgX3dyaXRlX3RhYmxlKHNlbGYsIHJ1bGVzLCBleGlzdHMpOgogICAg
ICAgIGlmIHJ1bGVzIG9yIGV4aXN0czoKICAgICAgICAgICAgc2VsZi5jdHgubXV0YXRlKFsibmZ0
IiwgIi1mIiwgIi0iXSwgaW5wdXQ9X25mdF9zY3JpcHQocnVsZXMsIGV4aXN0cykpCgogICAgZGVm
IF9jb21taXQoc2VsZiwgb2xkLCBkZXNpcmVkLCBsaXZlLCBib290PUZhbHNlKToKICAgICAgICBz
ZWxmLmN0eC5yZXF1aXJlX211dGF0aW9uKCkKICAgICAgICBzYXZlZF9zdGF0ZSA9IHNlbGYuY3R4
LnNuYXBzaG90X2ZpbGUoc2VsZi5zdGF0ZV9wYXRoKQogICAgICAgIHNhdmVkX3VuaXQgPSBsaXZl
WyJ1bml0Il0KICAgICAgICBpZiBzYXZlZF91bml0WyJleGlzdHMiXToKICAgICAgICAgICAgcGF0
aCA9IHNlbGYuY3R4LnVuaXRfcGF0aChVTklUKQogICAgICAgICAgICBpZiBub3QgcGF0aC5pc19m
aWxlKCkgb3IgT1dORVIgbm90IGluIHBhdGgucmVhZF90ZXh0KCk6CiAgICAgICAgICAgICAgICBy
YWlzZSBUdW5lRXJyb3IoIuWQjOWQjeWQr+WKqOacjeWKoeS4jeWxnuS6juerr+WPo+mZkOmAn+WK
n+iDvSIpCiAgICAgICAgYmVmb3JlID0ge3J1bGVfaWQ6IGNhcHR1cmVfc25hcHNob3Qoc2VsZi5j
dHgsIHJ1bGVbImlmYiJdKQogICAgICAgICAgICAgICAgICBmb3IgcnVsZV9pZCwgcnVsZSBpbiBv
bGRbInJ1bGVzIl0uaXRlbXMoKSBpZiBsaXZlWyJsaW5rcyJdLmdldChydWxlWyJpZmIiXSl9CiAg
ICAgICAgY3JlYXRlZF9kZXZpY2VzLCBjcmVhdGVkX2Nsc2FjdCwgYWRkZWRfZmlsdGVycywgcmVt
b3ZlZF9maWx0ZXJzLCByZW1vdmVkX2RldmljZXMgPSBbXSwgW10sIFtdLCBbXSwgW10KICAgICAg
ICB0YWJsZV9jaGFuZ2VkID0gRmFsc2UKICAgICAgICBvd25lZF9jbHNhY3QgPSBzZXQob2xkLmdl
dCgiY2xzYWN0X293bmVkIiwgW10pKQogICAgICAgIHRyeToKICAgICAgICAgICAgZm9yIHJ1bGVf
aWQsIHJ1bGUgaW4gZGVzaXJlZC5pdGVtcygpOgogICAgICAgICAgICAgICAgaW50ZXJmYWNlLCBk
ZXZpY2UgPSBydWxlWyJpbnRlcmZhY2UiXSwgcnVsZVsiaWZiIl0KICAgICAgICAgICAgICAgIG10
dSA9IGxpdmVbImxpbmtzIl1baW50ZXJmYWNlXVsibXR1Il0KICAgICAgICAgICAgICAgIGlmIG5v
dCBsaXZlWyJsaW5rcyJdLmdldChkZXZpY2UpOgogICAgICAgICAgICAgICAgICAgIHNlbGYuY3R4
Lm11dGF0ZShbImlwIiwgImxpbmsiLCAiYWRkIiwgIm5hbWUiLCBkZXZpY2UsICJ0eXBlIiwgImlm
YiJdKQogICAgICAgICAgICAgICAgICAgIGNyZWF0ZWRfZGV2aWNlcy5hcHBlbmQoZGV2aWNlKQog
ICAgICAgICAgICAgICAgICAgIHNlbGYuY3R4Lm11dGF0ZShbImlwIiwgImxpbmsiLCAic2V0Iiwg
ImRldiIsIGRldmljZSwgImFsaWFzIiwgX2FsaWFzKHJ1bGVfaWQpXSkKICAgICAgICAgICAgICAg
IGlmIG5vdCBsaXZlWyJsaW5rcyJdLmdldChkZXZpY2UpIG9yIGxpdmVbImxpbmtzIl1bZGV2aWNl
XS5nZXQoIm10dSIpICE9IG10dToKICAgICAgICAgICAgICAgICAgICBzZWxmLmN0eC5tdXRhdGUo
WyJpcCIsICJsaW5rIiwgInNldCIsICJkZXYiLCBkZXZpY2UsICJtdHUiLCBzdHIobXR1KV0pCiAg
ICAgICAgICAgICAgICBpZiBub3QgbGl2ZVsibGlua3MiXS5nZXQoZGV2aWNlKSBvciAiVVAiIG5v
dCBpbiBsaXZlWyJsaW5rcyJdW2RldmljZV0uZ2V0KCJmbGFncyIsIFtdKToKICAgICAgICAgICAg
ICAgICAgICBzZWxmLmN0eC5tdXRhdGUoWyJpcCIsICJsaW5rIiwgInNldCIsICJkZXYiLCBkZXZp
Y2UsICJ1cCJdKQogICAgICAgICAgICAgICAgYXBwbHlfcHJvZmlsZShzZWxmLmN0eCwgZGV2aWNl
LCBydWxlWyJwcm9maWxlIl0sIGhhbmRsZT0iYTIwMDoiKQogICAgICAgICAgICAgICAgaWYgbm90
IGxpdmVbImNsc2FjdCJdW2ludGVyZmFjZV06CiAgICAgICAgICAgICAgICAgICAgc2VsZi5jdHgu
bXV0YXRlKFsidGMiLCAicWRpc2MiLCAiYWRkIiwgImRldiIsIGludGVyZmFjZSwgImNsc2FjdCJd
KQogICAgICAgICAgICAgICAgICAgIGxpdmVbImNsc2FjdCJdW2ludGVyZmFjZV0gPSBUcnVlCiAg
ICAgICAgICAgICAgICAgICAgY3JlYXRlZF9jbHNhY3QuYXBwZW5kKGludGVyZmFjZSkKICAgICAg
ICAgICAgICAgICAgICBvd25lZF9jbHNhY3QuYWRkKGludGVyZmFjZSkKICAgICAgICAgICAgIyBL
ZWVwIHVuY2hhbmdlZCBmaWx0ZXJzIGluIHBsYWNlLCBpbmNsdWRpbmcgdGhlaXIgY291bnRlcnMu
CiAgICAgICAgICAgIGZvciBydWxlX2lkLCBwcmV2aW91cyBpbiBvbGRbInJ1bGVzIl0uaXRlbXMo
KToKICAgICAgICAgICAgICAgIHJlcGxhY2VtZW50ID0gZGVzaXJlZC5nZXQocnVsZV9pZCkKICAg
ICAgICAgICAgICAgIGlmIHJlcGxhY2VtZW50IGlzIE5vbmUgb3IgcmVwbGFjZW1lbnRbImludGVy
ZmFjZSJdICE9IHByZXZpb3VzWyJpbnRlcmZhY2UiXToKICAgICAgICAgICAgICAgICAgICBhY3R1
YWwgPSBsaXZlWyJmaWx0ZXJzIl1bcHJldmlvdXNbImludGVyZmFjZSJdXQogICAgICAgICAgICAg
ICAgICAgIGlmIGFueShpdGVtLmdldCgicHJlZiIpID09IFBSRUZfQkFTRSArIHByZXZpb3VzWyJz
bG90Il0gZm9yIGl0ZW0gaW4gYWN0dWFsKToKICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5f
ZGVsZXRlX2ZpbHRlcihwcmV2aW91cykKICAgICAgICAgICAgICAgICAgICAgICAgcmVtb3ZlZF9m
aWx0ZXJzLmFwcGVuZChwcmV2aW91cykKICAgICAgICAgICAgZm9yIHJ1bGVfaWQsIHJ1bGUgaW4g
ZGVzaXJlZC5pdGVtcygpOgogICAgICAgICAgICAgICAgcHJldmlvdXMgPSBvbGRbInJ1bGVzIl0u
Z2V0KHJ1bGVfaWQpCiAgICAgICAgICAgICAgICBhY3R1YWwgPSBsaXZlWyJmaWx0ZXJzIl1bcnVs
ZVsiaW50ZXJmYWNlIl1dCiAgICAgICAgICAgICAgICBwcmVzZW50ID0gcHJldmlvdXMgYW5kIHBy
ZXZpb3VzWyJpbnRlcmZhY2UiXSA9PSBydWxlWyJpbnRlcmZhY2UiXSBhbmQgYW55KAogICAgICAg
ICAgICAgICAgICAgIGl0ZW0uZ2V0KCJwcmVmIikgPT0gUFJFRl9CQVNFICsgcnVsZVsic2xvdCJd
IGZvciBpdGVtIGluIGFjdHVhbCkKICAgICAgICAgICAgICAgIGlmIG5vdCBwcmVzZW50OgogICAg
ICAgICAgICAgICAgICAgIHNlbGYuX2FkZF9maWx0ZXIocnVsZSkKICAgICAgICAgICAgICAgICAg
ICBhZGRlZF9maWx0ZXJzLmFwcGVuZChydWxlKQogICAgICAgICAgICAgICAgYWN0dWFsID0gc2Vs
Zi5fZmlsdGVycyhydWxlWyJpbnRlcmZhY2UiXSkKICAgICAgICAgICAgICAgIG1hdGNoaW5nID0g
W2l0ZW0gZm9yIGl0ZW0gaW4gYWN0dWFsIGlmIGl0ZW0uZ2V0KCJwcmVmIikgPT0gUFJFRl9CQVNF
ICsgcnVsZVsic2xvdCJdXQogICAgICAgICAgICAgICAgaWYgbm90IG1hdGNoaW5nOgogICAgICAg
ICAgICAgICAgICAgIHJhaXNlIFR1bmVFcnJvcigi5paw5aKe56uv5Y+j5YiG57G75Zmo5pyq55Sf
5pWIIiwgMjApCiAgICAgICAgICAgICAgICBydWxlWyJmaWx0ZXJfZmluZ2VycHJpbnQiXSA9IF9m
aW5nZXJwcmludChtYXRjaGluZykKICAgICAgICAgICAgaWYgbm90IGxpdmVbInRhYmxlIl0gb3Ig
bm90IGFsbChydWxlX2lkIGluIG9sZFsicnVsZXMiXSBhbmQgX3NhbWVfcnVsZShvbGRbInJ1bGVz
Il1bcnVsZV9pZF0sIHJ1bGUpCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgICBmb3IgcnVsZV9pZCwgcnVsZSBpbiBkZXNpcmVkLml0ZW1zKCkpIG9yIHNldChkZXNp
cmVkKSAhPSBzZXQob2xkWyJydWxlcyJdKToKICAgICAgICAgICAgICAgIHNlbGYuX3dyaXRlX3Rh
YmxlKGRlc2lyZWQsIGJvb2wobGl2ZVsidGFibGUiXSkpCiAgICAgICAgICAgICAgICB0YWJsZV9j
aGFuZ2VkID0gVHJ1ZQogICAgICAgICAgICBmb3IgcnVsZV9pZCwgcHJldmlvdXMgaW4gb2xkWyJy
dWxlcyJdLml0ZW1zKCk6CiAgICAgICAgICAgICAgICBpZiBydWxlX2lkIG5vdCBpbiBkZXNpcmVk
IGFuZCBsaXZlWyJsaW5rcyJdLmdldChwcmV2aW91c1siaWZiIl0pOgogICAgICAgICAgICAgICAg
ICAgIHNlbGYuY3R4Lm11dGF0ZShbImlwIiwgImxpbmsiLCAiZGVsIiwgImRldiIsIHByZXZpb3Vz
WyJpZmIiXV0pCiAgICAgICAgICAgICAgICAgICAgcmVtb3ZlZF9kZXZpY2VzLmFwcGVuZChwcmV2
aW91cykKICAgICAgICAgICAgbmVlZGVkID0ge3J1bGVbImludGVyZmFjZSJdIGZvciBydWxlIGlu
IGRlc2lyZWQudmFsdWVzKCl9CiAgICAgICAgICAgIGZvciBpbnRlcmZhY2UgaW4gc29ydGVkKG93
bmVkX2Nsc2FjdCAtIG5lZWRlZCk6CiAgICAgICAgICAgICAgICAjIE5ldmVyIHJlbW92ZSBhIGNs
c2FjdCB0aGF0IGdhaW5lZCBmb3JlaWduIGluZ3Jlc3MvZWdyZXNzIGZpbHRlcnMuCiAgICAgICAg
ICAgICAgICBpbmdyZXNzID0gc2VsZi5fanNvbihbInRjIiwgIi1qIiwgImZpbHRlciIsICJzaG93
IiwgImRldiIsIGludGVyZmFjZSwgImluZ3Jlc3MiXSkKICAgICAgICAgICAgICAgIGVncmVzcyA9
IHNlbGYuX2ZpbHRlcnMoaW50ZXJmYWNlKQogICAgICAgICAgICAgICAgaWYgbm90IGluZ3Jlc3Mg
YW5kIG5vdCBlZ3Jlc3M6CiAgICAgICAgICAgICAgICAgICAgc2VsZi5jdHgubXV0YXRlKFsidGMi
LCAicWRpc2MiLCAiZGVsIiwgImRldiIsIGludGVyZmFjZSwgImNsc2FjdCJdKQogICAgICAgICAg
ICAgICAgb3duZWRfY2xzYWN0LmRpc2NhcmQoaW50ZXJmYWNlKQogICAgICAgICAgICBuZXcgPSB7
InNjaGVtYV92ZXJzaW9uIjogMSwgInJ1bGVzIjogZGVzaXJlZCwgImNsc2FjdF9vd25lZCI6IHNv
cnRlZChvd25lZF9jbHNhY3QpfQogICAgICAgICAgICB0YWJsZSA9IHNlbGYuX3RhYmxlKHNlbGYu
X2pzb24oWyJuZnQiLCAiLWoiLCAibGlzdCIsICJydWxlc2V0Il0pKQogICAgICAgICAgICBpZiBi
b29sKHRhYmxlKSAhPSBib29sKGRlc2lyZWQpOgogICAgICAgICAgICAgICAgcmFpc2UgVHVuZUVy
cm9yKCLnq6/lj6PliIbnsbsgbmZ0IOihqOacqueUn+aViCIsIDIwKQogICAgICAgICAgICBuZXdb
Im5mdF9maW5nZXJwcmludCJdID0gX2ZpbmdlcnByaW50KHRhYmxlLCBuZnQ9VHJ1ZSkgaWYgdGFi
bGUgZWxzZSBOb25lCiAgICAgICAgICAgIHNlbGYuY3R4LndyaXRlX2pzb24oc2VsZi5zdGF0ZV9w
YXRoLCBuZXcpCiAgICAgICAgICAgIGlmIGRlc2lyZWQ6CiAgICAgICAgICAgICAgICBzZWxmLmN0
eC5pbnN0YWxsX3J1bnRpbWUoKQogICAgICAgICAgICAgICAgc2VsZi5jdHgud3JpdGVfdW5pdChV
TklULCAiIyAiICsgT1dORVIgKyAiXG5bVW5pdF1cbkRlc2NyaXB0aW9uPVZQUyBzZXJ2aWNlIHBv
cnQgc2hhcGluZ1xuIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiQWZ0ZXI9
bmV0d29yay1vbmxpbmUudGFyZ2V0XG5XYW50cz1uZXR3b3JrLW9ubGluZS50YXJnZXRcblxuW1Nl
cnZpY2VdXG4iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICJUeXBlPW9uZXNo
b3RcblJlbWFpbkFmdGVyRXhpdD15ZXNcbiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg
ICAgICAgIkV4ZWNTdGFydD0vdXNyL2Jpbi9weXRob24zIC91c3IvbG9jYWwvbGliL3Zwc2N0bC9u
ZXR3b3JrLXR1bmUvcnVudGltZS5weXogaW50ZXJuYWwgcG9ydHMtYXBwbHlcblxuIgogICAgICAg
ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiW0luc3RhbGxdXG5XYW50ZWRCeT1tdWx0aS11
c2VyLnRhcmdldFxuIikKICAgICAgICAgICAgICAgIHNlbGYuY3R4LnN5c3RlbWN0bCgiZW5hYmxl
IiwgVU5JVCkKICAgICAgICAgICAgZWxpZiBzYXZlZF91bml0WyJleGlzdHMiXToKICAgICAgICAg
ICAgICAgIHNlbGYuY3R4LnN5c3RlbWN0bCgiZGlzYWJsZSIsICItLW5vdyIsIFVOSVQpCiAgICAg
ICAgICAgICAgICBzZWxmLmN0eC5yZW1vdmVfZmlsZShzZWxmLmN0eC51bml0X3BhdGgoVU5JVCkp
CiAgICAgICAgICAgICAgICBzZWxmLmN0eC5zeXN0ZW1jdGwoImRhZW1vbi1yZWxvYWQiKQogICAg
ICAgICAgICByZXR1cm4geyJmZWF0dXJlIjogInBvcnRzIiwgImNoYW5nZWQiOiBUcnVlLCAicnVs
ZXMiOiBkZXNpcmVkLCAiYm9vdCI6IGJvb3R9CiAgICAgICAgZXhjZXB0IEJhc2VFeGNlcHRpb24g
YXMgZXJyb3I6CiAgICAgICAgICAgIGZhaWx1cmVzID0gW10KICAgICAgICAgICAgZGVmIHVuZG8o
b3BlcmF0aW9uKToKICAgICAgICAgICAgICAgIHRyeToKICAgICAgICAgICAgICAgICAgICBvcGVy
YXRpb24oKQogICAgICAgICAgICAgICAgZXhjZXB0IEJhc2VFeGNlcHRpb24gYXMgZmFpbHVyZToK
ICAgICAgICAgICAgICAgICAgICBmYWlsdXJlcy5hcHBlbmQoc3RyKGZhaWx1cmUpKQogICAgICAg
ICAgICBmb3IgcnVsZSBpbiByZXZlcnNlZChhZGRlZF9maWx0ZXJzKToKICAgICAgICAgICAgICAg
IHVuZG8obGFtYmRhIHJ1bGU9cnVsZTogc2VsZi5fZGVsZXRlX2ZpbHRlcihydWxlKSkKICAgICAg
ICAgICAgZm9yIHByZXZpb3VzIGluIHJlbW92ZWRfZGV2aWNlczoKICAgICAgICAgICAgICAgIHVu
ZG8obGFtYmRhIHByZXZpb3VzPXByZXZpb3VzOiBzZWxmLmN0eC5tdXRhdGUoWyJpcCIsICJsaW5r
IiwgImFkZCIsICJuYW1lIiwgcHJldmlvdXNbImlmYiJdLCAidHlwZSIsICJpZmIiXSkpCiAgICAg
ICAgICAgICAgICB1bmRvKGxhbWJkYSBwcmV2aW91cz1wcmV2aW91czogc2VsZi5jdHgubXV0YXRl
KFsiaXAiLCAibGluayIsICJzZXQiLCAiZGV2IiwgcHJldmlvdXNbImlmYiJdLCAiYWxpYXMiLCBf
YWxpYXMocHJldmlvdXNbImlkIl0pXSkpCiAgICAgICAgICAgICAgICB1bmRvKGxhbWJkYSBwcmV2
aW91cz1wcmV2aW91czogc2VsZi5jdHgubXV0YXRlKFsiaXAiLCAibGluayIsICJzZXQiLCAiZGV2
IiwgcHJldmlvdXNbImlmYiJdLCAibXR1Iiwgc3RyKGxpdmVbImxpbmtzIl1bcHJldmlvdXNbImlm
YiJdXVsibXR1Il0pLCAidXAiXSkpCiAgICAgICAgICAgIGZvciBydWxlX2lkLCBzbmFwc2hvdCBp
biBiZWZvcmUuaXRlbXMoKToKICAgICAgICAgICAgICAgIGRldmljZSA9IG9sZFsicnVsZXMiXVty
dWxlX2lkXVsiaWZiIl0KICAgICAgICAgICAgICAgIGxpbmsgPSBsaXZlWyJsaW5rcyJdW2Rldmlj
ZV0KICAgICAgICAgICAgICAgIHVuZG8obGFtYmRhIGRldmljZT1kZXZpY2UsIGxpbms9bGluazog
c2VsZi5jdHgubXV0YXRlKFsiaXAiLCAibGluayIsICJzZXQiLCAiZGV2IiwgZGV2aWNlLAogICAg
ICAgICAgICAgICAgICAgICAibXR1Iiwgc3RyKGxpbmtbIm10dSJdKSwgInVwIiBpZiAiVVAiIGlu
IGxpbmsuZ2V0KCJmbGFncyIsIFtdKSBlbHNlICJkb3duIl0pKQogICAgICAgICAgICAgICAgdW5k
byhsYW1iZGEgcnVsZV9pZD1ydWxlX2lkLCBzbmFwc2hvdD1zbmFwc2hvdDogcmVzdG9yZV9zbmFw
c2hvdChzZWxmLmN0eCwgb2xkWyJydWxlcyJdW3J1bGVfaWRdWyJpZmIiXSwgc25hcHNob3QpKQog
ICAgICAgICAgICBmb3IgcHJldmlvdXMgaW4gcmVtb3ZlZF9maWx0ZXJzOgogICAgICAgICAgICAg
ICAgaW50ZXJmYWNlID0gcHJldmlvdXNbImludGVyZmFjZSJdCiAgICAgICAgICAgICAgICBxdWV1
ZXMgPSBOb25lCiAgICAgICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICAgICAgcXVldWVz
ID0gc2VsZi5fanNvbihbInRjIiwgIi1qIiwgInFkaXNjIiwgInNob3ciLCAiZGV2IiwgaW50ZXJm
YWNlXSkKICAgICAgICAgICAgICAgIGV4Y2VwdCBCYXNlRXhjZXB0aW9uIGFzIGZhaWx1cmU6CiAg
ICAgICAgICAgICAgICAgICAgZmFpbHVyZXMuYXBwZW5kKHN0cihmYWlsdXJlKSkKICAgICAgICAg
ICAgICAgIGlmIHF1ZXVlcyBpcyBub3QgTm9uZSBhbmQgbm90IGFueShxdWV1ZS5nZXQoImtpbmQi
KSA9PSAiY2xzYWN0IiBmb3IgcXVldWUgaW4gcXVldWVzKToKICAgICAgICAgICAgICAgICAgICB1
bmRvKGxhbWJkYSBpbnRlcmZhY2U9aW50ZXJmYWNlOiBzZWxmLmN0eC5tdXRhdGUoWyJ0YyIsICJx
ZGlzYyIsICJhZGQiLCAiZGV2IiwgaW50ZXJmYWNlLCAiY2xzYWN0Il0pKQogICAgICAgICAgICAg
ICAgdW5kbyhsYW1iZGEgcHJldmlvdXM9cHJldmlvdXM6IHNlbGYuX2FkZF9maWx0ZXIocHJldmlv
dXMpKQogICAgICAgICAgICBpZiB0YWJsZV9jaGFuZ2VkOgogICAgICAgICAgICAgICAgdW5kbyhs
YW1iZGE6IHNlbGYuX3dyaXRlX3RhYmxlKG9sZFsicnVsZXMiXSBpZiBsaXZlWyJ0YWJsZSJdIGVs
c2Uge30sIGJvb2woZGVzaXJlZCkpKQogICAgICAgICAgICBmb3IgZGV2aWNlIGluIHJldmVyc2Vk
KGNyZWF0ZWRfZGV2aWNlcyk6CiAgICAgICAgICAgICAgICB1bmRvKGxhbWJkYSBkZXZpY2U9ZGV2
aWNlOiBzZWxmLmN0eC5tdXRhdGUoWyJpcCIsICJsaW5rIiwgImRlbCIsICJkZXYiLCBkZXZpY2Vd
KSkKICAgICAgICAgICAgZm9yIGludGVyZmFjZSBpbiByZXZlcnNlZChjcmVhdGVkX2Nsc2FjdCk6
CiAgICAgICAgICAgICAgICBkZWYgcmVtb3ZlX2NyZWF0ZWRfY2xzYWN0KGludGVyZmFjZT1pbnRl
cmZhY2UpOgogICAgICAgICAgICAgICAgICAgIGluZ3Jlc3MgPSBzZWxmLl9qc29uKFsidGMiLCAi
LWoiLCAiZmlsdGVyIiwgInNob3ciLCAiZGV2IiwgaW50ZXJmYWNlLCAiaW5ncmVzcyJdKQogICAg
ICAgICAgICAgICAgICAgIGlmIGluZ3Jlc3Mgb3Igc2VsZi5fZmlsdGVycyhpbnRlcmZhY2UpOgog
ICAgICAgICAgICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuWbnua7muS/neeVmeaWsOWi
nueahOWklumDqCBjbHNhY3Qg5YiG57G75Zmo77yaIiArIGludGVyZmFjZSkKICAgICAgICAgICAg
ICAgICAgICBzZWxmLmN0eC5tdXRhdGUoWyJ0YyIsICJxZGlzYyIsICJkZWwiLCAiZGV2IiwgaW50
ZXJmYWNlLCAiY2xzYWN0Il0pCiAgICAgICAgICAgICAgICB1bmRvKHJlbW92ZV9jcmVhdGVkX2Ns
c2FjdCkKICAgICAgICAgICAgdW5kbyhsYW1iZGE6IHNlbGYuY3R4LnJlc3RvcmVfZmlsZShzZWxm
LnN0YXRlX3BhdGgsIHNhdmVkX3N0YXRlKSkKICAgICAgICAgICAgdW5kbyhsYW1iZGE6IHNlbGYu
Y3R4LnJlc3RvcmVfdW5pdChVTklULCBzYXZlZF91bml0KSkKICAgICAgICAgICAgaWYgZmFpbHVy
ZXM6CiAgICAgICAgICAgICAgICByYWlzZSBUdW5lRXJyb3IoIuerr+WPo+mZkOmAn+Wksei0peS4
lOWbnua7muS4jeWujOaVtO+8miIgKyBzdHIoZXJyb3IpICsgIu+8myIgKyAi77ybIi5qb2luKGZh
aWx1cmVzKSwgMzApIGZyb20gZXJyb3IKICAgICAgICAgICAgcmFpc2UKUEsBAhQDFAAAAAAAAAAh
UCNV7Gc7AAAAOwAAAAsAAAAAAAAAAAAAAKSBAAAAAF9fbWFpbl9fLnB5UEsBAhQDFAAAAAAAAAAh
UBbWcHhJAAAASQAAABgAAAAAAAAAAAAAAKSBZAAAAG5ldHdvcmtfdHVuZS9fX2luaXRfXy5weVBL
AQIUAxQAAAAAAAAAIVB21sPqOwEAADsBAAAYAAAAAAAAAAAAAACkgeMAAABuZXR3b3JrX3R1bmUv
X19tYWluX18ucHlQSwECFAMUAAAAAAAAACFQYnzqQ3paAAB6WgAAFwAAAAAAAAAAAAAApIFUAgAA
bmV0d29ya190dW5lL2J1ZmZlcnMucHlQSwECFAMUAAAAAAAAACFQK2cc4Np3AADadwAAEwAAAAAA
AAAAAAAApIEDXQAAbmV0d29ya190dW5lL2NsaS5weVBLAQIUAxQAAAAAAAAAIVAwVw+NSUQAAElE
AAAWAAAAAAAAAAAAAACkgQ7VAABuZXR3b3JrX3R1bmUvY29tbW9uLnB5UEsBAhQDFAAAAAAAAAAh
UAUsE2bzkQAA85EAABYAAAAAAAAAAAAAAKSBixkBAG5ldHdvcmtfdHVuZS9lZ3Jlc3MucHlQSwEC
FAMUAAAAAAAAACFQQEZnxyODAAAjgwAAFQAAAAAAAAAAAAAApIGyqwEAbmV0d29ya190dW5lL3Bv
cnRzLnB5UEsFBgAAAAAIAAgAFgIAAAgvAgApAE1hbmFnZWQgYnkgdnBzY3RsIG5ldHdvcmsgdHVu
ZSBydW50aW1lIHYx
PO0_NETWORK_TUNE_PAYLOAD
}

po0_tune() (
    local work script_dir skip_dependencies=0 PO0_TUNE_DEPENDENCIES_PLANNED=0
    local dry_run=${VPSCTL_DRY_RUN:-0} install_deps=${VPSCTL_INSTALL_DEPS:-0} non_interactive=${VPSCTL_NON_INTERACTIVE:-0}
    local -a arguments=() action=() dep_options=() tools=()
    # The Python CLI accepts common flags at every parser level.
    while (($#)); do
        case $1 in
            --dry-run) dry_run=1 ;;
            --install-deps) install_deps=1 ;;
            --non-interactive) non_interactive=1 ;;
            --yes | --quiet | --verbose | --no-color | --json) ;;
            --help | -h) skip_dependencies=1 ;;
            --)
                if ((${#action[@]} == 0)); then shift; fi
                break
                ;;
            -*) if ((${#action[@]} < 2)); then skip_dependencies=1; fi ;;
            *) if ((${#action[@]} < 2)); then action+=("$1"); fi ;;
        esac
        arguments+=("$1")
        shift
    done
    case "${dry_run,,}" in 1 | true | yes | on) dep_options+=(--dry-run); dry_run=1 ;; esac
    case "${install_deps,,}" in 1 | true | yes | on) dep_options+=(--install-deps) ;; esac
    case "${non_interactive,,}" in 1 | true | yes | on) dep_options+=(--non-interactive) ;; esac
    case "${action[0]:-}:${action[1]:-}" in
        buffer:set | buffer:restore) tools=(python3 sysctl) ;;
        egress:set | egress:clear | egress:restore | egress:adopt) tools=(python3 ip tc systemctl) ;;
        port:set | port:delete) tools=(python3 ip tc nft systemctl) ;;
    esac
    if [[ $skip_dependencies == 0 ]] && ((${#tools[@]})) &&
        [[ $dry_run == 1 || ($EUID == 0 && -d /run/systemd/system && -r /etc/debian_version) ]]; then
        po0_require_tools "${dep_options[@]}" "${tools[@]}" || return $?
        [[ $PO0_TUNE_DEPENDENCIES_PLANNED == 0 ]] || return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        po0_error '网络调优需要 python3，请安装后重试。'
        return 3
    fi

    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 20
    export VPSCTL_TUNE_FRONTEND_PATH="$script_dir/${BASH_SOURCE[0]##*/}"
    export VPSCTL_TUNE_FRONTEND_KIND=po0
    work=$(mktemp -d -- "${TMPDIR:-/tmp}/po0-network-tune.XXXXXXXX") || return 20
    trap 'rm -f -- "$work/runtime.pyz"; rmdir -- "$work"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    if ! po0_tune_archive >"$work/runtime.pyz" || [[ ! -s $work/runtime.pyz ]]; then
        po0_error '无法解包内置网络调优运行时。'
        return 20
    fi
    python3 -I -B "$work/runtime.pyz" "${arguments[@]}" "$@"
)

po0_help() {
    cat <<'EOF'
PO0 IPv4 中转管理（独立单文件，Ubuntu 22.04/24.04、Debian + systemd + nftables）

用法:
  sudo bash po0-relay.sh            终端交互菜单
  sudo bash po0-relay.sh --status   只读查看，不安装依赖或改写配置
  bash po0-relay.sh --help          本帮助
  bash po0-relay.sh tune --help     网络调优命令帮助

菜单按线路管理、状态与维护、全局设置分组；每项独占一行。
新增可直接输入节点 URI 或手填目标 IPv4；名称默认沿用 URI 备注。
支持 VLESS、VMess（Base64 JSON）、Trojan、SS、HY2/Hysteria2、TUIC、AnyTLS。
查看线路显示完整中转 URI，使用保存的公网 IPv4 和入站端口；区间取起始端口。
首次添加 URI 探测公网 IPv4（最多 5 秒），可手动更正；菜单 9 可修改或重探。
URI 功能按需使用 python3 标准库，不需要仓库模块、代理内核或第三方 Python 包。
输入 :q 可取消；确认默认否。端口可为单个或范围，统一映射到固定目标端口。
协议用编号选择，默认 TCP+UDP（HY2/TUIC 默认 UDP）；入站留空生成并检查随机端口。
URI 目标支持域名，导入/替换或菜单 7 时解析 IPv4；查看不联网，不后台刷新。
HY2 跳跃端口选一个固定目标，导出移除 mport；保留凭据、SNI、Host 和其他参数。
公网端口须与入站端口一致；线路管理使用 IPv4 和交互菜单。

状态: /etc/po0-relay/state.tsv（版本化纯 TSV，不作为 Shell 执行）
旧版: 完整识别原始 /etc/nftables.conf，查看不落盘；首次确认变更时迁移。
仅管理 po0_relay_filter、po0_relay_nat、po0_relay_mangle，其他表保留；从不全局 flush 或重启 nftables。
规则: /etc/po0-relay/rules.nft，由 po0-relay.service 开机加载。
安装统一 nft 管理器后移交访问控制，仅保留 NAT/MSS；停用统一防火墙不会恢复 PO0 默认丢弃。
INPUT/FORWARD 默认丢弃，保留本机发现的 SSH TCP 端口和原 22、MSS 1452。
转发管理设置 ip_forward=1，保留旧调优；菜单 8 可单独开启 BBR+FQ 并保存开机配置。
BBR 用于本机新建 TCP 连接；FQ 设置为默认队列，现有网卡队列保持当前配置。
BBR/FQ 保存到 /etc/sysctl.d/99-po0-relay-bbr.conf 和同名 modules-load.d 文件。
菜单 10 进入网络调优，可调整 TCP 缓冲、网卡出口队列和静态端口限速。
独立 tune 子命令支持 --dry-run、--yes 和 --non-interactive；运行时随本文件提供。
禁止接管未知 nft 配置/同名表；缺少依赖时在需要时明确询问安装。
禁用/删除/修改影响新连接，已有连接由 conntrack 自然过期。

注意: 更改防火墙可能影响 SSH，请保留当前 SSH 会话及服务商 root 控制台。
线路修改先 nft -c 校验并保留备份，失败或 HUP/INT/TERM 自动回滚。
线路备份: /etc/po0-relay/backups/<UTC时间.随机串>/
线路恢复: 在 root 控制台执行 bash /etc/po0-relay/backups/<对应目录>/recover.sh
恢复只替换原三张表，并恢复旧文件、ip_forward 和服务开机启用状态。
BBR/FQ 的原参数和文件单独备份到 backups/bbr-*，失败自动恢复。
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
    if [[ ${1-} == tune ]]; then
        shift
        po0_tune "$@"
        return $?
    fi
    if [[ $# -gt 1 || ($# == 1 && $1 != --status) ]]; then
        po0_error '只支持 --help、--status、tune 或无参数菜单。'
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
        po0_menu
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
            8) po0_enable_bbr || status=$? ;;
            9) po0_action_public_ip || status=$? ;;
            10) po0_tune || status=$? ;;
            0) return 0 ;;
            *)
                po0_error '请选择菜单中的编号。'
                continue
                ;;
        esac
        if [[ $status == 130 ]]; then
            po0_message 33 '已取消。'
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
