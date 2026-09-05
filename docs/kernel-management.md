# 系统内核管理

`system kernel` 在 Debian/Ubuntu amd64 上清点已安装内核，安装发行版官方内核或 XanMod BBRv3 内核，将指定版本固定为 GRUB 2 默认启动项，并按版本安全卸载不再使用的内核。BBR/qdisc 的运行时与持久化设置仍由 `network bbr` 管理。

本功能处于 `experimental` 生命周期。内核和启动器变更可能导致重启后无法启动，首次使用前必须确认云厂商串行控制台、VNC、救援系统或其他带外恢复入口可用。

## 1. 命令接口

```text
vpsctl system kernel status
vpsctl system kernel install [--type official|cloud|hwe|xanmod]
    [--track auto|main|lts] [--cpu-level auto|v1|v2|v3]
    [--confirm-install INSTALL-KERNEL]
vpsctl system kernel switch --release RELEASE
    [--confirm-switch SWITCH-KERNEL]
vpsctl system kernel uninstall --release RELEASE
    [--confirm-uninstall REMOVE-KERNEL]
```

无参数且连接终端时进入“系统内核管理”菜单；非交互环境无参数时只显示状态。交互菜单按编号提供查看状态、安装/更新、切换默认内核和卸载指定版本，安装类型默认推荐官方标准内核。直接 CLI 省略 `--type` 时仍默认为 `xanmod`，兼容原有安装调用；`--track` 和 `--cpu-level` 只适用于 XanMod。

真实安装、切换和卸载分别要求强确认短语 `INSTALL-KERNEL`、`SWITCH-KERNEL` 和 `REMOVE-KERNEL`，全局 `--yes` 不能绕过。旧短语 `INSTALL-XANMOD-BBRV3` 仅作为 XanMod 安装的兼容输入；其他类型不接受。非交互卸载必须提供完整 `--release`，不再支持无目标地卸载全部 XanMod 包。

安装只增加或更新所选系列，不删除旧内核；切换只固定下一次及以后启动的默认版本，不自动重启。替换当前内核的安全顺序是：安装目标版本、切换默认项、自行重启、确认实际运行版本，再卸载旧版本。

## 2. 支持边界

- 仅支持 Linux 上使用 APT/dpkg 的 Debian/Ubuntu amd64。
- ARM64 和其他架构明确拒绝；不会回退执行第三方安装脚本。
- Docker、LXC、OpenVZ、Podman、systemd-nspawn、WSL 等不能替换宿主机内核的环境拒绝安装、切换和卸载。
- 状态与安装入口不要求 GRUB 2；自动切换只支持可以完整识别菜单项与稳定 ID 的标准 GRUB 2。其他启动器、默认项无法解析、菜单缺失或配置冲突时，切换和无法证明安全的卸载会在写入前拒绝。
- Secure Boot 检查按来源区分：发行版官方签名内核不套用 XanMod 的全面拒绝规则；安装 XanMod 时若 Secure Boot 已启用，或 UEFI 环境中无法可靠判定状态，则在写入前停止。

XanMod 还要求发行版 suite 位于其当前官方发布范围。CPU 等级由本机 `/proc/cpuinfo` 的完整 x86-64 psABI 特征集合判断，不下载或执行 CPU 检测脚本；自动模式最高选择 x86-64-v3，v4 CPU 仍使用 v3。

## 3. 安装来源与候选版本

版本号不写死在项目中。真实安装通过 APT 查询元包的当前 `Candidate` 和事务实际选择的依赖版本，没有有效候选时拒绝安装：

| `--type` | 平台 | 元包与选择规则 |
| --- | --- | --- |
| `official` | Debian/Ubuntu | Debian 使用 `linux-image-amd64`；Ubuntu 使用 `linux-generic` |
| `cloud` | 仅 Debian | 使用 `linux-image-cloud-amd64` |
| `hwe` | 仅 Ubuntu LTS | 使用 `linux-generic-hwe-${VERSION_ID}`，仅在该元包存在适配候选时提供 |
| `xanmod` | Debian/Ubuntu | 使用 XanMod 官方源，保留 `auto`、`main`、`lts` 分支和 CPU 等级选择 |

发行版官方类型只使用系统已经配置的 APT 源。入口在安装前校验候选版本的 Origin 与 suite 属于当前发行版，不能把同名包从未知来源当作官方内核。XanMod 的 `--track` 规则如下：

| `--track` | 选择顺序 |
| --- | --- |
| `auto` | 稳定 main 的当前 CPU 等级到较低兼容等级；缺包时再尝试 LTS |
| `main` | 只尝试稳定 main；官方只提供 x64v2/x64v3 |
| `lts` | 只尝试 LTS；提供 x64v1/x64v2/x64v3 |

