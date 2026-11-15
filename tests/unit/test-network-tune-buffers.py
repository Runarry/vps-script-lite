#!/usr/bin/env python3
"""Exercise buffer policy and persistence with a fixture system root and mocked kernel."""

from decimal import Decimal
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))

from network_tune import buffers
from network_tune.common import Context, MIB, TuneError


TX = "net.ipv4.tcp_wmem"
RX = "net.ipv4.tcp_rmem"
CORE_TX = "net.core.wmem_max"
CORE_RX = "net.core.rmem_max"
MTU_PROBING = "net.ipv4.tcp_mtu_probing"


class BufferTest(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.environment = patch.dict(os.environ, VPSCTL_TESTING="1", VPSCTL_SYSTEM_ROOT=str(self.root))
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.ctx = Context(dry_run=False, assume_yes=True, non_interactive=True)
        self.ctx.quiet = True
        self.manager = buffers.BufferManager(self.ctx)
        self.ctx.path("/run/systemd/system").mkdir(parents=True)
        self.write("/proc/meminfo", "MemTotal:        262144 kB\n")
        self.runtime = {
            TX: "4096 16384 4194304", RX: "4096 131072 6291456",
            CORE_TX: "212992", CORE_RX: "212992", MTU_PROBING: "0",
            "net.ipv4.tcp_sack": "1", "net.ipv4.tcp_timestamps": "1",
            "net.ipv4.tcp_window_scaling": "1", "net.ipv4.tcp_moderate_rcvbuf": "1",
        }
        self.writes = []
        for mocked in (
            patch.object(buffers, "read_sysctl", side_effect=self.read_runtime),
            patch.object(buffers, "set_sysctl", side_effect=self.write_runtime),
            patch.object(self.ctx, "run", side_effect=AssertionError("unit test attempted a host command")),
        ):
            mocked.start()
            self.addCleanup(mocked.stop)
        confirm = patch.object(self.ctx, "confirm", wraps=self.ctx.confirm)
        self.confirm = confirm.start()
        self.addCleanup(confirm.stop)

    def read_runtime(self, ctx, key):
        self.assertIs(ctx, self.ctx)
        return self.runtime[key].replace(" ", "\t")

    def write_runtime(self, ctx, key, value):
        self.assertIs(ctx, self.ctx)
        self.assertFalse(ctx.dry_run)
        self.runtime[key] = value
        self.writes.append((key, value))

    def write(self, logical, content):
        path = self.ctx.path(logical)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def set_buffers(self, **kwargs):
        return self.manager.set(SimpleNamespace(**kwargs))

    def restore_buffers(self):
        return self.manager.restore(SimpleNamespace())

    def assert_no_management(self):
        self.assertFalse(self.manager.config_file.exists())
        self.assertFalse(self.manager.state_file.exists())

    def test_exact_bdp_rounding_and_independent_direction(self):
        self.runtime[RX] = f"4096 {17 * MIB} {24 * MIB}"
        args = {"rtt_ms": "8388.608" + "0" * 24 + "1", "tx_mbps": "1", "rx_mbps": "0.000001", "sync_core": True}
        estimate = self.manager.estimate(SimpleNamespace(**args))
        self.assertEqual(Decimal(estimate["tx"]["bdp_bytes"]), Decimal("1048576." + "0" * 25 + "125"))
        self.assertEqual(estimate["tx"]["needed_max_bytes"], 5 * MIB)
        self.assertEqual(estimate["budget_bytes"], 16 * MIB)
        self.assertIsNone(estimate["rx"]["suggested_triplet"])
        self.assertTrue(estimate["rx"]["reason"])
        self.assert_no_management()
        self.assertEqual(self.writes, [])
        self.confirm.assert_not_called()

        result = self.set_buffers(recommended=True, **args)
        self.assertTrue(result["changed"])
        self.assertEqual(dict(self.writes), {TX: f"4096 16384 {5 * MIB}", CORE_TX: str(5 * MIB)})
        self.confirm.assert_called_once()

    def test_recommendation_is_bounded_and_manual_values_are_not(self):
        estimate = self.manager.estimate(SimpleNamespace(rtt_ms="150", tx_mbps="1000"))
        self.assertEqual(Decimal(estimate["tx"]["bdp_bytes"]), Decimal(18750000))
        self.assertEqual(estimate["tx"]["needed_max_bytes"], 38 * MIB)
        self.assertEqual(estimate["tx"]["suggested_max_bytes"], 16 * MIB)

        result = self.set_buffers(tx_max="64MiB")
        self.assertEqual(result["values"], {TX: "4096 16384 67108864"})
        self.assertEqual(self.writes, [(TX, "4096 16384 67108864")])
        self.assertFalse(self.set_buffers(tx_max="64MiB")["changed"])
        self.assertEqual(len(self.writes), 1)
        self.confirm.assert_called_once()

    def test_explicit_triplet_and_whitelisted_settings(self):
        for args in (
            {"rx_max": "64KiB"},
            {"rx_triplet": "8192,4096,65536"},
            {"settings": ["net.ipv4.tcp_congestion_control=bbr"]},
            {"settings": ["net.ipv4.tcp_mtu_probing=3"]},
            {"rx_max": "8MiB", "sync_core": True, "settings": [CORE_RX + "=12MiB"]},
            {"recommended": True, "rx_max": "8MiB"},
        ):
            with self.subTest(args=args), self.assertRaises(TuneError) as caught:
                self.set_buffers(**args)
            self.assertEqual(caught.exception.code, 2)
        self.assert_no_management()
        self.assertEqual(self.writes, [])

        result = self.set_buffers(rx_triplet="4KiB,16KiB,64KiB", settings=[MTU_PROBING + "=2"])
        self.assertEqual(result["values"], {RX: "4096 16384 65536", MTU_PROBING: "2"})
        self.assertEqual(dict(self.writes), result["values"])
        self.confirm.assert_called_once()

    def test_tcpfit_is_preserved_and_later_conflict_blocks_persistence(self):
        older = self.write("/etc/sysctl.conf", f"{TX} = 4096 16384 1048576\n")
        self.ctx.path("/etc/sysctl.d").mkdir()
        self.ctx.path("/etc/sysctl.d/99-sysctl.conf").symlink_to("../sysctl.conf")
        self.write("/run/sysctl.d/99-tcpfit.conf", f"{TX} = 4096 16384 5555555\n")
        tcpfit_value = "4096 32768 39597152"
        tcpfit = self.write("/etc/sysctl.d/99-tcpfit.conf", f"-net/ipv4/tcp_wmem = {tcpfit_value}\n")
        original_tcpfit = tcpfit.read_bytes()
        later = self.write("/usr/lib/sysctl.d/99-zz.conf", f"{TX} = 4096 16384 1111111\n")
        with self.assertRaisesRegex(TuneError, "/usr/lib/sysctl.d/99-zz.conf:1") as caught:
            self.set_buffers(tx_max="8MiB", sync_core=True)
        self.assertEqual(caught.exception.code, 10)
        self.assert_no_management()
        self.assertEqual(self.writes, [])
        self.confirm.assert_not_called()
        later.unlink()

        self.set_buffers(tx_max="8MiB", sync_core=True)
        status = self.manager.status()
        self.assertFalse(status["drift"])
        self.assertEqual(status["keys"][TX]["persistent"], "4096 16384 8388608")
        result = self.restore_buffers()
        self.assertEqual(result["sources"], {CORE_TX: None, TX: "/etc/sysctl.d/99-tcpfit.conf"})
        self.assertEqual(result["values"], {TX: tcpfit_value, CORE_TX: "212992"})
        self.assert_no_management()
        self.assertEqual(tcpfit.read_bytes(), original_tcpfit)
        self.assertEqual(older.read_text(), f"{TX} = 4096 16384 1048576\n")

    def test_masking_globs_and_same_basename_after_restore(self):
        self.write("/usr/lib/sysctl.d/99-zz-mask.conf", f"{RX} = 4096 131072 5555555\n")
        mask = self.ctx.path("/etc/sysctl.d/99-zz-mask.conf")
        mask.parent.mkdir(parents=True)
        mask.symlink_to("/dev/null")
        glob = self.write("/etc/sysctl.d/99-zz-glob.conf", "net/ipv4/tcp_[rw]mem = 4096 131072 3333333\n")

        self.set_buffers(tx_max="10MiB", rx_max="12MiB")
        tx_fallback = self.write("/run/sysctl.d/99-vpsctl-network-tune.conf", f"{TX} = 4096 16384 2222222\n")
        self.assertEqual(self.manager.status()["keys"][RX]["persistent"], "4096 131072 12582912")
        result = self.restore_buffers()
        self.assertEqual(result["values"], {TX: "4096 16384 2222222", RX: "4096 131072 3333333"})
        self.assertTrue(mask.is_symlink())
        self.assertTrue(glob.is_file())
        self.assertTrue(tx_fallback.is_file())

    def test_new_fragment_does_not_mask_existing_same_basename(self):
        content = "net.ipv4.tcp_congestion_control = bbr\n"
        shadowed = self.write("/run/sysctl.d/99-vpsctl-network-tune.conf", content)
        with self.assertRaisesRegex(TuneError, "会遮蔽现有配置 /run/sysctl.d/99-vpsctl-network-tune.conf"):
            self.set_buffers(tx_max="8MiB")
        self.assert_no_management()
        self.assertEqual(shadowed.read_text(), content)
        self.assertEqual(self.writes, [])
        self.confirm.assert_not_called()

    def test_dry_run_leaves_runtime_and_files_untouched(self):
        self.ctx.dry_run = True
        result = self.set_buffers(rx_max="8MiB", sync_core=True)
        self.assertTrue(result["dry_run"])
        self.assertTrue(result["would_change"])
        self.assertFalse(result["changed"])
        self.assert_no_management()
        self.assertFalse(self.ctx.state_dir.exists())
        self.assertEqual(self.writes, [])
        self.confirm.assert_not_called()

    def test_foreign_fragment_is_neither_overwritten_nor_removed(self):
        fragment = self.write("/etc/sysctl.d/99-vpsctl-network-tune.conf", f"{TX}=4096 16384 1234567\n")
        snapshot = fragment.read_bytes()
        self.assertTrue(self.manager.status()["drift"])
        with self.assertRaisesRegex(TuneError, "内容与 TCP 缓冲区状态不匹配"):
            self.set_buffers(tx_max="8MiB")
        with self.assertRaises(TuneError):
            self.restore_buffers()
        self.assertEqual(fragment.read_bytes(), snapshot)
        self.assertFalse(self.manager.state_file.exists())
        self.assertEqual(self.writes, [])
        self.confirm.assert_not_called()

    def test_set_rolls_back_after_partial_state_commit(self):
        self.set_buffers(tx_max="8MiB")
        before = self.runtime.copy()
        state = self.ctx.snapshot_file(self.manager.state_file)
        config = self.ctx.snapshot_file(self.manager.config_file)
        write_json = self.ctx.write_json

        def fail_after_write(path, data):
            write_json(path, data)
            raise TuneError("injected state failure", 20)

        with patch.object(self.ctx, "write_json", side_effect=fail_after_write):
            with self.assertRaisesRegex(TuneError, "injected state failure") as caught:
                self.set_buffers(tx_max="16MiB", rx_max="32MiB")
        self.assertEqual(caught.exception.code, 20)
        self.assertEqual(self.runtime, before)
        self.assertEqual(self.ctx.snapshot_file(self.manager.state_file), state)
        self.assertEqual(self.ctx.snapshot_file(self.manager.config_file), config)

    def test_readback_failure_does_not_persist_unapplied_value(self):
        original = self.runtime.copy()

        def clamp_write(ctx, key, value):
            if key == TX and value != original[key]:
                value = "4096 16384 6291456"
            self.write_runtime(ctx, key, value)

        with patch.object(buffers, "set_sysctl", side_effect=clamp_write):
            with self.assertRaisesRegex(TuneError, "写入后为 4096 16384 6291456") as caught:
                self.set_buffers(tx_max="8MiB", sync_core=True)
        self.assertEqual(caught.exception.code, 20)
        self.assertEqual(self.runtime, original)
        self.assert_no_management()

    def test_restore_rolls_back_on_interruption_then_restores_first_snapshot(self):
        original = self.runtime.copy()
        self.set_buffers(tx_max="8MiB")
        self.set_buffers(tx_max="16MiB")
        managed = self.runtime.copy()
        state = self.ctx.snapshot_file(self.manager.state_file)
        config = self.ctx.snapshot_file(self.manager.config_file)
        remove_file = self.ctx.remove_file

        def interrupt_after_remove(path):
            remove_file(path)
            if path == self.manager.state_file:
                raise KeyboardInterrupt

        with patch.object(self.ctx, "remove_file", side_effect=interrupt_after_remove):
            with self.assertRaises(KeyboardInterrupt):
                self.restore_buffers()
        self.assertEqual(self.runtime, managed)
        self.assertEqual(self.ctx.snapshot_file(self.manager.state_file), state)
        self.assertEqual(self.ctx.snapshot_file(self.manager.config_file), config)
        self.restore_buffers()
        self.assertEqual(self.runtime, original)
        self.assert_no_management()


if __name__ == "__main__":
    unittest.main()
