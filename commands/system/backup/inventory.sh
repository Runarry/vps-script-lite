# shellcheck shell=bash
# Inventory has no system mutations. Filesystem lists are explicit ReaR input.

bs_platform() {
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
        vps_cmd_error '当前整机适配需要 GNU/Linux x86_64；其他架构尚未验收。'
        return 3
    }
    local release id virtualization=''
    release="$(vps_cmd_system_path /etc/os-release)"
    id="$(awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' "$release")"
    case "$id" in debian | ubuntu | rhel | rocky | almalinux | centos | fedora) ;; *)
        vps_cmd_error "发行版 $id 尚无本项目 ReaR 适配（Alpine/musl/OpenRC 不支持该整机路径）。"
        return 3
        ;;
    esac
    [[ -d "$(vps_cmd_system_path /run/systemd/system)" ]] || {
        vps_cmd_error '整机停服与恢复当前需要 systemd。'
        return 3
    }
    if command -v systemd-detect-virt >/dev/null 2>&1; then virtualization="$(systemd-detect-virt --container 2>/dev/null)" || virtualization=''; fi
    [[ -z "$virtualization" || "$virtualization" == none ]] || {
        vps_cmd_error "运行于容器 $virtualization，不能管理宿主机磁盘/内核，拒绝裸机路径。"
        return 3
    }
    [[ ! -d "$(vps_cmd_system_path /sys/firmware/efi)" ]] || {
        if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
            vps_cmd_error 'Secure Boot 已启用；本项目尚未验收该介质签名/启动组合。'
            return 3
        fi
    }
}

