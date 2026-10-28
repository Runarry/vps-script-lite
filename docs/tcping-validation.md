# TCPing 验收记录

日期：2026-09-29。所有项目测试、语法和静态检查均在 `ssh host-vps-scripts` 指定的 Debian 13 专用宿主上执行；Alpine 3.24.1/OpenRC 验收在该宿主的 QEMU TCG 独立 overlay 内执行。本机只编辑文件和查看仓库差异。

最终候选源码为宿主的 `/var/tmp/vpsctl-tcping-final/source`。关键 SHA-256：`commands/service/tcping.sh` 为 `c769f3abb059d621eca1fa4e30ef0df7ee6038a89672a5977468b3f6252770b2`，`commands/service/tcping/listener.py` 为 `161fee0ee7f91c7d84b1dd8db8c2a7fd7ec8420dc049f1befb455d74457e5d1b`，`lib/ufw.sh` 为 `67007aa9b5e563109fe11f903a651cbce979b1b7debdab024e9338245d9f5faa`。真实 UFW 和最后的 Debian 网络验收都使用这些应用文件。宿主运行 `7.1.13-x64v3-xanmod1` 内核。

| 检查 | 结果和证据 |
| --- | --- |
| 单元与静态检查 | **PASS**。在最终候选目录执行 `bash -n`、`shellcheck -x`、`shfmt -d -i 4 -ci` 检查两个 TCPing 测试文件，并执行 `bash tests/unit/test-service-tcping.sh`。覆盖监听器 IPv4/IPv6 顺序和并发接入、端口占用、就绪文件清理；CLI 参数、首次端口、依赖使用、状态格式、幂等、失败回滚、UFW 其他 owner 保留、缺少就绪文件后的恢复、Alpine init 映射、交互菜单、拒绝卸载，以及服务提交前后收到 SIGTERM 时的回滚或 UFW 提交。命令输出包含三项 `PASS`，最后执行于最终候选源码。提交后信号检查使用隔离的 UFW 提交替身，不代表真实防火墙在信号窗口中被强制中断。 |
| Debian/systemd 真实功能 | **PASS**。`VPSCTL_REAL_TCPING_TEST=1 VPSCTL_TCPING_NETNS=1 VPSCTL_TCPING_RESULT_DIR=/var/tmp/vpsctl-tcping-accept-20260929/real-netns-final bash tests/integration/test-service-tcping-real.sh`。从独立 netns 的 veth IPv4 和 IPv6 地址连入真实服务，验证新端口可达、旧端口与停止后的端口不可达；另对本机 IPv4/IPv6 各执行 64 个并发 accept-close。验证 systemd 运行及自启、同端口 PID 和文件保持、占用端口不破坏旧服务、改端口、stop、无端口重启、uninstall 和专属文件清理。受保护父目录下普通用户 status 明确返回 4 和 root 提示，不再误报未安装。日志：`/var/tmp/vpsctl-tcping-accept-20260929/real-netns-final/acceptance.log`。 |
| 真实 UFW 联动 | **PASS**。在记录包、配置、共享状态、sysctl、nft 和 iptables 基线后，为 SSH 22/tcp 放行并启用测试 UFW。执行 `VPSCTL_REAL_TCPING_TEST=1 VPSCTL_TCPING_NETNS=1 VPSCTL_TCPING_LIVE_UFW=1 VPSCTL_TCPING_RESULT_DIR=/var/tmp/vpsctl-tcping-accept-20260929/real-ufw-final bash tests/integration/test-service-tcping-real.sh`。预先建立的手工端口规则在 TCPing 改端口及卸载后保留；另一个 owner 共享的新端口规则在 TCPing stop 后保留；全局 `network ufw sync` 没有重新放行已停止的 TCPing。日志：`/var/tmp/vpsctl-tcping-accept-20260929/real-ufw-final/acceptance.log`。 |
| Alpine/OpenRC 真实功能 | **PASS，最终哈希复验见下文**。独立 overlay 源于 `/root/vpsctl-reinstall-real-20260929/alpine-partitioned.raw`；通过 guest SSH 执行 `bin/vpsctl --no-color --non-interactive --yes --install-deps service tcping start --port 35731`，自动安装缺少的 `jq`，启动并加入 OpenRC default runlevel。真实 guest 重启前后 boot ID 确认变化；重启后服务与 IPv4/IPv6 接入恢复。随后从空状态执行同一 real harness 的 stop、改端口、占用保护、重启和卸载，全部通过。日志：`/var/tmp/vpsctl-tcping-accept-20260929/alpine-install.log`、`alpine-after-reboot.log`、`alpine-lifecycle.log`。 |
| Alpine 最终哈希复验 | **PASS**。将最终候选源码复制到同一隔离 overlay，在 guest 中校验模块、监听器和共享 UFW 库的 SHA-256 与上列最终值相同。执行 `bin/vpsctl --no-color --non-interactive --yes service tcping start --port 35731`，检查 OpenRC started/default runlevel、状态 JSON、就绪 JSON 和 IPv4/IPv6 接入。真实重启后 boot ID 变化，OpenRC 自动恢复相同端口与 IPv4/IPv6 监听。随后切换至 35732，确认旧端口关闭、新端口双栈可达；stop 保留禁用状态及脚本/服务定义，uninstall 清除专属文件、就绪文件和自启项。日志：`/var/tmp/vpsctl-tcping-accept-20260929/alpine-final-start.log`、`alpine-final-after-reboot.log`、`alpine-final-change.log`、`alpine-final-stop.log`、`alpine-final-uninstall.log`。guest 已关机，overlay 经 `qemu-img check` 无错，原始 RAW 哈希不变。 |
| 已安装命令与缓存 | **PASS**。最终候选执行 `VPSCTL_TEST_TCPING_UNINSTALL=1 bash tests/integration/test-distribution-real.sh`，真实已安装 CLI 离线卸载仅移除 TCPing 功能缓存，再经帮助命令只重新下载该 bundle；测试恢复原安装。日志：`/var/tmp/vpsctl-tcping-final/distribution-real.log` 以 `PASS: distribution real integration test` 结束。 |
| 应用静态检查与相关回归 | **PASS**。TCPing 入口及修改的共享命令、UFW 库、UFW 业务锁与采集模块通过 `bash -n`、`shellcheck -S warning` 和 `shfmt -d -i 4 -ci`。`test-command.sh`、`test-ufw-library.sh`、`test-network-ufw.sh`、`test-proxy-ufw.sh`、`test-access-ufw.sh`、`test-tls-ufw.sh` 通过，覆盖受影响的既有功能及新增手工规则保留行为；结果记录在本次远端执行的控制台输出中。 |
| 权限与恢复 | **PASS**。宿主 `runuser -u nobody -- ... service tcping start --port 56789` 返回 4，未产生状态。验收结束时 UFW 测试包已停用并清除，原 `/etc/ufw` 和共享 UFW 状态由基线 tar 恢复；共享状态文件哈希与基线相同。UFW 相关 sysctl 与原值相同；经 `iptables-restore`、`ip6tables-restore` 修复兼容表后，去除时间戳和流量计数的 iptables/ip6tables 规则正文与基线完全一致。原始 Alpine RAW 哈希未变化；overlay 经 `qemu-img check` 无错，guest 已关机，无 TCPing/QEMU 测试进程。流量计数和 nft 展示顺序不会在运行中的宿主上保持字节级相同。 |

