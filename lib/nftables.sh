# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034
# Native nftables state and transactions. Sourcing never changes the firewall.
# Call command.sh first; mutating APIs must run in the calling shell.

vps_nft_init() {
    local directory
    directory="$(vps_cmd_system_path /var/lib/vpsctl/network/nftables)" || return $?
    [[ "${VPS_NFT_STATE_DIR:-}" != "$directory" ]] || return 0
    [[ "${VPS_NFT_DEPTH:-0}" == 0 && "${VPS_NFT_LOCK_COUNT:-0}" == 0 ]] || return 70
    VPS_NFT_STATE_DIR="$directory"
    VPS_NFT_STATE_FILE="$directory/state.json"
    VPS_NFT_APPLIED_FILE="$directory/applied.json"
    VPS_NFT_JOURNAL="$directory/pending.json"
    VPS_NFT_LOCK_PATH="$(vps_cmd_system_path /run/vpsctl/network-nftables.lock)" || return $?
    VPS_NFT_LIB_DIR="${BASH_SOURCE[0]%/*}/nftables"
    VPS_NFT_LOCK_FD='' VPS_NFT_PROCESS='' VPS_NFT_WORK=''
    VPS_NFT_LOCK_COUNT=0 VPS_NFT_DEPTH=0
    VPS_NFT_FRAMES=() VPS_NFT_MODES=()
}

vps_nft_require_tools() { vps_cmd_ensure_tools network-nftables jq flock sha256sum; }

vps_nft_lock() {
    local status
    vps_nft_init || return $?
    if ((${VPS_NFT_LOCK_COUNT:-0} > 0)); then
        [[ "$VPS_NFT_PROCESS" == "$BASHPID" ]] || return 70
        VPS_NFT_LOCK_COUNT=$((VPS_NFT_LOCK_COUNT + 1))
        return 0
    fi
    VPS_NFT_PROCESS="$BASHPID"
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        VPS_NFT_LOCK_COUNT=1
        return 0
    fi
    vps_cmd_require_no_symlink_components "$VPS_NFT_LOCK_PATH" || return $?
    [[ ! -e "$VPS_NFT_LOCK_PATH" || -f "$VPS_NFT_LOCK_PATH" ]] || return 3
    mkdir -p -- "${VPS_NFT_LOCK_PATH%/*}" || return 20
    exec {VPS_NFT_LOCK_FD}>"$VPS_NFT_LOCK_PATH" || return 20
    if ! flock -n "$VPS_NFT_LOCK_FD"; then
        exec {VPS_NFT_LOCK_FD}>&-
        VPS_NFT_LOCK_FD=''
        vps_cmd_error '另一个 nftables 操作正在运行'
        return 3
    fi
    VPS_NFT_LOCK_COUNT=1
    if [[ -e "$VPS_NFT_JOURNAL" && "${VPS_NFT_DEPTH:-0}" == 0 ]]; then
        _vps_nft_recover || {
            status=$?
            vps_nft_unlock
            return "$status"
        }
    fi
}

vps_nft_unlock() {
    ((${VPS_NFT_LOCK_COUNT:-0} > 0)) || return 0
    [[ "$VPS_NFT_PROCESS" == "$BASHPID" ]] || return 70
    VPS_NFT_LOCK_COUNT=$((VPS_NFT_LOCK_COUNT - 1))
    ((VPS_NFT_LOCK_COUNT == 0)) || return 0
    if [[ -n "$VPS_NFT_LOCK_FD" ]]; then
        flock -u "$VPS_NFT_LOCK_FD" || true
        exec {VPS_NFT_LOCK_FD}>&-
    fi
    VPS_NFT_LOCK_FD='' VPS_NFT_PROCESS=''
}

vps_nft_is_active() {
    local tables
    command -v nft >/dev/null 2>&1 || return 1
    tables="$(nft -j list tables)" || {
        vps_cmd_error '无法读取 nftables 运行表，未改变防火墙'
        return 20
    }
    jq -e 'any(.nftables[]; .table.family=="inet" and .table.name=="vpsctl_firewall")' <<<"$tables" >/dev/null
}

