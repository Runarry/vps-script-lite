#!/usr/bin/env bash
# Destructive installed-runtime acceptance for the dedicated host-vps-scripts
# machine. This check owns the production relay-forward paths for its duration,
# then restores the captured UFW scope, nft tables, files, service and sysctls.
# shellcheck disable=SC1091,SC2034,SC2129 # Dynamic project sources and sourced globals are intentional.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
[[ "${VPSCTL_UFW_FORWARD_RUNTIME_REAL:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_UFW_FORWARD_RUNTIME_REAL=1 on the dedicated host\n'
    exit 0
}
((EUID == 0)) || { printf 'FAIL: installed relay runtime acceptance requires root\n' >&2; exit 4; }
for tool in apt-get awk bash cat cmp date dpkg-query find getent grep ip6tables-save iptables-save jq mv nft pgrep readlink sed sha256sum sort sysctl systemctl tar tr xargs; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'FAIL: missing %s\n' "$tool" >&2; exit 3; }
done

TEST_TEMP="$(mktemp -d /var/tmp/vpsctl-ufw-forward-runtime.XXXXXX)"
readonly TEST_TEMP
TARGET_HOST="vpsctl-forward-runtime-${BASHPID}.invalid"
TARGET1=198.51.100.41
TARGET2=198.51.100.42
TARGET3=198.51.100.43
TARGET_PORT=$((43000 + BASHPID % 1000))
LISTEN_PORT=$((TARGET_PORT + 1000))
printf -v ID_TOKEN '%016x' "$BASHPID"
printf -v FORWARD_TOKEN '%016x' "$((BASHPID + 1))"
EXIT_ID="exit-${ID_TOKEN}"
FORWARD_ID="forward-${FORWARD_TOKEN}"
SERVICE_NAME=vpsctl-proxy-forward.service
RUNTIME=/usr/local/libexec/vpsctl-proxy-runtime
HELPER=/usr/local/libexec/vpsctl-proxy-forward-refresh
CACHE=/var/lib/vpsctl/service/proxy/relay-resolved.json
BASELINE_ARCHIVE="$TEST_TEMP/baseline.tar"
BASELINE_PATHS="$TEST_TEMP/baseline.paths"
SCOPE_SNAPSHOT="$TEST_TEMP/proxy-forwards.snapshot"
UFW_SNAPSHOT="$TEST_TEMP/ufw-full.snapshot"
TABLE_SNAPSHOT="$TEST_TEMP/relay-tables.nft"
BASELINE_TABLES=0
BASELINE_ENABLED=0
BASELINE_ACTIVE=0
MUTATIONS_STARTED=0
OUTER_MUTATIONS_STARTED=0
PACKAGE_BASELINE=''
OUTER_BASELINE="$TEST_TEMP/outer-baseline"
mkdir -p "$OUTER_BASELINE"

PROXY_PROJECT_ROOT="$TEST_ROOT"
# shellcheck source=../../lib/command.sh
source "$TEST_ROOT/lib/command.sh"
vps_cmd_init 'installed relay runtime real acceptance' "$TEST_ROOT"
# shellcheck source=../../lib/ufw.sh
source "$TEST_ROOT/lib/ufw.sh"
# shellcheck source=../../commands/service/proxy/common.sh
source "$TEST_ROOT/commands/service/proxy/common.sh"
# shellcheck source=../../commands/service/proxy/ufw.sh
source "$TEST_ROOT/commands/service/proxy/ufw.sh"
# shellcheck source=../../commands/service/proxy/relay-forward.sh
source "$TEST_ROOT/commands/service/proxy/relay-forward.sh"
# shellcheck source=../../commands/service/proxy/relay.sh
source "$TEST_ROOT/commands/service/proxy/relay.sh"
proxy_common_init
proxy_relay_init
proxy_relay_forward_init
vps_ufw_init

normalize_inventory() {
    vps_ufw_inventory | jq -cS 'map(del(.number)) | sort_by(.id)'
}

