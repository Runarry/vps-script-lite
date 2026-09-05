# VPS Script Lite

面向日常 VPS 部署与维护的模块化脚本项目。

项目采用“一个管理入口、多个独立命令”的结构：管理入口只负责参数解析、固定命令登记、公共上下文和分发；每项实际功能原则上由一个公开入口脚本实现，复杂入口可拆为不单独分发的私有子模块。这样既能通过统一入口使用，也能单独运行、测试和排错。

> 当前版本为 0.7.0，提供网络、系统内核、访问、TLS 证书、代理与服务器测试入口。系统变更命令应先使用 `--dry-run` 并阅读对应恢复说明；内核变更需提前确认带外控制台或救援入口可用，服务器测试会下载并运行第三方代码、产生明显 CPU/磁盘/网络负载且不支持演练。

这里的 `0.7.0` 是现有应用与功能版本。GitHub Release 分发格式始于分发版本 `0.1.0`，当前分发版本为 `0.2.0`（仓库根 `VERSION`、tag `v0.2.0`）；两套版本号用途不同，发布资产、安装目录和 `vpsctl self` 使用分发版本，不回退或改写现有功能版本。

## 文档

- [架构与目录](docs/architecture.md)：组件边界、调用关系和目录用途。
- [脚本开发规范](docs/script-conventions.md)：命名、接口、日志、退出码、安全与质量要求。
- [命令登记规范](docs/command-registry.md)：新增命令时必须维护的元数据和清单格式。
- [开发与验收流程](docs/development-workflow.md)：从设计、实现到测试和评审的流程。
- [主管理脚本与 UI](docs/manager-ui.md)：启动检测、菜单结构、非交互模式和扩展方式。
- [网络设置](docs/network-settings.md)：BBR、DNS、IP 地址族偏好和 RFW 的接口、安全边界、持久化路径和恢复要求。
- [系统内核管理](docs/kernel-management.md)：发行版官方内核与 XanMod BBRv3 的安装、固定默认版本、按版本卸载和恢复；另见[验收记录](docs/kernel-validation.md)。
- [代理管理](docs/proxy-management.md)：Xray/sing-box 内核、节点、出口关联、端口转发、订阅、证书、日志与时间同步。
- [访问管理](docs/access-management.md)：用户、密码、公钥与 SSH 双端口验证事务、防火墙协同和恢复。
- [Fail2ban 管理](docs/fail2ban-management.md)：OpenSSH jail 的安装、均衡递增策略、白名单、验证和恢复。
- [TLS 证书管理](docs/tls-management.md)：域名证书导入、ACME 申请与自动续期。
- [服务器测试](docs/server-testing.md)：NodeQuality 与 TcpQuality 的上游来源、负载、报告上传、清理和退出码边界。

## 安装

核心管理入口支持 Alpine Linux 3.20 及更新版本的 `x86_64`、`aarch64` 主机。最小化 Alpine 镜像应先安装启动和下载所需工具：

```bash
apk add --no-cache bash curl ca-certificates
```

这里的“核心支持”覆盖安装、自管理、环境检测、帮助、清单和命令分发，不代表每个领域功能都支持 Alpine/OpenRC/musl。关键功能边界如下：