因此“最新”只表示执行时相应受信 APT 来源签名发布的当前候选，不表示写死版本或未经选择的滚动分支。

## 4. 来源、状态与受管路径

XanMod 唯一直接下载内容为官方仓库公钥：

```text
https://dl.xanmod.org/archive.key
```

导入前必须只有一个主公钥，且完整指纹严格等于：

```text
D38D7D1DA1349567ADED882D86F7D09EE734E623
```

软件包和仓库元数据随后由 APT 使用专用 keyring 验签。入口不使用 `apt-key`，也不执行远程脚本。

| 路径 | 用途 |
| --- | --- |
| `/etc/apt/sources.list.d/vpsctl-xanmod.sources` | vpsctl 独立 DEB822 XanMod 源 |
| `/etc/apt/keyrings/vpsctl-xanmod-archive-keyring.gpg` | 通过完整指纹验证的专用 keyring |
| `/var/lib/vpsctl/system/kernel-bbrv3/state` | 兼容保留的 XanMod 元包、候选、suite 和 CPU 等级状态 |
| `/var/lib/vpsctl/system/kernel/install-state` | 最近一次成功的 official、cloud 或 hwe 安装选择 |
| `/etc/default/grub.d/99-vpsctl-kernel.cfg` | vpsctl 受管的固定 GRUB 默认项；不覆盖用户 `/etc/default/grub` |
| `/var/lib/vpsctl/system/kernel/backups/` | 切换前的启动配置备份和恢复线索 |
| `/run/vpsctl/system-kernel.lock` | 阻止并发内核事务 |

固定路径存在非受管内容、符号链接或来源指纹漂移时拒绝覆盖。XanMod 安装失败发生在 APT 写入软件包前时，撤销本次新建的源和 keyring；APT 已开始修改系统后的失败保留来源与状态线索并返回部分完成或失败，供人工检查。仅当最后一个已安装 XanMod 包成功移除后，才清理其受管源、keyring 和兼容状态。

## 5. 版本清单与状态

`status` 结合 dpkg 安装状态、包文件归属、`/boot/vmlinuz-*`、`/boot/initrd.img-*`、`/lib/modules/*` 和 GRUB 菜单项，按完整 release 建立清单。人类可读输出对每个版本显示：

- 来源类型以及关联 image、modules、headers 和 meta 包；
- 内核镜像、initramfs、模块目录和正常 GRUB 启动项是否完整；
- 是否为当前运行版本、持久默认版本或已有的一次性 next 启动目标；
- 是否受保护、是否可以由 vpsctl 自动卸载，以及拒绝原因。

无法用 dpkg 文件归属证明来源的手工内核只展示，不纳入自动卸载。处于 unpacked、half-configured 等非正常 dpkg 状态，或缺少必要启动文件的版本会明确标记为不完整，不能作为卸载后的保留启动版本。

## 6. 安装与 APT 事务

建议先查看计划：

```text
bash bin/vpsctl --dry-run --install-deps system kernel install --type official
bash bin/vpsctl --dry-run --install-deps system kernel install --type xanmod --track auto
```

确认后安装示例：

```text
bash bin/vpsctl --install-deps system kernel install --type official \
  --confirm-install INSTALL-KERNEL
bash bin/vpsctl --install-deps system kernel install --type xanmod --track auto \
  --confirm-install INSTALL-KERNEL
```

入口先解析候选，再用 APT 模拟完整事务，逐包验证所选版本的来源。安装计划中出现无法解释的动作、移除软件包或其他不符合所选来源的操作时停止。真实安装固定元包版本，并在安装后核对依赖包版本与已验证计划一致；不使用通配符或 `autoremove`。安装的 `--dry-run` 展示依赖、来源、候选元包顺序和执行步骤，具体版本在真实执行时解析；演练不刷新源、不写配置、不安装包。

APT 内核包的维护脚本负责生成 initramfs 和常见启动项；标准 GRUB 2 环境会刷新并重新读取菜单。安装完成后输出实际解析到的持久默认启动版本；安装本身不会自动将新版本固定为默认，也不会自动重启。

## 7. 固定默认启动版本

先从 `status` 取得完整 release，再执行：

```text
bash bin/vpsctl --dry-run system kernel switch --release RELEASE
bash bin/vpsctl system kernel switch --release RELEASE \
  --confirm-switch SWITCH-KERNEL
```

切换只接受具有完整启动文件和正常 GRUB 菜单项的已安装版本。入口解析 GRUB 子菜单，排除 recovery 条目，并使用菜单中稳定的 entry ID 写入 `/etc/default/grub.d/99-vpsctl-kernel.cfg`，不依赖易变的菜单编号。固定具体版本后，后续内核更新不会自动把默认项移到另一版本。

