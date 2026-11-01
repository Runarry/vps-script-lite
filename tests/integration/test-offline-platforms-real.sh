#!/usr/bin/env bash
# Execute only on the dedicated SSH environment. The matching official image
# must already be available from build-offline-release.sh; no network is given
# to the acceptance container. This does not replace real systemd service tests.
set -euo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ $# == 1 && -f "$1" ]] || { printf 'usage: test-offline-platforms-real.sh OFFLINE_ARCHIVE\n' >&2; exit 2; }
TEST_TEMP="$(mktemp -d -t vpsctl-offline-platform.XXXXXXXX)"
trap 'rm -rf -- "$TEST_TEMP"' EXIT
mkdir "${TEST_TEMP}/package"
tar -xzf "$1" -C "${TEST_TEMP}/package"
(cd "${TEST_TEMP}/package" && sha256sum --quiet --check SHA256SUMS)
mapfile -t target < <(awk -F '\t' '$1 == "os" || $1 == "os_version" || $1 == "architecture" {print $2}' "${TEST_TEMP}/package/offline-manifest.tsv")
[[ ${#target[@]} == 3 ]] || { printf 'invalid offline target metadata\n' >&2; exit 1; }
docker run --rm --pull never --network none --platform "linux/${target[2]}" \
    --mount "type=bind,source=${TEST_ROOT}/scripts/offline-build,target=/builder,readonly" \
    --mount "type=bind,source=${TEST_TEMP}/package,target=/offline,readonly" \
    "${target[0]}:${target[1]}" bash /builder/container-accept.sh "${target[@]}"
