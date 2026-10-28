#!/usr/bin/env bash
# Focused standalone PO0 contract checks. Run only on host-vps-scripts.
# shellcheck disable=SC2034,SC2317 # Globals and commit hooks are used by sourced code.
# shellcheck disable=SC2030,SC2031 # Independent scenarios reload state; subshell changes are intentionally isolated.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="${PO0_UNIT_TMP:-$(mktemp -d)}"
mkdir -p "$TMP"
if [[ -z ${PO0_UNIT_TMP:-} ]]; then trap 'rm -rf -- "$TMP"' EXIT; fi
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
ok() { printf 'PASS: %s\n' "$*"; }
equal() { [[ "$1" == "$2" ]] || fail "$3: expected <$1>, got <$2>"; }
declare -A PO0_NAME PO0_ENABLED PO0_PROTO PO0_PORT PO0_DEST_IP PO0_DEST_PORT
# shellcheck source=/dev/null
source "$ROOT/scripts/po0-relay.sh"

# Compare semantic endpoints and preserved client parameters, rather than an
# implementation-specific serialization or Base64 alphabet.
python3 - "$ROOT/scripts/po0-relay.sh" "$TMP" <<'PY'
import base64, json, os, pathlib, subprocess, sys, urllib.parse
script, tmp = sys.argv[1:]
def b64(text):
    return base64.urlsafe_b64encode(text.encode()).decode().rstrip('=')
def unb64(text):
    return base64.urlsafe_b64decode(text + '=' * (-len(text) % 4)).decode()
def call(*args, prelude='', good=True):
    p = subprocess.run(['bash', '-c', 'source "$1"; shift; ' + prelude + '\npo0_uri "$@"',
                        'uri-test', script, *args], text=True, capture_output=True, timeout=8)
    if good and p.returncode:
        raise AssertionError(f'{args[0]} unexpectedly failed ({p.returncode}): {p.stderr}')
    if not good and not p.returncode:
        raise AssertionError(f'invalid {args[0]} unexpectedly accepted')
    assert 'SECRET' not in p.stderr and 'PRIVATE' not in p.stderr, 'credentials leaked to stderr'
    return p.stdout.rstrip('\n')
vm = {'v':'2','ps':'东京 节点','add':'origin.example','port':'443','id':'PRIVATE-ID',
      'aid':'0','net':'ws','type':'none','tls':'tls','path':'/tunnel?x=1','custom':'retained'}
vectors = [
    ('vless://PRIVATE-ID@origin.example:443?security=tls&type=ws&path=%2Fa&x=1&x=2#Tokyo%20Node', 'Tokyo Node', 'both'),
    ('vmess://' + b64(json.dumps(vm, ensure_ascii=False)), '东京 节点', 'both'),
    ('trojan://SECRET%3Apass@origin.example:443?sni=cert.example&allowInsecure=0&custom=yes#Trojan', 'Trojan', 'both'),
    ('ss://' + b64('aes-256-gcm:SECRET:pass') + '@origin.example:443/?plugin=v2ray-plugin%3Bhost%3Dcdn.example#SS', 'SS', 'both'),
    ('ss://' + b64('aes-256-gcm:SECRET:pass@origin.example:443') + '#Legacy', 'Legacy', 'both'),
    ('ss://aes-256-gcm:SECRET%3Apass@origin.example:443?plugin=obfs-local%3Bobfs%3Dhttp#Plaintext', 'Plaintext', 'both'),
    ('ss://2022-blake3-aes-128-gcm:PRIVATE%2Fkey%2BSECRET%3D@origin.example:443#SS2022', 'SS2022', 'both'),
    ('hysteria2://SECRET@origin.example:443?mport=443,8443-8445&obfs=salamander&obfs-password=PRIVATE#HY2', 'HY2', 'udp'),
    ('hy2://SECRET@origin.example:443?sni=cert.example&insecure=0#Alias', 'Alias', 'udp'),
    ('hy2://SECRET@origin.example:443,8443-8445?obfs=salamander#Native', 'Native', 'udp'),
    ('hysteria2://SECRET@origin.example?obfs=salamander#Default', 'Default', 'udp'),
    ('hy2://SECRET@origin.example:443?%6dport=443,8443-8445&obfs=salamander#Encoded', 'Encoded', 'udp'),
    ('tuic://PRIVATE-ID:SECRET@origin.example:443?congestion_control=bbr&udp_relay_mode=native#TUIC', 'TUIC', 'udp'),
    ('anytls://SECRET@origin.example:443?peer=cert.example&idle_session_check_interval=30#AnyTLS', 'AnyTLS', 'both'),
]
for uri, remark, hint in vectors:
    parsed = call('parse', uri).split('\n')
    assert parsed == ['origin.example', '443', remark, hint], (uri.split(':')[0], parsed)
    rewritten = call('rewrite', uri, '203.0.113.9', '23001')
    endpoint = call('parse', rewritten).split('\n')
    assert endpoint == ['203.0.113.9', '23001', remark, hint], endpoint
    port_only = call('rewrite', uri, '', '8444')
    assert call('parse', port_only).split('\n')[:2] == ['origin.example', '8444']
    if uri.startswith('vmess:'):
        obj = json.loads(unb64(rewritten[8:]))
        for key, value in vm.items():
            if key not in ('add','port'):
                assert obj[key] == value, (key, obj)
        assert obj.get('sni') == 'origin.example', obj
        assert obj.get('host') == 'origin.example', obj
    elif uri.startswith('ss:'):
        old, new = urllib.parse.urlsplit(uri), urllib.parse.urlsplit(rewritten)
        def ss_credentials(value):
            authority = urllib.parse.urlsplit(value).netloc
            if '@' not in authority:
                return unb64(authority).rsplit('@', 1)[0]
            userinfo = authority.rsplit('@', 1)[0]
            return urllib.parse.unquote(userinfo) if ':' in userinfo else unb64(userinfo)
        expected = '2022-blake3-aes-128-gcm:PRIVATE/key+SECRET=' if remark == 'SS2022' else 'aes-256-gcm:SECRET:pass'
        assert ss_credentials(uri) == ss_credentials(rewritten) == expected
        assert old.query == new.query and old.fragment == new.fragment
    else:
        old, new = urllib.parse.urlsplit(uri), urllib.parse.urlsplit(rewritten)
        assert old.username == new.username and old.password == new.password and old.fragment == new.fragment
        oq, nq = urllib.parse.parse_qs(old.query), urllib.parse.parse_qs(new.query)
        for key, value in oq.items():
            if key != 'mport':
                assert nq[key] == value, (key, nq)
        assert 'mport' not in nq, 'export retains HY2 port hopping'
        if old.scheme == 'vless':
            assert nq.get('sni') == ['origin.example'], nq
            assert nq.get('host') == ['origin.example'], nq
        if old.scheme in ('hysteria2', 'tuic', 'anytls') and not any(oq.get(k) for k in ('sni','peer','servername')):
            assert nq.get('sni') == ['origin.example'], nq
    print('PASS: URI parse/rewrite preserves client semantics:', uri.split(':')[0])
