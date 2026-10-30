# 备份与恢复

三个独立按需下载入口共用加密仓库：`system backup` 使用 ReaR 生成整机恢复材料，`system backup-docker` 保存 Docker 部署、镜像与数据，`system backup-repo` 管理 WebDAV、S3 或本地仓库。设计依据见 [备份设计](backup-design.md)，实际验证范围见 [验收记录](backup-validation.md)。

功能登记为 `experimental`。能力检测和真实恢复验收分别记录，不把一个发行版测试通过解释为所有 Linux 均可恢复。备份不保存进程、内存和网络连接。

## 按需加载与依赖

```bash
vpsctl system backup-repo
vpsctl system backup
vpsctl system backup-docker
```

交互终端显示中文菜单，非交互显示状态或帮助。安装态首次进入具体功能（包括帮助/status）下载该功能包与 `shared-command`、`shared-backup`；总菜单、全局帮助和 core 更新不预取它们。

Docker 不下载整机包或安装 ReaR，S3 不安装 rclone。实际动作缺依赖时，交互提示安装，非交互使用 `--install-deps`；`--yes` 只授权普通操作。Docker Engine 须已安装。归档使用 GNU tar，Docker 工作流还使用 Python 3 标准库和固定到实际 ID 的辅助镜像。

定时任务在配置时准备独立运行文件，执行时不下载代码或自动升级依赖。源码树可将示例中的 `vpsctl` 换成 `bash bin/vpsctl`。

## 仓库

先准备非空的仓库解密密码文件与凭据 JSON，归当前用户所有且权限 0600。配置时复制到 `/etc/vpsctl/backup/secrets/`。密码与凭据还必须保存在服务器之外，不能只放在需要该密码才能解开的仓库里。

WebDAV 凭据：

```json
{"user":"用户名","password":"应用密码"}
```

也支持 `{"bearer_token":"令牌"}`。S3 凭据：

```json
{"access_key_id":"访问密钥ID","secret_access_key":"访问密钥"}
```

临时凭据可增加 `session_token`。配置 WebDAV 的例子：

```bash
vpsctl --install-deps --yes system backup-repo configure offsite \
  --type webdav --url https://storage.example/remote.php/dav/files/USER/ \
  --prefix vps-backup --vendor nextcloud \
  --password-file /root/backup-password \
  --credentials-file /root/webdav-credentials.json
vpsctl --yes system backup-repo init offsite
```

选择 S3 时可改用：

```bash
vpsctl --install-deps --yes system backup-repo configure offsite \
  --type s3 --endpoint https://s3.example --bucket backups \
  --prefix vps-backup --region us-east-1 --bucket-lookup path \
  --password-file /root/backup-password \
  --credentials-file /root/s3-credentials.json
vpsctl --yes system backup-repo init offsite
```

同名配置会重新设置仓库引用，旧配置留为 `.previous`；同时使用多个仓库应取不同名称。离线仓库使用 `--type local --path /绝对存储目录`。连接支持自定义 CA、并发、超时和 pack 大小，默认验证 TLS，HTTP 需显式 `--allow-http`。

`init` 先在独立探测前缀执行真实写入、列举、读回和删除，再初始化实际仓库；已有仓库不覆盖。WebDAV 小文件探测不代表任意对象大小都受支持。

```bash
vpsctl system backup-repo status --json
vpsctl --yes system backup-repo probe offsite
vpsctl system backup-repo check offsite
vpsctl system backup-repo check offsite --read-data
```

`status` 只看本地脱敏状态。默认 `check` 检查仓库结构，`--read-data` 才读取全部数据。S3 生命周期规则不可独立删除仍被 Restic 引用的对象；Object Lock 或有限权限可能阻止清理。

## Docker 备份

```bash
vpsctl --install-deps system backup-docker inspect
vpsctl --install-deps --yes system backup-docker configure daily \
  --repo offsite --work-dir /srv/vps-backup-work --consistency stop
vpsctl --dry-run system backup-docker run daily
vpsctl --install-deps --yes system backup-docker run daily
vpsctl system backup-docker snapshots offsite --plan daily
```

默认覆盖本地选定 daemon 的全部容器，包括停止的容器。可用重复的 `--container NAME`、`--project NAME`、`--label KEY=VALUE` 限定范围。镜像实际 ID、Compose/运行定义、可写层、Named/Anonymous Volume、Bind Mount、共享关联和原运行状态都纳入材料；运行时 socket、设备与伪文件系统只记录依赖。

`stop` 模式正常停止共享数据的相关写入者，采集后恢复原运行状态，再上传。原先停止的容器保持停止。暂存空间与停服时间取决于本地采集量，上传在服务恢复后进行。

`online` 使用 `--online-config FILE` 配置原生数据库导出或明确的应用 hook，不将活动数据库原文件默认为一致备份。文件为 JSON 数组，例如：

