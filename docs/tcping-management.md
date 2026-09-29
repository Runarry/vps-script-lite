# TCPing 测试站点

`vpsctl service tcping` 提供一个单端口 TCP 监听服务，供其他机器检查本机 TCP 可达性。启动后在后台运行并启用开机启动；连接建立后立即关闭，不提供网页、代理、回显或逐连接日志。

## 使用

```bash
vpsctl service tcping
vpsctl --install-deps service tcping start --port 18080
vpsctl service tcping status
vpsctl service tcping start --port 18081
vpsctl service tcping stop
vpsctl service tcping start
vpsctl --yes service tcping uninstall
```

无参数且连接终端时显示编号菜单。首次启动必须输入 1–65535 的端口；后续 `start` 默认使用保存的端口。`start --port` 立即切换端口，同端口且服务已经就绪时不重启进程。非交互且无参数时只显示帮助。

在另一台机器上使用 TCPing 工具连接本机的 IP 和选定端口。服务监听 `0.0.0.0`，IPv6 可用时同时监听 `::`；IPv6 未提供时继续使用 IPv4，IPv6 端口被占用则报告冲突，不静默降级。启动失败或端口切换失败会恢复原配置、服务和 UFW 需求；不会终止占用该端口的其他程序。

`stop` 停止服务、取消开机启动并释放本模块的 UFW 需求，保留已下载脚本和端口配置。再次 `start` 会重新启用开机启动。`uninstall` 自动先停止服务，再清理资源。卸载菜单确认一次；非交互卸载使用全局 `--yes`。

支持 `--dry-run`、`--install-deps`、`--yes`、`--non-interactive`、`--quiet`、`--verbose`、`--no-color`，这些选项位于 `service` 之前；独立运行入口脚本时放在动作之前。演练不安装依赖、不改变服务、端口配置或防火墙，缺少依赖时显示安装计划。实际变更要求 root。输出为面向人的文本，不定义 JSON 输出接口。

## 平台与按需资源

支持 Linux、Bash 4.4+、systemd 或带 `supervise-daemon` 的 OpenRC。监听脚本仅使用 Python 3 标准库，不使用 pip 包；缺失的 Python 只在启动时通过共享依赖接口安装。UFW 协作使用现有 `jq`、`flock`、`sha256sum`；不把服务管理器作为可自动安装的普通依赖。实际已验证的平台和命令见 [验收记录](tcping-validation.md)。

`service-tcping` 是独立功能 bundle，包含入口和监听脚本，依赖 `shared-command` 与 `shared-ufw`。安装管理器、浏览全局菜单、全局帮助和清单不下载该功能；首次调用功能（包括功能帮助）时按当前 release 的 manifest 下载、校验和缓存。查看功能帮助、状态及菜单本身不安装系统软件包。缓存完整后可离线启动、停止和卸载。

部署后的监听脚本位于固定运行目录，不依赖当前 release 的代码位置，因此管理器更新、清理旧 release 或普通 `self uninstall` 不会停止已部署服务。需要删除此站点时，应先执行本功能的 `uninstall`。

## 防火墙与状态

复用共享 UFW 的所有权和事务机制，scope 与 owner 均为 `tcping`。需求设置 `preserve_existing:true`，借用已有等价手工规则，不取得其删除权；本模块新建的规则仍按共享引用管理。UFW 已启用时，启动申请 TCP 端口放行；切换端口先申请新端口，成功后释放旧端口。UFW 未安装或未启用时只记录需求，不安装或启用 UFW。后续 `network ufw sync` 或启用 UFW 会读取该需求。停止和卸载释放本模块需求，保留手工规则与其他功能仍在引用的规则；尊重已有解除联动设置及防火墙冲突检测。

云安全组、上游 NAT 和其他防火墙不由本模块修改，需自行放行所选端口。启动成功只确认本机服务已经监听，不代表公网链路已放行。

| 路径 / 服务 | 内容 |
| --- | --- |
| `/var/lib/vpsctl/service/tcping/state.json` | `schema_version: 1`、整数 `port`、布尔值 `enabled`；`enabled` 表示用户要求启动和开机启动，是 UFW 全局同步的业务契约 |
| `/usr/local/libexec/vpsctl/tcping/listener.py` | 受管监听脚本，运行时不生成 Python 字节码缓存 |
| `/run/vpsctl/tcping-ready.json` | 当前进程 PID、端口和实际监听地址族；成功绑定后才写入，正常退出时移除 |
| `vpsctl-tcping.service` / `/etc/init.d/vpsctl-tcping` | systemd / OpenRC 服务定义 |
| `/var/log/vpsctl/tcping.log` | OpenRC 启动或错误日志；systemd 使用系统 journal |

状态查询分别显示实际运行、自启状态及已保存端口。状态和父目录可读时可由普通用户查询；已有共享目录权限阻止读取时返回 `4` 并提示使用 root，不把无法读取误报为未安装，也不更改其他功能的目录权限。外部手工停止服务不会自动修改用户的持久启用意图；需要同时关闭服务、取消自启及撤销端口需求时使用 `stop`。

## 卸载与恢复

卸载确认服务停止后，删除服务定义、自启注册、监听脚本、状态、就绪文件及专属日志。然后删除当前受管 release 的 `service-tcping` 固定文件和缓存标记，下次进入功能会重新下载。源码运行只删除部署资源，不删除仓库源文件。

系统 Python、共享依赖、共享库、系统 journal、UFW 共用的历史元数据与其他功能资源保留。只清理已知的受管普通文件；同名非受管服务、符号链接或异常类型会拒绝操作并指出路径。

启动和换端口的中断处理会恢复原服务及文件；多步卸载已完成的清理不重新安装，失败时保留入口以便重试。配置或文件异常按错误提示修复后重试 `start`、`stop` 或 `uninstall`。恢复不完整时输出保留的临时备份目录并返回 `30`，不得将它视为成功。UFW 已提交但规则清理失败时保留服务对应需求，可运行 `network ufw sync` 后重试。

基础退出码：`0` 成功（含重复操作）、`2` 参数错误、`3` 前置条件或依赖不足、`4` 权限不足、`10` 配置无效、`20` 外部操作失败、`30` 部分完成、`130` 用户中断。维护责任随项目功能命令维护者。
