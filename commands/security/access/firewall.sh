# shellcheck shell=bash

ACCESS_FW_BACKEND='none'
ACCESS_FW_ADDED=0
ACCESS_FW_PREVIOUS_BACKEND=''
ACCESS_FW_PREVIOUS_PORT=''
ACCESS_FW_PREVIOUS_OWNED=0
ACCESS_FW_PREVIOUS_MODE=''
ACCESS_FW_STATE_LOGICAL="${ACCESS_STATE_LOGICAL}/firewall.state"
ACCESS_FW_STATE=''
ACCESS_FW_NFT_TARGETS=''
ACCESS_FW_NFT_MODE='auto'

access_firewall_init() {
    ACCESS_FW_STATE="$(vps_cmd_system_path "$ACCESS_FW_STATE_LOGICAL")" || return $?
}

access_firewall_service_enabled() {
    systemctl is-enabled --quiet "$1" >/dev/null 2>&1
}

access_firewall_detect() {
    local ufw_status iptables_version iptables_rules
    local -a detected=()

    if command -v ufw >/dev/null 2>&1; then
        ufw_status="$(LC_ALL=C ufw status 2>/dev/null | head -n 1 || true)"
        if [[ "$ufw_status" == 'Status: active' ]]; then
            detected+=(ufw)
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        detected+=(firewalld)
    fi
    if ((${#detected[@]} == 0)); then
        if command -v nft >/dev/null 2>&1 && access_firewall_nft_targets; then
            detected+=(nftables)
        fi
        if command -v iptables >/dev/null 2>&1; then
            iptables_rules="$(iptables -S 2>/dev/null || true)"
            if grep -qvE '^-P (INPUT|FORWARD|OUTPUT) ACCEPT$' <<<"$iptables_rules"; then
                iptables_version="$(iptables --version 2>/dev/null || true)"
                [[ "$iptables_version" == *nf_tables* && " ${detected[*]} " == *' nftables '* ]] || detected+=(iptables)
            fi
        fi
    fi
    if ((${#detected[@]} > 1)); then
        vps_cmd_error "检测到多个活动防火墙后端：${detected[*]}；拒绝 auto，请使用 --firewall manual 明确自行管理"
        return 3
    fi
    ((${#detected[@]} == 1)) && printf '%s\n' "${detected[0]}" || printf 'none\n'
}

access_firewall_nft_persistent() {
    local config

    config="$(vps_cmd_system_path /etc/nftables.conf)" || return $?
    access_firewall_service_enabled nftables.service || return 1
    [[ -f "$config" && ! -L "$config" ]] || return 1
    grep -Eq '^[[:space:]]*include[[:space:]]+[\"]?/etc/nftables\.d/\*\.nft[\"]?[[:space:]]*$' "$config" || return 1
    access_firewall_nft_targets
}

access_firewall_nft_targets() {
    local output family table chain found=0

    output="$(nft -a list ruleset 2>/dev/null | awk '
        $1 == "table" && ($2 == "inet" || $2 == "ip" || $2 == "ip6") {
            family=$2
            table_name=$3
            sub(/\{.*/, "", table_name)
            in_table=1
            next
        }
        in_table && $1 == "chain" {
            chain_name=$2
            sub(/\{.*/, "", chain_name)
            in_chain=1
            is_input=0
            restrictive=0
            managed=0
            next
        }
        in_chain && /type[[:space:]]+filter[[:space:]]+hook[[:space:]]+input([[:space:]]|;)/ {
            is_input=1
            if (/policy[[:space:]]+drop([[:space:]]|;)/) restrictive=1
            next
        }
        in_chain && $1 == "}" {
            if (is_input && (restrictive || managed)) {
                key=family SUBSEP table_name SUBSEP chain_name
                if (!seen[key]++) print family "\t" table_name "\t" chain_name
            }
            in_chain=0
            chain_name=""
            next
        }
        in_chain {
            if (/comment "vpsctl-access-[0-9]+"/) managed=1
            else if ($1 != "") restrictive=1
            next
        }
        in_table && $1 == "}" { in_table=0; family=""; table_name="" }
    ')" || return 1
    [[ -n "$output" ]] || return 1
    while IFS=$'\t' read -r family table chain; do
        [[ "$family" == inet || "$family" == ip || "$family" == ip6 ]] || return 1
        [[ "$table" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ && "$chain" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 1
        found=1
    done <<<"$output"
    ((found == 1)) || return 1
    ACCESS_FW_NFT_TARGETS="$output"
}

access_firewall_iptables_persistence() {
    if command -v netfilter-persistent >/dev/null 2>&1 && access_firewall_service_enabled netfilter-persistent.service; then
        printf 'netfilter-persistent\n'
        return 0
    fi
    if command -v service >/dev/null 2>&1 && access_firewall_service_enabled iptables.service; then
        printf 'iptables-service\n'
        return 0
    fi
    return 1
}

access_firewall_require_auto_backend() {
    local backend="$1" requested_mode="${2:-auto}" choice nft_file

    case "$backend" in
        none | ufw | firewalld) return 0 ;;
        nftables)
            access_firewall_nft_targets || {
                vps_cmd_error "检测到 nftables，但无法定位现有 INPUT 基链；请使用 --firewall manual"
                return 3
            }
            if [[ "$requested_mode" == persistent ]]; then
                access_firewall_nft_persistent || {
                    vps_cmd_error "事务记录要求 nftables 持久化模式，但 nftables.service 或 /etc/nftables.d/*.nft include 已漂移"
                    return 3
                }
                ACCESS_FW_NFT_MODE=persistent
                return 0
            fi
            if [[ "$requested_mode" == auto ]] && access_firewall_nft_persistent; then
                ACCESS_FW_NFT_MODE=persistent
                return 0
            fi
            if [[ "$requested_mode" == runtime ]]; then
                choice=runtime
            elif vps_cmd_is_interactive; then
                choice="$(vps_cmd_prompt_select "nftables 未检测到可靠持久化，如何处理候选 SSH 端口" runtime \
                    runtime "自动添加运行时规则（重启后失效）" \
                    manual "本次改为人工管理防火墙")" || return $?
            else
                choice=runtime
                vps_cmd_warning "nftables 未检测到可靠持久化；--firewall auto 将添加运行时规则，规则在重启或 ruleset reload 后可能失效"
            fi
            if [[ "$choice" == manual ]]; then
                ACCESS_FW_NFT_MODE=manual
                vps_cmd_warning "已选择人工管理 nftables；请自行确保候选 SSH 端口可达"
                return 0
            fi
            nft_file="$(access_firewall_nft_file)" || return $?
            if [[ -e "$nft_file" ]]; then
                access_firewall_nft_validate_file "$nft_file" || {
                    vps_cmd_error "存在不受管的 nftables 片段，拒绝运行时回退：/etc/nftables.d/zz-vpsctl-access.nft"
                    return 3
                }
                vps_cmd_error "已存在 vpsctl nftables 持久化片段，但持久化入口当前不可用；请先修复 nftables.service/include 或使用 --firewall manual"
                return 3
            fi
            ACCESS_FW_NFT_MODE=runtime
            vps_cmd_warning "将只在现有 INPUT 基链中添加 vpsctl 运行时规则；第二会话仍会实测可达性，但提交后请在重启或 reload ruleset 前补齐持久化"
            ;;
        iptables)
            access_firewall_iptables_persistence >/dev/null || {
                vps_cmd_error "检测到原生 iptables，但未检测到 netfilter-persistent 或 iptables-services 持久化；拒绝自动修改，请使用 --firewall manual"
                return 3
            }
            ;;
        *) return 70 ;;
    esac
}

access_firewall_load_managed() {
    ACCESS_FW_PREVIOUS_BACKEND=''
    ACCESS_FW_PREVIOUS_PORT=''
    ACCESS_FW_PREVIOUS_OWNED=0
    ACCESS_FW_PREVIOUS_MODE=''
    [[ -f "$ACCESS_FW_STATE" && ! -L "$ACCESS_FW_STATE" ]] || return 0
    ACCESS_FW_PREVIOUS_BACKEND="$(access_kv_get "$ACCESS_FW_STATE" backend 2>/dev/null || true)"
    ACCESS_FW_PREVIOUS_PORT="$(access_kv_get "$ACCESS_FW_STATE" port 2>/dev/null || true)"
    ACCESS_FW_PREVIOUS_OWNED="$(access_kv_get "$ACCESS_FW_STATE" owned 2>/dev/null || true)"
    ACCESS_FW_PREVIOUS_MODE="$(access_kv_get "$ACCESS_FW_STATE" mode 2>/dev/null || true)"
    case "$ACCESS_FW_PREVIOUS_BACKEND" in
        ufw | firewalld | nftables | iptables) ;;
        *)
            ACCESS_FW_PREVIOUS_BACKEND=''
            ACCESS_FW_PREVIOUS_PORT=''
            ACCESS_FW_PREVIOUS_OWNED=0
            ;;
    esac
    if [[ "$ACCESS_FW_PREVIOUS_BACKEND" == nftables ]]; then
        [[ "$ACCESS_FW_PREVIOUS_MODE" == persistent || "$ACCESS_FW_PREVIOUS_MODE" == runtime ]] || ACCESS_FW_PREVIOUS_MODE=persistent
    else
        ACCESS_FW_PREVIOUS_MODE=''
    fi
    [[ "$ACCESS_FW_PREVIOUS_OWNED" == 1 ]] && access_validate_port "$ACCESS_FW_PREVIOUS_PORT" || {
        ACCESS_FW_PREVIOUS_BACKEND=''
        ACCESS_FW_PREVIOUS_PORT=''
        ACCESS_FW_PREVIOUS_OWNED=0
        ACCESS_FW_PREVIOUS_MODE=''
    }
}

access_firewall_ufw_has_port() {
    LC_ALL=C ufw status 2>/dev/null | awk -v port="$1" '
        $1 == port || $1 == port "/tcp" { if ($2 == "ALLOW" || $2 == "ALLOW IN") found=1 }
        END { exit(found ? 0 : 1) }
    '
}

access_firewall_ufw_owned_numbers() {
    LC_ALL=C ufw status numbered 2>/dev/null | awk -v port="$1" '
        index($0, "# vpsctl security access") && $0 ~ ("\\][[:space:]]*" port "(/tcp)?([[:space:]]|$)") {
            number=$0
            sub(/\].*$/, "", number)
            gsub(/[^0-9]/, "", number)
            if (number != "") print number
        }
    ' | sort -rn
}

access_firewall_ufw_has_owned_port() {
    [[ -n "$(access_firewall_ufw_owned_numbers "$1")" ]]
}

access_firewall_firewalld_rule() {
    printf 'rule priority="-32700" port port="%s" protocol="tcp" accept\n' "$1"
}

access_firewall_firewalld_active_zone() {
    local output count

    output="$(firewall-cmd --get-active-zones 2>/dev/null | awk '/^[^[:space:]]/ {print $1}')" || return 3
    count="$(grep -c . <<<"$output" || true)"
    if [[ "$count" == 0 ]]; then
        output="$(firewall-cmd --get-default-zone 2>/dev/null)" || return 3
    elif [[ "$count" != 1 ]]; then
        vps_cmd_error "firewalld 有多个活动 zone；拒绝猜测 SSH 接口归属"
        return 3
    fi
    [[ "$output" =~ ^[A-Za-z0-9_-]+$ ]] || return 3
    printf '%s\n' "$output"
}

access_firewall_firewalld_has_owned_port() {
    local port="$1" scope="${2:-runtime}" zone="${3:-}" rule candidate

    rule="$(access_firewall_firewalld_rule "$port")"
    if [[ -z "$zone" ]]; then
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] || continue
            access_firewall_firewalld_has_owned_port "$port" "$scope" "$candidate" && return 0
        done < <(firewall-cmd --get-zones 2>/dev/null | tr ' ' '\n')
        return 1
    elif [[ "$scope" == permanent ]]; then
        firewall-cmd --quiet --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1
    else
        firewall-cmd --quiet --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1
    fi
}

access_firewall_has_owned_port() {
    local backend="$1" port="$2"

    case "$backend" in
        ufw) access_firewall_ufw_has_owned_port "$port" ;;
        firewalld) access_firewall_firewalld_has_owned_port "$port" ;;
        nftables) access_firewall_nft_has_port "$port" ;;
        iptables) access_firewall_iptables_has_owned_port "$port" ;;
        *) return 1 ;;
    esac
}

