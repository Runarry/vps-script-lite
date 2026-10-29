#!/usr/bin/env bash
# Opt-in native acceptance; run only via ssh host-vps-scripts.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2034
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ "${VPSCTL_REAL_CLEAN_TEST:-0}" == 1 ]] || {
    printf 'SKIP: set VPSCTL_REAL_CLEAN_TEST=1 on the dedicated test host\n'
    exit 0
}
((EUID == 0)) || exit 4
RESULT="${VPSCTL_CLEAN_RESULT_DIR:-}"
[[ "$RESULT" == /var/tmp/vpsctl-clean-accept.*/* && "$RESULT" != *'/../'* && "$RESULT" != *[[:space:]]* ]] || {
    printf 'FAIL: VPSCTL_CLEAN_RESULT_DIR must be under /var/tmp/vpsctl-clean-accept.*/\n' >&2
    exit 2
}
mkdir -p -- "$RESULT"
exec > >(tee -a "$RESULT/acceptance.log") 2>&1
TOKEN="vpsclean-accept-$$"
TMP_FIXTURE="/tmp/$TOKEN"
VAR_FIXTURE="/var/tmp/$TOKEN"
TMP_PROTECTED="/tmp/vpsctl-clean-accept-$$"
VAR_PROTECTED="/var/tmp/vpsctl-clean-protect-$$"
PID_TEXT="$$"
RULE="/run/tmpfiles.d/00-$TOKEN.conf"
APT_FIXTURE="/var/cache/apt/archives/$TOKEN.deb"
NATIVE_ENTRY="$TEST_ROOT/commands/system/clean.sh"
ROOTLESS=''

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
present() { [[ -f "$1" ]] || fail "missing preserved file: $1"; }
absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "unexpected retained file: $1"; }
native() {
    env -u VPSCTL_SYSTEM_ROOT -u VPSCTL_INSTALL_ROOT -u VPSCTL_SELF_STATE_ROOT \
        -u VPSCTL_MANAGED_ENTRY -u VPSCTL_PROJECT_ROOT -u VPSCTL_DISTRIBUTED \
        VPSCTL_TESTING=0 VPSCTL_DRY_RUN=0 VPSCTL_ASSUME_YES=0 \
        bash "$NATIVE_ENTRY" --no-color --non-interactive "$@"
}
tmpfiles_snapshot() {
    find /etc/tmpfiles.d /run/tmpfiles.d /usr/lib/tmpfiles.d -type f -exec sha256sum -- {} + | sort
}
cleanup() {
    local status=$?
    trap - EXIT
    rm -f -- "$RULE" "$APT_FIXTURE"
    rm -rf -- "$TMP_FIXTURE" "$VAR_FIXTURE" "$TMP_PROTECTED" "$VAR_PROTECTED"
    [[ -z "$ROOTLESS" ]] || rm -rf -- "$ROOTLESS"
    tmpfiles_snapshot >"$RESULT/tmpfiles.restored"
    if ! cmp -s "$RESULT/tmpfiles.before" "$RESULT/tmpfiles.restored"; then
        printf 'FAIL: tmpfiles configuration differs after fixture restoration\n' >&2
        status=1
    fi
    printf 'fixture_restoration_status=%s\n' "$status"
    exit "$status"
}

printf 'source=%s\n' "$TEST_ROOT"
sha256sum "$NATIVE_ENTRY" "$TEST_ROOT/lib/distribution.sh" >"$RESULT/source.sha256"
sed -n '/^ID=/p; /^VERSION_ID=/p' /etc/os-release
systemd-tmpfiles --version | sed -n '1p'
apt-get --version | sed -n '1p'
for tool in systemd-tmpfiles apt-get journalctl sha256sum runuser; do command -v "$tool" >/dev/null || exit 3; done
tmpfiles_snapshot >"$RESULT/tmpfiles.before"
trap cleanup EXIT

# Real source-mode mutation must refuse, while status and preview are rootless.
native status >"$RESULT/status.log" 2>&1
native --dry-run safe >"$RESULT/dry-run.log" 2>&1
status=0
native --yes vpsctl >"$RESULT/source-refusal.log" 2>&1 || status=$?
[[ "$status" == 3 ]] || fail "source-mode vpsctl expected 3, got $status"
ROOTLESS="$(mktemp -d /tmp/vpsctl-clean-rootless.XXXXXX)"
mkdir -p "$ROOTLESS/commands/system" "$ROOTLESS/lib"
cp "$NATIVE_ENTRY" "$ROOTLESS/commands/system/clean.sh"
cp "$TEST_ROOT/lib/command.sh" "$TEST_ROOT/lib/ui.sh" "$ROOTLESS/lib/"
chmod -R a+rX -- "$ROOTLESS"
runuser -u nobody -- env VPSCTL_TESTING=0 bash "$ROOTLESS/commands/system/clean.sh" --no-color --non-interactive status >"$RESULT/rootless-status.log" 2>&1
runuser -u nobody -- env VPSCTL_TESTING=0 bash "$ROOTLESS/commands/system/clean.sh" --no-color --non-interactive --dry-run safe >"$RESULT/rootless-preview.log" 2>&1
status=0
runuser -u nobody -- env VPSCTL_TESTING=0 bash "$ROOTLESS/commands/system/clean.sh" --no-color --non-interactive --yes packages >"$RESULT/rootless-refusal.log" 2>&1 || status=$?
[[ "$status" == 4 ]] || fail "rootless actual cleanup expected 4, got $status"
[[ ! -e "$ROOTLESS/run" ]] || fail 'rootless preview created mapped runtime state'
printf 'PASS: native source-mode status/preview, real ordinary-user status/preview/root refusal, explicit self refusal\n'