for uri in ('vless://PRIVATE@198.51.100.2:443', 'trojan://SECRET@198.51.100.2:443',
            'hy2://SECRET@198.51.100.2:443'):
    assert call('parse', uri).split('\n')[2] == ''
    assert call('resolve', uri).split('\n')[0] == '198.51.100.2'
for uri in ('trojan://SECRET@origin.example:443', 'anytls://SECRET@origin.example:443',
            'vless://PRIVATE@origin.example:443?security=tls&type=grpc',
            'vless://PRIVATE@origin.example:443?security=tls&type=ws&sni=cert.example&host=cdn.example'):
    rewritten = urllib.parse.urlsplit(call('rewrite', uri, '203.0.113.9', '23001'))
    old_query = urllib.parse.parse_qs(urllib.parse.urlsplit(uri).query)
    new_query = urllib.parse.parse_qs(rewritten.query)
    assert new_query.get('sni') == old_query.get('sni', ['origin.example'])
    if 'host' in old_query:
        assert new_query['host'] == old_query['host']
invalid = [
    '', 'https://PRIVATE@origin.example:443', 'vless://PRIVATE@origin.example',
    'trojan://SECRET@origin.example:0', 'trojan://SECRET@origin.example:65536',
    'trojan://SECRET@[2001:db8::1]:443', 'trojan://SECRET@999.2.3.4:443',
    'vmess://broken-PRIVATE', 'ss://broken-PRIVATE',
    'vless://PRIVATE@origin.example:443\nrule\t999',
    'vless://PRIVATE@$(touch /tmp/po0-uri-injection):443',
    'hy2://SECRET@origin.example:443,8443-8445?mport=443,9443-9445',
]
for uri in invalid:
    call('parse', uri, good=False)
for port in ('0','65536','23001-23002','22;id'):
    call('rewrite', vectors[0][0], '203.0.113.9', port, good=False)
call('rewrite', vectors[0][0], '$(id)', '23001', good=False)
print('PASS: URI rejects malformed, unsupported, IPv6, invalid ports and control/injection input')

# Replace only external I/O. The embedded application Python is still executed.
mock = pathlib.Path(tmp, 'uri-network-mock.py')
mock.write_text('''import io, os, socket, sys, urllib.request
sys.argv = sys.argv[1:]
def lookup(host, port, *args, **kwargs):
    if os.environ.get("MOCK_NO_NETWORK"): raise AssertionError("unexpected network in parse/rewrite")
    if host == "missing.example": raise socket.gaierror("fixture DNS failure")
    if host != "origin.example": raise AssertionError("unexpected DNS host")
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, port)) for ip in ("198.51.100.8", "198.51.100.9")]
socket.getaddrinfo = lookup
def urlopen(*args, **kwargs):
    if os.environ.get("MOCK_NO_NETWORK"): raise AssertionError("unexpected network in parse/rewrite")
    if os.environ.get("MOCK_PUBLIC_FAIL"): raise OSError("fixture network failure")
    return io.BytesIO(b"203.0.113.9\\n")
urllib.request.urlopen = urlopen
urllib.request.build_opener = lambda *args, **kwargs: type("FixtureOpener", (), {"open": staticmethod(urlopen)})()
exec(compile(sys.stdin.read(), "<po0-uri>", "exec"))
''')
prelude = 'python3() { command python3 ' + __import__('shlex').quote(str(mock)) + ' "$@"; }'
for uri, _, _ in vectors:
    call('parse', uri, prelude='export MOCK_NO_NETWORK=1\n' + prelude)
    call('rewrite', uri, '203.0.113.9', '23001', prelude='export MOCK_NO_NETWORK=1\n' + prelude)
assert call('resolve', vectors[0][0], prelude=prelude).split('\n')[0] == '198.51.100.8'
assert call('resolve', vectors[0][0], '198.51.100.9', prelude=prelude).split('\n')[0] == '198.51.100.9'
call('resolve', vectors[0][0].replace('origin.example', 'missing.example'), prelude=prelude, good=False)
assert call('public-ip', prelude=prelude) == '203.0.113.9'
call('public-ip', prelude='export MOCK_PUBLIC_FAIL=1\n' + prelude, good=False)
print('PASS: IPv4 DNS selection, preferred current address, failure and public-IP probes')
PY

for value in 1 22 443 65535; do po0_valid_port "$value" || fail "valid port $value"; done
for value in '' 0 65536 -1 1.5 '22;id' '22 23'; do
    if po0_valid_port "$value"; then fail "invalid port accepted: $value"; fi
done
for value in 192.0.2.1 198.51.100.254 1.1.1.1; do po0_valid_ipv4 "$value" || fail "valid IPv4 $value"; done
for value in '' 999.1.1.1 1.2.3 1.2.3.4.5 1.2.3.-1 '1.2.3.4;id'; do
    if po0_valid_ipv4 "$value"; then fail "invalid IPv4 accepted: $value"; fi
done
for value in 1 65535 20000-20002; do po0_valid_port_spec "$value" || fail "valid port spec $value"; done
for value in '' 0 65536 20002-20000 1-65536 1-2-3 '1,2'; do
    if po0_valid_port_spec "$value"; then fail "invalid port spec accepted: $value"; fi
done
po0_valid_name 'HK 转发 1' || fail 'normal Unicode name rejected'
for value in '' $'bad\tname' $'bad\nname'; do
    if po0_valid_name "$value"; then fail 'invalid name accepted'; fi
done
ok 'input validator boundaries'

for fixture in single multiple; do
    file="$ROOT/tests/fixtures/po0-legacy-$fixture.nft"
    before="$(sha256sum "$file")"
    po0_import_legacy "$file" || fail "legacy $fixture import"
    equal "$before" "$(sha256sum "$file")" 'legacy import writes nothing'
    equal wan0 "$PO0_IFACE" 'legacy interface'
    equal 192.0.2.1 "$PO0_RELAY_IP" 'legacy SNAT address'
    equal 22 "${PO0_SSH_PORTS[0]}" 'legacy SSH'
    if [[ "$fixture" == single ]]; then
        equal 1 "${#PO0_IDS[@]}" 'single legacy count'
        equal 默认线路 "${PO0_NAME[${PO0_IDS[0]}]}" 'single Unicode name'
    else
        equal 2 "${#PO0_IDS[@]}" 'multiple legacy count'
        equal HK-T1 "${PO0_NAME[${PO0_IDS[0]}]}" 'first legacy name'
        equal 'JP CO' "${PO0_NAME[${PO0_IDS[1]}]}" 'second legacy name'
    fi
    po0_write_state >"$TMP/state"
    po0_load_state "$TMP/state" || fail 'load serialized state'
    po0_write_state >"$TMP/roundtrip"
    cmp -s "$TMP/state" "$TMP/roundtrip" || fail 'state roundtrip changes data'
    po0_load_state "$TMP/state" || fail 'repeat load'
    po0_write_state >"$TMP/repeat"
    cmp -s "$TMP/state" "$TMP/repeat" || fail 'repeat load duplicates lines'
