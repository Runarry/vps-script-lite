#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
IFS=$'\n\t'

BS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/command.sh
source "$BS_ROOT/lib/command.sh"
# shellcheck source=../../lib/backup.sh
source "$BS_ROOT/lib/backup.sh"
# shellcheck source=backup/tools.sh
source "$BS_ROOT/commands/system/backup/tools.sh"
# shellcheck source=backup/inventory.sh
source "$BS_ROOT/commands/system/backup/inventory.sh"
# shellcheck source=backup/capture.sh
source "$BS_ROOT/commands/system/backup/capture.sh"
# shellcheck source=backup/recovery.sh
source "$BS_ROOT/commands/system/backup/recovery.sh"

bs_usage() {
    cat <<'EOF'
用法：vpsctl system backup <动作> [参数]
  inspect [--json]                            清点能力、持久挂载与漏项
  status [--json]                             查看计划和任务，不安装外部工具
  configure <计划> --repo <仓库> --work-dir <绝对路径>
      [--exclude-mount <挂载点>] [--exclude-device </dev/设备>]
      [--exclude-path <路径>] [--stop-service <unit>]
      [--private-containerd <unit>] [--keep-daily N --keep-weekly N --keep-monthly N]
  run <计划>                                 正常停服→本地全量归档→恢复服务→上传
  retry <任务>                               只重传已完成的本地材料
  recover-interrupted [计划或任务]           仅恢复所选计划/任务原先运行的服务
  snapshots <计划>                           列出完整远端恢复点
  restore-plan --repo <仓库> --snapshot <完整ID> --work-dir <保留盘目录>
  restore --repo <仓库> --snapshot <完整ID> --work-dir <保留盘目录>
      --disk-map /dev/原盘=/dev/目标盘 [可重复]
      --mode clone|production [--network preserve|dhcp --interface <网卡>]
      [--dns <解析器IP>]                       可重复；无目标 resolver 时指定静态 DNS
      [--confirm-restore <restore-plan给出的绑定令牌>]
  export-recovery <计划> --output <新目录>     导出离线工具及仓库连接模板，不含密码
  schedule <计划> enable|disable|status [--cron '分 时 日 月 周']
  uninstall                                  移除整机受管调度/运行副本，保留计划和备份

整机采集/恢复需要 root。首版按能力检查 GNU/Linux、systemd、x86_64、
Debian/Ubuntu/RHEL 家族，ext4/XFS/普通 LVM；检测通过仍不代表该组合已验收。
每次本地采集需要全量空间；所有持久挂载均记录纳入或排除。停止窗口覆盖本地归档。
run 会先清理本计划已远端完整的旧暂存；成功上传且业务恢复后按计划保留策略维护。
retry 成功后同样维护；维护失败返回 30，已完整的恢复点仍有效。失败采集材料不会自动删除。
服务按 --stop-service 顺序停止，逆序恢复；额外数据库自动发现并纳入。
Docker 需本机 rootful daemon；自动检查专用 containerd，不能停止共享使用者。
restore 必须在匹配 ISO 的 ReaR 救援系统中执行，会不可逆覆盖所有映射目标盘。
先运行 restore-plan 获取一次确认令牌；--yes 不能代替此令牌。
clone 默认 DHCP、新 machine-id/SSH 主机密钥、暂停 cron/timers/cloud-init；
production 默认保留网络和身份，恢复原服务与备份调度。网络变化可能中断 SSH。
恢复不自动重启。须在恢复系统重启后检查 SSH、服务和业务数据。
--dry-run 只读，不下载快照、不写配置、不停服；恢复演练要求已取回的材料。
通用参数：--dry-run --yes --non-interactive --install-deps --quiet --verbose --no-color
退出码：0 成功，2 参数，3 前置条件，4 权限，10 配置，20 外部失败，30 部分完成，130 中断。
EOF
}

