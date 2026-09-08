# shellcheck shell=bash
# HTTP-01 leases use short UFW transactions; ACME never holds the UFW lock.

TLS_UFW_SCOPE=''
TLS_UFW_DESIRED=''
TLS_HTTP_CHILD_PID=''

tls_install_cleanup_traps() {
    trap 'if tls_exit_cleanup "$?"; then exit 0; else exit "$?"; fi' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
}

tls_ufw_emit_lease() {
    local ipv6=false
    if vps_ufw_ipv6_available; then ipv6=true; fi
    jq -n --arg owner "tls:${TLS_UFW_SCOPE#tls-}" --argjson ipv6 "$ipv6" '
        (["ipv4"] + if $ipv6 then ["ipv6"] else [] end) | map({owner: $owner, kind: "input", family: .,
            proto: "tcp", port: "80", destination: "any", source: "any", temporary: true})'
}

tls_ufw_release() {
    [[ -n "${TLS_UFW_SCOPE:-}" ]] || return 0
    local status=0
    # An interrupted begin/commit must first restore its pending transaction.
    vps_ufw_rollback || return $?
    printf '[]\n' >"$TLS_UFW_DESIRED" || return 20
    vps_ufw_begin "$TLS_UFW_SCOPE" "$TLS_UFW_DESIRED" || status=$?
    if ((status == 0)); then
        vps_ufw_commit || status=$?
    fi
    if ((status != 0)); then
        vps_ufw_rollback || true
        vps_cmd_warning "HTTP-01 临时防火墙需求清理失败；请运行防火墙同步清理失效租约"
        return "$status"
    fi
    TLS_UFW_SCOPE=''
    rm -f -- "$TLS_UFW_DESIRED"
    TLS_UFW_DESIRED=''
}

tls_exit_cleanup() {
    local status="${1:-0}" cleanup_status=0
    trap '' INT TERM HUP
    if [[ -n "${TLS_HTTP_CHILD_PID:-}" ]]; then
        kill -TERM "$TLS_HTTP_CHILD_PID" 2>/dev/null || true
        wait "$TLS_HTTP_CHILD_PID" 2>/dev/null || true
        TLS_HTTP_CHILD_PID=''
    fi
    tls_ufw_release || cleanup_status=$?
    if [[ -n "${TLS_UFW_DESIRED:-}" ]]; then
        rm -f -- "$TLS_UFW_DESIRED"
    fi
    vps_cmd_unlock
    ((status != 0)) || status="$cleanup_status"
    return "$status"
}

tls_run_challenge() {
    local challenge="$1" cred="$2"
    shift 2
    if [[ "$challenge" != http-01 ]]; then
        tls_run_lego "$cred" "$@"
        return $?
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：HTTP-01 期间临时申请 TCP 80 放行，完成后释放；不启用 UFW"
        tls_run_lego "$cred" "$@"
        return $?
    fi
    local status=0 cleanup_status=0
    tls_ufw_release || return $?
    vps_ufw_require_tools || return $?
    vps_ufw_init || return $?
    TLS_UFW_DESIRED="$(mktemp "${TMPDIR:-/tmp}/vpsctl-tls-ufw.XXXXXX")" || return 20
    TLS_UFW_SCOPE="tls-${BASHPID}-${RANDOM}-${RANDOM}"
    tls_ufw_emit_lease >"$TLS_UFW_DESIRED" || status=$?
    if ((status == 0)); then
        vps_ufw_begin "$TLS_UFW_SCOPE" "$TLS_UFW_DESIRED" || status=$?
    fi
    if ((status == 0)); then
        vps_ufw_commit || status=$?
    fi
    if ((status == 0)); then
        "$TLS_LEGO_BIN" "$@" &
        TLS_HTTP_CHILD_PID=$!
        wait "$TLS_HTTP_CHILD_PID" || status=$?
        TLS_HTTP_CHILD_PID=''
    fi
    tls_ufw_release || cleanup_status=$?
    ((status != 0)) || status="$cleanup_status"
    return "$status"
}
