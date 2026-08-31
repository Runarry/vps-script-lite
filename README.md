# VPS Script Lite

面向日常 VPS 部署与维护的模块化脚本项目。

项目采用“一个管理入口、多个独立命令”的结构：管理入口只负责参数解析、固定命令登记、公共上下文和分发；每项实际功能原则上由一个公开入口脚本实现，复杂入口可拆为不单独分发的私有子模块。这样既能通过统一入口使用，也能单独运行、测试和排错。

> 当前版本为 0.5.0，在网络、访问与代理管理之外新增 `test nodequality` 和 `test tcpquality` 两个服务器测试入口。系统变更命令应先使用 `--dry-run` 并阅读对应恢复说明；服务器测试会下载并运行第三方代码、产生明显 CPU/磁盘/网络负载且不支持演练，运行前必须单独确认风险。

## 文档

- [架构与目录](docs/architecture.md)：组件边界、调用关系和目录用途。
- [脚本开发规范](docs/script-conventions.md)：命名、接口、日志、退出码、安全与质量要求。
- [命令登记规范](docs/command-registry.md)：新增命令时必须维护的元数据和清单格式。
- [开发与验收流程](docs/development-workflow.md)：从设计、实现到测试和评审的流程。
- [主管理脚本与 UI](docs/manager-ui.md)：启动检测、菜单结构、非交互模式和扩展方式。
- [网络设置](docs/network-settings.md)：BBR、DNS、IP 地址族偏好和 RFW 的接口、安全边界、持久化路径和恢复要求。
- [代理管理](docs/proxy-management.md)：Xray/sing-box 内核、节点、出口关联、端口转发、订阅、证书、日志与时间同步。
- [访问管理](docs/access-management.md)：用户、密码、公钥与 SSH 双端口验证事务、防火墙协同和恢复。
- [Fail2ban 管理](docs/fail2ban-management.md)：OpenSSH jail 的安装、均衡递增策略、白名单、验证和恢复。
- [服务器测试](docs/server-testing.md)：NodeQuality 与 TcpQuality 的上游来源、负载、报告上传、清理和退出码边界。

## 使用主管理脚本

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
bash bin/vpsctl security access status
bash bin/vpsctl security fail2ban status
bash bin/vpsctl service proxy status
bash bin/vpsctl service proxy profiles
bash bin/vpsctl service proxy relay status
bash bin/vpsctl test nodequality
bash bin/vpsctl test tcpquality
```

直接运行 `bash bin/vpsctl service proxy` 会进入统一代理界面。界面首先同时显示 Xray 与 sing-box 的安装/运行状态、配置路径、各自节点数和节点总数，再按内核生命周期、服务控制、节点管理、中转管理、查看输出和系统工具等能力分组提供操作。中转管理按编号提供“出口管理 / 节点中转 / 纯端口转发 / 状态与刷新”；一个出口可供多个入口复用，节点 URI 不因关联而改变。交互过程对内核、节点、出口、模式和开关等固定值统一使用编号选择；地址、端口、名称等开放值则在输入后立即校验，不要求输入 `--core` 等 CLI 参数。订阅可按编号选择全部，或只输出当前确有普通节点或端口转发 URI 的 sing-box/Xray 范围。

先查看变更计划的示例：

```text
bash bin/vpsctl --dry-run --install-deps network bbr enable
bash bin/vpsctl --dry-run --install-deps network dns set --server 1.1.1.1 --server 1.0.0.1
bash bin/vpsctl --dry-run network ip-policy set --policy prefer_ipv4
bash bin/vpsctl --dry-run --install-deps network rfw install
bash bin/vpsctl --dry-run security access ssh prepare --port 2222 --firewall manual
bash bin/vpsctl --dry-run security fail2ban install
bash bin/vpsctl --dry-run --install-deps service proxy install --core sing-box
```

在主管理菜单中选择 BBR、DNS、IP 地址族偏好、RFW、访问管理、Fail2ban、代理管理或两项服务器测试后，会直接进入对应功能入口，不再经过“命令详情”或输入 `r` 才运行的中间页；菜单选项执行的是真实动作，不提供演练、依赖授权、自动同意、非交互、静默或详细日志等执行型全局参数开关。`--dry-run`、`--install-deps`、`--yes`、`--non-interactive`、`--quiet`、`--verbose` 只用于直接功能 CLI，并写在领域之前；服务器测试明确拒绝 `--dry-run`，也不承诺非交互自动化。子动作及选项见[网络设置](docs/network-settings.md)、[访问管理](docs/access-management.md)、[Fail2ban 管理](docs/fail2ban-management.md)、[代理管理](docs/proxy-management.md)和[服务器测试](docs/server-testing.md)。机器可读格式开关、`--force` 和 `--confirm-*` 确认标志同样只用于直接 CLI，菜单中的危险动作改用明确的交互提示和必要的强确认短语。

依赖检查按用户当前选择的动作延迟执行：只有该动作实际缺少可安装工具时，真实执行的交互流程才询问是否安装，不会为其他菜单动作预装依赖；非交互调用和 `--dry-run` 依赖计划仍必须显式提供 `--install-deps`。该授权支持 `apt-get`、`dnf5`、`dnf`、`yum`、`apk`、`pacman` 和 `zypper`，实际安装需要 root，也不会绕过 Linux、init 系统、CPU 架构、内核版本、XDP/BPF 或功能本体等平台门禁。它与 `--dry-run` 组合时只展示固定的软件包安装命令，不实际安装，部分动作会在依赖计划后安全停止并提示安装后重跑。上例中的 `--core` 是直接命令和非交互调用保留的高级消歧参数：只有一个符合条件的内核时通常可自动解析，存在多个候选时应显式指定。

## 当前状态

- 规范：已建立。
- 目录骨架：已建立。
- 当前版本：0.5.0 服务器测试版。
- 管理入口：提供环境检测、终端 UI、固定注册表和安全分发。
- 功能命令：提供 `network bbr`、`network dns`、`network ip-policy`、`network rfw`、`security access`、`security fail2ban`、`service proxy`、`test nodequality` 和 `test tcpquality`；均处于 `experimental` 生命周期。
- 公共函数库：提供环境检测、命令注册、终端 UI 及网络和服务命令所需公共能力。
- 验收说明：所有项目测试与验证统一通过 `ssh host-vps-scripts` 在专用真实环境中执行；不得在当前系统或 WSL 中测试。发布前仍须按对应功能文档完成真实环境验收。
