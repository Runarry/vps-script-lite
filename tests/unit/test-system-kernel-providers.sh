#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
# shellcheck source-path=SCRIPTDIR

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
TEST_TEMP="$(mktemp -d)"
readonly TEST_TEMP
TEST_SYSTEM_ROOT="${TEST_TEMP}/system"
readonly TEST_SYSTEM_ROOT
trap 'rm -rf -- "$TEST_TEMP"' EXIT

mkdir -p \
    "$TEST_SYSTEM_ROOT/etc" \
    "$TEST_SYSTEM_ROOT/proc" \
    "$TEST_SYSTEM_ROOT/sys/firmware/efi/efivars" \
    "$TEST_SYSTEM_ROOT/var/lib/vpsctl/system/kernel-bbrv3" \
    "$TEST_SYSTEM_ROOT/var/lib/vpsctl/system/kernel"
printf 'ID=debian\nVERSION_ID="13"\nVERSION="13 (trixie)"\nVERSION_CODENAME=trixie\n' >"$TEST_SYSTEM_ROOT/etc/os-release"

export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_ENV_KERNEL_NAME=Linux
export VPSCTL_ENV_PACKAGE_MANAGER=apt-get

# shellcheck source=../../lib/command.sh
# shellcheck disable=SC1091
source "$TEST_ROOT/lib/command.sh"

readonly KERNEL_MANAGED_MARKER='# Managed by vpsctl system kernel.'
readonly KERNEL_XANMOD_KEY_URL='https://dl.xanmod.org/archive.key'
readonly KERNEL_XANMOD_REPO_URL='https://deb.xanmod.org'
readonly KERNEL_DOWNLOAD_USER_AGENT='test'
readonly KERNEL_XANMOD_KEY_FINGERPRINT='D38D7D1DA1349567ADED882D86F7D09EE734E623'
readonly KERNEL_REPO_LOGICAL='/etc/apt/sources.list.d/vpsctl-xanmod.sources'
readonly KERNEL_KEY_LOGICAL='/etc/apt/keyrings/vpsctl-xanmod-archive-keyring.gpg'
readonly KERNEL_STATE_LOGICAL='/var/lib/vpsctl/system/kernel-bbrv3/state'
readonly KERNEL_OFFICIAL_STATE_LOGICAL='/var/lib/vpsctl/system/kernel/install-state'

KERNEL_TYPE=xanmod
KERNEL_OS_ID=unknown
KERNEL_OS_VERSION_ID=''
KERNEL_OS_VERSION=''
KERNEL_OS_CODENAME=''
KERNEL_ARCH=unknown
KERNEL_VIRTUALIZATION=unknown
KERNEL_RUNNING_RELEASE=unknown
KERNEL_CPUINFO_FILE="$TEST_SYSTEM_ROOT/proc/cpuinfo"
KERNEL_CPU_LEVEL=auto
KERNEL_EFFECTIVE_LEVEL=''
KERNEL_TRACK=auto
KERNEL_SELECTED_PACKAGE=''
KERNEL_SELECTED_VERSION=''
KERNEL_REPO_FILE="$TEST_SYSTEM_ROOT/etc/apt/sources.list.d/vpsctl-xanmod.sources"
KERNEL_KEY_FILE="$TEST_SYSTEM_ROOT/etc/apt/keyrings/vpsctl-xanmod-archive-keyring.gpg"
KERNEL_STATE_FILE="$TEST_SYSTEM_ROOT/var/lib/vpsctl/system/kernel-bbrv3/state"
KERNEL_REPO_CREATED=0
KERNEL_KEY_CREATED=0
KERNEL_TMP_DIR=''

# shellcheck source=../../commands/system/kernel/providers.sh
# shellcheck disable=SC1091
source "$TEST_ROOT/commands/system/kernel/providers.sh"

test_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

test_assert_equal() {
    local expected="$1" actual="$2" message="$3"
    [[ "$expected" == "$actual" ]] || test_fail "${message}: expected '${expected}', got '${actual}'"
}

test_assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    [[ "$haystack" == *"$needle"* ]] || test_fail "${message}: missing '${needle}'"
}

test_reset_platform() {
    KERNEL_OS_ID=debian
    KERNEL_OS_VERSION_ID=13
    KERNEL_OS_VERSION='13 (trixie)'
    KERNEL_OS_CODENAME=trixie
    KERNEL_ARCH=x86_64
    KERNEL_VIRTUALIZATION=kvm
    KERNEL_TYPE=xanmod
}

