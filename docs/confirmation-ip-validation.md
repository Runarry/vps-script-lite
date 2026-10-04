# 确认流程与 URI 地址校验验收（2026-10-04）

本次调整 self 卸载授权、BBR 变更摘要确认和 URI 的纯 IP 校验复用。所有项目执行均通过 `ssh host-vps-scripts` 完成，本机仅编辑、读取仓库和传输源码。

## 验证结果

| 检查 | 结果与范围 |
| --- | --- |
| `bash tests/unit/test-distribution.sh` | PASS；普通卸载和 purge 的单次交互确认、取消、非交互拒绝、三种授权及旧组合、锁清理和删除范围。 |
| `bash tests/unit/test-network-bbr.sh` | PASS；普通/live/覆盖的组合摘要确认、确认前无变更、取消与输入中断、幂等、确认后新增未受管文件拒绝、备份、快照及回滚。 |
| 新增 URI 地址矩阵 | PASS；从现有增强测试提取其独立加载部分，运行原有新增断言，仅重定向测试根目录。覆盖公开 parse/rewrite、前导零 IPv4、压缩及嵌入 IPv4 的 IPv6、畸形地址、URI 主机名规则、括号和端口。 |
| `bash tests/unit/test-service-proxy-protocol-enhancements.sh` | PASS；现有 XHTTP、Hysteria2 与 URI 往返解析回归。 |
| `bash tests/unit/test-service-proxy-relay-enhancements.sh` | FAIL；新增地址矩阵执行完后，既有 Xray BBR 客户端选项断言失败，见下文。 |
| `bash tests/integration/test-distribution-real.sh` | PASS；真实受管安装的 `--yes` purge 和旧双标志组合，保留业务配置、功能状态、外部二进制与备份标记。 |
| BBR 真实环境验收 | PASS；真实 TTY 单次确认、取消、sysctl/tc/持久化应用、备份、恢复、幂等、`--yes` 和实际内核拒绝引发的回滚。 |
| 八个变更 Shell 文件的 `bash -n` | PASS。 |
| ShellCheck 与 shfmt | 相对修改前基线无新增诊断或格式差异；未将全文件检查记为全部通过，也未修改既有提示。使用 `shellcheck -x -P SCRIPTDIR` 和 `shfmt -i 4 -ci`，归档基线的 Shell 行尾先统一为 LF。 |

完整增强测试的失败位于 `tests/unit/test-service-proxy-relay-enhancements.sh` 的 Xray `bbr_profile=standard` 拒绝断言。测试预期状态 `10`，当前源码和修改前 HEAD 基线均返回 `0`，并保留该选项。最小复现使用相同 URI 和 exit 对象；两棵树中的 `relay.sh` 相同。此断言与 IP 校验复用无关，未扩大本次修改范围。该测试后续尚未执行的断言不计为通过。

未运行项目全套测试，未进行重启验收；本次不改变持久化文件格式或开机加载机制。

## 真实环境与恢复

- self 集成测试使用真实安装路径，按现有脚本先备份入口、分发目录和 self 状态，结束时恢复并清理测试标记，最终退出 `0`。
- BBR 使用真实 Bash、sysctl、ip、tc、flock 和 Python PTY，无命令模拟及 `VPSCTL_TESTING` 路径映射。挂载命名空间隔离持久化文件、状态和锁，网络命名空间使用临时网卡 `bbrtest0`，不操作主机 `eth0` 的队列。
- 当前内核的 `net.core.default_qdisc` 为全局值，验收通过绑定真实 proc 目录访问并修改，完成后显式恢复为 `fq`。主机 TCP 算法 `bbr`、默认 qdisc `fq`、`eth0` 的 `mq`/`fq` 队列及既有 BBR 文件、原始记录均与验收前快照一致。
- 在确认等待期间检查实际运行值、文件内容/权限/时间、恢复记录和锁；输入 `n` 后无 BBR 变更。输入一个 `y` 后完成带 live qdisc 和未受管文件备份的整次应用。不存在的 qdisc 导致真实 sysctl 失败时，运行值与文件恢复到该次调用前状态，返回 `20`。
- 命名空间随验收进程退出释放；隔离文件、备份与日志保留为证据。没有安装额外软件包。

## 证据位置

远端工作目录：`/var/tmp/vpsctl-confirm-ip.BlMbnc/`。`source/` 是验收副本，`baseline/` 是修改前归档；八个变更 Shell 文件的本地与受测副本 SHA-256 一致。

`evidence/` 中保留：

- `distribution-unit.log`、`bbr-unit.log`、`uri-protocol-unit.log`、`distribution-real.log`。
- `uri-relay-unit.log`：完整增强测试失败记录。
- `uri-address-matrix.sh/.log`：新增地址矩阵及其成功结果。
- `uri-client-options-repro.sh/.log`：原始版本与当前版本的相同失败行为。
- `static-check.py`、`static-checks.json`：语法结果、源码摘要、ShellCheck 和 shfmt 基线对照。
- `bbr-real-report.txt`、`bbr-real-results.json`、`bbr-real-*.log`：真实验收、错误回滚和主机恢复记录。

相关源码未变更时无需重跑验收；后续如需复验真实 BBR，可执行 `ssh host-vps-scripts 'bash /var/tmp/vpsctl-confirm-ip.BlMbnc/evidence/bbr-real-launch.sh'`。
