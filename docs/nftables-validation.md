# Native nftables acceptance evidence

## 2026-11-01 验收汇总

所有项目测试、语法与静态检查都通过 `ssh host-vps-scripts` 执行；编辑端和 WSL 未运行项目验证。下面的日志与源码指纹记录各项实际使用的代码，后续修改仅在影响到既有结果时补做相应检查。

| 范围 | 结果与证据 |
| --- | --- |
| 真实旧后端退役、停用/重启用、恢复 | PASS。`/var/tmp/vpsctl-nft-parent/live3/result` 为 `lifecycle_exit=0`。公开 CLI 清理 UFW 包及 RFW/XDP，随后使用本地重建的 UFW 恢复包恢复原版本和 RFW 服务；恢复包明确包含 Debian `config`、`templates`。 |
| Docker 与规则所有权 | PASS。同一 live3 验收从独立客户端 namespace 访问真实 Docker 发布端口，切换前后及停用期间均可达；去除计数/handle 后的外部规则和转发 sysctl 与基线一致。 |
| 公开规则管理和 systemd 运行时 | PASS。live3 覆盖未知监听默认拒绝、放行、仅允许指定来源、删除、reload，以及实际 `systemctl start/reload vpsctl-nftables`。此项不声称重启了 Debian 宿主。 |
| SSH 双会话完整事务 | PASS。`/var/tmp/vpsctl-nft-parent/live2/ssh-result`：通过新的外部 SSH 连接验证候选端口，commit 后仅保留新端口需求；再经新端口恢复备份，原端口重新可登录，sshd 配置哈希一致。 |
| TCPing 与 iperf3 真服务 | PASS。live2 下 `tcping-run.log`、`iperf3-run.log` 覆盖真实协议、端口冲突、换端口、停止/重启/卸载、人工规则和共享引用保留、停止后全局 sync 不重新开放。 |
| HTTP-01 与 Fail2ban | PASS。`/var/tmp/vpsctl-nft-engine/security/20261101T084349Z-3206591/`：HTTP-01 使用实际 IPv4/IPv6 HTTP 监听，成功、失败和 TERM 后释放授权及子进程；独立 Fail2ban 实例使用真实 `sshd` jail 与发行版 `nftables-multiport` action，封禁不被管理器更新清除，解封后 SSH banner 可达。未申请真实 ACME 证书。 |
| 已安装中转 helper / DNS 换址 | PASS。`/var/tmp/vpsctl-nft-linkage/forward-runtime/run-2/`：实际安装的 helper/watch 在隔离环境解析私有 hosts，IPv4/IPv6 TCP/UDP DNAT 在换址前后可达；缓存发布失败恢复缓存、状态、manifest 和规则，旧目标继续可达。仅 systemctl 调度使用替身。 |
| PO0 双向接入与恢复 | PASS。`/var/tmp/vpsctl-nft-po0/cooperative-final.log`，含先装 PO0 和先装管理器、独立/联动模式、旧配置归属证明、真实 TCP/UDP、服务失败及 nft 应用后元数据失败恢复。详见 PO0 验收记录。 |
| 原生过滤、连接限制、双栈和重启 | PASS。下面各专项记录涵盖真实 INPUT/DNAT、原始端口、来源/服务范围、TTL、连接与 UDP 包限制、IPv6 邻居发现、两个内核的真实代理入口，以及 Alpine/OpenRC 两次实际重启。 |
| 分发和相关回归 | PASS。`/var/tmp/vpsctl-nft-distribution/evidence/` 保存九项库/分发/构建/离线夹具/入口测试；`dependency/` 另验证原生入口冷缓存按四个 bundle 顺序加载且不会安装代理服务。`/var/tmp/vpsctl-nft-parent/proxy-unit-final.log` 为完整代理单元套件 PASS。共享引擎、CLI、SSH/TLS/测速联动等专项结果见各执行目录。 |

