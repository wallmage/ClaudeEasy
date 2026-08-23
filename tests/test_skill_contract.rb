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

  POLICY_REFERENCE_FILES = %w[
    claude-easy/references/policy-core.md
    claude-easy/references/diagnostics.md
    claude-easy/references/profiles-and-patch.md
    claude-easy/references/routing-and-security.md
    claude-easy/references/safe-update-and-recovery.md
    claude-easy/references/macos.md
    claude-easy/references/windows.md
  ].freeze

  REQUIRED_PUBLIC_FILES = (POLICY_REFERENCE_FILES + %w[
    README.md
    claude-easy/SKILL.md
    claude-easy/agents/openai.yaml
    claude-easy/assets/claude-region-check.html
    claude-easy/references/policy.json
    claude-easy/references/result-contract.json
    claude-easy/scripts/install_macos.sh
    claude-easy/scripts/install_windows.ps1
    claude-easy/scripts/install_windows.cmd
    claude-easy/scripts/uninstall_macos.sh
    claude-easy/scripts/uninstall_windows.ps1
    claude-easy/scripts/uninstall_windows.cmd
    claude-easy/scripts/macos/operation_lock.rb
    claude-easy/scripts/macos/usage_profile_state.rb
    claude-easy/scripts/macos/patch_profiles.rb
    claude-easy/scripts/macos/patch_profiles/transform.rb
    claude-easy/scripts/macos/patch_profiles/backups.rb
    claude-easy/scripts/macos/patch_profiles/mihomo.rb
    claude-easy/scripts/macos/patch_profiles/profile_writer.rb
    claude-easy/scripts/macos/patch_profiles/subscriptions.rb
    claude-easy/scripts/macos/patch_profiles/runtime.rb
    claude-easy/scripts/macos/patch_profiles/client_switches.rb
    claude-easy/scripts/macos/patch_profiles/log_repair.rb
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
    claude-easy/scripts/windows/install_windows/runtime.ps1
    claude-easy/scripts/windows/install_windows/safe_update.ps1
    LICENSE
  ]).freeze

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

  def policy_reference_paths
    POLICY_REFERENCE_FILES.map { |path| File.join(ROOT, path) }
  end

  def policy_document
    policy_reference_paths.map { |path| File.read(path) }.join("\n")
  end

  def test_all_distribution_files_exist
    missing = REQUIRED_PUBLIC_FILES.reject { |path| File.file?(File.join(ROOT, path)) }
    assert_empty missing, "missing public files: #{missing.join(', ')}"
  end

  def test_release_archive_includes_every_windows_installer_module
    modules = Dir[File.join(SKILL, "scripts/windows/install_windows/*.ps1")].map do |path|
      path.delete_prefix("#{ROOT}/")
    end

    assert_empty modules - REQUIRED_PUBLIC_FILES
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
        write_supported_clashx_app(release_home)
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
        connectivity_server, connectivity_thread, connectivity_ca, mixed_port =
          start_release_connectivity_server(release_home)
        controller_server, controller_thread, controller_socket_path, controller_requests =
          start_release_controller(release_home, mixed_port: mixed_port)
        release_env = {
          "HOME" => release_home,
          "RUBYOPT" => "-r#{preferences_fixture}",
          "CLAUDE_EASY_PROFILE_DIR" => profile_directory,
          "CLAUDE_EASY_USAGE_STATE_PATH" => nil,
          "CLAUDE_EASY_USAGE_PROFILE" => nil,
          "CURL_CA_BUNDLE" => connectivity_ca
        }
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

  def test_all_profiles_share_one_managed_china_domain_baseline
    policy = JSON.parse(File.read(File.join(SKILL, "references/policy.json")))
    mac_patcher = mac_patcher_source
    windows_patcher = File.read(File.join(SKILL, "scripts/windows/clash_verge_global.js"))

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

  def test_patch_runtime_route_verifiers_exist_on_both_platforms
    mac_verifier = File.read(File.join(SKILL, "scripts/macos/verify_routes.rb"))
    windows_verifier = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))
    policy = policy_document

    [mac_verifier, windows_verifier].each do |source|
      assert_includes source, "ChatGPT"
      assert_includes source, "Gemini"
      assert_includes source, "Grok"
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
  end

  def test_windows_route_verifier_uses_live_match_for_main_group
    source = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))

    assert_includes source, '$main = Get-LiveMainGroup $proxies'
    refute_match(/\$main\s*=\s*Find-Group\s+\$proxies\s+@\(\$policy\.main_group_names\)/, source)
  end

  def test_windows_route_verifier_uses_supported_main_group_types
    source = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))
    get_live = source[/function Get-LiveMainGroup\b.*?(?=^function |\z)/m]

    refute_nil get_live
    assert_includes get_live, "Test-SupportedRouteGroupType"
    refute_includes get_live, '-eq "Selector"'
  end

  def test_claude_and_anthropic_are_never_opened_or_tested
    [
      File.read(File.join(SKILL, "scripts/macos/verify_routes.rb")),
      File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))
    ].each do |source|
      refute_match %r{https://(?:www\.)?(?:claude\.ai|anthropic\.com)/}i, source
      assert_includes source, "https://chatgpt.com/"
      assert_includes source, "https://gemini.google.com/"
      assert_includes source, "https://grok.com/"
    end
  end

  def test_windows_route_verifier_rejects_nonempty_secret_argument
    source = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))

    assert_includes source, 'if (-not [string]::IsNullOrEmpty($Secret)) {'
    assert_includes source, '不能通过 -Secret 传入非空控制器密钥'
    refute_includes source, '"Bearer $Secret"'
  end

  def test_windows_route_verifier_blocks_controller_redirects
    source = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))

    assert_includes source, '$request.AllowAutoRedirect = $false'
  end

  def test_windows_route_verifier_bypasses_system_proxy_for_controller
    source = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))

    assert_includes source, '$request.Proxy = $null'
  end

  def test_configuration_history_is_versioned_compared_and_safely_restored
    mac_patcher = mac_patcher_source
    windows_installer = windows_installer_source

    assert_includes mac_patcher, "--snapshot-initial"
    assert_includes mac_patcher, "--list-backups"
    assert_includes mac_patcher, "--compare-backup"
    assert_includes mac_patcher, "--restore-backup"
    assert_includes windows_installer, "ListBackups"
    assert_includes windows_installer, "CompareBackup"
    assert_includes windows_installer, "RestoreBackup"
    assert_includes windows_installer, "claude-easy-backups"
    assert_includes windows_installer, "yyyy-MM-dd_HH-mm-ss"
    assert_includes windows_installer, "changed_fields"
    %w[id same backup_sha256 current_sha256].each do |field|
      assert_match(/^\s+#{field} = /, windows_installer)
    end

    Dir.mktmpdir do |directory|
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, File.join(SKILL, "scripts/macos/patch_profiles.rb"),
        "--list-backups", "--backup-dir", File.join(directory, "backups"), "--json"
      )
      assert status.success?, stderr
      assert_empty stderr
      assert_equal "no_backups", JSON.parse(stdout).fetch("code")
    end
    assert_includes windows_installer, '@($changedFields) @() @($comparison)'
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
  end

  def test_windows_policy_is_generated_from_canonical_json
    generator = File.join(ROOT, "tests/generate_windows_policy.rb")
    assert system(RbConfig.ruby, generator, "--check"), "Windows policy block is stale"
  end

  def test_udp_policy_uses_only_deterministic_destination_matches
    machine_policy = JSON.parse(File.read(File.join(SKILL, "references/policy.json")))
    assert_equal "AND,((NETWORK,UDP),(RULE-SET,{CN_IP})),DIRECT", machine_policy.fetch("cn_udp_direct_rule")
  end

  def test_policy_documents_dns_filters_and_safety_migrations
    policy = policy_document
    %w[exclude-filter empty-fallback skip-cert-verify ecs legacy_ai_rules forbidden_ai_domains proxy-server-nameserver system 二次转换].each do |term|
      assert_includes policy, term
    end
    assert_includes policy, "保留 Fake-IP 映射"
    refute_includes policy, "/cache/fakeip/flush"
    assert_includes policy, "/cache/dns/flush"
  end

  def test_macos_installer_avoids_fakeip_flush_and_curl
    path = File.join(SKILL, "scripts/install_macos.sh")
    skip unless File.file?(path)

    source = File.read(path)
    refute_includes source, "/cache/fakeip/flush"
    refute_includes source, "/usr/bin/curl"
  end

  def test_macos_installer_is_one_shot
    path = File.join(SKILL, "scripts/install_macos.sh")
    skip unless File.file?(path)

    source = File.read(path)
    refute_match(/osascript[^\n]*(?:ClashX Meta|quit|terminate|open -a)/i, source)
    refute_match(/\bopen\s+-a\s+["']?ClashX Meta/i, source)
    refute_match(/LaunchServices.*ClashX Meta/i, source)
  end

  def test_p1_recovery_and_refresh_guards_are_documented_and_exercised
    readme = File.read(File.join(ROOT, "README.md"))
    skill_document = File.read(File.join(SKILL, "SKILL.md"))
    patch_policy = policy_document
    windows_installer = File.read(File.join(SKILL, "scripts/install_windows.ps1"))
    windows_safe_update = File.read(
      File.join(SKILL, "scripts/windows/install_windows/safe_update.ps1")
    )
    windows_tests = File.binread(
      File.join(ROOT, "tests/test_windows_installer.ps1")
    ).force_encoding("UTF-8")

    refute_includes readme, "两个平台都必须让 Clash 保持运行"
    refute_includes readme, "已更新，尚未生效"
    assert_includes readme, "Windows 安装只在客户端本来就未运行时执行写入"
    assert_includes readme, "运行中可以创建安全更新备份和验收清单"
    assert_includes readme, "其余受保护客户端配置写入会整批延期"
    assert_includes readme, "修改整批延期且不得报告“已更新”"
    refute_includes skill_document, "两个平台都保持 Clash 运行"
    assert_includes skill_document, "普通安装、卸载和单文件备份恢复只有客户端本来就未运行时"
    assert_includes skill_document, "客户端运行时可以创建安全更新备份和验收清单"
    assert_includes skill_document, "安全更新失败恢复是唯一允许修改订阅的受控例外"
    refute_includes patch_policy, "安装器可以更新全局脚本"
    assert_includes patch_policy, "安装器整批延期"

    assert_includes windows_installer, 'BeforeUpdated = [string]$profile.Updated'
    assert_includes windows_installer, "Version = 4"
    assert_includes windows_installer, "Runtime = $runtimeSnapshot"
    assert_includes windows_installer,
                    "Invoke-ClashVergeReactivationShortcut $reactivationShortcut"
    assert_includes windows_installer, "Wait-ClashVergeRuntimeHealthy"
    assert_includes windows_installer, "safe_update_rolled_back"
    refute_includes windows_installer, "Test-SafeUpdateRefreshEvidence"
    refute_includes windows_installer, '"safe_update_refresh_pending"'
    refute_includes windows_safe_update, "UseUpdatedEvidence"
    assert_includes windows_installer, '[switch]$RefreshConfirmed'
    assert_includes windows_installer, '"missing_refresh_confirmation"'
    assert_includes windows_installer,
                    '[pscustomobject]@{ Path = $profilesIndexPath; Snapshot = $indexSnapshot; Label = "远程订阅清单" }'
    assert_includes windows_installer,
                    '[pscustomobject]@{ Path = $targetScript; Snapshot = $scriptSnapshot; Label = "全局扩展脚本" }'
    version_guard_function = windows_safe_update[
      windows_safe_update.index("function Open-SafeUpdateVersionGuard")...
      windows_safe_update.index("function New-SafeUpdateSnapshotContext")
    ]
    refute_nil version_guard_function
    assert_includes version_guard_function,
                    '[ClaudeEasy.VerifiedDeleteNative]::OpenSharedRead($Path)'
    assert_includes version_guard_function,
                    "[ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint"
    assert_includes version_guard_function,
                    "[ClaudeEasy.VerifiedDeleteNative]::GetLinkCount"
    snapshot_function = windows_safe_update[
      windows_safe_update.index("function New-SafeUpdateSnapshotContext")...
      windows_safe_update.index("function Get-SafeUpdateRecoveryItems")
    ]
    refute_nil snapshot_function
    refute_includes snapshot_function, 'Assert-ClaudeEasyProxyGroupCollection'
    refute_includes snapshot_function, 'Test-GeneratedYaml'
    refute_includes snapshot_function, 'Test-MihomoCandidate'
    assert_includes snapshot_function, 'SnapshotBytes = $profileBytes'
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
      '$manifest = [ordered]@{'
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
    assert_includes windows_tests,
                    "explicit UI refresh confirmation rejected unchanged valid subscriptions"
    assert_includes windows_tests,
                    "safe update verification accepted a missing UI refresh confirmation"
    assert_includes windows_tests,
                    "Windows ran subscription validation before creating the update snapshot"
    assert_includes windows_tests,
                    "legacy safe-update manifest auto-restored an untrusted backup"
    assert_includes windows_tests,
                    "unchanged valid legacy snapshot with missing or corrupted backups remained permanently pending"
    assert_includes windows_tests,
                    "legacy recovery without a runtime snapshot was reported as fully verified"
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
      readme,
      skill_document,
      patch_policy,
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents = [documents[2], documents[3]]
    documents.each do |document|
      assert_includes document, "already_disabled_owned"
      assert_includes document, "client_running_profile_three_deferred"
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

  def test_windows_uninstall_treats_file_and_usage_changes_as_protected
    uninstaller = File.binread(
      File.join(SKILL, "scripts/uninstall_windows.ps1")
    ).force_encoding("UTF-8")

    assert_includes uninstaller,
                    "$uninstallHasProtectedChanges = " \
                    "($filePlans.Count -gt 0 -or $null -ne $state -or " \
                    "$autoUpdateStateExists -or $usageStateExists)"
  end

  def test_windows_safe_update_verifies_passive_script_envelope_at_call_site
    source = File.read(
      File.join(SKILL, "scripts/windows/install_windows/safe_update.ps1")
    )

    assert_includes source,
                    "Assert-ClaudeEasyScriptOutsideManagedBlockIsPassive $ScriptText"
    assert_includes source, "Get-JavaScriptAnalysis $outsidePrefix"
    assert_includes source, "Get-JavaScriptAnalysis $outsideSuffix"
  end

  def test_windows_safe_update_checks_outside_literals_at_call_site
    source = File.read(
      File.join(SKILL, "scripts/windows/install_windows/safe_update.ps1")
    )

    assert_includes source, '$outsidePrefixAnalysis.HasLiteral'
    assert_includes source, '$outsideSuffixAnalysis.HasLiteral'
  end

  def test_windows_script_composition_rejects_main_references_at_call_site
    source = File.read(
      File.join(SKILL, "scripts/windows/install_windows/script_js.ps1")
    )

    assert_includes source, "Assert-JavaScriptDoesNotReferenceMain $withoutDeclaration"
    assert_includes source, "不能在入口声明之外引用 main"
  end

  def test_windows_delete_recovery_publishes_with_atomic_move
    source = File.read(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    )
    invoke_start = source.index("function Invoke-InterruptedTransactionRecovery(")
    invoke_end = source.index(
      "function Assert-InterruptedTransactionRecovered(",
      invoke_start || 0
    )
    refute_nil invoke_start
    refute_nil invoke_end
    invocation = source[invoke_start...invoke_end]

    assert_includes invocation,
                    "[System.IO.File]::Move(\n" \
                    "                        $entry.Temporary.Path,\n" \
                    "                        $entry.Item.Action.Path\n" \
                    "                    )"
    refute_includes invocation, "[System.IO.File]::WriteAllBytes("
  end

  def test_windows_delete_recovery_preserves_delete_identity_predicate
    source = File.read(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    )

    assert_includes source,
                    '$differentIdentityIsRestoredOriginal = $action.Action -eq "write" -and'
    assert_includes source,
                    '$snapshot.Identity -cne $action.Identity -and' \
                    "\n            -not $differentIdentityIsRestoredOriginal -and"
    assert_includes source,
                    '($action.Action -ne "delete" -or ' \
                    '$currentHash -ne $originalHash)) {'
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
    staging = function_source.index("$stagingStream = New-PrivateFileStream $staging")
    refute_nil watcher
    refute_nil staging
    assert_operator watcher, :<, staging
  end

  def test_windows_safe_update_compares_managed_script_envelope
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/safe_update.ps1")
    ).force_encoding("UTF-8")
    compare_start = source.index("function Assert-ClaudeEasyManagedScriptCurrent(")
    compare_end = source.index("function Test-ClaudeEasyFlowSequenceHasItem(", compare_start)
    refute_nil compare_start
    refute_nil compare_end
    compare = source[compare_start...compare_end]

    assert_includes compare, "Get-ClaudeEasyManagedScriptEnvelope $ScriptText $UsageProfile"
    assert_includes compare, "Get-ClaudeEasyManagedScriptEnvelope $expectedScript $UsageProfile"
    refute_includes compare, "Get-ClaudeEasyManagedScriptBlock $ScriptText $UsageProfile"
  end

  def test_windows_managed_script_finally_restores_intrinsics
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/script_js.ps1")
    ).force_encoding("UTF-8")

    assert_includes source, '$parts += "        claudeEasyRestoreIntrinsics();"'
  end

  def test_windows_managed_script_installs_main_after_original_end_marker
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/script_js.ps1")
    ).force_encoding("UTF-8")

    original_end_index = source.index("$parts += $originalEnd")
    finalizer_index = source.index(
      %q!$parts += 'claudeEasyInstallManagedMain(typeof claudeEasyPreviousMain === "function" ? claudeEasyPreviousMain : null);'!
    )
    refute_nil original_end_index
    refute_nil finalizer_index
    assert_operator original_end_index, :<, finalizer_index
  end

  def test_windows_backup_publication_uses_atomic_move
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    ).force_encoding("UTF-8")
    backup = source[/function Backup-Versioned\b.*?(?=^function |\z)/m]

    refute_nil backup
    assert_includes backup, '[System.IO.File]::Move($temporary, $destination)'
    refute_includes backup, '[System.IO.File]::Copy('
  end

  def test_windows_safe_update_multiline_flow_includes_trailing_sections
    source = File.read(
      File.join(SKILL, "scripts/windows/install_windows/safe_update.ps1")
    )

    assert_includes source,
                    "$flowLines += @($lines[($groupsNode.Start + 1)..($lines.Count - 1)])"
    refute_includes source,
                    "$flowLines += @($lines[($groupsNode.Start + 1)..($groupsNode.End - 1)])"
  end

  def test_skill_and_scripts_never_stop_or_restart_clash
    mac_install = File.read(File.join(SKILL, "scripts/install_macos.sh"))
    windows_install = windows_installer_source
    windows_uninstall = File.binread(File.join(SKILL, "scripts/uninstall_windows.ps1")).force_encoding("UTF-8")

    [mac_install, windows_install, windows_uninstall].each do |source|
      refute_match(/osascript[^\n]*(?:quit|terminate)/i, source)
      refute_match(/Stop-Process|taskkill|killall/i, source)
      refute_includes source, "请先从托盘菜单完全退出"
      refute_includes source, "退出客户端，再"
    end
  end

  def test_diagnostics_never_launches_clash_client_as_an_inspection_probe
    production_scripts = Dir.glob(File.join(SKILL, "scripts/**/*.{rb,sh,ps1,cmd,js}"))
    offenders = production_scripts.select do |path|
      File.binread(path).force_encoding("UTF-8").scrub.match?(
        %r{/Applications/ClashX Meta\.app/Contents/MacOS/ClashX Meta}
      )
    end
    assert_empty offenders, "production script launches ClashX Meta as a probe: #{offenders.join(', ')}"
  end

  def test_ci_covers_production_runtimes_and_pins_actions
    workflow = File.read(File.join(ROOT, ".github/workflows/test.yml"))
    uses = workflow.scan(/^\s*- uses:\s*(\S+)/).flatten

    refute_empty uses
    uses.each { |entry| assert_match(/@[0-9a-f]{40}\z/, entry, entry) }
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
end
