#!/usr/bin/env bash
# Importer acceptance uses real release bundles; upstream assets are inert fixtures.
# shellcheck disable=SC1091,SC2030,SC2031,SC2317
set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TEMP"' EXIT
RELEASE_VERSION="$(<"$TEST_ROOT/VERSION")"
NEXT_VERSION="${RELEASE_VERSION%.*}.$((10#${RELEASE_VERSION##*.} + 1))"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
sha_file() { sha256sum -- "$1" | awk '{print $1}'; }
rehash() (
    cd -- "$1"
    find . -type f ! -path ./SHA256SUMS -printf '%P\n' | LC_ALL=C sort |
        while IFS= read -r file; do sha256sum -- "$file"; done >SHA256SUMS
)

make_package() {
    local destination="$1" version="$2" source_root="$TEST_TEMP/source-$2" component asset digest size ID VERSION_ID
    mkdir -p "$source_root" "$destination"
    cp -a -- "$TEST_ROOT"/{VERSION,vpsctl.sh,bin,lib,commands,scripts} "$source_root/"
    printf '%s\n' "$version" >"$source_root/VERSION"
    bash "$source_root/scripts/build-release.sh" "$destination" >/dev/null
    # Match the dedicated host rather than spoofing a supported platform.
    # shellcheck disable=SC1091
    source /etc/os-release
    printf 'schema_version\t1\nversion\t%s\nos\t%s\nos_version\t%s\narchitecture\t%s\nbuilt_at\t2026-11-01T00:00:00Z\n' \
        "$version" "$ID" "$VERSION_ID" "$(dpkg --print-architecture)" >"$destination/offline-manifest.tsv"
    : >"$destination/components.tsv"
    for component in xray sing-box lego; do
        asset="${component}-fixture.tar.gz"
        mkdir -p "$destination/upstream/$component"
        printf 'inert %s upstream fixture\n' "$component" >"$destination/upstream/$component/$asset"
        digest="$(sha_file "$destination/upstream/$component/$asset")"
        printf 'component\t%s\tv1.2.3\t%s\t%s\tupstream/%s/%s\thttps://github.com/fixture/releases/download/v1.2.3/%s\n' \
            "$component" "$asset" "$digest" "$component" "$asset" "$asset" >>"$destination/components.tsv"
    done
    mkdir -p "$destination/apt/pool" "$TEST_TEMP/deb/DEBIAN"
    cat >"$TEST_TEMP/deb/DEBIAN/control" <<'CONTROL'
Package: vpsctl-offline-fixture
Version: 1.0
Architecture: all
Maintainer: vpsctl acceptance <test@example.invalid>
Description: inert offline importer fixture, never installed
CONTROL
    dpkg-deb --build --root-owner-group "$TEST_TEMP/deb" "$destination/apt/pool/vpsctl-offline-fixture_1.0_all.deb" >/dev/null
    asset='pool/vpsctl-offline-fixture_1.0_all.deb'
    digest="$(sha_file "$destination/apt/$asset")"
    size="$(stat -c %s "$destination/apt/$asset")"
    printf 'Package: vpsctl-offline-fixture\nVersion: 1.0\nArchitecture: all\nFilename: %s\nSize: %s\nSHA256: %s\nDescription: inert fixture\n\n' \
        "$asset" "$size" "$digest" >"$destination/apt/Packages"
    printf 'package\tversion\tarchitecture\tsha256\tpath\turl\nvpsctl-offline-fixture\t1.0\tall\t%s\tapt/%s\thttps://example.invalid/fixture.deb\n' "$digest" "$asset" >"$destination/apt/packages.tsv"
    rehash "$destination"
}

