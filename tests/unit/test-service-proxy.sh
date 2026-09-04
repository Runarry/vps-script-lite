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
TEST_DEP_BIN="${TEST_TEMP}/bin-dependencies"
MOCK_LOG="${TEST_TEMP}/mock.log"
readonly TEST_SYSTEM_ROOT TEST_FAKE_BIN TEST_DEP_BIN MOCK_LOG
REAL_BASH="$(command -v bash)"
REAL_CAT="$(command -v cat)"
REAL_DIRNAME="$(command -v dirname)"
REAL_GREP="$(command -v grep)"
REAL_SHA256SUM="$(command -v sha256sum)"
REAL_JQ="$(command -v jq)"
readonly REAL_BASH REAL_CAT REAL_DIRNAME REAL_GREP REAL_SHA256SUM REAL_JQ
trap 'rm -rf -- "$TEST_TEMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'${RUN_OUTPUT:+; last output: $RUN_OUTPUT}"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "$3: unexpectedly contained '$2'"; }
assert_file_contains() { [[ -f "$1" ]] || fail "$3: missing file $1"; grep -Fq -- "$2" "$1" || fail "$3: missing '$2'"; }
assert_json() { jq -e . >/dev/null 2>&1 <<<"$1" || fail "$2: invalid JSON"; }

mkdir -p "$TEST_FAKE_BIN" "$TEST_DEP_BIN"

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
  start) touch "$state/active-${2}" ;;
  restart)
    if [[ -e "${VPSCTL_SYSTEM_ROOT}/run/fail-service-restart-once" ]]; then
      rm -f "${VPSCTL_SYSTEM_ROOT}/run/fail-service-restart-once"
      exit 20
    fi
    touch "$state/active-${2}"
    ;;
  stop) rm -f "$state/active-${2}" ;;
  enable)
    unit="${*: -1}"; touch "$state/enabled-$unit"
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-service-enable" ]] || exit 20
    [[ " $* " != *" --now "* ]] || touch "$state/active-$unit"
    ;;
  disable)
    unit="${*: -1}"; rm -f "$state/enabled-$unit"
    [[ " $* " != *" --now "* ]] || rm -f "$state/active-$unit"
    ;;
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
  show)
    if [[ -e "$state/long-show" ]]; then
      printf "vpsctl-proxy-sing-box default\n"
      i=0; while ((i < 5000)); do printf "filler-%04d default\n" "$i"; ((i += 1)); done
      printf "vpsctl-proxy-xray default\n"
    else
      for f in "$state"/enabled-*; do [[ -e "$f" ]] && printf "%s default\n" "${f##*enabled-}"; done
    fi
    ;;
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
make_mock ip '[[ "$*" == *"-4 address"* || "$*" == *"-o address show"* ]] && printf "1: eth0 inet 203.0.113.10/24 scope global eth0\n"'
make_mock getent '
family="${1:-}"; host="${2:-}"
file="${VPSCTL_SYSTEM_ROOT}/run/dns-${family}-${host}"
[[ -f "$file" ]] || exit 2
while IFS= read -r address; do [[ -n "$address" ]] && printf "%s STREAM %s\n" "$address" "$host"; done <"$file"'
make_mock sysctl 'printf "sysctl %s\n" "$*" >>"$MOCK_LOG"'
make_mock nft '
printf "nft %s\n" "$*" >>"$MOCK_LOG"
state="${VPSCTL_SYSTEM_ROOT}/run/mock-nft"; mkdir -p "$state"
if [[ "${1:-}" == -j && "${2:-}" == list && "${3:-}" == ruleset ]]; then printf "{\"nftables\":[]}"; exit 0; fi
if [[ "${1:-}" == -j && "${2:-}" == list && "${3:-}" == tables ]]; then
  [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-nft-list-tables" ]] || exit 20
  printf "{\"nftables\":["; separator=""
  if [[ -f "$state/ip-vpsctl_proxy_forward4" ]]; then printf "%s{\"table\":{\"family\":\"ip\",\"name\":\"vpsctl_proxy_forward4\"}}" "$separator"; separator=,; fi
  if [[ -f "$state/ip6-vpsctl_proxy_forward6" ]]; then printf "%s{\"table\":{\"family\":\"ip6\",\"name\":\"vpsctl_proxy_forward6\"}}" "$separator"; fi
  printf "]}"; exit 0
fi
if [[ "${1:-}" == list && "${2:-}" == table ]]; then
  family="${3:-}"; table="${4:-}"; [[ -f "$state/${family}-${table}" ]] || exit 1
  printf "table %s %s { }\n" "$family" "$table"; exit 0
fi
if [[ "${1:-}" == -c && "${2:-}" == -f ]]; then
  [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-nft-check" ]] || exit 10
  exit 0
fi
if [[ "${1:-}" == -f ]]; then
  if [[ -e "${VPSCTL_SYSTEM_ROOT}/run/fail-nft-apply-once" ]]; then rm -f "${VPSCTL_SYSTEM_ROOT}/run/fail-nft-apply-once"; exit 20; fi
  [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-nft-apply" ]] || exit 20
  batch="${2:-}"; cp -p -- "$batch" "${VPSCTL_SYSTEM_ROOT}/run/last-nft.batch"
  for family in ip ip6; do
    table="vpsctl_proxy_forward$([[ "$family" == ip ]] && printf 4 || printf 6)"
    if grep -Fq "add table $family $table" "$batch" || grep -Fq "table $family $table {" "$batch"; then touch "$state/${family}-${table}"
    elif grep -Eq "(delete|destroy) table $family $table" "$batch"; then rm -f "$state/${family}-${table}"
    fi
  done
  exit 0
fi
exit 2'
make_mock ss '[[ ! -f "${VPSCTL_SYSTEM_ROOT}/run/listening-port" ]] || printf "tcp LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n" "$(<"${VPSCTL_SYSTEM_ROOT}/run/listening-port")"'
make_mock flock 'exit 0'
make_mock curl '
printf "curl %s\n" "$*" >>"$MOCK_LOG"
scenario_file="${VPSCTL_SYSTEM_ROOT}/run/release-fixture-scenario"
[[ -f "$scenario_file" ]] || { printf "unexpected curl %s\n" "$*" >>"$MOCK_LOG"; exit 99; }
scenario="$(<"$scenario_file")"
output=""; url=""
while (($#)); do
  case "$1" in
    -o) output="${2:-}"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || exit 98
case "$url" in
  *SagerNet/sing-box*) core=sing-box; repository=SagerNet/sing-box ;;
  *XTLS/Xray-core*) core=xray; repository=XTLS/Xray-core ;;
  *) exit 97 ;;
esac
release() {
  local tag="$1" draft="$2" prerelease="$3" version asset payload digest asset_url dgst_url
  version="${tag#v}"
  if [[ "$core" == sing-box ]]; then
    asset="sing-box-${version}-linux-amd64.tar.gz"
  else
    asset="Xray-linux-64.zip"
  fi
  payload="fixture:${core}:${version}"
  digest="$(printf "%s\n" "$payload" | "$REAL_SHA256SUM" | cut -d " " -f 1)"
  [[ "$scenario" != bad-digest ]] || digest=0000000000000000000000000000000000000000000000000000000000000000
  asset_url="https://github.com/${repository}/releases/download/${tag}/${asset}"
  if [[ "$core" == sing-box ]]; then
    printf "{\"tag_name\":\"%s\",\"draft\":%s,\"prerelease\":%s,\"assets\":[{\"name\":\"%s\",\"browser_download_url\":\"%s\",\"digest\":\"sha256:%s\"}]}" \
      "$tag" "$draft" "$prerelease" "$asset" "$asset_url" "$digest"
  else
    dgst_url="${asset_url}.dgst"
    printf "{\"tag_name\":\"%s\",\"draft\":%s,\"prerelease\":%s,\"assets\":[{\"name\":\"%s\",\"browser_download_url\":\"%s\"},{\"name\":\"%s.dgst\",\"browser_download_url\":\"%s\"}]}" \
      "$tag" "$draft" "$prerelease" "$asset" "$asset_url" "$asset" "$dgst_url"
  fi
}
non_prerelease_page() {
  local index
  printf "["
  for ((index = 0; index < 99; index += 1)); do
    ((index == 0)) || printf ","
    printf "{\"tag_name\":\"v1.0.%s\",\"draft\":false,\"prerelease\":false,\"assets\":[]}" "$index"
  done
  printf ","
  release "$( [[ "$core" == sing-box ]] && printf v1.12.0-beta.0 || printf v25.2.0-rc.0 )" true true
  printf "]"
}
if [[ "$url" == *"/releases/latest" ]]; then
  case "$scenario" in
    latest-prerelease) release "$( [[ "$core" == sing-box ]] && printf v1.12.0-beta.1 || printf v25.2.0-rc.1 )" false true >"$output" ;;
    malformed-latest) printf "{}" >"$output" ;;
    *) release "$( [[ "$core" == sing-box ]] && printf v1.11.0 || printf v25.1.1 )" false false >"$output" ;;
  esac
  exit 0
fi
if [[ "$url" == *"/releases/tags/"* ]]; then
  requested="${url##*/}"
  case "$scenario" in
    draft-tag) release "$requested" true "$( [[ "$requested" == *-* ]] && printf true || printf false )" >"$output" ;;
    mismatched-tag) release v9.9.9 false false >"$output" ;;
    *) release "$requested" false "$( [[ "$requested" == *-* ]] && printf true || printf false )" >"$output" ;;
  esac
  exit 0
fi
if [[ "$url" == *"/releases?per_page=100&page="* ]]; then
  page="${url##*page=}"
  case "$scenario:$page" in
    malformed-list:1) printf "{}" >"$output" ;;
    repeated-full:*) non_prerelease_page >"$output" ;;
    no-prerelease:1) non_prerelease_page >"$output" ;;
    no-prerelease:2) printf "[]" >"$output" ;;
    *:1) non_prerelease_page >"$output" ;;
    *:2)
      printf "[" >"$output"; release "$( [[ "$core" == sing-box ]] && printf v1.12.0-beta.1 || printf v25.2.0-rc.1 )" false true >>"$output"
      printf "," >>"$output"; release "$( [[ "$core" == sing-box ]] && printf v1.12.0-beta.2 || printf v25.2.0-rc.2 )" false true >>"$output"; printf "]" >>"$output" ;;
    *) printf "[]" >"$output" ;;
  esac
  exit 0
fi
if [[ "$url" == *.dgst ]]; then
  tag="${url#*/releases/download/}"; tag="${tag%%/*}"; version="${tag#v}"
  payload="fixture:${core}:${version}"
  digest="$(printf "%s\n" "$payload" | "$REAL_SHA256SUM" | cut -d " " -f 1)"
  [[ "$scenario" != bad-digest ]] || digest=0000000000000000000000000000000000000000000000000000000000000000
  printf "SHA2-256= %s\n" "$digest" >"$output"
  exit 0
fi
if [[ "$url" == https://github.com/*/releases/download/* ]]; then
  tag="${url#*/releases/download/}"; tag="${tag%%/*}"; version="${tag#v}"
  printf "fixture:%s:%s\n" "$core" "$version" >"$output"
  exit 0
fi
exit 96'
make_mock unzip '
printf "unzip %s\n" "$*" >>"$MOCK_LOG"
archive=""; destination=""
while (($#)); do
  case "$1" in -d) destination="${2:-}"; shift 2 ;; -*) shift ;; xray) shift ;; *) archive="$1"; shift ;; esac
done
IFS=: read -r marker core version <"$archive"
[[ "$marker" == fixture && "$core" == xray && -n "$destination" ]] || exit 20
scenario="$(<"${VPSCTL_SYSTEM_ROOT}/run/release-fixture-scenario")"
[[ "$scenario" != bad-version ]] || version=9.9.9
mkdir -p "$destination"
printf "#!/usr/bin/env bash\nprintf \"downloaded xray %%s\\\\n\" \"\$*\" >>\"\$MOCK_LOG\"\nif [[ \"\$(<\"\${VPSCTL_SYSTEM_ROOT}/run/release-fixture-scenario\")\" == bad-config && \"\$*\" == \"run -test -c \"* ]]; then exit 10; fi\nprintf \"Xray %s\\\\n\"\n" "$version" >"${destination}/xray"
chmod +x "${destination}/xray"'
make_mock tar '
printf "tar %s\n" "$*" >>"$MOCK_LOG"
archive=""; destination=""; member=""
while (($#)); do
  case "$1" in -xzf) archive="${2:-}"; shift 2 ;; -C) destination="${2:-}"; shift 2 ;; -*) shift ;; *) member="$1"; shift ;; esac