normalize_links() {
    vps_ufw_links | jq -cS 'sort_by(.owner) | map(.requirements |= sort_by(.family,.kind,.proto,.port,.source,.destination))'
}

normalize_scope() {
    vps_ufw_scope_desired proxy-forwards |
        jq -cS 'sort_by(.owner,.family,.kind,.proto,.port,.source,.destination)'
}

normalize_nft_file() {
    sed -E 's/counter packets [0-9]+ bytes [0-9]+/counter/g' "$1"
}

capture_path_manifest() {
    local output="$1" path relative
    : >"$output"
    while IFS= read -r relative; do
        path="/$relative"
        if [[ -L "$path" ]]; then
            printf 'link\t%s\t%s\n' "$relative" "$(readlink -- "$path")" >>"$output"
        elif [[ -f "$path" ]]; then
            printf 'file\t%s\t' "$relative" >>"$output"
            sha256sum "$path" | awk '{print $1}' >>"$output"
        elif [[ -d "$path" ]]; then
            printf 'dir\t%s\n' "$relative" >>"$output"
            find -P "$path" -mindepth 1 -printf '%y\t%m\t%u\t%g\t%p\n' | LC_ALL=C sort |
                sed "s#\t/#\t#" >>"$output"
            find -P "$path" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum |
                sed 's#  /#  #' >>"$output"
        else
            printf 'absent\t%s\n' "$relative" >>"$output"
        fi
    done <"$TEST_TEMP/all.paths"
}

snapshot_tables() {
    local output="$1" status=0
    proxy_relay_forward_nft_snapshot "$output" || status=$?
    [[ "$status" == 0 || "$status" == 1 ]] || return "$status"
    return "$status"
}

restore_tables() {
    if ((BASELINE_TABLES == 1)); then
        proxy_relay_forward_nft_restore "$TABLE_SNAPSHOT"
    else
        proxy_relay_forward_nft_clear
    fi
}

capture_ufw_baseline() {
    local status=0
    vps_ufw_lock || return $?
    vps_ufw_snapshot "$UFW_SNAPSHOT" || status=$?
    vps_ufw_unlock || return 70
    return "$status"
}

restore_ufw_baseline() {
    local status=0 unlock_status=0
    vps_ufw_lock || return $?
    vps_ufw_restore "$UFW_SNAPSHOT" || status=$?
    vps_ufw_unlock || unlock_status=$?
    ((unlock_status == 0)) || return 70
    return "$status"
}

