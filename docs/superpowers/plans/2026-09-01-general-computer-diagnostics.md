# ClaudeEasy 通用电脑诊断第一阶段 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不改变现有网络能力的前提下，为 ClaudeEasy 增加一个覆盖所有非网络电脑问题的通用判断流程，并通过唯一入口自动分流。

**Architecture:** `claude-easy/SKILL.md` 只增加顶层分流、共同执行边界和新策略路由。明显网络问题继续进入现有网络流程；其他问题进入独立的通用判断流程。第一阶段只增加策略，不创建全量采集器、后台服务或通用诊断脚本。

**Tech Stack:** Markdown Skill policies, YAML agent metadata, Ruby/Minitest existing contract suite, macOS and Windows native tools, Codex Computer Use when actually available.

**Spec:** `docs/superpowers/specs/2026-09-01-general-computer-diagnostics-design.md`

## Global Constraints

- 默认同时支持 macOS 与 Windows；共同能力只有两端都实现并验证后才能报告完成。
- 现有网络策略文件、`policy.json`、`result-contract.json` 和 `claude-easy/scripts/**` 不修改。
- 网络任务的现有用途档位、Patch、Diagnostics、安全更新、备份恢复和完成闸门保持现行行为。
- 新流程覆盖所有非网络电脑问题，不创建故障类别、支持清单或专项优先方向。
- 不创建全量状态采集器、永久监控、后台任务或未经真实失败证明的辅助脚本。
- 每项检查必须能够区分当前判断或补齐明确证据缺口；结果不改变下一步时跳过。
- 低风险、可恢复且在用户请求范围内的动作自动执行；只有真实阻塞或明确的数据与恢复风险才询问用户。
- 不向 `tests/` 添加锁定文案、标题、文件布局或固定关键词的 prose test。
- README 只描述用户可见行为；Skill 保存入口和立即可见边界；策略文件各自只有一个权威职责。
- 完成前必须提交、合并到 `main`、推送，并把仓库中的 `claude-easy/` 同步到 `/Users/wallny/.codex/skills/claude-easy/` 后逐文件验证一致。

## File Structure

- Modify: `AGENTS.md` — 增加通用分支的规则归属和第一阶段隔离要求。
- Modify: `README.md` — 解释一个入口、两套流程以及通用流程的用户可见行为。
- Modify: `claude-easy/SKILL.md` — 扩展触发范围；增加顶层分流、共同边界和通用策略读取路由；现有网络行为不变。
- Modify: `claude-easy/agents/openai.yaml` — 让 Skill 可由全部电脑诊断、分析和修复请求触发。
- Create: `claude-easy/references/general-diagnostics.md` — 通用判断、证据选择、自动修复、复测、内部状态和经验沉淀的唯一权威来源。
- Create: `claude-easy/references/general-macos.md` — macOS 的按需取证、Computer Use、权限、修改和恢复边界。
- Create: `claude-easy/references/general-windows.md` — Windows 的按需取证、Computer Use、权限、修改和恢复边界。

不修改 `.github/workflows/test.yml`、`tests/baseline.md` 或现有测试拓扑。新功能是指令级行为，目前没有能在低层自动判断语义效果的稳定接口；使用现有结构测试、网络回归和安装后的真实 Skill smoke 验收，避免用关键词断言伪造覆盖。

---

### Task 1: 建立通用判断策略

**Files:**
- Create: `claude-easy/references/general-diagnostics.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: `claude-easy/SKILL.md` 传入的用户原始请求、当前平台、当前工具能力和分流结果。
- Produces: 通用流程的唯一判断循环；平台文件和顶层入口只能引用，不得重新定义。

- [ ] **Step 1: 读取约束并确认当前网络基线**

Run:

```bash
git status --short
ruby tests/test_skill_contract.rb
ruby tests/test_ci_scope.rb
```

Expected: 工作树没有未知修改；两套测试均为 `0 failures, 0 errors`。如基线失败，先调查，不在本功能中掩盖。

- [ ] **Step 2: 创建通用判断策略**

`claude-easy/references/general-diagnostics.md` 必须按以下职责组织：

```markdown
# ClaudeEasy 通用电脑诊断策略

