#!/usr/bin/env ruby

require "json"
require "optparse"
require "socket"
require "stringio"

module ClashRouteBootstrap
  module_function

  def load_dependencies(loader:, argv:, output:)
    %w[patch_profiles result_contract].each { |path| loader.call(path) }
    true
  rescue LoadError, SyntaxError
    if argv.include?("--json")
      output.write(JSON.generate(
        "schema" => "claude-easy.result", "version" => 1, "command" => "verify_routes",
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

dependencies_loaded = ClashRouteBootstrap.load_dependencies(
  loader: ->(path) { require_relative path }, argv: ARGV, output: $stdout
)
exit 6 unless dependencies_loaded

module ClashRouteVerifier
  module_function

  TARGETS = [
    ["ChatGPT", "https://chatgpt.com/", :ai, /(?:\A|\.)chatgpt\.com\z/i],
    ["Gemini", "https://gemini.google.com/", :ai, /\Agemini\.google\.com\z/i],
    ["Grok", "https://grok.com/", :ai, /(?:\A|\.)grok\.com\z/i]
  ].freeze
  NON_PROXY_TERMINALS = %w[
    DIRECT DNS REJECT REJECT-DROP PASS PASS-RULE COMPATIBLE REMATCH RELAY
  ].freeze
  PROXY_GROUP_TYPES = %w[Selector URLTest Fallback LoadBalance].freeze
  NON_PROXY_TYPES = %w[Direct Dns Reject RejectDrop Pass PassRule Compatible Rematch Relay].freeze

  def controller_requester(controller)
    return controller if controller.respond_to?(:call)

    ->(method, endpoint, body = nil) { ClaudeEasy.controller_request(controller, method, endpoint, body) }
  end

  def get_json(controller, endpoint)
    code, body = controller_requester(controller).call("GET", endpoint, nil)
    return nil unless code == 200

    JSON.parse(body)
  rescue JSON::ParserError
    nil
  end

  def reserve_local_port
    listener = TCPServer.new("127.0.0.1", 0)
    listener.local_address.ip_port
  ensure
    listener&.close
  end

  def observe_connection(controller, url, host_pattern, observation_seconds: 15,
                         proxy_url: nil)
    requester = controller_requester(controller)
    unless proxy_url
      proxy_url = ClaudeEasy.runtime_loopback_proxy(requester)
    end
    return nil unless ClaudeEasy.mihomo_loopback_proxy_url?(proxy_url)

    existing = Array(get_json(requester, "/connections")&.fetch("connections", [])).map { |entry| entry["id"] }
    source_port = reserve_local_port
    pid = Process.spawn(
      ClaudeEasy::CURL_ISOLATED_ENVIRONMENT,
      "/usr/bin/curl", "-q", "--proxy", proxy_url,
      "--http1.1", "--fail", "-L", "--max-time", "15", "--limit-rate", "2k",
      "--local-port", source_port.to_s, url,
      out: File::NULL, err: File::NULL
    )
    (observation_seconds * 10).times do
      sleep 0.1
      connections = Array(get_json(requester, "/connections")&.fetch("connections", []))
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

  def proxy_group_type?(type)
    PROXY_GROUP_TYPES.any? { |group_type| group_type.casecmp(type.to_s).zero? }
  end

  def usable_route_group_selection?(proxies, group)
    proxy = proxies[group]
    return false unless proxy.is_a?(Hash) && proxy_group_type?(proxy["type"])

    selection = proxy["now"].to_s
    return proxy["type"].to_s.casecmp("LoadBalance").zero? if selection.empty?

    !non_proxy_terminal?(selection)
  end

  def find_group(proxies, candidates, requested = nil, ai: false)
    unless requested.to_s.empty?
      proxy = proxies[requested]
      return requested if proxy.is_a?(Hash) && proxy_group_type?(proxy["type"])

      return nil
    end

    Array(candidates).each do |candidate|
      proxy = proxies[candidate]
      return candidate if proxy.is_a?(Hash) && proxy_group_type?(proxy["type"])
    end
    return nil unless ai

    proxies.each do |name, proxy|
      next unless proxy.is_a?(Hash) && proxy_group_type?(proxy["type"])
      return name if name.to_s.match?(/(?:\A|[^A-Za-z])AI(?:[^A-Za-z]|\z)|OpenAI|人工智能|🤖/i)
    end
    nil
  end

  def live_main_group(controller, proxies, requested = nil)
    unless requested.to_s.empty?
      proxy = proxies[requested]
      return requested if proxy.is_a?(Hash) && proxy_group_type?(proxy["type"])

      return nil
    end

    rules = get_json(controller, "/rules")&.fetch("rules", nil)
    return nil unless rules.is_a?(Array)

    rule = rules.reverse.find do |entry|
      entry.is_a?(Hash) && entry["type"].to_s.casecmp("MATCH").zero?
    end
    group = rule && rule["proxy"].to_s
    proxy = proxies[group]
    return nil unless proxy.is_a?(Hash) && proxy_group_type?(proxy["type"])

    group
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

    return false if expected_group != ai_group && chains.include?(ai_group)
    chains.include?(expected_group)
  end

  def run(output: $stdout, details: nil, main_group: nil, ai_group: nil,
          observation_seconds: 15)
    requester = ClaudeEasy.controller_requester
    return false unless requester

    policy_path = File.expand_path("../../references/policy.json", __dir__)
    policy = JSON.parse(File.read(policy_path, encoding: "UTF-8"))
    proxies = get_json(requester, "/proxies")&.fetch("proxies", {})
    return false unless proxies.is_a?(Hash)
    main_group = live_main_group(requester, proxies, main_group)
    ai_group = find_group(proxies, policy["ai_group_names"], ai_group, ai: true)
    return false unless main_group && ai_group && usable_route_group_selection?(proxies, main_group) &&
                                               usable_route_group_selection?(proxies, ai_group)

    provider_payload = get_json(requester, "/providers/proxies")
    return false unless provider_payload.is_a?(Hash)

    providers = provider_payload.fetch("providers", {})
    return false unless providers.is_a?(Hash)

    expected = { main: main_group, ai: ai_group }
    selections = {
      main: proxies.dig(main_group, "now").to_s,
      ai: proxies.dig(ai_group, "now").to_s
    }

    output.puts "主代理组：已识别；当前选择已隐藏"
    output.puts "AI 分组：已识别；当前选择已隐藏"

    checks = TARGETS.map do |label, url, kind, host_pattern|
      connection = observe_connection(
        requester, url, host_pattern, observation_seconds: observation_seconds
      )
      current_proxies = get_json(requester, "/proxies")&.fetch("proxies", {})
      current_provider_payload = get_json(requester, "/providers/proxies")
      current_main = current_proxies.is_a?(Hash) ? live_main_group(requester, current_proxies) : nil
      current_ai = current_proxies.is_a?(Hash) ? find_group(
        current_proxies, policy["ai_group_names"], nil, ai: true
      ) : nil
      snapshot_stable = current_provider_payload.is_a?(Hash) &&
                        current_main == main_group && current_ai == ai_group &&
                        current_proxies.dig(main_group, "now").to_s == selections[:main] &&
                        current_proxies.dig(ai_group, "now").to_s == selections[:ai]
      chains = Array(connection && connection["chains"])
      provider_chains = Array(connection && connection["providerChains"])
      ok = snapshot_stable && route_passes?(
        chains, provider_chains: provider_chains, proxies: current_proxies,
        providers: current_provider_payload.fetch("providers", {}),
        kind: kind, expected_group: expected.fetch(kind),
        expected_selection: selections.fetch(kind), ai_group: ai_group
      )
      output.puts "#{label}：#{ok ? '通过' : '失败'}"
      status = if connection.nil?
                 "not_observed"
               else
                 ok ? "passed" : "failed"
               end
      details[:checks] << {
        "name" => label.downcase, "ok" => ok,
        "status" => status
      } if details
      ok
    end
    checks.all?
  rescue StandardError
    false
  end

  def cli(argv = ARGV, output: $stdout, profile_reader: ClaudeEasy.method(:saved_usage_profile))
    json_mode = argv.include?("--json")
    options = {
      main_group: nil, ai_group: nil, observation_seconds: 15,
      json: json_mode, help: false
    }
    parser = OptionParser.new do |opts|
      opts.banner = "用法：verify_routes.rb [选项]"
      opts.on("--main-group NAME", "指定当前运行配置的主代理组") { |value| options[:main_group] = value }
      opts.on("--ai-group NAME", "指定当前运行配置的 AI 分组") { |value| options[:ai_group] = value }
      opts.on("--observation-seconds N", Integer, "每项连接的观察秒数（1–60）") do |value|
        options[:observation_seconds] = value
      end
      opts.on("--json", "输出 JSON v1 结果") { options[:json] = true }
      opts.on("-h", "--help", "显示帮助") { options[:help] = true }
    end
    begin
      parser.parse!(argv)
      raise OptionParser::InvalidArgument, "观察时间必须为 1 到 60 秒" unless
        options[:observation_seconds].between?(1, 60)
      raise OptionParser::InvalidArgument, "代理组名称不能为空" if
        [options[:main_group], options[:ai_group]].compact.any? { |value| value.strip.empty? }
    rescue OptionParser::ParseError
      if json_mode
        ClaudeEasyResult.write(
          output: output, command: "verify_routes", operation: "verify_routes", ok: false,
          status: "invalid_request", code: "invalid_arguments", exit_code: 64,
          summary_zh: "参数错误。", profile: nil, changes: [], checks: [], items: [],
          messages: [], warnings: []
        )
      else
        output.puts "参数错误。"
      end
      return 64
    end
    if options[:help]
      if options[:json]
        ClaudeEasyResult.write(
          output: output, command: "verify_routes", operation: "help", ok: true,
          status: "ok", code: "help", exit_code: 0, summary_zh: "已显示帮助。"
        )
      else
        output.puts parser
      end
      return 0
    end

    profile_code = nil
    profile_summary = nil
    saved_profile = nil
    begin
      saved_profile = profile_reader.call
      if saved_profile.nil?
        profile_code = "usage_profile_unset"
        profile_summary = "尚未保存用途档位，未执行分流验证。"
      elsif saved_profile != 3
        profile_code = "usage_profile_mismatch"
        profile_summary = "分流验证仅适用于已保存的档位 3。"
      end
    rescue ClaudeEasy::InvalidConfigError
      profile_code = "usage_profile_invalid"
      profile_summary = "已保存的用途档位状态无效，未执行分流验证。"
    end
    if profile_code
      if options[:json]
        ClaudeEasyResult.write(
          output: output, command: "verify_routes", operation: "verify_routes", ok: false,
          status: "invalid_request", code: profile_code, exit_code: 10,
          summary_zh: profile_summary, profile: saved_profile, changes: [], checks: [], items: [],
          messages: [], warnings: []
        )
      else
        output.puts profile_summary
      end
      return 10
    end

    details = { checks: [] }
    ok = run(
      output: options[:json] ? StringIO.new : output, details: details,
      main_group: options[:main_group], ai_group: options[:ai_group],
      observation_seconds: options[:observation_seconds]
    )
    exit_code = ok ? 0 : 1
    if options[:json]
      ClaudeEasyResult.write(
        output: output, command: "verify_routes", operation: "verify_routes", ok: ok,
        status: ok ? "ok" : "failed", code: ok ? "routes_verified" : "route_verification_failed",
        exit_code: exit_code, summary_zh: ok ? "实时分流验证通过。" : "实时分流验证未通过。",
        profile: saved_profile, changes: [], checks: details.fetch(:checks), items: [], messages: [], warnings: []
      )
    else
      output.puts(ok ? "实时分流验证通过。" : "实时分流验证未通过。")
    end
    exit_code
  end
end

exit ClashRouteVerifier.cli if $PROGRAM_NAME == __FILE__
