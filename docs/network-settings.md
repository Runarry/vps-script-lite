# 网络设置

0.2.0 在固定的 `network` 领域提供 BBR、DNS 和 RFW 三个入口。本文记录公开命令接口、风险边界、落盘位置、失败语义和发布验收要求；它不声称这些操作已经在真实 VPS 或 VM 上完成验证。

## 1. 入口与公共约定

| 入口 | 子动作 | 风险 | 权限 | 演练 | 能力要求 | 生命周期 |
| --- | --- | --- | --- | --- | --- | --- |
| `network bbr` | `status`、`enable`、`set`、`restore` | `change` | `optional-root` | 支持 | `linux` | `experimental` |
| `network dns` | `show`、`test`、`set`、`refresh`、`verify`、`restore` | `disruptive` | `optional-root` | 支持 | `linux` | `experimental` |
| `network rfw` | `status`、`install`、`update`、`configure`、`start`、`stop`、`restart`、`stats`、`logs`、`uninstall` | `disruptive` | `optional-root` | 支持 | `linux`、`init:systemd` | `experimental` |

全局选项必须位于领域前，例如：

```text
bash bin/vpsctl --dry-run --install-deps network dns set --server 1.1.1.1
```

三项功能的公共约定如下：

- `--install-deps` 明确允许按当前动作安装缺失的系统工具；未提供时只报告缺失项。它支持 `apt-get`、`dnf5`、`dnf`、`yum`、`apk`、`pacman` 与 `zypper`，但不安装或绕过内核、init 系统、CPU 架构、XDP/BPF 等平台能力。
- `--dry-run` 展示检测结果和计划，不写系统、不安装依赖、不改变服务状态。与 `--install-deps` 组合时会展示包管理器命令；DNS 可继续展示后续计划，BBR 和 RFW 在缺失工具妨碍安全验证时会提示安装后重跑。
- `--yes` 只跳过允许自动同意的普通提示，不绕过能力检查、写前验证或 RFW 的中断性操作强确认。
- `--non-interactive` 禁止读取终端；缺少必要参数或必要的强确认时立即失败。
- 修改操作分别使用 `/run/vpsctl/network-bbr.lock`、`/run/vpsctl/network-dns.lock` 和 `/run/vpsctl/network-rfw.lock`，阻止同一功能的并发事务互相覆盖。
- 普通用户可运行帮助和可读取的状态查询；写 `/etc`、`/usr/local`、systemd 单元或持久状态时需要 root。

## 2. BBR

### 2.1 子动作和选项

| 子动作 | 用途 | 主要选项 |
| --- | --- | --- |
| `status` | 显示可用算法、当前拥塞控制、队列规则和持久化状态 | 无变更选项 |
| `enable` | 以 BBR 和 `fq` 为默认值启用并持久化 | `--algorithm ALG`、`--qdisc QDISC`、`--apply-live-qdisc` |
| `set` | 显式设置并持久化指定算法和队列规则 | `--algorithm ALG`、`--qdisc QDISC`、`--apply-live-qdisc` |
| `restore` | 使用保存的原始状态恢复项目管理的配置 | 无变更选项 |

示例：

```text
bash bin/vpsctl --dry-run --install-deps network bbr enable
bash bin/vpsctl network bbr set --algorithm bbr --qdisc fq
bash bin/vpsctl network bbr restore
```

命令只使用当前内核已经提供的拥塞控制能力，不下载、升级或替换内核。`enable` 默认选择 `bbr`/`fq`；指定算法和队列规则前必须验证其可用性。算法与默认 qdisc 会同时写入运行时 sysctl 和持久化片段；只有 `--apply-live-qdisc` 才会进一步替换当前默认网卡的 root qdisc，因此计划和确认信息必须单独标明该影响。

BBR 会按动作检查并在获授权后安装 `sysctl`、`modprobe`、`ip`、`tc`、`base64` 和实际事务锁所需的 `flock`。这只补齐用户空间工具；当前内核未提供目标拥塞控制算法时仍安全失败，不会尝试升级或替换内核。

