# 代理管理

`vpsctl service proxy` 在同一个入口下平级管理 Xray 与 sing-box，并提供出口驱动的节点中转与 nftables 端口转发。两个内核都按需安装，没有默认主次关系；可以只安装其中一个，也可以同时安装。命令支持 systemd 与 OpenRC，要求 Bash 4.4+；Alpine 核心支持范围为 3.20+ 的 `x86_64` 与 `aarch64`。帮助、协议矩阵和时间状态可由普通用户查看；内核、节点、中转状态和订阅需要 root，因为节点与出口清单包含受限凭据。

本功能仍处于 `experimental` 生命周期。仓库自动化测试和 mock 验证不等同于真实 VPS 或 VM 验证；部署前应先在隔离环境使用 `--dry-run` 检查计划，并为 SSH 连接和现有配置准备恢复手段。

## 1. 快速开始

有终端时，直接进入统一多内核界面：

```text
bash bin/vpsctl service proxy
```

用于脚本或自动化时，使用明确的子动作；全局选项必须写在 `service` 之前：

```text
bash bin/vpsctl service proxy status
bash bin/vpsctl service proxy profiles
bash bin/vpsctl --dry-run --install-deps service proxy install --core sing-box
bash bin/vpsctl service proxy install --core sing-box
bash bin/vpsctl service proxy install --core all --release-channel prerelease
bash bin/vpsctl service proxy update --core xray --version vX.Y.Z
bash bin/vpsctl service proxy node add --profile hysteria2 --core sing-box --port 8443 --address 203.0.113.10 --sni example.com
bash bin/vpsctl service proxy relay status
bash bin/vpsctl service proxy start --core sing-box --enable
```

不带动作时，交互终端进入代理菜单；非交互环境显示全部内核状态。交互菜单不要求用户输入 `--core`、节点 ID 或内部枚举，而是根据当前状态列出有效候选并使用编号选择；地址、端口、名称等开放值在输入后校验。命令模式保留 `--core sing-box|xray|all` 作为高级消歧接口：只有一个符合动作要求的候选时可以自动选中，存在多个候选时，非交互调用必须显式指定适用的单个内核或 `all`。

`--dry-run`、`--install-deps`、`--yes`、`--non-interactive`、`--quiet` 和 `--verbose` 等执行型全局参数只用于直接功能 CLI；菜单始终执行真实动作。`--json` 等机器可读格式开关、`--force` 和 `--confirm-*` 确认标志同样只属于 CLI。菜单中的中断性或不可逆动作仍会展示影响并要求相应的交互确认或强确认短语，不通过参数开关绕过。

## 2. 统一交互、状态与路径

每次进入或返回代理菜单时，界面都会先显示 Xray 与 sing-box 两个内核的安装状态、版本、运行状态、开机启动状态、配置文件路径、各自节点数和待重启状态，并在末尾汇总全部内核的节点总数。因此，操作入口不是先固定到某一个内核，而是在完整状态上下文中按能力分组：

- 内核生命周期：安装、更新和卸载。
- 服务控制：启动、停止和重启。
- 节点管理：添加、查看、修改、切换内核、批量设置出站 IP 策略和删除。
- 中转管理：出口管理、节点中转、纯端口转发、状态与刷新。
- 查看与输出：订阅、日志和支持的协议。
- 系统工具：系统时间状态与同步。

生命周期和服务动作会按实时状态筛选候选，例如安装只列出未安装内核，更新、卸载和日志只列出已经登记的内核，启动不会列出已经运行的内核，停止和重启只面向当前运行的内核。多个候选可供安装或更新时，交互界面还提供“全部”选择；随后用编号选择“使用最新稳定版（推荐）”“使用最新预发布版”或“输入精确 Release tag”。为“全部”输入精确 tag 时会分别询问两个项目的 tag。卸载和可能中断连接的服务动作仍逐个选择内核并执行相应确认。筛选只减少无效选项，不改变强确认、权限或待重启策略。

命令模式可单独查询相同状态：

