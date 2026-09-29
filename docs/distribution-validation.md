# 分发权限修复验收

验收日期：2026-09-06。所有项目代码执行、语法检查、静态检查和功能验证均通过 `ssh host-vps-scripts` 在专用环境完成。

## 原因与修复

- Git 中的 `bin/vpsctl` 为 `100644`；原构建直接归档源码权限，因此 core 入口缺少执行位。
- 全新安装原本会执行 `chmod 0755`，自更新却仅解压和复制，然后切换 `current`。后续启动直接 `exec` 入口时发生 `Permission denied`。
- 原安装器复用已存在的受管版本时不修复权限，且新版本根目录会保留 `mktemp -d` 的 `0700`，影响普通用户启动。
- 构建现在显式归档父目录并规范权限。升级在激活前规范全部已验证的版本文件，失败返回 20 并保留旧版本。安装器对新装和校验后复用的目录统一设置权限。

## 验证结果

在旧代码副本中加入升级后直接执行入口的断言，复现 `current/bin/vpsctl: Permission denied`，测试失败；修复后通过。

在远端源码副本中执行以下检查，均通过：

```bash
for file in vpsctl.sh lib/distribution.sh scripts/build-release.sh \
  tests/unit/test-distribution.sh tests/unit/test-release-build.sh \
  tests/integration/test-distribution-real.sh; do
  bash -n "$file"
done
shellcheck vpsctl.sh lib/distribution.sh scripts/build-release.sh \
  tests/unit/test-distribution.sh tests/unit/test-release-build.sh \
  tests/integration/test-distribution-real.sh
bash tests/unit/test-distribution.sh
bash tests/unit/test-release-build.sh
bash tests/integration/test-distribution-real.sh
bash tests/integration/test-vpsctl.sh
```

覆盖缺执行位的 core、严格 `umask 077`、不同源码权限下构建结果一致、权限设置失败不切换版本、安装后普通用户启动、重装修复已损坏执行位，以及跨版本升级后的 root/普通用户直接启动与离线缓存使用。

真实安装测试在系统安装路径上运行，下载由本地 Release 资产替代；权限修复首次验收的跨版本目标 `0.8.1` 当时仅为测试夹具。测试包含全部领域缓存迁移、卸载及 purge 的功能数据保护检查。

2026-09-06 将项目版本提升至 `0.8.1` 后，再次通过专用环境验证版本展示、`test-release-build.sh`、`test-vpsctl.sh` 和 `test-distribution-real.sh`。跨版本目标夹具同步调整为 `0.8.2`。本次改动脚本的 `bash -n` 与 ShellCheck 均通过；内核入口使用 `shellcheck -x` 跟随其模块定义。测试退出后已确认原 `0.1.0` 安装恢复。版本提交对应本地 tag `v0.8.1`，未推送或发布 GitHub Release。

## v0.8.5 发布验证（2026-09-06）

SSH 登录策略直接应用随 `v0.8.5` 发布，版本展示和分发清单统一为 `0.8.5`；跨版本测试夹具使用 `0.8.6`。在专用主机通过变更脚本的语法与 ShellCheck 检查，以及 `test-distribution.sh`、`test-release-build.sh`、`test-vpsctl.sh`、`test-distribution-real.sh`。覆盖清单与摘要校验、规范归档、全新和重复安装、按需领域下载、离线缓存、显式更新、升级权限修复、卸载及 purge。

测试结束恢复测试前的 `vpsctl 0.5.0` 安装。发布资产先作为 draft 上传，重新下载后与专用主机的已测构建逐字节比较，并再次验证安装流程；正式发布后复核 latest 安装器、全新安装及从 `v0.8.4` 显式升级到 `v0.8.5`。后续发布检查结果记录在 GitHub Release 说明中；`v0.8.4` 为本次发布回退版本。

## v0.8.6 发布验证（2026-09-08）

本次发布增加跨版本更新成功后清理可验证受管历史 release 的行为，版本号统一为 `0.8.6`，跨版本测试夹具使用 `0.8.7`。通过 `ssh host-vps-scripts` 完成变更脚本 ShellCheck、`bash tests/run.sh`（包含语法检查、全部单元测试与主管理入口集成测试）及 `bash tests/integration/test-distribution-real.sh`，均通过。

