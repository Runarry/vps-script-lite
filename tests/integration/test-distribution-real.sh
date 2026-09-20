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

# Future shared libraries must be accepted by both bootstrap and update.
EXTRA_CORE="$TEST_TEMP/extra-core"
mkdir -p "$EXTRA_CORE"
tar -xzf "$RELEASE_DIR/vpsctl-core-0.8.9.tar.gz" -C "$EXTRA_CORE"
mkdir -p "$EXTRA_CORE/lib/nested"
printf '# bootstrap shared helper\n' >"$EXTRA_CORE/lib/nested/bootstrap-helper.sh"
tar -C "$EXTRA_CORE" -czf "$RELEASE_DIR/vpsctl-core-0.8.9.tar.gz" VERSION bin lib commands
core_sha="$(sha256sum "$RELEASE_DIR/vpsctl-core-0.8.9.tar.gz" | awk '{print $1}')"
sed -i "s/^bundle\tcore\t.*/bundle\tcore\tvpsctl-core-0.8.9.tar.gz\t${core_sha}/" "$RELEASE_DIR/vpsctl-manifest.tsv"

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
case "$url" in
    https://run.NodeQuality.com | https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh)
        cp -- "${VPSCTL_TEST_LOCALE_UPSTREAM:?}" "$destination"
        ;;
    https://github.com/Runarry/vps-script-lite/releases/*)
        cp -- "${VPSCTL_TEST_ASSET_DIR:?}/${url##*/}" "$destination"
        ;;
    *) exit 2 ;;
esac
MOCK_CURL
chmod 0755 "$MOCK_BIN/curl"
export VPSCTL_TEST_ASSET_DIR="$RELEASE_DIR"

install_output="$(PATH="$MOCK_BIN:$PATH" bash "$RELEASE_DIR/vpsctl.sh" \
    --verified-manifest "$RELEASE_DIR/vpsctl-manifest.tsv" --version)"
[[ "$install_output" == 'vpsctl 0.8.9' ]] || fail 'bootstrap did not enter the installed CLI'
[[ -x "$ENTRY" && -L "$INSTALL_ROOT/current" ]] || fail 'managed launcher/current were not installed'
release_root="$(readlink -f -- "$INSTALL_ROOT/current")"
[[ -f "$release_root/.bundles/core.sha256" ]] || fail 'core marker is missing'
[[ -f "$release_root/lib/nested/bootstrap-helper.sh" ]] || fail 'bootstrap rejected new shared library'
su nobody -s /bin/bash -c "$ENTRY --version" | grep -Fx 'vpsctl 0.8.9' >/dev/null ||
    fail 'ordinary user could not execute the freshly installed shortcut'
# Reproduce an older updater leaving a valid, managed core without execute bits.
chmod 0644 "$release_root/bin/vpsctl"
PATH="$MOCK_BIN:$PATH" bash "$RELEASE_DIR/vpsctl.sh" \
    --verified-manifest "$RELEASE_DIR/vpsctl-manifest.tsv" --version >/dev/null
VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" --version >/dev/null ||
    fail 'reinstall did not repair the existing release entry permissions'
for domain in network system security service test; do
    [[ ! -e "$release_root/.bundles/${domain}.sha256" ]] || fail "${domain} was installed eagerly"
done

PATH="$MOCK_BIN:$PATH" "$ENTRY" network bbr --help >/dev/null
PATH="$MOCK_BIN:$PATH" "$ENTRY" network ufw --help >/dev/null
PATH="$MOCK_BIN:$PATH" "$ENTRY" system kernel --help >/dev/null
PATH="$MOCK_BIN:$PATH" "$ENTRY" security fail2ban --help >/dev/null
PATH="$MOCK_BIN:$PATH" "$ENTRY" service proxy --help >/dev/null
PATH="$MOCK_BIN:$PATH" "$ENTRY" test nodequality --help >/dev/null
for domain in network system security service test; do
    [[ -f "$release_root/.bundles/${domain}.sha256" ]] || fail "${domain} was not cached on demand"
done

VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" network bbr --help >/dev/null
VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" network ufw --help >/dev/null
VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" self status >/dev/null
rm -- "$SELF_ROOT/vpsctl.sh"
printf 'corrupt cache\n' >"$SELF_ROOT/manifest.tsv"
PATH="$MOCK_BIN:$PATH" "$ENTRY" --yes --non-interactive self update >/dev/null
cmp "$ENTRY" "$SELF_ROOT/vpsctl.sh" || fail 'same-version update did not repair cached launcher'
cmp "$release_root/.release/manifest.tsv" "$SELF_ROOT/manifest.tsv" || fail 'same-version update did not repair cached manifest'
su nobody -s /bin/bash -c "$ENTRY --version" | grep -Fx 'vpsctl 0.8.9' >/dev/null ||
    fail 'ordinary user could not execute the installed shortcut'

