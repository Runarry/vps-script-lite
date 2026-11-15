#!/usr/bin/env python3
"""Embed the canonical network tune zipapp in the standalone PO0 script."""

import argparse
import base64
from pathlib import Path
import stat
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PO0_SCRIPT = ROOT / "scripts/po0-relay.sh"
PAYLOAD_START = b"<<'PO0_NETWORK_TUNE_PAYLOAD'\n"
PAYLOAD_END = b"PO0_NETWORK_TUNE_PAYLOAD\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify the embedded payload without writing")
    args = parser.parse_args()

    sys.dont_write_bytecode = True
    sys.path.insert(0, str(ROOT / "lib"))
    from network_tune.common import runtime_archive

    current = PO0_SCRIPT.read_bytes()
    prefix, start, rest = current.partition(PAYLOAD_START)
    _, end, suffix = rest.partition(PAYLOAD_END)
    if not start or not end or current.count(PAYLOAD_START) != 1:
        parser.exit(1, "po0-relay.sh is missing its unique network tune payload block\n")
    payload = base64.encodebytes(runtime_archive())
    generated = prefix + start + payload + end + suffix
    if generated == current:
        return
    if args.check:
        parser.exit(1, "po0-relay.sh payload is stale. Run python3 scripts/embed-network-tune.py\n")

    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=PO0_SCRIPT.parent, prefix=".po0-relay-", delete=False) as work:
            temporary = Path(work.name)
            work.write(generated)
        temporary.chmod(stat.S_IMODE(PO0_SCRIPT.stat().st_mode))
        temporary.replace(PO0_SCRIPT)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
