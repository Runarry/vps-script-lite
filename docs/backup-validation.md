# 备份真实验收记录

日期：2026-10-30。验收已结束；PASS 结论仅覆盖明确记录的环境与行为，NOT RUN 不代表已验收。

## 环境和执行边界

本次 Debian 13 x86_64 BIOS/ext4 范围的真实后端、Docker/Compose/SQLite、故障保护和空白 VM 整机恢复验收已通过。整机恢复使用原 ISO 并在救援 RAM 补 SSH/基础工具；修复后的新 ISO 与工具包另完成无辅助的原生启动、仓库导入和远端恢复计划补验，未替换旧 sealed 快照。其他平台与数据库未运行项见文末。

全部项目语法、静态和功能检查均通过 `ssh host-vps-scripts` 在专用 Debian 13 x86_64 环境执行。本地仅编辑和只读查看。宿主机 Docker 29.8.1、Restic 0.18.0、发行版 rclone 1.60.1；没有 `/dev/kvm`，使用 QEMU 10.0.11 TCG。

统一应用源码：`/var/tmp/vpsctl-backup-implementation/source`，由主代理同步。
验收目录：`/var/tmp/vpsctl-backup-acceptance-20261030`，下文证据均相对其 `evidence/`。
测试 Docker 资源以 `vpsctl-backup-test-` 开头。未停止宿主机 Docker，未操作宿主机真实磁盘布局，未清理其他历史目录。

测试前宿主机余盘约 3.6 GiB、可用内存约 1.4 GiB。源盘与保留盘使用本目录稀疏文件。源客体首次启动已通过 SSH 确认为 Debian 13、BIOS、ext4、Linux 6.12.107、ReaR 2.7；不以客体启动代替最终恢复启动验收。

## 服务实现

- WebDAV：发行版 `rclone serve webdav`，测试端口 18441，独立目录 `webdav/`。
- S3：rclone 1.75.2 的实验性 `serve s3`，端口 18442，独立目录 `s3/`。兼容性结论仅适用于该实现，未验收 AWS S3、MinIO 或具体商业 WebDAV。
- rclone 1.75.2 官方下载压缩包 SHA256：`349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702`，已与官方版本目录 `SHA256SUMS` 比对。MinIO 官方下载入口返回 HTTP 410，未安装 MinIO。
- Docker fixture/helper：`debian:bookworm-slim`，实际 ID/仓库摘要 `sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3`。

## 已执行检查

