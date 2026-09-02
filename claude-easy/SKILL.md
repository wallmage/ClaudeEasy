---
name: claude-easy
description: Use when an agent needs to diagnose, analyze, or fix any macOS or Windows computer problem, or run a bounded observation window for an intermittent one; diagnose slow, intermittent, unavailable, misrouted, or leaking network behavior; safely update all Clash subscriptions or restore backups; or configure ClashX Meta or Clash Verge Rev for browsing, overseas AI, Claude, or Claude Code.
---

# ClaudeEasy 电脑诊断与网络配置

## 最高原则：用户沟通与执行

### 用户沟通原则

1. **所有回复固定使用简体中文。** 用户即使使用英文提问，也用简体中文回答；命令、路径、产品名和机器字段保留原文。
2. **所有沟通默认面向小白用户。** 用日常语言先说结果，不要求用户理解技术过程或替代理判断。进度消息、分析说明和最终回复都遵守以下规则。
3. **默认隐藏不必要的细节。** 技术术语、排查过程、机器状态、统计数字和附带例外留在内部；只有用户主动追问，或信息会影响实际使用、安全、必要决定或下一步行动时，才说明所需的最少内容。不因为细节真实、已经查到或显得严谨就展示。
4. **按用户目标报告结果。** 完成时通常一句话即可，没有必要行动就结束；不追加无关提醒、保留话或免责声明，不把不影响任务结果的细节说成遗留问题、完成不足或继续处理的理由。确实未达到用户目标或存在实际风险时，如实说明影响和必要行动，不隐瞒、不虚报完成。
5. **过程问题由代理处理。** 工具报错、重试和中间状态不逐项播报；有安全的下一步就继续。确实需要用户参与时，只给一个明确动作，不让用户阅读排查记录或选择技术方案。

### 执行原则

1. **一句话触发完整闭环。** 代理按当前流程策略自行读取本机能取得的证据，连续完成检查、诊断、修复、复测；能自行取得的信息不得反问用户。
2. **没完成就继续做。** 一次方法失败时，先确认没有破坏原状态，再换用安全证据或受支持入口继续；不得把未完成状态当作收尾，也不得让用户替代理分析技术问题。
3. **界面操作由代理完成。** 可靠脚本或结构化接口优先；必须点击正常应用窗口时使用当前会话实际提供的电脑操控（Computer Use）。工作台、操作系统或高风险动作强制要求的确认仍照常执行。
4. **只有真实阻塞才暂停。** 仅限密码、验证码、MFA、实体操作、系统权限弹窗、工具策略要求的即时确认、不可恢复风险、外部服务确实不可用，或无法从本机证据消除的安全歧义。暂停时只说用户现在要做的一个动作；收到回复立即继续原流程。

## 共同安全边界

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

所有网络任务先完整阅读 [references/policy-core.md](references/policy-core.md)，再按下表读取任务模块；每个选中的文件都要完整阅读。按当前平台读取 [references/macos.md](references/macos.md) 或 [references/windows.md](references/windows.md)，不得读取另一平台后混用规则。

| 任务 | 必须读取 | 条件追加 |
| --- | --- | --- |
| Diagnostics：慢、间歇失败、打不开、全红、分流异常或泄漏 | [references/diagnostics.md](references/diagnostics.md)；当前平台文件 | 涉及共同国内直连、DNS、TUN、代理组、AI 或 WebRTC 时读 [references/routing-and-security.md](references/routing-and-security.md)；需要改档或执行 Patch 时再读档位文件 |
| Patch：首次安装、改变用途档位或完整安全增强 | [references/profiles-and-patch.md](references/profiles-and-patch.md)、[references/routing-and-security.md](references/routing-and-security.md)；当前平台文件 | 涉及备份恢复或未完成事务时读 [references/safe-update-and-recovery.md](references/safe-update-and-recovery.md) |
| 更新全部订阅 | [references/safe-update-and-recovery.md](references/safe-update-and-recovery.md)、[references/profiles-and-patch.md](references/profiles-and-patch.md)、[references/routing-and-security.md](references/routing-and-security.md)；当前平台文件 | 无 |
| 列出、比较或恢复备份 | [references/safe-update-and-recovery.md](references/safe-update-and-recovery.md)、[references/profiles-and-patch.md](references/profiles-and-patch.md)；当前平台文件 | 恢复后验证 DNS、分流、AI 或 WebRTC 时读 [references/routing-and-security.md](references/routing-and-security.md) |
| AdGuard 配置或恢复 | [references/adguard.md](references/adguard.md)；当前平台文件 | 仅用户明确要求配置、恢复或导入 AdGuard 时读取 |
| 维护、审查或测试 Skill | 与改动直接相关的策略文件 | 只有跨模块维护、权威归属审查或整体一致性检查才读取全部七个策略文件 |

配置常量只读取 [references/policy.json](references/policy.json)；生成或判断机器输出时读取 [references/result-contract.json](references/result-contract.json)。全部状态以 `policy-core.md` 的“输出格式”和 `result-contract.json` 为准。各网络策略文件按上表分别成为其模块的唯一权威来源。

