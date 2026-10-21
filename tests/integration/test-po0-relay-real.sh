#!/usr/bin/env bash
# Opt-in acceptance for host-vps-scripts; all firewall writes stay in a netns.
# shellcheck disable=SC2034,SC2317 # Globals and systemctl hook are used by sourced code.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
ok() { printf 'PASS: %s\n' "$*"; }

inside() {
    local work="$1" first second before
    declare -gA PO0_NAME PO0_ENABLED PO0_PROTO PO0_PORT PO0_DEST_IP PO0_DEST_PORT
    # shellcheck source=/dev/null
    source "$ROOT/scripts/po0-relay.sh"
    PO0_STATE_FILE="$work/state.tsv"
    PO0_NFT_FILE="$work/nftables.conf"
    PO0_SYSCTL_FILE="$work/ip-forward.conf"
    PO0_BACKUP_DIR="$work/backups"
    PO0_LOCK_FILE="$work/po0.lock"
    SERVICE_FAIL=0
    printf 'disabled\n' >"$work/service-state"
    systemctl() {
        printf '%s ' "$@" >>"$work/systemctl.calls"
        printf '\n' >>"$work/systemctl.calls"
        case "${1-}:${2-}" in
            show:ssh.socket | show:sshd.socket) return 0 ;;
            is-enabled:nftables)
                cat "$work/service-state"
                [[ "$(cat "$work/service-state")" == enabled ]]
                ;;
            enable:nftables)
                if [[ "$SERVICE_FAIL" == 1 ]]; then
                    nft -s list ruleset >"$work/rollback-runtime.at-enable"
                    cp "$PO0_STATE_FILE" "$work/rollback-state.at-enable"
                    return 1
                fi
                printf 'enabled\n' >"$work/service-state"
                ;;
            disable:nftables) printf 'disabled\n' >"$work/service-state" ;;
            *) fail "unexpected systemctl operation: $*" ;;
        esac
    }
    po0_load_current || fail 'load fresh installation'
    [[ "$PO0_MODE" == fresh ]] || fail 'new installation mode'
    PO0_IFACE=wan0 PO0_RELAY_IP=192.0.2.1
    python3 - "$work/listener.ready" <<'PY' &
