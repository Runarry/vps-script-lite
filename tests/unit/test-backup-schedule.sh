#!/usr/bin/env bash
# Run only on the project's dedicated SSH test host. Fixture entries never back
# up host data; tests exercise the real scheduler, filesystem, locks and runner.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d /var/tmp/vpsctl-backup-schedule-test.XXXXXXXX)"
trap 'if [[ "${VPSCTL_TEST_KEEP_TEMP:-0}" == 1 ]]; then printf "Evidence: %s\n" "$TEST_TEMP"; else rm -rf -- "$TEST_TEMP"; fi' EXIT
export VPSCTL_TESTING=1 VPSCTL_NON_INTERACTIVE=1 VPSCTL_ASSUME_YES=1 VPSCTL_INSTALL_DEPS=0 VPSCTL_DRY_RUN=0 VPSCTL_NO_COLOR=1
export VPSCTL_SYSTEM_ROOT="$TEST_TEMP/system"
mkdir -p "$VPSCTL_SYSTEM_ROOT" "$TEST_TEMP/source/lib/backup" "$TEST_TEMP/source/commands/system/backup"
# shellcheck source=../../lib/command.sh
source "$TEST_ROOT/lib/command.sh"
# shellcheck source=../../lib/backup/config.sh
source "$TEST_ROOT/lib/backup/config.sh"
# shellcheck source=../../lib/backup/schedule.sh
source "$TEST_ROOT/lib/backup/schedule.sh"
vps_cmd_init test-backup-schedule "$TEST_TEMP/source"
backup_init "$TEST_TEMP/source"
export BACKUP_TEST_SCHEDULER=systemd BACKUP_JSON=1

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
equal() { [[ "$1" == "$2" ]] || fail "$3: expected [$1], got [$2]"; }
contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing [$2]"; }
invoke() { STATUS=0; OUTPUT="$("$@" 2>&1)" || STATUS=$?; }
backup_repo_probe() { printf '%s\n' "$1" >>"$VPSCTL_SYSTEM_ROOT/probes"; }

systemctl() {
    case "$1" in
        daemon-reload) printf '%s\n' "$*" >>"$VPSCTL_SYSTEM_ROOT/systemctl-events" ;;
        enable) touch "$VPSCTL_SYSTEM_ROOT/${*: -1}.enabled" ;;
        disable) rm -f -- "$VPSCTL_SYSTEM_ROOT/${*: -1}.enabled" ;;
        is-enabled|is-active) [[ -f "$VPSCTL_SYSTEM_ROOT/${*: -1}.enabled" ]] ;;
        *) fail "unexpected systemctl: $*" ;;
    esac
}
crontab() {
    if [[ "$1" == -l ]]; then
        [[ -f "$VPSCTL_SYSTEM_ROOT/crontab" ]] || { printf 'no crontab for root\n' >&2; return 1; }
        cat "$VPSCTL_SYSTEM_ROOT/crontab"
    else
        cp -- "$1" "$VPSCTL_SYSTEM_ROOT/crontab"
    fi
}

fixture_source() {
    local label="$1" file
    printf '%s\n' "$label" >"$TEST_TEMP/source/VERSION"
    for file in command environment ui; do cp "$TEST_ROOT/lib/$file.sh" "$TEST_TEMP/source/lib/"; done
    cp "$TEST_ROOT/lib/backup/schedule.sh" "$TEST_TEMP/source/lib/backup/"
    cp "$TEST_ROOT/lib/backup/config.sh" "$TEST_TEMP/source/lib/backup/"
    printf '# private repository module\n' >"$TEST_TEMP/source/lib/backup/repository.sh"
    printf '# private jobs module\n' >"$TEST_TEMP/source/lib/backup/jobs.sh"
    cat >"$TEST_TEMP/source/lib/backup.sh" <<'SH'
# shellcheck shell=bash
for module in config repository jobs schedule; do
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/backup/$module.sh"
done
SH
    cat >"$TEST_TEMP/source/lib/registry.sh" <<'SH'
vps_registry_bundle_files() {
    case "$1" in
        shared-backup) printf '%s\n' lib/backup.sh lib/backup/{config,repository,jobs,schedule}.sh ;;
        system-backup) printf '%s\n' commands/system/backup.sh commands/system/backup/late.sh ;;
        *) return 2 ;;
    esac
}
SH
    printf 'LATE_VERSION=%q\n' "$label" >"$TEST_TEMP/source/commands/system/backup/late.sh"
    cat >"$TEST_TEMP/source/commands/system/backup.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$root/lib/command.sh"
