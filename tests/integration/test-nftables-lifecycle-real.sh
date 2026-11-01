#!/usr/bin/env bash
# Opt-in live lifecycle acceptance for the dedicated host-vps-scripts environment.
# The hold mode lets a second SSH session verify access before cleanup restores it.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
[[ "${VPSCTL_REAL_NFT_LIFECYCLE:-0}" == 1 ]] || {
    printf 'SKIP: dedicated host opt-in required\n'
    exit 0
}
((EUID == 0)) || exit 4
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RESULT="${VPSCTL_NFT_LIFECYCLE_RESULT:?set dedicated evidence directory}"
mkdir -p -- "$RESULT"
exec > >(tee -a "$RESULT/acceptance.log") 2>&1
CLI=(bash "$ROOT/bin/vpsctl" --no-color --non-interactive --yes)
PREFIX="vnft${BASHPID}"
NS="${PREFIX}c"
HOST_IF="${PREFIX}h"
PEER_IF="${PREFIX}p"
IP=198.19.254.1
CONTAINER="vpsctl-nft-accept-${BASHPID}"
IMAGE=busybox:1.37.0
IMAGE_CREATED=0
HTTP_PID=''
BACKUP=''
NATIVE_STATE_BEFORE=0
[[ ! -e /var/lib/vpsctl/security/access/active ]] || {
    printf 'FAIL: SSH transaction already pending\n'
    exit 3
}
[[ ! -e /etc/po0-relay/state.tsv ]] || {
    printf 'FAIL: lifecycle fixture expects no host PO0; isolated PO0 suite covers coexistence\n'
    exit 3
}
[[ ! -e /var/lib/vpsctl/network/nftables/state.json ]] || NATIVE_STATE_BEFORE=1
[[ "$NATIVE_STATE_BEFORE" == 0 ]] || {
    printf 'FAIL: native state already exists; preserve it and use an isolated fixture\n'
    exit 3
}
for tool in nft jq docker ip curl python3 sha256sum ss; do command -v "$tool" >/dev/null || exit 3; done
for port in 58931 58932; do [[ -z "$(ss -H -ltn "sport = :$port")" ]] || exit 3; done
normalized_foreign() {
    nft -j list ruleset | jq -cS '[.nftables[] | select(has("metainfo")|not) |
      select((.table.name // .chain.table // .rule.table // .set.table // .map.table // .counter.table // "")!="vpsctl_firewall") |
      walk(if type=="object" then del(.handle,.packets,.bytes) else . end)] | sort_by(tostring)'
}
cleanup() {
    local status=$? tx='' failed=0
    trap - EXIT HUP INT TERM
    if [[ -f "$RESULT/access-transaction" && -f /var/lib/vpsctl/security/access/active ]]; then
        tx="$(<"$RESULT/access-transaction")"
        "${CLI[@]}" security access ssh abort --transaction "$tx" || failed=1
    fi
    if [[ -n "$BACKUP" ]]; then
        "${CLI[@]}" network nftables restore "$BACKUP" || failed=1
    fi
    if [[ "$failed" == 0 && "$NATIVE_STATE_BEFORE" == 0 ]]; then
        rm -rf -- /var/lib/vpsctl/network/nftables
    fi
    if [[ -n "$HTTP_PID" ]]; then
        kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    [[ "$IMAGE_CREATED" == 0 ]] || docker image rm "$IMAGE" >/dev/null 2>&1 || true
    ip netns del "$NS" 2>/dev/null || true
    ip link del "$HOST_IF" 2>/dev/null || true
    if [[ "$failed" != 0 ]]; then
        printf 'FAIL: cleanup incomplete; restore %s\n' "$BACKUP"
        status=30
    fi
    printf 'lifecycle_exit=%s\n' "$status" >"$RESULT/result"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
sha256sum "$ROOT/lib/nftables.sh" "$ROOT"/lib/nftables/* "$ROOT"/commands/network/nftables/*.sh >"$RESULT/code.sha256"
ip netns add "$NS"
ip link add "$HOST_IF" type veth peer name "$PEER_IF"
ip link set "$PEER_IF" netns "$NS"
ip address add "$IP/30" dev "$HOST_IF"
ip link set "$HOST_IF" up
ip -n "$NS" link set lo up
ip -n "$NS" address add 198.19.254.2/30 dev "$PEER_IF"
ip -n "$NS" link set "$PEER_IF" up
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker pull "$IMAGE"
    IMAGE_CREATED=1
fi
docker run -d --name "$CONTAINER" -p "$IP:58931:80" "$IMAGE" sh -c 'mkdir -p /www; echo nft-docker-ok >/www/index.html; exec httpd -f -p 80 -h /www' >/dev/null
probe_docker() { ip netns exec "$NS" curl -fsS --max-time 4 "http://$IP:58931/" | grep -Fxq nft-docker-ok; }
for _ in {1..20}; do
    if probe_docker; then break; fi
    sleep 0.2
done
probe_docker
normalized_foreign >"$RESULT/foreign.before.json"
sysctl -n net.ipv4.ip_forward net.ipv6.conf.all.forwarding >"$RESULT/forwarding.before"
"${CLI[@]}" network nftables enable 2>&1 | tee "$RESULT/enable.log"
BACKUP="$(sed -n 's/.*恢复快照：//p' "$RESULT/enable.log" | tail -n 1)"
[[ "$BACKUP" == /var/lib/vpsctl/backups/network/nftables/change-* && -f "$BACKUP/legacy/state.json" ]] || exit 10
printf '%s\n' "$BACKUP" >"$RESULT/enable-backup"
if [[ -f "$BACKUP/legacy/ufw-recovery.deb" ]]; then
    dpkg-deb --ctrl-tarfile "$BACKUP/legacy/ufw-recovery.deb" | tar -tf - >"$RESULT/recovery-control-files.txt"
    grep -Fxq './config' "$RESULT/recovery-control-files.txt"
    grep -Fxq './templates' "$RESULT/recovery-control-files.txt"
fi
! command -v ufw >/dev/null
[[ ! -e /usr/local/bin/rfw && ! -e /etc/systemd/system/rfw.service ]]
ip -details -json link show | jq -e 'all(.[]; .xdp.prog.name != "rfw")' >/dev/null
"${CLI[@]}" network nftables status --json | jq -e '.enabled and .runtime_active and .boot=="enabled"' >/dev/null
probe_docker
normalized_foreign >"$RESULT/foreign.after.json"
diff -u "$RESULT/foreign.before.json" "$RESULT/foreign.after.json"
sysctl -n net.ipv4.ip_forward net.ipv6.conf.all.forwarding >"$RESULT/forwarding.after"
cmp "$RESULT/forwarding.before" "$RESULT/forwarding.after"
printf 'PASS: real UFW/RFW retirement, XDP detach, Docker peer ingress and foreign rules/sysctls preserved\n'
mkdir -p "$RESULT/http"
printf 'nft-input-ok\n' >"$RESULT/http/index.html"
python3 -m http.server 58932 --bind "$IP" --directory "$RESULT/http" >"$RESULT/http.log" 2>&1 &
HTTP_PID=$!
sleep 0.3
if ip netns exec "$NS" curl -fsS --max-time 2 "http://$IP:58932/"; then
    printf 'FAIL: unknown listener open\n'
    exit 1
fi
"${CLI[@]}" network nftables rule add --port 58932 --proto tcp --comment lifecycle-probe
id="$("${CLI[@]}" network nftables rule list --json | jq -r '.rules[]|select(.comment=="lifecycle-probe")|.id')"
ip netns exec "$NS" curl -fsS --max-time 3 "http://$IP:58932/" | grep -Fxq nft-input-ok
"${CLI[@]}" network nftables rule edit --id "$id" --action allow-only --source 198.19.254.99
if ip netns exec "$NS" curl -fsS --max-time 2 "http://$IP:58932/"; then exit 1; fi
"${CLI[@]}" network nftables rule delete --id "$id"
"${CLI[@]}" network nftables reload
systemctl start vpsctl-nftables.service
systemctl reload vpsctl-nftables.service
nft list table inet vpsctl_firewall >"$RESULT/runtime-after-service.txt"
probe_docker
printf 'PASS: public CLI default-deny, allow-only CRUD, systemd start/reload and deployed runtime\n'
if [[ "${VPSCTL_NFT_LIFECYCLE_HOLD:-0}" == 1 ]]; then
    printf '%s\n' "$NS" >"$RESULT/client-namespace"
    : >"$RESULT/ready"
    for _ in {1..1800}; do
        [[ ! -e "$RESULT/finish" ]] || break
        sleep 1
    done
    [[ -e "$RESULT/finish" ]] || {
        printf 'FAIL: external-session acceptance timed out\n'
        exit 20
    }
fi
"${CLI[@]}" network nftables disable
! nft list table inet vpsctl_firewall >/dev/null 2>&1
probe_docker
"${CLI[@]}" network nftables enable
probe_docker
"${CLI[@]}" network nftables restore "$BACKUP"
BACKUP=''
command -v ufw >/dev/null
systemctl is-active --quiet rfw.service
normalized_foreign >"$RESULT/foreign.restored.json"
diff -u "$RESULT/foreign.before.json" "$RESULT/foreign.restored.json"
printf 'PASS: disable/re-enable and actual old package/service restore; foreign rules unchanged\n'
