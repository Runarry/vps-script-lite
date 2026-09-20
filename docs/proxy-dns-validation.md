# sing-box DNS 验收记录

验收日期：2026-09-20。代码基于提交 `5d6669274a8e9e79a35245c6a5c3fec4a868895d` 的 DNS 功能工作树。全部项目代码、语法检查、单元测试和真实功能验收都通过 `ssh host-vps-scripts` 在专用 Debian 13 x86_64 环境执行；工作站只用于编辑、读取差异和传输文件。

## 环境与结果

真实内核为 sing-box `1.14.0`；兼容矩阵同时使用 Xray `26.9.9`。测试未替换已安装内核、系统 DNS 或持久服务配置。

| 检查 | 结果 |
| --- | --- |
| `bash tests/unit/test-service-proxy-dns.sh` | PASS：4 组 DNS 默认值、六种模式、CLI、清单状态、版本边界、事务/回滚、pending、卸载保留与 purge |
| `bash tests/integration/test-service-proxy-dns-real.sh` | PASS：系统兼容、UDP、TCP、DoT、DoH、域名上游 bootstrap、四种地址族策略、REALITY 开关、中转服务器域名和负向路径 |
| Cloudflare DoH 预设 | PASS：项目生成的 `1.1.1.1:443`、TLS 名称 `cloudflare-dns.com` 和 `/dns-query` 配置通过真实查询并访问 `example.com` |
| resolved 回归 | PASS：普通 libc DNS 成功时，原生模式真实复现 `link has no DNS servers configured`；兼容模式恢复合法 REALITY 握手 |
| REALITY 防偷 `on` / `off` | PASS：两种状态分别完成真实客户端握手和 HTTPS 请求；`on` 的原生系统 DNS 对照按预期失败 |
| DNS 负向测试 | PASS：错误 TLS 名称和不可达 TCP 上游均无法解析，且 sing-box 进程保持运行 |
| `test-service-proxy-relay-cores-real.sh` | PASS：sing-box 1.14.0 / Xray 26.9.9 的 38 个配置、14 次切核和 10 个 IP 策略配置 |
| 代理主单元与相关回归 | PASS：`test-service-proxy.sh`、版本兼容、relay TLS、协议增强、relay 增强、节点增强、proxy UFW、release build 和主管理入口集成 |
| 新脚本静态检查 | PASS：Bash 语法、Python `py_compile` 和 ShellCheck error 级别 |

未执行整个 `tests/run.sh` 的无关系统功能；本次完整执行了代理主单元、DNS 单元、相关代理回归、真实内核配置矩阵和新增真实 DNS 验收。

## resolved 故障复现

真实验收在私有 network/mount namespace 中创建默认 dummy 接口，并把 namespace 内的 `/etc/resolv.conf` 指向受控 UDP DNS。`getent ahostsv4 dns-target.test` 先成功返回 `127.0.0.1`，证明普通系统 DNS 可用。独立 D-Bus 仅在私有 bus 上提供 `org.freedesktop.resolve1`，`GetLink` 返回的 `DNS` 与 `DNSEx` 均为空。

项目生成的 `system-native` 配置使用 `local` 且不设置 `prefer_go`。真实 sing-box 查询和启用防偷的 REALITY 合法握手都失败，服务端日志包含精确错误 `link has no DNS servers configured`。同一环境改用默认 `system` 后，生成配置包含 `prefer_go:true`，REALITY 防偷开启和关闭的客户端均完成握手，并通过服务端访问受控 HTTPS 目标。该对照隔离了修复字段，没有依赖外部 DNS 或修改宿主机 resolved 状态。

## 解析器与路由覆盖

受控 Python 夹具使用标准库同时提供 UDP、TCP、DoT、DoH 和双栈 HTTPS 目标。每种模式都由 `proxy_dns_render` 生成 DNS 与 `route.default_domain_resolver`，通过真实 sing-box SOCKS 请求解析目标域名；夹具日志确认查询到达预期传输。

域名上游 `dns-upstream.test` 由 `proxy-dns-bootstrap` 通过 `127.0.0.53:53` 解析，随后 DoH 查询到达域名上游。IP 上游配置不产生 bootstrap。`prefer_ipv4`、`prefer_ipv6`、`ipv4_only`、`ipv6_only` 分别由显式 `domain_resolver.strategy` 驱动，夹具记录真实请求只到达预期的 IPv4 或 IPv6 目标。

中转域名用项目的 URI 解析与 `proxy_relay_render_outbound` 生成，真实 Shadowsocks 客户端通过全局 `proxy-dns` 解析服务器域名并完成 HTTPS 请求。更广的协议渲染、切核和中转状态行为由本次已运行的代理主单元及 real-cores 验收覆盖；新增脚本只增加 DNS 特有的真实链路。

DoT/DoH 使用测试 CA、正确 TLS 名称和自定义高位端口。错误名称必须产生证书/TLS 失败；未监听的 TCP 上游必须产生连接拒绝或超时。两项均检查请求失败且内核仍存活，不接受明文或其他解析器回退。

## 复验命令

以下命令均在专用机代码副本 `/root/vpsctl-dns.vnvzrG/source` 中执行。D-Bus Python 绑定只解压到证据目录，没有安装到系统；若专用机已安装 `python3-dbus` 与 `python3-gi`，可省略三个环境路径。

```bash
cd /root/vpsctl-dns.vnvzrG/source

dep=/root/vpsctl-dns.vnvzrG/python-dbus/root
export PYTHONPATH="$dep/usr/lib/python3/dist-packages"
export LD_LIBRARY_PATH="$dep/usr/lib/x86_64-linux-gnu"
export GI_TYPELIB_PATH="$dep/usr/lib/x86_64-linux-gnu/girepository-1.0"
export SING_BOX_BINARY=/usr/local/bin/sing-box
export DNS_EVIDENCE_ROOT=/root/vpsctl-dns.vnvzrG

bash tests/unit/test-service-proxy-dns.sh
bash tests/integration/test-service-proxy-dns-real.sh
```

只复验确定性 namespace 用例时可设置 `RUN_PUBLIC_DNS_TEST=0`。设置 `KEEP_TEST_TEMP=1` 会保留受控配置和详细日志；默认成功后删除临时目录。

## 证据与恢复

主要记录：

- `/root/vpsctl-dns.vnvzrG/dns-unit-4.log`
- `/root/vpsctl-dns.vnvzrG/dns-real.log`
- `/root/vpsctl-dns.vnvzrG/dns-real-isolated.log`
- `/root/vpsctl-dns.vnvzrG/real-cores-dns.log`
- `/root/vpsctl-dns.vnvzrG/existing-guard.log`
- `/root/vpsctl-dns.vnvzrG/test-service-proxy-version-compat.sh.log`
- `/root/vpsctl-dns.vnvzrG/vpsctl-dns-bootstrap.CIViRZ/`
- `/root/vpsctl-dns.vnvzrG/vpsctl-dns-public.33SheP/`

真实脚本的 dummy 接口、默认路由、`/etc/resolv.conf` bind mount、端口 `53`/`443` 和全部受控服务都位于私有 namespace。退出 trap 停止 sing-box、DNS、D-Bus 和 resolved 夹具并卸载 namespace 内的 resolv.conf；namespace 退出后接口、路由和监听自动销毁。成功运行返回 `0`，宿主机 `systemd-resolved` 保持未运行，原 `/etc/resolv.conf` 与已有代理、nginx、Docker 和 SSH 服务未改动。下载的 `.deb` 仅解压在 `/root/vpsctl-dns.vnvzrG/python-dbus/`；删除该验收目录即可清理全部临时依赖和保留日志。
