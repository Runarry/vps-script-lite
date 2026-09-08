#!/usr/bin/env bash
# Cross-module UFW acceptance. Invoked by test-network-ufw-real.sh while UFW is active.
# shellcheck disable=SC1091,SC2016 # Dynamic project sources and jq variables are intentional.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
[[ "${VPSCTL_UFW_LINKAGE_CHILD:-0}" == 1 ]] || {
    printf 'SKIP: run through test-network-ufw-real.sh\n'
    exit 0
}
((EUID == 0)) || exit 4
LC_ALL=C ufw status | grep -Fqx 'Status: active' || {
    printf 'FAIL: linkage acceptance requires active UFW\n' >&2
    exit 3
}

for tool in bash flock getent install ip jq nft openssl python3 script setsid sha256sum ss ssh sshd sysctl systemctl tar timeout ufw; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'FAIL: missing %s\n' "$tool" >&2; exit 3; }
done

TEST_TEMP="$(mktemp -d /var/tmp/vpsctl-ufw-linkage.XXXXXX)"
readonly TEST_TEMP
LINKAGE_RESULT_DIR="${VPSCTL_UFW_RESULT_DIR:-/var/tmp/vpsctl-ufw-results}"
mkdir -p -- "$LINKAGE_RESULT_DIR"
suffix="$BASHPID"
TABLE4="vpsctl_ufw_accept4_${suffix}"
TABLE6="vpsctl_ufw_accept6_${suffix}"
CLIENT_NS="vpsctl-ufw-fc-${suffix}"
SERVER_NS="vpsctl-ufw-fs-${suffix}"
CLIENT_ROOT_IF="vfc${suffix}"
SERVER_ROOT_IF="vfs${suffix}"
CLIENT_PEER_IF="vfcp${suffix}"
SERVER_PEER_IF="vfsp${suffix}"
PORT_BASE=$((52000 + BASHPID % 500 * 6))
((PORT_BASE < 65000)) || PORT_BASE=54000
ADOPT_PORT=$PORT_BASE
INACTIVE_PORT=$((PORT_BASE + 1))
ROLLBACK_PORT=$((PORT_BASE + 2))
SSH_ABORT_PORT=$((PORT_BASE + 5))
SSH_COMMIT_PORT=$((PORT_BASE + 6))
LISTEN_PORT=$((PORT_BASE + 7))
TARGET_PORT=$((PORT_BASE + 8))
BLOCK_ROUTE_PORT=$((PORT_BASE + 9))
PROXY_PUBLIC_PORT=$((PORT_BASE + 10))
PROXY_LOOPBACK_PORT=$((PORT_BASE + 11))
NODE_A="node:accept-a-${suffix}"
NODE_B="node:accept-b-${suffix}"
OLD_IPV4_FORWARD="$(sysctl -n net.ipv4.ip_forward)"
OLD_IPV6_FORWARD="$(sysctl -n net.ipv6.conf.all.forwarding)"
SERVER_PIDS=()
ACTIVE_TX=''
COMMITTED_BACKUP=''
SSH_ORIGINAL_PORT=''
SSH_FALLBACK_CAPTURED=0
ADOPT_RULE_ID=''
NODES_BACKED_UP=0
HOSTS_BACKED_UP=0
TLS_BASELINE_CAPTURED=0
TLS_TIMER_WAS_ENABLED=0
TLS_TIMER_WAS_ACTIVE=0
TLS_PROCESS=''
TLS_PORT80_BASELINE=''

# shellcheck source=../../lib/command.sh
source "$TEST_ROOT/lib/command.sh"
# shellcheck source=../../lib/ufw.sh
source "$TEST_ROOT/lib/ufw.sh"
# shellcheck source=../../commands/service/proxy/ufw.sh
source "$TEST_ROOT/commands/service/proxy/ufw.sh"
# shellcheck source=../../commands/service/proxy/relay-forward.sh
source "$TEST_ROOT/commands/service/proxy/relay-forward.sh"
vps_cmd_init 'UFW linkage real acceptance' "$TEST_ROOT"
vps_ufw_init
PROXY_RELAY_FORWARD_TABLE4="$TABLE4"
PROXY_RELAY_FORWARD_TABLE6="$TABLE6"
export PROXY_RELAY_FORWARD_TABLE4 PROXY_RELAY_FORWARD_TABLE6

vpsctl() {
    bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes "$@"
}

tty_vpsctl() {
    local reply="$1" command
    shift
    printf -v command '%q ' env VPSCTL_NON_INTERACTIVE=0 bash "$TEST_ROOT/bin/vpsctl" --no-color "$@"
    printf '%s\n' "$reply" | timeout 30 script -q -e -c "$command" /dev/null
}

restore_access_backup() {
    local backup="$1"
    [[ "$backup" =~ ^bak-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]] || return 2
    tty_vpsctl "$backup" security access restore --backup "$backup"
}

capture_ssh_fallback() {
    SSH_ORIGINAL_PORT="$(sshd -T | awk '$1=="port" {print $2; exit}')"
    [[ "$SSH_ORIGINAL_PORT" =~ ^[0-9]+$ ]] || return 3
    if [[ -e /etc/ssh/sshd_config.d/00-vpsctl-access.conf ]]; then
        cp -p -- /etc/ssh/sshd_config.d/00-vpsctl-access.conf "$TEST_TEMP/ssh-managed.original"
    else
        : >"$TEST_TEMP/ssh-managed.absent"
    fi
    SSH_FALLBACK_CAPTURED=1
}

restore_ssh_fallback() {
    ((SSH_FALLBACK_CAPTURED == 1)) || return 0
    if [[ -f "$TEST_TEMP/ssh-managed.original" ]]; then
        install -o root -g root -m 0644 -- "$TEST_TEMP/ssh-managed.original" /etc/ssh/sshd_config.d/00-vpsctl-access.conf
    else
        rm -f -- /etc/ssh/sshd_config.d/00-vpsctl-access.conf
    fi
    sshd -t
    systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service
    [[ "$(sshd -T | awk '$1=="port" {print $2; exit}')" == "$SSH_ORIGINAL_PORT" ]]
    vpsctl network ufw sync >/dev/null
}

