# ClaudeEasy Windows 真机失败整改 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复首次 Windows 真人安装暴露的确定性错误，增加可验证的运行加载结果，并在 Computer Use 不可用时立即给出小白人工步骤。

**Architecture:** 保留 Clash Verge Rev 的全局 `Script.js` 官方增强入口。底层只修已复现的解析、发现、执行策略和错误分类；安装结果分离文件写入与运行加载，没有控制面证据时返回部分完成。Computer Use 使用两次失败熔断，不再无限重试。

**Tech Stack:** PowerShell 5.1/7, JavaScript/Node test runner, Mihomo, Clash Verge Rev loopback controller fixture, GitHub Actions Windows runner.

**Spec:** `docs/superpowers/specs/2026-09-04-windows-real-machine-remediation-design.md`

## Global Constraints

- 只修改 Windows 文件和本次 spec/plan；不碰任何 macOS 文件。
- 每个已确认错误只在现有测试文件的最低有效层增加一个回归。
- 先看到新回归失败，再写最小实现；每项修复后运行对应测试。
- 本机没有 PowerShell。先集中提交 Tasks 2–6 的 Windows 回归测试并由 CI 确认红灯，再开始实现，避免为每个错误重复等待一次 CI。
- 不把 Boa、管理员权限或 Windows 全平台兼容性猜测写成既定原因。
- 不新增第二套订阅 YAML 变换管线，不重启、退出或停止 Clash Verge Rev。
- 文件写入不等于运行生效；没有控制器回读时不能返回完整成功。
- 完成前运行完整本地可运行基线、推送后等待 Windows CI、合并到 `main`、推送、安装 Skill 并逐文件校验。

---

### Task 1: 建立 Windows CI 红灯基线

**Files:**
- Modify: `tests/test_windows_installer.ps1`
- Modify: `tests/test_windows_routes.ps1`

- [ ] 为 YAML 同级列表、IPv6 规则类型、自定义运行中 Mihomo、锁错误分类、内部 PowerShell 执行策略、安装运行加载结果分别增加最低层回归。
- [ ] 只提交测试，不修改产品代码。
- [ ] 推送工作分支，等待 Windows CI，记录每个新增回归的预期失败证据。
- [ ] CI 失败必须来自新增断言；已有测试或其他平台失败时先调查。

### Task 2: 修复 YAML 同级列表范围

**Files:**
- Modify: `claude-easy/scripts/windows/install_windows/yaml.ps1`
- Modify: `claude-easy/scripts/windows/install_windows/runtime.ps1`

- [ ] 使用 Task 1 已经在 CI 失败的 `dns-hijack` 修改和 `direct-nameserver` 读取用例。
- [ ] 最小修改两个节点范围函数：只有同级的列表项属于刚出现且尚未结束的值列表。
- [ ] 提交实现；由下一次 Windows CI 复测。

### Task 3: 修复 IPv6 规则类型误判

**Files:**
- Modify: `claude-easy/scripts/windows/install_windows/runtime.ps1`

- [ ] 使用 Task 1 已经在 CI 失败的 IPv6 类型回归。
- [ ] 只在载荷为 IPv6 CIDR 时把 `IPCIDR` 与 `IPCIDR6` 视为同一种类型。
- [ ] 提交实现；由下一次 Windows CI 复测。

### Task 4: 支持自定义目录的运行中 Mihomo

**Files:**
- Modify: `claude-easy/scripts/windows/install_windows/mihomo.ps1`

- [ ] 使用 Task 1 已经在 CI 失败的自定义目录运行进程回归。
- [ ] 优先读取当前用户会话内运行中内核的可执行文件路径；歧义时拒绝，之后才查现有默认位置。
- [ ] 提交实现；由下一次 Windows CI 复测。

### Task 5: 修复执行策略与锁错误分类

**Files:**
- Modify: `claude-easy/scripts/windows/install_windows/transaction.ps1`
- Modify: `claude-easy/scripts/windows/verify_routes.ps1`

- [ ] 使用 Task 1 已经在 CI 失败的访问拒绝与执行策略回归。
- [ ] 按 Win32 错误码分类锁失败；内部 PowerShell 启动显式传递 `-ExecutionPolicy Bypass`。
- [ ] 提交实现；由下一次 Windows CI 复测。

### Task 6: 增加首次安装运行加载闭环

**Files:**
- Modify: `claude-easy/scripts/install_windows.ps1`
- Modify: `claude-easy/references/result-contract.json`

- [ ] 使用 Task 1 已经在 CI 失败的自动加载与部分完成回归。
- [ ] 写入前捕获可用的运行状态；事务后复用现有一次性重新激活与健康等待。
- [ ] 只有运行验收通过才返回 `installed`；否则保留已验证文件并返回明确的部分完成结果。
- [ ] 提交实现；由下一次 Windows CI 复测。

### Task 7: 增加 Computer Use 熔断与小白接管

**Files:**
- Modify: `claude-easy/references/windows.md`

- [ ] 写入同一目标连续两次无可回读结果就停止重试的规则。
- [ ] 分别写清浏览器、Clash Verge Rev、Windows 语言和时区的人工步骤合同：位置、动作、目的、预期结果、确认语。
- [ ] 不复制安全更新、档位或验收规则；只引用它们。
- [ ] 运行 `git diff --check` 和现有 Skill 合同测试并提交。

### Task 8: 全量验证、审查和发布

**Files:**
- Verify all changed files.

- [ ] 运行 `ruby tests/test_ci_scope.rb`、`ruby tests/test_skill_contract.rb`、`ruby tests/generate_windows_policy.rb --check`、Node 测试和 `git diff --check`。
- [ ] 确认 diff 中没有任何 macOS 文件。
- [ ] 使用 `superpowers:requesting-code-review` 做最终审查；修复已确认问题并复测。
- [ ] 推送工作分支并等待 GitHub Actions Windows CI 完成。
- [ ] 合并到 `main`，推送 `main`。
- [ ] 把 `claude-easy/` 安装到 `/Users/wallny/.codex/skills/claude-easy/`，逐文件校验一致。
- [ ] 删除工作树和分支；最终只报告实际测试、Git 状态和真机待验证边界。
