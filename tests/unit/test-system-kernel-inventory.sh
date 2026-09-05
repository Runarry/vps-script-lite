#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
TEST_TEMP="$(mktemp -d)"
readonly TEST_TEMP
TEST_SYSTEM_ROOT="$TEST_TEMP/system"
readonly TEST_SYSTEM_ROOT
trap 'rm -rf -- "$TEST_TEMP"' EXIT

mkdir -p "$TEST_SYSTEM_ROOT/boot" "$TEST_SYSTEM_ROOT/lib/modules"
export VPSCTL_TESTING=1
export VPSCTL_SYSTEM_ROOT="$TEST_SYSTEM_ROOT"
export VPSCTL_NON_INTERACTIVE=1
export VPSCTL_NO_COLOR=1

# shellcheck source=../../lib/command.sh
source "$TEST_ROOT/lib/command.sh"
vps_cmd_init system-kernel-inventory "$TEST_ROOT"
KERNEL_BOOT_DIR="$(vps_cmd_system_path /boot)"
KERNEL_MODULES_DIR="$(vps_cmd_system_path /lib/modules)"
KERNEL_OS_ID=debian
KERNEL_OS_VERSION_ID=13
KERNEL_RUNNING_RELEASE='6.12.10-amd64'

# shellcheck source=../../commands/system/kernel/inventory.sh
source "$TEST_ROOT/commands/system/kernel/inventory.sh"

test_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

test_assert_equal() {
    local expected="$1" actual="$2" message="$3"
    [[ "$expected" == "$actual" ]] || test_fail "$message: expected '$expected', got '$actual'"
}

test_assert_array_has() {
    local array_name="$1" expected="$2" message="$3" item
    local -n values="$array_name"
    for item in "${values[@]}"; do [[ "$item" == "$expected" ]] && return 0; done
    test_fail "$message: missing '$expected'"
}

test_assert_array_lacks() {
    local array_name="$1" rejected="$2" message="$3" item
    local -n values="$array_name"
    for item in "${values[@]}"; do [[ "$item" != "$rejected" ]] || test_fail "$message: unexpected '$rejected'"; done
}

DPKG_DATABASE=''
declare -A DPKG_OWNERS=()

dpkg-query() {
    case "${1:-}" in
        -W) printf '%s' "$DPKG_DATABASE" ;;
        -S)
            local path="${3:-}" owner="${DPKG_OWNERS[${3:-}]:-}"
            [[ -n "$owner" ]] || return 1
            printf '%s: %s\n' "$owner" "$path"
            ;;
        *) return 2 ;;
    esac
}

write_release() {
    local release="$1"
    printf 'kernel\n' >"$KERNEL_BOOT_DIR/vmlinuz-$release"
    printf 'initrd\n' >"$KERNEL_BOOT_DIR/initrd.img-$release"
    mkdir -p "$KERNEL_MODULES_DIR/$release/kernel"
    printf 'module\n' >"$KERNEL_MODULES_DIR/$release/kernel/core.ko"
}

load_debian_fixture() {
    local debian_release='6.12.10-amd64' xanmod_release='6.12.1-x64v3-xanmod1' manual_release='6.9.1-custom'
    write_release "$debian_release"
    write_release "$xanmod_release"
    write_release "$manual_release"
    DPKG_OWNERS=()
    DPKG_OWNERS["$KERNEL_BOOT_DIR/vmlinuz-$debian_release"]="linux-image-$debian_release"
    DPKG_OWNERS["$KERNEL_BOOT_DIR/vmlinuz-$xanmod_release"]="linux-image-$xanmod_release"
    DPKG_DATABASE="$({
        printf 'ii \tlinux-image-%s\t1.0\tlinux-base\n' "$debian_release"
        printf 'ii \tlinux-headers-%s\t1.0\tlinux-headers-6.12.10-common\n' "$debian_release"
        printf 'ii \tlinux-headers-6.12.10-common\t1.0\t\n'
        printf 'ii \tlinux-image-amd64\t1.0\tlinux-image-%s (= 1.0)\n' "$debian_release"
        printf 'ii \tlinux-amd64\t1.0\tlinux-image-amd64 (= 1.0)\n'
        printf 'ii \tlinux-image-%s\t2.0\tlinux-base\n' "$xanmod_release"
        printf 'ii \tlinux-headers-%s\t2.0\tlinux-headers-common\n' "$xanmod_release"
        printf 'rc \tlinux-modules-extra-%s\t2.0\t\n' "$xanmod_release"
        printf 'ii \tlinux-firmware\t1.0\t\n'
    })"
    KERNEL_OS_ID=debian
}

