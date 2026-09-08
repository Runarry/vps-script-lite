# shellcheck shell=bash
# Shared UFW requirements, ownership and transactions. Sourcing defines functions only.
# Dollar names inside _vps_ufw_jq arguments are jq variables, not shell expansions.
# shellcheck disable=SC2016
# Callers source command.sh first. All mutating APIs must run in the calling shell.
# begin SCOPE FILE [auto|record-only|force] adds rules before the business change;
# commit releases obsolete rules afterwards. A cleanup failure returns 30 while
# retaining the committed requirements and new rules for the running service.

vps_ufw_init() {
    local directory
    directory="$(vps_cmd_system_path /var/lib/vpsctl/network/ufw)" || return $?
    [[ "${VPS_UFW_STATE_DIR:-}" != "$directory" ]] || return 0
    [[ "${VPS_UFW_DEPTH:-0}" == 0 && "${VPS_UFW_LOCK_COUNT:-0}" == 0 ]] || return 70
    VPS_UFW_STATE_DIR="$directory"
    VPS_UFW_STATE_FILE="$directory/state.json"
    VPS_UFW_JOURNAL="$directory/pending.json"
    VPS_UFW_LOCK_PATH="$(vps_cmd_system_path /run/vpsctl/network-ufw.lock)" || return $?
    VPS_UFW_LOCK_FD=''
    VPS_UFW_LOCK_COUNT=0
    VPS_UFW_DEPTH=0
    VPS_UFW_PROCESS=''
    VPS_UFW_WORK=''
    VPS_UFW_FRAMES=()
    VPS_UFW_MODES=()
}

vps_ufw_require_tools() {
    vps_cmd_ensure_tools network-ufw jq flock sha256sum || return $?
}

vps_ufw_is_active() {
    local output
    command -v ufw >/dev/null 2>&1 || return 1
    output="$(LC_ALL=C ufw status 2>/dev/null)" || {
        vps_cmd_error '无法检测 UFW 状态'
        return 3
    }
    case "${output%%$'\n'*}" in
        'Status: active') return 0 ;;
        'Status: inactive') return 1 ;;
        *)
            vps_cmd_error '无法识别 UFW 状态，拒绝猜测防火墙是否停用'
            return 3
            ;;
    esac
}