早期失败保留在证据中，不计作 PASS：旧 `/bin/sh` 中转 helper 的识别、恢复仍在运行的 RFW 文件、Debian 恢复包缺失 debconf 元数据，以及 Ubuntu 22 的协议别名和区间集合更新兼容性。对应实现已修正并完成有针对性的复验。源集合更新仅原子替换发生变化的命名集合元素，保留集合 handle、其他集合、meter 和绝对到期时间，不重载整套防火墙。最后两项兼容修复还在 Debian 宿主的原生工具中通过完整共享引擎专项，日志为 `/var/tmp/vpsctl-nft-parent/native-final.log`；对应脚本通过语法、warning 级 ShellCheck 和 shfmt 检查。

专用机的防火墙、SSH 配置与服务基线已恢复。验收中磁盘不足时清理了一份未运行的历史临时 VM 磁盘；其校验、用途和清理记录保存在 `/root/vpsctl-bios-efi-replace-20261028/firewall-test-space-recovery.txt`，旧日志与 guest 证据归档保留。Alpine 本次使用的原始镜像未变化。

未执行全项目完整套件、八种真实离线包重建、ARM 实机及旧 Ubuntu 内核矩阵。涉及脚本的语法和分文件检查已执行；全量递归跟踪依赖的 ShellCheck 曾因 OOM/超时未完成，不能报告为通过。分发范围的逐文件诊断与 HEAD 比较无新增问题，原生核心、CLI、PO0 和新增验收脚本的专项检查通过。

The real kernel harness is `tests/integration/test-network-nftables-real.sh`; it invokes `test-nftables-linkage-real.sh` for shared service ownership. Run it only on the dedicated environment:

```sh
ssh host-vps-scripts 'cd /var/tmp/vpsctl-nft-acceptance/code && VPSCTL_REAL_NFT_TEST=1 bash tests/integration/test-network-nftables-real.sh'
```

The source snapshot must first be copied to that directory. The harness creates three uniquely named network namespaces (router, client, destination), uses real nft/netfilter and real IPv4/IPv6 TCP/UDP sockets, and writes state under a per-run `VPSCTL_SYSTEM_ROOT`. All firewall and sysctl changes occur in the router namespace. Its exit trap stops its servers and deletes only its namespaces. It does not install packages, modify host services, or alter the host firewall. The sole tool substitution is a one-shot native apply failure for rollback testing; ordinary traffic tests use the real tools.

Each run retains `code-state.txt` (UTC time, kernel, nft version, available Git HEAD, SHA-256 of the copied engine, CLI modules and harness), `acceptance.log`, input state, and kernel snapshots under `/var/tmp/vpsctl-nft-acceptance/results/TIMESTAMP-PID/`. File hashes identify the actual tested source; the Git HEAD alone does not identify uncommitted changes.

## Recorded evidence

Packet-matrix run: `/var/tmp/vpsctl-nft-acceptance/results/20261101T080847Z-2664571/`, exit 0, on dedicated `host-vps-scripts`, kernel `7.1.13-x64v3-xanmod1`. The namespace/server cleanup completed automatically. This run includes the service-scope and ingress-guard changes. Its engine hashes matched the local working files at that completion; subsequent scoped compatibility and recovery changes are recorded separately below:

| File | SHA-256 |
| --- | --- |
| `lib/nftables.sh` | `c4363ae0f99c9bbe30ad52a11045df846fb901c0044e1823b8a24edae488764c` |
| `lib/nftables/schema.jq` | `ca3e05c87abd5127425946dd599157958951fe8269bd1f11b1ae25560a7b83da` |
| `lib/nftables/render.jq` | `50ff983eff59554d66985fb5826bc53571b77f15ad35f0f1220067c83e948e11` |
| `lib/nftables/reconcile.jq` | `a9315dfb3cba9401009aa1247e8cf84f6dd7b8cb79bcf0b205b6c5f81e73ec51` |
| `lib/nftables/transactions.sh` | `e27e65b17a181e9dd03a0bddd54bcb2215882e70e288b07e27fab096a496c523` |

