#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

export VPSCTL_PROXY_TEST_HARNESS_ONLY=1
# shellcheck source=test-service-proxy.sh disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-service-proxy.sh"
unset VPSCTL_PROXY_TEST_HARNESS_ONLY
# This suite verifies mutual exclusion with the real OS lock, not the older
# harness's no-op flock fixture.
rm -f -- "$TEST_FAKE_BIN/flock"

machine_snapshot() {
    run_proxy machine snapshot
    assert_equal 0 "$RUN_STATUS" 'machine snapshot status'
    assert_json "$RUN_OUTPUT" 'machine snapshot clean JSON'
}

machine_request() {
    jq -cn --arg id "$1" --arg revision "$2" --arg action "$3" --argjson params "$4" \
        '{schemaVersion:1,requestId:$id,expectedRevision:$revision,action:$action,params:$params}'
}

machine_apply() {
    local request="$1"
    if RUN_OUTPUT="$(bash "$TEST_PROXY" machine apply <<<"$request" 2>"$TEST_TEMP/machine.stderr")"; then RUN_STATUS=0; else RUN_STATUS=$?; fi
    assert_equal 0 "$RUN_STATUS" 'machine apply transport'
    assert_json "$RUN_OUTPUT" 'machine apply clean JSON'
}

test_machine_empty() {
    local first
    reset_root
    machine_snapshot
    jq -e '.schemaVersion == 1 and .nodes == [] and .relay.exits == [] and .relay.bindings == [] and
        .relay.forwards == [] and .exports == [] and (.cores | length == 2) and
        (.capabilities.profiles | length > 10) and (.capabilities.actions | length == 23) and
        (.revision | test("^[a-f0-9]{64}$"))' <<<"$RUN_OUTPUT" >/dev/null || fail 'complete empty machine snapshot'
    first="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    machine_snapshot
    assert_equal "$first" "$(jq -r '.revision' <<<"$RUN_OUTPUT")" 'stable snapshot revision'
    [[ ! -f "$(manifest_path)" ]] || fail 'snapshot initialized native manifest'
    run_proxy machine result --id 11111111-1111-4111-8111-111111111111
    jq -e '.status == "unknown" and .found == false' <<<"$RUN_OUTPUT" >/dev/null || fail 'missing request contract'
    run_proxy --dry-run machine snapshot
    assert_equal 2 "$RUN_STATUS" 'machine rejects dry-run'
}

