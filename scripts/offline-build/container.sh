#!/usr/bin/env bash
# Internal entry point, run only inside the matching disposable official image.
set -euo pipefail
IFS=$'\n\t'
umask 022
OS=$1 OS_VERSION=$2 ARCH=$3 RELEASE_VERSION=$4
source /etc/os-release
[[ "$ID" == "$OS" && "$VERSION_ID" == "$OS_VERSION" && "$(dpkg --print-architecture)" == "$ARCH" ]] || {
    printf 'offline builder: image does not match requested target\n' >&2; exit 1;
}
export DEBIAN_FRONTEND=noninteractive
# Replace image defaults explicitly, including updates/security and Ubuntu universe.
rm -f -- /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources
case "$OS:$OS_VERSION" in
    debian:12) suite=bookworm ;;
    debian:13) suite=trixie ;;
    ubuntu:22.04) suite=jammy ;;
    ubuntu:24.04) suite=noble ;;
    *) exit 2 ;;
esac
if [[ "$OS" == debian ]]; then
    printf 'deb http://deb.debian.org/debian %s main\ndeb http://deb.debian.org/debian %s-updates main\ndeb http://security.debian.org/debian-security %s-security main\n' \
        "$suite" "$suite" "$suite" >/etc/apt/sources.list
else
    if [[ "$ARCH" == arm64 ]]; then
        mirror=http://ports.ubuntu.com/ubuntu-ports
        security=$mirror
    else
        mirror=http://archive.ubuntu.com/ubuntu
        security=http://security.ubuntu.com/ubuntu
    fi
    printf 'deb %s %s main universe\ndeb %s %s-updates main universe\ndeb %s %s-security main universe\n' \
        "$mirror" "$suite" "$mirror" "$suite" "$security" "$suite" >/etc/apt/sources.list
fi
apt-get update
apt-get install -y --no-install-recommends python3 dpkg-dev ca-certificates
mkdir -p /work/cache/partial /work/package/apt/pool
: >/work/empty-status
: >/work/empty-extended-states
# shellcheck source=packages.sh
source /builder/packages.sh
options=(
    -o Dir::State::status=/work/empty-status
    -o Dir::State::extended_states=/work/empty-extended-states
    -o Dir::Cache::archives=/work/cache
    -o APT::Install-Recommends=false
    -o APT::Install-Suggests=false
    -o APT::Get::List-Cleanup=false
)
# Empty status is essential: using the image's installed package database silently
# omits libc, Python and other dependencies that a clean target may need.
apt-get "${options[@]}" --print-uris --yes --download-only install "${packages[@]}" >/work/uris.txt
apt-get "${options[@]}" --yes --download-only install "${packages[@]}"
cp /work/cache/*.deb /work/package/apt/pool/
cp /etc/apt/sources.list /work/package/apt/sources.list
(cd /work/package/apt && dpkg-scanpackages --multiversion pool /dev/null >Packages)
python3 /builder/package.py prepare /work/package /online /snapshot "$RELEASE_VERSION" "$OS" "$OS_VERSION" "$ARCH" /work/uris.txt
python3 /builder/package.py smoke /work/package
python3 /builder/package.py finalize /work/package /output "$RELEASE_VERSION" "$OS" "$OS_VERSION" "$ARCH"