access_firewall_nft_has_port() {
    local port="$1" family table chain rules found=0

    access_firewall_nft_targets || return 1
    while IFS=$'\t' read -r family table chain; do
        [[ -n "$family" ]] || continue
        rules="$(nft -a list chain "$family" "$table" "$chain" 2>/dev/null)" || return 1
        grep -Fq "comment \"vpsctl-access-${port}\"" <<<"$rules" || return 1
        found=1
    done <<<"$ACCESS_FW_NFT_TARGETS"
    ((found == 1))
}

access_firewall_iptables_has_owned_port() {
    local port="$1"

    iptables -C INPUT -p tcp --dport "$port" -m comment --comment "vpsctl-access-${port}" -j ACCEPT >/dev/null 2>&1 || return 1
    if command -v ip6tables >/dev/null 2>&1 && ip6tables -S >/dev/null 2>&1; then
        ip6tables -C INPUT -p tcp --dport "$port" -m comment --comment "vpsctl-access-${port}" -j ACCEPT >/dev/null 2>&1
    fi
}

access_firewall_nft_file() {
    vps_cmd_system_path /etc/nftables.d/zz-vpsctl-access.nft
}

access_firewall_nft_validate_file() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || return 1
    awk -v marker="$ACCESS_MANAGED_MARKER" '
        NR == 1 { if ($0 != marker) exit 1; next }
        {
            if (NF != 11 || $1 != "insert" || $2 != "rule" ||
                ($3 != "inet" && $3 != "ip" && $3 != "ip6") ||
                $4 !~ /^[A-Za-z_][A-Za-z0-9_.-]*$/ ||
                $5 !~ /^[A-Za-z_][A-Za-z0-9_.-]*$/ ||
                $6 != "tcp" || $7 != "dport" || $8 !~ /^[0-9]+$/ ||
                $9 != "accept" || $10 != "comment") exit 1
            comment=$11
            gsub(/^"|"$/, "", comment)
            if (comment != "vpsctl-access-" $8) exit 1
        }
        END { if (NR < 2) exit 1 }
    ' "$file"
}

