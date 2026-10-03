#!/usr/bin/env bash
# Tests intentionally exercise globals consumed by sourced DNS functions.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
TEST_SYSTEM_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_SYSTEM_ROOT"' EXIT

export VPSCTL_PROJECT_ROOT="$TEST_ROOT"
export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0 VPSCTL_ASSUME_YES=1 VPSCTL_NON_INTERACTIVE=1
export VPSCTL_QUIET=1 VPSCTL_VERBOSE=0 VPSCTL_NO_COLOR=1

mkdir -p "$TEST_SYSTEM_ROOT/etc" "$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/network/dns"
printf 'search svc.example\noptions timeout:1\nnameserver 192.0.2.53\n' >"$TEST_SYSTEM_ROOT/etc/resolv.conf"

# shellcheck source=../../commands/network/dns.sh
source "$TEST_ROOT/commands/network/dns.sh"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpectedly contains '$2'"; }

mock_dig_answer() {
    printf ';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n;; ANSWER SECTION:\nexample.com. 60 IN A 203.0.113.8\n'
}

test_address_validation() {
    vps_dns_validate_server 1.1.1.1 || fail "valid IPv4 was rejected"
    vps_dns_validate_server 2001:4860:4860::8888 || fail "valid IPv6 was rejected"
    ! vps_dns_validate_server 01.2.3.4 || fail "leading-zero IPv4 was accepted"
    ! vps_dns_validate_server 256.1.1.1 || fail "out-of-range IPv4 was accepted"
    ! vps_dns_validate_server 2001:::1 || fail "malformed IPv6 was accepted"
    vps_dns_parse_servers --server 1.1.1.1 --server 1.1.1.1 --server 8.8.8.8
    assert_equal 2 "${#VPS_DNS_SERVERS[@]}" "server deduplication"
    ! vps_dns_parse_servers --server 1.1.1.1 --server 8.8.8.8 --server 9.9.9.9 --server 208.67.222.222 >/dev/null 2>&1 || fail "more than three servers were accepted"
}

test_dns_answer_records_required() (
    local tool header response records code query_status=0
    dig() { printf '%s\n' "$response"; return "$query_status"; }
    drill() { printf '%s\n' "$response"; return "$query_status"; }

    for tool in dig drill; do
        if [[ "$tool" == dig ]]; then header=status; else header=rcode; fi
        response=";; ->>HEADER<<- opcode: QUERY, $header: NOERROR, id: 1"$'\n;; ANSWER SECTION:\nresolver.example. 60 IN CNAME target.example.\ntarget.example. 60 IN A 203.0.113.8'
        vps_dns_query "$tool" 192.0.2.53 resolver.example || fail "$tool rejected a CNAME followed by an address"
        response=";; ->>HEADER<<- opcode: QUERY, $header: NOERROR, id: 1"$'\n;; ANSWER SECTION:\nresolver.example. 60 IN AAAA 2001:db8::8'
        vps_dns_query "$tool" 192.0.2.53 resolver.example || fail "$tool rejected an IPv6-only answer"

        for records in '' \
            'resolver.example. 60 IN CNAME target.example.' \
            'resolver.example. 60 IN TXT 203.0.113.8' \
            'resolver.example. 60 IN A 256.0.0.1' \
            'resolver.example. 60 IN AAAA 2001:::8' \
            'resolver.example. 60 IN A target.example.'; do
            response=";; ->>HEADER<<- opcode: QUERY, $header: NOERROR, id: 1"$'\n;; ANSWER SECTION:\n'"$records"
            ! vps_dns_query "$tool" 192.0.2.53 resolver.example || fail "$tool accepted an answer without a valid address: $records"
        done
        for code in NXDOMAIN SERVFAIL; do
            response=";; ->>HEADER<<- opcode: QUERY, $header: $code, id: 1"$'\n;; ANSWER SECTION:\nresolver.example. 60 IN A 203.0.113.8'
            ! vps_dns_query "$tool" 192.0.2.53 resolver.example || fail "$tool accepted $code"
        done
        response=";; ->>HEADER<<- opcode: QUERY, $header: NOERROR, id: 1"$'\n;; QUESTION SECTION:\nresolver.example. 60 IN A 203.0.113.8\n;; ANSWER SECTION:\nresolver.example. 60 IN CNAME target.example.\n;; AUTHORITY SECTION:\nns.example. 60 IN A 192.0.2.53\n;; ADDITIONAL SECTION:\nns.example. 60 IN AAAA 2001:db8::53'
        ! vps_dns_query "$tool" 192.0.2.53 resolver.example || fail "$tool accepted an address outside the answer section"
        response=$';; ANSWER SECTION:\nresolver.example. 60 IN A 203.0.113.8'
        ! vps_dns_query "$tool" 192.0.2.53 resolver.example || fail "$tool accepted an answer without NOERROR"
        response=";; ->>HEADER<<- opcode: QUERY, $header: NOERROR, id: 1"$'\n;; ANSWER SECTION:\nresolver.example. 60 IN A 203.0.113.8'
        query_status=1
        ! vps_dns_query "$tool" 192.0.2.53 resolver.example || fail "$tool accepted a failing command"
        query_status=0
    done
)

test_lookup_answer_addresses() (
    local response tool
    nslookup() { printf '%s\n' "$response"; }
    host() { printf '%s\n' "$response"; }

    response=$'Server:\t192.0.2.53\nAddress:\t192.0.2.53#53\n\nNon-authoritative answer:\nName:\tresolver.example\nAddress: 203.0.113.8'
    vps_dns_query nslookup 192.0.2.53 resolver.example || fail "BIND nslookup answer was rejected"
    response=$'Server: 192.0.2.53\nAddress 1: 192.0.2.53 ns.example\n\nName: resolver.example\nAddress 1: 203.0.113.8 resolver.example'
    vps_dns_query nslookup 192.0.2.53 resolver.example || fail "BusyBox numbered nslookup answer was rejected"
    response=$'Server: 192.0.2.53\nAddress: 192.0.2.53:53\n\nName: resolver.example\nAddress: 2001:db8::8'
    vps_dns_query nslookup 192.0.2.53 resolver.example || fail "nslookup IPv6-only answer was rejected"
    response=$'Server: 192.0.2.53\nAddress 1: 192.0.2.53 ns.example\n\nName: resolver.example\nAddress 1: 2001:db8::8 resolver.example'
    vps_dns_query nslookup 192.0.2.53 resolver.example || fail "BusyBox numbered IPv6 answer was rejected"
    for response in \
        $'Server: 192.0.2.53\nAddress: 192.0.2.53#53\nName: resolver.example' \
        $'Server: 192.0.2.53\nAddress 1: 192.0.2.53 ns.example\nresolver.example canonical name = target.example.' \
        $'Address: 203.0.113.8\nName: resolver.example\nServer: 192.0.2.53\nAddress: 192.0.2.53' \
        $'Server: 192.0.2.53\nAddress: 192.0.2.53#53\n** server can\047t find resolver.example: NXDOMAIN' \
        $'Server: 192.0.2.53\nAddress: 192.0.2.53#53\n** server can\047t find resolver.example: SERVFAIL' \
        $'Name: resolver.example\nAddress: 256.0.0.1\nAddress 2: 2001:::8'; do
        ! vps_dns_query nslookup 192.0.2.53 resolver.example || fail "nslookup accepted output without an answer address"
    done

    response=$'resolver.example is an alias for target.example.\ntarget.example has address 203.0.113.8'
    vps_dns_query host "" resolver.example || fail "host answer was rejected"
    response='resolver.example has IPv6 address 2001:db8::8'
    vps_dns_query host "" resolver.example || fail "host IPv6-only answer was rejected"
    for response in \
        'resolver.example is an alias for target.example.' \
        'resolver.example mail is handled by 10 mail.example.' \
        $'Using domain server:\nName: 192.0.2.53\nAddress: 192.0.2.53#53' \
        'Host resolver.example not found: 3(NXDOMAIN)' \
        'Host resolver.example not found: 2(SERVFAIL)' \
        'resolver.example has address 256.0.0.1' \
        'resolver.example has IPv6 address 2001:::8'; do
        ! vps_dns_query host "" resolver.example || fail "host accepted output without an answer address"
    done
    for tool in nslookup host; do
        if [[ "$tool" == nslookup ]]; then
            nslookup() { printf 'Name: resolver.example\nAddress: 203.0.113.8\n'; return 1; }
        else
            host() { printf 'resolver.example has address 203.0.113.8\n'; return 1; }
        fi
        ! vps_dns_query "$tool" "" resolver.example || fail "$tool accepted a failing command"
    done
)

