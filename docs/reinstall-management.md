# 系统重装与 DD

`system reinstall` 按需运行 [bin456789/reinstall](https://github.com/bin456789/reinstall)。系统支持、镜像下载、分区、DD 和引导配置均由未经修改的上游脚本负责。本项目提供轻量命令入口、脚本下载与保留、状态查看、取消及工具缓存清理，不维护发行版列表或上游参数白名单。

## 使用

```bash
vpsctl system reinstall
vpsctl system reinstall status
vpsctl system reinstall run -- debian 13
vpsctl system reinstall run -- dd --img 'https://example.com/system.raw.xz'
vpsctl system reinstall reset
vpsctl --yes system reinstall uninstall
```

无参数、`help`、`-h` 和 `--help` 显示本地帮助，不下载上游。`status` 读取本地脚本、专属缓存和重装引导残留，显示占用空间。它不通过联网检测新版本，也不把上游准备步骤的成功当作系统已经重装完成。安装态首次调用此功能仍可能下载 vpsctl 自身的 `system-reinstall` 与 `shared-command` bundle；这与下载上游工具是两个独立步骤。

`run` 后的参数原样交给上游，可省略分隔符 `--`。例如 `run -- windows --image-name 'Windows 11 Enterprise LTSC 2024' --lang zh-cn` 可使用上游 Windows 安装能力。上游选项、引号和包含空格的参数保持原样；具体用法见上游文档。本地全局选项应放在 `system reinstall` 之前，直接运行入口脚本时放在动作之前。

每次 `run` 都从固定官方 HTTPS 地址下载最新脚本：

```text
https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
```

下载结果通过检查后原子保存为 `/var/lib/vpsctl/reinstall/reinstall.sh`。失败不会运行旧副本，旧副本仍可用于取消重装。重装所需配套文件继续由上游自行下载，不随本项目 Release 打包，也不固定上游版本。下载完成不代表上游或目标系统已经完成安装。

真实操作要求 Linux/root，具体发行版与虚拟化支持由上游判断；本项目不额外承诺全部上游目标系统均已实测。`run`、`reset` 和 `uninstall` 不支持 `--dry-run`，会在下载及写入前拒绝。入口保留上游终端输入、输出、信号和退出状态，不记录完整参数，也不预答上游问题。上游可能在终端显示登录信息。

`--non-interactive` 将上游标准输入接到 `/dev/null`，调用者须通过上游参数提供全部所需输入；上游仍需输入时会失败。`--yes` 只跳过本项目卸载的一次普通确认，不为上游选择目标系统或填写参数。缺失的包装器依赖沿用 `--install-deps` 约定，上游依赖管理仍由上游决定。

上游的准备步骤会设置下次启动的安装环境；实际重装可清除目标磁盘全部数据。入口不主动重启，也不会在准备步骤退出时删除后续安装仍需使用的文件。准备完成后可自行重启开始安装，或用 `reset` 取消。

## 取消与卸载

`reset` 使用保留的上游脚本调用官方 `reset`，脚本缺失时才下载。它取消重装引导并执行上游清理，保留工具脚本供再次使用。上游 reset 自身仍可能联网或安装所需依赖。

`uninstall` 检测到 reinstall 引导残留时，先调用官方 `reset`；取消失败即停止卸载，保留尚存的脚本和恢复材料。确认没有安装进程或安装环境占用后，清理以下固定专属路径：

| 路径 | 内容 |
| --- | --- |
| `/var/lib/vpsctl/reinstall/` | 保留的官方脚本及下载临时文件 |
| `/reinstall-tmp/` | 上游准备阶段的解包文件、探测文件和缓存 |
| `/reinstall.log` | 上游安装日志残留 |
| `/reinstall-vmlinuz`、`/reinstall-initrd`、`/reinstall-firmware` | 临时安装内核、initrd 与固件 |
| `/boot/reinstall-vmlinuz`、`/boot/reinstall-initrd`、`/boot/reinstall-firmware` | 对应的临时引导文件副本 |

GRUB、Extlinux 和 EFI 的引导项撤销由上游处理。删除前检查符号链接与挂载边界，包括目录内部的挂载；发现占用或不安全路径时说明原因并停止，不能直接对仍在使用的安装环境执行递归删除。

清理不依赖旧 vpsctl 状态文件：重装后的 Linux 重新安装 vpsctl，即可识别上述残留。没有引导残留时直接执行本地清理，不下载上游。工具专属路径以外的系统依赖、包管理器缓存、用户镜像及安装分区不在删除范围内；RAW DD 的镜像流与云镜像临时分区由上游安装流程处理。

卸载输出清理结果及回收空间，重复执行成功返回。仅清理上游工具及专属缓存，管理入口仍可供下一次按需使用。`vpsctl self uninstall` 的原有功能数据保留规则不变。

本入口不迁移自身到新系统，不注入开机清理服务；Windows 目标系统安装仍可透传执行，Windows 内的清理入口不在本功能范围内。

## 失败与验收

包装器参数错误或不支持演练返回 `2`，依赖、运行占用或安全前置条件不满足返回 `3`，权限不足返回 `4`，下载失败返回 `20`；部分清理失败返回 `30` 并报告未完成路径。`run` 和 `reset` 原样返回上游退出码；卸载中的 reset 失败返回 `30` 并保留剩余恢复材料，不把非零状态规范化为成功。中断不会自动取消已经准备的重装，应在确认上游进程退出后使用 `reset` 或 `uninstall`。

所有测试通过 `ssh host-vps-scripts` 执行。自动化覆盖按需下载、精确参数透传、下载失败、取消与卸载顺序、无旧状态清理、重复执行、挂载及链接保护、信号与分发边界。真实准备、取消、重启和 RAW DD 在该主机的可丢弃 QEMU 虚拟机内验收，结果及恢复信息见[验收记录](reinstall-validation.md)。
