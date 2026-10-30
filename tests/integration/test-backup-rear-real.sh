#!/usr/bin/env bash
# Dedicated host-vps-scripts fixture. Never run against a production host.
set -Eeuo pipefail
umask 077
[[ ${VPSCTL_BACKUP_REAL:-0} == 1 && $EUID == 0 ]] || { echo 'Set VPSCTL_BACKUP_REAL=1 on host-vps-scripts'; exit 3; }
[[ $(hostname) == debian-vps-script ]] || exit 3
LAB=${VPSCTL_BACKUP_LAB:-/var/tmp/vpsctl-backup-acceptance-20261030}
[[ $LAB == /var/tmp/vpsctl-backup-acceptance-* && $LAB != *..* ]] || exit 3
mkdir -p "$LAB/evidence"
exec > >(tee -a "$LAB/evidence/rear-fixture.log") 2>&1
case ${1:-status} in
prepare)
    [[ ! -e $LAB/source.raw && ! -e $LAB/guest ]] || { echo 'Fixture already exists; inspect before continuing'; exit 3; }
    avail=$(df -B1 --output=avail "$LAB" | tail -1)
    ((avail > 2800000000)) || { echo "Insufficient fixture budget: $avail"; exit 3; }
    df -h "$LAB"
    free -h
    qemu-system-x86_64 -accel help
    truncate -s 3G "$LAB/source.raw"
    printf 'label: dos\nstart=2048, type=83, bootable\n' | sfdisk "$LAB/source.raw"
    loop=$(losetup --find --show --partscan "$LAB/source.raw")
    [[ $(losetup -n -O BACK-FILE "$loop") == "$LAB/source.raw" ]] || exit 3
    trap 'mountpoint -q "$LAB/guest/dev/pts" && umount "$LAB/guest/dev/pts"; mountpoint -q "$LAB/guest/dev" && umount "$LAB/guest/dev"; mountpoint -q "$LAB/guest/proc" && umount "$LAB/guest/proc"; mountpoint -q "$LAB/guest/sys" && umount "$LAB/guest/sys"; mountpoint -q "$LAB/guest" && umount "$LAB/guest"; losetup -d "$loop"' EXIT
    mkfs.ext4 -q -L VPSCTL_BACKUP_TEST "${loop}p1"
    mkdir "$LAB/guest"
    mount "${loop}p1" "$LAB/guest"
    debootstrap --variant=minbase --include=systemd-sysv,udev,openssh-server,iproute2,ifupdown,isc-dhcp-client,rear,grub-pc,linux-image-amd64,restic,ca-certificates,curl,procps,python3,jq,docker.io,docker-cli,file,less trixie "$LAB/guest" http://deb.debian.org/debian
    mount --bind /dev "$LAB/guest/dev"
    mount -t devpts devpts "$LAB/guest/dev/pts"
    mount -t proc proc "$LAB/guest/proc"
    mount -t sysfs sys "$LAB/guest/sys"
    printf 'vpsctl-backup-test-source\n' > "$LAB/guest/etc/hostname"
    printf '/dev/vda1 / ext4 defaults 0 1\n' > "$LAB/guest/etc/fstab"
    printf 'auto lo\niface lo inet loopback\nauto ens3\niface ens3 inet dhcp\n' > "$LAB/guest/etc/network/interfaces"
    printf 'GRUB_CMDLINE_LINUX="console=ttyS0,115200 net.ifnames=1"\nGRUB_TERMINAL=serial\nGRUB_SERIAL_COMMAND="serial --speed=115200"\nGRUB_TIMEOUT=1\n' > "$LAB/guest/etc/default/grub"
    mkdir -p "$LAB/guest/root/.ssh" "$LAB/guest/etc/ssh/sshd_config.d"
    ssh-keygen -q -t ed25519 -N '' -f "$LAB/guest-key"
    cp "$LAB/guest-key.pub" "$LAB/guest/root/.ssh/authorized_keys"
    printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\n' > "$LAB/guest/etc/ssh/sshd_config.d/acceptance.conf"
    chroot "$LAB/guest" passwd -d root
    chroot "$LAB/guest" grub-install --target=i386-pc --recheck "$loop"
    chroot "$LAB/guest" update-grub
    chroot "$LAB/guest" systemctl enable ssh
    find "$LAB/guest/var/cache/apt/archives" -type f -name '*.deb' -delete
    cp "$LAB/guest"/boot/vmlinuz-* "$LAB/vmlinuz"
    cp "$LAB/guest"/boot/initrd.img-* "$LAB/initrd"
    printf 'VPSCTL-ISOLATED-BACKUP-TEST\n' > "$LAB/guest/root/vpsctl-backup-lab"
    printf 'system-business-data-20261030\n' > "$LAB/guest/root/business-proof.txt"
    sync
    echo 'PASS: prepared independent Debian13 BIOS/ext4 source disk'
    ;;
