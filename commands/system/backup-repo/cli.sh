# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034 # jq variables and flags consumed by command.sh.

backup_repo_usage() {
    cat <<'EOF'
用法：vpsctl system backup-repo [status|list] [--json]
      vpsctl system backup-repo configure <repo> --type s3|webdav|local --password-file <file> [选项]
      vpsctl system backup-repo probe|init <repo>
      vpsctl system backup-repo check <repo> [--read-data | --read-data-subset <n/t|百分比%>]
      vpsctl system backup-repo prune <repo> --plan <plan>

configure 必填：--password-file 为已有仓库解密密码（非空、0600）；同名仓库可重新配置，旧配置保存在 .previous。
  S3：--endpoint <https://host> --bucket <name> --credentials-file <0600 JSON>
      [--prefix <path>] [--region <region>] [--bucket-lookup auto|path|dns]
      凭据字段：access_key_id、secret_access_key、可选 session_token。
  WebDAV：--url <https://host/path> --credentials-file <0600 JSON> [--vendor other] [--prefix <path>]
      凭据字段：user、password；或 bearer_token。密码仅从文件读取。
  local：--path <绝对仓库路径>（适用于离线加密仓库）
  通用：[--ca-file <PEM>] [--pack-size 4..128] [--connections 1..32] [--timeout 1..3600]
        --allow-http 仅在明确接受明文连接时允许 http，默认验证 TLS。

status/list 只读本地，不连接远端、不安装工具，普通用户可查看可读配置的脱敏概览。
probe 在独立的 .vpsctl-probe 仓库写入、列举、读回和删除测试文件；保留探测仓库骨架。
init 先执行 probe，再初始化加密 v2 仓库；已有仓库保持不变。
check 默认仅检查仓库结构；--read-data 才是完整数据读取。小文件 probe 不能证明服务端大文件兼容。
prune 永久删除指定计划/源主机/类型的过期完整快照，始终保留最新完整快照；候选快照不自动删除。
实际配置、探测、初始化和清理需要 root；维护需确认，--yes 可授权。check 需要读取受保护凭据。
请在服务器之外另存密码和访问凭据；仓库无法在丢失密码后解密。
支持：--dry-run --install-deps --yes --non-interactive --quiet --verbose --no-color --help
演练不写配置、不上传或删除；可能读取仓库以展示清理计划。
退出码：0 成功，2 参数，3 依赖/前置条件，4 权限，10 配置，20 外部失败，30 部分完成，130 取消。
EOF
}

