#!/usr/bin/env bash
# Orchestration fault injection; never runs ReaR or stops native services.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2030,SC2031,SC2034,SC2317 # Subshell fixtures and public command globals.
set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TEMP"' EXIT
export VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$TEST_TEMP/system" VPSCTL_NON_INTERACTIVE=1 VPSCTL_NO_COLOR=1 VPSCTL_ASSUME_YES=1
mkdir -p "$VPSCTL_SYSTEM_ROOT"
# shellcheck source=../../commands/system/backup.sh
source "$TEST_ROOT/commands/system/backup.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
equal() { [[ "$1" == "$2" ]] || fail "$3: expected $1, got $2"; }
contains() { [[ "$1" == *"$2"* ]] || fail "$3: missing $2"; }
event() { printf '%s\n' "$*" >>"$TEST_TEMP/events"; }
invoke() {
    STATUS=0
    OUTPUT="$("$@" 2>&1)" || STATUS=$?
}

vps_cmd_init system-backup "$BS_ROOT"
backup_init "$BS_ROOT"
invoke bs_parse run p --unknown
equal 2 "$STATUS" 'unknown option'
invoke bs_parse configure p --repo repo
equal 2 "$STATUS" 'required work directory'
invoke bs_parse run p --network dhcp
equal 2 "$STATUS" 'irrelevant option rejected'
invoke bs_parse configure p --repo repo --work-dir '/unsafe space'
equal 2 "$STATUS" 'unsupported ReaR whitespace diagnosed'
invoke bs_parse run --non-interactive --yes p
equal 0 "$STATUS" 'scheduler global option placement'
invoke bs_parse restore --repo repo --snapshot latest --work-dir /mnt/preserve
equal 2 "$STATUS" 'mutable snapshot alias rejected'
invoke bs_require_rescue
equal 3 "$STATUS" 'normal OS recovery gate'
invoke bs_rear_version_at_least 'Relax-and-Recover 2.7 / Git' 2 9
equal 1 "$STATUS" 'known incompatible Debian13 ReaR version rejected'
invoke bs_rear_version_at_least 'Relax-and-Recover 2.9 / 2025-01-31' 2 9
equal 0 "$STATUS" 'pinned upstream version accepted'
(
    mkdir -p "$VPSCTL_SYSTEM_ROOT/bin" "$VPSCTL_SYSTEM_ROOT/usr/sbin" "$VPSCTL_SYSTEM_ROOT/usr/share/rear/conf"
    printf '#!/bin/bash\nexit 0\n' >"$VPSCTL_SYSTEM_ROOT/bin/rear"
    chmod 0700 "$VPSCTL_SYSTEM_ROOT/bin/rear"
    ln -s ../../bin/rear "$VPSCTL_SYSTEM_ROOT/usr/sbin/rear"
    : >"$VPSCTL_SYSTEM_ROOT/usr/share/rear/conf/default.conf"
    bs_rear_select "$VPSCTL_SYSTEM_ROOT/bin/rear"
    equal "$VPSCTL_SYSTEM_ROOT/usr/share/rear" "$BS_REAR_SHARE" 'native ISO /bin alias keeps standard share directory'
)
(
    curl() {
        local previous='' argument output=''
        for argument in "$@"; do
            [[ "$previous" != --output ]] || output="$argument"
            previous="$argument"
        done
        printf 'corrupt upstream download' >"$output"
    }
    invoke bs_rear_install_pinned "$BACKUP_STATE/tools/rear-2.9"
    equal 20 "$STATUS" 'changed upstream asset rejected before execution'
    [[ ! -e "$BACKUP_STATE/tools/rear-2.9" ]] || fail 'corrupt release was installed'
)
invoke bs_dns_address '1.1.1.999'
equal 2 "$STATUS" 'invalid resolver address'
invoke bs_dns_address '2606:4700:4700::1111'
equal 0 "$STATUS" 'IPv6 resolver address'
BS_NETWORK=dhcp BS_DNS=() BS_RESTORE_MANIFEST='{"network":{"resolved_available":false,"nameservers":["127.0.0.53","::1"]}}'
invoke bs_dns_plan
equal 3 "$STATUS" 'stub DNS without target resolver rejected'
BS_DNS=(10.0.2.3)
invoke bs_dns_plan
equal 0 "$STATUS" 'explicit DNS satisfies recovery network'

