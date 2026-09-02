# 架构与目录规范

## 1. 设计目标

项目围绕以下约束组织：

1. 只有一个面向用户的管理入口，提供一致的帮助、参数和错误处理体验。
2. 每个独立运维功能原则上对应一个公开入口脚本；复杂命令可以加载同名私有子模块，但只有入口脚本可被管理器分发。
3. 管理入口不承载业务逻辑；功能脚本之间不直接互相调用。
4. 共享代码只提取稳定、通用的基础能力，避免形成难以追踪的隐式依赖。
5. 配置、运行状态、日志和密钥与项目源码分离。
6. 源码树运行与 Release 安装并存；安装态按分发版本隔离，领域代码只从同版本 Release 获取。

## 2. 目录结构

```text
vps-script-lite/
├── README.md
├── bin/                    # 统一管理入口；只负责环境初始化与命令编排
├── commands/               # 独立功能脚本
│   ├── backup/             # 备份、恢复与保留策略
│   ├── deploy/             # 软件或应用部署
│   ├── monitoring/         # 健康检查、资源与告警相关操作
│   ├── network/            # 网络、DNS、防火墙和连通性
│   ├── security/           # 加固、审计、证书和访问控制
│   │   ├── access.sh       # 用户、凭据与 SSH 访问管理公开入口
│   │   ├── fail2ban.sh     # OpenSSH Fail2ban 防护公开入口
│   │   └── tls.sh          # 域名 TLS 证书管理公开入口
│   ├── service/            # 系统服务安装、配置和生命周期管理
│   │   ├── proxy.sh        # 代理管理公开入口
│   │   └── proxy/          # 仅由 proxy.sh 加载的私有实现模块
│   ├── test/               # 服务器综合质量与网络质量测试
│   └── system/             # 系统信息、内核、软件包和基础维护
├── config/                 # 可提交的默认配置与示例；禁止存放真实密钥
├── lib/                    # 可被入口或功能脚本复用的稳定公共函数
├── tests/
│   ├── fixtures/           # 脱敏、最小化的测试输入
│   ├── integration/        # 隔离环境中的跨组件验证
│   └── unit/               # 参数、纯函数和边界行为测试
└── docs/                   # 架构、开发和命令登记规范
```

尚未实现功能的空目录暂以 `.gitkeep` 保存；`commands/network/` 包含网络功能脚本，`commands/system/kernel.sh` 实现系统内核管理入口，`commands/security/access.sh` 实现访问管理入口，`commands/security/fail2ban.sh` 及其私有子模块实现 OpenSSH Fail2ban 防护，`commands/security/tls.sh` 及其私有子模块实现域名 TLS 证书管理，`commands/service/proxy.sh` 及其私有子模块实现代理管理入口，`commands/test/nodequality.sh` 与 `commands/test/tcpquality.sh` 实现服务器测试入口。

## 3. 组件职责

### 3.1 管理入口

源码树入口文件为 `bin/vpsctl`；安装后的固定快捷入口为 `/usr/local/bin/vpsctl`，并解析到当前分发版本的 core。管理入口只负责：

- 解析全局参数，如日志级别、非交互模式和演练模式。
- 将 `<domain> <action>` 映射到登记过的功能脚本。
- 初始化并向子脚本传递规范化的运行上下文。
- 统一展示帮助、版本和可用命令。
- 原样传递功能脚本的退出状态，不掩盖失败。

入口不得实现软件安装、防火墙修改、备份等具体业务，也不得使用 `eval` 或由用户输入拼接可执行路径。命令必须通过固定登记信息解析。

### 3.2 功能脚本

公开功能脚本位于 `commands/<domain>/`。默认粒度为“一项可独立描述、执行、验证或回滚的操作一个入口脚本”。

适合拆分的判断标准：

- 能够拥有独立的帮助说明和参数集合。
- 能够单独判断成功或失败。
- 能够单独测试，且不会依赖另一个功能脚本的内部状态。
- 用户可能只需要执行该功能，而不需要执行同目录的其他功能。

