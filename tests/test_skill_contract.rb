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
    claude-easy/references/general-diagnostics.md
    claude-easy/references/general-macos.md
    claude-easy/references/general-windows.md
    claude-easy/agents/openai.yaml
    claude-easy/assets/claude-region-check.html
    claude-easy/references/policy.json
    claude-easy/references/result-contract.json
    claude-easy/scripts/install_macos.sh
    claude-easy/scripts/check_skill_update.sh
    claude-easy/scripts/check_skill_update.ps1
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
    claude-easy/scripts/windows/install_windows/remote_preflight.ps1
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

  def test_all_distribution_files_exist
    missing = REQUIRED_PUBLIC_FILES.reject { |path| File.file?(File.join(ROOT, path)) }
    assert_empty missing, "missing public files: #{missing.join(', ')}"
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
    assert_includes windows_installer, "SafeUpdateChangedOnly"
    assert_includes windows_installer, "Get-RemoteSubscriptionUpdatePlan"
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

  def test_subscription_followups_use_parallel_three_site_connectivity
    readme = File.read(File.join(ROOT, "README.md"))
    safe_update = File.read(File.join(SKILL, "references/safe-update-and-recovery.md"))
    profiles = File.read(File.join(SKILL, "references/profiles-and-patch.md"))
    macos = File.read(File.join(SKILL, "references/macos.md"))
    diagnostics = File.read(File.join(SKILL, "references/diagnostics.md"))

    assert_match(/并行/, safe_update)
    assert_match(/百度.*Google.*ChatGPT/m, safe_update)
    refute_match(/百度、Google、Twitter|Google、Twitter/, safe_update)
    assert_match(/百度、Google、ChatGPT/, readme)
    refute_match(/国内站、Google、Twitter|命令行或 Agent/, readme)
    refute_match(/检查常用网站和 AI 工具/, readme)
    assert_match(/开启 TUN，关闭 Clash 自己的系统代理，检查百度、Google、ChatGPT/, readme)
    assert_match(/同一浏览器会话/, profiles)
    assert_match(/只有实际状态仍不明.*才.*用户/, macos)
    refute_match(/Agent 联网|Agent 连接|至少三个无关目标/, diagnostics)
    assert_match(/连通性仅复测百度、Google、ChatGPT 三页/, diagnostics)
  end

  def test_safe_update_followups_do_not_require_separate_agent_connectivity
    mac_cli = File.read(File.join(SKILL, "scripts/macos/patch_profiles/cli.rb"))
    windows_common = File.read(File.join(SKILL, "scripts/windows/install_windows/common.ps1"))

    refute_includes mac_cli, "agent_connectivity_verification"
    refute_includes windows_common, "agent_connectivity_verification"
  end

  def test_route_targets_are_observed_concurrently
    verifier = File.read(File.join(SKILL, "scripts/macos/verify_routes.rb"))

    assert_includes verifier, "Thread.new"
    assert_match(/TARGETS\.map\s+do.*Thread\.new/m, verifier)
    assert_includes verifier, "checks.all? { |_label, ok, _status| ok }"
    refute_match(/checks\.map\s+do\s+\|_label, ok, _status\|\s+ok\s+end\s+checks\.all\?/, verifier)
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

  FORBIDDEN_ANTHROPIC_DOMAINS = %w[claude.ai anthropic.com].freeze
  CLASHX_APP_MARKER = /ClashX Meta\.app|com\.metacubex\.ClashX\.meta|\bClashX Meta\b/i
  CLASH_CLIENT_LITERAL = /
    ClashX\ Meta
    |(?<![\w.-])ClashX(?![\w.-])
    |Clash\ Verge(?:\ Rev)?
    |clash-verge(?:-rev)?(?:\.exe)?
    |com\.metacubex\.ClashX\.meta
  /ix
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
    \b(?:system|exec(?:File(?:Sync)?|Sync)?|spawn(?:Sync)?|popen)\s*\(
    |\.(?:spawn(?:Sync)?|popen|exec(?:File(?:Sync)?|Sync)?)\b
    |Open3\.(?:popen3|capture2|capture3|pipeline)
    |%x
  }ix
  EXEC_PS = %r{
    (?:
      (?:^|[;|]|`\s+)&\s+(?![&])
      |Start-Process\b
    )
  }ix

  def production_script_paths
    Dir.glob(File.join(SKILL, "scripts/**/*.{rb,sh,ps1,psm1,cmd,js}")).select { |path| File.file?(path) }.sort
  end

  def strip_line_comments(line)
    return "" if line.match?(/\A\s*rem\b/i)

    stripped = +""
    in_single = false
    in_double = false
    index = 0
    while index < line.length
      char = line[index]
      next_char = line[index + 1]
      if !in_single && !in_double
        if char == "#"
          break
        elsif char == "/" && next_char == "/" && stripped[-1] != ":"
          break
        elsif char == "'"
          in_single = true
          stripped << char
        elsif char == '"'
          in_double = true
          stripped << char
        else
          stripped << char
        end
      elsif in_single
        stripped << char
        in_single = false if char == "'"
      elsif in_double
        stripped << char
        in_double = false if char == '"'
      end
      index += 1
    end
    stripped.rstrip
  end

  def comment_stripped_lines(source)
    source.lines.map { |line| strip_line_comments(line) }
  end

  def command_segments(line)
    segments = []
    current = +""
    in_single = false
    in_double = false
    index = 0
    while index < line.length
      char = line[index]
      if in_single
        current << char
        in_single = false if char == "'"
      elsif in_double
        if char == "\\" || char == "`"
          run = 1
          run += 1 while line[index + run] == char
          current << (char * run)
          index += run
          if run.odd? && line[index] == '"'
            current << '"'
            index += 1
          end
          next
        end
        current << char
        in_double = false if char == '"'
      elsif char == "'"
        in_single = true
        current << char
      elsif char == '"'
        in_double = true
        current << char
      elsif char == ";" || char == "|" || char == "&"
        segments << current
        current = +""
      else
        current << char
      end
      index += 1
    end
    segments << current
    segments.map(&:strip).reject(&:empty?)
  end

  def normalize_endpoint_source(source)
    source.gsub("\\/", "/")
  end

  def extract_http_urls(source)
    urls = []
    comment_stripped_lines(source).each_with_index do |line, index|
      normalized = normalize_endpoint_source(line)
      normalized.scan(%r{https?://}i) do
        rest = normalized[$~.begin(0)..]
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
    stripped_lines = comment_stripped_lines(source)
    extract_http_urls(source).each do |url, index|
      host = parse_uri_host(url)
      next unless forbidden_anthropic_host?(host)

      line = stripped_lines[index].strip
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

  def bare_quoted_clash_path_line?(line)
    line.match?(%r{\A\s*["'](?:/Applications/)?ClashX Meta\.app(?:/Contents/MacOS/ClashX Meta)?["']\s*\z})
  end

  def bare_quoted_clash_continuation?(previous_line)
    prev = previous_line.to_s.rstrip
    return false if prev.empty?
    return false if prev.match?(EXEC_RUBY_JS)

    return prev.match?(/[\w?!]\(\z/) if prev.end_with?("(")

    prev.match?(/[,\[{=]\z/)
  end

  def direct_exec_clash?(line, previous_line: nil)
    return false unless clashx_reference?(line)

    if bare_quoted_clash_path_line?(line)
      return false if bare_quoted_clash_continuation?(previous_line)

      return true
    end

    line.match?(%r{(?:[;|&]|`\s+)\s*(?:/\S+\s+)?["'](?:/Applications/)?ClashX Meta\.app(?:/Contents/MacOS/ClashX Meta)?["']}) ||
      line.match?(%r{(?:^|[;|&]|`\s+)\s*(?:/[\w./ -]+/)?ClashX Meta\.app/Contents/MacOS/ClashX Meta\b}) ||
      line.match?(%r{\A\s*["'](?:/Applications/)?ClashX Meta\.app(?:/Contents/MacOS/ClashX Meta)?["']\s+\S}) ||
      (line.match?(EXEC_PS) && line.match?(CLASHX_APP_MARKER))
  end

  def ruby_js_exec_clash?(line)
    return false unless clashx_reference?(line)
    return true if line.match?(EXEC_RUBY_JS)
    return true if line.match?(/`[^`\n]*ClashX Meta[^`\n]*`/)

    false
  end

  def line_has_clash_launch_execution?(line, previous_line: nil)
    open_launch_clash?(line) ||
      launch_services_clash?(line) ||
      direct_exec_clash?(line, previous_line: previous_line) ||
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

  def previous_nonempty_line(lines, index)
    return nil if index <= 0

    lines[0...index].reverse.find { |candidate| !candidate.strip.empty? }
  end

  def clashx_meta_launch_violations(source)
    lines = comment_stripped_lines(source)
    violations = []
    lines.each_with_index do |line, index|
      next unless line_has_clash_launch_execution?(line, previous_line: previous_nonempty_line(lines, index))

      violations << "ClashX Meta launch near line #{index + 1}: #{line.strip}"
    end
    violations.concat(applescript_clash_launch_violations(lines))
    violations.concat(jxa_clash_launch_violations(lines))
    violations.uniq
  end

  def extract_literal_kill_targets(segment)
    targets = []

    segment.scan(%r{pkill(?:\s+-[\w]+)*\s+-f\s+(?:"([^"]+)"|'([^']+)'|(\S+))}i) do |a, b, c|
      targets << (a || b || c)
    end
    segment.scan(%r{pkill(?:\s+-[\w]+)*\s+(?!-f\b)(?:"([^"]+)"|'([^']+)'|(\S+))}i) do |a, b, c|
      targets << (a || b || c)
    end
    segment.scan(/\bkillall\b((?:\s+-[\w]+)*)\s+(.*)/i) do |_flags, rest|
      remainder = rest
      while (match = remainder.match(/\A\s*(?:"([^"]+)"|'([^']+)'|(\S+))/))
        targets << (match[1] || match[2] || match[3])
        remainder = remainder[match.end(0)..]
      end
    end
    if segment.match?(/\btaskkill\b/i)
      segment.scan(%r{/(?:IM|PID)\s+(?:"([^"]+)"|'([^']+)'|(\S+))}i) do |a, b, c|
        targets << (a || b || c)
      end
    end
    segment.scan(/Stop-Process(?:\s+-\w+)*\s+-Name\s+(?:"([^"]+)"|'([^']+)'|(\S+))/i) do |a, b, c|
      targets << (a || b || c)
    end
    segment.scan(%r{(?:^|[;\s|&]|`\s*)(?:/[\w./-]+/)?kill(?:\s+-[\w]+)*\s+(?:"([^"]+)"|'([^']+)'|(-?\S+))}i) do |a, b, c|
      targets << (a || b || c)
    end
    targets.compact
  end

  def mihomo_kill_target?(target)
    return false if target.match?(/\A\$/)
    return false if target.match?(/\A-?\d+\z/)

    target.sub(/\.exe\z/i, "").match?(/\Amihomo\z/i)
  end

  def segment_forbidden_clash_kill?(segment)
    return false if segment.empty?
    return false if segment.match?(/\A(?:echo\b|puts\b|print\b|logger\b|Write-Host\b|Write-Output\b)/i)
    return false unless segment.match?(KILL_PRIMITIVE)

    targets = extract_literal_kill_targets(segment)
    return segment.match?(CLASH_CLIENT_LITERAL) if targets.empty?

    flagged = targets.any? do |target|
      next false if mihomo_kill_target?(target)

      target.match?(CLASH_CLIENT_LITERAL)
    end
    return true if flagged

    residue = targets.uniq.reduce(segment) { |text, target| text.gsub(target) { "" } }
    residue.match?(CLASH_CLIENT_LITERAL)
  end

  def clash_client_termination_violations(source)
    violations = []
    comment_stripped_lines(source).each_with_index do |line, index|
      command_segments(line).each do |segment|
        next unless segment_forbidden_clash_kill?(segment)

        violations << "Clash-client termination near line #{index + 1}: #{segment}"
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
