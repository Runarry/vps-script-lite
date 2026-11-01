#!/usr/bin/env bash
# Only manager installation paths are changed; no feature services are started.
# shellcheck disable=SC1091,SC2034
set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
RELEASE_VERSION="$(<"$TEST_ROOT/VERSION")"
NEXT_VERSION="${RELEASE_VERSION%.*}.$((10#${RELEASE_VERSION##*.} + 1))"
ENTRY=/usr/local/bin/vpsctl
INSTALL_ROOT=/usr/local/lib/vpsctl
SELF_ROOT=/var/lib/vpsctl/self
((EUID == 0)) || { printf 'FAIL: requires root on dedicated acceptance host\n' >&2; exit 4; }
[[ "$(uname -s)" == Linux ]] || { printf 'FAIL: requires Linux\n' >&2; exit 3; }
TEST_TEMP="$(mktemp -d /root/vpsctl-offline-distribution-real.XXXXXX)"
BACKUP="$TEST_TEMP/baseline"
mkdir -p "$BACKUP" "$TEST_TEMP/mock-bin"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
sha_file() { sha256sum -- "$1" | awk '{print $1}'; }

manager_snapshot() {
    local path
    for path in "$ENTRY" "$INSTALL_ROOT" "$SELF_ROOT"; do
        if [[ -e "$path" || -L "$path" ]]; then
            find "$path" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
            find "$path" -type l -printf '%p -> %l\n' | LC_ALL=C sort
        else
            printf 'ABSENT %s\n' "$path"
        fi
    done
}
manager_snapshot >"$TEST_TEMP/before"
for path in "$ENTRY" "$INSTALL_ROOT" "$SELF_ROOT"; do
    if [[ -e "$path" || -L "$path" ]]; then cp -a --parents -- "$path" "$BACKUP"; fi
