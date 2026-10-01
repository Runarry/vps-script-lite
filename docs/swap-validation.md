# Swap 验收记录

日期：2026-10-01。全部项目执行、语法、静态检查和真实验收均经 `ssh host-vps-scripts` 完成；本机仅编辑、导出／同步源码和查看差异。

## 候选与证据

源码基线：`c187f3858cf251472457bc9d21de709f26c9f3dc` 加本次工作区改动。未发布新 Release，版本仍为 `0.8.11`，manifest schema 仍为 2。

证据根目录为专用宿主 `/var/tmp/vpsctl-swap-20261001.HrQW0A`；候选代码在 `repo`，检查日志在 `evidence`。原始设备标识、配置及恢复材料只保存远端，不提交仓库。

最终文件 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| `commands/system/swap.sh` | `b4c6970338b7c8734b3e86870e51bf836450df1b9c08b706c44349adb62b8ad5` |
| `lib/command.sh` | `985e6d09016c36a58f68856f9e73ef511658ad8ebea7bc24d4f6214f5a2e3894` |
| `tests/unit/test-system-swap.sh` | `4fa99d7cb0fcde3e2b2d523138b554c325939a62e53cd100feaccb681a608698` |
| `tests/integration/test-system-swap-real.sh` | `313689e72e8d2e3c16df0c1c3453cbe7d8e22d41131a01acb5d28086ab7f24c0` |

Debian 真实验收的功能脚本为 `659c618b…`；其后产品改动仅处理 OpenRC 的本地文件系统启动顺序，复用仍有效的 systemd 结果。真实脚本补充了 OpenRC 配置恢复和重启失败时已知候选文件的身份核验与清理；最终脚本静态检查通过。

## 检查结果

| 范围 | 结果与证据 |
| --- | --- |
| 新功能、新增测试及共享生产代码 | **PASS**：`bash -n`、ShellCheck、`shfmt -d -i 4 -ci`。单元脚本用 `shellcheck -x`；共享库和真实脚本用 `shellcheck -x -P SCRIPTDIR`。 |
| 大小、参数与只读 CLI | **PASS**：自动推荐及上下界、溢出和非法输入、fstab 转义、状态／帮助、权限与依赖授权、演练无写入。后续仅事务和菜单改动，复用仍有效的结果。 |
| Swap 事务 | **PASS**：25 个隔离夹具，覆盖先启用后停用、提交后删除、同容量幂等、分区／UUID 去重、fstab 保留、空间／内存拒绝、初始化／启用／停用／配置／启动失败恢复、部分恢复与清理返回 30、信号中断、文件替换／符号链接／非 swap 文件保护。见 `swap-transaction-unit.log`。 |
| OpenRC 单元路径 | **PASS**：原 3 个 boot／恢复夹具，另有修复后的 8 个定向夹具，覆盖 localmount 依赖、配置内容和权限保留、同容量有效性及修复、关闭移除受管块、写入／依赖缓存／缺失配置恢复、异常标记拒绝和恢复失败返回 30。见 `swap-openrc-unit.log`、`swap-openrc-ordering-unit.log`。 |
| 菜单与平台 | **PASS**：显示实际推荐容量、非法输入重试、拒绝确认返回 130 且保持原状态、Linux 门禁。见 `swap-menu-unit.log`。 |
| 相关回归 | **PASS**：`test-command.sh`、`test-libraries.sh`、`test-distribution.sh`、`test-release-build.sh`、`test-vpsctl.sh`。包括第 3 项菜单直达、退出码／参数传递、功能包冷缓存及离线复用、固定发布清单。日志为 `evidence/<测试文件名>.log`。 |
| 既有测试文件格式 | **基线问题，非完整 PASS**：`test-command.sh`、`test-release-build.sh`、`test-vpsctl.sh` 存在原有格式差异；`test-libraries.sh` 存在既有 shfmt 解析诊断。逐文件与 HEAD 对照并排除 diff 行号变化后，诊断完全相同；新增分发测试的格式问题已修正。见 `format-baseline-*`、`format-current-*`。 |
| Debian 13/systemd/ext4 真实流程 | **PASS**：原交换分区与新增 64 MiB 普通文件混合接管为 256 MiB，旧文件删除；同容量不重建；扩大到 512 MiB；演练保持活动状态及 fstab。见 `debian-real-prepare.log`。 |
| Debian 真实重启与恢复 | **PASS**：重启前后 boot ID 不同，重启后只有原目标 512 MiB 文件活动，旧分区保持停用。继续缩小到 256 MiB、关闭、重复关闭；恢复原交换分区和逐字节一致的原 fstab。见 `debian-real-finish.log`、`debian-real/swaps.restored`。 |
| 普通用户与真实空间不足 | **PASS**：`nobody` 可查询实际状态；默认自动容量超过可用磁盘时返回 3，fstab 不变。见 `rootless-status.log`、`auto-insufficient-space.log`。 |
| Alpine 3.24.1/OpenRC/ext4 真实流程 | **PASS（修复后）**：在独立 ext4 数据盘上重新验证旧文件接管、256→512 MiB、同容量幂等及演练；真实关机再启动后 boot ID 改变，唯一目标 512 MiB 文件自动活动。继续缩容、关闭、重复关闭，恢复原 fstab、Swap 活动状态和原厂 `/etc/conf.d/swap`。见 `alpine-fixed-prepare-reboot.log`、`alpine-fixed-finish-reboot.log`、`alpine-results/`。 |
| Alpine 实际依赖安装 | **PASS**：缺少 `findmnt`、`lsblk` 时，非授权执行返回依赖提示；`--install-deps` 使用 APK 安装两者后完成真实操作。已存在的 swapon/swapoff/mkswap 来自 util-linux-misc，blkid 来自独立 blkid 包；没有把 BusyBox 同名工具当作完整查询接口。 |

