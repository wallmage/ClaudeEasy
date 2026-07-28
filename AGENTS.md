# ClaudeEasy 开发约定

## 执行

- 需求明确且在已有授权范围内时，从实现、验证、安装到提交推送连续做完。不得停在方案、计划、等待用户操作或“尚未提交”的中间状态，也不得要求用户重复确认；只有缺少必要权限或操作会明显超出用户授权时才能停下。
- 始终在 `main` 上工作，不使用 worktree、功能分支或 PR。
- 实际修改项目后，除非用户明确要求不要提交，否则自动完成本地测试、commit 和 push，让 GitHub CI 自动运行。不得把“尚未 commit 或 push”作为常规收尾。
- 每次项目改动需要 commit 和 push 时，无论改动是否直接位于 `claude-easy/`，都必须在同一流程中把仓库里的 `claude-easy/` 安装到 `~/.codex/skills/claude-easy/`。如果 `~/.agents/skills/claude-easy/` 存在，也要同步安装 Agents 副本。新副本必须逐文件校验一致；安装或校验失败时不得把任务报告为完成，也不得要求用户另行手动处理。
- 文档位置固定。不得自行新增需求汇总、入口、方案或计划文档：`README.md` 面向用户，`claude-easy/SKILL.md` 规定代理流程，`claude-easy/references/patch-policy.md` 保存详细产品规则，`docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md` 保存产品需求与架构，`tests/baseline.md` 记录现行自动化测试范围。
- 功能需求变化时，代码、Skill 和相关产品文档必须在同一次改动中同步更新。

## 项目边界

- 只支持 macOS 的 ClashX Meta 和 Windows 的 Clash Verge Rev；要求受支持版本的 Mihomo。
- 绝不退出、停止或重启 Clash。只有用户已选用途档位明确要求时，才通过客户端界面切换 TUN 或 Clash 自己的系统代理；AdGuard for Mac 只允许按已验证的兼容规则通过它自己的界面切换过滤模式，绝不改写第三方 PAC，也不切换订阅、代理组或节点。
- 已保存用途档位同时约束 Patch 和 Diagnostics；故障报告不能自动升档，诊断、修复和复测不得超出当前档位。
- 不泄露订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。
- 不加入 Apple、iCloud、Speedtest 等个人规则。
- 不实现订阅后台监听。档位 3 必须关闭订阅自动更新；订阅更新只能由用户显式触发“安全更新”，并覆盖当前存储位置中的全部远程订阅。
- 文档、代码和测试必须描述同一套现行行为，不保留已经取消的方案。

## 测试与发布

提交前运行：

```sh
ruby tests/test_macos_patcher.rb
ruby tests/coverage_ruby.rb
ruby tests/test_macos_wrappers.rb
ruby tests/test_skill_contract.rb
ruby tests/test_mutation_safety.rb
node --test tests/test_region_fingerprint_page.js
node --experimental-test-coverage --test --test-coverage-include=claude-easy/scripts/windows/clash_verge_global.js --test-coverage-lines=100 --test-coverage-functions=100 --test-coverage-branches=80 tests/test_windows_patcher.js
ruby tests/generate_windows_policy.rb --check
ruby -c claude-easy/scripts/macos/patch_profiles.rb
ruby -c claude-easy/scripts/macos/verify_routes.rb
node --check claude-easy/scripts/windows/clash_verge_global.js
sh -n claude-easy/scripts/install_macos.sh
sh -n claude-easy/scripts/uninstall_macos.sh
git diff --check
```

Windows PowerShell 5.1 的行为由 GitHub CI 验证。

每次 commit 或 push 前读取 `main` 上一次 `Test` workflow：失败则查看日志并修复；仍在运行或暂时无法访问时如实记录，不等待。随后自动在 `main` 上 commit、push，由 GitHub 启动 CI。push 后不轮询 CI，下次提交前再检查。

完成说明只报告实际运行过的测试和 Git 状态。未读取的 CI 不能称为已经通过。
