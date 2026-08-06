# Input Boundary Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复安全扫描确认的四个真实缺陷，让复杂 YAML、Windows 命令脚本路径和 `Script.js` 非规范词法输入在写入前安全失败。

**Architecture:** 三个平台边界都采用“先完整表示、再执行”的同一原则。YAML 先迭代计数再递归物化；Windows 命令脚本在进入 `cmd.exe` 前验证完整参数并关闭延迟展开；JavaScript 分析器识别正则字面量并拒绝代码区 Unicode 转义。

**Tech Stack:** Ruby 3.x、Psych、Windows PowerShell 5.1/7、JavaScript 词法扫描、Minitest、Node.js test runner。

## Global Constraints

- 只支持 macOS ClashX Meta 和 Windows Clash Verge Rev，Mihomo 最低版本为 1.19.27。
- 不启动、退出、停止或重启 Clash 客户端。
- 所有拒绝必须发生在事务写入前，且不得泄露路径、订阅或凭据。
- 保留工作区现有 `tests/test_windows_installer.ps1` 改动，不把无关行纳入提交。
- 每个修复先出现能证明旧行为错误的失败测试，再修改生产代码。

---

### Task 1: YAML 复杂度预算

**Files:**
- Modify: `claude-easy/scripts/macos/patch_profiles/transform.rb`
- Modify: `tests/test_macos_patcher.rb`
- Modify: `tests/baseline.md`

**Interfaces:**
- Consumes: `Psych.parse_stream(text, filename:)` 返回的 AST。
- Produces: `validate_yaml_complexity(node)`；超限抛出 `InvalidConfigError`。

- [x] **Step 1: 写失败测试**

新增直接调用 `load_yaml` 的深层 YAML 用例，要求只产生 `InvalidConfigError`；新增宽而浅的正常 YAML 和节点数超限用例。

- [x] **Step 2: 确认旧代码失败**

Run: `ruby tests/test_macos_patcher.rb --name '/test_load_yaml_rejects_excessive_depth_before_materialization|test_load_yaml_accepts_wide_shallow_documents|test_yaml_complexity_rejects_excessive_node_count/'`

Expected: 深层用例抛出 `SystemStackError` 或未得到规定的 `InvalidConfigError`。

- [x] **Step 3: 实现最小修复**

在 `transform.rb` 定义明确的最大深度与节点数；使用显式栈迭代遍历 Psych AST。`load_yaml` 在别名检查后、`ToRuby` 前调用验证器，任一预算超限统一抛出“YAML 结构过于复杂”。

- [x] **Step 4: 运行相关测试**

Run: `ruby tests/test_macos_patcher.rb --name '/test_load_yaml_rejects_excessive_depth_before_materialization|test_load_yaml_accepts_wide_shallow_documents|test_yaml_complexity_rejects_excessive_node_count|test_deep_yaml_aborts_the_batch_before_other_profiles_are_written/'`

Expected: 4 tests pass。

### Task 2: Windows 命令脚本调用边界

**Files:**
- Modify: `claude-easy/scripts/windows/install_windows/mihomo.ps1`
- Modify: `tests/test_windows_installer.ps1`
- Modify: `tests/test_skill_contract.rb`
- Modify: `tests/baseline.md`

**Interfaces:**
- Consumes: `Invoke-Mihomo([string]$CorePath, [string[]]$Arguments, [int]$TimeoutSeconds)`。
- Produces: `Assert-WindowsCommandScriptArgument([string]$Value)`；命令脚本路径或参数含解释器元字符时抛错。

- [x] **Step 1: 写失败测试**

在 Windows 行为测试中创建文件名含 `&` 的 `.cmd`，调用 `Invoke-Mihomo` 后断言它在启动前被拒绝；合同测试锁定 `/v:off` 和完整参数验证调用。

- [x] **Step 2: 确认旧代码失败**

Run: `ruby tests/test_skill_contract.rb --name test_windows_mihomo_batch_invocation_rejects_command_syntax`

Expected: FAIL，因为生产代码还没有参数边界验证。

- [x] **Step 3: 实现最小修复**

