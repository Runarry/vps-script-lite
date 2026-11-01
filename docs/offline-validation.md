# 离线分发验收记录

本文保留 2026-11-01 原 UFW/RFW 版本的历史验收证据。当前原生 nftables 版本已改用 `network-nftables` / `shared-nftables`，离线上游仅含 Xray、sing-box、lego，系统依赖不再含 UFW；下文旧包摘要、DEB 数量、RFW/UFW 结果不代表当前版本通过，须以新源码对应的验证记录为准。

## 验证范围

分发导入验收使用真实 `build-release.sh` 构建的全部功能包。上游二进制与 DEB 为不执行、不安装的惰性夹具；这些测试验证包完整性、导入事务和管理器生命周期，真实二进制、APT 依赖闭包和业务服务验收另行记录。

- `tests/unit/test-offline-distribution.sh`：完整包导入、同版本在线缓存补全、跨版本导入、原解压目录删除后功能缓存恢复，以及提交失败回滚。
- 16 个拒绝用例：缺包、错误平台/版本、内容摘要损坏、组件摘要与根清单不一致、重复记录、未登记文件、符号链接、路径越界，以及内部摘要重新生成后的恶意/缺文件功能归档。
- `tests/integration/test-offline-distribution-real.sh`：真实标准安装路径上的公开入口首次离线安装、在线延迟安装、同版本补全、已安装快速路径前处理 `--offline-dir`、互斥参数拒绝和离线 `self update`。
- 既有 `test-distribution.sh`、`test-distribution-real.sh`：在线分发回归。

## 环境与执行

2026-11-01，所有构建、语法检查和测试均通过 `ssh host-vps-scripts` 执行。专用主机为 Debian 13 / amd64；使用现有 Bash、GNU tar、dpkg-deb、ShellCheck。测试分发版本为 0.10.0 → 0.10.1。

远端工作目录：`/root/vpsctl-offline-acceptance`。证据目录：`/root/vpsctl-offline-acceptance/evidence`。

```sh
cd /root/vpsctl-offline-acceptance
for script in tests/unit/test-offline-distribution.sh tests/integration/test-offline-distribution-real.sh; do
  bash -n "$script"
done
shellcheck tests/unit/test-offline-distribution.sh tests/integration/test-offline-distribution-real.sh
bash tests/unit/test-offline-distribution.sh
bash tests/unit/test-distribution.sh
bash tests/integration/test-offline-distribution-real.sh
bash tests/integration/test-distribution-real.sh
```

## 结果

| 检查 | 状态 | 证据 |
| --- | --- | --- |
| 新增测试脚本语法及 ShellCheck | PASS | `evidence/test-static.log` |
| 离线导入单元验收 | PASS | `evidence/offline-unit.log` |
| 既有在线分发单元回归 | PASS | `evidence/distribution-unit.log` |
| 离线公开入口真实验收 | PASS | `evidence/offline-real.log`，含基线恢复 PASS |
| 既有在线分发真实回归 | PASS | `evidence/distribution-real.log` |

代码状态记录在 `evidence/source-sha256.txt`（初始同步）、`evidence/final-source-sha256.txt`（最终同步），主机信息在 `evidence/environment.txt`。离线单元用例在最终 helper 上运行；真实入口及在线回归结果复用同一实现的有效结果，随后仅增加输入完整性检查和离线 helper 缺失时的拒绝联网分支，未改变这些有效路径。

追加的独立回归也已通过：新 CLI 子进程中 `.offline` 仍存在，但 `lib/offline.sh`、共享库和功能缓存均已删除时，命令失败且没有 curl/wget 调用，也未重新填充缓存。记录位于更新后的 `evidence/offline-unit.log`；新增真实服务脚本及单元脚本摘要位于 `evidence/offline-services-test-sha256.txt`。

