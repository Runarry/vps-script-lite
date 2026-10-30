#!/usr/bin/env bash
# Real services and destructive, namespace-limited backup acceptance fixtures.
set -Eeuo pipefail
umask 077
[[ ${VPSCTL_BACKUP_REAL:-0} == 1 && $EUID == 0 ]] || { echo 'Set VPSCTL_BACKUP_REAL=1 on host-vps-scripts'; exit 3; }
[[ $(hostname) == debian-vps-script ]] || exit 3
LAB=${VPSCTL_BACKUP_LAB:-/var/tmp/vpsctl-backup-acceptance-20261030}
[[ $LAB == /var/tmp/vpsctl-backup-acceptance-* && $LAB != *..* ]] || exit 3
mkdir -p "$LAB/evidence" "$LAB/root" "$LAB/webdav" "$LAB/s3/backup-test"
exec > >(tee -a "$LAB/evidence/real.log") 2>&1
SOURCE=${VPSCTL_BACKUP_SOURCE:-/var/tmp/vpsctl-backup-implementation/source}
cli() { VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$LAB/root" bash "$SOURCE/bin/vpsctl" --non-interactive --yes "$@"; }
shared() {
    export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$LAB/root"
    source "$SOURCE/lib/command.sh"
    source "$SOURCE/lib/backup.sh"
    vps_cmd_init system-backup-repo "$SOURCE"
    backup_init "$SOURCE"
}
case ${1:-status} in
services)
    [[ ! -e $LAB/webdav.pid && ! -e $LAB/s3.pid ]] || exit 3
    printf 'acceptance-encryption-password\n' > "$LAB/password"
    printf '{"user":"backup-test","password":"acceptance-webdav"}\n' > "$LAB/webdav-credentials.json"
    printf '{"access_key_id":"backup-test","secret_access_key":"acceptance-s3-password"}\n' > "$LAB/s3-credentials.json"
    chmod 600 "$LAB/password" "$LAB/"*-credentials.json
    nohup rclone serve webdav "$LAB/webdav" --addr 0.0.0.0:18441 \
        --user backup-test --pass acceptance-webdav > "$LAB/evidence/webdav.log" 2>&1 </dev/null &
    echo $! > "$LAB/webdav.pid"
    nohup "$LAB/tools/rclone" serve s3 "$LAB/s3" --addr 0.0.0.0:18442 \
        --auth-key backup-test,acceptance-s3-password > "$LAB/evidence/s3.log" 2>&1 </dev/null &
    echo $! > "$LAB/s3.pid"
    sleep 1
    kill -0 "$(cat "$LAB/webdav.pid")" "$(cat "$LAB/s3.pid")"
    curl -fsS --user backup-test:acceptance-webdav http://127.0.0.1:18441/ >/dev/null
    echo 'PASS: real WebDAV and experimental rclone S3 services started'
    ;;
docker-fixture)
    [[ ! -e $LAB/docker-fixture-created ]] || exit 3
    ! docker container inspect vpsctl-backup-test-main >/dev/null 2>&1 || exit 3
    mkdir -p "$LAB/bind"
    printf 'uploaded-business-file\n' > "$LAB/bind/upload.txt"
    python3 - "$LAB/bind/business.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute('create table invoices(id integer primary key, amount integer, note text)')
