#!/usr/bin/env bash
# Function overrides below are deliberately invoked through sourced production code.
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
    "$TEST_SYSTEM_ROOT/etc/apt/sources.list.d" \
    "$TEST_SYSTEM_ROOT/etc/apt/keyrings" \
    "$TEST_SYSTEM_ROOT/etc/default/grub.d" \
    "$TEST_SYSTEM_ROOT/var/lib/vpsctl/system/kernel-bbrv3" \
    "$TEST_SYSTEM_ROOT/var/lib/vpsctl/system/kernel/backups" \
    "$TEST_SYSTEM_ROOT/proc/sys/net/ipv4" \
    "$TEST_SYSTEM_ROOT/proc/sys/net/core" \
    "$TEST_SYSTEM_ROOT/sys/firmware/efi/efivars" \
    "$TEST_SYSTEM_ROOT/boot/grub" \
    "$TEST_SYSTEM_ROOT/lib/modules" \
    "$TEST_SYSTEM_ROOT/run/vpsctl"

printf 'ID=debian\nVERSION_ID=12\nVERSION="12 (bookworm)"\nVERSION_CODENAME=bookworm\n' >"$TEST_SYSTEM_ROOT/etc/os-release"
printf 'bbr\n' >"$TEST_SYSTEM_ROOT/proc/sys/net/ipv4/tcp_congestion_control"
printf 'fq\n' >"$TEST_SYSTEM_ROOT/proc/sys/net/core/default_qdisc"

export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_ENV_KERNEL_NAME=Linux
export VPSCTL_ENV_OS_ID=debian
export VPSCTL_ENV_OS_VERSION_ID=12
export VPSCTL_ENV_OS_VERSION='12 (bookworm)'
export VPSCTL_ENV_OS_CODENAME=bookworm
export VPSCTL_ENV_ARCH=x86_64
export VPSCTL_ENV_PACKAGE_MANAGER=apt-get
export VPSCTL_ENV_VIRTUALIZATION=kvm
export VPSCTL_NON_INTERACTIVE=1
export VPSCTL_NO_COLOR=1

# shellcheck source=../../commands/system/kernel.sh
# shellcheck disable=SC1091
source "$TEST_ROOT/commands/system/kernel.sh"

# The entry point loads these declarations through private modules at runtime.
# Repeat their types here so ShellCheck also treats fixture keys as strings.
declare -Ag \
    KERNEL_GRUB_ENTRY \
    KERNEL_INSTALL_EXPECTED_VERSIONS \
    KERNEL_PKG_DEPENDS \
    KERNEL_PKG_IS_META \
    KERNEL_PKG_RELEASE \
    KERNEL_PKG_SERIES \
    KERNEL_PKG_STATUS \
    KERNEL_PKG_VERSION \
    KERNEL_RELEASE_COMPLETE \
    KERNEL_RELEASE_MANAGED \
    KERNEL_RELEASE_PACKAGES \
    KERNEL_RELEASE_REASON \
    KERNEL_RELEASE_SERIES \
    KERNEL_RELEASE_SOURCE

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

test_assert_file_absent() {
    [[ ! -e "$1" ]] || test_fail "$2: unexpected path $1"
}

test_init() {
    vps_cmd_init system-kernel "$TEST_ROOT"
    kernel_init_paths
    kernel_load_platform
}

reset_inventory_fixture() {
    KERNEL_RELEASES=()
    KERNEL_PURGE_PACKAGES=()
    KERNEL_PURGE_METAPACKAGES=()
    KERNEL_META_RELEASES=()
    KERNEL_INSTALL_EXPECTED_VERSIONS=()
    KERNEL_RELEASE_PACKAGES=()
    KERNEL_RELEASE_SOURCE=()
    KERNEL_RELEASE_SERIES=()
    KERNEL_RELEASE_COMPLETE=()
    KERNEL_RELEASE_MANAGED=()
    KERNEL_RELEASE_REASON=()
    KERNEL_PKG_STATUS=()
    KERNEL_PKG_VERSION=()
    KERNEL_PKG_DEPENDS=()
    KERNEL_PKG_RELEASE=()
    KERNEL_PKG_SERIES=()
    KERNEL_PKG_IS_META=()
    KERNEL_GRUB_ENTRY=()
    KERNEL_GRUB_SUPPORTED=0
    KERNEL_GRUB_REASON='未检测'
    KERNEL_GRUB_DEFAULT_RELEASE=''
    KERNEL_GRUB_NEXT_RELEASE=''
    KERNEL_GRUB_DEFAULT_ID=''
    KERNEL_GRUB_NEXT_ID=''
    KERNEL_GRUB_DEFAULT_SELECTOR=''
    KERNEL_GRUB_NEXT_SELECTOR=''
}

write_cpu_flags() {
    printf 'processor : 0\nflags : %s\n' "$1" >"$TEST_SYSTEM_ROOT/proc/cpuinfo"
}

parse_and_validate() {
    kernel_parse_args "$@" || return $?
    kernel_validate_action_options
}

