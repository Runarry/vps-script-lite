# shellcheck shell=bash
# Runtime bundle loading and self-management for installed releases.

# Self commands also load this library directly, without the CLI entry point.
if ! declare -F vps_registry_bundle_files >/dev/null; then
    # shellcheck source=registry.sh disable=SC1091
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/registry.sh"
fi

declare -g VPS_DISTRIBUTION_MANIFEST_VERSION=""
declare -g VPS_DISTRIBUTION_MANIFEST_REPOSITORY=""
declare -g VPS_DISTRIBUTION_LAUNCHER_FILE=""
declare -g VPS_DISTRIBUTION_LAUNCHER_SHA256=""
declare -gA VPS_DISTRIBUTION_BUNDLE_FILE=()
declare -gA VPS_DISTRIBUTION_BUNDLE_SHA256=()

vps_distribution_error() {
    printf 'vpsctl：错误：%s\n' "$1" >&2
}

vps_distribution_system_path() {
    local logical="$1"
    if [[ -n "${VPSCTL_SYSTEM_ROOT:-}" ]]; then
        printf '%s%s' "${VPSCTL_SYSTEM_ROOT%/}" "$logical"
    else
        printf '%s' "$logical"
    fi
}

vps_distribution_init_paths() {
    : "${VPSCTL_DISTRIBUTED:=0}"
    : "${VPSCTL_INSTALL_ROOT:=$(vps_distribution_system_path /usr/local/lib/vpsctl)}"
    : "${VPSCTL_SELF_STATE_ROOT:=$(vps_distribution_system_path /var/lib/vpsctl/self)}"
    : "${VPSCTL_MANAGED_ENTRY:=$(vps_distribution_system_path /usr/local/bin/vpsctl)}"
}

vps_distribution_is_distributed() {
    [[ "${VPSCTL_DISTRIBUTED:-0}" == "1" ]]
}

vps_distribution_safe_absolute_path() {
    local path="${1:-}"
    [[ "$path" == /* && "$path" != "/" && "$path" != *$'\n'* && "$path" != *$'\t'* ]] || return 1
    [[ "/$path/" != *'/../'* && "/$path/" != *'/./'* && "$path" != *'//'* ]]
}

vps_distribution_require_no_symlink_components() {
    local path="$1" current="" component
    local -a components=()

    vps_distribution_safe_absolute_path "$path" || return 1
    IFS='/' read -r -a components <<<"${path#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        current+="/${component}"
        [[ ! -L "$current" ]] || return 1
    done
}

vps_distribution_validate_testing_root() {
    local root="${VPSCTL_SYSTEM_ROOT:-}" resolved
    vps_distribution_safe_absolute_path "$root" || {
        vps_distribution_error '测试模式要求非根目录的绝对 VPSCTL_SYSTEM_ROOT'
        return 3
    }
    [[ -d "$root" && ! -L "$root" ]] || {
        vps_distribution_error '测试模式的 VPSCTL_SYSTEM_ROOT 必须是已存在的普通目录'
        return 3
    }
    vps_distribution_require_no_symlink_components "$root" || {
        vps_distribution_error '测试模式的 VPSCTL_SYSTEM_ROOT 不得包含符号链接组件'
        return 3
    }
    resolved="$(cd -- "$root" && pwd -P)" || return 3
    vps_distribution_safe_absolute_path "$resolved" || return 3
    [[ "$resolved" == "${root%/}" ]] || {
        vps_distribution_error '测试模式的 VPSCTL_SYSTEM_ROOT 必须是规范路径'
        return 3
    }
}

vps_distribution_sha256() {
    local file="$1" digest
    if command -v sha256sum >/dev/null 2>&1; then
        digest="$(sha256sum -- "$file")" || return 20
        printf '%s' "${digest%% *}"
    elif command -v shasum >/dev/null 2>&1; then
        digest="$(shasum -a 256 -- "$file")" || return 20
        printf '%s' "${digest%% *}"
    elif command -v openssl >/dev/null 2>&1; then
        digest="$(openssl dgst -sha256 -r -- "$file")" || return 20
        printf '%s' "${digest%% *}"
    else
        vps_distribution_error '缺少 SHA256 校验工具（sha256sum、shasum 或 openssl）'
        return 3
    fi
}

vps_distribution_verify_sha256() {
    local file="$1" expected="${2,,}" actual
    actual="$(vps_distribution_sha256 "$file")" || return $?
    [[ "${actual,,}" == "$expected" ]] || {
        vps_distribution_error "下载文件 SHA256 不匹配：${file##*/}"
        return 10
    }
}

