# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034 # jq programs and public API result variables.

backup_init() {
    BACKUP_PROJECT_ROOT="$1"
    BACKUP_ETC="$(vps_cmd_system_path /etc/vpsctl/backup)" || return $?
    BACKUP_STATE="$(vps_cmd_system_path /var/lib/vpsctl/backup)" || return $?
    BACKUP_LIBEXEC="$(vps_cmd_system_path /usr/local/libexec/vpsctl/backup)" || return $?
    export BACKUP_ETC BACKUP_STATE BACKUP_LIBEXEC
}

backup_valid_id() { [[ "${1:-}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]]; }

backup_ensure_tools() {
    vps_cmd_ensure_tools backup "$@" || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
    local tool version major minor marker
    for tool in "$@"; do
        marker=''
        case "$tool" in tar) marker='GNU tar' ;; date) marker='GNU coreutils' ;; esac
        if [[ -n "$marker" ]] && ! "$tool" --version 2>/dev/null | grep -q "$marker"; then
            local manager package saved_tool
            manager="$(vps_cmd_detect_package_manager)" || return $?
            package="$(vps_cmd_package_for_tool "$manager" "$tool")" || return $?
            if [[ "${VPSCTL_DRY_RUN:-0}" != 1 && "${VPSCTL_INSTALL_DEPS:-0}" != 1 ]]; then
                if ! vps_cmd_is_interactive; then
                    vps_cmd_error "备份需要 $marker；请用 --install-deps 授权安装"
                    return 3
                fi
                vps_cmd_warning "需要 $marker 软件包：$package"
                _vps_cmd_confirm_dependency_install || return $?
            fi
            vps_cmd_install_packages "$manager" "$package" || return $?
            if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
                VPS_CMD_DEPENDENCIES_PLANNED=1
                return 0
            fi
            hash -r
            saved_tool="$("$tool" --version)" || return 3
            [[ "$saved_tool" == *"$marker"* ]] || {
                vps_cmd_error "安装后 $marker 仍不可用"
                return 3
            }
        fi
        [[ "$tool" == restic ]] || continue
        version="$(restic version)" || return 20
        [[ "$version" =~ restic\ ([0-9]+)\.([0-9]+) ]] || return 3
        major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}"
        ((major > 0 || minor >= 14)) || {
            vps_cmd_error '需要 Restic >= 0.14（加密仓库 v2 和压缩支持）'
            return 3
        }
    done
}

backup_private_dir() {
    local path
    for path in "$@"; do
        vps_cmd_require_no_symlink_components "$path" || return $?
        if [[ -e "$path" ]]; then
            [[ -d "$path" && -w "$path" ]] || return 3
        else
            (
                umask 077
                mkdir -p -- "$path"
            ) || return 20
        fi
    done
}

