#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
readonly RELEASE_VERSION="$(<"${TEST_ROOT}/VERSION")"
readonly NEXT_VERSION="${RELEASE_VERSION%.*}.$((10#${RELEASE_VERSION##*.} + 1))"
readonly ENTRY=/usr/local/bin/vpsctl
readonly INSTALL_ROOT=/usr/local/lib/vpsctl
readonly SELF_ROOT=/var/lib/vpsctl/self

[[ "$(uname -s)" == Linux ]] || { printf 'SKIP: distribution real test requires Linux\n'; exit 0; }
((EUID == 0)) || { printf 'FAIL: distribution real test requires root\n' >&2; exit 4; }
command -v script >/dev/null 2>&1 || { printf 'FAIL: distribution menu test requires script\n' >&2; exit 3; }

TEST_TEMP="$(mktemp -d /root/vpsctl-distribution-real.XXXXXX)"
RELEASE_DIR="${TEST_TEMP}/release"
BACKUP_DIR="${TEST_TEMP}/backup"
MOCK_BIN="${TEST_TEMP}/mock-bin"
MARKER_ID="distribution-real-$$"
ETC_MARKER="/etc/vpsctl/${MARKER_ID}"
STATE_MARKER="/var/lib/vpsctl/network/${MARKER_ID}"
LIBEXEC_MARKER="/usr/local/libexec/${MARKER_ID}"
BACKUP_MARKER="/var/backups/vpsctl/${MARKER_ID}"
CACHE_UFW_STATE_DIR=/var/lib/vpsctl/network/ufw
CACHE_UFW_LOCK=/run/vpsctl/network-ufw.lock
CACHE_UFW_BACKUP="$TEST_TEMP/cache-ufw-baseline"
CACHE_UFW_BASELINE_TAKEN=0
CACHE_UFW_LOCK_PARENT_EXISTED=0

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

snapshot_feature_cache_ufw() {
    local path
    for path in /var/lib/vpsctl /var/lib/vpsctl/network /run/vpsctl; do
        [[ ! -L "$path" ]] || fail "shared UFW parent path is a symlink: $path"
    done
    [[ ! -L "$CACHE_UFW_STATE_DIR" && ( ! -e "$CACHE_UFW_STATE_DIR" || -d "$CACHE_UFW_STATE_DIR" ) ]] || fail 'unsafe shared UFW state directory before feature cache test'
    [[ ! -e "$CACHE_UFW_STATE_DIR/pending.json" && ! -L "$CACHE_UFW_STATE_DIR/pending.json" ]] || fail 'shared UFW recovery is pending before feature cache test'
    [[ ! -L "$CACHE_UFW_LOCK" && ( ! -e "$CACHE_UFW_LOCK" || -f "$CACHE_UFW_LOCK" ) ]] || fail 'unsafe shared UFW lock before feature cache test'
    rm -rf -- "$CACHE_UFW_BACKUP"
    mkdir -p -- "$CACHE_UFW_BACKUP"
    CACHE_UFW_LOCK_PARENT_EXISTED=0
    [[ ! -d "${CACHE_UFW_LOCK%/*}" ]] || CACHE_UFW_LOCK_PARENT_EXISTED=1
    if [[ -d "$CACHE_UFW_STATE_DIR" ]]; then cp -a -- "$CACHE_UFW_STATE_DIR" "$CACHE_UFW_BACKUP/state"; fi
    if [[ -f "$CACHE_UFW_LOCK" ]]; then cp -a -- "$CACHE_UFW_LOCK" "$CACHE_UFW_BACKUP/lock"; fi
    CACHE_UFW_BASELINE_TAKEN=1
}

