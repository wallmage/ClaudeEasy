#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "base64"
require "fiddle/import"
require "open3"
require "optparse"
require "psych"
require "tempfile"
require "time"

module ClaudeEasy
  VALIDATION_TIMEOUT_SECONDS = 30
end

module ClaudeEasyBootstrap
  module_function

  DEPENDENCIES = %w[
    result_contract patch_profiles/transform patch_profiles/backups patch_profiles/mihomo
    patch_profiles/profile_writer patch_profiles/subscriptions patch_profiles/runtime patch_profiles/cli
  ].freeze

  def load_dependencies(loader:, argv:, output:)
    DEPENDENCIES.each { |path| loader.call(path) }
    true
  rescue LoadError
    raise unless argv.include?("--json")

    output.write(JSON.generate(
      "schema" => "claude-easy.result", "version" => 1, "command" => "patch",
      "platform" => "macos", "client" => "clashx-meta", "operation" => "load",
      "ok" => false, "status" => "failed", "code" => "incomplete_package", "exit_code" => 1,
      "summary_zh" => "安装包不完整。", "profile" => nil, "changes" => [], "checks" => [],
      "items" => [], "messages" => [], "warnings" => []
    ) + "\n")
    false
  end
end

dependencies_loaded = ClaudeEasyBootstrap.load_dependencies(
  loader: ->(path) { require_relative path }, argv: ARGV, output: $stdout
)
exit 1 unless dependencies_loaded

exit ClaudeEasy.cli if $PROGRAM_NAME == __FILE__
