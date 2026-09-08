#!/usr/bin/env bash
# These tests exercise command transactions and business-state collection with
# a fixture UFW backend. Run only on ssh host-vps-scripts, never on the editor.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TMP="$(mktemp -d /tmp/vpsctl-ufw-cli-test.XXXXXX)"
readonly TEST_ROOT TEST_TMP
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$TEST_TMP/system" VPSCTL_NON_INTERACTIVE=1
export VPSCTL_ASSUME_YES=1 VPSCTL_DRY_RUN=0 VPSCTL_NO_COLOR=1 VPSCTL_ENV_INIT=systemd
export VPSCTL_ENV_PACKAGE_MANAGER=apt-get
trap 'rm -rf -- "$TEST_TMP"' EXIT
# shellcheck source=../../commands/network/ufw.sh
source "$TEST_ROOT/commands/network/ufw.sh"
mkdir -p -- "$VPSCTL_SYSTEM_ROOT"
vps_cmd_init network-ufw "$TEST_ROOT"
vps_ufw_init
UFW_CLI_INTERACTIVE=0
RUN_STATUS=0
RUN_OUTPUT=''

fail() {
    printf 'FAIL: %s\n%s\n' "$1" "$RUN_OUTPUT" >&2
    exit 1
}
assert_status() { [[ "$RUN_STATUS" == "$1" ]] || fail "$2: expected $1, got $RUN_STATUS"; }
run_cli() {
    if RUN_OUTPUT="$(ufw_cli_dispatch "$@" 2>&1)"; then RUN_STATUS=0; else RUN_STATUS=$?; fi
}

reset_fixture() {
    rm -rf -- "$VPSCTL_SYSTEM_ROOT"
    mkdir -p -- "$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d" "$VPSCTL_SYSTEM_ROOT/etc/default" \
        "$VPSCTL_SYSTEM_ROOT/etc/ssh" "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/service/proxy"
    printf 'IPV6=yes\nDEFAULT_INPUT_POLICY="DROP"\nDEFAULT_OUTPUT_POLICY="ACCEPT"\nDEFAULT_FORWARD_POLICY="DROP"\n' >"$VPSCTL_SYSTEM_ROOT/etc/default/ufw"
    printf 'ENABLED=no\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf"
    printf 'Port 22\n' >"$VPSCTL_SYSTEM_ROOT/etc/ssh/sshd_config"
    printf 'port 22\naddressfamily any\n' >"$VPSCTL_SYSTEM_ROOT/sshd-effective"
    printf 'owned-by-openssh\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d/openssh-server"
    : >"$VPSCTL_SYSTEM_ROOT/calls"
    SSH_CONNECTION=''
    export SSH_CONNECTION
}

# Only this shell function and the vps_cmd_run adapter implement mutations.
# They cannot invoke the host's actual ufw, init or package manager binaries.
_mock_render() {
    local rules="$1" family path row
    for family in ipv4 ipv6; do
        path="$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules"
        [[ "$family" != ipv6 ]] || path="$VPSCTL_SYSTEM_ROOT/etc/ufw/user6.rules"
        : >"$path"
        while IFS= read -r row; do
            jq -r '.tuple,.raw,""' <<<"$row" >>"$path"
        done < <(jq -c --arg family "$family" '.[] | select(.family == $family)' <<<"$rules")
    done
}