bs_inventory() {
    local mounts blocks boot=BIOS platform='prerequisites-only' diagnostics='[]' rc=0 work_mount='' path=''
    mounts="$(findmnt --json --list --output TARGET,SOURCE,FSTYPE,OPTIONS)" || return 20
    blocks="$(lsblk --json --bytes --paths --output NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,PKNAME,UUID,SERIAL,WWN)" || return 20
    [[ ! -d "$(vps_cmd_system_path /sys/firmware/efi)" ]] || boot=UEFI
    if ! bs_platform >/dev/null 2>&1; then
        platform=unsupported
        diagnostics='["平台不满足；configure/run 将输出具体原因"]'
    fi
    if [[ -n "${BS_WORK:-}" ]]; then
        path="$BS_WORK"
        while [[ ! -e "$path" && "$path" != / ]]; do
            path="${path%/*}"
            [[ -n "$path" ]] || path=/
        done
        work_mount="$(findmnt -n -o TARGET -T "$path")" || return 20
    fi
    BS_INVENTORY="$(jq -nc --argjson mounts "$mounts" --argjson blocks "$blocks" \
        --arg boot "$boot" --arg platform "$platform" --arg work_mount "$work_mount" --arg work "${BS_WORK:-}" \
        --argjson excludes "$(bs_json_array "${BS_EXCLUDE_MOUNTS[@]}")" --argjson excluded_devices "$(bs_json_array "${BS_EXCLUDE_DEVICES[@]}")" \
        --argjson diagnostics "$diagnostics" --arg architecture "$(uname -m)" '
        def pseudo: test("^(proc|sysfs|devtmpfs|tmpfs|devpts|cgroup2?|securityfs|selinuxfs|bpf|pstore|debugfs|tracefs|configfs|fusectl|mqueue|hugetlbfs|rpc_pipefs|binfmt_misc|autofs|overlay|squashfs|iso9660|efivarfs|nsfs)$");
        {schema_version:1,architecture:$architecture,boot:$boot,capability:$platform,validation:"未验收组合；能力检查不是启动恢复验收",diagnostics:$diagnostics,
         mounts:[$mounts.filesystems[] | . as $m | . + {coverage:(
            if (.fstype|pseudo) then "runtime"
            elif ($excludes|index($m.target))!=null then "excluded-explicit"
            elif $work_mount!="" and .target==$work_mount and (["/","/boot","/boot/efi","/usr","/var","/home","/opt","/srv"]|index($m.target)|not) then "excluded-staging"
            elif (.source|startswith("/dev/")) and (.fstype|test("^(ext[234]|xfs|vfat)$")) then "included"
            else "unresolved" end)}],
         devices:$blocks.blockdevices,
         unmounted:[$blocks.blockdevices[] | recurse(.children[]?) | select((.fstype//"")!="" and .fstype!="swap" and .fstype!="LVM2_member" and .type!="rom" and (.mountpoint==null or .mountpoint=="")) | . as $d | {device:.name,fstype,coverage:(if ($excluded_devices|index($d.name))!=null then "excluded-explicit" else "unresolved" end)}],
         work_dir:$work,work_mount:$work_mount,consistency:"计划内写入者正常停止；操作系统在线文件不保证全盘原子时点"}')" || rc=$?
    ((rc == 0)) || return 20
}

bs_print_inventory() {
    jq -r '"平台：\(.architecture) / \(.boot) / \(.capability)",.validation,(.mounts[]|"\(.coverage)：\(.target) ← \(.source) (\(.fstype))"),(.unmounted[]|"\(.coverage)：未挂载 \(.device) (\(.fstype))"),"暂存目录：\(.work_dir)，所在挂载点：\(.work_mount)",.consistency' <<<"$BS_INVENTORY"
}

bs_persistent_mounts() {
    jq -c '[.mounts[]|select(.coverage!="runtime")|{target,source,fstype,coverage}]|sort_by(.target)' <<<"$BS_INVENTORY"
}

bs_check_coverage() {
    local item source mount excluded
    bs_print_inventory >&2
    jq -e 'all(.mounts[]; .coverage!="unresolved") and all(.unmounted[]; .coverage!="unresolved")' <<<"$BS_INVENTORY" >/dev/null || {
        vps_cmd_error '存在未明确覆盖的挂载/未挂载文件系统；外部存储不会自动算作完整。请挂载后纳入，或用 --exclude-mount / --exclude-device 明确排除。'
        return 3
    }
    jq -e '[.mounts[]|select(.coverage=="included" and .target=="/")]|length==1' <<<"$BS_INVENTORY" >/dev/null || return 3
    for item in "${BS_EXCLUDE_MOUNTS[@]}"; do
        case "$item" in / | /boot | /boot/efi | /usr | /var | /etc)
            vps_cmd_error "不能排除系统必需挂载 $item"
            return 2
            ;;
        esac
    done
    for item in "${BS_EXCLUDE_PATHS[@]}"; do
        case "$item" in /boot | /boot/efi | /usr | /var | /etc | /etc/vpsctl | /usr/local/libexec)
            vps_cmd_error "不能排除恢复必需路径 $item"
            return 2
            ;;
        esac
    done
    while IFS= read -r item; do
        [[ "$item" != *[[:space:]\*\?\[]* ]] || {
            vps_cmd_error "ReaR NETFS 当前路径接口不支持空格或通配符：$item"
            return 3
        }
    done < <(jq -r '.mounts[]|select(.coverage=="included")|.target' <<<"$BS_INVENTORY")
    if jq -e '[.devices[]|recurse(.children[]?)|select(.type|test("crypt|raid|mpath"))]|length>0' <<<"$BS_INVENTORY" >/dev/null; then
        vps_cmd_error '检测到 LUKS/mdraid/multipath，当前恢复适配尚未验收，停止采集。'
        return 3
    fi
    # A staging disk cannot also contain a source filesystem: excluding its layout
    # would make a successful archive impossible to restore completely.
    excluded="$(jq -r '.work_mount' <<<"$BS_INVENTORY")"
    if jq -e --arg mount "$excluded" 'any(.mounts[]; .target==$mount and .coverage=="excluded-staging")' <<<"$BS_INVENTORY" >/dev/null; then
        source="$(jq -r --arg mount "$excluded" '.mounts[]|select(.target==$mount)|.source' <<<"$BS_INVENTORY")"
        if [[ "$source" != /dev/* ]]; then
            case "$(jq -r --arg mount "$excluded" '.mounts[]|select(.target==$mount)|.fstype' <<<"$BS_INVENTORY")" in
                nfs | nfs4 | cifs | tmpfs)
                    BS_STAGING_DISKS=''
                    return 0
                    ;;
                *)
                    vps_cmd_error "暂存挂载来源无法识别：$source"
                    return 3
                    ;;
            esac
        fi
        BS_STAGING_DISKS="$(lsblk -s -n -p -o NAME,TYPE "${source%%\[*}" | awk '$2=="disk" {print $1}')" || return 20
        while IFS= read -r mount; do
            source="$(jq -r --arg m "$mount" '.mounts[]|select(.target==$m)|.source' <<<"$BS_INVENTORY")"
            while IFS= read -r item; do
                [[ -z "$item" ]] || [[ $'\n'"$BS_STAGING_DISKS"$'\n' != *$'\n'"$item"$'\n'* ]] || {
                    vps_cmd_error "暂存盘 $item 同时包含纳入挂载 $mount；请选择独立保存盘，或在根文件系统内使用仅目录排除。"
                    return 3
                }
            done < <(lsblk -s -n -p -o NAME,TYPE "${source%%\[*}" | awk '$2=="disk" {print $1}')
        done < <(jq -r '.mounts[]|select(.coverage=="included")|.target' <<<"$BS_INVENTORY")
    else BS_STAGING_DISKS=''; fi
}

bs_rear_capabilities() {
    local defaults variable
    defaults="$BS_REAR_SHARE/conf/default.conf"
    tar --version | grep -q 'GNU tar' || {
        vps_cmd_error '整机元数据归档需要 GNU tar。'
        return 3
    }
    for variable in BACKUP_ONLY_INCLUDE BACKUP_PROG_COMPRESS_OPTIONS NETFS_PREFIX EXCLUDE_COMPONENTS POST_RECOVERY_SCRIPT; do
        grep -q "^${variable}=" "$defaults" || {
            vps_cmd_error "安装的 ReaR 缺少接口 $variable，不能使用本路径契约。"
            return 3
        }
    done
    bs_iso_dependencies || return $?
    bs_discover_ssh_helpers || return $?
    # NETFS defaults otherwise accept tar status 1 (changed/unreadable sources).
    bs_rear -V >&2 || return 20
}

bs_discover_ssh_helpers() {
    local binary effective defaults='' table kind path resolved helper dependencies status library
    local -A seen_helpers=() seen_libraries=()
    BS_SSH_HELPERS=() BS_SSH_HELPER_LIBS=()
    binary="$(command -v sshd)" || return 0
    effective="$("$binary" -T)" || {
        vps_cmd_error '无法读取 sshd 有效配置以确认救援 SSH 辅助程序；请先检查 sshd -T。'
        return 3
    }
    # ReaR may simplify the copied server configuration, so include installed
    # compiled defaults as well as any explicitly configured helper locations.
    defaults="$("$binary" -T -f /dev/null 2>/dev/null)" || defaults=''
    for kind in effective defaults; do
        if [[ "$kind" == effective ]]; then table="$effective"; else table="$defaults"; fi
        while IFS=' ' read -r _ path; do
            [[ -n "$path" ]] || continue
            if [[ ! -f "$path" || ! -x "$path" ]]; then
                [[ "$kind" == defaults ]] && continue
                vps_cmd_error "sshd 配置引用的辅助程序不可执行：$path"
                return 3
            fi
            bs_safe_path "$path" || {
                vps_cmd_error "ReaR 无法可靠复制该 SSH helper 路径：$path"
                return 3
            }
            resolved="$(readlink -f -- "$path")" || return 20
            for helper in "$path" "$resolved"; do
                [[ -z "${seen_helpers[$helper]+x}" ]] || continue
                seen_helpers[$helper]=1
                BS_SSH_HELPERS+=("$helper")
            done
        done < <(printf '%s\n' "$table" | awk '$1=="sshdsessionpath" || $1=="sshdauthpath"')
    done
    ((${#BS_SSH_HELPERS[@]})) || return 0
    bs_need_read_tools ldd || return $?
    for helper in "${BS_SSH_HELPERS[@]}"; do
        status=0
        dependencies="$(LC_ALL=C ldd "$helper" 2>&1)" || status=$?
        if [[ "$dependencies" == *'not found'* ]]; then
            vps_cmd_error "SSH helper 存在缺失动态库，不能生成可用救援 SSH：$helper"
            return 3
        fi
        if ((status != 0)); then
            [[ "$dependencies" == *'not a dynamic executable'* || "$dependencies" == *'statically linked'* ]] || {
                vps_cmd_error "无法检查 SSH helper 动态库：$helper"
                return 3
            }
            continue
        fi
        while IFS= read -r library; do
            if [[ ! -f "$library" ]] || ! bs_safe_path "$library"; then
                vps_cmd_error "无法读取 SSH helper 动态库：$library"
                return 3
            fi
            [[ -z "${seen_libraries[$library]+x}" ]] || continue
            seen_libraries[$library]=1
            BS_SSH_HELPER_LIBS+=("$library")
        done < <(awk '/=> \// {print $3} /^[[:space:]]*\// {print $1}' <<<"$dependencies")
    done
}

bs_iso_dependencies() {
    local manager path found=0
    BS_ISOLINUX_BIN='' BS_SYSLINUX_MODULES='' BS_SYSLINUX_VERSION=''
    # xorriso also reads the finished image before it can become a snapshot.
    backup_ensure_tools xorriso || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 3
    if [[ -d "$(vps_cmd_system_path /sys/firmware/efi)" ]]; then
        command -v grub-mkimage >/dev/null 2>&1 || command -v grub2-mkimage >/dev/null 2>&1 || {
            vps_cmd_error 'UEFI ISO 缺少 grub-mkimage/grub2-mkimage；请安装发行版匹配的 EFI GRUB 工具后重试。'
            return 3
        }
        return 0
    fi
    # ReaR probes extlinux first. If it is missing, its version parser can
    # mistake 'rear-2.9' in Bash's error filename for the Syslinux version.
    backup_ensure_tools extlinux strings || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 3
    for path in /usr/lib/ISOLINUX/isolinux.bin /usr/share/syslinux/isolinux.bin /usr/lib/syslinux/isolinux.bin /usr/lib/syslinux/bios/isolinux.bin; do
        [[ ! -f "$path" ]] || found=1
    done
    if ((found == 1)) && bs_bios_assets; then return 0; fi
    manager="$(vps_cmd_detect_package_manager)" || return $?
    local -a packages=()
    case "$manager" in
        apt-get) packages=(isolinux syslinux-common) ;;
        dnf | dnf5 | yum) packages=(syslinux) ;;
        *)
            vps_cmd_error 'BIOS ISO 缺少 isolinux.bin；该包管理器的引导依赖尚未适配。'
            return 3
            ;;
    esac
    if [[ "$VPSCTL_DRY_RUN" != 1 && "$VPSCTL_INSTALL_DEPS" != 1 ]]; then
        vps_cmd_is_interactive || {
            vps_cmd_error "BIOS ISO 缺少 ${packages[*]}；使用 --install-deps 授权准备。"
            return 3
        }
        vps_cmd_warning "BIOS ISO 需要 ${packages[*]}"
        _vps_cmd_confirm_dependency_install || return $?
    fi
    vps_cmd_install_packages "$manager" "${packages[@]}" || return $?
    [[ "$VPSCTL_DRY_RUN" != 1 ]] || return 3
    for path in /usr/lib/ISOLINUX/isolinux.bin /usr/share/syslinux/isolinux.bin /usr/lib/syslinux/isolinux.bin /usr/lib/syslinux/bios/isolinux.bin; do
        [[ ! -f "$path" ]] || found=1
    done
    ((found == 1)) || {
        vps_cmd_error '安装后仍无 isolinux.bin；请检查发行版 ReaR ISO 依赖。'
        return 3
    }
    bs_bios_assets
}

bs_bios_assets() {
    local path module text image_version cli_version package_versions first_version
    BS_ISOLINUX_BIN='' BS_SYSLINUX_MODULES='' BS_SYSLINUX_VERSION=''
    for path in /usr/lib/ISOLINUX/isolinux.bin /usr/share/syslinux/isolinux.bin /usr/lib/syslinux/isolinux.bin /usr/lib/syslinux/bios/isolinux.bin; do
        path="$(vps_cmd_system_path "$path")" || return $?
        if [[ -s "$path" ]]; then
            BS_ISOLINUX_BIN="$path"
            break
        fi
    done
    for path in /usr/lib/syslinux/modules/bios /usr/share/syslinux /usr/lib/syslinux /usr/lib/syslinux/bios; do
        path="$(vps_cmd_system_path "$path")" || return $?
        for module in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32 chain.c32; do
            [[ -s "$path/$module" ]] || break
        done
        if [[ "$module" == chain.c32 && -s "$path/chain.c32" ]]; then
            BS_SYSLINUX_MODULES="$path"
            break
        fi
    done
    [[ -n "$BS_ISOLINUX_BIN" && -n "$BS_SYSLINUX_MODULES" ]] || {
        vps_cmd_error 'BIOS ISO 缺少同一模块目录中的 ldlinux.c32/libcom32.c32/libutil.c32/menu.c32/chain.c32 或 isolinux.bin；请准备匹配的 isolinux/syslinux-common。'
        return 3
    }
    text="$(extlinux --version 2>&1)" || {
        vps_cmd_error 'extlinux 版本查询失败，不能推测 ISO 引导 ABI。'
        return 3
    }
    [[ "$text" =~ [Ee][Xx][Tt][Ll][Ii][Nn][Uu][Xx][[:space:]]+([0-9]+\.[0-9]+) ]] || {
        vps_cmd_error "无法识别 extlinux 版本：$text"
        return 3
    }
    cli_version="${BASH_REMATCH[1]}"
    image_version="$(LC_ALL=C strings "$BS_ISOLINUX_BIN" | awk '/^ISOLINUX [0-9]+\.[0-9]+/ && !seen {print $2;seen=1}')" || return 20
    [[ -n "$image_version" && "$cli_version" == "$image_version" ]] || {
        vps_cmd_error "extlinux ($cli_version) 与 isolinux.bin ($image_version) 版本不匹配；拒绝混用引导模块。"
        return 3
    }
    if [[ "$BS_ISOLINUX_BIN" == */usr/lib/ISOLINUX/isolinux.bin && "$BS_SYSLINUX_MODULES" == */usr/lib/syslinux/modules/bios ]] && command -v dpkg-query >/dev/null 2>&1; then
        # shellcheck disable=SC2016 # dpkg-query expands its own package-format variable.
        package_versions="$(dpkg-query -W -f='${Version}\n' isolinux syslinux-common extlinux)" || return 3
        first_version="${package_versions%%$'\n'*}"
        while IFS= read -r text; do
            [[ -n "$first_version" && "$text" == "$first_version" ]] || {
                vps_cmd_error 'isolinux、syslinux-common、extlinux 的 Debian 包版本不一致；先安装匹配版本。'
                return 3
            }
        done <<<"$package_versions"
    fi
    BS_SYSLINUX_VERSION="$image_version"
    vps_cmd_info "BIOS 引导：Syslinux $BS_SYSLINUX_VERSION，$BS_ISOLINUX_BIN，模块 $BS_SYSLINUX_MODULES"
}

bs_space_check() {
    local mount bytes required=0 available probe="$BS_WORK" excluded
    local -a exclusions=()
    while [[ ! -d "$probe" && "$probe" != / ]]; do
        probe="${probe%/*}"
        [[ -n "$probe" ]] || probe=/
    done
    for excluded in /proc /sys /dev /run /tmp /var/log/rear "${BS_REAR_VAR:-/var/lib/rear}" "${BS_REAR_LOG_DIR:-/var/log/rear}" "$BS_WORK" "$BACKUP_STATE/jobs" "$BACKUP_STATE/cache" "$BACKUP_STATE/staging" "${BS_EXCLUDE_PATHS[@]}"; do
        exclusions+=("--exclude=$excluded")
    done
    while IFS= read -r excluded; do exclusions+=("--exclude=$excluded"); done < <(jq -r '.mounts[]|select(.coverage|startswith("excluded"))|.target' <<<"$BS_INVENTORY")
    while IFS= read -r mount; do
        bytes="$(du -sx -B1 "${exclusions[@]}" -- "$mount")" || {
            vps_cmd_error "无法估算纳入数据 $mount 的实际空间；尚未停服。"
            return 20
        }
        bytes="${bytes%%$'\t'*}"
        [[ "$bytes" =~ ^[0-9]+$ ]] || return 20
        required=$((required + bytes))
    done < <(jq -r '.mounts[]|select(.coverage=="included")|.target' <<<"$BS_INVENTORY")
    # Full allocation is conservative for sparse files. ReaR's build tree and ISO
    # need a further 1 GiB plus 20% for archive metadata and concurrent OS writes.
    required=$((required + required / 5 + 1073741824))
    available="$(df -B1 --output=avail "$probe" | tail -n 1 | tr -d ' ')" || return 20
    vps_cmd_info "全量归档+救援介质空间估算：$required 字节；可用 $available 字节（稀疏文件按已分配空间估算）。"
    if [[ ! "$available" =~ ^[0-9]+$ ]] || ((available < required)); then
        vps_cmd_error '暂存空间不足，尚未停止任何服务；请设置更大的 --work-dir。'
        return 3
    fi
}