test_arguments_and_compatibility() {
    local status=0

    parse_and_validate install --type official --confirm-install INSTALL-KERNEL
    test_assert_equal install "$KERNEL_ACTION" 'official install action'
    test_assert_equal official "$KERNEL_TYPE" 'official install type'

    parse_and_validate install --track lts --cpu-level v2 --confirm-install INSTALL-XANMOD-BBRV3
    test_assert_equal xanmod "$KERNEL_TYPE" 'omitted type keeps XanMod default'
    test_assert_equal lts "$KERNEL_TRACK" 'XanMod track option'
    test_assert_equal v2 "$KERNEL_CPU_LEVEL" 'XanMod CPU option'

    status=0
    parse_and_validate install --type official --track lts >/dev/null 2>&1 || status=$?
    test_assert_equal 2 "$status" 'official rejects XanMod track'

    status=0
    parse_and_validate install --type cloud --cpu-level v2 >/dev/null 2>&1 || status=$?
    test_assert_equal 2 "$status" 'cloud rejects XanMod CPU level'

    status=0
    parse_and_validate install --type official --confirm-install INSTALL-XANMOD-BBRV3 >/dev/null 2>&1 || status=$?
    test_assert_equal 2 "$status" 'legacy install token is XanMod-only'

    status=0
    parse_and_validate uninstall >/dev/null 2>&1 || status=$?
    test_assert_equal 2 "$status" 'non-interactive uninstall requires release'

    status=0
    parse_and_validate switch >/dev/null 2>&1 || status=$?
    test_assert_equal 2 "$status" 'non-interactive switch requires release'

    status=0
    parse_and_validate uninstall --release 6.1.0-amd64 --confirm-uninstall REMOVE-XANMOD-BBRV3 >/dev/null 2>&1 || status=$?
    test_assert_equal 2 "$status" 'legacy uninstall token rejected'

    status=0
    parse_and_validate uninstall --release '../6.1.0-amd64' --confirm-uninstall REMOVE-KERNEL >/dev/null 2>&1 || status=$?
    test_assert_equal 2 "$status" 'release path rejected'

    parse_and_validate switch --release 6.8.0-1-amd64 --confirm-switch SWITCH-KERNEL
    test_assert_equal '6.8.0-1-amd64' "$KERNEL_RELEASE" 'complete release accepted'
}

test_provider_candidates_and_cpu() {
    local output
    write_cpu_flags 'lm cmov cx8 fpu fxsr mmx syscall sse2'
    test_assert_equal 1 "$(kernel_detect_psabi_level)" 'x86-64-v1 detection'

    write_cpu_flags 'lm cmov cx8 fpu fxsr mmx syscall sse2 cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3'
    test_assert_equal 2 "$(kernel_detect_psabi_level)" 'x86-64-v2 detection'

    write_cpu_flags 'lm cmov cx8 fpu fxsr mmx syscall sse2 cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave'
    test_assert_equal 3 "$(kernel_detect_psabi_level)" 'x86-64-v3 detection'

    KERNEL_OS_ID=debian
    KERNEL_TYPE=official
    test_assert_equal linux-image-amd64 "$(kernel_candidate_packages)" 'Debian official meta'
    KERNEL_TYPE=cloud
    test_assert_equal linux-image-cloud-amd64 "$(kernel_candidate_packages)" 'Debian cloud meta'
    KERNEL_OS_ID=ubuntu
    KERNEL_OS_VERSION='24.04.3 LTS (Noble Numbat)'
    KERNEL_OS_VERSION_ID=24.04
    KERNEL_TYPE=official
    test_assert_equal linux-generic "$(kernel_candidate_packages)" 'Ubuntu official meta'
    KERNEL_TYPE=hwe
    test_assert_equal linux-generic-hwe-24.04 "$(kernel_candidate_packages)" 'Ubuntu HWE meta'

    KERNEL_TYPE=xanmod
    KERNEL_EFFECTIVE_LEVEL=3
    KERNEL_TRACK=auto
    output="$(kernel_candidate_packages)"
    test_assert_equal $'linux-xanmod-x64v3\nlinux-xanmod-x64v2\nlinux-xanmod-lts-x64v3\nlinux-xanmod-lts-x64v2\nlinux-xanmod-lts-x64v1' "$output" 'XanMod auto candidate order'
    KERNEL_TRACK=main
    KERNEL_EFFECTIVE_LEVEL=1
    test_assert_equal '' "$(kernel_candidate_packages)" 'XanMod main has no v1 package'

    KERNEL_OS_ID=debian
    KERNEL_OS_VERSION='12 (bookworm)'
    KERNEL_OS_VERSION_ID=12
    KERNEL_TYPE=xanmod
    KERNEL_TRACK=auto
}

