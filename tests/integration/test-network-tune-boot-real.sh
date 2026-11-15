#!/usr/bin/env bash
# Dedicated disposable host only. setup -> reboot externally -> verify -> cleanup.
# No traffic is sent; shaping stays on two dummy interfaces, never the SSH interface.
set -Eeuo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
STATE=/var/tmp/vpsctl-network-tune-boot-test
FIXTURE=vpsctl-tune-boot-fixture.service
LEGACY=network-tuning-fq.service
EGRESS_A=vpsctl-network-tune-egress@vtboot0.service
EGRESS_B=vpsctl-network-tune-egress@vtboot1.service
PORTS=vpsctl-network-tune-ports.service

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tune() { bash "$ROOT/bin/vpsctl" --yes --non-interactive network tune "$@"; }
standalone() { bash "$STATE/po0-relay.sh" tune --yes --non-interactive "$@"; }
require_fixture() { [[ -f "$STATE/owned-fixture" ]] || fail 'No owned fixture'; }

[[ "${VPSCTL_REAL_TUNE_BOOT_TEST:-0}" == 1 ]] || { echo 'SKIP: set VPSCTL_REAL_TUNE_BOOT_TEST=1 on the disposable test host'; exit 0; }
(( EUID == 0 )) || fail 'root required'
[[ -d /run/systemd/system ]] || fail 'running systemd required'
[[ -z "${VPSCTL_SYSTEM_ROOT:-}" && "${VPSCTL_TESTING:-0}" != 1 ]] || fail 'real system test cannot use a mapped root'

case "${1:-}" in
setup)
    [[ ! -e "$STATE" ]] || fail "Existing fixture/evidence: $STATE"
    for path in /var/lib/vpsctl/network/tune /usr/local/lib/vpsctl/network-tune \
        /etc/sysctl.d/99-vpsctl-network-tune.conf \
        "/etc/systemd/system/$FIXTURE" "/etc/systemd/system/$LEGACY"; do
        [[ ! -e "$path" && ! -L "$path" ]] || fail "Would disturb existing state: $path"
    done
    for unit in "$FIXTURE" "$LEGACY" "$EGRESS_A" "$EGRESS_B" "$PORTS"; do
        [[ "$(systemctl show -p LoadState --value "$unit")" == not-found ]] || fail "Existing unit: $unit"
    done
    for interface in vtboot0 vtboot1; do
        if ip link show dev "$interface" >/dev/null 2>&1; then fail "Existing interface: $interface"; fi
    done
    if nft list table inet vpsctl_tune_ports >/dev/null 2>&1; then fail 'Existing tuning classifier'; fi
    mkdir -p "$STATE"
    touch "$STATE/owned-fixture"
    cat /proc/sys/kernel/random/boot_id >"$STATE/boot-before"
    sysctl -n net.ipv4.tcp_wmem >"$STATE/wmem-before"
    sysctl -n net.ipv4.tcp_rmem >"$STATE/rmem-before"
    sysctl -n net.core.wmem_max >"$STATE/core-before"
    nft -j list ruleset >"$STATE/firewall-before.json"
    ip -j address show >"$STATE/addresses-before.json"
    cp "$ROOT/scripts/po0-relay.sh" "$STATE/po0-relay.sh"
    cat >"/etc/systemd/system/$FIXTURE" <<'UNIT'
[Unit]
Description=Disposable network tune boot acceptance interfaces
Before=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip link add vtboot0 type dummy
ExecStart=/usr/sbin/ip link add vtboot1 type dummy
ExecStart=/usr/sbin/ip link set vtboot0 up
ExecStart=/usr/sbin/ip link set vtboot1 up
ExecStop=/usr/sbin/ip link del vtboot0
ExecStop=/usr/sbin/ip link del vtboot1
[Install]
WantedBy=multi-user.target
UNIT
    cat >"/etc/systemd/system/$LEGACY" <<UNIT
[Unit]
Description=Disposable legacy FQ adoption fixture
After=$FIXTURE
Requires=$FIXTURE
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/tc qdisc replace dev vtboot0 root handle 7100: fq maxrate 20mbit limit 1024 flow_limit 100
ExecStop=/usr/bin/touch $STATE/legacy-stop-ran
ExecStopPost=/usr/bin/touch $STATE/legacy-stop-post-ran
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now "$FIXTURE" "$LEGACY"
    tune egress adopt --interface vtboot0 --service "$LEGACY"
    [[ ! -e "$STATE/legacy-stop-ran" && ! -e "$STATE/legacy-stop-post-ran" ]] || fail 'Adoption ran legacy stop hooks'
    if systemctl is-active --quiet "$LEGACY" || systemctl is-enabled --quiet "$LEGACY"; then fail 'Legacy service still owns root'; fi
    tune status --interface vtboot0 --json >"$STATE/adopted.json"
    python3 - "$STATE/adopted.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))["egress"]["interfaces"]["vtboot0"]
assert value["matches"] and value["profile"]["maxrate_bps"] == 20_000_000, value
PY
    tune buffer set --tx-max 8MiB
    tune egress set --interface vtboot0 --mode tbf-fq --rate-mbps 30 --queue-packets 128 --flow-limit 64
    standalone egress set --interface vtboot1 --mode tbf --rate-mbps 12
    tune port set --id boot-a --interface vtboot0 --port 31001 --total-mbps 12 --flow-mbps 7
    standalone port set --id boot-b --interface vtboot1 --port 31002 --protocol both --total-mbps 4
    systemctl start "$EGRESS_A" "$EGRESS_B" "$PORTS"
    tune status --json >"$STATE/before-reboot.json"
    echo 'PASS: real systemd apply, legacy stop hooks suppressed, mixed frontends; ready for external reboot'
    ;;