Commands executed through SSH, from `/var/tmp/vpsctl-nft-acceptance/code`:

```sh
bash -n tests/integration/test-network-nftables-real.sh tests/integration/test-nftables-linkage-real.sh
shellcheck tests/integration/test-network-nftables-real.sh tests/integration/test-nftables-linkage-real.sh
VPSCTL_REAL_NFT_TEST=1 bash tests/integration/test-network-nftables-real.sh
```

| Check | Final result | Evidence |
| --- | --- | --- |
| IPv4/IPv6 TCP/UDP INPUT and DNAT traffic | PASS | `acceptance.log`: baseline and source-deny messages |
| Denied source actually blocked, permitted source retained | PASS | All eight INPUT/DNAT protocol/family combinations |
| Global allow-only precedes automatic input permits | PASS | Denied and allowed source traffic matrix |
| Stable manual ID and persistent native set handles across unrelated logging change | PASS | `set-identity.before` and `set-identity.after` are identical |
| Absolute TTL through reload and snapshot restore; expiry does not widen allow-only | PASS | All protocol/family INPUT/DNAT probes blocked after original expiry, also after reload |
| Limits explicit opt-in | PASS | Eight unrestricted TCP connections and UDP exchanges per family before configuration |
| TCP new-connection rate and concurrency | PASS | Burst received 2/8 per family; two held connections succeed, third is blocked |
| UDP packet rate, including packets on the same flow | PASS | Same-flow received 2/8 per family |
| Native apply error rollback | PASS | Injected real nft missing-table error; state/runtime comparisons and absent journal |
| Foreign, Docker-like and foreign DNAT rules survive apply/restore/clear | PASS | `foreign.before` and `foreign.after` are identical |
| Service-scoped deny/allow-only targets owner INPUT and original DNAT endpoints | PASS | Both actions block the denied source matrix while the unrelated service on port 41004 remains reachable |
| Global ingress restriction preserves router-initiated UDP replies | PASS | IPv4 and IPv6 echo response to router-originated UDP |
| Global ingress restriction preserves unrelated nonlocal transit | PASS | IPv4/IPv6 TCP and UDP traffic to the destination namespace without DNAT |
| Shared service ownership and prepare/commit/rollback | PASS | Preparing/removing one owner retains listener access; last-owner commit closes it; rollback restores previous policy |
| Shared-owner detach/attach | PASS | One attached owner retains access; detaching both closes access; reattaching one restores it |
| Harness syntax and ShellCheck | PASS | Commands above exit 0 on the dedicated host |

All results in this table were obtained on the final snapshot; no earlier run is needed to establish them. An earlier run at `20261101T080559Z-2605715` found a harness cleanup issue (servers retained its output pipe). Only its namespace server PIDs were stopped manually, and the harness cleanup was fixed before the final successful run.

## Scope limits

NOT RUN by this isolated harness: host boot persistence, UFW/RFW retirement, SSH safety against a real SSH daemon, public CLI CRUD, installed proxy/DNS refresh behavior, actual Docker interoperability, and reboot behavior. A synthetic Docker-like table verifies ownership preservation only. Those checks require separately coordinated host/service acceptance. No unexecuted category is counted as passed.

## Real proxy ingress supplement

The existing native packet matrix above was reused after later journal changes. The following additional real protocol checks ran through SSH on the same dedicated host, under private network/mount namespaces. They did not modify installed cores, host services, or the host firewall.

The old core directory recorded in `proxy-hy2-validation.md` no longer existed. Exact official Xray 26.9.30 and sing-box 1.14.2 releases were downloaded into `/var/tmp/vpsctl-nft-acceptance/proxy/cores/`. Both archive SHA-256 values matched the official GitHub release asset digests:

- Xray `Xray-linux-64.zip`: `f851110beaff16e78d643f0ccfd9524b4a44dfd59bae3e34bb52bba378f7690e`.
- sing-box `sing-box-1.14.2-linux-amd64.tar.gz`: `a684484d7477d1437282ee411f4d131d0340aaad60a7868841ebd5d87dd8a0c6`.

Retained evidence under `/var/tmp/vpsctl-nft-acceptance/proxy/`: official release JSON, checksum record, extracted binary hashes in `binaries.sha256`, tested source hashes in `source.sha256`, final harness hashes in `harness.sha256`, logs, generated configurations, native rules and protocol samples. Archive/extraction duplicates and generated test-root binary copies were removed after hashing to recover disk space; verified binaries remain in `cores/`.

| Check | Result | Evidence |
| --- | --- | --- |
| Existing HY2 harness, `HY2_SCOPE=nftables` | PASS, exit 0 | `hy2-native.log` and `hy2-native/case-001-xray-26.9.30-sing-box-1.14.2-salamander-5/` |
| HY2 native default-deny and managed listener permit | PASS | Unrelated UDP denied; Xray server/sing-box client carry continuous TCP and UDP |
| HY2 actual ingress hopping | PASS | At least three intervals; pre-NAT counters observed original ports 53100, 53101 and 53103 |
| Xray ordinary TCP node and protocol relay ingress | PASS, exit 0 | `node-ingress/xray/`: production Shadowsocks entry → Shadowsocks protocol exit → HTTP sentinel |
| sing-box ordinary TCP node and protocol relay ingress | PASS, exit 0 | `node-ingress/sing-box/`: same representative chain |
| Requirement gates actual ingress for both cores | PASS | Peer client crosses veth; denied before requirement, sentinel response and nonzero INPUT counter after permit, new ingress denied after removal |
| New ingress harness syntax and ShellCheck | PASS | Remote `bash -n` and `shellcheck tests/integration/test-proxy-nftables-ingress-real.sh` |

Reproduction from the copied source directory:

```sh
HY2_CORES_DIR=/var/tmp/vpsctl-nft-acceptance/proxy/cores \
HY2_EVIDENCE_DIR=/var/tmp/vpsctl-nft-acceptance/proxy/hy2-native \
HY2_SCOPE=nftables bash tests/integration/test-service-proxy-hy2-real.sh

PROXY_NFT_CORES_DIR=/var/tmp/vpsctl-nft-acceptance/proxy/cores \
PROXY_NFT_EVIDENCE_DIR=/var/tmp/vpsctl-nft-acceptance/proxy/node-ingress \
bash tests/integration/test-proxy-nftables-ingress-real.sh
```

An initial attempt hit a full filesystem during binary copies; a new fixture also shadowed Python's `http` package with its filename. These were environment/harness failures before protocol traffic, retained as `hy2-native.initial-blocked.log` and `node-ingress.initial-fail.log`. Removing only this task's download duplicates and renaming the fixture enabled the successful final runs. No application fix was needed.

The existing `test-service-proxy-relay-connectivity-real.sh` uses loopback entry sockets and does not enable the native manager. It was inspected but not executed as ingress evidence. The new owned harness supplies actual peer ingress instead. NOT RUN in this supplement: DNS target refresh, the full proxy profile matrix, installed runtime/systemd lifecycle, and additional HY2 core/version combinations.

## Final IPv6 control-packet regression

PASS, exit 0: `/var/tmp/vpsctl-nft-acceptance/results/20261101T081919Z-2808892/`. After the final ICMPv6 prerouting exemption, only the narrow `VPSCTL_NFT_CASE=ipv6-neighbor` branch ran. It installed a global `proto:any` IPv6 allow-only rule for `fd90:1::2`, flushed both peers' neighbor caches, and forced router resolution of the client's link-local address (outside that allowlist). `ipv6-neighbors.json` records successful link-local resolution with a MAC address and reachable neighbor state. TCP from the allowed global source succeeded; TCP from `fd90:1::3` remained blocked. `code-state.txt` records the final tested engine and harness hashes. Remote syntax/ShellCheck also passed. The earlier broad packet matrix was reused; it was not repeated for journal-only changes.

