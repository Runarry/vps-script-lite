#!/usr/bin/env bash
# CLI transaction and inventory regression tests. Run on host-vps-scripts only.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TMP="$(mktemp -d /tmp/vpsctl-nft-cli-test.XXXXXX)"
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$TEST_TMP/system" VPSCTL_NON_INTERACTIVE=1
export VPSCTL_ASSUME_YES=1 VPSCTL_DRY_RUN=0 VPSCTL_NO_COLOR=1 VPSCTL_ENV_INIT=systemd
export VPSCTL_ENV_PACKAGE_MANAGER=apt-get
trap 'rm -rf -- "$TEST_TMP"' EXIT
# shellcheck source=../../commands/network/nftables.sh
source "$TEST_ROOT/commands/network/nftables.sh"
mkdir -p -- "$VPSCTL_SYSTEM_ROOT/etc/ssh" "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/service/proxy"
printf 'Port 22\n' >"$VPSCTL_SYSTEM_ROOT/etc/ssh/sshd_config"
vps_cmd_init network-nftables "$TEST_ROOT"
vps_nft_init
RUN_STATUS=0 RUN_OUTPUT=''
fail() {
    printf 'FAIL: %s\n%s\n' "$1" "$RUN_OUTPUT" >&2
    exit 1
}
assert_status() { [[ "$RUN_STATUS" == "$1" ]] || fail "$2: expected $1 got $RUN_STATUS"; }
run_cli() {
    if RUN_OUTPUT="$(nft_cli_dispatch "$@" 2>&1)"; then RUN_STATUS=0; else RUN_STATUS=$?; fi
}

