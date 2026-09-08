#!/usr/bin/env bash
# Opt-in recovery of the deliberately damaged Debian13 MBR test child.
# Run only inside the separate rescue VM on host-vps-scripts.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

[[ "${VPSCTL_REAL_GRUB_RESCUE:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_GRUB_RESCUE=1 in the dedicated rescue guest\n'
    exit 0
}
[[ "$EUID" == 0 && ! -d /sys/firmware/efi ]] || exit 3
[[ "$(cat /sys/class/dmi/id/bios_vendor)" == SeaBIOS ]] || exit 3
[[ "$(cat /root/vpsctl-bios-grub-rescue-lab 2>/dev/null)" == VPSCTL-ISOLATED-BIOS-GRUB-RESCUE ]] || exit 3
[[ "$(blockdev --getsize64 /dev/vdb)" == 10737418240 ]] || exit 3
[[ "$(lsblk -dn -o TYPE /dev/vdb)" == disk ]] || exit 3

readonly MOUNT=/mnt/vpsctl-grub-rescue
readonly EVIDENCE=/root/vpsctl-grub-rescue-evidence
[[ ! -L "$MOUNT" ]] || exit 3
if mountpoint -q "$MOUNT"; then exit 3; fi
install -d -m 0700 "$MOUNT" "$EVIDENCE"
[[ -z "$(findmnt -rn -S /dev/vdb1)" ]] || exit 3
[[ ! -e "$EVIDENCE/backup" ]] || exit 3
mount -t ext4 -o ro,noload /dev/vdb1 "$MOUNT"
trap 'if mountpoint -q "$MOUNT"; then umount "$MOUNT"; fi' EXIT
backup="$(find "$MOUNT/var/lib/vpsctl/system/kernel/backups" -mindepth 1 -maxdepth 1 -type d -name 'bios-grub.*' | sort | tail -n 1)"
[[ -n "$backup" ]] || exit 3
(cd "$backup" && sha256sum -c SHA256SUMS)

python3 - "$backup" "$EVIDENCE" <<'PY'
import csv
import json
import pathlib
import subprocess
import sys

backup = pathlib.Path(sys.argv[1])
evidence = pathlib.Path(sys.argv[2])
saved = json.loads((backup / "partition-table.json").read_text())
assert saved["device"] == "/dev/vda"
assert saved["label"] == "dos" and saved["id"] == "0x20260908"
assert saved["sectorsize"] == 512 and len(saved["partitions"]) == 1
partition = saved["partitions"][0]
assert partition["node"] == "/dev/vda1"
assert partition["start"] == 262144 and partition["size"] == 20709343
# The original path must never be used for rescue writes: it is the rescue OS.
saved["device"] = "/dev/vdb"
partition["node"] = "/dev/vdb1"
actual = json.loads(subprocess.check_output(["sfdisk", "--json", "/dev/vdb"]))["partitiontable"]
assert actual == saved, "rescue disk identity or partition layout differs"
layout = json.loads((backup / "disk-layout.json").read_text())
original_root = next(x for x in layout["disk"]["children"] if x["name"] == "/dev/vda1")
root_uuid = subprocess.check_output(["blkid", "-s", "UUID", "-o", "value", "/dev/vdb1"], text=True).strip()
assert root_uuid and root_uuid == original_root["uuid"], "root filesystem UUID differs"
with (backup / "disk-regions.tsv").open() as stream:
    rows = list(csv.DictReader(stream, delimiter="\t"))
assert rows == [{"file": "embedding-region.bin", "disk": "/dev/vda", "offset_bytes": "0", "length_bytes": "134217728"}]
assert (backup / "embedding-region.bin").stat().st_size == 134217728
assert 134217728 == partition["start"] * saved["sectorsize"]
(evidence / "verified-partition-table.json").write_text(json.dumps(saved, sort_keys=True))
(evidence / "target-remap.txt").write_text("original=/dev/vda rescue=/dev/vdb root_uuid=" + root_uuid + "\n")
print("PASS: original /dev/vda remapped to verified /dev/vdb; UUID and full partition layout match")
PY

cp -a "$backup" "$EVIDENCE/backup"
umount "$MOUNT"
(cd "$EVIDENCE/backup" && sha256sum -c SHA256SUMS)
dd if="$EVIDENCE/backup/embedding-region.bin" of=/dev/vdb bs=1M \
    conv=notrunc,fsync status=progress
expected="$(sha256sum "$EVIDENCE/backup/embedding-region.bin" | awk '{print $1}')"
actual="$(dd if=/dev/vdb bs=1M count=128 iflag=fullblock status=none | sha256sum | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || exit 20
python3 - "$EVIDENCE" <<'PY'
import json
import pathlib
import subprocess
import sys

expected = json.loads((pathlib.Path(sys.argv[1]) / "verified-partition-table.json").read_text())
actual = json.loads(subprocess.check_output(["sfdisk", "--json", "/dev/vdb"]))["partitiontable"]
assert actual == expected, "partition table changed during raw recovery"
PY
date -u +%FT%TZ >"$EVIDENCE/restore-completed"
printf 'PASS: exact 128 MiB MBR/embedding region restored to /dev/vdb; pending independent boot\n'
