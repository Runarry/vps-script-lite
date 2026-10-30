# shellcheck shell=bash
# Capture state is separate from immutable payload and survives SIGKILL/reboot.

bs_save_state() {
    local stage="$1" error="${2:-}" temporary
    temporary="$(mktemp "$BACKUP_JOB_DIR/.system-state.XXXXXX")" || return 20
    jq -nc --arg job "$BACKUP_JOB_ID" --arg plan "$BS_ID" --arg stage "$stage" --arg error "$error" \
        --arg captured "${BS_CAPTURED_AT:-}" --arg snapshot "${BS_FINAL_SNAPSHOT:-}" --argjson recovered "${BS_SERVICES_RECOVERED:-false}" \
        --argjson pending "${BS_PENDING_SERVICES:-[]}" --argjson pid "$$" \
        --arg boot "$(cat /proc/sys/kernel/random/boot_id)" \
        '{schema_version:1,job_id:$job,plan_id:$plan,stage:$stage,error:$error,captured_at:$captured,snapshot:$snapshot,services_recovered:$recovered,pending_services:$pending,pid:$pid,boot_id:$boot}' >"$temporary" || return 20
    chmod 0600 "$temporary" && mv -f "$temporary" "$BACKUP_JOB_DIR/system-state.json" || return 20
    backup_job_state "$stage" "$error"
}

bs_check_docker_owner() {
    local main pids owner
    bs_need_read_tools pgrep ps || return $?
    main="$(systemctl show -p MainPID --value docker.service)" || return 20
    pids="$(pgrep -x dockerd)" || {
        vps_cmd_error 'docker.service 活跃但无法确认其 dockerd 进程；拒绝猜测停服范围。'
        return 3
    }
    [[ "$main" =~ ^[1-9][0-9]*$ && "$pids" == "$main" ]] || {
        vps_cmd_error '发现额外或不属于 docker.service 的 dockerd（可能为 rootless/custom daemon）；当前整机路径无法协调全部写入者。'
        return 3
    }
    owner="$(ps -o uid= -p "$main" | tr -d '[:space:]')" || return 20
    [[ "$owner" == 0 ]] || {
        vps_cmd_error 'docker.service 的 daemon 非 root；需要 rootless 专门适配。'
        return 3
    }
}

bs_check_containerd_tasks() {
    local docker_ids="$1" namespaces namespace tasks task
    bs_need_read_tools ctr || return $?
    namespaces="$(ctr namespaces list --quiet)" || return 20
    while IFS= read -r namespace; do
        [[ -z "$namespace" || "$namespace" == moby ]] || {
            vps_cmd_error "containerd 存在其他命名空间 $namespace，拒绝中断共享使用者。"
            return 3
        }
    done <<<"$namespaces"
    tasks="$(ctr --namespace moby tasks list --quiet)" || {
        vps_cmd_error '不能清点 containerd 的 moby tasks，无法确认其使用者。'
        return 3
    }
    while IFS= read -r task; do
        [[ -z "$task" ]] && continue
        [[ $'\n'"$docker_ids"$'\n' == *$'\n'"$task"$'\n'* ]] || {
            vps_cmd_error "containerd moby task 不属于已清点 Docker 容器：$task；拒绝遗漏外部写入者。"
            return 3
        }
    done <<<"$tasks"
}

