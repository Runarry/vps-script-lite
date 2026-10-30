#!/usr/bin/env bash
# Real local-restic regression tests; run only on host-vps-scripts.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016,SC2034,SC2317 # jq expressions, public flags and indirectly invoked fixture overrides.
set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d /var/tmp/vpsctl-backup-repo-test.XXXXXXXX)"
trap 'rm -rf -- "$TEST_TEMP"' EXIT
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$TEST_TEMP/root" VPSCTL_NON_INTERACTIVE=1 VPSCTL_ASSUME_YES=1 VPSCTL_NO_COLOR=1
export VPSCTL_DRY_RUN=0 VPSCTL_INSTALL_DEPS=0
mkdir -p "$VPSCTL_SYSTEM_ROOT" "$TEST_TEMP/work" "$TEST_TEMP/targets"
chmod 0755 "$TEST_TEMP/work" "$TEST_TEMP/targets"
# shellcheck source=../../commands/system/backup-repo.sh
source "$TEST_ROOT/commands/system/backup-repo.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
expect_status() {
    local expected="$1" status=0
    shift
    "$@" >"$TEST_TEMP/output" 2>&1 || status=$?
    [[ "$status" == "$expected" ]] || {
        cat "$TEST_TEMP/output" >&2
        fail "expected $expected, got $status: $*"
    }
}
make_job() {
    backup_job_create docker test-plan test-repo "$TEST_TEMP/work"
    printf 'application data %s\n' "$BACKUP_JOB_ID" >"$BACKUP_PAYLOAD_DIR/data.tar"
    jq -n --arg job "$BACKUP_JOB_ID" --arg host "$(backup_source_host)" --arg time "$(date -u +%FT%TZ)" \
        '{schema_version:1,type:"docker",plan_id:"test-plan",job_id:$job,source_host:$host,captured_at:$time,required_files:["data.tar"]}' >"$BACKUP_PAYLOAD_DIR/manifest.json"
}

backup_repo_main --help >/dev/null
[[ ! -e "$VPSCTL_SYSTEM_ROOT/etc" ]] || fail 'help wrote configuration'
expect_status 2 backup_repo_main configure invalid/name --type local
expect_status 2 backup_repo_main probe test-repo --pack-size 16
printf 'test-encryption-password\n' >"$TEST_TEMP/password"
chmod 0600 "$TEST_TEMP/password"
backup_repo_main configure test-repo --type local --path "$TEST_TEMP/repository" --password-file "$TEST_TEMP/password" --dry-run
[[ ! -e "$VPSCTL_SYSTEM_ROOT/etc" ]] || fail 'dry-run wrote configuration'
VPSCTL_DRY_RUN=0
backup_repo_main configure test-repo --type local --path "$TEST_TEMP/repository" --password-file "$TEST_TEMP/password"
backup_repo_load test-repo
[[ "$(stat -c %a "$BACKUP_ETC/repos/test-repo.json")" == 600 ]] || fail 'configuration permissions'
[[ "$(stat -c %a "$BACKUP_ETC/secrets")" == 700 ]] || fail 'secret directory permissions'
backup_repo_main status --json | jq -e '.schema_version == 1 and .remote_queried == false and .repositories[0].id == "test-repo"' >/dev/null
if [[ "$EUID" == 0 ]] && command -v runuser >/dev/null 2>&1; then
    chmod 0755 "$TEST_TEMP" "$VPSCTL_SYSTEM_ROOT"
    runuser -u nobody -- env VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$VPSCTL_SYSTEM_ROOT" VPSCTL_NON_INTERACTIVE=1 bash "$TEST_ROOT/commands/system/backup-repo.sh" status --json | jq -e '.remote_queried == false and .repositories == []' >/dev/null
fi
backup_repo_main init test-repo
backup_repo_main init test-repo
backup_repo_main check test-repo
plan="$(jq -n --arg work "$TEST_TEMP/work" '{schema_version:1,id:"test-plan",type:"docker",repo:"test-repo",work_dir:$work,retention:{daily:0,weekly:0,monthly:0},options:{}}')"
backup_plan_write test-plan docker "$plan"
backup_plan_load test-plan docker