backup_repo_parse() {
    local positional=0 option
    local -a args=()
    REPO_ACTION='' REPO_ID='' REPO_JSON=0 REPO_TYPE='' REPO_PASSWORD='' REPO_CREDENTIALS=''
    REPO_ENDPOINT='' REPO_BUCKET='' REPO_PREFIX='' REPO_REGION='us-east-1' REPO_LOOKUP=auto
    REPO_URL='' REPO_VENDOR=other REPO_PATH='' REPO_CA='' REPO_PACK=16 REPO_CONNECTIONS=4 REPO_TIMEOUT=120
    REPO_ALLOW_HTTP=false REPO_PLAN='' REPO_READ_DATA=0 REPO_SUBSET=''
    declare -gA REPO_SEEN=()
    while (($#)); do
        if ((positional == 0)); then
            case "$1" in
                --dry-run)
                    VPSCTL_DRY_RUN=1
                    shift
                    continue
                    ;;
                --install-deps)
                    VPSCTL_INSTALL_DEPS=1
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
                    REPO_JSON=1
                    shift
                    continue
                    ;;
                --allow-http)
                    REPO_ALLOW_HTTP=true
                    REPO_SEEN['--allow-http']=1
                    shift
                    continue
                    ;;
                --read-data)
                    REPO_READ_DATA=1
                    REPO_SEEN['--read-data']=1
                    shift
                    continue
                    ;;
                -h | --help)
                    REPO_ACTION=help
                    shift
                    continue
                    ;;
                --)
                    positional=1
                    shift
                    continue
                    ;;
                --type | --password-file | --credentials-file | --endpoint | --bucket | --prefix | --region | --bucket-lookup | --url | --vendor | --path | --ca-file | --pack-size | --connections | --timeout | --plan | --read-data-subset)
                    (($# >= 2)) && [[ -n "$2" && "$2" != --* ]] || return 2
                    option="$1"
                    REPO_SEEN[$option]=1
                    case "$option" in
                        --type) REPO_TYPE="$2" ;; --password-file) REPO_PASSWORD="$2" ;; --credentials-file) REPO_CREDENTIALS="$2" ;;
                        --endpoint) REPO_ENDPOINT="$2" ;; --bucket) REPO_BUCKET="$2" ;; --prefix) REPO_PREFIX="$2" ;;
                        --region) REPO_REGION="$2" ;; --bucket-lookup) REPO_LOOKUP="$2" ;; --url) REPO_URL="$2" ;;
                        --vendor) REPO_VENDOR="$2" ;; --path) REPO_PATH="$2" ;; --ca-file) REPO_CA="$2" ;;
                        --pack-size) REPO_PACK="$2" ;; --connections) REPO_CONNECTIONS="$2" ;; --timeout) REPO_TIMEOUT="$2" ;;
                        --plan) REPO_PLAN="$2" ;; --read-data-subset) REPO_SUBSET="$2" ;;
                    esac
                    shift 2
                    continue
                    ;;
                -*) return 2 ;;
            esac
        fi
        args+=("$1")
        shift
    done
    [[ "$REPO_ACTION" != help ]] || return 0
    ((${#args[@]} <= 2)) || return 2
    REPO_ACTION="${args[0]:-}" REPO_ID="${args[1]:-}"
    case "$REPO_ACTION" in
        '' | status | list | help) [[ -z "$REPO_ID" && ${#REPO_SEEN[@]} == 0 ]] || return 2 ;;
        configure | probe | init | check | prune) backup_valid_id "$REPO_ID" || return 2 ;;
        *) return 2 ;;
    esac
    for option in "${!REPO_SEEN[@]}"; do
        case "$REPO_ACTION:$option" in
            configure:--plan | configure:--read-data | configure:--read-data-subset) return 2 ;;
            configure:*) ;;
            check:--read-data | check:--read-data-subset | prune:--plan) ;;
            *) return 2 ;;
        esac
    done
    [[ "$REPO_ACTION" == status || "$REPO_ACTION" == list || "$REPO_JSON" == 0 ]] || return 2
    [[ "$REPO_ACTION" != prune ]] || backup_valid_id "$REPO_PLAN" || return 2
    [[ "$REPO_READ_DATA" == 0 || -z "$REPO_SUBSET" ]] || return 2
    if [[ -n "$REPO_SUBSET" ]]; then
        [[ "$REPO_SUBSET" =~ ^[1-9][0-9]*/[1-9][0-9]*$ || "$REPO_SUBSET" =~ ^([1-9][0-9]?|100)%$ ]] || return 2
    fi
}

backup_repo_status() {
    local file json='[]' entry
    if ! command -v jq >/dev/null 2>&1; then
        if ((REPO_JSON)); then
            vps_cmd_error 'JSON 状态需要已安装 jq；status 不安装工具'
            return 3
        fi
        printf '备份配置目录：%s（未安装 jq，无法解析配置；未连接远端）\n' "$BACKUP_ETC"
        return 0
    fi
    for file in "$BACKUP_ETC/repos/"*.json; do
        [[ -f "$file" && -r "$file" && ! -L "$file" ]] || continue
        entry="$(jq '{id,type,schema_version,password_configured:(.password_file|type == "string"),credentials_configured:(.credentials_file|type == "string" and length > 0)}' "$file")" || return 10
        json="$(jq --argjson entry "$entry" '. + [$entry]' <<<"$json")" || return 10
    done
    if ((REPO_JSON)); then
        jq -n --argjson repos "$json" --argjson readable "$([[ ! -e "$BACKUP_ETC/repos" || -r "$BACKUP_ETC/repos" ]] && printf true || printf false)" '{schema_version:1,remote_queried:false,configuration_readable:$readable,repositories:$repos}'
    else
        jq -r 'if length == 0 then "没有可读取的仓库配置（未连接远端）" else .[]|"仓库 \(.id)：\(.type)；密码已配置=\(.password_configured)（未连接远端）" end' <<<"$json"
    fi
}

