# 系统内核管理验收记录

验收日期：2026-09-05。所有项目执行、检查和真实系统验收均通过 `ssh host-vps-scripts` 在专用环境完成；工作站只编辑和检查仓库差异。

## 自动检查

- 内核入口、私有模块、内核测试及本次公共文件变更逐个通过 `bash -n`、`shellcheck -x` 和 `shfmt -d -i 4 -ci`；测试入口现已逐个执行所列脚本的语法检查。
- `bash tests/run.sh` 通过，包含全部项目单元测试、CLI 集成测试和分发包回归。
- system 分发包必须包含入口及 `providers.sh`、`inventory.sh`、`grub.sh`；分别缺少任一模块均拒绝加载。
- 内核回归覆盖官方源与 suite、Ubuntu proposed/backports 拒绝、实际安装依赖的逐版本来源检查、CPU/平台/Secure Boot 限制、强确认及演练零写入。
- 菜单回归确认 HWE 在非 LTS、无候选或非可信来源时隐藏；XanMod 分支与 CPU 选择只在该类型显示。
- 卸载回归覆盖当前/default/next 保护、手工和半配置内核、缺失启动文件、共享 headers、元包依赖闭包、跨版本移除、APT 意外安装/升级以及模块残留。
- GRUB 回归覆盖稳定 ID、子菜单、恢复项排除、配置冲突、固定默认项、下一次启动覆盖清理和失败恢复。

## Debian 13 amd64：真实 UEFI/GRUB 2

专用宿主为 Debian 13，运行于 Hyper-V。下列 release 均为验收时 APT 实际选择的版本，未写入安装代码。

| 类型 | 验收 release | 真实结果 |
| --- | --- | --- |
| 官方标准 | `6.12.107+deb13-amd64` | 安装、固定默认、重启核对、从其他内核运行时卸载通过 |
| Debian Cloud | `6.12.107+deb13-cloud-amd64` | 安装、固定默认、重启核对、从其他内核运行时卸载通过 |
| XanMod LTS | `6.18.49-x64v3-xanmod1` | 安装、固定默认、重启核对、回切官方后卸载通过 |
| XanMod main | 原 `7.1.11-x64v3-xanmod1`；恢复时候选 `7.1.13-x64v3-xanmod1` | 旧版精确卸载、新候选安装、固定默认和重启核对通过 |

每次重启均实际核对 `uname -r`。额外确认：

- 正确提供 `--yes` 与强确认短语，仍不能删除当前运行或默认启动版本。
- 官方和 Cloud 目标的必要更新元包随目标移除，保留版本保持完整。
- 切回官方后，依次删除 XanMod main 和 LTS；最后一个 XanMod 包清除后，受管源、keyring 和兼容状态均已清理。
- 重新安装官方更新元包和 XanMod main 时，已经固定的官方 `6.12.105+deb13-amd64` 默认项保持不变。
- 最后显式切换并重启至 main `7.1.13-x64v3-xanmod1`，同时保留官方 `6.12.105+deb13-amd64`、`6.12.107+deb13-amd64` 及官方更新元包。

## Ubuntu 24.04 LTS amd64：真实 BIOS/GRUB 2

使用专用宿主内的完整 QEMU TCG 虚拟机，具有独立内核、磁盘、GRUB 和重启过程；不是容器、chroot 或模拟软件包结果。基础镜像是验签及 SHA-256 校验通过的 Ubuntu 24.04.4 官方云镜像，初始运行 `6.8.0-138-generic`。

| 类型 | 验收 release | 真实结果 |
| --- | --- | --- |
| 官方 GA | `6.8.0-139-generic` | 安装、永久切换、重启核对、进入 HWE 后卸载通过 |
| HWE | `7.0.0-31-generic` | 安装、永久切换、重启核对、回切官方后卸载通过 |

三次切换均实际重启并核对 boot ID 改变和 `uname -r`。在运行 GA、默认 HWE 的状态下，分别尝试卸载两个版本，均返回 3 并明确报告 current/default 保护，启动文件均保留。进入 HWE 后，GA139 的六个 generic/virtual 更新元包随目标移除，HWE 镜像和三个 HWE 元包保持完整。

最后重新安装并切回官方 GA，重启后卸载 HWE 及三个 HWE 元包。终态 current/default 均为 `6.8.0-139-generic`，无 next 覆盖，`dpkg --audit` 无输出；Ubuntu 虚拟机已正常关机，QEMU 进程退出，磁盘完整性检查通过。

## 实测发现与修复

- Ubuntu 各 pocket 的 Codename 相同，不能只看 Codename；官方候选同时限制 Suite 和 Release，仅接受本发行版、updates、security。
- Ubuntu APT 的合法 `Inst` 行可以带 `[]` 或包名组成的依赖状态。安装解析支持这些受限结构，同时继续逐包验证来源，拒绝无法解析的动作。
- Ubuntu 云镜像的 generic/virtual 元包可能共同绑定同一 GA release。卸载闭包纳入必要的同系列 virtual 元包，并保护另一 release 的 HWE 元包。
- 卸载模拟必须拒绝附带安装新内核的事务；不能因为目标是旧版本就接受 APT 自动解依赖产生的额外安装。
- 最终全量回归触发了既有代理能力检查的 SIGPIPE 竞态：`grep -q` 提前结束读取，使上游写入在 `pipefail` 下被误判为协议不支持。五处检查改为完整消费输入；确定性回归确认旧实现失败、修复实现通过，原有核心切换分组也通过。代理两份既有文件保留原格式和历史静态检查基线，本次执行语法及适用 ShellCheck 检查，避免扩大无关改动。

## 日志、恢复与环境维护

专用机保留：

- `/root/vpsctl-kernel-20260905/validation/`：Debian 安装、切换、重启、卸载及项目检查日志；最终全量结果为 `full-suite-final-pipefix.log`，代理竞态对照为 `proxy-pipefail-old.log` 与 `proxy-pipefail-new.log`。
- `/root/vpsctl-kernel-recovery-20260905/`：验收前运行版本、dpkg 包清单、手动安装标记、启动配置和受管 XanMod 状态备份。
- `/var/lib/vpsctl/system/kernel/backups/`：每次实际切换前的 GRUB 恢复材料。
- `/root/vpsctl-kernel-ubuntu-20260905/`：Ubuntu 原始镜像、独立覆盖磁盘、验证材料和运行日志；`validation/` 保存对应 CLI、重启、保护分支、终态检查和 SHA-256 清单。访问密钥仅保留在专用机，不进入仓库。

专用宿主只有约 892 MiB 内存，初次并行检查时 QEMU 被宿主 OOM 终止。该次只完成安装预检查，内核包事务尚未开始；离线 `qemu-img check` 确认磁盘无错误。随后增加受记录的临时交换空间，并串行执行真实系统验收。

验收结束后已停用并删除宿主的 `host-test.swap`，恢复原有交换分区配置；前后状态分别保存于 Ubuntu 验收目录的 `host-swap-before.txt` 和 `host-swap-restored.txt`。镜像、日志及恢复材料继续保留，虚拟机不占用运行资源。

这些结果覆盖上述发行版和两种实际 GRUB 启动环境，不将其扩大为其他发行版、架构或启动器的实测结论。功能仍保持 `experimental` 生命周期。
