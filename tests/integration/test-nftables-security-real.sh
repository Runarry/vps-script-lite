#!/usr/bin/env bash
# Opt-in HTTP-01 lease and real Fail2ban acceptance. Every daemon and firewall
# lives in private network/mount/PID namespaces; host services are never called.
# shellcheck disable=SC1091,SC2016,SC2034
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"

if [[ "${1:-}" != --inside ]]; then
    [[ "${VPSCTL_REAL_NFT_SECURITY_TEST:-0}" == 1 ]] || {
        printf 'SKIP: set VPSCTL_REAL_NFT_SECURITY_TEST=1 on host-vps-scripts\n'
        exit 0
    }
    ((EUID == 0)) || {
        printf 'BLOCKED: root required\n'
        exit 3
    }
    for tool in unshare nsenter mount ip nft jq python3 curl fail2ban-server fail2ban-client sshd ssh-keygen; do
        command -v "$tool" >/dev/null || {
            printf 'BLOCKED: missing %s\n' "$tool"
            exit 3
        }
    done
    result="${VPSCTL_NFT_SECURITY_RESULTS:-/var/tmp/vpsctl-nft-engine/security}/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p -- "$result"
    printf '%s\n' "$(readlink /proc/self/ns/net)" >"$result/outer-network-namespace"
    status=0
    unshare --net --mount --pid --fork --mount-proc --kill-child=TERM \
        bash "$0" --inside "$result" 2>&1 | tee "$result/acceptance.log" || status=${PIPESTATUS[0]}
    printf 'INFO: evidence=%s exit=%s\n' "$result" "$status"
    exit "$status"
fi

RESULT="$2"
mount --make-rprivate /
mount -t tmpfs -o mode=0755 tmpfs /run
mkdir -p /run/sshd
[[ "$(readlink /proc/self/ns/net)" != "$(<"$RESULT/outer-network-namespace")" ]] || exit 3
[[ "$(nft -j list tables | jq '.nftables|map(select(.table!=null))|length')" == 0 ]] || exit 3
source "$TEST_ROOT/commands/security/fail2ban.sh"
source "$TEST_ROOT/commands/security/tls/nftables.sh"
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$RESULT/root" VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1
VPSCTL_DRY_RUN=0
mkdir -p -- "$VPSCTL_SYSTEM_ROOT/run"
vps_cmd_init nft-security-real "$TEST_ROOT"
vps_nft_init
PEER_PID='' TLS_PID='' PROBE_PID='' SSH_PID='' F2B_PID=''
F2B_SOCKET="$RESULT/fail2ban.sock"
F2B_CONFIG="$RESULT/fail2ban"

