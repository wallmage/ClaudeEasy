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

  def assert_selects(*paths, outputs:)
    selected = selected_outputs(*paths)
    outputs.each do |name|
      assert_includes selected, name, "#{paths.join(", ")} should include #{name}; got #{selected.join(", ")}"
    end
    selected
  end

  def assert_does_not_select(*paths, outputs:)
    selected = selected_outputs(*paths)
    outputs.each do |name|
      refute_includes selected, name, "#{paths.join(", ")} should not include #{name}; got #{selected.join(", ")}"
    end
    selected
  end

  def test_manual_dispatch_selects_every_job
    assert_equal OUTPUTS.sort, selected_outputs
  end

  def test_main_group_cases_includes_cross_platform_outputs
    assert_selects "tests/fixtures/main_group_cases.json",
                   outputs: %w[contract macos_core windows_engine macos_mihomo windows_mihomo]
    assert_does_not_select "tests/fixtures/main_group_cases.json", outputs: %w[windows_core]
  end

  def test_mihomo_ps1_includes_windows_core_and_contract
    assert_selects "claude-easy/scripts/windows/install_windows/mihomo.ps1",
                   outputs: %w[windows_core windows_mihomo contract]
  end

  def test_assets_include_contract_only
    selected = assert_selects "claude-easy/assets/claude-region-check.html", outputs: %w[contract]
    refute selected.grep(/\A(?:macos|windows)_/).any?,
           "assets should not select platform outputs; got #{selected.join(", ")}"
  end

  def test_control_paths_select_all_jobs
    [".github/workflows/test.yml", "tests/ci_scope.rb", "tests/test_ci_scope.rb"].each do |path|
      assert_equal OUTPUTS.sort, selected_outputs(path), path
    end
  end

  def test_macos_production_includes_contract_and_core_outputs
    assert_selects "claude-easy/scripts/macos/patch_profiles/transform.rb",
                   outputs: %w[contract macos_core macos_mihomo]
  end

  def test_windows_production_includes_contract_and_core
    assert_selects "claude-easy/scripts/install_windows.ps1", outputs: %w[contract windows_core]
  end

  def test_multiple_paths_union_outputs
    selected = selected_outputs(
      "claude-easy/scripts/macos/verify_routes.rb",
      "claude-easy/scripts/windows/verify_routes.ps1"
    )
    assert_includes selected, "macos_routes"
    assert_includes selected, "windows_routes"
    assert_includes selected, "contract"
  end

  def test_fail_safe_unknown_path_includes_contract_and_both_cores
    selected = assert_selects "claude-easy/newthing.txt", outputs: %w[contract macos_core windows_core]
    refute selected.grep(/(?:mihomo|mutation)\z/).any?,
           "fail-safe should not select mihomo or mutation outputs; got #{selected.join(", ")}"
  end

  def test_fail_safe_windows_signal_includes_windows_core
    assert_selects "some/unknown/path_windows.txt", outputs: %w[contract windows_core]
    assert_does_not_select "some/unknown/path_windows.txt", outputs: %w[macos_core]
  end

  def test_fail_safe_macos_signal_includes_macos_core
    assert_selects "some/unknown/path_macos.txt", outputs: %w[contract macos_core]
    assert_does_not_select "some/unknown/path_macos.txt", outputs: %w[windows_core]
  end

  def test_platform_changes_never_select_the_other_platform
    windows_paths = [
      "claude-easy/scripts/windows/verify_routes.ps1",
      "claude-easy/scripts/install_windows.ps1",
      "claude-easy/scripts/windows/clash_verge_global.js"
    ]
    macos_paths = [
      "claude-easy/scripts/macos/verify_routes.rb",
      "claude-easy/scripts/macos/patch_profiles/transform.rb",
      "claude-easy/scripts/install_macos.sh"
    ]

    windows_paths.each do |path|
      selected = selected_outputs(path)
      assert_empty selected.grep(/\Amacos_/), path
    end

    macos_paths.each do |path|
      selected = selected_outputs(path)
      assert_empty selected.grep(/\Awindows_/), path
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
