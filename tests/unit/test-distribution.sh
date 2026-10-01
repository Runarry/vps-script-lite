#!/usr/bin/env bash
# Network access is replaced by a local asset copier in every distributed-mode test.
# shellcheck disable=SC1091,SC2030,SC2031,SC2034,SC2317

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
TEST_SYSTEM_ROOT="${TEST_TEMP}/system"
TEST_ASSETS="${TEST_TEMP}/assets"
TEST_INSTALL_ROOT="${TEST_SYSTEM_ROOT}/usr/local/lib/vpsctl"
TEST_SELF_ROOT="${TEST_SYSTEM_ROOT}/var/lib/vpsctl/self"
TEST_ENTRY="${TEST_SYSTEM_ROOT}/usr/local/bin/vpsctl"
trap 'rm -rf -- "$TEST_TEMP"' EXIT

mkdir -p "$TEST_ASSETS" "$TEST_INSTALL_ROOT/releases" "$TEST_SELF_ROOT" "${TEST_ENTRY%/*}"

export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_INSTALL_ROOT="$TEST_INSTALL_ROOT"
export VPSCTL_SELF_STATE_ROOT="$TEST_SELF_ROOT"
export VPSCTL_MANAGED_ENTRY="$TEST_ENTRY"
export VPSCTL_NON_INTERACTIVE=1
export VPSCTL_ASSUME_YES=1

# shellcheck source=../../lib/distribution.sh
source "$TEST_ROOT/lib/distribution.sh"
vps_registry_init

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
assert_equal() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing '$2'"; }

sha_file() { sha256sum -- "$1" | awk '{print $1}'; }

write_manifest() {
    local path="$1" version="$2" launcher_sha="$3" network_sha="$4" core_sha="${5:-}"
    local zero='0000000000000000000000000000000000000000000000000000000000000000'
    local bundle digest archive
    [[ -n "$core_sha" ]] || core_sha="$zero"
    {
        printf 'schema_version\t2\n'
        printf 'version\t%s\n' "$version"
        printf 'repository\tRunarry/vps-script-lite\n'
        printf 'asset\tlauncher\tvpsctl.sh\t%s\n' "$launcher_sha"
        for bundle in "${VPS_BUNDLE_IDS[@]}"; do
            digest="$zero"
            archive="$TEST_ASSETS/vpsctl-${bundle}-${version}.tar.gz"
            [[ ! -f "$archive" ]] || digest="$(sha_file "$archive")"
            case "$bundle" in
                core) digest="$core_sha" ;;
                network-bbr) digest="$network_sha" ;;
            esac
            printf 'bundle\t%s\tvpsctl-%s-%s.tar.gz\t%s\n' "$bundle" "$bundle" "$version" "$digest"
        done
    } >"$path"
}

make_core_asset() {
    local version="$1" build="${TEST_TEMP}/build-core" required
    rm -rf -- "$build"
    mkdir -p "$build/bin" "$build/lib" "$build/commands/self"
    printf '%s\n' "$version" >"$build/VERSION"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$build/bin/vpsctl"
    for required in environment registry ui distribution; do
        printf '#!/usr/bin/env bash\n' >"$build/lib/${required}.sh"
    done
    for required in status update uninstall; do
        printf '#!/usr/bin/env bash\nexit 0\n' >"$build/commands/self/${required}.sh"
    done
    mkdir -p "$build/lib/nested"
    printf '# new shared helper\n' >"$build/lib/nested/future-helper.sh"
    tar -C "$build" -czf "${TEST_ASSETS}/vpsctl-core-${version}.tar.gz" VERSION bin lib commands
}

make_feature_assets() {
    local version="$1" build="${TEST_TEMP}/build-feature" bundle files path
    for bundle in shared-command shared-ufw network-bbr network-dns network-ufw system-reinstall system-swap service-tcping service-iperf3; do
        rm -rf -- "$build"
        mkdir -p "$build"
        files="$(vps_registry_bundle_files "$bundle")"
        while IFS= read -r path; do
            mkdir -p "$build/${path%/*}"
            printf '#!/usr/bin/env bash\n# feature fixture\n' >"$build/$path"
        done <<<"$files"
        tar -C "$build" -czf "${TEST_ASSETS}/vpsctl-${bundle}-${version}.tar.gz" "${files%%/*}"
    done
}

prepare_update_assets() {
    local version="$1" launcher_sha core_sha network_sha
    make_core_asset "$version"
    make_feature_assets "$version"
    printf '#!/usr/bin/env bash\n# release %s\nexit 0\n' "$version" >"$TEST_ASSETS/vpsctl.sh"
    launcher_sha="$(sha_file "$TEST_ASSETS/vpsctl.sh")"
    core_sha="$(sha_file "$TEST_ASSETS/vpsctl-core-${version}.tar.gz")"
    network_sha="$(sha_file "$TEST_ASSETS/vpsctl-network-bbr-${version}.tar.gz")"
    write_manifest "$TEST_ASSETS/vpsctl-manifest.tsv" "$version" "$launcher_sha" "$network_sha" "$core_sha"
}

test_source_mode_is_offline_and_mutations_refuse() (
    local calls=0 status=0
    VPSCTL_DISTRIBUTED=0
    VPSCTL_PROJECT_ROOT="$TEST_ROOT"
    vps_distribution_download() {
        calls=$((calls + 1))
        return 20
    }
    vps_distribution_ensure_command network:bbr || fail 'source mode ensure failed'
    assert_equal 0 "$calls" 'source mode network calls'
    vps_distribution_self_update '' >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" 'source mode update refusal'
)

test_manifest_is_strict() (
    local manifest="${TEST_TEMP}/strict.tsv" status scenario
    write_manifest "$manifest" 0.1.0 "$(printf x | sha256sum | awk '{print $1}')" "$(printf y | sha256sum | awk '{print $1}')"
    vps_distribution_parse_manifest "$manifest" || fail 'canonical manifest rejected'
    for scenario in schema1 duplicate missing-core traversal version uppercase extra-field empty-field blank; do
        case "$scenario" in
            schema1) sed '1s/2/1/' "$manifest" >"${manifest}.bad" ;;
            duplicate)
                cat "$manifest" >"${manifest}.bad"
                sed -n '5p' "$manifest" >>"${manifest}.bad"
                ;;
            missing-core) sed '5d' "$manifest" >"${manifest}.bad" ;;
            traversal) sed '5s/core/..\/core/' "$manifest" >"${manifest}.bad" ;;
            version) sed '5s/0.1.0/0.2.0/' "$manifest" >"${manifest}.bad" ;;
            uppercase) sed '5s/0$/A/' "$manifest" >"${manifest}.bad" ;;
            extra-field) sed '5s/$/\textra/' "$manifest" >"${manifest}.bad" ;;
            empty-field) sed '5s/bundle\t/bundle\t\t/' "$manifest" >"${manifest}.bad" ;;
            blank)
                cat "$manifest" >"${manifest}.bad"
                printf '\n' >>"${manifest}.bad"
                ;;
        esac
        status=0
        vps_distribution_parse_manifest "${manifest}.bad" >/dev/null 2>&1 || status=$?
        assert_equal 10 "$status" "runtime rejects $scenario manifest"
        status=0
        (
            # shellcheck disable=SC1090
            source <(sed '/^vpsctl_main "\$@"$/d' "$TEST_ROOT/vpsctl.sh")
            vpsctl_validate_manifest "${manifest}.bad"
        ) >/dev/null 2>&1 || status=$?
        assert_equal 1 "$status" "bootstrap rejects $scenario manifest"
    done
)