verify)
    require_fixture
    [[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$STATE/boot-before")" ]] || fail 'Host has not rebooted'
    for unit in "$FIXTURE" "$EGRESS_A" "$EGRESS_B" "$PORTS"; do
        systemctl is-active --quiet "$unit" || fail "Not active after boot: $unit"
        systemctl is-enabled --quiet "$unit" || fail "Not enabled after boot: $unit"
    done
    standalone status --json >"$STATE/after-reboot.json"
    python3 - "$STATE" <<'PY'
import json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
data = json.loads((root / "after-reboot.json").read_text())
for iface, rate in (("vtboot0", 30_000_000), ("vtboot1", 12_000_000)):
    record = data["egress"]["interfaces"][iface]
    assert record["matches"] and record["profile"]["rate_bps"] == rate, record
assert set(data["ports"]["rules"]) == {"boot-a", "boot-b"}, data["ports"]
assert not data["ports"]["drift"], data["ports"]
def read(key):
    return subprocess.check_output(["sysctl", "-n", key], text=True).split()
assert read("net.ipv4.tcp_wmem")[-1] == str(8 * 1024 * 1024)
assert read("net.ipv4.tcp_rmem") == (root / "rmem-before").read_text().split()
assert read("net.core.wmem_max") == (root / "core-before").read_text().split()
PY
    standalone egress clear --interface vtboot0
    tune status --json >"$STATE/egress-cleared.json"
    python3 - "$STATE/egress-cleared.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert not data["egress"]["interfaces"]["vtboot0"]["enabled"]
assert data["egress"]["interfaces"]["vtboot1"]["matches"]
assert set(data["ports"]["rules"]) == {"boot-a", "boot-b"} and not data["ports"]["drift"]
PY
    tune egress restore --interface vtboot0
    systemctl is-active --quiet "$LEGACY" || fail 'Restore did not restart legacy service'
    systemctl is-enabled --quiet "$LEGACY" || fail 'Restore did not re-enable legacy service'
    tc -j qdisc show dev vtboot0 >"$STATE/legacy-restored.json"
    python3 - "$STATE/legacy-restored.json" <<'PY'
import json, sys
root = next(row for row in json.load(open(sys.argv[1])) if row.get("root"))
assert root["kind"] == "fq" and root["options"]["maxrate"] * 8 == 20_000_000, root
PY
    standalone port delete --id boot-a
    tune status --json >"$STATE/port-deleted.json"
    python3 - "$STATE/port-deleted.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert set(data["ports"]["rules"]) == {"boot-b"} and not data["ports"]["drift"]
assert data["egress"]["interfaces"]["vtboot1"]["matches"]
PY
    journalctl -b -u "$EGRESS_A" -u "$EGRESS_B" -u "$PORTS" --no-pager >"$STATE/boot-journal.log"
    touch "$STATE/verified"
    echo 'PASS: real reboot, independent persistence, selected sysctl only, clear vs restore, legacy restart, cross-frontend management'
    ;;
cleanup)
    require_fixture
    if [[ -f /var/lib/vpsctl/network/tune/ports.json ]]; then
        tune port delete --id boot-a
        tune port delete --id boot-b
    fi
    if [[ -f /var/lib/vpsctl/network/tune/egress.json ]]; then
        while read -r interface; do tune egress restore --interface "$interface"; done < <(
            python3 -c 'import json; print("\n".join(json.load(open("/var/lib/vpsctl/network/tune/egress.json"))["interfaces"]))' | sed '/^$/d'
        )
    fi
    if [[ -f /var/lib/vpsctl/network/tune/buffers.json ]]; then tune buffer restore; fi
    # Restore the exact test-host runtime value after the module's persistent-source restoration.
    sysctl -w "net.ipv4.tcp_wmem=$(cat "$STATE/wmem-before")"
    for unit in "$LEGACY" "$FIXTURE"; do
        if [[ -f "/etc/systemd/system/$unit" ]]; then systemctl disable --now "$unit"; fi
        rm -f "/etc/systemd/system/$unit"
    done
    systemctl daemon-reload
    for unit in "$EGRESS_A" "$EGRESS_B" "$PORTS"; do
        [[ ! -e "/etc/systemd/system/$unit" ]] || fail "Leftover service: $unit"
    done
    if nft list table inet vpsctl_tune_ports >/dev/null 2>&1; then fail 'Classifier was not removed'; fi
    for interface in vtboot0 vtboot1; do
        if ip link show dev "$interface" >/dev/null 2>&1; then fail "Leftover test interface: $interface"; fi
    done
    rm -f /var/lib/vpsctl/network/tune/buffers.json /var/lib/vpsctl/network/tune/egress.json /var/lib/vpsctl/network/tune/ports.json
    rmdir /var/lib/vpsctl/network/tune
    rm -f /usr/local/lib/vpsctl/network-tune/runtime.pyz
    rmdir /usr/local/lib/vpsctl/network-tune
    touch "$STATE/cleaned"
    echo "PASS: test host restored; evidence kept in $STATE"
    ;;
*) fail 'Use setup, verify or cleanup';;
esac
