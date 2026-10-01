#!/usr/bin/env bash
# Isolated transaction tests: none of these fixtures may touch host swap.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
TEST_CASE=0
ENTRY="$TEST_ROOT/commands/system/swap.sh"
trap 'if [[ "${VPSCTL_TEST_KEEP_TEMP:-0}" == 1 ]]; then printf "Fixture evidence: %s\n" "$TEST_TEMP"; else command rm -rf -- "$TEST_TEMP"; fi' EXIT
export VPSCTL_TESTING=1 VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1
export VPSCTL_ASSUME_YES=1 VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0
# shellcheck source=../../commands/system/swap.sh
source "$ENTRY"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected path: $1"; }
present() { [[ -e "$1" ]] || fail "missing path: $1"; }
fixture_path() { [[ "$1" == "$VPSCTL_SYSTEM_ROOT/"* ]] || fail "mock refused host path: $1"; }
event() { printf '%s\n' "$*" >>"$VPSCTL_SYSTEM_ROOT/events"; }

new_case() {
    TEST_CASE=$((TEST_CASE + 1))
    export VPSCTL_SYSTEM_ROOT="$TEST_TEMP/case-$TEST_CASE"
    mkdir -p "$VPSCTL_SYSTEM_ROOT"/{proc,etc,dev,run/systemd/system,sys/block}
    printf 'MemTotal:       1048576 kB\nMemAvailable:   16777216 kB\n' >"$VPSCTL_SYSTEM_ROOT/proc/meminfo"
    printf 'Filename\tType\tSize\tUsed\tPriority\n' >"$VPSCTL_SYSTEM_ROOT/proc/swaps"
    printf '# retained header\nUUID=root / ext4 defaults 0 1\n' >"$VPSCTL_SYSTEM_ROOT/etc/fstab"
    : >"$VPSCTL_SYSTEM_ROOT/active"
    : >"$VPSCTL_SYSTEM_ROOT/events"
    VPSCTL_DRY_RUN=0 VPSCTL_ASSUME_YES=1 VPSCTL_INSTALL_DEPS=0
    VPSCTL_ENV_INIT=systemd
    MOCK_FAIL='' MOCK_SPACE=34359738368 MOCK_FSTYPE=ext4
    MOCK_TAMPER='' MOCK_UNIT='' MOCK_MISSING='' MOCK_DENY_ROOT=0 MOCK_TARGET_MASK=0
}

invoke() {
    STATUS=0
    # A fresh subshell gives each public call its own CLI and transaction state.
    OUTPUT="$(swap_main "$@" 2>&1)" || STATUS=$?
}

test_sizes() {
    local value status
    equal 1073741824 "$(swap_size_bytes auto 1)" 'auto lower clamp'
    equal 1073741824 "$(swap_size_bytes auto 524288)" 'auto exact 1GiB'
    equal 2147483648 "$(swap_size_bytes auto 524289)" 'auto rounds upwards'
    equal 6442450944 "$(swap_size_bytes auto 2621441)" 'auto rounds fractional RAM'
    equal 8589934592 "$(swap_size_bytes auto 16777216)" 'auto upper clamp'
    equal 67108864 "$(swap_size_bytes 64M)" 'minimum MiB accepted'
    equal 1073741824 "$(swap_size_bytes 1G)" 'GiB accepted'
    for value in 0 0M 63M 1T 1.5G -1G '+1G' '1 G' '1Gextra' 9223372036854775808G 999999999999999999999999M; do
        status=0
        swap_size_bytes "$value" >"$TEST_TEMP/size-output" 2>&1 || status=$?
        equal 2 "$status" "invalid size $value"
    done
    printf 'PASS: swap sizes\n'
}

test_fstab_escapes() {
    local path='/swap dir/file\name'
    equal "$path" "$(swap_fstab_decode "$(swap_fstab_encode "$path")")" 'fstab whitespace and backslash round trip'
    equal '/swap file' "$(swap_fstab_decode '/swap\040file')" 'fstab octal space'
    printf 'PASS: swap fstab escaping\n'
}

