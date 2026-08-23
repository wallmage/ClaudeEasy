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

  def test_macos_installer_avoids_fakeip_flush_and_curl
    path = File.join(SKILL, "scripts/install_macos.sh")
    skip unless File.file?(path)

    source = File.read(path)
    refute_includes source, "/cache/fakeip/flush"
    refute_includes source, "/usr/bin/curl"
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

  FORBIDDEN_CLASH_EXIT_PROSE = ["请先从托盘菜单完全退出", "退出客户端，再"].freeze
  FORBIDDEN_ANTHROPIC_DOMAINS = %w[claude.ai anthropic.com].freeze
  CLASHX_APP_MARKER = /ClashX Meta\.app|com\.metacubex\.ClashX\.meta|\bClashX Meta\b/i
  KILL_PRIMITIVE = %r{
    (?:^|[;\s|&]|`\s*)
    (?:
      (?:\/[\w.\/-]+/)?(?:pkill|killall|kill|taskkill)\b
      |Stop-Process\b
      |Process\.kill\b
      |(?<![A-Za-z_])\.\s*Kill\s*\(
    )
  }ix
  EXEC_OPEN = %r{
    (?:^|[;\s|&]|`\s*)
    (?:\/[\w.\/-]+/)?open\b
  }ix
  EXEC_LAUNCH_SERVICES = %r{
    (?:^|[;\s|&]|`\s*)
    (?:
      (?:\/[\w.\/-]+/)?launchctl\b
      |LSOpen\w*
    )
  }ix
  EXEC_RUBY_JS = %r{
    \b(?:system|exec|spawn|popen)\s*\(
    |\.(?:spawn|popen|exec)\b
    |Open3\.(?:popen3|capture2|capture3|pipeline)
    |%x
  }ix
  EXEC_PS = %r{
    (?:
      (?:^|[;|]|`\s+)&\s+(?![&])
      |Start-Process\b
    )
  }ix
  CLASH_CLIENT_NAME_MATCHERS = [
    /\AClashX Meta\z/i,
    /\AClashX\z/i,
    /\AClash Verge(?: Rev)?\z/i,
    /\Aclash-verge(?:-rev)?\z/i,
    /\Averge\z/i,
    /\Acom\.metacubex\.ClashX\.meta\z/i
  ].freeze

  def production_script_paths
    Dir.glob(File.join(SKILL, "scripts/**/*.{rb,sh,ps1,psm1,cmd,js}")).select { |path| File.file?(path) }.sort
  end

  def normalize_endpoint_source(source)
    source.gsub("\\/", "/")
  end

  def extract_http_urls(source)
    urls = []
    normalized = normalize_endpoint_source(source)
    normalized.lines.each_with_index do |line, index|
      line.scan(%r{https?://}i) do
        rest = line[$~.begin(0)..]
        next unless rest =~ /\A(https?:\/\/[^\s"'<>]+)/i

        url = Regexp.last_match(1).sub(/[;,)\]}]+$/, "")
        urls << [url, index]
      end
    end
    urls
  end

  def parse_uri_host(url)
    authority = url.sub(%r{\Ahttps?://}i, "").split(%r{[/\?#]}, 2).first.to_s
    authority = authority.sub(/[;,)\]}]+$/, "")
    authority = authority.split("@").last if authority.include?("@")
    authority = authority.delete_prefix("[").delete_suffix("]")
    host = authority.split(":", 2).first.to_s
    host[/\A[\w.-]+/].to_s
  end

  def forbidden_anthropic_host?(host)
    return false if host.empty?

    normalized = host.downcase
    FORBIDDEN_ANTHROPIC_DOMAINS.any? do |domain|
      normalized == domain || normalized.end_with?(".#{domain}")
    end
  end

  def anthropic_network_violations(source)
    violations = []
    extract_http_urls(source).each do |url, index|
      host = parse_uri_host(url)
      next unless forbidden_anthropic_host?(host)

      line = source.lines[index].strip
      violations << "Claude/Anthropic network probe near line #{index + 1}: #{line}"
    end
    violations.uniq
  end

  def clashx_reference?(text)
    text.match?(CLASHX_APP_MARKER)
  end

  def open_launch_clash?(line)
    return false unless line.match?(EXEC_OPEN) && clashx_reference?(line)

    line.match?(/(?:-a\s+["']?ClashX Meta|-b\s+com\.metacubex\.ClashX\.meta|ClashX Meta\.app)/i)
  end

  def launch_services_clash?(line)
    line.match?(EXEC_LAUNCH_SERVICES) && clashx_reference?(line)
  end

  def direct_exec_clash?(line)
    return false unless clashx_reference?(line)
    return false if passive_clashx_reference_line?(line)

    line.match?(%r{(?:^|[;|&]|`\s+)\s*(?:/\S+\s+)?["'](?:/Applications/)?ClashX Meta\.app(?:/Contents/MacOS/ClashX Meta)?["']}) ||
      line.match?(%r{(?:^|[;|&]|`\s+)\s*(?:/[\w./ -]+/)?ClashX Meta\.app/Contents/MacOS/ClashX Meta\b}) ||
      (line.match?(EXEC_PS) && line.match?(CLASHX_APP_MARKER))
  end

  def passive_clashx_reference_line?(line)
    return false if line.match?(%r{(?:^|[;|&]|`\s+)\s*(?:/\S+\s+)?["'](?:/Applications/)?ClashX Meta\.app})

    line.match?(/\.(?:end_with\?|include\?|match\?|start_with\?|delete_suffix)\s*\([^)]*ClashX Meta/) ||
      line.match?(/\[\s*!?\s*-[\dfxe]\s+["'][^"']*ClashX Meta/) ||
      line.match?(/\$\w+\s*=\s*["'][^"']*ClashX Meta/) ||
      line.match?(/\b(?:expected|actual)\b.*ClashX Meta/i) ||
      (line.match?(/\s==\s/) && line.match?(/ClashX Meta/)) ||
      line.match?(/\[\s*["']?\$\w+["']?\s+=\s*["']?\$\w+["']?\s*\]/)
  end

  def ruby_js_exec_clash?(line)
    return false unless clashx_reference?(line)
    return true if line.match?(EXEC_RUBY_JS)
    return true if line.match?(/`[^`\n]*ClashX Meta[^`\n]*`/)

    false
  end

  def line_has_clash_launch_execution?(line)
    open_launch_clash?(line) ||
      launch_services_clash?(line) ||
      direct_exec_clash?(line) ||
      ruby_js_exec_clash?(line)
  end

  def applescript_clash_launch_violations(lines)
    violations = []
    lines.each_with_index do |line, index|
      next unless line.match?(/tell\s+application(?:\s+id)?\s+["'](?:ClashX Meta|com\.metacubex\.ClashX\.meta)["']/i)

      block_lines = [line]
      if line.match?(/end\s+tell/i)
        block = line
      else
        ((index + 1)...lines.length).each do |block_index|
          block_lines << lines[block_index]
          break if lines[block_index].match?(/end\s+tell/i)
        end
        block = block_lines.join("\n")
      end
      next unless block.match?(/\b(?:activate|run|launch|open|reopen|quit|terminate)\b/i)

      violations << "AppleScript ClashX Meta activation or termination near line #{index + 1}"
    end
    violations
  end

  def jxa_clash_launch_violations(lines)
    violations = []
    lines.each_with_index do |line, index|
      next unless line.match?(/Application\s*\(\s*["'](?:ClashX Meta|com\.metacubex\.ClashX\.meta)["']\s*\)/i)

      window = lines[[index - 5, 0].max..[index + 5, lines.length - 1].min].join("\n")
      next unless window.match?(/\.(?:activate|launch|run|open)\s*\(/i)

      violations << "JXA ClashX Meta activation near line #{index + 1}"
    end
    violations
  end

  def clashx_meta_launch_violations(source)
    lines = source.lines
    violations = []
    lines.each_with_index do |line, index|
      next unless line_has_clash_launch_execution?(line)

      violations << "ClashX Meta launch near line #{index + 1}: #{line.strip}"
    end
    violations.concat(applescript_clash_launch_violations(lines))
    violations.concat(jxa_clash_launch_violations(lines))
    violations.uniq
  end

  def classify_process_target(name)
    normalized = name.to_s.strip.sub(/\.exe\z/i, "")
    return :mihomo if normalized.match?(/\Amihomo\z/i)
    return :clash if CLASH_CLIENT_NAME_MATCHERS.any? { |matcher| normalized.match?(matcher) }

    :unknown
  end

  def strip_shell_arg(arg)
    arg.to_s.strip.sub(/\A(['"])(.*)\1\z/, '\2')
  end

  def resolve_pgrep_target(arg, name_bindings)
    stripped = strip_shell_arg(arg)
    if stripped.match?(/\A\$[\w]+\z/)
      var = stripped
      name_bindings[var] || name_bindings[var.delete_prefix("$")] || :unknown
    else
      classify_process_target(stripped)
    end
  end

  def each_script_statement(line)
    line.split(";").map(&:strip).reject(&:empty?)
  end

  def build_process_target_maps(lines)
    name_bindings = {}
    pid_bindings = {}

    lines.each do |line|
      each_script_statement(line).each do |stmt|
        stmt.scan(/(?:^|[\s])([A-Za-z_][\w]*)=(["'])(.*?)\2/) do |var, _, value|
          name_bindings[var] = classify_process_target(value)
        end

        stmt.scan(/\$([A-Za-z_][\w]*)\s*=\s*["']([^"']*)["']/) do |var, value|
          name_bindings["$#{var}"] = classify_process_target(value)
        end

        stmt.scan(/\b([A-Za-z_][\w]*)\s*=\s*["']([^"']*)["']/) do |var, value|
          name_bindings[var] ||= classify_process_target(value)
        end

        stmt.scan(%r{([A-Za-z_][\w]*)=\$\((?:\/[\w.\/-]+/)?pgrep(?:\s+-f)?\s+([^)]+)\)}) do |var, arg|
          pid_bindings[var] = resolve_pgrep_target(arg, name_bindings)
        end

        if stmt.match?(/Get-Process/i)
          if stmt =~ /\$([A-Za-z_][\w]*)\s*=\s*Get-Process\s+\$([A-Za-z_][\w]*)/i
            target = name_bindings["$#{$2}"] || name_bindings[$2]
            pid_bindings["$#{$1}"] = target if target
          elsif stmt =~ /\$([A-Za-z_][\w]*)\s*=\s*Get-Process\s+-\s*Name\s+\$([A-Za-z_][\w]*)/i
            target = name_bindings["$#{$2}"] || name_bindings[$2]
            pid_bindings["$#{$1}"] = target if target
          elsif stmt =~ /\$([A-Za-z_][\w]*)\s*=\s*Get-Process\s+-\s*Name\s+["']([^"']+)["']/i
            pid_bindings["$#{$1}"] = classify_process_target($2)
          elsif stmt =~ /\$([A-Za-z_][\w]*)\s*=\s*Get-Process\s+["']([^"']+)["']/i
            pid_bindings["$#{$1}"] = classify_process_target($2)
          end
        end
      end
    end

    [name_bindings, pid_bindings]
  end

  def resolve_variable_target(token, name_bindings, pid_bindings)
    normalized = token.to_s.strip.sub(/\A-/, "")
    bare = normalized.delete_prefix("$")
    if normalized.start_with?("$")
      pid_bindings[normalized] ||
        pid_bindings[bare] ||
        name_bindings[normalized] ||
        name_bindings[bare] ||
        :unknown
    else
      pid_bindings[normalized] || name_bindings[normalized] || classify_process_target(normalized)
    end
  end

  def resolve_kill_target(line, name_bindings, pid_bindings)
    if line.match?(/Get-Process/i) && line.match?(/Stop-Process/i)
      if line =~ /Get-Process\s+\$([A-Za-z_][\w]*)/i
        target = name_bindings["$#{$1}"] || name_bindings[$1]
        return target if target
      end
      return classify_process_target(Regexp.last_match(1)) if line =~ /Get-Process\s+["']([^"']+)["']/i
    end

    if line =~ /Stop-Process\s+-InputObject\s+\$([A-Za-z_][\w]*)/i
      return pid_bindings["$#{$1}"] || :unknown
    end

    if line =~ /Stop-Process(?:\s+-\w+)*\s+-Name\s+(\$[A-Za-z_]\w*|"[^"]+"|'[^']+'|[^;\s|&]+)/i
      return resolve_variable_target(strip_shell_arg(Regexp.last_match(1)), name_bindings, pid_bindings)
    end

    if line =~ /Stop-Process\s+(\$[A-Za-z_]\w*|"[^"]+"|'[^']+'|[A-Za-z][\w.-]*)/i
      return resolve_variable_target(strip_shell_arg(Regexp.last_match(1)), name_bindings, pid_bindings)
    end

    if line =~ %r{(?:^|[;\s|&]|`\s*)(?:\/[\w.\/-]+/)?pkill(?:\s+-[\w]+)*\s+-f\s+("[^"]+"|'[^']+'|[^;\s|&]+)}i
      target = strip_shell_arg(Regexp.last_match(1))
      return :mihomo if target.match?(/mihomo/i)
      return :clash if classify_process_target(target) == :clash || target.match?(/ClashX|Clash Verge|clash-verge|verge/i)

      return :unknown
    end

    if line =~ %r{(?:^|[;\s|&]|`\s*)(?:\/[\w.\/-]+/)?(pkill|killall)(?:\s+-[\w]+)*\s+("[^"]+"|'[^']+'|[^;\s|&]+)}i
      return classify_process_target(strip_shell_arg(Regexp.last_match(2)))
    end

    if line =~ %r{(?:^|[;\s|&]|`\s*)(?:\/[\w.\/-]+/)?taskkill(?:\s+\/\w+)*\s+\/(?:PID|IM)\s+("[^"]+"|'[^']+'|[^;\s|&]+)}i
      return resolve_variable_target(strip_shell_arg(Regexp.last_match(1)), name_bindings, pid_bindings)
    end

    if line =~ /Process\.kill\s*\(\s*[^,]+,\s*(-?\$?[A-Za-z_][\w]*)\s*\)/
      return resolve_variable_target(Regexp.last_match(1), name_bindings, pid_bindings)
    end

    if line =~ /\$([A-Za-z_][\w]*)\.Kill\s*\(\s*\)/
      return pid_bindings["$#{$1}"] || :unknown
    end

    if line =~ %r{(?:^|[;\s|&]|`\s*)(?:\/[\w.\/-]+/)?kill(?:\s+-[\w]+)*\s+(-?\$?[A-Za-z_][\w]*|"[^"]+"|'[^']+')}i
      return resolve_variable_target(strip_shell_arg(Regexp.last_match(1)), name_bindings, pid_bindings)
    end

    :unknown
  end

  def clash_client_termination_violations(source)
    violations = []
    FORBIDDEN_CLASH_EXIT_PROSE.each do |phrase|
      violations << "forbidden exit prose: #{phrase}" if source.include?(phrase)
    end

    lines = source.lines
    name_bindings, pid_bindings = build_process_target_maps(lines)
    lines.each_with_index do |line, index|
      each_script_statement(line).each do |stmt|
        next if stmt.match?(/\A(?:#|\/\/|rem\b|echo\b|puts\b|print\b|logger\b|Write-Host\b|Write-Output\b)/i)
        next unless stmt.match?(KILL_PRIMITIVE)

        target = resolve_kill_target(stmt, name_bindings, pid_bindings)
        next unless target == :clash

        violations << "Clash-client termination near line #{index + 1}: #{stmt}"
      end
    end
    violations
  end

  def production_script_safety_violations
    production_script_paths.flat_map do |path|
      source = File.binread(path).force_encoding("UTF-8").scrub
      relative = path.delete_prefix("#{ROOT}/")
      (
        clash_client_termination_violations(source) +
        anthropic_network_violations(source) +
        clashx_meta_launch_violations(source)
      ).map { |detail| "#{relative}: #{detail}" }
    end
  end

  def test_production_scripts_forbid_clash_termination_anthropic_probes_and_clashx_launch
    violations = production_script_safety_violations
    assert_empty violations,
                 "production script safety violations:\n#{violations.join("\n")}"
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
