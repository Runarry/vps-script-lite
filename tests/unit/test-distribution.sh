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
    [[ -n "$core_sha" ]] || core_sha="$zero"
    {
        printf 'schema_version\t1\n'
        printf 'version\t%s\n' "$version"
        printf 'repository\tRunarry/vps-script-lite\n'
        printf 'asset\tlauncher\tvpsctl.sh\t%s\n' "$launcher_sha"
        printf 'bundle\tcore\tvpsctl-core-%s.tar.gz\t%s\n' "$version" "$core_sha"
        printf 'bundle\tnetwork\tvpsctl-network-%s.tar.gz\t%s\n' "$version" "$network_sha"
        printf 'bundle\tsystem\tvpsctl-system-%s.tar.gz\t%s\n' "$version" "$zero"
        printf 'bundle\tsecurity\tvpsctl-security-%s.tar.gz\t%s\n' "$version" "$zero"
        printf 'bundle\tservice\tvpsctl-service-%s.tar.gz\t%s\n' "$version" "$zero"
        printf 'bundle\ttest\tvpsctl-test-%s.tar.gz\t%s\n' "$version" "$zero"
    } >"$path"
}

make_core_asset() {
    local version="$1" build="${TEST_TEMP}/build-core" required
    rm -rf -- "$build"
    mkdir -p "$build/bin" "$build/lib" "$build/commands/self"
    printf '%s\n' "$version" >"$build/VERSION"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$build/bin/vpsctl"
    for required in environment registry ui command distribution; do
        printf '#!/usr/bin/env bash\n' >"$build/lib/${required}.sh"
    done
    for required in status update uninstall; do
        printf '#!/usr/bin/env bash\nexit 0\n' >"$build/commands/self/${required}.sh"
    done
    tar -C "$build" -czf "${TEST_ASSETS}/vpsctl-core-${version}.tar.gz" VERSION bin lib commands
}

make_network_asset() {
    local version="$1" build="${TEST_TEMP}/build-network" script
    rm -rf -- "$build"
    mkdir -p "$build/commands/network"
    for script in bbr dns ip-policy rfw; do
        printf '#!/usr/bin/env bash\nprintf "network bundle\\n"\n' >"$build/commands/network/${script}.sh"
    done
    tar -C "$build" -czf "${TEST_ASSETS}/vpsctl-network-${version}.tar.gz" commands
}

test_source_mode_is_offline_and_mutations_refuse() (
    local calls=0 status=0
    VPSCTL_DISTRIBUTED=0
    VPSCTL_PROJECT_ROOT="$TEST_ROOT"
    vps_distribution_download() {
        calls=$((calls + 1))
        return 20
    }
    vps_distribution_ensure_domain network || fail 'source mode ensure failed'
    assert_equal 0 "$calls" 'source mode network calls'
    vps_distribution_self_update '' >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" 'source mode update refusal'
)

test_manifest_is_strict() (
    local manifest="${TEST_TEMP}/strict.tsv" status=0
    write_manifest "$manifest" 0.1.0 "$(printf x | sha256sum | awk '{print $1}')" "$(printf y | sha256sum | awk '{print $1}')"
    vps_distribution_parse_manifest "$manifest" || fail 'canonical manifest rejected'
    sed '5s/core/network/' "$manifest" >"${manifest}.bad"
    vps_distribution_parse_manifest "${manifest}.bad" >/dev/null 2>&1 || status=$?
    assert_equal 10 "$status" 'out-of-order/duplicate manifest rejection'
)

