#!/usr/bin/env bash
# These fixtures execute only mock upstream scripts inside a temporary root.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2030,SC2031,SC2034
set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
ENTRY="$TEST_ROOT/commands/system/reinstall.sh"
TEST_CASE=0
TEST_PID=''
trap 'if [[ -n "$TEST_PID" ]]; then kill "$TEST_PID" 2>/dev/null || true; fi; rm -rf -- "$TEST_TEMP"' EXIT
mkdir -p "$TEST_TEMP/bin"
export PATH="$TEST_TEMP/bin:$PATH"
export VPSCTL_TESTING=1 VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1 VPSCTL_ASSUME_YES=1
export VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0

cat >"$TEST_TEMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'download\n' >>"$VPSCTL_SYSTEM_ROOT/events"
destination=''
while (($#)); do
    if [[ "$1" == --output ]]; then destination="$2"; shift; fi
    shift
done
case "${MOCK_DOWNLOAD:-ok}" in
    fail) printf 'partial\n' >"$destination"; exit 22 ;;
    empty) : >"$destination" ;;
    html) printf '<html>not a script</html>\n' >"$destination" ;;
    syntax) printf '#!/bin/bash\nif broken\n' >"$destination" ;;
    *) cp -- "$MOCK_UPSTREAM" "$destination" ;;
esac
EOF
cat >"$TEST_TEMP/bin/rm" <<'EOF'
#!/usr/bin/env bash
if [[ "${MOCK_REMOVE_FAIL:-0}" == 1 && "${*: -1}" == "$VPSCTL_SYSTEM_ROOT/reinstall-firmware" ]]; then
    exit 1
fi
exec /bin/rm "$@"
EOF
cat >"$TEST_TEMP/upstream" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" >"$VPSCTL_SYSTEM_ROOT/args"
printf 'upstream:%s\n' "${1:-}" >>"$VPSCTL_SYSTEM_ROOT/events"
[[ -t 0 && -t 1 ]] && printf 'tty\n' >"$VPSCTL_SYSTEM_ROOT/tty"
if [[ "${MOCK_READ_STDIN:-0}" == 1 ]]; then
    if IFS= read -r line; then printf '%s' "$line" >"$VPSCTL_SYSTEM_ROOT/stdin"; else : >"$VPSCTL_SYSTEM_ROOT/eof"; fi
fi
if [[ "${MOCK_SLEEP:-0}" == 1 ]]; then
    printf '%s\n' "$$" >"$VPSCTL_SYSTEM_ROOT/pid"
    trap 'exit 143' TERM
    while :; do sleep 0.1; done
fi
if [[ "${1:-}" == reset && "${MOCK_EXIT:-0}" == 0 ]]; then
    if [[ "${MOCK_KEEP_BOOT:-0}" != 1 ]]; then
        /bin/rm -f -- "$VPSCTL_SYSTEM_ROOT/boot/grub/custom.cfg" "$VPSCTL_SYSTEM_ROOT/boot/syslinux/nested/extlinux.conf" "$VPSCTL_SYSTEM_ROOT/efi/EFI/reinstall/grub.cfg"
    fi
    /bin/rm -rf -- "$VPSCTL_SYSTEM_ROOT/reinstall-tmp"
    /bin/rm -f -- "$VPSCTL_SYSTEM_ROOT/reinstall-vmlinuz" "$VPSCTL_SYSTEM_ROOT/reinstall-initrd"
    if [[ "${MOCK_RESET_MOUNT:-0}" == 1 ]]; then
        printf '10 1 0:1 / %s/reinstall-tmp rw - ext4 /dev/mock rw\n' "$VPSCTL_SYSTEM_ROOT" >"$VPSCTL_SYSTEM_ROOT/proc/self/mountinfo"
    fi