bs_parse() {
    BS_ACTION='' BS_ID='' BS_REPO='' BS_WORK='' BS_SNAPSHOT='' BS_OUTPUT=''
    BS_JSON=0 BS_MODE=clone BS_NETWORK='' BS_INTERFACE='' BS_CONFIRM='' BS_CRON=''
    BS_SCHEDULE='' BS_DAILY=7 BS_WEEKLY=4 BS_MONTHLY=6
    BS_EXCLUDE_MOUNTS=() BS_EXCLUDE_DEVICES=() BS_EXCLUDE_PATHS=() BS_SERVICES=() BS_CONTAINERD=() BS_DISK_MAPS=() BS_DNS=()
    local positional=0 arg option
    local -a supplied=()
    while (($#)); do
        arg="$1"
        if ((positional == 0)); then
            case "$arg" in
                --)
                    positional=1
                    shift
                    continue
                    ;;
                --help | -h)
                    BS_ACTION=help
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
                    BS_JSON=1
                    supplied+=("$arg")
                    shift
                    continue
                    ;;
                --repo | --work-dir | --snapshot | --output | --mode | --network | --interface | --dns | --confirm-restore | --cron | --keep-daily | --keep-weekly | --keep-monthly | --exclude-mount | --exclude-device | --exclude-path | --stop-service | --private-containerd | --disk-map)
                    (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || return 2
                    supplied+=("$arg")
                    case "$arg" in
                        --repo) BS_REPO="$2" ;; --work-dir) BS_WORK="$2" ;; --snapshot) BS_SNAPSHOT="$2" ;;
                        --output) BS_OUTPUT="$2" ;; --mode) BS_MODE="$2" ;; --network) BS_NETWORK="$2" ;;
                        --interface) BS_INTERFACE="$2" ;; --confirm-restore) BS_CONFIRM="$2" ;; --cron) BS_CRON="$2" ;;
                        --dns) BS_DNS+=("$2") ;;
                        --keep-daily) BS_DAILY="$2" ;; --keep-weekly) BS_WEEKLY="$2" ;; --keep-monthly) BS_MONTHLY="$2" ;;
                        --exclude-mount) BS_EXCLUDE_MOUNTS+=("$2") ;; --exclude-device) BS_EXCLUDE_DEVICES+=("$2") ;;
                        --exclude-path) BS_EXCLUDE_PATHS+=("$2") ;; --stop-service) BS_SERVICES+=("$2") ;;
                        --private-containerd) BS_CONTAINERD+=("$2") ;; --disk-map) BS_DISK_MAPS+=("$2") ;;
                    esac
                    shift 2
                    continue
                    ;;
                -*) return 2 ;;
            esac
        fi
        if [[ -z "$BS_ACTION" ]]; then
            BS_ACTION="$arg"
        elif [[ -z "$BS_ID" ]]; then
            BS_ID="$arg"
        elif [[ "$BS_ACTION" == schedule && -z "$BS_SCHEDULE" ]]; then
            BS_SCHEDULE="$arg"
        else return 2; fi
        shift
    done
    case "$BS_ACTION" in '' | help | inspect | status | configure | run | retry | snapshots | restore-plan | restore | export-recovery | schedule | recover-interrupted | uninstall) ;; *) return 2 ;; esac
    [[ -z "$BS_ID" ]] || backup_valid_id "$BS_ID" || return 2
    [[ -z "$BS_REPO" ]] || backup_valid_id "$BS_REPO" || return 2
    [[ "$BS_MODE" == clone || "$BS_MODE" == production ]] || return 2
    [[ -z "$BS_NETWORK" || "$BS_NETWORK" == preserve || "$BS_NETWORK" == dhcp ]] || return 2
    [[ -z "$BS_INTERFACE" || "$BS_INTERFACE" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 2
    for arg in "${BS_DNS[@]}"; do bs_dns_address "$arg" || return 2; done
    [[ "$BS_DAILY" =~ ^[0-9]+$ && "$BS_WEEKLY" =~ ^[0-9]+$ && "$BS_MONTHLY" =~ ^[0-9]+$ ]] || return 2
    for arg in "${BS_SERVICES[@]}" "${BS_CONTAINERD[@]}"; do bs_valid_unit "$arg" || return 2; done
    for arg in "$BS_WORK" "$BS_OUTPUT" "${BS_EXCLUDE_MOUNTS[@]}" "${BS_EXCLUDE_PATHS[@]}"; do
        [[ -z "$arg" ]] || bs_safe_path "$arg" || return 2
    done
    for arg in "${BS_EXCLUDE_DEVICES[@]}"; do [[ "$arg" =~ ^/dev/[A-Za-z0-9_./:-]+$ ]] || return 2; done
    case "$BS_ACTION" in
        configure) [[ -n "$BS_ID" && -n "$BS_REPO" && -n "$BS_WORK" ]] || return 2 ;;
        run | retry | snapshots) [[ -n "$BS_ID" ]] || return 2 ;;
        export-recovery) [[ -n "$BS_ID" && -n "$BS_OUTPUT" ]] || return 2 ;;
        restore | restore-plan) [[ -z "$BS_ID" && -n "$BS_REPO" && -n "$BS_WORK" && "$BS_SNAPSHOT" =~ ^[a-f0-9]{64}$ ]] || return 2 ;;
        schedule) [[ -n "$BS_ID" && "$BS_SCHEDULE" =~ ^(enable|disable|status)$ ]] || return 2 ;;
        help | inspect | status | uninstall | '') [[ -z "$BS_ID" ]] || return 2 ;;
    esac
    for option in "${supplied[@]}"; do
        case "$BS_ACTION:$option" in
            status:--json | inspect:--json | snapshots:--json | schedule:--json | schedule:--cron) ;;
            configure:--repo | configure:--work-dir | configure:--exclude-mount | configure:--exclude-device | configure:--exclude-path | configure:--stop-service | configure:--private-containerd | configure:--keep-daily | configure:--keep-weekly | configure:--keep-monthly) ;;
            restore:--repo | restore:--snapshot | restore:--work-dir | restore:--disk-map | restore:--mode | restore:--network | restore:--interface | restore:--dns | restore:--confirm-restore) ;;
            restore-plan:--repo | restore-plan:--snapshot | restore-plan:--work-dir | restore-plan:--disk-map | restore-plan:--mode | restore-plan:--network | restore-plan:--interface | restore-plan:--dns) ;;
            export-recovery:--output) ;;
            *)
                vps_cmd_error "动作 $BS_ACTION 不接受 $option"
                return 2
                ;;
        esac
    done
}

