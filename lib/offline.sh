# shellcheck shell=bash
# Public result variables are consumed by distribution and feature modules.
# shellcheck disable=SC2034
# Offline release resources. Loading this library does not change the system.
if [[ "${VPS_OFFLINE_LOADED:-0}" == 1 ]]; then return 0; fi
VPS_OFFLINE_LOADED=1

vps_offline_error() { printf 'vpsctl：离线包：%s\n' "$*" >&2; }

vps_offline_active() {
    [[ -n "${VPSCTL_PROJECT_ROOT:-}" && ( -e "$VPSCTL_PROJECT_ROOT/.offline" || -L "$VPSCTL_PROJECT_ROOT/.offline" ) ]]
}

vps_offline_relative_path() {
    local path="${1:-}"
    [[ "$path" =~ ^[A-Za-z0-9_][A-Za-z0-9_./+:%@=~-]*$ &&
        "/$path/" != *'/../'* && "/$path/" != *'/./'* &&
        "$path" != *'//'* && "$path" != */ ]]
}

vps_offline_no_links() {
    local path="$1" current='' part
    local -a parts=()
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\t'* ]] || return 3
    IFS=/ read -r -a parts <<<"$path"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        current+="/$part"
        [[ ! -L "$current" ]] || return 3
    done
}

vps_offline_sha256() {
    local digest
    digest="$(sha256sum -- "$1")" || return 20
    printf '%s' "${digest%% *}"
}

vps_offline_read_metadata() {
    local root="$1" file="$1/offline-manifest.tsv" value
    local -a lines=()
    [[ -d "$root" && ! -L "$root" && -f "$file" && ! -L "$file" ]] || return 10
    vps_offline_no_links "$root" || return 3
    mapfile -t lines <"$file"
    ((${#lines[@]} == 6)) || return 10
    [[ "${lines[0]}" == $'schema_version\t1' &&
        "${lines[1]}" =~ ^version$'\t'([0-9]+\.[0-9]+\.[0-9]+)$ ]] || return 10
    VPS_OFFLINE_VERSION="${BASH_REMATCH[1]}"
    case "${lines[2]}" in $'os\tdebian') VPS_OFFLINE_OS=debian ;; $'os\tubuntu') VPS_OFFLINE_OS=ubuntu ;; *) return 10 ;; esac
    value="${lines[3]#os_version$'\t'}"
    [[ "${lines[3]}" == $'os_version\t'"$value" ]] || return 10
    case "$VPS_OFFLINE_OS:$value" in debian:12 | debian:13 | ubuntu:22.04 | ubuntu:24.04) ;; *) return 10 ;; esac
    VPS_OFFLINE_OS_VERSION="$value"
    case "${lines[4]}" in $'architecture\tamd64') VPS_OFFLINE_ARCH=amd64 ;; $'architecture\tarm64') VPS_OFFLINE_ARCH=arm64 ;; *) return 10 ;; esac
    [[ "${lines[5]}" =~ ^built_at$'\t'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 10
    VPS_OFFLINE_BUILT_AT="${lines[5]#built_at$'\t'}"
    VPS_OFFLINE_ROOT="$root"
}

vps_offline_check_platform() (
    local ID='' VERSION_ID='' os_release=/etc/os-release arch
    if [[ "${VPSCTL_TESTING:-0}" == 1 && -n "${VPSCTL_SYSTEM_ROOT:-}" && -f "$VPSCTL_SYSTEM_ROOT/etc/os-release" ]]; then
        os_release="$VPSCTL_SYSTEM_ROOT/etc/os-release"
    fi
    [[ -f "$os_release" ]] || return 3
    # shellcheck source=/dev/null
    source "$os_release"
    arch="$(uname -m)" || return 3
    case "$arch" in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) return 3 ;; esac
    [[ "$ID" == "$VPS_OFFLINE_OS" && "$VERSION_ID" == "$VPS_OFFLINE_OS_VERSION" && "$arch" == "$VPS_OFFLINE_ARCH" ]] || {
        vps_offline_error "平台不匹配：包为 $VPS_OFFLINE_OS $VPS_OFFLINE_OS_VERSION $VPS_OFFLINE_ARCH，本机为 $ID $VERSION_ID $arch"
        return 3
    }
)