test_menu_install_availability_and_xanmod_inputs() (
    local status=0 log="$TEST_TEMP/kernel-menu.log" selected_type=official
    : >"$log"
    KERNEL_OS_ID=ubuntu
    KERNEL_OS_VERSION='24.04.3 LTS (Noble Numbat)'
    KERNEL_OS_VERSION_ID=24.04
    KERNEL_TYPE=official

    kernel_package_candidate_version() {
        test_assert_equal linux-generic-hwe-24.04 "$1" 'HWE menu probes exact release meta'
        printf '6.8.0.85.87~22.04.1\n'
    }
    kernel_menu_hwe_available || test_fail 'trusted Ubuntu LTS HWE candidate should be available'
    test_assert_equal official "$KERNEL_TYPE" 'HWE availability probe does not change selected type'

    KERNEL_OS_VERSION='24.10 (Oracular Oriole)'
    status=0
    kernel_menu_hwe_available >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'non-LTS Ubuntu hides HWE'

    KERNEL_OS_VERSION='24.04.3 LTS (Noble Numbat)'
    kernel_package_candidate_version() { return 1; }
    status=0
    kernel_menu_hwe_available >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'missing or untrusted HWE candidate hidden'

    kernel_package_candidate_version() { printf '6.8.0.85.87~22.04.1\n'; }
    vps_cmd_prompt_select() {
        local prompt="$1"
        shift
        printf 'prompt:%s|%s\n' "$prompt" "$(kernel_join_values "$@")" >>"$log"
        case "$prompt" in
            '请选择内核类型') printf '%s\n' "$selected_type" ;;
            '请选择 XanMod 分支') printf 'main\n' ;;
            '请选择 XanMod CPU 等级') printf 'v2\n' ;;
            *) return 2 ;;
        esac
    }
    kernel_install() {
        printf 'install:%s:%s:%s\n' "$KERNEL_TYPE" "$KERNEL_TRACK" "$KERNEL_CPU_LEVEL" >>"$log"
    }

    selected_type=official
    kernel_menu_install
    test_assert_contains "$(<"$log")" 'hwe, Ubuntu HWE 内核' 'trusted HWE candidate shown in Ubuntu menu'
    test_assert_not_contains "$(<"$log")" '请选择 XanMod 分支' 'official menu does not ask XanMod track'
    test_assert_not_contains "$(<"$log")" '请选择 XanMod CPU 等级' 'official menu does not ask XanMod CPU level'
    test_assert_contains "$(<"$log")" 'install:official:auto:auto' 'official menu keeps XanMod inputs untouched'

    : >"$log"
    selected_type=xanmod
    kernel_menu_install
    test_assert_contains "$(<"$log")" '请选择 XanMod 分支' 'XanMod menu asks track'
    test_assert_contains "$(<"$log")" '请选择 XanMod CPU 等级' 'XanMod menu asks CPU level'
    test_assert_contains "$(<"$log")" 'auto, 自动检测（推荐）, v1, x86-64-v1, v2, x86-64-v2, v3, x86-64-v3' 'XanMod CPU choices and auto default'
    test_assert_contains "$(<"$log")" 'install:xanmod:main:v2' 'XanMod menu forwards selected track and CPU level'

    : >"$log"
    kernel_package_candidate_version() { return 1; }
    selected_type=official
    kernel_menu_install
    test_assert_not_contains "$(<"$log")" 'hwe, Ubuntu HWE 内核' 'untrusted HWE candidate omitted from Ubuntu menu'

    : >"$log"
    KERNEL_OS_VERSION='24.10 (Oracular Oriole)'
    kernel_package_candidate_version() { printf '6.11.0.9.9\n'; }
    kernel_menu_install
    test_assert_not_contains "$(<"$log")" 'hwe, Ubuntu HWE 内核' 'non-LTS Ubuntu menu omits HWE'
)

test_secure_boot_is_provider_specific() (
    local status=0
    _kernel_require_common_platform() { return 0; }
    _kernel_require_provider_platform() { return 0; }
    kernel_secure_boot_enabled() { return 0; }

    KERNEL_TYPE=official
    kernel_require_install_platform || test_fail 'official kernel was incorrectly blocked by Secure Boot gate'

    KERNEL_TYPE=xanmod
    status=0
    kernel_require_install_platform >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" 'XanMod Secure Boot rejection'
)

test_key_fingerprint_and_xanmod_origin() (
    local fingerprint status=0 policy_case=official
    gpg() {
        printf '%s\n' \
            'pub:-:4096:1:86F7D09EE734E623:0:0:::::::' \
            "fpr:::::::::${KERNEL_XANMOD_KEY_FINGERPRINT}:"
    }
    fingerprint="$(kernel_primary_key_fingerprint unused)"
    test_assert_equal "$KERNEL_XANMOD_KEY_FINGERPRINT" "$fingerprint" 'full XanMod key fingerprint'

    gpg() {
        printf '%s\n' \
            'pub:-:4096:1:86F7D09EE734E623:0:0:::::::' \
            "fpr:::::::::${KERNEL_XANMOD_KEY_FINGERPRINT}:" \
            'pub:-:4096:1:1111111111111111:0:0:::::::'
    }
    status=0
    kernel_primary_key_fingerprint unused >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'multiple primary keys rejected'

    apt-cache() {
        case "$policy_case" in
            official)
                printf '%s\n' \
                    'linux-xanmod-x64v3:' \
                    '  Installed: (none)' \
                    '  Candidate: 7.1.11-xanmod1-0' \
                    '  Version table:' \
                    '     7.1.11-xanmod1-0 500' \
                    '        500 https://deb.xanmod.org bookworm/main amd64 Packages'
                ;;
            foreign)
                printf '%s\n' \
                    'linux-xanmod-x64v3:' \
                    '  Installed: (none)' \
                    '  Candidate: 9.9.9-evil' \
                    '  Version table:' \
                    '     9.9.9-evil 1001' \
                    '       1001 https://evil.example bookworm/main amd64 Packages' \
                    '        500 https://deb.xanmod.org bookworm/main amd64 Packages'
                ;;
            ambiguous)
                printf '%s\n' \
                    'linux-xanmod-x64v3:' \
                    '  Installed: (none)' \
                    '  Candidate: 7.1.11-xanmod1-0' \
                    '  Version table:' \
                    '     7.1.11-xanmod1-0 500' \
                    '        500 https://deb.xanmod.org bookworm/main amd64 Packages' \
                    '        500 https://evil.example bookworm/main amd64 Packages'
                ;;
        esac
    }
    KERNEL_TYPE=xanmod
    test_assert_equal '7.1.11-xanmod1-0' "$(kernel_package_candidate_version linux-xanmod-x64v3)" 'official XanMod candidate accepted'
    policy_case=foreign
    status=0
    kernel_package_candidate_version linux-xanmod-x64v3 >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'higher-priority foreign candidate rejected'
    policy_case=ambiguous
    status=0
    kernel_package_candidate_version linux-xanmod-x64v3 >/dev/null 2>&1 || status=$?
    test_assert_equal 1 "$status" 'same-priority mixed candidate rejected'
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
    test_assert_equal 'linux-xanmod-x64v3, linux-image-7.1.0-x64v3-xanmod1' "$(kernel_join_values "${KERNEL_XANMOD_PACKAGES[@]}")" 'configured XanMod dpkg states'
    kernel_query_xanmod_packages purge
    test_assert_equal 'linux-xanmod-x64v3, linux-image-7.1.0-x64v3-xanmod1, linux-headers-7.0.0-x64v3-xanmod1' "$(kernel_join_values "${KERNEL_XANMOD_PACKAGES[@]}")" 'purgeable XanMod dpkg states'

    dpkg-query() { printf '%s\n' $'iF \tlinux-xanmod-x64v3'; }
    status=0
    kernel_query_xanmod_packages installed >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'half-configured XanMod package rejected'
)

