#!/usr/bin/env bash
# Real installed relay runtime, isolated from the host by network/mount namespaces.
# Only the service manager is replaced; DNS, nft, sysctls and traffic are real.
# shellcheck disable=SC1091,SC2034,SC2016
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" != --inside ]]; then
    [[ "${VPSCTL_NFT_FORWARD_RUNTIME_REAL:-0}" == 1 ]] || {
        printf 'SKIP: set VPSCTL_NFT_FORWARD_RUNTIME_REAL=1 on the dedicated host\n'
        exit 0
    }
    ((EUID == 0)) || fail 'namespace acceptance requires root'
    for tool in unshare nsenter mount ip nft python3 jq getent sysctl pgrep sha256sum; do
        command -v "$tool" >/dev/null || fail "missing $tool"
    done
    evidence="${VPSCTL_NFT_FORWARD_RUNTIME_RESULTS:-$(mktemp -d /var/tmp/vpsctl-nft-forward-runtime.XXXXXX)}"
    mkdir -p -- "$evidence"
    evidence="$(cd -- "$evidence" && pwd -P)"
    [[ ! -e "$evidence/system-root" ]] || fail 'results contain a previous run; choose a fresh evidence directory'
    TEST_HOST_NETNS="$(readlink /proc/self/ns/net)"
    TEST_HOST_MNTNS="$(readlink /proc/self/ns/mnt)"
    export TEST_HOST_NETNS TEST_HOST_MNTNS
    sha256sum /etc/hosts >"$evidence/host-hosts.before.sha256"
    status=0
    unshare --net --mount --propagation private --fork \
        bash "${BASH_SOURCE[0]}" --inside "$evidence" >"$evidence/acceptance.log" 2>&1 || status=$?
    sha256sum /etc/hosts >"$evidence/host-hosts.after.sha256"
    cat "$evidence/acceptance.log"
    cmp -s "$evidence/host-hosts.before.sha256" "$evidence/host-hosts.after.sha256" || fail 'host hosts changed during acceptance'
    printf 'evidence=%s\n' "$evidence"
    exit "$status"
fi

EVIDENCE="$2"
[[ "$(readlink /proc/self/ns/net)" != "$TEST_HOST_NETNS" ]] || fail 'network namespace was not isolated'
[[ "$(readlink /proc/self/ns/mnt)" != "$TEST_HOST_MNTNS" ]] || fail 'mount namespace was not isolated'
printf 'network=%s mount=%s host_network=%s host_mount=%s\n' \
    "$(readlink /proc/self/ns/net)" "$(readlink /proc/self/ns/mnt)" "$TEST_HOST_NETNS" "$TEST_HOST_MNTNS" >"$EVIDENCE/namespaces.txt"
ROOT="$EVIDENCE/system-root"
mkdir -p "$ROOT/usr/local/libexec" "$ROOT/etc" "$ROOT/run" "$EVIDENCE/bin" "$EVIDENCE/batches"
cp -- /etc/hosts "$EVIDENCE/hosts.original"
cp -- /etc/hosts "$ROOT/etc/hosts"
mount --bind "$ROOT/etc/hosts" /etc/hosts
# The installed helper has a production absolute runtime path. Bind its private
# installation prefix rather than editing generated code or host directories.
mount --bind "$ROOT/usr/local" /usr/local
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$ROOT" VPSCTL_ENV_INIT=systemd
export VPSCTL_ENV_OS_ID=debian VPSCTL_ENV_OS_VERSION=12 VPSCTL_ENV_PACKAGE_MANAGER=apt
export VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1 VPSCTL_ASSUME_YES=1
export PROXY_RELAY_FORWARD_ALLOW_TEST_RUNTIME=1 EVIDENCE
export PATH="$EVIDENCE/bin:$PATH"
REAL_NFT="$(command -v nft)"
REAL_MV="$(command -v mv)"
export REAL_NFT REAL_MV
WATCH_PID='' CLIENT_PID='' SERVER_PID='' ECHO_PID=''

