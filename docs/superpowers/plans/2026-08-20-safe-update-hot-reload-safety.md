# Safe Update Hot Reload Safety Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement each task.

**Goal:** 保留 macOS 与 Windows 热加载，同时阻止安全更新再次造成客户端、内核、TUN 和系统网络状态不同步。

**Architecture:** macOS 改为只向已经运行的 ClashX Meta 进程发送客户端原生更新事件；Windows 保留客户端原生快捷键。两端都以运行状态和真实连通性作为完成条件，并把每次加载阶段记录进事务，限制为一次更新加载和一次恢复加载。

**Tech Stack:** Ruby 2.6、PowerShell、JXA/AppleEvent、Minitest、Pester 风格脚本测试

---

### Task 1: 固定 macOS 安全边界

**Files:**
- Modify: `tests/test_macos_patcher.rb`
- Modify: `tests/test_mutation_safety.rb`
- Modify: `claude-easy/scripts/macos/patch_profiles/runtime.rb`

1. 先添加失败测试：只向既有 PID 发原生更新事件；PID 变化或进程退出时拒绝；安全更新不得直接重新加载 Mihomo 或直接改 TUN。
2. 运行目标测试，确认因旧实现失败。
3. 添加最小的既有进程身份检查、原生更新事件发送和条件等待。
4. 再运行目标测试，确认通过。

### Task 2: 固定事务次数与恢复行为

**Files:**
- Modify: `tests/test_macos_patcher.rb`
- Modify: `claude-easy/scripts/macos/patch_profiles/profile_writer.rb`
- Modify: `claude-easy/scripts/macos/patch_profiles/runtime.rb`
- Modify: `claude-easy/scripts/macos/patch_profiles/subscriptions.rb`

1. 先添加失败测试：同一客户端进程中更新加载和恢复加载各最多一次，重复恢复不得再次发送事件。
2. 运行目标测试，确认失败。
3. 在持久事务中记录客户端进程身份与已执行阶段，并在发送事件前原子更新。
4. 运行目标测试，确认通过。

### Task 3: 固定 Windows 等待与次数

**Files:**
- Modify: `tests/test_windows_installer.ps1`
- Modify: `claude-easy/scripts/install_windows.ps1`
- Modify: `claude-easy/scripts/windows/install_windows/runtime.ps1`

1. 先添加失败测试：文件变化后仍须等待 TUN、代理组、DNS 与连通性稳定；每阶段只允许一次客户端原生加载。
2. 运行 Windows 目标测试，确认旧实现失败。
3. 添加进程身份、阶段记录和条件等待，保持现有快捷键热加载。
4. 运行目标测试，确认通过。

### Task 4: 同步权威规则和用户说明

**Files:**
- Modify: `claude-easy/references/safe-update-and-recovery.md`
- Modify: `claude-easy/references/macos.md`
- Modify: `claude-easy/references/windows.md`
- Modify: `claude-easy/SKILL.md`
- Modify: `README.md`
- Modify: `tests/baseline.md`

只写现行行为：双端热加载、客户端原生入口、条件验证、每阶段一次、失败恢复。删除与新行为冲突的旧描述。

### Task 5: 完整验证与发布

1. 运行 macOS、Windows、合同和变异安全测试。
2. 运行 `git diff --check` 并审查改动只覆盖本次故障。
3. 提交并推送分支，合并到 `main` 后推送。
4. 把仓库 `claude-easy/` 同步安装到两份本地 Skill，并逐文件校验一致。
5. 删除工作树；只报告实际完成和实际运行的检查。
