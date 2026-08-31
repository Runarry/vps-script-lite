#!/usr/bin/env bash
# Function overrides below are deliberately invoked through sourced production code.
# shellcheck disable=SC2030,SC2031,SC2034,SC2317

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
    "$TEST_SYSTEM_ROOT/etc/apt/sources.list.d" \
    "$TEST_SYSTEM_ROOT/etc/apt/keyrings" \
    "$TEST_SYSTEM_ROOT/var/lib/vpsctl/system/kernel-bbrv3" \
    "$TEST_SYSTEM_ROOT/proc/sys/net/ipv4" \
    "$TEST_SYSTEM_ROOT/proc/sys/net/core" \
    "$TEST_SYSTEM_ROOT/sys/firmware/efi/efivars" \
    "$TEST_SYSTEM_ROOT/boot" \
    "$TEST_SYSTEM_ROOT/lib/modules" \
    "$TEST_SYSTEM_ROOT/run/vpsctl"

printf 'ID=debian\nVERSION_CODENAME=bookworm\n' >"$TEST_SYSTEM_ROOT/etc/os-release"
printf 'bbr\n' >"$TEST_SYSTEM_ROOT/proc/sys/net/ipv4/tcp_congestion_control"
printf 'fq\n' >"$TEST_SYSTEM_ROOT/proc/sys/net/core/default_qdisc"

export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_ENV_KERNEL_NAME=Linux
export VPSCTL_ENV_OS_ID=debian
export VPSCTL_ENV_OS_CODENAME=bookworm
export VPSCTL_ENV_ARCH=x86_64
export VPSCTL_ENV_PACKAGE_MANAGER=apt-get
export VPSCTL_ENV_VIRTUALIZATION=kvm
export VPSCTL_NON_INTERACTIVE=1
export VPSCTL_NO_COLOR=1

# shellcheck source=../../commands/system/kernel.sh
# shellcheck disable=SC1091
source "$TEST_ROOT/commands/system/kernel.sh"

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

test_assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    [[ "$haystack" != *"$needle"* ]] || test_fail "${message}: unexpected '${needle}'"
}

test_init() {
    vps_cmd_init system-kernel "$TEST_ROOT"
    kernel_init_paths
    kernel_load_platform
}

write_cpu_flags() {
    printf 'processor : 0\nflags : %s\n' "$1" >"$TEST_SYSTEM_ROOT/proc/cpuinfo"
}

test_arguments() {
    local status=0
    kernel_parse_args install --track lts --cpu-level v2 --confirm-install INSTALL-XANMOD-BBRV3
    test_assert_equal install "$KERNEL_ACTION" 'install action'
    test_assert_equal lts "$KERNEL_TRACK" 'track option'
    test_assert_equal v2 "$KERNEL_CPU_LEVEL" 'CPU level option'

    kernel_parse_args uninstall --confirm-uninstall REMOVE-XANMOD-BBRV3
    kernel_validate_action_options
    test_assert_equal uninstall "$KERNEL_ACTION" 'uninstall action'

    status=0
    kernel_parse_args install --track edge >/dev/null 2>&1 || status=$?
    test_assert_equal 2 "$status" 'invalid track exit code'

    status=0
    kernel_parse_args status --cpu-level v2 >/dev/null 2>&1 || status=$?
    if ((status == 0)); then
        kernel_validate_action_options >/dev/null 2>&1 || status=$?
    fi
    test_assert_equal 2 "$status" 'status action-option rejection'
}

test_psabi_and_candidates() {
    local output
    write_cpu_flags 'lm cmov cx8 fpu fxsr mmx syscall sse2'
    test_assert_equal 1 "$(kernel_detect_psabi_level)" 'x86-64-v1 detection'

    write_cpu_flags 'lm cmov cx8 fpu fxsr mmx syscall sse2 cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3'
    test_assert_equal 2 "$(kernel_detect_psabi_level)" 'x86-64-v2 detection'

    write_cpu_flags 'lm cmov cx8 fpu fxsr mmx syscall sse2 cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave'
    test_assert_equal 3 "$(kernel_detect_psabi_level)" 'x86-64-v3 detection'

    KERNEL_EFFECTIVE_LEVEL=3
    KERNEL_TRACK=auto
    output="$(kernel_candidate_packages)"
    test_assert_equal $'linux-xanmod-x64v3\nlinux-xanmod-x64v2\nlinux-xanmod-lts-x64v3\nlinux-xanmod-lts-x64v2\nlinux-xanmod-lts-x64v1' "$output" 'auto candidate order'

    KERNEL_TRACK=main
    KERNEL_EFFECTIVE_LEVEL=1
    test_assert_equal '' "$(kernel_candidate_packages)" 'main has no v1 package'
    KERNEL_TRACK=lts
    test_assert_equal 'linux-xanmod-lts-x64v1' "$(kernel_candidate_packages)" 'LTS v1 package'
    KERNEL_TRACK=auto
}

