#!/usr/bin/env python3
# Managed by vpsctl tcping.
"""Accept and close TCP connections; no application protocol or request logging."""

import argparse
import errno
import json
import os
import selectors
import signal
import socket
import sys
import tempfile


def open_listeners(port):
    listeners = []
    try:
        for family, address, label in (
            (socket.AF_INET, "0.0.0.0", "ipv4"),
            (socket.AF_INET6, "::", "ipv6"),
        ):
            connection = None
            try:
                connection = socket.socket(family, socket.SOCK_STREAM)
                connection.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                if family == socket.AF_INET6:
                    connection.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                connection.bind((address, port))
                connection.listen(128)
                connection.setblocking(False)
            except OSError as error:
                if connection is not None:
                    connection.close()
                if family == socket.AF_INET6 and error.errno in (
                    errno.EAFNOSUPPORT,
                    errno.EPROTONOSUPPORT,
                    errno.EADDRNOTAVAIL,
                ):
                    continue
                raise
            listeners.append((connection, label))
        return listeners
    except BaseException:
        for connection, _ in listeners:
            connection.close()
        raise


def publish_ready(path, port, families):
    descriptor, temporary = tempfile.mkstemp(prefix=".tcping-ready.", dir=os.path.dirname(path))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump({"pid": os.getpid(), "port": port, "families": families}, stream)
            stream.write("\n")
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--ready-file")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port must be between 1 and 65535")
    if not args.check and not args.ready_file:
        parser.error("--ready-file is required when serving")

    listeners = []
    published = False
    selector = selectors.DefaultSelector()

    def stop(_signal, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        listeners = open_listeners(args.port)
        if args.check:
            return 0
        for connection, _ in listeners:
            selector.register(connection, selectors.EVENT_READ)
        publish_ready(args.ready_file, args.port, [label for _, label in listeners])
        published = True
        print("TCPing ready on port {} ({})".format(
            args.port, ", ".join(label for _, label in listeners)), flush=True)
        while True:
            for key, _ in selector.select():
                # Bound each batch so both address families continue to be served.
                for _ in range(128):
                    try:
                        connection, _ = key.fileobj.accept()
                    except BlockingIOError:
                        break
                    except ConnectionAbortedError:
                        continue
                    connection.close()
    except OSError as error:
        print("TCPing listener: {}".format(error), file=sys.stderr)
        return 3
    finally:
        selector.close()
        for connection, _ in listeners:
            connection.close()
        if published:
            try:
                os.unlink(args.ready_file)
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    sys.exit(main())
