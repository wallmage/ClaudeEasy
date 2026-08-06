# ClaudeEasy Skill Design

**日期：** 2026-07-20
**状态：** 已实现并持续维护

## 文档职责

本文只定义产品目标、组件边界和规则归属，不复制操作步骤、配置常量或状态文案：

- `README.md`：用户可见能力、命令和限制。
- `claude-easy/SKILL.md`：触发后必须立即可见的安全边界、代理入口、模块选择、执行顺序和策略读取路由。
- `claude-easy/references/policy-core.md`：所有任务共同遵守的支持范围、冲突顺序、脚本接口、异常和输出边界。
- `claude-easy/references/diagnostics.md`：诊断任务合同、证据方法、已知故障、修复和完成标准。
- `claude-easy/references/profiles-and-patch.md`：用途档位、Patch 顺序和 Patch 验收。
- `claude-easy/references/routing-and-security.md`：共同国内直连、DNS、TUN、代理组、AI 规则和 WebRTC。
- `claude-easy/references/safe-update-and-recovery.md`：安全更新、配置历史、备份和恢复。
- `claude-easy/references/macos.md` 与 `windows.md`：各平台文件事务、运行恢复和客户端边界。
- `claude-easy/references/policy.json`：解析器、规则集、分组候选和 AI 规则等配置常量。
- `claude-easy/references/result-contract.json`：JSON v1 字段、类型和状态枚举。
- `AGENTS.md`：开发、测试、安装和发布流程。
- `tests/baseline.md`：现行自动化测试范围，不定义产品功能。

每个任务先读取 `policy-core.md`，再由 `SKILL.md` 按任务与平台选择模块；只有跨模块维护、权威归属审查或整体一致性检查才读取全部策略。需求变化直接修改所属的权威来源；其他文档只更新引用或用户摘要，不重新复制一套规则。不得新增平行的需求汇总文档。

## 产品目标

ClaudeEasy 为 macOS ClashX Meta 和 Windows Clash Verge Rev 提供两种能力：

1. **Patch**：按用户用途给当前存储位置中的全部订阅安装最少安全能力。
2. **Diagnostics**：从慢、间歇失败、不可用、分流错误或泄漏等现象出发，形成可验证解释，并按交付类型完成分析、复核、修复或监测。

两端要求 Mihomo 1.19.27 或更高版本。旧客户端、未知内核或不明确的存储位置只检查，不修改。

## 不可突破的产品边界

- 绝对不要退出、停止或重启 Clash 客户端，也不得要求用户这样做。
- 不得运行 ClashX Meta 主程序做诊断、测试、版本查询或只读探测；不用 `--version`、`open`、LaunchServices 或 Computer Use 启动它。客户端版本读 `Info.plist`，实时状态读进程、日志、偏好或本地控制器，内核版本检查 Mihomo。
- 不切换订阅、代理组或节点，不改写第三方 PAC，不安装永久监听、计划任务或后台服务。
- 候选配置在写入前完成重读、二次转换和 Mihomo 校验；事务失败不得覆盖用户或客户端的并发变化。
- 公开输出不含订阅地址、凭据、完整路径、代理组名称或节点名称。

## 三档 Patch 架构

| 档位 | 目标 | 共同能力 | 额外能力 |
| --- | --- | --- | --- |
| 1｜普通浏览 | 国内直连与普通境外浏览 | 全部订阅的共同国内域名直连基线、安全节点启动解析、关闭订阅自动更新 | Clash 系统代理 |
| 2｜海外 AI | 普通浏览、海外 AI 和 Agent | 继承档位 1 | TUN 开，Clash 自己的系统代理关 |
| 3｜Claude/Claude Code | Claude、Claude Code 和完整泄漏防护 | 继承档位 2 | DNS 分流、AI 分组与规则、UDP/WebRTC 防护、区域指纹检查 |

共同基线属于三个档位，不能放进档位 3 专属实现。`default-nameserver`、`proxy-server-nameserver` 和 `direct-nameserver` 的安全判断由两个平台共享同一 `policy.json`，从而避免订阅加载时重进系统 DNS、AdGuard、TUN `dns-hijack` 与 Fake-IP 链。

档位同时约束 Patch 和 Diagnostics。故障不会自动升档；修复共同路径后只回归可能受本次改动影响的已选能力。

### 区域指纹组件

档位 3 使用本地 `assets/claude-region-check.html`，在实际打开 Claude 的同一浏览器中比较修改前后区域信号。页面使用 STUN 与 IPWhois，CSP 只允许所需查询；正式支持 macOS Safari/Chrome 和 Windows Edge/Chrome。它提供十项参考信号、风险分档和未知权重，不是 Claude 官方判断，也不能作为 DNS、WebRTC、实时分流或 Claude 联网的通过条件。具体信号、权重、授权和恢复规则只在 `profiles-and-patch.md` 定义。

## Diagnostics 架构

### 任务合同与证据模型

每次诊断先固定任务对象、交付类型、授权和完成条件。任务对象取用户完整描述中影响面最广的现象，避免把发现入口当成整个问题。分析或复核只要求结论、证据、反证和未知项完整；修复才要求最小改动、原场景复测和回归；更新和监测各有独立完成条件。

