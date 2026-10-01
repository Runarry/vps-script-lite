#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
RELEASE_DIR="${TEST_TEMP}/release"
RELEASE_VERSION="$(<"${TEST_ROOT}/VERSION")"

cleanup() {
    rm -rf -- "$TEST_TEMP"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
}

assert_archive_has() {
    local archive=$1
    local member=$2
    local members=''

    members="$(tar -tzf "$archive")"
    grep -Fx -- "$member" <<<"$members" >/dev/null || fail "${archive##*/} is missing ${member}"
}

trap cleanup EXIT

test_release_delivery() (
    local area="${TEST_TEMP}/delivery" target seed snapshot_before scenario entry previous builder
    local run_status run_output marker hook snapshot_expected
    local -a work=()
    mkdir -p -- "$area"
    marker="${area}/injection.log"
    hook="${area}/fault-hook.sh"
    seed="${area}/old-release"
    cp -a -- "$RELEASE_DIR" "$seed"
    cp -- "${seed}/vpsctl-core-${RELEASE_VERSION}.tar.gz" "${seed}/vpsctl-retired-0.0.0.tar.gz"
    printf '#!/usr/bin/env bash\nprintf "old release\\n"\n' >"${seed}/vpsctl.sh"

    # These functions exist only in the builder subprocess. Unmatched calls use
    # the real tools; markers prove the intended failure was actually injected.
    cat >"$hook" <<'BASH'
gzip() {
    local count=0
    if [[ "$RELEASE_TEST_SCENARIO" == gzip ]]; then
        [[ ! -f "$RELEASE_TEST_MARKER" ]] || read -r count <"$RELEASE_TEST_MARKER"
        count=$((count + 1))
        command printf '%s\n' "$count" >"$RELEASE_TEST_MARKER"
        if ((count == 3)); then command printf 'hit\n' >>"$RELEASE_TEST_MARKER"; return 71; fi
    fi
    command gzip "$@"
}
sha256sum() {
    local count=0
    if [[ "$RELEASE_TEST_SCENARIO" == digest ]]; then
        [[ ! -f "$RELEASE_TEST_MARKER" ]] || read -r count <"$RELEASE_TEST_MARKER"
        count=$((count + 1))
        command printf '%s\n' "$count" >"$RELEASE_TEST_MARKER"
        if ((count == 3)); then command printf 'hit\n' >>"$RELEASE_TEST_MARKER"; return 72; fi
    fi
    command sha256sum "$@"
}
printf() {
    if [[ "$RELEASE_TEST_SCENARIO" == manifest && "${1:-}" == 'bundle\t'* ]]; then
        command printf 'hit\n' >>"$RELEASE_TEST_MARKER"
        return 73
    fi
    command printf "$@"
}
mv() {
    local source="${@: -2:1}" destination="${@: -1}"
    if [[ "$source" == */assets && "$destination" == "$RELEASE_TEST_OUTPUT" &&
          ( "$RELEASE_TEST_SCENARIO" == publish || "$RELEASE_TEST_SCENARIO" == restore ) ]]; then
        command printf 'hit\n' >>"$RELEASE_TEST_MARKER"
        return 74
    fi
    if [[ "$source" == */previous && "$destination" == "$RELEASE_TEST_OUTPUT" && "$RELEASE_TEST_SCENARIO" == restore ]]; then
        command printf 'restore-hit\n' >>"$RELEASE_TEST_MARKER"
        return 75
    fi
    command mv "$@" || return $?
    if [[ "$source" == "$RELEASE_TEST_OUTPUT" && "$destination" == */previous && "$RELEASE_TEST_SCENARIO" == term ]]; then
        command printf 'hit\n' >>"$RELEASE_TEST_MARKER"
        kill -TERM "$BASHPID"
    fi
}
rm() {
    local last="${*: -1}"
    if [[ "$RELEASE_TEST_SCENARIO" == cleanup && "${last##*/}" == .vpsctl-release.* ]]; then
        command printf 'hit\n' >>"$RELEASE_TEST_MARKER"
        return 76
    fi
    command rm "$@"
}
BASH
    snapshot() {
        (
            cd -- "$1"
            find . -mindepth 1 -printf '%y %m %p %l\n' | LC_ALL=C sort
            find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum --
        )
    }
    run_build() {
        local fault="$1" destination="$2" script="${3:-${TEST_ROOT}/scripts/build-release.sh}"
        printf '0\n' >"$marker"
        if run_output="$(BASH_ENV="$hook" RELEASE_TEST_SCENARIO="$fault" RELEASE_TEST_OUTPUT="$destination" \
            RELEASE_TEST_MARKER="$marker" bash "$script" "$destination" 2>&1)"; then run_status=0; else run_status=$?; fi
    }
    assert_injected() { grep -Fxq hit "$marker" || fail "$1 injection did not run: $run_output"; }
    assert_unchanged() {
        [[ -d "$target" ]] || fail "$1 removed the old output: $run_output"
        [[ "$(snapshot "$target")" == "$snapshot_before" ]] || fail "$1 changed the old release"
    }
    assert_no_work() {
        [[ -z "$(find "$1" -mindepth 1 -maxdepth 1 -name '.vpsctl-release.*' -print)" ]] || fail "$2 leaked a work directory"
    }
    reset_target() {
        target="${area}/$1/release with spaces"
        mkdir -p -- "${target%/*}"
        cp -a -- "$seed" "$target"
        snapshot_before="$(snapshot "$target")"
    }
    snapshot_expected="$(snapshot "$RELEASE_DIR")"

    reset_target normal
    run_build none "$target"
    [[ "$run_status" == 0 && "$(snapshot "$target")" == "$snapshot_expected" ]] || fail "normal publication or old-version cleanup failed: $run_output"
    run_build none "$target"
    [[ "$run_status" == 0 && "$(snapshot "$target")" == "$snapshot_expected" ]] || fail "repeat publication changed the release: $run_output"
    assert_no_work "${target%/*}" 'normal publication'

    for scenario in gzip digest manifest publish term; do
        reset_target "$scenario"
        run_build "$scenario" "$target"
        assert_injected "$scenario"
        [[ "$run_status" != 0 ]] || fail "$scenario failure returned success"
        [[ "$scenario" != term || "$run_status" == 143 ]] || fail "TERM returned $run_status rather than 143"
        assert_unchanged "$scenario"
        assert_no_work "${target%/*}" "$scenario failure"
    done

    reset_target restore
    run_build restore "$target"
    assert_injected restore
    grep -Fxq restore-hit "$marker" || fail 'restore failure injection did not run'
    [[ "$run_status" != 0 && ! -e "$target" ]] || fail 'failed restore should leave old output in its recovery location'
    mapfile -t work < <(find "${target%/*}" -mindepth 1 -maxdepth 1 -type d -name '.vpsctl-release.*')
    [[ ${#work[@]} == 1 ]] || fail 'failed restore must preserve exactly one work directory'
    previous="${work[0]}/previous"
    [[ -d "$previous" && "$(snapshot "$previous")" == "$snapshot_before" ]] || fail 'failed restore lost or changed previous release'
    [[ -d "${work[0]}/assets" && "$(snapshot "${work[0]}/assets")" == "$snapshot_expected" ]] || fail 'failed restore lost the complete candidate'
    [[ "$run_output" == *"$previous"* ]] || fail 'failed restore did not report the old release recovery path'

    reset_target cleanup
    run_build cleanup "$target"
    assert_injected cleanup
    [[ "$run_status" != 0 && "$(snapshot "$target")" == "$snapshot_expected" ]] || fail 'cleanup failure must retain the published release and fail'
    mapfile -t work < <(find "${target%/*}" -mindepth 1 -maxdepth 1 -type d -name '.vpsctl-release.*')
    [[ ${#work[@]} == 1 && "$run_output" == *"${work[0]}"* ]] || fail 'cleanup failure did not preserve and report its work directory'
    [[ -d "${work[0]}/previous" && "$(snapshot "${work[0]}/previous")" == "$snapshot_before" ]] || fail 'cleanup failure lost the old release backup'

    for scenario in gzip publish; do
        target="${area}/first-${scenario}/release with spaces"
        mkdir -p -- "${target%/*}"
        run_build "$scenario" "$target"
        assert_injected "first $scenario"
        [[ "$run_status" != 0 && ! -e "$target" ]] || fail "first $scenario failure left a partial output"
        assert_no_work "${target%/*}" "first $scenario failure"
    done

    for entry in unrelated directory symlink hidden invalid-name; do
        reset_target "reject-${entry}"
        case "$entry" in
            unrelated) printf 'keep me\n' >"${target}/notes.txt" ;;
            directory) mkdir "${target}/vpsctl-extra-0.0.0.tar.gz"; printf 'keep me\n' >"${target}/vpsctl-extra-0.0.0.tar.gz/nested" ;;
            symlink) ln -s vpsctl.sh "${target}/vpsctl-link-0.0.0.tar.gz" ;;
            hidden) printf 'keep me\n' >"${target}/.private" ;;
            invalid-name) cp "${target}/vpsctl-retired-0.0.0.tar.gz" "${target}/vpsctl-UPPER-0.0.0.tar.gz" ;;
        esac
        snapshot_before="$(snapshot "$target")"
        run_build none "$target"
        [[ "$run_status" != 0 ]] || fail "$entry entry was accepted in a release directory"
        assert_unchanged "$entry rejection"
        assert_no_work "${target%/*}" "$entry rejection"
    done

    mkdir -p -- "${area}/protected/source"
    cp -R -- "${TEST_ROOT}/scripts" "${TEST_ROOT}/bin" "${TEST_ROOT}/lib" "${TEST_ROOT}/commands" "${area}/protected/source/"
    cp -- "${TEST_ROOT}/VERSION" "${TEST_ROOT}/vpsctl.sh" "${area}/protected/source/"
    builder="${area}/protected/source/scripts/build-release.sh"
    snapshot_before="$(snapshot "${area}/protected")"
    for target in / "${area}/protected/source" "${area}/protected"; do
        run_build none "$target" "$builder"
        [[ "$run_status" != 0 ]] || fail "unsafe output path was accepted: $target"
        [[ "$(snapshot "${area}/protected")" == "$snapshot_before" ]] || fail "unsafe path rejection changed the source tree: $target"
    done
    printf 'release delivery tests passed\n'
)

[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'distribution VERSION must use X.Y.Z format'
bash "${TEST_ROOT}/scripts/build-release.sh" "$RELEASE_DIR"
if [[ "${VPSCTL_TEST_ONLY:-}" == release-delivery ]]; then
    test_release_delivery
    exit 0
fi

expected_bundles=(
    core shared-command shared-ufw shared-server-test
    network-bbr network-dns network-ip-policy network-ufw network-rfw
    system-kernel system-reinstall security-access security-fail2ban security-tls
    service-proxy service-tcping service-iperf3 test-nodequality test-tcpquality
)
expected_assets=(vpsctl.sh vpsctl-manifest.tsv)
for bundle in "${expected_bundles[@]}"; do
    expected_assets+=("vpsctl-${bundle}-${RELEASE_VERSION}.tar.gz")
done
for asset in "${expected_assets[@]}"; do
    assert_file "${RELEASE_DIR}/${asset}"
done
actual_assets="$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)"
expected_sorted="$(printf '%s\n' "${expected_assets[@]}" | sort)"
[[ "$actual_assets" == "$expected_sorted" ]] || fail 'release output contains an unexpected asset set'

mapfile -t manifest <"${RELEASE_DIR}/vpsctl-manifest.tsv"
[[ ${#manifest[@]} -eq 23 ]] || fail 'manifest record count is not 23'
[[ ${manifest[0]} == $'schema_version\t2' ]] || fail 'manifest schema record is invalid'
[[ ${manifest[1]} == $'version\t'"${RELEASE_VERSION}" ]] || fail 'manifest distribution version is invalid'
[[ ${manifest[2]} == $'repository\tRunarry/vps-script-lite' ]] || fail 'manifest repository is invalid'

expected_names=(launcher "${expected_bundles[@]}")
for index in "${!expected_names[@]}"; do
    IFS=$'\t' read -r kind name filename digest extra <<<"${manifest[index + 3]}"
    [[ -z "$extra" && "$name" == "${expected_names[index]}" ]] || fail "invalid manifest asset record ${index}"
    if ((index == 0)); then
        [[ "$kind" == asset && "$filename" == vpsctl.sh ]] || fail 'launcher manifest record is invalid'
    else
        [[ "$kind" == bundle && "$filename" == "vpsctl-${name}-${RELEASE_VERSION}.tar.gz" ]] || fail "bundle record is invalid: ${name}"
    fi
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "invalid digest: ${name}"
    if ((index == 0)); then
        [[ ${manifest[index + 3]} == $'asset\tlauncher\tvpsctl.sh\t'"$digest" ]] || fail 'launcher record is not strict TSV'
    else
        [[ ${manifest[index + 3]} == $'bundle\t'"$name"$'\t'"$filename"$'\t'"$digest" ]] || fail "bundle record is not strict TSV: ${name}"
    fi
    [[ "$(sha256sum "${RELEASE_DIR}/${filename}" | awk '{print $1}')" == "$digest" ]] || fail "digest mismatch: ${name}"
done

core="${RELEASE_DIR}/vpsctl-core-${RELEASE_VERSION}.tar.gz"
for member in \
    VERSION \
    bin/vpsctl \
    lib/environment.sh \
    lib/registry.sh \
    lib/ui.sh \
    lib/distribution.sh; do
    assert_archive_has "$core" "$member"
done
for member in commands/self/status.sh commands/self/update.sh commands/self/uninstall.sh; do
    assert_archive_has "$core" "$member"
done

# Check exact per-bundle file boundaries, including every required private module.
# shellcheck source=../../lib/distribution.sh disable=SC1091
source "$TEST_ROOT/lib/distribution.sh"
for bundle in "${expected_bundles[@]}"; do
    archive="${RELEASE_DIR}/vpsctl-${bundle}-${RELEASE_VERSION}.tar.gz"
    vps_distribution_validate_archive "$archive" "$bundle" || fail "unsafe bundle: $bundle"
    expected_files="$(vps_registry_bundle_files "$bundle" | sort)"
    actual_files="$(tar -tzf "$archive" | grep -v '/$' | sort)"
    [[ "$actual_files" == "$expected_files" ]] || fail "unexpected files in $bundle"
done
for shared in command ufw server-test; do
    assert_archive_has "${RELEASE_DIR}/vpsctl-shared-${shared}-${RELEASE_VERSION}.tar.gz" "lib/${shared}.sh"
done
for archive in "${RELEASE_DIR}"/*.tar.gz; do
    while IFS= read -r member; do
        [[ "$member" != /* && "$member" != ./* && "$member" != */../* ]] || fail "non-relative archive member: ${member}"
    done < <(tar -tzf "$archive")
done

fixture="${TEST_TEMP}/source"
mkdir -p -- "$fixture"
cp -R -- "${TEST_ROOT}/scripts" "${TEST_ROOT}/bin" "${TEST_ROOT}/lib" "${TEST_ROOT}/commands" "$fixture/"
cp -- "${TEST_ROOT}/VERSION" "${TEST_ROOT}/vpsctl.sh" "$fixture/"
find "$fixture" -type d -exec chmod 0700 -- {} +
find "$fixture" -type f -exec chmod 0600 -- {} +
# Unexpected checkout permissions must not leak into published files.
chmod 6777 -- "${fixture}/lib/environment.sh"
(
    umask 077
    bash "${fixture}/scripts/build-release.sh" "${TEST_TEMP}/restricted-release"
)
for asset in "${expected_assets[@]}"; do
    cmp -s -- "${RELEASE_DIR}/${asset}" "${TEST_TEMP}/restricted-release/${asset}" ||
        fail "release changed with source permissions or umask: ${asset}"
done

extracted="${TEST_TEMP}/extracted"
mkdir -p -- "$extracted"
for archive in "${TEST_TEMP}/restricted-release"/*.tar.gz; do
    # Restore archived modes even when the test itself inherits a strict umask.
    tar --same-permissions -xzf "$archive" -C "$extracted"
done
while IFS= read -r -d '' entry; do
    expected_mode=644
    if [[ -d "$entry" || "$entry" == "${extracted}/bin/vpsctl" ]]; then
        expected_mode=755
    fi
    [[ "$(stat -c '%a' -- "$entry")" == "$expected_mode" ]] ||
        fail "unexpected release permissions: ${entry#"${extracted}/"}"
done < <(find "$extracted" -mindepth 1 -print0)
"${extracted}/bin/vpsctl" --help >"${TEST_TEMP}/help.txt" || fail 'archived core entry point cannot run directly'
grep -F 'VPS Script Lite' "${TEST_TEMP}/help.txt" >/dev/null || fail 'archived core entry point did not show help'

# Changing only VERSION must change the entry point in the resulting core too.
printf '9.8.7\n' >"${fixture}/VERSION"
bash "${fixture}/scripts/build-release.sh" "${TEST_TEMP}/alternate-release"
mkdir -- "${TEST_TEMP}/alternate-core"
tar --same-permissions -xzf "${TEST_TEMP}/alternate-release/vpsctl-core-9.8.7.tar.gz" -C "${TEST_TEMP}/alternate-core"
[[ "$("${TEST_TEMP}/alternate-core/bin/vpsctl" --version)" == 'vpsctl 9.8.7' ]] ||
    fail 'archived core entry point did not use its VERSION file'

test_release_delivery
printf 'release build tests passed\n'
