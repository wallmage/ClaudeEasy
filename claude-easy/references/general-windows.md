# ClaudeEasy 通用诊断 Windows 策略

> 读取路由：内部路由为 `general_computer` 且当前设备是 Windows 时读取本文件。只回答如何取得证据和如何安全执行。

## 能力检测

Computer Use 操作正常 Windows 应用、Task Manager、Settings 或其他必要界面时，先确认当前会话实际可调用、且能操作该窗口。只会控制浏览器标签页时，不能用来点 Settings、Task Manager 或其他桌面窗口。每次界面操作后立刻回读可见结果；回读失败则该次观察未完成。

没有可用 Computer Use 时，记为界面能力缺失，继续用本文件的系统接口回答仍能回答的问题。

PowerShell、Event Viewer、Reliability Monitor、性能计数器、进程和文件系统证据都是可用手段，不为它们做启动检测或固定调用清单。某项手段本机不存在、权限不足或调用失败时，只记该手段缺失，改用另一项仍能回答同一问题的本机手段。

## 原场景与界面操作

原场景落在有正常窗口的应用时，Computer Use 可用则按用户实际动作操作一次，并回读窗口标题、对话框和界面状态。

可以安全启动或操作用户要求诊断的普通应用：用该应用的快捷方式、Start 菜单或已安装可执行文件打开。不要套用 macOS 的 `open`、LaunchServices、Apple Event 或“活动监视器”。

## 按问题选择系统证据

只响应 `general-diagnostics.md` 提出的一个明确问题，或一组不可分割的同源读取。下列名称是可用手段，不是启动清单。不要把 `log show`、`mdfind`、`pmset`、`diskutil` 或 `~/Library/Logs/DiagnosticReports` 搬到 Windows。

- 进程：PowerShell `Get-Process`、`Get-CimInstance Win32_Process`；需要窗口时只读 Task Manager 对应行。只取与当前问题直接相关的进程名、PID、CPU、内存或打开句柄。
- 文件系统：只在与当前问题有直接关系的路径上用 `Get-Item`、`Get-ChildItem` 或限定该路径树的搜索。不无边界扫描用户配置目录或全盘。
- 性能：问题指向资源争用时用 `Get-Counter`、Resource Monitor 或 Task Manager 的短窗口计数。
- 电源：问题指向睡眠、唤醒或供电时用 `powercfg` 或 Settings 的电源页。
- 磁盘：问题指向该卷完整性时，用 `Get-Volume` 或 Settings 存储页只读信息。
- 可靠性与崩溃：问题指向崩溃或历史不稳定时，用 Reliability Monitor，或 `%LOCALAPPDATA%\CrashDumps` 与 `C:\ProgramData\Microsoft\Windows\WER` 中与目标应用和时间窗匹配的报告，只读必要字段。

不读取与当前问题无关的邮件、聊天、凭据、浏览器完整历史或文件正文。路径、时间、大小或类型已够回答时，不打开内容字段。

## 日志和历史时间窗

Windows 事件用 `Get-WinEvent` 或 Event Viewer，过滤器只带当前问题需要的时间窗、Provider、Event ID 或来源。不导出整份 Application/System 日志。时间窗来自用户描述或已读记录。

Reliability Monitor 只在需要应用崩溃或安装变更的历史时间线时打开；Computer Use 打开后回读对应条目，不留下持续采集。

通用判断要求建立观察窗口时，采集必须写明范围（哪些进程、事件日志、计数器或界面）、开始时间、停止条件（复现一次、到达约定期限、或已能回答该问题）和清理方法（停止本轮开始的持续事件订阅或 `logman` 会话、删除本轮临时输出）。不创建计划任务或常驻服务。

## 权限与安全修改

不把管理员权限当作默认。需要提升或 UAC 才能继续时，由当前工具或 Settings 触发系统授权弹窗。电脑操控不能代替用户处理 UAC。不能让用户复制长命令。

修改前记下足够原样恢复的原状态：原文件字节或版本化副本、改动过的注册表值、原服务或进程是否在跑、原设置项。

结束进程、清理、Repair、重启、重装和降级遵守与 macOS 相同的风险和恢复结果，按实际数据与恢复风险决定授权，不能为了省事执行：

- 退出应用或结束进程：会丢失未保存工作或中断该应用时先取得授权。
- 清理缓存或临时文件：可能丢掉本地数据或登录态时先取得授权；只删已确认对象，并留下可恢复副本或可重建路径。
- Repair：按已确认对象选用 Settings 里该应用的 Repair、`Repair-Volume` 或系统组件修复；会锁定卷、改系统文件或影响数据时先取得授权。不把管理员 Repair 当作默认第一步。
- 重启或注销：会中断未保存工作或其他会话时先取得授权。
- 重装或降级：会丢掉应用数据或改变版本时先取得授权。

失败或出现副作用时立即按记录的方法恢复。

## 恢复与复测

恢复写成可在本机执行的步骤：用保存的字节或副本放回原路径、写回原注册表值或 Settings 项、按记录恢复服务或进程。用 PowerShell、Settings 或资源管理器完成本机恢复，不要套用 macOS 的 `defaults` 或 `diskutil`。

复测按通用判断指定的原场景进行。Computer Use 可用时在原界面回读；否则用该应用的结构化状态或同一动作的系统结果。本文件不判断是否已经解决。

## 平台限制

- 工具缺失、权限被拒或 Computer Use 不可用时，向通用判断返回该手段的缺失状态。
- 本文件不提供每次开机都要跑的检查清单。
- Windows 证据和操作只用本机原生能力；同一风险结果不得靠复制 macOS 命令、日志来源或应用行为实现。
