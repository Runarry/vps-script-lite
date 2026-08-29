#!/usr/bin/env bash
# Global CLI flags are consumed by the sourced command helper library.
# shellcheck disable=SC2034

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

ACCESS_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly ACCESS_PROJECT_ROOT

# shellcheck source=../../lib/command.sh
source "${ACCESS_PROJECT_ROOT}/lib/command.sh"
# shellcheck source=access/common.sh
source "${ACCESS_PROJECT_ROOT}/commands/security/access/common.sh"
# shellcheck source=access/users.sh
source "${ACCESS_PROJECT_ROOT}/commands/security/access/users.sh"
# shellcheck source=access/keys.sh
source "${ACCESS_PROJECT_ROOT}/commands/security/access/keys.sh"
# shellcheck source=access/firewall.sh
source "${ACCESS_PROJECT_ROOT}/commands/security/access/firewall.sh"
# shellcheck source=access/sshd.sh
source "${ACCESS_PROJECT_ROOT}/commands/security/access/sshd.sh"

ACCESS_ARGS=()

access_usage() {
    cat <<'EOF'
安全管理 Linux 用户、SSH 密钥与可回滚的 sshd 访问策略。

用法：
  access.sh [global-options] status [--user USER] [--json]
  access.sh [global-options] user add --name USER [--set-password]
  access.sh [global-options] password set --user USER
  access.sh [global-options] key add --user USER (--stdin|--public-key-file FILE)
  access.sh [global-options] key generate --user USER
  access.sh [global-options] ssh prepare [--port PORT] [--root-login allow|deny]
      [--password-login allow|deny] [--fallback-user USER]
      [--firewall auto|manual]
  access.sh [global-options] session verify --transaction ID
  access.sh [global-options] ssh commit --transaction ID --confirm-apply ID
  access.sh [global-options] ssh abort --transaction ID
  access.sh [global-options] restore --backup ID

全局选项：
  --dry-run            展示写操作计划，不修改系统
  --install-deps       明确允许安装依赖（本命令通常依赖 OpenSSH/systemd）
  --yes                跳过允许自动确认的普通提示
  --non-interactive    禁止交互读取；passwd/key generate 仍要求 TTY
  --quiet              隐藏非必要信息
  --verbose            显示诊断信息（不会显示密码或私钥）
  --no-color           禁用彩色输出
  --                    停止解析全局选项
  -h, --help           显示帮助

安全事务：
  prepare 先验证标准 sshd_config，创建受管 drop-in，并在端口变更时让旧、新
  端口并行监听。必须在 15 分钟内从新端口建立第二个非 root SSH 会话，运行
  session verify，再以事务 ID 显式 commit；否则 systemd 定时任务自动 abort。
  密码登录将被禁用时，证明会话必须使用 publickey。复杂 Include、Match、
  多端口或条件访问配置会被拒绝，不会猜测合并。

防火墙：
  auto 适配单一活动 UFW、firewalld、持久化 nftables 或持久化 iptables。
  原生 nftables/iptables 无可靠持久化时拒绝自动修改；manual 不改防火墙。

权限：
  status 与 session verify 可由非 root 执行；其他写操作需要 root。
EOF
}

access_parse_globals() {
    ACCESS_ARGS=()
    while (($# > 0)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --install-deps) VPSCTL_INSTALL_DEPS=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --no-color) VPSCTL_NO_COLOR=1 ;;
            --)
                shift
                ACCESS_ARGS=("$@")
                return 0
                ;;
            *)
                ACCESS_ARGS=("$@")
                return 0
                ;;
        esac
        shift
    done
}

