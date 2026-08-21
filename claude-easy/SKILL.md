---
name: claude-easy
description: Use when an agent needs to diagnose slow, intermittent, unavailable, misrouted, or leaking network behavior; safely update all Clash subscriptions; or configure ClashX Meta or Clash Verge Rev for browsing, overseas AI, Claude, or Claude Code.
---

# ClaudeEasy 配置与诊断

## 策略读取路由

所有任务先完整阅读 [references/policy-core.md](references/policy-core.md)，再按下表读取任务模块；每个选中的文件都要完整阅读。按当前平台读取 [references/macos.md](references/macos.md) 或 [references/windows.md](references/windows.md)，不得读取另一平台后混用规则。

| 任务 | 必须读取 | 条件追加 |
| --- | --- | --- |
| Diagnostics：慢、间歇失败、打不开、全红、分流异常或泄漏 | [references/diagnostics.md](references/diagnostics.md)；当前平台文件 | 涉及共同国内直连、DNS、TUN、代理组、AI 或 WebRTC 时读 [references/routing-and-security.md](references/routing-and-security.md)；需要改档或执行 Patch 时再读档位文件 |
| Patch：首次安装、改变用途档位或完整安全增强 | [references/profiles-and-patch.md](references/profiles-and-patch.md)、[references/routing-and-security.md](references/routing-and-security.md)；当前平台文件 | 涉及备份恢复或未完成事务时读 [references/safe-update-and-recovery.md](references/safe-update-and-recovery.md) |
| 更新全部订阅 | [references/safe-update-and-recovery.md](references/safe-update-and-recovery.md)、[references/profiles-and-patch.md](references/profiles-and-patch.md)、[references/routing-and-security.md](references/routing-and-security.md)；当前平台文件 | 无 |
| 列出、比较或恢复备份 | [references/safe-update-and-recovery.md](references/safe-update-and-recovery.md)、[references/profiles-and-patch.md](references/profiles-and-patch.md)；当前平台文件 | 恢复后验证 DNS、分流、AI 或 WebRTC 时读 [references/routing-and-security.md](references/routing-and-security.md) |
| 维护、审查或测试 Skill | 与改动直接相关的策略文件 | 只有跨模块维护、权威归属审查或整体一致性检查才读取全部七个策略文件 |

配置常量只读取 [references/policy.json](references/policy.json)；生成或判断机器输出时读取 [references/result-contract.json](references/result-contract.json)。全部状态以 `policy-core.md` 的“输出格式”和 `result-contract.json` 为准。本文件保留代理入口、模块选择、执行顺序和不可突破的安全边界；各策略文件按上表分别成为其模块的唯一权威来源。

## 不可突破的边界

1. **绝对不要退出、停止或重启 Clash 客户端。** 不得执行、建议或要求用户这样做。
2. **不得运行 ClashX Meta 主程序做检查。** 不用 `open`、LaunchServices、Computer Use 或 `--version` 启动它；客户端版本读取 `Info.plist`，运行状态读取进程、日志、偏好或本地控制器，内核版本检查 Mihomo。客户端未运行时保持未运行。
3. 只按已保存用途档位操作，不切换订阅、代理组或节点，不覆盖第三方 PAC。只有对应任务策略明确允许时，才通过客户端界面切换 TUN、Clash 自己的系统代理或 AdGuard for Mac 的兼容设置。
4. 安全更新必须保留热加载，但只能走已经运行的客户端原生入口。候选加载与失败恢复各最多一次；运行配置变化后继续等待 TUN、代理选择、DNS 和实际连接全部恢复，禁止直接重载 Mihomo、直接改 TUN 或循环重试。
5. 只处理 Clash 当前存储位置中的订阅；无法确认本地或 iCloud 状态时停止，不猜。
6. 写入候选必须通过 YAML 重读、二次转换一致性检查和 Mihomo 1.19.27 以上版本的 30 秒校验；失败时保持原文件。
7. 跟随用户使用的语言。任何输出都不得包含订阅地址、密码、UUID、私钥、控制器密钥、完整节点地址或节点名称。

