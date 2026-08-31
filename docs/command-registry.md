# 命令登记规范

管理入口只能分发已经登记的命令。登记信息是固定、可审查的数据，不得通过执行未知脚本来动态生成。

当前固定注册表位于 `lib/registry.sh`；领域菜单和命令列表均由它生成。

安装态的 core 还提供并固定登记 `self` 自管理命令。其实现随 core 常驻，不依赖任何按需领域 bundle，也不能被其他领域 bundle 覆盖。

## 1. 每个命令必须登记的字段

| 字段 | 要求 |
| --- | --- |
| 命令 | 唯一的 `<domain> <action>` 名称 |
| 文件 | 相对于仓库根目录的固定路径 |
| 摘要 | 一句话说明目标，不描述实现细节 |
| 风险等级 | `read-only`、`change`、`disruptive` 或 `destructive` |
| 权限 | 普通用户、部分步骤提权或必须 root |
| 交互 | 是否可能提示，以及非交互模式所需参数 |
| 演练 | 支持、不适用或不支持并说明原因 |
| 依赖 | 非 Bash 内建及非项目公共库的外部命令 |
| 支持平台 | 已验证的发行版及版本范围 |
| 幂等性 | 是否幂等；若否，明确重复执行的影响 |
| 输出 | 人类可读输出及机器可读格式的契约 |
| 退出码 | 基础退出码之外的命令特有含义 |
| 恢复 | 失败或中断后的检查与恢复入口 |
| 负责人 | 维护该命令的团队或角色 |

## 2. Core 常驻 self 命令

`self` 固定驻留在 core，并以 `stable` 生命周期登记在“脚本管理”领域；接口为：

```text
vpsctl self status
vpsctl self update [--version vX.Y.Z]
vpsctl self uninstall [--purge] [--confirm-uninstall] [--confirm-purge]
```

| 子命令 | 语义 |
| --- | --- |
| `status` | 只读显示本地运行模式、分发版本、受管路径和领域缓存状态；不检查远端更新 |
| `update` | 用户显式触发更新；默认使用 latest，`--version vX.Y.Z` 固定目标 tag；校验完成并落盘后才原子切换 current，失败保留原版本 |
| `uninstall` | 交互模式现场确认；非交互模式需要 `--confirm-uninstall`；移除快捷入口、current 和 vpsctl 分发文件，不卸载任何功能组件 |
| `uninstall --purge` | 交互模式再次确认；非交互模式还需要 `--confirm-purge`；在普通卸载基础上只额外删除 `/var/lib/vpsctl/self/` 元数据 |

普通卸载和 purge 均不得删除或修改 `/etc/vpsctl/`、功能状态与备份、功能安装的软件包/服务/规则/内核及 `/usr/local/libexec/`。`--yes` 不能替代非交互调用所需的两个 self 确认标志。该边界独立于各功能命令自己的 `uninstall` 或 `--purge`，后者仍按各自命令文档处理。

## 3. 已登记命令清单

0.5.0 登记以下网络、系统、安全、服务与服务器测试入口。状态列描述接口生命周期，不表示已经完成真实 VPS 或 VM 验证；隔离环境验收要求见[网络设置](network-settings.md)、[系统内核管理](kernel-management.md)、[访问管理](access-management.md)、[Fail2ban 管理](fail2ban-management.md)、[代理管理](proxy-management.md)和[服务器测试](server-testing.md)。

| 命令 | 文件 | 摘要 | 风险 | 权限 | 演练 | 能力要求 | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `network bbr` | `commands/network/bbr.sh` | 查看、启用、设置或恢复 BBR 与队列规则 | `change` | `optional-root` | `supported` | `linux` | `experimental` |
| `network dns` | `commands/network/dns.sh` | 检测、测试、设置、刷新、验证或恢复 DNS | `disruptive` | `optional-root` | `supported` | `linux` | `experimental` |
| `network ip-policy` | `commands/network/ip-policy.sh` | 查看、设置或恢复 glibc IPv4/IPv6 地址排序偏好 | `disruptive` | `optional-root` | `supported` | `linux` | `experimental` |
| `network rfw` | `commands/network/rfw.sh` | 安装、配置和管理 RFW systemd 服务 | `disruptive` | `optional-root` | `supported` | `linux,init:systemd` | `experimental` |
| `system kernel` | `commands/system/kernel.sh` | 安装、更新或安全卸载最新 XanMod BBRv3 内核 | `disruptive` | `optional-root` | `supported` | `linux` | `experimental` |
| `security access` | `commands/security/access.sh` | 管理用户、密码、公钥与可验证恢复的 SSH 访问变更 | `disruptive` | `optional-root` | `supported` | `linux,init:systemd` | `experimental` |
| `security fail2ban` | `commands/security/fail2ban.sh` | 安装、配置和管理 OpenSSH 的 Fail2ban 防护 | `disruptive` | `optional-root` | `supported` | `linux,init:systemd` | `experimental` |
| `service proxy` | `commands/service/proxy.sh` | 平级管理 Xray 与 sing-box 内核、节点、日志和时间同步 | `disruptive` | `optional-root` | `supported` | `linux,service:any` | `experimental` |
| `test nodequality` | `commands/test/nodequality.sh` | 运行 NodeQuality 服务器综合质量测试 | `disruptive` | `root` | `unsupported` | `linux,root` | `experimental` |
| `test tcpquality` | `commands/test/tcpquality.sh` | 运行 TcpQuality TCP 网络质量测试 | `disruptive` | `root` | `unsupported` | `linux,root` | `experimental` |

