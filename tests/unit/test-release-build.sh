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

[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'distribution VERSION must use X.Y.Z format'
bash "${TEST_ROOT}/scripts/build-release.sh" "$RELEASE_DIR"

expected_assets=(
    vpsctl.sh
    vpsctl-manifest.tsv
    "vpsctl-core-${RELEASE_VERSION}.tar.gz"
    "vpsctl-network-${RELEASE_VERSION}.tar.gz"
    "vpsctl-system-${RELEASE_VERSION}.tar.gz"
    "vpsctl-security-${RELEASE_VERSION}.tar.gz"
    "vpsctl-service-${RELEASE_VERSION}.tar.gz"
    "vpsctl-test-${RELEASE_VERSION}.tar.gz"
)
for asset in "${expected_assets[@]}"; do
    assert_file "${RELEASE_DIR}/${asset}"
done
actual_assets="$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort)"
expected_sorted="$(printf '%s\n' "${expected_assets[@]}" | sort)"
[[ "$actual_assets" == "$expected_sorted" ]] || fail 'release output contains an unexpected asset set'

mapfile -t manifest <"${RELEASE_DIR}/vpsctl-manifest.tsv"
[[ ${#manifest[@]} -eq 10 ]] || fail 'manifest record count is not 10'
[[ ${manifest[0]} == $'schema_version\t1' ]] || fail 'manifest schema record is invalid'
[[ ${manifest[1]} == $'version\t'"${RELEASE_VERSION}" ]] || fail 'manifest distribution version is invalid'
[[ ${manifest[2]} == $'repository\tRunarry/vps-script-lite' ]] || fail 'manifest repository is invalid'

expected_names=(launcher core network system security service test)
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
    lib/command.sh \
    lib/distribution.sh; do
    assert_archive_has "$core" "$member"
done
for member in commands/self/status.sh commands/self/update.sh commands/self/uninstall.sh; do
    assert_archive_has "$core" "$member"
done

assert_archive_has "${RELEASE_DIR}/vpsctl-network-${RELEASE_VERSION}.tar.gz" commands/network/bbr.sh
assert_archive_has "${RELEASE_DIR}/vpsctl-system-${RELEASE_VERSION}.tar.gz" commands/system/kernel.sh
for member in providers inventory grub; do
    assert_archive_has "${RELEASE_DIR}/vpsctl-system-${RELEASE_VERSION}.tar.gz" "commands/system/kernel/${member}.sh"
done
assert_archive_has "${RELEASE_DIR}/vpsctl-security-${RELEASE_VERSION}.tar.gz" commands/security/access.sh
assert_archive_has "${RELEASE_DIR}/vpsctl-security-${RELEASE_VERSION}.tar.gz" commands/security/fail2ban.sh
assert_archive_has "${RELEASE_DIR}/vpsctl-security-${RELEASE_VERSION}.tar.gz" commands/security/tls.sh
assert_archive_has "${RELEASE_DIR}/vpsctl-service-${RELEASE_VERSION}.tar.gz" commands/service/proxy.sh
assert_archive_has "${RELEASE_DIR}/vpsctl-test-${RELEASE_VERSION}.tar.gz" commands/test/nodequality.sh
assert_archive_has "${RELEASE_DIR}/vpsctl-test-${RELEASE_VERSION}.tar.gz" commands/test/tcpquality.sh
assert_archive_has "${RELEASE_DIR}/vpsctl-test-${RELEASE_VERSION}.tar.gz" lib/server-test.sh

for archive in "${RELEASE_DIR}"/*.tar.gz; do
    while IFS= read -r member; do
        [[ "$member" != /* && "$member" != ./* && "$member" != */../* ]] || fail "non-relative archive member: ${member}"
    done < <(tar -tzf "$archive")
done

printf 'release build tests passed\n'
