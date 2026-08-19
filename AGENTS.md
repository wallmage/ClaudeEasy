# ClaudeEasy 开发约定

## 执行

- 每次项目改动需要 commit 和 push 时，无论改动是否直接位于 `claude-easy/`，都必须在同一流程中把仓库里的 `claude-easy/` 安装到 `~/.codex/skills/claude-easy/`。如果 `~/.agents/skills/claude-easy/` 存在，也要同步安装 Agents 副本。新副本必须逐文件校验一致；安装或校验失败时不得把任务报告为完成，也不得要求用户另行手动处理。
- `README.md` 只解释用户可见行为，`claude-easy/SKILL.md` 规定触发后必须立即可见的安全边界、代理入口、执行顺序和策略读取路由；设计文档只保存产品目标与组件边界，`tests/baseline.md` 只记录现行自动化测试范围。较低层文档不得复制后重新定义上层规则。
- 策略按职责拆分：`policy-core.md` 保存所有任务共同边界；`diagnostics.md` 保存诊断与证据规则；`profiles-and-patch.md` 保存用途档位与 Patch；`routing-and-security.md` 保存 DNS、TUN、代理组、AI 与 WebRTC；`safe-update-and-recovery.md` 保存安全更新、备份与恢复；`macos.md` 和 `windows.md` 分别保存平台事务。`policy.json` 保存配置常量，`result-contract.json` 保存机器输出合同。
- 运行 Skill 时始终先读 `policy-core.md`，再按 `SKILL.md` 的任务表读取对应模块和当前平台文件；只有跨模块维护、权威归属审查或整体一致性检查才读取全部策略。维护规则时先修改所属策略、代码和测试，再同步入口与架构说明。
- 功能需求变化时，先修改所属权威来源、代码和测试；其他文档只同步用户摘要、执行入口或架构影响，不重复整套规则。

## 项目边界

- 只支持 macOS 的 ClashX Meta 和 Windows 的 Clash Verge Rev；要求受支持版本的 Mihomo。
- 绝不退出、停止或重启 Clash。只有用户已选用途档位明确要求时，才通过客户端界面切换 TUN 或 Clash 自己的系统代理；AdGuard for Mac 只允许按已验证的兼容规则通过它自己的界面切换过滤模式，绝不改写第三方 PAC，也不切换订阅、代理组或节点。
- 不得运行 ClashX Meta 主程序做诊断、审查、测试、版本查询或只读探测；禁止直接执行应用包主程序、传入 `--version`、用 `open`/LaunchServices 打开应用，或通过 Computer Use 启动未运行的客户端。客户端版本读取 `Info.plist`，实时状态读取进程、日志、偏好或本地控制器，内核版本检查 Mihomo；客户端未运行时保持未运行。
- 已保存用途档位同时约束 Patch 和 Diagnostics；故障报告不能自动升档，诊断、修复和复测不得超出当前档位。
- 不泄露订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。
- 不实现订阅后台监听。档位 3 必须关闭订阅自动更新；订阅更新只能由用户显式触发“安全更新”，并覆盖当前存储位置中的全部远程订阅。
- macOS 和 Windows 的订阅更新都不得添加、固定或伪造 User-Agent；服务商限制只能通过用户开启订阅开关处理，不能靠 User-Agent 绕过。
- 文档、代码和测试必须描述同一套现行行为，不保留已经取消的方案。

## 测试与发布

完成说明只报告实际运行过的测试和 Git 状态。未读取的 CI 不能称为已经通过。
