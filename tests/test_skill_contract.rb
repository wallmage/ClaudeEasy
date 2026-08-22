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

  REQUIRED_PUBLIC_FILES = (
    Dir.glob(File.join(ROOT, "claude-easy/**/*"), File::FNM_EXTGLOB)
       .select { |path| File.file?(path) }
       .map { |path| path.delete_prefix("#{ROOT}/") } +
    %w[README.md LICENSE]
  ).sort.freeze

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
    assert_includes windows_verifier, "function Test-SupportedRouteGroupType"
    %w[Selector URLTest Fallback LoadBalance].each do |group_type|
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
    assert_includes mac_source, 'get_json(controller, "/rules")'
    assert_includes mac_source, 'rule["proxy"]'
    assert_includes mac_source, "main_group = live_main_group(requester, proxies, main_group)"
    assert_includes mac_source, 'ai_group = find_group(proxies, policy["ai_group_names"], ai_group, ai: true)'
    assert_includes windows_source, "function Get-LiveMainGroup"
    assert_includes windows_source, 'Invoke-ControllerJson "/rules"'
    assert_includes windows_source, '$rule.proxy'
    assert_includes windows_source, '$main = Get-LiveMainGroup $proxies'
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

  def test_windows_route_verifier_keeps_the_controller_secret_off_process_metadata
    source = File.read(File.join(SKILL, "scripts/windows/verify_routes.ps1"))
    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      policy_document,
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]

    assert_includes source, '[switch]$SecretStdin'
    assert_includes source, "function Read-ControllerSecretFromStandardInput"
    assert_includes source, '$inputReader.ReadToEnd()'
    assert_includes source, '不能通过 -Secret 传入非空控制器密钥'
    assert_includes source, 'if (-not [string]::IsNullOrEmpty($Secret)) {'
    assert_includes source, "function Get-ValidatedControllerBaseUri"
    assert_includes source, 'Test-StrictIpv4LoopbackHost $rawHost'
    assert_includes source, 'if (-not $rawHostIsLoopback)'
    assert_includes source, '$request.AllowAutoRedirect = $false'
    assert_includes source, '$request.Proxy = $null'
    assert_includes source, '$script:ClaudeEasyControllerSecret'
    refute_includes source, '"Bearer $Secret"'
    [documents[2], documents[3]].each do |document|
      assert_includes document, "-SecretStdin"
      assert_includes document, "本机回环"
      assert_includes document, "非空 `-Secret`"
    end
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
    Dir[File.join(SKILL, "scripts/**/*")].select { |path| File.file?(path) }.each do |path|
      refute_includes File.binread(path), "/cache/fakeip/flush", path
    end
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
    first_install_target = windows_installer.index('$usageProfileTarget = [pscustomobject]@{')
    refute_nil running_gate
    refute_nil first_install_target
    assert_operator running_gate, :<, first_install_target
    assert_includes windows_installer, '"client_running_profile_three_deferred"'
    assert_includes windows_installer, '"client_running_auto_update_deferred"'
    refute_includes windows_installer, "installed_running_client"
    assert_includes windows_tests, 'Get-TreeContentSnapshot $runningCase'
    assert_includes windows_tests, "client_running_profile_three_deferred"
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

    assert_includes windows_profiles, 'Updated = $updatedValue'
    assert_includes windows_profiles,
                    "$updatedRawValue -match '^(?:~|null|Null|NULL)$'"
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
    assert_includes windows_safe_update,
                    'CanAutoRestore = ($manifestVersion -ge 2)'
    assert_includes windows_safe_update,
                    'if ($manifestVersion -ge 2 -and ('
    assert_includes windows_installer,
                    '@($recoveryItems | Where-Object { -not $_.CanAutoRestore }).Count -gt 0'
    assert_includes windows_installer, '"safe_update_legacy_recovery_pending"'
    assert_includes windows_installer, '"safe_update_legacy_snapshot_required"'
    assert_includes windows_installer, "重新创建 v4 快照"
    refute_includes windows_installer, "重新创建 v3 快照"
    assert_includes windows_installer, '$safeUpdateContentRestoreEligible = $false'
    assert_includes windows_installer, 'if (-not $safeUpdateContentRestoreEligible) {'
    assert_includes windows_installer, '"safe_update_verification_retry_pending"'
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

  def test_windows_failed_safe_update_rollback_publishes_runtime_recovery_in_the_same_transaction
    installer = File.read(File.join(SKILL, "scripts/install_windows.ps1"))
    safe_update = File.read(
      File.join(SKILL, "scripts/windows/install_windows/safe_update.ps1")
    )

    assert_includes safe_update, "Invoke-VerifiedWriteDeleteTransaction (@($targets) + @($manifestTarget)) @()"
    assert_includes safe_update, "ManifestPath"
    assert_includes safe_update, "ManifestSnapshot"
    assert_includes safe_update, "-NotePropertyValue $RuntimeRecoveryBytes"
    assert_includes installer, 'Kind = "safe_update_runtime_recovery"'
    restore_call = installer.index("$restoreResult = Restore-SafeUpdateFiles")
    runtime_record = installer.index("$runtimeRecoveryBytes = ConvertTo-Utf8Bytes")
    refute_nil restore_call
    refute_nil runtime_record
    assert_operator runtime_record, :<, restore_call
    restore_block = installer[restore_call, 300]
    assert_includes restore_block, "$safeUpdateStatePath"
    assert_includes restore_block, "$manifestSnapshot $runtimeRecoveryBytes"
    assert_operator installer.scan("Remove-VerifiedOwnedFile $safeUpdateStatePath").length, :>=, 3
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

  def test_windows_interrupted_client_sensitive_recovery_waits_for_the_client
    transaction = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    ).force_encoding("UTF-8")
    installer = File.binread(
      File.join(SKILL, "scripts/install_windows.ps1")
    ).force_encoding("UTF-8")
    uninstaller = File.binread(
      File.join(SKILL, "scripts/uninstall_windows.ps1")
    ).force_encoding("UTF-8")
    safe_update = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/safe_update.ps1")
    ).force_encoding("UTF-8")
    windows_tests = File.binread(
      File.join(ROOT, "tests/test_windows_installer.ps1")
    ).force_encoding("UTF-8")

    assert_includes transaction,
                    "function Test-InterruptedRecoveryRequiresStoppedClient("
    assert_includes transaction, '"client_stopped"'
    assert_includes transaction, '"safe_update_running_client"'
    assert_includes transaction, "RecoveryPolicy = $InterruptedRecoveryPolicy"
    assert_includes transaction, "function Get-InterruptedRecoveryPolicy("
    assert_includes transaction,
                    'if ([long]$Record.Version -eq 1) { return "client_stopped" }'
    assert_includes transaction,
                    '$InterruptedRecoveryPolicy = "client_stopped"'
    assert_includes safe_update,
                    '-InterruptedRecoveryPolicy "safe_update_running_client"'
    assert_equal 6, installer.scan('"safe_update_running_client"').length
    assert_includes transaction,
                    "function Test-SafeUpdateRunningRecoveryTargets("
    assert_includes transaction, '"claude-easy-safe-update.json"'
    assert_includes transaction, '@(".yaml", ".yml")'
    assert_includes transaction,
                    "function Test-InterruptedRecoveryCommitCondition("
    assert_includes transaction,
                    "$recovered = Invoke-InterruptedTransactionRecovery `\n" \
                    "        $plan `\n        $preCommitCondition `\n" \
                    "        $finalizeCondition"
    assert_includes transaction,
                    "Test-InterruptedRecoveryCommitCondition $preCommitCondition"
    assert_includes transaction,
                    'throw "客户端保持运行；中断的客户端敏感事务等待恢复。"'

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
    journal_finalize = journal_body.index('$finalizeResults = @(& $FinalizeCondition)')
    journal_rollback = journal_body.index('Undo-InterruptedTransactionRecovery $opened')
    refute_nil journal_identity
    refute_nil journal_condition
    refute_nil journal_write
    refute_nil journal_delete
    refute_nil journal_finalize
    refute_nil journal_rollback
    assert_operator journal_identity, :<, journal_condition
    assert_operator journal_condition, :<, journal_write
    assert_operator journal_condition, :<, journal_delete
    assert_operator journal_write, :<, journal_finalize
    assert_operator journal_delete, :<, journal_finalize
    assert_operator journal_finalize, :<, journal_rollback
    assert_equal 2, journal_body.scan('Undo-InterruptedTransactionRecovery $opened').length

    undo_start = transaction.index("function Undo-InterruptedTransactionRecovery(")
    undo_end = transaction.index("\nfunction Invoke-InterruptedTransactionRecovery(", undo_start)
    refute_nil undo_start
    refute_nil undo_end
    undo_body = transaction[undo_start...undo_end]
    assert_includes undo_body, 'Set-VerifiedDeleteDisposition $entry.Stream $false'
    assert_includes undo_body, '$entry.Current `'
    assert_includes undo_body, 'Set-VerifiedDeleteDisposition $entry.Stream $true'

    recovery_start = transaction.index("function Repair-InterruptedFileTransaction")
    recovery_end = transaction.index("\nfunction Invoke-VerifiedPathTransaction", recovery_start)
    refute_nil recovery_start
    refute_nil recovery_end
    recovery_body = transaction[recovery_start...recovery_end]
    final_condition = recovery_body.index('$finalizeCondition = {')
    final_recheck = recovery_body.index(
      "Test-InterruptedRecoveryCommitCondition $preCommitCondition",
      final_condition
    )
    final_journal_delete = recovery_body.index(
      "Remove-FileTransactionJournal $snapshot.Bytes",
      final_condition
    )
    recovery_call = recovery_body.index("Invoke-InterruptedTransactionRecovery `")
    refute_nil final_condition
    refute_nil final_recheck
    refute_nil final_journal_delete
    refute_nil recovery_call
    assert_operator final_condition, :<, final_recheck
    assert_operator final_recheck, :<, final_journal_delete
    assert_operator final_journal_delete, :<, recovery_call

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
    preparation_final_condition = preparation_body.index(
      "Test-InterruptedRecoveryCommitCondition $preCommitCondition",
      preparation_condition + 1
    )
    preparation_cancel_delete = preparation_body.index(
      "Set-VerifiedDeleteDisposition $entry.Stream $false",
      preparation_final_condition
    )
    refute_nil preparation_identity
    refute_nil preparation_condition
    refute_nil preparation_delete
    refute_nil preparation_final_condition
    refute_nil preparation_cancel_delete
    assert_operator preparation_identity, :<, preparation_condition
    assert_operator preparation_condition, :<, preparation_delete
    assert_operator preparation_delete, :<, preparation_final_condition
    assert_operator preparation_final_condition, :<, preparation_cancel_delete

    [installer, uninstaller].each do |entrypoint|
      assert_includes entrypoint, '"transaction_recovery_pending"'
    end
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
    assert_includes windows_tests,
                    "running client changed an interrupted profiles.yaml target"
    assert_includes windows_tests,
                    "running client consumed an interrupted client-sensitive journal"
    assert_includes windows_tests,
                    "running client changed an interrupted usage-profile state"
    assert_includes windows_tests,
                    "running client changed an interrupted remote-profile restore target"
    assert_includes windows_tests,
                    "running client consumed an interrupted remote-profile restore journal"
    assert_includes windows_tests,
                    "ordinary remote-profile restore did not persist its stopped-client recovery policy"

    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      policy_document,
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents = [documents[2], documents[3]]
    documents.each do |document|
      assert_includes document, "中断的客户端敏感事务"
      assert_includes document, "transaction_recovery_pending"
      assert_includes document, "锁定并核对全部恢复目标"
      assert_includes document, "再次检查"
      assert_includes document, "恢复权限"
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
      "$journalBytes = Write-FileTransactionJournal " \
      "$opened $InterruptedRecoveryPolicy"
    )
    refute_nil identity_check
    refute_nil precommit_check
    refute_nil journal_write
    assert_operator identity_check, :<, precommit_check
    assert_operator precommit_check, :<, journal_write

    assert_includes transaction, "[scriptblock]$PreCommitCondition = $null"
    assert_includes transaction,
                    "Invoke-VerifiedPathTransaction $WriteTargets " \
                    "$DeleteTargets $PreCommitCondition $InterruptedRecoveryPolicy"
    assert_includes transaction, "elseif ($mutationStarted)"
    assert_includes uninstaller, "$transactionCommitted = Invoke-VerifiedWriteDeleteTransaction"
    assert_includes uninstaller,
                    "$writeTargets $deletePlans $clientStoppedPreCommit"
    assert_includes uninstaller,
                    "if ($null -ne $clientStoppedPreCommit -and -not $transactionCommitted)"
    assert_includes uninstaller,
                    "$uninstallHasProtectedChanges = " \
                    "($filePlans.Count -gt 0 -or $null -ne $state -or " \
                    "$autoUpdateStateExists -or $usageStateExists)"
    assert_includes uninstaller,
                    "if ($uninstallHasProtectedChanges -and (Test-ClashVergeRunning))"
    assert_includes uninstaller,
                    "if ($uninstallHasProtectedChanges) {\n" \
                    "        $clientStoppedPreCommit = {\n" \
                    "            return (-not (Test-ClashVergeRunning))"
    assert_includes windows_tests,
                    "client-start race changed a protected uninstall target"
    assert_includes windows_tests,
                    "client-start abort rewrote an existing transaction target"
    assert_includes windows_tests,
                    "running profile 1 uninstall changed a protected target"

    documents = [
      File.read(File.join(ROOT, "README.md")),
      File.read(File.join(SKILL, "SKILL.md")),
      policy_document,
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents = [documents[2], documents[3]]
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
                    "    [scriptblock]$PreCommitCondition = $null,\n" \
                    "    [string]$InterruptedRecoveryPolicy = \"client_stopped\"\n" \
                    ")"
    assert_includes transaction,
                    "Invoke-VerifiedPathTransaction $Targets @() " \
                    "$PreCommitCondition $InterruptedRecoveryPolicy"
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
      policy_document,
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents = [documents[2], documents[3]]
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
      policy_document,
      File.read(File.join(ROOT, "tests/baseline.md"))
    ]
    documents = [documents[2], documents[3]]
    documents.each do |document|
      assert_includes document, "尚未验收"
      assert_includes document, "safe_update_pending"
    end
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
    publish = function_source.index("[System.IO.File]::Move($staging, $temporary)")
    refute_nil watcher
    refute_nil staging
    refute_nil publish
    assert_operator watcher, :<, staging,
                    "sensitive staging bytes must not exist before caller-death cleanup is armed"
    assert_operator staging, :<, publish
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

  def test_windows_backups_are_private_before_the_first_byte_is_written
    source = File.binread(
      File.join(SKILL, "scripts/windows/install_windows/transaction.ps1")
    ).force_encoding("UTF-8")
    backup = source[/function Backup-Versioned\b.*?(?=^function |\z)/m]

    refute_nil backup
    assert_includes backup, '".claude-easy-backup-"'
    assert_includes backup, '$backupStream = New-PrivateFileStream $temporary'
    assert_includes backup, '$backupStream.Flush($true)'
    assert_includes backup, '[System.IO.File]::Move($temporary, $destination)'
    assert_operator backup.index('$backupStream = New-PrivateFileStream $temporary'), :<,
                    backup.index('$backupStream.Write(')
    assert_operator backup.index('$backupStream.Flush($true)'), :<,
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
    assert_equal 1, installer.scan(/Resolve-ClashVergeAppHome\s*$/).length
    assert_equal 1, uninstaller.scan(/Resolve-ClashVergeAppHome\s*$/).length
    refute_includes installer, '$candidates | Where-Object'
    refute_includes uninstaller, '$candidates | Where-Object'
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