`optional-root` 表示只读查询、帮助或部分计划阶段可以普通用户运行；实际系统变更仍须 root 或在具体步骤提权。依赖只在当前动作实际需要且确实缺失时处理：真实执行的交互模式列出缺失项并询问是否安装，非交互模式和 `--dry-run` 依赖计划必须显式提供 `--install-deps`。`--dry-run --install-deps` 只展示安装计划，仍不写配置、不安装依赖、不启动或重启服务。

在 Release 安装态，注册表仍登记相同的公开命令，但命令文件按领域来自当前分发版本的 bundle：`network`、`system`、`security`、`service` 和 `test` 分别对应同名 bundle，`self` 来自常驻 core。某领域首次分发前必须从 current 对应的同一个 GitHub Release 下载其资产，并以 `vpsctl-manifest.tsv` 中的 SHA-256 校验后缓存到版本隔离目录；未校验文件、其他版本缓存或临时下载都不得进入注册表解析与分发。源码树运行继续直接使用仓库固定路径。

`system kernel` 的状态可由普通用户读取，安装和卸载要求 root 与独立强确认，`--yes` 不能绕过。它只支持 Debian/Ubuntu amd64，从 XanMod 官方 APT 源动态选择当前候选版本，固定验证完整仓库密钥指纹；ARM、容器、WSL、Secure Boot 和不受支持的 suite 在任何写入前停止。卸载只传递经过校验的确切 XanMod 包名，必须先证明非 XanMod 回退内核存在，不运行 `autoremove`。完整恢复边界见[系统内核管理](kernel-management.md)。

主管理菜单选中登记功能后直接进入该功能 UI，不插入命令详情或二次运行页。封闭枚举由编号选择，开放值沿用命令参数校验；菜单真实执行动作，不暴露执行型全局参数、机器输出开关、`--force` 或 `--confirm-*` 标志。上述参数仅供直接功能 CLI；菜单中的危险动作使用对应交互确认及强确认短语。

入口按“命令 + 完整子参数形状”计算本次调用的能力要求。`network rfw` 的无附加参数 `help`/`--help`/`-h` 与 `status`，以及 `security fail2ban` 的帮助与 `status [--json]`，在 Linux 上不要求 `init:systemd`；`service proxy` 的无附加参数 `help`/`--help`/`-h`、`profiles`、`status`，以及 `time status [--json]` 在 Linux 上不要求 `service:any`。`test nodequality` 和 `test tcpquality` 的单个 `help`/`--help`/`-h` 参数不要求 `root`，但仍保留 `linux` 能力要求。未列出的参数形状和两项测试的无参数真实执行不能使用这些例外；服务器测试完整边界见[服务器测试](server-testing.md)。

`service proxy` 的 `service:any` 能力要求由入口解析为可用服务管理器，功能脚本会进一步限制为 systemd 或 OpenRC。注册表只登记公开入口 `commands/service/proxy.sh`；其 `commands/service/proxy/` 子模块是固定加载的私有实现，不单独登记，也不构成可直接分发的命令。交互菜单统一展示双核状态并按能力分组，通过状态筛选、枚举和编号选择解析内核或节点；订阅可选全部，或选择当前确有节点的 sing-box/Xray 范围。直接命令与非交互模式保留 `--core` 和 `--id` 作为精确消歧接口。帮助、协议矩阵和系统时间状态可由普通用户执行；内核状态与节点/订阅会读取受限状态文件，因此和安装、更新、卸载、服务控制、节点写操作及时间同步一样要求 root。重启、外部二进制原地更新与 `--purge` 另有不能被 `--yes` 绕过的强确认。完整接口见[代理管理](proxy-management.md)。

`security access` 整体登记为 `linux,init:systemd`，当前不承诺 OpenRC SSH 服务编排。帮助、公开状态和第二 SSH 会话证明可由普通用户运行；用户、密码、公钥、SSH 配置、防火墙、事务和备份的变更由功能脚本要求 root。SSH 变更不是单次覆盖：`ssh prepare` 建立保留旧端口的候选配置，新的非 root SSH 会话运行 `session verify` 写入短期证明，再由原管理会话运行 `ssh commit`；验证失败或不再继续时使用 `ssh abort`，历史备份由 `restore` 显式恢复。复杂的 include/Match/多值来源等无法安全归并的配置会在写入前拒绝。完整接口与恢复顺序见[访问管理](access-management.md)。

`security fail2ban` 只管理 systemd 上的 OpenSSH `sshd` jail。受管配置位于独立的 `jail.d/*.local` 文件，安装和配置会先备份、测试完整 Fail2ban 配置，再启动或 reload 服务；状态会报告受管文件漂移和 SSH 端口不同步。已有非受管 `sshd` jail 时必须显式接管，卸载只撤销 vpsctl 配置，不删除软件包、用户配置或历史备份。完整接口与恢复顺序见[Fail2ban 管理](fail2ban-management.md)。

## 4. 单命令说明模板

每个已登记命令还应在适当的命令文档中使用以下结构：

```text
# <domain> <action>

目标：
影响范围：
风险等级：
权限要求：
支持平台：
外部依赖：
幂等性：
演练支持：

用法：
参数：
正常输出：
机器可读输出：
退出码：
配置与状态文件：
失败与恢复：
验证方法：
```

模板只是说明格式，不代表需要为尚未实现的命令预先创建空文档。

## 5. 生命周期

- `experimental`：接口可能调整，不进入默认稳定清单。
- `stable`：遵守公开接口兼容要求，可用于日常运维。
- `deprecated`：继续工作但发出迁移提示，文档注明替代命令和移除版本。
- `removed`：从入口分发中删除，并在变更记录中保留迁移说明。

命令重命名必须经过弃用周期，入口不得在没有提示的情况下静默改变旧命令含义。