```json
[
  {"kind":"postgres","container":"db","user":"appuser","os_user":"postgres"},
  {"kind":"mysql","container":"mysql","defaults_file":"/run/secrets/backup.cnf"},
  {"kind":"sqlite","container":"app","path":"/data/app.db"}
]
```

只保留计划实际使用的适配条目。`container` 是容器名称，`path`、`defaults_file` 是容器内部路径；PostgreSQL 的数据库角色 `user` 和系统用户 `os_user` 分开设置。对应容器必须具备原生客户端，数据库数据目录由适配器探测。SQLite 的持久挂载若还含其他未覆盖业务文件，需要应用 hook 或改为 `stop`，不能悄悄丢弃这些文件。

PostgreSQL、MySQL/MariaDB 在线准备和采集会检查数据库目录所在挂载的覆盖范围。同一挂载中数据库目录之外的文件、符号链接或空目录，必须由其他导出适配器或明确的应用导出 hook 覆盖，否则在导出前拒绝，并列出未覆盖路径。可将业务数据拆到独立挂载、使用完整应用 hook，或改用 `stop`。数据库目录内部按原生数据库导出的语义处理，不保证保存放在其中的任意自定义文件；普通 pre/post hook 仅协调时点，不代表已经保存数据。

应用 hook 使用 `kind: "hook"`、`container`、`data_mounts`，并以 `capture`、`restore` 字符串数组提供容器内命令；capture 标准输出作为备份，restore 从标准输入读取。不解析拼接 Shell 命令。数据库与关联上传文件应协调同一备份范围；各适配器的实际验证结果见验收记录。

Rootless、远端 context、Swarm、外部卷驱动、未支持的创建字段和目标设备缺失会给出具体能力缺口。上传失败后重传已有材料，不再次停服：

```bash
vpsctl --yes system backup-docker retry TASK_ID
vpsctl --yes system backup-docker recover-interrupted daily
```

## 整机备份

```bash
vpsctl --install-deps system backup inspect
vpsctl --install-deps --yes system backup configure weekly \
  --repo offsite --work-dir /srv/vps-backup-work
vpsctl --dry-run system backup run weekly
vpsctl --install-deps --yes system backup run weekly
vpsctl system backup snapshots weekly
```

整机路径检查 GNU/Linux、systemd、x86_64、ReaR 和引导工具，清点持久挂载及未挂载文件系统。无法自动纳入的存储明确报告；`--exclude-mount`、`--exclude-device`、`--exclude-path` 用于明确排除，不可排除恢复必需系统范围。其他业务服务通过重复的 `--stop-service UNIT` 纳入。

