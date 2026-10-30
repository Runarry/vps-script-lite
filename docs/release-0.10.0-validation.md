# v0.10.0 发布验收

`v0.10.0` 于 2026-10-30 10:21:25（Asia/Singapore）正式发布并设为 latest，非 prerelease。发布提交为 `b177ab6f1cb91a0ead38ac2b0143fb658c9ecbfb`；GitHub Actions [构建记录](https://github.com/Runarry/vps-script-lite/actions/runs/40990851201) 成功，正式 [Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.10.0) 提供完整 27 个 schema 2 资产。上一正式版本 `v0.9.1` 保留。

本次发布实验性的整机备份、Docker 备份与加密仓库功能，包含定时任务和四项审查修复。功能基线为 `0567d4dd2fd4e4a1a967810a2a3340a892eefe23`；功能与平台验收边界见[备份验收记录](backup-validation.md)。发布准备仅调整版本与文档，不修改功能源码及测试，复用仍有效的功能验收结果。

所有项目验证通过 `ssh host-vps-scripts` 执行。本轮独立发布目录为 `/var/tmp/vpsctl-release-0.10.0.VctsHH1e/`，下文证据路径均相对此目录；正式资产由标签触发的 GitHub Actions 构建为草稿，重新下载验收后再发布，没有用参考构建代替草稿验收。

## 功能验收复用

发布提交相对功能基线只修改 `VERSION`、README 和发布文档，功能源码与测试未变化。`evidence/reused-backup-code.sha256` 记录 Docker 引擎/入口、整机恢复、共享任务库及三个专项测试共七份文件，与本轮修复验收副本逐字节一致。此前三项备份专项测试、语法及静态检查保持有效，没有重复功能备份、完整 VM 恢复或原生数据库端到端恢复。

## 构建与草稿验收

从发布提交用 `git -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` 导出源码，传入专用机 `source/`。GitHub Actions 生成的实际草稿资产重新下载后传入 `draft-assets/`。

| 检查 | 结果与证据 |
| --- | --- |
| `LC_ALL=C bash tests/unit/test-release-build.sh` | PASS；完整资产、摘要、路径与类型边界、版本来源和失败交付，见 `evidence/release-build.log`。 |
| `VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh` | PASS；见 `evidence/entry-version.log`。 |
| `LC_ALL=C bash scripts/build-release.sh ../build-assets` | PASS；27 个参考资产及摘要，见 `evidence/reference-build.log`、`evidence/build-assets.sha256`。 |
| 实际草稿与参考构建比较 | PASS；27 个资产逐字节一致，`evidence/draft-compare.log` 为空。 |
| 验收驱动准备 | PASS；三个驱动远端 Bash 语法及 ShellCheck 零诊断，见 `acceptance/preparation/drivers-static.txt`、`drivers.sha256`。真实公开 v0.9.1 的 23 个资产及 22 条登记摘要已核验，见 `previous-assets.txt`。 |

`evidence/preflight-status` 为 `preflight_exit=0`。首轮输出汇总受 PowerShell 管道尾部 CRLF 影响，最后的日志打印返回非零；测试与构建均已成功结束，随后只读核对状态、日志和 27 项资产摘要清单，未重复这些测试。

草稿执行命令：

```bash
bash /var/tmp/vpsctl-release-0.10.0.VctsHH1e/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.10.0.VctsHH1e/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

PASS；`acceptance/accept-draft.log` 覆盖严格 manifest 与全部 25 个 bundle、全新/重复/离线安装、20 个功能与 4 个共享包按需缓存、三个备份入口独立冷缓存与 shared-backup 复用，以及已安装私有模块和共享库的资产身份。三个入口的离线 help/status/JSON 不下载、不安装依赖，也不修改配置、业务、调度或受管运行状态。

同版本元数据修复、失败升级保留原版本、实际 `v0.9.1 → v0.10.0` 的 core-only 升级、普通卸载/purge 的业务保护和实际 v0.8.9 schema 1/2 双向迁移均通过。

`acceptance/evidence/status` 为 `test_exit=0`、`restore_exit=0`；安装、UFW、业务和运行锁的四份恢复比较日志均为空，服务和调度状态前后一致，原 `vpsctl 0.8.15` 已恢复。

## 正式发布与公开入口

草稿通过后正式发布并设为 latest，再执行：

```bash
bash /var/tmp/vpsctl-release-0.10.0.VctsHH1e/acceptance/public-smoke.sh
```

PASS；`acceptance/public-smoke.log` 覆盖 latest/固定 tag 安装器和 manifest 一致性、公开全新安装、指定版本安装与同版本修复、按需/离线缓存、三个备份入口独立包与共享依赖，以及实际公开 `v0.9.1 → v0.10.0` 的 core-only 升级和升级后的按需/离线使用。

全部 27 个公开资产均重新下载、校验摘要，并与已验收草稿逐字节比较一致，`acceptance/public/evidence/public-draft-compare.log` 为空。manifest SHA-256 为 `3fcc162504e4b48d8c7cc291c39ab1a89bd6d9c82e706a6a6d8f9d4f42cc0890`。

`acceptance/public/evidence/status` 为 `test_exit=0`、`restore_exit=0`；受管安装、UFW、业务与运行锁的恢复比较日志均为空，服务和调度状态一致。专用机恢复原 `vpsctl 0.8.15`，`current` 指向 `/usr/local/lib/vpsctl/releases/0.8.15`；备份与详细证据保留在专用目录。

## 更新

schema 2 用户运行 `vpsctl self update --version v0.10.0`。v0.8.9/schema 1 用户仍须按 README 校验目标安装器和 manifest，普通卸载管理器后重新安装。备份功能保持 experimental；本轮发布验收不扩大[功能验收记录](backup-validation.md)中的平台或数据库支持结论。
