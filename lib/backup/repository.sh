# shellcheck shell=bash
# shellcheck disable=SC2016 # jq expressions contain jq variables, not shell expansions.

backup_credentials_validate() {
    local kind="$1" file="$2"
    backup_private_file "$file" || return $?
    jq -e --arg kind "$kind" '
      def text: type == "string" and length > 0 and (test("[\u0000-\u001f]")|not);
      type == "object" and
      (if $kind == "s3" then (.access_key_id|text) and (.secret_access_key|text) and ((.session_token // "")|type == "string")
       else ((.user|text) and (.password|text)) or (.bearer_token|text) end) and
      ([..|strings|test("[\u0000-\u001f]")]|any|not)' "$file" >/dev/null || {
        vps_cmd_error '凭据 JSON 字段无效（只读取数据，不执行文件）'
        return 10
    }
}

# All credentials and backend options live only in this subshell. Restic receives
# secret file references and environment variables, never password command lines.
backup_restic() (
    local repo="$1" kind password credentials variable ca endpoint bucket prefix status=0
    local -a arguments=(--no-cache)
    shift
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || arguments+=(--no-lock)
    backup_repo_load "$repo" || return $?
    kind="$(jq -r .type <<<"$BACKUP_REPO_JSON")" || return 10
    backup_ensure_tools restic || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 3
    [[ "$kind" != webdav ]] || backup_ensure_tools rclone || return $?
    for variable in ${!RESTIC_@} ${!AWS_@} ${!RCLONE_@}; do unset "$variable"; done
    password="$(jq -r .password_file <<<"$BACKUP_REPO_JSON")" || return 10
    backup_private_file "$password" || return $?
    [[ -s "$password" ]] || {
        vps_cmd_error '仓库密码文件为空'
        return 10
    }
    export RESTIC_PASSWORD_FILE="$password"
    export RESTIC_PACK_SIZE
    RESTIC_PACK_SIZE="$(jq -r .pack_size <<<"$BACKUP_REPO_JSON")" || return 10
    ca="$(jq -r .ca_file <<<"$BACKUP_REPO_JSON")" || return 10
    if [[ -n "$ca" ]]; then
        [[ -f "$ca" && -r "$ca" ]] || return 3
        arguments+=(--cacert "$ca")
    fi
    if [[ "$kind" != local ]]; then
        credentials="$(jq -r .credentials_file <<<"$BACKUP_REPO_JSON")" || return 10
        backup_credentials_validate "$kind" "$credentials" || return $?
        prefix="$(jq -r .prefix <<<"$BACKUP_REPO_JSON")" || return 10
    fi
    case "$kind" in
        local) RESTIC_REPOSITORY="$(jq -r .path <<<"$BACKUP_REPO_JSON")" || return 10 ;;
        s3)
            endpoint="$(jq -r .endpoint <<<"$BACKUP_REPO_JSON")" bucket="$(jq -r .bucket <<<"$BACKUP_REPO_JSON")" || return 10
            RESTIC_REPOSITORY="s3:${endpoint%/}/$bucket/${prefix%/}"
            export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION
            AWS_ACCESS_KEY_ID="$(jq -r .access_key_id "$credentials")" || return 10
            AWS_SECRET_ACCESS_KEY="$(jq -r .secret_access_key "$credentials")" || return 10
            AWS_SESSION_TOKEN="$(jq -r '.session_token // ""' "$credentials")" || return 10
            AWS_DEFAULT_REGION="$(jq -r .region <<<"$BACKUP_REPO_JSON")" || return 10
            arguments+=(-o "s3.bucket-lookup=$(jq -r .bucket_lookup <<<"$BACKUP_REPO_JSON")" -o "s3.connections=$(jq -r .connections <<<"$BACKUP_REPO_JSON")")
            ;;
        webdav)
            RESTIC_REPOSITORY="rclone:vpsctl:${prefix%/}"
            export RCLONE_CONFIG=/dev/null RCLONE_CONFIG_VPSCTL_TYPE=webdav
            export RCLONE_CONFIG_VPSCTL_URL RCLONE_CONFIG_VPSCTL_VENDOR RCLONE_CONFIG_VPSCTL_USER RCLONE_CONFIG_VPSCTL_PASS RCLONE_CONFIG_VPSCTL_BEARER_TOKEN
            RCLONE_CONFIG_VPSCTL_URL="$(jq -r .url <<<"$BACKUP_REPO_JSON")" || return 10
            RCLONE_CONFIG_VPSCTL_VENDOR="$(jq -r .vendor <<<"$BACKUP_REPO_JSON")" || return 10
            RCLONE_CONFIG_VPSCTL_USER="$(jq -r '.user // ""' "$credentials")" || return 10
            RCLONE_CONFIG_VPSCTL_PASS="$(jq -jr '.password // ""' "$credentials" | rclone obscure -)" || return 20
            RCLONE_CONFIG_VPSCTL_BEARER_TOKEN="$(jq -r '.bearer_token // ""' "$credentials")" || return 10
            export RCLONE_TIMEOUT RCLONE_RETRIES=3 RCLONE_LOW_LEVEL_RETRIES=3
            RCLONE_TIMEOUT="$(jq -r .timeout <<<"$BACKUP_REPO_JSON")s" || return 10
            [[ -z "$ca" ]] || export RCLONE_CA_CERT="$ca"
            arguments+=(-o "rclone.connections=$(jq -r .connections <<<"$BACKUP_REPO_JSON")")
            ;;
    esac
    RESTIC_REPOSITORY="${RESTIC_REPOSITORY%/}${BACKUP_REPOSITORY_SUFFIX:-}"
    export RESTIC_REPOSITORY
    restic "${arguments[@]}" "$@" || status=$?
    return "$status"
)