cleanup() {
    local status=$? pid child
    trap - EXIT INT TERM HUP
    if [[ -s "$EVIDENCE/watch.pid" ]]; then WATCH_PID="$(<"$EVIDENCE/watch.pid")"; fi
    for pid in "$WATCH_PID" "$ECHO_PID" "$CLIENT_PID" "$SERVER_PID"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        while IFS= read -r child; do
            [[ "$child" =~ ^[1-9][0-9]*$ ]] || continue
            kill -TERM "$child" 2>/dev/null || true
        done < <(pgrep -P "$pid" || true)
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
trap 'printf "FAIL: status=%s line=%s function=%s\n" "$?" "$LINENO" "${FUNCNAME[0]:-main}" >&2' ERR

# Reject every unexpected systemctl action so the host systemd socket is never
# contacted. enable/start still runs the actual installed helper watch process.
cat >"$EVIDENCE/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$EVIDENCE/systemctl.calls"
case "$*" in
    daemon-reload) exit 0 ;;
    'show --property=LoadState --value vpsctl-proxy-forward.service') printf 'loaded\n' ;;
    'enable --now vpsctl-proxy-forward.service')
        /usr/local/libexec/vpsctl-proxy-forward-refresh watch >>"$EVIDENCE/watch.log" 2>&1 &
        printf '%s\n' "$!" >"$EVIDENCE/watch.pid"
        exit 0 ;;
    'is-active --quiet vpsctl-proxy-forward.service'|'is-enabled --quiet vpsctl-proxy-forward.service')
        [[ -s "$EVIDENCE/watch.pid" ]] && kill -0 "$(<"$EVIDENCE/watch.pid")" 2>/dev/null ;;
    *) printf 'Unexpected isolated systemctl: %s\n' "$*" >&2; exit 99 ;;
esac
SH
cat >"$EVIDENCE/bin/nft" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s parent=%s\n' "$*" "$(tr '\0' ' ' <"/proc/$PPID/cmdline")" >>"$EVIDENCE/nft.calls"
if [[ "${1:-}" == -f && -f "${2:-}" ]]; then
    cp -- "$2" "$EVIDENCE/batches/$(date +%s%N)-$BASHPID.nft"
fi
exec "$REAL_NFT" "$@"
SH
cat >"$EVIDENCE/bin/mv" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
target="${!#}"
if [[ "$target" == "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/service/proxy/relay-resolved.json" && -e "$EVIDENCE/fail-cache-publish" ]]; then
    rm -f -- "$EVIDENCE/fail-cache-publish"
    printf '%s\n' "$*" >"$EVIDENCE/cache-publish.injected"
    exit 42
fi
exec "$REAL_MV" "$@"
SH
chmod 0755 "$EVIDENCE/bin/"*

unshare --net -- bash -c 'touch "$1"; exec sleep 600' bash "$EVIDENCE/client.ready" &
CLIENT_PID=$!
unshare --net -- bash -c 'touch "$1"; exec sleep 600' bash "$EVIDENCE/server.ready" &
SERVER_PID=$!
for _attempt in {1..100}; do
    [[ ! -e "$EVIDENCE/client.ready" || ! -e "$EVIDENCE/server.ready" ]] || break
    sleep 0.02