access_firewall_nft_render() {
    local port="$1" old_port="${2:-}" family table chain

    printf '%s\n' "$ACCESS_MANAGED_MARKER"
    while IFS=$'\t' read -r family table chain; do
        [[ -n "$family" ]] || continue
        printf 'insert rule %s %s %s tcp dport %s accept comment "vpsctl-access-%s"\n' "$family" "$table" "$chain" "$port" "$port"
        [[ -z "$old_port" || "$old_port" == "$port" ]] ||
            printf 'insert rule %s %s %s tcp dport %s accept comment "vpsctl-access-%s"\n' "$family" "$table" "$chain" "$old_port" "$old_port"
    done <<<"$ACCESS_FW_NFT_TARGETS"
}

access_firewall_nft_delete_owned_rules() {
    local family table chain output handle
    local -a handles=()

    access_firewall_nft_targets || return 30
    while IFS=$'\t' read -r family table chain; do
        [[ -n "$family" ]] || continue
        output="$(nft -a list chain "$family" "$table" "$chain" 2>/dev/null)" || return 20
        mapfile -t handles < <(awk '
            /comment "vpsctl-access-[0-9]+"/ && /handle [0-9]+/ {
                for (i=1; i<=NF; i++) if ($i == "handle" && $(i+1) ~ /^[0-9]+$/) print $(i+1)
            }
        ' <<<"$output" | sort -rn)
        for handle in "${handles[@]}"; do
            vps_cmd_run nft delete rule "$family" "$table" "$chain" handle "$handle" || return 20
        done
        handles=()
    done <<<"$ACCESS_FW_NFT_TARGETS"
}

access_firewall_nft_snapshot_owned() {
    local destination="$1" family table chain output

    printf '%s\n' "$ACCESS_MANAGED_MARKER" >"$destination" || return 20
    while IFS=$'\t' read -r family table chain; do
        [[ -n "$family" ]] || continue
        output="$(nft -a list chain "$family" "$table" "$chain" 2>/dev/null)" || return 20
        awk -v family="$family" -v table="$table" -v chain="$chain" '
            /comment "vpsctl-access-[0-9]+"/ {
                port=""
                for (i=1; i<=NF; i++) if ($i == "dport" && $(i+1) ~ /^[0-9]+$/) port=$(i+1)
                comment=$0
                sub(/^.*comment "vpsctl-access-/, "", comment)
                sub(/".*$/, "", comment)
                if (port != "" && comment == port)
                    printf "insert rule %s %s %s tcp dport %s accept comment \"vpsctl-access-%s\"\n", family, table, chain, port, port
            }
        ' <<<"$output" >>"$destination" || return 20
    done <<<"$ACCESS_FW_NFT_TARGETS"
}

access_firewall_nft_apply_runtime() {
    local port="$1" old_port="${2:-}" tmp old_file delete_status=0

    tmp="$(mktemp)" || return 20
    old_file="$(mktemp)" || {
        rm -f -- "$tmp"
        return 20
    }
    access_firewall_nft_render "$port" "$old_port" >"$tmp" || {
        rm -f -- "$tmp" "$old_file"
        return 20
    }
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        rm -f -- "$tmp" "$old_file"
        vps_cmd_info "演练：将在现有 nftables INPUT 基链首部插入运行时 TCP $port 规则；不会创建持久化文件"
        return 0
    fi
    nft -c -f "$tmp" || {
        rm -f -- "$tmp" "$old_file"
        return 10
    }
    access_firewall_nft_snapshot_owned "$old_file" || {
        rm -f -- "$tmp" "$old_file"
        return 20
    }
    access_firewall_nft_delete_owned_rules || delete_status=$?
    if ((delete_status)); then
        rm -f -- "$tmp" "$old_file"
        return "$delete_status"
    fi
    if ! nft -f "$tmp"; then
        access_firewall_nft_delete_owned_rules >/dev/null 2>&1 || true
        nft -f "$old_file" >/dev/null 2>&1 || true
        rm -f -- "$tmp" "$old_file"
        return 20
    fi
    rm -f -- "$tmp" "$old_file"
    access_firewall_has_port nftables "$port" || return 30
    [[ -z "$old_port" || "$old_port" == "$port" ]] || access_firewall_has_port nftables "$old_port" || return 30
}

access_firewall_nft_apply_persistent() {
    local port="$1" old_port="${2:-}" nft_file nft_dir tmp old_file='' had_file=0 delete_status=0

    access_firewall_nft_persistent || return 3
    nft_file="$(access_firewall_nft_file)" || return $?
    nft_dir="${nft_file%/*}"
    vps_cmd_require_no_symlink_components "$nft_dir" || return $?
    vps_cmd_require_no_symlink_components "$nft_file" || return $?
    if [[ -e "$nft_file" ]] && ! access_firewall_nft_validate_file "$nft_file"; then
        vps_cmd_error "nftables 持久化文件已存在但不属于 vpsctl：/etc/nftables.d/zz-vpsctl-access.nft"
        return 3
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：将在现有 nftables INPUT 基链首部插入并持久化带标记的 TCP $port 规则"
        return 0
    fi
    mkdir -p -- "$nft_dir" || return 20
    chmod 0755 -- "$nft_dir" || return 20
    tmp="$(mktemp --tmpdir="$nft_dir" .vpsctl-access.XXXXXX)" || return 20
    access_firewall_nft_render "$port" "$old_port" >"$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    chmod 0644 -- "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    if ! nft -c -f "$tmp"; then
        rm -f -- "$tmp"
        return 10
    fi
    if [[ -f "$nft_file" ]]; then
        old_file="$(mktemp)" || {
            rm -f -- "$tmp"
            return 20
        }
        cp -p -- "$nft_file" "$old_file" || {
            rm -f -- "$tmp" "$old_file"
            return 20
        }
        had_file=1
    fi
    access_firewall_nft_delete_owned_rules || delete_status=$?
    if ((delete_status)); then
        rm -f -- "$tmp" "$old_file"
        return "$delete_status"
    fi
    if ! nft -f "$tmp"; then
        access_firewall_nft_delete_owned_rules >/dev/null 2>&1 || true
        ((had_file == 0)) || nft -f "$old_file" >/dev/null 2>&1 || true
        rm -f -- "$tmp"
        rm -f -- "$old_file"
        return 20
    fi
    if ! mv -f -- "$tmp" "$nft_file"; then
        access_firewall_nft_delete_owned_rules >/dev/null 2>&1 || true
        ((had_file == 0)) || nft -f "$old_file" >/dev/null 2>&1 || true
        ((had_file == 0)) || cp -p -- "$old_file" "$nft_file" >/dev/null 2>&1 || true
        rm -f -- "$old_file"
        return 20
    fi
    rm -f -- "$old_file"
    access_firewall_has_port nftables "$port" || return 30
    [[ -z "$old_port" || "$old_port" == "$port" ]] || access_firewall_has_port nftables "$old_port" || return 30
}

access_firewall_nft_apply() {
    local port="$1" old_port="${2:-}" mode="${3:-auto}"

    access_firewall_nft_targets || {
        vps_cmd_error "nftables INPUT 基链已消失或无法安全解析"
        return 30
    }
    if [[ "$mode" == auto ]]; then
        access_firewall_nft_persistent && mode=persistent || mode=runtime
    fi
    case "$mode" in
        persistent) access_firewall_nft_apply_persistent "$port" "$old_port" ;;
        runtime) access_firewall_nft_apply_runtime "$port" "$old_port" ;;
        *) return 70 ;;
    esac
}

