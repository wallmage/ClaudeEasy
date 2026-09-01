# Windows Feature Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Windows route verification use the same concurrent three-site mechanism already used on macOS.

**Architecture:** Keep the existing Windows route checks and result contract, but run one isolated verifier probe per target through Windows-compatible background jobs. The parent preserves deterministic output order and aggregates every probe result before deciding success.

**Tech Stack:** PowerShell 5.1/7, existing JSON result contract, Ruby/Minitest contract tests.

**Spec:** `claude-easy/references/windows.md` and `claude-easy/references/safe-update-and-recovery.md`

## Global Constraints

- Windows must remain feature-equivalent with macOS for the three-site route verification.
- PowerShell 5.1 support is required.
- Claude/Anthropic domains remain excluded; targets stay ChatGPT, Gemini, and Grok.
- Preserve the existing JSON result contract and check order.
- Do not change unrelated network or general-diagnostics behavior.

---

### Task 1: Add a Windows concurrency regression

**Files:**
- Modify: `tests/test_skill_contract.rb`
- Test: `claude-easy/scripts/windows/verify_routes.ps1`

**Interfaces:**
- Consumes: the Windows route verifier source.
- Produces: a regression that requires a background-job fan-out and aggregate wait.

- [ ] **Step 1: Write the failing test**

Add `test_windows_route_targets_are_observed_concurrently`, asserting the verifier contains `Invoke-ParallelRouteProbes`, `Start-Job`, and `Wait-Job`, and no longer invokes three `Observe-Route` calls directly inside one sequential array.

- [ ] **Step 2: Run the focused test**

Run: `ruby tests/test_skill_contract.rb --name /windows_route_targets_are_observed_concurrently/`

Expected: FAIL because the current Windows verifier evaluates the three calls sequentially.

### Task 2: Implement parallel Windows probes

**Files:**
- Modify: `claude-easy/scripts/windows/verify_routes.ps1`
- Test: `tests/test_skill_contract.rb`

**Interfaces:**
- Consumes: existing `Observe-Route`, controller validation, and JSON result functions.
- Produces: private probe mode plus `Invoke-ParallelRouteProbes` returning ordered `{ Label, Passed, Status }` records.

- [ ] **Step 1: Add private probe parameters and child execution**

Add a private target parameter and secret handoff path. A child invocation performs the existing setup and exactly one `Observe-Route`, emits one JSON result, and exits with that probe status.

- [ ] **Step 2: Add the PowerShell 5.1-compatible fan-out**

Implement `Invoke-ParallelRouteProbes` with `Start-Job`, `Wait-Job`, `Receive-Job`, and `Remove-Job`; invoke the verifier once per target, pass the already validated controller context, and collect all results before returning.

- [ ] **Step 3: Replace the sequential call site**

Build the existing three target descriptors once, call the helper, append checks in ChatGPT/Gemini/Grok order, and fail only after all probes have completed.

- [ ] **Step 4: Run focused tests**

Run: `ruby tests/test_skill_contract.rb --name /windows_route_targets_are_observed_concurrently/` and `ruby tests/test_skill_contract.rb`.

Expected: PASS with zero failures.

### Task 3: Verify, commit, merge, and install

**Files:**
- Modify: none beyond Tasks 1–2.

- [ ] **Step 1: Run platform and contract verification**

Run the existing Ruby, Node, and syntax suites, plus the Windows CI workflow after push.

- [ ] **Step 2: Commit and push**

```bash
git add claude-easy/scripts/windows/verify_routes.ps1 tests/test_skill_contract.rb docs/superpowers/plans/2026-09-01-windows-feature-parity.md
git commit -m "fix: parallelize Windows route verification"
git push -u origin codex/windows-parity
```

- [ ] **Step 3: Merge to main and synchronize installation**

Merge the verified branch into `main`, push `main`, run `rsync -a --delete claude-easy/ /Users/wallny/.codex/skills/claude-easy/`, then confirm `diff -qr` is empty.