## 模块选择

- **Patch 模块**：首次安装、改变用途档位，或用户明确要求配置网络时使用；只应用该档位的最少能力。
- **Diagnostics 模块**：慢、间歇失败、打不开、全红、分流异常或泄漏时使用。不能因为用户提到 Clash 就先运行补丁。
- **订阅更新**：用户明确要求更新全部订阅时使用；它不是 Patch 或 Diagnostics 的隐含步骤。

## 任务合同

调用工具前，在内部固定四项：任务对象、交付类型、授权边界、完成条件。任务对象取用户描述中影响面最广的可观察问题；单个应用报错可能只是下游症状。交付类型只取分析、复核、修复、更新或监测。每项检查和写入都必须推进完成条件，否则不做。

**使用 Skill 不等于授权修改 Skill。** 网络诊断、修复和产品反馈都不授权改仓库；只有用户明确要求维护本项目并把仓库放入范围时才允许修改。

持久修复必须以已经确认的问题为依据，并同时具备修改权限和明确对象。为取得证据而做的隔离实验，或用户已授权、单变量、可完整恢复的现场对照可以先执行；**诊断对照不是持久修复**，不得把实验成功写成问题已经解决。

完成条件按交付类型判断：分析或复核任务不要求执行修复或复测，只要求结论状态、证据、反证和未知项完整；修复任务必须完成最小修复、原场景复测和受影响能力回归；更新任务不做更新前测试，必须完成全部远程订阅的备份和当前平台更新，再按已保存档位完成首次 Patch 的客户端动作、全部验收和最终复核；监测任务必须确认采集确实运行并给出停止方法。历史问题已消失且无法重现时，只能说明证据边界，不能伪造复测。

## Diagnostics 执行顺序

1. 读取已保存用途档位。macOS：`bash scripts/install_macos.sh --show-profile`；Windows：`.\scripts\install_windows.cmd -ShowUsageProfile`。没有已保存档位且后续需要修改时，问：**“你使用网络代理主要用于哪些用途？”** 故障本身不能自动升档。
2. 建立原始证据清单：用户时间线、先前自动化或终端的原始会话或审计记录、版本化备份和变更收据、应用与控制器日志、系统日志、配置差异、当前状态。已有历史证据未读完前，不用当前健康状态改写过去。
3. 有 Computer Use 且原始症状可见时，在修改前用同一应用、目标和动作复现。再用范围矩阵区分单个目标、应用、本机、网络和共同路径；至少保留异常目标与两个健康对照。
4. 维护结论台账，分开记录症状、故障机制、故障来源、触发条件、恢复原因和修复动作。每项新检查必须区分至少两个仍成立的解释，或补齐一个明确缺口；工具调用失败只说明取证方法失败。连续两次调用失败时先回读环境和工具能力，再换证据来源。
5. 单次事故用现场时间线、直接机制证据、反证和恢复归因判断；声称“反复故障的主要原因”时，额外执行 `diagnostics.md` 中的因果判定门槛：原始事件、时间方向、候选事件命中率、故障覆盖率、正反例、独立证据和单变量干预。不得把只适用于重复样本的统计门槛套到单次事故，也不得用机制解释冒充事故证据。
6. 一次只改变一个变量。修复失败后恢复并继续取证；但事务安全规则优先于一般失败恢复规则，文件身份变化、提交状态未知或持久事务待恢复时不得强行覆盖。连续两次判断或修改无改善时执行诊断重置；没有新证据不做第三次修改。
7. 使用原场景复测。故障原因与恢复原因分别判断；组合操作、延迟复测或同一份配置未修改而恢复时，不得把恢复归给其中一项操作。

外部服务状态只在任务合同已经把异常限制到单个外部服务时查询。跨应用、跨目标或跨订阅异常时不查单个服务状态。

### 多订阅故障

逐份订阅取证，不得共用结论。先固定最后正常、首次失败、订阅切换、组合操作和最后一次确认失败到首次确认恢复的窗口，再读取原始会话或审计记录、控制器实时日志、健康检查、配置哈希和节点解析。

