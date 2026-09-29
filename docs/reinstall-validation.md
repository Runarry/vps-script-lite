# 系统重装真实验收

验收日期：2026-09-29。基于本地 HEAD `bb3aba1` 的未提交工作区；`VERSION` 仍为 `0.8.9`，功能尚未发布。所有项目运行、静态检查和真实功能验收均经 `ssh host-vps-scripts` 在专用 Debian 13 宿主执行，本地只编辑文件和查看差异。最终 `commands/system/reinstall.sh` SHA-256 为 `f97b8fd474a1cea22d225b48beaf35273902adef98a4c0212b3838022cc24e35`。真实准备、复位和 DD 使用前一版 `471721cfcf6f675abc58b4f87259c00beb3d7726dc3a30c1e94737ea3b980b29`；末次修改只调整活动 Bash 进程识别。新系统残留清理已用最终版实际验收。

## 隔离环境和恢复

验收目录：`/root/vpsctl-reinstall-real-20260929/`。宿主运行 UEFI 和 XanMod `7.1.13-x64v3-xanmod1`，本次宿主引导与分区布局保持不变，也没有重启宿主。`host-before.txt` 与末次核对的宿主 boot ID 均为 `d843cc42-f300-4b14-a467-ca213fc7a41f`。结束时本轮 QEMU 和回环 HTTP 服务均已停止，测试挂载点未挂载，宿主根分区剩余约 1.3 GiB。

真实写盘只发生在 QEMU SeaBIOS/TCG 单核、896 MiB guest 的 `/dev/vda`。源 Debian 13 盘来自关机基线 `/root/vpsctl-grub-install-20260908/vms/debian13/disk.qcow2` 的新子 overlay；历史基线没有写入。原根 UUID `a88eaa57-e875-4855-a3cb-c231758653f8`。最终子 overlay 关机后 `qemu-img check` 无错，SHA-256 `9867f96268bee57c0c34b95819cd291b542e95fe78de0328be70380d860cbfd7`、占用 704 MiB。保存 `final-overlay-info.txt`、`final-overlay.sha256`、串口和阶段日志后，已删除该可丢弃子 overlay 回收空间。若需重新验收，在 VM 关机时从基线建立新子盘：

```bash
qemu-img create -f qcow2 -F qcow2 \
  -b /root/vpsctl-grub-install-20260908/vms/debian13/disk.qcow2 \
  /root/vpsctl-reinstall-real-20260929/vm/disk.qcow2
```

此命令恢复原 Debian 测试起点；最终已安装盘本身不再保留。验收目录保留 `alpine-partitioned.raw`、NoCloud seed、测试脚本及阶段日志。guest 私钥只留在专用宿主的 `vm/guest-key`，未进入仓库。

## RAW 镜像与夹具修正

目标文件源自 [Alpine 官方 generic BIOS cloud-init 镜像](https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/generic_alpine-3.24.1-x86_64-bios-cloudinit-r0.qcow2)，下载时 SHA-512 与官方清单一致：`8d756f6fc7653daa4fb4e2e213d8a66007bcb1e5a846e28891af62c47b90685c694486c2746099ad99e9e8f5278db76b69d11dfe1e9361aa4c8406df16929a9c`。测试副本配置公钥、bash 和专用目标标记；Alpine 默认锁定 root 并拒绝其公钥登录，因此副本设置了仅供隔离 VM 使用的密码哈希，SSH 密码验证仍关闭。

官方 Alpine RAW 是整盘 ext4，没有分区表。首次上游 DD 完整写入 512 MiB 后，官方 `partx -u /dev/vda` 返回 1；`failed-dd-serial.log` 保留失败点。这是目标测试镜像布局不符合上游分区刷新步骤的夹具问题。最终保留同一 Alpine ext4，外加标准 MBR 和唯一活动分区：磁盘 640 MiB、MBR ID `0xd68c803c`、分区 1 从扇区 2048 开始且长 512 MiB。已有 Debian guest 的 `grub-install --target=i386-pc` 仅对测试盘 `/dev/vdb` 安装 BIOS GRUB；`sfdisk` 和 `partx` 均列出分区。GRUB 保留原 Alpine extlinux 的 `root=LABEL=/ modules=sd-mod,usb-storage,ext4,ena,gve,mana` 等启动参数，`/etc/fstab` 使用 UUID `7af5430b-f94c-484c-8fe6-36878b6de03a`。首次测试 GRUB 项漏掉 `modules=` 时 initramfs 无法挂载 ext4；补齐后独立 SeaBIOS→GRUB→Alpine 启动及 SSH 均通过。证据为 `build-partitioned-target.log`、`alpine-partitioned-initial-boot-fail.log`、`alpine-partitioned-serial.log`。