import pathlib, socket, sys, time
tcp = socket.socket()
tcp.bind(('0.0.0.0', 29999))
tcp.listen()
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(('0.0.0.0', 29999))
pathlib.Path(sys.argv[1]).touch()
time.sleep(30)
PY
    listener_pid=$!
    for ((attempt = 0; attempt < 50; attempt++)); do
        [[ -e "$work/listener.ready" ]] && break
        sleep 0.1
    done
    [[ -e "$work/listener.ready" ]] || fail 'test listeners did not start'
    SSH_CONNECTION='203.0.113.2 55555 192.0.2.1 2022' po0_collect_host
    if po0_check_conflicts 29999 tcp; then fail 'real TCP listener conflict accepted'; fi
    if po0_check_conflicts 29999 udp; then fail 'real UDP listener conflict accepted'; fi
    if po0_check_conflicts 2022 tcp; then fail 'active nondefault SSH port accepted'; fi
    po0_check_conflicts 2022 udp || fail 'SSH TCP reservation incorrectly blocks UDP'
    if po0_check_target 198.51.100.1; then fail 'different local-interface target accepted'; fi
    if po0_check_target 127.0.0.1; then fail 'loopback target accepted'; fi
    kill "$listener_pid"
    wait "$listener_pid" || true
    ok 'real listener conflicts, active SSH port and local target loop rejection'
    po0_apply || fail 'fresh installation apply'
    [[ -s "$PO0_STATE_FILE" && -s "$PO0_NFT_FILE" ]] || fail 'fresh installation persistence'
    mv "$PO0_STATE_FILE" "$work/fresh-state.tsv"
    mv "$PO0_NFT_FILE" "$work/fresh-nftables.conf"
    mv "$PO0_SYSCTL_FILE" "$work/fresh-ip-forward.conf"
    sysctl -q -w net.ipv4.ip_forward=0
    ok 'fresh installation applies an empty initial rule set'
    nft -f "$ROOT/tests/fixtures/po0-legacy-multiple.nft"
    cp "$ROOT/tests/fixtures/po0-legacy-multiple.nft" "$PO0_NFT_FILE"
    nft -s list ruleset >"$work/legacy-runtime.before"
    before="$(sha256sum "$PO0_NFT_FILE")"
    po0_load_current || fail 'load current legacy configuration'
    [[ "$PO0_MODE" == legacy && "${#PO0_IDS[@]}" == 2 ]] || fail 'legacy current mode/count'
    [[ "$before" == "$(sha256sum "$PO0_NFT_FILE")" ]] || fail 'legacy viewing rewrites config'
    [[ ! -e "$PO0_STATE_FILE" ]] || fail 'legacy viewing creates state'
    nft -s list ruleset >"$work/legacy-runtime.after"
    cmp -s "$work/legacy-runtime.before" "$work/legacy-runtime.after" || fail 'legacy viewing changes runtime'
    po0_load_current || fail 'repeat legacy view'
    [[ "${#PO0_IDS[@]}" == 2 ]] || fail 'legacy view duplicates rules'
    ok 'legacy inspection preserves runtime and disk without duplicate import'

    # A first edit migrates the recognized legacy rules in this isolated netns.
    nft add table inet foreign_po0
    nft 'add chain inet foreign_po0 marker'
    nft 'add rule inet foreign_po0 marker counter comment "acceptance foreign table"'
    nft -s list table inet foreign_po0 >"$work/foreign.before"
    po0_load_current || fail 'load legacy state before first edit'
    PO0_IFACE=wan0 PO0_RELAY_IP=192.0.2.1 PO0_NEXT_ID=3
    PO0_SSH_PORTS=(22)
    PO0_IDS=(1 2)
    PO0_NAME[1]='HK-T1' PO0_NAME[2]='JP CO'
    PO0_ENABLED[1]=1 PO0_ENABLED[2]=1
    PO0_PROTO[1]=both PO0_PROTO[2]=both
    PO0_PORT[1]=20001 PO0_PORT[2]=20002
    PO0_DEST_IP[1]=198.51.100.2 PO0_DEST_IP[2]=198.51.100.3
    PO0_DEST_PORT[1]=443 PO0_DEST_PORT[2]=8443
    po0_apply || fail 'initial legacy migration apply'
    [[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]] || fail 'forwarding not enabled'
    [[ -s "$PO0_STATE_FILE" && -s "$PO0_NFT_FILE" && -s "$PO0_SYSCTL_FILE" ]] || fail 'persistent files missing'
    nft -s list table inet foreign_po0 >"$work/foreign.after"
    cmp -s "$work/foreign.before" "$work/foreign.after" || fail 'initial apply changes foreign table'
    touch "$work/initial.ready"
    while [[ ! -e "$work/initial.probed" ]]; do sleep 0.1; done
    ok 'initial apply writes persistent files and preserves foreign nft table'

    po0_load_current
    first="${PO0_IDS[0]}" second="${PO0_IDS[1]}"
    PO0_PROTO[$first]=tcp PO0_PROTO[$second]=udp PO0_PORT[$second]=20001
    po0_apply || fail 'same input port with distinct protocols'
    touch "$work/protocol.ready"
    while [[ ! -e "$work/protocol.probed" ]]; do sleep 0.1; done
    ok 'same input port independently routes TCP and UDP to distinct servers'

    po0_load_current || fail 'load before edit'
    first="${PO0_IDS[0]}" second="${PO0_IDS[1]}"
    PO0_PROTO[$first]=both PO0_PROTO[$second]=both PO0_PORT[$second]=20002
    PO0_DEST_IP[$first]=198.51.100.3 PO0_DEST_PORT[$first]=8444
    po0_apply || fail 'edit destination'
    touch "$work/edit.ready"
    while [[ ! -e "$work/edit.probed" ]]; do sleep 0.1; done
    ok 'edit updates selected route and preserves the other route'

    po0_load_current
    PO0_ENABLED[$first]=0
    po0_apply || fail 'disable selected line'
    touch "$work/disable.ready"
    while [[ ! -e "$work/disable.probed" ]]; do sleep 0.1; done
    po0_load_current
    PO0_ENABLED[$first]=1 PO0_PORT[$first]=20010-20012
    po0_apply || fail 'enable selected line with input range'
    touch "$work/range.ready"
    while [[ ! -e "$work/range.probed" ]]; do sleep 0.1; done
    ok 'disable/enable and input range first/last port forwarding'

    cp "$PO0_STATE_FILE" "$work/rollback-state.before"
    cp "$PO0_NFT_FILE" "$work/rollback-config.before"
    cp "$PO0_SYSCTL_FILE" "$work/rollback-sysctl.before"
    nft -s list ruleset >"$work/rollback-runtime.before"
    po0_load_current
    PO0_DEST_PORT[$second]=443
    printf 'disabled\n' >"$work/service-state"
    SERVICE_FAIL=1
    if po0_apply; then fail 'service failure was reported as success'; fi
    SERVICE_FAIL=0
    [[ -s "$work/rollback-runtime.at-enable" ]] || fail 'failure injection missed post-apply service enable'
    if cmp -s "$work/rollback-state.before" "$work/rollback-state.at-enable"; then fail 'failure occurred before desired state was written'; fi
    [[ "$(cat "$work/service-state")" == disabled ]] || fail 'failed apply changes service enable state'
    cmp -s "$PO0_STATE_FILE" "$work/rollback-state.before" || fail 'failed apply changes saved state'
    cmp -s "$PO0_NFT_FILE" "$work/rollback-config.before" || fail 'failed apply changes saved config'
    cmp -s "$PO0_SYSCTL_FILE" "$work/rollback-sysctl.before" || fail 'failed apply changes sysctl file'
    nft -s list ruleset >"$work/rollback-runtime.after"
    cmp -s "$work/rollback-runtime.before" "$work/rollback-runtime.after" || fail 'failed apply changes runtime'
    touch "$work/rollback.ready"
    while [[ ! -e "$work/rollback.probed" ]]; do sleep 0.1; done
    ok 'injected service failure rolls back runtime, configuration and state'

    nft -f "$PO0_NFT_FILE"
    nft -f "$PO0_NFT_FILE"
    touch "$work/reload.ready"
    while [[ ! -e "$work/reload.probed" ]]; do sleep 0.1; done
    nft -s list table inet foreign_po0 >"$work/foreign.final"
    cmp -s "$work/foreign.before" "$work/foreign.final" || fail 'reload changes foreign table'
    po0_load_current
    PO0_IDS=("$second")
    unset 'PO0_NAME[$first]' 'PO0_ENABLED[$first]' 'PO0_PROTO[$first]' 'PO0_PORT[$first]' 'PO0_DEST_IP[$first]' 'PO0_DEST_PORT[$first]'
    po0_apply || fail 'delete first stable ID'
    po0_load_current
    [[ "${#PO0_IDS[@]}" == 1 && "${PO0_IDS[0]}" == "$second" ]] || fail 'delete changes surviving stable ID'
    touch "$work/delete.ready"
    while [[ ! -e "$work/delete.probed" ]]; do sleep 0.1; done
    ok 'persistent reload is idempotent and delete preserves surviving stable ID'
    return 0
}

