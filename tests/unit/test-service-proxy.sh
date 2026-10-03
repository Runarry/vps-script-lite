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
  start)
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/skip-service-start" ]] || exit 0
    touch "$state/active-${2}"
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-service-start" && ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-start-${2}" ]] || exit 20
    ;;
  restart)
    if [[ -e "${VPSCTL_SYSTEM_ROOT}/run/fail-service-restart-once" ]]; then
      rm -f "${VPSCTL_SYSTEM_ROOT}/run/fail-service-restart-once"
      exit 20
    fi
    touch "$state/active-${2}"
    ;;
  stop)
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-service-stop" ]] || exit 20
    rm -f "$state/active-${2}"
    ;;
  enable)
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/skip-service-enable" ]] || exit 0
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
case "${2:-}" in
  start|restart)
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/skip-service-start" ]] || exit 0
    touch "$state/active-${1}"
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-service-start" ]] || exit 20
    ;;
  stop)
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-service-stop" ]] || exit 20
    rm -f "$state/active-${1}"
    ;;
  status) [[ -f "$state/active-${1}" ]] ;;
esac'
make_mock rc-update '
printf "rc-update %s\n" "$*" >>"$MOCK_LOG"
state="${VPSCTL_SYSTEM_ROOT}/run/mock-openrc"; mkdir -p "$state"
case "${1:-}" in
  add)
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/skip-service-enable" ]] || exit 0
    touch "$state/enabled-${2}"
    [[ ! -e "${VPSCTL_SYSTEM_ROOT}/run/fail-service-enable" ]] || exit 20
    ;;
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
  for table in vpsctl_proxy_forward4 vpsctl_proxy_forward6 vpsctl_proxy_hy2_4 vpsctl_proxy_hy2_6; do
    family=ip; [[ "$table" != *6 ]] || family=ip6
    if [[ -f "$state/$family-$table" ]]; then
      printf "%s{\"table\":{\"family\":\"%s\",\"name\":\"%s\"}}" "$separator" "$family" "$table"; separator=,
    fi
  done
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
  for table in vpsctl_proxy_forward4 vpsctl_proxy_forward6 vpsctl_proxy_hy2_4 vpsctl_proxy_hy2_6; do
    family=ip; [[ "$table" != *6 ]] || family=ip6
    if grep -Fq "add table $family $table" "$batch" || grep -Fq "table $family $table {" "$batch"; then touch "$state/${family}-${table}"
    elif grep -Eq "(delete|destroy) table $family $table" "$batch"; then rm -f "$state/${family}-${table}"
    fi
  done
  exit 0
fi
exit 2'
make_mock ss '
[[ ! -f "${VPSCTL_SYSTEM_ROOT}/run/listening-port" ]] || printf "tcp LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n" "$(<"${VPSCTL_SYSTEM_ROOT}/run/listening-port")"
[[ ! -f "${VPSCTL_SYSTEM_ROOT}/run/listening-udp-port" ]] || printf "udp UNCONN 0 0 0.0.0.0:%s 0.0.0.0:*\n" "$(<"${VPSCTL_SYSTEM_ROOT}/run/listening-udp-port")"'
make_mock flock 'exit 0'
make_mock ufw '[[ "${1:-}" == status ]] || exit 99; printf "Status: inactive\n"'
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
    write_core_binary "$core" "/usr/bin/$core" "${2:-}"
    run_proxy install --core "$core"
    assert_equal 0 "$RUN_STATUS" "external $core install"
    jq -e '.owned == false' "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores/${core}.json" >/dev/null || fail "$core external ownership"
}

manifest_path() { printf '%s' "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/nodes.json"; }
relay_path() { printf '%s' "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay.json"; }
node_id_by_name() { jq -r --arg name "$1" '.nodes[] | select(.name == $name) | .id' "$(manifest_path)"; }

test_core_install_autostart() {
    local init core ownership state unit config service meta lkg before fault
    for init in systemd openrc; do
        export VPSCTL_ENV_INIT="$init"
        for core in sing-box xray; do
            unit="vpsctl-proxy-${core}"
            [[ "$init" != systemd ]] || unit+='.service'
            state="${TEST_SYSTEM_ROOT}/run/mock-${init}"
            config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/${core}/config.json"
            meta="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores/${core}.json"
            lkg="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/lkg/${core}"
            if [[ "$init" == systemd ]]; then
                service="${TEST_SYSTEM_ROOT}/etc/systemd/system/${unit}"
            else
                service="${TEST_SYSTEM_ROOT}/etc/init.d/${unit}"
            fi
            for ownership in owned external; do
                reset_root
                set_release_scenario default
                if [[ "$ownership" == external ]]; then
                    write_core_binary "$core"
                    before="$(sha256sum "${TEST_SYSTEM_ROOT}/usr/bin/${core}")"
                fi
                run_proxy install --core "$core"
                assert_equal 0 "$RUN_STATUS" "$init $ownership $core install"
                assert_contains "$RUN_OUTPUT" '已安装、启动并启用开机启动' "install success state"
                [[ -f "$state/active-$unit" && -f "$state/enabled-$unit" ]] || fail "$init $core install service defaults"
                [[ -f "$lkg/config.json" && -f "$lkg/core.json" && -f "$lkg/binary" ]] || fail "$init $core install LKG missing"
                cmp -s "$config" "$lkg/config.json" || fail "$core LKG config mismatch"
                if [[ "$ownership" == external ]]; then
                    assert_equal "$before" "$(sha256sum "${TEST_SYSTEM_ROOT}/usr/bin/${core}")" "external install modified binary"
                    jq -e '.owned == false' "$meta" >/dev/null || fail "external ownership changed"
                else
                    jq -e '.owned == true' "$meta" >/dev/null || fail "downloaded ownership changed"
                fi
                run_proxy stop --core "$core" --disable
                assert_equal 0 "$RUN_STATUS" "manual stop and disable"
                before="$(sha256sum "$config" "$meta" "$service")"
                : >"$MOCK_LOG"
                run_proxy install --core "$core"
                assert_equal 0 "$RUN_STATUS" "repeated $init $ownership $core install"
                assert_equal "$before" "$(sha256sum "$config" "$meta" "$service")" "repeated install changed files"
                [[ ! -e "$state/active-$unit" && ! -e "$state/enabled-$unit" ]] || fail "repeated install undid manual stop/disable"
                assert_not_contains "$(<"$MOCK_LOG")" 'curl ' "repeated install downloaded"

                for fault in fail-service-start fail-service-enable skip-service-start skip-service-enable; do
                    reset_root
                    set_release_scenario default
                    if [[ "$ownership" == external ]]; then
                        write_core_binary "$core"
                        before="$(sha256sum "${TEST_SYSTEM_ROOT}/usr/bin/${core}")"
                    fi
                    touch "${TEST_SYSTEM_ROOT}/run/$fault"
                    run_proxy install --core "$core"
                    assert_equal 20 "$RUN_STATUS" "$init $ownership $core $fault rollback"
                    [[ ! -e "$state/active-$unit" && ! -e "$state/enabled-$unit" ]] || fail "$fault leaked service state"
                    [[ ! -e "$config" && ! -e "$meta" && ! -e "$service" && ! -e "$lkg" ]] || fail "$fault leaked install files"
                    if [[ "$ownership" == external ]]; then
                        assert_equal "$before" "$(sha256sum "${TEST_SYSTEM_ROOT}/usr/bin/${core}")" "$fault removed external binary"
                    else
                        [[ ! -e "${TEST_SYSTEM_ROOT}/usr/local/bin/${core}" ]] || fail "$fault leaked owned binary"
                    fi
                done
            done

            reset_root
            write_core_binary "$core"
            touch "${TEST_SYSTEM_ROOT}/run/fail-service-enable" "${TEST_SYSTEM_ROOT}/run/fail-service-stop"
            run_proxy install --core "$core"
            assert_equal 30 "$RUN_STATUS" "$init $core incomplete service rollback"
            assert_contains "$RUN_OUTPUT" '回滚不完整' "incomplete rollback message"

            reset_root
            write_core_binary "$core"
            mkdir -p "$(dirname -- "$lkg")"
            touch "$lkg"
            run_proxy install --core "$core"
            assert_equal 30 "$RUN_STATUS" "$init $core LKG failure"
            assert_contains "$RUN_OUTPUT" '保存 LKG 失败' "LKG partial success message"
            [[ -f "$meta" && -f "$state/active-$unit" && -f "$state/enabled-$unit" ]] || fail "LKG failure discarded running install"
        done
    done
    export VPSCTL_ENV_INIT=systemd

    # Recover a retained managed service and config, including its prior state.
    reset_root
    install_external xray
    run_proxy stop --core xray --disable
    assert_equal 0 "$RUN_STATUS" "retained-service stop"
    config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json"
    service="${TEST_SYSTEM_ROOT}/etc/systemd/system/vpsctl-proxy-xray.service"
    meta="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores/xray.json"
    printf '\n# retained definition\n' >>"$service"
    printf '{"retained":true}\n' >"$config"
    before="$(sha256sum "$service" "$config" "${TEST_SYSTEM_ROOT}/usr/bin/xray")"
    rm -f -- "$meta"
    touch "${TEST_SYSTEM_ROOT}/run/fail-service-enable"
    run_proxy install --core xray
    assert_equal 20 "$RUN_STATUS" "retained stopped service rollback"
    assert_equal "$before" "$(sha256sum "$service" "$config" "${TEST_SYSTEM_ROOT}/usr/bin/xray")" "retained service file restore"
    [[ ! -e "$meta" ]] || fail "retained install failure kept metadata"
    state="${TEST_SYSTEM_ROOT}/run/mock-systemd"
    touch "$state/active-vpsctl-proxy-xray.service" "$state/enabled-vpsctl-proxy-xray.service"
    run_proxy install --core xray
    assert_equal 20 "$RUN_STATUS" "retained active service rollback"
    assert_equal "$before" "$(sha256sum "$service" "$config" "${TEST_SYSTEM_ROOT}/usr/bin/xray")" "retained active file restore"
    [[ -f "$state/active-vpsctl-proxy-xray.service" && -f "$state/enabled-vpsctl-proxy-xray.service" ]] || fail "retained service state not restored"

    reset_root
    set_release_scenario default
    run_proxy install --core all
    assert_equal 0 "$RUN_STATUS" "all-core autostart install"
    for core in sing-box xray; do
        [[ -f "$state/active-vpsctl-proxy-${core}.service" && -f "$state/enabled-vpsctl-proxy-${core}.service" ]] || fail "$core all install service defaults"
    done
    reset_root
    install_external sing-box
    run_proxy stop --core sing-box --disable
    assert_equal 0 "$RUN_STATUS" "stop registered core before mixed all install"
    write_core_binary xray
    run_proxy install --core all
    assert_equal 0 "$RUN_STATUS" "all install with registered and new cores"
    [[ ! -e "$state/active-vpsctl-proxy-sing-box.service" && ! -e "$state/enabled-vpsctl-proxy-sing-box.service" ]] || fail "all install changed registered core state"
    [[ -f "$state/active-vpsctl-proxy-xray.service" && -f "$state/enabled-vpsctl-proxy-xray.service" ]] || fail "all install skipped new core activation"
    reset_root
    set_release_scenario default
    touch "${TEST_SYSTEM_ROOT}/run/fail-start-vpsctl-proxy-sing-box.service"
    run_proxy install --core all
    assert_equal 30 "$RUN_STATUS" "all install partial failure"
    [[ ! -e "$state/active-vpsctl-proxy-sing-box.service" && ! -e "$state/enabled-vpsctl-proxy-sing-box.service" ]] || fail "failed all install core state leaked"
    [[ -f "$state/active-vpsctl-proxy-xray.service" && -f "$state/enabled-vpsctl-proxy-xray.service" ]] || fail "all install did not continue after first failure"
}

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
    assert_contains "$RUN_OUTPUT" 'systemctl start vpsctl-proxy-sing-box.service' "install dry-run start plan"
    assert_contains "$RUN_OUTPUT" 'systemctl enable vpsctl-proxy-sing-box.service' "install dry-run enable plan"
    assert_not_contains "$(<"$MOCK_LOG")" 'systemctl start ' "install dry-run started service"
    assert_not_contains "$(<"$MOCK_LOG")" 'systemctl enable ' "install dry-run enabled service"
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
    assert_not_contains "$(<"$MOCK_LOG")" 'systemctl restart ' "core update must preserve explicit restart contract"
    assert_not_contains "$(<"$MOCK_LOG")" 'systemctl start ' "core update must not start services"

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
        assert_contains "$RUN_OUTPUT" "拒绝生成的配置" "$core prerelease config compatibility error"
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

    RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --dry-run install --core sing-box
    assert_equal 0 "$RUN_STATUS" "sing-box dependency dry-run"
    assert_contains "$RUN_OUTPUT" "jq" "sing-box jq package plan"
    assert_contains "$RUN_OUTPUT" "curl" "sing-box curl package plan"
    assert_contains "$RUN_OUTPUT" "coreutils" "sing-box checksum package plan"
    assert_contains "$RUN_OUTPUT" "tar" "sing-box archive package plan"
    assert_contains "$RUN_OUTPUT" "apt-get update" "sing-box dependency update command"
    assert_contains "$RUN_OUTPUT" "apt-get install -y --no-install-recommends" "sing-box dependency install command"
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

    RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --dry-run node add \
        --profile vless-ws-tls --core sing-box --port 19991 --address proxy.example \
        --sni proxy.example --path /dependency-plan
    assert_equal 0 "$RUN_STATUS" "node add dependency dry-run"
    assert_contains "$RUN_OUTPUT" "jq" "node add jq package plan"
    assert_contains "$RUN_OUTPUT" "openssl" "node add openssl package plan"
    assert_contains "$RUN_OUTPUT" "iproute2" "node add ss package plan"
    assert_contains "$RUN_OUTPUT" "coreutils" "node add certificate checksum package plan"
    assert_contains "$RUN_OUTPUT" "安装依赖后重跑完整计划" "node add dependency rerun message"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy" ]] || fail "node dependency plan wrote proxy state"

    RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --dry-run subscription --core all
    assert_equal 0 "$RUN_STATUS" "subscription dependency dry-run"
    assert_contains "$RUN_OUTPUT" "jq" "subscription jq package plan"
    assert_contains "$RUN_OUTPUT" "coreutils" "subscription base64 and tr package plan"
    assert_contains "$RUN_OUTPUT" "安装依赖后重跑完整计划" "subscription dependency rerun message"

    VPSCTL_ENV_PACKAGE_MANAGER=unsupported RUN_PROXY_PATH="$TEST_DEP_BIN" run_proxy --dry-run status
    assert_equal 2 "$RUN_STATUS" "unknown package manager"
    assert_contains "$RUN_OUTPUT" "无效的软件包管理器" "unknown package manager message"
    assert_not_contains "$(<"$MOCK_LOG")" "apt-get " "dependency plans must not execute package manager"
    assert_not_contains "$(<"$MOCK_LOG")" "curl " "dependency plans must not download cores"
}

