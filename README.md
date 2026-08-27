# VPS Script Lite

面向日常 VPS 部署与维护的模块化脚本项目。

项目采用“一个管理入口、多个独立命令”的结构：未来的管理入口只负责参数解析、命令发现、公共上下文和分发；每项实际功能原则上由一个独立脚本实现。这样既能通过统一入口使用，也能单独运行、测试和排错。

> 当前已提供主管理入口、环境检测和可扩展终端 UI，尚未提供实际 VPS 运维功能。

## 文档

- [架构与目录](docs/architecture.md)：组件边界、调用关系和目录用途。
- [脚本开发规范](docs/script-conventions.md)：命名、接口、日志、退出码、安全与质量要求。
- [命令登记规范](docs/command-registry.md)：新增命令时必须维护的元数据和清单格式。
- [开发与验收流程](docs/development-workflow.md)：从设计、实现到测试和评审的流程。
- [主管理脚本与 UI](docs/manager-ui.md)：启动检测、菜单结构、非交互模式和扩展方式。

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

功能命令采用以下稳定模型：

```text
vpsctl <domain> <action> [options]
```

例如，文档中可能使用 `vpsctl system update-packages` 说明命令结构；该示例不代表对应功能已经实现。

## 当前状态

- 规范：已建立。
- 目录骨架：已建立。
- 管理入口：已实现首版环境检测、终端 UI、注册表和安全分发框架。
- 功能命令：未实现。
- 公共函数库：已实现环境检测、命令注册和终端 UI 模块。