if [[ "${1:-}" == --inside ]]; then
    inside "$2"
    exit
fi
[[ "${PO0_REAL_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set PO0_REAL_TEST=1 on host-vps-scripts\n'
    exit
}
((EUID == 0)) || fail 'root required'
for tool in ip nft python3 sysctl timeout sha256sum; do command -v "$tool" >/dev/null || fail "missing $tool"; done
WORK="${PO0_RESULT_DIR:-$(mktemp -d /var/tmp/po0-relay-real.XXXXXX)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd -P)"
PREFIX="po0-${BASHPID}"
C="$PREFIX-c" R="$PREFIX-r" S1="$PREFIX-s1" S2="$PREFIX-s2"
cleanup() {
    local ns pid
    for ns in "$C" "$R" "$S1" "$S2"; do
        while read -r pid; do
            if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
        done < <(ip netns pids "$ns" 2>/dev/null || true)
        ip netns del "$ns" 2>/dev/null || true
    done
}
trap cleanup EXIT
nft -s list ruleset >"$WORK/host-rules.before"
for ns in "$C" "$R" "$S1" "$S2"; do
    ip netns add "$ns"
    ip -n "$ns" link set lo up
done
ip -n "$C" link add client0 type veth peer name wan0 netns "$R"
ip -n "$C" addr add 192.0.2.2/24 dev client0
ip -n "$C" link set client0 up
ip -n "$C" route add default via 192.0.2.1
ip -n "$R" addr add 192.0.2.1/24 dev wan0
ip -n "$R" link set wan0 up
ip -n "$R" link add br0 type bridge
ip -n "$R" addr add 198.51.100.1/24 dev br0
ip -n "$R" link set br0 up
for pair in "1:$S1:2" "2:$S2:3"; do
    IFS=: read -r index ns octet <<<"$pair"
    ip -n "$R" link add "lan$index" type veth peer name server0 netns "$ns"
    ip -n "$R" link set "lan$index" master br0
    ip -n "$R" link set "lan$index" up
    ip -n "$ns" addr add "198.51.100.$octet/24" dev server0
    ip -n "$ns" link set server0 up
    ip -n "$ns" route add default via 198.51.100.1
done
cat >"$WORK/servers.py" <<'PY'
import socket, sys, threading, time
def run(port, kind):
    sock = socket.socket(socket.AF_INET, kind)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((sys.argv[1], port))
    if kind == socket.SOCK_STREAM:
        sock.listen()
    while True:
        if kind == socket.SOCK_STREAM:
            conn, peer = sock.accept()
            conn.recv(128)
            local = conn.getsockname()
            conn.sendall(f'{local[0]}:{local[1]}|{peer[0]}'.encode())
            conn.close()
        else:
            data, peer = sock.recvfrom(128)
            sock.sendto(f'{sys.argv[1]}:{port}|{peer[0]}'.encode(), peer)
for port in (443, 8443, 8444):
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        threading.Thread(target=run, args=(port, kind), daemon=True).start()
time.sleep(300)
PY
cat >"$WORK/probe.py" <<'PY'
import socket, sys
proto, port, expected = sys.argv[1:]
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM if proto == 'tcp' else socket.SOCK_DGRAM)
sock.settimeout(1)
try:
    sock.connect(('192.0.2.1', int(port)))
    sock.send(b'acceptance')
    actual = sock.recv(256).decode()