restore_feature_cache_ufw() {
    [[ "$CACHE_UFW_BASELINE_TAKEN" == 1 ]] || return 0
    rm -rf -- "$CACHE_UFW_STATE_DIR" || return 1
    if [[ -d "$CACHE_UFW_BACKUP/state" ]]; then
        cp -a -- "$CACHE_UFW_BACKUP/state" "$CACHE_UFW_STATE_DIR" || return 1
    fi
    rm -f -- "$CACHE_UFW_LOCK" || return 1
    if [[ -f "$CACHE_UFW_BACKUP/lock" ]]; then
        mkdir -p -- "${CACHE_UFW_LOCK%/*}" || return 1
        cp -a -- "$CACHE_UFW_BACKUP/lock" "$CACHE_UFW_LOCK" || return 1
    elif [[ "$CACHE_UFW_LOCK_PARENT_EXISTED" == 0 && -d "${CACHE_UFW_LOCK%/*}" ]]; then
        rmdir -- "${CACHE_UFW_LOCK%/*}" || return 1
    fi
    CACHE_UFW_BASELINE_TAKEN=0
}

feature_release_hashes() (
    cd -- "$release_root"
    find . -type f -print0 | sort -z | xargs -0 -r sha256sum
)

cleanup() {
    local restore_status=0
    restore_feature_cache_ufw || restore_status=1
    rm -f -- "$ENTRY"
    rm -rf -- "$INSTALL_ROOT" "$SELF_ROOT"
    restore_path "$ENTRY"
    restore_path "$INSTALL_ROOT"
    restore_path "$SELF_ROOT"
    rm -f -- "$ETC_MARKER" "$STATE_MARKER" "$LIBEXEC_MARKER" "$BACKUP_MARKER"
    if [[ "$restore_status" == 0 ]]; then
        rm -rf -- "$TEST_TEMP"
    else
        printf 'FAIL: shared UFW metadata restore failed; baseline retained at %s\n' "$CACHE_UFW_BACKUP" >&2
        return 1
    fi
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
tar -xzf "$RELEASE_DIR/vpsctl-core-${RELEASE_VERSION}.tar.gz" -C "$EXTRA_CORE"
mkdir -p "$EXTRA_CORE/lib/nested"
printf '# bootstrap shared helper\n' >"$EXTRA_CORE/lib/nested/bootstrap-helper.sh"
tar -C "$EXTRA_CORE" -czf "$RELEASE_DIR/vpsctl-core-${RELEASE_VERSION}.tar.gz" VERSION bin lib commands
core_sha="$(sha256sum "$RELEASE_DIR/vpsctl-core-${RELEASE_VERSION}.tar.gz" | awk '{print $1}')"
sed -i "s/^bundle\tcore\t.*/bundle\tcore\tvpsctl-core-${RELEASE_VERSION}.tar.gz\t${core_sha}/" "$RELEASE_DIR/vpsctl-manifest.tsv"

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
printf '%s\n' "${url##*/}" >>"${VPSCTL_TEST_DOWNLOAD_TRACE:?}"
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
export VPSCTL_TEST_DOWNLOAD_TRACE="$TEST_TEMP/download-trace"
mkdir -p -- "${ETC_MARKER%/*}" "${STATE_MARKER%/*}" "${LIBEXEC_MARKER%/*}" "${BACKUP_MARKER%/*}"
touch -- "$ETC_MARKER" "$STATE_MARKER" "$LIBEXEC_MARKER" "$BACKUP_MARKER"

# Optional historical fixture must be the actual published schema-1 release.
if [[ -n "${VPSCTL_TEST_LEGACY_ASSET_DIR:-}" ]]; then
    legacy="$VPSCTL_TEST_LEGACY_ASSET_DIR"
    [[ "$(head -n 1 "$legacy/vpsctl-manifest.tsv")" == $'schema_version\t1' ]] || fail 'legacy fixture is not schema 1'
    awk -F '\t' '$1 == "asset" || $1 == "bundle" {print $NF "  " $(NF-1)}' "$legacy/vpsctl-manifest.tsv" |
        (cd "$legacy" && sha256sum -c -) >/dev/null || fail 'legacy asset digest mismatch'
    export VPSCTL_TEST_ASSET_DIR="$legacy"
    : >"$VPSCTL_TEST_DOWNLOAD_TRACE"
    legacy_output="$(PATH="$MOCK_BIN:$PATH" bash -s -- --version <"$TEST_ROOT/vpsctl.sh")"
    [[ "$legacy_output" == 'vpsctl 0.8.9' ]] || fail 'source bootstrap did not enter the published schema-1 CLI'
    [[ "$(sort "$VPSCTL_TEST_DOWNLOAD_TRACE")" == "$(printf '%s\n' vpsctl.sh vpsctl-manifest.tsv vpsctl-core-0.8.9.tar.gz | sort)" ]] ||
        fail 'schema-1 bootstrap downloaded more than launcher, manifest and core'
    PATH="$MOCK_BIN:$PATH" "$ENTRY" network bbr --help >/dev/null
    [[ -f "$INSTALL_ROOT/current/.bundles/network.sha256" ]] || fail 'legacy domain cache missing'
    "$ENTRY" --non-interactive self uninstall --confirm-uninstall >/dev/null
    [[ ! -e "$ENTRY" && ! -e "$INSTALL_ROOT/releases" ]] || fail 'legacy normal uninstall left managed code'
    export VPSCTL_TEST_ASSET_DIR="$RELEASE_DIR"
fi

: >"$VPSCTL_TEST_DOWNLOAD_TRACE"
install_output="$(PATH="$MOCK_BIN:$PATH" bash "$RELEASE_DIR/vpsctl.sh" --version)"
[[ "$(sort "$VPSCTL_TEST_DOWNLOAD_TRACE")" == "$(printf '%s\n' vpsctl.sh vpsctl-manifest.tsv "vpsctl-core-${RELEASE_VERSION}.tar.gz" | sort)" ]] ||
    fail 'fresh install downloaded more than launcher, manifest and core'
[[ -f "$ETC_MARKER" && -f "$STATE_MARKER" && -f "$LIBEXEC_MARKER" && -f "$BACKUP_MARKER" ]] ||
    fail 'migration did not preserve business data'
[[ "$install_output" == "vpsctl $RELEASE_VERSION" ]] || fail 'bootstrap did not enter the installed CLI'
[[ -x "$ENTRY" && -L "$INSTALL_ROOT/current" ]] || fail 'managed launcher/current were not installed'
release_root="$(readlink -f -- "$INSTALL_ROOT/current")"
[[ -f "$release_root/.bundles/core.sha256" ]] || fail 'core marker is missing'
[[ -f "$release_root/lib/nested/bootstrap-helper.sh" ]] || fail 'bootstrap rejected new shared library'
su nobody -s /bin/bash -c "$ENTRY --version" | grep -Fx "vpsctl $RELEASE_VERSION" >/dev/null ||
    fail 'ordinary user could not execute the freshly installed shortcut'
# Reproduce an older updater leaving a valid, managed core without execute bits.
chmod 0644 "$release_root/bin/vpsctl"
PATH="$MOCK_BIN:$PATH" bash "$RELEASE_DIR/vpsctl.sh" \
    --verified-manifest "$RELEASE_DIR/vpsctl-manifest.tsv" --version >/dev/null
VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" --version >/dev/null ||
    fail 'reinstall did not repair the existing release entry permissions'
[[ "$(find "$release_root/.bundles" -type f -printf '%f\n')" == core.sha256 ]] || fail 'non-core bundle installed eagerly'
[[ ! -e "$release_root/lib/command.sh" && ! -e "$release_root/lib/ufw.sh" && ! -e "$release_root/lib/server-test.sh" ]] ||
    fail 'core contains feature shared libraries'
: >"$VPSCTL_TEST_DOWNLOAD_TRACE"
for builtin in --help --version list env; do
    VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" "$builtin" >/dev/null
done
VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" self status >/dev/null
[[ ! -s "$VPSCTL_TEST_DOWNLOAD_TRACE" ]] || fail 'core browsing contacted the network'

# Browse the actual TTY menus without selecting a feature: core must be enough.
printf '1\nb\nq\n' |
    VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" TERM=dumb \
        script -q -e -c "$ENTRY --no-color --no-clear menu" /dev/null >"$TEST_TEMP/menu.log" 2>&1 ||
    fail 'installed menu browsing failed'
grep -Fq '主菜单 / 网络设置' "$TEST_TEMP/menu.log" || fail 'network category menu was not reached'
[[ ! -s "$VPSCTL_TEST_DOWNLOAD_TRACE" ]] || fail 'menu browsing contacted the network'
[[ "$(find "$release_root/.bundles" -type f -printf '%f\n')" == core.sha256 ]] || fail 'menu browsing cached a feature'

PATH="$MOCK_BIN:$PATH" "$ENTRY" network bbr --help >/dev/null
[[ "$(sort "$VPSCTL_TEST_DOWNLOAD_TRACE")" == "$(printf '%s\n' "vpsctl-shared-command-${RELEASE_VERSION}.tar.gz" "vpsctl-network-bbr-${RELEASE_VERSION}.tar.gz" | sort)" ]] ||
    fail 'first BBR invocation downloaded unrelated bundles'
[[ ! -e "$release_root/commands/network/dns.sh" && ! -e "$release_root/lib/ufw.sh" ]] || fail 'BBR cache contains unrelated code'
features=(network-bbr network-dns network-ip-policy network-ufw network-rfw system-kernel system-reinstall security-access security-fail2ban security-tls service-proxy service-tcping service-iperf3 test-nodequality test-tcpquality)
for feature in "${features[@]}"; do
    PATH="$MOCK_BIN:$PATH" "$ENTRY" "${feature%%-*}" "${feature#*-}" --help >/dev/null
    [[ -f "$release_root/.bundles/${feature}.sha256" ]] || fail "$feature was not cached on demand"
done
[[ -f "$release_root/commands/service/tcping/listener.py" ]] || fail 'tcping private listener was not cached'
for shared in command ufw server-test; do
    [[ "$(grep -Fc "vpsctl-shared-${shared}-${RELEASE_VERSION}.tar.gz" "$VPSCTL_TEST_DOWNLOAD_TRACE")" == 1 ]] ||
        fail "shared $shared fetched more than once"
done
: >"$VPSCTL_TEST_DOWNLOAD_TRACE"
for feature in "${features[@]}"; do
    VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" "${feature%%-*}" "${feature#*-}" --help >/dev/null
done
VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" self status >/dev/null
[[ ! -s "$VPSCTL_TEST_DOWNLOAD_TRACE" ]] || fail 'cached feature contacted the network'

for cache_feature in tcping iperf3; do
    case "$cache_feature" in
        tcping) [[ "${VPSCTL_TEST_TCPING_UNINSTALL:-0}" == 1 ]] || continue ;;
        iperf3) [[ "${VPSCTL_TEST_IPERF3_UNINSTALL:-0}" == 1 ]] || continue ;;
    esac
    # This optional path checks self-deletion through the installed CLI. It must
    # not remove a pre-existing service or change real firewall rules.
    feature_paths=(
        "/etc/systemd/system/vpsctl-${cache_feature}.service"
        "/etc/init.d/vpsctl-${cache_feature}"
        "/var/lib/vpsctl/service/${cache_feature}"
        "/var/lib/vpsctl/service/${cache_feature}/state.json"
        "/var/log/vpsctl/${cache_feature}.log"
        "/run/vpsctl-${cache_feature}.pid"
    )
    if [[ "$cache_feature" == tcping ]]; then
        feature_paths+=(/usr/local/libexec/vpsctl/tcping /usr/local/libexec/vpsctl/tcping/listener.py /run/vpsctl/tcping-ready.json)
    else
        feature_paths+=(/run/vpsctl/iperf3.pid)
    fi
    for path in "${feature_paths[@]}"; do
        [[ ! -e "$path" && ! -L "$path" ]] || fail "pre-existing $cache_feature service blocks cache eviction acceptance: $path"
    done
    if command -v systemctl >/dev/null 2>&1 &&
        { systemctl is-active --quiet "vpsctl-${cache_feature}.service" || systemctl is-enabled --quiet "vpsctl-${cache_feature}.service"; }; then
        fail "pre-existing $cache_feature systemd service blocks cache eviction acceptance"
    fi
    snapshot_feature_cache_ufw
    cat >"$MOCK_BIN/ufw" <<'MOCK_UFW'