boot)
    [[ -f $LAB/source.raw && ! -f $LAB/qemu.pid ]] || exit 3
    holding=()
    [[ ! -f $LAB/holding.raw ]] || holding=(-drive "file=$LAB/holding.raw,format=raw,if=virtio,discard=unmap,detect-zeroes=unmap")
    qemu-system-x86_64 -accel tcg -machine pc -cpu max -m 768 -smp 2 \
        -drive "file=$LAB/source.raw,format=raw,if=virtio,discard=unmap,detect-zeroes=unmap" \
        "${holding[@]}" \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:22440-:22 -device virtio-net-pci,netdev=n0 \
        -display none -serial "file:$LAB/evidence/source-console.log" \
        -monitor "unix:$LAB/monitor.sock,server=on,wait=off" -daemonize -pidfile "$LAB/qemu.pid"
    echo 'Started isolated TCG source guest; SSH 127.0.0.1:22440'
    ;;
holding)
    [[ ! -e $LAB/holding.raw ]] || exit 3
    truncate -s 3G "$LAB/holding.raw"
    mkfs.ext4 -q -L BACKUP_HOLDING "$LAB/holding.raw"
    echo 'Prepared separate 3GiB sparse holding disk; attach as vdb on next guest boot'
    ;;
guest-fixture)
    ssh -p 22440 -i "$LAB/guest-key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 bash -s <<'GUEST'
