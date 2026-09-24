---
name: claude-easy
description: Use when an agent needs to diagnose, analyze, or fix any macOS or Windows computer problem, or run a bounded observation window for an intermittent one; diagnose slow, intermittent, unavailable, misrouted, or leaking network behavior; safely update all Clash subscriptions or restore backups; or configure ClashX Meta or Clash Verge Rev for browsing, overseas AI, Claude, or Claude Code.
---

# ClaudeEasy 电脑诊断与网络配置

## 最高原则：用户沟通与执行

### 用户沟通原则

1. **所有回复固定使用简体中文。** 用户即使使用英文提问，也用简体中文回答；命令、路径、产品名和机器字段保留原文。
2. **所有沟通默认面向小白用户。** 用日常语言先说结果，不要求用户理解技术过程或替代理判断。进度消息、分析说明和最终回复都遵守以下规则。
3. **先结果，后必要变化。** 最终回复先说完成情况和复测结果，再按对象简述实际变化；详细清单仅在用户要求时展开。日常语言，不展示内部状态名、不罗列排查流水账、不反复道歉。无法完成时说清具体原因与剩余一项必要动作；没有用户能做的动作就直说限制，不要求无意义回复。订阅结果按 [safe-update-and-recovery.md](references/safe-update-and-recovery.md)；通用流程不因此读取网络策略。
4. **只保留帮助判断或行动的信息。** 进度只说原因判断或修复行动的新进展；最终回复遵守当前任务的交付要求。完整因果分析、工具调用、重试过程和原始日志留在内部；用户需要判断依据时再简述关键证据。敏感值不展示，用名称和“连接参数已变更”等描述代替；订阅链接、服务器地址、端口、密码、UUID 和密钥不得进入报告。不虚报完成，不追加无关提醒。
5. **过程问题由代理处理。** 工具报错、重试和中间状态不逐项播报；有安全的下一步就继续。确实需要用户参与时，只给一个明确动作，不让用户阅读排查记录或选择技术方案。

### 故障执行：定位原因并修复

**目标是查明原因并解决原始问题。报告简短不等于诊断可以停在症状。** 每次故障任务都必须在内部完成 Root Cause Analysis 和对应的 Fix Plan；这不是回复格式要求。

- **因果分析：** 沿症状追到产生故障的具体环节、触发条件和机制，用故障现场证据解释它如何导致用户遇到的问题，并核对关键反证。发现报错后继续查“为什么会报错”；翻译错误、确认断线、整理时间线或罗列健康检查，都不能代替原因判断。
- **修复方案与执行：** 把原因对应到具体对象、最小修复动作、成功判据和必要的恢复方法。修复请求中，已授权且可安全执行的动作继续做完，并用原场景验证；不能只写方案就结束。纯分析请求只交付因果分析与方案，不修改。临时绕过只能算缓解，不能代替原因定位或宣称修好。
- **完成门槛：** 确认症状不算完成诊断；原因未定位，或方案与原因没有因果对应时，任务仍未解决。继续取得能区分候选的证据，而非重复证明故障存在。确实无法取得必要证据时，保留未解决状态，说明具体缺口及下一项取证、不同结果对应的处理；不得编造原因、把排查计划当修复方案，或用“建议排查”“继续观察”冒充完成。

故障已恢复时，原因判断使用故障时间窗的证据；当前连通、一次替代路径成功或“本地未发现异常”不能证明历史原因、排除本地或确定远端责任。恢复不能归功于未执行或未验证的修复，不为交付方案而试改健康配置。

### 执行原则

