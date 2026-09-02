#!/usr/bin/env bash
# Manage imported and ACME TLS certificates for local domain names.
# shellcheck disable=SC2034

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
    printf 'security tls 需要 Bash 4.4 或更高版本。\n' >&2
    exit 3
fi

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

tls_project_root() {
    if [[ -n "${VPSCTL_PROJECT_ROOT:-}" ]]; then
        printf '%s' "$VPSCTL_PROJECT_ROOT"
        return 0
    fi
    local script_dir
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    cd -- "${script_dir}/../.." && pwd -P
}

TLS_PROJECT_ROOT="$(tls_project_root)"
readonly TLS_PROJECT_ROOT
readonly TLS_MODULE_DIR="${TLS_PROJECT_ROOT}/commands/security/tls"

# shellcheck source=../../lib/command.sh
source "${TLS_PROJECT_ROOT}/lib/command.sh"

tls_load_module() {
    local name="$1" path
    path="${TLS_MODULE_DIR}/${name}"
    [[ "$name" =~ ^[a-z0-9-]+\.sh$ ]] || {
        vps_cmd_error "无效 TLS 模块名称：$name"
        return 2
    }
    [[ -f "$path" && -r "$path" && ! -L "$path" ]] || {
        vps_cmd_error "无法安全读取 TLS 模块：$path"
        return 3
    }
    vps_cmd_require_no_symlink_components "$path" || return $?
    # shellcheck source=/dev/null
    source "$path"
}

tls_load_module common.sh || exit $?
tls_load_module store.sh || exit $?
tls_load_module issue.sh || exit $?
tls_load_module timer.sh || exit $?

TLS_ARGS=()

tls_usage() {
    cat <<'EOF'
管理本机域名 TLS 证书：导入用户证书，或通过 ACME 申请并续期。

用法：
  tls.sh [global-options] status [--json]
  tls.sh [global-options] list [--json]
  tls.sh [global-options] show --id ID [--json]
  tls.sh [global-options] paths --id ID
  tls.sh [global-options] import --name NAME --cert-file FILE --key-file FILE
      [--chain-file FILE] [--reload none|proxy]
  tls.sh [global-options] replace --id ID --cert-file FILE --key-file FILE
      [--chain-file FILE] [--reload none|proxy]
  tls.sh [global-options] delete --id ID --confirm-delete
  tls.sh [global-options] issue --domain DOMAIN [--domain DOMAIN ...]
      --challenge http-01|dns-01 [--ca letsencrypt|zerossl] [--email EMAIL]
      [--dns-provider cloudflare|aliyun|tencent|dnspod|huawei]
      [--dns-credential-file FILE] [--staging] [--reload none|proxy]
  tls.sh [global-options] renew [--id ID | --all] [--force]
  tls.sh [global-options] credentials --id ID --dns-credential-file FILE
  tls.sh [global-options] timer status|enable|disable
  tls.sh [global-options] uninstall --confirm-uninstall REMOVE-VPSCTL-TLS
      [--purge --confirm-purge]

全局选项：
  --dry-run --install-deps --yes --non-interactive --quiet --verbose --no-color
  -h, --help

导入、查看不依赖 systemd。续期 timer 仅支持 systemd。ACME 使用钉死版本的
lego（x86_64/aarch64）。私钥不会写入 stdout、日志或 JSON。
EOF
}

tls_parse_globals() {
    TLS_ARGS=()
    while (($# > 0)); do
        case "$1" in
            --dry-run) VPSCTL_DRY_RUN=1 ;;
            --install-deps) VPSCTL_INSTALL_DEPS=1 ;;
            --yes) VPSCTL_ASSUME_YES=1 ;;
            --non-interactive) VPSCTL_NON_INTERACTIVE=1 ;;
            --quiet) VPSCTL_QUIET=1 ;;
            --verbose) VPSCTL_VERBOSE=1 ;;
            --no-color) VPSCTL_NO_COLOR=1 ;;
            --) shift; TLS_ARGS=("$@"); return 0 ;;
            *) TLS_ARGS=("$@"); return 0 ;;
        esac
        shift
    done
}

