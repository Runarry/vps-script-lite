#!/usr/bin/env bash
# Run only on the dedicated host (see AGENTS.md). This suite uses isolated UFW
# files and a command double; it never changes the host firewall.
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
readonly TEST_ROOT TEST_TEMP
trap 'rm -rf -- "$TEST_TEMP"' EXIT
# shellcheck source=/dev/null
source "$TEST_ROOT/lib/command.sh"
# shellcheck source=/dev/null
source "$TEST_ROOT/lib/ufw.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected $1, got $2"; }
assert_json() { jq -e "$2" <<<"$1" >/dev/null || fail "$3"; }

setup() {
    VPSCTL_TESTING=1
    VPSCTL_DRY_RUN=0
    VPSCTL_NON_INTERACTIVE=1
    VPSCTL_NO_COLOR=1
    VPSCTL_SYSTEM_ROOT="$TEST_TEMP/$1"
    mkdir -p "$VPSCTL_SYSTEM_ROOT/etc/ufw" "$VPSCTL_SYSTEM_ROOT/etc/default" "$VPSCTL_SYSTEM_ROOT/run"
    printf 'IPV6=yes\n' >"$VPSCTL_SYSTEM_ROOT/etc/default/ufw"
    printf 'ENABLED=yes\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf"
    : >"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules"
    : >"$VPSCTL_SYSTEM_ROOT/etc/ufw/user6.rules"
    : >"$VPSCTL_SYSTEM_ROOT/run/ufw-active"
    : >"$VPSCTL_SYSTEM_ROOT/run/mutations"
    vps_cmd_init ufw-library-test "$TEST_ROOT"
    vps_ufw_init
}

# Emit the documented UFW 0.36 tuple and associated iptables stanza. No library
# parsing/normalization helpers are used by this command double.
fixture_rule() {
    local family="$1" kind="$2" action="$3" proto="$4" port="$5" destination="$6" source="$7" comment="$8"
    local chain=ufw-user-input direction=in hex=''
    [[ "$family" != ipv6 ]] || chain=ufw6-user-input
    if [[ "$kind" == route ]]; then
        action="route:$action"
        chain="${chain%input}forward"
    fi
    if [[ "$kind" == output ]]; then
        direction=out
        chain="${chain%input}output"
    fi
    if [[ -n "$comment" ]]; then hex="$(printf '%s' "$comment" | od -An -tx1 | tr -d ' \n')"; fi
    printf '### tuple ### %s %s %s %s any %s %s' "$action" "$proto" "$port" "$destination" "$source" "$direction"
    [[ -z "$hex" ]] || printf ' comment=%s' "$hex"
    printf '\n-A %s -p %s' "$chain" "$proto"
    [[ "$destination" == 0.0.0.0/0 || "$destination" == ::/0 ]] || printf ' -d %s' "$destination"
    if [[ "$port" == *:* ]]; then
        printf ' -m multiport --dports %s' "$port"
    else printf ' --dport %s' "$port"; fi
    [[ "$source" == 0.0.0.0/0 || "$source" == ::/0 ]] || printf ' -s %s' "$source"
    case "$action" in allow | route:allow) printf ' -j ACCEPT\n\n' ;; *) printf ' -j DROP\n\n' ;; esac
}

seed() {
    local family="$1" file="$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules"
    [[ "$family" != ipv6 ]] || file="$VPSCTL_SYSTEM_ROOT/etc/ufw/user6.rules"
    fixture_rule "$@" >>"$file"
}

