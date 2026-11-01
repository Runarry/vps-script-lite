# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016
nft_cli_status() {
    local json="${1:-0}" state installed=false active=false ipv6=false boot=disabled status=0
    if ! command -v jq >/dev/null 2>&1; then
        [[ "$json" != 1 ]] || {
            vps_cmd_error 'JSON 状态需要 jq；请运行 install'
            return 3
        }
        printf 'nftables：尚未就绪（缺少 jq；启用时安装依赖）\n'
        return 0
    fi
    state="$(vps_nft_state)" || return $?
    [[ ! -f "$(vps_cmd_system_path /usr/local/lib/vpsctl/nftables/runtime.sh)" ]] || installed=true
    if vps_nft_is_active; then active=true; else
        status=$?
        [[ "$status" == 1 ]] || return "$status"
    fi
    vps_nft_ipv6_available && ipv6=true
    if nft_cli_detect_init; then boot="$(nft_cli_boot_state)"; fi
    if [[ "$json" == 1 ]]; then
        jq --argjson installed "$installed" --argjson active "$active" --argjson ipv6 "$ipv6" --arg boot "$boot" \
            '{schema_version:1,revision,installed:$installed,enabled,runtime_active:$active,boot:$boot,ipv6:$ipv6,logging,
              rule_count:(.rules|length),limit_count:(.limits|length),requirement_count:(.requirements|length)}' <<<"$state"
    else
        printf 'nftables：%s　运行规则：%s　开机加载：%s\n' "$(jq -r 'if .enabled then "启用" else "停用" end' <<<"$state")" "$active" "$boot"
        jq -r '"手工规则：\(.rules|length)　限速：\(.limits|length)　服务需求：\(.requirements|length)　日志：\(.logging)"' <<<"$state"
    fi
}

