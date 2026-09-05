# shellcheck shell=bash
# Runtime bundle loading and self-management for installed releases.

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
    local manifest="$1" line key name filename sha expected_name
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
                ((line_number == 1 && ${#fields[@]} == 2)) && [[ "$line" == $'schema_version\t1' ]] && ((schema_count == 0)) || return 10
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
                ((line_number >= 5 && line_number <= 10 && ${#fields[@]} == 4)) || return 10
                name="${fields[1]}"
                filename="${fields[2]}"
                sha="${fields[3]}"
                case "$line_number" in
                    5) expected_name='core' ;; 6) expected_name='network' ;; 7) expected_name='system' ;;
                    8) expected_name='security' ;; 9) expected_name='service' ;; 10) expected_name='test' ;;
                esac
                [[ "$name" == "$expected_name" && -z "${seen_bundle[$name]+set}" ]] || return 10
                [[ "$line" == $'bundle\t'"${name}"$'\t'"${filename}"$'\t'"${sha}" && "$filename" == "vpsctl-${name}-${VPS_DISTRIBUTION_MANIFEST_VERSION}.tar.gz" && "$sha" =~ ^[0-9a-f]{64}$ ]] || return 10
                seen_bundle[$name]=1
                VPS_DISTRIBUTION_BUNDLE_FILE[$name]="$filename"
                VPS_DISTRIBUTION_BUNDLE_SHA256[$name]="${sha,,}"
                ;;
            *) return 10 ;;
        esac
    done <"$manifest"

    ((line_number == 10 && schema_count == 1 && version_count == 1 && repository_count == 1 && launcher_count == 1)) || {
        vps_distribution_error 'release manifest 缺少必需字段'
        return 10
    }
    for name in core network system security service test; do
        [[ -n "${seen_bundle[$name]+set}" ]] || {
            vps_distribution_error "release manifest 缺少 ${name} bundle"
            return 10
        }
    done
}

