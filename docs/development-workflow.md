# 开发与验收流程

本流程用于新增或修改管理入口、功能脚本、公共库及相关文档。

## 测试环境限制

- 所有项目测试、语法检查、静态检查、集成验证和真实功能验收必须通过 `ssh host-vps-scripts` 在专用真实环境中执行。
- 禁止在当前系统或 WSL 中运行项目测试或验证命令；当前系统只用于编辑、差异审阅和不执行项目代码的只读仓库检查。
- `host-vps-scripts` 专门用于本项目验证，可按测试需要安装依赖、修改系统配置及执行破坏性场景。测试时仍须记录执行命令、关键结果和必要的恢复信息，且不得把真实凭据、主机信息或未脱敏日志提交到仓库。
- 文档中的“隔离环境验证”均特指 `host-vps-scripts`，不得以本机、WSL、容器或其他环境的结果替代。

### 默认套件与定向检查

按变更影响选择最小有效检查范围，优先复用现有测试及仍有效的验收结果；只有新改动、相关失败或明确未覆盖的风险才扩大范围。纯文档修改检查内容、链接与示例，不默认运行功能测试；用户或发布流程明确要求的检查仍须完成。

`tests/run.sh` 先对脚本中的固定清单执行 `bash -n`，再运行列出的单元测试和 `tests/integration/test-vpsctl.sh`。其他真实集成脚本即使出现在语法检查清单中，也没有被执行；末尾的 `PASS: all tests` 只代表该默认套件通过。真实服务、网络、重启或发布验收须按功能文档单独安排，不能用默认套件结果替代。

以下示例中的 `/path/to/vps-script-lite` 需替换为专用主机上的源码副本路径：

```bash
# 单个相关套件
ssh host-vps-scripts 'cd /path/to/vps-script-lite && bash tests/unit/test-network-bbr.sh'
# 代理脚本的定向分组；也可选择 relay-forward 或 relay-family
ssh host-vps-scripts 'cd /path/to/vps-script-lite && VPSCTL_TEST_ONLY=relay-cache bash tests/unit/test-service-proxy.sh'
# 构建交付与入口版本的定向检查
ssh host-vps-scripts 'cd /path/to/vps-script-lite && VPSCTL_TEST_ONLY=release-delivery bash tests/unit/test-release-build.sh'
ssh host-vps-scripts 'cd /path/to/vps-script-lite && VPSCTL_TEST_ONLY=entry-version bash tests/integration/test-vpsctl.sh'
```

`VPSCTL_TEST_ONLY` 由上述各脚本自行解释，不是 `tests/run.sh` 的通用筛选参数。分组名以对应脚本的分支为准；位置参数或未识别的分组值不会筛选测试，可能进入该脚本的默认流程。需要默认套件时，在同一 SSH 环境显式运行 `bash tests/run.sh`。

验收记录应注明源码基线、实际命令、检查范围及未运行或受限的部分。ShellCheck 必须区分零诊断、已有诊断无新增、部分分析和检查失败；不能把有限分析或被中止的执行记作完整通过。

## 1. 设计

新增功能前先确定：

1. 用户目标、影响范围和不可接受的失败状态。
2. 是否能作为一个独立命令完成；若包含多个可独立验证的目标，应拆为多个脚本。
3. 所属领域、命令名称、参数、输出和退出码。
4. 所需权限、外部依赖、支持平台和恢复方式。
5. 是否需要公共能力；仅有一个调用方时优先保留在功能脚本内部。

先补充命令登记草案，再开始实现，可避免入口和功能脚本产生不一致接口。

## 2. 实现顺序

推荐按以下顺序推进：

1. 编写帮助文本和参数校验。
2. 实现只读的当前状态检测。
3. 实现演练计划和风险提示。
4. 实现最小范围的系统变更。
5. 实现变更后验证、错误清理和恢复路径。
6. 接入统一入口的固定命令映射。
7. 在 `host-vps-scripts` 完成影响范围内的自动化检查及必要的真实验收，更新命令登记与文档。

## 3. 评审清单

### 边界

- 管理入口没有业务逻辑。
- 一个功能脚本只负责一个清晰目标。
- 功能脚本没有直接调用其他功能脚本。
- 公共库没有加载时副作用，也没有单一命令专属逻辑。

### 正确性

- 参数、路径、权限和依赖在变更前完成校验。
- 重复执行不会累积重复状态或造成额外破坏。
- 失败不会被吞掉，退出码符合规范。
- 中断和部分完成状态有清晰处理。

### 安全

- 没有 `eval`、未引用的变量展开或用户可控命令拼接。
- 敏感值不会出现在参数回显、日志或测试夹具中。
- 写入、覆盖和删除的目标范围经过验证。
- 可能中断远程访问的变更具备验证和恢复路径。

### 用户体验

- `--help` 与实际行为一致。
- 演练、确认和非交互模式语义明确。
- 错误信息能够指导下一步操作。
- 命令登记、支持平台和恢复说明已更新。

## 4. Release 资产与发布流程

仓库根 `VERSION` 是项目版本的规范来源，当前版本为 `0.8.12`。应用、功能、tag、发布资产、安装目录和命令行展示必须使用同一版本号。自 v0.8.10 起使用 schema 2；v0.8.9 按领域打包，使用 schema 1，跨格式迁移不通过 self update。

schema 2 Release 必须一次性提供安装器、严格 TSV 清单及注册表中的全部 bundle。构建与运行时共用 [lib/registry.sh](../lib/registry.sh) 中的 `VPS_BUNDLE_IDS`、`vps_registry_bundle_files` 和 `vps_registry_command_bundles`；新增命令、文件或依赖只维护这些固定定义，不复制另一份文档清单。当前生成的完整资产集合以构建输出的 manifest 为准，v0.8.9 的 schema 1 资产保持原样。

