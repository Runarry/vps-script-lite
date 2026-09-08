# UFW 真实环境验收记录

本文记录 `vpsctl network ufw` 在专用 `host-vps-scripts` 上的破坏性真实验收。记录不包含主机地址、登录凭据、私钥、真实备份 ID 或临时端口。

## 验收代码与环境

- 验收日期：2026-09-08（Asia/Singapore）。
- 操作系统：Debian GNU/Linux 13（trixie），x86_64，systemd。
- 验收源码目录：`/var/tmp/vpsctl-ufw.medWtkjB/source`；该目录不是 Git checkout。
- 冻结产品代码 SHA-256：`4d10e50d1ad934b93be629986d336352452268b793d100bdec25ce7e2ae5fb0e`。口径包含 `bin/`、`lib/`、`commands/`、`scripts/`、`vpsctl.sh` 和 `VERSION`，不包含 tests/docs；逐文件清单保存在 `/var/tmp/vpsctl-ufw.medWtkjB/product-code.sha256`。
- 完整验收开始时的源码树 fingerprint：`134b930707b3ade6349e0cce5e04a05e8b79463231553e2f06df50f07cdb0df2`。这是 runner 对当时整个源码副本逐文件计算的指纹。
- `test-network-ufw-real.sh` SHA-256：`6c16ca9775bdd990815bafb4e0438549ec5008270d5433dcbd5f45d1e57db399`。
- `test-ufw-linkage-real.sh` SHA-256：`5ab719eacb83dff46b99aec0a4ca05bb58bd4c6afb083b9b984c82cf90df7262`。
- `test-ufw-forward-runtime-real.sh` SHA-256：`afbfd441d3966d27f74493893d4d63f2f983d5b0a3340aeba1d05428c1d99034`。
- 初始 UFW 包状态：未安装，dpkg 无已安装状态；初始 UFW 为停用状态。
- 初始 SSH 有效端口：22；验收从真实 SSH 会话运行。
- 初始 nftables、iptables 与 ip6tables 规则集为空；nft 基线 SHA-256 为 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`。
- `/etc/ufw/applications.d/openssh-server` 为其他包拥有的既有文件，内容 SHA-256 为 `f363c320cecc0474122f81e1563ea28f9e7ebc5913ac049de4d6e01f8e9917d0`，必须保留。
- Debian 13 以外的平台：**NOT RUN**。RHEL 系、Arch、Alpine、openSUSE、OpenRC 及非 Linux 环境没有真实结论。

所有项目语法、静态、单元、集成和真实功能检查均通过 `ssh host-vps-scripts` 执行。Windows checkout 只用于读取、编辑和检查差异，没有运行项目代码。

## 真实验收结果

| 验收项 | 结果 | 实测证据 |
| --- | --- | --- |
| 安装与初始状态 | **PASS** | 从 Debian 软件源安装 UFW；新安装保持 inactive，服务持久化入口可用。 |
| 安全启用 | **PASS** | 启用前同时登记 sshd 有效端口与当前 SSH 会话端口；原会话在 UFW 启用后持续可用。 |
| 规则 CRUD 与顺序 | **PASS** | 公开 CLI 完成 add、指定位置 insert、按稳定 ID edit、按 ID/编号 delete；编辑后语义和顺序符合预期。 |
| 高级配置 | **PASS** | `app list/info/default/update`、incoming/routed 默认策略和 logging high/off/low 均由公开 CLI 写入并由 UFW 状态或配置验证；仍有 IPv6 服务引用时 `ipv6 off` 返回 3。 |
| INPUT 数据面 | **PASS** | 默认 incoming deny 阻断无 owner 的 IPv4/IPv6 TCP/UDP；双栈 TCP/UDP allow 规则允许 network namespace 的真实报文和响应。 |
| 停用与重新启用 | **PASS** | disable 后规则需求仍记录；enable 重新协调 SSH 与业务需求。 |
| 规则归属 | **PASS** | 精确接管等价人工规则；两个 owner 共享同一规则；有引用时禁止 edit/delete；detach、attach 和最后一个 owner 释放行为正确。 |
| 停用期协调 | **PASS** | UFW inactive 时只记录代理需求，不写活动规则；重新启用后补齐对应 owner。 |
| 跨地址族事务回滚 | **PASS** | 注入第二地址族 apply 失败后，第一地址族规则、UFW 文件、活动规则和共享 state 均恢复到操作前。 |
| SSH abort | **PASS** | `prepare --firewall auto` 同时保留旧端口和候选端口；abort 释放候选 owner。 |
| SSH commit 与 restore | **PASS** | 第二 SSH 会话完成 transaction proof；commit 后释放旧端口；restore 通过真实 PTY 输入备份 ID 的强确认完成，最终回到原端口和 owner。测试先从 TSV state 读取并校验非空备份 ID，未使用 `--yes` 绕过确认。 |
| 代理节点业务联动 | **PASS** | 通过公开 `service proxy node add/delete` 创建公网 Shadowsocks 节点，真实核心建立 TCP/UDP 监听并生成 IPv4/IPv6 四条 owner 规则；公开删除后监听和 owner 消失。127.0.0.1 节点真实监听但不生成公网规则。 |
| routed deny 与 DNAT | **PASS** | default routed deny 阻断无关 IPv4/IPv6 TCP/UDP 转发；测试自有 nft DNAT 配合 UFW route owner 后，四类报文均真实到达目标 namespace 并收到响应。 |
| DNS 目标替换 | **PASS** | 修改测试控制的 hostname 解析并刷新 cache 后，旧 IPv4/IPv6 destination 规则删除，新 destination 规则建立，四类 DNAT 数据面再次通过。该项使用生产 relay cache/render/UFW 函数组合；完整后台 helper 事务单列记录。 |
| 生产后台 refresh | **PASS** | 安装真实 runtime 依赖与 helper watch；`systemctl reload` 通过已安装 helper 完成生产 UFW、DNS cache 与 nft 目标换址；注入一次 cache 目标 `mv` 失败返回 20，cache、nft、UFW rules/state 和 pending journal 全部回滚。 |
| TLS HTTP-01 成功 | **PASS** | 本地 fake lego 通过 ready/release 握手停在挑战期；inventory 出现 80/TCP 的 `tls:*` owner，link requirement 为 `temporary:true`；成功后物理 80 规则恢复到基线。 |
| TLS 既有 80 规则 | **PASS** | 预先建立带稳定 ID/comment 的 IPv4/IPv6 人工 80 规则；HTTP-01 借用后归还，ID、comment、语义和无 owner 状态保持。 |
| TLS 失败与 TERM | **PASS** | fake lego 失败返回后释放租约；公开入口在独立进程组收到 TERM，顶层 CLI 返回 130，实际 TLS 子命令执行清理 trap，随后轮询确认物理 80 规则和临时 requirement 均释放。 |
| TLS DNS-01 | **PASS** | 使用测试凭据文件和 fake lego 完成 DNS-01，整个握手期间没有 80/TCP owner 或 temporary requirement。没有调用真实 ACME 或 DNS 服务。 |
| 普通卸载/重装 | **PASS** | 普通 uninstall 保留配置和联动 state；重新 install 保持 inactive；enable 后 SSH owner 仍存在。 |
| purge/干净重装 | **PASS** | `uninstall --purge` 使用 APT purge 清理 dpkg conffile 状态和 vpsctl state；随后公开 install 能重新创建 UFW 配置且保持 inactive；再次 purge 成功。 |
| 最终恢复 | **PASS** | package、UFW 路径、sysctl、netfilter 和 SSH 均恢复；测试节点、namespace、veth、nft 表、监听进程、fake lego、TLS state/timer、hosts 修改全部清理；外部 OpenSSH application profile 保留。 |

## 执行命令与证据

最终破坏性验收命令：

```bash
ssh -tt host-vps-scripts env \
  VPSCTL_REAL_UFW_TEST=1 \
  VPSCTL_UFW_RESULT_DIR=/var/tmp/vpsctl-ufw.medWtkjB/results \
  bash /var/tmp/vpsctl-ufw.medWtkjB/source/tests/integration/test-network-ufw-real.sh
