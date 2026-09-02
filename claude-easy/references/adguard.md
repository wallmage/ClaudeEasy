# AdGuard 可选配置

> 只有用户明确要求配置、恢复或导入 AdGuard 时读取。本文件不触发安装、检测或自动管理。

## 入口

- 没有明确 AdGuard 请求时：忽略本文件；不扫描是否安装，不修改任何 AdGuard、系统代理或第三方 PAC。
- 用户明确请求时：用 Computer Use 操作 AdGuard 自己的正常窗口，不直接改 plist、注册表、PAC 或系统代理。
- 用户原话已明确要求使用 Computer Use 时，视为本轮 AdGuard 操作授权；不重复询问相同授权。系统权限弹窗、密码、验证码和其他工具强制确认仍按平台规则处理。
- 用户明确指定非 Clash 上游或要求保留 `Network Extension` 时，与 Clash TUN 共存基线冲突就停止并报告，不自动切换或取消该设置。
- 切换过滤模式前只读确认系统 PAC 的归属；非 AdGuard 或归属不明时停止并报告，不覆盖第三方 PAC。
- 修改前通过 UI 回读并记录本轮涉及的开关、模式、代理字段、证书信任和 UDP 选项；失败时只通过 UI 恢复这份原状态并再次回读。
- 先在用户的 `Documents` 根目录查找 `.adguardsettings` 备份。找到用户保存的备份时，优先通过 AdGuard 的 Import Settings 导入；导入后回读关键开关。
- 没有备份时，按当前平台 UI 手动恢复下面的兼容基线，并保留未列出的项目为默认值。

## 配置表

### macOS（用户确认基线）

适用于用户明确要求把 AdGuard 与 ClashX Meta 共存配置好、且当前用途档位为 2 或 3 时：

档位 1 依赖 Clash 系统代理，不适用这套 `Automatic Proxy` 基线；保持原过滤模式并报告冲突。

- Filtering mode：`Automatic Proxy`；禁止切换为 `Network Extension`。
- General：开启 Launch at Login 和 Activate language-specific filters automatically；Do not block search ads、Hide menu bar icon、Send anonymized app usage data 保持关闭。
- Filters：只启用 AdGuard Base filter、AdGuard Tracking Protection filter、AdGuard Social Media filter、AdGuard Chinese filter；User rules、URL Tracking filter 和其他过滤器保持关闭，除非导入备份明确包含用户规则。
- Automatically filter applications：开启。
- Filter HTTPS protocol：开启；EV certificate filtering：开启。
- AdGuard outbound proxy（Clash TUN 共存基线）：关闭；不填写或管理主机、端口、用户名和密码。过滤后的流量由 Clash TUN 接管，避免切换订阅或节点时产生端口耦合。若现有值是用户指定的非 Clash 上游，除非用户明确要求取消，否则保留并报告，不套用此项；归属不明时同样不改。
- Trust any certificate：关闭；SOCKS5 UDP：关闭。
- DNS protection：关闭，让 Clash TUN/DNS 保持唯一的 DNS 接管职责。
- Stealth Mode：关闭；HTTP proxy server（让其他设备使用本机 AdGuard）：关闭。
- Security：开启 Phishing and malware protection；关闭匿名安全过滤器开发数据共享。
- Assistant：不调整；已有 Safari Assistant 扩展保持原状态。
- Extensions：总开关关闭；尤其关闭 AdGuard Extra，不手动启用其他 userscript。
- Advanced Settings：不改，保留默认值。
- 过滤器、用户规则、已启用的 userscript 和应用范围以导入备份为准；没有备份时不擅自新增复杂规则。

完成后通过 UI 回读 Filtering mode、AdGuard outbound proxy 和 HTTPS 过滤状态；网络复测遵守当前用途档位，不能访问或测试 Claude/Anthropic 远程域名。

### Windows（平台专属基线）

- 仅在用户明确请求时操作已运行的 AdGuard Windows 窗口。
- 有 `.adguardsettings` 备份时优先导入；没有备份时只在当前 UI 明确对应的字段中恢复用户确认过的广告过滤目标，保留平台默认的底层过滤模式。
- 通用开关：开启自动启动、按语言启用过滤器、HTTPS 过滤、Phishing and malware protection；只启用 Base、Tracking Protection、Social Media、Chinese 四类（若当前版本提供）；DNS protection、Stealth、userscript/Extensions 总开关关闭；Assistant 不调整。
- DNS：Clash Verge Rev 已接管 TUN/DNS 时关闭 AdGuard DNS protection；未接管时保留原值，不擅自改变两个 DNS 所有者。
- 网络驱动：不设置 macOS 的 `Network Extension` 或 `Automatic Proxy`。保留 Windows 默认 WFP/SockFilter；只有实测兼容性问题且用户明确要求修复时，才调整 `Use redirect driver mode` 或 `Filter localhost`。
- 代理：不把 macOS 的 `127.0.0.1:7890` 或 Clash 入站端口套到 Windows。`Use AdGuard as an HTTP proxy` 保持关闭；只有用户明确指定非 Clash 上游、且 Windows 当前 UI 提供对应字段时，才填写并验证；未获授权的现有上游保留并报告。
- 不直接编辑注册表、配置文件或系统代理；修改后回读开关并做当前档位允许的连通性复测。

## 停止条件

- 找不到备份且 UI 无法确认某个字段含义：保留原值并报告缺口，不猜测、不批量修改。
- 导入后系统权限、根证书或过滤模式不匹配：只修复用户明确授权且能通过 UI 验证的项目；非 Clash 上游仅在用户明确要求时检查；不能把“导入成功”当成整机状态已恢复。