test_fallback_detection() {
    local output
    printf 'kernel\n' >"$TEST_SYSTEM_ROOT/boot/vmlinuz-6.1.0-amd64"
    printf 'initrd\n' >"$TEST_SYSTEM_ROOT/boot/initrd.img-6.1.0-amd64"
    printf 'kernel\n' >"$TEST_SYSTEM_ROOT/boot/vmlinuz-7.1.0-x64v3-xanmod1"
    printf 'initrd\n' >"$TEST_SYSTEM_ROOT/boot/initrd.img-7.1.0-x64v3-xanmod1"
    ln -s missing-kernel "$TEST_SYSTEM_ROOT/boot/vmlinuz-5.10.0-broken"
    printf 'initrd\n' >"$TEST_SYSTEM_ROOT/boot/initrd.img-5.10.0-broken"
    mkdir -p \
        "$TEST_SYSTEM_ROOT/lib/modules/6.1.0-amd64" \
        "$TEST_SYSTEM_ROOT/lib/modules/7.1.0-x64v3-xanmod1" \
        "$TEST_SYSTEM_ROOT/lib/modules/5.10.0-broken"
    output="$(kernel_fallback_releases)"
    test_assert_equal '6.1.0-amd64' "$output" 'non-XanMod fallback detection'
}

test_secure_boot_detection() {
    local status=0 output
    local efivar="$TEST_SYSTEM_ROOT/sys/firmware/efi/efivars/SecureBoot-test"
    printf '\007\000\000\000\001' >"$efivar"
    kernel_secure_boot_enabled || test_fail 'enabled Secure Boot efivar was not detected'
    printf '\007\000\000\000\000' >"$efivar"
    if kernel_secure_boot_enabled; then
        test_fail 'disabled Secure Boot efivar was reported as enabled'
    fi
    rm -f -- "$efivar"

    status=0
    kernel_secure_boot_enabled || status=$?
    test_assert_equal 2 "$status" 'missing Secure Boot efivar is unverifiable'

    mkdir -p "$TEST_TEMP/empty-bin"
    status=0
    PATH="$TEST_TEMP/empty-bin" kernel_secure_boot_enabled || status=$?
    test_assert_equal 2 "$status" 'missing od is unverifiable'

    status=0
    output="$({ kernel_require_install_platform; } 2>&1)" || status=$?
    test_assert_equal 3 "$status" 'unverifiable Secure Boot rejection'
    test_assert_contains "$output" '无法可靠验证 Secure Boot' 'unverifiable Secure Boot message'

    rm -rf -- "$TEST_SYSTEM_ROOT/sys/firmware/efi"
    status=0
    kernel_secure_boot_enabled || status=$?
    test_assert_equal 1 "$status" 'legacy boot is not Secure Boot'
}

test_status_output() (
    local output
    kernel_query_xanmod_packages() {
        KERNEL_XANMOD_PACKAGES=(linux-xanmod-x64v3 linux-image-7.1.0-x64v3-xanmod1)
    }
    KERNEL_RUNNING_RELEASE='7.1.0-x64v3-xanmod1'
    output="$(kernel_status)"
    test_assert_contains "$output" '正在运行 XanMod BBRv3' 'running status'
    test_assert_contains "$output" 'linux-xanmod-x64v3' 'installed package detail'
    test_assert_contains "$output" '6.1.0-amd64' 'fallback detail'
    test_assert_contains "$output" '拥塞控制' 'congestion status'
)

test_dpkg_state_parsing() (
    local status=0
    dpkg-query() {
        printf '%s\n' \
            $'ii \tlinux-xanmod-x64v3' \
            $'hi \tlinux-image-7.1.0-x64v3-xanmod1' \
            $'rc \tlinux-headers-7.0.0-x64v3-xanmod1' \
            $'ii \tbash'
    }
    kernel_query_xanmod_packages installed
    test_assert_equal 'linux-xanmod-x64v3, linux-image-7.1.0-x64v3-xanmod1' "$(kernel_join_values "${KERNEL_XANMOD_PACKAGES[@]}")" 'configured dpkg states'
    kernel_query_xanmod_packages purge
    test_assert_equal 'linux-xanmod-x64v3, linux-image-7.1.0-x64v3-xanmod1, linux-headers-7.0.0-x64v3-xanmod1' "$(kernel_join_values "${KERNEL_XANMOD_PACKAGES[@]}")" 'purgeable dpkg states'

    dpkg-query() { return 2; }
    status=0
    kernel_query_xanmod_packages purge >/dev/null 2>&1 || status=$?
    test_assert_equal 20 "$status" 'dpkg query failure propagation'

    dpkg-query() { printf '%s\n' $'iF \tlinux-xanmod-x64v3'; }
    status=0
    kernel_query_xanmod_packages installed >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'half-configured package rejection'
)