bs_json_array() { if (($#)); then printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]'; else printf '[]'; fi; }
bs_valid_unit() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.@:-]*\.(service|socket)$ ]]; }
bs_safe_path() {
    _vps_cmd_validate_absolute_path "$1" && [[ "$1" != /root && "$1" != /home && "$1" != *[[:space:]\*\?\[]* && "$1" != *'/./'* && "$1" != */.. && "$1" != */. ]]
}
bs_need_read_tools() {
    local tool
    for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 || {
        vps_cmd_error "缺少 $tool；请先准备该工具（查看状态不会安装依赖）"
        return 3
    }; done
}

bs_configure() {
    bs_platform || return $?
    backup_ensure_tools jq findmnt lsblk tar restic file less || return $?
    bs_prepare_rear || return $?
    bs_need_read_tools jq findmnt lsblk tar || return $?
    backup_repo_load "$BS_REPO" || return $?
    bs_inventory || return $?
    bs_check_coverage || return $?
    bs_rear_capabilities || return $?
    local plan
    plan="$(jq -nc --arg id "$BS_ID" --arg repo "$BS_REPO" --arg work "$BS_WORK" \
        --argjson mounts "$(bs_json_array "${BS_EXCLUDE_MOUNTS[@]}")" --argjson devices "$(bs_json_array "${BS_EXCLUDE_DEVICES[@]}")" \
        --argjson paths "$(bs_json_array "${BS_EXCLUDE_PATHS[@]}")" --argjson services "$(bs_json_array "${BS_SERVICES[@]}")" \
        --argjson containerd "$(bs_json_array "${BS_CONTAINERD[@]}")" --argjson inventory "$BS_INVENTORY" \
        --argjson daily "$BS_DAILY" --argjson weekly "$BS_WEEKLY" --argjson monthly "$BS_MONTHLY" \
        '{schema_version:1,id:$id,type:"system",repo:$repo,work_dir:$work,retention:{daily:$daily,weekly:$weekly,monthly:$monthly},options:{exclude_mounts:$mounts,exclude_devices:$devices,exclude_paths:$paths,stop_services:$services,private_containerd:$containerd,inventory:$inventory}}')" || return 20
    if [[ "$VPSCTL_DRY_RUN" == 1 ]]; then
        printf '%s\n' "$plan"
        return 0
    fi
    vps_cmd_require_root || return $?
    backup_plan_write "$BS_ID" system "$plan" || return $?
    vps_cmd_info "计划已保存：$BS_ID；请 export-recovery 并在服务器之外保存仓库密码。"
}

bs_load_plan() {
    backup_plan_load "$BS_ID" system || return $?
    jq -e '.options | all(.exclude_mounts,.exclude_devices,.exclude_paths,.stop_services,.private_containerd; type=="array" and all(.[];type=="string"))' <<<"$BACKUP_PLAN_JSON" >/dev/null || return 10
    BS_REPO="$(jq -r .repo <<<"$BACKUP_PLAN_JSON")"
    BS_WORK="$(jq -r .work_dir <<<"$BACKUP_PLAN_JSON")"
    bs_safe_path "$BS_WORK" || return 10
    mapfile -t BS_EXCLUDE_MOUNTS < <(jq -r '.options.exclude_mounts[]?' <<<"$BACKUP_PLAN_JSON")
    mapfile -t BS_EXCLUDE_DEVICES < <(jq -r '.options.exclude_devices[]?' <<<"$BACKUP_PLAN_JSON")
    mapfile -t BS_EXCLUDE_PATHS < <(jq -r '.options.exclude_paths[]?' <<<"$BACKUP_PLAN_JSON")
    mapfile -t BS_SERVICES < <(jq -r '.options.stop_services[]?' <<<"$BACKUP_PLAN_JSON")
    mapfile -t BS_CONTAINERD < <(jq -r '.options.private_containerd[]?' <<<"$BACKUP_PLAN_JSON")
    local item
    for item in "${BS_EXCLUDE_MOUNTS[@]}" "${BS_EXCLUDE_PATHS[@]}"; do bs_safe_path "$item" || return 10; done
    for item in "${BS_SERVICES[@]}" "${BS_CONTAINERD[@]}"; do bs_valid_unit "$item" || return 10; done
}

bs_status() {
    local file data='[]' plans='[]' jobs='[]'
    if ! command -v jq >/dev/null 2>&1; then
        [[ "$BS_JSON" != 1 ]] || {
            printf '{"schema_version":1,"dependency_missing":"jq"}\n'
            return 0
        }
        printf '整机备份状态：尚未准备 jq；未安装任何外部工具。\n'
        return 0
    fi
    for file in "$BACKUP_ETC"/plans/*.json; do
        [[ -f "$file" ]] || continue
        data="$(jq -c 'select(.type=="system") | {id,repo,work_dir}' "$file")" || return 10
        [[ -z "$data" ]] || plans="$(jq -c --argjson item "$data" '.+[$item]' <<<"$plans")"
    done
    for file in "$BACKUP_STATE"/jobs/*/system-state.json; do
        [[ -f "$file" ]] || continue
        data="$(jq -c '{job_id,plan_id,stage,captured_at,services_recovered,pending_services,snapshot,error}' "$file")" || return 10
        jobs="$(jq -c --argjson item "$data" '.+[$item]' <<<"$jobs")"
    done
    if [[ -f "$BACKUP_STATE/restored-history.json" ]]; then
        data="$(jq -c '.jobs' "$BACKUP_STATE/restored-history.json")" || return 10
        jobs="$(jq -c --argjson history "$data" '.+$history|unique_by(.job_id)' <<<"$jobs")"
    fi
    data="$(jq -nc --argjson plans "$plans" --argjson jobs "$jobs" '{schema_version:1,type:"system",plans:$plans,jobs:$jobs,last_attempt:($jobs|sort_by(.job_id)|last),last_complete:($jobs|map(select(.stage=="complete"))|sort_by(.captured_at)|last),restore_validation:"未记录真实启动验收；inspect 仅判断前置能力"}')"
    if [[ "$BS_JSON" == 1 ]]; then
        printf '%s\n' "$data"
    else jq -r '"整机备份：\(.plans|length) 个计划，\(.jobs|length) 次任务",(.plans[]|"计划 \(.id) → \(.repo)，暂存 \(.work_dir)"),(.jobs[]|"任务 \(.job_id)：\(.stage)，原服务恢复=\(.services_recovered)，快照=\(.snapshot // "无")"),.restore_validation' <<<"$data"; fi
}

bs_menu() {
    local action id repo work value status=0
    while true; do
        action="$(vps_cmd_prompt_select '整机备份与恢复' status status '查看状态' inspect '清点系统与支持条件' configure '配置备份计划' run '立即整机备份' snapshots '查看完整快照' restore-plan '准备恢复材料与磁盘计划' restore '执行整机恢复' export-recovery '导出恢复工具包' schedule '管理定时任务' recover-interrupted '恢复中断任务的服务' uninstall '卸载受管调度和运行副本' quit '返回')" || return $?
        [[ "$action" != quit ]] || return 0
        case "$action" in
            inspect | status | recover-interrupted | uninstall) bs_main "$action" || status=$? ;;
            configure)
                read -r -p '计划名称：' id
                read -r -p '已配置仓库名称：' repo
                read -r -p '暂存绝对路径：' work
                bs_main configure "$id" --repo "$repo" --work-dir "$work" || status=$?
                ;;
            restore | restore-plan)
                local snapshot mapping mode network interface token dns
                read -r -p '仓库名称：' repo
                read -r -p '完整快照 ID：' snapshot
                read -r -p '恢复材料所在保留盘目录：' work
                read -r -p '磁盘映射（例如 /dev/vda=/dev/vda；多盘请使用 CLI）：' mapping
                mode="$(vps_cmd_prompt_select '恢复用途' clone clone '测试克隆' production '生产接替')" || return $?
                network="$(vps_cmd_prompt_select '目标网络' dhcp dhcp '指定网卡 DHCP' preserve '保留源网络配置')" || return $?
                interface=''
                [[ "$network" != dhcp ]] || read -r -p '目标网卡名称：' interface
                dns=''
                [[ "$network" != dhcp ]] || read -r -p '静态 DNS IP（留空沿用快照的解析器策略）：' dns
                local -a args=("$action" --repo "$repo" --snapshot "$snapshot" --work-dir "$work" --disk-map "$mapping" --mode "$mode" --network "$network")
                [[ -z "$interface" ]] || args+=(--interface "$interface")
                [[ -z "$dns" ]] || args+=(--dns "$dns")
                token=''
                bs_main "${args[@]}" || status=$?
                ;;
            *)
                read -r -p '计划名称：' id
                case "$action" in
                    export-recovery)
                        read -r -p '新工具包目录：' value
                        bs_main "$action" "$id" --output "$value" || status=$?
                        ;;
                    schedule)
                        value="$(vps_cmd_prompt_select '定时任务' status status '查看' enable '启用' disable '禁用')" || return $?
                        bs_main schedule "$id" "$value" || status=$?
                        ;;
                    *) bs_main "$action" "$id" || status=$? ;;
                esac
                ;;
        esac
        ((status == 0)) || vps_cmd_warning "操作未完成（$status），可查看状态后重试。"
        status=0
    done
}

