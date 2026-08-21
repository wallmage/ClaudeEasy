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
require "uri"

module ClaudeEasyAppleEvents
  extend Fiddle::Importer

  ERR_AE_TIMEOUT = -1712

  dlload "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
  AEDesc = struct ["unsigned int descriptorType", "void* dataHandle"]
  extern "int AECreateDesc(unsigned int, void*, long, void*)"
  extern "int AECreateAppleEvent(unsigned int, unsigned int, void*, short, int, void*)"
  extern "int AEPutParamPtr(void*, unsigned int, unsigned int, void*, long)"
  extern "int AESendMessage(void*, void*, int, int)"
  extern "int AEDisposeDesc(void*)"

  def self.send_get_url(pid, url)
    target = Fiddle::Pointer.malloc(AEDesc.size)
    event = Fiddle::Pointer.malloc(AEDesc.size)
    reply = Fiddle::Pointer.malloc(AEDesc.size)
    [target, event, reply].each { |descriptor| descriptor[0, AEDesc.size] = "\0" * AEDesc.size }
    pid_bytes = [Integer(pid)].pack("i")
    url_bytes = url.to_s.b
    return false unless AECreateDesc(0x6b706964, Fiddle::Pointer[pid_bytes], pid_bytes.bytesize, target).zero?
    return false unless AECreateAppleEvent(0x4755524c, 0x4755524c, target, -1, 0, event).zero?
    return false unless AEPutParamPtr(
      event, 0x2d2d2d2d, 0x75746638, Fiddle::Pointer[url_bytes], url_bytes.bytesize
    ).zero?

    status = AESendMessage(event, reply, 3, 180)
    status.zero? || status == ERR_AE_TIMEOUT
  rescue StandardError
    false
  ensure
    AEDisposeDesc(reply) if reply
    AEDisposeDesc(event) if event
    AEDisposeDesc(target) if target
  end

  def self.send_command(pid, event_class, event_id)
    target = Fiddle::Pointer.malloc(AEDesc.size)
    event = Fiddle::Pointer.malloc(AEDesc.size)
    reply = Fiddle::Pointer.malloc(AEDesc.size)
    [target, event, reply].each { |descriptor| descriptor[0, AEDesc.size] = "\0" * AEDesc.size }
    pid_bytes = [Integer(pid)].pack("i")
    return false unless AECreateDesc(0x6b706964, Fiddle::Pointer[pid_bytes], pid_bytes.bytesize, target).zero?
    return false unless AECreateAppleEvent(
      Integer(event_class), Integer(event_id), target, -1, 0, event
    ).zero?

    status = AESendMessage(event, reply, 3, 180)
    status.zero? || status == ERR_AE_TIMEOUT
  rescue StandardError
    false
  ensure
    AEDisposeDesc(reply) if reply
    AEDisposeDesc(event) if event
    AEDisposeDesc(target) if target
  end
end

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
    patch_profiles/client_switches patch_profiles/log_repair patch_profiles/cli
  ].freeze
  REQUIRED_APIS = {
    "ClaudeEasyResult" => %i[build valid_child_json?],
    "ClaudeEasyOperationLock" => [:acquire],
    "ClaudeEasy" => %i[
      patch profile_paths validate_with_mihomo transactional_compare_and_write_bytes
      safe_update_all fetch_remote_subscription backup_remote_subscriptions controller_socket controller_request running_mihomo_config_paths
      mihomo_core_paths repair_clashx_logs reconcile_clashx_client_switches cli saved_usage_profile
    ]
  }.freeze

  def load_dependencies(loader:, argv:, output:)
    DEPENDENCIES.each { |path| loader.call(path) }
    raise NameError, "incomplete package API" unless REQUIRED_APIS.all? do |owner_name, methods|
      owner = Object.const_get(owner_name)
      methods.all? { |method_name| owner.respond_to?(method_name) }
    end
    true
  rescue LoadError, SyntaxError, NameError
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
