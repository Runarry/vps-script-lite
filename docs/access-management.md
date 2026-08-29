# 访问管理

`security access` 统一管理本机用户凭据、公钥和 SSH 远程访问。它不会把 SSH 加固当作一次覆盖写入：中断性变更必须先准备双端口候选配置，再由一个新建立的非 root SSH 会话生成短期证明，最后才能提交。这样仍不能消除云安全组、上游 ACL、NAT 或错误人工操作造成的失联风险；执行前必须保留云厂商串行控制台、VNC、救援系统或其他带外入口。

## 1. 登记信息与支持边界

| 项目 | 值 |
| --- | --- |
| 公开命令 | `security access` |
| 公开脚本 | `commands/security/access.sh` |
| 风险 | `disruptive` |
| 权限 | `optional-root`；帮助、公开状态和第二会话证明可由普通用户执行，所有变更要求 root |
| 演练 | `supported` |
| 能力要求 | `linux,init:systemd` |
| 生命周期 | `experimental` |

当前 SSH 服务编排只支持 systemd。项目其他功能对 OpenRC 的支持不代表本命令支持 OpenRC；在 OpenRC、SysV、WSL、容器或无法唯一确定 SSH systemd unit 的环境中，不应尝试 SSH 准备、提交、中止或恢复。功能脚本还会检查账户工具、OpenSSH 服务端、`sshd -t` 等动作实际需要的前置条件。

本命令只管理本机账户、密码、`authorized_keys` 和自己的 SSH drop-in。它不管理云安全组、托管防火墙、路由器端口映射、堡垒机策略、PAM/LDAP/SSSD 身份源、SELinux 自定义端口标签或发行版之外的 SSH 守护进程。

## 2. 接口

```text
vpsctl security access status [--user USER] [--json]
vpsctl security access user add --name USER [--set-password]
vpsctl security access password set --user USER
vpsctl security access key add --user USER (--stdin | --public-key-file FILE)
vpsctl security access key generate --user USER
vpsctl security access ssh prepare [--port PORT]
    [--root-login allow|deny]
    [--password-login allow|deny]
    [--fallback-user USER]
    [--firewall auto|manual]
vpsctl security access session verify --transaction ID
vpsctl security access ssh commit --transaction ID --confirm-apply ID
vpsctl security access ssh abort --transaction ID
vpsctl security access restore --backup ID
```

`ssh prepare` 至少需要一项待变更设置。全局参数必须写在领域之前，例如：

```text
bash bin/vpsctl --dry-run security access ssh prepare --port 2222 --firewall manual
```

`--json` 只用于 `status`。密码不接受命令行明文参数；公钥从标准输入或明确文件读取。`--confirm-apply` 的值必须与事务 ID 相同，不能由全局 `--yes` 替代。

## 3. 用户、密码与公钥

### 3.1 用户

`user add --name USER` 创建本机登录用户并按发行版授予 `sudo` 或 `wheel` 管理权限；`--set-password` 在创建成功后进入密码设置流程。执行前会验证用户名格式并拒绝覆盖已有账户。密码、公钥和 fallback 操作会结合 `UID_MIN` 与登录 shell 拒绝系统服务账户。若创建后的管理员授权或可选密码步骤失败，命令只回滚本事务新建的账户、主目录和组变更，不触碰预先存在的账户。

本入口不提供删除用户、删除家目录、修改 UID/GID 或批量授予管理员权限，因此不会借由“清理”动作删除仍可能用于恢复的登录账户。需要保留的回退账户可在 SSH 准备阶段通过 `--fallback-user USER` 显式指定。

### 3.2 密码

`password set --user USER` 只为已存在的本机用户设置密码。密码从终端的隐藏输入流程交给系统密码工具，不写入命令行、项目配置、事务元数据或日志。非交互环境没有安全输入来源时会拒绝执行；`--dry-run` 只说明将调用密码设置流程，不读取或生成真实密码。

关闭 SSH 密码认证只影响远程 SSH，不等于锁定本机密码，也不修改 sudo/PAM 策略。在把 `PasswordAuthentication` 改为拒绝之前，应先为非 root 回退用户安装并实测公钥。

### 3.3 公钥

`key add` 接受一条 OpenSSH 公钥记录：自动化可通过 `--stdin` 管道传入，或用 `--public-key-file FILE` 指定文件。入口验证公钥记录后写入目标用户的 `~/.ssh/authorized_keys`，并保持目录、文件所有者和权限适合 OpenSSH 使用；重复添加同一公钥不得产生重复行。私钥不会被该动作读取或复制。

`key generate --user USER` 为目标用户生成新的密钥对，允许由 `ssh-keygen` 在 TTY 中交互设置可选口令。私钥只在当前终端显示一次，不写入普通 stdout、日志、状态 JSON 或备份；操作者输入明确的保存确认后，服务器端临时私钥立即删除。未确认或中断时同时撤销本次新增公钥。密钥生成不自动删除旧密钥，也不自动关闭密码登录。

## 4. SSH 变更事务

### 4.1 准备

