#!/usr/bin/env bash
# Run only on host-vps-scripts. Exercise consumers independently of bundle parsing.
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TEMP"' EXIT
export VPSCTL_TESTING=1 VPSCTL_NON_INTERACTIVE=1 VPSCTL_DRY_RUN=0
export VPSCTL_ENV_ARCH=x86_64 VPSCTL_ENV_KERNEL_NAME=Linux VPSCTL_ENV_INIT=systemd
export VPSCTL_SYSTEM_ROOT="$TEST_TEMP/root"
mkdir -p "$VPSCTL_SYSTEM_ROOT" "$TEST_TEMP/project/.offline" "$TEST_TEMP/assets" "$TEST_TEMP/out"

# shellcheck source=../../commands/service/iperf3.sh
source "$TEST_ROOT/commands/service/iperf3.sh"
# shellcheck source=../../commands/network/rfw.sh
source "$TEST_ROOT/commands/network/rfw.sh" help >/dev/null
# shellcheck source=../../commands/service/proxy/common.sh
source "$TEST_ROOT/commands/service/proxy/common.sh"
# shellcheck source=../../commands/service/proxy/core.sh
source "$TEST_ROOT/commands/service/proxy/core.sh"
# shellcheck source=../../commands/security/tls/common.sh
source "$TEST_ROOT/commands/security/tls/common.sh"
# shellcheck source=../../commands/security/tls/store.sh
source "$TEST_ROOT/commands/security/tls/store.sh"
# shellcheck source=../../commands/security/tls/issue.sh
source "$TEST_ROOT/commands/security/tls/issue.sh"
vps_cmd_init offline-runtime "$TEST_TEMP/project"
tls_init_paths
PROXY_ARCH=x86_64

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
expect_failure() {
    local status=0
    "$@" >"$TEST_TEMP/failure.log" 2>&1 || status=$?
    [[ "$status" != 0 ]] || fail "unexpected success: $*"
}
curl() {
    printf 'curl\n' >>"$TEST_TEMP/network"
    return 99
}
apt-get() {
    printf 'apt-get\n' >>"$TEST_TEMP/network"
    return 99
}
vps_cmd_require_root() { return 0; }
_proxy_core_is_musl() { return 1; }
tls_ensure_tools() { return 0; }
tls_timer_flags() {
    TLS_TIMER_SUPPORTED=false
    TLS_TIMER_ENABLED=false
    TLS_TIMER_ACTIVE=false
}

declare -A fixture_tags=() fixture_assets=() fixture_hashes=()
register_asset() {
    fixture_tags["$1"]="$2"
    fixture_assets["$1"]="$3"
    fixture_hashes["$1"]="$(sha256sum "$TEST_TEMP/assets/$3")"
    fixture_hashes["$1"]="${fixture_hashes[$1]%%[[:space:]]*}"
}

# The helper owns manifest validation. Its contract returns the original file
# only after validation; failed validation must never cause a consumer download.
vps_offline_component() {
    local component="$1" requested="${2:-}" channel="${3:-stable}" actual
    [[ "$channel" == stable && -n "${fixture_tags[$component]:-}" ]] || return 20
    [[ -z "$requested" || "$requested" == "${fixture_tags[$component]}" ]] || return 20
    VPS_OFFLINE_COMPONENT_TAG="${fixture_tags[$component]}"
    VPS_OFFLINE_COMPONENT_ASSET="${fixture_assets[$component]}"
    VPS_OFFLINE_COMPONENT_SHA256="${fixture_hashes[$component]}"
    VPS_OFFLINE_COMPONENT_PATH="$TEST_TEMP/assets/$VPS_OFFLINE_COMPONENT_ASSET"
    VPS_OFFLINE_COMPONENT_URL="https://github.com/fixture/releases/download/$VPS_OFFLINE_COMPONENT_TAG/$VPS_OFFLINE_COMPONENT_ASSET"
    [[ -f "$VPS_OFFLINE_COMPONENT_PATH" ]] || return 20
    actual="$(sha256sum "$VPS_OFFLINE_COMPONENT_PATH")" || return 20
    [[ "${actual%%[[:space:]]*}" == "$VPS_OFFLINE_COMPONENT_SHA256" ]]
}