| 状态 | 检查与实际结果 | 证据 |
| --- | --- | --- |
| PASS | 两个后端通过公开 CLI configure、probe、init；probe 实际写入、列举、读回并删除测试快照。初始化后 `check --read-data` 为空仓库检查，单独记录，不作为业务数据全量验证 | `repos-run.log` |
| PASS | 两后端各创建两份 12 MiB 随机业务数据快照，使用共享上传/恢复接口读回，`cmp` 逐字节一致；随后公开 CLI `check --read-data` 读完业务数据；`prune --plan` 保留最新完整快照，快照数及完整 ID 断言通过 | `storage-roundtrip-fixed.log`、`acceptance-*-snapshot-*`、`acceptance-*-after-prune.json` |
| FAIL，已修复 | 首次真实上传触发共享 `backup_snapshot_validate` 的 jq 表达式编译错误，候选快照未转完整；实现代理修复后完成上一行定向验收 | `storage-roundtrip.log` |
| PASS | 自有验收脚本远端 `bash -n` 与 `shellcheck -e SC1090,SC1091` | `acceptance-final-static.log` |
| PASS（仅 fixture） | 独立 TCG 源客体正常启动、SSH 可达、读取源业务 proof，随后安装 Docker 并接入单独保留盘 | `rear-fixture.log`、`source-console.log`、`guest-dependencies.log`、`guest-docker-cli.log` |
| PASS | Docker stop 模式实际采集、上传后，删除两个源容器、全部源/恢复镜像 ID、Named/Anonymous 卷及 Bind 源目录，从 S3 快照恢复；核对实际恢复镜像 ID、共享卷关联、640 权限、卷/Bind/可写层文件、SQLite integrity_check 和业务行、原运行/停止状态 | `docker-backup-v2.log`、`docker-destroy-restore.log`、`docker-source-inspect.json`、`docker-restored-inspect.json`；完整快照 `c1b54960fec2cc446b56e178cbffb997fc500e5cc9c2fe674ddf0a268f3965bb` |
| PASS | 不处理 TERM 的真实 PID 1 触发正常停止超时；任务为 capture-failed、未生成快照，运行容器仍运行、停止容器仍停止 | `docker-stop-failure.log`、对应任务 `20261029T171905Z-3132818800/job.json` |
| FAIL，已修复 | Docker 29 的 commit 弃用提示混入镜像 ID，导致镜像保存失败；移除弃用参数并提取实际镜像 ID 后完成上述真实恢复 | `docker-backup-fixed.log`、`docker-backup-v2.log` |
| FAIL，修复后继续 | ReaR 前置清点误将 bpf 视为未覆盖；动态设置 systemd SendSIGKILL 不受支持；Docker 停止导致运行时挂载正常消失而误判变化。分别交实现代理定向修复，未以跳过断言放行 | `guest-system-backup.log`、`guest-inventory.json`、`guest-system-backup-bpf-fixed2.log`、`guest-system-backup-systemd-fixed.log` |
| ABORTED | 网络故障注入错误使用其他验收阶段共用的 S3 endpoint，已中止该用例并恢复服务；不能作为故障验收通过证据 | `storage-network-failure.log` |
| PASS | 实际 Compose v5.5.1 部署，保存源文件与解析 JSON；删除源 Compose 目录、数据库/上传文件、两个容器、网络、SQLite 镜像后从 WebDAV 恢复，SQL integrity_check、业务金额与上传文件通过 | `compose-stop-restore.log`、`compose-source-archive.txt`、`compose-restored-manifest.json`；快照 `2f378fff9aebdce2bf8c7b705ec0d758f2b2dca23ad53e547964b5f08d7383fb` |
| PASS | 实际 SQLite 在线 WAL 写入循环下使用原生 `.backup` 采集；备份后源容器、镜像、DB 目录被删除，从 S3 恢复后 integrity_check、两条业务记录与运行写入通过 | `sqlite-online-restore.log`、`sqlite-online-restore-resume2.log`、`online-restored-manifest.json`；快照 `fa5949c3a2366c1422ccdf4ee909ef879dd3a405da8f25755f4c6d0f1cad5959` |
| PASS | 已有同子网网络和恢复范围外容器的场景明确拒绝恢复，未覆盖该网络；在本任务 fixture 中断开另一个容器并移除专用网络后才继续恢复，再接回 fixture 容器 | `sqlite-online-restore.log`、`sqlite-online-restore-resume.log`、`sqlite-online-restore-resume2.log` |
| PASS（复用主代理证据） | `tests/unit/test-libraries.sh`、`test-distribution.sh`、`test-release-build.sh`、`tests/integration/test-vpsctl.sh`，均由主代理在 SSH 固定 integration-source 上运行；分发/发布包已针对新 tools.sh 重跑，其余结果复用 | `/var/tmp/vpsctl-backup-implementation/evidence/libraries.log`、`distribution-final.log`、`release-build-final.log`、`entry.log` |
| PASS | 实际 32 MiB tmpfs 暂存区不足，停服前失败；运行/停止容器状态及原完整快照 ID 不变 | `docker-space-failure.log`、`docker-space-output.log`、`space-*-snapshots.json` |
| PASS | 实际宿主机服务持续打开并写入容器 Bind 文件；未声明服务时备份拒绝，声明 `--host-service` 后正常停服、采集、恢复服务和容器状态 | `host-shared-writer.log`、`uncoordinated-writer.log`；快照 `2c266a1263f208e824d22ffcae51bd92af54b33cc32e0e4d7a6f7452810e3d0d` |
| PASS，含人工恢复步骤 | 独立端口 18443、独立 fault-restic 仓库，观察真实 50 MiB 上传的新数据对象后停止该服务，Restic 被明确中断/强制终止，任务返回 20、旧完整快照保留、封存材料不变。确认进程死亡后只清理此仓库的陈旧锁，再重传同一任务，业务 StartedAt 不变，`check --read-data` 通过。此结论不包含“SIGKILL 后自动清锁重试” | `storage-interrupted-upload.log`、`interrupted-upload-output.log`、`interrupted-upload-status`、`interruption-after-failure.json`、`storage-interrupted-upload-recovery.log` |
| PASS | S3 使用拒绝的实际访问密钥，probe 返回 20 / Access Denied；旧完整快照及原业务状态不变 | `repository-auth-denied.log`、`auth-denied-output.log` |
| ABORTED，服务限制 | 实验性 rclone S3 `--read-only` 将拒绝写入映射为 HTTP 500；Restic 前置读取会创建仓库锁，因此该用例尚未进入采集/上传阶段。不能将其称为上传权限失败验收 | `docker-permission-retry.log`、`docker-permission-output.log` |
| PASS（采集/传输） | ReaR 在源 Debian 13 BIOS/ext4 客体生成约 160 MiB ISO、958 MiB 系统 tar，原 Docker/containerd/SSH 及业务状态恢复；S3 完整快照 `7eaf289ea709501a1ce64801af4f6897fef16d1bb728da983dbb6637d055b046` 上传成功 | `guest-system-backup-libs-fixed2.log`、`source-after-backup-status.log`、`native-system-rear.log`、`native-system-backup.log` |
| PASS（材料读回） | 关闭源客体后，清理旧本地 collection，从 S3 重新恢复 1.087 GiB 材料；Restic --verify、全部封存 SHA、完整 tar 读取通过；正式导出含 flock 和动态库的恢复工具包。读回通过后才删除源 raw 镜像，之后无法读取原 VPS | `system-pull-recovery.log`、`system-remote-restored-manifest.json`、`system-restored-disklayout.conf`、`deleted-source-image.sha256` |
| FAIL，2.7 兼容组合 | 同快照原始 ISO 启动空白 vda、独立 holding vdb 时，systemd-udevd/udev-trigger/sysinit 服务失败，无 DHCP/救援 SSH；尚未开始重分区或恢复，不能声明整机恢复已验收。原 serial 文件后来被新尝试复用；相同失败的独立诊断重现日志保留，原 ISO 未改 | `rescue-static-diagnostic.log`、`diagnostic-console.log`、`diagnostic-console-v2.log`；诊断 initrd 仅增加日志 unit，不代替正式 ISO |
| PASS（仅 fixture 重建） | 按主代理授权，从已校验 tar 手工重建测试源机并安装 BIOS GRUB，补运行时挂载目录，重新启动 Docker 并核对业务 SHA。此步骤只为在受管 ReaR 2.9 上重新采集，绝不算产品恢复验收。旧 2.7 ISO 与 sealed 快照保留 | `rebuild-source-v29-fixture.log`、`rebuilt-v29-source-ready.log`；原失败介质 `rescue-2.7.iso` |
| PASS（工具准备） | 在新源 fixture 上通过应用 `--install-deps` 实际从固定官方资产下载、校验并使用受管 ReaR 2.9；系统 dpkg 的 ReaR 2.7 保留。新计划名 acceptance-system-v29，不清理旧计划快照。正式新恢复点及恢复验收见后续 f8f 行 | `managed-rear29-proof.log`、`system-v29-configure-run.log` |
| ABORTED，已定位实现问题 | 首次 2.9 构建中，严格 tar 包装路径进入 ReaR PROGS，可能覆盖 ISO 原生 tar；在生成可交付恢复点前中止，collection-failed、services_recovered=true、原 Docker/containerd/容器 active。修复应只在 PRE_BACKUP_SCRIPT 阶段切换包装 | `v29-wrapper-collision-rear.log`、`system-v29-configure-run.log` |
| PASS（2.9 采集/读回），FAIL（BIOS 引导） | 修复后生成新完整点 `5cf14e06856a7bbc909ac2dcb745af77087c11a80b6533a0e68ba6d9430e693c`，重新取回 1.105 GiB、25 文件 verify 和完整 tar 通过；删源后实际 BIOS 启动停在 `Failed to load ldlinux.c32`。只读检查 ISO 缺全部 .c32 模块，未进内核，不可声明恢复通过 | `system-v29-tarfix-run.log`、`v29-pull-recovery-after-shutdown.log`、`rescue-v29.png`、`v29-bootloader-files.log` |
| PASS（BIOS 介质与读回） | 新恢复点 `f8f503cb033fe7178d3d59fc0ee77c67ebb046e21373de6d82c584fcdd8f18df` 使用真实 Syslinux 6.04，ISO 包含并比对 5 个必需 .c32；从 S3 冷读回 1.204 GiB、25 文件，Restic verify、封存 SHA 与完整 tar 读取通过，再删除源 raw。原生 ReaR 2.9 ISO 实际启动、udev 与 DHCP 正常 | `system-v29-bios-run.log`、`bios-iso-real-modules.log`、`bios-pull-recovery.log`、`bios-native-backup.log`、`deleted-source-f8f503cb033fe7178d3d59fc0ee77c67ebb046e21373de6d82c584fcdd8f18df.sha256` |
| FAIL（旧介质，修复见补验） | 原始 2.9 ISO 未包含 OpenSSH 10 的 sshd-session/sshd-auth 及完整依赖。按授权仅从同一已校验 tar 提取到救援 RAM，辅助控制通道建立；ISO 和 sealed 快照均未修改，不能称原介质 SSH 验收通过 | `rescue-f8f503cb033fe7178d3d59fc0ee77c67ebb046e21373de6d82c584fcdd8f18df-console.log` |
| FAIL（旧工具包，修复见补验） | 工具包全部 SHA 通过，但 import-repo 因缺少 install 返回 command not found；从同一已校验 tar 仅提取 usr/bin/install 到救援 RAM，ldd 闭包已存在，再继续。修复后无辅助定向验收见最后一行 | `f8f-rescue-restore-controller.log`、`rescue-install-ram-assistance.log` |
| PASS（真实恢复与防护） | 在原计划/任务状态均不存在的救援环境导入仓库；目标映射到 holding 盘被拒绝、错误令牌被拒绝，负例前后 vda 首 MiB SHA 相同、vdb UUID 不变。正确令牌执行真实 ReaR recover，恢复 1076 MiB、重建 initramfs、安装 GRUB、产品 post marker 成功。仅已排除的任务临时配置产生一致性警告 | `f8f-rescue-restore-install-assisted.log`、`f8f-recovery/` 下的 `holding-rejected.log`、`wrong-token-rejected.log`、`blank-disk-*.sha256`、`native-rear-recover.log`、`system-restore-run.log` |
| PASS（独立启动与业务） | 不挂 ISO，仅从恢复盘启动；实际 SSH 登录、ssh/docker/containerd/networkd active，容器卷/Bind 上传/可写层内容、3 项业务 SHA、SQLite integrity_check 与订单金额全部一致；DHCP/DNS 可达，machine-id 与 SSH host key 更新，cron masked、备份 timer 暂停，failed units 为 0 | `f8f-restored-business.log`、`restored-console.log` |
| PASS（最终无辅助补验） | 最终源码只生成 mkrescue（不采集 tar、不上传、不停业务），新 ISO SHA256 为 `9062c6d6146ce485f90abfa84f5afa120c8c7ace4be45ff0f91eea30314b6aea`。新 ISO 原生 SSH 登录、两个 helpers 的完整 ldd 闭包、原生 install/GNU tar 均通过；新版工具包完整 SHA、import-repo、独立 bin/install 均通过。再次从 S3 取回 1.204 GiB，Restic verify 25 文件和封存校验后生成 f8f 恢复计划，空白目标盘首 MiB SHA 不变。未补 RAM 程序，也未再次执行 recover | `sshfix-mkrescue-only.log`、`sshfix-build/`、`sshfix-native-rescue-verify.log`、`sshfix-final/`、`sshfix-iso.sha256`、`sshfix-source-sha256.txt` |
`storage-roundtrip-fixed.log` 在两后端 PASS 后出现一次 `--helper-image: command not found`，原因是验收代理在 shell 尚未退出时替换了正在执行的验收脚本，改变了后续读取位置；此前各断言已执行且有效。这不是应用缺陷。后续阶段采用固定的运行脚本副本，避免执行中替换。

