# shellcheck shell=bash
# shellcheck disable=SC2016

vps_nft_lease_metadata() {
    local pid="$BASHPID" boot='' start='' stat=''
    [[ ! -r /proc/sys/kernel/random/boot_id ]] || boot="$(</proc/sys/kernel/random/boot_id)"
    if [[ -r "/proc/$pid/stat" ]]; then
        stat="$(<"/proc/$pid/stat")"
        start="$(awk '{print $20}' <<<"${stat##*) }")"
    fi
    [[ -n "$boot" && "$start" =~ ^[0-9]+$ ]] || return 3
    VPS_NFT_LEASE_JSON="$(jq -cn --argjson pid "$pid" --arg boot_id "$boot" --arg start_time "$start" \
        '{pid:$pid,boot_id:$boot_id,start_time:$start_time}')"
}

_vps_nft_prune_leases() {
    local state="$1" record owner pid boot start stat actual
    local -a expired=()
    while IFS= read -r record; do
        owner="$(jq -r '.key' <<<"$record")"
        pid="$(jq -r '.value.pid' <<<"$record")"
        boot="$(jq -r '.value.boot_id' <<<"$record")"
        start="$(jq -r '.value.start_time' <<<"$record")"
        actual=''
        if [[ -r "/proc/$pid/stat" && -r /proc/sys/kernel/random/boot_id && "$boot" == "$(</proc/sys/kernel/random/boot_id)" ]]; then
            stat="$(<"/proc/$pid/stat")"
            actual="$(awk '{print $20}' <<<"${stat##*) }")"
        fi
        [[ -z "$actual" || "$actual" != "$start" ]] || continue
        expired+=("$owner")
    done < <(jq -c '.leases|to_entries[]' <<<"$state")
    jq -e --args '(reduce $ARGS.positional[] as $o ({};.[$o]=true)) as $expired |
      .leases |= with_entries(select($expired[.key]!=true)) |
      .requirements |= map(select(.temporary!=true or $expired[.owner]!=true))' -- "${expired[@]}" <<<"$state"
}

_vps_nft_normalize_desired() {
    local file="$1" scope="$2" candidate status=0
    [[ -f "$file" && ! -L "$file" ]] || return 2
    candidate="$(mktemp)" || return 20
    jq -n --arg scope "$scope" --slurpfile desired "$file" '
      {schema_version:1,revision:0,enabled:false,logging:false,rules:[],limits:[],links:{},leases:{},
       requirements:($desired[0]|map(. + {scope:$scope,source:(.source//"any"),destination:(.destination//"any"),
         port:(.port|gsub(":";"-")),temporary:(.temporary//false),interfaces:(.interfaces//{in:"",out:""})})|unique)}' >"$candidate" || status=2
    [[ "$status" != 0 ]] || vps_nft_validate_state "$candidate" || status=$?
    [[ "$status" != 0 ]] || jq '.requirements' "$candidate" || status=20
    rm -f -- "$candidate"
    return "$status"
}

vps_nft_inventory() {
    local state
    state="$(vps_nft_state)" || return $?
    state="$(_vps_nft_prune_leases "$state")" || return $?
    jq '. as $s | [.rules[] | . + {owners:[],kind:"input",origin:"manual"}] +
      ([.requirements[]|select($s.links[.owner].detached!=true)] |
       group_by({kind,family,proto,port,source,destination,original_port,original_destination,interfaces}) |
       map(.[0] + {id:("service:"+(.[0].owner)+":"+(.[0].family)+":"+(.[0].proto)+":"+(.[0].port)),
         action:"allow",origin:"service",owners:([.[].owner]|unique)} | del(.owner,.scope)))' <<<"$state"
}
vps_nft_links() {
    local state
    state="$(vps_nft_state)" || return $?
    jq '[((.links|keys)+[.requirements[].owner]|unique)[] as $o |
      {owner:$o,detached:(.links[$o].detached//false),scope:(.links[$o].scope//""),
       requirements:[.requirements[]|select(.owner==$o)|del(.scope)]}]' <<<"$state"
}
vps_nft_owner_detached() {
    local state
    state="$(vps_nft_state)" || return $?
    jq -e --arg owner "$1" '.links[$owner].detached==true' <<<"$state" >/dev/null
}
vps_nft_scope_desired() {
    local state
    state="$(vps_nft_state)" || return $?
    jq --arg scope "$1" '[.requirements[]|select(.scope==$scope)|del(.scope)]' <<<"$state"
}
vps_nft_rule_protected() {
    local rules
    rules="$(vps_nft_inventory)" || return $?
    jq -e --arg id "$1" 'any(.[];.id==$id and (.owners|length)>0)' <<<"$rules" >/dev/null
}

vps_nft_snapshot() {
    local directory="$1" active=false status=0
    ((${VPS_NFT_LOCK_COUNT:-0} > 0)) || return 70
    vps_cmd_require_no_symlink_components "$directory" || return $?
    mkdir -p -- "$directory" || return 20
    chmod 0700 -- "$directory" || return 20
    vps_nft_state >"$directory/state.json" || return $?
    if vps_nft_is_active; then active=true; else
        status=$?
        [[ "$status" == 1 ]] || return "$status"
    fi
    if [[ "$active" == true ]]; then _vps_nft_runtime_manifest >"$directory/manifest.json" || return $?; fi
    jq -n --argjson active "$active" '{version:1,active:$active}' >"$directory/snapshot.json" || return 20
    chmod 0600 -- "$directory/state.json" "$directory/snapshot.json"
}

vps_nft_prepare_restore() {
    local snapshot="$1" directory="$2" mode=auto
    vps_cmd_require_no_symlink_components "$snapshot" || return $?
    jq -e '.version==1 and (.active|type)=="boolean"' "$snapshot/snapshot.json" >/dev/null || return 3
    if jq -e '.active' "$snapshot/snapshot.json" >/dev/null; then mode=force; fi
    if [[ "$mode" == auto ]]; then
        # Runtime activation is independently snapshotted: a force preparation
        # can create a table while the persisted enabled flag is still false.
        mkdir -p -- "$directory" || return 20
        jq '.enabled=false' "$snapshot/state.json" >"$directory/restore-state.json" || return 20
        vps_nft_prepare_state "$directory/restore-state.json" "$directory" || return $?
        cp -- "$snapshot/state.json" "$directory/state.json" || return 20
    else
        vps_nft_prepare_state "$snapshot/state.json" "$directory" force || return $?
        if [[ -f "$snapshot/manifest.json" ]]; then
            jq --argjson now "$(date +%s)" '.sets[].elements |= map(select(.expires_at==0 or .expires_at>$now))' \
                "$snapshot/manifest.json" >"$directory/manifest.json" || return 20
            _vps_nft_stage_manifest "$directory/manifest.json" || return $?
            jq -r --slurpfile old "$directory/old.json" --argjson exists "$(jq '.chains|length>0' "$directory/old.json")" --argjson now "$(date +%s)" \
                -f "$VPS_NFT_LIB_DIR/reconcile.jq" "$directory/manifest.json" >"$directory/batch.nft" || return 20
        fi
    fi
}

vps_nft_restore() {
    local directory="$1" mode="${2:-runtime}" work status=0
    if [[ "$mode" == config-only ]]; then
        vps_nft_save_state "$directory/state.json"
        return $?
    fi
    [[ "$mode" == runtime ]] || return 2
    work="$(mktemp -d)" || return 20
    vps_nft_prepare_restore "$directory" "$work" || status=$?
    if [[ "$status" == 0 && -s "$work/batch.nft" ]]; then
        nft -c -f "$work/batch.nft" && nft -f "$work/batch.nft" || status=30
    fi
    [[ "$status" != 0 ]] || vps_nft_commit_prepared "$work" || status=30
    rm -f -- "$work/state.json" "$work/old.json" "$work/manifest.json" "$work/batch.nft" "$work/restore-state.json"
    rmdir -- "$work" || true
    return "$status"
}

_vps_nft_discard_directory() {
    local directory="$1" entry
    [[ "$directory" == "$VPS_NFT_STATE_DIR"/transactions/tx.* ]] || return 3
    vps_cmd_require_no_symlink_components "$directory" || return $?
    [[ -d "$directory" ]] || return 0
    for entry in "$directory"/frame-*; do
        [[ -d "$entry" && ! -L "$entry" ]] || continue
        rm -f -- "$entry/state.json" "$entry/snapshot.json" "$entry/desired.json" "$entry/manifest.json" || return 20
        rmdir -- "$entry" || return 20
    done
    rm -f -- "$directory/decision" "$directory/runtime.json" || return 20
    rmdir -- "$directory"
}

_vps_nft_journal_write() {
    jq -n --arg directory "$VPS_NFT_WORK" --arg phase "$1" '{version:1,directory:$directory,phase:$phase}' |
        vps_cmd_atomic_write /var/lib/vpsctl/network/nftables/pending.json 0600
}

_vps_nft_recover() {
    local directory phase
    [[ -e "$VPS_NFT_JOURNAL" ]] || return 0
    vps_cmd_require_no_symlink_components "$VPS_NFT_JOURNAL" || return $?
    jq -e '.version==1 and (.directory|type)=="string" and
      (.phase=="prepared" or .phase=="committing" or .phase=="cleanup-pending")' "$VPS_NFT_JOURNAL" >/dev/null || return 3
    directory="$(jq -r '.directory' "$VPS_NFT_JOURNAL")"
    phase="$(jq -r '.phase' "$VPS_NFT_JOURNAL")"
    [[ "$directory" == "$VPS_NFT_STATE_DIR"/transactions/tx.* ]] || return 3
    vps_cmd_require_no_symlink_components "$directory" || return $?
    if [[ -f "$directory/decision" && "$(<"$directory/decision")" == committed ]]; then phase=committing; fi
    if [[ "$phase" == prepared ]]; then
        vps_nft_restore "$directory/frame-0" || return 30
    elif vps_nft_is_active; then
        _vps_nft_apply_file "$VPS_NFT_STATE_FILE" force || return 30
    else [[ "$?" == 1 ]] || return 30; fi
    rm -f -- "$VPS_NFT_JOURNAL" || return 20
    _vps_nft_discard_directory "$directory"
}

# Prepare additions first; retain every outer frame's old endpoints until the
# outer commit. Desired ownership is already durable for crash recovery.
_vps_nft_prepare_union() {
    local frame state
    state="$(vps_nft_state)" || return $?
    for frame in "${VPS_NFT_FRAMES[@]}"; do
        [[ "$frame" != dry-run ]] || continue
        state="$(jq --slurpfile before "$frame/state.json" '.requirements=(.requirements+$before[0].requirements|unique)' <<<"$state")" || return 20
    done
    printf '%s\n' "$state" >"$VPS_NFT_WORK/runtime.json" || return 20
    _vps_nft_apply_file "$VPS_NFT_WORK/runtime.json" force
}

vps_nft_begin() {
    local scope="${1:-}" file="${2:-}" mode="${3:-auto}" desired state frame status=0 active=0
    [[ "$scope" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 2
    case "$mode" in auto | 0) mode=auto ;; record-only | 1) mode='record-only' ;; force | 2) mode=force ;; *) return 2 ;; esac
    vps_nft_init || return $?
    vps_nft_require_tools || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_nft_lock || return $?
        VPS_NFT_FRAMES[VPS_NFT_DEPTH]=dry-run
        VPS_NFT_MODES[VPS_NFT_DEPTH]="$mode"
        VPS_NFT_DEPTH=$((VPS_NFT_DEPTH + 1))
        return 0
    fi
    desired="$(_vps_nft_normalize_desired "$file" "$scope")" || return $?
    vps_nft_lock || return $?
    if ((VPS_NFT_DEPTH == 0)); then
        _vps_nft_recover || {
            status=$?
            vps_nft_unlock
            return "$status"
        }
        vps_cmd_require_no_symlink_components "$VPS_NFT_STATE_DIR/transactions" || {
            vps_nft_unlock
            return 3
        }
        mkdir -p -- "$VPS_NFT_STATE_DIR/transactions" || {
            vps_nft_unlock
            return 20
        }
        chmod 0700 -- "$VPS_NFT_STATE_DIR" "$VPS_NFT_STATE_DIR/transactions" || {
            vps_nft_unlock
            return 20
        }
        VPS_NFT_WORK="$(mktemp -d "$VPS_NFT_STATE_DIR/transactions/tx.XXXXXX")" || {
            vps_nft_unlock
            return 20
        }
        printf 'prepared\n' >"$VPS_NFT_WORK/decision" || {
            vps_nft_unlock
            return 20
        }
    fi
    frame="$VPS_NFT_WORK/frame-$VPS_NFT_DEPTH"
    vps_nft_snapshot "$frame" || {
        status=$?
        vps_nft_unlock
        return "$status"
    }
    VPS_NFT_FRAMES[VPS_NFT_DEPTH]="$frame"
    VPS_NFT_MODES[VPS_NFT_DEPTH]="$mode"
    VPS_NFT_DEPTH=$((VPS_NFT_DEPTH + 1))
    if ((VPS_NFT_DEPTH == 1)); then _vps_nft_journal_write prepared || {
        status=$?
        vps_nft_rollback || return 30
        return "$status"
    }; fi
    if [[ "$mode" != record-only ]]; then
        if vps_nft_is_active; then active=1; else
            status=$?
            [[ "$status" == 1 ]] || {
                vps_nft_rollback || return 30
                return "$status"
            }
        fi
    fi
    [[ "$mode" != force ]] || active=1
    [[ "$active" == 1 ]] || VPS_NFT_MODES[VPS_NFT_DEPTH - 1]='record-only'
    state="$(vps_nft_state)" && state="$(_vps_nft_prune_leases "$state")" || {
        status=$?
        vps_nft_rollback || return 30
        return "$status"
    }
    VPS_NFT_LEASE_JSON=null
    if jq -e 'any(.[];.temporary)' <<<"$desired" >/dev/null; then
        vps_nft_lease_metadata || {
            status=$?
            vps_nft_rollback || return 30
            return "$status"
        }
    fi
    state="$(jq --arg scope "$scope" --argjson desired "$desired" --argjson lease "$VPS_NFT_LEASE_JSON" '
      .revision+=1 | .requirements=([.requirements[]|select(.scope!=$scope)]+$desired) |
      reduce $desired[] as $r (.; .links[$r.owner]=((.links[$r.owner]//{detached:false})+{scope:$scope}) |
        if $r.temporary then .leases[$r.owner]=$lease else . end) |
      . as $s | .leases |= with_entries(select(.key as $o|any($s.requirements[];.owner==$o and .temporary)))' <<<"$state")" || {
        vps_nft_rollback || return 30
        return 20
    }
    printf '%s\n' "$state" | _vps_nft_save || {
        status=$?
        vps_nft_rollback || return 30
        return "$status"
    }
    if [[ "$active" == 1 ]]; then _vps_nft_prepare_union || {
        status=$?
        vps_nft_rollback || return 30
        return "$status"
    }; fi
}

vps_nft_commit() {
    local mode directory status=0
    ((${VPS_NFT_DEPTH:-0} > 0)) || return 0
    [[ "$VPS_NFT_PROCESS" == "$BASHPID" ]] || return 70
    if ((VPS_NFT_DEPTH > 1)); then
        VPS_NFT_DEPTH=$((VPS_NFT_DEPTH - 1))
        [[ "${VPS_NFT_MODES[VPS_NFT_DEPTH]}" == record-only ]] || VPS_NFT_MODES[0]=force
        vps_nft_unlock
        return 0
    fi
    mode="${VPS_NFT_MODES[0]}"
    directory="$VPS_NFT_WORK"
    if [[ "${VPS_NFT_FRAMES[0]}" != dry-run ]]; then
        printf 'committed\n' >"$directory/decision" || status=30
        if _vps_nft_journal_write committing; then
            [[ "$mode" == record-only ]] || _vps_nft_apply_file "$VPS_NFT_STATE_FILE" force || status=30
        else status=30; fi
        if [[ "$status" == 0 ]]; then
            rm -f -- "$VPS_NFT_JOURNAL" || status=30
            [[ "$status" != 0 ]] || _vps_nft_discard_directory "$directory" || status=30
        else
            _vps_nft_journal_write cleanup-pending || true
            vps_cmd_error '新服务需求已保留；旧 nftables 规则清理失败，请运行 network nftables sync'
        fi
    fi
    VPS_NFT_DEPTH=0 VPS_NFT_WORK=''
    VPS_NFT_FRAMES=() VPS_NFT_MODES=()
    vps_nft_unlock || return 70
    return "$status"
}

vps_nft_rollback() {
    local frame directory status=0
    ((${VPS_NFT_DEPTH:-0} > 0)) || return 0
    [[ "$VPS_NFT_PROCESS" == "$BASHPID" ]] || return 70
    frame="${VPS_NFT_FRAMES[VPS_NFT_DEPTH - 1]}"
    directory="$VPS_NFT_WORK"
    [[ "$frame" == dry-run ]] || vps_nft_restore "$frame" || status=30
    VPS_NFT_DEPTH=$((VPS_NFT_DEPTH - 1))
    unset 'VPS_NFT_FRAMES[VPS_NFT_DEPTH]' 'VPS_NFT_MODES[VPS_NFT_DEPTH]'
    if ((VPS_NFT_DEPTH == 0)); then
        if [[ "$status" == 0 && "$frame" != dry-run ]]; then
            rm -f -- "$VPS_NFT_JOURNAL" || status=30
            [[ "$status" != 0 ]] || _vps_nft_discard_directory "$directory" || status=30
        fi
        VPS_NFT_WORK='' VPS_NFT_FRAMES=() VPS_NFT_MODES=()
    fi
    vps_nft_unlock || return 70
    return "$status"
}

vps_nft_link_set() {
    local owner="$1" mode="$2" state status=0
    [[ "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]*$ && ("$mode" == attached || "$mode" == detached) ]] || return 2
    vps_nft_lock || return $?
    state="$(vps_nft_state)" || status=$?
    if [[ "$status" == 0 ]]; then
        state="$(jq --arg owner "$owner" --argjson detached "$([[ "$mode" == detached ]] && printf true || printf false)" \
            '.revision+=1 | .links[$owner]=((.links[$owner]//{scope:""})+{detached:$detached})' <<<"$state")" || status=20
    fi
    [[ "$status" != 0 ]] || printf '%s\n' "$state" | _vps_nft_save || status=$?
    if [[ "$status" == 0 ]] && vps_nft_is_active; then _vps_nft_apply_file "$VPS_NFT_STATE_FILE" force || status=$?; fi
    vps_nft_unlock
    return "$status"
}

vps_nft_scope_snapshot() {
    local scope="$1" file="$2" state status=0
    vps_nft_lock || return $?
    state="$(vps_nft_state)" || status=$?
    [[ "$status" != 0 ]] || vps_cmd_require_no_symlink_components "$file" || status=$?
    [[ "$status" != 0 ]] || jq --arg scope "$scope" '{version:1,scope:$scope,
      requirements:[.requirements[]|select(.scope==$scope)|del(.scope)]}' <<<"$state" >"$file" || status=20
    [[ "$status" != 0 ]] || chmod 0600 -- "$file" || status=20
    vps_nft_unlock
    return "$status"
}

vps_nft_scope_restore_begin() {
    local scope="$1" file="$2" desired status=0
    vps_cmd_require_no_symlink_components "$file" || return $?
    jq -e --arg scope "$scope" '.version==1 and .scope==$scope and (.requirements|type)=="array"' "$file" >/dev/null || return 3
    desired="$(mktemp)" || return 20
    jq '.requirements' "$file" >"$desired" || status=20
    [[ "$status" != 0 ]] || vps_nft_begin "$scope" "$desired" || status=$?
    rm -f -- "$desired"
    return "$status"
}
vps_nft_scope_restore() {
    vps_nft_scope_restore_begin "$@" || return $?
    vps_nft_commit
}