db.executemany('insert into invoices values (?, ?, ?)', [(1, 1250, 'paid'), (2, 875, 'open')])
db.commit()
assert db.execute('pragma integrity_check').fetchone() == ('ok',)
db.close()
PY
    docker volume create --label vpsctl-backup-test=acceptance vpsctl-backup-test-shared
    docker run -d --name vpsctl-backup-test-main --label vpsctl-backup-test=acceptance \
        --restart unless-stopped --mount type=volume,src=vpsctl-backup-test-shared,dst=/shared \
        --mount type=volume,dst=/anonymous --mount "type=bind,src=$LAB/bind,dst=/business" \
        debian:bookworm-slim sh -c 'trap "exit 0" TERM; while :; do sleep 1 & wait "$!"; done'
    docker run -d --name vpsctl-backup-test-stopped --label vpsctl-backup-test=acceptance \
        --mount type=volume,src=vpsctl-backup-test-shared,dst=/shared debian:bookworm-slim sh -c 'trap "exit 0" TERM; while :; do sleep 1 & wait "$!"; done'
    docker exec vpsctl-backup-test-main sh -c 'printf "named-shared-content\n" > /shared/named.txt; printf "anonymous-content\n" > /anonymous/anonymous.txt; printf "writable-layer-content\n" > /root/writable.txt; chmod 640 /shared/named.txt'
    docker exec vpsctl-backup-test-stopped sh -c 'printf "stopped-writable-layer\n" > /root/stopped.txt'
    docker stop vpsctl-backup-test-stopped
    docker inspect vpsctl-backup-test-main vpsctl-backup-test-stopped > "$LAB/evidence/docker-source-inspect.json"
    jq -r '.[0].Mounts[]|select(.Destination=="/anonymous")|.Name' "$LAB/evidence/docker-source-inspect.json" > "$LAB/anonymous-volume"
    sha256sum "$LAB/bind/"* > "$LAB/evidence/docker-bind.sha256"
    touch "$LAB/docker-fixture-created"
    echo 'PASS: running/stopped/shared/named/anonymous/bind/writable/SQLite fixture prepared'
    ;;
repos)
    cli system backup-repo configure acceptance-dav --type webdav --url http://127.0.0.1:18441 \
        --vendor other --prefix restic --credentials-file "$LAB/webdav-credentials.json" --password-file "$LAB/password" --allow-http
    cli system backup-repo configure acceptance-s3 --type s3 --endpoint http://127.0.0.1:18442 \
        --bucket backup-test --prefix restic --region us-east-1 --bucket-lookup path \
        --credentials-file "$LAB/s3-credentials.json" --password-file "$LAB/password" --allow-http
    for repo in acceptance-dav acceptance-s3; do
        cli system backup-repo probe "$repo"
        cli system backup-repo init "$repo"
        cli system backup-repo check "$repo" --read-data
    done
    ;;
storage-roundtrip)
    shared
    mkdir -p "$LAB/storage-fixture"
    head -c 12582912 /dev/urandom > "$LAB/storage-fixture/business.bin"
    sha256sum "$LAB/storage-fixture/business.bin" > "$LAB/evidence/business.sha256"
    for repo in acceptance-dav acceptance-s3; do
        plan="roundtrip-$repo"
        plan_json=$(jq -n --arg id "$plan" --arg repo "$repo" --arg work "$LAB/storage-work" \
            '{schema_version:1,id:$id,type:"docker",repo:$repo,work_dir:$work,retention:{daily:0,weekly:0,monthly:0},options:{}}')
        backup_plan_write "$plan" docker "$plan_json"
        for iteration in 1 2; do
            backup_job_create docker "$plan" "$repo" "$LAB/storage-work"
            cp "$LAB/storage-fixture/business.bin" "$BACKUP_PAYLOAD_DIR/business.bin"
            printf '%s\n' "$iteration" > "$BACKUP_PAYLOAD_DIR/generation"
            jq -n --arg plan "$plan" --arg job "$BACKUP_JOB_ID" --arg host "$(backup_source_host)" --arg time "$(date -u +%FT%TZ)" \
                '{schema_version:1,type:"docker",plan_id:$plan,job_id:$job,source_host:$host,captured_at:$time,required_files:["business.bin","generation"]}' > "$BACKUP_PAYLOAD_DIR/manifest.json"
            backup_upload_job "$BACKUP_JOB_ID" | tee "$LAB/evidence/$repo-snapshot-$iteration"
        done
        snapshot=$(cat "$LAB/evidence/$repo-snapshot-2")
        backup_restore_snapshot "$repo" "$snapshot" "$LAB/restored-$repo" docker
        cmp "$LAB/storage-fixture/business.bin" "$LAB/restored-$repo/business.bin"
        [[ $(cat "$LAB/restored-$repo/generation") == 2 ]]
        cli system backup-repo check "$repo" --read-data
        cli system backup-repo prune "$repo" --plan "$plan"
        backup_list_snapshots "$repo" docker "$plan" | tee "$LAB/evidence/$repo-after-prune.json"
        [[ $(jq length "$LAB/evidence/$repo-after-prune.json") == 1 ]]
        [[ $(jq -r '.[0].id' "$LAB/evidence/$repo-after-prune.json") == "$snapshot" ]]
        echo "PASS: $repo actual 12MiB upload, restored bytes, full data check, scoped prune/latest preservation"
    done
    ;;
