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

  def test_region_fingerprint_tests_include_structure
    %w[tests/test_region_fingerprint_page.js tests/test_region_fingerprint_browser.js].each do |path|
      assert_selects path, outputs: %w[structure]
    end
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

end
