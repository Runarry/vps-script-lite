#!/usr/bin/env bash
# Focused CLI and orchestration tests; native deletion is replaced at one boundary.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
TEST_CASE=0
trap 'if [[ "${VPSCTL_TEST_KEEP_TEMP:-0}" == 1 ]]; then printf "Fixture evidence: %s\n" "$TEST_TEMP"; else command rm -rf -- "$TEST_TEMP"; fi' EXIT
export VPSCTL_TESTING=1 VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1
export VPSCTL_ASSUME_YES=1 VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0
# shellcheck source=../../commands/system/clean.sh
source "$TEST_ROOT/commands/system/clean.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
excludes() { [[ "$1" != *"$2"* ]] || fail "$3: unexpected '$2'"; }
event() { printf '%s\n' "$*" >>"$VPSCTL_SYSTEM_ROOT/events"; }
events() { cat "$VPSCTL_SYSTEM_ROOT/events"; }
count_event() {
    local count
    count="$(grep -c "^$1" "$VPSCTL_SYSTEM_ROOT/events" || true)"
    printf '%s' "$count"
}
invoke() {
    STATUS=0
    OUTPUT="$(clean_main "$@" 2>&1)" || STATUS=$?
}
new_case() {
    TEST_CASE=$((TEST_CASE + 1))
    export VPSCTL_SYSTEM_ROOT="$TEST_TEMP/case-$TEST_CASE"
    mkdir -p "$VPSCTL_SYSTEM_ROOT"/{etc,run,var,tmp}
    printf 'protected settings\n' >"$VPSCTL_SYSTEM_ROOT/etc/sentinel"
    printf 'disposable cache\n' >"$VPSCTL_SYSTEM_ROOT/candidate"
    : >"$VPSCTL_SYSTEM_ROOT/events"
    VPSCTL_DRY_RUN=0 VPSCTL_ASSUME_YES=1 VPSCTL_INSTALL_DEPS=0
    VPSCTL_NON_INTERACTIVE=1 VPSCTL_DISTRIBUTED=1 VPSCTL_QUIET=0 VPSCTL_VERBOSE=0
    MOCK_MANAGER=apt-get MOCK_FAIL='' MOCK_DENY_ROOT=0 MOCK_INTERACTIVE=0
    MOCK_MISSING='' MOCK_TEMP_HELP=1 MOCK_SELF_STATUS=0 MOCK_CONFIRM_STATUS=0
    MOCK_TEMP_CONFIG_STATUS=0
    MOCK_TEMP_CONFIG=$'d /tmp 1777 root root 10d\nd /var/tmp 1777 root root 30d\nd "/tmp/plain path" 0700 root root 5s\ne /tmp/vpsctl-work.* - - - 1s\ne /var/tmp/vpsctl-work.*/nested - - - 1s'
}

