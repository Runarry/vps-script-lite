# PO0 独立中转验收记录

日期：2026-10-21。所有脚本执行、语法、静态检查和功能验证均通过 `ssh host-vps-scripts` 完成，本机只编辑文件和审阅差异。

## 环境与源码

专用机为 Debian 13，Linux 7.1.13、Bash 5.2.37、nftables 1.1.3、ShellCheck 0.10.0、shfmt 3.8.0。本记录不代表 Ubuntu 22.04 / 24.04 实测。

最终 `scripts/po0-relay.sh` SHA-256：`203cab6f07c06dd6f12ed21ada088a598a520d55bf7bea92dc52141455740b47`。

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
