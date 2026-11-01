#!/usr/bin/env bash
# Internal disconnected acceptance; run by test-offline-platforms-real.sh only.
set -euo pipefail
IFS=$'\n\t'
OS=$1 OS_VERSION=$2 ARCH=$3
source /etc/os-release
[[ "$ID" == "$OS" && "$VERSION_ID" == "$OS_VERSION" && "$(dpkg --print-architecture)" == "$ARCH" ]]
export DEBIAN_FRONTEND=noninteractive
# Do not start daemons in this disposable non-systemd container.
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
mkdir -p /work/lists/partial /work/no-sources
printf 'deb [trusted=yes] file:/offline/apt ./\n' >/work/offline.list
: >/work/empty-status
options=(
    -o Dir::Etc::sourcelist=/work/offline.list
    -o Dir::Etc::sourceparts=/work/no-sources
    -o Dir::State::lists=/work/lists
    -o APT::Install-Recommends=false
    -o APT::Install-Suggests=false
)
# shellcheck source=packages.sh
source /builder/packages.sh
apt-get "${options[@]}" update
# Resolve from an entirely empty package database to prove no image-installed
# dependency can hide a missing .deb in the local repository.
apt-get "${options[@]}" -o Dir::State::status=/work/empty-status --simulate install "${packages[@]}"
apt-get "${options[@]}" --yes install "${packages[@]}"
dpkg --audit
python3 /builder/package.py smoke /offline
printf 'PASS: disconnected package installation and upstream checks: %s %s %s\n' "$OS" "$OS_VERSION" "$ARCH"