test_confirmations_and_root_gate() (
    local status=0 write_marker="$TEST_TEMP/root-gate-write"
    VPSCTL_DRY_RUN=0
    VPSCTL_ASSUME_YES=1
    KERNEL_TYPE=xanmod
    KERNEL_RELEASE=6.1.0-amd64
    KERNEL_CONFIRM_INSTALL=''
    KERNEL_CONFIRM_SWITCH=''
    KERNEL_CONFIRM_UNINSTALL=''

    status=0
    kernel_confirm_install_action >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" '--yes cannot bypass install confirmation'
    status=0
    kernel_confirm_action switch '' "$KERNEL_SWITCH_TOKEN" 'switch' >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" '--yes cannot bypass switch confirmation'
    status=0
    kernel_confirm_uninstall_action >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" '--yes cannot bypass uninstall confirmation'

    KERNEL_ACTION=install
    KERNEL_TYPE=official
    kernel_require_install_platform() { return 0; }
    kernel_ensure_install_dependencies() { return 0; }
    vps_cmd_require_root() { return 3; }
    kernel_take_lock() { : >"$write_marker"; }
    status=0
    kernel_install >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" 'install root gate status'
    test_assert_file_absent "$write_marker" 'root gate stopped before lock/write phase'
)

test_dry_run_zero_write() (
    local output write_marker="$TEST_TEMP/dry-run-write"
    rm -f -- "$KERNEL_REPO_FILE" "$KERNEL_KEY_FILE" "$KERNEL_STATE_FILE" "$KERNEL_OFFICIAL_STATE_FILE" "$write_marker"
    VPSCTL_DRY_RUN=1
    KERNEL_ACTION=install
    KERNEL_TYPE=xanmod
    KERNEL_TRACK=auto
    KERNEL_CPU_LEVEL=auto
    KERNEL_OS_ID=debian
    KERNEL_OS_CODENAME=bookworm
    kernel_require_install_platform() { return 0; }
    kernel_resolve_cpu_level() { KERNEL_EFFECTIVE_LEVEL=3; }
    kernel_ensure_install_dependencies() { return 0; }
    vps_cmd_require_root() { return 0; }
    kernel_take_lock() { return 0; }
    kernel_confirm_install_action() { return 0; }
    vps_cmd_run() { printf 'plan:%s\n' "$(kernel_join_values "$@")"; }
    kernel_prepare_repository() { : >"$write_marker"; }
    output="$(kernel_install 2>&1)"
    test_assert_contains "$output" 'linux-xanmod-x64v3' 'dry-run preferred XanMod package'
    test_assert_contains "$output" "$KERNEL_XANMOD_KEY_FINGERPRINT" 'dry-run full fingerprint'
    test_assert_contains "$output" 'apt-get, update' 'dry-run APT refresh plan'
    test_assert_file_absent "$write_marker" 'dry-run did not prepare repository'
    test_assert_file_absent "$KERNEL_REPO_FILE" 'dry-run repository zero-write'
    test_assert_file_absent "$KERNEL_KEY_FILE" 'dry-run key zero-write'
    test_assert_file_absent "$KERNEL_STATE_FILE" 'dry-run XanMod state zero-write'
    test_assert_file_absent "$KERNEL_OFFICIAL_STATE_FILE" 'dry-run official state zero-write'
)

