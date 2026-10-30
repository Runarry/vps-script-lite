# shellcheck shell=bash
# shellcheck disable=SC2034 # Selected paths are the public API consumed by capture and recovery.
# A pinned, isolated ReaR checkout is used when the distro package is too old.

bs_rear_version_at_least() {
    local value="$1" major="$2" minor="$3"
    [[ "$value" =~ Relax-and-Recover[[:space:]]+([0-9]+)\.([0-9]+) ]] || return 3
    ((BASH_REMATCH[1] > major || (BASH_REMATCH[1] == major && BASH_REMATCH[2] >= minor)))
}

bs_rear_select() {
    local binary="$1" prefix system_binary
    binary="$(readlink -f "$binary")" || return 20
    system_binary="$(readlink -f "$(vps_cmd_system_path /usr/sbin/rear)")" || system_binary=''
    [[ -x "$binary" ]] || return 3
    if [[ -n "$system_binary" && "$binary" == "$system_binary" ]]; then
        # Native rescue images deliberately merge /usr/sbin into /bin.
        prefix="${VPSCTL_SYSTEM_ROOT:-}"
    elif [[ "$binary" == */usr/sbin/rear ]]; then
        prefix="${binary%/usr/sbin/rear}"
    else
        vps_cmd_error 'ReaR 安装布局必须包含 usr/sbin/rear 和匹配的 usr/share/rear。'
        return 3
    fi
    BS_REAR_BIN="$binary"
    BS_REAR_SHARE="$prefix/usr/share/rear"
    BS_REAR_VAR="$prefix/var/lib/rear"
    BS_REAR_LOG_DIR="$prefix/var/log/rear"
    [[ -f "$BS_REAR_SHARE/conf/default.conf" ]] || {
        vps_cmd_error "缺少匹配 ReaR 库：$BS_REAR_SHARE"
        return 3
    }
}

bs_rear() { "${BS_REAR_BIN:-rear}" "$@"; }

bs_rear_install_pinned() (
    local target="$1" archive temporary lock
    local url='https://github.com/rear/rear/releases/download/release/2.9/rear-2.9.tar.gz'
    # Pinned from the official HTTPS release asset, not an upstream-signed hash.
    # The GitHub release API for this historic asset has no digest field.
    local digest='40a2aafab7bceac33585b89de8404cfae4b7f1aa3532cd19ed2298feb0005be7'
    backup_private_dir "$BACKUP_STATE" "$BACKUP_STATE/tools" || return $?
    exec {lock}>"$BACKUP_STATE/tools/.rear-prepare.lock" || return 20
    flock -n "$lock" || {
        vps_cmd_error '其他操作正在准备 ReaR，请稍后重试。'
        return 3
    }
    if [[ -e "$target" ]]; then
        [[ -f "$target/.vpsctl-release-sha256" && "$(cat "$target/.vpsctl-release-sha256")" == "$digest" ]] || {
            vps_cmd_error "已有非匹配受管目录 $target；不会覆盖。"
            return 10
        }
        return 0
    fi
    temporary="$(mktemp -d "$BACKUP_STATE/tools/.rear-prepare.XXXXXX")" || return 20
    trap 'rm -rf -- "$temporary"' EXIT
    archive="$temporary/rear-2.9.tar.gz"
    curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 --retry 2 --output "$archive" "$url" || return 20
    printf '%s  %s\n' "$digest" "$archive" | sha256sum -c - >/dev/null || {
        vps_cmd_error '官方 ReaR 2.9 资产摘要不匹配，未安装或执行下载内容。'
        return 20
    }
    tar -xzf "$archive" --no-same-owner -C "$temporary" || return 20
    [[ -f "$temporary/rear-2.9/usr/share/rear/conf/default.conf" && -f "$temporary/rear-2.9/usr/sbin/rear" ]] || return 20
    chmod 0755 "$temporary/rear-2.9/usr/sbin/rear" || return 20
    bs_rear_version_at_least "$("$temporary/rear-2.9/usr/sbin/rear" -V)" 2 9 || return 20
    mkdir -p "$temporary/rear-2.9/var/lib/rear" "$temporary/rear-2.9/var/log/rear" || return 20
    printf '%s\n' "$digest" >"$temporary/rear-2.9/.vpsctl-release-sha256"
    jq -nc --arg url "$url" --arg digest "$digest" '{schema_version:1,version:"2.9",source:$url,sha256:$digest,checksum_provenance:"pinned from official HTTPS release asset; upstream API has no independent digest",installed_by:"vpsctl-system-backup"}' >"$temporary/rear-2.9/vpsctl-tool.json" || return 20
    mv "$temporary/rear-2.9" "$target" || return 20
)

bs_prepare_rear() {
    local candidate='' version='' id='' release='' os_file target minimum_minor=7
    os_file="$(vps_cmd_system_path /etc/os-release)" || return $?
    if [[ -r "$os_file" ]]; then
        id="$(awk -F= '$1=="ID"{gsub(/"/,"",$2);print $2}' "$os_file")"
        release="$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2);print $2}' "$os_file")"
    fi
    # Debian 13 / ReaR 2.7 generated a non-booting rescue system in the real VM.
    # Upstream issue 3528 also documents that combination and the 2.9 solution.
    if [[ "$id" == debian && "${release%%.*}" =~ ^[0-9]+$ ]] && ((${release%%.*} >= 13)); then minimum_minor=9; fi
    if candidate="$(command -v rear)" && version="$("$candidate" -V 2>/dev/null)" && bs_rear_version_at_least "$version" 2 "$minimum_minor"; then
        bs_rear_select "$candidate"
        return $?
    fi
    target="$BACKUP_STATE/tools/rear-2.9"
    if [[ -f "$target/.vpsctl-release-sha256" && "$(cat "$target/.vpsctl-release-sha256")" == 40a2aafab7bceac33585b89de8404cfae4b7f1aa3532cd19ed2298feb0005be7 ]]; then
        bs_rear_select "$target/usr/sbin/rear" || return $?
        bs_rear_version_at_least "$(bs_rear -V)" 2 9 || return 3
        return 0
    fi
    if [[ "$VPSCTL_DRY_RUN" == 1 ]]; then
        vps_cmd_info "演练：需要 ReaR >=2.$minimum_minor；将校验官方固定 2.9 并安装到 $target（不改系统 ReaR）。先实际准备依赖后才能检查 ISO。"
        return 3
    fi
    if [[ "$VPSCTL_INSTALL_DEPS" != 1 ]]; then
        vps_cmd_is_interactive || {
            vps_cmd_error "当前 ReaR 不满足 $id $release 的 >=2.$minimum_minor 要求；使用 --install-deps 准备校验的官方 2.9 独立副本。"
            return 3
        }
        vps_cmd_warning "需要下载并校验官方 ReaR 2.9 到 $target，并准备 curl/tar/校验工具；不覆盖系统包。"
        _vps_cmd_confirm_dependency_install || return $?
    fi
    vps_cmd_require_root || return $?
    # This local authorization only covers the explicitly described preparation.
    local VPSCTL_INSTALL_DEPS=1
    backup_ensure_tools curl tar sha256sum flock jq || return $?
    bs_rear_install_pinned "$target" || return $?
    bs_rear_select "$target/usr/sbin/rear"
}