```sh
VPSCTL_REAL_NFT_TEST=1 VPSCTL_NFT_CASE=ipv6-neighbor \
bash tests/integration/test-network-nftables-real.sh
```

## Actual Alpine/OpenRC reboot persistence

PASS: real QEMU guest boots, not a simulated service restart. Evidence is retained under `/var/tmp/vpsctl-nft-acceptance/alpine/`. The guest was Alpine 3.24.1, kernel `6.18.35-0-virt`, nftables 1.1.6, using OpenRC. QEMU used 320 MiB RAM, one TCG vCPU, a qcow2 overlay, and user-mode networking with loopback-only host forwards. Packages were installed only in the guest. No host services, host firewall or host packages were changed, and the host was not rebooted.

The backing image `/root/vpsctl-reinstall-real-20260929/alpine-partitioned.raw` was never written. Its before/after SHA-256 was identical: `75379a47f0bdb02c935d6f6ac06dab17587bdafa397c803babea55fccedfd97d`. `base.before.sha256`, `base.after.sha256`, and `final-overlay-info.txt` record that identity and the overlay relationship. QEMU was powered off after evidence collection; the overlay is retained for reproduction.

| Check | Result | Evidence |
| --- | --- | --- |
| Public CLI install and enable in OpenRC guest | PASS | `setup.log`; service added to default runlevel |
| Durable service requirement | PASS | Owner `boot-service`, IPv4 TCP 40123, saved through production begin/commit API |
| Actual enabled reboot | PASS | Boot ID `352f0d97-4daf-4857-846c-7481ec3c7af7` changed to `f882c7c3-16db-46da-829b-eb7757909ab3` |
| Automatic native table and service requirement restoration | PASS | `enabled.log`, `guest/vpsctl-nft-boot-evidence/enabled.ruleset.json` and enabled state |
| Real TCP payload while enabled, before/after reboot | PASS | Ports 40123 allowed and 40124 blocked; `initial-traffic.log`, `enabled-traffic.log` |
| Disable removes OpenRC runlevel activation | PASS | `disable.log`; private table immediately absent |
| Actual disabled reboot | PASS | Boot ID changed again to `78c90578-f462-42de-ae5b-4b9d46275c24` |
| Disabled state after reboot | PASS | Private table absent; service requirement retained; `disabled.log`, disabled state/ruleset |
| TCP payload after disabled reboot | PASS | Both listening ports respond; `disabled-traffic.log`, confirming the enabled blocked case was caused by firewall policy |
| Foreign table preservation | PASS | `foreign.before`, `foreign.enabled`, `foreign.disabled` identical across the two boot phases |
| Guest harness syntax/ShellCheck | PASS | Executed on `host-vps-scripts`; no local project execution |

The phase-based fixture is `tests/integration/test-nftables-boot-real.sh`, guarded by `VPSCTL_REAL_NFT_BOOT_TEST=1` and Alpine/OpenRC/root checks. It runs `setup`, `enabled`, `disable`, and `disabled` inside the disposable guest; the external controller issues actual `reboot` commands and probes the QEMU-forwarded TCP payload. The native manager runs against the guest's real filesystem, kernel and init system without testing-mode tool substitutions. Source hashes, installed OpenRC service, state, boot IDs, kernel rules, and guest version details are in `guest/vpsctl-nft-boot-evidence/` and `guest-evidence.tar`.