再追加两项真实 TERM 中断回归：同版本补全从缺少功能缓存的在线旧 release 开始，包装 `mv`，先执行真实重命名，再立即向 importer 的 `BASHPID` 发送 TERM。分别覆盖旧目标移动到 `previous-release` 后，以及候选 staging 发布到目标路径后；注入命中标记必须存在，退出码必须为 `143`，完整文件摘要与 current 链接必须恢复到原部分缓存状态，并移除导入锁。旧实现的暂存旧 release 场景稳定复现失败，修复后两项及整个离线单元验收均 PASS。证据为 `evidence/offline-signal-before-fix.log`、`evidence/offline-signal-before-fix.sha256`、最终 `evidence/offline-unit.log` 和 `evidence/offline-signal-final.sha256`。这次变更只调整导入中断窗口，先前真实服务成功路径结果继续有效，未重跑服务。

验收定位并修复了两个缺陷：bootstrap 的只读安装路径变量与子进程环境传递冲突，导致同版本补全失败；组件清单摘要未与上游文件核对，导致内部摘要不一致的包仍可激活。前者修复后真实生命周期通过；后者最小复现保留在 `evidence/component-hash-reproduction.log` 与 `evidence/component-hash-source-sha256.txt`，最终单元记录证明已拒绝。初期夹具 URL 和通用 `VERSION` 变量冲突已在测试代码修正，不作为产品缺陷。

未在本组测试中运行：真实上游二进制执行、APT 安装/升级、八平台包的依赖闭包和业务服务验收。这些需另由对应构建与运行时验收确认，不能由本记录的惰性夹具替代。

## 恢复约定

真实离线分发用例在改动前备份 `/usr/local/bin/vpsctl`、`/usr/local/lib/vpsctl`、`/var/lib/vpsctl/self`；退出时恢复并比较全部文件 SHA256 与符号链接。只有恢复成功才删除临时备份；失败时输出并保留 `/root/vpsctl-offline-distribution-real.*` 恢复目录。本次恢复检查通过，临时备份已清理。用例不启动、停止或修改业务服务，也不安装夹具 DEB。

## Debian 13 amd64 实包的真实服务验收

新增 `tests/integration/test-offline-services-real.sh`，仅在 root、真实 systemd、UFW 原为 inactive 且显式设置 `VPSCTL_REAL_OFFLINE_SERVICES_TEST=1` 时运行。本次使用构建器的真实离线包，不使用上述惰性夹具。成功路径验收后，仅增加包内说明文件和导入中断窗口修复；依赖资产及服务成功路径不变，复用本组结果。

- 包：`vpsctl-offline-0.10.0-debian-13-amd64.tar.gz`
- 包 SHA256：`7fe5382c6d226a4599827fd546d01c4f2c3a5d4cb539583425ba521a31e35fde`
- 执行记录：新加坡时间 `2026-11-01 02:25:15`（原始日志为 `2026-10-31T14:25:15-04:00`），完整操作输出位于 `evidence/offline-services-run.log`。
- 详细证据：`/root/vpsctl-offline-acceptance/evidence/offline-services/`。

通过 SSH 在专用主机执行：

```sh
cd /root/vpsctl-offline-acceptance
bash -n tests/integration/test-offline-services-real.sh
shellcheck tests/integration/test-offline-services-real.sh
VPSCTL_REAL_OFFLINE_SERVICES_TEST=1 \
VPSCTL_OFFLINE_PACKAGE=/root/vpsctl-offline-build/dist/offline/vpsctl-offline-0.10.0-debian-13-amd64.tar.gz \
VPSCTL_OFFLINE_SERVICES_RESULT_DIR=/root/vpsctl-offline-acceptance/evidence/offline-services \
bash tests/integration/test-offline-services-real.sh
```

