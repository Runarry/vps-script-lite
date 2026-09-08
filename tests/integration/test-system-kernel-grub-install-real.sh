#!/usr/bin/env bash
# Opt-in acceptance inside a disposable QEMU BIOS guest on host-vps-scripts.
# The host controller performs reboots between the explicit phases.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
readonly EVIDENCE=/root/vpsctl-bios-grub-evidence
readonly BACKUP_ROOT=/var/lib/vpsctl/system/kernel/backups

[[ "${VPSCTL_REAL_GRUB_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_GRUB_TEST=1 inside an isolated BIOS test guest\n'
    exit 0
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[[ "$EUID" == 0 && "$(uname -s)" == Linux ]] || fail 'Linux root is required'
[[ ! -d /sys/firmware/efi ]] || fail 'this acceptance must not modify a UEFI host'
[[ "$(cat /sys/class/dmi/id/bios_vendor)" == SeaBIOS ]] || fail 'SeaBIOS QEMU guest required'
[[ "$(cat /root/vpsctl-bios-grub-lab 2>/dev/null)" == VPSCTL-ISOLATED-BIOS-GRUB-VM ]] || fail 'isolated guest marker missing'
[[ "$(lsblk -dn -o TYPE /dev/vda)" == disk && "$(lsblk -dn -o TYPE /dev/vdb)" == disk ]] || fail 'dedicated vda and vdb disks required'
[[ "$(blockdev --getsize64 /dev/vdb)" == 67108864 ]] || fail 'vdb must be the dedicated 64 MiB data disk'

phase="${1:-}"
case "$phase" in prepare | install | first-boot | switch | second-boot | repair) ;; *) fail 'phase must be prepare, install, first-boot, switch, second-boot or repair' ;; esac
install -d -m 0700 "$EVIDENCE"
exec > >(tee -a "$EVIDENCE/$phase.log") 2>&1
printf 'phase=%s utc=%s\n' "$phase" "$(date -u +%FT%TZ)"

cli() {
    bash "$TEST_ROOT/bin/vpsctl" --no-color "$@"
}

read_state() {
    # Read the actual generated config with the same inventory used by status.
    # shellcheck source=/dev/null
    source "$TEST_ROOT/commands/system/kernel.sh"
    vps_cmd_init system-kernel "$TEST_ROOT"
    kernel_init_paths
    kernel_load_platform
    kernel_inventory_load
    kernel_grub_load
}

data_unchanged() {
    sha256sum -c "$EVIDENCE/data-before.sha256"
}

snapshot_readonly() {
    local path
    sha256sum /var/lib/dpkg/status /var/cache/debconf/config.dat
    for path in /etc/default/grub /etc/default/grub.d /boot/grub /etc/apt; do
        [[ ! -e "$path" ]] || find "$path" -type f -exec sha256sum {} +
    done
    dd if=/dev/vda bs=1M count=4 status=none | sha256sum
    if [[ -d "$BACKUP_ROOT" ]]; then
        find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'bios-grub.*' -print
    fi
}