# No backend here can invoke the machine's actual firewall or service manager.
nft() {
    local signature marker
    signature="$(
        IFS=' '
        printf '%s' "$*"
    )"
    printf 'nft %s\n' "$signature" >>"$VPSCTL_SYSTEM_ROOT/calls"
    if [[ "$signature" == '-j list tables' ]]; then
        [[ ! -e "$VPSCTL_SYSTEM_ROOT/fail-query" ]] || return 1
        if [[ -f "$VPSCTL_SYSTEM_ROOT/active" ]]; then
            printf '{"nftables":[{"table":{"family":"inet","name":"vpsctl_firewall"}}]}\n'
        else printf '{"nftables":[]}\n'; fi
        return 0
    fi
    if [[ "$signature" == 'list table inet vpsctl_firewall' || "$signature" == '-j list table inet vpsctl_firewall' ]]; then
        [[ ! -e "$VPSCTL_SYSTEM_ROOT/fail-table-detail" ]] || return 1
        [[ -f "$VPSCTL_SYSTEM_ROOT/active" ]] || return 1
        marker=''
        [[ ! -f "$VPSCTL_SYSTEM_ROOT/generation" ]] || marker="$(<"$VPSCTL_SYSTEM_ROOT/generation")"
        jq -cn --arg marker "$marker" '{nftables:[{set:{name:$marker}}]}'
        return 0
    fi
    if [[ "$1" == -c ]]; then
        [[ "$2" == -f && -f "$3" ]]
        return $?
    fi
    if [[ "$1" == -f ]]; then
        if [[ -f "$VPSCTL_SYSTEM_ROOT/fail-nft" ]]; then
            rm -f -- "$VPSCTL_SYSTEM_ROOT/fail-nft"
            return 1
        fi
        if grep -q '^delete table inet vpsctl_firewall' "$2"; then rm -f -- "$VPSCTL_SYSTEM_ROOT/active" "$VPSCTL_SYSTEM_ROOT/generation"; fi
        if grep -q '^add table inet vpsctl_firewall' "$2"; then touch "$VPSCTL_SYSTEM_ROOT/active"; fi
        marker="$(awk '$1=="add" && $2=="set" && $5~/^generation_/ {print $5}' "$2")"
        [[ -z "$marker" ]] || printf '%s\n' "$marker" >"$VPSCTL_SYSTEM_ROOT/generation"
        cp -- "$2" "$VPSCTL_SYSTEM_ROOT/last-batch"
        return 0
    fi
    printf 'Unexpected nft args: %s\n' "$signature" >&2
    return 70
}
systemctl() {
    (
        IFS=' '
        printf 'systemctl %s\n' "$*"
    ) >>"$VPSCTL_SYSTEM_ROOT/calls"
    case "$1" in
        is-active)
            [[ -f "$VPSCTL_SYSTEM_ROOT/service-active" ]] && return 0
            return 3
            ;;
        stop) rm -f -- "$VPSCTL_SYSTEM_ROOT/service-active" ;;
        start)
            [[ -f "$VPSCTL_SYSTEM_ROOT/etc/systemd/system/vpsctl-nftables.service" ]] || return 5
            flock -n "$VPSCTL_SYSTEM_ROOT/run/vpsctl/network-nftables.lock" true || return 70
            touch "$VPSCTL_SYSTEM_ROOT/service-active"
            ;;
        is-enabled) if [[ -f "$VPSCTL_SYSTEM_ROOT/boot" ]]; then printf 'enabled\n'; else
            printf 'disabled\n'
            return 1
        fi ;;
        enable) touch "$VPSCTL_SYSTEM_ROOT/boot" ;;
        disable) rm -f -- "$VPSCTL_SYSTEM_ROOT/boot" ;;
        daemon-reload) ;;
        *) return 70 ;;
    esac
}
rc-update() {
    local path="$VPSCTL_SYSTEM_ROOT/etc/runlevels/default/vpsctl-nftables"
    [[ "$2" == vpsctl-nftables && "$3" == default ]] || return 70
    case "$1" in
        add)
            mkdir -p -- "${path%/*}"
            touch "$path"
            ;;
        del)
            [[ -e "$path" ]] || return 1
            rm -f -- "$path"
            ;;
        *) return 70 ;;
    esac
}
sshd() { printf 'port 22\nport 2222\naddressfamily any\n'; }
nft_cli_legacy_begin() {
    printf 'legacy-begin\n' >>"$VPSCTL_SYSTEM_ROOT/calls"
    mkdir -p -- "$1"
}
nft_cli_legacy_retire() { printf 'legacy-retire\n' >>"$VPSCTL_SYSTEM_ROOT/calls"; }
nft_cli_legacy_finish() { printf 'legacy-finish\n' >>"$VPSCTL_SYSTEM_ROOT/calls"; }
nft_cli_legacy_restore() { printf 'legacy-restore\n' >>"$VPSCTL_SYSTEM_ROOT/calls"; }
nft_cli_po0_source() { :; }
po0_coop_prepare() { mkdir -p -- "$1"; }
po0_coop_commit() { :; }
po0_coop_restore() { :; }

run_cli install
assert_status 0 'install'
initial_backup="${RUN_OUTPUT##*恢复快照：}"
jq -e '.enabled==false' "$VPS_NFT_STATE_FILE" >/dev/null || fail 'install must remain disabled'
[[ -x "$VPSCTL_SYSTEM_ROOT/usr/local/lib/vpsctl/nftables/runtime.sh" ]] || fail 'offline runtime not installed'
[[ -f "$VPSCTL_SYSTEM_ROOT/usr/local/lib/vpsctl/nftables/lib/nftables/render.jq" ]] || fail 'renderer missing from runtime'
[[ ! -e "$VPSCTL_SYSTEM_ROOT/active" && ! -e "$VPSCTL_SYSTEM_ROOT/boot" ]] || fail 'install enabled firewall'

run_cli rule add --id admin --action allow-only --proto both --port 80,443,8000-8010 --source 192.0.2.1,2001:db8::/64 --ttl 30m
assert_status 0 'add restricted rule while disabled'
jq -e --argjson now "$(date +%s)" '.rules[0].expires_at>$now and .rules[0].action=="allow-only" and .enabled==false' "$VPS_NFT_STATE_FILE" >/dev/null || fail 'TTL not persisted absolutely'
expiry="$(jq '.rules[0].expires_at' "$VPS_NFT_STATE_FILE")"
run_cli rule edit --id admin --comment 'keep expiry'
assert_status 0 'partial edit'
[[ "$(jq '.rules[0].expires_at' "$VPS_NFT_STATE_FILE")" == "$expiry" ]] || fail 'edit renewed TTL'
run_cli rule add --id invalid --source 2001:::1
assert_status 2 'malformed IPv6'
run_cli rule add --id invalid --port 9000-100
assert_status 2 'reversed range'
run_cli rule add --id invalid --proto any --port 443
assert_status 2 'port with all protocols'
run_cli limit set --id udp --proto udp --port 443 --rate 30/second --burst 60
assert_status 0 'UDP rate'
run_cli limit set --id tcp --proto tcp --port 22 --connections 10
assert_status 0 'TCP connections'
run_cli limit set --id invalid --proto udp --connections 5
assert_status 2 'UDP connection limit'