#!/usr/bin/env bash
[[ "$#" == 1 && "$1" == status ]] || exit 89
printf 'Status: inactive\n'
MOCK_UFW
    chmod 0755 "$MOCK_BIN/ufw"
    feature_release_hashes >"$TEST_TEMP/${cache_feature}-release-before.sha256"
    awk -v feature="$cache_feature" '$2 != "./.bundles/service-" feature ".sha256" &&
         $2 != "./commands/service/" feature ".sh" &&
         $2 != "./commands/service/" feature "/listener.py"' \
        "$TEST_TEMP/${cache_feature}-release-before.sha256" >"$TEST_TEMP/${cache_feature}-release-expected-after.sha256"
    : >"$VPSCTL_TEST_DOWNLOAD_TRACE"
    VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" --yes --non-interactive service "$cache_feature" uninstall \
        >"$TEST_TEMP/${cache_feature}-uninstall.log" || fail "installed $cache_feature uninstall failed"
    [[ ! -s "$VPSCTL_TEST_DOWNLOAD_TRACE" ]] || fail "installed $cache_feature uninstall contacted the network"
    [[ ! -e "$release_root/.bundles/service-${cache_feature}.sha256" &&
       ! -e "$release_root/commands/service/${cache_feature}.sh" &&
       ! -e "$release_root/commands/service/${cache_feature}" &&
       ! -e "$release_root/.bundles/.service-${cache_feature}.lock" ]] || fail "installed $cache_feature uninstall retained feature cache"
    [[ -d "$release_root/commands/service" ]] || fail "installed $cache_feature uninstall removed the service domain"
    for path in "${feature_paths[@]}"; do
        [[ ! -e "$path" && ! -L "$path" ]] || fail "installed $cache_feature uninstall left a runtime artifact: $path"
    done
    feature_release_hashes >"$TEST_TEMP/${cache_feature}-release-after.sha256"
    cmp -s -- "$TEST_TEMP/${cache_feature}-release-expected-after.sha256" "$TEST_TEMP/${cache_feature}-release-after.sha256" ||
        fail "installed $cache_feature uninstall changed other release files"
    restore_feature_cache_ufw || fail "shared UFW metadata restore failed after $cache_feature uninstall"
    rm -- "$MOCK_BIN/ufw"

    : >"$VPSCTL_TEST_DOWNLOAD_TRACE"
    PATH="$MOCK_BIN:$PATH" "$ENTRY" service "$cache_feature" help >/dev/null || fail "$cache_feature help did not re-download the evicted bundle"
    [[ "$(<"$VPSCTL_TEST_DOWNLOAD_TRACE")" == "vpsctl-service-${cache_feature}-${RELEASE_VERSION}.tar.gz" ]] ||
        fail "$cache_feature help downloaded more than its evicted feature bundle"
    feature_release_hashes >"$TEST_TEMP/${cache_feature}-release-restored.sha256"
    cmp -s -- "$TEST_TEMP/${cache_feature}-release-before.sha256" "$TEST_TEMP/${cache_feature}-release-restored.sha256" ||
        fail "$cache_feature feature cache was not restored exactly after re-download"
