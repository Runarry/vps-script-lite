# 项目协作约束

- 把独立的只读检查合并到一次 shell 调用，优先使用 `rg`，并排除 `node_modules`、`dist`、`build`、`.next` 和临时目录。
- 对每个非简单任务评估子代理是否能显著提升速度、覆盖面或可靠性；确有收益时再使用。
- 所有项目测试、语法检查、静态检查、集成验证和真实功能验收都必须通过 `ssh host-vps-scripts` 在专用真实环境中执行。
- `host-vps-scripts` 是可随意修改和测试的专用环境；允许为了验证项目而安装依赖、修改系统配置或执行破坏性测试，但仍应记录必要的恢复信息和测试结果。
- 禁止在当前系统或 WSL 中执行任何项目测试或验证命令。当前系统仅用于编辑文件、查看差异以及执行不运行项目代码的只读仓库检查。


# 测试
Do not write tests for reversible, low-impact changes that mirror the implementation. If you do choose to verify your work with tests, make sure that the tests are meaningful and necessary to verify implementation.

Run tests appropriate to the change and complete required checks. Once those pass, broaden or repeat testing only when new changes, failures, or unresolved concerns justify it; otherwise, continue toward completing the task.