```

命令退出码为 0。主日志：`/var/tmp/vpsctl-ufw.medWtkjB/results/network-ufw-real.log`，SHA-256 为 `6041fbacebeb494f2afef6d6756faab31701339d9d57d9c7abeb2ec43f584b4d`。日志包含每个真实场景的独立 `PASS:` 行及最终两行：

```text
PASS: network UFW real acceptance
PASS: package, UFW paths, sysctls, and netfilter baseline restored
```

TLS fake 的参数和命令日志保存在同一结果目录：`tls-http-success.*`、`tls-http-existing.*`、`tls-failure.*`、`tls-term.*`、`tls-dns-success.*`。这些文件不包含真实凭据。

后台 runtime 真实验收使用 `VPSCTL_UFW_FORWARD_RUNTIME_REAL=1` 运行 `tests/integration/test-ufw-forward-runtime-real.sh`，命令退出码为 0。日志 `/var/tmp/vpsctl-ufw.medWtkjB/runtime-acceptance/runtime-real-run4.log` 的 SHA-256 为 `2381c2cbb360ed1de8c149674a679c7a578c7ef35c6c4b412db88cfee88735a7`。独立恢复核对 `/var/tmp/vpsctl-ufw.medWtkjB/runtime-acceptance/post-restore.txt` 的 SHA-256 为 `08388794ca39dc00e664602ed3f61060bcf1de1b15b5921cb154daac0ab285dd`；runtime 所用关键应用文件指纹清单 SHA-256 为 `41f6353967d4bfb52acd900f354c8eda8c13b1083f9451c4a35238c1091a5364`。

最终三份 runner 在远端分别执行：

```bash
bash -n tests/integration/test-network-ufw-real.sh
bash -n tests/integration/test-ufw-linkage-real.sh
bash -n tests/integration/test-ufw-forward-runtime-real.sh
shellcheck -x tests/integration/test-network-ufw-real.sh
shellcheck -x tests/integration/test-ufw-linkage-real.sh
shellcheck -x tests/integration/test-ufw-forward-runtime-real.sh
```

六项均退出 0。支持性回归已在同一远端代码树运行；其中分发真实安装验收日志为 `/var/tmp/vpsctl-ufw.medWtkjB/distribution-real.log`，包含安装态与断网缓存态的 `network ufw --help` 加载检查。APT remove/purge/reinstall 与安装失败回滚的隔离证据分别保存在 `cli-apt-lifecycle.log` 和 `cli-install-retry.log`。含旧 fixture 失败的历史合并日志不作为最终 PASS 依据。

## 缺陷与修正记录

验收过程中真实复现了 Debian 包生命周期缺陷：普通 remove 后手工删除 UFW conffile 会留下 dpkg 记录，使下一次 install 不重建 `/etc/default/ufw`。实现已改为 `--purge` 时调用 APT purge，并处理仅剩 dpkg conffile 状态的情形；最终真实 purge→install→purge 链路通过。

测试基础设施同时修正了三类问题：SSH transaction state 是 TSV，不能按 `key=value` 读取；restore 必须在 PTY 中输入备份 ID；公开 proxy node add 的 stdout 是分享 URI，节点 ID 应从公开 node list 读取。SSH 测试另保存受管 drop-in 应急副本，任何正常 restore 失败或信号退出都先尝试 PTY restore，再以已验证原端口的副本恢复并同步 UFW。

## 恢复记录

外层 runner 在第一次修改前捕获 UFW 包状态、`/etc/ufw`、`/etc/default/ufw`、`/var/lib/ufw`、vpsctl UFW state、相关 sysctl、iptables/ip6tables save 和完整 nft ruleset。cleanup 仅删除带唯一测试名的资源，停用并清理测试安装的 UFW，恢复文件和 sysctl，然后逐项比较基线。

主 runner 和后台 runtime runner 的内外层 cleanup 均报告 PASS。独立 post-restore 再次确认 UFW package/command 不存在，SSH 有效端口为 22，nft/iptables/ip6tables 为空，原代理服务恢复 active/enabled，IPv4/IPv6 forwarding 恢复原值，完整 UFW paths 归档与捕获值逐字节一致，外部 OpenSSH application profile 内容 SHA 不变。若 cleanup 任一步失败，runner 返回非零并保留 root-only 证据，不会把未恢复环境报告为通过。
