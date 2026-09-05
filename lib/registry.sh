# shellcheck shell=bash
# shellcheck disable=SC2034
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

    vps_registry_register_domain \
        "network" \
        "网络设置" \
        "BBR、本机 DNS、IP 地址族偏好与 RFW 网络防护管理"

    vps_registry_register_domain \
        "system" \
        "系统管理" \
        "内核、软件包和主机基础维护"

    vps_registry_register_domain \
        "security" \
        "安全与访问" \
        "用户凭据、公钥、SSH 远程访问、TLS 证书与 Fail2ban 防护管理"

    vps_registry_register_domain \
        "service" \
        "服务管理" \
        "按需安装并管理长期运行的系统服务"

    vps_registry_register_domain \
        "test" \
        "服务器测试" \
        "运行第三方服务器综合质量与 TCP 网络质量测试"

    vps_registry_register_domain \
        "self" \
        "脚本管理" \
        "查看分发状态，并安全更新或卸载 vpsctl"

    vps_registry_register_command \
        "network" \
        "bbr" \
        "BBR 设置" \
        "查看、启用和调整当前内核提供的拥塞控制与 qdisc" \
        "commands/network/bbr.sh" \
        "change" \
        "optional-root" \
        "supported" \
        "linux" \
        "experimental"

    vps_registry_register_command \
        "network" \
        "dns" \
        "本机 DNS" \
        "查看、测试、替换、刷新和验证本机 DNS 服务器" \
        "commands/network/dns.sh" \
        "disruptive" \
        "optional-root" \
        "supported" \
        "linux" \
        "experimental"

    vps_registry_register_command \
        "network" \
        "ip-policy" \
        "IP 地址族偏好" \
        "查看、设置或恢复本机 glibc IPv4/IPv6 地址排序偏好" \
        "commands/network/ip-policy.sh" \
        "disruptive" \
        "optional-root" \
        "supported" \
        "linux,libc:glibc" \
        "experimental"

    vps_registry_register_command \
        "network" \
        "rfw" \
        "RFW 管理" \
        "安装、更新、配置和管理基于 XDP 的 RFW 服务" \
        "commands/network/rfw.sh" \
        "disruptive" \
        "optional-root" \
        "supported" \
        "linux,init:systemd" \
        "experimental"

    vps_registry_register_command \
        "system" \
        "kernel" \
        "内核管理" \
        "查看、安装、固定切换或按版本安全卸载系统内核" \
        "commands/system/kernel.sh" \
        "disruptive" \
        "optional-root" \
        "supported" \
        "linux,os:debian-family" \
        "experimental"

    vps_registry_register_command \
        "security" \
        "access" \
        "访问管理" \
        "管理用户、密码、公钥与可验证恢复的 SSH 访问变更" \
        "commands/security/access.sh" \
        "disruptive" \
        "optional-root" \
        "supported" \
        "linux,init:systemd" \
        "experimental"

    vps_registry_register_command \
        "security" \
        "fail2ban" \
        "Fail2ban 防护" \
        "安装、配置和管理 OpenSSH 的 Fail2ban 防护" \
        "commands/security/fail2ban.sh" \
        "disruptive" \
        "optional-root" \
        "supported" \
        "linux,init:systemd" \
        "experimental"

    vps_registry_register_command \
        "security" \
        "tls" \
        "TLS 证书" \
        "管理域名 TLS 证书：导入、申请与自动续期" \
        "commands/security/tls.sh" \
        "disruptive" \
        "optional-root" \
        "supported" \
        "linux" \
        "experimental"

    vps_registry_register_command \
        "service" \
        "proxy" \
        "代理管理" \
        "平级管理 Xray 与 sing-box 内核、节点、日志和时间同步" \
        "commands/service/proxy.sh" \
        "disruptive" \
        "optional-root" \
        "supported" \
        "linux,service:any" \
        "experimental"

    vps_registry_register_command \
        "test" \
        "nodequality" \
        "NodeQuality 综合测试" \
        "运行 NodeQuality 服务器综合质量测试" \
        "commands/test/nodequality.sh" \
        "disruptive" \
        "root" \
        "unsupported" \
        "linux,root" \
        "experimental"

    vps_registry_register_command \
        "test" \
        "tcpquality" \
        "TcpQuality 网络测试" \
        "运行 TcpQuality TCP 网络质量测试" \
        "commands/test/tcpquality.sh" \
        "disruptive" \
        "root" \
        "unsupported" \
        "linux,root" \
        "experimental"

    vps_registry_register_command \
        "self" \
        "status" \
        "分发状态" \
        "显示本地分发版本、缓存领域和受管路径（不访问网络）" \
        "commands/self/status.sh" \
        "read-only" \
        "user" \
        "not-applicable" \
        "none" \
        "stable"

    vps_registry_register_command \
        "self" \
        "update" \
        "更新脚本" \
        "从官方 GitHub Release 验证并原子切换到新分发版本" \
        "commands/self/update.sh" \
        "change" \
        "optional-root" \
        "unsupported" \
        "none" \
        "stable"

    vps_registry_register_command \
        "self" \
        "uninstall" \
        "卸载脚本" \
        "删除受管入口和 release；可选清除脚本自身状态" \
        "commands/self/uninstall.sh" \
        "destructive" \
        "optional-root" \
        "unsupported" \
        "none" \
        "stable"
}

vps_registry_distribution_domain() {
    case "${1:-}" in
        self) printf 'core' ;;
        network | system | security | service | test) printf '%s' "$1" ;;
        *) return 2 ;;
    esac
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