backup_repo_config_json() {
    jq -n --arg id "$REPO_ID" --arg kind "$REPO_TYPE" --arg password "$REPO_PASSWORD" --arg credentials "$REPO_CREDENTIALS" \
        --arg endpoint "$REPO_ENDPOINT" --arg bucket "$REPO_BUCKET" --arg prefix "$REPO_PREFIX" --arg region "$REPO_REGION" --arg lookup "$REPO_LOOKUP" \
        --arg url "$REPO_URL" --arg vendor "$REPO_VENDOR" --arg path "$REPO_PATH" --arg ca "$REPO_CA" \
        --argjson pack "$REPO_PACK" --argjson connections "$REPO_CONNECTIONS" --argjson timeout "$REPO_TIMEOUT" --argjson http "$REPO_ALLOW_HTTP" \
        '{schema_version:1,id:$id,type:$kind,password_file:$password,credentials_file:$credentials,endpoint:$endpoint,bucket:$bucket,prefix:$prefix,region:$region,bucket_lookup:$lookup,url:$url,vendor:$vendor,path:$path,ca_file:$ca,pack_size:$pack,connections:$connections,timeout:$timeout,allow_http:$http}'
}

backup_repo_configure() {
    local json secret_directory config
    case "$REPO_TYPE" in s3 | webdav | local) ;; *) return 2 ;; esac
    [[ "$REPO_PACK" =~ ^[1-9][0-9]*$ && "$REPO_CONNECTIONS" =~ ^[1-9][0-9]*$ && "$REPO_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || return 2
    backup_ensure_tools jq || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || {
        vps_cmd_info '请安装上述依赖后重跑配置预检'
        return 0
    }
    json="$(backup_repo_config_json)" || return 2
    backup_repo_validate "$REPO_ID" "$json" || {
        vps_cmd_error '仓库参数无效，请检查类型所需参数、范围及 TLS 选项'
        return 2
    }
    backup_private_file "$REPO_PASSWORD" || return $?
    [[ -s "$REPO_PASSWORD" ]] || return 10
    [[ "$REPO_TYPE" == local ]] || backup_credentials_validate "$REPO_TYPE" "$REPO_CREDENTIALS" || return $?
    [[ -z "$REPO_CA" || (-f "$REPO_CA" && -r "$REPO_CA") ]] || return 3
    backup_ensure_tools restic || return $?
    [[ "$REPO_TYPE" != webdav ]] || backup_ensure_tools rclone || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || {
        vps_cmd_info '请安装上述依赖后重跑配置预检'
        return 0
    }
    vps_cmd_info "配置仓库 $REPO_ID（$REPO_TYPE），复制凭据到受保护目录；已有配置保留 .previous"
    vps_cmd_confirm '保存此仓库配置？' || {
        local status=$?
        ((status != 1)) || status=130
        return "$status"
    }
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    backup_private_dir "$BACKUP_ETC" "$BACKUP_ETC/repos" "$BACKUP_ETC/secrets" || return $?
    secret_directory="$(mktemp -d "$BACKUP_ETC/secrets/$REPO_ID.XXXXXXXX")" || return 20
    install -m 0600 -- "$REPO_PASSWORD" "$secret_directory/password" || return 20
    REPO_PASSWORD="$secret_directory/password"
    if [[ "$REPO_TYPE" != local ]]; then
        install -m 0600 -- "$REPO_CREDENTIALS" "$secret_directory/credentials.json" || return 20
        REPO_CREDENTIALS="$secret_directory/credentials.json"
    fi
    if [[ -n "$REPO_CA" ]]; then
        install -m 0600 -- "$REPO_CA" "$secret_directory/ca.pem" || return 20
        REPO_CA="$secret_directory/ca.pem"
    fi
    json="$(backup_repo_config_json)" || return 20
    config="$BACKUP_ETC/repos/$REPO_ID.json"
    vps_cmd_require_no_symlink_components "$config" || return $?
    if [[ -f "$config" ]]; then
        vps_cmd_require_no_symlink_components "$config.previous" || return $?
        cp -p -- "$config" "$config.previous" || return 20
    fi
    backup_atomic_json "$config" "$json" || return $?
    vps_cmd_success "已保存仓库 $REPO_ID；请执行 probe/init 验证存储能力"
}

backup_repo_action() (
    local status
    vps_cmd_require_root || return $?
    backup_ensure_tools jq flock || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
    if [[ "$REPO_ACTION" == configure ]]; then
        trap 'vps_cmd_unlock' EXIT
        vps_cmd_lock backup-repo-config || return $?
        backup_repo_configure
        return $?
    fi
    backup_repo_load "$REPO_ID" || return $?
    if [[ "$REPO_ACTION" == check ]]; then
        [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || {
            vps_cmd_info '演练：将执行仓库校验，不记录状态'
            return 0
        }
        if ((REPO_READ_DATA)); then
            backup_repo_check "$REPO_ID" --read-data
        elif [[ -n "$REPO_SUBSET" ]]; then
            backup_repo_check "$REPO_ID" --read-data-subset "$REPO_SUBSET"
        else backup_repo_check "$REPO_ID"; fi
        return $?
    fi
    vps_cmd_info "仓库 $REPO_ID：动作 $REPO_ACTION${REPO_PLAN:+，仅计划 $REPO_PLAN 的旧完整快照}"
    vps_cmd_confirm '执行上述仓库操作？（prune 删除不可撤销）' || {
        status=$?
        ((status != 1)) || status=130
        return "$status"
    }
    case "$REPO_ACTION" in
        probe) backup_repo_probe "$REPO_ID" ;;
        init)
            backup_repo_probe "$REPO_ID" || return $?
            [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
            if backup_restic "$REPO_ID" cat config >/dev/null 2>&1; then
                vps_cmd_success '仓库已初始化'
                return 0
            fi
            backup_restic_retry "$REPO_ID" init --repository-version 2 || return 20
            ;;
        prune) backup_repo_prune "$REPO_ID" "$REPO_PLAN" ;;
    esac
)