docker-backup)
    cli system backup-docker configure acceptance-docker --repo acceptance-s3 \
        --work-dir "$LAB/docker-work" --container vpsctl-backup-test-main \
        --container vpsctl-backup-test-stopped --consistency stop \
        --helper-image debian:bookworm-slim --daily 0 --weekly 0 --monthly 0
    cli system backup-docker inspect acceptance-docker --json > "$LAB/evidence/docker-plan.json"
    cli system backup-docker run acceptance-docker
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-main) == true ]]
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-stopped) == false ]]
    shared
    backup_list_snapshots acceptance-s3 docker acceptance-docker > "$LAB/evidence/docker-snapshots.json"
    jq -er '.[0].id' "$LAB/evidence/docker-snapshots.json" > "$LAB/docker-snapshot"
    echo 'PASS: Docker collected/uploaded; original running and stopped states preserved'
    ;;
compose-fixture)
    mkdir -p "$LAB/sqlite-image" "$LAB/compose/db" "$LAB/compose/uploads"
    cat > "$LAB/sqlite-image/Dockerfile" <<'DOCKERFILE'
FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y --no-install-recommends sqlite3 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
    docker build -t vpsctl-backup-test-sqlite:acceptance "$LAB/sqlite-image"
    printf 'compose-upload-content\n' > "$LAB/compose/uploads/upload.txt"
    python3 - "$LAB/compose/db/business.db" <<'PY'
import sqlite3,sys
db=sqlite3.connect(sys.argv[1])
db.execute('pragma journal_mode=wal')
db.execute('create table invoices(id integer primary key, amount integer, note text)')
db.executemany('insert into invoices values (?,?,?)',[(1,1250,'paid'),(2,875,'open')])
db.execute('create table sequence(n integer)')
db.execute('insert into sequence values (0)')
db.commit()
db.close()
PY
    cat > "$LAB/compose/compose.yaml" <<YAML
services:
  sqlite:
    image: vpsctl-backup-test-sqlite:acceptance
    container_name: vpsctl-backup-test-compose-sqlite
    labels:
      vpsctl-backup-test: acceptance
    volumes:
      - $LAB/compose/db:/data
    command: [sh, -c, 'trap "exit 0" TERM; while :; do sqlite3 /data/business.db "UPDATE sequence SET n=n+1;"; sleep 1 & wait \$\$!; done']
  uploads:
    image: debian:bookworm-slim
    container_name: vpsctl-backup-test-compose-uploads
    labels:
      vpsctl-backup-test: acceptance
    volumes:
      - $LAB/compose/uploads:/uploads
    command: [sh, -c, 'trap "exit 0" TERM; while :; do sleep 1 & wait \$\$!; done']
YAML
    docker compose -p vpsctl-backup-test-compose -f "$LAB/compose/compose.yaml" up -d
    docker compose -p vpsctl-backup-test-compose -f "$LAB/compose/compose.yaml" config > "$LAB/evidence/compose-resolved.yaml"
    docker exec vpsctl-backup-test-compose-sqlite sqlite3 /data/business.db 'pragma integrity_check; select * from invoices; select n from sequence;'
    ;;