make_job
first_job="$BACKUP_JOB_ID" first_payload="$BACKUP_PAYLOAD_DIR"
jq '.captured_at="2025-01-02T03:04:05Z"' "$first_payload/manifest.json" >"$first_payload/manifest.new"
mv "$first_payload/manifest.new" "$first_payload/manifest.json"
first_snapshot="$(backup_upload_job "$first_job")"
[[ "$first_snapshot" =~ ^[0-9a-f]{64}$ ]] || fail 'missing final snapshot ID'
backup_list_snapshots test-repo docker test-plan | jq -e --arg id "$first_snapshot" 'length == 1 and .[0].id == $id' >/dev/null
backup_list_snapshots test-repo docker test-plan | jq -e '.[0].time == "2025-01-02T03:04:05Z"' >/dev/null
[[ "$(backup_upload_job "$first_job")" == "$first_snapshot" ]] || fail 'idempotent retry changed snapshot'
mv "$BACKUP_ETC/plans/test-plan.json" "$BACKUP_ETC/plans/test-plan.offline"
backup_restore_snapshot test-repo "$first_snapshot" "$TEST_TEMP/targets/recovered" docker
cmp "$first_payload/data.tar" "$TEST_TEMP/targets/recovered/data.tar"
[[ -f "$TEST_TEMP/targets/recovered/manifest.json" ]] || fail 'restored payload prefix incorrect'
[[ "$(stat -c %a "$TEST_TEMP/targets")" == 755 && "$(stat -c %a "$TEST_TEMP/work")" == 755 ]] || fail 'user parent directory permissions changed'
expect_status 3 backup_restore_snapshot test-repo "$first_snapshot" "$TEST_TEMP/targets/recovered" docker
expect_status 10 backup_restore_snapshot test-repo "$first_snapshot" "$TEST_TEMP/targets/wrong-type" system
mv "$BACKUP_ETC/plans/test-plan.offline" "$BACKUP_ETC/plans/test-plan.json"
printf 'changed\n' >>"$first_payload/data.tar"
expect_status 30 backup_upload_job "$first_job"
[[ "$(backup_list_snapshots test-repo docker test-plan | jq length)" == 1 ]] || fail 'modified retry replaced complete snapshot'

make_job
rm -- "$BACKUP_PAYLOAD_DIR/data.tar"
expect_status 30 backup_upload_job "$BACKUP_JOB_ID"
[[ "$(jq -r .state "$BACKUP_JOB_DIR/job.json")" == incomplete ]] || fail 'missing source not recorded'
make_job
candidate_job="$BACKUP_JOB_ID"
sealed="$(backup_payload_index "$BACKUP_PAYLOAD_DIR")"
backup_atomic_json "$BACKUP_PAYLOAD_DIR/.vpsctl-files.json" "$sealed"
candidate="$(cd "$BACKUP_PAYLOAD_DIR" && backup_restic test-repo backup . --json --host "$(backup_source_host)" --tag "vpsctl,candidate,type:docker,plan:test-plan,job:$candidate_job" | jq -r 'select(.message_type == "summary")|.snapshot_id')"
expect_status 10 backup_restore_snapshot test-repo "$candidate" "$TEST_TEMP/targets/candidate" docker
[[ "$(backup_list_snapshots test-repo docker test-plan | jq length)" == 1 ]] || fail 'candidate appeared as complete'

# Real tag commits then reports a lost response: reconciliation must find the new ID.
mkdir "$TEST_TEMP/bin"
real_restic="$(command -v restic)"
printf '#!/usr/bin/env bash\nfor arg in "$@"; do if [[ "$arg" == tag ]]; then %q "$@"; exit 1; fi; done\nexec %q "$@"\n' "$real_restic" "$real_restic" >"$TEST_TEMP/bin/restic"
chmod 0700 "$TEST_TEMP/bin/restic"
original_path="$PATH"
PATH="$TEST_TEMP/bin:$PATH"
second_snapshot="$(backup_upload_job "$candidate_job")"
PATH="$original_path"
[[ "$second_snapshot" =~ ^[0-9a-f]{64}$ ]] || fail 'lost tag response not reconciled'
backup_repo_main prune test-repo --plan test-plan --dry-run >/dev/null
VPSCTL_DRY_RUN=0
[[ "$(backup_list_snapshots test-repo docker test-plan | jq length)" == 2 ]] || fail 'dry-run pruned snapshots'
backup_repo_main prune test-repo --plan test-plan >/dev/null
backup_list_snapshots test-repo docker test-plan | jq -e --arg id "$second_snapshot" 'length == 1 and .[0].id == $id' >/dev/null
backup_restic test-repo snapshots --json --tag candidate | jq -e 'length >= 1' >/dev/null
backup_repo_main check test-repo --read-data