# Native apt clean must remove only its cache, without package state changes.
sha256sum /var/lib/dpkg/status >"$RESULT/dpkg.before"
printf 'disposable apt cache fixture\n' >"$APT_FIXTURE"
native --dry-run packages >"$RESULT/packages-preview.log" 2>&1
present "$APT_FIXTURE"
native --yes packages >"$RESULT/packages.log" 2>&1
absent "$APT_FIXTURE"
sha256sum /var/lib/dpkg/status >"$RESULT/dpkg.after"
cmp "$RESULT/dpkg.before" "$RESULT/dpkg.after" || fail 'dpkg installed-package state changed'
native --yes packages >"$RESULT/packages-repeat.log" 2>&1
printf 'PASS: actual apt clean, readonly preview, repeated empty cache, dpkg state retained\n'

# Use an existing native aging mechanism, with rules exclusively for our paths.
# ctime cannot be backdated. Wait for the old fixtures to age, then refresh recent.
mkdir -p -- "$TMP_FIXTURE" "$VAR_FIXTURE" "$TMP_PROTECTED" "$VAR_PROTECTED"
for directory in "$TMP_FIXTURE" "$VAR_FIXTURE" "$TMP_PROTECTED" "$VAR_PROTECTED"; do
    mkdir -p "$directory/keep"
    printf 'longer native rule fixture\n' >"$directory/keep/old"
    printf 'old disposable fixture\n' >"$directory/old"
    printf 'recent protected fixture\n' >"$directory/recent"
    printf 'd %s 0700 root root 5s\n' "$directory"
done >"$RULE"
# Each rule can match a protected root and our unprotected disposable root.
# Its longer age must remain a boundary against the parent's short policy.
printf 'e /tmp/*-%s/keep - - - 30d\ne /var/tmp/*-%s/keep - - - 30d\n' "$PID_TEXT" "$PID_TEXT" >>"$RULE"
for directory in "$TMP_PROTECTED" "$VAR_PROTECTED"; do
    mkdir -p "$directory/explicit" "$directory/glob"
    printf 'old explicit-rule protected fixture\n' >"$directory/explicit/old"
    printf 'old glob-rule protected fixture\n' >"$directory/glob/old"
    printf 'd %s/explicit 0700 root root 5s\n' "$directory" >>"$RULE"
    # The bracket expression matches only this fixture, while exercising a
    # native e rule whose protected root is expanded after prefix filtering.
    printf 'e %s[%s]%s/glob - - - 5s\n' "${directory%"$PID_TEXT"}" "${PID_TEXT:0:1}" "${PID_TEXT:1}" >>"$RULE"
done
sleep 7
touch -- "$TMP_FIXTURE/recent" "$VAR_FIXTURE/recent"
native --yes temp >"$RESULT/temp.log" 2>&1
absent "$TMP_FIXTURE/old"
absent "$VAR_FIXTURE/old"
present "$TMP_FIXTURE/recent"
present "$VAR_FIXTURE/recent"
present "$TMP_PROTECTED/old"
present "$VAR_PROTECTED/old"
present "$TMP_PROTECTED/recent"
present "$VAR_PROTECTED/recent"
present "$TMP_PROTECTED/explicit/old"
present "$VAR_PROTECTED/explicit/old"
present "$TMP_PROTECTED/glob/old"
present "$VAR_PROTECTED/glob/old"
present "$TMP_FIXTURE/keep/old"
present "$VAR_FIXTURE/keep/old"
present "$TMP_PROTECTED/keep/old"
present "$VAR_PROTECTED/keep/old"
rm -f -- "$RULE"
tmpfiles_snapshot >"$RESULT/tmpfiles.after"
cmp "$RESULT/tmpfiles.before" "$RESULT/tmpfiles.after" || fail 'cleanup wrote persistent tmpfiles configuration'
printf 'PASS: actual tmpfiles aging in both roots; recent, vpsctl root/explicit-nested/glob-nested exclusions retained; configuration unchanged\n'

# Vacuum actual archived logs without forcing rotation. Active files may grow;
# preservation is established by their path and inode, not their changing hash.
find /var/log/journal /run/log/journal -type f -name '*.journal' ! -name '*@*' -printf '%p\t%i\n' 2>/dev/null | sort >"$RESULT/journal-active.before" || true
[[ -s "$RESULT/journal-active.before" ]] || fail 'no active journal available for native preservation acceptance'
journalctl --disk-usage >"$RESULT/journal-usage.before" 2>&1
native --yes journal >"$RESULT/journal.log" 2>&1
while IFS=$'\t' read -r path inode; do
    present "$path"
    [[ "$(stat -c %i "$path")" == "$inode" ]] || fail "active journal replaced: $path"
done <"$RESULT/journal-active.before"
journalctl --disk-usage >"$RESULT/journal-usage.after" 2>&1
printf 'PASS: actual journal vacuum-time=30d and active journal retention (no artificial old log generation)\n'
printf 'PASS: native system clean acceptance\n'