set -Eeuo pipefail
[[ $(cat /root/vpsctl-backup-lab) == VPSCTL-ISOLATED-BACKUP-TEST ]] || exit 3
mkdir -p /srv/business
printf 'whole-system-upload\n' > /srv/business/upload.txt
python3 - <<'PY'
import sqlite3
db=sqlite3.connect('/srv/business/business.db')
db.execute('create table orders(id integer primary key, total integer)')
db.executemany('insert into orders values (?,?)', [(1, 4225), (2, 1775)])
db.commit()
db.close()
PY
docker volume create vpsctl-backup-test-system
docker run -d --name vpsctl-backup-test-system --restart unless-stopped --mount type=volume,src=vpsctl-backup-test-system,dst=/data --mount type=bind,src=/srv/business,dst=/business debian:bookworm-slim sh -c 'trap "exit 0" TERM; while :; do sleep 1 & wait "$!"; done'
docker exec vpsctl-backup-test-system sh -c 'printf "whole-system-volume\n" > /data/volume.txt; printf "whole-system-writable\n" > /root/writable.txt'
docker info --format '{{.ServerVersion}} {{.DockerRootDir}}'
sha256sum /srv/business/* /root/business-proof.txt > /root/business-before.sha256
fstrim -v /
df -h / /mnt/holding
GUEST
    ;;
trim-offline)
    [[ ! -f $LAB/qemu.pid ]] || { echo 'Shut down the fixture guest first'; exit 3; }
    [[ -f $LAB/holding.raw && ! -L $LAB/holding.raw && ! -L $LAB/holding-mount ]] || exit 3
    loop=$(losetup --find --show "$LAB/holding.raw")
    [[ $(losetup -n -O BACK-FILE "$loop") == "$LAB/holding.raw" ]] || exit 3
    [[ $(blkid -s LABEL -o value "$loop") == BACKUP_HOLDING ]] || exit 3
    mkdir -p "$LAB/holding-mount"
    trap 'mountpoint -q "$LAB/holding-mount" && umount "$LAB/holding-mount"; losetup -d "$loop"' EXIT
    mount "$loop" "$LAB/holding-mount"
    fstrim -v "$LAB/holding-mount"
    df -h "$LAB"
    ;;
pull-recovery)
    SOURCE=${VPSCTL_BACKUP_SOURCE:-/var/tmp/vpsctl-backup-implementation/source}
    snapshot=${VPSCTL_BACKUP_SNAPSHOT:?Set the complete remote system snapshot ID}
    [[ $snapshot =~ ^[a-f0-9]{64}$ && ! -f $LAB/qemu.pid ]] || exit 3
    export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$LAB/root"
    bash "$SOURCE/bin/vpsctl" --yes --non-interactive system backup-repo configure system-s3 --type s3 \
        --endpoint http://127.0.0.1:18442 --bucket backup-test --prefix whole-system --region us-east-1 --bucket-lookup path \
        --credentials-file "$LAB/s3-credentials.json" --password-file "$LAB/password" --allow-http
    source "$SOURCE/lib/command.sh"
    source "$SOURCE/lib/backup.sh"
    vps_cmd_init system-backup-repo "$SOURCE"
    backup_init "$SOURCE"
    backup_snapshot_validate system-s3 "$snapshot" system
    loop=$(losetup --find --show "$LAB/holding.raw")
    [[ $(losetup -n -O BACK-FILE "$loop") == "$LAB/holding.raw" ]] || exit 3
    [[ $(blkid -s LABEL -o value "$loop") == BACKUP_HOLDING ]] || exit 3
    mkdir -p "$LAB/holding-mount"
    trap 'mountpoint -q "$LAB/holding-mount" && umount "$LAB/holding-mount"; losetup -d "$loop"' EXIT
    mount "$loop" "$LAB/holding-mount"
    # The complete remote recovery point has been independently validated above.
    # Remove only this lab's old local collection before downloading it afresh.
    [[ -d $LAB/holding-mount/staging && ! -L $LAB/holding-mount/staging ]] || exit 3
    rm -rf -- "$LAB/holding-mount/staging"
    sync
    fstrim -v "$LAB/holding-mount"
    target="$LAB/holding-mount/recovery/$snapshot/payload"
    backup_restore_snapshot system-s3 "$snapshot" "$target" system
    tar -tf "$target/netfs/system/backup.tar" >/dev/null
    cp "$target/manifest.json" "$LAB/evidence/system-$snapshot-manifest.json"
    cp "$target/manifest.json" "$LAB/evidence/system-remote-restored-manifest.json"
    cp "$target/rear-state/layout/disklayout.conf" "$LAB/evidence/system-restored-disklayout.conf"
    printf '%s\n' "$snapshot" > "$LAB/holding-mount/recovery/$snapshot/snapshot-id"
    mkdir -p "$LAB/holding-mount/tools"
    cp "$LAB/password" "$LAB/s3-credentials.json" "$LAB/holding-mount/tools/"
    bash "$SOURCE/bin/vpsctl" --yes --non-interactive system backup-repo configure system-recovery --type s3 \
        --endpoint http://10.0.2.2:18442 --bucket backup-test --prefix whole-system --region us-east-1 --bucket-lookup path \
        --credentials-file "$LAB/s3-credentials.json" --password-file "$LAB/password" --allow-http
    plan=$(jq '.id="acceptance-system-export" | .repo="system-recovery"' "$LAB/evidence/system-source-plan.json")
    backup_plan_write acceptance-system-export system "$plan"
    bash "$SOURCE/bin/vpsctl" --yes --non-interactive system backup export-recovery acceptance-system-export --output "$LAB/holding-mount/tools/recovery-kit"
    sync
    printf '%s\n' "$snapshot" > "$LAB/evidence/system-material-readback-$snapshot.ok"
    echo 'PASS: remote complete snapshot downloaded afresh, full content hashes and tar readability verified on separate holding disk'
    ;;
remove-source)
    snapshot=$(cat "$LAB/system-snapshot")
    [[ ! -f $LAB/qemu.pid && -f $LAB/evidence/system-remote-restored-manifest.json && -s $LAB/evidence/system-material-readback-$snapshot.ok ]] || exit 3
    [[ -f $LAB/source.raw && ! -L $LAB/source.raw && ! -f $LAB/restored.raw ]] || exit 3
    sha256sum "$LAB/source.raw" > "$LAB/evidence/deleted-source-$snapshot.sha256"
    rm -- "$LAB/source.raw"
    echo 'PASS: original source VM disk removed after complete remote readback; subsequent recovery cannot read it'
    ;;
copy-rescue-iso)
    snapshot=$(cat "$LAB/system-snapshot")
    [[ $snapshot =~ ^[a-f0-9]{64}$ && ! -f $LAB/qemu.pid && ! -e $LAB/source.raw && ! -e $LAB/rescue.iso ]] || exit 3
    loop=$(losetup --read-only --find --show "$LAB/holding.raw")
    [[ $(losetup -n -O BACK-FILE "$loop") == "$LAB/holding.raw" ]] || exit 3
    trap 'mountpoint -q "$LAB/holding-mount" && umount "$LAB/holding-mount"; losetup -d "$loop"' EXIT
    mount -o ro "$loop" "$LAB/holding-mount"
    payload="$LAB/holding-mount/recovery/$snapshot/payload"
    iso=$(jq -r .rear.iso "$payload/manifest.json")
    [[ $iso == iso/*.iso && $iso != *..* ]] || exit 3
    cp "$payload/$iso" "$LAB/rescue.iso"
    sync
    ;;
boot-rescue)
    [[ ! -f $LAB/qemu.pid && ! -e $LAB/source.raw && ! -e $LAB/restored.raw && -s $LAB/rescue.iso ]] || exit 3
    truncate -s 3G "$LAB/restored.raw"
    snapshot=$(cat "$LAB/system-snapshot")
    [[ $snapshot =~ ^[a-f0-9]{64}$ ]] || exit 3
    qemu-system-x86_64 -accel tcg -machine pc -cpu max -m 1024 -smp 2 \
        -drive "file=$LAB/restored.raw,format=raw,if=virtio,discard=unmap,detect-zeroes=unmap" \
        -drive "file=$LAB/holding.raw,format=raw,if=virtio,discard=unmap,detect-zeroes=unmap" \
        -cdrom "$LAB/rescue.iso" -boot order=d \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:22440-:22 -device virtio-net-pci,netdev=n0 \
        -display none -serial "file:$LAB/evidence/rescue-$snapshot-console.log" \
        -monitor "unix:$LAB/monitor.sock,server=on,wait=off" -daemonize -pidfile "$LAB/qemu.pid"
    echo 'Started matching ReaR rescue ISO with an empty vda and separate preserved vdb'
    ;;
rescue-restore)
    snapshot=$(cat "$LAB/system-snapshot")
    [[ $snapshot =~ ^[a-f0-9]{64}$ ]] || exit 3
    ssh -p 22440 -i "$LAB/guest-key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 "SNAPSHOT=$snapshot bash -s" <<'RESCUE'
set -Eeuo pipefail
[[ -f /etc/rear-release && $(blockdev --getsize64 /dev/vda) == 3221225472 ]] || exit 3
mkdir -p /mnt/holding
mountpoint -q /mnt/holding || mount /dev/vdb /mnt/holding
[[ $(findmnt -rn -o SOURCE -T /mnt/holding) == /dev/vdb ]] || exit 3
mkdir -p /mnt/holding/evidence
exec > >(tee -a /mnt/holding/evidence/rescue-restore-controller.log) 2>&1
[[ ! -d /etc/vpsctl/backup/plans && ! -d /var/lib/vpsctl/backup/jobs ]] || exit 3
kit=/mnt/holding/tools/recovery-kit
cli() { "$kit/recover.sh" --yes --non-interactive "$@"; }
"$kit/recover.sh" import-repo /mnt/holding/tools/password /mnt/holding/tools/s3-credentials.json
base=(--repo system-recovery --snapshot "$SNAPSHOT" --work-dir /mnt/holding/recovery --mode clone --network dhcp --interface ens3 --dns 10.0.2.3)
dd if=/dev/vda bs=1M count=1 status=none | sha256sum > /mnt/holding/evidence/blank-disk-before.sha256
holding_uuid=$(blkid -s UUID -o value /dev/vdb)
status=0
cli restore-plan "${base[@]}" --disk-map /dev/vda=/dev/vdb > /mnt/holding/evidence/holding-rejected.log 2>&1 || status=$?
[[ $status != 0 ]]
grep -E '活动挂载|保存盘|恢复材料' /mnt/holding/evidence/holding-rejected.log
cli restore-plan "${base[@]}" --disk-map /dev/vda=/dev/vda > /mnt/holding/evidence/system-restore-plan.log
token=$(sed -n 's/.*--confirm-restore \(restore-[a-f0-9]*\).*/\1/p' /mnt/holding/evidence/system-restore-plan.log | tail -1)
[[ $token =~ ^restore-[a-f0-9]{64}$ ]] || exit 3
status=0
cli restore "${base[@]}" --disk-map /dev/vda=/dev/vda --confirm-restore restore-wrong > /mnt/holding/evidence/wrong-token-rejected.log 2>&1 || status=$?
[[ $status == 2 ]]
grep -F '确认令牌' /mnt/holding/evidence/wrong-token-rejected.log
dd if=/dev/vda bs=1M count=1 status=none | sha256sum > /mnt/holding/evidence/blank-disk-after-negative.sha256
cmp /mnt/holding/evidence/blank-disk-before.sha256 /mnt/holding/evidence/blank-disk-after-negative.sha256
[[ $(blkid -s UUID -o value /dev/vdb) == "$holding_uuid" ]]
cli restore "${base[@]}" --disk-map /dev/vda=/dev/vda --confirm-restore "$token" > /mnt/holding/evidence/system-restore-run.log 2>&1
[[ $(blkid -s UUID -o value /dev/vdb) == "$holding_uuid" ]]
echo 'PASS: real ReaR restore completed on empty vda; holding disk and wrong token rejected before writes; reboot acceptance pending'
sync
RESCUE
    ;;
