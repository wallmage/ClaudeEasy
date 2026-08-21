#!/usr/bin/env ruby

macos = false
windows = false

ARGV.each do |path|
  case path
  when %r{\A(?:AGENTS\.md|README\.md|LICENSE|docs/|tests/baseline\.md)}
    next
  when %r{\Aclaude-easy/scripts/(?:install_macos\.sh|uninstall_macos\.sh|macos/)},
       %r{\Atests/(?:coverage_ruby\.rb|run_macos|test_macos|fixtures/macos|support/macos)}
    macos = true
  when %r{\Aclaude-easy/scripts/(?:install_windows|uninstall_windows|windows/)},
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