验证覆盖历史清理归属检查、同版本跳过、更新提交前失败保留原版本、清理失败保持新版本与重试，以及全新/重复安装、领域下载、离线缓存、升级权限、普通卸载和 purge 边界。真实集成测试退出后已恢复原 `vpsctl 0.5.0` 安装。

Release 按 draft 资产复核后正式发布的流程执行，后续资产下载比对和线上安装/更新结果记录在 GitHub Release 说明中。回退目标为 `v0.8.5`，需重新下载指定 Release；新策略不保留本地自动回退版本。

## v0.8.7 发布验证（2026-09-08）

发布提交为 `09a1b551b5cfb55938fe1edba4cfd0e13e4d3474`，包含 UFW 联动、REALITY 防偷回落保护和 BIOS GRUB 安装功能。通过 `ssh host-vps-scripts` 验证库、Release 构建、分发、入口和真实安装集成；跨版本夹具同步为 `0.8.8`。功能验收复用各功能文档记录的已通过结果。

GitHub Actions 生成的八个 draft 资产重新下载到专用主机后，清单摘要全部通过，并与目标提交在 `LC_ALL=C` 下构建的资产逐字节一致。将下载资产作为真实分发测试输入，安装、重复安装、领域加载、离线缓存、更新、卸载和原安装恢复均通过。

正式发布后，latest 安装器与固定 `v0.8.7` 清单摘要一致；公开资产的全新安装、全部领域按需下载、UFW 帮助及普通用户启动通过。使用上一版真实发布资产发现以下兼容边界，并验证了保留配置的迁移路径：

- `v0.8.6` 更新器因 core 白名单不包含 `lib/ufw.sh`，拒绝直接升级到 `v0.8.7`，原版本保持可用。
- 缓存 system 领域的 `v0.8.7` 因旧包缺少 `grub-install.sh`，拒绝直接回退到 `v0.8.6`，原版本保持可用。
- 安装器在已有可执行入口时只启动当前管理器，因此重新执行安装器不能直接完成上述迁移。
- 先下载并校验目标版本的安装器和 manifest，普通卸载管理器代码（`self uninstall --confirm-uninstall`，不使用 purge），再执行固定版本安装器，可以完成 `v0.8.6 → v0.8.7 → v0.8.6 → v0.8.7`；功能配置与备份保留，最终同版本 `self update` 通过。

证据位于专用主机 `/var/tmp/vpsctl-release-0.8.7/evidence/` 的 `pre-release.log`、`draft-assets.log` 和 `published-install.log`。验证退出码均为 0；每轮对受管安装路径的内容与归属快照进行恢复核对，最终原安装恢复通过。发布标签和八个资产保持不可变，迁移说明同步至 README 和 GitHub Release。

## 自用限制简化验收（2026-09-12）

基于 `123ee35` 的工作区修改，版本保持 `0.8.7`，未打 tag 或发布 Release。所有项目代码执行均通过 `ssh host-vps-scripts`，本机仅编辑和检查仓库差异。

### 通过的验证

- `tests/run.sh` 所列全部单元测试及 `test-vpsctl.sh` 入口集成按批执行通过。BBR 的旧演练断言已更新，确认缺少工具时无需安装授权即可展示计划，包管理器、模块加载和配置写入均未执行。
- 分发单元测试覆盖新增嵌套公共库、越界/链接拒绝、缺失或损坏缓存的同版本修复、缓存修复写入失败与重试、无缓存的跨版本更新、更新提交失败恢复旧入口及一致缓存，以及普通卸载的 `--yes`、旧参数、未授权拒绝和交互取消。专用 purge 确认仍保留。
- `test-distribution-real.sh` 在真实安装路径验证安装器及更新器接受新公共库、修复缓存、无缓存升级、普通卸载和 purge，并检查业务数据保留。下载使用本地构建资产，未发布测试版本。
- 安全和代理测试验证普通确认、旧参数兼容、显式错误令牌拒绝、TLS 菜单单次清库确认、唯一兼容内核自动选择，以及 `--yes` 不绕过清库、外部内核覆盖和节点切核确认。
- `test-security-access-pubkey-real.sh` 用链接公钥为临时账户安装授权，完成真实 SSH 登录及幂等检查；`test-security-tls-real.sh` 验证真实 timer 的普通卸载保留证书和私钥；`test-security-fail2ban-real.sh` 验证真实封禁/解封及 `--yes` 仅移除受管配置；实际 Xray 的 `--yes --non-interactive service proxy restart --core xray` 成功。
- 基线 `0.8.7` 的分发校验器接受本次实际构建的全部六个 bundle 及哈希。构建文件集合、manifest 格式和安装布局未改变。

