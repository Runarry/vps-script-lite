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

# The counter lives in a file because jq also runs in command/process substitutions.
track_jq() {
    printf '0\n' >"$VPSCTL_SYSTEM_ROOT/run/jq-count"
    # shellcheck disable=SC2317
    jq() {
        local count
        count="$(<"$VPSCTL_SYSTEM_ROOT/run/jq-count")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$VPSCTL_SYSTEM_ROOT/run/jq-count"
        if [[ "$count" == "${jq_fail_at:-0}" && "${jq_fail_mode:-before}" == before ]]; then return 5; fi
        command jq "$@" || return $?
        [[ "$count" != "${jq_fail_at:-0}" ]] || return 5
    }
}

assert_command() {
    local index
    local -a actual=() expected=("$@")
    mapfile -d '' -t actual <"$VPSCTL_SYSTEM_ROOT/run/command-args"
    assert_equal "${#expected[@]}" "${#actual[@]}" 'command argument count'
    for ((index = 0; index < ${#expected[@]}; index++)); do
        assert_equal "${expected[index]}" "${actual[index]}" "command argument $index"
    done
}

test_normalize_batches() (
    local file result filter status
    setup normalize-batches
    file="$VPSCTL_SYSTEM_ROOT/run/desired.json"
    cat >"$file" <<'EOF'
[
  {"owner":"node:a","kind":"input","family":"ipv4","proto":"tcp","port":"00080:00080","destination":null,"temporary":null,"preserve_existing":false},
  {"owner":"node:a","kind":"input","family":"ipv4","proto":"tcp","port":"80","source":"any","destination":"any"},
  {"owner":"forward:a","kind":"route","family":"ipv6","proto":"udp","port":"00900:01000","source":"2001:DB8::/64","destination":"::ffff:192.0.2.1","temporary":true},
  {"owner":"tcping","kind":"input","family":"ipv4","proto":"tcp","port":"65535","source":"192.000.002.010/32\u0000\n\n","destination":"0.0.0.0/0","preserve_existing":true,"ignored":"extra"}
]
EOF
    result="$(_vps_ufw_normalize_desired "$file" fixture)"
    assert_json "$result" '. == ([
      {scope:"fixture",owner:"node:a",kind:"input",family:"ipv4",proto:"tcp",port:"80",source:"any",destination:"any",source_port:"any",interfaces:{in:"",out:""},temporary:false},
      {scope:"fixture",owner:"forward:a",kind:"route",family:"ipv6",proto:"udp",port:"900:1000",source:"2001:0db8:0000:0000:0000:0000:0000:0000/64",destination:"0000:0000:0000:0000:0000:ffff:c000:0201",source_port:"any",interfaces:{in:"",out:""},temporary:true},
      {scope:"fixture",owner:"tcping",kind:"input",family:"ipv4",proto:"tcp",port:"65535",source:"192.0.2.10",destination:"any",source_port:"any",interfaces:{in:"",out:""},temporary:false,preserve_existing:true}
    ] | sort)' 'normalization preserves defaults, IPv6, ranges, deduplication and preserve_existing'
    printf '[]\n' >"$file"
    assert_equal '[]' "$(_vps_ufw_normalize_desired "$file" fixture)" 'empty desired remains an empty array'
    for filter in '.[0].source=""' '.[0].destination=""' '.[0].source="::1"' \
        '.[0].family="ipv6" | .[0].destination="192.0.2.1"' '.[0].port="900:80"' '.[0].port="65536"'; do
        desired node:a 80 | jq "$filter" >"$file"
        status=0
        _vps_ufw_normalize_desired "$file" fixture >/dev/null 2>&1 || status=$?
        assert_equal 2 "$status" "invalid requirement: $filter"
    done
    jq -n '[range(20) | {owner:("node:"+tostring),kind:"input",family:"ipv4",proto:"tcp",port:"80"}]' >"$file"
    track_jq
    result="$(_vps_ufw_normalize_desired "$file" fixture)"
    assert_equal 23 "$(<"$VPSCTL_SYSTEM_ROOT/run/jq-count")" '20 requirements use 23 jq calls'
    unset -f jq
    assert_json "$result" 'length==20' 'batch includes every requirement'
)

test_normalize_read_failures() (
    local file jq_fail_at jq_fail_mode status result expected
    setup normalize-failures
    file="$VPSCTL_SYSTEM_ROOT/run/desired.json"
    desired node:a 80 >"$file"
    for jq_fail_at in 1 2 3 4; do
        for jq_fail_mode in before after; do
            track_jq
            status=0
            result="$(_vps_ufw_normalize_desired "$file" fixture 2>/dev/null)" || status=$?
            expected=20
            [[ "$jq_fail_at" != 1 ]] || expected=2
            assert_equal "$expected" "$status" "normalize jq $jq_fail_at $jq_fail_mode failure"
            if [[ "$jq_fail_at" == 2 ]]; then assert_equal '' "$result" 'failed producer cannot emit normalized requirements'; fi
            unset -f jq
        done
    done
)

test_prune_batches() (
    local state result mode
    setup prune-batches
    vps_ufw_lease_metadata
    state="$(jq --argjson live "$VPS_UFW_LEASE_JSON" '
      .leases={"tls:live":$live,"tls:trimmed":($live | map_values(tostring+"\u0000\n\n")),
        "tls:dead":($live+{pid:2147483647}),"tls:boot":($live+{boot_id:"wrong"}),
        "tls:start":($live+{start_time:"wrong"}),"tls:missing":{},"tls:empty":{pid:"",boot_id:"",start_time:""}} |
      .requirements=[
        {owner:"tls:live",temporary:true,tag:"live"},{owner:"tls:trimmed",temporary:true,tag:"trimmed"},
        {owner:"tls:dead",temporary:true,tag:"dead"},{owner:"tls:boot",temporary:true,tag:"boot"},
        {owner:"tls:start",temporary:true,tag:"start"},{owner:"tls:missing",temporary:true,tag:"missing"},
        {owner:"tls:empty",temporary:true,tag:"empty"},{owner:"tls:dead",temporary:false,tag:"permanent"},
        {owner:"tls:dead",tag:"default"},{owner:"tls:dead",temporary:"true",tag:"nonboolean"},
        {owner:"node:other",temporary:true,tag:"other"},{temporary:true,tag:"ownerless"},
        {owner:7,temporary:true,tag:"numeric"},{owner:["tls:dead"],temporary:true,tag:"array"}] |
      .marker={keep:[1,2]}' <<<"$(_vps_ufw_state)")"
    track_jq
    result="$(_vps_ufw_prune_leases "$state")"
    assert_equal 2 "$(<"$VPSCTL_SYSTEM_ROOT/run/jq-count")" 'mixed leases use two jq calls'
    unset -f jq
    assert_json "$result" '(.leases|keys)==["tls:live","tls:trimmed"] and
      [.requirements[].tag]==["live","trimmed","permanent","default","nonboolean","other","ownerless","numeric","array"] and
      .marker=={keep:[1,2]} and .version==1 and .revision==0' 'expired owners lose only their temporary requirements'
    state="$result"
    track_jq
    result="$(_vps_ufw_prune_leases "$state")"
    assert_equal 1 "$(<"$VPSCTL_SYSTEM_ROOT/run/jq-count")" 'live leases use one jq call'
    unset -f jq
    assert_equal "$state" "$result" 'no expired leases return the original state bytes'
    for mode in live dead; do
        state="$(jq --arg mode "$mode" --argjson live "$VPS_UFW_LEASE_JSON" '
          .leases=(reduce range(20) as $i ({}; .["tls:"+($i|tostring)]=
            (if $mode=="live" then $live else $live+{pid:2147483647} end)))' <<<"$(_vps_ufw_state)")"
        track_jq
        result="$(_vps_ufw_prune_leases "$state")"
        if [[ "$mode" == live ]]; then
            assert_equal 1 "$(<"$VPSCTL_SYSTEM_ROOT/run/jq-count")" '20 live leases use one jq call'
            assert_equal "$state" "$result" '20 live leases are unchanged'
        else
            assert_equal 2 "$(<"$VPSCTL_SYSTEM_ROOT/run/jq-count")" '20 expired leases use two jq calls'
        fi
        unset -f jq
        if [[ "$mode" == dead ]]; then assert_json "$result" '.leases=={}' 'all expired leases removed together'; fi
    done
)

test_prune_read_failures() (
    local state result status jq_fail_at jq_fail_mode
    setup prune-failures
    state='{"leases":{"tls:dead":{}},"requirements":[{"owner":"tls:dead","temporary":true}]}'
    for jq_fail_at in 1 2; do
        for jq_fail_mode in before after; do
            track_jq
            status=0
            result="$(_vps_ufw_prune_leases "$state" 2>/dev/null)" || status=$?
            assert_equal 20 "$status" "prune jq $jq_fail_at $jq_fail_mode failure"
            if [[ "$jq_fail_at" == 1 ]]; then assert_equal '' "$result" 'failed producer cannot emit a pruned state'; fi
            unset -f jq
        done
    done
    for state in '' '{' '{"leases":{"tls:dead":{},"tls:invalid":[]},"requirements":[]}'; do
        status=0
        result="$(_vps_ufw_prune_leases "$state" 2>/dev/null)" || status=$?
        assert_equal 20 "$status" 'empty or malformed lease input fails'
        assert_equal '' "$result" 'invalid lease input cannot emit a successful state'
    done
)

test_add_rule_batches() (
    local rule status jq_fail_at=0 jq_fail_mode
    setup add-batches
    # shellcheck disable=SC2317
    vps_cmd_run() { printf '%s\0' "$@" >"$VPSCTL_SYSTEM_ROOT/run/command-args"; }
    rule='{"kind":"input","family":"ipv4","source":"any","destination":"any","proto":"tcp","port":"443"}'
    track_jq
    _vps_ufw_add_rule "$rule" ''
    assert_equal 1 "$(<"$VPSCTL_SYSTEM_ROOT/run/jq-count")" 'add rule reads all six fields with one jq'
    unset -f jq
    assert_command ufw allow proto tcp from 0.0.0.0/0 to 0.0.0.0/0 port 443
    _vps_ufw_add_rule '{"kind":"route","family":"ipv6","source":"any","destination":"any","proto":"udp","port":"900:1000"}' $'operator \tcomment\n' 2
    assert_command ufw route insert 2 allow proto udp from ::/0 to ::/0 port 900:1000 comment $'operator \tcomment\n'
    _vps_ufw_add_rule '{"kind":"output","family":"ipv4","source":"192.0.2.1","destination":"any","proto":"tcp","port":"22"}' '' 3
    assert_command ufw insert 3 allow out proto tcp from 192.0.2.1 to 0.0.0.0/0 port 22
    _vps_ufw_add_rule '{"kind":"","family":"","source":"","destination":"","proto":"","port":""}' ''
    assert_command ufw allow proto '' from '' to '' port ''
    _vps_ufw_add_rule '{"kind":"input\u0000\n","family":"ipv6\n\n","source":"any\u0000\n","destination":"2001:db8::1\n","proto":"t\u0000cp\n","port":"443\n"}' 'comment with spaces'
    assert_command ufw allow proto tcp from ::/0 to 2001:db8::1 port 443 comment 'comment with spaces'
    for jq_fail_mode in before after; do
        jq_fail_at=1
        track_jq
        rm -f "$VPSCTL_SYSTEM_ROOT/run/command-args"
        status=0
        _vps_ufw_add_rule "$rule" '' 2>/dev/null || status=$?
        assert_equal 20 "$status" "add producer $jq_fail_mode failure"
        [[ ! -e "$VPSCTL_SYSTEM_ROOT/run/command-args" ]] || fail 'failed producer ran ufw'
        unset -f jq
    done
    for rule in '' '{'; do
        status=0
        _vps_ufw_add_rule "$rule" '' 2>/dev/null || status=$?
        assert_equal 20 "$status" 'invalid rule JSON fails before ufw'
        [[ ! -e "$VPSCTL_SYSTEM_ROOT/run/command-args" ]] || fail 'invalid rule ran ufw'
    done
)

test_sweep_delete_safety() (
    local scenario status before expected_status expected_reads expected_command inventory_failure=0
    # shellcheck disable=SC2317
    _vps_ufw_inventory_raw() {
        local count
        count="$(<"$VPSCTL_SYSTEM_ROOT/run/inventory-count")"
        count=$((count + 1))
        printf '%s\n' "$count" >"$VPSCTL_SYSTEM_ROOT/run/inventory-count"
        [[ "$count" != "$inventory_failure" ]] || return 20
        cat "$VPSCTL_SYSTEM_ROOT/run/inventory-$count"
    }
    # shellcheck disable=SC2317
    vps_cmd_run() {
        printf '%s\0' "$@" >"$VPSCTL_SYSTEM_ROOT/run/command-args"
        [[ "$scenario" != command-failure ]]
    }
    for scenario in present absent preserve duplicate drift command-failure false-success \
        initial-failure fresh-failure post-failure initial-json fresh-json post-json; do
        setup "delete-$scenario"
        mkdir -p "$VPS_UFW_STATE_DIR"
        printf '%s\n' '{"version":1,"revision":0,"requirements":[],"links":{},"leases":{},"history":[],"managed":{"key":{"rule":{"id":"target"},"preserve":false}}}' >"$VPS_UFW_STATE_FILE"
        printf '0\n' >"$VPSCTL_SYSTEM_ROOT/run/inventory-count"
        printf '%s\n' '[{"id":"target","number":2}]' >"$VPSCTL_SYSTEM_ROOT/run/inventory-1"
        cp "$VPSCTL_SYSTEM_ROOT/run/inventory-1" "$VPSCTL_SYSTEM_ROOT/run/inventory-2"
        printf '[]\n' >"$VPSCTL_SYSTEM_ROOT/run/inventory-3"
        expected_status=0
        expected_reads=3
        expected_command=1
        inventory_failure=0
        case "$scenario" in
            absent)
                printf '[]\n' >"$VPSCTL_SYSTEM_ROOT/run/inventory-1"
                expected_reads=1
                expected_command=0
                ;;
            preserve)
                jq '.managed.key.preserve=true' "$VPS_UFW_STATE_FILE" >"$VPS_UFW_STATE_FILE.next"
                mv "$VPS_UFW_STATE_FILE.next" "$VPS_UFW_STATE_FILE"
                expected_reads=0
                expected_command=0
                ;;
            duplicate)
                printf '%s\n' '[{"id":"target","number":2},{"id":"target","number":3}]' >"$VPSCTL_SYSTEM_ROOT/run/inventory-1"
                expected_status=3
                expected_reads=1
                expected_command=0
                ;;
            drift)
                printf '%s\n' '[{"id":"target","number":1},{"id":"other","number":2}]' >"$VPSCTL_SYSTEM_ROOT/run/inventory-2"
                expected_status=3
                expected_reads=2
                expected_command=0
                ;;
            command-failure)
                expected_status=20
                expected_reads=2
                ;;
            false-success)
                cp "$VPSCTL_SYSTEM_ROOT/run/inventory-1" "$VPSCTL_SYSTEM_ROOT/run/inventory-3"
                expected_status=20
                ;;
            initial-failure | initial-json)
                expected_status=20
                expected_reads=1
                expected_command=0
                ;;
            fresh-failure | fresh-json)
                expected_status=20
                [[ "$scenario" != fresh-json ]] || expected_status=3
                expected_reads=2
                expected_command=0
                ;;
            post-failure | post-json) expected_status=20 ;;
        esac
        case "$scenario" in
            *-failure) [[ "$scenario" == command-failure ]] || inventory_failure="$expected_reads" ;;
            *-json) printf '{\n' >"$VPSCTL_SYSTEM_ROOT/run/inventory-$expected_reads" ;;
        esac
        before="$(<"$VPS_UFW_STATE_FILE")"
        status=0
        _vps_ufw_sweep 2>/dev/null || status=$?
        assert_equal "$expected_status" "$status" "$scenario deletion status"
        assert_equal "$expected_reads" "$(<"$VPSCTL_SYSTEM_ROOT/run/inventory-count")" "$scenario inventory reads"
        if [[ "$expected_command" == 1 ]]; then
            assert_command ufw --force delete 2
        else
            [[ ! -e "$VPSCTL_SYSTEM_ROOT/run/command-args" ]] || fail "$scenario executed an unsafe deletion"
        fi
        if [[ "$expected_status" == 0 ]]; then
            assert_json "$(<"$VPS_UFW_STATE_FILE")" '.managed=={}' "$scenario releases the managed record"
        else
            assert_equal "$before" "$(<"$VPS_UFW_STATE_FILE")" "$scenario retains the managed record for retry"
        fi
    done
)

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