test_status_service_and_logs() {
    reset_root
    install_external sing-box
    install_external xray
    run_proxy stop --core sing-box --disable
    assert_equal 0 "$RUN_STATUS" "stop sing-box before explicit service lifecycle checks"
    run_proxy stop --core xray --disable
    assert_equal 0 "$RUN_STATUS" "stop Xray before explicit service lifecycle checks"
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
    run_proxy stop --core xray --disable
    assert_equal 0 "$RUN_STATUS" "stop OpenRC Xray before explicit start"
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

# Runtime-loaded list calls the jq failure override below.
# shellcheck disable=SC1091,SC2317
test_node_list_bindings_and_text() (
    local first second third expected invalid format failure=""

    reset_root
    run_proxy node list
    assert_equal 0 "$RUN_STATUS" "node list without manifest"
    assert_equal '当前没有受管节点。' "$RUN_OUTPUT" "missing manifest text"
    run_proxy node list --json
    assert_equal 0 "$RUN_STATUS" "JSON node list without manifest"
    assert_equal '{"schema_version":1,"total":0,"nodes":[]}' "$RUN_OUTPUT" "missing manifest JSON"

    mkdir -p "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy"
    jq -n '{schema_version:1,nodes:[
        {id:"node-0000000000000001",core:"sing-box",profile:"shadowsocks-aes-256-gcm",
         name:"\u0000  第一\tsecond\\path\nmiddle\n\u0000\n",listen:"\u0000::\t \\bind\n\n",
         port:18011,address:"\u0000  proxy\t\\host\nline\n\u0000\n",ip_strategy:"prefer_ipv4",
         credentials:{},tls:{},transport:{},options:{}},
        {id:"node-0000000000000002",core:"xray",profile:"\u0000unknown\tprofile\\path\npart\n\u0000\n",
         name:"\u0000\n\n",listen:"\u0000",port:18012,address:"\n\n",
         credentials:{},tls:{},transport:{},options:{}},
        {id:"node-0000000000000003",core:"xray",profile:"vless-reality-vision",name:"plain-three",
         listen:"::",port:18013,address:"proxy.example",ip_strategy:"ipv6_only",
         credentials:{},tls:{},transport:{},options:{}}
    ]}' >"$(manifest_path)"
    # Listing only needs node IDs. Unrelated relay data, duplicate bindings and
    # IDs not present in the manifest must not invoke the full relay validator.
    printf '%s\n' '{"exits":[{"uri":"unused-invalid-uri"}],"forwards":"unused","bindings":[{"node_id":"node-0000000000000001"},{"node_id":"node-0000000000000001"},{"node_id":"node-ffffffffffffffff"}]}' >"$(relay_path)"

    first="$(printf '[1] %s\n    ID：node-0000000000000001  内核：sing-box  配置：Shadowsocks AES-256-GCM\n    监听：%s:18011  连接地址：%s\n    IP 策略：优先 IPv4（已绑定中转，暂不生效）\n' \
        $'  第一\tsecond\\path\nmiddle' $'::\t \\bind' $'  proxy\t\\host\nline')"
    second="$(printf '[2] \n    ID：node-0000000000000002  内核：Xray  配置：%s\n    监听：:18012  连接地址：\n    IP 策略：自动\n' \
        $'unknown\tprofile\\path\npart')"
    third='[3] plain-three
    ID：node-0000000000000003  内核：Xray  配置：VLESS + REALITY + XTLS Vision
    监听：:::18013  连接地址：proxy.example
    IP 策略：仅 IPv6
    REALITY 防偷：关闭'
    expected="$(printf '%s\n%s\n%s\n当前筛选：3 个；节点总数：3 个\n' "$first" "$second" "$third")"
    run_proxy node list
    assert_equal 0 "$RUN_STATUS" "complex node text list"
    assert_equal "$expected" "$RUN_OUTPUT" "text field boundaries and command substitution compatibility"
    run_proxy node list --core sing-box
    assert_equal 0 "$RUN_STATUS" "complex filtered node text list"
    assert_equal "$(printf '%s\n当前筛选：1 个；节点总数：3 个\n' "$first")" "$RUN_OUTPUT" "filtered text keeps full total"
    run_proxy node list --core xray
    assert_equal 0 "$RUN_STATUS" "Xray filtered node text list"
    assert_contains "$RUN_OUTPUT" $'[1] \n    ID：node-0000000000000002' "filtered list keeps empty values and order"
    assert_contains "$RUN_OUTPUT" '[2] plain-three' "filtered list restarts numbering"
    assert_contains "$RUN_OUTPUT" '当前筛选：2 个；节点总数：3 个' "Xray filtered count"

    run_proxy node list --json
    assert_equal 0 "$RUN_STATUS" "complex node JSON list"
    jq -e '
        .total == 3 and (.nodes | length) == 3 and
        .nodes[0].name == "\u0000  第一\tsecond\\path\nmiddle\n\u0000\n" and
        .nodes[0].relay_bound == true and .nodes[0].ip_strategy_effective == false and
        .nodes[0].ip_strategy_status == "relay_bound" and
        .nodes[1].ip_strategy == "auto" and .nodes[1].relay_bound == false and
        .nodes[2].reality_anti_relay == false and .nodes[2].ip_strategy_effective == true
    ' <<<"$RUN_OUTPUT" >/dev/null || fail "JSON list keeps raw names and binding annotations"
    run_proxy node list --core sing-box --json
    assert_equal 0 "$RUN_STATUS" "filtered node JSON list"
    jq -e '.total == 1 and (.nodes | length) == 1 and .nodes[0].id == "node-0000000000000001"' \
        <<<"$RUN_OUTPUT" >/dev/null || fail "JSON list filtered total"

    cp "$(manifest_path)" "${TEST_TEMP}/list-manifest.json"
    jq '.nodes[0].core = "xray"' "$(manifest_path)" >"${TEST_TEMP}/list-xray-only.json"
    cp "${TEST_TEMP}/list-xray-only.json" "$(manifest_path)"
    run_proxy node list --core sing-box
    assert_equal 0 "$RUN_STATUS" "empty text filter"
    assert_equal '当前筛选：0 个；节点总数：3 个' "$RUN_OUTPUT" "empty filter keeps full total"
    run_proxy node list --core sing-box --json
    assert_equal 0 "$RUN_STATUS" "empty JSON filter"
    jq -e '.total == 0 and .nodes == []' <<<"$RUN_OUTPUT" >/dev/null || fail "empty JSON filter"
    cp "${TEST_TEMP}/list-manifest.json" "$(manifest_path)"

    rm -f -- "$(relay_path)"
    run_proxy node list
    assert_equal 0 "$RUN_STATUS" "text list without relay state"
    assert_equal "${expected/'（已绑定中转，暂不生效）'/}" "$RUN_OUTPUT" "missing relay state leaves policy active"
    run_proxy node list --json
    assert_equal 0 "$RUN_STATUS" "JSON list without relay state"
    jq -e 'all(.nodes[]; .relay_bound == false and .ip_strategy_effective == true)' \
        <<<"$RUN_OUTPUT" >/dev/null || fail "missing relay state JSON annotations"

    for invalid in '' '{' '[]' '{}' '{"bindings":null}' '{"bindings":{}}' \
        '{"bindings":[17]}' '{"bindings":[{}]}' '{"bindings":[{"node_id":17}]}' \
        '{"bindings":[{"node_id":"node-bad"}]}' $'{"bindings":[]}\n{"bindings":[]}'; do
        printf '%s\n' "$invalid" >"$(relay_path)"
        for format in text json; do
            if [[ "$format" == json ]]; then run_proxy node list --json; else run_proxy node list; fi
            assert_equal 10 "$RUN_STATUS" "$format rejects invalid relay binding state"
            assert_contains "$RUN_OUTPUT" '中转状态的节点绑定格式校验失败' "$format invalid binding message"
            assert_not_contains "$RUN_OUTPUT" '当前筛选：' "$format invalid state has no success totals"
        done
    done
    rm -f -- "$(relay_path)"
    mkdir "$(relay_path)"
    for format in text json; do
        if [[ "$format" == json ]]; then run_proxy node list --json; else run_proxy node list; fi
        assert_equal 3 "$RUN_STATUS" "$format rejects relay directory"
        assert_contains "$RUN_OUTPUT" '可读普通文件' "$format relay directory message"
    done
    rmdir "$(relay_path)"
    ln -s "${TEST_TEMP}/missing-relay.json" "$(relay_path)"
    for format in text json; do
        if [[ "$format" == json ]]; then run_proxy node list --json; else run_proxy node list; fi
        assert_equal 3 "$RUN_STATUS" "$format rejects dangling relay symlink"
    done
    rm -f -- "$(relay_path)"
    printf '{"bindings":[]}\n' >"$(relay_path)"

    source "${TEST_ROOT}/lib/command.sh"
    vps_cmd_init "proxy node list tests" "$TEST_ROOT"
    source "${TEST_ROOT}/commands/service/proxy/common.sh"
    source "${TEST_ROOT}/commands/service/proxy/protocols-sing-box.sh"
    source "${TEST_ROOT}/commands/service/proxy/protocols-xray.sh"
    source "${TEST_ROOT}/commands/service/proxy/nodes.sh"
    source "${TEST_ROOT}/commands/service/proxy/relay.sh"
    proxy_common_init
    proxy_relay_init
    jq() {
        if [[ "$failure" == read && "${1:-}" == -ces ]]; then return 2; fi
        "${TEST_FAKE_BIN}/jq" "$@" || return $?
        # Emit a complete valid batch before failing to prove that mapfile's
        # successful read cannot hide the producer's nonzero exit status.
        if [[ "$failure" == stream && "${1:-}" == -j ]]; then return 42; fi
        return 0
    }
    for failure in read stream; do
        if RUN_OUTPUT="$(proxy_node_list 2>&1)"; then RUN_STATUS=0; else RUN_STATUS=$?; fi
        if [[ "$failure" == read ]]; then
            assert_equal 3 "$RUN_STATUS" "relay read failure"
            assert_contains "$RUN_OUTPUT" '无法读取中转状态' "relay read failure message"
        else
            assert_equal 10 "$RUN_STATUS" "node list producer failure"
            assert_contains "$RUN_OUTPUT" '无法读取节点列表' "node list producer failure message"
        fi
        assert_not_contains "$RUN_OUTPUT" '[1]' "$failure failure has no partial node output"
        assert_not_contains "$RUN_OUTPUT" '当前筛选：' "$failure failure has no success totals"
    done
)

test_core_choice_crud_pending_and_validation() {
    reset_root
    install_external xray
    run_proxy stop --core xray
    assert_equal 0 "$RUN_STATUS" "stop Xray before inactive CRUD checks"
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
    : >"$MOCK_LOG"
    run_proxy restart --core xray
    assert_equal 3 "$RUN_STATUS" "restart confirmation"
    assert_not_contains "$(<"$MOCK_LOG")" "restart vpsctl-proxy-xray.service" "unconfirmed restart must not restart service"
    run_proxy --yes restart --core xray
    assert_equal 0 "$RUN_STATUS" "--yes authorizes explicit restart"
    assert_file_contains "$MOCK_LOG" "restart vpsctl-proxy-xray.service" "--yes restarts service"
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
    : >"$MOCK_LOG"
    run_proxy --yes restart --core xray
    assert_equal 10 "$RUN_STATUS" "--yes restart preserves binary config validation"
    assert_not_contains "$(<"$MOCK_LOG")" "restart vpsctl-proxy-xray.service" "invalid config must not restart service"
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
    run_proxy --yes update --core sing-box
    assert_equal 3 "$RUN_STATUS" "--yes must not authorize external binary update"
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
    run_proxy --yes uninstall --core sing-box --purge
    assert_equal 3 "$RUN_STATUS" "--yes must not authorize core purge"
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

    (
        local interactive=1 reply expected_steps
        local restart_steps="${TEST_TEMP}/restart.steps" restart_output="${TEST_TEMP}/restart.output"
        vps_cmd_is_interactive() { [[ "$interactive" == 1 ]]; }
        proxy_require_platform() { return 0; }
        proxy_ensure_mutation_tools() { return 0; }
        _proxy_core_require_registered() { return 0; }
        vps_cmd_lock() { printf 'lock\n' >>"$restart_steps"; }
        vps_cmd_unlock() { return 0; }
        _proxy_core_validate_current_config() { printf 'validate\n' >>"$restart_steps"; }
        _proxy_core_restart_locked() { printf 'restart\n' >>"$restart_steps"; }
        expected_steps=$'lock\nvalidate\nrestart'
        for reply in n y; do
            : >"$restart_steps"
            status=0
            proxy_core_restart xray <<<"$reply" >"$restart_output" 2>&1 || status=$?
            assert_equal 0 "$status" "interactive restart accepts ordinary y/n"
            output="$(<"$restart_output")"
            assert_equal 1 "$(grep -o '输入 y 确认' <<<"$output" | wc -l | tr -d ' ')" "restart prompts once"
            assert_not_contains "$output" "RESTART-XRAY" "restart does not require a token"
            if [[ "$reply" == y ]]; then
                assert_equal "$expected_steps" "$(<"$restart_steps")" "confirmed restart retains validation before restart"
            else
                assert_equal "" "$(<"$restart_steps")" "cancelled restart does not lock, recover, validate or restart"
            fi
        done
        : >"$restart_steps"
        status=0
        proxy_core_restart xray </dev/null >"$restart_output" 2>&1 || status=$?
        assert_equal 130 "$status" "restart EOF cancellation"
        assert_equal "" "$(<"$restart_steps")" "restart EOF has no mutation"

        for interactive in 0 1; do
            : >"$restart_steps"
            VPSCTL_ASSUME_YES=1
            proxy_core_restart xray </dev/null >"$restart_output" 2>&1 || fail "--yes restart rejected"
            assert_equal "$expected_steps" "$(<"$restart_steps")" "--yes restart retains validation"
            assert_not_contains "$(<"$restart_output")" "输入 y 确认" "--yes restart does not prompt"
            : >"$restart_steps"
            VPSCTL_ASSUME_YES=0
            proxy_core_restart xray --confirm-disruptive </dev/null >"$restart_output" 2>&1 || fail "explicit restart authorization rejected"
            assert_equal "$expected_steps" "$(<"$restart_steps")" "explicit restart authorization retains validation"
            assert_not_contains "$(<"$restart_output")" "输入 y 确认" "explicit restart authorization does not prompt"
        done
        interactive=0
        : >"$restart_steps"
        status=0
        proxy_core_restart xray </dev/null >"$restart_output" 2>&1 || status=$?
        assert_equal 3 "$status" "noninteractive restart requires authorization"
        assert_equal "" "$(<"$restart_steps")" "unauthorized restart has no mutation"
    )

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
    assert_equal "" "$(proxy_lifecycle_candidates start 1)" "fresh installs are already active"
    run_proxy stop --core sing-box
    assert_equal 0 "$RUN_STATUS" "stop sing-box for lifecycle candidate checks"
    run_proxy stop --core xray
    assert_equal 0 "$RUN_STATUS" "stop Xray for lifecycle candidate checks"
    assert_equal $'sing-box\nxray' "$(proxy_lifecycle_candidates start 1)" "start candidates are inactive cores"
    touch "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-sing-box.service"
    assert_equal xray "$(proxy_lifecycle_candidates start 1)" "active core filtered from start"
    assert_equal sing-box "$(proxy_lifecycle_candidates stop 1)" "stop candidates are active cores"
    assert_equal sing-box "$(proxy_lifecycle_candidates restart 1)" "restart candidates are active cores"
    PROXY_INTERACTIVE=1
    selected="$(proxy_choose_core_for_profile vless-tcp "" 2>"$guided_stderr" </dev/null)"
    assert_equal sing-box "$selected" "unique compatible sing-box selects without confirmation"
    assert_file_contains "$guided_stderr" "自动使用唯一已安装且兼容的内核：sing-box" "automatic core selection info uses stderr"
    assert_not_contains "$(<"$guided_stderr")" "输入 y 确认" "unique compatible core does not prompt"
    selected="$(proxy_choose_core_for_profile vless-grpc-reality "" 2>"$guided_stderr" </dev/null)"
    assert_equal xray "$selected" "unique compatible Xray selects without confirmation"
    selected="$(proxy_choose_core_for_profile shadowsocks-aes-256-gcm "" 2>"$guided_stderr" <<<2)"
    assert_equal xray "$selected" "multiple compatible installed cores still require selection"
    assert_file_contains "$guided_stderr" "请选择运行" "multiple compatible core selector remains"
    PROXY_INTERACTIVE=0
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
    status=0
    proxy_choose_core_for_profile vless-tcp "" 2>"$guided_stderr" <<<n >/dev/null || status=$?
    assert_equal 130 "$status" "missing unique compatible core still requires install confirmation"
    assert_equal "" "$(<"${TEST_SYSTEM_ROOT}/run/stub-install.log")" "declined core install has no mutation"
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

    output="$(proxy_node_add --profile hysteria2 --port 19402 --address proxy.example <<< $'\n\n2\n\n\n\n\n2\n123\n456\n\n\n' 2>&1)"
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

# Runtime-loaded validation calls the function overrides below.
# shellcheck disable=SC1091,SC2317
test_profile_membership_pipe_consumption() (
    local status=0

    reset_root
    # Load the real node validation path, then make its supported-core producer
    # exceed a pipe buffer after emitting the requested core. A grep -q consumer
    # closes early and deterministically gives the producer SIGPIPE under pipefail.
    source "${TEST_ROOT}/lib/command.sh"
    vps_cmd_init "proxy membership tests" "$TEST_ROOT"
    source "${TEST_ROOT}/commands/service/proxy/common.sh"
    source "${TEST_ROOT}/commands/service/proxy/protocols-sing-box.sh"
    source "${TEST_ROOT}/commands/service/proxy/protocols-xray.sh"
    source "${TEST_ROOT}/commands/service/proxy/nodes.sh"

    proxy_profile_cores() {
        local index
        printf 'sing-box\n'
        for ((index = 0; index < 20000; index += 1)); do
            printf 'xray\n'
        done
    }
    vps_cmd_require_root() { return 77; }

    proxy_node_add --profile vless-grpc-tls --core sing-box \
        --name pipe-consumption --port 35099 --address pipe.example \
        --sni pipe.example --service-name pipe >/dev/null 2>&1 || status=$?
    assert_equal 77 "$status" "profile membership consumes complete producer output"
)

test_protocol_matrix() {
    reset_root
    write_core_binary sing-box
    write_core_binary xray
    mkdir -p "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores" "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy" "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy"
    local core logical version
    for core in sing-box xray; do
        logical="/usr/bin/$core"
        case "$core" in sing-box) version=1.14.0 ;; xray) version=26.3.27 ;; esac
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
    source "${TEST_ROOT}/commands/service/proxy/relay.sh"
    source "${TEST_ROOT}/commands/service/proxy/core.sh"
    proxy_common_init
    proxy_relay_init

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
        [vless-xhttp-reality]='VLESS + XHTTP + REALITY'
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
                if [[ "$core" == sing-box ]]; then
                    jq -e '.[0].up_mbps == 100 and .[0].down_mbps == 200' >/dev/null <<<"$rendered" || fail "sing-box hysteria2 bandwidth renderer fields"
                else
                    jq -e '.[0].streamSettings.finalmask.quicParams |
                        .brutalUp == "100000000" and .brutalDown == "200000000"' >/dev/null <<<"$rendered" || fail "Xray hysteria2 decimal Mbps renderer fields"
                fi
            fi
            [[ -n "$uri" ]] || fail "$profile/$core empty URI"
            descriptor="$(proxy_relay_uri_parse "$uri" "$profile")" || fail "$profile/$core relay URI parse"
            assert_equal "$profile" "$(jq -r '.profile' <<<"$descriptor")" "$profile/$core parsed profile"
            jq -e --arg core "$core" '.compatible_cores | index($core) != null' >/dev/null <<<"$descriptor" || fail "$profile/$core parsed core mapping"
            relay_exit="$(jq -cn --arg id "exit-0000000000000001" --arg name matrix --arg core "$core" \
                --arg profile "$profile" --arg uri "$uri" --argjson descriptor "$descriptor" \
                '{id:$id,name:$name,type:"protocol",core:$core,profile:$profile,uri:$uri,descriptor:$descriptor,
                  endpoint:$descriptor.endpoint,network_hint:$descriptor.network_hint}')"
            if [[ "$core" == sing-box && "$(jq -r '.tls.mode == "tls" and .tls.certificate_sha256 != ""' <<<"$descriptor")" == true ]]; then
                relay_exit="$(proxy_relay_apply_client_options "$relay_exit" "$cert_dir/cert.pem")" || fail "$profile/$core relay certificate migration"
            fi
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
    assert_equal 21 "$profile_count" "unique profile count"
    assert_equal 15 "$sb_count" "sing-box profile count"
    assert_equal 13 "$xray_count" "Xray profile count"
    assert_equal 7 "$overlap_count" "shared profile count"
    assert_equal 8 "$sb_only_count" "sing-box-only profile count"
    assert_equal 6 "$xray_only_count" "Xray-only profile count"
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