test_bootstrap_uses_release_launcher() (
    local fixtures="$TEST_TEMP/bootstrap" scenario digest output status bundle
    local zero='0000000000000000000000000000000000000000000000000000000000000000'
    local base='https://github.com/Runarry/vps-script-lite/releases'
    mkdir -p "$fixtures/tmp"
    for scenario in schema1 schema2 unknown-schema repository version launcher-path empty-field hash syntax; do
        cat >"$fixtures/vpsctl.sh" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
[[ ${VPSCTL_VERIFIED_STAGE:-} == 1 && -f ${VPSCTL_VERIFIED_MANIFEST:-} ]] || exit 90
printf 'canonical launcher\n'
printf '%s\n' "$@"
exit 17
LAUNCHER
        [[ "$scenario" != syntax ]] || printf 'if\n' >"$fixtures/vpsctl.sh"
        digest="$(sha_file "$fixtures/vpsctl.sh")"
        write_manifest "$fixtures/vpsctl-manifest.tsv" 0.8.9 "$digest" "$zero"
        case "$scenario" in
            schema1)
                sed -n '1s/2/1/;1,4p' "$fixtures/vpsctl-manifest.tsv" >"$fixtures/legacy.tsv"
                for bundle in core network system security service test; do
                    printf 'bundle\t%s\tvpsctl-%s-0.8.9.tar.gz\t%s\n' "$bundle" "$bundle" "$zero" >>"$fixtures/legacy.tsv"
                done
                mv "$fixtures/legacy.tsv" "$fixtures/vpsctl-manifest.tsv"
                ;;
            unknown-schema) sed -i '1s/2/3/' "$fixtures/vpsctl-manifest.tsv" ;;
            repository) sed -i '3s/Runarry/other/' "$fixtures/vpsctl-manifest.tsv" ;;
            version) sed -i '2s/0.8.9/..\/0.8.9/' "$fixtures/vpsctl-manifest.tsv" ;;
            launcher-path) sed -i '4s/vpsctl.sh/..\/vpsctl.sh/' "$fixtures/vpsctl-manifest.tsv" ;;
            empty-field) sed -i '4s/asset\t/asset\t\t/' "$fixtures/vpsctl-manifest.tsv" ;;
            hash) printf '# changed after hashing\n' >>"$fixtures/vpsctl.sh" ;;
        esac
        : >"$fixtures/downloads"
        status=0
        output="$(
            exec 2>&1
            # shellcheck disable=SC1090
            source <(sed '/^vpsctl_main "\$@"$/d' "$TEST_ROOT/vpsctl.sh")
            vpsctl_download() {
                printf '%s/%s\n' "$VPSCTL_RELEASE_BASE_URL" "$1" >>"$fixtures/downloads"
                cp -- "$fixtures/$1" "$2"
            }
            TMPDIR="$fixtures/tmp" vpsctl_stage_canonical_launcher --version 'argument with spaces'
        )" || status=$?
        case "$scenario" in
            schema1 | schema2)
                assert_equal 17 "$status" "$scenario canonical launcher exit status"
                assert_equal $'canonical launcher\n--version\nargument with spaces' "$output" "$scenario forwarded arguments"
                assert_equal "${base}/latest/download/vpsctl-manifest.tsv"$'\n'"${base}/download/v0.8.9/vpsctl.sh" \
                    "$(<"$fixtures/downloads")" "$scenario pinned launcher download"
                ;;
            *)
                assert_equal 1 "$status" "$scenario bootstrap rejection"
                [[ "$output" != *'canonical launcher'* ]] || fail "$scenario executed the rejected launcher"
                ;;
        esac
        [[ -z "$(find "$fixtures/tmp" -mindepth 1 -print -quit)" ]] || fail "$scenario left bootstrap temporary files"
    done
)

test_failed_downloads_retry_and_lock_recheck() (
    local release="$TEST_INSTALL_ROOT/releases/0.1.0" status scenario expected calls=0
    local archive="$TEST_ASSETS/vpsctl-network-ufw-0.1.0.tar.gz"
    make_feature_assets 0.1.0
    mkdir -p "$release/.release" "$release/.bundles"
    printf '0.1.0\n' >"$release/VERSION"
    write_manifest "$release/.release/manifest.tsv" 0.1.0 "$(sha_file "$archive")" "$(sha_file "$TEST_ASSETS/vpsctl-network-bbr-0.1.0.tar.gz")"
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$release"
    vps_distribution_download() { cp -- "${TEST_ASSETS}/${1##*/}" "$2"; }
    vps_distribution_ensure_command network:ufw || fail 'initial UFW load failed'
    expected="$(<"$release/.bundles/network-ufw.sha256")"
    cp "$archive" "$archive.good"
    for scenario in interrupted hash missing-module; do
        rm "$release/commands/network/ufw/menu.sh"
        case "$scenario" in
            interrupted) vps_distribution_download() {
                printf 'partial' >"$2"
                return 20
            } ;;
            hash) vps_distribution_download() { printf 'wrong hash' >"$2"; } ;;
            missing-module)
                rm -rf "$TEST_TEMP/incomplete"
                mkdir -p "$TEST_TEMP/incomplete"
                tar -xzf "$archive.good" -C "$TEST_TEMP/incomplete"
                rm "$TEST_TEMP/incomplete/commands/network/ufw/menu.sh"
                tar -C "$TEST_TEMP/incomplete" -czf "$archive" commands
                write_manifest "$release/.release/manifest.tsv" 0.1.0 "$expected" "$(sha_file "$TEST_ASSETS/vpsctl-network-bbr-0.1.0.tar.gz")"
                vps_distribution_download() { cp -- "${TEST_ASSETS}/${1##*/}" "$2"; }
                ;;
        esac
        status=0
        vps_distribution_ensure_command network:ufw >/dev/null 2>&1 || status=$?
        if [[ "$scenario" == interrupted ]]; then
            assert_equal 20 "$status" 'interrupted download status'
        else
            assert_equal 10 "$status" "$scenario rejected"
        fi
        [[ ! -e "$release/.bundles/network-ufw.sha256" ]] || fail 'failed repair retained success marker'
        [[ -z "$(find "$release/.bundles" -mindepth 1 ! -name '*.sha256' -print -quit)" ]] || fail 'failure left temporary download or lock'
        cp "$archive.good" "$archive"
        write_manifest "$release/.release/manifest.tsv" 0.1.0 "$expected" "$(sha_file "$TEST_ASSETS/vpsctl-network-bbr-0.1.0.tar.gz")"
        vps_distribution_download() { cp -- "${TEST_ASSETS}/${1##*/}" "$2"; }
        vps_distribution_ensure_command network:ufw || fail "$scenario retry failed"
        assert_equal "$expected" "$(<"$release/.bundles/network-ufw.sha256")" 'repaired marker'
    done
    rm "$release/.bundles/network-ufw.sha256"
    vps_distribution_acquire_lock() {
        mkdir "$1"
        printf '%s\n' "$expected" >"$release/.bundles/network-ufw.sha256"
    }
    vps_distribution_download() {
        calls=$((calls + 1))
        return 20
    }
    vps_distribution_ensure_bundle network-ufw || fail 'cache was not rechecked under lock'
    assert_equal 0 "$calls" 'lock recheck repeated download'
)

