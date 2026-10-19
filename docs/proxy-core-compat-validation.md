# Xray / sing-box 兼容升级验收

验收日期：2026-09-14。全部项目代码、语法检查、静态检查、单元测试和真实链路验收仅通过 `ssh host-vps-scripts` 在专用 Debian x86_64 环境执行；工作站只编辑、读取仓库和传输文件。

## 第一阶段

第一阶段在集成协议增强前通过完整回归与独立真实验收，冻结副本位于 `/root/vpsctl-core-compat.2MKdA2/phase1-snapshot`。

| 检查 | 结果 |
| --- | --- |
| `bash tests/run.sh` | PASS：全部语法、单元和主管理入口集成测试 |
| `test-service-proxy-version-compat.sh` | PASS：版本边界、五种策略、同版本配置/状态迁移、无变化、候选拒绝、各写入故障、连续更新、pending 合并、启动失败和事务恢复 |
| `test-service-proxy-relay-tls.sh` | PASS：指纹校验、受管证书匹配、外部材料、旧缓存、URI 更换、未迁移出口管理与纯转发 |
| `test-service-proxy-compat-real.sh` | PASS：两版 Xray 与 sing-box 1.14.0 的证书、IP 策略及 REALITY 防偷验收 |
| `test-service-proxy-relay-cores-real.sh` | PASS：Xray 26.3.27、26.9.9 分别搭配 sing-box 1.14.0；各覆盖 26 个协议/内核组合、12 次切核和 10 个 IP 策略配置 |
| `test-service-proxy-relay-connectivity-real.sh`，26.3.27 / 1.14.0 | 25 PASS、1 个既有 XFAIL；另有 2 个真实切核冒烟 PASS |
| `test-service-proxy-relay-real.sh` | PASS：真实 nftables 事务与网络转发 |

真实证书验收包括正确 SPKI 成功、错误 SPKI 失败、`insecure=1` 无法绕过固定要求，以及旧整证书指纹迁移；两核共六项。Hysteria2 使用 Ed25519 证书时，sing-box 1.14.0 的 Chrome QUIC 模拟开启失败、关闭成功，符合兼容提示。

IP 策略验收使用独立网络和挂载命名空间，在本地配置回环、私有地址以及公网地址段的受控双栈目标。Xray 26.3.27、26.9.9 各执行五种策略 × TCP/UDP × 三类目标，共 60 次真实请求；同时校验实际到达的 IPv4/IPv6 地址族。这证明不同地址类别的路由行为，不代表对外部互联网质量或吞吐量的测试。

REALITY 防偷在两版 Xray 下分别通过完整脚本：每次记录 57 次受控目标到达；错误 SNI、包含白名单域名的非精确匹配、无 SNI、非 TLS、不完整握手均未到达目标。正确 SNI、SNI 修改、回环辅助监听和规则隔离仍有效。

第一阶段新真实验收脚本通过 `bash -n`、ShellCheck warning 级别和 shfmt。修改过的应用模块在远端检查语法和错误级别 ShellCheck；保留原有格式及既有低级别诊断，没有为通过检查而整文件重排。

## 第二阶段

第一阶段验收通过后，集成 XHTTP、Hysteria2 双核及 sing-box 运行参数；最终完整 `bash tests/run.sh` 再次通过。新增节点、协议和中转单元测试全部 PASS，修改过的应用模块和新增单元测试通过远端 ShellCheck 错误级检查。