ufw() {
    {
        printf 'ufw'
        printf ' <%s>' "$@"
        printf '\n'
    } >>"$VPSCTL_SYSTEM_ROOT/calls"
    [[ "${1:-}" != --dry-run ]] || return 0
    [[ "${1:-}" != --force ]] || shift
    local rules family=ipv4 action='' kind=input direction=in proto=any port=any sport=any
    local source=0.0.0.0/0 destination=0.0.0.0/0 dapp=- sapp=- comment='' hex='' log='' iface='' in_if='' out_if='' position='' tuple row num4 num6 raw chain new_rows
    case "${1:-}" in
        status)
            if [[ "$(awk -F= '$1 == "ENABLED" {print $2}' "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf")" == yes ]]; then
                printf 'Status: active\n'
            else printf 'Status: inactive\n'; fi
            return 0
            ;;
        enable)
            printf 'ENABLED=yes\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf"
            return 0
            ;;
        disable)
            printf 'ENABLED=no\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf"
            return 0
            ;;
        reset)
            _mock_render '[]'
            printf 'ENABLED=no\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf"
            return 0
            ;;
        reload | default | logging | app) return 0 ;;
        delete)
            [[ ! -e "$VPSCTL_SYSTEM_ROOT/ignore-delete" ]] || return 0
            rules="$(_vps_ufw_inventory_raw)" || return $?
            _mock_render "$(jq -c --argjson number "$2" 'map(select(.number != $number))' <<<"$rules")"
            return 0
            ;;
    esac
    if [[ -e "$VPSCTL_SYSTEM_ROOT/fail-insert" ]]; then
        rm -f -- "$VPSCTL_SYSTEM_ROOT/fail-insert"
        return 1
    fi
    [[ "${1:-}" != route ]] || {
        kind=route
        shift
    }
    [[ "${1:-}" != insert ]] || {
        position="$2"
        shift 2
    }
    action="$1"
    shift
    while (($#)); do
        case "$1" in
            in | out)
                direction="$1"
                shift
                if [[ "${1:-}" == on ]]; then
                    if [[ "$direction" == in ]]; then in_if="$2"; else out_if="$2"; fi
                    shift 2
                fi
                ;;
            log | log-all)
                log="$1"
                shift
                ;;
            proto)
                proto="$2"
                shift 2
                ;;
            from)
                source="$2"
                shift 2
                if [[ "${1:-}" == port ]]; then
                    sport="$2"
                    shift 2
                elif [[ "${1:-}" == app ]]; then
                    sapp="$2"
                    sport=22
                    proto=tcp
                    shift 2
                fi
                ;;
            to)
                destination="$2"
                shift 2
                if [[ "${1:-}" == port ]]; then
                    port="$2"
                    shift 2
                elif [[ "${1:-}" == app ]]; then
                    dapp="$2"
                    port=22
                    proto=tcp
                    shift 2
                fi
                ;;
            comment)
                comment="$2"
                shift 2
                ;;
            *) return 2 ;;
        esac
    done
    if [[ "$source" == *:* || "$destination" == *:* ]]; then family=ipv6; fi
    [[ "$source" != any ]] || source=0.0.0.0/0
    [[ "$destination" != any ]] || destination=0.0.0.0/0
    if [[ "$family" == ipv6 ]]; then
        [[ "$source" != 0.0.0.0/0 ]] || source=::/0
        [[ "$destination" != 0.0.0.0/0 ]] || destination=::/0
    fi
    [[ "$kind" != route ]] || action="route:$action"
    [[ -z "$log" ]] || action+="_$log"
    iface="$direction"
    [[ -z "$in_if" ]] || iface="in_$in_if"
    [[ -z "$out_if" ]] || iface="${in_if:+${iface}!}out_$out_if"
    tuple="### tuple ### $action $proto $port $destination $sport $source ${dapp// /%20} ${sapp// /%20} $iface"
    if [[ -n "$comment" ]]; then
        hex="$(printf '%s' "$comment" | od -An -tx1 | tr -d ' \n')"
        tuple+=" comment=$hex"
    fi
    chain=ufw-user-input
    [[ "$family" != ipv6 ]] || chain=ufw6-user-input
    [[ "$kind" != route ]] || chain="${chain%input}forward"
    [[ "$direction" != out || "$kind" == route ]] || chain="${chain%input}output"
    raw="-A $chain -p $proto"
    [[ "$port" == any ]] || raw+=" --dport $port"
    [[ "$source" == 0.0.0.0/0 || "$source" == ::/0 ]] || raw+=" -s $source"
    [[ "$destination" == 0.0.0.0/0 || "$destination" == ::/0 ]] || raw+=" -d $destination"
    raw+=' -j ACCEPT'
    row="$(_vps_ufw_rule_json "$tuple" "$raw" "$family" 1)" || return $?
    new_rows="$(jq -cn --argjson row "$row" '[$row]')"
    if [[ "$dapp" == 'Dual Service' ]]; then
        row="$(_vps_ufw_rule_json "${tuple/ tcp / udp }" "${raw/ -p tcp / -p udp }" "$family" 1)" || return $?
        new_rows="$(jq -c --argjson row "$row" '.+[$row]' <<<"$new_rows")"
    fi
    rules="$(_vps_ufw_inventory_raw)" || return $?
    if [[ -n "$position" ]]; then
        num4="$(jq '[.[] | select(.family == "ipv4") | .number] | unique | length' <<<"$rules")"
        num6="$(jq '[.[] | select(.family == "ipv6") | .number] | unique | length' <<<"$rules")"
        if [[ "$family" == ipv4 ]]; then
            ((position <= num4)) || return 1
        else ((position > num4 && position <= num4 + num6)) || return 1; fi
        rules="$(jq -c --argjson rows "$new_rows" --argjson position "$position" '[.[]|select(.number<$position)]+$rows+[.[]|select(.number>=$position)]' <<<"$rules")"
    else rules="$(jq -c --argjson rows "$new_rows" '.+$rows' <<<"$rules")"; fi
    _mock_render "$rules"
}

