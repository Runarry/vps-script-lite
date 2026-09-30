# v0.8.11 发布验收

`v0.8.11` 于 2026-10-01（Asia/Singapore）正式发布并成为 latest。发布提交为 `fc6be0200c97ecad58002b63502c43248052edff`，GitHub Actions [构建记录](https://github.com/Runarry/vps-script-lite/actions/runs/36748243056) 成功，正式 [Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.8.11) 包含完整的 20 个 schema 2 资产。上一个正式版本 `v0.8.10` 保留，可作为回退版本。

所有项目构建、静态检查、测试和真实安装验收均通过 `ssh host-vps-scripts` 在专用 Debian 13 环境执行。本机仅编辑、查看仓库差异、导出源码及进行版本控制和资产传输。

## 源码与检查范围

源码以 `git -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` 导出，传至专用主机的 `/var/tmp/vpsctl-release-0.8.11/source`。初次导出受到本机 Git 行尾设置影响，远端语法检查因 CRLF 失败；重新以 LF 导出同一提交后继续，原始失败日志保留在 `evidence/syntax-crlf-export.log`。

本次仅调整版本、当前版本文档及分发真实集成测试中的版本夹具。集成测试读取根 `VERSION`，并从当前补丁号生成下一版本，不再修改入口中已不存在的版本常量。运行代码沿用 `v0.8.10` 之后已提交的修复与优化；其定向回归、独立对照和真实 PTY 等验证范围见[优化验收记录](optimization-review-2026-09-30.md)。

以下命令均在远端源码目录执行，日志位于 `/var/tmp/vpsctl-release-0.8.11/evidence/`：

| 检查 | 结果与日志 |
|---|---|
| `bash -n tests/integration/test-distribution-real.sh` | PASS；`syntax.log`。 |
| `shellcheck -x -P SCRIPTDIR --severity=error tests/integration/test-distribution-real.sh` | PASS，仅检查 error 级别；`shellcheck.log`。 |
| `shfmt -d -i 4 -ci tests/integration/test-distribution-real.sh` | 返回 1，存在既有格式差异；与 v0.8.10 源码基线的格式化增删行完全一致，无新增格式变化，不记为完整格式检查通过。见 `shfmt.log`、`shfmt-baseline.log` 和 `shfmt-*-changes.log`。 |
| `bash tests/unit/test-release-build.sh` | PASS，包含资产集合、严格清单、摘要、归档路径与权限、版本来源及构建失败交付；`release-build.log`。 |
| `bash tests/unit/test-release-workflow.sh` | PASS，21 次运行；`release-workflow.log`。 |
| `VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh` | PASS；`entry-version.log`。 |
| `bash tests/unit/test-distribution.sh` | PASS，覆盖分发校验、失败处理、更新和卸载边界；`distribution-unit.log`。 |
| `VPSCTL_TEST_LEGACY_ASSET_DIR=/var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy VPSCTL_TEST_TCPING_UNINSTALL=1 bash tests/integration/test-distribution-real.sh` | PASS；`distribution-real.log`。 |

`preflight-status` 记录 `preflight_exit=0`。未重跑完整默认套件、全部真实服务测试或跨发行版矩阵；已有效的功能验证继续复用，不将这些未执行范围记为通过。

## 草稿资产与真实安装

独立参考构建命令为 `LC_ALL=C bash scripts/build-release.sh /var/tmp/vpsctl-release-0.8.11/build-assets`。首次采用主机默认 locale 的参考构建与 GitHub 产物仅有 core 归档中 `VERSION` 的条目顺序不同，解包文件内容一致；统一排序环境后，全部 20 个资产与重新下载的草稿逐字节一致，`sha256sum -c` 全部通过。最初差异及环境记录保留在 `draft-host-locale-compare.log`、`core-content-diff.log` 和 `host-build-locale.log`；最终结果为 `draft-compare.log`、`draft-sha256.log` 和 `build-assets.sha256`。

从 GitHub 重新下载的完整草稿位于 `/var/tmp/vpsctl-release-0.8.11/draft-assets`。验收复用上一版脚本并补充实际 schema 2 更新和失败保留旧版场景：

```bash
bash /var/tmp/vpsctl-release-0.8.11/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.8.11/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

退出码为 0，覆盖实际 v0.8.9 schema 1 与新版 schema 2 双向普通卸载后重装、仅安装 core、14 个功能帮助及共享依赖按需下载、离线帮助、TCPing 功能缓存删除与重新下载、同版本更新修复缓存。另从 GitHub 下载并校验实际 v0.8.10 的完整资产，验证下载失败不改变旧版本或受管文件，成功更新到 v0.8.11 仅获取 manifest、安装器和 core，旧功能缓存不预取，首次 BBR 重新下载新版依赖。普通卸载与 purge 均保留业务数据标记。

主日志为 `evidence/draft-install.log`；阶段下载轨迹、资产摘要和恢复核对位于 `acceptance/evidence/`。其 `status` 记录 `test_exit=0`、`restore_exit=0`，受管目录及共享 UFW 状态的 tar 恢复比较日志为空。

## 正式发布与公网验收

草稿验收完成后，正式发布并设置 latest，再执行：

```bash
bash /var/tmp/vpsctl-release-0.8.11/acceptance/public-smoke.sh
```

退出码为 0。通过真实 GitHub 公开 URL 验证 latest 与固定 v0.8.11 的 manifest、安装器逐字节一致，并与已验收草稿匹配；manifest SHA-256 为 `0c36ab69cc53912e7786aea298e9c1485edd6a3fc506c7f5007102447bf9ea52`。覆盖 latest 全新安装、固定 tag 安装、首次功能下载、离线 BBR 帮助、显式指定版本更新修复缓存，以及实际 v0.8.10 到 v0.8.11 公网升级。跨版本更新只获取三个 core 分发资产，首次再次使用 BBR 才下载新版共享库与功能包。

公网安装期间出现一次 curl 连接超时，下载器现有重试成功，后续安装、摘要和更新断言均通过。日志为 `evidence/public-smoke.log`；实际请求、期望请求与恢复记录位于 `acceptance/public/evidence/`。其 `status` 记录 `test_exit=0`、`restore_exit=0`，恢复比较日志为空。

两轮真实验收均先保存入口、安装目录、self 元数据和共享 UFW 状态，退出时恢复并比较。最终入口仍报告测试前的 `vpsctl 0.5.0`，`current` 仍解析为 `/usr/local/lib/vpsctl/releases/0.1.0`；备份及完整证据留在上述远端验收目录中。