compose-stop-restore)
    cli system backup-docker configure acceptance-compose --repo acceptance-dav --work-dir "$LAB/compose-work" \
        --project vpsctl-backup-test-compose --consistency stop --helper-image debian:bookworm-slim
    cli system backup-docker run acceptance-compose
    shared
    snapshot=$(backup_list_snapshots acceptance-dav docker acceptance-compose | jq -er '.[0].id')
    printf '%s\n' "$snapshot" > "$LAB/compose-snapshot"
    cli system backup-docker restore-plan acceptance-dav "$snapshot" --target "$LAB/compose-download" \
        --bind-map "$LAB/compose/db=$LAB/compose-restored/db" --bind-map "$LAB/compose/uploads=$LAB/compose-restored/uploads" --json > "$LAB/evidence/compose-restore-plan.json"
    jq -e '.compose|length==2' "$LAB/compose-download/manifest.json" >/dev/null
    tar -tf "$LAB/compose-download/compose/sources.tar" | tee "$LAB/evidence/compose-source-archive.txt"
    grep -F 'compose/compose.yaml' "$LAB/evidence/compose-source-archive.txt"
    image=$(docker inspect -f '{{.Image}}' vpsctl-backup-test-compose-sqlite)
    docker compose -p vpsctl-backup-test-compose -f "$LAB/compose/compose.yaml" down
    [[ $LAB/compose == /var/tmp/vpsctl-backup-acceptance-*/compose && ! -L $LAB/compose ]] || exit 3
    rm -rf -- "$LAB/compose"
    docker image rm -f "$image"
    ! docker image inspect "$image" >/dev/null 2>&1 || exit 1
    cli system backup-docker restore acceptance-dav "$snapshot" --payload "$LAB/compose-download" \
        --bind-map "$LAB/compose/db=$LAB/compose-restored/db" --bind-map "$LAB/compose/uploads=$LAB/compose-restored/uploads"
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-compose-sqlite) == true ]]
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-compose-uploads) == true ]]
    [[ $(cat "$LAB/compose-restored/uploads/upload.txt") == compose-upload-content ]]
    [[ $(docker exec vpsctl-backup-test-compose-sqlite sqlite3 /data/business.db 'pragma integrity_check') == ok ]]
    [[ $(docker exec vpsctl-backup-test-compose-sqlite sqlite3 /data/business.db 'select sum(amount) from invoices') == 2125 ]]
    echo 'PASS: actual Compose source and resolved definitions archived; source DB/uploads/image/containers/network deleted; running business restored from WebDAV'
    ;;
sqlite-online-restore)
    before=$(docker exec vpsctl-backup-test-compose-sqlite sqlite3 /data/business.db 'select n from sequence')
    printf '%s\n' "$before" > "$LAB/evidence/sqlite-sequence-before"
    printf '[{"kind":"sqlite","container":"vpsctl-backup-test-compose-sqlite","path":"/data/business.db"}]\n' > "$LAB/online.json"
    cli system backup-docker configure acceptance-online --repo acceptance-s3 --work-dir "$LAB/online-work" \
        --container vpsctl-backup-test-compose-sqlite --consistency online --online-config "$LAB/online.json" --helper-image debian:bookworm-slim
    cli system backup-docker run acceptance-online
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-compose-sqlite) == true ]]
    shared
    snapshot=$(backup_list_snapshots acceptance-s3 docker acceptance-online | jq -er '.[0].id')
    cli system backup-docker restore-plan acceptance-s3 "$snapshot" --target "$LAB/online-download" \
        --bind-map "$LAB/compose-restored/db=$LAB/online-restored/db" --json > "$LAB/evidence/online-restore-plan.json"
    jq -e '.consistency=="online" and (.online_exports|length==1) and .online_exports[0].kind=="sqlite"' "$LAB/online-download/manifest.json" >/dev/null
    image=$(docker inspect -f '{{.Image}}' vpsctl-backup-test-compose-sqlite)
    docker rm -f vpsctl-backup-test-compose-sqlite
    [[ $LAB/compose-restored/db == /var/tmp/vpsctl-backup-acceptance-*/compose-restored/db && ! -L $LAB/compose-restored/db ]] || exit 3
    rm -rf -- "$LAB/compose-restored/db"
    docker image rm -f "$image"
    docker network disconnect vpsctl-backup-test-compose_default vpsctl-backup-test-compose-uploads
    docker network rm vpsctl-backup-test-compose_default
    cli system backup-docker restore acceptance-s3 "$snapshot" --payload "$LAB/online-download" \
        --bind-map "$LAB/compose-restored/db=$LAB/online-restored/db"
    docker network connect vpsctl-backup-test-compose_default vpsctl-backup-test-compose-uploads
    [[ $(docker exec vpsctl-backup-test-compose-sqlite sqlite3 /data/business.db 'pragma integrity_check') == ok ]]
    [[ $(docker exec vpsctl-backup-test-compose-sqlite sqlite3 /data/business.db 'select sum(amount) from invoices') == 2125 ]]
    after=$(docker exec vpsctl-backup-test-compose-sqlite sqlite3 /data/business.db 'select n from sequence')
    ((after >= before))
    printf 'PASS: native SQLite online snapshot; active WAL writer kept running; source container/image/DB removed; restored integrity/business rows/sequence %s >= %s\n' "$after" "$before"
    ;;