1. **一句话触发完整闭环。** 代理按当前流程策略自行读取本机能取得的证据，连续完成检查、诊断、修复、复测；能自行取得的信息不得反问用户。
2. **没完成就继续做。** 一次方法失败时，先确认原状态，再沿受支持入口诊断、修复并继续剩余步骤。操作请求不能降格为只检查；中间成功、待验收列表不是收尾。用户催促或纠正属于继续原任务，不重新索要已给授权。
3. **共同安全边界允许的界面操作由代理完成。** 可靠脚本或结构化接口优先；必须点击正常应用窗口时使用当前会话实际提供的电脑操控（Computer Use）。用户明确要求更新、修复、配置、恢复或执行其他完整流程时，该授权包含 Skill 与本轮已读策略明确披露、且属于该流程固定步骤的界面操作、联网测试和数据传输；包括 DNS、WebRTC 与区域指纹测试按既有披露向测试服务发送公网 IP。不得把同一流程拆到每个页面或验收项重复询问；用户再说“直接操作”“直接做完”“不要停”或同义表达时更不得重复询问。该授权不扩展到流程外动作，也不覆盖工作台、操作系统或高风险动作实际触发的强制确认。
4. **只有真实阻塞才暂停。** 仅限密码、验证码、MFA、实体操作、系统权限弹窗、工具或系统实际要求的即时确认、不可恢复风险、外部服务确实不可用，或无法从本机证据消除的安全歧义。已披露并已授权的固定流程步骤不属于新的隐私确认或安全歧义。用户同时操作浏览器或页面状态变化时，重新读取状态、使用独立标签页并继续原流程；不得要求用户停止操作或回复后再继续。暂停时只说用户现在要做的一个动作；收到回复立即继续原流程。
5. **报告是交付的一部分。** 按当前流程保留足以说明变化的本轮前后证据，结束前核对报告覆盖用户要求的全部对象。脚本只返回成功或数量时，继续从本轮比对结果、备份和当前状态补齐明细；缺少 JSON 字段不是省略明细的理由。无法取得的内容明确标为未确认，不猜测，不为补报告重新更新或恢复配置。用户指出漏报时直接补查并交付报告，不停在解释要求或承诺补查。

## 共同安全边界

以下边界适用于 macOS、Windows、网络与通用流程，以及所有诊断、修复、复测和恢复。执行原则、完成闸门和界面授权均受本节约束；不得请求临时例外或以用户催促、测试、回滚为由绕过。

- **绝对禁止代理切换节点，任何情况都不允许。** 不得通过界面、控制器、API、脚本、配置或改变代理组选择直接或间接改换用户当前节点；不得先切换再恢复。只能读取当前选择和证据。正式更新与恢复入口只核验原选择，不主动写回；使用正式入口，不为每次更新重新搜索源码。入口实际失败或发现反证时再追踪实现。
- **节点建议保持同地区、同类型。** 怀疑当前节点有问题时，建议仅限与当前节点**同地区、同类型**的候选，由用户自己调整。例如台湾家宽 2 只建议台湾家宽 1；不得建议日本等其他地区，也不得从家宽改为普通或数据中心节点。先从现有配置确认候选地区与类型；不明确则不推荐，没有符合条件的候选就说明没有，不跨区或降级兜底。
- **AI 会话和工作台只读。** 包括 Claude、Claude Code、Codex、ChatGPT、Cursor 等桌面应用、网页、终端交互会话及内置工具。Computer Use 仅可读取已有画面、截图和界面状态；不得点击、输入、滚动、导航或刷新已有 AI 页面、切换会话、新建、Fork、重试、发送、继续、停止、关闭或重启。不得用 API、命令或其他工具绕过界面禁令操作 AI 会话、任务或进程。需要交互才能取得证据时，由用户自己操作；代理继续只读取日志和已有状态，不把任务副本当作无影响的测试环境。网络连通验收唯一例外：允许在用户指定或默认浏览器的新标签页打开 `https://chatgpt.com/`，只读取页面加载状态；不登录、不输入、不发送消息、不操作会话、不改已有标签页。遇到认证页只记录证据，不把登录操作纳入测试。其他 AI 页面仍不得主动打开。