cleanup() {
    local status=$? pid failed=0
    trap - EXIT HUP INT TERM
    if [[ -S "$F2B_SOCKET" ]]; then
        fail2ban-client -s "$F2B_SOCKET" stop >"$RESULT/fail2ban-stop.log" 2>&1 || failed=1
    fi
    for pid in "$TLS_PID" "$PROBE_PID" "$SSH_PID" "$F2B_PID" "$PEER_PID"; do
        [[ -z "$pid" ]] || kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "$TLS_PID" "$PROBE_PID" "$SSH_PID" "$F2B_PID" "$PEER_PID"; do
        [[ -z "$pid" ]] || wait "$pid" 2>/dev/null || true
    done
    nft -j list ruleset >"$RESULT/final-ruleset.json" 2>/dev/null || true
    [[ ! -S "$F2B_SOCKET" ]] || failed=1
    printf 'cleanup_status=%s test_status=%s\n' "$failed" "$status" >"$RESULT/cleanup.txt"
    ((status != 0)) || status="$failed"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP
trap 'exit 130' INT
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
assert_json() { jq -e "$2" <<<"$1" >/dev/null || fail "$3"; }
wait_file() {
    local file="$1" pid="$2"
    for _ in {1..100}; do
        [[ ! -e "$file" ]] || return 0
        kill -0 "$pid" 2>/dev/null || fail "process $pid exited before $file"
        sleep .05
    done
    fail "timed out waiting for $file"
}
save() {
    jq "$1" <<<"$(vps_nft_state)" >"$RESULT/candidate.json"
    vps_nft_save_state "$RESULT/candidate.json"
    vps_nft_apply
}
set_owner() {
    local scope="$1" owner="$2" port="$3"
    jq -n --arg owner "$owner" --arg port "$port" \
        '["ipv4","ipv6"]|map({owner:$owner,kind:"input",family:.,proto:"tcp",port:$port,source:"any",destination:"any",temporary:false})' \
        >"$RESULT/desired.json"
    vps_nft_begin "$scope" "$RESULT/desired.json"
    vps_nft_commit
}

unshare --net sleep infinity &
PEER_PID=$!
for _ in {1..100}; do
    [[ "$(readlink "/proc/$PEER_PID/ns/net")" == "$(readlink /proc/self/ns/net)" ]] || break
    sleep .02
done
ip link set lo up
ip link add front type veth peer name peer0
ip link set peer0 netns "$PEER_PID"
ip address add 10.207.91.1/24 dev front
ip -6 address add fd92:207::1/64 dev front nodad
ip link set front up
nsenter -t "$PEER_PID" -n ip link set lo up
nsenter -t "$PEER_PID" -n ip address add 10.207.91.2/24 dev peer0
nsenter -t "$PEER_PID" -n ip address add 10.207.91.3/24 dev peer0
nsenter -t "$PEER_PID" -n ip -6 address add fd92:207::2/64 dev peer0 nodad
nsenter -t "$PEER_PID" -n ip link set peer0 up

{
    date -u --iso-8601=seconds
    uname -a
    nft --version
    fail2ban-client --version
    readlink /proc/self/ns/net
    sha256sum "$TEST_ROOT/lib/nftables.sh" "$TEST_ROOT"/lib/nftables/* \
        "$TEST_ROOT/commands/security/tls/nftables.sh" "$TEST_ROOT/commands/security/fail2ban.sh" "$0"
} >"$RESULT/code-state.txt"

cat >"$RESULT/fake-lego" <<'PY'
#!/usr/bin/env python3
import http.server, os, pathlib, signal, socket, sys
ready, release, exit_code = sys.argv[1:]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"vpsctl-http01-proof"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
class Server(http.server.HTTPServer):
    address_family = socket.AF_INET6
    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()
def terminate(signum, frame):
    raise SystemExit(128 + signum)
signal.signal(signal.SIGTERM, terminate)
with Server(("::", 80), Handler) as server:
    server.timeout = .05
    pathlib.Path(ready).write_text(str(os.getpid()))
    while not pathlib.Path(release).exists():
        server.handle_request()
sys.exit(int(exit_code))
PY
chmod 0700 "$RESULT/fake-lego"
TLS_LEGO_BIN="$RESULT/fake-lego"

http_probe() {
    local expected="$1" family="$2" destination source body status=0
    if [[ "$family" == ipv4 ]]; then
        destination='10.207.91.1'
        source='10.207.91.2'
    else
        destination='[fd92:207::1]'
        source='fd92:207::2'
    fi
    body="$(nsenter -t "$PEER_PID" -n curl --noproxy '*' -g -sS --max-time 1 --interface "$source" \
        "http://$destination/.well-known/acme-challenge/test-token" 2>/dev/null)" || status=$?
    if [[ "$expected" == allow ]]; then
        [[ "$status" == 0 && "$body" == vpsctl-http01-proof ]] || fail "HTTP $family should be allowed"
    else [[ "$status" != 0 ]] || fail "HTTP $family authorization was not released"; fi
}
start_probe() {
    local label="$1"
    "$RESULT/fake-lego" "$RESULT/$label.ready" "$RESULT/$label.release" 0 >"$RESULT/$label.log" 2>&1 &
    PROBE_PID=$!
    wait_file "$RESULT/$label.ready" "$PROBE_PID"
}
stop_probe() {
    kill -TERM "$PROBE_PID"
    wait "$PROBE_PID" 2>/dev/null || true
    PROBE_PID=''
}
assert_released() {
    assert_json "$(vps_nft_state)" 'all(.requirements[];.temporary!=true) and (.leases|length)==0' 'HTTP-01 lease leaked'
}
run_challenge_case() {
    local label="$1" mode="$2" exit_code="$3" expected="$4" status=0 child
    (
        tls_install_cleanup_traps
        tls_run_challenge http-01 '' "$RESULT/$label.ready" "$RESULT/$label.release" "$exit_code"
    ) >"$RESULT/$label.log" 2>&1 &
    TLS_PID=$!
    wait_file "$RESULT/$label.ready" "$TLS_PID"
    child="$(<"$RESULT/$label.ready")"
    vps_nft_state >"$RESULT/$label.during.json"
    assert_json "$(vps_nft_state)" 'any(.requirements[];.temporary and .port=="80") and (.leases|length)==1' 'HTTP-01 lease was not live'
    vps_nft_lock
    vps_nft_unlock
    http_probe allow ipv4
    http_probe allow ipv6
    if [[ "$mode" == term ]]; then kill -TERM "$TLS_PID"; else touch "$RESULT/$label.release"; fi
    wait "$TLS_PID" || status=$?
    TLS_PID=''
    [[ "$status" == "$expected" ]] || fail "$label returned $status instead of $expected"
    if kill -0 "$child" 2>/dev/null; then fail "$label left the challenge listener alive"; fi
    assert_released
    vps_nft_state >"$RESULT/$label.after.json"
    printf 'PASS: HTTP-01 %s status=%s, real IPv4/IPv6 HTTP during lease, demand/child released\n' "$label" "$status"
}

save '.enabled=true'
for mode in success failure term; do
    case "$mode" in
        success) run_challenge_case "$mode" release 0 0 ;;
        failure) run_challenge_case "$mode" release 7 7 ;;
        term) run_challenge_case "$mode" term 0 143 ;;
    esac
    start_probe "after-$mode"
    http_probe block ipv4
    http_probe block ipv6
    stop_probe
done
save '.rules=[{id:"manual-http",action:"allow",proto:"tcp",port:"80",source:"any",family:"both",service:"",comment:"acceptance",expires_at:0}]'
set_owner fixture-http node:other-http 80
run_challenge_case shared release 0 0
assert_json "$(vps_nft_state)" 'any(.rules[];.id=="manual-http") and any(.requirements[];.owner=="node:other-http")' 'lease release removed manual/shared owner'
start_probe preserved
http_probe allow ipv4
printf '[]\n' >"$RESULT/desired.json"
vps_nft_begin fixture-http "$RESULT/desired.json"
vps_nft_commit
http_probe allow ipv4
save '.rules=[]'
http_probe block ipv4
stop_probe
printf 'PASS: HTTP-01 release preserves independent owner and manual grants; removing final grant closes TCP80\n'

# The real production selector and renderer choose the shipped native action.
FAIL2BAN_BANACTION="$(fail2ban_detect_banaction)"
[[ "$FAIL2BAN_BANACTION" == nftables-multiport ]] || fail 'production action selector did not choose native nftables'
FAIL2BAN_PORT=2222 FAIL2BAN_BANTIME=10m FAIL2BAN_INCREMENT=off
FAIL2BAN_IGNORE=(127.0.0.1/8 ::1)
mkdir -p -- "$F2B_CONFIG/jail.d"
cp /etc/fail2ban/fail2ban.conf /etc/fail2ban/jail.conf /etc/fail2ban/paths-*.conf "$F2B_CONFIG/"
cp -a /etc/fail2ban/action.d /etc/fail2ban/filter.d "$F2B_CONFIG/"
cat >"$F2B_CONFIG/fail2ban.local" <<EOF
[DEFAULT]
logtarget = $RESULT/fail2ban.log
socket = $F2B_SOCKET
pidfile = $RESULT/fail2ban.pid
dbfile = $RESULT/fail2ban.sqlite3
EOF
fail2ban_emit_config >"$F2B_CONFIG/jail.d/99-vpsctl-sshd.local"
cat >>"$F2B_CONFIG/jail.d/99-vpsctl-sshd.local" <<EOF
# Isolation fixture: exercise the shipped sshd filter without host journal.
backend = polling
logpath = $RESULT/auth.log
EOF
: >"$RESULT/auth.log"
fail2ban-client -c "$F2B_CONFIG" -s "$F2B_SOCKET" -p "$RESULT/fail2ban.pid" -t >"$RESULT/fail2ban-config-check.log" 2>&1
fail2ban-server -f -c "$F2B_CONFIG" -s "$F2B_SOCKET" -p "$RESULT/fail2ban.pid" start >"$RESULT/fail2ban-server.log" 2>&1 &
F2B_PID=$!
for _ in {1..100}; do
    if fail2ban-client -s "$F2B_SOCKET" ping >/dev/null 2>&1; then break; fi
    kill -0 "$F2B_PID" 2>/dev/null || fail 'private Fail2ban daemon exited'
    sleep .05
done
fail2ban-client -s "$F2B_SOCKET" status sshd >"$RESULT/fail2ban-status.txt"
fail2ban-client -s "$F2B_SOCKET" get sshd actions >"$RESULT/fail2ban-actions.txt"
grep -q nftables-multiport "$RESULT/fail2ban-actions.txt" || fail 'shipped nftables action not loaded'

ssh-keygen -q -t ed25519 -N '' -f "$RESULT/ssh-host-key"
cat >"$RESULT/sshd_config" <<EOF
Port 2222
ListenAddress 10.207.91.1
HostKey $RESULT/ssh-host-key
PidFile $RESULT/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile none
PermitRootLogin no
UseDNS no
EOF
"$(command -v sshd)" -t -f "$RESULT/sshd_config"
"$(command -v sshd)" -D -e -f "$RESULT/sshd_config" >"$RESULT/sshd.log" 2>&1 &
SSH_PID=$!
set_owner ssh ssh 2222
cat >"$RESULT/ssh-banner.py" <<'PY'
import socket, sys
source, expected = sys.argv[1:]
allowed = False
with socket.socket() as client:
    client.settimeout(1)
    client.bind((source, 0))
    try:
        client.connect(("10.207.91.1", 2222))
        allowed = client.recv(256).startswith(b"SSH-")
    except OSError:
        pass
assert allowed == (expected == "allow"), (source, expected, allowed)
PY
ssh_probe() { nsenter -t "$PEER_PID" -n python3 "$RESULT/ssh-banner.py" "$1" "$2"; }
ssh_probe 10.207.91.2 allow
fail2ban-client -s "$F2B_SOCKET" set sshd banip 10.207.91.2 >"$RESULT/ban.txt"
for _ in {1..100}; do
    if nft -j list table inet f2b-table >"$RESULT/fail2ban-native.json" 2>/dev/null &&
        jq -e 'any(.nftables[];.set.elem!=null and (.set.elem|index("10.207.91.2"))!=null)' "$RESULT/fail2ban-native.json" >/dev/null; then break; fi
    sleep .05
done
ssh_probe 10.207.91.2 block
ssh_probe 10.207.91.3 allow
nft -j list table inet f2b-table | jq -S '.nftables|map(select(.metainfo==null))' >"$RESULT/ban-before-reload.json"
vps_nft_apply
ssh_probe 10.207.91.2 block
save '.rules += [{id:"unrelated-edit",action:"allow",proto:"tcp",port:"3333",source:"any",family:"ipv4",service:"",expires_at:0}]'
ssh_probe 10.207.91.2 block
nft -j list table inet f2b-table | jq -S '.nftables|map(select(.metainfo==null))' >"$RESULT/ban-after-edit.json"
cmp "$RESULT/ban-before-reload.json" "$RESULT/ban-after-edit.json" || fail 'manager reload/edit changed real Fail2ban table'
fail2ban-client -s "$F2B_SOCKET" get sshd banip >"$RESULT/ban-retained.txt"
grep -q 10.207.91.2 "$RESULT/ban-retained.txt" || fail 'daemon lost its active ban'
fail2ban-client -s "$F2B_SOCKET" set sshd unbanip 10.207.91.2 >"$RESULT/unban.txt"
ssh_probe 10.207.91.2 allow
printf 'PASS: real Fail2ban sshd jail + shipped nftables-multiport action bans TCP, survives manager reload/rule edit, unban restores SSH banner\n'
printf 'PASS: isolated security acceptance; fake lego only, no ACME issuance or host SSH policy test claimed\n'
