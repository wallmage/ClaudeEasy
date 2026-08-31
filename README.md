# ClaudeEasy

ClaudeEasy 是一个给 AI 助手用的 macOS 与 Windows 通用电脑诊断和修复 Skill，同时保留 Clash 网络配置能力。网络配置支持 macOS 的 ClashX Meta 和 Windows 的 Clash Verge Rev，可以用 Patch 按用途配置网络，也能排查连接问题、安全更新全部订阅、比较和恢复备份。

ClaudeEasy 是独立社区项目，与 Anthropic 没有隶属或官方合作关系。

ClaudeEasy 面向不熟悉电脑设置的普通用户。用户只需说明问题，代理会自行检查、修复和复测；网络配置任务仍按用途完成设置。默认只用简体中文给出最终结果，不展示缓存、日志、锁或中间失败等技术细节。只有系统授权、密码或确实必须手动点击时才会请用户做一步操作。

## 电脑故障诊断

macOS 与 Windows 都支持。

- 用户只描述问题，不需要选择故障类型。
- 网络问题仍使用成熟的原网络流程。
- 其他问题使用按证据动态选择下一步的通用流程。
- 不进行固定全面体检，不采集与当前判断无关的数据。
- 能自行读取或操作的事情由代理完成，只有真实阻塞才请用户参与。

## 它能做什么

- **电脑故障诊断：** 在 macOS 与 Windows 上按你描述的问题检查、修复和复测。不是固定全面体检。
- **按用途配置网络：** 为当前存储位置中的全部订阅应用合适的国内直连、DNS、TUN、AI 分流和 WebRTC 防护。
- **Diagnostics（网络故障排查）：** 处理速度慢、偶尔断线、网站打不开、节点全红、分流错误或隐私泄漏。先确认原因，再做最小改动。
- **安全更新订阅：** 更新前先备份，更新后重新应用当前档位的配置，并确认原来的 TUN、代理组和节点选择都能恢复。
- **管理备份：** 列出、比较和恢复历史版本。
- **验证结果：** 检查实际运行配置、代理组、规则、DNS、网站连接和必要的浏览器测试，不把“脚本退出成功”当成全部完成。

## 支持范围

- 通用电脑诊断：macOS 与 Windows。
- 网络配置：macOS 最新版 ClashX Meta，Windows 最新版 Clash Verge Rev，Mihomo 1.19.27 或更高版本。
- 不支持旧版 ClashX、旧版 Clash Verge、Linux 或其他客户端。

找不到内核、版本过旧或无法确认能力时，网络配置任务只检查，不修改。通用电脑诊断不受这项限制。

## 安全边界

以下条目适用于网络配置任务。通用电脑诊断不改 Clash 配置，也不退出客户端。

- **绝对不要退出、停止或重启 Clash 客户端。** ClaudeEasy 也不会要求你这样做。
- 不会自动切换订阅、代理组或节点。只有所选用途档位需要时，才调整 TUN 或 Clash 自己的系统代理。
- 只处理客户端当前存储位置中的订阅。macOS 偏好缺失、但当前订阅只在本地目录出现时会自动按本地处理；多个位置都匹配时不会冒险覆盖。
- 不改写第三方 PAC，不安装永久监听、LaunchAgent、`WatchPaths`、计划任务或后台服务。
- 客户端正在运行时的普通安装、卸载或单文件备份恢复会推迟，且不会被要求退出客户端。

## 选择用途档位

第一次配置时，ClaudeEasy 会问：“你使用网络代理主要用于哪些用途？”选择会保存在本机，以后可以更改。

| 档位 | 适合谁 | 会做什么 | 不会做什么 |
| --- | --- | --- | --- |
| **1｜普通浏览** | 国内网站、Google、Twitter、YouTube 等 | 安装共同国内域名直连基线，保护节点启动解析，关闭订阅自动更新，开启 Clash 系统代理 | 不改 TUN、IPv6、WebRTC、AI 分组或节点 |
| **2｜海外 AI** | ChatGPT、Codex、Gemini、Perplexity 等 | 继承共同补丁，开启 TUN，关闭 Clash 自己的系统代理，检查常用网站和 AI 工具 | 不增加 WebRTC 或 AI 分组补丁 |
| **3｜Claude/Claude Code** | Claude、Claude Code，或需要更完整的泄漏防护 | 继承档位 2，再增加 DNS 分流、AI 分组与规则和 UDP/WebRTC 防护 | 不替你选择订阅、代理组或节点 |

三个档位都会处理当前存储位置中的全部订阅，并关闭订阅自动更新。共同国内域名直连基线让国内域名和连接走 `DIRECT`。安全的节点启动解析避免节点域名依赖系统 DNS、明文 DNS 或 Fake-IP 链。

档位 3 会让局域网 UDP、国内域名和国内 IP 直连，其余 UDP 经过 AI 分组。QUIC、游戏、语音和视频也按这套规则处理。无法确认目的地时，使用方式可能受到影响。ClaudeEasy 可以建议台湾家宽优先、其次日本家宽，但最终由你自己选择节点。

