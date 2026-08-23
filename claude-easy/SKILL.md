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

## 平台界面能力

- **Windows：** 当前环境有 Computer Use 时可操作已经运行的 Clash Verge Rev；否则按 [policy-core.md](references/policy-core.md) 与 [windows.md](references/windows.md) 给出步骤或脚本路径。
- **macOS：** 不得用 Computer Use 操作 ClashX Meta；客户端开关走 [macos.md](references/macos.md) 原生命令。Computer Use 仍可用于 Safari、Chrome、AdGuard 等有正常窗口的应用。

## 不可突破的边界

1. **绝对不要退出、停止或重启 Clash 客户端。** 不得执行、建议或要求用户这样做。
2. **不得运行 ClashX Meta 主程序做检查。** 细节见 [policy-core.md](references/policy-core.md)。
3. **Claude/Anthropic 远程域名永久禁测；** AI 联网与分流验收只测 ChatGPT、Gemini 和 Grok。细节见 [policy-core.md](references/policy-core.md) 与 [profiles-and-patch.md](references/profiles-and-patch.md) 本地区域指纹闭环。
4. 只按已保存用途档位操作，不切换订阅、代理组或节点，不覆盖第三方 PAC。macOS 只通过原生开关协调命令修改 ClashX Meta 的 TUN 和系统代理；Windows 按 [windows.md](references/windows.md) 操作 Clash Verge Rev；AdGuard for Mac 只通过它自己的正常窗口调整兼容设置。
5. 安全更新必须保留热加载，且只能走已经运行的客户端原生入口；180 秒窗口与失败处理见 [safe-update-and-recovery.md](references/safe-update-and-recovery.md) 与当前平台文件。
6. 只处理 Clash 当前存储位置中的订阅；无法确认本地或 iCloud 状态时停止，不猜。见 [macos.md](references/macos.md) 与 [profiles-and-patch.md](references/profiles-and-patch.md)。
7. 写入候选必须通过 YAML 重读、二次转换一致性检查和 Mihomo 1.19.27 以上版本的 30 秒校验；失败时保持原文件。见 [policy-core.md](references/policy-core.md)。
8. 跟随用户使用的语言。任何输出都不得包含订阅地址、密码、UUID、私钥、控制器密钥、完整节点地址或节点名称。

## 模块选择

- **Patch 模块**：首次安装、改变用途档位，或用户明确要求配置网络时使用；只应用该档位的最少能力。
- **Diagnostics 模块**：慢、间歇失败、打不开、全红、分流异常或泄漏时使用。不能因为用户提到 Clash 就先运行补丁。
- **订阅更新**：用户明确要求更新全部订阅时使用；它不是 Patch 或 Diagnostics 的隐含步骤。

## 平台入口

### macOS

```bash
bash scripts/install_macos.sh --profile N
bash scripts/uninstall_macos.sh
ruby scripts/macos/patch_profiles.rb --reconcile-client-switches --usage-profile N --json
ruby scripts/macos/verify_routes.rb
```

### Windows

```powershell
.\scripts\install_windows.cmd -UsageProfile N
.\scripts\uninstall_windows.cmd
powershell.exe -NoProfile -File scripts/windows/verify_routes.ps1
```

Windows 客户端运行时的受保护写入边界见 [windows.md](references/windows.md)。