done
[[ -e "$EVIDENCE/client.ready" && -e "$EVIDENCE/server.ready" ]] || fail 'peer namespaces did not start'
ip link set lo up
ip link add ingress type veth peer name client
ip link add egress type veth peer name server
ip link set client netns "$CLIENT_PID"
ip link set server netns "$SERVER_PID"
ip address add 192.0.2.1/24 dev ingress
ip -6 address add 2001:db8:1::1/64 dev ingress nodad
ip address add 198.51.100.1/24 dev egress
ip -6 address add 2001:db8:2::1/64 dev egress nodad
ip link set ingress up
ip link set egress up
nsenter -t "$CLIENT_PID" -n ip link set lo up
nsenter -t "$CLIENT_PID" -n ip address add 192.0.2.2/24 dev client
nsenter -t "$CLIENT_PID" -n ip -6 address add 2001:db8:1::2/64 dev client nodad
nsenter -t "$CLIENT_PID" -n ip link set client up
nsenter -t "$SERVER_PID" -n ip link set lo up
for suffix in 41 42 43; do
    nsenter -t "$SERVER_PID" -n ip address add "198.51.100.$suffix/24" dev server
    nsenter -t "$SERVER_PID" -n ip -6 address add "2001:db8:2::$suffix/64" dev server nodad
done
nsenter -t "$SERVER_PID" -n ip link set server up
sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1

cat >"$EVIDENCE/echo.py" <<'PY'
import selectors, socket, sys
selector = selectors.DefaultSelector()
for suffix in (41, 42, 43):
    for family, address in ((socket.AF_INET, f'198.51.100.{suffix}'), (socket.AF_INET6, f'2001:db8:2::{suffix}')):
        for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
            sock = socket.socket(family, kind)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            sock.bind((address, 44101))
            if kind == socket.SOCK_STREAM:
                sock.listen(16)
            selector.register(sock, selectors.EVENT_READ, (kind, suffix))
open(sys.argv[1], 'w').write('ready\n')
while True:
    for key, _ in selector.select():
        kind, suffix = key.data
        if kind == socket.SOCK_STREAM:
            connection, _ = key.fileobj.accept()
            with connection:
                connection.settimeout(3)
                data = connection.recv(100)
                connection.sendall(str(suffix).encode() + b':' + data)
        else:
            data, peer = key.fileobj.recvfrom(100)
            key.fileobj.sendto(str(suffix).encode() + b':' + data, peer)
PY
cat >"$EVIDENCE/probe.py" <<'PY'
import socket, sys
expected = sys.argv[1].encode() + b':probe'
for family, address in ((socket.AF_INET, '192.0.2.1'), (socket.AF_INET6, '2001:db8:1::1')):
    for kind, protocol in ((socket.SOCK_STREAM, 'tcp'), (socket.SOCK_DGRAM, 'udp')):
        with socket.socket(family, kind) as sock:
            sock.settimeout(4)
            sock.connect((address, 45101))
            sock.sendall(b'probe')
            received = sock.recv(100)
            if received != expected:
                raise SystemExit(f'FAIL: {address} {protocol}: {received!r} != {expected!r}')
            print(f'PASS: target={sys.argv[1]} {address} {protocol} DNAT echo')
PY
nsenter -t "$SERVER_PID" -n python3 -B "$EVIDENCE/echo.py" "$EVIDENCE/echo.ready" >"$EVIDENCE/echo.log" 2>&1 &
ECHO_PID=$!
for _attempt in {1..100}; do [[ ! -e "$EVIDENCE/echo.ready" ]] || break; sleep 0.02; done
[[ -e "$EVIDENCE/echo.ready" ]] || fail 'dual-stack echo targets did not start'