inventory() {
    vpsctl network ufw rule list --json
}

apply_scope() {
    vps_ufw_begin "$1" "$2" "${3:-auto}"
    vps_ufw_commit
}

empty_scope() {
    local scope="$1" file="$TEST_TEMP/empty-$1.json"
    printf '[]\n' >"$file"
    apply_scope "$scope" "$file"
}

stop_servers() {
    local pid
    for pid in "${SERVER_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
    for pid in "${SERVER_PIDS[@]}"; do wait "$pid" >/dev/null 2>&1 || true; done
    SERVER_PIDS=()
}

snapshot_tls_baseline() {
    local path
    : >"$TEST_TEMP/tls.paths"
    for path in \
        var/lib/vpsctl/security/tls var/lib/vpsctl/backups/security/tls \
        usr/local/libexec/vpsctl/lego \
        etc/systemd/system/vpsctl-tls-renew.service etc/systemd/system/vpsctl-tls-renew.timer; do
        if [[ -e "/$path" || -L "/$path" ]]; then printf '%s\n' "$path" >>"$TEST_TEMP/tls.paths"; fi
    done
    if [[ -s "$TEST_TEMP/tls.paths" ]]; then
        tar -C / -cpf "$TEST_TEMP/tls.paths.tar" -T "$TEST_TEMP/tls.paths"
    fi
    systemctl is-enabled --quiet vpsctl-tls-renew.timer >/dev/null 2>&1 && TLS_TIMER_WAS_ENABLED=1
    systemctl is-active --quiet vpsctl-tls-renew.timer >/dev/null 2>&1 && TLS_TIMER_WAS_ACTIVE=1
    TLS_BASELINE_CAPTURED=1
}

restore_tls_baseline() {
    ((TLS_BASELINE_CAPTURED == 1)) || return 0
    systemctl disable --now vpsctl-tls-renew.timer >/dev/null 2>&1 || true
    rm -rf -- \
        /var/lib/vpsctl/security/tls /var/lib/vpsctl/backups/security/tls \
        /usr/local/libexec/vpsctl/lego \
        /etc/systemd/system/vpsctl-tls-renew.service /etc/systemd/system/vpsctl-tls-renew.timer
    [[ ! -f "$TEST_TEMP/tls.paths.tar" ]] || tar -C / -xpf "$TEST_TEMP/tls.paths.tar"
    systemctl daemon-reload >/dev/null
    if ((TLS_TIMER_WAS_ENABLED == 1)); then
        systemctl enable vpsctl-tls-renew.timer >/dev/null
    fi
    if ((TLS_TIMER_WAS_ACTIVE == 1)); then
        systemctl start vpsctl-tls-renew.timer >/dev/null
    fi
}

cleanup_proxy_nodes() {
    local id
    while IFS= read -r id; do
        [[ "$id" =~ ^node-[0-9a-f]{16}$ ]] || continue
        vpsctl service proxy node delete --id "$id" --confirm-delete >/dev/null 2>&1 || return 1
    done < <(vpsctl service proxy node list --core all --json 2>/dev/null |
        jq -r --arg prefix "ufw-accept-${suffix}-" '.nodes[] | select(.name | startswith($prefix)) | .id' || true)
}

preserve_tls_logs() {
    local file
    [[ -n "${fake_root:-}" && -d "$fake_root" ]] || return 0
    for file in "$fake_root"/*.log "$fake_root"/*.args; do
        [[ -f "$file" ]] || continue
        cp -p -- "$file" "$LINKAGE_RESULT_DIR/tls-${file##*/}" || return 1
    done
}

report_error() {
    local status=$?
    printf 'FAIL: shell error at %s:%s (%s)\n' \
        "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" "${FUNCNAME[1]:-main}" >&2
    return "$status"
}

wait_listener_state() {
    local mode="$1" port="$2" wanted="$3" output
    for _attempt in {1..100}; do
        if [[ "$mode" == tcp ]]; then output="$(ss -H -lnt "sport = :$port")"; else output="$(ss -H -lnu "sport = :$port")"; fi
        if [[ "$wanted" == present && -n "$output" ]] || [[ "$wanted" == absent && -z "$output" ]]; then return 0; fi
        sleep 0.05
    done
    return 1
}