access_status_user_fields() {
    local user="$1" entry uid home shell authorized key_count=unknown

    entry="$(getent passwd "$user" 2>/dev/null || true)"
    if [[ -z "$entry" ]]; then
        ACCESS_STATUS_USER_EXISTS=false
        ACCESS_STATUS_USER_UID=''
        ACCESS_STATUS_USER_HOME=''
        ACCESS_STATUS_USER_SHELL=''
        ACCESS_STATUS_USER_KEYS=0
        return 0
    fi
    ACCESS_STATUS_USER_EXISTS=true
    uid="$(access_user_field "$user" uid 2>/dev/null || true)"
    home="$(access_user_field "$user" home 2>/dev/null || true)"
    shell="$(access_user_field "$user" shell 2>/dev/null || true)"
    authorized="$(access_key_authorized_path "$user" 2>/dev/null || true)"
    if [[ -n "$authorized" && -r "$authorized" && -f "$authorized" && ! -L "$authorized" ]]; then
        key_count="$(awk '/^[[:space:]]*(ssh-|ecdsa-|sk-)/ {count++} END {print count+0}' "$authorized")"
    fi
    ACCESS_STATUS_USER_UID="$uid"
    ACCESS_STATUS_USER_HOME="$home"
    ACCESS_STATUS_USER_SHELL="$shell"
    ACCESS_STATUS_USER_KEYS="$key_count"
}

