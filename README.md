# ClaudeEasy

ClaudeEasy 是给 AI 助手使用的 Clash 网络配置与诊断 Skill，支持 macOS 的 ClashX Meta 和 Windows 的 Clash Verge Rev。它包含两个模块：Patch 按用途安装最少配置；Diagnostics 从网络现象出发取证、解释、修复和复测。

ClaudeEasy 是独立社区项目，与 Anthropic 没有隶属或官方合作关系。

本文档面向用户，只解释用户可见行为，不重新定义执行规则。代理入口和策略读取路由在 `claude-easy/SKILL.md`：每次先读共同策略，再按 Diagnostics、Patch、安全更新或恢复任务读取对应模块和当前平台文件。详细策略位于 `claude-easy/references/`；配置常量和机器输出分别以 `policy.json`、`result-contract.json` 为准。

## 支持范围

- macOS：最新版 ClashX Meta，使用 Mihomo 1.19.27 或更高版本。
- Windows：最新版 Clash Verge Rev，使用 Mihomo 1.19.27 或更高版本。
- 不支持旧版 ClashX、旧版 Clash Verge、Linux 或其他客户端。

找不到内核、版本过旧或无法确认能力时只检查，不修改。

## 安全边界

- **绝对不要退出、停止或重启 Clash 客户端。** Windows 受保护写入只有客户端本来就未运行时才执行；检测到客户端运行会整批延期，不要求你关闭它。
- 不运行 ClashX Meta 主程序做诊断，也不向它传 `--version`；客户端版本读取 `Info.plist`，内核版本检查 Mihomo。
- 不切换订阅、代理组或节点；只在用途档位要求时，通过客户端界面切换 TUN 或 Clash 自己的系统代理。
- 不改写第三方 PAC。AdGuard for Mac 只按策略中的已验证兼容路径，通过它自己的界面调整。
- 只处理客户端当前存储位置中的订阅；本地和 iCloud 状态不明确时停止。
- 每份候选都经过 YAML 重读、二次转换和 Mihomo 校验；失败保留原文件。
- 不安装永久监听、LaunchAgent、`WatchPaths`、计划任务或后台服务。
- 输出不包含订阅地址、密码、UUID、私钥、控制器密钥、完整路径或节点名称。

## 两个模块

### Patch

用于首次安装、改变用途档位或明确要求配置网络。它只应用当前档位需要的能力，不把档位 3 的完整增强塞进较低档位。

### Diagnostics

用于慢、间歇失败、打不开、全部节点不可用、分流异常或泄漏。代理先确定真正的问题范围，再读取原始会话、备份、应用日志、控制器日志、系统日志和配置差异；不会因为用户提到 Clash 或某个应用就先改配置，也不会把单个应用断线误当成完整问题。

分析或复核任务以结论、证据、反证和未知项完整为完成；修复任务才要求最小修复、原场景复测和受影响能力回归。诊断实验可以在隔离环境或明确授权、可完整恢复的单变量对照中执行，但诊断对照不是持久修复。

这套方法共同适用于 macOS 与 Windows；平台只改变证据来源和安全写入方式，不改变判断标准。多个订阅同时异常时逐份订阅取证，不得共用结论；故障原因与恢复原因分开判断。同一份配置未修改而恢复时，要验证共用运行状态或外部状态恢复，不得把恢复归给改过的其他配置文件。

外部服务状态只在证据已经把异常限制到单个服务时查询；跨应用、跨目标或跨订阅异常时不查询单个服务状态。

## 用途档位

首次修改前会问：“你使用网络代理主要用于哪些用途？”选择保存在本机，以后可以改。

| 档位 | 用途 | 安装能力 | 不会增加 |
| --- | --- | --- | --- |
| **1｜普通浏览** | 国内站、Google、Twitter、YouTube 等 | 全部订阅的共同国内直连与安全节点启动解析；关闭订阅自动更新；使用 Clash 系统代理 | TUN、IPv6、WebRTC、AI 分组或节点改动 |
| **2｜海外 AI** | ChatGPT、Codex、Gemini、Perplexity 等 | 继承档位 1；开启 TUN，关闭 Clash 自己的系统代理，避免重复接管 | WebRTC 或 AI 分组补丁 |
| **3｜Claude/Claude Code** | Claude、Claude Code 或完整泄漏防护 | 继承档位 2；增加 DNS 分流、AI 规则、UDP/WebRTC 防护和区域指纹检查 | 自动切换订阅、代理组或节点 |

