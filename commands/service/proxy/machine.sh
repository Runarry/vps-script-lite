# shellcheck shell=bash
# Trusted local Agent API. Native records deliberately retain credentials.

proxy_machine_actions() {
    printf '%s\n' core.install core.update core.start core.stop core.restart core.uninstall \
        node.add node.edit node.delete node.switch node.ip-policy dns.set dns.reset \
        exit.add exit.edit exit.delete binding.add binding.delete \
        forward.add forward.edit forward.delete forward.refresh time.sync
}

proxy_machine_uuid_valid() {
    [[ "$1" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]]
}

proxy_machine_json_file() {
    local path="$1" default="$2"
    vps_cmd_require_no_symlink_components "$path" || return $?
    if [[ -e "$path" ]]; then
        [[ -f "$path" ]] || return 10
        jq -ce 'select(type == "object")' "$path"
    else
        printf '%s\n' "$default"
    fi
}

proxy_machine_profiles() {
    local id label cores
    while IFS=$'\t' read -r id label; do
        cores="$(proxy_profile_cores "$id" | jq -Rsc 'split("\n") | map(select(length > 0))')" || return $?
        jq -cn --arg id "$id" --arg label "$label" --argjson cores "$cores" \
            '{id:$id,label:$label,cores:$cores}' || return $?
    done < <(proxy_all_profiles)
}

# All callers hold proxy.lock. Include authoritative files, pending recovery
# state and generated configs in CAS; do not hash volatile service probes.
proxy_machine_snapshot_locked() {
    local work="$1" core path logical digest node uri forward exit_record port end version pins cert
    proxy_machine_json_file "$PROXY_MANIFEST" "$(proxy_manifest_default)" >"$work/manifest.json" || return $?
    proxy_manifest_validate_file "$work/manifest.json" || return $?
    proxy_machine_json_file "$PROXY_RELAY_FILE" "$(proxy_relay_default)" >"$work/relay.json" || return $?
    proxy_relay_validate_file "$work/relay.json" "$work/manifest.json" || return $?
    : >"$work/cores.jsonl"
    : >"$work/files.jsonl"
    for core in sing-box xray; do
        _proxy_core_status_record "$core" >>"$work/cores.jsonl" || return $?
    done
    for logical in "$PROXY_STATE_LOGICAL/cores/sing-box.json" "$PROXY_STATE_LOGICAL/cores/xray.json" \
        "$PROXY_STATE_LOGICAL/pending/sing-box.json" "$PROXY_STATE_LOGICAL/pending/xray.json" \
        "$PROXY_STATE_LOGICAL/transaction.json" "$PROXY_STATE_LOGICAL/transaction-core-switch-certs.json" \
        "$PROXY_ETC_LOGICAL/sing-box/config.json" "$PROXY_ETC_LOGICAL/xray/config.json"; do
        path="$(vps_cmd_system_path "$logical")" || return $?
        vps_cmd_require_no_symlink_components "$path" || return $?
        digest=""
        if [[ -e "$path" ]]; then
            [[ -f "$path" ]] || return 10
            digest="$(jq -Sc . "$path" | sha256sum)" || return $?
            digest="${digest%% *}"
        fi
        jq -cn --arg path "$logical" --arg digest "$digest" '{path:$path,sha256:$digest}' >>"$work/files.jsonl" || return $?
    done
    proxy_machine_profiles >"$work/profiles.jsonl" || return $?
    proxy_machine_actions | jq -Rsc 'split("\n") | map(select(length > 0))' >"$work/actions.json" || return $?
    : >"$work/exports.jsonl"
    while IFS= read -r node; do
        uri="$(proxy_node_render_uri_json "$node")" || return $?
        [[ -n "$uri" ]] || return 10
        pins='{}'
        cert="$(jq -r '.tls.certificate_path // empty' <<<"$node")"
        if [[ -n "$cert" ]]; then
            cert="$(vps_cmd_system_path "$cert")" || return $?
            vps_cmd_require_no_symlink_components "$cert" || return $?
            if [[ -r "$cert" ]] && command -v openssl >/dev/null 2>&1; then
                pins="$(_proxy_relay_certificate_pins "$cert")" || return $?
                pins="$(jq -c '{tlsSpkiSha256:.tls_spki_sha256,certificateSha256:.tls_cert_sha256}' <<<"$pins")" || return $?
            fi
        fi
        jq -c --arg uri "$uri" --argjson pins "$pins" '{id,name,core,kind:"node",uri:$uri} + $pins' <<<"$node" >>"$work/exports.jsonl" || return $?
    done < <(jq -c '.nodes[]' "$work/manifest.json")
    while IFS= read -r forward; do
        exit_record="$(jq -ce --arg id "$(jq -r '.exit_id' <<<"$forward")" '.exits[] | select(.id == $id)' "$work/relay.json")" || return 10
        # Direct address forwards have no protocol URI; their complete native
        # records remain in relay.forwards and relay.exits.
        [[ "$(jq -r '.type' <<<"$exit_record")" == protocol ]] || continue
        port="$(jq -r '.listen_port_start' <<<"$forward")"
        end="$(jq -r '.listen_port_end' <<<"$forward")"
        for (( ; port <= end; port++)); do
            uri="$(proxy_relay_uri_rewrite "$(jq -r '.uri' <<<"$exit_record")" "$(jq -r '.publish_address' <<<"$forward")" "$port")" || return $?
            jq -c --arg uri "$uri" --arg core "$(jq -r '.core' <<<"$exit_record")" --arg port "$port" \
                '{id:(.id+":"+$port),name:(.name+":"+$port),core:$core,kind:"forward",uri:$uri}' \
                <<<"$forward" >>"$work/exports.jsonl" || return $?
        done
    done < <(jq -c '.forwards[]' "$work/relay.json")
    version="$(<"$PROXY_PROJECT_ROOT/VERSION")"
    jq -cn --arg version "$version" --slurpfile manifest "$work/manifest.json" \
        --slurpfile relay "$work/relay.json" --slurpfile cores "$work/cores.jsonl" \
        --slurpfile profiles "$work/profiles.jsonl" --slurpfile actions "$work/actions.json" \
        --slurpfile exports "$work/exports.jsonl" --slurpfile files "$work/files.jsonl" \
        '{schemaVersion:1,vpsctlVersion:$version,capabilities:{actions:$actions[0],profiles:$profiles},
          cores:$cores,nativeManifest:$manifest[0],nodes:$manifest[0].nodes,relay:$relay[0],exports:$exports,
          pendingCores:[$cores[] | select(.pending_restart) | .core],configurationHashes:$files}' >"$work/snapshot.json" || return $?
    digest="$(jq -Sc '{nativeManifest,relay,configurationHashes,cores:[.cores[] | del(.running)],certificatePins:[.exports[] | select(.kind == "node") | {id,tlsSpkiSha256,certificateSha256}]}' "$work/snapshot.json" | sha256sum)" || return $?
    jq -c --arg revision "${digest%% *}" '. + {revision:$revision}' "$work/snapshot.json"
}

