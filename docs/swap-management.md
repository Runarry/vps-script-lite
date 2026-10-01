# Swap 管理

`system swap` 查看主机内存与 Swap，设置单个受管磁盘 Swap 文件，或关闭全部受支持磁盘 Swap。它使用独立的 `system-swap` 功能包，只包含 `commands/system/swap.sh`，仅依赖 `shared-command`；不修改 `vm.swappiness`、`vm.vfs_cache_pressure` 或其他 sysctl。

## 接口与容量

```text
vpsctl system swap
vpsctl system swap status
vpsctl system swap set [--size auto|N(M|G)]
vpsctl system swap disable
vpsctl system swap --help

vpsctl --dry-run system swap set --size auto
vpsctl --dry-run system swap disable
vpsctl --yes --non-interactive system swap set --size 2G
vpsctl --yes --non-interactive system swap disable
```

也可独立运行 `bash commands/system/swap.sh`。通过主管理器调用时，全局参数放在 `system` 前；独立调用时放在子动作前。

| 调用 | 行为 |
| --- | --- |
| 无参数 | 交互 TTY 中进入菜单；无 TTY 或使用 `--non-interactive` 时显示状态 |
| `status` | 只读显示 RAM、全部活动 Swap 的类型、容量与使用量、开机配置和建议容量；普通用户可运行 |
| `set` | 默认 `--size auto`，替换全部受支持磁盘 Swap 为一个新的受管普通文件，并配置开机启用 |
| `set --size N(M\|G)` | 采用指定的整数二进制容量；例如 `512M`、`2G` |
| `disable` | 关闭全部受支持磁盘 Swap，删除经核验的旧普通文件，保留 Swap 分区并将其 fstab 配置改为 `noauto` |

`auto` 使用 `/proc/meminfo` 的 `MemTotal`，计算 `ceil(2 × MemTotal / 1 GiB)`，然后限制为 1～8 GiB。例如 512 MiB 内存建议 1 GiB，1 GiB 内存建议 2 GiB，1.5 GiB 内存建议 3 GiB，8 GiB 内存建议 8 GiB。建议值是固定的容量规则，不根据当前 Swap 用量动态缩减。

自定义容量只接受正整数和大写 `M` 或 `G`；`1M = 1 MiB`，`1G = 1 GiB`，最小 64 MiB。不接受小数、裸数字或其他单位。若已有唯一活动的同容量受管文件，且权限、身份与开机配置均符合要求，重复设置直接成功；其他情况按替换流程处理，不累积活动文件或开机条目。

菜单输入框显示计算后的推荐容量，例如 `4G`；回车采用推荐值，输入其他整数 M/G 可修改大小，非法输入会提示重试。真实设置和关闭要求 root，列出计划后执行一次普通确认，默认拒绝；全局 `--yes` 可用于无人值守。若需要安装缺失的可安装依赖，沿用项目的依赖授权流程，非交互使用 `--install-deps`。演练只读取状态和空间、显示操作及依赖计划，不创建锁、目录、备份或候选文件，不初始化、启用或停用 Swap，不修改 fstab 或开机配置，也不安装依赖。

## 支持范围与空间

状态可在 Linux 上查看；实际变更只处理普通磁盘 Swap 文件和 `/etc/fstab` 中的普通磁盘分区。zram、loop、LVM、加密设备、自定义 swap unit、独立 Swap 管理器，以及无法归并到受支持磁盘来源的配置会在系统变更前拒绝。状态仍报告所见来源，拒绝变更不表示这些来源已经停止。状态查询要求 util-linux 的 `swapon`；缺失时提示依赖，不在查询中安装软件。

候选文件固定创建在 `/var/lib/vpsctl/system/swap/`，使用唯一文件名、`dd` 完整写入和 `0600` 权限，随后由 `mkswap` 初始化。承载新文件的文件系统仅接受 ext2、ext3、ext4 或 XFS；不使用稀疏文件，也不将 Btrfs、ZFS、网络文件系统等当作支持后端。

空间检查保留全部旧文件，要求目标文件系统当前可用空间至少为“新文件容量 + 256 MiB 余量”。这相当于同时容纳已有文件、新文件和余量；即将删除的旧 Swap 不能作为可用空间抵扣。空间不足时在创建候选前停止。

开机编排限可识别的 systemd fstab Swap 路径或 OpenRC swap 开机服务。OpenRC 使用标准服务文档规定的配置，在 `/etc/conf.d/swap` 的受管块中追加 `!localmount` 的先后关系覆盖及 `localmount` 依赖，让文件所在本地文件系统先挂载；保留既有配置与依赖变量，更新依赖缓存。关闭功能时只移除该受管块。不能识别开机管理方式时拒绝变更，避免只修改当前活动状态却留下错误的开机行为。上述是实现边界，具体发行版、文件系统和初始化系统的实际验收范围应以对应测试记录为准，不表示所有 Linux 组合均已验证。

## 变更顺序与持久化

设置在独立互斥锁下执行：

1. 检查来源、路径、开机管理、容量、磁盘空间及必要工具，保存 fstab、开机配置与原活动状态的恢复材料。
2. 创建、初始化并启用新的候选 Swap，确认它已经活动。
3. 关闭原有受支持磁盘 Swap；旧普通文件此时仍保留，不删除分区。
4. 原子提交 fstab：移除旧普通文件的 Swap 条目，保留旧分区条目并加入 `noauto`，加入新文件的开机启用条目。
5. 刷新 systemd 或 OpenRC 开机配置，验证活动 Swap 与持久配置。
6. 最后删除身份仍与清点一致的旧普通文件；不删除 Swap 分区。