test_candidates_by_type() (
    local output status=0
    test_reset_platform

    KERNEL_TYPE=official
    test_assert_equal linux-image-amd64 "$(kernel_candidate_packages)" 'Debian official package'
    KERNEL_TYPE=cloud
    test_assert_equal linux-image-cloud-amd64 "$(kernel_candidate_packages)" 'Debian cloud package'

    KERNEL_OS_ID=ubuntu
    KERNEL_OS_VERSION_ID=24.04
    KERNEL_OS_VERSION='24.04.3 LTS (Noble Numbat)'
    KERNEL_OS_CODENAME=noble
    KERNEL_TYPE=official
    test_assert_equal linux-generic "$(kernel_candidate_packages)" 'Ubuntu official package'
    KERNEL_TYPE=hwe
    test_assert_equal linux-generic-hwe-24.04 "$(kernel_candidate_packages)" 'Ubuntu HWE package'

    KERNEL_EFFECTIVE_LEVEL=3
    KERNEL_TRACK=auto
    KERNEL_TYPE=xanmod
    output="$(kernel_candidate_packages)"
    test_assert_equal $'linux-xanmod-x64v3\nlinux-xanmod-x64v2\nlinux-xanmod-lts-x64v3\nlinux-xanmod-lts-x64v2\nlinux-xanmod-lts-x64v1' "$output" 'XanMod fallback order'

    KERNEL_TYPE=hwe
    KERNEL_OS_VERSION='25.10 (Questing Quokka)'
    kernel_candidate_packages >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" 'non-LTS HWE rejection'
)

APT_INDEX_MODE=official
APT_POLICY_MODE=official
APT_PLAN_MODE=''
PLAN_POLICY_MODE=''
XANMOD_INDEX_SIGNED_BY=valid
XANMOD_INDEX_TRUSTED=yes
XANMOD_INDEX_CODENAME=trixie
XANMOD_INDEX_SITE=https://deb.xanmod.org
XANMOD_INDEX_IDENTIFIER=Packages
XANMOD_INDEX_DESCRIPTION='https://deb.xanmod.org trixie/main amd64 Packages'
XANMOD_PLAN_PACKAGE=linux-xanmod-x64v3
XANMOD_PLAN_VERSION=7.1.11-xanmod1-0