boot-restored)
    [[ ! -f $LAB/qemu.pid && ! -f $LAB/source.raw && -f $LAB/restored.raw ]] || exit 3
    qemu-system-x86_64 -accel tcg -machine pc -cpu max -m 1024 -smp 2 \
        -drive "file=$LAB/restored.raw,format=raw,if=virtio,discard=unmap,detect-zeroes=unmap" \
        -drive "file=$LAB/holding.raw,format=raw,if=virtio,discard=unmap,detect-zeroes=unmap" \
        -boot order=c -netdev user,id=n0,hostfwd=tcp:127.0.0.1:22440-:22 -device virtio-net-pci,netdev=n0 \
        -display none -serial "file:$LAB/evidence/restored-console.log" \
        -monitor "unix:$LAB/monitor.sock,server=on,wait=off" -daemonize -pidfile "$LAB/qemu.pid"
    ;;
rebuild-source-fixture)
    # Fixture construction after the independently recorded 2.7 rescue failure.
    # This manual construction MUST NOT be reported as a product restore PASS.
    [[ ! -f $LAB/qemu.pid && ! -e $LAB/source.raw && -f $LAB/restored.raw ]] || exit 3
    snapshot=$(cat "$LAB/system-snapshot")
    [[ $snapshot =~ ^[a-f0-9]{64}$ ]] || exit 3
    mv "$LAB/restored.raw" "$LAB/source.raw"
    printf 'label: dos\nstart=2048, type=83, bootable\n' | sfdisk "$LAB/source.raw"
    source_loop=$(losetup --find --show --partscan "$LAB/source.raw")
    holding_loop=$(losetup --read-only --find --show "$LAB/holding.raw")
    [[ $(losetup -n -O BACK-FILE "$source_loop") == "$LAB/source.raw" && $(losetup -n -O BACK-FILE "$holding_loop") == "$LAB/holding.raw" ]] || exit 3
    mkdir -p "$LAB/rebuilt-source" "$LAB/holding-mount"
    root="$LAB/rebuilt-source"
    path=''
    trap 'for path in "$root/sys" "$root/proc" "$root/dev" "$root" "$LAB/holding-mount"; do mountpoint -q "$path" && umount "$path"; done; losetup -d "$source_loop" "$holding_loop"' EXIT
    mount -o ro "$holding_loop" "$LAB/holding-mount"
    archive="$LAB/holding-mount/recovery/$snapshot/payload/netfs/system/backup.tar"
    [[ -s $archive && -f $LAB/evidence/system-remote-restored-manifest.json ]] || exit 3
    mkfs.ext4 -q -U 715f8233-c8e4-47a3-b3ba-2f6a60307459 "${source_loop}p1"
    mount "${source_loop}p1" "$root"
    tar --extract --file "$archive" --directory "$root" --numeric-owner --same-owner --same-permissions --acls --xattrs --xattrs-include='*' --sparse
    [[ $(cat "$root/root/vpsctl-backup-lab") == VPSCTL-ISOLATED-BACKUP-TEST ]] || exit 3
    printf 'vpsctl-backup-test-source-v29\n' > "$root/etc/hostname"
    mkdir -p "$root/dev" "$root/proc" "$root/sys" "$root/run" "$root/tmp" "$root/mnt/holding"
    chmod 1777 "$root/tmp"
    mount --bind /dev "$root/dev"
    mount --make-rslave "$root/dev"
    mount -t proc proc "$root/proc"
    mount -t sysfs sys "$root/sys"
    chroot "$root" grub-install --target=i386-pc --recheck "$source_loop"
    chroot "$root" update-grub
    chroot "$root" sha256sum -c /root/business-before.sha256
    sync
    fstrim -v "$root"
    echo 'FIXTURE ONLY: source rebuilt from verified archive to test a new ReaR version; this is not product recovery acceptance'
    ;;
