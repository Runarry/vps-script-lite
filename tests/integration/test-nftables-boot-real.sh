#!/usr/bin/env bash
# Run INSIDE a disposable Alpine/OpenRC VM. The controller performs real reboots.
# shellcheck disable=SC1091,SC2016
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
[[ "${VPSCTL_REAL_NFT_BOOT_TEST:-0}" == 1 ]] || { echo 'SKIP: disposable OpenRC VM only'; exit 0; }
[[ -f /etc/alpine-release && -d /run/openrc && $EUID == 0 ]] || { echo 'BLOCKED: requires root in Alpine/OpenRC'; exit 3; }
TEST_ROOT="${NFT_BOOT_PROJECT_ROOT:-/root/vpsctl-source}"
evidence=/root/vpsctl-nft-boot-evidence
mkdir -p "$evidence"
vpsctl() { bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes "$@"; }
case "${1:-}" in
setup)
    cat >"$evidence/target.py" <<'PY'
import socket,threading,time
def serve(port):
    s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    s.bind(('0.0.0.0',port));s.listen(16)
    while True:
        c,_=s.accept()
        with c:c.sendall(b'openrc-nft-boot-ok\n')
for p in (40123,40124):threading.Thread(target=serve,args=(p,),daemon=True).start()
while True:time.sleep(60)
PY
    cat >"$evidence/foreign.nft" <<'NFT'
add table inet acceptance_boot_foreign
add chain inet acceptance_boot_foreign input { type filter hook input priority 20; policy accept; }
add rule inet acceptance_boot_foreign input tcp dport 49999 counter accept comment "boot foreign sentinel"
NFT
    cat >/etc/init.d/vpsctl-acceptance-target <<'RC'
#!/sbin/openrc-run
description="Disposable nftables acceptance fixture"
command=/usr/bin/python3
command_args=/root/vpsctl-nft-boot-evidence/target.py
command_background=yes
pidfile=/run/vpsctl-acceptance-target.pid
depend() { need localmount; before vpsctl-nftables; }
start_pre() {
    if ! nft list table inet acceptance_boot_foreign >/dev/null 2>&1; then
        nft -f /root/vpsctl-nft-boot-evidence/foreign.nft
    fi
}
RC
    chmod 0755 /etc/init.d/vpsctl-acceptance-target
    rc-update add vpsctl-acceptance-target default
    rc-service vpsctl-acceptance-target start
    nft -s list table inet acceptance_boot_foreign >"$evidence/foreign.before"
    vpsctl network nftables install
    vpsctl network nftables enable
    source "$TEST_ROOT/lib/command.sh"
    source "$TEST_ROOT/lib/nftables.sh"
    vps_cmd_init openrc-boot "$TEST_ROOT"
    printf '[{"owner":"boot-service","kind":"input","family":"ipv4","proto":"tcp","port":"40123","source":"any","destination":"any","temporary":false}]\n' >"$evidence/desired.json"
    vps_nft_begin acceptance-boot "$evidence/desired.json" force
    vps_nft_commit
    cat /proc/sys/kernel/random/boot_id >"$evidence/initial.boot-id"
    cp /var/lib/vpsctl/network/nftables/state.json "$evidence/enabled.state.json"
    rc-update show default | grep -F vpsctl-nftables
    ss -H -ltn | grep -E ':40123[[:space:]]'
    ss -H -ltn | grep -E ':40124[[:space:]]'
    echo 'PASS: native CLI install+enable and service requirement persisted in OpenRC guest'
    ;;
enabled)
    cat /proc/sys/kernel/random/boot_id >"$evidence/enabled.boot-id"
    ! cmp -s "$evidence/initial.boot-id" "$evidence/enabled.boot-id"
    rc-service vpsctl-nftables status
    rc-update show default | grep -F vpsctl-nftables
    ss -H -ltn | grep -E ':40123[[:space:]]'
    ss -H -ltn | grep -E ':40124[[:space:]]'
    nft -j list table inet vpsctl_firewall >"$evidence/enabled.ruleset.json"
    jq -e '.enabled and any(.requirements[];.owner=="boot-service" and .port=="40123")' /var/lib/vpsctl/network/nftables/state.json >/dev/null
    nft -s list table inet acceptance_boot_foreign >"$evidence/foreign.enabled"
    cmp "$evidence/foreign.before" "$evidence/foreign.enabled"
    echo 'PASS: actual OpenRC reboot changed boot ID and restored native table, service requirement, foreign table'
    ;;
disable)
    vpsctl network nftables disable
    ! nft list table inet vpsctl_firewall >/dev/null 2>&1
    ! rc-update show default | grep -F vpsctl-nftables
    cat /proc/sys/kernel/random/boot_id >"$evidence/disabled-before.boot-id"
    ;;
disabled)
    cat /proc/sys/kernel/random/boot_id >"$evidence/disabled-after.boot-id"
    ! cmp -s "$evidence/disabled-before.boot-id" "$evidence/disabled-after.boot-id"
    ! nft list table inet vpsctl_firewall >/dev/null 2>&1
    ! rc-update show default | grep -F vpsctl-nftables
    nft -s list table inet acceptance_boot_foreign >"$evidence/foreign.disabled"
    cmp "$evidence/foreign.before" "$evidence/foreign.disabled"
    jq -e '.enabled==false and any(.requirements[];.owner=="boot-service")' /var/lib/vpsctl/network/nftables/state.json >/dev/null
    ss -H -ltn | grep -E ':40123[[:space:]]'
    ss -H -ltn | grep -E ':40124[[:space:]]'
    echo 'PASS: disabled OpenRC reboot changed boot ID, own table absent, service requirement and foreign table retained'
    ;;
*) echo 'usage: setup|enabled|disable|disabled' >&2; exit 2 ;;
esac