档位 3 的全局 UDP 会影响 QUIC、游戏、语音和视频。AI 节点可以建议台湾家宽优先、其次日本家宽，但不会替用户切换。

升档只补新增能力。档位 3 降到 1 或 2 时先安全卸载，再安装新档位；只能撤销仍能确认属于本工具且未被用户继续修改的内容。Windows 卸载返回 `partial` 时保留旧档位，不继续降档。

## 三档共同保护

三个档位都会处理当前存储位置中的全部订阅，并做两件事：

1. 用 MetaCubeX ChinaMax `cn.mrs` 建立共同国内域名直连基线，让国内 DNS 和连接路由都命中 `DIRECT`。
2. 保留安全的 `default-nameserver` 和 `proxy-server-nameserver`；缺失或含 `system`、明文 DNS、错误类型、旧危险值的节点启动解析改用 `policy.json` 中的大陆 IP DoH。这样解析节点域名时不依赖系统 DNS、明文 53 或解析器域名引导。

这两项属于所有档位，不是档位 3 专属能力。服务商后续更新覆盖配置时，Windows 全局脚本会在订阅加载时重新应用；macOS 安全更新验收后重新应用。

## 档位 3 增强

- TUN 使用 system stack、DNS 劫持、自动路由和严格路由；关闭 IPv6。
- 国内域名直连大陆 DoH；普通境外 DNS 随主代理组；AI DNS 随 AI 分组。
- 复用已有可选 AI 分组，不改它的成员和当前选择；没有时才创建包含全部可用真实节点和代理提供者的独立选择器。
- 补全 OpenAI、Anthropic、Claude 和 Gemini 相关规则；不把通用 GitHub 或 Google 存储域名塞进 AI 规则。
- TCP DNS 和所有 UDP 经过 AI 分组，UDP 末尾拒绝兜底，减少 WebRTC 直连。

详细解析器、域名和规则清单只在 `policy.json` 保存，避免文档复制后漂移。

### Claude 区域指纹

档位 3 在修改前后用实际打开 Claude 的浏览器运行本地页面 `claude-easy/assets/claude-region-check.html`。页面会在检测按钮前列明 Google、Cloudflare 的三个 STUN 端点及公网 IP 披露，点击后才运行 WebRTC 测试；不会把检测到的 IP 发送给归属地查询或其他服务，CSP 也禁止其他网络请求。支持 macOS 的 Safari、Chrome 和 Windows 的 Edge、Chrome。

页面显示十项参考信号、已知项合计和未知权重。WebRTC 项只有明确暴露本地网络地址时计 `10` 分；公网出口不同、没有公网候选或无法完成对照都计 `0` 分，因为这些情况不能单独证明 WebRTC 绕过代理。它不查询国家，也不会把候选地址发给对照服务。它不是 Claude 官方判定，不能作为 Claude 是否可用的通过条件，也不替代 DNS、WebRTC 和实时分流验证。不会为了降分删除字体、伪装设备、修改 User-Agent 或擅自更改系统默认浏览器。任何可选设置都会先展示影响并单独取得授权。

## AdGuard for Mac

档位 2、3 使用 Clash TUN 时，AdGuard for Mac 的 `Network Extension` 可能与透明接管冲突。只有现场表现和单变量对照支持时，才通过 AdGuard 界面改为“自动代理”；Fake-IP 重用证据成立且当前 Mihomo HTTP 端口已验证时，才配置 AdGuard 出站代理按域名交给 Mihomo。不会用 `networksetup`、Plist 编辑或逐站例外，也不会全局关闭 HTTPS 过滤。

## 安装

```bash
git clone https://github.com/wallmage/ClaudeEasy.git
cd ClaudeEasy
```

macOS：

```bash
bash claude-easy/scripts/install_macos.sh --profile 1
bash claude-easy/scripts/install_macos.sh --profile 2
bash claude-easy/scripts/install_macos.sh --profile 3
```

Windows PowerShell 5.1：