vps_offline_apt() {
    printf '%s\n' "$@" >"$TEST_TEMP/apt-args"
    printf '%s' "${DEBIAN_FRONTEND:-}" >"$TEST_TEMP/apt-frontend"
    return "${fixture_apt_status:-0}"
}
vps_cmd_install_packages apt-get curl jq curl
[[ "$(cat "$TEST_TEMP/apt-args")" == $'install\ncurl\njq' ]] || fail 'dependency install missed local APT or deduplication'
fixture_manager=apt-get
vps_cmd_detect_package_manager() { printf '%s' "$fixture_manager"; }
iperf3() { return 0; }
dpkg-query() { printf 'iperf3: /usr/bin/iperf3\n'; }
iperf3_update_package
[[ "$(cat "$TEST_TEMP/apt-args")" == $'upgrade\niperf3' ]] || fail 'iperf3 update missed local APT'
[[ "$(cat "$TEST_TEMP/apt-frontend")" == noninteractive ]] || fail 'iperf3 update lost noninteractive frontend'
fixture_apt_status=20
expect_failure vps_cmd_install_packages apt-get curl
expect_failure iperf3_update_package
fixture_apt_status=0
expect_failure vps_cmd_install_packages dnf curl
fixture_manager=dnf
expect_failure iperf3_update_package
fixture_manager=apt-get

mkdir -p "$TEST_TEMP/archive/sing-box-9.8.7-linux-amd64"
printf '#!/usr/bin/env bash\nprintf "sing-box version 9.8.7\\n"\n' >"$TEST_TEMP/archive/sing-box-9.8.7-linux-amd64/sing-box"
tar -czf "$TEST_TEMP/assets/sing-box-9.8.7-linux-amd64.tar.gz" -C "$TEST_TEMP/archive" sing-box-9.8.7-linux-amd64
register_asset sing-box v9.8.7 sing-box-9.8.7-linux-amd64.tar.gz
_proxy_core_resolve_release sing-box stable '' "$TEST_TEMP/release.json"
jq -e '.tag_name == "v9.8.7" and .prerelease == false' "$TEST_TEMP/release.json" >/dev/null || fail 'snapshot release selection'
_proxy_core_fetch_release sing-box stable v9.8.7 "$TEST_TEMP/out/sing-box" "$TEST_TEMP/info.json" "$TEST_TEMP/release.json"
jq -e '.version == "9.8.7" and .release_tag == "v9.8.7"' "$TEST_TEMP/info.json" >/dev/null || fail 'proxy provenance'
expect_failure _proxy_core_resolve_release sing-box prerelease '' "$TEST_TEMP/rejected.json"
expect_failure _proxy_core_resolve_release sing-box stable v9.8.6 "$TEST_TEMP/rejected.json"
expect_failure _proxy_core_fetch_release sing-box stable v9.8.6 "$TEST_TEMP/out/rejected" "$TEST_TEMP/rejected-info.json" "$TEST_TEMP/release.json"
fixture_tags["sing-box"]=v9.8.6
expect_failure _proxy_core_fetch_release sing-box stable '' "$TEST_TEMP/out/mismatch" "$TEST_TEMP/mismatch-info.json"
fixture_tags["sing-box"]=v9.8.7
printf corrupt >>"$TEST_TEMP/assets/${fixture_assets["sing-box"]}"
expect_failure _proxy_core_fetch_release sing-box stable '' "$TEST_TEMP/out/corrupt" "$TEST_TEMP/corrupt-info.json"

