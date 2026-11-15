#!/usr/bin/env python3
"""Native acceptance traffic and mapped systemd/sysctl fixtures."""

import json
import os
from pathlib import Path
import selectors
import shlex
import socket
import subprocess
import sys
import time


def fixture(tool, args):
    work = Path(os.environ['NETWORK_TUNE_TEST_WORK'])
    root = Path(os.environ['VPSCTL_SYSTEM_ROOT'])

    def fault(name):
        trigger = work / name
        if trigger.is_file():
            trigger.unlink()
            print('injected failure:', tool, *args, file=sys.stderr)
            raise SystemExit(1)

    if tool == 'tc':
        if args[:2] == ['qdisc', 'replace'] and 'parent' in args and 'fq' in args:
            fault('fail-tc-child')
        real = os.environ['NETWORK_TUNE_REAL_TC']
        os.execv(real, [real, *args])

    if tool == 'sysctl':
        operation = 'write' if '-w' in args else 'read'
        for entry in (item for item in args if not item.startswith('-')):
            key, _, value = entry.partition('=')
            path = root / 'proc' / 'sys' / key.replace('.', '/')
            if operation == 'write':
                fault(f'fail-sysctl-{key}')
                assert path.is_file() and value, (key, value)
                path.write_text(value + '\n')
            else:
                print(path.read_text().strip())
        return 0

    command, *rest = args
    unit = next((item for item in rest if item.endswith('.service')), '')
    path = root / 'etc' / 'systemd' / 'system' / unit
    database = work / 'service-state.json'
    units = json.loads(database.read_text()) if database.is_file() else {}
    service = units.get(unit, {'enabled': False, 'active': False})
    enabled = 'enabled' if service['enabled'] else 'disabled'
    active = 'active' if service['active'] else 'inactive'
    if command == 'is-active':
        if '--quiet' not in rest:
            print(active)
        return 0 if service['active'] else 3
    if command == 'is-enabled':
        if '--quiet' not in rest:
            print(enabled)
        return 0 if service['enabled'] else 1
    if command == 'show':
        properties = {'ActiveState': active, 'UnitFileState': enabled,
                      'LoadState': 'loaded' if path.is_file() else 'not-found',
                      'FragmentPath': str(path) if path.is_file() else '', 'DropInPaths': ''}
        requested = [item for item in properties if item in rest or f'--property={item}' in rest]
        for key in requested or properties:
            print(properties[key] if '--value' in rest else f'{key}={properties[key]}')
        return 0
    if command == 'cat':
        if path.is_file():
            print(path.read_text(), end='')
            return 0
        return 1

    with (work / 'service-mutations.log').open('a') as log:
        log.write(json.dumps(args) + '\n')
    if command == 'daemon-reload':
        return 0
    assert unit, args
    if command in ('enable', 'disable'):
        if command == 'enable':
            fault('fail-service-enable')
        service['enabled'] = command == 'enable'
        if '--now' in rest:
            service['active'] = service['enabled']
    elif command in ('start', 'stop', 'restart', 'try-restart'):
        if command == 'stop' and service['active'] and unit.startswith('network-tuning-'):
            dropins = root / 'run' / 'systemd' / 'system' / (unit + '.d')
            stops = {'ExecStop': [], 'ExecStopPost': []}
            for config in [path, *sorted(dropins.glob('*.conf'))]:
                for line in config.read_text().splitlines():
                    key, _, value = line.partition('=')
                    if key in stops:
                        if value:
                            stops[key].append(shlex.split(value))
                        else:
                            stops[key].clear()
            for programs in stops.values():
                for argv in programs:
                    assert argv[:4] == ['/usr/sbin/tc', 'qdisc', 'del', 'dev'], argv
                    subprocess.run(argv, check=True)
        service['active'] = command != 'stop'
    else:
        raise AssertionError(args)
    units[unit] = service
    database.write_text(json.dumps(units, sort_keys=True))
    return 0


def measure_tcp(filename, low, high, flow_low=None, flow_high=None):
    result = json.loads(Path(filename).read_text())
    end = result['end']
    rates = [stream['receiver']['bits_per_second'] / 1_000_000 for stream in end['streams']]
    total = end['sum_received']['bits_per_second'] / 1_000_000
    print(f'{Path(filename).stem}: streams={rates}, total={total:.2f} Mbps')
    assert float(low) <= total <= float(high), (filename, total, low, high)
    if flow_low is not None:
        assert all(float(flow_low) <= rate <= float(flow_high) for rate in rates), rates


def datagrams(mode, duration, rate, size, source_port, receiver_port, ready):
    size, duration, rate = int(size), float(duration), float(rate)
    source_port, receiver_port = int(source_port), int(receiver_port)
    clients = ('10.213.1.2', 'fd95:1::2')
    backends = ('10.213.2.2', 'fd95:2::2')
    selector = selectors.DefaultSelector()
    sockets = []
    for idx, (family, client, backend) in enumerate(zip((socket.AF_INET, socket.AF_INET6), clients, backends)):
        sock = socket.socket(family, socket.SOCK_DGRAM)
        sockets.append(sock)
        if mode == 'receive':
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
            sock.bind((client, receiver_port))
            selector.register(sock, selectors.EVENT_READ, idx)
        else:
            level, option = (socket.IPPROTO_IP, 10) if idx == 0 else (socket.IPPROTO_IPV6, 23)
            sock.setsockopt(level, option, 0)  # PMTUDISC_DONT permits source fragmentation.
            sock.bind((backend, source_port))
            sock.connect((client, receiver_port))

    counts = [0, 0]
    if mode == 'send':
        payload = bytes(size)
        interval = size * 8 / (rate * 1_000_000)
        start = time.monotonic()
        now = start
        while now - start < duration:
            for idx, sock in enumerate(sockets):
                sock.send(payload)
                counts[idx] += 1
            time.sleep(max(0, start + counts[0] * interval - time.monotonic()))
            now = time.monotonic()
    else:
        Path(ready).touch()
        end = time.monotonic() + duration + 1
        while time.monotonic() < end:
            for key, _ in selector.select(.1):
                payload, peer = key.fileobj.recvfrom(65535)
                assert len(payload) == size, len(payload)
                assert peer[:2] == (backends[key.data], source_port), peer
                counts[key.data] += 1
    print(json.dumps({'counts': counts, 'mbps': [count * size * 8 / (duration * 1_000_000) for count in counts]}))


def tc_packets(filename, stage):
    entries = json.loads(Path(filename).read_text())
    if stage == 'redirect':
        actions = [action for item in entries for action in item.get('options', {}).get('actions', [])]
        total = sum(action['stats']['packets'] for action in actions if action['kind'] == 'mirred')
    else:
        total = sum(item['packets'] for item in entries if item.get('root'))
    print(total)


if __name__ == '__main__':
    name = Path(sys.argv[0]).name
    if name in ('tc', 'sysctl', 'systemctl'):
        raise SystemExit(fixture(name, sys.argv[1:]))
    {'tcp': measure_tcp, 'udp': datagrams, 'tc-packets': tc_packets}[sys.argv[1]](*sys.argv[2:])