fi
exit "${MOCK_EXIT:-0}"
EOF
chmod +x "$TEST_TEMP/bin/"*
export MOCK_UPSTREAM="$TEST_TEMP/upstream"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
equal() { [[ "$1" == "$2" ]] || fail "$3: expected $1, got $2"; }
contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing $2"; }
absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected path: $1"; }
present() { [[ -e "$1" ]] || fail "missing path: $1"; }

new_case() {
    TEST_CASE=$((TEST_CASE + 1))
    export VPSCTL_SYSTEM_ROOT="$TEST_TEMP/case-$TEST_CASE"
    mkdir -p "$VPSCTL_SYSTEM_ROOT/proc/self" "$VPSCTL_SYSTEM_ROOT/boot/grub"
    : >"$VPSCTL_SYSTEM_ROOT/proc/self/mountinfo"
    : >"$VPSCTL_SYSTEM_ROOT/proc/cmdline"
    export MOCK_DOWNLOAD=ok MOCK_EXIT=0 MOCK_READ_STDIN=0 MOCK_SLEEP=0
    export MOCK_KEEP_BOOT=0 MOCK_RESET_MOUNT=0 MOCK_REMOVE_FAIL=0
    VPSCTL_DRY_RUN=0
    VPSCTL_ASSUME_YES=1
}

invoke() {
    STATUS=0
    OUTPUT="$(bash "$ENTRY" "$@" 2>&1)" || STATUS=$?
}

seed() {
    mkdir -p "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/reinstall" "$VPSCTL_SYSTEM_ROOT/reinstall-tmp"
    cp "$MOCK_UPSTREAM" "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/reinstall/reinstall.sh"
    printf 'keep\n' >"$VPSCTL_SYSTEM_ROOT/reinstall-tmp/image"
    printf 'kernel\n' >"$VPSCTL_SYSTEM_ROOT/reinstall-vmlinuz"
    printf 'firmware\n' >"$VPSCTL_SYSTEM_ROOT/reinstall-firmware"
    printf 'log\n' >"$VPSCTL_SYSTEM_ROOT/reinstall.log"
}

pending() {
    printf '### BEGIN reinstall.sh ###\nmenuentry reinstall {}\n### END reinstall.sh ###\n' >"$VPSCTL_SYSTEM_ROOT/boot/grub/custom.cfg"
}

test_source_and_help() (
    local options="$-" old_ifs="$IFS" old_umask
    old_umask="$(umask)"
    # shellcheck source=../../commands/system/reinstall.sh disable=SC1091
    source "$ENTRY"
    equal "$options" "$-" 'source preserves shell options'
    equal "$old_ifs" "$IFS" 'source preserves IFS'
    equal "$old_umask" "$(umask)" 'source preserves umask'
    [[ -z "${REINSTALL_STATE:-}" ]] || fail 'source initialized paths'
    new_case
    invoke
    equal 0 "$STATUS" 'empty args show help'
    contains "$OUTPUT" '用法' 'help text'
    invoke --help
    equal 0 "$STATUS" '--help'
    invoke -- status
    equal 0 "$STATUS" 'leading global separator'
    invoke status
    equal 0 "$STATUS" 'empty local status'
    absent "$VPSCTL_SYSTEM_ROOT/events"
    absent "$VPSCTL_SYSTEM_ROOT/var"
    absent "$VPSCTL_SYSTEM_ROOT/run"
)