bs_discover_writers() {
    local unit id data active units='[]' containers='[]' info='{}' address='' root='' ids
    local -A seen=()
    local -a requested=("${BS_SERVICES[@]}")
    while IFS= read -r unit; do requested+=("$unit"); done < <(
        systemctl list-units --type=service --state=running --no-legend --plain --no-pager |
            awk '$1 ~ /^(postgresql|mysql|mariadb|redis|mongod|mongodb|rabbitmq|influxdb|cassandra|clickhouse|elasticsearch)([.@-]|$)/ {print $1}'
    )
    if systemctl is-active --quiet docker.service; then
        bs_need_read_tools docker timeout || return $?
        bs_check_docker_owner || return $?
        [[ -z "${DOCKER_HOST:-}" || "$DOCKER_HOST" == unix:///var/run/docker.sock ]] || {
            vps_cmd_error '整机路径只接受本机 rootful Docker socket；拒绝远程或用户 daemon。'
            return 3
        }
        address="$(docker context inspect --format '{{.Endpoints.docker.Host}}')" || return 20
        [[ "$address" == unix:///var/run/docker.sock ]] || {
            vps_cmd_error "Docker context 不是标准本机 daemon：$address"
            return 3
        }
        info="$(docker info --format '{{json .}}')" || return 20
        jq -e '[.SecurityOptions[]?|select(contains("rootless") or contains("userns"))]|length==0' <<<"$info" >/dev/null || {
            vps_cmd_error '检测到 Docker rootless/userns，当前整机停服适配不支持。'
            return 3
        }
        root="$(jq -r .DockerRootDir <<<"$info")"
        bs_path_covered "$root" || {
            vps_cmd_error "Docker data-root 未纳入：$root"
            return 3
        }
        ids="$(docker ps -aq --no-trunc)" || return 20
        while IFS= read -r id; do
            [[ -n "$id" ]] || continue
            data="$(docker inspect "$id")" || return 20
            while IFS= read -r root; do
                case "$root" in /var/run/docker.sock | /run/docker.sock | /proc/* | /sys/* | /dev/*) continue ;; esac
                bs_path_covered "$root" || {
                    vps_cmd_error "Docker bind 数据未纳入：$root"
                    return 3
                }
            done < <(jq -r '.[0].Mounts[]?|select(.Type=="bind")|.Source' <<<"$data")
            containers="$(jq -c --argjson data "$data" '.+[$data[0]|{id:.Id,name:.Name,running:.State.Running,restart_policy:.HostConfig.RestartPolicy}]' <<<"$containers")" || return 20
        done <<<"$ids"
        requested+=(docker.socket docker.service)
        if systemctl is-active --quiet containerd.service; then
            bs_check_containerd_tasks "$ids" || return $?
            requested+=(containerd.service)
            root=/var/lib/containerd
            if [[ -f /etc/containerd/config.toml ]]; then
                data="$(awk '/^\[/ {exit} /^root[[:space:]]*=/ {gsub(/["\047]/,"",$3); print $3}' /etc/containerd/config.toml)"
                [[ -z "$data" ]] || root="$data"
            fi
            bs_path_covered "$root" || {
                vps_cmd_error "containerd 数据未纳入：$root"
                return 3
            }
        fi
        requested+=("${BS_CONTAINERD[@]}")
    elif command -v pgrep >/dev/null 2>&1 && pgrep -x dockerd >/dev/null; then
        vps_cmd_error '存在非 docker.service 管理的 dockerd；无法保证停服与 socket 状态，需先适配该 daemon。'
        return 3
    fi
    for unit in "${requested[@]}"; do
        [[ -z "${seen[$unit]+x}" ]] || continue
        seen[$unit]=1
        bs_valid_unit "$unit" || return 10
        active="$(systemctl show -p ActiveState --value "$unit")" || return 20
        [[ "$active" == active || "$active" == inactive || "$active" == failed ]] || {
            vps_cmd_error "服务正在转换状态：$unit ($active)"
            return 3
        }
        [[ "$(systemctl show -p LoadState --value "$unit")" == loaded ]] || {
            [[ "$unit" == docker.socket ]] && continue
            vps_cmd_error "不存在服务 $unit"
            return 3
        }
        data="$(systemctl show -p SendSIGKILL --value "$unit")" || return 20
        units="$(jq -c --arg unit "$unit" --arg active "$active" --arg kill "$data" '.+[{unit:$unit,active:($active=="active"),send_sigkill:$kill}]' <<<"$units")" || return 20
    done
    BS_SERVICE_STATE="$(jq -nc --argjson units "$units" --argjson containers "$containers" --argjson info "$info" \
        '{schema_version:1,units:$units,containers:$containers,docker:{data_root:($info.DockerRootDir//null),driver:($info.Driver//null)},consistency:"显式服务与自动识别数据库停止；其他宿主机在线写入非原子"}')"
}

bs_path_covered() {
    local path="$1" original="$1" mount excluded
    [[ "$path" == /* ]] || return 3
    path="$(readlink -f -- "$path")" || return 3
    [[ -e "$path" ]] || return 3
    mount="$(findmnt -n -o TARGET -T "$path")" || return 3
    jq -e --arg mount "$mount" 'any(.mounts[]; .target==$mount and .coverage=="included")' <<<"$BS_INVENTORY" >/dev/null || return 3
    for excluded in /proc /sys /dev /run /tmp /var/log/rear "${BS_REAR_VAR:-/var/lib/rear}" "${BS_REAR_LOG_DIR:-/var/log/rear}" "$BS_WORK" "$BACKUP_STATE/jobs" "$BACKUP_STATE/cache" "$BACKUP_STATE/staging" "${BS_EXCLUDE_PATHS[@]}"; do
        [[ "$path" != "$excluded" && "$path" != "$excluded/"* && "$original" != "$excluded" && "$original" != "$excluded/"* ]] || return 3
    done
}

bs_stop_override() {
    local unit="$1" action="$2" directory file temporary
    directory="$(vps_cmd_system_path "/run/systemd/system/$unit.d")" || return $?
    file="$directory/zzzz-vpsctl-backup-$BACKUP_JOB_ID.conf"
    vps_cmd_require_no_symlink_components "$file" || return $?
    if [[ "$action" == install ]]; then
        [[ ! -e "$file" ]] || return 3
        mkdir -p "$directory" || return 20
        temporary="$(mktemp "$directory/.vpsctl-backup.XXXXXX")" || return 20
        printf '# vpsctl-backup-stop-v1\n[Service]\nSendSIGKILL=no\n' >"$temporary" || return 20
        chmod 0600 "$temporary" && mv "$temporary" "$file" || return 20
        systemctl daemon-reload || return 20
        [[ "$(systemctl show -p SendSIGKILL --value "$unit")" == no ]] || {
            vps_cmd_error "不能保证服务 $unit 正常停止时不强杀。"
            return 3
        }
    elif [[ -f "$file" ]]; then
        [[ "$(head -n 1 "$file")" == '# vpsctl-backup-stop-v1' ]] || return 10
        rm -f "$file" || return 20
        systemctl daemon-reload || return 20
    fi
}

bs_stop_writers() {
    local id unit active count result code
    # This immutable pre-stop list is committed before the first state change.
    printf '%s\n' "$BS_SERVICE_STATE" >"$BACKUP_JOB_DIR/services-before.json" || return 20
    cp "$BACKUP_JOB_DIR/services-before.json" "$BACKUP_PAYLOAD_DIR/services-before.json" || return 20
    : >"$BACKUP_JOB_DIR/services-touched"
    bs_save_state stopping || return $?
    # Prepare every service before stopping a socket that may implicitly stop a
    # dependent daemon. Each override is owned by this job and removed on exit.
    while IFS= read -r unit; do
        [[ "$unit" == *.service ]] || continue
        printf 'unit %s\n' "$unit" >>"$BACKUP_JOB_DIR/services-touched"
        bs_stop_override "$unit" install || return $?
    done < <(jq -r '.units[]|select(.active)|.unit' <<<"$BS_SERVICE_STATE")
    while IFS= read -r id; do
        printf 'container %s\n' "$id" >>"$BACKUP_JOB_DIR/services-touched"
        timeout --foreground 120 docker stop --time -1 "$id" >/dev/null || {
            vps_cmd_error "容器 $id 未正常停止；不进行强杀，不开始采集。"
            return 20
        }
        docker inspect "$id" | jq -e '.[0].State|.Running==false and .OOMKilled==false and .ExitCode!=137' >/dev/null || return 20
    done < <(jq -r '.containers[]|select(.running)|.id' <<<"$BS_SERVICE_STATE")
    while IFS= read -r unit; do
        printf 'unit %s\n' "$unit" >>"$BACKUP_JOB_DIR/services-touched"
        systemctl stop --no-block "$unit" || return 20
        count=0
        while true; do
            active="$(systemctl show -p ActiveState --value "$unit")" || return 20
            [[ "$active" != inactive && "$active" != failed ]] || break
            ((count < 120)) || {
                vps_cmd_error "服务 $unit 停止超时，未强制杀进程；开始恢复原运行状态。"
                return 20
            }
            sleep 1
            count=$((count + 1))
        done
        result="$(systemctl show -p Result --value "$unit")" || return 20
        code="$(systemctl show -p ExecMainStatus --value "$unit")" || return 20
        [[ "$active" == inactive && (-z "$result" || "$result" == success) && "$code" != 9 ]] || {
            vps_cmd_error "服务 $unit 未正常停止（$result / $code），放弃采集。"
            return 20
        }
    done < <(jq -r '.units[]|select(.active)|.unit' <<<"$BS_SERVICE_STATE")
}

bs_resume_writers() {
    local unit id running failed='[]' rc=0
    [[ -f "$BACKUP_JOB_DIR/services-before.json" ]] || return 0
    BS_SERVICE_STATE="$(cat "$BACKUP_JOB_DIR/services-before.json")" || return 20
    while IFS= read -r unit; do
        grep -Fxq "unit $unit" "$BACKUP_JOB_DIR/services-touched" || continue
        if [[ "$unit" == *.service ]]; then
            bs_stop_override "$unit" remove || rc=30
        fi
        if ! systemctl start "$unit" || ! systemctl is-active --quiet "$unit"; then
            failed="$(jq -c --arg unit "$unit" '.+[$unit]' <<<"$failed")"
            rc=30
        fi
    done < <(jq -r '.units|reverse[]|select(.active)|.unit' <<<"$BS_SERVICE_STATE")
    while IFS= read -r id; do
        grep -Fxq "container $id" "$BACKUP_JOB_DIR/services-touched" || continue
        if ! docker start "$id" >/dev/null || [[ "$(docker inspect --format '{{.State.Running}}' "$id")" != true ]]; then
            failed="$(jq -c --arg id "$id" '.+[$id]' <<<"$failed")"
            rc=30
        fi
    done < <(jq -r '.containers[]|select(.running)|.id' <<<"$BS_SERVICE_STATE")
    # Restart policies can auto-start containers during the daemon restart,
    # including containers that were stopped before this backup window.
    if grep -Fxq 'unit docker.service' "$BACKUP_JOB_DIR/services-touched"; then
        while IFS= read -r id; do
            if ! running="$(docker inspect --format '{{.State.Running}}' "$id")"; then
                failed="$(jq -c --arg id "$id" '.+[$id]' <<<"$failed")"
                rc=30
            elif [[ "$running" == true ]] && ! timeout --foreground 120 docker stop --time -1 "$id" >/dev/null; then
                failed="$(jq -c --arg id "$id" '.+[$id]' <<<"$failed")"
                rc=30
            fi
        done < <(jq -r '.containers[]|select(.running==false)|.id' <<<"$BS_SERVICE_STATE")
    fi
    BS_PENDING_SERVICES="$failed"
    if ((rc == 0)); then BS_SERVICES_RECOVERED=true; else BS_SERVICES_RECOVERED=false; fi
    return "$rc"
}

bs_create_tar_wrapper() {
    local directory="$1" native
    native="$(command -v tar)" || return 3
    mkdir -p "$directory" || return 20
    BS_REAR_TAR="$directory/tar"
    BS_REAR_TAR_STATUS="$directory/create-exit-status"
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        printf 'native=%q\n' "$native"
        printf 'record=%q\n' "$BS_REAR_TAR_STATUS"
        cat <<'TAR'
# ReaR's NETFS backend adds --ignore-failed-read unconditionally. Do not allow
# unreadable/missing source files to become a successful complete recovery point.
args=()
creating=0
for argument in "$@"; do
    [[ "$argument" == --ignore-failed-read ]] || args+=("$argument")
    [[ "$argument" != -c && "$argument" != --create ]] || creating=1
done
((creating == 0)) || printf 'running\n' >"$record"
status=0
"$native" "${args[@]}" || status=$?
((creating == 0)) || printf '%s\n' "$status" >"$record"
exit "$status"
TAR
    } >"$BS_REAR_TAR" || return 20
    chmod 0700 "$BS_REAR_TAR"
}

bs_rear_config() {
    local file="$1" item repo_file capture_command
    local -a secrets=()
    for repo_file in "$BACKUP_ETC"/repos/*.json; do
        [[ -f "$repo_file" ]] || continue
        while IFS= read -r item; do [[ -z "$item" ]] || secrets+=("$item"); done < <(jq -r '.password_file,.credentials_file // empty' "$repo_file")
    done
    {
        printf 'OUTPUT=ISO\nBACKUP=NETFS\nBACKUP_PROG=tar\n'
        if [[ -n "${BS_REAR_TAR:-}" ]]; then
            # NETFS/file builds and outputs the ISO before the backup stage.
            # Switch only there, so the wrapper cannot replace ISO /bin/tar.
            printf -v capture_command 'BACKUP_PROG=%q' "$BS_REAR_TAR"
            printf 'PRE_BACKUP_SCRIPT=%q\n' "$capture_command"
        fi
        printf 'BACKUP_URL=%q\nOUTPUT_URL=%q\n' "file://$BACKUP_PAYLOAD_DIR/netfs" "file://$BACKUP_PAYLOAD_DIR/iso"
        printf 'NETFS_PREFIX=system\nOUTPUT_PREFIX=system\nISO_PREFIX=vpsctl-rescue\n'
        printf 'BACKUP_PROG_ARCHIVE=backup\nBACKUP_PROG_SUFFIX=.tar\nBACKUP_PROG_COMPRESS_SUFFIX=\nBACKUP_PROG_COMPRESS_OPTIONS=()\n'
        printf 'BACKUP_PROG_WARN_PARTIAL_TRANSFER=\nBACKUP_TYPE=\nNETFS_KEEP_OLD_BACKUP_COPY=\n'
        printf 'BACKUP_PROG_OPTIONS=( --anchored --numeric-owner --acls --xattrs --xattrs-include=\\* --sparse )\n'
        printf 'BACKUP_ONLY_INCLUDE=yes\nAUTOEXCLUDE_PATH=()\nBACKUP_SELINUX_DISABLE=\n'
        printf 'BACKUP_PROG_INCLUDE=('
        while IFS= read -r item; do printf ' %q' "$item"; done < <(jq -r '.mounts[]|select(.coverage=="included")|.target' <<<"$BS_INVENTORY")
        printf ' )\nBACKUP_PROG_EXCLUDE+=('
        for item in /proc /sys /dev /run /tmp /var/log/rear "${BS_REAR_VAR:-/var/lib/rear}" "${BS_REAR_LOG_DIR:-/var/log/rear}" "$BS_WORK" "$BACKUP_STATE/jobs" "$BACKUP_STATE/cache" "$BACKUP_STATE/staging" "${BS_EXCLUDE_PATHS[@]}"; do printf ' %q %q' "$item" "$item/*"; done
        while IFS= read -r item; do printf ' %q %q' "$item" "$item/*"; done < <(jq -r '.mounts[]|select(.coverage|startswith("excluded"))|.target' <<<"$BS_INVENTORY")
        printf ' )\nEXCLUDE_MOUNTPOINTS+=('
        while IFS= read -r item; do printf ' %q' "$item"; done < <(jq -r '.mounts[]|select(.coverage|startswith("excluded"))|.target' <<<"$BS_INVENTORY")
        printf ' )\nEXCLUDE_COMPONENTS+=('
        for item in "${BS_EXCLUDE_DEVICES[@]}"; do printf ' %q' "$item"; done
        while IFS= read -r item; do [[ -z "$item" ]] || printf ' %q' "$item"; done <<<"${BS_STAGING_DISKS:-}"
        printf ' )\nCOPY_AS_IS_EXCLUDE+=('
        for item in "$BACKUP_ETC" "$BACKUP_STATE/jobs" "$BACKUP_STATE/cache" "$BACKUP_STATE/staging" /root/.aws /root/.config/rclone "${secrets[@]}"; do printf ' %q %q' "$item" "$item/*"; done
        # Concrete import-repo/restore-plan/restore dependencies. ReaR's own
        # mandatory list omits some coreutils, notably install.
        printf ' )\nREQUIRED_PROGS+=( bash cat chmod chroot cmp cp date dirname find findmnt flock grep install jq ln lsblk mkdir mktemp mv readlink restic rm rmdir sed sha256sum sleep stat systemctl tar tr uname )\n'
        # ReaR 2.7 on usrmerged Debian with systemd 257 misses private libraries
        # outside ldconfig's cache. Keep their actual paths and dependencies.
        for item in /usr/lib/x86_64-linux-gnu/systemd/libsystemd-*.so /usr/lib64/systemd/libsystemd-*.so; do
            [[ -f "$item" ]] || continue
            printf 'LIBS+=( %q )\nCOPY_AS_IS+=( %q )\n' "$item" "$item"
        done
        # OpenSSH 9.8/10 split sshd into libexec helpers. Preserve the configured
        # paths; PROGS would flatten them into /bin. LIBS contains their ldd
        # closure, in addition to ReaR's scan of COPY_AS_IS executables.
        for item in "${BS_SSH_HELPERS[@]:-}"; do
            [[ -n "$item" ]] || continue
            printf 'COPY_AS_IS+=( %q )\n' "$item"
        done
        for item in "${BS_SSH_HELPER_LIBS[@]:-}"; do
            [[ -n "$item" ]] || continue
            printf 'LIBS+=( %q )\n' "$item"
        done
        if command -v rclone >/dev/null 2>&1; then printf 'REQUIRED_PROGS+=( rclone )\n'; fi
        printf 'ISO_DEFAULT=manual\nISO_RECOVER_MODE=\n'
        if [[ -n "${BS_ISOLINUX_BIN:-}" ]]; then
            printf 'ISO_ISOLINUX_BIN=%q\nSYSLINUX_MODULES_DIR=%q\n' "$BS_ISOLINUX_BIN" "$BS_SYSLINUX_MODULES"
        fi
        printf 'USER_INPUT_TIMEOUT=1\nUSER_INPUT_INTERRUPT_TIMEOUT=1\nUSER_INPUT_UNATTENDED_TIMEOUT=1\n'
    } >"$file"
}

bs_verify_iso_boot_files() (
    local iso="$1" proof module
    [[ -n "${BS_ISOLINUX_BIN:-}" ]] || return 0
    proof="$(mktemp -d "$BACKUP_JOB_DIR/.iso-check.XXXXXX")" || return 20
    trap 'rm -rf -- "$proof"' EXIT
    : >"$BACKUP_JOB_DIR/iso-check.log"
    for module in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32 chain.c32; do
        if ! xorriso -osirrox on -indev "$iso" -extract "/isolinux/$module" "$proof/$module" >>"$BACKUP_JOB_DIR/iso-check.log" 2>&1 || [[ ! -s "$proof/$module" ]]; then
            vps_cmd_error "生成的 BIOS ISO 缺少 $module；不会上传为完整恢复点。见 $BACKUP_JOB_DIR/iso-check.log"
            return 20
        fi
        cmp -s "$BS_SYSLINUX_MODULES/$module" "$proof/$module" || {
            vps_cmd_error "ISO $module 与预检通过的 Syslinux 模块不一致。"
            return 20
        }
    done
)

bs_capture_material() {
    local rear_state iso files source_host network resolved=false nameservers history_file native_log
    local -a history_files=()
    mkdir -p "$BACKUP_PAYLOAD_DIR"/{netfs,iso,rear-state} "$BACKUP_JOB_DIR/rear-config" "$BS_WORK/$BACKUP_JOB_ID/rear-tmp" || return 20
    bs_create_tar_wrapper "$BS_WORK/$BACKUP_JOB_ID/rear-tools" || return $?
    bs_rear_config "$BACKUP_JOB_DIR/rear-config/local.conf" || return $?
    printf '%s\n' "$BS_INVENTORY" >"$BACKUP_PAYLOAD_DIR/coverage.json"
    for history_file in "$BACKUP_STATE"/jobs/*/system-state.json; do
        [[ ! -f "$history_file" || "$history_file" == "$BACKUP_JOB_DIR/system-state.json" ]] || history_files+=("$history_file")
    done
    if ((${#history_files[@]})); then
        jq -s '{schema_version:1,jobs:map({job_id,plan_id,stage,captured_at,services_recovered,pending_services,snapshot,error,historical:true})}' "${history_files[@]}" >"$BACKUP_PAYLOAD_DIR/backup-history.json" || return 20
    else printf '{"schema_version":1,"jobs":[]}\n' >"$BACKUP_PAYLOAD_DIR/backup-history.json"; fi
    cp "$BACKUP_JOB_DIR/rear-config/local.conf" "$BACKUP_PAYLOAD_DIR/rear-local.conf" || return 20
    bs_save_state collecting || return $?
    # ReaR owns its standard layout state; the host-wide capture lock serializes
    # both backup types. Its build directory lives on the selected work filesystem.
    native_log="$BS_REAR_LOG_DIR/rear-$(hostname).log"
    TMPDIR="$BS_WORK/$BACKUP_JOB_ID/rear-tmp" bs_rear -c "$BACKUP_JOB_DIR/rear-config" mkbackup </dev/null >"$BACKUP_JOB_DIR/rear.log" 2>&1 || {
        [[ ! -f "$native_log" ]] || cp "$native_log" "$BACKUP_JOB_DIR/rear-native.log" || true
        vps_cmd_error "ReaR 采集失败；日志：$BACKUP_JOB_DIR/rear.log，保留全部材料。"
        return 20
    }
    [[ ! -f "$native_log" ]] || cp "$native_log" "$BACKUP_JOB_DIR/rear-native.log" || return 20
    [[ -f "$BS_REAR_TAR_STATUS" && "$(cat "$BS_REAR_TAR_STATUS")" == 0 ]] || {
        vps_cmd_error 'GNU tar 没有完整成功退出（ReaR 2.7 可能容忍状态 1）；材料保留，拒绝上传为完整恢复点。'
        return 20
    }
    rear_state="$BS_REAR_VAR"
    cp -a "$rear_state/layout" "$rear_state/recovery" "$BACKUP_PAYLOAD_DIR/rear-state/" || return 20
    [[ -s "$BACKUP_PAYLOAD_DIR/rear-state/layout/disklayout.conf" && -s "$BACKUP_PAYLOAD_DIR/netfs/system/backup.tar" ]] || {
        vps_cmd_error 'ReaR 未生成契约约定的布局/归档，不能标记为完整恢复点。'
        return 20
    }
    iso="$(find "$BACKUP_PAYLOAD_DIR/iso" -type f -name '*.iso' -print -quit)"
    [[ -n "$iso" && -s "$iso" ]] || {
        vps_cmd_error '缺少匹配的 ReaR ISO。'
        return 20
    }
    bs_verify_iso_boot_files "$iso" || return $?
    tar -tf "$BACKUP_PAYLOAD_DIR/netfs/system/backup.tar" >/dev/null || return 20
    BS_CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    source_host="$(backup_source_host)"
    [[ ! -f /lib/systemd/system/systemd-resolved.service && ! -f /usr/lib/systemd/system/systemd-resolved.service ]] || resolved=true
    nameservers="$(awk '$1=="nameserver" {print $2}' /etc/resolv.conf | jq -Rsc 'split("\n")|map(select(length>0))')" || return 20
    network="$(jq -nc --argjson resolved "$resolved" --argjson nameservers "$nameservers" '{resolved_available:$resolved,nameservers:$nameservers}')" || return 20
    files="$(bs_json_array manifest.json coverage.json backup-history.json services-before.json rear-local.conf rear-state/layout/disklayout.conf netfs/system/backup.tar "${iso#"$BACKUP_PAYLOAD_DIR/"}")"
    jq -nc --arg plan "$BS_ID" --arg job "$BACKUP_JOB_ID" --arg host "$source_host" --arg captured "$BS_CAPTURED_AT" \
        --arg version "$(bs_rear -V)" --arg arch "$(uname -m)" --arg boot "$(jq -r .boot <<<"$BS_INVENTORY")" \
        --arg iso "${iso#"$BACKUP_PAYLOAD_DIR/"}" --argjson files "$files" --argjson coverage "$BS_INVENTORY" --argjson network "$network" \
        '{schema_version:1,type:"system",plan_id:$plan,job_id:$job,source_host:$host,captured_at:$captured,architecture:$arch,boot:$boot,rear_version:$version,required_files:$files,coverage:$coverage,network:$network,rear:{backend:"NETFS",program:"tar",url_relative:"netfs",prefix:"system",archive:"backup",suffix:".tar",compression:"none",iso:$iso},consistency:"stop-listed-writers; live operating-system files are not a global atomic snapshot"}' >"$BACKUP_PAYLOAD_DIR/manifest.json" || return 20
}

bs_run_cleanup() {
    local rc="$1" resume=0
    trap - EXIT INT TERM
    if [[ "${BS_CLEANUP_ARMED:-0}" == 1 ]]; then
        bs_resume_writers || resume=$?
        bs_save_state interrupted "中断/失败，原服务恢复结果=$resume；材料保留" || true
    fi
    vps_cmd_unlock
    ((resume == 0)) || rc=30
    exit "$rc"
}

bs_run() (
    local rc=0 resume=0 snapshot='' baseline
    bs_need_read_tools jq || return $?
    bs_load_plan || return $?
    bs_platform || return $?
    backup_ensure_tools tar restic jq findmnt lsblk file less || return $?
    bs_prepare_rear || return $?
    bs_rear_capabilities || return $?
    bs_inventory || return $?
    bs_check_coverage || return $?
    bs_discover_writers || return $?
    printf '%s\n' "$BS_SERVICE_STATE" | jq -r '(.units[]|select(.active)|"将正常停止服务：\(.unit)"),(.containers[]|select(.running)|"将正常停止容器：\(.name)")' >&2
    [[ "$VPSCTL_DRY_RUN" != 1 ]] || {
        backup_cleanup_completed system "$BS_ID" || return $?
        bs_space_check || return $?
        vps_cmd_info '演练完成；未写入、停服或上传。'
        return 0
    }
    vps_cmd_require_root || return $?
    vps_cmd_confirm "采集 $BS_ID：清理本计划已远端完整的旧暂存，停服覆盖本地归档，上传成功后按保留策略维护历史恢复点；是否继续？" || return 130
    vps_cmd_lock backup-capture || return $?
    trap 'bs_run_cleanup $?' EXIT
    trap 'exit 130' INT TERM
    backup_restic "$BS_REPO" snapshots --json >/dev/null || return 20
    backup_cleanup_completed system "$BS_ID" || return $?
    bs_inventory || return $?
    bs_check_coverage || return $?
    bs_space_check || return $?
    bs_discover_writers || return $?
    backup_job_create system "$BS_ID" "$BS_REPO" "$BS_WORK" || return $?
    BS_SERVICES_RECOVERED=false BS_PENDING_SERVICES='[]' BS_CAPTURED_AT='' BS_FINAL_SNAPSHOT=''
    BS_CLEANUP_ARMED=1
    baseline="$(bs_persistent_mounts)"
    bs_stop_writers || rc=$?
    if ((rc == 0)); then
        bs_inventory || rc=$?
        [[ "$baseline" == "$(bs_persistent_mounts)" ]] || {
            vps_cmd_error '停服期间挂载清单变化，放弃采集。'
            rc=3
        }
    fi
    if ((rc == 0)); then bs_capture_material || rc=$?; fi
    bs_save_state restoring-services || rc=20
    bs_resume_writers || resume=$?
    BS_CLEANUP_ARMED=0
    vps_cmd_unlock
    if ((rc != 0)); then
        bs_save_state collection-failed "采集失败=$rc，服务恢复=$resume" || true
        ((resume == 0)) || return 30
        return "$rc"
    fi
    bs_save_state collected || return $?
    if snapshot="$(backup_upload_job "$BACKUP_JOB_ID")"; then
        BS_FINAL_SNAPSHOT="$snapshot"
        bs_save_state complete || return $?
        printf '%s\n' "$snapshot"
        if ((resume == 0)) && ! backup_maintain_completed "$BACKUP_JOB_ID"; then
            bs_save_state complete '远端恢复点完整，但保留策略维护失败；已保留维护诊断' || true
            rc=30
        fi
    else
        rc=$?
        bs_save_state upload-failed "上传失败；retry $BACKUP_JOB_ID 仅重传，不重复停服" || true
    fi
    if ((resume != 0)); then
        vps_cmd_error '材料采集完成，但部分原服务未恢复；请 recover-interrupted。'
        return 30
    fi
    return "$rc"
)

bs_retry() {
    local job="$BS_ID" snapshot state
    bs_need_read_tools jq || return $?
    [[ -f "$BACKUP_STATE/jobs/$BS_ID/system-state.json" ]] || return 3
    jq -e '.stage=="collected" or .stage=="upload-failed" or .stage=="complete"' "$BACKUP_STATE/jobs/$BS_ID/system-state.json" >/dev/null || {
        vps_cmd_error '该任务没有完整采集材料，不能重传。'
        return 3
    }
    if [[ "$VPSCTL_DRY_RUN" == 1 ]]; then
        vps_cmd_info "仅重传任务 $BS_ID 的固定材料"
        return 0
    fi
    snapshot="$(backup_upload_job "$job")" || return $?
    BACKUP_JOB_ID="$job" BACKUP_JOB_DIR="$BACKUP_STATE/jobs/$job"
    state="$(cat "$BACKUP_JOB_DIR/system-state.json")"
    BS_ID="$(jq -r .plan_id <<<"$state")" BS_CAPTURED_AT="$(jq -r .captured_at <<<"$state")"
    BS_FINAL_SNAPSHOT="$snapshot" BS_SERVICES_RECOVERED="$(jq -r .services_recovered <<<"$state")" BS_PENDING_SERVICES="$(jq -c .pending_services <<<"$state")"
    bs_save_state complete || return $?
    printf '%s\n' "$snapshot"
    [[ "$BS_SERVICES_RECOVERED" == true ]] || return 30
    backup_maintain_completed "$job" || {
        bs_save_state complete '远端恢复点完整，但保留策略维护失败' || true
        return 30
    }
}

bs_recover_interrupted() (
    local file saved_id="$BS_ID" rc=0 job plan state
    bs_need_read_tools jq || return $?
    vps_cmd_require_root || return $?
    vps_cmd_lock backup-capture || return $?
    trap 'vps_cmd_unlock' EXIT
    for file in "$BACKUP_STATE"/jobs/*/system-state.json; do
        [[ -f "$file" ]] || continue
        state="$(cat "$file")"
        job="$(jq -r .job_id <<<"$state")"
        plan="$(jq -r .plan_id <<<"$state")"
        [[ -z "$saved_id" || "$saved_id" == "$plan" || "$saved_id" == "$job" ]] || continue
        [[ "$(jq -r .services_recovered <<<"$state")" != true ]] || continue
        if [[ "$VPSCTL_DRY_RUN" == 1 ]]; then
            vps_cmd_info "将恢复任务 $job 原运行状态"
            continue
        fi
        BACKUP_JOB_DIR="${file%/*}" BACKUP_JOB_ID="$job" BS_ID="$plan"
        BS_CAPTURED_AT="$(jq -r .captured_at <<<"$state")" BS_FINAL_SNAPSHOT="$(jq -r .snapshot <<<"$state")"
        bs_resume_writers || rc=30
        bs_save_state "$(jq -r .stage <<<"$state")" '中断恢复已尝试；采集和上传不会自动重做' || rc=20
    done
    return "$rc"
)