wait_watch_sleep() {
    local pid
    for _attempt in {1..200}; do
        systemctl is-active --quiet "$SERVICE_NAME" || return 1
        pid="$(systemctl show "$SERVICE_NAME" -p MainPID --value)"
        if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && pgrep -P "$pid" -x sleep >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

write_host() {
    local address="$1"
    cp -p -- "$TEST_TEMP/hosts.original" /etc/hosts
    printf '%s %s # vpsctl-forward-runtime-acceptance\n' "$address" "$TARGET_HOST" >>/etc/hosts
}

stage_test_state() {
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p /var/lib/vpsctl/service/proxy
    chmod 0700 /var/lib/vpsctl/service/proxy
    proxy_manifest_default >/var/lib/vpsctl/service/proxy/nodes.json
    jq -n --arg host "$TARGET_HOST" --arg exit "$EXIT_ID" --arg forward "$FORWARD_ID" --arg now "$now" \
        --argjson target_port "$TARGET_PORT" --argjson listen_port "$LISTEN_PORT" '
        {schema_version:1,
         exits:[{id:$exit,name:"runtime acceptance",type:"direct",
                 endpoint:{host:$host,port:$target_port},network_hint:"tcp",
                 created_at:$now,updated_at:$now}],
         bindings:[],
         forwards:[{id:$forward,name:"runtime acceptance",exit_id:$exit,
                    listen_port_start:$listen_port,listen_port_end:$listen_port,
                    network:"tcp",family:"ipv4",publish_address:"127.0.0.1",
                    created_at:$now,updated_at:$now}]}' \
        >/var/lib/vpsctl/service/proxy/relay.json
    chmod 0600 /var/lib/vpsctl/service/proxy/nodes.json /var/lib/vpsctl/service/proxy/relay.json
}

assert_target() {
    local wanted="$1" rejected="${2:-}" inventory nft_rules
    jq -e --arg id "$EXIT_ID" --arg wanted "$wanted" '.exits[$id].ipv4 == $wanted' "$CACHE" >/dev/null
    inventory="$(vps_ufw_inventory)"
    jq -e --arg owner "forward:$FORWARD_ID" --arg wanted "$wanted" --arg port "$TARGET_PORT" \
        'any(.[]; .kind=="route" and .family=="ipv4" and .proto=="tcp" and .port==$port and
          .destination==$wanted and (.owners|index($owner)))' <<<"$inventory" >/dev/null
    nft_rules="$(nft list table ip vpsctl_proxy_forward4)"
    grep -Fq "dnat to $wanted:$TARGET_PORT" <<<"$nft_rules"
    if [[ -n "$rejected" ]]; then
        jq -e --arg owner "forward:$FORWARD_ID" --arg rejected "$rejected" \
            'all(.[]; .destination!=$rejected or (.owners|index($owner)|not))' <<<"$inventory" >/dev/null
        if grep -Fq "dnat to $rejected:$TARGET_PORT" <<<"$nft_rules"; then
            printf 'FAIL: stale nft target retained: %s\n' "$rejected" >&2
            return 1
        fi
    fi
}

package_status() {
    local status
    status="$(dpkg-query -W -f='${Status}\n' ufw 2>/dev/null || true)"
    [[ "$status" == 'install ok installed' ]] && printf 'installed\n' || printf 'absent\n'
}

snapshot_outer_baseline() {
    local key path
    : >"$OUTER_BASELINE/paths.present"
    for path in etc/ufw etc/default/ufw var/lib/ufw var/lib/vpsctl/network/ufw; do
        [[ ! -e "/$path" && ! -L "/$path" ]] || printf '%s\n' "$path" >>"$OUTER_BASELINE/paths.present"
    done
    if [[ -s "$OUTER_BASELINE/paths.present" ]]; then
        tar -C / -cpf "$OUTER_BASELINE/paths.tar" -T "$OUTER_BASELINE/paths.present"
    fi
    nft list ruleset >"$OUTER_BASELINE/nft.rules"
    iptables-save >"$OUTER_BASELINE/iptables.rules"
    ip6tables-save >"$OUTER_BASELINE/ip6tables.rules"
    : >"$OUTER_BASELINE/sysctls"
    for key in \
        net.ipv4.ip_forward net.ipv6.conf.default.forwarding net.ipv6.conf.all.forwarding \
        net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter \
        net.ipv4.icmp_echo_ignore_broadcasts net.ipv4.icmp_ignore_bogus_error_responses \
        net.ipv4.icmp_echo_ignore_all net.ipv4.conf.all.log_martians \
        net.ipv4.conf.default.log_martians net.ipv6.conf.all.accept_redirects \
        net.ipv6.conf.default.accept_redirects; do
        if sysctl -n "$key" >/dev/null 2>&1; then
            printf '%s=%s\n' "$key" "$(sysctl -n "$key")" >>"$OUTER_BASELINE/sysctls"
        fi
    done
}