test_run_and_arguments() {
    local -a args=() expected=(debian 12 --password 'a b"c' '\literal' --yes --dry-run '')
    new_case
    seed
    invoke --non-interactive run -- "${expected[@]}"
    equal 0 "$STATUS" 'run passes upstream args'
    mapfile -d '' -t args <"$VPSCTL_SYSTEM_ROOT/args"
    equal "${#expected[@]}" "${#args[@]}" 'argument count'
    for index in "${!expected[@]}"; do equal "${expected[index]}" "${args[index]}" "argument $index"; done
    [[ "$OUTPUT" != *'a b"c'* ]] || fail 'wrapper logged secret'
    present "$VPSCTL_SYSTEM_ROOT/reinstall-tmp/image"
    present "$VPSCTL_SYSTEM_ROOT/reinstall-vmlinuz"
    equal 700 "$(stat -c %a "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/reinstall")" 'private cache directory'
    equal 700 "$(stat -c %a "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/reinstall/reinstall.sh")" 'private upstream script'
    invoke run alpine
    equal 0 "$STATUS" 'second run'
    equal 2 "$(grep -c '^download$' "$VPSCTL_SYSTEM_ROOT/events")" 'fresh download each run'
    export MOCK_EXIT=47
    invoke run debian
    equal 47 "$STATUS" 'upstream exit propagated'
    export MOCK_EXIT=0 MOCK_READ_STDIN=1
    invoke run debian <<<'must not reach upstream'
    equal 0 "$STATUS" 'noninteractive input'
    present "$VPSCTL_SYSTEM_ROOT/eof"
    absent "$VPSCTL_SYSTEM_ROOT/stdin"
}

test_download_failure() {
    local mode before
    for mode in fail empty html syntax; do
        new_case
        seed
        before="$(sha256sum "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/reinstall/reinstall.sh")"
        export MOCK_DOWNLOAD="$mode"
        invoke run debian
        equal 20 "$STATUS" "download rejected: $mode"
        absent "$VPSCTL_SYSTEM_ROOT/args"
        equal "$before" "$(sha256sum "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/reinstall/reinstall.sh")" 'old reset script retained'
        equal 1 "$(find "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/reinstall" -type f | wc -l)" 'no temporary download remains'
    done
    new_case
    invoke --dry-run run debian
    equal 2 "$STATUS" 'dry run refused'
    absent "$VPSCTL_SYSTEM_ROOT/var"
    absent "$VPSCTL_SYSTEM_ROOT/run"
    absent "$VPSCTL_SYSTEM_ROOT/events"
}

test_reset_and_uninstall() {
    new_case
    seed
    export MOCK_DOWNLOAD=fail
    invoke reset
    equal 0 "$STATUS" 'reset uses retained upstream offline'
    equal 'upstream:reset' "$(cat "$VPSCTL_SYSTEM_ROOT/events")" 'reset did not download'
    present "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/reinstall/reinstall.sh"
    present "$VPSCTL_SYSTEM_ROOT/reinstall.log"
    new_case
    invoke reset
    equal 0 "$STATUS" 'reset downloads when absent'
    equal $'download\nupstream:reset' "$(cat "$VPSCTL_SYSTEM_ROOT/events")" 'missing reset script downloaded'
    new_case
    seed
    pending
    ln -s grub "$VPSCTL_SYSTEM_ROOT/boot/grub2"
    invoke uninstall
    equal 0 "$STATUS" 'pending uninstall with legitimate grub2 symlink'
    equal 'upstream:reset' "$(cat "$VPSCTL_SYSTEM_ROOT/events")" 'official reset ran first offline'
    absent "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/reinstall"
    absent "$VPSCTL_SYSTEM_ROOT/reinstall-firmware"
    contains "$OUTPUT" '已回收分配空间' 'reports allocated bytes'
    contains "$OUTPUT" '已清理：/reinstall-firmware' 'reports each removed path'
    invoke uninstall
    equal 0 "$STATUS" 'repeated uninstall'
    contains "$OUTPUT" '0 字节' 'repeat reclaims zero'
    new_case
    seed
    export MOCK_DOWNLOAD=fail
    invoke uninstall
    equal 0 "$STATUS" 'no boot state cleans entirely offline'
    absent "$VPSCTL_SYSTEM_ROOT/events"
    new_case
    seed
    mkdir -p "$VPSCTL_SYSTEM_ROOT/boot/syslinux/nested"
    printf 'LABEL reinstall\n  LINUX /reinstall-vmlinuz\n' >"$VPSCTL_SYSTEM_ROOT/boot/syslinux/nested/extlinux.conf"
    invoke uninstall
    equal 0 "$STATUS" 'nested Extlinux config triggers reset'
    equal 'upstream:reset' "$(cat "$VPSCTL_SYSTEM_ROOT/events")" 'bounded Extlinux discovery'
    new_case
    seed
    mkdir -p "$VPSCTL_SYSTEM_ROOT/efi/EFI/reinstall"
    invoke uninstall
    equal 0 "$STATUS" 'empty EFI directory has no pending boot entry'
    absent "$VPSCTL_SYSTEM_ROOT/events"
    new_case
    seed
    mkdir -p "$VPSCTL_SYSTEM_ROOT/efi/EFI/reinstall"
    printf 'menuentry reinstall {}\n' >"$VPSCTL_SYSTEM_ROOT/efi/EFI/reinstall/grub.cfg"
    invoke uninstall
    equal 0 "$STATUS" 'config-only EFI preparation can be reset and cleaned'
    equal 'upstream:reset' "$(cat "$VPSCTL_SYSTEM_ROOT/events")" 'EFI config reset ran'
    new_case
    printf 'dd image leftover\n' >"$VPSCTL_SYSTEM_ROOT/reinstall-firmware"
    invoke uninstall
    equal 0 "$STATUS" 'post-DD Linux with no wrapper state'
    absent "$VPSCTL_SYSTEM_ROOT/reinstall-firmware"
    absent "$VPSCTL_SYSTEM_ROOT/events"
    new_case
    seed
    VPSCTL_ASSUME_YES=0
    invoke uninstall
    equal 3 "$STATUS" 'ordinary confirmation required'
    present "$VPSCTL_SYSTEM_ROOT/reinstall.log"
}