tls_menu_pick_id() {
    local prompt="$1" id
    local -a ids=() args=()
    mapfile -t ids < <(tls_list_ids | sort)
    ((${#ids[@]} > 0)) || {
        vps_cmd_error "还没有证书"
        return 3
    }
    args=("$prompt" "${ids[0]}")
    for id in "${ids[@]}"; do
        tls_load_record "$id" || continue
        args+=("$id" "${id}  ${TLS_CERT_NAME}  ${TLS_CERT_DOMAINS}")
    done
    ((${#args[@]} >= 4)) || {
        vps_cmd_error "还没有证书"
        return 3
    }
    vps_cmd_prompt_select "${args[@]}"
}

tls_menu() {
    local choice action id value cert key chain email provider cred reload status=0 rc
    local -a issue_args=() domains=()
    while true; do
        tls_status 0 || true
        choice="$(vps_cmd_prompt_select "TLS 证书管理" status \
            __section__ "查看" \
            status "总览" list "列出证书" show "查看详情" paths "打印 live 路径" \
            __section__ "上传" \
            import "导入证书" replace "替换证书" \
            __section__ "申请与续期" \
            issue "申请 ACME 证书" renew "续期" timer "续期 timer" credentials "更新 DNS 凭证" \
            __section__ "删除" \
            delete "删除证书" uninstall "卸载 timer / 清除库存" \
            quit "退出")" || {
            rc=$?
            [[ "$rc" == 130 ]] && return "$status"
            return "$rc"
        }
        case "$choice" in
            status) tls_status 0 || status=$? ;;
            list) tls_list || status=$? ;;
            show)
                id="$(tls_menu_pick_id "选择证书")" || continue
                tls_show --id "$id" || status=$?
                ;;
            paths)
                id="$(tls_menu_pick_id "选择证书")" || continue
                tls_paths --id "$id" || status=$?
                ;;
            import)
                value="$(vps_cmd_prompt_value "展示名称" '')" || continue
                cert="$(vps_cmd_prompt_value "证书绝对路径" '')" || continue
                key="$(vps_cmd_prompt_value "私钥绝对路径" '')" || continue
                chain="$(vps_cmd_prompt_value "证书链绝对路径（可空）" '')" || continue
                reload="$(vps_cmd_prompt_select "续期后重载" none none "不重载" proxy "重载代理内核")" || continue
                if [[ -n "$chain" ]]; then
                    tls_import --name "$value" --cert-file "$cert" --key-file "$key" --chain-file "$chain" --reload "$reload" || status=$?
                else
                    tls_import --name "$value" --cert-file "$cert" --key-file "$key" --reload "$reload" || status=$?
                fi
                ;;
            replace)
                id="$(tls_menu_pick_id "选择要替换的证书")" || continue
                cert="$(vps_cmd_prompt_value "证书绝对路径" '')" || continue
                key="$(vps_cmd_prompt_value "私钥绝对路径" '')" || continue
                chain="$(vps_cmd_prompt_value "证书链绝对路径（可空）" '')" || continue
                reload="$(vps_cmd_prompt_select "续期后重载" none none "不重载" proxy "重载代理内核")" || continue
                if [[ -n "$chain" ]]; then
                    tls_replace --id "$id" --cert-file "$cert" --key-file "$key" --chain-file "$chain" --reload "$reload" || status=$?
                else
                    tls_replace --id "$id" --cert-file "$cert" --key-file "$key" --reload "$reload" || status=$?
                fi
                ;;
            issue)
                value="$(vps_cmd_prompt_value "域名（逗号分隔）" '')" || continue
                action="$(vps_cmd_prompt_select "挑战类型" http-01 http-01 "HTTP-01（端口 80）" dns-01 "DNS-01")" || continue
                provider=""
                cred=""
                if [[ "$action" == dns-01 ]]; then
                    provider="$(vps_cmd_prompt_select "DNS 提供商" cloudflare cloudflare "Cloudflare" aliyun "阿里云" tencent "腾讯云" dnspod "DNSPod" huawei "华为云")" || continue
                    cred="$(vps_cmd_prompt_value "DNS 凭证文件绝对路径" '')" || continue
                fi
                email="$(vps_cmd_prompt_value "ACME 账户邮箱" '')" || continue
                reload="$(vps_cmd_prompt_select "续期后重载" none none "不重载" proxy "重载代理内核")" || continue
                issue_args=(--challenge "$action" --email "$email" --reload "$reload")
                IFS=',' read -r -a domains <<<"$value"
                for id in "${domains[@]}"; do
                    id="$(vps_cmd_trim "$id")"
                    [[ -n "$id" ]] || continue
                    issue_args+=(--domain "$id")
                done
                if [[ "$action" == dns-01 ]]; then
                    issue_args+=(--dns-provider "$provider" --dns-credential-file "$cred")
                fi
                tls_issue "${issue_args[@]}" || status=$?
                ;;
            renew)
                action="$(vps_cmd_prompt_select "续期范围" all all "全部到期证书" one "选择一张")" || continue
                if [[ "$action" == all ]]; then
                    tls_renew --all || status=$?
                else
                    id="$(tls_menu_pick_id "选择要续期的证书")" || continue
                    tls_renew --id "$id" || status=$?
                fi
                ;;
            timer)
                action="$(vps_cmd_prompt_select "续期 timer" status status "查看" enable "启用" disable "停用")" || continue
                tls_timer_dispatch "$action" || status=$?
                ;;
            credentials)
                id="$(tls_menu_pick_id "选择 ACME 证书")" || continue
                cred="$(vps_cmd_prompt_value "DNS 凭证文件绝对路径" '')" || continue
                tls_credentials --id "$id" --dns-credential-file "$cred" || status=$?
                ;;
            delete)
                id="$(tls_menu_pick_id "选择要删除的证书")" || continue
                vps_cmd_confirm_token "删除证书及其私钥" "$id" || continue
                tls_delete --id "$id" --confirm-delete || status=$?
                ;;
            uninstall)
                action="$(vps_cmd_prompt_select "卸载范围" timer timer "仅移除 timer" purge "清除证书库存")" || continue
                vps_cmd_confirm_token "卸载 TLS 管理" "$TLS_UNINSTALL_TOKEN" || continue
                if [[ "$action" == purge ]]; then
                    vps_cmd_confirm_token "彻底清除证书库存" "$TLS_UNINSTALL_TOKEN" || continue
                    tls_uninstall --confirm-uninstall "$TLS_UNINSTALL_TOKEN" --purge --confirm-purge || status=$?
                else
                    tls_uninstall --confirm-uninstall "$TLS_UNINSTALL_TOKEN" || status=$?
                fi
                ;;
            quit) return "$status" ;;
        esac
    done
}

