#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly TEST_ROOT
readonly VPSCTL=(bash "${TEST_ROOT}/bin/vpsctl" --no-color --no-clear)

test_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

test_contains() {
    local output="$1"
    local expected="$2"
    local message="$3"
    [[ "$output" == *"$expected"* ]] || test_fail "${message}: missing '${expected}'"
}

test_not_contains() {
    local output="$1"
    local unexpected="$2"
    local message="$3"
    [[ "$output" != *"$unexpected"* ]] || test_fail "${message}: unexpected '${unexpected}'"
}

test_no_ansi() {
    local output="$1"
    local message="$2"
    [[ "$output" != *$'\033['* ]] || test_fail "${message}: unexpected ANSI escape"
}

test_cli() {
    local output status option

    output="$("${VPSCTL[@]}" --version)"
    test_contains "$output" "vpsctl $(<"${TEST_ROOT}/VERSION")" "version output"

    output="$("${VPSCTL[@]}" --help)"
    test_contains "$output" "<domain> <action>" "help command model"
    test_contains "$output" "用法" "localized usage heading"
    test_contains "$output" "内置命令" "localized built-in heading"
    test_contains "$output" "--install-deps" "global install-deps help"
    test_no_ansi "$output" "--no-color help output"

    output="$("${VPSCTL[@]}" env)"
    test_contains "$output" "VPS Script Lite" "environment header"
    test_contains "$output" "系统" "environment system field"
    test_contains "$output" "BBR 状态" "BBR status field"
    test_contains "$output" "BBR 版本" "BBR version field"
    test_contains "$output" "拥塞控制" "congestion-control algorithm field"
    test_contains "$output" "兼容性" "environment compatibility field"
    test_contains "$output" "系统族" "environment OS family field"
    test_contains "$output" "代号" "environment codename field"
    test_contains "$output" "用户空间" "environment libc field"
    test_no_ansi "$output" "--no-color environment output"
    [[ "$output" != *"Init / Packages"* ]] || test_fail "removed Init / Packages field is still visible"
    [[ "$output" != *"Session"* ]] || test_fail "removed Session field is still visible"

    output="$(TERM=xterm bash "${TEST_ROOT}/bin/vpsctl" env)"
    test_no_ansi "$output" "non-TTY environment output"
    output="$(NO_COLOR=1 TERM=xterm bash "${TEST_ROOT}/bin/vpsctl" env)"
    test_no_ansi "$output" "NO_COLOR environment output"

    output="$("${VPSCTL[@]}" list)"
    test_contains "$output" "network bbr" "BBR command listing"
    test_contains "$output" "network dns" "DNS command listing"
    test_contains "$output" "network ip-policy" "IP policy command listing"
    test_contains "$output" "network ufw" "UFW command listing"
    test_contains "$output" "network rfw" "RFW command listing"
    test_contains "$output" "system kernel" "kernel command listing"
    test_contains "$output" "system reinstall" "reinstall command listing"
    test_contains "$output" "system swap" "swap command listing"
    test_contains "$output" "system backup" "system backup command listing"
    test_contains "$output" "system backup-docker" "Docker backup command listing"
    test_contains "$output" "system backup-repo" "repository command listing"
    test_contains "$output" "security access" "access command listing"
    test_contains "$output" "security tls" "tls command listing"
    test_contains "$output" "service proxy" "proxy command listing"
    test_contains "$output" "service tcping" "tcping command listing"
    test_contains "$output" "service iperf3" "iperf3 command listing"
    test_contains "$output" "test nodequality" "NodeQuality command listing"
    test_contains "$output" "test tcpquality" "TCPQuality command listing"
    test_contains "$output" "self status" "self status command listing"
    test_contains "$output" "self update" "self update command listing"
    test_contains "$output" "self uninstall" "self uninstall command listing"

    for option in --dry-run --install-deps --yes --non-interactive --quiet --verbose; do
        status=0
        output="$("${VPSCTL[@]}" "$option" menu 2>&1)" || status=$?
        [[ "$status" == "2" ]] || test_fail "menu option $option should return 2, got ${status}"
        test_contains "$output" "$option" "menu execution-option rejection"
        test_contains "$output" "交互菜单不能使用执行型全局选项" "localized menu option rejection"
    done

    status=0
    output="$(bash "${TEST_ROOT}/bin/vpsctl" --no-color --no-clear menu 2>&1)" || status=$?
    [[ "$status" == "2" ]] || test_fail "non-TTY menu should return 2, got ${status}"
    test_contains "$output" "交互菜单需要终端" "display-only menu options remain accepted"
    test_not_contains "$output" "不能使用执行型全局选项" "display-only menu option rejection"

    status=0
    output="$("${VPSCTL[@]}" system missing 2>&1)" || status=$?
    [[ "$status" == "2" ]] || test_fail "unknown command should return 2, got ${status}"
    test_contains "$output" "未知命令" "localized unknown-command error"
    test_no_ansi "$output" "--no-color unknown-command error"

    status=0
    output="$("${VPSCTL[@]}" --unknown 2>&1)" || status=$?
    [[ "$status" == "2" ]] || test_fail "unknown option should return 2, got ${status}"
    test_contains "$output" "未知全局选项" "localized unknown-option error"
    test_no_ansi "$output" "--no-color unknown-option error"
}