access_firewall_iptables_save() {
    local persistence

    persistence="$(access_firewall_iptables_persistence)" || return 3
    case "$persistence" in
        netfilter-persistent) vps_cmd_run netfilter-persistent save || return 20 ;;
        iptables-service)
            vps_cmd_run service iptables save || return 20
            if command -v ip6tables >/dev/null 2>&1 && access_firewall_service_enabled ip6tables.service; then
                vps_cmd_run service ip6tables save || return 20
            fi
            ;;
        *) return 70 ;;
    esac
}

access_firewall_has_port() {
    local backend="$1" port="$2"

    case "$backend" in
        none) return 1 ;;
        ufw) access_firewall_ufw_has_port "$port" ;;
        firewalld)
            firewall-cmd --quiet --query-port="${port}/tcp" >/dev/null 2>&1 ||
                access_firewall_firewalld_has_owned_port "$port"
            ;;
        nftables) access_firewall_nft_has_port "$port" ;;
        iptables) access_firewall_iptables_has_owned_port "$port" ;;
        *) return 1 ;;
    esac
}

access_firewall_open() {
    local backend="$1" port="$2" old_port="${3:-}" require_owned="${4:-0}" runtime_had=0 permanent_had=0 added_runtime=0 added_permanent=0 ipv6_added=0 rule zone

    ACCESS_FW_ADDED=0
    if [[ "$backend" != firewalld ]]; then
        if [[ "$require_owned" == 1 ]] && access_firewall_has_owned_port "$backend" "$port"; then
            vps_cmd_info "防火墙中已存在 vpsctl 自有的 TCP $port 规则"
            return 0
        elif [[ "$require_owned" != 1 ]] && access_firewall_has_port "$backend" "$port"; then
            vps_cmd_info "防火墙已允许 TCP $port"
            return 0
        fi
    fi
    case "$backend" in
        none)
            vps_cmd_warning "未检测到活动防火墙；未添加端口规则"
            return 0
            ;;
        ufw)
            vps_cmd_run ufw allow "${port}/tcp" comment 'vpsctl security access' || return 20
            [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]] || access_firewall_ufw_has_owned_port "$port" || {
                vps_cmd_error "UFW 未返回带 vpsctl 标记的规则，拒绝记录所有权"
                return 30
            }
            ;;
        firewalld)
            rule="$(access_firewall_firewalld_rule "$port")"
            zone="$(access_firewall_firewalld_active_zone)" || return $?
            if [[ "$require_owned" == 1 ]]; then
                access_firewall_firewalld_has_owned_port "$port" runtime "$zone" && runtime_had=1
                access_firewall_firewalld_has_owned_port "$port" permanent "$zone" && permanent_had=1
            else
                firewall-cmd --quiet --zone="$zone" --query-port="${port}/tcp" >/dev/null 2>&1 && runtime_had=1
                access_firewall_firewalld_has_owned_port "$port" runtime "$zone" && runtime_had=1
                firewall-cmd --quiet --permanent --zone="$zone" --query-port="${port}/tcp" >/dev/null 2>&1 && permanent_had=1
                access_firewall_firewalld_has_owned_port "$port" permanent "$zone" && permanent_had=1
            fi
            if ((runtime_had != permanent_had)); then
                vps_cmd_error "firewalld 的 TCP $port 仅存在于 runtime/permanent 之一；拒绝 auto 改写半持久状态"
                return 3
            fi
            if ((runtime_had == 1)); then
                vps_cmd_info "firewalld runtime 与 permanent 均已允许 TCP $port"
                return 0
            fi
            if ((runtime_had == 0)); then
                vps_cmd_run firewall-cmd --quiet --zone="$zone" --add-rich-rule="$rule" || return 20
                added_runtime=1
            fi
            if ((permanent_had == 0)); then
                if ! vps_cmd_run firewall-cmd --quiet --permanent --zone="$zone" --add-rich-rule="$rule"; then
                    ((added_runtime == 0)) || vps_cmd_run firewall-cmd --quiet --zone="$zone" --remove-rich-rule="$rule" || true
                    return 20
                fi
                added_permanent=1
            fi
            ACCESS_FW_ADDED="firewalld-r${added_runtime}-p${added_permanent}"
            ;;
        nftables)
            access_firewall_nft_apply "$port" "$old_port" "$ACCESS_FW_NFT_MODE" || return $?
            ACCESS_FW_ADDED="nft-${ACCESS_FW_NFT_MODE}"
            ;;
        iptables)
            vps_cmd_run iptables -I INPUT 1 -p tcp --dport "$port" -m comment --comment "vpsctl-access-${port}" -j ACCEPT || return 20
            if command -v ip6tables >/dev/null 2>&1 && ip6tables -S >/dev/null 2>&1; then
                if ! vps_cmd_run ip6tables -I INPUT 1 -p tcp --dport "$port" -m comment --comment "vpsctl-access-${port}" -j ACCEPT; then
                    vps_cmd_run iptables -D INPUT -p tcp --dport "$port" -m comment --comment "vpsctl-access-${port}" -j ACCEPT || true
                    return 20
                fi
                ipv6_added=1
            fi
            if ! access_firewall_iptables_save; then
                vps_cmd_run iptables -D INPUT -p tcp --dport "$port" -m comment --comment "vpsctl-access-${port}" -j ACCEPT || true
                ((ipv6_added == 0)) || vps_cmd_run ip6tables -D INPUT -p tcp --dport "$port" -m comment --comment "vpsctl-access-${port}" -j ACCEPT || true
                access_firewall_iptables_save >/dev/null 2>&1 || true
                return 20
            fi
            ACCESS_FW_ADDED="iptables-v6${ipv6_added}"
            ;;
        *) return 70 ;;
    esac
    [[ "$ACCESS_FW_ADDED" != 0 ]] || ACCESS_FW_ADDED=1
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：将通过 $backend 开放 TCP $port；未执行运行时存在性检查"
        return 0
    fi
    access_firewall_has_port "$backend" "$port" || return 30
    vps_cmd_success "已通过 $backend 开放 TCP $port"
}