docker-space-failure)
    shared
    backup_list_snapshots acceptance-s3 docker acceptance-docker > "$LAB/evidence/space-before-snapshots.json"
    mkdir -p "$LAB/tiny-stage"
    mount -t tmpfs -o size=32m,mode=700 vpsctl-backup-test-space "$LAB/tiny-stage"
    trap 'umount "$LAB/tiny-stage"' EXIT
    cli system backup-docker configure acceptance-space --repo acceptance-s3 --work-dir "$LAB/tiny-stage" \
        --container vpsctl-backup-test-main --container vpsctl-backup-test-stopped --consistency stop
    status=0
    cli system backup-docker run acceptance-space > "$LAB/evidence/docker-space-output.log" 2>&1 || status=$?
    [[ $status != 0 ]]
    grep -F '暂存空间不足' "$LAB/evidence/docker-space-output.log"
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-main) == true ]]
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-stopped) == false ]]
    backup_list_snapshots acceptance-s3 docker acceptance-docker > "$LAB/evidence/space-after-snapshots.json"
    cmp "$LAB/evidence/space-before-snapshots.json" "$LAB/evidence/space-after-snapshots.json"
    printf 'PASS: actual 32MiB full-space preflight rejected before stop; original states and complete snapshot unchanged (exit %s)\n' "$status"
    ;;
host-shared-writer)
    unit=vpsctl-backup-test-writer.service
    [[ ! -e /run/systemd/system/$unit ]] || exit 3
    cat > "$LAB/host-writer.py" <<'PY'
import os,sys,time
with open(sys.argv[1], 'r+b', buffering=0) as stream:
    while True:
        stream.seek(0)
        stream.write(b'host-shared-writer\n')
        os.fsync(stream.fileno())
        time.sleep(.2)
PY
    printf '[Unit]\nDescription=Isolated vpsctl backup acceptance writer\n[Service]\nExecStart=/usr/bin/python3 %s/host-writer.py %s/restored-bind/upload.txt\n' "$LAB" "$LAB" > "/run/systemd/system/$unit"
    systemctl daemon-reload
    trap 'systemctl stop "$unit"; rm -f "/run/systemd/system/$unit"; systemctl daemon-reload' EXIT
    systemctl start "$unit"
    systemctl is-active --quiet "$unit"
    cli system backup-docker configure acceptance-writer-uncoordinated --repo acceptance-s3 --work-dir "$LAB/writer-work" \
        --container vpsctl-backup-test-main --container vpsctl-backup-test-stopped --consistency stop
    status=0
    cli system backup-docker run acceptance-writer-uncoordinated > "$LAB/evidence/uncoordinated-writer.log" 2>&1 || status=$?
    [[ $status != 0 ]]
    grep -F '宿主机写入者' "$LAB/evidence/uncoordinated-writer.log"
    systemctl is-active --quiet "$unit"
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-main) == true ]]
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-stopped) == false ]]
    cli system backup-docker configure acceptance-writer-coordinated --repo acceptance-s3 --work-dir "$LAB/writer-work" \
        --container vpsctl-backup-test-main --container vpsctl-backup-test-stopped --consistency stop --host-service "$unit"
    cli system backup-docker run acceptance-writer-coordinated
    systemctl is-active --quiet "$unit"
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-main) == true ]]
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-stopped) == false ]]
    echo 'PASS: actual host shared writer blocks uncoordinated backup; declared service is stopped and resumed with original container states'
    ;;