test_query_server_routing_and_ipv6_retry() (
    local calls="$TEST_SYSTEM_ROOT/dns-query-calls" tool output expected response_a response_aaaa
    record_query() {
        local IFS='|'
        printf '%s\n' "$*" >>"$calls"
        case "$*" in
            *'|AAAA' | *'-type=AAAA|'* | *'|-t|AAAA|'*) printf '%s\n' "$response_aaaa" ;;
            *) printf '%s\n' "$response_a" ;;
        esac
    }
    dig() { record_query dig "$@"; }
    drill() { record_query drill "$@"; }
    nslookup() { record_query nslookup "$@"; }
    host() { record_query host "$@"; }

    for tool in dig drill nslookup host; do
        case "$tool" in
            dig | drill)
                if [[ "$tool" == dig ]]; then output=status; else output=rcode; fi
                response_a=";; ->>HEADER<<- opcode: QUERY, $output: NOERROR, id: 1"$'\n;; ANSWER SECTION:\nresolver.example. 60 IN A 203.0.113.8'
                response_aaaa=";; ->>HEADER<<- opcode: QUERY, $output: NOERROR, id: 1"$'\n;; ANSWER SECTION:\nresolver.example. 60 IN AAAA 2001:db8::8'
                ;;
            nslookup)
                response_a=$'Name: resolver.example\nAddress: 203.0.113.8'
                response_aaaa=$'Name: resolver.example\nAddress: 2001:db8::8'
                ;;
            host)
                response_a='resolver.example has address 203.0.113.8'
                response_aaaa='resolver.example has IPv6 address 2001:db8::8'
                ;;
        esac
        : >"$calls"
        vps_dns_query "$tool" 192.0.2.53 resolver.example || fail "$tool explicit query failed"
        output="$(<"$calls")"
        case "$tool" in
            dig) expected='dig|+time=3|+tries=1|+noall|+comments|+answer|@192.0.2.53|resolver.example|A' ;;
            drill) expected='drill|@192.0.2.53|resolver.example|A' ;;
            nslookup) expected='nslookup|-timeout=3|-type=A|resolver.example|192.0.2.53' ;;
            host) expected='host|-W|3|-t|A|resolver.example|192.0.2.53' ;;
        esac
        assert_equal "$expected" "$output" "$tool explicit server and A-first invocation"

        : >"$calls"
        vps_dns_query "$tool" "" resolver.example || fail "$tool default query failed"
        output="$(<"$calls")"
        expected="${expected//|@192.0.2.53/}"
        expected="${expected//|192.0.2.53/}"
        assert_equal "$expected" "$output" "$tool default resolver invocation"

        response_a=''
        : >"$calls"
        vps_dns_query "$tool" "" resolver.example || fail "$tool IPv6 retry failed"
        output="$(<"$calls")"
        assert_contains "$output" "$expected" "$tool A query before IPv6 retry"
        assert_contains "$output" 'AAAA' "$tool AAAA retry"
        assert_equal 2 "$(wc -l <"$calls" | tr -d '[:space:]')" "$tool IPv6 retry query count"
    done
)

test_system_resolution_routes() (
    local available='getent host dig drill nslookup' calls="$TEST_SYSTEM_ROOT/dns-system-calls"
    local response=$'203.0.113.8 STREAM resolver.example\n203.0.113.8 DGRAM\n203.0.113.8 RAW' getent_status=0 output status tool
    VPS_DNS_TEST_DOMAIN=resolver.example
    VPS_DNS_SERVERS=(192.0.2.53)
    VPS_DNS_BACKEND=plain
    VPSCTL_QUIET=0
    command() {
        if [[ "${1:-}" == -v ]]; then
            case "${2:-}" in
                getent | host | dig | drill | nslookup) [[ " $available " == *" $2 "* ]]; return $? ;;
            esac
        fi
        builtin command "$@"
    }
    getent() {
        local IFS='|'
        printf 'getent|%s\n' "$*" >>"$calls"
        printf '%s\n' "$response"
        return "$getent_status"
    }
    record_query() {
        local IFS='|'
        printf '%s\n' "$*" >>"$calls"
        printf '%s\n' "$response"
    }
    host() { record_query host "$@"; }
    dig() { record_query dig "$@"; }
    drill() { record_query drill "$@"; }
    nslookup() { record_query nslookup "$@"; }
    vps_dns_verify_servers() { return 0; }

    for response in $'203.0.113.8 STREAM resolver.example' $'2001:db8::8 STREAM resolver.example'; do
        : >"$calls"
        vps_dns_verify_system_resolution || fail "getent address was rejected"
        assert_equal 'getent|ahosts|resolver.example' "$(<"$calls")" "getent uses the libc/NSS route"
        output="$(vps_dns_verify 2>&1)" || fail "getent verification failed"
        assert_contains "$output" 'DNS 服务器与系统解析验证通过' "getent success wording"
    done
    for response in '' 'resolver.example STREAM' '256.0.0.1 STREAM resolver.example' '2001:::8 STREAM resolver.example'; do
        : >"$calls"
        ! vps_dns_verify_system_resolution || fail "getent output without a valid address was accepted"
        assert_equal 'getent|ahosts|resolver.example' "$(<"$calls")" "invalid getent output does not fall back"
    done
    response=$'203.0.113.8 STREAM resolver.example'
    getent_status=2
    : >"$calls"
    ! vps_dns_verify_system_resolution || fail "getent failure with address output was accepted"
    assert_equal 'getent|ahosts|resolver.example' "$(<"$calls")" "getent failure does not bypass libc/NSS"
    status=0
    vps_dns_verify >/dev/null 2>&1 || status=$?
    assert_equal 20 "$status" "verify preserves resolution failure status"

    getent_status=0
    available='host dig drill nslookup'
    response='resolver.example is an alias for target.example.'
    : >"$calls"
    ! vps_dns_verify_system_resolution >/dev/null 2>&1 || fail "host CNAME-only system lookup was accepted"
    output="$(<"$calls")"
    assert_not_contains "$output" 'dig|' "host failure does not try another tool"
    assert_equal 2 "$(wc -l <"$calls" | tr -d '[:space:]')" "host A and AAAA failure query count"
    status=0
    output="$(vps_dns_verify 2>&1)" || status=$?
    assert_equal 20 "$status" "default DNS failure verify status"
    assert_contains "$output" '默认 DNS 解析 resolver.example 失败' "default DNS failure wording"

    for tool in host dig drill nslookup; do
        available="$tool"
        case "$tool" in
            host) response='resolver.example has address 203.0.113.8' ;;
            dig) response=$';; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n;; ANSWER SECTION:\nresolver.example. 60 IN A 203.0.113.8' ;;
            drill) response=$';; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 1\n;; ANSWER SECTION:\nresolver.example. 60 IN A 203.0.113.8' ;;
            nslookup) response=$'Server: 192.0.2.53\nAddress: 192.0.2.53#53\nName: resolver.example\nAddress: 203.0.113.8' ;;
        esac
        : >"$calls"
        output="$(vps_dns_verify_system_resolution 2>&1)" || fail "$tool system fallback failed"
        assert_contains "$output" "getent 不可用，使用 $tool 检查默认 DNS 配置" "$tool fallback wording"
        assert_not_contains "$(<"$calls")" '192.0.2.53' "$tool system fallback must omit configured server"
        assert_equal 1 "$(wc -l <"$calls" | tr -d '[:space:]')" "$tool default resolver query count"
        output="$(vps_dns_verify 2>&1)" || fail "$tool fallback verification failed"
        assert_contains "$output" 'DNS 服务器与默认 DNS 解析验证通过' "$tool fallback success wording"
    done
)