apt-get() {
    if [[ "${1:-}" == --simulate ]]; then
        [[ "${2:-}" == -o && "${3:-}" == APT::Get::AutomaticRemove=false && "${4:-}" == install && "${5:-}" == --no-remove && "${6:-}" == --no-install-recommends && "${7:-}" == *=* && $# == 7 ]] || return 97
        case "$APT_PLAN_MODE" in
            official-dependencies)
                printf '%s\n' \
                    'Inst linux-image-6.12.107+deb13-amd64 (6.12.107-1 Debian-Security:13/stable-security [amd64])' \
                    'Inst initramfs-tools (0.148.3 Debian:13/stable [all])' \
                    'Inst linux-image-amd64 [6.12.105-1] (6.12.107-1 Debian-Security:13/stable-security [amd64])' \
                    'Conf linux-image-6.12.107+deb13-amd64 (6.12.107-1 Debian-Security:13/stable-security [amd64])' \
                    'Conf initramfs-tools (0.148.3 Debian:13/stable [all])' \
                    'Conf linux-image-amd64 (6.12.107-1 Debian-Security:13/stable-security [amd64])'
                ;;
            foreign-concrete | mixed-concrete)
                printf '%s\n' \
                    'Inst linux-image-6.12.107+deb13-amd64 (6.12.107-1 Example:13/stable [amd64])' \
                    'Inst linux-image-amd64 [6.12.105-1] (6.12.107-1 Debian-Security:13/stable-security [amd64])' \
                    'Conf linux-image-6.12.107+deb13-amd64 (6.12.107-1 Example:13/stable [amd64])' \
                    'Conf linux-image-amd64 (6.12.107-1 Debian-Security:13/stable-security [amd64])'
                ;;
            xanmod-with-distribution-dependency)
                printf '%s\n' \
                    'Inst initramfs-tools (0.148.3 Debian:13/stable [all])' \
                    "Inst $XANMOD_PLAN_PACKAGE ($XANMOD_PLAN_VERSION XanMod:trixie [amd64])" \
                    'Conf initramfs-tools (0.148.3 Debian:13/stable [all])' \
                    "Conf $XANMOD_PLAN_PACKAGE ($XANMOD_PLAN_VERSION XanMod:trixie [amd64])"
                ;;
            unknown-conf)
                printf '%s\n' 'Conf half-configured (1.0 Debian:13/stable [amd64])'
                ;;
            no-changes)
                printf '%s\n' 'linux-image-amd64 is already the newest version (6.12.107-1).'
                ;;
            remove)
                printf '%s\n' 'Remv linux-image-old [1.0]'
                ;;
            malformed)
                printf '%s\n' 'Inst cannot-parse'
                ;;
            ubuntu-empty-dependency-state)
                printf '%s\n' \
                    'Inst linux-virtual [6.8.0-138.138] (6.8.0-139.139 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [amd64]) []' \
                    'Conf linux-virtual (6.8.0-139.139 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [amd64])'
                ;;
            ubuntu-package-dependency-state)
                printf '%s\n' \
                    'Inst linux-virtual [6.8.0-138.138] (6.8.0-139.139 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [amd64]) [linux-image-unsigned-6.8.0-139-generic:amd64 ]' \
                    'Conf linux-virtual (6.8.0-139.139 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [amd64])'
                ;;
            ubuntu-invalid-dependency-state)
                printf '%s\n' \
                    'Inst linux-virtual [6.8.0-138.138] (6.8.0-139.139 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [amd64]) [linux-image:amd64;unexpected ]' \
                    'Conf linux-virtual (6.8.0-139.139 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [amd64])'
                ;;
            *) return 98 ;;
        esac
        return 0
    fi
    [[ "${1:-}" == indextargets ]] || return 2
    if (($# > 1)); then
        [[ $# == 5 && "${2:-}" == -o && "${3:-}" == "Dir::Etc::sourcelist=$KERNEL_REPO_FILE" && "${4:-}" == -o && "${5:-}" == Dir::Etc::sourceparts=- ]] || return 97
        [[ -z "${XANMOD_INDEX_CALL_LOG:-}" ]] || printf 'scoped\n' >>"$XANMOD_INDEX_CALL_LOG"
        [[ "$APT_INDEX_MODE" != failure ]] || return 100
        printf '%s\n' \
            "Description: $XANMOD_INDEX_DESCRIPTION" \
            "Codename: $XANMOD_INDEX_CODENAME" \
            "Site: $XANMOD_INDEX_SITE" \
            "Trusted: $XANMOD_INDEX_TRUSTED" \
            "Identifier: $XANMOD_INDEX_IDENTIFIER"
        case "$XANMOD_INDEX_SIGNED_BY" in
            valid) printf 'Signed-By: %s\n' "$KERNEL_KEY_LOGICAL" ;;
            missing) ;;
            empty) printf 'Signed-By: \n' ;;
            *) printf 'Signed-By: %s\n' "$XANMOD_INDEX_SIGNED_BY" ;;
        esac
        printf '\n'
        return 0
    fi
    case "$APT_INDEX_MODE" in
        official)
            printf '%s\n' \
                'Description: http://deb.debian.org/debian trixie/main amd64 Packages' \
                'Codename: trixie' \
                'Suite: stable' \
                'Release: trixie' \
                'Label: Debian' \
                'Origin: Debian' \
                'Trusted: yes' \
                'Identifier: Packages' \
                '' \
                'Description: http://security.debian.org/debian-security trixie-security/main amd64 Packages' \
                'Codename: trixie-security' \
                'Suite: stable-security' \
                'Release: trixie-security' \
                'Label: Debian-Security' \
                'Origin: Debian' \
                'Trusted: yes' \
                'Identifier: Packages' \
                ''
            ;;
        foreign-suite)
            printf '%s\n' \
                'Description: http://deb.debian.org/debian jammy/main amd64 Packages' \
                'Codename: jammy' \
                'Suite: stable' \
                'Release: jammy' \
                'Label: Debian' \
                'Origin: Debian' \
                'Trusted: yes' \
                'Identifier: Packages' \
                ''
            ;;
        foreign-origin)
            printf '%s\n' \
                'Description: https://packages.example trixie/main amd64 Packages' \
                'Codename: trixie' \
                'Suite: stable' \
                'Release: trixie' \
                'Label: Example' \
                'Origin: Example' \
                'Trusted: yes' \
                'Identifier: Packages' \
                ''
            ;;
        combined)
            printf '%s\n' \
                'Description: http://deb.debian.org/debian trixie/main amd64 Packages' \
                'Codename: trixie' \
                'Suite: stable' \
                'Release: trixie' \
                'Label: Debian' \
                'Origin: Debian' \
                'Trusted: yes' \
                'Identifier: Packages' \
                '' \
                'Description: https://deb.xanmod.org trixie/main amd64 Packages' \
                'Codename: trixie' \
                'Site: https://deb.xanmod.org' \
                'Signed-By: /etc/apt/keyrings/vpsctl-xanmod-archive-keyring.gpg' \
                'Trusted: yes' \
                'Identifier: Packages' \
                ''
            ;;
        ubuntu-pockets)
            printf '%s\n' \
                'Description: http://archive.ubuntu.com/ubuntu noble/main amd64 Packages' \
                'Codename: noble' \
                'Suite: noble' \
                'Release: noble' \
                'Label: Ubuntu' \
                'Origin: Ubuntu' \
                'Trusted: yes' \
                'Identifier: Packages' \
                '' \
                'Description: http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages' \
                'Codename: noble' \
                'Suite: noble-updates' \
                'Release: noble-updates' \
                'Label: Ubuntu' \
                'Origin: Ubuntu' \
                'Trusted: yes' \
                'Identifier: Packages' \
                '' \
                'Description: http://archive.ubuntu.com/ubuntu noble-proposed/main amd64 Packages' \
                'Codename: noble' \
                'Suite: noble-proposed' \
                'Release: noble-proposed' \
                'Label: Ubuntu' \
                'Origin: Ubuntu' \
                'Trusted: yes' \
                'Identifier: Packages' \
                '' \
                'Description: http://archive.ubuntu.com/ubuntu noble-backports/main amd64 Packages' \
                'Codename: noble' \
                'Suite: noble-backports' \
                'Release: noble-backports' \
                'Label: Ubuntu' \
                'Origin: Ubuntu' \
                'Trusted: yes' \
                'Identifier: Packages' \
                ''
            ;;
        failure) return 100 ;;
    esac
}

