#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
readonly TEST_PROXY="${TEST_ROOT}/commands/service/proxy.sh"
TEST_TEMP="$(mktemp -d)"
readonly TEST_TEMP
TEST_SYSTEM_ROOT="${TEST_TEMP}/root"
TEST_FAKE_BIN="${TEST_TEMP}/bin"
MOCK_LOG="${TEST_TEMP}/mock.log"
readonly TEST_SYSTEM_ROOT TEST_FAKE_BIN MOCK_LOG
REAL_SHA256SUM="$(command -v sha256sum)"
REAL_JQ="$(command -v jq)"
readonly REAL_SHA256SUM REAL_JQ
trap 'rm -rf -- "$TEST_TEMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'${RUN_OUTPUT:+; last output: $RUN_OUTPUT}"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpectedly contained '$2'"; }
assert_file_contains() { [[ -f "$1" ]] || fail "$3: missing file $1"; grep -Fq -- "$2" "$1" || fail "$3: missing '$2'"; }
assert_json() { jq -e . >/dev/null 2>&1 <<<"$1" || fail "$2: invalid JSON"; }

mkdir -p "$TEST_FAKE_BIN"

make_mock() {
    local name="$1" body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"${TEST_FAKE_BIN}/${name}"
    chmod +x "${TEST_FAKE_BIN}/${name}"
}

make_mock systemctl '
printf "systemctl %s\n" "$*" >>"$MOCK_LOG"
state="${VPSCTL_SYSTEM_ROOT}/run/mock-systemd"; mkdir -p "$state"
case "${1:-}" in
  is-active) [[ -f "$state/active-${*: -1}" ]] ;;
  is-enabled) [[ -f "$state/enabled-${*: -1}" ]] ;;
  start|restart) touch "$state/active-${2}" ;;
  stop) rm -f "$state/active-${2}" ;;
  enable)
    unit="${*: -1}"; touch "$state/enabled-$unit"
    [[ " $* " != *" --now "* ]] || touch "$state/active-$unit"
    ;;
  disable) rm -f "$state/enabled-${2}" ;;
  list-unit-files) printf "systemd-timesyncd.service enabled\n" ;;
  *) exit 0 ;;
esac'
make_mock rc-service '
printf "rc-service %s\n" "$*" >>"$MOCK_LOG"
state="${VPSCTL_SYSTEM_ROOT}/run/mock-openrc"; mkdir -p "$state"
case "${2:-}" in start|restart) touch "$state/active-${1}" ;; stop) rm -f "$state/active-${1}" ;; status) [[ -f "$state/active-${1}" ]] ;; esac'
make_mock rc-update '
printf "rc-update %s\n" "$*" >>"$MOCK_LOG"
state="${VPSCTL_SYSTEM_ROOT}/run/mock-openrc"; mkdir -p "$state"
case "${1:-}" in
  add) touch "$state/enabled-${2}" ;;
  del) rm -f "$state/enabled-${2}" ;;
  show) for f in "$state"/enabled-*; do [[ -e "$f" ]] && printf "%s default\n" "${f##*enabled-}"; done ;;
esac'
make_mock journalctl 'printf "journalctl %s\n" "$*" >>"$MOCK_LOG"; printf "journal fixture\n"'
make_mock timedatectl '
printf "timedatectl %s\n" "$*" >>"$MOCK_LOG"
if [[ "${1:-}" == show ]]; then
  case "${3:-}" in Timezone) printf "Asia/Singapore\n" ;; NTP|NTPSynchronized|CanNTP) printf "yes\n" ;; esac
fi'
make_mock chronyc '
printf "chronyc %s\n" "$*" >>"$MOCK_LOG"
case "${1:-}" in tracking) printf "Leap status     : Normal\n" ;; esac'
make_mock ip '[[ "$*" == *"-4 address"* ]] && printf "1: eth0 inet 203.0.113.10/24 scope global eth0\n"'
make_mock ss '[[ ! -f "${VPSCTL_SYSTEM_ROOT}/run/listening-port" ]] || printf "tcp LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n" "$(<"${VPSCTL_SYSTEM_ROOT}/run/listening-port")"'
make_mock flock 'exit 0'
make_mock curl 'printf "unexpected curl %s\n" "$*" >>"$MOCK_LOG"; exit 99'
make_mock unzip 'printf "unexpected unzip %s\n" "$*" >>"$MOCK_LOG"; exit 99'
make_mock tar 'printf "unexpected tar %s\n" "$*" >>"$MOCK_LOG"; exit 99'
make_mock sha256sum 'printf "sha256sum %s\n" "$*" >>"$MOCK_LOG"; exec "$REAL_SHA256SUM" "$@"'
make_mock jq 'set -o pipefail; "$REAL_JQ" "$@" | tr -d "\r"; exit "${PIPESTATUS[0]}"'