# Native Restic's incomplete-source exit code must not become project code 3.
printf '#!/usr/bin/env bash\nfor arg in "$@"; do if [[ "$arg" == backup ]]; then exit 3; fi; done\nexec %q "$@"\n' "$real_restic" >"$TEST_TEMP/bin/restic"
make_job
PATH="$TEST_TEMP/bin:$original_path"
expect_status 30 backup_upload_job "$BACKUP_JOB_ID"
PATH="$original_path"
[[ -f "$BACKUP_PAYLOAD_DIR/data.tar" && "$(jq -r .state "$BACKUP_JOB_DIR/job.json")" == upload_failed ]] || fail 'partial upload lost local materials'
failed_payload="$BACKUP_PAYLOAD_DIR"

# The next collection reclaims completed payloads, preserving unknown files,
# incomplete jobs and actual candidate-only material. Small metadata survives.
vps_cmd_lock backup-capture
make_job
candidate_only_payload="$BACKUP_PAYLOAD_DIR"
sealed="$(backup_payload_index "$BACKUP_PAYLOAD_DIR")"
backup_atomic_json "$BACKUP_PAYLOAD_DIR/.vpsctl-files.json" "$sealed"
(cd "$BACKUP_PAYLOAD_DIR" && backup_restic test-repo backup . --json --host "$(backup_source_host)" --tag "vpsctl,candidate,type:docker,plan:test-plan,job:$BACKUP_JOB_ID") >/dev/null
second_payload="$TEST_TEMP/work/$candidate_job/payload"
printf 'operator-owned note\n' >"$second_payload/operator-note.txt"
VPSCTL_DRY_RUN=1
backup_cleanup_completed docker test-plan
[[ -f "$second_payload/data.tar" ]] || fail 'dry-run removed staged material'
VPSCTL_DRY_RUN=0
backup_cleanup_completed docker test-plan
[[ ! -e "$second_payload/data.tar" && -f "$second_payload/operator-note.txt" ]] || fail 'cleanup removed unknown file or retained completed payload'
[[ -f "$BACKUP_STATE/jobs/$candidate_job/manifest.json" && -f "$BACKUP_STATE/jobs/$candidate_job/payload-index.json" ]] || fail 'cleanup lost recovery metadata'
[[ -f "$failed_payload/data.tar" && -f "$candidate_only_payload/data.tar" && -f "$first_payload/data.tar" ]] || fail 'cleanup removed failed/candidate materials'
make_job
newest_job="$BACKUP_JOB_ID" newest_payload="$BACKUP_PAYLOAD_DIR"
jq --arg time "$(date -u -d '+1 minute' +%FT%TZ)" '.captured_at=$time' "$newest_payload/manifest.json" >"$newest_payload/manifest.new"
mv "$newest_payload/manifest.new" "$newest_payload/manifest.json"
newest_snapshot="$(backup_upload_job "$newest_job")"
printf '#!/usr/bin/env bash\nfor arg in "$@"; do if [[ "$arg" == forget ]]; then exit 1; fi; done\nexec %q "$@"\n' "$real_restic" >"$TEST_TEMP/bin/restic"
PATH="$TEST_TEMP/bin:$original_path"
expect_status 30 backup_maintain_completed "$newest_job"
PATH="$original_path"
jq -e '.state == "complete" and .maintenance.result == "failed"' "$BACKUP_STATE/jobs/$newest_job/job.json" >/dev/null
backup_maintain_completed "$newest_job"
jq -e '.state == "complete" and .maintenance.result == "passed"' "$BACKUP_STATE/jobs/$newest_job/job.json" >/dev/null
backup_list_snapshots test-repo docker test-plan | jq -e --arg id "$newest_snapshot" 'length == 1 and .[0].id == $id' >/dev/null
make_job
late_job="$BACKUP_JOB_ID" late_payload="$BACKUP_PAYLOAD_DIR"
jq '.captured_at="2024-01-02T03:04:05Z"' "$late_payload/manifest.json" >"$late_payload/manifest.new"
mv "$late_payload/manifest.new" "$late_payload/manifest.json"
late_snapshot="$(backup_upload_job "$late_job")"
backup_maintain_completed "$late_job"
jq -e '.state == "complete" and .maintenance.result == "skipped"' "$BACKUP_STATE/jobs/$late_job/job.json" >/dev/null
backup_restic test-repo snapshots --json "$late_snapshot" | jq -e 'length == 1' >/dev/null
backup_cleanup_completed docker test-plan
[[ ! -e "$newest_payload" && ! -e "$late_payload" ]] || fail 'completed full payloads accumulate across runs'
[[ -f "$BACKUP_STATE/jobs/$newest_job/backup-tool-versions.json" && -f "$BACKUP_STATE/jobs/$late_job/manifest.json" ]] || fail 'version/manifest history not preserved'
[[ -f "$failed_payload/data.tar" && -f "$candidate_only_payload/data.tar" && -f "$second_payload/operator-note.txt" ]] || fail 'second cleanup removed protected files'
[[ "$(backup_upload_job "$newest_job")" == "$newest_snapshot" ]] || fail 'retry after cleanup lost completed snapshot'
jq -e '.state == "complete"' "$BACKUP_STATE/jobs/$newest_job/job.json" >/dev/null