只在 Windows `.cmd/.bat` 兼容分支逐项拒绝双引号、百分号、感叹号、脱字符及 `&|<>()`；`cmd.exe` 固定增加 `/v:off`。直接 `.exe` 调用不受影响。

- [x] **Step 4: 运行相关测试**

Run: `ruby tests/test_skill_contract.rb --name test_windows_mihomo_batch_invocation_rejects_command_syntax`

Expected: PASS。Windows PowerShell 5.1/7 行为用例由 GitHub Test workflow 验证。

### Task 3: JavaScript 规范词法边界

**Files:**
- Modify: `claude-easy/scripts/windows/install_windows/script_js.ps1`
- Modify: `tests/test_windows_installer.ps1`
- Modify: `tests/test_windows_patcher.js`
- Modify: `tests/baseline.md`

**Interfaces:**
- Consumes: `Get-JavaScriptAnalysis([string]$Text)` 的等长掩码。
- Produces: `Test-JavaScriptRegexLiteralStart([string]$Code)`；正则内容被等长掩码，代码区反斜线按非规范标识符拒绝。

- [x] **Step 1: 写失败测试**

新增两个事务前拒绝用例：Unicode 转义拼写 ClaudeEasy 保留标识符；正则字面量内的引号后跟受管保留标识符。另加合法正则与除法表达式组合成功用例，防止把 `/` 一律当成正则。

- [x] **Step 2: 确认旧代码失败**

Run: `node --test tests/test_windows_patcher.js`

Expected: 新增的源合同失败。Windows 行为用例在旧实现上至少有一个错误接受或错误拒绝。

- [x] **Step 3: 实现最小修复**

在代码状态根据前一有效词法单元判断 `/` 是否开始正则；迭代跳过转义、字符类、结束斜线和 flags，同时维持掩码长度及行终止符。代码状态遇到反斜线立即拒绝，不影响字符串、模板文本、注释或正则内部转义。

- [x] **Step 4: 运行相关测试**

Run: `node --test tests/test_windows_patcher.js`

Expected: PASS。Windows PowerShell 5.1/7 行为用例由 GitHub Test workflow 验证。

### Task 4: 验证与发布

**Files:**
- Modify: `tests/baseline.md`
- Verify: `claude-easy/`

**Interfaces:**
- Consumes: Tasks 1–3 的全部修复和测试。
- Produces: 已验证、已安装、已提交并推送的 `main`。

- [x] **Step 1: 运行语法、相关测试和差异检查**

Run: `ruby -c claude-easy/scripts/macos/patch_profiles/transform.rb`

Run: `ruby tests/test_macos_patcher.rb --name '/test_load_yaml_rejects_excessive_depth_before_materialization|test_load_yaml_accepts_wide_shallow_documents|test_deep_yaml_aborts_the_batch_before_other_profiles_are_written/'`

Run: `node --check claude-easy/scripts/windows/clash_verge_global.js && node --test tests/test_windows_patcher.js`

Run: `ruby tests/test_skill_contract.rb --name test_windows_mihomo_batch_invocation_rejects_command_syntax`

Run: `git diff --check`

- [x] **Step 2: 运行项目要求的完整本地矩阵**

按 `.github/workflows/test.yml` 在当前平台执行所有可运行的 Ruby、Node、Shell 语法、合同、mutation 和浏览器测试；PowerShell 5.1/7 与真实 Mihomo 留给 Windows CI。

- [x] **Step 3: 检查发布前 CI**

读取 `main` 最近一次 `Test` workflow；失败则查看日志并修复，运行中或暂不可用则如实记录且不等待。

- [x] **Step 4: 安装并逐文件校验 Skill**

把仓库 `claude-easy/` 同步到 `~/.codex/skills/claude-easy/`；若 `~/.agents/skills/claude-easy/` 存在也同步。使用递归差异检查确认完全一致。

- [ ] **Step 5: 精确提交并推送**

只暂存本计划涉及的差异；排除用户原有无关 hunk。提交到 `main`，推送 `origin/main`，不轮询新 CI。
