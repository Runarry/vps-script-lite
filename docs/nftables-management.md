# nftables 管理

公开入口为 `vpsctl network nftables`。它使用原生 nftables 管理 IPv4/IPv6 防火墙、来源控制及服务端口联动；旧 `network ufw` 和 `network rfw` 已移除，不提供别名，也不导入旧手工规则。

无参数在交互终端进入菜单，非交互调用显示状态。主菜单只有五项：端口放行 / 禁止、IP 访问控制、服务联动、更多管理、启用 / 停用防火墙。日志、统计、连接防护、恢复快照与卸载位于“更多管理”。

## 命令与权限

| 命令 | 行为 |
| --- | --- |
| `status [--json]` | 查看安装、保存的启用状态、实际运行表、开机加载及规则数量 |
| `install` | 安装独立运行时和开机服务；首次安装停用，重复安装保留已有启用状态 |
| `enable` | 采集现有服务端口、协调既有 PO0、启用原生规则与开机恢复，再退役旧防火墙 |
| `disable` | 停用自有防火墙和开机加载，保留规则及服务声明 |
| `reload` | 根据保存的启用状态重新应用自有规则 |
| `sync` | 从已知服务持久数据刷新端口声明；停用时只记录需求 |
| `rule list/add/edit/delete` | 查看、增加、修改或删除手工规则；修改、删除使用 `--id ID` |
| `limit list/set/delete` | 管理 TCP 新连接、同时连接数及 UDP 包速率防护 |
| `link list/attach/detach` | 查看联动，或按 `OWNER` 恢复、解除某个服务的自动联动 |
| `logging on/off` | 设置受限速保护的拒绝日志 |
| `stats [--json]` | 查看自有表的规则计数器 |
| `restore BACKUP-DIRECTORY` | 恢复一次变更前的状态、运行规则、专用服务及适用的旧防火墙/PO0 快照 |
| `uninstall` | 停用并移除独立运行时与开机服务，保留配置、联动记录和恢复快照 |

`status`、规则/防护/联动列表和统计支持 `--json`，输出带 `schema_version: 1`。列表中的规则 ID、服务 OWNER 是后续精确操作的标识。状态分别报告 `enabled`、`runtime_active` 和 `boot`，保存的启用意图不等同于当前内核规则已经加载。

帮助与可读取的查询可由普通用户执行。变更要求 root、nftables 用户空间工具及内核支持；专用运行时和开机编排支持 systemd/OpenRC。工具按当前动作处理，非交互补齐缺失依赖可用 `--install-deps`；`install` 本身明确安装所需依赖。注册生命周期为 `experimental`，平台声明仍以对应真实验收为准。

全局选项放在领域之前，例如 `vpsctl --dry-run --install-deps network nftables enable`。演练校验输入并显示计划，不写状态、规则或服务。主管理菜单执行真实动作，不提供这些执行参数的开关。

## 规则与来源

规则支持 `--action allow|deny|allow-only`、`--proto tcp|udp|both|any`、`--port`、`--source`、`--family both|ipv4|ipv6`、`--service OWNER`、`--comment` 和 `--ttl`。端口可用单值、逗号列表、连字符范围或 `any`；来源可用 IP、CIDR、逗号列表或 `any`。协议为 `any` 时端口也必须为 `any`。`rule edit` 只更新明确传入的字段。

```sh
vpsctl network nftables rule add --id web --action allow --proto tcp --port 80,443
vpsctl network nftables rule add --id admin --action allow-only --proto tcp --port 8443 --source 192.0.2.10 --family ipv4 --ttl 2h
vpsctl network nftables rule edit --id admin --source 192.0.2.0/24 --ttl 0
vpsctl network nftables rule delete --id web
```

`allow-only` 只允许列出的来源访问匹配端口，其他来源仍被拒绝。TTL 可用秒数、`Nm`、`Nh` 或 `Nd`，`0` 表示永久；保存的是绝对到期时间，reload、sync 与服务变更不会续期。`allow-only` 的最后一个允许来源到期后，拒绝其他来源的边界仍保留，不会退化为开放端口。

`--service OWNER` 将规则或防护绑定到该服务声明的入口，包括 DNAT 前的原始端口；额外指定的端口、协议与地址族会进一步缩小范围。服务端口变化后随声明更新；未知、已删除或解除联动的服务不会被当作全部端口匹配。可先用 `link list` 查询 OWNER。

来源限制与防护位于原生 prerouting 路径，可约束 DNAT 前的原始访问端口；普通 input 链默认拒绝未声明的入站，保留回环、已建立连接及必要 ICMP/IPv6 邻居发现。只操作项目自有 `inet vpsctl_firewall` 表，不执行全局 `flush ruleset`，不覆盖其他工具的表。

## 连接与 UDP 包防护

`limit set` 支持协议、端口、来源、地址族、服务、`--rate N/second|N/minute|N/hour`、`--burst N` 和 `--connections N`。TCP 速率只计算新连接，UDP 计算数据包；同时连接数仅适用于 TCP，`0` 清除该限制。至少保留一项速率或同时连接数限制。

