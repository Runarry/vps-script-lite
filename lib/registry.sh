# Fixed command registry for vpsctl. Feature scripts are never discovered by
# scanning the filesystem; each command must be explicitly registered here.

declare -ga VPS_DOMAIN_IDS=()
declare -gA VPS_DOMAIN_LABEL=()
declare -gA VPS_DOMAIN_DESCRIPTION=()

declare -ga VPS_COMMAND_KEYS=()
declare -gA VPS_COMMAND_DOMAIN=()
declare -gA VPS_COMMAND_ACTION=()
declare -gA VPS_COMMAND_LABEL=()
declare -gA VPS_COMMAND_SUMMARY=()
declare -gA VPS_COMMAND_PATH=()
declare -gA VPS_COMMAND_RISK=()
declare -gA VPS_COMMAND_PRIVILEGE=()
declare -gA VPS_COMMAND_DRY_RUN=()
declare -gA VPS_COMMAND_REQUIREMENTS=()
declare -gA VPS_COMMAND_LIFECYCLE=()
declare -ga VPS_REGISTRY_RESULTS=()

vps_registry_register_domain() {
    local domain="$1"
    local label="$2"
    local description="$3"

    if [[ ! "$domain" =~ ^[a-z][a-z0-9-]*$ ]]; then
        printf 'vpsctl registry: invalid domain: %s\n' "$domain" >&2
        return 10
    fi
    if [[ -n "${VPS_DOMAIN_LABEL[$domain]:-}" ]]; then
        printf 'vpsctl registry: duplicate domain: %s\n' "$domain" >&2
        return 10
    fi

    VPS_DOMAIN_IDS+=("$domain")
    VPS_DOMAIN_LABEL[$domain]="$label"
    VPS_DOMAIN_DESCRIPTION[$domain]="$description"
}

vps_registry_register_command() {
    local domain="$1"
    local action="$2"
    local label="$3"
    local summary="$4"
    local path="$5"
    local risk="$6"
    local privilege="$7"
    local dry_run="$8"
    local requirements="$9"
    local lifecycle="${10}"
    local command_key="${domain}:${action}"

    if [[ -z "${VPS_DOMAIN_LABEL[$domain]:-}" ]]; then
        printf 'vpsctl registry: command uses unknown domain: %s\n' "$domain" >&2
        return 10
    fi
    if [[ ! "$action" =~ ^[a-z][a-z0-9-]*$ ]]; then
        printf 'vpsctl registry: invalid action: %s\n' "$action" >&2
        return 10
    fi
    if [[ -n "${VPS_COMMAND_PATH[$command_key]:-}" ]]; then
        printf 'vpsctl registry: duplicate command: %s %s\n' "$domain" "$action" >&2
        return 10
    fi
    if [[ "$path" != "commands/${domain}/${action}.sh" ]]; then
        printf 'vpsctl registry: unsafe command path: %s\n' "$path" >&2
        return 10
    fi
    case "$risk" in read-only | change | disruptive | destructive) ;; *) return 10 ;; esac
    case "$privilege" in user | optional-root | root) ;; *) return 10 ;; esac
    case "$dry_run" in supported | not-applicable | unsupported) ;; *) return 10 ;; esac
    case "$lifecycle" in experimental | stable | deprecated) ;; *) return 10 ;; esac

    VPS_COMMAND_KEYS+=("$command_key")
    VPS_COMMAND_DOMAIN[$command_key]="$domain"
    VPS_COMMAND_ACTION[$command_key]="$action"
    VPS_COMMAND_LABEL[$command_key]="$label"
    VPS_COMMAND_SUMMARY[$command_key]="$summary"
    VPS_COMMAND_PATH[$command_key]="$path"
    VPS_COMMAND_RISK[$command_key]="$risk"
    VPS_COMMAND_PRIVILEGE[$command_key]="$privilege"
    VPS_COMMAND_DRY_RUN[$command_key]="$dry_run"
    VPS_COMMAND_REQUIREMENTS[$command_key]="$requirements"
    VPS_COMMAND_LIFECYCLE[$command_key]="$lifecycle"
}

vps_registry_init() {
    VPS_DOMAIN_IDS=()
    VPS_DOMAIN_LABEL=()
    VPS_DOMAIN_DESCRIPTION=()
    VPS_COMMAND_KEYS=()
    VPS_COMMAND_DOMAIN=()
    VPS_COMMAND_ACTION=()
    VPS_COMMAND_LABEL=()
    VPS_COMMAND_SUMMARY=()
    VPS_COMMAND_PATH=()
    VPS_COMMAND_RISK=()
    VPS_COMMAND_PRIVILEGE=()
    VPS_COMMAND_DRY_RUN=()
    VPS_COMMAND_REQUIREMENTS=()
    VPS_COMMAND_LIFECYCLE=()
    VPS_REGISTRY_RESULTS=()

    vps_registry_register_domain "system" "系统维护" "系统信息、账户、软件包与基础维护"
    vps_registry_register_domain "service" "服务管理" "系统服务安装、配置与生命周期管理"
    vps_registry_register_domain "deploy" "应用部署" "软件和应用部署"
    vps_registry_register_domain "network" "网络管理" "网络、DNS、防火墙与连通性"
    vps_registry_register_domain "security" "安全加固" "访问控制、审计、证书与系统加固"
    vps_registry_register_domain "backup" "备份恢复" "备份、恢复与保留策略"
    vps_registry_register_domain "monitoring" "监控诊断" "健康检查、资源观察与告警"

    # Register feature commands below with vps_registry_register_command.
    # No feature command is implemented in the current release.
}

vps_registry_has_command() {
    local command_key="$1"
    [[ -n "${VPS_COMMAND_PATH[$command_key]:-}" ]]
}

vps_registry_commands_for_domain() {
    local domain="$1"
    local command_key

    VPS_REGISTRY_RESULTS=()
    for command_key in "${VPS_COMMAND_KEYS[@]}"; do
        if [[ "${VPS_COMMAND_DOMAIN[$command_key]}" == "$domain" ]]; then
            VPS_REGISTRY_RESULTS+=("$command_key")
        fi
    done
}

vps_registry_count_commands() {
    local domain="$1"
    local command_key count=0

    for command_key in "${VPS_COMMAND_KEYS[@]}"; do
        [[ "${VPS_COMMAND_DOMAIN[$command_key]}" == "$domain" ]] && count=$((count + 1))
    done
    printf '%s' "$count"
}
