# iperf3 测速服务端

`vpsctl service iperf3` 管理单实例 iperf3 服务，供其他机器测试 TCP/UDP 吞吐量。支持 Linux、Bash 4.4+、systemd 和带 `supervise-daemon` 的 OpenRC。软件来自当前系统软件源，不编译、不添加第三方仓库。

## 使用

```bash
vpsctl service iperf3
vpsctl --install-deps service iperf3 start
vpsctl service iperf3 status
vpsctl service iperf3 start --port 25201
vpsctl service iperf3 restart
vpsctl service iperf3 logs
vpsctl service iperf3 update
vpsctl service iperf3 stop
vpsctl service iperf3 start
vpsctl --yes service iperf3 uninstall
```

无参数且连接交互终端时显示编号菜单；非交互时只显示帮助。首次 `start` 默认使用 5201，后续沿用保存端口；`--port` 接受 1–65535 的整数。同端口且服务正常时不重启进程。`start --port` 更改端口，失败时恢复原配置、服务和 UFW 需求，不终止占用端口的其他程序。

`start` 和 `restart` 启用开机启动；`restart` 要求已有受管服务与配置。`stop` 停止并取消自启、释放本模块的端口需求，保留配置和软件包。再次 `start` 恢复服务与自启。

`status` 分别显示软件版本、受管服务部署状态、实际运行和自启状态、保存端口及实际 TCP 监听。安装系统软件包不等于已部署受管服务；普通用户可读状态时可查询，受保护目录无法读取时提示使用 root。帮助和无附加参数的状态查询不要求服务管理器，不安装依赖。`logs` 输出 systemd journal 或 OpenRC 专属日志的最近 50 行。

支持全局 `--dry-run`、`--install-deps`、`--yes`、`--non-interactive`、`--quiet`、`--verbose`、`--no-color`，放在 `service` 前；直接执行入口时放在动作前。真实变更需要 root，缺少工具时一次性确认安装全部缺失依赖；自动化添加 `--install-deps`。演练只显示计划，缺依赖时不会安装或修改服务。

## 测速方式

在另一台机器上运行以下命令，将 `SERVER_ADDRESS` 替换为服务端地址，端口替换为实际配置：

```bash
# 客户端发送，服务端接收
iperf3 -c SERVER_ADDRESS -p 25201
# 服务端发送，客户端接收
iperf3 -c SERVER_ADDRESS -p 25201 -R
# UDP 测试，明确设置发送速率
iperf3 -c SERVER_ADDRESS -p 25201 -u -b 10M
```

服务使用原生 iperf3 的 TCP 控制连接，UDP 数据 socket 通常在测试开始后才创建。空闲时只看到 TCP 监听是正常现象。启动时检查受管进程与 TCP 监听；实际 UDP 通路需通过 UDP 测试确认。支持可用的 IPv4/IPv6，客户端可用 `-4` 或 `-6` 指定地址族。

测速产生真实网络流量并占用带宽。本功能只管理服务端、显示客户端示例，不主动测速，也不更改 BBR、MTU、缓冲区等参数。启动成功只确认本机监听，不代表云安全组、上游 NAT 或公网路径已放行。参考 [iperf3 官方手册](https://software.es.net/iperf/invoking.html)。

## 软件包与后台服务

安装使用现有共享包管理能力；apt、dnf5、dnf、yum、apk、pacman 安装 `iperf3`，zypper 安装提供 iperf3 的 `iperf`。已有可用程序可直接用于启动。首次安装时 Debian/Ubuntu 非交互预置 `iperf3/start_daemon=false`；新安装软件包附带的默认服务保持停止和不自启，已有原生服务不自动接管。

受管服务名为 `vpsctl-iperf3`，由 systemd/OpenRC 管理前台进程，不使用 `iperf3 -D`。服务定义使用程序的绝对路径，不依赖当前 release，因此管理器更新或普通 `self uninstall` 不会停止该服务。

`update` 只升级当前系统包管理器拥有的 iperf3 软件包，拒绝将独立安装的程序当作系统软件包更新。原受管服务运行时重启加载新版；停止时保持停止，自启设置和保存的启用意图均保留。不会执行系统整体升级。软件包更新遵循包管理器结果，不提供旧软件包版本的自动回滚；服务重启失败会尝试恢复原服务状态并报告失败。

## 防火墙与运行数据

scope/owner 均为 `iperf3`，申请所选端口的 TCP、UDP、IPv4 和可用 IPv6 需求。复用共享 UFW 事务，`preserve_existing:true` 保留已有等价手工规则；停止和卸载不删除其他功能仍在使用的规则。

UFW 未安装或未启用时只记录需求，不安装或开启 UFW。后续 `network ufw sync` 或启用 UFW 会读取持久配置；尊重已解除的联动和现有规则冲突。外部手工停止进程不改变保存的启用意图，需要关闭服务、自启与端口需求时使用 `stop`。

| 路径 / 服务 | 用途 |
| --- | --- |
| `/var/lib/vpsctl/service/iperf3/state.json` | `schema_version:1`、整数 `port`、布尔 `enabled`；全局 UFW 同步契约 |
| `/etc/systemd/system/vpsctl-iperf3.service` | systemd 服务定义，日志使用 journal |
| `/etc/init.d/vpsctl-iperf3` | OpenRC 服务定义 |
| `/run/vpsctl/iperf3.pid` | OpenRC 下原生 iperf3 进程 PID |
| `/run/vpsctl-iperf3.pid` | OpenRC 监督进程 PID |
| `/var/log/vpsctl/iperf3.log` | OpenRC 专属日志 |

`service-iperf3` 为独立按需功能包，依赖 `shared-command` 和 `shared-ufw`。功能帮助也会下载尚未缓存的功能包；浏览全局菜单、帮助和清单不会下载。未新增分发格式或迁移要求。

## 卸载与失败恢复

`uninstall` 确认一次；非交互使用 `--yes`。先停止并取消自启，释放本模块 UFW 需求，再删除受管服务定义、状态、专属 PID/日志及当前受管 release 的自身功能缓存。下次进入会重新下载功能包。源码运行不删除仓库源码。

系统 iperf3 软件包、共享依赖和库、系统 journal、其他服务及手工规则均保留。只删除固定受管资源，遇到非受管同名服务、符号链接或异常文件类型时报告错误。多步卸载的清理失败返回 30，保留可重试路径；不会为恢复已清理资源而重新安装。

端口或服务变更失败、中断时恢复之前的配置、服务和防火墙需求；恢复不完整时保留临时备份并显示位置。退出码：0 成功，2 参数，3 前置条件，4 权限，10 配置，20 外部操作失败，30 部分完成，130 用户中断。

实际验证范围见 [验收记录](iperf3-validation.md)。