test_partial_failures() {
    new_case
    seed
    pending
    export MOCK_EXIT=42
    invoke uninstall
    equal 30 "$STATUS" 'reset failure stops uninstall'
    present "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/reinstall/reinstall.sh"
    present "$VPSCTL_SYSTEM_ROOT/reinstall.log"
    contains "$OUTPUT" '42' 'upstream failure reported'
    new_case
    seed
    pending
    export MOCK_KEEP_BOOT=1
    invoke uninstall
    equal 30 "$STATUS" 'successful reset that leaves boot entry is not cleanup authorization'
    present "$VPSCTL_SYSTEM_ROOT/reinstall.log"
    new_case
    seed
    pending
    export MOCK_RESET_MOUNT=1
    invoke uninstall
    equal 30 "$STATUS" 'mount appearing after reset prevents deletion'
    present "$VPSCTL_SYSTEM_ROOT/reinstall.log"
    new_case
    seed
    export MOCK_REMOVE_FAIL=1
    invoke uninstall
    equal 30 "$STATUS" 'individual deletion failure returns partial'
    contains "$OUTPUT" '/reinstall-firmware' 'failed path reported'
    present "$VPSCTL_SYSTEM_ROOT/reinstall-firmware"
    absent "$VPSCTL_SYSTEM_ROOT/reinstall.log"
}

