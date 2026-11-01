#!/usr/bin/env bash
# Opt-in native nftables acceptance. All firewall/sysctl changes are in netns.
# shellcheck disable=SC1091,SC2016
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

if [[ "${1:-}" != --inside ]]; then
    [[ "${VPSCTL_REAL_NFT_TEST:-0}" == 1 ]] || { echo 'SKIP: set VPSCTL_REAL_NFT_TEST=1'; exit 0; }
    ((EUID == 0)) || { echo 'BLOCKED: root required'; exit 3; }
    for tool in ip nft jq python3 sysctl sha256sum timeout; do
        command -v "$tool" >/dev/null || { printf 'BLOCKED: missing %s\n' "$tool"; exit 3; }
    done
    result="${VPSCTL_NFT_RESULT_DIR:-/var/tmp/vpsctl-nft-acceptance/results}/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p -- "$result/root"
    rns="vn-r-$$" cns="vn-c-$$" bns="vn-b-$$"
    # shellcheck disable=SC2317 # Called by EXIT trap in this branch.
    cleanup() {
        local status=$? ns pid
        trap - EXIT HUP INT TERM
        for ns in "$rns" "$cns" "$bns"; do
            while read -r pid; do [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true; done < <(ip netns pids "$ns" 2>/dev/null)
            ip netns del "$ns" 2>/dev/null || true
        done
        printf 'INFO: evidence=%s exit=%s\n' "$result" "$status"
        exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM
    for ns in "$rns" "$cns" "$bns"; do ip netns add "$ns"; ip -n "$ns" link set lo up; done
    ip -n "$rns" link add front type veth peer name eth0 netns "$cns"
    ip -n "$rns" link add back type veth peer name eth0 netns "$bns"
    ip -n "$rns" address add 10.203.1.1/24 dev front
    ip -n "$rns" address add 10.203.2.1/24 dev back
    ip -n "$cns" address add 10.203.1.2/24 dev eth0
    ip -n "$cns" address add 10.203.1.3/24 dev eth0
    ip -n "$bns" address add 10.203.2.2/24 dev eth0
    ip -n "$rns" -6 address add fd90:1::1/64 dev front nodad
    ip -n "$rns" -6 address add fd90:2::1/64 dev back nodad
    ip -n "$cns" -6 address add fd90:1::2/64 dev eth0 nodad
    ip -n "$cns" -6 address add fd90:1::3/64 dev eth0 nodad
    ip -n "$bns" -6 address add fd90:2::2/64 dev eth0 nodad
    ip -n "$rns" link set front up; ip -n "$rns" link set back up
    ip -n "$cns" link set eth0 up; ip -n "$bns" link set eth0 up
    ip -n "$bns" route add default via 10.203.2.1
    ip -n "$bns" -6 route add default via fd90:2::1
    ip -n "$cns" route add 10.203.2.0/24 via 10.203.1.1
    ip -n "$cns" -6 route add fd90:2::/64 via fd90:1::1
    {
        date -u --iso-8601=seconds
        uname -a
        nft --version
        git -C "$TEST_ROOT" rev-parse HEAD 2>/dev/null || true
        find "$TEST_ROOT/lib" "$TEST_ROOT/commands/network/nftables" -type f \( -name '*nft*' -o -path '*/nftables/*' -o -name command.sh \) -print0 | sort -z | xargs -0 sha256sum
        sha256sum "$TEST_ROOT/tests/integration/test-network-nftables-real.sh" "$TEST_ROOT/tests/integration/test-nftables-linkage-real.sh" "$TEST_ROOT/commands/network/nftables.sh"
    } >"$result/code-state.txt"
    ip netns exec "$rns" env VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$result/root" \
        bash "$0" --inside "$result" "$cns" "$bns" 2>&1 | tee "$result/acceptance.log"
    exit "${PIPESTATUS[0]}"
fi

result="$2" cns="$3" bns="$4"
source "$TEST_ROOT/lib/command.sh"
source "$TEST_ROOT/lib/nftables.sh"
vps_cmd_init nft-real "$TEST_ROOT"
vps_nft_init
SERVER_PIDS=()
inside_cleanup() {
    local status=$? pid
    trap - EXIT
    if ((status)); then printf 'FAIL: kernel acceptance status=%s\n' "$status"; nft -a list ruleset >"$result/failure.nft" 2>&1 || true; fi
    for pid in "${SERVER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${SERVER_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    exit "$status"
}
trap inside_cleanup EXIT
sysctl -q -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1

cat >"$result/server.py" <<'PY'
import socket,sys,threading,time
host,port,mode,ready=sys.argv[1:]
s=socket.socket(socket.AF_INET6 if ':' in host else socket.AF_INET, socket.SOCK_STREAM if mode=='tcp' else socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
if ':' in host: s.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,1)
s.bind((host,int(port)))
def echo(c):
    try:
        c.settimeout(20)
        while True:
            p=c.recv(512)
            if not p: break
            c.sendall(p)
    except OSError: pass
    finally: c.close()
if mode=='tcp': s.listen(64)
open(ready,'w').close()
while True:
    if mode=='tcp':
        c,_=s.accept();threading.Thread(target=echo,args=(c,),daemon=True).start()
    else:
        p,a=s.recvfrom(512);s.sendto(p,a)
PY
cat >"$result/probe.py" <<'PY'
import socket,sys,threading,concurrent.futures
mode,host,port,source,action=sys.argv[1:]
family=socket.AF_INET6 if ':' in host else socket.AF_INET
def connect():
    s=socket.socket(family,socket.SOCK_STREAM if mode=='tcp' else socket.SOCK_DGRAM)
    s.settimeout(.45);s.bind((source,0))
    try:
        s.connect((host,int(port)));s.sendall(b'nft-real');assert s.recv(128)==b'nft-real'
        return s
    except (OSError,AssertionError): s.close();return None
if action in ('allow','block'):
    s=connect();ok=s is not None
    if s:s.close()
    assert ok==(action=='allow'),f'{action} expected for {mode} {host}:{port} from {source}; allowed={ok}'
elif action=='burst':
    gate=threading.Barrier(8)
    def probe(_):
        gate.wait();s=connect()
        if s:s.close();return 1
        return 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:n=sum(pool.map(probe,range(8)))
    print(f'burst received={n}/8',flush=True)
    assert 0<n<=2,n
elif action=='unlimited':
    for _ in range(8):
        s=connect();assert s is not None;s.close()
elif action=='concurrency':
    held=[connect(),connect()];assert all(held),'first two connections must succeed'
    third=connect();assert third is None,'third simultaneous connection crossed limit'
    for s in held:s.close()
elif action=='udp-packets':
    s=socket.socket(family,socket.SOCK_DGRAM);s.bind((source,0));s.settimeout(.08)
    n=0
    for _ in range(8):
        s.sendto(b'nft-real',(host,int(port)))
        try:n+=s.recv(128)==b'nft-real'
        except socket.timeout:pass
    print(f'UDP same-flow received={n}/8',flush=True);assert 0<n<=2,n
else:raise AssertionError(action)
PY
start_server() {
    local ns="$1" host="$2" port="$3" proto="$4" ready="$result/ready-$1-$2-$3-$4"
    if [[ "$ns" == router ]]; then python3 "$result/server.py" "$host" "$port" "$proto" "$ready" &
    else ip netns exec "$ns" python3 "$result/server.py" "$host" "$port" "$proto" "$ready" & fi
    SERVER_PIDS+=("$!")
    for _ in {1..60}; do [[ ! -e "$ready" ]] || return 0; sleep .05; done
    echo 'FAIL: server startup'; return 1
}
probe() { ip netns exec "$cns" python3 "$result/probe.py" "$@"; }
matrix() {
    local action="$1" source="${2:-2}" version host src base
    for version in 4 6; do
        if [[ "$version" == 4 ]]; then host=10.203.1.1; src="10.203.1.$source"; else host=fd90:1::1; src="fd90:1::$source"; fi
        for base in 41000 42000; do
            probe tcp "$host" "$base" "$src" "$action"
            probe udp "$host" "$((base+1))" "$src" "$action"
        done
    done
}
for host in 10.203.1.1 fd90:1::1; do
    for port in 41000 41002 41003 41004 41006; do start_server router "$host" "$port" tcp; done
    start_server router "$host" 41001 udp
done
for host in 10.203.2.2 fd90:2::2; do
    start_server "$bns" "$host" 41000 tcp
    start_server "$bns" "$host" 41001 udp
done
nft -f - <<'NFT'
add table inet acceptance_foreign
add chain inet acceptance_foreign input { type filter hook input priority 10; policy accept; }
add rule inet acceptance_foreign input tcp dport 59999 counter accept comment "foreign sentinel"
add table ip docker_like
add chain ip docker_like DOCKER-USER { type filter hook forward priority 10; policy accept; }
add rule ip docker_like DOCKER-USER ip saddr 192.0.2.99 counter drop comment "docker sentinel"
add table inet acceptance_nat
add chain inet acceptance_nat prerouting { type nat hook prerouting priority -100; policy accept; }
add rule inet acceptance_nat prerouting ip daddr 10.203.1.1 tcp dport 42000 dnat ip to 10.203.2.2:41000
add rule inet acceptance_nat prerouting ip daddr 10.203.1.1 udp dport 42001 dnat ip to 10.203.2.2:41001
add rule inet acceptance_nat prerouting ip6 daddr fd90:1::1 tcp dport 42000 dnat ip6 to [fd90:2::2]:41000
add rule inet acceptance_nat prerouting ip6 daddr fd90:1::1 udp dport 42001 dnat ip6 to [fd90:2::2]:41001
NFT
foreign_snapshot() {
    nft -s list table inet acceptance_foreign
    nft -s list table ip docker_like
    nft -s list table inet acceptance_nat
}
foreign_snapshot >"$result/foreign.before"
vps_nft_state | jq '.enabled=true' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
probe tcp 10.203.1.1 41000 10.203.1.2 block
probe udp fd90:1::1 41001 fd90:1::2 block
echo 'PASS: INPUT default deny IPv4 TCP and IPv6 UDP'
vps_nft_state | jq '.requirements=[ ["ipv4","ipv6"][] as $f | ["tcp","udp"][] as $p |
 {owner:"accept-service",scope:"accept",kind:"input",family:$f,proto:$p,port:(if $p=="tcp" then "41000,41002,41003" else "41001" end),source:"any",destination:"any",temporary:false}] |
 .links={"accept-service":{detached:false,scope:"accept"}}' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
if [[ "${VPSCTL_NFT_CASE:-}" == ipv6-neighbor ]]; then
    vps_nft_state | jq '.rules=[{id:"ipv6-neighbor-only",action:"allow-only",proto:"any",port:"any",source:"fd90:1::2",family:"ipv6",service:"",comment:"force ND under global ACL",expires_at:0}]' >"$result/candidate.json"
    vps_nft_save_state "$result/candidate.json"; vps_nft_apply
    ip -6 neigh flush dev front
    ip netns exec "$cns" ip -6 neigh flush dev eth0
    client_linklocal="$(ip netns exec "$cns" ip -j -6 address show dev eth0 | jq -er '.[].addr_info[] | select(.scope=="link") | .local')"
    # Resolve a link-local peer outside the allowed global-source set. Its
    # unicast NA must cross prerouting before the global proto:any restriction.
    python3 - "$client_linklocal" <<'PY'
import socket,sys
s=socket.socket(socket.AF_INET6,socket.SOCK_DGRAM)
s.sendto(b'force-neighbor-discovery',(sys.argv[1],59998,0,socket.if_nametoindex('front')))
PY
    for _ in {1..30}; do
        ip -j -6 neigh show dev front >"$result/ipv6-neighbors.json"
        jq -e --arg peer "$client_linklocal" 'any(.[];.dst==$peer and has("lladdr") and any(.state[];.=="REACHABLE" or .=="STALE" or .=="DELAY"))' "$result/ipv6-neighbors.json" >/dev/null && break
        sleep .1
    done
    jq -e --arg peer "$client_linklocal" 'any(.[];.dst==$peer and has("lladdr") and any(.state[];.=="REACHABLE" or .=="STALE" or .=="DELAY"))' "$result/ipv6-neighbors.json" >/dev/null
    probe tcp fd90:1::1 41000 fd90:1::2 allow
    probe tcp fd90:1::1 41000 fd90:1::3 block
    nft -j list table inet vpsctl_firewall >"$result/ipv6-neighbor.ruleset.json"
    vps_nft_clear
    echo 'PASS: global proto:any IPv6 allow-only preserves forced neighbor discovery for allowed source and blocks denied source TCP'
    exit 0
fi
matrix allow
matrix allow 3
echo 'PASS: real IPv4/IPv6 TCP/UDP INPUT and DNAT baseline'
vps_nft_state | jq '.rules=[{id:"source-deny",action:"deny",proto:"both",port:"41000-41001,42000-42001",source:"10.203.1.3,fd90:1::3",family:"both",service:"",comment:"denied client",expires_at:0}]' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
matrix block 3
matrix allow
echo 'PASS: denied sources blocked before INPUT and DNAT for both families/protocols'
vps_nft_state | jq '.rules=[{id:"source-only",action:"allow-only",proto:"both",port:"41000-41001,42000-42001",source:"10.203.1.2,fd90:1::2",family:"both",service:"",comment:"restricted service",expires_at:0}]' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
matrix block 3
matrix allow
nft -a -j list table inet vpsctl_firewall >"$result/sets.before.json"
vps_nft_state | jq '.logging=true' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
nft -a -j list table inet vpsctl_firewall >"$result/sets.after.json"
for stage in before after; do jq -S '[.nftables[].set // empty | {name,handle}]' "$result/sets.$stage.json" >"$result/set-identity.$stage"; done
cmp "$result/set-identity.before" "$result/set-identity.after"
vps_nft_state | jq -e '.rules[0].id=="source-only"' >/dev/null
echo 'PASS: allow-only beats auto permit; unrelated apply retains native set handles and stable rule ID'

expiry=$(($(date +%s)+12))
vps_nft_state | jq --argjson expiry "$expiry" '.rules[0].expires_at=$expiry' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
vps_nft_lock; vps_nft_snapshot "$result/ttl-snapshot"; vps_nft_unlock
probe udp 10.203.1.1 41001 10.203.1.2 allow
sleep 2
vps_nft_apply
sleep 2
vps_nft_lock; vps_nft_restore "$result/ttl-snapshot"; vps_nft_unlock
vps_nft_state | jq -e --argjson expiry "$expiry" '.rules[0].expires_at==$expiry' >/dev/null
remaining=$((expiry-$(date +%s)+1)); ((remaining<=0)) || sleep "$remaining"
matrix block
matrix block 3
vps_nft_apply
matrix block
echo 'PASS: absolute TTL survives reload/restore; expired allow-only never widens INPUT or DNAT'

vps_nft_state | jq '.rules=[] | .logging=false' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
for host in 10.203.1.1 fd90:1::1; do
    if [[ "$host" == *:* ]]; then src=fd90:1::2; else src=10.203.1.2; fi
    probe tcp "$host" 41002 "$src" unlimited
    probe udp "$host" 41001 "$src" unlimited
done
echo 'PASS: rate/concurrency limits are absent until explicitly configured'
vps_nft_state | jq '.limits=[
 {id:"tcp-rate",proto:"tcp",port:"41002",source:"any",family:"both",service:"",rate:"1/hour",burst:2,connections:0},
 {id:"tcp-count",proto:"tcp",port:"41003",source:"any",family:"both",service:"",rate:"",burst:2,connections:2},
 {id:"udp-packets",proto:"udp",port:"41001",source:"any",family:"both",service:"",rate:"1/hour",burst:2,connections:0}]' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
