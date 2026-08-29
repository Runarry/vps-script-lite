# shellcheck shell=bash

access_user_admin_group() {
    case "${VPSCTL_ENV_OS_ID:-}" in
        debian | ubuntu) printf 'sudo\n' ;;
        *) printf 'wheel\n' ;;
    esac
}

access_user_has_admin_access() {
    local user="$1" admin_group

    admin_group="$(access_user_admin_group)" || return $?
    id -nG -- "$user" 2>/dev/null | tr ' ' '\n' | grep -Fqx "$admin_group" || return 1
    command -v sudo >/dev/null 2>&1 || return 1
    sudo -l -U "$user" >/dev/null 2>&1
}

access_user_add() {
    local user="$1" set_password="$2" admin_group manager created=0

    vps_cmd_require_root || return $?
    access_validate_user_name "$user" || {
        vps_cmd_error "无效的用户名：${user:-<空>}"
        return 2
    }
    [[ "$user" != root ]] || {
        vps_cmd_error "不能创建保留用户 root"
        return 2
    }
    if getent passwd "$user" >/dev/null 2>&1; then
        vps_cmd_error "用户已存在：$user"
        return 3
    fi
    command -v useradd >/dev/null 2>&1 || {
        vps_cmd_error "未找到 useradd；当前平台不支持安全创建登录用户"
        return 3
    }
    admin_group="$(access_user_admin_group)" || return $?
    getent group "$admin_group" >/dev/null 2>&1 || {
        vps_cmd_error "系统管理员组不存在：$admin_group"
        return 3
    }
    if ! command -v sudo >/dev/null 2>&1; then
        if [[ "${VPSCTL_INSTALL_DEPS:-0}" != 1 ]]; then
            if vps_cmd_is_interactive; then
                vps_cmd_confirm "缺少 sudo，是否安装固定软件包 sudo？" || return 3
            else
                vps_cmd_error "缺少 sudo；请先安装，或添加 --install-deps 明确授权安装"
                return 3
            fi
        fi
        manager="$(vps_cmd_detect_package_manager)" || return $?
        vps_cmd_install_packages "$manager" sudo || return $?
        [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]] && {
            vps_cmd_info "演练：依赖安装完成后将创建管理员用户 $user"
            return 0
        }
        command -v sudo >/dev/null 2>&1 || return 20
    fi
    if ! vps_cmd_run useradd --create-home --user-group --groups "$admin_group" --shell /bin/bash -- "$user"; then
        if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] && getent passwd "$user" >/dev/null 2>&1; then
            userdel --remove -- "$user" >/dev/null 2>&1 || {
                vps_cmd_error "useradd 失败后检测到残留账户 $user，且自动回滚失败"
                return 30
            }
        fi
        return 20
    fi
    created=1
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] && ! id -nG -- "$user" | tr ' ' '\n' | grep -Fqx "$admin_group"; then
        userdel --remove -- "$user" >/dev/null 2>&1 || true
        vps_cmd_error "用户创建后未获得 $admin_group 管理员组，已尝试回滚"
        return 20
    fi
    if [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] && ! access_user_has_admin_access "$user"; then
        userdel --remove -- "$user" >/dev/null 2>&1 || true
        vps_cmd_error "sudo 策略未确认 $user 的管理员授权，已尝试回滚"
        return 20
    fi
    vps_cmd_success "已创建管理员用户 $user（同名主组、$admin_group、主目录、/bin/bash）"
    if [[ "$set_password" == 1 ]]; then
        if [[ "${VPSCTL_DRY_RUN:-0}" == 1 ]]; then
            vps_cmd_info "演练：用户创建后将通过系统 passwd 为 $user 设置密码"
            return 0
        fi
        if access_password_set "$user"; then
            :
        else
            if [[ "${VPSCTL_DRY_RUN:-0}" != 1 && "$created" == 1 ]]; then
                userdel --remove -- "$user" >/dev/null 2>&1 || {
                    vps_cmd_error "密码设置失败，且无法完整删除新用户 $user"
                    return 30
                }
            fi
            vps_cmd_warning "密码设置失败；已回滚本次新用户创建"
            return 20
        fi
    fi
}

access_password_set() {
    local user="$1"

    vps_cmd_require_root || return $?
    access_require_login_user "$user" || return $?
    command -v passwd >/dev/null 2>&1 || {
        vps_cmd_error "未找到系统 passwd"
        return 3
    }
    [[ "${VPSCTL_DRY_RUN:-0}" != 1 ]] || {
        vps_cmd_info "演练：将调用系统 passwd 为 $user 设置密码"
        return 0
    }
    [[ -t 0 && -t 1 ]] || {
        vps_cmd_error "password set 必须在 TTY 中由系统 passwd 安全读取密码"
        return 3
    }
    passwd -- "$user" || return 20
    vps_cmd_success "已由系统 passwd 更新 $user 的密码"
}
