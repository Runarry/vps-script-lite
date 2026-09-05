#!/usr/bin/env bash
# Build a package-proven inventory of locally installed kernel releases.
# This file is sourced by commands/system/kernel.sh.

# shellcheck disable=SC2034

declare -ag KERNEL_RELEASES=()
declare -ag KERNEL_PURGE_PACKAGES=()
declare -ag KERNEL_PURGE_METAPACKAGES=()
declare -ag KERNEL_META_RELEASES=()
declare -Ag KERNEL_RELEASE_PACKAGES=()
declare -Ag KERNEL_RELEASE_SOURCE=()
declare -Ag KERNEL_RELEASE_SERIES=()
declare -Ag KERNEL_RELEASE_COMPLETE=()
declare -Ag KERNEL_RELEASE_MANAGED=()
declare -Ag KERNEL_RELEASE_REASON=()
declare -Ag KERNEL_PKG_STATUS=()
declare -Ag KERNEL_PKG_VERSION=()
declare -Ag KERNEL_PKG_DEPENDS=()
declare -Ag KERNEL_PKG_RELEASE=()
declare -Ag KERNEL_PKG_SERIES=()
declare -Ag KERNEL_PKG_IS_META=()

_kernel_inventory_error() {
    if declare -F vps_cmd_error >/dev/null 2>&1; then
        vps_cmd_error "$1"
    else
        printf 'ERROR: %s\n' "$1" >&2
    fi
}