systemctl() {
    printf 'systemctl <%s>\n' "$*" >>"$VPSCTL_SYSTEM_ROOT/calls"
    case "${1:-}" in
        is-enabled)
            if [[ -e "$VPSCTL_SYSTEM_ROOT/boot-enabled" ]]; then
                printf 'enabled\n'
            else
                printf 'disabled\n'
                return 1
            fi
            ;;
        enable)
            [[ ! -e "$VPSCTL_SYSTEM_ROOT/fail-persist" ]] || return 1
            touch "$VPSCTL_SYSTEM_ROOT/boot-enabled"
            ;;
        disable) rm -f -- "$VPSCTL_SYSTEM_ROOT/boot-enabled" ;;
        *) return 0 ;;
    esac
}
sshd() { cat -- "$VPSCTL_SYSTEM_ROOT/sshd-effective"; }
apt-get() { printf 'apt-get <%s>\n' "$*" >>"$VPSCTL_SYSTEM_ROOT/calls"; }
vps_cmd_run() {
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || {
        printf 'dry-run <%s>\n' "$*"
        return 0
    }
    if [[ "${1:-}" == env && "${2:-}" == LC_ALL=C ]]; then shift 2; fi
    "$@"
}

test_validation() {
    reset_fixture
    run_cli rule add
    assert_status 2 'empty rule rejected'
    run_cli rule add --port 70000
    assert_status 2 'out-of-range port rejected'
    run_cli rule add --port 4000:3000
    assert_status 2 'descending range rejected'
    run_cli rule add --port '80;touch /tmp/unwanted'
    assert_status 2 'shell text rejected'
    run_cli reset
    assert_status 3 '--yes cannot bypass reset confirmation'
    run_cli uninstall --purge
    assert_status 3 '--yes cannot bypass purge confirmation'
    run_cli app update all --add-new
    assert_status 2 'update all cannot add-new'
    [[ ! -s "$VPSCTL_SYSTEM_ROOT/calls" ]] || fail 'argument errors reached backend'
}