# Preserve the real shared writer; failures below are injected at its boundary.
eval "$(declare -f vps_cmd_atomic_write | sed '1s/vps_cmd_atomic_write/test_real_atomic_write/')"
eval "$(declare -f vps_cmd_require_root | sed '1s/vps_cmd_require_root/test_real_require_root/')"
eval "$(declare -f _vps_cmd_tool_available | sed '1s/_vps_cmd_tool_available/test_real_tool_available/')"
vps_cmd_require_root() {
    [[ "$MOCK_DENY_ROOT" != 1 ]] || return 4
    test_real_require_root
}
_vps_cmd_tool_available() {
    [[ "$1" != "$MOCK_MISSING" ]] || return 1
    test_real_tool_available "$@"
}
vps_cmd_atomic_write() {
    if [[ "$1" == /etc/fstab ]]; then
        event config
        if [[ "$MOCK_FAIL" == config && ! -e "$VPSCTL_SYSTEM_ROOT/failed-config" ]]; then
            : >"$VPSCTL_SYSTEM_ROOT/failed-config"
            cat >/dev/null
            return 20
        fi
    fi
    if [[ "$1" == /etc/conf.d/swap ]]; then
        event openrc-config
        if [[ "$MOCK_FAIL" == openrc-restore && -e "$VPSCTL_SYSTEM_ROOT/failed-openrc-refresh" ]]; then
            cat >/dev/null
            return 20
        fi
        if [[ "$MOCK_FAIL" == openrc-config && ! -e "$VPSCTL_SYSTEM_ROOT/failed-openrc-config" ]]; then
            : >"$VPSCTL_SYSTEM_ROOT/failed-openrc-config"
            cat >/dev/null
            return 20
        fi
    fi
    test_real_atomic_write "$@"
}
apt-get() {
    event "install $*"
    return 99
}
dd() {
    local argument destination='' bytes=0 count=0
    if [[ "${1:-}" == --help ]]; then
        printf 'fsync status=\n'
        return 0
    fi
    for argument in "$@"; do
        case "$argument" in
            of=*) destination="${argument#of=}" ;;
            bs=*) bytes="${argument#bs=}" ;;
            count=*) count="${argument#count=}" ;;
        esac
    done
    fixture_path "$destination"
    event "dd $destination"
    if [[ "$MOCK_FAIL" == dd ]]; then
        printf 'partial' >"$destination"
        return 1
    fi
    case "$bytes" in *M) bytes=$((${bytes%M} * 1048576)) ;; *G) bytes=$((${bytes%G} * 1073741824)) ;; esac
    command truncate -s "$((bytes * count))" "$destination"
}
mkswap() {
    local path="${*: -1}"
    if [[ "${1:-}" == --version ]]; then
        printf 'mkswap from util-linux 2.40\n'
        return 0
    fi
    fixture_path "$path"
    event "mkswap $path"
    [[ "$MOCK_FAIL" != mkswap ]] || return 1
    printf swap >"${path}.signature"
}
swapon() {
    local path="${*: -1}" size type=file
    if [[ "${1:-}" == --help ]]; then
        printf '%s\n' '--show --bytes --raw'
        return 0
    fi
    if [[ "${1:-}" == --version ]]; then
        printf 'swapon from util-linux 2.40\n'
        return 0
    fi
    if [[ " $* " == *' --show'* ]]; then
        cat "$VPSCTL_SYSTEM_ROOT/active"
        return 0
    fi
    fixture_path "$path"
    event "swapon $path"
    if [[ "$MOCK_FAIL" == swapon && "$path" != "$VPSCTL_SYSTEM_ROOT/old.swap" ]]; then return 1; fi
    if [[ -b "$path" ]]; then
        size=67104768
        type=partition
    else size="$(($(stat -c %s "$path") - 4096))"; fi
    if ! awk -v path="$path" '$1 == path { found=1 } END { exit !found }' "$VPSCTL_SYSTEM_ROOT/active"; then
        printf '%s %s %s 0 -2\n' "$path" "$type" "$size" >>"$VPSCTL_SYSTEM_ROOT/active"
    fi
}
swapoff() {
    local path="${*: -1}" line source rest
    if [[ "${1:-}" == --version ]]; then
        printf 'swapoff from util-linux 2.40\n'
        return 0
    fi
    fixture_path "$path"
    event "swapoff $path"
    if [[ "$MOCK_FAIL" == swapoff && "$path" == "$VPSCTL_SYSTEM_ROOT/old.swap" ]]; then return 1; fi
    if [[ "$MOCK_FAIL" == rollback && "$path" != "$VPSCTL_SYSTEM_ROOT/old.swap" ]]; then return 1; fi
    while IFS= read -r line; do
        IFS=' ' read -r source rest <<<"$line"
        [[ "$(readlink -f -- "$source")" == "$path" ]] || printf '%s\n' "$line"
    done <"$VPSCTL_SYSTEM_ROOT/active" >"$VPSCTL_SYSTEM_ROOT/active.next"
    command mv "$VPSCTL_SYSTEM_ROOT/active.next" "$VPSCTL_SYSTEM_ROOT/active"
}
blkid() {
    local path="${*: -1}"
    if [[ "${1:-}" == --version ]]; then
        printf 'blkid from util-linux 2.40\n'
        return 0
    fi
    if [[ "${1:-}" == -t ]]; then
        [[ "$*" != *fixture-part* ]] || printf '%s\n' "$VPSCTL_SYSTEM_ROOT/dev/mockpart"
        return 0
    fi
    fixture_path "$path"
    [[ -f "${path}.signature" ]] || return 2
    cat "${path}.signature"
}
findmnt() {
    if [[ "${1:-}" == --version ]]; then
        printf 'findmnt from util-linux 2.40\n'
        return 0
    fi
    if [[ "$*" == *FSTYPE* ]]; then printf '%s\n' "$MOCK_FSTYPE"; else printf '/dev/fixture\n'; fi
}
lsblk() {
    if [[ "${1:-}" == --version ]]; then
        printf 'lsblk from util-linux 2.40\n'
        return 0
    fi
    if [[ "$*" == *PKNAME* ]]; then printf 'fixture-disk\n'; else printf 'part\n'; fi
}
df() {
    if [[ "${1:-}" == --help ]]; then
        printf '%s\n' '--output'
        return 0
    fi
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fixture 67108864 0 %s 0%% /\n' "$((MOCK_SPACE / 1024))"
}
systemctl() {
    case "${1:-}" in
        daemon-reload)
            event init
            if [[ "$MOCK_FAIL" == signal && ! -e "$VPSCTL_SYSTEM_ROOT/signalled" ]]; then
                : >"$VPSCTL_SYSTEM_ROOT/signalled"
                kill -TERM "$BASHPID"
            fi
            if [[ "$MOCK_FAIL" == init || "$MOCK_FAIL" == rollback ]]; then
                if [[ ! -e "$VPSCTL_SYSTEM_ROOT/failed-init" ]]; then
                    : >"$VPSCTL_SYSTEM_ROOT/failed-init"
                    return 1
                fi
            fi
            if [[ -n "$MOCK_TAMPER" && ! -e "$VPSCTL_SYSTEM_ROOT/tampered" ]]; then
                : >"$VPSCTL_SYSTEM_ROOT/tampered"
                if [[ "$MOCK_TAMPER" == non-swap || "$MOCK_TAMPER" == stale ]]; then
                    command cp -p --sparse=always "$VPSCTL_SYSTEM_ROOT/old.swap" "$VPSCTL_SYSTEM_ROOT/saved-old.swap"
                else
                    command mv "$VPSCTL_SYSTEM_ROOT/old.swap" "$VPSCTL_SYSTEM_ROOT/saved-old.swap"
                fi
                case "$MOCK_TAMPER" in
                    replaced)
                        command truncate -s 67108864 "$VPSCTL_SYSTEM_ROOT/old.swap"
                        chmod 600 "$VPSCTL_SYSTEM_ROOT/old.swap"
                        ;;
                    symlink) ln -s "$VPSCTL_SYSTEM_ROOT/saved-old.swap" "$VPSCTL_SYSTEM_ROOT/old.swap" ;;
                    stale) command truncate -s 33554432 "$VPSCTL_SYSTEM_ROOT/old.swap" ;;
                    # Same dev/inode/length/mode: specifically exercise the
                    # signature check rather than an earlier identity gate.
                    non-swap) printf ext4 >"$VPSCTL_SYSTEM_ROOT/old.swap.signature" ;;
                esac
            fi
            local logical unit directory="$VPSCTL_SYSTEM_ROOT/run/systemd/generator"
            logical="$(awk '$3 == "swap" && /Managed by vpsctl system swap/ { print $1 }' "$VPSCTL_SYSTEM_ROOT/etc/fstab")"
            if [[ -n "$logical" ]]; then
                unit="$(systemd-escape --path --suffix=swap "$(swap_fstab_decode "$logical")")"
                mkdir -p "$directory/swap.target.requires"
                printf '[Swap]\n' >"$directory/$unit"
                if [[ "$MOCK_FAIL" != boot ]]; then ln -sf "../$unit" "$directory/swap.target.requires/$unit"; fi
            fi
            ;;
        is-system-running) printf 'running\n' ;;
        list-units | list-unit-files) if [[ -n "$MOCK_UNIT" ]]; then printf '%s loaded active active\n' "$MOCK_UNIT"; fi ;;
        show)
            if [[ "${2:-}" == swap.target ]]; then
                if [[ "$MOCK_TARGET_MASK" == 1 ]]; then printf 'LoadState=masked\nUnitFileState=masked\n'; else printf 'LoadState=loaded\nUnitFileState=static\n'; fi
                return 0
            fi
            if [[ "$MOCK_UNIT" == custom.swap ]]; then
                printf 'What=%s/old.swap\nSourcePath=/etc/systemd/system/custom.swap\nFragmentPath=/etc/systemd/system/custom.swap\n' "$VPSCTL_SYSTEM_ROOT"
            else
                local logical unit
                logical="$(awk '$3 == "swap" && /Managed by vpsctl system swap/ { print $1 }' "$VPSCTL_SYSTEM_ROOT/etc/fstab")"
                unit="${2:-fixture.swap}"
                printf 'What=%s\nSourcePath=/etc/fstab\nFragmentPath=/run/systemd/generator/%s\nDropInPaths=\nLoadState=loaded\n' "$(swap_fstab_decode "$logical")" "$unit"
            fi
            ;;
        *) return 0 ;;
    esac
}
update-initramfs() {
    event initramfs
    [[ "$MOCK_FAIL" != init ]]
}
dracut() {
    event initramfs
    [[ "$MOCK_FAIL" != init ]]
}
rc-update() {
    local boot="$VPSCTL_SYSTEM_ROOT/etc/runlevels/boot/swap"
    case "${1:-}" in
        show) if [[ -L "$boot" ]]; then printf 'swap | boot\n'; fi ;;
        add)
            equal swap "${2:-}" 'OpenRC standard service'
            equal boot "${3:-}" 'OpenRC boot runlevel'
            event init
            mkdir -p "${boot%/*}"
            ln -sf "$VPSCTL_SYSTEM_ROOT/etc/init.d/swap" "$boot"
            [[ "$MOCK_FAIL" != openrc-add ]] || return 1
            ;;
        del)
            event restore-init
            command rm -f -- "$boot"
            ;;
        -u | --update)
            event refresh-init
            if [[ "$MOCK_FAIL" == openrc-refresh || "$MOCK_FAIL" == openrc-restore ]] && [[ ! -e "$VPSCTL_SYSTEM_ROOT/failed-openrc-refresh" ]]; then
                : >"$VPSCTL_SYSTEM_ROOT/failed-openrc-refresh"
                return 1
            fi
            ;;
        *) fail "unexpected rc-update invocation: $*" ;;
    esac
}
rm() {
    local argument
    for argument in "$@"; do
        [[ "$argument" == -* ]] && continue
        fixture_path "$argument"
        if [[ "$argument" == "$VPSCTL_SYSTEM_ROOT/old.swap" ]]; then
            event delete-old
            [[ "$MOCK_FAIL" != delete ]] || return 1
        fi
    done
    command rm "$@"
}