主要执行方式：

```bash
VPSCTL_BACKUP_REAL=1 bash /var/tmp/vpsctl-backup-real.sh services
VPSCTL_BACKUP_REAL=1 bash /var/tmp/vpsctl-backup-real.sh repos
VPSCTL_BACKUP_REAL=1 bash /var/tmp/vpsctl-backup-real.sh storage-roundtrip
VPSCTL_BACKUP_REAL=1 bash /var/tmp/vpsctl-backup-rear-real.sh prepare
VPSCTL_BACKUP_REAL=1 bash /var/tmp/vpsctl-backup-rear-real.sh boot
```

脚本中的仓库/任务状态使用 `VPSCTL_TESTING=1 VPSCTL_SYSTEM_ROOT=<验收目录>/root` 隔离；实际服务、Restic、Docker 和 QEMU 均为真实实现。

## 复用的模块专项结果

以下检查同样通过 `ssh host-vps-scripts` 执行，复用已有通过结果，未重复运行：

- 共享仓库回归覆盖候选/完整快照、成功材料清理、失败及未知材料保留、保留策略失败和旧任务重传。真实 local 仓库证据：`/var/tmp/vpsctl-backup-storage-dev/staging-maintenance-final.log`。
- Docker 的 15 项专项回归、系统备份的恢复保护、严格 tar 退出状态和 SSH helper 依赖回归通过；相关 Bash/Python 语法、ShellCheck 和适用文件的 shfmt 检查通过。
- 调度回归覆盖 cron 匹配、锁、同分钟去重和独立运行版本；真实 systemd 验证在原管理器目录移走后仍能执行。证据目录：`/var/tmp/vpsctl-backup-schedule-work`。真实非 systemd cron daemon 与实际调度升级未验收。