python3 - "$TEST_TEMP/assets/Xray-linux-64.zip" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("xray", '#!/usr/bin/env bash\nprintf "Xray 9.8.7\\n"\n')
PY
register_asset xray v9.8.7 Xray-linux-64.zip
_proxy_core_fetch_release xray stable '' "$TEST_TEMP/out/xray" "$TEST_TEMP/xray-info.json"
jq -e '.version == "9.8.7" and .release_tag == "v9.8.7"' "$TEST_TEMP/xray-info.json" >/dev/null || fail 'Xray provenance'
fixture_tags[xray]=v9.8.6
expect_failure _proxy_core_fetch_release xray stable '' "$TEST_TEMP/out/xray-mismatch" "$TEST_TEMP/xray-mismatch-info.json"

printf '#!/usr/bin/env bash\nprintf "rfw 9.8.7\\n"\n' >"$TEST_TEMP/assets/rfw-x86_64-unknown-linux-musl"
register_asset rfw v9.8.7 rfw-x86_64-unknown-linux-musl
rfw_fetch_binary "$TEST_TEMP/out/rfw"
[[ "$RFW_FETCHED_TAG" == v9.8.7 && "$RFW_FETCHED_SHA256" == "${fixture_hashes[rfw]}" ]] || fail 'RFW provenance'
fixture_tags[rfw]=v9.8.6
expect_failure rfw_fetch_binary "$TEST_TEMP/out/rfw-mismatch"
fixture_tags[rfw]=v9.8.7
mv "$TEST_TEMP/assets/${fixture_assets[rfw]}" "$TEST_TEMP/assets/rfw.saved"
expect_failure rfw_fetch_binary "$TEST_TEMP/out/rfw-missing"

printf '#!/usr/bin/env bash\nprintf "lego version 9.8.7\\n"\n' >"$TEST_TEMP/archive/lego"
tar -czf "$TEST_TEMP/assets/lego_v9.8.7_linux_amd64.tar.gz" -C "$TEST_TEMP/archive" lego
register_asset lego v9.8.7 lego_v9.8.7_linux_amd64.tar.gz
tls_install_lego
tls_lego_installed || fail 'new snapshot lego reported missing'
[[ "$(tls_kv_get "$TLS_LEGO_META" tag)" == v9.8.7 ]] || fail 'lego recorded pinned tag'
tls_status 1 | jq -e '.lego_installed == true and .lego_version == "v9.8.7"' >/dev/null || fail 'lego status lost snapshot version'
sed -i 's/tag=v9.8.7/tag=v5.4.1/' "$TLS_LEGO_META"
tls_lego_installed || fail 'legacy lego metadata rejected'
tls_install_lego
[[ "$(tls_kv_get "$TLS_LEGO_META" tag)" == v9.8.7 ]] || fail 'older lego was not updated to snapshot'
printf corrupt >>"$TLS_LEGO_BIN"
expect_failure tls_lego_installed
printf corrupt >>"$TEST_TEMP/assets/${fixture_assets[lego]}"
expect_failure tls_install_lego

mkdir -p "$TEST_TEMP/minimal/lib" "$TEST_TEMP/minimal/.offline"
cp -- "$TEST_ROOT/lib/command.sh" "$TEST_ROOT/lib/ui.sh" "$TEST_TEMP/minimal/lib/"
# shellcheck disable=SC2016 # This script is evaluated by the fixture subprocess.
expect_failure bash -c '
    source "$1/lib/command.sh"
    vps_cmd_init missing-helper "$1"
    vps_cmd_require_root() { return 0; }
    test_network="$2/network"
    apt-get() { printf "apt-get\n" >>"$test_network"; return 99; }
    vps_cmd_install_packages apt-get curl
' bash "$TEST_TEMP/minimal" "$TEST_TEMP"

[[ ! -e "$TEST_TEMP/network" ]] || fail 'offline resource failure fell back to network'
printf 'PASS: offline runtime consumers, snapshot versions, and no network fallback\n'