vps_distribution_parse_manifest() {
    local manifest="$1" line key name filename sha
    local LC_ALL=C
    local schema_count=0 version_count=0 repository_count=0 launcher_count=0 line_number=0
    local -A seen_bundle=()
    local -a fields=()

    [[ -f "$manifest" && -r "$manifest" && ! -L "$manifest" ]] || {
        vps_distribution_error "无法安全读取 release manifest：$manifest"
        return 3
    }
    VPS_DISTRIBUTION_MANIFEST_VERSION=""
    VPS_DISTRIBUTION_MANIFEST_REPOSITORY=""
    VPS_DISTRIBUTION_LAUNCHER_FILE=""
    VPS_DISTRIBUTION_LAUNCHER_SHA256=""
    VPS_DISTRIBUTION_BUNDLE_FILE=()
    VPS_DISTRIBUTION_BUNDLE_SHA256=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        [[ -n "$line" && "$line" != *$'\r'* ]] || {
            vps_distribution_error "manifest 第 ${line_number} 行为空或包含 CR"
            return 10
        }
        fields=()
        IFS=$'\t' read -r -a fields <<<"$line"
        key="${fields[0]:-}"
        case "$key" in
            schema_version)
                if ! ((line_number == 1 && ${#fields[@]} == 2 && schema_count == 0)) || [[ "$line" != $'schema_version\t2' ]]; then
                    vps_distribution_error '不支持的 manifest 格式；旧分发请先普通卸载再重新安装（保留业务数据）'
                    return 10
                fi
                schema_count=1
                ;;
            version)
                ((line_number == 2 && ${#fields[@]} == 2)) && [[ "${fields[1]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$line" == $'version\t'"${fields[1]}" ]] && ((version_count == 0)) || return 10
                VPS_DISTRIBUTION_MANIFEST_VERSION="${fields[1]}"
                version_count=1
                ;;
            repository)
                ((line_number == 3 && ${#fields[@]} == 2)) && [[ "$line" == $'repository\tRunarry/vps-script-lite' ]] && ((repository_count == 0)) || return 10
                VPS_DISTRIBUTION_MANIFEST_REPOSITORY="${fields[1]}"
                repository_count=1
                ;;
            asset)
                ((line_number == 4 && ${#fields[@]} == 4)) && [[ "${fields[1]}" == launcher ]] && ((launcher_count == 0)) || return 10
                filename="${fields[2]}"
                sha="${fields[3]}"
                [[ "$line" == $'asset\tlauncher\tvpsctl.sh\t'"$sha" && "$sha" =~ ^[0-9a-f]{64}$ ]] || return 10
                VPS_DISTRIBUTION_LAUNCHER_FILE="$filename"
                VPS_DISTRIBUTION_LAUNCHER_SHA256="${sha,,}"
                launcher_count=1
                ;;
            bundle)
                ((line_number >= 5 && ${#fields[@]} == 4)) || return 10
                name="${fields[1]}"
                filename="${fields[2]}"
                sha="${fields[3]}"
                [[ "$name" == core || "$name" =~ ^(shared|network|system|security|service|test)-[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]] || return 10
                [[ -z "${seen_bundle[$name]+set}" ]] || return 10
                [[ "$line" == $'bundle\t'"${name}"$'\t'"${filename}"$'\t'"${sha}" && "$filename" == "vpsctl-${name}-${VPS_DISTRIBUTION_MANIFEST_VERSION}.tar.gz" && "$sha" =~ ^[0-9a-f]{64}$ ]] || return 10
                seen_bundle[$name]=1
                VPS_DISTRIBUTION_BUNDLE_FILE[$name]="$filename"
                VPS_DISTRIBUTION_BUNDLE_SHA256[$name]="${sha,,}"
                ;;
            *) return 10 ;;
        esac
    done <"$manifest"

    if ! ((line_number >= 5 && schema_count == 1 && version_count == 1 && repository_count == 1 && launcher_count == 1)) || [[ -z "${seen_bundle[core]+set}" ]]; then
        vps_distribution_error 'release manifest 缺少必需字段'
        return 10
    fi
}

vps_distribution_download() {
    local url="$1" destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --connect-timeout 15 --max-time 300 --retry 2 --retry-max-time 900 \
            --output "$destination" "$url" || return 20
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --quiet --dns-timeout=15 --connect-timeout=15 --read-timeout=60 --tries=3 \
            --output-document="$destination" "$url" || return 20
    else
        vps_distribution_error '下载 release 需要 curl 或 wget'
        return 3
    fi
}

vps_distribution_release_url() {
    local version="$1" filename="$2"
    printf 'https://github.com/Runarry/vps-script-lite/releases/download/v%s/%s' "$version" "$filename"
}

vps_distribution_archive_path_allowed() {
    local bundle="$1" entry="${2%/}" files required
    # Future core releases can introduce internal helpers unknown to the updater.
    [[ "$bundle" == core && "$entry" == lib/* ]] && return 0
    files="$(vps_registry_bundle_files "$bundle")" || return $?
    while IFS= read -r required; do
        [[ "$entry" == "$required" || "$required" == "$entry/"* ]] && return 0
    done <<<"$files"
    return 1
}

vps_distribution_validate_archive() {
    local archive="$1" domain="$2" entry listing type
    local -a entries=()

    command -v tar >/dev/null 2>&1 || {
        vps_distribution_error '安装领域包需要 tar'
        return 3
    }
    listing="$(tar -tzf "$archive")" || {
        vps_distribution_error "无法读取领域包：${archive##*/}"
        return 10
    }
    [[ -n "$listing" ]] || return 10
    mapfile -t entries <<<"$listing"
    for entry in "${entries[@]}"; do
        entry="${entry%/}"
        [[ -n "$entry" && "$entry" != /* && "$entry" != *$'\\'* && "$entry" != *$'\t'* && "$entry" != *$'\n'* ]] || return 10
        [[ "/$entry/" != *'/../'* && "/$entry/" != *'/./'* && "/$entry/" != *'//'* ]] || return 10
        [[ "$entry" != '.release' && "$entry" != .release/* && "$entry" != '.bundles' && "$entry" != .bundles/* ]] || return 10
        vps_distribution_archive_path_allowed "$domain" "$entry" || {
            vps_distribution_error "${domain} 领域包包含越界路径：$entry"
            return 10
        }
    done
    while IFS= read -r type; do
        case "${type:0:1}" in - | d) ;; *)
            vps_distribution_error '领域包不得包含链接或特殊文件'
            return 10
            ;;
        esac
    done < <(tar -tvzf "$archive")
}

vps_distribution_validate_tree() {
    local tree="$1" script special
    [[ -d "$tree" && ! -L "$tree" ]] || return 10
    special="$(find "$tree" \( -type l -o -type p -o -type s \) -print -quit)"
    if [[ -n "$special" ]]; then
        vps_distribution_error '领域包解压结果包含不安全的链接或特殊文件'
        return 10
    fi
    while IFS= read -r -d '' script; do
        BASH_ENV='' ENV='' bash --noprofile --norc -n "$script" || {
            vps_distribution_error "Bash 语法检查失败：${script#"$tree"/}"
            return 10
        }
    done < <(find "$tree" -type f \( -name '*.sh' -o -path '*/bin/vpsctl' \) -print0)
}

vps_distribution_validate_bundle_tree() {
    local tree="$1" bundle="$2" required files
    local -a required_files=()
    files="$(vps_registry_bundle_files "$bundle")" || return $?
    mapfile -t required_files <<<"$files"
    for required in "${required_files[@]}"; do
        if [[ ! -f "$tree/$required" || -L "$tree/$required" ]] || ! vps_distribution_require_no_symlink_components "$tree/$required"; then
            vps_distribution_error "${bundle} bundle 缺少必需文件或路径不安全：$required"
            return 10
        fi
    done
}

vps_distribution_atomic_marker() {
    local release_root="$1" domain="$2" sha="$3" temporary
    mkdir -p -- "$release_root/.bundles" || return 20
    [[ ! -L "$release_root/.bundles" ]] || return 3
    temporary="$(mktemp "${release_root}/.bundles/.${domain}.XXXXXX")" || return 20
    if ! printf '%s\n' "$sha" >"$temporary" || ! chmod 0644 "$temporary" || ! mv -f -- "$temporary" "$release_root/.bundles/${domain}.sha256"; then
        rm -f -- "$temporary"
        return 20
    fi
}

vps_distribution_acquire_lock() {
    local lock="$1" owner pid=""
    owner="${lock}/pid"
    if mkdir -- "$lock" 2>/dev/null; then
        printf '%s\n' "$$" >"$owner" || {
            rmdir -- "$lock" 2>/dev/null || true
            return 20
        }
        return 0
    fi
    if [[ -f "$owner" && ! -L "$owner" ]]; then
        pid="$(<"$owner")"
    fi
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$pid" 2>/dev/null; then
        rm -f -- "$owner"
        if rmdir -- "$lock" 2>/dev/null && mkdir -- "$lock" 2>/dev/null; then
            printf '%s\n' "$$" >"$owner" || {
                rmdir -- "$lock" 2>/dev/null || true
                return 20
            }
            return 0
        fi
    fi
    vps_distribution_error "另一个 vpsctl 进程正在执行受管变更：${lock##*/}"
    return 3
}

vps_distribution_release_lock() {
    local lock="$1"
    rm -f -- "${lock}/pid"
    rmdir -- "$lock" 2>/dev/null || true
}

vps_distribution_install_bundle() {
    local release_root="$1" domain="$2" base_url="$3" work_root="$4"
    local filename sha archive extract_root
    filename="${VPS_DISTRIBUTION_BUNDLE_FILE[$domain]:-}"
    sha="${VPS_DISTRIBUTION_BUNDLE_SHA256[$domain]:-}"
    [[ -n "$filename" && -n "$sha" ]] || return 10
    archive="${work_root}/${filename}"
    extract_root="${work_root}/extract-${domain}"
    mkdir -p -- "$extract_root" || return 20
    vps_distribution_download "${base_url}/${filename}" "$archive" || return $?
    vps_distribution_verify_sha256 "$archive" "$sha" || return $?
    vps_distribution_validate_archive "$archive" "$domain" || return $?
    tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$extract_root" || return 20
    vps_distribution_validate_tree "$extract_root" || return $?
    vps_distribution_validate_bundle_tree "$extract_root" "$domain" || return $?
    if [[ "$domain" == core && "$(<"$extract_root/VERSION")" != "$VPS_DISTRIBUTION_MANIFEST_VERSION" ]]; then
        vps_distribution_error 'core bundle 版本与 manifest 不符'
        return 10
    fi
    [[ -d "$release_root" && ! -L "$release_root" ]] || return 3
    if [[ -n "$(find "$release_root" -type l -print -quit)" ]]; then
        vps_distribution_error "release 含有异常符号链接：$release_root"
        return 3
    fi
    cp -a -- "$extract_root/." "$release_root/" || return 20
    vps_distribution_atomic_marker "$release_root" "$domain" "$sha"
}

vps_distribution_current_manifest() {
    printf '%s/.release/manifest.tsv' "${VPSCTL_PROJECT_ROOT:?}"
}

vps_distribution_ensure_bundle() {
    local domain="${1:-}" manifest release_root marker expected work_root lock status=0 base_url
    vps_registry_bundle_files "$domain" >/dev/null || return 2
    vps_distribution_is_distributed || return 0
    vps_distribution_init_paths
    release_root="${VPSCTL_PROJECT_ROOT:?}"
    vps_distribution_require_no_symlink_components "$release_root" || {
        vps_distribution_error '当前 release 路径包含异常符号链接'
        return 3
    }
    if [[ "$release_root" != "${VPSCTL_INSTALL_ROOT}/releases/"* ]]; then
        vps_distribution_error '当前 release 不属于受管安装根'
        return 3
    fi
    # Core is the code currently executing. It is installed by the bootstrap,
    # never fetched lazily; in particular, self status must remain offline.
    if [[ "$domain" == core ]]; then
        vps_distribution_validate_bundle_tree "$release_root" core
        return $?
    fi
    manifest="$(vps_distribution_current_manifest)"
    vps_distribution_parse_manifest "$manifest" || return $?
    expected="${VPS_DISTRIBUTION_BUNDLE_SHA256[$domain]:-}"
    [[ -n "$expected" && -f "$release_root/VERSION" && "$(<"$release_root/VERSION")" == "$VPS_DISTRIBUTION_MANIFEST_VERSION" ]] || return 10
    marker="${release_root}/.bundles/${domain}.sha256"
    if [[ -f "$marker" && ! -L "$marker" && "$(<"$marker")" == "$expected" ]] && vps_distribution_validate_bundle_tree "$release_root" "$domain" >/dev/null 2>&1; then
        return 0
    fi
    mkdir -p -- "$release_root/.bundles" || return 20
    [[ -d "$release_root/.bundles" && ! -L "$release_root/.bundles" ]] || return 3
    lock="${release_root}/.bundles/.${domain}.lock"
    vps_distribution_acquire_lock "$lock" || return $?
    # A preceding invocation may have populated the cache before lock acquisition.
    if [[ -f "$marker" && ! -L "$marker" && "$(<"$marker")" == "$expected" ]] && vps_distribution_validate_bundle_tree "$release_root" "$domain" >/dev/null 2>&1; then
        vps_distribution_release_lock "$lock"
        return 0
    fi
    # A repair must not retain an old success marker while files are replaced.
    rm -f -- "$marker" || {
        vps_distribution_release_lock "$lock"
        return 20
    }
    work_root="$(mktemp -d "${release_root}/.bundles/.${domain}.work.XXXXXX")" || {
        vps_distribution_release_lock "$lock"
        return 20
    }
    base_url="https://github.com/${VPS_DISTRIBUTION_MANIFEST_REPOSITORY}/releases/download/v${VPS_DISTRIBUTION_MANIFEST_VERSION}"
    vps_distribution_install_bundle "$release_root" "$domain" "$base_url" "$work_root" || status=$?
    rm -rf -- "$work_root"
    vps_distribution_release_lock "$lock"
    return "$status"
}

vps_distribution_ensure_command() {
    local bundles bundle
    vps_distribution_is_distributed || return 0
    bundles="$(vps_registry_command_bundles "$1")" || return $?
    while IFS= read -r bundle; do
        vps_distribution_ensure_bundle "$bundle" || return $?
    done <<<"$bundles"
}

vps_distribution_remove_command_cache() {
    local command_key="${1:-}" validation="${2:-}" domain action bundle files release_root marker lock path parent relative status=0
    local -a bundle_files=() private_dirs=()
    vps_distribution_is_distributed || return 0
    [[ $# == 1 || ($# == 2 && "$validation" == cleanup) ]] || return 2
    # Feature scripts may source distribution.sh without passing through bin/vpsctl.
    ((${#VPS_COMMAND_KEYS[@]} > 0)) || vps_registry_init
    vps_registry_has_command "$command_key" && [[ "$command_key" != self:* ]] || return 2
    domain="${command_key%%:*}"
    action="${command_key#*:}"
    bundle="${domain}-${action}"
    files="$(vps_registry_bundle_files "$bundle")" || return $?
    mapfile -t bundle_files <<<"$files"
    vps_distribution_require_self_mutation || return $?
    vps_distribution_validate_managed_install "$validation" || return $?
    release_root="$VPSCTL_PROJECT_ROOT"
    vps_distribution_require_no_symlink_components "$release_root/.bundles" || return 3
    [[ -d "$release_root/.bundles" && ! -L "$release_root/.bundles" ]] || return 3
    marker="${release_root}/.bundles/${bundle}.sha256"
    lock="${release_root}/.bundles/.${bundle}.lock"
    if [[ "$validation" == cleanup ]]; then
        vps_distribution_require_no_symlink_components "$lock/pid" || return 3
        [[ ! -e "$lock" || -d "$lock" ]] || return 3
        [[ ! -e "$lock/pid" || -f "$lock/pid" ]] || return 3
    fi
    vps_distribution_acquire_lock "$lock" || return $?

    # Check every target before unlinking any file; the registry is the only
    # source of paths, and this operation must never reach shared/core files.
    for relative in "${bundle_files[@]}"; do
        if [[ "$relative" != "commands/${domain}/${action}.sh" && "$relative" != "commands/${domain}/${action}/"* ]]; then
            vps_distribution_error "功能缓存路径超出命令范围：$relative"
            status=3
            break
        fi
        path="${release_root}/${relative}"
        if ! vps_distribution_require_no_symlink_components "$path" || [[ -e "$path" && ! -f "$path" ]]; then
            vps_distribution_error "功能缓存路径不是安全的普通文件：$relative"
            status=3
            break
        fi
        if [[ "$validation" == cleanup && -e "$path" ]] && ! vps_distribution_clean_path_safe "$path"; then
            status=3
            break
        fi
        parent="${path%/*}"
        while [[ "$parent" != "$release_root" ]]; do
            if [[ -e "$parent" && ! -d "$parent" ]]; then
                vps_distribution_error "功能缓存父路径不是目录：$parent"
                status=3
                break
            fi
            parent="${parent%/*}"
        done
        [[ "$status" == 0 ]] || break
    done
    for relative in "${bundle_files[@]}"; do
        parent="${relative%/*}"
        while [[ "$parent" == "commands/${domain}/${action}" || "$parent" == "commands/${domain}/${action}/"* ]]; do
            private_dirs+=("${release_root}/${parent}")
            parent="${parent%/*}"
        done
    done
    if [[ -L "$marker" || (-e "$marker" && ! -f "$marker") ]]; then
        vps_distribution_error "功能缓存标记不是安全的普通文件：$marker"
        status=3
    fi
    if [[ "$validation" == cleanup && -e "$marker" ]] && ! vps_distribution_clean_path_safe "$marker"; then
        status=3
    fi
    if [[ "$status" == 0 ]]; then
        if ! rm -f -- "$marker"; then
            vps_distribution_error "无法清理功能缓存标记：$marker"
            status=20
        else
            for relative in "${bundle_files[@]}"; do
                path="${release_root}/${relative}"
                if ! rm -f -- "$path"; then
                    vps_distribution_error "无法清理功能缓存文件：$relative"
                    status=20
                fi
            done
            if ((${#private_dirs[@]} > 0)); then
                while IFS= read -r path; do
                    [[ -e "$path" || -L "$path" ]] || continue
                    if [[ ! -d "$path" || -L "$path" ]] || ! rmdir -- "$path"; then
                        vps_distribution_error "功能缓存私有目录仍有内容或无法清理：${path#"$release_root"/}"
                        status=20
                    fi
                done < <(printf '%s\n' "${private_dirs[@]}" | sort -ur)
            fi
        fi
    fi
    vps_distribution_release_lock "$lock"
    return "$status"
}

vps_distribution_require_self_mutation() {
    local expected_install expected_state expected_entry testing_sandbox=0
    vps_distribution_is_distributed || {
        vps_distribution_error '源码树模式禁止 self update/uninstall；请操作受管安装'
        return 3
    }
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || {
        vps_distribution_error 'self update/uninstall 不支持 --dry-run'
        return 2
    }
    vps_distribution_init_paths
    if [[ "${VPSCTL_TESTING:-0}" == 1 ]]; then
        vps_distribution_validate_testing_root || return $?
        testing_sandbox=1
    fi
    expected_install="$(vps_distribution_system_path /usr/local/lib/vpsctl)"
    expected_state="$(vps_distribution_system_path /var/lib/vpsctl/self)"
    expected_entry="$(vps_distribution_system_path /usr/local/bin/vpsctl)"
    if [[ "$VPSCTL_INSTALL_ROOT" != "$expected_install" || "$VPSCTL_SELF_STATE_ROOT" != "$expected_state" || "$VPSCTL_MANAGED_ENTRY" != "$expected_entry" ]]; then
        vps_distribution_error '拒绝操作非标准受管安装路径'
        return 3
    fi
    vps_distribution_safe_absolute_path "$VPSCTL_INSTALL_ROOT" && vps_distribution_safe_absolute_path "$VPSCTL_SELF_STATE_ROOT" || return 3
    [[ "${EUID:-$(id -u)}" == 0 || "$testing_sandbox" == 1 ]] || {
        vps_distribution_error 'self 变更操作需要 root 权限'
        return 4
    }
}

vps_distribution_validate_self_state_paths() {
    local path
    vps_distribution_require_no_symlink_components "$VPSCTL_SELF_STATE_ROOT" || return 3
    [[ ! -e "$VPSCTL_SELF_STATE_ROOT" || -d "$VPSCTL_SELF_STATE_ROOT" ]] || {
        vps_distribution_error 'self 状态路径不是目录'
        return 3
    }
    for path in "$VPSCTL_SELF_STATE_ROOT/manifest.tsv" "$VPSCTL_SELF_STATE_ROOT/entry.sha256"; do
        if [[ -L "$path" || (-e "$path" && ! -f "$path") ]]; then
            vps_distribution_error "self 缓存路径不是普通文件：$path"
            return 3
        fi
    done
}

vps_distribution_validate_managed_install() {
    local current target resolved manifest launcher_sha release_name target_suffix
    vps_distribution_require_no_symlink_components "$VPSCTL_INSTALL_ROOT" || {
        vps_distribution_error '安装根路径包含符号链接或不安全组件'
        return 3
    }
    current="${VPSCTL_INSTALL_ROOT}/current"
    [[ -L "$current" ]] || {
        vps_distribution_error '受管 current 必须是符号链接'
        return 3
    }
    target="$(readlink "$current")" || return 3
    if [[ "$target" =~ ^releases/[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
        resolved="$(cd -- "${VPSCTL_INSTALL_ROOT}/${target}" 2>/dev/null && pwd -P)" || return 3
    else
        target_suffix="${target#"${VPSCTL_INSTALL_ROOT}/releases/"}"
        if [[ "$target" != "${VPSCTL_INSTALL_ROOT}/releases/${target_suffix}" || ! "$target_suffix" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
            vps_distribution_error 'current 符号链接目标异常'
            return 3
        fi
        resolved="$(cd -- "$target" 2>/dev/null && pwd -P)" || return 3
    fi
    [[ "$resolved" == "${VPSCTL_INSTALL_ROOT}/releases/"* && ! -L "$resolved" ]] || return 3
    [[ "$(cd -- "${VPSCTL_PROJECT_ROOT:?}" && pwd -P)" == "$resolved" ]] || {
        vps_distribution_error '当前执行代码不属于受管 current release'
        return 3
    }
    # Cleanup validates each candidate separately, so an unrelated damaged cache
    # cannot prevent removal of independent residue. Self operations stay strict.
    if [[ "${1:-}" == cleanup ]]; then
        vps_distribution_require_no_symlink_components "$resolved/.release/manifest.tsv" &&
            vps_distribution_require_no_symlink_components "$resolved/.bundles/core.sha256" || return 3
    elif [[ -n "$(find "$resolved" -type l -print -quit)" ]]; then
        vps_distribution_error '当前 release 包含异常符号链接'
        return 3
    fi
    manifest="${resolved}/.release/manifest.tsv"
    vps_distribution_parse_manifest "$manifest" || return $?
    release_name="${resolved##*/}"
    [[ "$release_name" == "$VPS_DISTRIBUTION_MANIFEST_VERSION" && -f "$resolved/.vpsctl-managed-release" && ! -L "$resolved/.vpsctl-managed-release" ]] || return 3
    [[ "$(<"$resolved/.vpsctl-managed-release")" == $'Runarry/vps-script-lite\t'"${VPS_DISTRIBUTION_MANIFEST_VERSION}" ]] || return 3
    vps_distribution_validate_bundle_tree "$resolved" core || return $?
    [[ -f "$resolved/.bundles/core.sha256" && ! -L "$resolved/.bundles/core.sha256" && "$(<"$resolved/.bundles/core.sha256")" == "${VPS_DISTRIBUTION_BUNDLE_SHA256[core]}" ]] || return 3
    [[ -f "$VPSCTL_MANAGED_ENTRY" && ! -L "$VPSCTL_MANAGED_ENTRY" ]] || {
        vps_distribution_error '受管入口缺失、不是普通文件或是符号链接'
        return 3
    }
    launcher_sha="$(vps_distribution_sha256 "$VPSCTL_MANAGED_ENTRY")" || return $?
    [[ "${launcher_sha,,}" == "$VPS_DISTRIBUTION_LAUNCHER_SHA256" ]] || {
        vps_distribution_error '受管入口与当前 release manifest 不匹配'
        return 3
    }
    # Self metadata is a recoverable cache, not proof of release ownership.
    vps_distribution_validate_self_state_paths
}

vps_distribution_confirm() {
    local prompt="$1" reply
    [[ "${VPSCTL_ASSUME_YES:-0}" == 1 ]] && return 0
    if [[ "${VPSCTL_NON_INTERACTIVE:-0}" == 1 || ! -t 0 || ! -t 1 ]]; then
        vps_distribution_error '非交互 self 变更需要全局 --yes'
        return 3
    fi
    printf '%s [输入 y 确认] ' "$prompt" >&2
    IFS= read -r reply || return 130
    [[ "$reply" == y || "$reply" == Y || "$reply" == yes || "$reply" == YES ]] || return 130
}

vps_distribution_fetch_manifest() {
    local requested_version="$1" destination="$2" url
    if [[ -n "$requested_version" ]]; then
        url="$(vps_distribution_release_url "$requested_version" vpsctl-manifest.tsv)"
    else
        url='https://github.com/Runarry/vps-script-lite/releases/latest/download/vpsctl-manifest.tsv'
    fi
    vps_distribution_download "$url" "$destination" || return $?
    vps_distribution_parse_manifest "$destination" || return $?
    [[ -z "$requested_version" || "$VPS_DISTRIBUTION_MANIFEST_VERSION" == "$requested_version" ]] || {
        vps_distribution_error '下载的 manifest 版本与请求版本不符'
        return 10
    }
}

vps_distribution_atomic_install() {
    local source="$1" destination="$2" mode="$3" temporary
    temporary="${destination}.txn.$$.${RANDOM}"
    [[ ! -e "$temporary" && ! -L "$temporary" ]] || return 20
    if ! install -m "$mode" -- "$source" "$temporary" || ! mv -f -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 20
    fi
}

vps_distribution_self_status() {
    local manifest domain cached="" separator="" marker
    vps_distribution_init_paths
    printf '运行模式：%s\n' "$([[ "$VPSCTL_DISTRIBUTED" == 1 ]] && printf '受管分发' || printf '源码树')"
    manifest="${VPSCTL_PROJECT_ROOT}/.release/manifest.tsv"
    if vps_distribution_is_distributed && vps_distribution_parse_manifest "$manifest" >/dev/null 2>&1; then
        printf '分发版本：%s\n' "$VPS_DISTRIBUTION_MANIFEST_VERSION"
        for domain in "${VPS_BUNDLE_IDS[@]}"; do
            marker="${VPSCTL_PROJECT_ROOT}/.bundles/${domain}.sha256"
            [[ -f "$marker" && ! -L "$marker" && "$(<"$marker")" == "${VPS_DISTRIBUTION_BUNDLE_SHA256[$domain]:-}" ]] || continue
            cached+="${separator}${domain}"
            separator=', '
        done
        printf '缓存功能与共享包：%s\n' "${cached:-无}"
    else
        printf '分发版本：未安装\n缓存功能与共享包：不适用\n'
    fi
    printf '项目路径：%s\n安装根：%s\nself 状态：%s\n' "$VPSCTL_PROJECT_ROOT" "$VPSCTL_INSTALL_ROOT" "$VPSCTL_SELF_STATE_ROOT"
}

vps_distribution_owned_release() {
    local release="$1" version="${1##*/}" record=''
    local marker="$release/.vpsctl-managed-release"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && -d "$release" && ! -L "$release" &&
        -f "$marker" && -r "$marker" && ! -L "$marker" ]] || return 1
    # Read through EOF: extra lines and NUL bytes invalidate the ownership record.
    if IFS= read -r -d '' record <"$marker"; then return 1; fi
    [[ "${record%$'\n'}" == $'Runarry/vps-script-lite\t'"$version" ]]
}

vps_distribution_cleanup_old_releases() {
    local active_release="$1" releases_root="${VPSCTL_INSTALL_ROOT}/releases"
    local release version marker status=0
    version="${active_release##*/}"
    if ! vps_distribution_require_no_symlink_components "$releases_root" ||
        [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || "$active_release" != "$releases_root/$version" ||
            ! -d "$active_release" || -L "$active_release" || ! -L "$VPSCTL_INSTALL_ROOT/current" ]] ||
        [[ "$(readlink "$VPSCTL_INSTALL_ROOT/current")" != "$active_release" ]]; then
        vps_distribution_error '历史 release 清理失败：当前版本或 releases 路径异常'
        return 3
    fi
    for release in "$releases_root"/*; do
        version="${release##*/}"
        [[ "$release" != "$active_release" ]] || continue
        vps_distribution_owned_release "$release" || continue
        marker="$release/.vpsctl-managed-release"
        if ! rm -rf -- "$release"; then
            status=20
            vps_distribution_error "历史 release 清理失败：$release"
            # A partial removal may have deleted the ownership marker first.
            # Restore only that verified marker so a later update can retry.
            if [[ -d "$release" && ! -L "$release" && ! -e "$marker" && ! -L "$marker" ]] &&
                vps_distribution_require_no_symlink_components "$release"; then
                if ! (
                    set -o noclobber
                    printf 'Runarry/vps-script-lite\t%s\n' "$version" >"$marker"
                ); then
                    vps_distribution_error "无法恢复历史 release 标识，请人工检查：$release"
                fi
            fi
        fi
    done
    return "$status"
}

vps_distribution_self_update_locked() {
    local requested="${1:-}" work_root manifest launcher version release_target staging base_url status=0 current_tmp old_current
    local entry_tmp state_manifest_tmp state_sha_tmp rollback_ok=0
    local old_state_launcher old_state_manifest old_state_sha
    vps_distribution_validate_managed_install || return $?
    vps_distribution_confirm '确认下载并切换 vpsctl release，成功后删除受管历史版本？' || return $?
    work_root="$(mktemp -d "${VPSCTL_INSTALL_ROOT}/.update.XXXXXX")" || return 20
    old_state_launcher="${work_root}/old-vpsctl.sh"
    old_state_manifest="${work_root}/old-manifest.tsv"
    old_state_sha="${work_root}/old-entry.sha256"
    cp -p -- "$VPSCTL_MANAGED_ENTRY" "$old_state_launcher" || {
        rm -rf -- "$work_root"
        return 20
    }
    cp -p -- "$(vps_distribution_current_manifest)" "$old_state_manifest" || {
        rm -rf -- "$work_root"
        return 20
    }
    printf '%s\n' "$(vps_distribution_sha256 "$VPSCTL_MANAGED_ENTRY")" >"$old_state_sha" || {
        rm -rf -- "$work_root"
        return 20
    }
    manifest="${work_root}/vpsctl-manifest.tsv"
    if vps_distribution_fetch_manifest "$requested" "$manifest"; then :; else
        status=$?
        rm -rf -- "$work_root"
        return "$status"
    fi
    version="$VPS_DISTRIBUTION_MANIFEST_VERSION"
    release_target="${VPSCTL_INSTALL_ROOT}/releases/${version}"
    if [[ -e "$release_target" || -L "$release_target" ]]; then
        if [[ "$(cd -- "$release_target" 2>/dev/null && pwd -P)" == "$(cd -- "$VPSCTL_PROJECT_ROOT" && pwd -P)" ]]; then
            if ! mkdir -p -- "$VPSCTL_SELF_STATE_ROOT" ||
                ! vps_distribution_atomic_install "$old_state_manifest" "$VPSCTL_SELF_STATE_ROOT/manifest.tsv" 0644 ||
                ! vps_distribution_atomic_install "$old_state_sha" "$VPSCTL_SELF_STATE_ROOT/entry.sha256" 0600; then
                rm -rf -- "$work_root"
                vps_distribution_error 'self 缓存修复未完成；当前入口和 release 未改变，可重试 self update'
                return 20
            fi
            rm -rf -- "$work_root"
            printf '当前已是分发版本 %s；self 缓存已同步。\n' "$version"
            return 0
        fi
        vps_distribution_error "目标 release 已存在，拒绝覆盖：${version}"
        rm -rf -- "$work_root"
        return 3
    fi
    staging="${VPSCTL_INSTALL_ROOT}/releases/.staging-${version}.$$.${RANDOM}"
    mkdir -p -- "$staging/.release" || {
        rm -rf -- "$work_root"
        return 20
    }
    cp -- "$manifest" "$staging/.release/manifest.tsv" || {
        rm -rf -- "$staging" "$work_root"
        return 20
    }
    base_url="https://github.com/Runarry/vps-script-lite/releases/download/v${version}"
    if vps_distribution_install_bundle "$staging" core "$base_url" "$work_root"; then :; else
        status=$?
        rm -rf -- "$staging" "$work_root"
        return "$status"
    fi
    [[ -f "$staging/VERSION" && "$(<"$staging/VERSION")" == "$version" && -f "$staging/bin/vpsctl" && -f "$staging/lib/distribution.sh" && -f "$staging/commands/self/status.sh" ]] || {
        vps_distribution_error 'core bundle 不完整'
        rm -rf -- "$staging" "$work_root"
        return 10
    }
    printf 'Runarry/vps-script-lite\t%s\n' "$version" >"$staging/.vpsctl-managed-release" || {
        rm -rf -- "$staging" "$work_root"
        return 20
    }
    # Archive modes and the caller's umask must not make the next release
    # unreadable or its entry point unexecutable. Finish this before switching.
    if ! find "$staging" -type d -exec chmod 0755 -- {} + ||
        ! find "$staging" -type f -exec chmod 0644 -- {} + ||
        ! chmod 0755 -- "$staging/bin/vpsctl" ||
        [[ ! -x "$staging/bin/vpsctl" ]]; then
        vps_distribution_error '无法设置新 release 的读取和执行权限'
        rm -rf -- "$staging" "$work_root"
        return 20
    fi
    launcher="${work_root}/${VPS_DISTRIBUTION_LAUNCHER_FILE}"
    vps_distribution_download "${base_url}/${VPS_DISTRIBUTION_LAUNCHER_FILE}" "$launcher" || {
        status=$?
        rm -rf -- "$staging" "$work_root"
        return "$status"
    }
    vps_distribution_verify_sha256 "$launcher" "$VPS_DISTRIBUTION_LAUNCHER_SHA256" || {
        status=$?
        rm -rf -- "$staging" "$work_root"
        return "$status"
    }
    BASH_ENV='' ENV='' bash --noprofile --norc -n "$launcher" || {
        rm -rf -- "$staging" "$work_root"
        return 10
    }
    vps_distribution_require_no_symlink_components "$VPSCTL_SELF_STATE_ROOT" || {
        rm -rf -- "$staging" "$work_root"
        return 3
    }
    mkdir -p -- "$VPSCTL_SELF_STATE_ROOT" || {
        rm -rf -- "$staging" "$work_root"
        return 20
    }
    vps_distribution_require_no_symlink_components "${VPSCTL_MANAGED_ENTRY%/*}" || {
        rm -rf -- "$staging" "$work_root"
        return 3
    }
    entry_tmp="${VPSCTL_MANAGED_ENTRY}.tmp.$$.${RANDOM}"
    state_manifest_tmp="${VPSCTL_SELF_STATE_ROOT}/.manifest.tsv.$$.${RANDOM}"
    state_sha_tmp="${VPSCTL_SELF_STATE_ROOT}/.entry.sha256.$$.${RANDOM}"
    if ! install -m 0755 -- "$launcher" "$entry_tmp" ||
        ! install -m 0644 -- "$manifest" "$state_manifest_tmp" ||
        ! printf '%s\n' "$VPS_DISTRIBUTION_LAUNCHER_SHA256" >"$state_sha_tmp" ||
        ! chmod 0600 "$state_sha_tmp"; then
        rm -f -- "$entry_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        rm -rf -- "$staging" "$work_root"
        return 20
    fi
    mv -- "$staging" "$release_target" || {
        rm -f -- "$entry_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        rm -rf -- "$staging" "$work_root"
        return 20
    }
    current_tmp="${VPSCTL_INSTALL_ROOT}/.current.$$.${RANDOM}"
    old_current="$(readlink "${VPSCTL_INSTALL_ROOT}/current")" || {
        rm -f -- "$entry_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        rm -rf -- "$release_target" "$work_root"
        return 20
    }
    ln -s -- "$release_target" "$current_tmp" || {
        rm -f -- "$entry_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        rm -rf -- "$release_target" "$work_root"
        return 20
    }
    if ! mv -Tf -- "$current_tmp" "${VPSCTL_INSTALL_ROOT}/current"; then
        rm -f -- "$current_tmp"
        rm -f -- "$entry_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        rm -rf -- "$release_target" "$work_root"
        return 20
    fi
    if ! mv -f -- "$entry_tmp" "$VPSCTL_MANAGED_ENTRY" ||
        ! mv -f -- "$state_manifest_tmp" "${VPSCTL_SELF_STATE_ROOT}/manifest.tsv" ||
        ! mv -f -- "$state_sha_tmp" "${VPSCTL_SELF_STATE_ROOT}/entry.sha256"; then
        rm -f -- "$current_tmp" "$entry_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        if ln -s -- "$old_current" "$current_tmp" 2>/dev/null && mv -Tf -- "$current_tmp" "${VPSCTL_INSTALL_ROOT}/current" 2>/dev/null; then
            rollback_ok=1
        fi
        if [[ "$rollback_ok" == 1 ]]; then
            vps_distribution_atomic_install "$old_state_launcher" "$VPSCTL_MANAGED_ENTRY" 0755 || rollback_ok=0
            vps_distribution_atomic_install "$old_state_manifest" "$VPSCTL_SELF_STATE_ROOT/manifest.tsv" 0644 || rollback_ok=0
            vps_distribution_atomic_install "$old_state_sha" "$VPSCTL_SELF_STATE_ROOT/entry.sha256" 0600 || rollback_ok=0
        fi
        if [[ "$rollback_ok" == 1 ]] && vps_distribution_validate_managed_install >/dev/null 2>&1; then
            rm -rf -- "$release_target" "$work_root"
            vps_distribution_error '更新入口失败；已完整恢复原 release'
            return 20
        fi
        vps_distribution_error "更新事务回滚不完整；已保留新 release 和恢复材料：$work_root"
        return 30
    fi
    rm -rf -- "$work_root"
    if ! vps_distribution_cleanup_old_releases "$release_target"; then
        vps_distribution_error "分发版本 ${version} 已激活，但历史 release 清理未完成；请检查上述路径，下次成功跨版本更新将重试清理"
        return 30
    fi
    printf 'vpsctl 已切换到分发版本 %s；受管历史 release 已清理。\n' "$version"
}

vps_distribution_self_update() {
    local lock status=0
    vps_distribution_require_self_mutation || return $?
    lock="${VPSCTL_INSTALL_ROOT}/.self-update.lock"
    vps_distribution_acquire_lock "$lock" || return $?
    vps_distribution_self_update_locked "${1:-}" || status=$?
    vps_distribution_release_lock "$lock"
    return "$status"
}

vps_distribution_self_uninstall_locked() {
    local purge="${1:-0}" prompt='确认卸载受管 vpsctl（快捷入口、current 和分发版本目录）'
    vps_distribution_validate_managed_install || return $?
    [[ "$purge" != 1 ]] || prompt+='，并额外清除 vpsctl self 元数据（/var/lib/vpsctl/self/）'
    vps_distribution_confirm "${prompt}？" || return $?
    if [[ "$purge" == 1 ]]; then
        vps_distribution_require_no_symlink_components "$VPSCTL_SELF_STATE_ROOT" || {
            vps_distribution_error 'self 状态路径包含符号链接或不安全组件'
            return 3
        }
    fi
    rm -f -- "$VPSCTL_MANAGED_ENTRY" || return 20
    rm -f -- "${VPSCTL_INSTALL_ROOT}/current" || return 20
    rm -rf -- "${VPSCTL_INSTALL_ROOT}/releases" || return 20
    if [[ "$purge" == 1 && -e "$VPSCTL_SELF_STATE_ROOT" ]]; then
        rm -rf -- "$VPSCTL_SELF_STATE_ROOT" || return 20
    fi
    printf '受管 vpsctl 已卸载。配置、功能状态、备份和 /usr/local/libexec 均已保留。\n'
}

vps_distribution_self_uninstall() {
    local purge="${1:-0}" lock status=0
    vps_distribution_require_self_mutation || return $?
    lock="${VPSCTL_INSTALL_ROOT}/.self-update.lock"
    vps_distribution_acquire_lock "$lock" || return $?
    vps_distribution_self_uninstall_locked "$purge" || status=$?
    vps_distribution_release_lock "$lock"
    return "$status"
}

# Cleanup shares the install layout with self management, but preview is offline
# and unprivileged. Actual cleanup validates current only after taking self's lock.
vps_distribution_clean_require_install() {
    vps_distribution_is_distributed || {
        vps_distribution_error '源码树模式不能清理 vpsctl 受管文件'
        return 3
    }
    vps_distribution_init_paths
    if [[ "${VPSCTL_TESTING:-0}" == 1 ]]; then
        vps_distribution_validate_testing_root || return $?
    fi
    if [[ "$VPSCTL_INSTALL_ROOT" != "$(vps_distribution_system_path /usr/local/lib/vpsctl)" ||
    "$VPSCTL_SELF_STATE_ROOT" != "$(vps_distribution_system_path /var/lib/vpsctl/self)" ||
    "$VPSCTL_MANAGED_ENTRY" != "$(vps_distribution_system_path /usr/local/bin/vpsctl)" ]]; then
        vps_distribution_error '拒绝清理非标准受管安装路径'
        return 3
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 && "${VPSCTL_TESTING:-0}" != 1 && "${EUID:-$(id -u)}" != 0 ]]; then
        vps_distribution_error '清理受管文件需要 root 权限'
        return 4
    fi
    vps_distribution_require_no_symlink_components "$VPSCTL_INSTALL_ROOT" || return 3
}

vps_distribution_clean_path_safe() {
    local path="$1" unsafe mount_point boundary="$VPSCTL_INSTALL_ROOT"
    vps_distribution_require_no_symlink_components "$path" || {
        vps_distribution_error "保留含符号链接的清理路径：$path"
        return 3
    }
    [[ -f "$path" || -d "$path" ]] || {
        vps_distribution_error "保留非普通文件或目录：$path"
        return 3
    }
    # mountinfo includes same-filesystem bind mounts, which -xdev alone misses.
    [[ -r /proc/self/mountinfo ]] || return 3
    [[ "$path" != "$VPSCTL_SELF_STATE_ROOT/"* ]] || boundary="$VPSCTL_SELF_STATE_ROOT"
    while IFS=' ' read -r _ _ _ _ mount_point _; do
        mount_point="$(printf '%b' "$mount_point")"
        if [[ "$mount_point" == "$path" || "$mount_point" == "$path/"* ||
            ("$path" == "$mount_point/"* && ("$mount_point" == "$boundary" || "$mount_point" == "$boundary/"*)) ]]; then
            vps_distribution_error "保留含挂载点的清理路径：$path"
            return 3
        fi
    done </proc/self/mountinfo
    if [[ -d "$path" ]]; then
        unsafe="$(find "$path" -xdev ! -type d ! -type f -print -quit)" || return 20
        [[ -z "$unsafe" ]] || {
            vps_distribution_error "保留含链接或特殊文件的目录：$path"
            return 3
        }
    fi
}

vps_distribution_clean_business_names() {
    case "$1" in
        service:proxy) printf '%s\n' proxy proxy-time ;;
        service:tcping) printf 'tcping\n' ;;
        service:iperf3) printf 'iperf3\n' ;;
        test:*) : ;; # One-shot runners use private temporary trees, no service.
        *) printf '%s\n' "${1/:/-}" ;;
    esac
}

# Each candidate owns these leases in a subshell, independent of the caller's
# command-lock slot. Never force a business lock or disturb the running service.
vps_distribution_clean_unlock() {
    local descriptor lock
    for descriptor in "${clean_fds[@]}"; do
        flock -u "$descriptor" 2>/dev/null || true
        exec {descriptor}>&-
    done
    for lock in "${clean_download_locks[@]}"; do
        vps_distribution_release_lock "$lock"
    done
}

vps_distribution_clean_business_lock() {
    local command_key="$1" directory feature descriptor names
    names="$(vps_distribution_clean_business_names "$command_key")"
    [[ -n "$names" ]] || return 0
    command -v flock >/dev/null 2>&1 || return 3
    directory="$(vps_distribution_system_path /run/vpsctl)"
    vps_distribution_require_no_symlink_components "$directory" || return 3
    mkdir -p -- "$directory" || return 20
    while IFS= read -r feature; do
        vps_distribution_require_no_symlink_components "$directory/$feature.lock" || return 3
        [[ ! -e "$directory/$feature.lock" || -f "$directory/$feature.lock" ]] || return 3
        # system clean already holds its business lock. Borrow that exact open
        # descriptor without adding it to the descriptors this helper releases.
        if [[ "${VPS_CMD_LOCK_PATH:-}" == "$directory/$feature.lock" && "${VPS_CMD_LOCK_FD:-}" =~ ^[0-9]+$ &&
            "$(readlink "/proc/self/fd/$VPS_CMD_LOCK_FD")" == "$directory/$feature.lock" ]]; then
            continue
        fi
        exec {descriptor}>>"$directory/$feature.lock" || return 20
        clean_fds+=("$descriptor")
        if ! flock -n "$descriptor"; then
            vps_distribution_error "保留正在使用的功能缓存：$command_key（$feature 锁被占用）"
            return 3
        fi
    done <<<"$names"
}

vps_distribution_clean_download_lock() {
    local lock="$1"
    vps_distribution_require_no_symlink_components "$lock/pid" || return 3
    [[ ! -e "$lock" || -d "$lock" ]] || return 3
    [[ ! -e "$lock/pid" || -f "$lock/pid" ]] || return 3
    vps_distribution_acquire_lock "$lock" || return $?
    clean_download_locks+=("$lock")
}

vps_distribution_clean_remove_path() (
    local path="$1" bundle="${2:-}" old_release="${3:-0}" before after status=0 key
    local -a clean_fds=() clean_download_locks=()
    vps_distribution_clean_path_safe "$path" || return $?
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        printf '将清理：%s\n' "$path"
        return 0
    fi
    trap vps_distribution_clean_unlock EXIT
    if [[ "$old_release" == 1 ]]; then
        for key in "${VPS_COMMAND_KEYS[@]}"; do
            [[ "$key" != self:* ]] || continue
            if [[ -e "$path/${VPS_COMMAND_PATH[$key]}" || -e "$path/.bundles/${key/:/-}.sha256" ]]; then
                vps_distribution_clean_business_lock "$key" || return $?
            fi
        done
        if [[ -d "$path/.bundles" ]]; then
            for bundle in "${VPS_BUNDLE_IDS[@]}"; do
                vps_distribution_clean_download_lock "$path/.bundles/.$bundle.lock" || return $?
            done
        fi
    elif [[ -n "$bundle" ]]; then
        vps_distribution_clean_download_lock "$VPSCTL_PROJECT_ROOT/.bundles/.$bundle.lock" || return $?
    fi
    # A preceding downloader may have finished while we waited for its lock.
    [[ -e "$path" || -L "$path" ]] || return 0
    vps_distribution_clean_path_safe "$path" || return $?
    before="$(find "$path" -xdev -printf .)" || return 20
    if [[ -d "$path" ]]; then
        rm -rf --one-file-system -- "$path" || status=20
    else
        rm -f -- "$path" || status=20
    fi
    if [[ "$status" != 0 ]]; then
        after=''
        [[ ! -e "$path" ]] || after="$(find "$path" -xdev -printf .)"
        ((${#after} >= ${#before})) || status=30
        vps_distribution_error "清理未完成：$path"
        # Keep failed old releases recognizable for a later retry.
        if [[ "$old_release" == 1 && -d "$path" && ! -L "$path" &&
            ! -e "$path/.vpsctl-managed-release" && ! -L "$path/.vpsctl-managed-release" ]]; then
            (
                set -o noclobber
                printf 'Runarry/vps-script-lite\t%s\n' "${path##*/}" >"$path/.vpsctl-managed-release"
            ) || true
        fi
        return "$status"
    fi
    printf '已清理：%s\n' "$path"
)

vps_distribution_clean_bundle() (
    local key="$1" bundle="${1/:/-}" relative path files private_dir status=0 before='' after=''
    local -a targets=() clean_fds=() clean_download_locks=()
    files="$(vps_registry_bundle_files "$bundle")" || return 3
    targets+=("$VPSCTL_PROJECT_ROOT/.bundles/$bundle.sha256")
    while IFS= read -r relative; do targets+=("$VPSCTL_PROJECT_ROOT/$relative"); done <<<"$files"
    for path in "${targets[@]}"; do
        [[ -e "$path" || -L "$path" ]] || continue
        vps_distribution_clean_path_safe "$path" || return $?
        [[ -f "$path" ]] || return 3
        before+='.'
    done
    private_dir="$VPSCTL_PROJECT_ROOT/commands/${key/:/\/}"
    if [[ "$files" == *"commands/${key/:/\/}/"* && (-e "$private_dir" || -L "$private_dir") ]]; then
        vps_distribution_clean_path_safe "$private_dir" || return $?
        [[ -d "$private_dir" ]] || return 3
        targets+=("$private_dir")
        before+='.'
    fi
    [[ -n "$before" ]] || return 0
    if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
        printf '将清理功能包：%s\n' "$bundle"
        for path in "${targets[@]}"; do [[ ! -e "$path" ]] || printf '  %s\n' "$path"; done
        return 0
    fi
    trap vps_distribution_clean_unlock EXIT
    vps_distribution_clean_business_lock "$key" || return $?
    # The existing eviction helper owns its download lock; never acquire it twice.
    vps_distribution_remove_command_cache "$key" cleanup || status=$?
    if [[ "$status" != 0 ]]; then
        for path in "${targets[@]}"; do [[ ! -e "$path" && ! -L "$path" ]] || after+='.'; done
        ((${#after} >= ${#before})) || status=30
        return "$status"
    fi
    printf '已清理功能包：%s\n' "$bundle"
)

vps_distribution_clean_run() (
    local kind="$1" path name bundle suffix key status=0 result completed=0 issue=0
    local lock="" present
    vps_distribution_clean_require_install || return $?
    ((${#VPS_COMMAND_KEYS[@]} > 0)) || vps_registry_init
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]]; then
        lock="$VPSCTL_INSTALL_ROOT/.self-update.lock"
        vps_distribution_require_no_symlink_components "$lock/pid" || return 3
        [[ ! -e "$lock" || -d "$lock" ]] || return 3
        [[ ! -e "$lock/pid" || -f "$lock/pid" ]] || return 3
        vps_distribution_acquire_lock "$lock" || return $?
        trap 'vps_distribution_release_lock "$lock"' EXIT
    fi
    vps_distribution_validate_managed_install cleanup &&
        vps_distribution_owned_release "$VPSCTL_PROJECT_ROOT" || return 3
    local -a candidates=() bundles=() old_releases=()
    if [[ "$kind" == residue ]]; then
        for path in "$VPSCTL_INSTALL_ROOT/releases/"*; do
            [[ "$path" != "$VPSCTL_PROJECT_ROOT" ]] || continue
            vps_distribution_owned_release "$path" || continue
            candidates+=("$path")
            bundles+=('')
            old_releases+=(1)
        done
        path="$VPSCTL_SELF_STATE_ROOT/vpsctl.sh"
        if [[ -e "$path" || -L "$path" ]]; then
            if [[ -f "$path" && ! -L "$path" ]]; then
                candidates+=("$path")
                bundles+=('')
                old_releases+=(0)
            else
                vps_distribution_error "保留异常 self 旧入口：$path"
                issue=3
            fi
        fi
        for bundle in "${VPS_BUNDLE_IDS[@]}"; do
            for path in "$VPSCTL_PROJECT_ROOT/.bundles/.$bundle."*; do
                [[ -e "$path" || -L "$path" ]] || continue
                name="${path##*/}"
                suffix="${name#".$bundle.work."}"
                if [[ "$suffix" != "$name" && "$suffix" =~ ^[A-Za-z0-9]{6}$ && -d "$path" && ! -L "$path" ]]; then
                    candidates+=("$path")
                    bundles+=("$bundle")
                    old_releases+=(0)
                else
                    suffix="${name#".$bundle."}"
                    if [[ "$suffix" != "$name" && "$suffix" =~ ^[A-Za-z0-9]{6}$ && -f "$path" && ! -L "$path" ]]; then
                        candidates+=("$path")
                        bundles+=("$bundle")
                        old_releases+=(0)
                    fi
                fi
            done
        done
        for ((result = 0; result < ${#candidates[@]}; result++)); do
            status=0
            vps_distribution_clean_remove_path "${candidates[$result]}" "${bundles[$result]}" "${old_releases[$result]}" || status=$?
            case "$status" in
                0) completed=$((completed + 1)) ;;
                30)
                    completed=$((completed + 1))
                    issue=20
                    ;;
                20) issue=20 ;;
                *) [[ "$issue" == 20 ]] || issue=3 ;;
            esac
        done
    else
        for key in "${VPS_COMMAND_KEYS[@]}"; do
            [[ "$key" != self:* && "$key" != system:clean ]] || continue
            bundle="${key/:/-}"
            present=0
            if [[ -e "$VPSCTL_PROJECT_ROOT/.bundles/$bundle.sha256" || -L "$VPSCTL_PROJECT_ROOT/.bundles/$bundle.sha256" ]]; then present=1; fi
            while IFS= read -r path; do
                [[ ! -e "$VPSCTL_PROJECT_ROOT/$path" && ! -L "$VPSCTL_PROJECT_ROOT/$path" ]] || present=1
                if [[ "$path" == "commands/${key/:/\/}/"* &&
                    (-e "$VPSCTL_PROJECT_ROOT/commands/${key/:/\/}" || -L "$VPSCTL_PROJECT_ROOT/commands/${key/:/\/}") ]]; then present=1; fi
            done < <(vps_registry_bundle_files "$bundle")
            [[ "$present" == 1 ]] || continue
            status=0
            vps_distribution_clean_bundle "$key" || status=$?
            case "$status" in
                0) completed=$((completed + 1)) ;;
                30)
                    completed=$((completed + 1))
                    issue=20
                    ;;
                20) issue=20 ;;
                *) [[ "$issue" == 20 ]] || issue=3 ;;
            esac
        done
    fi
    if [[ "$issue" != 0 ]]; then
        ((completed == 0)) || return 30
        return "$issue"
    fi
    ((completed > 0)) || printf '没有可清理的 vpsctl %s。\n' "$([[ "$kind" == residue ]] && printf '残留' || printf '功能包缓存')"
)

vps_distribution_clean_residue() {
    (($# == 0)) || return 2
    vps_distribution_clean_run residue
}

vps_distribution_clean_bundles() {
    (($# == 0)) || return 2
    vps_distribution_clean_run bundles
}

vps_distribution_init_paths
