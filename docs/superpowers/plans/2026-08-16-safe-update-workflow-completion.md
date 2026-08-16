# Safe Update Workflow Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent a successful subscription-update command from being reported as the completed user task before every saved-profile check is finished.

**Architecture:** Keep platform commands responsible for deterministic file and runtime transactions, and expose that limited scope through optional machine fields. Keep full workflow order in the safe-update policy and make `SKILL.md` forbid completion while required checks remain.

**Tech Stack:** Ruby, POSIX shell, PowerShell, Markdown policies, Minitest.

## Global Constraints

- Preserve `safe_update_completed` and `safe_update_verified` for compatibility.
- Never restart, stop, or switch Clash, subscriptions, proxy groups, or nodes.
- Keep detailed profile acceptance rules in `profiles-and-patch.md`.
- A missing or incomplete required check continues automatically unless user action is truly unavoidable.

---

### Task 1: Machine-readable incomplete workflow result

**Files:**
- Modify: `claude-easy/references/result-contract.json`
- Modify: `claude-easy/scripts/macos/result_contract.rb`
- Modify: `claude-easy/scripts/macos/patch_profiles/cli.rb`
- Modify: `claude-easy/scripts/install_macos.sh`
- Modify: `claude-easy/scripts/windows/result_contract.ps1`
- Modify: `claude-easy/scripts/windows/install_windows/common.ps1`
- Modify: `claude-easy/scripts/install_windows.ps1`
- Test: `tests/test_macos_patcher.rb`
- Test: `tests/test_macos_wrappers.rb`
- Test: `tests/test_windows_installer.ps1`

**Interfaces:**
- Produces: optional `workflow_complete`, `completed_scope`, and `required_followups` fields in JSON v1.
- Consumes: existing safe-update success results and wrapper child-result merging.

- [ ] Add failing contract and platform tests for the three fields.
- [ ] Run targeted tests and confirm failures describe missing fields.
- [ ] Extend both result builders and macOS child-result merging.
- [ ] Emit `workflow_complete: false` with profile-specific follow-ups from successful safe-update results.
- [ ] Run targeted tests and confirm they pass.

### Task 2: Mandatory full-flow policy

**Files:**
- Modify: `claude-easy/SKILL.md`
- Modify: `claude-easy/references/safe-update-and-recovery.md`
- Modify: `README.md`
- Modify: `tests/test_skill_contract.rb`
- Modify: `tests/baseline.md`

**Interfaces:**
- Consumes: machine fields from Task 1.
- Produces: one authoritative update sequence and a final-response prohibition while checks remain.

- [ ] Add failing contract assertions for the ordered workflow, automatic continuation, missing-baseline redo, and final completion rule.
- [ ] Run the contract test and confirm failure.
- [ ] Add the authoritative workflow to `safe-update-and-recovery.md` and concise entry rule to `SKILL.md`.
- [ ] Synchronize README and baseline summaries without duplicating policy details.
- [ ] Run the contract test and confirm it passes.

### Task 3: Full verification and release

**Files:**
- Verify all changed files.

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: tested repository and byte-identical installed Skill copies.

- [ ] Run macOS, wrapper, contract, browser, and Windows tests available on this host.
- [ ] Run formatting and diff checks.
- [ ] Commit the implementation.
- [ ] Fast-forward `main`, push it, and install `claude-easy/` into both configured Skill locations.
- [ ] Compare every installed file byte-for-byte, verify Git matches the remote, and remove the worktree.