```text
vpsctl service proxy status [--core sing-box|xray|all] [--json]
```

人类可读状态分别显示两个内核的安装来源、版本、运行状态、开机启动状态、配置文件位置、节点数和待重启状态，最后显示总节点数。`--json` 输出带 `schema_version` 的机器可读对象、各内核记录和 `total_nodes`。

主要持久路径如下：

| 内容 | 路径 |
| --- | --- |
| sing-box 配置 | `/etc/vpsctl/proxy/sing-box/config.json` |
| Xray 配置 | `/etc/vpsctl/proxy/xray/config.json` |
| 节点清单 | `/var/lib/vpsctl/service/proxy/nodes.json` |
| 中转定义与 DNS 运行缓存 | `/var/lib/vpsctl/service/proxy/relay.json`、`/var/lib/vpsctl/service/proxy/relay-resolved.json` |
| 内核元数据与待重启记录 | `/var/lib/vpsctl/service/proxy/cores/`、`/var/lib/vpsctl/service/proxy/pending/` |
| 回退副本 | `/var/lib/vpsctl/backups/service/proxy/` |
| OpenRC 文件日志 | `/var/log/vpsctl/proxy/` |

systemd 服务名为 `vpsctl-proxy-sing-box.service` 和 `vpsctl-proxy-xray.service`；OpenRC 使用不带 `.service` 的同名服务。

## 3. 内核生命周期

Xray 与 sing-box 使用相同的命令模式生命周期接口：

| 动作 | 用法与行为 |
| --- | --- |
| `install` | `install --core CORE|all [--release-channel stable\|prerelease] [--version TAG]`；按需安装指定内核，写入最小配置和服务定义，但不自动启动或设为开机启动。 |
| `update` | `update [--core CORE\|all] [--release-channel stable\|prerelease] [--version TAG] [--confirm-external-update]`；下载并校验目标版本，原子替换二进制，不自动重启。 |
| `uninstall` | `uninstall [--core CORE] [--purge] [--confirm-purge]`；停止、禁用并移除受管服务，默认保留配置、节点和备份。 |
| `start` | `start [--core CORE] [--enable]`；启动内核，`--enable` 同时加入开机启动。 |
| `stop` | `stop [--core CORE] [--disable]`；停止内核，`--disable` 同时取消开机启动。 |
| `restart` | `restart [--core CORE] [--confirm-disruptive]`；显式确认后重启，并提交或回退待生效事务。 |
| `logs` | `logs [--core CORE] [--lines N] [--follow] [--since VALUE]`；systemd 读取 journal，OpenRC 读取项目日志；OpenRC 不支持 `--since`。 |

`CORE` 为 `sing-box` 或 `xray`。只有 `install` 和 `update` 接受 `all`；`install --core all` 处理两个内核，`update --core all` 只处理当前已经登记的内核。这与交互界面中安装/更新动作的“全部”选项对应。`--core all` 可以把同一个 `--release-channel` 转发给两个内核。两个项目的 tag 空间不同，因此它不能与单个 `--version` 共用。卸载、服务控制和日志必须解析到单个已经登记的内核。

`--release-channel` 与 `--version` 互斥。默认或显式选择 `stable` 时，安装和更新从对应项目的 GitHub `latest` Release 选择当前稳定版本，并拒绝 draft 或被标记为 prerelease 的响应。选择 `prerelease` 时，命令分页读取 Releases 列表并选择返回顺序中首个非 draft 的预发布版本；如果没有可用预发布版本会明确失败，不回退稳定版。指定 `TAG` 时则精确请求该 tag，可接受稳定版或预发布版，但仍拒绝 draft、tag 回显不一致或无效格式，不会自动改选其他版本。安装通道不写入元数据，也不会由后续更新自动跟随；以后不带 `--release-channel` 或 `--version` 执行 `update` 仍选择最新稳定版。

