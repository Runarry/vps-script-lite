#!/usr/bin/env bash
# No target: fresh online assets + one upstream snapshot, then all eight packages.
# Single target: --os OS --os-version VERSION --arch ARCH, with --online-dir and
# --snapshot-dir from the same release run. Requires Docker (and arm64 binfmt
# when cross-building). --aggregate only writes the eight-package checksum list.
set -euo pipefail
IFS=$'\n\t'
umask 022
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
OS='' OS_VERSION='' ARCH='' ONLINE_DIR='' SNAPSHOT_DIR='' AGGREGATE=0
OUTPUT_DIR="${PROJECT_ROOT}/dist/offline"
BUILD_TEMP=''
die() { printf 'build-offline-release: %s\n' "$*" >&2; exit 1; }
cleanup() { [[ -z "$BUILD_TEMP" ]] || rm -rf -- "$BUILD_TEMP"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
while (($#)); do
    case "$1" in
        --aggregate) AGGREGATE=1; shift ;;
        --os | --os-version | --arch | --online-dir | --snapshot-dir | --output-dir)
            (($# >= 2)) && [[ -n "$2" ]] || die "missing value for $1"
            case "$1" in
                --os) OS=$2 ;; --os-version) OS_VERSION=$2 ;; --arch) ARCH=$2 ;;
                --online-dir) ONLINE_DIR=$2 ;; --snapshot-dir) SNAPSHOT_DIR=$2 ;; --output-dir) OUTPUT_DIR=$2 ;;
            esac
            shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done
VERSION="$(<"${PROJECT_ROOT}/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'VERSION must use X.Y.Z format'
mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd -P)"
if ((AGGREGATE)); then
    [[ -z "$OS$OS_VERSION$ARCH$ONLINE_DIR$SNAPSHOT_DIR" ]] || die '--aggregate accepts only --output-dir'
    python3 "${SCRIPT_DIR}/offline-build/package.py" aggregate "$OUTPUT_DIR" "$VERSION"
    exit
fi
if [[ -n "$OS$OS_VERSION$ARCH" ]]; then
    case "$OS:$OS_VERSION:$ARCH" in
        debian:12:amd64 | debian:12:arm64 | debian:13:amd64 | debian:13:arm64 | \
        ubuntu:22.04:amd64 | ubuntu:22.04:arm64 | ubuntu:24.04:amd64 | ubuntu:24.04:arm64) ;;
        *) die 'target must be Debian 12/13 or Ubuntu 22.04/24.04, amd64/arm64' ;;
    esac
    [[ -n "$ONLINE_DIR" && -n "$SNAPSHOT_DIR" ]] || die 'single-target builds require --online-dir and --snapshot-dir'
fi
command -v docker >/dev/null || die 'Docker is required'
BUILD_TEMP="$(mktemp -d "${OUTPUT_DIR}/.vpsctl-offline.XXXXXXXX")"
if [[ -z "$ONLINE_DIR" ]]; then
    ONLINE_DIR="${BUILD_TEMP}/online"
    bash "${SCRIPT_DIR}/build-release.sh" "$ONLINE_DIR"
fi
if [[ -z "$SNAPSHOT_DIR" ]]; then
    SNAPSHOT_DIR="${BUILD_TEMP}/snapshot"
    bash "${SCRIPT_DIR}/resolve-offline-upstreams.sh" "$SNAPSHOT_DIR"
fi
ONLINE_DIR="$(cd -- "$ONLINE_DIR" && pwd -P)"
SNAPSHOT_DIR="$(cd -- "$SNAPSHOT_DIR" && pwd -P)"
python3 "${SCRIPT_DIR}/offline-build/package.py" online "$ONLINE_DIR" "$VERSION"
build_target() {
    local os=$1 os_version=$2 arch=$3 target_dir filename
    target_dir="${BUILD_TEMP}/${os}-${os_version}-${arch}"
    mkdir -- "$target_dir"
    [[ -d "${SNAPSHOT_DIR}/${arch}" ]] || die "snapshot has no ${arch} assets"
    # Use explicit official images for the target release and CPU architecture.
    docker run --rm --pull always --platform "linux/${arch}" \
        --mount "type=bind,source=${SCRIPT_DIR}/offline-build,target=/builder,readonly" \
        --mount "type=bind,source=${ONLINE_DIR},target=/online,readonly" \
        --mount "type=bind,source=${SNAPSHOT_DIR}/${arch},target=/snapshot,readonly" \
        --mount "type=bind,source=${target_dir},target=/output" \
        "${os}:${os_version}" bash /builder/container.sh "$os" "$os_version" "$arch" "$VERSION"
    filename="vpsctl-offline-${VERSION}-${os}-${os_version}-${arch}.tar.gz"
    [[ -f "${target_dir}/${filename}" && ! -L "${target_dir}/${filename}" ]] || die "container did not produce $filename"
    mv -f -- "${target_dir}/${filename}" "${OUTPUT_DIR}/${filename}"
    printf 'Offline release written to %s/%s\n' "$OUTPUT_DIR" "$filename"
}
if [[ -n "$OS" ]]; then
    build_target "$OS" "$OS_VERSION" "$ARCH"
else
    for target in debian:12 debian:13 ubuntu:22.04 ubuntu:24.04; do
        for arch in amd64 arm64; do build_target "${target%:*}" "${target#*:}" "$arch"; done
    done
    python3 "${SCRIPT_DIR}/offline-build/package.py" aggregate "$OUTPUT_DIR" "$VERSION"
fi