### 2.2 配置、状态与恢复

| 路径 | 用途 |
| --- | --- |
| `/etc/sysctl.d/90-vpsctl-bbr.conf` | 项目管理的拥塞控制和默认队列规则 sysctl 配置 |
| `/etc/modules-load.d/90-vpsctl-bbr.conf` | 需要时持久化加载 BBR 模块 |
| `/var/lib/vpsctl/network/bbr/original.conf` | 首次变更前保存的原始值和恢复依据 |
| `/var/lib/vpsctl/backups/network/bbr/` | 覆盖同名非受管片段前保存的文件备份 |

写入采用临时文件、校验和原子替换。`restore` 只使用受信任的状态记录，并移除或恢复项目管理的片段；状态缺失、格式无效或当前文件不再属于项目时必须安全拒绝，不凭猜测覆盖管理员后续修改。部分写入或恢复失败返回 `30`，同时指出仍生效的值和需要人工检查的上述路径。

## 3. DNS

### 3.1 子动作和选项

| 子动作 | 用途 | 主要选项 |
| --- | --- | --- |
| `show` | 显示当前权威后端、解析器和项目状态 | 无变更选项 |
| `test` | 在不改系统配置的情况下前测候选解析器 | 可重复 `--server IP`、`--test-domain DOMAIN`、`--install-deps` |
| `set` | 前测通过后写入检测到的权威后端 | 可重复 `--server IP`、`--test-domain DOMAIN`、`--install-deps` |
| `refresh` | 请求当前权威后端重新加载其已有配置 | 无服务器参数 |
| `verify` | 使用当前配置验证解析器和系统解析链路 | 无选项 |
| `restore` | 从项目备份恢复权威后端配置 | `--backup PATH/ID` |

`--server` 只接受有效 IPv4 或 IPv6 地址，可重复传入以保持明确顺序；它不接受未经约束的主机名或任意配置片段。全局 `--install-deps` 或 `test`/`set` 动作后的同名选项都是对缺失 `dig`、`drill`、`nslookup` 探测工具的显式授权；`set`/`restore` 的真实事务还会按需补齐 `flock`。未提供授权时不得静默安装软件。

### 3.2 四种后端

命令先判定谁对系统 DNS 配置拥有权威，再只操作该后端：

| 后端 | 管理目标与边界 |
| --- | --- |
| `systemd-resolved` | 使用项目专属的 resolved drop-in，并通过 resolved 重新加载；不直接覆盖其生成的 `/etc/resolv.conf` |
| `NetworkManager` | 通过 `nmcli` 更新活动连接的 DNS 属性；连接配置文件仍由 NetworkManager 管理 |
| `openresolv` | 更新 `/etc/resolvconf.conf` 并由 openresolv 生成结果；不把生成的 `/etc/resolv.conf` 当作静态文件覆盖 |
| 静态 `resolv.conf` | 仅在确认没有其他管理器拥有该文件时原子替换 `/etc/resolv.conf` |

旧版 Debian 的 legacy `resolvconf` 布局不具备足够一致的安全恢复语义，因此命令必须明确拒绝变更并返回前置条件错误；不得退化为直接覆盖 `/etc/resolv.conf`。用户应先迁移到受支持的 DNS 管理后端，再重新执行。