cleanup() {
    local original_status=$? cleanup_status=0 active=''
    trap - EXIT HUP INT TERM
    if [[ -n "$TLS_PROCESS" ]]; then
        kill -TERM -- "-$TLS_PROCESS" >/dev/null 2>&1 || true
        wait "$TLS_PROCESS" >/dev/null 2>&1 || true
        TLS_PROCESS=''
    fi
    stop_servers
    active="$(vpsctl security access status --json 2>/dev/null | jq -r '.transaction.id // empty' || true)"
    [[ -z "$active" ]] || vpsctl security access ssh abort --transaction "$active" >/dev/null 2>&1 || cleanup_status=1
    if [[ -n "$COMMITTED_BACKUP" ]]; then
        restore_access_backup "$COMMITTED_BACKUP" >/dev/null 2>&1 || cleanup_status=1
    fi
    if ((SSH_FALLBACK_CAPTURED == 1)) && [[ "$(sshd -T | awk '$1=="port" {print $2; exit}')" != "$SSH_ORIGINAL_PORT" ]]; then
        restore_ssh_fallback || cleanup_status=1
    fi
    cleanup_proxy_nodes || cleanup_status=1
    preserve_tls_logs || cleanup_status=1
    restore_tls_baseline || cleanup_status=1
    [[ ! -f "$TEST_TEMP/accept-nodes.snapshot" ]] || vps_ufw_scope_restore accept-nodes "$TEST_TEMP/accept-nodes.snapshot" || cleanup_status=1
    [[ ! -f "$TEST_TEMP/accept-forwards.snapshot" ]] || vps_ufw_scope_restore accept-forwards "$TEST_TEMP/accept-forwards.snapshot" || cleanup_status=1
    if ((NODES_BACKED_UP == 1)); then
        cp -p -- "$TEST_TEMP/nodes.original.json" /var/lib/vpsctl/service/proxy/nodes.json || cleanup_status=1
        vpsctl network ufw sync >/dev/null 2>&1 || cleanup_status=1
    fi
    if ((HOSTS_BACKED_UP == 1)); then cp -p -- "$TEST_TEMP/hosts.original" /etc/hosts || cleanup_status=1; fi
    empty_scope accept-rollback >/dev/null 2>&1 || cleanup_status=1
    if [[ -n "$ADOPT_RULE_ID" ]]; then
        local current
        current="$(inventory 2>/dev/null || true)"
        if jq -e --arg id "$ADOPT_RULE_ID" 'any(.[]; .id==$id and (.owners|length)==0)' <<<"$current" >/dev/null 2>&1; then
            vpsctl network ufw rule delete --id "$ADOPT_RULE_ID" >/dev/null 2>&1 || cleanup_status=1
        fi
    fi
    nft destroy table ip "$TABLE4" >/dev/null 2>&1 || true
    nft destroy table ip6 "$TABLE6" >/dev/null 2>&1 || true
    ip netns del "$CLIENT_NS" >/dev/null 2>&1 || true
    ip netns del "$SERVER_NS" >/dev/null 2>&1 || true
    ip link del "$CLIENT_ROOT_IF" >/dev/null 2>&1 || true
    ip link del "$SERVER_ROOT_IF" >/dev/null 2>&1 || true
    sysctl -q -w "net.ipv4.ip_forward=$OLD_IPV4_FORWARD" >/dev/null || cleanup_status=1
    sysctl -q -w "net.ipv6.conf.all.forwarding=$OLD_IPV6_FORWARD" >/dev/null || cleanup_status=1
    rm -rf -- "$TEST_TEMP"
    ((original_status != 0)) || original_status=$((cleanup_status == 0 ? 0 : 30))
    exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
trap report_error ERR

vps_ufw_scope_snapshot accept-forwards "$TEST_TEMP/accept-forwards.snapshot"

# Exact manual-rule adoption and shared ownership from two proxy node declarations.
ufw allow in proto tcp from 0.0.0.0/0 to 0.0.0.0/0 port "$ADOPT_PORT" comment accept-adopt
vps_ufw_scope_snapshot accept-nodes "$TEST_TEMP/accept-nodes.snapshot"
nodes_manifest="$TEST_TEMP/nodes.json"
nodes_desired="$TEST_TEMP/nodes.desired.json"
jq -n --argjson port "$ADOPT_PORT" --arg a "${NODE_A#node:}" --arg b "${NODE_B#node:}" '{schema_version:1,nodes:[
  {id:$a,listen:"0.0.0.0",port:$port,profile:"vmess-ws-tls"},
  {id:$b,listen:"0.0.0.0",port:$port,profile:"vmess-ws-tls"}]}' >"$nodes_manifest"
proxy_ufw_nodes_desired "$nodes_manifest" >"$nodes_desired"
apply_scope accept-nodes "$nodes_desired"
rules="$(inventory)"
ADOPT_RULE_ID="$(jq -r --arg port "$ADOPT_PORT" '.[] | select(.port==$port and .family=="ipv4") | .id' <<<"$rules")"
jq -e --arg id "$ADOPT_RULE_ID" --arg a "$NODE_A" --arg b "$NODE_B" \
    'any(.[]; .id==$id and (.owners|sort)==([$a,$b]|sort) and .comment=="accept-adopt")' <<<"$rules" >/dev/null
status=0
vpsctl network ufw rule delete --id "$ADOPT_RULE_ID" >/dev/null 2>&1 || status=$?
[[ "$status" == 3 ]]
vpsctl network ufw link detach "$NODE_A"
rules="$(inventory)"
jq -e --arg id "$ADOPT_RULE_ID" --arg b "$NODE_B" 'any(.[];.id==$id and .owners==[$b])' <<<"$rules" >/dev/null
vpsctl network ufw link detach "$NODE_B"
rules="$(inventory)"
jq -e --arg id "$ADOPT_RULE_ID" 'any(.[];.id==$id and (.owners|length)==0)' <<<"$rules" >/dev/null
vpsctl network ufw link attach "$NODE_A"
rules="$(inventory)"
jq -e --arg id "$ADOPT_RULE_ID" --arg a "$NODE_A" 'any(.[];.id==$id and .owners==[$a])' <<<"$rules" >/dev/null
vps_ufw_scope_restore accept-nodes "$TEST_TEMP/accept-nodes.snapshot"
rules="$(inventory)"
jq -e --arg id "$ADOPT_RULE_ID" 'any(.[];.id==$id and (.owners|length)==0 and .comment=="accept-adopt")' <<<"$rules" >/dev/null
vpsctl network ufw rule delete --id "$ADOPT_RULE_ID"
ADOPT_RULE_ID=''
rm -f -- "$TEST_TEMP/accept-nodes.snapshot"
printf 'PASS: manual adoption, shared ownership, protection, detach, attach, and scoped restore\n'

# Inactive mode records a requirement without changing UFW files; enable reconciles it.
cp -p -- /var/lib/vpsctl/service/proxy/nodes.json "$TEST_TEMP/nodes.original.json"
NODES_BACKED_UP=1
jq --arg id "accept-inactive-${suffix}" --argjson port "$INACTIVE_PORT" \
    '.nodes += [{id:$id,listen:"0.0.0.0",port:$port,profile:"vmess-ws-tls"}]' \
    "$TEST_TEMP/nodes.original.json" >"$TEST_TEMP/nodes.candidate.json"