tls_main() {
    local action init_status
    tls_parse_globals "$@"
    if vps_cmd_init "security tls" "$TLS_PROJECT_ROOT"; then :; else init_status=$?; return "$init_status"; fi
    tls_init_paths || return $?
    tls_require_linux || return $?
    set -- "${TLS_ARGS[@]}"
    action="${1:-}"
    if [[ "$action" == help || "$action" == -h || "$action" == --help ]]; then
        (($# == 1)) || { vps_cmd_error "help 不接受额外参数"; return 2; }
        tls_usage
        return 0
    fi
    if [[ -z "$action" ]]; then
        if vps_cmd_is_interactive; then
            tls_menu
        else
            tls_status 0
        fi
        return $?
    fi
    shift
    case "$action" in
        status) tls_dispatch_status "$@" ;;
        list) tls_list "$@" ;;
        show) tls_show "$@" ;;
        paths) tls_paths "$@" ;;
        import) tls_import "$@" ;;
        replace) tls_replace "$@" ;;
        delete) tls_delete "$@" ;;
        issue) tls_issue "$@" ;;
        renew) tls_renew "$@" ;;
        credentials) tls_credentials "$@" ;;
        timer) tls_timer_dispatch "$@" ;;
        uninstall) tls_uninstall "$@" ;;
        *)
            vps_cmd_error "未知 security tls 动作：$action"
            tls_usage >&2
            return 2
            ;;
    esac
}

trap 'vps_cmd_unlock' EXIT

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    tls_main "$@"
fi