eval "$(declare -f vps_cmd_confirm | sed '1s/vps_cmd_confirm/test_real_confirm/')"
eval "$(declare -f vps_cmd_ensure_tools | sed '1s/vps_cmd_ensure_tools/test_real_ensure_tools/')"
vps_cmd_confirm() {
    event confirm
    test_real_confirm "$@"
}
vps_cmd_ensure_tools() {
    event "ensure:$*"
    test_real_ensure_tools "$@"
}
vps_cmd_is_interactive() { [[ "$MOCK_INTERACTIVE" == 1 ]]; }
vps_cmd_require_root() {
    event root
    [[ "$MOCK_DENY_ROOT" == 0 ]] || return 4
}
vps_cmd_detect_package_manager() { printf '%s' "$MOCK_MANAGER"; }
command() {
    if [[ "${1:-}" == -v && "${2:-}" == "$MOCK_MISSING" ]]; then return 1; fi
    builtin command "$@"
}
systemd-tmpfiles() {
    case "${1:-}" in
        --help) [[ "$MOCK_TEMP_HELP" == 1 ]] && printf '%s\n' '--clean --prefix --replace --cat-config --no-pager' || printf '%s\n' '--clean' ;;
        --cat-config)
            event config-read
            [[ "$MOCK_TEMP_CONFIG_STATUS" == 0 ]] || return "$MOCK_TEMP_CONFIG_STATUS"
            printf '%s\n' "$MOCK_TEMP_CONFIG"
            ;;
        *) fail 'native tmpfiles escaped its execution boundary' ;;
    esac
}
journalctl() {
    [[ "${1:-}" == --disk-usage ]] || fail 'native journal escaped its execution boundary'
    printf 'Archived and active journals take up 1M.\n'
}
clean_load_distribution() { :; }
vps_distribution_clean_residue() {
    event "residue:$VPSCTL_DRY_RUN"
    [[ "$MOCK_SELF_STATUS" == 0 ]] || return "$MOCK_SELF_STATUS"
    [[ "$VPSCTL_DRY_RUN" == 1 ]] || rm -f -- "$VPSCTL_SYSTEM_ROOT/candidate"
    return 0
}
vps_distribution_clean_bundles() { event "bundles:$VPSCTL_DRY_RUN"; }
clean_run_native() {
    local arguments argument
    arguments="$#"
    for argument in "$@"; do arguments+="|$argument"; done
    event "native:$arguments"
    if [[ "$1" == systemd-tmpfiles ]]; then
        cat >"$VPSCTL_SYSTEM_ROOT/tmpfiles.stdin"
    fi
    [[ "$MOCK_FAIL" != "$1" ]] || return 77
    rm -f -- "$VPSCTL_SYSTEM_ROOT/candidate"
}
clean_free_kib() { printf '1024\n'; }

test_readonly_and_validation() {
    local argument
    for argument in nonsense --unknown '--yes=1'; do
        new_case
        invoke "$argument"
        equal 2 "$STATUS" 'invalid action or option'
        equal '' "$(events)" 'invalid arguments must not enter mutation'
    done
    new_case
    invoke packages extra
    equal 2 "$STATUS" 'extra positional argument'
    equal '' "$(events)" 'extra argument rejected before preview or execution'
    for argument in '' status help --help; do
        new_case
        MOCK_DENY_ROOT=1
        if [[ -n "$argument" ]]; then invoke "$argument"; else invoke; fi
        equal 0 "$STATUS" 'rootless status/help/default'
        equal '' "$(events)" 'status and help have no mutation boundary calls'
        [[ ! -e "$VPSCTL_SYSTEM_ROOT/run/vpsctl" ]] || fail 'status created lock directory'
    done
    new_case
    MOCK_DENY_ROOT=1
    invoke packages
    equal 4 "$STATUS" 'real execution requires root'
    equal root "$(events)" 'root refusal precedes preview/confirmation/destructive execution'
    [[ -f "$VPSCTL_SYSTEM_ROOT/candidate" ]] || fail 'root refusal lost candidate'
    for argument in safe bundles journal; do
        new_case
        MOCK_DENY_ROOT=1 VPSCTL_ASSUME_YES=0
        MOCK_MISSING=flock
        invoke --dry-run --install-deps "$argument"
        equal 0 "$STATUS" 'dry run bypasses mutation prerequisites'
        excludes "$(events)" root 'dry run root requirement'
        excludes "$(events)" confirm 'dry run confirmation'
        excludes "$(events)" native: 'dry run native execution'
        excludes "$(events)" ensure: 'dry run dependency processing'
        excludes "$(events)" ':0' 'dry run distribution mutation'
        [[ ! -e "$VPSCTL_SYSTEM_ROOT/run/vpsctl" ]] || fail 'dry run created lock directory'
        [[ -f "$VPSCTL_SYSTEM_ROOT/candidate" ]] || fail 'dry run removed candidate'
    done
    printf 'PASS: invalid arguments, rootless readonly actions, root refusal, zero-write previews\n'
}