kernel_release_valid() {
    local release="${1:-}"
    [[ -n "$release" && ${#release} -le 200 ]] || return 1
    [[ "$release" != */* && "$release" != *\\* ]] || return 1
    [[ "$release" != *[[:space:]]* && "$release" != *[[:cntrl:]]* ]] || return 1
    [[ "$release" =~ ^[0-9]+\.[0-9]+[A-Za-z0-9.+_~-]*$ ]]
}

_kernel_inventory_package_valid() {
    [[ "${1:-}" =~ ^[a-z0-9][a-z0-9+.-]*(:[a-z0-9][a-z0-9-]*)?$ ]]
}

_kernel_inventory_status_installed() {
    case "${1:-}" in 'ii ' | 'hi ') return 0 ;; *) return 1 ;; esac
}

_kernel_inventory_status_residual() {
    [[ "${1:-}" == 'rc ' ]]
}

kernel_inventory_package_installed() {
    local package="${1:-}"
    _kernel_inventory_package_valid "$package" || return 1
    _kernel_inventory_status_installed "${KERNEL_PKG_STATUS[$package]:-}"
}

_kernel_inventory_resolve_package() {
    local wanted="${1:-}" package match=''
    [[ -n "$wanted" ]] || return 1
    if [[ -v "KERNEL_PKG_STATUS[$wanted]" ]]; then
        printf '%s\n' "$wanted"
        return 0
    fi
    for package in "${!KERNEL_PKG_STATUS[@]}"; do
        [[ "${package%%:*}" == "$wanted" ]] || continue
        [[ -z "$match" ]] || return 2
        match="$package"
    done
    [[ -n "$match" ]] || return 1
    printf '%s\n' "$match"
}

_kernel_inventory_meta_series() {
    local package="${1%%:*}"
    case "$package" in
        linux-xanmod-lts-x64v[123]) printf 'xanmod:lts\n' ;;
        linux-xanmod-x64v[123]) printf 'xanmod:main\n' ;;
        linux-amd64 | linux-image-amd64 | linux-headers-amd64) printf 'debian:official\n' ;;
        linux-cloud-amd64 | linux-image-cloud-amd64 | linux-headers-cloud-amd64) printf 'debian:cloud\n' ;;
        linux-generic | linux-image-generic | linux-headers-generic | linux-virtual | linux-image-virtual | linux-headers-virtual) printf 'ubuntu:official\n' ;;
        *)
            if [[ "$package" =~ ^linux-(generic|image-generic|headers-generic|virtual|image-virtual|headers-virtual)-hwe-[0-9]{2}\.[0-9]{2}$ ]]; then
                printf 'ubuntu:hwe\n'
            else
                return 1
            fi
            ;;
    esac
}

_kernel_inventory_kernelish_package() {
    local package="${1%%:*}"
    [[ "$package" == linux-image-* || "$package" == linux-modules-* ||
        "$package" == linux-headers-* || "$package" == linux-xanmod-* ||
        "$package" == linux-generic* || "$package" == linux-virtual* ||
        "$package" == linux-amd64 || "$package" == linux-cloud-amd64 ]]
}

_kernel_inventory_append_unique() {
    local array_name="$1" value="$2" existing
    local -n target_array="$array_name"
    for existing in "${target_array[@]}"; do
        [[ "$existing" == "$value" ]] && return 0
    done
    target_array+=("$value")
}

_kernel_inventory_dependency_names() {
    local depends="${1:-}" group alternative name
    local old_ifs="$IFS"
    local -a groups=() alternatives=()
    IFS=',' read -r -a groups <<<"$depends"
    IFS="$old_ifs"
    for group in "${groups[@]}"; do
        IFS='|' read -r -a alternatives <<<"$group"
        IFS="$old_ifs"
        for alternative in "${alternatives[@]}"; do
            name="${alternative%%(*}"
            name="${name%%[*}"
            name="${name%%<*}"
            name="${name#"${name%%[![:space:]]*}"}"
            name="${name%"${name##*[![:space:]]}"}"
            name="${name%:any}"
            name="${name%:native}"
            _kernel_inventory_package_valid "$name" && printf '%s\n' "$name"
        done
    done
}

_kernel_inventory_release_package_match() {
    local package="${1%%:*}" release="$2"
    case "$package" in
        "linux-image-${release}" | "linux-image-unsigned-${release}" | "linux-modules-${release}" | "linux-modules-extra-${release}" | "linux-headers-${release}") return 0 ;;
        *) return 1 ;;
    esac
}

_kernel_inventory_image_package_match() {
    local package="${1%%:*}" release="$2"
    case "$package" in
        "linux-image-${release}" | "linux-image-unsigned-${release}") return 0 ;;
        *) return 1 ;;
    esac
}

_kernel_inventory_shared_package() {
    local package="${1%%:*}"
    case "$package" in
        *headers-common* | *tools-common* | linux-base | linux-firmware | firmware-* | *-firmware) return 0 ;;
        *) return 1 ;;
    esac
}

_kernel_inventory_path_has_entries() {
    local directory="$1" entry
    [[ -d "$directory" ]] || return 1
    shopt -s nullglob dotglob
    for entry in "$directory"/*; do
        shopt -u nullglob dotglob
        return 0
    done
    shopt -u nullglob dotglob
    return 1
}

_kernel_inventory_image_owner() {
    local image="$1" output line owner path resolved
    local -a owners=()
    [[ -f "$image" && ! -L "$image" ]] || return 1
    output="$(LC_ALL=C dpkg-query -S -- "$image" 2>/dev/null)" || return 1
    while IFS= read -r line; do
        [[ "$line" == *': '* ]] || continue
        owner="${line%%: *}"
        path="${line#*: }"
        [[ "$path" == "$image" ]] || continue
        _kernel_inventory_package_valid "$owner" || continue
        resolved="$(_kernel_inventory_resolve_package "$owner" 2>/dev/null)" || continue
        _kernel_inventory_append_unique owners "$resolved"
    done <<<"$output"
    ((${#owners[@]} == 1)) || return 1
    printf '%s\n' "${owners[0]}"
}

_kernel_inventory_release_source() {
    local package="${1%%:*}" release="$2"
    if [[ "$package" == *xanmod* || "$release" == *xanmod* ]]; then
        printf 'XanMod\n'
        return 0
    fi
    case "${KERNEL_OS_ID:-unknown}:$package" in
        debian:linux-image-*)
            [[ "$release" == *cloud* ]] && printf 'Debian 云\n' || printf 'Debian 官方\n'
            ;;
        ubuntu:linux-image-*) printf 'Ubuntu\n' ;;
        *)
            printf '手工/未知\n'
            return 1
            ;;
    esac
}

_kernel_inventory_initial_series() {
    local source="$1" release="$2"
    case "$source" in
        'Debian 云') printf 'debian:cloud\n' ;;
        'Debian 官方') printf 'debian:official\n' ;;
        XanMod | Ubuntu) printf 'unknown\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

_kernel_inventory_add_release() {
    local release="$1" existing
    kernel_release_valid "$release" || return 0
    for existing in "${KERNEL_RELEASES[@]}"; do
        [[ "$existing" == "$release" ]] && return 0
    done
    KERNEL_RELEASES+=("$release")
}

_kernel_inventory_meta_walk() {
    local package="$1" visiting_name="$2" visited_name="$3" releases_name="$4"
    local dependency resolved release
    local -n visiting_ref="$visiting_name" visited_ref="$visited_name"
    [[ -z "${visiting_ref[$package]:-}" ]] || return 30
    [[ -z "${visited_ref[$package]:-}" ]] || return 0
    visiting_ref["$package"]=1
    visited_ref["$package"]=1
    release="${KERNEL_PKG_RELEASE[$package]:-}"
    [[ -z "$release" ]] || _kernel_inventory_append_unique "$releases_name" "$release"
    while IFS= read -r dependency; do
        resolved="$(_kernel_inventory_resolve_package "$dependency" 2>/dev/null)" || continue
        kernel_inventory_package_installed "$resolved" || continue
        _kernel_inventory_kernelish_package "$resolved" || continue
        _kernel_inventory_meta_walk "$resolved" "$visiting_name" "$visited_name" "$releases_name" || return $?
    done < <(_kernel_inventory_dependency_names "${KERNEL_PKG_DEPENDS[$package]:-}")
    unset 'visiting_ref[$package]'
}

kernel_inventory_meta_releases() {
    local requested="${1:-}" package meta_series status=0
    local -A visiting=() visited=()
    KERNEL_META_RELEASES=()
    package="$(_kernel_inventory_resolve_package "$requested" 2>/dev/null)" || {
        _kernel_inventory_error "找不到已记录的软件包：${requested:-<空>}"
        return 3
    }
    kernel_inventory_package_installed "$package" || {
        _kernel_inventory_error "元包 $package 未处于完整安装状态"
        return 3
    }
    meta_series="$(_kernel_inventory_meta_series "$package" 2>/dev/null)" || {
        _kernel_inventory_error "$package 不在允许解析的内核元包白名单中"
        return 3
    }
    _kernel_inventory_meta_walk "$package" visiting visited KERNEL_META_RELEASES || status=$?
    ((status == 0)) || {
        _kernel_inventory_error "元包 $package 的依赖关系包含循环，无法证明目标内核"
        KERNEL_META_RELEASES=()
        return 30
    }
    ((${#KERNEL_META_RELEASES[@]} == 1)) || {
        _kernel_inventory_error "元包 $package 无法唯一绑定一个 concrete kernel release"
        KERNEL_META_RELEASES=()
        return 30
    }
}

kernel_inventory_load() {
    local output query_status status package version depends release path image initrd modules owner source series meta meta_series mapped
    local old_ifs="$IFS"
    local -a paths=() release_packages=() inferred_series=() owner_releases=()
    local -A image_owner_releases=()

    KERNEL_RELEASES=()
    KERNEL_PURGE_PACKAGES=()
    KERNEL_PURGE_METAPACKAGES=()
    KERNEL_META_RELEASES=()
    KERNEL_RELEASE_PACKAGES=()
    KERNEL_RELEASE_SOURCE=()
    KERNEL_RELEASE_SERIES=()
    KERNEL_RELEASE_COMPLETE=()
    KERNEL_RELEASE_MANAGED=()
    KERNEL_RELEASE_REASON=()
    KERNEL_PKG_STATUS=()
    KERNEL_PKG_VERSION=()
    KERNEL_PKG_DEPENDS=()
    KERNEL_PKG_RELEASE=()
    KERNEL_PKG_SERIES=()
    KERNEL_PKG_IS_META=()

    [[ -n "${KERNEL_BOOT_DIR:-}" && -n "${KERNEL_MODULES_DIR:-}" ]] || {
        _kernel_inventory_error '内核清单路径尚未初始化'
        return 2
    }
    if output="$(LC_ALL=C dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${Depends}\n' 2>&1)"; then
        :
    else
        query_status=$?
        _kernel_inventory_error "dpkg 数据库查询失败（退出码 $query_status）：$output"
        return 20
    fi
    while IFS=$'\t' read -r status package version depends; do
        [[ -n "$package" ]] || continue
        _kernel_inventory_package_valid "$package" || {
            _kernel_inventory_error "dpkg 返回了不安全的软件包名：$package"
            return 30
        }
        KERNEL_PKG_STATUS[$package]="$status"
        KERNEL_PKG_VERSION[$package]="$version"
        KERNEL_PKG_DEPENDS[$package]="$depends"
        KERNEL_PKG_RELEASE[$package]=''
        KERNEL_PKG_SERIES[$package]='unknown'
        KERNEL_PKG_IS_META[$package]=0
        if meta_series="$(_kernel_inventory_meta_series "$package" 2>/dev/null)"; then
            KERNEL_PKG_IS_META[$package]=1
            KERNEL_PKG_SERIES[$package]="$meta_series"
        fi
        if { _kernel_inventory_kernelish_package "$package" || [[ "${KERNEL_PKG_IS_META[$package]}" == 1 ]]; } &&
            ! _kernel_inventory_status_installed "$status" &&
            ! _kernel_inventory_status_residual "$status" &&
            [[ "$status" != 'un ' && "$status" != 'pn ' ]]; then
            _kernel_inventory_error "内核软件包 $package 处于未完成的 dpkg 状态 '$status'；请先修复 dpkg"
            return 30
        fi
    done <<<"$output"

    shopt -s nullglob
    paths=("$KERNEL_BOOT_DIR"/vmlinuz-* "$KERNEL_BOOT_DIR"/initrd.img-* "$KERNEL_MODULES_DIR"/*)
    shopt -u nullglob
    for path in "${paths[@]}"; do
        case "$path" in
            "$KERNEL_BOOT_DIR"/vmlinuz-*) release="${path##*/vmlinuz-}" ;;
            "$KERNEL_BOOT_DIR"/initrd.img-*) release="${path##*/initrd.img-}" ;;
            "$KERNEL_MODULES_DIR"/*) release="${path##*/}" ;;
            *) continue ;;
        esac
        _kernel_inventory_add_release "$release"
    done
    if ((${#KERNEL_RELEASES[@]} > 0)); then
        mapfile -t KERNEL_RELEASES < <(printf '%s\n' "${KERNEL_RELEASES[@]}" | LC_ALL=C sort -V -u)
    fi

    for release in "${KERNEL_RELEASES[@]}"; do
        image="$KERNEL_BOOT_DIR/vmlinuz-$release"
        initrd="$KERNEL_BOOT_DIR/initrd.img-$release"
        modules="$KERNEL_MODULES_DIR/$release"
        KERNEL_RELEASE_COMPLETE[$release]=0
        if [[ -s "$image" && ! -L "$image" && -s "$initrd" ]] && _kernel_inventory_path_has_entries "$modules"; then
            KERNEL_RELEASE_COMPLETE[$release]=1
        fi
        KERNEL_RELEASE_MANAGED[$release]=0
        KERNEL_RELEASE_SOURCE[$release]='手工/未知'
        KERNEL_RELEASE_SERIES[$release]='unknown'
        KERNEL_RELEASE_REASON[$release]='内核镜像没有可证明的 dpkg 软件包归属'
        KERNEL_RELEASE_PACKAGES[$release]=''
        owner=''
        [[ -s "$image" && ! -L "$image" ]] && owner="$(_kernel_inventory_image_owner "$image" 2>/dev/null || true)"
        [[ -n "$owner" ]] || continue
        if [[ -n "${image_owner_releases[$owner]:-}" ]]; then
            image_owner_releases[$owner]+=$'\n'
        fi
        image_owner_releases[$owner]+="$release"
        if ! _kernel_inventory_image_package_match "$owner" "$release"; then
            KERNEL_RELEASE_PACKAGES[$release]="$owner"
            KERNEL_RELEASE_REASON[$release]="镜像归属包 $owner 与 release $release 不精确对应"
            continue
        fi
        source="$(_kernel_inventory_release_source "$owner" "$release" 2>/dev/null || true)"
        [[ -n "$source" ]] || source='手工/未知'
        KERNEL_RELEASE_SOURCE[$release]="$source"
        series="$(_kernel_inventory_initial_series "$source" "$release")"
        KERNEL_RELEASE_SERIES[$release]="$series"
        release_packages=()
        _kernel_inventory_append_unique release_packages "$owner"
        for package in "${!KERNEL_PKG_STATUS[@]}"; do
            _kernel_inventory_release_package_match "$package" "$release" || continue
            _kernel_inventory_shared_package "$package" && continue
            _kernel_inventory_append_unique release_packages "$package"
        done
        for package in "${release_packages[@]}"; do
            KERNEL_PKG_RELEASE[$package]="$release"
            [[ "$series" == unknown ]] || KERNEL_PKG_SERIES[$package]="$series"
        done
        KERNEL_RELEASE_PACKAGES[$release]="$(printf '%s\n' "${release_packages[@]}")"
        KERNEL_RELEASE_PACKAGES[$release]="${KERNEL_RELEASE_PACKAGES[$release]%$'\n'}"
        if [[ "$source" == '手工/未知' ]]; then
            KERNEL_RELEASE_REASON[$release]='镜像虽由软件包提供，但来源系列不在允许范围内'
        elif ! kernel_inventory_package_installed "$owner"; then
            KERNEL_RELEASE_REASON[$release]="镜像软件包 $owner 未处于完整安装状态"
        else
            KERNEL_RELEASE_MANAGED[$release]=1
            KERNEL_RELEASE_REASON[$release]=''
        fi
    done

    # Infer ambiguous tracks from installed, fixed-whitelist meta packages only.
    for meta in "${!KERNEL_PKG_IS_META[@]}"; do
        [[ "${KERNEL_PKG_IS_META[$meta]}" == 1 ]] || continue
        kernel_inventory_package_installed "$meta" || continue
        kernel_inventory_meta_releases "$meta" >/dev/null 2>&1 || continue
        mapped="${KERNEL_META_RELEASES[0]}"
        meta_series="${KERNEL_PKG_SERIES[$meta]}"
        [[ -n "$mapped" && -v "KERNEL_RELEASE_SERIES[$mapped]" ]] || continue
        KERNEL_PKG_RELEASE[$meta]="$mapped"
        inferred_series=()
        [[ "${KERNEL_RELEASE_SERIES[$mapped]}" == unknown ]] || inferred_series+=("${KERNEL_RELEASE_SERIES[$mapped]}")
        if [[ -n "${KERNEL_RELEASE_REASON[$mapped]:-}" && "${KERNEL_RELEASE_REASON[$mapped]}" == series:* ]]; then
            IFS=',' read -r -a inferred_series <<<"${KERNEL_RELEASE_REASON[$mapped]#series:}"
            IFS="$old_ifs"
        fi
        _kernel_inventory_append_unique inferred_series "$meta_series"
        if ((${#inferred_series[@]} == 1)); then
            KERNEL_RELEASE_SERIES[$mapped]="$meta_series"
            for package in ${KERNEL_RELEASE_PACKAGES[$mapped]}; do KERNEL_PKG_SERIES[$package]="$meta_series"; done
        else
            KERNEL_RELEASE_SERIES[$mapped]='unknown'
            for package in ${KERNEL_RELEASE_PACKAGES[$mapped]}; do KERNEL_PKG_SERIES[$package]='unknown'; done
            KERNEL_RELEASE_REASON[$mapped]="series:$(
                IFS=,
                printf '%s' "${inferred_series[*]}"
            )"
        fi
    done
    for release in "${KERNEL_RELEASES[@]}"; do
        if [[ "${KERNEL_RELEASE_REASON[$release]:-}" == series:* ]]; then
            KERNEL_RELEASE_REASON[$release]="多个内核系列元包同时绑定此 release：${KERNEL_RELEASE_REASON[$release]#series:}"
        fi
    done
    for owner in "${!image_owner_releases[@]}"; do
        owner_releases=()
        mapfile -t owner_releases <<<"${image_owner_releases[$owner]}"
        ((${#owner_releases[@]} > 1)) || continue
        for release in "${owner_releases[@]}"; do
            KERNEL_RELEASE_MANAGED[$release]=0
            KERNEL_RELEASE_REASON[$release]="镜像包 $owner 同时拥有多个 release，卸载范围无法隔离"
        done
        KERNEL_PKG_RELEASE[$owner]=''
    done
}

_kernel_inventory_package_in_purge_set() {
    local wanted="$1" package
    for package in "${KERNEL_PURGE_PACKAGES[@]}"; do
        [[ "$package" == "$wanted" ]] && return 0
    done
    return 1
}

_kernel_inventory_meta_must_remove() {
    local package="$1" group alternative name resolved
    local depends="${KERNEL_PKG_DEPENDS[$package]:-}"
    local old_ifs="$IFS" any all
    local -a groups=() alternatives=()
    IFS=',' read -r -a groups <<<"$depends"
    IFS="$old_ifs"
    for group in "${groups[@]}"; do
        any=0
        all=1
        IFS='|' read -r -a alternatives <<<"$group"
        IFS="$old_ifs"
        for alternative in "${alternatives[@]}"; do
            name="${alternative%%(*}"
            name="${name%%[*}"
            name="${name%%<*}"
            name="${name#"${name%%[![:space:]]*}"}"
            name="${name%"${name##*[![:space:]]}"}"
            name="${name%:any}"
            name="${name%:native}"
            resolved="$(_kernel_inventory_resolve_package "$name" 2>/dev/null || true)"
            if [[ -n "$resolved" ]] && _kernel_inventory_package_in_purge_set "$resolved"; then
                any=1
            else
                all=0
            fi
        done
        ((any == 1 && all == 1)) && return 0
    done
    return 1
}

kernel_build_purge_packages() {
    local release="${1:-}" package status series meta_series changed
    KERNEL_PURGE_PACKAGES=()
    KERNEL_PURGE_METAPACKAGES=()
    kernel_release_valid "$release" || {
        _kernel_inventory_error "无效的内核 release：${release:-<空>}"
        return 2
    }
    [[ -v "KERNEL_RELEASE_MANAGED[$release]" ]] || {
        _kernel_inventory_error "内核 release 不在当前清单中：$release"
        return 3
    }
    [[ "${KERNEL_RELEASE_MANAGED[$release]}" == 1 ]] || {
        _kernel_inventory_error "内核 $release 不可自动卸载：${KERNEL_RELEASE_REASON[$release]}"
        return 3
    }
    series="${KERNEL_RELEASE_SERIES[$release]}"
    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        _kernel_inventory_shared_package "$package" && continue
        status="${KERNEL_PKG_STATUS[$package]:-}"
        _kernel_inventory_status_installed "$status" || _kernel_inventory_status_residual "$status" || continue
        _kernel_inventory_release_package_match "$package" "$release" || {
            [[ "$package" == "${KERNEL_RELEASE_PACKAGES[$release]%%$'\n'*}" ]] || continue
        }
        _kernel_inventory_append_unique KERNEL_PURGE_PACKAGES "$package"
    done <<<"${KERNEL_RELEASE_PACKAGES[$release]}"
    ((${#KERNEL_PURGE_PACKAGES[@]} > 0)) || {
        _kernel_inventory_error "没有可证明属于 $release 的精确软件包"
        return 30
    }

    changed=1
    while ((changed == 1)); do
        changed=0
        for package in "${!KERNEL_PKG_IS_META[@]}"; do
            [[ "${KERNEL_PKG_IS_META[$package]}" == 1 ]] || continue
            kernel_inventory_package_installed "$package" || continue
            _kernel_inventory_package_in_purge_set "$package" && continue
            _kernel_inventory_meta_must_remove "$package" || continue
            meta_series="${KERNEL_PKG_SERIES[$package]}"
            if [[ "$series" == unknown || "$meta_series" != "$series" ]]; then
                _kernel_inventory_error "卸载 $release 会影响其他或不明系列元包 $package（$meta_series）"
                KERNEL_PURGE_PACKAGES=()
                KERNEL_PURGE_METAPACKAGES=()
                return 30
            fi
            _kernel_inventory_append_unique KERNEL_PURGE_PACKAGES "$package"
            _kernel_inventory_append_unique KERNEL_PURGE_METAPACKAGES "$package"
            changed=1
        done
    done
}

kernel_validate_purge_simulation() {
    local output="${1:-}" command_status="${2:-${KERNEL_APT_SIMULATION_STATUS:-0}}" line action package expected
    local saw_action=0
    local -A seen=()
    [[ "$command_status" =~ ^[0-9]+$ && "$command_status" == 0 ]] || {
        _kernel_inventory_error "APT 模拟执行失败（退出码 $command_status）"
        return 30
    }
    ((${#KERNEL_PURGE_PACKAGES[@]} > 0)) || {
        _kernel_inventory_error 'APT 模拟前没有精确卸载允许集合'
        return 30
    }
    while IFS= read -r line; do
        if [[ "$line" =~ ^(Inst|Conf|Remv|Purg)[[:space:]]+([^[:space:]]+) ]]; then
            action="${BASH_REMATCH[1]}"
            package="${BASH_REMATCH[2]}"
            saw_action=1
            if [[ "$action" == Inst || "$action" == Conf ]]; then
                _kernel_inventory_error "APT 模拟包含禁止的 $action 操作：$package"
                return 30
            fi
            _kernel_inventory_package_in_purge_set "$package" || {
                _kernel_inventory_error "APT 模拟将移除允许集合外的软件包：$package"
                return 30
            }
            [[ -z "${seen[$package]:-}" ]] || {
                _kernel_inventory_error "APT 模拟重复报告软件包操作：$package"
                return 30
            }
            seen[$package]="$action"
        fi
    done <<<"$output"
    ((saw_action == 1)) || {
        _kernel_inventory_error 'APT 模拟没有给出可验证的软件包操作'
        return 30
    }
    for expected in "${KERNEL_PURGE_PACKAGES[@]}"; do
        [[ -n "${seen[$expected]:-}" ]] || {
            _kernel_inventory_error "APT 模拟未包含预期卸载的软件包：$expected"
            return 30
        }
    done
}