test_release_validation() {
    kernel_release_valid '6.12.105+deb13-amd64' || test_fail 'valid Debian release rejected'
    kernel_release_valid '6.12.1-x64v3-xanmod1' || test_fail 'valid XanMod release rejected'
    if kernel_release_valid '../6.12.1'; then test_fail 'path release accepted'; fi
    if kernel_release_valid $'6.12.1\nroot'; then test_fail 'control character accepted'; fi
    if kernel_release_valid '6.12.1 amd64'; then test_fail 'whitespace accepted'; fi
    if kernel_release_valid ''; then test_fail 'empty release accepted'; fi
}

test_inventory_and_meta_resolution() {
    load_debian_fixture
    kernel_inventory_load
    test_assert_equal '1' "${KERNEL_RELEASE_COMPLETE["6.12.10-amd64"]}" 'complete Debian release'
    test_assert_equal '1' "${KERNEL_RELEASE_MANAGED["6.12.10-amd64"]}" 'managed Debian release'
    test_assert_equal 'Debian 官方' "${KERNEL_RELEASE_SOURCE["6.12.10-amd64"]}" 'Debian source'
    test_assert_equal 'debian:official' "${KERNEL_RELEASE_SERIES["6.12.10-amd64"]}" 'Debian series'
    test_assert_equal 'XanMod' "${KERNEL_RELEASE_SOURCE["6.12.1-x64v3-xanmod1"]}" 'XanMod source'
    test_assert_equal 'unknown' "${KERNEL_RELEASE_SERIES["6.12.1-x64v3-xanmod1"]}" 'standalone XanMod series'
    test_assert_equal '手工/未知' "${KERNEL_RELEASE_SOURCE["6.9.1-custom"]}" 'manual source'
    test_assert_equal '0' "${KERNEL_RELEASE_MANAGED["6.9.1-custom"]}" 'manual release safety gate'
    kernel_inventory_package_installed linux-image-6.12.10-amd64 || test_fail 'installed package not recognized'
    if kernel_inventory_package_installed linux-modules-extra-6.12.1-x64v3-xanmod1; then test_fail 'rc package considered installed'; fi

    kernel_inventory_meta_releases linux-amd64
    test_assert_equal '6.12.10-amd64' "${KERNEL_META_RELEASES[0]}" 'nested Debian meta resolution'
}

test_purge_set_and_simulation() {
    local output status=0
    kernel_build_purge_packages 6.12.10-amd64
    test_assert_array_has KERNEL_PURGE_PACKAGES linux-image-6.12.10-amd64 'image purge target'
    test_assert_array_has KERNEL_PURGE_PACKAGES linux-headers-6.12.10-amd64 'exclusive header purge target'
    test_assert_array_has KERNEL_PURGE_PACKAGES linux-image-amd64 'version meta purge target'
    test_assert_array_has KERNEL_PURGE_PACKAGES linux-amd64 'outer meta purge target'
    test_assert_array_lacks KERNEL_PURGE_PACKAGES linux-headers-6.12.10-common 'shared header exclusion'
    test_assert_array_lacks KERNEL_PURGE_PACKAGES linux-firmware 'firmware exclusion'
    test_assert_array_has KERNEL_PURGE_METAPACKAGES linux-image-amd64 'meta warning list'
    test_assert_array_has KERNEL_PURGE_METAPACKAGES linux-amd64 'nested meta warning list'

    output=$'Purg linux-image-6.12.10-amd64 [1.0]\nPurg linux-headers-6.12.10-amd64 [1.0]\nRemv linux-image-amd64 [1.0]\nRemv linux-amd64 [1.0]'
    kernel_validate_purge_simulation "$output" 0
    status=0
    kernel_validate_purge_simulation "$output" 100 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'nonzero simulation rejection'
    status=0
    kernel_validate_purge_simulation "$output"$'\nInst linux-image-9.9.9-amd64 (9.9)' 0 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'simulation install rejection'
    status=0
    kernel_validate_purge_simulation "$output"$'\nRemv bash [1.0]' 0 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'out-of-scope removal rejection'
    status=0
    kernel_validate_purge_simulation $'Purg linux-image-6.12.10-amd64 [1.0]' 0 >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'incomplete simulation rejection'

    kernel_build_purge_packages 6.12.1-x64v3-xanmod1
    test_assert_array_has KERNEL_PURGE_PACKAGES linux-image-6.12.1-x64v3-xanmod1 'standalone XanMod purge'
    test_assert_array_has KERNEL_PURGE_PACKAGES linux-modules-extra-6.12.1-x64v3-xanmod1 'XanMod rc cleanup'
}

test_half_configured_rejection() {
    local saved="$DPKG_DATABASE" status=0
    DPKG_DATABASE=$'iF \tlinux-image-6.12.10-amd64\t1.0\t\n'
    kernel_inventory_load >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'half-configured kernel package rejection'
    DPKG_DATABASE="$saved"
    kernel_inventory_load
}