ufw() {
    local first="${1:-}" kind=input source='' destination='' port='' proto='' comment='' family=ipv4 position=''
    local file number ipv4_count current_count temp
    if [[ "$first" == status ]]; then
        [[ ! -e "$VPSCTL_SYSTEM_ROOT/run/status-error" ]] || return 1
        if [[ -e "$VPSCTL_SYSTEM_ROOT/run/ufw-active" ]]; then printf 'Status: active\n'; else printf 'Status: inactive\n'; fi
        return 0
    fi
    printf '%s\n' "$*" >>"$VPSCTL_SYSTEM_ROOT/run/mutations"
    if [[ "$first" == reload ]]; then return 0; fi
    if [[ "$first" == --force ]]; then
        shift
        case "$1" in
            enable)
                : >"$VPSCTL_SYSTEM_ROOT/run/ufw-active"
                return 0
                ;;
            disable)
                rm -f "$VPSCTL_SYSTEM_ROOT/run/ufw-active"
                return 0
                ;;
            delete)
                [[ ! -e "$VPSCTL_SYSTEM_ROOT/run/delete-fail" ]] || return 1
                number="$2"
                file="$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules"
                ipv4_count="$(awk '/^### tuple ### / {n++} END {print n+0}' "$file")"
                if ((number > ipv4_count)); then
                    number=$((number - ipv4_count))
                    file="$VPSCTL_SYSTEM_ROOT/etc/ufw/user6.rules"
                fi
                temp="$file.next"
                awk -v wanted="$number" '/^### tuple ### / {n++; skip=(n==wanted)} !skip {print} /^$/ {skip=0}' "$file" >"$temp"
                mv "$temp" "$file"
                return 0
                ;;
        esac
    fi
    if [[ "${1:-}" == route ]]; then
        kind=route
        shift
    fi
    if [[ "${1:-}" == insert ]]; then
        position="$2"
        shift 2
    fi
    [[ "${1:-}" == allow ]] || return 2
    shift
    while (($#)); do
        case "$1" in
            out)
                kind=output
                shift
                ;;
            proto)
                proto="$2"
                shift 2
                ;;
            from)
                source="$2"
                shift 2
                ;;
            to)
                destination="$2"
                shift 2
                ;;
            port)
                port="$2"
                shift 2
                ;;
            comment)
                comment="$2"
                shift 2
                ;;
            *) return 2 ;;
        esac
    done
    if [[ -r "$VPSCTL_SYSTEM_ROOT/run/fail-port" && "$port" == "$(<"$VPSCTL_SYSTEM_ROOT/run/fail-port")" ]]; then return 1; fi
    if [[ "$source$destination" == *:* ]]; then family=ipv6; fi
    file="$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules"
    [[ "$family" != ipv6 ]] || file="$VPSCTL_SYSTEM_ROOT/etc/ufw/user6.rules"
    if [[ -z "$position" ]]; then
        fixture_rule "$family" "$kind" allow "$proto" "$port" "$destination" "$source" "$comment" >>"$file"
    else
        if [[ "$family" == ipv6 ]]; then
            ipv4_count="$(awk '/^### tuple ### / {n++} END {print n+0}' "$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")"
            position=$((position - ipv4_count))
        fi
        current_count="$(awk '/^### tuple ### / {n++} END {print n+0}' "$file")"
        fixture_rule "$family" "$kind" allow "$proto" "$port" "$destination" "$source" "$comment" >"$file.insert"
        if ((position > current_count)); then
            cat "$file.insert" >>"$file"
        else
            awk -v wanted="$position" -v insert="$file.insert" '
              /^### tuple ### / {n++; if(n==wanted) {while((getline line < insert)>0) print line; close(insert)}}
              {print}' "$file" >"$file.next"
            mv "$file.next" "$file"
        fi
        rm -f "$file.insert"
    fi
}

desired() {
    local owner="$1" port="$2" temporary="${3:-false}" family="${4:-ipv4}" kind="${5:-input}"
    jq -cn --arg owner "$owner" --arg port "$port" --arg family "$family" --arg kind "$kind" --argjson temporary "$temporary" \
        '[{owner:$owner,kind:$kind,family:$family,proto:"tcp",port:$port,source:"any",destination:"any",temporary:$temporary}]'
}

apply() {
    local scope="$1" json="$2" mode="${3:-auto}"
    printf '%s\n' "$json" >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin "$scope" "$VPSCTL_SYSTEM_ROOT/run/desired.json" "$mode"
    vps_ufw_commit
}