test_install_meta_release_verification() (
    local status=0 output log="$TEST_TEMP/install-main.log"
    : >"$log"
    reset_inventory_fixture
    VPSCTL_DRY_RUN=0
    KERNEL_ACTION=install
    KERNEL_TYPE=official
    KERNEL_OS_ID=debian
    KERNEL_CONFIRM_INSTALL=INSTALL-KERNEL
    kernel_require_install_platform() { return 0; }
    kernel_ensure_install_dependencies() { return 0; }
    vps_cmd_require_root() { return 0; }
    kernel_take_lock() { return 0; }
    kernel_confirm_install_action() { return 0; }
    kernel_select_package() {
        KERNEL_SELECTED_PACKAGE=linux-image-amd64
        KERNEL_SELECTED_VERSION=6.8.12-1
    }
    kernel_validate_install_plan() {
        test_assert_equal linux-image-amd64 "$1" 'preflight selected meta package'
        test_assert_equal 6.8.12-1 "$2" 'preflight selected meta version'
        KERNEL_INSTALL_EXPECTED_VERSIONS=()
        KERNEL_INSTALL_EXPECTED_VERSIONS["linux-image-amd64"]=6.8.12-1
        KERNEL_INSTALL_EXPECTED_VERSIONS["linux-image-6.8.12-amd64"]=6.8.12-1
        printf 'preflight:%s:%s\n' "$1" "$2" >>"$log"
    }
    vps_cmd_run() {
        printf 'run:%s\n' "$(kernel_join_values "$@")" >>"$log"
    }
    kernel_inventory_load() {
        KERNEL_PKG_STATUS["linux-image-amd64"]='ii '
        KERNEL_PKG_VERSION["linux-image-amd64"]=6.8.12-1
        KERNEL_PKG_STATUS["linux-image-6.8.12-amd64"]='ii '
        KERNEL_PKG_VERSION["linux-image-6.8.12-amd64"]=6.8.12-1
        KERNEL_RELEASES=(6.8.12-amd64)
        KERNEL_RELEASE_MANAGED["6.8.12-amd64"]=1
        KERNEL_RELEASE_COMPLETE["6.8.12-amd64"]=1
    }
    kernel_inventory_meta_releases() { KERNEL_META_RELEASES=(6.8.12-amd64); }
    kernel_refresh_bootloader() { printf 'bootloader\n' >>"$log"; }
    kernel_grub_load() {
        KERNEL_GRUB_SUPPORTED=1
        KERNEL_GRUB_DEFAULT_RELEASE=6.1.0-amd64
        KERNEL_GRUB_ENTRY["6.8.12-amd64"]=gnulinux-6.8.12-amd64-advanced-root
    }
    kernel_write_state() { printf 'state:%s:%s\n' "$1" "$2" >>"$log"; }

    output="$(kernel_install 2>&1)"
    test_assert_contains "$(<"$log")" $'preflight:linux-image-amd64:6.8.12-1\nrun:env, DEBIAN_FRONTEND=noninteractive, apt-get' 'preflight runs before actual install'
    test_assert_contains "$(<"$log")" 'linux-image-amd64=6.8.12-1' 'install pins selected meta candidate'
    test_assert_contains "$(<"$log")" 'state:linux-image-amd64:6.8.12-1' 'state written after release verification'
    test_assert_contains "$output" '默认启动' 'install reports actual default release'

    : >"$log"
    kernel_validate_install_plan() {
        printf 'preflight-rejected\n' >>"$log"
        return 30
    }
    status=0
    kernel_install >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'install preflight rejection propagated'
    test_assert_contains "$(<"$log")" 'preflight-rejected' 'preflight rejection reached'
    test_assert_not_contains "$(<"$log")" 'install, -y' 'preflight rejection stopped actual install'

    : >"$log"
    kernel_validate_install_plan() {
        KERNEL_INSTALL_EXPECTED_VERSIONS=()
        KERNEL_INSTALL_EXPECTED_VERSIONS["linux-image-amd64"]=6.8.12-1
        KERNEL_INSTALL_EXPECTED_VERSIONS["linux-image-6.8.12-amd64"]=6.8.12-1
    }
    kernel_inventory_load() {
        KERNEL_PKG_STATUS["linux-image-amd64"]='ii '
        KERNEL_PKG_VERSION["linux-image-amd64"]=6.8.12-1
        KERNEL_PKG_STATUS["linux-image-6.8.12-amd64"]='ii '
        KERNEL_PKG_VERSION["linux-image-6.8.12-amd64"]=6.8.11-1
        KERNEL_RELEASES=(6.8.12-amd64)
        KERNEL_RELEASE_MANAGED["6.8.12-amd64"]=1
        KERNEL_RELEASE_COMPLETE["6.8.12-amd64"]=1
    }
    status=0
    kernel_install >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'installed dependency version mismatch rejected'
    test_assert_not_contains "$(<"$log")" 'state:' 'version mismatch does not write state'

    : >"$log"
    kernel_inventory_load() {
        KERNEL_PKG_STATUS["linux-image-amd64"]='ii '
        KERNEL_PKG_VERSION["linux-image-amd64"]=6.8.12-1
        KERNEL_PKG_STATUS["linux-image-6.8.12-amd64"]='ii '
        KERNEL_PKG_VERSION["linux-image-6.8.12-amd64"]=6.8.12-1
        KERNEL_RELEASES=(6.8.12-amd64)
        KERNEL_RELEASE_MANAGED["6.8.12-amd64"]=1
        KERNEL_RELEASE_COMPLETE["6.8.12-amd64"]=0
    }
    status=0
    kernel_install >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'incomplete concrete release rejects successful meta install'
    test_assert_not_contains "$(<"$log")" 'state:' 'incomplete release does not write state'
)

test_switch_signature_gate() (
    local release=6.8.12-amd64 status=0
    reset_inventory_fixture
    KERNEL_RELEASE_SOURCE[$release]='Debian 官方'
    KERNEL_RELEASE_PACKAGES[$release]='linux-image-6.8.12-amd64'
    kernel_secure_boot_enabled() { return 0; }
    kernel_switch_signature_gate "$release" || test_fail 'signed official kernel should pass with Secure Boot enabled'

    KERNEL_RELEASE_SOURCE[$release]=XanMod
    status=0
    kernel_switch_signature_gate "$release" >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" 'Secure Boot enabled blocks XanMod switch'

    kernel_secure_boot_enabled() { return 2; }
    status=0
    kernel_switch_signature_gate "$release" >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" 'unknown Secure Boot state blocks XanMod switch'

    KERNEL_RELEASE_SOURCE[$release]=Ubuntu
    KERNEL_RELEASE_PACKAGES[$release]='linux-image-unsigned-6.8.12-generic'
    status=0
    kernel_switch_signature_gate "$release" >/dev/null 2>&1 || status=$?
    test_assert_equal 3 "$status" 'unknown Secure Boot state blocks unsigned switch'

    kernel_secure_boot_enabled() { return 1; }
    kernel_switch_signature_gate "$release" || test_fail 'disabled Secure Boot should allow unsigned kernel switch'
)