(
    # Real sealed tar files, with only the target-disk and ReaR boundaries
    # replaced. Both public restore paths must reject before reaching ReaR.
    BS_WORK="$TEST_TEMP/network-restore" BS_SNAPSHOT="$(printf '%064d' 3)" BS_REPO=repo
    BS_NETWORK=dhcp BS_DNS=(1.1.1.1) BS_CONFIRM=fixture-token VPSCTL_DRY_RUN=0
    payload="$BS_WORK/$BS_SNAPSHOT/payload" tree="$TEST_TEMP/network-tree"
    mkdir -p "$payload"/{iso,netfs/system,rear-state/layout} "$tree"
    printf '%s\n' "$BS_SNAPSHOT" >"$BS_WORK/$BS_SNAPSHOT/snapshot-id"
    printf 'iso fixture\n' >"$payload/iso/rescue.iso"
    printf 'disk /dev/vda 1073741824 gpt\n' >"$payload/rear-state/layout/disklayout.conf"
    jq -nc '{schema_version:1,type:"system",plan_id:"old-plan",job_id:"old-job",source_host:"source",captured_at:"2026-10-30T00:00:00Z",rear:{backend:"NETFS",program:"tar",url_relative:"netfs",prefix:"system",archive:"backup",suffix:".tar",compression:"none",iso:"iso/rescue.iso"}}' >"$payload/manifest.json"
    bs_need_read_tools() { :; }
    bs_disk_plan() { bs_dns_plan || return $?; BS_RESTORE_PLAN='{}'; BS_RESTORE_TOKEN=fixture-token; }
    bs_require_rescue() { event unexpected-rescue; return 0; }
    bs_prepare_rear_restore() { event unexpected-prepare; return 77; }
    bs_rear() { event unexpected-rear; return 77; }
    seal_network_tar() {
        if (($#)); then tar -cf "$payload/netfs/system/backup.tar" -C "$tree" "$@";
        else tar -cf "$payload/netfs/system/backup.tar" -C "$tree" .; fi
        backup_payload_index "$payload" >"$payload/.vpsctl-files.json"
    }
    network_rejected() {
        local action
        for action in restore-plan restore; do
            : >"$TEST_TEMP/events"
            BS_ACTION="$action"
            invoke bs_restore
            equal 3 "$STATUS" "$action: $1"
            contains "$OUTPUT" '--network preserve' 'missing DHCP component has an actionable alternative'
            [[ ! -s "$TEST_TEMP/events" ]] || fail 'failed DHCP preflight reached ReaR'
        done
    }
    network_accepted() {
        BS_ACTION=restore-plan
        invoke bs_restore
        equal 0 "$STATUS" "$1"
    }
    seal_network_tar
    network_rejected 'missing networkd unit'
    BS_NETWORK=preserve
    network_accepted 'preserve does not require networkd or resolved'
    BS_NETWORK=dhcp
    mkdir -p "$tree/usr/lib/systemd/system"
    printf '[Service]\nExecStart=/usr/lib/systemd/systemd-networkd\n' >"$tree/usr/lib/systemd/system/systemd-networkd.service"
    seal_network_tar
    network_rejected 'missing networkd executable'
    printf '#!/bin/sh\ntouch %s/archived-program-ran\n' "$TEST_TEMP" >"$tree/usr/lib/systemd/systemd-networkd"
    chmod 0600 "$tree/usr/lib/systemd/systemd-networkd"
    seal_network_tar
    network_rejected 'non-executable networkd'
    chmod 0755 "$tree/usr/lib/systemd/systemd-networkd"
    seal_network_tar
    network_accepted 'old schema 1 without network metadata and ./ usr/lib layout'
    jq '.network={resolved_available:true}' "$payload/manifest.json" >"$payload/manifest.new"
    mv "$payload/manifest.new" "$payload/manifest.json"
    BS_DNS=()
    seal_network_tar
    network_rejected 'resolved strategy requires its unit'
    printf '[Service]\nExecStart=/usr/lib/systemd/systemd-resolved\n' >"$tree/usr/lib/systemd/system/systemd-resolved.service"
    seal_network_tar
    network_rejected 'resolved strategy requires its executable'
    cp "$tree/usr/lib/systemd/systemd-networkd" "$tree/usr/lib/systemd/systemd-resolved"
    seal_network_tar
    network_accepted 'resolved strategy with both components'
    rm "$tree/usr/lib/systemd/systemd-resolved" "$tree/usr/lib/systemd/system/systemd-resolved.service"
    BS_DNS=(1.1.1.1)
    seal_network_tar
    network_accepted 'explicit DNS does not require resolved despite manifest hint'

    mkdir -p "$tree/etc/systemd/system" "$tree/usr/bin"
    ln -s usr/lib "$tree/lib"
    ln -s /lib/systemd/system/systemd-networkd.service "$tree/etc/systemd/system/systemd-networkd.service"
    printf '[Service]\nExecStart=!!/lib/systemd/systemd-networkd --fixture\n' >"$tree/usr/lib/systemd/system/systemd-networkd.service"
    mv "$tree/usr/lib/systemd/systemd-networkd" "$tree/usr/bin/systemd-networkd"
    ln -s ../../bin/systemd-networkd "$tree/usr/lib/systemd/systemd-networkd"
    seal_network_tar
    network_accepted 'absolute unit link, relative program link and merged /lib alias'
    rm "$tree/usr/lib/systemd/systemd-networkd"
    ln "$tree/usr/bin/systemd-networkd" "$tree/usr/lib/systemd/systemd-networkd"
    seal_network_tar usr/bin/systemd-networkd etc lib usr/lib
    network_accepted 'hardlinked executable resolves to archive member'
    mkdir -p "$tree/usr/lib/systemd/system/service.d"
    printf '[Service]\nTimeoutStopSec=90\n' >"$tree/usr/lib/systemd/system/service.d/timeout.conf"
    seal_network_tar
    network_accepted 'unrelated global service drop-in remains compatible'
    printf '[Service]\nExecStart=\nExecStart=/missing/systemd-networkd\n' >"$tree/usr/lib/systemd/system/service.d/timeout.conf"
    seal_network_tar
    network_rejected 'drop-in startup override is diagnosed'
    rm "$tree/usr/lib/systemd/system/service.d/timeout.conf"
    rm "$tree/etc/systemd/system/systemd-networkd.service"
    ln -s /dev/null "$tree/etc/systemd/system/systemd-networkd.service"
    seal_network_tar
    network_rejected 'masked unit must not fall through to vendor unit'
    rm "$tree/etc/systemd/system/systemd-networkd.service"
    printf '[Service]\nExecStart=/missing/systemd-networkd\n' >"$tree/usr/lib/systemd/system/systemd-networkd.service"
    seal_network_tar
    network_rejected 'same-name binary elsewhere cannot satisfy selected ExecStart'
    printf '[Service]\nExecStart=/bin/sh -c systemd-networkd\n' >"$tree/usr/lib/systemd/system/systemd-networkd.service"
    seal_network_tar
    network_rejected 'custom shell startup is not guessed'
    [[ ! -e "$TEST_TEMP/archived-program-ran" ]] || fail 'archive executable was run during preflight'
)

(
    systemctl() { printf '123\n'; }
    pgrep() { printf '%s\n' "$MOCK_DAEMONS"; }
    ps() { printf '0\n'; }
    MOCK_DAEMONS=123
    invoke bs_check_docker_owner
    equal 0 "$STATUS" 'single managed rootful daemon'
    MOCK_DAEMONS=$'123\n456'
    invoke bs_check_docker_owner
    equal 3 "$STATUS" 'second dockerd cannot be silently left writing'
    ctr() { if [[ "$1" == namespaces ]]; then printf 'moby\n'; else printf '%s\n' "$MOCK_TASKS"; fi; }
    MOCK_TASKS=known-container
    invoke bs_check_containerd_tasks known-container
    equal 0 "$STATUS" 'Docker-owned moby task'
    MOCK_TASKS=$'known-container\nforeign-task'
    invoke bs_check_containerd_tasks known-container
    equal 3 "$STATUS" 'foreign moby task prevents shared daemon stop'
)

(
    bs_parse inspect
    bs_platform() { :; }
    findmnt() { printf '{"filesystems":[{"target":"/","source":"/dev/vda1","fstype":"ext4"},{"target":"/sys/fs/bpf","source":"bpf","fstype":"bpf"},{"target":"/mnt/external","source":"server:/data","fstype":"nfs4"}]}\n'; }
    lsblk() { printf '{"blockdevices":[{"name":"/dev/vda1","type":"part","fstype":"ext4","mountpoint":"/"}]}\n'; }
    bs_inventory
    equal runtime "$(jq -r '.mounts[]|select(.target=="/sys/fs/bpf")|.coverage' <<<"$BS_INVENTORY")" 'BPF is runtime'
    equal unresolved "$(jq -r '.mounts[]|select(.target=="/mnt/external")|.coverage' <<<"$BS_INVENTORY")" 'external storage never silently covered'
    before="$(bs_persistent_mounts)"
    BS_INVENTORY="$(jq '.mounts |= map(select(.coverage!="runtime"))' <<<"$BS_INVENTORY")"
    equal "$before" "$(bs_persistent_mounts)" 'runtime disappearance does not invalidate persistent capture'
)

# The local NETFS contract must not accidentally inherit the source hostname or
# gzip defaults. ReaR's output directory cannot recursively enter its archive.
(
    # BIOS module selection and final-image checks are independent of the full
    # VM boot acceptance. External ISO extraction is stubbed at one boundary.
    bios="$VPSCTL_SYSTEM_ROOT/usr/lib/syslinux/modules/bios"
    mkdir -p "$bios" "$VPSCTL_SYSTEM_ROOT/usr/lib/ISOLINUX" "$TEST_TEMP/iso-job"
    printf 'ISOLINUX 6.04 20250413\n' >"$VPSCTL_SYSTEM_ROOT/usr/lib/ISOLINUX/isolinux.bin"
    for module in ldlinux.c32 libcom32.c32 libutil.c32 menu.c32 chain.c32; do printf 'fixture-%s\n' "$module" >"$bios/$module"; done
    extlinux() { printf 'extlinux %s\n' "$MOCK_EXTLINUX_VERSION"; }
    strings() { cat "$1"; }
    dpkg-query() { printf '6.04-7\n6.04-7\n6.04-7\n'; }
    MOCK_EXTLINUX_VERSION=6.04
    bs_bios_assets
    equal "$bios" "$BS_SYSLINUX_MODULES" 'explicit BIOS module directory'
    MOCK_EXTLINUX_VERSION=2.9
    invoke bs_bios_assets
    equal 3 "$STATUS" 'ReaR pathname version cannot masquerade as Syslinux ABI'
    MOCK_EXTLINUX_VERSION=6.04
    bs_bios_assets
    BACKUP_JOB_DIR="$TEST_TEMP/iso-job"
    xorriso() {
        local previous='' argument member='' destination="${*: -1}"
        for argument in "$@"; do
            [[ "$previous" != -extract ]] || member="${argument##*/}"
            previous="$argument"
        done
        [[ "$member" != "${MOCK_MISSING_MODULE:-}" ]] || return 1
        cp "$bios/$member" "$destination"
    }
    invoke bs_verify_iso_boot_files "$TEST_TEMP/new.iso"
    equal 0 "$STATUS" 'complete image module set accepted'
    MOCK_MISSING_MODULE=ldlinux.c32
    invoke bs_verify_iso_boot_files "$TEST_TEMP/new.iso"
    equal 20 "$STATUS" 'missing ISO loader module prevents complete snapshot'
    rm "$bios/ldlinux.c32"
    invoke bs_bios_assets
    equal 3 "$STATUS" 'missing source loader module rejected before stop'
)

BS_INVENTORY='{"mounts":[{"target":"/","coverage":"included"},{"target":"/mnt/preserve","coverage":"excluded-staging"}]}'
BS_WORK=/mnt/preserve/staging BACKUP_PAYLOAD_DIR=/mnt/preserve/staging/job/payload
BS_EXCLUDE_PATHS=(/opt/cache) BS_EXCLUDE_DEVICES=() BS_STAGING_DISKS=/dev/vdb
bs_rear_config "$TEST_TEMP/local.conf"
config="$(cat "$TEST_TEMP/local.conf")"
contains "$config" 'NETFS_PREFIX=system' 'stable prefix'
contains "$config" 'BACKUP_PROG_COMPRESS_OPTIONS=()' 'uncompressed tar'
contains "$config" 'BACKUP_PROG_WARN_PARTIAL_TRANSFER=' 'partial tar cannot count as complete'
contains "$config" '/mnt/preserve/staging' 'recursive exclusion'
contains "$config" 'EXCLUDE_COMPONENTS+=( /dev/vdb )' 'holding disk excluded from recreation'

(
    helper_fixture="$TEST_TEMP/ssh-helpers"
    mkdir -p "$helper_fixture"/{defaults,custom,lib}
    for helper in defaults/sshd-session defaults/sshd-auth custom/sshd-auth; do
        printf '#!/bin/sh\nexit 0\n' >"$helper_fixture/$helper"
        chmod 0700 "$helper_fixture/$helper"
    done
    ln -s "$helper_fixture/defaults/sshd-session" "$helper_fixture/custom/sshd-session"
    for library in libwrap.so.0 libwtmpdb.so.0 libsqlite3.so.0; do : >"$helper_fixture/lib/$library"; done
    sshd() {
        if [[ "${MOCK_SSH_LEGACY:-0}" == 1 ]]; then
            printf 'port 22\n'
            return
        fi
        local directory=custom
        (($# == 1)) || directory=defaults
        printf 'sshdsessionpath %s/%s/sshd-session\nsshdauthpath %s/%s/sshd-auth\n' "$helper_fixture" "$directory" "$helper_fixture" "$directory"
    }
    ldd() {
        if [[ "${MOCK_SSH_MISSING_LIBRARY:-0}" == 1 ]]; then
            printf 'libwtmpdb.so.0 => not found\n'
            return
        fi
        local library
        for library in libwrap.so.0 libwtmpdb.so.0 libsqlite3.so.0; do printf '%s => %s/lib/%s (0x1234)\n' "$library" "$helper_fixture" "$library"; done
    }
    bs_discover_ssh_helpers
    equal 4 "${#BS_SSH_HELPERS[@]}" 'effective and compiled helpers include symlink target once'
    equal 3 "${#BS_SSH_HELPER_LIBS[@]}" 'transitive SSH helper libraries retained'
    bs_rear_config "$TEST_TEMP/ssh-helper-rear.conf"
    config="$(cat "$TEST_TEMP/ssh-helper-rear.conf")"
    contains "$config" "COPY_AS_IS+=( $helper_fixture/custom/sshd-session )" 'helper libexec path preserved'
    contains "$config" "LIBS+=( $helper_fixture/lib/libsqlite3.so.0 )" 'indirect wtmpdb SQLite dependency retained'
    MOCK_SSH_MISSING_LIBRARY=1
    invoke bs_discover_ssh_helpers
    equal 3 "$STATUS" 'unresolved SSH helper library rejected before capture'
    MOCK_SSH_MISSING_LIBRARY=0 MOCK_SSH_LEGACY=1
    bs_discover_ssh_helpers
    equal 0 "${#BS_SSH_HELPERS[@]}" 'older monolithic sshd needs no split helpers'
)

(
    bs_create_tar_wrapper "$TEST_TEMP/tar-wrapper"
    invoke "$BS_REAR_TAR" --ignore-failed-read -c -f "$TEST_TEMP/incomplete.tar" "$TEST_TEMP/definitely-missing-source"
    equal 2 "$STATUS" 'native tar read failures remain fatal despite ReaR ignore option'
    equal 2 "$(cat "$BS_REAR_TAR_STATUS")" 'capture exit is recorded independently of ReaR tolerance'
    bs_rear_config "$TEST_TEMP/strict-capture.conf"
    config="$(cat "$TEST_TEMP/strict-capture.conf")"
    contains "$config" $'BACKUP_PROG=tar\n' 'ISO builder receives native GNU tar'
    contains "$config" PRE_BACKUP_SCRIPT=BACKUP_PROG= 'wrapper activates only in backup stage after ISO output'
)

(
    # A previous full staging archive must not be counted as source data again.
    BS_WORK="$TEST_TEMP/space-source/staging" BS_EXCLUDE_PATHS=()
    mkdir -p "$BS_WORK"
    dd if=/dev/zero of="$TEST_TEMP/space-source/business" bs=1M count=1 status=none
    dd if=/dev/zero of="$BS_WORK/previous-archive" bs=1M count=8 status=none
    BS_INVENTORY="$(jq -nc --arg mount "$TEST_TEMP/space-source" '{mounts:[{target:$mount,coverage:"included"}]}')"
    df() { printf 'Available\n1077936128\n'; }
    invoke bs_space_check
    equal 0 "$STATUS" 'excluded old archive does not inflate source estimate'
)

# Replace only OS/repository boundaries. Capture, cleanup, immutable pre-stop
# state, host-wide lock, job state and retry sequencing stay real.
(
    coverage_fixture="$(mktemp -d /var/tmp/vpsctl-backup-system-path.XXXXXX)"
    trap 'rm -rf -- "$coverage_fixture"' EXIT
    mkdir -p "$coverage_fixture/normal" "$TEST_TEMP/excluded-data"
    ln -s "$TEST_TEMP/excluded-data" "$coverage_fixture/indirect"
    BS_WORK=/var/lib/vpsctl/backup/staging BS_EXCLUDE_PATHS=()
    BS_INVENTORY='{"mounts":[{"target":"/","coverage":"included"}]}'
    findmnt() { printf '/\n'; }
    invoke bs_path_covered "$coverage_fixture/normal"
    equal 0 "$STATUS" 'ordinary persistent path covered'
    invoke bs_path_covered "$TEST_TEMP/excluded-data"
    equal 3 "$STATUS" 'fixed excluded tmp data cannot be marked covered'
    invoke bs_path_covered "$coverage_fixture/indirect"
    equal 3 "$STATUS" 'symlink into excluded tmp data cannot bypass coverage'
)

(
    # Exercise the exported entrypoint, only omitting duplicate tool binaries.
    # Its checksum verification, validation, lock, installs and publication run.
    export VPSCTL_SYSTEM_ROOT="$TEST_TEMP/import-system" VPSCTL_DRY_RUN=0
    mkdir -p "$VPSCTL_SYSTEM_ROOT" "$TEST_TEMP/import-inputs" "$TEST_TEMP/import-shims"
    backup_init "$BS_ROOT"
    bs_load_plan() { :; }
    backup_ensure_tools() { :; }
    bs_export_tool() { mkdir -p "$2/bin"; }
    backup_tool_versions() { printf '{}\n'; }
    backup_repo_load() { BACKUP_REPO_JSON="$export_config"; }
    for name in a b; do
        printf 'password-%s\n' "$name" >"$TEST_TEMP/import-inputs/$name.password"
        printf '{"access_key_id":"key-%s","secret_access_key":"secret-%s"}\n' "$name" "$name" >"$TEST_TEMP/import-inputs/$name.credentials"
        printf 'CA-%s\n' "$name" >"$TEST_TEMP/import-inputs/$name.ca"
    done
    chmod 0600 "$TEST_TEMP/import-inputs/"*
    make_kit() {
        local id="$1" name="${2:-a}" kind="${3:-s3}"
        BS_REPO="$id" BS_OUTPUT="$TEST_TEMP/kit-$id"
        export_config="$(jq -nc --arg id "$id" --arg type "$kind" --arg inputs "$TEST_TEMP/import-inputs/$name" \
            '{schema_version:1,id:$id,type:$type,password_file:($inputs+".password"),credentials_file:($inputs+".credentials"),ca_file:($inputs+".ca"),pack_size:16,connections:2,timeout:60,allow_http:false,endpoint:"https://storage.example",bucket:"backup",region:"",bucket_lookup:"auto",prefix:"",path:"/backup"}')"
        bs_export >/dev/null
    }
    reseal_kit() {
        # shellcheck disable=SC2094
        (cd "$1" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
    }
    no_import_published() {
        [[ ! -d "$BACKUP_ETC/repos" || -z "$(find "$BACKUP_ETC/repos" -mindepth 1 -print -quit)" ]] || fail 'invalid input published a repository'
        [[ ! -d "$BACKUP_ETC/secrets" || -z "$(find "$BACKUP_ETC/secrets" -mindepth 1 -print -quit)" ]] || fail 'invalid input left secrets'
    }
    imported_files() { find "$BACKUP_ETC" -type f -exec sha256sum {} + | sort; }
    make_kit a
    make_kit b b
    make_kit failed
    make_kit local a local
    inputs="$TEST_TEMP/import-inputs"
    invoke bash "$TEST_TEMP/kit-a/recover.sh" import-repo "$inputs/a.password"
    equal 2 "$STATUS" 'remote import validates credential argument before copying password'
    no_import_published
    invoke bash "$TEST_TEMP/kit-local/recover.sh" import-repo "$inputs/a.password" "$inputs/a.credentials" extra
    equal 2 "$STATUS" 'import rejects extra arguments'
    no_import_published
    : >"$inputs/empty"
    chmod 0600 "$inputs/empty"
    invoke bash "$TEST_TEMP/kit-a/recover.sh" import-repo "$inputs/empty" "$inputs/a.credentials"
    equal 10 "$STATUS" 'empty import password rejected'
    no_import_published
    chmod 0644 "$inputs/a.password"
    invoke bash "$TEST_TEMP/kit-a/recover.sh" import-repo "$inputs/a.password" "$inputs/a.credentials"
    equal 10 "$STATUS" 'public import password rejected'
    chmod 0600 "$inputs/a.password"
    no_import_published
    printf '{}\n' >"$inputs/invalid.credentials"
    chmod 0600 "$inputs/invalid.credentials"
    invoke bash "$TEST_TEMP/kit-a/recover.sh" import-repo "$inputs/a.password" "$inputs/invalid.credentials"
    equal 10 "$STATUS" 'invalid credential JSON rejected before any publication'
    no_import_published
    rm "$TEST_TEMP/kit-failed/ca.crt"
    reseal_kit "$TEST_TEMP/kit-failed"
    invoke bash "$TEST_TEMP/kit-failed/recover.sh" import-repo "$inputs/a.password" "$inputs/a.credentials"
    equal 3 "$STATUS" 'required CA must be readable before publication'
    no_import_published
    cp "$inputs/a.ca" "$TEST_TEMP/kit-failed/ca.crt"
    cp "$TEST_TEMP/kit-failed/repository.json" "$TEST_TEMP/valid-repository.json"
    jq '.pack_size=0' "$TEST_TEMP/valid-repository.json" >"$TEST_TEMP/kit-failed/repository.json"
    reseal_kit "$TEST_TEMP/kit-failed"
    invoke bash "$TEST_TEMP/kit-failed/recover.sh" import-repo "$inputs/a.password" "$inputs/a.credentials"
    equal 10 "$STATUS" 'invalid repository JSON rejected before publication'
    no_import_published
    cp "$TEST_TEMP/valid-repository.json" "$TEST_TEMP/kit-failed/repository.json"
    reseal_kit "$TEST_TEMP/kit-failed"

    invoke bash "$TEST_TEMP/kit-a/recover.sh" import-repo "$inputs/a.password" "$inputs/a.credentials"
    equal 0 "$STATUS" 'first exported repository imports'
    first_files="$(imported_files)"
    invoke bash "$TEST_TEMP/kit-b/recover.sh" import-repo "$inputs/b.password" "$inputs/b.credentials"
    equal 0 "$STATUS" 'second exported repository imports'
    for field in password_file credentials_file ca_file; do
        first="$(jq -r --arg field "$field" '.[$field]' "$BACKUP_ETC/repos/a.json")"
        second="$(jq -r --arg field "$field" '.[$field]' "$BACKUP_ETC/repos/b.json")"
        [[ "${first%/*}" != "${second%/*}" ]] || fail 'imported repositories share a secret directory'
        equal 600 "$(stat -c %a "$first")" 'imported secret file is private'
        equal 700 "$(stat -c %a "${first%/*}")" 'imported secret directory is private'
        case "$field" in password_file) suffix=password ;; credentials_file) suffix=credentials ;; ca_file) suffix=ca ;; esac
        cmp "$inputs/a.$suffix" "$first" || fail 'second import changed first secret'
        cmp "$inputs/b.$suffix" "$second" || fail 'second import has wrong secret'
    done
    sha256sum --status -c <<<"$first_files" || fail 'first repository and secret checksums changed'
    before="$(imported_files)"
    directories="$(find "$BACKUP_ETC/secrets" -mindepth 1 -type d | sort)"
    invoke bash "$TEST_TEMP/kit-a/recover.sh" import-repo "$inputs/b.password" "$inputs/b.credentials"
    equal 3 "$STATUS" 'same ID import rejected'
    equal "$before" "$(imported_files)" 'same ID rejection leaves all existing secrets intact'
    vps_cmd_lock backup-repo-config
    invoke bash "$TEST_TEMP/kit-failed/recover.sh" import-repo "$inputs/a.password" "$inputs/a.credentials"
    equal 3 "$STATUS" 'import shares the repository configuration lock'
    vps_cmd_unlock
    export REAL_INSTALL
    REAL_INSTALL="$(command -v install)"
    cat >"$TEST_TEMP/import-shims/install" <<'SHIM'
#!/usr/bin/env bash
[[ "${*: -1}" != */credentials.json ]] || exit 1
exec "$REAL_INSTALL" "$@"
SHIM
    chmod 0700 "$TEST_TEMP/import-shims/install"
    invoke env PATH="$TEST_TEMP/import-shims:$PATH" bash "$TEST_TEMP/kit-failed/recover.sh" import-repo "$inputs/a.password" "$inputs/a.credentials"
    equal 20 "$STATUS" 'failed secret copy is propagated'
    equal "$before" "$(imported_files)" 'failed install never deletes existing secrets'
    equal "$directories" "$(find "$BACKUP_ETC/secrets" -mindepth 1 -type d | sort)" 'failed install removes only its own secret directory'
    rm "$TEST_TEMP/import-shims/install"
    printf '#!/bin/sh\nexit 1\n' >"$TEST_TEMP/import-shims/mv"
    chmod 0700 "$TEST_TEMP/import-shims/mv"
    invoke env PATH="$TEST_TEMP/import-shims:$PATH" bash "$TEST_TEMP/kit-failed/recover.sh" import-repo "$inputs/a.password" "$inputs/a.credentials"
    equal 20 "$STATUS" 'failed atomic publication is propagated'
    equal "$before" "$(imported_files)" 'failed publication leaves existing repositories and secrets intact'
    equal "$directories" "$(find "$BACKUP_ETC/secrets" -mindepth 1 -type d | sort)" 'failed publication removes only its own secret directory'
    export REAL_MV
    REAL_MV="$(command -v mv)"
    cat >"$TEST_TEMP/import-shims/mv" <<'SHIM'
#!/usr/bin/env bash
"$REAL_MV" "$@" || exit $?
kill -TERM "$PPID"
SHIM
    invoke env PATH="$TEST_TEMP/import-shims:$PATH" bash "$TEST_TEMP/kit-failed/recover.sh" import-repo "$inputs/a.password" "$inputs/a.credentials"
    equal 143 "$STATUS" 'termination immediately after publication is propagated'
    published_password="$(jq -r .password_file "$BACKUP_ETC/repos/failed.json")"
    cmp "$inputs/a.password" "$published_password" || fail 'late termination deleted published secrets'
    invoke bash "$TEST_TEMP/kit-local/recover.sh" import-repo "$inputs/a.password" "$inputs/a.credentials"
    equal 0 "$STATUS" 'local import preserves compatibility with an ignored second argument'
)

backup_ensure_tools() { :; }
bs_platform() { :; }
bs_prepare_rear() { :; }
bs_rear_capabilities() { :; }
bs_inventory() { BS_INVENTORY='{"mounts":[{"target":"/","source":"/dev/vda1","fstype":"ext4","coverage":"included"}]}'; }
bs_check_coverage() { :; }
bs_space_check() {
    event space
    return "${MOCK_SPACE:-0}"
}
bs_discover_writers() {
    BS_SERVICE_STATE='{"schema_version":1,"units":[{"unit":"database.service","active":true,"send_sigkill":"yes"},{"unit":"already-stopped.service","active":false,"send_sigkill":"yes"}],"containers":[{"id":"running-container","running":true},{"id":"stopped-container","running":false}]}'
}
backup_restic() { event repo-check; }
backup_cleanup_completed() { event cleanup-completed; }
backup_maintain_completed() {
    event maintenance
    return "${MOCK_MAINTENANCE:-0}"
}
bs_capture_material() {
    event capture
    BS_CAPTURED_AT=2026-10-30T00:00:00Z
    return "${MOCK_CAPTURE:-0}"
}
backup_upload_job() {
    event upload
    [[ "${MOCK_UPLOAD:-0}" == 0 ]] || return "$MOCK_UPLOAD"
    printf '%064d\n' 1
}
timeout() {
    shift 2
    "$@"
}
systemctl() {
    local unit="${*: -1}"
    case "$1" in
        daemon-reload) event daemon-reload ;;
        stop)
            event "stop:$unit"
            [[ "${MOCK_STOP:-0}" == 0 ]] || return "$MOCK_STOP"
            printf 'inactive\n' >"$TEST_TEMP/unit-state"
            ;;
        show)
            case "$3" in ActiveState) cat "$TEST_TEMP/unit-state" ;; Result) printf 'success\n' ;; ExecMainStatus) printf '0\n' ;; SendSIGKILL) printf 'no\n' ;; esac
            ;;
        start)
            event "start:$unit"
            [[ "${MOCK_START:-0}" == 0 ]] || return "$MOCK_START"
            printf 'active\n' >"$TEST_TEMP/unit-state"
            ;;
        is-active) [[ "$(cat "$TEST_TEMP/unit-state")" == active ]] ;;
        *) fail "unexpected systemctl $*" ;;
    esac
}
docker() {
    case "$1" in
        stop)
            event "container-stop:${*: -1}"
            printf 'false\n' >"$TEST_TEMP/container-state"
            ;;
        start)
            event "container-start:$2"
            printf 'true\n' >"$TEST_TEMP/container-state"
            ;;
        inspect)
            if [[ "${2:-}" == --format ]]; then
                cat "$TEST_TEMP/container-state"
            else printf '[{"State":{"Running":false,"OOMKilled":false,"ExitCode":0}}]\n'; fi
            ;;
        *) fail "unexpected docker $*" ;;
    esac
}
new_case() {
    : >"$TEST_TEMP/events"
    printf 'active\n' >"$TEST_TEMP/unit-state"
    printf 'true\n' >"$TEST_TEMP/container-state"
    MOCK_STOP=0 MOCK_START=0 MOCK_CAPTURE=0 MOCK_UPLOAD=0 MOCK_SPACE=0 MOCK_MAINTENANCE=0
    VPSCTL_DRY_RUN=0
    bs_parse run system-plan --yes
    backup_plan_write system-plan system "$(jq -nc --arg work "$TEST_TEMP/work" '{schema_version:1,id:"system-plan",type:"system",repo:"repo",work_dir:$work,retention:{daily:7,weekly:4,monthly:6},options:{exclude_mounts:[],exclude_devices:[],exclude_paths:[],stop_services:[],private_containerd:[]}}')"
}