| 功能 | Alpine 3.20+ 边界 |
| --- | --- |
| 核心管理入口 | `x86_64`、`aarch64` 支持；要求 Bash 4.4+，安装/更新需要 `curl` 和 CA 证书 |
| `network bbr` | 支持入口与依赖安装；实际变更仍要求内核暴露所选拥塞控制和 qdisc 能力 |
| `network dns` | 支持静态 `/etc/resolv.conf` 与 openresolv；检测到 Alpine DHCP 可能回写 plain 后端时，会在零写入状态拒绝并要求 openresolv，或明确禁用 udhcpc/dhcpcd 的 DNS hook |
| `network rfw` | 不支持 Alpine 默认的 OpenRC；仅支持 systemd、`x86_64`/`aarch64`、Linux 5.15+ 及所需 XDP/BPF 能力 |
| `security access` | SSH 服务编排仅支持 systemd；不能把核心的 OpenRC 支持外推为访问管理支持 |
| `security fail2ban` | 不支持 `apk`/OpenRC；仅支持文档列出的 systemd 发行版包管理器与 Fail2ban 0.11+ |
| `security tls` | 导入与查看支持 Alpine；续期 timer 需要 systemd；ACME 的 lego 二进制仅 `x86_64`/`aarch64` |
| `system kernel` | 不支持 Alpine；仅支持 Debian/Ubuntu amd64 上的 APT/dpkg，可管理发行版官方内核与 XanMod 官方构建；自动切换限可识别的标准 GRUB 2 |
| `network ip-policy` | 不支持 Alpine 的 musl；该入口只管理 glibc `getaddrinfo()` 的 `/etc/gai.conf` 排序 |
| `service proxy` | 支持 OpenRC 与 systemd；具体内核、协议、架构和依赖仍按代理功能文档与运行时门禁判断 |
| `test nodequality` / `test tcpquality` | vpsctl 包装入口要求 Linux/root，但运行时下载的第三方脚本会自行决定依赖和发行版兼容性；核心支持不构成其 Alpine 兼容承诺 |

在受支持的 Linux VPS 的 root shell 中可使用一行命令安装最新 GitHub Release：

```bash
curl -fsSL https://github.com/Runarry/vps-script-lite/releases/latest/download/vpsctl.sh | bash
```

安装后使用快捷命令 `vpsctl`。启动 `vpsctl` 只读取本地已安装内容，不联网检查更新；需要查看或更新分发版本时显式运行：

```text
vpsctl self status
vpsctl self update
vpsctl self update --version v0.2.0
```

`curl | bash` 的初始执行信任边界包括 HTTPS、GitHub、仓库及 Release 发布权限，以及当前 `latest` 指向的 `vpsctl.sh`；同一 Release 中的校验清单只能在安装器已经开始执行后保护后续资产，不能倒过来证明安装器自身可信。更稳妥的方式是先下载安装器和清单，检查来源、版本、SHA-256 与脚本内容，再执行本地文件：

```bash
tmp_dir="$(mktemp -d)"
base_url="https://github.com/Runarry/vps-script-lite/releases/download/v0.2.0"
curl -fL "$base_url/vpsctl.sh" -o "$tmp_dir/vpsctl.sh"
curl -fL "$base_url/vpsctl-manifest.tsv" -o "$tmp_dir/vpsctl-manifest.tsv"
awk -F '\t' '$1 == "asset" && $2 == "launcher" { print $4 "  vpsctl.sh" }' \
  "$tmp_dir/vpsctl-manifest.tsv" | (cd "$tmp_dir" && sha256sum -c -)
less "$tmp_dir/vpsctl.sh"
# 确认后在 root shell 中使用已校验的固定 tag manifest：
bash "$tmp_dir/vpsctl.sh" --verified-manifest "$tmp_dir/vpsctl-manifest.tsv"
```

固定安装布局为：

- 快捷入口：`/usr/local/bin/vpsctl`
- 不可变版本目录：`/usr/local/lib/vpsctl/releases/<version>/`
- 当前版本指针：`/usr/local/lib/vpsctl/current`
- 安装器、自更新和分发缓存元数据：`/var/lib/vpsctl/self/`

`core` 常驻安装；`network`、`system`、`security`、`service` 与 `test` 按领域拆分。首次调用某领域时，只从当前分发版本对应的同一个 GitHub Release 下载该领域资产，按 `vpsctl-manifest.tsv` 的 SHA-256 校验后缓存；不同版本的 core 与领域资产不得混用。

卸载命令为：

```text
vpsctl self uninstall --confirm-uninstall
vpsctl self uninstall --purge --confirm-uninstall --confirm-purge
```

普通卸载删除分发入口和已安装的分发文件，但不触碰 `/etc/vpsctl/`、功能状态与备份、各功能已经安装的组件或 `/usr/local/libexec/`。交互菜单会要求现场确认；非交互调用必须提供 `--confirm-uninstall`，purge 还必须提供 `--confirm-purge`，全局 `--yes` 不能替代这些非交互确认标志。`--purge` 具有相同的功能数据保护边界，只额外删除 `/var/lib/vpsctl/self/` 中的 self 元数据。

