#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly RELEASE_REPOSITORY='Runarry/vps-script-lite'
readonly RELEASE_SCHEMA_VERSION='1'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
OUTPUT_DIR="${1:-${PROJECT_ROOT}/dist/release}"
BUILD_TEMP=''

release_die() {
    printf 'build-release: %s\n' "$*" >&2
    exit 1
}

release_cleanup() {
    if [[ -n "$BUILD_TEMP" && -d "$BUILD_TEMP" ]]; then
        rm -rf -- "$BUILD_TEMP"
    fi
}

trap release_cleanup EXIT

release_require_tool() {
    command -v "$1" >/dev/null 2>&1 || release_die "required tool not found: $1"
}

release_require_regular() {
    local relative_path=$1
    [[ -f "${PROJECT_ROOT}/${relative_path}" && ! -L "${PROJECT_ROOT}/${relative_path}" ]] ||
        release_die "required regular file is missing: ${relative_path}"
}

release_require_tree() {
    local relative_path=$1
    local entry=''

    [[ -d "${PROJECT_ROOT}/${relative_path}" && ! -L "${PROJECT_ROOT}/${relative_path}" ]] ||
        release_die "required directory is missing: ${relative_path}"
    while IFS= read -r -d '' entry; do
        [[ ! -L "$entry" ]] || release_die "release input may not contain a symbolic link: ${entry#"${PROJECT_ROOT}/"}"
        [[ -f "$entry" || -d "$entry" ]] || release_die "unsupported release input: ${entry#"${PROJECT_ROOT}/"}"
    done < <(find "${PROJECT_ROOT}/${relative_path}" -mindepth 1 -print0)
}

release_sha256() {
    sha256sum -- "$1" | awk '{print $1}'
}

release_create_bundle() {
    local name=$1
    shift
    local filename="vpsctl-${name}-${RELEASE_VERSION}.tar.gz"
    local tar_path="${BUILD_TEMP}/${filename%.gz}"
    local relative_path=''

    for relative_path in "$@"; do
        if [[ -d "${PROJECT_ROOT}/${relative_path}" ]]; then
            release_require_tree "$relative_path"
        else
            release_require_regular "$relative_path"
        fi
    done

    tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
        -C "$PROJECT_ROOT" -cf "$tar_path" -- "$@"
    gzip -n "$tar_path"
    mv -- "${tar_path}.gz" "${OUTPUT_DIR}/${filename}"
}

release_require_tool awk
release_require_tool bash
release_require_tool find
release_require_tool gzip
release_require_tool grep
release_require_tool install
release_require_tool mktemp
release_require_tool sha256sum
release_require_tool tar

[[ $# -le 1 ]] || release_die 'usage: scripts/build-release.sh [output-directory]'
[[ -f "${PROJECT_ROOT}/VERSION" && ! -L "${PROJECT_ROOT}/VERSION" ]] || release_die 'VERSION is missing or unsafe'
RELEASE_VERSION="$(<"${PROJECT_ROOT}/VERSION")"
readonly RELEASE_VERSION
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || release_die 'VERSION must use X.Y.Z format'
release_require_regular 'vpsctl.sh'

release_require_regular 'bin/vpsctl'
release_require_regular 'lib/environment.sh'
release_require_regular 'lib/registry.sh'
release_require_regular 'lib/ui.sh'
release_require_regular 'lib/command.sh'
release_require_regular 'lib/distribution.sh'
release_require_tree 'commands/self'
release_require_regular 'commands/self/status.sh'
release_require_regular 'commands/self/update.sh'
release_require_regular 'commands/self/uninstall.sh'

mkdir -p -- "$OUTPUT_DIR"
OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd -P)"
[[ "$OUTPUT_DIR" != "$PROJECT_ROOT" ]] || release_die 'output directory may not be the project root'
BUILD_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-release.XXXXXXXX")"

rm -f -- \
    "${OUTPUT_DIR}/vpsctl.sh" \
    "${OUTPUT_DIR}/vpsctl-manifest.tsv" \
    "${OUTPUT_DIR}"/vpsctl-*-"${RELEASE_VERSION}".tar.gz

install -m 0755 -- "${PROJECT_ROOT}/vpsctl.sh" "${OUTPUT_DIR}/vpsctl.sh"

release_create_bundle core \
    VERSION \
    bin/vpsctl \
    lib/environment.sh \
    lib/registry.sh \
    lib/ui.sh \
    lib/command.sh \
    lib/distribution.sh \
    commands/self
release_create_bundle network commands/network
release_create_bundle system commands/system
release_create_bundle security commands/security
release_create_bundle service commands/service
release_create_bundle test commands/test lib/server-test.sh

MANIFEST_PATH="${OUTPUT_DIR}/vpsctl-manifest.tsv"
{
    printf 'schema_version\t%s\n' "$RELEASE_SCHEMA_VERSION"
    printf 'version\t%s\n' "$RELEASE_VERSION"
    printf 'repository\t%s\n' "$RELEASE_REPOSITORY"
    printf 'asset\tlauncher\tvpsctl.sh\t%s\n' "$(release_sha256 "${OUTPUT_DIR}/vpsctl.sh")"
    for name in core network system security service test; do
        filename="vpsctl-${name}-${RELEASE_VERSION}.tar.gz"
        printf 'bundle\t%s\t%s\t%s\n' "$name" "$filename" "$(release_sha256 "${OUTPUT_DIR}/${filename}")"
    done
} >"$MANIFEST_PATH"

printf 'Release assets written to %s\n' "$OUTPUT_DIR"