升档只增加新档位需要的能力。从档位 3 降到 1 或 2 时，会先安全卸载旧档位，再安装新档位。已经被你或客户端继续修改的内容不会被强行覆盖。Windows 卸载返回 `partial` 时会保留旧档位，不会继续降档。

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

这些命令只完成安全的文件处理。代理会继续完成客户端开关、测试、必要修复和最终复核；清单全部通过后才会告诉你完成。客户端正在运行时不会要求退出客户端。

## 常用命令

| 功能 | macOS | Windows |
| --- | --- | --- |
| 查看档位 | `bash claude-easy/scripts/install_macos.sh --show-profile` | `.\claude-easy\scripts\install_windows.cmd -ShowUsageProfile` |
| 安全更新 | `bash claude-easy/scripts/install_macos.sh --safe-update --json` | 先用 `-SnapshotProfiles -Json`，点击前用 `-BeginSafeUpdateRefresh -Json`，刷新后用 `-VerifySafeUpdate -RefreshConfirmed -Json` |
| 列出备份 | `ruby claude-easy/scripts/macos/patch_profiles.rb --list-backups --json` | `.\claude-easy\scripts\install_windows.cmd -ListBackups -Json` |
| 比较备份 | `ruby claude-easy/scripts/macos/patch_profiles.rb --compare-backup ID --json` | `.\claude-easy\scripts\install_windows.cmd -CompareBackup ID -Json` |
| 恢复备份 | `ruby claude-easy/scripts/macos/patch_profiles.rb --restore-backup ID --expected-current-sha256 HASH --json` | `.\claude-easy\scripts\install_windows.cmd -RestoreBackup ID -ExpectedCurrentSha256 HASH -Json` |
| 修复日志权限 | `ruby claude-easy/scripts/macos/patch_profiles.rb --repair-clashx-logs` | 不适用 |
| 协调客户端开关 | `ruby claude-easy/scripts/macos/patch_profiles.rb --reconcile-client-switches --usage-profile N --json` | 按 Clash Verge Rev 界面规则处理 |
| 验证实时分流 | `ruby claude-easy/scripts/macos/verify_routes.rb --json` | `powershell.exe -NoProfile -File claude-easy/scripts/windows/verify_routes.ps1 -Json` |

## 更新全部订阅

ClaudeEasy 只有在你明确要求“更新节点”或“更新订阅”时才会更新，不会在后台自动刷新。macOS 与 Windows 执行的是同一套安全步骤，只是刷新订阅的方式不同。

1. 先提醒你自行登录服务商管理后台，打开每份远程订阅的订阅开关；你确认后才会继续。
2. 更新前不做站点或浏览器测试。两端都先为全部远程订阅创建更新前备份。
3. 更新后按已保存档位完成客户端开关与验收，并确认原 TUN、代理组和节点选择都已恢复。任一无法恢复时拒绝更新。

Windows 有电脑操控（Computer Use）时，会自动操作已经运行的 Clash Verge Rev。没有时先帮助你启用；确实无法启用才会请你完成一个最短的点击动作。macOS 的 ClashX Meta 开关优先由原生命令自动处理，浏览器和系统设置由电脑操控完成。

## 备份与恢复

第一次运行会保存初始快照，之后每次写入前都会保存带时间的版本。公开备份 ID 不含真实文件名。

恢复前会再次备份当前版本。文件被其他程序改过、事务未完成或运行状态无法恢复时，ClaudeEasy 会停止，不会覆盖新内容。

恢复当前订阅后，还会恢复运行配置，并保留恢复前的 TUN 和仍然存在的代理组选择。

## 怎么判断配置真的生效了

- 档位 1：检查国内站、Google、Twitter、一个常用网站和 Clash 系统代理。
- 档位 2：再检查 TUN、ChatGPT、Gemini 和命令行或 Agent 联网。
- 档位 3：再检查 ChatGPT、Gemini、Grok、DNS、WebRTC 和本地区域风险。需要调整时，代理会在一次明确授权后替你完成本轮系统和浏览器设置，再复测到低风险通过。

## AdGuard for Mac

档位 2、3 使用 Clash TUN 时，AdGuard for Mac 的 `Network Extension` 可能发生冲突。只有实际现象和单变量对照都指向这个问题时，ClaudeEasy 才会通过 AdGuard 自己的界面调整设置。它不会改第三方 PAC，也不会为了省事全局关闭 HTTPS 过滤。

## 卸载

macOS：

```bash
bash claude-easy/scripts/uninstall_macos.sh
```

Windows：

```powershell
.\claude-easy\scripts\uninstall_windows.cmd
```

卸载只撤销仍能确认属于 ClaudeEasy、且之后没有被继续修改的内容。版本化备份会保留。Windows 客户端运行时，受保护的卸载会返回 `partial`，但不会要求你关闭客户端。

## 目前的限制

以下条目适用于网络配置任务。

- ClaudeEasy 不替你选择订阅、代理组或节点。
- Windows 的订阅增强要等订阅下次正常加载或刷新后才进入运行内核。安装完成不代表全部订阅已经生效。
- 客户端或控制器暂时读不到实时状态时，代理会继续排查或请你做必要一步，不会假装已经完成。
