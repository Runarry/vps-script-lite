#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'
umask 022
NFT_CLI_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly NFT_CLI_PROJECT_ROOT
# shellcheck source=../../lib/command.sh
source "$NFT_CLI_PROJECT_ROOT/lib/command.sh"
for NFT_CLI_MODULE in lib/nftables.sh commands/network/nftables/common.sh \
    commands/network/nftables/inventory.sh commands/network/nftables/rules.sh \
    commands/network/nftables/actions.sh commands/network/nftables/menu.sh commands/network/nftables/legacy.sh; do
    vps_cmd_require_no_symlink_components "$NFT_CLI_PROJECT_ROOT/$NFT_CLI_MODULE" || exit $?
    [[ -r "$NFT_CLI_PROJECT_ROOT/$NFT_CLI_MODULE" ]] || {
        vps_cmd_error "模块缺失：$NFT_CLI_MODULE"
        exit 3
    }
    # shellcheck disable=SC1090
    source "$NFT_CLI_PROJECT_ROOT/$NFT_CLI_MODULE"
done
unset NFT_CLI_MODULE

nft_cli_usage() {
    cat <<'EOF'
管理 nftables 防火墙和服务端口联动。
用法：vpsctl network nftables [global-options] ACTION
  status [--json]                 状态（含版本、规则和服务联动）
  install                        安装专用运行时，新安装保持停用
  enable | disable | reload | sync
  rule list [--json]
  rule add [--id ID] RULE-OPTIONS
  rule edit --id ID RULE-OPTIONS
  rule delete --id ID
  limit list [--json]
  limit set [--id ID] LIMIT-OPTIONS
  limit delete --id ID
  link list [--json] | link attach OWNER | link detach OWNER
  logging on|off
  stats [--json]
  restore BACKUP-DIRECTORY
  uninstall                      移除专用服务，保留规则和联动记录

规则选项（edit 未指定字段保持不变）：
  --action allow|deny|allow-only   --proto tcp|udp|both|any
  --port any|PORT[,PORT]|START-END --source any|IP[,IP]|CIDR[,CIDR]
  --family both|ipv4|ipv6          --service OWNER --comment TEXT
  --ttl SECONDS|Nm|Nh|Nd           保存为绝对到期时间；0 表示永久
allow-only 成员过期后，拒绝其他来源的边界仍保留。
限速选项：--proto tcp|udp --port PORTS --source SOURCES --family FAMILY
  --service OWNER --rate N/second|N/minute|N/hour --burst N --connections N
TCP 限制新连接，UDP 限制数据包；连接数仅用于 TCP。0 清除连接数限制。
install 不主动启用，重复安装保留启用状态；enable 自动采集 SSH、代理、TCPing 和 iperf3 端口，保留 TLS 租约。
成功启用后退役旧 UFW/RFW；不导入旧手工规则。disable/uninstall 不删除代理 NAT。
所有变更保留 root 专用恢复快照。SSH 事务未完成时拒绝全局变更。
全局选项（动作之前）：--install-deps --dry-run --yes --non-interactive
  --quiet --verbose --no-color --
终端无参数进入菜单，非交互无参数显示状态。
EOF
}

nft_cli_parse_json() {
    NFT_CLI_JSON=0
    case "$#:${1:-}" in 0:) ;; 1:--json) NFT_CLI_JSON=1 ;; *) return 2 ;; esac
}

nft_cli_dispatch() {
    local action="${1:-status}" operation saved status=0
    (($# == 0)) || shift
    case "$action" in
        help | -h | --help)
            (($# == 0)) || return 2
            nft_cli_usage
            ;;
        status | stats)
            nft_cli_parse_json "$@" || return $?
            "nft_cli_$action" "$NFT_CLI_JSON"
            ;;
        install)
            (($# == 0)) || return 2
            saved="${VPSCTL_INSTALL_DEPS:-0}"
            VPSCTL_INSTALL_DEPS=1
            nft_cli_change 1 nft_cli_install_locked || status=$?
            VPSCTL_INSTALL_DEPS="$saved"
            return "$status"
            ;;
        enable | disable | reload | sync | uninstall)
            (($# == 0)) || return 2
            nft_cli_change 1 "nft_cli_${action}_locked"
            ;;
        rule | limit)
            operation="${1:-}"
            (($# == 0)) || shift
            case "$action:$operation" in
                rule:list | limit:list)
                    nft_cli_parse_json "$@" || return $?
                    nft_cli_list "$action" "$NFT_CLI_JSON"
                    ;;
                rule:add | rule:edit | rule:delete | limit:set | limit:delete)
                    nft_cli_rule_parse "$action" "$operation" "$@" || return $?
                    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
                    nft_cli_change 0 nft_cli_rule_apply_locked
                    ;;
                *) return 2 ;;
            esac
            ;;
        link)
            operation="${1:-}"
            (($# == 0)) || shift
            case "$operation" in
                list)
                    nft_cli_parse_json "$@" || return $?
                    nft_cli_links_list "$NFT_CLI_JSON"
                    ;;
                attach | detach)
                    (($# == 1)) && [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || return 2
                    nft_cli_change 1 nft_cli_link_locked "$operation" "$1"
                    ;;
                *) return 2 ;;
            esac
            ;;
        logging)
            (($# == 1)) && [[ "$1" == on || "$1" == off ]] || return 2
            nft_cli_change 0 nft_cli_logging_locked "$1"
            ;;
        restore)
            (($# == 1)) || return 2
            vps_cmd_require_no_symlink_components "$1" || return $?
            nft_cli_change 1 nft_cli_restore_locked "$1"
            ;;
        *)
            vps_cmd_error "未知 nftables 动作：$action"
            return 2
            ;;
    esac
}

nft_cli_main() {
    vps_cmd_init network-nftables "$NFT_CLI_PROJECT_ROOT" || return $?
    nft_cli_parse_globals "$@"
    vps_nft_init || return $?
    if ((${#NFT_CLI_ARGS[@]} == 0)) && vps_cmd_is_interactive; then
        nft_cli_menu
    else nft_cli_dispatch "${NFT_CLI_ARGS[@]}"; fi
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then nft_cli_main "$@"; fi