写入前备份受管配置并检查已有的一次性 next 启动覆盖；next 目标无法解析时安全停止，可以解析时在写入固定默认项后清除，避免它覆盖本次选择。写入后刷新 GRUB 并回读验证默认 ID、release 和 next 状态。任一步失败都尝试恢复备份、再次刷新并验证，恢复信息保留在备份目录。命令不会重启系统；用户应在重启后用 `uname -r` 和 `status` 核对实际运行版本。

## 8. 按版本卸载

卸载必须指定完整 release：

```text
bash bin/vpsctl --dry-run system kernel uninstall --release RELEASE
bash bin/vpsctl system kernel uninstall --release RELEASE \
  --confirm-uninstall REMOVE-KERNEL
```

以下目标始终拒绝卸载：当前运行版本、持久默认版本、一次性 next 启动目标、无法证明 dpkg 归属的手工内核，以及包或启动状态无法安全解析的版本。默认项本身无法可靠解析时也拒绝卸载。删除后必须仍至少保留一个镜像、initramfs、模块目录和正常 GRUB 启动项均完整的版本。

入口根据 release 计算专属 image、modules 和 headers 包，并加入为移除该版本所必需、已经安装且反向依赖目标包的同系列 meta 包。Ubuntu 云镜像自带的 `linux-virtual`、`linux-image-virtual`、`linux-headers-virtual` 也参与官方系列的依赖闭包；对应 HWE 元包仅接受明确的 `YY.MM` 后缀。计划会完整列出这些精确包；移除 meta 包时明确提示该系列将停止自动跟随更新。共享 headers/common 包和其他 release 的包保持受保护。

执行前用 APT 模拟精确 purge。模拟输出包含 `Inst`、`Conf`，出现额外安装或升级，移除超出批准数组，或事务无法完整解析时一律停止；这可以阻止“删除旧版却顺带安装新版”的依赖行为。真实操作禁用自动清理，不使用通配符或 `autoremove`。包事务部分失败时保留状态、受管来源和恢复信息，不宣称已经安全完成。

需要恢复某系列的自动更新时，重新执行对应的 `install --type ...`；XanMod 还应选择所需 `--track`。重新安装元包不会解除已经固定的默认版本，使用新版本仍需显式 `switch`。

## 9. 恢复与验收要求

启动失败时，通过带外控制台选择另一个完整内核或进入救援系统。切换或卸载返回部分完成/失败时不要直接重启，先检查 dpkg、启动文件、受管 GRUB 片段、备份和实际菜单：

```text
dpkg-query -W 'linux-*'
ls -l /boot/vmlinuz-* /boot/initrd.img-* /lib/modules/
cat /etc/default/grub.d/99-vpsctl-kernel.cfg
update-grub
bash bin/vpsctl system kernel status
```

切换备份中的 `dropin` 对应受管的 `99-vpsctl-kernel.cfg`，`grub.cfg` 和 `grubenv` 是当时的启动菜单及环境快照。若备份没有 `dropin`，表示切换前没有该受管片段；恢复时只移除仍带 vpsctl 标记的新增片段。正常恢复后应运行 `update-grub` 并重新核对状态；生成失败时保留原始快照供救援入口恢复，不直接重启。

APT 包事务不能按文件备份整体回滚。部分失败时保留 `/var/log/apt/history.log`、`/var/log/apt/term.log`、`/var/log/dpkg.log` 和 vpsctl 安装状态，用 `dpkg --audit` 确认未完成的软件包；先修复包状态并验证保留内核的启动文件，再决定重启或重试。不要为消除报错而手工删除当前内核、默认项或共享模块。

测试应覆盖官方来源与 suite、候选选择、平台限制、确认短语、演练零写入、半配置包、缺失启动文件、GRUB 子菜单和固定 ID、next/default/current 保护、配置冲突与恢复、meta 反向依赖、共享 headers，以及 APT 意外安装、升级或越界移除的拒绝路径。

所有语法、ShellCheck、格式、单元、集成、分发包完整性及真实功能验收必须通过 `ssh host-vps-scripts` 在专用环境执行，禁止在当前系统或 WSL 中运行项目代码。专用环境必须分别完成 Debian 官方、Cloud、XanMod 和 Ubuntu 官方、HWE 的“安装 → 固定默认项 → 重启核对 → 卸载旧版”流程；模拟结果不能替代相应系统实测。具体环境、版本、检查结果与恢复材料见[验收记录](kernel-validation.md)；功能仍保持 `experimental` 生命周期。