| 检查 | 状态 | 证据 |
| --- | --- | --- |
| 新增真实服务脚本 Bash 语法与 ShellCheck | PASS | `evidence/offline-services-static.log` |
| 最终包导入后删除原解压目录，后续服务仍从保留资产运行 | PASS | `import.log`、`installed-manifest.sha256` |
| Xray 26.10.31 与 sing-box 1.14.4 从包内新安装，owned=true，配置检查成功，服务 active/enabled | PASS | `*-install.log`、`*-version.txt`、`*-config-check.log`、`proxy-status.json` |
| TCPing 启动、四次本地连接后主动关闭、停止、卸载、删除功能缓存后再次调用从本地恢复 | PASS | `tcping-*.log`、`acceptance.log` |
| iperf3 启动、短时 localhost 实际数据传输、本地 APT 更新、停止与卸载 | PASS | `iperf3-*.log`、`iperf3-client.json`、`apt-calls.txt` |
| APT 全局缓存清理后，保留的离线 DEB 池逐文件摘要不变 | PASS | `apt-pool-before-clean.sha256`、`apt-pool-after-clean.sha256` |
| 全流程未调用项目 PATH 中的 curl/wget | PASS | `download-calls.txt` 为零字节 |
| 原文件内容/模式/链接、服务运行与自启状态、iptables/ip6tables 规则恢复 | PASS | `paths-before.txt`、`paths-after-restore.txt`、`services-*.tsv`、`firewall-*.txt` |

本地 APT 更新实际通过临时独立索引和唯一 `file:/usr/local/lib/vpsctl/releases/0.10.0/.offline/apt` 源调用，参数完整保存在 `apt-calls.txt`。本次更新未改变系统软件包版本，`package-changes.diff` 为空；iperf3/libiperf0 保持 `3.18-2+deb13u2`，libsctp1 保持 `1.0.21+dfsg-1`。

为防止复用旧内核，本次先停下并暂存外部 `/usr/local/bin/xray`、`/usr/local/bin/sing-box` 及原代理状态。退出时恢复原 `vpsctl-proxy-xray`、`vpsctl-proxy-sing-box`、`vpsctl-proxy-forward` 为 active/enabled；TCPing 与受管 iperf3 恢复 inactive/not-found，原生 iperf3 恢复 inactive/disabled。原 UFW 配置、共享状态、APT archives 缓存也已恢复，UFW 保持 inactive。大目录通过同文件系统移动暂存，避免重复占用空间；恢复通过后已清理暂存资产。

本组真实服务验收未执行 ACME 签发、外部 DNS/NTP、公网代理传输或真实启用 UFW；实际传输仅使用 localhost。也未重跑广泛的既有服务套件。

## 运行时与构建回归

全部通过 `ssh host-vps-scripts` 执行，没有在本机或 WSL 运行项目检查：

- `test-offline-runtime.sh` 验证原始 ZIP/tar/二进制资产的本地使用、缺失或损坏资源拒绝、精确版本与通道限制、本地 APT 安装/升级和 lego 新旧元数据。
- 既有 `test-command.sh`、`test-network-rfw.sh`、`test-service-iperf3.sh`、`test-security-tls.sh`、`test-service-proxy.sh`、`test-service-proxy-version-compat.sh` 均 PASS。证据在 `/tmp/vpsctl-offline-runtime-20261101/evidence`。
- `test-offline-build.sh` PASS，包含最新稳定版解析、缺架构与摘要错误拒绝、说明文件及完整性清单、八包汇总一致性，以及在线构建目录容纳离线资产后重建和异常条目保护。
- `test-release-workflow.sh`（21 个场景）、`test-release-build.sh` 及输出目录保护变更后的定向 `release-delivery` 均 PASS。
- 新增离线帮助库、分发库、安装器与 self 更新脚本的 ShellCheck 为零诊断；功能模块未新增诊断，TLS 原有 5 项诊断保留。变更脚本语法及 Python 构建工具编译检查通过。

未运行默认完整套件；验证限定为本次分发和依赖来源变更涉及的入口。最终在线 manifest 为 `6f5f4fb835a9cfdacb32f0c4dc419e24a4adca10623cfacf7a6125665d4dbb3d`。成功路径实包验收使用前一份 `6a4bf49e06006ccbf3e4793bde186d771311366dcc99593b628c5d553afec495`；最终只增加已由故障注入验证的中断回滚修复，依赖资产与成功路径结果继续复用。