seed_old() {
    command truncate -s 67108864 "$VPSCTL_SYSTEM_ROOT/old.swap"
    chmod 600 "$VPSCTL_SYSTEM_ROOT/old.swap"
    printf swap >"$VPSCTL_SYSTEM_ROOT/old.swap.signature"
    printf '%s file 67108864 1024 -2\n' "$VPSCTL_SYSTEM_ROOT/old.swap" >"$VPSCTL_SYSTEM_ROOT/active"
    printf '/old.swap none swap sw 0 0\n' >>"$VPSCTL_SYSTEM_ROOT/etc/fstab"
    command cp "$VPSCTL_SYSTEM_ROOT/etc/fstab" "$VPSCTL_SYSTEM_ROOT/fstab.before"
    command cp "$VPSCTL_SYSTEM_ROOT/active" "$VPSCTL_SYSTEM_ROOT/active.before"
}
unchanged_old() {
    present "$VPSCTL_SYSTEM_ROOT/old.swap"
    command cmp "$VPSCTL_SYSTEM_ROOT/fstab.before" "$VPSCTL_SYSTEM_ROOT/etc/fstab" || fail 'original fstab was not restored'
    contains "$(cat "$VPSCTL_SYSTEM_ROOT/active")" "$VPSCTL_SYSTEM_ROOT/old.swap " 'old swap stays active'
    equal 67108864 "$(stat -c %s "$VPSCTL_SYSTEM_ROOT/old.swap")" 'old swap file preserved'
}

