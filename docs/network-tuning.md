# 网络调优

`vpsctl network tune` 提供 TCP 缓冲区估算与设置、网卡出口队列和按源端口的出口限速。Linux 上运行帮助、状态和估算需要 Python 3.9 或更新版本及对应的查询工具。真实变更要求 root、systemd 和相应内核能力。缓冲区使用 `sysctl`，出口队列使用 `ip` 和 `tc`，端口限速还需要 `nft` 及 IFB 支持。

```bash
vpsctl network tune --help
vpsctl network tune status --json
vpsctl network tune diagnose --interface eth0 --seconds 10
```

无子命令时，TTY 进入编号菜单，其余情况显示状态。直接调用时把 `--dry-run`、`--yes`、`--non-interactive` 和 `--install-deps` 写在 `network tune` 前。真实变更先显示影响并确认一次，自动化用 `--yes` 授权。`--dry-run` 读取当前配置并显示计划，保留系统状态。缺少工具时可在直接变更命令中用 `--install-deps` 授权安装，演练只列出缺失工具的安装计划。

`status --interface IFACE` 可查看指定接口的实际队列。`diagnose` 在 1 至 60 秒的观察窗口内采样 CPU、内存、队列计数和持续存活 TCP 连接的重传增量。诊断使用业务流量和系统计数器，目标速率需通过实际业务路径验证。状态中受权限保护的状态文件和计数器请以 root 查询。

## TCP 缓冲区

```bash
vpsctl network tune buffer estimate --rtt-ms 120 --tx-mbps 200 --rx-mbps 100
sudo vpsctl --dry-run network tune buffer set --recommended --rtt-ms 120 --tx-mbps 200
sudo vpsctl network tune buffer set --tx-max 12MiB --rx-max 8MiB
sudo vpsctl network tune buffer restore
```

按方向计算带宽时延积 `BDP = Mbps × RTT(ms) × 125` 字节。估算目标上限为 `max(4 MiB, 2 × BDP + 2 MiB)` 向上取整到 MiB，建议值受总内存的 `1/16` 预算限制。建议保留当前最小值与默认值，预算无法容纳它们时显示原因。手动设置可以指定 `--tx-max`、`--rx-max` 或完整的 `--tx-triplet MIN,DEFAULT,MAX`、`--rx-triplet MIN,DEFAULT,MAX`。容量用字节或 `KiB`、`MiB`、`GiB` 表示。`--sync-core` 显式同步同方向的 `net.core.wmem_max` 或 `net.core.rmem_max`，适用于推荐值或手动上限。

例如 512 MiB 物理内存、450 Mbps、200 ms RTT，对应 BDP 11,250,000 字节、理论建议 24 MiB、单方向预算 32 MiB，最终建议 24 MiB。这是项目的可解释起点，是否改善吞吐仍需实测；提高缓存不能修复链路丢包或中间设备改写窗口缩放、SACK 的问题。

缓冲区上限用于本机终止的 TCP 连接。纯转发经过本机时，端到端窗口由实际 TCP 对端协商。

高级设置使用可重复的 `--set KEY=VALUE`。可选键为 `net.ipv4.tcp_rmem`、`net.ipv4.tcp_wmem`、`net.core.rmem_max`、`net.core.wmem_max`，以及 `net.ipv4.` 下的 `tcp_sack`、`tcp_timestamps`、`tcp_window_scaling`、`tcp_moderate_rcvbuf`、`tcp_mtu_probing`。

`set` 将所选键写入 `/etc/sysctl.d/99-vpsctl-network-tune.conf` 并逐项应用。它会检查 sysctl 配置优先级，遇到后加载的冲突值时停止。`restore` 移除受管片段，并使用其余配置中生效的值。没有其他配置时使用首次接管该键时保存的运行值。

## 网卡出口队列

以下命令以 `eth0` 为例。参数使用实际出口接口及所需速率。省略 `--interface` 时，只有 IPv4 和 IPv6 默认路由合计指向唯一网卡才会自动选择。端口限速的 `set` 使用同一网卡选择规则。

```bash
sudo vpsctl --dry-run network tune egress set --interface eth0 --mode tbf --rate-mbps 100
sudo vpsctl network tune egress set --interface eth0 --mode tbf-fq --rate-mbps 100 --maxrate-mbps 20
sudo vpsctl network tune egress set --interface eth0 --mode fq --maxrate-mbps none
sudo vpsctl network tune egress clear --interface eth0
sudo vpsctl network tune egress restore --interface eth0
```

| 模式 | 作用 | 参数 |
| --- | --- | --- |
| `tbf` | 整张网卡的出口总速率 | 必填 `--rate-mbps`。`--burst-kib` 默认 64，`--latency-ms` 默认 50 |
| `tbf-fq` | TBF 总速率加 FQ 子队列 | 必填 `--rate-mbps`。可设 `--maxrate-mbps`。`--queue-packets` 默认 1024，`--flow-limit` 默认 100，`--burst-kib` 默认 64，`--latency-ms` 默认 20 |
| `fq` | FQ 排队及可选的每流 pacing 速率 | `--maxrate-mbps none` 或省略时取消每流上限。可设 `--queue-packets` 和 `--flow-limit` |

出口整形覆盖接口上的本机流量和转发流量，替换根队列可能短暂影响发包。应用前保存可识别的整个队列树。遇到未知队列参数、拓扑或外部根分类器会停止。`clear` 取消该接口的受管整形并恢复内核默认队列，同时保留首次快照。`restore` 按快照恢复原始队列树，并在已接管旧服务时恢复原有服务状态。