1. **绝对不要退出、停止或重启 Clash 客户端或其内核。** 适用于 ClashX Meta、Clash Verge Rev，以及 Mihomo 与辅助进程。不得执行、建议或要求用户这样做。
2. **不得运行 Clash 客户端主程序做检查。** 禁止直接执行 ClashX Meta 或 Clash Verge Rev 主程序、传入 `--version`、用 `open`/LaunchServices 打开应用，或通过 Computer Use 启动未运行的客户端。不得用于诊断、审查、测试、版本查询或只读探测。这些动作可能创建第二个客户端并中断现有 Mihomo。macOS 客户端版本只从 `Info.plist` 读取；实时状态读取进程、日志、偏好或本地控制器；内核版本只检查 Mihomo。客户端未运行时保持未运行；无法取得实时状态时只在机器结果标记未验证，不能为检查而启动。通用流程不得把任一 Clash 客户端当作普通应用启动、退出、停止、重启或 Computer Use 操作。Clash 当应用的取证只走日志、崩溃报告、进程快照。Windows 网络流程操作已经运行的 Clash Verge Rev 见下文平台界面能力。

## 内部路由

触发后、读取任何策略文件之前，按用户原话完成一次内部分流。内部路由名为 `legacy_network` 或 `general_computer`，只供代理使用：不向用户展示，也不询问属于哪类问题。

- 用户明确描述网络访问、连接速度、DNS、代理、分流、网络泄漏、订阅、节点、TUN、系统代理，或要把 Clash 当网络/配置问题处理：内部路由为 `legacy_network`。
- 只提到 Clash 客户端崩溃、卡住、占 CPU 或窗口打不开，且没有上一则网络症状：内部路由为 `general_computer`。
- 其他请求，包括无法从原话确定的模糊问题：内部路由为 `general_computer`。

若内部路由为 `general_computer`，只有原始问题随后被证明符合上文 `legacy_network` 条件时才转入，并停止通用分支写入、携带已取得事实。Clash 崩溃、卡住、占 CPU 或窗口打不开不得转入，即使日志出现代理端口、TUN 或监听地址。发现 Clash 进程不等于属于网络。

本文件保留代理入口、内部分流、共同边界、执行顺序和不可突破的安全边界。网络模块选择只属于网络流程。

## 通用流程

内部路由为 `general_computer` 时，只完整阅读 [references/general-diagnostics.md](references/general-diagnostics.md)，再按当前平台完整阅读 [references/general-macos.md](references/general-macos.md) 或 [references/general-windows.md](references/general-windows.md)，不得读取另一平台后混用规则。不得读取 [references/policy-core.md](references/policy-core.md)、[references/diagnostics.md](references/diagnostics.md)、[references/profiles-and-patch.md](references/profiles-and-patch.md)、[references/routing-and-security.md](references/routing-and-security.md)、[references/safe-update-and-recovery.md](references/safe-update-and-recovery.md)、[references/macos.md](references/macos.md)、[references/windows.md](references/windows.md)、[references/policy.json](references/policy.json) 或 [references/result-contract.json](references/result-contract.json)。不套用网络用途档位、Patch、订阅、DNS、WebRTC 或 Mihomo 完成闸门。判断、取证、修复和复测以通用策略与当前平台文件为准。按 `general-diagnostics.md` 自动执行低风险、可恢复且属于用户请求的修复。

## 网络流程

内部路由为 `legacy_network` 时执行本节全部规则。完整执行现有网络策略读取路由、平台边界和完成闸门。

**完成闸门不通过不得收尾。** Patch、更新、恢复或修复必须通过 [profiles-and-patch.md](references/profiles-and-patch.md) 的当前档位完成清单；任一必要项失败就继续诊断、修复和复测。

### 策略读取路由

所有网络任务先完整阅读 [references/policy-core.md](references/policy-core.md)，再按下表读取任务模块。纯订阅检查只读表中指定小节；其他任务完整读取所选文件及当前平台的 [references/macos.md](references/macos.md) 或 [references/windows.md](references/windows.md)，不得读取另一平台后混用规则。

