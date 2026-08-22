#!/usr/bin/env ruby

OUTPUTS = %w[
  contract macos_routes macos_core macos_wrappers macos_probes macos_mutation macos_mihomo
  windows_routes windows_engine windows_core windows_mutation windows_mihomo
].freeze

selected = OUTPUTS.to_h { |name| [name, false] }

if ARGV.empty?
  selected.keys.each { |name| selected[name] = true }
else
  ARGV.each do |path|
    case path
    when "claude-easy/references/policy.json"
      %w[contract macos_core macos_mihomo windows_engine windows_core windows_mihomo].each do |name|
        selected[name] = true
      end
    when "claude-easy/references/result-contract.json"
      %w[contract macos_core windows_core].each { |name| selected[name] = true }
    when %r{\Aclaude-easy/(?:SKILL\.md|agents/|references/.*\.md\z)},
         ".github/workflows/test.yml", "package.json", "package-lock.json",
         "tests/ci_scope.rb", "tests/test_ci_scope.rb", "tests/test_skill_contract.rb",
         "tests/generate_windows_policy.rb"
      selected["contract"] = true
    when %r{\Aclaude-easy/scripts/(?:install_macos|uninstall_macos)\.sh\z},
         "tests/test_macos_wrappers.rb"
      selected["macos_wrappers"] = true
    when "claude-easy/scripts/macos/verify_routes.rb"
      selected["macos_routes"] = true
    when "claude-easy/scripts/macos/patch_profiles/runtime.rb"
      %w[macos_core macos_probes macos_mutation].each { |name| selected[name] = true }
    when %r{\Aclaude-easy/scripts/macos/patch_profiles/(?:transform|mihomo)\.rb\z}
      %w[macos_core macos_mutation macos_mihomo].each { |name| selected[name] = true }
    when %r{\Aclaude-easy/scripts/macos/patch_profiles/(?:profile_writer|subscriptions)\.rb\z}
      %w[macos_core macos_probes macos_mutation].each { |name| selected[name] = true }
    when %r{\Aclaude-easy/scripts/macos/}, "tests/coverage_ruby.rb", "tests/test_macos_patcher.rb"
      selected["macos_core"] = true
    when %r{\Atests/(?:fixtures/macos|support/macos)}, "tests/run_macos_production_probes.rb"
      selected["macos_probes"] = true
    when "tests/run_macos_mihomo_validation.rb"
      selected["macos_mihomo"] = true
    when "claude-easy/scripts/windows/verify_routes.ps1"
      selected["windows_routes"] = true
    when "claude-easy/scripts/windows/clash_verge_global.js", "tests/test_windows_patcher.js"
      %w[windows_engine windows_mihomo].each { |name| selected[name] = true }
    when "claude-easy/scripts/windows/install_windows/transaction.ps1"
      %w[windows_core windows_mutation].each { |name| selected[name] = true }
    when %r{\Aclaude-easy/scripts/(?:install_windows|uninstall_windows)},
         %r{\Aclaude-easy/scripts/windows/}, "tests/test_windows_installer.ps1"
      selected["windows_core"] = true
    when "tests/test_mutation_safety.rb"
      %w[macos_mutation windows_mutation].each { |name| selected[name] = true }
    end
  end
end

OUTPUTS.each { |name| puts "#{name}=#{selected.fetch(name)}" }
