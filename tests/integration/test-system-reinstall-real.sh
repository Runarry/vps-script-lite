#!/usr/bin/env bash
# Opt-in checks inside the disposable SeaBIOS guest used for real reinstall acceptance.
# The host controls QEMU shutdown/reboot and retains the serial and SSH logs.
set -Eeuo pipefail

[[ "${VPSCTL_REAL_REINSTALL_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_REINSTALL_TEST=1 inside the isolated test guest\n'
    exit 0
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
phase="${1:-}"
[[ "$EUID" == 0 && "$(uname -s)" == Linux ]] || fail 'Linux root required'
[[ ! -d /sys/firmware/efi ]] || fail 'SeaBIOS guest required'
[[ "$(cat /sys/class/dmi/id/bios_vendor)" == SeaBIOS ]] || fail 'QEMU SeaBIOS guest required'
[[ -b /dev/vda ]] || fail 'virtual vda disk required'

case "$phase" in
    build-target | before | prepared | clean)
        [[ "$(cat /root/vpsctl-reinstall-guest-marker 2>/dev/null)" == VPSCTL-REINSTALL-DISPOSABLE-BIOS ]] || fail 'source guest marker missing'
        ;;
    dd-boot | seed-residues | dd-clean)
        [[ "$(cat /root/vpsctl-reinstall-dd-marker 2>/dev/null)" == VPSCTL-REINSTALL-DD-TARGET ]] || fail 'DD target marker missing'
        [[ ! -e /root/vpsctl-reinstall-guest-marker ]] || fail 'old guest marker survived DD'
        ;;
    *) fail 'phase must be build-target, before, prepared, clean, dd-boot, seed-residues, or dd-clean' ;;
esac

case "$phase" in
    build-target)
        [[ "$(blockdev --getsize64 /dev/vdb)" == 671088640 ]] || fail 'expected dedicated 640 MiB RAW target on vdb'
        [[ "$(lsblk -dn -o TYPE /dev/vdb)" == disk ]] || fail 'vdb is not a disk'
        [[ "$(blkid -s TYPE -o value /dev/vdb1)" == ext4 ]] || fail 'vdb1 is not ext4'
        uuid="$(blkid -s UUID -o value /dev/vdb1)"
        [[ "$uuid" == 7af5430b-f94c-484c-8fe6-36878b6de03a ]] || fail 'unexpected Alpine target UUID'
        target=/mnt/vpsctl-reinstall-target
        mkdir -p "$target"
        [[ ! -e "$target/boot" ]] || fail 'target mountpoint is not empty'
        mount /dev/vdb1 "$target"
        trap 'umount /mnt/vpsctl-reinstall-target' EXIT
        [[ "$(cat "$target/root/vpsctl-reinstall-dd-marker")" == VPSCTL-REINSTALL-DD-TARGET ]] || fail 'target image marker missing'
        [[ -s "$target/boot/vmlinuz-virt" && -s "$target/boot/initramfs-virt" ]] || fail 'Alpine kernel or initramfs missing'
        grub-install --target=i386-pc --boot-directory="$target/boot" --no-floppy --recheck /dev/vdb
        cat >"$target/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=1