cp -- "$TEST_TEMP/nodes.candidate.json" /var/lib/vpsctl/service/proxy/nodes.json
vpsctl network ufw disable
vpsctl network ufw sync
if jq -e --arg port "$INACTIVE_PORT" 'any(.[];.port==$port)' <<<"$(inventory)" >/dev/null; then
    printf 'FAIL: inactive transaction unexpectedly wrote a UFW rule\n' >&2
    exit 1
fi
vpsctl network ufw enable
jq -e --arg port "$INACTIVE_PORT" --arg owner "node:accept-inactive-${suffix}" \
    'any(.[];.port==$port and (.owners|index($owner)))' <<<"$(inventory)" >/dev/null
cp -p -- "$TEST_TEMP/nodes.original.json" /var/lib/vpsctl/service/proxy/nodes.json
vpsctl network ufw sync
NODES_BACKED_UP=0
printf 'PASS: inactive desired-state recording and enable reconciliation\n'

# Fail the second family apply and require complete rollback of the first rule and state.
rollback_desired="$TEST_TEMP/rollback.json"
jq -n --arg port "$ROLLBACK_PORT" '["ipv4","ipv6"] | map({owner:"node:accept-rollback",kind:"input",family:.,proto:"tcp",port:$port,source:"any",destination:"any",temporary:false})' >"$rollback_desired"
state_before="$(sha256sum /var/lib/vpsctl/network/ufw/state.json | awk '{print $1}')"
rules_before="$(inventory | jq -cS .)"
mkdir -p "$TEST_TEMP/fail-bin"
cat >"$TEST_TEMP/fail-bin/ufw" <<EOF
#!/usr/bin/env bash
count_file='$TEST_TEMP/fail-count'
if [[ "\$*" == *" $ROLLBACK_PORT"* ]]; then
    count=0; [[ ! -f "\$count_file" ]] || count="\$(<"\$count_file")"
    count=\$((count+1)); printf '%s\n' "\$count" >"\$count_file"
    if ((count == 2)); then exit 42; fi
fi
exec /usr/sbin/ufw "\$@"
EOF
chmod 0700 "$TEST_TEMP/fail-bin/ufw"
status=0
PATH="$TEST_TEMP/fail-bin:$PATH" vps_ufw_begin accept-rollback "$rollback_desired" || status=$?
[[ "$status" == 20 ]]
[[ "$(sha256sum /var/lib/vpsctl/network/ufw/state.json | awk '{print $1}')" == "$state_before" ]]
[[ "$(inventory | jq -cS .)" == "$rules_before" ]]
printf 'PASS: cross-family apply failure rolls back UFW files, runtime, and shared state\n'

# SSH abort, second-session proof, commit, and restore.
capture_ssh_fallback
current_port="$SSH_ORIGINAL_PORT"
prepare="$(vpsctl security access ssh prepare --port "$SSH_ABORT_PORT" --firewall auto 2>&1)"
ACTIVE_TX="$(grep -Eo 'tx-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}' <<<"$prepare" | tail -n 1)"
[[ -n "$ACTIVE_TX" ]]
jq -e --arg old "$current_port" --arg new "$SSH_ABORT_PORT" \
    'any(.[];.port==$old and (.owners|index("ssh"))) and any(.[];.port==$new and (.owners|index("ssh")))' <<<"$(inventory)" >/dev/null
vpsctl security access ssh abort --transaction "$ACTIVE_TX"
ACTIVE_TX=''
if jq -e --arg port "$SSH_ABORT_PORT" 'any(.[];.port==$port and (.owners|index("ssh")))' <<<"$(inventory)" >/dev/null; then
    printf 'FAIL: SSH abort retained the candidate rule owner\n' >&2
    exit 1
fi

prepare="$(vpsctl security access ssh prepare --port "$SSH_COMMIT_PORT" --firewall auto 2>&1)"
ACTIVE_TX="$(grep -Eo 'tx-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}' <<<"$prepare" | tail -n 1)"
[[ -n "$ACTIVE_TX" ]]
COMMITTED_BACKUP="$(awk -F $'\t' '$1=="backup_id" {print $2; exit}' "/var/lib/vpsctl/security/access/transactions/$ACTIVE_TX/state")"
[[ "$COMMITTED_BACKUP" =~ ^bak-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]]
[[ -f "/var/lib/vpsctl/backups/security/access/$COMMITTED_BACKUP/manifest" ]]
ssh -T -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_COMMIT_PORT" root@127.0.0.1 \
    bash "$TEST_ROOT/bin/vpsctl" --no-color security access session verify --transaction "$ACTIVE_TX"
vpsctl security access ssh commit --transaction "$ACTIVE_TX" --confirm-apply "$ACTIVE_TX"
ACTIVE_TX=''
jq -e --arg old "$current_port" --arg new "$SSH_COMMIT_PORT" \
    'all(.[];.port!=$old or (.owners|index("ssh")|not)) and any(.[];.port==$new and (.owners|index("ssh")))' <<<"$(inventory)" >/dev/null
restore_access_backup "$COMMITTED_BACKUP"
[[ "$(sshd -T | awk '$1=="port" {print $2; exit}')" == "$current_port" ]]
awk -F $'\t' '$1=="lifecycle" && $2=="restored" {found=1} END {exit !found}' \
    "/var/lib/vpsctl/backups/security/access/$COMMITTED_BACKUP/manifest"
jq -e --arg port "$current_port" \
    'any(.[];.port==$port and (.owners|index("ssh")))' <<<"$(inventory)" >/dev/null
COMMITTED_BACKUP=''
printf 'PASS: SSH auto-firewall abort and second-session commit/restore\n'

# Exercise node linkage through the public proxy business transaction.
public_name="ufw-accept-${suffix}-public"
vpsctl service proxy node add --profile shadowsocks-aes-256-gcm --core xray \
    --name "$public_name" --listen :: --port "$PROXY_PUBLIC_PORT" --address 127.0.0.1 >/dev/null