apt-cache() {
    [[ "${1:-}" == policy && $# == 2 ]] || return 2
    if [[ -n "$PLAN_POLICY_MODE" ]]; then
        local package="${2:-}" version source
        case "$package" in
            linux-image-amd64 | linux-image-6.12.107+deb13-amd64) version=6.12.107-1 ;;
            initramfs-tools) version=0.148.3 ;;
            linux-xanmod-x64v3) version=7.1.11-xanmod1-0 ;;
            linux-xanmod-lts-x64v3) version=6.18.49-xanmod1-0 ;;
            linux-virtual) version=6.8.0-139.139 ;;
            *) return 99 ;;
        esac
        case "$PLAN_POLICY_MODE:$package" in
            foreign:linux-image-6.12.107+deb13-amd64)
                source='https://packages.example trixie/main amd64 Packages'
                ;;
            mixed:linux-image-6.12.107+deb13-amd64)
                printf '%s\n' \
                    "$package:" \
                    "  Candidate: $version" \
                    '  Version table:' \
                    "     $version 500" \
                    '        500 http://security.debian.org/debian-security trixie-security/main amd64 Packages' \
                    '        100 https://packages.example trixie/main amd64 Packages'
                return 0
                ;;
            xanmod:linux-xanmod* | xanmod-mixed:linux-xanmod*)
                source='https://deb.xanmod.org trixie/main amd64 Packages'
                ;;
            ubuntu:linux-virtual)
                source='http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages'
                ;;
            *)
                if [[ "$package" == linux-image-* ]]; then
                    source='http://security.debian.org/debian-security trixie-security/main amd64 Packages'
                else
                    source='http://deb.debian.org/debian trixie/main amd64 Packages'
                fi
                ;;
        esac
        printf '%s\n' \
            "$package:" \
            "  Candidate: $version" \
            '  Version table:' \
            "     $version 500" \
            "        500 $source"
        if [[ "$PLAN_POLICY_MODE" == xanmod-mixed && "$package" == linux-xanmod* ]]; then
            printf '%s\n' '        100 https://packages.example trixie/main amd64 Packages'
        fi
        return 0
    fi
    case "$APT_POLICY_MODE" in
        official)
            printf '%s\n' \
                'linux-image-amd64:' \
                '  Installed: (none)' \
                '  Candidate: 6.12.107-1' \
                '  Version table:' \
                '     6.12.107-1 500' \
                '        500 http://security.debian.org/debian-security trixie-security/main amd64 Packages'
            ;;
        base)
            printf '%s\n' \
                'linux-image-amd64:' \
                '  Installed: (none)' \
                '  Candidate: 6.12.94-1' \
                '  Version table:' \
                '     6.12.94-1 500' \
                '        500 http://deb.debian.org/debian trixie/main amd64 Packages'
            ;;
        mixed)
            printf '%s\n' \
                'linux-image-amd64:' \
                '  Installed: (none)' \
                '  Candidate: 6.12.107-1' \
                '  Version table:' \
                '     6.12.107-1 500' \
                '        500 http://security.debian.org/debian-security trixie-security/main amd64 Packages' \
                '        100 https://packages.example trixie/main amd64 Packages'
            ;;
        foreign)
            printf '%s\n' \
                'linux-image-amd64:' \
                '  Installed: (none)' \
                '  Candidate: 9.9.9-1' \
                '  Version table:' \
                '     9.9.9-1 1001' \
                '       1001 https://packages.example trixie/main amd64 Packages'
            ;;
        none)
            printf '%s\n' '  Candidate: (none)'
            ;;
        failure) return 100 ;;
        xanmod)
            printf '%s\n' \
                'linux-xanmod-x64v3:' \
                '  Installed: (none)' \
                '  Candidate: 7.1.11-xanmod1-0' \
                '  Version table:' \
                '     7.1.11-xanmod1-0 500' \
                '        500 https://deb.xanmod.org trixie/main amd64 Packages'
            ;;
        xanmod-mixed)
            printf '%s\n' \
                'linux-xanmod-x64v3:' \
                '  Installed: (none)' \
                '  Candidate: 7.1.11-xanmod1-0' \
                '  Version table:' \
                '     7.1.11-xanmod1-0 500' \
                '        500 https://deb.xanmod.org trixie/main amd64 Packages' \
                '        100 https://packages.example trixie/main amd64 Packages'
            ;;
        ubuntu-updates)
            printf '%s\n' \
                'linux-generic:' \
                '  Installed: (none)' \
                '  Candidate: 6.8.0.79.81' \
                '  Version table:' \
                '     6.8.0.79.81 500' \
                '        500 http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages'
            ;;
        ubuntu-proposed)
            printf '%s\n' \
                'linux-generic:' \
                '  Installed: (none)' \
                '  Candidate: 6.8.0.80.82' \
                '  Version table:' \
                '     6.8.0.80.82 500' \
                '        500 http://archive.ubuntu.com/ubuntu noble-proposed/main amd64 Packages'
            ;;
        ubuntu-backports)
            printf '%s\n' \
                'linux-generic:' \
                '  Installed: (none)' \
                '  Candidate: 6.8.0.81.83' \
                '  Version table:' \
                '     6.8.0.81.83 500' \
                '        500 http://archive.ubuntu.com/ubuntu noble-backports/main amd64 Packages'
            ;;
    esac
}

