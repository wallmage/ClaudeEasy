#!/usr/bin/env ruby

require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
PROBE_ENVIRONMENT = { "CLAUDE_EASY_RUN_PRODUCTION_PROBES" => "1" }.freeze
CURRENT_RUBY = ENV.fetch("CLAUDE_EASY_CURRENT_RUBY", RbConfig.ruby)
SYSTEM_RUBY = ENV.fetch("CLAUDE_EASY_SYSTEM_RUBY", "/usr/bin/ruby")
RUBIES = [CURRENT_RUBY, SYSTEM_RUBY].freeze
SUMMARY_PATTERN =
  /(\d+) runs,\s*(\d+) assertions,\s*(\d+) failures,\s*(\d+) errors,\s*(\d+) skips/
SURVIVORS = [
  {
    suite: "tests/test_macos_patcher.rb",
    name: "test_next_run_recovers_runtime_killed_after_active_reload",
  },
  {
    suite: "tests/test_macos_wrappers.rb",
    name: "test_production_probe_uninstall_preserves_a_file_replaced_after_staging",
  },
  {
    suite: "tests/test_macos_wrappers.rb",
    name: "test_production_probe_install_recovers_a_killed_ready_uninstall_before_changing_profile",
  },
  {
    suite: "tests/test_macos_wrappers.rb",
    name: "test_production_probe_uninstall_recovers_a_killed_profile_transaction_before_enabling_updates",
  },
].freeze

failed = false
SURVIVORS.product(RUBIES).each do |spec, ruby|
  name_filter = "/\\A#{Regexp.escape(spec.fetch(:name))}\\z/"
  stdout, stderr, status = Open3.capture3(
    PROBE_ENVIRONMENT,
    ruby,
    spec.fetch(:suite),
    "--name",
    name_filter,
    chdir: ROOT
  )
  $stdout.write(stdout)
  $stderr.write(stderr)

  summary = stdout.lines.find { |line| line.include?(" runs, ") && line.include?(" assertions, ") }
  counts = summary&.match(SUMMARY_PATTERN)&.captures&.map(&:to_i)
  invocation_ok = status.success? && counts == [1, counts&.fetch(1, 0), 0, 0, 0]
  unless invocation_ok
    failed = true
    label = "#{ruby} #{spec.fetch(:suite)} #{spec.fetch(:name)}"
    if counts.nil?
      warn "production probe summary missing for #{label}"
    else
      runs, assertions, failures, errors, skips = counts
      warn "production probe failed for #{label}: " \
           "#{runs} runs, #{assertions} assertions, #{failures} failures, " \
           "#{errors} errors, #{skips} skips"
    end
  end
end

exit(failed ? 1 : 0)