无论选择哪个通道或精确 tag，下载与替换仍执行相同的安全检查：只接受对应官方 GitHub HTTPS Release 的唯一匹配资产，动态取得并验证 digest 或 `.dgst` 中的 SHA-256，检查解压目标和二进制版本，验证现有配置兼容性，再原子替换。摘要不是仓库内的固定版本或固定值。

### 外部二进制所有权

安装时，如果系统中已经存在可安全复用的 Xray 或 sing-box 普通可执行文件，命令会校验版本和生成配置，并将其登记为 `owned=false`，不会再次下载或复制。指定精确 tag 时，现有二进制版本必须与 tag 一致。选择最新预发布版时会先解析目标 tag，也只有外部二进制版本与该 tag 一致才会登记；不一致时应先按现有版本登记，再使用带强确认的 `update --release-channel prerelease` 替换，避免把稳定版误登记成预发布版。没有可复用文件时按所选 Release 下载并执行上述完整校验。此后：

- 更新外部二进制属于原地替换，交互模式要求输入强确认令牌；非交互模式必须额外传入 `--confirm-external-update`。
- 更新后仍保留“外部所有权”记录，不会把该文件变成 vpsctl 所有。
- 无论普通卸载还是 `--purge`，卸载都不会删除外部二进制；只删除 vpsctl 自己创建的服务和相应受管数据。

### 待重启策略

节点增加、修改、删除、节点中转关联和内核更新都会先校验新配置。nftables 端口转发在增删改后立即以单批事务生效。

若内核正在运行，且本次待生效原因全部是配置面变更（节点增删改、IP 策略、节点中转绑定或会重渲染该内核配置的出口变更），写入成功后会自动重启该内核并提交 LKG。重启失败则回滚到上一版并恢复服务。自动重启会短暂中断该内核上的代理连接，但不会中断 SSH。

以下情况仍只写入磁盘并记录 `pending_restart`，必须显式重启：

- 内核二进制 `update`（`core-update`）
- 已有 `core-update` 等不可自动应用的 pending 时，后续再做节点或中转修改
- 服务当前未运行（不自动 start；下次 `start` 时应用）

```text
vpsctl service proxy restart --core sing-box
```

非交互执行显式 `restart` 还需 `--confirm-disruptive`。`status` 中“待重启”为“是”表示磁盘配置或二进制尚未由当前进程采用；若服务已在运行，此时再次 `start` 会被拒绝并要求显式 `restart`。若服务未运行，`start` 会尝试待生效版本，失败时自动恢复记录的上一版。`relay status` 会分别显示核心配置待重启状态和转发运行状态。

### 卸载与彻底清除

普通 `uninstall` 保留该内核的配置、节点、证书、中转状态和备份，便于重新安装或人工恢复。只要该内核仍有协议出口，`--purge` 就会拒绝，并列出出口及其节点和端口转发引用。没有中转引用时，`--purge` 会删除该内核的节点、配置、状态、备份和日志，是不可逆清除：

- 交互模式要求输入 `PURGE-SING-BOX` 或 `PURGE-XRAY` 强确认令牌。
- 非交互模式必须同时提供 `--purge --confirm-purge`；全局 `--yes` 不能替代强确认。
- 清除范围受项目路径和所有权校验约束，外部二进制始终保留。

## 4. 节点与订阅

支持的节点动作如下：

```text
vpsctl service proxy profiles
vpsctl service proxy node list [--core CORE|all] [--json]
vpsctl service proxy node show --id NODE_ID [--uri]
vpsctl service proxy node add --profile PROFILE [--core CORE] [--name NAME] [--port PORT]
    [--listen ADDRESS] [--address CLIENT_ADDRESS] [--sni HOST]
    [--path PATH] [--service-name NAME]
    [--cert-mode self-signed|imported|managed --cert-file FILE --key-file FILE --cert-id ID]
    [--obfs none|salamander] [--up-mbps N] [--down-mbps N]
    [--congestion-control bbr|cubic|new_reno]
    [--ip-strategy auto|prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only]
vpsctl service proxy node edit --id NODE_ID [可修改上述非凭据字段]
vpsctl service proxy node core set --id NODE_ID --core sing-box|xray [--confirm-disruptive]
vpsctl service proxy node ip-policy set --core sing-box|xray --ip-strategy STRATEGY
    (--id NODE_ID [--id NODE_ID ...] | --profile PROFILE | --all)
vpsctl service proxy node delete --id NODE_ID [--cascade-relay] [--confirm-delete]
vpsctl service proxy subscription [--core CORE|all]
```