test_candidate_origin_validation() (
    local version status=0 policy_case=official
    apt-cache() {
        case "$policy_case" in
            official)
                printf '%s\n' \
                    'linux-xanmod-x64v3:' \
                    '  Installed: (none)' \
                    '  Candidate: 7.1.11-xanmod1-0' \
                    '  Version table:' \
                    '     7.1.11-xanmod1-0 500' \
                    '        500 https://deb.xanmod.org trixie/main amd64 Packages'
                ;;
            foreign)
                printf '%s\n' \
                    'linux-xanmod-x64v3:' \
                    '  Installed: (none)' \
                    '  Candidate: 9.9.9-evil' \
                    '  Version table:' \
                    '     9.9.9-evil 1001' \
                    '       1001 https://evil.example trixie/main amd64 Packages' \
                    '        500 https://deb.xanmod.org trixie/main amd64 Packages'
                ;;
            ambiguous)
                printf '%s\n' \
                    'linux-xanmod-x64v3:' \
                    '  Installed: (none)' \
                    '  Candidate: 7.1.11-xanmod1-0' \
                    '  Version table:' \
                    '     7.1.11-xanmod1-0 500' \
                    '        500 https://deb.xanmod.org trixie/main amd64 Packages' \
                    '        500 https://evil.example trixie/main amd64 Packages'
                ;;
        esac
    }
    version="$(kernel_package_candidate_version linux-xanmod-x64v3)"
    test_assert_equal '7.1.11-xanmod1-0' "$version" 'official candidate acceptance'
    policy_case=foreign
    status=0
    kernel_package_candidate_version linux-xanmod-x64v3 >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'higher-priority foreign candidate rejection'
    policy_case=ambiguous
    status=0
    kernel_package_candidate_version linux-xanmod-x64v3 >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'same-priority ambiguous candidate rejection'
)

test_dry_run_install() (
    local output
    KERNEL_EFFECTIVE_LEVEL=3
    KERNEL_OS_CODENAME=bookworm
    KERNEL_TRACK=auto
    VPSCTL_DRY_RUN=1
    kernel_require_install_platform() { return 0; }
    kernel_resolve_cpu_level() { KERNEL_EFFECTIVE_LEVEL=3; }
    kernel_ensure_install_dependencies() { return 0; }
    vps_cmd_require_root() { return 0; }
    kernel_take_lock() { return 0; }
    kernel_confirm_install_action() { return 0; }
    output="$(kernel_install 2>&1)"
    test_assert_contains "$output" 'linux-xanmod-x64v3' 'dry-run preferred package'
    test_assert_contains "$output" 'apt-get update' 'dry-run apt refresh'
    test_assert_contains "$output" "$KERNEL_XANMOD_KEY_FINGERPRINT" 'dry-run fingerprint'
    [[ ! -e "$KERNEL_REPO_FILE" ]] || test_fail 'dry-run wrote repository file'
    [[ ! -e "$KERNEL_KEY_FILE" ]] || test_fail 'dry-run wrote key file'
)

test_install_orchestration() (
    local output log="$TEST_TEMP/install.log"
    : >"$log"
    VPSCTL_DRY_RUN=0
    KERNEL_OS_CODENAME=bookworm
    kernel_require_install_platform() { return 0; }
    kernel_resolve_cpu_level() { KERNEL_EFFECTIVE_LEVEL=3; }
    kernel_ensure_install_dependencies() { return 0; }
    vps_cmd_require_root() { return 0; }
    kernel_take_lock() { return 0; }
    kernel_confirm_install_action() { return 0; }
    kernel_prepare_repository() { printf 'repo\n' >>"$log"; }
    kernel_select_package() {
        KERNEL_SELECTED_PACKAGE=linux-xanmod-x64v3
        KERNEL_SELECTED_VERSION=7.1.2-xanmod1
    }
    vps_cmd_run() {
        local joined
        printf -v joined '%q ' "$@"
        printf 'run:%s\n' "$joined" >>"$log"
    }
    kernel_package_is_installed() { [[ "$1" == linux-xanmod-x64v3 ]]; }
    kernel_write_state() { printf 'state:%s:%s\n' "$1" "$2" >>"$log"; }
    kernel_refresh_bootloader() { printf 'bootloader\n' >>"$log"; }
    output="$(kernel_install 2>&1)"
    test_assert_contains "$(<"$log")" 'apt-get install -y --no-install-recommends linux-xanmod-x64v3' 'selected package install command'
    test_assert_contains "$(<"$log")" 'state:linux-xanmod-x64v3:7.1.2-xanmod1' 'installed state record'
    test_assert_contains "$output" '7.1.2-xanmod1' 'install success version'
)