test_standalone_globals() {
    VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0 VPSCTL_ASSUME_YES=0 VPSCTL_NON_INTERACTIVE=0 VPSCTL_QUIET=0 VPSCTL_VERBOSE=0
    vps_dns_parse_standalone_globals --dry-run --install-deps --yes --non-interactive --quiet --verbose --no-color -- set --server 1.1.1.1
    assert_equal 1 "$VPSCTL_DRY_RUN" "standalone dry-run"
    assert_equal 1 "$VPSCTL_INSTALL_DEPS" "standalone install-deps"
    assert_equal 1 "$VPSCTL_ASSUME_YES" "standalone yes"
    assert_equal 1 "$VPSCTL_NON_INTERACTIVE" "standalone non-interactive"
    assert_equal 1 "$VPSCTL_QUIET" "standalone quiet"
    assert_equal 1 "$VPSCTL_VERBOSE" "standalone verbose"
    assert_equal 1 "$VPSCTL_NO_COLOR" "standalone no-color"
    assert_equal set "${VPS_DNS_ARGS[0]}" "standalone option terminator"
    VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0 VPSCTL_ASSUME_YES=1 VPSCTL_NON_INTERACTIVE=1 VPSCTL_QUIET=1 VPSCTL_VERBOSE=0
}

test_shared_dependency_handling() (
    local calls=0 status=0

    VPSCTL_DRY_RUN=0
    VPSCTL_NON_INTERACTIVE=1
    VPSCTL_INSTALL_DEPS=1
    vps_cmd_ensure_tools() {
        assert_equal 1 "$VPSCTL_INSTALL_DEPS" "global dependency authorization passed to shared helper"
        assert_equal network-dns "$1" "shared dependency feature"
        assert_equal dns-query "$2" "shared DNS query dependency"
        calls=$((calls + 1))
    }
    vps_cmd_confirm() { fail "DNS dependency handling must not ask a dedicated install question"; }
    vps_dns_install_query_tool
    assert_equal 1 "$calls" "global dependency authorization call count"
    assert_equal 1 "$VPSCTL_INSTALL_DEPS" "global dependency authorization preserved"

    calls=0
    VPSCTL_INSTALL_DEPS=0
    vps_dns_parse_servers --server 1.1.1.1 --install-deps
    assert_equal 1 "$VPSCTL_INSTALL_DEPS" "legacy action dependency option maps to global authorization"
    vps_dns_install_query_tool
    assert_equal 1 "$calls" "action dependency authorization call count"

    calls=0
    status=0
    VPSCTL_INSTALL_DEPS=1
    vps_cmd_ensure_tools() {
        calls=$((calls + 1))
        return 20
    }
    vps_dns_install_query_tool >/dev/null 2>&1 || status=$?
    assert_equal 20 "$status" "dependency installer failure status"
    assert_equal 1 "$calls" "failing dependency helper call count"
    assert_equal 1 "$VPSCTL_INSTALL_DEPS" "global authorization restored after dependency failure"

    calls=0
    status=0
    VPSCTL_INSTALL_DEPS=0
    vps_cmd_ensure_tools() {
        calls=$((calls + 1))
        return 3
    }
    vps_dns_install_query_tool >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" "missing DNS dependency authorization status"
    assert_equal 1 "$calls" "unauthorized DNS dependency is delegated to shared helper"
)

test_interactive_menu_inputs() (
    local menu_marker="${TEST_SYSTEM_ROOT}/dns-menu-marker" captured status=0
    local failure_marker="${TEST_SYSTEM_ROOT}/dns-menu-failure-marker"

    VPSCTL_NON_INTERACTIVE=0
    vps_cmd_prompt_select() {
        case "$1" in
            "DNS 管理")
                assert_equal show "$2" "DNS menu default action"
                assert_equal test "$5" "DNS menu test action value"
                assert_equal "测试服务器" "$6" "DNS menu test action label"
                assert_equal set "$7" "DNS menu set action value"
                assert_equal "设置服务器" "$8" "DNS menu set action label"
                if [[ -e "$menu_marker" ]]; then
                    printf quit
                else
                    : >"$menu_marker"
                    printf test
                fi
                ;;
            "选择测试域名")
                assert_equal example "$2" "test domain default choice"
                assert_equal custom "$5" "custom domain choice value"
                assert_equal "输入自定义域名" "$6" "custom domain choice label"
                printf custom
                ;;
            *) fail "unexpected select prompt: $1" ;;
        esac
    }
    vps_cmd_prompt_value() {
        case "$1" in
            "输入一至三个 DNS 服务器"*) printf '1.1.1.1, 9.9.9.9' ;;
            "输入测试域名") printf 'resolver.example' ;;
            *) fail "unexpected value prompt: $1" ;;
        esac
    }
    vps_dns_test_candidates() {
        printf '%s|%s\n' "$(vps_dns_join_servers)" "$VPS_DNS_TEST_DOMAIN" >"${TEST_SYSTEM_ROOT}/dns-menu-captured"
    }

    vps_dns_menu
    captured="$(<"${TEST_SYSTEM_ROOT}/dns-menu-captured")"
    assert_equal '1.1.1.1 9.9.9.9|resolver.example' "$captured" "interactive DNS server and custom domain collection"

    vps_cmd_prompt_select() {
        [[ "$1" == "DNS 管理" ]] || fail "unexpected failure-path prompt: $1"
        if [[ -e "$failure_marker" ]]; then printf quit; else : >"$failure_marker"; printf show; fi
    }
    vps_dns_show() { return 20; }
    vps_dns_menu >/dev/null 2>&1 || status=$?
    assert_equal 20 "$status" "interactive DNS failure status propagation"
)

test_dry_run_dependency_and_dns_plan() (
    local empty_path output

    VPSCTL_DRY_RUN=1
    VPSCTL_INSTALL_DEPS=1
    VPSCTL_QUIET=0
    VPS_DNS_SERVERS=(9.9.9.9)
    VPS_DNS_TEST_DOMAIN=example.com
    vps_dns_query_tool() { return 1; }
    vps_dns_install_query_tool() {
        VPS_CMD_DEPENDENCIES_PLANNED=1
        vps_cmd_info "演练：将安装 DNS 查询依赖"
    }
    vps_dns_detect_backend() {
        VPS_DNS_BACKEND=plain
        VPS_DNS_NM_CONNECTION=""
        VPS_DNS_NM_DEVICE=""
    }
    vps_dns_require_writable_target() { return 0; }
    vps_dns_write_plain() { vps_cmd_info "演练：将替换 /etc/resolv.conf"; }
    vps_dns_refresh_backend() { vps_cmd_info "演练：将刷新 DNS 后端"; }

    output="$(vps_dns_set 2>&1)"
    assert_contains "$output" '将安装 DNS 查询依赖' "dry-run DNS dependency plan"
    assert_contains "$output" '安装依赖后将查询候选 DNS 服务器' "dry-run deferred query plan"
    assert_contains "$output" '将替换 /etc/resolv.conf' "dry-run DNS write plan after dependencies"
    assert_contains "$output" '将刷新 DNS 后端' "dry-run DNS refresh plan after dependencies"

    empty_path="${TEST_SYSTEM_ROOT}/empty-query-path"
    mkdir -p -- "$empty_path"
    output="$(PATH="$empty_path" vps_dns_verify_system_resolution 2>&1)"
    assert_contains "$output" '安装依赖后将验证系统解析链路' "dry-run deferred verify plan"
)