public_nodes="$(vpsctl service proxy node list --core all --json)"
public_id="$(jq -r --arg name "$public_name" '[.nodes[] | select(.name==$name) | .id] | if length==1 then .[0] else empty end' \
    <<<"$public_nodes")"
[[ "$public_id" =~ ^node-[0-9a-f]{16}$ ]] || {
    printf 'FAIL: public node add did not return a node ID\n' >&2
    exit 1
}
owner="node:$public_id"
jq -e --arg id "$public_id" --argjson port "$PROXY_PUBLIC_PORT" \
    'any(.nodes[]; .id==$id and .listen=="::" and .port==$port and .profile=="shadowsocks-aes-256-gcm")' \
    <<<"$public_nodes" >/dev/null || {
        printf 'FAIL: public node is absent or differs in the business node list\n%s\n' "$public_nodes" >&2
        exit 1
    }
rules="$(inventory)"
jq -e --arg owner "$owner" --arg port "$PROXY_PUBLIC_PORT" '
    ([.[] | select(.port==$port and (.owners|index($owner))) | [.family,.proto]] | sort) ==
    ([ ["ipv4","tcp"], ["ipv4","udp"], ["ipv6","tcp"], ["ipv6","udp"] ] | sort)
' <<<"$rules" >/dev/null || {
        printf 'FAIL: public node did not create the four expected UFW requirements\n%s\n' "$rules" >&2
        exit 1
    }
wait_listener_state tcp "$PROXY_PUBLIC_PORT" present || {
    printf 'FAIL: active proxy core did not open the public TCP listener\n' >&2
    exit 1
}
wait_listener_state udp "$PROXY_PUBLIC_PORT" present || {
    printf 'FAIL: active proxy core did not open the public UDP listener\n' >&2
    exit 1
}
protected_id="$(jq -r --arg owner "$owner" --arg port "$PROXY_PUBLIC_PORT" \
    '.[] | select(.port==$port and .family=="ipv4" and .proto=="tcp" and (.owners|index($owner))) | .id' <<<"$rules")"
status=0
vpsctl network ufw rule edit --id "$protected_id" --comment forbidden-owned-edit >/dev/null 2>&1 || status=$?
[[ "$status" == 3 ]]
status=0
vpsctl network ufw ipv6 off >/dev/null 2>&1 || status=$?
[[ "$status" == 3 ]]
vpsctl network ufw link detach "$owner"
jq -e --arg owner "$owner" 'all(.[]; (.owners|index($owner)|not))' <<<"$(inventory)" >/dev/null
vpsctl network ufw link attach "$owner"
jq -e --arg owner "$owner" --arg port "$PROXY_PUBLIC_PORT" \
    'any(.[]; .port==$port and (.owners|index($owner)))' <<<"$(inventory)" >/dev/null
vpsctl service proxy node delete --id "$public_id" --confirm-delete
jq -e --arg owner "$owner" 'all(.[]; (.owners|index($owner)|not))' <<<"$(inventory)" >/dev/null
wait_listener_state tcp "$PROXY_PUBLIC_PORT" absent
wait_listener_state udp "$PROXY_PUBLIC_PORT" absent

loopback_name="ufw-accept-${suffix}-loopback"
vpsctl service proxy node add --profile shadowsocks-aes-256-gcm --core xray \
    --name "$loopback_name" --listen 127.0.0.1 --port "$PROXY_LOOPBACK_PORT" --address 127.0.0.1 >/dev/null
loopback_id="$(vpsctl service proxy node list --core all --json | jq -r --arg name "$loopback_name" \
    '[.nodes[] | select(.name==$name) | .id] | if length==1 then .[0] else empty end')"
[[ "$loopback_id" =~ ^node-[0-9a-f]{16}$ ]]
loopback_owner="node:$loopback_id"
wait_listener_state tcp "$PROXY_LOOPBACK_PORT" present
wait_listener_state udp "$PROXY_LOOPBACK_PORT" present
jq -e --arg owner "$loopback_owner" 'all(.[]; (.owners|index($owner)|not))' <<<"$(inventory)" >/dev/null
vpsctl service proxy node delete --id "$loopback_id" --confirm-delete
printf 'PASS: public proxy node CRUD drives TCP/UDP dual-stack ownership; loopback listeners stay private\n'

# Proxy-generated route requirements must permit real DNAT under default routed deny.
token=$((BASHPID % 180 + 30))
CLIENT4_ROOT="10.251.${token}.1"; CLIENT4="10.251.${token}.2"
SERVER4_ROOT="10.252.${token}.1"; SERVER4="10.252.${token}.2"; SERVER4_ALT="10.252.${token}.3"
printf -v hex '%x' "$((BASHPID % 65535))"
CLIENT6_ROOT="fd71:${hex}:1::1"; CLIENT6="fd71:${hex}:1::2"
SERVER6_ROOT="fd71:${hex}:2::1"; SERVER6="fd71:${hex}:2::2"; SERVER6_ALT="fd71:${hex}:2::3"
TARGET_HOST="ufw-target-${suffix}.test"