`ssh prepare` 在任何写入前完成以下检查：

1. 确认 systemd、OpenSSH 服务端、目标用户与候选端口满足要求。
2. 分析当前有效 SSH 配置；遇到无法证明可安全归并的复杂配置时拒绝继续。
3. 运行 `sshd -t` 验证候选配置。
4. 建立备份和事务状态。
5. 写入受管 drop-in `/etc/ssh/sshd_config.d/00-vpsctl-access.conf`，临时保留旧端口并加入候选端口，同时启用会话验证所需的 `ExposeAuthInfo`。
6. 按所选防火墙模式准备候选端口，然后 reload SSH 服务并再次验证运行状态。

准备成功会输出事务 ID、候选端口、回退用户、证明期限和下一条命令。候选阶段不会关闭旧 SSH 端口。`prepare` 只是让 sshd 在候选端口监听并配置本机防火墙，不代表云安全组、上游 ACL 或 NAT 已放行，也不代表客户端确实能从外部登录。

同一时间只允许一个待处理事务。事务证明有效期为 15 分钟；超时后不能提交，应先 `ssh abort`，检查网络和防火墙后重新准备。

### 4.2 新会话验证

从另一终端通过候选端口建立一个全新的 SSH 连接，使用准备阶段指定或确认的非 root 用户登录，然后在该新会话中运行：

```text
bash bin/vpsctl security access session verify --transaction ID
```

验证会结合 sshd 暴露的会话认证信息检查事务、端口、用户、会话新鲜度和非 root 身份，并为该事务记录一次性短期证明。以下情况不能代替验证：仍存活的旧端口会话、本机控制台、`su`/`sudo` 后启动的 shell、root SSH 会话、仅执行 TCP 探测，或在事务创建前已存在的连接。

### 4.3 提交

确认新会话可实际执行命令后，保留该会话不要退出，并在原管理会话执行：

```text
bash bin/vpsctl security access ssh commit \
  --transaction ID \
  --confirm-apply ID
```

提交只接受尚未消费且仍在 15 分钟期限内的匹配证明。它把候选配置转为最终配置，移除事务性旧端口和验证用设置，按事务记录收敛受管防火墙规则，运行 `sshd -t`，再 reload 并检查 SSH 服务。任何校验失败都必须报告备份和中止/恢复入口；不要在结果不明确时手工删除事务目录。

端口未变化而只调整 root 或密码认证策略时，仍必须走新会话证明和提交，避免把“配置语法正确”误当作“保留了可用认证路径”。

### 4.4 中止

候选端口不可达、认证失败、证明过期或决定取消时，从仍可用的原会话或带外控制台执行：

```text
bash bin/vpsctl security access ssh abort --transaction ID
```

中止恢复 prepare 前的受管 SSH 配置和由本事务管理的防火墙状态，验证配置并 reload 服务，然后清理待处理事务。它不会撤销事务之外的人工防火墙修改、云安全组变更，也不会删除用户、密码或公钥操作。

## 5. 双端口与复杂配置拒绝

修改端口时，prepare 阶段必须同时保留当前有效端口和候选端口；只有新端口上的新会话证明通过后，commit 才能移除旧端口。双端口是临时恢复措施，不是长期监听方案。若当前配置已经存在多个来源、条件块或 include 关系，使入口不能唯一判定全局 `Port`、`PermitRootLogin`、`PasswordAuthentication` 或受管 drop-in 的优先级，命令会在写入前拒绝。

典型拒绝对象包括无法安全解析或归并的 `Match` 条件、冲突的多处设置、非标准 include 布局、受管文件被符号链接替换，以及已有待处理事务。RHEL 系官方 drop-in 对 `/etc/crypto-policies/back-ends/opensshserver.config` 的精确 Include 是唯一的发行版白名单例外；其他嵌套 Include 仍拒绝。此类拒绝是安全边界，没有 `--force` 绕过；先用 `sshd -T`、`sshd -t` 和配置来源检查人工简化配置，确认现有连接仍可恢复，再重新运行 prepare。

## 6. 防火墙协同

`--firewall auto` 只在脚本能够识别受支持的本机防火墙后端并安全记录规则归属时执行。UFW 使用带 `vpsctl security access` 注释的编号规则，firewalld 使用固定优先级的精确 rich rule，iptables/ip6tables 同样使用 comment 标记。nftables 检测只把 `inet`、`ip` 或 `ip6` 家族中会限制入站的 `type filter hook input` 基链视为 SSH 入站防火墙；只有容器转发、NAT、output 等非 INPUT 规则，或者只有空的 `policy accept` INPUT 链时，不再误判为需要修改的防火墙。需要放行时，入口会在每条相关的现存 INPUT 基链首部插入带精确 comment 标记的规则，不会创建一个可能仍被后续 drop 基链拦截的独立 accept 基链。