test_entry_version() (
    local sandbox output status value marker menu_command
    local -a reader=(bash)
    sandbox="$(mktemp -d)"
    trap 'rm -rf -- "$sandbox"' EXIT
    mkdir -p "$sandbox/bin" "$sandbox/lib"
    cp "$TEST_ROOT/bin/vpsctl" "$sandbox/bin/vpsctl"
    cp "$TEST_ROOT"/lib/*.sh "$sandbox/lib/"
    printf '9.8.7\n' >"$sandbox/VERSION"
    output="$(bash "$sandbox/bin/vpsctl" --no-color --version)"
    [[ "$output" == 'vpsctl 9.8.7' ]] || test_fail "temporary VERSION did not control CLI: $output"
    output="$(bash "$sandbox/bin/vpsctl" --no-color env)"
    test_contains "$output" 'v9.8.7' 'temporary VERSION controls environment panel'
    if command -v script >/dev/null 2>&1; then
        printf -v menu_command 'TERM=xterm bash %q --no-color --no-clear menu' "$sandbox/bin/vpsctl"
        output="$(printf 'q\n' | script -q -e -f -c "$menu_command" /dev/null 2>&1)"
        test_contains "$output" 'v9.8.7' 'temporary VERSION controls TTY menu'
    else
        printf 'SKIP: version menu test requires script\n'
    fi
    printf '9.8.7' >"$sandbox/VERSION"
    output="$(bash "$sandbox/bin/vpsctl" --version)"
    [[ "$output" == 'vpsctl 9.8.7' ]] || test_fail 'valid VERSION without a final newline was rejected'

    # If startup reaches even its first library, record it and fail differently.
    marker="$sandbox/library-loaded"
    printf 'printf loaded >%q\nexit 99\n' "$marker" >"$sandbox/lib/environment.sh"
    assert_version_rejected() {
        local description="$1" option
        local -a command_args=()
        for option in --version env dispatch; do
            command_args=("$option")
            [[ "$option" != dispatch ]] || command_args=(network bbr status)
            status=0
            output="$("${reader[@]}" "$sandbox/bin/vpsctl" "${command_args[@]}" 2>&1)" || status=$?
            [[ "$status" == 3 ]] || test_fail "$description should return 3, got $status: $output"
            [[ ! -e "$marker" ]] || test_fail "$description loaded libraries before rejecting VERSION"
            test_contains "$output" VERSION "$description diagnostic identifies VERSION"
        done
    }
    rm -- "$sandbox/VERSION"
    assert_version_rejected 'missing VERSION'
    for value in '' '9.8' 'v9.8.7' '9.8.7-beta' ' 9.8.7' $'9.8.7\n1.2.3'; do
        printf '%s' "$value" >"$sandbox/VERSION"
        assert_version_rejected "empty or malformed VERSION <$value>"
    done
    rm -- "$sandbox/VERSION"
    mkdir "$sandbox/VERSION"
    assert_version_rejected 'non-regular VERSION'
    rmdir "$sandbox/VERSION"
    printf '9.8.7\n' >"$sandbox/VERSION"
    chmod 0000 "$sandbox/VERSION"
    if ((EUID != 0)); then
        assert_version_rejected 'unreadable VERSION'
    elif command -v setpriv >/dev/null 2>&1; then
        reader=(setpriv '--bounding-set=-dac_override,-dac_read_search' bash)
        assert_version_rejected 'unreadable VERSION without DAC override'
    else
        printf 'SKIP: unreadable VERSION as root requires setpriv\n'
    fi
    chmod 0600 "$sandbox/VERSION"
)

test_dispatch_security() (
    local sandbox output status marker menu_command download_marker expected direct direct_status feature
    local -a feature_env=() reader=() manager_options=(--no-color --non-interactive)

    [[ "$(uname -s)" == "Linux" ]] || return 0
    sandbox="$(mktemp -d)"
    trap 'rm -rf -- "$sandbox"' EXIT
    mkdir -p "$sandbox/bin" "$sandbox/lib" "$sandbox/commands/network" "$sandbox/commands/system" "$sandbox/commands/security" "$sandbox/commands/service/proxy" "$sandbox/commands/test"
    cp "$TEST_ROOT/bin/vpsctl" "$sandbox/bin/vpsctl"
    cp "$TEST_ROOT"/lib/*.sh "$sandbox/lib/"
    cp "$TEST_ROOT/VERSION" "$sandbox/VERSION"
    cat >>"$sandbox/lib/distribution.sh" <<'EOF'

vps_distribution_ensure_command() {
    if [[ -n "${VPSCTL_DOWNLOAD_MARKER:-}" ]]; then
        printf '%s\n' "$1" >>"$VPSCTL_DOWNLOAD_MARKER"
    fi
}
EOF
    cat >>"$sandbox/lib/environment.sh" <<'EOF'

# Make dispatch capability checks hermetic: this fixture deliberately exposes
# Linux and no init/service capability, regardless of the integration host.
vps_env_detect() {
    VPS_ENV[hostname]="fixture"
    VPS_ENV[user]="fixture"
    VPS_ENV[session]="non-interactive"
    VPS_ENV[interactive]="no"
    VPS_ENV[kernel_name]="${VPSCTL_FIXTURE_KERNEL:-Linux}"
    VPS_ENV[kernel_release]="fixture"
    VPS_ENV[architecture]="x86_64"
    VPS_ENV[os_id]="${VPSCTL_FIXTURE_OS:-fixture}"
    VPS_ENV[os_id_like]=""
    VPS_ENV[os_version_id]="1"
    VPS_ENV[os_codename]="fixture"
    VPS_ENV[os_pretty_name]="Fixture Linux"
    VPS_ENV[libc]="${VPSCTL_FIXTURE_LIBC:-musl}"
    VPS_ENV[bash_version]="${BASH_VERSION}"
    VPS_ENV[cpu_model]="fixture"
    VPS_ENV[cpu_cores]="1"
    VPS_ENV[memory_total]="1.0 GiB"
    VPS_ENV[uptime]="1 分钟"
    VPS_ENV[root_disk_total]="1.0 GiB"
    VPS_ENV[root_disk_available]="1.0 GiB"
    VPS_ENV[root_disk_used_percent]="0%"
    VPS_ENV[ipv4]="192.0.2.1"
    VPS_ENV[ipv6]="unavailable"
    VPS_ENV[init_system]="${VPSCTL_FIXTURE_INIT:-none}"
    VPS_ENV[service_manager]="none"
    VPS_ENV[package_manager]="unknown"
    VPS_ENV[timezone]="UTC"
    VPS_ENV[virtualization]="unknown"
    VPS_ENV[is_root]="no"
    VPS_ENV[bbr_status]="disabled"
    VPS_ENV[bbr_version]="unavailable"
    VPS_ENV[congestion_control]="unknown"
    VPS_ENV[available_congestion_controls]="unknown"
    VPS_ENV[compatibility]="limited"
    VPS_ENV[compatibility_detail]="fixture"
    VPS_CAPABILITY=()
    [[ "${VPS_ENV[kernel_name]}" != Linux ]] || VPS_CAPABILITY[linux]=1
}
EOF
    cat >"$sandbox/commands/network/bbr.sh" <<'EOF'
#!/usr/bin/env bash
printf 'no_color=%s\n' "${VPSCTL_NO_COLOR:-missing}"
printf 'install_deps=%s\n' "${VPSCTL_INSTALL_DEPS:-missing}"
printf 'libc=%s\n' "${VPSCTL_ENV_LIBC:-missing}"
printf 'bbr_args=%s\n' "$*"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'bbr:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
exit "${VPSCTL_DISPATCH_STATUS:-0}"
EOF
    chmod 0644 "$sandbox/commands/network/bbr.sh"

    cat >"$sandbox/commands/system/reinstall.sh" <<'EOF'
#!/usr/bin/env bash
printf 'reinstall_noninteractive=%s\n' "${VPSCTL_NON_INTERACTIVE:-missing}"
printf 'reinstall_arg=<%s>\n' "$@"
exit "${VPSCTL_DISPATCH_STATUS:-0}"
EOF
    chmod 0644 "$sandbox/commands/system/reinstall.sh"

    cat >"$sandbox/commands/system/swap.sh" <<'EOF'
#!/usr/bin/env bash
printf 'swap_no_color=%s\n' "${VPSCTL_NO_COLOR:-missing}"
printf 'swap_dry_run=%s\n' "${VPSCTL_DRY_RUN:-missing}"
printf 'swap_yes=%s\n' "${VPSCTL_ASSUME_YES:-missing}"
printf 'swap_noninteractive=%s\n' "${VPSCTL_NON_INTERACTIVE:-missing}"
printf 'swap_install_deps=%s quiet=%s verbose=%s clear=%s\n' "${VPSCTL_INSTALL_DEPS:-missing}" "${VPSCTL_QUIET:-missing}" "${VPSCTL_VERBOSE:-missing}" "${VPSCTL_CLEAR:-missing}"
printf 'swap_arg=<%s>\n' "$@"
[[ -z "${VPSCTL_DISPATCH_MARKER:-}" ]] || printf 'swap:%s\n' "$*" >>"$VPSCTL_DISPATCH_MARKER"
exit "${VPSCTL_DISPATCH_STATUS:-0}"
EOF
    chmod 0644 "$sandbox/commands/system/swap.sh"

    output="$(bash "$sandbox/bin/vpsctl" --no-color network bbr status)"
    test_contains "$output" "no_color=1" "no-color child context"
    output="$(bash "$sandbox/bin/vpsctl" --install-deps network bbr status)"
    test_contains "$output" "install_deps=1" "install-deps child context"
    test_contains "$output" "libc=musl" "libc child context"

    if command -v script >/dev/null 2>&1; then
        marker="$sandbox/menu-executed"
        printf -v menu_command 'env VPSCTL_DISPATCH_MARKER=%q VPSCTL_DISPATCH_STATUS=7 bash %q --no-color --no-clear menu' "$marker" "$sandbox/bin/vpsctl"
        status=0
        output="$(printf '1\n1\n\nb\nq\n' | script -q -e -f -c "$menu_command" /dev/null 2>&1)" || status=$?
        [[ "$status" == "7" ]] || test_fail "menu should preserve feature status 7, got ${status}"
        test_contains "$output" "bbr_args=" "menu zero-argument dispatch"
        test_not_contains "$output" "命令详情" "removed command detail screen"
        test_not_contains "$output" "[r] 无附加参数运行" "removed run confirmation"
        [[ -f "$marker" && "$(<"$marker")" == "bbr:" ]] || test_fail "menu did not dispatch the selected feature without arguments"

        marker="$sandbox/menu-swap-executed"
        printf -v menu_command 'env VPSCTL_DISPATCH_MARKER=%q VPSCTL_DISPATCH_STATUS=30 bash %q --no-color --no-clear menu' "$marker" "$sandbox/bin/vpsctl"
        status=0
        output="$(printf '2\n3\n\nb\nq\n' | script -q -e -f -c "$menu_command" /dev/null 2>&1)" || status=$?
        [[ "$status" == 30 ]] || test_fail "swap menu should preserve partial completion status 30, got ${status}"
        test_contains "$output" "Swap 管理" "system menu swap label"
        test_contains "$output" "swap_no_color=1" "swap menu child display context"
        [[ -f "$marker" && "$(<"$marker")" == "swap:" ]] || test_fail "system menu item 3 did not dispatch swap without arguments"
    fi

    marker="$sandbox/executed"
    download_marker="$sandbox/downloaded"

    # Check complete argv boundaries, including empty and newline arguments.
    # shellcheck disable=SC2016 # Forward shell metacharacters literally.
    output="$(bash "$sandbox/bin/vpsctl" --no-color --no-clear --dry-run --install-deps --yes --non-interactive --quiet --verbose system swap set --size '2 G' '' $'line one\nline two' 'a $b; c' '*')"
    # shellcheck disable=SC2016 # This literal is the expected argv serialization.
    expected=$'swap_arg=<set>\nswap_arg=<--size>\nswap_arg=<2 G>\nswap_arg=<>\nswap_arg=<line one\nline two>\nswap_arg=<a $b; c>\nswap_arg=<*>'
    [[ "${output#*swap_install_deps=1 quiet=1 verbose=1 clear=0$'\n'}" == "$expected" ]] || test_fail "dispatch changed argv boundaries: $output"
    test_contains "$output" 'swap_no_color=1' 'display child context'
    test_contains "$output" 'swap_dry_run=1' 'dry-run child context'
    test_contains "$output" 'swap_yes=1' 'confirmation child context'
    test_contains "$output" 'swap_noninteractive=1' 'noninteractive child context'
    test_contains "$output" 'swap_install_deps=1 quiet=1 verbose=1 clear=0' 'remaining global child context'
    output="$(bash "$sandbox/bin/vpsctl" --non-interactive system reinstall run -- windows --image-name 'Windows 11 Enterprise LTSC 2024' --iso 'https://example.invalid/a.iso?x=1&y=two' --password 'a $b; c')"
    test_contains "$output" 'reinstall_noninteractive=1' 'reinstall global context'
    test_contains "$output" 'reinstall_arg=<-->' 'upstream separator'
    test_contains "$output" 'reinstall_arg=<Windows 11 Enterprise LTSC 2024>' 'spaced upstream argument'
    test_contains "$output" 'reinstall_arg=<https://example.invalid/a.iso?x=1&y=two>' 'URL upstream argument'
    # shellcheck disable=SC2016 # Forward shell metacharacters literally.
    test_contains "$output" 'reinstall_arg=<a $b; c>' 'literal upstream argument'
    for status in 7 17 30; do
        direct_status=0
        VPSCTL_DISPATCH_STATUS="$status" bash "$sandbox/bin/vpsctl" system swap arbitrary >/dev/null 2>&1 || direct_status=$?
        [[ "$direct_status" == "$status" ]] || test_fail "dispatch lost child exit status $status: $direct_status"
    done

    # Inject startup hooks after manager startup; they must not reach its child.
    printf 'touch %q\n' "$marker" >"$sandbox/startup-hook"
    cat >>"$sandbox/lib/distribution.sh" <<'EOF'
vps_distribution_ensure_command() {
    [[ -z "${VPSCTL_DOWNLOAD_MARKER:-}" ]] || printf '%s\n' "$1" >>"$VPSCTL_DOWNLOAD_MARKER"
    export BASH_ENV="${VPSCTL_TEST_STARTUP_HOOK:-}" ENV="${VPSCTL_TEST_STARTUP_HOOK:-}"
}
EOF
    output="$(VPSCTL_TEST_STARTUP_HOOK="$sandbox/startup-hook" bash "$sandbox/bin/vpsctl" network bbr status)"
    test_contains "$output" 'bbr_args=status' 'child runs with startup hooks removed'
    [[ ! -e "$marker" ]] || test_fail 'child executed BASH_ENV or ENV startup hook'

    status=0
    output="$(VPSCTL_DOWNLOAD_MARKER="$download_marker" bash "$sandbox/bin/vpsctl" system missing 2>&1)" || status=$?
    [[ "$status" == 2 && ! -e "$download_marker" ]] || test_fail 'unknown command was loaded or did not return 2'
    test_contains "$output" '未知命令' 'unknown command diagnostic'
    status=0
    output="$(VPSCTL_FIXTURE_KERNEL=Darwin VPSCTL_DOWNLOAD_MARKER="$download_marker" VPSCTL_DISPATCH_MARKER="$marker" bash "$sandbox/bin/vpsctl" network bbr --help 2>&1)" || status=$?
    [[ "$status" == 3 ]] || test_fail "non-Linux dispatch should return 3: $status $output"
    test_contains "$output" 'linux' 'Linux requirement diagnostic'
    [[ ! -e "$marker" && ! -e "$download_marker" ]] || test_fail 'non-Linux dispatch loaded or executed a bundle'

    # The same transport now runs real feature entrypoints. Only environment
    # detection and distribution are fixtures; business guards remain real.
    cp -a "$TEST_ROOT/commands/." "$sandbox/commands/"
    mkdir -p "$sandbox/system" "$sandbox/tools"
    feature_env=(env VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT="$sandbox/system" VPSCTL_NO_COLOR=1
        VPSCTL_NON_INTERACTIVE=1 VPSCTL_ENV_OS_ID=fixture VPSCTL_ENV_LIBC=musl
        VPSCTL_ENV_INIT=none VPSCTL_ENV_PACKAGE_MANAGER=unknown VPSCTL_ENV_ARCH=x86_64
        VPSCTL_ENV_VIRTUALIZATION=unknown)

    assert_feature_result() {
        local wanted_status="$1" wanted_output="$2" domain="$3" action="$4"
        shift 4
        status=0
        output="$("${reader[@]}" "${feature_env[@]}" bash "$sandbox/bin/vpsctl" "${manager_options[@]}" "$domain" "$action" "$@" 2>&1)" || status=$?
        direct_status=0
        direct="$("${reader[@]}" "${feature_env[@]}" bash "$sandbox/commands/$domain/$action.sh" "$@" 2>&1)" || direct_status=$?
        [[ "$status" == "$wanted_status" ]] || test_fail "$domain $action $*: expected $wanted_status, got $status: $output"
        [[ "$status" == "$direct_status" && "$output" == "$direct" ]] || test_fail "$domain $action $*: manager/direct differ (rc=$status/$direct_status): $output / $direct"
        test_contains "$output" "$wanted_output" "$domain $action real entrypoint"
        printf 'PASS: manager/direct %s %s (rc=%s, %s)\n' "$domain" "$action $*" "$status" "$wanted_output"
    }

    assert_feature_result 3 'glibc' network ip-policy status
    assert_feature_result 3 'Debian/Ubuntu' system kernel install --type official
    assert_feature_result 3 'systemd' security fail2ban install
    assert_feature_result 3 'systemd 或 OpenRC' service iperf3 start
    assert_feature_result 3 'systemd 或 OpenRC' service tcping start
    assert_feature_result 3 'systemd' network rfw install
    assert_feature_result 3 'systemd 或 OpenRC' service proxy install --core sing-box
    assert_feature_result 2 '未知' service iperf3 status --unknown
    assert_feature_result 2 '不接受参数' test tcpquality help extra

    cat >"$sandbox/tools/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$VPSCTL_SYSTEMCTL_MARKER"
exit 99
EOF
    chmod 0755 "$sandbox/tools/systemctl"
    feature_env+=(PATH="$sandbox/tools:$PATH" VPSCTL_SYSTEMCTL_MARKER="$sandbox/systemctl-called")
    for feature in none openrc; do
        feature_env+=(VPSCTL_FIXTURE_INIT="$feature" VPSCTL_ENV_INIT="$feature")
        assert_feature_result 0 "\"platform\": \"$feature\"" security access status --json
        test_contains "$output" '"service": "unknown"' 'non-systemd SSH service is unknown'
        test_contains "$output" '"service_state": "unknown"' 'non-systemd SSH service state is unknown'
        [[ ! -e "$sandbox/systemctl-called" ]] || test_fail 'Access non-systemd status invoked systemctl'
        assert_feature_result 0 'SSH 服务' security access status
        expected="$output"
        assert_feature_result 0 'SSH 服务' security access
        [[ "$output" == "$expected" ]] || test_fail 'noninteractive Access default differs from status'
        assert_feature_result 0 '用法' security access --help
        assert_feature_result 2 '未知' security access status --unknown
        assert_feature_result 3 'Debian/Ubuntu' security access ssh prepare --port 2222 --firewall manual
        assert_feature_result 3 'Debian/Ubuntu' security access session verify --transaction tx-test
        [[ ! -e "$sandbox/systemctl-called" ]] || test_fail 'Access unsupported platform invoked systemctl'
    done
    # A supported OS still requires systemd for writes, and unsupported OS
    # status remains readable while its writes keep the OS-family guard.
    feature_env+=(VPSCTL_FIXTURE_OS=ubuntu VPSCTL_ENV_OS_ID=ubuntu)
    assert_feature_result 3 'systemd' security access ssh prepare --port 2222 --firewall manual
    assert_feature_result 3 'systemd' security access session verify --transaction tx-test
    if command -v script >/dev/null 2>&1; then
        # With a TTY, an absent Access action still enters the strict menu gate.
        feature_env+=(VPSCTL_NON_INTERACTIVE=0)
        printf -v menu_command '%q ' "${feature_env[@]}" bash "$sandbox/bin/vpsctl" --no-color security access
        status=0
        output="$(printf 'q\n' | script -q -e -f -c "$menu_command" /dev/null 2>&1)" || status=$?
        [[ "$status" == 3 ]] || test_fail "Access TTY menu without systemd should return 3: $status $output"
        test_contains "$output" 'systemd' 'real Access menu platform gate'
        feature_env+=(VPSCTL_NON_INTERACTIVE=1)
    else
        printf 'SKIP: Access TTY menu test requires script\n'
    fi
    feature_env+=(VPSCTL_FIXTURE_OS=fixture VPSCTL_ENV_OS_ID=fixture VPSCTL_FIXTURE_INIT=systemd VPSCTL_ENV_INIT=systemd)
    assert_feature_result 3 'Debian/Ubuntu' security access ssh prepare --port 2222 --firewall manual

    # Root is tested with an actual unprivileged process, not capability flags.
    feature_env=(env VPSCTL_TESTING=0 VPSCTL_NO_COLOR=1 VPSCTL_NON_INTERACTIVE=0)
    manager_options=(--no-color)
    if ((EUID == 0)); then
        command -v setpriv >/dev/null 2>&1 || test_fail 'real non-root dispatch test requires setpriv'
        chmod 0755 "$sandbox"
        reader=(setpriv --reuid=65534 --regid=65534 --clear-groups)
    fi
    assert_feature_result 4 'root' test nodequality
    assert_feature_result 2 '不接受参数' test tcpquality help extra
    manager_options=(--no-color --non-interactive)
    feature_env=(env VPSCTL_TESTING=0 VPSCTL_NO_COLOR=1
        VPSCTL_NON_INTERACTIVE=1 VPSCTL_ENV_OS_ID=ubuntu VPSCTL_FIXTURE_OS=ubuntu
        VPSCTL_ENV_INIT=none VPSCTL_FIXTURE_INIT=none)
    assert_feature_result 0 '"platform": "none"' security access status --json
    test_contains "$output" '"service_state": "unknown"' 'actual non-root Access status'
    reader=()

    rm -f -- "$marker"
    mkdir -p "$sandbox/outside"
    printf 'touch %q\n' "$marker" >"$sandbox/outside/bbr.sh"
    rm -- "$sandbox/commands/network/bbr.sh"
    ln -s ../../outside/bbr.sh "$sandbox/commands/network/bbr.sh"
    status=0
    bash "$sandbox/bin/vpsctl" network bbr status >/dev/null 2>&1 || status=$?
    [[ "$status" == 3 && ! -e "$marker" ]] || test_fail 'symlinked command file was not safely rejected'
    rm -rf -- "$sandbox/commands/network"
    mkdir -p "$sandbox/outside"
    cat >"$sandbox/outside/bbr.sh" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
    ln -s ../outside "$sandbox/commands/network"
    status=0
    bash "$sandbox/bin/vpsctl" network bbr status >/dev/null 2>&1 || status=$?
    [[ "$status" == "3" ]] || test_fail "symlinked command ancestor should return 3, got ${status}"
    [[ ! -e "$marker" ]] || test_fail "symlinked command ancestor was executed"
)

test_menu_self_lifecycle() (
    [[ "$(uname -s)" == Linux ]] || return 0
    command -v script >/dev/null 2>&1 || { printf 'SKIP: self menu tests require script\n'; return 0; }
    local sandbox install template scenario command output status expected action input domain_index index
    local self_index status_index update_index uninstall_index
    sandbox="$(mktemp -d)"
    trap 'rm -rf -- "$sandbox"' EXIT
    install="$sandbox/install"
    template="$sandbox/template"
    mkdir -p "$template/bin" "$template/lib" "$template/commands/self"
    cp "$TEST_ROOT/bin/vpsctl" "$template/bin/vpsctl"
    cp "$TEST_ROOT"/lib/*.sh "$template/lib/"
    cp "$TEST_ROOT/VERSION" "$template/VERSION"
    cat >>"$template/lib/distribution.sh" <<'EOF'

# Exercise the real menu and dispatch with lifecycle operations isolated to
# this fixture. Bundle activation itself has separate distribution coverage.
vps_distribution_ensure_command() { return 0; }
EOF
    cat >"$template/commands/self/status.sh" <<'EOF'
printf 'menu-status:%s color=%s clear=%s\n' "${VPSCTL_PROJECT_ROOT##*/}" "$VPSCTL_NO_COLOR" "$VPSCTL_CLEAR"
EOF
    cat >"$template/commands/self/update.sh" <<'EOF'
