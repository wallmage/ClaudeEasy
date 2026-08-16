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
  ITEM_STATUSES = %w[updated unchanged skipped failed rolled_back pending].freeze
  COMMANDS = %w[install uninstall patch verify_routes].freeze
  REQUIRED_FIELDS = %w[
    schema version command platform client operation ok status code exit_code summary_zh
    profile changes checks items messages warnings
  ].freeze

  def sanitize_text(value)
    text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
    text = text.gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
    text = text.gsub(/\e\[[0-?]*[ -\/]?[@-~]/, "")
    text = text.gsub(/[\p{Cc}\p{Cf}]/, "")
    text = text.gsub(/(?<![A-Za-z0-9])Bearer\s+\S+/i, "[已隐藏]")
    text = text.gsub(/(?<![A-Za-z0-9])(?:password|passwd|token|secret|uuid|private[-_ ]?key|controller[-_ ]?key)\s*[=:]\s*\S+/i, "[已隐藏]")
    text = text.gsub(/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i, "[已隐藏]")
    text = text.gsub(%r{(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9+.-]*://\S+}, "[已隐藏]")
    text = text.gsub(%r{(?<![A-Za-z0-9])/(?:[^/\s]+/)+[^/\s]*}, "[路径已隐藏]")
    text = text.gsub(/(?<![A-Za-z0-9])[A-Za-z]:[\\\/](?:[^\\\/\s]+[\\\/])+[^\\\/\s]*/, "[路径已隐藏]")
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
            changes: [], checks: [], items: [], messages: [], warnings: [],
            workflow_complete: nil, completed_scope: nil, required_followups: nil)
    normalized_command = command.to_s
    raise ArgumentError, "invalid command" unless COMMANDS.include?(normalized_command)
    normalized_status = status.to_s
    normalized_status = "failed" unless STATUSES.include?(normalized_status)
    result = {
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
    workflow_fields = [workflow_complete, completed_scope, required_followups]
    return result if workflow_fields.all?(&:nil?)
    raise ArgumentError, "incomplete workflow metadata" if workflow_fields.any?(&:nil?)
    raise ArgumentError, "invalid workflow_complete" unless [true, false].include?(workflow_complete)
    sanitized_scope = sanitize_text(completed_scope)
    raise ArgumentError, "invalid completed_scope" unless completed_scope.is_a?(String) && !sanitized_scope.empty?
    sanitized_followups = required_followups.map { |entry| sanitize_text(entry) } if required_followups.is_a?(Array)
    raise ArgumentError, "invalid required_followups" unless
      required_followups.is_a?(Array) &&
      required_followups.each_with_index.all? do |entry, index|
        entry.is_a?(String) && !sanitized_followups[index].empty?
      end

    result.merge(
      "workflow_complete" => workflow_complete,
      "completed_scope" => sanitized_scope,
      "required_followups" => sanitized_followups
    )
  end

  def valid_child_json?(text)
    result = JSON.parse(text)
    return false unless result.is_a?(Hash) && (REQUIRED_FIELDS - result.keys).empty?
    return false unless result["schema"] == SCHEMA && result["version"] == VERSION
    return false unless COMMANDS.include?(result["command"]) && result["platform"] == PLATFORM
    return false unless result["client"] == CLIENT && result["operation"].is_a?(String)
    return false unless [true, false].include?(result["ok"]) && STATUSES.include?(result["status"])
    return false unless result["code"].is_a?(String) && result["exit_code"].is_a?(Integer)
    return false unless result["summary_zh"].is_a?(String) &&
                        (result["profile"].nil? || [1, 2, 3].include?(result["profile"]))
    return false unless %w[changes checks items messages warnings].all? { |key| result[key].is_a?(Array) }

    items_valid = result["items"].all? do |item|
      !item.is_a?(Hash) || !item.key?("status") || ITEM_STATUSES.include?(item["status"])
    end
    return false unless items_valid

    workflow_keys = %w[workflow_complete completed_scope required_followups]
    present_workflow_keys = workflow_keys.select { |key| result.key?(key) }
    return true if present_workflow_keys.empty?
    return false unless present_workflow_keys == workflow_keys

    [true, false].include?(result["workflow_complete"]) &&
      result["completed_scope"].is_a?(String) && !sanitize_text(result["completed_scope"]).empty? &&
      result["required_followups"].is_a?(Array) &&
      result["required_followups"].all? do |entry|
        entry.is_a?(String) && !sanitize_text(entry).empty?
      end
  rescue JSON::ParserError, TypeError
    false
  end

  def write(output:, **attributes)
    output.write(JSON.generate(build(**attributes)))
    output.write("\n")
  end

  def emit(**attributes)
    write(output: $stdout, **attributes)
  end

  def cli(argv = ARGV)
    options = {
      messages: [], warnings: [], profile: nil, workflow_complete: nil,
      completed_scope: nil, required_followups: nil
    }
    merge_child_stdin = false
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
      opts.on("--workflow-complete VALUE") do |value|
        raise OptionParser::InvalidArgument, value unless %w[true false].include?(value)
        options[:workflow_complete] = value == "true"
      end
      opts.on("--completed-scope VALUE") { |value| options[:completed_scope] = value }
      opts.on("--required-followup VALUE") do |value|
        options[:required_followups] ||= []
        options[:required_followups] << value
      end
      opts.on("--merge-child-stdin") { merge_child_stdin = true }
    end
    parser.parse!(argv)
    required = %i[command operation ok status code exit_code summary_zh]
    raise OptionParser::MissingArgument, required.find { |key| !options.key?(key) }.to_s unless required.all? { |key| options.key?(key) }

    child = merge_child_stdin ? JSON.parse($stdin.read) : {}
    raise ArgumentError, "invalid child result" unless child.is_a?(Hash)
    workflow_complete = options[:workflow_complete].nil? ? child["workflow_complete"] : options[:workflow_complete]
    completed_scope = options[:completed_scope] || child["completed_scope"]
    required_followups = options[:required_followups] || child["required_followups"]
    emit(**options.merge(
      changes: Array(child["changes"]), checks: Array(child["checks"]),
      items: Array(child["items"]),
      messages: options[:messages] + Array(child["messages"]),
      warnings: options[:warnings] + Array(child["warnings"]),
      workflow_complete: workflow_complete, completed_scope: completed_scope,
      required_followups: required_followups
    ))
    0
  rescue OptionParser::ParseError, ArgumentError, JSON::ParserError
    emit(
      command: "patch", operation: "emit", ok: false, status: "invalid_request",
      code: "invalid_request", exit_code: 64, summary_zh: "结果参数无效。"
    )
    64
  end
end

exit ClaudeEasyResult.cli if $PROGRAM_NAME == __FILE__