macOS 文件日志缺失时使用 `/usr/bin/log show --info --debug`；TCP 摘要按 `process == "kernel"` 过滤，再在 `eventMessage` 中匹配实际 Mihomo PID。`SYN in/out: 0/1` 且 `RST in/out: 1/0` 只能定位到本机之外，不能仅凭客户端证据区分外部哪一层拒绝。Windows 文件或应用日志缺失时改查控制器记录，以及有明确时间和目标范围的 `pktmon` 或系统连接证据。一种采集方法失败不能宣布没有历史证据。

普通域名经 Mihomo 查询得到 `198.18.*` 是 Fake-IP 模式的正常应答，不能证明缓存污染。只有节点连接日志出现“节点域名 → Fake-IP 地址 → 超时”，且同一域名经直连 IP 加密解析器得到真实地址时，才支持该订阅的节点启动解析进入本机 DNS/Fake-IP 链。文件日志权限异常时按策略运行 `--repair-clashx-logs`，保留旧日志且不停止或重启 Clash。

## Patch 与用途档位

三个档位都处理当前存储位置中的全部订阅、关闭订阅自动更新，并应用共同国内域名直连基线和安全的节点启动解析；详细 DNS 值只读取 `policy.json`，不得在本文重复。

1. **档位 1｜普通浏览**：普通浏览、国内直连和 Clash 系统代理；不改 TUN、IPv6、WebRTC、AI 分组或节点。
2. **档位 2｜海外 AI**：继承档位 1，增加 TUN 和普通海外 AI；关闭 Clash 自己的系统代理，避免重复接管；不增加 WebRTC 或 AI 分组补丁。
3. **档位 3｜Claude/Claude Code**：继承档位 2，再应用完整 DNS 分流、AI 分组与规则、局域网与国内 UDP 分流、其余 UDP/WebRTC 防护和区域指纹检查。区域指纹只使用 `assets/claude-region-check.html`，是参考信号，不能作为 Claude 是否可用的通过条件；具体十项信号、Computer Use、STUN、CSP、浏览器与恢复规则只按 `profiles-and-patch.md` 执行。

用户可以随时改档；升档只补新增能力。档位 3 降到 1 或 2 时先安全卸载：macOS `bash scripts/uninstall_macos.sh`，Windows `.\scripts\uninstall_windows.cmd`。Windows 卸载返回 `partial` 时保留旧档位且不得继续降档。

共同基线问题可以调用已保存档位的平台安装入口，因为三个档位都包含这项能力；档位 1、2 不能因此获得档位 3 增强。与共同基线无关的单项 Clash 配置修复仍留在 Diagnostics：macOS 使用策略中的单项配置事务；Windows 当前没有安全的即时单项配置写入路径。**Patch 专用验收（Diagnostics 不固定执行）**只在 Patch 或相关能力确实被修改时运行。

## 平台入口

### macOS

```bash
bash scripts/install_macos.sh --profile N
bash scripts/uninstall_macos.sh
ruby scripts/macos/patch_profiles.rb --json
```

Patch 与 macOS 订阅更新的运行加载仍遵守平台策略；订阅下载不通过本地控制器。

### Windows

```powershell
.\scripts\install_windows.cmd -UsageProfile N
.\scripts\uninstall_windows.cmd
```

平台脚本只完成安全的文件事务。脚本成功不等于档位完成；必须继续按策略通过客户端界面完成当前档位的客户端开关与验收。

受保护写入只有客户端本来就未运行时才执行；客户端运行时整批延期，不要求用户退出、停止或重启。中断的客户端敏感事务同样遵守记录中的恢复权限。

## 更新全部订阅

只有用户明确要求更新节点或订阅时执行。首次收到请求时，先提醒用户：“请确保订阅开关已打开。请自行登录服务商管理后台，找到订阅开关并打开。”部分服务的开关开启后约 10 分钟有效；用户同一条消息已经明确说“打开了”或“没问题”时直接继续，否则等用户确认。用户确认前不得读取订阅、建立备份或操作客户端；不得代替用户操作服务商后台。

