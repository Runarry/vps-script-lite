# HY2 双核模板与端口跳跃验收

日期：2026-10-02。所有项目执行均通过 `ssh host-vps-scripts`，编辑主机未运行项目代码、语法检查或测试。代码已实现本轮参数、模板、URI、菜单及 nft 生命周期；一个关闭 Chrome 模拟的跨内核 UDP 组合存在上游限制，不能记为全部互通通过。

## 环境与版本

远端工作目录：`/var/tmp/vpsctl-hy2.Y1jXm9`。

- Xray：`26.3.27`、`26.4.13`、`26.6.1`、`26.9.8`、`26.9.9`、`26.9.30`。
- sing-box：`1.13.21`、`1.14.2`；真实 systemd 生命周期另使用宿主已有的 `1.14.0`。
- 8 份测试版本均来自官方 release，下载包与 release 的 SHA256 已核对；原始元数据及摘要保存在 `cores/*.release.json`、`cores/*.verified.sha256`。
- 链路、nft、UFW 测试使用独立网络和挂载命名空间，客户端从 veth 对端进入 PREROUTING，未用 OUTPUT 重定向代替真实入站。
- 为验收安装了 UFW `0.36.2-9`，依赖保留在专用主机；结束时宿主 `Status: inactive`、`ENABLED=no`，没有新增宿主 UFW 用户规则。

## 配置与定向回归

| 项目 | 结果 | 覆盖 |
| --- | --- | --- |
| 真实内核配置检查 | PASS，33 组 | 六个 Xray 版本及两个 sing-box 版本；出口 BBR、Gecko、Chrome、固定／随机间隔、新旧 Xray 跳跃结构、自动／指定带宽 |
| Xray 服务端 BBR | PASS，另 6 组 | 26.4.13 和 26.9.30 各验证 standard／conservative／aggressive，保留 10000/10000 Mbps |
| 参数和状态 | PASS | 端口范围边界、合并、去重；非法间隔；恢复默认；带宽成对设置／单边编辑／切回 auto；旧状态；HY2 拒绝显式 TUIC 拥塞参数 |
| URI | PASS | 域名、IPv4、括号 IPv6；多范围；省略端口 443 与缺省 SNI；特殊密码；导入导出；显式端口覆盖 URI；仅改端口保留 TLS pin |
| 节点和出口菜单 | PASS | 版本门槛、默认复原、固定／随机间隔展示、自定义节点向导、dry-run |
| 节点切核 | PASS | 保留端口、带宽和可转换选项；目标旧版本拒绝；事务及服务失败恢复 |
| 普通转发回归 | PASS | 冲突、nft 渲染、DNS 缓存、地址族、服务生命周期、订阅和回滚 |
| UFW 声明与分发 | PASS | NAT 后实际监听端口 input 声明；两份新私有模块纳入发布清单及运行时复制 |

执行的既有单测：`test-service-proxy-node-enhancements.sh`、`test-service-proxy-protocol-enhancements.sh`、`test-service-proxy-relay-tls.sh`、`test-service-proxy-version-compat.sh`、`test-proxy-ufw.sh`。代理管理总单测仅运行 `hy2-runtime`、`relay-conflicts`、`relay-render`、`relay-cache`、`relay-forward`、`relay-family`、`relay-service`、`node-core`，另通过既有 harness 运行参数/dry-run 和交互向导函数。发布检查仅运行 `release-delivery`。没有执行无关全量套件。

## 持续 TCP／UDP 与实际跳跃

下表按**服务端 → 客户端**列出；客户端通过 SOCKS 保持同一 TCP 连接，并持续发送 UDP 请求。固定 5 秒用例持续至少 17 秒，随机 5–7 秒用例持续至少 23 秒；PREROUTING 中 NAT 前的独立计数确认使用至少两个目的端口，覆盖至少三个跳跃间隔。

| 服务端 → 客户端 | 混淆／间隔 | 结果 |
| --- | --- | --- |
| Xray 26.9.30 → sing-box 1.14.2 | none、Salamander、Gecko，各固定 5 秒 | TCP＋UDP PASS |
| sing-box 1.14.2 → Xray 26.9.30，Chrome 默认 | none、Salamander、Gecko，各固定 5 秒 | TCP＋UDP PASS |
| sing-box 1.13.21 → Xray 26.4.13 | none，固定 5 秒 | TCP＋UDP PASS |
| sing-box 1.13.21 → Xray 26.3.27 | Salamander，固定 5 秒 | TCP＋UDP PASS |
| Xray 26.6.1 → sing-box 1.14.2 | Salamander，随机 5–7 秒 | TCP＋UDP PASS |
| sing-box 1.14.2 → Xray 26.9.9 | Gecko，随机 5–7 秒、新 UDP mask | TCP＋UDP PASS |
| sing-box 1.14.2 → Xray 26.9.8 | Gecko，随机 5–7 秒、旧 udpHop | TCP＋UDP PASS |
| Xray 26.9.30 → sing-box 1.14.2 | none，随机 5–7 秒 | TCP＋UDP PASS |
| sing-box 1.14.2 → sing-box 1.14.2 | Gecko，随机 5–7 秒 | TCP＋UDP PASS |
| Xray 26.9.30 → sing-box 1.14.2，指定 IPv4 监听 | none，固定 5 秒 | TCP＋UDP PASS |
| sing-box 1.14.2 → Xray 26.9.30，Chrome off、指定 IPv6、手动 100/200 Mbps | none，固定 5 秒 | TCP 持续跳跃 PASS；UDP FAIL，上游兼容限制 |

