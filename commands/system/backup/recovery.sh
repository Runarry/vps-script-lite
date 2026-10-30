# shellcheck shell=bash
# Recovery executes only against a fully verified snapshot and explicit disk map.

bs_dns_address() {
    local ip="$1" part count=0 rest
    local -a parts=()
    if [[ "$ip" == *:* ]]; then
        [[ "$ip" =~ ^[a-fA-F0-9:]+$ && "$ip" != *:::* ]] || return 2
        rest="${ip#*::}"
        [[ "$rest" == "$ip" || "$rest" != *::* ]] || return 2
        IFS=: read -r -a parts <<<"$ip"
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && continue
            [[ ${#part} -le 4 ]] || return 2
            count=$((count + 1))
        done
        if [[ "$ip" == *::* ]]; then ((count < 8)); else ((count == 8)) && [[ "$ip" != :* && "$ip" != *: ]]; fi
    else
        IFS=. read -r -a parts <<<"$ip"
        ((${#parts[@]} == 4)) || return 2
        for part in "${parts[@]}"; do [[ "$part" =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((part <= 255)) || return 2; done
        [[ "$ip" != *. ]]
    fi
}

bs_dns_plan() {
    local address mode=preserve servers='[]'
    if [[ "$BS_NETWORK" == dhcp ]]; then
        if ((${#BS_DNS[@]})); then
            mode=static-explicit
            servers="$(bs_json_array "${BS_DNS[@]}")"
        elif [[ "$(jq -r '.network.resolved_available // false' <<<"$BS_RESTORE_MANIFEST")" == true ]]; then
            mode=dhcp-systemd-resolved
        else
            mode=static-source
            servers="$(jq -c '[.network.nameservers[]? | select(startswith("127.")|not) | select(.!="::1")]' <<<"$BS_RESTORE_MANIFEST")"
            [[ "$(jq length <<<"$servers")" != 0 ]] || {
                vps_cmd_error '源快照没有可用 resolver 或非回环 DNS；DHCP 恢复需显式 --dns IP，不能沿用失效 stub。'
                return 3
            }
            while IFS= read -r address; do bs_dns_address "$address" || return 10; done < <(jq -r '.[]' <<<"$servers")
        fi
    fi
    BS_DNS_PLAN="$(jq -nc --arg mode "$mode" --argjson servers "$servers" '{mode:$mode,servers:$servers,reachability:"重启后需验证 DNS 连通；不能从配置推断可达"}')"
}

# Resolve only archive paths, never host paths. This also handles ../ in a
# relative symlink without extracting it into the rescue filesystem.
bs_archive_path() {
    local part
    local -a parts=() result=()
    [[ "$1" =~ ^[A-Za-z0-9_./+@:-]+$ ]] || return 3
    IFS=/ read -r -a parts <<<"$1"
    for part in "${parts[@]}"; do
        case "$part" in
            '' | .) ;;
            ..) ((${#result[@]})) || return 3; unset 'result[${#result[@]}-1]' ;;
            *) result+=("$part") ;;
        esac
    done
    ((${#result[@]})) || return 3
    BS_ARCHIVE_PATH="$(IFS=/; printf '%s' "${result[*]}")"
}

bs_archive_resolve() {
    local path="$1" index="$2" entry name mode size member target suffix hop file_link=0
    for ((hop = 0; hop < 40; hop++)); do
        bs_archive_path "$path" || return 3
        path="$BS_ARCHIVE_PATH"
        # One index scan handles both the file and any parent directory alias.
        entry="$(awk -F '\t' -v path="$path" '
          $1 == path || ($2 ~ /^[lh]/ && index(path, $1 "/") == 1) {
            if (best == "" || length($1) < length(best)) {best=$1; row=$0}
          }
          END {print row}' "$index")" || return 3
        [[ -n "$entry" ]] || { ((file_link == 0)) && return 1; return 3; }
        IFS=$'\t' read -r name mode size member target <<<"$entry"
        case "${mode:0:1}" in
            l | h)
                suffix="${path#"$name"}"
                [[ -n "$suffix" ]] || file_link=1
                if [[ "${mode:0:1}" == h || "$target" == /* ]]; then
                    path="$target$suffix"
                else
                    path="${name%/*}/$target$suffix"
                    [[ "$name" == */* ]] || path="$target$suffix"
                fi
                ;;
            -)
                [[ "$size" =~ ^[0-9]+$ ]] && ((size > 0)) || return 3
                BS_ARCHIVE_MODE="$mode" BS_ARCHIVE_MEMBER="$member"
                return 0
                ;;
            *) return 3 ;;
        esac
    done
    return 3
}

bs_archive_systemd_component() {
    local archive="$1" index="$2" component="$3" directory rc=1 unit='' line section='' executable='' starts=0 dropin
    local -a dropins=()
    # A mask or broken override must not fall through to a vendor unit.
    for directory in etc/systemd/system usr/local/lib/systemd/system usr/lib/systemd/system lib/systemd/system; do
        if bs_archive_resolve "$directory/$component.service" "$index"; then
            unit="$BS_ARCHIVE_MEMBER"
            break
        else
            rc=$?
            ((rc == 1)) || return 3
        fi
    done
    [[ -n "$unit" ]] || return 3
    while IFS= read -r dropin; do
        bs_archive_resolve "$dropin" "$index" || return 3
        dropins+=("$BS_ARCHIVE_MEMBER")
    done < <(awk -F '\t' -v component="$component" '
      $1 ~ /^(etc|usr\/local\/lib|usr\/lib|lib)\/systemd\/system\// &&
      (index($1, "/" component ".service.d/") || index($1, "/service.d/")) && $1 ~ /\.conf$/ {print $1}' "$index")
    if ((${#dropins[@]})); then
        dropin="$(tar -xOf "$archive" --occurrence=1 -- "${dropins[@]}")" || return 3
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*ExecStart[[:space:]]*= ]]; then
                vps_cmd_error "$component 的 drop-in 改写了 ExecStart，不能可靠判断自定义启动程序。"
                return 3
            fi
        done <<<"$dropin"
    fi
    unit="$(tar -xOf "$archive" --occurrence=1 -- "$unit")" || return 3
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ "$line" =~ ^[[:space:]]*\[([^]]+)\][[:space:]]*$ ]]; then
            section="${BASH_REMATCH[1]}"
        elif [[ "$section" == Service && "$line" =~ ^[[:space:]]*ExecStart[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            starts=$((starts + 1))
            line="${BASH_REMATCH[1]}"
            # Native systemd units use an absolute executable, optionally with
            # execution prefixes. Do not guess shell wrappers or expansions.
            [[ "$line" =~ ^[-+!:@]*(/[A-Za-z0-9_./+-]+)([[:space:]].*)?$ ]] || return 3
            executable="${BASH_REMATCH[1]}"
        fi
    done <<<"$unit"
    [[ "$starts" == 1 && "${executable##*/}" == "$component" ]] || return 3
    bs_archive_resolve "$executable" "$index" || return 3
    [[ "${BS_ARCHIVE_MODE:3:1}${BS_ARCHIVE_MODE:6:1}${BS_ARCHIVE_MODE:9:1}" == *[xst]* ]]
}

bs_restore_network_check() (
    [[ "$BS_NETWORK" == dhcp ]] || return 0
    local archive="$BS_RESTORE_PAYLOAD/netfs/system/backup.tar" index component
    local -a components=(systemd-networkd)
    [[ "$(jq -r .mode <<<"$BS_DNS_PLAN")" != dhcp-systemd-resolved ]] || components+=(systemd-resolved)
    index="$(mktemp)" || return 20
    trap 'rm -f -- "$index"' EXIT
    # Read metadata once. Only the small selected unit is later streamed to
    # stdout; no system archive is unpacked and no archived program is run.
    if ! LC_ALL=C tar -tvf "$archive" --numeric-owner --full-time --quoting-style=escape | awk '
      {
        mode=$1; size=$3; name=$0
        sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", name)
        target="-"
        if (mode ~ /^l/) {p=index(name, " -> "); target=substr(name,p+4); name=substr(name,1,p-1)}
        if (mode ~ /^h/) {p=index(name, " link to "); target=substr(name,p+9); name=substr(name,1,p-1)}
        member=name
        while (sub(/^\.\//, "", name)) {}
        if (name ~ /^[A-Za-z0-9_.\/+@:-]+$/ && name !~ /(^|\/)\.\.($|\/)/ && mode !~ /^d/)
          printf "%s\t%s\t%s\t%s\t%s\n", name, mode, size, member, target
      }' >"$index"; then
        vps_cmd_error '无法读取封存的系统 tar；DHCP 恢复前置检查失败。'
        return 3
    fi
    for component in "${components[@]}"; do
        bs_archive_systemd_component "$archive" "$index" "$component" || {
            vps_cmd_error "封存系统缺少可用的 $component 单元或 ExecStart 程序，或含无法判断的自定义启动配置；使用 --network preserve，或在源机安装/修复组件后重新备份。"
            return 3
        }
    done
)

bs_restore_material() {
    BS_RESTORE_PAYLOAD="$BS_WORK/$BS_SNAPSHOT/payload"
    if [[ -d "$BS_RESTORE_PAYLOAD" ]]; then
        [[ -f "$BS_WORK/$BS_SNAPSHOT/snapshot-id" && "$(cat "$BS_WORK/$BS_SNAPSHOT/snapshot-id")" == "$BS_SNAPSHOT" ]] || {
            vps_cmd_error '本地恢复材料缺少匹配的快照绑定，选择新 --work-dir 重新取回。'
            return 3
        }
        backup_payload_verify "$BS_RESTORE_PAYLOAD" || return $?
    else
        [[ "$VPSCTL_DRY_RUN" != 1 ]] || {
            vps_cmd_error '演练不下载数据；请先真实运行 restore-plan 取回材料。'
            return 3
        }
        backup_restore_snapshot "$BS_REPO" "$BS_SNAPSHOT" "$BS_RESTORE_PAYLOAD" system || return $?
        printf '%s\n' "$BS_SNAPSHOT" >"$BS_WORK/$BS_SNAPSHOT/snapshot-id" || return 20
    fi
    backup_manifest_validate "$BS_RESTORE_PAYLOAD/manifest.json" system || return $?
    BS_RESTORE_MANIFEST="$(cat "$BS_RESTORE_PAYLOAD/manifest.json")"
    jq -e '.rear.backend=="NETFS" and .rear.program=="tar" and .rear.url_relative=="netfs" and .rear.prefix=="system" and .rear.archive=="backup" and .rear.suffix==".tar" and .rear.compression=="none" and (.rear.iso|startswith("iso/"))' <<<"$BS_RESTORE_MANIFEST" >/dev/null || {
        vps_cmd_error '未知 ReaR 路径/压缩格式；不能猜测恢复。'
        return 10
    }
    [[ -s "$BS_RESTORE_PAYLOAD/rear-state/layout/disklayout.conf" && -s "$BS_RESTORE_PAYLOAD/netfs/system/backup.tar" ]] || return 30
    [[ -f "$BS_RESTORE_PAYLOAD/$(jq -r .rear.iso <<<"$BS_RESTORE_MANIFEST")" ]] || return 30
}

bs_disk_plan() {
    local mapping old target source_size target_size identity device_id entries='[]' sources='[]' disk source mount_fs ancestry mounted boot=BIOS
    local -A seen_old=() seen_new=()
    [[ ! -d "$(vps_cmd_system_path /sys/firmware/efi)" ]] || boot=UEFI
    [[ "$(jq -r .architecture <<<"$BS_RESTORE_MANIFEST")" == "$(uname -m)" && "$(jq -r .boot <<<"$BS_RESTORE_MANIFEST")" == "$boot" ]] || {
        vps_cmd_error '目标架构/BIOS-UEFI 与源快照不一致；本路径不执行布局转换。'
        return 3
    }
    while IFS=' ' read -r disk old source_size _; do
        [[ "$disk" == disk ]] || continue
        [[ "$old" =~ ^/dev/[A-Za-z0-9_./:-]+$ && "$source_size" =~ ^[0-9]+$ ]] || return 10
        sources="$(jq -c --arg old "$old" --argjson size "$source_size" '.+[{source:$old,size:$size}]' <<<"$sources")" || return 20
    done <"$BS_RESTORE_PAYLOAD/rear-state/layout/disklayout.conf"
    [[ "$(jq length <<<"$sources")" != 0 ]] || {
        vps_cmd_error '源布局没有可恢复磁盘。'
        return 10
    }
    for mapping in "${BS_DISK_MAPS[@]}"; do
        [[ "$mapping" =~ ^(/dev/[A-Za-z0-9_./:-]+)=(/dev/[A-Za-z0-9_./:-]+)$ ]] || return 2
        old="${BASH_REMATCH[1]}" target="${BASH_REMATCH[2]}"
        [[ -z "${seen_old[$old]+x}" ]] || {
            vps_cmd_error '磁盘映射必须一一对应。'
            return 2
        }
        seen_old[$old]=1
        source_size="$(jq -r --arg old "$old" '.[]|select(.source==$old)|.size' <<<"$sources")"
        [[ -n "$source_size" && -b "$target" ]] || {
            vps_cmd_error "映射源不在布局中或目标不是块设备：$mapping"
            return 3
        }
        target="$(readlink -f "$target")" || return 20
        device_id="$(bs_device_identity "$target")" || return $?
        [[ -z "${seen_new[$device_id]+x}" ]] || {
            vps_cmd_error "目标别名重复指向同一磁盘：$target"
            return 2
        }
        seen_new[$device_id]=1
        [[ "$(lsblk -dn -o TYPE "$target")" == disk ]] || {
            vps_cmd_error "目标必须是整盘：$target"
            return 3
        }
        target_size="$(lsblk -bdn -o SIZE "$target")" || return 20
        ((target_size >= source_size)) || {
            vps_cmd_error "目标盘 $target 比原盘更小；不会自动缩容。"
            return 3
        }
        mounted="$(lsblk -n -o MOUNTPOINT "$target" | sed '/^[[:space:]]*$/d')" || return 20
        [[ -z "$mounted" ]] || {
            vps_cmd_error "目标盘 $target 有活动挂载（$mounted）；不能擦除当前系统或保存盘。"
            return 3
        }
        identity="$(lsblk -J -b -p -o NAME,TYPE,SIZE,UUID,SERIAL,WWN "$target")" || return 20
        entries="$(jq -c --arg old "$old" --arg target "$target" --argjson size "$source_size" --argjson identity "$identity" '.+[{source:$old,target:$target,source_bytes:$size,target_identity:$identity}]' <<<"$entries")" || return 20
    done
    [[ "$(jq length <<<"$entries")" == "$(jq length <<<"$sources")" ]] || {
        vps_cmd_error "必须为每个源盘指定 --disk-map：$(jq -r 'map(.source)|join(", ")' <<<"$sources")"
        return 3
    }
    source="$(findmnt -n -o SOURCE -T "$BS_RESTORE_PAYLOAD")" || return 20
    mount_fs="$(findmnt -n -o FSTYPE -T "$BS_RESTORE_PAYLOAD")" || return 20
    case "$mount_fs" in
        tmpfs | ramfs | nfs | nfs4 | cifs) ancestry='' ;;
        *)
            [[ "$source" == /dev/* ]] || {
                vps_cmd_error "无法判断恢复材料存储是否会被擦除：$source ($mount_fs)"
                return 3
            }
            ancestry="$(lsblk -s -n -p -o NAME "${source%%\[*}")" || return 20
            ;;
    esac
    while IFS= read -r target; do
        [[ $'\n'"$ancestry"$'\n' != *$'\n'"$target"$'\n'* ]] || {
            vps_cmd_error "恢复材料位于将擦除的目标盘 $target；先移到保留盘。"
            return 3
        }
    done < <(jq -r '.[].target' <<<"$entries")
    if [[ -z "$BS_NETWORK" ]]; then
        if [[ "$BS_MODE" == clone ]]; then BS_NETWORK=dhcp; else BS_NETWORK=preserve; fi
    fi
    if [[ "$BS_NETWORK" == dhcp && -z "$BS_INTERFACE" ]]; then
        vps_cmd_error 'DHCP 恢复需用 --interface 指定目标网卡（查看 ip -br link）。'
        return 2
    fi
    bs_dns_plan || return $?
    BS_RESTORE_PLAN="$(jq -nc --arg snapshot "$BS_SNAPSHOT" --arg repo "$BS_REPO" --arg mode "$BS_MODE" --arg network "$BS_NETWORK" \
        --arg interface "$BS_INTERFACE" --arg material "$BS_RESTORE_PAYLOAD" --argjson entries "$entries" --argjson dns "$BS_DNS_PLAN" \
        '{schema_version:1,snapshot:$snapshot,repo:$repo,mode:$mode,network:$network,interface:$interface,dns:$dns,material:$material,disks:$entries,destructive:true}')" || return 20
    BS_RESTORE_TOKEN="$(printf '%s' "$BS_RESTORE_PLAN" | sha256sum)"
    BS_RESTORE_TOKEN="restore-${BS_RESTORE_TOKEN%% *}"
}

bs_device_identity() {
    local path
    path="$(readlink -f "$1")" || return 20
    [[ -b "$path" ]] || return 3
    stat -c '%t:%T' "$path"
}

bs_require_rescue() {
    [[ -f "$(vps_cmd_system_path /etc/rear-release)" ]] || {
        vps_cmd_error '必须从该快照的 ReaR ISO 启动救援环境；拒绝在普通运行系统上整盘恢复。'
        return 3
    }
    bs_rear_select "$(command -v rear)" || return $?
    [[ "$(bs_rear -V)" == "$(jq -r .rear_version <<<"$BS_RESTORE_MANIFEST")" ]] || {
        vps_cmd_error '当前 ReaR 与快照版本不匹配；请启动同一快照内的 ISO。'
        return 3
    }
    # Same-version unrelated rescue media can have a different initramfs/kernel
    # and layout. Require the source layout embedded in this recovery medium.
    local embedded
    embedded="$(vps_cmd_system_path /var/lib/rear/layout/disklayout.conf)" || return $?
    cmp -s "$embedded" "$BS_RESTORE_PAYLOAD/rear-state/layout/disklayout.conf" || {
        vps_cmd_error '当前救援介质的磁盘布局与快照不匹配；使用本快照 ISO。'
        return 3
    }
}

bs_prepare_rear_restore() {
    local cfg="$1" attempt="$2" rescue source target command post_script
    mkdir -p "$cfg/mappings" || return 20
    # ReaR's rescue.conf carries the rescue mode/distribution flags. Never source
    # the backup's local.conf: its URL points at the lost source VPS.
    rescue="$(vps_cmd_system_path /etc/rear/rescue.conf)"
    if [[ ! -f "$rescue" ]]; then
        rescue="$(find /etc /var/lib/rear -name rescue.conf -type f -print -quit 2>/dev/null)"
    fi
    [[ -n "$rescue" && -f "$rescue" ]] || {
        vps_cmd_error '救援系统缺少 ReaR rescue.conf。'
        return 3
    }
    cp "$rescue" "$cfg/rescue.conf" || return 20
    : >"$cfg/mappings/disk_mappings"
    while IFS=$'\t' read -r source target; do printf '%s %s\n' "$source" "$target" >>"$cfg/mappings/disk_mappings"; done < <(jq -r '.disks[]|[.source,.target]|@tsv' <<<"$BS_RESTORE_PLAN")
    # -C is loaded after rescue.conf, making the relocation contract explicit.
    post_script="$cfg/post-recover.sh"
    cp "$BS_ROOT/commands/system/backup/recovery.sh" "$post_script" || return 20
    printf -v command 'bash %q --post %q %q %q %q %q %q' "$post_script" "$BS_RESTORE_PAYLOAD" "$BS_MODE" "$BS_NETWORK" "$BS_INTERFACE" "$attempt" "$BS_DNS_PLAN"
    {
        printf 'CONFIG_DIR=%q\n' "$cfg"
        printf 'OUTPUT=ISO\nBACKUP=NETFS\nBACKUP_PROG=tar\n'
        printf 'PRE_BACKUP_SCRIPT=\nPOST_BACKUP_SCRIPT=\n'
        printf 'BACKUP_URL=%q\nNETFS_PREFIX=system\nBACKUP_PROG_ARCHIVE=backup\nBACKUP_PROG_SUFFIX=.tar\n' "file://$BS_RESTORE_PAYLOAD/netfs"
        printf 'BACKUP_PROG_COMPRESS_OPTIONS=()\nBACKUP_PROG_COMPRESS_SUFFIX=\nBACKUP_PROG_WARN_PARTIAL_TRANSFER=\n'
        printf 'BACKUP_PROG_OPTIONS=( --anchored --numeric-owner --acls --xattrs --xattrs-include=\\* --sparse )\n'
        printf 'MIGRATION_MODE=true\nAUTORESIZE_PARTITIONS=false\nUSER_INPUT_TIMEOUT=1\nUSER_INPUT_INTERRUPT_TIMEOUT=1\nUSER_INPUT_UNATTENDED_TIMEOUT=1\n'
        printf 'POST_RECOVERY_SCRIPT=%q\n' "$command"
    } >"$cfg/relocated.conf"
    chmod 0600 "$cfg"/*.conf "$cfg/mappings/disk_mappings" || return 20
}

bs_restore() (
    local cfg attempt rc=0
    bs_need_read_tools jq findmnt lsblk tar sha256sum || return $?
    vps_cmd_require_root || return $?
    vps_cmd_require_no_symlink_components "$BS_WORK" || return $?
    bs_restore_material || return $?
    bs_disk_plan || return $?
    bs_restore_network_check || return $?
    printf '%s\n' "$BS_RESTORE_PLAN" | jq .
    printf '绑定确认：--confirm-restore %s\n' "$BS_RESTORE_TOKEN"
    [[ "$BS_ACTION" == restore && "$VPSCTL_DRY_RUN" != 1 ]] || return 0
    bs_need_read_tools rear || return $?
    bs_require_rescue || return $?
    if [[ -n "$BS_CONFIRM" ]]; then
        [[ "$BS_CONFIRM" == "$BS_RESTORE_TOKEN" ]] || {
            vps_cmd_error '确认令牌与当前快照、目标盘指纹或网络策略不匹配。'
            return 2
        }
    else vps_cmd_confirm_token '将不可逆覆盖上面全部目标磁盘，唯一恢复材料必须保留。' "$BS_RESTORE_TOKEN" || return 130; fi
    vps_cmd_lock backup-capture || return $?
    trap 'vps_cmd_unlock' EXIT
    # Full tar read verifies that the archive is readable before partitioning.
    tar -tf "$BS_RESTORE_PAYLOAD/netfs/system/backup.tar" >/dev/null || return 30
    cfg="$BS_WORK/$BS_SNAPSHOT/rear-restore"
    attempt="$(date -u +%s%N)-$$-$RANDOM"
    bs_prepare_rear_restore "$cfg" "$attempt" || return $?
    printf '%s\n' "$BS_RESTORE_PLAN" >"$cfg/restore-plan.json"
    # ReaR changes into CONFIG_DIR/mappings while consuming disk_mappings.
    bs_rear -c "$cfg" -C "$cfg/relocated.conf" recover </dev/null >"$cfg/rear-recover.log" 2>&1 || rc=$?
    if ((rc != 0)); then
        vps_cmd_error "ReaR 恢复失败（$rc）；磁盘可能已部分覆盖。保留救援系统、材料与 $cfg/rear-recover.log；不要重启。"
        return 30
    fi
    bs_post_marker_matches "$BS_WORK/$BS_SNAPSHOT/post-recovery-complete" "$attempt" || {
        vps_cmd_error 'ReaR 已返回，但恢复后状态处理没有完成；检查日志，暂不重启。'
        return 30
    }
    vps_cmd_info '磁盘、文件与引导恢复完成，已安装一次性业务状态恢复服务。请卸载 ISO 后重启并检查 SSH/业务；首次启动日志见 vpsctl-restore-state.service。'
)

bs_post_marker_matches() { [[ -f "$1" && "$(cat "$1")" == "$2" ]]; }

# This function also runs as a standalone post-recovery script inside rescue.
# It prepares the mounted target before the first boot; it never starts target
# services against rescue's /proc or networking.
bs_post_recover() {
    local payload="$1" mode="$2" network="$3" interface="$4" attempt="$5" dns="$6" root=/mnt/local file name unit
    [[ -f "$root/etc/os-release" && -f "$payload/services-before.json" ]] || return 30
    mkdir -p "$root/var/lib/vpsctl/restore" "$root/usr/local/libexec/vpsctl" "$root/etc/systemd/system/multi-user.target.wants" || return 20
    chmod 0700 "$root/var/lib/vpsctl/restore"
    cp "$payload/services-before.json" "$root/var/lib/vpsctl/restore/services-before.json" || return 20
    if [[ -f "$payload/backup-history.json" ]]; then
        mkdir -p "$root/var/lib/vpsctl/backup"
        cp "$payload/backup-history.json" "$root/var/lib/vpsctl/backup/restored-history.json" || return 20
    fi
    printf '%s\n' "$mode" >"$root/var/lib/vpsctl/restore/mode"
    # Restored jobs are historical; no old running marker may resume services.
    for file in "$root/var/lib/vpsctl/backup/jobs"/*/system-state.json; do
        [[ -f "$file" ]] || continue
        jq '.services_recovered=true | .stage="restored-history" | .pending_services=[]' "$file" >"$file.new" && mv "$file.new" "$file" || return 20
    done
    # Keep timer enablement as links, disable them for the first boot, then only
    # production resumes them after source service state has been restored.
    : >"$root/var/lib/vpsctl/restore/timers"
    while IFS= read -r file; do
        name="${file##*/}"
        if [[ "$mode" == clone || "$name" == vpsctl-backup-* ]]; then
            printf '%s\n' "$name" >>"$root/var/lib/vpsctl/restore/timers"
            rm -f -- "$file" || return 20
        fi
    done < <(find "$root/etc/systemd/system" -type l -name '*.timer')
    mkdir -p "$root/var/lib/vpsctl/restore/cron-before"
    for file in "$root/etc/cron.d"/vpsctl-backup-*; do
        [[ ! -f "$file" ]] || mv "$file" "$root/var/lib/vpsctl/restore/cron-before/" || return 20
    done
    if [[ -x "$root/usr/bin/crontab" ]]; then
        if chroot "$root" crontab -l >"$root/var/lib/vpsctl/restore/root-crontab.before" 2>/dev/null; then
            awk '!/ # vpsctl-backup-schedule:v1:/' "$root/var/lib/vpsctl/restore/root-crontab.before" >"$root/var/lib/vpsctl/restore/root-crontab.paused"
            chroot "$root" crontab /var/lib/vpsctl/restore/root-crontab.paused || return 20
        fi
    fi
    if [[ "$mode" == clone ]]; then
        : >"$root/etc/machine-id"
        mkdir -p "$root/var/lib/dbus"
        rm -f "$root/var/lib/dbus/machine-id"
        ln -s /etc/machine-id "$root/var/lib/dbus/machine-id" || return 20
        for file in "$root"/etc/ssh/ssh_host_*; do [[ ! -f "$file" ]] || rm -f -- "$file" || return 20; done
        # SSH can start before the business-state oneshot on the first boot.
        # Generate clone host keys now so its enabled service does not fail first.
        chroot "$root" ssh-keygen -A || return 20
        printf '%s\n' "vpsctl-clone-${RANDOM}" >"$root/etc/hostname"
        mkdir -p "$root/etc/cloud"
        : >"$root/etc/cloud/cloud-init.disabled"
        for unit in cron.service crond.service anacron.service atd.service; do
            ln -sf /dev/null "$root/etc/systemd/system/$unit" || return 20
        done
    fi
    if [[ "$network" == dhcp ]]; then
        [[ "$interface" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 2
        mkdir -p "$root/var/lib/vpsctl/restore/network-before" "$root/etc/systemd/network" "$root/etc/cloud/cloud.cfg.d"
        # Keep the previous configuration for diagnosis, not as a second active
        # network manager. A single networkd definition owns the target NIC.
        for file in "$root/etc/netplan" "$root/etc/network/interfaces" "$root/etc/network/interfaces.d" "$root/etc/NetworkManager/system-connections"; do
            [[ ! -e "$file" ]] || mv "$file" "$root/var/lib/vpsctl/restore/network-before/${file##*/}" || return 20
        done
        for file in "$root/etc/systemd/network"/*.network; do
            [[ ! -f "$file" ]] || mv "$file" "$root/var/lib/vpsctl/restore/network-before/" || return 20
        done
        printf '[Match]\nName=%s\n[Network]\nDHCP=yes\n' "$interface" >"$root/etc/systemd/network/10-vpsctl-recovery.network"
        printf 'network: {config: disabled}\n' >"$root/etc/cloud/cloud.cfg.d/99-vpsctl-recovery.cfg"
        systemctl --root="$root" enable systemd-networkd.service || return 20
        for unit in networking.service NetworkManager.service; do ln -sf /dev/null "$root/etc/systemd/system/$unit" || return 20; done
        if [[ "$(jq -r .mode <<<"$dns")" == dhcp-systemd-resolved ]]; then
            systemctl --root="$root" enable systemd-resolved.service || return 20
            ln -sf /run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf" || return 20
        else
            rm -f "$root/etc/resolv.conf" || return 20
            jq -r '.servers[]|"nameserver "+.' <<<"$dns" >"$root/etc/resolv.conf" || return 20
            chmod 0644 "$root/etc/resolv.conf"
        fi
    fi
    # Disable previously stopped services before boot; active ones are restored
    # by the oneshot below, including Docker unless-stopped containers.
    while IFS= read -r unit; do
        systemctl --root="$root" disable "$unit" >/dev/null 2>&1 || return 20
    done < <(jq -r '.units[]|select(.active==false)|.unit' "$payload/services-before.json")
    cp "${BASH_SOURCE[0]}" "$root/usr/local/libexec/vpsctl/restore-state.sh" || return 20
    chmod 0700 "$root/usr/local/libexec/vpsctl/restore-state.sh"
    cat >"$root/etc/systemd/system/vpsctl-restore-state.service" <<'UNIT'
[Unit]
Description=Restore pre-backup service and container state once
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/vpsctl/restore/completed
[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/libexec/vpsctl/restore-state.sh --firstboot /var/lib/vpsctl/restore
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
UNIT
    ln -sf ../vpsctl-restore-state.service "$root/etc/systemd/system/multi-user.target.wants/vpsctl-restore-state.service" || return 20
    # Persist verifiable evidence beside (not inside) the sealed payload.
    printf '%s\n' "$attempt" >"${payload%/payload}/post-recovery-complete"
}

bs_firstboot_restore() {
    local state="$1" unit id running file rc=0
    [[ ! -f "$state/completed" ]] || return 0
    : >"$state/failed-items"
    if ! ssh-keygen -A; then
        printf 'ssh-host-keys\n' >>"$state/failed-items"
        rc=30
    fi
    while IFS= read -r unit; do
        if ! systemctl start "$unit" || ! systemctl is-active --quiet "$unit"; then
            printf '%s\n' "$unit" >>"$state/failed-items"
            rc=30
        fi
    done < <(jq -r '.units|reverse[]|select(.active)|.unit' "$state/services-before.json")
    while IFS=$'\t' read -r id running; do
        if [[ "$running" == true ]]; then
            if ! docker start "$id" || [[ "$(docker inspect --format '{{.State.Running}}' "$id")" != true ]]; then
                printf 'container:%s\n' "$id" >>"$state/failed-items"
                rc=30
            fi
        elif ! timeout --foreground 120 docker stop --time -1 "$id"; then
            printf 'container:%s\n' "$id" >>"$state/failed-items"
            rc=30
        fi
    done < <(jq -r '.containers[]|[.id,(.running|tostring)]|@tsv' "$state/services-before.json")
    if ((rc == 0)) && [[ "$(cat "$state/mode")" == production ]]; then
        while IFS= read -r unit; do
            [[ -n "$unit" ]] || continue
            if ! systemctl enable --now "$unit"; then
                printf '%s\n' "$unit" >>"$state/failed-items"
                rc=30
            fi
        done <"$state/timers"
        for file in "$state/cron-before"/*; do [[ ! -f "$file" ]] || mv "$file" /etc/cron.d/ || rc=30; done
        if [[ -s "$state/root-crontab.before" ]]; then crontab "$state/root-crontab.before" || rc=30; fi
    fi
    ((rc == 0)) || {
        printf '部分原服务未恢复，见 %s/failed-items；修复后重启本 oneshot 服务重试。\n' "$state" >&2
        return 30
    }
    date -u +%FT%TZ >"$state/completed"
}

# shellcheck disable=SC2016 # Emit literal variables for the relocated tool wrapper.
bs_export_tool() {
    local tool="$1" output="$2" binary dependency loader='' relative
    binary="$(command -v "$tool")" || return 3
    mkdir -p "$output/bin" "$output/tool-bin" "$output/tool-libs" || return 20
    cp -L "$binary" "$output/tool-bin/$tool" || return 20
    while IFS= read -r dependency; do
        [[ -f "$dependency" ]] || continue
        cp -L --parents "$dependency" "$output/tool-libs" || return 20
        [[ "$dependency" != *ld-linux* && "$dependency" != *ld-musl* ]] || loader="$dependency"
    done < <(ldd "$binary" 2>/dev/null | awk '/=> \// {print $3} /^[[:space:]]*\// {print $1}' || true)
    if [[ -n "$loader" ]]; then
        relative="${loader#/}"
        {
            printf '#!/usr/bin/env bash\n'
            printf 'bundle="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"\n'
            printf 'libraries="$(find "$bundle/tool-libs" -type d -printf "%%p:")"\n'
            printf 'exec "$bundle/tool-libs/%s" --library-path "$libraries" "$bundle/tool-bin/%s" "$@"\n' "$relative" "$tool"
        } >"$output/bin/$tool"
    else
        printf '#!/usr/bin/env bash\nbundle="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"\nexec "$bundle/tool-bin/%s" "$@"\n' "$tool" >"$output/bin/$tool"
    fi
    chmod 0700 "$output/bin/$tool" "$output/tool-bin/$tool"
}

bs_export() (
    local file repo type tool
    bs_need_read_tools jq || return $?
    bs_load_plan || return $?
    backup_repo_load "$BS_REPO" || return $?
    type="$(jq -r .type <<<"$BACKUP_REPO_JSON")"
    backup_ensure_tools restic jq flock install || return $?
    [[ "$type" != webdav ]] || backup_ensure_tools rclone || return $?
    [[ ! -e "$BS_OUTPUT" ]] || {
        vps_cmd_error '工具包输出目录必须不存在。'
        return 3
    }
    vps_cmd_require_no_symlink_components "$BS_OUTPUT" || return $?
    [[ "$VPSCTL_DRY_RUN" != 1 ]] || {
        vps_cmd_info "导出匹配脚本、Restic/jq、共享库、连接模板到 $BS_OUTPUT；不含密码。"
        return 0
    }
    umask 077
    mkdir -p "$BS_OUTPUT/runtime/commands/system/backup" "$BS_OUTPUT/runtime/lib/backup" || return 20
    for file in commands/system/backup.sh commands/system/backup/tools.sh commands/system/backup/inventory.sh commands/system/backup/capture.sh commands/system/backup/recovery.sh lib/command.sh lib/ui.sh lib/backup.sh lib/backup/config.sh lib/backup/repository.sh lib/backup/jobs.sh lib/backup/schedule.sh; do
        [[ -f "$BS_ROOT/$file" ]] || return 3
        cp "$BS_ROOT/$file" "$BS_OUTPUT/runtime/$file" || return 20
    done
    repo="$(jq '.password_file=("/etc/vpsctl/backup/secrets/"+.id+".IMPORT/password") | if .type!="local" then .credentials_file=("/etc/vpsctl/backup/secrets/"+.id+".IMPORT/credentials.json") else . end' <<<"$BACKUP_REPO_JSON")"
    if [[ "$(jq -r .ca_file <<<"$repo")" != '' ]]; then
        cp "$(jq -r .ca_file <<<"$repo")" "$BS_OUTPUT/ca.crt" || return 20
        repo="$(jq '.ca_file=("/etc/vpsctl/backup/secrets/"+.id+".IMPORT/ca.pem")' <<<"$repo")"
    fi
    printf '%s\n' "$repo" >"$BS_OUTPUT/repository.json"
    for tool in restic jq flock install; do bs_export_tool "$tool" "$BS_OUTPUT" || return $?; done
    [[ "$type" != webdav ]] || bs_export_tool rclone "$BS_OUTPUT" || return $?
    backup_tool_versions >"$BS_OUTPUT/versions.json" || return 20
    cat >"$BS_OUTPUT/recover.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
bundle="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export PATH="$bundle/bin:$PATH"
if [[ "${1:-}" == import-repo ]]; then
    shift
    [[ $# == 1 || $# == 2 ]] || { printf '用法：recover.sh import-repo <密码文件> [凭据JSON文件]\n' >&2; exit 2; }
    [[ "$EUID" == 0 ]] || exit 4
    (cd "$bundle" && sha256sum -c SHA256SUMS) >&2
    source "$bundle/runtime/lib/command.sh"
    source "$bundle/runtime/lib/backup.sh"
    vps_cmd_init recovery-kit "$bundle/runtime"
    backup_init "$bundle/runtime"
    repo="$(cat "$bundle/repository.json")"; id="$(jq -r .id <<<"$repo")"
    backup_repo_validate "$id" "$repo"
    kind="$(jq -r .type <<<"$repo")"
    [[ "$kind" == local || $# == 2 ]] || exit 2
    backup_private_file "$1"
    [[ -s "$1" ]] || { vps_cmd_error '仓库密码文件为空'; exit 10; }
    [[ "$kind" == local ]] || backup_credentials_validate "$kind" "$2"
    ca="$(jq -r .ca_file <<<"$repo")"
    [[ -z "$ca" || (-f "$bundle/ca.crt" && -r "$bundle/ca.crt") ]] || exit 3
    secret_directory='' published=0
    trap 'if [[ -n "$secret_directory" && "$published" == 0 ]] && ! jq -e --arg path "$secret_directory/password" '\''.password_file == $path'\'' "$BACKUP_ETC/repos/$id.json" >/dev/null 2>&1; then rm -rf -- "$secret_directory"; fi; vps_cmd_unlock' EXIT
    vps_cmd_lock backup-repo-config
    backup_private_dir "$BACKUP_ETC" "$BACKUP_ETC/repos" "$BACKUP_ETC/secrets"
    [[ ! -e "$BACKUP_ETC/repos/$id.json" && ! -L "$BACKUP_ETC/repos/$id.json" ]] || { printf '仓库已存在，直接运行恢复动作；不会覆盖。\n' >&2; exit 3; }
    umask 077
    secret_directory="$(mktemp -d "$BACKUP_ETC/secrets/$id.XXXXXXXX")" || exit 20
    install -m 0600 -- "$1" "$secret_directory/password" || exit 20
    credentials=''
    if [[ "$kind" != local ]]; then
        credentials="$secret_directory/credentials.json"
        install -m 0600 -- "$2" "$credentials" || exit 20
    fi
    if [[ -n "$ca" ]]; then
        ca="$secret_directory/ca.pem"
        install -m 0600 -- "$bundle/ca.crt" "$ca" || exit 20
    fi
    repo="$(jq --arg password "$secret_directory/password" --arg credentials "$credentials" --arg ca "$ca" \
        '.password_file=$password | .credentials_file=$credentials | .ca_file=$ca' <<<"$repo")"
    backup_repo_validate "$id" "$repo"
    backup_atomic_json "$BACKUP_ETC/repos/$id.json" "$repo"
    published=1
    exit 0
fi
exec bash "$bundle/runtime/commands/system/backup.sh" "$@"
SCRIPT
    chmod 0700 "$BS_OUTPUT/recover.sh"
    cat >"$BS_OUTPUT/README.txt" <<EOF
整机恢复工具包（schema_version=1），仓库：$BS_REPO，架构：$(uname -m)
包内不保存密码/服务商密钥。请单独保存密码文件及凭据 JSON。
import-repo 会先校验全部输入，再为各仓库创建独立私密目录；repository.json 中 .IMPORT 路径仅为占位，导入时替换。已有同 ID 仓库拒绝覆盖。
旧版工具包的 import-repo 使用共享秘密路径；请使用新版重新导出工具包。已有配置不会自动迁移。
本包携带该版本项目脚本、Restic/jq（WebDAV 另含 rclone）和所需动态库。
依赖恢复主机 Bash 4.4+ 与 Linux 基础工具；ReaR 及引导工具由快照 ISO 提供。
1. 在同架构 Linux 中：./recover.sh import-repo /安全路径/密码文件 /安全路径/凭据.json
2. 无原 plan 也可：./recover.sh restore-plan --repo $BS_REPO --snapshot 完整快照ID --work-dir /mnt/保留盘 --disk-map /dev/原盘=/dev/目标盘 --mode clone --network dhcp --interface 目标网卡
   不在目标机器时，可直接使用 runtime/lib/backup.sh 的 backup_restore_snapshot API 取回快照，或先取回后在目标重新运行 restore-plan。
3. 启动取回材料 payload/iso 内的 ISO；把本工具包和已取回目录挂载到保留盘。
4. 在救援系统 import-repo，然后运行同参数 restore-plan，核对目标，再用 restore 加 --confirm-restore 令牌执行。
   保存材料的盘不得出现在目标映射；BIOS/UEFI、架构和 ReaR 版本必须匹配。
5. 恢复完成后移除 ISO 重启，检查 SSH、vpsctl-restore-state.service、Docker 和业务。
clone 会重新生成机器/SSH 身份、默认 DHCP，禁用 cloud-init/cron/timers；请使用隔离网络。
production 保留身份、默认保留网络，首次启动恢复原服务状态后启用原备份 timers。
服务商/密钥失效不能靠工具包修复；本包无需旧 VPS、旧计划数据库或 GitHub。
EOF
    # SHA256SUMS is deliberately excluded from its own input list.
    # shellcheck disable=SC2094
    (cd "$BS_OUTPUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS) || return 20
    vps_cmd_info "恢复工具包：$BS_OUTPUT；密码需独立异地保存。"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -Eeuo pipefail
    IFS=$'\n\t'
    case "${1:-}" in
        --post)
            [[ $# == 7 ]] || exit 2
            shift
            bs_post_recover "$@"
            ;;
        --firstboot)
            [[ $# == 2 ]] || exit 2
            shift
            bs_firstboot_restore "$@"
            ;;
        *) exit 2 ;;
    esac
fi