最终 `alpine-partitioned.raw` SHA-256 为 `75379a47f0bdb02c935d6f6ac06dab17587bdafa397c803babea55fccedfd97d`。宿主只在回环端口 18080 提供该镜像，guest 经 `http://10.0.2.2:18080/alpine-partitioned.raw` 访问；HEAD 返回 200 和长度 671,088,640 字节。官方上游 `https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh` 原样下载，验收时 SHA-256 为 `5349b7416db39fa87caa0bc3df0f3a8e06e9401f4d3e7ad3031def5b4203fea5`。

## 真实验收结果

| 验收项 | 结果与证据 |
| --- | --- |
| 准备 | **PASS**。`VPSCTL_REAL_REINSTALL_TEST=1 bash /root/test-system-reinstall-real.sh before` 核对 SeaBIOS、专用标记和原根盘。`bash /root/vpsctl-source/bin/vpsctl --no-color --non-interactive system reinstall run -- dd --img URL --username root --ssh-key FILE` 每次下载官方最新脚本，生成 `/reinstall-vmlinuz`、`/reinstall-initrd` 和 `next_entry=reinstall (dd)`；状态占用 56,086,528 字节，准备时未重启或执行 DD。见 `prepare1.log`、`prepared1-check.log`。 |
| 自动复位卸载 | **PASS**。`vpsctl --yes --non-interactive system reinstall uninstall` 先运行保留的官方 `reset`、重建 GRUB，再清理脚本和固定文件，状态回到 0 字节。真实重启后仍为原 Debian 13，boot ID 从 `ae269152-5319-43a8-a0e9-a670e55278a4` 变为 `0f41058a-ef93-47c1-ab71-9db3329e2ac3`；重复卸载回收 0 字节。见 `uninstall1.log`、`uninstall-repeat.log` 和 `vm/serial.log`。 |
| 官方真实 DD | **PASS**。新 Debian 子 overlay 再准备最终 RAW，确认原 UUID、boot ID `5da27a14-ab65-4c0f-b690-40b3fede0f2b` 及待启动项。`final-serial.log` 记录上游 `finalos_distro=dd`、完整写入 671,088,640/671,088,640 字节、`DONE` 和同一 VM 的自动重启。 |
| 新系统接入 | **PASS**。SSH 返回 Alpine 3.24.1，boot ID `575cabd4-4b1f-44be-b6c7-29b941a9c4e3`、根设备 `/dev/vda1` 及目标 UUID；目标标记存在，旧 Debian 标记、旧源码目录和旧包装器缓存不存在。`dd-boot` guest 断言通过。见 `final-guest-state.log`、`final-serial.log`。 |
| 新系统缺旧元数据时清理 | **PASS**。复制最终 SHA 为 `f97b8fd4…` 的源码后，初始状态无脚本、无待启动项、0 字节。建立八个固定残留路径后状态为 9,216 字节；`uninstall` 无需下载上游，逐项清除后为 0 字节。重复卸载仍成功、回收 0 字节。见 `fresh-residues-before.log`、`fresh-uninstall.log`、`fresh-uninstall-repeat.log`。 |

父任务在 `/var/tmp/vpsctl-reinstall-parent-20260929/validation/full-suite.log` 执行 `bash tests/run.sh` 得到 `PASS: all tests`，包含前一版 37 个重装夹具；`distribution-real.log` 的真实安装和离线帮助通过。最终活动进程识别小修后，定向执行 `bash -n commands/system/reinstall.sh && bash -n tests/unit/test-system-reinstall.sh && shellcheck -x commands/system/reinstall.sh tests/unit/test-system-reinstall.sh && shfmt -d -i 4 -ci commands/system/reinstall.sh tests/unit/test-system-reinstall.sh && bash tests/unit/test-system-reinstall.sh`，40 个夹具通过；该输出来自 `/var/tmp/vpsctl-reinstall-unit-20260929` 的远端工具控制台，未保存单独日志，也没有重跑全量。最终真实 guest 脚本的 `bash -n`、`shellcheck -x`、`shfmt -d -i 4 -ci` 通过，见 `harness-static.log`。旧 `test-libraries.sh` 的既有 ShellCheck/格式诊断及 `test-distribution-real.sh` 的既有格式差异，经父任务与旧版对照，不算新增失败。

`host-uefi-status.log` 仅证明宿主 UEFI 上只读 `system reinstall status` 返回无缓存、无待启动项、0 字节；没有在宿主或额外 UEFI VM 执行 UEFI reset/引导写入。Windows 重装参数也没有真实执行。