if [[ "${1:-}" == --fixtures ]]; then
    [[ $# == 2 ]] || fail 'usage: --fixtures DIRECTORY'
    mkdir -p "$2"
    make_package "$2/current" "$RELEASE_VERSION"
    make_package "$2/next" "$NEXT_VERSION"
    printf 'PASS: offline acceptance fixtures built at %s\n' "$2"
    exit 0
fi

source "$TEST_ROOT/lib/distribution.sh"
source "$TEST_ROOT/lib/offline.sh"
vps_registry_init
export VPSCTL_TESTING=1 VPSCTL_NON_INTERACTIVE=1 VPSCTL_ASSUME_YES=1
export VPSCTL_SYSTEM_ROOT="$TEST_TEMP/system"
export VPSCTL_INSTALL_ROOT="$VPSCTL_SYSTEM_ROOT/usr/local/lib/vpsctl"
export VPSCTL_SELF_STATE_ROOT="$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/self"
export VPSCTL_MANAGED_ENTRY="$VPSCTL_SYSTEM_ROOT/usr/local/bin/vpsctl"
mkdir -p "$VPSCTL_SYSTEM_ROOT"
GOOD="$TEST_TEMP/good"
NEXT="$TEST_TEMP/next"
make_package "$GOOD" "$RELEASE_VERSION"
make_package "$NEXT" "$NEXT_VERSION"
vps_distribution_download() { printf 'unexpected network request\n' >&2; return 77; }

snapshot() (
    cd -- "$VPSCTL_SYSTEM_ROOT"
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    find . -type l -printf '%p -> %l\n' | LC_ALL=C sort
)

expect_rejected() {
    local label="$1" package="$2" status=0 before after
    before="$(snapshot)"
    (vps_offline_import "$package") >"$TEST_TEMP/rejection.log" 2>&1 || status=$?
    [[ "$status" != 0 ]] || fail "$label accepted"
    after="$(snapshot)"
    [[ "$before" == "$after" ]] || { cat "$TEST_TEMP/rejection.log" >&2; fail "$label changed the managed install"; }
    printf 'PASS: rejected %s without changing managed files\n' "$label"
}

test_validation_failures() {
    local scenario bad="$TEST_TEMP/bad" asset digest archive_root="$TEST_TEMP/archive"
    for scenario in missing-bundle missing-apt corrupt-hash component-hash wrong-os wrong-version wrong-architecture duplicate-manifest duplicate-checksum unlisted-file symlink path-traversal component-traversal archive-symlink archive-traversal archive-missing-module; do
        rm -rf -- "$bad"
        cp -a -- "$GOOD" "$bad"
        case "$scenario" in
            missing-bundle) rm -- "$bad/vpsctl-service-proxy-$RELEASE_VERSION.tar.gz"; rehash "$bad" ;;
            missing-apt) rm -- "$bad/apt/pool/"*.deb; rehash "$bad" ;;
            corrupt-hash) printf 'corruption\n' >>"$bad/vpsctl-network-bbr-$RELEASE_VERSION.tar.gz" ;;
            component-hash) printf 'corruption\n' >>"$bad/upstream/xray/xray-fixture.tar.gz"; rehash "$bad" ;;
            wrong-os) sed -i 's/^os\t.*/os\tubuntu/' "$bad/offline-manifest.tsv"; rehash "$bad" ;;
            wrong-version) sed -i 's/^version\t.*/version\t98.76.54/' "$bad/offline-manifest.tsv"; rehash "$bad" ;;
            wrong-architecture) sed -i 's/^architecture\t.*/architecture\tarm64/' "$bad/offline-manifest.tsv"; rehash "$bad" ;;
            duplicate-manifest) printf 'version\t%s\n' "$RELEASE_VERSION" >>"$bad/offline-manifest.tsv"; rehash "$bad" ;;
            duplicate-checksum) asset="$(head -n 1 "$bad/SHA256SUMS")"; printf '%s\n' "$asset" >>"$bad/SHA256SUMS" ;;
            unlisted-file) printf 'unlisted\n' >"$bad/unlisted.txt" ;;
            symlink) asset="$bad/upstream/xray/xray-fixture.tar.gz"; rm "$asset"; ln -s /etc/passwd "$asset" ;;
            path-traversal) printf '%064d  ../escape\n' 0 >>"$bad/SHA256SUMS" ;;
            component-traversal) sed -i 's@upstream/xray/xray-fixture.tar.gz@../escape@' "$bad/components.tsv"; rehash "$bad" ;;
            archive-*)
                asset="vpsctl-network-bbr-$RELEASE_VERSION.tar.gz"
                rm -rf -- "$archive_root"
                mkdir -p "$archive_root"
                tar -xzf "$bad/$asset" -C "$archive_root"
                case "$scenario" in
                    archive-symlink)
                        rm "$archive_root/commands/network/bbr.sh"
                        ln -s /etc/passwd "$archive_root/commands/network/bbr.sh"
                        tar -czf "$bad/$asset" -C "$archive_root" commands
                        ;;
                    archive-traversal)
                        tar -czf "$bad/$asset" -C "$archive_root" --transform 's@commands/network/bbr.sh@../offline-escaped@' commands/network/bbr.sh
                        ;;
                    archive-missing-module)
                        rm "$archive_root/commands/network/bbr.sh"
                        tar -czf "$bad/$asset" -C "$archive_root" commands
                        ;;
                esac
                digest="$(sha_file "$bad/$asset")"
                sed -i "s/^bundle\tnetwork-bbr\t.*/bundle\tnetwork-bbr\t$asset\t$digest/" "$bad/vpsctl-manifest.tsv"
                rehash "$bad"
                ;;
        esac
        expect_rejected "$scenario" "$bad"
    done
}