## 工作目标与完成状态
## 原始问题与原场景
## 候选解释
## 下一项检查的选择合同
## 判断更新与诊断重置
## 证据满足条件与停止检查
## 自动修复、恢复与复测
## Computer Use 与其他工具
## 间歇性问题与观察窗口
## 经验沉淀与产品改进
## 用户沟通与真实阻塞
```

写入以下强制行为：

- 不预设故障类别，不运行固定检查清单。
- 先观察原始应用、动作、时间和影响范围；能自行取得的信息不问用户。
- 候选解释必须能够解释已知现场，并明确支持证据、反证、下一项验证和不同结果的后续行动。
- 检查只有在能够区分候选或补齐明确缺口时执行；不能改变下一步的检查直接跳过。
- 选择顺序为区分能力、决策价值、现象覆盖、时间与风险、用户介入。
- 连续两项检查没有缩小范围时，回到原始问题执行诊断重置；没有新证据不做第三次试改。
- 足以选择安全修复后立即停止采集。
- 修复前记录原状态和恢复方法；一次只改一个对象；失败或出现副作用立即恢复。
- 使用同一应用、账号、目标和动作复测；指标恢复不能代替原场景恢复。
- 内部状态固定为 `resolved`、`mitigated`、`observing`、`blocked`、`unresolved`。
- 经验只保存可识别现场、决定性验证、确认原因、修复、恢复、复测和反例；自然恢复与未经复测的修改不得固化。

- [ ] **Step 3: 更新规则归属**

在 `AGENTS.md` 的“执行”与“项目边界”中增加：

- 第一阶段为网络旧流程与通用新流程并行；两者独立读取策略。
- `general-diagnostics.md`、`general-macos.md`、`general-windows.md` 的唯一职责。
- 现有七个网络策略文件和全部网络脚本不得因通用分支而改变行为。
- 新通用能力默认双端同步；明确的平台差异分别写入平台文件。
- 真实案例未证明需要前，不新增通用采集器、后台监测或辅助脚本。

不要把通用判断规则复制进 `AGENTS.md`。

- [ ] **Step 4: 验证文档完整性和原有结构测试**

Run:

```bash
test -s claude-easy/references/general-diagnostics.md
git diff --check
ruby tests/test_skill_contract.rb
```

Expected: 文件非空；`git diff --check` 无输出；合同测试为 `0 failures, 0 errors`。

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md claude-easy/references/general-diagnostics.md
git commit -m "feat: define general computer diagnostics workflow"
```

---

### Task 2: 定义 macOS 与 Windows 平台边界

**Files:**
- Create: `claude-easy/references/general-macos.md`
- Create: `claude-easy/references/general-windows.md`

**Interfaces:**
- Consumes: `general-diagnostics.md` 产生的一个明确证据问题或一个已确认修复对象。
- Produces: 当前平台可靠的最小取证或安全操作方式，以及权限、恢复和工具缺失状态。

- [ ] **Step 1: 创建 macOS 平台策略**

`general-macos.md` 使用以下结构：

```markdown
# ClaudeEasy 通用诊断 macOS 策略

## 能力检测
## 原场景与界面操作
## 按问题选择系统证据
## 日志和历史时间窗
## 权限与安全修改
## 恢复与复测
## 平台限制
```

要求：

- Computer Use 只有当前会话实际可调用且能操作目标窗口时才算可用；每次操作后回读界面结果。
- shell、统一日志、进程、文件系统、性能和电源工具只按 `general-diagnostics.md` 提出的明确问题调用，不形成启动清单。
- 不无边界扫描用户文件，不读取与当前问题无关的内容字段。
- 可以安全启动或操作用户要求诊断的普通应用；ClashX Meta 仍受现有网络分支永久边界约束。
- 退出应用、结束进程、删除缓存、修复磁盘、重启、重装和降级按实际数据与恢复风险决定授权，不能为了省事执行。
- 间歇问题的采集必须有范围、开始时间、停止条件和清理方法。

- [ ] **Step 2: 创建 Windows 平台策略**

`general-windows.md` 使用与 macOS 文件相同的职责结构，并明确：

- Computer Use 操作正常 Windows 应用、Task Manager、Settings 或其他必要界面时，先确认工具实际可用，操作后回读结果。
- PowerShell、Event Viewer、Reliability Monitor、性能计数器、进程和文件系统证据只回答当前明确问题。
- 不把管理员权限当作默认；需要权限时由当前工具触发系统授权，不能让用户复制长命令。
- 结束进程、清理、Repair、重启、重装和降级遵守与 macOS 相同的风险和恢复结果。
- 不能把 macOS 的命令、日志来源或应用行为照搬到 Windows。

- [ ] **Step 3: 检查职责没有重复**

人工逐节比较三个新策略文件：通用文件只定义如何判断；平台文件只定义如何取得证据和安全执行。删除任何重复定义的判断门槛、完成状态或用户沟通规则。

Run:

```bash
git diff --check
ruby tests/test_skill_contract.rb
```

Expected: 无空白错误；合同测试为 `0 failures, 0 errors`。

- [ ] **Step 4: Commit**

```bash
git add claude-easy/references/general-macos.md claude-easy/references/general-windows.md
git commit -m "feat: add cross-platform general diagnostics policies"
```

---

### Task 3: 增加唯一分流入口并保护网络旧流程