| 资产 | 命名规则 |
|---|---|
| 安装器 | `vpsctl.sh` |
| 清单 | `vpsctl-manifest.tsv` |
| core、共享库与功能包 | `vpsctl-<bundle-id>-<VERSION>.tar.gz`；bundle ID 来自注册表，版本来自根目录 `VERSION` |

每个 tar 包内使用项目根相对路径，不包含额外顶级包目录。`vpsctl-manifest.tsv` 依次包含 `schema_version<TAB>2`、`version<TAB>VERSION`、`repository<TAB>Runarry/vps-script-lite`、`asset<TAB>launcher<TAB>vpsctl.sh<TAB>SHA256`，以及各 bundle 的 `bundle<TAB>NAME<TAB>vpsctl-NAME-VERSION.tar.gz<TAB>SHA256`。名称唯一，文件名和版本精确对应，摘要是 64 位小写十六进制，core 必须存在；功能和共享包内容必须符合注册表固定清单。新增功能或私有模块时同步更新该清单和依赖映射。

`bash scripts/build-release.sh [输出目录]` 默认输出到 `dist/release`。输出目录专用于发布资产：只接受 `vpsctl.sh`、`vpsctl-manifest.tsv` 和 `vpsctl-<包名>-<X.Y.Z>.tar.gz` 普通文件；包名由小写字母、数字和分隔它们的连字符组成。目录内有其他文件、隐藏条目、子目录或符号链接时，构建报错并保留原内容。不能将文件系统根、源码根或源码祖先目录作为输出目录。

构建先在输出目录的同一父目录准备完整候选资产，归档、摘要和 manifest 写入成功后才整体切换；成功构建会移除该输出中的旧版本资产。构建失败保留旧输出；交付失败会尝试恢复旧目录，恢复失败则保留并报告旧资产路径。交付完成后的临时目录清理失败返回非零、报告残留路径，并保留已经生成的新输出。

同一输出目录应串行构建。切换期间该路径可能短暂不存在；可捕获的 HUP／INT／TERM 会进入相同清理与恢复流程，SIGKILL 或掉电后的自动恢复不在保证范围内。此步骤只生成本地发布资产，不创建或上传 GitHub Release。

发布按以下顺序进行：

1. 固定仓库根 `VERSION`，并确认应用展示、tag、manifest 版本和资产文件名完全一致。
2. 从目标提交按注册表清单构建全部不带顶级目录的 bundle 和 `vpsctl.sh`，计算所有资产的 SHA-256，最后生成 `vpsctl-manifest.tsv`；清单不能自我登记。
3. 只通过 `ssh host-vps-scripts` 验证清单严格解析、摘要、tar 路径安全、全新安装、重复安装、首次功能及共享依赖下载、离线缓存、显式更新、指定版本更新、失败回退、普通卸载和 purge 边界。不得在当前系统或 WSL 运行这些检查。
4. 先创建 draft Release 并上传同一版本的完整资产集；资产未齐全或摘要不符时不得发布，也不得让 `latest` 提前指向该版本。
5. 从 draft 资产重新下载并在 `host-vps-scripts` 复核 SHA-256 与安装结果，再发布 tag 对应的 Release。
6. 发布后验证 `releases/latest/download/vpsctl.sh`、显式 `vX.Y.Z` 更新和全新 VPS 安装，记录命令、关键结果、回退版本和必要恢复信息。

标签触发的发布工作流先查询该 tag 对应的 Release：不存在时创建草稿，已有草稿时保留标题和说明，随后上传本次完整构建并覆盖同名资产；不在本次构建中的附件保留。查询失败或无法确定状态时停止，已发布版本直接报错，不修改其资产。工作流不会自动发布 Release。

创建或上传失败后可直接重跑。同一 tag 应串行执行，上传期间不要手动发布或修改草稿。`gh release upload --clobber` 会先删除旧同名资产，再上传新文件，因此失败可能暂时留下不完整草稿；重跑补齐后仍须按上述流程重新下载复核，再手动发布，不提供远端资产回滚。

跨格式验证必须包含上一版实际发布的安装器与资产，不能只依赖修改当前源码版本号的夹具。schema 1 与 schema 2 双向迁移均使用先下载并校验目标安装器/manifest、普通卸载管理器代码（不使用 purge）、再运行目标安装器的流程；验证已部署服务、配置、功能状态和备份保持不变。schema 2 同格式更新须验证仅下载 manifest、安装器和 core，旧功能缓存不预取，新版本首次调用才重新下载。

一行 `curl | bash` 安装把 HTTPS、GitHub、仓库与 Release 发布权限以及远端安装器本身放在初始信任边界内。manifest 能验证安装器之后下载的资产，也能在先下载模式下验证本地 `vpsctl.sh`，但如果安装器和 manifest 都来自同一被攻破的发布渠道，它不能提供独立真实性证明。验收文档必须同时保留“先固定 tag 下载安装器与 manifest、核对摘要、审阅脚本、再执行本地文件”的较安全流程。

## 5. 完成定义

一个功能只有同时满足以下条件才算完成：

- 脚本职责单一并符合目录规范。
- 静态检查、语法检查和自动化测试通过。
- 通过 `ssh host-vps-scripts` 在声明支持的平台上完成真实环境验证。
- 正常、重复执行、无权限、缺依赖、失败和中断路径均被验证。
- 命令登记、帮助和恢复说明齐全。
- 涉及分发时，完整 Release 资产、manifest、同版本功能及共享库缓存、无启动更新检查和 self 卸载保护边界均已在 `host-vps-scripts` 验证。
- 没有真实凭据、主机信息、运行状态或日志进入仓库。
