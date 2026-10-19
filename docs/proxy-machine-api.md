# 代理机器接口（schemaVersion 1）

供本机可信 SubMeld Agent 使用；以 root 执行，不支持 `--dry-run`。快照包含节点凭据和原生出口 URI，只能经可信通道传递。读取不会初始化节点、出口或配置文件。需要现有 jq、sha256sum、flock、base64；证书公钥指纹使用已有 openssl。

```text
vpsctl --non-interactive service proxy machine snapshot
vpsctl --non-interactive service proxy machine apply < command.json
vpsctl --non-interactive service proxy machine result --id REQUEST_UUID
```

`snapshot` 输出一个 JSON：`schemaVersion`、`revision`、`vpsctlVersion`、`capabilities.actions`、`capabilities.profiles[{id,label,cores}]`、`cores`、`nodes`、`relay{exits,bindings,forwards}`、`exports`、`pendingCores`。原生节点、核心和中转记录保持原字段。`nativeManifest` 保留整个 nodes.json，包括 DNS 和未来原生字段。`configurationHashes` 提供核心元数据、生成配置、pending 和恢复事务文件的摘要。revision 为这些配置和证书公钥指纹的稳定 SHA-256，不含实时服务探测、日志或机器请求回执。

`exports` 沿用原生 URI 导出函数：节点 ID 与原生 ID 一致，协议端口转发按每个端口输出 `FORWARD_ID:PORT`。每项包含 `id,name,core,kind,uri`；节点证书可读取时增加 `tlsSpkiSha256`（Base64 公钥 SHA-256）和 `certificateSha256`（十六进制整证书 SHA-256），不读取私钥文件内容。直连地址出口没有协议 URI，完整配置仍在 relay 中；不会伪造订阅节点。任何原生节点导出失败都会使整个快照失败，避免报告不完整清单。

`apply` 从 stdin 读取单个 JSON：

```json
{
  "schemaVersion": 1,
  "requestId": "11111111-1111-4111-8111-111111111111",
  "expectedRevision": "替换为最近快照的64位小写十六进制revision",
  "action": "node.add",
  "params": {
    "profile": "shadowsocks-aes-256-gcm",
    "core": "sing-box",
    "name": "edge",
    "port": 23456,
    "address": "proxy.example"
  }
}
```

支持 `core.install/update/start/stop/restart/uninstall`、`node.add/edit/delete/switch/ip-policy`、`dns.set/reset`、`exit.add/edit/delete`、`binding.add/delete`、`forward.add/edit/delete/refresh` 和 `time.sync`。`node.switch` 映射 `node core set`，`node.ip-policy` 映射 `node ip-policy set`；中转操作映射原生 `relay` 子命令。`tunnel.*` 由 Agent 独立管理，不进入该接口。

params 使用原 CLI 去掉 `--` 的键。值选项使用字符串或数值；无值标志使用布尔值（false 不传入）；仅 `node.ip-policy` 的 `id` 接受字符串数组，展开为重复 `--id`。每个 action 独立允许选项，未知选项、NUL、嵌套对象或数组误用被拒绝。参数以 Bash 数组传递，不执行任意 shell。原生选项、协议限制和参数验证保持原样。

已授权远程操作自动使用普通确认；node、binding、forward 删除传入普通 `--confirm-delete`。危险操作仍需调用方显式选择 `confirm-purge`、`confirm-disruptive`（切核）、`confirm-external-update`、`cascade`、`confirm-cascade` 等原生命令要求的标志。

所有变更 action 的 params 都接受独立布尔参数 `install-deps`。设为 true 时，仅为该次原生变更子进程设置 `VPSCTL_INSTALL_DEPS=1`，允许原有依赖安装器安装缺少的系统工具；仍执行原有包管理器和安装结果校验。false 或省略不增加授权，字符串、数值或数组均被拒绝。该参数不会作为 `--install-deps` 拼入 action 的普通选项，也不会修改外层环境。直接 CLI 已提供的全局 `--install-deps` 授权继续有效；机器接口本身需要的 jq 等读取依赖应在 Agent 安装阶段准备。

快照、CAS 和变更使用同一把 `proxy.lock`，先持锁再比较 expectedRevision；原生变更子 shell 借用父锁，保留原回滚、pending、退出清理和其他领域锁（例如 time.sync 的 proxy-time 锁）。持锁冲突返回原生退出码 3，不产生请求回执。机器接口不会释放父锁后另行调用 CLI，因此 CAS 不存在检查与变更间的窗口。

回执保存于 `/var/lib/vpsctl/service/proxy/machine-requests/UUID.json`（目录 0700、文件 0600）。只保存规范 JSON 的 payload SHA-256 和脱敏结果，不保存输入、完整快照或原生日志。同 ID 同 payload 返回原回执；同 ID 不同 payload 返回 conflict，保留原回执。变更前先原子写入 unknown，正常结束再原子替换结果；进程中断后保持 unknown，永不自动重做。原生返回部分失败或失败时保留 exitCode，不能当作 applied。

结果字段为 `schemaVersion,requestId,status,exitCode,message,revision`，状态为 `applied/pending_restart/conflict/failed/unknown`。原生非零退出优先报告 failed；成功时仅检查本次操作涉及核心的 pending：核心操作按所选 core/all，节点操作按实际节点核心（切核包含两端），DNS 默认 sing-box，关联和已绑定出口修改按相关入口节点核心。判断使用操作前后快照，删除后的记录仍按操作前引用解析。纯 forward、time.sync、未绑定出口和仅重命名出口没有代理核心生效依赖，成功报告 applied，不受其他核心待重启影响，也不会自动重启无关核心。snapshot.pendingCores 仍完整展示所有待重启核心。message 为固定脱敏说明，详细恢复信息需由管理员在本机原生状态中检查。已经生成合法结果时进程退出 0，业务结果以 status 和 exitCode 为准；参数 envelope、依赖、权限、锁或快照构建错误可能非零退出且不产生结果 JSON。

`result` 查询未记录的 ID 时额外返回 `found:false`、status unknown、exitCode 30、进程退出 0。Agent 只能将 **found 严格等于 false** 当作“尚未执行，可首次提交”；已存在的 unknown 回执绝不能重做。查回执不依赖当前配置能够完整导出。回执不会因核心卸载而删除；需要新尝试时必须使用新 requestId 和最新 revision。

定向验收只在 `ssh host-vps-scripts` 的临时源码目录执行 `bash tests/unit/test-service-proxy-machine.sh`。测试复用隔离系统根目录与原生核心夹具，不修改宿主真实代理服务。