**Files:**
- Modify: `claude-easy/SKILL.md`
- Modify: `claude-easy/agents/openai.yaml`

**Interfaces:**
- Consumes: 用户原始请求。
- Produces: `legacy_network` 或 `general_computer` 内部路由；路由不展示给用户，也不要求用户选择。

- [ ] **Step 1: 扩展 Skill 触发描述**

保持 `name: claude-easy`，把 frontmatter description 改为同时覆盖：

- 任意 macOS 或 Windows 电脑故障的诊断、分析、修复或监测；
- 现有慢、间歇失败、不可访问、错误分流和泄漏网络问题；
- ClashX Meta、Clash Verge Rev 配置、订阅更新和备份恢复。

描述必须先表达“所有电脑问题”，再列网络专用能力，避免隐式触发仍局限于 Clash。

- [ ] **Step 2: 在任何策略读取前增加内部路由**

在 `SKILL.md` 中写入等价于以下逻辑的命令式规则：

```text
if 用户明确描述网络访问、连接速度、DNS、代理、分流、泄漏、Clash、订阅、节点、TUN 或系统代理:
    route = legacy_network
else:
    route = general_computer

if route == general_computer and 后续证据确认问题属于网络:
    停止通用分支写入
    携带已取得事实转入 legacy_network
```

分流要求：

- 不向用户询问属于哪类问题。
- 模糊请求默认通用流程。
- `legacy_network` 完整执行现有网络策略读取路由、平台边界和完成闸门。
- `general_computer` 只读 `general-diagnostics.md` 与当前平台文件；不读取网络用途档位、Patch、订阅、DNS、WebRTC 或 Mihomo 策略。

- [ ] **Step 3: 把共同规则与分支规则划清**

`SKILL.md` 共同规则只保留两条流程都适用的用户沟通、连续执行、真实阻塞和一般安全边界。网络分支继续保留现有以下行为：

- Computer Use 操作网络相关系统或浏览器设置前的一次即时授权；
- ClashX Meta 不启动、不退出、不停止、不重启；
- Claude/Anthropic 远程域名永久禁测；
- 用途档位约束、订阅和节点不擅自切换；
- 当前档位完成闸门。

通用分支按新策略自动执行低风险可恢复操作，不继承网络档位和完成闸门。不要删除或放宽任何网络永久边界。

- [ ] **Step 4: 更新 agent metadata**

`claude-easy/agents/openai.yaml` 保持现有字段，只扩大可发现范围。目标语义：

```yaml
interface:
  display_name: "ClaudeEasy 电脑诊断与网络配置"
  short_description: "自动诊断并修复 macOS、Windows 和 Clash 网络问题"
  default_prompt: "使用 $claude-easy 自动分析、诊断、修复或监测用户的电脑问题；明显网络问题继续使用现有网络流程，其他问题使用通用判断流程。"
```

可以压缩措辞，但不能改变分流含义。

- [ ] **Step 5: 确认网络实现文件没有变化**

Run from the feature worktree:

```bash
base="$(git merge-base HEAD main)"
git diff --exit-code "$base" -- \
  claude-easy/references/diagnostics.md \
  claude-easy/references/macos.md \
  claude-easy/references/policy-core.md \
  claude-easy/references/policy.json \
  claude-easy/references/profiles-and-patch.md \
  claude-easy/references/result-contract.json \
  claude-easy/references/routing-and-security.md \
  claude-easy/references/safe-update-and-recovery.md \
  claude-easy/references/windows.md \
  claude-easy/scripts
```

Expected: no output and exit status `0`. If `main` advanced after worktree creation, compare against the exact branch-point commit shown by `git merge-base` and inspect any upstream change before proceeding.

- [ ] **Step 6: Run structure tests and commit**

```bash
ruby tests/test_skill_contract.rb
ruby tests/test_ci_scope.rb
git diff --check
git add claude-easy/SKILL.md claude-easy/agents/openai.yaml
git commit -m "feat: route computer problems to general diagnostics"
```

Expected: both test suites pass, whitespace check is empty, and commit succeeds.

---

### Task 4: 更新用户文档

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: 已完成的顶层分流和通用判断行为。
- Produces: 不重新定义策略的用户可见说明。

- [ ] **Step 1: 改写 README 开头和能力说明**

README 必须先说明 ClaudeEasy 是 macOS 与 Windows 的通用电脑诊断和修复 Skill，同时保留 Clash 网络配置能力。

新增简短的“电脑故障诊断”说明：

- 用户只描述问题，不需要选择故障类型。
- 网络问题仍使用成熟的原网络流程。
- 其他问题使用按证据动态选择下一步的通用流程。
- 不进行固定全面体检，不采集与当前判断无关的数据。
- 能自行读取或操作的事情由代理完成，只有真实阻塞才请用户参与。