### 平台界面能力

AdGuard 是高级可选能力：默认不检测、不安装、不配置，也不因发现 AdGuard 进程或窗口而自动启用。只有用户明确说“配置 AdGuard”“恢复 AdGuard 配置”或“导入 AdGuard 备份”时，才读取 `references/adguard.md` 并使用 Computer Use 操作已经运行或可见的 AdGuard 窗口。

每次配置或修复先检查当前会话的工具清单，只有实际可调用、且能操作该目标窗口的电脑操控工具才算这项动作已启用。只会控制浏览器标签页时，不能用来改系统设置或点 Clash。没有工具时，从运行环境读取当前工作台；能够识别时只查询该产品的最新官方说明，不凭产品名猜测能力。Codex 与 ZCode by Z.ai 已知支持电脑操控，但仍以当前会话是否提供工具为准；支持而未启用时，给出当前平台的官方启用步骤并等待用户完成。当前工作台不支持时，建议改用支持电脑操控的工作台；若本档位后续不需要任何界面动作，继续自动流程，不为能力检测单独阻塞。

Codex 未启用时，按当前官方界面引导用户进入“设置 → 插件 → 电脑操控（Computer Use）”，安装并启用页面中的电脑操控插件；macOS 再开启系统要求的“屏幕录制”和“辅助功能”权限，Windows 只按当前应用显示的权限提示操作。界面名称变化时先查官方说明。其他工作台只给该产品当前平台的官方步骤。用户明确要求“使用 Computer Use 代为操作电脑”时，视为本轮相关电脑操作已经授权；不得再询问“是否同意”或要求回复授权。只在系统强制的密码、验证码、MFA、权限弹窗或工具策略即时确认时暂停；授权范围仍限于用户明确请求的操作，不扩展到无关动作。

- **Windows：** 有电脑操控时操作已经运行的 Clash Verge Rev、浏览器和其他正常窗口；没有时先用安全脚本，只有确实不存在自动入口的界面动作才交给用户。
- **macOS：** 不用电脑操控附加 ClashX Meta；客户端开关走 [macos.md](references/macos.md) 原生命令。Safari、Chrome、AdGuard、系统设置等正常窗口由电脑操控完成。

### 不可突破的边界

1. **Clash 启停禁令见上文共同安全边界。**
2. **不得运行 Clash 客户端主程序做检查。** 细节见共同安全边界。
3. **Claude/Anthropic 远程域名永久禁测；** AI 联网与分流验收只测 ChatGPT、Gemini 和 Grok。细节见 [policy-core.md](references/policy-core.md) 与 [profiles-and-patch.md](references/profiles-and-patch.md) 本地区域指纹闭环。
4. 只按已保存用途档位操作，不切换订阅、代理组或节点，不覆盖第三方 PAC。macOS 只通过原生开关协调命令修改 ClashX Meta 的 TUN 和系统代理；Windows 按 [windows.md](references/windows.md) 操作 Clash Verge Rev；AdGuard for Mac 只通过它自己的正常窗口调整兼容设置。
5. 安全更新第一步必须读取并比对全部远程订阅；全部相同时返回 `no_change` 且不修改，有变化时只更新变化目标并通过已经运行的客户端重新加载。流程与失败处理见 [safe-update-and-recovery.md](references/safe-update-and-recovery.md)。
6. 只处理 Clash 当前存储位置中的订阅；macOS 存储偏好缺失、且当前订阅只在本地目录唯一出现时自动按本地处理。仍存在多个匹配位置时才停止对应写入。见 [macos.md](references/macos.md)。
7. 写入候选必须通过 YAML 重读、二次转换一致性检查和 Mihomo 1.19.27 以上版本的 30 秒校验；失败时保持原文件。见 [policy-core.md](references/policy-core.md)。
8. 用户可见沟通遵守本文件开头的简体中文与小白表达规则。

### 模块选择

- **Patch 模块**：首次安装、改变用途档位，或用户明确要求配置网络时使用；只应用该档位的最少能力。
- **Diagnostics 模块**：慢、间歇失败、打不开、全红、分流异常或泄漏时使用。不能因为用户提到 Clash 就先运行补丁。
- **订阅更新**：用户明确要求更新全部订阅时使用；它不是 Patch 或 Diagnostics 的隐含步骤。

如果本次由 schedule task 触发，第一步运行 `scripts/check_skill_update.sh`（macOS）或 `scripts/check_skill_update.ps1`（Windows）检查 GitHub 版本；返回 `skill_updated` 时重新读取已安装的 `SKILL.md`，再按新版本继续。随后仍按订阅比对流程执行：先逐份读取远端配置，全部相同就结束，有变化只更新变化目标。

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
.\scripts\install_windows.cmd -SafeUpdateChangedOnly -Json
.\scripts\uninstall_windows.cmd
powershell.exe -NoProfile -File scripts/windows/verify_routes.ps1
```

Windows 客户端运行时的受保护写入边界见 [windows.md](references/windows.md)。