test_machine_native_and_requests() {
    local revision request result id uri state_hash receipt changed
    reset_root
    install_external sing-box 1.13.0
    machine_snapshot
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    request="$(machine_request 11111111-1111-4111-8111-111111111111 "$revision" node.add \
        '{"profile":"vless-reality-vision","core":"sing-box","name":"machine-node","port":33490,"address":"proxy.example","sni":"reality.example","reality-anti-relay":"on"}')"
    machine_apply "$request"
    jq -e '.status == "applied" and .exitCode == 0' <<<"$RUN_OUTPUT" >/dev/null || fail 'native mutation using inherited lock'
    result="$RUN_OUTPUT"
    id="$(node_id_by_name machine-node)"
    run_proxy node show --id "$id" --uri
    uri="$RUN_OUTPUT"
    machine_snapshot
    jq -e --arg uri "$uri" --slurpfile manifest "$(manifest_path)" '.nativeManifest == $manifest[0] and
        .nodes == $manifest[0].nodes and .nodes[0].credentials.uuid != null and
        .nodes[0].tls.reality_guard.enabled == true and .exports[0].uri == $uri' <<<"$RUN_OUTPUT" >/dev/null || fail 'complete native credentials and native URI'
    machine_apply "$request"
    assert_equal "$result" "$RUN_OUTPUT" 'same request replays original receipt'
    assert_equal 1 "$(jq '.nodes | length' "$(manifest_path)")" 'duplicate creates no second node'
    changed="$(jq -c '.params.name="collision"' <<<"$request")"
    machine_apply "$changed"
    jq -e '.status == "conflict" and .exitCode == 2' <<<"$RUN_OUTPUT" >/dev/null || fail 'same ID different payload rejected'
    run_proxy machine result --id 11111111-1111-4111-8111-111111111111
    assert_equal "$result" "$RUN_OUTPUT" 'collision preserved original receipt'
    request="$(machine_request 22222222-2222-4222-8222-222222222222 "$revision" node.delete "$(jq -cn --arg id "$id" '{id:$id}')")"
    machine_apply "$request"
    jq -e '.status == "conflict" and .exitCode == 3' <<<"$RUN_OUTPUT" >/dev/null || fail 'stale revision rejected'
    assert_equal 1 "$(jq '.nodes | length' "$(manifest_path)")" 'stale command left nodes intact'

    run_proxy stop --core sing-box
    set_release_scenario default
    run_proxy update --core sing-box --version v1.13.1 --confirm-external-update
    assert_equal 0 "$RUN_STATUS" 'native core update leaves pending restart'
    machine_snapshot
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    request="$(machine_request 33333333-3333-4333-8333-333333333333 "$revision" dns.set '{"preset":"cloudflare-doh"}')"
    machine_apply "$request"
    jq -e '.status == "pending_restart" and .exitCode == 0' <<<"$RUN_OUTPUT" >/dev/null || fail 'pending DNS not falsely applied'
    machine_snapshot
    jq -e '.nativeManifest.settings.sing_box.dns.mode == "doh" and .pendingCores == ["sing-box"]' <<<"$RUN_OUTPUT" >/dev/null || fail 'DNS and pending retained'
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    request="$(machine_request 44444444-4444-4444-8444-444444444444 "$revision" core.restart '{"core":"sing-box"}')"
    machine_apply "$request"
    jq -e '.status == "applied"' <<<"$RUN_OUTPUT" >/dev/null || fail 'pending restart applied normally'
    machine_snapshot
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    request="$(machine_request 55555555-5555-4555-8555-555555555555 "$revision" node.delete "$(jq -cn --arg id "$id" '{id:$id}')")"
    machine_apply "$request"
    jq -e '.status == "applied"' <<<"$RUN_OUTPUT" >/dev/null || fail 'authorized normal deletion needs no second confirmation'
    assert_equal 0 "$(jq '.nodes | length' "$(manifest_path)")" 'node removed'

    machine_snapshot
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    request="$(machine_request 66666666-6666-4666-8666-666666666666 "$revision" core.uninstall '{"core":"sing-box","purge":true}')"
    machine_apply "$request"
    jq -e '.status == "failed" and .exitCode == 3' <<<"$RUN_OUTPUT" >/dev/null || fail 'purge still requires explicit dangerous flag'
    state_hash="$(sha256sum "$(manifest_path)")"
    request="$(machine_request 77777777-7777-4777-8777-777777777777 "$revision" node.add '{"profile":"socks5","shell":"touch /bad"}')"
    machine_apply "$request"
    jq -e '.status == "failed" and .exitCode == 2' <<<"$RUN_OUTPUT" >/dev/null || fail 'option allowlist'
    assert_equal "$state_hash" "$(sha256sum "$(manifest_path)")" 'unknown option no mutation'
    assert_not_contains "$RUN_OUTPUT" '/bad' 'receipt does not echo arguments'
    request="$(machine_request 88888888-8888-4888-8888-888888888888 "$revision" tunnel.apply '{}')"
    machine_apply "$request"
    jq -e '.status == "failed" and .exitCode == 2' <<<"$RUN_OUTPUT" >/dev/null || fail 'tunnel stays outside native API'

    receipt="$TEST_SYSTEM_ROOT/var/lib/vpsctl/service/proxy/machine-requests/11111111-1111-4111-8111-111111111111.json"
    assert_equal 600 "$(stat -c %a "$receipt")" 'private receipt permissions'
    assert_not_contains "$(cat "$receipt")" 'private-secret' 'receipt contains no native credentials'
}