serial --unit=0 --speed=115200
terminal_input serial
terminal_output serial
menuentry 'Alpine reinstall DD target' {
    search --no-floppy --fs-uuid --set=root $uuid
    linux /boot/vmlinuz-virt root=LABEL=/ modules=sd-mod,usb-storage,ext4,ena,gve,mana console=ttyS0,115200n8 console=ttyAMA0,115200n8 console=tty0
    initrd /boot/initramfs-virt
}
EOF
        printf 'UUID=%s / ext4 defaults,noatime 1 1\n' "$uuid" >"$target/etc/fstab"
        sync
        umount "$target"
        trap - EXIT
        sfdisk -d /dev/vdb
        partx -s /dev/vdb
        ;;
    before)
        [[ "$(findmnt -n -o SOURCE /)" == /dev/vda1 ]] || fail 'root is not the disposable vda partition'
        printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
        printf 'root_uuid=%s\n' "$(findmnt -n -o UUID /)"
        printf 'bios_vendor=%s\n' "$(cat /sys/class/dmi/id/bios_vendor)"
        printf 'grub_next=%s\n' "$(grub-editenv /boot/grub/grubenv list 2>/dev/null || true)"
        ;;
    prepared)
        [[ -s /reinstall-vmlinuz && -s /reinstall-initrd ]] || fail 'upstream boot resources missing'
        [[ -d /reinstall-tmp ]] || fail 'upstream work directory missing'
        found_entry=0
        for cfg in /boot/grub/grub.cfg /boot/grub/custom.cfg; do
            [[ ! -f "$cfg" ]] || ! grep -Fq '### BEGIN reinstall.sh ###' "$cfg" || found_entry=1
        done
        [[ "$found_entry" == 1 ]] || fail 'GRUB reinstall entry missing'
        grub-editenv /boot/grub/grubenv list | grep -q '^next_entry=' || fail 'one-shot GRUB entry missing'
        printf 'kernel_bytes=%s initrd_bytes=%s\n' "$(stat -c %s /reinstall-vmlinuz)" "$(stat -c %s /reinstall-initrd)"
        grub-editenv /boot/grub/grubenv list
        ;;
    clean)
        for path in /reinstall-tmp /reinstall.log /reinstall-vmlinuz /reinstall-initrd /reinstall-firmware \
            /boot/reinstall-vmlinuz /boot/reinstall-initrd /boot/reinstall-firmware; do
            [[ ! -e "$path" ]] || fail "residue remains: $path"
        done
        for cfg in /boot/grub/grub.cfg /boot/grub/custom.cfg; do
            if [[ -f "$cfg" ]] && grep -Eq '### BEGIN reinstall\.sh ###|reinstall-(vmlinuz|initrd|firmware)' "$cfg"; then
                fail "GRUB reinstall entry remains: $cfg"
            fi
        done
        ! grub-editenv /boot/grub/grubenv list | grep -q '^next_entry=' || fail 'one-shot GRUB entry remains'
        printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
        ;;
    dd-boot)
        root_source="$(awk '$2 == "/" { print $1; exit }' /proc/mounts)"
        [[ "$root_source" == /dev/vda* ]] || fail 'DD image root is not on vda'
        printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
        printf 'root_source=%s\n' "$root_source"
        grep -E '^UUID=' /etc/fstab
        cat /etc/os-release
        ;;
    seed-residues)
        [[ ! -e /var/lib/vpsctl/reinstall ]] || fail 'old wrapper state unexpectedly exists'
        for path in /reinstall-tmp /reinstall.log /reinstall-vmlinuz /reinstall-initrd /reinstall-firmware \
            /boot/reinstall-vmlinuz /boot/reinstall-initrd /boot/reinstall-firmware; do
            [[ ! -e "$path" ]] || fail "fixture path already exists: $path"
        done
        mkdir /reinstall-tmp
        printf 'disposable residue\n' >/reinstall-tmp/marker
        for path in /reinstall.log /reinstall-vmlinuz /reinstall-initrd /reinstall-firmware \
            /boot/reinstall-vmlinuz /boot/reinstall-initrd /boot/reinstall-firmware; do
            printf 'disposable residue\n' >"$path"
        done
        ;;
    dd-clean)
        [[ ! -e /var/lib/vpsctl/reinstall ]] || fail 'wrapper state remains'
        for path in /reinstall-tmp /reinstall.log /reinstall-vmlinuz /reinstall-initrd /reinstall-firmware \
            /boot/reinstall-vmlinuz /boot/reinstall-initrd /boot/reinstall-firmware; do
            [[ ! -e "$path" ]] || fail "residue remains: $path"
        done
        printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"
        ;;
esac
printf 'PASS: real reinstall guest phase %s\n' "$phase"