vps_ufw_ipv6_available() {
    local defaults disabled
    defaults="$(vps_cmd_system_path /etc/default/ufw)" || return $?
    vps_cmd_require_no_symlink_components "$defaults" || return $?
    [[ -r "$defaults" && -f "$defaults" ]] || return 1
    awk -F= '/^[[:space:]]*IPV6[[:space:]]*=/ {
        gsub(/[[:space:]"\047]/, "", $2); value=tolower($2)
    } END {exit(value != "yes")}' "$defaults" || return 1
    disabled="$(vps_cmd_system_path /proc/sys/net/ipv6/conf/all/disable_ipv6)" || return $?
    if [[ "${VPSCTL_TESTING:-0}" != 1 ]]; then
        [[ -r "$disabled" ]] || return 1
    fi
    [[ ! -r "$disabled" || "$(<"$disabled")" == 0 ]]
}

vps_ufw_ipv6_enabled() { vps_ufw_ipv6_available; }

vps_ufw_lock() {
    vps_ufw_init || return $?
    if ((${VPS_UFW_LOCK_COUNT:-0} > 0)); then
        [[ "$VPS_UFW_PROCESS" == "$BASHPID" ]] || {
            vps_cmd_error 'UFW 事务不能在继承事务的子 shell 中运行'
            return 70
        }
        VPS_UFW_LOCK_COUNT=$((VPS_UFW_LOCK_COUNT + 1))
        return 0
    fi
    VPS_UFW_PROCESS="$BASHPID"
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        VPS_UFW_LOCK_COUNT=1
        return 0
    fi
    command -v flock >/dev/null 2>&1 || {
        vps_cmd_error 'UFW 共享锁需要 flock'
        return 3
    }
    vps_cmd_require_no_symlink_components "$VPS_UFW_LOCK_PATH" || return $?
    [[ ! -e "$VPS_UFW_LOCK_PATH" || -f "$VPS_UFW_LOCK_PATH" ]] || return 3
    mkdir -p -- "${VPS_UFW_LOCK_PATH%/*}" || return 20
    exec {VPS_UFW_LOCK_FD}>"$VPS_UFW_LOCK_PATH" || return 20
    if ! flock -n "$VPS_UFW_LOCK_FD"; then
        exec {VPS_UFW_LOCK_FD}>&-
        VPS_UFW_LOCK_FD=''
        vps_cmd_error '另一个 UFW 操作正在运行'
        return 3
    fi
    VPS_UFW_LOCK_COUNT=1
}

vps_ufw_unlock() {
    ((${VPS_UFW_LOCK_COUNT:-0} > 0)) || return 0
    [[ "$VPS_UFW_PROCESS" == "$BASHPID" ]] || return 70
    VPS_UFW_LOCK_COUNT=$((VPS_UFW_LOCK_COUNT - 1))
    ((VPS_UFW_LOCK_COUNT == 0)) || return 0
    if [[ -n "${VPS_UFW_LOCK_FD:-}" ]]; then
        flock -u "$VPS_UFW_LOCK_FD" >/dev/null 2>&1 || true
        exec {VPS_UFW_LOCK_FD}>&-
    fi
    VPS_UFW_LOCK_FD=''
    VPS_UFW_PROCESS=''
}

_vps_ufw_jq() {
    local filter="$1"
    shift
    jq "$@" '
      def endpoint: {kind,family,proto,port,source,destination,
        source_port:(.source_port // "any"),interfaces:(.interfaces // {in:"",out:""})};
      def same($r): endpoint == ($r|endpoint);
      def refs($s;$r): [$s.requirements[] | select($s.links[.owner].detached != true)
        | select(same($r)) | .owner] | unique;
      def intervals: if . == "any" then [[1,65535]] else
        split(",") | map(split(":") | map(tonumber) | if length==1 then [.[0],.[0]] else . end) end;
      def overlaps($a;$b): try (any($a|intervals[]; . as $x |
        any($b|intervals[]; .[0] <= $x[1] and .[1] >= $x[0]))) catch true;
      def address_overlap($a;$b): $a=="any" or $b=="any" or $a==$b or
        ($a|contains("/")) or ($b|contains("/"));
      def conflicts($r): .kind==$r.kind and .family==$r.family and
        (.proto==$r.proto or .proto=="any") and overlaps(.port;$r.port) and
        address_overlap(.destination;$r.destination) and address_overlap(.source;$r.source) and
        (.action!="allow" or .opaque==true or (.simple!=true and same($r)) or (.source!=$r.source and .source!="any") or
         .source_port!="any" or .interfaces.in!="" or .interfaces.out!="");
    '"$filter"
}

_vps_ufw_state() {
    vps_ufw_init || return $?
    vps_cmd_require_no_symlink_components "$VPS_UFW_STATE_FILE" || return $?
    if [[ ! -e "$VPS_UFW_STATE_FILE" ]]; then
        printf '%s\n' '{"version":1,"revision":0,"requirements":[],"links":{},"managed":{},"leases":{},"history":[]}'
        return 0
    fi
    [[ -f "$VPS_UFW_STATE_FILE" ]] || return 3
    jq -e 'type=="object" and .version==1 and (.requirements|type)=="array" and
      (.links|type)=="object" and (.managed|type)=="object" and (.leases|type)=="object" and
      (.history|type)=="array"' "$VPS_UFW_STATE_FILE" >/dev/null || {
        vps_cmd_error 'UFW 引用状态损坏或版本不受支持，拒绝覆盖'
        return 3
    }
    cat -- "$VPS_UFW_STATE_FILE"
}

_vps_ufw_save() {
    vps_cmd_require_no_symlink_components "$VPS_UFW_STATE_DIR" || return $?
    mkdir -p -- "$VPS_UFW_STATE_DIR" || return 20
    chmod 0700 -- "$VPS_UFW_STATE_DIR" || return 20
    vps_cmd_atomic_write /var/lib/vpsctl/network/ufw/state.json 0600
}

_vps_ufw_hash() {
    local digest
    digest="$(sha256sum)" || return 20
    printf '%s' "${digest%% *}"
}

# Expand IPv6 for equivalence comparisons without adding a Python dependency to
# services on machines where UFW has never been installed.
_vps_ufw_address() {
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
    fi
    [[ -z "$prefix" || "$prefix" =~ ^[0-9]{1,3}$ ]] || return 2
    if [[ "$value" == *:* ]]; then
        if [[ "$value" == *.* ]]; then
            tail="$(_vps_ufw_address "${value##*:}")" || return 2
            IFS=. read -r -a pieces <<<"$tail"
            printf -v tail '%x:%x' "$((pieces[0] * 256 + pieces[1]))" "$((pieces[2] * 256 + pieces[3]))"
            value="${value%:*}:$tail"
        fi
        [[ "$value" =~ ^[0-9a-f:]+$ && "$value" != *:::* ]] || return 2
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
        IFS=. read -r -a pieces <<<"$value"
        ((${#pieces[@]} == 4)) || return 2
        [[ -z "$prefix" ]] || ((10#$prefix <= 32)) || return 2
        for part in "${pieces[@]}"; do
            [[ "$part" =~ ^[0-9]{1,3}$ ]] && ((10#$part <= 255)) || return 2
            expanded+="${expanded:+.}$((10#$part))"
        done
        [[ -z "$prefix" || "$prefix" == 32 ]] || expanded+="/$((10#$prefix))"
    fi
    printf '%s' "$expanded"
}

_vps_ufw_simple_raw() {
    local raw="$1" family="$2" kind="$3" proto="$4" port="$5" source="$6" destination="$7"
    local chain='ufw-user-input' seen_chain='' seen_proto='' seen_port=any seen_source=any seen_destination=any jump=''
    local index token value
    local -a tokens=()
    [[ "$raw" != *$'\n'* ]] || return 1
    [[ "$family" != ipv6 ]] || chain=ufw6-user-input
    [[ "$kind" != route ]] || chain="${chain%input}forward"
    [[ "$kind" != output ]] || chain="${chain%input}output"
    IFS=' ' read -r -a tokens <<<"$raw"
    for ((index = 0; index < ${#tokens[@]}; index += 2)); do
        token="${tokens[index]}"
        value="${tokens[index + 1]:-}"
        [[ -n "$value" ]] || return 1
        case "$token" in
            -A)
                [[ -z "$seen_chain" ]] || return 1
                seen_chain="$value"
                ;;
            -p)
                [[ -z "$seen_proto" ]] || return 1
                seen_proto="$value"
                ;;
            --dport | --dports)
                [[ "$seen_port" == any ]] || return 1
                seen_port="$value"
                ;;
            -s)
                [[ "$seen_source" == any ]] || return 1
                seen_source="$(_vps_ufw_address "$value")" || return 1
                ;;
            -d)
                [[ "$seen_destination" == any ]] || return 1
                seen_destination="$(_vps_ufw_address "$value")" || return 1
                ;;
            -j)
                [[ -z "$jump" ]] || return 1
                jump="$value"
                ;;
            -m) [[ "$value" == "$proto" || "$value" == multiport ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
    [[ "$seen_chain" == "$chain" && "$seen_proto" == "$proto" && "$seen_port" == "$port" &&
        "$seen_source" == "$source" && "$seen_destination" == "$destination" && "$jump" == ACCEPT ]]
}

_vps_ufw_rule_json() {
    local tuple="$1" raw="$2" family="$3" number="$4"
    local action proto port destination sport source direction='in' ifaces='in'
    local in_if='' out_if='' comment='' token kind=input log='' simple=true opaque=false hex digest
    local dapp='' sapp='' index
    local -a fields=() parts=()
    IFS=' ' read -r -a fields <<<"${tuple#\#\#\# tuple \#\#\# }"
    if [[ "${fields[${#fields[@]} - 1]:-}" == comment=* ]]; then
        hex="${fields[${#fields[@]} - 1]#comment=}"
        [[ "$hex" =~ ^([0-9a-fA-F]{2})*$ ]] || return 3
        for ((index = 0; index < ${#hex}; index += 2)); do comment+="\\x${hex:index:2}"; done
        printf -v comment '%b' "$comment"
        unset 'fields[${#fields[@]}-1]'
    fi
    case "${#fields[@]}" in
        6) ;;
        7) ifaces="${fields[6]}" ;;
        8)
            dapp="${fields[6]}"
            sapp="${fields[7]}"
            ;;
        9)
            dapp="${fields[6]}"
            sapp="${fields[7]}"
            ifaces="${fields[8]}"
            ;;
        *)
            vps_cmd_error "不支持的 UFW tuple，拒绝猜测规则: $tuple"
            return 3
            ;;
    esac
    action="${fields[0]}"
    proto="${fields[1]}"
    port="${fields[2]}"
    destination="$(_vps_ufw_address "${fields[3]}")" || return 3
    sport="${fields[4]}"
    source="$(_vps_ufw_address "${fields[5]}")" || return 3
    if [[ "$action" == route:* ]]; then
        kind=route
        action="${action#route:}"
    fi
    if [[ "$action" == *_* ]]; then
        log="${action#*_}"
        action="${action%%_*}"
    fi
    case "$action" in allow | deny | reject | limit) ;; *) return 3 ;; esac
    IFS='!' read -r -a parts <<<"$ifaces"
    for token in "${parts[@]}"; do
        case "$token" in
            in) direction=in ;;
            out) direction=out ;;
            in_*)
                in_if="${token#in_}"
                direction=in
                ;;
            out_*)
                out_if="${token#out_}"
                direction=out
                ;;
            *) return 3 ;;
        esac
    done
    [[ "$kind" != input || "$direction" != out ]] || kind=output
    [[ "$dapp" != - ]] || dapp=''
    [[ "$sapp" != - ]] || sapp=''
    dapp="${dapp//%20/ }"
    sapp="${sapp//%20/ }"
    [[ -z "$dapp$sapp$log" ]] || simple=false
    [[ "$proto" == tcp || "$proto" == udp ]] || simple=false
    [[ "$port" =~ ^[0-9]+(:[0-9]+)?$ && "$sport" == any ]] || simple=false
    [[ -z "$in_if$out_if" ]] || simple=false
    if [[ "$simple" == true && "$action" == allow ]] &&
        ! _vps_ufw_simple_raw "$raw" "$family" "$kind" "$proto" "$port" "$source" "$destination"; then
        simple=false
        opaque=true
    fi
    digest="$(printf '%s\n%s\n%s' "$family" "$tuple" "$raw" | _vps_ufw_hash)" || return $?
    jq -cn --arg id "$digest" --argjson number "$number" --arg kind "$kind" --arg family "$family" \
        --arg action "$action" --arg proto "$proto" --arg port "$port" --arg destination "$destination" \
        --arg source "$source" --arg source_port "$sport" --arg in_if "$in_if" --arg out_if "$out_if" \
        --arg comment "$comment" --arg tuple "$tuple" --arg raw "$raw" --arg log "$log" \
        --arg dapp "$dapp" --arg sapp "$sapp" --arg ifaces "$ifaces" --argjson simple "$simple" --argjson opaque "$opaque" \
        '{id:$id,number:$number,kind:$kind,family:$family,action:$action,proto:$proto,port:$port,
          source:$source,destination:$destination,source_port:$source_port,interfaces:{in:$in_if,out:$out_if},
          comment:$comment,tuple:$tuple,raw:$raw,log:$log,dapp:$dapp,sapp:$sapp,
          app:$dapp,source_app:$sapp,simple:$simple,opaque:$opaque,owners:[],
          app_group:(if $dapp!="" or $sapp!="" then
            [$family,(if $dapp!="" then $dapp else $port end),$destination,
             (if $sapp!="" then $sapp else $source_port end),$source,$ifaces]|tojson else null end)}'
}