backup_repo_menu() {
    local action id kind password credentials endpoint bucket url path status
    while true; do
        action="$(vps_cmd_prompt_select '备份仓库' status status '查看本地状态' configure '配置仓库' probe '检测写入与读回' init '初始化加密仓库' check '检查仓库结构' quit '退出')" || {
            status=$?
            ((status != 130)) || return 0
            return "$status"
        }
        case "$action" in
            quit) return 0 ;;
            status) backup_repo_parse status && backup_repo_status || return $? ;;
            configure)
                id="$(vps_cmd_prompt_value '仓库 ID（字母、数字、下划线、短横线）' '')" || return $?
                backup_valid_id "$id" || {
                    vps_cmd_warning '无效仓库 ID'
                    continue
                }
                kind="$(vps_cmd_prompt_select '存储类型' s3 s3 'S3' webdav 'WebDAV' local '本地离线仓库')" || return $?
                password="$(vps_cmd_prompt_value '仓库密码文件绝对路径（0600）' '')" || return $?
                case "$kind" in
                    local)
                        path="$(vps_cmd_prompt_value '仓库绝对路径' '')" || return $?
                        backup_repo_parse configure "$id" --type local --path "$path" --password-file "$password" || return $?
                        ;;
                    s3)
                        endpoint="$(vps_cmd_prompt_value 'S3 HTTPS endpoint' '')" || return $?
                        bucket="$(vps_cmd_prompt_value 'Bucket' '')" || return $?
                        credentials="$(vps_cmd_prompt_value '凭据 JSON 文件绝对路径（0600）' '')" || return $?
                        backup_repo_parse configure "$id" --type s3 --endpoint "$endpoint" --bucket "$bucket" --password-file "$password" --credentials-file "$credentials" || return $?
                        ;;
                    webdav)
                        url="$(vps_cmd_prompt_value 'WebDAV HTTPS URL' '')" || return $?
                        credentials="$(vps_cmd_prompt_value '凭据 JSON 文件绝对路径（0600）' '')" || return $?
                        backup_repo_parse configure "$id" --type webdav --url "$url" --password-file "$password" --credentials-file "$credentials" || return $?
                        ;;
                esac
                backup_repo_action || return $?
                ;;
            *)
                id="$(vps_cmd_prompt_value '仓库 ID' '')" || return $?
                backup_valid_id "$id" || {
                    vps_cmd_warning '无效仓库 ID'
                    continue
                }
                backup_repo_parse "$action" "$id" && backup_repo_action || return $?
                ;;
        esac
    done
}