done
IFS=: read -r marker core version <"$archive"
[[ "$marker" == fixture && "$core" == sing-box && -n "$destination" && -n "$member" ]] || exit 20
scenario="$(<"${VPSCTL_SYSTEM_ROOT}/run/release-fixture-scenario")"
[[ "$scenario" != bad-version ]] || version=9.9.9
mkdir -p "${destination}/${member%/*}"
printf "#!/usr/bin/env bash\nprintf \"downloaded sing-box %%s\\\\n\" \"\$*\" >>\"\$MOCK_LOG\"\nif [[ \"\$(<\"\${VPSCTL_SYSTEM_ROOT}/run/release-fixture-scenario\")\" == bad-config && \"\$*\" == \"check -c \"* ]]; then exit 10; fi\nprintf \"sing-box version %s\\\\n\"\n" "$version" >"${destination}/${member}"
chmod +x "${destination}/${member}"'
make_mock sha256sum 'printf "sha256sum %s\n" "$*" >>"$MOCK_LOG"; exec "$REAL_SHA256SUM" "$@"'
make_mock jq 'set -o pipefail; "$REAL_JQ" "$@" | tr -d "\r"; exit "${PIPESTATUS[0]}"'
make_mock apt-get 'printf "apt-get %s\n" "$*" >>"$MOCK_LOG"'

ln -s "$REAL_BASH" "${TEST_DEP_BIN}/bash"
ln -s "$REAL_CAT" "${TEST_DEP_BIN}/cat"
ln -s "$REAL_DIRNAME" "${TEST_DEP_BIN}/dirname"
ln -s "$REAL_GREP" "${TEST_DEP_BIN}/grep"
ln -s "${TEST_FAKE_BIN}/systemctl" "${TEST_DEP_BIN}/systemctl"
ln -s "${TEST_FAKE_BIN}/apt-get" "${TEST_DEP_BIN}/apt-get"

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
export PROXY_RELAY_FORWARD_ALLOW_TEST_RUNTIME=1
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
    if RUN_OUTPUT="$(PATH="${RUN_PROXY_PATH:-$PATH}" bash "$TEST_PROXY" "$@" 2>&1)"; then RUN_STATUS=0; else RUN_STATUS=$?; fi
}

reset_root() {
    rm -rf -- "$TEST_SYSTEM_ROOT"
    mkdir -p "$TEST_SYSTEM_ROOT/run" "$TEST_SYSTEM_ROOT/usr/bin" "$TEST_SYSTEM_ROOT/usr/local/bin"
    : >"$MOCK_LOG"
}

set_release_scenario() {
    printf '%s\n' "${1:-default}" >"${TEST_SYSTEM_ROOT}/run/release-fixture-scenario"
}

write_core_binary() {
    local core="$1" logical path version
    logical="${2:-/usr/bin/$1}"
    case "$core" in
        sing-box) version="${3:-1.11.0}" ;;
        xray) version="${3:-25.1.1}" ;;
        *) fail "unknown fixture core: $core" ;;
    esac
    path="${TEST_SYSTEM_ROOT}${logical}"
    mkdir -p "${path%/*}"
    printf '%s\n' '#!/usr/bin/env bash' \
        'core="${0##*/}"' \
        '[[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-core-validation" ]] || { case "$*" in *" -c "*|*" -test "*) printf "fixture core validation rejected:%0600d\\n" 0 >&2; exit 10;; esac; }' \
        '[[ "$core" != xray || "$*" != "run -test -c "* || "${*: -1}" == *.json ]] || { printf "Xray fixture requires a .json config path\\n" >&2; exit 10; }' \
        'case "$core:$*" in' \
        "  \"sing-box:version\") printf \"sing-box version ${version}\\\\n\" ;;" \
        '  "sing-box:generate uuid") printf "11111111-1111-4111-8111-111111111111\\n" ;;' \
        '  "sing-box:generate reality-keypair") printf "PrivateKey: private-secret\\nPublicKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n" ;;' \
        "  \"xray:version\"|\"xray:-version\") printf \"Xray ${version}\\\\n\" ;;" \
        '  "xray:uuid") printf "22222222-2222-4222-8222-222222222222\\n" ;;' \
        '  "xray:x25519") printf "PrivateKey: private-secret\\nPublicKey: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\\n" ;;' \
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
relay_path() { printf '%s' "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay.json"; }
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

    reset_root
    set_release_scenario default
    write_core_binary xray
    run_proxy install --core xray --version v25.1.1
    assert_equal 0 "$RUN_STATUS" "external Xray version matches v-prefixed tag"

    reset_root
    set_release_scenario default
    write_core_binary xray
    run_proxy install --core xray --version 25.1.1
    assert_equal 0 "$RUN_STATUS" "external Xray version matches unprefixed tag"
}

test_core_release_channels() {
    local sing_meta xray_meta core meta
    sing_meta="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores/sing-box.json"
    xray_meta="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores/xray.json"

    reset_root
    run_proxy install --core sing-box --release-channel
    assert_equal 2 "$RUN_STATUS" "release channel missing value"
    run_proxy install --core sing-box --release-channel beta
    assert_equal 2 "$RUN_STATUS" "invalid release channel"
    run_proxy install --core sing-box --release-channel stable --release-channel prerelease
    assert_equal 2 "$RUN_STATUS" "duplicate release channel"
    run_proxy install --core sing-box --version
    assert_equal 2 "$RUN_STATUS" "exact version missing value"
    run_proxy install --core sing-box --version v1.11.0 --version v1.12.0-beta.1
    assert_equal 2 "$RUN_STATUS" "duplicate exact version"
    run_proxy install --core sing-box --version v1.11.0 --release-channel stable
    assert_equal 2 "$RUN_STATUS" "version and channel conflict"
    run_proxy update --core sing-box --release-channel
    assert_equal 2 "$RUN_STATUS" "update release channel missing value"
    run_proxy update --core sing-box --release-channel prerelease --version v1.12.0-beta.1
    assert_equal 2 "$RUN_STATUS" "update version and channel conflict"
    run_proxy update --core sing-box --release-channel stable --release-channel stable
    assert_equal 2 "$RUN_STATUS" "update duplicate release channel"
    run_proxy install --core all --version v1.11.0
    assert_equal 2 "$RUN_STATUS" "all cores reject shared exact version"
    assert_not_contains "$(<"$MOCK_LOG")" "curl " "invalid release arguments avoid network"

    run_proxy --dry-run install --core sing-box --release-channel prerelease
    assert_equal 0 "$RUN_STATUS" "prerelease install dry-run"
    assert_contains "$RUN_OUTPUT" "Pre-release" "prerelease dry-run channel"
    [[ ! -e "$sing_meta" ]] || fail "prerelease dry-run wrote metadata"
    run_proxy --dry-run install --core xray --version v25.2.0-rc.1
    assert_equal 0 "$RUN_STATUS" "exact prerelease dry-run"
    assert_contains "$RUN_OUTPUT" "v25.2.0-rc.1" "exact tag dry-run output"

    reset_root
    set_release_scenario default
    run_proxy install --core sing-box
    assert_equal 0 "$RUN_STATUS" "default stable managed install"
    jq -e '.owned == true and .version == "1.11.0" and .release_tag == "v1.11.0" and (has("release_channel") | not)' \
        "$sing_meta" >/dev/null || fail "default stable metadata"
    assert_file_contains "$MOCK_LOG" "/SagerNet/sing-box/releases/latest" "default stable endpoint"
    assert_not_contains "$(<"$MOCK_LOG")" "/releases?per_page=" "default stable avoids release list"
    assert_file_contains "$MOCK_LOG" "sing-box-1.11.0-linux-amd64.tar.gz" "stable sing-box asset"
    assert_file_contains "$MOCK_LOG" "downloaded sing-box version" "stable sing-box version smoke test"
    assert_file_contains "$MOCK_LOG" "downloaded sing-box check -c" "stable sing-box config validation"

    reset_root
    set_release_scenario default
    run_proxy install --core xray --version v25.2.0-rc.1
    assert_equal 0 "$RUN_STATUS" "exact prerelease managed install"
    jq -e '.owned == true and .version == "25.2.0-rc.1" and .release_tag == "v25.2.0-rc.1"' \
        "$xray_meta" >/dev/null || fail "exact prerelease metadata"
    assert_file_contains "$MOCK_LOG" "/XTLS/Xray-core/releases/tags/v25.2.0-rc.1" "exact prerelease endpoint"
    assert_file_contains "$MOCK_LOG" "Xray-linux-64.zip.dgst" "exact prerelease Xray digest"

    reset_root
    set_release_scenario default
    run_proxy install --core xray --version v25.1.1
    assert_equal 0 "$RUN_STATUS" "exact stable managed install"
    jq -e '.version == "25.1.1" and .release_tag == "v25.1.1"' "$xray_meta" >/dev/null || fail "exact stable metadata"

    reset_root
    set_release_scenario draft-tag
    run_proxy install --core xray --version v25.2.0-rc.1
    assert_equal 20 "$RUN_STATUS" "exact draft release rejection"
    [[ ! -e "$xray_meta" ]] || fail "draft release wrote metadata"
    assert_not_contains "$(<"$MOCK_LOG")" "/releases/download/" "draft release downloaded asset"

    reset_root
    set_release_scenario mismatched-tag
    run_proxy install --core sing-box --version v1.12.0-beta.1
    assert_equal 20 "$RUN_STATUS" "exact tag echo mismatch rejection"
    assert_contains "$RUN_OUTPUT" "非请求版本" "exact tag mismatch message"
    [[ ! -e "$sing_meta" ]] || fail "tag mismatch wrote metadata"

    reset_root
    set_release_scenario latest-prerelease
    run_proxy install --core sing-box --release-channel stable
    assert_equal 20 "$RUN_STATUS" "stable channel rejects prerelease latest response"
    [[ ! -e "$sing_meta" ]] || fail "prerelease latest wrote stable metadata"

    reset_root
    set_release_scenario default
    run_proxy install --core all --release-channel prerelease
    assert_equal 0 "$RUN_STATUS" "all cores prerelease install"
    jq -e '.owned == true and .version == "1.12.0-beta.1" and .release_tag == "v1.12.0-beta.1"' \
        "$sing_meta" >/dev/null || fail "sing-box prerelease metadata"
    jq -e '.owned == true and .version == "25.2.0-rc.1" and .release_tag == "v25.2.0-rc.1"' \
        "$xray_meta" >/dev/null || fail "Xray prerelease metadata"
    assert_file_contains "$MOCK_LOG" "/SagerNet/sing-box/releases?per_page=100&page=1" "sing-box prerelease first page"
    assert_file_contains "$MOCK_LOG" "/SagerNet/sing-box/releases?per_page=100&page=2" "sing-box prerelease pagination"
    assert_file_contains "$MOCK_LOG" "/XTLS/Xray-core/releases?per_page=100&page=2" "Xray prerelease pagination"
    assert_not_contains "$(<"$MOCK_LOG")" "/releases/latest" "prerelease avoids stable endpoint"
    assert_not_contains "$(<"$MOCK_LOG")" "beta.2/sing-box" "prerelease uses first matching release"
    assert_not_contains "$(<"$MOCK_LOG")" "rc.2/Xray" "Xray prerelease uses first matching release"
    assert_file_contains "$MOCK_LOG" "sing-box-1.12.0-beta.1-linux-amd64.tar.gz" "prerelease sing-box asset"
    assert_file_contains "$MOCK_LOG" "Xray-linux-64.zip.dgst" "prerelease Xray digest fallback"
    assert_file_contains "$MOCK_LOG" "downloaded sing-box check -c" "prerelease sing-box config validation"
    assert_file_contains "$MOCK_LOG" "downloaded xray run -test -c" "prerelease Xray config validation"

    : >"$MOCK_LOG"
    run_proxy update --core all --release-channel prerelease
    assert_equal 0 "$RUN_STATUS" "repeated prerelease update"
    assert_file_contains "$MOCK_LOG" "/releases?per_page=100&page=2" "repeated prerelease resolution"
    jq -e '.release_tag == "v1.12.0-beta.1"' "$sing_meta" >/dev/null || fail "repeated sing-box prerelease tag"
    jq -e '.release_tag == "v25.2.0-rc.1"' "$xray_meta" >/dev/null || fail "repeated Xray prerelease tag"

    : >"$MOCK_LOG"
    run_proxy update --core all
    assert_equal 0 "$RUN_STATUS" "default update returns to stable channel"
    jq -e '.release_tag == "v1.11.0"' "$sing_meta" >/dev/null || fail "default sing-box update stable tag"
    jq -e '.release_tag == "v25.1.1"' "$xray_meta" >/dev/null || fail "default Xray update stable tag"
    assert_file_contains "$MOCK_LOG" "/SagerNet/sing-box/releases/latest" "default sing-box update stable endpoint"
    assert_file_contains "$MOCK_LOG" "/XTLS/Xray-core/releases/latest" "default Xray update stable endpoint"
    assert_not_contains "$(<"$MOCK_LOG")" "/releases?per_page=" "default update does not follow prior channel"

    for core in sing-box xray; do
        case "$core" in sing-box) meta="$sing_meta" ;; xray) meta="$xray_meta" ;; esac
        reset_root
        set_release_scenario bad-digest
        run_proxy install --core "$core" --release-channel prerelease
        assert_equal 20 "$RUN_STATUS" "$core prerelease digest mismatch rejection"
        assert_contains "$RUN_OUTPUT" "SHA256 校验失败" "$core prerelease digest error"
        assert_not_contains "$(<"$MOCK_LOG")" "/releases/latest" "$core digest failure does not fall back"
        [[ ! -e "$meta" ]] || fail "$core digest mismatch wrote metadata"

        reset_root
        set_release_scenario bad-version
        run_proxy install --core "$core" --release-channel prerelease
        assert_equal 20 "$RUN_STATUS" "$core prerelease binary version mismatch rejection"
        assert_contains "$RUN_OUTPUT" "二进制版本 9.9.9" "$core prerelease binary version error"
        assert_not_contains "$(<"$MOCK_LOG")" "/releases/latest" "$core version failure does not fall back"
        [[ ! -e "$meta" ]] || fail "$core version mismatch wrote metadata"

        reset_root
        set_release_scenario bad-config
        run_proxy install --core "$core" --release-channel prerelease
        assert_equal 10 "$RUN_STATUS" "$core prerelease config compatibility rejection"
        assert_contains "$RUN_OUTPUT" "拒绝当前配置" "$core prerelease config compatibility error"
        assert_not_contains "$(<"$MOCK_LOG")" "/releases/latest" "$core config failure does not fall back"
        [[ ! -e "$meta" ]] || fail "$core incompatible prerelease wrote metadata"
    done

    reset_root
    set_release_scenario no-prerelease
    run_proxy install --core sing-box --release-channel prerelease
    assert_equal 20 "$RUN_STATUS" "missing prerelease fails safely"
    assert_file_contains "$MOCK_LOG" "/releases?per_page=100&page=2" "missing prerelease reaches empty page"
    assert_not_contains "$(<"$MOCK_LOG")" "/releases/latest" "missing prerelease does not fall back"
    [[ ! -e "$sing_meta" ]] || fail "missing prerelease wrote metadata"

    reset_root
    set_release_scenario repeated-full
    run_proxy install --core xray --release-channel prerelease
    assert_equal 20 "$RUN_STATUS" "repeated full prerelease pages stop safely"
    assert_contains "$RUN_OUTPUT" "超过 10 页" "prerelease page limit message"
    assert_file_contains "$MOCK_LOG" "/releases?per_page=100&page=10" "prerelease page limit reached"
    assert_not_contains "$(<"$MOCK_LOG")" "/releases?per_page=100&page=11" "prerelease page limit prevents unbounded query"
    [[ ! -e "$xray_meta" ]] || fail "page limit wrote metadata"

    reset_root
    set_release_scenario malformed-list
    run_proxy install --core xray --release-channel prerelease
    assert_equal 20 "$RUN_STATUS" "malformed prerelease list rejection"
    [[ ! -e "$xray_meta" ]] || fail "malformed prerelease response wrote metadata"

    reset_root
    set_release_scenario default
    write_core_binary sing-box /usr/bin/sing-box 1.11.0
    run_proxy install --core sing-box --release-channel prerelease
    assert_equal 3 "$RUN_STATUS" "external stable binary not registered as prerelease"
    assert_contains "$RUN_OUTPUT" "先不带 --release-channel/--version" "external prerelease mismatch guidance"
    assert_file_contains "$MOCK_LOG" "/releases?per_page=100&page=2" "external prerelease target resolved"
    [[ ! -e "$sing_meta" ]] || fail "mismatched external prerelease wrote metadata"

    reset_root
    set_release_scenario default
    write_core_binary sing-box /usr/bin/sing-box 1.12.0-beta.1
    run_proxy install --core sing-box --release-channel prerelease
    assert_equal 0 "$RUN_STATUS" "matching external prerelease registration"
    jq -e '.owned == false and .version == "1.12.0-beta.1"' "$sing_meta" >/dev/null || fail "matching external prerelease metadata"

    reset_root
    set_release_scenario default
    write_core_binary xray /usr/bin/xray 25.2.0-rc.1
    run_proxy install --core xray --version v25.2.0-rc.1
    assert_equal 0 "$RUN_STATUS" "matching external exact prerelease registration"
    jq -e '.owned == false and .version == "25.2.0-rc.1"' "$xray_meta" >/dev/null || fail "external exact prerelease metadata"

    reset_root
    set_release_scenario default
    install_external sing-box
    : >"$MOCK_LOG"
    run_proxy update --core sing-box --release-channel prerelease
    assert_equal 3 "$RUN_STATUS" "external prerelease update requires strong confirmation"
    assert_not_contains "$(<"$MOCK_LOG")" "curl " "unconfirmed external prerelease update avoids network"
    run_proxy update --core sing-box --release-channel prerelease --confirm-external-update
    assert_equal 0 "$RUN_STATUS" "confirmed external prerelease update"
    jq -e '.owned == false and .version == "1.12.0-beta.1" and .release_tag == "v1.12.0-beta.1"' \
        "$sing_meta" >/dev/null || fail "confirmed external prerelease update metadata"
}

