# AdGuard 可选配置

> 只有用户明确要求配置、恢复或导入 AdGuard 时读取。本文件不触发安装、检测或自动管理。

## 入口

- 没有明确 AdGuard 请求时：忽略本文件；不扫描是否安装，不修改任何 AdGuard、系统代理或第三方 PAC。
- 用户明确请求时：用 Computer Use 操作 AdGuard 自己的正常窗口，不直接改 plist、注册表、PAC 或系统代理。
- 先在用户的 `Documents` 根目录查找 `.adguardsettings` 备份。找到用户保存的备份时，优先通过 AdGuard 的 Import Settings 导入；导入后回读关键开关。
- 没有备份时，按当前平台 UI 手动恢复下面的兼容基线，并保留未列出的项目为默认值。

## macOS + Clash TUN 基线

适用于用户明确要求把 AdGuard 与 ClashX Meta 共存配置好时：

- Filtering mode：`Automatic Proxy`；禁止切换为 `Network Extension`。
- Automatically filter applications：开启。
- Filter HTTPS protocol：开启；EV certificate filtering：开启。
- AdGuard outbound proxy：开启，协议 HTTP，主机 `127.0.0.1`，端口必须先从当前 Mihomo 的监听进程、控制器运行配置和一次代理请求三重确认；用户名和密码留空。
- Trust any certificate：关闭；SOCKS5 UDP：关闭。
- DNS protection：关闭，让 Clash TUN/DNS 保持唯一的 DNS 接管职责。
- Stealth Mode：关闭；HTTP proxy server（让其他设备使用本机 AdGuard）：关闭。
- Advanced Settings：不改，保留默认值。
- 过滤器、用户规则、已启用的 userscript 和应用范围以导入备份为准；没有备份时不擅自新增复杂规则。

完成后通过 UI 回读设置；网络复测遵守当前用途档位，不能访问或测试 Claude/Anthropic 远程域名。

## Windows

- 仅在用户明确请求时操作已运行的 AdGuard Windows 窗口。
- 有 `.adguardsettings` 备份时优先导入；没有备份时只在当前 UI 明确对应的字段中恢复用户确认过的广告过滤目标，保留平台默认的底层过滤模式。
- 不把 macOS 的 `Automatic Proxy`、`127.0.0.1:7890` 或 TUN 规则直接套到 Windows；先依据当前 Clash Verge Rev 和 AdGuard 版本的实际 UI/运行状态确定端口与兼容方式。
- 不直接编辑注册表、配置文件或系统代理；修改后回读开关并做当前档位允许的连通性复测。

## 停止条件

- 找不到备份且 UI 无法确认某个字段含义：保留原值并报告缺口，不猜测、不批量修改。
- 导入后系统权限、根证书或当前 Clash 端口不匹配：只修复用户明确授权且能通过 UI 验证的项目；不能把“导入成功”当成整机状态已恢复。
