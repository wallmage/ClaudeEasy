#!/usr/bin/env ruby

require "json"
require "socket"
require "stringio"

module ClashRouteBootstrap
  module_function

  def load_dependencies(loader:, argv:, output:)
    %w[patch_profiles result_contract].each { |path| loader.call(path) }
    true
  rescue LoadError
    raise unless argv.include?("--json")

    output.write(JSON.generate(
      "schema" => "claude-easy.result", "version" => 1, "command" => "verify_routes",
      "platform" => "macos", "client" => "clashx-meta", "operation" => "load",
      "ok" => false, "status" => "failed", "code" => "incomplete_package", "exit_code" => 1,
      "summary_zh" => "安装包不完整。", "profile" => nil, "changes" => [], "checks" => [],
      "items" => [], "messages" => [], "warnings" => []
    ) + "\n")
    false
  end
end

dependencies_loaded = ClashRouteBootstrap.load_dependencies(
  loader: ->(path) { require_relative path }, argv: ARGV, output: $stdout
)
exit 1 unless dependencies_loaded

module ClashRouteVerifier
  module_function

  TARGETS = [
    ["Google", "https://www.google.com/search?q=clash-route-verification", :main, /(?:\A|\.)google\.com\z/i],
    ["OpenAI", "https://openai.com/", :ai, /(?:\A|\.)openai\.com\z/i],
    ["Anthropic", "https://www.anthropic.com/", :ai, /(?:\A|\.)anthropic\.com\z/i],
    ["Claude", "https://claude.ai/", :ai, /(?:\A|\.)claude\.ai\z/i]
  ].freeze
  NON_PROXY_TERMINALS = %w[DIRECT REJECT REJECT-DROP COMPATIBLE PASS].freeze
  PROXY_GROUP_TYPES = %w[Selector URLTest Fallback LoadBalance Relay].freeze
  NON_PROXY_TYPES = %w[Direct Dns Reject RejectDrop Pass PassRule Compatible Rematch].freeze

  def get_json(socket, endpoint)
    code, body = ClaudeEasy.controller_request(socket, "GET", endpoint)
    return nil unless code == 200

    JSON.parse(body)
  rescue JSON::ParserError
    nil
  end

  def active_profile
    selected = ClaudeEasy.selected_profile_name
    ClaudeEasy.default_profile_directories.each do |directory|
      path = ClaudeEasy.profile_paths(directory).find { |candidate| ClaudeEasy.active_profile?(candidate, selected) }
      return path if path
    end
    nil
  end

  def reserve_local_port
    listener = TCPServer.new("127.0.0.1", 0)
    listener.local_address.ip_port
  ensure
    listener&.close
  end

  def observe_connection(socket, url, host_pattern)
    existing = Array(get_json(socket, "/connections")&.fetch("connections", [])).map { |entry| entry["id"] }
    source_port = reserve_local_port
    pid = Process.spawn(
      "/usr/bin/curl", "--http1.1", "--fail", "-L", "--max-time", "15", "--limit-rate", "2k",
      "--local-port", source_port.to_s, url,
      out: File::NULL, err: File::NULL
    )
    100.times do
      sleep 0.1
      connections = Array(get_json(socket, "/connections")&.fetch("connections", []))
      observed = connections.find do |entry|
        metadata = entry["metadata"] || {}
        !existing.include?(entry["id"]) &&
          metadata["host"].to_s.match?(host_pattern) &&
          metadata["network"].to_s.casecmp("tcp").zero? &&
          metadata["sourcePort"].to_i == source_port
      end
      return observed if observed
    end
    nil
  ensure
    terminate_process(pid) if pid
  end

  def terminate_process(pid, grace_seconds: 1)
    Process.kill("TERM", pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + grace_seconds
    loop do
      return if Process.waitpid(pid, Process::WNOHANG)
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.02
    end
    Process.kill("KILL", pid)
    Process.waitpid(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def non_proxy_terminal?(name)
    NON_PROXY_TERMINALS.any? { |terminal| terminal.casecmp(name.to_s).zero? }
  end

  def selectionless_main_group?(proxies, group)
    proxies.dig(group, "type").to_s.casecmp("LoadBalance").zero?
  end

  def proxy_group_type?(type)
    PROXY_GROUP_TYPES.any? { |group_type| group_type.casecmp(type.to_s).zero? }
  end

  def live_chain_proxy(proxies, providers, name, provider_name)
    unless provider_name.to_s.empty?
      provider = providers[provider_name]
      return nil unless provider.is_a?(Hash)

      return Array(provider["proxies"]).find do |proxy|
        proxy.is_a?(Hash) && proxy["name"].to_s == name.to_s
      end
    end
    proxies[name]
  end

  def safe_live_chain?(chains, provider_chains, proxies, providers)
    return false if chains.empty?

    chains.each_with_index do |name, index|
      return false if non_proxy_terminal?(name)

      proxy = live_chain_proxy(proxies, providers, name, provider_chains[index])
      return false unless proxy.is_a?(Hash)

      type = proxy["type"].to_s
      return false if type.empty? ||
                      NON_PROXY_TYPES.any? { |blocked| blocked.casecmp(type).zero? }
      return false if index.zero? && proxy_group_type?(type)
    end
    true
  end

  def route_passes?(chains, proxies:, kind:, expected_group:, expected_selection:, ai_group:,
                    providers: {}, provider_chains: [])
    return false unless safe_live_chain?(chains, provider_chains, proxies, providers)

    expected_proxy = proxies[expected_group]
    return false unless expected_proxy.is_a?(Hash) && proxy_group_type?(expected_proxy["type"])
    return chains.include?(expected_group) if kind == :ai

    return false if chains.include?(ai_group)
    return true if chains.include?(expected_group)

    chains.each_with_index.any? do |name, index|
      next false unless name.match?(/google/i)

      proxy = live_chain_proxy(proxies, providers, name, provider_chains[index])
      proxy.is_a?(Hash) && proxy_group_type?(proxy["type"])
    end
  end

  def run(output: $stdout, details: nil)
    socket = ClaudeEasy.controller_socket
    path = active_profile
    return false unless socket && path

    policy_path = File.expand_path("../../references/policy.json", __dir__)
    policy = JSON.parse(File.read(policy_path, encoding: "UTF-8"))
    config = ClaudeEasy.load_yaml(File.read(path, encoding: "UTF-8"), path)
    main_group = ClaudeEasy.detect_main_group(config, policy)
    ai_group = ClaudeEasy.existing_ai_group(config, policy)&.fetch("name", nil)
    return false unless main_group && ai_group

    proxies = get_json(socket, "/proxies")&.fetch("proxies", {})
    return false unless proxies.is_a?(Hash)
    provider_payload = get_json(socket, "/providers/proxies")
    return false unless provider_payload.is_a?(Hash)

    providers = provider_payload.fetch("providers", {})
    return false unless providers.is_a?(Hash)

    expected = { main: main_group, ai: ai_group }
    selections = {
      main: proxies.dig(main_group, "now").to_s,
      ai: proxies.dig(ai_group, "now").to_s
    }
    return false if selections.fetch(:ai).empty? || non_proxy_terminal?(selections.fetch(:ai))
    if selections.fetch(:main).empty?
      return false unless selectionless_main_group?(proxies, main_group)
    elsif non_proxy_terminal?(selections.fetch(:main))
      return false
    end

    main_selection = selections.fetch(:main)
    main_selection = "动态选择" if main_selection.empty?
    output.puts "主代理组：#{ClaudeEasy.safe_label(main_group)} → #{ClaudeEasy.safe_label(main_selection)}"
    output.puts "AI 分组：#{ClaudeEasy.safe_label(ai_group)} → #{ClaudeEasy.safe_label(selections.fetch(:ai))}"

    checks = TARGETS.map do |label, url, kind, host_pattern|
      connection = observe_connection(socket, url, host_pattern)
      chains = Array(connection && connection["chains"])
      provider_chains = Array(connection && connection["providerChains"])
      ok = route_passes?(
        chains, provider_chains: provider_chains, proxies: proxies, providers: providers,
        kind: kind, expected_group: expected.fetch(kind),
        expected_selection: selections.fetch(kind), ai_group: ai_group
      )
      selected = chains.first
      output.puts "#{label}：#{ok ? '通过' : '失败'}（#{ClaudeEasy.safe_label(selected)}）"
      details[:checks] << { "name" => label.downcase, "ok" => ok } if details
      ok
    end
    checks.all?
  rescue StandardError
    false
  end

  def cli(argv = ARGV, output: $stdout)
    unknown = argv.reject { |argument| argument == "--json" }
    unless unknown.empty?
      json_mode = argv.include?("--json")
      if json_mode
        ClaudeEasyResult.write(
          output: output, command: "verify_routes", operation: "verify_routes", ok: false,
          status: "invalid_request", code: "invalid_arguments", exit_code: 64,
          summary_zh: "参数错误。", profile: nil, changes: [], checks: [], items: [],
          messages: [], warnings: []
        )
      end
      return 64
    end
    json_mode = argv.include?("--json")
    details = { checks: [] }
    ok = run(output: json_mode ? StringIO.new : output, details: details)
    exit_code = ok ? 0 : 1
    if json_mode
      ClaudeEasyResult.write(
        output: output, command: "verify_routes", operation: "verify_routes", ok: ok,
        status: ok ? "ok" : "failed", code: ok ? "routes_verified" : "route_verification_failed",
        exit_code: exit_code, summary_zh: ok ? "实时分流验证通过。" : "实时分流验证未通过。",
        profile: nil, changes: [], checks: details.fetch(:checks), items: [], messages: [], warnings: []
      )
    end
    exit_code
  end
end

exit ClashRouteVerifier.cli if $PROGRAM_NAME == __FILE__
