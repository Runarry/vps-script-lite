# PO0 独立中转验收记录

日期：2026-10-21。所有脚本执行、语法、静态检查和功能验证均通过 `ssh host-vps-scripts` 完成，本机只编辑文件和审阅差异。

## 环境与源码

专用机为 Debian 13，Linux 7.1.13、Bash 5.2.37、nftables 1.1.3、ShellCheck 0.10.0、shfmt 3.8.0。本记录不代表 Ubuntu 22.04 / 24.04 实测。

2026-10-21 验收版本的 `scripts/po0-relay.sh` SHA-256：`203cab6f07c06dd6f12ed21ada088a598a520d55bf7bea92dc52141455740b47`。

远端证据目录：`/var/tmp/po0-relay-accept-20261021/`。`final-code-state.sha256` 记录脚本、两个测试及测试入口的摘要。功能验收后的应用差异仅为说明有意行为的 ShellCheck 注释，见 `final-annotations.diff`；功能结果继续有效，最终文件另通过静态检查。

## 结果

| 检查 | 结果与范围 |
| --- | --- |
| Bash 语法 | PASS：独立脚本、两个新测试及 `tests/run.sh`。实际生成的 `recover.sh` 也通过语法检查。 |
| ShellCheck / shfmt | PASS：独立脚本和两个新测试的完整默认级别 ShellCheck、`shfmt -d -i 4 -ci`。局部抑制说明了 nft 变量字面量、布尔校验和菜单子 Shell 隔离等有意行为。 |
| 旧版兼容 | PASS：原模板单线路、多线路及中文／含空格名称导入，网卡与 SNAT 地址保留，重复读取无重复记录，TSV 往返一致。模板外内容、未知版本、重复 ID 被拒绝。 |
| 菜单 | PASS：真实提示和动作函数的新增、逐字段默认值、非法输入重试、协议最后选择、启停、删除、取消和默认拒绝确认。真实 PTY 下列表和退出不修改旧配置，不创建状态。复制到仓库之外仍可显示帮助，非 TTY 菜单立即拒绝。 |
| 端口与 SSH | PASS：协议交集和区间边界冲突，真实 TCP／UDP 监听占用，本机其他地址和回环目标拒绝；SSH TCP 保护不妨碍同号 UDP。替身验证 sshd、具名 SSH socket 的端口会被保护，而无关 systemd socket 不会被额外放行。 |
| 真实转发 | PASS：四个网络命名空间模拟客户端、PO0、两台目标机，共 32 次 TCP／UDP 探测。验证不同目标地址和端口、同入口 TCP／UDP 分别去不同目标、区间首尾、旧 SNAT 地址 `192.0.2.1`、编辑不影响另一条线路，以及停用／启用／删除。 |
| 首次部署与接管 | PASS：空状态首次应用；原有 nft 模板运行规则直接迁移为新版持久化状态，并承接真实流量。 |
| 失败恢复 | PASS：在新规则和磁盘状态均已写入后，注入 nftables 服务启用失败；运行规则、状态、nft 配置、sysctl 文件及服务启用状态恢复，原流量仍可用。注入位置有单独快照，未用前置检查失败代替回滚测试。 |
| 持久化与隔离 | PASS：生成的配置连续两次 `nft -f` 加载后转发有效，独立的外部 nft 表保持原样；宿主机规则前后比较一致。 |

主要日志：`unit-final-2.log`、`real-final.log`、`static-final.log`、`recovery-syntax-final.log`、`cleanup-final.log`。详细迁移、候选、回滚和前后快照位于 `real-final/`。

## 执行方法与边界

在专用机的本次源码副本中执行：

```bash
cd /var/tmp/po0-relay-accept-20261021/repo
bash tests/unit/test-po0-relay.sh
PO0_REAL_TEST=1 PO0_RESULT_DIR=/var/tmp/po0-relay-accept-20261021/real-final \
    timeout 180 bash tests/integration/test-po0-relay-real.sh
```

以上命令必须通过 `ssh host-vps-scripts` 使用。重复验收时给 `PO0_RESULT_DIR` 指定一个新的目录，避免复用旧的阶段标记。

