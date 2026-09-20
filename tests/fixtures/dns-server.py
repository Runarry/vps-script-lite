#!/usr/bin/env python3
"""Small authoritative DNS fixture for real sing-box resolver tests.

The fixture exposes the same zone over UDP, TCP, DNS-over-TLS and
DNS-over-HTTPS.  It intentionally uses only the Python standard library so
the destructive/real integration test does not need to alter the test host.
"""

from __future__ import annotations

import argparse
import base64
import http.server
import ipaddress
import json
import os
import signal
import socket
import socketserver
import ssl
import struct
import threading
import time
from pathlib import Path


class Fixture:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.name = args.name.rstrip(".").lower() + "."
        self.bootstrap_name = args.bootstrap_name.rstrip(".").lower() + "."
        self.lock = threading.Lock()

    def record(self, transport: str, name: str, query_type: int) -> None:
        entry = {
            "time": time.time(),
            "transport": transport,
            "name": name,
            "type": query_type,
        }
        with self.lock:
            with open(self.args.evidence, "a", encoding="utf-8") as stream:
                stream.write(json.dumps(entry, separators=(",", ":")) + "\n")

    @staticmethod
    def read_name(packet: bytes, offset: int) -> tuple[str, int]:
        labels: list[str] = []
        while True:
            if offset >= len(packet):
                raise ValueError("truncated DNS name")
            length = packet[offset]
            offset += 1
            if length == 0:
                break
            if length & 0xC0:
                raise ValueError("compressed query name is not supported")
            if offset + length > len(packet):
                raise ValueError("truncated DNS label")
            labels.append(packet[offset : offset + length].decode("ascii"))
            offset += length
        return ".".join(labels).lower() + ".", offset

    def answer(self, query: bytes, transport: str) -> bytes:
        if len(query) < 12:
            raise ValueError("truncated DNS header")
        query_id, flags, questions, _, _, _ = struct.unpack("!HHHHHH", query[:12])
        if questions != 1:
            raise ValueError("fixture expects exactly one DNS question")
        name, offset = self.read_name(query, 12)
        if offset + 4 > len(query):
            raise ValueError("truncated DNS question")
        query_type, query_class = struct.unpack("!HH", query[offset : offset + 4])
        question = query[12 : offset + 4]
        self.record(transport, name, query_type)

        address = None
        if name == self.name and query_class == 1:
            if query_type == 1:
                address = ipaddress.ip_address(self.args.ipv4).packed
            elif query_type == 28:
                address = ipaddress.ip_address(self.args.ipv6).packed
        elif name == self.bootstrap_name and query_class == 1 and query_type == 1:
            address = ipaddress.ip_address(self.args.host).packed

        response_flags = 0x8000 | 0x0080 | (flags & 0x0100)
        if address is None:
            response_flags |= 0x0003
            return struct.pack("!HHHHHH", query_id, response_flags, 1, 0, 0, 0) + question

        answer = b"\xc0\x0c" + struct.pack("!HHIH", query_type, 1, 30, len(address)) + address
        return struct.pack("!HHHHHH", query_id, response_flags, 1, 1, 0, 0) + question + answer


class UDPServer(socketserver.ThreadingUDPServer):
    allow_reuse_address = True
    daemon_threads = True


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        query, output = self.request
        try:
            response = self.server.fixture.answer(query, "udp")
        except (ValueError, UnicodeDecodeError):
            return
        output.sendto(response, self.client_address)


class TCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class TCPHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        size_data = self._read_exact(2)
        if size_data is None:
            return
        size = struct.unpack("!H", size_data)[0]
        query = self._read_exact(size)
        if query is None:
            return
        try:
            response = self.server.fixture.answer(query, self.server.transport)
        except (ValueError, UnicodeDecodeError):
            return
        self.request.sendall(struct.pack("!H", len(response)) + response)

    def _read_exact(self, size: int) -> bytes | None:
        chunks = bytearray()
        while len(chunks) < size:
            chunk = self.request.recv(size - len(chunks))
            if not chunk:
                return None
            chunks.extend(chunk)
        return bytes(chunks)


class HTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def server_bind(self) -> None:
        # HTTPServer normally calls getfqdn() here.  That implicit lookup can
        # block before the isolated DNS fixture itself is ready.
        socketserver.TCPServer.server_bind(self)
        self.server_name = str(self.server_address[0])
        self.server_port = int(self.server_address[1])


class HTTPServerV6(HTTPServer):
    address_family = socket.AF_INET6


class DoHHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        prefix = self.server.path + "?dns="
        if not self.path.startswith(prefix):
            self.send_error(404)
            return
        value = self.path[len(prefix) :].split("&", 1)[0]
        try:
            query = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
        except ValueError:
            self.send_error(400)
            return
        self._answer(query)

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path != self.server.path:
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        self._answer(self.rfile.read(length))

    def _answer(self, query: bytes) -> None:
        try:
            response = self.server.fixture.answer(query, "doh")
        except (ValueError, UnicodeDecodeError):
            self.send_error(400)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/dns-message")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, _format: str, *_args: object) -> None:
        return


class TargetHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self.server.fixture.record(self.server.transport, self.path, 0)
        body = b"vpsctl-dns-ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def serve(server: socketserver.BaseServer) -> threading.Thread:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return thread


def write_ready(path: str, servers: dict[str, socketserver.BaseServer]) -> None:
    ready = {name: int(server.server_address[1]) for name, server in servers.items()}
    temporary = path + ".tmp"
    Path(temporary).write_text(json.dumps(ready, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--udp-port", type=int, default=0)
    parser.add_argument("--tcp-port", type=int, default=0)
    parser.add_argument("--dot-port", type=int, default=0)
    parser.add_argument("--doh-port", type=int, default=0)
    parser.add_argument("--http-port", type=int, default=0)
    parser.add_argument("--path", default="/dns-query")
    parser.add_argument("--name", default="dns-target.test")
    parser.add_argument("--bootstrap-name", default="dns-upstream.test")
    parser.add_argument("--ipv4", default="127.0.0.1")
    parser.add_argument("--ipv6", default="::1")
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--ready", required=True)
    args = parser.parse_args()

    Path(args.evidence).write_text("", encoding="utf-8")
    fixture = Fixture(args)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(args.cert, args.key)

    udp = UDPServer((args.host, args.udp_port), UDPHandler)
    tcp = TCPServer((args.host, args.tcp_port), TCPHandler)
    dot = TCPServer((args.host, args.dot_port), TCPHandler)
    doh = HTTPServer((args.host, args.doh_port), DoHHandler)
    target4 = HTTPServer((args.ipv4, args.http_port), TargetHandler)
    target6 = HTTPServerV6((args.ipv6, target4.server_address[1]), TargetHandler)
    for server in (udp, tcp, dot, doh, target4, target6):
        server.fixture = fixture
    tcp.transport = "tcp"
    dot.transport = "dot"
    dot.socket = tls.wrap_socket(dot.socket, server_side=True)
    doh.path = args.path
    target4.transport = "http4"
    target6.transport = "http6"
    doh.socket = tls.wrap_socket(doh.socket, server_side=True)
    target4.socket = tls.wrap_socket(target4.socket, server_side=True)
    target6.socket = tls.wrap_socket(target6.socket, server_side=True)
    servers = {
        "udp": udp,
        "tcp": tcp,
        "dot": dot,
        "doh": doh,
        "http": target4,
        "http6": target6,
    }

    stopped = threading.Event()

    def stop(_signum: int, _frame: object) -> None:
        stopped.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    threads = [serve(server) for server in servers.values()]
    write_ready(args.ready, servers)
    while not stopped.wait(0.2):
        pass
    for server in servers.values():
        server.shutdown()
        server.server_close()
    for thread in threads:
        thread.join(timeout=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