test_confirmation() {
    new_case
    VPSCTL_ASSUME_YES=0
    invoke packages
    equal 3 "$STATUS" 'noninteractive confirmation requires authorization'
    equal 1 "$(count_event confirm)" 'one noninteractive confirmation attempt'
    excludes "$(events)" native: 'unapproved noninteractive execution'
    [[ ! -e "$VPSCTL_SYSTEM_ROOT/run/vpsctl" ]] || fail 'unapproved operation created lock'
    new_case
    VPSCTL_ASSUME_YES=0 MOCK_INTERACTIVE=1
    invoke packages <<<''
    equal 130 "$STATUS" 'empty interactive answer defaults to no'
    excludes "$(events)" native: 'default-no operation ran'
    [[ -f "$VPSCTL_SYSTEM_ROOT/candidate" ]] || fail 'default-no lost candidate'
    new_case
    VPSCTL_ASSUME_YES=0 MOCK_INTERACTIVE=1
    invoke safe <<<'y'
    equal 0 "$STATUS" 'one yes authorizes composite safe operation'
    equal 1 "$(count_event confirm)" 'safe asks once'
    equal 2 "$(count_event native:)" 'safe executed packages and temp'
    contains "$(events)" residue:0 'safe executes residue'
    excludes "$(events)" bundles: 'safe excludes bundles'
    excludes "$(events)" journalctl 'safe excludes journal'
    contains "$OUTPUT" '成功 3 项' 'safe aggregate summary'
    contains "$OUTPUT" '可用空间变化' 'disk observation reported'
    [[ ! -e "$VPSCTL_SYSTEM_ROOT/candidate" ]] || fail 'approved clean did not change fixture'
    equal 'protected settings' "$(cat "$VPSCTL_SYSTEM_ROOT/etc/sentinel")" 'protected settings retained'
    printf 'PASS: default-no, noninteractive authorization, single confirmation for safe, protected data\n'
}

test_package_backends() {
    local manager expected
    for manager in apt-get dnf5 dnf yum apk pacman zypper; do
        new_case
        MOCK_MANAGER="$manager"
        mkdir -p -- "$VPSCTL_SYSTEM_ROOT/etc/apk/cache"
        case "$manager" in
            apt-get) expected='native:2|apt-get|clean' ;;
            dnf5 | dnf | yum) expected="native:3|$manager|clean|packages" ;;
            apk) expected='native:4|apk|--no-network|cache|clean' ;;
            pacman) expected='native:3|pacman|--noconfirm|-Sc' ;;
            zypper) expected='native:3|zypper|--non-interactive|clean' ;;
        esac
        invoke packages
        equal 0 "$STATUS" "backend $manager"
        contains "$(events)" "$expected" "native backend arguments $manager"
        equal 1 "$(count_event native:)" "backend $manager called only once"
        [[ ! -e "$VPSCTL_SYSTEM_ROOT/candidate" ]] || fail "backend $manager did not execute"
        invoke packages
        equal 0 "$STATUS" "backend $manager repeated empty clean"
    done
    new_case
    MOCK_MANAGER=apk
    invoke packages
    equal 0 "$STATUS" 'inactive APK cache is successful no-op'
    equal 0 "$(count_event native:)" 'inactive APK cache does not call apk'
    [[ -f "$VPSCTL_SYSTEM_ROOT/candidate" ]] || fail 'inactive APK removed fixture'
    new_case
    MOCK_MANAGER=unknown
    invoke packages
    equal 3 "$STATUS" 'unknown package manager explicit refusal'
    equal 0 "$(count_event confirm)" 'unavailable action no confirmation'
    printf 'PASS: all seven native backend argument arrays, repeated empty, inactive APK, unknown backend\n'
}