仅当多个步骤必须形成不可分割的事务、拆开会破坏安全性或一致性时，才允许由一个功能脚本协调这些步骤。原因应写入对应命令文档。

当一个公开入口同时包含多个平级后端、生命周期、配置渲染或事务恢复流程，允许在 `commands/<domain>/<action>/` 下拆分私有子模块。私有子模块必须满足以下约束：

- 只能由对应的 `commands/<domain>/<action>.sh` 通过固定文件名加载，不得由注册表直接分发。
- 文件名和路径不能来自用户输入；加载前应验证普通文件、可读性和符号链接边界。
- 被加载时只能定义函数、常量及由入口稍后初始化的模块变量，不执行平台初始化、文件写入、服务操作或其他系统副作用。
- 不提供独立 CLI 稳定性承诺；参数解析、公共退出码和事务边界仍由公开入口统一负责。
- 业务专用帮助函数留在私有模块中，只有确实被多个公开命令复用且接口稳定后才提升到 `lib/`。

功能脚本不得直接调用另一个公开 `commands/` 脚本。加载自己同名目录中的私有子模块不视为跨功能调用；需要组合多个公开功能时，仍由管理入口或未来专门的编排层按公开接口调度。

服务器测试入口是受控的第三方启动器：上游地址必须是代码中固定的官方 HTTPS URL，下载内容只保存到本次调用拥有的临时目录，再以前台子进程运行。临时目录从 `/var/tmp` 与 `/tmp` 中选择安全、可写且空间更大的位置，避免小容量 tmpfs 阻断上游 rootfs。入口不把上游参数提升为本项目接口，不缓存或登记远端脚本版本，也不能把上游的高负载、联网、报告上传或系统副作用包装成可演练动作。退出与常规可捕获信号只清理本次调用创建并仍可识别的临时资源；不得扫描或删除其他调用、上游历史运行或用户文件。`SIGKILL`、入口 Shell 崩溃及主机掉电等无法执行陷阱的情况不承诺自动清理。

### 3.3 公共函数库

`lib/` 仅存放稳定且至少被两个组件复用的基础能力，例如日志格式、平台检测、权限检查、锁和安全的文件替换。

公共库不得：

- 包含某个功能命令专属的业务流程。
- 在被加载时修改系统或产生其他副作用。
- 隐式退出调用方进程。
- 读取未声明的全局变量。

### 3.4 Release 分发与安装态

源码树仍可直接运行 `bash bin/vpsctl`，用于开发、审阅和明确选择的源码部署场景。安装态采用以下固定布局：

```text
/usr/local/bin/vpsctl                         # 用户快捷入口
/usr/local/lib/vpsctl/
├── current                                  # 指向当前分发版本的原子切换指针
└── releases/
    └── <version>/                           # 单一不可变分发版本
/var/lib/vpsctl/self/                        # 安装、自更新、资产缓存元数据
```

`core` 随每个分发版本常驻，必须足以完成启动、帮助、版本解析、固定登记、自管理和领域资产装载。`network`、`system`、`security`、`service` 与 `test` 是按领域发布的 bundle；首次分发某领域命令时，core 从当前版本对应的同一个 GitHub Release 下载 bundle，先按清单中的 SHA-256 校验，再写入该版本缓存并执行。校验失败、版本不匹配或资产缺失时不得执行已有临时文件，也不得回退到其他分发版本的 bundle。正常启动和菜单刷新均不检查更新，不应因为 GitHub 不可用而阻断已经缓存的功能。

仓库根 `VERSION` 是分发版本的规范来源。当前分发版本 `0.2.0` 的 tag 为 `v0.2.0`，Release 必须同时包含：