Debian 13 与系统源提供的 ReaR 2.7 存在已复现的救援启动兼容问题。该组合使用合适的现有 ReaR，或在允许安装依赖时按需取得固定版本 2.9 到本功能受管目录；不修改系统 ReaR 包、不添加软件源。下载地址和 SHA256 固定，元数据记录来源。摘要用于固定已取得的官方 HTTPS 发布资产，不等同于独立签名验证；实际启动结论以验收记录为准。[上游问题记录](https://github.com/rear/rear/issues/3528)

每次生成完整的本地归档、配套 ISO、布局和清单，再由 Restic 上传。远端去重不免除本地全量读取和暂存需求。`--work-dir` 可指向额外存储，暂存目标从源范围排除；空间不足时不开始停服。

服务状态持久记录；采集成功或失败都尝试恢复，启动失败单独返回部分完成状态。进程被强制终止或主机掉电后，通过中断恢复入口处理，不能承诺任意故障下零中断。

## 定时执行和保留

```bash
vpsctl --install-deps --yes system backup-docker schedule daily enable --cron '0 3 * * *'
vpsctl --install-deps --yes system backup schedule weekly enable --cron '0 3 * * 0'
vpsctl system backup-docker schedule daily status --json
vpsctl --yes system backup-docker schedule daily disable
```

systemd 和 cron 每分钟唤醒固定运行文件，由同一五字段 cron 匹配器决定执行，采用主机时区。支持数字、列表、范围、步长和英文月份/星期。错过的时点记录为错过，不在开机后自动补做停服备份；同一分钟不重复启动同一计划。

运行文件按不可变版本保存，升级原子切换，执行中的任务继续使用旧版本。管理器删除历史 release 不影响定时任务，采集锁避免手动与定时任务互相停服务。

计划保存每日/每周/每月保留数量。成功上传后自动按计划维护远端历史，清理限定到源主机、类型和计划并保留最新完整恢复点；旧采集时间的重传不会刚上传就被自动清理。维护失败与备份成功分别记录，返回部分完成状态，不撤销已经成功的快照。也可手动查看和执行维护：

```bash
vpsctl --dry-run system backup-repo prune offsite --plan daily
vpsctl --yes system backup-repo prune offsite --plan daily
```

成功材料默认保留到该计划下次执行前：确认对应完整恢复点仍在远端、校验本地封存内容后，仅清理本任务自己的成功暂存文件，保留小清单和任务记录。失败、候选和已变化的材料保留，夹杂的未知文件不删除，不能为了腾空间删除唯一恢复材料。这样正常定时备份不会无限累积全量本地归档；失败材料仍需依据任务状态重传或处理。

若旧任务重传后，其快照已被保留策略删除，成功查询确认该完整 ID 不存在时会保留本地材料，记录 `local_cleanup.state=skipped`、`reason=snapshot_missing` 并警告，不阻塞新备份。仓库连接、认证、查询解析或仍存在快照的完整性检查失败，依然返回失败；后续空间检查也不会被跳过。

卸载、关闭调度均保留配置、凭据和远端备份。历史数据删除为独立动作，不随本地缓存清理传播到远端。

## 恢复

使用确定的快照 ID。先导出工具包在服务器之外保留，密码和存储凭据另存：

```bash
vpsctl system backup export-recovery weekly --output /srv/recovery-system
vpsctl system backup-docker export-recovery offsite /srv/recovery-docker
```

原 VPS 消失后，在另一台 Linux 或临时 Linux 虚拟机准备连接与密码并取回备份，不依赖原任务数据库。工具包提供匹配版本的工具；完整离线恢复还需另存实际数据。

新导出的整机工具包在 `import-repo` 时先校验输入，再将密码、访问凭据和 CA 保存到各仓库独立的私密目录，最后发布仓库配置；同名仓库已存在时仍拒绝覆盖。Docker 工具包的手动配置模板也按仓库名称隔离秘密文件路径。旧工具包需重新导出才能获得修复；已有配置不自动迁移，已经被旧包覆盖的凭据需从独立保存的副本重新配置。

Docker 取回材料并检查冲突：

```bash
vpsctl system backup-docker restore-plan offsite SNAPSHOT_ID --target /srv/docker-restore
vpsctl system backup-docker restore offsite SNAPSHOT_ID --payload /srv/docker-restore
```

恢复重建镜像、网络、卷、容器和运行状态；同名、路径与端口冲突先处理。覆盖使用 `--overwrite` 并按帮助提供绑定目标 Engine 与快照的确认。`--name-prefix`、`--bind-map SOURCE=TARGET` 用于映射，不能覆盖其他服务仍使用的路径。

正常下载会在材料目录同级保存 `.docker-source.json` 来源记录，复制材料时一并保留。没有来源记录的独立离线材料仍可恢复，但计划将来源标为实际内容摘要，不能凭输入字符串声称已验证某个远端快照；覆盖时使用计划输出的 `confirmation_snapshot` 值。恢复前始终核验材料的封存哈希。

整机恢复在匹配 ReaR 救援 ISO 中运行：先用 `restore-plan --repo REPO --snapshot ID --work-dir 保留盘目录 --disk-map 原盘=目标盘` 取回材料、校验映射并取得确认令牌，再用 `restore` 和相同目标参数执行。多盘重复传入 `--disk-map`；暂存盘不能是即将擦写的目标盘。另机取回的材料可通过附加虚拟磁盘或 NFS 提供给救援环境。

`--mode production` 用于生产接替，按计划处理网络和身份；`--mode clone` 用于隔离克隆测试。`--network dhcp --interface 网卡` 切换目标网卡；可重复使用 `--dns IPv4或IPv6` 指定 DNS。没有 systemd-resolved 时仅能保留原非回环静态 DNS 或使用显式 DNS，源 stub 地址不会被当作可用解析服务。计划会展示 DNS 来源，静态地址仍需在目标网络验证连通。

`restore-plan` 和 `restore` 会在调用 ReaR 前检查封存系统归档中的 DHCP 依赖：必须有可用的 `systemd-networkd` 单元与对应程序；选择 systemd-resolved DNS 方案时还需对应 resolver 单元和程序。组件缺失、自定义 shell 启动或修改 `ExecStart` 的 drop-in 无法可靠判断时明确拒绝；普通资源限制或超时 drop-in 不受影响。可改用 `--network preserve`，或在源系统准备组件后重新备份；救援阶段不会自动安装组件。检查直接读取归档，已有 schema 1 快照同样适用；通过检查不代替重启后的网络验收。

恢复不自动重启；重启后的 SSH、服务与业务内容检查才构成完整启动恢复验收。整盘覆盖不可自动回滚，失败保留救援环境、材料和日志。

所有项目测试与真实恢复演练只能在 `ssh host-vps-scripts` 环境执行。实际支持组合和未运行项明确记录，不以单次上传或仓库结构检查代替业务恢复。
