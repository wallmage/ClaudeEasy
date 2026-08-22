require "minitest/autorun"
require "open3"
require "rbconfig"

class CiScopeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CLASSIFIER = File.join(ROOT, "tests/ci_scope.rb")
  OUTPUTS = %w[
    contract macos_routes macos_core macos_wrappers macos_probes macos_mutation macos_mihomo
    windows_routes windows_engine windows_core windows_mutation windows_mihomo
  ].freeze

  CASES = {
    ["README.md"] => [],
    ["claude-easy/SKILL.md"] => %w[contract],
    [".github/workflows/test.yml"] => %w[contract],
    ["claude-easy/scripts/macos/verify_routes.rb"] => %w[macos_routes],
    ["claude-easy/scripts/macos/patch_profiles/runtime.rb"] =>
      %w[macos_core macos_probes macos_mutation],
    ["claude-easy/scripts/install_macos.sh"] => %w[macos_wrappers],
    ["claude-easy/scripts/windows/verify_routes.ps1"] => %w[windows_routes],
    ["tests/test_windows_routes.ps1"] => %w[windows_routes],
    ["claude-easy/scripts/windows/install_windows/transaction.ps1"] =>
      %w[windows_core windows_mutation],
    ["claude-easy/scripts/windows/clash_verge_global.js"] =>
      %w[windows_engine windows_mihomo],
    ["claude-easy/references/policy.json"] =>
      %w[contract macos_core macos_mihomo windows_engine windows_core windows_mihomo]
  }.freeze

  def selected_outputs(*paths)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, CLASSIFIER, *paths)
    assert status.success?, stderr
    values = stdout.each_line.to_h do |line|
      key, value = line.strip.split("=", 2)
      [key, value]
    end
    assert_equal OUTPUTS.sort, values.keys.sort
    values.select { |_key, value| value == "true" }.keys.sort
  end

  def test_routes_each_path_to_only_its_affected_jobs
    assert File.file?(File.join(ROOT, "tests/test_windows_routes.ps1")), "missing focused Windows route suite"
    CASES.each do |paths, expected|
      assert_equal expected.sort, selected_outputs(*paths), paths.join(", ")
    end
  end

  def test_manual_dispatch_selects_every_job
    assert_equal OUTPUTS.sort, selected_outputs
  end

  def test_platform_changes_never_select_the_other_platform
    CASES.each_key do |paths|
      selected = selected_outputs(*paths)
      if paths.any? { |path| path.include?("/windows/") }
        assert_empty selected.grep(/\Amacos_/), paths.join(", ")
      elsif paths.any? { |path| path.include?("/macos/") || path.end_with?("_macos.sh") }
        assert_empty selected.grep(/\Awindows_/), paths.join(", ")
      end
    end
  end

  def test_every_production_script_has_an_owner
    stdout, stderr, status = Open3.capture3("git", "ls-files", "claude-easy/scripts", chdir: ROOT)
    assert status.success?, stderr
    stdout.lines.map(&:strip).each do |path|
      refute_empty selected_outputs(path), path
    end
  end
end