确认后严格执行：更新前不运行任何测试。macOS 运行 `bash scripts/install_macos.sh --safe-update --json`；Windows 先运行 `.\scripts\install_windows.cmd -SnapshotProfiles -Json`，为全部远程订阅创建更新前备份和本轮验收记录，并只读记录更新前 TUN 与代理选择。macOS 继续使用 Foundation 原生请求完成下载、补丁和内部运行检查，并发送 `Accept-Language: zh-CN,zh;q=0.9`。Windows 使用 Computer Use 操作已经运行的 Clash Verge Rev：进入“订阅”，确认自动更新关闭，点击顶部“更新所有订阅”，等待本轮刷新结束；不得使用右键菜单中的“更新”或“通过代理更新”。

Windows 先检查当前工具列表是否提供 Computer Use；没有该工具，或首次调用失败时，不重试，立即把上述界面步骤交给用户，并要求操作完成后回复“我已经手动更新完了”。收到该回复后运行 `.\scripts\install_windows.cmd -VerifySafeUpdate -RefreshConfirmed -Json`；只在 UI 刷新完成或用户明确确认后提供的 `-RefreshConfirmed` 就是本轮刷新凭据，订阅字节和时间戳未变化也可以是有效结果。客户端刷新会通过已安装的全局脚本按已保存档位重新应用补丁，验收命令逐份检查 YAML、代理组、Mihomo 校验、全局脚本、运行配置和自动更新关闭状态，并恢复和核对更新前 TUN 与代理选择。失败时恢复备份并重新加载原运行配置。Windows 使用 Computer Use 自动刷新成功时也必须运行同一验收命令，不能直接结束。

`safe_update_completed`、`safe_update_verified` 和 `workflow_complete: false` 都是中间回执；看到后必须继续完成 `required_followups` 中的每一项，再做最终状态复核，不得提前输出最终说明。两端更新后都必须继续首次 Patch 中的平台客户端动作和全部验收；安全更新已经重新应用订阅文件补丁，不得再次运行安装命令。档位 2 继承档位 1 的共同补丁与站点验收，但档位 2 不执行档位 1 的系统代理开启动作，而是直接开启 TUN 并关闭 Clash 自己的系统代理；档位 3 继承档位 2，再完成完整分流、DNS、两项 WebRTC 和一次更新后本地区域指纹检测。没有 Computer Use 时不能省略这些步骤：把必须由界面或浏览器完成的动作逐项交给用户并读取结果；未验证项目不得宣称完成。最终状态复核必须再次确认订阅自动更新关闭；任一原代理组或节点选择无法恢复时拒绝更新。只有当前档位规定的全部验收都取得本轮通过结果，才算更新任务完成。

macOS 不得用 curl 下载订阅，也不得固定或伪造 User-Agent；只能按当前运行客户端动态生成原生请求身份。Windows 不直接下载订阅，只调用 Clash Verge Rev 的客户端原生刷新。两端不追加通用的防倒退、数量、哈希或时间戳检查；但现有 AnyTLS 被新配置全部替换为 Shadowsocks 时必须拒绝接受本轮更新。平台命令内部不追加 WebRTC 或区域指纹检查；命令返回后仍按已保存档位完成任务验收。

## 配置历史与恢复

先列出备份，再比较症状出现前的候选；配置差异只输出字段名和哈希。恢复必须携带比较时哈希：macOS `--expected-current-sha256`，Windows `-ExpectedCurrentSha256`。恢复前先备份当前版本；恢复当前订阅后还要恢复运行配置并按保存档位验收。外部修改、文件身份变化、事务状态未知或运行恢复失败时保留现场和记录，不强行回滚。

## 最终说明

先给结论，再列最能区分其他解释的证据、实际动作、复测结果和仍未知的部分。不得用长篇可能性列表代替结论，不得用状态回执代替完整交付。结论强度与证据一致；能立即定性就立即给结论，不得为诊断阶段设置任意分钟数。