_vps_ufw_inventory_raw() {
    local file family line tuple='' raw='' rows='' row number=0
    for family in ipv4 ipv6; do
        if [[ "$family" == ipv4 ]]; then
            file="$(vps_cmd_system_path /etc/ufw/user.rules)"
        else file="$(vps_cmd_system_path /etc/ufw/user6.rules)"; fi
        vps_cmd_require_no_symlink_components "$file" || return $?
        [[ -e "$file" ]] || continue
        [[ -f "$file" && -r "$file" ]] || return 3
        tuple=''
        raw=''
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == '### tuple ### '* || "$line" == '### END RULES ###'* || -z "$line" ]]; then
                if [[ -n "$tuple" ]]; then
                    number=$((number + 1))
                    row="$(_vps_ufw_rule_json "$tuple" "$raw" "$family" "$number")" || return $?
                    rows+="$row"$'\n'
                fi
                tuple=''
                raw=''
                [[ "$line" != '### tuple ### '* ]] || tuple="$line"
            elif [[ -n "$tuple" ]]; then
                raw+="${raw:+$'\n'}$line"
            fi
        done <"$file"
        if [[ -n "$tuple" ]]; then
            number=$((number + 1))
            row="$(_vps_ufw_rule_json "$tuple" "$raw" "$family" "$number")" || return $?
            rows+="$row"$'\n'
        fi
    done
    # UFW collapses the protocol expansions of one application profile into one
    # display/delete number (UFWBackend.get_rule_by_number).
    jq -s 'reduce .[] as $r ({next:1,groups:{},rules:[]};
      if $r.app_group!=null and .groups[$r.app_group]!=null then
        .rules += [$r + {number:.groups[$r.app_group]}]
      else .rules += [$r + {number:.next}] |
        (if $r.app_group!=null then .groups[$r.app_group]=.next else . end) | .next+=1 end) | .rules' <<<"$rows"
}

vps_ufw_inventory() {
    local state rules
    state="$(_vps_ufw_state)" || return $?
    # Read-only protection checks must not treat an expired process lease as a
    # live owner. The next writer persists this pruning and releases its rule.
    state="$(_vps_ufw_prune_leases "$state")" || return $?
    rules="$(_vps_ufw_inventory_raw)" || return $?
    _vps_ufw_jq 'map(. as $r | .owners = (if .action=="allow" and .simple then refs($s;$r) else [] end))' \
        --argjson s "$state" <<<"$rules"
}

vps_ufw_links() {
    local state
    state="$(_vps_ufw_state)" || return $?
    jq '[((.links|keys) + [.requirements[].owner] | unique)[] as $o | {
      owner:$o,detached:(.links[$o].detached // false),scope:(.links[$o].scope // ""),
      requirements:[.requirements[] | select(.owner==$o) | del(.scope)]}]' <<<"$state"
}

vps_ufw_owner_detached() {
    local state
    state="$(_vps_ufw_state)" || return $?
    jq -e --arg owner "${1:-}" '.links[$owner].detached == true' <<<"$state" >/dev/null
}

vps_ufw_scope_desired() {
    local state
    state="$(_vps_ufw_state)" || return $?
    jq --arg scope "${1:-}" '[.requirements[] | select(.scope==$scope) | del(.scope)]' <<<"$state"
}

vps_ufw_rule_protected() {
    local rules
    rules="$(vps_ufw_inventory)" || return $?
    jq -e --arg id "${1:-}" 'any(.[]; .id==$id and (.owners|length)>0)' <<<"$rules" >/dev/null
}

