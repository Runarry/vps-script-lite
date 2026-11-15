# v0.13.0 发布验收

`v0.13.0` 于 2026-11-15 19:47:13（Asia/Singapore）正式发布并设为 latest，非 prerelease。发布提交为 `7b7e980`；[GitHub Actions 构建](https://github.com/Runarry/vps-script-lite/actions/runs/43709843057) 全部成功。[正式 Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.13.0) 包含 27 项 schema 2 在线资产、8 个离线归档及汇总 SHA-256 清单，共 36 项。上一正式版本 `v0.12.2` 保留。

本次增加 `network tune`，提供 TCP 缓冲区、出口整形与端口限速，PO0 单文件提供相同入口。两个入口共享配置、运行时和锁；设置独立持久化，支持失败恢复、旧服务接管和 BBR 队列保护。安装或升级管理器不会自动调整网络配置。功能验收复用本轮已通过的 58 项定向单元测试、原生流量、队列恢复和整机重启结果，见[网络调优](network-tuning.md#本次验收)。

所有人工构建与项目检查均通过 `ssh host-vps-scripts` 执行。发布目录为 `/var/tmp/vpsctl-release-0.13.0/`，下列证据路径相对于该目录；发布源码从目标提交按 LF 导出。本机仅编辑、操作 Git/GitHub 和传输文件。

## 构建及草稿

| 检查 | 结果与证据 |
| --- | --- |
| 版本与单文件运行时 | PASS。`python3 -B scripts/embed-network-tune.py --check`、`VPSCTL_TEST_ONLY=release-delivery bash tests/unit/test-release-build.sh`、`VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh`；`evidence/release-delivery.log`、`entry-version.log`。 |
| 发布分发生命周期 | PASS。`tests/integration/test-distribution-real.sh` 与 `test-offline-distribution-real.sh`，覆盖安装、缓存、更新、错误资源、普通卸载和 purge；`evidence/distribution-real.log`、`offline-distribution-real.log`。 |
| 在线实际草稿资产 | PASS。重新下载 27 项资产，严格 manifest、摘要、归档路径及注册表文件集合通过，并与 `LC_ALL=C` 的参考构建逐字节一致；`evidence/draft-online.log`。 |
| 八个实际离线归档 | PASS。外层摘要与 GitHub 资产和汇总清单一致；共验证 1,920 条包内摘要、1,608 条 DEB 记录和 216 处在线文件副本。平台、版本、APT 索引、上游记录及所需 Python 3、iproute2、nftables、systemd 包均核对通过；`evidence/offline/archive-validation.json`、`archive-validation.log`。 |
| 实际包安装与升级 | PASS。草稿在线包首次与重复安装、调优入口冷缓存只下载 `shared-command` 和 `network-tune`、断网缓存、Python zipapp、实际 `v0.12.2 → v0.13.0` 下载失败回退与成功升级；成功在线升级只下载安装器、manifest 和 core。实际 Debian 13 / amd64 离线包完成首次安装、同版本补全、跨版本升级、删除原解压目录后的功能缓存恢复，断网操作无下载请求；`evidence/draft-lifecycle.log`、`lifecycle-draft/`。 |
| 验收驱动 | PASS。新增发布验收驱动的 Bash 语法和 ShellCheck；复用已有资产核验器，仅更新新 bundle 的数量要求。 |

草稿按 tag 的 REST 查询返回 404 后，通过 GitHub Release 查询取得实际草稿 ID，再按 ID 获取完整元数据。未重建或替换草稿资产。初次验收驱动静态检查发现动态 source 的来源提示，随后补齐正确的分发上下文和来源标注，检查通过；未修改产品实现。

## 正式公开复核

PASS：正式发布后的 36 项资产 ID、大小、摘要和上传状态均与已验收草稿一致。公开 `latest` 安装器及 manifest 下载后与草稿逐字节一致。在线 manifest SHA-256 为 `a74f5d80fbf35f468eee1f80b665734c6e6f2a1afc5b51184e5140135b573d1c`；见 `evidence/public-assets.log`、`latest-manifest.tsv`。

PASS：实际公开 HTTPS 下载完成首次安装、调优功能按需下载、缓存使用、指定 `v0.13.0` 的真实跨版本升级与失败回退，普通卸载与 purge 保留功能状态标记；`evidence/public-lifecycle.log`、`lifecycle-public/`。

草稿及公开两轮均为 `test_exit=0 restore_exit=0`，测试前后的管理器入口、发布文件、符号链接及 self 元数据快照一致。专用机原安装已恢复，日志与恢复材料保留在发布目录；没有在生产机器安装或迁移配置。

## 范围与升级

未运行项目全量测试，未重复已通过的网络功能矩阵，也未执行八平台真实网络调优或逐平台离线依赖安装。八包的归档检查不等同于这些运行验收；实际离线安装使用 Debian 13 / amd64。正式发布后复用身份未变的草稿离线包检查，没有重复下载八个大型归档。

schema 2 用户可执行 `vpsctl self update --version v0.13.0`，随后使用 `vpsctl network tune`。先固定 tag 下载安装器与 manifest，按清单核对安装器摘要并审阅后执行的流程见 [README](../README.md#安装)。如需回退，可重新取得 `v0.12.2` 管理器；管理器降级不会自动撤销已设置的队列、端口规则或 TCP 参数，应使用相应功能的恢复入口。
