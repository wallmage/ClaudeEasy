# ClaudeEasy

ClaudeEasy 是一个给 AI 助手用的 Clash 配置与诊断 Skill。它支持 macOS 的 ClashX Meta 和 Windows 的 Clash Verge Rev，可以用 Patch 按用途配置网络，也能排查连接问题、安全更新全部订阅、比较和恢复备份。

ClaudeEasy 是独立社区项目，与 Anthropic 没有隶属或官方合作关系。

本文档面向用户，只解释用户可见行为，不重新定义执行规则。普通用户不需要阅读内部策略。代理入口和策略读取路由在 `claude-easy/SKILL.md`：每次先读共同策略，再按任务读取诊断、配置、更新或恢复规则，以及当前平台文件。详细规则在 `claude-easy/references/`。配置常量和机器输出分别以 `policy.json`、`result-contract.json` 为准。

## 它能做什么

- **按用途配置网络：** 为当前存储位置中的全部订阅应用合适的国内直连、DNS、TUN、AI 分流和 WebRTC 防护。
- **Diagnostics（故障排查）：** 处理速度慢、偶尔断线、网站打不开、节点全红、分流错误或隐私泄漏。先确认原因，再做最小改动。临时对照只用来找原因，诊断对照不是持久修复。macOS 与 Windows 使用同一套判断方法，平台只改变证据来源和安全写入方式，不改变判断标准。
- **安全更新订阅：** 更新前先备份，更新后重新应用当前档位的配置，并确认原来的 TUN、代理组和节点选择都能恢复。
- **管理备份：** 列出、比较和恢复历史版本。比较结果只显示字段名和哈希，不显示配置内容。
- **验证结果：** 检查实际运行配置、代理组、规则、DNS、网站连接和必要的浏览器测试，不把“脚本退出成功”当成全部完成。

## 支持范围

- macOS：最新版 ClashX Meta，Mihomo 1.19.27 或更高版本。
- Windows：最新版 Clash Verge Rev，Mihomo 1.19.27 或更高版本。
- 不支持旧版 ClashX、旧版 Clash Verge、Linux 或其他客户端。

找不到内核、版本过旧或无法确认能力时，ClaudeEasy 只检查，不修改。

## 安全边界

- **绝对不要退出、停止或重启 Clash 客户端。** ClaudeEasy 也不会要求你这样做。
- 不会自动切换订阅、代理组或节点。只有所选用途档位需要时，才调整 TUN 或 Clash 自己的系统代理。
- 只处理客户端当前存储位置中的订阅。本地和 iCloud 状态不明确时会停止，不会猜。
- 不改写第三方 PAC，不安装永久监听、LaunchAgent、`WatchPaths`、计划任务或后台服务。
- macOS 不会启动 ClashX Meta 主程序来做检查。macOS 不用 Computer Use 操作 ClashX Meta，因为它是纯菜单栏应用。ClaudeEasy 会先读取状态，需要调整时每个开关最多一次。
- Windows 普通安装、卸载和单文件备份恢复只有客户端本来就未运行时才执行。客户端正在运行时，这些操作会暂停，也不会要求你退出客户端。
- 运行中可以创建安全更新备份和验收清单。安全更新失败恢复是唯一允许修改订阅的受控例外，其余受保护客户端配置写入会整批延期。
- 输出不会包含订阅地址、密码、UUID、私钥、控制器密钥、完整路径或节点名称。

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

这些命令只完成安全的文件处理。脚本成功不等于档位完成，之后还要完成客户端开关与验收。Windows 安装只在客户端本来就未运行时执行写入。客户端运行时修改整批延期且不得报告“已更新”。

## 常用命令

| 功能 | macOS | Windows |
| --- | --- | --- |
| 查看档位 | `bash claude-easy/scripts/install_macos.sh --show-profile` | `.\claude-easy\scripts\install_windows.cmd -ShowUsageProfile` |
| 安全更新 | `bash claude-easy/scripts/install_macos.sh --safe-update --json` | 先用 `-SnapshotProfiles -Json`，刷新后再用 `-VerifySafeUpdate -RefreshConfirmed -Json` |
| 列出备份 | `ruby claude-easy/scripts/macos/patch_profiles.rb --list-backups --json` | `.\claude-easy\scripts\install_windows.cmd -ListBackups -Json` |
| 比较备份 | `ruby claude-easy/scripts/macos/patch_profiles.rb --compare-backup ID --json` | `.\claude-easy\scripts\install_windows.cmd -CompareBackup ID -Json` |
| 恢复备份 | `ruby claude-easy/scripts/macos/patch_profiles.rb --restore-backup ID --expected-current-sha256 HASH --json` | `.\claude-easy\scripts\install_windows.cmd -RestoreBackup ID -ExpectedCurrentSha256 HASH -Json` |
| 修复日志权限 | `ruby claude-easy/scripts/macos/patch_profiles.rb --repair-clashx-logs` | 不适用 |
| 协调客户端开关 | `ruby claude-easy/scripts/macos/patch_profiles.rb --reconcile-client-switches --usage-profile N --json` | 按 Clash Verge Rev 界面规则处理 |
| 验证实时分流 | `ruby claude-easy/scripts/macos/verify_routes.rb --json` | `powershell.exe -NoProfile -File claude-easy/scripts/windows/verify_routes.ps1 -Json` |

