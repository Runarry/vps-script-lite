#!/usr/bin/env bash
# Managed cleanup fixtures never touch installed releases or fetch network assets.
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2317
set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
TEST_ASSETS="$TEST_TEMP/assets"
trap 'rm -rf -- "$TEST_TEMP"' EXIT
mkdir -p "$TEST_ASSETS"
source "$TEST_ROOT/lib/distribution.sh"
vps_registry_init

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
assert_status() {
    local expected="$1" status=0
    shift
    "$@" >"$TEST_TEMP/output" 2>"$TEST_TEMP/error" || status=$?
    [[ "$status" == "$expected" ]] || fail "$*: expected status $expected, got $status: $(cat "$TEST_TEMP/error")"
}
assert_exists() { [[ -e "$1" || -L "$1" ]] || fail "missing protected path: $1"; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected retained path: $1"; }

vps_distribution_download() {
    printf '%s\n' "$1" >>"$TEST_TEMP/downloads"
    cp -- "$TEST_ASSETS/${1##*/}" "$2"
}

fixture() {
    local name="$1" relative bundle digest
    export VPSCTL_TESTING=1 VPSCTL_DISTRIBUTED=1 VPSCTL_DRY_RUN=0
    export VPSCTL_ASSUME_YES=0 VPSCTL_NON_INTERACTIVE=1
    export VPSCTL_SYSTEM_ROOT="$TEST_TEMP/$name"
    export VPSCTL_INSTALL_ROOT="$VPSCTL_SYSTEM_ROOT/usr/local/lib/vpsctl"
    export VPSCTL_SELF_STATE_ROOT="$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/self"
    export VPSCTL_MANAGED_ENTRY="$VPSCTL_SYSTEM_ROOT/usr/local/bin/vpsctl"
    export VPSCTL_PROJECT_ROOT="$VPSCTL_INSTALL_ROOT/releases/1.2.3"
    mkdir -p "$VPSCTL_PROJECT_ROOT/.release" "$VPSCTL_PROJECT_ROOT/.bundles" "$VPSCTL_SELF_STATE_ROOT" "${VPSCTL_MANAGED_ENTRY%/*}"
    while IFS= read -r relative; do
        [[ "$relative" != */* ]] || mkdir -p "$VPSCTL_PROJECT_ROOT/${relative%/*}"
        printf '# fixture\n' >"$VPSCTL_PROJECT_ROOT/$relative"
    done < <(vps_registry_bundle_files core)
    printf '1.2.3\n' >"$VPSCTL_PROJECT_ROOT/VERSION"
    printf 'Runarry/vps-script-lite\t1.2.3\n' >"$VPSCTL_PROJECT_ROOT/.vpsctl-managed-release"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$VPSCTL_MANAGED_ENTRY"
    ln -s "$VPSCTL_PROJECT_ROOT" "$VPSCTL_INSTALL_ROOT/current"
    {
        printf 'schema_version\t2\nversion\t1.2.3\nrepository\tRunarry/vps-script-lite\n'
        printf 'asset\tlauncher\tvpsctl.sh\t%s\n' "$(vps_distribution_sha256 "$VPSCTL_MANAGED_ENTRY")"
        for bundle in "${VPS_BUNDLE_IDS[@]}"; do
            digest="$(printf x | sha256sum)"
            digest="${digest%% *}"
            if [[ -f "$TEST_ASSETS/vpsctl-$bundle-1.2.3.tar.gz" ]]; then
                digest="$(vps_distribution_sha256 "$TEST_ASSETS/vpsctl-$bundle-1.2.3.tar.gz")"
            fi
            printf 'bundle\t%s\tvpsctl-%s-1.2.3.tar.gz\t%s\n' "$bundle" "$bundle" "$digest"
        done
    } >"$VPSCTL_PROJECT_ROOT/.release/manifest.tsv"
    vps_distribution_parse_manifest "$VPSCTL_PROJECT_ROOT/.release/manifest.tsv"
    printf '%s\n' "${VPS_DISTRIBUTION_BUNDLE_SHA256[core]}" >"$VPSCTL_PROJECT_ROOT/.bundles/core.sha256"
    printf 'keep\n' >"$VPSCTL_SELF_STATE_ROOT/manifest.tsv"
    printf 'keep\n' >"$VPSCTL_SELF_STATE_ROOT/entry.sha256"
}

cache_bundle() {
    local bundle="$1" relative
    while IFS= read -r relative; do
        mkdir -p "$VPSCTL_PROJECT_ROOT/${relative%/*}"
        printf '# cached fixture\n' >"$VPSCTL_PROJECT_ROOT/$relative"
    done < <(vps_registry_bundle_files "$bundle")
    printf '%s\n' "${VPS_DISTRIBUTION_BUNDLE_SHA256[$bundle]}" >"$VPSCTL_PROJECT_ROOT/.bundles/$bundle.sha256"
}

old_release() {
    local version="$1"
    mkdir -p "$VPSCTL_INSTALL_ROOT/releases/$version/.bundles"
    printf 'Runarry/vps-script-lite\t%s\n' "$version" >"$VPSCTL_INSTALL_ROOT/releases/$version/.vpsctl-managed-release"
    printf old >"$VPSCTL_INSTALL_ROOT/releases/$version/owned-file"
}

test_preconditions() (
    fixture preconditions
    for helper in vps_distribution_clean_residue vps_distribution_clean_bundles; do
        VPSCTL_DISTRIBUTED=0 assert_status 3 "$helper"
        VPSCTL_DISTRIBUTED=0 VPSCTL_DRY_RUN=1 assert_status 3 "$helper"
        VPSCTL_INSTALL_ROOT="$TEST_TEMP/nonstandard" assert_status 3 "$helper"
    done
    printf 'Runarry/vps-script-lite\t1.2.3\n\n' >"$VPSCTL_PROJECT_ROOT/.vpsctl-managed-release"
    assert_status 3 vps_distribution_clean_residue
    assert_absent "$VPSCTL_INSTALL_ROOT/.self-update.lock"
)

test_residue_boundaries_and_dry_run() (
    fixture residue
    local old="$VPSCTL_INSTALL_ROOT/releases/1.2.2" before after path version
    old_release 1.2.2
    for version in 1.2.0 1.2.1; do old_release "$version"; done
    printf 'Runarry/vps-script-lite\t1.2.0\n\n' >"$VPSCTL_INSTALL_ROOT/releases/1.2.0/.vpsctl-managed-release"
    printf 'Runarry/vps-script-lite\t1.2.1\0' >"$VPSCTL_INSTALL_ROOT/releases/1.2.1/.vpsctl-managed-release"
    mkdir -p "$VPSCTL_INSTALL_ROOT/releases/unknown" "$VPSCTL_INSTALL_ROOT/releases/.staging-2.0.0.test" "$VPSCTL_INSTALL_ROOT/.update.ABC123"
    printf legacy >"$VPSCTL_SELF_STATE_ROOT/vpsctl.sh"
    mkdir -p "$VPSCTL_PROJECT_ROOT/.bundles/.network-bbr.work.ABC123"
    printf partial >"$VPSCTL_PROJECT_ROOT/.bundles/.network-bbr.work.ABC123/download"
    printf digest >"$VPSCTL_PROJECT_ROOT/.bundles/.network-bbr.XYZ123"
    mkdir -p "$VPSCTL_PROJECT_ROOT/.bundles/.unknown.work.ABC123" "$VPSCTL_PROJECT_ROOT/.bundles/.network-bbr.work.short"
    ln -s "$TEST_ASSETS" "$VPSCTL_PROJECT_ROOT/.bundles/.unrelated-link"
    ln -s "$TEST_ASSETS" "$VPSCTL_INSTALL_ROOT/releases/0.0.1"
    for path in etc/vpsctl/config var/lib/vpsctl/service/state var/backups/vpsctl/backup usr/local/libexec/vpsctl/runtime var/tmp/unrelated; do
        mkdir -p "$VPSCTL_SYSTEM_ROOT/${path%/*}"
        printf keep >"$VPSCTL_SYSTEM_ROOT/$path"
    done
    before="$(find "$VPSCTL_SYSTEM_ROOT" -printf '%P %y %s %T@\n' | sort)"
    VPSCTL_DRY_RUN=1 assert_status 0 vps_distribution_clean_residue
    after="$(find "$VPSCTL_SYSTEM_ROOT" -printf '%P %y %s %T@\n' | sort)"
    [[ "$before" == "$after" ]] || fail 'dry run changed files or locks'
    [[ "$(cat "$TEST_TEMP/output")" == *"$old"* ]] || fail 'preview omitted old release'
    assert_absent "$TEST_TEMP/downloads"
    assert_status 0 vps_distribution_clean_residue
    assert_absent "$old"
    assert_absent "$VPSCTL_SELF_STATE_ROOT/vpsctl.sh"
    assert_absent "$VPSCTL_PROJECT_ROOT/.bundles/.network-bbr.work.ABC123"
    assert_absent "$VPSCTL_PROJECT_ROOT/.bundles/.network-bbr.XYZ123"
    for path in releases/1.2.0 releases/1.2.1 releases/unknown releases/0.0.1 releases/.staging-2.0.0.test .update.ABC123; do assert_exists "$VPSCTL_INSTALL_ROOT/$path"; done
    for path in .bundles/.unknown.work.ABC123 .bundles/.network-bbr.work.short .bundles/.unrelated-link .bundles/core.sha256; do assert_exists "$VPSCTL_PROJECT_ROOT/$path"; done
    for path in etc/vpsctl/config var/lib/vpsctl/service/state var/backups/vpsctl/backup usr/local/libexec/vpsctl/runtime var/tmp/unrelated; do
        [[ "$(cat "$VPSCTL_SYSTEM_ROOT/$path")" == keep ]] || fail "protected data changed: $path"
    done
    assert_status 0 vps_distribution_clean_residue
    [[ "$(cat "$TEST_TEMP/output")" == *'没有可清理'* ]] || fail 'repeated empty residue cleanup was not empty'
)

test_unsafe_residue_is_independent() (
    fixture unsafe
    old_release 1.2.0
    old_release 1.2.1
    old_release 1.2.2
    ln -s "$TEST_ASSETS" "$VPSCTL_INSTALL_ROOT/releases/1.2.0/link"
    mkfifo "$VPSCTL_INSTALL_ROOT/releases/1.2.1/fifo"
    assert_status 30 vps_distribution_clean_residue
    assert_exists "$VPSCTL_INSTALL_ROOT/releases/1.2.0/link"
    assert_exists "$VPSCTL_INSTALL_ROOT/releases/1.2.1/fifo"
    assert_absent "$VPSCTL_INSTALL_ROOT/releases/1.2.2"
    assert_status 3 vps_distribution_clean_residue
)

test_residue_locks_and_partial_failure() (
    fixture residue_locks
    local work="$VPSCTL_PROJECT_ROOT/.bundles/.network-bbr.work.ABC123"
    mkdir -p "$work" "$VPSCTL_PROJECT_ROOT/.bundles/.network-bbr.lock"
    printf '%s\n' "$$" >"$VPSCTL_PROJECT_ROOT/.bundles/.network-bbr.lock/pid"
    assert_status 3 vps_distribution_clean_residue
    assert_exists "$work"
    printf legacy >"$VPSCTL_SELF_STATE_ROOT/vpsctl.sh"
    assert_status 30 vps_distribution_clean_residue
    assert_absent "$VPSCTL_SELF_STATE_ROOT/vpsctl.sh"
    assert_exists "$work"
    rm -rf "$VPSCTL_PROJECT_ROOT/.bundles/.network-bbr.lock"
    mkdir "$VPSCTL_INSTALL_ROOT/.self-update.lock"
    printf '%s\n' "$$" >"$VPSCTL_INSTALL_ROOT/.self-update.lock/pid"
    assert_status 3 vps_distribution_clean_residue
    assert_exists "$work"
    rm -rf "$VPSCTL_INSTALL_ROOT/.self-update.lock"
    assert_status 0 vps_distribution_clean_residue
    old_release 1.2.2
    rm() {
        if [[ "${*: -1}" == "$VPSCTL_INSTALL_ROOT/releases/1.2.2" ]]; then
            command rm -f "$VPSCTL_INSTALL_ROOT/releases/1.2.2/owned-file" "$VPSCTL_INSTALL_ROOT/releases/1.2.2/.vpsctl-managed-release"
            return 1
        fi
        command rm "$@"
    }
    assert_status 30 vps_distribution_clean_residue
    assert_exists "$VPSCTL_INSTALL_ROOT/releases/1.2.2/.vpsctl-managed-release"
    unset -f rm
    assert_status 0 vps_distribution_clean_residue
)

test_bundle_eviction_and_reload() (
    local build="$TEST_TEMP/build-tcping" relative before after
    mkdir -p "$build"
    while IFS= read -r relative; do
        mkdir -p "$build/${relative%/*}"
        printf '# redownloaded fixture\n' >"$build/$relative"
    done < <(vps_registry_bundle_files service-tcping)
    tar -C "$build" -czf "$TEST_ASSETS/vpsctl-service-tcping-1.2.3.tar.gz" commands
    fixture bundles
    cache_bundle shared-command
    cache_bundle shared-ufw
    cache_bundle service-tcping
    cache_bundle service-iperf3
    if vps_registry_has_command system:clean; then cache_bundle system-clean; fi
    before="$(find "$VPSCTL_SYSTEM_ROOT" -printf '%P %y %s %T@\n' | sort)"
    VPSCTL_DRY_RUN=1 assert_status 0 vps_distribution_clean_bundles
    after="$(find "$VPSCTL_SYSTEM_ROOT" -printf '%P %y %s %T@\n' | sort)"
    [[ "$before" == "$after" ]] || fail 'bundle dry run mutated files or locks'
    assert_status 0 vps_distribution_clean_bundles
    assert_absent "$VPSCTL_PROJECT_ROOT/commands/service/tcping.sh"
    assert_absent "$VPSCTL_PROJECT_ROOT/commands/service/tcping"
    assert_absent "$VPSCTL_PROJECT_ROOT/commands/service/iperf3.sh"
    assert_exists "$VPSCTL_PROJECT_ROOT/lib/command.sh"
    assert_exists "$VPSCTL_PROJECT_ROOT/lib/ufw.sh"
    assert_exists "$VPSCTL_PROJECT_ROOT/.bundles/core.sha256"
    if vps_registry_has_command system:clean; then assert_exists "$VPSCTL_PROJECT_ROOT/commands/system/clean.sh"; fi
    assert_status 0 vps_distribution_clean_bundles
    [[ "$(cat "$TEST_TEMP/output")" == *'没有可清理'* ]] || fail 'empty bundle cleanup was not empty'
    assert_status 0 vps_distribution_ensure_bundle service-tcping
    [[ "$(cat "$VPSCTL_PROJECT_ROOT/commands/service/tcping/listener.py")" == '# redownloaded fixture' ]] || fail 'cache did not reload'
    assert_exists "$VPSCTL_PROJECT_ROOT/.bundles/service-tcping.sha256"
    assert_exists "$TEST_TEMP/downloads"
)

test_bundle_business_and_download_locks() (
    fixture bundle_locks
    local key feature fd lock
    mkdir -p "$VPSCTL_SYSTEM_ROOT/run/vpsctl"
    for key in service:proxy service:tcping service:iperf3 network:ufw network:rfw system:reinstall; do
        cache_bundle "${key/:/-}"
        case "$key" in
            service:proxy) feature=proxy ;;
            service:tcping) feature=tcping ;;
            service:iperf3) feature=iperf3 ;;
            *) feature="${key/:/-}" ;;
        esac
        exec {fd}>"$VPSCTL_SYSTEM_ROOT/run/vpsctl/$feature.lock"
        flock -n "$fd"
        assert_status 3 vps_distribution_clean_bundles
        assert_exists "$VPSCTL_PROJECT_ROOT/${VPS_COMMAND_PATH[$key]}"
        flock -u "$fd"
        exec {fd}>&-
        assert_status 0 vps_distribution_clean_bundles
    done
    cache_bundle service-proxy
    exec {fd}>"$VPSCTL_SYSTEM_ROOT/run/vpsctl/proxy-time.lock"
    flock -n "$fd"
    assert_status 3 vps_distribution_clean_bundles
    flock -u "$fd"
    exec {fd}>&-
    assert_status 0 vps_distribution_clean_bundles
    cache_bundle network-bbr
    cache_bundle service-tcping
    lock="$VPSCTL_PROJECT_ROOT/.bundles/.service-tcping.lock"
    mkdir "$lock"
    printf '%s\n' "$$" >"$lock/pid"
    assert_status 30 vps_distribution_clean_bundles
    assert_absent "$VPSCTL_PROJECT_ROOT/commands/network/bbr.sh"
    assert_exists "$VPSCTL_PROJECT_ROOT/commands/service/tcping.sh"
    assert_status 3 vps_distribution_clean_bundles
    rm -rf "$lock"
    assert_status 0 vps_distribution_clean_bundles
)

test_bundle_unsafe_and_partial_failure() (
    fixture bundle_failures
    cache_bundle network-bbr
    cache_bundle service-tcping
    rm "$VPSCTL_PROJECT_ROOT/commands/service/tcping/listener.py"
    ln -s "$TEST_ASSETS" "$VPSCTL_PROJECT_ROOT/commands/service/tcping/listener.py"
    assert_status 30 vps_distribution_clean_bundles
    assert_absent "$VPSCTL_PROJECT_ROOT/commands/network/bbr.sh"
    assert_exists "$VPSCTL_PROJECT_ROOT/commands/service/tcping.sh"
    assert_exists "$VPSCTL_PROJECT_ROOT/.bundles/service-tcping.sha256"
    rm "$VPSCTL_PROJECT_ROOT/commands/service/tcping/listener.py"
    cache_bundle service-tcping
    rm() {
        [[ "${*: -1}" != "$VPSCTL_PROJECT_ROOT/commands/service/tcping/listener.py" ]] || return 1
        command rm "$@"
    }
    assert_status 30 vps_distribution_clean_bundles
    assert_absent "$VPSCTL_PROJECT_ROOT/.bundles/service-tcping.sha256"
    assert_exists "$VPSCTL_PROJECT_ROOT/commands/service/tcping/listener.py"
    unset -f rm
    assert_status 0 vps_distribution_clean_bundles
    cache_bundle network-bbr
    rm() {
        [[ "${*: -1}" != "$VPSCTL_PROJECT_ROOT/.bundles/network-bbr.sha256" ]] || return 1
        command rm "$@"
    }
    assert_status 20 vps_distribution_clean_bundles
    unset -f rm
    assert_exists "$VPSCTL_PROJECT_ROOT/.bundles/network-bbr.sha256"
    assert_exists "$VPSCTL_PROJECT_ROOT/commands/network/bbr.sh"
    assert_status 0 vps_distribution_clean_bundles
)

test_old_release_busy_feature() (
    fixture old_busy
    old_release 1.2.2
    local old="$VPSCTL_INSTALL_ROOT/releases/1.2.2" fd
    mkdir -p "$old/commands/service" "$VPSCTL_SYSTEM_ROOT/run/vpsctl"
    printf cached >"$old/commands/service/tcping.sh"
    exec {fd}>"$VPSCTL_SYSTEM_ROOT/run/vpsctl/tcping.lock"
    flock -n "$fd"
    assert_status 3 vps_distribution_clean_residue
    assert_exists "$old"
    flock -u "$fd"
    exec {fd}>&-
    assert_status 0 vps_distribution_clean_residue
    assert_absent "$old"
    # A caller's live system-clean lock must remain held across old-release work.
    old_release 1.2.2
    mkdir -p "$old/commands/system"
    printf cached >"$old/commands/system/clean.sh"
    VPS_CMD_LOCK_PATH="$VPSCTL_SYSTEM_ROOT/run/vpsctl/system-clean.lock"
    exec {VPS_CMD_LOCK_FD}>"$VPS_CMD_LOCK_PATH"
    flock -n "$VPS_CMD_LOCK_FD"
    assert_status 0 vps_distribution_clean_residue
    assert_absent "$old"
    assert_status 1 flock -n "$VPS_CMD_LOCK_PATH" true
    flock -u "$VPS_CMD_LOCK_FD"
    exec {VPS_CMD_LOCK_FD}>&-
)

test_nonroot_preview() (
    if [[ "$EUID" != 0 ]] || ! command -v runuser >/dev/null || ! id nobody >/dev/null 2>&1; then
        printf 'SKIP: nonroot preview requires root, runuser and nobody\n'
        return 0
    fi
    fixture nonroot
    old_release 1.2.2
    cache_bundle network-bbr
    chmod 0755 "$TEST_TEMP"
    mkdir -p "$VPSCTL_SYSTEM_ROOT/code/lib"
    cp "$TEST_ROOT/lib/distribution.sh" "$TEST_ROOT/lib/registry.sh" "$VPSCTL_SYSTEM_ROOT/code/lib/"
    for helper in vps_distribution_clean_residue vps_distribution_clean_bundles; do
        assert_status 0 runuser -u nobody -- env VPSCTL_TESTING=0 VPSCTL_DRY_RUN=1 \
            bash -c 'cd /; source "$1"; "$2"' bash "$VPSCTL_SYSTEM_ROOT/code/lib/distribution.sh" "$helper"
        assert_status 4 runuser -u nobody -- env VPSCTL_TESTING=0 VPSCTL_DRY_RUN=0 \
            bash -c 'cd /; source "$1"; "$2"' bash "$VPSCTL_SYSTEM_ROOT/code/lib/distribution.sh" "$helper"
    done
    assert_exists "$VPSCTL_INSTALL_ROOT/releases/1.2.2"
    assert_exists "$VPSCTL_PROJECT_ROOT/commands/network/bbr.sh"
    assert_absent "$VPSCTL_INSTALL_ROOT/.self-update.lock"
    assert_absent "$VPSCTL_SYSTEM_ROOT/run"
)

test_mount_boundaries() (
    if ! unshare --mount --propagation private -- true 2>/dev/null; then
        printf 'SKIP: mount boundary checks require a private mount namespace\n'
        return 0
    fi
    fixture mounts
    old_release 1.2.1
    old_release 1.2.2
    cache_bundle service-iperf3
    local old="$VPSCTL_INSTALL_ROOT/releases/1.2.1" external="$VPSCTL_SYSTEM_ROOT/external"
    mkdir -p "$old/mounted" "$external"
    printf keep >"$external/iperf3.sh"
    assert_status 0 unshare --mount --propagation private -- bash -c '
        source "$1"
        mount --bind "$3" "$2/mounted" || exit 1
        status=0; vps_distribution_clean_residue || status=$?
        [[ "$status" == 30 && -f "$3/iperf3.sh" && -d "$2" && ! -e "$VPSCTL_INSTALL_ROOT/releases/1.2.2" ]] || exit 1
        umount "$2/mounted" || exit 1
        mount --bind "$3" "$VPSCTL_PROJECT_ROOT/commands/service" || exit 1
        status=0; vps_distribution_clean_bundles || status=$?
        [[ "$status" == 3 && -f "$3/iperf3.sh" && -f "$VPSCTL_PROJECT_ROOT/.bundles/service-iperf3.sha256" ]] || exit 1
        umount "$VPSCTL_PROJECT_ROOT/commands/service" || exit 1
    ' bash "$TEST_ROOT/lib/distribution.sh" "$old" "$external"
    [[ "$(cat "$external/iperf3.sh")" == keep ]] || fail 'bind mounted data was changed'
)

test_preconditions
test_residue_boundaries_and_dry_run
test_unsafe_residue_is_independent
test_residue_locks_and_partial_failure
test_bundle_eviction_and_reload
test_bundle_business_and_download_locks
test_bundle_unsafe_and_partial_failure
test_old_release_busy_feature
test_nonroot_preview
test_mount_boundaries
printf 'PASS: managed distribution cleanup\n'