test_boundaries() {
    local target
    for target in /reinstall-tmp /reinstall-tmp/bind /var/lib/vpsctl/reinstall /efi/EFI/reinstall /boot/efi/reinstall-initrd; do
        new_case
        seed
        pending
        printf '10 1 8:1 / %s%s rw - ext4 /dev/mock rw\n' "$VPSCTL_SYSTEM_ROOT" "$target" >"$VPSCTL_SYSTEM_ROOT/proc/self/mountinfo"
        invoke uninstall
        equal 3 "$STATUS" "mount refused before reset: $target"
        absent "$VPSCTL_SYSTEM_ROOT/events"
        present "$VPSCTL_SYSTEM_ROOT/reinstall.log"
        invoke status
        equal 3 "$STATUS" 'unsafe occupancy is unknown'
        contains "$OUTPUT" '无法确定' 'status does not traverse mounted system as cache'
    done
    new_case
    seed
    pending
    mkdir -p "$VPSCTL_SYSTEM_ROOT/elsewhere"
    /bin/rm -rf "$VPSCTL_SYSTEM_ROOT/reinstall-tmp"
    ln -s "$VPSCTL_SYSTEM_ROOT/elsewhere" "$VPSCTL_SYSTEM_ROOT/reinstall-tmp"
    invoke uninstall
    equal 3 "$STATUS" 'symlink refused before reset'
    absent "$VPSCTL_SYSTEM_ROOT/events"
    new_case
    seed
    pending
    printf '10 1 8:1 / %s/boot rw - ext4 /dev/mock rw\n' "$VPSCTL_SYSTEM_ROOT" >"$VPSCTL_SYSTEM_ROOT/proc/self/mountinfo"
    invoke uninstall
    equal 0 "$STATUS" 'ordinary separate /boot mount is permitted'
}

test_active_environment() {
    local script option
    for script in /tmp/reinstall.sh /trans.sh; do
        new_case
        seed
        mkdir -p "$VPSCTL_SYSTEM_ROOT/proc/98765"
        printf '/bin/bash\0%s\0debian\0' "$script" >"$VPSCTL_SYSTEM_ROOT/proc/98765/cmdline"
        invoke uninstall
        equal 3 "$STATUS" "active process refused: $script"
        absent "$VPSCTL_SYSTEM_ROOT/events"
    done
    new_case
    seed
    mkdir -p "$VPSCTL_SYSTEM_ROOT/proc/98765"
    printf '/bin/bash\0-c\0echo reinstall.sh trans.sh\0' >"$VPSCTL_SYSTEM_ROOT/proc/98765/cmdline"
    invoke uninstall
    equal 0 "$STATUS" 'shell command text does not falsely match process'
    new_case
    seed
    mkdir -p "$VPSCTL_SYSTEM_ROOT/proc/98765"
    printf '/bin/bash\0--noprofile\0--norc\0/tmp/reinstall.sh\0debian\0' >"$VPSCTL_SYSTEM_ROOT/proc/98765/cmdline"
    invoke uninstall
    equal 3 "$STATUS" 'long shell options do not hide an active installer'
    absent "$VPSCTL_SYSTEM_ROOT/events"
    for option in -lc -ci; do
        new_case
        seed
        mkdir -p "$VPSCTL_SYSTEM_ROOT/proc/98765"
        printf '/bin/bash\0%s\0/tmp/reinstall.sh\0' "$option" >"$VPSCTL_SYSTEM_ROOT/proc/98765/cmdline"
        invoke uninstall
        equal 0 "$STATUS" "combined $option command text does not falsely match process"
    done
    new_case
    seed
    printf 'quiet finalos_distro=debian\n' >"$VPSCTL_SYSTEM_ROOT/proc/cmdline"
    invoke uninstall
    equal 3 "$STATUS" 'installer cmdline refused'
    new_case
    seed
    printf '10 1 0:1 / %s rw - tmpfs tmpfs rw\n' "$VPSCTL_SYSTEM_ROOT" >"$VPSCTL_SYSTEM_ROOT/proc/self/mountinfo"
    invoke uninstall
    equal 3 "$STATUS" 'live root refused'
}