for host in 10.203.1.1 fd90:1::1; do
    if [[ "$host" == *:* ]]; then src=fd90:1::2; else src=10.203.1.2; fi
    probe tcp "$host" 41002 "$src" burst
    probe tcp "$host" 41003 "$src" concurrency
    probe udp "$host" 41001 "$src" udp-packets
done
echo 'PASS: real per-source TCP new-connection rate/concurrency and UDP same-flow packet limits, IPv4/IPv6'

# One-shot native apply failure while a service transaction is preparing additions.
vps_nft_state >"$result/rollback.state.before"
nft -s -j list table inet vpsctl_firewall >"$result/rollback.runtime.before"
mkdir -p "$result/fail-bin"
real_nft="$(command -v nft)"
cat >"$result/fail-bin/nft" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == -f && ! -e '$result/failure-injected' ]]; then
    touch '$result/failure-injected'
    printf 'add rule inet missing_table missing_chain accept\n' | '$real_nft' -f -
    exit 1
fi
exec '$real_nft' "\$@"
EOF
chmod 0700 "$result/fail-bin/nft"
printf '[{"owner":"rollback-service","kind":"input","family":"ipv4","proto":"tcp","port":"49999","source":"any","destination":"any","temporary":false}]\n' >"$result/desired.json"
old_path="$PATH"; PATH="$result/fail-bin:$PATH"
status=0; vps_nft_begin rollback "$result/desired.json" >"$result/injected-apply.log" 2>&1 || status=$?
PATH="$old_path"
[[ "$status" != 0 && -e "$result/failure-injected" && "$VPS_NFT_DEPTH" == 0 ]]
cmp "$result/rollback.state.before" "$VPS_NFT_STATE_FILE"
[[ ! -e "$VPS_NFT_JOURNAL" ]]
# Dynamic meters and counters legitimately change; compare named structure/rules.
nft -s -j list table inet vpsctl_firewall >"$result/rollback.runtime.after"
for stage in before after; do
    jq -S '[.nftables[] | select(has("metainfo")|not) | if .set then .set |= del(.elem) else . end]' \
        "$result/rollback.runtime.$stage" >"$result/rollback.$stage.normalized"