done

rm -- "$SELF_ROOT/vpsctl.sh"
printf 'corrupt cache\n' >"$SELF_ROOT/manifest.tsv"
PATH="$MOCK_BIN:$PATH" "$ENTRY" --yes --non-interactive self update >/dev/null
cmp "$ENTRY" "$SELF_ROOT/vpsctl.sh" || fail 'same-version update did not repair cached launcher'
cmp "$release_root/.release/manifest.tsv" "$SELF_ROOT/manifest.tsv" || fail 'same-version update did not repair cached manifest'
su nobody -s /bin/bash -c "$ENTRY --version" | grep -Fx "vpsctl $RELEASE_VERSION" >/dev/null ||
    fail 'ordinary user could not execute the installed shortcut'

# Exercise a real version change, with a legacy core archive lacking execute
# permission. Same-version update above does not install or activate a new core.
NEXT_SOURCE="$TEST_TEMP/next-source"
NEXT_ASSETS="$TEST_TEMP/next-assets"
mkdir -p "$NEXT_SOURCE" "$NEXT_ASSETS"
cp -a -- "$TEST_ROOT/bin" "$TEST_ROOT/lib" "$TEST_ROOT/commands" \
    "$TEST_ROOT/scripts" "$TEST_ROOT/vpsctl.sh" "$NEXT_SOURCE/"