后端行为以 [NetworkManager 设置契约](https://www.networkmanager.dev/docs/api/latest/nm-settings-nmcli.html)、[systemd-resolved 接口](https://www.freedesktop.org/software/systemd/man/org.freedesktop.resolve1.html)、[openresolv 配置说明](https://manpages.debian.org/bookworm/openresolv/resolvconf.conf.5.en.html)和 [Debian resolvconf](https://manpages.debian.org/unstable/resolvconf/resolvconf.8.en.html)为依据。

各后端实际管理的原文件和元数据在变更前备份到 `/var/lib/vpsctl/backups/network/dns/`。备份标识和路径会显示在正常输出中，可传给 `restore --backup PATH/ID`；恢复时必须验证路径属于允许的备份范围、后端匹配且内容格式有效。

### 3.3 写前、写后与失败语义

`set` 在任何写入前先验证服务器地址、依赖和后端，再使用 `test` 同等的探测逻辑对候选解析器执行实际 DNS 查询。任一必要前测失败时不修改系统。

写入和后端重新加载完成后，命令从系统解析链路再次查询 `--test-domain`。写后验证失败属于部分完成：保留已经写入的新配置，不自动回滚，返回 `30`，输出备份标识、当前后端和明确的 `restore` 命令。这样既保留现场供诊断，也避免未经确认的第二次网络变更掩盖原始失败。

## 4. RFW

### 4.1 支持边界

RFW 入口仅支持以下组合：

- systemd 服务管理器。
- `x86_64` 或 `aarch64` CPU 架构。
- Linux 5.15 或更新内核，并具备所选网卡所需的 XDP 能力；启用访问日志时还需可用的 BPF 文件系统。
- IPv4 规则；它不修改 IPv6 规则，也不代表主机已获得 IPv6 防护。

`install` 和 `update` 只从 [narwhal-cloud/rfw 官方 Releases](https://github.com/narwhal-cloud/rfw/releases)解析最新稳定 release，拒绝 prerelease、草稿、非 HTTPS 下载和无法匹配本机架构的资产。下载的二进制必须按官方 checksum 验证并核对版本后才能替换；校验信息缺失、不匹配或含糊时安全失败，不安装未验证资产。

RFW 会在参数校验以及 Linux、systemd、架构和内核版本门禁通过后，按动作补齐 `curl`、`sha256sum`、`flock`、`ip`，以及启用端口日志时所需的 `mountpoint`。`systemctl`、`journalctl`、XDP、BPF 文件系统和 RFW 二进制能力仍按平台或功能前置条件处理，不作为通用软件包自动安装。

### 4.2 子动作和选项

| 子动作 | 用途 | 主要选项 |
| --- | --- | --- |
| `status` | 显示安装版本、配置摘要和 systemd 状态 | 无变更选项 |
| `install` | 安装官方最新稳定 release、配置和 systemd 单元 | `--force` 允许覆盖检测到的既有安装；不自动应用危险规则 |
| `update` | 校验并替换为官方最新稳定 release | `--force` 允许强制重新安装；更新后延后重启 |
| `configure` | 校验并写入 RFW 配置 | `--iface`、`--geo-mode none\|blocklist\|whitelist`、`--countries CSV`、`--block-email on\|off`、`--block-http on\|off`、`--block-socks5 on\|off`、`--block-wireguard on\|off`、`--block-quic on\|off`、`--block-all on\|off`、`--fet off\|loose\|strict`、`--xdp-mode auto\|skb\|drv\|hw`、`--log-port-access on\|off`、`--rust-log LEVEL` |
| `start` | 启动服务 | `--enable`、危险配置时 `--confirm-disruptive` |
| `stop` | 停止服务 | `--disable` |
| `restart` | 显式应用当前二进制和配置 | 危险配置时 `--confirm-disruptive` |
| `stats` | 查询统计 | `--port`、`--ip`、`--blocked-only`、`--allowed-only`、`--group-by-port` |
| `logs` | 查询 journal 日志 | `--lines`、`--follow`、`--since` |
| `uninstall` | 停止并移除项目安装的组件 | `--purge` 同时移除项目配置、状态和 RFW 备份；非交互清除还需 `--confirm-purge` |

`configure` 的规则开关均使用明确的 `on` 或 `off`，不得用是否出现参数来表达含糊的继承状态。`--countries CSV` 必须与地理模式一致，并在写入前规范化和校验国家代码。

首次安装生成的配置将所有过滤规则、FET 和访问日志设为 `off`，不会自动启动服务；至少显式配置一项过滤规则或访问日志后才能启动。上游的 `--block-email` 针对 SMTP 发送流量，其他协议开关和 `--block-all` 针对相应的 IPv4 入站流量。

### 4.3 延后重启与强确认

`configure` 和 `update` 写入成功后不自动启动或重启 RFW；输出明确标记“已暂存、尚未应用”，让现有 SSH 会话保持在可控状态。服务停止时可用 `start` 应用暂存内容；服务已运行且存在暂存内容时必须用 `restart`，避免把一次无操作的 `start` 误判为已应用。

当应用可能封禁管理地址或中断 SSH 的配置时，交互模式必须要求用户输入完整确认短语 `APPLY-RFW`。`--yes` 不能代替该短语；非交互模式必须显式提供 `--confirm-disruptive`，否则拒绝执行。强确认只确认已展示的当前计划，计划发生变化后必须重新确认。

### 4.4 配置、状态与恢复

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/rfw` | 校验后安装的 RFW 二进制 |
| `/etc/vpsctl/rfw.conf` | 项目管理的 RFW 配置 |
| `/etc/systemd/system/rfw.service` | 项目管理的 systemd 单元 |
| `/var/lib/vpsctl/network/rfw/` | 安装元数据、版本/checksum 记录及恢复所需状态 |
| `/var/lib/vpsctl/backups/network/rfw/` | 更新、配置和失败恢复使用的上一版本备份 |

替换二进制、配置和单元前必须保留可识别的上一版本状态。安装、更新或卸载发生部分完成时返回 `30`，输出当前二进制版本、服务是否仍运行、哪些路径已改变，以及恢复上一文件或重新安装校验过版本的步骤。`uninstall` 默认保留配置和恢复状态；只有显式 `--purge` 才删除项目管理的数据，而且不得删除范围外文件。清除操作在交互模式要求输入 `PURGE-RFW`，在非交互模式要求额外提供无值标志 `--confirm-purge`；`--yes` 同样不能替代这一确认。

## 5. 退出码

三个入口遵守统一退出码：

| 退出码 | 含义与网络命令示例 |
| ---: | --- |
| `0` | 成功，或目标状态已经满足 |
| `2` | 子动作、参数、组合或确认用法错误 |
| `3` | 内核/后端/systemd/架构不支持，依赖缺失，或 legacy Debian resolvconf 被安全拒绝 |
| `4` | 执行变更所需权限不足 |
| `10` | 配置、备份或持久状态无效 |
| `20` | 下载、checksum 获取、DNS 前测或外部命令失败，且系统尚未部分变更 |
| `30` | 操作部分完成，需要人工检查或恢复；DNS 写后验证失败固定使用此码 |
| `70` | 未分类的内部错误 |
| `130` | 用户中断 |

入口原样传递功能脚本退出码。失败信息必须同时说明已改变和未改变的状态、备份或状态路径以及下一条安全恢复命令。

## 6. 发布验收要求

自动化测试通过只代表仓库内可重复检查完成。声明平台支持前，还必须在可丢弃的隔离 VPS 或 VM 中完成以下验收，并保留脱敏结果：

- BBR：覆盖可用/不可用内核、重复执行、重启后持久化、`--apply-live-qdisc` 影响和完整恢复。
- DNS：分别覆盖 systemd-resolved、NetworkManager、openresolv、静态 resolv.conf；验证 legacy Debian 安全拒绝、候选前测失败零写入、写后失败保留配置并返回 `30`、按备份恢复。
- RFW：分别覆盖 systemd 上的 `x86_64`/`aarch64`，校验稳定 release 选择、checksum 不匹配拒绝、IPv6 不受影响、配置/更新延后重启、`APPLY-RFW`/`--confirm-disruptive` 门禁、更新和卸载恢复。
- 三入口：覆盖普通用户/root、`--dry-run`、`--non-interactive`、锁冲突、中断、重复执行及各基础退出码。

RFW 和 DNS 的中断性用例不得在唯一可用的远程管理链路上直接试验；应准备控制台或快照恢复通道。