test_read_only_and_args() {
    local arguments
    local -a tokens=()
    new_case
    seed_old
    invoke
    equal 0 "$STATUS" 'headless default status/help'
    [[ -n "$OUTPUT" ]] || fail 'headless default omitted status/help'
    [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail 'headless default mutated system'
    invoke --help
    equal 0 "$STATUS" 'help'
    contains "$OUTPUT" 'set' 'set help syntax'
    contains "$OUTPUT" 'disable' 'disable help syntax'
    invoke status
    equal 0 "$STATUS" 'status'
    [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail 'status mutated system'
    unchanged_old
    for arguments in 'status extra' 'disable extra' 'set --size' 'set --size 64M --size 128M' 'set --size 64M extra' 'set --size 1.5G' 'set --size 63M' 'set 64M' 'set --bogus' 'status --bogus' 'unknown'; do
        # Intentional token splitting of fixed argument fixtures.
        IFS=' ' read -r -a tokens <<<"$arguments"
        invoke "${tokens[@]}"
        equal 2 "$STATUS" "reject arguments $arguments"
    done
    printf 'PASS: swap read-only CLI and invalid arguments\n'
}

test_unsafe_sources() {
    local kind
    for kind in zram manager custom symlink non-swap masked-target; do
        new_case
        seed_old
        case "$kind" in
            zram)
                printf '%s partition 67108864 0 100\n' "$VPSCTL_SYSTEM_ROOT/dev/zram0" >>"$VPSCTL_SYSTEM_ROOT/active"
                mkdir -p "$VPSCTL_SYSTEM_ROOT/sys/block/zram0"
                ;;
            manager)
                mkdir -p "$VPSCTL_SYSTEM_ROOT/proc/123"
                printf 'dphys-swapfile\n' >"$VPSCTL_SYSTEM_ROOT/proc/123/comm"
                ;;
            custom) MOCK_UNIT=custom.swap ;;
            masked-target) MOCK_TARGET_MASK=1 ;;
            symlink)
                command mv "$VPSCTL_SYSTEM_ROOT/old.swap" "$VPSCTL_SYSTEM_ROOT/keep.swap"
                ln -s "$VPSCTL_SYSTEM_ROOT/keep.swap" "$VPSCTL_SYSTEM_ROOT/old.swap"
                ;;
            non-swap)
                : >"$VPSCTL_SYSTEM_ROOT/active"
                printf ext4 >"$VPSCTL_SYSTEM_ROOT/old.swap.signature"
                ;;
        esac
        invoke set --size 128M
        [[ "$STATUS" != 0 ]] || fail "unsafe $kind source accepted"
        present "$VPSCTL_SYSTEM_ROOT/old.swap"
        command cmp "$VPSCTL_SYSTEM_ROOT/fstab.before" "$VPSCTL_SYSTEM_ROOT/etc/fstab" || fail "$kind changed fstab"
        [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail "$kind changed system before rejection"
    done
    printf 'PASS: swap special managers and unsafe sources rejected\n'
}