### 静态检查边界

修改脚本的 `bash -n` 通过。ShellCheck 使用 `-x -P SCRIPTDIR --extended-analysis=false` 对照基线，无新增诊断；完整数据流分析曾耗尽专用主机内存而被终止，因此不列为通过项。`shfmt -d -i 4 -ci` 在基线已有整文件风格差异，本次修改行没有新增差异，未进行无关的整文件格式化。不能将这两项表述为全仓库零告警或全格式通过。

### 恢复与证据

真实验收前对安装、SSH 受管配置、TLS、Fail2ban、代理配置及相关功能状态和备份保存快照。结束后文件快照比较、`sshd -T` 前后比较和恢复脚本均成功（`acceptance_exit=0`、`restoration_exit=0`）。原安装恢复为 `0.1.0`，SSH、Fail2ban、Xray 保持 active，TLS timer 保持 inactive；临时登录账户与 Fail2ban 网络命名空间已删除。系统日志和 Fail2ban 运行历史保留测试记录。

原始证据与恢复快照保留在专用主机 `/root/vpsctl-simplify.zcQUv6fA/evidence/`，包括单元/集成日志、`real-status.txt`、`restoration-status.txt`、`static-comparison-final.log` 和 `compatibility.log`。该目录包含系统快照，不提交仓库。

## 恢复信息

真实安装测试开始前备份 `/usr/local/bin/vpsctl`、`/usr/local/lib/vpsctl` 和 `/var/lib/vpsctl/self`，退出时恢复，清理测试标记。已确认测试机 `current` 恢复到原 `0.1.0` 版本。

对已遇到入口缺执行位故障的机器，在 root shell 中执行：

```bash
chmod 0755 /usr/local/lib/vpsctl/current/bin/vpsctl
vpsctl --version
```

该命令只恢复当前入口的执行权限；后续升级应使用包含本修复的新 Release。

## 按功能分发验收（2026-09-27，未发布）

基于 `0d38992` 的工作区修改，源码版本仍为 `0.8.9`，未修改 tag 或发布资产。新格式为 manifest schema 2，包含 core、三个共享库包及十二个公开功能包；已发布的 `v0.8.9` 仍是 schema 1，后续发布必须使用新版本。全部项目执行、语法和静态检查均通过 `ssh host-vps-scripts` 在专用 Debian 13 主机进行。

合并后的 `bash tests/run.sh` 完整通过，退出码为 `0`，包括全部单元测试、逐脚本语法检查和主管理入口集成测试。代理安装矩阵覆盖两个内核、systemd/OpenRC、下载与外部二进制登记、启动/启用失败后的恢复、部分恢复失败、LKG 保存失败，以及已登记内核重复安装和多内核部分成功。

真实安装验收通过，退出码为 `0`：

- 从 GitHub 获取实际发布的 `v0.8.9` 安装器、清单和六个旧领域包，逐项验证 SHA-256；先安装旧版并缓存 network，再普通卸载，使用工作区构建的新格式重新安装。配置、业务状态、备份及 libexec 标记均保留。
- 首次安装的下载记录恰好为 manifest、安装器和 core；通用命令库、UFW 库、测速包装库均未预装。
- 全局帮助、版本、清单、环境及 self 状态在下载器被禁用时仍可用。通过真实伪终端进入主菜单及网络分类、返回并退出，下载记录为空，仍只有 core 缓存标记。
- 首次调用 BBR 只下载 `shared-command` 和 `network-bbr`，未落盘 DNS 或 UFW 代码。十二项功能帮助均可按需加载，三个共享库各下载一次；随后禁用下载器，全部功能帮助均可离线复用。
- 在已经缓存全部功能后升级到隔离夹具 `0.8.10`，仍只请求 manifest、安装器和 core。新版本不带旧功能代码，首次再次使用 BBR 才下载新版依赖；历史版本清理、普通用户入口权限和 self 缓存修复均通过。
- 普通卸载、purge 的业务数据保护及原有 locale 场景继续通过。分发单元测试还覆盖错误哈希、下载失败与重试、缺少私有模块、包路径边界、锁内缓存重查和失效缓存修复。

