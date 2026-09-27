#!/usr/bin/env bash
# Opt-in destructive acceptance for proxy installation on host-vps-scripts.
# It uses the host's real external Xray and sing-box binaries, real systemd
# units, and an empty node manifest. Original proxy files and service states
# are restored on every exit path.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT

[[ "${VPSCTL_REAL_PROXY_INSTALL_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_PROXY_INSTALL_TEST=1 on the dedicated host\n'
    exit 0
}
((EUID == 0)) || { printf 'FAIL: real proxy install acceptance requires root\n' >&2; exit 4; }

for tool in awk bash basename chmod cmp date dirname find flock grep jq mkdir mktemp mv ps readlink rm sha256sum sort stat systemctl tar tee xargs; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'FAIL: missing %s\n' "$tool" >&2; exit 3; }
done

. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" == 13 ]] || {
    printf 'FAIL: this recorded acceptance is restricted to Debian 13\n' >&2
    exit 3
}
[[ "$(ps -p 1 -o comm=)" == systemd ]] || {
    printf 'FAIL: this acceptance requires systemd as PID 1\n' >&2
    exit 3
}

exec 9>/run/lock/vpsctl-proxy-install-real.lock
flock -n 9 || { printf 'FAIL: another real proxy install acceptance is active\n' >&2; exit 3; }