验收期间先后发现并复测修复了 Alpine 将 PID 1 `init` 误判为不支持 OpenRC、TCPing 清理误删匹配的手工 UFW 规则，以及普通用户因受保护父目录不可读而误报“未安装”三个问题。最终 live UFW 与 Debian netns 验收使用修复后的相同应用文件。未重启 Debian 宿主；开机自启的真实重启证据来自 Alpine guest。云厂商安全组不属于此专用环境，未进行外部公网接入测试。

## 2026-10-28：未安装 systemd 单元的状态查询

本次基线为 `8a258e4`（v0.8.17 发布验收提交），仅修改 TCPing 的自启查询和既有单元回归。候选目录为专用机 `/root/vpsctl-tcping-quiet-20261028/source`；`commands/service/tcping.sh` SHA-256 为 `b2a0af714dca76713095305da597b9a322da92c2183d22f9e8f60a7dd7a7812b`。所有执行仍通过 `ssh host-vps-scripts`。

修复前在 Debian 12 / systemd `252.39-1~deb12u2` 的独立 QEMU guest 中复现：单元不存在时，`systemctl show --property=LoadState --value vpsctl-tcping.service` 返回 `not-found`、退出码 0，而 `is-enabled --quiet` 返回 1 并打印 `Failed to get unit file state ... No such file or directory`；旧版 status 与交互菜单均泄漏此诊断。修复先判断 LoadState，仅跳过确认不存在的单元，其他情况沿用原自启判断。