check_installed() {
    local expected backup
    expected="$(cat "$EVIDENCE/expected-default")"
    [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' grub-pc)" == 'ii ' ]] || fail 'grub-pc not configured'
    [[ -s /boot/grub/i386-pc/normal.mod && -s /boot/grub/grub.cfg ]] || fail 'installed GRUB files incomplete'
    [[ -z "$(dpkg --audit)" ]] || fail 'dpkg audit is not clean'
    read_state
    [[ "$KERNEL_GRUB_SUPPORTED" == 1 && "$KERNEL_GRUB_DEFAULT_RELEASE" == "$expected" ]] || fail 'default kernel changed unexpectedly'
    [[ "$KERNEL_GRUB_NEXT_SELECTOR" == "$(cat "$EVIDENCE/expected-next")" ]] || fail 'next_entry differs from the approved plan'
    sfdisk --dump /dev/vda >"$EVIDENCE/partition-after.txt"
    cmp "$EVIDENCE/partition-before.txt" "$EVIDENCE/partition-after.txt"
    sha256sum -c "$EVIDENCE/retained-kernel.sha256"
    data_unchanged
    backup="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'bios-grub.*' | sort | tail -n 1)"
    [[ -n "$backup" && "$(stat -c %a "$backup")" == 700 ]] || fail 'restricted BIOS backup missing'
    [[ -s "$backup/disk-regions.tsv" && -s "$backup/RECOVERY.txt" && -s "$backup/transaction.log" ]] || fail 'recovery records missing'
    (cd "$backup" && sha256sum -c SHA256SUMS)
    printf '%s\n' "$backup" >"$EVIDENCE/latest-backup"
    printf 'GET grub-pc/install_devices\n' | DEBIAN_FRONTEND=noninteractive debconf-communicate grub-pc | tee "$EVIDENCE/debconf-target-after.txt"
    grep -Eq '^0 /dev/(vda|disk/by-id/[^ ,]+)$' "$EVIDENCE/debconf-target-after.txt" || fail 'debconf target did not become the approved disk'
    printf 'GET grub-pc/cloud_style_installation\n' | DEBIAN_FRONTEND=noninteractive debconf-communicate grub-pc | tee "$EVIDENCE/debconf-cloud-style-after.txt"
    grep -Fxq '0 false' "$EVIDENCE/debconf-cloud-style-after.txt" || fail 'cloud-style automatic disk selection is still enabled'
    printf 'current=%s default=%s next=%s\n' "$KERNEL_RUNNING_RELEASE" "$KERNEL_GRUB_DEFAULT_RELEASE" "${KERNEL_GRUB_NEXT_RELEASE:-none}"
}

case "$phase" in
    prepare)
        [[ ! -e "$EVIDENCE/prepared" ]] || fail 'prepare already ran; use a new disposable overlay'
        mode="${VPSCTL_REAL_GRUB_MODE:-preserve-invalid-next}"
        case "$mode" in preserve-invalid-next | preserve-valid-next | fallback) ;; *) fail 'unknown default/next scenario' ;; esac
        second="${VPSCTL_REAL_GRUB_SECOND_RELEASE:-}"
        [[ "$second" =~ ^[0-9]+\.[0-9]+[A-Za-z0-9.+_~-]*$ ]] || fail 'set the installed second kernel release'
        current="$(uname -r)"
        [[ "$current" != "$second" && -s "/boot/vmlinuz-$second" && -s "/boot/initrd.img-$second" && -d "/lib/modules/$second" ]] || fail 'second kernel must be complete and distinct'
        printf '%s\n' "$current" >"$EVIDENCE/expected-default"
        printf '%s\n' "$second" >"$EVIDENCE/second-release"
        printf '%s\n' "$mode" >"$EVIDENCE/scenario"
        cat /proc/sys/kernel/random/boot_id >"$EVIDENCE/boot-id-before"
        sfdisk --dump /dev/vda >"$EVIDENCE/partition-before.txt"
        sha256sum "/boot/vmlinuz-$current" "/boot/initrd.img-$current" "/boot/vmlinuz-$second" "/boot/initrd.img-$second" >"$EVIDENCE/retained-kernel.sha256"
        sha256sum /dev/vdb >"$EVIDENCE/data-before.sha256"
        tar -cpf "$EVIDENCE/grub-config-before.tar" /etc/default/grub /etc/default/grub.d /boot/grub
        if [[ "$mode" == fallback ]]; then
            mv /boot/grub/grub.cfg "$EVIDENCE/grub.cfg-unresolvable"
            grub-editenv /boot/grub/grubenv set next_entry=vpsctl-nonexistent-entry
            printf '\n' >"$EVIDENCE/expected-next"
        else
            read_state
            kernel_grub_load_config || true
            [[ "$KERNEL_GRUB_DEFAULT_RELEASE" == "$current" ]] || fail 'prepare must start with current kernel as the resolved default'
            if [[ "$mode" == preserve-valid-next ]]; then
                grub-editenv /boot/grub/grubenv set "next_entry=${KERNEL_GRUB_ENTRY[$current]}"
                printf '%s\n' "${KERNEL_GRUB_ENTRY[$current]}" >"$EVIDENCE/expected-next"
            else
                grub-editenv /boot/grub/grubenv set next_entry=vpsctl-nonexistent-entry
                printf '\n' >"$EVIDENCE/expected-next"
            fi
        fi
        if [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' grub-pc 2>/dev/null || true)" == 'ii ' ]]; then
            dpkg --remove grub-pc
        fi
        printf 'grub-pc grub-pc/install_devices multiselect /dev/vdb\ngrub-pc grub-pc/install_devices_disks_changed multiselect /dev/vdb\ngrub-pc grub-pc/install_devices_empty boolean false\n' | debconf-set-selections
        if grep -Eq '^ID="?ubuntu"?$' /etc/os-release; then
            printf 'grub-pc grub-pc/cloud_style_installation boolean true\n' | debconf-set-selections
        fi
        [[ -z "$(dpkg --audit)" ]] || fail 'preparation left incomplete package state'
        touch "$EVIDENCE/prepared"
        ;;
    install | repair)
        [[ -e "$EVIDENCE/prepared" ]] || fail 'prepare phase is required'
        snapshot_readonly | sort >"$EVIDENCE/$phase-readonly-before"
        cli --dry-run system kernel install-grub --disk /dev/vda
        snapshot_readonly | sort >"$EVIDENCE/$phase-readonly-after"
        cmp "$EVIDENCE/$phase-readonly-before" "$EVIDENCE/$phase-readonly-after"
        data_unchanged
        cli --non-interactive system kernel install-grub --disk /dev/vda --confirm-install-grub INSTALL-BIOS-GRUB
        check_installed
        [[ "$(cat /proc/sys/kernel/random/boot_id)" == "$(cat "$EVIDENCE/boot-id-before")" ]] || fail 'install-grub unexpectedly rebooted'
        ;;
    first-boot)
        [[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$EVIDENCE/boot-id-before")" ]] || fail 'no real reboot occurred'
        [[ "$(uname -r)" == "$(cat "$EVIDENCE/expected-default")" ]] || fail 'first reboot did not boot preserved/fallback kernel'
        cat /proc/sys/kernel/random/boot_id >"$EVIDENCE/boot-id-first"
        # GRUB consumes a valid next_entry during the first real boot.
        printf '\n' >"$EVIDENCE/expected-next"
        check_installed
        ;;
    switch)
        [[ -s "$EVIDENCE/boot-id-first" ]] || fail 'first-boot phase is required'
        second="$(cat "$EVIDENCE/second-release")"
        cli --non-interactive system kernel switch --release "$second" --confirm-switch SWITCH-KERNEL
        read_state
        [[ "$KERNEL_GRUB_DEFAULT_RELEASE" == "$second" && -z "$KERNEL_GRUB_NEXT_SELECTOR" ]] || fail 'switch did not fix the second kernel'
        data_unchanged
        ;;
    second-boot)
        [[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$EVIDENCE/boot-id-first")" ]] || fail 'second real reboot did not occur'
        [[ "$(uname -r)" == "$(cat "$EVIDENCE/second-release")" ]] || fail 'second reboot selected the wrong kernel'
        [[ -z "$(dpkg --audit)" ]] || fail 'final dpkg audit is not clean'
        data_unchanged
        cli system kernel status
        cat /proc/sys/kernel/random/boot_id >"$EVIDENCE/boot-id-second"
        date -u +%FT%TZ >"$EVIDENCE/completed"
        ;;
esac
printf 'PASS: BIOS GRUB real acceptance phase %s\n' "$phase"