test_lazy_domain_install_and_cache() (
    local release="${TEST_INSTALL_ROOT}/releases/0.1.0" manifest network_sha calls=0
    make_network_asset 0.1.0
    network_sha="$(sha_file "${TEST_ASSETS}/vpsctl-network-0.1.0.tar.gz")"
    mkdir -p "$release/.release" "$release/.bundles"
    manifest="$release/.release/manifest.tsv"
    write_manifest "$manifest" 0.1.0 "$(printf launcher | sha256sum | awk '{print $1}')" "$network_sha"
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$release"
    vps_distribution_download() {
        calls=$((calls + 1))
        cp -- "${TEST_ASSETS}/${1##*/}" "$2"
    }
    vps_distribution_ensure_domain network || fail 'lazy network install failed'
    [[ -f "$release/commands/network/bbr.sh" ]] || fail 'lazy command missing'
    assert_equal "$network_sha" "$(<"$release/.bundles/network.sha256")" 'network cache marker'
    vps_distribution_ensure_domain network || fail 'cached network ensure failed'
    assert_equal 1 "$calls" 'cached ensure download count'
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
    local launcher_sha core_sha network_sha status=0 current_before
    rm -rf -- "$TEST_INSTALL_ROOT" "$TEST_SELF_ROOT" "$TEST_ASSETS"
    mkdir -p "$TEST_ASSETS" "$TEST_INSTALL_ROOT/releases" "$TEST_SELF_ROOT" "${TEST_ENTRY%/*}"
    prepare_managed_install "$old_release" 0.1.0
    make_core_asset 0.2.0
    make_network_asset 0.2.0
    printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_ASSETS/vpsctl.sh"
    launcher_sha="$(sha_file "$TEST_ASSETS/vpsctl.sh")"
    core_sha="$(sha_file "$TEST_ASSETS/vpsctl-core-0.2.0.tar.gz")"
    network_sha="$(sha_file "$TEST_ASSETS/vpsctl-network-0.2.0.tar.gz")"
    write_manifest "$TEST_ASSETS/vpsctl-manifest.tsv" 0.2.0 "$launcher_sha" "$network_sha" "$core_sha"
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$old_release"
    vps_distribution_download() { cp -- "${TEST_ASSETS}/${1##*/}" "$2"; }
    vps_distribution_self_update 0.2.0 >/dev/null || fail 'manual update failed'
    [[ "$(readlink "$TEST_INSTALL_ROOT/current")" == "$new_release" ]] || fail 'current did not switch to requested release'
    [[ -d "$old_release" && -f "$new_release/commands/network/bbr.sh" ]] || fail 'update did not retain old release and prefetch cached domain'
    [[ "$(sha_file "$TEST_ENTRY")" == "$launcher_sha" ]] || fail 'managed launcher was not updated'

    VPSCTL_PROJECT_ROOT="$new_release"
    make_core_asset 0.3.0
    make_network_asset 0.3.0
    network_sha="$(sha_file "$TEST_ASSETS/vpsctl-network-0.3.0.tar.gz")"
    write_manifest "$TEST_ASSETS/vpsctl-manifest.tsv" 0.3.0 "$launcher_sha" "$network_sha"
    current_before="$(readlink "$TEST_INSTALL_ROOT/current")"
    vps_distribution_self_update 0.3.0 >/dev/null 2>&1 || status=$?
    assert_equal 10 "$status" 'bad target bundle rejection'
    [[ "$(readlink "$TEST_INSTALL_ROOT/current")" == "$current_before" ]] || fail 'failed update changed current release'
    [[ ! -e "$TEST_INSTALL_ROOT/releases/0.3.0" && ! -e "$TEST_INSTALL_ROOT/.self-update.lock" ]] || fail 'failed update left active release or lock'
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
    make_network_asset "$version"
    network_sha="$(sha_file "${TEST_ASSETS}/vpsctl-network-${version}.tar.gz")"
    mkdir -p "$release/.release" "$release/.bundles" "$release/bin" "$release/lib" "$release/commands/self"
    printf '%s\n' "$version" >"$release/VERSION"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$release/bin/vpsctl"
    for required in environment registry ui command distribution; do
        printf '#!/usr/bin/env bash\n' >"$release/lib/${required}.sh"
    done
    for required in status update uninstall; do
        printf '#!/usr/bin/env bash\n' >"$release/commands/self/${required}.sh"
    done
    write_manifest "$release/.release/manifest.tsv" "$version" "$launcher_sha" "$network_sha"
    cp -- "$release/.release/manifest.tsv" "$TEST_SELF_ROOT/manifest.tsv"
    printf '%s\n' "$launcher_sha" >"$TEST_SELF_ROOT/entry.sha256"
    printf '%064d\n' 0 >"$release/.bundles/core.sha256"
    printf 'Runarry/vps-script-lite\t%s\n' "$version" >"$release/.vpsctl-managed-release"
    printf '%s\n' "$network_sha" >"$release/.bundles/network.sha256"
    ln -s "$release" "$TEST_INSTALL_ROOT/current"
}

