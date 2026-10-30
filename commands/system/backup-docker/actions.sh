#!/usr/bin/env bash
# Public argument handling and the shared storage/job boundary.
# shellcheck source-path=SCRIPTDIR
# These globals are consumed by sourced shared libraries and dispatcher functions.
# shellcheck disable=SC2034

bd_usage() {
    cat <<'EOF'
用法：vpsctl system backup-docker ACTION [参数]
  inspect [PLAN]                         清点本地 daemon、容器与覆盖缺口
  status [PLAN]                          查看配置和最近任务（不安装工具）
  configure PLAN --repo REPO             保存计划，默认全部容器（含停止的）
  run PLAN                               清理旧成功材料、采集、上传并按计划维护
  snapshots REPO [--plan PLAN]            列出完整 Docker 快照
  retry JOB                              重传已有材料并按计划维护，不再次停服
  recover-interrupted PLAN                恢复该计划中断任务原先运行的写入者
  restore-plan REPO SNAPSHOT --target DIR  取回材料并显示恢复冲突与能力
  restore REPO SNAPSHOT --target DIR      重建镜像、卷、网络、容器及运行状态
  schedule PLAN enable|disable|status [--cron '表达式']
  export-recovery REPO DIRECTORY          导出独立恢复工具包（凭据另行保存）
  uninstall                              停用受管 Docker 调度，保留备份与配置

配置选项：--work-dir DIR --consistency stop|online --container NAME（可重复）
  --project NAME --label KEY[=VALUE] --host-service UNIT.service
  --helper-image IMAGE（默认 debian:bookworm-slim，运行时固定实际 ID）
  --online-config FILE（在线适配器 JSON 数组；含 kind/container/data_mounts）
  --pre-hook FILE --post-hook FILE（在线应用协调的可执行宿主机脚本，必须成对）
  --stop-timeout 秒（默认120，超时不强杀）--include-orphan-volumes
  --include-unused-images --daily N --weekly N --monthly N
  --host-writers none 可声明已协调外部写入者；实际宿主机写入仍会检查。
恢复选项：--payload DIR 使用已取回材料；--name-prefix PREFIX；
  --container NAME / --project NAME 选择容器，或 --volume NAME 仅恢复卷数据；
  --bind-map SOURCE=TARGET（可重复）；覆盖须 --overwrite
  --confirm-target ENGINE_ID --confirm-snapshot PLAN_CONFIRMATION，--yes 不替代。
  PLAN_CONFIRMATION 为计划显示的已验证完整快照 ID 或离线 sha256:内容摘要。
--dry-run 只读展示计划，不创建目录、停服务、下载、上传；恢复演练需 --payload。
每次 run 在锁内核实旧成功快照仍可用，再清理同计划的旧成功暂存材料。
失败和候选材料保留；run/retry 上传成功后自动按 daily/weekly/monthly 维护远端。
维护失败返回30，仍保留成功快照ID与已完成备份状态，可单独检查维护结果。
--json 显式输出脱敏 JSON。实际采集/恢复需要 root 和本地 rootful Docker。
仅按动作准备依赖；--install-deps 允许安装依赖或拉取辅助镜像。
支持 --yes --non-interactive --quiet --verbose --no-color；无参数打开中文菜单。
在线模式必须为活动数据提供原生 PG/MySQL/MariaDB/SQLite 或明确 hook；
不把活动数据库原文件作为一致备份。rootless/远程/Swarm/外部卷需专项适配。
EOF
}

