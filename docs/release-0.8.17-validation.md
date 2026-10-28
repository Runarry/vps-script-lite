# v0.8.17 发布验收

`v0.8.17` 于 2026-10-28 18:26:12（Asia/Singapore）正式发布并设为 latest。发布提交为 `4673d580e39266f7974ce0a749d9d38db870eea9`，GitHub Actions [构建记录](https://github.com/Runarry/vps-script-lite/actions/runs/40671800015) 成功，正式 [Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.8.17) 提供完整 22 个 schema 2 资产。上一正式版本 `v0.8.16` 保留。

所有项目执行与验收均通过 `ssh host-vps-scripts`；正式发布资产由 GitHub Actions 构建。本机只编辑、审阅、进行版本控制、管理 Release 和传输文件。

## 修复与功能验证

修复提交 `a0ef86f` 处理 BIOS 环境仍装有互斥 `grub-efi-amd64` 控制包时，安装 `grub-pc` 被 APT `--no-remove` 拒绝的问题。仅允许精确替换已安装、未锁定、可独立移除的普通控制包；确认页展示原版本，备份后以非 purge 的 dpkg 移除，后续 APT 保留 `--no-remove`。EFI 模块、ESP 文件及内核保留，删除记录和原包状态进入恢复材料。

功能验证目录为 `/root/vpsctl-bios-efi-replace-20261028/`。安装流程、provider 和内核入口三组回归通过，涉及文件通过 Bash 语法、完整 ShellCheck 和 shfmt。真实 Debian 12 / SeaBIOS / GPT / Btrfs `@rootfs`、`compress=zlib:3` 环境复现原错误，修正版演练只读、实际替换、11 项恢复材料摘要及一次固件重启均通过。完整记录见[BIOS GRUB 验收](kernel-grub-install-validation.md#2026-10-28bios-环境的-efi-控制包替换)和远端 `REPORT.txt`。

该功能验收使用 v0.8.16 基线加修复代码，后续仅更新发布版本及文档。发布提交与已验收快照中的内核入口、私有模块、相关回归和 command/environment/ui 库逐字节一致，记录为下文的 `evidence/reused-kernel-code.log`。没有重跑全量套件、已通过的内核启动或其他发行版/签名包/锁定包 VM 变体；相应拒绝行为由回归夹具覆盖。

## 发布包与草稿验收

从发布提交以 `git -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` 导出源码，传至专用机 `/var/tmp/vpsctl-release-0.8.17.jV1QL7V5/source`。以下证据路径相对此远端发布根目录。

| 检查 | 结果与日志 |
| --- | --- |
| `LC_ALL=C bash tests/unit/test-release-build.sh` | PASS；`evidence/release-build.log`，覆盖完整资产、摘要、归档边界、权限、版本来源和失败交付。 |
| `VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh` | PASS；`evidence/entry-version.log`。 |
| `LC_ALL=C bash scripts/build-release.sh ../build-assets` | PASS；`evidence/reference-build.log`，22 个参考资产及 `evidence/build-assets.sha256`。 |
| 草稿重新下载 | PASS；22 个 GitHub 草稿资产与参考构建逐字节一致，全部 SHA-256 通过；`evidence/draft-compare.log`、`draft-sha256.log`、`draft-asset-count.txt`。 |

`evidence/preflight-status` 为 `preflight_exit=0`。沿用上一版安装验收驱动，适配目标 `0.8.17`、上一真实版本 `0.8.16` 和独立目录；缓存的真实 v0.8.16/v0.8.9 资产与新下载的公开 manifest 及摘要匹配。增加安装后 `providers.sh` 与 `grub-install.sh` 的发布包身份、依赖预检、EFI 替换阶段及实际 APT `--no-remove` 检查。两个驱动的远程语法检查通过，准备日志为 `acceptance-preparation.log`。

```bash
bash /var/tmp/vpsctl-release-0.8.17.jV1QL7V5/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.8.17.jV1QL7V5/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

PASS；`acceptance/draft-run.log` 包含全新/重复/离线安装、全部功能及共享依赖按需缓存、同版本修复、失败升级回退、真实 schema 1/2 双向迁移、实际 `v0.8.16 → v0.8.17` 仅下载 manifest/安装器/core 的升级，以及普通卸载/purge 的业务数据保护。安装后的内核帮助与两份修复模块身份检查通过。`acceptance/evidence/status` 为 `test_exit=0`、`restore_exit=0`，管理器及共享 UFW 恢复比较无差异。

## 正式发布与公开入口

正式发布并设为 latest 后执行 `bash /var/tmp/vpsctl-release-0.8.17.jV1QL7V5/acceptance/public-smoke.sh`，PASS。`acceptance/public-run.log` 覆盖 latest/固定 tag 的 manifest 与安装器身份、latest 全新安装、固定 tag 安装、显式指定版本更新、实际 v0.8.16 到 v0.8.17 的 core-only 更新，以及升级后的按需和离线缓存。已安装内核模块仍与包内两份修复代码一致。

公开 manifest 和安装器与验收草稿逐字节一致，记录为 `evidence/published-draft-identity.log`；manifest SHA-256 为 `e1aa852635d11788514300453b17cf8263efd8773e36a50dcf598d4e6deb11ca`，记录为 `evidence/published-manifest.sha256`。

`acceptance/public/evidence/status` 为 `test_exit=0`、`restore_exit=0`。`managed-restore-compare.log` 和 `ufw-restore-compare.log` 均无差异，业务配置、功能状态、libexec 和备份标记保持。专用机恢复为原 `vpsctl 0.8.15`，`current` 指向 `/usr/local/lib/vpsctl/releases/0.8.15`；备份与详细日志留在专用机。

## 更新与重试

schema 2 用户可执行 `vpsctl self update --version v0.8.17`，再运行 `vpsctl system kernel install-grub --disk /dev/vda` 查看并确认修复计划。v0.8.9 的 schema 1 用户仍按 README 下载校验安装器/manifest、普通卸载后重装。磁盘、启动模式、内核及其他包保护继续遵循[系统内核管理](kernel-management.md)。
