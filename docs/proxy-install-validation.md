# 代理内核首次安装自动启动验收

验收日期：2026-09-27。项目执行、语法检查和静态检查均在专用 `host-vps-scripts` Debian 13 / systemd 环境完成；工作站只用于查看、编辑和打包源文件。

## 验收范围

本次独立真实验收针对首次安装的新行为：空节点状态下执行 `install --core all` 后，sing-box 与 Xray 应立即启动并启用开机启动，状态校验成功后保存 LKG。随后人工停止并禁用两个服务，再次执行同一安装命令，应把已经登记的内核视为无变化，并保留人工设置的停止、禁用状态。

真实环境复用了机器现有的普通可执行文件，因此两核元数据均为 `owned=false`。这仍使用真实 sing-box 1.14.0、Xray 26.3.27 进程和真实 systemd 单元，不使用服务 mock；官方下载、`owned=true`、systemd/OpenRC 故障注入、文件与服务状态回滚、LKG 保存失败及 `--core all` 部分失败由新增单元矩阵覆盖，本次真实验收未重复下载或替换约 116 MB 的现有二进制。

## 代码与环境

基础提交为 `0d38992d29564810b2d7b0fa021c6589368dd303`，从干净 `HEAD` 归档后只覆盖候选 `commands/service/proxy/core.sh`、`commands/service/proxy.sh` 和真实验收脚本。远端一次性候选位于：

```text
/var/tmp/vpsctl-lazy-autostart.sj4HrXmQ/proxy-real/candidate.5da1fG/source
```

候选源指纹为 `c821538e9446e0aa51104e4c95fb99dcf1dd673cf93bb4741039dd5a5fb90dad`。直接相关文件的远端 SHA-256：

```text
dda4e8d1299d9edbb74e59172a64a0fbc21cf65259b987d32720719319fae5e6  commands/service/proxy/core.sh
3e6cff157e293870d8823aad8ec1e719fc523c93e5cce6c21a080ca443cf4a30  commands/service/proxy.sh
641fb7c428c97ed0f74f4319216b0d320ee584f8b58e5948266540f970cb611a  tests/integration/test-service-proxy-install-real.sh
```

主机原有 `/usr/local/bin/sing-box` 和 `/usr/local/bin/xray` 均为普通可执行文件。测试前记录并在清理后恢复了以下状态：Xray `active/enabled`、sing-box `inactive/disabled`、中转刷新服务 `vpsctl-proxy-forward.service` 为 `active/enabled`。

## 结果

| 检查 | 结果 |
| --- | --- |
| 候选脚本 `bash -n` | PASS：使用 `xargs -0 -n 1 bash -n` 逐文件检查，全部 shell 文件通过远端语法检查 |
| 新真实验收脚本 ShellCheck | PASS：`shellcheck -S warning` 无诊断 |
| 空节点 `install --core all` | PASS：创建空节点清单，两份配置均没有入站；两个真实进程均有有效 `MainPID`，其 `/proc/PID/exe` 指向预期二进制 |
| systemd 运行与开机状态 | PASS：sing-box 与 Xray 均为 `active/enabled`，加载项目生成的 `/etc/systemd/system/vpsctl-proxy-*.service` |
| 外部所有权与 LKG | PASS：两核元数据均为 `owned=false`，元数据摘要与现有可执行文件一致；LKG 的配置、节点、元数据及二进制摘要均与安装结果一致 |
| 已登记内核重复安装 | PASS：人工停止、禁用两核后再次 `install --core all`，两核均报告无需更改，继续保持 `inactive/disabled`，受管文件和二进制指纹未变化 |
| 主机恢复 | PASS：原配置、状态、备份、日志、单元文件和两个二进制的审计指纹逐项一致；三个相关服务的 active/enabled 状态逐项一致；没有遗留 `vpsctl-proxy.*` 临时目录 |

第一次执行在进入应用逻辑前因一次性归档中的 `bin/vpsctl` 带 CRLF 而失败。该次退出恢复检查同样 PASS。只在远端一次性候选目录中规范化 shell 文件行尾并重新通过语法、ShellCheck 后复验；没有为此修改应用代码。成功复验退出码为 0。

## 复验命令

以下命令在 `host-vps-scripts` 上执行：

```bash
cd /var/tmp/vpsctl-lazy-autostart.sj4HrXmQ/proxy-real/candidate.5da1fG/source
find . -type f \( -name '*.sh' -o -path './bin/vpsctl' \) -print0 |
    sort -z | xargs -0 -n 1 bash -n
shellcheck -S warning tests/integration/test-service-proxy-install-real.sh

VPSCTL_REAL_PROXY_INSTALL_TEST=1 \
VPSCTL_PROXY_INSTALL_RESULT_DIR=/var/tmp/vpsctl-lazy-autostart.sj4HrXmQ/proxy-real/results \
bash tests/integration/test-service-proxy-install-real.sh
```

成功证据目录为：

```text
/var/tmp/vpsctl-lazy-autostart.sj4HrXmQ/proxy-real/results/run.ZwzfqV
```

主要记录包括 `logs/proxy-install-real.log`、`logs/first-install.log`、`logs/repeated-install.log`、`candidate-before-noop.tsv`、`candidate-after-noop.tsv`、`baseline/paths.before.tsv`、`baseline/paths.restored.tsv`、`baseline/unit-states.before.tsv` 和 `baseline/unit-states.restored.tsv`。后两组基线文件已用 `cmp` 再次确认完全一致。首次 CRLF staging 失败及成功恢复的证据保存在相邻的 `run.AOlpGX`；这些记录不包含配置正文、凭据或原始 IP。