test_ubuntu_series_ambiguity() {
    local release='6.8.0-90-generic' status=0
    rm -rf -- "$KERNEL_BOOT_DIR" "$KERNEL_MODULES_DIR"
    mkdir -p "$KERNEL_BOOT_DIR" "$KERNEL_MODULES_DIR"
    write_release "$release"
    KERNEL_OS_ID=ubuntu
    DPKG_OWNERS=()
    DPKG_OWNERS["$KERNEL_BOOT_DIR/vmlinuz-$release"]="linux-image-$release"
    DPKG_DATABASE="$({
        printf 'ii \tlinux-image-%s\t1.0\t\n' "$release"
        printf 'ii \tlinux-image-generic\t1.0\tlinux-image-%s (= 1.0)\n' "$release"
        printf 'ii \tlinux-image-generic-hwe-22.04\t1.0\tlinux-image-%s (= 1.0)\n' "$release"
    })"
    kernel_inventory_load
    test_assert_equal Ubuntu "${KERNEL_RELEASE_SOURCE[$release]}" 'Ubuntu source display'
    test_assert_equal 1 "${KERNEL_RELEASE_MANAGED[$release]}" 'package-proven Ubuntu remains managed'
    kernel_inventory_meta_releases linux-image-generic
    test_assert_equal "$release" "${KERNEL_META_RELEASES[0]}" 'GA meta installation resolution'
    kernel_inventory_meta_releases linux-image-generic-hwe-22.04
    test_assert_equal "$release" "${KERNEL_META_RELEASES[0]}" 'HWE meta installation resolution'
    status=0
    kernel_build_purge_packages "$release" >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'ambiguous Ubuntu meta closure rejection'

    DPKG_DATABASE="$(printf 'ii \tlinux-image-%s\t1.0\t\n' "$release")"
    kernel_inventory_load
    test_assert_equal 1 "${KERNEL_RELEASE_MANAGED[$release]}" 'unreferenced old Ubuntu release remains managed'
    test_assert_equal unknown "${KERNEL_RELEASE_SERIES[$release]}" 'unreferenced Ubuntu series remains unknown'
    kernel_build_purge_packages "$release"
    test_assert_array_has KERNEL_PURGE_PACKAGES "linux-image-$release" 'old Ubuntu concrete purge target'
}