初轮打包与分发失败由源码同步遗漏根目录 `vpsctl.sh` 导致，补齐后仅重跑这两项并通过。普通用户检查最初受验收源码临时目录的遍历权限阻断，修正该目录权限后通过。初轮新增真实脚本的 ShellCheck 未使用字段诊断已修正；未作为产品故障或通过结果隐去。

首轮 Alpine 重启发现实际产品问题：标准 `/etc/init.d/swap` 声明 `before localmount`，独立数据盘上的 Swap 文件在服务启动时尚不可读，且该服务未把 `swapon -a` 失败传播为服务失败。依照系统自带 `/etc/conf.d/swap` 的说明，修复为受管的 `rc_before`／`rc_need` 配置，使本地文件系统先挂载，并将配置恢复和依赖刷新纳入事务。失败日志保留在 `alpine-finish-reboot.log` 与 `alpine-results-failed-reboot/`；修复后确认依赖缓存包含 localmount，并以实际重启后的 `/proc/swaps`／`swapon --show` 验证成功，没有用服务显示 started 代替实际 Swap 活动验证。

## 复现与恢复

以下命令均在专用 SSH 环境的候选源码目录运行：

```bash
bash tests/unit/test-system-swap.sh
bash tests/unit/test-command.sh
bash tests/unit/test-libraries.sh
bash tests/unit/test-distribution.sh
bash tests/unit/test-release-build.sh
bash tests/integration/test-vpsctl.sh

VPSCTL_REAL_SWAP_TEST=1 VPSCTL_SWAP_RESULT_DIR=/var/tmp/swap-acceptance \
  bash tests/integration/test-system-swap-real.sh prepare-reboot
# 重启该专用测试系统后：
VPSCTL_REAL_SWAP_TEST=1 VPSCTL_SWAP_RESULT_DIR=/var/tmp/swap-acceptance \
  bash tests/integration/test-system-swap-real.sh finish-reboot
```

中途需要单独恢复时，使用同一结果目录运行 `restore`。真实脚本要求分区或无 Swap 的原始状态，避免把用户既有普通 Swap 文件作为可删除测试对象。测试创建的旧文件、新文件均在测试或恢复过程中清理；配置及小型清点备份保留远端供审阅，不复制完整 Swap 数据。

Alpine 使用已有基础镜像之上的独立写时复制磁盘及临时数据盘，基础镜像未改动。验收结束后撤销客机临时挂载、临时 cloud-init 禁用标记及本次新增依赖，恢复原配置并正常关闭虚拟机；两份测试镜像的 `qemu-img check` 均无错误。记录见 `alpine-final-state.log`、`alpine-final-image-check.log`。Debian 宿主的原交换分区和原 fstab 已恢复，Alpine 验收没有修改宿主 Swap 配置。

没有执行默认全套 `tests/run.sh` 或其他功能的真实全套验收。ext2/ext3/XFS 和其他发行版未做真实启动声明；相关能力判断、拒绝行为和软件包映射的测试不代替这些环境的实际验收。
