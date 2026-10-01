# iperf3 验收记录

日期：2026-10-01。所有项目测试、语法、静态检查及真实功能验收均经 `ssh host-vps-scripts` 在 Debian 13 专用宿主执行；Alpine 3.24.1/OpenRC 使用该宿主上的 QEMU TCG 独立写时复制镜像。本机仅编辑、同步文件和审阅差异。

## 候选版本

源码基线为 `e69b9ddefb9cf22c16d7fc8a26185361aefddf3f` 加本次工作区改动。本次功能尚未单独发布 Release，保持既有 manifest schema 2。最终服务模块 SHA-256：`0d303bd45707ab62777caa7ca1d8a0c30f9321c97c3b00bac9fe8ea9ae416c4e`。

单元测试 SHA-256：`9bfc017a9d5be348c024010931753b1ad7bea7d3070c4fdef22c2804c1e6a409`。真实验收脚本 SHA-256：`1987f8504d121e320cd358a761f2016390c720b59a73e056761d916c3347476c`。

证据根目录：专用宿主 `/var/tmp/vpsctl-iperf3-20261001.86ZzO5`，候选源码位于其 `repo` 子目录。原始主机输出、包清单和测速 JSON 仅保留远端，不提交到仓库。

## 已执行检查

| 范围 | 结果与证据 |
| --- | --- |
| 新模块和新增测试的静态检查 | **PASS**：`bash -n`、`shellcheck -x -P SCRIPTDIR -S warning`、`shfmt -d -i 4 -ci`。最后的退出码修正后已复验。 |
| 受影响共享代码与入口 | **PASS**：六个生产文件的语法、`shellcheck -x`、shfmt 检查。已有测试文件的聚合默认 ShellCheck 存在原有夹具/来源解析诊断，本次未修改无关测试约定；新增测试按上述参数通过。 |
| iperf3 单元验收 | **PASS**：参数、默认端口、只读/演练、依赖授权和默认原生服务抑制；仅 TCP 监听的正常空闲状态；幂等；TCP、UDP、已连接 UDP 端口冲突；启动/自启失败恢复；业务提交前后 TERM；启用意图×实际运行×实际自启的八种更新组合；软件包失败 20、非系统程序更新前置失败 3；卸载保留程序。 |
| 相关回归 | **PASS**：`test-libraries.sh`、`test-command.sh`、`test-ufw-library.sh`、`test-network-ufw.sh`、`test-distribution.sh`、`test-release-build.sh`、`test-vpsctl.sh`。涵盖登记、菜单数量、包映射、UFW owner/存量采集/锁、只读能力例外和功能缓存。日志为根目录下 `*.integration.log`。 |
| Debian/systemd 真实服务 | **PASS**：首次安装、实际服务及自启、幂等、占用保护、换端口、停止/重启、日志、卸载和保留软件包。IPv4/IPv6 各六项 TCP 正反向、单连接/多连接、UDP 正反向测试均传输了数据。原始十二项结果在 `debian-real`，后续生命周期结果在 `debian-lifecycle`。 |
| 普通用户权限 | **PASS**：非 root 的真实 start 返回 4；既有共享状态目录不可读时 status 返回 4 并提示 root，没有误报未安装。日志为 `unprivileged-start.log`、`unprivileged-status.log`。 |
| 软件包真实更新 | **PASS**：Debian APT、Alpine APK 更新路径均执行成功，当前软件源已是最新版本。Debian 未部署受管服务时更新没有创建服务；Alpine 运行时更新后服务恢复。未强制降级再跨版本升级，二进制跨版本替换不在此次实测范围。 |
| Alpine 首装、后启防火墙与重启 | **PASS**：首次安装 iperf3 3.20-r0，OpenRC 启动并加入 default runlevel；原生 iperf3 服务保持停止。UFW 停用时先保存需求，随后 `network ufw enable` 自动补齐 TCP/UDP、IPv4/IPv6 规则。虚拟机真实重启前后 boot ID 不同，重启后服务和反向测速恢复。日志为 `alpine-first-start.log`、`alpine-late-ufw.log`、`alpine-update-before-reboot.log`、`alpine-after-reboot.log`。 |
| Alpine 隔离对端与活动 UFW | **PASS**：可选网络命名空间、活动 UFW 分支全部完成；本机与独立对端均完成 IPv4/IPv6 TCP 正反向、单连接/多连接和 UDP 正反向测试。确认 TCP/UDP/已连接 UDP 占用保护、换端口后的真实接入、手工 TCP 规则保留、共享 owner 保留与最后引用释放、stop 后全局 sync 不重新放行，以及重启/卸载清理。完整输出见 `alpine-live-acceptance.log` 与 `alpine-results/acceptance.log`。 |
| 安装态与功能缓存 | **PASS**：`VPSCTL_TEST_IPERF3_UNINSTALL=1 bash tests/integration/test-distribution-real.sh`。已安装 CLI 离线卸载只删除本功能缓存；再次 help 只重新下载 iperf3 包，并与卸载前文件哈希一致；原管理器安装恢复至原 `0.1.0`。日志为 `distribution-real.log`。 |

