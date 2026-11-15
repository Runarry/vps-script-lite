#!/usr/bin/env python3
"""Mocked root queue/service transactions; no host networking is touched."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
from network_tune.common import Context, TuneError
from network_tune import egress


FQ = {"limit": 10000, "flow_limit": 100, "buckets": 1024, "orphan_mask": 1023,
      "quantum": 3028, "initial_quantum": 15140, "low_rate_threshold": 68750,
      "refill_delay": 40000, "timer_slack": 10000, "horizon": 10000000, "horizon_drop": None,
      "bands": 3, "priomap ": [1, 2, 2, 2, 1, 2, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1],
      "weights ": [589824, 196608, 65536]}


def fq(handle="0:", parent=None, **options):
    node = {"kind": "fq", "handle": handle, "options": dict(FQ, **options)}
    node.update({"parent": parent} if parent else {"root": True})
    return node


def args(**values):
    result = dict(interface="eth0", mode="tbf-fq", rate_mbps="450", maxrate_mbps=None,
                  burst_kib=256, latency_ms=20, queue_packets=1024, flow_limit=100, service=None)
    result.update(values)
    return SimpleNamespace(**result)


class FakeContext(Context):
    def __init__(self, directory):
        with patch.dict(os.environ, {"VPSCTL_TESTING": "1", "VPSCTL_SYSTEM_ROOT": directory}):
            super().__init__(assume_yes=True)
        self.tree = [fq()]
        self.default_tree = [fq()]
        self.filters = []
        self.calls = []
        self.units = {}
        self.fail = None
        self.tbf_details = False
        self.broken_weights_parser = False
        self.path("/run/systemd/system").mkdir(parents=True)
        self.quiet = True

    def require_tools(self, *names):
        pass

    def install_runtime(self):
        self.calls.append(["install_runtime"])

    def run(self, argv, check=True, input=None, timeout=15):
        self.calls.append(argv[:])
        if self.fail and self.fail(argv):
            self.fail = None
            raise TuneError("injected command failure", 20)
        stdout = ""
        if argv[0] == "ip":
            pass
        elif argv == ["cat", "/proc/net/psched"]:
            stdout = "000003e8 00000040 000f4240 3b9aca00\n"
        elif argv[0] == "systemctl":
            action = argv[1]
            name = argv[2] if len(argv) > 2 else None
            if action == "show":
                unit = self.units.get(name, {})
                loaded = self.unit_path(name).exists() or unit.get("vendor")
                stdout = "LoadState=" + ("loaded" if loaded else "not-found") + "\nActiveState=" + ("active" if unit.get("active") else "inactive") + "\nUnitFileState=" + ("enabled" if unit.get("enabled") else "disabled") + "\n"
            elif action == "cat":
                stdout = self.unit_path(name).read_text()
            elif action in ("enable", "disable", "stop", "start"):
                name = argv[-1]
                unit = self.units.setdefault(name, {})
                if action == "stop" and name in egress.LEGACY_UNITS and unit.get("active"):
                    dropin = self.path("/run/systemd/system/" + name + ".d/90-vpsctl-network-tune-adopt.conf")
                    if not dropin.exists() or "ExecStop=\nExecStopPost=\n" not in dropin.read_text():
                        # A legacy stop hook destroys the shaping tree.
                        self.tree = [fq("dead:")]
                        self.calls.append(["legacy_stop_hook_ran"])
                unit["enabled" if action in ("enable", "disable") else "active"] = action in ("enable", "start")
        elif argv[:2] == ["tc", "-j"]:
            data = copy.deepcopy(self.filters if "filter" in argv else self.tree)
            if "-d" in argv and self.tbf_details:
                for node in data:
                    if node["kind"] == "tbf":
                        opts = node["options"]
                        opts.setdefault("limit", int(opts["rate"] * opts["lat"] / 1000000 + opts["burst"]))
                        opts["burst_raw"] = (int(opts["burst"]) * 15625000 + opts["rate"] - 1) // opts["rate"]
                        opts["burst"] = str(opts["burst"]) + "b/8"
                        opts.setdefault("mpu", 0)
                        opts.setdefault("linklayer", "ethernet")
            stdout = json.dumps(data)
        elif argv[:3] == ["tc", "qdisc", "del"]:
            if self.tree[0]["handle"] == "0:":
                raise TuneError("Cannot delete qdisc with handle of zero", 20)
            self.tree = copy.deepcopy(self.default_tree)
        elif argv[:3] == ["tc", "qdisc", "replace"]:
            index = argv.index("handle")
            handle, kind = argv[index + 1:index + 3]
            old = next((q for q in self.tree if q["handle"] == handle), None)
            if old and old["kind"] != kind:
                raise TuneError("Invalid qdisc name", 20)
            option_args = argv[index + 3:]
            if self.broken_weights_parser and "weights" in option_args:
                weights = option_args.index("weights")
                if len(option_args[weights + 1:]) == 3:
                    raise TuneError("Not enough elements in weights", 20)
                option_args = option_args[:weights + 1] + option_args[weights + 2:]
            opts = self.parse_options(kind, option_args)
            if old:
                opts = dict(old["options"], **opts)  # same-handle fq retains omitted maxrate
            node = {"kind": kind, "handle": handle, "options": opts}
            if "root" in argv:
                node["root"] = True
                self.tree = [node]
            else:
                node["parent"] = argv[argv.index("parent") + 1]
                self.tree = [q for q in self.tree if q.get("parent") != node["parent"]] + [node]
        else:
            raise AssertionError("unexpected command: " + repr(argv))
        return subprocess.CompletedProcess(argv, 0, stdout, "")

    @staticmethod
    def parse_options(kind, argv):
        opts = dict(FQ) if kind == "fq" else {}
        idx = 0
        while idx < len(argv):
            key = argv[idx]
            idx += 1
            if key in ("pacing", "nopacing", "horizon_drop", "horizon_cap", "ecn", "noecn"):
                if key == "nopacing":
                    opts["pacing"] = False
                elif key in ("ecn", "noecn"):
                    opts["ecn"] = key == "ecn"
                elif key.startswith("horizon_"):
                    opts.pop("horizon_drop", None)
                    opts.pop("horizon_cap", None)
                    opts[key] = None
                continue
            if key in ("priomap", "weights"):
                count = 16 if key == "priomap" else 3
                opts[key + " "] = [int(v) for v in argv[idx:idx + count]]
                idx += count
                continue
            value = argv[idx]
            idx += 1
            if key == "linklayer":
                opts[key] = value
                continue
            if key == "ce_threshold_selector":
                selector, mask = value.split("/")
                opts[key], opts["ce_threshold_mask"] = int(selector), int(mask)
                continue
            if key == "burst" and "/" in value:
                value, cell = value.split("/")
                opts["burst_cell"] = int(cell)
            if value.endswith("bit"):
                number = int(float(value[:-3])) // 8
            elif value.endswith("ms"):
                number = float(value[:-2]) * 1000
            elif value.endswith(("us", "ns")):
                number = float(value[:-2])
            else:
                number = int(value)
            opts["lat" if key == "latency" else key] = number
        if kind == "tbf":
            # Stable kernel quantization: flooring requested burst to 25-byte steps.
            opts["burst"] = int(opts["burst"] // 25 * 25)
            if "limit" in opts:
                opts["lat"] = int((opts["limit"] - opts["burst"]) * 1000000 / opts["rate"])
        if kind == "fq_codel":
            for key in ("target", "interval", "ce_threshold"):
                if key in opts:
                    opts[key] = int(opts[key] * 1000) // 1024 * 1024 // 1000
        return opts

    @property
    def mutations(self):
        return [argv for argv in self.calls if argv[:2] == ["tc", "qdisc"]]


class EgressTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="egress-unit-")
        self.ctx = FakeContext(self.temp.name)
        self.manager = egress.EgressManager(self.ctx)

    def tearDown(self):
        self.temp.cleanup()

    def test_profiles_units_and_quantized_idempotence(self):
        for mode in ("tbf-fq", "fq", "tbf"):
            profile = {"mode": mode, "rate_bps": 450000000, "burst_bytes": 262144,
                       "latency_ms": 20, "maxrate_bps": 50000000,
                       "limit_packets": 1024, "flow_limit": 100, "orphan_mask": 4294967295}
            egress.apply_profile(self.ctx, "eth0", profile)
            count = len(self.ctx.mutations)
            self.assertTrue(egress.profile_matches(self.ctx, "eth0", profile))
            egress.apply_profile(self.ctx, "eth0", profile)
            self.assertEqual(count, len(self.ctx.mutations))
            if mode != "tbf":
                self.assertEqual(self.ctx.tree[-1]["options"]["maxrate"], 6250000)
                self.assertEqual(self.ctx.tree[-1]["options"]["orphan_mask"], 4294967295)

    def test_maxrate_removal_gets_fresh_handle(self):
        self.ctx.tree = [fq("a100:", maxrate=56250000)]
        egress.apply_profile(self.ctx, "eth0", {"mode": "fq", "maxrate_bps": None})
        self.assertNotEqual(self.ctx.tree[0]["handle"], "a100:")
        self.assertNotIn("maxrate", self.ctx.tree[0]["options"])

    def test_profile_match_checks_child_parent_and_count(self):
        profile = egress._profile_from_args(args())
        egress.apply_profile(self.ctx, "eth0", profile)
        self.ctx.tree[1]["parent"] = "dead:1"
        self.assertFalse(egress.profile_matches(self.ctx, "eth0", profile))
        self.ctx.tree[1]["parent"] = self.ctx.tree[0]["handle"] + "1"
        self.ctx.tree.append(fq("fefe:", parent=self.ctx.tree[0]["handle"] + "2"))
        self.assertFalse(egress.profile_matches(self.ctx, "eth0", profile))

    def test_rich_mq_snapshot_restores_all_options_and_topology(self):
        self.ctx.tree = [{"kind": "mq", "root": True, "handle": "0:", "options": {}},
                         fq(parent=":1", maxrate=987654, pacing=False), fq(parent=":2", limit=3210)]
        snapshot = egress.capture_snapshot(self.ctx, "eth0")
        egress.apply_profile(self.ctx, "eth0", {"mode": "fq"})
        egress.restore_snapshot(self.ctx, "eth0", snapshot)
        self.assertTrue(egress._snapshot_matches(self.ctx, "eth0", snapshot))
        self.assertEqual(len(self.ctx.tree), 3)
        commands = [" ".join(v) for v in self.ctx.mutations]
        self.assertTrue(any("timer_slack 10000ns" in v and "refill_delay 40000us" in v for v in commands))
        self.assertTrue(any("maxrate 7901232bit" in v and "nopacing" in v for v in commands))
        self.assertTrue(any("weights 589824 196608 65536" in v for v in commands))

    def test_codel_and_noqueue_snapshots(self):
        for tree in ([{"kind": "fq_codel", "root": True, "handle": "0:", "options": {
                "limit": 3210, "flows": 4096, "quantum": 1514, "target": 6000,
                "interval": 100000, "memory_limit": 33554432, "ecn": False}}],
                [{"kind": "noqueue", "root": True, "handle": "0:", "options": {}}]):
            self.ctx.tree = copy.deepcopy(tree)
            self.ctx.default_tree = copy.deepcopy(tree)
            snapshot = egress.capture_snapshot(self.ctx, "eth0")
            egress.apply_profile(self.ctx, "eth0", {"mode": "fq", "maxrate_bps": 400000000})
            egress.restore_snapshot(self.ctx, "eth0", snapshot)
            self.assertTrue(egress._snapshot_matches(self.ctx, "eth0", snapshot))

    def test_omitted_noecn_and_zero_low_rate_are_preserved(self):
        self.ctx.tree = [{"kind": "fq_codel", "root": True, "handle": "0:", "options": {
            "limit": 2000, "flows": 1024, "target": 5000, "interval": 100000,
            "ce_threshold": 2000, "ce_threshold_selector": 2, "ce_threshold_mask": 3}}]
        snapshot = egress.capture_snapshot(self.ctx, "eth0")
        egress.apply_profile(self.ctx, "eth0", {"mode": "fq"})
        egress.restore_snapshot(self.ctx, "eth0", snapshot)
        self.assertFalse(self.ctx.tree[0]["options"]["ecn"])
        self.assertEqual(self.ctx.tree[0]["options"]["ce_threshold_mask"], 3)
        self.ctx.tree = [fq()]
        del self.ctx.tree[0]["options"]["low_rate_threshold"]
        snapshot = egress.capture_snapshot(self.ctx, "eth0")
        egress.apply_profile(self.ctx, "eth0", {"mode": "fq", "maxrate_bps": 10000000})
        egress.restore_snapshot(self.ctx, "eth0", snapshot)
        self.assertEqual(self.ctx.tree[0]["options"]["low_rate_threshold"], 0)

    def test_codel_dump_replay_does_not_lose_ticks(self):
        self.ctx.tree = [{"kind": "fq_codel", "root": True, "handle": "20:", "options": {
            "limit": 919, "flows": 1024, "quantum": 1300,
            "target": 5999, "interval": 110999, "ce_threshold": 1999}}]
        snapshot = egress.capture_snapshot(self.ctx, "eth0")
        for _ in range(3):
            egress.apply_profile(self.ctx, "eth0", {"mode": "fq"})
            egress.restore_snapshot(self.ctx, "eth0", snapshot)
            self.assertEqual(self.ctx.tree[0]["options"]["target"], 5999)
            self.assertEqual(self.ctx.tree[0]["options"]["interval"], 110999)
            self.assertEqual(self.ctx.tree[0]["options"]["ce_threshold"], 1999)
            count = len(self.ctx.mutations)
            egress.restore_snapshot(self.ctx, "eth0", snapshot)
            self.assertEqual(len(self.ctx.mutations), count)

    def test_broken_iproute2_weights_parser_replays_exact_weights(self):
        self.ctx.tree = [fq("20:")]
        self.ctx.tree[0]["options"]["weights "] = [786432, 262144, 131072]
        snapshot = egress.capture_snapshot(self.ctx, "eth0")
        self.ctx.broken_weights_parser = True
        egress.apply_profile(self.ctx, "eth0", {"mode": "fq", "maxrate_bps": 10000000})
        egress.restore_snapshot(self.ctx, "eth0", snapshot)
        self.assertTrue(egress._snapshot_matches(self.ctx, "eth0", snapshot))
        calls = [cmd for cmd in self.ctx.mutations if "weights" in cmd]
        self.assertEqual(calls[0][-4:], ["weights", "786432", "262144", "131072"])
        self.assertEqual(calls[1][-5:], ["weights", "786432", "786432", "262144", "131072"])

    def test_tbf_detailed_snapshot_preserves_limit_mpu_and_cell(self):
        self.ctx.tree = [{"kind": "tbf", "handle": "9400:", "root": True, "options": {
            "rate": 56250000, "burst": 262125, "lat": 20000, "mpu": 16, "limit": 1387144}}]
        self.ctx.tbf_details = True
        snapshot = egress.capture_snapshot(self.ctx, "eth0")
        options = snapshot["tree"][0]["options"]
        self.assertEqual(options["burst_cell"], 8)
        self.assertEqual(options["limit"], 1387144)
        self.assertNotIn("burst_raw", options)
        egress.apply_profile(self.ctx, "eth0", {"mode": "fq"})
        egress.restore_snapshot(self.ctx, "eth0", snapshot)
        self.assertEqual(self.ctx.tree[0]["options"]["limit"], 1387144)
        self.assertEqual(self.ctx.tree[0]["options"]["mpu"], 16)
        self.ctx.tree[0]["options"]["minburst"] = 1514
        with self.assertRaisesRegex(TuneError, "peakrate"):
            egress.capture_snapshot(self.ctx, "eth0")

    def test_unknown_tree_and_filters_rejected_before_mutation(self):
        for tree in ([{"kind": "cake", "root": True, "handle": "1:", "options": {}}],
                     [fq(unknown_option=17)]):
            self.ctx.tree = tree
            with self.assertRaises(TuneError):
                self.manager.set(args())
            self.assertEqual(self.ctx.mutations, [])
        self.ctx.tree = [fq()]
        self.ctx.filters = [{"kind": "u32"}]
        with self.assertRaisesRegex(TuneError, "过滤器"):
            self.manager.set(args())
        self.assertEqual(self.ctx.mutations, [])

    def test_clear_preserves_original_restore_and_owned_service(self):
        self.ctx.tree = [fq(maxrate=12345678, flow_limit=57)]
        original = egress.capture_snapshot(self.ctx, "eth0")
        self.manager.set(args())
        unit = egress._unit_name("eth0")
        self.assertNotIn("ExecStop", self.ctx.unit_path(unit).read_text())
        self.manager.clear(args())
        record = self.manager._load()["interfaces"]["eth0"]
        self.assertFalse(record["enabled"])
        self.assertEqual(record["original"], original)
        self.assertFalse(self.ctx.units[unit]["enabled"])
        self.assertNotIn("maxrate", self.ctx.tree[0]["options"])
        self.manager.restore(args())
        self.assertTrue(egress._snapshot_matches(self.ctx, "eth0", original))
        self.assertNotIn("eth0", self.manager._load()["interfaces"])

    def test_apply_failure_rolls_back_tree_files_and_services(self):
        original = egress.capture_snapshot(self.ctx, "eth0")
        self.ctx.fail = lambda argv: argv[:2] == ["systemctl", "enable"]
        with self.assertRaisesRegex(TuneError, "injected"):
            self.manager.set(args())
        self.assertTrue(egress._snapshot_matches(self.ctx, "eth0", original))
        self.assertFalse(self.manager.state_path.exists())
        self.assertFalse(self.ctx.unit_path(egress._unit_name("eth0")).exists())

    def test_clear_of_matching_kernel_default_handle_zero(self):
        self.manager.set(args(mode="fq", rate_mbps=None, burst_kib=None, latency_ms=None,
                              queue_packets=None, flow_limit=None))
        self.assertEqual(self.ctx.mutations, [])
        self.manager.clear(args())
        self.assertEqual(self.ctx.tree[0]["handle"], "0:")
        self.assertEqual(len(self.ctx.mutations), 2)

    def test_repeated_set_repairs_owned_unit_drift_without_resetting_queue(self):
        self.manager.set(args())
        count = len(self.ctx.mutations)
        path = self.ctx.unit_path(egress._unit_name("eth0"))
        path.write_text(path.read_text().replace("RemainAfterExit=yes", "RemainAfterExit=no"))
        self.assertTrue(self.manager.set(args())["changed"])
        self.assertIn("RemainAfterExit=yes", path.read_text())
        self.assertEqual(count, len(self.ctx.mutations))
        self.assertFalse(self.manager.set(args())["changed"])

    def test_restore_failure_keeps_desired_state_and_original(self):
        self.manager.set(args())
        state = self.manager._load()
        desired = egress.capture_snapshot(self.ctx, "eth0")
        self.ctx.fail = lambda argv: argv[:3] == ["tc", "qdisc", "replace"] and "root" in argv and "fq" in argv
        with self.assertRaisesRegex(TuneError, "injected"):
            self.manager.restore(args())
        self.assertEqual(state, self.manager._load())
        self.assertTrue(egress._snapshot_matches(self.ctx, "eth0", desired))
        self.assertTrue(self.ctx.units[egress._unit_name("eth0")]["enabled"])

    def test_incomplete_rollback_is_code30(self):
        self.ctx.fail = lambda argv: argv[:2] == ["systemctl", "enable"]
        with patch.object(egress, "restore_snapshot", side_effect=TuneError("restore failed", 20)):
            with self.assertRaises(TuneError) as failure:
                self.manager.set(args())
        self.assertEqual(failure.exception.code, 30)

    def test_adopt_suppresses_stop_hooks_and_preserves_counters(self):
        legacy = "network-tuning-po0-shaper.service"
        content = ("[Service]\nType=oneshot\nRemainAfterExit=yes\n"
                   "ExecStart=/usr/sbin/tc qdisc replace dev eth0 root handle 9400: tbf rate 450mbit burst 256kb latency 20ms\n"
                   "ExecStart=/usr/sbin/tc qdisc replace dev eth0 parent 9400:1 handle 9401: fq limit 1024\n"
                   "ExecStopPost=/bin/sh /usr/local/sbin/network-tuning-po0-restore eth0\n")
        self.ctx.write_unit(legacy, content)
        self.ctx.units[legacy] = {"active": True, "enabled": True}
        profile = egress._legacy_profile(content, "eth0")
        egress.apply_profile(self.ctx, "eth0", profile, "9400:")
        self.ctx.tree[0]["bytes"] = 123456789
        count = len(self.ctx.mutations)
        self.manager.adopt(args(service=legacy))
        self.assertEqual(count, len(self.ctx.mutations))
        self.assertEqual(self.ctx.tree[0]["bytes"], 123456789)
        self.assertNotIn(["legacy_stop_hook_ran"], self.ctx.calls)
        self.assertEqual(self.ctx.units[legacy], {"active": False, "enabled": False})
        self.manager.restore(args())
        self.assertEqual(self.ctx.units[legacy], {"active": True, "enabled": True})
        self.assertEqual(self.ctx.unit_path(legacy).read_text(), content)

    def test_adopt_failure_reenables_original_service_without_stop_hook(self):
        legacy = "network-tuning-fq.service"
        content = ("[Service]\nExecStart=/usr/sbin/tc qdisc replace dev eth0 root handle 9101: fq maxrate 450mbit\n"
                   "ExecStop=/usr/sbin/tc qdisc replace dev eth0 root handle 9102: fq\n")
        self.ctx.write_unit(legacy, content)
        self.ctx.units[legacy] = {"active": True, "enabled": True}
        self.ctx.tree = [fq("9101:", maxrate=56250000)]
        self.ctx.fail = lambda argv: argv[:2] == ["systemctl", "enable"] and argv[-1].startswith("vpsctl-")
        with self.assertRaisesRegex(TuneError, "injected"):
            self.manager.adopt(args(service=legacy))
        self.assertEqual(self.ctx.units[legacy], {"active": True, "enabled": True})
        self.assertNotIn(["legacy_stop_hook_ran"], self.ctx.calls)
        self.assertEqual(self.ctx.tree[0]["options"]["maxrate"], 56250000)
        self.assertFalse(self.manager.state_path.exists())
        dropin = self.ctx.path("/run/systemd/system/" + legacy + ".d/90-vpsctl-network-tune-adopt.conf")
        self.assertFalse(dropin.exists())

    def test_dry_run_and_ownership_conflict_do_not_write(self):
        self.ctx.dry_run = True
        self.manager.set(args())
        self.assertEqual(self.ctx.mutations, [])
        self.assertFalse(self.manager.state_path.exists())
        self.assertFalse(self.ctx.unit_path(egress._unit_name("eth0")).exists())
        self.ctx.dry_run = False
        self.ctx.write_unit(egress._unit_name("eth0"), "# Someone else's unit\n")
        with self.assertRaisesRegex(TuneError, "外部接管"):
            self.manager.set(args())
        self.assertEqual(self.ctx.mutations, [])

    def test_vendor_unit_name_conflict_is_rejected_before_mutation(self):
        name = egress._unit_name("eth0")
        self.ctx.units[name] = {"vendor": True, "active": False, "enabled": False}
        with self.assertRaisesRegex(TuneError, "受管路径以外"):
            self.manager.set(args())
        self.assertEqual(self.ctx.mutations, [])
        self.assertFalse(self.manager.state_path.exists())
        self.assertFalse(self.ctx.unit_path(name).exists())


class NativeContext(FakeContext):
    """Real tc inside one disposable namespace; files/services stay mocked."""
    def __init__(self, directory, namespace):
        super().__init__(directory)
        self.namespace = namespace

    def run(self, argv, check=True, input=None, timeout=15):
        if argv[0] not in ("tc", "ip") and argv != ["cat", "/proc/net/psched"]:
            return super().run(argv, check=check, input=input, timeout=timeout)
        self.calls.append(argv[:])
        if self.fail and self.fail(argv):
            self.fail = None
            raise TuneError("injected command failure", 20)
        return Context.run(self, ["ip", "netns", "exec", self.namespace, *argv],
                           check=check, input=input, timeout=timeout)


class NativeReplayTests(unittest.TestCase):
    def setUp(self):
        self.namespace = "vtt-egress-" + str(os.getpid())
        self.temp = tempfile.TemporaryDirectory(prefix="egress-native-", dir=os.getcwd())
        subprocess.run(["ip", "netns", "add", self.namespace], check=True)
        self.addCleanup(self.cleanup_namespace)
        self.ctx = NativeContext(self.temp.name, self.namespace)
        self.ctx.run(["ip", "link", "add", "eth0", "type", "veth", "peer", "name", "peer0"])
        self.ctx.run(["ip", "link", "set", "eth0", "up"])
        self.ctx.run(["ip", "link", "set", "peer0", "up"])

    def cleanup_namespace(self):
        subprocess.run(["ip", "netns", "del", self.namespace], check=True)
        self.temp.cleanup()

    def root(self, *options):
        self.ctx.mutate(["tc", "qdisc", "replace", "dev", "eth0", "root", "handle", "20:", *options])

    def assert_replay(self, snapshot, repetitions=3):
        for _ in range(repetitions):
            egress.apply_profile(self.ctx, "eth0", {"mode": "tbf", "rate_bps": 12000000,
                                                  "burst_bytes": 65536, "latency_ms": 50})
            egress.restore_snapshot(self.ctx, "eth0", snapshot)
            restored = egress.capture_snapshot(self.ctx, "eth0")
            self.assertEqual([egress._options(node) for node in snapshot["tree"]],
                             [egress._options(node) for node in restored["tree"]])
            calls = len(self.ctx.mutations)
            egress.restore_snapshot(self.ctx, "eth0", snapshot)
            self.assertEqual(calls, len(self.ctx.mutations), "equal restore reset queue")

    def test_native_codel_times_replay_exactly(self):
        self.root("fq_codel", "limit", "919", "flows", "1024", "target", "6ms",
                  "interval", "111ms", "ce_threshold", "2ms", "quantum", "1300", "noecn")
        snapshot = egress.capture_snapshot(self.ctx, "eth0")
        print("CoDel snapshot:", json.dumps(snapshot), flush=True)
        self.assert_replay(snapshot)

    def test_native_fq_full_options_and_custom_weights(self):
        self.root("fq", "limit", "1800", "flow_limit", "143", "quantum", "1300")
        snapshot = egress.capture_snapshot(self.ctx, "eth0")
        self.assert_replay(snapshot)
        if "weights " in snapshot["tree"][0]["options"]:
            snapshot["tree"][0]["options"]["weights "] = [786432, 262144, 131072]
            egress.restore_snapshot(self.ctx, "eth0", snapshot)
            print("FQ custom snapshot:", json.dumps(egress.capture_snapshot(self.ctx, "eth0")), flush=True)
            self.assert_replay(snapshot)

    def test_native_child_failure_restores_codel_with_code20(self):
        self.root("fq_codel", "limit", "919", "flows", "1024", "target", "6ms",
                  "interval", "111ms", "quantum", "1300", "noecn")
        snapshot = egress.capture_snapshot(self.ctx, "eth0")
        self.ctx.fail = lambda argv: argv[:3] == ["tc", "qdisc", "replace"] and "parent" in argv
        with self.assertRaises(TuneError) as failure:
            egress.EgressManager(self.ctx).set(args(rate_mbps="18"))
        self.assertEqual(failure.exception.code, 20)
        restored = egress.capture_snapshot(self.ctx, "eth0")
        self.assertEqual(snapshot["tree"][0]["options"], restored["tree"][0]["options"])
        self.assertFalse((self.ctx.state_dir / "egress.json").exists())

    def test_native_tbf_fq_detailed_snapshot_replay(self):
        self.root("tbf", "rate", "450mbit", "burst", "256kb", "latency", "20ms")
        self.ctx.mutate(["tc", "qdisc", "replace", "dev", "eth0", "parent", "20:1",
                         "handle", "21:", "fq", "limit", "1024"])
        snapshot = egress.capture_snapshot(self.ctx, "eth0")
        print("TBF+fq snapshot:", json.dumps(snapshot), flush=True)
        self.assert_replay(snapshot)

    def test_native_mq_keeps_intrinsic_defaults_and_custom_children(self):
        self.ctx.run(["ip", "link", "add", "multi", "numtxqueues", "4", "numrxqueues", "4",
                      "type", "veth", "peer", "name", "multi-peer"])
        self.ctx.run(["ip", "link", "set", "multi", "up"])
        self.ctx.run(["ip", "link", "set", "multi-peer", "up"])
        self.ctx.mutate(["tc", "qdisc", "replace", "dev", "multi", "root", "handle", "60:", "mq"])
        self.ctx.mutate(["tc", "qdisc", "replace", "dev", "multi", "parent", "60:1", "handle", "61:",
                         "fq", "maxrate", "11mbit", "limit", "961", "flow_limit", "77"])
        self.ctx.mutate(["tc", "qdisc", "replace", "dev", "multi", "parent", "60:2", "handle", "62:",
                         "fq_codel", "limit", "701", "target", "7ms", "interval", "112ms", "noecn"])
        snapshot = egress.capture_snapshot(self.ctx, "multi")
        key = lambda node: (node.get("root", False), node.get("parent", ""), node["handle"])
        expected = sorted(snapshot["tree"], key=key)
        self.assertEqual(sum(node["handle"] == "0:" for node in snapshot["tree"]), 2)
        start = len(self.ctx.mutations)
        for _ in range(3):
            egress.apply_profile(self.ctx, "multi", {"mode": "tbf", "rate_bps": 22000000,
                                                   "burst_bytes": 98304, "latency_ms": 63})
            egress.restore_snapshot(self.ctx, "multi", snapshot)
            restored = egress.capture_snapshot(self.ctx, "multi")
            self.assertEqual(expected, sorted(restored["tree"], key=key))
            count = len(self.ctx.mutations)
            egress.restore_snapshot(self.ctx, "multi", snapshot)
            self.assertEqual(count, len(self.ctx.mutations))
        for command in self.ctx.mutations[start:]:
            self.assertNotIn("60:3", command)
            self.assertNotIn("60:4", command)


if __name__ == "__main__":
    native = "--native" in sys.argv
    if native:
        if os.environ.get("VPSCTL_REAL_EGRESS_TEST") != "1" or os.geteuid() != 0:
            raise SystemExit("Native replay requires VPSCTL_REAL_EGRESS_TEST=1 and root on host-vps-scripts")
        sys.argv.remove("--native")
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(NativeReplayTests if native else EgressTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(0 if result.wasSuccessful() else 1)