test_dependency_install_plans() {
    local hint_count
    reset_root

    RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --install-deps --help
    assert_equal 0 "$RUN_STATUS" "direct install-deps help"
    assert_contains "$RUN_OUTPUT" "--install-deps" "install-deps help listing"

    RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy status
    assert_equal 3 "$RUN_STATUS" "status missing jq"
    assert_contains "$RUN_OUTPUT" "jq" "status missing jq tool"
    assert_contains "$RUN_OUTPUT" "--install-deps" "status missing jq hint"
    hint_count="$(grep -o -- '--install-deps' <<<"$RUN_OUTPUT" | wc -l | tr -d ' ')"
    assert_equal 1 "$hint_count" "status has one centralized install-deps hint"

    RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --dry-run --install-deps install --core sing-box
    assert_equal 0 "$RUN_STATUS" "sing-box dependency dry-run"
    assert_contains "$RUN_OUTPUT" "jq" "sing-box jq package plan"
    assert_contains "$RUN_OUTPUT" "curl" "sing-box curl package plan"
    assert_contains "$RUN_OUTPUT" "coreutils" "sing-box checksum package plan"
    assert_contains "$RUN_OUTPUT" "tar" "sing-box archive package plan"
    assert_contains "$RUN_OUTPUT" "安装依赖后重跑完整计划" "sing-box dependency rerun message"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy" ]] || fail "sing-box dependency plan wrote proxy state"

    RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --dry-run --install-deps install --core xray
    assert_equal 0 "$RUN_STATUS" "Xray dependency dry-run"
    assert_contains "$RUN_OUTPUT" "unzip" "Xray archive package plan"
    assert_contains "$RUN_OUTPUT" "安装依赖后重跑完整计划" "Xray dependency rerun message"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy" ]] || fail "Xray dependency plan wrote proxy state"

    RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --dry-run --install-deps node add \
        --profile shadowsocks-aes-256-gcm --core sing-box --port invalid --address proxy.example
    assert_equal 2 "$RUN_STATUS" "invalid node arguments before dependency install"
    assert_not_contains "$RUN_OUTPUT" "apt-get" "invalid node arguments dependency plan"

    RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --dry-run --install-deps node add \
        --profile shadowsocks-aes-256-gcm --core sing-box --address proxy.example
    assert_equal 2 "$RUN_STATUS" "missing node port before dependency install"
    assert_not_contains "$RUN_OUTPUT" "apt-get" "missing node port dependency plan"

    RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --dry-run --install-deps node add \
        --profile vless-ws-tls --core sing-box --port 19991 --address proxy.example \
        --sni proxy.example --path /dependency-plan
    assert_equal 0 "$RUN_STATUS" "node add dependency dry-run"
    assert_contains "$RUN_OUTPUT" "jq" "node add jq package plan"
    assert_contains "$RUN_OUTPUT" "openssl" "node add openssl package plan"
    assert_contains "$RUN_OUTPUT" "iproute2" "node add ss package plan"
    assert_contains "$RUN_OUTPUT" "coreutils" "node add certificate checksum package plan"
    assert_contains "$RUN_OUTPUT" "安装依赖后重跑完整计划" "node add dependency rerun message"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy" ]] || fail "node dependency plan wrote proxy state"

    RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --dry-run --install-deps subscription --core all
    assert_equal 0 "$RUN_STATUS" "subscription dependency dry-run"
    assert_contains "$RUN_OUTPUT" "jq" "subscription jq package plan"
    assert_contains "$RUN_OUTPUT" "coreutils" "subscription base64 and tr package plan"
    assert_contains "$RUN_OUTPUT" "安装依赖后重跑完整计划" "subscription dependency rerun message"

    VPSCTL_ENV_PACKAGE_MANAGER=unsupported RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --dry-run --install-deps status
    assert_equal 2 "$RUN_STATUS" "unknown package manager"
    assert_contains "$RUN_OUTPUT" "无效的软件包管理器" "unknown package manager message"
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
    assert_equal 2 "$(grep -cE '节点数[[:space:]]*：[[:space:]]*1' <<<"$RUN_OUTPUT")" "per-core status counts"
    grep -qE '总节点数[[:space:]]*：[[:space:]]*2' <<<"$RUN_OUTPUT" || fail "status total"
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
    install_external sing-box
    install_external xray
    assert_file_contains "${TEST_SYSTEM_ROOT}/etc/init.d/vpsctl-proxy-xray" 'command="/usr/bin/xray"' "OpenRC service command"
    assert_file_contains "${TEST_SYSTEM_ROOT}/etc/init.d/vpsctl-proxy-xray" 'output_log="/var/log/vpsctl/proxy/xray.log"' "OpenRC log path"
    printf 'openrc fixture\n' >"${TEST_SYSTEM_ROOT}/var/log/vpsctl/proxy/xray.log"
    run_proxy start --core xray --enable
    assert_equal 0 "$RUN_STATUS" "OpenRC start"
    assert_file_contains "$MOCK_LOG" "rc-service vpsctl-proxy-xray start" "OpenRC start routing"
    assert_file_contains "$MOCK_LOG" "rc-update add vpsctl-proxy-xray default" "OpenRC enable routing"
    touch "${TEST_SYSTEM_ROOT}/run/mock-openrc/long-show"
    run_proxy status --json
    assert_equal true "$(jq -r '.cores[] | select(.core == "sing-box") | .enabled' <<<"$RUN_OUTPUT")" "OpenRC sing-box enabled status with long service list"
    assert_equal true "$(jq -r '.cores[] | select(.core == "xray") | .enabled' <<<"$RUN_OUTPUT")" "OpenRC Xray enabled status with long service list"
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
    local id secret before list_json uri subscription decoded validation_detail
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
    grep -Fq 'restart vpsctl-proxy-xray.service' "$MOCK_LOG" || fail "running edit did not restart automatically"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json" ]] || fail "auto-applied edit left pending state"
    assert_equal x-pending "$(jq -r '.nodes[0].name' "$(manifest_path)")" "auto-applied edit name"
    run_proxy restart --core xray
    assert_equal 3 "$RUN_STATUS" "restart confirmation"
    run_proxy restart --core xray --confirm-disruptive
    assert_equal 0 "$RUN_STATUS" "explicit restart"

    touch "${TEST_SYSTEM_ROOT}/run/fail-service-restart-once"
    run_proxy node edit --id "$id" --name x-fail-apply
    assert_equal 20 "$RUN_STATUS" "auto-apply restart failure"
    assert_equal x-pending "$(jq -r '.nodes[0].name' "$(manifest_path)")" "failed auto-apply rolled back name"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json" ]] || fail "failed auto-apply left pending state"

    mkdir -p "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending"
    jq -n --arg core xray '{
        schema_version:1,core:$core,reason:"core-update",
        manifest_backup:"",config_backup:"",binary_backup:"",meta_backup:"",
        relay_backup:"",relay_existed:false,relay_touched:false,
        relay_runtime_touched:false,relay_cache_backup:"",relay_cache_existed:false,
        relay_nft_backup:"",relay_nft_existed:false,created_at:"2026-01-01T00:00:00Z"
    }' >"${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json"
    : >"$MOCK_LOG"
    run_proxy node edit --id "$id" --name x-mixed
    assert_equal 0 "$RUN_STATUS" "edit with core-update pending"
    assert_equal x-mixed "$(jq -r '.nodes[0].name' "$(manifest_path)")" "mixed pending wrote new name"
    [[ -f "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json" ]] || fail "mixed pending did not retain restart marker"
    jq -e '.reason | contains("core-update") and contains("node-edit")' \
        "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json" >/dev/null || fail "mixed pending reasons"
    ! grep -Fq 'restart vpsctl-proxy-xray.service' "$MOCK_LOG" || fail "core-update pending caused auto-restart"
    assert_contains "$RUN_OUTPUT" "请显式 restart 应用" "mixed pending requires explicit restart"
    run_proxy restart --core xray --confirm-disruptive
    assert_equal 0 "$RUN_STATUS" "explicit restart applies mixed pending"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json" ]] || fail "mixed pending not cleared"

    before="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    touch "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    run_proxy node edit --id "$id" --name rejected
    assert_equal 10 "$RUN_STATUS" "binary config validation failure"
    assert_contains "$RUN_OUTPUT" "fixture core validation rejected" "binary config validation detail"
    validation_detail="$(awk -F 'Xray 校验详情：' 'NF > 1 { print $2; exit }' <<<"$RUN_OUTPUT")"
    assert_equal 512 "${#validation_detail}" "binary config validation detail limit"
    assert_contains "$validation_detail" "..." "binary config validation detail truncation marker"
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
    : >"$MOCK_LOG"
    run_proxy node edit --id "$id" --sni new.example --cert-file "$certs/new.example/cert.pem" --key-file "$certs/new.example/key.pem"
    assert_equal 0 "$RUN_STATUS" "running TLS SNI edit"
    new_cert="$(jq -r --arg id "$id" '.nodes[] | select(.id == $id) | .tls.certificate_path' "$(manifest_path)")"
    [[ "$new_cert" =~ /cert-[a-f0-9]{64}\.pem$ && "$new_cert" != "$old_cert" ]] || fail "edited certificate path is not independently fingerprinted"
    grep -Fq 'restart vpsctl-proxy-sing-box.service' "$MOCK_LOG" || fail "running TLS edit did not restart automatically"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/sing-box.json" ]] || fail "auto-applied TLS edit left pending state"
    [[ ! -e "${TEST_SYSTEM_ROOT}${old_cert}" && -f "${TEST_SYSTEM_ROOT}${new_cert}" ]] || fail "auto-apply did not prune the superseded certificate generation"

    touch "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    run_proxy node edit --id "$id" --sni failed.example --cert-file "$certs/failed.example/cert.pem" --key-file "$certs/failed.example/key.pem"
    assert_equal 10 "$RUN_STATUS" "TLS config validation failure"
    rm -f "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    assert_equal "$new_cert" "$(jq -r --arg id "$id" '.nodes[] | select(.id == $id) | .tls.certificate_path' "$(manifest_path)")" "failed TLS edit manifest rollback"
    cert_root="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/certs/${id}"
    failed_cert="$(openssl x509 -in "$certs/failed.example/cert.pem" -noout -fingerprint -sha256 | awk -F= '{gsub(":", "", $2); print tolower($2)}')"
    [[ ! -e "$cert_root/cert-${failed_cert}.pem" && -f "${TEST_SYSTEM_ROOT}${new_cert}" ]] || fail "failed TLS edit left an orphan certificate"
}

