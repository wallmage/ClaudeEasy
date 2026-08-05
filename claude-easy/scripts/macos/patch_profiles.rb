#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "fiddle/import"
require "json"
require "base64"
require "open3"
require "optparse"
require "psych"
require "rbconfig"
require "rexml/document"
require "tempfile"
require "time"

module ClaudeEasyDarwinFilesystem
  extend Fiddle::Importer

  RENAME_EXCL = 0x00000004

  dlload "/usr/lib/libSystem.B.dylib"
  extern "int renamex_np(const char *, const char *, unsigned int)"

  def self.rename_exclusive(source, destination)
    return true if renamex_np(source, destination, RENAME_EXCL).zero?

    raise SystemCallError.new("无法独占发布状态文件", Fiddle.last_error)
  end
end

module ClaudeEasy
  VALIDATION_TIMEOUT_SECONDS = 30
end

module ClaudeEasyBootstrap
  module_function

  DEPENDENCIES = %w[
    result_contract operation_lock patch_profiles/transform patch_profiles/backups usage_profile_state patch_profiles/mihomo
    patch_profiles/profile_writer patch_profiles/subscriptions patch_profiles/runtime
    patch_profiles/log_repair patch_profiles/cli
  ].freeze

  def load_dependencies(loader:, argv:, output:)
    DEPENDENCIES.each { |path| loader.call(path) }
    true
  rescue LoadError, SyntaxError
    if argv.include?("--json")
      output.write(JSON.generate(
        "schema" => "claude-easy.result", "version" => 1, "command" => "patch",
        "platform" => "macos", "client" => "clashx-meta", "operation" => "load",
        "ok" => false, "status" => "failed", "code" => "incomplete_package", "exit_code" => 6,
        "summary_zh" => "安装包不完整。", "profile" => nil, "changes" => [], "checks" => [],
        "items" => [], "messages" => [], "warnings" => []
      ) + "\n")
    else
      output.write("安装包不完整。\n")
    end
    false
  end
end

if $PROGRAM_NAME == __FILE__
  dependencies_loaded = ClaudeEasyBootstrap.load_dependencies(
    loader: ->(path) { require_relative path }, argv: ARGV, output: $stdout
  )
  exit 6 unless dependencies_loaded

  exit ClaudeEasy.cli
end

ClaudeEasyBootstrap::DEPENDENCIES.each { |path| require_relative path }