# Exercise a real version change, with a legacy core archive lacking execute
# permission. Same-version update above does not install or activate a new core.
NEXT_SOURCE="$TEST_TEMP/next-source"
NEXT_ASSETS="$TEST_TEMP/next-assets"
mkdir -p "$NEXT_SOURCE" "$NEXT_ASSETS"
cp -a -- "$TEST_ROOT/bin" "$TEST_ROOT/lib" "$TEST_ROOT/commands" \
    "$TEST_ROOT/scripts" "$TEST_ROOT/vpsctl.sh" "$NEXT_SOURCE/"
printf '0.8.10\n' >"$NEXT_SOURCE/VERSION"
sed -i 's/^readonly VPSCTL_VERSION="0.8.9"$/readonly VPSCTL_VERSION="0.8.10"/' "$NEXT_SOURCE/bin/vpsctl"
bash "$NEXT_SOURCE/scripts/build-release.sh" "$NEXT_ASSETS" >/dev/null
LEGACY_CORE="$TEST_TEMP/legacy-core"
mkdir -p "$LEGACY_CORE"
tar -xzf "$NEXT_ASSETS/vpsctl-core-0.8.10.tar.gz" -C "$LEGACY_CORE"
mkdir -p "$LEGACY_CORE/lib/nested"
printf '# update shared helper\n' >"$LEGACY_CORE/lib/nested/update-helper.sh"
chmod 0644 "$LEGACY_CORE/bin/vpsctl"
tar -C "$LEGACY_CORE" -czf "$NEXT_ASSETS/vpsctl-core-0.8.10.tar.gz" VERSION bin lib commands
core_sha="$(sha256sum "$NEXT_ASSETS/vpsctl-core-0.8.10.tar.gz" | awk '{print $1}')"
sed -i "s/^bundle\tcore\t.*/bundle\tcore\tvpsctl-core-0.8.10.tar.gz\t${core_sha}/" "$NEXT_ASSETS/vpsctl-manifest.tsv"
export VPSCTL_TEST_ASSET_DIR="$NEXT_ASSETS"
rm -rf -- "$SELF_ROOT"
PATH="$MOCK_BIN:$PATH" "$ENTRY" --yes --non-interactive self update --version v0.8.10 >/dev/null
[[ -f "$INSTALL_ROOT/current/lib/nested/update-helper.sh" ]] || fail 'update rejected new shared library'
cmp "$ENTRY" "$SELF_ROOT/vpsctl.sh" || fail 'versioned update did not restore cached launcher'
[[ "$(readlink -f "$INSTALL_ROOT/current")" == "$INSTALL_ROOT/releases/0.8.10" ]] || fail 'versioned update did not switch current'
[[ ! -e "$release_root" && ! -L "$release_root" ]] || fail 'versioned update retained the previous release'
[[ "$(find "$INSTALL_ROOT/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')" == 0.8.10 ]] ||
    fail 'versioned update did not leave only the current release'
VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" --version | grep -Fx 'vpsctl 0.8.10' >/dev/null ||
    fail 'updated shortcut could not run offline as root'
su nobody -s /bin/bash -c "$ENTRY --version" | grep -Fx 'vpsctl 0.8.10' >/dev/null ||
    fail 'updated shortcut could not run as an ordinary user'
for domain in network system security service test; do
    [[ -f "$INSTALL_ROOT/current/.bundles/${domain}.sha256" ]] || fail "updated ${domain} cache is missing"
done
VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" network bbr --help >/dev/null
export VPSCTL_TEST_ASSET_DIR="$RELEASE_DIR"

mkdir -p -- "${ETC_MARKER%/*}" "${STATE_MARKER%/*}" "${LIBEXEC_MARKER%/*}"
touch -- "$ETC_MARKER" "$STATE_MARKER" "$LIBEXEC_MARKER"
rm -- "$SELF_ROOT/vpsctl.sh"
"$ENTRY" --yes --non-interactive self uninstall >/dev/null
[[ ! -e "$ENTRY" && ! -e "$INSTALL_ROOT/current" && ! -e "$INSTALL_ROOT/releases" ]] ||
    fail 'normal uninstall retained managed code'
[[ -f "$SELF_ROOT/manifest.tsv" && ! -e "$SELF_ROOT/vpsctl.sh" ]] || fail 'normal uninstall changed self cache'
[[ -f "$ETC_MARKER" && -f "$STATE_MARKER" && -f "$LIBEXEC_MARKER" ]] ||
    fail 'normal uninstall removed protected feature data'

PATH="$MOCK_BIN:$PATH" bash "$RELEASE_DIR/vpsctl.sh" \
    --verified-manifest "$RELEASE_DIR/vpsctl-manifest.tsv" --version >/dev/null
"$ENTRY" --non-interactive self uninstall --purge --confirm-uninstall --confirm-purge >/dev/null
[[ ! -e "$SELF_ROOT" ]] || fail 'purge retained self metadata'
[[ -f "$ETC_MARKER" && -f "$STATE_MARKER" && -f "$LIBEXEC_MARKER" ]] ||
    fail 'purge removed protected feature data'

# Run after the lazy-bundle assertions: each fresh install deliberately requests
# the test bundle immediately. All upstream downloads remain local fixtures.
export VPSCTL_TEST_LOCALE_UPSTREAM="$TEST_TEMP/locale-upstream.sh"
export VPSCTL_TEST_LOCALE_TRACE="$TEST_TEMP/locale-trace"
cat >"$VPSCTL_TEST_LOCALE_UPSTREAM" <<'LOCALE_UPSTREAM'
#!/usr/bin/env bash
set -euo pipefail
printf 'LC_ALL=%s:%s\nLANG=%s:%s\nLC_CTYPE=%s:%s\n' \
    "${LC_ALL+x}" "${LC_ALL-}" "${LANG+x}" "${LANG-}" \
    "${LC_CTYPE+x}" "${LC_CTYPE-}" >"${VPSCTL_TEST_LOCALE_TRACE:?}"
printf 'locale-spinner=\u28FC\u28E4\n'
LOCALE_UPSTREAM

locale_regression() {
    local kind="$1" scenario="$2" launch output
    local lang=C.UTF-8 ctype=C.UTF-8 ctype_state=x all_state=x all_value=''
    local expected_trace="$TEST_TEMP/locale-expected" expected_spinner
    local -a locale_env=(env -u LC_ALL -u LANG -u LC_CTYPE)

    case "$scenario" in
        unset) all_state='' ;;
        empty) locale_env+=(LC_ALL=) ;;
        utf8) all_value=C.UTF-8; locale_env+=(LC_ALL=C.UTF-8) ;;
        lang) all_state=''; ctype_state=''; ctype='' ;;
        ctype) all_state=''; lang=C ;;
        c) all_value=C; locale_env+=(LC_ALL=C) ;;
    esac
    locale_env+=("LANG=$lang" "PATH=$MOCK_BIN:$PATH")
    [[ "$ctype_state" != x ]] || locale_env+=("LC_CTYPE=$ctype")
    printf 'LC_ALL=%s:%s\nLANG=x:%s\nLC_CTYPE=%s:%s\n' \
        "$all_state" "$all_value" "$lang" "$ctype_state" "$ctype" >"$expected_trace"
    # Use fixed UTF-8 octets, independent of the test runner's own locale.
    expected_spinner="$(printf 'locale-spinner=\342\243\274\342\243\244')"
    if [[ "$scenario" == c ]]; then
        expected_spinner='locale-spinner=\u28FC\u28E4'
    fi

    rm -f -- "$ENTRY"
    rm -rf -- "$INSTALL_ROOT" "$SELF_ROOT"
    for launch in fresh installed; do
        rm -f -- "$VPSCTL_TEST_LOCALE_TRACE"
        if [[ "$launch" == fresh ]]; then
            output="$("${locale_env[@]}" bash "$RELEASE_DIR/vpsctl.sh" \
                --verified-manifest "$RELEASE_DIR/vpsctl-manifest.tsv" \
                --quiet --yes test "$kind")" || fail "$kind/$scenario fresh launch failed"
        else
            output="$("${locale_env[@]}" "$ENTRY" --quiet --yes test "$kind")" ||
                fail "$kind/$scenario installed launch failed"
        fi
        cmp -s -- "$expected_trace" "$VPSCTL_TEST_LOCALE_TRACE" ||
            fail "$kind/$scenario/$launch changed the upstream locale environment"
        printf '%s\n' "$output" | grep -Fx -- "$expected_spinner" >/dev/null ||
            fail "$kind/$scenario/$launch changed upstream Unicode output bytes"
    done
}

for locale_kind in nodequality tcpquality; do
    for locale_scenario in unset empty utf8 lang ctype c; do
        locale_regression "$locale_kind" "$locale_scenario"
    done
done

printf 'PASS: distribution real integration test\n'