export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_ENV_INIT=systemd
export VPSCTL_ENV_PACKAGE_MANAGER=apt-get
export VPSCTL_ENV_ARCH=x86_64
export VPSCTL_NON_INTERACTIVE=1
export VPSCTL_ASSUME_YES=0
export VPSCTL_DRY_RUN=0
export VPSCTL_NO_COLOR=1
export VPSCTL_QUIET=0
export VPSCTL_VERBOSE=0
export MOCK_LOG
export REAL_SHA256SUM
export REAL_JQ
# Native jq under Git Bash must preserve logical Linux paths passed via --arg,
# while still converting physical /tmp fixture paths used as input files.
export MSYS2_ARG_CONV_EXCL='/etc;/usr;/var;/run;/CN=;/tls;/matrix'
export PATH="${TEST_FAKE_BIN}:${PATH}"

RUN_STATUS=0
RUN_OUTPUT=""
run_proxy() {
    if RUN_OUTPUT="$(bash "$TEST_PROXY" "$@" 2>&1)"; then RUN_STATUS=0; else RUN_STATUS=$?; fi
}

reset_root() {
    rm -rf -- "$TEST_SYSTEM_ROOT"
    mkdir -p "$TEST_SYSTEM_ROOT/run" "$TEST_SYSTEM_ROOT/usr/bin" "$TEST_SYSTEM_ROOT/usr/local/bin"
    : >"$MOCK_LOG"
}

write_core_binary() {
    local core="$1" logical path
    logical="${2:-/usr/bin/$1}"
    path="${TEST_SYSTEM_ROOT}${logical}"
    mkdir -p "${path%/*}"
    printf '%s\n' '#!/usr/bin/env bash' \
        'core="${0##*/}"' \
        '[[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-core-validation" ]] || { case "$*" in *" -c "*|*" -test "*) exit 10;; esac; }' \
        'case "$core:$*" in' \
        '  "sing-box:version") printf "sing-box version 1.11.0\\n" ;;' \
        '  "sing-box:generate uuid") printf "11111111-1111-4111-8111-111111111111\\n" ;;' \
        '  "sing-box:generate reality-keypair") printf "PrivateKey: private-secret\\nPublicKey: public-value\\n" ;;' \
        '  "xray:version"|"xray:-version") printf "Xray 25.1.1\\n" ;;' \
        '  "xray:uuid") printf "22222222-2222-4222-8222-222222222222\\n" ;;' \
        '  "xray:x25519") printf "PrivateKey: private-secret\\nPublicKey: public-value\\n" ;;' \
        'esac' >"$path"
    chmod +x "$path"
}

install_external() {
    local core="$1"
    write_core_binary "$core"
    run_proxy install --core "$core"
    assert_equal 0 "$RUN_STATUS" "external $core install"
    jq -e '.owned == false' "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores/${core}.json" >/dev/null || fail "$core external ownership"
}

manifest_path() { printf '%s' "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/nodes.json"; }
node_id_by_name() { jq -r --arg name "$1" '.nodes[] | select(.name == $name) | .id' "$(manifest_path)"; }

test_arguments_dry_run_and_time() {
    local manifest_hash config_hash
    reset_root
    run_proxy status --core bad
    assert_equal 2 "$RUN_STATUS" "invalid status core"
    run_proxy node add --profile shadowsocks-aes-256-gcm --port 9000 --address example.com
    assert_equal 3 "$RUN_STATUS" "add without installed core"
    run_proxy --dry-run install --core sing-box
    assert_equal 0 "$RUN_STATUS" "install dry-run"
    assert_contains "$RUN_OUTPUT" "演练" "install dry-run output"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores/sing-box.json" ]] || fail "dry-run wrote core metadata"

    install_external sing-box
    manifest_hash="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    config_hash="$(sha256sum "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json" | awk '{print $1}')"
    run_proxy --dry-run node add --profile vless-ws-tls --core sing-box --name dry-tls --port 18999 \
      --address proxy.example --sni dry.example --path /tls
    assert_equal 0 "$RUN_STATUS" "TLS node add dry-run"
    assert_contains "$RUN_OUTPUT" "演练" "TLS node add dry-run output"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "dry-run manifest hash"
    assert_equal "$config_hash" "$(sha256sum "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json" | awk '{print $1}')" "dry-run config hash"
    [[ ! -e "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/certs" ]] || fail "dry-run created certificate files"

    run_proxy time status --json
    assert_equal 0 "$RUN_STATUS" "time JSON status"
    assert_json "$RUN_OUTPUT" "time JSON status"
    assert_equal Asia/Singapore "$(jq -r .timezone <<<"$RUN_OUTPUT")" "mock timezone"
    run_proxy time sync
    assert_equal 0 "$RUN_STATUS" "time sync"
    assert_file_contains "$MOCK_LOG" "timedatectl set-ntp true" "time sync routing"
    run_proxy time status extra
    assert_equal 2 "$RUN_STATUS" "time status arguments"
}

