#!/usr/bin/env bash
# Opt-in standard-path acceptance on the dedicated Debian/systemd test host.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
[[ "${VPSCTL_REAL_OFFLINE_SERVICES_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_OFFLINE_SERVICES_TEST=1 on the dedicated host\n'
    exit 0
}
((EUID == 0)) || { printf 'FAIL: requires root\n' >&2; exit 4; }
[[ -d /run/systemd/system ]] || { printf 'FAIL: requires real systemd\n' >&2; exit 3; }
PACKAGE="${VPSCTL_OFFLINE_PACKAGE:?set VPSCTL_OFFLINE_PACKAGE to the final offline tar.gz}"
[[ -f "$PACKAGE" && ! -L "$PACKAGE" ]] || { printf 'FAIL: package is not an ordinary file\n' >&2; exit 3; }
for tool in bash jq python3 sha256sum systemctl tar timeout iptables-save ip6tables-save apt-get; do
    command -v "$tool" >/dev/null || { printf 'FAIL: missing %s\n' "$tool" >&2; exit 3; }
done
# This focused host acceptance preserves its inactive firewall. Live UFW rule
# mutation is covered by the existing UFW acceptance, outside this test's scope.
[[ "$(LC_ALL=C ufw status | head -n 1)" == 'Status: inactive' ]] || {
    printf 'FAIL: this dedicated-host test requires the baseline UFW to be inactive\n' >&2
    exit 3
}
TEST_TEMP="$(mktemp -d /root/vpsctl-offline-services.XXXXXX)"
RESULT_DIR="${VPSCTL_OFFLINE_SERVICES_RESULT_DIR:-$TEST_TEMP/evidence}"
BACKUP="$TEST_TEMP/baseline"
mkdir -p -- "$BACKUP" "$RESULT_DIR" "$TEST_TEMP/no-network"
exec > >(tee -a "$RESULT_DIR/acceptance.log") 2>&1
printf 'package=%s\nrecovery=%s\n' "$PACKAGE" "$TEST_TEMP"
sha256sum "$PACKAGE" >"$RESULT_DIR/package.sha256"
cat "$RESULT_DIR/package.sha256"
date --iso-8601=seconds
df -m /
dpkg-query -W >"$RESULT_DIR/packages-before.tsv"
UNITS=(vpsctl-proxy-forward.service vpsctl-proxy-xray.service vpsctl-proxy-sing-box.service vpsctl-tcping.service vpsctl-iperf3.service iperf3.service)
declare -A ACTIVE=() ENABLED=()
for unit in "${UNITS[@]}"; do
    ACTIVE[$unit]="$(systemctl is-active "$unit" 2>/dev/null || true)"
    ENABLED[$unit]="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    printf '%s\t%s\t%s\n' "$unit" "${ACTIVE[$unit]}" "${ENABLED[$unit]}" >>"$RESULT_DIR/services-before.tsv"
done
MOVE_PATHS=(
    /usr/local/bin/vpsctl /usr/local/lib/vpsctl /var/lib/vpsctl/self
    /etc/vpsctl/proxy /var/lib/vpsctl/service/proxy /var/lib/vpsctl/backups/service/proxy /var/log/vpsctl/proxy
    /usr/local/bin/xray /usr/local/bin/sing-box
    /usr/local/libexec/vpsctl-proxy-runtime /usr/local/libexec/vpsctl-proxy-forward-refresh
    /var/lib/vpsctl/service/tcping /usr/local/libexec/vpsctl/tcping /var/log/vpsctl/tcping.log
    /run/vpsctl/tcping-ready.json /run/vpsctl-tcping.pid
    /var/lib/vpsctl/service/iperf3 /var/log/vpsctl/iperf3.log /run/vpsctl/iperf3.pid /run/vpsctl-iperf3.pid
    /var/lib/vpsctl/network/ufw /run/vpsctl/network-ufw.lock
    /run/vpsctl/proxy.lock /run/vpsctl/tcping.lock /run/vpsctl/iperf3.lock
    /var/cache/apt/archives
)
for unit in "${UNITS[@]}"; do
    [[ "$unit" != iperf3.service ]] || continue
    MOVE_PATHS+=("/etc/systemd/system/$unit" "/etc/systemd/system/$unit.d" "/etc/systemd/system/multi-user.target.wants/$unit")
done
COPY_PATHS=(/etc/ufw /etc/default/ufw)
MOVED_PATHS=()
BASELINE_READY=0
MUTATED=0
ORIGINAL_PATH="$PATH"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
path_snapshot() {
    local path
    for path in "${MOVE_PATHS[@]}" "${COPY_PATHS[@]}"; do
        if [[ -e "$path" || -L "$path" ]]; then
            find "$path" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
            find "$path" -printf '%m %y %p %l\n' | LC_ALL=C sort
        else printf 'ABSENT %s\n' "$path"; fi
    done
}
firewall_snapshot() {
    iptables-save | sed '/^#/d;s/\[[0-9]*:[0-9]*\]/[0:0]/g'
    ip6tables-save | sed '/^#/d;s/\[[0-9]*:[0-9]*\]/[0:0]/g'
}
cleanup() {
    local result=$? restored=0 path unit
    trap - EXIT HUP INT TERM
    export PATH="$ORIGINAL_PATH"
    if ((MUTATED)); then
        for unit in "${UNITS[@]}"; do
            if [[ "$(systemctl show -p LoadState --value "$unit")" != not-found ]]; then
                systemctl stop "$unit" >/dev/null 2>&1 || restored=1
            fi
            [[ "$unit" == iperf3.service ]] || systemctl disable "$unit" >/dev/null 2>&1 || true
        done
        if ((BASELINE_READY)); then
            for path in "${MOVE_PATHS[@]}"; do rm -rf -- "$path" || restored=1; done
            for path in "${MOVE_PATHS[@]}"; do
                if [[ -e "$BACKUP$path" || -L "$BACKUP$path" ]]; then
                    mkdir -p -- "${path%/*}" && mv -- "$BACKUP$path" "$path" || restored=1
                fi
            done
            for path in "${COPY_PATHS[@]}"; do
                rm -rf -- "$path" || restored=1
                if [[ -e "$BACKUP$path" || -L "$BACKUP$path" ]]; then
                    mkdir -p -- "${path%/*}" && cp -a -- "$BACKUP$path" "$path" || restored=1
                fi
            done
            path_snapshot >"$RESULT_DIR/paths-after-restore.txt"
            cmp -s "$RESULT_DIR/paths-before.txt" "$RESULT_DIR/paths-after-restore.txt" || restored=1
        else
            # Snapshot staging interrupted: restore only entries already moved.
            for path in "${MOVED_PATHS[@]}"; do
                mkdir -p -- "${path%/*}" && mv -- "$BACKUP$path" "$path" || restored=1
            done
        fi
        systemctl daemon-reload || restored=1
        for unit in "${UNITS[@]}"; do
            systemctl reset-failed "$unit" >/dev/null 2>&1 || true
            case "${ENABLED[$unit]}" in
                enabled) systemctl enable "$unit" >/dev/null 2>&1 || restored=1 ;;
                disabled) systemctl disable "$unit" >/dev/null 2>&1 || restored=1 ;;
                masked | static | not-found | '') ;;
                *) printf 'FAIL: unsupported original enablement %s %s\n' "$unit" "${ENABLED[$unit]}"; restored=1 ;;
            esac
        done
        for unit in "${UNITS[@]}"; do
            if [[ "${ACTIVE[$unit]}" == active ]]; then systemctl start "$unit" || restored=1; fi
        done
        for unit in "${UNITS[@]}"; do
            actual_active="$(systemctl is-active "$unit" 2>/dev/null || true)"
            actual_enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
            printf '%s\t%s\t%s\n' "$unit" "$actual_active" "$actual_enabled" >>"$RESULT_DIR/services-after.tsv"
            [[ "$actual_active" == "${ACTIVE[$unit]}" && "$actual_enabled" == "${ENABLED[$unit]}" ]] || restored=1
        done
        firewall_snapshot >"$RESULT_DIR/firewall-after.txt"
        cmp -s "$RESULT_DIR/firewall-before.txt" "$RESULT_DIR/firewall-after.txt" || restored=1
        [[ "$(LC_ALL=C ufw status | head -n 1)" == 'Status: inactive' ]] || restored=1
    fi
    dpkg-query -W >"$RESULT_DIR/packages-after.tsv"
    diff -u "$RESULT_DIR/packages-before.tsv" "$RESULT_DIR/packages-after.tsv" >"$RESULT_DIR/package-changes.diff" || true
    if ((restored)); then
        printf 'FAIL: baseline restoration incomplete; preserve recovery=%s evidence=%s\n' "$TEST_TEMP" "$RESULT_DIR"
        result=30
    else
        printf 'PASS: original files, service active/enabled states and firewall rules restored\n'
        rm -rf -- "$BACKUP" "$TEST_TEMP/source" "$TEST_TEMP/no-network"
    fi
    printf 'evidence=%s\n' "$RESULT_DIR"
    df -m /
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
firewall_snapshot >"$RESULT_DIR/firewall-before.txt"
MUTATED=1
# Stop the forward refresher before moving any of the state it reads.
for unit in "${UNITS[@]}"; do
    if [[ "${ACTIVE[$unit]}" == active ]]; then systemctl stop "$unit"; fi