test_validation_failures
vps_offline_validate_package "$GOOD" || fail 'canonical package rejected'
vps_offline_import "$GOOD" || fail 'full local import failed'
export VPSCTL_DISTRIBUTED=1
export VPSCTL_PROJECT_ROOT="$VPSCTL_INSTALL_ROOT/releases/$RELEASE_VERSION"
vps_offline_active || fail 'imported release is not active offline'
[[ "$(readlink "$VPSCTL_INSTALL_ROOT/current")" == "$VPSCTL_PROJECT_ROOT" ]] || fail 'current link is wrong'
[[ "$(<"$VPSCTL_PROJECT_ROOT/.release/offline.sha256")" == "$(sha_file "$GOOD/SHA256SUMS")" ]] || fail 'offline checksum anchor is wrong'
vps_distribution_parse_manifest "$VPSCTL_PROJECT_ROOT/.release/manifest.tsv"
for bundle in "${VPS_BUNDLE_IDS[@]}"; do
    [[ "$(<"$VPSCTL_PROJECT_ROOT/.bundles/$bundle.sha256")" == "${VPS_DISTRIBUTION_BUNDLE_SHA256[$bundle]}" ]] || fail "missing full-cache marker $bundle"
done
# Turn the fixture into a partial online cache, then hydrate the same release.
# A failed commit must recover that precise partial cache as well as metadata.
rm -rf -- "$VPSCTL_PROJECT_ROOT/.offline"
rm -- "$VPSCTL_PROJECT_ROOT/.release/offline.sha256"
vps_distribution_remove_command_cache network:bbr || fail 'prepare online cache failed'
before="$(snapshot)"
move_failed=0
mv() {
    if [[ "${*: -1}" == "$VPSCTL_MANAGED_ENTRY" && "$move_failed" == 0 ]]; then
        move_failed=1
        return 1
    fi
    command mv "$@"
}
status=0
vps_offline_import "$GOOD" >"$TEST_TEMP/hydrate-transaction.log" 2>&1 || status=$?
unset -f mv
[[ "$status" != 0 ]] || fail 'same-version hydration ignored entry commit failure'
[[ "$before" == "$(snapshot)" ]] || { cat "$TEST_TEMP/hydrate-transaction.log" >&2; fail 'failed hydration changed partial online install'; }
for signal_phase in stash-old-release publish-candidate; do
    before="$(snapshot)"
    signal_marker="$TEST_TEMP/signal-$signal_phase.hit"
    mv() {
        local source="${*: -2:1}" destination="${*: -1}"
        command mv "$@" || return $?
        if [[ ! -e "$signal_marker" ]] &&
            { [[ "$signal_phase" == stash-old-release && "$source" == "$VPSCTL_PROJECT_ROOT" && "$destination" == */previous-release ]] ||
              [[ "$signal_phase" == publish-candidate && "$source" == "$VPSCTL_INSTALL_ROOT/releases/.offline-"* && "$destination" == "$VPSCTL_PROJECT_ROOT" ]]; }; then
            printf '%s -> %s\n' "$source" "$destination" >"$signal_marker"
            kill -TERM "$BASHPID"
        fi
    }
    status=0
    vps_offline_import "$GOOD" >"$TEST_TEMP/signal-$signal_phase.log" 2>&1 || status=$?
    unset -f mv
    [[ -s "$signal_marker" ]] || fail "$signal_phase did not inject its signal after a successful rename"
    [[ "$status" == 143 ]] || { cat "$TEST_TEMP/signal-$signal_phase.log" >&2; fail "$signal_phase returned $status instead of 143"; }
    [[ "$before" == "$(snapshot)" ]] || { cat "$TEST_TEMP/signal-$signal_phase.log" >&2; fail "$signal_phase did not restore the partial online release, entry and metadata"; }
    [[ ! -e "$VPSCTL_INSTALL_ROOT/.self-update.lock" ]] || fail "$signal_phase retained its import lock"
    printf 'PASS: TERM after %s restored old release, entry and metadata (exit 143)\n' "$signal_phase"
