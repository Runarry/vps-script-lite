# REALITY 防偷验收记录

验收日期：2026-09-08。全部项目代码执行、语法检查、静态检查及真实功能验收均通过 `ssh host-vps-scripts` 完成；工作站只编辑、读取仓库和传输代码。

## 环境与结果

使用独立代码副本与临时配置，真实内核为 sing-box `1.14.0`、Xray `26.3.27`。未替换专用机已安装内核或持久服务配置。

| 检查 | 结果 |
| --- | --- |
| `bash tests/run.sh` | PASS：全部语法、单元与主管理入口集成测试，包括新增 REALITY 防偷用例 |
| `bash tests/integration/test-service-proxy-reality-anti-relay-real.sh` | PASS：六个 profile/core 组合的配置与正确 SNI 回落；双核错误 SNI、包含白名单域名、无 SNI、非 TLS、不完整握手拒绝；回环监听、规则隔离及 SNI 修改 |
| REALITY 真实协议链路，防护 `on` | 5 PASS，1 个已知上游 XFAIL |
| 相同链路，防护 `off` | 5 PASS，相同上游 XFAIL |
| VLESS Vision，默认 `www.amd.com`，防护 `on` | sing-box、Xray 均 PASS |
| `bash tests/integration/test-service-proxy-relay-cores-real.sh` | PASS：36 个配置组合、12 个切核场景、10 个节点 IP 策略配置 |
| ShellCheck | 与统一 Linux 换行后的修改前基线比较，无新增诊断；排除既有 SC2015、SC2034、SC2119、SC2120 后通过 |
| Python TLS 目标夹具 `py_compile` | PASS |

`shfmt -d -i 4 -ci` 在修改前基线和当前代理脚本中均报告原有格式风格差异；本次保持周边风格，没有整文件格式化。它未作为本次功能验收通过项。

唯一 XFAIL 是 Xray `trojan-grpc-reality` 在 REALITY 认证后被 gRPC 传输关闭连接。防护开关两组都符合现有 `server-preface` 关闭日志特征；继续使用显式 `ALLOW_XRAY_TROJAN_GRPC_REALITY_XFAIL=1`，未增加新的豁免或泛化失败条件。

## 防护与状态覆盖

新增单元用例验证新增默认开启、显式关闭、旧清单兼容、编辑省略保留、参数与 SNI 校验、大小写域名归一化、转义 NUL 拒绝、状态输出和 dry-run。还覆盖双核主辅端口、系统监听、端口转发、关闭及删除后复用、切核和失败回滚。开关前后分享 URI 与凭据保持不变。

真实负向测试使用受控 TLS 目标记录每次 TCP 到达。每类拒绝请求前后目标记录数必须保持不变，内核进程必须仍存活；负向组结束后再次验证正确 SNI 成功。最终成功运行记录 57 次目标到达，拒绝用例均未增加记录。修改 SNI 后旧域名被拒绝，新域名仍能回落，内部端口及 REALITY 密钥保持不变。

防护仅限制可进入回落路径的 SNI，白名单伪装站仍可访问，不用于限制合法凭据滥用或解密后的 HTTP 内容。

## 复验与恢复

以下命令均在专用机的代码副本中运行：

```bash
bash tests/run.sh
bash tests/integration/test-service-proxy-reality-anti-relay-real.sh
CONNECTIVITY_PROFILE=reality CONNECTIVITY_REALITY_GUARD=on ALLOW_XRAY_TROJAN_GRPC_REALITY_XFAIL=1 bash tests/integration/test-service-proxy-relay-connectivity-real.sh
CONNECTIVITY_PROFILE=reality CONNECTIVITY_REALITY_GUARD=off ALLOW_XRAY_TROJAN_GRPC_REALITY_XFAIL=1 bash tests/integration/test-service-proxy-relay-connectivity-real.sh
CONNECTIVITY_PROFILE=vless-reality-vision CONNECTIVITY_SNI=www.amd.com bash tests/integration/test-service-proxy-relay-connectivity-real.sh
bash tests/integration/test-service-proxy-relay-cores-real.sh
```

受控目标脚本使用回环 `443` 和临时 hosts 名称，执行前检查端口、备份 `/etc/hosts`，退出时停止测试进程并恢复、逐字节核对 hosts。失败时保留临时目录和备份。已另外验证缺失内核返回 `3`，内核夹具中途失败返回 `1`；后者执行前后的 hosts SHA-256 一致。

远端验收目录为 `/root/vpsctl-reality-guard.RbfkQ8`，保留 `full-suite.log`、`guard-real.log`、`guard-blocked.log`、`guard-cleanup-failure.log`、`connectivity-on.log`、`connectivity-off.log`、`connectivity-default-sni.log`、`real-cores.log` 及静态诊断基线。日志和测试凭据不提交仓库。