dpkg-query() { return 0; }

test_distribution_candidate_origin() (
    local version status=0
    test_reset_platform
    KERNEL_TYPE=official

    APT_INDEX_MODE=official
    APT_POLICY_MODE=official
    version="$(kernel_package_candidate_version linux-image-amd64)"
    test_assert_equal 6.12.107-1 "$version" 'security candidate acceptance'

    APT_POLICY_MODE=base
    version="$(kernel_package_candidate_version linux-image-amd64)"
    test_assert_equal 6.12.94-1 "$version" 'distribution mirror candidate acceptance'

    APT_POLICY_MODE=mixed
    kernel_package_candidate_version linux-image-amd64 >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'same-version third-party rejection'

    status=0
    APT_INDEX_MODE=foreign-suite
    APT_POLICY_MODE=base
    kernel_package_candidate_version linux-image-amd64 >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'foreign suite rejection'

    status=0
    APT_INDEX_MODE=foreign-origin
    APT_POLICY_MODE=foreign
    kernel_package_candidate_version linux-image-amd64 >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'foreign origin rejection'

    status=0
    APT_POLICY_MODE=failure
    kernel_package_candidate_version linux-image-amd64 >/dev/null 2>&1 || status=$?
    test_assert_equal 20 "$status" 'apt-cache query failure propagation'

    status=0
    APT_POLICY_MODE=base
    APT_INDEX_MODE=failure
    kernel_package_candidate_version linux-image-amd64 >/dev/null 2>&1 || status=$?
    test_assert_equal 20 "$status" 'indextarget query failure propagation'
)

test_ubuntu_pocket_suite_validation() (
    local version status=0
    test_reset_platform
    KERNEL_TYPE=official
    KERNEL_OS_ID=ubuntu
    KERNEL_OS_VERSION_ID=24.04
    KERNEL_OS_VERSION='24.04.3 LTS (Noble Numbat)'
    KERNEL_OS_CODENAME=noble
    APT_INDEX_MODE=ubuntu-pockets

    APT_POLICY_MODE=ubuntu-updates
    version="$(kernel_package_candidate_version linux-generic)"
    test_assert_equal 6.8.0.79.81 "$version" 'Ubuntu updates pocket acceptance'

    APT_POLICY_MODE=ubuntu-proposed
    kernel_package_candidate_version linux-generic >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'Ubuntu proposed pocket rejection'

    status=0
    APT_POLICY_MODE=ubuntu-backports
    kernel_package_candidate_version linux-generic >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'Ubuntu backports pocket rejection'
)

test_xanmod_same_version_foreign_origin() (
    local version status=0
    test_reset_platform
    KERNEL_TYPE=xanmod
    APT_POLICY_MODE=xanmod
    version="$(kernel_package_candidate_version linux-xanmod-x64v3)"
    test_assert_equal 7.1.11-xanmod1-0 "$version" 'XanMod official candidate acceptance'

    APT_POLICY_MODE=xanmod-mixed
    kernel_package_candidate_version linux-xanmod-x64v3 >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'XanMod lower-priority same-version foreign rejection'
)

test_install_plan_validation() (
    local status=0
    test_reset_platform
    KERNEL_TYPE=official
    APT_INDEX_MODE=official
    APT_PLAN_MODE=official-dependencies
    PLAN_POLICY_MODE=official
    kernel_validate_install_plan linux-image-amd64 6.12.107-1
    test_assert_equal 6.12.107-1 "${KERNEL_INSTALL_EXPECTED_VERSIONS["linux-image-amd64"]}" 'plan selected meta version'
    test_assert_equal 6.12.107-1 "${KERNEL_INSTALL_EXPECTED_VERSIONS["linux-image-6.12.107+deb13-amd64"]}" 'plan selected concrete version'
    test_assert_equal 0.148.3 "${KERNEL_INSTALL_EXPECTED_VERSIONS["initramfs-tools"]}" 'plan accepted distribution dependency'

    status=0
    APT_PLAN_MODE=foreign-concrete
    PLAN_POLICY_MODE=foreign
    kernel_validate_install_plan linux-image-amd64 6.12.107-1 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'third-party concrete kernel rejection'
    test_assert_equal 0 "${#KERNEL_INSTALL_EXPECTED_VERSIONS[@]}" 'failed foreign plan leaves no expected packages'

    status=0
    APT_PLAN_MODE=mixed-concrete
    PLAN_POLICY_MODE=mixed
    kernel_validate_install_plan linux-image-amd64 6.12.107-1 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'lower-priority same-version concrete rejection'
    test_assert_equal 0 "${#KERNEL_INSTALL_EXPECTED_VERSIONS[@]}" 'failed mixed plan leaves no expected packages'

    status=0
    APT_PLAN_MODE=unknown-conf
    PLAN_POLICY_MODE=official
    kernel_validate_install_plan linux-image-amd64 6.12.107-1 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'Conf without Inst rejection'
    test_assert_equal 0 "${#KERNEL_INSTALL_EXPECTED_VERSIONS[@]}" 'failed Conf plan leaves no expected packages'

    APT_PLAN_MODE=no-changes
    kernel_validate_install_plan linux-image-amd64 6.12.107-1
    test_assert_equal 0 "${#KERNEL_INSTALL_EXPECTED_VERSIONS[@]}" 'no-change plan accepted'

    status=0
    APT_PLAN_MODE=remove
    kernel_validate_install_plan linux-image-amd64 6.12.107-1 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'removal action rejection'

    status=0
    APT_PLAN_MODE=malformed
    kernel_validate_install_plan linux-image-amd64 6.12.107-1 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'malformed Inst rejection'
)

