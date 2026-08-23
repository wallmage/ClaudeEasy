require "minitest/autorun"
require "open3"
require "rbconfig"

class CiScopeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CLASSIFIER = File.join(ROOT, "tests/ci_scope.rb")
  OUTPUTS = %w[structure macos windows mihomo].freeze

  def selected_outputs(*paths)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, CLASSIFIER, *paths)
    assert status.success?, stderr
    values = stdout.each_line.to_h do |line|
      key, value = line.strip.split("=", 2)
      [key, value]
    end
    OUTPUTS.each do |name|
      assert values.key?(name), "classifier output missing #{name}"
    end
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
    assert_selects outputs: OUTPUTS
  end

  def test_main_group_cases_includes_all_flags
    assert_selects "tests/fixtures/main_group_cases.json",
                   outputs: %w[structure macos windows mihomo]
  end

  def test_transform_expected_includes_all_flags
    assert_selects "tests/fixtures/transform_expected/reuse-existing-ai-group.json",
                   outputs: %w[structure macos windows mihomo]
  end

  def test_mihomo_ps1_includes_structure_windows_mihomo
    assert_selects "claude-easy/scripts/windows/install_windows/mihomo.ps1",
                   outputs: %w[structure windows mihomo]
  end

  def test_assets_include_structure
    assert_selects "claude-easy/assets/claude-region-check.html", outputs: %w[structure]
  end

  def test_region_fingerprint_tests_include_structure
    %w[tests/test_region_fingerprint_page.js tests/test_region_fingerprint_browser.js].each do |path|
      assert_selects path, outputs: %w[structure]
    end
  end

  def test_control_paths_select_all_jobs
    [".github/workflows/test.yml", "tests/ci_scope.rb", "tests/test_ci_scope.rb"].each do |path|
      assert_selects path, outputs: OUTPUTS
    end
  end

  def test_macos_transform_includes_structure_macos_mihomo
    assert_selects "claude-easy/scripts/macos/patch_profiles/transform.rb",
                   outputs: %w[structure macos mihomo]
  end

  def test_windows_production_includes_structure_and_windows
    assert_selects "claude-easy/scripts/install_windows.ps1", outputs: %w[structure windows]
  end

  def test_god_suite_ownership
    assert_selects "tests/test_macos_patcher.rb", outputs: %w[structure macos mihomo]
    assert_selects "tests/test_windows_installer.ps1", outputs: %w[structure windows mihomo]
  end

  def test_windows_patcher_includes_structure
    assert_selects "tests/test_windows_patcher.js", outputs: %w[structure]
  end

  def test_multiple_paths_union_outputs
    assert_selects(
      "claude-easy/scripts/macos/verify_routes.rb",
      "claude-easy/scripts/windows/verify_routes.ps1",
      outputs: %w[structure macos windows]
    )
  end

  def test_fail_safe_unknown_path_includes_structure_macos_windows
    assert_selects "zzz.unknown", outputs: %w[structure macos windows]
    assert_does_not_select "zzz.unknown", outputs: %w[mihomo]
  end

  def test_fail_safe_windows_signal_includes_structure_windows
    assert_selects "some/unknown/path_windows.txt", outputs: %w[structure windows]
    assert_does_not_select "some/unknown/path_windows.txt", outputs: %w[mihomo]
  end

  def test_fail_safe_macos_signal_includes_structure_macos
    assert_selects "some/unknown/path_macos.txt", outputs: %w[structure macos]
    assert_does_not_select "some/unknown/path_macos.txt", outputs: %w[mihomo]
  end

  def test_every_production_script_has_an_owner
    stdout, stderr, status = Open3.capture3("git", "ls-files", "claude-easy/scripts", chdir: ROOT)
    assert status.success?, stderr
    stdout.lines.map(&:strip).each do |path|
      refute_empty selected_outputs(path), path
    end
  end
end
