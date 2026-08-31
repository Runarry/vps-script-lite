#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'
umask 022
export LC_ALL=C

VPSCTL_DISTRIBUTION_VERSION=''
readonly VPSCTL_RELEASE_REPOSITORY='Runarry/vps-script-lite'
VPSCTL_RELEASE_BASE_URL='https://github.com/Runarry/vps-script-lite/releases/latest/download'
readonly VPSCTL_MANIFEST_NAME='vpsctl-manifest.tsv'
readonly VPSCTL_ENTRY_POINT='/usr/local/bin/vpsctl'
readonly VPSCTL_INSTALL_ROOT='/usr/local/lib/vpsctl'
readonly VPSCTL_RELEASES_DIR='/usr/local/lib/vpsctl/releases'
readonly VPSCTL_CURRENT_LINK='/usr/local/lib/vpsctl/current'
readonly VPSCTL_SELF_STATE='/var/lib/vpsctl/self'

VPSCTL_TEMP_DIR=''
declare -A VPSCTL_MANIFEST_FILES=()
declare -A VPSCTL_MANIFEST_HASHES=()

vpsctl_bootstrap_die() {
    printf 'vpsctl bootstrap: %s\n' "$*" >&2
    exit 1
}

vpsctl_bootstrap_cleanup() {
    if [[ -n "$VPSCTL_TEMP_DIR" && -d "$VPSCTL_TEMP_DIR" ]]; then
        rm -rf -- "$VPSCTL_TEMP_DIR"
    fi
}

trap vpsctl_bootstrap_cleanup EXIT

vpsctl_require_platform() {
    ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) ||
        vpsctl_bootstrap_die 'Bash 4.4 or newer is required'
    [[ "$(uname -s)" == 'Linux' ]] || vpsctl_bootstrap_die 'Linux is required'
}

vpsctl_require_install_privilege() {
    [[ "$(id -u)" == '0' ]] || vpsctl_bootstrap_die 'run as root'
}

vpsctl_require_tools() {
    local tool=''
    for tool in awk bash chmod curl find id install ln mkdir mktemp mv readlink rm sha256sum tar uname; do
        command -v "$tool" >/dev/null 2>&1 || vpsctl_bootstrap_die "required tool not found: ${tool}"
    done
}

vpsctl_sha256() {
    sha256sum -- "$1" | awk '{print $1}'
}

vpsctl_download() {
    local filename=$1
    local destination=$2

    curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --fail --location --silent --show-error \
        --output "$destination" "${VPSCTL_RELEASE_BASE_URL}/${filename}"
    [[ -f "$destination" && ! -L "$destination" ]] ||
        vpsctl_bootstrap_die "download did not produce a regular file: ${filename}"
}