test_ubuntu_install_plan_dependency_state() (
    local status=0
    test_reset_platform
    KERNEL_TYPE=official
    KERNEL_OS_ID=ubuntu
    KERNEL_OS_VERSION_ID=24.04
    KERNEL_OS_VERSION='24.04.3 LTS (Noble Numbat)'
    KERNEL_OS_CODENAME=noble
    APT_INDEX_MODE=ubuntu-pockets
    PLAN_POLICY_MODE=ubuntu

    APT_PLAN_MODE=ubuntu-empty-dependency-state
    kernel_validate_install_plan linux-virtual 6.8.0-139.139
    test_assert_equal 6.8.0-139.139 "${KERNEL_INSTALL_EXPECTED_VERSIONS["linux-virtual"]}" 'Ubuntu empty dependency-state plan'

    APT_PLAN_MODE=ubuntu-package-dependency-state
    kernel_validate_install_plan linux-virtual 6.8.0-139.139
    test_assert_equal 6.8.0-139.139 "${KERNEL_INSTALL_EXPECTED_VERSIONS["linux-virtual"]}" 'Ubuntu package dependency-state plan'

    APT_PLAN_MODE=ubuntu-invalid-dependency-state
    kernel_validate_install_plan linux-virtual 6.8.0-139.139 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'Ubuntu invalid dependency-state rejection'
    test_assert_equal 0 "${#KERNEL_INSTALL_EXPECTED_VERSIONS[@]}" 'invalid dependency-state leaves no expected packages'
)

test_write_xanmod_repository() {
    mkdir -p -- "${KERNEL_REPO_FILE%/*}"
    printf '%s\n' \
        '# Managed by vpsctl system kernel.' \
        'Types: deb' \
        'URIs: https://deb.xanmod.org' \
        "Suites: $KERNEL_OS_CODENAME" \
        'Components: main' \
        'Architectures: amd64' \
        'Signed-By: /etc/apt/keyrings/vpsctl-xanmod-archive-keyring.gpg' >"$KERNEL_REPO_FILE"
}

test_xanmod_index_metadata() (
    local mode output status
    test_reset_platform
    KERNEL_OS_VERSION_ID=12
    KERNEL_OS_CODENAME=bookworm
    XANMOD_INDEX_CODENAME=bookworm
    XANMOD_INDEX_DESCRIPTION='https://deb.xanmod.org bookworm/main amd64 Packages'
    KERNEL_REPO_FILE="$TEST_TEMP/index-metadata/vpsctl-xanmod.sources"
    local XANMOD_INDEX_CALL_LOG="$TEST_TEMP/scoped-index-calls"
    test_write_xanmod_repository
    kernel_primary_key_fingerprint() { printf '%s\n' "$KERNEL_XANMOD_KEY_FINGERPRINT"; }
    for mode in missing valid; do
        XANMOD_INDEX_SIGNED_BY="$mode"
        output="$(_kernel_xanmod_index_descriptions)"
        test_assert_equal "$XANMOD_INDEX_DESCRIPTION" "$output" "XanMod $mode Signed-By acceptance"
    done
    test_assert_equal $'scoped\nscoped' "$(<"$XANMOD_INDEX_CALL_LOG")" 'XanMod scoped indextargets arguments'

    for mode in empty /etc/apt/keyrings/foreign.gpg; do
        status=0
        XANMOD_INDEX_SIGNED_BY="$mode"
        output="$(_kernel_xanmod_index_descriptions 2>&1)" || status=$?
        test_assert_equal 30 "$status" "XanMod $mode Signed-By rejection"
        [[ -n "$output" ]] || test_fail 'missing invalid index diagnostic'
    done
    XANMOD_INDEX_SIGNED_BY=missing
    for mode in trusted codename site identifier description; do
        status=0
        output="$(
            case "$mode" in
                trusted) XANMOD_INDEX_TRUSTED=no ;;
                codename) XANMOD_INDEX_CODENAME=foreign ;;
                site) XANMOD_INDEX_SITE=https://packages.example ;;
                identifier) XANMOD_INDEX_IDENTIFIER=Sources ;;
                description) XANMOD_INDEX_DESCRIPTION='' ;;
            esac
            _kernel_xanmod_index_descriptions 2>&1
        )" || status=$?
        test_assert_equal 30 "$status" "XanMod invalid $mode rejection"
        [[ -n "$output" ]] || test_fail "missing $mode index diagnostic"
    done

    status=0
    APT_INDEX_MODE=failure
    _kernel_xanmod_index_descriptions >/dev/null 2>&1 || status=$?
    test_assert_equal 20 "$status" 'XanMod scoped index query failure'
    APT_INDEX_MODE=official
    status=0
    kernel_primary_key_fingerprint() { printf '%s\n' 'BAD-FINGERPRINT'; }
    _kernel_xanmod_index_descriptions >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'XanMod incorrect key fingerprint rejection'
)

