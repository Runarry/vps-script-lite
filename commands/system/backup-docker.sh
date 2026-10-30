#!/usr/bin/env bash
# Docker backup entry point; storage and scheduling are shared with system backup.
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
IFS=$'\n\t'

BD_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/command.sh
source "$BD_ROOT/lib/command.sh"
# shellcheck source=../../lib/backup.sh
source "$BD_ROOT/lib/backup.sh"
# shellcheck source=backup-docker/actions.sh
source "$BD_ROOT/commands/system/backup-docker/actions.sh"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then bd_main "$@"; fi