done
ok 'legacy metadata, names, complete import and stable state roundtrip'
long_name="$(printf '%080d' 0)"
sed "s/HK-T1/$long_name/g" "$ROOT/tests/fixtures/po0-legacy-multiple.nft" >"$TMP/long-name.nft"
po0_import_legacy "$TMP/long-name.nft" || fail 'valid legacy name longer than 64 characters rejected'
equal "$long_name" "${PO0_NAME[${PO0_IDS[0]}]}" 'long legacy name preservation'

cp "$ROOT/tests/fixtures/po0-legacy-multiple.nft" "$TMP/unsafe.nft"
printf '\ninclude "/tmp/arbitrary.nft"\n' >>"$TMP/unsafe.nft"
if po0_import_legacy "$TMP/unsafe.nft"; then fail 'modified legacy template accepted'; fi
printf 'PO0-RELAY\t99\n' >"$TMP/invalid-state"
if po0_load_state "$TMP/invalid-state"; then fail 'unknown state version accepted'; fi
printf 'PO0-RELAY\t1\nmeta\tinterface\twan0\nmeta\trelay_ip\t192.0.2.1\nmeta\tnext_id\t2\nssh\t22\nrule\t1\t1\ttcp\t20001\t198.51.100.2\t443\tfirst\nrule\t1\t1\ttcp\t20002\t198.51.100.3\t8443\tduplicate\n' >"$TMP/invalid-state"
if po0_load_state "$TMP/invalid-state"; then fail 'duplicate stable ID accepted'; fi
ok 'unknown state version, duplicate IDs, and modified legacy refusal'

(
    po0_import_legacy "$ROOT/tests/fixtures/po0-legacy-multiple.nft"
    PO0_PUBLIC_IP=203.0.113.9
    PO0_URI[1]='vless://PRIVATE-ID@198.51.100.2:443?security=tls&sni=cert.example#State'
    po0_write_state >"$TMP/uri-state.tsv"
    grep -Fxq $'PO0-RELAY\t2' "$TMP/uri-state.tsv" || fail 'URI state is not v2'
    po0_load_state "$TMP/uri-state.tsv" || fail 'load v2 URI state'
    equal 203.0.113.9 "$PO0_PUBLIC_IP" 'v2 public address'
    equal 'vless://PRIVATE-ID@198.51.100.2:443?security=tls&sni=cert.example#State' "${PO0_URI[1]}" 'v2 original URI'
    po0_write_state >"$TMP/uri-roundtrip.tsv"
    cmp -s "$TMP/uri-state.tsv" "$TMP/uri-roundtrip.tsv" || fail 'URI v2 roundtrip changes data'
    for record in $'uri\t1\tvless://PRIVATE-ID@198.51.100.2:443' $'uri\t99\tvless://PRIVATE-ID@198.51.100.2:443' $'meta\tpublic_ip\t203.0.113.8' $'meta\tunknown\tvalue' $'unknown\tvalue'; do
        cat "$TMP/uri-state.tsv" >"$TMP/uri-invalid.tsv"
        printf '%s\n' "$record" >>"$TMP/uri-invalid.tsv"
        if po0_load_state "$TMP/uri-invalid.tsv"; then fail 'duplicate, orphan or unknown v2 record accepted'; fi
    done
    # v1 is read compatibly, and the next serialization upgrades to v2.
    sed '/^uri\t/d; /^meta\tpublic_ip\t/d; 1s/2$/1/' "$TMP/uri-state.tsv" >"$TMP/v1-state.tsv"
    po0_load_state "$TMP/v1-state.tsv" || fail 'v1 compatibility'
    equal '' "$PO0_PUBLIC_IP" 'v1 resets previous public address'
    equal '' "${PO0_URI[1]-}" 'v1 resets previous URIs'
    po0_write_state >"$TMP/v1-upgraded.tsv"
    grep -Fxq $'PO0-RELAY\t2' "$TMP/v1-upgraded.tsv" || fail 'v1 is not upgraded on write'
    po0_load_state "$TMP/v1-upgraded.tsv" || fail 'v1 upgraded reload'
    ok 'v1 compatibility and v2 URI/public-IP roundtrip, duplicate/orphan/unknown refusal'
)

po0_import_legacy "$ROOT/tests/fixtures/po0-legacy-multiple.nft"
first="${PO0_IDS[0]}" second="${PO0_IDS[1]}"
PO0_PROTO[$first]=tcp PO0_PROTO[$second]=udp PO0_PORT[$second]="${PO0_PORT[$first]}"
po0_validate_state || fail 'TCP and UDP may share input port'
PO0_PROTO[$second]=tcp
if po0_validate_state; then fail 'same protocol input overlap accepted'; fi
PO0_PORT[$first]=20000-20002 PO0_PORT[$second]=20002-20003
if po0_validate_state; then fail 'range endpoint overlap accepted'; fi
PO0_ENABLED[$second]=0
po0_validate_state || fail 'disabled overlap blocks valid state'
PO0_PORT[$first]=22
if po0_validate_state; then fail 'SSH TCP input accepted'; fi
PO0_PROTO[$first]=udp
po0_validate_state || fail 'UDP SSH-number port rejected'
PO0_DEST_IP[$first]="$PO0_RELAY_IP"
if po0_validate_state; then fail 'relay-address destination loop accepted'; fi
ok 'protocol-specific conflicts, range boundaries, disabled rules and SSH protection'

po0_import_legacy "$ROOT/tests/fixtures/po0-legacy-multiple.nft"
po0_render_config >"$TMP/rendered.nft"
if grep -Eq '^[[:space:]]*flush[[:space:]]+ruleset' "$TMP/rendered.nft"; then fail 'render wipes foreign nft tables'; fi
ok 'rendered persistent configuration uses scoped reset'
cp "$ROOT/scripts/po0-relay.sh" "$TMP/standalone.sh"
help="$(cd "$TMP" && bash ./standalone.sh --help)"
[[ -n "$help" ]] || fail 'public help is empty'
if timeout 3 bash "$TMP/standalone.sh" </dev/null >"$TMP/non-tty.log" 2>&1; then
    fail 'interactive menu accepted non-TTY input'
else
    status=$?
    [[ "$status" != 124 ]] || fail 'non-TTY menu hangs'
fi
ok 'public help and bounded non-TTY menu refusal'