test_disabled() (
    setup disabled
    rm "$VPSCTL_SYSTEM_ROOT/run/ufw-active"
    printf 'IPV6=no\n' >"$VPSCTL_SYSTEM_ROOT/etc/default/ufw"
    apply proxy-nodes "$(desired node:a 8443 false ipv6)"
    assert_json "$(vps_ufw_scope_desired proxy-nodes)" 'length==1 and .[0].family=="ipv6"' 'disabled requirements persisted'
    assert_equal '' "$(<"$VPSCTL_SYSTEM_ROOT/run/mutations")" 'disabled must not mutate UFW'
    assert_equal '[]' "$(vps_ufw_inventory)" 'disabled inventory remains empty'
    apply ssh "$(desired ssh 22)" force
    assert_json "$(vps_ufw_inventory)" 'length==1 and .[0].port=="22"' 'force preinstalls before enable'
)

test_shared_references() (
    setup references
    apply proxy-nodes "$(desired node:a 8443)"
    apply ssh "$(desired ssh 8443)"
    assert_json "$(vps_ufw_inventory)" 'length==1 and (.[0].owners|sort)==["node:a","ssh"]' 'same endpoint shares one rule'
    apply proxy-nodes '[]'
    assert_json "$(vps_ufw_inventory)" 'length==1 and .[0].owners==["ssh"]' 'first release preserves shared rule'
    apply ssh '[]'
    assert_json "$(vps_ufw_inventory)" 'length==0' 'last owner removes rule'
)

test_adoption_and_leases() (
    local pid="$BASHPID" original
    setup adoption
    seed ipv4 input allow tcp 80 0.0.0.0/0 0.0.0.0/0 'administrator HTTP'
    original="$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")"
    apply tls-lease "$(desired tls:lease 80 true)"
    assert_json "$(cat "$VPS_UFW_STATE_FILE")" ".leases[\"tls:lease\"].pid==$pid and (.managed|length)==0" 'lease owns process, borrows manual rule'
    apply tls-lease '[]'
    assert_equal "$original" "$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")" 'temporary borrow preserves exact manual content'
    seed ipv4 input allow tcp 8000:9000 0.0.0.0/0 0.0.0.0/0 'broad operator rule'
    seed ipv4 input allow tcp 8443 0.0.0.0/0 0.0.0.0/0 'operator exact'
    : >"$VPSCTL_SYSTEM_ROOT/run/mutations"
    apply proxy-nodes "$(desired node:a 8443)"
    assert_equal '' "$(<"$VPSCTL_SYSTEM_ROOT/run/mutations")" 'permanent adoption does not rewrite comment or duplicate'
    assert_json "$(cat "$VPS_UFW_STATE_FILE")" 'any(.managed[]; .origin=="adopted" and .rule.comment=="operator exact")' 'original adopted content retained'
    apply proxy-nodes '[]'
    assert_json "$(vps_ufw_inventory)" 'length==2 and any(.[]; .port=="8000:9000") and all(.[]; .port!="8443")' 'only exact adopted rule retired'
    apply tls-live "$(desired tls:live 9443 true)"
    apply proxy-nodes "$(desired node:b 9443)"
    apply tls-live '[]'
    assert_json "$(vps_ufw_inventory)" 'any(.[]; .port=="9443" and .owners==["node:b"])' 'permanent owner protects formerly temporary rule'
)

