# 当前测试基线

本文件只记录现行自动化测试范围。产品要求见 `claude-easy/references/` 各策略文件。

## CI 范围

`tests/ci_scope.rb` 按改动计算 flags：`structure`、`macos`、`windows`、`mihomo`。详见 `.github/workflows/test.yml`。

## Jobs

| Job | 覆盖的失败类 |
| --- | --- |
| **scope** | 分类器误选/漏选 job 或 platform flag |
| **structure**（macos-15） | CI scope 分类；Skill 路由合同；策略与代码 parity；Ruby/Shell 语法；空白与 diff 检查 |
| **structure-node**（ubuntu） | Windows 引擎与 region 页 JS 语法 |
| **macos** | macOS patcher 与包装器；逐份远端比对、无变化短路和仅更新变化订阅；存储偏好缺失时识别唯一现行本地订阅；dispatch 追加 system-ruby；base-scoped 包装器与生产探针；覆盖 `already_disabled_owned` |
| **windows** ×3 TestGroup | AST 解析；JSON smoke；installer 套件与远端订阅比对计划；base-scoped PS5 路由（core leg）；覆盖运行中三个档位安装、卸载、备份恢复与中断恢复 |
| **windows-installer-powershell-7**（dispatch） | PS7 完整 installer 套件 |
| **windows-routes-powershell-7**（dispatch） | PS7 路由验证 |
| **mihomo** | arm64 当前内核；dispatch 追加 intel 与 minimum 版本 |
| **windows-mihomo** | 当前内核 PS5；dispatch = 2 内核 × PS5/PS7 |

Playwright region-browser 在 CI 外运行。