PROXY_PROJECT_ROOT="$TEST_ROOT"
source "$TEST_ROOT/lib/command.sh"
vps_cmd_init 'isolated installed relay runtime' "$TEST_ROOT"
source "$TEST_ROOT/lib/nftables.sh"
source "$TEST_ROOT/commands/service/proxy/common.sh"
source "$TEST_ROOT/commands/service/proxy/nftables.sh"
source "$TEST_ROOT/commands/service/proxy/relay-forward.sh"
source "$TEST_ROOT/commands/service/proxy/relay.sh"
proxy_common_init
proxy_relay_init
proxy_relay_forward_init
mkdir -p "$PROXY_STATE_DIR"
proxy_manifest_default >"$PROXY_MANIFEST"
TARGET_HOST=relay-runtime.vpsctl.invalid
EXIT_ID=exit-0000000000000041
FORWARD_ID=forward-0000000000000041
write_hosts() {
    cat "$EVIDENCE/hosts.original" >"$ROOT/etc/hosts"
    printf '198.51.100.%s %s\n2001:db8:2::%s %s\n' "$1" "$TARGET_HOST" "$1" "$TARGET_HOST" >>"$ROOT/etc/hosts"
}
write_hosts 41
jq -n --arg host "$TARGET_HOST" --arg exit "$EXIT_ID" --arg forward "$FORWARD_ID" '
  {schema_version:1,exits:[{id:$exit,name:"runtime acceptance",type:"direct",endpoint:{host:$host,port:44101},network_hint:"both",created_at:"2026-11-01T00:00:00Z",updated_at:"2026-11-01T00:00:00Z"}],bindings:[],
   forwards:[{id:$forward,name:"runtime acceptance",exit_id:$exit,listen_port_start:45101,listen_port_end:45101,network:"both",family:"dual",publish_address:"relay.example",created_at:"2026-11-01T00:00:00Z",updated_at:"2026-11-01T00:00:00Z"}]}' >"$PROXY_RELAY_FILE"
chmod 0600 "$PROXY_MANIFEST" "$PROXY_RELAY_FILE"
vps_nft_init
vps_nft_state | jq '.enabled=true' >"$EVIDENCE/firewall.initial.json"
vps_nft_save_state "$EVIDENCE/firewall.initial.json"
vps_nft_apply
nft add table inet runtime_sentinel
nft add chain inet runtime_sentinel keep
nft add rule inet runtime_sentinel keep counter comment independent
nft -s list table inet runtime_sentinel >"$EVIDENCE/independent.before.nft"

proxy_relay_forward_install_service
WATCH_PID="$(<"$EVIDENCE/watch.pid")"
for _attempt in {1..400}; do
    kill -0 "$WATCH_PID" 2>/dev/null || fail 'installed watch process stopped'
    pgrep -P "$WATCH_PID" -x sleep >/dev/null 2>&1 && break
    sleep 0.05
done
pgrep -P "$WATCH_PID" -x sleep >/dev/null || fail 'installed watch never completed its first refresh'
tr '\0' ' ' <"/proc/$WATCH_PID/cmdline" >"$EVIDENCE/watch.cmdline"
grep -Fq '/usr/local/libexec/vpsctl-proxy-forward-refresh watch' "$EVIDENCE/watch.cmdline" || fail 'watch did not run installed helper'
for module in schema.jq render.jq reconcile.jq transactions.sh; do
    cmp -s "$TEST_ROOT/lib/nftables/$module" "$PROXY_RELAY_FORWARD_RUNTIME/lib/nftables/$module" || fail "installed runtime omitted $module"
done
cmp -s "$TEST_ROOT/lib/nftables.sh" "$PROXY_RELAY_FORWARD_RUNTIME/lib/nftables.sh" || fail 'installed shared library differs'
grep -Fq '/usr/local/libexec/vpsctl-proxy-runtime/commands/service/proxy.sh' "$EVIDENCE/nft.calls" || fail 'nft was never called from installed runtime'
printf 'PASS: production installer deployed native dependencies and actual helper watch\n'