test_tls_managed_certificate() {
    reset_root
    install_external sing-box
    local host=managed.example id cert_id live cert_path mode
    cert_id="crt-0123456789abcdef"
    mkdir -p "${TEST_TEMP}/managed" "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live/${cert_id}"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=${host}" \
        -addext "subjectAltName=DNS:${host}" \
        -keyout "${TEST_TEMP}/managed/key.pem" -out "${TEST_TEMP}/managed/cert.pem" >/dev/null 2>&1
    cp -- "${TEST_TEMP}/managed/cert.pem" "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live/${cert_id}/fullchain.pem"
    cp -- "${TEST_TEMP}/managed/key.pem" "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live/${cert_id}/privkey.pem"
    chmod 0640 "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live/${cert_id}/fullchain.pem"
    chmod 0600 "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/security/tls/live/${cert_id}/privkey.pem"
    run_proxy node add --profile vless-ws-tls --name managed-node --port 19301 --address proxy.example \
        --sni "$host" --path /managed --cert-mode managed --cert-id "$cert_id"
    assert_equal 0 "$RUN_STATUS" "managed TLS node add"
    id="$(node_id_by_name managed-node)"
    cert_path="$(jq -r --arg id "$id" '.nodes[] | select(.id == $id) | .tls.certificate_path' "$(manifest_path)")"
    mode="$(jq -r --arg id "$id" '.nodes[] | select(.id == $id) | .tls.mode' "$(manifest_path)")"
    assert_equal "managed" "$mode" "managed cert mode"
    assert_equal "/var/lib/vpsctl/security/tls/live/${cert_id}/fullchain.pem" "$cert_path" "managed live path"
    assert_equal "$cert_id" "$(jq -r --arg id "$id" '.nodes[] | select(.id == $id) | .tls.certificate_id' "$(manifest_path)")" "managed cert id"
    run_proxy node add --profile vless-ws-tls --name missing-managed --port 19302 --address proxy.example \
        --sni "$host" --path /missing --cert-mode managed --cert-id crt-ffffffffffffffff
    assert_equal 3 "$RUN_STATUS" "missing managed cert rejected"
}

test_unified_interactive_api() (
    local output selected status=0 menu_line status_line install_marker subscription decoded
    local selector_stderr="${TEST_TEMP}/selector.stderr"
    local guided_stderr="${TEST_TEMP}/guided.stderr"
    local subscription_stderr="${TEST_TEMP}/subscription.stderr"
    local release_stderr="${TEST_TEMP}/release.stderr"

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
    selected="$(
        vps_cmd_prompt_select() {
            [[ "${PROXY_INTERACTIVE:-0}" == "1" ]] || return 99
            [[ "$1" == "delegated select" && "$2" == "first" && "$3" == "first" && "$4" == "First" ]] || return 98
            printf 'delegated-select'
        }
        PROXY_INTERACTIVE=1
        proxy_prompt_select "delegated select" first first First
    )"
    assert_equal delegated-select "$selected" "selector delegates with captured interactive state"
    selected="$(
        vps_cmd_prompt_value() {
            [[ "${PROXY_INTERACTIVE:-0}" == "1" ]] || return 99
            [[ "$1" == "delegated value" && "$2" == "fallback" ]] || return 98
            printf 'delegated-value'
        }
        PROXY_INTERACTIVE=1
        proxy_prompt_value "delegated value" fallback
    )"
    assert_equal delegated-value "$selected" "value prompt delegates with captured interactive state"
    proxy_test_cancel_action() { return 130; }
    proxy_test_fail_action() { return 3; }
    status=0
    proxy_menu_action proxy_test_cancel_action >/dev/null 2>&1 || status=$?
    assert_equal 0 "$status" "menu action treats selection cancel as back"
    status=0
    proxy_menu_action proxy_test_fail_action >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" "menu action preserves real failures"

    PROXY_INTERACTIVE=1
    PROXY_FORWARD_ARGS=()
    proxy_prompt_release_options install sing-box <<<2 2>"$release_stderr"
    assert_equal $'--release-channel\nprerelease' "$(printf '%s\n' "${PROXY_FORWARD_ARGS[@]}")" "interactive prerelease forwarding"
    output="$(<"$release_stderr")"
    assert_contains "$output" "使用最新稳定版（推荐）" "interactive stable release choice"
    assert_contains "$output" "使用最新预发布版" "interactive prerelease choice"
    assert_contains "$output" "输入精确 Release tag" "interactive exact tag choice"

    PROXY_FORWARD_ARGS=()
    proxy_prompt_release_options update xray <<< $'3\nv25.2.0-rc.1' 2>"$release_stderr"
    assert_equal $'--version\nv25.2.0-rc.1' "$(printf '%s\n' "${PROXY_FORWARD_ARGS[@]}")" "interactive exact tag forwarding"
    PROXY_FORWARD_ARGS=()
    proxy_prompt_release_options install sing-box <<<1 2>"$release_stderr"
    assert_equal '' "$(printf '%s' "${PROXY_FORWARD_ARGS[*]}")" "interactive stable release default"
    PROXY_INTERACTIVE=0

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
    assert_contains "$output" "总节点数" "menu status total"
    menu_line="$(grep -n -m1 '代理能力' <<<"$output" | cut -d: -f1)"
    status_line="$(grep -nE -m1 '总节点数[[:space:]]*：[[:space:]]*0' <<<"$output" | cut -d: -f1)"
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

    subscription="$(proxy_subscription_interactive <<<2 2>"$subscription_stderr")"
    output="$(<"$subscription_stderr")"
    assert_contains "$output" "全部节点" "subscription range includes all nodes"
    assert_contains "$output" "Xray（2 个节点）" "subscription range includes installed core with nodes"
    assert_not_contains "$output" "sing-box（" "subscription range filters core without nodes"
    decoded="$(printf '%s' "$subscription" | base64 -d)"
    assert_contains "$decoded" "numbered-one" "interactive core subscription first URI"
    assert_contains "$decoded" "numbered-two" "interactive core subscription second URI"
    status=0
    proxy_subscription_interactive <<<3 >/dev/null 2>&1 || status=$?
    assert_equal 130 "$status" "subscription range can return to node menu"

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

    output="$(proxy_node_add --profile vless-ws-tls --port 19401 --address proxy.example <<< $'\n\n2\n\n\n\n\n2\n/tmp/cert.pem\n/tmp/key.pem\n' 2>&1)"
    assert_contains "$output" "证书方式" "custom certificate enum"
    assert_contains "$output" "生成自签名证书" "certificate self-signed choice"
    assert_contains "$output" "导入现有证书" "certificate imported choice"
    assert_contains "$output" "证书文件绝对路径" "imported certificate selection"
    assert_contains "$output" "出站 IP 策略" "custom node IP strategy choice"

    output="$(proxy_node_add --profile hysteria2 --port 19402 --address proxy.example <<< $'\n\n2\n\n\n\n\n2\n123\n456\n' 2>&1)"
    assert_contains "$output" "混淆方式" "custom obfuscation enum"
    assert_contains "$output" "不使用混淆" "obfuscation none choice"
    assert_contains "$output" "Salamander" "obfuscation Salamander choice"
    assert_contains "$output" "上行 Mbps" "custom obfuscation bandwidth"

    output="$(proxy_node_add --profile tuic-v5 --port 19403 --address proxy.example <<< $'\n\n2\n\n\n\n\n3\n' 2>&1)"
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