vps_offline_check_file() {
    local root="$1" relative="$2" line expected='' name actual
    vps_offline_relative_path "$relative" || return 10
    [[ -f "$root/$relative" && ! -L "$root/$relative" ]] || return 10
    vps_offline_no_links "$root/$relative" || return 3
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([0-9a-f]{64})\ \ (.+)$ ]] || return 10
        name="${BASH_REMATCH[2]}"
        if [[ "$name" == "$relative" ]]; then
            [[ -z "$expected" ]] || return 10
            expected="${BASH_REMATCH[1]}"
        fi
    done <"$root/SHA256SUMS"
    [[ -n "$expected" ]] || return 10
    actual="$(vps_offline_sha256 "$root/$relative")" || return $?
    [[ "$actual" == "$expected" ]] || { vps_offline_error "文件摘要不匹配：$relative"; return 10; }
}

vps_offline_read_components() {
    local root="$1" wanted="${2:-}" requested="${3:-}" channel="${4:-stable}"
    local line kind id tag asset sha relative url extra actual
    local -A seen=()
    [[ -z "$channel" || "$channel" == stable ]] || { vps_offline_error '包内不包含预发布通道'; return 3; }
    [[ -f "$root/components.tsv" && ! -L "$root/components.tsv" ]] || return 10
    while IFS= read -r line || [[ -n "$line" ]]; do
        IFS=$'\t' read -r kind id tag asset sha relative url extra <<<"$line"
        [[ "$kind" == component && -z "$extra" && "$tag" =~ ^v?[0-9][A-Za-z0-9.+_-]*$ &&
            "$asset" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$sha" =~ ^[0-9a-f]{64}$ &&
            "$url" == https://github.com/* && "$relative" == "upstream/$id/$asset" &&
            "$line" == $'component\t'"$id"$'\t'"$tag"$'\t'"$asset"$'\t'"$sha"$'\t'"$relative"$'\t'"$url" ]] || return 10
        case "$id" in xray | sing-box | lego | rfw) ;; *) return 10 ;; esac
        [[ -z "${seen[$id]+set}" ]] || return 10
        seen[$id]=1
        vps_offline_relative_path "$relative" || return 10
        [[ -f "$root/$relative" && ! -L "$root/$relative" ]] || return 10
        if [[ -z "$wanted" ]]; then
            actual="$(vps_offline_sha256 "$root/$relative")" || return $?
            [[ "$actual" == "$sha" ]] || { vps_offline_error "$id 组件与登记摘要不一致"; return 10; }
        fi
        if [[ "$id" == "$wanted" ]]; then
            [[ -z "$requested" || "$requested" == "$tag" ]] || {
                vps_offline_error "$id 仅包含 $tag，不包含请求版本 $requested"
                return 3
            }
            VPS_OFFLINE_COMPONENT_TAG="$tag"
            VPS_OFFLINE_COMPONENT_ASSET="$asset"
            VPS_OFFLINE_COMPONENT_SHA256="$sha"
            VPS_OFFLINE_COMPONENT_PATH="$root/$relative"
            VPS_OFFLINE_COMPONENT_URL="$url"
        fi
    done <"$root/components.tsv"
    ((${#seen[@]} == 4)) && [[ -z "$wanted" || -n "${seen[$wanted]+set}" ]] || return 10
}

vps_offline_validate_package() {
    local root file relative line name sha actual count=0
    local -A listed=()
    root="$(cd -- "$1" && pwd -P)" || return 3
    vps_offline_read_metadata "$root" || { vps_offline_error '离线元数据缺失或格式错误'; return 10; }
    vps_offline_check_platform || return $?
    [[ -f "$root/SHA256SUMS" && ! -L "$root/SHA256SUMS" ]] || return 10
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^([0-9a-f]{64})\ \ (.+)$ ]] || return 10
        sha="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]}"
        vps_offline_relative_path "$name" && [[ "$name" != SHA256SUMS && -z "${listed[$name]+set}" ]] || return 10
        [[ -f "$root/$name" && ! -L "$root/$name" ]] || return 10
        listed[$name]="$sha"
    done <"$root/SHA256SUMS"
    while IFS= read -r -d '' file; do
        [[ -d "$file" && ! -L "$file" ]] && continue
        [[ -f "$file" && ! -L "$file" ]] || { vps_offline_error '离线包含链接或特殊文件'; return 10; }
        relative="${file#"$root"/}"
        [[ "$relative" == SHA256SUMS ]] && continue
        [[ -n "${listed[$relative]+set}" ]] || { vps_offline_error "未登记文件：$relative"; return 10; }
        count=$((count + 1))
    done < <(find "$root" -mindepth 1 -print0)
    ((count == ${#listed[@]})) || return 10
    (cd -- "$root" && sha256sum --check --strict --status SHA256SUMS) || {
        vps_offline_error '文件校验失败'; return 10;
    }
    for relative in vpsctl.sh vpsctl-manifest.tsv offline-manifest.tsv components.tsv apt/Packages apt/packages.tsv; do
        [[ -n "${listed[$relative]+set}" ]] || return 10
    done
    [[ -n "$(find "$root/apt/pool" -maxdepth 1 -type f -name '*.deb' -print -quit)" ]] || return 10
    vps_offline_read_components "$root" || return $?
    if ! declare -F vps_distribution_parse_manifest >/dev/null; then
        # Feature processes normally load only command.sh and this helper.
        # shellcheck source=distribution.sh disable=SC1091
        source "$(dirname -- "${BASH_SOURCE[0]}")/distribution.sh" || return 3
    fi
    vps_distribution_parse_manifest "$root/vpsctl-manifest.tsv" || return $?
    [[ "$VPS_DISTRIBUTION_MANIFEST_VERSION" == "$VPS_OFFLINE_VERSION" &&
        "${listed[vpsctl.sh]}" == "$VPS_DISTRIBUTION_LAUNCHER_SHA256" ]] || return 10
    for name in "${!VPS_DISTRIBUTION_BUNDLE_FILE[@]}"; do
        file="${VPS_DISTRIBUTION_BUNDLE_FILE[$name]}"
        sha="${VPS_DISTRIBUTION_BUNDLE_SHA256[$name]}"
        [[ "${listed[$file]:-}" == "$sha" ]] || return 10
    done
    actual="$(vps_offline_sha256 "$root/SHA256SUMS")" || return $?
    VPS_OFFLINE_PACKAGE_SHA256="$actual"
}

vps_offline_runtime_root() {
    local root="${VPSCTL_PROJECT_ROOT:?}/.offline" anchor="${VPSCTL_PROJECT_ROOT}/.release/offline.sha256" expected
    [[ -f "$anchor" && ! -L "$anchor" && -f "$root/SHA256SUMS" && ! -L "$root/SHA256SUMS" ]] || return 10
    vps_offline_no_links "$anchor" && vps_offline_no_links "$root" || return 3
    expected="$(<"$anchor")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ && "$(vps_offline_sha256 "$root/SHA256SUMS")" == "$expected" ]] || return 10
    vps_offline_check_file "$root" offline-manifest.tsv && vps_offline_check_file "$root" components.tsv || return $?
    vps_offline_read_metadata "$root" || return $?
    [[ -f "${VPSCTL_PROJECT_ROOT}/VERSION" && "$(<"${VPSCTL_PROJECT_ROOT}/VERSION")" == "$VPS_OFFLINE_VERSION" ]] || return 10
    vps_offline_check_platform
}

vps_offline_component() {
    local component="$1" requested="${2:-}" channel="${3:-stable}" actual
    VPS_OFFLINE_COMPONENT_TAG=''; VPS_OFFLINE_COMPONENT_PATH=''
    vps_offline_runtime_root || { vps_offline_error '已导入的离线资源缺失或损坏；拒绝联网回退'; return 10; }
    vps_offline_read_components "$VPS_OFFLINE_ROOT" "$component" "$requested" "$channel" || return $?
    actual="$(vps_offline_sha256 "$VPS_OFFLINE_COMPONENT_PATH")" || return $?
    [[ "$actual" == "$VPS_OFFLINE_COMPONENT_SHA256" ]] || { vps_offline_error "$component 资产摘要不匹配"; return 10; }
}

# Each invocation has private indexes/cache and only a file: source. Do not put
# the durable payload in the machine's disposable /var/cache/apt/archives.
vps_offline_apt() (
    local action="$1" work package status=0
    local -a options=() extra=()
    shift
    case "$action" in install) ;; upgrade) extra+=(--only-upgrade) ;; *) return 2 ;; esac
    (($# > 0)) || return 2
    for package in "$@"; do [[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9+._-]*$ ]] || return 2; done
    vps_offline_runtime_root || return $?
    vps_offline_validate_package "$VPS_OFFLINE_ROOT" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        vps_cmd_info "演练：仅从 $VPS_OFFLINE_ROOT/apt 本地仓库 $action 软件包：$*"
        return 0
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/vpsctl-offline-apt.XXXXXXXX")" || return 20
    trap 'rm -rf -- "$work"' EXIT
    mkdir -p -- "$work/lists/partial" "$work/archives/partial" "$work/sources.list.d" || return 20
    chmod 0755 -- "$work" "$work/lists" "$work/archives" || return 20
    printf 'deb [trusted=yes] file:%s/apt ./\n' "$VPS_OFFLINE_ROOT" >"$work/sources.list"
    options=(-o "Dir::Etc::sourcelist=$work/sources.list" -o "Dir::Etc::sourceparts=$work/sources.list.d"
        -o "Dir::State::lists=$work/lists" -o "Dir::Cache::archives=$work/archives"
        -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache= -o Acquire::Languages=none
        -o APT::Get::List-Cleanup=0)
    vps_cmd_run apt-get "${options[@]}" update || return 20
    vps_cmd_run env DEBIAN_FRONTEND=noninteractive apt-get "${options[@]}" install -y --no-install-recommends "${extra[@]}" "$@" || status=20
    return "$status"
)

# A complete candidate is prepared before changing current, the shortcut or
# self caches. This also hydrates an identical online release of the same version.
vps_offline_import() (
    local source_dir="$1" root version target staging='' work='' lock='' old_current='' old_release=''
    local name archive extract path package_sha old_version='' entry_changed=0 manifest_changed=0 sha_changed=0
    local candidate_moved=0 previous_moved=0 current_changed=0 committed=0 had_entry=0 had_manifest=0 had_sha=0
    local rollback_failed=0 status current_tmp='' previous='' entry state install_root
    vps_offline_validate_package "$source_dir" || return $?
    root="$VPS_OFFLINE_ROOT"; version="$VPS_OFFLINE_VERSION"; package_sha="$VPS_OFFLINE_PACKAGE_SHA256"
    vps_distribution_init_paths
    install_root="$VPSCTL_INSTALL_ROOT"; entry="$VPSCTL_MANAGED_ENTRY"; state="$VPSCTL_SELF_STATE_ROOT"
    if [[ "${VPSCTL_TESTING:-0}" == 1 ]]; then vps_distribution_validate_testing_root || return $?; else
        [[ "${EUID:-$(id -u)}" == 0 ]] || return 4
        [[ "$install_root" == /usr/local/lib/vpsctl && "$entry" == /usr/local/bin/vpsctl && "$state" == /var/lib/vpsctl/self ]] || return 3
    fi
    for path in "$install_root/releases" "${entry%/*}" "$state"; do
        vps_offline_no_links "$path" || return 3
        [[ ! -e "$path" || -d "$path" ]] || return 3
    done
    vps_distribution_validate_self_state_paths || return $?
    mkdir -p -- "$install_root/releases" "${entry%/*}" "$state" || return 20
    chmod 0700 -- "$state" || return 20
    lock="$install_root/.self-update.lock"
    vps_distribution_require_no_symlink_components "$lock/pid" || return 3
    vps_distribution_acquire_lock "$lock" || return $?
    trap 'vps_distribution_release_lock "$lock"' EXIT
    if [[ -e "$install_root/current" || -L "$install_root/current" ]]; then
        [[ -L "$install_root/current" ]] || return 3
        old_current="$(readlink "$install_root/current")" || return 3
        old_release="$(readlink -f -- "$install_root/current")" || return 3
        old_version="${old_release##*/}"
        [[ "$old_release" == "$install_root/releases/$old_version" && "$old_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 3
        vps_distribution_owned_release "$old_release" || return 3
        # Use the executing release's own registry when checking an older core.
        # shellcheck disable=SC2016
        env VPSCTL_PROJECT_ROOT="$old_release" VPSCTL_DISTRIBUTED=1 VPSCTL_INSTALL_ROOT="$install_root" \
            VPSCTL_SELF_STATE_ROOT="$state" VPSCTL_MANAGED_ENTRY="$entry" \
            VPSCTL_TESTING="${VPSCTL_TESTING:-0}" VPSCTL_SYSTEM_ROOT="${VPSCTL_SYSTEM_ROOT:-}" BASH_ENV='' ENV='' \
            bash --noprofile --norc -c 'source "$VPSCTL_PROJECT_ROOT/lib/distribution.sh"; vps_distribution_validate_managed_install' || return $?
    elif [[ -e "$entry" || -L "$entry" ]]; then
        vps_offline_error '入口已存在但无受管 current，拒绝覆盖'; return 3
    fi
    target="$install_root/releases/$version"
    if [[ -e "$target" || -L "$target" ]]; then
        [[ "$target" == "$old_release" && ! -L "$target" &&
            "$(vps_offline_sha256 "$target/.release/manifest.tsv")" == "$(vps_offline_sha256 "$root/vpsctl-manifest.tsv")" ]] || {
            vps_offline_error '目标 release 已存在或同版本 manifest 不一致'; return 3;
        }
    fi
    work="$(mktemp -d "$install_root/.offline-import.XXXXXXXX")" || return 20
    previous="$work/previous-release"
    current_tmp="$install_root/.current.offline.$$.${RANDOM}"
    # Invoked by the EXIT trap, including interrupted imports.
    # shellcheck disable=SC2317
    vps_offline_import_cleanup() {
        status=$?
        trap - EXIT HUP INT TERM
        if ((committed == 0)); then
            if ((candidate_moved)); then rm -rf -- "$target" || rollback_failed=1; fi
            if ((previous_moved)) && [[ -d "$previous" ]]; then mv -- "$previous" "$target" || rollback_failed=1; fi
            if ((current_changed)); then
                if [[ -n "$old_current" ]]; then
                    rm -f -- "$current_tmp"
                    if ! ln -s -- "$old_current" "$current_tmp" || ! mv -Tf -- "$current_tmp" "$install_root/current"; then rollback_failed=1; fi
                else rm -f -- "$install_root/current" || rollback_failed=1; fi
            fi
            if ((entry_changed)); then
                if ((had_entry)); then vps_distribution_atomic_install "$work/old-entry" "$entry" 0755 || rollback_failed=1
                else rm -f -- "$entry" || rollback_failed=1; fi
            fi
            if ((manifest_changed)); then
                if ((had_manifest)); then vps_distribution_atomic_install "$work/old-manifest" "$state/manifest.tsv" 0644 || rollback_failed=1
                else rm -f -- "$state/manifest.tsv" || rollback_failed=1; fi
            fi
            if ((sha_changed)); then
                if ((had_sha)); then vps_distribution_atomic_install "$work/old-sha" "$state/entry.sha256" 0600 || rollback_failed=1
                else rm -f -- "$state/entry.sha256" || rollback_failed=1; fi
            fi
        fi
        [[ -z "$staging" || ! -d "$staging" ]] || rm -rf -- "$staging" || rollback_failed=1
        rm -f -- "$current_tmp" || rollback_failed=1
        if ((rollback_failed)); then
            vps_offline_error "恢复未完成，材料保留于 $work"; status=30
        elif ! rm -rf -- "$work"; then
            vps_offline_error "临时材料清理失败：$work"; status=30
        fi
        vps_distribution_release_lock "$lock"
        exit "$status"
    }
    trap vps_offline_import_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ -f "$entry" && ! -L "$entry" ]]; then cp -p -- "$entry" "$work/old-entry" || return 20; had_entry=1; fi
    if [[ -f "$state/manifest.tsv" ]]; then cp -p -- "$state/manifest.tsv" "$work/old-manifest" || return 20; had_manifest=1; fi
    if [[ -f "$state/entry.sha256" ]]; then cp -p -- "$state/entry.sha256" "$work/old-sha" || return 20; had_sha=1; fi
    staging="$(mktemp -d "$install_root/releases/.offline-${version}.XXXXXXXX")" || return 20
    # The bootstrap has already verified and loaded this target core/registry.
    for name in "${VPS_BUNDLE_IDS[@]}"; do
        archive="${VPS_DISTRIBUTION_BUNDLE_FILE[$name]:-}"
        [[ -n "$archive" ]] || return 10
        vps_distribution_verify_sha256 "$root/$archive" "${VPS_DISTRIBUTION_BUNDLE_SHA256[$name]}" || return $?
        vps_distribution_validate_archive "$root/$archive" "$name" || return $?
        extract="$work/extract"
        mkdir -p -- "$extract" || return 20
        tar --no-same-owner --no-same-permissions -xzf "$root/$archive" -C "$extract" || return 20
        vps_distribution_validate_tree "$extract" && vps_distribution_validate_bundle_tree "$extract" "$name" || return $?
        cp -a -- "$extract/." "$staging/" || return 20
        rm -rf -- "$extract" || return 20
        vps_distribution_atomic_marker "$staging" "$name" "${VPS_DISTRIBUTION_BUNDLE_SHA256[$name]}" || return $?
    done
    [[ "$(<"$staging/VERSION")" == "$version" ]] || return 10
    mkdir -p -- "$staging/.release" "$staging/.offline" || return 20
    install -m 0644 -- "$root/vpsctl-manifest.tsv" "$staging/.release/manifest.tsv" || return 20
    cp -a -- "$root/." "$staging/.offline/" || return 20
    # Catch a source changed while copying, before any managed pointer changes.
    vps_offline_validate_package "$staging/.offline" || return $?
    [[ "$VPS_OFFLINE_PACKAGE_SHA256" == "$package_sha" ]] || { vps_offline_error '导入过程中源包发生变化'; return 10; }
    printf '%s\n' "$VPS_OFFLINE_PACKAGE_SHA256" >"$staging/.release/offline.sha256" || return 20
    printf 'Runarry/vps-script-lite\t%s\n' "$version" >"$staging/.vpsctl-managed-release" || return 20
    find "$staging" -type d -exec chmod 0755 -- {} + && find "$staging" -type f -exec chmod 0644 -- {} + &&
        chmod 0755 -- "$staging/bin/vpsctl" || return 20
    # Record intent before external mutations: a signal can arrive immediately
    # after a successful rename, before the following shell assignment executes.
    if [[ "$target" == "$old_release" ]]; then
        previous_moved=1
        mv -- "$target" "$previous" || return 20
    fi
    candidate_moved=1
    mv -- "$staging" "$target" || return 20
    staging=''
    ln -s -- "$target" "$current_tmp" || return 20
    current_changed=1
    mv -Tf -- "$current_tmp" "$install_root/current" || return 20
    entry_changed=1
    vps_distribution_atomic_install "$target/.offline/vpsctl.sh" "$entry" 0755 || return 20
    manifest_changed=1
    vps_distribution_atomic_install "$target/.release/manifest.tsv" "$state/manifest.tsv" 0644 || return 20
    printf '%s\n' "$VPS_DISTRIBUTION_LAUNCHER_SHA256" >"$work/entry.sha256" || return 20
    sha_changed=1
    vps_distribution_atomic_install "$work/entry.sha256" "$state/entry.sha256" 0600 || return 20
    committed=1
    if [[ -n "$old_version" && "$old_version" != "$version" ]]; then
        vps_distribution_cleanup_old_releases "$target" || return 30
    fi
    printf '已导入离线分发版本 %s（%s %s %s）。\n' "$version" "$VPS_OFFLINE_OS" "$VPS_OFFLINE_OS_VERSION" "$VPS_OFFLINE_ARCH"
)