| 检查 | 结果与证据 |
| --- | --- |
| 定向静态检查 | PASS。`bash -n commands/service/tcping.sh tests/unit/test-service-tcping.sh`；应用执行 `shellcheck -x -P SCRIPTDIR -S warning` 无 warning/error，测试执行 `shellcheck -x -P SCRIPTDIR` 零诊断；两文件 `shfmt -d -i 4 -ci` 零差异。日志位于候选目录同级 `validation/`，`status` 为 `validation_exit=0`。应用使用既有 warning 检查级别，不将其表述为所有级别零诊断。 |
| TCPing 现有单元套件 | PASS。`LC_ALL=C bash tests/unit/test-service-tcping.sh`，日志 `validation/unit.log` 包含三项 PASS。新增回归验证未安装 status/菜单/首次 start 无缺失单元警告、服务管理器查询失败的诊断与退出码保留，以及无本模块路径但已加载且启用的外部同名服务仍被拒绝。既有监听器、回滚、UFW 所有权和 OpenRC 映射覆盖保持通过。 |
| Debian 12 真实流程 | PASS。在 `/root/vpsctl-tcping-quiet-20261028` 执行 `./gssh "bash -s" < acceptance.sh`，流程通过标准输入进入 guest，调用 `/root/tcping-quiet-source/commands/service/tcping.sh`。未安装 helper 返回 1 且无 stderr，status 和 PTY 菜单安静。首次 `start --port 11111` 返回 0，单元 loaded/active/enabled，helper 返回 0，`127.0.0.1:11111` 与 `[::1]:11111` 实际 TCP 连接通过。stop 后 disabled，helper 返回 1；uninstall 后 helper/status/菜单均无缺失单元警告。宿主证据 `/root/vpsctl-tcping-quiet-20261028/fixed-acceptance-host.log` 以 `FIXED_ACCEPTANCE_PASS`、`ACCEPTANCE_EXIT=0` 结束，原问题日志为同目录 `old-reproduction.log`。 |

验收明细和每条命令的 stdout/stderr/退出码位于同目录 `evidence/`，简报为 `acceptance-report.txt`。TCPing 专属文件、自启链接、11111 监听和防火墙需求已清理，guest 正常关机，`vm-cleanup.txt` 为 `VM_POWERED_OFF`；原始基线未修改。guest 为复现安装的 `jq` 保留在此可丢弃副本中。外层 PowerShell 调用曾因退出变量转义错误返回 1，记录为夹具调用问题；guest 脚本的逐项断言和最终退出码均通过，未因此重复验收。

本次仅影响 systemd 单元不存在时的自启查询，未重跑全量套件、UFW 真实规则矩阵、Alpine 真实重启或公网接入。监听逻辑与防火墙逻辑未修改；相应原有验收记录继续保留。