backup_private_file() {
    local file="$1" mode owner
    vps_cmd_require_no_symlink_components "$file" || return $?
    [[ -f "$file" && -r "$file" ]] || {
        vps_cmd_error "无法读取文件：$file"
        return 3
    }
    mode="$(stat -c %a -- "$file")" owner="$(stat -c %u -- "$file")" || return 20
    if (((8#$mode & 077) != 0)) || [[ "$owner" != "$EUID" ]]; then
        vps_cmd_error "凭据/受管配置必须由当前用户拥有且其他用户不可读取：$file"
        return 10
    fi
}

backup_atomic_json() {
    local path="$1" json="$2" temporary
    vps_cmd_require_no_symlink_components "$path" || return $?
    jq -e 'type == "object"' >/dev/null <<<"$json" || return 10
    temporary="$(mktemp "${path%/*}/.backup-json.XXXXXXXX")" || return 20
    if ! printf '%s\n' "$json" >"$temporary" || ! chmod 0600 "$temporary" || ! mv -f -- "$temporary" "$path"; then
        rm -f -- "$temporary"
        return 20
    fi
}

backup_plan_validate() {
    local id="$1" kind="$2" json="$3"
    backup_valid_id "$id" && [[ "$kind" == system || "$kind" == docker ]] || return 2
    jq -e --arg id "$id" --arg kind "$kind" '
      def id: type == "string" and test("^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$");
      def count: type == "number" and floor == . and . >= 0 and . <= 10000;
      .schema_version == 1 and .id == $id and .type == $kind and (.repo|id) and
      (.work_dir|type == "string" and startswith("/") and . != "/" and (test("[\u0000-\u001f]")|not) and (split("/")|index("..")|not)) and
      (.retention|type == "object") and (.retention.daily|count) and (.retention.weekly|count) and (.retention.monthly|count) and
      (.options|type == "object")' >/dev/null <<<"$json" || {
        vps_cmd_error "计划格式不兼容或字段无效：$id（支持 schema_version=1）"
        return 10
    }
}

backup_plan_load() {
    backup_valid_id "$1" || return 2
    backup_ensure_tools jq || return $?
    backup_private_file "$BACKUP_ETC/plans/$1.json" || return $?
    BACKUP_PLAN_JSON="$(cat -- "$BACKUP_ETC/plans/$1.json")" || return 20
    backup_plan_validate "$1" "$2" "$BACKUP_PLAN_JSON"
}

backup_plan_write() {
    local id="$1" kind="$2" json="$3" file
    backup_ensure_tools jq || return $?
    backup_plan_validate "$id" "$kind" "$json" || return $?
    file="$BACKUP_ETC/plans/$id.json"
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || {
        vps_cmd_info "演练：保存 $kind 计划 $id"
        return 0
    }
    backup_private_dir "$BACKUP_ETC" "$BACKUP_ETC/plans" || return $?
    vps_cmd_require_no_symlink_components "$file" || return $?
    if [[ -f "$file" ]]; then
        vps_cmd_require_no_symlink_components "$file.previous" || return $?
        cp -p -- "$file" "$file.previous" || return 20
    fi
    backup_atomic_json "$file" "$json"
}

backup_repo_validate() {
    local id="$1" json="$2"
    backup_valid_id "$id" || return 2
    jq -e --arg id "$id" '
      def text: type == "string" and (test("[\u0000-\u001f]")|not);
      def path: text and startswith("/") and . != "/" and (split("/")|index("..")|not);
      def url: text and test("^https?://[^/@?#]+(/[^?#]*)?$");
      .schema_version == 1 and .id == $id and (.type == "s3" or .type == "webdav" or .type == "local") and
      (.password_file|path) and (.pack_size|type == "number" and floor == . and . >= 4 and . <= 128) and
      (.connections|type == "number" and floor == . and . >= 1 and . <= 32) and
      (.timeout|type == "number" and floor == . and . >= 1 and . <= 3600) and
      (.ca_file|. == "" or path) and (.allow_http|type == "boolean") and
      (if .type == "local" then (.path|path) else
        (.credentials_file|path) and (.prefix|text and (startswith("/")|not) and (split("/")|index("..")|not)) and
        (if .type == "s3" then (.endpoint|url) and (.bucket|text and test("^[a-zA-Z0-9][a-zA-Z0-9.-]*$")) and
          (.region|text) and (.bucket_lookup == "auto" or .bucket_lookup == "path" or .bucket_lookup == "dns") and
          (.allow_http or (.endpoint|startswith("https://")))
         else (.url|url) and (.vendor|text and test("^[a-zA-Z0-9_-]+$")) and (.allow_http or (.url|startswith("https://"))) end) end)' >/dev/null <<<"$json" || return 10
}

backup_repo_load() {
    backup_valid_id "$1" || return 2
    backup_ensure_tools jq || return $?
    backup_private_file "$BACKUP_ETC/repos/$1.json" || return $?
    BACKUP_REPO_JSON="$(cat -- "$BACKUP_ETC/repos/$1.json")" || return 20
    backup_repo_validate "$1" "$BACKUP_REPO_JSON" || {
        vps_cmd_error "仓库配置无效或格式不兼容：$1（支持 schema_version=1）"
        return 10
    }
}

backup_source_host() {
    local identity path
    path="$(vps_cmd_system_path /etc/machine-id)" || return $?
    if [[ -r "$path" ]]; then
        IFS= read -r identity <"$path" || true
        if [[ "$identity" =~ ^[a-fA-F0-9]{32}$ ]]; then
            printf '%s\n' "$identity"
            return 0
        fi
    fi
    hostname | tr -cd 'a-zA-Z0-9._-'
}

backup_tool_versions() {
    local restic_version='' rclone_version='' tar_version='' project_version='unknown'
    if command -v restic >/dev/null 2>&1; then restic_version="$(restic version)" || return 20; fi
    if command -v rclone >/dev/null 2>&1; then
        rclone_version="$(rclone version)" || return 20
        rclone_version="${rclone_version%%$'\n'*}"
    fi
    if command -v tar >/dev/null 2>&1; then
        tar_version="$(tar --version 2>/dev/null)" || tar_version='unavailable'
        tar_version="${tar_version%%$'\n'*}"
    fi
    if [[ -r "$BACKUP_PROJECT_ROOT/VERSION" ]]; then IFS= read -r project_version <"$BACKUP_PROJECT_ROOT/VERSION" || true; fi
    jq -n --arg restic "$restic_version" --arg rclone "$rclone_version" --arg tar "$tar_version" --arg arch "$(uname -m)" --arg system "$(uname -sr)" --arg version "$project_version" \
        '{schema_version:1,restic:$restic,rclone:$rclone,tar:$tar,architecture:$arch,source_system:$system,vpsctl:$version,minimum_restic:"0.14.0",backup_format:1}'
}