test_status_service_and_logs() {
    reset_root
    install_external sing-box
    install_external xray
    jq '.nodes = [
        {id:"node-0000000000000001",core:"sing-box",profile:"shadowsocks-aes-256-gcm",name:"status-sb",listen:"::",port:18001,address:"proxy.example",credentials:{},tls:{},transport:{},options:{}},
        {id:"node-0000000000000002",core:"xray",profile:"shadowsocks-aes-256-gcm",name:"status-xr",listen:"::",port:18002,address:"proxy.example",credentials:{},tls:{},transport:{},options:{}}
      ]' "$(manifest_path)" >"${TEST_TEMP}/status-manifest.json"
    cp "${TEST_TEMP}/status-manifest.json" "$(manifest_path)"
    run_proxy status
    assert_equal 0 "$RUN_STATUS" "status both cores"
    assert_contains "$RUN_OUTPUT" "/etc/vpsctl/proxy/sing-box/config.json" "sing-box config path"
    assert_contains "$RUN_OUTPUT" "/etc/vpsctl/proxy/xray/config.json" "xray config path"
    assert_equal 2 "$(grep -c '节点数：1' <<<"$RUN_OUTPUT")" "per-core status counts"
    assert_contains "$RUN_OUTPUT" "总节点数：2" "status total"
    run_proxy node list
    assert_equal 0 "$RUN_STATUS" "full node list"
    assert_contains "$RUN_OUTPUT" "[1] status-sb" "numbered first node"
    assert_contains "$RUN_OUTPUT" "[2] status-xr" "numbered second node"
    assert_contains "$RUN_OUTPUT" "内核：sing-box" "sing-box node annotation"
    assert_contains "$RUN_OUTPUT" "内核：Xray" "Xray node annotation"
    assert_contains "$RUN_OUTPUT" "当前筛选：2 个；节点总数：2 个" "full node list totals"
    run_proxy status --json
    assert_equal true "$(jq -r '.cores[] | select(.core == "sing-box") | .installed' <<<"$RUN_OUTPUT")" "sing-box registered status"
    assert_file_contains "${TEST_SYSTEM_ROOT}/etc/systemd/system/vpsctl-proxy-sing-box.service" "ExecStart=/usr/bin/sing-box run -c /etc/vpsctl/proxy/sing-box/config.json" "systemd unit"

    printf '  systemd start/logs/stop\n'
    run_proxy start
    assert_equal 2 "$RUN_STATUS" "non-interactive lifecycle core ambiguity"
    assert_contains "$RUN_OUTPUT" "存在多个候选内核" "non-interactive lifecycle ambiguity guidance"
    run_proxy start --core sing-box --enable
    assert_equal 0 "$RUN_STATUS" "systemd start"
    assert_file_contains "$MOCK_LOG" "systemctl start vpsctl-proxy-sing-box.service" "systemd start routing"
    assert_file_contains "$MOCK_LOG" "systemctl enable vpsctl-proxy-sing-box.service" "systemd enable routing"
    run_proxy logs --core sing-box --lines 12 --since yesterday
    assert_equal 0 "$RUN_STATUS" "systemd logs"
    assert_file_contains "$MOCK_LOG" "journalctl -u vpsctl-proxy-sing-box.service --no-pager -n 12 --since yesterday" "journal routing"
    run_proxy stop --core sing-box --disable
    assert_equal 0 "$RUN_STATUS" "systemd stop"

    reset_root
    export VPSCTL_ENV_INIT=openrc
    printf '  OpenRC install/start/logs\n'
    install_external xray
    assert_file_contains "${TEST_SYSTEM_ROOT}/etc/init.d/vpsctl-proxy-xray" 'command="/usr/bin/xray"' "OpenRC service command"
    assert_file_contains "${TEST_SYSTEM_ROOT}/etc/init.d/vpsctl-proxy-xray" 'output_log="/var/log/vpsctl/proxy/xray.log"' "OpenRC log path"
    printf 'openrc fixture\n' >"${TEST_SYSTEM_ROOT}/var/log/vpsctl/proxy/xray.log"
    run_proxy start --core xray --enable
    assert_equal 0 "$RUN_STATUS" "OpenRC start"
    assert_file_contains "$MOCK_LOG" "rc-service vpsctl-proxy-xray start" "OpenRC start routing"
    assert_file_contains "$MOCK_LOG" "rc-update add vpsctl-proxy-xray default" "OpenRC enable routing"
    run_proxy logs --core xray --lines 1
    assert_equal 0 "$RUN_STATUS" "OpenRC logs"
    assert_contains "$RUN_OUTPUT" "openrc fixture" "OpenRC file log"
    run_proxy logs --core xray --since yesterday
    assert_equal 2 "$RUN_STATUS" "OpenRC since rejection"
    export VPSCTL_ENV_INIT=systemd
    printf '  service routing done\n'
}