vpsctl_validate_manifest() {
    local manifest=$1
    local -a lines=()
    local -a bundle_names=(core network system security service test)
    local index=0
    local line=''
    local kind=''
    local name=''
    local filename=''
    local digest=''
    local extra=''

    [[ -f "$manifest" && ! -L "$manifest" ]] || vpsctl_bootstrap_die 'manifest is not a safe regular file'
    mapfile -t lines <"$manifest"
    [[ ${#lines[@]} -eq 10 ]] || vpsctl_bootstrap_die 'manifest must contain exactly 10 records'
    for line in "${lines[@]}"; do
        [[ -n "$line" && "$line" != *$'\r'* ]] || vpsctl_bootstrap_die 'manifest contains an invalid record'
    done
    [[ ${lines[0]} == $'schema_version\t1' ]] || vpsctl_bootstrap_die 'unsupported manifest schema'
    [[ ${lines[1]} =~ ^version$'\t'([0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
        vpsctl_bootstrap_die 'invalid distribution version in manifest'
    VPSCTL_DISTRIBUTION_VERSION="${BASH_REMATCH[1]}"
    [[ ${lines[2]} == $'repository\tRunarry/vps-script-lite' ]] || vpsctl_bootstrap_die 'unexpected repository in manifest'

    IFS=$'\t' read -r kind name filename digest extra <<<"${lines[3]}"
    [[ "$kind" == asset && "$name" == launcher && "$filename" == vpsctl.sh && -z "$extra" ]] ||
        vpsctl_bootstrap_die 'invalid launcher manifest record'
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || vpsctl_bootstrap_die 'invalid launcher SHA256'
    [[ ${lines[3]} == $'asset\tlauncher\tvpsctl.sh\t'"$digest" ]] ||
        vpsctl_bootstrap_die 'launcher manifest record is not strict TSV'
    VPSCTL_MANIFEST_FILES[launcher]=$filename
    VPSCTL_MANIFEST_HASHES[launcher]=$digest

    for index in "${!bundle_names[@]}"; do
        IFS=$'\t' read -r kind name filename digest extra <<<"${lines[index + 4]}"
        [[ "$kind" == bundle && "$name" == "${bundle_names[index]}" && -z "$extra" ]] ||
            vpsctl_bootstrap_die 'invalid or out-of-order bundle manifest record'
        [[ "$filename" == "vpsctl-${name}-${VPSCTL_DISTRIBUTION_VERSION}.tar.gz" ]] ||
            vpsctl_bootstrap_die "unexpected bundle filename: ${filename}"
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || vpsctl_bootstrap_die "invalid SHA256 for bundle: ${name}"
        [[ ${lines[index + 4]} == $'bundle\t'"$name"$'\t'"$filename"$'\t'"$digest" ]] ||
            vpsctl_bootstrap_die "bundle manifest record is not strict TSV: ${name}"
        VPSCTL_MANIFEST_FILES[$name]=$filename
        VPSCTL_MANIFEST_HASHES[$name]=$digest
    done
}

vpsctl_verify_file() {
    local path=$1
    local expected=$2
    local label=$3
    local actual=''

    [[ -f "$path" && ! -L "$path" ]] || vpsctl_bootstrap_die "unsafe ${label} file"
    actual="$(vpsctl_sha256 "$path")"
    [[ "$actual" == "$expected" ]] || vpsctl_bootstrap_die "SHA256 verification failed for ${label}"
}

vpsctl_validate_launcher() {
    local launcher=$1

    vpsctl_verify_file "$launcher" "${VPSCTL_MANIFEST_HASHES[launcher]}" 'launcher'
    bash -n "$launcher" || vpsctl_bootstrap_die 'downloaded launcher has invalid Bash syntax'
}

vpsctl_stage_canonical_launcher() {
    local manifest=''
    local launcher=''
    local status=0

    VPSCTL_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-bootstrap.XXXXXXXX")"
    manifest="${VPSCTL_TEMP_DIR}/${VPSCTL_MANIFEST_NAME}"
    launcher="${VPSCTL_TEMP_DIR}/vpsctl.sh"
    vpsctl_download "$VPSCTL_MANIFEST_NAME" "$manifest"
    vpsctl_validate_manifest "$manifest"
    vpsctl_download "${VPSCTL_MANIFEST_FILES[launcher]}" "$launcher"
    vpsctl_validate_launcher "$launcher"
    chmod 0755 "$launcher"

    VPSCTL_VERIFIED_STAGE=1 \
    VPSCTL_VERIFIED_MANIFEST="$manifest" \
        bash "$launcher" "$@" || status=$?
    exit "$status"
}

vpsctl_path_has_symlink_component() {
    local path=$1
    local component=''
    local current=''
    local -a components=()

    [[ "$path" == /* ]] || return 0
    IFS='/' read -r -a components <<<"${path#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        current="${current}/${component}"
        [[ ! -L "$current" ]] || return 0
    done
    return 1
}

vpsctl_prepare_directory() {
    local path=$1
    local mode=$2

    ! vpsctl_path_has_symlink_component "$path" || vpsctl_bootstrap_die "refusing symbolic-link directory path: ${path}"
    mkdir -p -- "$path"
    chmod "$mode" "$path"
}

vpsctl_validate_archive_paths() {
    local archive=$1
    local entry=''
    local listing_line=''
    local type=''
    local found_version=0
    local found_entry=0

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || vpsctl_bootstrap_die 'core archive contains an empty path'
        [[ "$entry" =~ ^[A-Za-z0-9._/@+-]+/?$ ]] || vpsctl_bootstrap_die "core archive contains an unsafe path: ${entry}"
        [[ "$entry" != /* && "$entry" != ../* && "$entry" != */../* && "$entry" != */.. ]] ||
            vpsctl_bootstrap_die "core archive escapes its root: ${entry}"
        case "$entry" in
            VERSION) found_version=1 ;;
            bin | bin/ | bin/vpsctl | lib | lib/ | lib/environment.sh | lib/registry.sh | lib/ui.sh | lib/command.sh | lib/distribution.sh | commands | commands/ | commands/self | commands/self/ | commands/self/*) ;;
            *) vpsctl_bootstrap_die "unexpected path in core archive: ${entry}" ;;
        esac
        [[ "$entry" != bin/vpsctl ]] || found_entry=1
    done < <(tar -tzf "$archive")
    ((found_version == 1 && found_entry == 1)) || vpsctl_bootstrap_die 'core archive is missing required entry points'

    while IFS= read -r listing_line; do
        type=${listing_line:0:1}
        [[ "$type" == '-' || "$type" == 'd' ]] ||
            vpsctl_bootstrap_die 'core archive contains a link or special file'
    done < <(tar -tvzf "$archive")
}

vpsctl_validate_release_tree() {
    local root=$1
    local script=''
    local special=''
    local required=''
    local -a required_files=(
        VERSION bin/vpsctl lib/environment.sh lib/registry.sh lib/ui.sh lib/command.sh lib/distribution.sh
        commands/self/status.sh commands/self/update.sh commands/self/uninstall.sh
    )

    special="$(find "$root" \( -type l -o ! -type d -a ! -type f \) -print -quit)"
    [[ -z "$special" ]] || vpsctl_bootstrap_die 'extracted core contains a link or special file'
    for required in "${required_files[@]}"; do
        [[ -f "${root}/${required}" && ! -L "${root}/${required}" ]] ||
            vpsctl_bootstrap_die "extracted core is missing ${required}"
    done
    [[ "$(<"${root}/VERSION")" == "$VPSCTL_DISTRIBUTION_VERSION" ]] ||
        vpsctl_bootstrap_die 'extracted core has an unexpected distribution version'
    [[ -d "${root}/commands/self" && ! -L "${root}/commands/self" ]] ||
        vpsctl_bootstrap_die 'extracted core is missing commands/self'

    bash -n "${root}/bin/vpsctl" || vpsctl_bootstrap_die 'bin/vpsctl has invalid Bash syntax'
    while IFS= read -r -d '' script; do
        bash -n "$script" || vpsctl_bootstrap_die "invalid Bash syntax in ${script#"${root}/"}"
    done < <(find "$root/lib" "$root/commands/self" -type f -name '*.sh' -print0)
}

vpsctl_check_managed_paths() {
    local target=''
    local current_hash=''
    local recorded_hash=''

    if [[ -e "$VPSCTL_ENTRY_POINT" || -L "$VPSCTL_ENTRY_POINT" ]]; then
        [[ -f "$VPSCTL_ENTRY_POINT" && ! -L "$VPSCTL_ENTRY_POINT" ]] ||
            vpsctl_bootstrap_die "refusing to overwrite non-managed entry: ${VPSCTL_ENTRY_POINT}"
        current_hash="$(vpsctl_sha256 "$VPSCTL_ENTRY_POINT")"
        if [[ -f "${VPSCTL_SELF_STATE}/entry.sha256" && ! -L "${VPSCTL_SELF_STATE}/entry.sha256" ]]; then
            recorded_hash="$(<"${VPSCTL_SELF_STATE}/entry.sha256")"
        fi
        [[ "$current_hash" == "${VPSCTL_MANIFEST_HASHES[launcher]}" || "$current_hash" == "$recorded_hash" ]] ||
            vpsctl_bootstrap_die "refusing to overwrite non-managed entry: ${VPSCTL_ENTRY_POINT}"
    fi
    if [[ -e "$VPSCTL_CURRENT_LINK" || -L "$VPSCTL_CURRENT_LINK" ]]; then
        [[ -L "$VPSCTL_CURRENT_LINK" ]] || vpsctl_bootstrap_die "refusing non-managed current path: ${VPSCTL_CURRENT_LINK}"
        target="$(readlink -- "$VPSCTL_CURRENT_LINK")"
        [[ "$target" == "${VPSCTL_RELEASES_DIR}/"* ]] ||
            vpsctl_bootstrap_die "refusing non-managed current link: ${VPSCTL_CURRENT_LINK}"
    fi
}

vpsctl_atomic_symlink() {
    local target=$1
    local destination=$2
    local temporary="${destination}.tmp.$$"

    [[ ! -e "$temporary" && ! -L "$temporary" ]] || vpsctl_bootstrap_die "temporary link already exists: ${temporary}"
    ln -s -- "$target" "$temporary"
    mv -Tf -- "$temporary" "$destination"
}

vpsctl_record_self_state() {
    local manifest=$1
    local launcher=$2
    local temporary=''

    temporary="${VPSCTL_SELF_STATE}/manifest.tsv.tmp.$$"
    install -m 0644 -- "$manifest" "$temporary"
    mv -Tf -- "$temporary" "${VPSCTL_SELF_STATE}/manifest.tsv"
    temporary="${VPSCTL_SELF_STATE}/vpsctl.sh.tmp.$$"
    install -m 0755 -- "$launcher" "$temporary"
    mv -Tf -- "$temporary" "${VPSCTL_SELF_STATE}/vpsctl.sh"
    temporary="${VPSCTL_SELF_STATE}/entry.sha256.tmp.$$"
    printf '%s\n' "${VPSCTL_MANIFEST_HASHES[launcher]}" >"$temporary"
    chmod 0600 "$temporary"
    mv -Tf -- "$temporary" "${VPSCTL_SELF_STATE}/entry.sha256"
}

vpsctl_write_release_metadata() {
    local release_root=$1
    local manifest=$2
    local temporary=''

    mkdir -p -- "${release_root}/.release" "${release_root}/.bundles"
    chmod 0755 "${release_root}/.release" "${release_root}/.bundles"
    install -m 0644 -- "$manifest" "${release_root}/.release/manifest.tsv"
    temporary="${release_root}/.bundles/core.sha256.tmp.$$"
    printf '%s\n' "${VPSCTL_MANIFEST_HASHES[core]}" >"$temporary"
    chmod 0644 "$temporary"
    mv -Tf -- "$temporary" "${release_root}/.bundles/core.sha256"
}

vpsctl_install_launcher_entry() {
    local launcher=$1
    local temporary="${VPSCTL_ENTRY_POINT}.tmp.$$"

    ! vpsctl_path_has_symlink_component '/usr/local/bin' ||
        vpsctl_bootstrap_die 'refusing symbolic-link entry directory: /usr/local/bin'
    mkdir -p -- '/usr/local/bin'
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || vpsctl_bootstrap_die "temporary entry already exists: ${temporary}"
    install -m 0755 -- "$launcher" "$temporary"
    mv -Tf -- "$temporary" "$VPSCTL_ENTRY_POINT"
}

vpsctl_install_core() {
    local manifest=$1
    local launcher=$2
    local archive=''
    local release_dir="${VPSCTL_RELEASES_DIR}/${VPSCTL_DISTRIBUTION_VERSION}"
    local staging=''

    archive="${VPSCTL_TEMP_DIR}/${VPSCTL_MANIFEST_FILES[core]}"
    vpsctl_download "${VPSCTL_MANIFEST_FILES[core]}" "$archive"
    vpsctl_verify_file "$archive" "${VPSCTL_MANIFEST_HASHES[core]}" 'core bundle'
    vpsctl_validate_archive_paths "$archive"

    vpsctl_prepare_directory "$VPSCTL_RELEASES_DIR" 0755
    vpsctl_prepare_directory "$VPSCTL_SELF_STATE" 0700
    vpsctl_check_managed_paths

    staging="$(mktemp -d "${VPSCTL_RELEASES_DIR}/.${VPSCTL_DISTRIBUTION_VERSION}.XXXXXXXX")"
    tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$staging"
    vpsctl_validate_release_tree "$staging"
    chmod 0755 "$staging/bin/vpsctl"
    printf '%s\t%s\n' "$VPSCTL_RELEASE_REPOSITORY" "$VPSCTL_DISTRIBUTION_VERSION" >"${staging}/.vpsctl-managed-release"
    vpsctl_write_release_metadata "$staging" "$manifest"

    if [[ -e "$release_dir" || -L "$release_dir" ]]; then
        [[ -d "$release_dir" && ! -L "$release_dir" ]] || vpsctl_bootstrap_die "release path is unsafe: ${release_dir}"
        [[ -f "${release_dir}/.vpsctl-managed-release" ]] || vpsctl_bootstrap_die "refusing to replace an unmanaged release: ${release_dir}"
        [[ "$(<"${release_dir}/.vpsctl-managed-release")" == $'Runarry/vps-script-lite\t'"${VPSCTL_DISTRIBUTION_VERSION}" ]] ||
            vpsctl_bootstrap_die "release ownership marker is invalid: ${release_dir}"
        vpsctl_validate_release_tree "$release_dir"
        [[ -f "${release_dir}/.release/manifest.tsv" && ! -L "${release_dir}/.release/manifest.tsv" ]] ||
            vpsctl_bootstrap_die "installed release manifest is missing: ${release_dir}"
        [[ "$(vpsctl_sha256 "${release_dir}/.release/manifest.tsv")" == "$(vpsctl_sha256 "$manifest")" ]] ||
            vpsctl_bootstrap_die "installed release manifest differs from the canonical manifest: ${release_dir}"
        [[ -f "${release_dir}/.bundles/core.sha256" && ! -L "${release_dir}/.bundles/core.sha256" ]] ||
            vpsctl_bootstrap_die "installed core digest is missing: ${release_dir}"
        [[ "$(<"${release_dir}/.bundles/core.sha256")" == "${VPSCTL_MANIFEST_HASHES[core]}" ]] ||
            vpsctl_bootstrap_die "installed core digest is invalid: ${release_dir}"
        rm -rf -- "$staging"
    else
        mv -- "$staging" "$release_dir"
    fi

    vpsctl_atomic_symlink "$release_dir" "$VPSCTL_CURRENT_LINK"
    vpsctl_install_launcher_entry "$launcher"
    vpsctl_record_self_state "$manifest" "$launcher"
}

vpsctl_exec_current() {
    export VPSCTL_DISTRIBUTED=1
    export VPSCTL_INSTALL_ROOT
    export VPSCTL_SELF_STATE_ROOT='/var/lib/vpsctl/self'
    exec "${VPSCTL_CURRENT_LINK}/bin/vpsctl" "$@"
}

vpsctl_main() {
    local manifest=''
    local launcher=''
    local provided_manifest=''

    vpsctl_require_platform

    if [[ -x "${VPSCTL_CURRENT_LINK}/bin/vpsctl" ]]; then
        vpsctl_exec_current "$@"
    fi
    vpsctl_require_install_privilege
    vpsctl_require_tools
    if [[ "${1:-}" == '--verified-manifest' ]]; then
        (($# >= 2)) || vpsctl_bootstrap_die '--verified-manifest requires a local manifest path'
        provided_manifest="$2"
        shift 2
        provided_manifest="$(readlink -f -- "$provided_manifest")"
        [[ -f "$provided_manifest" && ! -L "$provided_manifest" ]] ||
            vpsctl_bootstrap_die 'verified manifest path is not a safe regular file'
        manifest="$provided_manifest"
        launcher=${BASH_SOURCE[0]}
    elif [[ "${VPSCTL_VERIFIED_STAGE:-0}" != '1' ]]; then
        if [[ "$(readlink -f -- "${BASH_SOURCE[0]}")" == "$VPSCTL_ENTRY_POINT" &&
            -f "${VPSCTL_SELF_STATE}/manifest.tsv" && ! -L "${VPSCTL_SELF_STATE}/manifest.tsv" ]]; then
            manifest="${VPSCTL_SELF_STATE}/manifest.tsv"
            launcher=${BASH_SOURCE[0]}
        else
            vpsctl_stage_canonical_launcher "$@"
        fi
    else
        manifest=${VPSCTL_VERIFIED_MANIFEST:-}
        launcher=${BASH_SOURCE[0]}
    fi

    [[ -n "$manifest" ]] || vpsctl_bootstrap_die 'verified manifest path is missing'
    VPSCTL_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-install.XXXXXXXX")"
    vpsctl_validate_manifest "$manifest"
    VPSCTL_RELEASE_BASE_URL="https://github.com/${VPSCTL_RELEASE_REPOSITORY}/releases/download/v${VPSCTL_DISTRIBUTION_VERSION}"
    vpsctl_validate_launcher "$launcher"
    vpsctl_install_core "$manifest" "$launcher"
    vpsctl_bootstrap_cleanup
    VPSCTL_TEMP_DIR=''
    vpsctl_exec_current "$@"
}

vpsctl_main "$@"