source "$root/lib/environment.sh"
source "$root/lib/backup.sh"
[[ "$VPSCTL_INSTALL_DEPS" == 0 && "$VPSCTL_NON_INTERACTIVE" == 1 && "$VPSCTL_ASSUME_YES" == 1 ]] || exit 98
[[ "$3" == --non-interactive && "$4" == --yes ]] || exit 97
case "$1" in
    recover-interrupted) printf 'recover %s\n' "$2" >>"$VPSCTL_SYSTEM_ROOT/entry-events" ;;
    run)
        printf 'started %s\n' "$(<"$root/VERSION")" >>"$VPSCTL_SYSTEM_ROOT/entry-events"
        : >"$VPSCTL_SYSTEM_ROOT/started"
        while [[ -f "$VPSCTL_SYSTEM_ROOT/block" ]]; do sleep 0.05; done
        source "$root/commands/system/backup/late.sh"
        printf 'finished %s %s\n' "$(<"$root/VERSION")" "$LATE_VERSION" >>"$VPSCTL_SYSTEM_ROOT/entry-events"
        ;;
    *) exit 96 ;;
esac
SH
}

fixture_source v1
backup_private_dir "$BACKUP_ETC" "$BACKUP_ETC/plans"
backup_plan_write daily system '{"schema_version":1,"id":"daily","type":"system","repo":"fixture","work_dir":"/var/tmp/fixture","retention":{"daily":7,"weekly":4,"monthly":6},"options":{}}'

printf 'TEST: strict cron grammar and calendar semantics\n'
for expression in '* * * * *' '*/15 2-6/2 1,15 JAN,MAR MON-FRI' '0 3 * * 7' '0 0 29 2 *'; do
    _backup_schedule_cron validate "$expression" || fail "valid cron rejected: $expression"
done
for expression in '0 0 * * *;touch /tmp/no' '$(id) * * * *' '0 0 * * * extra' '0 24 * * *' '60 * * * *' '*/0 * * * *' '0 0 * * 8' '@daily' '0 0 1W * *' $'0 0 * * *\n'; do
    invoke _backup_schedule_cron validate "$expression"
    equal 2 "$STATUS" "invalid cron rejected: $expression"
done
_backup_schedule_cron match '0 0 1 * MON' "$(date -d '2026-10-05 00:00:00' +%s)" || fail 'DOM/DOW must use OR'
_backup_schedule_cron match '0 0 1 * MON' "$(date -d '2026-10-01 00:00:00' +%s)" || fail 'DOM branch of OR missing'
invoke _backup_schedule_cron match '0 0 * * MON' "$(date -d '2026-10-01 00:00:00' +%s)"
equal 1 "$STATUS" 'wildcard day must respect weekday'
equal '2028-02-29' "$(_backup_schedule_cron inspect '0 0 29 2 *' "$(date -d '2026-10-01 00:00:00' +%s)" | jq -r '.next_run[:10]')" 'next leap day'

printf 'TEST: dry-run, read-only status and invalid plans\n'
before="$(find "$TEST_TEMP" -type f -exec sha256sum {} + | sort)"
VPSCTL_DRY_RUN=1 backup_schedule system daily enable '* * * * *'
VPSCTL_DRY_RUN=1 backup_schedule system daily disable
backup_schedule system daily status '' | jq -e '.enabled == false and .backend == "none"' >/dev/null
equal "$before" "$(find "$TEST_TEMP" -type f -exec sha256sum {} + | sort)" 'dry run/status files unchanged'
[[ ! -e "$BACKUP_STATE" && ! -e "$BACKUP_LIBEXEC" ]] || fail 'dry run/status created directories'
invoke backup_schedule system ../daily enable '* * * * *'; equal 2 "$STATUS" 'path traversal rejected'
invoke backup_schedule docker daily enable '* * * * *'; equal 10 "$STATUS" 'wrong plan type rejected'
invoke backup_schedule system daily enable '0 0 31 2 *'; equal 2 "$STATUS" 'impossible date rejected'