done
cmp "$result/rollback.before.normalized" "$result/rollback.after.normalized"
echo 'PASS: bad native apply rolls back desired state and kernel policy, closes transaction journal'

# Restrict exactly one service's original ingress endpoints, including DNAT.
vps_nft_state | jq '.limits=[] | .requirements += [
 ["ipv4","ipv6"][] as $f |
 {owner:"unrelated-service",scope:"unrelated",kind:"input",family:$f,proto:"tcp",port:"41004",source:"any",destination:"any",temporary:false},
 (["tcp","udp"][] as $p | {owner:"accept-service",scope:"accept",kind:"route",family:$f,proto:$p,
 port:(if $p=="tcp" then "41000" else "41001" end),source:"any",destination:(if $f=="ipv4" then "10.203.2.2" else "fd90:2::2" end),
 original_port:(if $p=="tcp" then "42000" else "42001" end),original_destination:"any",temporary:false})] |
 .links["unrelated-service"]={detached:false,scope:"unrelated"} |
 .rules=[{id:"service-only",action:"allow-only",proto:"both",port:"any",source:"10.203.1.2,fd90:1::2",family:"both",service:"accept-service",comment:"owner restriction",expires_at:0}]' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
matrix block 3
matrix allow
probe tcp 10.203.1.1 41004 10.203.1.3 allow
probe tcp fd90:1::1 41004 fd90:1::3 allow
vps_nft_state | jq '.rules[0].action="deny" | .rules[0].source="10.203.1.3,fd90:1::3"' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
matrix block 3
matrix allow
probe tcp 10.203.1.1 41004 10.203.1.3 allow
probe tcp fd90:1::1 41004 fd90:1::3 allow
echo 'PASS: service-scoped deny/allow-only covers owner INPUT+original DNAT endpoints and preserves unrelated service'

