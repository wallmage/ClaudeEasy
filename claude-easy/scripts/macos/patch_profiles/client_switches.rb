module ClaudeEasy
  module_function

  CLIENT_SWITCH_REQUIRED_SDEF_CODES = %w[clashtun clashtog].freeze

  def preference_boolean(value)
    normalized = value.to_s.strip.downcase
    return true if %w[1 true yes].include?(normalized)
    return false if %w[0 false no].include?(normalized)

    nil
  end

  def clashx_script_commands_supported?(identity)
    executable = identity.fetch(:executable).to_s
    suffix = "/Contents/MacOS/ClashX Meta"
    return false unless executable.end_with?(suffix)

    bundle = executable[0, executable.length - suffix.length]
    dictionary = File.join(bundle, "Contents", "Resources", "ProxySetting.sdef")
    return false unless File.file?(dictionary) && !File.symlink?(dictionary)

    source = File.binread(dictionary)
    CLIENT_SWITCH_REQUIRED_SDEF_CODES.all? { |code| source.include?(%(code="#{code}")) }
  rescue StandardError
    false
  end

  def macos_system_proxy_snapshot(runner: Open3.method(:capture3))
    output, _error, status = runner.call("/usr/sbin/scutil", "--proxy")
    return nil unless status.success? && output.include?("<dictionary>")

    fields = output.each_line.each_with_object({}) do |line, values|
      match = line.match(/\A\s*([A-Za-z][A-Za-z0-9]*)\s*:\s*(.*?)\s*\z/)
      values[match[1]] = match[2] if match
    end
    integer = lambda do |key|
      value = fields[key]
      value && value.match?(/\A\d+\z/) ? value.to_i : 0
    end
    enabled = ->(key) { integer.call(key) == 1 }
    {
      http_enabled: enabled.call("HTTPEnable"), http_proxy: fields["HTTPProxy"],
      http_port: integer.call("HTTPPort"),
      https_enabled: enabled.call("HTTPSEnable"), https_proxy: fields["HTTPSProxy"],
      https_port: integer.call("HTTPSPort"),
      socks_enabled: enabled.call("SOCKSEnable"), socks_proxy: fields["SOCKSProxy"],
      socks_port: integer.call("SOCKSPort"),
      pac_enabled: enabled.call("ProxyAutoConfigEnable"),
      auto_discovery_enabled: enabled.call("ProxyAutoDiscoveryEnable")
    }
  rescue StandardError
    nil
  end

  def runtime_client_switch_values(requester)
    status, body = requester.call("GET", "/configs", nil)
    return nil unless status == 200

    config = JSON.parse(body)
    return nil unless config.is_a?(Hash) && config["tun"].is_a?(Hash)

    tun_enabled = config.dig("tun", "enable")
    return nil unless tun_enabled == true || tun_enabled == false

    mixed_port = config["mixed-port"]
    http_port = mixed_port.is_a?(Integer) && mixed_port.positive? ? mixed_port : config["port"]
    socks_port = mixed_port.is_a?(Integer) && mixed_port.positive? ? mixed_port : config["socks-port"]
    return nil unless http_port.is_a?(Integer) && http_port.between?(1, 65_535)
    return nil unless socks_port.is_a?(Integer) && socks_port.between?(1, 65_535)

    {
      tun_effective: tun_enabled ? :enabled : :disabled,
      http_port: http_port, socks_port: socks_port
    }
  rescue JSON::ParserError, StandardError
    nil
  end

  def classify_system_proxy(snapshot, http_port, socks_port)
    return :unknown unless snapshot.is_a?(Hash)
    return :other if snapshot[:pac_enabled] || snapshot[:auto_discovery_enabled]

    enabled = snapshot.values_at(:http_enabled, :https_enabled, :socks_enabled)
    return :disabled unless enabled.any?

    strict_match = enabled.all? &&
                   snapshot.values_at(:http_proxy, :https_proxy, :socks_proxy).all? do |proxy|
                     proxy == "127.0.0.1"
                   end &&
                   snapshot[:http_port] == http_port &&
                   snapshot[:https_port] == http_port &&
                   snapshot[:socks_port] == socks_port
    strict_match ? :clash : :other
  end

  def clashx_client_switch_state(requester: nil, preference_reader: nil, proxy_reader: nil)
    requester ||= current_runtime_requester
    return nil unless requester

    runtime = runtime_client_switch_values(requester)
    return nil unless runtime

    preference_reader ||= method(:defaults_read)
    proxy_reader ||= method(:macos_system_proxy_snapshot)
    tun_intent = preference_boolean(preference_reader.call("restoreTunProxy"))
    system_proxy_intent = preference_boolean(preference_reader.call("proxyPortAutoSet"))
    return nil if tun_intent.nil? || system_proxy_intent.nil?

    system_proxy = classify_system_proxy(
      proxy_reader.call, runtime.fetch(:http_port), runtime.fetch(:socks_port)
    )
    return nil if system_proxy == :unknown

    {
      tun_effective: runtime.fetch(:tun_effective), tun_intent: tun_intent,
      system_proxy_effective: system_proxy, system_proxy_intent: system_proxy_intent
    }
  rescue StandardError
    nil
  end

  def client_switch_state_complete?(state)
    state.is_a?(Hash) &&
      %i[tun_effective tun_intent system_proxy_effective system_proxy_intent].all? do |key|
        state.key?(key)
      end
  end

  def wait_for_client_switch(identity, identity_reader, state_reader, attempts, sleeper)
    attempts.times do |attempt|
      return nil unless same_clashx_process?(identity, identity_reader.call)

      state = state_reader.call
      return state if client_switch_state_complete?(state) && yield(state)

      sleeper.call(0.5) if attempt + 1 < attempts
    end
    nil
  rescue StandardError
    nil
  end

  def manual_client_switch_result(reason, changes = [])
    { status: :manual_required, reason: reason, changes: changes, checks: [] }
  end

  def reconcile_clashx_client_switches(usage_profile:, identity_reader: nil,
                                       command_support_reader: nil, state_reader: nil,
                                       command_sender: nil, connectivity_checker: nil,
                                       sleeper: ->(seconds) { sleep seconds }, attempts: 20)
    return manual_client_switch_result(:invalid_profile) unless [1, 2, 3].include?(usage_profile)

    identity_reader ||= method(:clashx_running_identity)
    identity = identity_reader.call
    return manual_client_switch_result(:client_not_running) unless identity

    command_support_reader ||= method(:clashx_script_commands_supported?)
    return manual_client_switch_result(:native_commands_unavailable) unless
      command_support_reader.call(identity)

    requester = current_runtime_requester if state_reader.nil? || connectivity_checker.nil?
    state_reader ||= -> { clashx_client_switch_state(requester: requester) }
    connectivity_checker ||= lambda do
      mode = usage_profile == 1 ? :disabled : :enabled
      default_connectivity_healthy?(requester: requester, tun_mode: mode)
    end
    command_sender ||= lambda do |current, command|
      request_clashx_script_command(current, command, process_reader: identity_reader)
    end

    state = state_reader.call
    return manual_client_switch_result(:state_unavailable) unless client_switch_state_complete?(state)
    return manual_client_switch_result(:client_changed) unless
      same_clashx_process?(identity, identity_reader.call)

    changes = []
    if usage_profile != 1
      tun_matches = state[:tun_effective] == :enabled && state[:tun_intent] == true
      unless tun_matches
        return manual_client_switch_result(:state_ambiguous, changes) unless
          state[:tun_effective] == :disabled && state[:tun_intent] == false
        return manual_client_switch_result(:native_command_failed, changes) unless
          command_sender.call(identity, :tun_mode)

        changes << :tun
        state = wait_for_client_switch(identity, identity_reader, state_reader, attempts, sleeper) do |current|
          current[:tun_effective] == :enabled && current[:tun_intent] == true
        end
        return manual_client_switch_result(:native_command_unverified, changes) unless state
      end
      return manual_client_switch_result(:connectivity_unverified, changes) unless
        connectivity_checker.call
      return manual_client_switch_result(:client_changed, changes) unless
        same_clashx_process?(identity, identity_reader.call)

      state = state_reader.call
      return manual_client_switch_result(:state_unavailable, changes) unless
        client_switch_state_complete?(state)
      return manual_client_switch_result(:client_changed, changes) unless
        same_clashx_process?(identity, identity_reader.call)
      return manual_client_switch_result(:state_ambiguous, changes) unless
        state[:tun_effective] == :enabled && state[:tun_intent] == true
    end

    target_proxy = usage_profile == 1 ? :enabled : :disabled
    if state[:system_proxy_effective] == :other
      return manual_client_switch_result(:third_party_proxy_active, changes)
    end
    proxy_matches = if target_proxy == :enabled
                      state[:system_proxy_effective] == :clash &&
                        state[:system_proxy_intent] == true
                    else
                      state[:system_proxy_effective] != :clash &&
                        state[:system_proxy_intent] == false
                    end
    unless proxy_matches
      safe_transition = if target_proxy == :enabled
                          state[:system_proxy_effective] == :disabled &&
                            state[:system_proxy_intent] == false
                        else
                          %i[clash disabled].include?(state[:system_proxy_effective]) &&
                            state[:system_proxy_intent] == true
                        end
      return manual_client_switch_result(:state_ambiguous, changes) unless safe_transition
      return manual_client_switch_result(:native_command_failed, changes) unless
        command_sender.call(identity, :system_proxy)

      changes << :system_proxy
      state = wait_for_client_switch(identity, identity_reader, state_reader, attempts, sleeper) do |current|
        if target_proxy == :enabled
          current[:system_proxy_effective] == :clash && current[:system_proxy_intent] == true
        else
          current[:system_proxy_effective] != :clash && current[:system_proxy_intent] == false
        end
      end
      return manual_client_switch_result(:native_command_unverified, changes) unless state
      if usage_profile != 1
        return manual_client_switch_result(:connectivity_unverified, changes) unless
          connectivity_checker.call
      end
    end

    if usage_profile == 1
      return manual_client_switch_result(:connectivity_unverified, changes) unless
        connectivity_checker.call
    end
    return manual_client_switch_result(:client_changed, changes) unless
      same_clashx_process?(identity, identity_reader.call)

    state = state_reader.call
    return manual_client_switch_result(:state_unavailable, changes) unless
      client_switch_state_complete?(state)
    return manual_client_switch_result(:client_changed, changes) unless
      same_clashx_process?(identity, identity_reader.call)
    tun_matches = usage_profile == 1 ||
                  (state[:tun_effective] == :enabled && state[:tun_intent] == true)
    proxy_matches = if usage_profile == 1
                      state[:system_proxy_effective] == :clash &&
                        state[:system_proxy_intent] == true
                    else
                      state[:system_proxy_effective] != :clash &&
                        state[:system_proxy_intent] == false
                    end
    return manual_client_switch_result(:third_party_proxy_active, changes) if
      state[:system_proxy_effective] == :other
    unless tun_matches && proxy_matches
      return manual_client_switch_result(:state_ambiguous, changes)
    end

    {
      status: changes.empty? ? :unchanged : :reconciled,
      reason: nil, changes: changes,
      checks: [
        { "name" => "tun", "status" => state[:tun_effective].to_s },
        { "name" => "system_proxy", "status" => state[:system_proxy_effective].to_s },
        { "name" => "connectivity", "ok" => true }
      ]
    }
  rescue StandardError
    manual_client_switch_result(:unexpected_error, changes || [])
  end
end