access_status() {
    local user="$1" json="$2" port=unknown root_login=unknown password_login=unknown pubkey=unknown managed=false
    local active='' tx_status='' expires='' service_state=unknown strict=invalid listening=false
    local firewall_backend=unknown firewall_port_rule=null firewall_managed=false

    if access_sshd_validate_standard >/dev/null 2>&1; then
        strict=standard
        port="$(access_sshd_current_port 2>/dev/null || printf unknown)"
        root_login="$(access_sshd_effective_value permitrootlogin 2>/dev/null || printf unknown)"
        password_login="$(access_sshd_effective_value passwordauthentication 2>/dev/null || printf unknown)"
        pubkey="$(access_sshd_effective_value pubkeyauthentication 2>/dev/null || printf unknown)"
    fi
    systemctl is-active --quiet "$ACCESS_SSH_SERVICE" >/dev/null 2>&1 && service_state=active || service_state=inactive
    if access_validate_port "$port" && access_sshd_port_listening "$port"; then
        listening=true
    fi
    firewall_backend="$(access_firewall_detect 2>/dev/null || printf conflict)"
    if [[ "$firewall_backend" != none && "$firewall_backend" != conflict ]]; then
        access_firewall_has_port "$firewall_backend" "$port" && firewall_port_rule=true || firewall_port_rule=false
    fi
    access_firewall_load_managed
    [[ -n "$ACCESS_FW_PREVIOUS_BACKEND" && "$ACCESS_FW_PREVIOUS_OWNED" == 1 ]] && firewall_managed=true
    [[ -f "$ACCESS_CONFIG" && ! -L "$ACCESS_CONFIG" ]] && grep -Fqx "$ACCESS_MANAGED_MARKER" "$ACCESS_CONFIG" && managed=true
    active="$(access_active_transaction 2>/dev/null || true)"
    if [[ -n "$active" ]]; then
        tx_status="$(access_kv_get "$ACCESS_TRANSACTION_DIR/$active/state" status 2>/dev/null || printf invalid)"
        expires="$(access_kv_get "$ACCESS_TRANSACTION_DIR/$active/state" expires_epoch 2>/dev/null || true)"
        [[ "$expires" =~ ^[0-9]+$ ]] || expires=0
    fi
    if [[ -n "$user" ]]; then access_status_user_fields "$user"; fi
    if [[ "$json" == 1 ]]; then
        printf '{\n'
        printf '  "schema_version": 1,\n'
        printf '  "platform": "systemd",\n'
        printf '  "sshd": {"service": "%s", "service_state": "%s", "config_shape": "%s", "port": "%s", "listening": %s, "permit_root_login": "%s", "password_authentication": "%s", "pubkey_authentication": "%s", "managed": %s},\n' \
            "$(access_json_escape "$ACCESS_SSH_SERVICE")" "$service_state" "$strict" "$port" "$listening" "$root_login" "$password_login" "$pubkey" "$managed"
        printf '  "firewall": {"backend": "%s", "port_rule_present": %s, "managed": %s},\n' \
            "$(access_json_escape "$firewall_backend")" "$firewall_port_rule" "$firewall_managed"
        if [[ -n "$active" ]]; then
            printf '  "transaction": {"id": "%s", "status": "%s", "expires_epoch": %s},\n' "$active" "$tx_status" "${expires:-0}"
        else
            printf '  "transaction": null,\n'
        fi
        if [[ -n "$user" ]]; then
            printf '  "user": {"name": "%s", "exists": %s, "uid": "%s", "home": "%s", "shell": "%s", "authorized_key_count": "%s"}\n' \
                "$(access_json_escape "$user")" "$ACCESS_STATUS_USER_EXISTS" "$(access_json_escape "$ACCESS_STATUS_USER_UID")" \
                "$(access_json_escape "$ACCESS_STATUS_USER_HOME")" "$(access_json_escape "$ACCESS_STATUS_USER_SHELL")" "$(access_json_escape "$ACCESS_STATUS_USER_KEYS")"
        else
            printf '  "user": null\n'
        fi
        printf '}\n'
        return 0
    fi
    vps_cmd_status "SSH 服务" "$ACCESS_SSH_SERVICE ($service_state)" "$([[ "$service_state" == active ]] && printf success || printf error)"
    vps_cmd_status "配置结构" "$strict" "$([[ "$strict" == standard ]] && printf success || printf warning)"
    vps_cmd_status "监听端口" "$port" emphasis
    vps_cmd_status "端口监听" "$listening" "$([[ "$listening" == true ]] && printf success || printf error)"
    vps_cmd_status "root 登录" "$root_login" info
    vps_cmd_status "密码认证" "$password_login" info
    vps_cmd_status "公钥认证" "$pubkey" "$([[ "$pubkey" == yes ]] && printf success || printf warning)"
    vps_cmd_status "vpsctl 受管" "$managed" info
    vps_cmd_status "防火墙" "$firewall_backend (port_rule_present=$firewall_port_rule, managed=$firewall_managed)" info
    vps_cmd_status "活动事务" "${active:-无}${tx_status:+ ($tx_status, expires $expires)}" "$([[ -z "$active" ]] && printf info || printf warning)"
    if [[ -n "$user" ]]; then
        vps_cmd_status "用户" "$user (exists=$ACCESS_STATUS_USER_EXISTS, uid=${ACCESS_STATUS_USER_UID:-无})" info
        vps_cmd_status "主目录" "${ACCESS_STATUS_USER_HOME:-无}" info
        vps_cmd_status "登录 shell" "${ACCESS_STATUS_USER_SHELL:-无}" info
        vps_cmd_status "authorized_keys" "$ACCESS_STATUS_USER_KEYS" info
    fi
}

access_parse_required_value() {
    (($# >= 2)) || {
        vps_cmd_error "$1 缺少参数值"
        return 2
    }
}

access_dispatch_status() {
    local user='' json=0
    while (($# > 0)); do
        case "$1" in
            --user)
                access_parse_required_value "$@" || return $?
                [[ -z "$user" ]] || {
                    vps_cmd_error "重复指定 --user"
                    return 2
                }
                user="$2"
                shift
                ;;
            --json)
                ((json == 0)) || {
                    vps_cmd_error "重复指定 --json"
                    return 2
                }
                json=1
                ;;
            *)
                vps_cmd_error "未知 status 选项：$1"
                return 2
                ;;
        esac
        shift
    done
    [[ -z "$user" ]] || access_validate_user_name "$user" || {
        vps_cmd_error "无效用户名：$user"
        return 2
    }
    access_status "$user" "$json"
}