printf '%s\n' "$NEXT_VERSION" >"$NEXT_SOURCE/VERSION"
bash "$NEXT_SOURCE/scripts/build-release.sh" "$NEXT_ASSETS" >/dev/null
LEGACY_CORE="$TEST_TEMP/legacy-core"
mkdir -p "$LEGACY_CORE"
tar -xzf "$NEXT_ASSETS/vpsctl-core-${NEXT_VERSION}.tar.gz" -C "$LEGACY_CORE"
mkdir -p "$LEGACY_CORE/lib/nested"
printf '# update shared helper\n' >"$LEGACY_CORE/lib/nested/update-helper.sh"
chmod 0644 "$LEGACY_CORE/bin/vpsctl"
tar -C "$LEGACY_CORE" -czf "$NEXT_ASSETS/vpsctl-core-${NEXT_VERSION}.tar.gz" VERSION bin lib commands
core_sha="$(sha256sum "$NEXT_ASSETS/vpsctl-core-${NEXT_VERSION}.tar.gz" | awk '{print $1}')"
sed -i "s/^bundle\tcore\t.*/bundle\tcore\tvpsctl-core-${NEXT_VERSION}.tar.gz\t${core_sha}/" "$NEXT_ASSETS/vpsctl-manifest.tsv"
export VPSCTL_TEST_ASSET_DIR="$NEXT_ASSETS"
rm -rf -- "$SELF_ROOT"
: >"$VPSCTL_TEST_DOWNLOAD_TRACE"
PATH="$MOCK_BIN:$PATH" "$ENTRY" --yes --non-interactive self update --version "v$NEXT_VERSION" >/dev/null
[[ "$(sort "$VPSCTL_TEST_DOWNLOAD_TRACE")" == "$(printf '%s\n' vpsctl.sh vpsctl-manifest.tsv "vpsctl-core-${NEXT_VERSION}.tar.gz" | sort)" ]] ||
    fail 'cross-version update prefetched feature/shared bundles'