test_node_ip_strategy_and_batch() {
    local sb1 sb2 xr1 strategy expected config manifest_hash config_hash exit_id binding_id node_uri
    local list_json show_json pending
    reset_root
    install_external sing-box
    install_external xray

    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box --name policy-sb-1 --port 19601 \
        --address proxy.example --ip-strategy prefer_ipv4
    assert_equal 0 "$RUN_STATUS" "sing-box node with explicit IP strategy"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box --name policy-sb-2 --port 19602 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "second sing-box policy node"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name policy-xr-1 --port 19603 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "first Xray policy node"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name policy-xr-2 --port 19604 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "second Xray policy node"
    sb1="$(node_id_by_name policy-sb-1)"; sb2="$(node_id_by_name policy-sb-2)"
    xr1="$(node_id_by_name policy-xr-1)"

    config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json"
    jq -e --arg id "$sb1" '
        any(.outbounds[]; .tag == ("direct-" + $id) and .domain_resolver.server == "local" and .domain_resolver.strategy == "prefer_ipv4") and
        any(.route.rules[]; .inbound == [$id] and .outbound == ("direct-" + $id)) and
        any(.dns.servers[]; .tag == "local" and .type == "local")
    ' "$config" >/dev/null || fail "sing-box explicit policy renderer"

    # A legacy node without ip_strategy must be exposed as auto without forcing
    # an eager manifest rewrite.
    jq --arg id "$sb2" '(.nodes[] | select(.id == $id)) |= del(.ip_strategy)' "$(manifest_path)" >"${TEST_TEMP}/legacy-nodes.json"
    cp "${TEST_TEMP}/legacy-nodes.json" "$(manifest_path)"
    run_proxy node list --core sing-box --json
    assert_equal 0 "$RUN_STATUS" "legacy node list default"
    list_json="$RUN_OUTPUT"
    jq -e --arg id "$sb2" '.nodes[] | select(.id == $id and .ip_strategy == "auto" and .ip_strategy_effective == true)' \
        >/dev/null <<<"$list_json" || fail "legacy node auto JSON default"
    run_proxy node show --id "$sb2"
    assert_equal 0 "$RUN_STATUS" "legacy node show default"
    show_json="$RUN_OUTPUT"
    jq -e '.ip_strategy == "auto"' >/dev/null <<<"$show_json" || fail "legacy node detail auto default"

    manifest_hash="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json"
    config_hash="$(sha256sum "$config" | awk '{print $1}')"
    run_proxy --dry-run node ip-policy set --core sing-box --ip-strategy ipv6_only --all
    assert_equal 0 "$RUN_STATUS" "node policy batch dry-run"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "node policy dry-run manifest"
    assert_equal "$config_hash" "$(sha256sum "$config" | awk '{print $1}')" "node policy dry-run config"

    for strategy in auto prefer_ipv4 prefer_ipv6 ipv4_only ipv6_only; do
        run_proxy node ip-policy set --core sing-box --ip-strategy "$strategy" --id "$sb1"
        assert_equal 0 "$RUN_STATUS" "sing-box strategy ${strategy}"
        assert_equal "$strategy" "$(jq -r --arg id "$sb1" '.nodes[] | select(.id == $id) | .ip_strategy' "$(manifest_path)")" "sing-box manifest ${strategy}"
        if [[ "$strategy" == auto ]]; then
            jq -e --arg id "$sb1" 'all(.outbounds[]; .tag != ("direct-" + $id)) and all(.route.rules[]?; .outbound != ("direct-" + $id))' \
                "$config" >/dev/null || fail "sing-box auto renderer"
        else
            jq -e --arg id "$sb1" --arg strategy "$strategy" '
                any(.outbounds[]; .tag == ("direct-" + $id) and .domain_resolver.strategy == $strategy) and
                any(.route.rules[]; .inbound == [$id] and .outbound == ("direct-" + $id))
            ' "$config" >/dev/null || fail "sing-box ${strategy} renderer"
        fi
    done

    config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json"
    for strategy in auto prefer_ipv4 prefer_ipv6 ipv4_only ipv6_only; do
        case "$strategy" in
            auto) expected=AsIs ;;
            prefer_ipv4) expected=UseIPv4v6 ;;
            prefer_ipv6) expected=UseIPv6v4 ;;
            ipv4_only) expected=ForceIPv4 ;;
            ipv6_only) expected=ForceIPv6 ;;
        esac
        run_proxy node ip-policy set --core xray --ip-strategy "$strategy" --id "$xr1"
        assert_equal 0 "$RUN_STATUS" "Xray strategy ${strategy}"
        if [[ "$strategy" == auto ]]; then
            jq -e --arg id "$xr1" 'all(.outbounds[]; .tag != ("direct-" + $id)) and all(.routing.rules[]?; .outboundTag != ("direct-" + $id))' \
                "$config" >/dev/null || fail "Xray auto renderer"
        else
            jq -e --arg id "$xr1" --arg expected "$expected" '
                any(.outbounds[]; .tag == ("direct-" + $id) and .protocol == "freedom" and .settings.domainStrategy == $expected) and
                any(.routing.rules[]; .inboundTag == [$id] and .outboundTag == ("direct-" + $id))
            ' "$config" >/dev/null || fail "Xray ${strategy} renderer"
        fi
    done

    run_proxy node ip-policy set --core sing-box --ip-strategy prefer_ipv6 --id "$sb1" --id "$sb1" --id "$sb2"
    assert_equal 0 "$RUN_STATUS" "deduplicated same-core node batch"
    assert_contains "$RUN_OUTPUT" '2 个节点' "deduplicated batch count"
    assert_equal 2 "$(jq -r '[.nodes[] | select(.core == "sing-box" and .ip_strategy == "prefer_ipv6")] | length' "$(manifest_path)")" "deduplicated batch result"

    run_proxy node ip-policy set --core xray --ip-strategy ipv4_only --profile shadowsocks-aes-256-gcm
    assert_equal 0 "$RUN_STATUS" "profile batch"
    assert_equal 2 "$(jq -r '[.nodes[] | select(.core == "xray" and .ip_strategy == "ipv4_only")] | length' "$(manifest_path)")" "profile batch result"
    run_proxy node ip-policy set --core xray --ip-strategy prefer_ipv4 --all
    assert_equal 0 "$RUN_STATUS" "all-nodes batch"
    assert_equal 2 "$(jq -r '[.nodes[] | select(.core == "xray" and .ip_strategy == "prefer_ipv4")] | length' "$(manifest_path)")" "all-nodes batch result"

    manifest_hash="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    run_proxy node ip-policy set --core sing-box --ip-strategy ipv6_only \
        --profile shadowsocks-aes-256-gcm --profile shadowsocks-aes-256-gcm
    assert_equal 2 "$RUN_STATUS" "duplicate profile selector rejection"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "duplicate profile manifest"
    run_proxy node ip-policy set --core sing-box --ip-strategy ipv6_only --id "$xr1"
    assert_equal 3 "$RUN_STATUS" "mixed-core ID rejection"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "mixed-core rejection manifest"
    run_proxy node ip-policy set --core sing-box --ip-strategy ipv6_only --profile vless-tcp
    assert_equal 3 "$RUN_STATUS" "empty profile selection"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "empty selection manifest"

    config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json"
    config_hash="$(sha256sum "$config" | awk '{print $1}')"
    touch "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    run_proxy node ip-policy set --core sing-box --ip-strategy ipv4_only --all
    assert_equal 10 "$RUN_STATUS" "batch binary validation failure"
    assert_contains "$RUN_OUTPUT" '请先更新内核' "old sing-box domain_resolver upgrade hint"
    rm -f -- "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "failed batch manifest hash"
    assert_equal "$config_hash" "$(sha256sum "$config" | awk '{print $1}')" "failed batch config hash"

    run_proxy node show --id "$sb2" --uri
    assert_equal 0 "$RUN_STATUS" "policy relay source URI"
    node_uri="$RUN_OUTPUT"
    run_proxy relay exit add --name policy-protocol --uri "$node_uri" --profile shadowsocks-aes-256-gcm --core sing-box
    assert_equal 0 "$RUN_STATUS" "policy relay protocol exit"
    exit_id="$(jq -r '.exits[] | select(.name == "policy-protocol") | .id' "$(relay_path)")"
    run_proxy relay bind add --node-id "$sb1" --exit-id "$exit_id"
    assert_equal 0 "$RUN_STATUS" "policy node relay binding"
    binding_id="$(jq -r --arg id "$sb1" '.bindings[] | select(.node_id == $id) | .id' "$(relay_path)")"
    run_proxy node ip-policy set --core sing-box --ip-strategy ipv6_only --id "$sb1"
    assert_equal 0 "$RUN_STATUS" "persist policy on relay-bound node"
    jq -e --arg id "$sb1" 'all(.outbounds[]; .tag != ("direct-" + $id)) and all(.route.rules[]?; .outbound != ("direct-" + $id))' \
        "$config" >/dev/null || fail "relay-bound node still rendered direct policy"
    run_proxy node show --id "$sb1"
    assert_equal 0 "$RUN_STATUS" "relay-bound policy detail"
    jq -e '.relay_bound == true and .ip_strategy == "ipv6_only" and .ip_strategy_effective == false and .ip_strategy_status == "relay_bound"' \
        >/dev/null <<<"$RUN_OUTPUT" || fail "relay-bound policy status"
    run_proxy relay bind delete --id "$binding_id" --confirm-delete
    assert_equal 0 "$RUN_STATUS" "policy relay unbind"
    jq -e --arg id "$sb1" 'any(.outbounds[]; .tag == ("direct-" + $id) and .domain_resolver.strategy == "ipv6_only")' \
        "$config" >/dev/null || fail "unbound policy not restored"

    run_proxy start --core sing-box --enable
    assert_equal 0 "$RUN_STATUS" "start sing-box for pending policy test"
    : >"$MOCK_LOG"
    run_proxy node ip-policy set --core sing-box --ip-strategy prefer_ipv4 --id "$sb1"
    assert_equal 0 "$RUN_STATUS" "active-core policy batch"
    grep -Fq 'restart vpsctl-proxy-sing-box.service' "$MOCK_LOG" || fail "active policy batch did not restart automatically"
    pending="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/sing-box.json"
    [[ ! -e "$pending" ]] || fail "auto-applied policy batch left pending restart"
}

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
    source "${TEST_ROOT}/commands/service/proxy/relay-uri.sh"
    source "${TEST_ROOT}/commands/service/proxy/relay-forward.sh"
    source "${TEST_ROOT}/commands/service/proxy/core.sh"
    proxy_common_init

    _proxy_relay_forward_valid_ipv6 '2001:db8::1' || fail "valid compressed IPv6 literal rejected"
    _proxy_relay_forward_valid_ipv6 '::ffff:192.0.2.1' || fail "valid IPv4-mapped IPv6 literal rejected"
    if _proxy_relay_forward_valid_ipv6 '1:2:3:4:5:6:7:8:9'; then fail "nine-hextet IPv6 literal accepted"; fi
    if _proxy_relay_forward_valid_ipv6 '1:2:3:4:5:6:7:8::1'; then fail "compressed-overflow IPv6 literal accepted"; fi
    if _proxy_relay_forward_valid_ipv6 '12345::1'; then fail "oversized IPv6 hextet accepted"; fi

    local version_binary="${TEST_TEMP}/version-core" parsed_version version_status=0
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$VERSION_FIXTURE_OUTPUT"' >"$version_binary"
    chmod +x "$version_binary"

    export VERSION_FIXTURE_OUTPUT=$'Xray 26.3.27 (Xray, Penetrates Everything.)\nCompiled with go1.26.1 linux/amd64'
    parsed_version="$(_proxy_core_binary_version xray "$version_binary")"
    assert_equal 26.3.27 "$parsed_version" "Xray product version before later Go version"

    export VERSION_FIXTURE_OUTPUT='Xray 26.3.27 go1.26.1 linux/amd64'
    parsed_version="$(_proxy_core_binary_version xray "$version_binary")"
    assert_equal 26.3.27 "$parsed_version" "Xray product version before same-line Go version"

    export VERSION_FIXTURE_OUTPUT='sing-box version 1.13.12'
    parsed_version="$(_proxy_core_binary_version sing-box "$version_binary")"
    assert_equal 1.13.12 "$parsed_version" "standard sing-box product version"

    export VERSION_FIXTURE_OUTPUT=$'Xray development build\nCompiled with go1.26.1 linux/amd64'
    version_status=0
    _proxy_core_binary_version xray "$version_binary" >/dev/null 2>&1 || version_status=$?
    assert_equal 20 "$version_status" "Xray output without product version rejection"

    export VERSION_FIXTURE_OUTPUT='sing-box version 26.3.27'
    version_status=0
    _proxy_core_binary_version xray "$version_binary" >/dev/null 2>&1 || version_status=$?
    assert_equal 20 "$version_status" "wrong Xray product prefix rejection"

    export VERSION_FIXTURE_OUTPUT='Xray version 26.3.27'
    version_status=0
    _proxy_core_binary_version xray "$version_binary" >/dev/null 2>&1 || version_status=$?
    assert_equal 20 "$version_status" "unexpected Xray version format rejection"

    export VERSION_FIXTURE_OUTPUT=$'Xray 26.3.27\nXray 26.3.28'
    version_status=0
    _proxy_core_binary_version xray "$version_binary" >/dev/null 2>&1 || version_status=$?
    assert_equal 20 "$version_status" "ambiguous Xray product versions rejection"

    local cert_dir="${TEST_TEMP}/cert" profile label supported node rendered uri id profile_obfs port=20000 count=0
    local descriptor relay_exit outbound rewritten rewritten_descriptor ss2022_uri="" parse_status=0 parse_error="" legacy_payload legacy_uri
    local profile_count=0 sb_count=0 xray_count=0 overlap_count=0 sb_only_count=0 xray_only_count=0
    local digest_file="${TEST_TEMP}/xray.dgst" digest digest_status=0 label_status=0
    local -A expected_labels=(
        [vless-reality-vision]='VLESS + REALITY + XTLS Vision'
        [vless-ws-tls]='VLESS + WebSocket + TLS'
        [trojan-ws-tls]='Trojan + WebSocket + TLS'
        [vless-grpc-tls]='VLESS + gRPC + TLS'
        [anytls-tls]='AnyTLS + TLS'
        [anytls-reality]='AnyTLS + REALITY'
        [hysteria2]='Hysteria2'
        [tuic-v5]='TUIC v5'
        [shadowsocks-aes-256-gcm]='Shadowsocks AES-256-GCM'
        [shadowsocks-chacha20-poly1305]='Shadowsocks ChaCha20-Poly1305'
        [shadowsocks-2022]='Shadowsocks 2022'
        [shadowsocks-2022-padding]='Shadowsocks 2022 Padding'
        [shadowsocks-2022-shadowtls]='Shadowsocks 2022 + ShadowTLS'
        [vless-tcp]='VLESS + TCP'
        [socks5]='SOCKS5'
        [vless-grpc-reality]='VLESS + gRPC + REALITY'
        [trojan-xhttp-reality]='Trojan + XHTTP + REALITY'
        [trojan-grpc-reality]='Trojan + gRPC + REALITY'
        [vless-xhttp-tls]='VLESS + XHTTP + TLS'
        [trojan-grpc-tls]='Trojan + gRPC + TLS'
    )
    assert_equal 'hysteria2-8443' "$(proxy_profile_default_name hysteria2 8443)" "default node name uses profile id"
    proxy_sb_profile_label 'not-a-profile' >/dev/null || label_status=$?
    assert_equal 2 "$label_status" "unknown sing-box profile label"
    label_status=0
    proxy_xray_profile_label 'not-a-profile' >/dev/null || label_status=$?
    assert_equal 2 "$label_status" "unknown Xray profile label"
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
        [[ -n "${expected_labels[$profile]:-}" ]] || fail "$profile missing expected official label"
        assert_equal "${expected_labels[$profile]}" "$label" "$profile official label"
        assert_equal "$label" "$(proxy_profile_label "$profile")" "$profile label helper"
        if proxy_sb_supports_profile "$profile" && proxy_xray_supports_profile "$profile"; then
            assert_equal "$(proxy_sb_profile_label "$profile")" "$(proxy_xray_profile_label "$profile")" "$profile shared core label"
        fi
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
            descriptor="$(proxy_relay_uri_parse "$uri" "$profile")" || fail "$profile/$core relay URI parse"
            assert_equal "$profile" "$(jq -r '.profile' <<<"$descriptor")" "$profile/$core parsed profile"
            jq -e --arg core "$core" '.compatible_cores | index($core) != null' >/dev/null <<<"$descriptor" || fail "$profile/$core parsed core mapping"
            relay_exit="$(jq -cn --arg id "exit-0000000000000001" --arg name matrix --arg core "$core" \
                --arg profile "$profile" --arg uri "$uri" --argjson descriptor "$descriptor" \
                '{id:$id,name:$name,type:"protocol",core:$core,profile:$profile,uri:$uri,descriptor:$descriptor,
                  endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint}')"
            outbound="$(proxy_relay_render_outbound "$core" "$relay_exit")" || fail "$profile/$core relay outbound render"
            jq -e '(.outbounds | type) == "array" and (.outbounds | length) > 0 and (.target_tag | length) > 0' \
                >/dev/null <<<"$outbound" || fail "$profile/$core relay outbound shape"
            if [[ "$core" == xray && "$(jq -r '.tls.mode == "tls" and .tls.certificate_sha256 != ""' <<<"$descriptor")" == true ]]; then
                assert_not_contains "$outbound" 'allowInsecure' "$profile/$core removed Xray allowInsecure"
                jq -e --arg pin "$(jq -r '.tls.certificate_sha256' <<<"$descriptor")" \
                    '.outbounds[0].streamSettings.tlsSettings.pinnedPeerCertSha256 == $pin' \
                    >/dev/null <<<"$outbound" || fail "$profile/$core Xray certificate pin"
            fi
            rewritten="$(proxy_relay_uri_rewrite "$uri" relay.example 24443)" || fail "$profile/$core relay URI rewrite"
            rewritten_descriptor="$(proxy_relay_uri_parse "$rewritten" "$profile")" || fail "$profile/$core rewritten URI parse"
            assert_equal relay.example "$(jq -r '.endpoint.host' <<<"$rewritten_descriptor")" "$profile/$core rewritten host"
            assert_equal 24443 "$(jq -r '.endpoint.port' <<<"$rewritten_descriptor")" "$profile/$core rewritten port"
            [[ "$profile" != shadowsocks-2022 ]] || ss2022_uri="$uri"
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
    parse_status=0
    proxy_relay_uri_parse "$ss2022_uri" >/dev/null 2>&1 || parse_status=$?
    assert_equal 2 "$parse_status" "ambiguous Shadowsocks 2022 profile selection"
    parse_status=0
    parse_error=''
    parse_error="$(proxy_relay_uri_parse 'vless://11111111-1111-4111-8111-111111111111@proxy.example:443?type=tcp&security=none&unsupported=1' 2>&1)" || parse_status=$?
    assert_equal 10 "$parse_status" "unsupported relay URI parameter rejection"
    assert_contains "$parse_error" 'unsupported query parameter: unsupported' "unsupported relay URI parameter message"
    descriptor="$(proxy_relay_uri_parse 'vless://11111111-1111-4111-8111-111111111111@198.51.100.24:55210?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef&type=tcp&headerType=none#compat')" || fail "VLESS Reality headerType compatibility parse"
    assert_equal vless-reality-vision "$(jq -r '.profile' <<<"$descriptor")" "VLESS Reality headerType profile"
    assert_equal '198.51.100.24:55210' "$(jq -r '.endpoint.host + ":" + (.endpoint.port | tostring)' <<<"$descriptor")" "VLESS Reality headerType endpoint"
    parse_status=0
    proxy_relay_uri_parse 'vless://11111111-1111-4111-8111-111111111111@proxy.example:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef&type=tcp&headerType=http' >/dev/null 2>&1 || parse_status=$?
    assert_equal 10 "$parse_status" "unsupported VLESS Reality header type rejection"
    descriptor="$(proxy_relay_uri_parse 'vless://11111111-1111-4111-8111-111111111111@proxy.example:443?encryption=none&type=grpc&security=tls&sni=proxy.example&serviceName=relay&authority=proxy.example&insecure=1' vless-grpc-tls)" || fail "Xray insecure TLS fixture parse"
    relay_exit="$(jq -cn --arg id exit-0000000000000001 --arg name insecure --arg core xray \
        --arg profile vless-grpc-tls --arg uri 'vless://11111111-1111-4111-8111-111111111111@proxy.example:443?encryption=none&type=grpc&security=tls&sni=proxy.example&serviceName=relay&authority=proxy.example&insecure=1' \
        --argjson descriptor "$descriptor" \
        '{id:$id,name:$name,type:"protocol",core:$core,profile:$profile,uri:$uri,descriptor:$descriptor,
          endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint}')"
    parse_status=0
    proxy_relay_render_outbound xray "$relay_exit" >/dev/null 2>&1 || parse_status=$?
    assert_equal 10 "$parse_status" "Xray insecure TLS without certificate pin rejection"
    legacy_payload="$(printf 'aes-256-gcm:legacy-secret@[2001:db8::10]:8388' | base64 | tr -d '\r\n')"
    legacy_uri="ss://${legacy_payload}#legacy"
    descriptor="$(proxy_relay_uri_parse "$legacy_uri" shadowsocks-aes-256-gcm)" || fail "legacy Base64 Shadowsocks IPv6 parse"
    assert_equal 2001:db8::10 "$(jq -r '.endpoint.host' <<<"$descriptor")" "legacy Shadowsocks IPv6 host"
    rewritten="$(proxy_relay_uri_rewrite "$legacy_uri" 2001:db8::20 9443)" || fail "legacy Base64 Shadowsocks rewrite"
    descriptor="$(proxy_relay_uri_parse "$rewritten" shadowsocks-aes-256-gcm)" || fail "rewritten legacy Shadowsocks parse"
    assert_equal 2001:db8::20 "$(jq -r '.endpoint.host' <<<"$descriptor")" "rewritten legacy Shadowsocks IPv6 host"
    assert_equal 9443 "$(jq -r '.endpoint.port' <<<"$descriptor")" "rewritten legacy Shadowsocks port"
    rewritten="$(proxy_relay_uri_rewrite 'vless://11111111-1111-4111-8111-111111111111@[2001:db8::1]:443?encryption=none&type=tcp#name%20with%20space' relay.example 10443)" || fail "ordered URI rewrite"
    assert_equal 'vless://11111111-1111-4111-8111-111111111111@relay.example:10443?encryption=none&type=tcp#name%20with%20space' "$rewritten" "URI rewrite preserves query order and fragment"
    parse_status=0
    proxy_relay_uri_parse 'socks5://bad%ZZ:value@proxy.example:1080' >/dev/null 2>&1 || parse_status=$?
    assert_equal 10 "$parse_status" "invalid percent encoding rejection"
}