access_dispatch_user() {
    local action="${1:-}" user='' set_password=0
    [[ "$action" == add ]] || {
        vps_cmd_error "user 需要 add"
        return 2
    }
    shift
    while (($# > 0)); do
        case "$1" in
            --name)
                access_parse_required_value "$@" || return $?
                [[ -z "$user" ]] || {
                    vps_cmd_error "重复指定 --name"
                    return 2
                }
                user="$2"
                shift
                ;;
            --set-password)
                ((set_password == 0)) || {
                    vps_cmd_error "重复指定 --set-password"
                    return 2
                }
                set_password=1
                ;;
            *)
                vps_cmd_error "未知 user add 选项：$1"
                return 2
                ;;
        esac
        shift
    done
    [[ -n "$user" ]] || {
        vps_cmd_error "user add 需要 --name"
        return 2
    }
    access_user_add "$user" "$set_password"
}

access_dispatch_password() {
    local action="${1:-}" user=''
    [[ "$action" == set ]] || {
        vps_cmd_error "password 需要 set"
        return 2
    }
    shift
    while (($# > 0)); do
        case "$1" in
            --user)
                access_parse_required_value "$@" || return $?
                [[ -z "$user" ]] || {
                    vps_cmd_error "重复指定 --user"
                    return 2
                }
                user="$2"
                shift
                ;;
            *)
                vps_cmd_error "未知 password set 选项：$1"
                return 2
                ;;
        esac
        shift
    done
    [[ -n "$user" ]] || {
        vps_cmd_error "password set 需要 --user"
        return 2
    }
    access_password_set "$user"
}

access_dispatch_key() {
    local action="${1:-}" user='' source_kind='' source_value=''
    case "$action" in add | generate) ;; *)
        vps_cmd_error "key 需要 add|generate"
        return 2
        ;;
    esac
    shift
    while (($# > 0)); do
        case "$1" in
            --user)
                access_parse_required_value "$@" || return $?
                [[ -z "$user" ]] || {
                    vps_cmd_error "重复指定 --user"
                    return 2
                }
                user="$2"
                shift
                ;;
            --stdin)
                [[ "$action" == add && -z "$source_kind" ]] || {
                    vps_cmd_error "--stdin 与其他来源互斥且仅用于 key add"
                    return 2
                }
                source_kind=stdin
                ;;
            --public-key-file)
                access_parse_required_value "$@" || return $?
                [[ "$action" == add && -z "$source_kind" ]] || {
                    vps_cmd_error "--public-key-file 与其他来源互斥且仅用于 key add"
                    return 2
                }
                source_kind='file'
                source_value="$2"
                shift
                ;;
            *)
                vps_cmd_error "未知 key $action 选项：$1"
                return 2
                ;;
        esac
        shift
    done
    [[ -n "$user" ]] || {
        vps_cmd_error "key $action 需要 --user"
        return 2
    }
    if [[ "$action" == add ]]; then
        [[ -n "$source_kind" ]] || {
            vps_cmd_error "key add 需要 --stdin 或 --public-key-file"
            return 2
        }
        access_key_add "$user" "$source_kind" "$source_value"
    else
        [[ -z "$source_kind" ]] || return 2
        access_key_generate "$user"
    fi
}

