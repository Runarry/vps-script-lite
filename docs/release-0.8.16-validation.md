# v0.8.16 发布验收

`v0.8.16` 于 2026-10-28 16:43:07（Asia/Singapore）正式发布并设为 latest。发布提交为 `66b3cd939f74af6b41b41eb02c184d3c7e34ee0b`，GitHub Actions [构建记录](https://github.com/Runarry/vps-script-lite/actions/runs/40658375833) 成功，正式 [Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.8.16) 提供完整 22 个 schema 2 资产。上一正式版本 `v0.8.15` 保留。

所有项目测试、参考构建及实际安装验收均通过 `ssh host-vps-scripts` 执行；正式资产由 GitHub Actions 构建。本机只编辑、审阅、进行版本控制、管理 Release 和传输文件。

## 源码与发布前检查

本版包含单设备 Btrfs 根/启动子卷的 BIOS GRUB 安装与修复、当前子卷内核路径识别，以及 Btrfs `/boot` 的固定默认项和单次覆盖清理。功能提交为 `2e1766f2396e1206cea103f7f3853b60c18f10f1`；真实 Debian 12 的安装、两次固件启动、切换及旧内核卸载结果见 [Btrfs 验收记录](kernel-grub-install-validation.md#2026-10-28单设备-btrfs-子卷兼容)。仓库同时提供独立 PO0 中转脚本及输入编辑、历史复用功能，沿用其[独立验收记录](po0-relay-validation.md)。发布准备仅更新 `VERSION` 和当前版本文档。

使用 `git -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` 从发布提交导出源码，传至专用机 `/var/tmp/vpsctl-release-0.8.16.PXBshaTy/source`。以下证据路径相对此远端发布根目录。

| 检查 | 结果与日志 |
| --- | --- |
| `LC_ALL=C bash tests/unit/test-release-build.sh` | PASS；`evidence/release-build.log`，包含完整资产、摘要、归档边界、权限、版本来源和失败交付。 |
| `VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh` | PASS；`evidence/entry-version.log`。 |
| `LC_ALL=C bash scripts/build-release.sh ../build-assets` | PASS；`evidence/reference-build.log`，生成完整 22 个参考资产，摘要为 `evidence/build-assets.sha256`。 |
| 复用内核功能验证 | `evidence/reused-kernel-code.log` 确认内核入口、私有模块、两份 GRUB 回归及 command/environment/ui 库与本次已通过的 Btrfs 验收快照逐字节一致。相关语法、ShellCheck、shfmt、三组内核回归和真实启动结果继续有效。 |

`evidence/preflight-status` 为 `preflight_exit=0`。没有重跑全仓库套件、已通过的 Btrfs 虚拟机启动或其他发行版/网络/代理矩阵。

## 草稿资产与安装验收

`master` 与 `v0.8.16` 标签原子推送后，由标签工作流生成草稿。重新从 GitHub 下载全部草稿资产并传至 `draft-assets/`；`diff -r build-assets draft-assets` 无差异，22 个文件全部通过 SHA-256。证据为 `evidence/draft-compare.log`、`draft-sha256.log` 和 `draft-asset-count.txt`。

复用上一版安装验收驱动，仅适配目标 `0.8.16`、上一真实版本 `0.8.15` 及独立目录，并增加重复离线安装和已安装内核模块的 Btrfs 代码身份检查。上一版资产及真实 schema 1 `v0.8.9` 资产与新下载的公开清单及摘要匹配，记录为 `acceptance-preparation.log`。两个驱动通过远端 `bash -n`。

```bash
bash /var/tmp/vpsctl-release-0.8.16.PXBshaTy/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.8.16.PXBshaTy/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

PASS；主日志为 `acceptance/draft-run.log`，`acceptance/evidence/status` 为 `test_exit=0`、`restore_exit=0`。覆盖全新及重复/离线安装、全部功能与共享依赖按需下载、离线帮助、TCPing 缓存移除与重取、同版本 self 元数据修复、真实 schema 1/2 双向普通卸载后重装、失败升级保留旧版本、实际 `v0.8.15 → v0.8.16` 仅下载 manifest/安装器/core 的升级，以及卸载/purge 的业务数据保护。

安装后的 `system-kernel` 帮助可用，模块与发布源码一致，Btrfs 成员识别及实际挂载点逻辑存在；安装后的 `grub-install.sh` SHA-256 为 `b277c22055b3a05866597106cd592c06ccabf313db01c47cdfc6a837a13ba96b`。代理机器快照仅保留脱敏摘要。驱动恢复了原管理器、self 元数据和共享 UFW 状态，两个恢复比较日志均无差异。

## 公开入口验收与恢复

正式发布并设为 latest 后执行：

```bash
bash /var/tmp/vpsctl-release-0.8.16.PXBshaTy/acceptance/public-smoke.sh
```

PASS；主日志为 `acceptance/public-run.log`，`acceptance/public/evidence/status` 为 `test_exit=0`、`restore_exit=0`。真实公开 URL 验证 latest 与固定 tag 的 manifest/安装器一致，覆盖 latest 全新安装、固定 tag 安装、显式指定版本更新、实际 `v0.8.15 → v0.8.16` 更新、BBR/TCPing 按需缓存及离线帮助。跨版本更新只获取 manifest、安装器和 core，功能包在新版首次调用时下载；公开安装的内核模块身份与 Btrfs 逻辑检查同样通过。

公开 manifest 和安装器与已验收草稿逐字节一致，记录为 `evidence/published-draft-identity.log`。manifest SHA-256 为 `f96aca33a031a9e01e7109de7b3f1deb4aeaf0f08ba6ae13843f389de02aaf53`，记录为 `evidence/published-manifest.sha256`。

两轮实际安装验收均备份并恢复管理入口、不可变 release/current、self 元数据和共享 UFW 状态，业务配置、功能状态、libexec 和备份标记保持。公开验收的 `managed-restore-compare.log`、`ufw-restore-compare.log` 均无差异，测试机最终恢复为原 `vpsctl 0.8.15`，`current` 指向 `/usr/local/lib/vpsctl/releases/0.8.15`。备份及详细证据留在专用机。

## 使用与兼容范围

schema 2 用户可执行 `vpsctl --yes --non-interactive self update --version v0.8.16`。v0.8.9 的 schema 1 用户仍按 README 下载并校验目标安装器/manifest、普通卸载后重装；README 保留固定 tag 与审阅后执行的安装流程。

单设备 Btrfs BIOS 主机更新后，可通过 `vpsctl system kernel install-grub --disk /dev/vda` 查看并确认安装/修复计划；预检需要已安装 `btrfs-progs`。Btrfs `/boot` 的单次覆盖清理策略会在计划中展示。其余内核包、磁盘布局及发行版门禁沿用[系统内核管理](kernel-management.md)，没有以发布验收替代其他平台的真实启动验证。