## 未运行与适用范围

ReaR 从远端快照到空白 VM 并启动、本地计划/任务状态丢失后的恢复均已 PASS（使用 RAM 补救援控制工具，限定见表）。修复后的原生救援 SSH、新版工具包自举与真实远端恢复计划均已 PASS（最终 mkrescue-only 补验，无 RAM 辅助，不重复完整恢复）。操作级只读权限、调度升级在本验收阶段为 NOT RUN。认证拒绝与上传中断、空间不足、停止失败、宿主机共享写入的已验证范围见上表。

ARM、UEFI、XFS、LVM、RHEL 系、rootless/userns、跨架构及商业云存储未运行，不继承本记录结论。

## 恢复和清理信息

验收期间的 WebDAV/S3 和 QEMU 均在专用目录内，SSH 仅通过宿主机 `127.0.0.1:22440` 转发。最终已正常关闭专用 VM，确认无 loop 使用后移除 source/restored/holding 三个测试 raw，专属 WebDAV/S3 端点已停止、PID 文件已清理。凭据仅为本任务创建的测试值，配置文件 0600，目录 0700；报告不记录真实业务凭据。

已完成 Docker/Compose/在线 SQLite 及仓库往返后，仅移除了本任务的重复 staging/download 和随机输入，恢复清单已另存 evidence，普通 WebDAV/S3 往返仓库已在证据保存后清理；整机 whole-system 仓库和旧系统快照保留。稀疏镜像使用 discard=unmap；ReaR 构建结束后执行 `sync; fstrim /mnt/holding`，释放已删除的构建临时块，避免把 guest 已释放空间误当成 host 可用空间。