test_ubuntu_virtual_and_generic_ga_closure() {
    local ga_release='6.8.0-138-generic' hwe_release='6.11.0-1018-generic' status=0
    local package
    rm -rf -- "$KERNEL_BOOT_DIR" "$KERNEL_MODULES_DIR"
    mkdir -p "$KERNEL_BOOT_DIR" "$KERNEL_MODULES_DIR"
    write_release "$ga_release"
    write_release "$hwe_release"
    KERNEL_OS_ID=ubuntu
    DPKG_OWNERS=()
    DPKG_OWNERS["$KERNEL_BOOT_DIR/vmlinuz-$ga_release"]="linux-image-$ga_release"
    DPKG_OWNERS["$KERNEL_BOOT_DIR/vmlinuz-$hwe_release"]="linux-image-$hwe_release"
    DPKG_DATABASE="$({
        printf 'ii \tlinux-image-%s\t1.0\t\n' "$ga_release"
        printf 'ii \tlinux-headers-%s\t1.0\t\n' "$ga_release"
        printf 'ii \tlinux-image-generic\t1.0\tlinux-image-%s (= 1.0)\n' "$ga_release"
        printf 'ii \tlinux-headers-generic\t1.0\tlinux-headers-%s (= 1.0)\n' "$ga_release"
        printf 'ii \tlinux-generic\t1.0\tlinux-image-generic (= 1.0), linux-headers-generic (= 1.0)\n'
        printf 'ii \tlinux-image-virtual\t1.0\tlinux-image-%s (= 1.0)\n' "$ga_release"
        printf 'ii \tlinux-headers-virtual\t1.0\tlinux-headers-%s (= 1.0)\n' "$ga_release"
        printf 'ii \tlinux-virtual\t1.0\tlinux-image-virtual (= 1.0), linux-headers-virtual (= 1.0)\n'
        printf 'ii \tlinux-image-%s\t2.0\t\n' "$hwe_release"
        printf 'ii \tlinux-headers-%s\t2.0\t\n' "$hwe_release"
        printf 'ii \tlinux-image-generic-hwe-24.04\t2.0\tlinux-image-%s (= 2.0)\n' "$hwe_release"
        printf 'ii \tlinux-headers-generic-hwe-24.04\t2.0\tlinux-headers-%s (= 2.0)\n' "$hwe_release"
        printf 'ii \tlinux-generic-hwe-24.04\t2.0\tlinux-image-generic-hwe-24.04 (= 2.0), linux-headers-generic-hwe-24.04 (= 2.0)\n'
        printf 'ii \tlinux-image-virtual-hwe-24.04\t2.0\tlinux-image-%s (= 2.0)\n' "$hwe_release"
        printf 'ii \tlinux-headers-virtual-hwe-24.04\t2.0\tlinux-headers-%s (= 2.0)\n' "$hwe_release"
        printf 'ii \tlinux-virtual-hwe-24.04\t2.0\tlinux-image-virtual-hwe-24.04 (= 2.0), linux-headers-virtual-hwe-24.04 (= 2.0)\n'
    })"
    kernel_inventory_load
    test_assert_equal ubuntu:official "${KERNEL_RELEASE_SERIES[$ga_release]}" 'generic and virtual GA series'
    test_assert_equal ubuntu:hwe "${KERNEL_RELEASE_SERIES[$hwe_release]}" 'separate HWE series'
    kernel_inventory_meta_releases linux-virtual
    test_assert_equal "$ga_release" "${KERNEL_META_RELEASES[0]}" 'virtual meta resolves GA release'
    kernel_build_purge_packages "$ga_release"
    for package in linux-image-generic linux-headers-generic linux-generic linux-image-virtual linux-headers-virtual linux-virtual; do
        test_assert_array_has KERNEL_PURGE_METAPACKAGES "$package" 'GA generic/virtual meta closure'
    done
    for package in linux-image-generic-hwe-24.04 linux-headers-generic-hwe-24.04 linux-generic-hwe-24.04 linux-image-virtual-hwe-24.04 linux-headers-virtual-hwe-24.04 linux-virtual-hwe-24.04; do
        test_assert_array_lacks KERNEL_PURGE_PACKAGES "$package" 'HWE packages protected from GA purge'
    done

    if _kernel_inventory_meta_series linux-generic-hwe-24.04-edge >/dev/null; then test_fail 'generic HWE edge accepted as fixed meta'; fi
    if _kernel_inventory_meta_series linux-virtual-hwe-24.04-edge >/dev/null; then test_fail 'virtual HWE edge accepted as fixed meta'; fi
    if _kernel_inventory_meta_series linux-oem-24.04 >/dev/null; then test_fail 'OEM channel accepted as fixed meta'; fi
    DPKG_DATABASE=$'iF \tlinux-virtual-hwe-24.04-edge\t2.0\t\n'
    status=0
    kernel_inventory_load >/dev/null 2>&1 || status=$?
    test_assert_equal 30 "$status" 'non-whitelist edge half-configured protection'
}

test_image_ownership_guards() {
    local release_a='6.7.1-amd64' release_b='6.7.2-amd64'
    rm -rf -- "$KERNEL_BOOT_DIR" "$KERNEL_MODULES_DIR"
    mkdir -p "$KERNEL_BOOT_DIR" "$KERNEL_MODULES_DIR"
    write_release "$release_a"
    write_release "$release_b"
    KERNEL_OS_ID=debian
    DPKG_OWNERS=()
    DPKG_OWNERS["$KERNEL_BOOT_DIR/vmlinuz-$release_a"]="linux-image-$release_a"
    DPKG_OWNERS["$KERNEL_BOOT_DIR/vmlinuz-$release_b"]="linux-image-$release_a"
    DPKG_DATABASE="$(printf 'ii \tlinux-image-%s\t1.0\t\n' "$release_a")"
    kernel_inventory_load
    test_assert_equal 0 "${KERNEL_RELEASE_MANAGED[$release_a]}" 'multi-image owner protects matching release'
    test_assert_equal 0 "${KERNEL_RELEASE_MANAGED[$release_b]}" 'mismatched image owner rejected'

    rm -f -- "$KERNEL_BOOT_DIR/vmlinuz-$release_b"
    ln -s "vmlinuz-$release_a" "$KERNEL_BOOT_DIR/vmlinuz-$release_b"
    DPKG_OWNERS["$KERNEL_BOOT_DIR/vmlinuz-$release_b"]="linux-image-$release_b"
    DPKG_DATABASE+=$'\n'"$(printf 'ii \tlinux-image-%s\t1.0\t\n' "$release_b")"
    kernel_inventory_load
    test_assert_equal 0 "${KERNEL_RELEASE_MANAGED[$release_b]}" 'symlink image is never package-trusted'
    test_assert_equal 0 "${KERNEL_RELEASE_COMPLETE[$release_b]}" 'symlink image is never boot-complete'
}

test_release_validation
test_inventory_and_meta_resolution
test_purge_set_and_simulation
test_half_configured_rejection
test_ubuntu_series_ambiguity
test_ubuntu_virtual_and_generic_ga_closure
test_image_ownership_guards
printf 'PASS: system kernel inventory tests\n'
