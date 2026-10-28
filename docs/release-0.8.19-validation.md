# v0.8.19 发布验收

`v0.8.19` 于 2026-10-28 20:09:36（Asia/Singapore）正式发布并设为 latest。发布提交为 `e4a8bf85b81dad6c4c503248cdd7d6f1ae607e8b`，GitHub Actions [构建记录](https://github.com/Runarry/vps-script-lite/actions/runs/40685246722) 成功，正式 [Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.8.19) 提供完整 22 个 schema 2 资产。上一正式版本 `v0.8.18` 保留。

所有项目执行与验收均通过 `ssh host-vps-scripts`；正式发布资产由 GitHub Actions 构建。本机只编辑、审阅、进行版本控制、管理 Release 和传输文件。

## 统一修复与功能验证

修复提交 `3f0f977` 将 TCPing 的缺失单元判断移入 `lib/command.sh` 的 `vps_cmd_systemd_unit_enabled UNIT`，由 sing-box/Xray 核心、代理中转运行时、TCPing 和 iperf3 四处共用。仅在 LoadState 为 `not-found` 时按未启用返回，其他状态与真正的查询错误保留原有结果及诊断。没有改动服务操作、监听、转发或 OpenRC 分支。

五组定向回归通过：command 共享库、TCPing、iperf3，以及代理 `core-install`、`relay-service`。修改文件通过 Bash 语法检查；ShellCheck 和 shfmt 按基线核对无新增诊断或格式差异，保留部分既有诊断/差异，额外导入全部来源的代理测试分析曾以 137 终止，未记为通过。没有运行全量套件。详细命令、解析范围及证据见 [systemd 服务自启查询验收](systemd-service-query-validation.md)。

独立 Debian 12 / systemd 252 guest 已复现旧版 sing-box 安装成功却打印缺失单元警告的问题。修正版的 sing-box/Xray 完整启停卸载、代理中转真实 unit 状态、TCPing 双栈连接、iperf3 真实收发，以及 static/masked/disabled/not-found 状态均通过；外部真实 binary 路径与回归覆盖的受管下载路径范围在上述记录中分别说明。测试资源清理，guest 正常关机，原始基线及宿主引导/防火墙未修改。

功能验收后只更新版本和文档。发布源码与最终验收快照中的共享库、四处调用、相关回归、监听器和依赖共 14 份文件逐字节一致，记录为下文 `evidence/reused-service-code.log`。共享函数所在 `lib/command.sh` 的 SHA-256 为 `266df5f793ea0e770aff9b251d5cf2edcdf789c1aba3a2833344dbb9d225d37e`。

## 发布包与草稿验收

从发布提交以 `git -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` 导出源码，传至专用机 `/var/tmp/vpsctl-release-0.8.19.b4SNCjhi/source`。以下证据路径相对此远端发布根目录。

| 检查 | 结果与日志 |
| --- | --- |
| `LC_ALL=C bash tests/unit/test-release-build.sh` | PASS；`evidence/release-build.log`，覆盖完整资产、摘要、归档边界、权限、版本来源和失败交付。 |
| `VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh` | PASS；`evidence/entry-version.log`。 |
| `LC_ALL=C bash scripts/build-release.sh ../build-assets` | PASS；`evidence/reference-build.log`，22 个参考资产及 `evidence/build-assets.sha256`。 |
| 草稿重新下载 | PASS；22 个 GitHub 草稿资产与参考构建逐字节一致，全部 SHA-256 通过；`evidence/draft-compare.log`、`draft-sha256.log`、`draft-asset-count.txt`。 |

`evidence/preflight-status` 为 `preflight_exit=0`。沿用上一版发布验收驱动，适配目标 `0.8.19`、上一真实版本 `0.8.18` 和独立目录；v0.8.18 的真实缓存与新下载公开 manifest 一致，21 项登记资产摘要通过，v0.8.9 保留原 schema 1 资产。两个驱动远程 `bash -n` 和完整 ShellCheck 零诊断通过，记录为 `acceptance-preparation.log`。

```bash
bash /var/tmp/vpsctl-release-0.8.19.b4SNCjhi/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.8.19.b4SNCjhi/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

PASS；`acceptance/accept-draft.log` 覆盖全新/重复/离线安装、全部功能及共享依赖按需缓存、同版本修复、失败升级回退、真实 schema 1/2 双向迁移、实际 `v0.8.18 → v0.8.19` 仅下载 manifest/安装器/core 的升级，以及普通卸载/purge 的业务数据保护。

增加安装后的 `lib/command.sh`、TCPing、iperf3、代理 common/relay-forward 五份文件与四个目标 bundle 的逐字节比对及共同 helper 定义/调用检查。对确认不存在的唯一真实单元，已安装 helper 返回 1 且 stderr 为空；TCPing 未安装 status 也无 stderr。身份摘要为 `acceptance/evidence/installed-systemd-enabled.sha256`，行为证据为 `missing-unit-helper.status` 和对应 stdout/stderr。`acceptance/evidence/status` 为 `test_exit=0`、`restore_exit=0`，管理器与 UFW 恢复比较无差异。

## 正式发布与公开入口

正式发布并设为 latest 后执行 `bash /var/tmp/vpsctl-release-0.8.19.b4SNCjhi/acceptance/public-smoke.sh`，PASS。`acceptance/public-smoke.log` 覆盖 latest/固定 tag 的 manifest 与安装器身份、latest 全新安装、按需和离线缓存、固定版本安装/更新，以及实际 v0.8.18 到 v0.8.19 的 core-only 升级。固定版本安装后三项服务帮助缓存、四个公开 bundle 摘要、五份已安装文件身份与共同 helper 调用均通过；真实缺失单元返回 1 且 stderr 为空，TCPing 未安装状态也无 stderr。

公开安装器、manifest 和五份受影响安装代码与验收草稿一致，记录为 `evidence/published-draft-identity.log`。manifest SHA-256 为 `cf3ea7ac226303d7bb735d729bf6c9c30986ec315eecaede4e14754a86960504`，记录为 `evidence/published-manifest.sha256`。

`acceptance/public/evidence/status` 为 `test_exit=0`、`restore_exit=0`。`managed-restore-compare.log` 和 `ufw-restore-compare.log` 均无差异；业务配置、功能状态、libexec 和备份标记保持，测试标记无残留。专用机恢复原 `vpsctl 0.8.15`，`current` 指向 `/usr/local/lib/vpsctl/releases/0.8.15`。备份与详细证据保留在专用机。

## 更新

schema 2 用户执行 `vpsctl self update --version v0.8.19`。已正常启动的代理核心、TCPing 和 iperf3 无需重装或重启。v0.8.9 的 schema 1 用户仍按 README 下载校验安装器/manifest、普通卸载后重装。