source-v29-backup)
    SOURCE=${VPSCTL_BACKUP_SOURCE:-/var/tmp/vpsctl-backup-implementation/source}
    tar -C "$SOURCE" --exclude=.git --exclude=tests --exclude=docs -cf - . | \
        ssh -p 22440 -i "$LAB/guest-key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 'mkdir -p /opt/vpsctl-source-v29; tar -C /opt/vpsctl-source-v29 -xf -'
    ssh -p 22440 -i "$LAB/guest-key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 bash -s <<'GUEST'
set -Eeuo pipefail
[[ $(cat /root/vpsctl-backup-lab) == VPSCTL-ISOLATED-BACKUP-TEST ]] || exit 3
cli() { bash /opt/vpsctl-source-v29/bin/vpsctl --yes --non-interactive --install-deps "$@"; }
cli system backup configure acceptance-system-v29 --repo system-s3 --work-dir /mnt/holding/staging --exclude-mount /mnt/holding --private-containerd containerd.service --keep-daily 1 --keep-weekly 0 --keep-monthly 0
cli system backup run acceptance-system-v29
GUEST
    ;;
verify-restored)
    ssh -p 22440 -i "$LAB/guest-key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 bash -s <<'RESTORED'
set -Eeuo pipefail
[[ ! -f /etc/rear-release && ! -d /sys/firmware/efi ]]
[[ $(findmnt -rn -o SOURCE -T /) == /dev/vda1 ]]
for ((attempt=0; attempt<90; attempt++)); do
    [[ ! -f /var/lib/vpsctl/restore/completed ]] || break
    sleep 2
