# 代理管理

`vpsctl service proxy` 在同一个入口下平级管理 Xray 与 sing-box。两个内核都按需安装，没有默认主次关系；可以只安装其中一个，也可以同时安装。命令支持 systemd 与 OpenRC，要求 Bash 4.4+。帮助、协议矩阵和时间状态可由普通用户查看；内核/节点状态、订阅以及所有安装、写配置、服务和时间同步操作需要 root，因为节点清单包含受限凭据。

本功能仍处于 `experimental` 生命周期。仓库自动化测试和 mock 验证不等同于真实 VPS 或 VM 验证；部署前应先在隔离环境使用 `--dry-run` 检查计划，并为 SSH 连接和现有配置准备恢复手段。

## 1. 快速开始

全局选项必须写在 `service` 之前：

```text
bash bin/vpsctl service proxy status
bash bin/vpsctl service proxy profiles
bash bin/vpsctl --dry-run service proxy install --core sing-box
bash bin/vpsctl service proxy install --core sing-box
bash bin/vpsctl service proxy node add --profile hysteria2 --core sing-box --port 8443 --address 203.0.113.10 --sni example.com
bash bin/vpsctl service proxy start --core sing-box --enable
```

不带动作时，交互终端进入代理菜单；非交互环境显示全部内核状态。存在多个可用内核时，交互模式会询问目标内核，非交互模式必须用 `--core sing-box` 或 `--core xray` 明确选择。

## 2. 状态与路径

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
| 内核元数据与待重启记录 | `/var/lib/vpsctl/service/proxy/cores/`、`/var/lib/vpsctl/service/proxy/pending/` |
| 回退副本 | `/var/lib/vpsctl/backups/service/proxy/` |
| OpenRC 文件日志 | `/var/log/vpsctl/proxy/` |

systemd 服务名为 `vpsctl-proxy-sing-box.service` 和 `vpsctl-proxy-xray.service`；OpenRC 使用不带 `.service` 的同名服务。

## 3. 内核生命周期

Xray 与 sing-box 使用相同的生命周期接口：

| 动作 | 用法与行为 |
| --- | --- |
| `install` | `install --core CORE|all [--version TAG]`；按需安装指定内核，写入最小配置和服务定义，但不自动启动或设为开机启动。 |
| `update` | `update [--core CORE|all] [--version TAG] [--confirm-external-update]`；下载并校验目标版本，原子替换二进制，不自动重启。 |
| `uninstall` | `uninstall [--core CORE] [--purge] [--confirm-purge]`；停止、禁用并移除受管服务，默认保留配置、节点和备份。 |
| `start` | `start [--core CORE] [--enable]`；启动内核，`--enable` 同时加入开机启动。 |
| `stop` | `stop [--core CORE] [--disable]`；停止内核，`--disable` 同时取消开机启动。 |
| `restart` | `restart [--core CORE] [--confirm-disruptive]`；显式确认后重启，并提交或回退待生效事务。 |
| `logs` | `logs [--core CORE] [--lines N] [--follow] [--since VALUE]`；systemd 读取 journal，OpenRC 读取项目日志；OpenRC 不支持 `--since`。 |

`CORE` 为 `sing-box` 或 `xray`。只有 `install` 和 `update` 接受 `all`；`install --core all` 处理两个内核，`update --core all` 只处理当前已经登记的内核。两个项目的 tag 空间不同，因此 `--core all` 不能与单个 `--version` 共用。卸载、服务控制和日志必须解析到单个已经登记的内核。

### 外部二进制所有权

安装时，如果系统中已经存在可安全复用的 Xray 或 sing-box 普通可执行文件，命令会校验版本和生成配置，并将其登记为 `owned=false`，不会再次下载或复制。没有可复用文件时，安装和更新只接受对应官方 GitHub Release 的稳定版本资产，匹配当前架构，验证 SHA-256 摘要并核对解压后二进制版本后才替换。此后：

- 更新外部二进制属于原地替换，交互模式要求输入强确认令牌；非交互模式必须额外传入 `--confirm-external-update`。
- 更新后仍保留“外部所有权”记录，不会把该文件变成 vpsctl 所有。
- 无论普通卸载还是 `--purge`，卸载都不会删除外部二进制；只删除 vpsctl 自己创建的服务和相应受管数据。

### 待重启策略

节点增加、修改、删除和内核更新都会先校验新配置。若内核正在运行，变更只写入磁盘并记录 `pending_restart`，不会静默中断现有连接。必须显式执行：

```text
vpsctl service proxy restart --core sing-box
```

非交互执行还需 `--confirm-disruptive`。`status` 中“待重启”为“是”表示磁盘配置或二进制尚未由当前进程采用；若服务已在运行，此时再次 `start` 会被拒绝并要求显式 `restart`。若服务未运行，`start` 会尝试待生效版本，失败时自动恢复记录的上一版。

### 卸载与彻底清除

