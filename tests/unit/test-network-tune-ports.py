#!/usr/bin/env python3
"""Pure mocked regression checks; run only on host-vps-scripts."""

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
from network_tune import ports


def arguments(**changes):
    values = dict(id="web", interface="eth0", port=443, protocol="tcp", family="both",
                  total_mbps=None, flow_mbps="10", burst_kib=None, latency_ms=None,
                  queue_packets=None, flow_limit=None)
    values.update(changes)
    return SimpleNamespace(**values)


class Fixture(Context):
    """Model only links, own filters/table and file writes; never run a process."""
    def __init__(self, root):
        with patch.dict(os.environ, {"VPSCTL_TESTING": "1", "VPSCTL_SYSTEM_ROOT": str(root)}):
            super().__init__(assume_yes=True, non_interactive=True)
        self.path("/run/systemd/system").mkdir(parents=True)
        self.links = {"eth0": {"ifname": "eth0", "mtu": 1500, "flags": ["UP"]},
                      "eth1": {"ifname": "eth1", "mtu": 1400, "flags": ["UP"]}}
        self.clsact = set()
        self.filters = {}
        self.profiles = {}
        self.table = []
        self.foreign = []
        self.policies = []
        self.commands = []
        self.fail = None
        self.fail_write = False
        self.enabled = False

    def require_tools(self, *names):
        pass

    def confirm(self, summary):
        pass

    def install_runtime(self):
        pass

    def unit_state(self, name):
        file = self.snapshot_file(self.unit_path(name))
        return {"exists": file["exists"], "file": file, "enabled": self.enabled, "active": False}

    def restore_unit(self, name, snapshot):
        self.restore_file(self.unit_path(name), snapshot["file"])
        self.enabled = snapshot["enabled"]

    def systemctl(self, *args, check=True):
        if args[0] == "enable":
            self.enabled = True
        if args[0] == "disable":
            self.enabled = False
        return subprocess.CompletedProcess(args, 0, "", "")

    def write_json(self, path, data, mode=0o600):
        if self.fail_write:
            self.fail_write = False
            raise TuneError("injected state persistence failure", 20)
        return super().write_json(path, data, mode)

    def run(self, argv, check=True, input=None, timeout=15):
        if argv == ["ip", "-j", "-d", "link", "show"]:
            data = list(self.links.values())
        elif argv in (["ip", "-j", "-4", "rule", "show"], ["ip", "-j", "-6", "rule", "show"]):
            data = self.policies
        elif argv == ["nft", "-j", "list", "ruleset"]:
            data = {"nftables": self.foreign + self.table}
        elif argv[:4] == ["tc", "-j", "chain", "show"]:
            data = []
        elif argv[:4] == ["tc", "-j", "qdisc", "show"]:
            interface = argv[5]
            data = [{"kind": "fq_codel", "root": True, "handle": "0:"}]
            if interface in self.clsact:
                data += [{"kind": "clsact", "handle": "ffff:"}]
        elif argv[:4] == ["tc", "-j", "filter", "show"]:
            data = self.filters.get((argv[5], argv[6]), [])
        else:
            raise AssertionError("unexpected read: " + repr(argv))
        return subprocess.CompletedProcess(argv, 0, json.dumps(data), "")

    def mutate(self, argv, **kwargs):
        if self.dry_run:
            raise AssertionError("dry-run mutation")
        self.commands.append(argv)
        if self.fail and self.fail(argv):
            self.fail = None
            raise TuneError("injected command failure", 20)
        if argv[:3] == ["ip", "link", "add"]:
            name = argv[4]
            if name in self.links:
                raise AssertionError("duplicate link")
            self.links[name] = {"ifname": name, "mtu": 1500, "flags": [], "linkinfo": {"info_kind": "ifb"}}
        elif argv[:3] == ["ip", "link", "set"]:
            link = self.links[argv[4]]
            if "alias" in argv:
                link["ifalias"] = argv[argv.index("alias") + 1]
            if "mtu" in argv:
                link["mtu"] = int(argv[argv.index("mtu") + 1])
            if "up" in argv:
                link["flags"] = ["UP"]
            if "down" in argv:
                link["flags"] = []
        elif argv[:3] == ["ip", "link", "del"]:
            del self.links[argv[4]]
            self.profiles.pop(argv[4], None)
        elif argv[:2] == ["tc", "qdisc"]:
            if argv[-1] != "clsact":
                raise AssertionError("ports touched a physical root")
            if argv[2] == "add":
                self.clsact.add(argv[4])
            else:
                self.clsact.remove(argv[4])
        elif argv[:2] == ["tc", "filter"]:
            key = (argv[4], "egress")
            pref = int(argv[argv.index("pref") + 1])
            values = self.filters.setdefault(key, [])
            if argv[2] == "del":
                self.filters[key] = [item for item in values if item["pref"] != pref]
            else:
                values.append({"pref": pref, "kind": "fw", "options": {
                    "fw": {"mark": argv[argv.index("handle") + 1].split("/")[0], "mask": "0xffff0000"},
                    "actions": [{"kind": "skbedit", "mark": 0, "mask": "ffff0000", "index": 1,
                                 "stats": {"packets": 0}, "last_used": 0},
                                {"kind": "mirred", "to_dev": argv[-1]}]}})
        elif argv == ["nft", "-f", "-"]:
            script = kwargs["input"]
            self.table = []
            if "add table" in script:
                self.table = [{"table": {"family": "inet", "name": ports.TABLE, "comment": ports.OWNER}}]
                self.table += [{"rule": {"family": "inet", "table": ports.TABLE, "expr": line}}
                               for line in script.splitlines() if line.startswith("add rule")]
        else:
            raise AssertionError("unexpected write: " + repr(argv))
        return subprocess.CompletedProcess(argv, 0, "", "")


class PortTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.ctx = Fixture(Path(self.temp.name))
        self.manager = ports.PortManager(self.ctx)
        self.patches = [
            patch.object(ports, "profile_matches", side_effect=lambda ctx, interface, profile: ctx.profiles.get(interface) == profile),
            patch.object(ports, "capture_snapshot", side_effect=lambda ctx, interface: copy.deepcopy(ctx.profiles.get(interface))),
            patch.object(ports, "restore_snapshot", side_effect=lambda ctx, interface, snapshot: ctx.profiles.__setitem__(interface, snapshot)),
            patch.object(ports, "apply_profile", side_effect=lambda ctx, interface, profile, handle: ctx.profiles.__setitem__(interface, copy.deepcopy(profile))),
        ]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def test_tcp_flow_both_and_shared_udp_profiles(self):
        flow = ports._rule(arguments(), 1)
        self.assertEqual(flow["profile"]["mode"], "fq")
        self.assertEqual(flow["profile"]["orphan_mask"], 0xffffffff)
        combined = ports._rule(arguments(total_mbps="25"), 1)
        self.assertEqual(combined["profile"]["mode"], "tbf-fq")
        self.assertEqual(combined["profile"]["maxrate_bps"], 10_000_000)
        aggregate = ports._rule(arguments(protocol="both", flow_mbps=None, total_mbps="20"), 2)
        self.assertEqual(len(ports._keys(aggregate)), 4)
        self.assertEqual(aggregate["profile"]["mode"], "tbf")
        self.assertEqual(len({aggregate["ifb"] for _ in ports._keys(aggregate)}), 1)

    def test_input_rejection_before_side_effects(self):
        for changes in ({"protocol": "udp"}, {"protocol": "both"}, {"flow_mbps": None},
                        {"total_mbps": "20", "burst_kib": 0}, {"port": 65536}, {"queue_packets": 0}):
            with self.subTest(changes=changes), self.assertRaises(TuneError):
                self.manager.set(arguments(**changes))
        self.assertFalse(self.ctx.commands)

    def test_overlap_expansion_and_update_same_id(self):
        self.manager.set(arguments(protocol="both", flow_mbps=None, total_mbps="20"))
        before = len(self.ctx.commands)
        with self.assertRaisesRegex(TuneError, "重叠"):
            self.manager.set(arguments(id="conflict", protocol="udp", family="ipv6", flow_mbps=None, total_mbps="5"))
        self.assertEqual(len(self.ctx.commands), before)
        result = self.manager.set(arguments(protocol="both", flow_mbps=None, total_mbps="25"))
        self.assertTrue(result["changed"])

    def test_noop_preserves_native_filter_counters_and_mark_low_bits(self):
        self.manager.set(arguments())
        before = len(self.ctx.commands)
        action = self.ctx.filters[("eth0", "egress")][0]["options"]["actions"][0]
        action.update(stats={"packets": 321}, last_used=99, first_used=12, index=18)
        self.assertFalse(self.manager.set(arguments())["changed"])
        self.assertEqual(len(self.ctx.commands), before)
        script = ports._nft_script(self.manager.list()["rules"], True)
        self.assertIn("priority 110", script)
        self.assertIn("meta mark & 0x0000ffff", script)
        for line in script.splitlines():
            if line.startswith("add rule"):
                self.assertLess(line.index("ct state"), line.index("sport"))
        self.assertFalse(any("ct mark" in part for part in script.splitlines()))

    def test_foreign_classifier_and_ifb_rejected_without_mutation(self):
        self.ctx.clsact.add("eth0")
        foreign = {"pref": 8, "kind": "flower"}
        self.ctx.filters[("eth0", "egress")] = [foreign]
        with self.assertRaisesRegex(TuneError, "外部 egress"):
            self.manager.set(arguments())
        self.ctx.filters.clear()
        self.ctx.links[ports._ifb("web")] = {"ifname": ports._ifb("web"), "mtu": 1500,
                                            "linkinfo": {"info_kind": "ifb"}, "ifalias": "someone-else"}
        with self.assertRaisesRegex(TuneError, "不属于"):
            self.manager.set(arguments())
        self.assertFalse(self.ctx.commands)

    def test_foreign_mark_conflicts_and_provably_lower_bit_rules(self):
        mark = {"meta": {"key": "mark"}}
        self.assertTrue(ports._foreign_mark_conflict({"match": {"left": mark, "op": "==", "right": 65536}}))
        self.assertTrue(ports._foreign_mark_conflict({"mangle": {"key": mark, "value": 65536}}))
        self.assertFalse(ports._foreign_mark_conflict({"match": {"left": {"&": [mark, 255]}, "op": "==", "right": 1}}))
        self.assertFalse(ports._foreign_mark_conflict({"mangle": {"key": mark, "value": {"|": [{"&": [mark, 0xffffff00]}, 7]}}}))
        self.ctx.foreign = [{"rule": {"family": "ip", "table": "foreign", "expr": [{"mangle": {"key": mark, "value": 65536}}]}}]
        with self.assertRaisesRegex(TuneError, "mark"):
            self.manager.set(arguments())
        self.assertFalse(self.ctx.commands)

    def test_legacy_mark_masks_do_not_confuse_low_bits_with_reservations(self):
        for line in ("-A OUTPUT -j MARK --set-xmark 0x1/0xff", "-A OUTPUT -j MARK --or-mark 0x1",
                     "-A OUTPUT -m mark --mark 0x1/0xff -j ACCEPT",
                     "-A OUTPUT -j CONNMARK --restore-mark --nfmask 0xff --ctmask 0xff"):
            self.assertFalse(ports._legacy_mark_conflict(line), line)
        for line in ("-A OUTPUT -j MARK --set-xmark 0x10000/0xffff0000", "-A OUTPUT -j MARK --set-mark 1",
                     "-A OUTPUT -j MARK --and-mark 0xffff", "-A OUTPUT -j CONNMARK --restore-mark"):
            self.assertTrue(ports._legacy_mark_conflict(line), line)

    def test_dry_run_creates_no_state_unit_or_device(self):
        self.ctx.dry_run = True
        self.assertTrue(self.manager.set(arguments())["dry_run"])
        self.assertFalse(self.ctx.commands)
        self.assertFalse(self.ctx.state_dir.exists())
        self.assertFalse(self.ctx.unit_path(ports.UNIT).exists())

    def test_flowtable_bypass_and_policy_mark_conflicts_precede_writes(self):
        self.ctx.foreign = [{"flowtable": {"family": "inet", "table": "foreign", "name": "ft", "dev": ["eth0"]}}]
        with self.assertRaisesRegex(TuneError, "flowtable"):
            self.manager.set(arguments())
        self.ctx.foreign.clear()
        self.ctx.policies = [{"fwmark": "0x10000", "fwmask": "0xffff0000"}]
        with self.assertRaisesRegex(TuneError, "策略路由"):
            self.manager.set(arguments())
        self.assertFalse(self.ctx.commands)
        self.ctx.policies = [{"fwmark": "0x1", "fwmask": "0xff"}]
        self.assertTrue(self.manager.set(arguments())["changed"])
        self.ctx.policies = [{"fwmark": "0x10000", "fwmask": "0xffff0000", "oif": "elsewhere"},
                             {"fwmark": "0x1/0xff"}]
        self.assertFalse(self.manager.set(arguments())["changed"])

    def test_failed_interface_move_restores_mtu_and_old_filter(self):
        self.manager.set(arguments())
        self.ctx.fail_write = True
        with self.assertRaisesRegex(TuneError, "persistence failure"):
            self.manager.set(arguments(interface="eth1"))
        self.assertEqual(self.ctx.links[ports._ifb("web")]["mtu"], 1500)
        self.assertTrue(self.ctx.filters[("eth0", "egress")])
        self.assertFalse(self.ctx.filters.get(("eth1", "egress")))
        self.assertNotIn("eth1", self.ctx.clsact)
        self.assertFalse(self.manager.status()["drift"])

    def test_failed_new_filter_rolls_back_device_and_clsact(self):
        self.ctx.fail = lambda argv: argv[:3] == ["tc", "filter", "add"]
        with self.assertRaisesRegex(TuneError, "injected command"):
            self.manager.set(arguments())
        self.assertEqual(set(self.ctx.links), {"eth0", "eth1"})
        self.assertFalse(self.ctx.clsact)
        self.assertFalse(self.ctx.table)
        self.assertFalse(self.manager.state_path.exists())

    def test_delete_persistence_failure_restores_native_and_saved_state(self):
        self.manager.set(arguments())
        before = self.manager.list()
        table = copy.deepcopy(self.ctx.table)
        self.ctx.fail_write = True
        with self.assertRaisesRegex(TuneError, "persistence failure"):
            self.manager.delete(SimpleNamespace(id="web"))
        self.assertEqual(self.manager.list(), before)
        self.assertEqual(self.ctx.table, table)
        self.assertIn(ports._ifb("web"), self.ctx.links)
        self.assertFalse(self.manager.status()["drift"])

    def test_delete_preserves_foreign_ingress_and_physical_root(self):
        self.manager.set(arguments())
        self.ctx.filters[("eth0", "ingress")] = [{"pref": 1, "kind": "flower"}]
        self.manager.delete(SimpleNamespace(id="web"))
        self.assertIn("eth0", self.ctx.clsact)
        self.assertTrue(self.ctx.filters[("eth0", "ingress")])
        self.assertNotIn(ports._ifb("web"), self.ctx.links)
        self.assertFalse(self.ctx.table)
        self.assertFalse(self.ctx.enabled)
        self.assertFalse(any("root" in argv for argv in self.ctx.commands))

    def test_boot_recovers_missing_resources_and_second_boot_noops(self):
        self.manager.set(arguments(total_mbps="25"))
        self.ctx.links.pop(ports._ifb("web"))
        self.ctx.profiles.clear()
        self.ctx.filters.clear()
        self.ctx.clsact.clear()
        self.ctx.table.clear()
        self.assertTrue(self.manager.boot()["changed"])
        before = len(self.ctx.commands)
        self.assertFalse(self.manager.boot()["changed"])
        self.assertEqual(len(self.ctx.commands), before)

    def test_stale_native_profile_and_same_id_foreign_table_block(self):
        self.manager.set(arguments())
        before = len(self.ctx.commands)
        self.ctx.profiles[ports._ifb("web")]["maxrate_bps"] = 2_000_000
        with self.assertRaisesRegex(TuneError, "外部修改"):
            self.manager.set(arguments(flow_mbps="20"))
        self.assertEqual(len(self.ctx.commands), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
