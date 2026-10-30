# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034 # jq programs and public API result variables.

backup_manifest_validate() {
    local file="$1" kind="${2:-}"
    [[ -f "$file" && ! -L "$file" ]] || return 30
    jq -e --arg kind "$kind" '
      def text: type == "string" and length > 0 and (test("[\u0000-\u001f]")|not);
      def id: text and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$");
      .schema_version == 1 and (.type == "docker" or .type == "system") and ($kind == "" or .type == $kind) and
      (.plan_id|id) and (.job_id|id) and (.source_host|text) and (.captured_at|text) and
      ((.required_files // [])|type == "array" and all(.[]; text and (startswith("/")|not) and (split("/")|all(.[]; . != ".." and . != "." and . != ""))))' "$file" >/dev/null || {
        vps_cmd_error '恢复清单字段无效或版本不兼容（支持 schema_version=1）'
        return 10
    }
}

backup_job_create() {
    local kind="$1" plan="$2" repo="$3" work="$4" json
    [[ "$kind" == docker || "$kind" == system ]] && backup_valid_id "$plan" && backup_valid_id "$repo" || return 2
    vps_cmd_require_no_symlink_components "$work" || return $?
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || {
        vps_cmd_error '演练不能创建备份任务'
        return 3
    }
    backup_ensure_tools jq flock || return $?
    backup_private_dir "$BACKUP_STATE" "$BACKUP_STATE/jobs" "$work" || return $?
    BACKUP_JOB_ID="$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}${RANDOM}"
    BACKUP_JOB_DIR="$BACKUP_STATE/jobs/$BACKUP_JOB_ID"
    BACKUP_PAYLOAD_DIR="$work/$BACKUP_JOB_ID/payload"
    mkdir -m 0700 -- "$BACKUP_JOB_DIR" || return 20
    backup_private_dir "$work/$BACKUP_JOB_ID" "$BACKUP_PAYLOAD_DIR" || return $?
    json="$(jq -n --arg id "$BACKUP_JOB_ID" --arg kind "$kind" --arg plan "$plan" --arg repo "$repo" --arg work "$work" --arg payload "$BACKUP_PAYLOAD_DIR" --arg host "$(backup_source_host)" --arg time "$(date -u +%FT%TZ)" \
        '{schema_version:1,id:$id,job_id:$id,type:$kind,plan_id:$plan,repo:$repo,work_dir:$work,payload_dir:$payload,source_host:$host,captured_at:$time,updated_at:$time,state:"created",stage:"created",snapshot_id:null,error:null}')" || return 20
    backup_atomic_json "$BACKUP_JOB_DIR/job.json" "$json"
}

backup_job_load() {
    backup_valid_id "$1" || return 2
    BACKUP_JOB_ID="$1" BACKUP_JOB_DIR="$BACKUP_STATE/jobs/$1"
    backup_private_file "$BACKUP_JOB_DIR/job.json" || return $?
    BACKUP_JOB_JSON="$(cat -- "$BACKUP_JOB_DIR/job.json")" || return 20
    jq -e --arg id "$1" '.schema_version == 1 and .id == $id and .job_id == $id and (.type == "docker" or .type == "system") and (.payload_dir|type == "string")' <<<"$BACKUP_JOB_JSON" >/dev/null || return 10
    BACKUP_PAYLOAD_DIR="$(jq -r .payload_dir <<<"$BACKUP_JOB_JSON")" || return 10
    vps_cmd_require_no_symlink_components "$BACKUP_PAYLOAD_DIR"
}

backup_job_state() {
    local stage="$1" error="${2:-}" json
    [[ "$stage" =~ ^[a-zA-Z0-9_-]+$ ]] || return 2
    backup_private_file "$BACKUP_JOB_DIR/job.json" || return $?
    json="$(jq --arg stage "$stage" --arg error "$error" --arg time "$(date -u +%FT%TZ)" '.state=$stage | .stage=$stage | .updated_at=$time | .error=(if $error == "" then null else $error end)' "$BACKUP_JOB_DIR/job.json")" || return 10
    backup_atomic_json "$BACKUP_JOB_DIR/job.json" "$json"
}

backup_payload_index() (
    local payload="$1" temporary file digest size relative
    backup_manifest_validate "$payload/manifest.json" || return $?
    [[ -z "$(find "$payload" -mindepth 1 ! -type f ! -type d -print -quit)" ]] || {
        vps_cmd_error '恢复材料必须由普通文件和目录组成；拒绝符号链接或设备文件'
        return 30
    }
    while IFS= read -r relative; do
        [[ -f "$payload/$relative" && ! -L "$payload/$relative" ]] || {
            vps_cmd_error "缺少必需恢复材料：$relative"
            return 30
        }
    done < <(jq -r '.required_files // [] | .[]' "$payload/manifest.json")
    temporary="$(mktemp "${payload%/*}/.payload-index.XXXXXXXX")" || return 20
    trap 'rm -f -- "$temporary"' EXIT
    while IFS= read -r -d '' file; do
        relative="${file#"$payload/"}"
        [[ "$relative" != .vpsctl-files.json ]] || continue
        [[ "$relative" != *$'\n'* && "$relative" != *$'\r'* ]] || return 10
        digest="$(sha256sum -- "$file")" size="$(stat -c %s -- "$file")" || return 20
        jq -cn --arg path "$relative" --arg digest "${digest%% *}" --argjson size "$size" '{path:$path,sha256:$digest,size:$size}' >>"$temporary" || return 20
    done < <(find "$payload" -type f -print0)
    jq -s '{schema_version:1,files:sort_by(.path)}' "$temporary"
)

backup_payload_verify() {
    local payload="$1" expected actual
    [[ -f "$payload/.vpsctl-files.json" && ! -L "$payload/.vpsctl-files.json" ]] || return 30
    expected="$(jq -cS . "$payload/.vpsctl-files.json")" || return 10
    actual="$(backup_payload_index "$payload" | jq -cS .)" || return 30
    [[ "$expected" == "$actual" ]] || {
        vps_cmd_error '已封存的恢复材料发生变化或缺失；保留现场，不能重传不同数据'
        return 30
    }
}

# Resolve a single hex ID, inspect the stored manifest and index, and verify that
# every sealed file is represented in the snapshot. No local plan is required.
backup_snapshot_validate() {
    local repo="$1" snapshot="$2" kind="$3" completion="${4:-complete}" snapshots nodes manifest index prefix
    [[ "$snapshot" =~ ^[0-9a-f]{8,64}$ ]] && [[ "$kind" == system || "$kind" == docker ]] || return 2
    snapshots="$(backup_restic "$repo" snapshots --json "$snapshot")" || return 20
    jq -e --arg kind "type:$kind" --arg completion "$completion" 'length == 1 and (.[0].tags|index("vpsctl") != null and index($kind) != null and index($completion) != null)' <<<"$snapshots" >/dev/null || {
        vps_cmd_error '快照不是请求类型的完整恢复点，或 ID 不唯一'
        return 10
    }
    BACKUP_SNAPSHOT_ID="$(jq -r '.[0].id' <<<"$snapshots")" || return 10
    nodes="$(backup_restic "$repo" ls --json "$BACKUP_SNAPSHOT_ID")" || return 20
    prefix="$(jq -rs '[.[]|select(.type == "file" and (.path|endswith("/manifest.json")))|.path]|sort_by(length)|.[0] // empty' <<<"$nodes")" || return 10
    [[ -n "$prefix" ]] || return 30
    prefix="${prefix%/manifest.json}"
    manifest="$(backup_restic "$repo" dump "$BACKUP_SNAPSHOT_ID" "$prefix/manifest.json")" || return 30
    index="$(backup_restic "$repo" dump "$BACKUP_SNAPSHOT_ID" "$prefix/.vpsctl-files.json")" || return 30
    jq -e --arg kind "$kind" '.schema_version == 1 and .type == $kind and (.job_id|type == "string") and (.plan_id|type == "string") and (.source_host|type == "string") and (.captured_at|type == "string")' <<<"$manifest" >/dev/null || return 10
    jq -e '.schema_version == 1 and (.files|type == "array" and length > 0 and all(.[]; (.path|type == "string" and (startswith("/")|not) and (split("/")|all(.[]; . != ".." and . != "." and . != ""))) and (.sha256|test("^[0-9a-f]{64}$")) and (.size|type == "number" and . >= 0)))' <<<"$index" >/dev/null || return 10
    jq -en --argjson manifest "$manifest" --argjson index "$index" --argjson snapshots "$snapshots" --arg prefix "$prefix" --argjson nodes "$(jq -s . <<<"$nodes")" '
      ($snapshots[0].tags|index("job:"+$manifest.job_id) != null and index("plan:"+$manifest.plan_id) != null) and
      ($snapshots[0].hostname == $manifest.source_host) and
      ($index.files|map(.path)|index("manifest.json") != null) and
      all($index.files[]; . as $file | any($nodes[]; .type == "file" and .path == ($prefix+"/"+$file.path) and .size == $file.size)) and
      all(($manifest.required_files // [])[]; . as $required | any($index.files[]; .path == $required))' >/dev/null || return 30
    BACKUP_SNAPSHOT_PREFIX="$prefix" BACKUP_SNAPSHOT_MANIFEST="$manifest" BACKUP_SNAPSHOT_INDEX="$index"
}

backup_upload_job() (
    local job="$1" repo kind plan host sealed snapshots snapshot result status=0 json lock_fd captured
    backup_ensure_tools jq restic flock date || return $?
    backup_job_load "$job" || return $?
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || {
        vps_cmd_info "演练：重传现有材料 $BACKUP_PAYLOAD_DIR"
        return 0
    }
    exec {lock_fd}>"$BACKUP_JOB_DIR/upload.lock" || return 20
    flock -n "$lock_fd" || {
        vps_cmd_error '该任务正在上传'
        return 3
    }
    repo="$(jq -r .repo <<<"$BACKUP_JOB_JSON")" kind="$(jq -r .type <<<"$BACKUP_JOB_JSON")" plan="$(jq -r .plan_id <<<"$BACKUP_JOB_JSON")" host="$(jq -r .source_host <<<"$BACKUP_JOB_JSON")" || return 10
    if jq -e '.state == "complete" and (.local_payload_cleaned_at|type == "string")' <<<"$BACKUP_JOB_JSON" >/dev/null; then
        snapshot="$(jq -r .snapshot_id <<<"$BACKUP_JOB_JSON")" || return 10
        backup_snapshot_validate "$repo" "$snapshot" "$kind" || return $?
        jq -e --arg job "$job" '.job_id == $job' <<<"$BACKUP_SNAPSHOT_MANIFEST" >/dev/null || return 10
        printf '%s\n' "$BACKUP_SNAPSHOT_ID"
        return 0
    fi
    backup_manifest_validate "$BACKUP_PAYLOAD_DIR/manifest.json" "$kind" || {
        backup_job_state incomplete '恢复材料清单无效'
        return 30
    }
    jq -e --arg job "$job" --arg plan "$plan" --arg host "$host" '.job_id == $job and .plan_id == $plan and .source_host == $host' "$BACKUP_PAYLOAD_DIR/manifest.json" >/dev/null || return 10
    captured="$(date -u -d "$(jq -r .captured_at "$BACKUP_PAYLOAD_DIR/manifest.json")" '+%Y-%m-%d %H:%M:%S')" || return 10
    if [[ ! -e "$BACKUP_PAYLOAD_DIR/.vpsctl-files.json" ]]; then
        if [[ ! -e "$BACKUP_PAYLOAD_DIR/backup-tool-versions.json" ]]; then
            sealed="$(backup_tool_versions)" || return $?
            backup_atomic_json "$BACKUP_PAYLOAD_DIR/backup-tool-versions.json" "$sealed" || return $?
        fi
        sealed="$(backup_payload_index "$BACKUP_PAYLOAD_DIR")" || {
            backup_job_state incomplete '恢复材料不完整'
            return 30
        }
        backup_atomic_json "$BACKUP_PAYLOAD_DIR/.vpsctl-files.json" "$sealed" || return $?
    fi
    backup_payload_verify "$BACKUP_PAYLOAD_DIR" || {
        backup_job_state incomplete '封存材料被修改'
        return 30
    }
    # Reconcile a lost response after tagging before attempting another upload.
    snapshots="$(backup_list_snapshots "$repo" "$kind" "$plan")" || return $?
    snapshot="$(jq -r --arg job "job:$job" '[.[]|select(.tags|index($job) != null)][0].id // empty' <<<"$snapshots")" || return 10
    if [[ -z "$snapshot" ]]; then
        backup_job_state uploading || return $?
        result="$(cd -- "$BACKUP_PAYLOAD_DIR" && TZ=UTC backup_restic_retry "$repo" backup . --json --host "$host" --time "$captured" --tag "vpsctl,candidate,type:$kind,plan:$plan,job:$job")" || status=$?
        if ((status != 0)); then
            backup_job_state upload_failed "Restic 退出码 $status；材料保留，可重试同一 job" || return 30
            ((status != 3)) || return 30
            return 20
        fi
        snapshot="$(jq -r 'select(.message_type == "summary")|.snapshot_id // empty' <<<"$result")" || return 20
        [[ "$snapshot" =~ ^[0-9a-f]{8,64}$ ]] || return 30
        backup_snapshot_validate "$repo" "$snapshot" "$kind" candidate || {
            backup_job_state incomplete '候选快照缺少恢复材料'
            return 30
        }
        [[ "$(jq -cS . <<<"$BACKUP_SNAPSHOT_INDEX")" == "$(jq -cS . "$BACKUP_PAYLOAD_DIR/.vpsctl-files.json")" ]] || return 30
        backup_payload_verify "$BACKUP_PAYLOAD_DIR" || {
            backup_job_state incomplete '上传期间本地封存材料发生变化，保留候选快照'
            return 30
        }
        backup_restic "$repo" tag --remove candidate --add complete "$snapshot" >&2 || status=$?
        # A tag response may be lost even though the new snapshot was committed.
        snapshots="$(backup_list_snapshots "$repo" "$kind" "$plan")" || {
            backup_job_state upload_failed '标记结果未知；重试将先对账'
            return 30
        }
        snapshot="$(jq -r --arg job "job:$job" '[.[]|select(.tags|index($job) != null)][0].id // empty' <<<"$snapshots")" || return 10
        [[ -n "$snapshot" ]] || {
            backup_job_state upload_failed "完整标记未完成，Restic 退出码 $status"
            return 30
        }
    fi
    backup_snapshot_validate "$repo" "$snapshot" "$kind" || {
        backup_job_state incomplete '完整快照复核失败'
        return 30
    }
    json="$(jq --arg snapshot "$BACKUP_SNAPSHOT_ID" --arg time "$(date -u +%FT%TZ)" '.snapshot_id=$snapshot | .final_snapshot=$snapshot | .remote_complete_at=$time | .state="complete" | .stage="complete" | .error=null' "$BACKUP_JOB_DIR/job.json")" || return 20
    backup_atomic_json "$BACKUP_JOB_DIR/job.json" "$json" || return 30
    printf '%s\n' "$BACKUP_SNAPSHOT_ID"
)

backup_restore_snapshot() (
    local repo="$1" snapshot="$2" target="${3%/}" kind="$4" temporary source lock_fd parent
    backup_valid_id "$repo" || return 2
    vps_cmd_require_no_symlink_components "$target" || return $?
    if [[ -e "$target" ]]; then
        [[ -d "$target" && -z "$(find "$target" -mindepth 1 -print -quit)" ]] || {
            vps_cmd_error '恢复目标必须不存在或为空目录'
            return 3
        }
    fi
    backup_ensure_tools jq restic flock || return $?
    backup_snapshot_validate "$repo" "$snapshot" "$kind" || return $?
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || {
        vps_cmd_info "演练：取回完整快照 $BACKUP_SNAPSHOT_ID 到 $target"
        return 0
    }
    parent="${target%/*}"
    [[ -n "$parent" ]] || parent=/
    backup_private_dir "$BACKUP_STATE" "$BACKUP_STATE/locks" || return $?
    if [[ "$parent" != / ]]; then backup_private_dir "$parent" || return $?; fi
    vps_cmd_require_no_symlink_components "$BACKUP_STATE/locks/repo-$repo.lock" || return $?
    exec {lock_fd}>"$BACKUP_STATE/locks/repo-$repo.lock" || return 20
    flock -n -s "$lock_fd" || {
        vps_cmd_error '仓库正在本机清理，稍后恢复'
        return 3
    }
    temporary="$(mktemp -d "$parent/.vpsctl-restore.XXXXXXXX")" || return 20
    trap 'rm -rf -- "$temporary"' EXIT
    backup_restic_retry "$repo" restore "$BACKUP_SNAPSHOT_ID" --target "$temporary" --verify >&2 || return 20
    source="$temporary$BACKUP_SNAPSHOT_PREFIX"
    vps_cmd_require_no_symlink_components "$source" || return 30
    backup_manifest_validate "$source/manifest.json" "$kind" || return $?
    backup_payload_verify "$source" || return $?
    if [[ -d "$target" ]]; then rmdir -- "$target" || return 3; fi
    mv -- "$source" "$target" || return 20
    chmod 0700 -- "$target" || return 20
)

# Called under the host capture lock before the next collection. Remote metadata
# is the authority for deletion; only its sealed, unchanged regular files are
# removed. Unknown files and nonempty directories are never removed recursively.
backup_cleanup_completed_job() (
    local job="$1" repo kind work snapshot snapshots listed_snapshot relative path digest expected json directory lock_fd repo_lock_fd versions remaining=false
    local -a files=()
    local -A directories=()
    backup_job_load "$job" || return $?
    jq -e '.state == "complete" and (.snapshot_id|type == "string")' <<<"$BACKUP_JOB_JSON" >/dev/null || return 3
    repo="$(jq -r .repo <<<"$BACKUP_JOB_JSON")" kind="$(jq -r .type <<<"$BACKUP_JOB_JSON")" work="$(jq -r .work_dir <<<"$BACKUP_JOB_JSON")" snapshot="$(jq -r .snapshot_id <<<"$BACKUP_JOB_JSON")" || return 10
    backup_valid_id "$repo" || return 10
    [[ "$snapshot" =~ ^[0-9a-f]{64}$ ]] || return 10
    vps_cmd_require_no_symlink_components "$work" || return $?
    [[ "$BACKUP_PAYLOAD_DIR" == "$work/$job/payload" ]] || {
        vps_cmd_error "拒绝清理不属于任务 $job 的材料路径"
        return 10
    }
    [[ -d "$BACKUP_PAYLOAD_DIR" ]] || return 0
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：核验完整快照 $snapshot 后，保存任务 $job 的小型元数据并清理封存材料 $BACKUP_PAYLOAD_DIR；额外文件保留"
        return 0
    fi
    vps_cmd_require_no_symlink_components "$BACKUP_JOB_DIR/upload.lock" || return $?
    exec {lock_fd}>"$BACKUP_JOB_DIR/upload.lock" || return 20
    flock -n "$lock_fd" || return 3
    backup_private_dir "$BACKUP_STATE/locks" || return $?
    vps_cmd_require_no_symlink_components "$BACKUP_STATE/locks/repo-$repo.lock" || return $?
    exec {repo_lock_fd}>"$BACKUP_STATE/locks/repo-$repo.lock" || return 20
    flock -n -s "$repo_lock_fd" || return 3
    # Retention may remove a late-uploaded snapshot before the next collection.
    # List raw IDs: `snapshots --json` can silently omit corrupt snapshots while
    # returning success. A present object must still pass full validation below.
    snapshots="$(backup_restic "$repo" list snapshots)" || return 20
    if [[ -n "$snapshots" ]]; then
        while IFS= read -r listed_snapshot; do
            [[ "$listed_snapshot" =~ ^[0-9a-f]{64}$ ]] || return 10
        done <<<"$snapshots"
    fi
    if [[ $'\n'"$snapshots"$'\n' != *$'\n'"$snapshot"$'\n'* ]]; then
        json="$(jq --arg time "$(date -u +%FT%TZ)" '.local_cleanup={state:"skipped",reason:"snapshot_missing",checked_at:$time}' "$BACKUP_JOB_DIR/job.json")" || return 10
        backup_atomic_json "$BACKUP_JOB_DIR/job.json" "$json" || return $?
        vps_cmd_warning "任务 $job 的远端快照 $snapshot 已不存在；保留本地材料，跳过清理并继续备份"
        return 0
    fi
    backup_snapshot_validate "$repo" "$snapshot" "$kind" || return $?
    jq -en --argjson manifest "$BACKUP_SNAPSHOT_MANIFEST" --argjson job "$BACKUP_JOB_JSON" \
        '$manifest.job_id == $job.job_id and $manifest.plan_id == $job.plan_id and $manifest.source_host == $job.source_host' >/dev/null || return 10
    if [[ -e "$BACKUP_PAYLOAD_DIR/.vpsctl-files.json" || -L "$BACKUP_PAYLOAD_DIR/.vpsctl-files.json" ]]; then
        [[ -f "$BACKUP_PAYLOAD_DIR/.vpsctl-files.json" && ! -L "$BACKUP_PAYLOAD_DIR/.vpsctl-files.json" ]] || return 30
        [[ "$(jq -cS . "$BACKUP_PAYLOAD_DIR/.vpsctl-files.json")" == "$(jq -cS . <<<"$BACKUP_SNAPSHOT_INDEX")" ]] || return 30
        files+=("$BACKUP_PAYLOAD_DIR/.vpsctl-files.json")
    fi
    while IFS= read -r -d '' relative; do
        path="$BACKUP_PAYLOAD_DIR/$relative"
        vps_cmd_require_no_symlink_components "$path" || return $?
        if [[ -e "$path" ]]; then
            [[ -f "$path" ]] || return 30
            digest="$(sha256sum -- "$path")" || return 20
            expected="$(jq -r --arg path "$relative" '.files[]|select(.path == $path)|.sha256' <<<"$BACKUP_SNAPSHOT_INDEX")" || return 10
            [[ "${digest%% *}" == "$expected" ]] || {
                vps_cmd_error "保留已发生变化的任务材料：$path"
                return 30
            }
            files+=("$path")
        fi
        directory="${path%/*}"
        while [[ "$directory" != "$BACKUP_PAYLOAD_DIR" ]]; do
            directories["$directory"]=1
            directory="${directory%/*}"
        done
    done < <(jq -j '.files[]|.path,"\u0000"' <<<"$BACKUP_SNAPSHOT_INDEX")
    backup_atomic_json "$BACKUP_JOB_DIR/manifest.json" "$BACKUP_SNAPSHOT_MANIFEST" || return $?
    backup_atomic_json "$BACKUP_JOB_DIR/payload-index.json" "$BACKUP_SNAPSHOT_INDEX" || return $?
    if jq -e '.files|any(.[]; .path == "backup-tool-versions.json")' <<<"$BACKUP_SNAPSHOT_INDEX" >/dev/null; then
        versions="$(backup_restic "$repo" dump "$snapshot" "$BACKUP_SNAPSHOT_PREFIX/backup-tool-versions.json")" || return 20
        backup_atomic_json "$BACKUP_JOB_DIR/backup-tool-versions.json" "$versions" || return $?
    fi
    json="$(jq --arg time "$(date -u +%FT%TZ)" '.local_cleanup={state:"removing",started_at:$time}' "$BACKUP_JOB_DIR/job.json")" || return 10
    backup_atomic_json "$BACKUP_JOB_DIR/job.json" "$json" || return $?
    for path in "${files[@]}"; do
        vps_cmd_require_no_symlink_components "$path" || return 30
        rm -- "$path" || return 30
    done
    if ((${#directories[@]})); then
        while IFS= read -r -d '' directory; do rmdir -- "$directory" 2>/dev/null || true; done < <(printf '%s\0' "${!directories[@]}" | sort -zr)
    fi
    rmdir -- "$BACKUP_PAYLOAD_DIR" 2>/dev/null || remaining=true
    rmdir -- "${BACKUP_PAYLOAD_DIR%/*}" 2>/dev/null || true
    json="$(jq --arg time "$(date -u +%FT%TZ)" --argjson remaining "$remaining" '.local_payload_cleaned_at=$time | .local_cleanup={state:"completed",completed_at:$time,unknown_files_retained:$remaining}' "$BACKUP_JOB_DIR/job.json")" || return 10
    backup_atomic_json "$BACKUP_JOB_DIR/job.json" "$json" || return 30
    vps_cmd_info "已清理任务 $job 的已上传材料；任务记录及小型清单保留"
)

backup_cleanup_completed() (
    local kind="$1" plan="$2" file job failed=0
    [[ "$kind" == docker || "$kind" == system ]] && backup_valid_id "$plan" || return 2
    backup_ensure_tools jq restic flock || return $?
    for file in "$BACKUP_STATE/jobs/"*/job.json; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        if ! jq -e --arg kind "$kind" --arg plan "$plan" '.schema_version == 1 and .type == $kind and .plan_id == $plan and .state == "complete" and (.snapshot_id|type == "string") and (.local_payload_cleaned_at == null)' "$file" >/dev/null; then continue; fi
        job="${file%/job.json}"
        job="${job##*/}"
        if ! backup_cleanup_completed_job "$job"; then
            vps_cmd_warning "任务 $job 的本地材料清理未完成，已保留未删除内容"
            failed=1
        fi
    done
    ((failed == 0)) || return 30
)

# Retention is a separate outcome from the completed backup. An old capture
# uploaded late is never immediately removed by automatic maintenance.
backup_maintain_completed() (
    local job="$1" repo kind plan snapshot host snapshots newest result='passed' reason='' status=0 json
    backup_ensure_tools jq restic flock || return $?
    backup_job_load "$job" || return $?
    jq -e '.state == "complete" and (.snapshot_id|type == "string")' <<<"$BACKUP_JOB_JSON" >/dev/null || return 3
    repo="$(jq -r .repo <<<"$BACKUP_JOB_JSON")" kind="$(jq -r .type <<<"$BACKUP_JOB_JSON")" plan="$(jq -r .plan_id <<<"$BACKUP_JOB_JSON")" snapshot="$(jq -r .snapshot_id <<<"$BACKUP_JOB_JSON")" host="$(jq -r .source_host <<<"$BACKUP_JOB_JSON")" || return 10
    if backup_snapshot_validate "$repo" "$snapshot" "$kind" && snapshots="$(backup_list_snapshots "$repo" "$kind" "$plan")"; then
        newest="$(jq -r --arg host "$host" '[.[]|select(.hostname == $host)][0].id // empty' <<<"$snapshots")" || return 10
        if [[ "$newest" != "$snapshot" ]]; then
            result=skipped reason='当前任务不是该源主机与计划按采集时间排序的最新完整快照'
        elif ! backup_repo_prune "$repo" "$plan" >/dev/null; then status=20; fi
    else status=20; fi
    if ((status != 0)); then result=failed reason='备份已完成；自动保留策略维护失败，可稍后单独重试'; fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        json="$(jq --arg time "$(date -u +%FT%TZ)" --arg result "$result" --arg reason "$reason" --argjson status "$status" '.maintenance={checked_at:$time,result:$result,reason:$reason,exit_code:$status}' "$BACKUP_JOB_DIR/job.json")" || return 10
        backup_atomic_json "$BACKUP_JOB_DIR/job.json" "$json" || return 30
    fi
    vps_cmd_info "任务 $job 的保留策略维护：$result${reason:+；$reason}"
    ((status == 0)) || return 30
)