restore_outer_baseline() {
    local assignment path now="$TEST_TEMP/outer-nft.after" restore="$TEST_TEMP/outer-nft.restore"
    if command -v ufw >/dev/null 2>&1; then ufw --force disable >/dev/null 2>&1 || return 1; fi
    if [[ "$(package_status)" == installed ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y ufw >/dev/null || return 1
    fi
    for path in /etc/ufw /etc/default/ufw /var/lib/ufw /var/lib/vpsctl/network/ufw; do
        rm -rf -- "$path"
    done
    [[ ! -f "$OUTER_BASELINE/paths.tar" ]] || tar -C / -xpf "$OUTER_BASELINE/paths.tar"
    while IFS= read -r assignment; do
        [[ -n "$assignment" ]] || continue
        sysctl -q -w "$assignment" >/dev/null || return 1
    done <"$OUTER_BASELINE/sysctls"
    systemctl daemon-reload >/dev/null 2>&1 || true
    nft list ruleset >"$now"
    if ! cmp -s "$OUTER_BASELINE/nft.rules" "$now"; then
        { printf 'flush ruleset\n'; cat "$OUTER_BASELINE/nft.rules"; } >"$restore"
        nft -c -f "$restore" && nft -f "$restore" || return 1
    fi
    iptables-save >"$TEST_TEMP/outer-iptables.after"
    ip6tables-save >"$TEST_TEMP/outer-ip6tables.after"
    cmp -s "$OUTER_BASELINE/iptables.rules" "$TEST_TEMP/outer-iptables.after" || return 1
    cmp -s "$OUTER_BASELINE/ip6tables.rules" "$TEST_TEMP/outer-ip6tables.after" || return 1
    [[ "$(package_status)" == "$PACKAGE_BASELINE" ]] || return 1
    if [[ -s "$OUTER_BASELINE/paths.present" ]]; then
        tar -C / -cpf "$TEST_TEMP/outer-paths.after.tar" -T "$OUTER_BASELINE/paths.present"
        cmp -s "$OUTER_BASELINE/paths.tar" "$TEST_TEMP/outer-paths.after.tar" || return 1
    fi
}

report_error() {
    local status=$?
    printf 'FAIL: shell error status=%s at %s:%s function=%s\n' \
        "$status" "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]}" "${FUNCNAME[1]:-main}" >&2
    return "$status"
}

cleanup() {
    local original_status=$? cleanup_status=0 table_status=0
    trap - EXIT HUP INT TERM
    if ((MUTATIONS_STARTED == 1)); then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -rf -- \
            /var/lib/vpsctl/service/proxy \
            /usr/local/libexec/vpsctl-proxy-runtime \
            /usr/local/libexec/vpsctl-proxy-forward-refresh \
            /etc/systemd/system/vpsctl-proxy-forward.service \
            /etc/sysctl.d/90-vpsctl-proxy-forward.conf
        [[ ! -s "$BASELINE_ARCHIVE" ]] || tar -C / -xpf "$BASELINE_ARCHIVE" || cleanup_status=1
        cp -p -- "$TEST_TEMP/hosts.original" /etc/hosts || cleanup_status=1
        systemctl daemon-reload >/dev/null 2>&1 || cleanup_status=1
        if ((BASELINE_ENABLED == 1)); then systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || cleanup_status=1; fi
        if ((BASELINE_ACTIVE == 1)); then
            systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || cleanup_status=1
            wait_watch_sleep || cleanup_status=1
            # The restored helper refreshes once before sleeping. Restore the
            # byte-exact state captured before the check, then restore its exact
            # UFW/nft transaction outputs while the helper is idle.
            [[ ! -s "$BASELINE_ARCHIVE" ]] || tar -C / -xpf "$BASELINE_ARCHIVE" || cleanup_status=1
        fi
        restore_ufw_baseline >/dev/null 2>&1 || cleanup_status=1
        restore_tables >/dev/null 2>&1 || cleanup_status=1
        sysctl -q -w "net.ipv4.ip_forward=$(<"$TEST_TEMP/ip4-forward")" >/dev/null || cleanup_status=1
        sysctl -q -w "net.ipv6.conf.all.forwarding=$(<"$TEST_TEMP/ip6-forward")" >/dev/null || cleanup_status=1
        capture_path_manifest "$TEST_TEMP/paths.after" || cleanup_status=1
        normalize_inventory >"$TEST_TEMP/inventory.after" || cleanup_status=1
        normalize_links >"$TEST_TEMP/links.after" || cleanup_status=1
        normalize_scope >"$TEST_TEMP/scope.after" || cleanup_status=1
        sysctl -n net.ipv4.ip_forward >"$TEST_TEMP/ip4-forward.after" || cleanup_status=1
        sysctl -n net.ipv6.conf.all.forwarding >"$TEST_TEMP/ip6-forward.after" || cleanup_status=1
        systemctl is-active "$SERVICE_NAME" >"$TEST_TEMP/service-active.after" 2>&1 || true
        systemctl is-enabled "$SERVICE_NAME" >"$TEST_TEMP/service-enabled.after" 2>&1 || true
        cmp -s "$TEST_TEMP/paths.before" "$TEST_TEMP/paths.after" || cleanup_status=1
        [[ "$(sha256sum /etc/hosts | awk '{print $1}')" == "$(<"$TEST_TEMP/hosts.sha")" ]] || cleanup_status=1
        cmp -s "$TEST_TEMP/inventory.before" "$TEST_TEMP/inventory.after" || cleanup_status=1
        cmp -s "$TEST_TEMP/links.before" "$TEST_TEMP/links.after" || cleanup_status=1
        cmp -s "$TEST_TEMP/scope.before" "$TEST_TEMP/scope.after" || cleanup_status=1
        cmp -s "$TEST_TEMP/ip4-forward" "$TEST_TEMP/ip4-forward.after" || cleanup_status=1
        cmp -s "$TEST_TEMP/ip6-forward" "$TEST_TEMP/ip6-forward.after" || cleanup_status=1
        if ((BASELINE_TABLES == 1)); then
            snapshot_tables "$TEST_TEMP/relay-tables.after.nft" || cleanup_status=1
            normalize_nft_file "$TABLE_SNAPSHOT" >"$TEST_TEMP/relay-tables.before.normalized"
            normalize_nft_file "$TEST_TEMP/relay-tables.after.nft" >"$TEST_TEMP/relay-tables.after.normalized"
            cmp -s "$TEST_TEMP/relay-tables.before.normalized" "$TEST_TEMP/relay-tables.after.normalized" || cleanup_status=1
        else
            snapshot_tables "$TEST_TEMP/relay-tables.after.nft" || table_status=$?
            [[ "$table_status" == 1 ]] || cleanup_status=1
        fi
        if ((BASELINE_ACTIVE == 1)); then
            systemctl is-active --quiet "$SERVICE_NAME" || cleanup_status=1
        elif systemctl is-active --quiet "$SERVICE_NAME"; then
            cleanup_status=1
        fi
        if ((BASELINE_ENABLED == 1)); then
            systemctl is-enabled --quiet "$SERVICE_NAME" || cleanup_status=1
        elif systemctl is-enabled --quiet "$SERVICE_NAME"; then
            cleanup_status=1
        fi
        if ((cleanup_status == 0)); then
            printf 'PASS: restored original UFW scope, nft tables, proxy files, service state, hosts, and forwarding sysctls\n'
        else
            printf 'FAIL: baseline restoration verification failed; artifacts retained at %s\n' "$TEST_TEMP" >&2
        fi
    fi
    if ((OUTER_MUTATIONS_STARTED == 1)); then
        if restore_outer_baseline; then
            printf 'PASS: restored UFW package/path, sysctl, nft, iptables, and ip6tables outer baseline\n'
        else
            cleanup_status=1
            printf 'FAIL: outer UFW baseline restoration failed; artifacts retained at %s\n' "$TEST_TEMP" >&2
        fi
    fi
    if ((original_status == 0 && cleanup_status == 0)); then
        rm -rf -- "$TEST_TEMP"
        exit 0
    fi
    ((original_status != 0)) || original_status=30
    exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
trap report_error ERR

PACKAGE_BASELINE="$(package_status)"
[[ "$PACKAGE_BASELINE" == absent ]] || {
    printf 'FAIL: dedicated outer baseline requires UFW package absent\n' >&2
    exit 3
}
snapshot_outer_baseline
printf 'INFO: outer baseline nft=%s paths=%s package=%s\n' \
    "$(sha256sum "$OUTER_BASELINE/nft.rules" | awk '{print $1}')" \
    "$([[ -f "$OUTER_BASELINE/paths.tar" ]] && sha256sum "$OUTER_BASELINE/paths.tar" | awk '{print $1}' || printf absent)" \
    "$PACKAGE_BASELINE"
OUTER_MUTATIONS_STARTED=1
bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes --install-deps network ufw install
bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes network ufw install
bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes network ufw ipv6 on
bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes network ufw enable
command -v ufw >/dev/null
LC_ALL=C ufw status | grep -Fqx 'Status: active'
[[ ! -e /var/lib/vpsctl/network/ufw/pending.json ]] || {
    printf 'FAIL: UFW setup left a transaction journal\n' >&2
    exit 3
}
printf 'PASS: installed and enabled UFW for isolated runtime transaction window\n'

printf '%s\n' \
    var/lib/vpsctl/service/proxy \
    usr/local/libexec/vpsctl-proxy-runtime \
    usr/local/libexec/vpsctl-proxy-forward-refresh \
    etc/systemd/system/vpsctl-proxy-forward.service \
    etc/sysctl.d/90-vpsctl-proxy-forward.conf >"$TEST_TEMP/all.paths"
: >"$BASELINE_PATHS"
while IFS= read -r path; do
    [[ ! -e "/$path" && ! -L "/$path" ]] || printf '%s\n' "$path" >>"$BASELINE_PATHS"
done <"$TEST_TEMP/all.paths"
[[ ! -s "$BASELINE_PATHS" ]] || tar -C / -cpf "$BASELINE_ARCHIVE" -T "$BASELINE_PATHS"
cp -p -- /etc/hosts "$TEST_TEMP/hosts.original"
sha256sum /etc/hosts | awk '{print $1}' >"$TEST_TEMP/hosts.sha"
sysctl -n net.ipv4.ip_forward >"$TEST_TEMP/ip4-forward"
sysctl -n net.ipv6.conf.all.forwarding >"$TEST_TEMP/ip6-forward"
systemctl is-enabled --quiet "$SERVICE_NAME" >/dev/null 2>&1 && BASELINE_ENABLED=1
systemctl is-active --quiet "$SERVICE_NAME" >/dev/null 2>&1 && BASELINE_ACTIVE=1
vps_ufw_scope_snapshot proxy-forwards "$SCOPE_SNAPSHOT"
capture_ufw_baseline
if snapshot_tables "$TABLE_SNAPSHOT"; then BASELINE_TABLES=1; else [[ "$?" == 1 ]]; fi
normalize_inventory >"$TEST_TEMP/inventory.before"
normalize_links >"$TEST_TEMP/links.before"
normalize_scope >"$TEST_TEMP/scope.before"
capture_path_manifest "$TEST_TEMP/paths.before"
MUTATIONS_STARTED=1

systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
rm -rf -- \
    /var/lib/vpsctl/service/proxy \
    /usr/local/libexec/vpsctl-proxy-runtime \
    /usr/local/libexec/vpsctl-proxy-forward-refresh \
    /etc/systemd/system/vpsctl-proxy-forward.service \
    /etc/sysctl.d/90-vpsctl-proxy-forward.conf
systemctl daemon-reload
proxy_relay_forward_nft_clear
write_host "$TARGET1"
stage_test_state

proxy_relay_forward_install_service
wait_watch_sleep || { printf 'FAIL: installed helper did not reach background watch sleep\n' >&2; exit 1; }
cmp -s "$TEST_ROOT/lib/ufw.sh" "$RUNTIME/lib/ufw.sh"
cmp -s "$TEST_ROOT/commands/service/proxy/ufw.sh" "$RUNTIME/commands/service/proxy/ufw.sh"
cmp -s "$TEST_ROOT/commands/service/proxy/relay-forward.sh" "$RUNTIME/commands/service/proxy/relay-forward.sh"
main_pid="$(systemctl show "$SERVICE_NAME" -p MainPID --value)"
main_command="$(tr '\0' ' ' <"/proc/$main_pid/cmdline")"
grep -Fq 'vpsctl-proxy-forward-refresh watch' <<<"$main_command"
assert_target "$TARGET1"
printf 'PASS: production installer copied UFW dependencies and started installed helper watch\n'

write_host "$TARGET2"
systemctl reload "$SERVICE_NAME"
assert_target "$TARGET2" "$TARGET1"
printf 'PASS: systemd reload used installed helper/runtime for production UFW+DNS+nft apply\n'

failure_inventory="$(normalize_inventory)"
failure_links="$(normalize_links)"
failure_scope="$(normalize_scope)"
failure_cache_sha="$(sha256sum "$CACHE" | awk '{print $1}')"
failure_state_sha="$(sha256sum /var/lib/vpsctl/network/ufw/state.json | awk '{print $1}')"
snapshot_tables "$TEST_TEMP/failure-before.nft"
write_host "$TARGET3"
mkdir -p "$TEST_TEMP/fail-bin"
cat >"$TEST_TEMP/fail-bin/mv" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%q ' "\$@" >>'$TEST_TEMP/mv.calls'
printf '\n' >>'$TEST_TEMP/mv.calls'
target="\${!#}"
if [[ "\$target" == '$CACHE' && ! -e '$TEST_TEMP/mv.failed-once' ]]; then
    : >'$TEST_TEMP/mv.failed-once'
    exit 42
fi
exec /usr/bin/mv "\$@"
EOF
cat >"$TEST_TEMP/fail-bin/ufw" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%q ' "\$@" >>'$TEST_TEMP/ufw.calls'
printf '\n' >>'$TEST_TEMP/ufw.calls'
exec /usr/sbin/ufw "\$@"
EOF
chmod 0700 "$TEST_TEMP/fail-bin/mv" "$TEST_TEMP/fail-bin/ufw"
failure_status=0
PATH="$TEST_TEMP/fail-bin:$PATH" "$HELPER" refresh >"$TEST_TEMP/failure.log" 2>&1 || failure_status=$?
[[ "$failure_status" == 20 ]] || {
    printf 'FAIL: cache commit injection returned %s, expected 20\n' "$failure_status" >&2
    exit 1
}
[[ -e "$TEST_TEMP/mv.failed-once" ]]
grep -Fq "to $TARGET3 port $TARGET_PORT" "$TEST_TEMP/ufw.calls"
grep -Fq 'reload ' "$TEST_TEMP/ufw.calls"
[[ "$(sha256sum "$CACHE" | awk '{print $1}')" == "$failure_cache_sha" ]]
[[ "$(sha256sum /var/lib/vpsctl/network/ufw/state.json | awk '{print $1}')" == "$failure_state_sha" ]]
[[ "$(normalize_inventory)" == "$failure_inventory" ]]
[[ "$(normalize_links)" == "$failure_links" ]]
[[ "$(normalize_scope)" == "$failure_scope" ]]
snapshot_tables "$TEST_TEMP/failure-after.nft"
normalize_nft_file "$TEST_TEMP/failure-before.nft" >"$TEST_TEMP/failure-before.normalized"
normalize_nft_file "$TEST_TEMP/failure-after.nft" >"$TEST_TEMP/failure-after.normalized"
cmp -s "$TEST_TEMP/failure-before.normalized" "$TEST_TEMP/failure-after.normalized"
[[ ! -e /var/lib/vpsctl/network/ufw/pending.json ]]
assert_target "$TARGET2" "$TARGET3"
printf 'PASS: one-shot cache commit failure restored cache, nft tables, UFW rules/state, and closed journal\n'

write_host "$TARGET2"
printf 'PASS: installed relay runtime production transaction acceptance\n'
