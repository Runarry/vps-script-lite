# v0.8.15 发布验收

`v0.8.15` 于 2026-10-19 15:38:43（Asia/Singapore）正式发布并设为 latest。发布提交为 `1b85625ce9fdc4dc455c92e8f29c62d4381935bc`，GitHub Actions [构建记录](https://github.com/Runarry/vps-script-lite/actions/runs/39216933307) 成功，正式 [Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.8.15) 提供完整 22 个 schema 2 资产。上一正式版本 `v0.8.14` 保留，可作为回退目标。

所有项目测试、独立参考构建和安装验收均通过 `ssh host-vps-scripts` 执行；GitHub Actions 构建正式资产。本机仅编辑、检查仓库、进行版本控制、管理 Release 和传输文件。

## 源码与发布前检查

功能源码来自提交 `32c579744a397cc3e467d420450fdec03b58d8b5`，新增代理机器接口，包括原生配置快照、稳定 revision、同锁内版本冲突检查、请求回执、继承锁和每次请求的依赖安装授权。接口格式与使用边界见[代理机器接口](proxy-machine-api.md)。发布准备只修改 `VERSION`、README 和开发流程中的当前版本说明，没有修改功能代码。

从发布提交以 `git -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` 导出源码，传至专用机 `/var/tmp/vpsctl-release-0.8.15.YIKMPpPt/source`。下文证据路径相对该远端根目录。

| 检查 | 结果与日志 |
| --- | --- |
| 六份变更脚本的 `bash -n` | PASS；`evidence/syntax.log`。范围为代理入口、machine 模块、command/registry 库、测试入口和新增机器接口测试。 |
| 六份变更脚本的 `shellcheck --severity=error` | PASS，错误级无诊断；`evidence/shellcheck-errors.log`。未进行完整级别或递归分析。 |
| `bash tests/unit/test-command.sh` | PASS；`evidence/command-unit.log`。 |
| `LC_ALL=C bash tests/unit/test-release-build.sh` | PASS；`evidence/release-build.log`，覆盖资产清单、摘要、归档边界、权限、版本来源和失败交付。 |
| `VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh` | PASS；`evidence/entry-version.log`。 |
| `LC_ALL=C bash scripts/build-release.sh /var/tmp/vpsctl-release-0.8.15.YIKMPpPt/build-assets` | PASS；`evidence/reference-build.log`，生成完整 22 个参考资产，摘要为 `evidence/build-assets.sha256`。 |

`evidence/preflight-status` 记录 `preflight_exit=0`。机器接口的 `bash tests/unit/test-service-proxy-machine.sh` 已在本次对话的代码审查阶段通过专用机执行，覆盖快照、CAS、原生操作夹具、锁冲突、中断回执、TLS/中转导出、依赖授权和 pending 范围；发布提交的功能代码未变，因此复用该结果，没有重复执行。没有运行全仓库套件或无关协议、内核、网络及性能矩阵。

## 草稿资产与安装验收

`master` 和 `v0.8.15` 标签原子推送后，由标签工作流生成草稿。重新从 GitHub 下载全部资产并传至 `draft-assets/`；`diff -r build-assets draft-assets` 无差异，22 个文件全部通过 SHA-256 校验。证据为 `evidence/draft-compare.log`、`draft-sha256.log`、`draft-asset-count.txt`。另确认 `service-proxy` 包包含 `commands/service/proxy/machine.sh`，记录为 `evidence/machine-bundle.log`。

复用上一版真实验收脚本，调整目标版本、上一版本及独立工作目录，并增加受管安装入口的机器快照检查。临时资产验证驱动首次因传输末行 CRLF 在安装验收开始前报语法错误；修正驱动换行并通过远端语法检查后，直接执行以下安装验收，保留已完成的资产比对结果。

真实 `v0.8.14` 使用上一发布留存资产，重新下载其公开 manifest 并与留存清单逐字节比较，所有资产摘要复核通过；日志为 `evidence/previous-public-manifest.tsv` 和 `previous-assets-sha256.log`。schema 1 使用此前留存并校验的真实 `v0.8.9` 资产。

```bash
bash /var/tmp/vpsctl-release-0.8.15.YIKMPpPt/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.8.15.YIKMPpPt/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

PASS，`acceptance/evidence/status` 为 `test_exit=0`、`restore_exit=0`。覆盖 core 安装、16 个功能帮助及共享依赖按需下载、离线帮助、TCPing 缓存移除/重取、同版本 self 元数据修复、schema 1/2 双向普通卸载后重装、普通卸载及 purge 的业务数据保护。实际 `v0.8.14 → v0.8.15` 更新下载失败时保留旧版本和文件；成功升级只下载 manifest、安装器和 core，新版首次使用功能才重新下载对应包。主日志为 `evidence/draft-install.log`。

新增机器接口检查通过真实受管入口下载 `shared-ufw` 和 `service-proxy`，验证安装后的 `machine.sh`、快照 `schemaVersion=1`、`vpsctlVersion=0.8.15`、revision 和 `node.add` 能力。完整快照和 stderr 仅写入受保护临时文件并清理；证据只保留 `acceptance/evidence/proxy-machine-summary.json` 的脱敏摘要。机器变更动作复用上述隔离单元夹具结果。

## 正式发布与公网验收

正式发布并设置 latest 后，执行：

```bash
bash /var/tmp/vpsctl-release-0.8.15.YIKMPpPt/acceptance/public-smoke.sh
```

PASS，`acceptance/public/evidence/status` 为 `test_exit=0`、`restore_exit=0`。通过真实 GitHub 公开 URL 验证 latest 与固定 tag 的 manifest、安装器一致；覆盖 latest 全新安装、固定 `v0.8.15` 安装、BBR/TCPing 按需下载、离线帮助、同版本修复、真实 `v0.8.14 → v0.8.15` 公网升级及升级后的按需缓存。公网机器快照与模块按需下载同样通过，仅保存脱敏摘要。主日志为 `evidence/public-smoke.log`，请求轨迹与恢复证据位于 `acceptance/public/evidence/`。

公开 manifest 和安装器与已验收草稿逐字节一致。manifest SHA-256 为 `56c3a8f2e985996ce0b1190580d02aff17967db9b5b410fcab5f605372ac72a7`，记录为 `evidence/published-manifest.sha256`。

两轮实际安装验收均备份并恢复 `/usr/local/bin/vpsctl`、`/usr/local/lib/vpsctl`、self 元数据及共享 UFW 状态，恢复比较无差异。业务配置、功能状态、libexec 和备份通过独立标记确认保留。测试前后入口仍报告 `vpsctl 0.5.0`，`current` 仍为 `/usr/local/lib/vpsctl/releases/0.1.0`；备份和详细证据保留在专用机，不提交宿主配置或凭据。

## 使用与兼容范围

schema 2 用户可执行 `vpsctl --yes --non-interactive self update --version v0.8.15`。v0.8.9 的 schema 1 用户仍按 README 普通卸载后重装。README 保留固定 tag 下载、核对 manifest 安装器摘要、审阅后执行的安装流程。

机器接口需要 root，不支持 `--dry-run`，快照包含完整凭据，只供可信本机 Agent 使用。危险变更继续要求对应原生确认标志；已记录为 unknown 的请求不得自动重做。本版未改变代理协议实现，既有兼容范围沿用 [v0.8.14 发布验收](release-0.8.14-validation.md)及其引用的协议记录。