普通 `uninstall` 保留该内核的配置、节点、证书和备份，便于重新安装或人工恢复。`--purge` 会删除该内核的节点、配置、状态、备份和日志，是不可逆清除：

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
    [--cert-mode self-signed|imported --cert-file FILE --key-file FILE]
    [--obfs none|salamander] [--up-mbps N] [--down-mbps N]
    [--congestion-control bbr|cubic|new_reno]
vpsctl service proxy node edit --id NODE_ID [可修改上述非凭据字段]
vpsctl service proxy node delete --id NODE_ID [--confirm-delete]
vpsctl service proxy subscription [--core CORE|all]
```

`profiles` 列出 profile ID、名称和支持它的内核。`node list` 可按内核筛选；`node show --uri` 输出单节点分享 URI；`subscription` 将全部或指定内核的分享 URI 按清单顺序拼接并输出单行 Base64 订阅内容。节点 ID、UUID、密码、Reality 密钥和需要的混淆密码由命令安全生成，编辑接口不直接接受替换凭据。

端口在整个代理节点清单中必须唯一，且会检查本机当前监听占用。新增或编辑会先生成候选清单和候选内核配置，再调用对应内核校验；校验失败不会提交候选配置。非交互删除节点必须传入 `--confirm-delete`。

### TLS 证书

需要证书的 profile 支持两种模式：

- `--cert-mode self-signed`：在节点专属目录生成自签名证书。客户端必须显式信任该证书或按输出采用不安全验证选项。
- `--cert-mode imported --cert-file FILE --key-file FILE`：验证证书未过期、未加密私钥与证书匹配，并在 OpenSSL 支持时检查 SNI 覆盖，再复制到项目管理目录；后续运行不依赖原始文件路径。

私钥和证书均以受限权限保存，并按证书指纹使用不可覆盖的版本化文件名。运行中修改证书时，上一版会保留到显式重启完成：成功后清理未引用版本，失败回滚后清理新版本。代理管理不申请、续期或部署 ACME 证书；如需公有 CA 证书，应在外部完成签发，再使用复制导入模式。

## 5. 协议矩阵

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

## 6. 系统时间

TLS、Reality 和基于时间的认证都依赖正确系统时钟：

```text
vpsctl service proxy time status [--json]
vpsctl service proxy time sync
```

`time status` 只读显示当前 UTC 时间、时区、NTP 是否启用、是否已同步以及检测到的后端；JSON 使用 `schema_version: 1`。`time sync` 是 root 变更：systemd 优先使用 `timedatectl` 和已有 timesyncd/chrony，OpenRC 使用 chrony；确实没有可用后端时才按检测到的包管理器安装 chrony，持久启用并启动服务。若 `chronyc` 可用，会执行 `makestep`，随后最多等待 30 秒确认同步。

时间同步不使用 HTTP `Date`、网页时间解析或 `date -s`，也不会修改 DNS。

## 7. 明确不包含的功能

当前代理管理只负责单机内核、节点、订阅、日志和系统时间。以下能力不在范围内：

- Argo 或其他 Cloudflare 隧道、API、DNS 和证书集成。
- 中转机、落地机、多跳链路或跨主机编排。
- DNS 修改、域名解析托管或分流 DNS 配置。
- 节点批量导入、批量编辑、批量删除或批量部署。
- Hysteria2 端口跳跃；`hysteria2` profile 只使用单个监听端口。
- ACME 申请与自动续期。

如需修改本机 DNS，应单独使用 [`vpsctl network dns`](network-settings.md)，不要把 DNS 变更与代理事务混合执行。

## 8. 依赖、演练与退出码

支持的平台范围是 Linux、systemd 或 OpenRC，以及 `x86_64`/`amd64`、`aarch64`/`arm64`、`armv7l`/`armv7` 架构。状态、清单和配置渲染依赖 `jq`；端口检查与订阅输出使用 `ss`、`base64` 和 `tr`；证书操作依赖 `openssl` 与 `sha256sum`；官方 Release 安装还依赖 `curl` 以及 Xray 的 `unzip` 或 sing-box 的 `tar`。systemd 日志使用 `journalctl`，OpenRC 日志使用 `tail`。时间同步支持 `apt-get`、`dnf5`、`dnf`、`yum`、`apk`、`pacman` 和 `zypper`，但只在缺少可用 NTP 后端时安装 chrony。

`--dry-run` 会展示安装、写入、服务控制和时间同步命令，不下载、不写受管配置、不安装包，也不启停服务。常见退出码遵循项目统一约定：`2` 为参数错误，`3` 为前置条件或依赖不满足，`4` 为权限不足，`10` 为配置或证书校验失败，`20` 为外部命令或远端服务失败，`30` 为部分完成、同步确认超时或需要人工恢复，`130` 为用户中断。发生 `30` 时先查看 `status`、待重启记录和服务日志，不要直接删除状态或备份文件。
