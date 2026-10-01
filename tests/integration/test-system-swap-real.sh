#!/usr/bin/env bash
# Opt-in acceptance on host-vps-scripts or its isolated Alpine guest.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
[[ "${VPSCTL_REAL_SWAP_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_SWAP_TEST=1 in the dedicated test environment\n'
    exit 0
}
((EUID == 0)) || exit 4
PHASE="${1:-run}"
case "$PHASE" in run | prepare-reboot | finish-reboot | restore) ;; *) exit 2 ;; esac
RESULT="${VPSCTL_SWAP_RESULT_DIR:-}"
[[ "$RESULT" == /* && "$RESULT" != / && "$RESULT" != *[[:space:]]* && "$RESULT" != *'/../'* ]] || {
    printf 'FAIL: supply an absolute VPSCTL_SWAP_RESULT_DIR\n' >&2
    exit 2
}
mkdir -p -- "$RESULT"
exec > >(tee -a "$RESULT/acceptance.log") 2>&1
printf 'phase=%s source=%s\n' "$PHASE" "$TEST_ROOT"
sha256sum "$TEST_ROOT/commands/system/swap.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
vpsctl() { bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes "$@"; }
active() { swapon --show=NAME,TYPE,SIZE,USED,PRIO --bytes --raw --noheadings; }
current_file() {
    local name type _size _used _priority
    while IFS=' ' read -r name type _size _used _priority; do
        [[ "$type" != file ]] || printf '%s\n' "$name"
    done < <(active)
}
check_only_file() {
    local bytes="$1" output path
    output="$(active)"
    [[ -n "$output" && "$output" != *$'\n'* ]] || fail 'expected exactly one active swap'
    path="$(current_file)"
    [[ "$path" == /var/lib/vpsctl/system/swap/swap.* && -f "$path" ]] || fail 'unexpected active swap file'
    [[ "$(stat -c %s "$path")" == "$bytes" ]] || fail 'wrong swap file capacity'
    [[ "$(stat -c '%u:%g:%a' "$path")" == 0:0:600 ]] || fail 'wrong swap permissions'
    printf '%s\n' "$path"
}
reload_boot() {
    if [[ -d /run/systemd/system ]]; then systemctl daemon-reload; fi
}
check_non_swap() {
    awk '$3 != "swap"' /etc/fstab >"$RESULT/non-swap.after"
    cmp "$RESULT/non-swap.before" "$RESULT/non-swap.after" || fail 'unrelated fstab lines changed'
    [[ "$(cat /proc/sys/vm/swappiness)" == "$(cat "$RESULT/swappiness.before")" ]] || fail 'swappiness changed'
}
restore() {
    local status=0 path type _size _used priority extra active_path _active_rest found checkpoint
    [[ -f "$RESULT/baseline-ready" ]] || return 0
    # Re-enable original partitions before dropping test capacity.
    while IFS=' ' read -r path type _size _used priority extra; do
        [[ -n "$path" ]] || continue
        [[ "$type" == partition && "$path" == /dev/* && -b "$path" && -z "$extra" ]] || return 30
        found=0
        while IFS=' ' read -r active_path _active_rest; do
            [[ "$active_path" != "$path" ]] || found=1
        done < <(active)
        ((found == 0)) || continue
        if [[ "$priority" == -* ]]; then
            swapon -- "$path" || status=30
        else swapon --priority "$priority" -- "$path" || status=30; fi
    done <"$RESULT/swaps.before"
    ((status == 0)) || return "$status"
    while IFS=' ' read -r path type _size _used priority; do
        [[ "$type" == file ]] || continue
        case "$path" in
            /var/lib/vpsctl/system/swap/swap.* | "$RESULT/legacy.swap")
                swapoff -- "$path" || {
                    status=30
                    continue
                }
                [[ -f "$path" && ! -L "$path" ]] || {
                    status=30
                    continue
                }
                rm -f -- "$path" || status=30
                ;;
            *)
                printf 'Unknown active file left intact: %s\n' "$path"
                status=30
                ;;
        esac
    done < <(active)
    # A reboot failure can leave our known file inactive. Do not infer ownership
    # from its name alone: match the inode and size recorded before the reboot.
    for checkpoint in 256 before-reboot; do
        [[ -f "$RESULT/file.$checkpoint" && -f "$RESULT/inode.$checkpoint" ]] || continue
        path="$(cat "$RESULT/file.$checkpoint")"
        [[ "$path" == /var/lib/vpsctl/system/swap/swap.* ]] || {
            status=30
            continue
        }
        [[ -e "$path" || -L "$path" ]] || continue
        found=0
        while IFS=' ' read -r active_path _active_rest; do
            [[ "$active_path" != "$path" ]] || found=1
        done < <(active)
        if ((found == 0)) && [[ -f "$path" && ! -L "$path" && "$(stat -c '%d:%i:%s' "$path")" == "$(cat "$RESULT/inode.$checkpoint")" && "$(blkid -p -s TYPE -o value "$path")" == swap ]]; then
            rm -- "$path" || status=30
        else
            printf 'Checkpoint file identity or activity changed, retaining: %s\n' "$path"
            status=30
        fi
    done
    cp -p -- "$RESULT/fstab.before" /etc/fstab || status=30
    reload_boot || status=30
    if [[ -f "$RESULT/openrc-conf.before" ]]; then
        cp -p -- "$RESULT/openrc-conf.before" /etc/conf.d/swap || status=30
    elif [[ -f "$RESULT/openrc-conf.absent" ]]; then
        rm -f -- /etc/conf.d/swap || status=30
    fi
    if [[ -f "$RESULT/openrc-boot.before" && "$(cat "$RESULT/openrc-boot.before")" == absent ]]; then
        rc-update del swap boot || status=30
    fi
    if [[ -f "$RESULT/openrc-boot.before" ]]; then rc-update -u || status=30; fi
    if [[ -f "$RESULT/legacy.swap" && ! -L "$RESULT/legacy.swap" ]]; then rm -f -- "$RESULT/legacy.swap" || status=30; fi
    active >"$RESULT/swaps.restored"
    cmp /etc/fstab "$RESULT/fstab.before" || status=30
    awk '{print $1, $2}' "$RESULT/swaps.before" | sort >"$RESULT/sources.before"
    awk '{print $1, $2}' "$RESULT/swaps.restored" | sort >"$RESULT/sources.restored"
    cmp "$RESULT/sources.before" "$RESULT/sources.restored" || status=30
    ((status != 0)) || printf 'PASS: original swap sources and fstab restored\n'
    return "$status"
}
HOLD_FOR_REBOOT=0
cleanup() {
    local status="$?"
    trap - EXIT
    if [[ "$HOLD_FOR_REBOOT" != 1 ]]; then restore || status=30; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$PHASE" == restore ]]; then exit 0; fi
if [[ "$PHASE" == finish-reboot ]]; then
    [[ -f "$RESULT/reboot-ready" && -f "$RESULT/baseline-ready" ]] || fail 'no prepared reboot test'
    [[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$RESULT/boot.before")" ]] || fail 'machine has not rebooted'
    [[ "$(check_only_file 536870912)" == "$(cat "$RESULT/file.before-reboot")" ]] || fail 'wrong swap after reboot'
    check_non_swap
    printf 'PASS: real reboot retained only the requested swap file\n'
else
    [[ ! -e "$RESULT/baseline-ready" ]] || fail 'result directory already contains an acceptance run'
    # This acceptance deletes old swap files: require a restorable partition-only baseline.
    active >"$RESULT/swaps.before"
    while IFS=' ' read -r path type _; do
        [[ -z "$path" || ("$type" == partition && "$path" == /dev/* && -b "$path") ]] || fail 'pre-existing active swap file is outside acceptance scope'
    done <"$RESULT/swaps.before"
    while IFS= read -r path; do
        [[ -z "$path" || ("$path" == /dev/* && -b "$path") ]] || fail 'pre-existing fstab swap file is outside acceptance scope'
    done < <(findmnt --fstab --evaluate --types swap --noheadings --raw --output SOURCE || true)
    cp -p /etc/fstab "$RESULT/fstab.before"
    awk '$3 != "swap"' /etc/fstab >"$RESULT/non-swap.before"
    cat /proc/sys/vm/swappiness >"$RESULT/swappiness.before"
    cat /proc/sys/kernel/random/boot_id >"$RESULT/boot.before"
    if command -v rc-update >/dev/null 2>&1; then
        if [[ -e /etc/runlevels/boot/swap ]]; then printf 'present\n'; else printf 'absent\n'; fi >"$RESULT/openrc-boot.before"
        if [[ -f /etc/conf.d/swap && ! -L /etc/conf.d/swap ]]; then
            cp -p /etc/conf.d/swap "$RESULT/openrc-conf.before"
        elif [[ ! -e /etc/conf.d/swap && ! -L /etc/conf.d/swap ]]; then
            touch "$RESULT/openrc-conf.absent"
        else
            fail 'unsupported pre-existing OpenRC configuration path'
        fi
    fi
    touch "$RESULT/baseline-ready"
    vpsctl system swap status
    dd if=/dev/zero "of=$RESULT/legacy.swap" bs=1M count=64 conv=fsync
    chmod 0600 "$RESULT/legacy.swap"
    mkswap "$RESULT/legacy.swap"
    swapon --priority 23 "$RESULT/legacy.swap"
    printf '%s none swap sw,pri=23 0 0\n' "$RESULT/legacy.swap" >>/etc/fstab
    reload_boot
    vpsctl system swap set --size 256M
    check_only_file 268435456 >"$RESULT/file.256"
    [[ ! -e "$RESULT/legacy.swap" ]] || fail 'old swap file was not removed'
    check_non_swap
    cp /etc/fstab "$RESULT/fstab.256"
    stat -c '%d:%i:%s' "$(cat "$RESULT/file.256")" >"$RESULT/inode.256"
    vpsctl system swap set --size 256M
    cmp /etc/fstab "$RESULT/fstab.256" || fail 'repeat changed fstab'
    [[ "$(stat -c '%d:%i:%s' "$(cat "$RESULT/file.256")")" == "$(cat "$RESULT/inode.256")" ]] || fail 'repeat recreated swap'
    printf 'PASS: mixed takeover, file cleanup and idempotence\n'
    vpsctl system swap set --size 512M
    check_only_file 536870912 >"$RESULT/file.before-reboot"
    stat -c '%d:%i:%s' "$(cat "$RESULT/file.before-reboot")" >"$RESULT/inode.before-reboot"
    [[ ! -e "$(cat "$RESULT/file.256")" ]] || fail 'old managed file was not removed after resize'
    cp /etc/fstab "$RESULT/fstab.512"
    active >"$RESULT/swaps.512"
    bash "$TEST_ROOT/bin/vpsctl" --dry-run --non-interactive system swap set --size 64M
    cmp /etc/fstab "$RESULT/fstab.512" || fail 'dry-run changed fstab'
    [[ "$(current_file)" == "$(cat "$RESULT/file.before-reboot")" ]] || fail 'dry-run changed active swap'
    check_non_swap
    printf 'PASS: resize and dry-run preservation\n'
    if [[ "$PHASE" == prepare-reboot ]]; then
        touch "$RESULT/reboot-ready"
        HOLD_FOR_REBOOT=1
        printf 'READY: reboot, then run finish-reboot with VPSCTL_SWAP_RESULT_DIR=%s\n' "$RESULT"
        exit 0
    fi
fi
vpsctl system swap set --size 256M
check_only_file 268435456 >/dev/null
vpsctl system swap disable
[[ -z "$(active)" ]] || fail 'disable left active swap'
check_non_swap
cp /etc/fstab "$RESULT/fstab.disabled"
vpsctl system swap disable
cmp /etc/fstab "$RESULT/fstab.disabled" || fail 'repeat disable changed fstab'
printf 'PASS: shrink, disable and repeated disable\n'
