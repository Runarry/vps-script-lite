# 系统清理

`system clean` 查看并清理 vpsctl 脚本残留、按需功能包、软件包缓存、过期临时文件和归档 journal。系统菜单中追加为第 4 项“系统清理”，保留内核、重装和 Swap 的编号。独立 `system-clean` bundle 只包含 `commands/system/clean.sh`，仅依赖 `shared-command`。

登记风险为 `change`：真实执行会永久删除对应缓存、过期临时文件或归档日志，不保留这些内容的备份。生命周期为 `experimental`，权限为 `optional-root`；帮助、状态和演练可由普通用户执行，真实清理要求 root。

## 接口与确认

```text
vpsctl system clean
vpsctl system clean status
vpsctl system clean safe
vpsctl system clean vpsctl
vpsctl system clean bundles
vpsctl system clean packages
vpsctl system clean temp
vpsctl system clean journal
vpsctl system clean help

vpsctl --dry-run system clean safe
vpsctl --dry-run system clean bundles
vpsctl --dry-run system clean journal
vpsctl --yes --non-interactive system clean safe
```

也可独立运行 `bash commands/system/clean.sh`。通过主管理器调用时，全局参数放在 `system` 前；独立调用时放在子动作前。支持 `--dry-run`、`--yes`、`--non-interactive`、`--install-deps`、`--quiet`、`--verbose` 和 `--no-color`，帮助同时接受 `help` 与 `--help`。

| 动作 | 范围 |
| --- | --- |
| 无参数 | 交互 TTY 中进入编号菜单；无 TTY 或使用 `--non-interactive` 时显示状态 |
| `status` | 只读显示各清理项目的可用性、候选或占用情况；受权限或工具限制时大小可显示为不可用 |
| `safe` | 一次组合 `vpsctl`、`packages`、`temp`；不包含 `bundles` 和 `journal` |
| `vpsctl` | 仅清理受管安装中可验证归属的脚本残留 |
| `bundles` | 清理当前受管版本可重新下载的已登记功能包，保留 core、共享库和系统清理自身 |
| `packages` | 调用当前软件包管理器的原生缓存清理接口 |
| `temp` | 按系统现有时效规则清理 `/tmp` 与 `/var/tmp`，排除 vpsctl 工作路径 |
| `journal` | 清理超过 30 天的归档 journal，保留活动日志 |

每次操作在列出范围后只做一次普通确认，默认拒绝；`safe` 的子项不重复确认。直接 CLI 可用全局 `--yes` 授权，无人值守使用 `--yes --non-interactive`。非交互未授权返回 `3`，交互取消返回 `130`。菜单采用编号选择，封闭选项无需输入内部动作名。

`--dry-run` 只读取状态、列出候选和待执行命令，不创建锁、目录或临时文件，不执行软件包清理、tmpfiles 清理或 journal vacuum，也不安装依赖。候选占用大小不等于实际可释放空间；无法只读估算时明确显示不可用，不以真实清理试算。

安装态首次调用仍遵循管理器原有的按需下载流程，可能先缓存本功能及共享依赖；上述零变更保证指功能开始后的清理演练。部分候选无法安全清理时，演练保留非零退出码。

依赖只按当前动作处理。真实非交互安装缺失的可安装依赖须显式传入 `--install-deps`；该参数不改变清理范围，也不把缺少的平台能力视为受支持。状态与演练不安装工具。

## 脚本残留与功能包

`vpsctl` 与 `bundles` 只支持受管 Release 安装，不清理源码树。源码模式仍可运行 `packages`、`temp` 和 `journal`；`safe` 报告并跳过不可用的脚本残留子项，显式调用不支持的动作返回 `3`。

脚本残留限以下可识别对象：

- `/usr/local/lib/vpsctl/releases/` 下受管标记有效、且不是当前版本的旧 release。
- 旧版本遗留的 `/var/lib/vpsctl/self/vpsctl.sh` 普通文件。
- 当前 release 的 `.bundles/` 中已登记包的已遗弃下载工作目录和临时缓存标记。

清理遵守 self 更新和功能包下载的现有互斥边界；被占用对象保留并报告。候选必须通过归属、路径和文件类型核验，不把名字相近、归属未知、符号链接或异常文件类型当作可删内容。`.update`、staging 等更新恢复材料和未知条目保留，不能以“残留”为由删除。

`bundles` 只移除注册表固定列出的非 self 功能文件及对应缓存标记，排除 `system-clean`。core、`shared-command`、`shared-ufw` 和 `shared-server-test` 均保留。已安装的服务和外部工具继续运行；下次调用被清功能时，按原有 manifest、版本和 SHA-256 校验重新下载，所以离线时应保留仍需使用的功能缓存。它不卸载功能安装的软件包，也不调用其他功能脚本的卸载入口。