new_case
invoke bs_run
equal 0 "$STATUS" 'successful capture'
events="$(cat "$TEST_TEMP/events")"
contains "$events" $'capture\ndaemon-reload\nstart:database.service\ncontainer-start:running-container\nupload' 'services restored before upload'
[[ "$events" != *'start:already-stopped'* && "$events" != *'container-start:stopped-container'* ]] || fail 'original stopped state changed'

new_case
MOCK_STOP=1
invoke bs_run
equal 20 "$STATUS" 'stop failure is propagated'
events="$(cat "$TEST_TEMP/events")"
[[ "$events" != *capture* && "$events" != *upload* ]] || fail 'capture after failed stop'
contains "$events" 'container-start:running-container' 'rollback after failed stop'

new_case
MOCK_CAPTURE=20
invoke bs_run
equal 20 "$STATUS" 'collection failure'
events="$(cat "$TEST_TEMP/events")"
contains "$events" 'start:database.service' 'failed capture restores service'
[[ "$events" != *upload* ]] || fail 'failed capture uploaded'

new_case
MOCK_START=1
invoke bs_run
equal 30 "$STATUS" 'restart failure is partial even with valid archive'
contains "$(cat "$TEST_TEMP/events")" upload 'valid data still uploaded after restart failure'
[[ "$(cat "$TEST_TEMP/events")" != *maintenance* ]] || fail 'pruned old recovery points while services were not restored'