(
    po0_import_legacy "$ROOT/tests/fixtures/po0-legacy-multiple.nft"
    unset SSH_CONNECTION
    ip() { printf '2: wan0 inet 192.0.2.1/24 brd 192.0.2.255 scope global wan0\n'; }
    sshd() { printf 'port 22\n'; }
    ss() {
        case "${2-}" in
            -lntu) printf 'tcp LISTEN 0 128 0.0.0.0:12345 0.0.0.0:*\ntcp LISTEN 0 128 0.0.0.0:2022 0.0.0.0:*\n' ;;
            -lntp) printf 'LISTEN 0 128 0.0.0.0:12345 0.0.0.0:* users:(("systemd",pid=1,fd=5))\nLISTEN 0 128 0.0.0.0:2022 0.0.0.0:* users:(("sshd",pid=55,fd=5))\n' ;;
            *) fail 'unexpected ss query' ;;
        esac
    }
    systemctl() {
        if [[ "${1-}:${2-}:${3-}:${4-}" == show:ssh.socket:--property=Listen:--value ]]; then
            printf '[::]:2222 (Stream)\n'
        fi
    }
    po0_collect_host
    printf '%s\n' "${PO0_SSH_PORTS[@]}" >"$TMP/ssh-ports"
    grep -Fxq 2022 "$TMP/ssh-ports" || fail 'sshd listener not protected'
    grep -Fxq 2222 "$TMP/ssh-ports" || fail 'ssh.socket listener not protected'
    if grep -Fxq 12345 "$TMP/ssh-ports"; then fail 'unrelated systemd socket opened as SSH'; fi
    po0_render_config >"$TMP/socket-firewall.nft"
    if grep -Eq 'tcp dport 12345([^0-9]|$)' "$TMP/socket-firewall.nft"; then fail 'unrelated systemd socket opened in input firewall'; fi
    ok 'SSH daemon/socket ports protected without opening unrelated systemd listeners'
)

# Exercise real prompt/action code; replace only host discovery and the final
# commit so this unit suite cannot change the host firewall or service state.
(
    po0_import_legacy "$ROOT/tests/fixtures/po0-legacy-multiple.nft"
    first="${PO0_IDS[0]}" second="${PO0_IDS[1]}"
    PO0_PROTO[$first]=tcp
    po0_write_state >"$TMP/menu-in.tsv"
    cp "$TMP/menu-in.tsv" "$TMP/menu-original.tsv"
    po0_prepare_change() {
        po0_load_state "$TMP/menu-in.tsv"
        PO0_MODE=managed
        PO0_LOCAL_IPS=(192.0.2.1)
        PO0_LISTEN_TCP=() PO0_LISTEN_UDP=()
    }
    po0_apply() { po0_write_state >"$TMP/menu-out.tsv"; }

    po0_read_value port 'port' 443 <<<$'bad\n0\n8443'
    equal 8443 "$PO0_ANSWER" 'invalid input retries'
    po0_action_add <<<$'invalid-ip\n198.51.100.3\n0\n8443\nUDP split\n20001\n9\n2\ny' >"$TMP/menu-add.log" 2>&1 || fail 'add chooses UDP after entering existing TCP port'
    po0_load_state "$TMP/menu-out.tsv"
    equal 3 "${#PO0_IDS[@]}" 'add count'
    equal udp "${PO0_PROTO[3]}" 'add last protocol choice'
    equal 20001 "${PO0_PORT[3]}" 'add shares TCP port with UDP'
    equal 4 "$PO0_NEXT_ID" 'add advances next stable ID'
    ok 'add flow retries invalid fields and accepts protocol choice after shared port'

    po0_action_add <<<$'198.51.100.3\n443\nDefault protocol\n21001\n\ny' >"$TMP/menu-add-default.log" 2>&1 || fail 'add default protocol'
    po0_load_state "$TMP/menu-out.tsv"
    equal both "${PO0_PROTO[3]}" 'add defaults to both protocols'
    for field in 1 2 3 4 5; do
        po0_action_edit <<<"$first"$'\n'"$field"$'\n\ny' >"$TMP/menu-edit-$field.log" 2>&1 || fail "edit blank default field $field"
        cmp -s "$TMP/menu-original.tsv" "$TMP/menu-out.tsv" || fail "edit blank changes existing field $field"
    done
    ok 'new protocol default and all five edit defaults preserve values'

    po0_prepare_change
    po0_write_state >"$TMP/menu-memory.before"
    for input in ':q' $'198.51.100.3\n443\n:q' $'198.51.100.3\n443\nDeclined\n21001\n3\n'; do
        rm -f "$TMP/menu-out.tsv"
        if po0_action_add <<<"$input" >"$TMP/menu-cancel.log" 2>&1; then fail 'cancelled add succeeds'; else status=$?; fi
        equal 130 "$status" 'cancelled add status'
        [[ ! -e "$TMP/menu-out.tsv" ]] || fail 'cancelled add commits'
        po0_write_state >"$TMP/menu-memory.after"
        cmp -s "$TMP/menu-memory.before" "$TMP/menu-memory.after" || fail 'cancelled add changes memory/next ID'
    done
    for action in edit toggle delete reapply; do
        rm -f "$TMP/menu-out.tsv"
        if "po0_action_$action" <<<':q' >"$TMP/menu-cancel-$action.log" 2>&1; then fail "cancelled $action succeeds"; else status=$?; fi
        equal 130 "$status" "cancelled $action status"
        [[ ! -e "$TMP/menu-out.tsv" ]] || fail "cancelled $action commits"
    done
    ok 'cancel at partial input and default-no confirmation leaves memory and commit untouched'

    po0_action_toggle <<<"$first"$'\ny' >"$TMP/menu-disable.log" 2>&1 || fail 'disable action'
    po0_load_state "$TMP/menu-out.tsv"
    equal 0 "${PO0_ENABLED[$first]}" 'disable state'
    equal 1 "${PO0_ENABLED[$second]}" 'disable preserves other rule'
    cp "$TMP/menu-out.tsv" "$TMP/menu-in.tsv"
    po0_action_toggle <<<"$first"$'\ny' >"$TMP/menu-enable.log" 2>&1 || fail 'enable action'
    cmp -s "$TMP/menu-original.tsv" "$TMP/menu-out.tsv" || fail 'enable restores original state'
    cp "$TMP/menu-original.tsv" "$TMP/menu-in.tsv"
    po0_action_delete <<<"$first"$'\ny' >"$TMP/menu-delete.log" 2>&1 || fail 'delete action'
    po0_load_state "$TMP/menu-out.tsv"
    equal 1 "${#PO0_IDS[@]}" 'delete count'
    equal "$second" "${PO0_IDS[0]}" 'delete preserves surviving stable ID'
    equal 3 "$PO0_NEXT_ID" 'delete does not recycle stable ID'
    ok 'toggle and delete actions commit only the selected stable ID'
)