test_business_inventory() {
    local output nodes relay cache
    reset_fixture
    printf 'port 22\nport 2222\naddressfamily any\n' >"$VPSCTL_SYSTEM_ROOT/sshd-effective"
    SSH_CONNECTION='192.0.2.20 51000 192.0.2.10 2200'
    output="$(ufw_cli_ssh_desired)" || fail 'SSH inventory failed'
    jq -e 'length==6 and ([.[].port]|unique)==["22","2200","2222"] and all(.[]; .owner=="ssh")' <<<"$output" >/dev/null || fail 'effective/current SSH ports not preserved'
    nodes="$TEST_TMP/nodes.json"
    cat >"$nodes" <<'EOF'
{"schema_version":1,"nodes":[
 {"id":"reality","profile":"vless-reality","listen":"0.0.0.0","port":443,"tls":{"reality_guard":{"enabled":true,"listen_port":40000}}},
 {"id":"quic","profile":"hysteria2","listen":"::","port":8443},
 {"id":"ss","profile":"shadowsocks-2022","listen":"0.0.0.0","port":1443},
 {"id":"local","profile":"socks5","listen":"127.0.0.1","port":1080}]}
EOF
    output="$(ufw_cli_nodes_desired "$nodes")" || fail 'node inventory failed'
    jq -e 'length==5 and all(.[]; .port!="40000" and .port!="1080") and ([.[]|select(.owner=="node:ss")|.proto]|sort)==["tcp","udp"] and all(.[]|select(.owner=="node:quic"); .proto=="udp")' <<<"$output" >/dev/null || fail 'node protocol/loopback inventory incorrect'
    relay="$TEST_TMP/relay.json"
    cache="$TEST_TMP/cache.json"
    printf '%s\n' '{"schema_version":1,"exits":[{"id":"remote","endpoint":{"host":"relay.example","port":10443},"network_hint":"both"}],"forwards":[{"id":"fwd","exit_id":"remote","network":"auto","family":"ipv4","listen_port_start":4100,"listen_port_end":4110}]}' >"$relay"
    printf '%s\n' '{"schema_version":1,"exits":{"remote":{"host":"relay.example","ipv4":"198.51.100.8"}}}' >"$cache"
    output="$(ufw_cli_forwards_desired "$relay" "$cache")" || fail 'forward inventory failed'
    jq -e 'length==2 and all(.[]; .kind=="route" and .port=="10443" and .destination=="198.51.100.8" and .owner=="forward:fwd")' <<<"$output" >/dev/null || fail 'DNAT destination/port incorrect'
    printf '%s\n' '{"schema_version":1,"exits":{"remote":{"host":"old.example","ipv4":"198.51.100.8"}}}' >"$cache"
    if ufw_cli_forwards_desired "$relay" "$cache" >/dev/null 2>&1; then fail 'stale host cache accepted'; fi
}

