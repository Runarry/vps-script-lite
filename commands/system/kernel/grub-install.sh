#!/usr/bin/env bash
# Explicit BIOS GRUB installation. Never install a boot sector from a kernel hook.
# shellcheck disable=SC2034,SC2016,SC2015

declare -ag KERNEL_GRUB_INSTALL_ARGS=()
declare -ag KERNEL_GRUB_INSTALL_PROTECTED_RELEASES=()
declare -Ag KERNEL_GRUB_INSTALL_EXPECTED_VERSIONS=()
KERNEL_GRUB_INSTALL_BACKUP=''

_kernel_grub_install_require_platform() {
    local tool path output status=0
    local -a missing=()
    _kernel_require_common_platform || return $?
    for tool in python3 findmnt lsblk sfdisk blkid blockdev systemd-detect-virt \
        dpkg dpkg-query apt-get apt-cache debconf-communicate debconf-set-selections \
        dd od sha256sum tar du df stat readlink find sort awk grep install mktemp flock tee sync cat chmod date; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if ((${#missing[@]})); then
        vps_cmd_error "BIOS GRUB 预检缺少工具：$(kernel_join_values "${missing[@]}")；请先单独安装所需的 python3、util-linux、fdisk、debconf 或 coreutils 后重试"
        return 3
    fi
    path="$(vps_cmd_system_path /sys/firmware/efi)" || return $?
    [[ ! -e "$path" ]] || {
        vps_cmd_error '检测到 UEFI；install-grub 仅支持 BIOS，不修改 EFI 启动器'
        return 3
    }
    for path in /boot/grub/menu.lst /boot/grub/stage1 /host/wubildr /host/wubildr.mbr; do
        path="$(vps_cmd_system_path "$path")" || return $?
        [[ ! -e "$path" ]] || {
            vps_cmd_error '检测到 GRUB Legacy 或 Wubi 引导文件；不支持自动迁移该启动布局'
            return 3
        }
    done
    if systemd-detect-virt --container --quiet; then
        vps_cmd_error '容器不能安装宿主机 BIOS 引导器'
        return 3
    else
        status=$?
        ((status == 1)) || return 3
    fi
    if systemd-detect-virt --chroot --quiet; then
        vps_cmd_error 'chroot 环境不能证明实际启动磁盘，拒绝 BIOS GRUB 安装'
        return 3
    else
        status=$?
        ((status == 1)) || return 3
    fi
    [[ "${KERNEL_RUNNING_RELEASE,,}" != *microsoft* && "${KERNEL_RUNNING_RELEASE,,}" != *wsl* ]] || return 3
    path="$(vps_cmd_system_path /proc/cmdline)" || return $?
    [[ -r "$path" ]] || return 3
    output="$(cat -- "$path")" || return 3
    if [[ " $output " =~ [[:space:]](noefi|efi=([^[:space:]]*,)?(disable|noruntime)(,[^[:space:]]*)?)[[:space:]] ]]; then
        vps_cmd_error '内核启动参数关闭了 EFI 识别或运行时；缺少 EFI 目录不能证明 BIOS 模式'
        return 3
    fi
    path="$(vps_cmd_system_path /sys)" || return $?
    output="$(findmnt --noheadings --output FSTYPE --target "$path" 2>/dev/null)" || return 3
    [[ "$output" == sysfs ]] || {
        vps_cmd_error '无法确认完整 sysfs；缺少 EFI 目录不足以证明 BIOS 模式'
        return 3
    }
    path="$(vps_cmd_system_path /sys/class/dmi/id/bios_vendor)" || return $?
    [[ -r "$path" ]] && [[ -n "$(cat -- "$path")" ]] || {
        vps_cmd_error '缺少可验证的 DMI BIOS 信息，不能安全推断启动模式'
        return 3
    }
    path="$KERNEL_BOOT_DIR/config-$KERNEL_RUNNING_RELEASE"
    [[ -f "$path" && ! -L "$path" ]] && grep -Fqx 'CONFIG_EFI=y' "$path" || {
        vps_cmd_error '当前内核配置未能证明 CONFIG_EFI=y，不能仅凭 EFI 目录缺失判定 BIOS'
        return 3
    }
    output="$(LC_ALL=C dpkg --audit 2>&1)" || {
        vps_cmd_error "dpkg 审计失败：$output"
        return 3
    }
    [[ -z "$output" ]] || {
        vps_cmd_error "dpkg 存在未完成事务，请先修复：$output"
        return 3
    }
}

# Pure JSON validation, shared by read-only discovery and fixture tests. With no
# partition table, return only the disk to inspect; otherwise return TSV fields.
_kernel_grub_install_parse_disk_data() {
    python3 - "$@" <<'PY'
import json
import re
import sys

def fail(message):
    raise ValueError(message)

def device(value):
    if not isinstance(value, str) or not re.fullmatch(r"/dev/[A-Za-z0-9._+-]+", value):
        fail("块设备名称不安全")
    return value

def integer(value, name, minimum=0):
    if isinstance(value, bool) or not str(value).isdigit():
        fail(name + " 不是整数")
    value = int(value)
    if value < minimum or value > 2**63 - 1:
        fail(name + " 超出安全范围")
    return value

def readonly(value):
    if isinstance(value, bool):
        return int(value)
    result = integer(value, "只读标记")
    if result not in (0, 1):
        fail("只读标记无效")
    return result

try:
    requested, root_raw, boot_raw, blocks_raw = sys.argv[1:5]
    table_raw = sys.argv[5] if len(sys.argv) > 5 else ""
    mbr_hex = sys.argv[6] if len(sys.argv) > 6 else ""
    blocks = json.loads(blocks_raw)["blockdevices"]
    nodes = {}
    parents = {}
    ambiguous = set()
    def walk(items, parent=None):
        for item in items:
            name = item["name"]
            if not isinstance(name, str) or not name.startswith("/dev/") or any(ord(c) < 32 for c in name):
                fail("块设备名称不安全")
            if name in nodes:
                ambiguous.add(name)
            nodes[name] = item
            parents[name] = parent
            walk(item.get("children", []), name)
    walk(blocks)

    def mount(raw, allowed):
        entries = json.loads(raw)["filesystems"]
        if len(entries) != 1:
            fail("挂载来源不唯一")
        entry = entries[0]
        if entry["target"] not in allowed or entry["fstype"] not in ("ext2", "ext3", "ext4"):
            fail("仅支持普通 ext2/ext3/ext4 根分区和同盘 /boot")
        if "rw" not in entry["options"].split(","):
            fail("根分区或 /boot 为只读")
        matches = [x for x in nodes.values() if x.get("maj:min") == entry["maj:min"]]
        if len(matches) != 1:
            fail("挂载设备无法唯一关联到块设备")
        node = matches[0]
        if node["name"] in ambiguous or node["type"] != "part" or node.get("children"):
            fail("不支持 LVM、RAID、加密、多路径或整盘文件系统")
        if node.get("fstype") != entry["fstype"]:
            fail("挂载和分区文件系统不一致")
        disk_name = parents[node["name"]]
        if not disk_name or disk_name in ambiguous or nodes[disk_name]["type"] != "disk" or parents[disk_name] is not None:
            fail("根分区或 /boot 不属于一块普通整盘")
        if node.get("pkname") not in (disk_name, disk_name[5:]):
            fail("块设备父子证据不一致")
        return entry, node, nodes[disk_name]

    root_mount, root, disk = mount(root_raw, ("/",))
    boot_mount, boot, boot_disk = mount(boot_raw, ("/", "/boot"))
    disk_name = device(disk["name"])
    if disk_name != boot_disk["name"]:
        fail("根分区和 /boot 跨盘，不在首版支持范围")
    if requested and requested != disk_name:
        fail("指定目标不是承载根分区和 /boot 的唯一磁盘；拒绝写入数据盘")
    if any(readonly(x.get("ro")) != 0 for x in (root, boot, disk)):
        fail("目标磁盘或启动分区为只读")
    for child in disk.get("children", []):
        if child["type"] != "part" or child.get("children"):
            fail("启动盘存在复杂块设备关系")
    if not table_raw:
        print(disk_name)
        sys.exit(0)

    table = json.loads(table_raw)["partitiontable"]
    if table["device"] != disk_name or table["unit"] != "sectors":
        fail("分区表设备或计量单位不一致")
    label = table["label"]
    if label not in ("dos", "gpt") or disk.get("pttype") != label:
        fail("仅支持可一致识别的 MBR 或 GPT 分区表")
    sector = integer(table["sectorsize"], "逻辑扇区", 512)
    if sector not in (512, 4096) or sector != integer(disk["log-sec"], "逻辑扇区", 512):
        fail("逻辑扇区大小不支持或不一致")
    size = integer(disk["size"], "磁盘容量", 1)
    partitions = table["partitions"]
    if not partitions or not table.get("id"):
        fail("分区表没有可验证的标识或分区")
    if {x["node"] for x in partitions} != {x["name"] for x in disk.get("children", [])}:
        fail("内核设备关系与磁盘分区表不一致")
    intervals = []
    bios = []
    lower, upper = sector, size
    if label == "gpt":
        lower = integer(table["firstlba"], "GPT 首个可用扇区", 2) * sector
        upper = (integer(table["lastlba"], "GPT 最后可用扇区", 2) + 1) * sector
        if lower >= upper or upper >= size:
            fail("GPT 可用分区范围不安全")
    for part in partitions:
        name = device(part["node"])
        start = integer(part["start"], "分区起点", 1) * sector
        length = integer(part["size"], "分区长度", 1) * sector
        if start < lower or start + length > upper or length != integer(nodes[name]["size"], "分区容量", 1):
            fail("分区超出磁盘或容量不一致")
        if integer(nodes[name]["start"], "内核分区起点", 1) * 512 != start:
            fail("内核尚未读取当前分区表，分区起点不一致")
        intervals.append((start, start + length))
        kind = str(part["type"]).lower()
        if label == "dos" and kind.lstrip("0") in ("5", "f", "85"):
            fail("首版不支持 MBR 扩展或逻辑分区")
        if label == "gpt" and kind == "21686148-6449-6e6f-744e-656564454649":
            node = nodes[name]
            if length < 1048576 or node.get("fstype") or any(node.get("mountpoints") or []):
                fail("BIOS Boot 分区必须至少 1 MiB、未挂载且无文件系统")
            if readonly(node.get("ro")):
                fail("BIOS Boot 分区为只读")
            bios.append((name, start, length))
    intervals.sort()
    if any(a[1] > b[0] for a, b in zip(intervals, intervals[1:])):
        fail("分区重叠")
    mbr = bytes.fromhex(mbr_hex)
    if len(mbr) != 512 or mbr[510:] != b"\x55\xaa":
        fail("MBR 签名无效或无法读取")
    types = [mbr[446 + i * 16 + 4] for i in range(4)]
    if label == "gpt":
        if types.count(0xEE) != 1 or any(x not in (0, 0xEE) for x in types):
            fail("拒绝混合 MBR 或不完整的 GPT 保护 MBR")
        if len(bios) != 1:
            fail("GPT 必须已有唯一的 BIOS Boot 分区；不会创建或格式化分区")
        region_device, offset, length = bios[0]
    else:
        if 0xEE in types or intervals[0][0] < 1048576:
            fail("MBR 首分区前必须至少有 1 MiB 嵌入空间")
        region_device, offset, length = disk_name, 0, intervals[0][0]
    data = {
        "disk": disk, "root": root_mount, "boot": boot_mount,
        "partitiontable": table, "region_offset": offset, "region_length": length,
        "mbr_sha_source": mbr_hex,
    }
    fields = {
        "DISK": disk_name, "ROOT_PART": root["name"], "BOOT_PART": boot["name"],
        "LABEL": label, "SIZE": size, "SECTOR_SIZE": sector,
        "REGION_DEVICE": region_device, "REGION_OFFSET": offset, "REGION_LENGTH": length,
        "DISK_DATA": json.dumps(data, sort_keys=True, separators=(",", ":")),
        "TABLE_DATA": json.dumps(table, sort_keys=True, separators=(",", ":")),
    }
    for key, value in fields.items():
        value = str(value)
        if any(ord(c) < 32 for c in value):
            fail("设备元数据包含控制字符")
        print(key + "\t" + value)
except (ValueError, KeyError, TypeError, IndexError) as error:
    print("BIOS GRUB 磁盘检查失败：" + str(error), file=sys.stderr)
    sys.exit(3)
PY
}

_kernel_grub_install_probe_disk() {
    local requested="${1:-}" root_json boot_json blocks_json table_json disk mbr output key value signature status=0
    if [[ -n "$requested" ]]; then
        [[ "$requested" =~ ^/dev/[A-Za-z0-9._+-]+$ || "$requested" =~ ^/dev/disk/by-id/[A-Za-z0-9._+:-]+$ ]] || {
            vps_cmd_error '--disk 只接受整盘设备或 /dev/disk/by-id/ 下的整盘链接'
            return 3
        }
        requested="$(readlink -e -- "$requested")" || return 3
        [[ -b "$requested" ]] || return 3
    fi
    root_json="$(LC_ALL=C findmnt --json --output SOURCE,FSTYPE,TARGET,MAJ:MIN,OPTIONS --target /)" || return 3
    boot_json="$(LC_ALL=C findmnt --json --output SOURCE,FSTYPE,TARGET,MAJ:MIN,OPTIONS --target /boot)" || return 3
    blocks_json="$(LC_ALL=C lsblk --json --bytes --paths --output NAME,TYPE,PKNAME,RO,SIZE,MAJ:MIN,LOG-SEC,START,FSTYPE,MOUNTPOINTS,PTTYPE,PARTTYPE,UUID,PARTUUID,SERIAL,WWN)" || return 3
    disk="$(_kernel_grub_install_parse_disk_data "$requested" "$root_json" "$boot_json" "$blocks_json")" || return $?
    [[ -b "$disk" && "$(readlink -e -- "$disk")" == "$disk" && "$(blockdev --getro "$disk")" == 0 ]] || {
        vps_cmd_error '候选设备不是可写的真实规范整盘路径'
        return 3
    }
    table_json="$(LC_ALL=C sfdisk --json "$disk")" || return 3
    LC_ALL=C sfdisk --verify "$disk" >/dev/null 2>&1 || {
        vps_cmd_error 'sfdisk 分区表校验失败'
        return 3
    }
    mbr="$(od -An -v -tx1 -N512 -- "$disk")" || return 3
    mbr="${mbr//[[:space:]]/}"
    output="$(_kernel_grub_install_parse_disk_data "$requested" "$root_json" "$boot_json" "$blocks_json" "$table_json" "$mbr")" || return $?
    while IFS=$'\t' read -r key value; do
        case "$key" in
            DISK | ROOT_PART | BOOT_PART | LABEL | SIZE | SECTOR_SIZE | REGION_DEVICE | REGION_OFFSET | REGION_LENGTH | DISK_DATA | TABLE_DATA)
                printf -v "KERNEL_GRUB_INSTALL_$key" '%s' "$value"
                ;;
            *) return 3 ;;
        esac
    done <<<"$output"
    if [[ "$KERNEL_GRUB_INSTALL_LABEL" == gpt ]]; then
        signature="$(LC_ALL=C blkid --probe --match-tag TYPE --output value "$KERNEL_GRUB_INSTALL_REGION_DEVICE" 2>/dev/null)" || status=$?
        [[ -z "$signature" && ("$status" == 0 || "$status" == 2) ]] || {
            vps_cmd_error 'BIOS Boot 分区仍有文件系统签名或签名探测失败'
            return 3
        }
    fi
}

_kernel_grub_install_validate_paths() {
    local path file line
    local -a files=()
    for path in "$KERNEL_BOOT_DIR" "$KERNEL_GRUB_CFG" "$KERNEL_GRUB_ENV" \
        "$KERNEL_GRUB_DEFAULT_FILE" "$KERNEL_GRUB_DEFAULT_DIR" "$KERNEL_GRUB_DROPIN" \
        "$KERNEL_GRUB_BACKUP_ROOT" "$(vps_cmd_system_path /etc/grub.d)"; do
        vps_cmd_require_no_symlink_components "$path" || return $?
    done
    for path in "$KERNEL_GRUB_DEFAULT_DIR" "$KERNEL_BOOT_DIR/grub" "$KERNEL_GRUB_BACKUP_ROOT" "$(vps_cmd_system_path /etc/grub.d)"; do
        [[ ! -e "$path" || -d "$path" ]] || {
            vps_cmd_error "GRUB 目录位置已被普通文件占用：$path"
            return 10
        }
    done
    for path in "$KERNEL_GRUB_CFG" "$KERNEL_GRUB_ENV" "$KERNEL_GRUB_DEFAULT_FILE"; do
        [[ ! -e "$path" || (-f "$path" && -r "$path") ]] || {
            vps_cmd_error "GRUB 配置路径不是可读普通文件：$path"
            return 10
        }
    done
    if [[ -e "$KERNEL_GRUB_DROPIN" ]]; then
        [[ -f "$KERNEL_GRUB_DROPIN" ]] && grep -Fqx "$KERNEL_MANAGED_MARKER" "$KERNEL_GRUB_DROPIN" || {
            vps_cmd_error '/etc/default/grub.d/99-vpsctl-kernel.cfg 已存在但不属于 vpsctl，拒绝覆盖'
            return 10
        }
    fi
    shopt -s nullglob
    files=("$KERNEL_GRUB_DEFAULT_DIR"/*.cfg)
    shopt -u nullglob
    for file in "${files[@]}"; do
        [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 10
        if [[ "${file##*/}" > 99-vpsctl-kernel.cfg ]] &&
            grep -Eq '^[[:space:]]*[^#].*(GRUB_DEFAULT|GRUB_SAVEDEFAULT)|^[[:space:]]*(GRUB_DEFAULT|GRUB_SAVEDEFAULT)' "$file"; then
            vps_cmd_error "后加载的非受管配置会覆盖默认项，请先人工整理：$file"
            return 10
        fi
    done
    [[ ! -f "$KERNEL_GRUB_DEFAULT_FILE" ]] || files+=("$KERNEL_GRUB_DEFAULT_FILE")
    for file in "${files[@]}"; do
        bash -n -- "$file" || {
            vps_cmd_error "GRUB 配置有 shell 语法错误：$file"
            return 10
        }
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
            [[ "$line" == *GRUB_DEFAULT* || "$line" == *GRUB_SAVEDEFAULT* ]] || continue
            if [[ ! "$line" =~ ^[[:space:]]*GRUB_(DEFAULT|SAVEDEFAULT)[[:space:]]*= ]]; then
                vps_cmd_error "GRUB 默认变量使用非标准赋值、readonly 或动态 shell 语句，拒绝自动修改：$file"
                return 10
            fi
            _kernel_grub_parse_literal "${line#*=}" >/dev/null || {
                vps_cmd_error "GRUB 默认变量包含动态展开或附加 shell 语句，请先人工整理：$file"
                return 10
            }
        done <"$file"
    done
    if [[ -e "$KERNEL_GRUB_ENV" ]]; then
        python3 - "$KERNEL_GRUB_ENV" <<'PY' || return 10
import re
import sys
try:
    data = open(sys.argv[1], "rb").read()
    if len(data) != 1024 or not data.startswith(b"# GRUB Environment Block\n"):
        raise ValueError("grubenv 不是标准 1024 字节环境块；请先人工修复")
    seen = set()
    for line in data.split(b"\n"):
        if not line or line.startswith(b"#"):
            continue
        if b"=" not in line or any(c < 32 or c == 127 for c in line):
            raise ValueError("grubenv 包含损坏的变量记录")
        key, _ = line.split(b"=", 1)
        if not re.fullmatch(rb"[A-Za-z_][A-Za-z0-9_]*", key) or key in seen:
            raise ValueError("grubenv 包含无效或重复变量")
        seen.add(key)
except (OSError, ValueError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(10)
PY
    fi
}

_kernel_grub_install_plan_packages() {
    local KERNEL_TYPE=official package resolved version old requested installed=0
    local efi_bin_installed=0 planned_common='' planned_efi_bin=''
    KERNEL_GRUB_INSTALL_ARGS=()
    KERNEL_GRUB_INSTALL_EXPECTED_VERSIONS=()
    resolved="$(_kernel_inventory_resolve_package grub-pc 2>/dev/null || true)"
    if [[ -n "$resolved" ]] && kernel_inventory_package_installed "$resolved"; then
        requested="${KERNEL_PKG_VERSION[$resolved]}"
        installed=1
    else
        requested="$(_kernel_distribution_candidate_version grub-pc)" || {
            vps_cmd_error '没有可验证的官方 grub-pc 候选；请检查发行版源并单独刷新 APT 索引后重试'
            return 3
        }
    fi
    kernel_validate_install_plan grub-pc "$requested" || return $?
    resolved="$(_kernel_inventory_resolve_package grub-efi-amd64-bin 2>/dev/null || true)"
    if [[ -n "$resolved" ]] && kernel_inventory_package_installed "$resolved"; then
        efi_bin_installed=1
    fi
    for package in "${!KERNEL_INSTALL_EXPECTED_VERSIONS[@]}"; do
        case "${package%%:*}" in
            grub-common) planned_common="${KERNEL_INSTALL_EXPECTED_VERSIONS[$package]}" ;;
            grub-efi-amd64-bin) planned_efi_bin="${KERNEL_INSTALL_EXPECTED_VERSIONS[$package]}" ;;
        esac
    done
    for package in "${!KERNEL_INSTALL_EXPECTED_VERSIONS[@]}"; do
        case "${package%%:*}" in
            grub-efi-amd64-bin | grub-efi-amd64-unsigned)
                # Cloud images often carry EFI modules alongside BIOS modules.
                # Their exact grub-common dependency can require a matching
                # upgrade when grub-pc is installed. This does not authorize a
                # new EFI backend or an unrelated EFI module installation.
                if ((efi_bin_installed != 1)) || [[ -z "$planned_common" || "$planned_common" != "$planned_efi_bin" ||
                    "${KERNEL_INSTALL_EXPECTED_VERSIONS[$package]}" != "$planned_efi_bin" ]]; then
                    vps_cmd_error "EFI 模块变更不是已有 amd64 模块随 grub-common 的必要同版本升级：$package"
                    return 3
                fi
                ;;
            linux-* | kernel-* | grub-efi* | shim-* | systemd-boot*)
                vps_cmd_error "BIOS GRUB 安装计划不得改变内核或其他启动器软件包：$package"
                return 3
                ;;
        esac
        version="${KERNEL_INSTALL_EXPECTED_VERSIONS[$package]}"
        resolved="$(_kernel_inventory_resolve_package "$package" 2>/dev/null || true)"
        if [[ -n "$resolved" ]] && kernel_inventory_package_installed "$resolved"; then
            old="${KERNEL_PKG_VERSION[$resolved]}"
            if dpkg --compare-versions "$version" lt "$old"; then
                vps_cmd_error "BIOS GRUB 安装计划包含降级：$package $old → $version"
                return 3
            fi
        fi
        KERNEL_GRUB_INSTALL_EXPECTED_VERSIONS["$package"]="$version"
    done
    KERNEL_GRUB_INSTALL_EXPECTED_VERSIONS['grub-pc']="$requested"
    if ((installed == 0 || ${#KERNEL_INSTALL_EXPECTED_VERSIONS[@]} > 0)); then
        while IFS= read -r package; do
            KERNEL_GRUB_INSTALL_ARGS+=("$package=${KERNEL_GRUB_INSTALL_EXPECTED_VERSIONS[$package]}")
        done < <(printf '%s\n' "${!KERNEL_GRUB_INSTALL_EXPECTED_VERSIONS[@]}" | LC_ALL=C sort)
    fi
}

_kernel_grub_install_plan_defaults() {
    KERNEL_GRUB_INSTALL_DEFAULT_RELEASE=''
    KERNEL_GRUB_INSTALL_NEXT_RELEASE=''
    KERNEL_GRUB_INSTALL_NEXT_ID=''
    KERNEL_GRUB_INSTALL_CLEAR_NEXT=1
    KERNEL_GRUB_INSTALL_FALLBACK=0
    kernel_grub_load_config || true
    if [[ -n "${KERNEL_GRUB_DEFAULT_RELEASE:-}" &&
        "${KERNEL_RELEASE_COMPLETE[$KERNEL_GRUB_DEFAULT_RELEASE]:-0}" == 1 &&
        "${KERNEL_RELEASE_MANAGED[$KERNEL_GRUB_DEFAULT_RELEASE]:-0}" == 1 ]]; then
        KERNEL_GRUB_INSTALL_DEFAULT_RELEASE="$KERNEL_GRUB_DEFAULT_RELEASE"
        if [[ "${KERNEL_GRUB_NEXT_READ_KNOWN:-0}" == 1 && -n "${KERNEL_GRUB_NEXT_RELEASE:-}" &&
            "${KERNEL_RELEASE_COMPLETE[$KERNEL_GRUB_NEXT_RELEASE]:-0}" == 1 &&
            "${KERNEL_RELEASE_MANAGED[$KERNEL_GRUB_NEXT_RELEASE]:-0}" == 1 ]]; then
            KERNEL_GRUB_INSTALL_NEXT_RELEASE="$KERNEL_GRUB_NEXT_RELEASE"
            KERNEL_GRUB_INSTALL_NEXT_ID="$KERNEL_GRUB_NEXT_ID"
            KERNEL_GRUB_INSTALL_CLEAR_NEXT=0
        fi
    else
        KERNEL_GRUB_INSTALL_FALLBACK=1
        [[ "${KERNEL_RELEASE_COMPLETE[$KERNEL_RUNNING_RELEASE]:-0}" == 1 &&
            "${KERNEL_RELEASE_MANAGED[$KERNEL_RUNNING_RELEASE]:-0}" == 1 ]] || {
            vps_cmd_error '原默认项无法解析，当前运行内核也不是完整的受管启动目标，拒绝回退'
            return 3
        }
        KERNEL_GRUB_INSTALL_DEFAULT_RELEASE="$KERNEL_RUNNING_RELEASE"
    fi
}

_kernel_grub_install_debconf_snapshot() {
    local key output
    for key in grub-pc/install_devices grub-pc/install_devices_disks_changed grub-pc/install_devices_empty \
        grub-pc/install_devices_failed grub-pc/install_devices_failed_upgrade grub-pc/cloud_style_installation; do
        # An unregistered question is recorded as absent (10), never created by GET.
        output="$(printf 'GET %s\nFGET %s seen\n' "$key" "$key" | debconf-communicate grub-pc 2>/dev/null)" || {
            [[ "$output" == 10\ * ]] || return 3
        }
        printf '%s\n%s\n' "$key" "$output"
    done
}

_kernel_grub_install_config_paths() {
    local package
    printf '%s\n' "$KERNEL_GRUB_DEFAULT_FILE" "$KERNEL_GRUB_DEFAULT_DIR" \
        "$(vps_cmd_system_path /etc/grub.d)" "$KERNEL_BOOT_DIR/grub" \
        "$(vps_cmd_system_path /usr/lib/grub/i386-pc)"
    for package in "${!KERNEL_GRUB_INSTALL_EXPECTED_VERSIONS[@]}"; do
        case "${package%%:*}" in
            grub-efi-amd64-bin | grub-efi-amd64-unsigned)
                printf '%s\n' "$(vps_cmd_system_path /usr/lib/grub/x86_64-efi)"
                break
                ;;
        esac
    done
}

_kernel_grub_install_config_signature() {
    local path
    local -a paths=()
    mapfile -t paths < <(_kernel_grub_install_config_paths)
    for path in "${paths[@]}"; do
        vps_cmd_require_no_symlink_components "$path" || return $?
    done
    paths+=("$(vps_cmd_system_path /etc/apt)" "$(vps_cmd_system_path /var/lib/dpkg/status)")
    paths+=("$KERNEL_BOOT_DIR/vmlinuz-$KERNEL_GRUB_INSTALL_DEFAULT_RELEASE" "$KERNEL_BOOT_DIR/initrd.img-$KERNEL_GRUB_INSTALL_DEFAULT_RELEASE")
    if [[ -n "$KERNEL_GRUB_INSTALL_NEXT_RELEASE" ]]; then
        paths+=("$KERNEL_BOOT_DIR/vmlinuz-$KERNEL_GRUB_INSTALL_NEXT_RELEASE" "$KERNEL_BOOT_DIR/initrd.img-$KERNEL_GRUB_INSTALL_NEXT_RELEASE")
    fi
    python3 - "${paths[@]}" <<'PY'
import hashlib
import os
import stat
import sys

digest = hashlib.sha256()
def walk(path):
    digest.update(os.fsencode(path) + b"\0")
    if not os.path.lexists(path):
        digest.update(b"absent\0")
        return
    mode = os.lstat(path)
    if mode.st_uid != 0 or mode.st_mode & 0o022:
        raise ValueError("配置或启动文件不是 root 独占可写：" + path)
    digest.update(str((mode.st_mode, mode.st_uid, mode.st_gid, mode.st_size)).encode())
    if stat.S_ISDIR(mode.st_mode):
        for child in sorted(os.listdir(path)):
            walk(os.path.join(path, child))
    elif stat.S_ISREG(mode.st_mode):
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(1048576), b""):
                digest.update(chunk)
    else:
        raise ValueError("配置或启动文件包含链接或特殊文件：" + path)
try:
    for path in sys.argv[1:]:
        walk(path)
    print(digest.hexdigest())
except (OSError, ValueError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(3)
PY
}

_kernel_grub_install_boot_signature() {
    local release
    for release in "${KERNEL_GRUB_INSTALL_PROTECTED_RELEASES[@]}"; do
        sha256sum -- "$KERNEL_BOOT_DIR/vmlinuz-$release" "$KERNEL_BOOT_DIR/initrd.img-$release" || return 3
    done
}

_kernel_grub_install_prepare() {
    local package configs debconf packages
    _kernel_grub_install_require_platform || return $?
    _kernel_grub_install_validate_paths || return $?
    _kernel_grub_install_probe_disk "${KERNEL_GRUB_DISK:-}" || return $?
    kernel_inventory_load || return $?
    _kernel_grub_install_plan_packages || return $?
    _kernel_grub_install_plan_defaults || return $?
    KERNEL_GRUB_INSTALL_PROTECTED_RELEASES=("$KERNEL_GRUB_INSTALL_DEFAULT_RELEASE")
    [[ -z "$KERNEL_GRUB_INSTALL_NEXT_RELEASE" ]] || _kernel_inventory_append_unique KERNEL_GRUB_INSTALL_PROTECTED_RELEASES "$KERNEL_GRUB_INSTALL_NEXT_RELEASE"
    if [[ "${KERNEL_RELEASE_COMPLETE[$KERNEL_RUNNING_RELEASE]:-0}" == 1 && "${KERNEL_RELEASE_MANAGED[$KERNEL_RUNNING_RELEASE]:-0}" == 1 ]]; then
        _kernel_inventory_append_unique KERNEL_GRUB_INSTALL_PROTECTED_RELEASES "$KERNEL_RUNNING_RELEASE"
    fi
    KERNEL_GRUB_INSTALL_BOOT_SIGNATURE="$(_kernel_grub_install_boot_signature)" || return 3
    configs="$(_kernel_grub_install_config_signature)" || return $?
    debconf="$(_kernel_grub_install_debconf_snapshot)" || {
        vps_cmd_error '无法读取 GRUB debconf 备份数据'
        return 3
    }
    packages="$(for package in "${!KERNEL_GRUB_INSTALL_EXPECTED_VERSIONS[@]}"; do
        printf '%s=%s\n' "$package" "${KERNEL_GRUB_INSTALL_EXPECTED_VERSIONS[$package]}"
    done | LC_ALL=C sort)"
    KERNEL_GRUB_INSTALL_PLAN_SIGNATURE="$(printf '%s\n' "$KERNEL_GRUB_INSTALL_DISK_DATA" "$configs" "$debconf" "$packages" \
        "$KERNEL_GRUB_INSTALL_DEFAULT_RELEASE" "$KERNEL_GRUB_INSTALL_NEXT_RELEASE" "$KERNEL_GRUB_INSTALL_NEXT_ID" \
        "$KERNEL_GRUB_INSTALL_CLEAR_NEXT" "$KERNEL_GRUB_INSTALL_FALLBACK" \
        "$KERNEL_GRUB_INSTALL_BOOT_SIGNATURE" | sha256sum)" || return 3
}