storage-interrupted-upload)
    # This endpoint AND repository are independent of every normal acceptance run.
    nohup "$LAB/tools/rclone" serve s3 "$LAB/s3" --addr 127.0.0.1:18443 \
        --auth-key backup-test,acceptance-s3-password > "$LAB/evidence/s3-interruption.log" 2>&1 </dev/null &
    fault_pid=$!
    trap 'kill "$fault_pid" 2>/dev/null || true' EXIT
    sleep 1
    cli system backup-repo configure acceptance-interruption --type s3 --endpoint http://127.0.0.1:18443 \
        --bucket backup-test --prefix fault-restic --region us-east-1 --bucket-lookup path \
        --credentials-file "$LAB/s3-credentials.json" --password-file "$LAB/password" --allow-http
    cli system backup-repo init acceptance-interruption
    shared
    plan=acceptance-interruption
    backup_plan_write "$plan" docker "$(jq -n --arg work "$LAB/interruption-work" '{schema_version:1,id:"acceptance-interruption",type:"docker",repo:"acceptance-interruption",work_dir:$work,retention:{daily:0,weekly:0,monthly:0},options:{}}')"
    for iteration in seed interrupted; do
        backup_job_create docker "$plan" acceptance-interruption "$LAB/interruption-work"
        job=$BACKUP_JOB_ID
        if [[ $iteration == seed ]]; then printf 'old-complete-recovery-point\n' > "$BACKUP_PAYLOAD_DIR/business.bin"; else head -c 52428800 /dev/urandom > "$BACKUP_PAYLOAD_DIR/business.bin"; fi
        jq -n --arg job "$job" --arg host "$(backup_source_host)" --arg time "$(date -u +%FT%TZ)" \
            '{schema_version:1,type:"docker",plan_id:"acceptance-interruption",job_id:$job,source_host:$host,captured_at:$time,required_files:["business.bin"]}' > "$BACKUP_PAYLOAD_DIR/manifest.json"
        if [[ $iteration == seed ]]; then
            backup_upload_job "$job" > "$LAB/evidence/interruption-old-snapshot"
        fi
    done
    initial=$(find "$LAB/s3/backup-test/fault-restic/data" -type f | wc -l)
    docker inspect -f '{{.State.StartedAt}}' vpsctl-backup-test-main > "$LAB/evidence/interruption-start-before"
    (set +e; backup_upload_job "$job" > "$LAB/evidence/interrupted-upload-output.log" 2>&1; printf '%s\n' "$?" > "$LAB/evidence/interrupted-upload-status") &
    uploader=$!
    for ((attempt=0; attempt<3000; attempt++)); do
        current=$(find "$LAB/s3/backup-test/fault-restic/data" -type f | wc -l)
        ((current <= initial)) || break
        sleep .01
    done
    ((current > initial)) || { echo 'ABORTED: no actual data upload observed'; exit 1; }
    kill "$fault_pid"
    wait "$fault_pid" || true
    sleep 1
    # Bound this injected interruption; signal only the real Restic child of this upload.
    python3 - "$uploader" <<'PY'
