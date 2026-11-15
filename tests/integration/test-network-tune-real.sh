#!/usr/bin/env bash
# Opt-in on host-vps-scripts. Linux networking runs in disposable namespaces.
# shellcheck disable=SC2317,SC2016
set -Eeuo pipefail
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
FIXTURE="$ROOT/tests/integration/network-tune-fixture.py"
BASE=${VPSCTL_TUNE_RESULT_DIR:-/var/tmp/vpsctl-tune-acceptance}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

if [[ "${1:-}" != --inside ]]; then
    [[ "${VPSCTL_REAL_TUNE_TEST:-0}" == 1 ]] || { echo 'SKIP: set VPSCTL_REAL_TUNE_TEST=1'; exit 0; }
    (( EUID == 0 )) || { echo 'BLOCKED: root required'; exit 3; }
    for tool in ip tc nft iperf3 python3 sysctl systemd-escape timeout sha256sum; do
        command -v "$tool" >/dev/null || { printf 'BLOCKED: missing %s\n' "$tool"; exit 3; }
    done
    phase=${1:-all}
    case "$phase" in all|buffer|queues|traffic) ;; *) fail "unknown phase $phase" ;; esac
    mkdir -p "$BASE"
    work=$(mktemp -d "$BASE/native-$phase.XXXXXXXX")
    router=vtt-r-$$ client=vtt-c-$$ backend=vtt-b-$$
    created=()
    cleanup() {
        local status=$? ns pid
        trap - EXIT HUP INT TERM
        for ns in "${created[@]}"; do
            while read -r pid; do kill "$pid" 2>/dev/null || true; done < <(ip netns pids "$ns")
            ip netns del "$ns"
        done
        printf 'INFO: evidence=%s exit=%s\n' "$work" "$status"
        exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM
    for ns in "$router" "$client" "$backend"; do
        ip netns add "$ns"
        created+=("$ns")
        ip -n "$ns" link set lo up
    done
    ip -n "$router" link add front type veth peer name eth0 netns "$client"
    ip -n "$router" link add back type veth peer name eth0 netns "$backend"
    ip -n "$router" address add 10.213.1.1/24 dev front
    ip -n "$router" address add 10.213.2.1/24 dev back
    ip -n "$client" address add 10.213.1.2/24 dev eth0
    ip -n "$backend" address add 10.213.2.2/24 dev eth0
    ip -n "$router" -6 address add fd95:1::1/64 dev front nodad
    ip -n "$router" -6 address add fd95:2::1/64 dev back nodad
    ip -n "$client" -6 address add fd95:1::2/64 dev eth0 nodad
    ip -n "$backend" -6 address add fd95:2::2/64 dev eth0 nodad
    ip -n "$router" link set front up
    ip -n "$router" link set back up
    ip -n "$client" link set eth0 up
    ip -n "$backend" link set eth0 up
    ip -n "$router" route add default via 10.213.1.2
    ip -n "$client" route add default via 10.213.1.1
    ip -n "$client" -6 route add default via fd95:1::1
    ip -n "$backend" route add default via 10.213.2.1
    ip -n "$backend" -6 route add default via fd95:2::1
    ip netns exec "$router" sysctl -q -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
    if [[ "$phase" != buffer ]] && ! grep -q '^ifb ' /proc/modules; then modprobe ifb numifbs=0; fi
    {
        date -u --iso-8601=seconds
        uname -a
        nft --version
        tc -Version
        git -C "$ROOT" rev-parse HEAD 2>/dev/null || true
        sha256sum "$ROOT"/lib/network_tune/*.py "$ROOT"/lib/registry.sh "$ROOT"/lib/distribution.sh \
            "$ROOT"/bin/vpsctl "$ROOT"/commands/network/{tune,bbr}.sh "$ROOT"/scripts/po0-relay.sh "$0" "$FIXTURE"
    } >"$work/code-state.txt"
    mkdir -p "$work/standalone"
    cp "$ROOT/scripts/po0-relay.sh" "$work/standalone/po0-relay.sh"
    ip netns exec "$router" bash "$0" --inside "$work" "$client" "$backend" "$phase" 2>&1 | tee "$work/acceptance.log"
    exit "${PIPESTATUS[0]}"
fi

work=$2 client=$3 backend=$4 phase=$5
export NETWORK_TUNE_TEST_WORK="$work" VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$work/root" VPSCTL_NO_COLOR=1
export NETWORK_TUNE_REAL_TC
NETWORK_TUNE_REAL_TC=$(command -v tc)
mapped=$VPSCTL_SYSTEM_ROOT
state="$mapped/var/lib/vpsctl/network/tune"
runtime="$mapped/usr/local/lib/vpsctl/network-tune/runtime.pyz"
units="$mapped/etc/systemd/system"
mkdir -p "$work/bin" "$mapped/run/systemd/system" "$mapped/etc/sysctl.d" "$mapped/proc/sys/net"/{core,ipv4}
install -m 0700 "$FIXTURE" "$work/bin/network-tune-fixture"
for name in tc sysctl systemctl; do ln -s network-tune-fixture "$work/bin/$name"; done
export PATH="$work/bin:$PATH"

dump_failure() {
    local status=$?
    if (( status )); then
        nft -a list ruleset >"$work/failure.nft" 2>&1 || true
        tc -s -j qdisc show >"$work/failure-qdiscs.json" 2>&1 || true
        tc -s -j filter show dev front egress >"$work/failure-filters.json" 2>&1 || true
        ip -d -j link show >"$work/failure-links.json" 2>&1 || true
    fi
    exit "$status"
}
trap dump_failure EXIT
trap 'printf "FAIL: phase=%s line=%s\n" "$phase" "$LINENO" >&2' ERR

tune() { bash "$ROOT/bin/vpsctl" network tune "$@"; }
standalone() { (cd "$work/standalone" && env -u PYTHONPATH bash ./po0-relay.sh tune "$@"); }
apply() { tune --non-interactive --yes "$@"; }
rejected() {
    local expected=$1 label=$2 rc=0
    shift 2
    "$@" >"$work/$label.log" 2>&1 || rc=$?
    [[ "$rc" == "$expected" ]] || { cat "$work/$label.log"; fail "$label exit $rc, expected $expected"; }
}

proc_set() { printf '%s\n' "$2" >"$mapped/proc/sys/${1//./\/}"; }
proc_check() { [[ "$(sysctl -n "$1")" == "$2" ]] || fail "unexpected sysctl $1: $(sysctl -n "$1")"; }
tree() {
    tc -j qdisc show dev "$1" | python3 -c '
import json,sys
queues = [{k: v for k, v in q.items() if k != "refcnt"}
          for q in json.load(sys.stdin) if q["kind"] not in ("clsact", "ingress")]
print(json.dumps(sorted(queues, key=lambda q: (q.get("parent", ""), q["handle"])), sort_keys=True))'
}
qdisc_packets() { tc -s -j qdisc show dev "$1" >"$work/qdisc-stats.json"; python3 "$FIXTURE" tc-packets "$work/qdisc-stats.json" root; }
redirect_packets() { tc -s -j filter show dev front egress >"$work/redirect.json"; python3 "$FIXTURE" tc-packets "$work/redirect.json" redirect; }
fixture_manifest() { find "$mapped" -type f -print0 | sort -z | xargs -0 -r sha256sum; }

buffer_test() {
    local before
    before=$(fixture_manifest)
    tune --json status >"$work/fresh-vpsctl.json"
    standalone --json status >"$work/fresh-standalone.json"
    python3 - "$work/fresh-vpsctl.json" "$work/fresh-standalone.json" <<'PY'
import json, sys
from pathlib import Path

data = [json.loads(Path(path).read_text()) for path in sys.argv[1:]]
for status in data:
    assert status.pop('time_utc')
assert data[0] == data[1], data
PY
    tune --json buffer estimate --rtt-ms 80 --tx-mbps 1000 --rx-mbps 2000 >"$work/estimate.json"
    python3 - "$work/estimate.json" <<'PY'
import json, sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data['budget_bytes'] == 64 * 1024**2, data
assert data['tx']['suggested_triplet'] == [4096, 16384, 22 * 1024**2], data
assert data['rx']['suggested_triplet'] == [4096, 131072, 41 * 1024**2], data
PY
    tune --dry-run --non-interactive buffer set --tx-max 8MiB --sync-core
    standalone --dry-run --non-interactive buffer set --tx-max 8MiB --sync-core
    tune --json diagnose --interface front --seconds 1 >"$work/diagnose.json"
    python3 - "$work/diagnose.json" <<'PY'
import json, sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
assert data['seconds'] >= 1 and 'qdisc_deltas' in data, data
PY
    [[ "$before" == "$(fixture_manifest)" && ! -e "$mapped/run/vpsctl" && ! -e "$state" ]] || fail 'read/dry-run created state or locks'
    rejected 2 needs-confirmation tune --non-interactive buffer set --tx-max 8MiB
    rejected 2 cc-whitelist apply buffer set --set net.ipv4.tcp_congestion_control=reno
    printf '%s\n' 'net.ipv4.tcp_wmem = 4096 16384 3145728' >"$mapped/etc/sysctl.d/80-existing.conf"
    printf '%s\n' 'net.ipv4.tcp_wmem = 4096 16384 5242880' >"$mapped/etc/sysctl.d/zz-later.conf"
    rejected 10 later-conflict apply buffer set --tx-max 8MiB
    rm "$mapped/etc/sysctl.d/zz-later.conf"
    standalone --non-interactive --yes buffer set --tx-max 8MiB --sync-core
    proc_check net.ipv4.tcp_wmem '4096 16384 8388608'
    proc_check net.core.wmem_max 8388608
    proc_check net.ipv4.tcp_rmem '4096 131072 6291456'
    proc_check net.core.rmem_max 212992
    [[ -s "$state/buffers.json" && -s "$mapped/etc/sysctl.d/99-vpsctl-network-tune.conf" ]] || fail 'standalone did not persist buffer state/config'
    before=$(fixture_manifest)
    touch "$work/fail-sysctl-net.ipv4.tcp_wmem"
    rejected 20 buffer-rollback apply buffer set --tx-max 10MiB --rx-max 12MiB
    [[ ! -e "$work/fail-sysctl-net.ipv4.tcp_wmem" && "$before" == "$(fixture_manifest)" ]] || fail 'buffer transaction rollback changed persistence or runtime'
    apply buffer set --rx-max 70MiB
    proc_check net.ipv4.tcp_rmem '4096 131072 73400320'
    apply buffer restore
    proc_check net.ipv4.tcp_wmem '4096 16384 3145728'
    proc_check net.ipv4.tcp_rmem '4096 131072 6291456'
    proc_check net.core.wmem_max 212992
    [[ ! -e "$mapped/etc/sysctl.d/99-vpsctl-network-tune.conf" ]] || fail 'buffer restore left owned fragment'
    pass 'both frontends share state; BDP, read-only, independent values, precedence, rollback, and restoration'
}

queue_test() {
    local original shape mtime original_legacy before packets
    tc qdisc replace dev front root handle 19: fq_codel
    bash "$ROOT/bin/vpsctl" --yes --non-interactive network bbr set --algorithm cubic --qdisc fq --apply-live-qdisc
    [[ "$(tree front)" == *'"kind": "fq"'* ]] || fail 'ordinary live BBR could not replace a default fq_codel root'
    bash "$ROOT/bin/vpsctl" --yes --non-interactive network bbr restore
    [[ "$(tree front)" == *'"kind": "fq_codel"'* ]] || fail 'ordinary live BBR could not restore the default fq_codel root'
    tc qdisc replace dev front root handle 20: fq_codel limit 919 flows 1024 target 6ms interval 111ms quantum 1300 noecn
    original=$(tree front)
    tune --dry-run --non-interactive egress set --interface front --mode tbf --rate-mbps 18
    [[ "$original" == "$(tree front)" && ! -e "$state/egress.json" ]] || fail 'egress dry-run changed queue/state'
    touch "$work/fail-tc-child"
    rejected 20 child-rollback apply egress set --interface front --mode tbf-fq --rate-mbps 18
    [[ ! -e "$work/fail-tc-child" && "$original" == "$(tree front)" && ! -e "$state/egress.json" && ! -e "$runtime" ]] || fail 'egress child failure did not restore original tree/files'
    apply egress set --interface front --mode fq --maxrate-mbps 10 --queue-packets 730 --flow-limit 97
    shape=$(tree front)
    [[ "$shape" == *'"maxrate": 1250000'* ]] || fail "missing fq maxrate: $shape"
    backend_run ping -q -c 4 -i .1 -W 1 10.213.1.2 >"$work/egress-noop-ping.log"
    packets=$(qdisc_packets front)
    mtime=$(stat -c %y "$state/egress.json")
    before=$(wc -l <"$work/service-mutations.log")
    apply egress set --interface front --mode fq --maxrate-mbps 10 --queue-packets 730 --flow-limit 97
    [[ "$shape" == "$(tree front)" && "$mtime" == "$(stat -c %y "$state/egress.json")" && "$before" == "$(wc -l <"$work/service-mutations.log")" ]] || fail 'egress no-op touched queue/state/unit'
    (( $(qdisc_packets front) >= packets && packets >= 4 )) || fail 'egress no-op reset packet counters'
    rejected 10 bbr-owned bash "$ROOT/bin/vpsctl" --yes --non-interactive network bbr set --algorithm cubic --qdisc fq --apply-live-qdisc
    grep -qF 'owned by network tune' "$work/bbr-owned.log"
    [[ "$shape" == "$(tree front)" ]] || fail 'BBR modified owned live root'
    bash "$ROOT/bin/vpsctl" --yes --non-interactive network bbr set --algorithm cubic --qdisc fq
    [[ "$shape" == "$(tree front)" ]] || fail 'BBR non-live modified owned root'
    before=$(fixture_manifest)
    printf '%s\n' "$before" >"$work/bbr-restore-before.sha256"
    rejected 10 bbr-restore-owned bash "$ROOT/bin/vpsctl" --yes --non-interactive network bbr restore
    grep -qF 'owned by network tune' "$work/bbr-restore-owned.log"
    fixture_manifest >"$work/bbr-restore-after.sha256"
    cmp "$work/bbr-restore-before.sha256" "$work/bbr-restore-after.sha256"
    proc_check net.ipv4.tcp_congestion_control cubic
    proc_check net.core.default_qdisc fq
    [[ "$shape" == "$(tree front)" ]] || fail 'BBR restore changed the owned root'
    apply egress set --interface front --mode fq --maxrate-mbps none --queue-packets 730 --flow-limit 97
    [[ "$(tree front)" != *'"maxrate":'* ]] || fail 'fq maxrate remained after removal'
    apply egress set --interface front --mode tbf-fq --rate-mbps 18 --maxrate-mbps 9
    shape=$(tree front)
    [[ "$shape" == *'"kind": "tbf"'* && "$shape" == *'"kind": "fq"'* ]] || fail 'TBF+fq child missing'
    systemctl is-enabled --quiet vpsctl-network-tune-egress@front.service
    grep -qx 'ExecStart=/usr/bin/python3 /usr/local/lib/vpsctl/network-tune/runtime.pyz internal egress-apply front' "$units/vpsctl-network-tune-egress@front.service"
    tc qdisc del dev front root
    python3 "$runtime" internal egress-apply front
    [[ "$(tree front)" == *'"kind": "tbf"'* ]] || fail 'installed runtime did not replay queue'
    apply egress clear --interface front
    [[ "$(tree front)" != *'"kind": "tbf"'* && -s "$state/egress.json" ]] || fail 'clear did not reset live root while retaining restore data'
    apply egress restore --interface front
    [[ "$original" == "$(tree front)" ]] || fail 'restore did not recover exact fq_codel hierarchy'
    tc qdisc replace dev front root handle 30: pfifo limit 37
    shape=$(tree front)
    rejected 3 unsupported-root apply egress set --interface front --mode tbf --rate-mbps 20
    [[ "$shape" == "$(tree front)" ]] || fail 'unsupported root was modified'

    tc qdisc replace dev front root handle 40: fq maxrate 10mbit limit 955 flow_limit 85
    original_legacy=$(tree front)
    rejected 10 bbr-rich bash "$ROOT/bin/vpsctl" --yes --non-interactive network bbr set --algorithm cubic --qdisc fq_codel --apply-live-qdisc
    grep -qF 'custom queue option' "$work/bbr-rich.log"
    [[ "$original_legacy" == "$(tree front)" ]] || fail 'BBR modified unsupported rich root'
    cat >"$units/network-tuning-fq.service" <<'UNIT'
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/tc qdisc replace dev front root handle 40: fq maxrate 10mbit limit 955 flow_limit 85
ExecStop=/usr/sbin/tc qdisc del dev front root
ExecStopPost=/usr/sbin/tc qdisc del dev back root
[Install]
WantedBy=multi-user.target
UNIT
    systemctl enable --now network-tuning-fq.service
    backend_run ping -q -c 4 -i .1 -W 1 10.213.1.2 >"$work/egress-adopt-ping.log"
    packets=$(qdisc_packets front)
    apply egress adopt --interface front --service network-tuning-fq.service
    if systemctl is-enabled --quiet network-tuning-fq.service || systemctl is-active --quiet network-tuning-fq.service; then fail 'legacy unit stayed enabled or active'; fi
    [[ "$original_legacy" == "$(tree front)" ]] || fail 'adoption reset the matching live root'
    (( $(qdisc_packets front) >= packets && packets >= 4 )) || fail 'adoption reset the matching root packet counters'
    apply egress restore --interface front
    systemctl is-enabled --quiet network-tuning-fq.service
    systemctl is-active --quiet network-tuning-fq.service
    [[ "$original_legacy" == "$(tree front)" ]] || fail 'adoption restore failed to recover legacy tree'
    tc qdisc replace dev back root handle 41: fq
    systemctl stop network-tuning-fq.service
    systemctl disable network-tuning-fq.service
    rm "$units/network-tuning-fq.service"
    bash "$ROOT/bin/vpsctl" --yes --non-interactive network bbr restore

    ip link add name multi numtxqueues 4 numrxqueues 4 type veth peer name multi-peer
    ip link set multi up
    ip link set multi-peer up
    tc qdisc replace dev multi root handle 60: mq
    tc qdisc replace dev multi parent 60:1 handle 61: fq maxrate 11mbit limit 961 flow_limit 77
    tc qdisc replace dev multi parent 60:2 handle 62: fq_codel limit 701 target 7ms interval 112ms noecn
    original=$(tree multi)
    printf '%s\n' "$original" >"$work/mq-before.json"
    apply egress set --interface multi --mode tbf --rate-mbps 22 --burst-kib 96 --latency-ms 63
    apply egress restore --interface multi
    tree multi >"$work/mq-after.json"
    cmp "$work/mq-before.json" "$work/mq-after.json"
    tc qdisc replace dev back root handle 70: tbf rate 33500kbit burst 96321 latency 57ms mpu 64
    tc qdisc replace dev back parent 70:1 handle 71: fq maxrate 13mbit limit 781 flow_limit 69
    original=$(tree back)
    apply egress set --interface back --mode fq --maxrate-mbps 23
    apply egress restore --interface back
    [[ "$original" == "$(tree back)" ]] || fail "restore changed original TBF+fq subtree: $(tree back)"
    pass 'egress ownership, native qdisc rollback and restore, maxrate removal, boot replay, BBR conflict guard and adoption'
}

client_run() { ip netns exec "$client" "$@"; }
backend_run() { ip netns exec "$backend" "$@"; }
iperf_read() {
    local name=$1 family=$2 port=$3 streams=$4 address=10.213.1.1
    [[ "$family" != 6 ]] || address=fd95:1::1
    client_run timeout 18 iperf3 "-$family" -c "$address" -p "$port" -R -P "$streams" -O 1 -t 4 -J >"$work/$name.json"
}
rate_is() { local name=$1; shift; python3 "$FIXTURE" tcp "$work/$name.json" "$@"; }
port_apply() { apply port set --id selected --interface front --port 54101 "$@"; }
fragmented_udp() {
    local label=$1 before after receiver
    before=$(redirect_packets)
    client_run python3 "$FIXTURE" udp receive 5 3 4200 54101 54113 "$work/$label.ready" >"$work/$label-received.json" & receiver=$!
    for _ in {1..40}; do [[ ! -e "$work/$label.ready" ]] || break; sleep .05; done
    [[ -e "$work/$label.ready" ]] || fail 'fragment receiver did not start'
    backend_run python3 "$FIXTURE" udp send 5 3 4200 54101 54113 - >"$work/$label-sent.json"
    wait "$receiver"
    after=$(redirect_packets)
    python3 - "$work" "$label" "$((after - before))" <<'PY'
import json, sys
from pathlib import Path

work, label, classified = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
sent = json.loads((work / f'{label}-sent.json').read_text())['counts']
received = json.loads((work / f'{label}-received.json').read_text())['counts']
print(f'{label}: sent={sent}, received={received}, classified={classified}')
assert received == sent, (sent, received)
assert classified == 3 * sum(sent), (classified, sent)
PY
}

traffic_test() {
    local original nft_baseline before after ppid upid sender left right ifb alias
    original=$(tree front)
    ip -d -j link show dev front >"$work/frontend-link-limits.json"
    if command -v ethtool >/dev/null; then ethtool -k front >"$work/frontend-offloads.txt"; fi
    tc qdisc add dev front clsact
    tc filter add dev front ingress pref 100 protocol all matchall action pass
    tc -j filter show dev front ingress >"$work/ingress.before"

    # Exercise native ownership checks before new qdiscs/filters appear.
    tc filter add dev front egress pref 100 protocol all matchall action pass
    rejected 10 foreign-egress port_apply --total-mbps 10
    tc filter del dev front egress pref 100
    ip -4 rule add priority 12000 fwmark 0x10000/0xffff0000 table 120
    ip -4 -j rule show >"$work/foreign-routing-mark.json"
    rejected 10 foreign-mark port_apply --total-mbps 10
    ip -4 rule del priority 12000
    rejected 2 invalid-udp-flow port_apply --protocol udp --flow-mbps 10
    # Two public selectors return from the same TCP backend port, with a third
    # backend port available for concurrent global-limit verification.
    nft -f - <<'NFT'
table inet vtt_external {
    chain route_relay {
        type nat hook prerouting priority -100; policy accept;
        ip daddr 10.213.1.1 tcp dport { 54101, 54102 } dnat ip to 10.213.2.2:54001
        ip daddr 10.213.1.1 tcp dport 54103 dnat ip to 10.213.2.2:54002
        ip6 daddr fd95:1::1 tcp dport { 54101, 54102 } dnat ip6 to [fd95:2::2]:54001
        ip6 daddr fd95:1::1 tcp dport 54103 dnat ip6 to [fd95:2::2]:54002
    }
}
NFT
    nft_baseline=$(nft -s list table inet vtt_external)
    backend_run iperf3 -s -p 54001 >"$work/server-selected.log" 2>&1 &
    backend_run iperf3 -s -p 54002 >"$work/server-global.log" 2>&1 &
    sleep .3

    before=$(fixture_manifest)
    tune --dry-run --non-interactive port set --id selected --interface front --port 54101 --total-mbps 10
    [[ "$before" == "$(fixture_manifest)" && "$original" == "$(tree front)" ]] || fail 'port dry-run changed topology or files'
    touch "$work/fail-service-enable"
    rejected 20 port-rollback port_apply --total-mbps 10
    [[ ! -e "$work/fail-service-enable" && "$before" == "$(fixture_manifest)" && "$original" == "$(tree front)" ]] || fail 'port rollback did not recover state/root/runtime'
    if nft list table inet vpsctl_tune_ports >/dev/null 2>&1; then fail 'port rollback left owned nft table'; fi
    [[ -z "$(ip -brief link show type ifb)" && '[]' == "$(tc -j filter show dev front egress)" ]] || fail 'port rollback left redirects/IFB'

    port_apply --total-mbps 10
    [[ "$original" == "$(tree front)" ]] || fail 'port profile changed physical root'
    rejected 10 overlap apply port set --id overlap --interface front --port 54101 --family ipv6 --total-mbps 10
    iperf_read total-one 4 54101 1
    rate_is total-one 7 13
    iperf_read total-two 4 54101 2
    rate_is total-two 7 13
    before=$(redirect_packets)
    port_apply --total-mbps 10
    (( $(redirect_packets) >= before && before > 0 )) || fail 'port no-op reset redirect counters'
    iperf_read unrelated-same-backend 4 54102 1
    rate_is unrelated-same-backend 55 inf
    after=$(redirect_packets)
    (( after - before <= 4 )) || fail 'unrelated public mapping hit selected redirect'

    port_apply --flow-mbps 10
    iperf_read flow-one 4 54101 1
    rate_is flow-one 7 13 7 13
    iperf_read flow-two 6 54101 2
    rate_is flow-two 15 24 7 13
    port_apply --total-mbps 15 --flow-mbps 10
    iperf_read combined-one 4 54101 1
    rate_is combined-one 7 13 7 13
    iperf_read combined-two 4 54101 2
    rate_is combined-two 12 18 3 13

    apply egress set --interface front --mode tbf --rate-mbps 12
    iperf_read global-selected 4 54101 1 & left=$!
    iperf_read global-unrelated 4 54103 1 & right=$!
    wait "$left"
    wait "$right"
    python3 - "$work" <<'PY'
import json, sys
from pathlib import Path

work = Path(sys.argv[1])
rates = [json.loads((work / f'global-{name}.json').read_text())['end']['sum_received']['bits_per_second'] / 1e6 for name in ('selected', 'unrelated')]
print(f'Physical aggregate across selected and unrelated ports: {rates}, sum={sum(rates):.2f} Mbps')
assert min(rates) > 0.2 and 8 <= sum(rates) <= 14, rates
PY
    apply egress restore --interface front
    [[ "$original" == "$(tree front)" ]] || fail 'physical restore lost original queue'

    port_apply --protocol both --total-mbps 10
    fragmented_udp fragments-with-nat-hooks

    client_run python3 "$FIXTURE" udp receive 5 2 1000 54101 54113 "$work/mixed.ready" >"$work/mixed-received.json" & upid=$!
    for _ in {1..40}; do [[ ! -e "$work/mixed.ready" ]] || break; sleep .05; done
    [[ -e "$work/mixed.ready" ]] || fail 'mixed receiver did not start'
    iperf_read mixed-tcp 4 54101 1 & ppid=$!
    backend_run python3 "$FIXTURE" udp send 5 2 1000 54101 54113 - >"$work/mixed-sent.json" & sender=$!
    wait "$ppid"
    wait "$sender"
    wait "$upid"
    python3 - "$work" <<'PY'
import json, sys
from pathlib import Path

work = Path(sys.argv[1])
udp = json.loads((work / 'mixed-received.json').read_text())['mbps']
tcp = json.loads((work / 'mixed-tcp.json').read_text())['end']['sum_received']['bits_per_second'] / 1e6
total = tcp + sum(udp)
print(f'One rule across UDP IPv4/IPv6 and TCP: UDP={udp}, TCP={tcp:.2f}, sum={total:.2f} Mbps')
assert min(udp) > .2 and tcp > 1 and 6 <= total <= 12, (udp, tcp, total)
PY

    tune --json status --interface front >"$work/port-status.json"
    python3 - "$work/port-status.json" <<'PY'
import json, sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())['ports']
assert not data['drift'] and 'selected' in data['rules'], data
PY
    read -r ifb < <(ip -o link show type ifb | awk -F ': ' '{print $2}')
    [[ -n "$ifb" ]] || fail 'port IFB not found'
    alias=$(ip -d -j link show dev "$ifb" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["ifalias"])')
    ip link set dev "$ifb" alias foreign-test
    rejected 10 foreign-ifb apply port delete --id selected
    ip link set dev "$ifb" alias "$alias"
    systemctl is-enabled --quiet vpsctl-network-tune-ports.service
    nft delete table inet vpsctl_tune_ports
    tc filter del dev front egress
    ip link del dev "$ifb"
    python3 "$runtime" internal ports-apply
    [[ "$original" == "$(tree front)" && -n "$(ip -brief link show type ifb)" ]] || fail 'boot replay failed to recreate isolated port resources'
    apply port delete --id selected
    tc -j filter show dev front ingress >"$work/ingress.after"
    cmp "$work/ingress.before" "$work/ingress.after"
    [[ "$nft_baseline" == "$(nft -s list table inet vtt_external)" && "$original" == "$(tree front)" ]] || fail 'foreign nft table or root changed'
    [[ -z "$(ip -brief link show type ifb)" ]] || fail 'delete left owned IFB'
    if nft list table inet vpsctl_tune_ports >/dev/null 2>&1; then fail 'port delete left owned nft table'; fi

    nft delete table inet vtt_external
    port_apply --protocol udp --total-mbps 10
    [[ "$(nft list tables)" == 'table inet vpsctl_tune_ports' ]] || fail 'NAT-independent fragment probe requires only the port table'
    fragmented_udp fragments-without-nat
    apply port delete --id selected
    pass 'real caps, post-SNAT port selection, coexistence with global shaping, dual-stack UDP fragments, rollback and ownership'
}

printf 'MemTotal:       1048576 kB\n' >"$mapped/proc/meminfo"
proc_set net.ipv4.tcp_wmem '4096 16384 4194304'
proc_set net.ipv4.tcp_rmem '4096 131072 6291456'
proc_set net.core.wmem_max 212992
proc_set net.core.rmem_max 212992
proc_set net.ipv4.tcp_congestion_control reno
proc_set net.ipv4.tcp_available_congestion_control 'reno cubic'
proc_set net.core.default_qdisc fq_codel
for item in tcp_sack tcp_timestamps tcp_window_scaling tcp_moderate_rcvbuf tcp_mtu_probing; do proc_set "net.ipv4.$item" 1; done

case "$phase" in
    all) buffer_test; queue_test; traffic_test ;;
    buffer) buffer_test ;;
    queues) queue_test ;;
    traffic) traffic_test ;;
esac