集成测试中的 `nft`、网络接口、路由、连接、`ss` 和转发参数均为真实内核操作，位于独立网络命名空间；文件路径指向本次测试目录。服务启用操作使用有状态替身，以免改变宿主机服务状态。因此没有执行实际 systemd 启用、机器重启、软件包安装、手动运行恢复脚本或信号中断注入；持久化结论限定为生成配置的真实重复加载，恢复脚本完成语法检查和代码审阅。自动失败回滚已真实执行。

测试退出时清理网络命名空间及其中的进程，保留证据文件。没有运行无关全仓库测试，也没有修改 vpsctl 功能注册或发布版本。

## 2026-10-28：增加开启 BBR＋FQ

新增菜单 8，以及状态页的 TCP 拥塞控制／默认队列显示。开启操作使用独立的 sysctl 和模块配置文件，与线路状态、nft 规则和转发参数分开保存。仅设置默认队列，不替换运行中的网卡队列。

所有检查仍通过 `ssh host-vps-scripts` 执行。证据目录为 `/var/tmp/po0-bbr-accept-20261028/`，包含 `commands.txt`、`code-state.sha256`、`unit.log`、`static.log`、`real.log` 和 `real/` 中的前后快照。

| 检查 | 结果 |
| --- | --- |
| 原 PO0 单元测试与新增 BBR 用例 | PASS：取消零写入、不支持 BBR／FQ、第二个 sysctl 设置失败、第二个持久化文件写入失败、原文件及权限恢复、按需加载模块、只读状态和重复开启不写入。 |
| Bash / ShellCheck / shfmt | PASS：独立脚本和修改后的单元测试。最终帮助文案修正后，脚本再次通过 `bash -n`、完整 ShellCheck 和 `shfmt -d -i 4 -ci`。 |
| 真实开启与连接 | PASS：在专用机将拥塞控制临时设为 reno，再调用实际开启函数恢复为 bbr；默认队列核对为 fq；新建并连接的 TCP 客户端、服务端 socket 均报告使用 bbr。 |
| 配置持久化与重复执行 | PASS：生成 sysctl／模块文件，`sysctl -p` 加载生成配置后参数正确；再次开启无需输入，文件 inode、时间和内容不变。 |
| 恢复与影响范围 | PASS：退出时恢复原 bbr/fq；网卡实际 qdisc、nft 规则和原生产配置文件前后完全一致。 |

关键命令为专用机源码副本中的 `bash tests/unit/test-po0-relay.sh` 和证据目录中的 `bash real-check.sh`；真实功能调用仅覆盖持久化文件、锁及备份路径，sysctl、模块探测、TCP 连接均使用真实系统。

功能验收版本 SHA-256 为 `0108f49dbd677b91286a4b73cca22da0cc97c7b0c4dbf95163e1f358353a664d`；其后只修正帮助中线路备份与 BBR 备份的描述，交付版本为 `991a5b075c77abe362c6e113f0a6bb5afaa4ad878eab1ff1a784932abc3d6188`，功能结果复用。

本轮未重启机器，未在真实缺失 BBR／FQ 的内核上测试，也未重复运行未改变的 nft 真实转发套件。不支持内核及失败恢复通过定向替身验证；测试机默认队列原本就是 fq，真实检查验证其设置和重载，没有声称观察到实际网卡队列切换。

## 2026-10-28：URI 中转与分组菜单

新增 URI 导入、完整中转 URI 展示、公网 IPv4 设置、按需 DNS 刷新和状态 v2；主菜单整理为线路管理、状态与维护、全局设置三个分组。继续单文件交付，URI 处理仅使用内嵌 Python 标准库。原 BBR 改动保留。

所有检查通过 `ssh host-vps-scripts` 执行。环境为 Debian 13、Bash 5.2.37、Python 3.13.5、nftables 1.1.3、ShellCheck 0.10.0；未声称 Ubuntu 实测。证据根目录为 `/var/tmp/po0-uri-accept-20261028/`，源码副本为其中的 `repo/`。

