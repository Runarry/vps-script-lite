# 系统清理验收（2026-10-29）

所有项目执行通过 `ssh host-vps-scripts` 完成；本机仅编辑、读取仓库和传输文件。独立验收副本位于 `/var/tmp/vpsctl-clean-accept.bgdn87/source/`，没有修改 `/root/vps-script-lite`。原生后端环境为 Debian 13、APT 3.0.3、systemd 257.13。

## 定向检查

| 检查 | 状态与范围 |
| --- | --- |
| `bash tests/unit/test-system-clean.sh` | PASS：非法参数、非交互默认状态、普通用户只读动作、权限拒绝、零执行演练、默认拒绝、一次确认、七种软件包管理器的参数数组、未启用 APK 缓存、不支持能力、重复清理、保护数据、原生失败 `20` 和组合部分完成 `30`。包管理器执行使用函数桩，不能视为七种发行版的真实验收。 |
| 两个新测试脚本的 `bash -n`、`shellcheck -x -P SCRIPTDIR` | PASS；原生验收执行前检查。 |
| 原生 APT 清理 | PASS：演练保留测试缓存；真实 `apt-get clean` 删除独立缓存标记；重复清理成功；`/var/lib/dpkg/status` 的 SHA-256 保持一致。 |
| 真实普通用户 | PASS：`nobody` 用户执行 `status`、`--dry-run safe` 成功；实际 `--yes packages` 返回权限不足 `4`。 |
| 原生 tmpfiles 清理 | PASS：修复后普通旧文件删除、近期文件保留；两个临时根目录中 vpsctl 根目录 `d`、显式子目录 `d`、通配符子目录 `e` 规则下的旧文件均保留。跨保护与非保护路径的较长时效规则仍阻止父目录较短时效回退。fixture 清理后原有配置摘要一致。首轮缺陷与修复见下文。 |
| 原生 journal 清理 | PASS：实际执行 `journalctl --vacuum-time=30d`，报告释放 `0B`；活动 journal 的路径和 inode 保留。没有生成虚假的旧日志，不能据此宣称已观察到超过 30 天归档的删除。 |

执行命令使用远端验收副本：

```bash
bash tests/unit/test-system-clean.sh
bash -n tests/unit/test-system-clean.sh tests/integration/test-system-clean-real.sh
shellcheck -x -P SCRIPTDIR tests/unit/test-system-clean.sh tests/integration/test-system-clean-real.sh
VPSCTL_REAL_CLEAN_TEST=1 \
VPSCTL_CLEAN_RESULT_DIR=/var/tmp/vpsctl-clean-accept.bgdn87/evidence/native-final \
bash tests/integration/test-system-clean-real.sh
```

## tmpfiles 回归证据

首轮受测 `clean.sh` SHA-256 为 `706ccf05f251ba049dab20eb73afbe3c0adbabc0488c500c36c1e46cb6efab6e`。使用 fixture 专属的 `/run/tmpfiles.d/00-vpsclean-accept-<pid>.conf`，仅为测试目录设置 `5s` 时效；等待 `7s` 后刷新近期文件，再调用真实 `temp`。

预期 `/tmp/vpsctl*` 和 `/var/tmp/vpsctl*` 内文件保留；实际 `/tmp/vpsctl-clean-accept-<pid>/old` 被删除，CLI 返回成功。原生调试证据显示 `x /tmp/vpsctl*` 已读取，但单独的 `d` 规则先清理其内容。具体路径的 `--exclude-prefix` 可以阻止显式根目录与子目录规则；它在配置路径展开前生效，无法单独阻止通配符 `e` 规则。部分组件前缀 `/tmp/vpsctl`、`/var/tmp/vpsctl` 同样不能保护这些规则。增加单层子路径 `x` 仍不能保护另有通配符规则直接指定的更深目录。这些复现使用独立临时目录；fixture-only 复现不读取其他系统规则。

最终实现只读获取有效 tmpfiles 配置，将可能清理 vpsctl 路径的规则变为原生保留边界，再经标准输入执行限定 `/tmp`、`/var/tmp` 的 `--clean`；不创建持久配置。规则读取或转换失败时不执行清理。最终单元测试覆盖规则读取失败阻止原生执行；真实复验覆盖上述规则及父子时效边界，两个新测试均退出 `0`，临时规则和目录恢复状态为 `0`。

最终原生验收的 `clean.sh` SHA-256 为 `a9bd4baec75f714c8fd093c8def669a26e2f53088620b1778cc0095e0eaa3fa1`。单元测试文件 SHA-256 为 `913c9f976cf4b82d0de7fb6258484727cacd4f66c1a5c616f2170a18a93499a2`，原生验收脚本为 `bff54d891c1dcff8b18e7455af51c4d69c385891a669a2573b2184c287e96fab`。

## 证据与范围

远端证据目录为 `/var/tmp/vpsctl-clean-accept.bgdn87/evidence/`：

