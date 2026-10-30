#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
IFS=$'\n\t'

REPO_PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../lib/command.sh
source "$REPO_PROJECT_ROOT/lib/command.sh"
# shellcheck source=../../lib/backup.sh
source "$REPO_PROJECT_ROOT/lib/backup.sh"
# shellcheck source=backup-repo/cli.sh
source "$REPO_PROJECT_ROOT/commands/system/backup-repo/cli.sh"

backup_repo_main() {
    vps_cmd_init system-backup-repo "$REPO_PROJECT_ROOT" || return $?
    backup_init "$REPO_PROJECT_ROOT" || return $?
    backup_repo_parse "$@" || {
        backup_repo_usage >&2
        return 2
    }
    [[ "$REPO_ACTION" != help ]] || {
        backup_repo_usage
        return 0
    }
    if [[ -z "$REPO_ACTION" ]]; then
        if vps_cmd_is_interactive; then
            backup_repo_menu
            return $?
        fi
        REPO_ACTION=status
    fi
    case "$REPO_ACTION" in
        status | list) backup_repo_status ;;
        *) backup_repo_action ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then backup_repo_main "$@"; fi