## 系统缓存与日志

`packages` 使用环境检测到的软件包管理器，调用固定原生命令：

| 软件包管理器 | 清理命令 |
| --- | --- |
| APT | `apt-get clean` |
| DNF5 / DNF / YUM | `dnf5 clean packages` / `dnf clean packages` / `yum clean packages` |
| APK | `apk --no-network cache clean`；未启用缓存时无需清理 |
| Pacman | `pacman -Sc --noconfirm` |
| Zypper | `zypper --non-interactive clean` |

保留包管理器自身的互斥锁和错误处理，不删除锁文件或强行绕过占用。Pacman 不使用 `-Scc`。不执行 `autoremove`、内核卸载或软件包升级。

`temp` 要求可用且支持范围限制、有效配置读取的 `systemd-tmpfiles`，以及系统已有的 `awk`。它只运行 `--clean`，将范围限制为 `/tmp`、`/var/tmp`，沿用现有时效与排除规则。单次调用先读取有效配置，将可能覆盖 `/tmp/vpsctl*`、`/var/tmp/vpsctl*` 的清理规则转为保留规则，再通过标准输入执行；这样也能保护另有显式目录或通配子目录规则的 vpsctl 工作路径。变量、转义或通配范围无法排除交集时，保守保留该规则的匹配范围，可能额外保留部分临时文件；不会退回父目录更短的时效。规则读取或解析失败时不执行该项清理。

不会 `rm -rf /tmp`，不运行 `--remove`，不新建或修改持久 tmpfiles 配置，也不为本功能增加自定义保留期限。不支持时，`safe` 报告并跳过，显式 `temp` 返回 `3`。

`journal` 使用固定的 `journalctl --vacuum-time=30d`，只处理已归档文件，不先 rotate，不清空活动 journal，不修改 journald 的持久保留配置。无需或不支持 journal 的主机报告不可用；本功能不清理其他应用的任意日志文件。

所有动作保留 `/etc/vpsctl/`、功能状态、历史备份、证书、Swap、已安装外部二进制和运行时工具。也不清空 Linux 内存缓存，不清理 Docker 或用户 home，不新增清理 timer。

## 结果与恢复

清理结果逐项汇总成功、跳过和失败，并报告清理前后观测到的可用磁盘空间变化。该差值可能受其他进程、不同文件系统、压缩、稀疏文件和仍被进程打开的已删除文件影响，不承诺与候选大小一致；无法读取时明确报告不可用。重复清理不会累积配置或计划任务，已无候选的项目无需操作。

清理不是事务回滚操作：先前已完成的删除不会因后续子项失败而恢复。失败或中断后先查看逐项结果和保留路径，再运行 `status` 或演练检查尚未完成的对象。包管理器占用应等待现有操作结束；不要手工删除锁。功能缓存可在联网时通过再次调用该功能重新下载；需要旧 release 时重新安装指定发布版本。过期临时文件、已清缓存和归档日志没有内容恢复承诺。

退出码沿用项目约定：`0` 成功，`2` 参数错误，`3` 前置条件或显式动作不支持，`4` 权限不足，`10` 归属或配置错误，`20` 外部操作失败，`30` 部分完成，`130` 用户取消或中断。`safe` 中已说明的不支持子项按跳过报告；有实际失败或未完成清理时，应依据返回码与逐项说明处理。

## 验证

所有项目语法、静态、单元、分发和真实系统检查只能通过 `ssh host-vps-scripts` 执行，禁止在当前系统或 WSL 运行。默认 `tests/run.sh` 执行 `tests/unit/test-system-clean.sh` 和 `tests/unit/test-distribution-clean.sh`，并只对 `tests/integration/test-system-clean-real.sh` 做语法检查；真实验收需单独运行，不由默认套件触发。

定向验收应覆盖注册表与第 4 项菜单、首次下载及离线缓存、普通用户状态与演练、默认拒绝和一次确认、无人值守、零写入演练、包管理器精确参数、临时目录限制与排除、固定 journal 策略、源码模式、占用保留、归属未知对象保护，以及子项失败后的部分完成结果。真实验收应记录测试前配置、功能状态、备份、证书、Swap、运行工具与恢复材料的保留情况，并区分已真实执行的后端和仅以命令桩验证的后端；单台主机通过不代表全部发行版均已验收。

本次结果见[系统清理验收](system-clean-validation.md)。
