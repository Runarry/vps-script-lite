# VPS Script Lite

面向日常 VPS 部署与维护的模块化脚本项目。

项目采用“一个管理入口、多个独立命令”的结构：管理入口只负责参数解析、固定命令登记、公共上下文和分发；每项实际功能原则上由一个独立脚本实现。这样既能通过统一入口使用，也能单独运行、测试和排错。

> 0.2.0 是首个网络功能版本，提供 BBR、DNS 和 RFW 三个 `network` 入口。网络变更具有断网风险，请先使用 `--dry-run` 并阅读对应恢复说明。

## 文档

- [架构与目录](docs/architecture.md)：组件边界、调用关系和目录用途。
- [脚本开发规范](docs/script-conventions.md)：命名、接口、日志、退出码、安全与质量要求。
- [命令登记规范](docs/command-registry.md)：新增命令时必须维护的元数据和清单格式。
- [开发与验收流程](docs/development-workflow.md)：从设计、实现到测试和评审的流程。
- [主管理脚本与 UI](docs/manager-ui.md)：启动检测、菜单结构、非交互模式和扩展方式。
- [网络设置](docs/network-settings.md)：BBR、DNS、RFW 的接口、安全边界、持久化路径和恢复要求。

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

网络首版的三个入口分别为：

```text
bash bin/vpsctl network bbr status
bash bin/vpsctl network dns show
bash bin/vpsctl network rfw status
```

先查看变更计划的示例：

```text
bash bin/vpsctl --dry-run network bbr enable
bash bin/vpsctl --dry-run network dns set --server 1.1.1.1 --server 1.0.0.1
bash bin/vpsctl --dry-run network rfw install
```

全局选项写在领域之前；子动作及选项见[网络设置](docs/network-settings.md)。`--yes` 只跳过允许自动确认的提示，不能绕过 RFW 的中断性操作强确认。

## 当前状态

- 规范：已建立。
- 目录骨架：已建立。
- 当前版本：0.2.0 网络首版。
- 管理入口：提供环境检测、终端 UI、固定注册表和安全分发。
- 功能命令：提供 `network bbr`、`network dns` 和 `network rfw`；三者均处于 `experimental` 生命周期。
- 公共函数库：提供环境检测、命令注册、终端 UI 及网络命令所需公共能力。
- 验收说明：仓库中的自动化检查不等同于真实 VPS 或 VM 验证；发布前仍须按网络文档的隔离环境矩阵完成验收。
