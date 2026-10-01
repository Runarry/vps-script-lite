# 系统重装与 DD

`system reinstall` 按需运行 [bin456789/reinstall](https://github.com/bin456789/reinstall)。系统支持、镜像下载、分区、DD 和引导配置均由未经修改的上游脚本负责。本项目提供常用系统与 RAW DD 的快捷菜单、原样透传上游参数的命令入口、脚本下载与保留、状态查看、取消及工具缓存清理。快捷菜单的固定预设不限制直接 `run` 的目标系统或上游参数。

## 使用

```bash
vpsctl system reinstall
vpsctl system reinstall menu
vpsctl --non-interactive system reinstall
vpsctl system reinstall help
vpsctl system reinstall status
vpsctl system reinstall run -- debian 13
vpsctl system reinstall run -- dd --img 'https://example.com/system.raw.xz'
vpsctl system reinstall reset
vpsctl --yes system reinstall uninstall
```

无参数在交互 TTY 中进入快捷菜单；没有 TTY 或设置了 `--non-interactive` 时显示本地帮助。显式 `menu` 必须具备交互 TTY，否则拒绝执行。`help`、`-h` 和 `--help` 始终显示本地帮助；查看帮助和浏览菜单不下载上游。

源码树也可直接运行独立入口，行为与主管理入口一致：

```bash
bash commands/system/reinstall.sh
bash commands/system/reinstall.sh menu
bash commands/system/reinstall.sh run -- debian 13
```

`status` 读取本地脚本、专属缓存和重装引导残留，显示占用空间。它不通过联网检测新版本，也不把上游准备步骤的成功当作系统已经重装完成。安装态首次调用此功能仍可能下载 vpsctl 自身的 `system-reinstall` 与 `shared-command` bundle；这与下载上游工具是两个独立步骤。

## 快捷重装与 RAW DD

快捷菜单按编号选择目标系统和版本，版本列表的首项为默认值：

| 目标 | 常用版本 |
| --- | --- |
| Debian | 13（默认）、12、上游 `latest` |
| Ubuntu | 24.04（默认）、22.04、26.04、上游 `latest` |
| Alpine | 3.24（默认）、3.23、上游 `latest` |
| Rocky Linux | 9（默认）、10、8、上游 `latest` |
| AlmaLinux | 9（默认）、10、8、上游 `latest` |
| Windows 客户端 | Windows 11 Enterprise LTSC 2024（默认）、Windows 11 Pro、Windows 10 Enterprise LTSC 2021、Windows 10 Pro |
| Windows Server | 2022（默认）、2025、2019 |
| RAW DD | 输入 HTTP(S) 镜像 URL；格式识别由上游负责 |

Windows Server 使用桌面体验，版本可选 Standard（默认）或 Datacenter。Windows 语言可选 `zh-cn`（默认）或 `en-us`，ISO 由上游自动获取。选择上游最新版时省略版本号，由运行时下载的上游决定版本；固定预设不代表本项目已经逐一完成真实安装验收。

Linux 与 RAW 默认使用 `root`，SSH 端口默认 `22`；认证可选随机密码（默认）、自定义密码或 SSH 公钥。Windows 使用 `administrator`，RDP 端口默认 `3389`，密码可选随机生成（默认）或自定义。自定义密码隐藏输入，并要求重复输入确认。RAW 的用户名、认证和 SSH 端口只用于安装环境，最终镜像内的账户与登录方式由镜像本身决定。

提交前显示目标系统、版本、登录方式、端口等摘要，隐藏密码内容，再进行默认拒绝的安装确认；只有明确同意后才下载并执行上游。`--yes` 只用于原有卸载确认，不能替代快捷安装确认、选择系统或授权重启。执行输出仍可能包含上游显示的登录信息。

上游准备成功后，快捷流程提供三个选择：

- **立即重启**：选择即授权重启，不再追加确认；重启后开始安装，可能清除目标磁盘全部数据。
- **稍后重启（默认）**：保留安装资源，用户可自行重启；输入 `q` 或遇到 EOF 也按稍后重启处理。
- **取消重装**：调用保留的上游 `reset` 撤销重装引导，保留工具脚本。

上游准备失败或被中断时不进入重启选择，不主动重启，也不自动清理恢复材料。快捷流程在上游执行和成功后的选择期间持有同一互斥锁，转发信号并保留上游失败状态；取消失败时保留尚存的恢复材料并报告失败。

## 直接透传与下载

`run` 后的参数原样交给上游，可省略分隔符 `--`。例如 `run -- windows --image-name 'Windows 11 Enterprise LTSC 2024' --lang zh-cn` 可使用上游 Windows 安装能力。参数内容与边界保持原样，包括含空格的参数；具体用法见上游文档。本地全局选项应放在 `system reinstall` 之前，直接运行入口脚本时放在动作之前。

每次直接 `run` 或确认后的快捷安装都从固定官方 HTTPS 地址下载最新脚本：

```text
https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
```

下载结果通过检查后原子保存为 `/var/lib/vpsctl/reinstall/reinstall.sh`。失败不会运行旧副本，旧副本仍可用于取消重装。重装所需配套文件继续由上游自行下载，不随本项目 Release 打包，也不固定上游版本。下载完成不代表上游或目标系统已经完成安装。

真实操作要求 Linux/root，具体发行版与虚拟化支持由上游判断；本项目不额外承诺全部上游目标系统均已实测。快捷安装、`run`、`reset` 和 `uninstall` 不支持 `--dry-run`，会在下载及写入前拒绝。直接 `run` 使用 `exec` 交接上游，保留终端输入、输出、信号和退出状态，不记录完整参数，也不预答上游问题。上游可能在终端显示登录信息。

直接调用的 `--non-interactive` 将上游标准输入接到 `/dev/null`，调用者须通过上游参数提供全部所需输入；上游仍需输入时会失败。`--yes` 只跳过本项目卸载的一次普通确认，不为上游选择目标系统或填写参数。缺失的包装器依赖沿用 `--install-deps` 约定，上游依赖管理仍由上游决定。

上游的准备步骤会设置下次启动的安装环境；实际重装可清除目标磁盘全部数据。直接 `run` 不主动重启，也不会在准备步骤退出时删除后续安装仍需使用的文件；准备完成后可自行重启开始安装，或用 `reset` 取消。成功后的重启选择只属于快捷菜单流程。

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

本入口不迁移自身到新系统，不注入开机清理服务；Windows 目标系统安装可通过快捷菜单或透传执行，Windows 内的清理入口不在本功能范围内。

## 失败与验收

包装器参数错误或不支持演练返回 `2`，依赖、运行占用或安全前置条件不满足返回 `3`，权限不足返回 `4`，下载失败返回 `20`；部分清理失败返回 `30` 并报告未完成路径。`run` 和 `reset` 原样返回上游退出码；卸载中的 reset 失败返回 `30` 并保留剩余恢复材料，不把非零状态规范化为成功。中断不会自动取消已经准备的重装，应在确认上游进程退出后使用 `reset` 或 `uninstall`。

所有测试通过 `ssh host-vps-scripts` 执行。自动化检查与可丢弃 QEMU 虚拟机中的真实准备、取消、重启和 RAW DD 的实际验收范围、结果及恢复信息见[验收记录](reinstall-validation.md)；快捷菜单列出的系统与版本不构成逐项实测承诺。