test_relay_forward_conflicts() (
    local manifest="${TEST_TEMP}/conflicts-relay.json" nodes="${TEST_TEMP}/conflicts-nodes.json"
    local base="${TEST_TEMP}/conflicts-base.json" calls="${TEST_TEMP}/conflicts-jq.log"
    local first second expected hint source profile profile_json node_id failure='' read_count=0 size
    source "${TEST_ROOT}/commands/service/proxy/relay-forward.sh"
    vps_cmd_error() { printf '%s\n' "$*" >&2; }
    jq() {
        local file="${*: -1}"
        printf '%s\n' "$file" >>"$calls"
        if [[ "$failure" == forward-short && "$file" == "$manifest" || "$failure" == node-short && "$file" == "$nodes" ]]; then
            printf 'incomplete\0'
            return 0
        fi
        if [[ "$failure" == forward-partial && "$file" == "$manifest" || "$failure" == node-partial && "$file" == "$nodes" ]]; then
            printf 'incomplete\0'
            return 42
        fi
        "$REAL_JQ" "$@" || return $?
        # A successful read of complete records must not hide producer failure.
        if [[ "$failure" == forward-stream && "$file" == "$manifest" || "$failure" == node-stream && "$file" == "$nodes" ]]; then return 42; fi
        return 0
    }
    mapfile() {
        read_count=$((read_count + 1))
        builtin mapfile "$@" || return $?
        [[ "$failure" != "read-$read_count" ]]
    }
    check_conflicts() {
        local expected_status="$1" expected_output="$2" description="$3" expected_calls="${4:-2}"
        : >"$calls"
        read_count=0
        if RUN_OUTPUT="$(proxy_relay_forward_validate_conflicts "$manifest" "$nodes" 2>&1)"; then RUN_STATUS=0; else RUN_STATUS=$?; fi
        assert_equal "$expected_status" "$RUN_STATUS" "$description status"
        assert_equal "$expected_output" "$RUN_OUTPUT" "$description diagnostic"
        assert_equal "$expected_calls" "$(wc -l <"$calls")" "$description jq count"
    }
    cat >"$base" <<'JSON'
{"exits":[{"id":"exit","protocol":{"network_hint":"tcp"}}],"forwards":[
{"id":"F0","exit_id":"exit","listen_port_start":20000,"listen_port_end":20010,"network":"tcp"},
{"id":"F1","exit_id":"exit","listen_port_start":20010,"listen_port_end":20020,"network":"tcp"},
{"id":"F2","exit_id":"exit","listen_port_start":20010,"listen_port_end":20020,"network":"tcp"}]}
JSON
    printf '{"nodes":[]}\n' >"$nodes"
    while IFS=' ' read -r first second expected; do
        "$REAL_JQ" --arg first "$first" --arg second "$second" '
            .forwards = .forwards[:2] | .forwards[0].network = $first | .forwards[1].network = $second
        ' "$base" >"$manifest"
        if [[ "$expected" == 10 ]]; then
            check_conflicts 10 '转发 F0 与 F1 的端口区间及网络相交' "$first/$second shared endpoint" 1
        else
            check_conflicts 0 '' "$first/$second shared endpoint"
        fi
    done <<'CASES'
tcp tcp 10
tcp udp 0
tcp both 10
udp tcp 0
udp udp 10
udp both 10
both tcp 10
both udp 10
both both 10
CASES
    "$REAL_JQ" '.forwards = .forwards[:2] | .forwards |= reverse' "$base" >"$manifest"
    check_conflicts 10 '转发 F1 与 F0 的端口区间及网络相交' 'inclusive lower endpoint' 1
    "$REAL_JQ" '.forwards = .forwards[:2] | .forwards[1].listen_port_start = 20011' "$base" >"$manifest"
    check_conflicts 0 '' 'adjacent disjoint intervals'

    for source in protocol legacy; do
        for hint in tcp udp both; do
            "$REAL_JQ" --arg source "$source" --arg hint "$hint" '
                .forwards = .forwards[:2] | .forwards[0].network = "auto" | .forwards[1].network = "udp" |
                .exits[0].network_hint = "both" |
                if $source == "protocol" then .exits[0].protocol.network_hint = $hint
                else .exits[0].protocol = {} | .exits[0].network_hint = $hint end
            ' "$base" >"$manifest"
            if [[ "$hint" == tcp ]]; then check_conflicts 0 '' "$source auto $hint";
            else check_conflicts 10 '转发 F0 与 F1 的端口区间及网络相交' "$source auto $hint" 1; fi
        done
    done
    "$REAL_JQ" '.forwards = .forwards[:1] | .forwards[0].network = "auto" | .exits[0].protocol.network_hint = "invalid"' "$base" >"$manifest"
    check_conflicts 2 'network=auto 时出口 protocol.network_hint 必须是 tcp、udp 或 both' 'invalid auto hint' 1
    "$REAL_JQ" '.forwards = .forwards[:1] | .exits[0].protocol.network_hint = "invalid"' "$base" >"$manifest"
    check_conflicts 0 '' 'explicit network ignores invalid hint'

    while IFS=' ' read -r profile hint; do
        "$REAL_JQ" -n --arg profile "$profile" '{nodes:[{id:"N0",port:20010,profile:$profile,tls:{}}]}' >"$nodes"
        for first in tcp udp; do
            "$REAL_JQ" --arg network "$first" '.forwards = .forwards[:1] | .forwards[0].network = $network' "$base" >"$manifest"
            if [[ "$hint" == both || "$hint" == "$first" ]]; then
                check_conflicts 10 "转发 F0 与受管节点 N0 的端口及网络相交（20010/${hint}）" "$profile/$first node mapping"
            else
                check_conflicts 0 '' "$profile/$first node mapping"
            fi
        done
    done <<'PROFILES'
hysteria2 udp
tuic-v5 udp
shadowsocks-aes-256-gcm both
shadowsocks-chacha20-poly1305 both
shadowsocks-2022 both
shadowsocks-2022-padding both
vless-reality-vision tcp
unknown-profile tcp
PROFILES
    printf '{"nodes":[{"id":"N0","port":25000,"profile":"hysteria2","tls":{"reality_guard":{"enabled":true,"listen_port":20010}}}]}\n' >"$nodes"
    for first in tcp udp both; do
        "$REAL_JQ" --arg network "$first" '.forwards = .forwards[:1] | .forwards[0].network = $network' "$base" >"$manifest"
        if [[ "$first" == udp ]]; then check_conflicts 0 '' 'UDP skips TCP guard';
        else check_conflicts 10 '转发 F0 与受管节点 N0 的 REALITY 防偷辅助端口及网络相交（20010/tcp）' "$first guard collision"; fi
    done
    printf '{"nodes":[{"id":"N0","port":25000,"profile":"hysteria2","tls":{"reality_guard":{"enabled":false,"listen_port":null}}},{"id":"N1","port":20010,"profile":"unknown","tls":{}}]}\n' >"$nodes"
    "$REAL_JQ" '.forwards = .forwards[:1]' "$base" >"$manifest"
    check_conflicts 10 '转发 F0 与受管节点 N1 的端口及网络相交（20010/tcp）' 'empty guard retains record alignment'

    printf '{"nodes":[{"id":"N0","port":20000,"profile":"unknown","tls":{}},{"id":"N1","port":20000,"profile":"unknown","tls":{}}]}\n' >"$nodes"
    cp "$base" "$manifest"
    check_conflicts 10 '转发 F0 与 F1 的端口区间及网络相交' 'first later forward precedes nodes and F2' 1
    "$REAL_JQ" '.forwards[1,2].listen_port_start = 21000 | .forwards[1,2].listen_port_end = 21010' "$base" >"$manifest"
    check_conflicts 10 '转发 F0 与受管节点 N0 的端口及网络相交（20000/tcp）' 'F0 first node precedes F1/F2 pair'
    "$REAL_JQ" '.forwards[2].network = "invalid"' "$base" >"$manifest"
    check_conflicts 10 '转发 F0 与 F1 的端口区间及网络相交' 'earlier pair precedes later invalid network' 1
    "$REAL_JQ" '.forwards[1,2].listen_port_start = 21000 | .forwards[1,2].listen_port_end = 21010 | .forwards[2].network = "invalid"' "$base" >"$manifest"
    check_conflicts 2 'network 必须是 auto、tcp、udp 或 both：invalid' 'later pair validation precedes F0 node' 1

    node_id=$'N |"\t中\r\ninner'
    for profile_json in '"\u0000hysteria2"' '"hysteria2\n"' '"tuic-v5\u0000\n\n"'; do
        "$REAL_JQ" -n --arg id "$node_id" --argjson profile "$profile_json" '
            {nodes:[{id:($id + "\u0000\n\n"),port:20010,profile:$profile,tls:{}}]}
        ' >"$nodes"
        "$REAL_JQ" '.forwards = .forwards[:1] | .forwards[0].network = "udp" | .forwards[0].id += "\u0000\n\n"' "$base" >"$manifest"
        check_conflicts 10 "转发 F0 与受管节点 ${node_id} 的端口及网络相交（20010/udp）" 'NUL and trailing LF preserve UDP profile mapping and IDs'
    done
    for profile_json in '""' 'null' 'false' '42' '"unknown |\t\r\nprofile"' '{"nested":["hysteria2",true]}'; do
        "$REAL_JQ" -n --argjson profile "$profile_json" '
            {nodes:[{id:{label:"line\nbreak",nested:[true,2]},port:20010,profile:$profile,tls:{}}]}
        ' >"$nodes"
        "$REAL_JQ" '.forwards = .forwards[:1]' "$base" >"$manifest"
        node_id="$("$REAL_JQ" -r '.nodes[0].id' "$nodes")"
        check_conflicts 10 "转发 F0 与受管节点 ${node_id} 的端口及网络相交（20010/tcp）" 'unrestricted node ID/profile values retain legacy behavior'
    done

    printf '{"forwards":[]}\n' >"$manifest"
    printf '{invalid\n' >"$nodes"
    check_conflicts 0 '' 'empty forwards skip node reads' 1
    "$REAL_JQ" '.forwards = .forwards[:1]' "$base" >"$manifest"
    rm -f -- "$nodes"
    check_conflicts 0 '' 'missing nodes' 1
    mkdir "$nodes"
    check_conflicts 0 '' 'node directory skipped by conflict helper' 1
    rmdir "$nodes"
    ln -s "$base" "$nodes"
    check_conflicts 0 '' 'node symlink skipped by conflict helper' 1
    rm -f -- "$nodes"
    printf '{"nodes":[]}\n' >"$nodes"
    check_conflicts 0 '' 'empty nodes'

    for size in 1 20; do
        "$REAL_JQ" -n --argjson size "$size" '{exits:[{id:"exit",network_hint:"both"}],forwards:[range($size) |
            {id:("F" + tostring),exit_id:"exit",listen_port_start:(30000 + . * 2),listen_port_end:(30001 + . * 2),network:"auto"}]}' >"$manifest"
        "$REAL_JQ" -n --argjson size "$size" '{nodes:[range($size) | {id:("N" + tostring),port:(40000 + .),profile:"unknown",tls:{}}]}' >"$nodes"
        check_conflicts 0 '' "$size forwards and nodes use two jq calls"
    done
    for failure in forward-short forward-partial forward-stream read-1 node-short node-partial node-stream read-2; do
        case "$failure" in forward-* | read-1) expected=1 ;; *) expected=2 ;; esac
        check_conflicts 10 '' "$failure rejects incomplete or failed transport" "$expected"
    done
)

test_relay_forward_render_nft() (
    local manifest="${TEST_TEMP}/render-relay.json" cache="${TEST_TEMP}/render-cache.json"
    local base="${TEST_TEMP}/render-base.json" cache_base="${TEST_TEMP}/render-cache-base.json"
    local actual="${TEST_TEMP}/render-actual.nft" errors="${TEST_TEMP}/render-errors.log" calls="${TEST_TEMP}/render-jq.log"
    local header="${TEST_TEMP}/render-header.nft" golden="${TEST_TEMP}/render-golden.nft" expected="${TEST_TEMP}/render-expected.nft"
    local empty="${TEST_TEMP}/render-empty.nft" helper_args_file="${TEST_TEMP}/render-args" failure='' fixture
    local PROXY_RELAY_FORWARD_TABLE4=render4 PROXY_RELAY_FORWARD_TABLE6=render6
    local -a captured=()
    source "${TEST_ROOT}/commands/service/proxy/relay-forward.sh"
    vps_cmd_error() { printf '%s\n' "$*" >&2; }
    jq() {
        printf 'jq\n' >>"$calls"
        case "$failure" in
            short) printf 'incomplete\0'; return 0 ;;
            partial) printf 'incomplete\0'; return 42 ;;
            empty) return 42 ;;
        esac
        "$REAL_JQ" "$@" || return $?
        [[ "$failure" != stream ]]
    }
    mapfile() {
        builtin mapfile "$@" || return $?
        [[ "$failure" != read ]]
    }
    check_render() {
        local expected_status="$1" expected_file="$2" description="$3" expected_calls="${4:-1}"
        : >"$calls"
        if proxy_relay_forward_render_nft "$manifest" "$cache" >"$actual" 2>"$errors"; then RUN_STATUS=0; else RUN_STATUS=$?; fi
        RUN_OUTPUT="$(<"$errors")"
        assert_equal "$expected_status" "$RUN_STATUS" "$description status"
        assert_equal "$expected_calls" "$(wc -l <"$calls")" "$description jq count"
        cmp -s "$expected_file" "$actual" || { diff -u "$expected_file" "$actual" >&2; fail "$description output differs"; }
    }
    cat >"$base" <<'JSON'
{"exits":[
{"id":"v4","endpoint":{"port":8443},"protocol":{"network_hint":"udp"}},
{"id":"dual","endpoint":{"port":443},"protocol":{"network_hint":"both"},"network_hint":"udp"},
{"id":"v6","endpoint":{"port":5353},"network_hint":"udp"}],"forwards":[
{"id":"F0","exit_id":"v4","network":"tcp","listen_port_start":30000,"listen_port_end":30002,"publish_address":"public.example","family":"ipv4"},
{"id":"F1","exit_id":"dual","network":"auto","listen_port_start":31000,"listen_port_end":31000,"publish_address":"203.0.113.1"},
{"id":"F2","exit_id":"v6","network":"auto","listen_port_start":32000,"listen_port_end":32001,"publish_address":"2001:db8::1","family":"ipv6"}]}
JSON
    cat >"$cache_base" <<'JSON'
{"exits":{"v4":{"ipv4":"198.51.100.10","ipv6":"2001:db8::10"},"dual":{"ipv4":"198.51.100.20","ipv6":"2001:db8::20"},"v6":{"ipv4":"198.51.100.30","ipv6":"2001:db8::30"}}}
JSON
    cat >"$header" <<'NFT'
destroy table ip render4
add table ip render4
add chain ip render4 prerouting { type nat hook prerouting priority dstnat; policy accept; }
add chain ip render4 forward { type filter hook forward priority filter; policy accept; }
add chain ip render4 postrouting { type nat hook postrouting priority srcnat; policy accept; }
destroy table ip6 render6
add table ip6 render6
add chain ip6 render6 prerouting { type nat hook prerouting priority dstnat; policy accept; }
add chain ip6 render6 forward { type filter hook forward priority filter; policy accept; }
add chain ip6 render6 postrouting { type nat hook postrouting priority srcnat; policy accept; }
NFT
    cp "$header" "$golden"
    cat >>"$golden" <<'NFT'
