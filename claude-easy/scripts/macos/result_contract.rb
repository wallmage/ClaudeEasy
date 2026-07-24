#!/usr/bin/env ruby

require "json"
require "optparse"

module ClaudeEasyResult
  module_function

  SCHEMA = "claude-easy.result".freeze
  VERSION = 1
  PLATFORM = "macos".freeze
  CLIENT = "clashx-meta".freeze
  STATUSES = %w[ok no_change skipped failed rolled_back partial invalid_request unsupported].freeze
  COMMANDS = %w[install uninstall patch verify_routes].freeze

  def sanitize_text(value)
    text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
    text = text.gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
    text = text.gsub(/\e\[[0-?]*[ -\/]?[@-~]/, "")
    text = text.gsub(/[\p{Cc}\p{Cf}]/, "")
    text = text.gsub(/\b(?:password|passwd|token|secret|uuid|private[-_ ]?key|controller[-_ ]?key)\s*[=:]\s*\S+/i, "[已隐藏]")
    text = text.gsub(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i, "[已隐藏]")
    text = text.gsub(%r{\b[A-Za-z][A-Za-z0-9+.-]*://\S+}, "[已隐藏]")
    text = text.gsub(%r{(?<![A-Za-z0-9])/(?:[^/\s]+/)+[^/\s]*}, "[路径已隐藏]")
    text = text.gsub(/\b[A-Za-z]:[\\\/](?:[^\\\/\s]+[\\\/])+[^\\\/\s]*/, "[路径已隐藏]")
    text.strip.each_char.take(240).join
  end

  def sanitize(value)
    case value
    when String, Symbol then sanitize_text(value)
    when Array then value.map { |entry| sanitize(entry) }
    when Hash
      value.each_with_object({}) do |(key, entry), output|
        output[sanitize_text(key)] = sanitize(entry)
      end
    when Integer, Float, TrueClass, FalseClass, NilClass then value
    else sanitize_text(value)
    end
  end

  def build(command:, operation:, ok:, status:, code:, exit_code:, summary_zh:, profile: nil,
            changes: [], checks: [], items: [], messages: [], warnings: [])
    normalized_command = command.to_s
    raise ArgumentError, "invalid command" unless COMMANDS.include?(normalized_command)
    normalized_status = status.to_s
    normalized_status = "failed" unless STATUSES.include?(normalized_status)
    {
      "schema" => SCHEMA,
      "version" => VERSION,
      "command" => normalized_command,
      "platform" => PLATFORM,
      "client" => CLIENT,
      "operation" => sanitize_text(operation),
      "ok" => !!ok,
      "status" => normalized_status,
      "code" => sanitize_text(code),
      "exit_code" => Integer(exit_code),
      "summary_zh" => sanitize_text(summary_zh),
      "profile" => profile,
      "changes" => sanitize(Array(changes)),
      "checks" => sanitize(Array(checks)),
      "items" => sanitize(Array(items)),
      "messages" => sanitize(Array(messages)),
      "warnings" => sanitize(Array(warnings))
    }
  end

  def write(output:, **attributes)
    output.write(JSON.generate(build(**attributes)))
    output.write("\n")
  end

  def emit(**attributes)
    write(output: $stdout, **attributes)
  end

  def cli(argv = ARGV)
    options = { messages: [], warnings: [], profile: nil }
    parser = OptionParser.new do |opts|
      opts.on("--command VALUE") { |value| options[:command] = value }
      opts.on("--operation VALUE") { |value| options[:operation] = value }
      opts.on("--ok VALUE") { |value| options[:ok] = value == "true" }
      opts.on("--status VALUE") { |value| options[:status] = value }
      opts.on("--code VALUE") { |value| options[:code] = value }
      opts.on("--exit-code VALUE", Integer) { |value| options[:exit_code] = value }
      opts.on("--summary VALUE") { |value| options[:summary_zh] = value }
      opts.on("--profile VALUE") { |value| options[:profile] = value.match?(/\A[1-3]\z/) ? value.to_i : nil }
      opts.on("--message VALUE") { |value| options[:messages] << value }
      opts.on("--warning VALUE") { |value| options[:warnings] << value }
    end
    parser.parse!(argv)
    required = %i[command operation ok status code exit_code summary_zh]
    raise OptionParser::MissingArgument, required.find { |key| !options.key?(key) }.to_s unless required.all? { |key| options.key?(key) }

    emit(**options.merge(changes: [], checks: [], items: []))
    0
  rescue OptionParser::ParseError, ArgumentError
    emit(
      command: "patch", operation: "emit", ok: false, status: "invalid_request",
      code: "invalid_request", exit_code: 64, summary_zh: "结果参数无效。"
    )
    64
  end
end

exit ClaudeEasyResult.cli if $PROGRAM_NAME == __FILE__