ip netns add "$CLIENT_NS"; ip netns add "$SERVER_NS"
ip link add "$CLIENT_ROOT_IF" type veth peer name "$CLIENT_PEER_IF"
ip link add "$SERVER_ROOT_IF" type veth peer name "$SERVER_PEER_IF"
ip link set "$CLIENT_PEER_IF" netns "$CLIENT_NS"; ip link set "$SERVER_PEER_IF" netns "$SERVER_NS"
ip -n "$CLIENT_NS" link set "$CLIENT_PEER_IF" name eth0; ip -n "$SERVER_NS" link set "$SERVER_PEER_IF" name eth0
ip link set "$CLIENT_ROOT_IF" up; ip link set "$SERVER_ROOT_IF" up
ip -n "$CLIENT_NS" link set lo up; ip -n "$SERVER_NS" link set lo up
ip -n "$CLIENT_NS" link set eth0 up; ip -n "$SERVER_NS" link set eth0 up
ip address add "${CLIENT4_ROOT}/24" dev "$CLIENT_ROOT_IF"; ip address add "${SERVER4_ROOT}/24" dev "$SERVER_ROOT_IF"
ip -6 address add "${CLIENT6_ROOT}/64" dev "$CLIENT_ROOT_IF" nodad; ip -6 address add "${SERVER6_ROOT}/64" dev "$SERVER_ROOT_IF" nodad
ip -n "$CLIENT_NS" address add "${CLIENT4}/24" dev eth0; ip -n "$SERVER_NS" address add "${SERVER4}/24" dev eth0
ip -n "$SERVER_NS" address add "${SERVER4_ALT}/24" dev eth0
ip -n "$CLIENT_NS" -6 address add "${CLIENT6}/64" dev eth0 nodad; ip -n "$SERVER_NS" -6 address add "${SERVER6}/64" dev eth0 nodad
ip -n "$SERVER_NS" -6 address add "${SERVER6_ALT}/64" dev eth0 nodad
ip -n "$CLIENT_NS" route add default via "$CLIENT4_ROOT"; ip -n "$SERVER_NS" route add default via "$SERVER4_ROOT"
ip -n "$CLIENT_NS" -6 route add default via "$CLIENT6_ROOT"; ip -n "$SERVER_NS" -6 route add default via "$SERVER6_ROOT"
sysctl -q -w net.ipv4.ip_forward=1 >/dev/null; sysctl -q -w net.ipv6.conf.all.forwarding=1 >/dev/null

cp -p -- /etc/hosts "$TEST_TEMP/hosts.original"; HOSTS_BACKED_UP=1
printf '%s %s # vpsctl-ufw-accept\n%s %s # vpsctl-ufw-accept\n' "$SERVER4" "$TARGET_HOST" "$SERVER6" "$TARGET_HOST" >>/etc/hosts
relay_manifest="$TEST_TEMP/relay.json"; relay_cache="$TEST_TEMP/relay-cache.json"; relay_batch="$TEST_TEMP/relay.nft"
jq -n --arg host "$TARGET_HOST" --argjson target "$TARGET_PORT" --argjson listen "$LISTEN_PORT" '{schema_version:1,
  exits:[{id:"exit-aaaaaaaaaaaaaaaa",name:"accept-target",type:"direct",endpoint:{host:$host,port:$target},network_hint:"both"}],
  bindings:[],forwards:[{id:"forward-bbbbbbbbbbbbbbbb",name:"accept-forward",exit_id:"exit-aaaaaaaaaaaaaaaa",
    listen_port_start:$listen,listen_port_end:$listen,network:"both",family:"dual",publish_address:"accept.invalid"}]}' >"$relay_manifest"
proxy_relay_forward_refresh_cache "$relay_manifest" '' "$relay_cache"
proxy_ufw_forwards_desired "$relay_manifest" "$relay_cache" >"$TEST_TEMP/forward.desired.json"
apply_scope accept-forwards "$TEST_TEMP/forward.desired.json"
proxy_relay_forward_render_nft "$relay_manifest" "$relay_cache" >"$relay_batch"
proxy_relay_forward_nft_apply "$relay_batch"

RELAY_SERVER_CODE='
import socket,sys
mode,host,port_text,ready=sys.argv[1:]
family=socket.AF_INET6 if ":" in host else socket.AF_INET
kind=socket.SOCK_STREAM if mode=="tcp" else socket.SOCK_DGRAM
s=socket.socket(family,kind); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind((host,int(port_text)))
if mode=="tcp": s.listen(2)
open(ready,"w").close()
if mode=="tcp":
 c,p=s.accept(); data=c.recv(64); c.sendall(p[0].encode()+b"|"+data); c.close()
else:
 data,p=s.recvfrom(64); s.sendto(p[0].encode()+b"|"+data,p)
'
RELAY_CLIENT_CODE='
import socket,sys
mode,host,port_text,expected=sys.argv[1:]
family=socket.AF_INET6 if ":" in host else socket.AF_INET
kind=socket.SOCK_STREAM if mode=="tcp" else socket.SOCK_DGRAM
s=socket.socket(family,kind); s.settimeout(3); payload=("relay-"+mode).encode()
if mode=="tcp": s.connect((host,int(port_text))); s.sendall(payload); result=s.recv(128)
else: s.sendto(payload,(host,int(port_text))); result,_=s.recvfrom(128)
assert result==expected.encode()+b"|"+payload,(result,expected)
'
start_relay_server() {
    local mode="$1" host="$2" label="$3" port="${4:-$TARGET_PORT}" ready
    ready="$TEST_TEMP/relay-ready-$label"
    ip netns exec "$SERVER_NS" python3 -c "$RELAY_SERVER_CODE" "$mode" "$host" "$port" "$ready" &
    SERVER_PIDS+=("$!")
    for _attempt in {1..100}; do [[ -e "$ready" ]] && return 0; sleep 0.05; done
    return 1
}
probe_route_blocked() {
    local mode="$1" host="$2" port="$3" expected="$4"
    if timeout 4 ip netns exec "$CLIENT_NS" python3 -c "$RELAY_CLIENT_CODE" "$mode" "$host" "$port" "$expected" \
        >/dev/null 2>&1; then
        printf 'FAIL: unrelated routed %s/%s unexpectedly crossed default routed deny\n' "$port" "$mode" >&2
        return 1
    fi
}
run_relay_set() {
    local server4="$1" server6="$2"
    start_relay_server tcp "$server4" "tcp4-$server4"; start_relay_server udp "$server4" "udp4-$server4"
    start_relay_server tcp "$server6" "tcp6-${server6//:/_}"; start_relay_server udp "$server6" "udp6-${server6//:/_}"
    ip netns exec "$CLIENT_NS" python3 -c "$RELAY_CLIENT_CODE" tcp "$CLIENT4_ROOT" "$LISTEN_PORT" "$SERVER4_ROOT"
    ip netns exec "$CLIENT_NS" python3 -c "$RELAY_CLIENT_CODE" udp "$CLIENT4_ROOT" "$LISTEN_PORT" "$SERVER4_ROOT"
    ip netns exec "$CLIENT_NS" python3 -c "$RELAY_CLIENT_CODE" tcp "$CLIENT6_ROOT" "$LISTEN_PORT" "$SERVER6_ROOT"
    ip netns exec "$CLIENT_NS" python3 -c "$RELAY_CLIENT_CODE" udp "$CLIENT6_ROOT" "$LISTEN_PORT" "$SERVER6_ROOT"
    for pid in "${SERVER_PIDS[@]}"; do wait "$pid"; done
    SERVER_PIDS=()
}