The existing NoCloud seed was attached after an initial boot without it waited for cloud metadata. Guest cloud-init was then disabled for subsequent boots; no product boot behavior was bypassed. The recorded successful enabled and disabled phases each used a separate actual reboot. This supplement covers real OpenRC persistence on Alpine; Ubuntu 22 userspace compatibility, physical-host reboot, and other init systems are not established by this guest test.

## Ubuntu 22.04 userspace compatibility

PASS, final `container_exit=0`: `/var/tmp/vpsctl-nft-acceptance/ubuntu22/`. Execution began only after the parent explicitly released the completed host lifecycle test. The disposable official Ubuntu 22.04 image had digest `ubuntu@sha256:076e7bf82319619f28dd0aa9c02ab34b055ad37100395b4f49a2ffba04fb5e11`. It reported Ubuntu 22.04.5 LTS, distribution package `nftables 1.0.2-1ubuntu3.1`, jq 1.6, and Bash 5.1. The initially assumed nftables 0.9.8 version was incorrect for this distribution; no 0.9.8 compatibility result is claimed.

The container used the host's `7.1.13-x64v3-xanmod1` kernel. These results establish Ubuntu 22.04 userspace compatibility against that kernel, not compatibility with Ubuntu's older default kernel. Source was mounted read-only; real netfilter operations ran in isolated network namespaces. Dependencies were installed only inside the container, with `--no-install-recommends`, matching the production installer policy.

| Check | Result | Evidence |
| --- | --- | --- |
| Real native engine scoped suite | PASS | `engine-unit.log`: validation, compile, named source sets, IPv4/IPv6 intervals, native timeouts, meters, TTL, transactions, recovery and foreign-table isolation |
| TCP rate/concurrency and UDP rate expressions | PASS | Real kernel apply by the engine suite; earlier dedicated-host actual packet results remain separately recorded |
| Generation metadata and failed publication recovery | PASS | Real native generation commit, injected metadata publication failure, snapshot restoration, abandoned preparation recovery |
| Changed source membership on older nft userspace | PASS | `interval-fixed.log`: `nft -c` and `nft -f` both succeed; retained host 192.0.2.1 and new host .3 exist, removed .2 is absent |
| Actual IPv6 allow-only, denied TCP, and link-local neighbor discovery | PASS, reused after source-set reconciliation change | `ipv6-native.log`, `native/20261101T085336Z-7/`; no later rendering-guard change invalidated this result |
| Updated unit formatting and static checks | PASS | Remote `shfmt -w -i 4 -ci`, `bash -n`, `shellcheck -S error`; exact formatted file copied back |
| Disposable resource cleanup | PASS | `container.removed`, `image.removed`; only the assigned container and newly pulled image were removed |

This test exposed two product compatibility defects before passing. First, `meta l4proto ipv6-icmp` depended on `/etc/protocols`, absent in a minimal install without recommended `netbase`; a native numeric-protocol-58 reproduction succeeded. The renderer now uses numeric 58 while retaining native ICMPv6 type keywords. Second, nftables 1.0.2 rejected deleting an existing interval and adding a retained endpoint in the same batch. The reconciler now atomically flushes and repopulates only the changed named source set, preserving its handle, unaffected chains/meters, and remaining absolute TTL. Both check and actual apply failures are retained in `protocol-name.err`, `interval-before-fix/`, and the failed stage logs. The final suite checks actual membership, stable object handles and retained meter contents rather than requiring one command spelling.

The final tested hashes are recorded in `environment.txt`: renderer `5e71c48db8709fd3a8d9daaad7078b226e98a24063b8fad12e451879a56ba382`, reconciler `12b6d08ac6799236d3bf16292381cdef062903b8bb0061e57c43ebf4e8b57f92`, and unit `5a48359d650ea40b7ebbda6de4310caaac1ac563f910995790c7552a53019546`. No host package installation or daemon configuration change was made. NOT RUN: nftables 0.9.8, an older Ubuntu kernel, or a repeat of unrelated proxy/boot/full-project suites.
