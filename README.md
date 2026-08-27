# VPS Script Lite

面向日常 VPS 部署与维护的模块化脚本项目。

项目采用“一个管理入口、多个独立命令”的结构：管理入口只负责参数解析、固定命令登记、公共上下文和分发；每项实际功能原则上由一个公开入口脚本实现，复杂入口可拆为不单独分发的私有子模块。这样既能通过统一入口使用，也能单独运行、测试和排错。

> 当前版本为 0.3.0，在 BBR、DNS 和 RFW 三个 `network` 入口之外新增 `service proxy`，平级管理 Xray 与 sing-box。网络和代理服务变更都可能中断远程连接，请先使用 `--dry-run` 并阅读对应恢复说明。

## 文档

- [架构与目录](docs/architecture.md)：组件边界、调用关系和目录用途。
- [脚本开发规范](docs/script-conventions.md)：命名、接口、日志、退出码、安全与质量要求。
- [命令登记规范](docs/command-registry.md)：新增命令时必须维护的元数据和清单格式。
- [开发与验收流程](docs/development-workflow.md)：从设计、实现到测试和评审的流程。
- [主管理脚本与 UI](docs/manager-ui.md)：启动检测、菜单结构、非交互模式和扩展方式。
- [网络设置](docs/network-settings.md)：BBR、DNS、RFW 的接口、安全边界、持久化路径和恢复要求。
- [代理管理](docs/proxy-management.md)：Xray/sing-box 内核、节点、协议、订阅、证书、日志与时间同步。

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

当前网络与服务入口包括：

```text
bash bin/vpsctl network bbr status
bash bin/vpsctl network dns show
bash bin/vpsctl network rfw status
bash bin/vpsctl service proxy status
bash bin/vpsctl service proxy profiles
```

直接运行 `bash bin/vpsctl service proxy` 会进入统一代理界面。界面首先同时显示 Xray 与 sing-box 的安装/运行状态、配置路径、各自节点数和节点总数，再按内核生命周期、服务控制、节点管理、查看输出和系统工具等能力分组提供操作。交互过程使用枚举和编号选择内核或节点，不要求输入 `--core`。

先查看变更计划的示例：

```text
bash bin/vpsctl --dry-run network bbr enable
bash bin/vpsctl --dry-run network dns set --server 1.1.1.1 --server 1.0.0.1
bash bin/vpsctl --dry-run network rfw install
bash bin/vpsctl --dry-run service proxy install --core sing-box
```

全局选项写在领域之前；子动作及选项见[网络设置](docs/network-settings.md)和[代理管理](docs/proxy-management.md)。上例中的 `--core` 是脚本和非交互调用保留的高级消歧参数：只有一个符合条件的内核时通常可自动解析，存在多个候选时应显式指定。`--yes` 只跳过允许自动确认的提示，不能绕过 RFW 中断性操作、代理重启、外部二进制更新或彻底清除的强确认。

## 当前状态

- 规范：已建立。
- 目录骨架：已建立。
- 当前版本：0.3.0 代理管理版。
- 管理入口：提供环境检测、终端 UI、固定注册表和安全分发。
- 功能命令：提供 `network bbr`、`network dns`、`network rfw` 和 `service proxy`；均处于 `experimental` 生命周期。
- 公共函数库：提供环境检测、命令注册、终端 UI 及网络和服务命令所需公共能力。
- 验收说明：仓库中的自动化检查不等同于真实 VPS 或 VM 验证；发布前仍须按对应功能文档在隔离环境完成验收。
