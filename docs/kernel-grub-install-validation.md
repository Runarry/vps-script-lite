# BIOS GRUB 安装真实验收记录

验收日期：2026-09-08。所有项目执行、静态检查和虚拟机验收都通过 `ssh host-vps-scripts` 在专用环境进行；工作站只编辑文件和查看仓库差异。功能继续保持 `experimental`。

## 隔离环境与恢复基线

测试目录为 `/root/vpsctl-grub-install-20260908/`。宿主本身为 Debian 13 UEFI，运行 XanMod；此次未修改宿主引导配置或重启宿主。QEMU 采用完整 SeaBIOS/TCG 虚拟机、单核、896 MiB 内存，三个发行版串行运行。三个发行版验收 VM 各有独立 qcow2 子覆盖磁盘和一块 64 MiB 数据盘；救援 VM 另挂接 10 GiB 故障副本。

| 虚拟机 | 镜像与布局 | 验收场景 |
| --- | --- | --- |
| Debian 12 | 复用 2026-09-06 验收镜像的子 overlay；GPT，3 MiB BIOS Boot 分区，ext4 根分区，ESP 不参与实际 BIOS 启动 | 保留可解析默认项，清除无效 next_entry |
| Debian 13 | [官方 genericcloud 镜像](https://cloud.debian.org/images/cloud/trixie/latest/)，通过官方 SHA-512 清单；独立 overlay 转换为 MBR，ext4 根分区起点保持 128 MiB | 旧 grub.cfg 无法读取时固定当前内核，清除覆盖 |
| Ubuntu 24.04 | 复用 2026-09-05 已验签官方云镜像的子 overlay；GPT，4 MiB BIOS Boot 分区，同盘独立 ext4 `/boot` | 保留可解析默认项及有效 next_entry；关闭云镜像自动选盘 |

Debian 12 和 Ubuntu 的历史基线均保持关机，测试只写新的子 overlay。Debian 13 分区转换属于一次性测试夹具准备，先保存原 GPT、fstab 和 grub.cfg，再保持根分区的起点与长度转换为 MBR；fstab 改用文件系统 UUID，卸载原 ESP，并显式安装基础 BIOS 引导以核对转换后的真实启动。项目安装流程本身不转换分区表。

宿主保留官方镜像清单和校验日志、原镜像的 backing chain、各 VM 的启动脚本、串口输出、SSH 接入材料和逐阶段日志。私钥只留在专用机，不进入仓库。

## 执行方法与断言

`tests/integration/test-system-kernel-grub-install-real.sh` 是显式选择的破坏性真实测试，不在日常测试中自动执行。它要求 Linux root、SeaBIOS、专用 guest 标记以及 `/dev/vda` 启动盘和 64 MiB `/dev/vdb` 数据盘，避免误用于宿主。

在 VM 内通过宿主的 `guest.sh` 执行，先设置 `VPSCTL_REAL_GRUB_TEST=1`、`VPSCTL_REAL_GRUB_MODE` 和已完整安装的 `VPSCTL_REAL_GRUB_SECOND_RELEASE`，依次运行：

1. `prepare`：保存启动 ID、分区表、内核文件哈希和原 GRUB 配置；建立指定 default/next 场景，移除完整 grub-pc 包但保留 grub-pc-bin，把遗留 debconf 安装目标设置为数据盘。
2. `install`：比较演练前后的 dpkg、debconf、APT/GRUB 文件哈希、磁盘头部和备份列表；通过 CLI 安装后核对默认项、next、包状态、分区表、保留内核、数据盘全盘哈希和备份校验清单。
3. 宿主显式重启该 VM，再运行 `first-boot`：必须看到不同 boot ID 和预期保留或回退内核；有效 next_entry 应已被本次引导消费。
4. `switch`：使用现有 CLI 固定第二套内核；再由宿主重启 VM，运行 `second-boot` 核对第二个新 boot ID 和实际 `uname -r`。
5. 可在第一次重启前执行 `repair`，验证已安装状态下的重复修复仍完成确认和备份流程。

测试不会把 CLI 返回成功等同于固件启动验收通过。VM 的两次重启结果、数据盘未变和可核验恢复材料均为成功条件。

Ubuntu 为构造仅剩 `grub-pc-bin` 的状态，先模拟并在测试子 overlay 中移除 `grub-pc`、`grub-gfxpayload-lists`、`grub-efi-amd64-signed` 和 `shim-signed` 四个包；APT 确认为 0 安装、0 升级、4 移除。两个签名包被 APT 视为 protected，因此夹具准备显式允许该操作。此步骤没有进入产品安装路径；所有内核和 initramfs 的前后 SHA-256 一致，历史基线未修改。直接用 dpkg 移除 grub-pc 的首次准备尝试被依赖检查拒绝，未开始项目安装。

## 实测发现

Ubuntu 24.04 的 `grub-pc` 维护脚本包含 `grub-pc/cloud_style_installation` 分支。本镜像该值实际为 `true`，此时 postinst 会绕过 `install_devices`，直接根据 `/boot` 自动选择磁盘。因此仅清空旧安装设备无法保证包阶段不写引导盘。核心流程现将该键纳入备份和漂移检查，在包安装前及完成后都设置并回读 `false`；原值保留在恢复材料中。测试使用有效分区及 ext4 文件系统的数据盘作为遗留目标，并用执行追踪检查实际 GRUB 调用参数。

## 验收结果

三个发行版的完整流程均通过，包含 6 次验收重启；独立救援恢复及恢复后的启动验证也通过。

| 发行版 | 保留或回退内核 → 切换内核 | 安装及回读 | 两次真实重启 |
| --- | --- | --- | --- |
| Debian 12 | `6.1.0-52-cloud-amd64` → `6.18.49-x64v3-xanmod1` | 安装及重复修复通过 | 通过 |
| Debian 13 | `6.12.107+deb13-cloud-amd64` → `6.12.107+deb13-amd64` | 通过 | 通过 |
| Ubuntu 24.04 | `6.8.0-139-generic` → `7.0.0-31-generic` | 通过 | 通过 |

Ubuntu 实际安装 2 包、0 升级、0 删除；原默认和有效 next_entry 均保持为 GA139。分区表、4 个内核及 initramfs 文件、64 MiB 数据盘的前后 SHA-256 一致，产品引导区及配置备份清单全部校验通过。

Debian 12 首次仅新增 `grub-pc=2.06-13+deb12u2`，保持原 Cloud 默认并清除不可解析的 next_entry；随后完整执行一次重复修复，包计划为空且未升级软件包。两次事务都生成独立备份并通过原内核、数据盘、分区表、默认项和备份内容校验。

Debian 13 初始完全未安装 `grub-pc`。移走原 `grub.cfg` 后，实际计划明确回退当前 Cloud 内核，仅新增 `grub-pc=2.12-9+deb13u2`，清除无效覆盖并生成稳定默认项。128 MiB 的 MBR 与嵌入区备份校验通过；第一次重启进入 Cloud，第二次重启进入标准内核。

`strace --seccomp-bpf -f -e trace=execve` 的完整记录只出现一次 `/usr/sbin/grub-install`，参数为 `--target=i386-pc --boot-directory=/boot --no-floppy /dev/vda`，进程返回 0，没有独立 `--force` 参数。原始 `cloud_style_installation=true` 被保存在备份中，完成后回读为 `false`、安装设备为 `/dev/vda`。维护脚本会打印通用的 `Running grub-install` 提示；该文字不等同于实际执行，因此验收依据 execve 记录。

首次不带 seccomp 过滤的追踪在 TCG 下开销较高。其完整演练已通过；随后在真实命令首轮预检、尚未创建任何产品备份或进入写盘事务时终止整个测试进程组，核对无遗留进程，再使用过滤追踪重跑。中断前快照与最终演练快照一致；这次测试控制调整不计作产品安装失败。相关证据保留为 `stopped-prewrite-*`。

## 救援恢复、自动检查与终态

从成功的 Debian 13 磁盘另建 `debian13-damaged` 子 overlay，清零前 440 字节引导代码并放入循环指令，保留磁盘标识、分区记录和 MBR 签名。SeaBIOS 停在引导入口，CPU 指令指针为 `0x7c00`，SSH 无法连接，确认该副本不能启动系统。

随后关闭故障 VM，以独立 Debian 12 VM 启动救援。`test-system-kernel-grub-install-rescue-real.sh` 先用 `ro,noload` 挂载故障根分区，验证产品备份清单、10 GiB 容量、MBR ID、根文件系统 UUID 和完整分区 JSON。原设备 `/dev/vda` 在救援环境明确映射为 `/dev/vdb`，实际写入始终使用已验证的 `/dev/vdb`，没有直接采用 TSV 的旧设备路径。

复制备份并再次校验、卸载根分区后，恢复精确字节区间 `[0, 134217728)`；恢复后的引导区 SHA-256 与备份一致，分区 JSON 不变。关闭救援 VM 后独立启动该副本，产生新的 boot ID，实际运行与默认均为 `6.12.107+deb13-amd64`，数据盘哈希不变。这次恢复范围为原始引导区，已验证的默认配置继续用于启动。

项目自动检查均在专用宿主通过：

- `validation/final-full-suite.log`：`bash tests/run.sh`，最终 `PASS: all tests`。
- `validation/grub-install-unit.log`：新增安装流程的 9 组回归通过。
- `validation/final-compat-static.log`、`validation/final-test-static.log`：适用静态和格式检查无输出、成功退出。
- 两个真实验收辅助脚本的最终 `bash -n`、`shellcheck -x`、`shfmt -d -i 4 -ci` 均通过；新增救援脚本已纳入测试入口的语法检查枚举。

`debian12`、`debian13`、`ubuntu24`、`rescue` 和 `debian13-damaged` 全部正常停止；故障首次启动使用 QEMU monitor 退出，此时未启动操作系统。相关 qcow2 完整性检查均通过。宿主前后 `uname -a` 完全一致，仍运行 `7.1.13-x64v3-xanmod1`，原交换分区保持不变；最终可用内存约 1.6 GiB、磁盘余约 3.6 GiB。

逐阶段日志、镜像链、产品备份及证据归档保留在各 `vms/<name>/` 目录，每份归档均有 SHA-256 文件。`rescue/recovery-evidence.tar` 包含救援脚本、身份核验和原始恢复材料；`debian13-damaged/recovered-boot.log` 记录恢复后的真实启动。总入口为 `RESTORE.txt`、`matrix.tsv`、`vms-stopped-final.txt` 和 `host-after.txt`，所有路径均相对上述测试目录。历史基线及三个成功验收盘继续保留。