证据模型由七个槽位组成：症状、故障机制、故障来源、触发条件、恢复原因、修复动作、证据状态。先读取用户时间线、原始会话或审计记录、版本化备份、应用/控制器/系统日志和配置差异。工具失败只代表取证路径失败，不能当作被查对象异常。

持久修复必须针对已经确认的问题。诊断所需的隔离实验或已授权、可恢复的单变量对照只产生证据。具体场景优先于通用流程，平台边界优先于跨平台摘要，事务安全优先于一般失败恢复。

### 判断标准

单次事故使用现场时间线、直接机制证据、反证和恢复归因。只有声称反复故障的主要原因时，才额外要求原始事件、时间方向、候选事件命中率、故障覆盖率、正反例、独立证据和单变量干预。机制解释不能代替事故证据。

多个订阅同时异常时逐份订阅取证，不得共用结论；同时检查共用运行状态。macOS 文件日志缺失时，内核 TCP 摘要从 `process == "kernel"` 的 Unified Log 读取，并用 `eventMessage` 绑定 Mihomo PID；Windows 使用控制器记录、`pktmon` 或系统连接证据。Fake-IP 模式的正常应答不能当作缓存污染。故障原因与恢复原因分别判断；同一份配置未修改而恢复时，外部状态恢复和共用运行状态恢复仍需验证。

### 外部组件

外部服务状态只在范围已经限制到单个服务时查询。AdGuard for Mac 兼容、PAC 所有权、Fake-IP 重用和节点启动解析属于具体场景规则，必须满足各自证据条件后才能修改；不从应用名单或订阅名称生成产品规则。

## 平台架构

### macOS

- Shell 入口负责参数、环境和调用编排；Ruby 模块负责订阅发现、YAML 1.2 转换、备份、持久事务、Mihomo 校验、控制器刷新、日志权限修复和 JSON 输出。
- 当前订阅写入后只通过本地控制器刷新，不用 AppleScript，不切换 TUN、订阅、代理组或节点。
- 普通 Patch、安全更新和备份恢复共用操作锁与事务恢复。文件和运行配置共同组成提交条件；文件身份变化、外部刷新或未知提交状态保留现场和事务记录。
- ClashX Meta 日志权限修复保留旧日志及原权限，建立继承 ACL，恢复当前会话目录，不停止或重启 Clash。

### Windows

- CMD 是兼容入口；PowerShell 负责 AppHome、档位、自动更新所有权、备份、事务、安全更新和 JSON；`clash_verge_global.js` 负责订阅加载时的配置转换。
- 三档都安装带数字档位的全局脚本；档位 1、2 只应用共同基线，档位 3 再应用完整策略。
- Windows 受保护写入只有客户端本来就未运行时才执行。客户端运行时整批延期，不要求用户关闭客户端；安全更新恢复只有目标严格绑定本轮清单时才可例外。
- 安装、卸载、备份恢复和事务恢复共用目录锁、文件身份、原字节和提交条件。新文件使用准备记录；中断后按持久恢复权限处理，不从路径猜用途。

## 安全更新

安全更新是用户显式触发的批量流程，不是后台监听。三个档位都关闭订阅自动更新。更新前锁定全部远程订阅的当前版本并创建清单和备份；客户端界面一次触发全部更新；更新后逐份验证刷新证据、YAML、Mihomo、代理组、当前策略和自动更新状态。任何失败按平台事务保持整批一致；磁盘验证和运行生效分别报告。

## 公开接口

macOS 公开入口使用 `--json`，Windows 使用 `-Json`。JSON v1 的标准输出只有一个对象，退出码和 `exit_code` 一致，字段与状态由 `result-contract.json` 定义。安装包不完整在任何 AppHome 写入前返回 `6/incomplete_package`。

备份 ID 使用脱敏稳定标识；比较只返回字段名和哈希。恢复必须携带比较时 SHA-256，恢复前再备份当前版本。内部状态文件不通过普通单文件备份接口恢复。

## 生效与验收

当前订阅只有控制器自动刷新和运行检查都通过，才能报告已经生效。档位 1、2 只验收各自能力；档位 3 通过双平台分流脚本验证 Google、OpenAI、Anthropic 和 Claude 的实时连接链，并执行 DNS 深度测试和两项 WebRTC 页面。

Claude 联网只由分流验证脚本完成。Patch、Diagnostics、复测和安全更新都不得用 Computer Use、浏览器自动化或系统浏览器打开 `claude.ai`、进入账号或发送测试消息。

## 测试策略

- macOS Ruby 与 Windows JavaScript 共享配置转换 fixtures 和完整结果摘要。
- 两端共同覆盖三档 DNS 启动边界、国内直连、AI 规则、UDP/WebRTC、幂等性和脱敏。
- 文件事务覆盖备份先于写入、路径与文件身份、并发变化、中断恢复、客户端运行边界和未知提交状态。
- 公开命令覆盖 JSON v1、退出码、UTF-8、安装包不完整和禁止副作用。
- macOS 纯转换、路由验证和 Windows JavaScript 转换维持既定覆盖率门槛；PowerShell、Shell 与 CMD 使用行为测试。

具体测试范围只在 `tests/baseline.md` 记录，产品行为仍以策略、配置常量和机器合同为准。
