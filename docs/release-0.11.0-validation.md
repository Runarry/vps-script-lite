# v0.11.0 发布验收

`v0.11.0` 于 2026-11-01 10:25:47（Asia/Singapore）正式发布并设为 latest，非 prerelease。发布提交为 `541b33da1359e685888bcf68f597a7b94701cd58`；[GitHub Actions 构建](https://github.com/Runarry/vps-script-lite/actions/runs/41264457524) 全部成功。[正式 Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.11.0) 提供 27 个 schema 2 在线资产、8 个离线归档及统一离线 SHA-256 清单，共 36 项。上一正式版本 `v0.10.0` 保留。

本次发布常用运维与代理离线分发。功能范围、断网依赖安装、真实服务及失败回滚的既有结果见[离线验收记录](offline-validation.md)。所有本轮人工构建、静态检查及执行验收均通过 `ssh host-vps-scripts` 完成；本机只编辑、操作 Git/GitHub、下载与传输文件。GitHub CLI 按用户要求在沙盒外执行。

专用主机发布目录为 `/var/tmp/vpsctl-release-0.11.0-541b33d/`，下列证据路径均相对于该目录。源码从发布提交以 LF 导出；实际草稿来自标签触发的 Actions，验收重新下载这些草稿资产。

## 构建与草稿

| 检查 | 结果与证据 |
| --- | --- |
| 发布前交付及版本入口 | PASS；`VPSCTL_TEST_ONLY=release-delivery bash tests/unit/test-release-build.sh`、`VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh`；`evidence/release-delivery.log`、`entry-version.log`。 |
| 参考在线构建 | PASS；`bash scripts/build-release.sh ../build-assets` 生成 27 项；`evidence/reference-build.log`、`build-assets.sha256`。 |
| 草稿资产完整集合 | PASS；36 个名称精确匹配；全部实际文件与 GitHub 资产摘要一致；27 个在线文件与参考构建逐字节相同；`evidence/draft-release.json`、`draft-online.log`。 |
| 8 个离线归档 | PASS；外层 SHA-256 与汇总清单及 GitHub 摘要相同，包内全部文件摘要、平台元数据及在线 manifest 已核对；`evidence/offline-package-checks.tsv` 及各目标元数据文件。 |
| 草稿在线生命周期 | PASS；严格 manifest/全部 bundle、首次及重复安装、按需与缓存加载、同版本修复、失败升级保留旧版、真实 `v0.10.0 → v0.11.0` core-only 升级及普通卸载/purge；`evidence/draft-acceptance.log`、`acceptance/evidence/`。 |
| 实包离线生命周期 | PASS；首次导入全部 25 个 bundle，删除原解压目录后恢复 TCPing 缓存，以保留资源执行同版本导入，实际公开 v0.10.0 安装经新包安装器离线升级至 v0.11.0；`evidence/offline-smoke.log`、`offline-smoke/`。 |

离线流程的 curl/wget 拒绝桩调用记录为空，`self status` 显示目标平台和四项组件版本。v0.10.0 尚无 `self update --offline-dir` 参数，跨版本离线验收直接运行 v0.11.0 包内的 `vpsctl.sh --offline-dir ...`。

本次统一解析的上游快照为 Xray `v26.10.31`、sing-box `v1.14.4`、lego `v5.6.0`、RFW `v0.1.9`。8 包的每个 DEB 与原始上游程序资产均逐项比对，和先前已完成断网安装及二进制检查的资源完全一致；相应系统依赖与真实服务结果继续有效，未重复这部分执行。GitHub Release JSON 中的下载计数等审计数据可随查询时间变化，不作为程序资源的身份。

本轮 Actions 使用原生 amd64/arm64 runner 进行匹配构建及二进制兼容检查。此前专用主机的 ARM64 断网依赖安装验收使用 QEMU；未新增真实 ARM 服务或防火墙规则验收，Debian 13 ARM64 的 nft 仿真限制继续保留。

准备阶段单独分析公共验收库产生调用方 `ENTRY` 变量提示；按两个真实入口连同公共库分析后，ShellCheck 零诊断。首轮离线驱动将导入提示和版本输出一起断言，驱动断言失败且基线恢复成功；修正为读取实际安装版本后通过。两者均未修改产品代码，初轮材料保留在 `evidence/preparation.log`、`offline-smoke-first*`。

## 正式公开资产与恢复

正式发布后执行 `bash acceptance/public-smoke.sh` 和 `python3 public-hashes.py`：

- PASS：latest 与固定 `v0.11.0` 的安装器、manifest 一致；全部 27 个公开在线资产与验收草稿逐字节相同。
- PASS：公开首次安装、指定版本更新及同版本缓存修复、实际 `v0.10.0 → v0.11.0` 在线升级，以及升级后的按需下载和离线缓存。
- PASS：8 个公开离线归档和汇总清单重新下载并核验摘要，与已验收草稿一致。使用流式校验控制专用主机的磁盘占用。
- PASS：草稿在线、实包离线和正式公开三组验收均为 `test_exit=0`、`restore_exit=0`；原管理器、UFW/业务文件、运行锁及服务/调度状态按对应快照恢复。

证据为 `evidence/public-smoke.log`、`public-offline-hashes.log`、`public-offline-checks.tsv`、`public-release.json`，以及 `acceptance/evidence/status`、`evidence/offline-smoke/status`、`acceptance/public/evidence/status`。在线 manifest SHA-256 为 `55853a8b38f2fd819e7bd7356a8127666b53325cdc13ae0b8399d7028a20f674`。

本轮未运行默认完整测试套件，未重复依赖未变化的八平台安装和真实服务验收，未进行 ACME 签发、公网代理传输或真实 ARM 硬件验收。RFW 地域过滤仍需联网。验证结果不扩大上述功能验收的支持范围。