关键命令在远端合并源码目录执行：

```bash
cd /var/tmp/vpsctl-lazy-autostart.sj4HrXmQ/integrated
bash tests/run.sh
VPSCTL_TEST_LEGACY_ASSET_DIR=/var/tmp/vpsctl-lazy-autostart.sj4HrXmQ/legacy \
    bash tests/integration/test-distribution-real.sh
```

受影响脚本的语法检查及 `shellcheck -x -P SCRIPTDIR --severity=error --extended-analysis=false` 均通过。代理相关脚本的无限制 ShellCheck 分析曾因测试机内存限制被终止；完整告警级别还包含既有诊断，因此不把本次结果表述为全仓库零告警。没有为既有 shfmt 风格差异重排无关代码。

真实分发测试退出时恢复 `/usr/local/bin/vpsctl`、`/usr/local/lib/vpsctl` 和 `/var/lib/vpsctl/self`，已核对 current 恢复为原 `0.1.0`。Xray 恢复为 active/enabled、sing-box 为 inactive/disabled、中转刷新服务为 active/enabled。代理的真实安装启动、LKG 和文件恢复证据另见 [代理安装验收](proxy-install-validation.md)。

原始日志保留在专用主机 `/var/tmp/vpsctl-lazy-autostart.sj4HrXmQ/evidence/`：`tests-run.log`、`tests-run.rc`、`distribution-real.log`、`distribution-real.rc`、`static-final.log` 和 `static-final.rc`。旧版发布资产和独立代理验收记录保留在同一工作目录的 `legacy/`、`proxy-real/`，不将主机配置正文或凭据提交仓库。

## 源码入口与已发布清单兼容（2026-09-29）

已在 `host-vps-scripts` 复现：`master` 安装入口要求 schema 2，但最新已发布 `v0.8.9` 的清单仍为 schema 1，首次安装因此报 `unsupported manifest schema`。该场景不需要卸载。源码入口现在校验两种格式共有的安装器元数据，并从清单指定的固定版本下载、校验和运行安装器；该发布版安装器继续严格校验自己的完整清单。当前安装逻辑与 `self update` 仍拒绝直接使用旧格式包。

以下检查均通过 SSH 在专用主机执行并通过：

- 受影响三个脚本的 `bash -n` 和 `shellcheck -x -P SCRIPTDIR --severity=error --extended-analysis=false`。
- `bash tests/unit/test-distribution.sh`：覆盖两种格式的安装器转交、固定版本下载、参数和退出码传递、临时目录清理，以及错误来源、版本、路径、TSV、摘要和 Bash 语法的拒绝。
- `bash tests/unit/test-release-build.sh`。
- `VPSCTL_TEST_LEGACY_ASSET_DIR=/var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy bash tests/integration/test-distribution-real.sh`：使用从 GitHub 下载并逐项校验 SHA-256 的真实 `v0.8.9` 资产，以标准输入执行当前源码入口，成功安装旧格式版本；随后完成源码构建的 schema 2 安装、按需缓存、更新及卸载验收。

真实分发测试在上传到专用主机的源码快照中运行，下载请求由测试映射到已校验的资产目录。测试退出时恢复 `/usr/local/bin/vpsctl`、`/usr/local/lib/vpsctl` 和 `/var/lib/vpsctl/self`；安装入口及 `current` 的前后记录一致，`current` 恢复为原 `0.1.0`。日志保留在专用主机 `/var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/evidence/`，包括 `reproduction.log`、`legacy-sha256.log`、`shellcheck.log`、`distribution-unit.log`、`release-build.log`、`distribution-real.log` 和安装前后记录。源码版本、tag 和已发布资产未改动。
