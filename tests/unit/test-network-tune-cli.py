#!/usr/bin/env python3
"""CLI safety and shared-runtime transaction regressions; no host mutations."""
import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))

from network_tune import cli
from network_tune.common import Context, TuneError, runtime_archive


class TuneInterfaceTest(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.environment = patch.dict(os.environ, {
            "VPSCTL_TESTING": "1", "VPSCTL_SYSTEM_ROOT": directory.name,
            "VPSCTL_DRY_RUN": "0", "VPSCTL_ASSUME_YES": "0",
            "VPSCTL_NON_INTERACTIVE": "0",
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.ctx = Context()
        self.ctx.path("/run/systemd/system").mkdir(parents=True)

    def test_flags_work_at_all_public_parser_depths(self):
        action = ["buffer", "set", "--tx-max", "16MiB"]
        for position in (0, 1, 2, len(action)):
            args = cli.parser().parse_args(action[:position] +
                                          ["--dry-run", "--yes", "--non-interactive"] + action[position:])
            self.assertTrue(args.dry_run and args.yes and args.non_interactive)
            self.assertEqual(args.tx_max, "16MiB")
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                cli.parser().parse_args(["buffer", "set", "--dry", "--tx-max", "16MiB"])

    def test_port_plan_displays_both_limits(self):
        rule = {"id": "ss", "interface": "eth0", "port": 30001,
                "protocol": "tcp", "family": "both",
                "profile": {"mode": "tbf-fq", "rate_bps": 100_000_000, "maxrate_bps": 30_000_000}}
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            cli.render({"dry_run": True, "rule": rule}, SimpleNamespace(), self.ctx)
        self.assertIn("汇总：100 Mbps", out.getvalue())
        self.assertIn("每 TCP 流：30 Mbps", out.getvalue())
        self.assertIn("源端口 30001", out.getvalue())

    def test_back_from_core_sync_does_not_apply(self):
        for choice, answers in (("manual", ["16MiB", ""]), ("recommended", ["200", "450", ""])):
            with patch.object(cli, "_choose", side_effect=[choice, None]), \
                    patch.object(cli, "_ask", side_effect=answers), \
                    patch.object(cli, "_menu_action") as apply:
                cli._buffer_menu(self.ctx)
                apply.assert_not_called()

    def test_clear_and_restore_plans_name_scope_and_different_effects(self):
        for restoring, expected in ((False, "内核默认队列"), (True, "可能重新启用旧限速")):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                cli.render({"dry_run": True, "interface": "eth0", "restore": restoring}, SimpleNamespace(), self.ctx)
            self.assertIn("eth0", out.getvalue())
            self.assertIn(expected, out.getvalue())

    def test_ambiguous_default_interface_is_not_guessed(self):
        with patch.object(cli, "_json_command", side_effect=[[{"dev": "eth0"}], [{"dev": "eth1"}]]):
            with self.assertRaisesRegex(TuneError, "不唯一"):
                cli._interface(self.ctx)

    def test_read_only_list_does_not_create_lock_or_runtime(self):
        with patch.object(cli, "PortManager") as manager:
            manager.return_value.list.return_value = {"rules": {}}
            self.assertEqual(cli.dispatch(self.ctx, cli.parser().parse_args(["port", "list"])), {"rules": {}})
        self.assertFalse(self.ctx.path("/run/vpsctl").exists())
        self.assertFalse(self.ctx.runtime_path.exists())

    def test_noninteractive_confirmation_requires_yes(self):
        self.ctx.non_interactive = True
        self.ctx.quiet = True
        with self.assertRaisesRegex(TuneError, "--yes"):
            self.ctx.confirm("test")
        self.ctx.dry_run = True
        self.ctx.confirm("dry-run does not prompt")

    def test_runtime_failure_restores_previous_bytes_and_mode(self):
        self.ctx.atomic_write(self.ctx.runtime_path, runtime_archive(), 0o640)
        saved = self.ctx.snapshot_file(self.ctx.runtime_path)
        with patch("network_tune.common.runtime_archive", return_value=b"replacement"):
            with self.assertRaisesRegex(TuneError, "injected"):
                with self.ctx.runtime_transaction():
                    self.ctx.install_runtime()
                    raise TuneError("injected after installing shared runtime")
        self.assertEqual(self.ctx.snapshot_file(self.ctx.runtime_path), saved)

    def test_failed_first_install_removes_only_new_runtime(self):
        with self.assertRaisesRegex(TuneError, "interrupted"):
            with self.ctx.runtime_transaction():
                self.ctx.install_runtime()
                raise TuneError("interrupted", 130)
        self.assertFalse(self.ctx.runtime_path.exists())

    def test_foreign_runtime_is_never_overwritten(self):
        self.ctx.atomic_write(self.ctx.runtime_path, b"foreign file", 0o600)
        with self.assertRaisesRegex(TuneError, "不属于"):
            self.ctx.install_runtime()
        self.assertEqual(self.ctx.runtime_path.read_bytes(), b"foreign file")

    def test_boot_waits_for_peer_lock_and_user_operation_fails_fast(self):
        import fcntl
        real_flock = fcntl.flock
        events = []

        def once_busy(descriptor, operation):
            if operation & fcntl.LOCK_EX and not events:
                events.append("busy")
                raise BlockingIOError()
            return real_flock(descriptor, operation)

        with patch("network_tune.common.fcntl.flock", side_effect=once_busy):
            with self.assertRaises(TuneError):
                with self.ctx.lock("network-tune"):
                    self.fail("user operation acquired busy lock")
        events.clear()
        self.ctx.lock_wait_seconds = 1
        with patch("network_tune.common.fcntl.flock", side_effect=once_busy):
            with self.ctx.lock("network-tune"):
                self.assertEqual(events, ["busy"])

    def test_managed_restore_start_runs_after_locks_and_is_observed(self):
        starts = []

        def run(arguments, **kwargs):
            if arguments[:2] == ["systemctl", "start"]:
                with Context().lock("network-tune"):
                    starts.append(arguments[-1])
            return subprocess.CompletedProcess(arguments, 0, "", "")

        name = "vpsctl-network-tune-ports.service"
        with patch.object(self.ctx, "run", side_effect=run), \
                patch.object(self.ctx, "unit_state", return_value={"active": False, "enabled": False}):
            with self.ctx.unit_restore_scope():
                with self.ctx.lock("network-tune"):
                    self.ctx.restore_unit(name, {"active": True, "enabled": False, "file": {"exists": False}})
                    self.assertFalse(starts)
        self.assertEqual(starts, [name])


if __name__ == "__main__":
    unittest.main()
