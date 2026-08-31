# ClaudeEasy 共同策略

> 读取路由：所有任务必须先完整读取本文件，再按 [SKILL.md](../SKILL.md) 的任务路由读取相关模块。只有跨模块维护、权威归属审查或整体一致性检查才读取全部策略文件。

## 规则归属与冲突处理

每类规则只有一个权威来源，较低层文档不得重新定义、扩展或覆盖较高层规则：

1. 本文件定义所有任务共同遵守的支持范围、冲突顺序、脚本接口、异常和输出边界。
2. [diagnostics.md](diagnostics.md)、[profiles-and-patch.md](profiles-and-patch.md)、[routing-and-security.md](routing-and-security.md)、[safe-update-and-recovery.md](safe-update-and-recovery.md)、[macos.md](macos.md) 与 [windows.md](windows.md) 分别是对应模块和平台行为的唯一权威来源；读取组合只由 [SKILL.md](../SKILL.md) 的任务路由决定。
3. [`policy.json`](policy.json) 定义解析器、规则集、分组候选和 AI 规则等配置常量；策略 Markdown 只解释用途，不复制常量清单。
4. [`result-contract.json`](result-contract.json) 定义机器输出字段、类型和状态枚举；策略 Markdown 只定义语义约束。
5. `SKILL.md` 保留触发后必须立即可见的安全边界、代理入口、模块选择、执行顺序和读取路由；README 只解释用户可见行为，不重新定义执行规则；设计文档只定义产品目标、组件边界和规则归属；`tests/baseline.md` 只记录测试覆盖范围。

冲突按以下顺序处理：用户当次明确授权和用途档位先限定可做范围；随后具体场景规则优先于通用规则，平台规则优先于跨平台摘要，事务安全规则优先于一般失败恢复规则。仍无法唯一判断时停止对应写入并报告规则冲突，不自行挑选较宽松解释。

## 支持范围

支持：

- macOS 上使用 Mihomo 内核的最新版 ClashX Meta；
- Windows 上使用 Mihomo 内核的最新版 Clash Verge Rev。

要求 Mihomo 1.19.27 或更高版本。旧版 ClashX、旧版 Clash Verge、找不到内核、版本过旧或无法确认内核能力时只检查，不修改。macOS 建议升级到 ClashX Meta；Windows 建议升级到 Clash Verge Rev。

### 跨平台共同边界

同一用户请求和同一用途档位在 macOS 与 Windows 上遵守相同的授权、隐私、客户端安全边界和用户可见完成条件。平台文件分别定义各自的实现方式与失败处理；跨平台摘要不得把两端不同的实现方式写成相同。新增或改变共同边界时，只有两个平台都实现并通过对应测试后才能报告完成。

**Claude/Anthropic 远程域名永久禁测：** 相关网站、API 和域名一律不打开、不请求、不测试。禁止通过浏览器、Computer Use、curl、脚本、DNS、WebRTC、分流验证或任何其他方式向这些域名产生测试流量；用户当次要求也不能覆盖。只允许静态检查配置，AI 联网与分流验收只测试 ChatGPT、Gemini 和 Grok。本地 `assets/claude-region-check.html` 不属于 Claude/Anthropic 域名；已保存档位为 3 时，任何配置任务都必须在收尾运行一次本地区域指纹测试，每轮调整后再运行一次，直到低风险通过。

Clash Verge Rev 有正常主窗口，Windows 当前会话按 SKILL.md 确认可用的电脑操控时可以操作已经运行的客户端。ClashX Meta 是纯菜单栏应用，没有主窗口；macOS 不得用电脑操控操作、读取或验证 ClashX Meta，也不得尝试附加一次。macOS 客户端开关只走平台原生命令和结构化验收；电脑操控仍可用于有正常窗口的浏览器和 AdGuard。能力检测、启用和缺失时的处理以 `SKILL.md` 为准，不得把 Windows 的失败处理套到 macOS 菜单栏应用。

绝对不要退出、停止或重启 Clash 客户端。不得执行、建议或要求用户执行这类操作。中国用户通常依赖客户端越过 GFW；关闭客户端会让 AI 助手断线，并可能让修复停在一半。

任何 Patch、Diagnostics、代码审查、测试或环境探测都不得运行 ClashX Meta 主程序，包括直接执行应用包中的 `ClashX Meta`、传入 `--version` 或其他参数、使用 `open` 或 LaunchServices 打开应用，以及通过 Computer Use 启动未运行的客户端。这些动作可能创建第二个客户端并中断现有 Mihomo。客户端版本只从应用的 `Info.plist` 读取；进程、日志、偏好和本地控制器用于读取运行状态；内核版本只检查 Mihomo。客户端未运行时保持未运行；无法取得实时状态时只在机器结果标记未验证，不能为检查而启动。

## 模块选择

ClaudeEasy 有两个独立模块：