new_case
MOCK_MAINTENANCE=30
invoke bs_run
equal 30 "$STATUS" 'maintenance failure is partial after completed backup'
contains "$OUTPUT" 0000000000000000000000000000000000000000000000000000000000000001 'complete snapshot still reported'

new_case
MOCK_UPLOAD=20
invoke bs_run
equal 20 "$STATUS" 'upload failure'
job="$(find "$BACKUP_STATE/jobs" -name system-state.json -exec jq -r 'select(.stage=="upload-failed")|.job_id' {} \; | tail -n 1)"
[[ -n "$job" ]] || fail 'missing retained upload-failed job'
: >"$TEST_TEMP/events"
MOCK_UPLOAD=0 BS_ID="$job"
invoke bs_retry
equal 0 "$STATUS" 'retry success'
equal $'upload\nmaintenance' "$(cat "$TEST_TEMP/events")" 'retry never recollects or stops services'
equal complete "$(jq -r .stage "$BACKUP_STATE/jobs/$job/system-state.json")" 'retry status updated'

new_case
MOCK_SPACE=3
invoke bs_run
equal 3 "$STATUS" 'space preflight'
equal $'repo-check\ncleanup-completed\nspace' "$(cat "$TEST_TEMP/events")" 'old complete staging cleanup precedes space check; no services stopped'