printf '{"schema_version":1,"nodes":[{"id":"hy2","profile":"hysteria2","listen":"::","port":8443}]}\n' >"$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/service/proxy/nodes.json"
printf '{"schema_version":1,"exits":[{"id":"edge","endpoint":{"host":"192.0.2.100","port":443},"protocol":{"network_hint":"both"}}],"forwards":[{"id":"relay","exit_id":"edge","network":"both","family":"ipv4","listen_port_start":10000,"listen_port_end":10001}]}\n' >"$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/service/proxy/relay.json"
printf '{"schema_version":1,"exits":{"edge":{"host":"192.0.2.100","ipv4":"192.0.2.100"}}}\n' >"$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/service/proxy/relay-resolved.json"
mkdir -p -- "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/service/tcping" "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/service/iperf3"
printf '{"schema_version":1,"enabled":true,"port":9000}\n' >"$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/service/tcping/state.json"
printf '{"schema_version":1,"enabled":true,"port":5201}\n' >"$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/service/iperf3/state.json"
printf '[{"owner":"tls:fixture","kind":"input","family":"ipv4","proto":"tcp","port":"80","source":"any","destination":"any","temporary":true}]\n' >"$TEST_TMP/tls.json"
if vps_nft_begin tls-fixture "$TEST_TMP/tls.json" record-only && vps_nft_commit; then
    :
else fail 'TLS lease fixture'; fi
export SSH_CONNECTION='198.51.100.2 50000 192.0.2.1 2200'
run_cli enable
assert_status 0 'enable with inventory'
[[ -f "$VPSCTL_SYSTEM_ROOT/active" && -f "$VPSCTL_SYSTEM_ROOT/boot" ]] || fail 'enable missing runtime or boot'
jq -e '([.requirements[] | select(.owner=="ssh") | .port]|unique)==["22","2200","2222"] and
    any(.requirements[];.owner=="node:hy2" and .proto=="udp" and .port=="8443") and
    any(.requirements[];.owner=="tcping" and .port=="9000") and
    any(.requirements[];.owner=="iperf3" and .proto=="udp") and
    any(.requirements[];.owner=="forward:relay" and .original_port=="10000-10001" and .destination=="192.0.2.100") and
    any(.requirements[];.owner=="tls:fixture" and .temporary)' "$VPS_NFT_STATE_FILE" >/dev/null || fail 'business inventory incomplete or live TLS lease lost'
grep -q '^legacy-finish$' "$VPSCTL_SYSTEM_ROOT/calls" || fail 'legacy retirement missing'
run_cli install
assert_status 0 'repeat install while enabled'
[[ -f "$VPSCTL_SYSTEM_ROOT/active" && -f "$VPSCTL_SYSTEM_ROOT/boot" ]] || fail 'repeat install disabled firewall'
if RUN_OUTPUT="$(
    export -f nft
    bash "$VPSCTL_SYSTEM_ROOT/usr/local/lib/vpsctl/nftables/runtime.sh" start 2>&1
)"; then RUN_STATUS=0; else RUN_STATUS=$?; fi
assert_status 0 'installed offline runtime boot entry'
systemctl start vpsctl-nftables.service || fail 'active-exited oneshot fixture'
run_cli link detach node:hy2
assert_status 0 'detach service'
run_cli sync
assert_status 0 'sync'
jq -e '.links["node:hy2"].detached' "$VPS_NFT_STATE_FILE" >/dev/null || fail 'sync lost detached flag'