## 八平台实包与最终归档

同次构建统一获取的上游稳定版为 Xray `v26.10.31`、sing-box `v1.14.4`、lego `v5.6.0`、RFW `v0.1.9`。版本来自本次构建的实际 API 查询，不是源码版本锁。快照保存于 `/tmp/vpsctl-offline-upstreams-20261101`，两种架构共用一次上游解析结果。

每个目标均在专用 SSH 主机上使用匹配架构的官方镜像构建，再使用 `--network none` 的干净镜像验证本地 APT 仓库。验证包含：空已安装状态下解析完整依赖闭包、实际安装种子软件包、dpkg 审计、四项上游二进制版本执行，以及 Xray/sing-box 基础配置检查。

| 目标系统 | amd64 | arm64 | 每种架构的 DEB 数量 |
| --- | --- | --- | --- |
| Debian 12 | PASS | PASS（QEMU） | 212 |
| Debian 13 | PASS | PASS（QEMU；下述 nft 限制） | 202 |
| Ubuntu 22.04 | PASS | PASS（QEMU） | 195 |
| Ubuntu 24.04 | PASS | PASS（QEMU） | 199 |

执行入口为 `bash tests/integration/test-offline-platforms-real.sh /path/to/offline-package.tar.gz`；各平台构建与验收日志保存在 `/root/vpsctl-offline-build/*-build.log`、`*-accept.log`。原生 Debian 13 amd64 的首次日志为 `debian13-amd64.log`、`debian13-amd64-accept.log`。ARM64 结果仅表示现有 QEMU 用户态仿真验证，不表示真实 ARM 硬件、ARM 内核或防火墙规则操作已经验收。

资源验收完成后，复用已验证的依赖和上游文件，将全部包的项目资产统一替换为最终 `6f5f4f…dbb3d` manifest 对应内容，重新生成包内 `SHA256SUMS` 与归档；未重复已经通过且资源未改变的检查。汇总器验证 8 种目标元数据、相同在线 manifest 和各架构一致的上游组件清单，随后生成 `vpsctl-offline-SHA256SUMS`，标准 `sha256sum -c` 对全部 8 包均为 OK。

最终 8 包及汇总清单位于仓库忽略目录 `dist/offline-validation/`；本次功能验收时未上传或发布 GitHub Release。汇总清单本身的 SHA256 为 `e1f519530791bffe9dcdbba87a94fd212591346646549af89e33fd5f431be51c`。每包携带目标版本、使用说明和逐文件摘要；原始上游和 DEB 来源可从包内清单追溯。后续正式构建、草稿复核与公开发布结果见 [v0.11.0 发布验收](release-0.11.0-validation.md)。

### Debian 13 ARM64 的 nft 仿真限制

该目标的 UFW 包安装钩子记录了 `Couldn't determine iptables version` 并忽略触发器失败。APT 返回 0、dpkg 审计为空；对此另行进行了最小定向复现，未更改主机防火墙或运行防火墙规则操作。

相同离线 DEB 池、匹配 Debian 13 arm64 镜像和断网 QEMU 环境中，`iptables-nft`、`ip6tables-nft` 及默认别名能够加载，但返回 1，错误为 `Failed to initialize nft: Protocol not supported`；两个 legacy 后端返回 0，版本为 `v1.8.11 (legacy)`，`ufw --version` 返回 0，版本为 `0.36.2`。原生验收主机同版本 nft 后端返回 0。日志为 `/root/vpsctl-offline-build/debian13-arm64-ufw-diagnostic.log`。

这将问题定位到 QEMU/容器中的 nft 协议初始化，没有发现二进制或共享库依赖缺失。该平台的防火墙规则应用仍记为 **未验收**，不将 APT 安装成功解释为 ARM 防火墙功能通过；未为模拟环境添加产品绕过或替换默认防火墙后端。