test_relay_state_bindings_and_purge() {
    local exit_id node1 node2 binding_id original_uri status_json config outbound_count
    reset_root

    run_proxy relay exit add --name unsafe-xray \
        --uri 'vless://11111111-1111-4111-8111-111111111111@proxy.example:443?encryption=none&type=grpc&security=tls&sni=proxy.example&serviceName=relay&authority=proxy.example&insecure=1' \
        --core xray
    assert_equal 10 "$RUN_STATUS" "unrenderable Xray TLS exit rejected before core installation"
    assert_equal 0 "$(jq -r '.exits | length' "$(relay_path)")" "rejected Xray exit not persisted"

    run_proxy relay exit add --name landing-socks --uri 'socks5://relay-user:relay-pass@198.51.100.20:1080#landing' --core sing-box
    assert_equal 0 "$RUN_STATUS" "save protocol exit without installed core"
    [[ -f "$(relay_path)" ]] || fail "relay state was not created"
    assert_equal 600 "$(stat -c %a "$(relay_path)")" "relay state permissions"
    exit_id="$(jq -r '.exits[0].id' "$(relay_path)")"
    run_proxy relay status --json
    assert_equal 0 "$RUN_STATUS" "relay JSON status without core"
    status_json="$RUN_OUTPUT"
    assert_equal 1 "$(jq -r '.unverified_protocol_exits | length' <<<"$status_json")" "unverified exit status"
    run_proxy relay exit edit --id "$exit_id" \
        --uri 'vless://11111111-1111-4111-8111-111111111111@198.51.100.21:10443?encryption=none&type=tcp#landing-vless'
    assert_equal 0 "$RUN_STATUS" "protocol exit edit derives new profile"
    assert_equal vless-tcp "$(jq -r '.exits[0].profile' "$(relay_path)")" "edited protocol exit profile"
    assert_equal sing-box "$(jq -r '.exits[0].core' "$(relay_path)")" "edited protocol exit compatible core"

    install_external sing-box
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box --name relay-entry-1 --port 32101 --address entry.example
    assert_equal 0 "$RUN_STATUS" "first relay entry add"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box --name relay-entry-2 --port 32102 --address entry.example
    assert_equal 0 "$RUN_STATUS" "second relay entry add"
    node1="$(node_id_by_name relay-entry-1)"
    node2="$(node_id_by_name relay-entry-2)"
    run_proxy node show --id "$node1" --uri
    assert_equal 0 "$RUN_STATUS" "entry URI before binding"
    original_uri="$RUN_OUTPUT"

    run_proxy relay bind add --node-id "$node1" --exit-id "$exit_id"
    assert_equal 0 "$RUN_STATUS" "first relay binding"
    run_proxy relay bind add --node-id "$node2" --exit-id "$exit_id"
    assert_equal 0 "$RUN_STATUS" "second relay binding sharing exit"
    assert_equal 2 "$(jq -r '.bindings | length' "$(relay_path)")" "shared exit binding count"
    config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json"
    outbound_count="$(jq -r '[.outbounds[] | select((.tag // "") | startswith("relay-exit-"))] | length' "$config")"
    [[ "$outbound_count" == 1 ]] || fail "one shared relay outbound: got ${outbound_count}; config=$(jq -c . "$config")"
    assert_equal 2 "$(jq -r '[.route.rules[] | select(.outbound | startswith("relay-exit-"))] | length' "$config")" "two inbound routing rules"
    run_proxy node show --id "$node1" --uri
    assert_equal "$original_uri" "$RUN_OUTPUT" "binding preserves entry URI"

    run_proxy relay bind add --node-id "$node1" --exit-id "$exit_id"
    assert_equal 3 "$RUN_STATUS" "one exit per entry invariant"
    run_proxy node delete --id "$node1" --confirm-delete
    assert_equal 3 "$RUN_STATUS" "bound node delete refusal"
    assert_contains "$RUN_OUTPUT" "仍作为中转入口" "bound node delete diagnostic"
    run_proxy relay exit delete --id "$exit_id"
    assert_equal 3 "$RUN_STATUS" "referenced exit delete refusal"
    run_proxy uninstall --core sing-box --purge --confirm-purge
    assert_equal 3 "$RUN_STATUS" "core purge relay refusal"
    assert_contains "$RUN_OUTPUT" "$exit_id" "core purge exit diagnostic"
    assert_contains "$RUN_OUTPUT" "$node1" "core purge node diagnostic"

    binding_id="$(jq -r --arg node "$node1" '.bindings[] | select(.node_id == $node) | .id' "$(relay_path)")"
    run_proxy relay bind delete --id "$binding_id" --confirm-delete
    assert_equal 0 "$RUN_STATUS" "relay binding delete"
    run_proxy node delete --id "$node2" --cascade-relay --confirm-delete
    assert_equal 0 "$RUN_STATUS" "node delete with relay cascade"
    assert_equal 0 "$(jq -r '.bindings | length' "$(relay_path)")" "all relay bindings removed"
    run_proxy relay exit delete --id "$exit_id"
    assert_equal 0 "$RUN_STATUS" "unreferenced exit delete"
    assert_equal 0 "$(jq -r '.exits | length' "$(relay_path)")" "relay exit removed"
}