add rule ip render4 prerouting fib daddr type local tcp dport 30000-30002 counter dnat to 198.51.100.10:8443 comment "vpsctl:F0"
add rule ip render4 forward ct status dnat ip daddr 198.51.100.10 tcp dport 8443 ct state { new, established, related } counter accept comment "vpsctl:F0"
add rule ip render4 forward ct status dnat ct direction reply ct original proto-dst 30000-30002 meta l4proto tcp ct state { established, related } counter accept comment "vpsctl:F0:return"
add rule ip render4 postrouting ct status dnat ip daddr 198.51.100.10 tcp dport 8443 counter masquerade comment "vpsctl:F0"
add rule ip render4 prerouting fib daddr type local tcp dport 31000 counter dnat to 198.51.100.20:443 comment "vpsctl:F1"
add rule ip render4 forward ct status dnat ip daddr 198.51.100.20 tcp dport 443 ct state { new, established, related } counter accept comment "vpsctl:F1"
add rule ip render4 forward ct status dnat ct direction reply ct original proto-dst 31000 meta l4proto tcp ct state { established, related } counter accept comment "vpsctl:F1:return"
add rule ip render4 postrouting ct status dnat ip daddr 198.51.100.20 tcp dport 443 counter masquerade comment "vpsctl:F1"
add rule ip render4 prerouting fib daddr type local udp dport 31000 counter dnat to 198.51.100.20:443 comment "vpsctl:F1"
add rule ip render4 forward ct status dnat ip daddr 198.51.100.20 udp dport 443 ct state { new, established, related } counter accept comment "vpsctl:F1"
add rule ip render4 forward ct status dnat ct direction reply ct original proto-dst 31000 meta l4proto udp ct state { established, related } counter accept comment "vpsctl:F1:return"
add rule ip render4 postrouting ct status dnat ip daddr 198.51.100.20 udp dport 443 counter masquerade comment "vpsctl:F1"
add rule ip6 render6 prerouting fib daddr type local tcp dport 31000 counter dnat to [2001:db8::20]:443 comment "vpsctl:F1"
add rule ip6 render6 forward ct status dnat ip6 daddr 2001:db8::20 tcp dport 443 ct state { new, established, related } counter accept comment "vpsctl:F1"
add rule ip6 render6 forward ct status dnat ct direction reply ct original proto-dst 31000 meta l4proto tcp ct state { established, related } counter accept comment "vpsctl:F1:return"
add rule ip6 render6 postrouting ct status dnat ip6 daddr 2001:db8::20 tcp dport 443 counter masquerade comment "vpsctl:F1"
add rule ip6 render6 prerouting fib daddr type local udp dport 31000 counter dnat to [2001:db8::20]:443 comment "vpsctl:F1"
add rule ip6 render6 forward ct status dnat ip6 daddr 2001:db8::20 udp dport 443 ct state { new, established, related } counter accept comment "vpsctl:F1"
add rule ip6 render6 forward ct status dnat ct direction reply ct original proto-dst 31000 meta l4proto udp ct state { established, related } counter accept comment "vpsctl:F1:return"
add rule ip6 render6 postrouting ct status dnat ip6 daddr 2001:db8::20 udp dport 443 counter masquerade comment "vpsctl:F1"
add rule ip6 render6 prerouting fib daddr type local udp dport 32000-32001 counter dnat to [2001:db8::30]:5353 comment "vpsctl:F2"
add rule ip6 render6 forward ct status dnat ip6 daddr 2001:db8::30 udp dport 5353 ct state { new, established, related } counter accept comment "vpsctl:F2"
add rule ip6 render6 forward ct status dnat ct direction reply ct original proto-dst 32000-32001 meta l4proto udp ct state { established, related } counter accept comment "vpsctl:F2:return"
add rule ip6 render6 postrouting ct status dnat ip6 daddr 2001:db8::30 udp dport 5353 counter masquerade comment "vpsctl:F2"
NFT
    cp "$base" "$manifest"
    cp "$cache_base" "$cache"
    : >"$empty"
    check_render 0 "$golden" 'mixed family/protocol rules retain exact order and formatting'
    for fixture in ipv4 ipv6 missing; do
        "$REAL_JQ" --arg fixture "$fixture" '
            if $fixture == "missing" then del(.exits.dual) else del(.exits.dual[$fixture]) end
        ' "$cache_base" >"$cache"
        case "$fixture" in
            ipv4) sed '/^add rule ip render4 .*vpsctl:F1/d' "$golden" >"$expected" ;;
            ipv6) sed '/^add rule ip6 render6 .*vpsctl:F1/d' "$golden" >"$expected" ;;
            missing) sed '/^add rule .*vpsctl:F1/d' "$golden" >"$expected" ;;
        esac
        check_render 0 "$expected" "dual forward skips $fixture cache address"
    done
    cp "$cache_base" "$cache"
    "$REAL_JQ" '.forwards[1].network = "invalid"' "$base" >"$manifest"
    head -n 14 "$golden" >"$expected"
    check_render 2 "$expected" 'network errors retain preceding header and forward rules'
    assert_contains "$RUN_OUTPUT" 'network 必须是 auto、tcp、udp 或 both：invalid' 'invalid network diagnostic'
    printf '{"forwards":[]}\n' >"$manifest"
    check_render 0 "$header" 'empty forwards emit the ten-line clear batch'
    printf '{}\n' >"$cache"
    check_render 0 "$header" 'empty forwards need no cache entries'

    (
        # Capture helper arguments to cover fields such as publish_address which
        # deliberately do not appear in the resulting nft rules.
        _proxy_relay_forward_emit_rule_set() { printf '%s\0' "$@" >>"$helper_args_file"; }
        "$REAL_JQ" -n '{exits:[{id:"edge",endpoint:{port:"8443\u0000\n\n"},protocol:{network_hint:"tcp\u0000\n\n"}}],forwards:[
            {id:"F |\"\t中\r\ninner\u0000\n\n",exit_id:"edge\u0000\n\n",network:"auto\u0000\n\n",listen_port_start:"30000\u0000\n",listen_port_end:"30002\u0000\n",
             publish_address:"public |\"\t中\r\ninner\u0000\n\n",family:"ipv4\u0000\n\n"}]}' >"$manifest"
        printf '{"exits":{"edge":{"ipv4":"198.51.100.42\\u0000\\n\\n"}}}\n' >"$cache"
        : >"$helper_args_file"
        check_render 0 "$header" 'scalar fields retain internal characters and strip NUL/trailing LF'
        builtin mapfile -d '' -t captured <"$helper_args_file"
        assert_equal 9 "${#captured[@]}" 'one rule helper call with nine fields'
        assert_equal ip "${captured[0]}" 'normalized family'
        assert_equal render4 "${captured[1]}" 'family table'
        assert_equal 198.51.100.42 "${captured[2]}" 'normalized cache address'
        assert_equal 8443 "${captured[3]}" 'normalized endpoint port'
        assert_equal $'public |"\t中\r\ninner' "${captured[4]}" 'publish field character preservation'
        assert_equal tcp "${captured[5]}" 'normalized auto network hint'
        assert_equal 30000 "${captured[6]}" 'normalized interval start'
        assert_equal 30002 "${captured[7]}" 'normalized interval end'
        assert_equal $'F |"\t中\r\ninner' "${captured[8]}" 'ID character preservation'

        "$REAL_JQ" -n '{exits:[{id:"edge",endpoint:{port:[8443,"line\nbreak"]},network_hint:"udp"}],forwards:[
            {id:{label:"line\nbreak",nested:[true,2]},exit_id:"edge",network:"tcp",listen_port_start:30000,listen_port_end:30000,publish_address:[],family:"ipv4"}]}' >"$manifest"
        printf '{"exits":{"edge":{"ipv4":{"address":"198.51.100.42"}}}}\n' >"$cache"
        : >"$helper_args_file"
        check_render 0 "$header" 'non-string fields retain native jq rendering without new schema restrictions'
        builtin mapfile -d '' -t captured <"$helper_args_file"
        assert_equal "$("$REAL_JQ" -r '.exits.edge.ipv4' "$cache")" "${captured[2]}" 'structured cache address'
        assert_equal "$("$REAL_JQ" -r '.exits[0].endpoint.port' "$manifest")" "${captured[3]}" 'structured endpoint port'
        assert_equal '[]' "${captured[4]}" 'structured publish field'
        assert_equal "$("$REAL_JQ" -r '.forwards[0].id' "$manifest")" "${captured[8]}" 'structured ID'

        "$REAL_JQ" '.forwards = .forwards[:1] | .forwards[0].id = "" | .forwards[0].publish_address = "" | .exits[0].endpoint.port = ""' "$base" >"$manifest"
        cp "$cache_base" "$cache"
        : >"$helper_args_file"
        check_render 0 "$header" 'empty scalar fields retain record alignment'
        builtin mapfile -d '' -t captured <"$helper_args_file"
        assert_equal 9 "${#captured[@]}" 'empty fields retain nine rule helper arguments'
        assert_equal '' "${captured[3]}" 'empty endpoint port'
        assert_equal '' "${captured[4]}" 'empty publish field'
        assert_equal '' "${captured[8]}" 'empty ID'
    )

    cp "$base" "$manifest"
    cp "$cache_base" "$cache"
    for failure in short partial empty stream read; do
        check_render 10 "$empty" "$failure extraction failure emits no batch"
    done
    failure=''
    for fixture in manifest cache; do
        cp "$base" "$manifest"
        cp "$cache_base" "$cache"
        if [[ "$fixture" == manifest ]]; then printf '{invalid\n' >>"$manifest"; else printf '{invalid\n' >"$cache"; fi
        check_render 10 "$empty" "$fixture JSON parse failure emits no batch"
    done
    printf '{"forwards":[]}\n' >"$manifest"
    check_render 10 "$empty" 'cache parse failure is caught even with empty forwards'
    for fixture in empty-manifest empty-cache multiple-manifest multiple-cache; do
        cp "$base" "$manifest"
        cp "$cache_base" "$cache"
        case "$fixture" in
            empty-manifest) : >"$manifest" ;;
            empty-cache) : >"$cache" ;;
            multiple-manifest) printf '{}\n' >>"$manifest" ;;
            multiple-cache) printf '{}\n' >>"$cache" ;;
        esac
        check_render 10 "$empty" "$fixture document read failure emits no batch"
    done
    cp "$base" "$manifest"
    "$REAL_JQ" '.exits.dual = 42' "$cache_base" >"$cache"
    check_render 10 "$empty" 'cache field read failure emits no batch'
    cp "$base" "$manifest"
    rm -f -- "$cache"
    check_render 2 "$empty" 'missing cache retains file-type failure' 0
    cp "$cache_base" "$cache"
    rm -f -- "$manifest"
    ln -s "$base" "$manifest"
    check_render 2 "$empty" 'manifest symlink retains file-type failure' 0
)

test_relay_forward_refresh_cache() (
    local manifest="${TEST_TEMP}/cache-relay.json" old_cache="${TEST_TEMP}/cache-old.json"
    local output="${TEST_TEMP}/cache-actual.json" calls="${TEST_TEMP}/cache-getent.log"
    local errors="${TEST_TEMP}/cache-errors.log" dns="${TEST_TEMP}/cache-dns"
    local jq_calls="${TEST_TEMP}/cache-jq.log" sentinel="${TEST_TEMP}/cache-sentinel.json" failure=''
    source "${TEST_ROOT}/commands/service/proxy/relay-forward.sh"
    mkdir -p "$dns"
    vps_cmd_warning() { printf '%s\n' "$*" >&2; }
    date() { printf '2026-09-30T01:02:03Z\n'; }
    jq() {
        local file="${*: -1}"
        if [[ "$file" == "$manifest" ]]; then
            printf 'manifest\n' >>"$jq_calls"
            case "$failure" in
                short) printf 'incomplete\0'; return 0 ;;
                partial) printf 'ready\0batch.example\0ipv4\0'; return 42 ;;
                empty) return 42 ;;
            esac
        else
            printf 'jq\n' >>"$jq_calls"
        fi
        "$REAL_JQ" "$@" || return $?
        # Complete records must not hide a nonzero producer exit status.
        if [[ "$file" == "$manifest" && "$failure" == stream ]]; then return 42; fi
        return 0
    }
    mapfile() {
        builtin mapfile "$@" || return $?
        [[ "$failure" != read ]]
    }
    getent() {
        local database="$1" host="$2" address file="${dns}/$1-$2"
        printf '%s %s\n' "$database" "$host" >>"$calls"
        [[ -f "$file" ]] || return 2
        while IFS= read -r address; do
            [[ -z "$address" ]] || printf '%s STREAM %s\n' "$address" "$host"
        done <"$file"
        return 0
    }
    check_cache() {
        local expected_queries="$1" description="$2" expected_jq_calls="${3:-}"
        : >"$calls"
        : >"$jq_calls"
        # Call in the same shell so a cache leaking across invocations is observable.
        if proxy_relay_forward_refresh_cache "$manifest" "$old_cache" "$output" >"$errors" 2>&1; then RUN_STATUS=0; else RUN_STATUS=$?; fi
        RUN_OUTPUT="$(<"$errors")"
        assert_equal 0 "$RUN_STATUS" "$description status"
        assert_equal "$expected_queries" "$(LC_ALL=C sort "$calls")" "$description getent requests"
        assert_equal 1 "$(grep -c '^manifest$' "$jq_calls")" "$description manifest reads"
        [[ -z "$expected_jq_calls" ]] || assert_equal "$expected_jq_calls" "$(wc -l <"$jq_calls")" "$description jq count"
        assert_equal 600 "$(stat -c '%a' "$output")" "$description cache permissions"
        "$REAL_JQ" -e '
            .schema_version == 1 and (.resolved | type) == "array" and (.degraded | type) == "array" and
            .updated_at == "2026-09-30T01:02:03Z" and .updated_at == .generated_at and
            keys_unsorted == ["schema_version","exits","resolved","degraded","updated_at","generated_at"] and
            all(.exits[]; (.host | type) == "string" and .updated_at == "2026-09-30T01:02:03Z")
        ' "$output" >/dev/null || fail "$description cache schema"
    }
    check_cache_failure() {
        local expected_status="$1" description="$2" expected_jq_calls="${3:-1}" had_output=false
        [[ ! -e "$output" ]] || had_output=true
        : >"$calls"
        : >"$jq_calls"
        if proxy_relay_forward_refresh_cache "$manifest" "$old_cache" "$output" >"$errors" 2>&1; then RUN_STATUS=0; else RUN_STATUS=$?; fi
        RUN_OUTPUT="$(<"$errors")"
        assert_equal "$expected_status" "$RUN_STATUS" "$description status"
        assert_equal '' "$(<"$calls")" "$description skips DNS"
        assert_equal "$expected_jq_calls" "$(wc -l <"$jq_calls")" "$description jq count"
        if [[ "$had_output" == true ]]; then
            cmp -s "$sentinel" "$output" || fail "$description overwrote existing output"
            assert_equal 640 "$(stat -c '%a' "$output")" "$description output permissions unchanged"
        else
            [[ ! -e "$output" ]] || fail "$description created output"
        fi
    }

    printf '{"exits":[],"forwards":[]}\n' >"$manifest"
    check_cache '' 'empty exits' 3
    "$REAL_JQ" -e '.exits == {} and .resolved == [] and .degraded == []' "$output" >/dev/null || fail 'empty exits retain empty cache lists'
    printf '{"exits":[{"id":"unused","endpoint":{"host":"unused.example"}}],"forwards":[]}\n' >"$manifest"
    check_cache '' 'unreferenced exits' 3
    "$REAL_JQ" -e '.exits == {} and .resolved == [] and .degraded == []' "$output" >/dev/null || fail 'unreferenced exits are omitted'

    cat >"$manifest" <<'JSON'
{"exits":[
{"id":"a","endpoint":{"host":"shared.example"}},
{"id":"b","endpoint":{"host":"shared.example"}},
{"id":"other","endpoint":{"host":"other.example"}},
{"id":"case","endpoint":{"host":"Shared.example"}},
{"id":"dot","endpoint":{"host":"shared.example."}},
{"id":"unused","endpoint":{"host":"unused.example"}}],"forwards":[
{"exit_id":"a"},{"exit_id":"a","family":"ipv4"},{"exit_id":"b","family":"dual"},
{"exit_id":"other","family":"ipv4"},{"exit_id":"case","family":"ipv4"},{"exit_id":"dot","family":"ipv4"}]}
JSON
    printf '%s\n' '!invalid' '999.0.0.1' '198.51.100.20' '198.51.100.10' '198.51.100.20' >"${dns}/ahostsv4-shared.example"
    printf '%s\n' '!invalid' '2001:db8::20' '2001:db8::10' '2001:db8::20' >"${dns}/ahostsv6-shared.example"
    printf '%s\n' '198.51.100.30' >"${dns}/ahostsv4-other.example"
    printf '%s\n' '198.51.100.40' >"${dns}/ahostsv4-Shared.example"
    printf '%s\n' '198.51.100.50' >"${dns}/ahostsv4-shared.example."
    check_cache $'ahostsv4 Shared.example\nahostsv4 other.example\nahostsv4 shared.example\nahostsv4 shared.example.\nahostsv6 shared.example' 'shared DNS, family union and exact host text'
    jq -e '
        .exits.a.ipv4 == "198.51.100.10" and .exits.b.ipv4 == "198.51.100.10" and
        .exits.a.ipv6 == "2001:db8::10" and .exits.b.ipv6 == "2001:db8::10" and
        .exits.other.ipv4 == "198.51.100.30" and .exits.case.ipv4 == "198.51.100.40" and
        .exits.dot.ipv4 == "198.51.100.50" and (.exits | has("unused") | not) and
        (.resolved | map(.exit_id)) == ["a","b","other","case","dot"] and
        (.exits | keys_unsorted) == ["a","b","other","case","dot"] and
        (.exits.a | keys_unsorted) == ["ipv4","ipv6","host","updated_at"] and .degraded == []
    ' "$output" >/dev/null || fail 'shared DNS selects sorted valid addresses and keeps hosts distinct'
    printf '%s\n' '198.51.100.60' >"${dns}/ahostsv4-shared.example"
    printf '%s\n' '2001:db8::60' >"${dns}/ahostsv6-shared.example"
    check_cache $'ahostsv4 Shared.example\nahostsv4 other.example\nahostsv4 shared.example\nahostsv4 shared.example.\nahostsv6 shared.example' 'next refresh queries new DNS answers'
    jq -e '
        .exits.a.ipv4 == "198.51.100.60" and .exits.b.ipv4 == "198.51.100.60" and
        .exits.a.ipv6 == "2001:db8::60" and .exits.b.ipv6 == "2001:db8::60" and .degraded == []
    ' "$output" >/dev/null || fail 'successful DNS results must not survive the next refresh'

    cat >"$manifest" <<'JSON'
{"exits":[
{"id":"a","endpoint":{"host":"failed.example"}},
{"id":"b","endpoint":{"host":"failed.example"}},
{"id":"none","endpoint":{"host":"failed.example"}},
{"id":"mismatch","endpoint":{"host":"failed.example"}}],"forwards":[
{"exit_id":"a"},{"exit_id":"b"},{"exit_id":"none","family":"ipv4"},{"exit_id":"mismatch","family":"ipv4"}]}
JSON
    cat >"$old_cache" <<'JSON'
{"exits":{
"a":{"host":"failed.example","ipv4":"198.51.100.11","ipv6":"2001:db8::11"},
"b":{"host":"failed.example","ipv4":"198.51.100.22","ipv6":"2001:db8::22"},
"mismatch":{"host":"previous.example","ipv4":"198.51.100.33"}}}
JSON
    check_cache $'ahostsv4 failed.example\nahostsv6 failed.example' 'failed DNS reuses empty results with separate exit fallbacks'
    jq -e '
        .exits.a.ipv4 == "198.51.100.11" and .exits.a.ipv6 == "2001:db8::11" and
        .exits.b.ipv4 == "198.51.100.22" and .exits.b.ipv6 == "2001:db8::22" and
        .exits.none.ipv4 == null and .exits.mismatch.ipv4 == null and
        (.degraded | length) == 6 and all(.degraded[]; .reason == "dns-failed" and
            .retained == (.exit_id == "a" or .exit_id == "b")) and
        ([.degraded[] | [.exit_id,.family]] | sort) ==
            [["a","ipv4"],["a","ipv6"],["b","ipv4"],["b","ipv6"],["mismatch","ipv4"],["none","ipv4"]]
    ' "$output" >/dev/null || fail 'old cache is retained only for the matching exit, host and family'
    : >"${dns}/ahostsv4-failed.example"
    : >"${dns}/ahostsv6-failed.example"
    check_cache $'ahostsv4 failed.example\nahostsv6 failed.example' 'successful empty DNS output is also reused'
    jq -e '
        .exits.a.ipv4 == "198.51.100.11" and .exits.b.ipv4 == "198.51.100.22" and
        .exits.none.ipv4 == null and .exits.mismatch.ipv4 == null and (.degraded | length) == 6
    ' "$output" >/dev/null || fail 'empty DNS output preserves separate old cache decisions'
    printf '%s\n' '198.51.100.44' >"${dns}/ahostsv4-failed.example"
    printf '%s\n' '2001:db8::44' >"${dns}/ahostsv6-failed.example"
    check_cache $'ahostsv4 failed.example\nahostsv6 failed.example' 'DNS recovers on a later refresh'
    jq -e '
        all(.exits[]; .ipv4 == "198.51.100.44") and
        .exits.a.ipv6 == "2001:db8::44" and .exits.b.ipv6 == "2001:db8::44" and .degraded == []
    ' "$output" >/dev/null || fail 'failed DNS and retained addresses must not survive the next refresh'

    old_cache=''
    cat >"$manifest" <<'JSON'
{"exits":[
{"id":"v4","endpoint":{"host":"v4.example"}},
{"id":"v6","endpoint":{"host":"v6.example"}},
{"id":"partial-a","endpoint":{"host":"partial.example"}},
{"id":"partial-b","endpoint":{"host":"partial.example"}},
{"id":"literal4","endpoint":{"host":"198.51.100.70"}},
{"id":"literal6","endpoint":{"host":"2001:db8::70"}}],"forwards":[
{"exit_id":"v4","family":"ipv4"},{"exit_id":"v6","family":"ipv6"},
{"exit_id":"partial-a"},{"exit_id":"partial-b","family":"dual"},{"exit_id":"literal4"},{"exit_id":"literal6"}]}
JSON
    printf '%s\n' '198.51.100.80' >"${dns}/ahostsv4-v4.example"
    printf '%s\n' '2001:db8::80' >"${dns}/ahostsv6-v6.example"
    printf '%s\n' '198.51.100.90' >"${dns}/ahostsv4-partial.example"
    check_cache $'ahostsv4 partial.example\nahostsv4 v4.example\nahostsv6 partial.example\nahostsv6 v6.example' 'single stack, partial dual stack and IP literals'
    jq -e '
        .exits.v4.ipv4 == "198.51.100.80" and (.exits.v4 | has("ipv6") | not) and
        .exits.v6.ipv6 == "2001:db8::80" and (.exits.v6 | has("ipv4") | not) and
        .exits["partial-a"].ipv4 == "198.51.100.90" and .exits["partial-a"].ipv6 == null and
        .exits["partial-b"].ipv4 == "198.51.100.90" and .exits["partial-b"].ipv6 == null and
        .exits.literal4.ipv4 == "198.51.100.70" and (.exits.literal4 | has("ipv6") | not) and
        .exits.literal6.ipv6 == "2001:db8::70" and (.exits.literal6 | has("ipv4") | not) and
        ([.degraded[] | [.exit_id,.family,.reason,.retained]] | sort) ==
            [["literal4","ipv6","family-unavailable",false],["literal6","ipv4","family-unavailable",false],
             ["partial-a","ipv6","dns-failed",false],["partial-b","ipv6","dns-failed",false]]
    ' "$output" >/dev/null || fail 'address-family modes and IP literal degradation stay unchanged'

    (
        local id=$'edge |"\t中\r\ninner' host=$'host |"\t中\r\ninner'
        local resolver_args="${TEST_TEMP}/cache-resolver.args"
        local -a captured=()
        proxy_relay_forward_resolve_family() {
            printf '%s\0%s\0' "$1" "$2" >>"$resolver_args"
            if [[ "$2" == ipv4 ]]; then printf '198.51.100.42\n'; else printf '2001:db8::42\n'; fi
        }
        # $id and $host in the filter are jq variables supplied by --arg.
        # shellcheck disable=SC2016
        "$REAL_JQ" -n --arg id "$id" --arg host "$host" '{exits:[
            {id:($id + "\u0000\n\n"),endpoint:{host:($host + "\u0000\n\n")}},
            {id:"",endpoint:{host:""}},
            {id:"raw\u0000\n\n",endpoint:{host:"unqueried.example"}},
            {id:"legacy-null",endpoint:{host:"shared.example"}},
            {id:"unreferenced",endpoint:{host:"unused.example"}}],forwards:[
            {exit_id:($id + "\u0000\n\n"),family:"ipv6"},{exit_id:$id,family:"ipv4\u0000\n\n"},
            {exit_id:"",family:"ipv4"},{exit_id:"raw\u0000\n\n"},
            {exit_id:"legacy-null",family:null},{exit_id:"unreferenced\u0000\n\n",family:"dual"}]}' >"$manifest"
        : >"$resolver_args"
        check_cache '' 'field characters, empty fields and original reference matching'
        builtin mapfile -d '' -t captured <"$resolver_args"
        assert_equal 8 "${#captured[@]}" 'field semantics resolver argument count'
        assert_equal "$host" "${captured[0]}" 'host preserves internal characters and strips NUL/trailing LF'
        assert_equal ipv4 "${captured[1]}" 'family lookup uses normalized ID'
        assert_equal '' "${captured[2]}" 'empty host retains field alignment'
        assert_equal ipv4 "${captured[3]}" 'empty ID family lookup'
        assert_equal shared.example "${captured[4]}" 'null family defaults to dual host'
        assert_equal ipv4 "${captured[5]}" 'null family includes IPv4'
        assert_equal shared.example "${captured[6]}" 'dual host is unchanged'
        assert_equal ipv6 "${captured[7]}" 'null family includes IPv6'
        # $id and $host in the filter are jq variables supplied by --arg.
        # shellcheck disable=SC2016
        "$REAL_JQ" -e --arg id "$id" --arg host "$host" '
            .exits[$id].host == $host and .exits[$id].ipv4 == "198.51.100.42" and
            (.exits[$id] | has("ipv6") | not) and .exits[""].host == "" and
            .exits[""].ipv4 == "198.51.100.42" and
            (.exits.raw | keys_unsorted) == ["host","updated_at"] and
            .exits["legacy-null"].ipv4 == "198.51.100.42" and .exits["legacy-null"].ipv6 == "2001:db8::42" and
            (.resolved | map(.exit_id)) == [$id,"","raw","legacy-null"] and .degraded == []
        ' "$output" >/dev/null || fail 'ID/host normalization, reference filtering and empty fields remain unchanged'
    )

    "$REAL_JQ" -n '{exits:[range(20) | {id:("E" + tostring),endpoint:{host:"batch.example"}}],
        forwards:[range(20) | {exit_id:("E" + tostring)}]}' >"$manifest"
    printf '198.51.100.42\n' >"${dns}/ahostsv4-batch.example"
    printf '2001:db8::42\n' >"${dns}/ahostsv6-batch.example"
    check_cache $'ahostsv4 batch.example\nahostsv6 batch.example' 'twenty dual-stack exits batch field reads' 83

    printf 'existing output\n' >"$sentinel"
    cp "$sentinel" "$output"
    chmod 0640 "$output"
    for failure in short partial empty stream read; do
        check_cache_failure 20 "$failure extraction failure preserves output"
    done
    failure=''
    : >"$manifest"
    check_cache_failure 20 'empty manifest preserves output'
    printf '{"exits":[{"id":"ready","endpoint":{"host":"batch.example"}}],"forwards":[{"exit_id":"ready"}]}\n{invalid\n' >"$manifest"
    check_cache_failure 20 'JSON parse failure after a valid document preserves output'
    rm -f -- "$output"
    check_cache_failure 20 'JSON parse failure creates no output'
    rm -f -- "$manifest"
    check_cache_failure 2 'missing manifest retains file-type failure' 0
    ln -s "$sentinel" "$manifest"
    check_cache_failure 2 'manifest symlink retains file-type failure' 0
    rm -f -- "$manifest"
    printf '{"exits":[],"forwards":[]}\n' >"$manifest"
    output=''
    check_cache_failure 2 'empty output path retains argument failure' 0
)

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