except (TimeoutError, OSError):
    actual = 'BLOCKED'
if actual != expected:
    raise SystemExit(f'{proto}/{port}: expected {expected}, got {actual}')
print(f'PASS: {proto}/{port} -> {actual}')
PY
ip netns exec "$S1" python3 "$WORK/servers.py" 198.51.100.2 >"$WORK/server1.log" 2>&1 &
ip netns exec "$S2" python3 "$WORK/servers.py" 198.51.100.3 >"$WORK/server2.log" 2>&1 &
sleep 0.3
ip netns exec "$R" bash "$0" --inside "$WORK" >"$WORK/inside.log" 2>&1 &
INSIDE_PID=$!
wait_stage() {
    local stage="$1" attempt
    for ((attempt = 0; attempt < 300; attempt++)); do
        [[ -e "$WORK/$stage.ready" ]] && return
        kill -0 "$INSIDE_PID" 2>/dev/null || {
            cat "$WORK/inside.log"
            fail "inside exited before $stage"
        }
        sleep 0.1
    done
    cat "$WORK/inside.log"
    fail "timeout waiting for $stage"
}
probe() { ip netns exec "$C" python3 "$WORK/probe.py" "$@"; }
probe_line() {
    local input="$1" ip="$2" port="$3"
    probe tcp "$input" "$ip:$port|192.0.2.1"
    probe udp "$input" "$ip:$port|192.0.2.1"
}
wait_stage initial
probe_line 20001 198.51.100.2 443
probe_line 20002 198.51.100.3 8443
touch "$WORK/initial.probed"
wait_stage protocol
probe tcp 20001 '198.51.100.2:443|192.0.2.1'
probe udp 20001 '198.51.100.3:8443|192.0.2.1'
touch "$WORK/protocol.probed"
wait_stage edit
probe_line 20001 198.51.100.3 8444
probe_line 20002 198.51.100.3 8443
touch "$WORK/edit.probed"
wait_stage disable
probe tcp 20001 BLOCKED
probe udp 20001 BLOCKED
probe_line 20002 198.51.100.3 8443
touch "$WORK/disable.probed"
wait_stage range
probe_line 20010 198.51.100.3 8444
probe_line 20012 198.51.100.3 8444
probe_line 20002 198.51.100.3 8443
touch "$WORK/range.probed"
wait_stage rollback
probe_line 20010 198.51.100.3 8444
probe_line 20002 198.51.100.3 8443
touch "$WORK/rollback.probed"
wait_stage reload
probe_line 20012 198.51.100.3 8444
probe_line 20002 198.51.100.3 8443
touch "$WORK/reload.probed"
wait_stage delete
probe tcp 20010 BLOCKED
probe udp 20010 BLOCKED
probe_line 20002 198.51.100.3 8443
touch "$WORK/delete.probed"
wait "$INSIDE_PID" || {
    cat "$WORK/inside.log"
    fail 'inside acceptance'
}
cat "$WORK/inside.log"
nft -s list ruleset >"$WORK/host-rules.after"
cmp -s "$WORK/host-rules.before" "$WORK/host-rules.after" || fail 'host firewall changed during isolated acceptance'
ok 'host firewall remained unchanged'
printf 'PASS: PO0 real acceptance complete; evidence %s\n' "$WORK"