test_chinese_status_without_ansi() {
    local output help_output
    VPSCTL_QUIET=0 VPSCTL_NO_COLOR=1 VPSCTL_NON_INTERACTIVE=1
    vps_dns_detect_backend() {
        VPS_DNS_BACKEND=plain
        VPS_DNS_NM_CONNECTION=""
        VPS_DNS_NM_DEVICE=""
    }
    vps_dns_effective_servers() { printf '1.1.1.1\n2606:4700:4700::1111\n'; }
    output="$(vps_dns_show)"
    assert_contains "$output" 'DNS 后端' "Chinese backend status"
    assert_contains "$output" '静态 /etc/resolv.conf' "Chinese backend value"
    assert_contains "$output" '活动服务器' "Chinese server status"
    assert_contains "$output" '1.1.1.1' "Chinese server value"
    assert_not_contains "$output" $'\033[' "no ANSI in non-color status"
    help_output="$(vps_dns_usage)"
    assert_contains "$help_output" '动作：' "Chinese help"
    assert_contains "$help_output" '--no-color' "standalone no-color help"
    VPSCTL_QUIET=1
}

test_backend_detection() {
    ip() { printf 'default via 192.0.2.1 dev eth0 proto dhcp\n'; }
    nmcli() {
        [[ "$*" == *'GENERAL.CONNECTION'* ]] && printf 'primary\n'
    }
    vps_dns_detect_backend
    assert_equal networkmanager "$VPS_DNS_BACKEND" "NetworkManager ownership"
    assert_equal primary "$VPS_DNS_NM_CONNECTION" "default NetworkManager connection"

    ip() { return 1; }
    nmcli() { return 1; }
    resolvectl() { return 0; }
    systemctl() { return 0; }
    vps_dns_detect_backend
    assert_equal plain "$VPS_DNS_BACKEND" "active resolved service without owned resolv.conf"
    mkdir -p "$TEST_SYSTEM_ROOT/run/systemd/resolve"
    printf 'nameserver 127.0.0.53\n' >"$TEST_SYSTEM_ROOT/run/systemd/resolve/stub-resolv.conf"
    rm -f "$TEST_SYSTEM_ROOT/etc/resolv.conf"
    ln -s ../run/systemd/resolve/stub-resolv.conf "$TEST_SYSTEM_ROOT/etc/resolv.conf"
    if [[ -L "$TEST_SYSTEM_ROOT/etc/resolv.conf" ]]; then
        vps_dns_detect_backend
        assert_equal systemd-resolved "$VPS_DNS_BACKEND" "systemd-resolved ownership"
        ip() { printf 'default via 192.0.2.1 dev eth0\n'; }
        nmcli() { [[ "$*" == *'GENERAL.CONNECTION'* ]] && printf 'primary\n'; }
        vps_dns_detect_backend
        assert_equal networkmanager "$VPS_DNS_BACKEND" "NetworkManager with resolved rc-manager stack"
        ip() { return 1; }
        nmcli() { return 1; }
        rm -f "$TEST_SYSTEM_ROOT/etc/resolv.conf"
        ln -s ../mystery-resolv.conf "$TEST_SYSTEM_ROOT/etc/resolv.conf"
        vps_dns_detect_backend
        assert_equal unsafe-symlink "$VPS_DNS_BACKEND" "unknown resolv.conf symlink"
    fi

    resolvectl() { return 1; }
    systemctl() { return 1; }
    resolvconf() { [[ "${1:-}" == --version ]] && printf 'openresolv 3.13\n'; }
    rm -f "$TEST_SYSTEM_ROOT/etc/resolv.conf"
    printf 'nameserver 192.0.2.53\n' >"$TEST_SYSTEM_ROOT/etc/resolv.conf"
    vps_dns_detect_backend
    assert_equal openresolv "$VPS_DNS_BACKEND" "openresolv ownership"

    mkdir -p "$TEST_SYSTEM_ROOT/etc/resolvconf/run"
    resolvconf() { [[ "${1:-}" == --version ]] && printf 'Debian resolvconf 1.91\n'; }
    vps_dns_detect_backend
    assert_equal debian-resolvconf "$VPS_DNS_BACKEND" "legacy Debian resolvconf ownership"
}

test_preflight_failure_does_not_write() {
    local before after status
    before="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    dig() { return 1; }
    VPS_DNS_SERVERS=(9.9.9.9)
    VPS_DNS_TEST_DOMAIN=example.com
    if vps_dns_set; then status=0; else status=$?; fi
    [[ "$status" != 0 ]] || fail "failed preflight returned success"
    after="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_equal "$before" "$after" "failed preflight must not write"
}

test_plain_replacement_preserves_directives() {
    local content count
    printf '# managed locally\n   search svc.example corp.example\nnameserver 192.0.2.1\noptions rotate timeout:1\nnameserver 192.0.2.2\n' >"$TEST_SYSTEM_ROOT/etc/resolv.conf"
    assert_equal 'svc.example corp.example' "$(vps_dns_collect_search)" "leading-space search collection"
    VPS_DNS_SERVERS=(1.1.1.1 2606:4700:4700::1111)
    vps_dns_write_plain
    content="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_contains "$content" 'search svc.example corp.example' "leading-space search preservation"
    assert_contains "$content" 'options rotate timeout:1' "options preservation"
    assert_contains "$content" 'nameserver 1.1.1.1' "IPv4 replacement"
    assert_contains "$content" 'nameserver 2606:4700:4700::1111' "IPv6 replacement"
    assert_not_contains "$content" 'nameserver 192.0.2.1' "old server removal"
    count="$(grep -c '^nameserver ' "$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_equal 2 "$count" "complete server replacement"
}

