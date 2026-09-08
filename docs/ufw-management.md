# UFW 防火墙管理

`vpsctl network ufw` 提供 UFW 安装、卸载、规则管理及 SSH、代理节点、中转、HTTP-01 证书挑战的端口联动。功能处于 `experimental`，实际平台及连通性验证以 [UFW 验收记录](ufw-validation.md) 为准。

## 入口与菜单

终端中无参数进入菜单，非交互调用默认显示状态。主菜单提供安装、启停、规则列表、端口增删改、联动管理、同步和卸载；方向、地址、网卡、规则顺序、默认策略、IPv6、日志、应用配置及重置位于“高级规则管理”。

```text
vpsctl network ufw status [--json]
vpsctl network ufw install
vpsctl network ufw enable|disable|reload
vpsctl network ufw uninstall [--purge] [--confirm-purge]
vpsctl network ufw reset [--confirm-reset]
vpsctl network ufw rule list [--json]
vpsctl network ufw rule add [RULE-OPTIONS]
vpsctl network ufw rule edit (--id ID|--number N) [RULE-OPTIONS]
vpsctl network ufw rule delete (--id ID|--number N)
vpsctl network ufw link list [--json]
vpsctl network ufw link detach|attach OWNER
vpsctl network ufw sync
vpsctl network ufw default incoming|outgoing|routed allow|deny|reject
vpsctl network ufw ipv6 on|off
vpsctl network ufw logging on|off|low|medium|high|full
vpsctl network ufw app list|info NAME|default POLICY|update NAME|all [--add-new]
```

应用默认策略支持 `allow`、`deny`、`reject`、`skip`；`app update --add-new` 仅适用于单个应用，不能与 `all` 组合。

全局选项位于领域前，例如 `vpsctl --dry-run network ufw enable`。沿用 `--install-deps`、`--yes`、`--non-interactive`、`--quiet`、`--verbose` 和显示选项。演练不安装依赖、不获取写锁、不创建状态或临时规则；必要工具缺失时只展示安装计划或明确说明前置条件。`--yes` 不替代清除配置和重置的强确认。

安装默认不启用。新配置采用拒绝入站、允许出站、拒绝转发，已有配置保留其策略。软件只从系统已经配置的源安装，支持项目现有包管理器；源中没有 UFW 时失败，不添加第三方源。systemd/OpenRC 的持久化按实际服务能力检查，帮助和可读取的状态不要求服务管理器。

## 手动规则

规则选项如下，编辑时未提供的字段保持原值：

| 选项 | 值 |
| --- | --- |
| `--action` | `allow`、`deny`、`reject`、`limit` |
| `--direction` | `in`、`out`、`route` |
| `--proto` | 协议名；端口管理通常使用 `tcp`、`udp` |
| `--port`、`--source-port` | 单端口、逗号分隔列表或冒号范围 |
| `--source`、`--destination` | IP、CIDR 或 `any` |
| `--family` | `ipv4`、`ipv6`、`both` |
| `--in-interface`、`--out-interface` | 网卡名称 |
| `--position` | 新增规则的插入位置 |
| `--comment` | 备注 |
| `--app` | UFW 应用配置名称，与显式端口选项互斥 |
| `--log` | `log` 或 `log-all` |

```text
vpsctl network ufw rule add --port 8443 --proto tcp --comment web
vpsctl network ufw rule add --port 5000:5010 --proto udp
vpsctl network ufw rule add --action allow --port 5432 --source 192.0.2.0/24 --family ipv4
vpsctl network ufw rule edit --number 3 --port 9443
vpsctl network ufw rule delete --number 3
```

规则列表给出即时编号、稳定内容 ID、地址族、方向、动作、端口、地址、关联服务和备注。编号可能随增删变化，脚本在锁内重新读取并核对目标；双栈规则的 IPv4/IPv6 项分别标识。编辑保留所选项的顺序，发生错误恢复原规则。组合是否合法同时经过本项目校验和 UFW 校验。