access_firewall_close() {
    local backend="$1" port="$2" owned="${3:-0}" mode="${4:-auto}" rule number removed=0 zone zones
    local -a numbers=()

    case "$backend" in
        none | '') return 0 ;;
        ufw)
            [[ "$owned" == 1 ]] || {
                vps_cmd_error "拒绝删除没有 vpsctl 所有权记录的 UFW 规则"
                return 30
            }
            mapfile -t numbers < <(access_firewall_ufw_owned_numbers "$port")
            if ((${#numbers[@]} == 0)); then
                access_firewall_has_port ufw "$port" && {
                    vps_cmd_error "UFW 所有权标记已漂移；不会删除同端口的其他规则"
                    return 30
                }
                return 0
            fi
            for number in "${numbers[@]}"; do
                vps_cmd_run ufw --force delete "$number" || return 20
            done
            ;;
        firewalld)
            [[ "$owned" == 1 ]] || {
                vps_cmd_error "拒绝删除没有 vpsctl 所有权记录的 firewalld 规则"
                return 30
            }
            rule="$(access_firewall_firewalld_rule "$port")"
            zones="$(firewall-cmd --get-zones 2>/dev/null)" || return 20
            while IFS= read -r zone; do
                [[ -n "$zone" ]] || continue
                if access_firewall_firewalld_has_owned_port "$port" runtime "$zone"; then
                    vps_cmd_run firewall-cmd --quiet --zone="$zone" --remove-rich-rule="$rule" || return 20
                fi
                if access_firewall_firewalld_has_owned_port "$port" permanent "$zone"; then
                    vps_cmd_run firewall-cmd --quiet --permanent --zone="$zone" --remove-rich-rule="$rule" || return 20
                fi
            done < <(tr ' ' '\n' <<<"$zones")
            ;;
        nftables)
            [[ "$owned" == 1 ]] || {
                vps_cmd_error "拒绝删除没有 vpsctl 所有权记录的 nftables 规则"
                return 30
            }
            access_firewall_nft_delete_owned_rules || return $?
            local nft_file
            nft_file="$(access_firewall_nft_file)" || return $?
            if [[ -e "$nft_file" ]]; then
                [[ "$mode" != runtime ]] || {
                    vps_cmd_error "运行时 nftables 状态与持久化片段发生冲突；拒绝删除未知来源文件"
                    return 30
                }
                access_firewall_nft_validate_file "$nft_file" || return 30
                vps_cmd_run rm -f -- "$nft_file" || return 20
            fi
            ;;
        iptables)
            [[ "$owned" == 1 ]] || {
                vps_cmd_error "拒绝删除没有 vpsctl 所有权记录的 iptables 规则"
                return 30
            }
            if iptables -C INPUT -p tcp --dport "$port" -m comment --comment "vpsctl-access-${port}" -j ACCEPT >/dev/null 2>&1; then
                vps_cmd_run iptables -D INPUT -p tcp --dport "$port" -m comment --comment "vpsctl-access-${port}" -j ACCEPT || return 20
                removed=1
            fi
            if command -v ip6tables >/dev/null 2>&1 && ip6tables -C INPUT -p tcp --dport "$port" -m comment --comment "vpsctl-access-${port}" -j ACCEPT >/dev/null 2>&1; then
                vps_cmd_run ip6tables -D INPUT -p tcp --dport "$port" -m comment --comment "vpsctl-access-${port}" -j ACCEPT || return 20
                removed=1
            fi
            if ((removed)); then
                access_firewall_iptables_save || return $?
            fi
            ;;
        *) return 70 ;;
    esac
}