vps_distribution_download() {
    local url="$1" destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --tlsv1.2 --output "$destination" "$url" || return 20
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --quiet --output-document="$destination" "$url" || return 20
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
    local domain="$1" entry="${2%/}"
    case "$domain" in
        core)
            case "$entry" in
                VERSION | bin | bin/vpsctl | lib | lib/environment.sh | lib/registry.sh | lib/ui.sh | lib/command.sh | lib/distribution.sh | commands | commands/self | commands/self/*) return 0 ;;
            esac
            ;;
        network | system | security | service)
            [[ "$entry" == commands || "$entry" == "commands/${domain}" || "$entry" == "commands/${domain}/"* ]] && return 0
            ;;
        test)
            [[ "$entry" == commands || "$entry" == commands/test || "$entry" == commands/test/* || "$entry" == lib || "$entry" == lib/server-test.sh ]] && return 0
            ;;
    esac
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

vps_distribution_validate_domain_tree() {
    local tree="$1" domain="$2" required
    local -a required_files=()
    case "$domain" in
        core)
            required_files=(VERSION bin/vpsctl lib/environment.sh lib/registry.sh lib/ui.sh lib/command.sh lib/distribution.sh commands/self/status.sh commands/self/update.sh commands/self/uninstall.sh)
            ;;
        network)
            required_files=(commands/network/bbr.sh commands/network/dns.sh commands/network/ip-policy.sh commands/network/rfw.sh)
            ;;
        system) required_files=(commands/system/kernel.sh commands/system/kernel/providers.sh commands/system/kernel/inventory.sh commands/system/kernel/grub.sh) ;;
        security) required_files=(commands/security/access.sh commands/security/fail2ban.sh commands/security/tls.sh) ;;
        service) required_files=(commands/service/proxy.sh) ;;
        test) required_files=(commands/test/nodequality.sh commands/test/tcpquality.sh lib/server-test.sh) ;;
        *) return 2 ;;
    esac
    for required in "${required_files[@]}"; do
        [[ -f "$tree/$required" && ! -L "$tree/$required" ]] || {
            vps_distribution_error "${domain} 领域包缺少必需文件：$required"
            return 10
        }
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
    vps_distribution_validate_domain_tree "$extract_root" "$domain" || return $?
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

vps_distribution_ensure_domain() {
    local domain="${1:-}" manifest release_root marker expected work_root lock status=0 base_url
    case "$domain" in core | network | system | security | service | test) ;; *) return 2 ;; esac
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
        vps_distribution_validate_domain_tree "$release_root" core
        return $?
    fi
    manifest="$(vps_distribution_current_manifest)"
    vps_distribution_parse_manifest "$manifest" || return $?
    expected="${VPS_DISTRIBUTION_BUNDLE_SHA256[$domain]}"
    marker="${release_root}/.bundles/${domain}.sha256"
    if [[ -f "$marker" && ! -L "$marker" && "$(<"$marker")" == "$expected" ]]; then
        return 0
    fi
    mkdir -p -- "$release_root/.bundles" || return 20
    [[ -d "$release_root/.bundles" && ! -L "$release_root/.bundles" ]] || return 3
    lock="${release_root}/.bundles/.${domain}.lock"
    vps_distribution_acquire_lock "$lock" || return $?
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

vps_distribution_cached_domains() {
    local release_root="${1:-${VPSCTL_PROJECT_ROOT:-}}" marker domain
    printf 'core\n'
    for domain in network system security service test; do
        marker="${release_root}/.bundles/${domain}.sha256"
        [[ -f "$marker" && ! -L "$marker" ]] && printf '%s\n' "$domain"
    done
    return 0
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

vps_distribution_validate_managed_install() {
    local current target resolved manifest launcher_sha release_name target_suffix state_launcher_sha
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
    if [[ -n "$(find "$resolved" -type l -print -quit)" ]]; then
        vps_distribution_error '当前 release 包含异常符号链接'
        return 3
    fi
    manifest="${resolved}/.release/manifest.tsv"
    vps_distribution_parse_manifest "$manifest" || return $?
    release_name="${resolved##*/}"
    [[ "$release_name" == "$VPS_DISTRIBUTION_MANIFEST_VERSION" && -f "$resolved/.vpsctl-managed-release" && ! -L "$resolved/.vpsctl-managed-release" ]] || return 3
    [[ "$(<"$resolved/.vpsctl-managed-release")" == $'Runarry/vps-script-lite\t'"${VPS_DISTRIBUTION_MANIFEST_VERSION}" ]] || return 3
    vps_distribution_validate_domain_tree "$resolved" core || return $?
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
    vps_distribution_require_no_symlink_components "$VPSCTL_SELF_STATE_ROOT" || return 3
    [[ -f "$VPSCTL_SELF_STATE_ROOT/vpsctl.sh" && ! -L "$VPSCTL_SELF_STATE_ROOT/vpsctl.sh" ]] || return 3
    state_launcher_sha="$(vps_distribution_sha256 "$VPSCTL_SELF_STATE_ROOT/vpsctl.sh")" || return $?
    [[ "${state_launcher_sha,,}" == "$VPS_DISTRIBUTION_LAUNCHER_SHA256" ]] || return 3
    [[ -f "$VPSCTL_SELF_STATE_ROOT/manifest.tsv" && ! -L "$VPSCTL_SELF_STATE_ROOT/manifest.tsv" ]] || return 3
    [[ "$(vps_distribution_sha256 "$manifest")" == "$(vps_distribution_sha256 "$VPSCTL_SELF_STATE_ROOT/manifest.tsv")" ]] || return 3
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
        for domain in core network system security service test; do
            marker="${VPSCTL_PROJECT_ROOT}/.bundles/${domain}.sha256"
            [[ -f "$marker" && ! -L "$marker" && "$(<"$marker")" == "${VPS_DISTRIBUTION_BUNDLE_SHA256[$domain]}" ]] || continue
            cached+="${separator}${domain}"
            separator=', '
        done
        printf '缓存领域：%s\n' "${cached:-无}"
    else
        printf '分发版本：未安装\n缓存领域：不适用\n'
    fi
    printf '项目路径：%s\n安装根：%s\nself 状态：%s\n' "$VPSCTL_PROJECT_ROOT" "$VPSCTL_INSTALL_ROOT" "$VPSCTL_SELF_STATE_ROOT"
}