迁移使用 `egress adopt --interface eth0`，也可加 `--service NAME` 明确指定 `network-tuning-fq`、`network-tuning-po0-shaper` 或 `network-tuning-us-shaper`。它核对旧服务命令和实际队列，通过核对后使用相同参数接管。网卡已经有受管出口队列时，BBR 的 live qdisc 替换受同一把锁和队列所有权保护。

## 源端口出口限速

```bash
sudo vpsctl network tune port set --id web --interface eth0 --port 443 --protocol tcp --family both --total-mbps 80 --flow-mbps 8
sudo vpsctl network tune port set --id udp-test --interface eth0 --port 5201 --protocol udp --total-mbps 40
sudo vpsctl network tune port list --json
sudo vpsctl network tune port delete --id web
```

端口规则按 SNAT 之后的出口网卡、协议、地址族和**源端口**匹配。默认协议为 `tcp`，默认地址族为 `both`。`--total-mbps` 是该规则覆盖的全部流量共享上限，`--flow-mbps` 仅用于 TCP，可单独使用或与总限速组合。`udp` 和 `both` 使用总限速。更新使用原规则 ID，交叉覆盖相同网卡、协议、地址族和端口的不同 ID 会被拒绝。

每条规则使用独立 IFB 队列。TCP 每流速率由 Linux FQ 按流哈希和 pacing 实现，实际吞吐受流分桶、RTT、拥塞控制和整张网卡整形影响。PO0 回程数据若使用转换后的对外入口端口，应以该端口配置限速。规则只作用于所选出口和源端口，端口放行仍由防火墙管理。转发、NAT 和代理配置仍由各自入口管理。

分类器属于 `inet vpsctl_tune_ports`，保留包标记低 16 位并使用高 16 位标记本功能的规则。检测到冲突的现有标记或外部出口分类器时，端口限速事务会停止。只配置端口规则时，物理网卡根队列继续处理 IFB 返回的流量。

## 持久化和恢复

- TCP 缓冲、出口队列和端口限速各自使用 `/var/lib/vpsctl/network/tune/` 下的 `buffers.json`、`egress.json` 和 `ports.json`。
- `vpsctl-network-tune-egress@<网卡实例>.service` 在开机时应用该网卡的队列。`vpsctl-network-tune-ports.service` 独立重建已保存的端口规则。两者调用 `/usr/local/lib/vpsctl/network-tune/runtime.pyz`。功能包清理、自更新和 `self uninstall` 后，该运行时仍供受管服务使用。
- 如果变更失败，先用 `status` 和 `diagnose` 核对当前值。`buffer restore` 恢复缓冲区，`egress restore` 恢复网卡队列，`port delete --id ID` 撤销指定端口规则。退出码 `30` 表示回滚不完整，需要根据诊断核实受影响资源。

## PO0 单文件入口

复制 `scripts/po0-relay.sh` 后，在 PO0 的主菜单选择 `10`，或直接运行 `bash po0-relay.sh tune --help`。`tune` 后的子命令和功能参数与 `vpsctl network tune` 相同，通用选项放在 `tune` 和子命令之间。脚本内置同一套 Python 运行时，调用时解包到专用临时目录并在退出时清理。编辑或删除匹配静态限速的 IPv4 中转线路会显示规则 ID，限速规则可通过 `tune port` 独立调整。

调优源代码改动后，运行 `python3 scripts/embed-network-tune.py` 更新单文件内置运行时，使用 `python3 scripts/embed-network-tune.py --check` 校验。项目验证在专用 `host-vps-scripts` 上执行。

## 本次验收

2026-11-15 在 `host-vps-scripts`（Debian 13、Linux 6.12.116、iproute2 6.15.0）完成以下验证：

- 58 项调优模块定向单元测试、原有 BBR 回归，以及入口、分发、清理、单文件和发布包相关测试通过。
- 原生网络命名空间验证了本机服务、DNAT 回程、多入口共用落地、IPv4/IPv6、TCP/UDP 共享总额和分片。10 Mbps 端口总额下双流合计约 9.70 Mbps；10 Mbps 每流限制下双流合计约 18.87 Mbps；12 Mbps 全出口限制下匹配与未匹配端口合计约 11.80 Mbps。这些是隔离环境的语义验证数据。
- 有 NAT 和无 NAT 两种场景各收到完整的 447 个 IPv4、447 个 IPv6 分片 UDP 数据报，对应恰好 2,682 次 IFB 重定向；低速探测确认每包仅经过一次物理出口。
- 完整队列恢复、失败回滚、标记及队列所有权冲突、旧服务停止钩子保护、BBR 旧快照保护通过。实际处理了 CoDel 时间刻度、TBF 突发量刻度、iproute2 FQ 权重解析及 mq 内建子队列的恢复差异。
- 在两个专用 dummy 接口上安装真实 systemd 服务并重启主机。两个出口服务与端口服务并发启动成功，选定的 TCP 参数生效，独立清除/恢复与两个入口交替管理通过。完成后撤销测试配置并恢复 TCP 原值，SSH 网卡队列及原有防火墙保持原状。

原生隔离网络验收入口为 `tests/integration/test-network-tune-real.sh`，需要显式设置 `VPSCTL_REAL_TUNE_TEST=1`。真实重启验收入口为 `tests/integration/test-network-tune-boot-real.sh`，仅限可重启的专用测试主机，以 `VPSCTL_REAL_TUNE_BOOT_TEST=1` 分别执行 `setup`、外部重启、`verify` 和 `cleanup`。

本次未执行项目全量测试或其他内核的真实验收。前端和新增集成脚本的定向 ShellCheck 通过；原有 BBR 全脚本检查仍有既有告警及来源解析问题，功能回归通过。生产机器未迁移配置。
