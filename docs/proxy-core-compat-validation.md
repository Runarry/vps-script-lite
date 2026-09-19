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