set -Eeuo pipefail
case "$VPSCTL_MENU_CASE" in
    update | partial-new | invalid-entry)
        ln -sfn -- "$VPSCTL_INSTALL_ROOT/releases/new" "$VPSCTL_INSTALL_ROOT/current"
        rm -rf -- "$VPSCTL_INSTALL_ROOT/releases/old"
        if [[ "$VPSCTL_MENU_CASE" == invalid-entry ]]; then
            printf '#!/nonexistent/vpsctl-menu-interpreter\n' >"$VPSCTL_MANAGED_ENTRY"
        fi
        [[ "$VPSCTL_MENU_CASE" != partial-new ]] || exit 30
        ;;
    fail) exit 20 ;;
    partial-old) exit 30 ;;
    no-entry) rm -- "$VPSCTL_MANAGED_ENTRY" ;;
    uninstall) rm -- "$VPSCTL_MANAGED_ENTRY" "$VPSCTL_INSTALL_ROOT/current" ;;
    partial-uninstall) rm -- "$VPSCTL_MANAGED_ENTRY"; exit 20 ;;
    same | cancel-update | cancel-uninstall) ;;
    *) exit 99 ;;
esac
EOF
    cp "$template/commands/self/update.sh" "$template/commands/self/uninstall.sh"

    # shellcheck source=../../lib/registry.sh
    source "$TEST_ROOT/lib/registry.sh"
    vps_registry_init
    for domain_index in "${!VPS_DOMAIN_IDS[@]}"; do
        [[ "${VPS_DOMAIN_IDS[$domain_index]}" != self ]] || self_index=$((domain_index + 1))
    done
    vps_registry_commands_for_domain self
    for index in "${!VPS_REGISTRY_RESULTS[@]}"; do
        case "${VPS_REGISTRY_RESULTS[$index]}" in
            self:status) status_index=$((index + 1)) ;;
            self:update) update_index=$((index + 1)) ;;
            self:uninstall) uninstall_index=$((index + 1)) ;;
        esac
    done

    for scenario in update same cancel-update fail partial-old partial-new no-entry invalid-entry uninstall cancel-uninstall partial-uninstall; do
        rm -rf -- "$install"
        mkdir -p "$install/releases"
        cp -a -- "$template" "$install/releases/old"
        cp -a -- "$template" "$install/releases/new"
        ln -s -- "$install/releases/old" "$install/current"
        cat >"$install/entry" <<'EOF'