独立故障仓库 `fault-restic` 在所有结果和全数据读回证据保存后已清理。旧 2.7/2.9 系统快照保留，失败 ISO 已转存下述制品目录。无效的共用 endpoint 注入和只读 500 用例仅保留历史 ABORTED 证据，不保留为可复用验收入口；正式故障脚本使用独立 endpoint 和独立仓库，并记录强杀后的显式 stale-lock 清理。

首轮 ReaR 2.7 采集的原生 tar 日志为 `native-system-backup.log`，归档为 1,004,103,680 字节；扫描只见正常的去除绝对路径前缀提示，未见源读取失败、权限或 I/O 错误。严格 tar 包装的缺文件回归另行验证；最终 f8f 的实际采集与恢复证据见上表。




原失败 ISO 已按字节校验后转存到本机允许的制品目录，宿主机重复副本清理：
`D:/ProgramData/.codex/visualizations/2026/10/29/01a1887b-d641-76e2-815f-ed2ab277de11/backup-acceptance-failed-rear-2.7.iso`、`backup-acceptance-failed-rear-2.9-missing-c32.iso`。校验证据为 `preserved-failed-isos.sha256`，旧 sealed 快照未修改。

f8f 恢复盘独立启动并验证业务后，已移除 holding 中该恢复点的重复 payload（约 1.2 GiB），保留正式工具包、恢复计划、原生日志和 S3 全部整机快照。执行 sync/fstrim 后宿主机 df 可用 509 MiB，真实空闲（含 root 保留）约 1.415 GiB，见 `post-restore-duplicate-cleanup.log`。