test_node_core_switch() {
    local switch_id incompatible_id peer_id binding_id exit_id state_hash relay_hash
    local before_semantic after_semantic old_updated old_cert old_key new_cert new_key
    local source_config target_config source_config_hash target_config_hash
    local source_stop_line target_apply_line source_restore_line exit_uri
    local profile source_core target_core matrix_name matrix_id matrix_before matrix_after port=35400
    local cert_dir="${TEST_TEMP}/node-core-switch-cert"
    local -a shared_profiles=(
        vless-reality-vision vless-grpc-tls hysteria2 shadowsocks-aes-256-gcm
        shadowsocks-chacha20-poly1305 shadowsocks-2022 shadowsocks-2022-padding
    )

    # Confirmation, registration, compatibility, pending state, and relay safety guards.
    reset_root
    install_external sing-box
    install_external xray
    run_proxy stop --core xray --disable
    assert_equal 0 "$RUN_STATUS" "stop target for core switch dry-run checks"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box \
        --name switch-guard --port 35101 --address switch.example
    assert_equal 0 "$RUN_STATUS" "core switch guard node add"
    switch_id="$(node_id_by_name switch-guard)"
    state_hash="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    source_config_hash="$(sha256sum "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json" | awk '{print $1}')"
    target_config_hash="$(sha256sum "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json" | awk '{print $1}')"
    run_proxy --dry-run node core set --id "$switch_id" --core xray
    assert_equal 0 "$RUN_STATUS" "core switch dry-run"
    assert_contains "$RUN_OUTPUT" "演练" "core switch dry-run output"
    assert_equal "$state_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "core switch dry-run manifest"
    assert_equal "$source_config_hash" "$(sha256sum "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json" | awk '{print $1}')" "core switch dry-run source config"
    assert_equal "$target_config_hash" "$(sha256sum "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json" | awk '{print $1}')" "core switch dry-run target config"
    [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-xray.service" ]] || fail "core switch dry-run started target"
    run_proxy node core set --id "$switch_id" --core xray
    assert_equal 3 "$RUN_STATUS" "core switch requires disruptive confirmation"
    assert_equal "$state_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "unconfirmed core switch state"
    run_proxy --yes node core set --id "$switch_id" --core xray
    assert_equal 3 "$RUN_STATUS" "core switch --yes does not replace disruptive confirmation"
    run_proxy node core set --id "$switch_id" --core sing-box --confirm-disruptive
    assert_equal 3 "$RUN_STATUS" "same-core switch rejection"

    run_proxy uninstall --core xray
    assert_equal 0 "$RUN_STATUS" "remove target registration fixture"
    run_proxy node core set --id "$switch_id" --core xray --confirm-disruptive
    assert_equal 3 "$RUN_STATUS" "unregistered target core rejection"
    write_core_binary xray
    run_proxy install --core xray
    assert_equal 0 "$RUN_STATUS" "restore target registration fixture"

    run_proxy node add --profile vless-tcp --core sing-box \
        --name switch-incompatible --port 35102 --address switch.example
    assert_equal 0 "$RUN_STATUS" "incompatible core switch node add"
    incompatible_id="$(node_id_by_name switch-incompatible)"
    run_proxy node core set --id "$incompatible_id" --core xray --confirm-disruptive
    assert_equal 3 "$RUN_STATUS" "incompatible profile core switch rejection"

    mkdir -p "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending"
    jq -n --arg core xray '{
        schema_version:1,core:$core,reason:"core-update",
        manifest_backup:"",config_backup:"",binary_backup:"",meta_backup:"",
        relay_backup:"",relay_existed:false,relay_touched:false,
        relay_runtime_touched:false,relay_cache_backup:"",relay_cache_existed:false,
        relay_nft_backup:"",relay_nft_existed:false,created_at:"2026-01-01T00:00:00Z"
    }' >"${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json"
    state_hash="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    run_proxy node core set --id "$switch_id" --core xray --confirm-disruptive
    assert_equal 3 "$RUN_STATUS" "pending target core switch rejection"
    assert_equal "$state_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "pending rejection manifest state"
    rm -f -- "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json"

    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box \
        --name switch-peer --port 35103 --address switch.example
    assert_equal 0 "$RUN_STATUS" "shared relay switch peer add"
    peer_id="$(node_id_by_name switch-peer)"
    run_proxy relay exit add --name switch-guard-exit \
        --uri 'socks5://relay-user:relay-pass@198.51.100.20:1080#switch-guard' --core sing-box
    assert_equal 0 "$RUN_STATUS" "core switch guard relay exit add"
    exit_id="$(jq -r '.exits[] | select(.name == "switch-guard-exit") | .id' "$(relay_path)")"
    run_proxy relay bind add --node-id "$switch_id" --exit-id "$exit_id"
    assert_equal 0 "$RUN_STATUS" "core switch first shared binding"
    run_proxy relay bind add --node-id "$peer_id" --exit-id "$exit_id"
    assert_equal 0 "$RUN_STATUS" "core switch second shared binding"
    relay_hash="$(sha256sum "$(relay_path)" | awk '{print $1}')"
    run_proxy node core set --id "$switch_id" --core xray --confirm-disruptive
    assert_equal 3 "$RUN_STATUS" "shared relay exit core switch rejection"
    assert_equal "$relay_hash" "$(sha256sum "$(relay_path)" | awk '{print $1}')" "shared exit rejection relay state"

    binding_id="$(jq -r --arg node "$peer_id" '.bindings[] | select(.node_id == $node) | .id' "$(relay_path)")"
    run_proxy relay bind delete --id "$binding_id" --confirm-delete
    assert_equal 0 "$RUN_STATUS" "make core switch relay exit exclusive"
    run_proxy relay forward add --name switch-guard-forward --exit-id "$exit_id" \
        --listen-ports 35150 --network tcp --address relay.example
    assert_equal 0 "$RUN_STATUS" "core switch relay forward fixture"
    relay_hash="$(sha256sum "$(relay_path)" | awk '{print $1}')"
    run_proxy node core set --id "$switch_id" --core xray --confirm-disruptive
    assert_equal 3 "$RUN_STATUS" "forwarded relay exit core switch rejection"
    assert_equal "$relay_hash" "$(sha256sum "$(relay_path)" | awk '{print $1}')" "forward rejection relay state"

    # A retained node can leave an unregistered source core; removing it still produces a valid retained source config.
    reset_root
    install_external sing-box
    install_external xray
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box \
        --name switch-unregistered-source --port 35170 --address switch.example
    assert_equal 0 "$RUN_STATUS" "unregistered source movable node add"
    switch_id="$(node_id_by_name switch-unregistered-source)"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box \
        --name switch-unregistered-remaining --port 35171 --address switch.example
    assert_equal 0 "$RUN_STATUS" "unregistered source remaining node add"
    peer_id="$(node_id_by_name switch-unregistered-remaining)"
    run_proxy uninstall --core sing-box
    assert_equal 0 "$RUN_STATUS" "unregister retained source core"
    run_proxy node core set --id "$switch_id" --core xray --confirm-disruptive
    assert_equal 0 "$RUN_STATUS" "switch from unregistered retained source"
    assert_equal xray "$(jq -r --arg id "$switch_id" '.nodes[] | select(.id == $id) | .core' "$(manifest_path)")" "unregistered source switched node"
    jq -e --arg id "$peer_id" '[.inbounds[] | select(.tag == $id)] | length == 1' \
        "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json" >/dev/null || fail "unregistered source config lost retained node"
    jq -e --arg id "$switch_id" '[.inbounds[] | select(.tag == $id)] | length == 1' \
        "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json" >/dev/null || fail "unregistered source target config missing node"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-xray.service" ]] || fail "unregistered source switch did not start target"

    # A compatible, exclusive binding follows the node. TLS paths are rewritten for the target core.
    reset_root
    install_external sing-box
    install_external xray
    run_proxy stop --core xray --disable
    assert_equal 0 "$RUN_STATUS" "stop target before core switch takeover"
    mkdir -p "$cert_dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=switch.example' \
        -addext 'subjectAltName=DNS:switch.example' \
        -keyout "${cert_dir}/key.pem" -out "${cert_dir}/cert.pem" >/dev/null 2>&1
    run_proxy node add --profile vless-grpc-tls --core sing-box --name switch-tls \
        --port 35201 --address switch.example --sni switch.example --service-name switch \
        --cert-mode imported --cert-file "${cert_dir}/cert.pem" --key-file "${cert_dir}/key.pem"
    assert_equal 0 "$RUN_STATUS" "TLS core switch node add"
    switch_id="$(node_id_by_name switch-tls)"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box \
        --name switch-remaining --port 35202 --address switch.example
    assert_equal 0 "$RUN_STATUS" "source remaining node add"
    peer_id="$(node_id_by_name switch-remaining)"
    old_cert="$(jq -r --arg id "$switch_id" '.nodes[] | select(.id == $id) | .tls.certificate_path' "$(manifest_path)")"
    old_key="$(jq -r --arg id "$switch_id" '.nodes[] | select(.id == $id) | .tls.key_path' "$(manifest_path)")"
    new_cert="${old_cert/sing-box/xray}"
    new_key="${old_key/sing-box/xray}"
    mkdir -p "${TEST_SYSTEM_ROOT}${new_cert%/*}"
    cp -- "${TEST_SYSTEM_ROOT}${old_cert}" "${TEST_SYSTEM_ROOT}${new_cert}"
    cp -- "${TEST_SYSTEM_ROOT}${old_key}" "${TEST_SYSTEM_ROOT}${new_key}"
    jq -n --arg cert "$new_cert" --arg key "$new_key" \
        '{schema_version:1,kind:"node-core-switch-cert-stage",cert_created:[$cert,$key],created_at:"2026-01-01T00:00:00Z"}' \
        >"${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/transaction-core-switch-certs.json"
    run_proxy node edit --id "$switch_id" --name switch-tls-stage-recovered
    assert_equal 0 "$RUN_STATUS" "recover interrupted core switch certificate stage"
    [[ ! -e "${TEST_SYSTEM_ROOT}${new_cert}" && ! -e "${TEST_SYSTEM_ROOT}${new_key}" ]] || fail "certificate stage recovery left target copies"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/transaction-core-switch-certs.json" ]] || fail "certificate stage recovery left journal"
    jq --arg id "$switch_id" '(.nodes[] | select(.id == $id) | .updated_at) = "2000-01-01T00:00:00Z"' \
        "$(manifest_path)" >"${TEST_TEMP}/node-core-switch-manifest.json"
    cp -- "${TEST_TEMP}/node-core-switch-manifest.json" "$(manifest_path)"
    before_semantic="$(jq -c --arg id "$switch_id" '.nodes[] | select(.id == $id) |
        {id,profile,name,listen,port,address,ip_strategy,created_at,credentials,
         tls:(.tls | del(.certificate_path,.key_path)),transport,options}' "$(manifest_path)")"
    old_updated="$(jq -r --arg id "$switch_id" '.nodes[] | select(.id == $id) | .updated_at' "$(manifest_path)")"
    old_cert="$(jq -r --arg id "$switch_id" '.nodes[] | select(.id == $id) | .tls.certificate_path' "$(manifest_path)")"
    old_key="$(jq -r --arg id "$switch_id" '.nodes[] | select(.id == $id) | .tls.key_path' "$(manifest_path)")"
    run_proxy node show --id "$peer_id" --uri
    assert_equal 0 "$RUN_STATUS" "core switch movable relay URI"
    exit_uri="$RUN_OUTPUT"
    run_proxy relay exit add --name switch-follow-exit --uri "$exit_uri" --core sing-box
    assert_equal 0 "$RUN_STATUS" "core switch movable relay exit add"
    exit_id="$(jq -r '.exits[] | select(.name == "switch-follow-exit") | .id' "$(relay_path)")"
    run_proxy relay bind add --node-id "$switch_id" --exit-id "$exit_id"
    assert_equal 0 "$RUN_STATUS" "core switch movable relay binding"

    run_proxy start --core sing-box --enable
    assert_equal 0 "$RUN_STATUS" "start enabled source before core switch"
    : >"$MOCK_LOG"
    run_proxy node core set --id "$switch_id" --core xray --confirm-disruptive
    assert_equal 0 "$RUN_STATUS" "compatible node core switch"
    assert_equal xray "$(jq -r --arg id "$switch_id" '.nodes[] | select(.id == $id) | .core' "$(manifest_path)")" "switched node target core"
    after_semantic="$(jq -c --arg id "$switch_id" '.nodes[] | select(.id == $id) |
        {id,profile,name,listen,port,address,ip_strategy,created_at,credentials,
         tls:(.tls | del(.certificate_path,.key_path)),transport,options}' "$(manifest_path)")"
    assert_equal "$before_semantic" "$after_semantic" "core switch preserved node semantics"
    [[ "$(jq -r --arg id "$switch_id" '.nodes[] | select(.id == $id) | .updated_at' "$(manifest_path)")" != "$old_updated" ]] || \
        fail "core switch did not update updated_at"
    new_cert="$(jq -r --arg id "$switch_id" '.nodes[] | select(.id == $id) | .tls.certificate_path' "$(manifest_path)")"
    new_key="$(jq -r --arg id "$switch_id" '.nodes[] | select(.id == $id) | .tls.key_path' "$(manifest_path)")"
    [[ "$new_cert" == /etc/vpsctl/proxy/xray/certs/"${switch_id}"/* && "$new_cert" != "$old_cert" ]] || fail "core switch certificate path was not moved to Xray"
    [[ "$new_key" == /etc/vpsctl/proxy/xray/certs/"${switch_id}"/* && "$new_key" != "$old_key" ]] || fail "core switch key path was not moved to Xray"
    [[ -f "${TEST_SYSTEM_ROOT}${new_cert}" && -f "${TEST_SYSTEM_ROOT}${new_key}" ]] || fail "core switch target certificate material missing"

    source_config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json"
    target_config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json"
    jq -e --arg id "$switch_id" '[.inbounds[] | select(.tag == $id)] | length == 0' "$source_config" >/dev/null || fail "source config retained switched inbound"
    jq -e --arg id "$peer_id" '[.inbounds[] | select(.tag == $id)] | length == 1' "$source_config" >/dev/null || fail "source config lost remaining inbound"
    jq -e --arg id "$switch_id" '[.inbounds[] | select(.tag == $id)] | length == 1' "$target_config" >/dev/null || fail "target config missing switched inbound"
    jq -e --arg id "$exit_id" --arg node "$switch_id" '
        (.exits[] | select(.id == $id) | .core) == "xray" and
        ([.bindings[] | select(.node_id == $node)] | length == 1)
    ' "$(relay_path)" >/dev/null || fail "exclusive relay binding or exit did not follow switched node"
    assert_equal 0 "$(jq -r '[.outbounds[] | select((.tag // "") | startswith("relay-exit-"))] | length' "$source_config")" "source relay outbound removed after switch"
    assert_equal 1 "$(jq -r '[.outbounds[] | select((.tag // "") | startswith("relay-exit-"))] | length' "$target_config")" "target relay outbound added after switch"

    source_stop_line="$(grep -nF 'systemctl stop vpsctl-proxy-sing-box.service' "$MOCK_LOG" | head -n 1 | cut -d: -f1)"
    target_apply_line="$(grep -nE 'systemctl (start|restart) vpsctl-proxy-xray.service' "$MOCK_LOG" | head -n 1 | cut -d: -f1)"
    source_restore_line="$(grep -nE 'systemctl (start|restart) vpsctl-proxy-sing-box.service' "$MOCK_LOG" | head -n 1 | cut -d: -f1)"
    [[ -n "$source_stop_line" && -n "$target_apply_line" && -n "$source_restore_line" ]] || fail "core switch service transition calls missing: $(<"$MOCK_LOG")"
    ((source_stop_line < target_apply_line && target_apply_line < source_restore_line)) || fail "core switch service transition order invalid: $(<"$MOCK_LOG")"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-xray.service" ]] || fail "target core was not started immediately"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-sing-box.service" ]] || fail "source core with remaining nodes was not restored"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/enabled-vpsctl-proxy-xray.service" ]] || fail "target core did not inherit enabled state"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/enabled-vpsctl-proxy-sing-box.service" ]] || fail "source core with remaining nodes lost enabled state"

    # Moving the final source node restarts the already-active target and disables the empty source.
    : >"$MOCK_LOG"
    run_proxy node core set --id "$peer_id" --core xray --confirm-disruptive
    assert_equal 0 "$RUN_STATUS" "last source node core switch"
    assert_file_contains "$MOCK_LOG" "systemctl stop vpsctl-proxy-sing-box.service" "last-node source stop"
    assert_file_contains "$MOCK_LOG" "systemctl restart vpsctl-proxy-xray.service" "active target restart"
    assert_file_contains "$MOCK_LOG" "systemctl disable vpsctl-proxy-sing-box.service" "empty source disable"
    [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-sing-box.service" ]] || fail "empty source remained active"
    [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-systemd/enabled-vpsctl-proxy-sing-box.service" ]] || fail "empty source remained enabled"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-xray.service" ]] || fail "target inactive after last-node switch"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/enabled-vpsctl-proxy-xray.service" ]] || fail "target disabled after inheriting source state"

    # A target restart failure restores manifests, configs, relay state, pending markers, and services.
    reset_root
    install_external sing-box
    install_external xray
    run_proxy stop --core xray --disable
    assert_equal 0 "$RUN_STATUS" "disable target before core switch rollback checks"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core sing-box \
        --name switch-rollback --port 35301 --address rollback.example
    assert_equal 0 "$RUN_STATUS" "core switch rollback node add"
    switch_id="$(node_id_by_name switch-rollback)"
    run_proxy node show --id "$switch_id" --uri
    assert_equal 0 "$RUN_STATUS" "core switch rollback relay URI"
    exit_uri="$RUN_OUTPUT"
    run_proxy relay exit add --name switch-rollback-exit --uri "$exit_uri" --core sing-box
    assert_equal 0 "$RUN_STATUS" "core switch rollback exit add"
    exit_id="$(jq -r '.exits[] | select(.name == "switch-rollback-exit") | .id' "$(relay_path)")"
    run_proxy relay bind add --node-id "$switch_id" --exit-id "$exit_id"
    assert_equal 0 "$RUN_STATUS" "core switch rollback binding add"
    source_config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json"
    target_config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json"
    state_hash="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    relay_hash="$(sha256sum "$(relay_path)" | awk '{print $1}')"
    source_config_hash="$(sha256sum "$source_config" | awk '{print $1}')"
    target_config_hash="$(sha256sum "$target_config" | awk '{print $1}')"
    touch "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-sing-box.service"
    touch "${TEST_SYSTEM_ROOT}/run/mock-systemd/enabled-vpsctl-proxy-sing-box.service"
    touch "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-xray.service"
    : >"$MOCK_LOG"
    touch "${TEST_SYSTEM_ROOT}/run/fail-service-restart-once"
    run_proxy node core set --id "$switch_id" --core xray --confirm-disruptive
    assert_equal 20 "$RUN_STATUS" "core switch target restart failure"
    assert_equal "$state_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "core switch rollback manifest"
    assert_equal "$relay_hash" "$(sha256sum "$(relay_path)" | awk '{print $1}')" "core switch rollback relay state"
    assert_equal "$source_config_hash" "$(sha256sum "$source_config" | awk '{print $1}')" "core switch rollback source config"
    assert_equal "$target_config_hash" "$(sha256sum "$target_config" | awk '{print $1}')" "core switch rollback target config"
    assert_equal sing-box "$(jq -r --arg id "$switch_id" '.nodes[] | select(.id == $id) | .core' "$(manifest_path)")" "core switch rollback node core"
    assert_equal sing-box "$(jq -r --arg id "$exit_id" '.exits[] | select(.id == $id) | .core' "$(relay_path)")" "core switch rollback relay exit core"
    [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/sing-box.json" && \
       ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json" ]] || fail "core switch rollback left pending state"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-sing-box.service" ]] || fail "core switch rollback did not restore source activity"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/enabled-vpsctl-proxy-sing-box.service" ]] || fail "core switch rollback did not restore source enablement"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-xray.service" ]] || fail "core switch rollback changed prior target activity"
    [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-systemd/enabled-vpsctl-proxy-xray.service" ]] || fail "core switch rollback changed prior target enablement"

    # Every profile shared by the public matrix can reuse source-generated credentials in both directions.
    reset_root
    install_external sing-box 1.14.0
    install_external xray 26.3.27
    for profile in "${shared_profiles[@]}"; do
        for source_core in sing-box xray; do
            case "$source_core" in sing-box) target_core=xray ;; xray) target_core=sing-box ;; esac
            port=$((port + 1))
            matrix_name="matrix-${profile}-${source_core}"
            if [[ "$profile" == vless-grpc-tls ]]; then
                run_proxy node add --profile "$profile" --core "$source_core" --name "$matrix_name" \
                    --port "$port" --address matrix.example --sni matrix.example --service-name matrix
            else
                run_proxy node add --profile "$profile" --core "$source_core" --name "$matrix_name" \
                    --port "$port" --address matrix.example --sni matrix.example
            fi
            assert_equal 0 "$RUN_STATUS" "matrix source node add ${profile}/${source_core}"
            matrix_id="$(node_id_by_name "$matrix_name")"
            matrix_before="$(jq -c --arg id "$matrix_id" '.nodes[] | select(.id == $id) |
                del(.core,.updated_at,.tls.certificate_path,.tls.key_path)' "$(manifest_path)")"
            run_proxy node core set --id "$matrix_id" --core "$target_core" --confirm-disruptive
            assert_equal 0 "$RUN_STATUS" "matrix core switch ${profile}/${source_core}"
            matrix_after="$(jq -c --arg id "$matrix_id" '.nodes[] | select(.id == $id) |
                del(.core,.updated_at,.tls.certificate_path,.tls.key_path)' "$(manifest_path)")"
            assert_equal "$matrix_before" "$matrix_after" "matrix semantics ${profile}/${source_core}"
            assert_equal "$target_core" "$(jq -r --arg id "$matrix_id" '.nodes[] | select(.id == $id) | .core' "$(manifest_path)")" \
                "matrix target core ${profile}/${source_core}"
        done
    done
}

test_reality_anti_relay_guard() {
    local direct_id protocol_id xray_id sb_id off_id legacy_id replacement_id guard_port sb_guard_port
    local before_manifest before_config before_uri after_uri before_credentials before_keys
    local xray_config sb_config manifest_hash relay_hash xray_hash sb_hash list_json invalid relay_uri

    reset_root
    install_external sing-box
    install_external xray

    # Allocation must avoid a real listener, ordinary node ports, forward ranges,
    # the candidate's public port, and guard ports already assigned to either core.
    printf '10000\n' >"${TEST_SYSTEM_ROOT}/run/listening-port"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray \
        --name guard-port-owner --port 10001 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "guard allocation ordinary-node fixture"
    run_proxy relay exit add --name guard-port-direct --target 198.51.100.30 --target-port 443
    assert_equal 0 "$RUN_STATUS" "guard allocation direct-exit fixture"
    direct_id="$(jq -r '.exits[] | select(.name == "guard-port-direct") | .id' "$(relay_path)")"
    run_proxy relay forward add --name guard-port-forward --exit-id "$direct_id" \
        --listen-ports 10002-10003 --network tcp --address relay.example
    assert_equal 0 "$RUN_STATUS" "guard allocation forward fixture"

    run_proxy node add --profile vless-reality-vision --core xray --name guarded-xray \
        --port 10004 --address proxy.example --sni reality.example
    assert_equal 0 "$RUN_STATUS" "REALITY add defaults anti-relay on"
    xray_id="$(node_id_by_name guarded-xray)"
    guard_port="$(jq -r --arg id "$xray_id" '.nodes[] | select(.id == $id) | .tls.reality_guard.listen_port' "$(manifest_path)")"
    assert_equal 10005 "$guard_port" "guard allocation skips system, node, forward and public ports"
    jq -e --arg id "$xray_id" '.nodes[] | select(.id == $id) |
        .tls.reality_guard == {enabled:true,listen_port:10005}' "$(manifest_path)" >/dev/null ||
        fail "default REALITY guard state"

    run_proxy node add --profile vless-reality-vision --core sing-box --name guarded-sing-box \
        --port 19101 --address proxy.example --sni reality.example --ip-strategy prefer_ipv4
    assert_equal 0 "$RUN_STATUS" "second-core guarded REALITY add"
    sb_id="$(node_id_by_name guarded-sing-box)"
    sb_guard_port="$(jq -r --arg id "$sb_id" '.nodes[] | select(.id == $id) | .tls.reality_guard.listen_port' "$(manifest_path)")"
    assert_equal 10006 "$sb_guard_port" "guard allocation is shared across cores"

    run_proxy node add --profile anytls-reality --core sing-box --name unguarded-reality \
        --port 19102 --address proxy.example --sni reality.example --reality-anti-relay off
    assert_equal 0 "$RUN_STATUS" "explicit REALITY anti-relay off"
    off_id="$(node_id_by_name unguarded-reality)"
    jq -e --arg id "$off_id" '.nodes[] | select(.id == $id) |
        .tls.reality_guard == {enabled:false,listen_port:null}' "$(manifest_path)" >/dev/null ||
        fail "explicit disabled REALITY guard state"

    run_proxy node list --json
    assert_equal 0 "$RUN_STATUS" "guard node JSON list"
    list_json="$RUN_OUTPUT"
    jq -e --arg on "$xray_id" --arg off "$off_id" '
        (.nodes[] | select(.id == $on) | .reality_anti_relay) == true and
        (.nodes[] | select(.id == $off) | .reality_anti_relay) == false
    ' <<<"$list_json" >/dev/null || fail "node JSON list guard booleans"

    # The option has a deliberately narrow contract: only REALITY nodes and only
    # on/off.  Enabled guards additionally require an exact DNS hostname SNI.
    for invalid in yes true 1 ''; do
        if [[ -n "$invalid" ]]; then
            run_proxy node add --profile vless-reality-vision --core xray --name "invalid-mode-$invalid" \
                --port 19200 --address proxy.example --sni reality.example --reality-anti-relay "$invalid"
        else
            run_proxy node add --profile vless-reality-vision --core xray --name invalid-mode-missing \
                --port 19200 --address proxy.example --sni reality.example --reality-anti-relay
        fi
        assert_equal 2 "$RUN_STATUS" "invalid anti-relay mode ${invalid:-missing}"
    done
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name invalid-nonreality-on \
        --port 19201 --address proxy.example --reality-anti-relay on
    assert_equal 2 "$RUN_STATUS" "non-REALITY rejects anti-relay on"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name invalid-nonreality-off \
        --port 19201 --address proxy.example --reality-anti-relay off
    assert_equal 2 "$RUN_STATUS" "non-REALITY rejects anti-relay off"
    for invalid in 198.51.100.10 2001:db8::1 'https://reality.example' 'reality.example/path' 'reality.example:443' '*.reality.example'; do
        run_proxy node add --profile vless-reality-vision --core xray --name invalid-sni \
            --port 19202 --address proxy.example --sni "$invalid" --reality-anti-relay on
        assert_equal 2 "$RUN_STATUS" "guard rejects non-DNS SNI $invalid"
    done

    # Editing unrelated fields preserves both the assigned inner port and all
    # credentials. Toggling the guard changes neither credentials nor URI.
    before_credentials="$(jq -Sc --arg id "$xray_id" '.nodes[] | select(.id == $id) | .credentials' "$(manifest_path)")"
    before_keys="$(jq -r --arg id "$xray_id" '.nodes[] | select(.id == $id) |
        .credentials.private_key + ":" + .credentials.public_key + ":" + .credentials.short_id' "$(manifest_path)")"
    run_proxy node show --id "$xray_id" --uri
    assert_equal 0 "$RUN_STATUS" "guarded URI before edits"
    before_uri="$RUN_OUTPUT"
    run_proxy node edit --id "$xray_id" --address edited-proxy.example
    assert_equal 0 "$RUN_STATUS" "unrelated guarded-node edit"
    assert_equal "$guard_port" "$(jq -r --arg id "$xray_id" '.nodes[] | select(.id == $id) | .tls.reality_guard.listen_port' "$(manifest_path)")" \
        "unrelated edit preserves guard port"
    assert_equal "$before_credentials" "$(jq -Sc --arg id "$xray_id" '.nodes[] | select(.id == $id) | .credentials' "$(manifest_path)")" \
        "unrelated edit preserves credentials"
    run_proxy node edit --id "$xray_id" --address proxy.example
    assert_equal 0 "$RUN_STATUS" "restore guarded public address"
    run_proxy node edit --id "$xray_id" --reality-anti-relay off
    assert_equal 0 "$RUN_STATUS" "disable guard by edit"
    jq -e --arg id "$xray_id" '.nodes[] | select(.id == $id) |
        .tls.reality_guard == {enabled:false,listen_port:null}' "$(manifest_path)" >/dev/null ||
        fail "disabled guard edit state"
    run_proxy node show --id "$xray_id" --uri
    after_uri="$RUN_OUTPUT"
    assert_equal "$before_uri" "$after_uri" "guard disable leaves URI unchanged"
    assert_equal "$before_keys" "$(jq -r --arg id "$xray_id" '.nodes[] | select(.id == $id) |
        .credentials.private_key + ":" + .credentials.public_key + ":" + .credentials.short_id' "$(manifest_path)")" \
        "guard disable leaves REALITY keys unchanged"
    run_proxy node edit --id "$xray_id" --reality-anti-relay on
    assert_equal 0 "$RUN_STATUS" "re-enable guard by edit"
    assert_equal 10005 "$(jq -r --arg id "$xray_id" '.nodes[] | select(.id == $id) | .tls.reality_guard.listen_port' "$(manifest_path)")" \
        "guard re-enable reuses first free port"
    run_proxy node show --id "$xray_id" --uri
    assert_equal "$before_uri" "$RUN_OUTPUT" "guard re-enable leaves URI unchanged"

    run_proxy node edit --id "$xray_id" --sni ReAlItY.ExAmPlE
    assert_equal 0 "$RUN_STATUS" "mixed-case DNS SNI is accepted"
    jq -e --arg id "$xray_id" '
        any(.routing.rules[]; (.inboundTag | index("reality-guard-" + $id)) != null and
            (.domain | index("full:reality.example")) != null)
    ' "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json" >/dev/null ||
        fail "mixed-case SNI exact rule is normalized"
    run_proxy node edit --id "$xray_id" --sni reality.example
    assert_equal 0 "$RUN_STATUS" "restore lowercase guarded SNI"

    cp -p -- "$(manifest_path)" "${TEST_SYSTEM_ROOT}/run/nodes-before-nul.json"
    jq --arg id "$xray_id" '(.nodes[] | select(.id == $id) | .tls.server_name) = "reality\u0000.example"' \
        "$(manifest_path)" >"${TEST_SYSTEM_ROOT}/run/nodes-with-nul.json"
    mv -- "${TEST_SYSTEM_ROOT}/run/nodes-with-nul.json" "$(manifest_path)"
    run_proxy node list --json
    assert_equal 10 "$RUN_STATUS" "manifest guard rejects escaped NUL SNI"
    mv -- "${TEST_SYSTEM_ROOT}/run/nodes-before-nul.json" "$(manifest_path)"

    # Dry-run reports the transition while preserving manifest and rendered config.
    before_manifest="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    before_config="$(sha256sum "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json" | awk '{print $1}')"
    run_proxy --dry-run node edit --id "$xray_id" --reality-anti-relay off
    assert_equal 0 "$RUN_STATUS" "guard edit dry-run"
    assert_contains "$RUN_OUTPUT" "演练" "guard edit dry-run output"
    assert_equal "$before_manifest" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "guard dry-run manifest"
    assert_equal "$before_config" "$(sha256sum "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json" | awk '{print $1}')" "guard dry-run config"

    # Old manifests without reality_guard remain disabled through ordinary edits
    # and are exposed as false by the stable JSON list interface.
    run_proxy node add --profile vless-grpc-reality --core xray --name legacy-reality \
        --port 19103 --address proxy.example --sni reality.example --service-name legacy --reality-anti-relay off
    assert_equal 0 "$RUN_STATUS" "legacy fixture add"
    legacy_id="$(node_id_by_name legacy-reality)"
    jq --arg id "$legacy_id" '(.nodes[] | select(.id == $id) | .tls) |= del(.reality_guard)' \
        "$(manifest_path)" >"${TEST_SYSTEM_ROOT}/run/legacy-nodes.json"
    mv -- "${TEST_SYSTEM_ROOT}/run/legacy-nodes.json" "$(manifest_path)"
    run_proxy node edit --id "$legacy_id" --name legacy-reality-edited
    assert_equal 0 "$RUN_STATUS" "legacy node ordinary edit"
    jq -e --arg id "$legacy_id" '.nodes[] | select(.id == $id) | .tls | has("reality_guard") | not' \
        "$(manifest_path)" >/dev/null || fail "legacy edit unexpectedly enabled or normalized guard"
    run_proxy node list --json
    jq -e --arg id "$legacy_id" '(.nodes[] | select(.id == $id) | .reality_anti_relay) == false' \
        <<<"$RUN_OUTPUT" >/dev/null || fail "legacy node list guard compatibility"
    run_proxy node edit --id "$legacy_id" --reality-anti-relay on
    assert_equal 0 "$RUN_STATUS" "legacy node explicit guard enable"

    # Renderer structure must isolate the auxiliary guard listener on loopback.
    # Guard rules are scoped to reality-guard-ID; relay and IP-policy rules remain
    # scoped to the public node ID.
    run_proxy node show --id "$(node_id_by_name guard-port-owner)" --uri
    assert_equal 0 "$RUN_STATUS" "shared relay fixture URI"
    relay_uri="$RUN_OUTPUT"
    run_proxy relay exit add --name guard-protocol-exit --uri "$relay_uri" \
        --profile shadowsocks-aes-256-gcm --core xray
    assert_equal 0 "$RUN_STATUS" "guarded Xray protocol-exit fixture"
    protocol_id="$(jq -r '.exits[] | select(.name == "guard-protocol-exit") | .id' "$(relay_path)")"
    run_proxy relay bind add --node-id "$xray_id" --exit-id "$protocol_id"
    assert_equal 0 "$RUN_STATUS" "guarded Xray relay binding"
    xray_config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/xray/config.json"
    sb_config="${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/sing-box/config.json"
    jq -e --arg id "$xray_id" --arg sni reality.example --argjson public 10004 --argjson inner 10005 '
        . as $root |
        any(.inbounds[]; .tag == $id and .port == $public and
            .streamSettings.realitySettings.target == ("127.0.0.1:" + ($inner | tostring))) and
        any(.inbounds[]; .tag == ("reality-guard-" + $id) and .protocol == "dokodemo-door" and
            .listen == "127.0.0.1" and .port == $inner and .settings.address == "127.0.0.1" and
            .settings.port == 1 and .settings.network == "tcp" and .sniffing.enabled == true and
            .sniffing.routeOnly == true and (.sniffing.destOverride | index("tls") != null)) and
        any(.routing.rules[]; (.inboundTag | index("reality-guard-" + $id)) != null and
            (.protocol | index("tls")) != null and (.domain | index("full:" + $sni)) != null and
            .outboundTag == ("reality-target-" + $id)) and
        any(.outbounds[]; .tag == ("reality-target-" + $id) and .protocol == "freedom" and
            .settings.redirect == ($sni + ":443")) and
        any(.routing.rules[]; (.inboundTag | index("reality-guard-" + $id)) != null and
            .outboundTag as $tag | any($root.outbounds[]; .tag == $tag and .protocol == "blackhole")) and
        any(.routing.rules[]; (.inboundTag | index($id)) != null and
            .outboundTag as $tag | any($root.outbounds[]; .tag == $tag and .protocol != "blackhole"))
    ' "$xray_config" >/dev/null || fail "Xray guard, target, exact-SNI, block and relay rendering"
    jq -e --arg id "$sb_id" --arg sni reality.example --argjson public 19101 --argjson inner 10006 '
        . as $root |
        any(.inbounds[]; .tag == $id and .listen_port == $public and
            .tls.reality.handshake == {server:"127.0.0.1",server_port:$inner}) and
        any(.inbounds[]; .tag == ("reality-guard-" + $id) and .type == "direct" and
            .listen == "127.0.0.1" and .listen_port == $inner and
            (has("override_address") | not) and (has("override_port") | not)) and
        any(.route.rules[]; (.inbound | index("reality-guard-" + $id)) != null and .action == "sniff" and .timeout == "1s") and
        any(.route.rules[]; (.inbound | index("reality-guard-" + $id)) != null and
            (.protocol | index("tls")) != null and (.domain | index($sni)) != null and
            .outbound == ("reality-target-" + $id) and .override_address == $sni and .override_port == 443) and
        any(.outbounds[]; .tag == ("reality-target-" + $id) and .type == "direct" and
            .domain_resolver.server == "local") and
        any(.route.rules[]; (.inbound | index("reality-guard-" + $id)) != null and .action == "reject") and
        any(.route.rules[]; (.inbound | index($id)) != null and
            .outbound == ("direct-" + $id))
    ' "$sb_config" >/dev/null || fail "sing-box guard, target, exact-SNI, reject and IP-policy rendering"

    # Deleting a guarded node releases its inner port for deterministic reuse.
    run_proxy node delete --id "$legacy_id" --confirm-delete
    assert_equal 0 "$RUN_STATUS" "guarded legacy node delete"
    run_proxy node delete --id "$xray_id" --cascade-relay --confirm-delete
    assert_equal 0 "$RUN_STATUS" "guarded Xray node delete with binding"
    run_proxy node add --profile shadowsocks-aes-256-gcm --core xray --name released-public-owner \
        --port 10004 --address proxy.example
    assert_equal 0 "$RUN_STATUS" "occupy deleted node public port before guard reuse"
    run_proxy node add --profile vless-reality-vision --core xray --name replacement-reality \
        --port 19104 --address proxy.example --sni reality.example
    assert_equal 0 "$RUN_STATUS" "replacement guarded node add"
    replacement_id="$(node_id_by_name replacement-reality)"
    assert_equal 10005 "$(jq -r --arg id "$replacement_id" '.nodes[] | select(.id == $id) | .tls.reality_guard.listen_port' "$(manifest_path)")" \
        "deleted guard port becomes reusable"

    # Guard metadata and render state participate in core-switch rollback.
    manifest_hash="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    relay_hash="$(sha256sum "$(relay_path)" | awk '{print $1}')"
    xray_hash="$(sha256sum "$xray_config" | awk '{print $1}')"
    sb_hash="$(sha256sum "$sb_config" | awk '{print $1}')"
    touch "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-xray.service"
    touch "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-sing-box.service"
    touch "${TEST_SYSTEM_ROOT}/run/fail-service-restart-once"
    run_proxy node core set --id "$replacement_id" --core sing-box --confirm-disruptive
    assert_equal 20 "$RUN_STATUS" "guarded core-switch restart failure"
    assert_equal "$manifest_hash" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "guarded switch rollback manifest"
    assert_equal "$relay_hash" "$(sha256sum "$(relay_path)" | awk '{print $1}')" "guarded switch rollback relay"
    assert_equal "$xray_hash" "$(sha256sum "$xray_config" | awk '{print $1}')" "guarded switch rollback Xray config"
    assert_equal "$sb_hash" "$(sha256sum "$sb_config" | awk '{print $1}')" "guarded switch rollback sing-box config"

    run_proxy node core set --id "$replacement_id" --core sing-box --confirm-disruptive
    assert_equal 0 "$RUN_STATUS" "guarded core switch"
    jq -e --arg id "$replacement_id" '.nodes[] | select(.id == $id) |
        .core == "sing-box" and .tls.reality_guard == {enabled:true,listen_port:10005}' \
        "$(manifest_path)" >/dev/null || fail "guarded core switch state"
    jq -e --arg id "$replacement_id" '
        any(.inbounds[]; .tag == ("reality-guard-" + $id)) and
        any(.outbounds[]; .tag == ("reality-target-" + $id))
    ' "$sb_config" >/dev/null || fail "guarded core switch target rendering"
}

test_hy2_runtime_lifecycle() {
    local init id exit_id forward_id before state service
    for init in systemd openrc; do
        reset_root
        export VPSCTL_ENV_INIT="$init"
        install_external sing-box
        state="${TEST_SYSTEM_ROOT}/run/mock-${init}"
        if [[ "$init" == systemd ]]; then service=vpsctl-proxy-forward.service; else service=vpsctl-proxy-forward; fi
        run_proxy node add --profile hysteria2 --core sing-box --name hopping --port 39400 --hop-ports 39400-39405,39500-39600 --address proxy.example --cert-mode self-signed
        assert_equal 0 "$RUN_STATUS" "$init hop-only node add"
        id="$(node_id_by_name hopping)"
        [[ -f "$state/enabled-$service" && -f "$state/active-$service" ]] || fail "$init hopping runtime not active/enabled"
        [[ ! -e "$(relay_path)" ]] || fail "hop-only created relay manifest"
        [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" ]] || fail "hop-only created DNS cache"
        [[ ! -e "${TEST_SYSTEM_ROOT}/etc/sysctl.d/90-vpsctl-proxy-forward.conf" ]] || fail "hop-only enabled forwarding sysctl"
        assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'fib daddr type local udp dport { 39401-39405,39500-39600 } counter redirect to :39400' "compact redirect excludes base"
        assert_not_contains "$(cat "${TEST_SYSTEM_ROOT}/run/last-nft.batch")" 'hook forward' "hop-only has no FORWARD chain"
        : >"$MOCK_LOG"
        run_proxy node edit --id "$id" --name hopping-renamed
        assert_equal 0 "$RUN_STATUS" "$init hop node name edit"
        assert_not_contains "$(cat "$MOCK_LOG")" 'enable --now vpsctl-proxy-forward.service' "ordinary hop edit does not reinstall systemd runtime"
        assert_not_contains "$(cat "$MOCK_LOG")" 'rc-update add vpsctl-proxy-forward' "ordinary hop edit does not reinstall OpenRC runtime"
        run_proxy relay status --json
        assert_equal 0 "$RUN_STATUS" "$init hop runtime status"
        jq -e '.forward_runtime | .installed and .active and .enabled and .hop_count == 1 and .forward_count == 0' <<<"$RUN_OUTPUT" >/dev/null || fail "hop-only runtime status counts"
        rm -f "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_hy2_4" "${TEST_SYSTEM_ROOT}/run/mock-nft/ip6-vpsctl_proxy_hy2_6"
        run_proxy relay forward refresh
        assert_equal 0 "$RUN_STATUS" "$init hop-only boot refresh"
        [[ -f "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_hy2_4" ]] || fail "boot refresh omitted hops"
        before="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
        touch "${TEST_SYSTEM_ROOT}/run/fail-nft-apply-once"
        run_proxy node edit --id "$id" --hop-ports 39700-39705
        assert_equal 20 "$RUN_STATUS" "$init nft failure aborts hop edit"
        assert_equal "$before" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "nft failure restores node manifest"
        [[ -f "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_hy2_4" ]] || fail "nft rollback lost hop table"
        run_proxy relay exit add --name hop-test-exit --target 198.51.100.80 --target-port 443
        assert_equal 0 "$RUN_STATUS" "$init relay exit for coexistence"
        exit_id="$(jq -r '.exits[0].id' "$(relay_path)")"
        run_proxy relay forward add --name hop-overlap-tcp --exit-id "$exit_id" --listen-ports 39500 --network tcp --address proxy.example
        assert_equal 0 "$RUN_STATUS" "$init TCP forwarding may overlap hop port"
        forward_id="$(jq -r '.forwards[0].id' "$(relay_path)")"
        run_proxy relay forward add --name hop-overlap-udp --exit-id "$exit_id" --listen-ports 39501 --network udp --address proxy.example
        [[ "$RUN_STATUS" != 0 ]] || fail "UDP forwarding overlaps hops"
        run_proxy node edit --id "$id" --hop-ports off
        assert_equal 0 "$RUN_STATUS" "$init last hop off keeps forwarding"
        [[ -f "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_forward4" && -f "$state/enabled-$service" ]] || fail "last hop off removed forwarding runtime"
        [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_hy2_4" ]] || fail "hop off retained hop rules"
        run_proxy node edit --id "$id" --hop-ports 39400-39405,39500-39600
        assert_equal 0 "$RUN_STATUS" "$init restore hops beside TCP forwarding"
        run_proxy relay forward delete --id "$forward_id" --confirm-delete
        assert_equal 0 "$RUN_STATUS" "$init last forwarding removal keeps hop"
        [[ -f "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_hy2_4" && -f "$state/enabled-$service" ]] || fail "last forward deletion removed hopping runtime"
        run_proxy node delete --id "$id" --confirm-delete
        assert_equal 0 "$RUN_STATUS" "$init last hop delete"
        [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_hy2_4" && ! -e "$state/enabled-$service" ]] || fail "last hop deletion retained rules/service"
    done
    export VPSCTL_ENV_INIT=systemd
    reset_root
    install_external sing-box
    printf '39500\n' >"${TEST_SYSTEM_ROOT}/run/listening-udp-port"
    run_proxy node add --profile hysteria2 --core sing-box --name occupied-hop --port 39400 --hop-ports 39500-39502 --address proxy.example --cert-mode self-signed
    assert_equal 3 "$RUN_STATUS" "UDP system socket rejects hop candidate"
    rm -f "${TEST_SYSTEM_ROOT}/run/listening-udp-port"
    touch "${TEST_SYSTEM_ROOT}/run/fail-service-enable"
    run_proxy node add --profile hysteria2 --core sing-box --name failed-hop --port 39400 --hop-ports 39500-39502 --address proxy.example --cert-mode self-signed
    assert_equal 20 "$RUN_STATUS" "runtime enable failure rolls back first hop"
    assert_equal 0 "$(jq '.nodes | length' "$(manifest_path)")" "failed runtime setup restores empty nodes"
    [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_hy2_4" ]] || fail "failed runtime setup retained hop table"
    rm -f "${TEST_SYSTEM_ROOT}/run/fail-service-enable"
    run_proxy node add --profile hysteria2 --core sing-box --name hop-core-rollback --listen 203.0.113.10 --port 39400 --hop-ports 39500-39502 --address proxy.example --cert-mode self-signed
    assert_equal 0 "$RUN_STATUS" "explicit listen hop add"
    assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'ip daddr 203.0.113.10 udp dport { 39500-39502 } counter dnat to 203.0.113.10:39400' "explicit listen preserves destination address"
    id="$(node_id_by_name hop-core-rollback)"
    run_proxy start --core sing-box
    assert_equal 0 "$RUN_STATUS" "start hop core"
    before="$(sha256sum "$(manifest_path)" | awk '{print $1}')"
    touch "${TEST_SYSTEM_ROOT}/run/fail-nft-list-tables"
    run_proxy node edit --id "$id" --hop-ports 39600-39605
    assert_equal 20 "$RUN_STATUS" "snapshot enumeration failure aborts hop edit"
    assert_equal "$before" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "snapshot failure leaves node declaration unchanged"
    rm -f "${TEST_SYSTEM_ROOT}/run/fail-nft-list-tables"
    touch "${TEST_SYSTEM_ROOT}/run/fail-service-restart-once"
    run_proxy node edit --id "$id" --hop-ports 39600-39605
    assert_equal 20 "$RUN_STATUS" "core restart failure rolls back hop edit"
    assert_equal "$before" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "pending rollback restores hop declaration"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_hy2_4" ]] || fail "pending rollback lost hop rule table"
    touch "${TEST_SYSTEM_ROOT}/run/fail-nft-apply-once"
    run_proxy uninstall --core sing-box --purge --confirm-purge
    assert_equal 20 "$RUN_STATUS" "purge nft failure restores stopped core"
    assert_equal "$before" "$(sha256sum "$(manifest_path)" | awk '{print $1}')" "failed purge restores hop declaration"
    [[ -f "${TEST_SYSTEM_ROOT}/run/mock-systemd/active-vpsctl-proxy-sing-box.service" ]] || fail "failed purge did not restart original core"
    run_proxy uninstall --core sing-box --purge --confirm-purge
    assert_equal 0 "$RUN_STATUS" "purge removes final hop"
    [[ ! -e "${TEST_SYSTEM_ROOT}/run/mock-nft/ip-vpsctl_proxy_hy2_4" ]] || fail "purge retained hop table"
}

# Shared manifest rollback must restore the failed core without undoing later
# successful work owned by the other core or standalone forwarding commands.
core_pending_ok() {
    run_proxy "$@"
    assert_equal 0 "$RUN_STATUS" "core pending fixture: $*"
}

core_pending_update() {
    local version=v26.3.27
    [[ "$1" != sing-box ]] || version=v1.12.0
    set_release_scenario default
    core_pending_ok update --core "$1" --version "$version" --confirm-external-update
}

core_pending_files() {
    sha256sum "${TEST_SYSTEM_ROOT}/etc/vpsctl/proxy/$1/config.json" \
        "${TEST_SYSTEM_ROOT}/usr/bin/$1" \
        "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/cores/$1.json"
}

core_pending_snapshot() {
    local core
    sha256sum "$(manifest_path)" \
        "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/network/ufw/state.json"
    [[ ! -f "$(relay_path)" ]] || sha256sum "$(relay_path)"
    for core in xray sing-box; do
        core_pending_files "$core"
        [[ ! -f "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/$core.json" ]] || \
            sha256sum "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/$core.json"
    done
}

core_pending_owner() {
    jq -Sc --arg owner "node:$1" '[.requirements[] | select(.owner == $owner)]' \
        "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/network/ufw/state.json"
}

core_pending_restart_fails() {
    touch "${TEST_SYSTEM_ROOT}/run/fail-service-restart-once"
    run_proxy restart --core "$1" --confirm-disruptive
    assert_equal "${2:-20}" "$RUN_STATUS" "$1 failed restart rollback"
}

test_core_pending_isolation() {
    local a b both aid bid delete_id keep_id a_nodes a_files a_dns b_nodes b_files b_dns b_pending b_owner
    for a in xray sing-box; do
        b=sing-box; [[ "$a" != sing-box ]] || b=xray
        for both in 0 1; do
            printf 'TEST: pending isolation %s, other pending=%s\n' "$a" "$both"
            reset_root
            install_external xray
            install_external sing-box 1.12.0
            core_pending_ok node add --profile shadowsocks-aes-256-gcm --core "$a" --name a-original --port 19001 --address proxy.example
            core_pending_ok node add --profile shadowsocks-aes-256-gcm --core "$b" --name b-edit --port 19002 --address proxy.example
            core_pending_ok node add --profile shadowsocks-aes-256-gcm --core "$b" --name b-delete --port 19003 --address proxy.example
            aid="$(node_id_by_name a-original)"; bid="$(node_id_by_name b-edit)"; delete_id="$(node_id_by_name b-delete)"
            core_pending_ok dns set --core sing-box --mode udp --server 1.1.1.1
            a_nodes="$(jq -Sc --arg core "$a" '[.nodes[] | select(.core == $core)]' "$(manifest_path)")"
            a_dns="$(jq -Sc '.settings.sing_box // null' "$(manifest_path)")"
            a_files="$(core_pending_files "$a")"
            core_pending_update "$a"
            core_pending_ok node edit --id "$aid" --name a-pending --port 19011
            if [[ "$a" == sing-box ]]; then core_pending_ok dns set --mode tcp --server 9.9.9.9; fi
            if ((both)); then core_pending_update "$b"; fi
            core_pending_ok node edit --id "$bid" --name b-committed --port 19012
            core_pending_ok node delete --id "$delete_id" --confirm-delete
            core_pending_ok node add --profile shadowsocks-aes-256-gcm --core "$b" --name b-added --port 19004 --address proxy.example
            keep_id="$(node_id_by_name b-added)"
            if [[ "$b" == sing-box ]]; then core_pending_ok dns set --mode doh --server 1.0.0.1; fi
            b_nodes="$(jq -Sc --arg core "$b" '[.nodes[] | select(.core == $core)]' "$(manifest_path)")"
            b_dns="$(jq -Sc '.settings.sing_box // null' "$(manifest_path)")"
            b_files="$(core_pending_files "$b")"
            b_owner="$(core_pending_owner "$keep_id")"
            b_pending=''; if ((both)); then b_pending="$(sha256sum "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/$b.json")"; fi
            core_pending_restart_fails "$a"
            assert_equal "$a_nodes" "$(jq -Sc --arg core "$a" '[.nodes[] | select(.core == $core)]' "$(manifest_path)")" "$a original nodes restored"
            assert_equal "$a_files" "$(core_pending_files "$a")" "$a config binary and metadata restored"
            assert_equal "$b_nodes" "$(jq -Sc --arg core "$b" '[.nodes[] | select(.core == $core)]' "$(manifest_path)")" "$b later CRUD preserved"
            assert_equal "$b_files" "$(core_pending_files "$b")" "$b files preserved"
            assert_equal "$b_owner" "$(core_pending_owner "$keep_id")" "$b UFW owner preserved"
            [[ "$b_owner" != '[]' ]] || fail 'later node has no UFW requirements'
            if [[ "$a" == sing-box ]]; then
                assert_equal "$a_dns" "$(jq -Sc '.settings.sing_box // null' "$(manifest_path)")" 'failed sing-box DNS restored'
            else
                assert_equal "$b_dns" "$(jq -Sc '.settings.sing_box // null' "$(manifest_path)")" 'later sing-box DNS preserved'
            fi
            [[ ! -e "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/$a.json" ]] || fail 'successful rollback retained failed core pending'
            if ((both)); then
                assert_equal "$b_pending" "$(sha256sum "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/$b.json")" 'other core pending preserved'
            fi
        done
    done
}

test_core_pending_relay_merge() {
    local a b aid bid uri aexit bexit direct forward before_forward later_relay b_files original_exit
    for a in xray sing-box; do
        b=sing-box; [[ "$a" != sing-box ]] || b=xray
        printf 'TEST: pending shared relay merge %s\n' "$a"
        reset_root
        install_external "$a"; install_external "$b"
        core_pending_ok node add --profile shadowsocks-aes-256-gcm --core "$a" --name relay-a --port 19101 --address proxy.example
        core_pending_ok node add --profile shadowsocks-aes-256-gcm --core "$b" --name relay-b --port 19102 --address proxy.example
        aid="$(node_id_by_name relay-a)"; bid="$(node_id_by_name relay-b)"
        core_pending_ok node show --id "$aid" --uri; uri="$RUN_OUTPUT"
        core_pending_ok relay exit add --name exit-a --uri "$uri" --profile shadowsocks-aes-256-gcm --core "$a"
        aexit="$(jq -r '.exits[] | select(.name == "exit-a") | .id' "$(relay_path)")"
        original_exit="$(jq -Sc --arg id "$aexit" '.exits[] | select(.id == $id)' "$(relay_path)")"
        core_pending_update "$a"
        core_pending_ok relay bind add --node-id "$aid" --exit-id "$aexit"
        core_pending_ok relay exit edit --id "$aexit" --name a-stage --uri "${uri/proxy.example/stage.example}" --profile shadowsocks-aes-256-gcm --core "$a"
        core_pending_ok relay exit edit --id "$aexit" --name a-pending --uri "${uri/proxy.example/pending.example}" --profile shadowsocks-aes-256-gcm --core "$a"
        # The add/delete pair cancels; the replacement binding was also absent originally.
        core_pending_ok relay bind delete --id "$(jq -r --arg id "$aid" '.bindings[] | select(.node_id == $id) | .id' "$(relay_path)")" --confirm-delete
        core_pending_ok relay bind add --node-id "$aid" --exit-id "$aexit"
        core_pending_ok node show --id "$bid" --uri; uri="$RUN_OUTPUT"
        core_pending_ok relay exit add --name exit-b --uri "$uri" --profile shadowsocks-aes-256-gcm --core "$b"
        bexit="$(jq -r '.exits[] | select(.name == "exit-b") | .id' "$(relay_path)")"
        core_pending_ok relay bind add --node-id "$bid" --exit-id "$bexit"
        core_pending_ok relay exit add --name standalone --target 198.51.100.50 --target-port 443
        direct="$(jq -r '.exits[] | select(.name == "standalone") | .id' "$(relay_path)")"
        core_pending_ok relay forward add --name later-forward --exit-id "$direct" --listen-ports 19200 --network tcp --address relay.example
        later_relay="$(jq -Sc --arg id "$aid" --arg exit "$aexit" --argjson original "$original_exit" '.bindings |= map(select(.node_id != $id)) | (.exits[] | select(.id == $exit)) = $original' "$(relay_path)")"
        b_files="$(core_pending_files "$b")"
        core_pending_restart_fails "$a"
        assert_equal "$later_relay" "$(jq -Sc . "$(relay_path)")" 'rollback removes only pending binding'
        assert_equal "$b_files" "$(core_pending_files "$b")" 'other core bound config preserved'
        assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'tcp dport 19200' 'later standalone forward runtime preserved'

        # A cascade deletion journals the exit, its binding, and its forward.
        core_pending_ok relay bind add --node-id "$aid" --exit-id "$aexit"
        printf '198.51.100.60\n' >"${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-proxy.example"
        core_pending_ok relay forward add --name affected-forward --exit-id "$aexit" --listen-ports 19210 --network tcp --address relay.example
        forward="$(jq -r '.forwards[] | select(.name == "affected-forward") | .id' "$(relay_path)")"
        before_forward="$(jq -Sc --arg id "$forward" '.forwards[] | select(.id == $id)' "$(relay_path)")"
        core_pending_update "$a"
        core_pending_ok relay exit delete --id "$aexit" --cascade --confirm-cascade
        core_pending_ok relay forward edit --id "$(jq -r '.forwards[] | select(.name == "later-forward") | .id' "$(relay_path)")" --listen-ports 19201
        # The restored hostname can use its matching pre-cascade DNS cache.
        rm -f -- "${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-proxy.example"
        core_pending_restart_fails "$a"
        assert_equal "$before_forward" "$(jq -Sc --arg id "$forward" '.forwards[] | select(.id == $id)' "$(relay_path)")" 'cascade forward restored'
        jq -e --arg node "$aid" --arg exit "$aexit" 'any(.exits[]; .id == $exit) and any(.bindings[]; .node_id == $node and .exit_id == $exit) and any(.forwards[]; .name == "later-forward" and .listen_port_start == 19201)' "$(relay_path)" >/dev/null || fail 'cascade lost restored references or later independent forward edit'
        assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'tcp dport 19201' 'merged independent forward applied'
        assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'tcp dport 19210' 'restored cascade forward applied'
        jq -e --arg id "$aexit" '.exits[$id].host == "proxy.example" and .exits[$id].ipv4 == "198.51.100.60"' "${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json" >/dev/null || fail 'matching backup DNS cache not used'
    done
}

test_core_pending_conflicts_and_legacy() {
    local aid pending before exit_id uri
    printf 'TEST: pending restored port conflict\n'
    reset_root
    install_external xray; install_external sing-box
    core_pending_ok node add --profile shadowsocks-aes-256-gcm --core xray --name conflict-a --port 19300 --address proxy.example
    aid="$(node_id_by_name conflict-a)"
    core_pending_update xray
    core_pending_ok node edit --id "$aid" --port 19301
    core_pending_ok node add --profile shadowsocks-aes-256-gcm --core sing-box --name later-occupant --port 19300 --address proxy.example
    before="$(core_pending_snapshot)"
    core_pending_restart_fails xray 30
    assert_equal "$before" "$(core_pending_snapshot)" 'port conflict must fail before writes'

    printf 'TEST: legacy node-only pending merge\n'
    core_pending_ok node delete --id "$(node_id_by_name later-occupant)" --confirm-delete
    pending="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json"
    jq '{schema_version,core,reason,manifest_backup,config_backup,binary_backup,meta_backup,created_at}' "$pending" >"${TEST_TEMP}/pending.json"; cp "${TEST_TEMP}/pending.json" "$pending"
    core_pending_ok node add --profile shadowsocks-aes-256-gcm --core sing-box --name legacy-later --port 19302 --address proxy.example
    core_pending_restart_fails xray
    assert_equal 19300 "$(jq -r --arg id "$aid" '.nodes[] | select(.id == $id) | .port' "$(manifest_path)")" 'legacy pending restored target node'
    [[ -n "$(node_id_by_name legacy-later)" ]] || fail 'legacy node-only pending removed other core node'

    printf 'TEST: relay journal record conflict and unsafe legacy relay\n'
    core_pending_ok node show --id "$aid" --uri; uri="$RUN_OUTPUT"
    core_pending_ok relay exit add --name journal-exit --uri "$uri" --profile shadowsocks-aes-256-gcm --core xray
    exit_id="$(jq -r '.exits[] | select(.name == "journal-exit") | .id' "$(relay_path)")"
    core_pending_update xray
    core_pending_ok relay bind add --node-id "$aid" --exit-id "$exit_id"
    # Simulate another writer changing the same valid binding after its journal.
    jq '(.bindings[0].updated_at) = "2026-09-30T00:00:00Z"' "$(relay_path)" >"${TEST_TEMP}/relay.json"
    cp "${TEST_TEMP}/relay.json" "$(relay_path)"
    before="$(core_pending_snapshot)"
    core_pending_restart_fails xray 30
    assert_equal "$before" "$(core_pending_snapshot)" 'journal conflict must fail before writes'
    jq 'del(.relay_undo)' "$pending" >"${TEST_TEMP}/pending.json"; cp "${TEST_TEMP}/pending.json" "$pending"
    before="$(core_pending_snapshot)"
    core_pending_restart_fails xray 30
    assert_equal "$before" "$(core_pending_snapshot)" 'legacy touched relay divergence must fail before writes'
    printf 'TEST: safe legacy relay already equals backup\n'
    cp "$(jq -r '.relay_backup' "$pending")" "$(relay_path)"
    before="$(jq -Sc . "$(relay_path)")"
    core_pending_restart_fails xray
    assert_equal "$before" "$(jq -Sc . "$(relay_path)")" 'safe legacy relay declaration preserved'
    [[ ! -e "$pending" ]] || fail 'safe legacy rollback retained pending'
}

test_core_pending_runtime_retry() {
    local aid hop_id exit_id cache pending declaration b_files b_owner uri
    printf 'TEST: merged runtime preserves later HY2/cache, failed restore retries\n'
    reset_root
    install_external xray; install_external sing-box
    core_pending_ok node add --profile shadowsocks-aes-256-gcm --core xray --name runtime-a --port 19400 --address proxy.example
    aid="$(node_id_by_name runtime-a)"
    core_pending_ok node show --id "$aid" --uri; uri="$RUN_OUTPUT"
    core_pending_ok relay exit add --name before --uri "$uri" --profile shadowsocks-aes-256-gcm --core xray
    exit_id="$(jq -r '.exits[0].id' "$(relay_path)")"
    core_pending_ok relay bind add --node-id "$aid" --exit-id "$exit_id"
    printf '198.51.100.70\n' >"${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-proxy.example"
    core_pending_ok relay forward add --name before --exit-id "$exit_id" --listen-ports 19410 --network tcp --address relay.example
    # An accepted older exit lacks its URI-derived descriptor. Updating the core
    # normalizes relay declarations without taking a shared runtime snapshot.
    jq 'del(.exits[].descriptor)' "$(relay_path)" >"${TEST_TEMP}/relay.json"
    cp "${TEST_TEMP}/relay.json" "$(relay_path)"
    core_pending_update xray
    pending="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/pending/xray.json"
    jq -e '.relay_touched and (.relay_runtime_touched | not)' "$pending" >/dev/null || fail 'core normalization fixture must touch only relay declarations'
    core_pending_ok node edit --id "$aid" --name runtime-pending
    core_pending_ok relay exit edit --id "$exit_id" --name before-pending --uri "${uri/:19400/:19401}" --profile shadowsocks-aes-256-gcm --core xray
    jq -e '.relay_runtime_touched and .relay_cache_existed and .relay_cache_backup != ""' "$pending" >/dev/null || fail 'later relay edit did not retain first runtime/cache snapshot'
    core_pending_ok node add --profile hysteria2 --core sing-box --name later-hy2 --port 39400 --hop-ports 39500-39502 --address proxy.example --cert-mode self-signed
    hop_id="$(node_id_by_name later-hy2)"
    printf '198.51.100.71\n' >"${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-later.example"
    core_pending_ok relay exit add --name later-cache --target later.example --target-port 8443
    exit_id="$(jq -r '.exits[] | select(.name == "later-cache") | .id' "$(relay_path)")"
    core_pending_ok relay forward add --name later-cache --exit-id "$exit_id" --listen-ports 19411 --network tcp --address relay.example
    cache="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/service/proxy/relay-resolved.json"
    # Later cache entries must survive even when DNS is unavailable at rollback.
    rm -f -- "${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-later.example"
    b_files="$(core_pending_files sing-box)"; b_owner="$(core_pending_owner "$hop_id")"
    rm -f -- "${TEST_SYSTEM_ROOT}/run/dns-ahostsv4-proxy.example"
    touch "${TEST_SYSTEM_ROOT}/run/fail-nft-apply"
    core_pending_restart_fails xray 30
    [[ -f "$pending" ]] || fail 'runtime failure consumed pending rollback'
    declaration="$(jq -Sc . "$(manifest_path)")"
    rm -f -- "${TEST_SYSTEM_ROOT}/run/fail-nft-apply"
    # Retry through the public lifecycle path, which must finish recovery first.
    core_pending_ok restart --core xray --confirm-disruptive
    assert_equal "$declaration" "$(jq -Sc . "$(manifest_path)")" 'retry restore changed merged declaration'
    assert_equal runtime-a "$(jq -r --arg id "$aid" '.nodes[] | select(.id == $id) | .name' "$(manifest_path)")" 'retry restored original Xray node'
    jq -e 'any(.exits[]; .name == "before") and all(.exits[]; .name != "before-pending")' "$(relay_path)" >/dev/null || fail 'retry failed to undo pending exit edit'
    assert_equal "$b_files" "$(core_pending_files sing-box)" 'runtime rollback changed later sing-box files'
    assert_equal "$b_owner" "$(core_pending_owner "$hop_id")" 'runtime rollback changed later HY2 UFW owner'
    jq -e --arg id "$exit_id" '.exits[$id].host == "later.example" and .exits[$id].ipv4 == "198.51.100.71"' "$cache" >/dev/null || fail 'runtime rollback lost later DNS cache'
    assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'redirect to :39400' 'runtime rollback lost later HY2 rules'
    assert_file_contains "${TEST_SYSTEM_ROOT}/run/last-nft.batch" 'tcp dport 19411' 'runtime rollback lost later forward rules'
    [[ ! -e "$pending" ]] || fail 'successful runtime retry retained pending'
    core_pending_ok restart --core xray --confirm-disruptive
    assert_equal "$declaration" "$(jq -Sc . "$(manifest_path)")" 'repeat recovery must be idempotent'
}

test_core_pending() {
    test_core_pending_isolation
    test_core_pending_relay_merge
    test_core_pending_conflicts_and_legacy
    test_core_pending_runtime_retry
}

if [[ "${VPSCTL_PROXY_TEST_HARNESS_ONLY:-0}" == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi

case "${VPSCTL_TEST_ONLY:-}" in
    core-pending) test_core_pending; printf 'PASS: per-core pending rollback regressions\n'; exit 0 ;;
    hy2-runtime) test_hy2_runtime_lifecycle; printf 'PASS: HY2 runtime lifecycle tests\n'; exit 0 ;;
    core-install) test_core_install_autostart; printf 'PASS: proxy install autostart tests\n'; exit 0 ;;
    core-release) test_core_release_channels; printf 'PASS: proxy core release tests\n'; exit 0 ;;
    node-list) test_node_list_bindings_and_text; printf 'PASS: proxy node list tests\n'; exit 0 ;;
    node-ip-policy) test_node_ip_strategy_and_batch; printf 'PASS: node IP policy tests\n'; exit 0 ;;
    relay-state) test_relay_state_bindings_and_purge; printf 'PASS: relay state tests\n'; exit 0 ;;
    relay-xray) test_relay_xray_pending_and_validation; printf 'PASS: relay Xray tests\n'; exit 0 ;;
    relay-conflicts) test_relay_forward_conflicts; printf 'PASS: relay conflict tests\n'; exit 0 ;;
    relay-render) test_relay_forward_render_nft; printf 'PASS: relay render tests\n'; exit 0 ;;
    relay-cache) test_relay_forward_refresh_cache; printf 'PASS: relay cache tests\n'; exit 0 ;;
    relay-forward) test_relay_forwarding_subscription_and_rollback; printf 'PASS: relay forward tests\n'; exit 0 ;;
    relay-family) test_relay_forward_family_modes; printf 'PASS: relay forward family tests\n'; exit 0 ;;
    relay-service) test_relay_forward_service_lifecycle; printf 'PASS: relay service tests\n'; exit 0 ;;
    node-core) test_node_core_switch; printf 'PASS: node core switch tests\n'; exit 0 ;;
    profile-membership) test_profile_membership_pipe_consumption; printf 'PASS: profile membership tests\n'; exit 0 ;;
    reality-anti-relay) test_reality_anti_relay_guard; printf 'PASS: REALITY anti-relay tests\n'; exit 0 ;;
esac

printf 'TEST: proxy arguments, dry-run and time\n'
test_arguments_dry_run_and_time
printf 'TEST: HY2 runtime lifecycle\n'
test_hy2_runtime_lifecycle
printf 'TEST: proxy core release channels\n'
test_core_release_channels
printf 'TEST: proxy install autostart and rollback\n'
test_core_install_autostart
printf 'TEST: proxy dependency installation plans\n'
test_dependency_install_plans
printf 'TEST: proxy status, services and logs\n'
test_status_service_and_logs
printf 'TEST: proxy node list bindings and text fields\n'
test_node_list_bindings_and_text
printf 'TEST: proxy CRUD, pending and validation\n'
test_core_choice_crud_pending_and_validation
printf 'TEST: per-core pending rollback regressions\n'
test_core_pending
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
printf 'TEST: proxy profile membership pipe consumption\n'
test_profile_membership_pipe_consumption
printf 'TEST: proxy protocol renderer matrix\n'
test_protocol_matrix
printf 'TEST: proxy relay state, bindings and purge guards\n'
test_relay_state_bindings_and_purge
printf 'TEST: proxy relay Xray pending and validation\n'
test_relay_xray_pending_and_validation
printf 'TEST: proxy relay forwarding, subscriptions and rollback\n'
test_relay_forward_conflicts
test_relay_forward_render_nft
test_relay_forward_refresh_cache
test_relay_forwarding_subscription_and_rollback
printf 'TEST: proxy relay forward address-family modes\n'
test_relay_forward_family_modes
printf 'TEST: proxy relay service lifecycle and failures\n'
test_relay_forward_service_lifecycle
printf 'TEST: proxy node core switching\n'
test_node_core_switch
printf 'TEST: proxy REALITY anti-relay guard\n'
test_reality_anti_relay_guard
printf 'PASS: service proxy tests\n'