test_core_choice_crud_pending_and_validation() {
    reset_root
    install_external xray
    run_proxy node add --profile shadowsocks-aes-256-gcm --name x-one --port 19001 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "single installed core choice"
    assert_equal xray "$(jq -r '.nodes[0].core' "$(manifest_path)")" "single core selected"
    local id secret before list_json uri subscription decoded
    id="$(node_id_by_name x-one)"
    secret="$(jq -r '.nodes[0].credentials.password' "$(manifest_path)")"
    [[ -n "$secret" ]] || fail "CRUD node secret missing"
    run_proxy node list
    assert_equal 0 "$RUN_STATUS" "node list"
    assert_not_contains "$RUN_OUTPUT" "$secret" "default list secret"
    run_proxy node list --json
    assert_equal 0 "$RUN_STATUS" "node JSON list"
    list_json="$RUN_OUTPUT"
    assert_json "$list_json" "node JSON list"
    assert_not_contains "$list_json" "$secret" "JSON list secret"
    run_proxy node show --id "$id" --uri
    assert_equal 0 "$RUN_STATUS" "node URI"
    uri="$RUN_OUTPUT"
    assert_not_contains "$uri" "private-secret" "URI private key"
    run_proxy subscription --core xray
    assert_equal 0 "$RUN_STATUS" "subscription"
    subscription="$RUN_OUTPUT"
    decoded="$(printf '%s' "$subscription" | base64 -d)"
    assert_contains "$decoded" "$uri" "subscription URI consistency"

    run_proxy node edit --id "$id" --name x-edited --port 19002
    assert_equal 0 "$RUN_STATUS" "node edit"
    assert_equal x-edited "$(jq -r '.nodes[0].name' "$(manifest_path)")" "edited manifest name"
    assert_equal 19002 "$(jq -r '.nodes[0].port' "$(manifest_path)")" "edited manifest port"
    assert_equal "$secret" "$(jq -r '.nodes[0].credentials.password' "$(manifest_path)")" "edit preserved credentials"
    jq -e '.inbounds | length == 1' "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json" >/dev/null || fail "edited generated config"

    touch "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-xray.service"
    : >"$MOCK_LOG"
    run_proxy node edit --id "$id" --name x-pending
    assert_equal 0 "$RUN_STATUS" "running edit"
    [[ -f "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json" ]] || fail "running edit did not mark pending"
    ! grep -Fq 'restart vpsctl-proxy-xray.service' "$MOCK_LOG" || fail "running edit restarted automatically"
    run_proxy restart --core xray
    assert_equal 3 "$RUN_STATUS" "restart confirmation"
    run_proxy restart --core xray --confirm-disruptive
    assert_equal 0 "$RUN_STATUS" "explicit restart"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json" ]] || fail "restart did not clear pending"

    before="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    touch "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    run_proxy node edit --id "$id" --name rejected
    assert_equal 10 "$RUN_STATUS" "binary config validation failure"
    rm -f "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    assert_equal "$before" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "failed validation commit"

    run_proxy node delete --id "$id"
    assert_equal 3 "$RUN_STATUS" "non-interactive delete confirmation"
    run_proxy node delete --id "$id" --confirm-delete
    assert_equal 0 "$RUN_STATUS" "node delete"
    assert_equal 0 "$(jq -r '.nodes | length' "$(manifest_path)")" "deleted manifest node"
}

test_overlap_port_ambiguity_and_uninstall() {
    reset_root
    install_external sing-box
    install_external xray
    run_proxy node add --profile vless-tcp --name sb-only --port 19091 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "single-core sing-box profile choice"
    assert_equal sing-box "$(jq -r '.nodes[] | select(.name == "sb-only") | .core' "$(manifest_path)")" "sing-box-only profile core"
    run_proxy node add --profile vless-grpc-reality --name xr-only --port 19092 --address proxy.example --sni www.amd.com --service-name xr-grpc
    assert_equal 0 "$RUN_STATUS" "single-core Xray profile choice"
    assert_equal xray "$(jq -r '.nodes[] | select(.name == "xr-only") | .core' "$(manifest_path)")" "Xray-only profile core"
    run_proxy node add --profile shadowsocks-aes-256-gcm --name ambiguous --port 19101 --address proxy.example
    assert_equal 2 "$RUN_STATUS" "non-interactive shared-profile ambiguity"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box --name sb --port 19101 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "explicit sing-box add"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name xr --port 19101 --address proxy.example
    assert_equal 3 "$RUN_STATUS" "cross-core port conflict"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name xr --port 19102 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "explicit xray add"

    run_proxy update --core sing-box
    assert_equal 3 "$RUN_STATUS" "external update strong confirmation"
    assert_not_contains "$(<"$MOCK_LOG")" "unexpected curl" "unconfirmed update network access"
    run_proxy uninstall --core sing-box
    assert_equal 0 "$RUN_STATUS" "default uninstall"
    [[ -x "${TEST_SYSTEM_ROOT}/usr/bin/sing-box" ]] || fail "external binary removed"
    assert_equal 4 "$(jq -r '.nodes | length' "$(manifest_path)")" "default uninstall retained nodes"
    write_core_binary sing-box
    run_proxy install --core sing-box
    assert_equal 0 "$RUN_STATUS" "re-register retained core"
    run_proxy uninstall --core sing-box --purge
    assert_equal 3 "$RUN_STATUS" "purge confirmation"
    run_proxy uninstall --core sing-box --purge --confirm-purge
    assert_equal 0 "$RUN_STATUS" "confirmed purge"
    assert_equal 0 "$(jq -r '[.nodes[] | select(.core == "sing-box")] | length' "$(manifest_path)")" "purged core nodes"
    assert_equal 2 "$(jq -r '[.nodes[] | select(.core == "xray")] | length' "$(manifest_path)")" "purge retained other core nodes"
    [[ -x "${TEST_SYSTEM_ROOT}/usr/bin/sing-box" ]] || fail "purge removed external binary"
}