| 任务 | 必须读取 | 条件追加 |
| --- | --- | --- |
| Diagnostics：慢、间歇失败、打不开、全红、分流异常或泄漏 | [references/diagnostics.md](references/diagnostics.md)；当前平台文件 | 涉及共同国内直连、DNS、TUN、代理组、AI 或 WebRTC 时读 [references/routing-and-security.md](references/routing-and-security.md)；需要改档或执行 Patch 时再读档位文件 |
| Patch：首次安装、改变用途档位或完整安全增强 | [references/profiles-and-patch.md](references/profiles-and-patch.md)、[references/routing-and-security.md](references/routing-and-security.md)；当前平台文件 | Windows 完整配置、备份恢复或未完成事务时读 [references/safe-update-and-recovery.md](references/safe-update-and-recovery.md) |
| 只检查订阅是否有更新 | [只检查订阅](references/safe-update-and-recovery.md#只检查订阅)（含两端读取要求，按当前平台执行） | 入口实际失败时才追踪相关实现；不读 Patch、恢复或浏览器验收章节 |
| 更新全部订阅 | [references/safe-update-and-recovery.md](references/safe-update-and-recovery.md)、[references/profiles-and-patch.md](references/profiles-and-patch.md)、[references/routing-and-security.md](references/routing-and-security.md)；当前平台文件 | 无 |
| 列出、比较或恢复备份 | [references/safe-update-and-recovery.md](references/safe-update-and-recovery.md)、[references/profiles-and-patch.md](references/profiles-and-patch.md)；当前平台文件 | 恢复后验证 DNS、分流、AI 或 WebRTC 时读 [references/routing-and-security.md](references/routing-and-security.md) |
| AdGuard 配置或恢复 | [references/adguard.md](references/adguard.md)；当前平台文件 | 仅用户明确要求配置、恢复或导入 AdGuard 时读取 |
| 维护、审查或测试 Skill | 与改动直接相关的策略文件 | 只有跨模块维护、权威归属审查或整体一致性检查才读取全部七个策略文件 |

配置常量只读取 [references/policy.json](references/policy.json)；生成或判断机器输出时读取 [references/result-contract.json](references/result-contract.json)。全部状态以 `policy-core.md` 的“输出格式”和 `result-contract.json` 为准。各网络策略文件按上表分别成为其模块的唯一权威来源。

### 平台界面能力

AdGuard 是高级可选能力：默认不检测、不安装、不配置，也不因发现 AdGuard 进程或窗口而自动启用。只有用户明确说“配置 AdGuard”“恢复 AdGuard 配置”或“导入 AdGuard 备份”时，才读取 `references/adguard.md` 并使用 Computer Use 操作已经运行或可见的 AdGuard 窗口。

每次配置或修复先按共同安全边界排除禁止操作的目标，再检查当前会话的工具清单，只有实际可调用、且能操作该目标窗口的电脑操控工具才算这项动作已启用。需要打开网页或运行网页检测时，使用 Computer Use 操作用户指定浏览器，未指定时用默认浏览器；不得使用 Codex 或其他工作台的内置浏览器打开内容，不限制 Safari、Chrome、Edge 或其他浏览器。只会控制浏览器标签页时，不能用来改系统设置或点 Clash。没有工具时，从运行环境读取当前工作台；能够识别时只查询该产品的最新官方说明，不凭产品名猜测能力。Codex 与 ZCode by Z.ai 已知支持电脑操控，但仍以当前会话是否提供工具为准；支持而未启用时，给出当前平台的官方启用步骤并等待用户完成。当前工作台不支持时，建议改用支持电脑操控的工作台；若本档位后续不需要任何界面动作，继续自动流程，不为能力检测单独阻塞。

启用引导先读取当前会话实际提供的工具及其说明，区分正常应用窗口操控与浏览器标签页操控；能列出 Chrome 窗口不代表能可靠读取网页 URL，浏览器未连接也不代表全部电脑操控不可用。只有工具说明、当前可见界面或该工作台当前平台的官方说明确认过的入口才能告诉用户；不得凭记忆编造“设置 → 计算机使用”等菜单，或把另一工作台的插件步骤照搬过来。用户说找不到入口时先核对实际界面，不重复同一路径。工具强制拒绝不得绕过；Windows 目标无法操作时按平台文件交接该动作，其余安全取证继续。

用户明确要求“使用 Computer Use 代为操作电脑”时，视为本轮相关电脑操作已经授权；不得再询问“是否同意”或要求回复授权。只在系统强制的密码、验证码、MFA、权限弹窗或工具策略即时确认时暂停；授权范围仍限于用户明确请求的操作，不扩展到无关动作。

- **Windows：** 有电脑操控时操作已经运行的 Clash Verge Rev、用户默认浏览器和其他正常窗口；没有时先用安全脚本，只有确实不存在自动入口的界面动作才交给用户。
- **macOS：** 不用电脑操控附加 ClashX Meta；客户端开关走 [macos.md](references/macos.md) 原生命令。用户默认浏览器、AdGuard、系统设置等正常窗口由电脑操控完成。

### 不可突破的边界

1. **Clash 启停禁令见上文共同安全边界。**
2. **不得运行 Clash 客户端主程序做检查。** 细节见共同安全边界。
3. **Claude/Anthropic 远程域名永久禁测；** AI 联网与分流验收只测 ChatGPT、Gemini 和 Grok。细节见 [policy-core.md](references/policy-core.md) 与 [profiles-and-patch.md](references/profiles-and-patch.md) 区域指纹闭环。
4. 只按已保存用途档位操作，不切换订阅、代理组或节点，不覆盖第三方 PAC。macOS 只通过原生开关协调命令修改 ClashX Meta 的 TUN 和系统代理；Windows 按 [windows.md](references/windows.md) 操作 Clash Verge Rev；AdGuard for Mac 只通过它自己的正常窗口调整兼容设置。
5. 更新请求直接运行正式更新入口；普通更新、强制重写与 Windows 客户端刷新见 [safe-update-and-recovery.md](references/safe-update-and-recovery.md)。
6. 只处理 Clash 当前存储位置中的订阅；macOS 存储偏好缺失、且当前订阅只在本地目录唯一出现时自动按本地处理。仍存在多个匹配位置时才停止对应写入。见 [macos.md](references/macos.md)。
7. 写入候选必须通过 YAML 重读、二次转换一致性检查和 Mihomo 1.19.27 以上版本的 30 秒校验；失败时保持原文件。见 [policy-core.md](references/policy-core.md)。
8. 用户可见沟通遵守本文件开头的简体中文与小白表达规则。

### 模块选择

- **Patch 模块**：首次安装、改变用途档位，或用户明确要求配置网络时使用；只应用该档位的最少能力。
- **Diagnostics 模块**：慢、间歇失败、打不开、全红、分流异常或泄漏时使用。不能因为用户提到 Clash 就先运行补丁。
- **订阅检查与更新**：用户询问是否有更新，或明确要求更新全部订阅时使用；它不是 Patch 或 Diagnostics 的隐含步骤。

如果本次由 schedule task 触发，第一步运行 `scripts/check_skill_update.sh`（macOS）或 `scripts/check_skill_update.ps1`（Windows）检查 GitHub 版本；返回 `skill_updated` 时重新读取已安装的 `SKILL.md`，再按新版本继续。随后按本次请求选择只检查或更新入口。

### 平台入口

#### macOS

```bash
bash scripts/install_macos.sh --profile N
bash scripts/install_macos.sh --show-profile
bash scripts/uninstall_macos.sh
ruby scripts/macos/patch_profiles.rb --reconcile-client-switches --usage-profile N --json
ruby scripts/macos/verify_routes.rb
```

#### Windows

```powershell
.\scripts\install_windows.cmd -UsageProfile N
.\scripts\install_windows.cmd -ShowUsageProfile
.\scripts\install_windows.cmd -SnapshotProfiles -Json
.\scripts\install_windows.cmd -BeginSafeUpdateRefresh -Json
# Computer Use 完成本轮“更新所有订阅”后
.\scripts\install_windows.cmd -VerifySafeUpdate -RefreshConfirmed -Json
.\scripts\uninstall_windows.cmd
powershell.exe -NoProfile -File scripts/windows/verify_routes.ps1
```

Windows 运行中配置修改、恢复与加载验收见 [windows.md](references/windows.md)。