access_firewall_write_state() {
    local backend="$1" port="$2" mode="${3:-}" tmp

    if [[ -z "$backend" || -z "$port" || "$backend" == none ]]; then
        [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]] || rm -f -- "$ACCESS_FW_STATE"
        return 0
    fi
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    tmp="$(mktemp --tmpdir="$ACCESS_STATE_DIR" .firewall.XXXXXX)" || return 20
    {
        access_kv_put schema_version 2
        access_kv_put backend "$backend"
        access_kv_put port "$port"
        access_kv_put owned 1
        access_kv_put mode "$mode"
    } >"$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    chmod 0644 -- "$tmp" || {
        rm -f -- "$tmp"
        return 20
    }
    mv -f -- "$tmp" "$ACCESS_FW_STATE" || {
        rm -f -- "$tmp"
        return 20
    }
}

access_firewall_commit() {
    local backend="$1" old_port="$2" new_port="$3" added="$4" previous_backend="$5" previous_port="$6" previous_mode="${7:-}" mode=''

    if [[ "$backend" == nftables ]]; then
        case "$added" in
            nft-runtime) mode=runtime ;;
            nft-persistent) mode=persistent ;;
            *) mode="${previous_mode:-auto}" ;;
        esac
        access_firewall_nft_apply "$new_port" '' "$mode" || return $?
    elif [[ "$old_port" != "$new_port" && "$previous_backend" == "$backend" && "$previous_port" == "$old_port" ]]; then
        access_firewall_close "$backend" "$old_port" 1 || return $?
    fi
    if [[ "$added" != 0 || "$previous_backend:$previous_port" == "$backend:$new_port" ]]; then
        access_firewall_write_state "$backend" "$new_port" "$mode"
    else
        access_firewall_write_state '' ''
    fi
}

access_firewall_abort() {
    local backend="$1" new_port="$2" added="$3" previous_backend="${4:-}" previous_port="${5:-}" previous_mode="${6:-}" mode=auto

    [[ "$added" != 0 ]] || return 0
    case "$added" in
        nft-runtime) mode=runtime ;;
        nft-persistent) mode=persistent ;;
    esac
    if [[ "$backend" == nftables && "$previous_backend" == nftables && -n "$previous_port" ]]; then
        access_firewall_nft_apply "$previous_port" '' "${previous_mode:-auto}"
        return $?
    fi
    access_firewall_close "$backend" "$new_port" 1 "$mode"
}