- `system-clean-unit-final.log`、`test-static.log`：最终定向单元和新测试静态检查；`system-clean-unit.log` 为修复前记录。
- `native-final/acceptance.log`、`native-final/source.sha256`、各动作日志：最终完整原生验收、普通用户检查与受测源码摘要。
- `native-final/dpkg.before`、`native-final/dpkg.after`、`native-final/tmpfiles.before`、`native-final/tmpfiles.after`、`native-final/tmpfiles.restored`：最终软件包状态和 tmpfiles 配置保留。
- `native/acceptance.log`、`native/source.sha256`、各动作日志：首轮原生验收与受测源码摘要。
- `native/dpkg.before`、`native/dpkg.after`：软件包状态保留。
- `native/tmpfiles.before`、`native/tmpfiles.restored`：测试规则清理后配置保留。
- `tmpfiles-native-repro.log`、`tmpfiles-descendant-repro.log`、`tmpfiles-exclude-explicit.log`、`tmpfiles-exclude-glob.log`、`tmpfiles-combined-glob.log`、`tmpfiles-partial-prefix.log`：原生排除语义的定向复现。
- `journal/cleanup.log`、`journal/active.before`、`journal/usage.before`、`journal/usage.after`：独立 journal 实际执行及活动文件保留。

## 分发、菜单及关联回归

主代理的远端副本和证据目录为 `/var/tmp/vpsctl-system-clean-root.rw3IW4/` 与其 `evidence/`；分发帮助函数的独立夹具目录为 `/var/tmp/vpsctl-clean-dist-t5ZIOx/`。

| 检查 | 状态与范围 |
| --- | --- |
| `bash tests/unit/test-libraries.sh` | PASS：20 项登记、第 4 项系统清理、功能包文件与依赖映射。证据 `libraries.log`。 |
| `bash tests/unit/test-release-build.sh` | PASS：包括 `system-clean` 的完整资产集合、25 行 manifest 和交付检查。证据 `release-build.log`。 |
| `VPSCTL_TEST_ONLY=dispatch bash tests/integration/test-vpsctl.sh` | PASS：统一入口及直接执行的既有分发回归。证据 `dispatch.log`。 |
| `bash tests/unit/test-distribution-clean.sh` | PASS：归属、未知及异常路径、演练不变、状态保护、self/下载/业务锁、部分失败与重试、功能包移除及重新下载；包含真实 bind mount 和普通用户预览。 |
| `bash tests/unit/test-distribution.sh` | PASS：既有更新、卸载和缓存行为回归；后续清理专用边界修复复用这一有效结果，并重新通过清理定向测试。 |
| `VPSCTL_TEST_CLEAN_ONLY=1 bash tests/integration/test-distribution-real.sh` | PASS：真实固定安装路径下的安装、离线浏览、残留清理、功能包清空、保护 core/shared/system-clean、配置/状态/备份/工具哨兵保留、仅重新下载所需功能包，以及实际 TTY 菜单。证据 `distribution-clean-real-final.log`。 |

受管验收通过原有下载安装流程运行，下载由本次构建资产替代，不请求发布或修改 GitHub Release。为服务存活验证启动一项临时 systemd 服务，清理前后 `ActiveState` 与 `MainPID` 一致，验收退出时停止它。原有安装及 self 元数据由既有夹具备份并恢复；随后确认 `current` 与入口恢复为原来的 `0.8.15`，没有遗留测试服务。首轮菜单测试输入漏掉返回暂停的回车，造成等待；修正输入并加超时后完整定向流程通过，不作为应用缺陷。

原生后端验收后，仅补充了演练部分候选失败时保持非零退出码的修复。最终 `bash tests/unit/test-system-clean.sh`、对应两文件的 `bash -n`、`shellcheck -x`、`shfmt -i 4 -ci -d` 全部通过，日志为 `system-clean-unit-preview-status.log`；与该错误码改动无关的原生与分发结果继续有效。最终源码摘要：

- `commands/system/clean.sh`：`bc3f55ba8bb27eb2b0a89d732a12009752b418504b37c05b962a02cff2829c4d`
- `tests/unit/test-system-clean.sh`：`92ecc84214e79e5f37b09925eda4aec5a5ddc0a8a5725d6d2b38f9f133466bf6`

## 静态检查与未运行范围

新增功能、新增清理测试和分发库的语法、ShellCheck、shfmt 检查通过；注册表和默认测试入口三项检查也通过。所有修改的 Shell 文件均通过语法检查。

既有 `test-libraries.sh` 的 ShellCheck 提示和 shfmt 解析问题、`test-release-build.sh` 的格式差异、`test-distribution-real.sh` 的 `SC2155` 与格式差异仍存在，不能记为零诊断通过。已将当前文件与 HEAD 基线在同一远端工具环境对比，规范化文件名及行号后的诊断一致，无本次新增诊断；证据为 `evidence/*baseline*`、`*.normalized`。受管真实测试先通过了仅排除既有 `SC2155` 的定向 ShellCheck。

未运行无关完整套件，没有重启或卸载软件包。DNF5、DNF、YUM、APK、Pacman、Zypper 仅完成参数分支测试，尚未在对应发行版真实运行；journal 的真实验收没有观察到超过 30 天归档的删除。仓库版本保持 `0.8.19`，未发布新 Release。