test_relay_xray_pending_and_validation() {
    local node1 node2 node3 node_uri new_uri exit_id direct_id forward_id config pending state_hash
    reset_root
    install_external xray
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name xray-entry-1 --port 32301 --address xray-entry.example
    assert_equal 0 "$RUN_STATUS" "first Xray relay entry"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name xray-entry-2 --port 32302 --address xray-entry.example
    assert_equal 0 "$RUN_STATUS" "second Xray relay entry"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name xray-entry-3 --port 32303 --address xray-entry.example
    assert_equal 0 "$RUN_STATUS" "third Xray relay entry"
    node1="$(node_id_by_name xray-entry-1)"; node2="$(node_id_by_name xray-entry-2)"; node3="$(node_id_by_name xray-entry-3)"
    run_proxy node show --id "$node1" --uri
    assert_equal 0 "$RUN_STATUS" "Xray relay source URI"
    node_uri="$RUN_OUTPUT"
    run_proxy relay exit add --name xray-landing --uri "$node_uri" --profile shadowsocks-aes-256-gcm --core xray
    assert_equal 0 "$RUN_STATUS" "Xray relay exit"
    exit_id="$(jq -r '.exits[] | select(.name == "xray-landing") | .id' "$(relay_path)")"
    printf '198.51.100.80\n' >"${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-xray-entry.example"
    run_proxy relay forward add --name xray-forward --exit-id "$exit_id" --listen-ports 32400 --network auto --address relay.example
    assert_equal 0 "$RUN_STATUS" "Xray protocol forward"
    forward_id="$(jq -r '.forwards[] | select(.name == "xray-forward") | .id' "$(relay_path)")"
    run_proxy relay exit add --name xray-direct --target 198.51.100.50 --target-port 443
    assert_equal 0 "$RUN_STATUS" "Xray direct exit"
    direct_id="$(jq -r '.exits[] | select(.name == "xray-direct") | .id' "$(relay_path)")"
    run_proxy relay bind add --node-id "$node3" --exit-id "$direct_id"
    assert_equal 3 "$RUN_STATUS" "direct exit cannot be bound"

    run_proxy start --core xray --enable
    assert_equal 0 "$RUN_STATUS" "start Xray before relay binding"
    : >"$MOCK_LOG"
    run_proxy relay bind add --node-id "$node1" --exit-id "$exit_id"
    assert_equal 0 "$RUN_STATUS" "active Xray first relay binding"
    grep -Fq 'restart vpsctl-proxy-xray.service' "$MOCK_LOG" || fail "first relay binding did not restart automatically"
    pending="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json"
    [[ ! -e "$pending" ]] || fail "auto-applied first relay binding left pending state"
    : >"$MOCK_LOG"
    run_proxy relay bind add --node-id "$node2" --exit-id "$exit_id"
    assert_equal 0 "$RUN_STATUS" "active Xray shared relay binding"
    grep -Fq 'restart vpsctl-proxy-xray.service' "$MOCK_LOG" || fail "shared relay binding did not restart automatically"
    [[ ! -e "$pending" ]] || fail "auto-applied shared relay binding left pending state"
    config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json"
    assert_equal 1 "$(jq -r '[.outbounds[] | select((.tag // "") | startswith("relay-exit-"))] | length' "$config")" "one shared Xray relay outbound"
    assert_equal 2 "$(jq -r '[.routing.rules[] | select((.outboundTag // "") | startswith("relay-exit-"))] | length' "$config")" "two Xray inboundTag rules"
    assert_equal 2 "$(jq -r '.bindings | length' "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/lkg/xray/relay.json")" "Xray relay LKG snapshot"
    [[ -f "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/lkg/xray/relay-resolved.json" ]] || fail "Xray relay LKG DNS cache snapshot"
    [[ -f "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/lkg/xray/relay-nftables.nft" ]] || fail "Xray relay LKG nft snapshot"

    state_hash="$(sha256sum "$(relay_path)" | awk '{print $1}')"
    touch "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    run_proxy relay bind add --node-id "$node3" --exit-id "$exit_id"
    assert_equal 10 "$RUN_STATUS" "relay binding core validation failure"
    rm -f -- "${TEST_SYSTEM_ROOT}/run/fail-core-validation"
    assert_equal "$state_hash" "$(sha256sum "$(relay_path)" | awk '{print $1}')" "relay state unchanged after core validation failure"

    new_uri="${node_uri/xray-entry.example/xray-new.example}"
    printf '198.51.100.81\n' >"${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-xray-new.example"
    rm -f -- "${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-xray-entry.example"
    touch "${TEST_SYSTEM_ROOT}/run/fail-service-restart-once"
    run_proxy relay exit edit --id "$exit_id" --uri "$new_uri" --profile shadowsocks-aes-256-gcm --core xray
    assert_equal 20 "$RUN_STATUS" "failed auto-apply restores previous relay data plane"
    [[ ! -e "$pending" ]] || fail "failed auto-apply did not consume restored pending state"
    assert_equal "$node_uri" "$(jq -r --arg id "$exit_id" '.exits[] | select(.id == $id) | .uri' "$(relay_path)")" "failed auto-apply restored relay exit"
    assert_equal xray-entry.example "$(jq -r --arg id "$exit_id" '.exits[$id].host' "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json")" "failed auto-apply restored DNS cache"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_forward4" ]] || fail "failed auto-apply did not restore managed nft table"
    run_proxy relay forward delete --id "$forward_id" --confirm-delete
    assert_equal 0 "$RUN_STATUS" "Xray forward cleanup after restart rollback"
}