done
[[ -f /var/lib/vpsctl/restore/completed ]]
systemctl is-active ssh docker containerd systemd-networkd
[[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-system) == true ]]
sha256sum -c /root/business-before.sha256
docker exec vpsctl-backup-test-system sh -c 'test "$(cat /data/volume.txt)" = whole-system-volume; test "$(cat /root/writable.txt)" = whole-system-writable; test "$(cat /business/upload.txt)" = whole-system-upload'
python3 - <<'PY'
import sqlite3
db=sqlite3.connect('/srv/business/business.db')
assert db.execute('pragma integrity_check').fetchone()==('ok',)
assert db.execute('select * from orders order by id').fetchall()==[(1,4225),(2,1775)]
PY
identity=$(cat /etc/machine-id)
[[ $identity =~ ^[a-f0-9]{32}$ && $identity != 01af12503d3b4ff895b0af24279d355d ]]
key=$(sha256sum /etc/ssh/ssh_host_ed25519_key.pub)
[[ ${key%% *} != 239da8ebc0b412b26df4d9c89b454043743fca538ffcc90712e966741c3da2e6 ]]
[[ -z $(find /etc/systemd/system -type l -name 'vpsctl-backup-*.timer' -print -quit) ]]
[[ $(systemctl is-enabled cron.service 2>/dev/null || true) == masked ]]
ip -br address show ens3
getent hosts deb.debian.org
systemctl --failed --no-pager
cat /etc/fstab
cat /etc/resolv.conf
cat /var/lib/vpsctl/restore/completed
echo 'PASS: recovered Debian boot/SSH/system services/Docker/volume/bind/writable data/SQLite business/DHCP-DNS/clone identity and paused scheduling'
RESTORED
    ;;