| 检查 | 结果 |
| --- | --- |
| 真实配置与切核矩阵 | PASS：sing-box 1.14.0 分别搭配 Xray 26.3.27、26.9.9，以及 sing-box 1.15.0-alpha.3 搭配 Xray 26.9.9；每组 28 个协议/内核组合、14 次切核、10 个 IP 策略配置 |
| XHTTP 实际 HTTP/2 链路 | PASS：两版 Xray × 三个 XHTTP profile × 四种 mode，共 24 个成功组合；另验证错误路径、错误 Host、REALITY 错误 SNI，以及新旧默认行为 |
| Hysteria2 互通 | PASS：两版 Xray 分别与 sing-box 1.14.0 组成四个服务端/客户端方向，覆盖无混淆、Salamander 及真实 TCP/UDP 转发 |
| sing-box Gecko / BBR | PASS：Gecko；客户端和服务端各三档 BBR 的实际 TCP/UDP 链路；服务端保留 100 Mbps 原配置，客户端省略带宽触发 BBR 协商 |
| sing-box 1.15.0-alpha.3 | PASS：完整配置/切核冒烟及 Gecko 实际 TCP/UDP 链路 |
| 完整中转链路，26.9.9 / 1.14.0 | 27 PASS、1 个原有 XFAIL；另有 2 个真实切核冒烟 PASS |
| 新 profile 的 REALITY 防偷 | PASS：七个 profile/core 组合；两版 Xray 下各记录 70 次预期目标到达，负向过滤及 SNI 编辑均通过 |

XHTTP 的 Host、路径与 SNI 分别保存并传入内核。TLS 使用整证书固定时，Xray 原生 pin 认证可替代名称认证，因此修改 SNI 而仍命中同一受信证书的用例预期成功；这项验收不声称同时强制域名校验。REALITY 错误 SNI 仍必须失败。