test_rollback_and_nesting() (
    local before status=0
    setup rollback
    seed ipv4 input allow tcp 22 0.0.0.0/0 0.0.0.0/0 'original SSH'
    before="$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")"
    printf '8081\n' >"$VPSCTL_SYSTEM_ROOT/run/fail-port"
    jq -s 'add' <(desired node:a 8080) <(desired node:b 8081) >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json" || status=$?
    assert_equal 20 "$status" 'partial add reports failure'
    assert_equal "$before" "$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")" 'failed begin restores all rule content'
    assert_equal 0 "$VPS_UFW_DEPTH" 'failed begin closes frame'
    [[ ! -e "$VPS_UFW_STATE_FILE" ]] || fail 'failed first transaction left candidate state'
    rm "$VPSCTL_SYSTEM_ROOT/run/fail-port"
    desired node:a 8443 >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json"
    desired forward:a 8080 false ipv4 route >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin proxy-forwards "$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_commit
    vps_ufw_rollback
    assert_equal "$before" "$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")" 'outer rollback includes committed inner transaction'
    vps_cmd_lock independent
    desired node:a 7443 >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json"
    [[ -n "$VPS_CMD_LOCK_FD" && "$VPS_UFW_LOCK_FD" != "$VPS_CMD_LOCK_FD" ]] || fail 'UFW replaced command lock FD'
    desired node:a 7444 >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_commit
    vps_ufw_commit
    assert_json "$(vps_ufw_inventory)" 'any(.[];.port=="7444") and all(.[];.port!="7443")' 'same-scope nested commit keeps newest desired'
    vps_cmd_unlock
)

test_commit_cleanup_failure() (
    local status=0
    setup cleanup
    apply proxy-nodes "$(desired node:a 8000)"
    : >"$VPSCTL_SYSTEM_ROOT/run/delete-fail"
    desired node:a 8001 >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_commit || status=$?
    assert_equal 30 "$status" 'cleanup failure is partial commit'
    assert_equal 0 "$VPS_UFW_DEPTH" 'partial commit releases frame'
    assert_equal 0 "$VPS_UFW_LOCK_COUNT" 'partial commit releases lock'
    assert_json "$(vps_ufw_scope_desired proxy-nodes)" 'length==1 and .[0].port=="8001"' 'new running endpoint remains desired'
    assert_json "$(vps_ufw_inventory)" 'length==2 and any(.[];.port=="8001")' 'cleanup failure retains new allow'
    assert_json "$(cat "$VPS_UFW_JOURNAL")" '.phase=="cleanup-pending"' 'cleanup journal survives'
    vps_ufw_rollback
    rm "$VPSCTL_SYSTEM_ROOT/run/delete-fail"
    apply proxy-nodes "$(desired node:a 8001)"
    assert_json "$(vps_ufw_inventory)" 'length==1 and .[0].port=="8001"' 'later transaction retries old cleanup'
)

test_conflicts_and_detach() (
    local status=0 id before
    setup conflicts
    seed ipv4 input allow tcp 443 0.0.0.0/0 192.0.2.1 'source restriction'
    before="$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")"
    desired node:a 443 >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json" || status=$?
    assert_equal 3 "$status" 'restricted allow blocks widening'
    assert_equal "$before" "$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")" 'conflict preserves source restriction'
    apply proxy-nodes "$(desired node:a 8443)"
    id="$(vps_ufw_inventory | jq -r '.[]|select(.port=="8443")|.id')"
    vps_ufw_rule_protected "$id" || fail 'active service rule not protected'
    vps_ufw_link_set node:a detached
    if vps_ufw_rule_protected "$id"; then fail 'detached only owner still protects manual rule'; fi
    apply proxy-nodes '[]'
    assert_json "$(vps_ufw_inventory)" 'any(.[];.port=="8443" and .owners==[])' 'detach retains manual endpoint after service removal'
    apply proxy-nodes "$(desired node:a 9443)"
    assert_json "$(vps_ufw_inventory)" 'all(.[];.port!="9443")' 'detached service is not automatically readded'
)