test_uninstall_preserves_feature_state() (
    local release="${TEST_INSTALL_ROOT}/releases/0.2.0"
    rm -f -- "$TEST_INSTALL_ROOT/current"
    prepare_managed_install "$release" 0.2.0
    mkdir -p "$TEST_SYSTEM_ROOT/etc/vpsctl" "$TEST_SYSTEM_ROOT/var/lib/vpsctl/network" "$TEST_SYSTEM_ROOT/usr/local/libexec"
    touch "$TEST_SYSTEM_ROOT/etc/vpsctl/keep" "$TEST_SYSTEM_ROOT/var/lib/vpsctl/network/keep" "$TEST_SYSTEM_ROOT/usr/local/libexec/keep"
    VPSCTL_DISTRIBUTED=1
    VPSCTL_PROJECT_ROOT="$release"
    vps_distribution_self_uninstall 0 >/dev/null || fail 'normal uninstall failed'
    [[ ! -e "$TEST_ENTRY" && ! -e "$TEST_INSTALL_ROOT/current" && ! -e "$TEST_INSTALL_ROOT/releases" ]] || fail 'managed install remained'
    [[ -e "$TEST_SELF_ROOT/vpsctl.sh" ]] || fail 'normal uninstall removed self state'
    [[ -e "$TEST_SYSTEM_ROOT/etc/vpsctl/keep" && -e "$TEST_SYSTEM_ROOT/var/lib/vpsctl/network/keep" && -e "$TEST_SYSTEM_ROOT/usr/local/libexec/keep" ]] || fail 'normal uninstall removed preserved data'
)

test_uninstall_confirmation_contract() (
    local status=0
    VPSCTL_DISTRIBUTED=0 VPSCTL_PROJECT_ROOT="$TEST_ROOT" VPSCTL_NON_INTERACTIVE=1 VPSCTL_ASSUME_YES=1 \
        bash "$TEST_ROOT/commands/self/uninstall.sh" >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" 'global yes cannot replace uninstall confirmation flag'
    status=0
    VPSCTL_DISTRIBUTED=0 VPSCTL_PROJECT_ROOT="$TEST_ROOT" VPSCTL_NON_INTERACTIVE=1 VPSCTL_ASSUME_YES=1 \
        bash "$TEST_ROOT/commands/self/uninstall.sh" --purge --confirm-uninstall >/dev/null 2>&1 || status=$?
    assert_equal 3 "$status" 'purge requires its own confirmation flag'
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
    vps_distribution_validate_domain_tree "$tree" system >/dev/null 2>&1 || status=$?
    assert_equal 10 "$status" 'incomplete system kernel bundle rejected'
    for module in providers inventory grub; do
        printf '#!/usr/bin/env bash\n' >"$tree/commands/system/kernel/$module.sh"
    done
    vps_distribution_validate_domain_tree "$tree" system || fail 'complete system kernel bundle rejected'
    for module in providers inventory grub; do
        mv "$tree/commands/system/kernel/$module.sh" "$tree/$module.sh"
        status=0
        vps_distribution_validate_domain_tree "$tree" system >/dev/null 2>&1 || status=$?
        assert_equal 10 "$status" "system bundle missing $module rejected"
        mv "$tree/$module.sh" "$tree/commands/system/kernel/$module.sh"
    done
)

test_system_bundle_requires_kernel_modules
test_source_mode_is_offline_and_mutations_refuse
test_manifest_is_strict
test_lazy_domain_install_and_cache
test_status_is_offline
test_manual_update_is_atomic_and_versioned
test_stale_lock_is_recovered
test_testing_root_cannot_target_production
test_uninstall_preserves_feature_state
test_uninstall_confirmation_contract
test_purge_removes_only_self_state

printf 'distribution tests passed\n'