import os,pathlib,signal,sys,time
def stop(pid):
    for child in children.get(pid,[]): stop(child)
    try:
        if pathlib.Path(f'/proc/{pid}/exe').resolve()==pathlib.Path('/usr/bin/restic'):
            os.kill(pid,signal.SIGKILL)
    except OSError: pass
root=int(sys.argv[1])
for attempt in range(100):
    if not pathlib.Path(f'/proc/{root}').exists(): break
    children={}
    for p in pathlib.Path('/proc').iterdir():
        if not p.name.isdigit(): continue
        try:
            fields=(p/'stat').read_text().split(') ',1)[1].split()
            children.setdefault(int(fields[1]),[]).append(int(p.name))
        except (OSError,IndexError,ValueError): pass
    stop(root)
    time.sleep(.2)
PY
    wait "$uploader"
    [[ $(cat "$LAB/evidence/interrupted-upload-status") != 0 ]]
    [[ $(jq -r .state "$BACKUP_JOB_DIR/job.json") == upload_failed ]]
    sha256sum "$BACKUP_PAYLOAD_DIR/.vpsctl-files.json" > "$LAB/evidence/interruption-sealed-index.sha256"
    nohup "$LAB/tools/rclone" serve s3 "$LAB/s3" --addr 127.0.0.1:18443 \
        --auth-key backup-test,acceptance-s3-password > "$LAB/evidence/s3-interruption-resumed.log" 2>&1 </dev/null &
    fault_pid=$!
    sleep 1
    backup_restic acceptance-interruption unlock
    backup_list_snapshots acceptance-interruption docker "$plan" > "$LAB/evidence/interruption-after-failure.json"
    [[ $(jq length "$LAB/evidence/interruption-after-failure.json") == 1 ]]
    [[ $(jq -r '.[0].id' "$LAB/evidence/interruption-after-failure.json") == "$(cat "$LAB/evidence/interruption-old-snapshot")" ]]
    backup_upload_job "$job" > "$LAB/evidence/interruption-retried-snapshot"
    sha256sum -c "$LAB/evidence/interruption-sealed-index.sha256"
    docker inspect -f '{{.State.StartedAt}}' vpsctl-backup-test-main > "$LAB/evidence/interruption-start-after"
    cmp "$LAB/evidence/interruption-start-before" "$LAB/evidence/interruption-start-after"
    cli system backup-repo check acceptance-interruption --read-data
    echo 'PASS: independent real S3 server terminated during observed data upload; interrupted job failed, old complete snapshot survived, sealed material retried without business restart; full data check passed'
    ;;
repository-auth-denied)
    printf '{"access_key_id":"rejected-test-user","secret_access_key":"rejected-test-password"}\n' > "$LAB/rejected-credentials.json"
    chmod 600 "$LAB/rejected-credentials.json"
    cli system backup-repo configure acceptance-denied --type s3 --endpoint http://127.0.0.1:18442 \
        --bucket backup-test --prefix restic --region us-east-1 --bucket-lookup path \
        --credentials-file "$LAB/rejected-credentials.json" --password-file "$LAB/password" --allow-http
    shared
    backup_list_snapshots acceptance-s3 docker > "$LAB/evidence/auth-before-snapshots.json"
    status=0
    cli system backup-repo probe acceptance-denied > "$LAB/evidence/auth-denied-output.log" 2>&1 || status=$?
    [[ $status != 0 ]]
    grep -Ei 'access.denied|access key|forbidden|invalidaccess|authentication' "$LAB/evidence/auth-denied-output.log"
    backup_list_snapshots acceptance-s3 docker > "$LAB/evidence/auth-after-snapshots.json"
    cmp "$LAB/evidence/auth-before-snapshots.json" "$LAB/evidence/auth-after-snapshots.json"
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-main) == true ]]
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-stopped) == false ]]
    printf 'PASS: real S3 authentication denied (exit %s); historical complete snapshots and business states unchanged\n' "$status"
    ;;