done
path_snapshot >"$RESULT_DIR/paths-before.txt"
for path in "${COPY_PATHS[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then mkdir -p -- "${BACKUP}${path%/*}"; cp -a -- "$path" "$BACKUP$path"; fi
done
for path in "${MOVE_PATHS[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
        mkdir -p -- "${BACKUP}${path%/*}"
        mv -- "$path" "$BACKUP$path"
        MOVED_PATHS+=("$path")
    fi
done
BASELINE_READY=1
systemctl daemon-reload
mkdir -p /var/cache/apt/archives/partial

export VPSCTL_OFFLINE_DOWNLOAD_TRACE="$RESULT_DIR/download-calls.txt"
export VPSCTL_OFFLINE_APT_TRACE="$RESULT_DIR/apt-calls.txt"
VPSCTL_OFFLINE_REAL_APT="$(command -v apt-get)"
export VPSCTL_OFFLINE_REAL_APT
: >"$VPSCTL_OFFLINE_DOWNLOAD_TRACE"
: >"$VPSCTL_OFFLINE_APT_TRACE"
cat >"$TEST_TEMP/no-network/curl" <<'NETWORK'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"${VPSCTL_OFFLINE_DOWNLOAD_TRACE:?}"
exit 97
NETWORK
cp -- "$TEST_TEMP/no-network/curl" "$TEST_TEMP/no-network/wget"
cat >"$TEST_TEMP/no-network/apt-get" <<'APT'
#!/usr/bin/env bash
printf '%q ' "$@" >>"${VPSCTL_OFFLINE_APT_TRACE:?}"
printf '\n' >>"$VPSCTL_OFFLINE_APT_TRACE"
for argument in "$@"; do
    if [[ "$argument" == Dir::Etc::sourcelist=* ]]; then cat "${argument#*=}" >>"$VPSCTL_OFFLINE_APT_TRACE"; fi
done
exec "${VPSCTL_OFFLINE_REAL_APT:?}" "$@"
APT
chmod 0755 "$TEST_TEMP/no-network/"*
export PATH="$TEST_TEMP/no-network:$ORIGINAL_PATH"
unset VPSCTL_TESTING VPSCTL_SYSTEM_ROOT VPSCTL_PROJECT_ROOT VPSCTL_INSTALL_ROOT VPSCTL_SELF_STATE_ROOT VPSCTL_MANAGED_ENTRY VPSCTL_DISTRIBUTED
mkdir -p "$TEST_TEMP/source"
tar -xzf "$PACKAGE" -C "$TEST_TEMP/source"
bash "$TEST_TEMP/source/vpsctl.sh" --offline-dir "$TEST_TEMP/source" --version >"$RESULT_DIR/import.log"
rm -rf -- "$TEST_TEMP/source"
printf 'PASS: final offline package imported; extracted source deleted\n'
printf 'IMPORT_READY\n'
vpsctl() { /usr/local/bin/vpsctl --no-color --yes --non-interactive --install-deps "$@"; }
RELEASE="$(readlink -f /usr/local/lib/vpsctl/current)"
cp -- "$RELEASE/.offline/components.tsv" "$RESULT_DIR/components.tsv"
sha256sum "$RELEASE/.release/manifest.tsv" >"$RESULT_DIR/installed-manifest.sha256"
[[ ! -e /usr/local/bin/xray && ! -e /usr/local/bin/sing-box ]] || fail 'external baseline binaries were not stashed'
for core in xray sing-box; do
    vpsctl service proxy install --core "$core" >"$RESULT_DIR/$core-install.log" 2>&1
    systemctl is-active --quiet "vpsctl-proxy-$core.service" || fail "$core service is inactive"
    systemctl is-enabled --quiet "vpsctl-proxy-$core.service" || fail "$core service is disabled"
    tag="$(awk -F '\t' -v core="$core" '$2==core {print $3}' "$RESULT_DIR/components.tsv")"
    jq -e --arg core "$core" --arg tag "$tag" '.owned==true and .core==$core and .release_tag==$tag and .version==($tag|ltrimstr("v"))' \
        "/var/lib/vpsctl/service/proxy/cores/$core.json" >/dev/null || fail "$core installation did not use packaged version"
    "/usr/local/bin/$core" version >"$RESULT_DIR/$core-version.txt"
    case "$core" in
        xray) /usr/local/bin/xray run -test -config /etc/vpsctl/proxy/xray/config.json >"$RESULT_DIR/xray-config-check.log" 2>&1 ;;
        sing-box) /usr/local/bin/sing-box check -c /etc/vpsctl/proxy/sing-box/config.json >"$RESULT_DIR/sing-box-config-check.log" 2>&1 ;;
    esac
    printf 'PASS: packaged %s %s installed, configuration checked, service active/enabled\n' "$core" "$tag"
done
vpsctl service proxy status --core all --json >"$RESULT_DIR/proxy-status.json"
jq -e '(.cores|length)==2 and all(.cores[]; .installed and .running and .enabled and .source=="vpsctl")' "$RESULT_DIR/proxy-status.json" >/dev/null

free_port() {
    python3 -B - <<'PY'
import socket
with socket.socket() as connection:
    connection.bind(("127.0.0.1", 0))
    print(connection.getsockname()[1])
PY
}
tcping_port="$(free_port)"
vpsctl service tcping start --port "$tcping_port" >"$RESULT_DIR/tcping-start.log" 2>&1
systemctl is-active --quiet vpsctl-tcping.service
systemctl is-enabled --quiet vpsctl-tcping.service
python3 -B - "$tcping_port" <<'PY'
import socket, sys
for _ in range(4):
    with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3) as connection:
        assert connection.recv(1) == b"", "TCPing must close the accepted connection"
PY
vpsctl service tcping stop >"$RESULT_DIR/tcping-stop.log" 2>&1
! systemctl is-active --quiet vpsctl-tcping.service || fail 'TCPing stop left service active'
vpsctl service tcping uninstall >"$RESULT_DIR/tcping-uninstall.log" 2>&1
[[ ! -e "$RELEASE/commands/service/tcping.sh" && ! -e "$RELEASE/.bundles/service-tcping.sha256" ]] || fail 'TCPing uninstall retained feature cache'
vpsctl service tcping --help >"$RESULT_DIR/tcping-reload.log" 2>&1
[[ -f "$RELEASE/commands/service/tcping.sh" && -f "$RELEASE/.bundles/service-tcping.sha256" ]] || fail 'TCPing local feature cache did not recover'
printf 'PASS: TCPing start, four local connects, stop, uninstall and local cache recovery\n'

iperf_port="$(free_port)"
vpsctl service iperf3 start --port "$iperf_port" >"$RESULT_DIR/iperf3-start.log" 2>&1
systemctl is-active --quiet vpsctl-iperf3.service
systemctl is-enabled --quiet vpsctl-iperf3.service
timeout 15 iperf3 -c 127.0.0.1 -p "$iperf_port" -t 1 -b 10M -J >"$RESULT_DIR/iperf3-client.json"
jq -e 'has("error")|not' "$RESULT_DIR/iperf3-client.json" >/dev/null
jq -e '.end.sum_received.bytes>0' "$RESULT_DIR/iperf3-client.json" >/dev/null
vpsctl service iperf3 update >"$RESULT_DIR/iperf3-update.log" 2>&1
systemctl is-active --quiet vpsctl-iperf3.service || fail 'iperf3 update did not restore active service'
systemctl is-enabled --quiet vpsctl-iperf3.service || fail 'iperf3 update changed autostart'
grep -q 'deb \[trusted=yes\] file:' "$VPSCTL_OFFLINE_APT_TRACE" || fail 'iperf3 update did not use the local APT repository'
pool_hashes() (cd "$RELEASE/.offline/apt/pool"; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
pool_hashes >"$RESULT_DIR/apt-pool-before-clean.sha256"
apt-get clean
pool_hashes >"$RESULT_DIR/apt-pool-after-clean.sha256"
cmp -s "$RESULT_DIR/apt-pool-before-clean.sha256" "$RESULT_DIR/apt-pool-after-clean.sha256" || fail 'APT cache clean changed retained local packages'
vpsctl service iperf3 stop >"$RESULT_DIR/iperf3-stop.log" 2>&1
! systemctl is-active --quiet vpsctl-iperf3.service || fail 'iperf3 stop left service active'
vpsctl service iperf3 uninstall >"$RESULT_DIR/iperf3-uninstall.log" 2>&1
[[ ! -e "$RELEASE/commands/service/iperf3.sh" && ! -e "$RELEASE/.bundles/service-iperf3.sha256" ]] || fail 'iperf3 uninstall retained feature cache'
printf 'PASS: iperf3 start, local throughput, local APT update, cache clean, stop and uninstall\n'
[[ ! -s "$VPSCTL_OFFLINE_DOWNLOAD_TRACE" ]] || fail 'a project operation called curl/wget'
printf 'PASS: no project curl/wget calls during actual offline services acceptance\n'
printf 'PASS: actual offline services acceptance\n'