test_preserve_existing() (
    local original
    setup preserve-existing
    seed ipv4 input allow tcp 8443 0.0.0.0/0 0.0.0.0/0 'operator TCP test'
    original="$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")"
    apply tcping "$(desired tcping 8443 | jq 'map(. + {preserve_existing:true})')"
    assert_json "$(cat "$VPS_UFW_STATE_FILE")" '(.managed|length)==0 and (.leases|length)==0 and
        any(.requirements[]; .owner=="tcping" and .preserve_existing==true and .temporary==false)' 'permanent demand borrows manual rule without a lease'
    apply tcping "$(desired tcping 9443 | jq 'map(. + {preserve_existing:true})')"
    assert_json "$(vps_ufw_inventory)" 'length==2 and any(.[];.port=="8443" and .comment=="operator TCP test")' 'port change preserves manual rule'
    apply proxy-nodes "$(desired node:shared 9443)"
    apply tcping '[]'
    assert_json "$(vps_ufw_inventory)" 'any(.[];.port=="9443" and .owners==["node:shared"])' 'other owner preserves the created shared rule'
    apply proxy-nodes '[]'
    assert_equal "$original" "$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")" 'last release removes only the created rule and preserves original bytes'
)

test_iperf3_lifecycle() (
    local original4 original6 requirements
    setup iperf3-lifecycle
    seed ipv4 input allow tcp 5201 0.0.0.0/0 0.0.0.0/0 'operator iperf3 TCP'
    seed ipv6 input allow udp 5201 ::/0 ::/0 'operator iperf3 UDP'
    original4="$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")"
    original6="$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user6.rules")"
    requirements="$(jq -s 'add | [.[] | . as $request | ("tcp","udp") as $proto |
        $request + {proto:$proto,preserve_existing:true}]' <(desired iperf3 5201) <(desired iperf3 5201 false ipv6))"
    apply iperf3 "$requirements"
    assert_json "$(vps_ufw_inventory)" 'length==4 and all(.[]; .port=="5201" and .owners==["iperf3"])' 'iperf3 owns TCP and UDP in both families'
    assert_json "$(<"$VPS_UFW_STATE_FILE")" '(.managed|length)==2 and (.leases|length)==0' 'iperf3 borrows both manual rules and manages only new endpoints'
    vps_ufw_link_set iperf3 detached
    assert_json "$(vps_ufw_inventory)" 'length==4 and all(.[]; .owners==[])' 'iperf3 detach releases ownership without deleting rules'
    vps_ufw_link_set iperf3 attached
    apply iperf3 "$requirements"
    assert_json "$(vps_ufw_inventory)" 'length==4 and all(.[]; .owners==["iperf3"])' 'iperf3 attach restores ownership'
    apply iperf3 "$(jq 'map(.port="5301")' <<<"$requirements")"
    assert_json "$(vps_ufw_inventory)" 'length==6 and ([.[]|select(.port=="5201")]|length)==2 and
        all(.[]|select(.port=="5201"); .comment|startswith("operator iperf3"))' 'iperf3 port change preserves manual old endpoints'
    apply proxy-nodes "$(desired node:shared 5301)"
    apply iperf3 '[]'
    assert_json "$(vps_ufw_inventory)" 'length==3 and any(.[]; .port=="5301" and .owners==["node:shared"])' 'iperf3 removal preserves another owner'
    apply proxy-nodes '[]'
    assert_equal "$original4" "$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")" 'iperf3 release preserves original IPv4 bytes'
    assert_equal "$original6" "$(<"$VPSCTL_SYSTEM_ROOT/etc/ufw/user6.rules")" 'iperf3 release preserves original IPv6 bytes'
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

for test in test_normalize_batches test_normalize_read_failures test_prune_batches test_prune_read_failures \
    test_add_rule_batches test_sweep_delete_safety test_disabled test_shared_references test_adoption_and_leases test_preserve_existing test_iperf3_lifecycle test_rollback_and_nesting \
    test_commit_cleanup_failure test_conflicts_and_detach test_scoped_ssh_restore test_ipv6_and_inventory \
    test_interruption_and_dead_lease test_scoped_history_isolation test_tampered_rule_and_paths; do
    "$test"
    printf 'PASS: %s\n' "$test"
done