start_relay_server tcp "$SERVER4" blocked-tcp4 "$BLOCK_ROUTE_PORT"
start_relay_server udp "$SERVER4" blocked-udp4 "$BLOCK_ROUTE_PORT"
start_relay_server tcp "$SERVER6" blocked-tcp6 "$BLOCK_ROUTE_PORT"
start_relay_server udp "$SERVER6" blocked-udp6 "$BLOCK_ROUTE_PORT"
probe_route_blocked tcp "$SERVER4" "$BLOCK_ROUTE_PORT" "$CLIENT4"
probe_route_blocked udp "$SERVER4" "$BLOCK_ROUTE_PORT" "$CLIENT4"
probe_route_blocked tcp "$SERVER6" "$BLOCK_ROUTE_PORT" "$CLIENT6"
probe_route_blocked udp "$SERVER6" "$BLOCK_ROUTE_PORT" "$CLIENT6"
stop_servers
run_relay_set "$SERVER4" "$SERVER6"

# Change the locally controlled DNS answer, refresh cache, then update both nft and UFW destinations.
cp -p -- "$TEST_TEMP/hosts.original" /etc/hosts
printf '%s %s # vpsctl-ufw-accept\n%s %s # vpsctl-ufw-accept\n' "$SERVER4_ALT" "$TARGET_HOST" "$SERVER6_ALT" "$TARGET_HOST" >>/etc/hosts
proxy_relay_forward_refresh_cache "$relay_manifest" "$relay_cache" "$TEST_TEMP/relay-cache-new.json"
proxy_ufw_forwards_desired "$relay_manifest" "$TEST_TEMP/relay-cache-new.json" >"$TEST_TEMP/forward-new.desired.json"
apply_scope accept-forwards "$TEST_TEMP/forward-new.desired.json"
proxy_relay_forward_render_nft "$relay_manifest" "$TEST_TEMP/relay-cache-new.json" >"$relay_batch"
proxy_relay_forward_nft_apply "$relay_batch"
rules="$(inventory)"
old6_normalized="$(_vps_ufw_address "$SERVER6")"
new6_normalized="$(_vps_ufw_address "$SERVER6_ALT")"
jq -e --arg old4 "$SERVER4" --arg old6 "$old6_normalized" --arg new4 "$SERVER4_ALT" --arg new6 "$new6_normalized" \
    'all(.[];.destination!=$old4 and .destination!=$old6) and any(.[];.destination==$new4 and .kind=="route") and any(.[];.destination==$new6 and .kind=="route")' <<<"$rules" >/dev/null || {
        printf 'FAIL: DNS refresh did not replace routed destinations exactly\n%s\n' "$rules" >&2
        exit 1
    }
run_relay_set "$SERVER4_ALT" "$SERVER6_ALT"
vps_ufw_scope_restore accept-forwards "$TEST_TEMP/accept-forwards.snapshot"
rm -f -- "$TEST_TEMP/accept-forwards.snapshot"
proxy_relay_forward_nft_clear
cp -p -- "$TEST_TEMP/hosts.original" /etc/hosts; HOSTS_BACKED_UP=0
printf 'PASS: proxy route ownership, real dual-stack TCP/UDP DNAT, and DNS destination replacement\n'

# Exercise the public TLS command with a local fake lego. No external ACME or DNS service is used.
snapshot_tls_baseline
fake_root="$TEST_TEMP/fake-lego"
mkdir -p -- "$fake_root" /usr/local/libexec/vpsctl /var/lib/vpsctl/security/tls
export VPSCTL_UFW_FAKE_ROOT="$fake_root"
cat >"$fake_root/lego" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
path=''
domain=''
http=0
dns=0
printf '%s\n' "$@" >"$VPSCTL_UFW_FAKE_ROOT/args"
while (($#)); do
    case "$1" in
        --path) path="$2"; shift 2 ;;
        --domains) [[ -n "$domain" ]] || domain="$2"; shift 2 ;;
        --http) http=1; shift ;;
        --dns) dns=1; shift 2 ;;
        *) shift ;;
    esac
done
mode="$(<"$VPSCTL_UFW_FAKE_ROOT/mode")"
printf '%s\n' "$mode" >"$VPSCTL_UFW_FAKE_ROOT/ready"
case "$mode" in
    term) exec sleep 120 ;;
    failure) : ;;
    http-success | http-existing) ((http == 1 && dns == 0)) || exit 18 ;;
    dns-success) ((dns == 1 && http == 0)) || exit 18; [[ -n "${CF_DNS_API_TOKEN:-}" ]] || exit 19 ;;
    *) exit 18 ;;
esac
released=0
for _attempt in {1..600}; do
    if [[ -f "$VPSCTL_UFW_FAKE_ROOT/release" ]]; then released=1; break; fi
    sleep 0.05
done
((released == 1)) || exit 21
[[ "$mode" != failure ]] || exit 17
[[ -n "$path" && -n "$domain" ]]
base="${domain//\*/_}"
mkdir -p -- "$path/certificates"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$domain" \
    -addext "subjectAltName=DNS:$domain" \
    -keyout "$path/certificates/$base.key" -out "$path/certificates/$base.pem" >/dev/null 2>&1
