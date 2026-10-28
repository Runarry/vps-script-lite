# systemd 服务自启查询验收

日期：2026-10-28。基线为 `2d5f2fb`（v0.8.18 发布验收提交）。所有项目执行均通过 `ssh host-vps-scripts`，本机只编辑、审阅、打包和传输文件。

## 统一实现与范围

`lib/command.sh` 提供 `vps_cmd_systemd_unit_enabled UNIT`，先读取 LoadState：精确为 `not-found` 时返回 1，不调用会输出缺失单元诊断的 `is-enabled`；其余状态继续由 `systemctl is-enabled --quiet` 判断。两个查询真正失败时保留原诊断和退出码。

以下四个调用点使用该函数，OpenRC 分支和变更服务的动作保持原有实现：

| 调用点 | 覆盖功能 |
| --- | --- |
| `proxy_service_is_enabled` | sing-box、Xray 安装、状态及服务恢复 |
| `_proxy_relay_forward_runtime_enabled` | 代理中转运行时状态与服务恢复 |
| `tcping_service_enabled` | TCPing 状态、安装前快照与外部服务保护 |
| `iperf3_service_enabled` | iperf3 状态、安装前快照与恢复 |

已检索生产代码中的全部 `is-enabled` 查询。RFW 的未静默查询位于服务已运行的分支；访问、TLS、Fail2ban、时间同步和 UFW 等其余查询已有各自的 stderr 处理，本次不改变其语义。未改动 `is-active` 或全局错误输出。

共享函数 SHA-256 为 `266df5f793ea0e770aff9b251d5cf2edcdf789c1aba3a2833344dbb9d225d37e`；候选及其余修改文件摘要保存在 `/root/vpsctl-systemd-enabled-20261028/validation/final-source.sha256`。

## 定向回归与静态检查

候选目录为 `/root/vpsctl-systemd-enabled-20261028/source`。下列检查通过，未执行全量套件：

| 命令 | 结果与证据 |
| --- | --- |
| `LC_ALL=C bash tests/unit/test-command.sh` | PASS；`validation/unit-command.log`。新增覆盖缺失单元不执行 is-enabled、已加载状态沿用原结果，以及 LoadState 与 is-enabled 两阶段的真实错误和退出码保留。 |
| `LC_ALL=C bash tests/unit/test-service-tcping.sh` | PASS；`validation/unit-tcping.log`。包括首次安装、外部已加载服务保护、查询错误、监听器与回滚的现有覆盖。 |
| `LC_ALL=C bash tests/unit/test-service-iperf3.sh` | PASS；`validation/unit-iperf3.log`。替身区分 LoadState 与 MainPID 查询，未安装读取和首次启动无缺失单元诊断；原有启停、更新状态矩阵、信号回滚和菜单覆盖通过。 |
| `VPSCTL_TEST_ONLY=core-install bash tests/unit/test-service-proxy.sh` | PASS；`/var/tmp/vpsctl-systemd-enabled-proxy-20261028/logs/core-install.log`。sing-box/Xray、systemd/OpenRC、受管下载/外部 binary 及回滚场景，新增首次安装无原诊断断言。 |
| `VPSCTL_TEST_ONLY=relay-service bash tests/unit/test-service-proxy.sh` | PASS；同目录 `relay-service.log`。新增未安装 runtime 为 false 且跳过 is-enabled、已加载启用后仍查询并返回 true。最后仅调整该测试的结果变量为局部变量，已重跑此组，复用未受影响的 core-install 结果。 |

修改的八份 Shell 文件均通过远程 `bash -n`。`lib/command.sh`、TCPing、iperf3 的 ShellCheck warning 级别无诊断，iperf3 测试全级别零诊断；command 测试 warning 级别无诊断，全级别保留原有 info，完整基线比较无差异。四份文件的 shfmt 零差异，command 测试的既有格式差异与基线相同；记录于 `validation/static-baseline-status`，三项比较均为 0。`validation/unit-status` 的三个套件退出码均为 0。最初将静态与功能检查串联时，既有 info 和格式差异中断了后续步骤；最终将有效的基线比较与独立功能检查分别记录。