rescue-only-build)
    # Focused follow-up for discovered rescue SSH/import dependencies.
    # No service stop, filesystem archive, upload, or second destructive recover.
    ssh -p 22440 -i "$LAB/guest-key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 bash -s <<'MEDIA'
set -Eeuo pipefail
[[ ! -f /etc/rear-release && -f /var/lib/vpsctl/restore/completed ]] || exit 3
source /opt/vpsctl-source-sshfix/commands/system/backup.sh
vps_cmd_init system-backup "$BS_ROOT"
backup_init "$BS_ROOT"
bs_parse inspect --non-interactive --install-deps
BS_ID=acceptance-system-v29-bios
bs_load_plan
BS_WORK=/mnt/holding/ssh-media-proof
BACKUP_JOB_DIR=$BS_WORK/proof
BACKUP_PAYLOAD_DIR=$BS_WORK/payload
BS_REAR_TAR=''
umask 077
mkdir -p "$BACKUP_JOB_DIR/rear-config" "$BACKUP_PAYLOAD_DIR/netfs" "$BACKUP_PAYLOAD_DIR/iso" "$BS_WORK/tmp"
bs_prepare_rear
bs_rear_capabilities
bs_inventory
bs_check_coverage
bs_rear_config "$BACKUP_JOB_DIR/rear-config/local.conf"
printf '%s\n' "${BS_SSH_HELPERS[@]}" > "$BACKUP_JOB_DIR/helpers.txt"
printf '%s\n' "${BS_SSH_HELPER_LIBS[@]}" > "$BACKUP_JOB_DIR/helper-libs.txt"
vps_cmd_lock backup-capture
trap 'vps_cmd_unlock' EXIT
TMPDIR="$BS_WORK/tmp" bs_rear -c "$BACKUP_JOB_DIR/rear-config" mkrescue > "$BACKUP_JOB_DIR/mkrescue.log" 2>&1
iso=$(find "$BACKUP_PAYLOAD_DIR/iso" -name '*.iso' -type f -print -quit)
[[ -n $iso && -s $iso ]]
bs_verify_iso_boot_files "$iso"
bash /opt/vpsctl-source-sshfix/commands/system/backup.sh export-recovery acceptance-system-v29-bios --output /mnt/holding/tools/recovery-kit-sshfix --yes --non-interactive
[[ -x /mnt/holding/tools/recovery-kit-sshfix/bin/install ]]
/mnt/holding/tools/recovery-kit-sshfix/bin/install --version | head -1
systemctl is-active docker containerd ssh
printf 'PASS: product-config mkrescue-only and new recovery kit generated; native boot/import acceptance pending\n'
sync
fstrim -v /mnt/holding
fstrim -v /
MEDIA
    ;;rescue-only-verify)
    snapshot=$(cat "$LAB/system-snapshot")
    [[ $snapshot =~ ^[a-f0-9]{64}$ ]] || exit 3
    ssh -p 22440 -i "$LAB/guest-key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 "SNAPSHOT=$snapshot bash -s" <<'PROOF'
