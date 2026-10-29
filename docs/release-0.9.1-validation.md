# v0.9.1 发布验收

`v0.9.1` 于 2026-10-29 12:58:33（Asia/Singapore）正式发布并设为 latest，非 prerelease。发布提交为 `9aca1e085fcb0ccf7e3d5c65bb1b66e4b7d927d9`；GitHub Actions [构建记录](https://github.com/Runarry/vps-script-lite/actions/runs/40820259710) 成功，正式 [Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.9.1) 提供完整 23 个 schema 2 资产。上一正式版本 `v0.8.19` 保留。

本次新增 `system clean`，支持推荐清理、受管残留与功能包缓存、软件包下载缓存、按系统规则过期的临时文件和独立归档 journal 清理。功能提交为 `fdc6b55`；功能边界、真实 Debian 验收及其他后端的验证范围见[系统清理验收](system-clean-validation.md)。

所有项目测试与验收均通过 `ssh host-vps-scripts`；正式发布资产由 GitHub Actions 构建。发布副本与证据位于专用机 `/var/tmp/vpsctl-release-0.9.1.7d00Ynhv/`，下文证据路径均相对此目录；本机仅编辑、审阅、版本控制、管理 GitHub Release 和传输文件。

## 功能验收复用

本次版本准备仅修改 `VERSION` 和发布文档。发布提交相对 `fdc6b55` 的功能源码与测试没有变化，复用已通过的功能测试。新功能的 Bash 语法、ShellCheck、shfmt、定向单元及 Debian 原生清理结果保持有效；既有测试静态诊断的基线和真实后端限制均保留在功能验收记录中。

`evidence/reused-clean-code.sha256` 确认发布源码与功能验收版本一致：`commands/system/clean.sh` 为 `bc3f55ba8bb27eb2b0a89d732a12009752b418504b37c05b962a02cff2829c4d`，对应单元测试为 `92ecc84214e79e5f37b09925eda4aec5a5ddc0a8a5725d6d2b38f9f133466bf6`。未重复原生 APT、tmpfiles、journal 清理，未运行无关完整套件。

## 构建与草稿验收

从发布提交用 `git -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` 导出源码，传至专用机的 `source/`。正式草稿由标签工作流生成，重新下载后传入 `draft-assets/`，没有用本地参考包替代草稿验收。

| 检查 | 结果与证据 |
| --- | --- |
| `LC_ALL=C bash tests/unit/test-release-build.sh` | PASS；完整资产、摘要、路径与类型边界、版本来源及失败交付，见 `evidence/release-build.log`。 |
| `VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh` | PASS；见 `evidence/entry-version.log`。 |
| `LC_ALL=C bash scripts/build-release.sh ../build-assets` | PASS；23 个参考资产及摘要，见 `evidence/reference-build.log`、`build-assets.sha256`。 |
| 草稿重新下载与比较 | PASS；23 个资产与参考构建逐字节一致，`evidence/draft-compare.log` 为空。驱动重新校验全部 22 条登记资产摘要和 tar 路径、core 版本。 |
| 验收驱动静态检查 | PASS；`acceptance/accept-draft.sh`、`public-smoke.sh`、`common.sh` 均经远端 Bash 语法及完整 ShellCheck 检查。准备证据见 `acceptance/preparation/`。 |

草稿执行命令：

```bash
bash /var/tmp/vpsctl-release-0.9.1.7d00Ynhv/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.9.1.7d00Ynhv/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

PASS；`acceptance/accept-draft.log` 覆盖全新、重复与离线安装，全部 17 项功能和 3 个共享包的按需缓存，已安装清理代码及 core 注册表/分发库与资产身份一致，清理帮助/状态离线与演练零变更。真实受管夹具残留和功能包清空、core/shared/system-clean/self 保留及 BBR/Swap 重新下载通过；业务标记和服务状态保持不变。

同版本元数据修复、失败更新保留原版本、真实 `v0.8.19 → v0.9.1` 仅下载 manifest/安装器/core 的升级，以及普通卸载与 purge 的业务数据保护均通过。使用实际发布的 v0.8.9 schema 1 资产完成双向手动迁移；v0.8.19 缓存先与新下载的公开 manifest 对比并核验全部登记摘要。

`acceptance/evidence/status` 为 `test_exit=0`、`restore_exit=0`；受管安装、UFW、运行锁与业务数据的比较日志为空，服务状态一致。原 `vpsctl 0.8.15` 已恢复。

## 正式发布与公开入口

草稿验收通过后正式发布并设为 latest，随后执行：

```bash
bash /var/tmp/vpsctl-release-0.9.1.7d00Ynhv/acceptance/public-smoke.sh
```

PASS；`acceptance/public-smoke.log` 覆盖 latest 和固定 tag 的安装器/manifest 一致性、实际全新安装、按需及离线缓存、同版本修复、固定版本安装，以及真实 `v0.8.19 → v0.9.1` 的 core-only 更新与更新后的按需/离线使用。已安装清理代码、注册表及分发库与公开资产一致，清理状态与演练不改变受管文件或运行数据。

全部 23 个公开资产均重新下载、验证摘要，并与验收草稿逐字节比较一致。manifest SHA-256 为 `4a9a5f17a884e9594024f00e269b28253a997f675894d8caa6e828569e785957`。

`acceptance/public/evidence/status` 为 `test_exit=0`、`restore_exit=0`；受管安装、UFW、运行锁与业务比较日志为空，清理前后及最终服务状态一致。专用机再次恢复原 `vpsctl 0.8.15`，`current` 指向 `/usr/local/lib/vpsctl/releases/0.8.15`。详细证据和恢复备份保留在专用机。

## 更新

schema 2 用户更新命令：`vpsctl self update --version v0.9.1`。v0.8.9 的 schema 1 用户仍须按 README 校验目标安装器和 manifest、普通卸载后重装。清理功能不要求重装或重启已部署服务。