test_native_scope_and_availability() {
    new_case
    invoke temp
    equal 0 "$STATUS" 'temp execution'
    contains "$(events)" 'native:5|systemd-tmpfiles|--clean|--prefix=/tmp|--prefix=/var/tmp|-' 'tmpfiles limited command and stdin'
    contains "$(cat "$VPSCTL_SYSTEM_ROOT/tmpfiles.stdin")" 'd /tmp 1777 root root 10d' 'native parent aging rule retained'
    contains "$(cat "$VPSCTL_SYSTEM_ROOT/tmpfiles.stdin")" 'd "/tmp/plain path" 0700 root root 5s' 'unrelated quoted native rule retained'
    contains "$(cat "$VPSCTL_SYSTEM_ROOT/tmpfiles.stdin")" 'x /tmp/vpsctl*' 'transient tmp exclusion'
    contains "$(cat "$VPSCTL_SYSTEM_ROOT/tmpfiles.stdin")" 'x /var/tmp/vpsctl*' 'transient var tmp exclusion'
    excludes "$(cat "$VPSCTL_SYSTEM_ROOT/tmpfiles.stdin")" 'e /tmp/vpsctl-work.*' 'explicit protected glob cannot clean'
    excludes "$(cat "$VPSCTL_SYSTEM_ROOT/tmpfiles.stdin")" 'e /var/tmp/vpsctl-work.*/nested' 'protected nested glob cannot clean'
    [[ ! -e "$VPSCTL_SYSTEM_ROOT/run/tmpfiles.d" ]] || fail 'temp created persistent rule'
    new_case
    MOCK_TEMP_CONFIG_STATUS=42
    invoke temp
    [[ "$STATUS" != 0 ]] || fail 'unreadable native rules unexpectedly accepted'
    equal 0 "$(count_event native:)" 'rule reader failure must not run cleanup'
    [[ -f "$VPSCTL_SYSTEM_ROOT/candidate" ]] || fail 'failed rule reader lost candidate'
    new_case
    invoke journal
    equal 0 "$STATUS" 'journal execution'
    contains "$(events)" 'native:2|journalctl|--vacuum-time=30d' 'fixed journal retention'
    equal 1 "$(count_event native:)" 'journal does not rotate first'
    new_case
    MOCK_MISSING=journalctl
    invoke journal
    equal 3 "$STATUS" 'missing journal helper explicit refusal'
    equal 0 "$(count_event native:)" 'missing journal no destructive call'
    new_case
    MOCK_TEMP_HELP=0
    invoke temp
    equal 3 "$STATUS" 'unsupported tmpfiles flags explicit refusal'
    equal 0 "$(count_event native:)" 'unsupported tmpfiles no destructive call'
    new_case
    VPSCTL_DISTRIBUTED=0 MOCK_MANAGER=unknown MOCK_MISSING=systemd-tmpfiles
    invoke safe
    equal 3 "$STATUS" 'safe with no supported action reports unavailable'
    excludes "$(events)" native: 'safe unavailable capabilities skipped'
    excludes "$(events)" residue: 'safe source mode skips residue'
    excludes "$(events)" confirm 'nothing available requires no confirmation'
    contains "$OUTPUT" '跳过' 'unavailable capabilities explained'
    contains "$OUTPUT" '成功 0 项，跳过 3 项，失败/未完成 0 项' 'no-ready summary does not invent a failed item'
    new_case
    VPSCTL_DISTRIBUTED=0 MOCK_MISSING=systemd-tmpfiles
    invoke safe
    equal 0 "$STATUS" 'safe skips unsupported source and tmpfiles'
    contains "$OUTPUT" '成功 1 项，跳过 2 项' 'skip summary'
    equal 1 "$(count_event native:)" 'only available safe item executed'
    printf 'PASS: bounded tmpfiles stdin rules, fixed journal policy, unavailable native capabilities, safe skips\n'
}

test_failures() {
    new_case
    MOCK_FAIL=apt-get
    invoke packages
    equal 20 "$STATUS" 'external failure mapped to 20'
    contains "$OUTPUT" '失败/未完成 1 项' 'failed item summary'
    new_case
    MOCK_FAIL=apt-get
    invoke safe
    equal 30 "$STATUS" 'composite partial failure'
    contains "$OUTPUT" '成功 2 项' 'independent safe items continue after failure'
    contains "$OUTPUT" '失败/未完成 1 项' 'partial failure item summary'
    contains "$(events)" 'systemd-tmpfiles' 'temp still attempted after package failure'
    new_case
    MOCK_SELF_STATUS=30
    invoke vpsctl
    equal 30 "$STATUS" 'distribution partial status retained'
    new_case
    VPSCTL_DRY_RUN=1 MOCK_SELF_STATUS=30
    invoke vpsctl
    equal 30 "$STATUS" 'partially blocked distribution preview stays nonzero'
    excludes "$(events)" 'residue:0' 'partial preview never executes cleanup'
    excludes "$(events)" confirm 'partial preview does not prompt'
    printf 'PASS: external error, partial composite completion, distribution partial result\n'
}

test_readonly_and_validation
test_confirmation
test_package_backends
test_native_scope_and_availability
test_failures
printf 'PASS: system clean unit tests\n'