set -Eeuo pipefail
[[ -f /etc/rear-release && ! -d /etc/vpsctl/backup/plans && ! -d /var/lib/vpsctl/backup/jobs ]]
# Successful remote public-key login itself proves the native sshd helpers run.
cat /etc/rear-release
/usr/sbin/rear -V
for helper in /usr/lib/openssh/sshd-session /usr/lib/openssh/sshd-auth; do
    [[ -x $helper ]]
    dependencies=$(ldd "$helper")
    printf '%s\n' "$dependencies"
    [[ $dependencies != *'not found'* ]]
done
install --version | head -1
tar --version | head -1
mkdir -p /mnt/holding
mountpoint -q /mnt/holding || mount /dev/vdb /mnt/holding
[[ $(findmnt -rn -o SOURCE -T /mnt/holding) == /dev/vdb ]]
kit=/mnt/holding/tools/recovery-kit-sshfix
"$kit/recover.sh" import-repo /mnt/holding/tools/password /mnt/holding/tools/s3-credentials.json
[[ -x $kit/bin/install ]]
# Confirm the bundle's install remains independently usable from this ISO.
"$kit/bin/install" -m 0600 /mnt/holding/tools/password /run/vpsctl-kit-install-proof
[[ $(stat -c %a /run/vpsctl-kit-install-proof) == 600 ]]
rm -f /run/vpsctl-kit-install-proof
dd if=/dev/vda bs=1M count=1 status=none | sha256sum > /mnt/holding/evidence/sshfix-disk-before.sha256
"$kit/recover.sh" restore-plan --repo system-s3 --snapshot "$SNAPSHOT" --work-dir /mnt/holding/recovery \
    --disk-map /dev/vda=/dev/vda --mode clone --network dhcp --interface ens3 --dns 10.0.2.3 \
    --yes --non-interactive > /mnt/holding/evidence/sshfix-restore-plan.log
grep -E 'restore-[a-f0-9]{64}' /mnt/holding/evidence/sshfix-restore-plan.log
dd if=/dev/vda bs=1M count=1 status=none | sha256sum > /mnt/holding/evidence/sshfix-disk-after.sha256
cmp /mnt/holding/evidence/sshfix-disk-before.sha256 /mnt/holding/evidence/sshfix-disk-after.sha256
ip -br address show ens3
echo 'PASS: fixed original ISO native SSH/helpers/libraries/install, recovery bundle import and remote full-snapshot restore-plan; no RAM assistance or disk writes'
PROOF
    ;;status)
    df -h "$LAB"
    du -sh "$LAB"
    [[ ! -f $LAB/qemu.pid ]] || ps -p "$(cat "$LAB/qemu.pid")" -o pid,args
    ;;
*) echo 'Usage: prepare|boot|holding|guest-fixture|trim-offline|pull-recovery|remove-source|copy-rescue-iso|boot-rescue|rescue-restore|boot-restored|rebuild-source-fixture|source-v29-backup|verify-restored|rescue-only-build|rescue-only-verify|status'; exit 2 ;;
esac