[[ -f "$INSTALL_ROOT/current/lib/nested/update-helper.sh" ]] || fail 'update rejected new shared library'
cmp "$ENTRY" "$SELF_ROOT/vpsctl.sh" || fail 'versioned update did not restore cached launcher'
[[ "$(readlink -f "$INSTALL_ROOT/current")" == "$INSTALL_ROOT/releases/$NEXT_VERSION" ]] || fail 'versioned update did not switch current'
[[ ! -e "$release_root" && ! -L "$release_root" ]] || fail 'versioned update retained the previous release'
[[ "$(find "$INSTALL_ROOT/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')" == "$NEXT_VERSION" ]] ||
    fail 'versioned update did not leave only the current release'
VPSCTL_TEST_CURL_FAIL=1 PATH="$MOCK_BIN:$PATH" "$ENTRY" --version | grep -Fx "vpsctl $NEXT_VERSION" >/dev/null ||
    fail 'updated shortcut could not run offline as root'
su nobody -s /bin/bash -c "$ENTRY --version" | grep -Fx "vpsctl $NEXT_VERSION" >/dev/null ||
    fail 'updated shortcut could not run as an ordinary user'
[[ "$(find "$INSTALL_ROOT/current/.bundles" -type f -printf '%f\n')" == core.sha256 ]] || fail 'update is not core-only'
[[ ! -e "$INSTALL_ROOT/current/commands/network" && ! -e "$INSTALL_ROOT/current/lib/command.sh" ]] ||
    fail 'update copied old feature code'
PATH="$MOCK_BIN:$PATH" "$ENTRY" network bbr --help >/dev/null
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