test_tls_certificate_transaction() {
    reset_root
    install_external sing-box
    local certs="${TEST_TEMP}/tls-transaction" host id old_cert new_cert failed_cert cert_root
    mkdir -p "$certs"
    for host in old.example new.example failed.example; do
        mkdir -p "$certs/$host"
        openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$host" \
          -addext "subjectAltName=DNS:$host" -keyout "$certs/$host/key.pem" -out "$certs/$host/cert.pem" >/dev/null 2>&1
    done
    run_proxy node add --profile vless-ws-tls --name tls-node --port 19201 --address proxy.example \
      --sni old.example --path /tls --cert-mode imported --cert-file "$certs/old.example/cert.pem" --key-file "$certs/old.example/key.pem"
    assert_equal 0 "$RUN_STATUS" "TLS imported node add"
    id="$(node_id_by_name tls-node)"
    old_cert="$(jq -r --arg id "$id" '.nodes[] | select(.id == $id) | .tls.certificate_path' "$(manifest_path)")"
    [[ "$old_cert" =~ /cert-[a-f0-9]{64}\.pem$ ]] || fail "initial certificate path is not fingerprint-versioned"
    [[ -f "${TEST_SYSTEM_ROOT}${old_cert}" ]] || fail "initial fingerprinted certificate missing"

    touch "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-sing-box.service"
    run_proxy node edit --id "$id" --sni new.example --cert-file "$certs/new.example/cert.pem" --key-file "$certs/new.example/key.pem"
    assert_equal 0 "$RUN_STATUS" "running TLS SNI edit"
    new_cert="$(jq -r --arg id "$id" '.nodes[] | select(.id == $id) | .tls.certificate_path' "$(manifest_path)")"
    [[ "$new_cert" =~ /cert-[a-f0-9]{64}\.pem$ && "$new_cert" != "$old_cert" ]] || fail "edited certificate path is not independently fingerprinted"
    [[ -f "${TEST_SYSTEM_ROOT}${old_cert}" && -f "${TEST_SYSTEM_ROOT}${new_cert}" ]] || fail "pending TLS edit did not retain both certificate generations"
    [[ -f "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/sing-box.json" ]] || fail "TLS edit did not create pending state"
    run_proxy restart --core sing-box --confirm-disruptive
    assert_equal 0 "$RUN_STATUS" "TLS pending restart"
    [[ ! -e "${TEST_SYSTEM_ROOT}${old_cert}" && -f "${TEST_SYSTEM_ROOT}${new_cert}" ]] || fail "restart did not prune the superseded certificate generation"

    touch "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    run_proxy node edit --id "$id" --sni failed.example --cert-file "$certs/failed.example/cert.pem" --key-file "$certs/failed.example/key.pem"
    assert_equal 10 "$RUN_STATUS" "TLS config validation failure"
    rm -f "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    assert_equal "$new_cert" "$(jq -r --arg id "$id" '.nodes[] | select(.id == $id) | .tls.certificate_path' "$(manifest_path)")" "failed TLS edit manifest rollback"
    cert_root="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/certs/${id}"
    failed_cert="$(openssl x509 -in "$certs/failed.example/cert.pem" -noout -fingerprint -sha256 | awk -F= '{gsub(":", "", $2); print tolower($2)}')"
    [[ ! -e "$cert_root/cert-${failed_cert}.pem" && -f "${TEST_SYSTEM_ROOT}${new_cert}" ]] || fail "failed TLS edit left an orphan certificate"
}