```sh
vpsctl network nftables limit set --id web-guard --proto tcp --port 443 --rate 20/second --burst 40 --connections 100
vpsctl network nftables limit set --id udp-guard --proto udp --port 5201 --rate 1000/second --burst 2000
```

这些限制按来源地址维护 meter，不是 Mbit/s 或字节带宽整形。普通服务同步及无关规则调整保留动态 meter；重启后连接统计从内核重新建立。`stats` 显示计数器，不能据此推断带宽限速。

## 服务联动与 PO0

SSH、Xray/sing-box 节点、中转、TCPing、iperf3 和 TLS HTTP-01 使用同一共享引擎提交需求。TCPing 声明 TCP，iperf3 声明 TCP/UDP，两者在 start 时开放、stop 或 uninstall 时撤销自身需求。代理按保存的节点/转发配置声明端口，停止或普通卸载内核仍保留配置对应的需求，删除节点/转发或清除配置时才撤销。HTTP-01 只在实际申请/续期阶段持有短期 TCP 80 租约，结束后释放。多个服务共用端口时，撤销一个需求不删除其他仍需的放行。

`link detach OWNER` 解除该服务的自动联动，`link attach OWNER` 恢复并重新同步。手工规则与业务声明分开保存。未启用时，服务事务只保存需求；它们不会自行启用防火墙，也不会加载旧 UFW 实现。

独立 PO0 继续拥有其转发、NAT 和持久配置。首次启用时使用固定 helper 识别、协调既有 PO0 与原生 ACL；停用或卸载管理防火墙时不删除代理 NAT。无法确认归属、格式或恢复材料时在切换前拒绝，不以全局清空来处理冲突。

## 安装、迁移与恢复

首次安装不启用；已有启用状态下重复安装保留运行和开机状态。启用会先备份，采集 SSH 与现有业务端口，验证候选规则，再以单批次原子加载自有规则。新规则生效后，旧 UFW 停用并移除软件包及规则/状态，项目管理的 RFW 停止、禁用并清理专属二进制、配置、单元和状态；旧手工规则不转换。其他软件包拥有的 UFW application profiles 保留。已有受管 Fail2ban 的防火墙动作一并迁到 nftables；外部修改或无法确认所有权会在清理前拒绝。

如果已经部署代理中转后台运行时，退役 UFW 前会在代理业务锁内用当前版本的固定脚本和共享库升级 `/usr/local/libexec/vpsctl-proxy-runtime/`，撤下旧 UFW 模块。变更前快照包含整个旧运行时，失败时一并恢复。该步骤不调用代理公开入口，不安装 Xray/sing-box 二进制或代理服务，也不重启代理。

存在未完成 SSH 访问事务时，全局防火墙变更会拒绝，需先在访问管理中 commit 或 abort。规则事务与业务事务使用固定锁顺序。候选规则先执行 `nft -c`；失败尝试恢复变更前快照，恢复未完成返回 `30` 并显示快照路径。

| 路径 | 用途 |
| --- | --- |
| `/var/lib/vpsctl/network/nftables/state.json` | `schema_version: 1` 的规则、来源到期时间、防护、联动与服务需求 |
| `/run/vpsctl/network-nftables.lock` | 原生防火墙事务锁 |
| `/var/lib/vpsctl/backups/network/nftables/change-*` | root 专用的变更前恢复快照 |
| `/usr/local/lib/vpsctl/nftables/` | 独立 runtime 与同版本共享代码、jq 模块及 PO0 helper |
| `/etc/systemd/system/vpsctl-nftables.service` | systemd 开机加载单元 |
| `/etc/init.d/vpsctl-nftables` | OpenRC 开机加载脚本 |

`disable` 和 `uninstall` 保留状态与快照；以后再次 enable 会重新采集当前服务并应用保存规则。普通 core 更新、功能缓存清理或 `self uninstall` 不代替防火墙卸载。恢复只接受现有完整快照目录，不手工编辑状态来猜测旧规则；基础退出码遵循 [网络设置](network-settings.md#6-退出码)。

## 分发与验证边界

`network-nftables` 包含公开入口、固定私有模块和 `scripts/po0-relay.sh`；装载顺序为 `shared-command` → `shared-nftables` → `service-proxy` → `network-nftables`。`service-proxy` 只提供上述旧运行时迁移所需脚本；冷缓存的功能帮助也会下载它，不安装代理服务。共享包固定包含 `lib/nftables.sh` 与 `schema.jq`、`render.jq`、`reconcile.jq`、`transactions.sh`。后台运行时复制这些同版本依赖，脱离按需下载缓存。

离线包保留 nftables 与其他功能仍使用的 iptables 系统依赖，不再包含 UFW 系统包或 RFW 上游资产。旧 UFW/RFW 的历史验收记录不代表当前原生实现通过。所有项目检查均须经 `ssh host-vps-scripts` 执行，真实网络、重启恢复、旧后端清理和 PO0 双向共存须以新源码对应的真实记录为准；已执行范围与未执行项目见 [nftables 验收记录](nftables-validation.md)。