_kernel_grub_install_show_plan() {
    vps_cmd_status 'BIOS GRUB 目标' "$KERNEL_GRUB_INSTALL_DISK（$KERNEL_GRUB_INSTALL_SIZE 字节，$KERNEL_GRUB_INSTALL_LABEL）" normal
    vps_cmd_status '根分区 /' "$KERNEL_GRUB_INSTALL_ROOT_PART" normal
    vps_cmd_status '/boot 所在分区' "$KERNEL_GRUB_INSTALL_BOOT_PART" normal
    vps_cmd_status '引导区备份' "偏移 $KERNEL_GRUB_INSTALL_REGION_OFFSET，长度 $KERNEL_GRUB_INSTALL_REGION_LENGTH 字节" normal
    [[ "$KERNEL_GRUB_INSTALL_LABEL" != gpt ]] || vps_cmd_info '另备份磁盘前 512 字节的保护 MBR；不修改分区表'
    if ((${#KERNEL_GRUB_INSTALL_ARGS[@]})); then
        vps_cmd_info "APT 完整包变更：$(kernel_join_values "${KERNEL_GRUB_INSTALL_ARGS[@]}")"
    else
        vps_cmd_info 'GRUB 软件包已满足要求；本次仅修复引导安装及配置，不升级软件包'
    fi
    if [[ "$KERNEL_GRUB_INSTALL_FALLBACK" == 1 ]]; then
        vps_cmd_warning "原默认项无法安全解析；将固定当前运行内核 $KERNEL_GRUB_INSTALL_DEFAULT_RELEASE 并清除单次覆盖"
    else
        vps_cmd_info "保留原默认内核 $KERNEL_GRUB_INSTALL_DEFAULT_RELEASE，并固定为精确稳定菜单 ID"
    fi
    if [[ "$KERNEL_GRUB_INSTALL_CLEAR_NEXT" == 1 ]]; then
        vps_cmd_info '单次覆盖：清除 next_entry（包括缺失或无法解析的覆盖）'
    else
        vps_cmd_info "保留有效单次覆盖内核：$KERNEL_GRUB_INSTALL_NEXT_RELEASE"
    fi
    vps_cmd_info '包安装期间将清空旧 debconf 安装盘以阻止维护脚本强制写盘；随后显式安装无 --force 的 i386-pc GRUB，并保存确认目标'
    vps_cmd_info '将关闭云镜像 cloud_style_installation 自动选盘选项，使后续 GRUB 维护继续使用本次确认的目标盘'
}

_kernel_grub_install_stage() {
    local stage="$1"
    printf '%s\n' "$stage" >"$KERNEL_GRUB_INSTALL_BACKUP/stage" || return 20
    printf '%s %s\n' "$(date -u +%FT%TZ)" "$stage" >>"$KERNEL_GRUB_INSTALL_BACKUP/transaction.log" || return 20
    sync -f "$KERNEL_GRUB_INSTALL_BACKUP/stage" || return 20
}

_kernel_grub_install_backup() {
    local path free needed=16777216 bytes
    local -a paths=() present=()
    mapfile -t paths < <(_kernel_grub_install_config_paths)
    for path in "${paths[@]}"; do
        [[ -e "$path" ]] || continue
        bytes="$(du -s -B1 -- "$path")" || return 20
        bytes="${bytes%%[[:space:]]*}"
        [[ "$bytes" =~ ^[0-9]+$ ]] || return 20
        needed=$((needed + bytes))
        present+=("$path")
    done
    needed=$((needed + KERNEL_GRUB_INSTALL_REGION_LENGTH + 512))
    path="$KERNEL_GRUB_BACKUP_ROOT"
    while [[ ! -e "$path" ]]; do path="${path%/*}"; done
    free="$(df -B1 --output=avail -- "$path" | awk 'NR == 2 {print $1}')" || return 20
    [[ "$free" =~ ^[0-9]+$ ]] && ((free >= needed)) || {
        vps_cmd_error "备份空间不足，至少需要 $needed 字节；未开始安装"
        return 20
    }
    install -d -m 0700 -- "$KERNEL_GRUB_BACKUP_ROOT" || return 20
    KERNEL_GRUB_INSTALL_BACKUP="$(mktemp -d "$KERNEL_GRUB_BACKUP_ROOT/bios-grub.$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")" || return 20
    chmod 0700 -- "$KERNEL_GRUB_INSTALL_BACKUP" || return 20
    _kernel_grub_install_stage backing-up || return $?
    printf '%s\n' "$KERNEL_GRUB_INSTALL_DISK_DATA" >"$KERNEL_GRUB_INSTALL_BACKUP/disk-layout.json" || return 20
    printf '%s\n' "$KERNEL_GRUB_INSTALL_TABLE_DATA" >"$KERNEL_GRUB_INSTALL_BACKUP/partition-table.json" || return 20
    sfdisk --dump "$KERNEL_GRUB_INSTALL_DISK" >"$KERNEL_GRUB_INSTALL_BACKUP/partition-table.sfdisk" || return 20
    LC_ALL=C dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' >"$KERNEL_GRUB_INSTALL_BACKUP/packages.tsv" || return 20
    _kernel_grub_install_debconf_snapshot >"$KERNEL_GRUB_INSTALL_BACKUP/debconf.txt" || return 20
    printf '%s\n' "${KERNEL_GRUB_INSTALL_ARGS[@]}" >"$KERNEL_GRUB_INSTALL_BACKUP/apt-plan.txt" || return 20
    tar --create --absolute-names --file "$KERNEL_GRUB_INSTALL_BACKUP/grub-files.tar" -- "${present[@]}" || return 20
    tar --list --file "$KERNEL_GRUB_INSTALL_BACKUP/grub-files.tar" >/dev/null || return 20
    printf 'file\tdisk\toffset_bytes\tlength_bytes\n' >"$KERNEL_GRUB_INSTALL_BACKUP/disk-regions.tsv" || return 20
    if [[ "$KERNEL_GRUB_INSTALL_LABEL" == gpt ]]; then
        dd if="$KERNEL_GRUB_INSTALL_DISK" of="$KERNEL_GRUB_INSTALL_BACKUP/protective-mbr.bin" bs=512 count=1 iflag=fullblock status=none || return 20
        [[ "$(stat -c %s "$KERNEL_GRUB_INSTALL_BACKUP/protective-mbr.bin")" == 512 ]] || return 20
        printf 'protective-mbr.bin\t%s\t0\t512\n' "$KERNEL_GRUB_INSTALL_DISK" >>"$KERNEL_GRUB_INSTALL_BACKUP/disk-regions.tsv" || return 20
    fi
    dd if="$KERNEL_GRUB_INSTALL_DISK" of="$KERNEL_GRUB_INSTALL_BACKUP/embedding-region.bin" bs=1M \
        iflag=skip_bytes,count_bytes,fullblock skip="$KERNEL_GRUB_INSTALL_REGION_OFFSET" count="$KERNEL_GRUB_INSTALL_REGION_LENGTH" status=none || return 20
    [[ "$(stat -c %s "$KERNEL_GRUB_INSTALL_BACKUP/embedding-region.bin")" == "$KERNEL_GRUB_INSTALL_REGION_LENGTH" ]] || return 20
    printf 'embedding-region.bin\t%s\t%s\t%s\n' "$KERNEL_GRUB_INSTALL_DISK" "$KERNEL_GRUB_INSTALL_REGION_OFFSET" "$KERNEL_GRUB_INSTALL_REGION_LENGTH" >>"$KERNEL_GRUB_INSTALL_BACKUP/disk-regions.tsv" || return 20
    {
        printf 'BIOS GRUB recovery evidence; target: %s\n' "$KERNEL_GRUB_INSTALL_DISK"
        printf 'Original default/fallback release: %s\n' "$KERNEL_GRUB_INSTALL_DEFAULT_RELEASE"
        printf 'Saved next release: %s\n' "${KERNEL_GRUB_INSTALL_NEXT_RELEASE:-none}"
        cat <<'EOF'
No automatic boot-sector rollback is attempted. APT, debconf and boot files may
already have changed if the stage indicates installation. Do not reboot after a
failure until the boot path has been checked from a console or rescue system.

Keep a copy of this directory off the machine. First verify SHA256SUMS, compare
disk-layout.json and partition-table.sfdisk with the actual disk identity and
layout, and inspect transaction.log and stage. grub-files.tar contains absolute
paths; inspect its contents before restoring selected files. packages.tsv and
debconf.txt record the previous package and GRUB debconf state.

disk-regions.tsv records exact byte offsets and lengths for raw rescue recovery.
Only restore raw regions from a rescue system after independently checking the
disk identity and unchanged partition layout. Restoring files alone does not
restore an installed boot sector; restoring a raw region does not roll back APT.
The script never creates partitions, formats devices, or supplies --force.
EOF
    } >"$KERNEL_GRUB_INSTALL_BACKUP/RECOVERY.txt" || return 20
    (
        cd -- "$KERNEL_GRUB_INSTALL_BACKUP" || exit 20
        sha256sum -- disk-layout.json partition-table.json partition-table.sfdisk packages.tsv debconf.txt \
            apt-plan.txt grub-files.tar disk-regions.tsv embedding-region.bin RECOVERY.txt >SHA256SUMS || exit 20
        [[ ! -f protective-mbr.bin ]] || sha256sum -- protective-mbr.bin >>SHA256SUMS || exit 20
        sha256sum --check --status SHA256SUMS || exit 20
    ) || return 20
    sync -f "$KERNEL_GRUB_INSTALL_BACKUP" || return 20
    _kernel_grub_install_stage backup-complete
}

_kernel_grub_install_run() {
    "$@" 2>&1 | tee -a "$KERNEL_GRUB_INSTALL_BACKUP/transaction.log"
}

_kernel_grub_install_seed_devices() {
    local mode="$1" target='' empty=true output key expected
    if [[ "$mode" == persist ]]; then
        target="$KERNEL_GRUB_INSTALL_DISK"
        empty=false
    fi
    {
        printf 'grub-pc grub-pc/install_devices multiselect %s\n' "$target"
        printf 'grub-pc grub-pc/install_devices_disks_changed multiselect %s\n' "$target"
        printf 'grub-pc grub-pc/install_devices_empty boolean %s\n' "$empty"
        printf 'grub-pc grub-pc/install_devices_failed boolean false\n'
        printf 'grub-pc grub-pc/install_devices_failed_upgrade boolean false\n'
        printf 'grub-pc grub-pc/cloud_style_installation boolean false\n'
        printf 'grub-pc grub-pc/install_devices seen true\n'
        printf 'grub-pc grub-pc/install_devices_disks_changed seen true\n'
        printf 'grub-pc grub-pc/install_devices_empty seen true\n'
        printf 'grub-pc grub-pc/cloud_style_installation seen true\n'
    } | debconf-set-selections >>"$KERNEL_GRUB_INSTALL_BACKUP/transaction.log" 2>&1 || return 30
    for key in install_devices install_devices_disks_changed install_devices_empty install_devices_failed install_devices_failed_upgrade cloud_style_installation; do
        case "$key" in
            install_devices | install_devices_disks_changed) expected="$target" ;;
            install_devices_empty) expected="$empty" ;;
            *) expected=false ;;
        esac
        output="$(printf 'GET grub-pc/%s\n' "$key" | debconf-communicate grub-pc 2>/dev/null)" || return 30
        [[ "$output" == "0 $expected" ]] || {
            vps_cmd_error "debconf grub-pc/$key 与计划不一致；不会继续调用安装程序"
            return 30
        }
    done
}