test_status_version_rows() (
    local output
    reset_inventory_fixture
    KERNEL_ACTION=status
    KERNEL_OS_ID=debian
    KERNEL_RUNNING_RELEASE=6.8.12-amd64
    kernel_refresh_inventory() {
        KERNEL_RELEASES=(6.8.12-amd64 6.1.0-amd64)
        KERNEL_RELEASE_SOURCE["6.8.12-amd64"]='Debian 官方'
        KERNEL_RELEASE_SOURCE["6.1.0-amd64"]='Debian 官方'
        KERNEL_RELEASE_PACKAGES["6.8.12-amd64"]=$'linux-image-6.8.12-amd64\nlinux-modules-6.8.12-amd64'
        KERNEL_RELEASE_PACKAGES["6.1.0-amd64"]='linux-image-6.1.0-amd64'
        KERNEL_RELEASE_COMPLETE["6.8.12-amd64"]=1
        KERNEL_RELEASE_COMPLETE["6.1.0-amd64"]=1
        KERNEL_RELEASE_MANAGED["6.8.12-amd64"]=1
        KERNEL_RELEASE_MANAGED["6.1.0-amd64"]=1
        KERNEL_GRUB_SUPPORTED=1
        KERNEL_GRUB_DEFAULT_RELEASE=6.1.0-amd64
        KERNEL_GRUB_ENTRY["6.8.12-amd64"]=entry-new
        KERNEL_GRUB_ENTRY["6.1.0-amd64"]=entry-old
    }
    output="$(kernel_status)"
    test_assert_contains "$output" '6.8.12-amd64' 'status release row'
    test_assert_contains "$output" 'Debian 官方' 'status source'
    test_assert_contains "$output" '当前运行' 'status current flag'
    test_assert_contains "$output" '默认启动' 'status default flag'
    test_assert_contains "$output" 'linux-modules-6.8.12-amd64' 'status associated packages'
    test_assert_contains "$output" '可卸载' 'status actionable old release'
)

test_release_selection_protection() (
    local status=0 reason target=6.5.0-amd64
    reset_inventory_fixture
    KERNEL_RELEASES=(6.8.0-amd64 6.5.0-amd64 6.1.0-amd64)
    for target in "${KERNEL_RELEASES[@]}"; do
        KERNEL_RELEASE_MANAGED[$target]=1
        KERNEL_RELEASE_COMPLETE[$target]=1
        KERNEL_GRUB_ENTRY[$target]="entry-$target"
    done
    KERNEL_GRUB_SUPPORTED=1
    KERNEL_GRUB_DEFAULT_RELEASE=6.8.0-amd64
    KERNEL_GRUB_DEFAULT_SELECTOR=entry-6.8.0-amd64
    KERNEL_RUNNING_RELEASE=6.1.0-amd64
    target=6.5.0-amd64
    kernel_release_actionable uninstall "$target" || test_fail 'unprotected old release should be selectable'
    kernel_release_actionable switch "$target" || test_fail 'complete GRUB release should be switchable'

    status=0
    kernel_release_actionable uninstall "$KERNEL_RUNNING_RELEASE" || status=$?
    test_assert_equal 1 "$status" 'current release protected'
    test_assert_contains "$KERNEL_ACTION_REASON" '当前运行' 'current release reason'

    status=0
    kernel_release_actionable uninstall "$KERNEL_GRUB_DEFAULT_RELEASE" || status=$?
    test_assert_equal 1 "$status" 'default release protected'
    test_assert_contains "$KERNEL_ACTION_REASON" '默认启动' 'default release reason'

    KERNEL_GRUB_NEXT_ID=entry-6.5.0-amd64
    KERNEL_GRUB_NEXT_RELEASE=$target
    status=0
    kernel_release_actionable uninstall "$target" || status=$?
    test_assert_equal 1 "$status" 'next release protected'
    test_assert_contains "$KERNEL_ACTION_REASON" '下一次启动' 'next release reason'

    KERNEL_GRUB_NEXT_ID=unknown-entry
    KERNEL_GRUB_NEXT_RELEASE=''
    status=0
    kernel_release_actionable uninstall "$target" || status=$?
    test_assert_equal 1 "$status" 'unknown next target blocks uninstall'
    test_assert_contains "$KERNEL_ACTION_REASON" '下一次启动目标无法解析' 'unknown next reason'

    KERNEL_GRUB_NEXT_ID=''
    KERNEL_GRUB_DEFAULT_RELEASE=''
    status=0
    kernel_release_actionable uninstall "$target" || status=$?
    test_assert_equal 1 "$status" 'unknown default blocks uninstall'
    test_assert_contains "$KERNEL_ACTION_REASON" '默认启动内核无法解析' 'unknown default reason'

    KERNEL_GRUB_DEFAULT_RELEASE=6.8.0-amd64
    KERNEL_GRUB_DEFAULT_SELECTOR='1>2'
    status=0
    kernel_release_actionable uninstall "$target" || status=$?
    test_assert_equal 1 "$status" 'numeric default path drift blocks uninstall'
    test_assert_contains "$KERNEL_ACTION_REASON" '编号' 'numeric selector drift reason'

    KERNEL_GRUB_DEFAULT_SELECTOR=entry-6.8.0-amd64
    KERNEL_RELEASE_MANAGED[$target]=0
    KERNEL_RELEASE_REASON[$target]='手工内核归属未知'
    status=0
    kernel_release_actionable uninstall "$target" || status=$?
    test_assert_equal 1 "$status" 'unmanaged release blocked'
    reason="$KERNEL_ACTION_REASON"
    test_assert_contains "$reason" '手工内核归属未知' 'unmanaged release reason'
)

