#!/usr/bin/env ruby

OUTPUTS = %w[structure macos windows mihomo].freeze

RULES = [
  [%r{\A\.github/workflows/}, OUTPUTS],
  ["tests/ci_scope.rb", OUTPUTS],
  ["tests/test_ci_scope.rb", OUTPUTS],

  ["tests/fixtures/main_group_cases.json", %w[structure macos windows mihomo]],
  [%r{\Atests/fixtures/transform_expected/}, %w[structure macos windows mihomo]],

  ["claude-easy/references/policy.json", %w[structure macos windows mihomo]],
  ["claude-easy/references/result-contract.json", %w[structure macos windows]],

  [%r{\Aclaude-easy/assets/}, %w[structure]],
  [%r{\Aclaude-easy/(?:SKILL\.md|agents/|references/.*\.md\z)}, %w[structure]],
  ["package.json", %w[structure]],
  ["package-lock.json", %w[structure]],
  ["tests/test_skill_contract.rb", %w[structure]],
  ["tests/test_region_fingerprint_page.js", %w[structure]],
  ["tests/test_region_fingerprint_browser.js", %w[structure]],
  ["tests/generate_windows_policy.rb", %w[structure]],

  ["tests/test_macos_patcher.rb", %w[structure macos mihomo]],
  ["tests/test_windows_installer.ps1", %w[structure windows mihomo]],

  ["tests/test_macos_wrappers.rb", %w[structure macos]],
  ["tests/run_macos_mihomo_validation.rb", %w[structure macos mihomo]],
  [%r{\Atests/(?:fixtures/macos|support/)}, %w[structure macos]],
  ["tests/run_macos_production_probes.rb", %w[structure macos]],

  ["tests/test_windows_routes.ps1", %w[structure windows]],
  ["tests/test_windows_patcher.js", %w[structure]],

  [%r{\Aclaude-easy/scripts/(?:install_macos|uninstall_macos)\.sh\z}, %w[structure macos]],
  ["claude-easy/scripts/macos/verify_routes.rb", %w[structure macos]],
  [%r{\Aclaude-easy/scripts/macos/patch_profiles/(?:transform|mihomo)\.rb\z},
   %w[structure macos mihomo]],
  [%r{\Aclaude-easy/scripts/macos/}, %w[structure macos]],

  ["claude-easy/scripts/windows/clash_verge_global.js", %w[structure windows mihomo]],
  ["claude-easy/scripts/windows/install_windows/mihomo.ps1", %w[structure windows mihomo]],
  [%r{\Aclaude-easy/scripts/(?:install_windows|uninstall_windows)}, %w[structure windows]],
  [%r{\Aclaude-easy/scripts/windows/}, %w[structure windows]]
].freeze

def path_matches?(matcher, path)
  case matcher
  when String then path == matcher
  when Regexp then path.match?(matcher)
  when Array then matcher.any? { |item| path_matches?(item, path) }
  else false
  end
end

def outputs_for_path(path)
  selected = OUTPUTS.to_h { |name| [name, false] }
  matched = false

  RULES.each do |matcher, rule_outputs|
    next unless path_matches?(matcher, path)

    matched = true
    rule_outputs.each { |name| selected[name] = true }
  end

  unless matched
    selected["structure"] = true
    if path.include?("macos")
      selected["macos"] = true
    elsif path.include?("windows")
      selected["windows"] = true
    else
      selected["macos"] = true
      selected["windows"] = true
    end
  end

  selected
end

selected = OUTPUTS.to_h { |name| [name, false] }

if ARGV.empty?
  selected.keys.each { |name| selected[name] = true }
else
  ARGV.each do |path|
    outputs_for_path(path).each do |name, value|
      selected[name] = true if value
    end
  end
end

OUTPUTS.each { |name| puts "#{name}=#{selected.fetch(name)}" }
