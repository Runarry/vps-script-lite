# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR
# Shared backup code; loading it never prepares tools or writes state.
# shellcheck source=backup/config.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/backup/config.sh"
# shellcheck source=backup/repository.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/backup/repository.sh"
# shellcheck source=backup/jobs.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/backup/jobs.sh"
# shellcheck source=backup/schedule.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/backup/schedule.sh"