# Each action owns its option allowlist. Values become array elements, never
# shell text. Native functions retain validation and explicit dangerous flags.
proxy_machine_build_args() {
    local command="$1" action key type value allowed='' flags='' item
    local node_fields='name listen port address sni reality-anti-relay path service-name xhttp-mode host cert-mode cert-id cert-file key-file obfs up-mbps down-mbps hop-ports bbr-profile congestion-control ip-strategy'
    local exit_fields='name uri profile core target target-port tls-cert-file tls-spki-sha256 chrome-parrot bbr-profile hop-ports hop-interval bandwidth-mode up-mbps down-mbps'
    action="$(jq -r '.action' "$command")"
    PROXY_MACHINE_ARGS=()
    case "$action" in
        core.install)
            PROXY_MACHINE_ARGS=(install)
            allowed='core release-channel version'
            ;;
        core.update)
            PROXY_MACHINE_ARGS=(update)
            allowed='core release-channel version'
            flags='confirm-external-update'
            ;;
        core.start)
            PROXY_MACHINE_ARGS=(start)
            allowed=core
            flags=enable
            ;;
        core.stop)
            PROXY_MACHINE_ARGS=(stop)
            allowed=core
            flags=disable
            ;;
        core.restart)
            PROXY_MACHINE_ARGS=(restart)
            allowed=core
            flags=confirm-disruptive
            ;;
        core.uninstall)
            PROXY_MACHINE_ARGS=(uninstall)
            allowed=core
            flags='purge confirm-purge'
            ;;
        node.add)
            PROXY_MACHINE_ARGS=(node add)
            allowed="profile core $node_fields"
            ;;
        node.edit)
            PROXY_MACHINE_ARGS=(node edit)
            allowed="id $node_fields"
            ;;
        node.delete)
            PROXY_MACHINE_ARGS=(node delete)
            allowed=id
            flags='cascade-relay confirm-delete'
            ;;
        node.switch)
            PROXY_MACHINE_ARGS=(node core set)
            allowed='id core'
            flags=confirm-disruptive
            ;;
        node.ip-policy)
            PROXY_MACHINE_ARGS=(node ip-policy set)
            allowed='core id profile ip-strategy'
            flags=all
            ;;
        dns.set)
            PROXY_MACHINE_ARGS=(dns set)
            allowed='core mode server port tls-server-name path bootstrap preset'
            ;;
        dns.reset)
            PROXY_MACHINE_ARGS=(dns reset)
            allowed=core
            ;;
        exit.add)
            PROXY_MACHINE_ARGS=(relay exit add)
            allowed="$exit_fields"
            ;;
        exit.edit)
            PROXY_MACHINE_ARGS=(relay exit edit)
            allowed="id $exit_fields"
            ;;
        exit.delete)
            PROXY_MACHINE_ARGS=(relay exit delete)
            allowed=id
            flags='cascade confirm-cascade'
            ;;
        binding.add)
            PROXY_MACHINE_ARGS=(relay bind add)
            allowed='node-id exit-id'
            ;;
        binding.delete)
            PROXY_MACHINE_ARGS=(relay bind delete)
            allowed=id
            flags=confirm-delete
            ;;
        forward.add)
            PROXY_MACHINE_ARGS=(relay forward add)
            allowed='name exit-id listen-ports network family address'
            ;;
        forward.edit)
            PROXY_MACHINE_ARGS=(relay forward edit)
            allowed='id name exit-id listen-ports network family address'
            ;;
        forward.delete)
            PROXY_MACHINE_ARGS=(relay forward delete)
            allowed=id
            flags=confirm-delete
            ;;
        forward.refresh)
            PROXY_MACHINE_ARGS=(relay forward refresh)
            allowed=id
            ;;
        time.sync) PROXY_MACHINE_ARGS=(time sync) ;;
        *) return 2 ;;
    esac
    while IFS= read -r key; do
        type="$(jq -r --arg key "$key" '.params[$key] | type' "$command")" || return 2
        if [[ "$key" == install-deps ]]; then
            [[ "$type" == boolean ]] || return 2
        elif [[ " $flags " == *" $key "* ]]; then
            [[ "$type" == boolean ]] || return 2
            [[ "$(jq -r --arg key "$key" '.params[$key]' "$command")" == false ]] || PROXY_MACHINE_ARGS+=("--$key")
        elif [[ " $allowed " == *" $key "* ]]; then
            if [[ "$type" == array ]]; then
                [[ "$action" == node.ip-policy && "$key" == id ]] || return 2
                while IFS= read -r item; do
                    IFS= read -r -d '' value < <(jq -j '., "\u0000"' <<<"$item") || return 2
                    PROXY_MACHINE_ARGS+=("--$key" "$value")
                done < <(jq -c --arg key "$key" '.params[$key][]' "$command")
            else
                [[ "$type" == string || "$type" == number ]] || return 2
                IFS= read -r -d '' value < <(jq -j --arg key "$key" '.params[$key], "\u0000"' "$command") || return 2
                PROXY_MACHINE_ARGS+=("--$key" "$value")
            fi
        else
            return 2
        fi
    done < <(jq -r '.params | keys[]' "$command")
    case "$action" in
        node.delete | binding.delete | forward.delete) PROXY_MACHINE_ARGS+=(--confirm-delete) ;;
    esac
}