RESULT_ROOT="${VPSCTL_PROXY_INSTALL_RESULT_DIR:-/var/tmp/vpsctl-proxy-install-results}"
[[ "$RESULT_ROOT" == /var/tmp/* && ! -L "$RESULT_ROOT" ]] || {
    printf 'FAIL: result directory must be a non-symlink below /var/tmp\n' >&2
    exit 3
}
mkdir -p -- "$RESULT_ROOT"
chmod 0700 -- "$RESULT_ROOT"
RUN_DIR="$(mktemp -d "${RESULT_ROOT%/}/run.XXXXXX")"
readonly RUN_DIR
BASELINE="${RUN_DIR}/baseline"
LOG_DIR="${RUN_DIR}/logs"
mkdir -p -- "$BASELINE/stash" "$LOG_DIR"
RESULT_LOG="${LOG_DIR}/proxy-install-real.log"
: >"$RESULT_LOG"
exec > >(tee -a "$RESULT_LOG") 2>&1

readonly -a CORE_UNITS=(vpsctl-proxy-sing-box.service vpsctl-proxy-xray.service)
readonly -a CORES=(sing-box xray)
readonly -a STASH_PATHS=(
    /etc/vpsctl/proxy
    /var/lib/vpsctl/service/proxy
    /var/lib/vpsctl/backups/service/proxy
    /var/log/vpsctl/proxy
    /etc/systemd/system/vpsctl-proxy-sing-box.service
    /etc/systemd/system/vpsctl-proxy-xray.service
)
readonly -a STASH_LABELS=(etc-proxy state-proxy backups-proxy log-proxy unit-sing-box unit-xray)
readonly -a AUDIT_PATHS=(
    /etc/vpsctl/proxy
    /var/lib/vpsctl/service/proxy
    /var/lib/vpsctl/backups/service/proxy
    /var/log/vpsctl/proxy
    /etc/systemd/system/vpsctl-proxy-sing-box.service
    /etc/systemd/system/vpsctl-proxy-xray.service
    /etc/systemd/system/vpsctl-proxy-forward.service
    /usr/local/bin/sing-box
    /usr/local/bin/xray
)

UNIT_NAMES=()
MUTATION_STARTED=0
STASH_STARTED=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

vpsctl() {
    bash "$TEST_ROOT/bin/vpsctl" --no-color --non-interactive --yes "$@"
}

add_unit() {
    local candidate="$1" current
    [[ "$candidate" =~ ^vpsctl-proxy-(sing-box|xray|forward[-A-Za-z0-9_.@]*)\.(service|timer)$ ]] || return 0
    for current in "${UNIT_NAMES[@]:-}"; do [[ "$current" != "$candidate" ]] || return 0; done
    UNIT_NAMES+=("$candidate")
}

discover_units() {
    local unit
    add_unit vpsctl-proxy-sing-box.service
    add_unit vpsctl-proxy-xray.service
    while IFS= read -r unit; do
        [[ -n "$unit" ]] && add_unit "$unit"
    done < <(systemctl list-unit-files --no-legend --no-pager 'vpsctl-proxy-forward*' 2>/dev/null | awk '{print $1}')
}

unit_value() {
    local action="$1" unit="$2" value
    value="$(systemctl "$action" "$unit" 2>/dev/null || true)"
    [[ -n "$value" ]] || value=not-found
    printf '%s' "$value"
}

snapshot_unit_states() {
    local output="$1" unit load active enabled
    : >"$output"
    for unit in "${UNIT_NAMES[@]}"; do
        load="$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)"
        [[ -n "$load" ]] || load=not-found
        active="$(unit_value is-active "$unit")"
        enabled="$(unit_value is-enabled "$unit")"
        printf '%s\t%s\t%s\t%s\n' "$unit" "$load" "$active" "$enabled" >>"$output"
    done
}

validate_baseline_unit_states() {
    local unit load active enabled
    while IFS=$'\t' read -r unit load active enabled; do
        [[ -n "$unit" ]] || continue
        [[ "$load" == loaded ]] || fail "$unit is not loaded at baseline"
        case "$active" in active | inactive) ;; *) fail "unsupported baseline activity state $active for $unit" ;; esac
        case "$enabled" in
            enabled | enabled-runtime | disabled | static | indirect | generated | transient) ;;
            *) fail "unsupported baseline enablement state $enabled for $unit" ;;
        esac
    done <"$BASELINE/unit-states.before.tsv"
}

fingerprint_path() {
    local path="$1" kind mode uid gid size digest parent base target
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        printf '%s\tabsent\n' "$path"
        return 0
    fi
    kind="$(stat -c %F -- "$path")"
    mode="$(stat -c %a -- "$path")"
    uid="$(stat -c %u -- "$path")"
    gid="$(stat -c %g -- "$path")"
    size="$(stat -c %s -- "$path")"
    case "$kind" in
        'regular file') digest="$(sha256sum -- "$path" | awk '{print $1}')" ;;
        'symbolic link')
            target="$(readlink -- "$path")"
            digest="$(printf '%s' "$target" | sha256sum | awk '{print $1}')"
            ;;
        directory)
            parent="$(dirname -- "$path")"
            base="$(basename -- "$path")"
            digest="$(tar --sort=name --format=gnu --mtime=@0 --numeric-owner -C "$parent" -cf - "$base" | sha256sum | awk '{print $1}')"
            ;;
        *) digest=not-applicable ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$kind" "$mode" "$uid" "$gid" "$size" "$digest"
}

snapshot_audit_paths() {
    local output="$1" path
    : >"$output"
    for path in "${AUDIT_PATHS[@]}"; do fingerprint_path "$path" >>"$output"; done
}

quiesce_units() {
    local index unit enabled
    for ((index = ${#UNIT_NAMES[@]} - 1; index >= 0; index--)); do
        unit="${UNIT_NAMES[$index]}"
        systemctl stop "$unit" >/dev/null 2>&1 || true
        enabled="$(unit_value is-enabled "$unit")"
        case "$enabled" in
            enabled | enabled-runtime | linked | linked-runtime)
                systemctl disable "$unit" >/dev/null
                ;;
        esac
    done
}

stash_baseline_paths() {
    local index path label device parent_device
    device="$(stat -c %d -- "$RUN_DIR")"
    for path in "${STASH_PATHS[@]}"; do
        parent_device="$(stat -c %d -- "$(dirname -- "$path")")"
        [[ "$device" == "$parent_device" ]] || fail "baseline stash is not on the same filesystem as $path"
    done
    for ((index = 0; index < ${#STASH_PATHS[@]}; index++)); do
        path="${STASH_PATHS[$index]}"
        label="${STASH_LABELS[$index]}"
        if [[ -e "$path" || -L "$path" ]]; then
            : >"$BASELINE/stash/$label.original-present"
        else
            : >"$BASELINE/stash/$label.original-absent"
        fi
    done
    STASH_STARTED=1
    for ((index = 0; index < ${#STASH_PATHS[@]}; index++)); do
        path="${STASH_PATHS[$index]}"
        label="${STASH_LABELS[$index]}"
        if [[ -f "$BASELINE/stash/$label.original-present" ]]; then
            mv -- "$path" "$BASELINE/stash/$label"
            : >"$BASELINE/stash/$label.stashed"
        fi
    done
}

restore_stashed_paths() {
    local index path label
    for ((index = 0; index < ${#STASH_PATHS[@]}; index++)); do
        path="${STASH_PATHS[$index]}"
        label="${STASH_LABELS[$index]}"
        case "$path" in
            /etc/vpsctl/proxy | /var/lib/vpsctl/service/proxy | /var/lib/vpsctl/backups/service/proxy | \
                /var/log/vpsctl/proxy | /etc/systemd/system/vpsctl-proxy-sing-box.service | \
                /etc/systemd/system/vpsctl-proxy-xray.service) ;;
            *) return 1 ;;
        esac
        if [[ -f "$BASELINE/stash/$label.stashed" ]]; then
            rm -rf -- "$path"
            mkdir -p -- "$(dirname -- "$path")"
            mv -- "$BASELINE/stash/$label" "$path" || return 1
        elif [[ -f "$BASELINE/stash/$label.original-absent" ]]; then
            rm -rf -- "$path"
        fi
    done
}

restore_unit_states() {
    local unit load active enabled
    while IFS=$'\t' read -r unit load active enabled; do
        [[ -n "$unit" ]] || continue
        case "$enabled" in
            enabled) systemctl enable "$unit" >/dev/null || return 1 ;;
            enabled-runtime) systemctl enable --runtime "$unit" >/dev/null || return 1 ;;
            disabled) systemctl disable "$unit" >/dev/null 2>&1 || true ;;
            static | indirect | generated | transient | not-found) ;;
            *) printf 'FAIL: unsupported baseline enablement state %s for %s\n' "$enabled" "$unit" >&2; return 1 ;;
        esac
        case "$active" in
            active) systemctl start "$unit" >/dev/null || return 1 ;;
            inactive) systemctl stop "$unit" >/dev/null 2>&1 || true ;;
            *) printf 'FAIL: unsupported baseline activity state %s for %s\n' "$active" "$unit" >&2; return 1 ;;
        esac
    done <"$BASELINE/unit-states.before.tsv"
}

cleanup() {
    local original_status=$? cleanup_status=0 unit
    trap - EXIT HUP INT TERM
    if ((MUTATION_STARTED == 1)); then
        for unit in "${UNIT_NAMES[@]}"; do
            systemctl stop "$unit" >/dev/null 2>&1 || true
            systemctl disable "$unit" >/dev/null 2>&1 || true
        done
        if ((STASH_STARTED == 1)); then
            restore_stashed_paths || cleanup_status=1
        fi
        systemctl daemon-reload >/dev/null 2>&1 || cleanup_status=1
        if ((cleanup_status == 0)); then
            snapshot_audit_paths "$BASELINE/paths.restored.tsv" || cleanup_status=1
            cmp -s "$BASELINE/paths.before.tsv" "$BASELINE/paths.restored.tsv" || cleanup_status=1
        fi
        restore_unit_states || cleanup_status=1
        snapshot_unit_states "$BASELINE/unit-states.restored.tsv" || cleanup_status=1
        cmp -s "$BASELINE/unit-states.before.tsv" "$BASELINE/unit-states.restored.tsv" || cleanup_status=1
    fi
    if ((cleanup_status == 0)); then
        if ((MUTATION_STARTED == 1)); then
            printf 'PASS: original proxy files, binary digests, and service boot/runtime states restored\n'
        else
            printf 'PASS: preflight exited before global proxy state changed\n'
        fi
        rm -rf -- "$BASELINE/stash"
    else
        printf 'FAIL: cleanup did not reproduce the proxy baseline; private recovery files retained at %s\n' "$BASELINE/stash" >&2
    fi
    printf 'Evidence: %s\n' "$RUN_DIR"
    ((original_status != 0)) || original_status=$((cleanup_status == 0 ? 0 : 30))
    exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

assert_core_installed() {
    local core="$1" unit binary config meta lkg pid executable
    unit="vpsctl-proxy-${core}.service"
    binary="/usr/local/bin/${core}"
    config="/etc/vpsctl/proxy/${core}/config.json"
    meta="/var/lib/vpsctl/service/proxy/cores/${core}.json"
    lkg="/var/lib/vpsctl/service/proxy/lkg/${core}"

    [[ -x "$binary" && ! -L "$binary" ]] || fail "$core external binary is unavailable"
    [[ -f "$config" && ! -L "$config" ]] || fail "$core config was not created"
    jq -e '.inbounds == []' "$config" >/dev/null || fail "$core empty-node config has inbounds"
    jq -e --arg core "$core" --arg binary "$binary" --arg service "vpsctl-proxy-${core}" '
        .schema_version == 1 and .core == $core and .binary == $binary and
        .owned == false and .service == $service and (.version | type == "string" and length > 0) and
        (.sha256 | test("^[0-9a-f]{64}$"))
    ' "$meta" >/dev/null || fail "$core metadata does not describe the external binary"
    [[ "$(jq -r '.sha256' "$meta")" == "$(sha256sum "$binary" | awk '{print $1}')" ]] || fail "$core metadata digest differs from the executable"

    systemctl is-active --quiet "$unit" || fail "$core service is not active after install"
    systemctl is-enabled --quiet "$unit" || fail "$core service is not enabled after install"
    [[ "$(systemctl show "$unit" -p FragmentPath --value)" == "/etc/systemd/system/$unit" ]] || fail "$core loaded an unexpected unit file"
    pid="$(systemctl show "$unit" -p MainPID --value)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "$core service has no real MainPID"
    executable="$(readlink -f -- "/proc/$pid/exe")"
    [[ "$executable" == "$binary" ]] || fail "$core MainPID is not the expected real executable"

    [[ -f "$lkg/config.json" && -f "$lkg/nodes.json" && -f "$lkg/core.json" && -f "$lkg/binary" ]] || fail "$core LKG is incomplete"
    cmp -s "$config" "$lkg/config.json" || fail "$core LKG config differs from installed config"
    cmp -s /var/lib/vpsctl/service/proxy/nodes.json "$lkg/nodes.json" || fail "$core LKG node manifest differs"
    cmp -s "$meta" "$lkg/core.json" || fail "$core LKG metadata differs"
    [[ "$(sha256sum "$lkg/binary" | awk '{print $1}')" == "$(sha256sum "$binary" | awk '{print $1}')" ]] || fail "$core LKG binary digest differs"
    printf 'PASS: %s real process active, enabled, empty-configured, externally owned, and saved as LKG\n' "$core"
}

snapshot_candidate_state() {
    local output="$1" path
    : >"$output"
    for path in \
        /etc/vpsctl/proxy \
        /var/lib/vpsctl/service/proxy \
        /var/lib/vpsctl/backups/service/proxy \
        /var/log/vpsctl/proxy \
        /etc/systemd/system/vpsctl-proxy-sing-box.service \
        /etc/systemd/system/vpsctl-proxy-xray.service \
        /usr/local/bin/sing-box \
        /usr/local/bin/xray; do
        fingerprint_path "$path" >>"$output"
    done
}

printf 'proxy-install-real utc=%s\n' "$(date -u +%FT%TZ)"
printf 'source=%s\n' "$TEST_ROOT"
find "$TEST_ROOT" -type f -not -path '*/.git/*' -print0 |
    sort -z | xargs -0 sha256sum | sha256sum | awk '{print "source_sha256=" $1}' | tee "$RUN_DIR/source-fingerprint.txt"

discover_units
snapshot_unit_states "$BASELINE/unit-states.before.tsv"
validate_baseline_unit_states
grep -F $'vpsctl-proxy-xray.service\tloaded\tactive\tenabled' "$BASELINE/unit-states.before.tsv" >/dev/null ||
    fail 'expected baseline Xray service to be active and enabled'
grep -F $'vpsctl-proxy-sing-box.service\tloaded\tinactive\tdisabled' "$BASELINE/unit-states.before.tsv" >/dev/null ||
    fail 'expected baseline sing-box service to be inactive and disabled'
for core in "${CORES[@]}"; do
    [[ -x "/usr/local/bin/$core" && ! -L "/usr/local/bin/$core" ]] || fail "missing real external $core binary"
done

MUTATION_STARTED=1
quiesce_units
for unit in "${UNIT_NAMES[@]}"; do
    ! systemctl is-active --quiet "$unit" || fail "$unit remained active after baseline quiesce"
    ! systemctl is-enabled --quiet "$unit" || fail "$unit remained enabled before install"
done
snapshot_audit_paths "$BASELINE/paths.before.tsv"
stash_baseline_paths
systemctl daemon-reload

vpsctl service proxy install --core all 2>&1 | tee "$LOG_DIR/first-install.log"
jq -e '.schema_version == 1 and .nodes == []' /var/lib/vpsctl/service/proxy/nodes.json >/dev/null ||
    fail 'install did not initialize an empty node manifest'
assert_core_installed sing-box
assert_core_installed xray
printf 'PASS: install --core all started and enabled both real systemd services\n'

for unit in "${CORE_UNITS[@]}"; do
    systemctl stop "$unit"
    systemctl disable "$unit" >/dev/null
done
snapshot_candidate_state "$RUN_DIR/candidate-before-noop.tsv"
vpsctl service proxy install --core all 2>&1 | tee "$LOG_DIR/repeated-install.log"
[[ "$(grep -Fc '已安装，无需更改' "$LOG_DIR/repeated-install.log")" == 2 ]] ||
    fail 'repeated install did not report both registered cores as unchanged'
for unit in "${CORE_UNITS[@]}"; do
    ! systemctl is-active --quiet "$unit" || fail "$unit was restarted by registered no-op install"
    ! systemctl is-enabled --quiet "$unit" || fail "$unit was re-enabled by registered no-op install"
done
snapshot_candidate_state "$RUN_DIR/candidate-after-noop.tsv"
cmp -s "$RUN_DIR/candidate-before-noop.tsv" "$RUN_DIR/candidate-after-noop.tsv" ||
    fail 'registered no-op install changed managed files or binaries'
printf 'PASS: repeated install preserved intentional inactive/disabled state and managed files\n'
printf 'PASS: proxy install real acceptance completed\n'
