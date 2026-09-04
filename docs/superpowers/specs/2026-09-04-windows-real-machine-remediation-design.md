# ClaudeEasy Windows 真机失败整改设计

## 结论

本次只改 Windows。目标不是在 CI 中假装证明真机已经可用，而是消除日志中已经证实的程序错误，把首次安装后的“已写入、已加载、再次生成后仍生效”分开验收，并让 Computer Use 失败后立即进入清晰的人工流程。

## 已确认的问题

### 1. YAML 块边界判断错误

Windows 安装器把与键同级缩进的合法块状列表当成下一个节点。它会漏读 `selected:`、`dns-hijack:` 和 `direct-nameserver:` 的列表，修改时还可能留下旧列表项，生成无效 YAML。

原因是两个独立解析器都用“缩进小于或等于父键”结束节点，没有把紧随映射键、与键同级缩进的 `- ...` 识别为该键的值。

### 2. 运行验收误判 IPv6 规则

Mihomo 运行接口可能把 IPv6 CIDR 规则报告为 `IPCIDR`，现有验收只接受 `IPCIDR6`，因此正确配置会被判失败。

### 3. Mihomo 自动发现只覆盖默认安装位置

朋友机器的内核位于 `D:\clash verge\verge-mihomo.exe`。现有发现逻辑只查默认目录，已经运行的自定义安装无法被识别。

### 4. PowerShell 执行策略没有贯穿子进程

公开 `.cmd` 入口可以绕过本机脚本策略，但路由验收再次启动 PowerShell 时没有传递 `-ExecutionPolicy Bypass`。因此主流程能启动，内部验收仍会被同一策略拦住。

### 5. 操作锁把权限错误误报为并发

取得 AppHome 锁时，所有 `Win32Exception` 都被解释为“另一项操作正在运行”。访问被拒绝因此引导用户反复重试一个不存在的并发问题。

### 6. 安装完成状态缺少运行加载闭环

当前安装器在写完 `Script.js` 和设置后直接返回 `installed`。这只能证明文件事务成功，不能证明 Clash Verge Rev 已重新生成当前运行配置，更不能证明以后再次生成仍保留补丁。

Clash Verge Rev v2.5.2 的官方实现会先执行全局 `Script.js`，再执行当前配置自己的脚本；应用控制字段最后再覆盖回运行配置。因此全局脚本入口方向本身成立，但一次文件写入不能证明实际执行成功。

### 7. Computer Use 没有失败熔断和人工接管

同一浏览器 URL 识别失败被重复尝试，Clash 操作也没有可靠回读。Skill 没有在失败后明确宣布能力不可用，也没有立即提供按界面位置、动作、目的和回读结果组织的小白步骤。

## 证据边界

以下内容不作为本次已确认原因：

- “必须管理员权限”；日志没有证明。
- “Boa 不兼容全局脚本”；日志只证明补丁没有稳定保留，没有捕获到脚本引擎错误。
- “Windows Computer Use 全平台不可用”；只确认该会话连续失败。

没有 Windows 真机，本次只能用 Windows CI、假控制器和真实 Mihomo 二进制覆盖可重复行为。真机界面、快捷键注册时机和 Clash Verge Rev 再生成后的长期保持，必须留到下一次真人测试确认。

## 整改架构

### A. 修正确定性底层错误

- 统一修正映射键后同级列表的范围判断；不引入完整 YAML 框架。
- 运行验收按载荷是否为 IPv6 规范化 `IPCIDR`/`IPCIDR6`。
- 从已经运行的 `verge-mihomo` 进程读取可执行文件路径，再回退到现有默认目录。
- 所有内部 PowerShell 进程显式使用 `-ExecutionPolicy Bypass`。
- 根据 Win32 错误码区分“文件占用”和“访问被拒绝”。

### B. 把安装结果拆成三个事实

1. `written`：目标文件事务成功且候选通过静态与 Mihomo 校验。
2. `loaded`：已运行客户端完成一次重新加载，控制器回读的是新运行配置且当前档位验收通过。
3. `persistent`：客户端以后再次生成配置后，补丁仍存在。

安装器只有取得已有控制器、原运行状态和已经注册的重新激活快捷键时，才自动发送一次快捷键并等待 `loaded`。不具备这些条件时，文件可以保留，但返回 `partial` 与 `runtime_activation_required`，不能再返回完整成功。

本次不新增绕过 Clash Verge Rev 生成管线的第二套 YAML 补丁器，也不自动开启新的控制器安全边界。下一次真机复测负责确认 `persistent`；在此之前完成说明必须明确“CI 已通过，真机持久生效待验证”。

### C. Computer Use 熔断和人工接管

Windows Computer Use 对同一目标连续两次没有取得可回读结果后，本任务中停止重试。代理立即说明自动操作不可用，并给出一次只做一个动作的步骤：

- 用户要点哪里；
- 要改成什么；
- 这一步的目的；
- 做完后应看到什么；
- 用户回复的固定确认语。

浏览器、Clash Verge Rev、Windows 语言和时区分别给出独立步骤。不能把多个界面动作压成“请手动完成测试”。

## 文件职责

- `claude-easy/scripts/windows/install_windows/yaml.ps1`：配置文件节点范围。
- `claude-easy/scripts/windows/install_windows/runtime.ps1`：运行 YAML、控制器回读与规则验收。
- `claude-easy/scripts/windows/install_windows/mihomo.ps1`：内核发现。
- `claude-easy/scripts/windows/install_windows/transaction.ps1`：Windows 错误分类。
- `claude-easy/scripts/windows/verify_routes.ps1`：内部验收进程启动。
- `claude-easy/scripts/install_windows.ps1`：首次安装的写入、加载和结果状态。
- `claude-easy/references/windows.md`：Computer Use 熔断与人工步骤的唯一权威来源。
- `claude-easy/references/result-contract.json`：新增机器结果状态。
- `tests/test_windows_installer.ps1`、`tests/test_windows_routes.ps1`：每个已确认错误的最低层回归。

不修改任何 `macos` 文件、macOS 测试、macOS 文档或跨平台公共行为。

## 完成标准

- 合法的同级块状列表可以读取、替换并保留 YAML 有效性。
- IPv6 CIDR 的两种 Mihomo 类型表达都能正确验收。
- 自定义目录中已经运行的 `verge-mihomo.exe` 可以自动发现。
- 受限执行策略下内部路由验收仍能启动。
- 访问被拒绝不再提示“另一项操作正在运行”。
- 有可验证控制面时，安装只发送一次重新激活并回读运行配置；没有时返回 `partial` 和明确后续动作。
- 同一 Windows Computer Use 目标两次失败后不再自动重试。
- Windows CI 全绿；Git diff 不含 macOS 文件。
- 最终说明区分 CI 证据与仍待下一台真机确认的行为。