# Retry only evidence of a transient network/server failure. Authentication,
# quota, permission, incomplete-source (3), and lock errors are not retried.
backup_restic_retry() (
    local repo="$1" attempt status log
    shift
    log="$(mktemp)" || return 20
    chmod 0600 "$log" || return 20
    trap 'rm -f -- "$log"' EXIT
    for attempt in 1 2 3; do
        status=0
        backup_restic "$repo" "$@" 2>"$log" || status=$?
        cat -- "$log" >&2
        ((status != 0)) || return 0
        if ((status == 3 || attempt == 3)) ||
            grep -Eqi 'access.?denied|forbidden|unauthorized|authentication|wrong password|quota|no space|repository.*locked|insufficient' "$log" ||
            ! grep -Eqi 'timeout|timed out|connection reset|connection refused|temporary|temporarily|429|503|502|504|unexpected EOF|network is unreachable' "$log"; then
            return "$status"
        fi
        sleep "$((attempt * 2))"
    done
)

backup_repo_probe() (
    local repo="$1" probe snapshot readback result status=0
    local BACKUP_REPOSITORY_SUFFIX='.vpsctl-probe'
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || {
        vps_cmd_info "演练：仓库 $repo 独立探测前缀内写入、列举、读回并删除测试材料"
        return 0
    }
    probe="vpsctl-probe-$(date -u +%s)-${RANDOM}${RANDOM}"
    if ! backup_restic "$repo" cat config >/dev/null 2>&1; then
        backup_restic_retry "$repo" init --repository-version 2 >&2 || return 20
    fi
    result="$(printf '%s' "$probe" | backup_restic_retry "$repo" backup --stdin --stdin-filename probe.txt --tag "$probe" --json)" || return 20
    snapshot="$(jq -r 'select(.message_type == "summary") | .snapshot_id // empty' <<<"$result")" || return 20
    [[ "$snapshot" =~ ^[0-9a-f]{8,64}$ ]] || return 20
    backup_restic "$repo" snapshots --json "$snapshot" | jq -e --arg tag "$probe" 'length == 1 and (.[0].tags|index($tag) != null)' >/dev/null || status=20
    readback="$(backup_restic "$repo" dump "$snapshot" /probe.txt)" || status=20
    [[ "$readback" == "$probe" ]] || status=20
    backup_restic "$repo" forget "$snapshot" --prune >&2 || status=30
    ((status == 0)) || {
        vps_cmd_error "写入探测未完成；检查仓库 $repo 的 .vpsctl-probe 前缀"
        return "$status"
    }
    vps_cmd_info '写入、列举、内容读回和测试快照删除通过；独立探测仓库骨架保留供后续检测（尚未验证大 pack 限制）'
)

backup_repo_check() {
    local repo="$1" scope='structure' json
    shift
    if (($#)); then scope="$*"; fi
    backup_restic_retry "$repo" check "$@" || return 20
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    backup_private_dir "$BACKUP_STATE" "$BACKUP_STATE/checks" || return $?
    json="$(jq -n --arg scope "$scope" --arg time "$(date -u +%FT%TZ)" '{schema_version:1,checked_at:$time,scope:$scope,result:"passed"}')" || return 20
    backup_atomic_json "$BACKUP_STATE/checks/$repo.json" "$json"
}

backup_list_snapshots() {
    local repo="$1" kind="$2" plan="${3:-}" tag="vpsctl,complete,type:$2" result
    [[ "$kind" == system || "$kind" == docker ]] || return 2
    if [[ -n "$plan" ]]; then
        backup_valid_id "$plan" || return 2
        tag+=",plan:$plan"
    fi
    result="$(backup_restic_retry "$repo" snapshots --json --tag "$tag")" || return 20
    jq 'sort_by(.time) | reverse' <<<"$result"
}

backup_repo_prune() (
    local repo="$1" plan="$2" kind json host daily weekly monthly lock_file lock_fd
    backup_valid_id "$plan" || return 2
    backup_private_file "$BACKUP_ETC/plans/$plan.json" || return $?
    kind="$(jq -r .type "$BACKUP_ETC/plans/$plan.json")" || return 10
    backup_plan_load "$plan" "$kind" || return $?
    [[ "$(jq -r .repo <<<"$BACKUP_PLAN_JSON")" == "$repo" ]] || return 10
    daily="$(jq -r .retention.daily <<<"$BACKUP_PLAN_JSON")" weekly="$(jq -r .retention.weekly <<<"$BACKUP_PLAN_JSON")" monthly="$(jq -r .retention.monthly <<<"$BACKUP_PLAN_JSON")" || return 10
    host="$(backup_source_host)" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        backup_private_dir "$BACKUP_STATE" "$BACKUP_STATE/locks" || return $?
        lock_file="$BACKUP_STATE/locks/repo-$repo.lock"
        vps_cmd_require_no_symlink_components "$lock_file" || return $?
        exec {lock_fd}>"$lock_file" || return 20
        flock -n -x "$lock_fd" || {
            vps_cmd_error '仓库正在本机恢复或维护，拒绝清理'
            return 3
        }
    fi
    local -a args=(forget --json --prune --group-by host --host "$host" --tag "vpsctl,complete,type:$kind,plan:$plan" --keep-last 1 --keep-daily "$daily" --keep-weekly "$weekly" --keep-monthly "$monthly")
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || args+=(--dry-run)
    json="$(backup_restic "$repo" "${args[@]}")" || return 20
    printf '%s\n' "$json"
)