所有公开命令都支持中文结果，机器调用使用 JSON v1。JSON 标准输出只有一个对象，实际退出码与 `exit_code` 一致，字段以 `result-contract.json` 为准。

## 更新全部订阅

ClaudeEasy 只有在你明确要求“更新节点”或“更新订阅”时才会更新，不会在后台自动刷新。macOS 与 Windows 执行的是同一套安全步骤，只是刷新订阅的方式不同。

1. 先提醒你：“请确保订阅开关已打开。请自行登录服务商管理后台，找到订阅开关并打开。”部分服务的开关开启后约 10 分钟有效。你回复“打开了”或“没问题”后才继续。否则确认前不得读取订阅、建立备份或操作客户端。不得代替用户操作服务商后台。
2. 更新前不做站点、Agent、分流、DNS 或 WebRTC 测试。两端都先为全部远程订阅创建更新前备份，任一备份失败时停止。Windows `-SnapshotProfiles -Json` 还会记住原来的 TUN 和代理组选择。
3. macOS 使用 Foundation 原生请求，请求身份从当前运行的 ClashX Meta 动态生成，并发送 `Accept-Language: zh-CN,zh;q=0.9`。它不用 curl，也不伪造 User-Agent。Windows 只用 Clash Verge Rev 顶部的“更新所有订阅”，不会直接下载，也不会使用右键菜单中的“更新”或“通过代理更新”。
4. macOS 在写入前完成文本编码、YAML、二次转换一致性检查和 Mihomo 校验，防止损坏或不完整的配置被写入。Windows 刷新时运行已安装的全局脚本，并在刷新后逐份检查订阅、补丁、代理组、Mihomo 和运行配置。任何一端失败都会按更新前备份恢复，并继续核对运行状态。
5. 平台命令成功只是中间状态。ClaudeEasy 还会按已保存档位完成客户端开关与验收，再次确认订阅自动更新关闭，并确认原 TUN、代理组和节点选择都已恢复。任一原代理组或节点选择无法恢复时拒绝更新。机器结果出现 `workflow_complete: false`，表示还有检查没做完，不会提前结束。

Windows 有 Computer Use 时，可以操作已经运行的 Clash Verge Rev。没有时会给你同样的界面步骤，等你回复“我已经手动更新完了”后运行 Windows `-VerifySafeUpdate -RefreshConfirmed -Json` 继续验收。没有 Computer Use 只改变由谁点击，不会减少检查项目。

两端不会用节点数量、哈希或时间戳简单判断更新好坏。不过，如果原配置中的 AnyTLS 在新配置里全部变成 Shadowsocks，本轮更新不会被接受。

## 备份与恢复

第一次运行会保存初始快照，之后每次写入前都会保存带时间的版本。公开备份 ID 不含真实文件名。比较只显示字段路径和 SHA-256，不显示配置值。

恢复前会再次备份当前版本，并确认当前 SHA-256 仍等于你比较时看到的值。文件被其他程序改过、文件身份变化、事务未完成或运行状态无法恢复时，ClaudeEasy 会停止，不会覆盖新内容。

恢复当前订阅后，还会恢复运行配置，并保留恢复前的 TUN 和仍然存在的代理组选择。中途被强制结束时，下一次公开操作会先处理未完成记录。同一个恢复阶段不会反复发送加载事件。

Windows 的其他受保护恢复只有客户端本来就未运行时进行。

## 怎么判断配置真的生效了

- 档位 1：检查国内站、Google、Twitter、一个常用网站和 Clash 系统代理。
- 档位 2：再检查 TUN、ChatGPT、Gemini 和命令行或 Agent 联网。
- 档位 3：再检查 ChatGPT、Gemini、Grok 的实时连接链、DNS 深度测试和两项 WebRTC 页面。

**Claude/Anthropic 永久禁测：相关网站、API、域名和本地检测页一律不打开、不请求、不测试。** 只允许静态检查配置；AI 联网只测试 ChatGPT、Gemini 和 Grok。

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

- ClaudeEasy 不替你选择订阅、代理组或节点。
- Windows 的订阅增强要等订阅下次正常加载或刷新后才进入运行内核。安装完成不代表全部订阅已经生效。
- 客户端或控制器无法提供实时状态时，结果会写“未验证”，不会假装成功。
