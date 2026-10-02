#!/usr/bin/env python3
"""Real HY2 acceptance traffic: persistent TCP plus SOCKS5 UDP association."""
import argparse
import concurrent.futures
import json
import socket
import struct
import sys
import threading
import time


def exact(conn, size):
    result = b""
    while len(result) < size:
        chunk = conn.recv(size - len(result))
        if not chunk:
            raise EOFError("connection closed during continuous echo")
        result += chunk
    return result


def address(conn, atyp):
    if atyp == 1:
        return socket.inet_ntop(socket.AF_INET, exact(conn, 4))
    if atyp == 4:
        return socket.inet_ntop(socket.AF_INET6, exact(conn, 16))
    if atyp == 3:
        return exact(conn, exact(conn, 1)[0]).decode()
    raise ValueError("invalid SOCKS address type")


def socks(port, command):
    conn = socket.create_connection(("127.0.0.1", port), timeout=8)
    conn.settimeout(10)
    conn.sendall(b"\x05\x01\x00")
    assert exact(conn, 2) == b"\x05\x00", "SOCKS authentication"
    target = 56001 if command == 1 else 0
    host_bytes = bytes((127, 0, 0, 1)) if command == 1 else bytes(4)
    conn.sendall(bytes((5, command, 0, 1)) + host_bytes + struct.pack("!H", target))
    head = exact(conn, 4)
    assert head[:2] == b"\x05\x00", "SOCKS connection failed: " + repr(head)
    host = address(conn, head[3])
    relay_port = struct.unpack("!H", exact(conn, 2))[0]
    return conn, host, relay_port


def echo(addresses, port, marker=b""):
    def handler(conn):
        try:
            while data := conn.recv(65535):
                conn.sendall(marker + data)
        finally:
            conn.close()

    def listener(host, udp):
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        sock = socket.socket(family, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((host, port))
        if udp:
            while True:
                data, peer = sock.recvfrom(65535)
                print(json.dumps({"udp_target": host, "port": port, "bytes": len(data)}), flush=True)
                sock.sendto(marker + data, peer)
        else:
            sock.listen(32)
            while True:
                conn, _ = sock.accept()
                threading.Thread(target=handler, args=(conn,), daemon=True).start()

    with concurrent.futures.ThreadPoolExecutor(max_workers=2 * len(addresses)) as pool:
        futures = [pool.submit(listener, host, udp) for host in addresses for udp in (False, True)]
        for future in futures:
            future.result()


def continuous(port, seconds, tcp_only=False):
    tcp, _, _ = socks(port, 1)
    if not tcp_only:
        control, host, relay_port = socks(port, 3)
        if host in ("0.0.0.0", "::"):
            host = "127.0.0.1"
        udp = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET, socket.SOCK_DGRAM)
        udp.settimeout(10)
    prefix = b"\x00\x00\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", 56001)
    start = time.monotonic()
    index = 0
    while True:
        token = ("hy2-continuity-%d" % index).encode()
        tcp.sendall(token)
        assert exact(tcp, len(token)) == token, "TCP payload mismatch"
        print("PASS: TCP sample %d at %.3fs" % (index, time.monotonic() - start), file=sys.stderr, flush=True)
        if not tcp_only:
            udp.sendto(prefix + token, (host, relay_port))
            reply, _ = udp.recvfrom(65535)
            assert reply[:3] == b"\x00\x00\x00", "invalid UDP SOCKS header"
            atyp = reply[3]
            offset = {1: 8, 4: 20}.get(atyp)
            if atyp == 3:
                offset = 5 + reply[4]
            assert offset is not None and reply[offset + 2:] == token, "UDP payload mismatch"
        elapsed = time.monotonic() - start
        print(json.dumps({"sample": index, "elapsed": round(elapsed, 3), "tcp": "PASS", "udp": "NOT RUN" if tcp_only else "PASS"}), flush=True)
        if elapsed >= seconds:
            break
        index += 1
        time.sleep(1)
    if not tcp_only:
        udp.close()
        control.close()
    tcp.close()


def direct(host, port, udp, marker=b""):
    family = socket.AF_INET6 if ":" in host else socket.AF_INET
    sock = socket.socket(family, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM)
    sock.settimeout(3)
    sock.connect((host, port))
    token = b"hy2-unrelated-traffic"
    sock.sendall(token)
    assert sock.recv(65535) == marker + token, "direct traffic was redirected or lost"
    print("PASS: direct %s %s:%d" % ("UDP" if udp else "TCP", host, port))


parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=("echo", "continuous", "tcp-continuous", "udp", "tcp"))
parser.add_argument("host_or_port")
parser.add_argument("port_or_seconds", type=int)
parser.add_argument("--marker", default="")
args = parser.parse_args()
if args.mode == "echo":
    echo(args.host_or_port.split(","), args.port_or_seconds, args.marker.encode())
elif args.mode in ("continuous", "tcp-continuous"):
    continuous(int(args.host_or_port), args.port_or_seconds, args.mode == "tcp-continuous")
else:
    direct(args.host_or_port, args.port_or_seconds, args.mode == "udp", args.marker.encode())
