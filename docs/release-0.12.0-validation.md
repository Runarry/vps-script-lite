# v0.12.0 发布验收

`v0.12.0` 于 2026-11-01 22:11:40（Asia/Singapore）正式发布并设为 latest，非 prerelease。发布提交为 `0064a1b268845b38df0a03ed2c1bfec6e8a250fa`；[GitHub Actions 构建](https://github.com/Runarry/vps-script-lite/actions/runs/41314288474) 全部成功。[正式 Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.12.0) 提供 26 个 schema 2 在线资产、8 个离线归档及统一离线 SHA-256 清单，共 35 项。上一正式版本 `v0.11.0` 保留。

本次统一使用原生 nftables，移除 UFW/RFW 公开入口、共享实现和对应发布资源。首次启用按现有服务配置重建规则并备份、退役旧后端，不导入旧手工规则。接口及恢复边界见 [nftables 管理](nftables-management.md)，真实防火墙、代理中转、PO0、Docker、SSH、HTTP-01、Fail2ban、测速服务和 OpenRC 重启结果复用[功能验收记录](nftables-validation.md)。本次发布提交在功能提交 `216b16a` 上仅修改版本号和说明。

所有本轮人工构建、静态检查及执行验收均通过 `ssh host-vps-scripts` 完成。本机只编辑、操作 Git/GitHub、下载与传输文件。专用主机发布目录为 `/var/tmp/vpsctl-release-0.12.0/`，下列证据均相对于该目录；源码从发布提交以 LF 导出。

## 构建与草稿验收

| 检查 | 结果与证据 |
| --- | --- |
| 发布交付与版本入口 | PASS。`VPSCTL_TEST_ONLY=release-delivery bash tests/unit/test-release-build.sh`、`VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh`；`evidence/release-delivery.log`、`entry-version.log`。 |
| 全部在线资产 | PASS。专用机以 `LC_ALL=C bash scripts/build-release.sh ../build-assets` 生成参考资产；实际草稿 26 项与参考构建逐字节一致，严格 manifest、SHA-256、归档路径和注册表文件集合通过；`evidence/reference-build.log`、`draft-online.log`。 |
| 完整草稿集合 | PASS。实际 GitHub 草稿 35 项名称、大小和资产摘要精确匹配；24 个 bundle 无 `network-ufw`、`network-rfw`、`shared-ufw`；`evidence/draft-release.json`。 |
| 八个离线归档 | PASS。每包外层摘要同时匹配 GitHub 与汇总清单，包内全部文件摘要、路径、平台、在线资产、三项上游程序和 APT 清单通过；各平台 `evidence/*package*`、`*.verified.json` 和元数据文件。 |
| 草稿在线生命周期 | PASS。全新与重复安装、原生功能四项按需依赖、全部命令帮助与断网缓存、同版本缓存修复、实际 `v0.11.0 → v0.12.0` 失败下载回滚及仅 core 升级、普通卸载、purge 和重装；`acceptance/draft-run.log`、`draft/evidence/`。 |
| 实包离线生命周期 | PASS。Debian 13 / amd64 实包首次导入、删除原解压目录后的 nftables 功能缓存恢复、同版本离线导入，以及实际 `v0.11.0 → v0.12.0` 离线升级；`acceptance/offline-run.log`、`offline/evidence/`。 |
| 验收驱动静态检查 | PASS。四项 shell 驱动的 `bash -n`、warning 级 ShellCheck 及 Python 静态解析；`acceptance/static-checks.json`。 |

原生入口首次功能下载精确为 `shared-command → shared-nftables → service-proxy → network-nftables`；代理依赖仅缓存脚本，不安装或启动代理。离线流程的 curl/wget 拒绝桩记录为空。卸载、purge 和升级均保留业务标记。

离线程序快照为 Xray `v26.10.31`、sing-box `v1.14.4`、lego `v5.6.0`，不含 RFW。八种平台的所有保留 DEB 和三项上游程序与上一版已验收资源逐项相同；系统包清单仅移除 `ufw`。复用此前有效的依赖安装及二进制执行结果，没有重复八平台软件包安装；证据为 `evidence/dependency-payload-reuse.json`、`dependency-payload-reuse.log`。Actions 使用匹配的原生 amd64/arm64 runner 构建和检查二进制；专用机既有 ARM 执行采用 QEMU，不声称真实 ARM 硬件验收。

参考构建首轮受专用机 locale 影响，归档顶层成员顺序与 CI 不同，解包内容相同。固定 `LC_ALL=C` 后 26 项逐字节一致；首轮材料保存在 `evidence/draft-online-first-locale.log`。首次源码导出受到 Windows Git 换行转换影响，在运行功能检查前失败；随后使用 `git -c core.autocrlf=false archive` 重新导出实际 LF 提交，检查通过。两者均未修改产品实现。

## 正式公开复核与恢复

PASS：公开在线复核覆盖 latest 与固定 tag 的安装器、manifest、全部在线资产，以及实际首次安装、指定版本升级、失败回滚和功能缓存；结果见 `acceptance/public-run.log`、`public/evidence/`。八个公开离线归档和汇总清单以流式下载重新计算摘要，与已验收草稿一致，35 项公开资产身份均保持不变；证据为 `evidence/public-release.json`、`public-offline-hashes.log`、`public-offline-checks.tsv`。

公开下载首轮遇到一次 TLS EOF，失败发生在管理器快照和变更之前。对失败的精确地址复查得到 HTTP 200 后，继续使用已核验资产完成剩余下载和公开验收；保留 `acceptance/public-first-attempt.log`、`public-network-diagnosis.json`，不将初轮记作通过。

在线 manifest SHA-256 为 `b7ab62cb56b03b2e47b031d8704ecb6cc5ca7033378258ec0609ce890926177c`。草稿在线、离线及正式公开三组验收均为 `test_exit=0`、`restore_exit=0`，管理器、业务文件、dpkg 状态、计划任务、运行锁、服务及静态 nft 规则集逐项恢复比对通过。

为满足发布空间需求，清理了已完成且恢复成功的 v0.9.1、v0.10.0 历史临时 `business.tar` 副本，保留各自日志和较新的 v0.11.0 恢复副本；被清理文件的路径、大小、SHA-256 和原恢复状态记录于 `evidence/space-recovery.txt`。

本轮未运行默认完整测试套件，未重复防火墙功能矩阵、八平台断网软件包安装、真实 ACME 签发或真实 ARM 硬件验收。此前全量递归 ShellCheck 的 OOM/超时限制及各功能的平台边界继续以对应验收记录为准。