`profiles` 列出 profile ID、名称和支持它的内核。`node list` 可按内核筛选；`node show --uri` 输出单节点分享 URI；`subscription` 先按原顺序输出普通节点，再按转发记录和端口升序追加协议出口的端口转发 URI，稳定去重后输出单行 Base64。`--core all` 包含所有协议出口转发，指定内核时按出口选择的内核筛选；直连出口不生成 URI。交互菜单生成订阅前先用编号选择“全部”，或选择当前确有普通节点或转发 URI 的 sing-box/Xray 范围。节点 ID、UUID、密码、REALITY 密钥和需要的混淆密码由命令安全生成，编辑接口不直接接受替换凭据。

交互式添加节点时，先用编号选择 profile 和适用内核，并填写监听端口与客户端连接地址，再选择“快速向导”或“自定义向导”。快速向导就此采用界面显示的推荐设置；自定义向导继续询问该 profile 支持的可调字段。profile、目标内核以及证书模式、混淆方式、拥塞控制等枚举值都通过编号选择，不要求记忆或手工输入内部枚举字符串；凭据在两种向导中都由命令安全生成。

如果当前没有已安装且兼容所选 profile 的内核，界面会列出兼容内核并询问是否先安装；用户确认并完成安装后继续原节点向导，拒绝或取消则不创建节点。一个内核兼容时自动使用，多个已安装内核兼容时按编号选择。这个引导不改变非交互接口：自动化调用在没有兼容内核时仍会失败并要求先安装，在多个候选可用时使用 `--core` 消歧。

交互式节点列表默认展示全部内核的节点，每一项都明确标注所属 Xray 或 sing-box。查看、编辑、切换内核和删除从这份完整列表按编号选取节点；切换内核时，菜单只列出已经安装且支持该节点 profile 的另一内核，并在执行立即接管前要求交互确认。命令模式仍使用稳定的 `--id NODE_ID`，便于脚本精确引用。命令模式的 `node list` 默认同样返回全部节点并标注 `core`，只有显式传入 `--core` 时才筛选。

### 切换节点内核

`node core set` 将一个节点从当前内核切换到 `--core` 指定的另一内核。目标内核必须已经安装，命令不会自动安装；目标还必须支持节点当前 profile，不能借此改变 profile 或绕过协议矩阵。切换保留客户端连接端点、节点 ID、凭据、TLS、传输参数和 `ip_strategy` 的语义；目标内核重新生成分享 URI 后，URI 的字符串编码或参数顺序可能不同，不应据此判断客户端参数发生变化。`self-signed` 和 `imported` 模式的受管证书及私钥会在事务中迁移到目标内核对应的内部路径，外部原始导入路径仍不会成为运行依赖。

没有中转绑定的节点可以直接切换。若节点绑定协议出口，只有该出口仅由这个节点独占、没有任何端口转发引用，并且出口 profile 也兼容目标内核时，命令才会把出口及绑定一并迁移。出口被其他节点共享、存在任意 forward 引用，或出口与目标内核不兼容时，切换会在写入前拒绝，不会只迁移节点而留下不一致的中转关系。

切换属于立即接管的中断性事务，不采用普通配置变更的待重启流程；非交互调用必须显式传入 `--confirm-disruptive`，全局 `--yes` 不能替代该确认。目标服务的 active/enabled 状态按源服务可用性继承。命令会先验证目标清单、目标内核配置、中转和证书迁移计划，再一次提交并完成服务接管；任何阶段失败都会回滚节点清单、两侧内核配置、中转状态、证书内部路径以及服务 active/enabled 状态。

