# 系统内核管理

`system kernel` 安装、更新或安全卸载 XanMod 官方构建的 BBRv3 内核。该入口只管理内核软件包、vpsctl 专用的 XanMod APT 源和签名密钥；BBR/qdisc 的运行时与持久化设置仍由 `network bbr` 管理。

本功能处于 `experimental` 生命周期。内核变更可能导致重启后无法启动，首次使用前必须确认云厂商串行控制台、VNC、救援系统或其他带外恢复入口可用。

## 1. 命令接口

```text
vpsctl system kernel status
vpsctl system kernel install [--track auto|main|lts]
    [--cpu-level auto|v1|v2|v3]
    [--confirm-install INSTALL-XANMOD-BBRV3]
vpsctl system kernel uninstall
    [--confirm-uninstall REMOVE-XANMOD-BBRV3]
```

无参数且连接终端时进入“系统内核管理”菜单；非交互环境无参数时只显示状态。`install` 具有收敛语义：尚未安装时安装当前候选版本，已经安装时由 APT 更新到当前候选版本。

直接 CLI 的非演练安装和卸载必须分别提供 `INSTALL-XANMOD-BBRV3` 与 `REMOVE-XANMOD-BBRV3`；交互菜单要求输入同一强确认短语。`--yes` 不能绕过。脚本不会自动重启。

## 2. 支持边界

- 仅支持 Linux 上的 Debian/Ubuntu amd64 与 APT/dpkg。
- 发行版代号必须位于 XanMod 官方当前发布范围：Debian `bookworm`、`trixie`、`forky`、`sid`，Ubuntu `noble`、`plucky`、`questing`、`resolute`、`stonking`。
- ARM64 没有 XanMod 官方构建，因此明确拒绝；不会回退执行第三方 ARM 安装脚本。
- Docker、LXC、OpenVZ、Podman、systemd-nspawn、WSL 等环境不能替换宿主机内核，因此拒绝安装和卸载。
- 若 `mokutil` 或 UEFI `SecureBoot-*` 变量表明 Secure Boot 已启用，安装会停止；系统以 UEFI 启动但无法可靠读取 Secure Boot 状态时同样会安全拒绝。关闭 Secure Boot、恢复 EFI 变量读取能力，或完成平台适用的签名/注册流程后再重试。

入口从本机 `/proc/cpuinfo` 检查完整 x86-64 psABI 特征集合，不下载或执行 CPU 检测脚本。自动模式最高选择 x86-64-v3；v4 CPU 使用 v3，因为 XanMod 官方说明 v4 对内核无额外收益。

## 3. “最新”版本与分支

版本号不写死在项目中。入口添加 XanMod 官方 APT 源、执行 `apt-get update`，再使用 `apt-cache policy` 查询元包的当前 `Candidate`：

| `--track` | 选择顺序 |
| --- | --- |
| `auto` | 稳定 main 的当前 CPU 等级到较低兼容等级；缺包时再尝试 LTS |
| `main` | 只尝试稳定 main；官方只提供 x64v2/x64v3 |
| `lts` | 只尝试 LTS；提供 x64v1/x64v2/x64v3 |

因此“最新”表示执行时 XanMod 官方仓库为相应元包签名发布的最新候选版本，不表示 edge/rolling 分支，也不依赖参考脚本中某个固定版本。

## 4. 仓库与完整性

唯一下载内容为 XanMod 官方仓库公钥：

```text
https://dl.xanmod.org/archive.key
```

导入前必须只有一个主公钥，且完整指纹严格等于：

```text
D38D7D1DA1349567ADED882D86F7D09EE734E623
```

软件包和仓库元数据随后由 APT 使用该专用 keyring 验签。入口不使用 GitHub 镜像密钥、不执行远程脚本，也不使用 `apt-key`。

| 路径 | 用途 |
| --- | --- |
| `/etc/apt/sources.list.d/vpsctl-xanmod.sources` | vpsctl 独立 DEB822 XanMod 源 |
| `/etc/apt/keyrings/vpsctl-xanmod-archive-keyring.gpg` | 通过完整指纹验证的专用 keyring |
| `/var/lib/vpsctl/system/kernel-bbrv3/state` | 最近一次成功选择的元包、候选版本、suite 和 CPU 等级 |
| `/run/vpsctl/system-kernel.lock` | 阻止并发内核事务 |

这些固定路径存在非受管内容、符号链接或指纹漂移时，入口拒绝覆盖。安装失败发生在 APT 写入软件包之前时，会撤销本次新建的源和 keyring；APT 已开始修改系统后的失败会保留源和状态线索并返回 `20` 或 `30`，供人工检查和重试。

## 5. 安装、重启与启用 BBR

建议先执行：

```text
bash bin/vpsctl --dry-run --install-deps system kernel install
```

确认计划后安装：

```text
bash bin/vpsctl --install-deps system kernel install \
  --confirm-install INSTALL-XANMOD-BBRV3
```

APT 内核包的维护脚本负责生成 initramfs 和常见启动项；如果系统提供 `update-grub`，入口会再显式刷新一次。找不到 `update-grub` 时会提示在重启前人工检查启动器，但不会猜测或覆盖 `GRUB_DEFAULT`。完成后自行重启并验证：

```text
uname -r
bash bin/vpsctl system kernel status
bash bin/vpsctl network bbr status
```

运行内核应带 `xanmod` 后缀。XanMod 把 BBRv3 编译为 `tcp_bbr` 并设为默认实现，但算法名称仍显示为 `bbr`；仅凭通用内核上的算法名无法判断 BBR 代际。需要显式持久化 `bbr`/`fq` 时使用：

```text
bash bin/vpsctl network bbr enable
```

## 6. 卸载与恢复

卸载前必须在 `/boot/vmlinuz-*`、对应 `/boot/initrd.img-*` 和 `/lib/modules/*` 中至少检测到一个非 XanMod 回退内核，否则拒绝。可按发行版先安装：

```text
apt-get install -y linux-image-amd64   # Debian
apt-get install -y linux-image-generic # Ubuntu
```

演练及真实卸载：

```text
bash bin/vpsctl --dry-run system kernel uninstall
bash bin/vpsctl system kernel uninstall \
  --confirm-uninstall REMOVE-XANMOD-BBRV3
```

入口从 dpkg 状态收集并校验每一个确切的 `linux-*xanmod*` 包名，再把数组传给 `apt-get purge`；不会把通配符交给 APT，不会运行 `autoremove`，也不会删除发行版内核。包全部消失且启动菜单刷新完成后，才删除 vpsctl 受管源、keyring 和状态。当前正在运行 XanMod 时仍可卸载磁盘上的包，但当前内核会持续到关机；重启前必须再次确认回退启动项存在。

若启动失败，通过带外控制台选择发行版内核或进入救援系统；若卸载返回 `30`，不要直接重启，应先检查：

```text
dpkg-query -W 'linux-*xanmod*'
ls -l /boot/vmlinuz-* /boot/initrd.img-* /lib/modules/
update-grub
```

## 7. 验收要求

单元测试覆盖参数、CPU 分级、候选包顺序、演练零写入、回退内核门禁、精确卸载列表、禁止 `autoremove`、强确认和受管文件所有权。所有语法、静态、单元、集成及真实包安装/卸载验收必须通过 `ssh host-vps-scripts` 在专用环境执行，禁止在当前系统或 WSL 中运行项目代码。
