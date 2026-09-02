# TLS 证书管理

`security tls` 维护本机域名 TLS 证书：导入用户提供的证书与私钥，或通过 ACME 申请并续期公有 CA 证书。证书以稳定、无符号链接的 live 路径对外提供，供代理等功能按文件系统契约消费。本命令不调用其他公开功能脚本，也不改写 Nginx、Caddy 或代理配置。

本功能处于 `experimental` 生命周期，要求 Bash 4.4+ 与 Linux。导入、查看不依赖 systemd；续期 timer 仅支持 systemd。ACME 客户端为钉死版本的 lego，只支持 `x86_64`/`aarch64`。纯导入用户不会下载 lego。

## 接口

```text
vpsctl security tls status [--json]
vpsctl security tls list [--json]
vpsctl security tls show --id ID [--json]
vpsctl security tls paths --id ID

vpsctl security tls import --name NAME --cert-file FILE --key-file FILE
    [--chain-file FILE] [--reload none|proxy]
vpsctl security tls replace --id ID --cert-file FILE --key-file FILE
    [--chain-file FILE] [--reload none|proxy]
vpsctl security tls delete --id ID --confirm-delete

vpsctl security tls issue --domain DOMAIN [--domain DOMAIN ...]
    --challenge http-01|dns-01
    [--ca letsencrypt|zerossl] [--email EMAIL]
    [--dns-provider cloudflare|aliyun|tencent|dnspod|huawei]
    [--dns-credential-file FILE] [--staging]
    [--reload none|proxy]
vpsctl security tls renew [--id ID | --all] [--force]
vpsctl security tls credentials --id ID --dns-credential-file FILE

vpsctl security tls timer status|enable|disable
vpsctl security tls uninstall --confirm-uninstall REMOVE-VPSCTL-TLS
vpsctl security tls uninstall --purge --confirm-uninstall REMOVE-VPSCTL-TLS
    --confirm-purge
```

无参数且连接交互终端时进入编号菜单；无参数非交互调用等同于人类可读的 `status`。菜单执行真实动作，不提供 dry-run 或机器格式开关。

帮助、`status`、`list`、`show` 和 `paths` 允许普通用户执行；读不到私钥目录时该项显示为权限不足，不把私钥写入 stdout、日志或 JSON。所有变更动作需要 root。`--yes` 不能替代 `--confirm-delete`、`--confirm-uninstall` 或 `--confirm-purge`。

`status --json` 的顶层包含 `schema_version: 1`，并报告 lego 安装状态、timer、证书列表（域名、来源、指纹、到期、live 路径）以及即将到期计数。私钥内容不会出现在任何输出中。

## 存储布局

| 用途 | 路径 |
| --- | --- |
| 状态与证书 | `/var/lib/vpsctl/security/tls/` |
| live 证书 | `/var/lib/vpsctl/security/tls/live/<id>/fullchain.pem`（0640） |
| live 私钥 | `/var/lib/vpsctl/security/tls/live/<id>/privkey.pem`（0600） |
| 历史版本 | `/var/lib/vpsctl/security/tls/certs/<id>/archive/<fingerprint>/` |
| DNS 凭证 | `/var/lib/vpsctl/security/tls/credentials/<id>.env`（0600） |
| 备份 | `/var/lib/vpsctl/backups/security/tls/` |
| lego 二进制 | `/usr/local/libexec/vpsctl/lego` |
| 续期 timer | `vpsctl-tls-renew.timer` / `vpsctl-tls-renew.service` |

live 路径必须是普通文件的原子替换，不能使用符号链接。项目拒绝路径中的符号链接组件。证书 ID 形如 `crt-` 加 16 位小写十六进制。`--name` 只用于展示。

写入事务顺序：获取锁、校验 PEM 与未加密私钥、确认公钥匹配、确认 SAN 覆盖声明域名、写入 fingerprint 归档、备份旧 live、原子替换 live、写入 metadata。失败时回滚 live 与 metadata；回滚也失败则返回 `30` 并输出备份 ID。metadata 与 live 指纹不一致时，写操作拒绝覆盖。

`self uninstall` 不得删除上述路径。`tls uninstall` 只停用并删除续期 unit；`--purge` 再删除 live、账户、凭证和 lego 二进制，保留 backups。

## 导入与替换

导入要求绝对路径的普通文件，拒绝符号链接。证书不能过期，私钥必须未加密且与证书匹配。可选 `--chain-file` 会拼到 fullchain 末尾。域名集合取自证书 SAN（必要时回退 CN）。`--reload proxy` 写入 metadata，并在本次成功后尝试重载已知代理 unit。

非交互删除必须传入 `--confirm-delete`。若 `/var/lib/vpsctl/service/proxy/nodes.json` 中存在 `managed` 引用该证书 ID，删除会拒绝，要求先改节点。

## ACME 申请与续期

ACME 客户端固定为 lego `v5.4.1`，从 GitHub Release 下载对应 `linux_amd64` 或 `linux_arm64` 资产，并用官方 checksums 文件校验。`issue` 本身授权下载 lego；系统工具（`openssl`、`curl`、`tar`、`sha256sum`、`ss`、`flock`）仍按 `--install-deps` 规则处理。

- `--ca` 默认 `letsencrypt`。`--staging` 只用于 Let's Encrypt staging，不得用于生产。
- ZeroSSL 需要 `--email`。Let's Encrypt 也要求 email，用于账户注册。
- HTTP-01：lego 临时监听 `:80`。若 80 已被占用则失败并提示改用 DNS-01，不抢占已有服务。
- DNS-01：通配符 `*.example.com` 必须使用。提供商白名单为 Cloudflare、阿里云、腾讯云、DNSPod、华为云。凭证文件只允许对应提供商的环境变量名，未知键会被拒绝。
- 本功能不把域名解析到本机；HTTP-01 只检查端口占用。
- 首次成功的 ACME 签发会幂等启用续期 timer。

`renew --all` 只续期 `source=acme` 且 30 天内到期的证书；导入证书跳过。`--force` 忽略剩余有效期。部分成功返回 `30` 并列出失败 ID。timer 每天两次触发 `vpsctl security tls renew --all`，并带随机延迟。无 systemd 时可以导入和申请，但不能安装 timer。

`--reload proxy` 在签发或续期成功后，若存在 `vpsctl-proxy-sing-box` 或 `vpsctl-proxy-xray` 的 systemd unit / OpenRC 脚本，则对其执行 try-reload-or-restart 或 restart。这不是调用 `service proxy`。

## 代理消费

其他功能不得 exec 本命令。代理可通过 live 路径引用证书：

```text
vpsctl service proxy node add --profile vless-ws-tls --sni example.com \
    --cert-mode managed --cert-id crt-...
```

节点配置保存证书 ID 与 live 逻辑路径。续期只替换 live 文件内容，路径不变。续期后证书指纹变化会使分享 URI 中的证书固定值变化。完整节点接口见[代理管理](proxy-management.md)。

## 验收

所有语法、单元、集成和真实功能验证只能通过 `ssh host-vps-scripts` 在专用环境执行。默认套件覆盖参数、dry-run、导入校验、替换、删除确认、漂移拒绝、timer unit、mock lego 申请/续期、凭证权限与密钥不泄漏。opt-in 脚本 `tests/integration/test-security-tls-real.sh` 在 `VPSCTL_REAL_TLS_TEST=1` 时于专用主机执行真实导入与 timer；若提供 `VPSCTL_TLS_TEST_DOMAIN`，再使用 Let's Encrypt staging 做 HTTP-01 申请。不得把私钥、DNS token 或未脱敏主机名提交到仓库。