assert_target() {
    local suffix="$1" rejected="${2:-}"
    jq -e --arg id "$EXIT_ID" --arg v4 "198.51.100.$suffix" --arg v6 "2001:db8:2::$suffix" \
        '.exits[$id].ipv4==$v4 and .exits[$id].ipv6==$v6' "$PROXY_RELAY_FORWARD_CACHE" >/dev/null || fail 'DNS cache target mismatch'
    jq -e --arg owner "forward:$FORWARD_ID" --arg v4 "198.51.100.$suffix" --arg v6 "2001:db8:2::$suffix" '
        [.requirements[]|select(.owner==$owner)] | length==4 and
        all(.[];.kind=="route" and .port=="44101" and .original_port=="45101" and (.destination==$v4 or .destination==$v6))' "$VPS_NFT_STATE_FILE" >/dev/null || fail 'native shared route ownership mismatch'
    nft -j list table ip vpsctl_proxy_forward4 | jq -e --arg address "198.51.100.$suffix" \
        'any(.nftables[].rule.expr[]?;.dnat.addr==$address and .dnat.port==44101)' >/dev/null || fail 'IPv4 DNAT target mismatch'
    nft -j list table ip6 vpsctl_proxy_forward6 | jq -e --arg address "2001:db8:2::$suffix" \
        'any(.nftables[].rule.expr[]?;.dnat.addr==$address and .dnat.port==44101)' >/dev/null || fail 'IPv6 DNAT target mismatch'
    if [[ -n "$rejected" ]]; then
        jq -e --arg old4 "198.51.100.$rejected" --arg old6 "2001:db8:2::$rejected" 'all(.requirements[];.destination!=$old4 and .destination!=$old6)' "$VPS_NFT_STATE_FILE" >/dev/null || fail 'stale target requirement retained'
    fi
    nsenter -t "$CLIENT_PID" -n python3 -B "$EVIDENCE/probe.py" "$suffix"
}
snapshot_tables() {
    local label="$1" family table
    for family in inet ip ip6; do
        case "$family" in inet) table=vpsctl_firewall ;; ip) table=vpsctl_proxy_forward4 ;; ip6) table=vpsctl_proxy_forward6 ;; esac
        nft -s list table "$family" "$table" >"$EVIDENCE/$label.$family.nft"
    done
}
assert_target 41
write_hosts 42
/usr/local/libexec/vpsctl-proxy-forward-refresh refresh
assert_target 42 41
printf 'PASS: installed helper refreshed real hosts DNS and all four DNAT traffic paths\n'

cp -- "$PROXY_RELAY_FORWARD_CACHE" "$EVIDENCE/cache.before.json"
cp -- "$VPS_NFT_STATE_FILE" "$EVIDENCE/state.before.json"
cp -- "$VPS_NFT_APPLIED_FILE" "$EVIDENCE/applied.before.json"
snapshot_tables before-failure
write_hosts 43
: >"$EVIDENCE/fail-cache-publish"
failure=0
/usr/local/libexec/vpsctl-proxy-forward-refresh refresh >"$EVIDENCE/failure.log" 2>&1 || failure=$?
[[ "$failure" == 20 ]] || fail "publish failure returned $failure instead of 20"
[[ -s "$EVIDENCE/cache-publish.injected" ]] || fail 'cache publish failure was not injected'
cmp -s "$PROXY_RELAY_FORWARD_CACHE" "$EVIDENCE/cache.before.json" || fail 'cache did not roll back exactly'
cmp -s "$VPS_NFT_STATE_FILE" "$EVIDENCE/state.before.json" || fail 'native state did not roll back exactly'
cmp -s "$VPS_NFT_APPLIED_FILE" "$EVIDENCE/applied.before.json" || fail 'native applied manifest did not roll back exactly'
snapshot_tables after-failure
for family in inet ip ip6; do
    cmp -s "$EVIDENCE/before-failure.$family.nft" "$EVIDENCE/after-failure.$family.nft" || fail "$family runtime did not roll back exactly"
done
[[ ! -e "$VPS_NFT_JOURNAL" ]] || fail 'publish rollback left a native transaction journal'
grep -Fq '198.51.100.43' "$EVIDENCE/batches/"*.nft || fail 'candidate native batch was never submitted'
assert_target 42 43
nft -s list table inet runtime_sentinel >"$EVIDENCE/independent.after.nft"
cmp -s "$EVIDENCE/independent.before.nft" "$EVIDENCE/independent.after.nft" || fail 'independent nft table changed'
printf 'PASS: injected cache publish failure restored cache/state/applied/native tables and all four traffic paths\n'
printf 'PASS: isolated installed relay runtime acceptance\n'