bd_parse() {
    BD_ACTION='' BD_REPO='' BD_WORK='' BD_MODE=stop BD_HELPER=debian:bookworm-slim
    BD_ONLINE='' BD_PRE_HOOK='' BD_POST_HOOK='' BD_TARGET='' BD_PAYLOAD='' BD_PREFIX='' BD_CONFIRM_TARGET='' BD_CONFIRM_SNAPSHOT=''
    BD_CRON='' BD_FILTER_PLAN='' BD_JSON=0 BD_OVERWRITE=0 BD_ORPHANS=0 BD_UNUSED=0 BD_HOST_ACK=0
    BD_STOP_TIMEOUT=120 BD_DAILY=7 BD_WEEKLY=4 BD_MONTHLY=6
    BD_ARGS=() BD_CONTAINERS=() BD_PROJECTS=() BD_VOLUMES=() BD_LABELS=() BD_SERVICES=() BD_BINDS=()
    local positional=0 key value
    local -A scoped_options=()
    while (($#)); do
        if ((positional == 0)); then
            case "$1" in
                --help | --dry-run | --yes | --non-interactive | --install-deps | --quiet | --verbose | --no-color | --) ;;
                --*) scoped_options["$1"]=1 ;;
            esac
            case "$1" in
                --help | -h)
                    BD_ACTION=help
                    shift
                    continue
                    ;;
                --dry-run)
                    VPSCTL_DRY_RUN=1
                    shift
                    continue
                    ;;
                --yes)
                    VPSCTL_ASSUME_YES=1
                    shift
                    continue
                    ;;
                --non-interactive)
                    VPSCTL_NON_INTERACTIVE=1
                    shift
                    continue
                    ;;
                --install-deps)
                    VPSCTL_INSTALL_DEPS=1
                    shift
                    continue
                    ;;
                --quiet)
                    VPSCTL_QUIET=1
                    shift
                    continue
                    ;;
                --verbose)
                    VPSCTL_VERBOSE=1
                    shift
                    continue
                    ;;
                --no-color)
                    VPSCTL_NO_COLOR=1
                    shift
                    continue
                    ;;
                --json)
                    BD_JSON=1
                    shift
                    continue
                    ;;
                --overwrite)
                    BD_OVERWRITE=1
                    shift
                    continue
                    ;;
                --include-orphan-volumes)
                    BD_ORPHANS=1
                    shift
                    continue
                    ;;
                --include-unused-images)
                    BD_UNUSED=1
                    shift
                    continue
                    ;;
                --repo | --work-dir | --consistency | --helper-image | --online-config | --pre-hook | --post-hook | --stop-timeout | --daily | --weekly | --monthly | --target | --payload | --name-prefix | --confirm-target | --confirm-snapshot | --cron | --plan | --container | --project | --volume | --label | --host-service | --host-writers | --bind-map)
                    if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
                        vps_cmd_error "$1 缺少值"
                        return 2
                    fi
                    key="$1" value="$2"
                    case "$key" in
                        --repo) BD_REPO="$value" ;;
                        --work-dir) BD_WORK="$value" ;;
                        --consistency) BD_MODE="$value" ;;
                        --helper-image) BD_HELPER="$value" ;;
                        --online-config) BD_ONLINE="$value" ;;
                        --pre-hook) BD_PRE_HOOK="$value" ;;
                        --post-hook) BD_POST_HOOK="$value" ;;
                        --stop-timeout) BD_STOP_TIMEOUT="$value" ;;
                        --daily) BD_DAILY="$value" ;;
                        --weekly) BD_WEEKLY="$value" ;;
                        --monthly) BD_MONTHLY="$value" ;;
                        --target) BD_TARGET="$value" ;;
                        --payload) BD_PAYLOAD="$value" ;;
                        --name-prefix) BD_PREFIX="$value" ;;
                        --confirm-target) BD_CONFIRM_TARGET="$value" ;;
                        --confirm-snapshot) BD_CONFIRM_SNAPSHOT="$value" ;;
                        --cron) BD_CRON="$value" ;;
                        --plan) BD_FILTER_PLAN="$value" ;;
                        --container) BD_CONTAINERS+=("$value") ;;
                        --project) BD_PROJECTS+=("$value") ;;
                        --volume) BD_VOLUMES+=("$value") ;;
                        --label) BD_LABELS+=("$value") ;;
                        --host-service) BD_SERVICES+=("$value") ;;
                        --host-writers)
                            [[ "$value" == none ]] || return 2
                            BD_HOST_ACK=1
                            ;;
                        --bind-map) BD_BINDS+=("$value") ;;
                    esac
                    shift 2
                    continue
                    ;;
                --)
                    positional=1
                    shift
                    continue
                    ;;
                -*)
                    vps_cmd_error "未知选项: $1"
                    return 2
                    ;;
            esac
        fi
        if [[ -z "$BD_ACTION" ]]; then BD_ACTION="$1"; else BD_ARGS+=("$1"); fi
        shift
    done
    case "$BD_ACTION" in
        '' | help | inspect | status | configure | run | snapshots | retry | recover-interrupted | restore-plan | restore | schedule | export-recovery | uninstall) ;;
        *)
            vps_cmd_error "未知动作: $BD_ACTION"
            return 2
            ;;
    esac
    case "$BD_MODE" in stop | online) ;; *) return 2 ;; esac
    for value in "$BD_STOP_TIMEOUT" "$BD_DAILY" "$BD_WEEKLY" "$BD_MONTHLY"; do [[ "$value" =~ ^[0-9]{1,6}$ ]] || return 2; done
    ((BD_STOP_TIMEOUT > 0)) || return 2
    case "$BD_ACTION" in
        help | uninstall | '') ((${#BD_ARGS[@]} == 0)) || return 2 ;;
        status | inspect) ((${#BD_ARGS[@]} <= 1)) || return 2 ;;
        restore | restore-plan | export-recovery) ((${#BD_ARGS[@]} == 2)) || return 2 ;;
        schedule) ((${#BD_ARGS[@]} == 2)) || return 2 ;;
        *) ((${#BD_ARGS[@]} == 1)) || return 2 ;;
    esac
    for key in "${!scoped_options[@]}"; do
        case "$BD_ACTION:$key" in
            status:--json | inspect:--json | snapshots:--json | restore-plan:--json | restore:--json | schedule:--json | :--json) ;;
            configure:--repo | configure:--work-dir | configure:--consistency | configure:--helper-image | configure:--online-config | configure:--pre-hook | configure:--post-hook | configure:--stop-timeout | configure:--daily | configure:--weekly | configure:--monthly | configure:--container | configure:--project | configure:--label | configure:--host-service | configure:--host-writers | configure:--include-orphan-volumes | configure:--include-unused-images) ;;
            restore:--target | restore-plan:--target | restore:--payload | restore-plan:--payload | restore:--name-prefix | restore-plan:--name-prefix | restore:--bind-map | restore-plan:--bind-map | restore:--container | restore-plan:--container | restore:--project | restore-plan:--project | restore:--volume | restore-plan:--volume | restore:--overwrite | restore:--confirm-target | restore:--confirm-snapshot) ;;
            snapshots:--plan | schedule:--cron) ;;
            *)
                vps_cmd_error "$BD_ACTION 不支持选项 $key"
                return 2
                ;;
        esac
    done
}

bd_engine() { python3 "$BD_ROOT/commands/system/backup-docker/engine.py" "$@"; }

bd_require_engine() {
    command -v docker >/dev/null 2>&1 || {
        vps_cmd_error '需要已安装且可访问的本地 Docker Engine'
        return 3
    }
    backup_ensure_tools python3 jq tar || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || {
        vps_cmd_error '安装依赖后重跑以完成清点'
        return 3
    }
}

bd_result() {
    local result="$1"
    if [[ "$BD_JSON" == 1 ]]; then printf '%s\n' "$result"; else
        jq -r 'if .containers then "Docker 主机: \(.engine_id) / \(.architecture)\n容器: \(.containers | length)\n停服范围: \((.stop_scope // []) | join(", "))\n暂存估算: \(.estimated_staging_bytes) 字节\n能力缺口: \((.gaps // []) | join("；"))" elif .conflicts then "目标 Engine: \(.target_engine)\n来源: \(.source_host) / \(.snapshot_job)\n来源类型: \(.source.kind)\n内容摘要: \(.source.content_sha256)\n覆盖确认值: \(.confirmation_snapshot)\n计划启动: \(.start | join(", "))\n冲突: \(.conflicts | map(.type + ":" + .target) | join(", "))\n能力缺口: \(.gaps | join("；"))" elif .restored then "已恢复: \(.restored | join(", "))\n已启动: \(.running | join(", "))\n来源: \(.source.kind) / \(.source.job_id) / \(.source.content_sha256)" else . end' <<<"$result"
    fi
}

bd_inspect() {
    local result
    local -a args=(inspect)
    bd_require_engine || return $?
    if ((${#BD_ARGS[@]})); then
        backup_plan_load "${BD_ARGS[0]}" docker || return $?
        args+=(--plan "$BACKUP_ETC/plans/${BD_ARGS[0]}.json")
    fi
    result="$(bd_engine "${args[@]}")" || return $?
    bd_result "$result"
}

bd_status() {
    local path result='[]'
    if ! command -v jq >/dev/null 2>&1; then
        printf 'Docker 备份配置目录: %s\n任务目录: %s\n' "$BACKUP_ETC/plans" "$BACKUP_STATE/jobs"
        [[ "$BD_JSON" != 1 ]] || {
            vps_cmd_error '--json 需要 jq'
            return 3
        }
        return 0
    fi
    if ((${#BD_ARGS[@]})); then
        backup_plan_load "${BD_ARGS[0]}" docker || return $?
        result="$(jq '[{id,type,repo,work_dir,consistency:.options.consistency}]' <<<"$BACKUP_PLAN_JSON")"
    else
        for path in "$BACKUP_ETC"/plans/*.json; do
            [[ -f "$path" ]] || continue
            result="$(jq -s '.[0] + [.[1] | select(.type == "docker") | {id,type,repo,work_dir,consistency:.options.consistency}]' <(printf '%s' "$result") "$path")" || return 10
        done
    fi
    if [[ "$BD_JSON" == 1 ]]; then jq '{schema_version:1,plans:.,support:"按具体环境验收；status 不安装外部工具"}' <<<"$result"; else
        jq -r '.[] | "计划 \(.id)：仓库 \(.repo)，模式 \(.consistency)，暂存 \(.work_dir)"' <<<"$result"
        printf '任务状态目录：%s/jobs\n' "$BACKUP_STATE"
    fi
}

bd_array() { if (($#)); then printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]'; else printf '[]'; fi; }

bd_configure() {
    local id="${BD_ARGS[0]}" online='[]' plan
    if ! backup_valid_id "$id" || ! backup_valid_id "$BD_REPO"; then
        vps_cmd_error '需要有效 PLAN 和 --repo'
        return 2
    fi
    [[ -n "$BD_WORK" ]] || BD_WORK="$BACKUP_STATE/staging"
    [[ "$BD_WORK" == /* && "$BD_WORK" != / && "$BD_WORK" != *'/../'* ]] || return 2
    backup_ensure_tools jq || return $?
    backup_repo_load "$BD_REPO" || return $?
    if [[ -n "$BD_ONLINE" ]]; then
        [[ -f "$BD_ONLINE" ]] || return 2
        online="$(jq -ce 'if type == "array" then . else error("online config 必须为数组") end' "$BD_ONLINE")" || return 10
    fi
    [[ "$BD_MODE" != online || "$online" != '[]' ]] || {
        vps_cmd_error 'online 计划需要 --online-config'
        return 2
    }
    if [[ -n "$BD_PRE_HOOK" || -n "$BD_POST_HOOK" ]]; then
        [[ "$BD_MODE" == online && "$BD_PRE_HOOK" == /* && "$BD_POST_HOOK" == /* && -x "$BD_PRE_HOOK" && -x "$BD_POST_HOOK" ]] || {
            vps_cmd_error '在线 pre/post hooks 必须成对使用绝对可执行脚本路径'
            return 2
        }
    fi
    plan="$(jq -cn --arg id "$id" --arg repo "$BD_REPO" --arg work "$BD_WORK" --arg mode "$BD_MODE" --arg helper "$BD_HELPER" \
        --argjson containers "$(bd_array "${BD_CONTAINERS[@]}")" --argjson projects "$(bd_array "${BD_PROJECTS[@]}")" \
        --argjson labels "$(bd_array "${BD_LABELS[@]}")" --argjson services "$(bd_array "${BD_SERVICES[@]}")" \
        --argjson online "$online" --arg pre "$BD_PRE_HOOK" --arg post "$BD_POST_HOOK" --argjson timeout "$BD_STOP_TIMEOUT" --argjson daily "$BD_DAILY" --argjson weekly "$BD_WEEKLY" --argjson monthly "$BD_MONTHLY" \
        --argjson orphans "$BD_ORPHANS" --argjson unused "$BD_UNUSED" --argjson ack "$BD_HOST_ACK" \
        '{schema_version:1,id:$id,type:"docker",repo:$repo,work_dir:$work,retention:{daily:$daily,weekly:$weekly,monthly:$monthly},options:{consistency:$mode,containers:$containers,projects:$projects,labels:$labels,host_services:$services,host_writers_ack:($ack==1),helper_image:$helper,online:$online,pre_hook:$pre,post_hook:$post,stop_timeout:$timeout,include_orphan_volumes:($orphans==1),include_unused_images:($unused==1)}}')" || return 10
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        jq 'del(.options.online)' <<<"$plan"
        return 0
    fi
    vps_cmd_require_root || return $?
    backup_plan_write "$id" docker "$plan" || return $?
    printf '已保存 Docker 备份计划：%s\n' "$id"
}

bd_recover_locked() {
    local id="$1" job_file journal job_plan
    for job_file in "$BACKUP_STATE"/jobs/*/job.json; do
        [[ -f "$job_file" ]] || continue
        job_plan="$(jq -r '.plan_id // .plan // empty' "$job_file")" || return 10
        [[ "$job_plan" == "$id" ]] || continue
        journal="${job_file%/*}/docker-running.json"
        [[ -f "$journal" ]] || continue
        if [[ "$(jq -r '.resumed' "$journal")" != true ]]; then
            bd_engine recover --job-dir "${job_file%/*}" || return $?
        fi
    done
}

bd_stage_runtime() {
    local target="$1" list file
    local -a files=()
    list="$(_backup_schedule_files "$BD_ROOT" docker)" || return $?
    mapfile -t files <<<"$list"
    (
        umask 077
        mkdir -p -- "$target/runtime"
    ) || return 20
    for file in "${files[@]}"; do
        [[ -f "$BD_ROOT/$file" && "$file" != *..* && "$file" != /* ]] || return 10
        if [[ "$file" == */* ]]; then mkdir -p -- "$target/runtime/${file%/*}" || return 20; fi
        cp -p -- "$BD_ROOT/$file" "$target/runtime/$file" || return 20
    done
    cat >"$target/README.txt" <<'EOF'
这份快照带有匹配版本的独立 Docker 恢复脚本和共享库，不依赖旧 VPS 或 GitHub。
目标需要 Linux、rootful Docker Engine、Bash 4.4+、Python 3.9+、jq、GNU tar、flock。
先用 Restic 取回整个快照 payload（保留 .vpsctl-files.json 和全部目录）。
cd payload
bash recovery/runtime/commands/system/backup-docker.sh restore-plan offline SNAPSHOT_ID --payload "$PWD"
bash recovery/runtime/commands/system/backup-docker.sh restore offline SNAPSHOT_ID --payload "$PWD"
这里 offline 是有效占位仓库标识；已有 --payload 不需要旧仓库配置或密码。
有资源冲突时遵循恢复计划，使用显式目标/快照确认或名称、bind 路径映射。
归档中含环境变量、部署定义等敏感数据，请在私有目录保存。
EOF
}

bd_run() (
    local id="${BD_ARGS[0]}" repo work status=0
    local -a extra=()
    backup_plan_load "$id" docker || return $?
    bd_require_engine || return $?
    repo="$(jq -r .repo <<<"$BACKUP_PLAN_JSON")"
    work="$(jq -r .work_dir <<<"$BACKUP_PLAN_JSON")"
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        bd_inspect || return $?
        printf '将核实并清理同计划旧成功材料，正常停止上述写入者，采集到 %s，再恢复运行状态、上传到 %s 并按计划保留策略维护。\n' "$work" "$repo"
        return 0
    fi
    vps_cmd_require_root || return $?
    vps_cmd_confirm "执行 Docker 计划 $id 的维护窗口备份，并清理已核实的旧成功暂存材料、按计划保留策略维护远端？" || return 130
    vps_cmd_lock backup-capture || return $?
    trap 'vps_cmd_unlock' EXIT
    bd_recover_locked "$id" || return $?
    backup_restic "$repo" cat config >/dev/null || return $?
    backup_cleanup_completed docker "$id" >&2 || return $?
    backup_job_create docker "$id" "$repo" "$work" || return $?
    bd_stage_runtime "$BACKUP_PAYLOAD_DIR/recovery" || return $?
    backup_job_state capturing || return $?
    [[ "${VPSCTL_INSTALL_DEPS:-0}" != 1 ]] || extra+=(--install-deps)
    if bd_engine capture --plan "$BACKUP_ETC/plans/$id.json" --job-dir "$BACKUP_JOB_DIR" --payload "$BACKUP_PAYLOAD_DIR" --job-id "$BACKUP_JOB_ID" "${extra[@]}"; then
        backup_job_state local-complete || return $?
    else
        status=$?
        backup_job_state capture-failed "Docker capture failed ($status); inspect docker-running.json" || true
        return "$status"
    fi
    # Upload never holds the maintenance lock; original writers have already resumed.
    vps_cmd_unlock
    bd_upload_completed "$BACKUP_JOB_ID"
)

bd_upload_completed() {
    local job="$1" snapshot
    snapshot="$(backup_upload_job "$job")" || return $?
    printf '%s\n' "$snapshot"
    if ! backup_maintain_completed "$job" >&2; then
        vps_cmd_warning "备份数据已成功上传（快照 $snapshot）；计划保留策略维护未完成，请检查任务 $job 的 maintenance 记录。"
        return 30
    fi
}

bd_recover() (
    local id="${BD_ARGS[0]}"
    backup_valid_id "$id" || return 2
    bd_require_engine || return $?
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || {
        printf '将检查计划 %s 的中断状态。\n' "$id"
        return 0
    }
    vps_cmd_require_root || return $?
    vps_cmd_lock backup-capture || return $?
    trap 'vps_cmd_unlock' EXIT
    bd_recover_locked "$id"
)

bd_restore() (
    local repo="${BD_ARGS[0]}" snapshot="${BD_ARGS[1]}" item result
    local -a args=()
    bd_require_engine || return $?
    backup_valid_id "$repo" || return 2
    [[ "$snapshot" =~ ^[a-f0-9]{8,64}$ ]] || {
        vps_cmd_error '恢复需要固定 snapshot ID'
        return 2
    }
    if [[ -z "$BD_PAYLOAD" ]]; then
        [[ -n "$BD_TARGET" ]] || {
            vps_cmd_error '需要 --target 或 --payload'
            return 2
        }
        if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
            vps_cmd_error '恢复演练需 --payload 指向已取回材料，不执行下载'
            return 3
        fi
        backup_snapshot_validate "$repo" "$snapshot" docker || return $?
        snapshot="$BACKUP_SNAPSHOT_ID"
        backup_restore_snapshot "$repo" "$snapshot" "$BD_TARGET" docker || return $?
        BD_PAYLOAD="$BD_TARGET"
        bd_engine record-source --payload "$BD_PAYLOAD" --snapshot "$snapshot" || return $?
    else
        backup_payload_verify "$BD_PAYLOAD" || return $?
    fi
    args=(--payload "$BD_PAYLOAD" --snapshot "$snapshot" --name-prefix "$BD_PREFIX")
    for item in "${BD_BINDS[@]}"; do args+=(--bind-map "$item"); done
    for item in "${BD_CONTAINERS[@]}"; do args+=(--container "$item"); done
    for item in "${BD_PROJECTS[@]}"; do args+=(--project "$item"); done
    for item in "${BD_VOLUMES[@]}"; do args+=(--volume "$item"); done
    result="$(bd_engine restore-plan "${args[@]}")" || return $?
    if [[ "$BD_ACTION" != restore || "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        bd_result "$result"
        return 0
    fi
    if [[ "$(jq '.gaps | length' <<<"$result")" != 0 ]]; then
        bd_result "$result" >&2
        return 3
    fi
    vps_cmd_require_root || return $?
    if [[ "$(jq '.conflicts | length' <<<"$result")" != 0 && "$BD_CONFIRM_TARGET" == '' ]] && vps_cmd_is_interactive; then
        bd_result "$result"
        BD_CONFIRM_TARGET="$(jq -r .target_engine <<<"$result")"
        BD_CONFIRM_SNAPSHOT="$(jq -r .confirmation_snapshot <<<"$result")"
        vps_cmd_confirm_token '覆盖以上全部冲突资源；原 bind 数据将保存在同级目录。' "$BD_CONFIRM_TARGET/$BD_CONFIRM_SNAPSHOT" || return 130
        BD_OVERWRITE=1
    fi
    if [[ "$BD_OVERWRITE" == 1 ]]; then args+=(--overwrite); fi
    args+=(--confirm-target "$BD_CONFIRM_TARGET" --confirm-snapshot "$BD_CONFIRM_SNAPSHOT")
    vps_cmd_lock backup-capture || return $?
    trap 'vps_cmd_unlock' EXIT
    result="$(bd_engine restore "${args[@]}")" || return $?
    bd_result "$result"
)

bd_export() {
    local repo="${BD_ARGS[0]}" target="${BD_ARGS[1]}" file kind binary list secrets
    local -a files=()
    backup_repo_load "$repo" || return $?
    vps_cmd_require_no_symlink_components "$target" || return $?
    [[ ! -e "$target" ]] || {
        vps_cmd_error '恢复工具包必须使用尚不存在的新目录'
        return 3
    }
    kind="$(jq -r .type <<<"$BACKUP_REPO_JSON")"
    backup_ensure_tools restic sha256sum || return $?
    [[ "$kind" != webdav ]] || backup_ensure_tools rclone || return $?
    list="$(_backup_schedule_files "$BD_ROOT" docker)" || return $?
    mapfile -t files <<<"$list"
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        printf '将导出 %s 恢复脚本与当前 Restic%s 到 %s；凭据另外保管。\n' "$repo" "$([[ "$kind" == webdav ]] && printf /rclone)" "$target"
        return 0
    fi
    (
        umask 077
        mkdir -p -- "$target/tools" "$target/runtime" "$target/config"
    ) || return 20
    for file in "${files[@]}"; do
        [[ -f "$BD_ROOT/$file" && "$file" != *..* && "$file" != /* ]] || return 10
        if [[ "$file" == */* ]]; then mkdir -p -- "$target/runtime/${file%/*}" || return 20; fi
        cp -p -- "$BD_ROOT/$file" "$target/runtime/$file" || return 20
    done
    for binary in restic rclone; do
        [[ "$binary" != rclone || "$kind" == webdav ]] || continue
        cp -- "$(command -v "$binary")" "$target/tools/$binary" || return 20
        chmod 0700 -- "$target/tools/$binary" || return 20
    done
    secrets="/etc/vpsctl/backup/secrets/recovery-$repo"
    jq --arg secrets "$secrets" '.password_file=($secrets + "/password") |
        if .type == "local" then . else .credentials_file=($secrets + "/credentials.json") end |
        if (.ca_file // "") == "" then . else .ca_file=($secrets + "/ca.pem") end' <<<"$BACKUP_REPO_JSON" >"$target/config/$repo.json" || return 20
    backup_tool_versions >"$target/tool-versions.json" || return $?
    cat >"$target/recover.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
base="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export PATH="$base/tools:$PATH"
exec bash "$base/runtime/commands/system/backup-docker.sh" "$@"
SH
    chmod 0700 -- "$target/recover.sh" || return 20
    cat >"$target/README.txt" <<EOF
Docker 离线恢复入口，schema_version=1。仓库：$repo。
先在目标 Linux 准备 Docker Engine、Bash 4.4+、Python 3.9+、jq、GNU tar 和 flock。
工具包附当前 Restic（WebDAV 同时附 rclone）与匹配项目脚本；不需要旧主机或 GitHub。
运行 sha256sum -c SHA256SUMS 检查工具包，查看 tool-versions.json。
将 config/$repo.json 安装到 /etc/vpsctl/backup/repos/$repo.json（0600）。
把另行保存的仓库密码与访问凭据置于 JSON 指定路径（目录0700、文件0600）。
本仓库独立使用 $secrets/password 和 $secrets/credentials.json（本地仓库无需访问凭据）。
若配置了私有 CA，另行保存并在新主机放至 $secrets/ca.pem。不要把密码仅保存于加密仓库内。
./recover.sh snapshots $repo --json
./recover.sh restore-plan $repo SNAPSHOT_ID --target /srv/recovery --json
./recover.sh restore $repo SNAPSHOT_ID --payload /srv/recovery
存在冲突时使用计划显示的 Engine ID、固定快照 ID 进行一次范围确认：
--overwrite --confirm-target ENGINE_ID --confirm-snapshot PLAN_CONFIRMATION
PLAN_CONFIRMATION 使用 restore-plan 显示的 confirmation_snapshot；独立离线材料使用 sha256:内容摘要。
可用 --bind-map SOURCE=TARGET 和 --name-prefix PREFIX 显式映射恢复目标。
此包包含恢复工具和连接模板，不含业务快照数据、密码、访问凭据或 Docker Engine。
EOF
    # The output filename is explicitly excluded from find's input set.
    # shellcheck disable=SC2094
    (cd -- "$target" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS) || return 20
    chmod -R go-rwx -- "$target" || return 20
    printf '已导出恢复工具包：%s\n' "$target"
}

bd_snapshots() {
    local result
    result="$(backup_list_snapshots "${BD_ARGS[0]}" docker "$BD_FILTER_PLAN")" || return $?
    if [[ "$BD_JSON" == 1 ]]; then printf '%s\n' "$result"; else
        jq -r '.[] | "\(.id)  \(.time)  主机 \(.hostname)  \(.tags | join(", "))"' <<<"$result"
    fi
}

bd_retry() {
    local job="${BD_ARGS[0]}"
    backup_job_load "$job" || return $?
    [[ "$(jq -r .type <<<"$BACKUP_JOB_JSON")" == docker ]] || return 10
    if [[ -f "$BACKUP_JOB_DIR/docker-running.json" && "$(jq -r .resumed "$BACKUP_JOB_DIR/docker-running.json")" != true ]]; then
        vps_cmd_error '原运行状态尚未恢复；请先 recover-interrupted PLAN'
        return 30
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        printf '将重试上传任务 %s，成功后按计划保留策略维护远端。\n' "$job"
        return 0
    fi
    bd_upload_completed "$job"
}

bd_schedule() {
    local id="${BD_ARGS[0]}" action="${BD_ARGS[1]}" result plan
    local -a options=()
    case "$action" in enable | disable | status) ;; *) return 2 ;; esac
    if [[ "$action" == enable ]]; then
        backup_plan_load "$id" docker || return $?
        bd_require_engine || return $?
        if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
            vps_cmd_require_root || return $?
            [[ "${VPSCTL_INSTALL_DEPS:-0}" != 1 ]] || options+=(--install-deps)
            result="$(bd_engine prepare --plan "$BACKUP_ETC/plans/$id.json" "${options[@]}")" || return $?
            plan="$(jq --arg image "$(jq -r .helper_image_id <<<"$result")" '.options.helper_image=$image' <<<"$BACKUP_PLAN_JSON")" || return 10
            backup_plan_write "$id" docker "$plan" || return $?
        else
            result="$(bd_engine inspect --plan "$BACKUP_ETC/plans/$id.json")" || return $?
            bd_result "$result"
            printf '启用前将验证并固定 GNU tar 辅助镜像；定时执行不拉取镜像。\n'
        fi
    fi
    BACKUP_JSON="$BD_JSON"
    backup_schedule docker "$id" "$action" "$BD_CRON"
}

bd_menu_id() {
    local value
    printf '%s：' "$1" >&2
    IFS= read -r value || return 130
    backup_valid_id "$value" || {
        vps_cmd_error '标识无效'
        return 2
    }
    printf '%s' "$value"
}

bd_menu() {
    local choice value status repo mode path scope snapshot sub cron
    local -a arguments=()
    while true; do
        choice="$(vps_cmd_prompt_select 'Docker 备份与恢复' status status '查看计划' inspect '清点 Docker' configure '配置备份计划' run '执行备份计划' snapshots '查看仓库快照' retry '重传已有采集材料' recover-interrupted '恢复中断停服' restore-plan '准备恢复与检查冲突' restore '执行恢复' schedule '管理定时备份' export-recovery '导出恢复工具包' uninstall '停用 Docker 备份调度' help '查看命令帮助' quit '返回')" || {
            status=$?
            [[ "$status" != 130 ]] || return 0
            return "$status"
        }
        arguments=("$choice")
        case "$choice" in
            quit) return 0 ;;
            status | inspect | help | uninstall) ;;
            configure)
                value="$(bd_menu_id '新计划标识')" || continue
                repo="$(bd_menu_id '已配置的仓库标识')" || continue
                mode="$(vps_cmd_prompt_select '数据一致性方式' stop stop '维护窗口正常停服' online '数据库原生导出与应用 hook')" || continue
                arguments+=("$value" --repo "$repo" --consistency "$mode")
                printf '暂存绝对目录（留空使用默认值）：' >&2
                IFS= read -r path || return 130
                [[ -z "$path" ]] || arguments+=(--work-dir "$path")
                scope="$(vps_cmd_prompt_select '备份范围' all all '本 daemon 全部容器（含停止的）' container '指定容器' project '指定 Compose 项目')" || continue
                if [[ "$scope" != all ]]; then
                    printf '容器/项目名称：' >&2
                    IFS= read -r value || return 130
                    [[ -n "$value" ]] || continue
                    arguments+=("--$scope" "$value")
                fi
                if [[ "$mode" == online ]]; then
                    printf '在线适配器 JSON 文件绝对路径：' >&2
                    IFS= read -r path || return 130
                    arguments+=(--online-config "$path")
                fi
                ;;
            restore | restore-plan)
                repo="$(bd_menu_id '仓库标识')" || continue
                printf '完整快照 ID：' >&2
                IFS= read -r snapshot || return 130
                [[ "$snapshot" =~ ^[a-f0-9]{8,64}$ ]] || {
                    vps_cmd_error '快照 ID 无效'
                    continue
                }
                printf '新的材料下载绝对目录：' >&2
                IFS= read -r path || return 130
                arguments+=("$repo" "$snapshot" --target "$path")
                ;;
            schedule)
                value="$(bd_menu_id '计划标识')" || continue
                sub="$(vps_cmd_prompt_select '定时备份' status status '查看状态' enable '启用' disable '停用')" || continue
                arguments+=("$value" "$sub")
                if [[ "$sub" == enable ]]; then
                    printf '五段 cron 表达式（例如 0 3 * * *）：' >&2
                    IFS= read -r cron || return 130
                    arguments+=(--cron "$cron")
                fi
                ;;
            export-recovery)
                repo="$(bd_menu_id '仓库标识')" || continue
                printf '新恢复工具包绝对目录：' >&2
                IFS= read -r path || return 130
                arguments+=("$repo" "$path")
                ;;
            snapshots)
                value="$(bd_menu_id '仓库标识')" || continue
                arguments+=("$value")
                ;;
            retry)
                value="$(bd_menu_id '任务标识')" || continue
                arguments+=("$value")
                ;;
            *)
                value="$(bd_menu_id '计划标识')" || continue
                arguments+=("$value")
                ;;
        esac
        status=0
        bd_main "${arguments[@]}" || status=$?
        if ((status)); then
            vps_cmd_warning "本次操作未完成（退出码 $status），可查看状态后继续。"
        fi
    done
}

bd_main() {
    vps_cmd_init system-backup-docker "$BD_ROOT" || return $?
    bd_parse "$@" || {
        bd_usage >&2
        return 2
    }
    [[ "$BD_ACTION" != help ]] || {
        bd_usage
        return 0
    }
    if [[ "${VPSCTL_TESTING:-0}" != 1 && "$(uname -s)" != Linux ]]; then
        vps_cmd_error 'Docker 备份仅支持 Linux'
        return 3
    fi
    backup_init "$BD_ROOT" || return $?
    case "$BD_ACTION" in
        '') if vps_cmd_is_interactive; then bd_menu; else bd_status; fi ;;
        inspect) bd_inspect ;;
        status) bd_status ;;
        configure) bd_configure ;;
        run) bd_run ;;
        recover-interrupted) bd_recover ;;
        restore | restore-plan) bd_restore ;;
        retry) bd_retry ;;
        snapshots) bd_snapshots ;;
        schedule) bd_schedule ;;
        export-recovery) bd_export ;;
        uninstall) backup_schedule_uninstall docker ;;
    esac
}
