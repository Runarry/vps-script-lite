#!/usr/bin/env bash
# Focused standalone PO0 contract checks. Run only on host-vps-scripts.
# shellcheck disable=SC2034,SC2317 # Globals and commit hooks are used by sourced code.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
ok() { printf 'PASS: %s\n' "$*"; }
equal() { [[ "$1" == "$2" ]] || fail "$3: expected <$1>, got <$2>"; }
declare -A PO0_NAME PO0_ENABLED PO0_PROTO PO0_PORT PO0_DEST_IP PO0_DEST_PORT
# shellcheck source=/dev/null
source "$ROOT/scripts/po0-relay.sh"

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
    po0_action_add <<<$'UDP split\n20001\ninvalid-ip\n198.51.100.3\n0\n8443\n9\n2\ny' >"$TMP/menu-add.log" 2>&1 || fail 'add chooses UDP after entering existing TCP port'
    po0_load_state "$TMP/menu-out.tsv"
    equal 3 "${#PO0_IDS[@]}" 'add count'
    equal udp "${PO0_PROTO[3]}" 'add last protocol choice'
    equal 20001 "${PO0_PORT[3]}" 'add shares TCP port with UDP'
    equal 4 "$PO0_NEXT_ID" 'add advances next stable ID'
    ok 'add flow retries invalid fields and accepts protocol choice after shared port'

    po0_action_add <<<$'Default protocol\n21001\n198.51.100.3\n443\n\ny' >"$TMP/menu-add-default.log" 2>&1 || fail 'add default protocol'
    po0_load_state "$TMP/menu-out.tsv"
    equal both "${PO0_PROTO[3]}" 'add defaults to both protocols'
    for field in 1 2 3 4 5; do
        po0_action_edit <<<"$first"$'\n'"$field"$'\n\ny' >"$TMP/menu-edit-$field.log" 2>&1 || fail "edit blank default field $field"
        cmp -s "$TMP/menu-original.tsv" "$TMP/menu-out.tsv" || fail "edit blank changes existing field $field"
    done
    ok 'new protocol default and all five edit defaults preserve values'

    po0_prepare_change
    po0_write_state >"$TMP/menu-memory.before"
    for input in ':q' $'Partial\n21001\n:q' $'Declined\n21001\n198.51.100.3\n443\n3\n'; do
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

cp "$ROOT/tests/fixtures/po0-legacy-multiple.nft" "$TMP/menu-legacy.nft"
before="$(sha256sum "$TMP/menu-legacy.nft")"
{
    printf '#!/usr/bin/env bash\nsource %q\n' "$TMP/standalone.sh"
    printf 'PO0_NFT_FILE=%q\nPO0_STATE_FILE=%q\npo0_main\n' "$TMP/menu-legacy.nft" "$TMP/menu-state.tsv"
} >"$TMP/menu-runner.sh"
python3 - "$TMP/menu-runner.sh" <<'PY'
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
PY
equal "$before" "$(sha256sum "$TMP/menu-legacy.nft")" 'PTY menu list writes nothing'
[[ ! -e "$TMP/menu-state.tsv" ]] || fail 'PTY read-only menu creates state'
ok 'real PTY menu lists legacy lines and exits without writing'
printf 'PASS: PO0 unit acceptance complete\n'
