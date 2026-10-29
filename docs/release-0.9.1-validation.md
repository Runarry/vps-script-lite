# v0.9.1 发布验收

发布目标为 `v0.9.1`，沿用 manifest schema 2。本次新增 `system clean`，支持推荐清理、受管残留与功能包缓存、软件包下载缓存、按系统规则过期的临时文件和独立归档 journal 清理。功能提交为 `fdc6b55`；功能边界、真实 Debian 验收及其他后端的验证范围见[系统清理验收](system-clean-validation.md)。

所有项目执行与验收均通过 `ssh host-vps-scripts`。发布副本与证据位于专用机 `/var/tmp/vpsctl-release-0.9.1.7d00Ynhv/`；本机仅编辑、审阅、版本控制、管理 GitHub Release 和传输文件。

## 功能验收复用

本次版本准备仅修改 `VERSION` 和发布文档，不重新运行已通过且代码未改变的功能测试。新功能的 Bash 语法、ShellCheck、shfmt、定向单元及 Debian 原生清理结果保持有效；既有测试静态诊断的基线和真实后端限制均保留在功能验收记录中。

## 发布流程

发布前按仓库流程完成版本与构建检查，从 GitHub 草稿重新下载完整资产并核验摘要，验证真实安装、缓存、更新及卸载保护；草稿验收通过后正式发布并设置 latest，再验证公开安装入口。发布与恢复的实际结果在流程完成后补充到本记录。

schema 2 用户更新命令：`vpsctl self update --version v0.9.1`。v0.8.9 的 schema 1 用户仍须按 README 校验目标安装器和 manifest、普通卸载后重装。清理功能不要求重装或重启已部署服务。