最终 SSH/工具包补验源码冻结在 `frozen-system-sshfix/`，核心模块 SHA256 见 `sshfix-source-sha256.txt`。核心恢复使用 `frozen-system-recovery-bios/` 导出的同组恢复工具，工具包自身 `SHA256SUMS` 校验通过；后续 SSH/工具包补丁未改变已经验证的 f8f sealed 归档。已验收恢复盘的 UUID、clone 身份与首次启动 journal 保存于 `restored-disk-before-cleanup.log`。


最终清理完成，见 `final-cleanup.log`：专属 QEMU 已关闭，`source.raw`、`restored.raw`、`holding.raw` 均不存在；自有 WebDAV/S3 服务已停止，宿主机 Docker 一直运行，原有 submeld 容器仍 healthy。测试容器、卷、网络、写入服务及普通/故障仓库已清理。宿主机 df 最终可用约 1.8 GiB，真实空闲（含 root 保留）约 2.64 GiB。

保留内容：验收目录下 `s3/`（约 1.4 GiB，whole-system 三个系统恢复点及探测骨架）、`evidence/`（约 17 MiB）、最终 `rescue.iso`（约 156 MiB）、`recovery-kit-sshfix/`（约 26 MiB）、冻结源码和测试凭据。测试端点已经停止，需复查仓库时用原测试服务配置启动；旧普通仓库快照 ID 仅用于对照历史证据，不再保证可下载。