nft_cli_install_runtime() {
    local file destination root directory
    nft_cli_detect_init || return $?
    vps_cmd_ensure_tools network-nftables nft jq flock sha256sum || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info '演练：安装离线专用运行时和 vpsctl-nftables 开机服务'
        return 0
    fi
    root=/usr/local/lib/vpsctl/nftables
    for file in lib/command.sh lib/ui.sh lib/offline.sh lib/nftables.sh \
        lib/nftables/schema.jq lib/nftables/render.jq lib/nftables/reconcile.jq lib/nftables/transactions.sh \
        scripts/po0-relay.sh; do
        [[ -f "$NFT_CLI_PROJECT_ROOT/$file" ]] || {
            vps_cmd_error "运行时文件缺失：$file"
            return 3
        }
        destination="$root/$file"
        directory="$(vps_cmd_system_path "${destination%/*}")" || return $?
        vps_cmd_require_no_symlink_components "$directory" || return $?
        mkdir -p -- "$directory" || return 20
        vps_cmd_atomic_write "$destination" 0644 <"$NFT_CLI_PROJECT_ROOT/$file" || return $?
    done
    vps_cmd_atomic_write "$root/runtime.sh" 0755 <"$NFT_CLI_PROJECT_ROOT/commands/network/nftables/runtime.sh" || return $?
    if [[ "$NFT_CLI_INIT" == systemd ]]; then
        directory="$(vps_cmd_system_path /etc/systemd/system)" || return $?
        vps_cmd_require_no_symlink_components "$directory" && mkdir -p -- "$directory" || return 20
        vps_cmd_atomic_write /etc/systemd/system/vpsctl-nftables.service 0644 <<'UNIT' || return $?
[Unit]
Description=vpsctl owned nftables firewall
DefaultDependencies=no
After=local-fs.target nftables.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/env bash /usr/local/lib/vpsctl/nftables/runtime.sh start
ExecReload=/usr/bin/env bash /usr/local/lib/vpsctl/nftables/runtime.sh reload

[Install]
WantedBy=multi-user.target
UNIT
        vps_cmd_run systemctl daemon-reload || return 20
    else
        directory="$(vps_cmd_system_path /etc/init.d)" || return $?
        vps_cmd_require_no_symlink_components "$directory" && mkdir -p -- "$directory" || return 20
        vps_cmd_atomic_write /etc/init.d/vpsctl-nftables 0755 <<'OPENRC' || return $?
#!/sbin/openrc-run
description="vpsctl owned nftables firewall"
depend() { need localmount; after nftables; before net; }
start() { ebegin "Loading vpsctl firewall"; /usr/bin/env bash /usr/local/lib/vpsctl/nftables/runtime.sh start; eend $?; }
stop() { return 0; }
reload() { /usr/bin/env bash /usr/local/lib/vpsctl/nftables/runtime.sh reload; }
extra_started_commands="reload"
OPENRC
    fi
}

nft_cli_install_locked() {
    local state
    nft_cli_install_runtime || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
    state="$(vps_nft_state)" || return $?
    nft_cli_save_json "$state" || return $?
    if [[ "$(jq -r '.enabled' <<<"$state")" == true ]]; then
        nft_cli_persist enable || return 20
        vps_cmd_success '专用运行时已更新；防火墙保持启用'
    else
        nft_cli_persist disable || return 20
        vps_cmd_success 'nftables 已安装，保持停用；使用 enable 自动采集端口并启用'
    fi
}

nft_cli_po0_source() {
    local variable
    # The standalone script exposes source-safe, private cooperation functions.
    # shellcheck source=../../../scripts/po0-relay.sh
    source "$NFT_CLI_PROJECT_ROOT/scripts/po0-relay.sh" || return $?
    if [[ "${VPSCTL_TESTING:-0}" == 1 ]]; then
        for variable in PO0_STATE_FILE PO0_NFT_FILE PO0_LEGACY_NFT_FILE PO0_SERVICE_FILE \
            PO0_SHARED_STATE PO0_SHARED_RUNTIME PO0_SHARED_LOCK PO0_PROXY_STATE_DIR PO0_SYSCTL_FILE \
            PO0_BBR_SYSCTL_FILE PO0_BBR_MODULES_FILE PO0_BACKUP_DIR PO0_LOCK_FILE; do
            printf -v "$variable" '%s' "$(vps_cmd_system_path "${!variable}")" || return $?
        done
    fi
}

nft_cli_enable_locked() {
    local state candidate prepared po0
    nft_cli_install_runtime || return $?
    [[ "${VPS_CMD_DEPENDENCIES_PLANNED:-0}" != 1 ]] || return 0
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info '演练：采集服务和 PO0 需求，原子启用自有表，设置开机加载，退役 UFW/RFW'
        return 0
    fi
    mkdir -m 0700 -- "$NFT_CLI_BACKUP/legacy" || return 20
    nft_cli_legacy_begin "$NFT_CLI_BACKUP/legacy" || return $?
    nft_cli_sync_locked record-only || return $?
    nft_cli_po0_source || return $?
    po0="$NFT_CLI_BACKUP/po0"
    po0_coop_prepare "$po0" || return $?
    if [[ -f "$po0/present" ]]; then
        vps_nft_begin po0 "$po0/requirements.json" record-only || return $?
        vps_nft_commit || return $?
    fi
    state="$(vps_nft_state)" || return $?
    candidate="$NFT_CLI_BACKUP/enable.json"
    (
        umask 077
        jq '.enabled=true | .revision+=1' <<<"$state" >"$candidate"
    ) || return 20
    prepared="$NFT_CLI_BACKUP/prepared"
    vps_nft_prepare_state "$candidate" "$prepared" || return $?
    if [[ -f "$po0/present" ]]; then cat -- "$po0/batch.nft" >>"$prepared/batch.nft" || return 20; fi
    nft -c -f "$prepared/batch.nft" || return 20
    nft -f "$prepared/batch.nft" || return 20
    vps_nft_commit_prepared "$prepared" || return $?
    if [[ -f "$po0/present" ]]; then po0_coop_commit "$po0" || return $?; fi
    nft_cli_persist enable || return 20
    nft_cli_legacy_retire "$NFT_CLI_BACKUP/legacy" || return $?
    vps_nft_is_active || {
        vps_cmd_error '自有防火墙未进入启用状态'
        return 20
    }
    nft list table inet vpsctl_firewall >/dev/null || return 20
    nft_cli_legacy_finish "$NFT_CLI_BACKUP/legacy" || return $?
    vps_cmd_success 'nftables 已启用并设置开机加载，现有 SSH 和服务端口已同步'
}

nft_cli_disable_locked() {
    local state
    state="$(vps_nft_state)" || return $?
    nft_cli_save_json "$(jq '.enabled=false | .revision+=1' <<<"$state")" || return $?
    nft_cli_persist disable || return 20
    vps_cmd_success '防火墙已停用；规则、服务联动和代理 NAT 保留'
}

nft_cli_reload_locked() {
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info '演练：重新加载自有规则'
        return 0
    fi
    vps_nft_apply
}

nft_cli_uninstall_locked() {
    local logical path
    nft_cli_disable_locked || return $?
    nft_cli_stop_runtime || return $?
    for logical in "${NFT_CLI_PATHS[@]}"; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        vps_cmd_run rm -rf -- "$path" || return 20
    done
    [[ "$NFT_CLI_INIT" != systemd ]] || vps_cmd_run systemctl daemon-reload || return 20
    vps_cmd_success '专用运行时和开机服务已卸载；配置、恢复快照和代理 NAT 保留'
}

nft_cli_logging_locked() {
    local state value=false
    [[ "$1" != on ]] || value=true
    state="$(vps_nft_state)" || return $?
    nft_cli_save_json "$(jq --argjson value "$value" '.logging=$value | .revision+=1' <<<"$state")"
}

nft_cli_links_list() {
    local json="${1:-0}" links
    nft_cli_read_tools || return $?
    links="$(vps_nft_links)" || return $?
    if [[ "$json" == 1 ]]; then
        jq -n --argjson links "$links" '{schema_version:1,links:$links}'
    else
        printf '服务 OWNER\t联动状态\t需求数\n'
        jq -r '.[] | [.owner,(if .detached then "已解除" else "自动联动" end),(.requirements|length)] | @tsv' <<<"$links"
    fi
}

nft_cli_link_locked() {
    local operation="$1" owner="$2" links
    links="$(vps_nft_links)" || return $?
    jq -e --arg owner "$owner" 'any(.[];.owner==$owner)' <<<"$links" >/dev/null || {
        vps_cmd_error '未知服务，请先 sync 并查看 link list'
        return 2
    }
    if [[ "$operation" == attach ]]; then
        vps_nft_link_set "$owner" attached || return $?
        nft_cli_sync_locked auto
    else vps_nft_link_set "$owner" detached; fi
}

nft_cli_stats() {
    local json="${1:-0}" counters='[]' data status=0
    nft_cli_read_tools || return $?
    if vps_nft_is_active; then
        data="$(nft -j list table inet vpsctl_firewall)" || return 20
        counters="$(jq '[.nftables[] | .rule? // empty | {chain,handle,comment,
            counters:[.expr[] | .counter? // empty]}]' <<<"$data")" || return 20
    else
        status=$?
        [[ "$status" == 1 ]] || return "$status"
    fi
    if [[ "$json" == 1 ]]; then
        jq -n --argjson counters "$counters" '{schema_version:1,counters:$counters}'
    else jq -r '.[] | [.chain,(.comment//""),([.counters[].packets]|add//0),([.counters[].bytes]|add//0)]|@tsv' <<<"$counters"; fi
}

nft_cli_restore_locked() {
    local backup="$1"
    [[ -d "$backup/snapshot" && -d "$backup/files" && -f "$backup/boot" && -f "$backup/init" ]] || {
        vps_cmd_error '不是有效的 nftables 恢复快照'
        return 2
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：恢复 $backup"
        return 0
    fi
    if [[ -d "$backup/legacy" ]]; then
        mkdir -m 0700 -- "$NFT_CLI_BACKUP/legacy" || return 20
        nft_cli_legacy_begin "$NFT_CLI_BACKUP/legacy" || return $?
        : >"$NFT_CLI_BACKUP/legacy/retirement-started" || return 20
    fi
    if [[ -f "$backup/po0/present" ]]; then
        nft_cli_po0_source && po0_coop_prepare "$NFT_CLI_BACKUP/po0" || return $?
    fi
    nft_cli_recover "$backup" || return 30
    vps_cmd_success '防火墙和专用服务已从快照恢复'
}