`status --json` 输出含 `installed`、`active`、`ipv6` 布尔值及 `rules`、`links` 数组的对象。`rule list --json` 输出规则数组，`link list --json` 输出 `owner`、`detached`、`scope` 和 `requirements`；稳定规则 ID 反映规则内容，规则编辑后 ID 会改变，编号不构成持久标识。

仍被服务引用的规则默认受保护。例如先运行 `link detach node:ID`，再手动调整该节点的规则；其他服务仍引用同一规则时保护继续有效。`link attach node:ID` 恢复自动管理并同步当前配置。

## 自动联动

| 业务 | 维护规则的时机与范围 |
| --- | --- |
| SSH | prepare 保留旧端口并添加候选端口；新会话验证和 commit 成功后释放旧端口；abort/restore 恢复对应需求 |
| 节点 | 根据 profile 使用 TCP、UDP 或两者；增删改和清除配置时同步；REALITY 的本机辅助端口不向外放行 |
| 中转转发 | 使用 UFW `route allow` 放行 DNAT 后的目标 IP、协议、目标端口；目标域名解析改变时同步更新 |
| TLS HTTP-01 | 申请和续期期间临时申请 80/TCP，成功、失败或可捕获中断后释放；DNS-01 不新增入站规则 |

联动只在 UFW 开启时修改规则；未安装或未开启时记录配置需求。启用前读取现有 SSH、节点和中转配置补齐存量规则。停止、重启服务或普通卸载但保留配置时继续保留需求，删除配置才释放。中转出口本身是远端地址，不生成本机 INPUT 放行；公共监听范围继续由现有 nftables DNAT 配置控制。

永久需求自动接管完全等价的已有 ALLOW 规则，并记录原始规则内容。来源限制、限速、拒绝或更大端口范围不等于服务所需规则，不会被擅自拆分或扩大权限；阻断冲突会明确失败。临时 TLS 需求借用已有规则而不改变其永久归属。

同一个端口或转发目标可以有多个服务引用，最后一个引用释放后才清理规则。解除联动保留人工规则并持续记住选择，后续同步不自动加回。SSH 原有 `--firewall manual` 保持人工管理语义，其他防火墙后端继续走原有流程。

## 状态、事务与恢复

共享状态位于 `/var/lib/vpsctl/network/ufw/`，规则和 UFW 配置仍由系统 UFW 持久化。共享库随 core 分发，中转后台运行时也包含同版本共享库。不同业务不互相调用公开命令。

事务先添加新放行，再提交业务配置，最后删除不再引用的旧规则。开始阶段或业务提交失败恢复本次变化；业务已经成功但旧规则清理失败时，保留新端口及需求并返回 `30`，记录待清理内容，后续 `sync` 重试。同步也回收已失效的临时租约。不可捕获退出和掉电后的遗留以事务记录为恢复依据，不能将中断当作已完成。

普通卸载先停用 UFW，保留配置和联动状态，重装后可以继续同步；`--purge` 才明确清除，并在执行前展示影响和备份。清除保留其他软件包提供的应用配置，例如 OpenSSH 的 UFW profile；Debian 系统同时清理 UFW 的包配置记录，保证后续重装能重新生成配置文件。`reset` 属于高级危险操作，重置后保持停用，再次启用前重新同步服务需求。

退出码沿用项目规范：`2` 参数错误、`3` 前置条件不满足、`4` 权限不足、`10` 配置无效、`20` 外部操作失败、`30` 部分完成、`70` 内部错误、`130` 用户中断。收到 `30` 后应读取具体诊断、检查 `status`、`rule list` 和 `link list`，再运行 `sync`；不要盲目重置规则。

## 验收

所有语法、静态、单元、集成及真实功能检查必须通过 `ssh host-vps-scripts` 执行。本机不运行项目验证。覆盖规则归属与并发、停用和重启持久化、SSH 跨会话、节点实际协议、中转真实 FORWARD 连通性、DNS 更新以及 TLS 租约清理，结果见 [验收记录](ufw-validation.md)。
