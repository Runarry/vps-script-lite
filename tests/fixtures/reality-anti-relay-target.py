#!/usr/bin/env python3
"""Count TCP arrivals and serve a tiny TLS response for REALITY fallback tests."""

import socket
import ssl
import sys
import threading
import time


def handle(connection, context, evidence_path):
    with open(evidence_path, "a", encoding="utf-8") as evidence:
        evidence.write(f"{time.time_ns()}\n")
        evidence.flush()
    try:
        with context.wrap_socket(connection, server_side=True) as tls_connection:
            tls_connection.settimeout(3)
            try:
                tls_connection.recv(16384)
            except (TimeoutError, socket.timeout):
                pass
            body = b"vpsctl-reality-fallback-ok\n"
            response = (
                b"HTTP/1.1 200 OK\r\n"
                b"Connection: close\r\n"
                b"Content-Type: text/plain\r\n"
                + f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
                + body
            )
            tls_connection.sendall(response)
    except (ConnectionError, OSError, ssl.SSLError):
        connection.close()


def main():
    if len(sys.argv) != 6:
        raise SystemExit("usage: reality-anti-relay-target.py HOST PORT CERT KEY EVIDENCE")
    host, port_text, certificate, key, evidence_path = sys.argv[1:]
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificate, key)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((host, int(port_text)))
        listener.listen(32)
        while True:
            connection, _address = listener.accept()
            thread = threading.Thread(
                target=handle,
                args=(connection, context, evidence_path),
                daemon=True,
            )
            thread.start()


if __name__ == "__main__":
    main()
