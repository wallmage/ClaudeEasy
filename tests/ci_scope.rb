#!/usr/bin/env ruby

OUTPUTS = %w[
  contract macos_routes macos_core macos_wrappers macos_probes macos_mutation macos_mihomo
  windows_routes windows_engine windows_core windows_mutation windows_mihomo
].freeze

RULES = [
  [%r{\A\.github/workflows/}, OUTPUTS],
  ["tests/ci_scope.rb", OUTPUTS],
  ["tests/test_ci_scope.rb", OUTPUTS],

  ["tests/fixtures/main_group_cases.json",
   %w[contract macos_core windows_engine macos_mihomo windows_mihomo]],

  [%r{\Atests/fixtures/transform_expected/},
   %w[contract macos_core windows_engine macos_mihomo windows_mihomo]],

  ["claude-easy/references/policy.json",
   %w[contract macos_core macos_mihomo windows_engine windows_core windows_mihomo]],
  ["claude-easy/references/result-contract.json", %w[contract macos_core windows_core]],

  [%r{\Aclaude-easy/assets/}, %w[contract]],

  [%r{\Aclaude-easy/(?:SKILL\.md|agents/|references/.*\.md\z)}, %w[contract]],
  ["package.json", %w[contract]],
  ["package-lock.json", %w[contract]],
  ["tests/test_skill_contract.rb", %w[contract]],
  ["tests/test_region_fingerprint_page.js", %w[contract]],
  ["tests/test_region_fingerprint_browser.js", %w[contract]],
  ["tests/generate_windows_policy.rb", %w[contract]],

  ["tests/test_macos_patcher.rb", %w[macos_core]],
  ["tests/test_windows_installer.ps1", %w[windows_core]],

  ["tests/test_macos_wrappers.rb", %w[macos_wrappers]],
  ["tests/run_macos_mihomo_validation.rb", %w[macos_mihomo]],
  [%r{\Atests/(?:fixtures/macos|support/macos)}, %w[macos_probes]],
  ["tests/run_macos_production_probes.rb", %w[macos_probes]],
  ["tests/test_windows_routes.ps1", %w[windows_routes]],
  ["tests/test_windows_patcher.js", %w[windows_engine windows_mihomo]],
  ["tests/test_mutation_safety.rb", %w[macos_mutation windows_mutation]],

  [%r{\Aclaude-easy/scripts/(?:install_macos|uninstall_macos)\.sh\z}, %w[macos_wrappers contract]],
  ["claude-easy/scripts/macos/verify_routes.rb", %w[macos_routes contract]],
  ["claude-easy/scripts/macos/patch_profiles/runtime.rb",
   %w[macos_core macos_probes macos_mutation contract]],
  [%r{\Aclaude-easy/scripts/macos/patch_profiles/(?:transform|mihomo)\.rb\z},
   %w[macos_core macos_mutation macos_mihomo contract]],
  [%r{\Aclaude-easy/scripts/macos/patch_profiles/(?:profile_writer|subscriptions)\.rb\z},
   %w[macos_core macos_probes macos_mutation contract]],
  [%r{\Aclaude-easy/scripts/macos/}, %w[macos_core contract]],

  ["claude-easy/scripts/windows/verify_routes.ps1", %w[windows_routes contract]],
  ["claude-easy/scripts/windows/clash_verge_global.js", %w[windows_engine windows_mihomo contract]],
  ["claude-easy/scripts/windows/install_windows/mihomo.ps1", %w[windows_mihomo]],
  ["claude-easy/scripts/windows/install_windows/transaction.ps1",
   %w[windows_core windows_mutation contract]],
  [%r{\Aclaude-easy/scripts/(?:install_windows|uninstall_windows)}, %w[windows_core contract]],
  [%r{\Aclaude-easy/scripts/windows/}, %w[windows_core contract]]
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
    selected["contract"] = true
    if path.include?("macos")
      selected["macos_core"] = true
    elsif path.include?("windows")
      selected["windows_core"] = true
    else
      selected["macos_core"] = true
      selected["windows_core"] = true
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