done
cleanup() {
    local status=$? path restore_status=0
    trap - EXIT
    for path in "$ENTRY" "$INSTALL_ROOT" "$SELF_ROOT"; do
        rm -rf -- "$path" || restore_status=1
        if [[ -e "$BACKUP$path" || -L "$BACKUP$path" ]]; then
            mkdir -p -- "${path%/*}" || restore_status=1
            cp -a -- "$BACKUP$path" "$path" || restore_status=1
        fi
    done
    manager_snapshot >"$TEST_TEMP/after"
    cmp -s "$TEST_TEMP/before" "$TEST_TEMP/after" || restore_status=1
    if [[ "$restore_status" == 0 ]]; then
        printf 'PASS: manager entry, releases and self metadata baseline restored\n'
        rm -rf -- "$TEST_TEMP"
    else
        printf 'FAIL: manager restoration incomplete; recovery material: %s\n' "$TEST_TEMP" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
rm -rf -- "$ENTRY" "$INSTALL_ROOT" "$SELF_ROOT"
unset VPSCTL_TESTING VPSCTL_SYSTEM_ROOT VPSCTL_PROJECT_ROOT VPSCTL_INSTALL_ROOT VPSCTL_SELF_STATE_ROOT VPSCTL_MANAGED_ENTRY VPSCTL_DISTRIBUTED

bash "$TEST_ROOT/tests/unit/test-offline-distribution.sh" --fixtures "$TEST_TEMP/packages"
PACKAGE="$TEST_TEMP/packages/current"
NEXT="$TEST_TEMP/packages/next"
cat >"$TEST_TEMP/mock-bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
destination='' url=''
while (($#)); do
    case "$1" in
        --output | -o) destination="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" >>"${VPSCTL_TEST_DOWNLOAD_TRACE:?}"
[[ "${VPSCTL_TEST_NETWORK_DENY:-1}" == 0 ]] || exit 77
[[ "$url" == https://github.com/Runarry/vps-script-lite/releases/* && -n "$destination" ]] || exit 78
cp -- "${VPSCTL_TEST_ASSET_DIR:?}/${url##*/}" "$destination"
CURL
chmod 0755 "$TEST_TEMP/mock-bin/curl"
export PATH="$TEST_TEMP/mock-bin:$PATH"
export VPSCTL_TEST_DOWNLOAD_TRACE="$TEST_TEMP/downloads"
export VPSCTL_TEST_ASSET_DIR="$PACKAGE"
export VPSCTL_TEST_NETWORK_DENY=1
: >"$VPSCTL_TEST_DOWNLOAD_TRACE"

assert_full_offline_release() {
    local root="$INSTALL_ROOT/current" bundle
    [[ -f "$root/.offline/SHA256SUMS" && -f "$root/.release/offline.sha256" ]] || fail 'local package was not retained'
    [[ "$(<"$root/.release/offline.sha256")" == "$(sha_file "$root/.offline/SHA256SUMS")" ]] || fail 'retained package anchor differs'
    (
        source "$root/lib/distribution.sh"
        vps_distribution_parse_manifest "$root/.release/manifest.tsv"
        for bundle in "${VPS_BUNDLE_IDS[@]}"; do
            [[ -f "$root/.bundles/$bundle.sha256" && "$(<"$root/.bundles/$bundle.sha256")" == "${VPS_DISTRIBUTION_BUNDLE_SHA256[$bundle]}" ]] || fail "full offline marker missing: $bundle"
        done
    )
    [[ ! -s "$VPSCTL_TEST_DOWNLOAD_TRACE" ]] || fail 'offline operation attempted network access'
}

# Public bootstrap must install an entire package without network access.
cp -a -- "$PACKAGE" "$TEST_TEMP/extracted"
bash "$TEST_ROOT/vpsctl.sh" --offline-dir "$TEST_TEMP/extracted" --version >"$TEST_TEMP/fresh.log"
[[ "$(<"$INSTALL_ROOT/current/VERSION")" == "$RELEASE_VERSION" ]] || fail 'fresh bootstrap version mismatch'
assert_full_offline_release
rm -rf -- "$TEST_TEMP/extracted"
"$ENTRY" --version >"$TEST_TEMP/deleted-source.log"
(
    export VPSCTL_DISTRIBUTED=1 VPSCTL_PROJECT_ROOT="$INSTALL_ROOT/releases/$RELEASE_VERSION"
    source "$VPSCTL_PROJECT_ROOT/lib/distribution.sh"
    vps_registry_init
    vps_distribution_remove_command_cache network:bbr
)
[[ ! -e "$INSTALL_ROOT/current/commands/network/bbr.sh" ]] || fail 'feature eviction failed'
"$ENTRY" --non-interactive network bbr --help >"$TEST_TEMP/reload.log"
[[ -f "$INSTALL_ROOT/current/commands/network/bbr.sh" ]] || fail 'local feature reload failed'
[[ ! -s "$VPSCTL_TEST_DOWNLOAD_TRACE" ]] || fail 'feature reload used network'
printf 'PASS: fresh public offline bootstrap and cache reload after source deletion\n'

# Establish a real online install, including the original lazy download boundary.
rm -rf -- "$ENTRY" "$INSTALL_ROOT" "$SELF_ROOT"
export VPSCTL_TEST_NETWORK_DENY=0
bash "$PACKAGE/vpsctl.sh" --version >"$TEST_TEMP/online.log"
[[ "$(wc -l <"$VPSCTL_TEST_DOWNLOAD_TRACE")" == 3 ]] || fail 'online bootstrap did not fetch exactly manifest, launcher, core'
[[ ! -e "$INSTALL_ROOT/current/.offline" && ! -e "$INSTALL_ROOT/current/commands/network/bbr.sh" ]] || fail 'online install lost lazy behavior'
: >"$VPSCTL_TEST_DOWNLOAD_TRACE"
export VPSCTL_TEST_NETWORK_DENY=1
bash "$TEST_ROOT/vpsctl.sh" --offline-dir "$PACKAGE" --version >"$TEST_TEMP/hydrate.log"
assert_full_offline_release
printf 'PASS: online lazy bootstrap and same-version offline hydration before installed fast path\n'

# Invalid package arguments must still be validated when an installation exists.
before="$(readlink "$INSTALL_ROOT/current")"
if bash "$TEST_ROOT/vpsctl.sh" --offline-dir "$TEST_TEMP/missing-package" --version >"$TEST_TEMP/missing.log" 2>&1; then
    fail 'installed fast path silently ignored invalid --offline-dir'
fi
[[ "$(readlink "$INSTALL_ROOT/current")" == "$before" ]] || fail 'invalid package changed current'
if "$ENTRY" --yes self update --offline-dir "$NEXT" --version "v$NEXT_VERSION" >"$TEST_TEMP/conflict.log" 2>&1; then
    fail 'self update accepted offline-dir with version'
fi
[[ "$(readlink "$INSTALL_ROOT/current")" == "$before" ]] || fail 'conflicting update flags changed current'
"$ENTRY" --yes --non-interactive self update --offline-dir "$NEXT" >"$TEST_TEMP/update.log"
[[ "$(<"$INSTALL_ROOT/current/VERSION")" == "$NEXT_VERSION" ]] || fail 'offline CLI self update did not activate target version'
assert_full_offline_release
"$ENTRY" --version >"$TEST_TEMP/updated-entry.log"
printf 'PASS: invalid installed-path import rejected, conflicting flags rejected, public offline cross-version update\n'
printf 'PASS: offline distribution real acceptance\n'