test_lock_signals_and_terminal() {
    local iteration result=0 upstream_pid
    new_case
    export MOCK_SLEEP=1
    bash "$ENTRY" run debian >"$VPSCTL_SYSTEM_ROOT/output" 2>&1 &
    TEST_PID=$!
    for iteration in {1..100}; do
        [[ -f "$VPSCTL_SYSTEM_ROOT/pid" ]] && break
        sleep 0.05
    done
    present "$VPSCTL_SYSTEM_ROOT/pid"
    upstream_pid="$(cat "$VPSCTL_SYSTEM_ROOT/pid")"
    equal "$TEST_PID" "$upstream_pid" 'upstream replaces wrapper process'
    invoke reset
    equal 3 "$STATUS" 'run holds shared lock against reset'
    invoke uninstall
    equal 3 "$STATUS" 'run holds shared lock against uninstall'
    kill -TERM "$TEST_PID"
    wait "$TEST_PID" || result=$?
    TEST_PID=''
    equal 143 "$result" 'TERM reaches foreground upstream'
    export MOCK_SLEEP=0
    invoke reset
    equal 0 "$STATUS" 'lock released after signal'
    if command -v script >/dev/null 2>&1; then
        new_case
        VPSCTL_NON_INTERACTIVE=0 script -q -e -c "bash '$ENTRY' run debian" /dev/null >/dev/null
        present "$VPSCTL_SYSTEM_ROOT/tty"
    else
        fail 'terminal acceptance requires util-linux script'
    fi
}

test_permissions_dependencies_and_busybox() {
    local tool source_path
    new_case
    (
        # shellcheck disable=SC2317
        uname() { printf 'Darwin\n'; }
        export -f uname
        invoke run debian
        equal 3 "$STATUS" 'non-Linux mutation refused'
        absent "$VPSCTL_SYSTEM_ROOT/events"
        absent "$VPSCTL_SYSTEM_ROOT/run"
    )
    if ((EUID == 0)) && command -v runuser >/dev/null 2>&1; then
        STATUS=0
        OUTPUT="$(runuser -u nobody -- env VPSCTL_TESTING=0 VPSCTL_NON_INTERACTIVE=1 bash "$ENTRY" run debian 2>&1)" || STATUS=$?
        equal 4 "$STATUS" 'real unprivileged user is refused'
        contains "$OUTPUT" 'root' 'permission failure explained'
    else
        fail 'root/runuser needed for permission acceptance'
    fi
    new_case
    mkdir -p "$TEST_TEMP/no-curl"
    for tool in bash dirname uname flock mkdir chmod find readlink grep mktemp mv rm du; do
        source_path="$(type -P "$tool")"
        [[ "$tool" != rm ]] || source_path=/bin/rm
        ln -s "$source_path" "$TEST_TEMP/no-curl/$tool"
    done
    PATH="$TEST_TEMP/no-curl" invoke run debian
    equal 3 "$STATUS" 'missing curl is reported without implicit dependency install'
    contains "$OUTPUT" 'curl' 'missing dependency named'
    absent "$VPSCTL_SYSTEM_ROOT/var"
    new_case
    seed
    export MOCK_DOWNLOAD=fail
    PATH="$TEST_TEMP/no-curl" invoke reset
    equal 0 "$STATUS" 'retained reset does not require curl'
    new_case
    seed
    present "$VPSCTL_SYSTEM_ROOT/reinstall.log"
    mkdir -p "$TEST_TEMP/busybox"
    for tool in du rm mv find readlink; do
        ln -s "$(type -P busybox)" "$TEST_TEMP/busybox/$tool"
    done
    PATH="$TEST_TEMP/busybox:$PATH" invoke run debian
    equal 0 "$STATUS" 'BusyBox tools support download and replacement'
    PATH="$TEST_TEMP/busybox:$PATH" invoke status
    equal 0 "$STATUS" 'BusyBox du supports occupancy'
    PATH="$TEST_TEMP/busybox:$PATH" invoke uninstall
    equal 0 "$STATUS" 'BusyBox cleanup commands'
    absent "$VPSCTL_SYSTEM_ROOT/reinstall.log"
}

test_source_and_help
test_run_and_arguments
test_download_failure
test_reset_and_uninstall
test_partial_failures
test_boundaries
test_active_environment
test_lock_signals_and_terminal
test_permissions_dependencies_and_busybox
printf 'PASS: system reinstall unit tests (%s fixtures)\n' "$TEST_CASE"