#!/usr/bin/env bash
exec bash "$VPSCTL_INSTALL_ROOT/current/bin/vpsctl" "$@"
EOF
        chmod 0755 "$install/entry"
        action="$update_index"
        expected=0
        case "$scenario" in
            uninstall | cancel-uninstall | partial-uninstall) action="$uninstall_index" ;;
        esac
        case "$scenario" in
            partial-old | partial-new) expected=30 ;;
            no-entry | invalid-entry | partial-uninstall) expected=20 ;;
        esac
        if [[ "$scenario" == update ]]; then
            printf -v input '%s\n%s\n%s\n%s\n\nq\n' "$self_index" "$action" "$self_index" "$status_index"
        else
            printf -v input '%s\n%s\n\n%s\n\nq\n' "$self_index" "$action" "$status_index"
        fi
        printf -v command 'env VPSCTL_DISTRIBUTED=1 VPSCTL_INSTALL_ROOT=%q VPSCTL_MANAGED_ENTRY=%q VPSCTL_MENU_CASE=%q TERM=xterm bash %q --no-color --no-clear menu' \
            "$install" "$install/entry" "$scenario" "$install/releases/old/bin/vpsctl"
        status=0
        output="$(printf '%s' "$input" | script -q -e -f -c "$command" /dev/null 2>&1)" || status=$?
        [[ "$status" == "$expected" ]] || test_fail "self menu $scenario: expected $expected, got $status: $output"
        test_no_ansi "$output" "self menu $scenario display options"
        case "$scenario" in
            update)
                test_contains "$output" 'menu-status:new color=1 clear=0' 'updated menu dispatch and display options'
                test_not_contains "$output" 'menu-status:old' 'old menu must not resume after update'
                [[ ! -e "$install/releases/old" ]] || test_fail 'update fixture retained old release'
                ;;
            same | cancel-update | fail | cancel-uninstall)
                test_contains "$output" 'menu-status:old color=1 clear=0' "self menu $scenario continuation"
                test_not_contains "$output" '正在进入新版本主菜单' "self menu $scenario should not restart"
                ;;
            *) test_not_contains "$output" 'menu-status:' "self menu $scenario must exit before another command" ;;
        esac
        if [[ "$scenario" == invalid-entry ]]; then
            test_contains "$output" '无法启动更新后的受管入口' 'new entry execution failure'
        fi
    done
)

if [[ "${VPSCTL_TEST_ONLY:-}" == dispatch ]]; then
    test_dispatch_security
    printf 'PASS: vpsctl dispatch tests\n'
    exit 0
fi

if [[ "${VPSCTL_TEST_ONLY:-}" == entry-version ]]; then
    test_entry_version
    printf 'PASS: vpsctl entry version tests\n'
    exit 0
fi

test_cli
test_entry_version
test_dispatch_security
test_menu_self_lifecycle
printf 'PASS: vpsctl integration tests\n'