| 检查 | 结果与证据 |
| --- | --- |
| URI 格式与语义 | PASS：VLESS、VMess Base64 JSON、Trojan、SS SIP002／整体 Base64／明文与 SS2022 凭据、HY2／Hysteria2、TUIC、AnyTLS。验证地址与端口替换，凭据、中文备注、未知参数、显式及隐式 SNI／Host 保留；覆盖 HY2 原生多端口、编码 mport、缺省 443、冲突集合拒绝。见 `tester/unit-final.log`。 |
| 状态与编辑 | PASS：v1 读取与写入升级、v2 往返、重复／孤立／未知记录拒绝；补录 URI、修改目标同步模板、DNS 刷新失败零提交、取消不落盘、默认保留 URI 时不查 DNS。 |
| 真实终端 | PASS：PTY 下执行新增 → 查看 → 编辑 → 查看 → 退出，完整分享 URI 可见，编辑后的目标端口持久化；另覆盖旧配置只读查看、菜单分组、每项一行、真实 TTY 下 NO_COLOR／TERM=dumb。见 `tester/unit-final/pty-uri.log`；共 38 条单元验收 PASS 摘要。 |
| 公网探测与 DNS | PASS：真实 HTTPS 公网 IPv4 探测及系统 DNS 解析，见 `parent/network.log`。定向 I/O 替身另覆盖失败手填、重新探测、优先保留当前 IPv4、无解析结果及只读查看不联网。 |
| 依赖与只读兼容 | PASS：缺少 Python 时普通线路和 URI 线路基本信息仍可查看，查看不安装依赖；URI 错误诊断不输出凭据。 |
| 真实转发 | PASS：网络命名空间中使用真实新增动作导入 URI，读取导出端点后完成 TCP／UDP 通信，覆盖区间起始与末端；原单端口、启停、编辑、删除、SNAT、配置重载检查继续通过。见 `tester/real.log` 和 `tester/real/`。 |
| 回滚与隔离 | PASS：在规则及状态已经写入后注入服务启用失败，URI、公网 IPv4、其他状态和运行规则均恢复；无关 nft 表与宿主机规则保持原样。 |
| Bash／ShellCheck／shfmt | PASS：独立脚本和两个受影响测试的语法、完整 ShellCheck、`shfmt -d -i 4 -ci`。见 `parent/static.log`、`tester/test-shellcheck-final.log` 和 `tester/test-shfmt-final.log`；通过时静态工具可能无输出。 |

主要执行命令（均在专用机源码副本中运行）：

```bash
bash -n scripts/po0-relay.sh tests/unit/test-po0-relay.sh tests/integration/test-po0-relay-real.sh
shellcheck scripts/po0-relay.sh tests/unit/test-po0-relay.sh tests/integration/test-po0-relay-real.sh
shfmt -d -i 4 -ci scripts/po0-relay.sh tests/unit/test-po0-relay.sh tests/integration/test-po0-relay-real.sh
PO0_UNIT_TMP=/var/tmp/po0-uri-accept-20261028/tester/unit-final bash tests/unit/test-po0-relay.sh
PO0_REAL_TEST=1 PO0_RESULT_DIR=/var/tmp/po0-uri-accept-20261028/tester/real \
    timeout 100 bash tests/integration/test-po0-relay-real.sh
```

最终脚本 SHA-256 为 `e35e98f6a822269e6a306d9a98fbe0d493b1e058b9f1a087ccd97d9b01ed4148`，与本地交付文件一致，见 `tester/unit-final-state.sha256`。真实转发验收使用的脚本为 `d5db21fb437d9d69db2fb674622b6253332f732c4f335b9e01bc92ac3985aac1`；之后仅调整提示颜色、格式，以及 URI 编辑中非法输入重试和回车保留的交互分支。后续差异保存在 `parent/post-integration.diff`，由最终单元与 PTY 检查覆盖；nft 渲染、应用和回滚逻辑未再改变，复用真实转发结果。

真实转发使用内核网络操作及临时配置文件，systemd 启用仍使用有状态替身；PTY 操作使用隔离状态与提交替身。测试结束清理网络命名空间及进程，保留证据。未运行全仓库测试、机器重启、真实依赖安装或所有代理协议的完整握手；协议参数保留由 URI 语义断言验证，真实网络验收限定为 nft TCP／UDP 转发。未重复执行已验证且未改变的 BBR 内核调优验收。