test_lazy_feature_install_and_cache() (
    local release="${TEST_INSTALL_ROOT}/releases/0.1.0" manifest network_sha calls=0
    make_feature_assets 0.1.0
    network_sha="$(sha_file "${TEST_ASSETS}/vpsctl-network-bbr-0.1.0.tar.gz")"
    mkdir -p "$release/.release" "$release/.bundles"
    printf '0.1.0\n' >"$release/VERSION"
    manifest="$release/.release/manifest.tsv"
    write_manifest "$manifest" 0.1.0 "$(printf launcher | sha256sum | awk '{print $1}')" "$network_sha"
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$release"
    vps_distribution_download() {
        calls=$((calls + 1))
        cp -- "${TEST_ASSETS}/${1##*/}" "$2"
    }
    vps_distribution_ensure_command network:bbr || fail 'lazy network install failed'
    [[ -f "$release/commands/network/bbr.sh" ]] || fail 'lazy command missing'
    assert_equal "$network_sha" "$(<"$release/.bundles/network-bbr.sha256")" 'network cache marker'
    vps_distribution_ensure_command network:bbr || fail 'cached network ensure failed'
    assert_equal 2 "$calls" 'feature plus shared dependency download count'
    [[ ! -e "$release/commands/network/dns.sh" && ! -e "$release/lib/ufw.sh" ]] || fail 'BBR downloaded unrelated code'
    vps_distribution_ensure_command network:dns || fail 'DNS install failed'
    assert_equal 3 "$calls" 'shared command dependency was downloaded twice'
    [[ ! -e "$release/commands/system/reinstall.sh" ]] || fail 'unrelated commands downloaded reinstall'
    vps_distribution_ensure_command system:reinstall || fail 'reinstall lazy install failed'
    assert_equal 4 "$calls" 'reinstall downloaded unrelated dependencies'
    [[ -f "$release/commands/system/reinstall.sh" ]] || fail 'reinstall command missing'
    [[ ! -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/reinstall/reinstall.sh" ]] || fail 'feature loading downloaded the upstream installer'
    vps_distribution_ensure_command service:iperf3 || fail 'iperf3 lazy install failed'
    assert_equal 6 "$calls" 'iperf3 downloads its feature and shared UFW dependency'
    [[ -f "$release/commands/service/iperf3.sh" && -f "$release/lib/ufw.sh" ]] || fail 'iperf3 feature or UFW dependency missing'
    [[ ! -e "$release/commands/service/tcping.sh" ]] || fail 'iperf3 loading downloaded unrelated service'
    vps_distribution_download() { return 20; }
    vps_distribution_ensure_command network:bbr || fail 'cached BBR failed offline'
    vps_distribution_ensure_command network:dns || fail 'cached DNS failed offline'
    vps_distribution_ensure_command system:reinstall || fail 'cached reinstall wrapper failed offline'
    vps_distribution_ensure_command service:iperf3 || fail 'cached iperf3 failed offline'
    [[ -z "$(find "$release/.bundles" -mindepth 1 ! -name '*.sha256' -print -quit)" ]] || fail 'lazy download left temporary assets'
)

test_lazy_swap_install_and_cache() (
    local release="${TEST_INSTALL_ROOT}/releases/0.1.1" calls=0 swap_sha
    make_feature_assets 0.1.1
    swap_sha="$(sha_file "$TEST_ASSETS/vpsctl-system-swap-0.1.1.tar.gz")"
    mkdir -p "$release/.release" "$release/.bundles"
    printf '0.1.1\n' >"$release/VERSION"
    write_manifest "$release/.release/manifest.tsv" 0.1.1 "$(sha_file "$TEST_ASSETS/vpsctl-shared-command-0.1.1.tar.gz")" "$(sha_file "$TEST_ASSETS/vpsctl-network-bbr-0.1.1.tar.gz")"
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$release"
    vps_distribution_download() {
        calls=$((calls + 1))
        cp -- "${TEST_ASSETS}/${1##*/}" "$2"
    }
    vps_distribution_ensure_command system:swap || fail 'lazy swap install failed'
    assert_equal 2 "$calls" 'swap downloads only its feature and shared command dependency'
    [[ -f "$release/commands/system/swap.sh" && -f "$release/lib/command.sh" ]] || fail 'swap command or shared dependency missing'
    assert_equal "$swap_sha" "$(<"$release/.bundles/system-swap.sha256")" 'swap cache marker'
    assert_equal $'shared-command.sha256\nsystem-swap.sha256' "$(find "$release/.bundles" -type f -printf '%f\n' | sort)" 'swap cache has no unrelated bundles'
    [[ ! -e "$release/lib/ufw.sh" && ! -e "$release/commands/system/kernel.sh" && ! -e "$release/commands/system/reinstall.sh" ]] || fail 'swap loaded unrelated code'
    [[ ! -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/system/swap" ]] || fail 'feature loading created swap state'
    vps_distribution_download() {
        calls=$((calls + 1))
        return 20
    }
    vps_distribution_ensure_command system:swap || fail 'cached swap failed offline'
    assert_equal 2 "$calls" 'cached swap attempted a network download'
    [[ -z "$(find "$release/.bundles" -mindepth 1 ! -name '*.sha256' -print -quit)" ]] || fail 'swap lazy download left temporary assets'
)

test_command_cache_eviction() (
    local release="${TEST_INSTALL_ROOT}/releases/0.3.0" marker status=0 calls=0
    local script listener shared other iperf3_marker iperf3_script preserved
    prepare_managed_install "$release" 0.3.0
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$release"
    vps_distribution_download() {
        calls=$((calls + 1))
        cp -- "${TEST_ASSETS}/${1##*/}" "$2"
    }
    vps_distribution_ensure_command service:tcping || fail 'initial tcping feature load failed'
    vps_distribution_ensure_command service:iperf3 || fail 'initial iperf3 feature load failed'
    vps_distribution_ensure_command network:bbr || fail 'other feature load failed'
    marker="$release/.bundles/service-tcping.sha256"
    script="$release/commands/service/tcping.sh"
    listener="$release/commands/service/tcping/listener.py"
    shared="$release/lib/ufw.sh"
    other="$release/commands/network/bbr.sh"
    [[ -f "$marker" && -f "$script" && -f "$listener" && -f "$shared" && -f "$other" ]] || fail 'cache eviction fixture is incomplete'

    VPSCTL_DISTRIBUTED=0 vps_distribution_remove_command_cache service:tcping || fail 'source mode cache eviction failed'
    [[ -f "$marker" && -f "$script" && -f "$listener" ]] || fail 'source mode modified installed cache'
    vps_distribution_remove_command_cache self:status >/dev/null 2>&1 || status=$?
    assert_equal 2 "$status" 'self bundle eviction refused'
    status=0
    vps_distribution_remove_command_cache shared:ufw >/dev/null 2>&1 || status=$?
    assert_equal 2 "$status" 'shared bundle eviction refused'
    [[ -f "$marker" && -f "$shared" ]] || fail 'invalid eviction touched cache'

    mv -- "$release/.bundles" "$TEST_TEMP/tcping-bundles-outside"
    ln -s "$TEST_TEMP/tcping-bundles-outside" "$release/.bundles"
    status=0
    vps_distribution_remove_command_cache service:tcping >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" 'symlinked bundle directory refused'
    [[ -f "$TEST_TEMP/tcping-bundles-outside/service-tcping.sha256" && ! -e "$TEST_TEMP/tcping-bundles-outside/.service-tcping.lock" && -f "$script" ]] || fail 'symlinked bundle directory changed outside cache'
    rm -- "$release/.bundles"
    mv -- "$TEST_TEMP/tcping-bundles-outside" "$release/.bundles"

    mv -- "$listener" "${listener}.saved"
    ln -s "$TEST_TEMP/outside" "$listener"
    status=0
    vps_distribution_remove_command_cache service:tcping >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" 'symlinked feature file refused'
    [[ -f "$marker" && -f "$script" && -L "$listener" ]] || fail 'symlink refusal removed cache content'
    rm -- "$listener"
    mv -- "${listener}.saved" "$listener"

    mv -- "$marker" "${marker}.saved"
    mkdir -- "$marker"
    status=0
    vps_distribution_remove_command_cache service:tcping >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" 'directory marker refused'
    [[ -f "$script" && -f "$listener" ]] || fail 'unsafe marker removed feature files'
    rmdir -- "$marker"
    mv -- "${marker}.saved" "$marker"

    # A feature child shell sources distribution.sh without an initialized registry.
    VPSCTL_DISTRIBUTED=1 VPSCTL_PROJECT_ROOT="$release" bash --noprofile --norc -c \
        'source "$1"; vps_distribution_remove_command_cache service:tcping' bash "$TEST_ROOT/lib/distribution.sh" || fail 'fresh child could not evict tcping cache'
    [[ ! -e "$marker" && ! -e "$script" && ! -e "$listener" && ! -e "$release/commands/service/tcping" ]] || fail 'tcping cache eviction was incomplete'
    [[ -d "$release/commands/service" ]] || fail 'tcping eviction removed the service domain directory'
    [[ -f "$shared" && -f "$release/lib/command.sh" && -f "$other" && -f "$release/.bundles/core.sha256" ]] || fail 'tcping eviction removed shared, core, or other feature'
    vps_distribution_remove_command_cache service:tcping || fail 'cache eviction was not retryable'
    calls=0
    vps_distribution_ensure_command service:tcping || fail 'evicted tcping feature did not re-download'
    assert_equal 1 "$calls" 'only the evicted feature re-downloaded'

    rm() {
        local arg last=""
        for arg in "$@"; do last="$arg"; done
        if [[ "$last" == "$listener" ]]; then return 1; fi
        command rm "$@"
    }
    status=0
    vps_distribution_remove_command_cache service:tcping >/dev/null 2>&1 || status=$?
    unset -f rm
    assert_equal 20 "$status" 'partial cache eviction reports failure'
    [[ ! -e "$marker" && ! -e "$script" && -f "$listener" ]] || fail 'partial eviction retained success marker or removed wrong files'
    [[ -f "$shared" && -f "$other" ]] || fail 'partial eviction touched shared or other feature'
    vps_distribution_remove_command_cache service:tcping || fail 'partial eviction could not be retried'
    [[ ! -e "$listener" && ! -e "$release/commands/service/tcping" ]] || fail 'retry left feature cache behind'

    vps_distribution_ensure_command service:tcping || fail 'tcping feature did not re-download for directory boundary'
    printf 'keep\n' >"$release/commands/service/tcping/unexpected"
    status=0
    vps_distribution_remove_command_cache service:tcping >/dev/null 2>&1 || status=$?
    assert_equal 20 "$status" 'unexpected private directory content is reported'
    [[ -f "$release/commands/service/tcping/unexpected" && ! -e "$marker" ]] || fail 'unexpected private content was deleted or retained success marker'
    rm -- "$release/commands/service/tcping/unexpected"
    vps_distribution_remove_command_cache service:tcping || fail 'private directory cleanup was not retryable'
    [[ ! -e "$release/commands/service/tcping" ]] || fail 'private directory remained after retry'

    vps_distribution_ensure_command service:tcping || fail 'tcping reload for iperf3 cache boundary failed'
    iperf3_marker="$release/.bundles/service-iperf3.sha256"
    iperf3_script="$release/commands/service/iperf3.sh"
    [[ -f "$iperf3_marker" && -f "$iperf3_script" ]] || fail 'tcping eviction removed iperf3 cache'
    preserved="$(sha256sum "$shared" "$release/lib/command.sh" "$other" "$marker" "$script" "$listener" "$release/.bundles/core.sha256")"
    VPSCTL_DISTRIBUTED=1 VPSCTL_PROJECT_ROOT="$release" bash --noprofile --norc -c \
        'source "$1"; vps_distribution_remove_command_cache service:iperf3' bash "$TEST_ROOT/lib/distribution.sh" || fail 'fresh child could not evict iperf3 cache'
    [[ ! -e "$iperf3_marker" && ! -e "$iperf3_script" && ! -e "$release/.bundles/.service-iperf3.lock" ]] || fail 'iperf3 cache eviction was incomplete'
    [[ -d "$release/commands/service" ]] || fail 'iperf3 eviction removed the service domain'
    assert_equal "$preserved" "$(sha256sum "$shared" "$release/lib/command.sh" "$other" "$marker" "$script" "$listener" "$release/.bundles/core.sha256")" 'iperf3 eviction preserves shared, core and other features'
    vps_distribution_remove_command_cache service:iperf3 || fail 'iperf3 cache eviction was not retryable'
    calls=0
    vps_distribution_ensure_command service:iperf3 || fail 'evicted iperf3 feature did not re-download'
    assert_equal 1 "$calls" 'only the evicted iperf3 feature re-downloaded'
)

test_status_is_offline() (
    local release="${TEST_INSTALL_ROOT}/releases/0.1.0" output calls=0
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$release"
    vps_distribution_download() {
        calls=$((calls + 1))
        return 20
    }
    output="$(vps_distribution_self_status)"
    assert_contains "$output" '分发版本：0.1.0' 'status version'
    assert_contains "$output" 'network' 'status cached domain'
    assert_equal 0 "$calls" 'status network calls'
)

test_manual_update_is_atomic_and_versioned() (
    local old_release="${TEST_INSTALL_ROOT}/releases/0.1.0" new_release="${TEST_INSTALL_ROOT}/releases/0.2.0"
    local history="${TEST_INSTALL_ROOT}/releases/0.0.9" launcher_sha network_sha status=0 current_before
    local failed_destination move_failed next_version output
    rm -rf -- "$TEST_INSTALL_ROOT" "$TEST_SELF_ROOT" "$TEST_ASSETS"
    mkdir -p "$TEST_ASSETS" "$TEST_INSTALL_ROOT/releases" "$TEST_SELF_ROOT" "${TEST_ENTRY%/*}"
    prepare_managed_install "$old_release" 0.1.0
    mkdir -p "$history"
    printf 'Runarry/vps-script-lite\t0.0.9\n' >"$history/.vpsctl-managed-release"
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$old_release"
    vps_distribution_download() { cp -- "${TEST_ASSETS}/${1##*/}" "$2"; }
    cp -- "$old_release/.release/manifest.tsv" "$TEST_ASSETS/vpsctl-manifest.tsv"
    vps_distribution_self_update 0.1.0 >/dev/null || fail 'same-version update failed'
    [[ -d "$old_release" && -f "$history/.vpsctl-managed-release" ]] || fail 'same-version update removed release history'

    prepare_update_assets 0.2.0
    launcher_sha="$(sha_file "$TEST_ASSETS/vpsctl.sh")"
    vps_distribution_download() { return 20; }
    vps_distribution_self_update 0.2.0 >/dev/null 2>&1 || status=$?
    assert_equal 20 "$status" 'manifest download failure'
    [[ -d "$old_release" && -f "$history/.vpsctl-managed-release" ]] || fail 'download failure removed release history'
    vps_distribution_download() { cp -- "${TEST_ASSETS}/${1##*/}" "$2"; }
    status=0
    chmod() {
        if [[ "${*: -1}" == */bin/vpsctl ]]; then return 1; fi
        command chmod "$@"
    }
    vps_distribution_self_update 0.2.0 >/dev/null 2>&1 || status=$?
    assert_equal 20 "$status" 'entry permission failure rejected before activation'
    [[ "$(readlink "$TEST_INSTALL_ROOT/current")" == "$old_release" ]] || fail 'permission failure changed current release'
    [[ -d "$old_release" && -f "$history/.vpsctl-managed-release" ]] || fail 'permission failure removed release history'
    [[ ! -e "$new_release" && ! -e "$TEST_INSTALL_ROOT/.self-update.lock" ]] || fail 'permission failure left release or lock'
    unset -f chmod

    for failed_destination in "$TEST_INSTALL_ROOT/current" "$TEST_ENTRY" \
        "$TEST_SELF_ROOT/manifest.tsv" "$TEST_SELF_ROOT/vpsctl.sh" "$TEST_SELF_ROOT/entry.sha256"; do
        rm -f -- "$TEST_SELF_ROOT/vpsctl.sh"
        printf 'corrupt cache\n' >"$TEST_SELF_ROOT/manifest.tsv"
        status=0
        move_failed=0
        mv() {
            if [[ "${*: -1}" == "$failed_destination" && "$move_failed" == 0 ]]; then
                move_failed=1
                return 1
            fi
            command mv "$@"
        }
        vps_distribution_self_update 0.2.0 >/dev/null 2>&1 || status=$?
        unset -f mv
        assert_equal 20 "$status" "activation failure at $failed_destination"
        [[ "$(readlink "$TEST_INSTALL_ROOT/current")" == "$old_release" ]] || fail 'activation failure changed current release'
        [[ -d "$old_release" && -f "$history/.vpsctl-managed-release" ]] || fail 'activation failure removed release history'
        [[ ! -e "$new_release" && ! -e "$TEST_INSTALL_ROOT/.self-update.lock" ]] || fail 'activation failure left release or lock'
        vps_distribution_validate_managed_install || fail 'activation failure did not restore managed metadata'
        if [[ "$failed_destination" != "$TEST_INSTALL_ROOT/current" ]]; then
            assert_self_cache_matches
        fi
    done

    status=0
    umask 077
    rm -rf -- "$TEST_SELF_ROOT"
    output="$(vps_distribution_self_update 0.2.0)" || fail 'manual update failed'
    assert_contains "$output" '受管历史 release 已清理' 'successful update cleanup message'
    [[ "$(readlink "$TEST_INSTALL_ROOT/current")" == "$new_release" ]] || fail 'current did not switch to requested release'
    "$TEST_INSTALL_ROOT/current/bin/vpsctl" || fail 'updated entry point cannot execute directly'
    assert_equal 755 "$(stat -c %a "$new_release")" 'updated release directory permissions'
    assert_equal 644 "$(stat -c %a "$new_release/.release/manifest.tsv")" 'updated manifest permissions'
    [[ ! -e "$old_release" && ! -e "$history" ]] || fail 'update retained a managed historical release'
    [[ ! -e "$new_release/commands/network" && ! -e "$new_release/lib/command.sh" && ! -e "$new_release/lib/ufw.sh" ]] || fail 'update prefetched feature or shared code'
    assert_equal core.sha256 "$(find "$new_release/.bundles" -type f -printf '%f\n')" 'update fetched only core'
    [[ -f "$new_release/lib/nested/future-helper.sh" ]] || fail 'update rejected new shared helper'
    assert_equal 0.2.0 "$(find "$TEST_INSTALL_ROOT/releases" -mindepth 1 -maxdepth 1 -printf '%f\n')" 'only current release remains'
    [[ "$(sha_file "$TEST_ENTRY")" == "$launcher_sha" ]] || fail 'managed launcher was not updated'

    VPSCTL_PROJECT_ROOT="$new_release"
    vps_distribution_validate_managed_install || fail 'successful update left inconsistent metadata'
    assert_self_cache_matches
    mkdir -p "$history"
    printf 'Runarry/vps-script-lite\t0.0.9\n' >"$history/.vpsctl-managed-release"
    prepare_update_assets 0.3.0
    launcher_sha="$(sha_file "$TEST_ASSETS/vpsctl.sh")"
    network_sha="$(sha_file "$TEST_ASSETS/vpsctl-network-bbr-0.3.0.tar.gz")"
    write_manifest "$TEST_ASSETS/vpsctl-manifest.tsv" 0.3.0 "$launcher_sha" "$network_sha"
    current_before="$(readlink "$TEST_INSTALL_ROOT/current")"
    vps_distribution_self_update 0.3.0 >/dev/null 2>&1 || status=$?
    assert_equal 10 "$status" 'bad target bundle rejection'
    [[ "$(readlink "$TEST_INSTALL_ROOT/current")" == "$current_before" ]] || fail 'failed update changed current release'
    [[ -d "$new_release" && -f "$history/.vpsctl-managed-release" ]] || fail 'bundle verification failure removed release history'
    [[ ! -e "$TEST_INSTALL_ROOT/releases/0.3.0" && ! -e "$TEST_INSTALL_ROOT/.self-update.lock" ]] || fail 'failed update left active release or lock'

    for next_version in 0.3.0 0.4.0; do
        prepare_update_assets "$next_version"
        vps_distribution_self_update "$next_version" >/dev/null || fail 'consecutive update failed'
        VPSCTL_PROJECT_ROOT="$TEST_INSTALL_ROOT/releases/$next_version"
        assert_equal "$next_version" "$(find "$TEST_INSTALL_ROOT/releases" -mindepth 1 -maxdepth 1 -printf '%f\n')" 'consecutive updates accumulated release history'
        vps_distribution_validate_managed_install || fail 'consecutive update left inconsistent metadata'
        "$TEST_INSTALL_ROOT/current/bin/vpsctl" || fail 'consecutively updated entry point cannot execute'
    done
)

test_update_cleanup_skips_unmanaged_entries() (
    local old_release="${TEST_INSTALL_ROOT}/releases/0.1.0" release version
    local outside="${TEST_TEMP}/outside-release" linked_marker="${TEST_TEMP}/linked-release-marker"
    local -a preserved=(0.0.1 0.0.2 0.0.3 0.0.4 0.0.5 0.0.6 0.0.7 0.0.8 0.0.9 .staging-0.2.0.fixture 0.0.8.backup not-a-version)
    rm -rf -- "$TEST_INSTALL_ROOT" "$TEST_SELF_ROOT" "$TEST_ASSETS"
    mkdir -p "$TEST_ASSETS" "$TEST_INSTALL_ROOT/releases" "$TEST_SELF_ROOT" "${TEST_ENTRY%/*}" "$outside"
    prepare_managed_install "$old_release" 0.1.0
    for version in "${preserved[@]}"; do
        mkdir -p "$TEST_INSTALL_ROOT/releases/$version"
    done
    printf 'keep\n' >"$outside/keep"
    printf 'Runarry/vps-script-lite\t0.0.4\n' >"$outside/.vpsctl-managed-release"
    printf 'Runarry/vps-script-lite\t9.9.9\n' >"$TEST_INSTALL_ROOT/releases/0.0.2/.vpsctl-managed-release"
    printf 'Runarry/vps-script-lite\t0.0.3\n' >"$linked_marker"
    ln -s "$linked_marker" "$TEST_INSTALL_ROOT/releases/0.0.3/.vpsctl-managed-release"
    rmdir "$TEST_INSTALL_ROOT/releases/0.0.4"
    ln -s "$outside" "$TEST_INSTALL_ROOT/releases/0.0.4"
    printf 'Runarry/vps-script-lite\t0.0.5\n\n' >"$TEST_INSTALL_ROOT/releases/0.0.5/.vpsctl-managed-release"
    printf 'Runarry/vps-script-lite\t0.0.6\000\n' >"$TEST_INSTALL_ROOT/releases/0.0.6/.vpsctl-managed-release"
    mkdir "$TEST_INSTALL_ROOT/releases/0.0.7/.vpsctl-managed-release"
    printf 'Other/repository\t0.0.8\n' >"$TEST_INSTALL_ROOT/releases/0.0.8/.vpsctl-managed-release"
    rmdir "$TEST_INSTALL_ROOT/releases/0.0.9"
    printf 'keep\n' >"$TEST_INSTALL_ROOT/releases/0.0.9"
    for version in .staging-0.2.0.fixture 0.0.8.backup not-a-version; do
        printf 'Runarry/vps-script-lite\t%s\n' "$version" >"$TEST_INSTALL_ROOT/releases/$version/.vpsctl-managed-release"
    done
    release="$TEST_INSTALL_ROOT/releases/0.0.0"
    mkdir "$release"
    printf 'Runarry/vps-script-lite\t0.0.0\n' >"$release/.vpsctl-managed-release"
    ln -s "$outside" "$release/linked-data"

    prepare_update_assets 0.2.0
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$old_release"
    vps_distribution_download() { cp -- "${TEST_ASSETS}/${1##*/}" "$2"; }
    vps_distribution_self_update 0.2.0 >/dev/null || fail 'update with unmanaged entries failed'
    [[ ! -e "$old_release" && ! -e "$release" ]] || fail 'update retained a safely owned historical release'
    for version in "${preserved[@]}"; do
        [[ -e "$TEST_INSTALL_ROOT/releases/$version" || -L "$TEST_INSTALL_ROOT/releases/$version" ]] || fail "cleanup removed protected entry $version"
    done
    [[ -f "$outside/keep" && -f "$outside/.vpsctl-managed-release" && -f "$linked_marker" ]] || fail 'cleanup followed a release or marker symlink'
    VPSCTL_PROJECT_ROOT="$TEST_INSTALL_ROOT/releases/0.2.0"
    vps_distribution_validate_managed_install || fail 'cleanup damaged the active release'
)

test_update_cleanup_failure_keeps_new_release_and_retries() (
    local old_release="${TEST_INSTALL_ROOT}/releases/0.1.0" new_release="${TEST_INSTALL_ROOT}/releases/0.2.0"
    local output status=0 launcher_sha
    rm -rf -- "$TEST_INSTALL_ROOT" "$TEST_SELF_ROOT" "$TEST_ASSETS"
    mkdir -p "$TEST_ASSETS" "$TEST_INSTALL_ROOT/releases" "$TEST_SELF_ROOT" "${TEST_ENTRY%/*}"
    prepare_managed_install "$old_release" 0.1.0
    prepare_update_assets 0.2.0
    launcher_sha="$(sha_file "$TEST_ASSETS/vpsctl.sh")"
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$old_release"
    vps_distribution_download() { cp -- "${TEST_ASSETS}/${1##*/}" "$2"; }
    rm() {
        if [[ "${*: -1}" == "$old_release" ]]; then
            command rm -f -- "$old_release/.vpsctl-managed-release"
            return 1
        fi
        command rm "$@"
    }
    output="$(vps_distribution_self_update 0.2.0 2>&1)" || status=$?
    unset -f rm
    assert_equal 30 "$status" 'cleanup failure reports partially completed update'
    assert_contains "$output" "$old_release" 'cleanup failure identifies the remaining release'
    assert_contains "$output" '分发版本 0.2.0 已激活' 'cleanup failure explains active version'
    [[ "$(readlink "$TEST_INSTALL_ROOT/current")" == "$new_release" ]] || fail 'cleanup failure rolled back current'
    [[ -d "$old_release" && ! -e "$TEST_INSTALL_ROOT/.self-update.lock" ]] || fail 'cleanup failure lost history or left the update lock'
    assert_equal $'Runarry/vps-script-lite\t0.1.0' "$(<"$old_release/.vpsctl-managed-release")" 'partial cleanup restored the verified ownership marker'
    assert_equal "$launcher_sha" "$(sha_file "$TEST_ENTRY")" 'cleanup failure retained the new launcher'
    VPSCTL_PROJECT_ROOT="$new_release"
    vps_distribution_validate_managed_install || fail 'cleanup failure corrupted the committed update'
    "$TEST_INSTALL_ROOT/current/bin/vpsctl" || fail 'cleanup failure made the new entry point unusable'

    vps_distribution_self_update 0.2.0 >/dev/null || fail 'same-version update after cleanup failure failed'
    [[ -d "$old_release" ]] || fail 'same-version update retried historical cleanup'
    prepare_update_assets 0.3.0
    vps_distribution_self_update 0.3.0 >/dev/null || fail 'next-version cleanup retry failed'
    assert_equal 0.3.0 "$(find "$TEST_INSTALL_ROOT/releases" -mindepth 1 -maxdepth 1 -printf '%f\n')" 'next-version update did not clean all historical releases'
    VPSCTL_PROJECT_ROOT="$TEST_INSTALL_ROOT/releases/0.3.0"
    vps_distribution_validate_managed_install || fail 'cleanup retry damaged the active release'
)

test_stale_lock_is_recovered() (
    local lock="${TEST_INSTALL_ROOT}/.stale-test.lock"
    mkdir -p "$lock"
    printf '999999999\n' >"$lock/pid"
    vps_distribution_acquire_lock "$lock" || fail 'stale lock was not recovered'
    assert_equal "$$" "$(<"$lock/pid")" 'recovered lock owner'
    vps_distribution_release_lock "$lock"
    [[ ! -e "$lock" ]] || fail 'released lock remains'
)

test_testing_root_cannot_target_production() (
    local status=0
    VPSCTL_DISTRIBUTED=1
    VPSCTL_TESTING=1
    VPSCTL_SYSTEM_ROOT=/
    vps_distribution_require_self_mutation >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" 'production root accepted as testing sandbox'
)

prepare_managed_install() {
    local release="$1" version="$2" launcher_sha network_sha
    printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_ENTRY"
    cp -- "$TEST_ENTRY" "$TEST_SELF_ROOT/vpsctl.sh"
    launcher_sha="$(sha_file "$TEST_ENTRY")"
    make_feature_assets "$version"
    network_sha="$(sha_file "${TEST_ASSETS}/vpsctl-network-bbr-${version}.tar.gz")"
    mkdir -p "$release/.release" "$release/.bundles" "$release/bin" "$release/lib" "$release/commands/self"
    printf '%s\n' "$version" >"$release/VERSION"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$release/bin/vpsctl"
    for required in environment registry ui distribution; do
        printf '#!/usr/bin/env bash\n' >"$release/lib/${required}.sh"
    done
    cp -- "$TEST_ROOT/lib/registry.sh" "$release/lib/registry.sh"
    for required in status update uninstall; do
        printf '#!/usr/bin/env bash\n' >"$release/commands/self/${required}.sh"
    done
    write_manifest "$release/.release/manifest.tsv" "$version" "$launcher_sha" "$network_sha"
    cp -- "$release/.release/manifest.tsv" "$TEST_SELF_ROOT/manifest.tsv"
    printf '%s\n' "$launcher_sha" >"$TEST_SELF_ROOT/entry.sha256"
    printf '%064d\n' 0 >"$release/.bundles/core.sha256"
    printf 'Runarry/vps-script-lite\t%s\n' "$version" >"$release/.vpsctl-managed-release"
    printf '%s\n' "$network_sha" >"$release/.bundles/network-bbr.sha256"
    ln -s "$release" "$TEST_INSTALL_ROOT/current"
}

assert_self_cache_matches() {
    assert_equal "$(sha_file "$TEST_ENTRY")" "$(sha_file "$TEST_SELF_ROOT/vpsctl.sh")" 'cached launcher'
    assert_equal "$(sha_file "$VPSCTL_PROJECT_ROOT/.release/manifest.tsv")" "$(sha_file "$TEST_SELF_ROOT/manifest.tsv")" 'cached manifest'
    assert_equal "$(sha_file "$TEST_ENTRY")" "$(<"$TEST_SELF_ROOT/entry.sha256")" 'cached entry digest'
}

test_self_cache_repair() (
    local release="$TEST_INSTALL_ROOT/releases/0.1.0" history="$TEST_INSTALL_ROOT/releases/0.0.9"
    local scenario path status entry_sha
    rm -rf -- "$TEST_INSTALL_ROOT" "$TEST_SELF_ROOT"
    mkdir -p "$TEST_INSTALL_ROOT/releases" "$TEST_SELF_ROOT"
    prepare_managed_install "$release" 0.1.0
    mkdir -p "$history"
    printf 'Runarry/vps-script-lite\t0.0.9\n' >"$history/.vpsctl-managed-release"
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$release"
    entry_sha="$(sha_file "$TEST_ENTRY")"
    cp -- "$release/.release/manifest.tsv" "$TEST_ASSETS/vpsctl-manifest.tsv"
    vps_distribution_download() { cp -- "${TEST_ASSETS}/${1##*/}" "$2"; }
    for scenario in missing-root missing-launcher corrupt-manifest corrupt-digest; do
        case "$scenario" in
            missing-root) rm -rf -- "$TEST_SELF_ROOT" ;;
            missing-launcher) rm -- "$TEST_SELF_ROOT/vpsctl.sh" ;;
            corrupt-manifest) printf 'corrupt\n' >"$TEST_SELF_ROOT/manifest.tsv" ;;
            corrupt-digest) printf 'corrupt\n' >"$TEST_SELF_ROOT/entry.sha256" ;;
        esac
        vps_distribution_self_update 0.1.0 >/dev/null || fail "same-version cache repair: $scenario"
        assert_self_cache_matches
        assert_equal "$release" "$(readlink "$TEST_INSTALL_ROOT/current")" 'cache repair current'
        assert_equal "$entry_sha" "$(sha_file "$TEST_ENTRY")" 'cache repair entry'
        [[ -f "$history/.vpsctl-managed-release" ]] || fail 'cache repair removed history'
    done
    for path in vpsctl.sh manifest.tsv entry.sha256; do
        rm -- "$TEST_SELF_ROOT/$path"
        status=0
        mv() {
            [[ "${*: -1}" != "$TEST_SELF_ROOT/$path" ]] || return 1
            command mv "$@"
        }
        vps_distribution_self_update 0.1.0 >/dev/null 2>&1 || status=$?
        unset -f mv
        assert_equal 20 "$status" 'cache repair write failure'
        assert_equal "$release" "$(readlink "$TEST_INSTALL_ROOT/current")" 'failed cache repair current'
        assert_equal "$entry_sha" "$(sha_file "$TEST_ENTRY")" 'failed cache repair entry'
        [[ ! -e "$TEST_INSTALL_ROOT/.self-update.lock" ]] || fail 'failed cache repair retained lock'
        vps_distribution_self_update 0.1.0 >/dev/null || fail 'cache repair retry'
        assert_self_cache_matches
    done
    for path in vpsctl.sh manifest.tsv entry.sha256; do
        rm -- "$TEST_SELF_ROOT/$path"
        ln -s "$TEST_ENTRY" "$TEST_SELF_ROOT/$path"
        status=0
        vps_distribution_self_update 0.1.0 >/dev/null 2>&1 || status=$?
        assert_equal 3 "$status" 'cache symlink rejected'
        rm -- "$TEST_SELF_ROOT/$path"
        mkdir "$TEST_SELF_ROOT/$path"
        status=0
        vps_distribution_self_uninstall 0 >/dev/null 2>&1 || status=$?
        assert_equal 3 "$status" 'cache directory rejected'
        rmdir "$TEST_SELF_ROOT/$path"
    done
    [[ -f "$TEST_ENTRY" ]] || fail 'unsafe cache check removed entry'
)