test_uninstall_safety_and_exact_packages() (
    local status=0 output purge_flag="$TEST_TEMP/purged" log="$TEST_TEMP/uninstall.log"
    : >"$log"
    rm -f -- "$purge_flag"
    VPSCTL_DRY_RUN=0
    kernel_require_uninstall_platform() { return 0; }
    kernel_ensure_uninstall_dependencies() { return 0; }
    vps_cmd_require_root() { return 0; }
    kernel_take_lock() { return 0; }
    kernel_confirm_uninstall_action() { return 0; }
    kernel_query_xanmod_packages() {
        if [[ -e "$purge_flag" ]]; then
            KERNEL_XANMOD_PACKAGES=()
        else
            KERNEL_XANMOD_PACKAGES=(linux-xanmod-x64v3 linux-image-7.1.0-x64v3-xanmod1)
        fi
    }
    kernel_fallback_releases() { return 0; }
    status=0
    kernel_uninstall >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" 'uninstall without fallback rejection'
    [[ ! -e "$purge_flag" ]] || test_fail 'uninstall without fallback ran purge'

    kernel_fallback_releases() { printf '6.1.0-amd64\n'; }
    vps_cmd_run() {
        local joined
        printf -v joined '%q ' "$@"
        printf 'run:%s\n' "$joined" >>"$log"
        [[ "$joined" != *'apt-get purge'* ]] || : >"$purge_flag"
    }
    kernel_refresh_bootloader() { printf 'bootloader\n' >>"$log"; }
    kernel_cleanup_owned_files() { printf 'cleanup\n' >>"$log"; }
    output="$(kernel_uninstall 2>&1)"
    test_assert_contains "$(<"$log")" 'apt-get purge -y linux-xanmod-x64v3 linux-image-7.1.0-x64v3-xanmod1' 'exact XanMod purge list'
    test_assert_not_contains "$(<"$log")" 'autoremove' 'autoremove exclusion'
    test_assert_contains "$output" '全部卸载' 'uninstall success output'
)

test_owned_cleanup_and_drift() (
    local status=0
    printf '%s\nTypes: deb\n' "$KERNEL_MANAGED_MARKER" >"$KERNEL_REPO_FILE"
    printf 'key\n' >"$KERNEL_KEY_FILE"
    printf '%s\nschema=1\n' "$KERNEL_MANAGED_MARKER" >"$KERNEL_STATE_FILE"
    vps_cmd_run() { "$@"; }
    kernel_cleanup_owned_files
    [[ ! -e "$KERNEL_REPO_FILE" && ! -e "$KERNEL_KEY_FILE" && ! -e "$KERNEL_STATE_FILE" ]] || test_fail 'owned files were not removed'

    printf 'Types: deb\n' >"$KERNEL_REPO_FILE"
    status=0
    kernel_cleanup_owned_files >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'unmanaged repository cleanup refusal'
    [[ -e "$KERNEL_REPO_FILE" ]] || test_fail 'unmanaged repository was removed'
    rm -f -- "$KERNEL_REPO_FILE"
)

test_noninteractive_confirmation() (
    local status=0
    VPSCTL_DRY_RUN=0
    KERNEL_CONFIRM_INSTALL=''
    KERNEL_CONFIRM_UNINSTALL=''
    status=0
    kernel_confirm_install_action >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" 'non-interactive install confirmation gate'
    status=0
    kernel_confirm_uninstall_action >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" 'non-interactive uninstall confirmation gate'
)

test_init
test_arguments
test_psabi_and_candidates
test_fallback_detection
test_secure_boot_detection
test_status_output
test_dpkg_state_parsing
test_candidate_origin_validation
test_dry_run_install
test_install_orchestration
test_uninstall_safety_and_exact_packages
test_owned_cleanup_and_drift
test_noninteractive_confirmation
printf 'PASS: system kernel tests\n'
