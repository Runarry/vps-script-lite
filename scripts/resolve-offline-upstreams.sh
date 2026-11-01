#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ $# == 1 ]] || { printf 'usage: scripts/resolve-offline-upstreams.sh SNAPSHOT_DIR\n' >&2; exit 2; }
exec python3 "${SCRIPT_DIR}/offline-build/upstreams.py" "$1"
