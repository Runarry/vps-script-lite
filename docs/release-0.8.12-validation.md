# v0.8.12 发布验收

`v0.8.12` 于 2026-10-02 22:57:35（Asia/Singapore）正式发布并成为 latest。发布提交为 `1af9f1d4c6bd1c9e7acb19fc7bbfedaa494d9ae3`，GitHub Actions [构建记录](https://github.com/Runarry/vps-script-lite/actions/runs/37023234559) 成功，正式 [Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.8.12) 提供完整的 22 个 schema 2 资产。上一个正式版本 `v0.8.11` 保留，可作为回退版本。

所有项目测试、独立参考构建和真实安装验收均通过 `ssh host-vps-scripts` 在专用环境执行；GitHub Actions 构建正式发布资产。本机仅编辑、查看仓库差异、进行版本控制和传输源码／资产，没有运行项目代码。

## 源码与验证范围

源码使用 `git -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` 从发布提交导出，传至 `/var/tmp/vpsctl-release-0.8.12/source`。发布准备只调整根 `VERSION` 和当前版本文档；运行代码来自原 HEAD `073894eee137624a96ee9acd8e0970537551685d`。

本版包含重装快捷菜单、iperf3 管理、磁盘 Swap 管理，以及 Hysteria2 双核模板、代理节点向导和端口跳跃。对应真实功能证据继续复用[重装验收](reinstall-validation.md)、[iperf3 验收](iperf3-validation.md)、[Swap 验收](swap-validation.md)及 [Hysteria2 验收](proxy-hy2-validation.md)，不重复执行未被版本更新影响的系统变更。

以下命令在远端源码目录执行，日志保存在 `/var/tmp/vpsctl-release-0.8.12/evidence/`：

| 检查 | 结果与日志 |
|---|---|
| `bash tests/unit/test-release-build.sh` | PASS，覆盖完整资产、严格清单、摘要、归档路径与权限、版本来源及构建失败交付；`test-release-build.log`。 |
| `bash tests/unit/test-release-workflow.sh` | PASS，21 次工作流场景；`test-release-workflow.log`。 |
| `bash tests/unit/test-distribution.sh` | PASS，覆盖分发校验、缓存、更新失败和卸载边界；`test-distribution.log`。 |
| `VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh` | PASS；`entry-version.log`。 |
| `LC_ALL=C bash scripts/build-release.sh /var/tmp/vpsctl-release-0.8.12/build-assets` | PASS，生成 22 个资产；`build.log` 和 `build-assets.sha256`。 |

`preflight-status` 记录 `preflight_exit=0`。本次未重跑完整默认套件、全部真实服务测试、跨发行版矩阵或项目 ShellCheck／shfmt；各功能已有静态检查的等级、告警和受限范围仍以原验收记录为准。

## 草稿资产与安装验收

标签触发工作流后，重新从 GitHub 下载全部草稿资产并传至 `/var/tmp/vpsctl-release-0.8.12/draft-assets`。`diff -r build-assets draft-assets` 无差异，`sha256sum -c` 对全部 22 个文件通过。日志为 `draft-compare.log`（空）和 `draft-sha256.log`。

沿用上一版发布验收脚本，调整目标／上一版版本号、资产数量及新增的 Swap、iperf3 功能帮助。上一版资产来自此前已验收的真实 v0.8.11 Release；重新下载公开 manifest，与留存清单比较一致，并再次校验全部资产摘要。v0.8.9 schema 1 使用此前留存的真实发布资产。

```bash
bash /var/tmp/vpsctl-release-0.8.12/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.8.12/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

退出码为 0。覆盖仅安装 core、16 个功能帮助及共享依赖按需下载、离线帮助、TCPing 功能缓存删除与重新下载、同版本更新修复、schema 1／2 双向普通卸载后重装、普通卸载与 purge 保留业务数据标记。使用实际 v0.8.11 资产验证更新下载失败保持原 current 和原文件，成功更新到 v0.8.12 仅获取 manifest、安装器和 core；新版首次使用 BBR 才下载共享依赖和功能包。

主日志为 `evidence/draft-install.log`。下载轨迹、前后文件摘要和恢复核对位于 `acceptance/evidence/`；`status` 记录 `test_exit=0`、`restore_exit=0`，受管目录和共享 UFW 状态的恢复比较日志为空。

## 正式发布与公网验收

草稿验收完成后正式发布，设置 latest，再执行：

```bash
bash /var/tmp/vpsctl-release-0.8.12/acceptance/public-smoke.sh
```

退出码为 0。通过真实 GitHub 公开 URL 验证 latest 与固定 v0.8.12 的 manifest、安装器一致。覆盖 latest 全新安装、固定 tag 安装、首次 BBR／TCPing 功能下载、离线 BBR 帮助、显式指定版本更新修复缓存，以及实际 v0.8.11 到 v0.8.12 公网升级。跨版本更新只获取三个 core 分发资产，不预取功能包；首次再次使用 BBR 才下载新版依赖。

manifest SHA-256 为 `960712d77763b96ec84482b82f12b28c20f83d83dd72721c1345d367b1a652d6`。公开 manifest 和安装器与已验收草稿逐字节一致，记录为 `evidence/published-manifest.sha256` 和 `evidence/published-draft-identity.log`。主日志为 `evidence/public-smoke.log`；实际请求、期望请求和恢复记录位于 `acceptance/public/evidence/`，`status` 记录 `test_exit=0`、`restore_exit=0`。

两轮实际安装验收均保存并恢复入口、安装目录、self 元数据及共享 UFW 状态，恢复比较通过。测试前后入口仍报告 `vpsctl 0.5.0`，`current` 仍为 `/usr/local/lib/vpsctl/releases/0.1.0`；备份和完整证据保留在远端发布验收目录中。

## 已知功能限制

Xray 26.9.30 客户端关闭 Chrome 模拟、连接 sing-box 1.14.2 服务端时，Hysteria2 UDP 回包仍存在上游兼容失败，TCP 和端口跳跃可用。Release 说明保留该限制及已实测替代组合，详见 [Hysteria2 上游限制](proxy-hy2-validation.md#上游限制与可用替代)。重装菜单也未逐项真实安装全部预设，包括 Windows 和 UEFI 实际写入；不将菜单预设或本次分发验收记为这些功能组合的完整通过。
