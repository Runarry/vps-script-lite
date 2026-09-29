# v0.8.10 发布验收

本记录用于跟踪 `v0.8.10` 的发布资产和实际安装验收。项目测试、静态检查、独立参考构建和实际功能验收均在 `host-vps-scripts` 专用 Debian 13 环境执行；GitHub Actions 负责正式 Release 资产构建。本机仅编辑文件、只读检查仓库以及执行发布所需的版本控制和资产传输操作，不运行项目代码。

## 验收范围

- 从目标提交构建 schema 2 Release 资产，验证清单、摘要和上传后重新下载的资产完全一致。
- 使用已发布的真实 `v0.8.9` schema 1 资产，验证普通卸载后安装 `v0.8.10`，再从 schema 2 普通卸载并装回 schema 1；各次迁移均保留业务数据标记。
- 直接以重新下载的 draft 资产安装：首次只取清单、安装器和 core；功能包及共享库按需下载；已缓存的帮助命令离线可用。
- 验证已安装的 TCPing 卸载只清除其功能缓存，再次调用帮助只重新下载 TCPing 包；验证同版本 `self update` 修复安装器和清单缓存。
- 验收后还原测试前的受管安装路径与共享 UFW 状态，并核对还原结果。既有 TCPing 服务及 UFW 功能验收结果见相关功能文档；本次只检查分发行为。

## 目标代码与已完成的静态检查

目标提交为 `5510eebf3bf02f588a11f10afa48d6f91a30bb4c`。该提交以 LF 行尾导出到专用主机的 `/var/tmp/vpsctl-release-0.8.10/source`，独立参考构建位于 `/var/tmp/vpsctl-release-0.8.10/build-assets`，共 20 个资产。

自 `v0.8.9` 以来改动的 26 个 Bash 文件在专用主机通过 `shellcheck -x -P SCRIPTDIR --severity=error --extended-analysis=false`；Python 模块通过 `py_compile`。三个版本相关脚本的 `shfmt -d -i 4 -ci` 差异与基线提交 `155ff0a67967141553ab7e10669940793a7fcf74` 逐字节相同，因此这里只确认没有新增格式差异，不把整仓库格式记为通过。原始记录位于专用主机 `/var/tmp/vpsctl-release-0.8.10/evidence/` 的 `shellcheck.log`、`shfmt.log` 和 `shfmt-baseline.log`。

在该源码导出目录运行 `bash tests/run.sh`，退出码为 `0`，末行是 `PASS: all tests`。该脚本包含所列 Bash 语法检查、全部单元测试和主管理入口集成测试。完整输出位于同一证据目录的 `full-suite.log`。

随后以真实 `v0.8.9` schema 1 发布资产运行 `VPSCTL_TEST_LEGACY_ASSET_DIR=/var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy VPSCTL_TEST_TCPING_UNINSTALL=1 bash tests/integration/test-distribution-real.sh`，退出码为 `0`，末行为 `PASS: distribution real integration test`。该测试在真实安装路径覆盖旧格式引导、按需功能缓存、离线帮助、已安装 TCPing 的缓存删除与重新下载、同版本更新、跨版本升级、普通卸载与 purge。测试后原受管入口恢复为 `vpsctl 0.5.0`，`current` 仍指向原 `releases/0.1.0`。输出位于同一证据目录的 `distribution-real.log`。测试脚本从同一源码自行构建并调整夹具，未直接使用前述 `build-assets`；重新下载的 draft 资产另行验收。

## Draft 资产与实际安装

GitHub Actions 工作流 [运行记录](https://github.com/Runarry/vps-script-lite/actions/runs/36537968837) 成功构建 draft。20 个资产从 GitHub 重新下载到专用主机的 `/var/tmp/vpsctl-release-0.8.10/draft-assets`，与独立参考构建 `diff -r` 完全一致，`sha256sum -c` 对全部 20 个文件均通过。证据为 `/var/tmp/vpsctl-release-0.8.10/evidence/` 下的 `draft-compare.log`（空）、`draft-sha256.log` 和 `build-assets.sha256`。

在专用主机运行：

```bash
bash /var/tmp/vpsctl-release-0.8.10/acceptance/accept-draft.sh \
  /var/tmp/vpsctl-release-0.8.10/draft-assets \
  /var/tmp/vpsctl-bootstrap-schema.6xaXqa3H/legacy
```

退出码为 `0`。验收程序先核对新旧两版清单及其所引用资产摘要，再以重新下载的 draft 资产作为下载源，在真实安装路径完成 `schema 1 → 2 → 1 → 2` 的普通卸载后重装。每次迁移均保留 `/etc/vpsctl`、`/var/lib/vpsctl/network`、`/usr/local/libexec/vpsctl` 和 `/var/backups/vpsctl` 中的测试业务标记。新版本首次安装只下载 manifest、launcher 和 core；首次 BBR 只下载 `shared-command` 与 `network-bbr`；全部 14 个功能帮助加载后，三个共享包各只下载一次，随后全部帮助离线可用。已安装 TCPing 的卸载删除自身功能缓存，帮助命令只重新下载该包；同版本更新修复被故意损坏的 launcher 和 manifest 缓存。

原始日志、每阶段下载轨迹、摘要核对及恢复核对位于 `/var/tmp/vpsctl-release-0.8.10/acceptance/evidence/`。`status` 记录 `test_exit=0`、`restore_exit=0`；受管路径与共享 UFW 状态的 `tar -d` 比较日志均为空。测试后入口仍报告 `vpsctl 0.5.0`，`current` 仍解析为原 `releases/0.1.0`。

## 正式发布后的公网验收

[`v0.8.10` Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.8.10) 已正式发布并成为 latest，发布提交仍为 `5510eebf3bf02f588a11f10afa48d6f91a30bb4c`。在专用主机运行 `bash /var/tmp/vpsctl-release-0.8.10/acceptance/public-smoke.sh`，退出码为 `0`。

脚本通过真实 GitHub 下载获取 latest 与固定 `v0.8.10` 的 manifest 和 launcher，分别逐字节一致；固定版本 manifest 的 SHA-256 为 `d1057090281429d25ca08ade5ec47a0cf51565bbc751a74543f92671e60ad0e9`，两份公开文件也与已验收的 draft 文件一致。通过 latest 下载的安装器全新安装时，实际网络请求为 latest manifest、固定版本 launcher 和 core。首次 BBR 帮助只获取 `shared-command` 与 `network-bbr`，随后禁用下载器仍可离线运行。显式 `self update --version v0.8.10` 修复被故意损坏的缓存；普通卸载后，通过从固定标签下载的安装器和清单重新安装成功，首次 TCPing 帮助按需下载其功能包。

公网验收日志、下载 URL 记录和恢复核对位于 `/var/tmp/vpsctl-release-0.8.10/acceptance/public/evidence/`。`status` 记录 `test_exit=0`、`restore_exit=0`；受管路径与共享 UFW 状态的 `tar -d` 比较日志均为空。最终入口仍报告 `vpsctl 0.5.0`，`current` 仍解析为测试前的 `releases/0.1.0`。TCPing 服务启动和真实 UFW 功能沿用先前已通过的功能验收，本次发布检查聚焦分发资产、缓存与迁移。