_vps_ufw_normalize_desired() {
    local file="$1" scope="$2" rows='' row source destination
    [[ -f "$file" && ! -L "$file" ]] || return 2
    jq -e 'type=="array" and all(.[];
      (.owner|type)=="string" and (.owner|test("^(ssh|node:[A-Za-z0-9_.-]+|forward:[A-Za-z0-9_.-]+|tls:[A-Za-z0-9_.-]+)$")) and
      (.kind=="input" or .kind=="route") and (.family=="ipv4" or .family=="ipv6") and
      (.proto=="tcp" or .proto=="udp") and (.port|type)=="string" and
      (.port|test("^[0-9]{1,5}(:[0-9]{1,5})?$")) and
      ([.port|split(":")[]|tonumber]|all(.>=1 and .<=65535)) and
      ([.port|split(":")[]|tonumber] | .[0] <= .[-1]) and
      ((.source // "any")|type)=="string" and ((.destination // "any")|type)=="string" and
      ((.temporary // false)|type)=="boolean")' "$file" >/dev/null || {
        vps_cmd_error 'UFW 服务规则需求格式无效'
        return 2
    }
    while IFS= read -r row; do
        source="$(_vps_ufw_address "$(jq -r '.source // "any"' <<<"$row")")" || return 2
        destination="$(_vps_ufw_address "$(jq -r '.destination // "any"' <<<"$row")")" || return 2
        if [[ "$(jq -r '.family' <<<"$row")" == ipv4 ]]; then
            [[ "$source$destination" != *:* ]] || return 2
        else
            [[ "$source$destination" != *.* ]] || return 2
        fi
        row="$(jq -c --arg scope "$scope" --arg source "$source" --arg destination "$destination" '
          {scope:$scope,owner,kind,family,proto,port:(.port|split(":")|map(tonumber)|unique|map(tostring)|join(":")),
           source:$source,destination:$destination,source_port:"any",interfaces:{in:"",out:""},temporary:(.temporary // false)}' <<<"$row")" || return 20
        rows+="$row"$'\n'
    done < <(jq -c '.[]' "$file")
    jq -s 'unique' <<<"$rows"
}

vps_ufw_lease_metadata() {
    local pid="$BASHPID" boot='' start='' stat=''
    [[ ! -r /proc/sys/kernel/random/boot_id ]] || boot="$(</proc/sys/kernel/random/boot_id)"
    if [[ -r "/proc/$pid/stat" ]]; then
        stat="$(<"/proc/$pid/stat")"
        start="$(awk '{print $20}' <<<"${stat##*) }")"
    fi
    [[ -n "$boot" && "$start" =~ ^[0-9]+$ ]] || {
        vps_cmd_error '无法记录临时 UFW 租约的进程身份'
        return 3
    }
    # Public metadata, assigned in the owning shell rather than a command substitution.
    VPS_UFW_LEASE_JSON="$(jq -cn --argjson pid "$pid" --arg boot_id "$boot" --arg start_time "$start" \
        '{pid:$pid,boot_id:$boot_id,start_time:$start_time}')" || return 20
}

_vps_ufw_prune_leases() {
    local state="$1" owner pid boot start stat actual
    while IFS= read -r owner; do
        pid="$(jq -r --arg owner "$owner" '.leases[$owner].pid' <<<"$state")"
        boot="$(jq -r --arg owner "$owner" '.leases[$owner].boot_id' <<<"$state")"
        start="$(jq -r --arg owner "$owner" '.leases[$owner].start_time' <<<"$state")"
        actual=''
        if [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" && -r /proc/sys/kernel/random/boot_id &&
            "$boot" == "$(</proc/sys/kernel/random/boot_id)" ]]; then
            stat="$(<"/proc/$pid/stat")"
            actual="$(awk '{print $20}' <<<"${stat##*) }")"
        fi
        [[ -z "$actual" || "$actual" != "$start" ]] || continue
        state="$(jq --arg owner "$owner" '.requirements |= map(select(.owner!=$owner or .temporary!=true)) |
          del(.leases[$owner])' <<<"$state")" || return 20
    done < <(jq -r '.leases|keys[]' <<<"$state")
    printf '%s\n' "$state"
}

# Config snapshots are private, explicit files; never source a recovery file.
vps_ufw_snapshot() {
    local directory="${1:-}" logical path saved index=0 records='' record active=0 status=0
    ((${VPS_UFW_LOCK_COUNT:-0} > 0)) || {
        vps_cmd_error 'UFW 快照必须在共享锁内创建'
        return 70
    }
    vps_cmd_require_no_symlink_components "$directory" || return $?
    mkdir -p -- "$directory" || return 20
    chmod 0700 -- "$directory" || return 20
    if vps_ufw_is_active; then active=1; else
        status=$?
        [[ "$status" == 1 ]] || return "$status"
    fi
    for logical in /etc/default/ufw /etc/ufw/ufw.conf /etc/ufw/user.rules /etc/ufw/user6.rules \
        /etc/ufw/before.rules /etc/ufw/before6.rules /etc/ufw/after.rules /etc/ufw/after6.rules \
        /etc/ufw/sysctl.conf /var/lib/vpsctl/network/ufw/state.json; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        saved="$directory/file-$index"
        vps_cmd_require_no_symlink_components "$saved" || return $?
        if [[ -e "$path" ]]; then
            [[ -f "$path" && -r "$path" ]] || return 3
            cp -p -- "$path" "$saved" || return 20
            record="$(jq -cn --arg path "$logical" --arg file "file-$index" '{path:$path,file:$file,exists:true}')" || return 20
        else
            record="$(jq -cn --arg path "$logical" --arg file "file-$index" '{path:$path,file:$file,exists:false}')" || return 20
        fi
        records+="$record"$'\n'
        index=$((index + 1))
    done
    vps_cmd_require_no_symlink_components "$directory/snapshot.json" || return $?
    jq -s --argjson active "$active" '{version:1,active:$active,files:.}' <<<"$records" >"$directory/snapshot.json" || return 20
    chmod 0600 -- "$directory/snapshot.json" || return 20
}

vps_ufw_restore() {
    local directory="${1:-}" mode="${2:-runtime}" record logical path saved active current=0 status=0 changed=0
    [[ "$mode" == runtime || "$mode" == config-only ]] || return 2
    ((${VPS_UFW_LOCK_COUNT:-0} > 0)) || return 70
    vps_cmd_require_no_symlink_components "$directory/snapshot.json" || return $?
    [[ -f "$directory/snapshot.json" ]] || return 3
    jq -e '.version==1 and (.active==0 or .active==1) and (.files|length)==10 and
      all(.files[]; (.file|test("^file-[0-9]+$")) and
       (.path=="/etc/default/ufw" or .path=="/var/lib/vpsctl/network/ufw/state.json" or
        (.path|test("^/etc/ufw/(ufw\\.conf|user6?\\.rules|before6?\\.rules|after6?\\.rules|sysctl\\.conf)$"))))' \
        "$directory/snapshot.json" >/dev/null || return 3
    active="$(jq -r '.active' "$directory/snapshot.json")"
    if [[ "$mode" == runtime ]]; then
        if vps_ufw_is_active; then current=1; else
            status=$?
            [[ "$status" == 1 ]] || return 30
        fi
    fi
    while IFS= read -r record; do
        logical="$(jq -r '.path' <<<"$record")"
        saved="$(jq -r '.file' <<<"$record")"
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        if [[ "$(jq -r '.exists' <<<"$record")" == true ]]; then
            vps_cmd_require_no_symlink_components "$directory/$saved" || return $?
            [[ -f "$directory/$saved" ]] || return 3
            if [[ "$logical" != /var/lib/vpsctl/network/ufw/state.json ]] && ! cmp -s -- "$directory/$saved" "$path"; then changed=1; fi
            mkdir -p -- "${path%/*}" || return 30
            cp -p -- "$directory/$saved" "$path" || return 30
        else
            [[ ! -e "$path" || -f "$path" ]] || return 3
            if [[ "$logical" != /var/lib/vpsctl/network/ufw/state.json && -e "$path" ]]; then changed=1; fi
            rm -f -- "$path" || return 30
        fi
    done < <(jq -c '.files[]' "$directory/snapshot.json")
    [[ "$mode" != config-only ]] || return 0
    if [[ "$active" == 1 ]]; then
        if [[ "$current" == 1 ]]; then
            [[ "$changed" == 0 ]] || vps_cmd_run ufw reload >&2 || return 30
        else vps_cmd_run ufw --force enable >&2 || return 30; fi
    elif [[ "$current" == 1 ]]; then
        vps_cmd_run ufw --force disable >&2 || return 30
    fi
}

_vps_ufw_journal_write() {
    local phase="$1"
    jq -cn --arg phase "$phase" --arg directory "$VPS_UFW_WORK" \
        '{version:1,phase:$phase,directory:$directory}' |
        vps_cmd_atomic_write /var/lib/vpsctl/network/ufw/pending.json 0600
}

_vps_ufw_discard_directory() {
    local directory="$1" entry
    [[ "$directory" == "$VPS_UFW_STATE_DIR"/transactions/tx.* ]] || return 3
    vps_cmd_require_no_symlink_components "$directory" || return $?
    [[ -d "$directory" ]] || return 0
    for entry in "$directory"/frame-*; do
        [[ -d "$entry" && ! -L "$entry" ]] || continue
        rm -f -- "$entry"/file-[0-9]* "$entry/snapshot.json" "$entry/desired.json" || return 20
        rmdir -- "$entry" || return 20
    done
    rm -f -- "$directory/decision" || return 20
    rmdir -- "$directory" || return 20
}

_vps_ufw_recover() {
    local phase directory
    [[ -e "$VPS_UFW_JOURNAL" ]] || return 0
    vps_cmd_require_no_symlink_components "$VPS_UFW_JOURNAL" || return $?
    [[ -f "$VPS_UFW_JOURNAL" ]] || return 3
    jq -e '.version==1 and (.directory|type)=="string" and
      (.phase=="prepared" or .phase=="committing" or .phase=="cleanup-pending")' "$VPS_UFW_JOURNAL" >/dev/null || return 3
    phase="$(jq -r '.phase' "$VPS_UFW_JOURNAL")"
    directory="$(jq -r '.directory' "$VPS_UFW_JOURNAL")"
    [[ "$directory" == "$VPS_UFW_STATE_DIR"/transactions/tx.* ]] || return 3
    vps_cmd_require_no_symlink_components "$directory/decision" || return $?
    if [[ -f "$directory/decision" && "$(<"$directory/decision")" == committed ]]; then phase=committing; fi
    if [[ "$phase" == prepared ]]; then
        vps_cmd_warning '恢复上次中断的 UFW 准备事务'
        vps_ufw_restore "$directory/frame-0" || return 30
    else
        # A service may already be using the new endpoint. Never roll it back
        # merely because obsolete-rule cleanup was interrupted.
        _vps_ufw_state >/dev/null || return $?
        vps_cmd_warning '保留已提交的 UFW 需求，将在本次提交重试旧规则清理'
    fi
    rm -f -- "$VPS_UFW_JOURNAL" || return 20
    _vps_ufw_discard_directory "$directory"
}

_vps_ufw_add_rule() {
    local rule="$1" comment="$2" position="${3:-}" kind family source destination proto port
    local -a arguments=()
    kind="$(jq -r '.kind' <<<"$rule")"
    family="$(jq -r '.family' <<<"$rule")"
    source="$(jq -r '.source' <<<"$rule")"
    destination="$(jq -r '.destination' <<<"$rule")"
    proto="$(jq -r '.proto' <<<"$rule")"
    port="$(jq -r '.port' <<<"$rule")"
    if [[ "$source" == any ]]; then
        if [[ "$family" == ipv6 ]]; then source='::/0'; else source='0.0.0.0/0'; fi
    fi
    [[ "$destination" != any ]] || destination="$([[ "$family" == ipv6 ]] && printf '::/0' || printf '0.0.0.0/0')"
    [[ "$kind" != route ]] || arguments+=(route)
    [[ -z "$position" ]] || arguments+=(insert "$position")
    arguments+=(allow)
    [[ "$kind" != output ]] || arguments+=(out)
    arguments+=(proto "$proto" from "$source" to "$destination" port "$port")
    [[ -z "$comment" ]] || arguments+=(comment "$comment")
    vps_cmd_run ufw "${arguments[@]}" >&2 || return 20
}

_vps_ufw_delete_id() {
    local id="$1" rules number fresh
    rules="$(_vps_ufw_inventory_raw)" || return $?
    number="$(jq -r --arg id "$id" '[.[]|select(.id==$id)] | if length==0 then "absent" elif length==1 then .[0].number else "ambiguous" end' <<<"$rules")" || return 20
    [[ "$number" != absent ]] || return 0
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || {
        vps_cmd_error 'UFW 规则内容重复，不能安全定位删除'
        return 3
    }
    # Numbers are only used after a second content check, never as a durable ID.
    fresh="$(_vps_ufw_inventory_raw)" || return $?
    jq -e --arg id "$id" --argjson number "$number" 'any(.[]; .id==$id and .number==$number)' <<<"$fresh" >/dev/null || {
        vps_cmd_error 'UFW 规则在删除前发生变化，请重试'
        return 3
    }
    vps_cmd_run ufw --force delete "$number" >&2 || return 20
    fresh="$(_vps_ufw_inventory_raw)" || return $?
    jq -e --arg id "$id" 'all(.[]; .id!=$id)' <<<"$fresh" >/dev/null || return 20
}

_vps_ufw_apply_desired() {
    local state rules request matches key managed chosen owner scope temporary comment conflicts origin
    state="$(_vps_ufw_state)" || return $?
    while IFS= read -r request; do
        owner="$(jq -r '.owner' <<<"$request")"
        scope="$(jq -r '.scope' <<<"$request")"
        [[ "$(jq -r --arg owner "$owner" '.links[$owner].detached // false' <<<"$state")" != true ]] || continue
        if [[ "$(jq -r '.family' <<<"$request")" == ipv6 ]] && ! vps_ufw_ipv6_available; then
            vps_cmd_error "UFW 未启用 IPv6，无法兑现 $owner 的 IPv6 放行需求"
            return 3
        fi
        rules="$(_vps_ufw_inventory_raw)" || return $?
        conflicts="$(_vps_ufw_jq '[.[] | select(conflicts($r))]' --argjson r "$request" <<<"$rules")" || return 20
        if [[ "$(jq 'length' <<<"$conflicts")" != 0 ]]; then
            vps_cmd_error "UFW 的来源、网卡或 deny/limit 等现有规则与 $owner 需求冲突；请先明确调整规则"
            return 3
        fi
        key="$(_vps_ufw_jq 'endpoint' -cS <<<"$request" | _vps_ufw_hash)" || return 20
        managed="$(jq -c --arg key "$key" '.managed[$key] // null' <<<"$state")"
        matches="$(_vps_ufw_jq '[.[]|select(.simple and .action=="allow" and same($r))]' --argjson r "$request" <<<"$rules")" || return 20
        chosen=''
        origin=created
        if [[ "$managed" != null ]]; then
            chosen="$(jq -c --arg id "$(jq -r '.rule.id' <<<"$managed")" '.[]|select(.id==$id)' <<<"$matches")"
        fi
        if [[ -z "$chosen" ]]; then
            if [[ "$(jq 'length' <<<"$matches")" != 0 ]]; then
                chosen="$(jq -c '.[0]' <<<"$matches")"
                origin=adopted
                temporary="$(jq -r '.temporary' <<<"$request")"
                # A short-lived lease may borrow a manual rule, but cannot acquire it.
                if [[ "$temporary" == true ]]; then continue; fi
            else
                comment="vpsctl ufw ${key:0:16}"
                _vps_ufw_add_rule "$request" "$comment" || return $?
                rules="$(_vps_ufw_inventory_raw)" || return $?
                chosen="$(_vps_ufw_jq '[.[]|select(.simple and .action=="allow" and same($r))] | if length==1 then .[0] else empty end' \
                    -c --argjson r "$request" <<<"$rules")" || return 20
                [[ -n "$chosen" ]] || {
                    vps_cmd_error 'UFW 未生成所请求的精确规则'
                    return 20
                }
            fi
            state="$(jq --arg key "$key" --arg origin "$origin" --argjson rule "$chosen" \
                '.managed[$key]={origin:$origin,rule:$rule,preserve:false}' <<<"$state")" || return 20
        fi
        # Keep original content even after retirement, for scoped SSH undo.
        state="$(jq --arg scope "$scope" --arg owner "$owner" --argjson rule "$chosen" \
            '.history = ([.history[] | select(.scope!=$scope or .owner!=$owner or .rule.id!=$rule.id)] +
              [{scope:$scope,owner:$owner,rule:$rule,revision:(.revision // 0)}])' <<<"$state")" || return 20
        printf '%s\n' "$state" | _vps_ufw_save || return $?
    done < <(jq -c --arg scope "$1" '.requirements[]|select(.scope==$scope)' <<<"$state")
}

_vps_ufw_sweep() {
    local state entry key id preserve rules actual
    state="$(_vps_ufw_state)" || return $?
    while IFS= read -r entry; do
        key="$(jq -r '.key' <<<"$entry")"
        id="$(jq -r '.value.rule.id' <<<"$entry")"
        preserve="$(jq -r '.value.preserve // false' <<<"$entry")"
        if [[ "$preserve" != true ]]; then
            rules="$(_vps_ufw_inventory_raw)" || return $?
            actual="$(jq -c --arg id "$id" '.[]|select(.id==$id)' <<<"$rules")"
            if [[ -n "$actual" ]]; then
                _vps_ufw_delete_id "$id" || return $?
            else
                # A changed comment/content denotes an administrator edit. Do not
                # substitute a matching port or a stale display number for its ID.
                vps_cmd_verbose "UFW 管理规则已不存在或被人工修改，释放记录: $id"
            fi
        fi
        state="$(jq --arg key "$key" 'del(.managed[$key])' <<<"$state")" || return 20
        printf '%s\n' "$state" | _vps_ufw_save || return $?
    done < <(_vps_ufw_jq '. as $s | .managed | to_entries[] | select((refs($s;.value.rule)|length)==0)' -c <<<"$state")
}

vps_ufw_begin() {
    local scope="${1:-}" file="${2:-}" mode="${3:-auto}" desired state frame status=0 active=0
    [[ "$scope" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 2
    case "$mode" in auto | 0) mode=auto ;; record-only | 1) mode='record-only' ;; force | 2) mode=force ;; *) return 2 ;; esac
    vps_ufw_init || return $?
    vps_ufw_require_tools || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_ufw_lock || return $?
        VPS_UFW_FRAMES[VPS_UFW_DEPTH]='dry-run'
        VPS_UFW_MODES[VPS_UFW_DEPTH]="$mode"
        VPS_UFW_DEPTH=$((VPS_UFW_DEPTH + 1))
        vps_cmd_info "演练：记录并同步 UFW 服务范围 $scope（$mode）"
        return 0
    fi
    desired="$(_vps_ufw_normalize_desired "$file" "$scope")" || return $?
    vps_ufw_lock || return $?
    if ((VPS_UFW_DEPTH == 0)); then
        _vps_ufw_recover || {
            status=$?
            vps_ufw_unlock
            return "$status"
        }
        vps_cmd_require_no_symlink_components "$VPS_UFW_STATE_DIR/transactions" || {
            vps_ufw_unlock
            return 3
        }
        mkdir -p -- "$VPS_UFW_STATE_DIR/transactions" || {
            vps_ufw_unlock
            return 20
        }
        chmod 0700 -- "$VPS_UFW_STATE_DIR" "$VPS_UFW_STATE_DIR/transactions" || {
            vps_ufw_unlock
            return 20
        }
        VPS_UFW_WORK="$(mktemp -d "$VPS_UFW_STATE_DIR/transactions/tx.XXXXXX")" || {
            vps_ufw_unlock
            return 20
        }
        printf 'prepared\n' >"$VPS_UFW_WORK/decision" || {
            vps_ufw_unlock
            return 20
        }
        chmod 0600 -- "$VPS_UFW_WORK/decision" || {
            vps_ufw_unlock
            return 20
        }
    fi
    frame="$VPS_UFW_WORK/frame-$VPS_UFW_DEPTH"
    vps_ufw_snapshot "$frame" || {
        status=$?
        vps_ufw_unlock
        return "$status"
    }
    VPS_UFW_FRAMES[VPS_UFW_DEPTH]="$frame"
    VPS_UFW_MODES[VPS_UFW_DEPTH]="$mode"
    VPS_UFW_DEPTH=$((VPS_UFW_DEPTH + 1))
    if ((VPS_UFW_DEPTH == 1)); then
        _vps_ufw_journal_write prepared || {
            status=$?
            vps_ufw_rollback || return 30
            return "$status"
        }
    fi
    if [[ "$mode" != record-only ]]; then
        if vps_ufw_is_active; then active=1; else
            status=$?
            [[ "$status" == 1 ]] || {
                vps_ufw_rollback || return 30
                return "$status"
            }
        fi
    fi
    [[ "$mode" != force ]] || active=1
    if [[ "$active" == 1 ]] && ! command -v ufw >/dev/null 2>&1; then
        vps_cmd_error '强制同步规则需要先安装 UFW'
        vps_ufw_rollback || return 30
        return 3
    fi
    if [[ "$active" != 1 ]]; then VPS_UFW_MODES[VPS_UFW_DEPTH - 1]='record-only'; fi
    state="$(_vps_ufw_state)" || {
        status=$?
        vps_ufw_rollback || return 30
        return "$status"
    }
    state="$(_vps_ufw_prune_leases "$state")" || {
        status=$?
        vps_ufw_rollback || return 30
        return "$status"
    }
    if jq -e 'any(.[]; .temporary)' <<<"$desired" >/dev/null; then
        vps_ufw_lease_metadata || {
            status=$?
            vps_ufw_rollback || return 30
            return "$status"
        }
    else VPS_UFW_LEASE_JSON=null; fi
    state="$(jq --arg scope "$scope" --argjson desired "$desired" --argjson lease "$VPS_UFW_LEASE_JSON" '
      .revision = ((.revision // 0) + 1) |
      .requirements = ([.requirements[]|select(.scope!=$scope)] + $desired) |
      reduce $desired[] as $r (.; .links[$r.owner] = ((.links[$r.owner] // {detached:false}) + {scope:$scope}) |
        if $r.temporary then .leases[$r.owner]=$lease else . end) |
      . as $s | .leases |= with_entries(select(.key as $o | any($s.requirements[]; .owner==$o and .temporary)))' <<<"$state")" || {
        vps_ufw_rollback || return 30
        return 20
    }
    printf '%s\n' "$state" | _vps_ufw_save || {
        status=$?
        vps_ufw_rollback || return 30
        return "$status"
    }
    if [[ "$active" == 1 ]]; then
        _vps_ufw_apply_desired "$scope" || {
            status=$?
            vps_ufw_rollback || return 30
            return "$status"
        }
    else
        vps_cmd_info "UFW 未应用规则，仅保存 $scope 的服务需求"
    fi
}

vps_ufw_commit() {
    local mode status=0 directory
    ((${VPS_UFW_DEPTH:-0} > 0)) || return 0
    [[ "$VPS_UFW_PROCESS" == "$BASHPID" ]] || return 70
    if ((VPS_UFW_DEPTH > 1)); then
        VPS_UFW_DEPTH=$((VPS_UFW_DEPTH - 1))
        # A nested forced/live update also needs cleanup at the outer boundary.
        if [[ "${VPS_UFW_MODES[VPS_UFW_DEPTH]}" != record-only ]]; then VPS_UFW_MODES[0]=force; fi
        vps_ufw_unlock
        return 0
    fi
    mode="${VPS_UFW_MODES[0]}"
    directory="${VPS_UFW_WORK:-}"
    if [[ "${VPS_UFW_FRAMES[0]}" != dry-run ]]; then
        # A separate pre-created decision file survives a failure to replace
        # pending.json, so recovery cannot mistake an already running service
        # for an uncommitted prepare merely because metadata cleanup failed.
        printf 'committed\n' >"$directory/decision" || status=30
        if _vps_ufw_journal_write committing; then
            if [[ "$mode" != record-only ]]; then _vps_ufw_sweep || status=30; fi
        else status=30; fi
        if [[ "$status" == 0 ]]; then
            rm -f -- "$VPS_UFW_JOURNAL" || status=30
            [[ "$status" != 0 ]] || _vps_ufw_discard_directory "$directory" || status=30
        else
            _vps_ufw_journal_write cleanup-pending || true
            vps_cmd_error 'UFW 新规则与服务需求已保留；旧规则清理未完成，请运行 network ufw sync 重试'
        fi
    fi
    VPS_UFW_DEPTH=0
    VPS_UFW_WORK=''
    VPS_UFW_FRAMES=()
    VPS_UFW_MODES=()
    vps_ufw_unlock || return 70
    return "$status"
}

vps_ufw_rollback() {
    local frame status=0 directory
    ((${VPS_UFW_DEPTH:-0} > 0)) || return 0
    [[ "$VPS_UFW_PROCESS" == "$BASHPID" ]] || return 70
    frame="${VPS_UFW_FRAMES[VPS_UFW_DEPTH - 1]}"
    directory="${VPS_UFW_WORK:-}"
    if [[ "$frame" != dry-run ]]; then vps_ufw_restore "$frame" || status=30; fi
    VPS_UFW_DEPTH=$((VPS_UFW_DEPTH - 1))
    if ((VPS_UFW_DEPTH == 0)); then
        if [[ "$status" == 0 && "$frame" != dry-run ]]; then
            rm -f -- "$VPS_UFW_JOURNAL" || status=30
            [[ "$status" != 0 ]] || _vps_ufw_discard_directory "$directory" || status=30
        fi
        VPS_UFW_WORK=''
        VPS_UFW_FRAMES=()
        VPS_UFW_MODES=()
    fi
    vps_ufw_unlock || return 70
    [[ "$status" == 0 ]] || vps_cmd_error 'UFW 回滚失败，已保留 pending.json 和恢复快照'
    return "$status"
}

vps_ufw_link_set() {
    local owner="${1:-}" mode="${2:-}" state status=0
    [[ "$owner" =~ ^(ssh|node:[A-Za-z0-9_.-]+|forward:[A-Za-z0-9_.-]+|tls:[A-Za-z0-9_.-]+)$ ]] || return 2
    [[ "$mode" == attached || "$mode" == detached ]] || return 2
    vps_ufw_init || return $?
    vps_ufw_require_tools || return $?
    vps_ufw_lock || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：UFW $owner $mode"
        vps_ufw_unlock
        return 0
    fi
    if ((VPS_UFW_DEPTH == 0)); then _vps_ufw_recover || {
        status=$?
        vps_ufw_unlock
        return "$status"
    }; fi
    state="$(_vps_ufw_state)" || {
        status=$?
        vps_ufw_unlock
        return "$status"
    }
    state="$(_vps_ufw_jq '. as $s | .managed |= with_entries(
      .value.rule as $r | if any($s.requirements[]; .owner==$owner and same($r))
      then .value.preserve=$detached else . end) |
      .links[$owner] = ((.links[$owner] // {scope:""}) + {detached:$detached})' \
        --arg owner "$owner" --argjson detached "$([[ "$mode" == detached ]] && printf true || printf false)" <<<"$state")" || {
        vps_ufw_unlock
        return 20
    }
    printf '%s\n' "$state" | _vps_ufw_save || status=$?
    vps_ufw_unlock
    return "$status"
}

vps_ufw_scope_snapshot() {
    local scope="${1:-}" file="${2:-}" state rules status=0
    [[ "$scope" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 2
    vps_ufw_lock || return $?
    state="$(_vps_ufw_state)" || {
        status=$?
        vps_ufw_unlock
        return "$status"
    }
    rules="$(_vps_ufw_inventory_raw)" || {
        status=$?
        vps_ufw_unlock
        return "$status"
    }
    vps_cmd_require_no_symlink_components "$file" || {
        vps_ufw_unlock
        return 3
    }
    jq -n --arg scope "$scope" --argjson state "$state" --argjson rules "$rules" \
        '{version:1,scope:$scope,revision:($state.revision // 0),requirements:[$state.requirements[]|select(.scope==$scope)|del(.scope)],
        inventory:$rules,managed_ids:[$state.managed[].rule.id]}' >"$file" || status=20
    [[ "$status" != 0 ]] || chmod 0600 -- "$file" || status=20
    vps_ufw_unlock
    return "$status"
}

vps_ufw_scope_restore_begin() {
    local scope="${1:-}" file="${2:-}" state desired snapshot rules rule id number rank family active=0 status=0
    vps_cmd_require_no_symlink_components "$file" || return $?
    [[ -f "$file" ]] || return 3
    jq -e --arg scope "$scope" '.version==1 and .scope==$scope and (.requirements|type)=="array" and
      (.inventory|type)=="array" and (.managed_ids|type)=="array"' "$file" >/dev/null || return 3
    snapshot="$(cat -- "$file")" || return 20
    vps_ufw_lock || return $?
    desired="$(mktemp "${file%/*}/.ufw-desired.XXXXXX")" || {
        vps_ufw_unlock
        return 20
    }
    jq '.requirements' <<<"$snapshot" >"$desired" || {
        rm -f -- "$desired"
        vps_ufw_unlock
        return 20
    }
    vps_ufw_begin "$scope" "$desired" || {
        status=$?
        rm -f -- "$desired"
        vps_ufw_unlock
        return "$status"
    }
    rm -f -- "$desired"
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_ufw_unlock
        return 0
    fi
    state="$(_vps_ufw_state)" || {
        status=$?
        vps_ufw_rollback
        vps_ufw_unlock
        return "$status"
    }
    # Only newly adopted rules that were manual in the snapshot revert to manual.
    state="$(jq --argjson before "$snapshot" --arg scope "$scope" '. as $s |
      .managed |= with_entries(.value.rule.id as $id |
      if .value.origin=="adopted" and any($before.inventory[]; .id==$id) and
        ($before.managed_ids|index($id))==null and
        any($s.history[]; .scope==$scope and .rule.id==$id and
          (.revision // 0)>($before.revision // 0)) then .value.preserve=true else . end)' <<<"$state")" || {
        vps_ufw_rollback
        vps_ufw_unlock
        return 20
    }
    printf '%s\n' "$state" | _vps_ufw_save || {
        vps_ufw_rollback
        vps_ufw_unlock
        return 20
    }
    if vps_ufw_is_active; then active=1; else
        status=$?
        [[ "$status" == 1 ]] || {
            vps_ufw_rollback
            vps_ufw_unlock
            return "$status"
        }
    fi
    if [[ "$active" == 1 ]]; then
        # A committed SSH port change may have retired an original manual rule.
        # History proves which pre-snapshot rules this scope actually touched.
        while IFS= read -r rule; do
            id="$(jq -r '.id' <<<"$rule")"
            rules="$(_vps_ufw_inventory_raw)" || {
                vps_ufw_rollback
                vps_ufw_unlock
                return 3
            }
            jq -e --arg id "$id" 'any(.[];.id==$id)' <<<"$rules" >/dev/null && continue
            number="$(jq -r '.number' <<<"$rule")"
            family="$(jq -r '.family' <<<"$rule")"
            rank="$(jq --arg family "$family" --argjson number "$number" \
                '[.inventory[] | select(.family==$family) | .number] | unique | index($number)' <<<"$snapshot")" || {
                vps_ufw_rollback
                vps_ufw_unlock
                return 20
            }
            # UFW insert requires an existing slot in this address family. A
            # removed last rule must be appended, not inserted at length+1.
            number="$(jq -r --arg family "$family" --argjson rank "$rank" \
                '[.[] | select(.family==$family) | .number] | unique | .[$rank] // empty' <<<"$rules")" || {
                vps_ufw_rollback
                vps_ufw_unlock
                return 20
            }
            _vps_ufw_add_rule "$rule" "$(jq -r '.comment' <<<"$rule")" "$number" || {
                vps_ufw_rollback
                vps_ufw_unlock
                return 20
            }
        done < <(jq -c --arg scope "$scope" --argjson state "$state" '. as $before | .inventory[] as $r |
          select(any($state.history[]; .scope==$scope and .rule.id==$r.id and
            (.revision // 0)>($before.revision // 0) and
            $state.links[.owner // .scope].detached != true)) | $r' <<<"$snapshot")
    fi
    vps_ufw_unlock
}

vps_ufw_scope_restore() {
    vps_ufw_scope_restore_begin "$@" || return $?
    vps_ufw_commit
}