test_rule_transactions() {
    local rules id original
    reset_fixture
    run_cli rule add --family ipv4 --port 80 --log log --comment before
    assert_status 0 'manual rule add'
    run_cli rule add --family ipv4 --port 81
    assert_status 0 'second rule add'
    id="$(vps_ufw_inventory | jq -r '.[]|select(.port=="80")|.id')"
    run_cli rule edit --id "$id" --comment after
    assert_status 0 'comment-only edit'
    rules="$(vps_ufw_inventory)"
    jq -e 'length==2 and .[0].port=="80" and .[0].comment=="after" and .[0].log=="log" and .[1].port=="81"' <<<"$rules" >/dev/null || fail 'edit lost order or logging'
    run_cli rule add --family ipv4 --app OpenSSH --log log-all
    assert_status 0 'application rule add'
    run_cli rule edit --number 3 --comment app-note
    assert_status 0 'application comment edit'
    vps_ufw_inventory | jq -e '.[2].app=="OpenSSH" and .[2].log=="log-all" and .[2].comment=="app-note"' >/dev/null || fail 'edit discarded app or log-all'
    original="$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")"
    touch "$VPSCTL_SYSTEM_ROOT/fail-insert"
    run_cli rule edit --number 1 --port 8080
    assert_status 20 'backend edit failure reported'
    [[ "$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")" == "$original" ]] || fail 'failed edit did not restore exact rules'
    touch "$VPSCTL_SYSTEM_ROOT/ignore-delete"
    run_cli rule delete --number 2
    assert_status 20 'false-success delete rejected'
    [[ "$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")" == "$original" ]] || fail 'failed delete changed original rules'
    rm -f -- "$VPSCTL_SYSTEM_ROOT/ignore-delete"
    run_cli rule delete --number 2
    assert_status 0 'verified delete'
}

test_sync_protection_and_lifecycle() {
    local requirements rules
    reset_fixture
    run_cli sync
    assert_status 0 'inactive sync'
    [[ "$(vps_ufw_inventory | jq length)" == 0 ]] || fail 'inactive sync added rules'
    vps_ufw_links | jq -e 'any(.[]; .owner=="ssh" and (.requirements|length)==2)' >/dev/null || fail 'inactive sync lost SSH requirements'
    run_cli rule add --family ipv4 --port 22
    assert_status 0 'existing SSH rule'
    run_cli rule delete --number 1
    assert_status 3 'attached service protects manual equivalent rule'
    run_cli link detach ssh
    assert_status 0 'detach service'
    run_cli rule edit --number 1 --port 2223
    assert_status 0 'detached rule can be edited'
    run_cli sync
    assert_status 0 'sync detached state'
    vps_ufw_links | jq -e 'any(.[]; .owner=="ssh" and .detached)' >/dev/null || fail 'sync reattached owner'
    run_cli link attach ssh
    assert_status 0 'reattach inactive service'
    requirements="$(vps_ufw_links)"
    run_cli enable
    assert_status 0 'enable stages attached business rules'
    vps_ufw_inventory | jq -e 'any(.[]; .port=="22" and .family=="ipv4") and any(.[]; .port=="22" and .family=="ipv6")' >/dev/null || fail 'enable missed SSH family'
    run_cli reset --confirm-reset
    assert_status 0 'confirmed reset'
    if vps_ufw_is_active; then fail 'reset reenabled UFW'; fi
    rules="$(vps_ufw_inventory)"
    [[ "$(jq length <<<"$rules")" == 0 ]] || fail 'reset added physical service rules'
    [[ "$(vps_ufw_links)" == "$requirements" ]] || fail 'reset lost attached requirements'
    mkdir -p -- "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/security/access"
    printf 'tx-pending\n' >"$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/security/access/active"
    run_cli enable
    assert_status 3 'pending SSH transaction blocks global enable'
    rm -f -- "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/security/access/active"
    run_cli uninstall --purge --confirm-purge
    assert_status 0 'purge'
    [[ "$(cat "$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d/openssh-server")" == owned-by-openssh ]] || fail 'purge removed foreign application profile'
    [[ ! -e "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/network/ufw/state.json" ]] || fail 'purge left active ownership state'
    find "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/backups/network/ufw" -name snapshot.json -print -quit | grep -q . || fail 'purge lost recovery backup'
}

test_dry_run_and_business_lock() {
    local before descriptor lock
    reset_fixture
    before="$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" "$VPSCTL_SYSTEM_ROOT/etc/default/ufw")"
    VPSCTL_DRY_RUN=1
    run_cli enable
    assert_status 0 'dry-run enable'
    VPSCTL_DRY_RUN=0
    [[ ! -e "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/network/ufw" && ! -e "$VPSCTL_SYSTEM_ROOT/run/vpsctl" ]] || fail 'dry-run created managed state or lock'
    [[ "$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" "$VPSCTL_SYSTEM_ROOT/etc/default/ufw")" == "$before" ]] || fail 'dry-run mutated config'
    mkdir -p -- "$VPSCTL_SYSTEM_ROOT/run/vpsctl"
    lock="$VPSCTL_SYSTEM_ROOT/run/vpsctl/proxy.lock"
    exec {descriptor}>"$lock"
    flock -n "$descriptor" || fail 'fixture lock'
    run_cli sync
    assert_status 3 'global sync refuses active proxy lock'
    exec {descriptor}>&-
    [[ ! -e "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/network/ufw" ]] || fail 'lock conflict mutated shared state'
    run_cli sync
    assert_status 0 'business descriptors released after conflict'
}

test_application_rule_group() {
    local rules id
    reset_fixture
    run_cli rule add --family ipv4 --app 'Dual Service' --comment original
    assert_status 0 'multi-protocol application add'
    run_cli rule add --family ipv4 --port 8081
    assert_status 0 'rule after application group'
    rules="$(vps_ufw_inventory)"
    jq -e 'length==3 and .[0].number==1 and .[1].number==1 and .[2].number==2' <<<"$rules" >/dev/null || fail 'application backend fixture grouping'
    run_cli rule edit --number 1 --comment changed
    assert_status 0 'edit application number preserves all protocols'
    rules="$(vps_ufw_inventory)"
    jq -e 'length==3 and all(.[]|select(.number==1); .app=="Dual Service" and .comment=="changed") and .[2].port=="8081"' <<<"$rules" >/dev/null || fail 'application edit lost expansion or neighbor'
    id="$(jq -r '.[1].id' <<<"$rules")"
    run_cli rule delete --id "$id"
    assert_status 0 'individual expansion ID deletes native application group'
    vps_ufw_inventory | jq -e 'length==1 and .[0].port=="8081"' >/dev/null || fail 'application delete removed neighbor or left expansion'
}

# Package removal can fail after deleting the binary and files; recovery must
# restore custom configuration as well as the shared snapshot and boot state.
# These overrides stay in this subshell and never invoke real host binaries.
# shellcheck disable=SC2317
test_uninstall_failure_recovery() (
    local init original TEST_REMOVE_FAIL=1
    command() {
        if [[ $# == 2 && "$1" == -v && "$2" == ufw && -e "$VPSCTL_SYSTEM_ROOT/package-removed" ]]; then return 1; fi
        builtin command "$@"
    }
    apt-get() {
        case "${1:-}" in
            remove | purge)
                rm -f -- "$VPSCTL_SYSTEM_ROOT/etc/ufw/custom.conf" "$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d/openssh-server"
                touch "$VPSCTL_SYSTEM_ROOT/package-removed"
                [[ "$TEST_REMOVE_FAIL" == 0 ]]
                ;;
            install) rm -f -- "$VPSCTL_SYSTEM_ROOT/package-removed" ;;
            update) return 0 ;;
            *) return 1 ;;
        esac
    }
    rc-update() {
        local path="$VPSCTL_SYSTEM_ROOT/etc/runlevels/default/ufw"
        case "${1:-}" in
            add)
                mkdir -p -- "${path%/*}"
                touch "$path"
                ;;
            del) rm -f -- "$path" ;;
            *) return 1 ;;
        esac
    }
    for init in systemd openrc; do
        reset_fixture
        VPSCTL_ENV_INIT="$init"
        TEST_REMOVE_FAIL=1
        run_cli rule add --family ipv4 --port 8080
        assert_status 0 "$init recovery fixture"
        ufw enable >/dev/null
        if [[ "$init" == systemd ]]; then
            systemctl enable ufw.service
        else rc-update add ufw default; fi
        printf 'custom-policy\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/custom.conf"
        original="$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" "$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules" "$VPSCTL_SYSTEM_ROOT/etc/ufw/custom.conf" "$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d/openssh-server")"
        run_cli uninstall --purge --confirm-purge
        assert_status 20 "$init partial package removal failure"
        [[ ! -e "$VPSCTL_SYSTEM_ROOT/package-removed" ]] || fail "$init package was not reinstalled"
        [[ "$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" "$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules" "$VPSCTL_SYSTEM_ROOT/etc/ufw/custom.conf" "$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d/openssh-server")" == "$original" ]] || fail "$init failed uninstall lost complete configuration"
        vps_ufw_is_active || fail "$init failed uninstall left UFW inactive"
        if [[ "$init" == systemd ]]; then
            [[ -e "$VPSCTL_SYSTEM_ROOT/boot-enabled" ]] || fail 'systemd boot state was not restored'
        else
            [[ -e "$VPSCTL_SYSTEM_ROOT/etc/runlevels/default/ufw" ]] || fail 'OpenRC boot state was not restored'
        fi
        TEST_REMOVE_FAIL=0
        run_cli uninstall
        assert_status 0 "$init uninstall preserving configuration"
        [[ -e "$VPSCTL_SYSTEM_ROOT/package-removed" ]] || fail "$init successful uninstall left package installed"
        [[ ! -e "$VPSCTL_SYSTEM_ROOT/boot-enabled" && ! -e "$VPSCTL_SYSTEM_ROOT/etc/runlevels/default/ufw" ]] || fail "$init successful uninstall left boot enabled"
        [[ "$(cat "$VPSCTL_SYSTEM_ROOT/etc/ufw/custom.conf")" == custom-policy && "$(cat "$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d/openssh-server")" == owned-by-openssh ]] || fail "$init successful uninstall lost saved configuration"
        [[ "$(cat "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf")" == ENABLED=no ]] || fail "$init successful uninstall retained active configuration"
    done
)