第一次 Debian 验收在十二项测速通过后，因测试错误地要求“未安装 UFW 时也记录 IPv6 UFW 需求”而中断；测试已按共享 UFW 的 IPv6 配置能力修正。后续生命周期复用了仍有效的测速结果。另一次单元测试把 UFW 正常递增的 revision 当成幂等失败，已改为检查服务文件与有效防火墙需求；真正失败回滚仍比较完整 UFW 状态。

## 重现方式

以下命令在 `ssh host-vps-scripts` 的候选目录运行；真实测试要求没有预先存在的本功能实例，并自行清理本次创建的服务。默认套件没有执行，其他功能的真实全套验收未运行。

```bash
bash tests/unit/test-service-iperf3.sh
VPSCTL_REAL_IPERF3_TEST=1 bash tests/integration/test-service-iperf3-real.sh
VPSCTL_TEST_IPERF3_UNINSTALL=1 bash tests/integration/test-distribution-real.sh
```

Alpine 可选分支在同一专用宿主内的隔离 guest 执行，需先启用 UFW 并确保 SSH 可达：

```bash
VPSCTL_REAL_IPERF3_TEST=1 \
VPSCTL_IPERF3_NETNS=1 VPSCTL_IPERF3_LIVE_UFW=1 \
VPSCTL_IPERF3_RESULT_DIR=/root/iperf3-acceptance \
bash /root/iperf3-candidate/tests/integration/test-service-iperf3-real.sh
```

## 恢复与未覆盖范围

Debian 上的受管服务、状态、专属日志和自身 UFW 需求均已清理。保留按方案安装的 `iperf3`/`libiperf0` 3.18-2+deb13u2 与 `libsctp1` 1.0.21+dfsg-1，原生 iperf3 服务为 inactive/disabled。systemd 可能暂留已删除 unit 的 failed 缓存项，不存在运行中的受管进程。包差异及恢复信息见 `packages-added.txt`、`debian-recovery.txt`。

Alpine 验收使用本次新建 overlay，基础 RAW 和既有 TCPing overlay 不作为可写磁盘。软件包和活动 UFW 改动仅在本次 guest 中；结果归档到宿主 `alpine-results`，guest 已关闭，overlay 经 `qemu-img check` 确认无错。本次服务、临时网络命名空间、veth、手工规则和共享 owner 测试需求均由验收脚本清理。

未重启 Debian 宿主；真实重启证据来自 Alpine。没有进行外部公网或云安全组验收，也没有运行长时间带宽压测。其他包管理器的映射与调用属于定向测试/代码覆盖，不构成相应发行版的真实安装声明。
