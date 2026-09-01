# 服务器测试

0.6.0 提供 `test nodequality` 与 `test tcpquality` 两个公开入口。它们是第三方官方测试脚本的受控启动器，不是本项目维护的测试算法，也不固定远端内容版本。每次真实执行都会从代码中登记的官方 HTTPS 地址重新下载脚本到本次调用的临时目录，再以前台子进程运行。

## 1. 风险与共同边界

两项命令的注册元数据均为 `disruptive`、`root`、`unsupported` 演练、`linux,root` 能力要求和 `experimental` 生命周期。运行前必须了解以下边界：

- 必须在 Linux 上以 root 执行。仅 `help`、`-h` 或 `--help` 可由非 root 用户调用；该例外只移除 `root`，不会绕过 Linux 能力检查，也不会下载远端脚本。
- 测试可能长时间占用 CPU、内存和磁盘，产生大量外网流量并影响同机业务延迟、吞吐或流量额度。应避开业务高峰，确认剩余磁盘、内存、流量配额和供应商使用政策，并在独占或可中断的维护窗口运行。
- 远端脚本是运行时下载的当前上游版本。本项目固定来源 URL，但不固定提交、版本或校验和；运行行为、依赖、探测目标和报告格式可能在本项目未变更时由上游调整。
- 两个上游都可能将测试结果上传到其报告服务并输出可分享 URL。报告可能包含公网 IP、硬件、网络线路、路由、运营商或地域等主机信息；不要在不能接受第三方处理这些信息的服务器上运行，也不要公开含敏感信息的报告链接。
- `--dry-run` 明确不受支持。`vpsctl --dry-run test nodequality` 和 `vpsctl --dry-run test tcpquality` 会在任何下载或上游执行前拒绝，不提供“只展示计划”的替代语义。
- 公开接口不透传上游参数；除单个帮助参数外，多余参数一律拒绝。`--non-interactive` 也不构成本版本的自动化兼容承诺。

本项目入口负责终端输入与信号转发，以及本次调用临时资源的清理。运行前会比较 `/var/tmp` 与 `/tmp` 的可用空间，在其中安全、可写且空间更大的目录创建 `vpsctl-server-test.<name>.XXXXXX`；这是为了避免常见的小容量 tmpfs `/tmp` 无法容纳上游 rootfs。清理范围只包括当前运行创建且仍可安全识别的下载文件和目录。它不扫描或删除其他调用、上游历史运行、用户文件，也不承诺替上游回收其在包装器临时目录之外创建的所有挂载、依赖或缓存。正常返回以及可捕获的 `HUP`、`INT`、`TERM` 和 `EXIT` 路径会尝试清理；`SIGKILL` 无法捕获，入口 Shell 崩溃、内核故障、主机掉电或文件系统异常也可能跳过清理。异常结束后应先确认没有残留测试进程或挂载，再人工检查临时空间，不能盲目删除不属于本次运行的路径。

## 2. `test nodequality`

官方项目与启动地址：

- 项目：[LloydAsp/NodeQuality](https://github.com/LloydAsp/NodeQuality)
- 启动脚本：[`https://run.NodeQuality.com`](https://run.NodeQuality.com)

用法：

```text
bash bin/vpsctl test nodequality
bash bin/vpsctl test nodequality help
```

无参数执行保留 NodeQuality 上游的四项交互选择，由用户决定是否运行基础信息、IP 质量、网络质量和回程路由测试。本项目不预答这些问题，也不把选择提升为稳定的 CLI 参数。NodeQuality 使用临时 BenchOS/chroot 环境组合多个测试，并在完成后整理和上传报告；所选项目越多，耗时、资源占用与外网流量通常越高。

NodeQuality 上游在完成其正常工作与清理后可能返回状态 `1`。为避免把该已知上游结尾行为误报为本项目失败，入口仅对 NodeQuality 子进程状态 `1` 规范化为成功 `0`；状态 `0` 保持为 `0`，其他非零状态原样返回。由于上游也可能用 `1` 表示内部问题，调用者仍必须查看完整终端输出并确认预期测试结果或报告链接存在，不能只凭规范化后的退出码判定报告完整。

## 3. `test tcpquality`

官方项目与下载地址：

- 项目：[ibsgss/TcpQuality](https://github.com/ibsgss/TcpQuality)
- GitHub Raw 启动脚本：[`runTcpQuality.sh`](https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh)

用法：

```text
bash bin/vpsctl test tcpquality
bash bin/vpsctl test tcpquality --help
```

无参数执行不会显示本项目的二次配置向导，也不把上游参数提升为本项目接口；如果当前官方脚本显示自己的测试选项，则原样保留并由用户直接选择。该测试会并发访问多个探测目标，并可能生成和上传报告；必须在可以接受网络负载、探测流量和结果披露的环境中运行。入口原样返回 TcpQuality 子进程退出状态。

## 4. 退出与恢复

共同基础退出码沿用项目约定：参数错误为 `2`，平台或命令不可用为 `3`，真实执行缺少 root 为 `4`，下载失败或上游执行失败使用入口或上游返回的其他非零状态，被 `vpsctl` 的中断处理终止通常为 `130`。NodeQuality 的状态 `1` 规范化是上节所述唯一命令特例。

失败或中断后不要立即重跑。先确认测试子进程已经退出、系统负载恢复、没有意外残留的挂载或临时数据，再检查网络配额和上游输出。若异常发生在报告上传阶段，远端可能已经收到部分或完整数据，即使本地没有打印报告链接；本地清理不能撤回已经上传的报告。