关闭使用相同的清点、配置恢复和提交边界：先关闭受支持活动 Swap，提交并验证开机禁用配置，最后清理旧普通文件。`swapoff` 可能因可用内存不足而失败；此时保留旧文件，进入提交前恢复，不强行删除仍活动的文件。

| 路径 | 用途 |
| --- | --- |
| `/proc/meminfo`、`/proc/swaps` | 内存与当前活动 Swap 的只读来源 |
| `/etc/fstab` | 普通文件及分区的开机 Swap 配置 |
| `/var/lib/vpsctl/system/swap/swap.*` | 唯一候选文件与受管 Swap |
| `/var/lib/vpsctl/backups/system/swap/<UTC时间>.XXXXXX/` | 每次变更的配置与活动状态恢复材料 |
| `/etc/runlevels/boot/swap` | OpenRC 标准 Swap 开机服务登记 |
| `/etc/conf.d/swap` | OpenRC 本地文件系统先挂载的受管配置块 |

备份目录中的 `fstab` 保存原配置，`fstab.new` 保存待提交配置；`active-swap` 保存原活动 Swap 及其容量、用量和优先级；`sources` 与 `identities` 保存来源及文件身份；`boot-state` 记录初始化系统和原 OpenRC Swap 开机状态。OpenRC 另存 `openrc-swap` 原文件或 `openrc-swap.missing` 缺失标记，以及 `openrc-swap.new` 待提交配置。恢复材料不复制整份旧 Swap 文件。普通 `self uninstall` 与 self 的 `--purge` 不关闭 Swap，也不清理上述功能目录。

## 失败与恢复

提交前失败或可捕获中断会尝试恢复原配置、开机状态和原活动 Swap，再关闭并清理本次候选。若恢复未完成，命令报告问题与恢复材料路径；保留材料后再检查，不能把返回失败视为所有步骤都已自动恢复。`SIGKILL`、主机掉电等无法执行清理的情况需要人工检查。

提交并验证成功后，新配置保持生效。旧普通文件清理失败返回 `30`，报告未完成路径；应先确认当前 Swap 与 fstab 已符合目标，再仅清理报告中仍存在、身份一致且不活动的普通文件。不要为清理失败自动恢复旧配置，或删除一个已经重新用于其他用途的文件。

恢复时先查看实际状态和命令报告的配置／元数据材料：

```bash
vpsctl system swap status
cat /proc/swaps
grep -n 'swap' /etc/fstab
```

如果仍处于提交前状态，在 root 会话中按以下顺序检查和恢复：

1. 核对报告的备份目录，比较 `fstab`、`fstab.new` 与当前 `/etc/fstab`；若当前配置已有其他人的后续变更，先合并相关 Swap 条目，不直接覆盖。
2. 需要恢复原配置时，从备份 `fstab` 恢复对应内容并保留原权限与属主。systemd 使用 `systemctl daemon-reload` 刷新；OpenRC 同时核对并恢复 `/etc/conf.d/swap`（原本缺失时仅清理本次创建且未经外部修改的文件），根据 `boot-state` 的 `openrc_swap_boot` 值恢复原 boot 登记，最后执行 `rc-update -u` 更新依赖缓存。
3. 根据 `active-swap`、`sources` 和 `identities` 核对仍存在的原文件或分区，只重新启用身份一致的原 Swap；原优先级为非负数时，使用 `swapon --priority N -- PATH` 保留优先级，否则使用 `swapon -- PATH`。
4. 再检查当前状态。候选文件只有在已经关闭、原活动状态已恢复且身份确认后才能删除。

不要对备份内容执行 `source`，也不要未经核对运行 `swapon -a`，以免启用其他管理器的条目。

如果处于提交后状态，恢复材料可以帮助恢复配置记录或重建新的等容量 Swap，不能恢复已经删除旧文件的内容。本功能没有整文件备份或“恢复旧 Swap 文件内容”的承诺。

退出码沿用项目约定：`0` 成功，`2` 参数错误，`3` 前置条件不满足，`4` 权限不足，`10` 配置错误，`20` 外部操作失败，`30` 部分完成，`130` 用户取消或中断。以实际错误说明和保留路径判断需要处理的步骤。

## 验证

所有语法、静态、单元、分发和真实系统检查均须通过 `ssh host-vps-scripts` 执行，禁止在当前系统或 WSL 中运行。默认 `tests/run.sh` 包含 `tests/unit/test-system-swap.sh`，并只对 `tests/integration/test-system-swap-real.sh` 做语法检查；真实 Swap 验收需要单独运行后者。

验证范围应包含自动容量和单位校验、rootless 状态、一次确认与无人值守、零写入演练、普通文件和 fstab 分区处理、额外空间检查、不支持来源拒绝、候选启用失败、旧 Swap 关闭失败、开机配置失败、提交前回滚、提交后清理失败与恢复路径，以及首次功能下载和离线缓存。真实验收应记录原 fstab、开机状态、活动 Swap 和恢复结果；容器权限拒绝 `swapon` 的结果只能说明该限制，不能代替真实启用成功证据。

真实脚本显式启用后才运行，并要求原状态只有可恢复的交换分区：

```bash
VPSCTL_REAL_SWAP_TEST=1 VPSCTL_SWAP_RESULT_DIR=/var/tmp/swap-acceptance \
  bash tests/integration/test-system-swap-real.sh prepare-reboot
# 在专用测试环境重启后，继续验收并恢复原配置：
VPSCTL_REAL_SWAP_TEST=1 VPSCTL_SWAP_RESULT_DIR=/var/tmp/swap-acceptance \
  bash tests/integration/test-system-swap-real.sh finish-reboot
```

`run` 运行不含重启的完整流程；`restore` 只恢复同一结果目录保存的原状态。结果目录应使用不含空白字符的独立绝对路径。具体执行结果见 [Swap 验收记录](swap-validation.md)。