access_dispatch_ssh() {
    local action="${1:-}" port='' root_login='' password_login='' fallback='' firewall='' firewall_set=0 specified=0 tx_id='' confirm=''
    case "$action" in prepare | commit | abort) ;; *)
        vps_cmd_error "ssh 需要 prepare|commit|abort"
        return 2
        ;;
    esac
    shift
    if [[ "$action" == prepare ]]; then
        while (($# > 0)); do
            case "$1" in
                --port)
                    access_parse_required_value "$@" || return $?
                    [[ -z "$port" ]] || {
                        vps_cmd_error "重复指定 --port"
                        return 2
                    }
                    port="$2"
                    specified=$((specified + 1))
                    shift
                    ;;
                --root-login)
                    access_parse_required_value "$@" || return $?
                    [[ -z "$root_login" ]] || {
                        vps_cmd_error "重复指定 --root-login"
                        return 2
                    }
                    root_login="$2"
                    specified=$((specified + 1))
                    shift
                    ;;
                --password-login)
                    access_parse_required_value "$@" || return $?
                    [[ -z "$password_login" ]] || {
                        vps_cmd_error "重复指定 --password-login"
                        return 2
                    }
                    password_login="$2"
                    specified=$((specified + 1))
                    shift
                    ;;
                --fallback-user)
                    access_parse_required_value "$@" || return $?
                    [[ -z "$fallback" ]] || {
                        vps_cmd_error "重复指定 --fallback-user"
                        return 2
                    }
                    fallback="$2"
                    shift
                    ;;
                --firewall)
                    access_parse_required_value "$@" || return $?
                    ((firewall_set == 0)) || {
                        vps_cmd_error "重复指定 --firewall"
                        return 2
                    }
                    firewall="$2"
                    firewall_set=1
                    shift
                    ;;
                *)
                    vps_cmd_error "未知 ssh prepare 选项：$1"
                    return 2
                    ;;
            esac
            shift
        done
        ((specified > 0)) || {
            vps_cmd_error "ssh prepare 至少需要一个策略选项"
            return 2
        }
        [[ -z "$port" ]] || access_validate_port "$port" || {
            vps_cmd_error "无效端口：$port"
            return 2
        }
        [[ -z "$root_login" || "$root_login" == allow || "$root_login" == deny ]] || {
            vps_cmd_error "--root-login 仅接受 allow|deny"
            return 2
        }
        [[ -z "$password_login" || "$password_login" == allow || "$password_login" == deny ]] || {
            vps_cmd_error "--password-login 仅接受 allow|deny"
            return 2
        }
        [[ -z "$firewall" || "$firewall" == auto || "$firewall" == manual ]] || {
            vps_cmd_error "--firewall 仅接受 auto|manual"
            return 2
        }
        if [[ -n "$port" && -z "$firewall" ]]; then
            if vps_cmd_is_interactive; then
                firewall="$(vps_cmd_prompt_select "端口变更的防火墙处理" auto auto "自动适配单一活动后端" manual "手动管理")" || return $?
            else
                vps_cmd_error "非交互端口变更必须显式指定 --firewall auto|manual"
                return 2
            fi
        fi
        [[ -n "$firewall" ]] || firewall=manual
        access_ssh_prepare "$port" "$root_login" "$password_login" "$fallback" "$firewall"
        return
    fi
    while (($# > 0)); do
        case "$1" in
            --transaction)
                access_parse_required_value "$@" || return $?
                [[ -z "$tx_id" ]] || {
                    vps_cmd_error "重复指定 --transaction"
                    return 2
                }
                tx_id="$2"
                shift
                ;;
            --confirm-apply)
                [[ "$action" == commit ]] || {
                    vps_cmd_error "--confirm-apply 仅用于 commit"
                    return 2
                }
                access_parse_required_value "$@" || return $?
                [[ -z "$confirm" ]] || {
                    vps_cmd_error "重复指定 --confirm-apply"
                    return 2
                }
                confirm="$2"
                shift
                ;;
            *)
                vps_cmd_error "未知 ssh $action 选项：$1"
                return 2
                ;;
        esac
        shift
    done
    [[ -n "$tx_id" ]] || {
        vps_cmd_error "ssh $action 需要 --transaction"
        return 2
    }
    if [[ "$action" == commit ]]; then
        [[ -n "$confirm" ]] || {
            vps_cmd_error "ssh commit 需要 --confirm-apply ID"
            return 2
        }
        access_ssh_commit "$tx_id" "$confirm"
    else
        [[ -z "$confirm" ]] || return 2
        access_ssh_abort "$tx_id"
    fi
}

