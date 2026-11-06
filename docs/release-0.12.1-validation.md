# v0.12.1 发布验收

`v0.12.1` 于 2026-11-06 15:34:15（Asia/Singapore）正式发布并设为 latest，非 prerelease。发布提交为 `e49ebdd06cea4f69097987299914b29dc30b8e23`；[GitHub Actions 构建](https://github.com/Runarry/vps-script-lite/actions/runs/42178945761) 全部成功。[正式 Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.12.1) 提供 26 个 schema 2 在线资产、8 个离线归档及统一离线 SHA-256 清单，共 35 项。上一正式版本 `v0.12.0` 保留。

本次补齐 Alpine/OpenRC 的 SSH 密钥添加与生成、公钥认证启用、root/密码登录策略及备份恢复。账户管理与 SSH 端口事务仍限 systemd。Alpine 3.23.8/OpenRC 和 Debian 13/systemd 的真实 SSH 登录、取消生成、权限、幂等、策略恢复及回归测试复用[访问管理验收](access-management.md#2026-11-06-alpineopenrc-密钥访问验收)，不重复与版本号无关的功能矩阵。

所有本轮人工构建、校验与执行验收均通过 `ssh host-vps-scripts` 完成，本机只编辑、操作 Git/GitHub、下载与传输文件。专用主机证据目录为 `/var/tmp/vpsctl-release-0.12.1/`。发布提交以 LF 导出，253 个准备阶段源码文件与提交逐字节相同；证据为 `evidence/commit-source-identity.log`。

## 构建与草稿验收

| 检查 | 结果与证据 |
| --- | --- |
| 发布交付与版本入口 | PASS。`VPSCTL_TEST_ONLY=release-delivery bash tests/unit/test-release-build.sh`、`VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh`；`evidence/release-delivery.log`、`entry-version.log`。 |
| 在线资产与完整集合 | PASS。26 个草稿在线资产与 `LC_ALL=C bash scripts/build-release.sh ../build-assets` 的参考构建逐字节相同；严格 manifest、摘要、路径、注册表文件集合、35 项完整资产名称和摘要通过；`evidence/draft-online.log`、`draft-release.json`。 |
| 八个离线归档 | PASS。外层摘要同时匹配 GitHub 与汇总清单，包内全部文件摘要、平台、在线资产、三项上游程序和 APT 清单通过；`evidence/vpsctl-offline-*.verified.json`。 |
| 草稿在线生命周期 | PASS。全新与重复安装、全部命令按需下载、离线缓存、同版本修复、实际 `v0.12.0 → v0.12.1` 下载失败回退及仅 core 升级、普通卸载、purge 和重装；`acceptance/draft-run.log`、`draft/evidence/`。 |
| 实包离线生命周期 | PASS。Debian 13/amd64 实包首次导入、删除原解压目录后的功能缓存恢复、同版本导入，以及实际 `v0.12.0 → v0.12.1` 离线升级；断网桩记录为空，`acceptance/offline-run.log`、`offline/evidence/`。 |
| 更新后系统依赖 | PASS。Debian 12/13、Ubuntu 22.04/24.04 各自的 amd64/arm64 共八种目标，在匹配的官方镜像内以 `--network none` 验证空包数据库的依赖闭包解析、真实 APT 安装、`dpkg --audit` 和三项上游程序执行；逐个平台处理以控制磁盘占用。结果见 `evidence/platform-*.log`；ARM 为 QEMU 用户态仿真。 |
| 验收驱动静态检查 | PASS。四项 shell 驱动的 `bash -n`、warning 级 ShellCheck 和三项 Python AST 解析；`acceptance/static-checks.json`。 |

Xray `v26.10.31`、sing-box `v1.14.4`、lego `v5.6.0` 的两个架构资产与上一版逐项相同；系统依赖包含 APT、DNS 工具、CA 证书和基础库更新，差异明细为 `evidence/dependency-payload-reuse.json`。不将归档完整性校验等同于系统依赖安装通过；ARM 执行采用专用机的 QEMU 用户态仿真，不声称真实 ARM 硬件或 ARM 防火墙规则验收。

草稿在线、离线及公开在线三组验收均为 `test_exit=0`、`restore_exit=0`，原管理器、业务文件、包状态、计划任务、锁、服务和静态防火墙规则恢复比对通过。临时离线包按顺序传入并在校验、执行完成后删除，验收容器和本次拉取的镜像已清理，保留日志、元数据和摘要。

## 正式公开复核

PASS：公开 latest 与固定 tag 的安装器、manifest、全部在线资产均与验收过的草稿一致；使用公开下载完成全新与重复安装、功能按需下载、断网缓存、实际 `v0.12.0 → v0.12.1` 显式更新及失败回退、卸载和重装。证据为 `acceptance/public-run.log`、`public/evidence/`。

PASS：八个公开离线归档和汇总清单再次通过流式下载计算摘要，与 GitHub 元数据、已验收草稿和汇总清单完全一致，35 项公开资产身份保持不变。证据为 `evidence/public-release.json`、`public-offline-hashes.log`、`public-offline-checks.tsv` 和 `summary.json`。

在线 manifest SHA-256 为 `0beefa14ca2cb2cf7d11aad17ff626b64e0e842fa8c6e3d670fd6615dd60c9b4`。必要时可使用 `vpsctl self update --version v0.12.0` 重新安装保留的上一版；这不恢复已经独立修改的 SSH 业务配置，SSH 策略恢复使用对应的访问管理备份。

本轮不运行默认完整测试套件，不重复 SSH 端口事务、防火墙功能矩阵、真实 ACME 签发或真实 ARM 硬件验收。功能脚本既有静态诊断及支持边界见访问管理验收记录。