带宽验收在每个 Xray Hysteria2 服务端配置中断言 `100 Mbps` 为字符串 `"100000000"`，两版内核均验证并启动该配置，实际链路通过。`12500000 B/s` 来自 [v26.3.27 的 Bandwidth.Bps 解析](https://github.com/XTLS/Xray-core/blob/v26.3.27/infra/conf/transport_internet.go#L460)：无后缀数值按 bit/s 再除以 8；CLI dump 未提供内部已解析 protobuf，因此未把源码推导称为直接读取运行时数值，也未进行吞吐量基准测试。

BBR 用例通过受控协商条件验证配置与连接：客户端不声明上/下行带宽，服务端保留带宽值；根据 [Xray Hysteria 协商逻辑](https://github.com/XTLS/Xray-core/blob/v26.3.27/transport/internet/hysteria/hub.go) 和 sing-box 对应原生实现进入 BBR。这验证参数可用性与协商路径，不用于比较三档算法的性能。

## 复验命令

以下命令均在 `ssh host-vps-scripts` 登录后的专用机执行。代码与内核保存在本次验收目录中；二进制变量指向已核对摘要的临时文件。

```bash
cd /root/vpsctl-core-compat.2MKdA2/source
bash tests/run.sh

export SING_BOX_BINARY=/root/vpsctl-core-compat.2MKdA2/cores/sing-box-1.14.0
export XRAY_BINARY=/root/vpsctl-core-compat.2MKdA2/cores/xray-26.9.9
bash tests/integration/test-service-proxy-relay-cores-real.sh
ALLOW_XRAY_TROJAN_GRPC_REALITY_XFAIL=1 bash tests/integration/test-service-proxy-relay-connectivity-real.sh
bash tests/integration/test-service-proxy-reality-anti-relay-real.sh
bash tests/integration/test-service-proxy-relay-real.sh

export SING_BOX_STABLE_BINARY=/root/vpsctl-core-compat.2MKdA2/cores/sing-box-1.14.0
export SING_BOX_ALPHA_BINARY=/root/vpsctl-core-compat.2MKdA2/cores/sing-box-1.15.0-alpha.3
export XRAY_OLD_BINARY=/root/vpsctl-core-compat.2MKdA2/cores/xray-26.3.27
export XRAY_NEW_BINARY=/root/vpsctl-core-compat.2MKdA2/cores/xray-26.9.9
bash tests/integration/test-service-proxy-compat-real.sh
ENHANCEMENT_SCOPE=all bash tests/integration/test-service-proxy-protocol-enhancements-real.sh
```

将 `XRAY_BINARY` 改为 `xray-26.3.27` 可复验旧版配置和防偷；将 `SING_BOX_BINARY` 改为 `sing-box-1.15.0-alpha.3` 可复验预发布配置矩阵。协议增强脚本支持 `xhttp`、`hysteria`、`sing-box-knobs`、`sing-box-server-bbr`、`alpha` 分组，便于只重跑受影响项。

## 证据与恢复

远端根目录 `/root/vpsctl-core-compat.2MKdA2` 保存代码快照、临时内核和日志。主要记录：

- `logs/phase1-full-suite.log`
- `tester/phase1-complete-real.log`
- `tester/phase1-static-final.log`
- `logs/phase1-real-cores-stable.log`、`logs/phase1-real-cores-latest.log`
- `logs/phase1-connectivity-stable.log`
- `logs/phase1-latest-trojan-grpc.log`
- `logs/phase1-nft-relay-real.log`
- `logs/phase2-full-suite.log`、`logs/phase2-shellcheck.log`
- `logs/phase2-real-cores-26.3.27.log`、`logs/phase2-real-cores-26.9.9.log`、`logs/phase2-real-cores-alpha.log`
- `logs/phase2-connectivity-latest.log`
- `logs/phase2-reality-guard-26.3.27.log`、`logs/phase2-reality-guard-26.9.9.log`
- `tester/phase2-xhttp.log`、`tester/phase2-hysteria.log`
- `tester/phase2-sing-box-knobs.log`、`tester/phase2-sing-box-server-bbr.log`、`tester/phase2-alpha.log`
- `tester/phase2-static-final.log`、`tester/phase2-native-bandwidth.txt`

Xray 26.9.9 与 sing-box 1.15.0-alpha.3 的临时二进制均通过官方 Release 摘要校验，未替换机器已安装内核。协议与防偷验收使用临时配置和受控端口，退出时清理进程、恢复 hosts；IP 策略测试的地址与 hosts 修改隔离在命名空间中。nftables 测试清理专用表、网络接口及命名空间，恢复原转发开关。测试凭据、二进制和详细运行日志不提交仓库。

既有 `trojan-grpc-reality` XFAIL 仍存在：26.9.9 的严格复验也出现相同 `server-preface` 关闭特征。未增加失败类型豁免；后续版本实际连通时，现有测试会以 XPASS 提醒移除对应豁免。

## 2026-10-03：单核 pending 回滚隔离

本次只修改待生效回滚及其必要的 UFW、中转归一化和缓存衔接，保留 CLI、schema 1 与 LKG 保存时机。节点按内核合并恢复，中转以记录的 before/after 逐项撤销；冲突先于文件写入拒绝。运行规则恢复失败保留 pending，下一次 start/restart 重试，嵌套 UFW 事务完成后才清理恢复记录。

所有执行均经 `ssh host-vps-scripts`。新增 `VPSCTL_TEST_ONLY=core-pending` 分组在原代码上复现另一内核节点被覆盖；修复后按受影响场景分段验证，并复用仍有效的结果：

| 验证范围 | 结果与证据 |
| --- | --- |
| 双向回滚、另一核 CRUD/DNS、双核 pending、配置/二进制/元数据和 UFW owner 保留 | PASS；`candidate1-core-pending.log` 的四项隔离场景。该轮后续中转场景发现的撤销记录合并错误已修复，不能将该整份日志标为通过。 |
| 中转记录合并与抵消、级联恢复、独立 forward 保留、旧主机 DNS 缓存回退 | PASS；修复后 `candidate2-relay-merge.log`。 |
| 端口及中转同记录冲突、旧节点 pending、旧中转 pending 的安全拒绝与等价状态接受 | PASS；`candidate1-conflicts-legacy.log`。 |
| 先归一化中转、后首次修改转发运行状态；恢复失败、公开入口重试、HY2/缓存保留和幂等 | PASS；`candidate3-runtime-retry.log`。 |
| UFW 节点/转发边界，以及外层 node/relay 的回滚失败和同步失败仍保留 pending | PASS；`candidate4-proxy-ufw.log`，包含六项新增嵌套场景。 |
| 最终 UFW 包装逻辑下已有 Xray 自动应用失败恢复 | PASS；`candidate4-relay-xray.log`。 |

以上证据位于专用主机 `/var/tmp/vpsctl-core-pending-regressions/`，各轮 `sha256` 清单记录代码身份。夹具使用临时系统根目录和可控的内核、服务、UFW、nft/DNS 替身；验证结束清理本轮夹具，诊断副本和日志保留。没有修改宿主实际代理服务或防火墙；这些结果不代表真实代理连通性验收。

父任务在 `/var/tmp/vpsctl-p1-parent.kLhidA/source` 执行现有版本兼容/更新事务、DNS 以及 `hy2-runtime` 分组，全部通过，记录分别为其 `evidence/proxy-version.log`、`proxy-dns.log`、`proxy-hy2-runtime.log`。相关脚本的 `bash -n` 和 ShellCheck error 级别检查通过。五个修改的代理模块采用 `shellcheck -x -P SCRIPTDIR --extended-analysis=false` 全级别对照：基线与最终版均为 7 条既有诊断，无新增；因此不声称 ShellCheck 全级别零诊断或启用了扩展数据流分析。新增测试的语法和 error 级别检查亦通过。未运行全仓库套件或真实代理协议连接测试。

## 2026-10-19：第一批模板与兼容性优化

基于提交 `3890e9e2afcc6c04e884b518d37c17ebef03f483` 加本轮工作区改动。范围为默认更新避免隐式降级、AnyTLS padding 跟随内核默认、sing-box 原生整证书固定及兼容提示；未增加 CLI 参数或状态 schema，也未修改默认安装通道。工作区原有访问管理修改保持原样。

全部项目执行均通过 `ssh host-vps-scripts`。证据根目录为 `/var/tmp/vpsctl-proxy-batch1.oPQewQ`，各子目录保留对应源码快照和日志。sing-box `1.14.3`、`1.15.0-alpha.7`、`1.15.0-alpha.12` 从官方 Release 下载并验证资产 SHA-256，元数据及摘要位于 `cores/`；真实 TLS 服务端使用此前保存的 Xray `26.3.27`，未替换宿主已安装内核。

| 验收范围 | 结果与证据（相对上述根目录） |
| --- | --- |
| Release 选择与更新菜单 | PASS；`update/evidence/core-release.log`、`arguments-menu.log`。包含默认跳过、显式稳定版/tag 回退、混合 `--core all`、Release 仅查询一次、更新四项菜单及安装菜单兼容。 |
| 同版本重建与更新事务 | PASS；`update/evidence/version-compat.log`。包含 SemVer 预发布排序、无法比较返回 3、默认跳过返回 0、已有 pending 保留、同版本配置/状态迁移及原有写入失败回滚。 |
| 整证书固定出口的候选降级 | PASS；`update/evidence/core-update-pin.log`。绑定仅含 URI 指纹的 sing-box 出口，先更新到 alpha.8 建立 pending，再显式降到 `1.14.3`/`alpha.6`，均在提交前拒绝，二进制、配置、元数据、relay、pending 和备份摘要不变。此项使用内核/服务替身。 |
| TLS URI、版本边界和信任语义 | PASS；`tls/evidence/unit-tls-final.log`。包含 `1.14.3`、`alpha.6`、`alpha.7`、`alpha.12`，已有 SPKI 优先、含 NUL 的摘要字节编码、编码失败传播、URI 替换清理旧信任材料、按实际内核显示固定方式及不扩展状态字段。 |
| 原生整证书固定真实链路 | PASS；`tls/evidence/alpha7.log`、`alpha12.log`，各 12 个链路用例。包含原有 SPKI/Xray 兼容，正确/错误整证书 pin，`insecure=false/true` 均不能绕过错误 pin，以及同公钥重签后 SPKI 成功、旧整证书 pin 失败。 |
| 旧版 TLS 行为 | PASS；`tls/evidence/stable1143.log`。sing-box `1.14.3` 的既有 SPKI 正负链路、受管证书迁移和 Xray 整证书固定通过；无 SPKI 材料的 URI 整证书固定仍明确拒绝。 |
| AnyTLS 默认 padding | PASS；`parent/evidence/anytls-tls-real.log`、`anytls-reality-real.log`。sing-box `1.14.3` 下两个 profile 各通过一个真实协议中转链路，并复用脚本附带的切核冒烟。未做性能或流量特征评测。 |
| 节点与独占出口切核 | PASS；`acceptance/evidence/node-enhancements.log`。无本地证书/SPKI 时切到 `1.14.3`/`alpha.6` 拒绝且状态/写入记录不变，切到 `alpha.7` 生成原生指纹，反切 Xray 保留 hex 指纹及 relay 数据；此夹具替换提交/服务边界，不代表真实 systemd 验收。 |
| 协议列表与原有节点回归 | PASS；`parent/evidence/node-enhancements.log`、`profiles.txt`。原有节点增强测试通过；协议列表可显示版本与已知组合提示。 |

降级夹具第一轮因没有形成 pending 而失败，日志保存在 `update/evidence/core-update-pin-fixture-failure.log`。随后使用真实更新流程建立 pending，仅重跑受影响分组并通过，没有放宽状态保持断言。已通过且未受后续展示文案修改影响的真实链路结果直接复用。

修改过的应用脚本和测试脚本均完成远端 `bash -n`。节点模块和 sing-box 模板通过 ShellCheck error 级别检查；更新相关四文件的非递归 warning 级检查报告 13 条既有 SC2034，关闭扩展分析后的 HEAD 对照结果一致，无新增诊断。TLS 和切核测试的定向检查仍有未修改行的既有诊断，不能称为全级别零告警。递归 ShellCheck 在专用机被资源限制终止，记录为未完成；未修复环境或抑制告警，原始结果与基线对照保存在各 `evidence/` 目录。

最小复验命令（登录专用机并进入对应源码快照后执行）：

```bash
VPSCTL_TEST_ONLY=core-release bash tests/unit/test-service-proxy.sh
VPSCTL_TEST_ONLY=arguments-menu bash tests/unit/test-service-proxy.sh
VPSCTL_TEST_ONLY=core-update-pin bash tests/unit/test-service-proxy.sh
bash tests/unit/test-service-proxy-version-compat.sh
bash tests/unit/test-service-proxy-relay-tls.sh
bash tests/unit/test-service-proxy-node-enhancements.sh

export SING_BOX_BINARY=/var/tmp/vpsctl-proxy-batch1.oPQewQ/cores/sing-box-1.15.0-alpha.7
export XRAY_OLD_BINARY=/root/vpsctl-core-compat.2MKdA2/cores/xray-26.3.27
bash tests/integration/test-service-proxy-compat-real.sh --tls
# 将 SING_BOX_BINARY 改为 alpha.12 或 1.14.3 可复验对应 TLS 分支。

export SING_BOX_BINARY=/var/tmp/vpsctl-proxy-batch1.oPQewQ/cores/sing-box-1.14.3
export XRAY_BINARY="$XRAY_OLD_BINARY"
CONNECTIVITY_CORE=sing-box CONNECTIVITY_PROFILE=anytls-tls bash tests/integration/test-service-proxy-relay-connectivity-real.sh
CONNECTIVITY_CORE=sing-box CONNECTIVITY_PROFILE=anytls-reality bash tests/integration/test-service-proxy-relay-connectivity-real.sh
```

真实验收使用临时证书、配置与受控端口，退出时清理测试进程和夹具；源码、已校验内核和必要证据保留。原生 TLS 配置和详细日志含测试凭据，仅保存在专用机，不提交仓库。未运行全仓库套件、完整协议矩阵、新增场景的真实 systemd 生命周期或吞吐量基准测试；历史 Trojan/gRPC/REALITY、HY2 Chrome off 限制仍按原验收版本描述，本轮没有据此推断新版本结果。
