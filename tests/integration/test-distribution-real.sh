#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
readonly ENTRY=/usr/local/bin/vpsctl
readonly INSTALL_ROOT=/usr/local/lib/vpsctl
readonly SELF_ROOT=/var/lib/vpsctl/self

[[ "$(uname -s)" == Linux ]] || { printf 'SKIP: distribution real test requires Linux\n'; exit 0; }
((EUID == 0)) || { printf 'FAIL: distribution real test requires root\n' >&2; exit 4; }

TEST_TEMP="$(mktemp -d /root/vpsctl-distribution-real.XXXXXX)"
RELEASE_DIR="${TEST_TEMP}/release"
BACKUP_DIR="${TEST_TEMP}/backup"
MOCK_BIN="${TEST_TEMP}/mock-bin"
MARKER_ID="distribution-real-$$"
ETC_MARKER="/etc/vpsctl/${MARKER_ID}"
STATE_MARKER="/var/lib/vpsctl/network/${MARKER_ID}"
LIBEXEC_MARKER="/usr/local/libexec/${MARKER_ID}"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

backup_path() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        cp -a --parents -- "$path" "$BACKUP_DIR"
    fi
}

restore_path() {
    local path="$1" saved
    saved="${BACKUP_DIR}${path}"
    if [[ -e "$saved" || -L "$saved" ]]; then
        mkdir -p -- "${path%/*}"
        cp -a -- "$saved" "$path"
    fi
}

cleanup() {
    rm -f -- "$ENTRY"
    rm -rf -- "$INSTALL_ROOT" "$SELF_ROOT"
    restore_path "$ENTRY"
    restore_path "$INSTALL_ROOT"
    restore_path "$SELF_ROOT"
    rm -f -- "$ETC_MARKER" "$STATE_MARKER" "$LIBEXEC_MARKER"
    rm -rf -- "$TEST_TEMP"
}

trap cleanup EXIT
mkdir -p -- "$RELEASE_DIR" "$BACKUP_DIR" "$MOCK_BIN"
backup_path "$ENTRY"
backup_path "$INSTALL_ROOT"
backup_path "$SELF_ROOT"
rm -f -- "$ENTRY"
rm -rf -- "$INSTALL_ROOT" "$SELF_ROOT"

bash "$TEST_ROOT/scripts/build-release.sh" "$RELEASE_DIR"

cat >"$MOCK_BIN/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
destination=''
url=''
while (($# > 0)); do
    case "$1" in
        --output | -o)
            destination="${2:?missing curl output path}"
            shift 2
            ;;
        --output=*) destination="${1#*=}"; shift ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
[[ "${VPSCTL_TEST_CURL_FAIL:-0}" != 1 ]] || exit 77
[[ -n "$destination" && -n "$url" ]] || exit 2
cp -- "${VPSCTL_TEST_ASSET_DIR:?}/${url##*/}" "$destination"
MOCK_CURL
chmod 0755 "$MOCK_BIN/curl"
export VPSCTL_TEST_ASSET_DIR="$RELEASE_DIR"

install_output="$(PATH="$MOCK_BIN:$PATH" bash "$RELEASE_DIR/vpsctl.sh" \
    --verified-manifest "$RELEASE_DIR/vpsctl-manifest.tsv" --version)"
[[ "$install_output" == 'vpsctl 0.6.0' ]] || fail 'bootstrap did not enter the installed CLI'
[[ -x "$ENTRY" && -L "$INSTALL_ROOT/current" ]] || fail 'managed launcher/current were not installed'
release_root="$(readlink -f -- "$INSTALL_ROOT/current")"
[[ -f "$release_root/.bundles/core.sha256" ]] || fail 'core marker is missing'
for domain in network system security service test; do
    [[ ! -e "$release_root/.bundles/${domain}.sha256" ]] || fail "${domain} was installed eagerly"
done

PATH="$MOCK_BIN:$PATH" "$ENTRY" network bbr --help >/dev/null
PATH="$MOCK_BIN:$PATH" "$ENTRY" system kernel --help >/dev/null
PATH="$MOCK_BIN:$PATH" "$ENTRY" security fail2ban --help >/dev/null
PATH="$MOCK_BIN:$PATH" "$ENTRY" service proxy --help >/dev/null
PATH="$MOCK_BIN:$PATH" "$ENTRY" test nodequality --help >/dev/null
for domain in network system security service test; do
    [[ -f "$release_root/.bundles/${domain}.sha256" ]] || fail "${domain} was not cached on demand"
done

VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" network bbr --help >/dev/null
VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" self status >/dev/null
PATH="$MOCK_BIN:$PATH" "$ENTRY" --yes --non-interactive self update >/dev/null
su nobody -s /bin/bash -c "$ENTRY --version" | grep -Fx 'vpsctl 0.6.0' >/dev/null ||
    fail 'ordinary user could not execute the installed shortcut'

mkdir -p -- "${ETC_MARKER%/*}" "${STATE_MARKER%/*}" "${LIBEXEC_MARKER%/*}"
touch -- "$ETC_MARKER" "$STATE_MARKER" "$LIBEXEC_MARKER"
"$ENTRY" --non-interactive self uninstall --confirm-uninstall >/dev/null
[[ ! -e "$ENTRY" && ! -e "$INSTALL_ROOT/current" && ! -e "$INSTALL_ROOT/releases" ]] ||
    fail 'normal uninstall retained managed code'
[[ -f "$SELF_ROOT/vpsctl.sh" ]] || fail 'normal uninstall removed self state'
[[ -f "$ETC_MARKER" && -f "$STATE_MARKER" && -f "$LIBEXEC_MARKER" ]] ||
    fail 'normal uninstall removed protected feature data'

PATH="$MOCK_BIN:$PATH" bash "$RELEASE_DIR/vpsctl.sh" \
    --verified-manifest "$RELEASE_DIR/vpsctl-manifest.tsv" --version >/dev/null
"$ENTRY" --non-interactive self uninstall --purge --confirm-uninstall --confirm-purge >/dev/null
[[ ! -e "$SELF_ROOT" ]] || fail 'purge retained self metadata'
[[ -f "$ETC_MARKER" && -f "$STATE_MARKER" && -f "$LIBEXEC_MARKER" ]] ||
    fail 'purge removed protected feature data'

printf 'PASS: distribution real integration test\n'