test_uninstall_preserves_feature_state() (
    local release="${TEST_INSTALL_ROOT}/releases/0.2.0"
    rm -f -- "$TEST_INSTALL_ROOT/current"
    prepare_managed_install "$release" 0.2.0
    mkdir -p "$TEST_SYSTEM_ROOT/etc/vpsctl" "$TEST_SYSTEM_ROOT/var/lib/vpsctl/network" "$TEST_SYSTEM_ROOT/usr/local/libexec"
    touch "$TEST_SYSTEM_ROOT/etc/vpsctl/keep" "$TEST_SYSTEM_ROOT/var/lib/vpsctl/network/keep" "$TEST_SYSTEM_ROOT/usr/local/libexec/keep"
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$release"
    rm -f -- "$TEST_SELF_ROOT/vpsctl.sh"
    printf 'corrupt cache\n' >"$TEST_SELF_ROOT/manifest.tsv"
    vps_distribution_self_uninstall 0 >/dev/null || fail 'normal uninstall failed'
    [[ ! -e "$TEST_ENTRY" && ! -e "$TEST_INSTALL_ROOT/current" && ! -e "$TEST_INSTALL_ROOT/releases" ]] || fail 'managed install remained'
    [[ ! -e "$TEST_SELF_ROOT/vpsctl.sh" ]] || fail 'normal uninstall repaired an unused cache'
    assert_equal 'corrupt cache' "$(<"$TEST_SELF_ROOT/manifest.tsv")" 'normal uninstall preserves self state'
    [[ -e "$TEST_SYSTEM_ROOT/etc/vpsctl/keep" && -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/network/keep" && -e "$TEST_SYSTEM_ROOT/usr/local/libexec/keep" ]] || fail 'normal uninstall removed preserved data'
)

test_uninstall_confirmation_contract() (
    local status authorization args command output release="$TEST_INSTALL_ROOT/releases/0.2.0"
    for authorization in yes legacy; do
        mkdir -p "$TEST_INSTALL_ROOT/releases" "$TEST_SELF_ROOT"
        rm -f -- "$TEST_INSTALL_ROOT/current"
        prepare_managed_install "$release" 0.2.0
        cp -- "$TEST_ROOT/lib/distribution.sh" "$release/lib/distribution.sh"
        export VPSCTL_DISTRIBUTED=1 VPSCTL_PROJECT_ROOT="$release" VPSCTL_NON_INTERACTIVE=1
        status=0
        VPSCTL_ASSUME_YES=0 bash "$TEST_ROOT/commands/self/uninstall.sh" >/dev/null 2>&1 || status=$?
        assert_equal 3 "$status" 'noninteractive uninstall requires authorization'
        for args in '--purge' '--purge --confirm-uninstall' '--purge --confirm-purge'; do
            local -a parsed=()
            IFS=' ' read -r -a parsed <<<"$args"
            status=0
            VPSCTL_ASSUME_YES=1 bash "$TEST_ROOT/commands/self/uninstall.sh" "${parsed[@]}" >/dev/null 2>&1 || status=$?
            assert_equal 3 "$status" 'global yes cannot replace purge confirmation flags'
        done
        [[ -f "$TEST_ENTRY" ]] || fail 'unconfirmed uninstall changed installation'
        if [[ "$authorization" == yes ]]; then
            printf -v command 'env VPSCTL_ASSUME_YES=0 VPSCTL_NON_INTERACTIVE=0 bash %q' "$TEST_ROOT/commands/self/uninstall.sh"
            status=0
            output="$(printf 'n\n' | script -q -e -c "$command" /dev/null 2>&1)" || status=$?
            assert_equal 130 "$status" 'interactive uninstall cancellation'
            assert_contains "$output" '确认卸载受管 vpsctl' 'interactive uninstall prompt'
            [[ -f "$TEST_ENTRY" && -d "$release" ]] || fail 'cancelled uninstall changed installation'
        fi
        if [[ "$authorization" == yes ]]; then
            VPSCTL_ASSUME_YES=1 bash "$TEST_ROOT/commands/self/uninstall.sh" >/dev/null || fail 'global yes uninstall'
        else
            VPSCTL_ASSUME_YES=0 bash "$TEST_ROOT/commands/self/uninstall.sh" --confirm-uninstall >/dev/null || fail 'legacy uninstall flag'
        fi
        [[ ! -e "$TEST_ENTRY" ]] || fail 'authorized uninstall kept entry'
    done
)

test_purge_removes_only_self_state() (
    local release="${TEST_INSTALL_ROOT}/releases/0.3.0"
    mkdir -p "$TEST_INSTALL_ROOT/releases" "$TEST_SELF_ROOT"
    rm -f -- "$TEST_INSTALL_ROOT/current"
    prepare_managed_install "$release" 0.3.0
    mkdir -p "$TEST_SYSTEM_ROOT/etc/vpsctl" "$TEST_SYSTEM_ROOT/var/lib/vpsctl/security" "$TEST_SYSTEM_ROOT/usr/local/libexec"
    touch "$TEST_SYSTEM_ROOT/etc/vpsctl/purge-keep" "$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/purge-keep" "$TEST_SYSTEM_ROOT/usr/local/libexec/purge-keep"
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$release"
    vps_distribution_self_uninstall 1 >/dev/null || fail 'purge uninstall failed'
    [[ ! -e "$TEST_SELF_ROOT" ]] || fail 'purge retained self state'
    [[ -e "$TEST_SYSTEM_ROOT/etc/vpsctl/purge-keep" && -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/security/purge-keep" && -e "$TEST_SYSTEM_ROOT/usr/local/libexec/purge-keep" ]] || fail 'purge removed preserved data'
)

test_system_bundle_requires_kernel_modules() (
    local tree="${TEST_TEMP}/kernel-bundle" module status
    mkdir -p "$tree/commands/system/kernel"
    printf '#!/usr/bin/env bash\n' >"$tree/commands/system/kernel.sh"
    status=0
    vps_distribution_validate_bundle_tree "$tree" system-kernel >/dev/null 2>&1 || status=$?
    assert_equal 10 "$status" 'incomplete system kernel bundle rejected'
    for module in providers inventory grub grub-install; do
        printf '#!/usr/bin/env bash\n' >"$tree/commands/system/kernel/$module.sh"
    done
    vps_distribution_validate_bundle_tree "$tree" system-kernel || fail 'complete system kernel bundle rejected'
    for module in providers inventory grub grub-install; do
        mv "$tree/commands/system/kernel/$module.sh" "$tree/$module.sh"
        status=0
        vps_distribution_validate_bundle_tree "$tree" system-kernel >/dev/null 2>&1 || status=$?
        assert_equal 10 "$status" "system bundle missing $module rejected"
        mv "$tree/$module.sh" "$tree/commands/system/kernel/$module.sh"
    done
)

test_private_modules_and_shared_boundaries() (
    local bundle tree="$TEST_TEMP/private-modules" path files status archive="$TEST_TEMP/boundary.tar.gz"
    for bundle in network-ufw security-access security-tls service-proxy service-tcping service-iperf3; do
        rm -rf "$tree"
        mkdir -p "$tree"
        files="$(vps_registry_bundle_files "$bundle")"
        while IFS= read -r path; do
            mkdir -p "$tree/${path%/*}"
            cp "$TEST_ROOT/$path" "$tree/$path"
        done <<<"$files"
        vps_distribution_validate_bundle_tree "$tree" "$bundle" || fail "complete $bundle rejected"
        while IFS= read -r path; do
            mv "$tree/$path" "$tree/missing"
            status=0
            vps_distribution_validate_bundle_tree "$tree" "$bundle" >/dev/null 2>&1 || status=$?
            assert_equal 10 "$status" "missing private file: $path"
            mv "$tree/missing" "$tree/$path"
        done <<<"$files"
    done
    for bundle in shared-command shared-ufw shared-server-test network-bbr system-swap security-fail2ban; do
        status=0
        vps_distribution_archive_path_allowed "$bundle" lib/distribution.sh || status=$?
        assert_equal 1 "$status" "$bundle may overwrite core"
        status=0
        vps_distribution_archive_path_allowed "$bundle" commands/network/dns.sh || status=$?
        assert_equal 1 "$status" "$bundle contains an unrelated command"
    done
)

test_core_archive_boundaries() (
    local tree="$TEST_TEMP/core-boundaries" archive="$TEST_TEMP/core-boundaries.tar.gz" path status
    mkdir -p "$tree/lib/nested"
    printf '# helper\n' >"$tree/lib/nested/helper.sh"
    tar -C "$tree" -czf "$archive" lib
    vps_distribution_validate_archive "$archive" core || fail 'nested shared helper rejected'
    for path in /etc/passwd lib/../outside .release/manifest.tsv commands/network/bbr.sh bin/other; do
        status=0
        tar -C "$tree" --transform="s|lib/nested/helper.sh|$path|" -czf "$archive" lib/nested/helper.sh
        vps_distribution_validate_archive "$archive" core >/dev/null 2>&1 || status=$?
        assert_equal 10 "$status" "out-of-bounds core path rejected: $path"
    done
    ln -s helper.sh "$tree/lib/nested/link.sh"
    tar -C "$tree" -czf "$archive" lib
    status=0
    vps_distribution_validate_archive "$archive" core >/dev/null 2>&1 || status=$?
    assert_equal 10 "$status" 'core symlink rejected'
)

test_core_archive_boundaries
test_private_modules_and_shared_boundaries
test_system_bundle_requires_kernel_modules
test_source_mode_is_offline_and_mutations_refuse
test_manifest_is_strict
test_bootstrap_uses_release_launcher
test_lazy_feature_install_and_cache
test_lazy_swap_install_and_cache
test_command_cache_eviction
test_status_is_offline
test_failed_downloads_retry_and_lock_recheck
test_manual_update_is_atomic_and_versioned
test_update_cleanup_skips_unmanaged_entries
test_update_cleanup_failure_keeps_new_release_and_retries
test_stale_lock_is_recovered
test_testing_root_cannot_target_production
test_self_cache_repair
test_uninstall_preserves_feature_state
test_uninstall_confirmation_contract
test_purge_removes_only_self_state

printf 'distribution tests passed\n'