done
vps_offline_import "$GOOD" || fail 'same-version hydration failed'
vps_offline_active || fail 'hydrated release is not offline'
[[ -f "$VPSCTL_PROJECT_ROOT/commands/network/bbr.sh" ]] || fail 'hydration did not restore missing feature'
printf 'PASS: same-version hydration and transaction rollback preserve partial online cache\n'
rm -rf -- "$GOOD"
vps_distribution_remove_command_cache network:bbr || fail 'offline feature cache eviction failed'
[[ ! -e "$VPSCTL_PROJECT_ROOT/commands/network/bbr.sh" ]] || fail 'feature cache was not removed'
vps_distribution_ensure_command network:bbr || fail 'offline feature cache reload failed after deleting original package'
printf 'PASS: full import, markers, package retention, feature eviction/reload\n'

# A fresh process cannot inherit the already loaded helper functions. Losing
# the helper alongside an evicted feature must fail before any online fallback.
(
    broken="$TEST_TEMP/missing-helper-release"
    guard="$TEST_TEMP/missing-helper-bin"
    cp -a -- "$VPSCTL_PROJECT_ROOT" "$broken"
    mkdir -p "$guard"
    rm -- "$broken/lib/offline.sh" "$broken/lib/command.sh" \
        "$broken/commands/network/bbr.sh" "$broken/.bundles/shared-command.sha256" "$broken/.bundles/network-bbr.sha256"
    export VPSCTL_MISSING_HELPER_TRACE="$TEST_TEMP/missing-helper-network"
    : >"$VPSCTL_MISSING_HELPER_TRACE"
    cat >"$guard/curl" <<'NETWORK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${VPSCTL_MISSING_HELPER_TRACE:?}"
exit 77
NETWORK
    cp -- "$guard/curl" "$guard/wget"
    chmod 0755 "$guard/curl" "$guard/wget"
    status=0
    PATH="$guard:$PATH" BASH_ENV='' ENV='' bash "$broken/bin/vpsctl" --non-interactive network bbr --help \
        >"$TEST_TEMP/missing-helper.log" 2>&1 || status=$?
    [[ "$status" != 0 ]] || fail 'fresh CLI accepted offline package without its helper'
    [[ ! -s "$VPSCTL_MISSING_HELPER_TRACE" ]] || fail 'fresh CLI attempted a network fallback without its helper'
    [[ ! -e "$broken/lib/command.sh" && ! -e "$broken/commands/network/bbr.sh" ]] || fail 'missing-helper failure populated the evicted cache'
    printf 'PASS: fresh CLI rejects missing offline helper without network fallback\n'
)

# Inject one failed rename at each transaction destination. Subsequent rollback
# commands run normally; assertions concern externally observable install state.
for failed_destination in "$VPSCTL_INSTALL_ROOT/current" "$VPSCTL_MANAGED_ENTRY" "$VPSCTL_SELF_STATE_ROOT/manifest.tsv" "$VPSCTL_SELF_STATE_ROOT/entry.sha256"; do
    before="$(snapshot)"
    status=0
    move_failed=0
    mv() {
        if [[ "${*: -1}" == "$failed_destination" && "$move_failed" == 0 ]]; then
            move_failed=1
            return 1
        fi
        command mv "$@"
    }
    vps_offline_import "$NEXT" >"$TEST_TEMP/transaction.log" 2>&1 || status=$?
    unset -f mv
    [[ "$status" != 0 ]] || fail "transaction failure at $failed_destination succeeded"
    [[ "$before" == "$(snapshot)" ]] || { cat "$TEST_TEMP/transaction.log" >&2; fail "transaction failure at $failed_destination changed install"; }
    printf 'PASS: transaction rollback at %s\n' "${failed_destination#"$VPSCTL_SYSTEM_ROOT"}"
done
vps_offline_import "$NEXT" || fail 'cross-version offline import failed'
[[ "$(<"$VPSCTL_INSTALL_ROOT/current/VERSION")" == "$NEXT_VERSION" ]] || fail 'cross-version import did not activate target'
printf 'PASS: offline distribution unit acceptance\n'