# dpkg remembers deleted conffiles after remove, but forgets them after purge.
# Model that package state so a subsequent public install must restore a usable
# UFW configuration without losing another package's application profile.
# shellcheck disable=SC2317
test_apt_uninstall_reinstall() (
    local flow original TEST_PURGE_FAIL=0
    command() {
        if [[ $# == 2 && "$1" == -v && "$2" == ufw && "$(cat "$VPSCTL_SYSTEM_ROOT/package-state")" != installed ]]; then return 1; fi
        builtin command "$@"
    }
    apt-get() {
        case "${1:-}" in
            remove) printf 'residual\n' >"$VPSCTL_SYSTEM_ROOT/package-state" ;;
            purge)
                printf 'absent\n' >"$VPSCTL_SYSTEM_ROOT/package-state"
                rm -f -- "$VPSCTL_SYSTEM_ROOT/etc/default/ufw" "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" "$VPSCTL_SYSTEM_ROOT/etc/ufw/before.init"
                [[ "$TEST_PURGE_FAIL" == 0 ]]
                ;;
            install)
                if [[ "$(cat "$VPSCTL_SYSTEM_ROOT/package-state")" == absent ]]; then
                    mkdir -p -- "$VPSCTL_SYSTEM_ROOT/etc/default" "$VPSCTL_SYSTEM_ROOT/etc/ufw"
                    printf 'IPV6=yes\n' >"$VPSCTL_SYSTEM_ROOT/etc/default/ufw"
                    printf 'ENABLED=no\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf"
                    printf 'package-hook\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/before.init"
                fi
                printf 'installed\n' >"$VPSCTL_SYSTEM_ROOT/package-state"
                ;;
            update) return 0 ;;
            *) return 1 ;;
        esac
    }
    ufw() {
        [[ -r "$VPSCTL_SYSTEM_ROOT/etc/default/ufw" && -r "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" ]] || return 1
        [[ "${1:-}" != --force ]] || shift
        case "${1:-}" in
            status) printf 'Status: inactive\n' ;;
            disable) printf 'ENABLED=no\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" ;;
            default) return 0 ;;
            *) return 1 ;;
        esac
    }
    for flow in keep purge keep-then-purge; do
        reset_fixture
        printf 'installed\n' >"$VPSCTL_SYSTEM_ROOT/package-state"
        original="$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/default/ufw")"
        if [[ "$flow" != purge ]]; then
            run_cli uninstall
            assert_status 0 "$flow plain uninstall"
            [[ "$(cat "$VPSCTL_SYSTEM_ROOT/package-state")" == residual ]] || fail 'plain uninstall purged APT conffiles'
        fi
        if [[ "$flow" != keep ]]; then
            if [[ "$flow" == keep-then-purge ]]; then
                TEST_PURGE_FAIL=1
                run_cli uninstall --purge --confirm-purge
                assert_status 20 'failed residual-config purge'
                [[ "$(cat "$VPSCTL_SYSTEM_ROOT/package-state")" != installed ]] || fail 'failed residual-config purge installed an absent package'
                [[ "$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/default/ufw")" == "$original" ]] || fail 'failed residual-config purge lost saved configuration'
                TEST_PURGE_FAIL=0
            fi
            run_cli uninstall --purge --confirm-purge
            assert_status 0 "$flow purge"
        fi
        run_cli install
        assert_status 0 "$flow reinstall restores usable UFW conffiles"
        [[ "$(cat "$VPSCTL_SYSTEM_ROOT/package-state")" == installed ]] || fail "$flow reinstall did not install UFW"
        [[ -r "$VPSCTL_SYSTEM_ROOT/etc/default/ufw" ]] || fail "$flow reinstall left deleted dpkg conffiles"
        if [[ "$flow" == keep ]]; then
            [[ "$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/default/ufw")" == "$original" ]] || fail 'plain reinstall changed saved policy'
        fi
        [[ "$(cat "$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d/openssh-server")" == owned-by-openssh ]] || fail "$flow removed another package's application profile"
        if vps_ufw_is_active; then fail "$flow reinstall activated UFW"; fi
    done
    for flow in fresh saved; do
        reset_fixture
        if [[ "$flow" == fresh ]]; then
            rm -f -- "$VPSCTL_SYSTEM_ROOT/etc/default/ufw" "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf"
            printf 'absent\n' >"$VPSCTL_SYSTEM_ROOT/package-state"
        else
            printf 'saved-custom-hook\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/before.init"
            printf 'residual\n' >"$VPSCTL_SYSTEM_ROOT/package-state"
            original="$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/default/ufw" "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" "$VPSCTL_SYSTEM_ROOT/etc/ufw/before.init")"
        fi
        touch "$VPSCTL_SYSTEM_ROOT/fail-persist"
        run_cli install
        assert_status 20 "$flow install persistence failure"
        [[ "$(cat "$VPSCTL_SYSTEM_ROOT/package-state")" == absent ]] || fail "$flow install rollback left deleted dpkg conffile metadata"
        if [[ "$flow" == fresh ]]; then
            [[ ! -e "$VPSCTL_SYSTEM_ROOT/etc/default/ufw" && ! -e "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" && ! -e "$VPSCTL_SYSTEM_ROOT/etc/ufw/before.init" ]] || fail 'fresh install rollback left new configuration'
        else
            [[ "$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/default/ufw" "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" "$VPSCTL_SYSTEM_ROOT/etc/ufw/before.init")" == "$original" ]] || fail 'failed reinstall lost complete original configuration'
        fi
        [[ "$(cat "$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d/openssh-server")" == owned-by-openssh ]] || fail "$flow install rollback lost another package's application profile"
        rm -f -- "$VPSCTL_SYSTEM_ROOT/fail-persist"
        run_cli install
        assert_status 0 "$flow install can retry after persistence failure"
        [[ -r "$VPSCTL_SYSTEM_ROOT/etc/default/ufw" && -r "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" ]] || fail "$flow retry left UFW unusable"
        if [[ "$flow" == saved ]]; then
            [[ "$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/default/ufw" "$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf" "$VPSCTL_SYSTEM_ROOT/etc/ufw/before.init")" == "$original" ]] || fail 'retry installation changed saved configuration'
        fi
        if vps_ufw_is_active; then fail "$flow retry activated UFW"; fi
    done
)

# Prompt overrides are invoked indirectly by the sourced menu implementation.
# shellcheck disable=SC2317
test_menu_preserves_defaults() (
    local TEST_MENU_ID TEST_MENU_CHANGE='' original
    reset_fixture
    run_cli rule add --family ipv4 --action deny --proto udp --port 8443 --source 198.51.100.0/24 --comment keep-note --log log-all
    assert_status 0 'menu source fixture'
    TEST_MENU_ID="$(vps_ufw_inventory | jq -r '.[0].id')"
    ufw_cli_menu_select_rule() { printf '%s' "$TEST_MENU_ID"; }
    vps_cmd_prompt_select() { printf '%s' "$2"; }
    vps_cmd_prompt_value() {
        case "$TEST_MENU_CHANGE:$1" in
            port:端口、*) printf '9443' ;;
            source:来源\ IP/CIDR) printf '203.0.113.0/24' ;;
            *) printf '%s' "$2" ;;
        esac
    }
    original="$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")"
    ufw_cli_menu_rule advanced edit >"$TEST_TMP/menu-output" 2>&1 || fail 'advanced menu defaults failed'
    [[ "$(sha256sum "$VPSCTL_SYSTEM_ROOT/etc/ufw/user.rules")" == "$original" ]] || fail 'pressing Enter changed advanced rule'
    TEST_MENU_CHANGE=port
    ufw_cli_menu_rule simple edit >"$TEST_TMP/menu-output" 2>&1 || fail 'simple menu edit failed'
    vps_ufw_inventory | jq -e '.[0].port=="9443" and .[0].proto=="udp" and .[0].action=="deny" and .[0].source=="198.51.100.0/24" and .[0].comment=="keep-note" and .[0].log=="log-all"' >/dev/null || fail 'simple port menu reset other fields'
    TEST_MENU_ID="$(vps_ufw_inventory | jq -r '.[0].id')"
    TEST_MENU_CHANGE=source
    ufw_cli_menu_rule advanced edit >"$TEST_TMP/menu-output" 2>&1 || fail 'advanced menu source edit failed'
    vps_ufw_inventory | jq -e '.[0].source=="203.0.113.0/24" and .[0].proto=="udp" and .[0].action=="deny" and .[0].comment=="keep-note" and .[0].log=="log-all"' >/dev/null || fail 'advanced source menu reset other fields'
)

test_validation
test_business_inventory
test_rule_transactions
test_sync_protection_and_lifecycle
test_dry_run_and_business_lock
test_application_rule_group
test_uninstall_failure_recovery
test_apt_uninstall_reinstall
test_menu_preserves_defaults
printf 'PASS: network ufw command validation, business inventory, rule rollback, ownership and lifecycle\n'