test_purge_simulation_guards() (
    local status=0
    KERNEL_PURGE_PACKAGES=(linux-image-6.5.0-amd64 linux-modules-6.5.0-amd64)
    kernel_validate_purge_simulation $'Purg linux-image-6.5.0-amd64 [6.5]\nPurg linux-modules-6.5.0-amd64 [6.5]' 0 || test_fail 'exact purge simulation should pass'

    status=0
    kernel_validate_purge_simulation $'Purg linux-image-6.5.0-amd64 [6.5]\nInst linux-image-6.9.0-amd64 (6.9 Debian:stable)' 0 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'APT Inst operation rejected'

    status=0
    kernel_validate_purge_simulation $'Purg linux-image-6.5.0-amd64 [6.5]\nPurg libc6 [2.36]' 0 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'out-of-scope purge rejected'
)

test_uninstall_target_change_guard() (
    local status=0 output build_count=0 run_log="$TEST_TEMP/target-change-runs"
    : >"$run_log"
    reset_inventory_fixture
    VPSCTL_DRY_RUN=0
    KERNEL_ACTION=uninstall
    KERNEL_RELEASE=6.5.0-amd64
    KERNEL_RUNNING_RELEASE=6.1.0-amd64
    KERNEL_CONFIRM_UNINSTALL=REMOVE-KERNEL
    kernel_require_uninstall_platform() { return 0; }
    kernel_ensure_uninstall_dependencies() { return 0; }
    vps_cmd_require_root() { return 0; }
    kernel_take_lock() { return 0; }
    kernel_refresh_inventory() {
        KERNEL_GRUB_SUPPORTED=1
        KERNEL_GRUB_DEFAULT_RELEASE=6.8.0-amd64
        KERNEL_GRUB_NEXT_RELEASE=''
    }
    kernel_grub_require() { return 0; }
    kernel_select_release() { return 0; }
    kernel_release_actionable() { return 0; }
    kernel_build_purge_packages() {
        build_count=$((build_count + 1))
        KERNEL_PURGE_PACKAGES=(linux-image-6.5.0-amd64 linux-modules-6.5.0-amd64)
        ((build_count == 1)) || KERNEL_PURGE_PACKAGES+=(linux-headers-6.5.0-amd64)
        KERNEL_PURGE_METAPACKAGES=()
    }
    kernel_purge_simulate() { return 0; }
    kernel_confirm_uninstall_action() { return 0; }
    vps_cmd_run() { printf '%s\n' "$(kernel_join_values "$@")" >>"$run_log"; }

    output="$(kernel_uninstall 2>&1)" || status=$?
    test_assert_equal 3 "$status" 'changed purge set rejected after confirmation'
    test_assert_contains "$output" '目标包在确认期间发生变化' 'changed purge set message'
    test_assert_equal '' "$(<"$run_log")" 'changed purge set never executed apt purge'
)

test_dry_run_exact_package_array() (
    local output run_log="$TEST_TEMP/dry-uninstall-runs"
    : >"$run_log"
    reset_inventory_fixture
    VPSCTL_DRY_RUN=1
    KERNEL_ACTION=uninstall
    KERNEL_RELEASE=6.5.0-amd64
    KERNEL_RUNNING_RELEASE=6.1.0-amd64
    kernel_require_uninstall_platform() { return 0; }
    kernel_ensure_uninstall_dependencies() { return 0; }
    vps_cmd_require_root() { return 0; }
    kernel_take_lock() { return 0; }
    kernel_refresh_inventory() {
        KERNEL_GRUB_SUPPORTED=1
        KERNEL_GRUB_DEFAULT_RELEASE=6.8.0-amd64
    }
    kernel_grub_require() { return 0; }
    kernel_select_release() { return 0; }
    kernel_build_purge_packages() {
        KERNEL_PURGE_PACKAGES=(linux-image-6.5.0-amd64 linux-modules-6.5.0-amd64 linux-image-amd64)
        KERNEL_PURGE_METAPACKAGES=(linux-image-amd64)
    }
    kernel_purge_simulate() { return 0; }
    kernel_confirm_uninstall_action() { return 0; }
    vps_cmd_run() { printf '%s\n' "$(kernel_join_values "$@")" >>"$run_log"; }

    output="$(kernel_uninstall 2>&1)"
    test_assert_contains "$(<"$run_log")" 'APT::Get::AutomaticRemove=false, purge, -y, --, linux-image-6.5.0-amd64, linux-modules-6.5.0-amd64, linux-image-amd64' 'exact purge package array'
    test_assert_not_contains "$(<"$run_log")" 'autoremove' 'autoremove excluded'
    test_assert_contains "$output" '停止自动跟随更新' 'meta removal warning'
    test_assert_contains "$output" '演练不会卸载软件包' 'dry-run zero-write message'
)