test_scoped_ssh_restore() (
    local snapshot
    setup scoped
    snapshot="$VPSCTL_SYSTEM_ROOT/run/ssh-snapshot.json"
    seed ipv4 input allow tcp 22 0.0.0.0/0 0.0.0.0/0 'legacy original SSH'
    vps_ufw_scope_snapshot ssh "$snapshot"
    apply ssh "$(jq -s add <(desired ssh 22) <(desired ssh 2222))"
    apply proxy-nodes "$(desired node:a 8443)"
    apply ssh "$(desired ssh 2222)"
    assert_json "$(vps_ufw_inventory)" 'all(.[];.port!="22")' 'SSH commit retires originally manual old port'
    vps_ufw_scope_restore_begin ssh "$snapshot"
    assert_json "$(vps_ufw_inventory)" 'any(.[];.port=="22") and any(.[];.port=="2222")' 'restore opens old SSH before retiring current port'
    vps_ufw_commit
    assert_json "$(vps_ufw_inventory)" 'length==2 and any(.[];.port=="22" and .comment=="legacy original SSH" and .owners==[]) and
      any(.[];.port=="8443" and .owners==["node:a"])' 'scope restore restores manual old SSH and preserves other service'
    assert_json "$(vps_ufw_scope_desired ssh)" 'length==0' 'scope restore retains pre-migration ownership state'
)

test_ipv6_and_inventory() (
    local status=0 inventory id
    setup ipv6
    seed ipv6 input allow tcp 443 2001:db8::1 ::/0 'IPv6 operator'
    desired node:v6 443 false ipv6 | jq '.[0].destination="2001:0db8:0:0::1"' >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_commit
    assert_json "$(vps_ufw_inventory)" 'length==1 and .[0].comment=="IPv6 operator" and .[0].owners==["node:v6"]' 'IPv6 compressed and expanded forms adopt same endpoint'
    apply proxy-forwards "$(desired forward:a 900:1000 false ipv6 route)"
    assert_json "$(vps_ufw_inventory)" 'any(.[];.family=="ipv6" and .kind=="route" and .port=="900:1000" and .simple)' 'IPv6 route range is parsed and owned'
    printf 'IPV6=no\n' >"$VPSCTL_SYSTEM_ROOT/etc/default/ufw"
    desired node:new 444 false ipv6 >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json" || status=$?
    assert_equal 3 "$status" 'active IPv6-disabled requirements fail explicitly'
    assert_json "$(vps_ufw_scope_desired proxy-nodes)" 'length==1 and .[0].port=="443"' 'unsupported IPv6 keeps old requirements'
    # Native UFW assigns one display number to both protocol expansions of an app.
    cat >>"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules" <<'EOF'
### tuple ### allow tcp 53 0.0.0.0/0 any 0.0.0.0/0 DNS - in
-A ufw-user-input -p tcp --dport 53 -j ACCEPT -m comment --comment 'dapp_DNS'

### tuple ### allow udp 53 0.0.0.0/0 any 0.0.0.0/0 DNS - in
-A ufw-user-input -p udp --dport 53 -j ACCEPT -m comment --comment 'dapp_DNS'

EOF
    seed ipv4 input allow tcp 22 0.0.0.0/0 0.0.0.0/0 'after grouped app'
    inventory="$(vps_ufw_inventory)"
    assert_json "$inventory" '[.[]|select(.app=="DNS")|.number]==[1,1] and any(.[];.port=="22" and .number==2) and
      any(.[];.family=="ipv6" and .port=="443" and .number==3)' 'app groups preserve native display numbers across families'
    id="$(jq -r '.[]|select(.port=="22")|.id' <<<"$inventory")"
    seed ipv4 output allow udp 9999 0.0.0.0/0 0.0.0.0/0 'later rule'
    assert_equal "$id" "$(vps_ufw_inventory | jq -r '.[]|select(.port=="22")|.id')" 'durable ID does not depend on other rule numbers'
)

