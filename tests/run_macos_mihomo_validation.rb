#!/usr/bin/env ruby

require "digest"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
TEST_NAME = "test_generated_profile_passes_installed_mihomo_validation".freeze

Dir.mktmpdir("claude-easy-mihomo-validation-") do |directory|
  receipt_path = File.join(directory, "completion.json")
  receipt_nonce = SecureRandom.hex(32)
  core_path = ENV["CLAUDE_EASY_TEST_MIHOMO"].to_s
  environment = {
    "CLAUDE_EASY_REQUIRE_REAL_MIHOMO" => "1",
    "CLAUDE_EASY_MIHOMO_RECEIPT_PATH" => receipt_path,
    "CLAUDE_EASY_MIHOMO_RECEIPT_NONCE" => receipt_nonce
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
  receipt = begin
    JSON.parse(File.read(receipt_path))
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end
  expected_validations = [1, 2, 3].flat_map do |usage_profile|
    [
      { "profile" => usage_profile, "stage" => "baseline" },
      { "profile" => usage_profile, "stage" => "patched" }
    ]
  end
  expected_core_sha256 = Digest::SHA256.file(core_path).hexdigest if File.file?(core_path)
  complete = status.success? &&
             counts == [1, counts&.fetch(1, 0), 0, 0, 0] &&
             counts&.fetch(1, 0).positive? &&
             receipt == {
               "schema" => "claude-easy.mihomo-validation",
               "version" => 1,
               "nonce" => receipt_nonce,
               "core_sha256" => expected_core_sha256,
               "profiles_completed" => [1, 2, 3],
               "validations" => expected_validations
             }

  warn "real Mihomo validation did not complete every profile and stage" unless complete
  exit(complete ? 0 : 1)
end