printf 'TEST: complete runtime and systemd render/status\n'
backup_schedule system daily enable '* * * * *'
equal fixture "$(<"$VPSCTL_SYSTEM_ROOT/probes")" 'write probe before enabling'
name="$(_backup_schedule_name system daily)"
unit="$VPSCTL_SYSTEM_ROOT/etc/systemd/system/$name"
contains "$(<"$unit.timer")" 'OnCalendar=*-*-* *:*:00' 'minute matcher timer'
contains "$(<"$unit.timer")" 'OnBootSec=30s' 'recovery tick after boot'
command systemd-analyze verify "$unit.service" "$unit.timer"
backup_schedule system daily status | jq -e '.enabled and .active and .next_run != null and .catch_up == false' >/dev/null
runtime="$BACKUP_LIBEXEC/system"
old="$(readlink -f "$runtime/current")"
[[ -f "$old/lib/backup/jobs.sh" && -f "$old/lib/ui.sh" && -f "$old/commands/system/backup/late.sh" ]] || fail 'incomplete runtime'
equal 700 "$(stat -c %a "$runtime")" 'runtime directory private'
equal 600 "$(stat -c %a "$BACKUP_ETC/schedules/system-daily.json")" 'schedule private'

printf 'TEST: overlap, immutable upgrade and original-release removal\n'
mv -- "$TEST_TEMP/source/commands/system/backup/late.sh" "$TEST_TEMP/source/commands/system/backup/late.missing"
invoke _backup_schedule_runtime_install system
equal 10 "$STATUS" 'incomplete upgrade must fail'
equal "$old" "$(readlink -f "$runtime/current")" 'failed upgrade changed current'
mv -- "$TEST_TEMP/source/commands/system/backup/late.missing" "$TEST_TEMP/source/commands/system/backup/late.sh"
touch "$VPSCTL_SYSTEM_ROOT/block"
bash "$runtime/runner" daily &
job=$!
for ((attempt=0; attempt<100; attempt++)); do
    [[ ! -f "$VPSCTL_SYSTEM_ROOT/started" ]] || break
    sleep 0.05
done
[[ -f "$VPSCTL_SYSTEM_ROOT/started" ]] || fail 'runner did not enter backup'
bash "$runtime/runner" daily
equal 1 "$(grep -c '^recover ' "$VPSCTL_SYSTEM_ROOT/entry-events")" 'overlap must not recover active job'
fixture_source v2
backup_schedule system daily enable '* * * * *'
new="$(readlink -f "$runtime/current")"
[[ "$old" != "$new" && -d "$old" ]] || fail 'active version deleted during upgrade'
mv -- "$TEST_TEMP/source" "$TEST_TEMP/removed-manager-release"
rm -f -- "$VPSCTL_SYSTEM_ROOT/block"
wait "$job"
contains "$(<"$VPSCTL_SYSTEM_ROOT/entry-events")" 'finished v1 v1' 'running job mixed versions after upgrade'
rm -f -- "$BACKUP_STATE/schedules/system-daily/last-attempt-minute"
if [[ "${VPSCTL_TEST_SYSTEMD_RUNTIME:-0}" == 1 ]]; then
    command systemd-run --wait --collect --unit="vpsctl-backup-schedule-fixture-$$" \
        --property=Type=oneshot -- /bin/bash "$runtime/runner" daily
else
    bash "$runtime/runner" daily
