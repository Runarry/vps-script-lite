#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 022

readonly RELEASE_REPOSITORY='Runarry/vps-script-lite'
readonly RELEASE_SCHEMA_VERSION='2'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
# shellcheck source=../lib/registry.sh disable=SC1091
source "${PROJECT_ROOT}/lib/registry.sh"
OUTPUT_DIR="${1:-${PROJECT_ROOT}/dist/release}"
BUILD_TEMP=''
ASSET_DIR=''

release_die() {
    printf 'build-release: %s\n' "$*" >&2
    exit 1
}

release_cleanup() {
    local status=$?

    trap - EXIT
    trap '' HUP INT TERM
    if [[ -n "$BUILD_TEMP" && -d "$BUILD_TEMP" ]]; then
        # A remaining candidate plus the old directory means publication did
        # not finish, even if a signal arrived immediately after either mv.
        if [[ -d "${BUILD_TEMP}/previous" && -d "${BUILD_TEMP}/assets" ]]; then
            if [[ -e "$OUTPUT_DIR" || -L "$OUTPUT_DIR" ]] ||
                ! mv -T -- "${BUILD_TEMP}/previous" "$OUTPUT_DIR"; then
                printf 'build-release: cannot restore output; previous assets retained at %s\n' "${BUILD_TEMP}/previous" >&2
                exit 1
            fi
        fi
        if ! rm -rf -- "$BUILD_TEMP"; then
            printf 'build-release: cannot clean build directory; retained at %s\n' "$BUILD_TEMP" >&2
            ((status != 0)) || status=1
        fi
    fi
    exit "$status"
}

trap release_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

release_require_output_directory() (
    local entry filename

    [[ -d "$OUTPUT_DIR" ]] || return 0
    [[ -r "$OUTPUT_DIR" && -x "$OUTPUT_DIR" ]] || release_die "cannot inspect output directory: $OUTPUT_DIR"
    shopt -s nullglob dotglob
    for entry in "$OUTPUT_DIR"/*; do
        filename="${entry##*/}"
        [[ -f "$entry" && ! -L "$entry" ]] || release_die "output contains a non-release entry: $entry"
        case "$filename" in
            vpsctl.sh | vpsctl-manifest.tsv) ;;
            *)
                [[ "$filename" =~ ^vpsctl-[a-z0-9]+(-[a-z0-9]+)*-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz$ ]] ||
                    release_die "output contains a non-release entry: $entry"
                ;;
        esac
    done
)

release_sha256() {
    sha256sum -- "$1" | awk '{print $1}'
}

release_create_bundle() {
    local name=$1
    shift
    local filename="vpsctl-${name}-${RELEASE_VERSION}.tar.gz"
    local tar_path="${BUILD_TEMP}/${filename%.gz}"
    local staging_dir="${BUILD_TEMP}/${name}"
    local relative_path=''
    local entry=''
    local staged_path=''
    local -a archive_roots=()

    for relative_path in "$@"; do
        if [[ -d "${PROJECT_ROOT}/${relative_path}" ]]; then
            release_require_tree "$relative_path"
        else
            release_require_regular "$relative_path"
        fi
    done

    mkdir -p -- "$staging_dir"
    for relative_path in "$@"; do
        while IFS= read -r -d '' entry; do
            staged_path="${staging_dir}/${entry#"${PROJECT_ROOT}/"}"
            if [[ -d "$entry" ]]; then
                mkdir -p -- "$staged_path"
            else
                install -D -m 0644 -- "$entry" "$staged_path"
            fi
        done < <(find "${PROJECT_ROOT}/${relative_path}" -print0)
    done
    # Archive explicit parent directories and fixed modes, independent of the
    # checkout's executable bits and the builder's umask.
    find "$staging_dir" -type d -exec chmod 0755 -- {} +
    if [[ "$name" == core ]]; then
        chmod 0755 -- "${staging_dir}/bin/vpsctl"
    fi
    mapfile -d '' -t archive_roots < <(find "$staging_dir" -mindepth 1 -maxdepth 1 -printf '%f\0' | sort -z)
    tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
        -C "$staging_dir" -cf "$tar_path" -- "${archive_roots[@]}"
    gzip -n "$tar_path"
    mv -- "${tar_path}.gz" "${ASSET_DIR}/${filename}"
}

release_require_tool awk
release_require_tool bash
release_require_tool chmod
release_require_tool find
release_require_tool gzip
release_require_tool grep
release_require_tool install
release_require_tool mktemp
release_require_tool sha256sum
release_require_tool sort
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
release_require_regular 'lib/ufw.sh'
release_require_regular 'lib/distribution.sh'
release_require_tree 'commands/self'
release_require_regular 'commands/self/status.sh'
release_require_regular 'commands/self/update.sh'
release_require_regular 'commands/self/uninstall.sh'

mkdir -p -- "$(dirname -- "$OUTPUT_DIR")"
if [[ -d "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$(cd -- "$OUTPUT_DIR" && pwd -P)"
else
    [[ ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || release_die "output path is not a directory: $OUTPUT_DIR"
    output_parent="$(cd -- "$(dirname -- "$OUTPUT_DIR")" && pwd -P)"
    OUTPUT_DIR="${output_parent%/}/$(basename -- "$OUTPUT_DIR")"
fi
[[ "$OUTPUT_DIR" != / && "$OUTPUT_DIR" != "$PROJECT_ROOT" && "$PROJECT_ROOT" != "$OUTPUT_DIR/"* ]] ||
    release_die 'output directory may not be the filesystem root, project root, or an ancestor of the project'
release_require_output_directory
BUILD_TEMP="$(mktemp -d "$(dirname -- "$OUTPUT_DIR")/.vpsctl-release.XXXXXXXX")"
ASSET_DIR="${BUILD_TEMP}/assets"
mkdir -- "$ASSET_DIR"

install -m 0755 -- "${PROJECT_ROOT}/vpsctl.sh" "${ASSET_DIR}/vpsctl.sh"

for name in "${VPS_BUNDLE_IDS[@]}"; do
    bundle_files="$(vps_registry_bundle_files "$name")" || release_die "unknown bundle: $name"
    mapfile -t bundle_paths <<<"$bundle_files"
    release_create_bundle "$name" "${bundle_paths[@]}"
done

MANIFEST_PATH="${ASSET_DIR}/vpsctl-manifest.tsv"
{
    printf 'schema_version\t%s\n' "$RELEASE_SCHEMA_VERSION"
    printf 'version\t%s\n' "$RELEASE_VERSION"
    printf 'repository\t%s\n' "$RELEASE_REPOSITORY"
    digest="$(release_sha256 "${ASSET_DIR}/vpsctl.sh")" || release_die 'cannot compute launcher SHA-256'
    printf 'asset\tlauncher\tvpsctl.sh\t%s\n' "$digest"
    for name in "${VPS_BUNDLE_IDS[@]}"; do
        filename="vpsctl-${name}-${RELEASE_VERSION}.tar.gz"
        digest="$(release_sha256 "${ASSET_DIR}/${filename}")" || release_die "cannot compute bundle SHA-256: $name"
        printf 'bundle\t%s\t%s\t%s\n' "$name" "$filename" "$digest"
    done
} >"$MANIFEST_PATH"

if [[ -d "$OUTPUT_DIR" ]]; then
    chmod --reference="$OUTPUT_DIR" "$ASSET_DIR"
    mv -T -- "$OUTPUT_DIR" "${BUILD_TEMP}/previous"
fi
mv -T -- "$ASSET_DIR" "$OUTPUT_DIR"

printf 'Release assets written to %s\n' "$OUTPUT_DIR"