docker-destroy-restore)
    [[ -s $LAB/docker-snapshot && -f $LAB/docker-fixture-created ]] || exit 3
    snapshot=$(cat "$LAB/docker-snapshot")
    [[ $snapshot =~ ^[a-f0-9]{64}$ ]] || exit 3
    cli system backup-docker restore-plan acceptance-s3 "$snapshot" --target "$LAB/docker-download" \
        --bind-map "$LAB/bind=$LAB/restored-bind" --json > "$LAB/evidence/docker-restore-plan-before-delete.json"
    # Scope all destructive operations to the exact fixture identities.
    docker rm -f vpsctl-backup-test-main vpsctl-backup-test-stopped
    anonymous=$(cat "$LAB/anonymous-volume")
    [[ $anonymous =~ ^[a-f0-9]{64}$ ]] || exit 3
    docker volume rm vpsctl-backup-test-shared "$anonymous"
    [[ $LAB/bind == /var/tmp/vpsctl-backup-acceptance-*/bind && ! -L $LAB/bind ]] || exit 3
    rm -rf -- "$LAB/bind"
    # The image archive must be the only remaining source of fixture images.
    mapfile -t images < <(jq -r '.inventory.containers[] | .original_image_id, .restore_image_id' "$LAB/docker-download/manifest.json" | sort -u)
    for image in "${images[@]}"; do
        if docker image inspect "$image" >/dev/null 2>&1; then docker image rm -f "$image"; fi
    done
    for image in "${images[@]}"; do ! docker image inspect "$image" >/dev/null 2>&1 || exit 1; done
    cli system backup-docker restore acceptance-s3 "$snapshot" --payload "$LAB/docker-download" \
        --bind-map "$LAB/bind=$LAB/restored-bind"
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-main) == true ]]
    [[ $(docker inspect -f '{{.State.Running}}' vpsctl-backup-test-stopped) == false ]]
    docker exec vpsctl-backup-test-main sh -c 'test "$(cat /shared/named.txt)" = named-shared-content; test "$(cat /anonymous/anonymous.txt)" = anonymous-content; test "$(cat /root/writable.txt)" = writable-layer-content; test "$(stat -c %a /shared/named.txt)" = 640'
    docker cp vpsctl-backup-test-stopped:/root/stopped.txt "$LAB/stopped-restored.txt"
    [[ $(cat "$LAB/stopped-restored.txt") == stopped-writable-layer ]]
    [[ $(cat "$LAB/restored-bind/upload.txt") == uploaded-business-file ]]
    python3 - "$LAB/restored-bind/business.db" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
assert db.execute('pragma integrity_check').fetchone() == ('ok',)
assert db.execute('select * from invoices order by id').fetchall() == [(1, 1250, 'paid'), (2, 875, 'open')]
PY
    docker inspect vpsctl-backup-test-main vpsctl-backup-test-stopped > "$LAB/evidence/docker-restored-inspect.json"
    python3 - "$LAB/docker-download/manifest.json" "$LAB/evidence/docker-restored-inspect.json" <<'PY'
import json, sys
manifest, restored = (json.load(open(path)) for path in sys.argv[1:])
original = {c['Name'].lstrip('/'): c for c in manifest['inventory']['containers']}
for container in restored:
    source = original[container['Name'].lstrip('/')]
    assert container['Image'] == source['restore_image_id']
volumes = [next(m['Name'] for m in c['Mounts'] if m['Destination'] == '/shared') for c in restored]
assert len(set(volumes)) == 1, 'shared volume association was lost'
PY
    echo 'PASS: source containers, images, volumes and bind data removed; business bytes/SQLite/writable image/shared volume/states restored'
    ;;
status)
    date -u +%FT%TZ
    df -h "$LAB"
    du -sh "$LAB"
    docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}'
    ;;
*) echo 'Usage: services|repos|storage-roundtrip|docker-fixture|docker-backup|docker-destroy-restore|compose-fixture|compose-stop-restore|sqlite-online-restore|docker-space-failure|host-shared-writer|storage-interrupted-upload|repository-auth-denied|status'; exit 2 ;;
esac