_kernel_grub_install_verify_packages() {
    local package resolved
    kernel_inventory_load || return 30
    for package in grub-pc grub-pc-bin grub-common grub2-common; do
        resolved="$(_kernel_inventory_resolve_package "$package")" && kernel_inventory_package_installed "$resolved" || {
            vps_cmd_error "安装后未确认完整软件包：$package"
            return 30
        }
    done
    for package in "${!KERNEL_GRUB_INSTALL_EXPECTED_VERSIONS[@]}"; do
        resolved="$(_kernel_inventory_resolve_package "$package")" || return 30
        kernel_inventory_package_installed "$resolved" &&
            [[ "${KERNEL_PKG_VERSION[$resolved]}" == "${KERNEL_GRUB_INSTALL_EXPECTED_VERSIONS[$package]}" ]] || {
            vps_cmd_error "安装后包版本与确认计划不一致：$package"
            return 30
        }
    done
    for package in grub-install update-grub grub-editenv; do
        command -v "$package" >/dev/null 2>&1 || return 30
    done
}

_kernel_grub_install_execute() {
    local target next='' output release old_table="$KERNEL_GRUB_INSTALL_TABLE_DATA"
    _kernel_grub_install_stage suppress-package-boot-writes || return 30
    _kernel_grub_install_seed_devices suppress || return 30
    if ((${#KERNEL_GRUB_INSTALL_ARGS[@]})); then
        _kernel_grub_install_stage apt-install || return 30
        _kernel_grub_install_run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
            apt-get -o APT::Get::AutomaticRemove=false -o Dpkg::Options::=--force-confold \
            install -y --no-remove --no-install-recommends "${KERNEL_GRUB_INSTALL_ARGS[@]}" || return 30
    fi
    _kernel_grub_install_verify_packages || return 30
    _kernel_grub_install_stage grub-install || return 30
    _kernel_grub_install_run grub-install --target=i386-pc --boot-directory=/boot --no-floppy "$KERNEL_GRUB_INSTALL_DISK" || return 30
    _kernel_grub_install_seed_devices persist || return 30
    # First generate fresh menu IDs; package installation may have provided the
    # generator for the first time. The final configured default is checked below.
    _kernel_grub_install_stage generate-menu || return 30
    _kernel_grub_install_run update-grub || return 30
    kernel_grub_load_config || true
    target="${KERNEL_GRUB_ENTRY[$KERNEL_GRUB_INSTALL_DEFAULT_RELEASE]:-}"
    [[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._+/@:=-]*(\>[A-Za-z0-9][A-Za-z0-9._+/@:=-]*)?$ ]] || {
        vps_cmd_error '新生成的菜单没有计划默认内核的唯一精确稳定 ID'
        return 30
    }
    if [[ "$KERNEL_GRUB_INSTALL_CLEAR_NEXT" == 0 ]]; then
        # A numeric/simple entry can move when the menu is regenerated. Preserve
        # its snapshotted release through the new precise version entry instead.
        next="${KERNEL_GRUB_ENTRY[$KERNEL_GRUB_INSTALL_NEXT_RELEASE]:-}"
        [[ "$next" =~ ^[A-Za-z0-9][A-Za-z0-9._+/@:=-]*(\>[A-Za-z0-9][A-Za-z0-9._+/@:=-]*)?$ ]] || {
            vps_cmd_error '原单次覆盖内核在新菜单中没有唯一精确版本项'
            return 30
        }
    fi
    _kernel_grub_install_stage configure-default || return 30
    install -d -m 0755 -- "$KERNEL_GRUB_DEFAULT_DIR" || return 30
    {
        printf '%s\n' "$KERNEL_MANAGED_MARKER"
        printf "GRUB_DEFAULT='%s'\nGRUB_SAVEDEFAULT=false\n" "$target"
    } | vps_cmd_atomic_write /etc/default/grub.d/99-vpsctl-kernel.cfg 0644 || return 30
    if [[ ! -f "$KERNEL_GRUB_ENV" ]]; then
        _kernel_grub_install_run grub-editenv "$KERNEL_GRUB_ENV" create || return 30
    fi
    if [[ -n "$next" ]]; then
        _kernel_grub_install_run grub-editenv "$KERNEL_GRUB_ENV" set "next_entry=$next" || return 30
    else
        _kernel_grub_install_run grub-editenv "$KERNEL_GRUB_ENV" unset next_entry || return 30
    fi
    _kernel_grub_install_run update-grub || return 30
    _kernel_grub_install_stage verify || return 30
    kernel_inventory_load || return 30
    for release in "${KERNEL_GRUB_INSTALL_PROTECTED_RELEASES[@]}"; do
        [[ "${KERNEL_RELEASE_COMPLETE[$release]:-0}" == 1 && "${KERNEL_RELEASE_MANAGED[$release]:-0}" == 1 ]] || {
            vps_cmd_error "安装后的保留内核启动文件或包状态不完整：$release"
            return 30
        }
    done
    output="$(_kernel_grub_install_boot_signature)" || return 30
    [[ "$output" == "$KERNEL_GRUB_INSTALL_BOOT_SIGNATURE" ]] || {
        vps_cmd_error '安装过程中保留内核的镜像或 initrd 内容发生变化'
        return 30
    }
    kernel_grub_load
    [[ "$KERNEL_GRUB_SUPPORTED" == 1 && "$KERNEL_GRUB_DEFAULT_RELEASE" == "$KERNEL_GRUB_INSTALL_DEFAULT_RELEASE" &&
        "$KERNEL_GRUB_DEFAULT_ID" == "$target" && "$KERNEL_GRUB_NEXT_ID" == "$next" &&
        "$KERNEL_GRUB_RAW_DEFAULT" == "$target" && "$KERNEL_GRUB_RAW_SAVEDEFAULT" == false &&
        "$KERNEL_GRUB_NEXT_RELEASE" == "$KERNEL_GRUB_INSTALL_NEXT_RELEASE" &&
        "${KERNEL_RELEASE_COMPLETE[$KERNEL_GRUB_INSTALL_DEFAULT_RELEASE]:-0}" == 1 ]] || {
        vps_cmd_error 'BIOS GRUB 默认项、单次覆盖或启动文件回读不符合确认计划'
        return 30
    }
    [[ -s "$KERNEL_BOOT_DIR/grub/i386-pc/normal.mod" ]] || return 30
    _kernel_grub_install_probe_disk "$KERNEL_GRUB_INSTALL_DISK" || return 30
    [[ "$old_table" == "$KERNEL_GRUB_INSTALL_TABLE_DATA" ]] || {
        vps_cmd_error '安装后分区表发生变化，必须从控制台检查'
        return 30
    }
    output="$(printf 'GET grub-pc/install_devices\n' | debconf-communicate grub-pc 2>/dev/null)" || return 30
    [[ "$output" == "0 $KERNEL_GRUB_INSTALL_DISK" ]] || {
        vps_cmd_error 'debconf 回读不是已确认的唯一目标盘'
        return 30
    }
    _kernel_grub_install_stage complete-pending-reboot || return 30
}

_kernel_grub_install_exit() {
    local status="$1"
    trap - EXIT HUP INT TERM
    if [[ "${KERNEL_GRUB_INSTALL_MUTATING:-0}" == 1 ]]; then
        status=30
        vps_cmd_error "BIOS GRUB 安装部分完成；请检查 $KERNEL_GRUB_INSTALL_BACKUP 的 stage、transaction.log 与 RECOVERY.txt，确认修复后再重启"
        printf '%s\n' 'incomplete; inspect the last stage and transaction.log' >"$KERNEL_GRUB_INSTALL_BACKUP/result" || true
    fi
    kernel_cleanup
    exit "$status"
}

kernel_install_grub() (
    local signature
    umask 077
    KERNEL_GRUB_INSTALL_MUTATING=0
    KERNEL_GRUB_INSTALL_BACKUP=''
    vps_cmd_require_root || return $?
    if [[ -z "${KERNEL_GRUB_DISK:-}" ]] && ! vps_cmd_is_interactive && [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        vps_cmd_error '非交互 install-grub 必须用 --disk 明确指定整盘设备'
        return 3
    fi
    _kernel_grub_install_prepare || return $?
    _kernel_grub_install_show_plan
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info '演练完成：未刷新 APT、写入 debconf、创建备份或修改启动文件'
        return 0
    fi
    signature="$KERNEL_GRUB_INSTALL_PLAN_SIGNATURE"
    kernel_confirm_action install-grub "${KERNEL_CONFIRM_INSTALL_GRUB:-}" "$KERNEL_INSTALL_GRUB_TOKEN" \
        "确认向 $KERNEL_GRUB_INSTALL_DISK 安装 BIOS GRUB；请先确认控制台或救援入口可用。" || return $?
    kernel_take_lock || return $?
    trap '_kernel_grub_install_exit $?' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _kernel_grub_install_prepare || return $?
    [[ "$signature" == "$KERNEL_GRUB_INSTALL_PLAN_SIGNATURE" ]] || {
        vps_cmd_error '确认后磁盘、配置、包状态或 APT 计划发生变化，未开始安装；请重新检查并确认'
        return 3
    }
    _kernel_grub_install_backup || return $?
    _kernel_grub_install_prepare || return $?
    [[ "$signature" == "$KERNEL_GRUB_INSTALL_PLAN_SIGNATURE" ]] || {
        vps_cmd_error '备份期间系统状态发生变化，未开始安装；已保留备份'
        return 3
    }
    KERNEL_GRUB_INSTALL_MUTATING=1
    _kernel_grub_install_execute || return 30
    KERNEL_GRUB_INSTALL_MUTATING=0
    vps_cmd_success 'BIOS GRUB 安装与配置校验通过，待重启验证'
    vps_cmd_status '默认启动内核' "$KERNEL_GRUB_INSTALL_DEFAULT_RELEASE" normal
    vps_cmd_info "恢复材料保留在 $KERNEL_GRUB_INSTALL_BACKUP"
    vps_cmd_info '如需更换默认版本，请执行 vpsctl system kernel switch --release 完整内核版本；自行重启后用 uname -r 核对'
)
