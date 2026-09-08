#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

UFW_CLI_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly UFW_CLI_PROJECT_ROOT
# shellcheck source=../../lib/command.sh
source "$UFW_CLI_PROJECT_ROOT/lib/command.sh"
for UFW_CLI_MODULE in lib/ufw.sh commands/network/ufw/common.sh commands/network/ufw/inventory.sh \
    commands/network/ufw/rules.sh commands/network/ufw/actions.sh commands/network/ufw/menu.sh; do
    UFW_CLI_MODULE="$UFW_CLI_PROJECT_ROOT/$UFW_CLI_MODULE"
    vps_cmd_require_no_symlink_components "$UFW_CLI_MODULE" || exit $?
    [[ -f "$UFW_CLI_MODULE" && -r "$UFW_CLI_MODULE" ]] || {
        vps_cmd_error "UFW 模块缺失或不可读：$UFW_CLI_MODULE"
        exit 3
    }
done
unset UFW_CLI_MODULE
# shellcheck source=../../lib/ufw.sh
source "$UFW_CLI_PROJECT_ROOT/lib/ufw.sh"
# shellcheck source=ufw/common.sh
source "$UFW_CLI_PROJECT_ROOT/commands/network/ufw/common.sh"
# shellcheck source=ufw/inventory.sh
source "$UFW_CLI_PROJECT_ROOT/commands/network/ufw/inventory.sh"
# shellcheck source=ufw/rules.sh
source "$UFW_CLI_PROJECT_ROOT/commands/network/ufw/rules.sh"
# shellcheck source=ufw/actions.sh
source "$UFW_CLI_PROJECT_ROOT/commands/network/ufw/actions.sh"
# shellcheck source=ufw/menu.sh
source "$UFW_CLI_PROJECT_ROOT/commands/network/ufw/menu.sh"

ufw_cli_usage() {
    cat <<'EOF'
管理 UFW 防火墙、规则和现有服务的端口联动。

用法：vpsctl network ufw [global-options] ACTION
  status [--json]
  install                         安装但不主动启用；保留已有策略
  enable | disable | reload
  reset [--confirm-reset]         重置规则并停用，保留业务联动需求
  uninstall [--purge] [--confirm-purge]
  sync                            采集现有 SSH/代理需求并清理过期引用
  rule list [--json]
  rule add RULE-OPTIONS
  rule edit (--id ID | --number N) RULE-OPTIONS
  rule delete (--id ID | --number N)
  link list [--json]
  link detach OWNER | link attach OWNER
  default incoming|outgoing|routed allow|deny|reject
  ipv6 on|off
  logging on|off|low|medium|high|full
  app list | app info NAME | app default allow|deny|reject|skip
  app update NAME [--add-new] | app update all

规则选项（edit 未指定字段保留，规则顺序不变）：
  --action allow|deny|reject|limit  --direction in|out|route
  --proto PROTOCOL                 --port PORT[,PORT]|START:END
  --source IP|CIDR|any              --destination IP|CIDR|any
  --source-port PORTS              --family ipv4|ipv6|both
  --in-interface NAME             --out-interface NAME
  --position NUMBER（仅 add）      --comment TEXT
  --app NAME（替代端口/协议）      --log log|log-all
默认规则为 allow in tcp；协议及组合由本机 UFW 校验。

服务引用规则默认禁止修改/删除。请先 link list，再 link detach OWNER；
解除状态会跨 sync 和服务重启保持，attach 后恢复同步。
install 不启用 UFW；enable 先放行现有 SSH 和业务规则，成功后再启用。
停用时普通 sync 只记录需求。存在未完成 SSH 事务时全局操作会拒绝执行。
uninstall 停用并保留配置/联动状态；--purge 备份后清理两者。
交互 reset/purge 必须输入 RESET-UFW/PURGE-UFW；非交互必须显式
--confirm-reset/--confirm-purge，--yes 不能代替。

全局选项（动作之前）：
  --install-deps --dry-run --yes --non-interactive --quiet --verbose --no-color --
终端无参数进入主菜单；非交互无参数显示状态。
EOF
}

ufw_cli_parse_json() {
    UFW_CLI_JSON=0
    case "$#:${1:-}" in 0:) ;; 1:--json) UFW_CLI_JSON=1 ;; *)
        vps_cmd_error '此动作仅接受 --json'
        return 2
        ;;
    esac
}