Ed25519 专项：Xray 26.9.30 Chrome on 拒绝握手，符合该模拟握手的证书限制；Chrome off 可以建立 TCP，UDP 回包仍失败。没有把关闭 Chrome 模拟写成保证 TCP／UDP 均可用的解决方法。

## 网络与恢复

| 项目 | 结果 |
| --- | --- |
| IPv4／IPv6 额外端口映射、指定地址 DNAT | PASS |
| 不同本机地址隔离、TCP 共用端口 | PASS |
| 本机 OUTPUT 与经过本机的 UDP 转发不被误改 | PASS |
| HY2 两表与普通转发两表独立保留 | PASS |
| UFW 默认拒绝，先验证无关 UDP 被阻断，再按实际监听端口放行 | PASS，持续 HY2 TCP＋UDP 跳跃通过 |
| 仅 HY2 跳跃节点安装真实 systemd 服务 | PASS；不创建 relay.json、DNS 缓存或 forwarding sysctl |
| 普通停止、保留配置卸载、重装 | PASS；声明和映射保留／恢复 |
| 清表后重启受管 systemd 服务 | PASS；从声明恢复规则，模拟开机恢复路径 |
| nft 应用失败 | PASS；恢复原节点清单和原规则 |
| purge 服务停用失败 | PASS；恢复原内核 active/enabled、清单和 nft；后续成功 purge 清理映射并停用共享服务 |
| 删除最后普通转发／最后跳跃、pending 内核重启失败 | PASS，systemd／OpenRC 定向模拟测试 |

真实 systemd 测试先快照宿主受管配置、规则及服务状态，结束后两轮均记录 `RESTORE_RESULT=0`。首次 purge 故障注入未命中，因为真实 ExecStopPost 提前清表，该次脚本退出 1；之后改用一次性服务停用失败注入，独立补验成功，未将首次退出误记为全通过。

## 上游限制与可用替代

已实测的失败范围是 **Xray 26.9.30 客户端关闭 Chrome 模拟，连接 sing-box 1.14.2 服务端的 UDP 回包**，包括 Ed25519 专项及 RSA／IPv6／手动带宽用例。TCP 和端口跳跃本身可用。