# A global ingress boundary must preserve replies and unrelated transit.
start_server "$cns" 10.203.1.2 41005 udp
start_server "$cns" fd90:1::2 41005 udp
vps_nft_state | jq '.rules=[{id:"ingress-only",action:"allow-only",proto:"both",port:"any",source:"192.0.2.55,2001:db8::55",family:"both",service:"",comment:"ingress boundary",expires_at:0}]' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
python3 "$result/probe.py" udp 10.203.1.2 41005 10.203.1.1 allow
python3 "$result/probe.py" udp fd90:1::2 41005 fd90:1::1 allow
probe tcp 10.203.2.2 41000 10.203.1.2 allow
probe udp 10.203.2.2 41001 10.203.1.2 allow
probe tcp fd90:2::2 41000 fd90:1::2 allow
probe udp fd90:2::2 41001 fd90:1::2 allow
echo 'PASS: global ingress restrictions preserve router-initiated UDP replies and unrelated TCP/UDP transit, IPv4/IPv6'

vps_nft_state | jq '.rules=[]' >"$result/candidate.json"
vps_nft_save_state "$result/candidate.json"; vps_nft_apply
VPSCTL_NFT_LINKAGE_CHILD=1 bash "$TEST_ROOT/tests/integration/test-nftables-linkage-real.sh" "$result" "$cns"
vps_nft_clear
foreign_snapshot >"$result/foreign.after"
cmp "$result/foreign.before" "$result/foreign.after"
echo 'PASS: unknown, Docker-like and foreign DNAT tables unchanged through apply/restore/clear; no global flush'
echo 'PASS: isolated native nftables kernel acceptance'