现有用途档位、网络能力、安全边界、命令和限制保持原义。不要在 README 复制通用策略的判断门槛或内部状态。

- [ ] **Step 2: 检查 README 与策略一致**

人工核对：README 没有承诺“所有问题一定自动修好”，也没有把第一阶段描述成网络已经并入通用流程。

Run:

```bash
git diff --check
ruby tests/test_skill_contract.rb
```

Expected: 无空白错误；合同测试为 `0 failures, 0 errors`。

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: explain general computer diagnostics"
```

---

### Task 5: 验证、安装、合并和交付

**Files:**
- Verify only: all changed files
- Install target: `/Users/wallny/.codex/skills/claude-easy/`

**Interfaces:**
- Consumes: Tasks 1–4 的完成提交。
- Produces: 通过本地测试、真实路由 smoke、安装校验、`main` 推送和清理后的最终交付。

- [ ] **Step 1: 运行本机可执行的完整相关测试**

```bash
ruby tests/test_skill_contract.rb
ruby tests/test_ci_scope.rb
ruby tests/test_macos_patcher.rb
ruby tests/test_macos_wrappers.rb
ruby tests/run_macos_production_probes.rb
node --check claude-easy/scripts/windows/clash_verge_global.js
node --test tests/test_windows_patcher.js
node --test tests/test_region_fingerprint_page.js
git diff --check
```

Expected: 所有命令成功。只报告实际运行结果；Windows PowerShell 测试只有在 Windows 或 CI 实际执行并读取结果后才能称为通过。

- [ ] **Step 2: 安装后执行真实 Skill smoke**

在不会修改真实网络配置和用户数据的分析模式下，分别运行：

```text
使用 $claude-easy：Clash 节点全部不可用，只分析，不修改。
使用 $claude-easy：电脑最近明显变慢，只分析，不修改。
使用 $claude-easy：一个普通应用打开后立即退出，只分析，不修改。
```

验收：

- 网络请求进入现有网络流程，不使用通用策略代替用途档位和网络证据规则。
- 两个非网络请求进入通用流程，不读取用途档位，不运行 Clash 安装器，不做全量体检。
- 非网络流程先观察原场景或已有证据，只执行能够改变下一步的检查。
- 能从本机取得的信息不反问用户。

记录实际工具调用和结果供最终说明；不把模型自述当成路由证据。

- [ ] **Step 3: 检查第一阶段没有越界**

```bash
git status --short
git diff --stat "$(git merge-base HEAD main)" HEAD
git diff --check "$(git merge-base HEAD main)" HEAD
```

Expected: 只出现本计划列出的文件；没有通用脚本、后台服务、故障分类文件、网络策略或网络脚本修改。

- [ ] **Step 4: 提交遗漏的验收修正**

只有 smoke 暴露了本计划范围内的路由、策略或文档问题时才修改对应文件，然后重新运行受影响测试并提交：

```bash
git add AGENTS.md README.md claude-easy/SKILL.md claude-easy/agents/openai.yaml claude-easy/references/general-*.md
git commit -m "fix: complete general diagnostics routing"
```

如果没有修正，跳过本步骤，不创建空提交。

- [ ] **Step 5: 合并到 main 并推送**

按根目录 `AGENTS.md` 使用非交互式 git 流程，不创建 PR：

```bash
cd /Users/wallny/Developer/Skills/ClaudeEasy
git status --short
git merge --ff-only codex/general-computer-diagnostics
git push origin main
```

实现开始时固定创建 `.worktrees/general-computer-diagnostics` 和 `codex/general-computer-diagnostics`，不要临时改名。无法 fast-forward 时停止并检查分叉，不自动变基或覆盖用户提交。

- [ ] **Step 6: 同步已安装 Skill 并逐文件验证**

在 `main` 推送成功后执行：

```bash
mkdir -p /Users/wallny/.codex/skills/claude-easy
rsync -a --delete claude-easy/ /Users/wallny/.codex/skills/claude-easy/
diff -qr claude-easy /Users/wallny/.codex/skills/claude-easy
```

Expected: `diff -qr` 无输出且退出状态 `0`。失败时继续修复并重新验证，不能要求用户手动安装。

- [ ] **Step 7: 清理 worktree 并报告真实状态**

从主工作区确认 `main` 已包含实现提交且工作树干净，再删除明确的功能 worktree和已合并分支：

```bash
git worktree list
git worktree remove /Users/wallny/Developer/Skills/ClaudeEasy/.worktrees/general-computer-diagnostics
git branch -d codex/general-computer-diagnostics
git status --short
git log -5 --oneline
```

只有 `git worktree list` 确认该精确路径属于已合并功能分支时才执行删除；不要使用通配符。最终只报告实际运行的测试、安装校验、提交和推送状态。
