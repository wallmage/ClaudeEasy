#!/usr/bin/env ruby

macos = false
windows = false

ARGV.each do |path|
  next if path == "tests/baseline.md"
  next unless path.start_with?("claude-easy/", "tests/") ||
              %w[.github/workflows/test.yml package.json package-lock.json].include?(path)

  case path
  when %r{\Aclaude-easy/scripts/(?:install_macos\.sh|uninstall_macos\.sh|macos/)},
       "claude-easy/references/macos.md",
       %r{\Atests/(?:coverage_ruby\.rb|run_macos|test_macos|fixtures/macos|support/macos)}
    macos = true
  when %r{\Aclaude-easy/scripts/(?:install_windows|uninstall_windows|windows/)},
       "claude-easy/references/windows.md",
       %r{\Atests/(?:generate_windows|test_windows)}
    windows = true
  else
    macos = true
    windows = true
  end
end

macos = windows = true if ARGV.empty?
puts "macos=#{macos}"
puts "windows=#{windows}"
