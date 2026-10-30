#!/usr/bin/env bash
# Focused mapping, restart-journal, unsafe-path and CLI regression coverage.
set -Eeuo pipefail
IFS=$'\n\t'
TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
python3 - "$TEST_ROOT" <<'PY'
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("docker_backup", root / "commands/system/backup-docker/engine.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class BackupTests(unittest.TestCase):
    def container(self):
        return {"Id": "a" * 64, "Name": "/app", "Image": "sha256:original", "restore_image_id": "sha256:writable",
                "Config": {"Image": "image:latest", "Entrypoint": ["sh", "-c"], "Cmd": ["printf test; sleep 100"],
                           "Env": ["VALUE=two words"], "User": "1001:1002", "Healthcheck": {"Test": ["CMD", "true"]}},
                "HostConfig": {"Binds": ["data:/data", "/old bind:/file:ro"], "NetworkMode": "project_default",
                               "RestartPolicy": {"Name": "unless-stopped"}, "PortBindings": {"80/tcp": [{"HostPort": "8080"}]}},
                "Mounts": [{"Type": "volume", "Name": "data", "Destination": "/data", "RW": True},
                           {"Type": "bind", "Source": "/old bind", "Destination": "/file", "RW": False, "Propagation": "rprivate"}],
                "NetworkSettings": {"Networks": {"project_default": {"Aliases": ["app", "a" * 12], "IPAMConfig": {"IPv4Address": "172.25.0.10"}, "IPAddress": "172.25.0.10"}}},
                "State": {"Running": True}}

    def test_restore_uses_committed_image_and_original_config(self):
        c = self.container()
        original = copy.deepcopy(c)
        result = module.create_request(c, {c["Id"]: "clone-app", "app": "clone-app"}, {"data": "clone-data"}, {"project_default": "clone-net"}, {"/old bind": "/new bind"})
        self.assertEqual(result["Image"], "sha256:writable")
        self.assertEqual(result["Cmd"], c["Config"]["Cmd"])
        self.assertEqual(result["Entrypoint"], ["sh", "-c"])
        self.assertEqual(result["HostConfig"]["Mounts"][0]["Source"], "clone-data")
        self.assertEqual(result["HostConfig"]["Mounts"][1]["Source"], "/new bind")
        self.assertTrue(result["HostConfig"]["Mounts"][1]["ReadOnly"])
        self.assertNotIn("Binds", result["HostConfig"])
        endpoint = result["NetworkingConfig"]["EndpointsConfig"]["clone-net"]
        self.assertEqual(endpoint["Aliases"], ["clone-app"])
        self.assertEqual(endpoint["IPAMConfig"]["IPv4Address"], "172.25.0.10")
        self.assertNotIn("IPAddress", endpoint)
        self.assertEqual(c, original)

    def test_unknown_start_fields_are_reported(self):
        c = self.container()
        c["HostConfig"]["FutureStartupFeature"] = {"value": 1}
        self.assertIn("HostConfig.FutureStartupFeature", module.unknown_fields(c))

    def test_commit_warning_does_not_become_image_reference(self):
        image = "sha256:" + "c" * 64
        result = subprocess.CompletedProcess([], 0, ("Flag --pause has been deprecated\n" + image + "\n").encode(), b"")
        with patch.object(module, "docker", return_value=result) as docker:
            self.assertEqual(module.commit_image("container"), image)
        docker.assert_called_once_with("commit", "container")

    def test_partial_restore_rejects_unselected_shared_volume_users(self):
        first = self.container()
        second = copy.deepcopy(first)
        second.update(Id="b" * 64, Name="/second")
        manifest = {"schema_version": 1, "type": "docker", "inventory": {
            "containers": [first, second], "resources": [{"type": "volume", "source": "data", "containers": [first["Id"], second["Id"]]}], "networks": []}}
        with tempfile.TemporaryDirectory() as temporary:
            module.write_json(Path(temporary) / "manifest.json", manifest)
            with self.assertRaises(module.Failure):
                module.selected_manifest(temporary, {"containers": ["app"]})
            selected = module.selected_manifest(temporary, {"volumes": ["data"]})
            self.assertEqual(selected["inventory"]["containers"], [])
            self.assertEqual(selected["inventory"]["resources"][0]["source"], "data")

    def test_restore_source_binds_verified_id_and_offline_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            payload = Path(temporary) / "payload"
            payload.mkdir()
            module.write_json(payload / "manifest.json", {"job_id": "actual-job"})
            module.write_json(payload / ".vpsctl-files.json", {"schema_version": 1, "files": []})
            offline = module.source_identity(payload, "a" * 64)
            self.assertEqual(offline["kind"], "offline-content")
            self.assertIsNone(offline["snapshot_id"])
            self.assertTrue(offline["confirmation"].startswith("sha256:"))
            self.assertEqual(module.source_identity(payload, "b" * 64)["confirmation"], offline["confirmation"])
            snapshot = "a" * 64
            verified = module.source_identity(payload, snapshot, record=True)
            self.assertEqual(verified["confirmation"], snapshot)
            with self.assertRaises(module.Failure):
                module.source_identity(payload, "b" * 64)
            module.write_json(payload / "manifest.json", {"job_id": "different-job"})
            with self.assertRaises(module.Failure):
                module.source_identity(payload, snapshot)

    def test_native_sqlite_archive_keeps_permissions_and_relative_path(self):
        import tarfile
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source, payload = base / "source", base / "payload"
            source.mkdir()
            (payload / "data").mkdir(parents=True)
            (source / "db.sqlite").write_bytes(b"live data must never be archived")
            (source / "db.sqlite").chmod(0o640)
            snapshot = base / "native.sqlite"
            snapshot.write_bytes(b"native consistent database")
            resource = {"key": "db", "type": "volume", "source": "db", "definition": {"Mountpoint": str(source)}, "archive": "data/db.tar"}
            module.sqlite_archive({"resources": [resource]}, {"resource_key": "db", "relative_path": "db.sqlite"}, snapshot, payload)
            with tarfile.open(payload / "data/db.tar") as archive:
                member = archive.getmember("./db.sqlite")
                self.assertEqual(member.mode, 0o640)
                self.assertEqual(archive.extractfile(member).read(), b"native consistent database")
            self.assertTrue(resource["native_archive"])

    def online_inventory(self, source, storage="bind", names=("app",)):
        containers = []
        resource = {"key": "online-data", "type": storage, "source": str(source) if storage == "bind" else "online-data",
                    "archive": "data/online.tar", "containers": [], "directory": True}
        if storage == "volume":
            resource["definition"] = {"Mountpoint": str(source)}
        for index, name in enumerate(names):
            c = self.container()
            c.update(Id=str(index + 1) * 64, Name="/" + name)
            c["Mounts"] = [{"Type": storage, "Destination": "/data", "RW": True,
                            "Source": str(source), **({"Name": "online-data"} if storage == "volume" else {})}]
            containers.append(c)
            resource["containers"].append(c["Id"])
        return {"containers": containers, "writers": containers, "resources": [resource]}

    def online_adapter(self, kind="postgres", name="app"):
        return {"kind": kind, "container": name, **({"defaults_file": "/run/secrets/database.cnf"} if kind in ("mysql", "mariadb") else {})}

    def online_query(self, paths):
        def query(*args, **kwargs):
            self.assertNotIn("output", kwargs, "coverage must fail before any export")
            self.assertIn(args[-1], ("SHOW data_directory", "SELECT @@datadir"))
            cid = args[args.index("psql") - 1] if "psql" in args else args[1]
            path = paths[cid] if isinstance(paths, dict) else paths
            return subprocess.CompletedProcess([], 0, (path + "\n").encode(), b"")
        return query

    def test_online_sql_rejects_uncovered_files_links_and_empty_directories(self):
        for storage in ("bind", "volume"):
            for kind in ("postgres", "mysql", "mariadb"):
                with self.subTest(storage=storage, kind=kind), tempfile.TemporaryDirectory() as temporary:
                    source = Path(temporary)
                    (source / "database").mkdir()
                    (source / "database/live-file").write_text("SQL owns this directory")
                    (source / "uploads").mkdir()
                    (source / "uploads/photo").write_text("must not disappear")
                    (source / "empty").mkdir()
                    (source / "link").symlink_to(source / "database", target_is_directory=True)
                    inv = self.online_inventory(source, storage)
                    options = {"online": [self.online_adapter(kind)], "pre_hook": "/coordination-only", "post_hook": "/resume"}
                    with patch.object(module, "docker", side_effect=self.online_query("/data/database")):
                        with self.assertRaises(module.Failure) as failure:
                            module.online_prepare(inv, options)
                    self.assertEqual(failure.exception.code, 10)
                    for path in ("uploads/photo", "empty/", "link", "独立挂载", "capture/restore", "stop"):
                        self.assertIn(path, str(failure.exception))
                    self.assertNotIn("logical_only", inv["resources"][0])

    def test_online_sql_accepts_exclusive_root_and_nested_directory_without_scanning_database(self):
        for storage in ("bind", "volume"):
            for kind in ("postgres", "mysql", "mariadb"):
                for relative in ("", "parent/database"):
                    with self.subTest(storage=storage, kind=kind, relative=relative), tempfile.TemporaryDirectory() as temporary:
                        source = Path(temporary) / "source with spaces"
                        database = source / relative
                        database.mkdir(parents=True)
                        (database / "live-file").write_text("SQL export only")
                        inv = self.online_inventory(source, storage)
                        original_scandir = os.scandir
                        def scan(path):
                            self.assertNotEqual(Path(path), database, "database internals must retain SQL semantics")
                            return original_scandir(path)
                        with patch.object(module, "docker", side_effect=self.online_query("/data/" + relative)), patch.object(module.os, "scandir", side_effect=scan):
                            adapters = module.online_prepare(inv, {"online": [self.online_adapter(kind)]})
                        self.assertEqual(adapters[0]["resolved_mounts"], ["online-data"])
                        self.assertTrue(inv["resources"][0]["logical_only"])

    def test_online_sql_combines_all_adapters_on_shared_resource(self):
        for storage in ("bind", "volume"):
            with self.subTest(storage=storage), tempfile.TemporaryDirectory() as temporary:
                source = Path(temporary)
                names = ("pg", "mysql", "mariadb")
                inv = self.online_inventory(source, storage, names)
                adapters, paths = [], {}
                for index, kind in enumerate(("postgres", "mysql", "mariadb")):
                    (source / kind).mkdir()
                    c = inv["containers"][index]
                    c["Mounts"][0]["Destination"] = "/shared" if index else "/data"
                    paths[c["Id"]] = c["Mounts"][0]["Destination"] + "/" + kind
                    adapters.append(self.online_adapter(kind, names[index]))
                with patch.object(module, "docker", side_effect=self.online_query(paths)):
                    self.assertEqual(len(module.online_prepare(inv, {"online": adapters})), 3)

    def test_online_hook_covers_only_declared_paths_after_all_adapters_resolve(self):
        for storage in ("bind", "volume"):
            for hook_first in (False, True):
                with self.subTest(storage=storage, hook_first=hook_first), tempfile.TemporaryDirectory() as temporary:
                    source = Path(temporary)
                    (source / "database").mkdir()
                    (source / "uploads").mkdir()
                    (source / "uploads/photo").write_text("application export")
                    inv = self.online_inventory(source, storage)
                    hook = {"kind": "hook", "container": "app", "data_mounts": ["/data/uploads"],
                            "capture": ["app-backup", "capture"], "restore": ["app-backup", "restore"]}
                    adapters = [hook, self.online_adapter()] if hook_first else [self.online_adapter(), hook]
                    with patch.object(module, "docker", side_effect=self.online_query("/data/database")):
                        self.assertEqual(len(module.online_prepare(inv, {"online": adapters})), 2)
                        (source / "unclaimed").mkdir()
                        with self.assertRaises(module.Failure) as failure:
                            module.online_prepare(inv, {"online": adapters})
                    self.assertEqual(failure.exception.code, 10)
                    self.assertIn("unclaimed", str(failure.exception))

    def test_online_rejects_unsafe_missing_or_unreadable_mappings(self):
        for case in ("relative", "traversal", "control", "unmounted", "missing", "symlink", "source-symlink",
                     "missing-resource", "missing-mountpoint", "volume-source", "unreadable", "scan-error", "not-directory"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                source = Path(temporary) / "source"
                source.mkdir()
                (source / "database").mkdir()
                inv = self.online_inventory(source, "volume" if case in ("missing-mountpoint", "volume-source") else "bind")
                path = {"relative": "relative", "traversal": "/data/../database", "control": "/data/bad\npath",
                        "unmounted": "/other/database", "missing": "/data/missing"}.get(case, "/data/database")
                if case == "symlink":
                    (source / "database").rmdir()
                    (source / "database").symlink_to(source, target_is_directory=True)
                elif case == "source-symlink":
                    link = Path(temporary) / "link"
                    link.symlink_to(source, target_is_directory=True)
                    inv = self.online_inventory(link)
                elif case == "missing-resource":
                    inv["resources"] = []
                elif case == "missing-mountpoint":
                    inv["resources"][0]["definition"] = {}
                elif case == "volume-source":
                    inv["containers"][0]["Mounts"][0]["Source"] += "/database"
                elif case == "not-directory":
                    (source / "database").rmdir()
                    (source / "database").write_text("not a directory")
                access = patch.object(module.os, "access", return_value=False) if case == "unreadable" else patch.object(module.os, "access", wraps=os.access)
                scan = patch.object(module.os, "scandir", side_effect=PermissionError("denied")) if case == "scan-error" else patch.object(module.os, "scandir", wraps=os.scandir)
                with patch.object(module, "docker", side_effect=self.online_query(path)), access, scan:
                    with self.assertRaises(module.Failure) as failure:
                        module.online_prepare(inv, {"online": [self.online_adapter()]})
                self.assertEqual(failure.exception.code, 10)

    def test_online_prepare_and_capture_fail_before_exports_or_complete_manifest(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "source"
            (source / "database").mkdir(parents=True)
            (source / "uploads").mkdir()
            inv = self.online_inventory(source)
            inv.update(gaps=[], space_estimation_unavailable=[], estimated_staging_bytes=0)
            plan = {"id": "plan", "options": {"consistency": "online", "online": [self.online_adapter()]}}
            plan_file = base / "plan.json"
            module.write_json(plan_file, plan)
            with patch.object(module, "Engine"), patch.object(module, "inventory", return_value=inv), patch.object(module, "public_inventory", return_value={}), patch.object(module, "docker", side_effect=self.online_query("/data/database")), patch.object(sys, "argv", ["engine", "prepare", "--plan", str(plan_file)]), patch.object(module, "verify_tar") as tar, patch.object(module, "helper_image") as helper:
                with self.assertRaises(module.Failure) as failure:
                    module.main()
                self.assertEqual(failure.exception.code, 10)
                tar.assert_not_called()
                helper.assert_not_called()
            job, payload = base / "job", base / "payload"
            with patch.object(module, "inventory", return_value=inv), patch.object(module, "verify_tar"), patch.object(module, "helper_image", return_value="helper"), patch.object(module, "docker", side_effect=self.online_query("/data/database")):
                with self.assertRaises(module.Failure) as failure:
                    module.capture(None, plan, job, payload, "job")
            self.assertEqual(failure.exception.code, 10)
            self.assertFalse((payload / "manifest.json").exists())
            for folder in ("online", "data", "images"):
                self.assertEqual(list((payload / folder).iterdir()), [])

    def test_shared_container_dependencies_are_ordered(self):
        a = self.container()
        b = copy.deepcopy(a)
        b.update(Id="b" * 64, Name="/sidecar")
        b["HostConfig"]["NetworkMode"] = "container:" + a["Id"]
        self.assertEqual([c["Name"] for c in module.ordered([b, a])], ["/app", "/sidecar"])

    def test_unsafe_path_is_rejected_before_operations(self):
        for value in ("/", "/root", "/tmp/../..", "/tmp/../etc", "relative", "/tmp/bad\npath"):
            with self.subTest(value=value), self.assertRaises(module.Failure):
                module.safe_path(value)
        with tempfile.TemporaryDirectory() as temporary:
            expected = Path(temporary) / "directory with spaces"
            self.assertEqual(module.safe_path(str(expected)), expected)
            (Path(temporary) / "link").symlink_to("/tmp")
            with self.assertRaises(module.Failure):
                module.safe_path(str(Path(temporary) / "link/target"))

    def test_resume_journal_only_starts_original_writers(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "journal.json"
            module.write_json(path, {"containers": ["original-running"], "services": [], "resumed": False})
            with patch.object(module, "docker", return_value=subprocess.CompletedProcess([], 0, b"", b"")) as docker:
                module.restore_running(path)
            docker.assert_called_once_with("start", "original-running", check=False)
            self.assertTrue(module.read_json(path)["resumed"])

    def test_stop_failure_leaves_journal_recoverable(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "journal.json"
            c = self.container()
            inv = {"engine_id": "test", "writers": [c], "resources": []}
            with patch.object(module, "docker", side_effect=subprocess.TimeoutExpired("docker stop", 1)):
                with self.assertRaises(subprocess.TimeoutExpired):
                    module.stop_writers(inv, {"stop_timeout": 1}, path)
            self.assertEqual(module.read_json(path)["containers"], [c["Id"]])
            self.assertFalse(module.read_json(path)["resumed"])

    def test_cli_rejects_unknown_and_missing_values(self):
        for args in (("--unknown",), ("configure", "x", "--repo"), ("run",), ("restore", "repo")):
            result = subprocess.run(["bash", str(root / "commands/system/backup-docker.sh"), *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 2, result.stderr.decode())
        result = subprocess.run(["bash", str(root / "commands/system/backup-docker.sh"), "--help"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def maintenance_flow(self, action="run", cleanup=0, upload=0, maintain=0, dry_run=False, capture=0):
        with tempfile.TemporaryDirectory() as temporary:
            events = Path(temporary) / "events"
            environment = dict(os.environ, ROOT=str(root), EVENTS=str(events), WORK=temporary,
                               ACTION=action, CLEANUP_EXIT=str(cleanup), UPLOAD_EXIT=str(upload),
                               MAINTAIN_EXIT=str(maintain), CAPTURE_EXIT=str(capture), VPSCTL_DRY_RUN="1" if dry_run else "0",
                               VPSCTL_NO_COLOR="1")
            script = r'''
source "$ROOT/commands/system/backup-docker.sh"
event() { printf '%s\n' "$1" >>"$EVENTS"; }
backup_plan_load() { BACKUP_PLAN_JSON='{"repo":"repo","work_dir":"/fixture"}'; }
bd_require_engine() { :; }
bd_inspect() { event inspect; }
vps_cmd_require_root() { :; }
vps_cmd_confirm() { event confirm; }
vps_cmd_lock() { LOCKED=1; event lock; }
vps_cmd_unlock() { if [[ "${LOCKED:-0}" == 1 ]]; then event unlock; fi; LOCKED=0; }
bd_recover_locked() { event recover; }
backup_restic() { event repository; }
backup_cleanup_completed() {
    [[ "${LOCKED:-0}" == 1 && "$1" == docker && "$2" == plan ]] || return 70
    event cleanup
    return "$CLEANUP_EXIT"
}
backup_job_create() { event create; BACKUP_JOB_ID=job; BACKUP_JOB_DIR="$WORK/job"; BACKUP_PAYLOAD_DIR="$WORK/payload"; }
bd_stage_runtime() { :; }
backup_job_state() { event "$1"; }
bd_engine() { event capture; return "$CAPTURE_EXIT"; }
backup_upload_job() { event upload; [[ "$UPLOAD_EXIT" == 0 ]] || return "$UPLOAD_EXIT"; printf '%064d\n' 1; }
backup_maintain_completed() { event maintain; printf 'maintenance detail\n'; return "$MAINTAIN_EXIT"; }
backup_job_load() { BACKUP_JOB_JSON='{"type":"docker"}'; BACKUP_JOB_DIR="$WORK/job"; }
BD_ROOT="$ROOT" BACKUP_ETC="$WORK" BD_ARGS=(plan)
if [[ "$ACTION" == retry ]]; then BD_ARGS=(job); bd_retry; else bd_run; fi
'''
            result = subprocess.run(["bash", "-c", script], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            return result, events.read_text().splitlines() if events.exists() else []

    def test_cleanup_runs_under_capture_lock_before_new_job(self):
        result, events = self.maintenance_flow()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        for before, after in (("lock", "recover"), ("repository", "cleanup"), ("cleanup", "create"),
                              ("create", "capture"), ("unlock", "upload"), ("upload", "maintain")):
            self.assertLess(events.index(before), events.index(after))
        self.assertEqual(result.stdout.decode().strip(), "0" * 63 + "1")
        self.assertIn("maintenance detail", result.stderr.decode())

    def test_failed_cleanup_and_dry_run_do_not_capture_or_delete(self):
        result, events = self.maintenance_flow(cleanup=20)
        self.assertEqual(result.returncode, 20)
        self.assertNotIn("create", events)
        self.assertNotIn("capture", events)
        result, events = self.maintenance_flow(dry_run=True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(events, ["inspect"])

    def test_maintenance_failure_preserves_successful_snapshot_for_run_and_retry(self):
        for action in ("run", "retry"):
            with self.subTest(action=action):
                result, events = self.maintenance_flow(action=action, maintain=20)
                self.assertEqual(result.returncode, 30, result.stderr.decode())
                self.assertEqual(result.stdout.decode().strip(), "0" * 63 + "1")
                self.assertIn("备份数据已成功上传", result.stderr.decode())
                self.assertEqual(events.count("upload"), 1)
                self.assertEqual(events.count("maintain"), 1)
                if action == "retry":
                    self.assertNotIn("capture", events)
                    self.assertNotIn("cleanup", events)

    def test_upload_failure_never_runs_retention(self):
        result, events = self.maintenance_flow(upload=20)
        self.assertEqual(result.returncode, 20)
        self.assertNotIn("maintain", events)
        self.assertEqual(result.stdout, b"")

    def test_rejected_capture_is_never_marked_complete_or_uploaded(self):
        result, events = self.maintenance_flow(capture=10)
        self.assertEqual(result.returncode, 10, result.stderr.decode())
        self.assertIn("capture-failed", events)
        for event in ("local-complete", "upload", "maintain"):
            self.assertNotIn(event, events)

    def test_recovery_templates_isolate_repository_password_credentials_and_ca(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            tools = base / "tools"
            tools.mkdir()
            for binary in ("restic", "rclone"):
                tool = tools / binary
                tool.write_text("#!/bin/sh\nexit 0\n")
                tool.chmod(0o700)
            repos = {name: {"type": kind, "password_file": "/original/password", "credentials_file": "/original/credentials" if kind != "local" else "",
                            "ca_file": "/original/private-ca.pem" if kind != "local" else ""}
                     for name, kind in (("alpha", "s3"), ("beta", "webdav"), ("local", "local"))}
            environment = dict(os.environ, ROOT=str(root), WORK=temporary, REPOS_JSON=json.dumps(repos),
                               PATH=str(tools) + os.pathsep + os.environ["PATH"], VPSCTL_NO_COLOR="1")
            script = r'''
source "$ROOT/commands/system/backup-docker.sh"
backup_repo_load() { BACKUP_REPO_JSON="$(jq -c --arg repo "$1" '.[$repo]' <<<"$REPOS_JSON")"; }
backup_ensure_tools() { :; }
backup_tool_versions() { printf '{}\n'; }
_backup_schedule_files() { printf 'commands/system/backup-docker.sh\n'; }
for repo in alpha beta local; do
    BD_ARGS=("$repo" "$WORK/export-$repo")
    bd_export
done
'''
            result = subprocess.run(["bash", "-c", script], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            for repo in repos:
                config = module.read_json(base / ("export-" + repo) / "config" / (repo + ".json"))
                secrets = "/etc/vpsctl/backup/secrets/recovery-" + repo
                self.assertEqual(config["password_file"], secrets + "/password")
                self.assertEqual(config["credentials_file"], "" if repo == "local" else secrets + "/credentials.json")
                self.assertEqual(config["ca_file"], "" if repo == "local" else secrets + "/ca.pem")
                self.assertIn(secrets, (base / ("export-" + repo) / "README.txt").read_text())
                self.assertNotIn("/original/", json.dumps(config))

unittest.main(argv=[sys.argv[0]])
PY