fi
contains "$(<"$VPSCTL_SYSTEM_ROOT/entry-events")" 'finished v2 v2' 'runtime relied on deleted manager release'
bash "$runtime/runner" daily
equal 2 "$(grep -c '^started ' "$VPSCTL_SYSTEM_ROOT/entry-events")" 'same-minute deduplication'
contains "$(<"$BACKUP_STATE/schedules/system-daily/events.jsonl")" 'overlap' 'overlap event missing'
future_minute=$(( (10#$(date +%M) + 2) % 60 ))
jq --arg cron "$future_minute * * * *" '.cron = $cron' "$BACKUP_ETC/schedules/system-daily.json" >"$TEST_TEMP/changed-schedule"
mv -- "$TEST_TEMP/changed-schedule" "$BACKUP_ETC/schedules/system-daily.json"
chmod 0600 "$BACKUP_ETC/schedules/system-daily.json"
recovered="$(grep -c '^recover ' "$VPSCTL_SYSTEM_ROOT/entry-events")"
bash "$runtime/runner" daily
equal "$((recovered + 1))" "$(grep -c '^recover ' "$VPSCTL_SYSTEM_ROOT/entry-events")" 'unscheduled minute must recover interrupted tasks'
equal 2 "$(grep -c '^started ' "$VPSCTL_SYSTEM_ROOT/entry-events")" 'unscheduled minute started a backup'
mv -- "$TEST_TEMP/removed-manager-release" "$TEST_TEMP/source"
backup_schedule system daily enable '* * * * *'
[[ ! -d "$old" ]] || fail 'idle old runtime not collected'

printf 'TEST: disable ownership and cron preservation\n'
backup_schedule system daily disable
backup_schedule system daily disable ''
[[ ! -e "$unit.service" && ! -e "$unit.timer" && -d "$new" ]] || fail 'disable removed runtime or retained units'
backup_schedule system daily status | jq -e '.enabled == false' >/dev/null
printf '# someone else\n' >"$unit.service"
invoke backup_schedule system daily enable '* * * * *'
equal 10 "$STATUS" 'foreign service refused'
backup_schedule system daily disable
equal '# someone else' "$(<"$unit.service")" 'foreign unit removed'
rm -f -- "$unit.service"
BACKUP_TEST_SCHEDULER=cron
printf '17 2 * * * /usr/local/bin/other-job\n# user comment\n' >"$VPSCTL_SYSTEM_ROOT/crontab"
backup_schedule system daily enable '0 3 * * 0'
contains "$(<"$VPSCTL_SYSTEM_ROOT/crontab")" '* * * * * /bin/bash' 'cron uses same minute matcher'
backup_schedule system daily enable '0 3 * * 0'
equal 1 "$(grep -c 'vpsctl-backup-schedule:v1' "$VPSCTL_SYSTEM_ROOT/crontab")" 'duplicate cron entries'
backup_schedule system daily status | jq -e '.enabled and .backend == "cron"' >/dev/null
backup_schedule system daily disable
equal $'17 2 * * * /usr/local/bin/other-job\n# user comment' "$(<"$VPSCTL_SYSTEM_ROOT/crontab")" 'foreign cron modified'
printf 'TEST: active uninstall preserves leased runtime\n'
backup_schedule system daily enable '* * * * *'
rm -f -- "$BACKUP_STATE/schedules/system-daily/last-attempt-minute" "$VPSCTL_SYSTEM_ROOT/started"
touch "$VPSCTL_SYSTEM_ROOT/block"
bash "$runtime/runner" daily &
job=$!
for ((attempt=0; attempt<100; attempt++)); do
    [[ ! -f "$VPSCTL_SYSTEM_ROOT/started" ]] || break
    sleep 0.05
done
[[ -f "$VPSCTL_SYSTEM_ROOT/started" ]] || fail 'uninstall fixture did not enter backup'
backup_schedule_uninstall system
[[ -d "$new" && ! -e "$runtime/current" ]] || fail 'active uninstall removed leased version'
rm -f -- "$VPSCTL_SYSTEM_ROOT/block"
wait "$job"
backup_schedule_uninstall system
[[ ! -e "$runtime/runner" && ! -e "$runtime/current" && ! -d "$new" ]] || fail 'uninstall did not remove idle runtime'
[[ -f "$BACKUP_ETC/plans/daily.json" ]] || fail 'uninstall deleted plan'
printf 'PASS: backup scheduling and immutable offline runtime\n'