## 从源码树运行主管理脚本

在 Linux VPS、WSL 或其他 Bash 4.4+ 的 GNU/Linux 环境中运行：

```text
bash bin/vpsctl
```

常用内置命令：

```text
bash bin/vpsctl env
bash bin/vpsctl list
bash bin/vpsctl --help
```

功能命令采用以下统一模型：

```text
vpsctl [global-options] <domain> <action> [command-options]
```

当前网络、安全、服务与服务器测试入口包括：

```text
bash bin/vpsctl network bbr status
bash bin/vpsctl network dns show
bash bin/vpsctl network ip-policy status
bash bin/vpsctl network rfw status
bash bin/vpsctl system kernel status
bash bin/vpsctl system kernel install --type official --confirm-install INSTALL-KERNEL
bash bin/vpsctl system kernel switch --release RELEASE --confirm-switch SWITCH-KERNEL
bash bin/vpsctl system kernel uninstall --release RELEASE --confirm-uninstall REMOVE-KERNEL
bash bin/vpsctl security access status
bash bin/vpsctl security fail2ban status
bash bin/vpsctl security tls status
bash bin/vpsctl service proxy status
bash bin/vpsctl service proxy profiles
bash bin/vpsctl service proxy node core set --id NODE_ID --core xray --confirm-disruptive
bash bin/vpsctl service proxy relay status
bash bin/vpsctl test nodequality
bash bin/vpsctl test tcpquality
```

直接运行 `bash bin/vpsctl system kernel` 会进入内核管理菜单，按编号查看版本状态、安装/更新、固定默认启动版本或卸载指定版本。菜单默认推荐发行版官方标准内核；直接 CLI 省略 `--type` 时仍默认 XanMod，以兼容旧调用。Debian 还提供 Cloud，Ubuntu LTS 在适配候选存在时提供 HWE。安装不会删除旧内核，切换不会重启；应在重启核对目标版本后再卸载旧版本。

直接运行 `bash bin/vpsctl service proxy` 会进入统一代理界面。界面首先同时显示 Xray 与 sing-box 的安装/运行状态、配置路径、各自节点数和节点总数，再按内核生命周期、服务控制、节点管理、中转管理、查看输出和系统工具等能力分组提供操作。节点管理包含将单个节点切换到另一兼容内核；中转管理按编号提供“出口管理 / 节点中转 / 纯端口转发 / 状态与刷新”。一个出口可供多个入口复用，节点 URI 不因关联而改变。交互过程对内核、节点、出口、模式和开关等固定值统一使用编号选择；地址、端口、名称等开放值则在输入后立即校验，不要求输入 `--core` 等 CLI 参数。订阅可按编号选择全部，或只输出当前确有普通节点或端口转发 URI 的 sing-box/Xray 范围。

`node core set` 只接受已经安装且支持该节点 profile 的另一内核，不会代为安装。切换保持客户端端点、凭据、TLS、传输和 IP 策略语义；重新生成的 URI 可能采用不同的字符串编码或参数顺序，自签名和导入证书的受管内部路径会随内核迁移。绑定的协议出口只有在该节点独占、没有端口转发引用且与目标内核兼容时才会一并迁移；共享、有端口转发或不兼容都会拒绝。切换会立即接管并可能短暂中断连接，非交互调用必须提供 `--confirm-disruptive`；目标服务的 active/enabled 状态按源服务可用性继承，任一步失败都会回滚节点、配置、中转、证书与服务状态。

先查看变更计划的示例：

```text
bash bin/vpsctl --dry-run --install-deps network bbr enable
bash bin/vpsctl --dry-run --install-deps network dns set --server 1.1.1.1 --server 1.0.0.1
bash bin/vpsctl --dry-run network ip-policy set --policy prefer_ipv4
bash bin/vpsctl --dry-run --install-deps network rfw install
bash bin/vpsctl --dry-run --install-deps system kernel install --type official
bash bin/vpsctl --dry-run security access ssh prepare --port 2222 --firewall manual
bash bin/vpsctl --dry-run security fail2ban install
bash bin/vpsctl --dry-run security tls import --name example --cert-file /path/cert.pem --key-file /path/key.pem
bash bin/vpsctl --dry-run --install-deps service proxy install --core sing-box
bash bin/vpsctl --dry-run --install-deps service proxy install --core all --release-channel prerelease
bash bin/vpsctl service proxy update --core xray --version vX.Y.Z
```