代理两份应用的 ShellCheck warning 级别保留 `common.sh` 原有 SC2034；代理测试按原解析范围完成全级别检查，剩余诊断相对基线无新增，局部结果变量调整减少既有 SC2031。父代理另查新增断言所在位置没有诊断。三文件的 shfmt 均保留原有差异，排除 hunk 位置后与基线相同。此结果为“既有诊断/格式差异无新增”，不记为零诊断或零格式差异。证据为代理日志目录的 `shellcheck-*.json`、`shellcheck-test-baseline-comparison.diff` 和 `shfmt-*-comparison.diff`。额外导入全部外部来源分析代理测试曾以 137 终止，该扩展分析未完成；没有将其记为通过，也未修复无关静态问题。

## Debian 12 真实验收

专用机上的独立 QEMU guest 使用 Debian 12、systemd `252.39-1~deb12u2`。在 `/root/vpsctl-systemd-enabled-20261028` 分别执行 `./gssh "bash -s" < reproduce-old.sh` 与 `./gssh "bash -s" < acceptance.sh`，脚本经标准输入进入 guest；修正版源码为 `/root/systemd-enabled-source`。旧版 sing-box 首次安装返回 0 且服务真实运行，同时复现精确的缺失单元警告。

修正版验收全部 PASS，guest 与外层调用均退出 0，`fixed-acceptance-host.log` 和 `evidence/fixed-acceptance.log` 以 `FIXED_ACCEPTANCE_PASS`、`ACCEPTANCE_EXIT=0` 结束：

| 场景 | 结果 |
| --- | --- |
| sing-box / Xray | 首次 install 无原警告，真实 active/enabled；stop --disable 后判断正确；uninstall --purge 及卸载后状态正确。复用专用机现有真实 sing-box 1.14.3 / Xray 26.3.27 binary，安装走外部 binary 的 `owned=false` 路径；受管下载路径由 core-install 回归覆盖。 |
| iperf3 | 未安装 status 的 stderr 为空；首次 `--install-deps start --port 15201`、真实 `iperf3 -c 127.0.0.1 -p 15201 -t 1 -P 1 -J` 通过，收发字节均大于 0；stop/uninstall 及卸载后查询无原警告。 |
| TCPing | 未安装 status 的 stderr 为空；首次 start 11111 active/enabled，IPv4/IPv6 实际连接通过；stop/uninstall 及卸载后查询无原警告。 |
| 中转运行时 | 缺失时 installed/active/enabled 均 false 且 stderr 为空；真实 oneshot `/bin/true`、RemainAfterExit fixture 验证 loaded/disabled、enabled+active、停止禁用及再次缺失的判断，无需部署 nft 转发。 |
| systemd 其他状态 | 真实 static 返回 0、masked 返回 1，均与原 is-enabled 结果相同；not-found 返回 1 且静默。未以 mock systemctl 替代这些真实状态。 |

报告与每项 stdout/stderr/退出码位于同目录 `acceptance-report.txt` 和 `evidence/`；guest 中的五份应用摘要与宿主候选一致。五个受管 unit、自启项、监听、需求、fixture 及 guest binary 副本已清理，iperf3 系统包默认服务 inactive/disabled。guest 已正常关机，`vm-cleanup.txt` 记录 PID 退出；原始 `guest2.raw` 基线和宿主引导/防火墙未修改。curl、unzip、iperf3 测试依赖保留在可丢弃 guest 中。

未重跑 OpenRC 真实环境、重启、完整 UFW/nft 转发矩阵、上游 Release 下载或 DBus 故障注入。OpenRC、受管下载与真实查询错误由相关既有及新增定向回归覆盖；本次不修改监听、转发或上游安装逻辑。