test_xanmod_repository_configuration() (
    local field content status
    local rejected_query_log="$TEST_TEMP/rejected-source-query"
    test_reset_platform
    KERNEL_REPO_FILE="$TEST_TEMP/repository-config/vpsctl-xanmod.sources"
    kernel_primary_key_fingerprint() { printf '%s\n' "$KERNEL_XANMOD_KEY_FINGERPRINT"; }
    apt-get() {
        printf 'unexpected query\n' >>"$rejected_query_log"
        return 98
    }
    for field in marker uri suite component architecture key options missing symlink; do
        test_write_xanmod_repository
        content="$(<"$KERNEL_REPO_FILE")"
        case "$field" in
            marker) content="${content/'# Managed by vpsctl system kernel.'/'# User source'}" ;;
            uri) content="${content/https:\/\/deb.xanmod.org/https:\/\/packages.example}" ;;
            suite) content="${content/'Suites: trixie'/'Suites: bookworm'}" ;;
            component) content="${content/'Components: main'/'Components: other'}" ;;
            architecture) content="${content/'Architectures: amd64'/'Architectures: arm64'}" ;;
            key) content="${content/\/etc\/apt\/keyrings\/vpsctl-xanmod-archive-keyring.gpg/\/etc\/apt\/keyrings\/foreign.gpg}" ;;
            options) content+=$'\nTrusted: yes' ;;
        esac
        printf '%s\n' "$content" >"$KERNEL_REPO_FILE"
        if [[ "$field" == missing || "$field" == symlink ]]; then
            mv -- "$KERNEL_REPO_FILE" "$KERNEL_REPO_FILE.target"
            [[ "$field" != symlink ]] || ln -s "$KERNEL_REPO_FILE.target" "$KERNEL_REPO_FILE"
        fi
        status=0
        _kernel_xanmod_index_descriptions >/dev/null 2>&1 || status=$?
        test_assert_equal 30 "$status" "XanMod $field source configuration rejection"
        [[ ! -e "$rejected_query_log" ]] || test_fail 'invalid repository configuration reached apt-get'
    done
)

test_xanmod_install_plan_distribution_dependency() (
    local mode status
    test_reset_platform
    KERNEL_TYPE=xanmod
    KERNEL_REPO_FILE="$TEST_TEMP/install-plan/vpsctl-xanmod.sources"
    test_write_xanmod_repository
    APT_INDEX_MODE=combined
    APT_PLAN_MODE=xanmod-with-distribution-dependency
    PLAN_POLICY_MODE=xanmod
    kernel_primary_key_fingerprint() { printf '%s\n' "$KERNEL_XANMOD_KEY_FINGERPRINT"; }
    for mode in valid missing; do
        XANMOD_INDEX_SIGNED_BY="$mode"
        for XANMOD_PLAN_PACKAGE in linux-xanmod-x64v3 linux-xanmod-lts-x64v3; do
            if [[ "$XANMOD_PLAN_PACKAGE" == linux-xanmod-lts-x64v3 ]]; then
                XANMOD_PLAN_VERSION=6.18.49-xanmod1-0
            else
                XANMOD_PLAN_VERSION=7.1.11-xanmod1-0
            fi
            kernel_validate_install_plan "$XANMOD_PLAN_PACKAGE" "$XANMOD_PLAN_VERSION"
            test_assert_equal "$XANMOD_PLAN_VERSION" "${KERNEL_INSTALL_EXPECTED_VERSIONS["$XANMOD_PLAN_PACKAGE"]}" "XanMod $mode Signed-By plan meta version"
            test_assert_equal 0.148.3 "${KERNEL_INSTALL_EXPECTED_VERSIONS["initramfs-tools"]}" 'XanMod plan distribution dependency'
        done
        status=0
        PLAN_POLICY_MODE=xanmod-mixed
        kernel_validate_install_plan "$XANMOD_PLAN_PACKAGE" "$XANMOD_PLAN_VERSION" >/dev/null 2>&1 || status=$?
        test_assert_equal 30 "$status" "XanMod $mode Signed-By same-version foreign plan rejection"
        test_assert_equal 0 "${#KERNEL_INSTALL_EXPECTED_VERSIONS[@]}" 'failed XanMod mixed plan leaves no expected packages'
        PLAN_POLICY_MODE=xanmod
    done
)