cp -- "$path/certificates/$base.pem" "$path/certificates/$base.crt"
EOF
install -o root -g root -m 0755 -- "$fake_root/lego" /usr/local/libexec/vpsctl/lego
fake_sha="$(sha256sum /usr/local/libexec/vpsctl/lego | awk '{print $1}')"
printf 'tag=v5.4.1\nasset=lego_v5.4.1_linux_amd64.tar.gz\nsha256=%s\n' "$fake_sha" \
    >/var/lib/vpsctl/security/tls/lego.meta
chmod 0600 /var/lib/vpsctl/security/tls/lego.meta
printf 'CF_DNS_API_TOKEN=acceptance-only\n' >"$fake_root/cloudflare.env"
chmod 0600 "$fake_root/cloudflare.env"

port80_snapshot() {
    inventory | jq -cS '[.[] | select(.port=="80" and .proto=="tcp") |
        {id,family,kind,action,proto,port,source,destination,comment,owners}] | sort_by(.id)'
}
tls_rule_absent() {
    [[ "$(port80_snapshot)" == "$TLS_PORT80_BASELINE" ]] || return 1
    jq -e 'all(.[]; if (.owner | startswith("tls:")) then
        all(.requirements[]; .temporary != true) else true end)' \
        <<<"$(vpsctl network ufw link list --json)" >/dev/null
}
tls_rule_present() {
    jq -e 'any(.[]; .port=="80" and .proto=="tcp" and (.owners | map(startswith("tls:")) | any))' \
        <<<"$(inventory)" >/dev/null
    jq -e 'any(.[]; (.owner | startswith("tls:")) and
        any(.requirements[]; .port=="80" and .proto=="tcp" and .temporary==true))' \
        <<<"$(vpsctl network ufw link list --json)" >/dev/null
}
start_tls_issue() {
    local mode="$1" domain="$2" challenge="$3"
    printf '%s\n' "$mode" >"$fake_root/mode"
    rm -f -- "$fake_root/ready" "$fake_root/release" "$fake_root/args"
    local -a args=(security tls issue --domain "$domain" --challenge "$challenge" --email acceptance@example.test --reload none)
    if [[ "$challenge" == dns-01 ]]; then
        args+=(--dns-provider cloudflare --dns-credential-file "$fake_root/cloudflare.env")
    fi
    setsid bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes "${args[@]}" \
        >"$fake_root/$mode.log" 2>&1 &
    TLS_PROCESS=$!
    for _attempt in {1..100}; do
        if [[ -f "$fake_root/ready" ]]; then
            cp -p -- "$fake_root/args" "$fake_root/$mode.args"
            return 0
        fi
        kill -0 "$TLS_PROCESS" >/dev/null 2>&1 || break
        sleep 0.05
    done
    printf 'FAIL: fake lego did not reach %s ready state\n' "$mode" >&2
    return 1
}
release_tls_issue() {
    : >"$fake_root/release"
}
wait_tls_release() {
    for _attempt in {1..100}; do
        if tls_rule_absent; then return 0; fi
        sleep 0.05
    done
    return 1
}
wait_tls_issue() {
    local expected="$1" status=0
    wait "$TLS_PROCESS" || status=$?
    TLS_PROCESS=''
    [[ "$status" == "$expected" ]] || {
        printf 'FAIL: TLS issue status expected %s, got %s\n' "$expected" "$status" >&2
        return 1
    }
}

TLS_PORT80_BASELINE="$(port80_snapshot)"
tls_rule_absent
start_tls_issue http-success "ufw-http-success-${suffix}.example.test" http-01
tls_rule_present
grep -Fx -- '--http' "$fake_root/args" >/dev/null
grep -Fx -- ':80' "$fake_root/args" >/dev/null
release_tls_issue
wait_tls_issue 0
tls_rule_absent
printf 'PASS: TLS HTTP-01 success held and released a temporary port 80 lease\n'

vpsctl network ufw rule add --action allow --direction in --proto tcp --port 80 --family both --comment accept-tls-existing
TLS_PORT80_BASELINE="$(port80_snapshot)"
start_tls_issue http-existing "ufw-http-existing-${suffix}.example.test" http-01
tls_rule_present
release_tls_issue
wait_tls_issue 0
tls_rule_absent
jq -e 'all(.[]; .comment=="accept-tls-existing" and (.owners|length)==0)' <<<"$TLS_PORT80_BASELINE" >/dev/null
while IFS= read -r existing_id; do
    vpsctl network ufw rule delete --id "$existing_id"
done < <(jq -r '.[].id' <<<"$TLS_PORT80_BASELINE")
TLS_PORT80_BASELINE="$(port80_snapshot)"
printf 'PASS: TLS HTTP-01 borrowed and returned pre-existing IPv4/IPv6 port 80 rules\n'

start_tls_issue failure "ufw-http-failure-${suffix}.example.test" http-01
tls_rule_present
release_tls_issue
wait_tls_issue 20
tls_rule_absent
printf 'PASS: TLS HTTP-01 failure released its temporary port 80 lease\n'

start_tls_issue term "ufw-http-term-${suffix}.example.test" http-01
tls_rule_present
kill -TERM -- "-$TLS_PROCESS"
wait_tls_issue 130
wait_tls_release
printf 'PASS: TLS HTTP-01 TERM released its temporary port 80 lease\n'

start_tls_issue dns-success "ufw-dns-${suffix}.example.test" dns-01
tls_rule_absent
grep -Fx -- '--dns' "$fake_root/args" >/dev/null
grep -Fx -- 'cloudflare' "$fake_root/args" >/dev/null
release_tls_issue
wait_tls_issue 0
tls_rule_absent
printf 'PASS: TLS DNS-01 completed without acquiring a port 80 lease\n'
preserve_tls_logs
restore_tls_baseline
TLS_BASELINE_CAPTURED=0
printf 'PASS: TLS HTTP-01 leases port 80 for success/failure/TERM and DNS-01 never leases it\n'

printf 'PASS: UFW cross-module ownership, rollback, inactive, SSH, and proxy linkage\n'