access_dispatch_session() {
    local action="${1:-}" tx_id=''
    [[ "$action" == verify ]] || {
        vps_cmd_error "session 需要 verify"
        return 2
    }
    shift
    while (($# > 0)); do
        case "$1" in
            --transaction)
                access_parse_required_value "$@" || return $?
                [[ -z "$tx_id" ]] || {
                    vps_cmd_error "重复指定 --transaction"
                    return 2
                }
                tx_id="$2"
                shift
                ;;
            *)
                vps_cmd_error "未知 session verify 选项：$1"
                return 2
                ;;
        esac
        shift
    done
    [[ -n "$tx_id" ]] || {
        vps_cmd_error "session verify 需要 --transaction"
        return 2
    }
    access_session_verify "$tx_id"
}

access_dispatch_restore() {
    local backup_id=''
    while (($# > 0)); do
        case "$1" in
            --backup)
                access_parse_required_value "$@" || return $?
                [[ -z "$backup_id" ]] || {
                    vps_cmd_error "重复指定 --backup"
                    return 2
                }
                backup_id="$2"
                shift
                ;;
            *)
                vps_cmd_error "未知 restore 选项：$1"
                return 2
                ;;
        esac
        shift
    done
    [[ -n "$backup_id" ]] || {
        vps_cmd_error "restore 需要 --backup"
        return 2
    }
    access_restore "$backup_id"
}

access_restore() {
    local backup_id="$1" backup_dir manifest kind

    backup_dir="$(access_backup_path "$backup_id")" || return $?
    manifest="$backup_dir/manifest"
    [[ -f "$manifest" && ! -L "$manifest" ]] || {
        vps_cmd_error "备份不存在：$backup_id"
        return 3
    }
    kind="$(access_kv_get "$manifest" kind 2>/dev/null || true)"
    case "$kind" in
        ssh) access_ssh_restore "$backup_id" ;;
        authorized_keys) access_key_restore "$backup_id" ;;
        *)
            vps_cmd_error "未知或损坏的备份类型：${kind:-缺失}"
            return 30
            ;;
    esac
}

