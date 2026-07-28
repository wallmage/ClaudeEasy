require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"
require_relative "support/macos_runtime_fixture"

ROOT = File.expand_path("..", __dir__)
SKILL = File.join(ROOT, "claude-easy")

class SkillContractTest < Minitest::Test
  include MacosRuntimeFixture

  REQUIRED_PUBLIC_FILES = %w[
    README.md
    claude-easy/SKILL.md
    claude-easy/agents/openai.yaml
    claude-easy/assets/claude-region-check.html
    claude-easy/references/patch-policy.md
    claude-easy/references/policy.json
    claude-easy/references/result-contract.json
    claude-easy/scripts/install_macos.sh
    claude-easy/scripts/install_windows.ps1
    claude-easy/scripts/install_windows.cmd
    claude-easy/scripts/uninstall_macos.sh
    claude-easy/scripts/uninstall_windows.ps1
    claude-easy/scripts/uninstall_windows.cmd
    claude-easy/scripts/macos/operation_lock.rb
    claude-easy/scripts/macos/patch_profiles.rb
    claude-easy/scripts/macos/patch_profiles/transform.rb
    claude-easy/scripts/macos/patch_profiles/backups.rb
    claude-easy/scripts/macos/patch_profiles/mihomo.rb
    claude-easy/scripts/macos/patch_profiles/profile_writer.rb
    claude-easy/scripts/macos/patch_profiles/subscriptions.rb
    claude-easy/scripts/macos/patch_profiles/runtime.rb
    claude-easy/scripts/macos/patch_profiles/cli.rb
    claude-easy/scripts/macos/result_contract.rb
    claude-easy/scripts/macos/verify_routes.rb
    claude-easy/scripts/windows/verify_routes.ps1
    claude-easy/scripts/windows/clash_verge_global.js
    claude-easy/scripts/windows/result_contract.ps1
    claude-easy/scripts/windows/install_windows/common.ps1
    claude-easy/scripts/windows/install_windows/yaml.ps1
    claude-easy/scripts/windows/install_windows/profiles.ps1
    claude-easy/scripts/windows/install_windows/mihomo.ps1
    claude-easy/scripts/windows/install_windows/transaction.ps1
    claude-easy/scripts/windows/install_windows/script_js.ps1
    claude-easy/scripts/windows/install_windows/safe_update.ps1
    .github/workflows/test.yml
    tests/fixtures/main_group_cases.json
    tests/baseline.md
    tests/coverage_ruby.rb
    tests/generate_windows_policy.rb
    tests/run_macos_production_probes.rb
    tests/support/macos_runtime_fixture.rb
    tests/test_macos_patcher.rb
    tests/test_macos_wrappers.rb
    tests/test_mutation_safety.rb
    tests/test_region_fingerprint_page.js
    tests/test_skill_contract.rb
    tests/test_windows_installer.ps1
    tests/test_windows_patcher.js
    docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md
    LICENSE
  ].freeze

  def windows_installer_source
    paths = [File.join(SKILL, "scripts/install_windows.ps1")] +
      Dir[File.join(SKILL, "scripts/windows/install_windows/*.ps1")].sort
    paths.map { |path| File.binread(path).force_encoding("UTF-8") }.join("\n")
  end

  def mac_patcher_source
    paths = [File.join(SKILL, "scripts/macos/patch_profiles.rb")] +
      Dir[File.join(SKILL, "scripts/macos/patch_profiles/*.rb")].sort
    paths.map { |path| File.read(path) }.join("\n")
  end

  def test_all_distribution_files_exist
    missing = REQUIRED_PUBLIC_FILES.reject { |path| File.file?(File.join(ROOT, path)) }
    assert_empty missing, "missing public files: #{missing.join(', ')}"
  end

  def test_release_archive_is_self_contained_and_runs_from_a_unicode_space_path
    release_files = REQUIRED_PUBLIC_FILES.select do |path|
      path == "README.md" || path == "LICENSE" || path.start_with?("claude-easy/")
    end
    Dir.mktmpdir("claude-easy-release-") do |directory|
      package_name = "ClaudeEasy 发布包"
      staging = File.join(directory, "staging")
      package_root = File.join(staging, package_name)
      release_files.each do |relative|
        destination = File.join(package_root, relative)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(ROOT, relative), destination, preserve: true)
      end

      archive = File.join(directory, "claude-easy-release.tar")
      _output, _error, status = Open3.capture3(
        "tar", "-cf", archive, "-C", staging, package_name
      )
      assert status.success?, "release archive creation failed"

      listing, _error, status = Open3.capture3("tar", "-tf", archive)
      assert status.success?, "release archive listing failed"
      entries = listing.lines.map(&:chomp)
      refute entries.any? { |entry| entry.start_with?("/") || entry.split("/").include?("..") }
      release_files.each { |relative| assert_includes entries, "#{package_name}/#{relative}" }

      extracted = File.join(directory, "extracted")
      FileUtils.mkdir_p(extracted)
      _output, _error, status = Open3.capture3("tar", "-xf", archive, "-C", extracted)
      assert status.success?, "release archive extraction failed"
      unpacked = File.join(extracted, package_name)
      install_macos = File.join(unpacked, "claude-easy/scripts/install_macos.sh")
      uninstall_macos = File.join(unpacked, "claude-easy/scripts/uninstall_macos.sh")
      patcher = File.join(unpacked, "claude-easy/scripts/macos/patch_profiles.rb")
      windows_engine = File.join(unpacked, "claude-easy/scripts/windows/clash_verge_global.js")
      assert File.executable?(install_macos)
      assert File.executable?(uninstall_macos)

      [install_macos, uninstall_macos].each do |script|
        _output, _error, status = Open3.capture3("sh", "-n", script)
        assert status.success?, "extracted shell entrypoint failed syntax validation"
        _output, _error, status = Open3.capture3({ "HOME" => directory }, "sh", script, "--help")
        assert status.success?, "extracted shell help entrypoint failed"
      end
      _output, _error, status = Open3.capture3(RbConfig.ruby, patcher, "--help")
      assert status.success?, "extracted Ruby entrypoint failed"
      _output, _error, status = Open3.capture3("node", "--check", windows_engine)
      assert status.success?, "extracted Windows JavaScript entrypoint failed syntax validation"

      profile_directory = File.join(directory, "用户 配置")
      FileUtils.mkdir_p(profile_directory)
      File.write(File.join(profile_directory, "friend.yaml"), <<~YAML)
        mixed-port: 7890
        proxies:
          - name: node
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: Main
            type: select
            proxies: [node]
        rules:
          - MATCH,Main
      YAML
      _output, _error, status = Open3.capture3(
        RbConfig.ruby, patcher, "--profile-dir", profile_directory,
        "--usage-profile", "1", "--dry-run"
      )
      assert status.success?, "extracted release could not patch a profile from a Unicode path"

      if RUBY_PLATFORM.include?("darwin")
        release_home = File.join(directory, "安装 用户")
        fake_core = File.join(
          release_home, "Applications", "ClashX Meta.app", "Contents", "Resources",
          "com.metacubex.ClashX.ProxyConfigHelper.meta"
        )
        FileUtils.mkdir_p(File.dirname(fake_core))
        File.write(fake_core, <<~SH)
          #!/bin/sh
          if [ "${1:-}" = "-v" ]; then
            printf '%s\n' 'Mihomo Meta v1.19.27 release-test'
          fi
          exit 0
        SH
        FileUtils.chmod(0o700, fake_core)
        preferences_fixture = write_release_preferences_fixture(directory)
        release_usage_state = File.join(
          release_home, "Library", "Application Support", "ClaudeEasy", "usage-profile.plist"
        )
        release_env = {
          "HOME" => release_home,
          "RUBYOPT" => "-r#{preferences_fixture}",
          "CLAUDE_EASY_PROFILE_DIR" => profile_directory,
          "CLAUDE_EASY_USAGE_STATE_PATH" => nil,
          "CLAUDE_EASY_USAGE_PROFILE" => nil
        }
        controller_server, controller_thread, controller_socket_path, controller_requests =
          start_release_controller(release_home)
        connectivity_server, connectivity_thread =
          start_release_connectivity_server(release_home)
        begin
          probe = <<~RUBY
            context = ClaudeEasy.capture_runtime_profile_context([ARGV.fetch(0)])
            puts JSON.generate(
              selected: ClaudeEasy.selected_profile_name,
              context: context,
              socket: ClaudeEasy.controller_socket
            )
            exit(
              context && context[:selected] == "friend" &&
              context[:active_path] == File.realpath(File.join(ARGV.fetch(0), "friend.yaml")) &&
              ClaudeEasy.controller_socket ? 0 : 1
            )
          RUBY
          probe_output, probe_error, probe_status = Open3.capture3(
            release_env, RbConfig.ruby, "-r#{patcher}", "-e", probe, profile_directory
          )
          assert probe_status.success?,
                 "isolated release runtime context was unavailable: #{probe_error}#{probe_output}"
          output, error, status = Open3.capture3(
            release_env, "sh", install_macos, "--profile", "1", "--json"
          )
        ensure
          stop_release_runtime_fixture(
            controller_server: controller_server,
            controller_thread: controller_thread,
            controller_socket_path: controller_socket_path,
            connectivity_server: connectivity_server,
            connectivity_thread: connectivity_thread
          )
        end
        assert status.success?,
               "extracted public installer failed after #{controller_requests.inspect}: #{error}#{output}"
        assert_empty error
        result = JSON.parse(output)
        assert_equal status.exitstatus, result.fetch("exit_code")
        assert_equal "install", result.fetch("command")
        assert result.fetch("ok")
        assert File.file?(release_usage_state)
        patched_profile = YAML.safe_load(File.read(File.join(profile_directory, "friend.yaml")))
        assert patched_profile.fetch("rule-providers").key?("claude-easy-cn-domain")
      end
    end
  end

  def test_tests_and_product_spec_are_distributed_but_generated_material_is_ignored
    ignore = File.read(File.join(ROOT, ".gitignore"))
    ignore_lines = ignore.lines.map(&:strip)

    assert_includes ignore_lines, "docs/*"
    assert_includes ignore_lines, "!docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"
    refute_includes ignore.lines.map(&:strip), "tests/baseline.md"
    refute_includes ignore.lines.map(&:strip), "tests/"
    assert_includes ignore.lines.map(&:strip), "dist/"
  end

  def test_agent_instructions_execute_clear_requests_without_reconfirmation
    instructions = File.read(File.join(ROOT, "AGENTS.md"))
    assert_includes instructions, "从实现、验证、安装到提交推送连续做完"
    assert_includes instructions, "不得要求用户重复确认"
    assert_includes instructions, "不得自行新增需求汇总、入口、方案或计划文档"
    assert_includes instructions, "实际修改项目后"
    assert_includes instructions, "自动完成本地测试、commit 和 push"
    assert_includes instructions, "不得把“尚未 commit 或 push”作为常规收尾"
  end

  def test_public_guides_define_their_roles_and_point_to_detailed_policy
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes readme, "本文档面向用户"
    assert_includes readme, "给代理执行的流程规定在 `claude-easy/SKILL.md`"
    assert_includes readme, "产品规则和全部状态文案以 `claude-easy/references/patch-policy.md` 为准"
    assert_includes skill, "开始前完整阅读 [references/patch-policy.md](references/patch-policy.md)"
    assert_includes skill, "详细产品规则和全部状态以该文件为准"
    assert_includes policy, "# ClaudeEasy 策略"
  end

  def test_canonical_brand_spelling_is_single_word
    spaced_brand = ["Claude", "Easy"].join(" ")
    product_files = [
      File.join(ROOT, "README.md"),
      File.join(ROOT, "AGENTS.md"),
      File.join(SKILL, "SKILL.md"),
      File.join(SKILL, "agents/openai.yaml"),
      File.join(SKILL, "references/patch-policy.md"),
      File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
    ] + Dir.glob(File.join(SKILL, "scripts/**/*.{rb,js,ps1,sh,cmd}"))

    offenders = product_files.select do |path|
      source = File.read(path)
      source.include?(spaced_brand) || source.upcase.include?("CLAUDE EASY")
    end
    assert_empty offenders, "product brand must be spelled ClaudeEasy: #{offenders.join(', ')}"

    assert_equal "# ClaudeEasy", File.foreach(File.join(ROOT, "README.md")).first.chomp
    readme = File.read(File.join(ROOT, "README.md"))
    assert_includes readme, "https://github.com/wallmage/ClaudeEasy.git"
    assert_includes readme, "与 Anthropic 没有隶属或官方合作关系"
    assert_includes File.read(File.join(SKILL, "SKILL.md")), "# ClaudeEasy 配置与诊断"
    metadata = YAML.safe_load(File.read(File.join(SKILL, "agents/openai.yaml")))
    assert_equal "ClaudeEasy 配置与诊断", metadata.dig("interface", "display_name")
  end

  def test_retired_project_name_is_absent_from_repository
    client_word = "clash"
    profile_word = "profile"
    change_word = "patch"
    retired_name = Regexp.new(
      "#{Regexp.escape(client_word)}[\\s_-]*(?:#{Regexp.escape(profile_word)}[\\s_-]*)?" \
      "#{Regexp.escape(change_word)}(?:er)?",
      Regexp::IGNORECASE
    )
    retired_localized_name = Regexp.new("#{Regexp.escape(client_word)}\\s*补丁", Regexp::IGNORECASE)
    offenders = []
    paths = Dir.glob(File.join(ROOT, "**", "*"), File::FNM_DOTMATCH)
               .reject { |path| path == File.join(ROOT, ".git") || path.start_with?(File.join(ROOT, ".git", "")) }

    paths.each do |path|
      relative = path.delete_prefix("#{ROOT}/")
      offenders << relative if relative.match?(retired_name) || relative.match?(retired_localized_name)
      next unless File.file?(path)

      File.binread(path).force_encoding("UTF-8").scrub.each_line.with_index(1) do |line, number|
        if line.match?(retired_name) || line.match?(retired_localized_name)
          offenders << "#{relative}:#{number}:#{line.strip}"
        end
      end
    end

    assert_empty offenders, "retired project name remains:\n#{offenders.join("\n")}"
  end

  def test_skill_exposes_patch_and_diagnostics_as_separate_modules
    skill = File.read(File.join(SKILL, "SKILL.md"))
    metadata = YAML.safe_load(skill.match(/\A---\n(.*?)\n---/m)[1])

    assert_includes metadata.fetch("description"), "diagnose"
    assert_includes metadata.fetch("description"), "slow"
    assert_includes metadata.fetch("description"), "intermittent"
    assert_includes skill, "Patch 模块"
    assert_includes skill, "Diagnostics 模块"
    assert_includes skill, "不能因为用户提到 Clash 就先运行补丁"
    assert_includes skill, "Diagnostics 默认只读"
  end

  def test_patch_module_selects_and_remembers_the_minimum_usage_profile
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))
    mac_installer = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    mac_uninstaller = File.read(File.join(SKILL, "scripts/uninstall_macos.sh"))
    windows_installer = windows_installer_source

    [readme, skill, policy, design].each do |document|
      %w[普通浏览 海外\ AI Claude/Claude\ Code].each do |profile|
        assert_includes document, profile.gsub("\\ ", " ")
      end
      assert_includes document, "首次"
      assert_includes document, "保存"
      assert_includes document, "修改"
    end

    assert_includes skill, "你使用网络代理主要用于哪些用途"
    assert_includes skill, "没有已保存档位"
    assert_includes skill, "明确表达 `Claude` 或 `Claude Code`"
    refute_includes skill, "语音输入中的 `cloud`"
    refute_includes readme, "语音输入中的 `cloud`"
    refute_includes policy, "语音输入把 Claude 识别为 `cloud`"
    refute_includes design, "语音输入 `cloud`"
    assert_includes policy, "只应用满足已选用途所需的最少改动"

    assert_includes mac_installer, "CLAUDE_EASY_USAGE_PROFILE"
    assert_includes mac_installer, "usage-profile.plist"
    refute_includes mac_installer, "CLAUDE_EASY_USAGE_STATE_PATH"
    refute_includes mac_uninstaller, "CLAUDE_EASY_USAGE_STATE_PATH"
    assert_includes mac_installer, "--profile"
    assert_includes windows_installer, "CLAUDE_EASY_USAGE_PROFILE"
    assert_includes windows_installer, "claude-easy-usage-profile.json"
    assert_includes windows_installer, "UsageProfile"
  end

  def test_each_usage_profile_has_distinct_actions_and_acceptance_tests
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    [skill, policy].each do |document|
      assert_includes document, "档位 1"
      assert_includes document, "档位 2"
      assert_includes document, "档位 3"
      assert_includes document, "Google"
      assert_includes document, "Twitter"
      assert_includes document, "ChatGPT"
      assert_includes document, "Gemini"
      assert_includes document, "Claude"
    end

    assert_includes policy, "档位 1 不修改 TUN"
    assert_includes policy, "共同国内域名直连基线"
    assert_includes policy, "档位 2 不增加 WebRTC 或 AI 分组补丁"
    assert_includes policy, "只关闭 Clash 客户端自己的系统代理开关"
    assert_includes policy, "不得清除或覆盖 AdGuard"
    assert_includes policy, "不是为了隐藏代理"
    assert_includes policy, "台湾家宽优先，其次日本家宽"
    assert_includes policy, "不得自动切换节点"
  end

  def test_profile_three_closes_the_claude_region_fingerprint_loop_in_the_system_browser
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))

    [readme, skill, policy, design].each do |document|
      assert_includes document, "assets/claude-region-check.html"
      assert_includes document, "离线"
      assert_includes document, "Safari"
      assert_includes document, "Chrome"
      assert_includes document, "Windows"
      assert_includes document, "绿色"
      assert_includes document, "低风险"
      assert_includes document, "0–30"
      assert_includes document, "20 分"
      assert_includes document, "区域指纹"
      assert_includes document, "DNS、WebRTC"
      assert_includes document, "估计"
    end

    [skill, policy].each do |document|
      assert_includes document, "系统默认浏览器"
      assert_includes document, "Computer Use"
      assert_includes document, "不得使用 Codex 内置浏览器"
      assert_includes document, "开始检测"
      assert_includes document, "重新扫描"
      assert_includes document, "修改后的系统默认浏览器"
      assert_includes document, "修改前基线"
      assert_includes document, "不得写死"
      assert_includes document, "未验证"
      assert_includes document, "最多等待 60 秒"
      assert_includes document, "只刷新一次"
      assert_includes document, "有限信息"
      assert_includes document, "本地检测页不可用"
      assert_includes document, "浏览器未暴露的信息不计分"
      assert_includes document, "其他默认浏览器"
      assert_includes document, "补测其余八项"
      assert_includes document, "兼容性限制"
      assert_includes document, "重新计算总分和风险档"
    end

    [readme, skill, policy, design].each do |document|
      refute_includes document, "https://fuck-claude.vercel.app/zh/"
      refute_includes document, "Google Analytics"
    end

    assert_operator skill.index("修改前基线"), :<, skill.index("运行平台安装程序")
    assert_operator policy.index("修改前基线"), :<, policy.index("运行平台安装程序")
  end

  def test_profile_three_classifies_region_signals_and_requires_consent_for_user_preferences
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    [skill, policy].each do |document|
      %w[
        Asia/Taipei
        zh-TW
        en-US
        ANTHROPIC_BASE_URL
        已安装中文字体
        国产厂商字体
        国产浏览器
        国产品牌设备
        时区偏移
        Emoji
      ].each { |term| assert_includes document, term }
      assert_includes document, "征得用户同意"
      assert_includes document, "浏览器语言与 Intl 区域设置"
      assert_includes document, "不得删除中文字体"
      assert_includes document, "只说明当前用于检测的浏览器"
      assert_includes document, "不得伪装设备或 User-Agent"
      assert_includes document, "UTC+8"
      assert_includes document, "不会改变当前时间"
      assert_includes document, "Safari 或 Chrome"
      assert_includes document, "Edge 或 Chrome"
      assert_includes document, "完整 hostname"
      assert_includes document, "向下滚动"
      assert_includes document, "一次申请"
      assert_includes document, "只回复“同意”"
      assert_includes document, "默认使用繁体中文"
      assert_includes document, "台湾区域设置"
      assert_includes document, "明确要求英文"
      assert_includes document, "美国区域设置"
      assert_includes document, "最终用于复测的浏览器"
      assert_includes document, "系统和其他应用"
      assert_includes document, "移除 `zh-CN`"
      assert_includes document, "`zh-Hans`"
    end
  end

  def test_profile_changes_are_safe_and_lower_profiles_do_not_run_the_full_patch
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    mac_installer = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    windows_installer = File.read(File.join(SKILL, "scripts/install_windows.ps1"))

    assert_includes skill, "用户可以随时改档"
    assert_includes policy, "升档"
    assert_includes policy, "降档"
    assert_includes policy, "不能为了降档覆盖后来产生的用户改动"
    assert_includes skill, "从档位 3 降到档位 1 或 2"
    assert_includes skill, "uninstall_macos.sh"
    assert_includes skill, "uninstall_windows.cmd"
    assert_includes policy, "旧订阅增强仍可能保留"
    assert_includes policy, "三个档位都会关闭订阅自动更新"
    assert_includes mac_installer, '--usage-profile "$USAGE_PROFILE"'
    assert_includes windows_installer, 'if ($resolvedUsageProfile -ne 3)'
    assert_includes windows_installer, '$savedUsageProfile -eq 3'
    assert_includes windows_installer, "必须先运行安全卸载"
  end

  def test_all_profiles_share_one_managed_china_domain_baseline
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy_doc = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))
    policy = JSON.parse(File.read(File.join(SKILL, "references/policy.json")))
    mac_patcher = mac_patcher_source
    windows_patcher = File.read(File.join(SKILL, "scripts/windows/clash_verge_global.js"))

    [readme, skill, policy_doc, design].each do |document|
      assert_includes document, "共同国内域名直连基线"
      assert_includes document, "全部订阅"
    end
    provider = policy.fetch("cn_domain_provider")
    assert_equal "http", provider.fetch("type")
    assert_equal "domain", provider.fetch("behavior")
    assert_equal "mrs", provider.fetch("format")
    assert_equal 86_400, provider.fetch("interval")
    assert_includes provider.fetch("url"), "/geosite/cn.mrs"
    assert_includes mac_patcher, "patch_common_cn"
    assert_includes mac_patcher, '"rule-set:#{provider_name}"'
    assert_includes windows_patcher, "claudeEasyCommonCn"
    assert_includes windows_patcher, "CLAUDE_EASY_USAGE_PROFILE"
  end

  def test_known_diagnostics_cover_domestic_misrouting_and_adguard_certificate_failures
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    [skill, policy].each do |document|
      assert_includes document, "第一档已知故障：国内请求误走海外"
      assert_includes document, "Kimi"
      assert_includes document, "欧陆词典"
      assert_includes document, "不得点击"
      assert_includes document, "CERTIFICATE_VERIFY_FAILED"
      assert_includes document, "不添加 Apple"
      assert_includes document, "暂未复现"
    end
  end

  def test_adguard_certificate_failures_preserve_the_global_tun_compatibility_path
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))

    [readme, skill, policy, design].each do |document|
      assert_includes document, "禁止按应用调整 AdGuard 过滤范围"
      assert_includes document, "Clash TUN 存在时不得把 AdGuard 改为 `Network Extension`"
      assert_includes document, "系统代理所有权"
      assert_includes document, "PAC 查询中断"
    end

    [skill, policy, design].each do |document|
      assert_includes document, "`ProxyConfigHelper`"
      refute_includes document, "排除出错的非浏览器应用"
      refute_includes document, "调整应用过滤范围"
    end
  end

  def test_adguard_fake_ip_reuse_uses_a_hostname_preserving_outbound_proxy
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))

    [readme, skill, policy, design].each do |document|
      assert_includes document, "Fake-IP 被重新分配"
      assert_includes document, "AdGuard 出站代理"
      assert_includes document, "127.0.0.1"
      assert_includes document, "Mihomo HTTP 代理端口"
      assert_includes document, "按域名"
      assert_includes document, "已有的非 Clash 出站代理"
      assert_includes document, "恢复 AdGuard 原状态"
    end

    assert_includes policy, "同一个 Fake-IP"
    assert_includes policy, "目标域名"
    assert_includes policy, "只通过 AdGuard 界面"
    assert_includes policy, "端口正在由当前 Mihomo 监听"
    assert_includes policy, "不得固定假设为 `7890`"
    assert_includes policy, "不得全局关闭 HTTPS 过滤"
  end

  def test_saved_profile_bounds_diagnostics_repairs_and_regression_checks
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))
    metadata = YAML.safe_load(File.read(File.join(SKILL, "agents/openai.yaml")))

    [readme, skill, policy, design].each do |document|
      assert_includes document, "Patch 和 Diagnostics"
      assert_includes document, "诊断"
      assert_includes document, "档位"
    end

    assert_includes skill, "Diagnostics 每次开始都先读取本机保存的档位"
    assert_includes skill, "故障本身不能自动升档"
    assert_includes policy, "用途档位是 Diagnostics 的需求边界"
    assert_includes policy, "但不检查或修改 TUN"
    assert_includes policy, "不运行 DNS 泄漏、WebRTC 或 AI 检查"
    assert_includes policy, "共同国内域名直连基线"
    assert_includes policy, "档位 2 不运行 DNS 泄漏、WebRTC 或 AI 分组检查"
    assert_includes policy, "档位 3 的既有能力"
    assert_includes policy, "只重测可能受本次改动影响的第三档能力"
    assert_includes metadata.dig("interface", "default_prompt"), "诊断前读取用途档位"
  end

  def test_diagnostics_uses_a_universal_evidence_loop
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes policy, "## Diagnostics 模块"
    %w[复现 影响范围 对照 时间线 假设 证据 排除 最小改动 复测 观察窗口].each do |term|
      assert_includes policy, term
    end
    assert_includes policy, "不要求用户先知道该查什么"
    assert_includes policy, "任何外部记录都不是诊断前提"
    assert_includes policy, "没有证据不能下结论"
    assert_includes policy, "按现象选择必要层级，不是每次全部执行"
    assert_includes policy, "始终记录时间、操作系统、活动网络和原始症状"
    assert_includes policy, "只有影响范围或证据指向共同网络路径时"
    assert_includes policy, "保留所有尚未证实的解释"
    assert_includes policy, "只有充分反证"
  end

  def test_long_read_only_investigations_can_use_safe_parallel_subagents
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))

    [skill, policy, design].each do |document|
      assert_includes document, "Sub Agent"
      assert_includes document, "超过 10 分钟"
    end
    assert_includes policy, "只读证据"
    assert_includes policy, "统一时间窗"
    assert_includes policy, "只有一个界面操作者"
    assert_includes policy, "只有一个主动流量生成者"
    assert_includes policy, "写入、更新、恢复和最终判断"
    assert_includes policy, "主代理串行完成"
  end

  def test_computer_use_rules_cover_windows_without_overstating_availability
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))

    [skill, policy, design].each do |document|
      assert_includes document, "Windows Computer Use"
      assert_includes document, "当前会话"
      assert_includes document, "前台桌面"
    end
    assert_includes policy, "保持解锁"
    assert_includes policy, "不能操作 UAC"
    assert_includes policy, "优先使用脚本"
    assert_includes policy, "2026-07-09"
  end

  def test_patch_runtime_route_verifiers_exist_on_both_platforms
    mac_verifier = File.read(File.join(SKILL, "scripts/macos/verify_routes.rb"))
    windows_verifier = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    [mac_verifier, windows_verifier].each do |source|
      assert_includes source, "Google"
      assert_includes source, "OpenAI"
      assert_includes source, "Anthropic"
      assert_includes source, "Claude"
      assert_includes source, "/connections"
      assert_includes source, "/proxies"
      assert_includes source, "/providers/proxies"
      assert_includes source, "providerChains"
      assert_includes source, "DIRECT"
    end
    assert_includes policy, "verify_routes.ps1"
    assert_includes mac_verifier, "NON_PROXY_TERMINALS"
    assert_includes mac_verifier, "non_proxy_terminal?"
    assert_includes windows_verifier, '$nonProxyNames = @("DIRECT"'
    assert_includes windows_verifier, '$nonProxyTypes = @("Direct"'
    assert_includes windows_verifier, "function Test-RouteChains"
    assert_includes windows_verifier, "function Test-SafeLiveChain"
    assert_includes windows_verifier, "function Get-LiveChainProxy"
    assert_includes windows_verifier, "function Test-SupportedRouteGroupType"
    %w[Selector URLTest Fallback LoadBalance Relay].each do |group_type|
      assert_includes windows_verifier, %("#{group_type}")
    end
    assert_includes(
      windows_verifier,
      "if ($null -eq $property -or -not (Test-SupportedRouteGroupType ([string]$property.Value.type))) {"
    )
  end

  def test_both_route_verifiers_use_live_match_rule_for_main_group
    mac_source = File.read(File.join(SKILL, "scripts/macos/verify_routes.rb"))
    windows_source = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))

    assert_includes mac_source, "def live_main_group"
    assert_includes mac_source, 'get_json(socket, "/rules")'
    assert_includes mac_source, 'rule["proxy"]'
    assert_includes mac_source, "main_group = live_main_group(socket, proxies, main_group)"
    assert_includes mac_source, 'ai_group = find_group(proxies, policy["ai_group_names"], ai_group, ai: true)'
    assert_includes windows_source, "function Get-LiveMainGroup"
    assert_includes windows_source, 'Invoke-ControllerJson "/rules"'
    assert_includes windows_source, '$rule.proxy'
    assert_includes windows_source, '$main = Get-LiveMainGroup $proxies'
  end

  def test_route_verifiers_share_group_overrides_observation_window_and_result_shape
    mac_source = File.read(File.join(SKILL, "scripts/macos/verify_routes.rb"))
    windows_source = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))

    assert_includes mac_source, '"--main-group NAME"'
    assert_includes mac_source, '"--ai-group NAME"'
    assert_includes mac_source, '"--observation-seconds N"'
    assert_includes mac_source, '"not_observed"'
    assert_includes mac_source, 'ok ? "passed" : "failed"'
    assert_includes windows_source, "Test-UsableRouteGroupSelection"
    assert_includes windows_source, '"not_observed"'
    assert_includes windows_source, '"route_verification_failed"'
  end

  def test_windows_route_tests_load_all_verifier_functions_without_drifting_allowlists
    windows_test = File.read(File.join(ROOT, "tests/test_windows_installer.ps1"))

    assert_includes windows_test, '$routeFunctionAsts = @($routeAst.FindAll({'
    assert_includes windows_test, '$routeFunctionAsts | ForEach-Object {'
    assert_includes windows_test, '$routeFunctionSources = $routeFunctionAsts | ForEach-Object'
  end

  def test_route_verifiers_share_targets_and_supported_runtime_types
    mac_source = File.read(File.join(SKILL, "scripts/macos/verify_routes.rb"))
    windows_source = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))

    {
      "Google" => "https://www.google.com/search?q=clash-route-verification",
      "OpenAI" => "https://openai.com/",
      "Anthropic" => "https://www.anthropic.com/",
      "Claude" => "https://claude.ai/"
    }.each do |label, url|
      assert_includes mac_source, %(["#{label}", "#{url}")
      assert_includes windows_source, %("#{label}" "#{url}")
    end
    %w[Selector URLTest Fallback LoadBalance Relay].each do |group_type|
      assert_includes mac_source, group_type
      assert_includes windows_source, group_type
    end
    %w[DIRECT DNS REJECT REJECT-DROP PASS PASS-RULE COMPATIBLE REMATCH].each do |terminal|
      assert_includes mac_source, terminal
      assert_includes windows_source, terminal
    end
  end

  def test_windows_route_verifier_keeps_the_controller_secret_off_process_metadata
    source = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))
    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(
        File.join(
          ROOT,
          "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"
        )
      ),
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]

    assert_includes source, '[switch]$SecretStdin'
    assert_includes source, "function Read-ControllerSecretFromStandardInput"
    assert_includes source, '$inputReader.ReadToEnd()'
    assert_includes source, '不能通过 -Secret 传入非空控制器密钥'
    assert_includes source, "function Get-ValidatedControllerBaseUri"
    assert_includes source, 'Test-StrictIpv4LoopbackHost $rawHost'
    assert_includes source, 'if (-not $rawHostIsLoopback)'
    assert_includes source, '$request.AllowAutoRedirect = $false'
    assert_includes source, '$request.Proxy = $null'
    assert_includes source, '$script:ClaudeEasyControllerSecret'
    refute_includes source, '"Bearer $Secret"'
    documents.each do |document|
      assert_includes document, "-SecretStdin"
      assert_includes document, "本机回环"
      assert_includes document, "非空 `-Secret`"
    end
  end

  def test_diagnostics_separates_clues_from_conclusions
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    %w[已确认 有力支持 尚未证实 已排除].each { |state| assert_includes policy, state }
    assert_includes policy, "单个现象或相关性只能算线索"
    assert_includes policy, "第二种独立证据"
    assert_includes policy, "反证"
    assert_includes policy, "解释全部已知现象"
  end

  def test_diagnostics_has_reproduction_scope_and_reset_gates
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes skill, "有 Computer Use"
    assert_includes skill, "修改前复现"
    assert_includes skill, "两次假设"
    assert_includes skill, "诊断重置"
    assert_includes policy, "配置缺陷不等于故障原因"
    assert_includes policy, "至少两个健康对照"
    assert_includes policy, "恢复全部未生效的试验"
    assert_includes policy, "没有新的证据不得进行第三次修改"
    assert_includes policy, "不能因为单个目标的对照结果就停用或删除整个组件"
    assert_includes policy, "共同组件本身"
  end

  def test_diagnostics_resolves_overlapping_network_interceptors_by_responsibility
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))

    [skill, policy, design].each do |document|
      assert_includes document, "重叠接管"
      assert_includes document, "职责分层"
    end

    assert_includes policy, "系统代理或 PAC"
    assert_includes policy, "透明代理或内容过滤器"
    assert_includes policy, "VPN 或 TUN"
    assert_includes policy, "原有功能覆盖"
    assert_includes policy, "安全属性"
    assert_includes policy, "不逐站添加例外"
  end

  def test_macos_adguard_uses_the_known_clash_compatibility_path
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))

    [readme, skill, policy, design].each do |document|
      assert_includes document, "AdGuard for Mac"
      assert_includes document, "Network Extension"
      assert_includes document, "自动代理"
    end

    assert_includes skill, "档位 2、3"
    assert_includes skill, "不得逐站添加例外"
    assert_includes policy, "已知兼容路径"
    assert_includes policy, "不是升档"
    assert_includes policy, "只通过 AdGuard 界面"
    assert_includes policy, "不得用 `networksetup`"
    assert_includes policy, "Safari 和 Chrome"
    assert_includes policy, "非浏览器应用"
    assert_includes policy, "至少三个无关目标"
    assert_includes policy, "不能仅凭检测到 AdGuard"
    assert_includes policy, "无改善立即恢复"
    assert_includes design, "Patch 和 Diagnostics"
  end

  def test_configuration_history_is_versioned_compared_and_safely_restored
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))
    mac_patcher = mac_patcher_source
    mac_installer = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    windows_installer = windows_installer_source

    [readme, skill, policy, design].each do |document|
      assert_includes document, "每次写入"
      assert_includes document, "日期时间"
      assert_includes document, "配置差异"
      assert_includes document, "回滚"
    end

    assert_includes skill, "修改前的版本"
    assert_includes skill, "先备份当前版本"
    assert_includes policy, "不能仅凭时间接近"
    assert_includes policy, "预期 SHA-256"
    assert_includes policy, "不得自动删除历史备份"
    assert_includes policy, "不输出配置值"
    assert_includes policy, "失败时恢复回滚前版本"
    assert_includes mac_patcher, "--snapshot-initial"
    assert_includes mac_patcher, "--list-backups"
    assert_includes mac_patcher, "--compare-backup"
    assert_includes mac_patcher, "--restore-backup"
    assert_includes mac_installer, "--snapshot-initial"
    assert_includes windows_installer, "ListBackups"
    assert_includes windows_installer, "CompareBackup"
    assert_includes windows_installer, "RestoreBackup"
    assert_includes windows_installer, "claude-easy-backups"
    assert_includes windows_installer, "yyyy-MM-dd_HH-mm-ss"
    assert_includes windows_installer, "ChangedFields"
    assert_includes skill, "先列出备份"
    assert_includes skill, "先比较"
    assert_includes skill, "症状出现前"
    assert_includes skill, "--expected-current-sha256"
    assert_includes skill, "-ExpectedCurrentSha256"
  end

  def test_safe_update_replaces_all_subscriptions_as_one_transaction
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))
    installer = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    patcher = mac_patcher_source

    [readme, skill, policy, design].each do |document|
      assert_includes document, "安全更新"
      assert_includes document, "全部远程订阅"
      assert_includes document, "全部保持原样"
      assert_includes document, "三个档位"
      assert_includes document, "关闭自动更新"
      assert_includes document, "请帮我安全更新全部订阅"
      assert_includes document, "数月"
      assert_includes document, "再次确认自动更新关闭"
    end
    assert_includes installer, "--safe-update"
    assert_includes patcher, "--safe-update-all"
    assert_includes patcher, "--print-subscription-auto-update-state"
    assert_includes patcher, "--print-auto-update-ownership-state"
    assert_includes patcher, "--disable-subscription-auto-update"
    assert_includes installer, "--disable-subscription-auto-update"
    assert_includes windows_installer_source, "allow_auto_update"
    assert_includes windows_installer_source, "VerifySafeUpdate"
    [readme, skill, policy, design].each do |document|
      assert_includes document, "不依赖 Computer Use"
    end
    assert_includes policy, "不得安装永久监听"
    refute_includes skill, "订阅以后刷新时，请再次运行"
  end

  def test_macos_backup_recovery_includes_the_active_runtime
    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))
    ]

    documents.each do |document|
      assert_includes document, "macOS 恢复当前订阅后"
      assert_includes document, "运行内核"
      assert_includes document, "恢复回滚前版本"
    end
  end

  def test_diagnostics_selects_tools_by_the_observed_symptom
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    %w[浏览器 DNS 分流 TCP TLS 首字节 丢包 进程 系统记录 应用日志].each do |term|
      assert_includes policy, term
    end
    assert_includes policy, "一个应用异常而其他应用正常"
    assert_includes policy, "不得直接执行 Patch 模块"
    assert_includes policy, "不得把完整补丁验收当成每次诊断的固定步骤"
  end

  def test_ai_availability_diagnostics_check_official_incidents_before_local_state
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(
      File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
    )

    [readme, skill, policy, design].each do |document|
      assert_includes document, "AI 服务状态前置检查"
      assert_includes document, "对应提供商的官方状态页和事件历史"
    end
    [skill, policy].each do |document|
      assert_includes document, "https://status.openai.com/"
      assert_includes document, "https://status.anthropic.com/"
    end

    assert_operator(
      skill.index("AI 服务状态前置检查"),
      :<,
      skill.index("Diagnostics 每次开始都先读取本机保存的档位")
    )
    assert_operator(
      policy.index("### AI 服务状态前置检查"),
      :<,
      policy.index("### 通用工作循环")
    )
  end

  def test_diagnostics_finishes_with_repair_explanation_and_verification
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes policy, "能在本机安全修复"
    assert_includes policy, "由代理自动完成"
    assert_includes policy, "本机无法修复"
    assert_includes policy, "在线搜索"
    assert_includes policy, "官方或第一方资料"
    assert_includes policy, "一次只改变一个变量"
    assert_includes policy, "修复前的状态"
    assert_includes policy, "原始症状"
    assert_includes policy, "发生了什么"
    assert_includes policy, "为什么会这样"
  end

  def test_diagnostics_drives_through_repair_and_iteration
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))

    [readme, skill, policy, design].each do |document|
      assert_includes document, "解决原始问题是 Diagnostics 的结束目标"
      assert_includes document, "只读检查是第一阶段，不是交付结果"
      assert_includes document, "诊断结论不是完成"
      assert_includes document, "修复、复测、继续迭代"
      assert_includes document, "状态说明不能代替行动"
    end

    [skill, policy].each do |document|
      assert_includes document, "不请求用户确认诊断方案"
      assert_includes document, "修复失败后恢复"
      assert_includes document, "继续取证"
      assert_includes document, "一次失败不是停止条件"
      assert_includes document, "工具明确要求的操作时确认"
      assert_includes document, "完成全部不需要确认的准备"
      assert_includes document, "用户授权后直接继续"
      assert_includes document, "不得把“请回复继续”当成常规收尾"
    end

    assert_includes policy, "解释和建议不算修复"
    assert_includes policy, "只有问题已经解决或遇到真实阻塞"
    assert_includes policy, "诊断重置后继续"
    assert_includes policy, "同一原始动作"
  end

  def test_diagnostics_does_not_hide_a_full_patch_behind_a_targeted_repair
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes policy, "Patch 模块会应用完整安全策略，不是单项修复器"
    assert_includes policy, "包含与已确认问题无关的改动"
    assert_includes policy, "不得把完整 Patch 伪装成单项修复"
    assert_includes skill, "Patch 专用验收"
    assert_includes skill, "Diagnostics 不固定执行"
    assert_includes skill, "单项 Clash 配置修复仍留在 Diagnostics"
    assert_includes policy, "只有用户明确要求完整安全增强时才进入 Patch"
    assert_includes policy, "macOS 单项配置事务"
    assert_includes policy, "依次清除 Fake-IP 和 DNS 缓存"
    assert_includes policy, "Windows 当前没有安全的即时单项配置写入路径"
    assert_includes policy, "## Patch 验证标准"
  end

  def test_diagnostics_defines_observation_by_the_original_failure_pattern
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes policy, "可以立即重复的问题"
    assert_includes policy, "修复前后各连续测试三次"
    assert_includes policy, "最近记录中的典型复发间隔"
    assert_includes policy, "同样长的时间窗"
    assert_includes policy, "curl.exe"
    assert_includes policy, "Test-NetConnection"
    assert_includes policy, "Test-Connection"
    assert_includes policy, "采集工具或会话"
    assert_includes policy, "停止与清理方法"
    assert_includes policy, "未建立监测"
    assert_includes policy, "只有已经确认采集器正在运行时"
  end

  def test_diagnostics_protects_application_state_and_log_secrets
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    %w[访问令牌 refresh\ token ID\ token Authorization Cookie 账号标识 会话内容].each do |term|
      assert_includes policy, term.gsub("\\ ", " ")
    end
    assert_includes policy, "只读取必要时间窗"
    assert_includes policy, "未保存工作"
    assert_includes policy, "关闭应用、注销账号、删除或隔离缓存、Repair、重装或降级"
    assert_includes policy, "明确授权"
    assert_includes policy, "相同服务不等于相同账号、接口或认证方式"
    assert_includes policy, "登录、支付、发消息"
    assert_includes policy, "停止重复提交"
    assert_includes policy, "密码、验证码、MFA 或硬件确认"
  end

  def test_windows_diagnostics_does_not_claim_an_instant_runtime_patch
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))

    assert_includes policy, "Windows 客户端运行时不得修改当前配置"
    assert_includes policy, "不能写成已立即生效"
    assert_includes policy, "不得为了复测而触发订阅切换、节点切换"
    assert_includes policy, "代理组切换或 TUN 切换"
    assert_includes policy, "更不得重启客户端"
    assert_includes policy, "已更新，尚未生效"
  end

  def test_diagnostics_does_not_bake_in_the_reference_incident
    public_source = Dir.glob(File.join(ROOT, "{README.md,claude-easy/**/*}"), File::FNM_EXTGLOB)
                       .select { |path| File.file?(path) }
                       .map { |path| File.binread(path).force_encoding("UTF-8").scrub }
                       .join("\n")

    %w[MESL 5.86GB 702.9MB MAO-5G].each { |term| refute_includes public_source, term }
    refute_match(/7\s*月\s*19\s*日/, public_source)
  end

  def test_readme_and_metadata_describe_diagnostics
    readme = File.read(File.join(ROOT, "README.md"))
    metadata = YAML.safe_load(File.read(File.join(SKILL, "agents/openai.yaml")))

    assert_includes readme, "Patch"
    assert_includes readme, "Diagnostics"
    assert_includes metadata.dig("interface", "short_description"), "诊断"
    assert_includes metadata.dig("interface", "default_prompt"), "诊断"
  end

  def test_documentation_distinguishes_written_tun_settings_from_runtime_state
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))

    refute_includes policy, "TUN：已开启"
    assert_includes policy, "配置中的 TUN：已写入；运行状态：已自动刷新并验证"
    assert_includes skill, "检查 TUN、DNS、外网连通性和目标配置仍保留的代理组选择"
  end

  def test_skill_frontmatter_contains_only_name_and_description
    skip unless File.file?(File.join(SKILL, "SKILL.md"))

    source = File.read(File.join(SKILL, "SKILL.md"))
    frontmatter = source.match(/\A---\n(.*?)\n---/m)
    refute_nil frontmatter
    metadata = YAML.safe_load(frontmatter[1])
    assert_equal %w[description name], metadata.keys.sort
    assert_equal "claude-easy", metadata["name"]
    assert_match(/\AUse when\b/, metadata["description"])
  end

  def test_openai_metadata_invokes_skill_in_chinese
    skip unless File.file?(File.join(SKILL, "agents/openai.yaml"))

    metadata = YAML.safe_load(File.read(File.join(SKILL, "agents/openai.yaml")))
    prompt = metadata.dig("interface", "default_prompt")
    assert_includes prompt, "$claude-easy"
    assert_includes prompt, "当前存储位置"
    assert_includes prompt, "绝对不要退出、停止或重启 Clash 客户端"
    assert_match(/[\p{Han}]/, prompt)
  end

  def test_skill_contains_required_chinese_user_contract
    skip unless File.file?(File.join(SKILL, "SKILL.md"))

    source = File.read(File.join(SKILL, "SKILL.md"))
    %w[简体中文 当前存储位置 ClashX\ Meta Clash\ Verge\ Rev 深度测试 截图 未验证].each do |text|
      assert_includes source, text.gsub("\\ ", " ")
    end
    %w[ipinfo.cv/webrtc-check ip.net.coffee/dns ip.net.coffee/webrtc].each do |url|
      assert_includes source, url
    end
  end

  def test_skill_names_every_guard_from_the_network_outage
    source = File.read(File.join(SKILL, "SKILL.md"))

    assert_includes source, "保留 `default-nameserver` 和 `proxy-server-nameserver`"
    assert_includes source, "大陆 IP DoH"
    assert_includes source, "direct-nameserver-follow-policy"
    assert_includes source, "不得把节点启动解析改成 `1.1.1.1` 或 `8.8.8.8`"
    assert_includes source, "不得安装永久监听、LaunchAgent、`WatchPaths`、计划任务或目录监听"
    assert_includes source, "REALITY `short-id`"
    assert_includes source, "只允许通过本地控制器自动刷新"
    assert_includes source, "失败时立即恢复原文件和原运行配置"
    assert_includes source, "`config.yaml` 是 ClashX Meta 的默认基础配置"
    assert_includes source, "不得删除"
  end

  def test_skill_automates_route_and_browser_verification_when_computer_use_exists
    source = File.read(File.join(SKILL, "SKILL.md"))

    assert_includes source, "访问 Google 时必须经过主代理组"
    assert_includes source, "不能经过 `DIRECT` 或 AI 分组"
    assert_includes source, "访问 OpenAI、Anthropic 或 Claude 时必须经过 AI 分组当前节点"
    assert_includes source, "macOS 或 Windows 环境只要提供 Computer Use，就由代理连续完成"
    assert_includes source, "当前环境没有 Computer Use 时，给出中文逐步操作"
  end


  def test_macos_route_verifier_checks_main_and_ai_destinations
    source = File.read(File.join(SKILL, "scripts/macos/verify_routes.rb"))

    %w[Google OpenAI Anthropic Claude].each { |name| assert_includes source, name }
    assert_includes source, "def route_passes?"
    assert_includes source, "return false if chains.include?(ai_group)"
    assert_includes source, 'existing.include?(entry["id"])'
  end

  def test_skill_reuses_user_ai_groups_and_creates_independent_node_selectors
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    ruby_patcher = mac_patcher_source
    windows_patcher = File.read(File.join(SKILL, "scripts/windows/clash_verge_global.js"))

    assert_includes skill, "已有可选 AI 分组时，直接复用"
    assert_includes skill, "不得修改它的成员或当前选择"
    assert_includes skill, "全部可用的真实节点和代理提供者"
    assert_includes skill, "主代理组与 AI 节点互不影响"
    assert_includes skill, "不得创建第二个安全代理分组"
    assert_includes policy, "不得替用户选择台湾、日本或任何家宽节点"
    refute_includes ruby_patcher, "def ensure_safe_group"
    refute_includes ruby_patcher, "def home_candidate"
    refute_includes windows_patcher, "function claudeEasyEnsureSafeGroup"
    refute_includes windows_patcher, "function claudeEasyHomeCandidate"
  end

  def test_agents_requires_requirement_docs_to_change_with_behavior
    agents = File.read(File.join(ROOT, "AGENTS.md"))

    assert_includes agents, "功能需求变化时"
    assert_includes agents, "代码、Skill 和相关产品文档必须在同一次改动中同步更新"
  end

  def test_public_tree_contains_no_personal_provider_or_machine_data
    files = Dir.glob(File.join(ROOT, "{README.md,claude-easy/**/*}"), File::FNM_EXTGLOB).select { |path| File.file?(path) }
    source = files.map { |path| File.binread(path).force_encoding("UTF-8").scrub }.join("\n")
    refute_match(%r{/Users/[^/\s]+}, source)
    refute_match(%r{https?://[^\s]+(?:token|subscribe|subscription)[^\s]*=}i, source)
  end

  def test_policy_is_valid_json_and_omits_forbidden_ai_domains
    path = File.join(SKILL, "references/policy.json")
    skip unless File.file?(path)

    policy = JSON.parse(File.read(path))
    assert_includes policy.fetch("forbidden_ai_domains"), "raw.githubusercontent.com"
    assert_includes policy.fetch("forbidden_ai_domains"), "storage.googleapis.com"
    ai_rules = policy.fetch("ai_rules").join("\n")
    refute_includes ai_rules, "raw.githubusercontent.com"
    refute_includes ai_rules, "storage.googleapis.com"
    refute policy.key?("proxy_bootstrap_resolvers")
    refute policy.key?("default_bootstrap_resolvers")
  end

  def test_managed_dns_policy_uses_bootstrap_free_ip_doh_without_site_exceptions
    policy = JSON.parse(File.read(File.join(SKILL, "references/policy.json")))
    assert_equal [
      "https://94.140.14.140/dns-query",
      "https://94.140.14.141/dns-query",
      "https://101.101.101.101/dns-query"
    ], policy.fetch("resolvers")
    assert_equal [
      "https://223.5.5.5/dns-query#DIRECT",
      "https://1.12.12.12/dns-query#DIRECT"
    ], policy.fetch("direct_resolvers")

    public_source = Dir.glob(File.join(ROOT, "{README.md,claude-easy/**/*}"), File::FNM_EXTGLOB)
                       .select { |path| File.file?(path) }
                       .map { |path| File.binread(path).force_encoding("UTF-8").scrub }
                       .join("\n")
    refute_includes public_source.downcase, "aiping.cn"

    policy_doc = File.read(File.join(SKILL, "references/patch-policy.md"))
    assert_includes policy_doc, "无需先解析解析器域名"
  end

  def test_windows_policy_is_generated_from_canonical_json
    generator = File.join(ROOT, "tests/generate_windows_policy.rb")
    assert system(RbConfig.ruby, generator, "--check"), "Windows policy block is stale"
  end

  def test_windows_policy_generator_uses_binary_io
    source = File.read(File.join(ROOT, "tests/generate_windows_policy.rb"))
    assert_includes source, "File.binread"
    assert_includes source, "File.binwrite"
    refute_match(/File\.write\(engine_path/, source)
  end

  def test_readme_is_chinese_and_explains_safe_refresh_behavior
    path = File.join(ROOT, "README.md")
    skip unless File.file?(path)

    source = File.read(path)
    assert_operator source.scan(/[\p{Han}]/).length, :>, 200
    %w[单次运行 当前存储位置 全局扩展脚本 DNS WebRTC 家宽 台湾 日本].each do |term|
      assert_includes source, term
    end
    %w[游戏 语音 视频 QUIC 第三方].each { |term| assert_includes source, term }
  end

  def test_public_policy_routes_quic_with_the_shared_browser_udp_guard
    retired_rule = "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT"
    files = [
      File.join(ROOT, "README.md"),
      File.join(SKILL, "SKILL.md"),
      File.join(SKILL, "references/patch-policy.md"),
      File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
    ]

    files.each do |path|
      source = File.read(path)
      refute_includes source, retired_rule, path
      assert_includes source, "QUIC", path
      assert_includes source, "AI 分组", path
    end
  end

  def test_shared_browser_policy_scopes_dns_but_not_webrtc_by_domain
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))

    [skill, policy, design].each do |source|
      %w[AI\ 分组 STUN 标签页 TCP DNS].each { |term| assert_includes source, term }
    end
    assert_includes policy, "NETWORK,UDP,<AI 分组>"
    refute_includes policy, "NETWORK,UDP,<原主代理组>"
  end

  def test_diagnostics_separates_network_wait_from_browser_rendering
    files = [
      File.join(ROOT, "README.md"),
      File.join(SKILL, "SKILL.md"),
      File.join(SKILL, "references/patch-policy.md"),
      File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
    ]

    files.each do |path|
      source = File.read(path)
      %w[主文档 扩展 对照 单站].each { |term| assert_includes source, term, path }
    end
  end

  def test_policy_documents_dns_filters_and_safety_migrations
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    %w[exclude-filter empty-fallback skip-cert-verify ecs 160.79.104.0/21 ai.com proxy-server-nameserver system 二次转换].each do |term|
      assert_includes policy, term
    end
    assert_includes policy, "/cache/fakeip/flush"
    assert_includes policy, "/cache/dns/flush"
  end

  def test_macos_installer_is_one_shot
    path = File.join(SKILL, "scripts/install_macos.sh")
    skip unless File.file?(path)

    source = File.read(path)
    refute_includes source, "RunAtLoad"
    refute_includes source, "WatchPaths"
    refute_includes source, "KeepAlive"
    patcher = mac_patcher_source
    assert_includes patcher, 'File.join(home, ".config", "clash.meta")'
    refute_includes source, "launchctl bootout"
    assert_match(/[\p{Han}]/, source)
    assert_includes source, "plutil"
    refute_includes source, "<plist version="
    refute_includes source, "launchctl bootstrap"
    refute_includes source, "osascript"
    assert_match(/\A#!\/bin\/sh\nset -eu\nset -f\n/, source)
    refute_match(/\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/, source)
  end

  def test_macos_mutating_wrappers_share_one_cross_process_operation_lock
    helper = File.read(File.join(SKILL, "scripts/macos/operation_lock.rb"))
    installer = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    uninstaller = File.read(File.join(SKILL, "scripts/uninstall_macos.sh"))

    assert_includes helper, "File::LOCK_EX | File::LOCK_NB"
    assert_includes helper, "LOCK_TIMEOUT_SECONDS = 5"
    assert_includes helper, "handle.close_on_exec = false"
    [installer, uninstaller].each do |source|
      assert_includes source, 'OPERATION_LOCK_PATH="$BACKUP_DIR/.claude-easy-wrapper.lock"'
      assert_includes source, "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD"
      assert_includes source, '"$OPERATION_LOCK_SOURCE" "$OPERATION_LOCK_PATH" /bin/sh "$0" "$@"'
      assert_includes source, "operation_in_progress"
    end
    pending_recovery = installer.index("recover_interrupted_uninstall\nresolve_usage_profile")
    client_preflight = installer.index('if [ ! -d "/Applications/ClashX Meta.app" ]')
    refute_nil pending_recovery
    refute_nil client_preflight
    assert_operator pending_recovery, :<, client_preflight
    assert_includes installer, 'recovery_json=$(/bin/sh "$UNINSTALLER_SOURCE" --json'
    assert_includes installer, "uninstall_recovery_failed"
  end

  def test_macos_profile_operation_signal_handoff_preserves_committed_state
    installer = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    cli = File.read(File.join(SKILL, "scripts/macos/patch_profiles/cli.rb"))
    patcher_tests = File.read(File.join(ROOT, "tests/test_macos_patcher.rb"))
    wrappers = File.read(File.join(ROOT, "tests/test_macos_wrappers.rb"))

    assert_includes installer, "run_committing_profile_operation()"
    assert_includes installer, "preserve_profile_operation_state()"
    assert_includes installer, "record_profile_operation_signal 143"
    assert_includes installer, "commit_profile_selection"
    assert_includes installer, "AUTO_UPDATE_RECOVERY_REQUIRED=0"
    assert_includes installer, "AUTO_UPDATE_RECOVERY_PENDING=0"
    assert_includes installer, "PROFILE_OPERATION_COMMITTED=1"
    assert_includes installer, "operation_committed_interrupted"
    assert_includes installer, "PROFILE_OPERATION_RECOVERY_INTENT=1"
    assert_includes installer, "operation_interrupted_recovery_intent"
    assert_includes installer,
                    "trap ':' HUP INT TERM\n" \
                    "    set +e\n" \
                    '    /usr/bin/ruby "$OPERATION_LOCK_SOURCE"'
    assert_includes installer, "--wrapper-commit-receipt"
    assert_includes installer, "PROFILE_OPERATION_RECEIPT_COMMITTED=1"
    assert_includes installer, "operation_committed_result_failed"
    assert_includes installer, "operation_result_unknown_recovery_intent"
    assert_includes cli, "WRAPPER_COMMIT_RECEIPT_FAILURE_EXIT = 75"
    assert_includes cli, "wrapper_commit_receipt_failed"
    assert_includes cli, "def validate_wrapper_commit_receipt(options)"
    assert_includes cli, "def mark_wrapper_commit_receipt(options)"
    assert_includes cli, "io.fsync"
    assert_includes cli, "mark_wrapper_commit_receipt(options) if operation_succeeded"
    assert_includes cli,
                    "if result[:status] == :updated\n" \
                    "        mark_wrapper_commit_receipt(options)"
    assert_includes patcher_tests,
                    "test_cli_marks_wrapper_receipt_before_success_result_output"
    assert_includes wrappers,
                    "test_signal_after_profile_commit_preserves_outer_profile_state"
    assert_includes wrappers,
                    "test_result_failure_after_profile_commit_preserves_outer_profile_state"
    assert_includes wrappers,
                    "test_uncertain_or_unpublished_commit_receipt_preserves_outer_profile_state"
    assert_includes wrappers, 'Process.kill("TERM", Process.ppid)'
    assert_includes wrappers, 'Process.kill("TERM", -Process.getpgrp)'
    assert_includes wrappers, 'raise Errno::ENOSPC, "injected result write failure"'
    assert_includes wrappers, '"--restore-owned-subscription-auto-update"'

    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(
        File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
      ),
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents.each do |document|
      assert_includes document, "TERM"
      assert_includes document, "operation_committed_interrupted"
      assert_includes document, "operation_interrupted_recovery_intent"
      assert_includes document, "提交收据"
      assert_includes document, "operation_committed_result_failed"
      assert_includes document, "operation_result_unknown_recovery_intent"
    end
  end

  def test_macos_controller_loads_recheck_the_live_profile_context
    runtime = File.read(
      File.join(SKILL, "scripts/macos/patch_profiles/runtime.rb")
    )
    subscriptions = File.read(
      File.join(SKILL, "scripts/macos/patch_profiles/subscriptions.rb")
    )
    writer = File.read(
      File.join(SKILL, "scripts/macos/patch_profiles/profile_writer.rb")
    )
    cli = File.read(File.join(SKILL, "scripts/macos/patch_profiles/cli.rb"))
    patcher_tests = File.read(File.join(ROOT, "tests/test_macos_patcher.rb"))

    [
      ["def reload_recovered_profile_runtime", "def activate_updated_profile"],
      ["def activate_updated_profile", "def rollback_after_reload_failure"],
      ["def rollback_after_reload_failure", "\nend\n"]
    ].each do |start_marker, end_marker|
      start = runtime.index(start_marker)
      finish = runtime.index(end_marker, start + start_marker.length)
      refute_nil start
      refute_nil finish
      body = runtime[start...finish]
      guard = body.index("runtime_precommit_allowed?(precommit_condition)")
      load = body.index('"PUT", "/configs?force=true"')
      refute_nil guard
      refute_nil load
      assert_operator guard, :<, load
    end

    safe_recovery_start = subscriptions.index("def reload_recovered_safe_update_runtime")
    safe_recovery_end = subscriptions.index("def safe_update_all", safe_recovery_start)
    refute_nil safe_recovery_start
    refute_nil safe_recovery_end
    safe_recovery = subscriptions[safe_recovery_start...safe_recovery_end]
    assert_operator(
      safe_recovery.index("capture_runtime_profile_context(roots)"),
      :<,
      safe_recovery.index('"PUT", "/configs?force=true"')
    )

    assert_includes subscriptions, "def capture_runtime_profile_context"
    assert_includes subscriptions, "def selected_profile_name(runner:"
    assert_includes subscriptions, '"selectConfigName"'
    assert_includes subscriptions, "selected_before = selected_profile_name"
    assert_includes subscriptions, "selected_after = selected_profile_name"
    assert_includes subscriptions, "return nil unless selected_before.is_a?(String)"
    assert_includes subscriptions, "return nil unless selected_after.is_a?(String)"
    assert_includes subscriptions, "return nil unless matching_paths.length == 1"
    assert_includes subscriptions, "storage_before = guard_storage ? storage_mode : nil"
    assert_includes subscriptions, "storage_after = guard_storage ? storage_mode : nil"
    assert_includes subscriptions,
                    "return runtime_precommit_allowed?(precommit_condition) unless active"
    assert_includes writer, "precommit_condition: precommit_condition"
    assert_includes cli, "guard_storage: guard_storage"
    assert_includes cli, "!runtime_precommit_allowed?(precommit_condition)"
    refute_includes cli,
                    "usage_profile: options[:usage_profile], selected_name: selected_profile_name"

    %w[
      test_run_does_not_reload_the_old_profile_after_the_user_switches_profiles
      test_safe_update_does_not_reload_the_old_profile_after_the_user_switches_profiles
      test_pending_runtime_recovery_does_not_reload_a_profile_the_user_left
      test_reload_failure_does_not_force_the_old_profile_after_a_late_user_switch
      test_cli_restore_backup_does_not_reload_the_old_profile_after_a_user_switch
      test_safe_update_aborts_if_the_client_changes_storage_during_validation
      test_safe_update_aborts_when_the_user_enters_a_remote_target_during_validation
      test_cli_restore_backup_rolls_back_if_the_user_enters_the_target_during_validation
      test_pending_runtime_recovery_keeps_the_journal_when_the_active_profile_is_missing
      test_selected_profile_snapshot_distinguishes_default_config_from_read_failure
      test_run_without_reload_stops_when_the_current_profile_cannot_be_read
    ].each { |name| assert_includes patcher_tests, name }

    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(
        File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
      ),
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents.each do |document|
      assert_includes document, "每次控制器加载前"
      assert_includes document, "绝不加载旧订阅"
      assert_match(/读取失败|无法可靠读取/, document)
    end
  end

  def test_macos_uninstall_recovers_pending_profile_transactions_before_writing
    uninstaller = File.read(File.join(SKILL, "scripts/uninstall_macos.sh"))
    patcher = mac_patcher_source
    recovery = uninstaller.index("\nrecover_pending_profile_transaction\n")
    uninstall_recovery = uninstaller.index("\nrestore_uncommitted_uninstall\n", recovery)

    refute_nil recovery
    refute_nil uninstall_recovery
    assert_operator recovery, :<, uninstall_recovery
    assert_includes uninstaller, "--recover-profile-transaction"
    assert_includes uninstaller, "profile_transaction_recovery_failed"
    assert_includes patcher, "--recover-profile-transaction"

    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))
    ]
    documents.each do |document|
      assert_includes document, "macOS 安全卸载"
      assert_includes document, "发现未完成的配置事务"
      assert_includes document, "恢复订阅自动更新之前"
      assert_includes document, "自动更新所有权"
    end
  end

  def test_p1_recovery_and_refresh_guards_are_documented_and_exercised
    mac_uninstaller = File.read(File.join(SKILL, "scripts/uninstall_macos.sh"))
    windows_installer = File.read(File.join(SKILL, "scripts/install_windows.ps1"))
    windows_profiles = File.read(
      File.join(SKILL, "scripts/windows/install_windows/profiles.ps1")
    )
    windows_safe_update = File.read(
      File.join(SKILL, "scripts/windows/install_windows/safe_update.ps1")
    )
    mac_tests = File.read(File.join(ROOT, "tests/test_macos_wrappers.rb"))
    windows_tests = File.binread(
      File.join(ROOT, "tests/test_windows_installer.ps1")
    ).force_encoding("UTF-8")

    assert_includes mac_uninstaller,
                    "disabled|already_disabled|already_disabled_owned)"
    assert_includes mac_tests, 'puts "already_disabled_owned"'

    running_gate = windows_installer.index(
      'if ($clientRunning) {'
    )
    first_install_target = windows_installer.index('$usageProfileTarget = $null')
    refute_nil running_gate
    refute_nil first_install_target
    assert_operator running_gate, :<, first_install_target
    assert_includes windows_installer, '"client_running_profile_three_deferred"'
    assert_includes windows_installer, '"client_running_auto_update_deferred"'
    refute_includes windows_installer, "installed_running_client"
    assert_includes windows_tests, 'Get-TreeContentSnapshot $runningCase'
    assert_includes windows_tests, "client_running_profile_three_deferred"

    assert_includes windows_profiles, 'Updated = $updatedValue'
    assert_includes windows_profiles,
                    "$updatedRawValue -match '^(?:~|null|Null|NULL)$'"
    assert_includes windows_installer, 'BeforeUpdated = [string]$profile.Updated'
    assert_includes windows_installer, "Version = 2"
    assert_includes windows_installer, "Test-SafeUpdateRefreshEvidence"
    assert_includes windows_installer, '"safe_update_refresh_pending"'
    assert_includes windows_safe_update,
                    'UseUpdatedEvidence = ($manifestVersion -eq 2)'
    assert_includes windows_safe_update,
                    'CanAutoRestore = ($manifestVersion -eq 2)'
    assert_includes windows_safe_update,
                    'if ($manifestVersion -eq 2 -and ('
    assert_includes windows_installer,
                    '@($recoveryItems | Where-Object { -not $_.CanAutoRestore }).Count -gt 0'
    assert_includes windows_installer, '"safe_update_legacy_recovery_pending"'
    assert_includes windows_installer, '"safe_update_legacy_snapshot_required"'
    assert_includes windows_installer, '$safeUpdateContentRestoreEligible = $false'
    assert_includes windows_installer, 'if (-not $safeUpdateContentRestoreEligible) {'
    assert_includes windows_installer, '"safe_update_verification_retry_pending"'
    assert_includes windows_installer,
                    '[pscustomobject]@{ Path = $profilesIndexPath; Snapshot = $indexSnapshot }'
    assert_includes windows_installer,
                    '[pscustomobject]@{ Path = $targetScript; Snapshot = $scriptSnapshot }'
    version_guard_function = windows_safe_update[
      windows_safe_update.index("function Open-SafeUpdateVersionGuard")...
      windows_safe_update.index("function New-SafeUpdateSnapshotContext")
    ]
    refute_nil version_guard_function
    assert_includes version_guard_function,
                    '[ClaudeEasy.VerifiedDeleteNative]::Open($Path, $false, $false)'
    assert_includes version_guard_function,
                    "[ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint"
    assert_includes version_guard_function,
                    "[ClaudeEasy.VerifiedDeleteNative]::GetLinkCount"
    snapshot_function = windows_safe_update[
      windows_safe_update.index("function New-SafeUpdateSnapshotContext")...
      windows_safe_update.index("function Get-SafeUpdateRecoveryItems")
    ]
    refute_nil snapshot_function
    assert_includes snapshot_function,
                    'Assert-ClaudeEasyProxyGroupCollection $profileText $file'
    assert_includes snapshot_function,
                    'Test-MihomoCandidate $CorePath $profileText $ProfileDirectory'
    assert_includes snapshot_function, 'SnapshotBytes = $profileBytes'
    assert_includes snapshot_function, '$fileGuards += $indexGuard'
    assert_includes snapshot_function, '$fileGuards += $profileGuard'
    windows_transaction = File.read(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    )
    assert_includes windows_transaction, '[switch]$UseSourceBytes'
    assert_includes windows_transaction,
                    '$backupStream.Write($SourceBytes, 0, $SourceBytes.Length)'
    assert_includes windows_installer, '-SourceBytes $profile.SnapshotBytes'
    assert_includes windows_installer, "-UseSourceBytes"
    snapshot_guard = windows_installer.index(
      '$snapshotContext = New-SafeUpdateSnapshotContext'
    )
    snapshot_backup = windows_installer.index(
      '$backup = Backup-Versioned `'
    )
    snapshot_manifest = windows_installer.index(
      '$manifest = [ordered]@{ Version = 2'
    )
    snapshot_dispose = windows_installer.index(
      'foreach ($guard in @($snapshotContext.Guards)) { $guard.Dispose() }'
    )
    [snapshot_guard, snapshot_backup, snapshot_manifest, snapshot_dispose].each do |index|
      refute_nil index
    end
    assert_operator snapshot_guard, :<, snapshot_backup
    assert_operator snapshot_backup, :<, snapshot_manifest
    assert_operator snapshot_manifest, :<, snapshot_dispose
    refresh_function = windows_safe_update[
      windows_safe_update.index("function Test-SafeUpdateRefreshEvidence")...
      windows_safe_update.index("function Get-SafeUpdateRecoveryItems")
    ]
    refute_nil refresh_function
    assert_match(
      /\$CurrentSha256 -cne \$BeforeSha256\) \{\s+return \$true/,
      refresh_function
    )
    assert_includes refresh_function,
                    'if (-not $UseUpdatedEvidence) { return $false }'
    assert_includes refresh_function, 'return $currentTimestamp -gt $beforeTimestamp'
    assert_includes windows_tests,
                    "safe update verification accepted a batch in which no subscription was refreshed"
    assert_includes windows_tests,
                    "newer client update timestamp"
    assert_includes windows_tests,
                    "snapshot accepted a subscription written before the client's profiles index commit"
    assert_includes windows_tests,
                    "legacy safe-update manifest auto-restored an untrusted backup"
    assert_includes windows_tests,
                    "unchanged valid legacy snapshot with missing or corrupted backups remained permanently pending"
    assert_includes windows_tests,
                    "legacy recovery could not complete after every subscription was refreshed"
    assert_includes windows_tests,
                    "concurrent profiles index change triggered a safe-update rollback"
    assert_includes windows_tests, "# concurrent candidate one"
    assert_includes windows_tests, "# index-race candidate one"
    assert_includes windows_tests,
                    "unquoted YAML null was not accepted as an absent client update timestamp"
    assert_includes windows_tests,
                    "quoted null was accepted as client update metadata"
    lock_setup = windows_tests.index(
      '$runningFixtureLock = Enter-AppHomeMutationLock $runningCase'
    )
    lock_baseline = windows_tests.index(
      '$runningBefore = Get-TreeContentSnapshot $runningCase'
    )
    refute_nil lock_setup
    refute_nil lock_baseline
    assert_operator lock_setup, :<, lock_baseline

    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(
        File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
      ),
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents.each do |document|
      assert_includes document, "already_disabled_owned"
      assert_includes document, "client_running_profile_three_deferred"
      assert_includes document, "safe_update_refresh_pending"
      assert_includes document, "safe_update_legacy_recovery_pending"
      assert_includes document, "safe_update_legacy_snapshot_required"
      assert_includes document, "safe_update_verification_retry_pending"
      assert_includes document, "updated: null"
      assert_includes document, "只读版本锁"
    end
  end

  def test_windows_failed_safe_update_rollback_deletes_manifest_in_the_same_transaction
    installer = File.read(File.join(SKILL, "scripts/install_windows.ps1"))
    safe_update = File.read(
      File.join(SKILL, "scripts/windows/install_windows/safe_update.ps1")
    )

    assert_includes safe_update, "Invoke-VerifiedWriteDeleteTransaction"
    assert_includes safe_update, "ManifestPath"
    assert_includes safe_update, "ManifestSnapshot"
    restore_call = installer.lines.find { |line| line.include?("$restoreResult = Restore-SafeUpdateFiles") }
    refute_nil restore_call
    assert_includes restore_call, "$safeUpdateStatePath"
    assert_includes restore_call, "$manifestSnapshot"
    assert_equal 1, installer.scan("Remove-VerifiedOwnedFile $safeUpdateStatePath").length
  end

  def test_windows_safe_update_restores_a_missing_manifest_target
    installer = File.read(File.join(SKILL, "scripts/install_windows.ps1"))
    safe_update = File.read(
      File.join(SKILL, "scripts/windows/install_windows/safe_update.ps1")
    )
    windows_tests = File.binread(
      File.join(ROOT, "tests/test_windows_installer.ps1")
    ).force_encoding("UTF-8")

    index_snapshot = installer.index(
      'Get-OptionalFileSnapshot $profilesIndexPath "profiles.yaml"'
    )
    observed_missing = installer.index(
      '$observedCurrentHashes[$recovery.TargetPath] = ""'
    )
    refute_nil index_snapshot
    refute_nil observed_missing
    assert_operator index_snapshot, :<, observed_missing
    verify_prefix = installer[index_snapshot...observed_missing]
    refute_includes verify_prefix, "Get-RemoteSubscriptionTargets"
    assert_includes safe_update, "function Get-SafeUpdateVerificationTargets("
    assert_includes safe_update,
                    '$items = @(Get-RemoteSubscriptionProfileItems @(Split-YamlLines $ProfilesIndexText))'
    assert_includes safe_update, "if ($matches.Count -eq 1) {"
    assert_includes safe_update, '$path = [string]$recovery.TargetPath'
    assert_includes safe_update,
                    '$observedHash = [string]$ObservedHashes[$recovery.TargetPath]'
    assert_includes safe_update,
                    'if ([string]::IsNullOrWhiteSpace($observedHash)) {'
    assert_includes safe_update, "                Existed = $false"
    assert_includes windows_tests,
                    "safe update did not recreate a missing remote subscription"

    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(
        File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
      ),
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents.each do |document|
      assert_includes document, "订阅文件缺失"
      assert_includes document, "原子重建"
    end
  end

  def test_windows_preparation_recovery_accepts_targets_removed_by_the_main_journal
    transaction = File.read(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    )
    recovery_start = transaction.index("function Repair-InterruptedFilePreparation")
    recovery_end = transaction.index("function Write-FileTransactionJournal", recovery_start)
    refute_nil recovery_start
    refute_nil recovery_end
    recovery = transaction[recovery_start...recovery_end]

    assert_includes recovery, 'if (-not $target.Exists) { continue }'
  end

  def test_windows_interrupted_current_config_recovery_waits_for_the_client
    transaction = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    ).force_encoding("UTF-8")
    installer = File.binread(
      File.join(SKILL, "scripts/install_windows.ps1")
    ).force_encoding("UTF-8")
    uninstaller = File.binread(
      File.join(SKILL, "scripts/uninstall_windows.ps1")
    ).force_encoding("UTF-8")
    windows_tests = File.binread(
      File.join(ROOT, "tests/test_windows_installer.ps1")
    ).force_encoding("UTF-8")

    assert_includes transaction,
                    "function Test-CurrentConfigRecoveryRequiresStoppedClient("
    assert_includes transaction,
                    "function Test-InterruptedRecoveryCommitCondition("
    assert_includes transaction,
                    "$recovered = Invoke-InterruptedTransactionRecovery " \
                    "$plan $preCommitCondition"
    assert_includes transaction,
                    "Test-InterruptedRecoveryCommitCondition $preCommitCondition"
    assert_includes transaction,
                    'throw "客户端保持运行；中断的当前配置事务等待恢复。"'

    journal_start = transaction.index("function Invoke-InterruptedTransactionRecovery(")
    journal_end = transaction.index(
      "\nfunction Assert-InterruptedTransactionRecovered(",
      journal_start
    )
    refute_nil journal_start
    refute_nil journal_end
    journal_body = transaction[journal_start...journal_end]
    journal_identity = journal_body.index(
      "[ClaudeEasy.VerifiedDeleteNative]::GetIdentity($handle)"
    )
    journal_condition = journal_body.index(
      "Test-InterruptedRecoveryCommitCondition $PreCommitCondition"
    )
    journal_write = journal_body.index("Write-LockedStreamBytes")
    journal_delete = journal_body.index(
      "Set-VerifiedDeleteDisposition $entry.Stream $true",
      journal_write
    )
    refute_nil journal_identity
    refute_nil journal_condition
    refute_nil journal_write
    refute_nil journal_delete
    assert_operator journal_identity, :<, journal_condition
    assert_operator journal_condition, :<, journal_write
    assert_operator journal_condition, :<, journal_delete

    preparation_start = transaction.index("function Repair-InterruptedFilePreparation")
    preparation_end = transaction.index(
      "\nfunction Write-FileTransactionJournal(",
      preparation_start
    )
    refute_nil preparation_start
    refute_nil preparation_end
    preparation_body = transaction[preparation_start...preparation_end]
    preparation_identity = preparation_body.index(
      "[ClaudeEasy.VerifiedDeleteNative]::GetIdentity($handle)"
    )
    preparation_condition = preparation_body.index(
      "Test-InterruptedRecoveryCommitCondition $preCommitCondition"
    )
    preparation_delete = preparation_body.index(
      "Set-VerifiedDeleteDisposition $entry.Stream $true"
    )
    refute_nil preparation_identity
    refute_nil preparation_condition
    refute_nil preparation_delete
    assert_operator preparation_identity, :<, preparation_condition
    assert_operator preparation_condition, :<, preparation_delete

    [installer, uninstaller].each do |entrypoint|
      assert_includes entrypoint, '"transaction_recovery_pending"'
    end
    assert_includes windows_tests,
                    "running client changed an interrupted current-config target"
    assert_includes windows_tests,
                    "running client consumed an interrupted current-config journal"
    assert_includes windows_tests,
                    "running client changed a prepared current-config target"
    assert_includes windows_tests,
                    "running client consumed a current-config preparation record"
    assert_includes windows_tests,
                    "interrupted recovery rechecks a newly started client"
    assert_includes windows_tests,
                    "newly started client allowed interrupted journal recovery"
    assert_includes windows_tests,
                    "newly started client allowed prepared current-config targets"

    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(
        File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
      ),
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents.each do |document|
      assert_includes document, "中断的当前配置事务"
      assert_includes document, "transaction_recovery_pending"
      assert_includes document, "锁定并核对全部恢复目标"
      assert_includes document, "再次检查"
    end
  end

  def test_windows_uninstall_rechecks_client_after_transaction_targets_are_locked
    transaction = File.read(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    )
    uninstaller = File.binread(
      File.join(SKILL, "scripts/uninstall_windows.ps1")
    ).force_encoding("UTF-8")
    windows_tests = File.binread(
      File.join(ROOT, "tests/test_windows_installer.ps1")
    ).force_encoding("UTF-8")

    transaction_start = transaction.index("function Invoke-VerifiedPathTransaction(")
    transaction_end = transaction.index(
      "\nfunction Invoke-VerifiedFileTransaction(",
      transaction_start
    )
    refute_nil transaction_start
    refute_nil transaction_end
    transaction_body = transaction[transaction_start...transaction_end]
    identity_check = transaction_body.index(
      "[ClaudeEasy.VerifiedDeleteNative]::GetIdentity($handle)"
    )
    precommit_check = transaction_body.index(
      "$preCommitResults = @(& $PreCommitCondition)"
    )
    journal_write = transaction_body.index(
      "$journalBytes = Write-FileTransactionJournal $opened"
    )
    refute_nil identity_check
    refute_nil precommit_check
    refute_nil journal_write
    assert_operator identity_check, :<, precommit_check
    assert_operator precommit_check, :<, journal_write

    assert_includes transaction, "[scriptblock]$PreCommitCondition = $null"
    assert_includes transaction,
                    "Invoke-VerifiedPathTransaction $WriteTargets $DeleteTargets $PreCommitCondition"
    assert_includes transaction, "elseif ($mutationStarted)"
    assert_includes uninstaller, "$transactionCommitted = Invoke-VerifiedWriteDeleteTransaction"
    assert_includes uninstaller,
                    "$writeTargets $deletePlans $clientStoppedPreCommit"
    assert_includes uninstaller,
                    "if ($null -ne $clientStoppedPreCommit -and -not $transactionCommitted)"
    assert_includes windows_tests,
                    "client-start race changed a protected uninstall target"
    assert_includes windows_tests,
                    "client-start abort rewrote an existing transaction target"

    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(
        File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
      ),
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents.each { |document| assert_includes document, "提交条件" }
  end

  def test_windows_install_and_restore_recheck_client_at_locked_precommit
    transaction = File.read(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    )
    installer = File.binread(
      File.join(SKILL, "scripts/install_windows.ps1")
    ).force_encoding("UTF-8")
    windows_tests = File.binread(
      File.join(ROOT, "tests/test_windows_installer.ps1")
    ).force_encoding("UTF-8")

    assert_includes transaction,
                    "function Invoke-VerifiedFileTransaction(\n" \
                    "    [object[]]$Targets,\n" \
                    "    [scriptblock]$PreCommitCondition = $null\n" \
                    ")"
    assert_includes transaction,
                    "Invoke-VerifiedPathTransaction $Targets @() $PreCommitCondition"
    assert_includes installer,
                    "$restoreCommitted = Invoke-VerifiedFileTransaction"
    assert_includes installer,
                    "$installCommitted = Invoke-VerifiedFileTransaction $targets $clientStoppedPreCommit"
    assert_includes installer,
                    ") $clientStoppedPreCommit\n" \
                    "    if (-not $restoreCommitted)"
    assert_includes installer,
                    "$installCommitted = Invoke-VerifiedFileTransaction " \
                    "$targets $clientStoppedPreCommit\n" \
                    "    if (-not $installCommitted)"
    assert_includes windows_tests,
                    "client-start install changed a protected target"
    assert_includes windows_tests,
                    "client-start restore changed current configuration"

    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(
        File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
      ),
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents.each do |document|
      assert_includes document, "安装、备份恢复和卸载"
      assert_includes document, "提交条件"
    end
  end

  def test_windows_uninstall_preserves_a_pending_safe_update
    uninstaller = File.binread(
      File.join(SKILL, "scripts/uninstall_windows.ps1")
    ).force_encoding("UTF-8")
    windows_tests = File.binread(
      File.join(ROOT, "tests/test_windows_installer.ps1")
    ).force_encoding("UTF-8")

    lock = uninstaller.index("$mutationLock = Enter-AppHomeMutationLock $AppHome")
    pending_snapshot = uninstaller.index(
      'Get-OptionalFileSnapshot $safeUpdateStatePath "安全更新准备记录"'
    )
    install_state_snapshot = uninstaller.index(
      'Get-OptionalFileSnapshot $statePath "安装状态"'
    )
    refute_nil lock
    refute_nil pending_snapshot
    refute_nil install_state_snapshot
    assert_operator lock, :<, pending_snapshot
    assert_operator pending_snapshot, :<, install_state_snapshot
    assert_includes uninstaller,
                    "if ($safeUpdateStateSnapshot.Exists) {\n" \
                    "        Complete-PendingSafeUpdateUninstall\n" \
                    "    }"
    assert_includes uninstaller, '"partial" "safe_update_pending"'
    assert_includes windows_tests,
                    "pending safe update uninstall changed AppHome"

    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      File.read(File.join(SKILL, "references/patch-policy.md")),
      File.read(
        File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md")
      ),
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents.each do |document|
      assert_includes document, "尚未验收"
      assert_includes document, "safe_update_pending"
    end
  end

  def test_installers_preflight_and_uninstallers_restore_owned_settings
    mac_install = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    mac_uninstall = File.read(File.join(SKILL, "scripts/uninstall_macos.sh"))
    windows_install_entry = File.binread(File.join(SKILL, "scripts/install_windows.ps1"))
    windows_install = windows_installer_source
    windows_uninstall = File.binread(File.join(SKILL, "scripts/uninstall_windows.ps1"))
    windows_tests = File.binread(File.join(ROOT, "tests/test_windows_installer.ps1"))
    patcher = mac_patcher_source

    profile_stage = mac_install.index("\nstage_profile_selection\n")
    assert_operator mac_install.index('id -u'), :<, profile_stage
    assert_operator mac_install.index('core_status='), :<, profile_stage
    assert_operator mac_install.index('--snapshot-initial'), :<, profile_stage
    auto_update_disable = mac_install.index("run_subscription_auto_update_disable", profile_stage)
    refute_nil auto_update_disable
    assert_operator profile_stage, :<, auto_update_disable
    assert_includes mac_install, "rollback_profile_selection"
    assert_operator mac_install.index('core_status='), :<, auto_update_disable
    refute_includes mac_install, "launchctl bootstrap"
    refute_includes mac_install, "launchctl bootout"
    refute_includes mac_install, "WatchPaths"
    refute_includes mac_uninstall, "launchctl bootout"
    refute_includes mac_uninstall, 'defaults write "$DEFAULTS_DOMAIN" restoreTunProxy'
    assert_includes mac_uninstall, "旧版安装前的 TUN 偏好无法证明仍是当前选择"
    assert_includes patcher, "File::EXCL"

    assert_equal "\xEF\xBB\xBF".b, windows_install_entry.byteslice(0, 3)
    assert_equal "\xEF\xBB\xBF".b, windows_uninstall.byteslice(0, 3)
    assert_equal "\xEF\xBB\xBF".b, windows_tests.byteslice(0, 3)
    assert_includes windows_install.force_encoding("UTF-8"), "MihomoPath"
    assert_includes windows_install, "Test-MihomoVersion"
    assert_includes windows_install, "OriginalBytes"
    assert_includes windows_install, "install-state.json"
    assert_includes windows_install, "SetAccessRuleProtection"
    assert_includes windows_install, "S-1-5-18"
    assert_includes windows_install, "S-1-5-32-544"
    assert_includes windows_uninstall, "InstalledSha256"
    assert_includes windows_install, "claude-easy-auto-update-state.json"
    assert_includes windows_uninstall, "claude-easy-auto-update-state.json"
    assert_includes windows_uninstall, "Invoke-VerifiedWriteDeleteTransaction"
    assert_includes windows_tests, "auto-update restore did not reconstruct the original absent/null/tilde/empty-map shapes"
    assert_includes windows_tests, "running offline uninstall changed a protected target"
    assert_includes windows_tests, "delete transaction allowed a same-target write between verification and deletion"
  end

  def test_windows_safe_uninstall_ownership_and_partial_boundary_are_documented
    readme = File.read(File.join(ROOT, "README.md"))
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    design = File.read(File.join(ROOT, "docs/superpowers/specs/2026-07-20-claude-easy-skill-design.md"))
    baseline = File.read(File.join(ROOT, "tests/baseline.md"))

    [readme, policy, design].each do |source|
      assert_includes source, "所有权状态"
      assert_match(/客户端.*运行.*(?:不改任何文件|整批不改|整批卸载返回 `partial`)/, source)
      assert_match(/不得要求.*退出、停止或重启|不要求退出、停止或重启|不会要求退出或重启/, source)
    end
    assert_includes skill, "Windows 卸载返回 `partial`"
    assert_includes skill, "必须保留旧档位且不得继续降档"
    assert_includes baseline, "句柄绑定删除"
    assert_includes baseline, "文件身份"
    assert_includes baseline, "失败恢复不覆盖并发内容"
  end


  def test_skill_and_scripts_never_stop_or_restart_clash
    skill = File.read(File.join(SKILL, "SKILL.md"))
    readme = File.read(File.join(ROOT, "README.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    mac_install = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    windows_install = windows_installer_source
    windows_uninstall = File.binread(File.join(SKILL, "scripts/uninstall_windows.ps1")).force_encoding("UTF-8")

    [skill, readme, policy].each do |source|
      assert_includes source, "绝对不要退出、停止或重启 Clash 客户端"
      refute_includes source, "请先从托盘菜单完全退出"
      refute_includes source, "退出客户端，再"
    end
    [mac_install, windows_install, windows_uninstall].each do |source|
      refute_match(/osascript[^\n]*(?:quit|terminate)/i, source)
      refute_match(/Stop-Process|taskkill|killall/i, source)
      refute_includes source, "请先从托盘菜单完全退出"
      refute_includes source, "退出客户端，再"
    end
  end

  def test_validation_timeout_and_idempotence_guards_are_documented
    skill = File.read(File.join(SKILL, "SKILL.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    mac = mac_patcher_source
    windows = windows_installer_source

    [skill, policy].each do |source|
      assert_includes source, "30 秒"
      assert_includes source, "二次转换"
    end
    assert_includes mac, "VALIDATION_TIMEOUT_SECONDS = 30"
    assert_includes mac, ":non_idempotent"
    refute_match(/^\s*def (?:reload|select_proxy)\b/, mac)
    assert_includes windows, "WaitForExit($TimeoutSeconds * 1000)"
    assert_includes windows, '$process.Kill()'
  end

  def test_reality_short_id_scope_is_documented
    readme = File.read(File.join(ROOT, "README.md"))
    policy = File.read(File.join(SKILL, "references/patch-policy.md"))
    assert_match(/macOS[^\n]*REALITY `short-id`|REALITY `short-id`[^\n]*macOS/, readme)
    assert_match(/macOS[^\n]*REALITY `short-id`|REALITY `short-id`[^\n]*macOS/, policy)
  end

  def test_ci_covers_production_runtimes_and_pins_actions
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    uses = workflow.scan(/^\s*- uses:\s*(\S+)/).flatten

    refute_empty uses
    uses.each { |entry| assert_match(/@[0-9a-f]{40}\z/, entry, entry) }
    assert_includes workflow, "runs-on: macos-15"
    assert_includes workflow, "ruby tests/run_macos_production_probes.rb"
    assert_includes workflow, "ruby tests/coverage_ruby.rb"
    assert_includes workflow, "ruby tests/test_mutation_safety.rb"
    assert_includes workflow, "ruby tests/test_macos_wrappers.rb"
    assert_includes workflow, "runs-on: ${{ matrix.runner }}"
    assert_includes workflow, "runner: macos-15-intel"
    assert_includes workflow, "architecture: arm64"
    assert_includes workflow, "architecture: amd64"
    assert_includes workflow, "v1.19.27:$MIHOMO_MINIMUM_SHA256:MINIMUM"
    assert_includes workflow, "v1.19.29:$MIHOMO_CURRENT_SHA256:CURRENT"
    assert_includes workflow, "3617c9d8a5a55aecfe1ebd0f55ff59f2706c8ad68fd65c6c4e5f7cf2b74263f1"
    assert_includes workflow, "5392bea435a1c4b0a496571daafa977f744207cfafac18fb78a9b7d0747585c2"
    assert_includes workflow, "4dc25df9e899f14161911302a8ee5fc9e202ed9c976fc405bf82c50ff27466ca"
    assert_includes workflow, "b57fec2e38462532fe75252792b355b99db16b0b8ea2d6bdf0cd8bc7ddacb9d2"
    mihomo_hashes = workflow.scan(/(?:minimum|current)_sha256:\s*"([^"]+)"/).flatten
    assert_equal 4, mihomo_hashes.length
    mihomo_hashes.each { |digest| assert_match(/\A[0-9a-f]{64}\z/, digest) }
    assert_includes workflow, "github.com/MetaCubeX/mihomo/releases/download/"
    assert_includes workflow, "shasum -a 256 --check"
    assert_includes workflow, "--connect-timeout 15 --max-time 300"
    assert_equal 2, workflow.scan(/CLAUDE_EASY_REQUIRE_REAL_MIHOMO: "1"/).length
    assert_includes workflow, 'CLAUDE_EASY_TEST_MIHOMO="$MIHOMO_MINIMUM_PATH" ruby'
    assert_includes workflow, 'CLAUDE_EASY_TEST_MIHOMO="$MIHOMO_CURRENT_PATH" ruby'
    assert_equal 2, workflow.scan(/ruby tests\/run_macos_mihomo_validation\.rb/).length
    macos_tests = File.read(File.join(ROOT, "tests/test_macos_patcher.rb"))
    assert_includes macos_tests, 'ENV["CLAUDE_EASY_REQUIRE_REAL_MIHOMO"] == "1"'
    assert_includes macos_tests, 'ENV["CLAUDE_EASY_TEST_MIHOMO"]'
    assert_includes workflow, "--test-coverage-lines=100"
    assert_includes workflow, "--test-coverage-functions=100"
    assert_includes workflow, "--test-coverage-branches=80"
    assert_includes workflow, "34b4c5bc0c176eebd298f6624aa23ea41985a2c54efb04eb0e9c4542e45190ee"
    assert_includes workflow, "1a8520cfe425441eba3eba8623b27b985020031243fe1ecaa1af2b92358a03f9"
    assert_includes workflow, "mihomo-windows-amd64-$env:MIHOMO_VERSION.zip"
    assert_includes workflow, "-RealMihomoOnly"
    assert_includes workflow, "executable: powershell.exe"
    assert_includes workflow, "executable: pwsh.exe"
    assert_equal 4, workflow.scan(/- version: v1\.19\.(?:27|29)\n\s+sha256: "[0-9a-f]{64}"\n\s+executable: (?:powershell|pwsh)\.exe\n\s+edition: (?:Desktop|Core)\n\s+major: [57]/).length
    assert_includes workflow, "--connect-timeout 15 --max-time 300"
    assert_includes workflow, "shell: powershell"
    assert_includes workflow, "Get-Command powershell.exe"
    assert_includes workflow, "-ExpectedPSEdition Desktop -ExpectedPSMajor 5"
    assert_match(/^  windows-installer-powershell-5:$/, workflow)
    assert_includes workflow, "shell: pwsh"
    assert_includes workflow, "Get-Command pwsh.exe"
    assert_includes workflow, "-ExpectedPSEdition Core -ExpectedPSMajor 7"
    assert_match(/^  windows-installer-powershell-7:$/, workflow)
    assert_includes workflow, "git diff --check"
    assert_includes workflow, "fetch-depth: 0"
    assert_includes workflow, "github.event.before"
    assert_includes workflow, "github.event.pull_request.base.sha"
    assert_equal 6, workflow.scan(/timeout-minutes:\s*20/).length
  end

  def test_github_actions_shell_fields_are_static
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    shell_values = workflow.scan(/^\s+shell:\s*(.+)$/).flatten

    refute_empty shell_values
    assert shell_values.all? { |value| %w[bash powershell pwsh].include?(value) },
           "GitHub rejects expression contexts in steps[*].shell before any job starts"
  end

  def test_windows_full_runtime_jobs_require_completion_receipts
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    windows_tests = File.binread(File.join(ROOT, "tests/test_windows_installer.ps1")).force_encoding("UTF-8")

    {
      "windows-installer-powershell-5" => ["powershell.exe", "Desktop", "5"],
      "windows-installer-powershell-7" => ["pwsh.exe", "Core", "7"]
    }.each do |job_name, (executable, edition, major)|
      job = workflow[/^  #{Regexp.escape(job_name)}:\n(?:(?!^  \S).*\n)*/]
      refute_nil job, "missing Windows full-suite job: #{job_name}"
      assert_match(
        /^\s*\$runtime = \(Get-Command #{Regexp.escape(executable)}\)\.Source\n\s*& \$runtime -NoLogo -NoProfile -File \.\/tests\/test_windows_installer\.ps1 -PowerShellPath \$runtime -ExpectedPSEdition #{edition} -ExpectedPSMajor #{major} -CompletionReceiptPath \$receipt$/,
        job
      )
      assert_includes job, 'Remove-Item -LiteralPath $receipt -Force -ErrorAction SilentlyContinue'
      assert_includes job, 'Test-Path -LiteralPath $receipt -PathType Leaf'
      assert_includes job, 'Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json'
      assert_includes job, '$completed.Mode -ne "Full"'
      assert_includes job, "$completed.PSEdition -ne \"#{edition}\""
      assert_includes job, "[int]$completed.PSMajor -ne #{major}"
    end

    assert_includes windows_tests, "[string]$CompletionReceiptPath"
    assert_includes windows_tests, 'Mode = "Full"'
    assert_includes windows_tests, "PSEdition = $ExpectedPSEdition"
    assert_includes windows_tests, "PSMajor = $ExpectedPSMajor"
    assert_match(/WriteAllText\(\s*\$CompletionReceiptPath,/m, windows_tests)
  end

  def test_windows_real_mihomo_jobs_require_case_completion_receipts
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    windows_tests = File.binread(File.join(ROOT, "tests/test_windows_installer.ps1")).force_encoding("UTF-8")
    job = workflow[/^  windows-mihomo:\n(?:(?!^  \S).*\n)*/]

    refute_nil job
    assert_includes job, '$receipt = Join-Path $env:RUNNER_TEMP "claude-easy-windows-mihomo.json"'
    assert_includes job, 'Remove-Item -LiteralPath $receipt -Force -ErrorAction SilentlyContinue'
    assert_includes job, '$nonce = [Guid]::NewGuid().ToString("N")'
    assert_includes job, '-CompletionReceiptPath $receipt'
    assert_includes job, '-CompletionReceiptNonce $nonce'
    assert_includes job, 'Test-Path -LiteralPath $receipt -PathType Leaf'
    assert_includes job, 'Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json'
    assert_includes job, '$completed.Mode -ne "RealMihomo"'
    assert_includes job, "$completed.PSEdition -ne '${{ matrix.edition }}'"
    assert_includes job, "[int]$completed.PSMajor -ne ${{ matrix.major }}"
    assert_includes job, '$completed.Nonce -ne $nonce'
    assert_includes job, '[int]$completed.CoreCount -ne $core.Count'
    assert_includes job, '@($completed.Cases | ForEach-Object { "$($_.Core):$($_.Profile)" })'
    assert_includes job, '@("1:1", "1:2", "1:3")'

    assert_includes windows_tests, "[string]$CompletionReceiptNonce"
    assert_includes windows_tests, '$realCompletedCases = New-Object System.Collections.ArrayList'
    assert_includes windows_tests,
                    '[void]$realCompletedCases.Add([ordered]@{ Core = $realCoreIndex; Profile = $realUsageProfile })'
    assert_includes windows_tests, 'Mode = "RealMihomo"'
    assert_includes windows_tests, "PSEdition = $ExpectedPSEdition"
    assert_includes windows_tests, "PSMajor = $ExpectedPSMajor"
    assert_includes windows_tests, "Nonce = $CompletionReceiptNonce"
    assert_includes windows_tests, "CoreCount = $RealMihomoPaths.Count"
    assert_includes windows_tests, "Cases = @($realCompletedCases)"
    assert_includes windows_tests, 'foreach ($realUsageProfile in @(1, 2, 3))'

    branch = windows_tests[/        if \(\$RealMihomoOnly\) \{.*?^        \}/m]
    refute_nil branch
    transformed_validation = branch.index(
      'Assert-True (' + "\n" +
      '                        $realTransformedValidation.ExitCode -eq 0'
    )
    completed_case = branch.index(
      '[void]$realCompletedCases.Add([ordered]@{ Core = $realCoreIndex; Profile = $realUsageProfile })'
    )
    receipt = branch.index('Mode = "RealMihomo"')
    failure_gate = branch.index('if ($script:deferredProbeFailures.Count -gt 0)')
    return_statement = branch.rindex("            return")
    refute_nil transformed_validation
    refute_nil completed_case
    refute_nil receipt
    refute_nil failure_gate
    refute_nil return_statement
    assert_operator transformed_validation, :<, completed_case
    assert_operator failure_gate, :<, receipt
    assert_operator receipt, :<, return_statement
  end

  def test_macos_real_mihomo_runner_rejects_zero_or_skipped_cases
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    patcher_tests = File.read(File.join(ROOT, "tests/test_macos_patcher.rb"))
    runner_path = File.join(ROOT, "tests/run_macos_mihomo_validation.rb")

    assert File.file?(runner_path), "missing real Mihomo validation runner"
    runner = File.read(runner_path)
    assert_equal 1,
                 patcher_tests.scan(
                   /^  def test_generated_profile_passes_installed_mihomo_validation$/
                 ).length
    assert_equal 2, workflow.scan(/ruby tests\/run_macos_mihomo_validation\.rb/).length
    refute_includes workflow,
                    "ruby tests/test_macos_patcher.rb --name test_generated_profile_passes_installed_mihomo_validation"
    assert_includes runner, 'counts == [1, counts&.fetch(1, 0), 0, 0, 0]'
    assert_includes runner, "counts&.fetch(1, 0).positive?"
    assert_includes runner, '"CLAUDE_EASY_MIHOMO_RECEIPT_PATH"'
    assert_includes runner, '"CLAUDE_EASY_MIHOMO_RECEIPT_NONCE"'
    assert_includes runner, '"profiles_completed" => [1, 2, 3]'
    assert_includes runner, '"validations" => expected_validations'
    assert_includes runner, '"core_sha256" => expected_core_sha256'
    assert patcher_tests.include?("      [1, 2, 3].each do |usage_profile|"),
           "real Mihomo validation must execute all three usage profiles"
    assert_includes patcher_tests, '"profiles_completed" => profiles_completed'
    assert_includes patcher_tests, '"validations" => validations'
    assert_includes patcher_tests, '"core_sha256" => Digest::SHA256.file(core).hexdigest'
  end

  def test_ruby_coverage_requires_the_entire_transform_module_at_one_hundred_percent
    source = File.read(File.join(ROOT, "tests/coverage_ruby.rb"))

    assert_includes source, "MINIMUM_PATCHER_LINE_COVERAGE = 100.0"
    assert_includes source, "MINIMUM_MODULE_LINE_COVERAGE = 100.0"
    assert_includes source, "MINIMUM_VERIFY_LINE_COVERAGE = 100.0"
    assert_includes source, "MINIMUM_PRODUCTION_BRANCH_COVERAGE = 75.0"
    assert_includes source, 'TRANSFORM_PATH = File.join(MACOS_RUBY_ROOT, "patch_profiles", "transform.rb")'
    assert_includes source, "MINIMUM_TRANSFORM_LINE_COVERAGE = 100.0"
    assert_includes source, "uncovered_line_ranges"
    assert_includes source, "uncovered_branch_lines"
    assert_includes source, "path == TRANSFORM_PATH"
    refute_includes source, "TRANSFORM_CORE_METHODS"
    refute_includes source, "RubyVM::AbstractSyntaxTree"
  end

  def test_windows_runtime_tests_use_powershell_ast_for_automatic_variable_writes
    source = File.read(File.join(ROOT, "tests/test_windows_installer.ps1"))

    assert_includes source, "Assert-NoReadOnlyAutomaticVariableWrites"
    assert_includes source, "AssignmentStatementAst"
    assert_includes source, "ParameterAst"
    assert_includes source, "ForEachStatementAst"
    assert_includes source, "UnaryExpressionAst"
    assert_includes source, "PostfixPlusPlus"
    assert_includes source, "CommandAst"
    assert_includes source, "Set-Variable"
    assert_includes source, "Invoke-DeferredProbe"
    assert_match(
      /^    if \(\$script:deferredProbeFailures\.Count -gt 0\) \{\n        throw \("deferred production probes failed:/,
      source
    )
    assert_includes source, "Compress-Archive"
    assert_includes source, "Expand-Archive"
    assert_includes source, "incomplete release changed AppHome"
  end

  def test_windows_candidate_cleanup_watcher_is_armed_before_publish
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/mihomo.ps1")
    ).force_encoding("UTF-8")
    function_source = source[
      /function Test-MihomoCandidate\b.*?(?=^function |\z)/m
    ]

    refute_nil function_source
    watcher = function_source.index("Start-MihomoCandidateCleanupWatcher $temporary")
    publish = function_source.index("[System.IO.File]::Move($staging, $temporary)")
    refute_nil watcher
    refute_nil publish
    assert_operator watcher, :<, publish,
                    "candidate must never become visible before caller-death cleanup is armed"
  end

  def test_windows_test_failure_diagnostics_do_not_echo_captured_output
    source = File.read(File.join(ROOT, "tests/test_windows_installer.ps1"))
    diagnostic = source[/function Get-TestOutputDiagnostic\b.*?^}/m]
    json_assertion = source[/function Assert-JsonResult\b.*?^}/m]

    refute_nil diagnostic
    refute_nil json_assertion
    assert_includes diagnostic, '[System.Security.Cryptography.SHA256]::Create()'
    assert_includes diagnostic, 'return "output_length=$($text.Length) output_sha256=$digest"'
    refute_match(/return\s+\$text\b/, diagnostic)
    refute_match(/throw "[^"]*\$\(\$result\.Output\)/, source)
    refute_match(/Assert-True .*"[^"]*\$\(\$[A-Za-z0-9_]+\.Output\)/, source)
    assert_operator json_assertion.index("JSON result leaked"), :<,
                    json_assertion.index("$result.exit_code -eq $ExitCode"),
                    "privacy must be checked before a mismatched result is printed"
  end

  def test_production_probe_inventory_and_ci_aggregation_are_fixed
    patcher_source = File.read(File.join(ROOT, "tests/test_macos_patcher.rb"))
    wrapper_source = File.read(File.join(ROOT, "tests/test_macos_wrappers.rb"))
    runner_source = File.read(File.join(ROOT, "tests/run_macos_production_probes.rb"))
    windows_source = File.read(File.join(ROOT, "tests/test_windows_installer.ps1"))
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    expected_macos = %w[
      test_production_probe_mihomo_does_not_survive_a_killed_validator
      test_production_probe_next_run_recovers_batch_killed_after_first_commit
      test_production_probe_next_safe_update_recovers_batch_killed_after_first_descriptor_commit
      test_production_probe_next_safe_update_recovers_runtime_killed_after_reload
      test_production_probe_normal_batch_rejects_duplicate_file_aliases
      test_production_probe_normal_batch_restores_a_commit_when_bookkeeping_raises
      test_production_probe_safe_update_restores_a_swap_when_bookkeeping_raises
    ].sort
    expected_wrappers = %w[
      test_production_probe_install_recovers_a_killed_ready_uninstall_before_changing_profile
      test_production_probe_shared_wrapper_lock_prevents_uninstall_from_deleting_a_concurrent_install
      test_production_probe_uninstall_preserves_a_file_replaced_after_staging
      test_production_probe_uninstall_recovers_a_killed_profile_transaction_before_enabling_updates
    ]
    expected_windows = [
      "Mihomo candidate privacy and cleanup after caller death",
      "Mihomo timeout terminates descendants",
      "SUBST AppHome lock alias",
      "backup publication survives caller death",
      "duplicate transaction action field",
      "extended-path AppHome lock alias",
      "installer and uninstaller shared AppHome lock",
      "interrupted new-file transaction preserves later content",
      "interrupted recovery rechecks a newly started client",
      "interrupted transaction same-byte identity replacement",
      "new-file transaction journal empty original bytes",
      "non-proxy route termini",
      "private transaction journal ACL",
      "public new-target journal handoff strong-kill recovery",
      "public new-target pre-journal strong-kill recovery",
      "public restore strong-kill atomicity",
      "public restore same-byte identity replacement",
      "release archive public install",
      "safe-update rollback manifest strong-kill recovery",
      "short-path backup identity alias",
      "strict transaction journal byte schema",
      "strict UTF-8 safe-update validation",
      "strict safe-update manifest schema",
      "stopped-client transactions recheck after locked target verification"
    ].sort
    expected_transaction_journal_cases = %w[
      alternate-data-stream
      duplicate-action
      duplicate-actions
      duplicate-existed
      duplicate-original-base64
      duplicate-path
      duplicate-replacement-base64
      duplicate-version
      invalid-utf8
      reserved-device
      trailing-dot
      trailing-space
    ].sort
    expected_public_kill_markers = %w[
      CLAUDE_EASY_TEST_BACKUP_CRASH_READY
      CLAUDE_EASY_TEST_JOURNAL_HANDOFF_CRASH_READY
      CLAUDE_EASY_TEST_PREJOURNAL_CRASH_READY
      CLAUDE_EASY_TEST_PUBLIC_CRASH_READY
      CLAUDE_EASY_TEST_RECOVERY_CRASH_READY
      CLAUDE_EASY_TEST_RESTORE_CRASH_READY
      CLAUDE_EASY_TEST_SAFE_UPDATE_ROLLBACK_CRASH_READY
      CLAUDE_EASY_TEST_UNINSTALL_CRASH_READY
    ].sort

    assert_equal expected_macos,
                 patcher_source.scan(/^  def (test_production_probe_[a-z0-9_]+)/).flatten.sort
    assert_equal expected_wrappers,
                 wrapper_source.scan(/^  def (test_production_probe_[a-z0-9_]+)/).flatten.sort
    assert_equal expected_windows,
                 windows_source.scan(/Invoke-DeferredProbe "([^"]+)"/).flatten.sort
    journal_matrix = windows_source[
      /\$transactionJournalCases = @\(.*?\n            \)\n            \$unsafeTransactionJournals/m
    ]
    refute_nil journal_matrix
    assert_equal expected_transaction_journal_cases,
                 journal_matrix.scan(/Name = "([^"]+)"/).flatten.sort
    assert_equal expected_public_kill_markers,
                 windows_source.scan(/\$env:(CLAUDE_EASY_TEST_[A-Z_]+CRASH_READY)/).flatten.uniq.sort
    armed_public_kill_markers = windows_source.scan(
      /\$env:(CLAUDE_EASY_TEST_[A-Z_]+CRASH_READY)\s*=\s*\$([A-Za-z][A-Za-z0-9]*)/
    ).reject { |_, value| value == "null" }.map(&:first).uniq.sort
    assert_equal expected_public_kill_markers, armed_public_kill_markers
    assert_includes windows_source, '"real Mihomo core #{0} profile {1}: {2}"'
    assert_equal 1, workflow.scan("ruby tests/run_macos_production_probes.rb").length
    assert_includes runner_source, 'ENV.fetch("CLAUDE_EASY_CURRENT_RUBY", RbConfig.ruby)'
    assert_includes runner_source, 'ENV.fetch("CLAUDE_EASY_SYSTEM_RUBY", "/usr/bin/ruby")'
  end

  def test_windows_interrupted_new_file_recovery_requires_managed_bytes
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    ).force_encoding("UTF-8")
    recovery_plan = source[
      /function Get-InterruptedTransactionRecoveryPlan\b.*?(?=^function Invoke-InterruptedTransactionRecovery)/m
    ]

    refute_nil recovery_plan
    assert_match(
      /\} elseif \(\$action\.Action -eq "write"\) \{\n\s+if \(\$snapshot\.Exists -and\n\s+\$currentHash -ne \$replacementHash -and -not \$isInterruptedReplacement\) \{\n\s+throw "中断事务新建目标有无法自动合并的新改动/,
      recovery_plan
    )
  end

  def test_windows_interrupted_recovery_accepts_only_original_byte_prefixes
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    ).force_encoding("UTF-8")
    plan = source[/function Get-InterruptedTransactionRecoveryPlan\b.*?(?=^function |\z)/m]

    refute_nil plan
    assert_includes plan, "$isInterruptedOriginal"
    assert_includes plan, "$snapshot.Bytes.Length -le $action.Original.Length"
    assert_includes plan,
                    '($action.Action -ne "delete" -or $currentHash -ne $originalHash)'
    assert_match(/\$action\.Action -eq "write".*\$action\.Existed.*\$isInterruptedOriginal/m, plan)
    assert_includes plan, '@{ Operation = "write"; Action = $action; Snapshot = $snapshot }'
  end

  def test_windows_managed_script_suffix_cannot_rebind_main
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/script_js.ps1")
    ).force_encoding("UTF-8")

    assert_includes source, "function Assert-JavaScriptDoesNotBindMain"
    assert_equal 2, source.scan('Assert-JavaScriptCanCompose $restored').length
    assert_includes source, '(?:function|class|var|let|const)'
    assert_includes source, '(?<![A-Za-z0-9_$.])main\s*='
  end

  def test_windows_existing_script_cannot_rebind_main_outside_its_declaration
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/script_js.ps1")
    ).force_encoding("UTF-8")

    assert_includes source, 'Assert-JavaScriptDoesNotBindMain $withoutDeclaration'
  end

  def test_windows_existing_script_rejects_dynamic_global_escape_before_writing
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/script_js.ps1")
    ).force_encoding("UTF-8")

    assert_includes source, "function Assert-JavaScriptDoesNotUseDynamicCode"
    assert_includes source, 'Assert-JavaScriptDoesNotUseDynamicCode $Text'
    assert_includes source, '\b(?:eval|Function)\b'
    assert_includes source, '\.\s*constructor\b'
    assert_includes source, "$stringLiterals = @()"
    assert_includes source, "StringLiterals = @($stringLiterals)"
    assert_includes source, '$constructorLiteral = @($analysis.StringLiterals | Where-Object {'
    assert_includes source, '$_.Substring(1, $_.Length - 2) -ceq "constructor"'
    assert_includes source, '$constructorLiteral)'
    assert_includes source, "$templateExpressionDepths = @()"
    assert_includes source, '$templateExpressionDepths += 1'
    assert_includes source, '$state = "template"'
  end

  def test_windows_safe_update_compares_managed_envelope_not_user_script_body
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/safe_update.ps1")
    ).force_encoding("UTF-8")

    assert_includes source, "function Get-ClaudeEasyManagedScriptEnvelope"
    assert_includes source, '"`r`n// CLAUDEEASY ORIGINAL CONTENT`r`n"'
    assert_includes source, "Get-ClaudeEasyManagedScriptEnvelope $ScriptText $UsageProfile"
    assert_includes source, "Get-ClaudeEasyManagedScriptEnvelope $expectedScript $UsageProfile"
  end

  def test_windows_managed_script_preserves_top_level_semantics_then_seals_entry
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/script_js.ps1")
    ).force_encoding("UTF-8")
    uninstaller = File.binread(
      File.join(SKILL, "scripts/uninstall_windows.ps1")
    ).force_encoding("UTF-8")

    assert_includes source, '$parts += "let claudeEasyInstallManagedMain = (function ("'
    %w[Object Reflect Array Boolean Error Function JSON RegExp].each do |intrinsic|
      assert_includes source, %($parts += "  this.#{intrinsic},)
    end
    assert_includes source, '$parts += "  this.String"'
    assert_includes source, '$parts += "const claudeEasySubjectSnapshots = [];"'
    assert_includes source, '$parts += "const claudeEasyGlobalSnapshots = [];"'
    assert_includes source, '$parts += "function claudeEasyRestoreIntrinsics() {"'
    assert_includes source, '$parts += "let claudeEasyPreviousMain = null;"'
    assert_includes source, '$parts += "const claudeEasyManagedMain = main;"'
    assert_includes source, '$parts += "return function (previousMain) {"'
    assert_includes source, '$parts += "  claudeEasyRestoreIntrinsics();"'
    assert_includes source, '$parts += "      } finally {"'
    assert_includes source, '$parts += "        claudeEasyRestoreIntrinsics();"'
    assert_includes source, '$parts += "        return claudeEasyApplyFunction(previousMain, undefined, [config, profileName]);"'
    assert_includes source, %q!$parts += '  claudeEasyDefineProperty(claudeEasyRealGlobal, "main", {'!
    assert_includes source, '$parts += "    get: function () { return claudeEasyManagedMain; },"'
    assert_includes source, '$parts += "    set: function () {},"'
    assert_includes source, '$parts += "    configurable: false"'
    assert_includes source, 'if (-not [string]::IsNullOrWhiteSpace($previous)) { $parts += $previous.Trim() }'
    assert_includes source,
                    %q!$parts += 'claudeEasyInstallManagedMain(typeof claudeEasyPreviousMain === "function" ? claudeEasyPreviousMain : null);'!
    assert_includes source, '$parts += "claudeEasyInstallManagedMain = null;"'
    refute_includes source, "loadPrevious"
    refute_includes source, "new Proxy"

    setup_index = source.index('$parts += "let claudeEasyInstallManagedMain = (function ("')
    original_begin_index = source.index("$parts += $originalBegin")
    original_end_index = source.index("$parts += $originalEnd")
    finalizer_index = source.index(
      %q!$parts += 'claudeEasyInstallManagedMain(typeof claudeEasyPreviousMain === "function" ? claudeEasyPreviousMain : null);'!
    )
    null_index = source.index('$parts += "claudeEasyInstallManagedMain = null;"')
    assert_operator setup_index, :<, original_begin_index
    assert_operator original_begin_index, :<, original_end_index
    assert_operator original_end_index, :<, finalizer_index
    assert_operator finalizer_index, :<, null_index

    assert_includes source, '// CLAUDEEASY ORIGINAL BEGIN'
    assert_includes source, '// CLAUDEEASY ORIGINAL END'
    assert_includes uninstaller, '$_.Kind -eq "original-begin"'
    assert_includes uninstaller, '$_.Kind -eq "original-end"'
  end

  def test_windows_backups_are_published_only_after_complete_private_write
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    ).force_encoding("UTF-8")
    backup = source[/function Backup-Versioned\b.*?(?=^function |\z)/m]

    refute_nil backup
    assert_includes backup, '".claude-easy-backup-"'
    assert_includes backup, '$backupStream.Flush($true)'
    assert_includes backup, 'Protect-BackupAcl $temporary'
    assert_includes backup, '[System.IO.File]::Move($temporary, $destination)'
    assert_operator backup.index('$backupStream.Flush($true)'), :<,
                    backup.index('[System.IO.File]::Move($temporary, $destination)')
    assert_operator backup.index('Protect-BackupAcl $temporary'), :<,
                    backup.index('[System.IO.File]::Move($temporary, $destination)')
  end

  def test_windows_default_app_home_rejects_multiple_existing_candidates
    transaction = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    ).force_encoding("UTF-8")
    installer = File.binread(File.join(SKILL, "scripts/install_windows.ps1")).force_encoding("UTF-8")
    uninstaller = File.binread(File.join(SKILL, "scripts/uninstall_windows.ps1")).force_encoding("UTF-8")

    assert_includes transaction, "function Resolve-ClashVergeAppHome"
    assert_includes transaction, "Clash Verge Rev 配置目录不唯一"
    assert_includes transaction, 'if ($existing.Count -gt 1)'
    assert_equal 1, installer.scan("Resolve-ClashVergeAppHome").length
    assert_equal 1, uninstaller.scan("Resolve-ClashVergeAppHome").length
    refute_includes installer, '$candidates | Where-Object'
    refute_includes uninstaller, '$candidates | Where-Object'
  end

  def test_macos_production_probe_runner_executes_all_cases_and_propagates_any_failure
    runner = File.join(ROOT, "tests/run_macos_production_probes.rb")
    assert File.file?(runner), "macOS production probes need one behaviorally testable CI runner"

    Dir.mktmpdir("claude-easy-probe-runner-") do |directory|
      current_ruby = File.join(directory, "current-ruby")
      system_ruby = File.join(directory, "system-ruby")
      counter = File.join(directory, "counter")
      log = File.join(directory, "calls")
      fake_ruby_source = <<~RUBY
        #!#{RbConfig.ruby}
        statuses = ENV.fetch("CLAUDE_EASY_FAKE_PROBE_STATUSES").split(",").map(&:to_i)
        counter_path = ENV.fetch("CLAUDE_EASY_FAKE_PROBE_COUNTER")
        call_index = File.file?(counter_path) ? File.read(counter_path).to_i : 0
        File.write(counter_path, (call_index + 1).to_s)
        File.open(ENV.fetch("CLAUDE_EASY_FAKE_PROBE_LOG"), "a") do |file|
          file.puts(([File.basename($PROGRAM_NAME), ENV["CLAUDE_EASY_RUN_PRODUCTION_PROBES"]] + ARGV).join("|"))
        end
        exit statuses.fetch(call_index, 99)
      RUBY
      [current_ruby, system_ruby].each do |path|
        File.write(path, fake_ruby_source)
        FileUtils.chmod(0o700, path)
      end
      expected_calls = [
        "current-ruby|1|tests/test_macos_patcher.rb|--name|/production_probe/",
        "current-ruby|1|tests/test_macos_wrappers.rb|--name|/production_probe/",
        "system-ruby|1|tests/test_macos_patcher.rb|--name|/production_probe/",
        "system-ruby|1|tests/test_macos_wrappers.rb|--name|/production_probe/"
      ]

      4.times do |failed_index|
        statuses = Array.new(4, 0)
        statuses[failed_index] = 7
        FileUtils.rm_f([counter, log])
        _output, _error, status = Open3.capture3(
          {
            "CLAUDE_EASY_CURRENT_RUBY" => current_ruby,
            "CLAUDE_EASY_SYSTEM_RUBY" => system_ruby,
            "CLAUDE_EASY_FAKE_PROBE_STATUSES" => statuses.join(","),
            "CLAUDE_EASY_FAKE_PROBE_COUNTER" => counter,
            "CLAUDE_EASY_FAKE_PROBE_LOG" => log
          },
          RbConfig.ruby, runner, chdir: ROOT
        )
        refute status.success?, "probe runner ignored failure at command #{failed_index + 1}"
        calls = File.readlines(log, chomp: true)
        assert_equal expected_calls, calls,
                     "probe runner did not execute every suite on both supported Rubies"
      end

      FileUtils.rm_f([counter, log])
      _output, _error, status = Open3.capture3(
        {
          "CLAUDE_EASY_CURRENT_RUBY" => current_ruby,
          "CLAUDE_EASY_SYSTEM_RUBY" => system_ruby,
          "CLAUDE_EASY_FAKE_PROBE_STATUSES" => "0,0,0,0",
          "CLAUDE_EASY_FAKE_PROBE_COUNTER" => counter,
          "CLAUDE_EASY_FAKE_PROBE_LOG" => log
        },
        RbConfig.ruby, runner, chdir: ROOT
      )
      assert status.success?, "probe runner rejected four successful probe suites"
      assert_equal expected_calls, File.readlines(log, chomp: true)
    end
  end

  def test_every_test_entrypoint_is_wired_into_ci
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    entrypoints = Dir[File.join(ROOT, "tests/test_*.{rb,js,ps1}")].sort

    refute_empty entrypoints
    entrypoints.each do |path|
      assert_includes workflow, File.basename(path), "test entrypoint is not executed by CI: #{path}"
    end
  end

  def test_region_fingerprint_page_runs_on_macos_and_both_windows_runtimes
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    jobs = workflow.scan(
      /^  ([a-z0-9-]+):\n(.*?)(?=^  [a-z0-9-]+:\n|\z)/m
    ).to_h
    command = "node --test tests/test_region_fingerprint_page.js"

    %w[
      macos
      windows-installer-powershell-5
      windows-installer-powershell-7
    ].each do |job|
      assert jobs.key?(job), "missing CI job: #{job}"
      assert_includes jobs.fetch(job), command,
                      "offline fingerprint page is not tested in #{job}"
    end
  end

  def test_every_local_test_entrypoint_is_in_the_precommit_release_list
    instructions = File.read(File.join(ROOT, "AGENTS.md"))
    local_entrypoints = Dir[File.join(ROOT, "tests/test_*.{rb,js}")].sort

    refute_empty local_entrypoints
    local_entrypoints.each do |path|
      assert_includes instructions, File.basename(path), "local test entrypoint is missing from AGENTS.md: #{path}"
    end
  end

  def test_all_public_commands_expose_the_versioned_result_contract
    contract = JSON.parse(File.read(File.join(SKILL, "references/result-contract.json")))
    assert_equal "claude-easy.result", contract.fetch("schema")
    assert_equal 1, contract.fetch("version")
    assert_equal %w[
      schema version command platform client operation ok status code exit_code summary_zh
      profile changes checks items messages warnings
    ], contract.fetch("required_fields")
    assert_equal %w[install uninstall patch verify_routes], contract.fetch("commands")
    assert_equal ["integer", "null"], contract.fetch("field_types").fetch("profile")
    %w[changes checks items messages warnings].each do |field|
      assert_equal "array", contract.fetch("field_types").fetch(field)
    end

    mac_paths = %w[
      scripts/install_macos.sh scripts/uninstall_macos.sh
      scripts/macos/patch_profiles.rb scripts/macos/verify_routes.rb
    ]
    windows_paths = %w[
      scripts/install_windows.ps1 scripts/uninstall_windows.ps1 scripts/windows/verify_routes.ps1
    ]
    mac_paths.each do |path|
      source = path == "scripts/macos/patch_profiles.rb" ? mac_patcher_source : File.read(File.join(SKILL, path))
      assert_includes source, "--json", path
    end
    windows_paths.each { |path| assert_includes File.read(File.join(SKILL, path)), "Json", path }

    ruby_contract = File.read(File.join(SKILL, "scripts/macos/result_contract.rb"))
    powershell_contract = File.read(File.join(SKILL, "scripts/windows/result_contract.ps1"))
    assert_includes ruby_contract, 'SCHEMA = "claude-easy.result"'
    assert_includes ruby_contract, "VERSION = 1"
    assert_includes ruby_contract, "COMMANDS = %w[install uninstall patch verify_routes]"
    assert_includes powershell_contract, '$script:ClaudeEasyResultSchema = "claude-easy.result"'
    assert_includes powershell_contract, '$script:ClaudeEasyResultVersion = 1'
    assert_includes powershell_contract, '$script:ClaudeEasyResultCommands = @("install", "uninstall", "patch", "verify_routes")'
  end

  def test_production_coverage_cannot_be_inflated_with_ignore_markers
    production = Dir.glob(File.join(SKILL, "scripts/**/*.{rb,js,ps1,sh,cmd}"))
    markers = [":nocov:", "c8 ignore", "istanbul ignore", "coverage:ignore", "node:coverage"]
    offenders = production.each_with_object([]) do |path, found|
      text = File.read(path).downcase
      markers.each { |marker| found << "#{path}: #{marker}" if text.include?(marker) }
    end

    assert_empty offenders, "production coverage exclusions are forbidden: #{offenders.join(', ')}"
  end

  def test_license_is_mit
    source = File.read(File.join(ROOT, "LICENSE"))
    assert_includes source, "MIT License"
    assert_includes source, "wallmage"
  end

  def test_uninstallers_preserve_backups
    mac = File.read(File.join(SKILL, "scripts/uninstall_macos.sh"))
    windows = File.read(File.join(SKILL, "scripts/uninstall_windows.ps1"))
    assert_includes windows, "CLAUDEEASY POLICY BEGIN"
    refute_match(/Remove-Item[^\n]+backups/i, windows)
    refute_match(%r{/bin/rm[^\n]+backups}i, mac)
  end
end
