# v0.12.2 发布记录

`v0.12.2` 于 2026-11-14 20:26:39（Asia/Singapore）正式发布并设为 latest，非 prerelease。发布提交为 `5f6b1115869ea1f5a4bafa32000fd1eb7b712a23`；[GitHub Actions 构建](https://github.com/Runarry/vps-script-lite/actions/runs/43585902376) 成功。[正式 Release](https://github.com/Runarry/vps-script-lite/releases/tag/v0.12.2) 提供 26 个 schema 2 在线资产、8 个离线归档及统一离线 SHA-256 清单，共 35 项。上一正式版本 `v0.12.1` 保留。

本次修复 BIOS GRUB 安装/修复时，已有 `grub-efi-amd64-signed` 必须随 `grub-common` 升级却被拒绝的问题。仅允许已安装、未锁定且来自可信发行版源的签名包按精确依赖配套升级，保留新增、降级及删除限制，并将原签名模块纳入变更检查和恢复备份。CLI 接口不变，发布管理器不会自动修改引导配置或重启系统。

## 验证范围

GRUB 修复的定向回归、Bash 语法、ShellCheck、格式检查，以及 Debian 13 / SeaBIOS / GPT / Btrfs 虚拟机中的真实修复、两次磁盘启动和内核切换均已通过，详见[功能验收记录](kernel-grub-install-validation.md#2026-11-14已有签名-efi-模块的配套升级)。发布提交保留该修复及对应回归代码，功能结果继续有效。

本次按要求停止后续测试并直接发布。Actions 构建成功和 GitHub 发布状态、资产名称数量的读取仅证明构建与发布完成；未重新下载草稿资产进行独立摘要复核，未执行发布交付与版本入口定向检查、在线升级/回退生命周期、八平台离线依赖安装、离线生命周期或正式公开安装验收，不将这些项目记为通过。未运行完整测试套件，也未在业务机器测试或部署。

## 专用环境与升级

发布验收准备期间，临时 ARM binfmt 登记误匹配本机 ELF，导致专用测试机的新 SSH 连接被重置；该环境准备错误与产品实现无关。后续测试和自动恢复尝试已停止。此临时登记可通过重启专用测试机清除；若控制台已有登录的 Bash，也可用内建命令 `printf '%s\n' -1 > /proc/sys/fs/binfmt_misc/vpsctl-release-offline-aarch64` 移除。停止时尚未确认环境恢复，准备材料位于专用机 `/var/tmp/vpsctl-release-0.12.2/`。

schema 2 用户可执行 `vpsctl self update --version v0.12.2` 升级管理器，再按[系统内核管理](kernel-management.md)使用原有 GRUB 修复入口。必要时可使用保留的 `v0.12.1` 恢复管理器版本；管理器降级不会回滚已经执行的软件包或引导变更，后者使用对应操作的恢复备份。