# Real add/edit/reapply prompt logic with only external discovery and final
# persistence replaced. No firewall, service or host configuration writes.
(
    po0_import_legacy "$ROOT/tests/fixtures/po0-legacy-multiple.nft"
    po0_write_state >"$TMP/uri-menu-in.tsv"
    URI_PUBLIC_PROBE=''
    URI_RESOLVE_FORBIDDEN=0
    eval "$(declare -f po0_uri | sed '1s/po0_uri/po0_uri_real/')"
    po0_uri() {
        case $1 in
            public-ip)
                [[ -n $URI_PUBLIC_PROBE ]] || return 1
                printf '%s\n' "$URI_PUBLIC_PROBE"
                ;;
            resolve)
                if [[ $URI_RESOLVE_FORBIDDEN == 1 ]]; then
                    touch "$TMP/uri-unexpected-resolve"
                    return 1
                fi
                [[ $2 != *missing.example* ]] || return 1
                local -a source_fields
                mapfile -t source_fields < <(po0_uri_real parse "$2")
                [[ ${#source_fields[@]} == 4 ]] || return 1
                [[ ${source_fields[0]} != origin.example ]] || source_fields[0]=198.51.100.9
                printf '%s\n' "${source_fields[@]}"
                ;;
            *) po0_uri_real "$@" ;;
        esac
    }
    po0_prepare_change() {
        po0_load_state "$TMP/uri-menu-in.tsv"
        PO0_MODE=managed PO0_LOCAL_IPS=(192.0.2.1)
        PO0_LISTEN_TCP=() PO0_LISTEN_UDP=()
    }
    po0_apply() { po0_write_state >"$TMP/uri-menu-out.tsv"; }
    source_uri='vless://PRIVATE-ID@198.51.100.2:443?security=tls&sni=cert.example#URI%20Name'
    po0_action_add <<<"$source_uri"$'\n\n23001-23003\n\ninvalid\n203.0.113.9\ny' >"$TMP/uri-menu-add.log" 2>&1 || fail 'URI add with failed public-IP probe and manual fallback'
    po0_load_state "$TMP/uri-menu-out.tsv"
    equal 'URI Name' "${PO0_NAME[3]}" 'URI remark defaults name'
    equal both "${PO0_PROTO[3]}" 'VLESS default both'
    equal "$source_uri" "${PO0_URI[3]}" 'add preserves source URI'
    equal 203.0.113.9 "$PO0_PUBLIC_IP" 'manual public IP persisted'
    share=$(po0_share_uri 3)
    mapfile -t endpoint < <(po0_uri parse "$share")
    equal 203.0.113.9 "${endpoint[0]}" 'share public address'
    equal 23001 "${endpoint[1]}" 'range share uses first port'
    full=$(po0_list) brief=$(po0_list brief)
    [[ $full == *"$share"* ]] || fail 'full list omits share URI'
    [[ $brief != *PRIVATE-ID* && $brief != *vless://* ]] || fail 'brief list discloses URI credentials'
    cp "$TMP/uri-menu-out.tsv" "$TMP/uri-menu-in.tsv"
    po0_action_add <<<$'hy2://SECRET@198.51.100.3:8443?mport=8443,9000-9002#HY2\n\n23020\n\ny' >"$TMP/uri-menu-hy2.log" 2>&1 || fail 'HY2 add with existing public address'
    po0_load_state "$TMP/uri-menu-out.tsv"
    equal udp "${PO0_PROTO[4]}" 'HY2 defaults UDP'
    share=$(po0_share_uri 4)
    [[ $share != *mport=* ]] || fail 'HY2 exported share retains port hopping'
    cp "$TMP/uri-menu-out.tsv" "$TMP/uri-menu-in.tsv"
    po0_action_add <<<$'tuic://PRIVATE-ID:SECRET@198.51.100.3:8443\n\n23021\n\ny' >"$TMP/uri-menu-tuic.log" 2>&1 || fail 'unmarked TUIC add'
    po0_load_state "$TMP/uri-menu-out.tsv"
    equal '线路5' "${PO0_NAME[5]}" 'unmarked URI defaults stable-ID name'
    equal udp "${PO0_PROTO[5]}" 'TUIC defaults UDP'
    cp "$TMP/uri-menu-out.tsv" "$TMP/uri-menu-in.tsv"
    po0_action_edit <<<$'1\n6\n198.51.100.77\nvless://PRIVATE-ID@origin.example:443?security=tls#Attached\ny' >"$TMP/uri-menu-attach.log" 2>&1 || fail 'URI-only attach retries invalid IPv4 at same prompt'
    po0_load_state "$TMP/uri-menu-out.tsv"
    equal 198.51.100.9 "${PO0_DEST_IP[1]}" 'attach resolves domain'
    equal HK-T1 "${PO0_NAME[1]}" 'attach preserves existing rule name'
    PO0_DEST_IP[1]=198.51.100.8
    po0_write_state >"$TMP/uri-menu-in.tsv"
    URI_RESOLVE_FORBIDDEN=1
    po0_action_edit <<<$'1\n6\n\ny' >"$TMP/uri-menu-keep.log" 2>&1 || fail 'blank attach retains URI'
    [[ ! -e "$TMP/uri-unexpected-resolve" ]] || fail 'blank attach resolves DNS instead of retaining cached endpoint'
    cmp -s "$TMP/uri-menu-in.tsv" "$TMP/uri-menu-out.tsv" || fail 'blank attach changes URI state'
    URI_RESOLVE_FORBIDDEN=0
    po0_action_edit <<<$'1\n3\n198.51.100.7\ny' >"$TMP/uri-menu-ip.log" 2>&1 || fail 'edit attached target IP'
    po0_load_state "$TMP/uri-menu-out.tsv"
    mapfile -t endpoint < <(po0_uri parse "${PO0_URI[1]}")
    equal 198.51.100.7 "${endpoint[0]}" 'target IP edit synchronizes source URI'
    [[ ${PO0_URI[1]} == *origin.example* ]] || fail 'IP edit loses implicit upstream TLS name'
    cp "$TMP/uri-menu-out.tsv" "$TMP/uri-menu-in.tsv"
    po0_action_edit <<<$'1\n4\n8444\ny' >"$TMP/uri-menu-port.log" 2>&1 || fail 'edit attached target port'
    po0_load_state "$TMP/uri-menu-out.tsv"
    mapfile -t endpoint < <(po0_uri parse "${PO0_URI[1]}")
    equal 8444 "${endpoint[1]}" 'target port edit synchronizes source URI'
    PO0_URI[1]='vless://PRIVATE-ID@origin.example:8444?security=tls#Refresh'
    po0_write_state >"$TMP/uri-menu-in.tsv"
    po0_action_reapply <<<y >"$TMP/uri-menu-refresh.log" 2>&1 || fail 'reapply resolves attached domain'
    po0_load_state "$TMP/uri-menu-out.tsv"
    equal 198.51.100.9 "${PO0_DEST_IP[1]}" 'reapply updates resolved target'
    PO0_URI[3]='vless://PRIVATE-ID@missing.example:443'
    po0_write_state >"$TMP/uri-menu-in.tsv"
    rm -f "$TMP/uri-menu-out.tsv"
    if po0_action_reapply <<<y >"$TMP/uri-menu-dns-fail.log" 2>&1; then fail 'DNS failure reapply succeeds'; fi
    [[ ! -e "$TMP/uri-menu-out.tsv" ]] || fail 'DNS failure commits partially refreshed rules'
    po0_prepare_change
    po0_write_state >"$TMP/uri-memory.before"
    for input in "$source_uri"$'\n\n23030\n\n' ':q'; do
        if po0_action_add <<<"$input" >"$TMP/uri-menu-cancel.log" 2>&1; then fail 'URI cancelled add succeeds'; else status=$?; fi
        equal 130 "$status" 'URI cancelled add status'
        [[ ! -e "$TMP/uri-menu-out.tsv" ]] || fail 'URI cancelled add commits'
        po0_write_state >"$TMP/uri-memory.after"
        cmp -s "$TMP/uri-memory.before" "$TMP/uri-memory.after" || fail 'URI cancellation changes memory'
    done
    po0_action_public_ip <<<$'1\n203.0.113.8\ny' >"$TMP/uri-menu-public.log" 2>&1 || fail 'manual public-IP update'
    po0_load_state "$TMP/uri-menu-out.tsv"
    equal 203.0.113.8 "$PO0_PUBLIC_IP" 'public-IP action persists global setting'
    cp "$TMP/uri-menu-out.tsv" "$TMP/uri-menu-in.tsv"
    URI_PUBLIC_PROBE=203.0.113.7
    po0_action_public_ip <<<$'2\n\ny' >"$TMP/uri-menu-reprobe.log" 2>&1 || fail 'public-IP reprobe accepts detection default'
    po0_load_state "$TMP/uri-menu-out.tsv"
    equal 203.0.113.7 "$PO0_PUBLIC_IP" 'public-IP reprobe refreshes global setting'
    rm -f "$TMP/uri-menu-out.tsv"
    po0_prepare_change() { PO0_MODE=fresh; }
    if po0_action_public_ip <<<y >"$TMP/uri-menu-public-fresh.log" 2>&1; then fail 'public-IP action initializes fresh installation'; fi
    [[ ! -e "$TMP/uri-menu-out.tsv" ]] || fail 'fresh public-IP action writes configuration'
    ok 'URI add/export, manual public-IP fallback, field-6 attach, synchronized edits and atomic DNS refresh'
)

(
    po0_import_legacy "$ROOT/tests/fixtures/po0-legacy-multiple.nft"
    command() {
        if [[ ${1-}:${2-} == -v:python3 ]]; then return 1; fi
        builtin command "$@"
    }
    po0_list brief >"$TMP/no-python-list.log" || fail 'manual list requires Python'
    PO0_URI[1]='vless://PRIVATE-ID@198.51.100.2:443'
    PO0_PUBLIC_IP=203.0.113.9
    po0_write_state >"$TMP/no-python-state.tsv" || fail 'manual state requires Python'
    po0_load_state "$TMP/no-python-state.tsv" || fail 'URI state loading requires Python'
    po0_list >"$TMP/no-python-uri-list.log" || fail 'read-only URI list fails without Python'
    if po0_uri parse 'vless://PRIVATE-ID@198.51.100.2:443' >"$TMP/no-python-uri.log" 2>&1; then fail 'URI parser succeeds without Python'; fi
    [[ $(cat "$TMP/no-python-uri.log") != *PRIVATE-ID* ]] || fail 'missing Python diagnosis exposes URI'
    NO_COLOR=1 TERM=xterm po0_menu >"$TMP/no-color-menu.log"
    TERM=dumb po0_menu >"$TMP/dumb-menu.log"
    if grep -q $'\033' "$TMP/no-color-menu.log" "$TMP/dumb-menu.log"; then fail 'NO_COLOR/TERM=dumb menu contains ANSI'; fi
    ok 'manual operations tolerate missing Python and terminal color opt-outs suppress ANSI'
)

cp "$ROOT/tests/fixtures/po0-legacy-multiple.nft" "$TMP/menu-legacy.nft"
before="$(sha256sum "$TMP/menu-legacy.nft")"
{
    printf '#!/usr/bin/env bash\nsource %q\n' "$TMP/standalone.sh"
    printf 'PO0_NFT_FILE=%q\nPO0_STATE_FILE=%q\npo0_main\n' "$TMP/menu-legacy.nft" "$TMP/menu-state.tsv"
} >"$TMP/menu-runner.sh"
python3 - "$TMP/menu-runner.sh" "$ROOT/scripts/po0-relay.sh" <<'PY'
import os, pty, select, subprocess, sys, time
master, slave = pty.openpty()
process = subprocess.Popen(['bash', sys.argv[1]], stdin=slave, stdout=slave, stderr=slave)
os.close(slave)
os.write(master, b'1\n0\n')
output = bytearray()
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    if select.select([master], [], [], 0.1)[0]:
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        output.extend(data)
    if process.poll() is not None:
        break
if process.poll() is None:
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        process.kill()
        raise SystemExit(f'menu did not exit after list and 0: {output.decode(errors="replace")}')
if process.returncode != 0 or 'HK-T1'.encode() not in output or 'JP CO'.encode() not in output:
    raise SystemExit(f'menu failed: status {process.returncode}: {output.decode(errors="replace")}')
os.close(master)

def menu(env):
    master, slave = pty.openpty()
    process = subprocess.Popen(['bash', '-c', 'source "$1"; po0_menu', 'menu-test', sys.argv[2]],
                               stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    output = bytearray()
    while select.select([master], [], [], 2)[0]:
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        if not data:
            break
        output.extend(data)
    assert process.wait(timeout=2) == 0
    os.close(master)
    return bytes(output)
env = os.environ.copy()
env.pop('NO_COLOR', None)
env['TERM'] = 'xterm'
colored = menu(env)
assert b'\x1b[' in colored, 'interactive xterm menu lacks color'
for label in ('线路管理', '状态与维护', '全局设置'):
    assert label.encode() in colored, 'menu group missing: ' + label
options = [line for line in colored.decode().splitlines() if __import__('re').match(r'\s+[0-9]\)', line)]
assert len(options) == 10 and all(len(__import__('re').findall(r'[0-9]\)', line)) == 1 for line in options), options
env['NO_COLOR'] = '1'
assert b'\x1b' not in menu(env), 'NO_COLOR ignored on real TTY'
env.pop('NO_COLOR')
env['TERM'] = 'dumb'
assert b'\x1b' not in menu(env), 'TERM=dumb ignored on real TTY'
print('PASS: grouped one-option-per-line TTY menu and actual ANSI opt-outs')
PY
equal "$before" "$(sha256sum "$TMP/menu-legacy.nft")" 'PTY menu list writes nothing'
[[ ! -e "$TMP/menu-state.tsv" ]] || fail 'PTY read-only menu creates state'
ok 'real PTY menu lists legacy lines and exits without writing'

# Run complete menu navigation against temporary persistence. Keep the real
# prompts, parser, validation, state reload and nft rendering; replace only
# host discovery and the commit that would change firewall/service state.
cat >"$TMP/pty-uri-runner.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$1"
PO0_STATE_FILE=$2 PO0_NFT_FILE=$3
po0_import_legacy "$4"
PO0_PUBLIC_IP=203.0.113.9
po0_write_state >"$PO0_STATE_FILE"
po0_render_config >"$PO0_NFT_FILE"
po0_collect_host() {
    PO0_LOCAL_IPS=(192.0.2.1)
    PO0_LISTEN_TCP=() PO0_LISTEN_UDP=()
}
po0_apply() {
    po0_write_state >"$PO0_STATE_FILE" || return $?
    po0_render_config >"$PO0_NFT_FILE"
}
po0_main
SH
python3 - "$TMP/pty-uri-runner.sh" "$ROOT/scripts/po0-relay.sh" "$TMP" "$ROOT/tests/fixtures/po0-legacy-multiple.nft" <<'PY'
import os, pathlib, pty, select, subprocess, sys, time
runner, script, tmp, legacy = sys.argv[1:]
state = pathlib.Path(tmp, 'pty-uri-state.tsv')
config = pathlib.Path(tmp, 'pty-uri-nftables.conf')
master, slave = pty.openpty()
env = os.environ.copy()
env['TERM'] = 'xterm'
process = subprocess.Popen(['bash', runner, script, str(state), str(config), legacy],
                           stdin=slave, stdout=slave, stderr=slave, env=env)
os.close(slave)
transcript = bytearray()
cursor = 0
def expect(label):
    global cursor
    marker = label.encode()
    deadline = time.monotonic() + 8
    start = cursor
    while True:
        end = transcript.find(marker, cursor)
        if end >= 0:
            cursor = end + len(marker)
            return bytes(transcript[start:cursor])
        if time.monotonic() >= deadline:
            raise AssertionError('timeout waiting for prompt: ' + label)
        if not select.select([master], [], [], 0.1)[0]:
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError as error:
            raise AssertionError('PTY closed before prompt: ' + label) from error
        if not chunk:
            raise AssertionError('PTY EOF before prompt: ' + label)
        transcript.extend(chunk)
def send(value):
    os.write(master, (value + '\n').encode())
uri = 'vless://PRIVATE-PTY@198.51.100.2:443?security=tls&type=ws&sni=cert.example&host=cdn.example&unknown=keep%20me#PTY%20New'
share = uri.replace('@198.51.100.2:443', '@203.0.113.9:23101').encode()
try:
    expect('请选择:')
    send('2')
    expect('节点 URI 或目标 IPv4')
    send(uri)
    expect('规则名称')
    send('')
    expect('中转端口')
    send('23101-23103')
    expect('协议编号')
    send('')
    expect('确认这次变更？')
    send('y')
    assert share in expect('请选择:'), 'add output truncates or alters complete share URI'
    send('1')
    listed = expect('请选择:')
    assert share in listed and '[3] PTY New'.encode() in listed, 'view omits new name or complete URI'
    send('3')
    expect('规则 ID')
    send('3')
    expect('编辑字段编号')
    send('4')
    expect('目标端口')
    send('8444')
    expect('确认这次变更？')
    send('y')
    expect('请选择:')
    send('1')
    listed = expect('请选择:')
    assert share in listed and b'198.51.100.2:8444' in listed, 'view loses share or edited upstream endpoint'
    send('0')
    assert process.wait(timeout=3) == 0, 'PTY menu exits unsuccessfully'
    lines = [line.split('\t') for line in state.read_text().splitlines()]
    rule = next(row for row in lines if row[:2] == ['rule', '3'])
    saved_uri = next(row[2] for row in lines if row[:2] == ['uri', '3'])
    assert rule[4:7] == ['23101-23103', '198.51.100.2', '8444'], rule
    assert saved_uri == uri.replace('@198.51.100.2:443', '@198.51.100.2:8444'), saved_uri
    print('PASS: actual PTY add/view/edit/exit preserves complete share URI and edited persistent endpoint')
finally:
    pathlib.Path(tmp, 'pty-uri.log').write_bytes(transcript)
    if process.poll() is None:
        process.kill()
        process.wait(timeout=2)
    os.close(master)
PY

# BBR/FQ has its own transaction: exercise kernel/module failures without
# changing the test host, while keeping real atomic file writes and locking.
(
    BBR_TEST="$TMP/bbr"
    mkdir -p "$BBR_TEST"
    PO0_BBR_SYSCTL_FILE="$BBR_TEST/bbr.conf"
    PO0_BBR_MODULES_FILE="$BBR_TEST/modules.conf"
    PO0_LOCK_FILE="$BBR_TEST/lock"
    PO0_BACKUP_DIR="$BBR_TEST/backups"
    for file in "$BBR_TEST/forward.conf" "$BBR_TEST/state.tsv" "$BBR_TEST/nftables.conf"; do printf 'untouched\n' >"$file"; done
    PO0_SYSCTL_FILE="$BBR_TEST/forward.conf" PO0_STATE_FILE="$BBR_TEST/state.tsv" PO0_NFT_FILE="$BBR_TEST/nftables.conf"
    sha256sum "$PO0_SYSCTL_FILE" "$PO0_STATE_FILE" "$PO0_NFT_FILE" >"$BBR_TEST/relay.before"
    sysctl() {
        local key value count
        if [[ ${1-} == -n ]]; then
            case ${2-} in
                net.ipv4.tcp_congestion_control) cat "$BBR_TEST/algorithm" ;;
                net.core.default_qdisc) cat "$BBR_TEST/queue" ;;
                net.ipv4.tcp_available_congestion_control) cat "$BBR_TEST/available" ;;
                *) return 70 ;;
            esac
            return
        fi
        [[ ${1-}:${2-} == -q:-w ]] || return 70
        key=${3%%=*} value=${3#*=}
        printf '%s\n' "$3" >>"$BBR_TEST/writes"
        count=$(wc -l <"$BBR_TEST/writes")
        if [[ $BBR_FAULT == second-sysctl && $count == 2 ]]; then return 1; fi
        case $key in
            net.ipv4.tcp_congestion_control) printf '%s\n' "$value" >"$BBR_TEST/algorithm" ;;
            net.core.default_qdisc)
                if [[ $BBR_FAULT == no-fq && $value == fq ]]; then return 1; fi
                printf '%s\n' "$value" >"$BBR_TEST/queue"
                ;;
            *) return 70 ;;
        esac
    }
    modprobe() {
        printf '%s\n' "$1" >>"$BBR_TEST/modules-called"
        case "$BBR_FAULT:$1" in
            no-bbr:tcp_bbr | no-fq:sch_fq) return 1 ;;
            load-bbr:tcp_bbr) printf 'reno bbr\n' >"$BBR_TEST/available" ;;
        esac
    }
    mv() {
        if [[ $BBR_FAULT == persistence && ${!#} == "$PO0_BBR_MODULES_FILE" && ! -e "$BBR_TEST/move-failed" ]]; then
            [[ -s "$PO0_BBR_SYSCTL_FILE" ]] || fail 'persistence failure preceded the first file write'
            touch "$BBR_TEST/move-failed"
            return 1
        fi
        command mv "$@"
    }
    nft() {
        touch "$BBR_TEST/forbidden-nft"
        return 99
    }
    tc() {
        touch "$BBR_TEST/forbidden-tc"
        return 99
    }
    bbr_reset() {
        rm -f "$PO0_BBR_SYSCTL_FILE" "$PO0_BBR_MODULES_FILE" "$BBR_TEST/writes" "$BBR_TEST/modules-called" "$BBR_TEST/move-failed"
        printf 'reno\n' >"$BBR_TEST/algorithm"
        printf 'fq_codel\n' >"$BBR_TEST/queue"
        printf 'reno bbr\n' >"$BBR_TEST/available"
        BBR_FAULT=none
    }
    bbr_assert_original() {
        equal reno "$(cat "$BBR_TEST/algorithm")" 'BBR failure restores congestion control'
        equal fq_codel "$(cat "$BBR_TEST/queue")" 'BBR failure restores default queue'
        [[ ! -e "$PO0_BBR_SYSCTL_FILE" ]] || fail 'BBR failure leaves new sysctl file'
        [[ ! -e "$PO0_BBR_MODULES_FILE" ]] || fail 'BBR failure leaves new modules file'
    }
    bbr_reset
    if po0_enable_bbr <<<'' >"$BBR_TEST/cancel.log" 2>&1; then fail 'default-no BBR confirmation succeeds'; else status=$?; fi
    equal 130 "$status" 'BBR cancel status'
    bbr_assert_original
    [[ ! -e "$BBR_TEST/writes" && ! -e "$BBR_TEST/modules-called" && ! -e "$PO0_BACKUP_DIR" ]] || fail 'BBR cancel mutates parameters, modules or backups'
    ok 'BBR cancellation makes no kernel/module/persistence changes'

    for fault in no-bbr no-fq second-sysctl; do
        bbr_reset
        BBR_FAULT=$fault
        [[ $fault != no-bbr ]] || printf 'reno\n' >"$BBR_TEST/available"
        if po0_enable_bbr <<<y >"$BBR_TEST/$fault.log" 2>&1; then fail "BBR $fault succeeds"; fi
        bbr_assert_original
        if [[ $fault == second-sysctl ]]; then grep -Fxq 'net.core.default_qdisc=fq' "$BBR_TEST/writes" || fail 'second sysctl injection missed initial queue write'; fi
    done
    ok 'unsupported BBR/FQ and second sysctl failure leave no partial state'

    bbr_reset
    po0_bbr_modules_content >"$PO0_BBR_MODULES_FILE"
    chmod 600 "$PO0_BBR_MODULES_FILE"
    cp -p "$PO0_BBR_MODULES_FILE" "$BBR_TEST/modules.before"
    BBR_FAULT=persistence
    if po0_enable_bbr <<<y >"$BBR_TEST/persistence.log" 2>&1; then fail 'BBR persistence failure succeeds'; fi
    [[ -f "$BBR_TEST/move-failed" ]] || fail 'persistence injection was not reached'
    equal reno "$(cat "$BBR_TEST/algorithm")" 'persistence failure restores congestion control'
    equal fq_codel "$(cat "$BBR_TEST/queue")" 'persistence failure restores queue'
    [[ ! -e "$PO0_BBR_SYSCTL_FILE" ]] || fail 'persistence rollback leaves first new file'
    cmp -s "$BBR_TEST/modules.before" "$PO0_BBR_MODULES_FILE" || fail 'persistence rollback changes existing modules file'
    equal 600 "$(stat -c %a "$PO0_BBR_MODULES_FILE")" 'persistence rollback preserves existing file mode'
    ok 'second persistence-file failure restores runtime, absent file and existing file'

    bbr_reset
    BBR_FAULT=load-bbr
    printf 'reno\n' >"$BBR_TEST/available"
    po0_enable_bbr <<<y >"$BBR_TEST/success.log" 2>&1 || fail 'BBR enable with module loading'
    equal bbr "$(cat "$BBR_TEST/algorithm")" 'BBR enable runtime algorithm'
    equal fq "$(cat "$BBR_TEST/queue")" 'BBR enable runtime queue'
    grep -Fxq tcp_bbr "$BBR_TEST/modules-called" || fail 'BBR module not loaded when unavailable'
    grep -Fxq tcp_bbr "$PO0_BBR_MODULES_FILE" || fail 'BBR boot module missing'
    grep -Fxq sch_fq "$PO0_BBR_MODULES_FILE" || fail 'FQ boot module missing'
    grep -Eq '^net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq$' "$PO0_BBR_SYSCTL_FILE" || fail 'FQ boot parameter missing'
    grep -Eq '^net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr$' "$PO0_BBR_SYSCTL_FILE" || fail 'BBR boot parameter missing'
    before="$(
        stat -c '%i:%y:%a' "$PO0_BBR_SYSCTL_FILE" "$PO0_BBR_MODULES_FILE"
        sha256sum "$BBR_TEST/writes" "$BBR_TEST/modules-called"
    )"
    display="$(po0_bbr_status)"
    [[ $display == *bbr* && $display == *fq* ]] || fail 'BBR read-only display omits current values'
    po0_enable_bbr </dev/null >"$BBR_TEST/repeat.log" 2>&1 || fail 'already enabled BBR requires input or fails'
    equal "$before" "$(
        stat -c '%i:%y:%a' "$PO0_BBR_SYSCTL_FILE" "$PO0_BBR_MODULES_FILE"
        sha256sum "$BBR_TEST/writes" "$BBR_TEST/modules-called"
    )" 'BBR repeat changes files/runtime/modules'
    [[ ! -e "$BBR_TEST/forbidden-nft" && ! -e "$BBR_TEST/forbidden-tc" ]] || fail 'BBR action changes nft or live queues'
    sha256sum "$PO0_SYSCTL_FILE" "$PO0_STATE_FILE" "$PO0_NFT_FILE" >"$BBR_TEST/relay.after"
    cmp -s "$BBR_TEST/relay.before" "$BBR_TEST/relay.after" || fail 'BBR action changes forwarding state/config'
    ok 'BBR module enable and persisted repeat are idempotent; forwarding and live queues untouched'
)
printf 'PASS: PO0 unit acceptance complete\n'