# A late retry can be removed by an explicit prune before its local cleanup.
# Keep that last local copy, but do not prevent the plan's next backup.
make_job
expired_job="$BACKUP_JOB_ID" expired_payload="$BACKUP_PAYLOAD_DIR"
jq '.captured_at="2023-01-02T03:04:05Z"' "$expired_payload/manifest.json" >"$expired_payload/manifest.new"
mv "$expired_payload/manifest.new" "$expired_payload/manifest.json"
backup_job_state upload_failed 'fixture: old capture awaiting retry'
expired_snapshot="$(backup_upload_job "$expired_job")"
backup_maintain_completed "$expired_job"
backup_repo_main prune test-repo --plan test-plan >/dev/null
backup_list_snapshots test-repo docker test-plan | jq -e --arg id "$expired_snapshot" 'all(.[]; .id != $id)' >/dev/null
expired_index="$(sha256sum "$expired_payload/.vpsctl-files.json")"
backup_cleanup_completed docker test-plan
backup_payload_verify "$expired_payload"
[[ "$(sha256sum "$expired_payload/.vpsctl-files.json")" == "$expired_index" ]] || fail 'expired snapshot cleanup changed local materials'
jq -e '.state == "complete" and .local_payload_cleaned_at == null and .local_cleanup.state == "skipped" and .local_cleanup.reason == "snapshot_missing"' "$BACKUP_STATE/jobs/$expired_job/job.json" >/dev/null
make_job
following_job="$BACKUP_JOB_ID" following_payload="$BACKUP_PAYLOAD_DIR"
jq --arg time "$(date -u -d '+2 minutes' +%FT%TZ)" '.captured_at=$time' "$following_payload/manifest.json" >"$following_payload/manifest.new"
mv "$following_payload/manifest.new" "$following_payload/manifest.json"
following_snapshot="$(backup_upload_job "$following_job")"
backup_maintain_completed "$following_job"
backup_list_snapshots test-repo docker test-plan | jq -e --arg id "$following_snapshot" 'length == 1 and .[0].id == $id' >/dev/null

# A missing ID is not permission to suppress transport, parsing or integrity
# failures. The still-present completed task must remain untouched in each case.
(
    backup_restic() { return 20; }
    expect_status 20 backup_cleanup_completed_job "$following_job"
    expect_status 30 backup_cleanup_completed docker test-plan
)
(
    backup_restic() { printf '%s\n' "$invalid_inventory"; }
    for invalid_inventory in 'not an id' '{}' '[{}]' 'short' "$following_snapshot"$'\ncorrupt'; do
        expect_status 10 backup_cleanup_completed_job "$following_job"
    done
)
(
    backup_snapshot_validate() { return 10; }
    expect_status 10 backup_cleanup_completed_job "$following_job"
)
backup_payload_verify "$following_payload"
jq -e '.local_payload_cleaned_at == null and .local_cleanup == null' "$BACKUP_STATE/jobs/$following_job/job.json" >/dev/null

# Restic snapshots --json exits successfully while skipping a corrupt object.
# The raw object inventory must keep that case on the integrity-failure path.
cp "$TEST_TEMP/repository/snapshots/$following_snapshot" "$TEST_TEMP/snapshot-original"
printf 'corrupt snapshot\n' >"$TEST_TEMP/repository/snapshots/$following_snapshot"
expect_status 10 backup_cleanup_completed_job "$following_job"
backup_payload_verify "$following_payload"
jq -e '.local_payload_cleaned_at == null and .local_cleanup == null' "$BACKUP_STATE/jobs/$following_job/job.json" >/dev/null
cp "$TEST_TEMP/snapshot-original" "$TEST_TEMP/repository/snapshots/$following_snapshot"
vps_cmd_unlock
printf 'PASS: backup repository, restore, candidate isolation, reconciliation, retention and bounded staging cleanup\n'