若已证明 `nftables.service` 与 `/etc/nftables.d/*.nft` include 可用，规则同时写入受管片段 `/etc/nftables.d/zz-vpsctl-access.nft`。若无法证明持久化，交互模式只询问一次：自动添加运行时规则，或本次改由人工管理；非交互模式下显式的 `--firewall auto` 会选择运行时规则并打印警告。运行时规则仍参与 prepare、第二会话验证、commit、abort 和所有权清理，但在重启或其他工具 reload/flush ruleset 后会失效。此时 `status` 的防火墙 `mode` 为 `runtime`；在重启或 reload ruleset 前必须补齐可靠持久化或恢复原 SSH 端口，否则可能失联。vpsctl 不会为了规避这一限制而覆盖未知的 `/etc/nftables.conf` 或伪造独立基链。

prepare 先放行候选端口；commit 在新会话证明通过后才移除本事务不再需要的旧端口规则；abort 恢复事务前的受管规则。删除时同时要求状态中的所有权记录与后端中的精确标记匹配。检测到多个活动后端、INPUT 基链无法解析、后端不可用、已有受管持久化片段却发生入口漂移，或无法保证回滚时，自动模式仍会拒绝继续。

`--firewall manual` 不修改防火墙。操作者必须在 prepare 前确认候选端口已同时通过本机防火墙、云安全组、上游 ACL 和 NAT；commit 后再自行移除旧端口规则。脚本显示的端口计划是提示，不构成外部网络已放行的证明。无论哪种模式，新 SSH 会话验证都是提交的必要条件。

## 7. 状态、配置与恢复

| 内容 | 路径 |
| --- | --- |
| 受管 SSH 配置 | `/etc/ssh/sshd_config.d/00-vpsctl-access.conf` |
| 事务和访问状态 | `/var/lib/vpsctl/security/access/` |
| 历史备份 | `/var/lib/vpsctl/backups/security/access/` |

`status [--user USER]` 显示 SSH 服务、受管配置、有效端口、实际监听、防火墙后端与显式端口规则、待处理事务；指定用户时附加账户和公钥状态。防火墙字段不把云安全组、默认策略或复杂规则集猜测成“可达”，外部可达性仍由第二会话验证。`--json` 输出同一状态的机器可读表示，但不得包含密码、私钥、公钥正文或一次性证明秘密。

`restore --backup ID` 根据备份类型恢复一次 SSH 事务（受管配置、被迁移的 Port 来源文件和 vpsctl 自有防火墙状态）或一次 `authorized_keys` 修改。恢复是中断性动作，要求 root、强确认与当前内容哈希漂移检查；它不是账户数据库、密码哈希、全部公钥或外部防火墙的全机快照。存在待处理 SSH 事务时优先使用对应 `ssh abort`，不要用历史 restore 跨过活动事务。

建议恢复顺序：

1. 保持所有仍可用的 SSH 会话在线，必要时进入带外控制台。
2. 运行 `status`，记录事务 ID、备份 ID、有效监听端口和防火墙模式。
3. 有活动事务时运行 `ssh abort --transaction ID`。
4. 中止失败或需要回到更早状态时，选择确认过的备份运行 `restore --backup ID`。
5. 人工运行 `sshd -t`，检查 systemd unit、监听端口、本机和外部防火墙，再用新的非 root SSH 会话验收。

不要通过删除 `/var/lib/vpsctl/security/access/` 或受管 drop-in 来“解除锁定”；这会丢失自动中止所需的事务信息。

## 8. 演练、退出码与验收

`--dry-run` 会展示用户、公钥、SSH 配置、防火墙、reload、备份和事务计划，不写账户数据库、home、`/etc/ssh`、防火墙或状态目录，也不会生成可供 commit 使用的事务/证明。密码演练不读取密码，密钥生成演练不创建密钥。

常见退出码遵循项目统一约定：`2` 参数错误，`3` 前置条件或依赖不满足，`4` 权限不足，`10` 配置或输入校验失败，`20` 外部命令或服务操作失败，`30` 部分完成或需要人工恢复，`130` 用户中断。发生 `30` 时应立即保留当前会话并按命令输出的事务/备份路径恢复。

所有验证必须通过 `ssh host-vps-scripts` 在专用真实环境执行，不得在当前系统或 WSL 运行项目代码。至少覆盖：普通用户/root 权限、用户和密码失败后的部分完成、公钥去重与权限、dry-run 零写入、复杂配置写前拒绝、双端口监听、新非 root 会话证明、证明过期/复用/错误端口拒绝、commit 后旧端口收敛、abort、历史 restore、防火墙自动与手工模式，以及断开原会话后仍可从候选会话恢复。OpenRC 只验证入口明确拒绝，不作为支持平台验收。

仓库提供不纳入默认测试套件的显式真实验收脚本 `tests/integration/test-security-access-real.sh`。它只应在专用主机以 `VPSCTL_REAL_ACCESS_TEST=1` 启用，并要求调用方提供已准备好的一次性非 root 管理员、私钥路径、普通用户可读的项目副本和空闲候选端口；脚本在同一持续 root 会话内完成双端口 prepare、publickey 第二会话证明、root-only 证明权限检查、abort 与配置哈希复原检查。