before="$(jq -cS . "$VPS_NFT_STATE_FILE")"
touch "$VPSCTL_SYSTEM_ROOT/fail-nft"
run_cli rule edit --id admin --port 8443
assert_status 20 'failed nft apply'
[[ "$(jq -cS . "$VPS_NFT_STATE_FILE")" == "$before" ]] || fail 'failed mutation did not restore state'
[[ -f "$VPSCTL_SYSTEM_ROOT/active" ]] || fail 'rollback lost live firewall'
[[ -f "$VPSCTL_SYSTEM_ROOT/service-active" ]] || fail 'rollback lost active oneshot state'

mkdir -p -- "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/security/access"
touch "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/security/access/active"
run_cli disable
assert_status 3 'SSH pending blocks global change'
[[ -f "$VPSCTL_SYSTEM_ROOT/active" ]] || fail 'blocked operation changed runtime'
rm -f -- "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/security/access/active"

before="$(sha256sum "$VPS_NFT_STATE_FILE")"
backup_count="$(find "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/backups/network/nftables" -mindepth 1 -maxdepth 1 -type d | wc -l)"
VPSCTL_DRY_RUN=1
run_cli rule add --id dry --port 1234
assert_status 0 'dry-run rule'
run_cli enable
assert_status 0 'dry-run enable'
VPSCTL_DRY_RUN=0
[[ "$(sha256sum "$VPS_NFT_STATE_FILE")" == "$before" ]] || fail 'dry-run wrote state'
[[ "$(find "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/backups/network/nftables" -mindepth 1 -maxdepth 1 -type d | wc -l)" == "$backup_count" ]] || fail 'dry-run created backup'
run_cli status --json
assert_status 0 'JSON status'
jq -e '.schema_version==1 and .enabled and .runtime_active and .boot=="enabled"' <<<"$RUN_OUTPUT" >/dev/null || fail 'invalid versioned status'
run_cli rule list --json
assert_status 0 'JSON rules'
jq -e '.schema_version==1 and (.rules|length)==1' <<<"$RUN_OUTPUT" >/dev/null || fail 'invalid versioned rules'
run_cli link list --json
assert_status 0 'JSON links'
jq -e '.schema_version==1 and (.links|length)>0' <<<"$RUN_OUTPUT" >/dev/null || fail 'invalid versioned links'
run_cli stats --json
assert_status 0 'JSON stats'
jq -e '.schema_version==1 and (.counters|type)=="array"' <<<"$RUN_OUTPUT" >/dev/null || fail 'invalid versioned stats'
touch "$VPSCTL_SYSTEM_ROOT/fail-query"
run_cli status --json
assert_status 20 'status propagates nft enumeration failure'
run_cli stats --json
assert_status 20 'stats propagates nft enumeration failure'
rm -f -- "$VPSCTL_SYSTEM_ROOT/fail-query"
touch "$VPSCTL_SYSTEM_ROOT/fail-table-detail"
run_cli stats --json
assert_status 20 'stats propagates table detail failure'
rm -f -- "$VPSCTL_SYSTEM_ROOT/fail-table-detail"

if RUN_OUTPUT="$(nft_cli_menu_rule_form ports add <<<$'1\nbad\n443\n1\n1' 2>&1)"; then RUN_STATUS=0; else RUN_STATUS=$?; fi
assert_status 0 'short port menu retries invalid port immediately'
menu_id="$(jq -r '.rules[] | select(.id!="admin") | .id' "$VPS_NFT_STATE_FILE")"
jq -e --arg id "$menu_id" 'any(.rules[];.id==$id and .port=="443" and .proto=="tcp" and .source=="any" and .family=="both" and .expires_at==0)' "$VPS_NFT_STATE_FILE" >/dev/null || fail 'menu changed common defaults'
run_cli rule delete --id "$menu_id"
assert_status 0 'delete menu rule'

