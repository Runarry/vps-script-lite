# v0.8.14 发布验收

`v0.8.14` 于 2026-10-19 14:19:24（Asia/Singapore）正式发布并设为 latest。发布提交为 `9dd11b4b51704ef21cd508e688d1ce97b6268a87`，GitHub Actions [构建记录](https://github.com/Runarry/vps-script-lite/actions/runs/39208630106) 成功，正式 [Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.8.14) 提供 22 个 schema 2 资产。上一正式版本 `v0.8.13` 保留，可作为回退版本。

所有项目测试、独立参考构建和安装验收均通过 `ssh host-vps-scripts` 执行；GitHub Actions 构建正式发布资产。本机只进行源码和文档编辑、仓库检查、版本控制、Release 管理及文件传输，没有运行项目代码。

## 源码与发布前检查

功能源码来自提交 `3d8107c`；发布准备只修改根 `VERSION` 和当前版本文档。从发布提交以 `git -c core.autocrlf=false -c core.eol=lf archive --format=tar HEAD` 导出源码，传至 `/var/tmp/vpsctl-release-0.8.14.6QX8zV/source`。下文证据路径相对该远端根目录。

本版包含默认代理内核更新避免隐式降级、sing-box 原生整证书指纹及 AnyTLS 默认 padding；也包含 v0.8.13 之后提交的代理回滚隔离和重启顺序、SSH 访问恢复与非 systemd 只读状态、管理入口分发、共享 UFW 需求生成、BBR/self 卸载确认及冗余 self 安装器缓存清理。

| 检查 | 结果与日志 |
| --- | --- |
| `LC_ALL=C bash tests/unit/test-release-build.sh` | PASS；`evidence/release-build.log`，覆盖资产清单、摘要、归档边界、权限、版本来源和失败交付。 |
| `VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh` | PASS；`evidence/entry-version.log`。 |
| `VPSCTL_TEST_ONLY=dispatch bash tests/integration/test-vpsctl.sh` | PASS；`evidence/dispatch.log`，覆盖管理入口与直接功能调用的分发边界。 |
| `bash tests/unit/test-security-access.sh` | PASS；`evidence/security-access.log`，包括非 systemd 只读状态及服务查询失败。 |
| `bash tests/unit/test-distribution.sh` | PASS；`evidence/distribution-unit.log`。 |
| `LC_ALL=C bash scripts/build-release.sh /var/tmp/vpsctl-release-0.8.14.6QX8zV/build-assets` | PASS；`evidence/build.log`、`build-assets.sha256`，生成完整 22 个参考资产。 |

代理结果复用 [2026-10-19 第一批兼容验收](proxy-core-compat-validation.md)。专用机对照确认五份代理模块与已验收源码逐字节一致；`relay.sh` 唯一差异是将 PEM 选项文字从“提供 PEM 证书（SPKI）”改为“提供 PEM 证书”，不改变行为。记录为 `evidence/reused-proxy-source.log`。没有重复执行已验收的代理真实链路、全仓库套件、完整内核/网络矩阵或性能基准；此前递归 ShellCheck 的资源限制仍按原验收记录披露。

## 草稿资产与安装验收

`master` 和 `v0.8.14` 标签原子推送后，由标签工作流生成草稿。重新从 GitHub 下载所有草稿资产，传至 `draft-assets/`；`diff -r build-assets draft-assets` 无差异，全部 SHA-256 检查通过，资产数为 22。证据为 `evidence/draft-compare.log`、`draft-sha256.log`、`draft-asset-count.txt`。

沿用上一版本安装验收脚本，替换目标版本、上一版本和独立工作目录，并将“重建 self 安装器副本”的断言改为本版实际约定：该副本不重建，修复 manifest 和入口摘要。使用真实 v0.8.13 发布资产；重新下载公开 manifest，与留存资产清单逐字节比较并逐项复核摘要，记录为 `evidence/previous-public-manifest.tsv`、`previous-assets-sha256.log`。schema 1 使用此前保存并验证的真实 v0.8.9 资产。

```bash
bash /var/tmp/vpsctl-release-0.8.14.6QX8zV/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.8.14.6QX8zV/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

PASS，`acceptance/evidence/status` 为 `test_exit=0`、`restore_exit=0`。覆盖 core 安装、16 个功能帮助与共享依赖按需下载、离线帮助、TCPing 缓存移除/重取、同版本元数据修复、schema 1/2 双向普通卸载后重装、普通卸载及 purge 的业务数据保护。真实 v0.8.13 更新下载失败时保留旧版本和文件；成功升级只下载 manifest、安装器和 core，新版首次使用功能才下载相应包。主日志为 `evidence/draft-install.log`。

## 公开入口验收与恢复

正式发布后，使用真实 GitHub 公开 URL 执行 `acceptance/public-smoke.sh`，结果 PASS，`acceptance/public/evidence/status` 为 `test_exit=0`、`restore_exit=0`。覆盖 latest 全新安装、固定 tag 安装、BBR/TCPing 首次按需下载、离线帮助、同版本 self 元数据修复，以及实际 v0.8.13 到 v0.8.14 的公网升级；升级只获取三个 core 分发资产，首次使用功能才重新下载依赖。请求轨迹位于 `acceptance/public/evidence/`，主日志为 `evidence/public-smoke.log`。

公开 manifest 和安装器与已验收草稿逐字节一致，记录为 `evidence/published-draft-identity.log`。manifest SHA-256 为 `b7c3cf1d83785b59c983886a1c9efb090f394824c59049dbe0e5f778be447412`，原始记录为 `evidence/published-manifest.sha256`。

两轮安装验收均保存并恢复 `/usr/local/bin/vpsctl`、`/usr/local/lib/vpsctl`、self 元数据及共享 UFW 状态，恢复比较通过；业务配置、功能状态、libexec 和备份通过独立标记确认保留。测试后入口恢复为 `vpsctl 0.5.0`，`current` 恢复为 `/usr/local/lib/vpsctl/releases/0.1.0`。备份、脚本、源码与详细证据保留在专用机，不将宿主配置或凭据提交仓库。

## 使用与兼容范围

README 保留固定 tag 下载、核验 manifest 中的安装器摘要、审阅后执行的安装流程。schema 2 用户可通过 `vpsctl --yes --non-interactive self update --version v0.8.14` 升级；v0.8.9 的 schema 1 仍需按 README 普通卸载后重装，不能直接跨格式更新。

原生整证书固定要求 sing-box `1.15.0-alpha.7+`，默认安装通道仍为稳定版。本轮没有重新验证历史 Trojan/gRPC/REALITY 及 HY2 Chrome off 的上游限制，Release 说明按已有实测版本保留提示，不宣称新版本已修复。