proxy_machine_result_json() {
    jq -cn --arg id "$1" --arg status "$2" --argjson code "$3" --arg message "$4" --arg revision "$5" \
        '{schemaVersion:1,requestId:$id,status:$status,exitCode:$code,message:$message,revision:$revision}'
}

proxy_machine_receipt_write() {
    local id="$1" hash="$2" result="$3" dir="$PROXY_STATE_DIR/machine-requests"
    vps_cmd_require_no_symlink_components "$dir/$id.json" || return $?
    mkdir -p -- "$dir" || return 20
    chmod 0700 -- "$PROXY_STATE_DIR" "$dir" || return 20
    jq -cn --arg hash "$hash" --argjson result "$result" '{payloadHash:$hash,result:$result}' |
        vps_cmd_atomic_write "$PROXY_STATE_LOGICAL/machine-requests/$id.json" 0600
}

# Determine activation dependencies from the request and both native snapshots.
# Deleted bindings/nodes and both ends of a core switch still exist in before.
proxy_machine_affected_pending() {
    jq -cn --slurpfile command "$1" --slurpfile before "$2" --slurpfile after "$3" '
      $command[0] as $request | $request.action as $action | $request.params as $params |
      $before[0] as $old | $after[0] as $new |
      def node_cores($ids):
        [$old.nodes[], $new.nodes[] | select(.id as $id | $ids | index($id)) | .core];
      (if ($action | startswith("core.")) then
         if $params.core == "all" then ["sing-box","xray"]
         elif $params.core != null then [$params.core]
         else [$old.cores[] | select(
           if $action == "core.install" then (.installed | not)
           elif $action == "core.start" then .installed and (.running | not)
           elif $action == "core.stop" or $action == "core.restart" then .installed and .running
           else .installed end) | .core] end
       elif $action == "node.add" then
         [$new.nodes[] | select(.id as $id | [$old.nodes[].id] | index($id) | not) | .core]
       elif $action == "node.ip-policy" then [$params.core]
       elif ($action | startswith("node.")) then node_cores([$params.id])
       elif ($action | startswith("dns.")) then [$params.core // "sing-box"]
       elif $action == "binding.add" then node_cores([$params["node-id"]])
       elif $action == "binding.delete" then
         node_cores([$old.relay.bindings[], $new.relay.bindings[] | select(.id == $params.id) | .node_id])
       elif $action == "exit.delete" or $action == "exit.edit" then
         # A name-only exit edit never regenerates a core configuration.
         if $action == "exit.edit" and
           ([$params | keys[] | select(. != "id" and . != "name" and . != "install-deps")] | length) == 0
         then []
         else node_cores([$old.relay.bindings[], $new.relay.bindings[] |
                          select(.exit_id == $params.id) | .node_id]) end
       else [] end | unique) as $affected |
       [$new.pendingCores[] | select(. as $core | $affected | index($core))]
    '
}

# Globals below are consumed by native proxy modules in the inherited subshell.
# shellcheck disable=SC2034
proxy_machine_apply_locked() {
    local work="$1" id expected hash revision receipt stored_hash result status code=0 message snapshot pending
    id="$(jq -r '.requestId' "$work/command.json")"
    expected="$(jq -r '.expectedRevision' "$work/command.json")"
    hash="$(jq -Sc . "$work/command.json" | sha256sum)" || return $?
    hash="${hash%% *}"
    receipt="$PROXY_STATE_DIR/machine-requests/$id.json"
    vps_cmd_require_no_symlink_components "$receipt" || return $?
    if [[ -e "$receipt" ]]; then
        [[ -f "$receipt" ]] || return 10
        stored_hash="$(jq -er '.payloadHash' "$receipt")" || return 10
        if [[ "$stored_hash" == "$hash" ]]; then
            jq -ce '.result' "$receipt"
            return
        fi
        revision="$(jq -er '.result.revision' "$receipt")" || return 10
        proxy_machine_result_json "$id" conflict 2 'Request ID already belongs to a different payload.' "$revision"
        return 0
    fi
    snapshot="$(proxy_machine_snapshot_locked "$work")" || return $?
    revision="$(jq -r '.revision' <<<"$snapshot")"
    if [[ "$expected" != "$revision" ]]; then
        result="$(proxy_machine_result_json "$id" conflict 3 'Configuration changed; refresh the snapshot before creating another request.' "$revision")" || return $?
    elif ! proxy_machine_build_args "$work/command.json"; then
        result="$(proxy_machine_result_json "$id" failed 2 'Unsupported action, option or parameter type.' "$revision")" || return $?
    else
        printf '%s\n' "$snapshot" >"$work/before.json" || return 20
        # Persist before invoking any native mutation. An interrupted request
        # remains unknown and is never run again, including after process death.
        result="$(proxy_machine_result_json "$id" unknown 30 'Execution outcome is unknown; inspect current state before issuing a new request.' "$revision")" || return $?
        proxy_machine_receipt_write "$id" "$hash" "$result" || return $?
        VPSCTL_ASSUME_YES=1
        VPSCTL_NON_INTERACTIVE=1
        PROXY_INTERACTIVE=0
        # Native stdout can include links and stderr can include arguments.
        # Neither is a safe remote diagnostic. Preserve their numeric outcome.
        (
            # Per-request authorization applies only to the native operation.
            # The native dependency installer and its checks remain unchanged.
            if jq -e '.params["install-deps"] == true' "$work/command.json" >/dev/null; then
                VPSCTL_INSTALL_DEPS=1
            fi
            vps_cmd_with_inherited_lock proxy_dispatch "${PROXY_MACHINE_ARGS[@]}"
        ) >/dev/null 2>&1 || code=$?
        if ! snapshot="$(proxy_machine_snapshot_locked "$work")"; then
            printf '%s\n' "$result"
            return 0
        fi
        revision="$(jq -r '.revision' <<<"$snapshot")"
        if ((code != 0)); then
            status=failed
            message='Native operation failed; inspect current state and native recovery information.'
        else
            printf '%s\n' "$snapshot" >"$work/after.json" || return 20
            pending="$(proxy_machine_affected_pending "$work/command.json" "$work/before.json" "$work/after.json")" || {
                printf '%s\n' "$result"
                return 0
            }
            if jq -e 'length > 0' >/dev/null <<<"$pending"; then
                status=pending_restart
                message='Configuration saved; an affected core restart is still pending.'
            else
                status=applied
                message='Native operation completed.'
            fi
        fi
        result="$(proxy_machine_result_json "$id" "$status" "$code" "$message" "$revision")" || return $?
    fi
    proxy_machine_receipt_write "$id" "$hash" "$result" || return $?
    printf '%s\n' "$result"
}

proxy_machine_dispatch() (
    local action="${1:-}" work='' id='' receipt snapshot revision
    (($# > 0)) || return 2
    shift
    case "$action" in
        snapshot | apply) (($# == 0)) || return 2 ;;
        result)
            (($# == 2)) && [[ "$1" == --id ]] && proxy_machine_uuid_valid "$2" || return 2
            id="$2"
            ;;
        *) return 2 ;;
    esac
    [[ "${VPSCTL_DRY_RUN:-0}" == 0 ]] || {
        vps_cmd_error 'machine 不支持 --dry-run'
        return 2
    }
    proxy_require_state_access || return $?
    proxy_ensure_tools machine jq sha256sum flock base64 || return $?
    work="$(mktemp -d)" || return 20
    trap 'rm -rf -- "$work"; vps_cmd_unlock' EXIT
    if [[ "$action" == apply ]]; then
        # Exactly one envelope; reject NUL before converting JSON to Bash args.
        cat >"$work/input.json" || return 20
        jq -ces 'if length == 1 then .[0] else error("one command required") end' "$work/input.json" >"$work/command.json" 2>/dev/null || return 2
        jq -e '
          def text: type == "string" and length <= 65536 and (contains("\u0000") | not);
          type == "object" and keys == ["action","expectedRevision","params","requestId","schemaVersion"] and
          .schemaVersion == 1 and (.requestId | type == "string" and test("^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$")) and
          (.expectedRevision | type == "string" and test("^[a-f0-9]{64}$")) and (.action | text) and
          (.params | type == "object" and all(to_entries[];
            (.key | test("^[a-z][a-z0-9-]*$")) and
            (.value | if type == "array" then length <= 2000 and all(.[]; text)
                      else text or type == "number" or type == "boolean" end)))
          ' "$work/command.json" >/dev/null 2>&1 || {
            vps_cmd_error '无效 MachineCommand'
            return 2
        }
    fi
    vps_cmd_lock proxy || return $?
    case "$action" in
        snapshot) proxy_machine_snapshot_locked "$work" ;;
        apply) proxy_machine_apply_locked "$work" ;;
        result)
            receipt="$PROXY_STATE_DIR/machine-requests/$id.json"
            vps_cmd_require_no_symlink_components "$receipt" || return $?
            if [[ -f "$receipt" ]]; then
                jq -ce '.result' "$receipt"
            else
                snapshot="$(proxy_machine_snapshot_locked "$work")" || return $?
                revision="$(jq -r '.revision' <<<"$snapshot")"
                proxy_machine_result_json "$id" unknown 30 'No receipt exists for this request ID.' "$revision" | jq -c '. + {found:false}'
            fi
            ;;
    esac
)