代理内核安装和更新默认选择最新稳定版，也可用 `--release-channel prerelease` 选择最新预发布版，或用 `--version TAG` 精确选择稳定或预发布 Release；后两项互斥。`--core all` 可共享 release channel，但不能共享一个 `--version`，因为 Xray 与 sing-box 的 tag 空间不同。安装时选择的通道不会写入状态；以后不带版本选项执行 `update` 仍选择最新稳定版。内核资产继续执行官方来源、唯一资产、SHA-256、解压目标、二进制版本和现有配置兼容性校验，更新完成后不会自动重启服务。

在主管理菜单中选择 BBR、DNS、IP 地址族偏好、RFW、内核管理、访问管理、Fail2ban、TLS 证书、代理管理或两项服务器测试后，会直接进入对应功能入口，不再经过“命令详情”或输入 `r` 才运行的中间页；菜单选项执行的是真实动作，不提供演练、依赖授权、自动同意、非交互、静默或详细日志等执行型全局参数开关。系统内核菜单以官方标准内核为推荐安装项，并通过编号选择具体切换或卸载版本；代理内核的安装和更新会用编号选择最新稳定版（推荐）、最新预发布版或精确 Release tag。`--dry-run`、`--install-deps`、`--yes`、`--non-interactive`、`--quiet`、`--verbose` 只用于直接功能 CLI，并写在领域之前；服务器测试明确拒绝 `--dry-run`，也不承诺非交互自动化。子动作及选项见[网络设置](docs/network-settings.md)、[系统内核管理](docs/kernel-management.md)、[访问管理](docs/access-management.md)、[Fail2ban 管理](docs/fail2ban-management.md)、[TLS 证书管理](docs/tls-management.md)、[代理管理](docs/proxy-management.md)和[服务器测试](docs/server-testing.md)。机器可读格式开关、`--force` 和 `--confirm-*` 确认标志同样只用于直接 CLI，菜单中的危险动作改用明确的交互提示和必要的强确认短语。

依赖检查按用户当前选择的动作延迟执行：只有该动作实际缺少可安装工具时，真实执行的交互流程才询问是否安装，不会为其他菜单动作预装依赖；非交互调用和 `--dry-run` 依赖计划仍必须显式提供 `--install-deps`。该授权支持 `apt-get`、`dnf5`、`dnf`、`yum`、`apk`、`pacman` 和 `zypper`，实际安装需要 root，也不会绕过 Linux、init 系统、CPU 架构、内核版本、XDP/BPF 或功能本体等平台门禁。它与 `--dry-run` 组合时只展示固定的软件包安装命令，不实际安装，部分动作会在依赖计划后安全停止并提示安装后重跑。上例中的 `--core` 是直接命令和非交互调用保留的高级消歧参数：只有一个符合条件的内核时通常可自动解析，存在多个候选时应显式指定。

## 当前状态

- 规范：已建立。
- 目录骨架：已建立。
- 当前版本：0.7.0 TLS 证书管理版。
- 管理入口：提供环境检测、终端 UI、固定注册表和安全分发。
- 功能命令：提供 `network bbr`、`network dns`、`network ip-policy`、`network rfw`、`system kernel`、`security access`、`security fail2ban`、`security tls`、`service proxy`、`test nodequality` 和 `test tcpquality`；均处于 `experimental` 生命周期。
- 公共函数库：提供环境检测、命令注册、终端 UI 及网络和服务命令所需公共能力。
- 验收说明：所有项目测试与验证统一通过 `ssh host-vps-scripts` 在专用真实环境中执行；不得在当前系统或 WSL 中测试。发布前仍须按对应功能文档完成真实环境验收。