test_dry_run_permissions_dependencies() {
    new_case
    seed_old
    VPSCTL_ASSUME_YES=0
    invoke --dry-run set --size 128M
    equal 0 "$STATUS" 'dry-run without confirmation'
    [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail 'dry-run executed mutation'
    unchanged_old
    MOCK_DENY_ROOT=1
    invoke set --size 128M
    equal 4 "$STATUS" 'root permission rejection'
    unchanged_old
    MOCK_DENY_ROOT=0 MOCK_MISSING=mkswap
    invoke --yes set --size 128M
    equal 3 "$STATUS" 'missing dependency requires authorization'
    [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail 'missing dependency attempted installation/mutation'
    invoke --dry-run --install-deps set --size 128M
    equal 0 "$STATUS" "missing dependency dry-run plan ($OUTPUT)"
    [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail 'dry-run installed dependency'
    unchanged_old
    printf 'PASS: swap dry-run, permissions and dependencies\n'
}

test_set_order_and_idempotence() {
    local active line previous=''
    new_case
    seed_old
    invoke set --size 128M
    equal 0 "$STATUS" "replacement success: $OUTPUT"
    absent "$VPSCTL_SYSTEM_ROOT/old.swap"
    active="$(cat "$VPSCTL_SYSTEM_ROOT/active")"
    equal 1 "$(wc -l <"$VPSCTL_SYSTEM_ROOT/active" | tr -d ' ')" 'one resulting swap'
    contains "$active" ' file 134213632 ' 'requested swap usable size'
    line="${active%% *}"
    equal 134217728 "$(stat -c %s "$line")" 'requested swap file size'
    while IFS= read -r line; do
        case "$line" in
            "swapoff $VPSCTL_SYSTEM_ROOT/old.swap") contains "$previous" 'swapon ' 'candidate active before old swapoff' ;;
            delete-old)
                contains "$previous" 'config' 'fstab commit before deletion'
                contains "$previous" 'init' 'init commit before deletion'
                ;;
        esac
        previous+="$line"$'\n'
    done <"$VPSCTL_SYSTEM_ROOT/events"
    contains "$(cat "$VPSCTL_SYSTEM_ROOT/etc/fstab")" 'UUID=root / ext4 defaults 0 1' 'root filesystem entry retained'
    : >"$VPSCTL_SYSTEM_ROOT/events"
    invoke set --size 128M
    equal 0 "$STATUS" "same managed size success: $OUTPUT"
    equal "$active" "$(cat "$VPSCTL_SYSTEM_ROOT/active")" 'same size retains active file'
    [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail 'same owned size repeated transaction'
    printf 'PASS: swap replacement ordering and idempotence\n'
}

test_failures_restore_old() {
    local stage
    for stage in dd mkswap swapon swapoff config init boot; do
        new_case
        seed_old
        MOCK_FAIL="$stage"
        invoke set --size 128M
        equal 20 "$STATUS" "failure $stage reports operation failure ($OUTPUT)"
        unchanged_old
        equal 1 "$(wc -l <"$VPSCTL_SYSTEM_ROOT/active" | tr -d ' ')" "$stage rollback leaves only old swap active"
        equal 0 "$(find "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/system/swap" -maxdepth 1 -type f ! -name '*.signature' | wc -l | tr -d ' ')" "$stage rollback removes candidate file"
        [[ "$(cat "$VPSCTL_SYSTEM_ROOT/events")" != *delete-old* ]] || fail "$stage failure deleted old file"
    done
    printf 'PASS: swap transaction failures restore old state\n'
}

test_insufficient_resources() {
    new_case
    seed_old
    MOCK_SPACE=1
    invoke set --size 128M
    [[ "$STATUS" != 0 ]] || fail 'insufficient filesystem space accepted'
    unchanged_old
    [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail 'insufficient space changed system'
    new_case
    seed_old
    printf 'MemTotal: 1048576 kB\nMemAvailable: 1 kB\n' >"$VPSCTL_SYSTEM_ROOT/proc/meminfo"
    printf '%s file 67108864 1048576 -2\n' "$VPSCTL_SYSTEM_ROOT/old.swap" >"$VPSCTL_SYSTEM_ROOT/active"
    invoke disable
    [[ "$STATUS" != 0 ]] || fail 'unsafe swapoff memory pressure accepted'
    unchanged_old
    [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail 'memory rejection changed system'
    printf 'PASS: swap resource failures are unchanged\n'
}

test_partial_cleanup() {
    new_case
    seed_old
    MOCK_FAIL=delete
    invoke set --size 128M
    equal 30 "$STATUS" 'committed replacement cleanup failure'
    present "$VPSCTL_SYSTEM_ROOT/old.swap"
    [[ "$(cat "$VPSCTL_SYSTEM_ROOT/active")" != *'/old.swap '* ]] || fail 'cleanup failure reactivated old swap'
    [[ "$(cat "$VPSCTL_SYSTEM_ROOT/etc/fstab")" != *'/old.swap '* ]] || fail 'cleanup failure reverted committed fstab'
    contains "$(cat "$VPSCTL_SYSTEM_ROOT/active")" ' file 134213632 ' 'cleanup failure keeps committed candidate'
    new_case
    seed_old
    MOCK_FAIL=rollback
    invoke set --size 128M
    equal 30 "$STATUS" 'rollback cleanup failure reported separately'
    present "$VPSCTL_SYSTEM_ROOT/old.swap"
    contains "$(cat "$VPSCTL_SYSTEM_ROOT/active")" '/old.swap ' 'failed candidate cleanup still restores old activity'
    printf 'PASS: swap partial cleanup reports exit 30\n'
}

test_signal_and_delete_protection() {
    local kind
    new_case
    seed_old
    MOCK_FAIL=signal
    invoke set --size 128M
    equal 143 "$STATUS" "TERM propagates interruption ($OUTPUT)"
    unchanged_old
    equal 1 "$(wc -l <"$VPSCTL_SYSTEM_ROOT/active" | tr -d ' ')" 'TERM removes candidate activity'
    equal 0 "$(find "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/system/swap" -maxdepth 1 -type f ! -name '*.signature' | wc -l | tr -d ' ')" 'TERM removes candidate file'
    for kind in replaced symlink stale non-swap; do
        new_case
        seed_old
        MOCK_TAMPER="$kind"
        invoke set --size 128M
        equal 30 "$STATUS" "$kind deletion refusal reports cleanup failure ($OUTPUT)"
        present "$VPSCTL_SYSTEM_ROOT/old.swap"
        present "$VPSCTL_SYSTEM_ROOT/saved-old.swap"
        if [[ "$kind" == non-swap ]]; then
            equal ext4 "$(cat "$VPSCTL_SYSTEM_ROOT/old.swap.signature")" 'non-swap signature retained'
            equal 67108864 "$(stat -c %s "$VPSCTL_SYSTEM_ROOT/old.swap")" 'non-swap file retained at same size'
        elif [[ "$kind" == symlink ]]; then
            [[ -L "$VPSCTL_SYSTEM_ROOT/old.swap" ]] || fail 'replacement symlink deleted'
        elif [[ "$kind" == stale ]]; then
            equal 33554432 "$(stat -c %s "$VPSCTL_SYSTEM_ROOT/old.swap")" 'stale changed file retained'
        fi
        contains "$(cat "$VPSCTL_SYSTEM_ROOT/active")" ' file 134213632 ' 'deletion refusal retains committed candidate'
        [[ "$(cat "$VPSCTL_SYSTEM_ROOT/events")" != *delete-old* ]] || fail "$kind reached unsafe deletion"
    done
    printf 'PASS: swap interruption and replaced-file deletion protection\n'
}

test_mixed_sources() {
    local action part="$TEST_TEMP/unused" options
    for action in set disable; do
        new_case
        seed_old
        part="$VPSCTL_SYSTEM_ROOT/dev/mockpart"
        # This unbacked fixture node is never opened. All block-device tools
        # are functions above; only stat/readlink inspect its identity.
        command mknod "$part" b 240 255
        printf swap >"${part}.signature"
        mkdir -p "$VPSCTL_SYSTEM_ROOT/dev/disk/by-uuid"
        ln -s ../../mockpart "$VPSCTL_SYSTEM_ROOT/dev/disk/by-uuid/fixture-part"
        printf '%s partition 67104768 4096 -2\n%s partition 67104768 4096 -2\n' "$part" "$VPSCTL_SYSTEM_ROOT/dev/disk/by-uuid/fixture-part" >>"$VPSCTL_SYSTEM_ROOT/active"
        printf 'UUID=fixture-part none swap sw,pri=7,discard,auto 0 0\n/dev/disk/by-uuid/fixture-part none swap defaults 0 0\n# unrelated tail' >>"$VPSCTL_SYSTEM_ROOT/etc/fstab"
        if [[ "$action" == set ]]; then invoke set --size 128M; else invoke disable; fi
        equal 0 "$STATUS" "$action mixed sources ($OUTPUT)"
        [[ -b "$part" ]] || fail "$action removed partition fixture"
        equal swap "$(cat "${part}.signature")" "$action left partition data unchanged"
        absent "$VPSCTL_SYSTEM_ROOT/old.swap"
        equal 1 "$(grep -c "^swapoff $part$" "$VPSCTL_SYSTEM_ROOT/events")" "$action deduplicated active partition aliases"
        contains "$(cat "$VPSCTL_SYSTEM_ROOT/etc/fstab")" 'UUID=root / ext4 defaults 0 1' "$action retained non-swap entry"
        contains "$(cat "$VPSCTL_SYSTEM_ROOT/etc/fstab")" '# unrelated tail' "$action retained unrelated unterminated line"
        while IFS= read -r options; do
            contains ",${options}," ',noauto,' "$action disables partition auto activation"
            [[ ",${options}," != *,auto,* ]] || fail "$action retained conflicting auto option"
        done < <(awk '$3 == "swap" && $1 !~ /var\/lib\/vpsctl/ { print $4 }' "$VPSCTL_SYSTEM_ROOT/etc/fstab")
        contains "$(cat "$VPSCTL_SYSTEM_ROOT/etc/fstab")" 'pri=7' "$action retains partition priority option"
        contains "$(cat "$VPSCTL_SYSTEM_ROOT/etc/fstab")" 'discard' "$action retains partition discard option"
        if [[ "$action" == disable ]]; then [[ ! -s "$VPSCTL_SYSTEM_ROOT/active" ]] || fail 'disable left swap active'; fi
    done
    printf 'PASS: swap mixed file/partition aliases and noauto persistence\n'
}

assert_openrc_ordering() (
    local conf="$VPSCTL_SYSTEM_ROOT/etc/conf.d/swap" rc_before='' rc_need='' swap_extra=''
    present "$conf"
    # Only source the declarative config created by this fixture.
    # shellcheck disable=SC1090
    source "$conf"
    contains " $rc_before " ' !localmount ' 'OpenRC cancels pre-localmount ordering'
    contains " $rc_need " ' localmount ' 'OpenRC requires mounted local filesystems'
    contains " $rc_need " ' logger ' 'OpenRC retains existing dependency'
    equal 'keep value' "$swap_extra" 'OpenRC retains unrelated variable'
)

assert_openrc_conf_preserved() {
    local conf="$VPSCTL_SYSTEM_ROOT/etc/conf.d/swap" original="$VPSCTL_SYSTEM_ROOT/openrc-conf.before"
    command cmp "$original" <(head -c "$(stat -c %s "$original")" "$conf") || fail 'OpenRC replaced prior config text'
    equal "$(stat -c '%a:%u:%g' "$original")" "$(stat -c '%a:%u:%g' "$conf")" 'OpenRC config metadata retained'
}

test_openrc_boot_transaction() {
    local mode active conf backup
    for mode in success add-failure conf-failure refresh-failure refresh-missing wrong-target malformed-markers restore-failure; do
        new_case
        seed_old
        VPSCTL_ENV_INIT=openrc
        mkdir -p "$VPSCTL_SYSTEM_ROOT/etc/init.d" "$VPSCTL_SYSTEM_ROOT/etc/runlevels/boot" "$VPSCTL_SYSTEM_ROOT/etc/conf.d"
        printf '#!/bin/sh\n' >"$VPSCTL_SYSTEM_ROOT/etc/init.d/swap"
        printf '#!/bin/sh\n' >"$VPSCTL_SYSTEM_ROOT/etc/init.d/localmount"
        conf="$VPSCTL_SYSTEM_ROOT/etc/conf.d/swap"
        printf '# site swap configuration\nrc_before="localmount"\nrc_need="logger"\nswap_extra="keep value"\n' >"$conf"
        chmod 640 "$conf"
        command cp -p "$conf" "$VPSCTL_SYSTEM_ROOT/openrc-conf.before"
        case "$mode" in
            add-failure) MOCK_FAIL=openrc-add ;;
            conf-failure) MOCK_FAIL=openrc-config ;;
            refresh-failure) MOCK_FAIL=openrc-refresh ;;
            refresh-missing)
                MOCK_FAIL=openrc-refresh
                command rm "$conf"
                ;;
            restore-failure) MOCK_FAIL=openrc-restore ;;
            malformed-markers)
                printf '# BEGIN vpsctl system swap local files\nrc_need="localmount"\n' >>"$conf"
                command cp -p "$conf" "$VPSCTL_SYSTEM_ROOT/openrc-conf.before"
                ;;
            wrong-target)
                printf '#!/bin/sh\n' >"$VPSCTL_SYSTEM_ROOT/etc/init.d/unrelated"
                ln -s "$VPSCTL_SYSTEM_ROOT/etc/init.d/unrelated" "$VPSCTL_SYSTEM_ROOT/etc/runlevels/boot/swap"
                ;;
        esac
        invoke set --size 128M
        if [[ "$mode" == success ]]; then
            equal 0 "$STATUS" "OpenRC successful transaction ($OUTPUT)"
            equal "$VPSCTL_SYSTEM_ROOT/etc/init.d/swap" "$(readlink -f "$VPSCTL_SYSTEM_ROOT/etc/runlevels/boot/swap")" 'OpenRC standard boot service enabled'
            absent "$VPSCTL_SYSTEM_ROOT/old.swap"
            assert_openrc_ordering
            assert_openrc_conf_preserved
            contains "$(cat "$VPSCTL_SYSTEM_ROOT/events")" refresh-init 'OpenRC dependency cache refreshed'
            active="$(cat "$VPSCTL_SYSTEM_ROOT/active")"
            : >"$VPSCTL_SYSTEM_ROOT/events"
            invoke set --size 128M
            equal 0 "$STATUS" "OpenRC same-size idempotence ($OUTPUT)"
            equal "$active" "$(cat "$VPSCTL_SYSTEM_ROOT/active")" 'OpenRC same-size retains active swap file'
            [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail 'valid OpenRC same-size repeated transaction'
            # Removing the ordering block must invalidate the no-op decision.
            command cp -p "$VPSCTL_SYSTEM_ROOT/openrc-conf.before" "$conf"
            invoke set --size 128M
            equal 0 "$STATUS" "OpenRC same-size repairs missing ordering ($OUTPUT)"
            assert_openrc_ordering
            assert_openrc_conf_preserved
            contains "$(cat "$VPSCTL_SYSTEM_ROOT/events")" openrc-config 'OpenRC invalid same-size ordering repaired'
            invoke disable
            equal 0 "$STATUS" "OpenRC disable cleans managed ordering ($OUTPUT)"
            [[ ! -s "$VPSCTL_SYSTEM_ROOT/active" ]] || fail 'OpenRC disable left swap active'
            command cmp "$VPSCTL_SYSTEM_ROOT/openrc-conf.before" "$conf" || fail 'OpenRC disable did not preserve original config exactly'
            assert_openrc_conf_preserved
        elif [[ "$mode" == restore-failure ]]; then
            equal 30 "$STATUS" "OpenRC failed restore reports partial rollback ($OUTPUT)"
            present "$VPSCTL_SYSTEM_ROOT/old.swap"
            contains "$(cat "$VPSCTL_SYSTEM_ROOT/active")" '/old.swap ' 'OpenRC failed config restore retains original activity'
            backup="$(find "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/backups/system/swap" -name openrc-swap -type f)"
            present "$backup"
            command cmp "$VPSCTL_SYSTEM_ROOT/openrc-conf.before" "$backup" || fail 'OpenRC failed restore lost original config backup'
        else
            if [[ "$mode" == malformed-markers ]]; then
                equal 3 "$STATUS" "OpenRC malformed markers rejected before mutation ($OUTPUT)"
                [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail 'OpenRC malformed config changed system'
            else
                equal 20 "$STATUS" "OpenRC $mode reports operation failure ($OUTPUT)"
            fi
            unchanged_old
            equal 1 "$(wc -l <"$VPSCTL_SYSTEM_ROOT/active" | tr -d ' ')" "OpenRC $mode removes candidate activity"
            if [[ "$mode" == refresh-missing ]]; then
                absent "$conf"
            else
                command cmp "$VPSCTL_SYSTEM_ROOT/openrc-conf.before" "$conf" || fail "OpenRC $mode did not restore original config bytes"
                assert_openrc_conf_preserved
            fi
            if [[ "$mode" == wrong-target ]]; then
                equal "$VPSCTL_SYSTEM_ROOT/etc/init.d/unrelated" "$(readlink -f "$VPSCTL_SYSTEM_ROOT/etc/runlevels/boot/swap")" 'OpenRC original boot target retained'
            else
                absent "$VPSCTL_SYSTEM_ROOT/etc/runlevels/boot/swap"
            fi
        fi
    done
    printf 'PASS: swap OpenRC ordering, config preservation, idempotence, disable and rollback\n'
}

test_menu_and_platform_gates() {
    new_case
    seed_old
    (
        local selected count status
        vps_cmd_init system-swap "$TEST_ROOT"
        swap_init_paths
        vps_cmd_prompt_value() {
            equal 2G "$2" 'menu default reflects fixture RAM'
            count=0
            [[ ! -f "$VPSCTL_SYSTEM_ROOT/prompt-count" ]] || count="$(cat "$VPSCTL_SYSTEM_ROOT/prompt-count")"
            count=$((count + 1))
            printf '%s\n' "$count" >"$VPSCTL_SYSTEM_ROOT/prompt-count"
            if ((count == 1)); then printf '1.5G'; else printf '64M'; fi
        }
        selected="$(swap_prompt_size 2>"$TEST_TEMP/menu-errors")"
        equal 64M "$selected" 'menu retries invalid size and accepts valid size'
        equal 2 "$(cat "$VPSCTL_SYSTEM_ROOT/prompt-count")" 'menu invalid size retry count'
        vps_cmd_confirm() { return 1; }
        invoke set --size 128M
        equal 130 "$STATUS" 'declined swap confirmation reports cancellation'
        unchanged_old
        [[ ! -s "$VPSCTL_SYSTEM_ROOT/events" ]] || fail 'declined confirmation mutated system'
        uname() { printf 'Darwin\n'; }
        VPSCTL_TESTING=0
        status=0
        swap_require_linux >"$TEST_TEMP/platform-output" 2>&1 || status=$?
        equal 3 "$status" 'unsupported standalone platform rejected'
        VPSCTL_TESTING=1
        swap_require_linux || fail 'isolated testing did not bypass platform gate'
        uname() { printf 'Linux\n'; }
        VPSCTL_TESTING=0
        swap_require_linux || fail 'Linux platform rejected'
        printf 'PASS: swap menu defaults, validation, cancellation and platform gate\n'
    )
}

case "${1:-all}" in
    pure)
        test_sizes
        test_fstab_escapes
        ;;
    cli)
        test_read_only_and_args
        test_dry_run_permissions_dependencies
        ;;
    safety) test_signal_and_delete_protection ;;
    openrc) test_openrc_boot_transaction ;;
    menu) test_menu_and_platform_gates ;;
    transaction)
        test_set_order_and_idempotence
        test_failures_restore_old
        test_insufficient_resources
        test_partial_cleanup
        test_unsafe_sources
        test_signal_and_delete_protection
        test_mixed_sources
        ;;
    all)
        test_sizes
        test_fstab_escapes
        test_read_only_and_args
        test_dry_run_permissions_dependencies
        test_set_order_and_idempotence
        test_failures_restore_old
        test_insufficient_resources
        test_partial_cleanup
        test_unsafe_sources
        test_signal_and_delete_protection
        test_mixed_sources
        test_openrc_boot_transaction
        test_menu_and_platform_gates
        ;;
    *) fail "unknown test group: $1" ;;
esac
printf 'PASS: system swap unit tests (%s fixtures)\n' "$TEST_CASE"