test_interruption_and_dead_lease() (
    local status=0
    setup interruption
    desired node:aborted 8080 >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    (vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json")
    [[ -f "$VPS_UFW_JOURNAL" ]] || fail 'interrupted prepare did not leave recovery journal'
    apply ssh "$(desired ssh 22)"
    assert_json "$(vps_ufw_inventory)" 'length==1 and .[0].port=="22"' 'next process recovers abandoned prepare'
    (apply tls-dead "$(desired tls:dead 80 true)")
    assert_json "$(vps_ufw_inventory)" 'any(.[];.port=="80")' 'dead-process fixture has a temporary allow'
    apply ssh "$(desired ssh 22)"
    assert_json "$(vps_ufw_inventory)" 'all(.[];.port!="80")' 'new transaction retires dead temporary lease'
    apply proxy-nodes "$(desired node:a 8000)"
    desired node:a 8001 >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json"
    # Called indirectly by the public commit function to inject a durable-write failure.
    # shellcheck disable=SC2317
    _vps_ufw_journal_write() { return 20; }
    vps_ufw_commit || status=$?
    assert_equal 30 "$status" 'metadata failure reports partial commit'
    # Reload definitions without touching transaction globals or the UFW files.
    source "$TEST_ROOT/lib/ufw.sh"
    apply ssh "$(desired ssh 22)"
    assert_json "$(vps_ufw_scope_desired proxy-nodes)" 'length==1 and .[0].port=="8001"' 'decision marker preserves committed service after metadata failure'
    assert_json "$(vps_ufw_inventory)" 'any(.[];.port=="8001") and all(.[];.port!="8000")' 'metadata recovery only cleans obsolete rule'
)

test_scoped_history_isolation() (
    local snapshot
    setup scope-history
    snapshot="$VPSCTL_SYSTEM_ROOT/run/ssh-snapshot.json"
    apply ssh "$(desired ssh 443)"
    apply proxy-nodes "$(desired node:a 443)"
    apply ssh "$(desired ssh 22)"
    vps_ufw_scope_snapshot ssh "$snapshot"
    apply ssh "$(jq -s add <(desired ssh 22) <(desired ssh 2222))"
    apply proxy-nodes '[]'
    apply ssh "$(desired ssh 2222)"
    vps_ufw_scope_restore ssh "$snapshot"
    assert_json "$(vps_ufw_inventory)" 'length==1 and .[0].port=="22"' 'old historical SSH use cannot revive a different service removed since snapshot'
    vps_ufw_scope_snapshot ssh "$snapshot"
    apply ssh "$(desired ssh 2222)"
    vps_ufw_link_set ssh detached
    vps_ufw_scope_restore ssh "$snapshot"
    assert_json "$(vps_ufw_inventory)" 'all(.[];.port!="22")' 'scope restore honors detached SSH after its old rule was removed'
)

# setup initializes the public globals afresh inside this isolated test subshell.
# shellcheck disable=SC2031
test_tampered_rule_and_paths() (
    local status=0 before
    setup tampered
    seed ipv4 input allow tcp 8080 0.0.0.0/0 0.0.0.0/0 'tuple says unrestricted'
    sed 's/ -j ACCEPT/ -s 192.0.2.50 -j ACCEPT/' "$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules" >"$VPSCTL_SYSTEM_ROOT/run/modified"
    cp "$VPSCTL_SYSTEM_ROOT/run/modified" "$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules"
    before="$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")"
    desired node:a 8080 >"$VPSCTL_SYSTEM_ROOT/run/desired.json"
    vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json" || status=$?
    assert_equal 3 "$status" 'tuple/raw disagreement cannot be adopted or broadened'
    assert_equal "$before" "$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")" 'tampered restriction is unchanged'
    status=0
    mkdir -p "$VPS_UFW_STATE_DIR"
    printf '{"version":999}\n' >"$VPS_UFW_STATE_FILE"
    vps_ufw_begin proxy-nodes "$VPSCTL_SYSTEM_ROOT/run/desired.json" || status=$?
    assert_equal 3 "$status" 'unknown state version rejects mutation'
    assert_json "$(cat "$VPS_UFW_STATE_FILE")" '.version==999' 'unsupported state is preserved'
)

for test in test_disabled test_shared_references test_adoption_and_leases test_rollback_and_nesting \
    test_commit_cleanup_failure test_conflicts_and_detach test_scoped_ssh_restore test_ipv6_and_inventory \
    test_interruption_and_dead_lease test_scoped_history_isolation test_tampered_rule_and_paths; do
    "$test"
    printf 'PASS: %s\n' "$test"
done