new_case
VPSCTL_DRY_RUN=1
invoke bs_run
equal 0 "$STATUS" 'dry run'
equal $'cleanup-completed\nspace' "$(cat "$TEST_TEMP/events")" 'dry run never locks or mutates'

# Restore accepts repo+snapshot with no old plan and verifies sealed material
# every time. This is not a disk-recovery or boot acceptance test.
VPSCTL_DRY_RUN=0
BS_WORK="$TEST_TEMP/recovery" BS_SNAPSHOT="$(printf '%064d' 2)" BS_REPO=repo
backup_restore_snapshot() {
    local target="$3"
    mkdir -p "$target"/{netfs/system,iso,rear-state/layout}
    printf 'fixture\n' >"$target/iso/rescue.iso"
    printf 'archive fixture\n' >"$target/netfs/system/backup.tar"
    printf 'disk /dev/vda 1073741824 gpt\n' >"$target/rear-state/layout/disklayout.conf"
    jq -nc '{schema_version:1,type:"system",plan_id:"lost-plan",job_id:"old-job",source_host:"source",captured_at:"2026-10-30T00:00:00Z",rear:{backend:"NETFS",program:"tar",url_relative:"netfs",prefix:"system",archive:"backup",suffix:".tar",compression:"none",iso:"iso/rescue.iso"}}' >"$target/manifest.json"
    backup_payload_index "$target" >"$target/.vpsctl-files.json"
}
invoke bs_restore_material
equal 0 "$STATUS" 'fetch without old plan'
invoke bs_restore_material
equal 0 "$STATUS" 'cached material reverified'
printf 'corrupt' >>"$BS_WORK/$BS_SNAPSHOT/payload/netfs/system/backup.tar"
invoke bs_restore_material
equal 30 "$STATUS" 'corrupt cached archive rejected'