f8f 原 ISO 的 SSH 缺依赖介质另存：`D:/ProgramData/.codex/visualizations/2026/10/29/01a1887b-d641-76e2-815f-ed2ab277de11/backup-acceptance-rear-2.9-f8f-ssh-gap.iso`，已通过传回专用远端 cmp/SHA 验证。最终新 ISO 和工具包为修复后定向补验产物；f8f sealed 快照内原始 ISO 未替换。

NOT RUN：ARM、UEFI、XFS、LVM、RHEL 系、rootless/userns、跨架构、PostgreSQL/MySQL/MariaDB 原生数据库适配、具体商业 S3/WebDAV、操作级只读写入权限，以及本验收阶段的调度升级。SQLite stop/online 与 Compose 的实际业务恢复为 PASS；主代理的库/分发/发布/入口结果按表复用。历史 FAIL/ABORTED 保留用于说明问题和修复，不将未执行项归为通过。

## 2026-10-30 审查缺陷修复回归

本轮仅修复在线挂载覆盖、DHCP 恢复前置检查、过期快照本地清理阻塞和恢复工具包凭据冲突。全部检查通过 `ssh host-vps-scripts` 执行；本地未运行项目测试、语法或静态检查。

| 状态 | 范围与结果 | 远端证据位置 |
| --- | --- | --- |
| PASS | `test-backup-docker.sh` 共 23 项测试。PG/MySQL/MariaDB 的 bind/volume 混合数据拒绝，合法根目录/子目录、多适配器和应用 hook 通过；路径映射及读取错误拒绝，准备/采集失败不导出或生成完整清单；不同仓库的恢复模板秘密路径隔离 | `/var/tmp/vpsctl-backup-fixes-docker-20261030/source`；执行结果在本轮 SSH 工具输出 |
| PASS | `test-system-backup.sh`。真实小型封存 tar 覆盖 networkd/resolved 单元和程序缺失、不可执行、常见目录、软硬链接、mask、实际 ExecStart、显式 DNS、preserve 和旧 schema 1；两条恢复入口失败均未调用 ReaR，检查不执行归档程序 | `/var/tmp/vpsctl-backup-fixes-recovery-20261030/source`；执行结果在本轮 SSH 工具输出 |
| PASS | 同一整机专项测试实际导出并调用 `import-repo`：双仓库的密码、访问凭据、CA 隔离；非法输入不发布、同名拒绝、配置锁互斥；复制/原子发布失败仅清理本次秘密，发布后 TERM 不删除已引用秘密；保留 local 可携带第二参数的兼容行为 | 同上；使用宿主机已有工具替代包内重复二进制，校验、导入及文件发布执行真实代码 |
| PASS | `test-backup-repo.sh` 使用真实本地 Restic：旧失败任务重传并被手动 prune 后，保留封存材料并记录跳过原因，下一次备份上传/维护成功；查询错误、格式异常及仍存在的损坏快照继续失败 | `/var/tmp/vpsctl-backup-fixes-storage-20261030/test-final.log`，对应源码在同目录 `source/` |
| PASS | 修改的 Bash 文件通过语法与 ShellCheck 检查，Docker 引擎通过 Python 编译检查 | 各模块上述专用验证目录及本轮 SSH 工具输出 |

额外定向验证确认：Restic 0.18.0 的 `snapshots --json` 在快照对象损坏时可能输出空列表但返回 0。因此本地清理通过 `list snapshots` 的原始对象 ID 清单判断是否缺失，再对仍存在的对象执行原有完整性检查；已增加真实损坏对象回归。暂时生成的损坏仓库副本与测试夹具已清理，未更改旧验收仓库或宿主机业务。

本轮未重复完整 VM 磁盘恢复/启动、原生 PostgreSQL/MySQL/MariaDB 端到端恢复，也未重跑无关全套测试。在线数据库回归模拟目录查询，实际执行文件系统覆盖检查；整机回归使用真实小型 tar，并替换磁盘和 ReaR 边界。以上结果只证明本轮修复范围，不扩展前文的真实平台与业务恢复验收结论。


