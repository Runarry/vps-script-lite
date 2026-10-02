# v0.8.13 发布验收

`v0.8.13` 于 2026-10-03 00:05:53（Asia/Singapore）正式发布并成为 latest。发布提交为 `5db7a4e4021c2f6f0bb79e3846b76ee225e64a4d`，GitHub Actions [构建记录](https://github.com/Runarry/vps-script-lite/actions/runs/37031307485) 成功，正式 [Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.8.13) 提供完整的 22 个 schema 2 资产。上一正式版本 `v0.8.12` 保留，可作为回退版本。

所有项目测试、独立参考构建和真实安装验收均通过 `ssh host-vps-scripts` 在专用环境执行；GitHub Actions 构建正式发布资产。本机仅编辑、查看仓库差异、进行版本控制和传输源码／资产，没有运行项目代码。

## 源码与验证范围

源码使用 `git -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` 从发布提交导出，传至 `/var/tmp/vpsctl-release-0.8.13/source`。发布准备只调整根 `VERSION` 和当前版本文档；运行代码来自原 HEAD `1bb741acb29ba509b1bb38b91115b42747da87de`。

本版将 Hysteria2 双核节点分享链接改为单个数字监听端口加 `mport` 跳跃集合。中转导入继续兼容原生多端口与 `mport`，编辑会替换旧集合，关闭跳跃或普通转发会删除旧 `mport`，同时保留 TLS 指纹和其他查询参数。服务端规则和内核配置没有修改。

本轮复用 [Hysteria2 分享链接修正验收](proxy-hy2-validation.md#2026-10-02-分享链接导入兼容修正)中的协议／解析器、节点、出口 TLS、普通转发、语法及错误级 ShellCheck 结果。专用主机逐字节比较本版三份运行脚本和三份修改过的测试，与 `/var/tmp/vpsctl-hy2-uri/repo` 的已验收源码全部一致；证据为 `evidence/reused-uri-source-identity.log`。发布工作流和分发代码未改，继续复用 [v0.8.12 发布验收](release-0.8.12-validation.md)的工作流及分发单元测试结果。

以下命令在远端源码目录执行，日志位于 `/var/tmp/vpsctl-release-0.8.13/evidence/`：

| 检查 | 结果与日志 |
|---|---|
| `LC_ALL=C bash tests/unit/test-release-build.sh` | PASS，覆盖完整资产、严格清单、摘要、归档路径与权限、版本来源及构建失败交付；`test-release-build.log`。 |
| `VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh` | PASS；`entry-version.log`。 |
| `LC_ALL=C bash scripts/build-release.sh /var/tmp/vpsctl-release-0.8.13/build-assets` | PASS，生成 22 个资产；`build.log` 和 `build-assets.sha256`。 |

`preflight-status` 记录 `preflight_exit=0`。本次没有重跑完整默认套件、未变更的工作流和分发单元测试、已验收的代理回归、ShellCheck／shfmt 或真实内核／网络矩阵；仍有效的原结果按上述记录复用，不把未运行项目记为本轮通过。

## 草稿资产与安装验收

标签触发工作流后，重新从 GitHub 下载全部草稿资产并传至 `/var/tmp/vpsctl-release-0.8.13/draft-assets`。`diff -r build-assets draft-assets` 无差异，`sha256sum -c` 对全部 22 个文件通过。日志为 `draft-compare.log`（空）和 `draft-sha256.log`。

沿用上一版验收脚本，只调整目标版本与上一版版本号。真实 v0.8.12 资产来自此前已验收的 GitHub 草稿；重新下载其正式公开 manifest，与留存清单逐字节比较并再次校验全部资产摘要。证据为 `previous-public-manifest.tsv` 和 `previous-assets.sha256.log`。v0.8.9 schema 1 使用此前留存的真实发布资产。

```bash
bash /var/tmp/vpsctl-release-0.8.13/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.8.13/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

退出码为 0。覆盖 core 安装、16 个功能帮助及共享依赖按需下载、离线帮助、TCPing 功能缓存删除与重新下载、同版本更新修复、schema 1／2 双向普通卸载后重装、普通卸载与 purge 保留业务数据标记。使用真实 v0.8.12 验证更新下载失败保持原 current 和原文件，成功更新到 v0.8.13 只获取 manifest、安装器和 core；新版首次使用 BBR 才下载依赖和功能包。

主日志为 `evidence/draft-install.log`。下载轨迹、文件摘要和恢复核对位于 `acceptance/evidence/`；`status` 记录 `test_exit=0`、`restore_exit=0`，受管目录和共享 UFW 状态的恢复比较通过。

## 正式发布与公网验收

草稿验收完成后正式发布并设置 latest，再执行：

```bash
bash /var/tmp/vpsctl-release-0.8.13/acceptance/public-smoke.sh
```

退出码为 0。通过真实 GitHub 公开 URL 验证 latest 与固定 v0.8.13 的 manifest、安装器一致。覆盖 latest 全新安装、固定 tag 安装、首次 BBR／TCPing 功能下载、离线 BBR 帮助、指定版本更新修复缓存及实际 v0.8.12 到 v0.8.13 公网升级。跨版本更新只获取三个 core 分发资产；首次使用 BBR 才下载新版依赖。

manifest SHA-256 为 `54d626730c36500dd9ae2fa5ae7b149707ed9a12114f71c1a29b03ee8288bd1a`。公开 manifest 和安装器与已验收草稿逐字节一致，记录为 `evidence/published-manifest.sha256` 和 `evidence/published-draft-identity.log`（空）。主日志为 `evidence/public-smoke.log`；请求与恢复记录位于 `acceptance/public/evidence/`，`status` 记录 `test_exit=0`、`restore_exit=0`。

两轮实际安装验收均保存并恢复入口、安装目录、self 元数据及共享 UFW 状态，恢复比较通过。测试前后入口仍报告 `vpsctl 0.5.0`，`current` 仍为 `/usr/local/lib/vpsctl/releases/0.1.0`；备份和完整证据保留在远端发布验收目录中。

## 已知功能限制

`mport` 导入取决于客户端版本，本轮未直接操作客户端 GUI。原有 Hysteria2 跨核 UDP 限制仍适用：Xray 26.9.30 客户端关闭 Chrome 模拟、连接 sing-box 1.14.2 服务端时，UDP 回包存在上游兼容失败；TCP 和端口跳跃可用。Release 说明保留这些限制及已实测替代组合，详见 [Hysteria2 上游限制](proxy-hy2-validation.md#上游限制与可用替代)。