每个节点独立保存 `ip_strategy`；旧清单缺失该字段时按 `auto` 处理，列表和详情 JSON 始终补出有效默认值。`auto` 使用代理内核自身默认行为，且不会继承 [`network ip-policy`](network-settings.md#4-ip-地址族偏好) 的系统策略。其他策略通过节点专属直连出站和入站标签路由实现：

| 节点策略 | sing-box `domain_resolver.strategy` | Xray Freedom `domainStrategy` |
| --- | --- | --- |
| `auto` | 默认 `direct` | 默认 `AsIs` |
| `prefer_ipv4` | `prefer_ipv4` | `UseIPv4v6` |
| `prefer_ipv6` | `prefer_ipv6` | `UseIPv6v4` |
| `ipv4_only` | `ipv4_only` | `ForceIPv4` |
| `ipv6_only` | `ipv6_only` | `ForceIPv6` |

这些策略只约束内核对目标域名的解析和选址，不阻断写死的异族字面量 IP。节点绑定中转后，流量优先使用 relay 规则；策略仍保存在节点中，但列表和详情会显示“已绑定中转，暂不生效”。解除绑定后的同一重渲染流程会自动恢复节点策略。

`node ip-policy set` 只接受单一内核，可重复 `--id` 去重选择节点，也可按一个 profile 或该内核全部节点设置。命令先构造统一候选 manifest、渲染配置并调用真实内核校验，再通过现有事务一次提交；任一节点或配置校验失败时整批不写入。运行中的内核在提交成功后自动重启应用；若存在待应用的二进制更新则仍只记录待重启。交互界面提供多选节点、按 profile 和当前内核全部节点三种范围。

端口在整个代理节点清单中必须唯一，且会检查本机当前监听占用以及同网络端口转发冲突。新增或编辑会先生成候选清单并与当前中转状态共同渲染候选内核配置，再调用对应内核校验；校验失败不会提交候选配置。已经作为中转入口的节点默认拒绝删除；`--cascade-relay --confirm-delete` 可在同一事务中删除节点关联。非交互删除节点必须传入 `--confirm-delete`。

### TLS 证书

需要证书的 profile 支持两种模式：

- `--cert-mode self-signed`：在节点专属目录生成自签名证书。客户端必须显式信任该证书或按输出采用不安全验证选项。
- `--cert-mode imported --cert-file FILE --key-file FILE`：验证证书未过期、未加密私钥与证书匹配，并在 OpenSSL 支持时检查 SNI 覆盖，再复制到项目管理目录；后续运行不依赖原始文件路径。
- `--cert-mode managed --cert-id crt-...`：引用 [`security tls`](tls-management.md) 的 live 路径，不复制证书。SNI 必须被该证书覆盖。续期后路径不变；指纹变化会使分享 URI 中的证书固定值变化。

私钥和证书均以受限权限保存，并按证书指纹使用不可覆盖的版本化文件名。运行中修改证书时，上一版会保留到本次自动重启（或显式重启）完成：成功后清理未引用版本，失败回滚后清理新版本。代理管理不申请、续期或部署 ACME 证书。公有 CA 证书由 [`security tls`](tls-management.md) 维护；节点可继续使用 `self-signed`/`imported`，或在后续版本通过 `managed` 模式引用其 live 路径。当前导入模式仍复制到节点专属目录，后续运行不依赖原始文件路径。

## 5. 中转管理

中转以“先定义出口，再关联入口”为核心模型。出口与入口相对解耦：一个本机节点最多关联一个同内核协议出口，一个出口可以被多个入口节点和多条端口转发复用。节点中转不会创建新入口、修改入口凭据或改变原节点 URI；未关联节点继续走 `direct`。本功能不把本机部署成落地机，也不进行跨主机编排、负载均衡或一个入口多出口分流。

### 出口与节点中转

```text
vpsctl service proxy relay status [--json]

vpsctl service proxy relay exit list [--json]
vpsctl service proxy relay exit show --id EXIT_ID [--uri]
vpsctl service proxy relay exit add --name NAME --uri URI [--profile PROFILE] [--core CORE]
vpsctl service proxy relay exit add --name NAME --target HOST --target-port PORT
vpsctl service proxy relay exit edit --id EXIT_ID [...]
vpsctl service proxy relay exit delete --id EXIT_ID [--cascade --confirm-cascade]

vpsctl service proxy relay bind list [--core CORE|all] [--json]
vpsctl service proxy relay bind show --id BIND_ID
vpsctl service proxy relay bind add --node-id NODE_ID --exit-id EXIT_ID
vpsctl service proxy relay bind delete --id BIND_ID [--confirm-delete]
```

协议出口保存原始 URI、内核无关的规范化描述、profile、所选内核、目标地址端口和网络建议。一个 URI 有多个可用内核时必须明确选择；Shadowsocks 2022 普通与 Padding 无法仅从链接区分，必须使用 `--profile` 或在交互菜单中编号选择。内核尚未安装时可以保存协议出口，列表和状态会标记“尚未二进制验证”；实际建立节点关联时才要求同内核已登记，并用真实二进制校验完整配置。

URI 层接受协议矩阵对应的标准 VLESS、Trojan、AnyTLS、Hysteria2/Hy2、TUIC、Shadowsocks/SIP002（含旧式整段 Base64）、ShadowTLS 插件和 SOCKS5 链接。VLESS TCP/REALITY 分享链接中常见的无操作参数 `headerType=none` 会被兼容接受，其他 header 类型仍会拒绝。未知或重复参数、矩阵外组合和无法渲染的变体会被拒绝；新版 Xray 已移除 `allowInsecure`，因此选择 Xray 的不安全 TLS URI 必须同时带有本项目的 `pcs` 证书指纹，渲染时使用证书固定。sing-box 按 inbound tag 生成 `route` 动作，Xray 使用 `inboundTag`/`outboundTag`；每个被使用的出口只生成一份稳定 tag 的 outbound。

删除仍被引用的出口默认拒绝。`--cascade --confirm-cascade` 会同时删除该出口、全部节点关联和端口转发，并将核心配置、relay 状态和运行规则作为一个可回滚变更处理。关联修改沿用待重启策略：运行中的内核在仅配置变更时自动重启应用；pending 与 LKG 快照同时记录 relay 定义、DNS 运行缓存和受管 nftables 规则，核心应用失败时恢复同一代数据面。

### 纯端口转发

```text
vpsctl service proxy relay forward list [--json]
vpsctl service proxy relay forward show --id FORWARD_ID [--uris|--json]
vpsctl service proxy relay forward add --name NAME --exit-id EXIT_ID --listen-ports START[-END]
    [--network auto|tcp|udp|both] [--family dual|ipv4|ipv6] [--address HOST]
vpsctl service proxy relay forward edit --id FORWARD_ID [--family dual|ipv4|ipv6] [...]
vpsctl service proxy relay forward delete --id FORWARD_ID [--confirm-delete]
vpsctl service proxy relay forward refresh [--id FORWARD_ID]
```

纯端口转发只使用 nftables，不启动用户态转发进程。协议出口和直连 `HOST:PORT` 出口都可用于转发；直连出口必须明确选择 TCP、UDP 或 both。`auto` 对 Hysteria2/TUIC 采用 UDP，对普通 Shadowsocks 采用 both，对 ShadowTLS 和其他当前协议采用 TCP。端口区间内的每个入口端口都映射到出口的同一个目标端口。

每条转发独立保存 `family`；旧记录缺失时以及新增时默认 `dual`，列表 JSON 始终补出该默认值。`ipv4` 或 `ipv6` 只解析、缓存并渲染指定地址族，若出口是相反族字面量或域名没有所需记录，新增和编辑在提交前失败。`dual` 部署出口所有可用地址族，至少一个族可用即可提交；缺少另一族时在 `relay status` 中标记部分双栈 degraded。它不提供跨地址族优先、失败回退、NAT64 或用户态转发。

nftables 规则只写入独立的 `ip vpsctl_proxy_forward4` 和 `ip6 vpsctl_proxy_forward6` 表，使用 `fib daddr type local` 限定本机 PREROUTING 流量，不创建 OUTPUT 规则，也不刷新全局 ruleset。规则包括受管 DNAT 连接的 FORWARD 放行和 masquerade；IPv4、IPv6 分别渲染，不做 NAT64。候选批次先通过 `nft -c`，再一次提交；状态、DNS 缓存、核心配置或运行规则任一提交失败都会尝试恢复旧版本。检测到其他 FORWARD 链拒绝策略时只告警，不修改 UFW、firewalld、云安全组或第三方表。

首条转发会按需安装 nftables，启用 IP forwarding，并安装、启用 `vpsctl-proxy-forward` 服务。该服务每 5 分钟重新解析正在使用的域名出口并恢复受管规则，本身不承载流量。多条转发共享出口时，缓存按所有引用记录计算所需地址族并集，成功提交后不再保留无人引用的旧族。每个地址族确定性选取排序后的首个有效地址；解析失败时保留最后可用地址并在 `relay status` 中标记 degraded，没有可用旧地址时拒绝替换规则并保留现有数据面。目标解析到本机时拒绝应用，以避免转发循环。最后一条转发删除后会停止并禁用服务、清除两个受管表和 DNS 运行缓存。

`--address` 只定义生成 URI 使用的本机发布地址；省略时使用本机探测地址。单栈模式采用字面量发布地址时必须与所选地址族一致；域名发布地址允许保留，列表 JSON 和详情会提示其 DNS 记录由用户负责。协议出口可用 `forward show --uris` 按端口升序展开新 URI：除 authority 的主机和端口外，原凭据、参数顺序和名称保持不变；旧式整段 Base64 Shadowsocks 链接只重新编码包含端点的载荷。普通列表只显示模板能力，不展开大范围内容。

## 6. 协议矩阵

下表以本项目采用的参考项目能力集合为基线，列出当前公开 profile ID 与内核支持矩阵。`是` 表示可以用该内核创建和渲染节点；空白表示不支持，不能通过 `--core` 强制绕过。

| Profile ID | sing-box | Xray |
| --- | :---: | :---: |
| `vless-reality-vision` | 是 | 是 |
| `vless-ws-tls` | 是 |  |
| `trojan-ws-tls` | 是 |  |
| `vless-grpc-tls` | 是 | 是 |
| `anytls-tls` | 是 |  |
| `anytls-reality` | 是 |  |
| `hysteria2` | 是 |  |
| `tuic-v5` | 是 |  |
| `shadowsocks-aes-256-gcm` | 是 | 是 |
| `shadowsocks-chacha20-poly1305` | 是 | 是 |
| `shadowsocks-2022` | 是 | 是 |
| `shadowsocks-2022-padding` | 是 | 是 |
| `shadowsocks-2022-shadowtls` | 是 |  |
| `vless-tcp` | 是 |  |
| `socks5` | 是 |  |
| `vless-grpc-reality` |  | 是 |
| `trojan-xhttp-reality` |  | 是 |
| `trojan-grpc-reality` |  | 是 |
| `vless-xhttp-tls` |  | 是 |
| `trojan-grpc-tls` |  | 是 |

其中 `vless-reality-vision`、`vless-grpc-tls`、`shadowsocks-aes-256-gcm`、`shadowsocks-chacha20-poly1305`、`shadowsocks-2022` 和 `shadowsocks-2022-padding` 由两个内核共同支持。

## 7. 系统时间

TLS、REALITY 和基于时间的认证都依赖正确系统时钟：

```text
vpsctl service proxy time status [--json]
vpsctl service proxy time sync
```

`time status` 只读显示当前 UTC 时间、时区、NTP 是否启用、是否已同步以及检测到的后端；JSON 使用 `schema_version: 1`。`time sync` 是 root 变更：systemd 优先使用 `timedatectl` 和已有 timesyncd/chrony，OpenRC 使用 chrony；确实没有可用后端时，真实执行的交互流程询问是否安装 chrony，非交互调用则必须提供 `--install-deps`，随后才会持久启用并启动服务。若 `chronyc` 可用，会执行 `makestep`，随后最多等待 30 秒确认同步。

时间同步不使用 HTTP `Date`、网页时间解析或 `date -s`，也不会修改 DNS。

## 8. 明确不包含的功能

当前代理管理只负责单机内核、节点、出口关联、nftables 端口转发、订阅、日志和系统时间。以下能力不在范围内：

- Argo 或其他 Cloudflare 隧道、API、DNS 和证书集成。
- 落地机部署、多跳链路、跨主机编排、负载均衡或一个入口多出口。
- DNS 修改、域名解析托管或分流 DNS 配置。
- 节点批量导入、除 IP 地址族策略外的批量编辑、批量删除或批量部署。
- Hysteria2 端口跳跃；`hysteria2` profile 只使用单个监听端口。
- ACME 申请与自动续期。

如需修改本机 DNS，应单独使用 [`vpsctl network dns`](network-settings.md)，不要把 DNS 变更与代理事务混合执行。

## 9. 依赖、演练与退出码

支持的平台范围是 Linux、systemd 或 OpenRC，以及 `x86_64`/`amd64`、`aarch64`/`arm64`、`armv7l`/`armv7` 架构。状态、清单和配置渲染依赖 `jq`；端口检查与订阅输出使用 `ss`、`base64`、`tr`、`awk` 和 `mktemp`；证书与稳定 ID 操作依赖 `openssl` 与 `sha256sum`；端口转发依赖 `nft`、`ip`、`getent` 和 `sysctl`；受管变更使用 `flock` 加锁；官方 Release 安装还依赖 `curl` 以及 Xray 的 `unzip` 或 sing-box 的 `tar`。功能只在当前动作实际需要时检查对应工具：真实执行的交互环境发现缺失后才列出缺失项并询问是否安装，不会在进入代理菜单时预装所有工具；非交互调用和 `--dry-run` 依赖计划仍必须提供 `--install-deps`。获得授权后，当前动作可通过 `apt-get`、`dnf5`、`dnf`、`yum`、`apk`、`pacman` 或 `zypper` 补齐缺失工具；时间同步只在缺少可用 NTP 后端时补齐 chrony。systemd 的 `journalctl`、OpenRC 的 `tail`、服务管理器和 CPU 架构属于平台前置条件，不由该选项安装或绕过。

真实协议链路验收脚本为 `tests/integration/test-service-proxy-relay-connectivity-real.sh`，默认对任何失败都严格退出。Xray 26.3.27 与 26.6.27 的 `trojan-grpc-reality` 已确认在 REALITY 认证完成后由 gRPC 传输层关闭连接；需要执行其余完整矩阵时可显式设置 `ALLOW_XRAY_TROJAN_GRPC_REALITY_XFAIL=1`。该豁免只接受日志中的 server-preface 关闭特征；若未来版本修复并实际连通，脚本以 XPASS 失败，要求移除豁免，避免永久静默跳过。

`--dry-run` 会展示安装、写入、服务控制和时间同步命令，不下载、不写受管配置、不安装包，也不启停服务。与 `--install-deps` 组合且发现工具缺失时，会先展示固定的软件包安装计划，再安全停止并提示安装后重跑完整计划。常见退出码遵循项目统一约定：`2` 为参数错误，`3` 为前置条件或依赖不满足，`4` 为权限不足，`10` 为配置或证书校验失败，`20` 为外部命令或远端服务失败，`30` 为部分完成、同步确认超时或需要人工恢复，`130` 为用户中断。发生 `30` 时先查看 `status`、待重启记录和服务日志，不要直接删除状态或备份文件。