bs_main() {
    vps_cmd_init system-backup "$BS_ROOT" || return $?
    bs_parse "$@" || {
        bs_usage >&2
        return 2
    }
    [[ "$BS_ACTION" != help ]] || {
        bs_usage
        return 0
    }
    backup_init "$BS_ROOT" || return $?
    [[ -n "$BS_ACTION" ]] || {
        if vps_cmd_is_interactive; then bs_menu; else bs_status; fi
        return $?
    }
    case "$BS_ACTION" in
        status) bs_status ;;
        inspect)
            bs_need_read_tools jq findmnt lsblk || return $?
            bs_inventory || return $?
            if [[ "$BS_JSON" == 1 ]]; then printf '%s\n' "$BS_INVENTORY"; else bs_print_inventory; fi
            ;;
        configure) bs_configure ;;
        run) bs_run ;;
        retry) bs_retry ;;
        recover-interrupted) bs_recover_interrupted ;;
        snapshots)
            bs_need_read_tools jq || return $?
            bs_load_plan || return $?
            if [[ "$BS_JSON" == 1 ]]; then
                backup_list_snapshots "$BS_REPO" system "$BS_ID"
            else backup_list_snapshots "$BS_REPO" system "$BS_ID" | jq -r '.[]|"\(.id)  \(.time)  \(.hostname)"'; fi
            ;;
        restore | restore-plan) bs_restore ;;
        export-recovery) bs_export ;;
        schedule)
            if [[ "$BS_SCHEDULE" == enable ]]; then
                bs_need_read_tools jq || return $?
                bs_load_plan || return $?
                bs_platform || return $?
                backup_ensure_tools tar restic jq findmnt lsblk file less || return $?
                bs_prepare_rear || return $?
                bs_rear_capabilities || return $?
                bs_inventory || return $?
                bs_check_coverage || return $?
                bs_discover_writers || return $?
            fi
            export BACKUP_JSON="$BS_JSON"
            backup_schedule system "$BS_ID" "$BS_SCHEDULE" "$BS_CRON"
            ;;
        uninstall)
            vps_cmd_confirm '卸载整机备份受管调度与未使用的运行副本（保留计划、凭据、材料和历史任务）？' || return 130
            backup_schedule_uninstall system
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then bs_main "$@"; fi