```powershell
.\claude-easy\scripts\install_windows.cmd -UsageProfile 1
.\claude-easy\scripts\install_windows.cmd -UsageProfile 2
.\claude-easy\scripts\install_windows.cmd -UsageProfile 3
```

这些命令只完成安全的文件事务。脚本成功不等于档位完成；仍需由 Skill 按策略通过客户端界面完成当前档位的客户端开关与验收。

Windows 安装只在客户端本来就未运行时执行写入；客户端运行时修改整批延期且不得报告“已更新”。

## 公开命令

- 查看档位：macOS `--show-profile`；Windows `-ShowUsageProfile`
- 列出备份：macOS `--list-backups`；Windows `-ListBackups`
- 比较备份：macOS `--compare-backup ID`；Windows `-CompareBackup ID`
- 恢复备份：macOS `--restore-backup ID --expected-current-sha256 HASH`；Windows `-RestoreBackup ID -ExpectedCurrentSha256 HASH`
- 修复 ClashX Meta 日志权限：macOS `--repair-clashx-logs`
- JSON v1：macOS `--json`；Windows `-Json`

所有公开命令的机器输出字段以 `result-contract.json` 为准；JSON 标准输出只有一个对象，实际退出码与 `exit_code` 一致。

## 安全更新

只有用户明确要求“请帮我安全更新全部订阅”或同义请求时执行：

1. 先为全部远程订阅建立清单、哈希和修改前备份。
2. 通过客户端界面一次触发“立即执行安全更新”；不得检查服务商后台、登录网站或修改后台开关。
3. 逐份确认本轮刷新证据、YAML、Mihomo、代理组、当前策略和订阅自动更新仍关闭。
4. 一份失败时按平台事务规则保持整批一致，并逐一报告成功、恢复或失败状态。

数月未更新也走同一流程。下载成功不等于当前运行内核已经采用；生效状态会单独报告。

macOS 重载当前订阅前会保存 TUN 和代理组选择，重载后先恢复原状态再检查联网；进程意外中断时，下次运行仍按更新前状态恢复，不依赖重启客户端。

脚本返回更新成功不代表整项任务完成。ClaudeEasy 会自动继续完成当前档位的全部验收；缺项、超时或结果波动时会继续检查，直到所有必做项目都有本轮结果，或明确说明唯一无法自动完成的步骤。

macOS 与 Windows 使用相同的完成条件和档位验收。Windows 因客户端接口不同会先建立快照、再触发刷新并验收，但每个中间结果都会列出剩余步骤；不会把快照或单次验收回执当成任务完成。

## 配置历史与恢复

第一次运行保存初始快照，每次写入前保存带日期时间的版本。比较只输出字段名和 SHA-256，不输出配置值。恢复前再次备份当前版本，并要求当前 SHA-256 仍等于比较时结果；并发变化、文件身份变化或未完成事务会阻止覆盖。

macOS 恢复当前订阅后通过本地控制器重新加载并验收；运行恢复失败时保留事务。Windows 受保护恢复只有客户端本来就未运行时进行；安全更新是唯一受严格清单限制的运行中恢复例外。

## 验收

档位 1 验收国内站、Google、Twitter、常用站点和 Clash 系统代理；档位 2 再验收 TUN、ChatGPT、Gemini 与 Agent 联网；档位 3 再验收 Google、OpenAI、Anthropic、Claude 的实时连接链、DNS 深度测试和两项 WebRTC 页面。

Claude 联网只由分流验证脚本完成；不会用 Computer Use 或浏览器打开 `claude.ai`、进入账号或发送消息。浏览器只打开本地区域检测页和 DNS/WebRTC 测试页。

## 卸载

macOS：

```bash
bash claude-easy/scripts/uninstall_macos.sh
```

Windows：

```powershell
.\claude-easy\scripts\uninstall_windows.cmd
```

卸载只撤销本工具拥有且未被继续修改的内容，不删除版本化备份。Windows 客户端运行时只返回延期状态，不要求你关闭客户端。

## 限制

- 不替用户选择订阅、代理组或节点。
- 不保证区域指纹参考分能改变任何服务判定。
- Windows 订阅增强在各订阅以后正常加载或刷新时生效；安装完成不能代表全部订阅已在运行内核中采用。
- 客户端或控制器无法提供实时状态时会标记“未验证”，不会伪造成功。