```text
vpsctl.sh
vpsctl-manifest.tsv
vpsctl-core-0.2.0.tar.gz
vpsctl-network-0.2.0.tar.gz
vpsctl-system-0.2.0.tar.gz
vpsctl-security-0.2.0.tar.gz
vpsctl-service-0.2.0.tar.gz
vpsctl-test-0.2.0.tar.gz
```

bundle 内部使用项目根相对路径，不能再包一层顶级目录。`vpsctl-manifest.tsv` 是严格 TSV，字段顺序如下；SHA-256 使用 64 位小写十六进制：

```text
schema_version<TAB>1
version<TAB>0.2.0
repository<TAB>Runarry/vps-script-lite
asset<TAB>launcher<TAB>vpsctl.sh<TAB>SHA256
bundle<TAB>core<TAB>vpsctl-core-0.2.0.tar.gz<TAB>SHA256
bundle<TAB>network<TAB>vpsctl-network-0.2.0.tar.gz<TAB>SHA256
bundle<TAB>system<TAB>vpsctl-system-0.2.0.tar.gz<TAB>SHA256
bundle<TAB>security<TAB>vpsctl-security-0.2.0.tar.gz<TAB>SHA256
bundle<TAB>service<TAB>vpsctl-service-0.2.0.tar.gz<TAB>SHA256
bundle<TAB>test<TAB>vpsctl-test-0.2.0.tar.gz<TAB>SHA256
```

manifest 的 `version`、tag、文件名和安装目标版本必须一致。`current` 只在 manifest、core 及必要安装文件完成校验并落盘后切换；更新失败时保留原 current。这里的分发版本 `0.2.0` 与现有应用/功能版本 `0.7.0` 是不同维度，不得用分发版本回退功能文档或功能接口。

### 3.5 配置与运行数据

仓库中的 `config/` 只保存默认值、模式说明和脱敏示例。实际部署时建议使用：

- 系统配置：`/etc/vpsctl/`
- 持久状态：`/var/lib/vpsctl/`
- self 元数据：`/var/lib/vpsctl/self/`
- 运行锁：`/run/vpsctl/`
- 日志：优先写入 systemd journal；确需文件时使用 `/var/log/vpsctl/`

密码、令牌、私钥、真实主机清单和包含隐私的数据不得提交到仓库。

访问管理把 SSH 加固视为跨会话事务：公开入口可以暂时并存旧端口与候选端口，但只有新的非 root SSH 会话提交一次性证明后才允许提交最终配置。事务状态和备份属于运行数据，不得放入仓库；功能脚本必须在写入前拒绝无法安全归并的复杂 SSH 配置，且不能把当前仍存活的旧会话当作新路径验证结果。

## 4. 调用关系

```text
用户
  └─> 统一入口 bin/vpsctl
        ├─> 公共库 lib/（可选）
        └─> commands/<domain>/<action>.sh（功能实现后，以子进程执行）
              ├─> commands/<domain>/<action>/*.sh（可选，仅加载私有模块）
              └─> 公共库 lib/（可选）
```

管理入口应以子进程方式执行公开功能脚本，而不是加载其业务代码，以隔离参数、陷阱、工作目录和退出状态。公开功能脚本可以加载明确声明的公共库及自身同名目录中的固定私有模块；私有模块不得反向加载公开功能脚本或绕过入口自行分发。

安装态的调用关系保持相同，只是 core 和领域代码来自 `/usr/local/lib/vpsctl/current` 指向的同一分发版本；源码树运行继续使用仓库内 `bin/`、`lib/` 和 `commands/`。领域下载与缓存属于 core 的装载职责，不改变功能脚本之间不得互相调用的边界。

## 5. 稳定边界

以下内容一旦发布即视为公开接口：

- `<domain> <action>` 命令名。
- 命令行参数及其默认值。
- 标准输出中声明为机器可读的格式。
- 退出码含义。
- 配置键、环境变量和持久状态格式。
- Release 资产命名、manifest schema、安装路径与 `vpsctl self` 命令语义。

对公开接口的破坏性变更必须提供迁移说明，并在主版本升级时进行。