原因：Xray 在 2026-09-01 后启用 `OmitMaxDatagramFrameSize`；Chrome 模拟会重新声明该参数，因此默认模式通过，而 off 模式触发 sing-box 服务端依赖的 `datagram support disabled`。Xray 和 sing-box 公开配置没有单独控制这一兼容行为的字段，不能靠模板补一个参数解决。[Xray dialer](https://github.com/XTLS/Xray-core/blob/v26.9.30/transport/internet/hysteria/dialer.go)、[Chrome 参数覆盖](https://github.com/apernet/quic-go/blob/184d081eef3e/chrome_parrot.go)、[sing-box 服务端依赖](https://github.com/SagerNet/sing-quic/blob/6a3a24d65b99/hysteria2/service.go)、[Xray 配置映射](https://github.com/XTLS/Xray-core/blob/v26.9.30/infra/conf/transport_internet.go)。

需要 TCP＋UDP 时，可保持默认 Chrome 模拟并使用 RSA/ECDSA 证书，或采用上表已通过的 sing-box 客户端组合。脚本未自动升级、换核、修改系统时间或使用预发布版本规避失败。

## 检查边界

- PASS：受影响脚本的远端 `bash -n`；生产脚本、两个新模块及四份独立单测的 `shellcheck -S error -x`；发布模块完整性。
- PASS：新增真实链路脚本的远端 ShellCheck（仅排除独立路径解析 SC1091）、格式检查及 Python 流量夹具编译。
- 警告：生产脚本的 warning 级 ShellCheck 仍有跨文件变量未使用、可选函数参数等 SC2034／SC2120 提示，不能宣称 warning 级零告警。
- 受阻：代理管理总单测 `test-service-proxy.sh` 的 ShellCheck 进程被终止，退出 137；批量和单文件方式均未完成。该文件的语法检查及本轮相关实际测试已通过，没有为此改测试基础设施。
- 未运行：宿主真正重启（通过清表后真实服务重启验证恢复路径）、真实 OpenRC 宿主（仅定向模拟）、无关全量测试和未列出的内核组合。
- FAIL：上述 Chrome off 跨内核 UDP 回包；这是验收暴露的上游限制，仍保留失败证据。

## 复现与证据

新增独立链路脚本为 `tests/integration/test-service-proxy-hy2-real.sh`，流量夹具为 `tests/fixtures/hy2-traffic.py`。通过 SSH 在专用环境执行，例如：

```bash
cd /var/tmp/vpsctl-hy2.Y1jXm9/repo
HY2_CORES_DIR=/var/tmp/vpsctl-hy2.Y1jXm9/cores \
HY2_EVIDENCE_DIR=/var/tmp/vpsctl-hy2.Y1jXm9/recheck-config \
HY2_SCOPE=config bash tests/integration/test-service-proxy-hy2-real.sh
```

`HY2_SCOPE` 可选 `config`、`server-bbr`、`traffic`、`nft`、`chrome`、`ufw`、`supplement`、`bind`；UFW 用例需要已安装 UFW。包含已知 UDP 失败组合的 scope 会保留失败状态，不因 TCP 单项成功返回全部通过。

远端主要证据：

- `evidence/`：定向单测、分发、语法／ShellCheck 结果；修复后的 URI 和菜单结果为 `protocol-fixed.log`、`relay-tls-fixed.log`。
- `acceptance/config.log`、`acceptance/traffic-fixed.log`：33 组配置及前 12 组持续双向协议测试。
- `acceptance/server-bbr.log`、`acceptance/server-bbr.evidence/`：6 组服务端 BBR 真实配置补验。
- `acceptance/nft-addressed.log`、`acceptance/ufw-final.log`、`acceptance/bind-verified.log`：网络隔离、真实 UFW 和指定监听。
- `acceptance/supplement-final.log`、`acceptance/chrome-debug/`：同核替代路径、Chrome off 的 TCP 连续跳跃与 UDP 失败。
- 各 case 的 `counters.json`、`traffic.jsonl`、配置与内核日志：目的端口计数、持续时间和失败原因。
- `service-acceptance/`、`service-acceptance/purge-check/`：真实服务生命周期、故障注入和原环境恢复。

## 2026-10-02 分享链接导入兼容修正

用户反馈把端口范围直接写为 `:20120-20200` 时，客户端直接拒绝导入。重新核对发现：官方 Hysteria URI 支持 authority 多端口，但 v2rayN/v2rayNG 导入器使用标准 URL 的数字端口，并另读 `mport` 扩展。此前真实内核及本项目 URI 往返检查没有覆盖图形客户端的导入器，不能据此宣称所有客户端都支持原生范围语法。[官方规范](https://hysteria.network/docs/developers/URI-Scheme/)、[v2rayN 实现](https://github.com/2dust/v2rayN/blob/master/v2rayN/ServiceLib/Handler/Fmt/Hysteria2Fmt.cs)、[v2rayNG 实现](https://github.com/2dust/v2rayNG/blob/master/V2rayNG/app/src/main/java/com/v2ray/ang/fmt/Hysteria2Fmt.kt)。

本次将双核节点分享改为 `hysteria2://PASSWORD@HOST:20120?mport=20120-20200&...`。地址后的端口保留实际监听端口；`mport` 包含实际监听与额外接入端口的规范化集合。导入兼容原生范围及 `mport` 两种格式。修改出口跳跃集合时替换旧 `mport`；关闭跳跃或生成普通端口转发链接时删除它，同时保留密码编码、TLS 指纹和其他查询参数。两处同时指定不同多端口集合时拒绝歧义输入。未修改服务端规则或内核配置渲染。

验证均通过 `ssh host-vps-scripts`，证据目录为 `/var/tmp/vpsctl-hy2-uri/evidence/`：

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 协议回归与新增 URI 用例 | PASS | `protocol-and-parser.log` |
| 独立标准 URL 解析器 | PASS；复现旧范围端口失败，接受双核各域名／IPv4／IPv6 共 6 条实际导出链接 | 同上，使用 Python `urllib.parse`；未把它当作 GUI 实测 |
| 节点编辑、分享、切核 | PASS | `node.log` |
| 出口编辑、跳跃开关与 TLS 信任保留 | PASS | `relay-tls.log` |
| 普通转发、分享与回滚 | PASS | `forward.log` |
| 六份受影响脚本语法 | PASS | 远端 `bash -n` |
| 六份受影响脚本 ShellCheck 错误级 | PASS，逐文件全部退出 0 | `static-per-file.log`；首次批量检查被终止，退出 137，随后逐文件完成 |

本轮未直接操作用户的客户端 GUI，也未重复与 URI 变更无关的内核和网络矩阵；`mport` 仍取决于客户端版本支持。用户例子中的 `127.17.12.41` 属于回环地址，如果不是脱敏内容，连接前还应改为服务器实际公网地址。