test_unified_interactive_api() (
    local output selected status=0 menu_line status_line install_marker
    local selector_stderr="${TEST_TEMP}/selector.stderr"
    local guided_stderr="${TEST_TEMP}/guided.stderr"

    reset_root
    # Source the production entry point once with a harmless action so its
    # function API can be exercised with deterministic stdin below.
    # shellcheck source=../../commands/service/proxy.sh
    source "$TEST_PROXY" help >/dev/null

    selected="$(proxy_prompt_select "selector default" quick quick "Quick" custom "Custom" 2>"$selector_stderr" <<<"")"
    assert_equal quick "$selected" "selector default"
    selected="$(proxy_prompt_select "selector retry" quick quick "Quick" custom "Custom" 2>"$selector_stderr" <<< $'99\n2')"
    assert_equal custom "$selected" "selector invalid retry"
    assert_file_contains "$selector_stderr" "选择无效，请输入列表中的编号" "selector invalid warning"
    status=0
    proxy_prompt_select "selector quit" quick quick "Quick" custom "Custom" </dev/null >/dev/null 2>&1 || status=$?
    assert_equal 130 "$status" "selector EOF quit"
    status=0
    proxy_prompt_select "selector quit" quick quick "Quick" custom "Custom" <<<q >/dev/null 2>&1 || status=$?
    assert_equal 130 "$status" "selector q quit"
    proxy_test_cancel_action() { return 130; }
    proxy_test_fail_action() { return 3; }
    status=0
    proxy_menu_action proxy_test_cancel_action >/dev/null 2>&1 || status=$?
    assert_equal 0 "$status" "menu action treats selection cancel as back"
    status=0
    proxy_menu_action proxy_test_fail_action >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" "menu action preserves real failures"

    assert_equal $'sing-box\nxray' "$(proxy_lifecycle_candidates install 1)" "install candidates are unregistered cores"
    install_external sing-box
    install_external xray
    assert_equal "" "$(proxy_lifecycle_candidates install 1)" "registered cores filtered from install"
    assert_equal $'sing-box\nxray' "$(proxy_lifecycle_candidates update 1)" "update candidates are registered cores"
    assert_equal $'sing-box\nxray' "$(proxy_lifecycle_candidates start 1)" "start candidates are inactive cores"
    touch "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-sing-box.service"
    assert_equal xray "$(proxy_lifecycle_candidates start 1)" "active core filtered from start"
    assert_equal sing-box "$(proxy_lifecycle_candidates stop 1)" "stop candidates are active cores"
    assert_equal sing-box "$(proxy_lifecycle_candidates restart 1)" "restart candidates are active cores"
    assert_equal all "$(proxy_resolve_lifecycle_core all install 1)" "install accepts all cores"
    assert_equal all "$(proxy_resolve_lifecycle_core all update 1)" "update accepts all cores"
    for selected in uninstall start stop restart logs; do
        status=0
        proxy_resolve_lifecycle_core all "$selected" 0 >/dev/null 2>&1 || status=$?
        assert_equal 2 "$status" "${selected} rejects all cores"
    done

    output="$(proxy_menu_run <<<q 2>&1)"
    for selected in "内核管理" "节点管理" "服务控制" "日志" "时间" "协议"; do
        assert_contains "$output" "$selected" "grouped proxy menu"
    done
    assert_contains "$output" "/etc/vpsctl/proxy/sing-box/config.json" "menu sing-box status path"
    assert_contains "$output" "/etc/vpsctl/proxy/xray/config.json" "menu Xray status path"
    assert_contains "$output" "总节点数：0" "menu status total"
    menu_line="$(grep -n -m1 '代理能力' <<<"$output" | cut -d: -f1)"
    status_line="$(grep -n -m1 '总节点数：0' <<<"$output" | cut -d: -f1)"
    ((status_line < menu_line)) || fail "status summary was not above grouped proxy menu"

    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name numbered-one --port 19301 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "first numbered node fixture"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name numbered-two --port 19302 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "second numbered node fixture"

    # The proxy entry point captures the real TTY state before selectors enter
    # command substitutions. Keep the generic predicate false here to prove
    # the captured proxy state remains usable after stdout becomes a pipe.
    vps_cmd_is_interactive() { return 1; }
    PROXY_INTERACTIVE=1
    output="$(proxy_node_view_interactive <<< $'2\n1' 2>&1)"
    assert_contains "$output" "[1] numbered-one" "interactive numbered node list"
    assert_contains "$output" "[2] numbered-two" "interactive numbered node list"
    assert_contains "$output" "节点详情" "interactive node details action"
    assert_contains "$output" "名称：numbered-two" "interactive numbered details selection"
    output="$(proxy_node_view_interactive <<< $'1\n2' 2>&1)"
    assert_contains "$output" "ss://" "interactive numbered URI action"

    reset_root
    install_marker="${TEST_SYSTEM_ROOT}/run/stub-installed"
    proxy_core_registered() { [[ -f "${install_marker}-$1" ]]; }
    proxy_core_install() {
        printf '%s\n' "$1" >>"${TEST_SYSTEM_ROOT}/run/stub-install.log"
        [[ "${VPSCTL_DRY_RUN:-0}" == "1" ]] || touch "${install_marker}-$1"
    }
    selected="$(proxy_choose_core_for_profile shadowsocks-aes-256-gcm "" 2>"$guided_stderr" <<<2)"
    assert_equal xray "$selected" "guided compatible core selection"
    assert_file_contains "${TEST_SYSTEM_ROOT}/run/stub-install.log" xray "guided install stub"
    [[ -f "${install_marker}-xray" ]] || fail "guided install did not use selected core"

    rm -f -- "${install_marker}-sing-box" "${install_marker}-xray"
    : >"${TEST_SYSTEM_ROOT}/run/stub-install.log"
    VPSCTL_DRY_RUN=1
    selected="$(proxy_choose_core_for_profile vless-tcp "" 2>"$guided_stderr")"
    assert_equal sing-box "$selected" "dry-run guided compatible core"
    assert_file_contains "${TEST_SYSTEM_ROOT}/run/stub-install.log" sing-box "dry-run guided install stub"
    [[ ! -e "${install_marker}-sing-box" ]] || fail "dry-run guided install created registration metadata"

    touch "${install_marker}-sing-box"
    vps_cmd_require_root() { return 0; }
    proxy_require_platform() { return 0; }
    proxy_prepare_manifest_state() { return 0; }
    proxy_require_available_port() { return 0; }
    proxy_require_unique_name() { return 0; }

    output="$(proxy_node_add --profile hysteria2 --port 19400 --address proxy.example <<< $'\n\n\n' 2>&1)"
    assert_contains "$output" "请选择添加模式" "quick node add mode"
    assert_not_contains "$output" "混淆方式" "quick mode skips custom enums"

    output="$(proxy_node_add --profile vless-ws-tls --port 19401 --address proxy.example <<< $'\n\n2\n\n\n\n\n2\n/tmp/cert.pem\n/tmp/key.pem' 2>&1)"
    assert_contains "$output" "证书方式" "custom certificate enum"
    assert_contains "$output" "生成自签名证书" "certificate self-signed choice"
    assert_contains "$output" "导入现有证书" "certificate imported choice"
    assert_contains "$output" "证书文件绝对路径" "imported certificate selection"

    output="$(proxy_node_add --profile hysteria2 --port 19402 --address proxy.example <<< $'\n\n2\n\n\n\n\n2\n123\n456' 2>&1)"
    assert_contains "$output" "混淆方式" "custom obfuscation enum"
    assert_contains "$output" "不使用混淆" "obfuscation none choice"
    assert_contains "$output" "Salamander" "obfuscation Salamander choice"
    assert_contains "$output" "上行 Mbps" "custom obfuscation bandwidth"

    output="$(proxy_node_add --profile tuic-v5 --port 19403 --address proxy.example <<< $'\n\n2\n\n\n\n\n3' 2>&1)"
    assert_contains "$output" "拥塞控制" "custom congestion enum"
    assert_contains "$output" "BBR" "congestion BBR choice"
    assert_contains "$output" "CUBIC" "congestion CUBIC choice"
    assert_contains "$output" "New Reno" "congestion New Reno choice"

    selected="$(proxy_prompt_select "证书方式" self-signed self-signed "生成自签名证书" imported "导入现有证书" <<<2 2>/dev/null)"
    assert_equal imported "$selected" "certificate enum selection"
    selected="$(proxy_prompt_select "混淆方式" none none "不使用混淆" salamander "Salamander" <<<2 2>/dev/null)"
    assert_equal salamander "$selected" "obfuscation enum selection"
    selected="$(proxy_prompt_select "拥塞控制" bbr bbr BBR cubic CUBIC new_reno "New Reno" <<<3 2>/dev/null)"
    assert_equal new_reno "$selected" "congestion enum selection"
)