run_cli disable
assert_status 0 'disable'
[[ ! -e "$VPSCTL_SYSTEM_ROOT/active" && ! -e "$VPSCTL_SYSTEM_ROOT/boot" ]] || fail 'disable left firewall enabled'
restore_backup="${RUN_OUTPUT##*恢复快照：}"
run_cli restore "$restore_backup"
assert_status 0 'restore enabled snapshot'
[[ -f "$VPSCTL_SYSTEM_ROOT/active" && -f "$VPSCTL_SYSTEM_ROOT/boot" ]] || fail 'restore did not recover runtime and boot'
jq -e '.enabled and .links["node:hy2"].detached' "$VPS_NFT_STATE_FILE" >/dev/null || fail 'restore changed saved policy'
run_cli disable
assert_status 0 'disable after restore'
run_cli uninstall
assert_status 0 'uninstall'
uninstall_backup="${RUN_OUTPUT##*恢复快照：}"
[[ ! -e "$VPSCTL_SYSTEM_ROOT/usr/local/lib/vpsctl/nftables" && -f "$VPS_NFT_STATE_FILE" ]] || fail 'uninstall deleted configuration or retained runtime'
[[ ! -e "$VPSCTL_SYSTEM_ROOT/service-active" ]] || fail 'uninstall retained active-exited unit'
run_cli restore "$uninstall_backup"
assert_status 0 'restore active-exited oneshot after uninstall'
[[ -f "$VPSCTL_SYSTEM_ROOT/service-active" ]] || fail 'restore did not restart original active service after unlocking'
run_cli restore "$initial_backup"
assert_status 0 'restore absent runtime'
[[ ! -e "$VPSCTL_SYSTEM_ROOT/service-active" && ! -e "$VPSCTL_SYSTEM_ROOT/usr/local/lib/vpsctl/nftables" ]] || fail 'restore absent retained service or runtime'
[[ "$(stat -c %a "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/backups/network/nftables")" == 700 ]] || fail 'backups not private'
if grep -Eq '^systemctl (start|restart|stop) nftables(\.service)?$|flush ruleset|/etc/nftables.conf' "$VPSCTL_SYSTEM_ROOT/calls"; then fail 'generic service or ruleset touched'; fi
VPSCTL_ENV_INIT=openrc
run_cli install
assert_status 0 'OpenRC install disabled without runlevel entry'
[[ -x "$VPSCTL_SYSTEM_ROOT/etc/init.d/vpsctl-nftables" ]] || fail 'OpenRC service missing'
run_cli enable
assert_status 0 'OpenRC enable'
[[ -f "$VPSCTL_SYSTEM_ROOT/etc/runlevels/default/vpsctl-nftables" ]] || fail 'OpenRC boot entry missing'
run_cli disable
assert_status 0 'OpenRC disable'
[[ ! -e "$VPSCTL_SYSTEM_ROOT/etc/runlevels/default/vpsctl-nftables" ]] || fail 'OpenRC boot entry retained'
(
    installed=0
    # Called indirectly by the dependency installer imported above.
    # shellcheck disable=SC2317
    _vps_cmd_tool_available() { [[ "$1" != jq || "$installed" == 1 ]]; }
    # shellcheck disable=SC2317
    vps_cmd_install_packages() {
        [[ "$1" == apt-get && "$2" == jq ]] || return 70
        installed=1
    }
    VPSCTL_INSTALL_DEPS=1
    if nft_cli_rule_parse rule add --port bad; then fail 'malformed rule accepted before dependencies'; fi
    [[ "$installed" == 0 ]] || fail 'invalid rule installed dependencies'
    nft_cli_rule_parse rule add --port 1234 || fail 'authorized lazy jq installation'
    [[ "$installed" == 1 ]] || fail 'mutation ignored --install-deps'
    jq -e '.port=="1234"' <<<"$NFT_CLI_PATCH" >/dev/null || fail 'parser lost fields during dependency install'
    installed=0
    VPSCTL_DRY_RUN=1
    nft_cli_rule_parse rule add --port 4321 || fail 'dependency-only dry-run'
    [[ "$VPS_CMD_DEPENDENCIES_PLANNED" == 1 && "$NFT_CLI_PATCH" == '{}' ]] || fail 'dependency dry-run constructed unvalidated state'
)
printf 'PASS: nftables CLI transactions, inventory, limits, dry-run and JSON\n'
