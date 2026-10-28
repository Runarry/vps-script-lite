# v0.8.18 发布验收

`v0.8.18` 于 2026-10-28 19:39:39（Asia/Singapore）正式发布并设为 latest。发布提交为 `7b20f84f76f24c602428445ce66835a93ba75a42`，GitHub Actions [构建记录](https://github.com/Runarry/vps-script-lite/actions/runs/40681369598) 成功，正式 [Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.8.18) 提供完整 22 个 schema 2 资产。上一正式版本 `v0.8.17` 保留。

所有项目执行与验收均通过 `ssh host-vps-scripts`；正式发布资产由 GitHub Actions 构建。本机只编辑、审阅、进行版本控制、管理 Release 和传输文件。

## 修复与功能验证

修复提交 `d6f8d00` 处理 TCPing 首次安装前，Debian 12 / systemd 252 查询不存在单元的自启状态时打印 `Failed to get unit file state ... No such file or directory` 的问题。先读取 LoadState，仅在 `not-found` 时按未安装处理；其他情况继续查询原自启状态。实际查询错误的诊断和退出码保留，无本模块文件但已经加载且启用的外部同名服务仍被保护。

候选目录 `/root/vpsctl-tcping-quiet-20261028/source` 的 TCPing 单元套件、两份修改文件的 Bash 语法及 shfmt 通过；应用 ShellCheck 使用既有 warning 级别、测试使用完整级别，分别无 warning/error 和零诊断。独立 Debian 12 / systemd 252 guest 复现原问题后，验证未安装状态与 PTY 菜单、首次真实启动 11111、loaded/active/enabled 判断、IPv4/IPv6 真实连接、停止及卸载均通过。专属资源和防火墙需求清理，guest 已关机。详细范围、证据、夹具调用的退出变量转义问题和未验项目见 [TCPing 验收记录](tcping-validation.md#2026-10-28未安装-systemd-单元的状态查询)。

功能验收后只更新版本和文档。发布提交与验收快照中的 TCPing 入口、监听器、单元测试及 command/ufw/distribution/environment/ui 库逐字节一致，记录为下文的 `evidence/reused-tcping-code.log`。发布包和已安装入口的 SHA-256 均为 `b2a0af714dca76713095305da597b9a322da92c2183d22f9e8f60a7dd7a7812b`。未重跑全量套件、真实 UFW 矩阵或 Alpine 重启；监听器和防火墙逻辑未修改。

## 发布包与草稿验收

从发布提交以 `git -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` 导出源码，传至专用机 `/var/tmp/vpsctl-release-0.8.18.PNhW3uWF/source`。以下证据路径相对此远端发布根目录。

| 检查 | 结果与日志 |
| --- | --- |
| `LC_ALL=C bash tests/unit/test-release-build.sh` | PASS；`evidence/release-build.log`，覆盖完整资产、摘要、归档边界、权限、版本来源和失败交付。 |
| `VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh` | PASS；`evidence/entry-version.log`。 |
| `LC_ALL=C bash scripts/build-release.sh ../build-assets` | PASS；`evidence/reference-build.log`，22 个参考资产及 `evidence/build-assets.sha256`。 |
| 草稿重新下载 | PASS；22 个 GitHub 草稿资产与参考构建逐字节一致，全部 SHA-256 通过；`evidence/draft-compare.log`、`draft-sha256.log`、`draft-asset-count.txt`。 |

`evidence/preflight-status` 为 `preflight_exit=0`。沿用上一版安装验收驱动，适配目标 `0.8.18`、上一真实版本 `0.8.17` 和独立目录；缓存的实际 v0.8.17 资产与新下载的公开 manifest 一致，21 项登记资产摘要通过，v0.8.9 仍使用原 schema 1 资产。驱动增加已安装 TCPing 与发布包身份、LoadState 判断及未安装 status 无 stderr 的检查，不向宿主部署监听服务。两个驱动的远程语法检查和完整 ShellCheck 通过；准备时一个 ShellCheck 注释指令语法错误已修复并定向复验，记录为 `acceptance-preparation.log`。

```bash
bash /var/tmp/vpsctl-release-0.8.18.PNhW3uWF/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.8.18.PNhW3uWF/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

PASS；`acceptance/accept-draft.log` 包含全新/重复/离线安装、全部功能及共享依赖按需缓存、同版本修复、失败升级回退、真实 schema 1/2 双向迁移、实际 `v0.8.17 → v0.8.18` 仅下载 manifest/安装器/core 的升级，以及普通卸载/purge 的业务数据保护。已安装 TCPing 身份与未安装状态检查通过。`acceptance/evidence/status` 为 `test_exit=0`、`restore_exit=0`，管理器及共享 UFW 恢复比较均无差异。

## 正式发布与公开入口

正式发布并设为 latest 后执行 `bash /var/tmp/vpsctl-release-0.8.18.PNhW3uWF/acceptance/public-smoke.sh`，PASS。`acceptance/public-smoke.log` 覆盖 latest/固定 tag 的 manifest 与安装器身份、latest 全新安装、按需和离线缓存、固定 tag 安装与显式指定版本更新，以及实际 v0.8.17 到 v0.8.18 的 core-only 更新。通过公开资产安装的 TCPing 与发布包身份一致，未安装状态查询成功且 stderr 为空。

公开 manifest 和安装器与验收草稿逐字节一致，记录为 `evidence/published-draft-identity.log`；manifest SHA-256 为 `52a7fddb226ed611e2026639a8588f0fa699c2004e21d43c902e5f701a4983af`，记录为 `evidence/published-manifest.sha256`。

`acceptance/public/evidence/status` 为 `test_exit=0`、`restore_exit=0`。`managed-restore-compare.log` 和 `ufw-restore-compare.log` 均无差异，业务配置、功能状态、libexec 和备份标记保持。专用机恢复为原 `vpsctl 0.8.15`，`current` 指向 `/usr/local/lib/vpsctl/releases/0.8.15`；测试标记无残留，备份与详细日志留在专用机。

## 更新

schema 2 用户执行 `vpsctl self update --version v0.8.18`，然后以 `vpsctl service tcping status` 查看状态。原日志中的 TCPing 已成功启动，此次修复不要求重装或重启现有监听服务。v0.8.9 的 schema 1 用户仍按 README 下载校验安装器/manifest、普通卸载后重装。
