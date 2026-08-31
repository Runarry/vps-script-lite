# Fail2ban 管理

`security fail2ban` 安装 Fail2ban，并只管理 OpenSSH 的 `sshd` jail。它不会修改发行版提供的 `jail.conf`、过滤器或动作文件，也不会接管 Nginx、Apache、邮件等其他 jail。受管配置通过 `/etc/fail2ban/jail.d/99-vpsctl-sshd.local` 覆盖必要字段；卸载该功能后，用户原有配置会重新成为有效配置。

本功能处于 `experimental` 生命周期，支持 Bash 4.4+、systemd、OpenSSH Server 和发行版提供的 Fail2ban 0.11+。软件包安装支持 `apt-get`、`dnf5`、`dnf`、`yum`、`pacman` 和 `zypper`；不会自动添加 EPEL 或其他软件源，不支持 apk/OpenRC。

## 接口

```text
vpsctl security fail2ban status [--json]
vpsctl security fail2ban install [--ignore-ip IP_OR_CIDR ...]
    [--ignore-current-session] [--adopt-existing]
vpsctl security fail2ban configure
    [--bantime TIME] [--findtime TIME] [--maxretry 1..100]
    [--increment on|off] [--max-bantime TIME]
vpsctl security fail2ban sync-ssh-port
vpsctl security fail2ban ignore list
vpsctl security fail2ban ignore add|remove --ip IP_OR_CIDR
vpsctl security fail2ban unban --ip IP
vpsctl security fail2ban verify
vpsctl security fail2ban start|stop|restart
vpsctl security fail2ban logs [--lines N]
vpsctl security fail2ban restore --backup ID --confirm-restore ID
vpsctl security fail2ban uninstall --confirm-uninstall REMOVE-VPSCTL-FAIL2BAN
```

无参数且连接交互终端时进入编号菜单；无参数非交互调用等同于人类可读的 `status`。菜单执行真实动作，不提供 dry-run 或机器格式开关。

`status`、帮助和 `ignore list` 允许普通用户执行，`logs` 沿用 journal 自身权限；受 Fail2ban socket、journal 或状态目录权限限制的字段会显示为未知或返回权限错误。所有变更动作需要 root。`status --json` 的顶层包含 `schema_version: 1`，并报告软件版本、init/systemd 状态、配置所有权与漂移、当前和受管 SSH 端口、jail 状态、阈值、封禁动作、忽略列表和封禁计数。

## 默认策略与白名单

首次安装写入以下 `sshd` jail 策略：

- 10 分钟内失败 5 次触发封禁。
- 首次封禁 1 小时；重复攻击递增，最长 1 周。
- 使用 `usedns = no`，避免根据日志中的主机名进行反向解析。
- 忽略 `127.0.0.1/8` 和 `::1`；这些回环范围不能删除。
- 从有效的 `sshd -T` 输出同步全部 SSH 监听端口。

`install` 在交互 SSH 会话中显示 `SSH_CONNECTION` 的来源 IP，并询问是否按单地址加入白名单；不会静默永久放行。直接 CLI 必须通过可重复的 `--ignore-ip` 或 `--ignore-current-session` 明确加入。白名单只接受 IPv4、IPv6 或 CIDR，不接受域名、文件和命令。

`configure` 只更新明确给出的阈值，其他受管值保持不变。时间必须是 Fail2ban 可解析的正时长，`maxretry` 限制为 1 到 100；启用递增时最大封禁时间不能短于首次封禁时间。

## 软件包、防火墙与 SSH 端口

`install` 本身就是安装 Fail2ban 的明确授权，不需要额外提供 `--install-deps`。apt 系安装 Fail2ban 和 systemd Python 支持；RPM 系安装 Fail2ban 及 systemd 支持；pacman/zypper 使用发行版包。软件源缺少所需包时操作失败并保留诊断，不修改软件源配置。

封禁动作按当前能力选择：活动 firewalld 使用 `firewallcmd-rich-rules`，活动 UFW 使用 `ufw`，否则优先使用 nftables，再回退到 `iptables-multiport`。同时检测到 UFW 和 firewalld 时拒绝自动配置。日志 backend 不在受管文件中硬编码，继续使用发行版的 `%(sshd_backend)s`。

`security access` 修改 SSH 端口后不会跨功能改写 Fail2ban。`status` 会比较 `sshd -T` 与受管端口；发现漂移时使用 `sync-ssh-port`。同步仍经过完整的备份、配置测试、reload 和回滚流程。

## 配置所有权与恢复

实时状态保存在 `/var/lib/vpsctl/security/fail2ban/`，历史备份保存在 `/var/lib/vpsctl/backups/security/fail2ban/`。状态记录受管参数、配置哈希和 schema。若受管文件被手工修改或替换为符号链接，写操作会拒绝覆盖。

如果安装前已有非 vpsctl 的 `sshd` jail，默认停止并报告冲突。交互模式必须明确同意，直接 CLI 必须提供 `--adopt-existing`；接管只创建 vpsctl 的高优先级覆盖文件，不修改或删除原文件。

配置事务顺序为：获取锁、保存带校验信息的备份、原子写入、运行 `fail2ban-client -t`、启动或 reload 服务、执行 `ping` 和 `status sshd`。失败时恢复配置和先前运行状态；回滚也失败则返回部分完成状态并输出备份 ID。`restore` 只接受本功能备份目录内校验通过的 ID，确认值必须与备份 ID 完全一致。

`verify` 选择一个未被封禁的 TEST-NET 地址执行临时 ban/unban，以验证实际动作能够运行；退出和可捕获信号都会尝试解封。`unban` 只接受单个规范 IP。

`uninstall` 需要固定强确认词，只删除带 vpsctl 标记且哈希匹配的受管 jail，随后验证并 reload。它保留 Fail2ban 软件包、服务启用/运行状态、用户配置、运行数据库和历史备份。

## 验收

所有语法、单元、集成和真实功能验证只能通过 `ssh host-vps-scripts` 在专用环境执行。除参数、dry-run、幂等、漂移和回滚测试外，真实验收还应从临时 network namespace 的独立源地址制造认证失败，确认达到阈值后被封禁、连接被防火墙拒绝、手工解封恢复，并在退出时清除临时网络与测试封禁。