test_openresolv_replacement() {
    local content
    printf 'dynamic_order="tap0 eth0"\nname_servers="192.0.2.1"\nname_server_blacklist="192.0.2.*"\nreplace="$replace nameserver/*/"\n' >"$TEST_SYSTEM_ROOT/etc/resolvconf.conf"
    VPS_DNS_SERVERS=(1.1.1.1 8.8.8.8)
    vps_dns_write_openresolv
    content="$(<"$TEST_SYSTEM_ROOT/etc/resolvconf.conf")"
    assert_contains "$content" 'dynamic_order="tap0 eth0"' "openresolv dynamic order preservation"
    assert_contains "$content" 'name_servers="1.1.1.1 8.8.8.8"' "openresolv servers"
    assert_contains "$content" 'replace="$replace nameserver/*/"' "openresolv dynamic server replacement"
    assert_equal 1 "$(grep -Fc 'replace="$replace nameserver/*/"' "$TEST_SYSTEM_ROOT/etc/resolvconf.conf")" "single openresolv replacement rule"
    assert_not_contains "$content" '192.0.2.*' "old openresolv blacklist removal"
}

# These runtime stubs are invoked indirectly by the sourced DNS command.
# shellcheck disable=SC2317
setup_dns_set_fixture() {
    DNS_TEST_BACKEND="$1"
    DNS_TEST_ROOT="$(mktemp -d "$TEST_SYSTEM_ROOT/dns-set.XXXXXX")"
    DNS_TEST_CALLS="$DNS_TEST_ROOT/calls"
    DNS_TEST_RUNTIME="$DNS_TEST_ROOT/runtime"
    DNS_TEST_RESOLUTION_STATUS=0 DNS_TEST_BACKUP_STATUS=0 DNS_TEST_WRITE_STATUS=0 DNS_TEST_READ_FAILURE=""
    export VPSCTL_SYSTEM_ROOT="$DNS_TEST_ROOT"
    VPSCTL_DRY_RUN=0 VPSCTL_QUIET=0
    VPS_DNS_SERVERS=(1.1.1.1 8.8.8.8 2001:db8::53)
    VPS_DNS_TEST_DOMAIN=example.com
    mkdir -p "$DNS_TEST_ROOT/etc" "$DNS_TEST_ROOT/nm"
    : >"$DNS_TEST_CALLS"
    printf 'search svc.example corp.example\noptions rotate timeout:1\nnameserver 192.0.2.53\n' >"$DNS_TEST_ROOT/etc/resolv.conf"
    printf 'dynamic_order="eth0"\nname_servers="192.0.2.53"\n' >"$DNS_TEST_ROOT/etc/resolvconf.conf"
    printf '192.0.2.53\n' >"$DNS_TEST_RUNTIME"
    printf '192.0.2.53\n' >"$DNS_TEST_ROOT/nm/ipv4.dns"
    printf '\n' >"$DNS_TEST_ROOT/nm/ipv6.dns"

    record_dns_call() { local IFS=' '; printf '%s\n' "$*" >>"$DNS_TEST_CALLS"; }
    update_dns_runtime() {
        if [[ "$DNS_TEST_BACKEND" == systemd-resolved ]]; then
            local file line value section=''
            local -a servers=() values=()
            for file in "$DNS_TEST_ROOT/etc/systemd/resolved.conf" "$DNS_TEST_ROOT/etc/systemd/resolved.conf.d/"*.conf; do
                [[ -f "$file" ]] || continue
                section=''
                while IFS= read -r line || [[ -n "$line" ]]; do
                    if [[ "$line" == '['*']' ]]; then section="$line"; fi
                    [[ "$section" == '[Resolve]' && "$line" == DNS=* ]] || continue
                    value="${line#DNS=}"
                    if [[ -z "$value" ]]; then
                        servers=()
                    else
                        IFS=' ' read -r -a values <<<"$value"
                        servers+=("${values[@]}")
                    fi
                done <"$file"
            done
            printf '%s\n' "${servers[@]}" >"$DNS_TEST_RUNTIME"
        else
            printf '%s\n' "${VPS_DNS_SERVERS[@]}" >"$DNS_TEST_RUNTIME"
        fi
        if [[ "$DNS_TEST_BACKEND" == openresolv || "$DNS_TEST_BACKEND" == networkmanager ]]; then
            vps_dns_plain_content >"$DNS_TEST_ROOT/etc/resolv.conf.next"
            mv -- "$DNS_TEST_ROOT/etc/resolv.conf.next" "$DNS_TEST_ROOT/etc/resolv.conf"
        fi
    }
    vps_dns_detect_backend() {
        VPS_DNS_BACKEND="$DNS_TEST_BACKEND"
        VPS_DNS_NM_CONNECTION=primary VPS_DNS_NM_DEVICE=eth0
    }
    vps_cmd_confirm() { record_dns_call confirm; }
    vps_cmd_require_root() { record_dns_call root; }
    vps_dns_require_writable_target() { record_dns_call writable "$1"; }
    vps_cmd_ensure_tools() {
        assert_equal 'network-dns flock' "$1 $2" "set lock dependency"
        record_dns_call dependencies
    }
    vps_cmd_lock() { record_dns_call lock "$1"; }
    vps_cmd_unlock() { record_dns_call unlock; }
    vps_dns_backup_current() { record_dns_call backup "$1"; return "$DNS_TEST_BACKUP_STATUS"; }
    vps_cmd_atomic_write() {
        local file
        record_dns_call write "$1"
        ((DNS_TEST_WRITE_STATUS == 0)) || return "$DNS_TEST_WRITE_STATUS"
        file="$(vps_dns_path "$1")"
        cat >"$file.next" || return 20
        mv -- "$file.next" "$file"
    }
    vps_cmd_run() {
        if [[ "$VPSCTL_DRY_RUN" == 1 ]]; then
            local IFS=' '
            vps_cmd_info "演练：$*"
            return 0
        fi
        record_dns_call run "$@"
        "$@"
    }
    dig() { record_dns_call candidate "$@"; mock_dig_answer; }
    getent() {
        record_dns_call resolution
        printf '203.0.113.8 STREAM example.com\n'
        return "$DNS_TEST_RESOLUTION_STATUS"
    }
    systemctl() { update_dns_runtime; }
    resolvconf() { [[ "$1" == -u ]] || return 1; update_dns_runtime; }
    resolvectl() {
        if [[ "$1" == dns ]]; then
            printf 'Global: '
            while IFS= read -r server; do printf '%s ' "$server"; done <"$DNS_TEST_RUNTIME"
            printf '\n'
        else
            [[ "$1" == flush-caches ]]
        fi
    }
    vps_dns_resolv_link_owner() { printf 'regular\n'; }
    nmcli() {
        local property value
        if [[ "$1" == --escape && "$2" == no && "$3" == -g ]]; then
            property="$4"
            record_dns_call read "$property"
            if [[ "$property" == IP4.DNS,IP6.DNS ]]; then
                cat "$DNS_TEST_RUNTIME"
            else
                cat "$DNS_TEST_ROOT/nm/$property"
                if [[ "$property" == "$DNS_TEST_READ_FAILURE" && -f "$DNS_TEST_ROOT/fail-read" ]]; then
                    rm -- "$DNS_TEST_ROOT/fail-read"
                    return 20
                fi
            fi
        elif [[ "$1 $2" == 'connection modify' ]]; then
            record_dns_call write networkmanager
            shift 3
            while (($# > 0)); do
                property="$1" value="$2"
                printf '%s\n' "$value" >"$DNS_TEST_ROOT/nm/$property"
                shift 2
            done
        elif [[ "$1 $2" == 'device reapply' ]]; then
            update_dns_runtime
        else
            [[ "$1 $2" == 'connection reload' ]]
        fi
    }
}

assert_dns_set_applied() {
    local calls
    calls="$(<"$DNS_TEST_CALLS")"
    assert_equal 1 "$(grep -c '^backup ' "$DNS_TEST_CALLS")" "$1 backup"
    assert_equal 1 "$(grep -c '^write ' "$DNS_TEST_CALLS")" "$1 write"
    assert_contains "$calls" 'run resolvectl flush-caches' "$1 cache refresh"
    case "$DNS_TEST_BACKEND" in
        networkmanager) assert_contains "$calls" 'run nmcli device reapply eth0' "$1 device reapply" ;;
        systemd-resolved) assert_contains "$calls" 'run systemctl restart systemd-resolved' "$1 resolved restart" ;;
        openresolv) assert_contains "$calls" 'run resolvconf -u' "$1 openresolv refresh" ;;
    esac
}

assert_dns_set_skipped() {
    local calls
    calls="$(<"$DNS_TEST_CALLS")"
    assert_not_contains "$calls" 'backup ' "$1 backup"
    assert_not_contains "$calls" 'write ' "$1 write"
    assert_not_contains "$calls" 'run ' "$1 refresh"
    assert_contains "$calls" 'confirm' "$1 confirmation"
    assert_contains "$calls" 'root' "$1 privilege check"
    assert_contains "$calls" 'lock network-dns' "$1 lock"
    assert_contains "$calls" 'unlock' "$1 unlock"
    assert_equal "${#VPS_DNS_SERVERS[@]}" "$(grep -c '^candidate ' "$DNS_TEST_CALLS")" "$1 candidate preflight"
    assert_equal 1 "$(grep -c '^resolution$' "$DNS_TEST_CALLS")" "$1 runtime verification"
    assert_contains "$(<"$DNS_TEST_ROOT/output")" '无需重新应用' "$1 no-op explanation"
}

test_repeated_set_skips_all_four_backends() (
    local backend
    for backend in plain systemd-resolved openresolv networkmanager; do (
        setup_dns_set_fixture "$backend"
        vps_dns_set >"$DNS_TEST_ROOT/output" 2>&1
        assert_dns_set_applied "$backend first set"
        : >"$DNS_TEST_CALLS"
        vps_dns_set >"$DNS_TEST_ROOT/output" 2>&1
        assert_dns_set_skipped "$backend repeated set"
        [[ "$backend" == networkmanager ]] || assert_contains "$(<"$DNS_TEST_CALLS")" 'writable ' "$backend writable check"
    ); done
)

test_resolved_replaces_inherited_global_servers() (
    local origin file original
    for origin in main dropin; do (
        setup_dns_set_fixture systemd-resolved
        mkdir -p "$DNS_TEST_ROOT/etc/systemd/resolved.conf.d"
        case "$origin" in
            main) file="$DNS_TEST_ROOT/etc/systemd/resolved.conf" ;;
            dropin) file="$DNS_TEST_ROOT/etc/systemd/resolved.conf.d/10-existing.conf" ;;
        esac
        printf '[Resolve]\nDNS=192.0.2.53 2001:db8::54\n' >"$file"
        original="$(<"$file")"
        vps_dns_set >"$DNS_TEST_ROOT/output" 2>&1
        assert_dns_set_applied "resolved $origin inherited servers"
        assert_equal "$(printf '%s\n' "${VPS_DNS_SERVERS[@]}")" "$(<"$DNS_TEST_RUNTIME")" "resolved $origin runtime replaces inherited list"
        assert_equal "$original" "$(<"$file")" "resolved $origin source is preserved"
        : >"$DNS_TEST_CALLS"
        vps_dns_set >"$DNS_TEST_ROOT/output" 2>&1
        assert_dns_set_skipped "resolved $origin repeated set"
    ); done
)

test_file_config_requires_exact_target_content() (
    local backend mismatch file
    for backend in plain systemd-resolved openresolv; do
        for mismatch in order extra; do (
            setup_dns_set_fixture "$backend"
            vps_dns_set >/dev/null
            if [[ "$mismatch" == order ]]; then
                VPS_DNS_SERVERS=(8.8.8.8 1.1.1.1 2001:db8::53)
            else
                case "$backend" in
                    plain) printf 'nameserver 9.9.9.9\n' >>"$DNS_TEST_ROOT/etc/resolv.conf" ;;
                    systemd-resolved) printf 'FallbackDNS=9.9.9.9\n' >>"$DNS_TEST_ROOT/etc/systemd/resolved.conf.d/90-vpsctl-dns.conf" ;;
                    openresolv) printf 'name_servers="9.9.9.9"\n' >>"$DNS_TEST_ROOT/etc/resolvconf.conf" ;;
                esac
            fi
            : >"$DNS_TEST_CALLS"
            vps_dns_set >/dev/null
            assert_dns_set_applied "$backend $mismatch differs"
        ); done
    done
    setup_dns_set_fixture systemd-resolved
    vps_dns_set >/dev/null
    file="$DNS_TEST_ROOT/etc/systemd/resolved.conf.d/90-vpsctl-dns.conf"
    printf '\n\n' >>"$file"
    : >"$DNS_TEST_CALLS"
    vps_dns_set >"$DNS_TEST_ROOT/output" 2>&1
    assert_dns_set_skipped 'trailing newlines'
)

test_file_writers_do_not_commit_failed_generation() (
    local backend file writer status
    for backend in plain systemd-resolved openresolv; do (
        setup_dns_set_fixture "$backend"
        vps_dns_set >/dev/null 2>&1
        case "$backend" in
            plain)
                file="$DNS_TEST_ROOT/etc/resolv.conf" writer=vps_dns_write_plain
                # Called indirectly by the selected file writer.
                # shellcheck disable=SC2317
                vps_dns_plain_content() { printf 'nameserver 9.9.9.9\n'; return 20; }
                ;;
            systemd-resolved)
                file="$DNS_TEST_ROOT/etc/systemd/resolved.conf.d/90-vpsctl-dns.conf" writer=vps_dns_write_resolved
                # Called indirectly by the selected file writer.
                # shellcheck disable=SC2317
                vps_dns_resolved_content() { printf '[Resolve]\nDNS=9.9.9.9\n'; return 20; }
                ;;
            openresolv)
                file="$DNS_TEST_ROOT/etc/resolvconf.conf" writer=vps_dns_write_openresolv
                # Called indirectly by the selected file writer.
                # shellcheck disable=SC2317
                vps_dns_openresolv_content() { printf 'name_servers="9.9.9.9"\n'; return 20; }
                ;;
        esac
        cp -- "$file" "$DNS_TEST_ROOT/original"
        # The selected writer must return before reaching this indirect stub.
        # shellcheck disable=SC2317
        vps_dns_atomic_write() {
            record_dns_call atomic-write "$1"
            cat >"$(vps_dns_path "$1")"
        }
        : >"$DNS_TEST_CALLS"
        status=0
        "$writer" >/dev/null 2>&1 || status=$?
        assert_equal 20 "$status" "$backend generation failure status"
        assert_not_contains "$(<"$DNS_TEST_CALLS")" 'atomic-write ' "$backend failed generation must not call atomic writer"
        cmp -s -- "$DNS_TEST_ROOT/original" "$file" || fail "$backend failed generation changed the old file"
    ); done
)

test_nm_compares_all_target_properties() (
    local index
    local -a properties=(ipv4.dns ipv4.dns ipv4.ignore-auto-dns ipv6.ignore-auto-dns
        ipv4.dns-search ipv6.dns-search ipv4.dns-options ipv6.dns-options ipv6.dns ipv6.dns)
    local -a values=('8.8.8.8,1.1.1.1' '1.1.1.1,8.8.8.8,9.9.9.9' no no
        other.example other.example timeout:2 timeout:2 2001:db8::54 2001:db8:0:0:0:0:0:53)
    for ((index = 0; index < ${#properties[@]}; index++)); do (
        setup_dns_set_fixture networkmanager
        vps_dns_set >/dev/null
        printf '%s\n' "${values[$index]}" >"$DNS_TEST_ROOT/nm/${properties[$index]}"
        : >"$DNS_TEST_CALLS"
        vps_dns_set >/dev/null
        assert_dns_set_applied "NetworkManager ${properties[$index]}=${values[$index]}"
    ); done
)

test_nm_normalizes_tool_lists_and_empty_values() (
    local property
    setup_dns_set_fixture networkmanager
    vps_dns_set >/dev/null
    printf '1.1.1.1,\t8.8.8.8\n' >"$DNS_TEST_ROOT/nm/ipv4.dns"
    printf 'true\n' >"$DNS_TEST_ROOT/nm/ipv4.ignore-auto-dns"
    printf 'on\n' >"$DNS_TEST_ROOT/nm/ipv6.ignore-auto-dns"
    for property in ipv4.dns-search ipv6.dns-search; do printf 'svc.example, corp.example\n' >"$DNS_TEST_ROOT/nm/$property"; done
    for property in ipv4.dns-options ipv6.dns-options; do printf 'rotate, timeout:1\n' >"$DNS_TEST_ROOT/nm/$property"; done
    : >"$DNS_TEST_CALLS"
    vps_dns_set >"$DNS_TEST_ROOT/output" 2>&1
    assert_dns_set_skipped 'NetworkManager tool delimiters'

    setup_dns_set_fixture networkmanager
    printf 'nameserver 192.0.2.53\n' >"$DNS_TEST_ROOT/etc/resolv.conf"
    VPS_DNS_SERVERS=(1.1.1.1)
    vps_dns_set >/dev/null
    for property in ipv6.dns ipv4.dns-search ipv6.dns-search ipv4.dns-options ipv6.dns-options; do
        printf '%s\n' -- >"$DNS_TEST_ROOT/nm/$property"
    done
    : >"$DNS_TEST_CALLS"
    vps_dns_set >"$DNS_TEST_ROOT/output" 2>&1
    assert_dns_set_skipped 'NetworkManager empty properties'
)

test_matching_config_with_runtime_drift_is_reapplied() (
    local backend
    for backend in systemd-resolved openresolv networkmanager; do (
        setup_dns_set_fixture "$backend"
        vps_dns_set >/dev/null
        printf '9.9.9.9\n' >>"$DNS_TEST_RUNTIME"
        if [[ "$backend" == openresolv ]]; then printf 'nameserver 9.9.9.9\n' >>"$DNS_TEST_ROOT/etc/resolv.conf"; fi
        vps_dns_config_matches "$backend" || fail "$backend drift fixture persistent configuration differs"
        : >"$DNS_TEST_CALLS"
        vps_dns_set >/dev/null 2>&1
        assert_dns_set_applied "$backend runtime drift"
    ); done
)

test_matching_config_with_failed_resolution_keeps_status_30() (
    local backend status
    for backend in plain systemd-resolved openresolv networkmanager; do (
        setup_dns_set_fixture "$backend"
        vps_dns_set >/dev/null
        DNS_TEST_RESOLUTION_STATUS=1
        : >"$DNS_TEST_CALLS"
        status=0
        vps_dns_set >/dev/null 2>&1 || status=$?
        assert_equal 30 "$status" "$backend failed verification after reapply"
        assert_dns_set_applied "$backend failed resolution"
        assert_equal 2 "$(grep -c '^resolution$' "$DNS_TEST_CALLS")" "$backend checks before and after apply"
    ); done
)

test_unconfirmed_config_reads_are_reapplied() (
    local backend
    for backend in plain systemd-resolved openresolv networkmanager; do (
        setup_dns_set_fixture "$backend"
        vps_dns_set >/dev/null
        : >"$DNS_TEST_ROOT/fail-read"
        if [[ "$backend" == networkmanager ]]; then
            DNS_TEST_READ_FAILURE=ipv4.dns
        else
            case "$backend" in
                plain) DNS_TEST_COMPARE_FILE="$DNS_TEST_ROOT/etc/resolv.conf" ;;
                systemd-resolved) DNS_TEST_COMPARE_FILE="$DNS_TEST_ROOT/etc/systemd/resolved.conf.d/90-vpsctl-dns.conf" ;;
                openresolv) DNS_TEST_COMPARE_FILE="$DNS_TEST_ROOT/etc/resolvconf.conf" ;;
            esac
            # Called indirectly while comparing the backend configuration.
            # shellcheck disable=SC2317
            cat() {
                if [[ "${1:-}" == -- && "${2:-}" == "$DNS_TEST_COMPARE_FILE" && -f "$DNS_TEST_ROOT/fail-read" ]]; then
                    command cat "$@"
                    rm -- "$DNS_TEST_ROOT/fail-read"
                    return 20
                fi
                command cat "$@"
            }
        fi
        : >"$DNS_TEST_CALLS"
        vps_dns_set >/dev/null
        assert_dns_set_applied "$backend inconclusive read"
        [[ ! -e "$DNS_TEST_ROOT/fail-read" ]] || fail "$backend comparison did not attempt the failing read"
    ); done
)

test_set_preapply_errors_keep_status_20() (
    local failure status
    for failure in backup write; do (
        setup_dns_set_fixture plain
        if [[ "$failure" == backup ]]; then DNS_TEST_BACKUP_STATUS=20; else DNS_TEST_WRITE_STATUS=20; fi
        status=0
        vps_dns_set >/dev/null 2>&1 || status=$?
        assert_equal 20 "$status" "$failure failure before apply completes"
        assert_not_contains "$(<"$DNS_TEST_CALLS")" 'run ' "$failure failure does not refresh"
        assert_not_contains "$(<"$DNS_TEST_CALLS")" 'resolution' "$failure failure does not verify"
    ); done
)

test_matching_config_dry_run_keeps_original_plan() (
    local backend output
    for backend in plain systemd-resolved openresolv networkmanager; do (
        setup_dns_set_fixture "$backend"
        vps_dns_set >/dev/null
        : >"$DNS_TEST_CALLS"
        VPSCTL_DRY_RUN=1
        output="$(vps_dns_set 2>&1)"
        assert_contains "$output" 'flush-caches' "$backend dry-run refresh plan"
        if [[ "$backend" == networkmanager ]]; then
            assert_contains "$output" 'connection modify' "$backend dry-run write plan"
        else
            assert_contains "$output" '将替换' "$backend dry-run write plan"
        fi
        assert_not_contains "$output" '无需重新应用' "$backend dry-run does not short-circuit"
        assert_not_contains "$(<"$DNS_TEST_CALLS")" 'backup ' "$backend dry-run does not back up"
        assert_not_contains "$(<"$DNS_TEST_CALLS")" 'lock ' "$backend dry-run does not lock"
        assert_not_contains "$(<"$DNS_TEST_CALLS")" 'write ' "$backend dry-run does not write"
        assert_not_contains "$(<"$DNS_TEST_CALLS")" 'resolution' "$backend dry-run does not verify"
    ); done
)

test_alpine_plain_dhcp_refusal() (
    local before status=0

    mkdir -p "$TEST_SYSTEM_ROOT/etc/network"
    printf 'auto eth0\niface eth0 inet dhcp\n' >"$TEST_SYSTEM_ROOT/etc/network/interfaces"
    before="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    VPSCTL_ENV_OS_ID=alpine
    VPS_DNS_SERVERS=(1.1.1.1)
    vps_dns_test_candidates() { return 0; }
    vps_cmd_confirm() { return 0; }
    vps_cmd_require_root() { return 0; }
    vps_dns_detect_backend() { VPS_DNS_BACKEND=plain; }
    vps_dns_set >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" "Alpine DHCP plain backend refusal"
    assert_equal "$before" "$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")" "Alpine DHCP refusal zero write"

    mkdir -p "$TEST_SYSTEM_ROOT/etc/udhcpc"
    printf 'RESOLV_CONF="no"\n' >"$TEST_SYSTEM_ROOT/etc/udhcpc/udhcpc.conf"
    ! vps_dns_alpine_plain_dhcp_conflict plain || fail "Alpine RESOLV_CONF=no should permit static DNS"

    mkdir -p "$TEST_SYSTEM_ROOT/run"
    : >"$TEST_SYSTEM_ROOT/run/dhcpcd.pid"
    vps_dns_alpine_plain_dhcp_conflict plain || fail "udhcpc setting must not bypass active dhcpcd"
    printf 'nohook hostname resolv.conf\n' >"$TEST_SYSTEM_ROOT/etc/dhcpcd.conf"
    ! vps_dns_alpine_plain_dhcp_conflict plain || fail "dhcpcd nohook resolv.conf should permit static DNS"
)

test_legacy_resolvconf_refusal() {
    local before after status
    mkdir -p "$TEST_SYSTEM_ROOT/etc/resolvconf/run"
    resolvconf() { [[ "${1:-}" == --version ]] && printf 'Debian resolvconf 1.91\n'; }
    dig() { mock_dig_answer; }
    VPS_DNS_SERVERS=(8.8.8.8)
    VPS_DNS_TEST_DOMAIN=example.com
    before="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    if vps_dns_set; then status=0; else status=$?; fi
    assert_equal 3 "$status" "legacy resolvconf refusal status"
    after="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_equal "$before" "$after" "legacy resolvconf refusal must not write"
}

test_post_verify_failure_retains_change_and_restore() {
    local status content original
    rmdir "$TEST_SYSTEM_ROOT/etc/resolvconf/run"
    rmdir "$TEST_SYSTEM_ROOT/etc/resolvconf"
    original=$'search before.example\noptions rotate\nnameserver 192.0.2.44'
    printf '%s\n' "$original" >"$TEST_SYSTEM_ROOT/etc/resolv.conf"

    vps_dns_detect_backend() {
        VPS_DNS_BACKEND=plain
        VPS_DNS_NM_CONNECTION=""
        VPS_DNS_NM_DEVICE=""
    }
    vps_dns_refresh_backend() { return 0; }
    vps_cmd_lock() { return 0; }
    vps_cmd_unlock() { return 0; }
    dig() { mock_dig_answer; }
    getent() { return 1; }
    VPS_DNS_SERVERS=(1.0.0.1)
    VPS_DNS_TEST_DOMAIN=example.com
    if vps_dns_set; then status=0; else status=$?; fi
    assert_equal 30 "$status" "post-change verify failure status"
    content="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_contains "$content" 'nameserver 1.0.0.1' "failed verification must retain new DNS"
    assert_not_contains "$content" 'nameserver 192.0.2.44' "failed verification must not auto-rollback"

    vps_dns_restore
    content="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_contains "$content" 'nameserver 192.0.2.44' "restore latest backup"
    assert_contains "$content" 'search before.example' "restore preserved search"
}

test_dry_run_does_not_write() {
    local before after lock_calls=0 backup_calls=0
    before="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    VPSCTL_DRY_RUN=1
    VPS_DNS_SERVERS=(9.9.9.9)
    VPS_DNS_TEST_DOMAIN=example.com
    vps_cmd_lock() { lock_calls=$((lock_calls + 1)); }
    vps_dns_backup_current() { backup_calls=$((backup_calls + 1)); }
    vps_dns_set
    VPSCTL_DRY_RUN=0
    after="$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")"
    assert_equal "$before" "$after" "dry-run must not write DNS configuration"
    assert_equal 0 "$lock_calls" "dry-run lock creation"
    assert_equal 0 "$backup_calls" "dry-run backup creation"
}

test_verify_rejects_extra_upstream() {
    local status
    VPS_DNS_SERVERS=(1.1.1.1)
    vps_dns_effective_servers() { printf '1.1.1.1\n8.8.8.8\n127.0.0.53\n'; }
    if vps_dns_verify_servers; then status=0; else status=$?; fi
    [[ "$status" != 0 ]] || fail "unexpected non-loopback upstream was accepted"
}

test_explicit_restore_is_confined() {
    local outside status
    outside="$TEST_SYSTEM_ROOT/outside-backup"
    printf 'nameserver 203.0.113.53\n' >"$outside"
    if vps_dns_restore --backup "$outside"; then status=0; else status=$?; fi
    assert_equal 10 "$status" "explicit restore backup confinement"
}

test_nm_refresh_reapplies_device() (
    local calls=""
    VPS_DNS_NM_CONNECTION=primary
    VPS_DNS_NM_DEVICE=eth0
    vps_cmd_run() {
        local IFS=' '
        calls+="$*"$'\n'
    }
    vps_dns_refresh_backend networkmanager
    assert_contains "$calls" 'nmcli connection reload' "NetworkManager reload"
    assert_contains "$calls" 'nmcli device reapply eth0' "NetworkManager device reapply"
    assert_not_contains "$calls" 'connection up' "NetworkManager must not reconnect"
)

test_nm_effective_servers_are_runtime_values() {
    local output

    output="$(
        VPS_DNS_BACKEND=networkmanager
        vps_dns_resolv_link_owner() { printf 'regular\n'; }
        nmcli() {
            [[ "$*" == *'IP4.DNS,IP6.DNS device show'* ]] || return 1
            printf '1.1.1.1\n2606:4700:4700::1111\n'
        }
        vps_dns_effective_servers
    )"
    assert_contains "$output" '1.1.1.1' "NetworkManager active IPv4 server"
    assert_contains "$output" '2606:4700:4700::1111' "NetworkManager active IPv6 server"
}

test_read_only_target_rejected() {
    local status
    findmnt() { printf 'ro,relatime\n'; }
    if vps_dns_require_writable_target /etc/resolv.conf; then status=0; else status=$?; fi
    assert_equal 3 "$status" "read-only mount rejection"
    unset -f findmnt
}

test_managed_ancestor_symlink_rejected() {
    local etc_path="$TEST_SYSTEM_ROOT/etc"
    local saved_etc="$TEST_SYSTEM_ROOT/etc.saved"
    local outside_etc="$TEST_SYSTEM_ROOT/../outside-dns-etc"
    local status=0

    mv -- "$etc_path" "$saved_etc"
    mkdir -p -- "$outside_etc"
    if ln -s "$outside_etc" "$etc_path" 2>/dev/null && [[ -L "$etc_path" ]]; then
        vps_dns_require_writable_target /etc/resolv.conf >/dev/null 2>&1 || status=$?
        assert_equal 3 "$status" "managed DNS ancestor symlink rejection"
        [[ ! -e "$outside_etc/resolv.conf" ]] || fail "DNS path escaped through an ancestor symlink"
        unlink -- "$etc_path" 2>/dev/null || rmdir -- "$etc_path"
    elif [[ -e "$etc_path" || -L "$etc_path" ]]; then
        unlink -- "$etc_path" 2>/dev/null || rmdir -- "$etc_path"
    fi
    mv -- "$saved_etc" "$etc_path"
}

test_refresh_failure_after_write_returns_30() {
    local status
    VPSCTL_DRY_RUN=0
    VPS_DNS_SERVERS=(4.4.4.4)
    VPS_DNS_TEST_DOMAIN=example.com
    dig() { mock_dig_answer; }
    vps_dns_detect_backend() {
        VPS_DNS_BACKEND=plain
        VPS_DNS_NM_CONNECTION=""
        VPS_DNS_NM_DEVICE=""
    }
    vps_dns_refresh_backend() { return 20; }
    vps_cmd_lock() { return 0; }
    vps_cmd_unlock() { return 0; }
    vps_dns_backup_current() { return 0; }
    if vps_dns_set; then status=0; else status=$?; fi
    assert_equal 30 "$status" "refresh failure after write"
    assert_contains "$(<"$TEST_SYSTEM_ROOT/etc/resolv.conf")" 'nameserver 4.4.4.4' "refresh failure retains write"
}

test_restore_metadata_trust_boundary() {
    local root missing outside status
    root="$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/network/dns"
    mkdir -p "$root/missing-meta"
    missing="$root/missing-meta/resolv.conf"
    printf 'nameserver 1.1.1.1\n' >"$missing"
    if vps_dns_restore --backup "$missing"; then status=0; else status=$?; fi
    assert_equal 10 "$status" "explicit backup without metadata"
    outside="$TEST_SYSTEM_ROOT/forged-backup"
    printf 'nameserver 8.8.8.8\n' >"$outside"
    printf 'backup=%s\n' "$outside" >"$root/latest"
    if vps_dns_restore; then status=0; else status=$?; fi
    assert_equal 10 "$status" "forged latest backup escape"
}

test_nm_restore_rejects_unknown_property() {
    local dir backup status
    dir="$TEST_SYSTEM_ROOT/var/lib/vpsctl/backups/network/dns/nm-forged"
    mkdir -p "$dir"
    backup="$dir/.current-state"
    {
        printf 'connection=primary\ndevice=eth0\n'
        printf 'ipv4.gateway=192.0.2.1\n'
    } >"$backup"
    {
        printf 'backend=networkmanager\nkind=networkmanager\ntarget=@networkmanager\nbackup=%s\n' "$backup"
    } >"$dir/metadata"
    vps_dns_detect_backend() {
        VPS_DNS_BACKEND=networkmanager
        VPS_DNS_NM_CONNECTION=primary
        VPS_DNS_NM_DEVICE=eth0
    }
    if vps_dns_restore --backup "$backup"; then status=0; else status=$?; fi
    assert_equal 10 "$status" "unknown NetworkManager restore property"
}

test_address_validation
test_dns_answer_records_required
test_lookup_answer_addresses
test_query_server_routing_and_ipv6_retry
test_system_resolution_routes
test_standalone_globals
test_shared_dependency_handling
test_dry_run_dependency_and_dns_plan
test_interactive_menu_inputs
test_backend_detection
test_preflight_failure_does_not_write
test_plain_replacement_preserves_directives
test_openresolv_replacement
test_repeated_set_skips_all_four_backends
test_resolved_replaces_inherited_global_servers
test_file_config_requires_exact_target_content
test_file_writers_do_not_commit_failed_generation
test_nm_compares_all_target_properties
test_nm_normalizes_tool_lists_and_empty_values
test_matching_config_with_runtime_drift_is_reapplied
test_matching_config_with_failed_resolution_keeps_status_30
test_unconfirmed_config_reads_are_reapplied
test_set_preapply_errors_keep_status_20
test_matching_config_dry_run_keeps_original_plan
test_alpine_plain_dhcp_refusal
test_nm_refresh_reapplies_device
test_nm_effective_servers_are_runtime_values
test_read_only_target_rejected
test_managed_ancestor_symlink_rejected
test_legacy_resolvconf_refusal
test_post_verify_failure_retains_change_and_restore
test_dry_run_does_not_write
test_verify_rejects_extra_upstream
test_explicit_restore_is_confined
test_refresh_failure_after_write_returns_30
test_restore_metadata_trust_boundary
test_nm_restore_rejects_unknown_property
test_chinese_status_without_ansi
printf 'PASS: network DNS tests\n'