- **Patch** 负责首次安装、用途变化或用户明确要求的网络配置，只应用满足已选用途所需的最少改动。
- **Diagnostics** 负责从用户的模糊描述出发，主动取证、解释、单项修复并复测。

用户说“网络不对劲”时先进入 Diagnostics。不能因为用户提到 Clash、DNS、代理或某个网站，就直接运行安装程序。单项 Clash 配置问题也留在 Diagnostics；只有档位 3 或用户明确要求完整安全增强时才运行完整补丁。

在 Diagnostics 中，只有用户明确要求完整安全增强时才进入 Patch；单纯报告故障不能视为用途选择。

## 脚本接口与内部职责

所有公开命令都显式支持 JSON v1：macOS 使用 `--json`，Windows 使用 `-Json`。默认模式继续输出中文信息，失败分支也必须输出摘要，不能只返回退出码。JSON 模式的标准输出只能有一个对象，不能混入日志；对象中的 `exit_code` 必须与进程退出码一致。`code` 和 `operation` 是稳定的机器标识，`command` 只允许 `install`、`uninstall`、`patch`、`verify_routes`。所有必填字段、状态值和字段类型以 [result-contract.json](result-contract.json) 为准。安装包任一必需模块缺失时都在修改 AppHome 前返回退出码 `6` 和 `incomplete_package`。

Skill 调用脚本时优先使用 JSON 模式，并依据字段判断结果，不解析中文文案。分流验证只报告代理组已识别和各目标的检查状态。

ClaudeEasy 的公开脚本固定在 `claude-easy/`，参数和调用方式保持兼容。内部代码按配置转换、备份与事务、Mihomo 校验、订阅处理、运行状态和 CLI 组织；入口只负责参数、编排与结果输出。拆分不能改变事务顺序、安全边界或既有退出码。

## 异常处理

- `401 unauthorized`、HTML、空文件或损坏 YAML：机器结果标记订阅无效，等待以后刷新出有效订阅。
- Mihomo 拒绝候选文件：保留原文件，机器结果标记内核校验失败。
- Mihomo 版本检查或候选校验超过 30 秒：终止本工具启动的 Mihomo 校验子进程，保留原文件，机器结果标记超时，继续处理下一份订阅。
- 候选写入前必须重新解析（YAML 重读）候选文本；解析失败按无效配置处理，保留原文件。
- YAML 候选的二次转换与第一次不同：保留原文件，机器结果标记二次转换不一致。
- 找不到 Mihomo、版本低于 1.19.27 或无法读取版本：停止安装，不写入任何目标文件。
- 读取或写入失败：保留能保留的原文件，机器结果准确区分读取或写入失败，不能伪装成订阅无效。
- 找不到主代理组：不修改，不猜节点。
- 没有已有 AI 分组，并且订阅中找不到任何有效内联节点或代理提供者：不创建空组，机器结果标记没有可用 AI 节点。
- 已有 Windows 全局脚本只有一个同步 `main`：先运行原脚本，再运行 ClaudeEasy 补丁。Clash Verge Rev 当前不会等待 Promise，因此必须拒绝 `async function main`。
- 已有 Windows 脚本结构无法安全组合：保留原文件，先直接读取本地 `Script.js` 分析；只有当前环境确实无法读取时，才请用户提供一次所需内容。
- 两端都原样保留已有的 REALITY `short-id` 文本，不补齐、不截断、不猜缺失值。macOS 读写 YAML 时显式保护容易被误判为数字的有效十六进制文本；Windows 的对象转换不得改变该字段。
- 当前配置只有自动刷新和运行检查全部通过，才能向用户说“已更新并自动生效”。刷新失败、恢复结果和内核状态写入机器结果，按完成闸门继续处理；只有真实阻塞或用户主动询问时才用日常语言说明。
- ClashX Meta 正在运行时保持运行；配置事务不通过 AppleScript 或 System Events 操作界面，不修改 `restoreTunProxy`，也不切换代理组或节点。档位要求的 TUN 与系统代理状态只由 macOS 平台策略规定的原生开关协调命令处理；Foundation JXA 只用于订阅请求。
- 远程 `proxy-providers` 在 Mihomo 写入前检查中可能需要网络；离线检查失败时保留原文件并继续诊断连接，确认设备本身未联网且无法自动恢复时，才请用户连接网络。

## 输出格式

脚本的 JSON、退出码、状态、检查项和逐订阅结果供代理内部判断，不直接复制给用户。用户可见说明统一遵守 [SKILL.md](../SKILL.md) 的“用户沟通原则”，不另设汇报清单。

```text
已经设置完成，可以正常使用。
```

未完成的机器状态不能转述成结尾。仍可安全推进时继续处理；遇到真实阻塞时只说一个用户动作，例如：“还差一步：请在系统弹窗中点‘允许’，完成后回复我。” 用户主动要求技术详情时，才按机器结果说明具体状态，并继续隐藏订阅、代理组、节点、IP、DNS 和密钥等敏感内容。