test_secure_boot_provider_gate() (
    local status=0
    test_reset_platform
    kernel_secure_boot_enabled() { return 0; }
    KERNEL_TYPE=xanmod
    kernel_require_install_platform >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" 'XanMod enabled Secure Boot rejection'

    status=0
    kernel_secure_boot_enabled() { return 2; }
    kernel_require_install_platform >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" 'XanMod unknown Secure Boot rejection'

    status=0
    KERNEL_TYPE=official
    kernel_secure_boot_enabled() { test_fail 'official provider queried Secure Boot'; }
    kernel_require_install_platform >/dev/null 2>&1 || status=$?
    test_assert_equal 0 "$status" 'official kernel allows Secure Boot'
)

test_uninstall_uses_common_gate_only() (
    local status=0
    test_reset_platform
    KERNEL_TYPE=xanmod
    KERNEL_OS_ID=ubuntu
    KERNEL_OS_CODENAME=jammy
    kernel_require_uninstall_platform >/dev/null 2>&1 || status=$?
    test_assert_equal 0 "$status" 'uninstall ignores provider suite gate'
)

test_state_locations() (
    local official_state="$TEST_SYSTEM_ROOT$KERNEL_OFFICIAL_STATE_LOGICAL"
    local xanmod_state="$TEST_SYSTEM_ROOT$KERNEL_STATE_LOGICAL"
    local symlink_target="$TEST_TEMP/user-state" status=0
    test_reset_platform
    vps_cmd_init system-kernel-providers "$TEST_ROOT"

    printf 'legacy\n' >"$xanmod_state"
    KERNEL_TYPE=official
    kernel_write_state linux-image-amd64 6.12.107-1
    test_assert_contains "$(<"$official_state")" 'provider=official' 'official state provider'
    test_assert_equal legacy "$(<"$xanmod_state")" 'official state preserves XanMod state'

    KERNEL_TYPE=xanmod
    KERNEL_EFFECTIVE_LEVEL=3
    KERNEL_TRACK=main
    kernel_write_state linux-xanmod-x64v3 7.1.11-xanmod1 >/dev/null 2>&1 || status=$?
    test_assert_equal 10 "$status" 'unmanaged XanMod state rejection'
    test_assert_equal legacy "$(<"$xanmod_state")" 'unmanaged XanMod state preservation'
    rm -f -- "$xanmod_state"
    kernel_write_state linux-xanmod-x64v3 7.1.11-xanmod1
    test_assert_contains "$(<"$xanmod_state")" 'provider=xanmod' 'XanMod legacy state location'

    printf 'user-owned\n' >"$official_state"
    KERNEL_TYPE=official
    status=0
    kernel_prepare_repository >/dev/null 2>&1 || status=$?
    test_assert_equal 10 "$status" 'unmanaged official state prepare rejection'
    status=0
    kernel_write_state linux-image-amd64 6.12.107-1 >/dev/null 2>&1 || status=$?
    test_assert_equal 10 "$status" 'unmanaged official state write rejection'
    test_assert_equal user-owned "$(<"$official_state")" 'unmanaged official state preservation'

    rm -f -- "$official_state"
    printf 'symlink-target\n' >"$symlink_target"
    ln -s "$symlink_target" "$official_state"
    status=0
    kernel_prepare_repository >/dev/null 2>&1 || status=$?
    [[ "$status" != 0 ]] || test_fail 'official state symlink was accepted by prepare'
    status=0
    kernel_write_state linux-image-amd64 6.12.107-1 >/dev/null 2>&1 || status=$?
    [[ "$status" != 0 ]] || test_fail 'official state symlink was accepted by write'
    test_assert_equal symlink-target "$(<"$symlink_target")" 'official state symlink target preservation'
)

test_load_os_version_fields() (
    unset VPSCTL_ENV_OS_ID VPSCTL_ENV_OS_VERSION_ID VPSCTL_ENV_OS_VERSION VPSCTL_ENV_OS_CODENAME VPSCTL_ENV_ARCH VPSCTL_ENV_VIRTUALIZATION
    kernel_load_platform
    test_assert_equal debian "$KERNEL_OS_ID" 'os-release ID'
    test_assert_equal 13 "$KERNEL_OS_VERSION_ID" 'os-release VERSION_ID'
    test_assert_equal '13 (trixie)' "$KERNEL_OS_VERSION" 'os-release VERSION'
    test_assert_equal trixie "$KERNEL_OS_CODENAME" 'os-release codename'
)

vps_cmd_init system-kernel-providers "$TEST_ROOT"
test_candidates_by_type
test_distribution_candidate_origin
test_ubuntu_pocket_suite_validation
test_xanmod_same_version_foreign_origin
test_install_plan_validation
test_ubuntu_install_plan_dependency_state
test_xanmod_index_metadata
test_xanmod_repository_configuration
test_xanmod_install_plan_distribution_dependency
test_secure_boot_provider_gate
test_uninstall_uses_common_gate_only
test_state_locations
test_load_os_version_fields
printf 'PASS: system kernel provider tests\n'