ufw_cli_dispatch() {
    local action="${1:-status}" operation purge=0 confirmed=0 direction policy name add_new=0 saved_deps
    (($# == 0)) || shift
    case "$action" in
        help | -h | --help)
            (($# == 0)) || return 2
            ufw_cli_usage
            ;;
        status)
            ufw_cli_parse_json "$@" || return $?
            ufw_cli_status "$UFW_CLI_JSON"
            ;;
        install)
            (($# == 0)) || return 2
            saved_deps="${VPSCTL_INSTALL_DEPS:-0}"
            VPSCTL_INSTALL_DEPS=1
            local status=0
            ufw_cli_change 1 1 ufw_cli_install_locked || status=$?
            VPSCTL_INSTALL_DEPS="$saved_deps"
            return "$status"
            ;;
        enable | disable | reload | sync)
            (($# == 0)) || return 2
            if [[ "$action" == sync ]]; then
                ufw_cli_change 1 1 ufw_cli_sync_locked auto
            else ufw_cli_change 1 1 "ufw_cli_${action}_locked"; fi
            ;;
        reset)
            case "$#:${1:-}" in 0:) ;; 1:--confirm-reset) confirmed=1 ;; *) return 2 ;; esac
            ufw_cli_strong_confirm "$confirmed" RESET-UFW '重置 UFW 手工规则和默认策略' || return $?
            ufw_cli_change 1 1 ufw_cli_reset_locked
            ;;
        uninstall)
            while (($#)); do
                case "$1" in --purge)
                    [[ "$purge" == 0 ]] || return 2
                    purge=1
                    ;;
                --confirm-purge)
                    [[ "$confirmed" == 0 ]] || return 2
                    confirmed=1
                    ;;
                *) return 2 ;; esac
                shift
            done
            [[ "$confirmed" == 0 || "$purge" == 1 ]] || return 2
            if [[ "$purge" == 1 ]]; then ufw_cli_strong_confirm "$confirmed" PURGE-UFW '清理 UFW 配置和联动状态（先备份）' || return $?; fi
            ufw_cli_change 1 1 ufw_cli_uninstall_locked "$purge"
            ;;
        rule)
            operation="${1:-}"
            (($# == 0)) || shift
            case "$operation" in
                list)
                    ufw_cli_parse_json "$@" || return $?
                    ufw_cli_rule_list "$UFW_CLI_JSON"
                    ;;
                add | edit | delete)
                    ufw_cli_rule_parse "$operation" "$@" || return $?
                    if [[ "$operation" == add ]]; then ufw_cli_rule_validate || return $?; fi
                    ufw_cli_change 0 0 ufw_cli_rule_apply_locked
                    ;;
                *)
                    vps_cmd_error 'rule 需要 list、add、edit 或 delete'
                    return 2
                    ;;
            esac
            ;;
        link)
            operation="${1:-}"
            (($# == 0)) || shift
            case "$operation" in
                list)
                    ufw_cli_parse_json "$@" || return $?
                    ufw_cli_links_list "$UFW_CLI_JSON"
                    ;;
                detach | attach)
                    (($# == 1)) && [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || return 2
                    ufw_cli_change 1 1 ufw_cli_link_locked "$operation" "$1"
                    ;;
                *) return 2 ;;
            esac
            ;;
        default)
            if (($# == 4)) && [[ "$1" == --direction && "$3" == --policy ]]; then
                direction="$2"
                policy="$4"
            elif (($# == 2)); then
                direction="$1"
                policy="$2"
            else return 2; fi
            case "$direction" in incoming | outgoing | routed) ;; *) return 2 ;; esac
            case "$policy" in allow | deny | reject) ;; *) return 2 ;; esac
            ufw_cli_change 1 1 ufw_cli_default_locked "$direction" "$policy"
            ;;
        logging)
            (($# == 1)) || return 2
            case "$1" in on | off | low | medium | high | full) ;; *) return 2 ;; esac
            ufw_cli_change 0 0 ufw_cli_logging_locked "$1"
            ;;
        ipv6)
            (($# == 1)) && [[ "$1" == on || "$1" == off ]] || return 2
            ufw_cli_change 1 1 ufw_cli_ipv6_locked "$1"
            ;;
        app)
            operation="${1:-}"
            (($# == 0)) || shift
            case "$operation" in
                list)
                    (($# == 0)) || return 2
                    ufw_cli_require_installed || return $?
                    LC_ALL=C ufw app list
                    ;;
                info)
                    (($# == 1)) && [[ -n "$1" && "$1" != -* && "$1" != *$'\n'* ]] || return 2
                    ufw_cli_require_installed || return $?
                    LC_ALL=C ufw app info "$1"
                    ;;
                default)
                    (($# == 1)) || return 2
                    case "$1" in allow | deny | reject | skip) ;; *) return 2 ;; esac
                    ufw_cli_change 0 0 ufw_cli_app_locked default "$1"
                    ;;
                update)
                    name=''
                    while (($#)); do
                        if [[ "$1" == --add-new ]]; then
                            [[ "$add_new" == 0 ]] || return 2
                            add_new=1
                        elif [[ -z "$name" && -n "$1" && "$1" != -* && "$1" != *$'\n'* ]]; then
                            name="$1"
                        else return 2; fi
                        shift
                    done
                    [[ -n "$name" ]] || return 2
                    [[ "$name" != all || "$add_new" == 0 ]] || {
                        vps_cmd_error 'app update all 不能与 --add-new 同用'
                        return 2
                    }
                    if [[ "$add_new" == 1 ]]; then
                        ufw_cli_change 1 1 ufw_cli_app_locked update --add-new "$name"
                    else ufw_cli_change 1 1 ufw_cli_app_locked update "$name"; fi
                    ;;
                *) return 2 ;;
            esac
            ;;
        *)
            vps_cmd_error "未知 UFW 动作：$action"
            return 2
            ;;
    esac
}

ufw_cli_main() {
    vps_cmd_init network-ufw "$UFW_CLI_PROJECT_ROOT" || return $?
    ufw_cli_parse_globals "$@"
    vps_ufw_init || return $?
    UFW_CLI_INTERACTIVE=0
    if vps_cmd_is_interactive; then UFW_CLI_INTERACTIVE=1; fi
    if ((${#UFW_CLI_ARGS[@]} == 0)) && [[ "$UFW_CLI_INTERACTIVE" == 1 ]]; then
        ufw_cli_menu
    else
        ufw_cli_dispatch "${UFW_CLI_ARGS[@]}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then ufw_cli_main "$@"; fi
