#!/usr/bin/env bash
# Retirement rollback uses real files with isolated service/package substitutes.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$WORK/root" VPSCTL_ENV_INIT=systemd
export VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1
mkdir -p "$VPSCTL_SYSTEM_ROOT"
# shellcheck source=../../lib/command.sh
source "$ROOT/lib/command.sh"
vps_cmd_init 'native legacy regression' "$ROOT"
# shellcheck source=../../commands/network/nftables/legacy.sh
source "$ROOT/commands/network/nftables/legacy.sh"
# Used by the sourced legacy runtime deployment function.
# shellcheck disable=SC2034
NFT_CLI_PROJECT_ROOT="$ROOT"
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
mkdir -p "$WORK/services" "$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d" \
    "$VPSCTL_SYSTEM_ROOT/etc/default" "$VPSCTL_SYSTEM_ROOT/etc/systemd/system" \
    "$VPSCTL_SYSTEM_ROOT/etc/vpsctl" "$VPSCTL_SYSTEM_ROOT/usr/local/bin" \
    "$VPSCTL_SYSTEM_ROOT/var/lib/vpsctl/network/rfw"
printf 'ENABLED=yes\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/ufw.conf"
printf 'IPV6=yes\n' >"$VPSCTL_SYSTEM_ROOT/etc/default/ufw"
printf 'OpenSSH external profile\n' >"$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d/openssh-server"
printf '# Managed by vpsctl (rfw)\n' >"$VPSCTL_SYSTEM_ROOT/etc/systemd/system/rfw.service"
printf '# Managed by vpsctl (rfw)\ninterface=eth0\n' >"$VPSCTL_SYSTEM_ROOT/etc/vpsctl/rfw.conf"
printf 'saved-binary\n' >"$VPSCTL_SYSTEM_ROOT/usr/local/bin/rfw"
touch "$WORK/services/ufw-installed" "$WORK/services/ufw-active" "$WORK/services/ufw-enabled" \
    "$WORK/services/rfw-active" "$WORK/services/rfw-enabled"
mkdir -p "$VPSCTL_SYSTEM_ROOT/usr/local/libexec/vpsctl-proxy-runtime/lib"
printf 'old backend\n' >"$VPSCTL_SYSTEM_ROOT/usr/local/libexec/vpsctl-proxy-runtime/lib/ufw.sh"
printf '#!/usr/bin/env bash\n# Managed by vpsctl proxy relay-forward.\n' >"$VPSCTL_SYSTEM_ROOT/usr/local/libexec/vpsctl-proxy-forward-refresh"
command() {
    if [[ "${1:-}" == -v && "${2:-}" == ufw ]]; then
        [[ -e "$WORK/services/ufw-installed" ]]
    elif [[ "${1:-}" == -v && "${2:-}" == dpkg-query ]]; then
        return 1
    else builtin command "$@"; fi
}
ufw() {
    [[ -e "$WORK/services/ufw-installed" ]] || return 127
    case "${1:-}:${2:-}" in
        status:) if [[ -e "$WORK/services/ufw-active" ]]; then printf 'Status: active\n'; else printf 'Status: inactive\n'; fi ;;
        --force:disable) rm -f "$WORK/services/ufw-active" ;;
        --force:enable) touch "$WORK/services/ufw-active" ;;
        *) return 2 ;;
    esac
}
# vps_cmd_run env invokes an executable, so dispatch that one fixed adapter here.
vps_cmd_run() {
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || return 0
    if [[ "${1:-}" == env && "${2:-}" == LC_ALL=C && "${3:-}" == ufw ]]; then
        shift 3
        ufw "$@"
    else "$@"; fi
}
systemctl() {
    local operation="$1" service="${2:-}"
    service="${service%.service}"
    case "$operation" in
        is-active)
            if [[ "$service" == --quiet ]]; then
                service="${3%.service}"
                [[ -e "$WORK/services/$service-active" ]]
                return
            fi
            if [[ -e "$WORK/services/$service-active" ]]; then printf active; else
                printf inactive
                return 3
            fi
            ;;
        is-enabled) if [[ -e "$WORK/services/$service-enabled" ]]; then printf enabled; else
            printf disabled
            return 1
        fi ;;
        stop)
            [[ ! -e "$WORK/fail-stop" ]] || return 20
            rm -f "$WORK/services/$service-active"
            ;;
        disable) rm -f "$WORK/services/$service-enabled" ;;
        start | restart) touch "$WORK/services/$service-active" ;;
        enable) touch "$WORK/services/$service-enabled" ;;
        daemon-reload) ;;
        *) return 2 ;;
    esac
}
ip() {
    if [[ -e "$WORK/services/rfw-active" || -e "$WORK/stuck-xdp" ]]; then
        printf '[{"ifname":"eth0","xdp":{"prog":{"id":42,"name":"rfw"}}}]\n'
    else printf '[]\n'; fi
}
sysctl() {
    if [[ "$1" == -n ]]; then printf '1\n'; else printf '%s\n' "$*" >>"$WORK/sysctl.log"; fi
}
vps_cmd_detect_package_manager() { printf apk; }
apk() {
    [[ "$1:${2:-}" == del:ufw ]] || return 2
    [[ ! -e "$WORK/fail-purge" ]] || return 20
    rm -f "$WORK/services/ufw-installed"
}
vps_cmd_install_packages() {
    [[ "$*" == $'apk\nufw' || "$1:$2" == apk:ufw ]] || return 2
    touch "$WORK/services/ufw-installed"
}

