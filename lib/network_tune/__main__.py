"""Source-tree and packaged entry point; never run project code on the editor host."""
import os
import sys

if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from network_tune.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