access_menu() {
    local choice action value user source port root_mode password_mode firewall tx backup rc status=0
    while true; do
        choice="$(vps_cmd_prompt_select "SSH 访问安全" status \
            status "查看状态" user "创建管理员用户" password "设置用户密码" \
            key "添加或生成 SSH 密钥" ssh "准备 SSH 访问变更" \
            transaction "提交或中止活动事务" restore "恢复已提交备份" quit "退出")" || {
            rc=$?
            [[ "$rc" == 130 ]] && return "$status"
            return "$rc"
        }
        case "$choice" in
            status) access_status '' 0 || status=$? ;;
            user)
                user="$(vps_cmd_prompt_value "新用户名" '')" || continue
                access_validate_user_name "$user" || {
                    vps_cmd_error "无效用户名"
                    continue
                }
                action="$(vps_cmd_prompt_select "初始密码" no no "暂不设置" yes "立即调用 passwd")" || continue
                access_user_add "$user" "$([[ "$action" == yes ]] && printf 1 || printf 0)" || status=$?
                ;;
            password)
                user="$(vps_cmd_prompt_value "用户名" '')" || continue
                access_validate_user_name "$user" || {
                    vps_cmd_error "无效用户名"
                    continue
                }
                access_password_set "$user" || status=$?
                ;;
            key)
                user="$(vps_cmd_prompt_value "用户名" '')" || continue
                access_validate_user_name "$user" || {
                    vps_cmd_error "无效用户名"
                    continue
                }
                action="$(vps_cmd_prompt_select "密钥操作" generate generate "生成一次性密钥" file "从公钥文件添加")" || continue
                if [[ "$action" == generate ]]; then
                    access_key_generate "$user" || status=$?
                else
                    source="$(vps_cmd_prompt_value "公钥文件绝对路径" '')" || continue
                    [[ "$source" == /* ]] || {
                        vps_cmd_error "必须使用绝对路径"
                        continue
                    }
                    access_key_add "$user" file "$source" || status=$?
                fi
                ;;
            ssh)
                action="$(vps_cmd_prompt_select "变更项目" port port "更改 SSH 端口" root "更改 root 登录" password "更改密码登录")" || continue
                port=''
                root_mode=''
                password_mode=''
                firewall=manual
                case "$action" in
                    port)
                        value="$(vps_cmd_prompt_value "新 SSH 端口" '')" || continue
                        access_validate_port "$value" || {
                            vps_cmd_error "无效端口"
                            continue
                        }
                        port="$value"
                        firewall="$(vps_cmd_prompt_select "防火墙处理" auto auto "自动" manual "手动")" || continue
                        ;;
                    root) root_mode="$(vps_cmd_prompt_select "root SSH 登录" deny deny "禁用" allow "允许")" || continue ;;
                    password) password_mode="$(vps_cmd_prompt_select "SSH 密码登录" deny deny "禁用" allow "允许")" || continue ;;
                esac
                user="$(vps_cmd_prompt_value "fallback 管理员用户（可留空）" '')" || continue
                [[ -z "$user" ]] || access_validate_user_name "$user" || {
                    vps_cmd_error "无效 fallback 用户"
                    continue
                }
                access_ssh_prepare "$port" "$root_mode" "$password_mode" "$user" "$firewall" || status=$?
                ;;
            transaction)
                tx="$(access_active_transaction 2>/dev/null || true)"
                [[ -n "$tx" ]] || {
                    vps_cmd_info "当前没有活动事务"
                    continue
                }
                action="$(vps_cmd_prompt_select "事务 $tx" abort abort "中止并回滚" commit "提交（需已有会话证明）")" || continue
                if [[ "$action" == commit ]]; then
                    vps_cmd_confirm_token "提交会关闭旧 SSH 端口" "$tx" || continue
                    access_ssh_commit "$tx" "$tx" || status=$?
                else
                    access_ssh_abort "$tx" || status=$?
                fi
                ;;
            restore)
                backup="$(vps_cmd_prompt_value "备份 ID" '')" || continue
                [[ "$backup" == bak-* ]] && access_validate_id "$backup" || {
                    vps_cmd_error "无效备份 ID"
                    continue
                }
                access_restore "$backup" || status=$?
                ;;
            quit) return "$status" ;;
        esac
    done
}

access_main() {
    local action init_status

    access_parse_globals "$@"
    if vps_cmd_init "security access" "$ACCESS_PROJECT_ROOT"; then :; else
        init_status=$?
        return "$init_status"
    fi
    access_common_init || return $?
    access_firewall_init || return $?
    access_sshd_init || return $?
    ACCESS_ENTRY_SCRIPT="${ACCESS_PROJECT_ROOT}/commands/security/access.sh"
    set -- "${ACCESS_ARGS[@]}"
    action="${1:-}"
    if [[ "$action" == help || "$action" == -h || "$action" == --help ]]; then
        (($# == 1)) || {
            vps_cmd_error "help 不接受额外参数"
            return 2
        }
        access_usage
        return 0
    fi
    access_require_platform || return $?
    if [[ -z "$action" ]]; then
        if vps_cmd_is_interactive; then access_menu; else access_status '' 0; fi
        return $?
    fi
    shift
    case "$action" in
        status) access_dispatch_status "$@" ;;
        user) access_dispatch_user "$@" ;;
        password) access_dispatch_password "$@" ;;
        key) access_dispatch_key "$@" ;;
        ssh) access_dispatch_ssh "$@" ;;
        session) access_dispatch_session "$@" ;;
        restore) access_dispatch_restore "$@" ;;
        *)
            vps_cmd_error "未知 security access 动作：$action"
            access_usage >&2
            return 2
            ;;
    esac
}

trap 'access_cleanup_secret; vps_cmd_unlock' EXIT

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    access_main "$@"
fi