vps_distribution_self_update_locked() {
    local requested="${1:-}" work_root manifest launcher version release_target staging base_url domain status=0 current_tmp old_current
    local entry_tmp state_launcher_tmp state_manifest_tmp state_sha_tmp rollback_ok=0
    local old_state_launcher old_state_manifest old_state_sha
    local -a domains=()
    vps_distribution_validate_managed_install || return $?
    vps_distribution_confirm '确认下载并切换 vpsctl release？' || return $?
    work_root="$(mktemp -d "${VPSCTL_INSTALL_ROOT}/.update.XXXXXX")" || return 20
    old_state_launcher="${work_root}/old-vpsctl.sh"
    old_state_manifest="${work_root}/old-manifest.tsv"
    old_state_sha="${work_root}/old-entry.sha256"
    cp -p -- "$VPSCTL_SELF_STATE_ROOT/vpsctl.sh" "$old_state_launcher" || {
        rm -rf -- "$work_root"
        return 20
    }
    cp -p -- "$VPSCTL_SELF_STATE_ROOT/manifest.tsv" "$old_state_manifest" || {
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
            rm -rf -- "$work_root"
            printf '当前已是分发版本 %s。\n' "$version"
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
    mapfile -t domains < <(vps_distribution_cached_domains "$VPSCTL_PROJECT_ROOT")
    base_url="https://github.com/Runarry/vps-script-lite/releases/download/v${version}"
    for domain in "${domains[@]}"; do
        if vps_distribution_install_bundle "$staging" "$domain" "$base_url" "$work_root"; then :; else
            status=$?
            rm -rf -- "$staging" "$work_root"
            return "$status"
        fi
    done
    [[ -f "$staging/VERSION" && "$(<"$staging/VERSION")" == "$version" && -f "$staging/bin/vpsctl" && -f "$staging/lib/distribution.sh" && -f "$staging/commands/self/status.sh" ]] || {
        vps_distribution_error 'core bundle 不完整'
        rm -rf -- "$staging" "$work_root"
        return 10
    }
    printf 'Runarry/vps-script-lite\t%s\n' "$version" >"$staging/.vpsctl-managed-release" || {
        rm -rf -- "$staging" "$work_root"
        return 20
    }
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
    state_launcher_tmp="${VPSCTL_SELF_STATE_ROOT}/.vpsctl.sh.$$.${RANDOM}"
    state_manifest_tmp="${VPSCTL_SELF_STATE_ROOT}/.manifest.tsv.$$.${RANDOM}"
    state_sha_tmp="${VPSCTL_SELF_STATE_ROOT}/.entry.sha256.$$.${RANDOM}"
    if ! install -m 0755 -- "$launcher" "$entry_tmp" ||
        ! install -m 0755 -- "$launcher" "$state_launcher_tmp" ||
        ! install -m 0644 -- "$manifest" "$state_manifest_tmp" ||
        ! printf '%s\n' "$VPS_DISTRIBUTION_LAUNCHER_SHA256" >"$state_sha_tmp" ||
        ! chmod 0600 "$state_sha_tmp"; then
        rm -f -- "$entry_tmp" "$state_launcher_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        rm -rf -- "$staging" "$work_root"
        return 20
    fi
    mv -- "$staging" "$release_target" || {
        rm -f -- "$entry_tmp" "$state_launcher_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        rm -rf -- "$staging" "$work_root"
        return 20
    }
    current_tmp="${VPSCTL_INSTALL_ROOT}/.current.$$.${RANDOM}"
    old_current="$(readlink "${VPSCTL_INSTALL_ROOT}/current")" || {
        rm -f -- "$entry_tmp" "$state_launcher_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        rm -rf -- "$release_target" "$work_root"
        return 20
    }
    ln -s -- "$release_target" "$current_tmp" || {
        rm -f -- "$entry_tmp" "$state_launcher_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        rm -rf -- "$release_target" "$work_root"
        return 20
    }
    if ! mv -Tf -- "$current_tmp" "${VPSCTL_INSTALL_ROOT}/current"; then
        rm -f -- "$current_tmp"
        rm -f -- "$entry_tmp" "$state_launcher_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        rm -rf -- "$release_target" "$work_root"
        return 20
    fi
    if ! mv -f -- "$entry_tmp" "$VPSCTL_MANAGED_ENTRY" ||
        ! mv -f -- "$state_manifest_tmp" "${VPSCTL_SELF_STATE_ROOT}/manifest.tsv" ||
        ! mv -f -- "$state_launcher_tmp" "${VPSCTL_SELF_STATE_ROOT}/vpsctl.sh" ||
        ! mv -f -- "$state_sha_tmp" "${VPSCTL_SELF_STATE_ROOT}/entry.sha256"; then
        rm -f -- "$current_tmp" "$entry_tmp" "$state_launcher_tmp" "$state_manifest_tmp" "$state_sha_tmp"
        if ln -s -- "$old_current" "$current_tmp" 2>/dev/null && mv -Tf -- "$current_tmp" "${VPSCTL_INSTALL_ROOT}/current" 2>/dev/null; then
            rollback_ok=1
        fi
        if [[ "$rollback_ok" == 1 ]]; then
            vps_distribution_atomic_install "$old_state_launcher" "$VPSCTL_MANAGED_ENTRY" 0755 || rollback_ok=0
            vps_distribution_atomic_install "$old_state_manifest" "$VPSCTL_SELF_STATE_ROOT/manifest.tsv" 0644 || rollback_ok=0
            vps_distribution_atomic_install "$old_state_launcher" "$VPSCTL_SELF_STATE_ROOT/vpsctl.sh" 0755 || rollback_ok=0
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
    printf 'vpsctl 已切换到分发版本 %s；上一 release 已保留。\n' "$version"
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
    local purge="${1:-0}"
    vps_distribution_validate_managed_install || return $?
    vps_distribution_confirm '确认卸载受管 vpsctl？' || return $?
    if [[ "$purge" == 1 ]]; then
        vps_distribution_confirm '确认额外清除 vpsctl self 状态？' || return $?
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

vps_distribution_init_paths