nft_cli_legacy_begin "$WORK/before"
[[ -e "$WORK/services/rfw-active" && -e "$WORK/services/ufw-active" ]] || fail 'backup changed services'
touch "$WORK/stuck-xdp"
status=0
nft_cli_legacy_retire "$WORK/before" || status=$?
[[ "$status" == 20 && -f "$VPSCTL_SYSTEM_ROOT/usr/local/bin/rfw" ]] || fail 'stuck XDP was not rejected before cleanup'
rm "$WORK/stuck-xdp"
nft_cli_legacy_restore "$WORK/before"
[[ -e "$WORK/services/rfw-active" && -e "$WORK/services/ufw-active" ]] || fail 'failed retirement did not restore active services'
[[ -f "$VPSCTL_SYSTEM_ROOT/usr/local/libexec/vpsctl-proxy-runtime/lib/ufw.sh" && ! -e "$VPSCTL_SYSTEM_ROOT/usr/local/libexec/vpsctl-proxy-runtime/lib/nftables.sh" ]] || fail 'runtime rollback did not restore exact old deployment'
nft_cli_legacy_retire "$WORK/before"
[[ -f "$VPSCTL_SYSTEM_ROOT/usr/local/libexec/vpsctl-proxy-runtime/lib/nftables/render.jq" && ! -e "$VPSCTL_SYSTEM_ROOT/usr/local/libexec/vpsctl-proxy-runtime/lib/ufw.sh" ]] || fail 'retirement did not upgrade deployed background runtime'
touch "$WORK/fail-purge"
status=0
nft_cli_legacy_finish "$WORK/before" || status=$?
[[ "$status" == 20 ]] || fail 'package failure was hidden'
rm "$WORK/fail-purge"
nft_cli_legacy_restore "$WORK/before"
[[ -e "$WORK/services/rfw-enabled" && -e "$WORK/services/ufw-enabled" ]] || fail 'failed purge did not restore boot state'
nft_cli_legacy_retire "$WORK/before"
nft_cli_legacy_finish "$WORK/before"
[[ ! -e "$WORK/services/ufw-installed" && ! -e "$VPSCTL_SYSTEM_ROOT/usr/local/bin/rfw" ]] || fail 'retirement left old backends'
[[ -f "$VPSCTL_SYSTEM_ROOT/etc/ufw/applications.d/openssh-server" ]] || fail 'foreign profile removed'
nft_cli_legacy_begin "$WORK/native-only"
: >"$WORK/native-only/retirement-started"
nft_cli_legacy_restore "$WORK/before"
[[ "$(<"$VPSCTL_SYSTEM_ROOT/usr/local/bin/rfw")" == saved-binary ]] || fail 'binary did not restore'
nft_cli_legacy_restore "$WORK/native-only"
[[ ! -e "$WORK/services/ufw-installed" && ! -e "$VPSCTL_SYSTEM_ROOT/usr/local/bin/rfw" ]] || fail 'failed restore compensation retained legacy backend'
VPSCTL_DRY_RUN=1 nft_cli_legacy_begin "$WORK/dry"
[[ ! -e "$WORK/dry" ]] || fail 'dry run created backup'
printf 'PASS: legacy retirement, XDP retention refusal, package failure rollback, inverse restore and foreign profile preservation\n'
