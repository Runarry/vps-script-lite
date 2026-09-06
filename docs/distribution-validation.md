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

## 恢复信息

真实安装测试开始前备份 `/usr/local/bin/vpsctl`、`/usr/local/lib/vpsctl` 和 `/var/lib/vpsctl/self`，退出时恢复，清理测试标记。已确认测试机 `current` 恢复到原 `0.1.0` 版本。

对已遇到入口缺执行位故障的机器，在 root shell 中执行：

```bash
chmod 0755 /usr/local/lib/vpsctl/current/bin/vpsctl
vpsctl --version
```

该命令只恢复当前入口的执行权限；后续升级应使用包含本修复的新 Release。