vps_nft_enabled() {
    local state
    state="$(vps_nft_state)" || return $?
    jq -e '.enabled' <<<"$state" >/dev/null
}
vps_nft_ipv6_available() {
    local path
    path="$(vps_cmd_system_path /proc/sys/net/ipv6/conf/all/disable_ipv6)" || return $?
    [[ "${VPSCTL_TESTING:-0}" == 1 && ! -e "$path" ]] && return 0
    [[ -r "$path" && "$(<"$path")" == 0 ]]
}
vps_nft_ipv6_enabled() { vps_nft_ipv6_available; }

# Validation is independent of nft parsing and rejects shell/nft metacharacters.
_vps_nft_address() {
    local value="${1,,}" prefix='' host left right part expanded='' zeros index tail
    local -a pieces=() before=() after=()
    case "$value" in any | 0.0.0.0/0 | ::/0)
        printf 'any'
        return 0
        ;;
    esac
    if [[ "$value" == */* ]]; then
        prefix="${value#*/}"
        value="${value%/*}"
        [[ -n "$prefix" ]] || return 2
    fi
    [[ -z "$prefix" || "$prefix" =~ ^[0-9]{1,3}$ ]] || return 2
    if [[ "$value" == *:* ]]; then
        if [[ "$value" == *.* ]]; then
            tail="$(_vps_nft_address "${value##*:}")" || return 2
            IFS=. read -r -a pieces <<<"$tail"
            ((${#pieces[@]} == 4)) || return 2
            printf -v tail '%x:%x' "$((pieces[0] * 256 + pieces[1]))" "$((pieces[2] * 256 + pieces[3]))"
            value="${value%:*}:$tail"
        fi
        [[ "$value" =~ ^[0-9a-f:]+$ && "$value" != *:::* ]] || return 2
        [[ "$value" != :* || "$value" == ::* ]] || return 2
        [[ "$value" != *: || "$value" == *:: ]] || return 2
        [[ -z "$prefix" ]] || ((10#$prefix <= 128)) || return 2
        if [[ "$value" == *::* ]]; then
            left="${value%%::*}"
            right="${value#*::}"
            [[ "$right" != *::* ]] || return 2
            IFS=: read -r -a before <<<"$left"
            IFS=: read -r -a after <<<"$right"
            zeros=$((8 - ${#before[@]} - ${#after[@]}))
            ((zeros >= 1)) || return 2
            pieces=("${before[@]}")
            for ((index = 0; index < zeros; index++)); do pieces+=(0); done
            pieces+=("${after[@]}")
        else
            [[ "$value" != :* && "$value" != *: ]] || return 2
            IFS=: read -r -a pieces <<<"$value"
            ((${#pieces[@]} == 8)) || return 2
        fi
        for part in "${pieces[@]}"; do
            [[ "$part" =~ ^[0-9a-f]{1,4}$ ]] || return 2
            printf -v host '%04x' "$((16#$part))"
            expanded+="${expanded:+:}$host"
        done
        [[ -z "$prefix" || "$prefix" == 128 ]] || expanded+="/$((10#$prefix))"
    else
        [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
        IFS=. read -r -a pieces <<<"$value"
        [[ -z "$prefix" ]] || ((10#$prefix <= 32)) || return 2
        for part in "${pieces[@]}"; do
            [[ "$part" =~ ^[0-9]{1,3}$ ]] && ((10#$part <= 255)) || return 2
            expanded+="${expanded:+.}$((10#$part))"
        done
        [[ -z "$prefix" || "$prefix" == 32 ]] || expanded+="/$((10#$prefix))"
    fi
    printf '%s' "$expanded"
}

vps_nft_validate_source() {
    local value="${1:-}" family="${2:-both}" item
    local -a items=()
    [[ "$family" == both || "$family" == ipv4 || "$family" == ipv6 ]] || return 2
    [[ "$value" == any ]] && return 0
    [[ "$value" =~ ^[a-fA-F0-9.:/]+(,[a-fA-F0-9.:/]+)*$ ]] || return 2
    IFS=, read -r -a items <<<"$value"
    for item in "${items[@]}"; do
        _vps_nft_address "$item" >/dev/null || return 2
        [[ "$family" != ipv4 || "$item" != *:* ]] || return 2
        [[ "$family" != ipv6 || "$item" == *:* ]] || return 2
    done
}

vps_nft_validate_port() {
    local value="${1:-}" item low high
    local -a items=()
    [[ "$value" == any ]] && return 0
    [[ "$value" =~ ^[0-9]{1,5}(-[0-9]{1,5})?(,[0-9]{1,5}(-[0-9]{1,5})?)*$ ]] || return 2
    IFS=, read -r -a items <<<"$value"
    for item in "${items[@]}"; do
        low="${item%-*}"
        high="${item##*-}"
        ((10#$low >= 1 && 10#$high <= 65535 && 10#$low <= 10#$high)) || return 2
    done
}

vps_nft_validate_state() {
    local file="$1" value family record
    vps_nft_init || return $?
    [[ -f "$file" && ! -L "$file" ]] || return 2
    jq -e -f "$VPS_NFT_LIB_DIR/schema.jq" "$file" >/dev/null || {
        vps_cmd_error 'nftables 状态或规则格式无效'
        return 2
    }
    while IFS= read -r record; do
        family="$(jq -r '.family' <<<"$record")"
        while IFS= read -r value; do
            vps_nft_validate_source "$value" "$family" || return 2
        done < <(jq -r '.source, (.destination // empty), (.original_destination // empty)' <<<"$record")
    done < <(jq -c '.rules[],.limits[],.requirements[]' "$file")
}

_vps_nft_validate_item() {
    local kind="$1" json="$2" file status=0
    file="$(mktemp)" || return 20
    jq -n --arg kind "$kind" --argjson item "$json" '{schema_version:1,revision:0,enabled:false,logging:false,rules:[],limits:[],requirements:[],links:{},leases:{}} | .[$kind]=[$item]' >"$file" || status=2
    [[ "$status" != 0 ]] || vps_nft_validate_state "$file" || status=$?
    rm -f -- "$file"
    return "$status"
}
vps_nft_validate_rule() { _vps_nft_validate_item rules "$1"; }
vps_nft_validate_limit() { _vps_nft_validate_item limits "$1"; }

vps_nft_state() {
    vps_nft_init || return $?
    vps_cmd_require_no_symlink_components "$VPS_NFT_STATE_FILE" || return $?
    if [[ ! -e "$VPS_NFT_STATE_FILE" ]]; then
        printf '%s\n' '{"schema_version":1,"revision":0,"enabled":false,"logging":false,"rules":[],"limits":[],"requirements":[],"links":{},"leases":{}}'
    else
        vps_nft_validate_state "$VPS_NFT_STATE_FILE" || return 3
        cat -- "$VPS_NFT_STATE_FILE"
    fi
}
_vps_nft_state() { vps_nft_state; }

vps_nft_save_state() {
    vps_nft_validate_state "$1" || return $?
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    vps_cmd_require_no_symlink_components "$VPS_NFT_STATE_DIR" || return $?
    [[ ! -e "$VPS_NFT_STATE_FILE" || -f "$VPS_NFT_STATE_FILE" ]] || return 3
    mkdir -p -- "$VPS_NFT_STATE_DIR" || return 20
    chmod 0700 -- "$VPS_NFT_STATE_DIR" || return 20
    vps_cmd_atomic_write /var/lib/vpsctl/network/nftables/state.json 0600 <"$1"
}

_vps_nft_save() {
    local file status=0
    file="$(mktemp)" || return 20
    cat >"$file" || status=20
    [[ "$status" != 0 ]] || vps_nft_save_state "$file" || status=$?
    rm -f -- "$file"
    return "$status"
}

_vps_nft_runtime_manifest() {
    local table marker digest file
    table="$(nft -j list table inet vpsctl_firewall)" || return 3
    marker="$(jq -r '[.nftables[].set.name? | select(.!=null) |
      select(test("^generation_[a-f0-9]{64}$"))] | if length==1 then .[0] else empty end' <<<"$table")" || return 3
    if [[ -n "$marker" ]]; then
        vps_cmd_require_no_symlink_components "$VPS_NFT_STATE_DIR/plans/${marker#generation_}.json" || return $?
        [[ -f "$VPS_NFT_STATE_DIR/plans/${marker#generation_}.json" ]] || {
            vps_cmd_error '运行中的 nftables 版本缺少恢复清单'
            return 3
        }
        file="$VPS_NFT_STATE_DIR/plans/${marker#generation_}.json"
        digest="$(jq -cS '.sets|=with_entries(select(.key|startswith("generation_")|not))' "$file" | sha256sum)" || return 3
        [[ "${digest%% *}" == "${marker#generation_}" ]] || return 3
        cat -- "$file"
    elif [[ -f "$VPS_NFT_APPLIED_FILE" ]] && ! jq -e '.sets|keys|any(startswith("generation_"))' "$VPS_NFT_APPLIED_FILE" >/dev/null; then
        # One-time compatibility with an earlier native manifest format.
        cat -- "$VPS_NFT_APPLIED_FILE"
    else
        vps_cmd_error 'nftables 运行表缺少可验证的版本标记'
        return 3
    fi
}

_vps_nft_stage_manifest() {
    local file="$1" digest temp
    digest="$(jq -cS '.sets|=with_entries(select(.key|startswith("generation_")|not))' "$file" | sha256sum)" || return 20
    digest="${digest%% *}"
    temp="$file.staged"
    jq --arg name "generation_$digest" '.sets|=with_entries(select(.key|startswith("generation_")|not)) |
      .sets[$name]={definition:"type mark;",dynamic:false,elements:[]}' "$file" >"$temp" || return 20
    mv -- "$temp" "$file" || return 20
    vps_cmd_require_no_symlink_components "$VPS_NFT_STATE_DIR/plans" || return $?
    mkdir -p -- "$VPS_NFT_STATE_DIR/plans" || return 20
    chmod 0700 -- "$VPS_NFT_STATE_DIR" "$VPS_NFT_STATE_DIR/plans" || return 20
    vps_cmd_atomic_write "/var/lib/vpsctl/network/nftables/plans/$digest.json" 0600 <"$file"
}

_vps_nft_gc_plans() {
    local marker file
    marker="$(jq -r '.sets|keys[]|select(startswith("generation_"))' "$VPS_NFT_APPLIED_FILE")" || return 20
    # Runtime markers reference immutable plans, so a failed metadata commit
    # must retain its staged plan until a successful commit or rollback.
    for file in "$VPS_NFT_STATE_DIR"/plans/*.json; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        [[ "${file##*/}" == "${marker#generation_}.json" ]] || rm -f -- "$file" || return 20
    done
}

# Prepare is read-only with respect to managed state and runtime. The caller can
# append another owner's batch and publish both owners in one nft transaction.
vps_nft_prepare_state() {
    local file="$1" directory="$2" mode="${3:-auto}" active=false status=0 old
    vps_nft_validate_state "$file" || return $?
    if [[ "$mode" == force ]] || jq -e '.enabled' "$file" >/dev/null; then
        vps_cmd_ensure_tools network-nftables nft || return $?
    fi
    vps_cmd_require_no_symlink_components "$directory" || return $?
    mkdir -p -- "$directory" || return 20
    chmod 0700 -- "$directory" || return 20
    [[ "$file" == "$directory/state.json" ]] || cp -- "$file" "$directory/state.json" || return 20
    if vps_nft_is_active; then active=true; else
        status=$?
        [[ "$status" == 1 ]] || return "$status"
    fi
    printf '%s\n' '{"sets":{},"chains":{}}' >"$directory/old.json" || return 20
    if [[ "$active" == true ]]; then
        _vps_nft_runtime_manifest >"$directory/old.json" || return $?
    fi
    if [[ "$mode" != force ]] && ! jq -e '.enabled' "$file" >/dev/null; then
        cp -- "$directory/old.json" "$directory/manifest.json" || return 20
        printf '%s\n' '{"sets":{},"chains":{}}' >"$directory/manifest.json" || return 20
        : >"$directory/batch.nft"
        [[ "$active" != true ]] || printf 'delete table inet vpsctl_firewall\n' >"$directory/batch.nft"
        return 0
    fi
    jq --argjson now "$(date +%s)" -f "$VPS_NFT_LIB_DIR/render.jq" "$file" >"$directory/manifest.json" || return 20
    _vps_nft_stage_manifest "$directory/manifest.json" || return $?
    old="$directory/old.json"
    jq -r --slurpfile old "$old" --argjson exists "$active" --argjson now "$(date +%s)" \
        -f "$VPS_NFT_LIB_DIR/reconcile.jq" "$directory/manifest.json" >"$directory/batch.nft" || return 20
}

vps_nft_commit_prepared() {
    local directory="$1"
    vps_nft_save_state "$directory/state.json" || return $?
    _vps_nft_save_applied "$directory/manifest.json" || return $?
    _vps_nft_gc_plans
}

_vps_nft_save_applied() {
    [[ ! -e "$VPS_NFT_APPLIED_FILE" || -f "$VPS_NFT_APPLIED_FILE" ]] || return 20
    vps_cmd_atomic_write /var/lib/vpsctl/network/nftables/applied.json 0600 <"$1"
}

_vps_nft_apply_file() {
    local file="$1" mode="${2:-auto}" work status=0
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    work="$(mktemp -d)" || return 20
    vps_nft_prepare_state "$file" "$work" "$mode" || status=$?
    if [[ "$status" == 0 && -s "$work/batch.nft" ]]; then
        nft -c -f "$work/batch.nft" && nft -f "$work/batch.nft" || status=20
    fi
    if [[ "$status" == 0 ]]; then
        mkdir -p -- "$VPS_NFT_STATE_DIR" || status=20
        [[ "$status" != 0 ]] || _vps_nft_save_applied "$work/manifest.json" || status=20
        [[ "$status" != 0 ]] || _vps_nft_gc_plans || status=20
    fi
    rm -f -- "$work/state.json" "$work/manifest.json" "$work/old.json" "$work/batch.nft"
    rmdir -- "$work" || true
    return "$status"
}

vps_nft_apply() {
    local state status=0
    vps_nft_lock || return $?
    state="$(vps_nft_state)" || status=$?
    [[ "$status" != 0 ]] || state="$(_vps_nft_prune_leases "$state")" || status=$?
    [[ "$status" != 0 ]] || printf '%s\n' "$state" | _vps_nft_save || status=$?
    [[ "$status" != 0 ]] || _vps_nft_apply_file "$VPS_NFT_STATE_FILE" || status=$?
    vps_nft_unlock
    return "$status"
}

vps_nft_clear() {
    local status=0 file
    vps_nft_lock || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        if vps_nft_is_active; then
            file="$(mktemp)" || {
                vps_nft_unlock
                return 20
            }
            printf 'delete table inet vpsctl_firewall\n' >"$file"
            nft -c -f "$file" && nft -f "$file" || status=20
            rm -f -- "$file"
        else
            status=$?
            [[ "$status" != 1 ]] || status=0
        fi
        [[ "$status" != 0 ]] || rm -f -- "$VPS_NFT_APPLIED_FILE" || status=20
    fi
    vps_nft_unlock
    return "$status"
}

vps_nft_proxy_nodes_requirements() {
    jq -e --argjson ipv6 "$2" '
      def protocols: if .=="hysteria2" or .=="tuic-v5" then ["udp"]
        elif startswith("shadowsocks-") then ["tcp","udp"] else ["tcp"] end;
      [.nodes[] as $n | $n.listen as $listen | select(($listen|startswith("127."))|not) | select($listen!="::1") |
        (if $listen=="::" then if $ipv6 then ["ipv4","ipv6"] else ["ipv4"] end
         elif $listen|contains(":") then ["ipv6"] else ["ipv4"] end)[] as $family |
        ($n.profile|protocols)[] as $proto |
        {owner:("node:"+$n.id),kind:"input",family:$family,proto:$proto,port:($n.port|tostring),source:"any",
         destination:(if $listen=="::" or $listen=="0.0.0.0" then "any" else $listen end),temporary:false} as $r |
        $r, (if $n.profile=="hysteria2" and ($n.options.hop_ports//"")!="" then
          $r+{original_port:$n.options.hop_ports,original_destination:$r.destination} else empty end)]
    ' <<<"$1"
}

vps_nft_proxy_forwards_requirements() {
    jq -e --argjson cache "$2" '
      . as $root | [.forwards[] as $f | ([$root.exits[]|select(.id==$f.exit_id)][0]) as $exit |
      (if $f.network=="auto" then ($exit.protocol.network_hint//$exit.network_hint) else $f.network end) as $network |
      (if $network=="both" then ["tcp","udp"] elif $network=="tcp" or $network=="udp" then [$network] else error("invalid forward protocol") end)[] as $proto |
      (if $f.family=="dual" then ["ipv4","ipv6"] else [$f.family] end)[] as $family |
      ($cache.exits[$f.exit_id][$family]//"") as $address | select($address!="") |
      {owner:("forward:"+$f.id),kind:"route",family:$family,proto:$proto,port:($exit.endpoint.port|tostring),
       source:"any",destination:$address,temporary:false,
       original_port:([$f.listen_port_start,$f.listen_port_end]|unique|map(tostring)|join("-")),original_destination:"any"}]
    ' <<<"$1"
}

# shellcheck source=nftables/transactions.sh
source "${BASH_SOURCE[0]%/*}/nftables/transactions.sh"
