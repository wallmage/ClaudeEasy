#!/usr/bin/env ruby

require "open3"
require "rbconfig"

ROOT = File.expand_path("..", __dir__)
TEST_NAME = "test_generated_profile_passes_installed_mihomo_validation".freeze

environment = {
  "CLAUDE_EASY_REQUIRE_REAL_MIHOMO" => "1"
}
stdout, stderr, status = Open3.capture3(
  environment,
  RbConfig.ruby,
  "tests/test_macos_patcher.rb",
  "--name",
  TEST_NAME,
  chdir: ROOT
)
$stdout.write(stdout)
$stderr.write(stderr)

summary = stdout.lines.find { |line| line.include?(" runs, ") && line.include?(" assertions, ") }
counts = summary&.match(
  /(\d+) runs,\s*(\d+) assertions,\s*(\d+) failures,\s*(\d+) errors,\s*(\d+) skips/
)&.captures&.map(&:to_i)
complete = status.success? &&
           counts == [1, counts&.fetch(1, 0), 0, 0, 0] &&
           counts&.fetch(1, 0).positive?

warn "real Mihomo validation did not complete every profile and stage" unless complete
exit(complete ? 0 : 1)