# A successful earlier recovery hook cannot satisfy a subsequent attempt.
printf 'old-attempt\n' >"$TEST_TEMP/post-marker"
invoke bs_post_marker_matches "$TEST_TEMP/post-marker" new-attempt
equal 1 "$STATUS" 'stale completion marker rejected'
invoke bs_post_marker_matches "$TEST_TEMP/post-marker" old-attempt
equal 0 "$STATUS" 'matching hook evidence accepted'

# Linux aliases must use block identity, not the supplied pathname. No device
# is opened: these private fixture nodes are used exclusively by stat/readlink.
if ((EUID == 0)); then
    mknod "$TEST_TEMP/block-node" b 7 240
    ln -s "$TEST_TEMP/block-node" "$TEST_TEMP/block-alias"
    equal "$(bs_device_identity "$TEST_TEMP/block-node")" "$(bs_device_identity "$TEST_TEMP/block-alias")" 'disk alias identity'
fi

# A first-boot failure in one item must not leave later independent writers
# stopped or restart schedules before the business state is restored.
(
    state="$TEST_TEMP/firstboot"
    mkdir "$state"
    printf 'production\n' >"$state/mode"
    printf 'vpsctl-backup-system-plan.timer\n' >"$state/timers"
    printf '{"units":[{"unit":"later.service","active":true},{"unit":"fails.service","active":true}],"containers":[{"id":"bad","running":true},{"id":"later","running":true}]}\n' >"$state/services-before.json"
    : >"$TEST_TEMP/events"
    ssh-keygen() { :; }
    systemctl() {
        event "firstboot:$*"
        [[ "$*" != *fails.service* ]]
    }
    docker() {
        event "firstboot-container:$*"
        [[ "$*" != *bad* ]] || return 1
        [[ "$1" != inspect ]] || printf 'true\n'
    }
    invoke bs_firstboot_restore "$state"
    equal 30 "$STATUS" 'firstboot aggregates failures'
    events="$(cat "$TEST_TEMP/events")"
    contains "$events" 'later.service' 'later service restored after failed service'
    contains "$events" 'firstboot-container:start' 'containers attempted after service failure'
    contains "$events" 'later' 'later container restored after failed container'
    [[ ! -f "$state/completed" && "$events" != *enable* ]] || fail 'incomplete firstboot enabled schedules or marked completed'
    contains "$(cat "$state/failed-items")" fails.service 'failed service recorded'
    contains "$(cat "$state/failed-items")" container:bad 'failed container recorded'
)

printf 'PASS: system backup CLI, NETFS contract, stop/restart/upload failures, retry, dry-run, rescue gate and sealed restore material\n'