test_purge_failure_preserves_xanmod_source() (
    local status=0 cleanup_marker="$TEST_TEMP/cleanup-called"
    reset_inventory_fixture
    printf '%s\nTypes: deb\n' "$KERNEL_MANAGED_MARKER" >"$KERNEL_REPO_FILE"
    printf 'key\n' >"$KERNEL_KEY_FILE"
    printf '%s\nschema=1\n' "$KERNEL_MANAGED_MARKER" >"$KERNEL_STATE_FILE"
    rm -f -- "$cleanup_marker"
    VPSCTL_DRY_RUN=0
    KERNEL_ACTION=uninstall
    KERNEL_RELEASE=7.1.0-x64v3-xanmod1
    KERNEL_RUNNING_RELEASE=6.1.0-amd64
    KERNEL_CONFIRM_UNINSTALL=REMOVE-KERNEL
    kernel_require_uninstall_platform() { return 0; }
    kernel_ensure_uninstall_dependencies() { return 0; }
    vps_cmd_require_root() { return 0; }
    kernel_take_lock() { return 0; }
    kernel_refresh_inventory() {
        KERNEL_GRUB_SUPPORTED=1
        KERNEL_GRUB_DEFAULT_RELEASE=6.8.0-amd64
        KERNEL_GRUB_NEXT_RELEASE=''
        KERNEL_PKG_STATUS["linux-image-7.1.0-x64v3-xanmod1"]='ii '
        KERNEL_PKG_VERSION["linux-image-7.1.0-x64v3-xanmod1"]=7.1.0
    }
    kernel_grub_require() { return 0; }
    kernel_select_release() { return 0; }
    kernel_release_actionable() { return 0; }
    kernel_build_purge_packages() {
        KERNEL_PURGE_PACKAGES=(linux-image-7.1.0-x64v3-xanmod1)
        KERNEL_PURGE_METAPACKAGES=()
    }
    kernel_purge_simulate() { return 0; }
    kernel_confirm_uninstall_action() { return 0; }
    kernel_cleanup_owned_files() { : >"$cleanup_marker"; }
    vps_cmd_run() { return 1; }

    status=0
    kernel_uninstall >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'failed purge returns partial failure'
    [[ -e "$KERNEL_REPO_FILE" && -e "$KERNEL_KEY_FILE" && -e "$KERNEL_STATE_FILE" ]] || test_fail 'failed purge removed XanMod source or state'
    test_assert_file_absent "$cleanup_marker" 'failed purge did not call source cleanup'
)

test_uninstall_modules_residue() (
    local status=0 release=6.5.0-amd64 module_dir="$KERNEL_MODULES_DIR/6.5.0-amd64"
    reset_inventory_fixture
    mkdir -p "$module_dir/kernel/drivers"
    printf 'third-party-module\n' >"$module_dir/kernel/drivers/local.ko"
    VPSCTL_DRY_RUN=0
    KERNEL_ACTION=uninstall
    KERNEL_RELEASE=$release
    KERNEL_RUNNING_RELEASE=6.1.0-amd64
    KERNEL_CONFIRM_UNINSTALL=REMOVE-KERNEL
    kernel_require_uninstall_platform() { return 0; }
    kernel_ensure_uninstall_dependencies() { return 0; }
    vps_cmd_require_root() { return 0; }
    kernel_take_lock() { return 0; }
    kernel_refresh_inventory() {
        KERNEL_GRUB_SUPPORTED=1
        KERNEL_GRUB_DEFAULT_RELEASE=6.8.0-amd64
        KERNEL_GRUB_NEXT_RELEASE=''
        KERNEL_PKG_STATUS["linux-image-6.5.0-amd64"]='ii '
        KERNEL_PKG_VERSION["linux-image-6.5.0-amd64"]=6.5.0
    }
    kernel_grub_require() { return 0; }
    kernel_select_release() { return 0; }
    kernel_release_actionable() { return 0; }
    kernel_build_purge_packages() {
        KERNEL_PURGE_PACKAGES=(linux-image-6.5.0-amd64)
        KERNEL_PURGE_METAPACKAGES=()
    }
    kernel_purge_simulate() { return 0; }
    kernel_confirm_uninstall_action() { return 0; }
    vps_cmd_run() { return 0; }
    kernel_inventory_load() {
        KERNEL_PKG_STATUS["linux-image-6.5.0-amd64"]='pn '
        KERNEL_RELEASE_COMPLETE["6.8.0-amd64"]=1
    }
    kernel_refresh_bootloader() { return 0; }
    kernel_grub_load() {
        KERNEL_GRUB_SUPPORTED=1
        KERNEL_GRUB_DEFAULT_RELEASE=6.8.0-amd64
        KERNEL_GRUB_NEXT_RELEASE=''
        KERNEL_RELEASE_COMPLETE["6.8.0-amd64"]=1
    }

    status=0
    kernel_uninstall >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'non-empty modules-only residue returns partial failure'
    [[ -f "$module_dir/kernel/drivers/local.ko" ]] || test_fail 'uninstall removed unowned residual module file'
)

test_owned_cleanup_and_drift() (
    local status=0
    printf '%s\nTypes: deb\n' "$KERNEL_MANAGED_MARKER" >"$KERNEL_REPO_FILE"
    printf 'key\n' >"$KERNEL_KEY_FILE"
    printf '%s\nschema=1\n' "$KERNEL_MANAGED_MARKER" >"$KERNEL_STATE_FILE"
    vps_cmd_run() { "$@"; }
    kernel_cleanup_owned_files
    [[ ! -e "$KERNEL_REPO_FILE" && ! -e "$KERNEL_KEY_FILE" && ! -e "$KERNEL_STATE_FILE" ]] || test_fail 'owned XanMod files were not removed'

    printf 'Types: deb\n' >"$KERNEL_REPO_FILE"
    status=0
    kernel_cleanup_owned_files >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'unmanaged repository cleanup refusal'
    [[ -e "$KERNEL_REPO_FILE" ]] || test_fail 'unmanaged repository was removed'
    rm -f -- "$KERNEL_REPO_FILE"
)

test_init
test_arguments_and_compatibility
test_provider_candidates_and_cpu
test_menu_install_availability_and_xanmod_inputs
test_secure_boot_is_provider_specific
test_key_fingerprint_and_xanmod_origin
test_dpkg_state_parsing
test_confirmations_and_root_gate
test_dry_run_zero_write
test_install_meta_release_verification
test_switch_signature_gate
test_status_version_rows
test_release_selection_protection
test_purge_simulation_guards
test_uninstall_target_change_guard
test_dry_run_exact_package_array
test_purge_failure_preserves_xanmod_source
test_uninstall_modules_residue
test_owned_cleanup_and_drift
printf 'PASS: system kernel tests\n'