test_machine_lock_and_interruption() {
    local revision request lock_fd pid receipt attempt result
    reset_root
    install_external sing-box 1.13.0
    machine_snapshot
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    request="$(machine_request aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa "$revision" dns.set '{"preset":"cloudflare-doh"}')"
    exec {lock_fd}>"$TEST_SYSTEM_ROOT/run/vpsctl/proxy.lock"
    flock -n "$lock_fd"
    run_proxy machine snapshot
    assert_equal 3 "$RUN_STATUS" 'snapshot shares proxy lock'
    if RUN_OUTPUT="$(bash "$TEST_PROXY" machine apply <<<"$request" 2>&1)"; then RUN_STATUS=0; else RUN_STATUS=$?; fi
    assert_equal 3 "$RUN_STATUS" 'apply cannot check CAS outside native lock'
    [[ ! -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/service/proxy/machine-requests/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.json" ]] || fail 'busy lock wrote receipt'
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    run_proxy dns set --preset cloudflare-doh
    assert_equal 0 "$RUN_STATUS" 'native mutation after lock release'
    machine_apply "$request"
    jq -e '.status == "conflict"' <<<"$RUN_OUTPUT" >/dev/null || fail 'CAS observes native change after lock'

    machine_snapshot
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    request="$(machine_request bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb "$revision" dns.reset '{}')"
    printf '%s\n' "$request" >"$TEST_TEMP/crash-command.json"
    # Isolated process group: killing it cannot leave a native mutation running.
    setsid bash "$TEST_PROXY" machine apply <"$TEST_TEMP/crash-command.json" >"$TEST_TEMP/crash-output" 2>"$TEST_TEMP/crash-stderr" &
    pid=$!
    receipt="$TEST_SYSTEM_ROOT/var/lib/vpsctl/service/proxy/machine-requests/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.json"
    for ((attempt = 0; attempt < 500; attempt++)); do
        [[ ! -f "$receipt" ]] || break
        sleep .01
    done
    [[ -f "$receipt" ]] || fail 'pre-mutation receipt missing'
    kill -KILL -- "-$pid"
    wait "$pid" 2>/dev/null || true
    run_proxy machine result --id bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
    jq -e '.status == "unknown" and .found != false' <<<"$RUN_OUTPUT" >/dev/null || fail 'interrupted request unknown'
    result="$RUN_OUTPUT"
    machine_apply "$request"
    assert_equal "$result" "$RUN_OUTPUT" 'interrupted request never retried'
}

test_machine_relay_and_tls() {
    local id uri exit_id forward_id revision request pins snapshot
    reset_root
    printf '198.51.100.22\n' >"$TEST_SYSTEM_ROOT/run/dns-ahostsv4-proxy.example"
    install_external sing-box 1.13.0
    run_proxy node add --profile trojan-ws-tls --core sing-box --name machine-tls --port 33491 \
        --address proxy.example --sni tls.example --path '/route?native=1'
    assert_equal 0 "$RUN_STATUS" 'TLS node fixture'
    id="$(node_id_by_name machine-tls)"
    run_proxy node show --id "$id" --uri
    uri="$RUN_OUTPUT"
    machine_snapshot
    snapshot="$RUN_OUTPUT"
    pins="$(jq -r '.exports[0].tlsSpkiSha256' <<<"$snapshot")"
    [[ "$pins" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail 'TLS SPKI export'
    jq -e '.exports[0].certificateSha256 | test("^[a-f0-9]{64}$")' <<<"$snapshot" >/dev/null || fail 'TLS certificate fingerprint export'
    revision="$(jq -r '.revision' <<<"$snapshot")"
    request="$(machine_request cccccccc-cccc-4ccc-8ccc-cccccccccccc "$revision" exit.add \
        "$(jq -cn --arg uri "$uri" --arg pin "$pins" '{name:"machine-exit",uri:$uri,core:"sing-box","tls-spki-sha256":$pin}')")"
    machine_apply "$request"
    jq -e '.status == "applied"' <<<"$RUN_OUTPUT" >/dev/null || fail 'protocol exit with TLS SPKI'
    exit_id="$(jq -r '.exits[0].id' "$(relay_path)")"
    run_proxy relay bind add --node-id "$id" --exit-id "$exit_id"
    assert_equal 0 "$RUN_STATUS" 'native binding fixture'
    machine_snapshot
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    request="$(machine_request dddddddd-dddd-4ddd-8ddd-dddddddddddd "$revision" forward.add \
        "$(jq -cn --arg id "$exit_id" '{name:"machine-forward","exit-id":$id,"listen-ports":"33492-33493",network:"tcp",family:"ipv4",address:"entry.example"}')")"
    machine_apply "$request"
    jq -e '.status == "applied"' <<<"$RUN_OUTPUT" >/dev/null || fail "machine forward add: $RUN_OUTPUT"
    forward_id="$(jq -r '.forwards[0].id' "$(relay_path)")"
    run_proxy relay forward show --id "$forward_id" --uris
    uri="$RUN_OUTPUT"
    machine_snapshot
    jq -e --slurpfile relay "$(relay_path)" --arg uris "$uri" '.relay == $relay[0] and
        (.relay.bindings | length == 1) and (.exports | length == 3) and
        ([.exports[] | select(.kind == "forward") | .uri] | join("\n")) == $uris and
        .relay.exits[0].client_options.tls_spki_sha256 != null' <<<"$RUN_OUTPUT" >/dev/null || fail 'complete relay and native forward URIs'
    # A failed native write still invokes its original validation/rollback path.
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    touch "$TEST_SYSTEM_ROOT/run/fail-core-validation"
    request="$(machine_request eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee "$revision" node.edit \
        "$(jq -cn --arg id "$id" '{id:$id,name:"must-not-commit"}')")"
    machine_apply "$request"
    jq -e '.status == "failed" and .exitCode == 10' <<<"$RUN_OUTPUT" >/dev/null || fail 'native validation failure retained'
    assert_equal machine-tls "$(jq -r '.nodes[0].name' "$(manifest_path)")" 'failed write kept native state'
}

test_machine_install_deps() {
    local revision request observed invalid index=1
    reset_root
    install_external sing-box 1.13.0
    cp -- "$TEST_FAKE_BIN/systemctl" "$TEST_FAKE_BIN/systemctl-original"
    # These variables expand in the fixture process, not while writing it.
    # shellcheck disable=SC2016
    make_mock systemctl '
printf "%s %s\n" "${VPSCTL_INSTALL_DEPS:-unset}" "${1:-}" >>"$VPSCTL_SYSTEM_ROOT/run/deps-observed"
exec "${0%/*}/systemctl-original" "$@"'
    export VPSCTL_INSTALL_DEPS=0
    observed="$TEST_SYSTEM_ROOT/run/deps-observed"
    machine_snapshot
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    request="$(machine_request ffffffff-ffff-4fff-8fff-fffffffffff1 "$revision" core.stop '{"core":"sing-box","install-deps":true}')"
    machine_apply "$request"
    jq -e '.status == "applied"' <<<"$RUN_OUTPUT" >/dev/null || fail 'explicit dependency authorization accepted'
    assert_file_contains "$observed" '1 stop' 'native operation sees dependency authorization'
    assert_file_contains "$observed" '0 is-active' 'outer snapshots keep original dependency setting'
    assert_equal 0 "$VPSCTL_INSTALL_DEPS" 'request did not modify outer authorization'
    machine_snapshot
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    request="$(machine_request ffffffff-ffff-4fff-8fff-fffffffffff2 "$revision" core.start '{"core":"sing-box","install-deps":false}')"
    machine_apply "$request"
    jq -e '.status == "applied"' <<<"$RUN_OUTPUT" >/dev/null || fail 'false dependency flag omitted from native argv'
    assert_file_contains "$observed" '0 start' 'false does not enable native dependency install'
    machine_snapshot
    revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
    request="$(machine_request ffffffff-ffff-4fff-8fff-fffffffffff3 "$revision" core.stop '{"core":"sing-box"}')"
    machine_apply "$request"
    jq -e '.status == "applied"' <<<"$RUN_OUTPUT" >/dev/null || fail 'missing dependency flag accepted'
    assert_file_contains "$observed" '0 stop' 'missing flag does not leak earlier authorization'
    : >"$observed"
    for invalid in '"true"' '1' '[]'; do
        request="$(machine_request "ffffffff-ffff-4fff-8fff-ffffffffff0$index" "$revision" core.start \
            "$(jq -cn --argjson value "$invalid" '{core:"sing-box","install-deps":$value}')")"
        machine_apply "$request"
        jq -e '.status == "failed" and .exitCode == 2' <<<"$RUN_OUTPUT" >/dev/null || fail 'nonboolean dependency flag rejected'
        index=$((index + 1))
    done
    assert_not_contains "$(cat "$observed")" ' start' 'invalid dependency flags never invoke native mutation'
    mv -- "$TEST_FAKE_BIN/systemctl-original" "$TEST_FAKE_BIN/systemctl"
    unset VPSCTL_INSTALL_DEPS
}

test_machine_pending_scope() {
    local sb_id xr_id exit_id bind_id uri pending_before sequence=0 revision request
    reset_root
    install_external sing-box 1.13.0
    install_external xray 26.9.8
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box --name pending-sb --port 33501 --address 198.51.100.21
    assert_equal 0 "$RUN_STATUS" 'sing-box pending-scope fixture'
    sb_id="$(node_id_by_name pending-sb)"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name pending-xr --port 33502 --address 198.51.100.22
    assert_equal 0 "$RUN_STATUS" 'Xray pending-scope fixture'
    xr_id="$(node_id_by_name pending-xr)"
    set_release_scenario default
    run_proxy update --core xray --version v26.9.9 --confirm-external-update
    assert_equal 0 "$RUN_STATUS" 'native Xray update pending fixture'
    pending_before="$(cat "$TEST_SYSTEM_ROOT/var/lib/vpsctl/service/proxy/pending/xray.json")"

    # Each operation uses the latest CAS revision and executes native code.
    machine_pending_apply() {
        local action="$1" params="$2" expected="$3"
        sequence=$((sequence + 1))
        machine_snapshot
        revision="$(jq -r '.revision' <<<"$RUN_OUTPUT")"
        request="$(machine_request "00000000-0000-4000-8000-$(printf '%012d' "$sequence")" "$revision" "$action" "$params")"
        machine_apply "$request"
        assert_equal "$expected" "$(jq -r '.status' <<<"$RUN_OUTPUT")" "$action pending scope"
    }

    machine_pending_apply core.restart '{"core":"sing-box"}' applied
    machine_pending_apply node.edit "$(jq -cn --arg id "$sb_id" '{id:$id,name:"pending-sb-edited"}')" applied
    machine_pending_apply dns.set '{"preset":"cloudflare-doh"}' applied
    machine_pending_apply exit.add '{"name":"pending-direct","target":"198.51.100.23","target-port":443}' applied
    exit_id="$(jq -r '.exits[] | select(.name == "pending-direct") | .id' "$(relay_path)")"
    machine_pending_apply forward.add "$(jq -cn --arg id "$exit_id" \
        '{name:"pending-forward","exit-id":$id,"listen-ports":"33503",network:"tcp",family:"ipv4",address:"entry.example"}')" applied
    machine_pending_apply time.sync '{}' applied
    assert_equal "$pending_before" "$(cat "$TEST_SYSTEM_ROOT/var/lib/vpsctl/service/proxy/pending/xray.json")" 'unrelated operations preserve Xray pending'

    machine_pending_apply node.edit "$(jq -cn --arg id "$xr_id" '{id:$id,name:"pending-xr-edited"}')" pending_restart
    run_proxy node show --id "$xr_id" --uri
    assert_equal 0 "$RUN_STATUS" 'Xray exit URI fixture'
    uri="$RUN_OUTPUT"
    machine_pending_apply exit.add "$(jq -cn --arg uri "$uri" '{name:"pending-protocol",uri:$uri,core:"xray"}')" applied
    exit_id="$(jq -r '.exits[] | select(.name == "pending-protocol") | .id' "$(relay_path)")"
    machine_pending_apply binding.add "$(jq -cn --arg node "$xr_id" --arg exit "$exit_id" '{"node-id":$node,"exit-id":$exit}')" pending_restart
    bind_id="$(jq -r '.bindings[] | .id' "$(relay_path)")"
    uri="${uri/198.51.100.22/198.51.100.24}"
    machine_pending_apply exit.edit "$(jq -cn --arg id "$exit_id" --arg uri "$uri" '{id:$id,uri:$uri}')" pending_restart
    machine_pending_apply exit.edit "$(jq -cn --arg id "$exit_id" '{id:$id,name:"renamed-only"}')" applied
    machine_pending_apply binding.delete "$(jq -cn --arg id "$bind_id" '{id:$id}')" pending_restart
    machine_pending_apply core.start '{"core":"xray"}' failed
    unset -f machine_pending_apply
}

if [[ "${VPSCTL_TEST_ONLY:-}" == machine-pending ]]; then
    test_machine_pending_scope
elif [[ "${VPSCTL_TEST_ONLY:-}" == machine-deps ]]; then
    test_machine_install_deps
elif [[ "${VPSCTL_TEST_ONLY:-}" == machine-relay ]]; then
    test_machine_relay_and_tls
else
    test_machine_empty
    test_machine_native_and_requests
    test_machine_lock_and_interruption
    test_machine_relay_and_tls
    test_machine_install_deps
    test_machine_pending_scope
fi
printf 'PASS: proxy machine snapshots, CAS, native operations and durable receipts\n'