test_relay_forwarding_subscription_and_rollback() {
    local node_id node_uri exit_id forward_id direct_id ipv6_id ipv6_forward_id state_hash batch_hash cache_hash
    local decoded status_json
    reset_root
    install_external sing-box
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box --name subscription-entry --port 32200 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "relay subscription entry add"
    node_id="$(node_id_by_name subscription-entry)"
    run_proxy node show --id "$node_id" --uri
    assert_equal 0 "$RUN_STATUS" "relay source URI"
    node_uri="$RUN_OUTPUT"
    printf '198.51.100.20\n' >"${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-proxy.example"

    run_proxy relay exit add --name protocol-landing --uri "$node_uri" --profile shadowsocks-aes-256-gcm --core sing-box
    assert_equal 0 "$RUN_STATUS" "protocol forward exit add"
    exit_id="$(jq -r '.exits[] | select(.name == "protocol-landing") | .id' "$(relay_path)")"
    run_proxy relay forward add --name protocol-forward --exit-id "$exit_id" --listen-ports 33000-33002 --network auto --address relay.example
    assert_equal 0 "$RUN_STATUS" "protocol range forward add"
    forward_id="$(jq -r '.forwards[0].id' "$(relay_path)")"
    [[ -f "${TEST_SYSTEM_ROOT}/run/last-nft.batch" ]] || fail "nft batch missing after forward add; output=${RUN_OUTPUT}; log=$(cat "$MOCK_LOG"); state=$(jq -c . "$(relay_path)")"
    assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'tcp dport 33000-33002' "TCP nft range"
    assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'udp dport 33000-33002' "UDP nft range"
    assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'dnat to 198.51.100.20:32200' "fixed destination port DNAT"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_forward4" ]] || fail "IPv4 managed nft table missing"
    [[ -f "${TEST_SYSTEM_ROOT}/etc/systemd/system/vpsctl-proxy-forward.service" ]] || fail "relay forward systemd service missing"
    [[ -f "${TEST_SYSTEM_ROOT}/usr/local/libexec/vpsctl-proxy-runtime/commands/service/proxy.sh" ]] || fail "relay forward runtime snapshot missing"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/enabled-vpsctl-proxy-forward.service" ]] || fail "relay forward service not enabled"

    run_proxy relay forward show --id "$forward_id" --uris
    assert_equal 0 "$RUN_STATUS" "expanded forward URIs"
    assert_equal 3 "$(grep -c '^ss://' <<<"$RUN_OUTPUT")" "expanded forward URI count"
    assert_contains "$RUN_OUTPUT" 'relay.example:33000' "first rewritten URI endpoint"
    assert_contains "$RUN_OUTPUT" 'relay.example:33002' "last rewritten URI endpoint"
    run_proxy subscription --core sing-box
    assert_equal 0 "$RUN_STATUS" "subscription with forward URIs"
    decoded="$(base64 -d <<<"$RUN_OUTPUT")"
    assert_equal 4 "$(grep -c '^ss://' <<<"$decoded")" "subscription ordinary plus forward URI count"
    assert_equal "$node_uri" "$(sed -n '1p' <<<"$decoded")" "ordinary node keeps subscription order"

    run_proxy relay exit add --name direct-landing --target 198.51.100.30 --target-port 443
    assert_equal 0 "$RUN_STATUS" "direct exit add"
    direct_id="$(jq -r '.exits[] | select(.name == "direct-landing") | .id' "$(relay_path)")"
    run_proxy relay forward add --name conflicting-forward --exit-id "$direct_id" --listen-ports 32200 --network tcp --address relay.example
    assert_equal 10 "$RUN_STATUS" "node port/network conflict rejection"

    run_proxy relay exit add --name ipv6-landing --target 2001:db8::20 --target-port 8443
    assert_equal 0 "$RUN_STATUS" "IPv6 direct exit add"
    ipv6_id="$(jq -r '.exits[] | select(.name == "ipv6-landing") | .id' "$(relay_path)")"
    run_proxy relay forward add --name ipv6-large-range --exit-id "$ipv6_id" --listen-ports 40000-50000 --network udp --address relay6.example
    assert_equal 0 "$RUN_STATUS" "IPv6 large-range forward"
    ipv6_forward_id="$(jq -r '.forwards[] | select(.name == "ipv6-large-range") | .id' "$(relay_path)")"
    assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'udp dport 40000-50000' "IPv6 large nft interval"
    assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'dnat to [2001:db8::20]:8443' "IPv6 fixed destination port DNAT"
    run_proxy relay forward delete --id "$ipv6_forward_id" --confirm-delete
    assert_equal 0 "$RUN_STATUS" "IPv6 forward delete"

    state_hash="$(sha256sum "$(relay_path)" | awk '{print $1}')"
    batch_hash="$(sha256sum "${TEST_SYSTEM_ROOT}/run/last-nft.batch" | awk '{print $1}')"
    touch "${TEST_SYSTEM_ROOT}/run/fail-nft-apply-once"
    run_proxy relay forward edit --id "$forward_id" --listen-ports 33100-33102
    [[ "$RUN_STATUS" != 0 ]] || fail "injected nft apply failure unexpectedly succeeded"
    assert_equal "$state_hash" "$(sha256sum "$(relay_path)" | awk '{print $1}')" "relay state rollback after nft failure"
    assert_equal "$batch_hash" "$(sha256sum "${TEST_SYSTEM_ROOT}/run/last-nft.batch" | awk '{print $1}')" "nft rollback after apply failure"

    rm -f -- "${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-proxy.example"
    run_proxy relay forward refresh --id "$forward_id"
    assert_equal 0 "$RUN_STATUS" "DNS failure retains last usable address"
    run_proxy relay status --json
    assert_equal 0 "$RUN_STATUS" "relay runtime status JSON"
    status_json="$RUN_OUTPUT"
    jq -e '.forward_runtime.degraded[] | select(.exit_id and .reason == "dns-failed" and .retained == true)' \
        >/dev/null <<<"$status_json" || fail "retained DNS degradation missing"

    cache_hash="$(sha256sum "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" | awk '{print $1}')"
    batch_hash="$(sha256sum "${TEST_SYSTEM_ROOT}/run/last-nft.batch" | awk '{print $1}')"
    printf '203.0.113.10\n' >"${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-proxy.example"
    run_proxy relay forward refresh --id "$forward_id"
    assert_equal 10 "$RUN_STATUS" "local destination loop rejection"
    assert_equal "$cache_hash" "$(sha256sum "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" | awk '{print $1}')" "loop rejection cache unchanged"
    assert_equal "$batch_hash" "$(sha256sum "${TEST_SYSTEM_ROOT}/run/last-nft.batch" | awk '{print $1}')" "loop rejection rules unchanged"

    run_proxy relay forward delete --id "$forward_id" --confirm-delete
    assert_equal 0 "$RUN_STATUS" "last forward delete"
    assert_equal 0 "$(jq -r '.forwards | length' "$(relay_path)")" "last forward state removed"
    [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_forward4" ]] || fail "managed IPv4 nft table not cleared"
    [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-systemd/enabled-vpsctl-proxy-forward.service" ]] || fail "relay service not disabled"
}

test_relay_forward_family_modes() {
    local exit_id forward_id ipv6_forward_id ipv6_exit_id ipv6_literal_forward_id dual_partial_id
    local state_hash cache_hash batch_hash batch list_json
    reset_root
    printf '198.51.100.80\n' >"${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-dual.example"
    printf '2001:db8::80\n' >"${TEST_SYSTEM_ROOT}/run/dns-ahostsv6-dual.example"
    run_proxy relay exit add --name dual-domain --target dual.example --target-port 443
    assert_equal 0 "$RUN_STATUS" "dual-stack domain exit"
    exit_id="$(jq -r '.exits[0].id' "$(relay_path)")"
    run_proxy relay forward add --name invalid-publish --exit-id "$exit_id" --listen-ports 34999 --network tcp \
        --family dual --address not:a
    assert_equal 2 "$RUN_STATUS" "colon-bearing non-IPv6 publish address refusal"
    assert_equal 0 "$(jq -r '.forwards | length' "$(relay_path)")" "invalid publish address leaves state unchanged"
    run_proxy relay forward add --name dual-forward --exit-id "$exit_id" --listen-ports 35000 --network tcp \
        --family dual --address publish.example
    assert_equal 0 "$RUN_STATUS" "dual-stack forward add"
    forward_id="$(jq -r '.forwards[0].id' "$(relay_path)")"
    assert_equal dual "$(jq -r '.forwards[0].family' "$(relay_path)")" "stored dual family"
    jq -e --arg id "$exit_id" '.exits[$id].ipv4 == "198.51.100.80" and .exits[$id].ipv6 == "2001:db8::80"' \
        "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" >/dev/null || fail "dual cache contains both families"
    batch="$(<"${TEST_SYSTEM_ROOT}/run/last-nft.batch")"
    assert_contains "$batch" 'dnat to 198.51.100.80:443' "dual IPv4 nft rule"
    assert_contains "$batch" 'dnat to [2001:db8::80]:443' "dual IPv6 nft rule"
    run_proxy relay forward list --json
    assert_equal 0 "$RUN_STATUS" "dual forward JSON list"
    list_json="$RUN_OUTPUT"
    jq -e '.forwards[0].family == "dual" and .forwards[0].publish_address_dns_managed_externally == true and
        (.forwards[0].publish_address_note | contains("DNS"))' >/dev/null <<<"$list_json" || fail "forward JSON family and publish note"

    # Legacy records remain valid and are surfaced with the effective default.
    jq 'del(.forwards[0].family)' "$(relay_path)" >"${TEST_TEMP}/legacy-relay.json"
    cp "${TEST_TEMP}/legacy-relay.json" "$(relay_path)"
    run_proxy relay forward list --json
    assert_equal 0 "$RUN_STATUS" "legacy forward family list"
    jq -e '.forwards[0].family == "dual"' >/dev/null <<<"$RUN_OUTPUT" || fail "legacy forward dual default"
    run_proxy relay forward show --id "$forward_id" --json
    assert_equal 0 "$RUN_STATUS" "legacy forward family detail JSON"
    jq -e '.forward.family == "dual" and .forward.publish_address_dns_managed_externally == true' \
        >/dev/null <<<"$RUN_OUTPUT" || fail "legacy forward detail defaults"

    run_proxy relay forward edit --id "$forward_id" --family ipv4
    assert_equal 0 "$RUN_STATUS" "switch shared exit to IPv4-only"
    assert_equal ipv4 "$(jq -r '.forwards[0].family' "$(relay_path)")" "normalized IPv4 family"
    jq -e --arg id "$exit_id" '.exits[$id].ipv4 == "198.51.100.80" and (.exits[$id] | has("ipv6") | not)' \
        "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" >/dev/null || fail "unused IPv6 cache not cleaned"
    batch="$(<"${TEST_SYSTEM_ROOT}/run/last-nft.batch")"
    assert_contains "$batch" 'dnat to 198.51.100.80:443' "IPv4-only nft rule"
    assert_not_contains "$batch" 'dnat to [2001:db8::80]:443' "IPv4-only excludes IPv6 nft rule"

    run_proxy relay forward add --name ipv6-shared --exit-id "$exit_id" --listen-ports 35001 --network tcp \
        --family ipv6 --address publish.example
    assert_equal 0 "$RUN_STATUS" "shared exit IPv6 forward"
    ipv6_forward_id="$(jq -r '.forwards[] | select(.name == "ipv6-shared") | .id' "$(relay_path)")"
    jq -e --arg id "$exit_id" '.exits[$id].ipv4 == "198.51.100.80" and .exits[$id].ipv6 == "2001:db8::80"' \
        "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" >/dev/null || fail "shared exit family union cache"
    batch="$(<"${TEST_SYSTEM_ROOT}/run/last-nft.batch")"
    assert_contains "$batch" 'tcp dport 35000' "shared IPv4 forward rule"
    assert_contains "$batch" 'tcp dport 35001' "shared IPv6 forward rule"

    run_proxy relay forward delete --id "$ipv6_forward_id" --confirm-delete
    assert_equal 0 "$RUN_STATUS" "shared IPv6 forward delete"
    jq -e --arg id "$exit_id" '.exits[$id].ipv4 == "198.51.100.80" and (.exits[$id] | has("ipv6") | not)' \
        "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" >/dev/null || fail "unreferenced shared IPv6 cache cleanup"
    rm -f -- "${TEST_SYSTEM_ROOT}/run/dns-ahostsv6-dual.example"
    state_hash="$(sha256sum "$(relay_path)" | awk '{print $1}')"
    run_proxy relay forward add --name missing-v6 --exit-id "$exit_id" --listen-ports 35002 --network tcp \
        --family ipv6 --address publish.example
    assert_equal 3 "$RUN_STATUS" "missing requested DNS family refusal"
    assert_equal "$state_hash" "$(sha256sum "$(relay_path)" | awk '{print $1}')" "missing family leaves state unchanged"

    run_proxy relay exit add --name literal-v6 --target 2001:db8::90 --target-port 8443
    assert_equal 0 "$RUN_STATUS" "literal IPv6 exit"
    ipv6_exit_id="$(jq -r '.exits[] | select(.name == "literal-v6") | .id' "$(relay_path)")"
    run_proxy relay forward add --name wrong-exit-family --exit-id "$ipv6_exit_id" --listen-ports 35003 --network tcp \
        --family ipv4 --address publish.example
    assert_equal 2 "$RUN_STATUS" "opposite literal exit family refusal"
    run_proxy relay forward add --name wrong-publish-family --exit-id "$ipv6_exit_id" --listen-ports 35003 --network tcp \
        --family ipv6 --address 192.0.2.30
    assert_equal 2 "$RUN_STATUS" "opposite literal publish family refusal"
    run_proxy relay forward add --name literal-v6-forward --exit-id "$ipv6_exit_id" --listen-ports 35003 --network tcp \
        --family ipv6 --address publish6.example
    assert_equal 0 "$RUN_STATUS" "IPv6-only literal forward"
    ipv6_literal_forward_id="$(jq -r '.forwards[] | select(.name == "literal-v6-forward") | .id' "$(relay_path)")"
    run_proxy relay forward show --id "$ipv6_literal_forward_id"
    assert_equal 0 "$RUN_STATUS" "domain publish forward detail"
    assert_contains "$RUN_OUTPUT" 'DNS 记录由用户负责' "domain publish responsibility note"

    run_proxy relay forward add --name partial-dual --exit-id "$ipv6_exit_id" --listen-ports 35004 --network tcp \
        --family dual --address publish6.example
    assert_equal 0 "$RUN_STATUS" "partial dual-stack literal target"
    dual_partial_id="$(jq -r '.forwards[] | select(.name == "partial-dual") | .id' "$(relay_path)")"
    [[ -n "$dual_partial_id" ]] || fail "partial dual forward missing"
    run_proxy relay status --json
    assert_equal 0 "$RUN_STATUS" "partial dual status"
    jq -e --arg id "$ipv6_exit_id" '.forward_runtime.partial_dual == true and
        (.forward_runtime.degraded[] |
        select(.exit_id == $id and .family == "ipv4" and .reason == "family-unavailable" and .retained == false))' \
        >/dev/null <<<"$RUN_OUTPUT" || fail "partial dual degradation marker"

    state_hash="$(sha256sum "$(relay_path)" | awk '{print $1}')"
    cache_hash="$(sha256sum "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" | awk '{print $1}')"
    batch_hash="$(sha256sum "${TEST_SYSTEM_ROOT}/run/last-nft.batch" | awk '{print $1}')"
    touch "${TEST_SYSTEM_ROOT}/run/fail-nft-list-tables"
    run_proxy relay forward refresh
    assert_equal 20 "$RUN_STATUS" "nft table enumeration failure aborts before replacement"
    rm -f -- "${TEST_SYSTEM_ROOT}/run/fail-nft-list-tables"
    assert_equal "$state_hash" "$(sha256sum "$(relay_path)" | awk '{print $1}')" "snapshot failure state hash"
    assert_equal "$cache_hash" "$(sha256sum "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" | awk '{print $1}')" "snapshot failure cache hash"
    assert_equal "$batch_hash" "$(sha256sum "${TEST_SYSTEM_ROOT}/run/last-nft.batch" | awk '{print $1}')" "snapshot failure nft hash"
}

test_relay_forward_service_lifecycle() {
    local exit_id forward_id
    reset_root
    run_proxy relay exit add --name lifecycle-direct --target 198.51.100.60 --target-port 8443
    assert_equal 0 "$RUN_STATUS" "lifecycle direct exit"
    exit_id="$(jq -r '.exits[0].id' "$(relay_path)")"
    touch "${TEST_SYSTEM_ROOT}/run/fail-service-enable"
    run_proxy relay forward add --name fail-start --exit-id "$exit_id" --listen-ports 34100 --network tcp --address relay.example
    [[ "$RUN_STATUS" != 0 ]] || fail "injected relay service start failure unexpectedly succeeded"
    rm -f -- "${TEST_SYSTEM_ROOT}/run/fail-service-enable"
    assert_equal 0 "$(jq -r '.forwards | length' "$(relay_path)")" "relay state rollback after service start failure"
    [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_forward4" ]] || fail "nft table survived failed first service start"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" ]] || fail "DNS cache survived failed first service start"

    run_proxy relay forward add --name lifecycle-forward --exit-id "$exit_id" --listen-ports 34100 --network tcp --address relay.example
    assert_equal 0 "$RUN_STATUS" "relay service start after rollback"
    forward_id="$(jq -r '.forwards[0].id' "$(relay_path)")"
    assert_file_contains "${TEST_SYSTEM_ROOT}/etc/systemd/system/vpsctl-proxy-forward.service" 'ExecStart=/usr/local/libexec/vpsctl-proxy-forward-refresh watch' "systemd DNS watcher"
    assert_file_contains "${TEST_SYSTEM_ROOT}/usr/local/libexec/vpsctl-proxy-forward-refresh" 'sleep 300' "five minute DNS refresh"
    [[ -f "${TEST_SYSTEM_ROOT}/usr/local/libexec/vpsctl-proxy-runtime/lib/ui.sh" ]] || fail "relay runtime UI dependency missing"
    run_proxy relay forward delete --id "$forward_id" --confirm-delete
    assert_equal 0 "$RUN_STATUS" "systemd relay last delete"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" ]] || fail "last delete retained DNS cache"
    run_proxy relay forward refresh
    assert_equal 0 "$RUN_STATUS" "empty relay refresh"
    [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_forward4" ]] || fail "empty refresh recreated managed nft table"

    reset_root
    VPSCTL_ENV_INIT=openrc run_proxy relay exit add --name openrc-direct --target 198.51.100.70 --target-port 9443
    assert_equal 0 "$RUN_STATUS" "OpenRC direct exit"
    exit_id="$(jq -r '.exits[0].id' "$(relay_path)")"
    VPSCTL_ENV_INIT=openrc run_proxy relay forward add --name openrc-forward --exit-id "$exit_id" --listen-ports 34200 --network udp --address relay.example
    assert_equal 0 "$RUN_STATUS" "OpenRC relay forward add"
    forward_id="$(jq -r '.forwards[0].id' "$(relay_path)")"
    assert_file_contains "${TEST_SYSTEM_ROOT}/etc/init.d/vpsctl-proxy-forward" 'command_args="watch"' "OpenRC DNS watcher"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-openrc/enabled-vpsctl-proxy-forward" ]] || fail "OpenRC relay service not enabled"
    VPSCTL_ENV_INIT=openrc run_proxy relay forward delete --id "$forward_id" --confirm-delete
    assert_equal 0 "$RUN_STATUS" "OpenRC relay last delete"
    [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-openrc/enabled-vpsctl-proxy-forward" ]] || fail "OpenRC relay service not disabled"
}

case "${VPSCTL_TEST_ONLY:-}" in
    core-release) test_core_release_channels; printf 'PASS: proxy core release tests\n'; exit 0 ;;
    node-ip-policy) test_node_ip_strategy_and_batch; printf 'PASS: node IP policy tests\n'; exit 0 ;;
    relay-state) test_relay_state_bindings_and_purge; printf 'PASS: relay state tests\n'; exit 0 ;;
    relay-xray) test_relay_xray_pending_and_validation; printf 'PASS: relay Xray tests\n'; exit 0 ;;
    relay-forward) test_relay_forwarding_subscription_and_rollback; printf 'PASS: relay forward tests\n'; exit 0 ;;
    relay-family) test_relay_forward_family_modes; printf 'PASS: relay forward family tests\n'; exit 0 ;;
    relay-service) test_relay_forward_service_lifecycle; printf 'PASS: relay service tests\n'; exit 0 ;;
esac

printf 'TEST: proxy arguments, dry-run and time\n'
test_arguments_dry_run_and_time
printf 'TEST: proxy core release channels\n'
test_core_release_channels
printf 'TEST: proxy dependency installation plans\n'
test_dependency_install_plans
printf 'TEST: proxy status, services and logs\n'
test_status_service_and_logs
printf 'TEST: proxy CRUD, pending and validation\n'
test_core_choice_crud_pending_and_validation
printf 'TEST: proxy core choice, ports and uninstall\n'
test_overlap_port_ambiguity_and_uninstall
printf 'TEST: proxy TLS certificate transactions\n'
test_tls_certificate_transaction
printf 'TEST: proxy managed TLS certificates\n'
test_tls_managed_certificate
printf 'TEST: proxy unified interactive API\n'
test_unified_interactive_api
printf 'TEST: proxy node IP strategy rendering and atomic batches\n'
test_node_ip_strategy_and_batch
printf 'TEST: proxy protocol renderer matrix\n'
test_protocol_matrix
printf 'TEST: proxy relay state, bindings and purge guards\n'
test_relay_state_bindings_and_purge
printf 'TEST: proxy relay Xray pending and validation\n'
test_relay_xray_pending_and_validation
printf 'TEST: proxy relay forwarding, subscriptions and rollback\n'
test_relay_forwarding_subscription_and_rollback
printf 'TEST: proxy relay forward address-family modes\n'
test_relay_forward_family_modes
printf 'TEST: proxy relay service lifecycle and failures\n'
test_relay_forward_service_lifecycle
printf 'PASS: service proxy tests\n'