test_protocol_matrix() {
    reset_root
    write_core_binary sing-box
    write_core_binary xray
    mkdir -p "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores" "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy" "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy"
    local core logical version
    for core in sing-box xray; do
        logical="/usr/bin/$core"; version=fixture
        jq -n --arg core "$core" --arg binary "$logical" --arg version "$version" \
          '{schema_version:1,core:$core,binary:$binary,owned:false,version:$version,release_tag:"",sha256:"fixture",service:("vpsctl-proxy-"+$core),installed_at:"2026-01-01T00:00:00Z",updated_at:"2026-01-01T00:00:00Z"}' \
          >"${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores/${core}.json"
    done

    # Load the renderer API without executing proxy_main.
    source "${TEST_ROOT}/lib/command.sh"
    vps_cmd_init "proxy renderer tests" "$TEST_ROOT"
    source "${TEST_ROOT}/commands/service/proxy/common.sh"
    source "${TEST_ROOT}/commands/service/proxy/protocols-sing-box.sh"
    source "${TEST_ROOT}/commands/service/proxy/protocols-xray.sh"
    source "${TEST_ROOT}/commands/service/proxy/nodes.sh"
    source "${TEST_ROOT}/commands/service/proxy/core.sh"
    proxy_common_init

    local cert_dir="${TEST_TEMP}/cert" profile label supported node rendered uri id profile_obfs port=20000 count=0
    local profile_count=0 sb_count=0 xray_count=0 overlap_count=0 sb_only_count=0 xray_only_count=0
    local digest_file="${TEST_TEMP}/xray.dgst" digest digest_status=0
    printf 'SHA2-256= AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' >"$digest_file"
    digest="$(_proxy_core_xray_dgst_sha256 "$digest_file" Xray-linux-64.zip)"
    assert_equal aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$digest" "official Xray dgst format"
    printf 'SHA2-256= not-a-digest\n' >"$digest_file"
    _proxy_core_xray_dgst_sha256 "$digest_file" Xray-linux-64.zip >/dev/null 2>&1 || digest_status=$?
    assert_equal 20 "$digest_status" "invalid Xray dgst rejection"
    mkdir -p "$cert_dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=www.amd.com \
      -addext subjectAltName=DNS:www.amd.com -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" >/dev/null 2>&1
    while IFS=$'\t' read -r profile label; do
        [[ -n "$profile" ]] || continue
        profile_count=$((profile_count + 1))
        profile_obfs=none
        [[ "$profile" != hysteria2 ]] || profile_obfs=salamander
        supported=0
        while IFS= read -r core; do
            [[ -n "$core" ]] || continue
            supported=$((supported + 1)); count=$((count + 1)); port=$((port + 1))
            case "$core" in sing-box) sb_count=$((sb_count + 1)) ;; xray) xray_count=$((xray_count + 1)) ;; esac
            printf -v id 'node-%016x' "$count"
            node="$(proxy_prepare_node_json "$core" "$profile" "$id" "matrix-$count" "::" "$port" "proxy.example" "www.amd.com" "/matrix" "matrix-grpc" imported "$cert_dir/cert.pem" "$cert_dir/key.pem" "$profile_obfs" 100 200 bbr)" || fail "$profile/$core fixture generation"
            case "$core" in
                sing-box)
                    proxy_sb_validate_node "$node" || fail "$profile sing-box validate"
                    rendered="$(proxy_sb_render_node "$node")" || fail "$profile sing-box render"
                    uri="$(proxy_sb_render_uri "$node")" || fail "$profile sing-box URI"
                    ;;
                xray)
                    proxy_xray_validate_node "$node" || fail "$profile xray validate"
                    rendered="$(proxy_xray_render_node "$node")" || fail "$profile xray render"
                    uri="$(proxy_xray_render_uri "$node")" || fail "$profile xray URI"
                    ;;
            esac
            jq -e 'type == "array"' >/dev/null <<<"$rendered" || fail "$profile/$core rendered invalid JSON array"
            if [[ "$profile" == hysteria2 ]]; then
                jq -e '.[0].up_mbps == 100 and .[0].down_mbps == 200' >/dev/null <<<"$rendered" || fail "hysteria2 bandwidth renderer fields"
            fi
            [[ -n "$uri" ]] || fail "$profile/$core empty URI"
            local private_key
            private_key="$(jq -r '.credentials.private_key' <<<"$node")"
            [[ -z "$private_key" ]] || assert_not_contains "$uri" "$private_key" "$profile/$core URI private_key"
        done < <(proxy_profile_cores "$profile")
        ((supported > 0)) || fail "$profile has no renderer"
        case "$supported" in
            2) overlap_count=$((overlap_count + 1)) ;;
            1)
                if proxy_sb_supports_profile "$profile"; then sb_only_count=$((sb_only_count + 1)); else xray_only_count=$((xray_only_count + 1)); fi
                ;;
            *) fail "$profile has an invalid core mapping" ;;
        esac
    done < <(proxy_all_profiles)
    assert_equal 20 "$profile_count" "unique profile count"
    assert_equal 15 "$sb_count" "sing-box profile count"
    assert_equal 11 "$xray_count" "Xray profile count"
    assert_equal 6 "$overlap_count" "shared profile count"
    assert_equal 9 "$sb_only_count" "sing-box-only profile count"
    assert_equal 5 "$xray_only_count" "Xray-only profile count"
}

printf 'TEST: proxy arguments, dry-run and time\n'
test_arguments_dry_run_and_time
printf 'TEST: proxy status, services and logs\n'
test_status_service_and_logs
printf 'TEST: proxy CRUD, pending and validation\n'
test_core_choice_crud_pending_and_validation
printf 'TEST: proxy core choice, ports and uninstall\n'
test_overlap_port_ambiguity_and_uninstall
printf 'TEST: proxy TLS certificate transactions\n'
test_tls_certificate_transaction
printf 'TEST: proxy unified interactive API\n'
test_unified_interactive_api
printf 'TEST: proxy protocol renderer matrix\n'
test_protocol_matrix
printf 'PASS: service proxy tests\n'
