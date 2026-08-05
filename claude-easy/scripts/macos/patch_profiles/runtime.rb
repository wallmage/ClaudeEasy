module ClaudeEasy
  module_function

  RUNTIME_NON_PROXY_NAMES = %w[
    DIRECT DNS REJECT REJECT-DROP PASS PASS-RULE COMPATIBLE REMATCH
  ].freeze
  RUNTIME_NON_PROXY_TYPES = %w[
    Direct Dns Reject RejectDrop Pass PassRule Compatible Rematch Relay
  ].freeze
  RUNTIME_PROXY_GROUP_TYPES = %w[Selector URLTest Fallback LoadBalance].freeze

  CURL_ISOLATED_ENVIRONMENT = {
    "http_proxy" => nil, "https_proxy" => nil, "all_proxy" => nil,
    "HTTP_PROXY" => nil, "HTTPS_PROXY" => nil, "ALL_PROXY" => nil,
    "no_proxy" => nil, "NO_PROXY" => nil
  }.freeze

  def controller_socket
    cache_directories = [
      File.expand_path("~/Library/Caches/com.MetaCubeX.ClashX.meta/cacheConfigs"),
      File.expand_path("~/Library/Caches/com.metacubex.ClashX.meta/cacheConfigs")
    ]
    cache_directories.each do |directory|
      candidates = Dir.glob(File.join(directory, "*.yaml")).each_with_object([]) do |path, entries|
        entries << [path, File.mtime(path)]
      rescue SystemCallError
        next
      end
      candidates.sort_by { |_path, modified| modified }.reverse_each do |path, _modified|
        config = load_yaml(File.read(path, encoding: "UTF-8"), path)
        socket = config["external-controller-unix"] if config.is_a?(Hash)
        return socket if socket.is_a?(String) && File.socket?(socket)
      rescue StandardError
        next
      end
    end
    nil
  end

  def controller_request(socket, method, path, body = nil)
    arguments = ["/usr/bin/curl", "-q", "-sS", "--proxy", "", "--noproxy", "*",
                 "--max-time", "3", "-X", method, "--unix-socket", socket,
                 "-o", "-", "-w", "\n%{http_code}"]
    arguments.concat(["-H", "Content-Type: application/json", "--data", body]) if body
    arguments << "http://localhost#{path}"
    output, status = Open3.capture2e(CURL_ISOLATED_ENVIRONMENT, *arguments)
    return [0, ""] unless status.success?

    response_body, code = output.rpartition("\n").values_at(0, 2)
    [code.to_i, response_body]
  rescue StandardError
    [0, ""]
  end

  def tun_state(socket: nil, requester: nil)
    if requester.nil?
      socket ||= controller_socket
      return :unknown unless socket

      requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    end

    request = requester
    status, body = request.call("GET", "/configs", nil)
    return :unknown unless status == 200

    config = JSON.parse(body)
    return :unknown unless config.is_a?(Hash) && config["tun"].is_a?(Hash)

    enabled = config.dig("tun", "enable")
    return :enabled if enabled == true
    return :disabled if enabled == false

    :unknown
  rescue JSON::ParserError
    :unknown
  end

  def runtime_proxies(requester)
    status, body = requester.call("GET", "/proxies", nil)
    return nil unless status == 200

    payload = JSON.parse(body)
    proxies = payload["proxies"]
    proxies if proxies.is_a?(Hash)
  rescue JSON::ParserError
    nil
  end

  def runtime_selections(requester)
    proxies = runtime_proxies(requester)
    return nil unless proxies

    proxies.each_with_object({}) do |(name, proxy), selections|
      next unless proxy.is_a?(Hash) && proxy["now"].is_a?(String)
      next unless proxy["type"].to_s.casecmp("Selector").zero?

      selections[name] = proxy["now"]
    end
  end

  def runtime_provider_proxies(requester)
    status, body = requester.call("GET", "/providers/proxies", nil)
    return nil unless status == 200

    providers = JSON.parse(body)["providers"]
    return nil unless providers.is_a?(Hash)

    providers.each_value.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |provider, proxies|
      next unless provider.is_a?(Hash)

      Array(provider["proxies"]).each do |proxy|
        next unless proxy.is_a?(Hash) && !proxy["name"].to_s.empty?

        proxies[proxy["name"]] << proxy
      end
    end
  rescue JSON::ParserError
    nil
  end

  def runtime_non_proxy_name?(name)
    RUNTIME_NON_PROXY_NAMES.any? { |blocked| blocked.casecmp(name.to_s).zero? }
  end

  def runtime_non_proxy_type?(type)
    RUNTIME_NON_PROXY_TYPES.any? { |blocked| blocked.casecmp(type.to_s).zero? }
  end

  def runtime_proxy_group_type?(type)
    RUNTIME_PROXY_GROUP_TYPES.any? { |group_type| group_type.casecmp(type.to_s).zero? }
  end

  def runtime_proxy_path_safe?(proxies, name, seen = {})
    return false unless proxies.is_a?(Hash) && name.is_a?(String) && !name.empty?
    return false if runtime_non_proxy_name?(name) || seen[name]

    proxy = proxies[name]
    return false unless proxy.is_a?(Hash)

    type = proxy["type"].to_s
    return false if type.empty? || runtime_non_proxy_type?(type)
    unless runtime_proxy_group_type?(type)
      return false if proxy.key?("now") || proxy.key?("all")
      return true
    end

    visited = seen.merge(name => true)
    if type.casecmp("LoadBalance").zero?
      members = proxy["all"]
      return false unless members.is_a?(Array) && !members.empty?

      members.all? { |member| runtime_proxy_path_safe?(proxies, member, visited) }
    else
      runtime_proxy_path_safe?(proxies, proxy["now"], visited)
    end
  end

  def runtime_proxy_candidate_safe?(proxies, provider_proxies, proxy, seen)
    return false unless proxy.is_a?(Hash)

    type = proxy["type"].to_s
    return false if type.empty? || runtime_non_proxy_type?(type)
    unless runtime_proxy_group_type?(type)
      return false if proxy.key?("now") || proxy.key?("all")
      return true
    end

    if type.casecmp("LoadBalance").zero?
      members = proxy["all"]
      return false unless members.is_a?(Array) && !members.empty?

      members.all? do |member|
        runtime_proxy_candidates_safe?(proxies, provider_proxies, member, seen)
      end
    else
      runtime_proxy_candidates_safe?(proxies, provider_proxies, proxy["now"], seen)
    end
  end

  def runtime_proxy_candidates_safe?(proxies, provider_proxies, name, seen)
    return false unless name.is_a?(String) && !name.empty?
    return false if runtime_non_proxy_name?(name) || seen[name]

    candidates = []
    candidates << proxies[name] if proxies[name].is_a?(Hash)
    candidates.concat(Array(provider_proxies[name]))
    return false if candidates.empty?

    visited = seen.merge(name => true)
    candidates.all? do |proxy|
      runtime_proxy_candidate_safe?(proxies, provider_proxies, proxy, visited)
    end
  end

  def runtime_proxy_group_safe?(requester, group, proxies: nil)
    proxies ||= runtime_proxies(requester)
    return false unless proxies.is_a?(Hash)

    provider_proxies = runtime_provider_proxies(requester)
    return false unless provider_proxies.is_a?(Hash)
    return false if runtime_non_proxy_name?(group)

    root = proxies[group]
    return false unless root.is_a?(Hash) && runtime_proxy_group_type?(root["type"])

    runtime_proxy_candidate_safe?(proxies, provider_proxies, root, { group => true })
  rescue StandardError
    false
  end

  def profile_ai_runtime_group(path, policy: nil)
    config = load_yaml(File.read(path, encoding: "UTF-8"), path)
    rules = Array(config["rules"])
    first = rule_info(rules[0])
    second = rule_info(rules[1])
    return nil unless first[:type] == "NETWORK" && first[:payload].to_s.casecmp("UDP").zero? &&
                      second[:type] == "NETWORK" && second[:payload].to_s.casecmp("UDP").zero? &&
                      second[:target].to_s.casecmp("REJECT").zero?

    target = first[:target].to_s
    return nil unless selectable_groups(config).any? { |group| group["name"] == target }

    if policy
      required = render_ai_rules(policy, target).map { |rule| managed_rule_identity(rule) }
      return nil if required.empty? || required.any?(&:nil?)

      identities = rules.map { |rule| managed_rule_identity(rule) }
      positions = required.map { |identity| identities.index(identity) }
      return nil if positions.any?(&:nil?)

      first_broad = rules.index { |rule| broad_rule?(rule) }
      return nil if first_broad && positions.any? { |position| position >= first_broad }
    end

    target
  rescue StandardError
    nil
  end

  def restore_candidate_valid?(path, usage_profile, policy: nil, validator: nil)
    validator ||= method(:validate_with_mihomo)
    validation = validator.call(path)
    return :timeout if validation == :timeout
    return false unless validation == true

    usage_profile != 3 || (policy && !profile_ai_runtime_group(path, policy: policy).nil?)
  rescue StandardError
    false
  end

  def runtime_selections_for_profile(selections, path, require_all: false)
    return nil unless selections.is_a?(Hash)

    config = load_yaml(File.read(path, encoding: "UTF-8"), path)
    selector_names = selectable_groups(config).map { |group| group.fetch("name") }
    return {} if selector_names.empty?
    return nil if require_all && !selector_names.all? { |name| selections.key?(name) }

    selections.select { |name, _selected| selector_names.include?(name) }
  rescue StandardError
    nil
  end

  def dns_runtime_healthy?(requester, name)
    status, body = requester.call("GET", "/dns/query?name=#{name}&type=A", nil)
    return false unless status == 200

    payload = JSON.parse(body)
    dns_status = payload["Status"] || payload["status"]
    answers = payload["Answer"] || payload["answer"]
    dns_status.to_i.zero? && answers.is_a?(Array) && !answers.empty?
  rescue JSON::ParserError
    false
  end

  def runtime_loopback_proxy(requester)
    status, body = requester.call("GET", "/configs", nil)
    return nil unless status == 200

    config = JSON.parse(body)
    return nil unless config.is_a?(Hash)

    [["mixed-port", "http"], ["port", "http"], ["socks-port", "socks5h"]].each do |key, scheme|
      port = config[key]
      next unless port.is_a?(Integer) && port.between?(1, 65_535)

      return "#{scheme}://127.0.0.1:#{port}"
    end
    nil
  rescue JSON::ParserError, SystemCallError, IOError
    nil
  end

  def default_connectivity_healthy?(requester: nil, tun_mode: :enabled)
    proxy = if tun_mode == :enabled
              ""
            else
              return false unless requester

              runtime_loopback_proxy(requester)
            end
    return false unless proxy

    arguments = [
      "/usr/bin/curl", "-q", "-sS", "--fail", "--proxy", proxy,
      "--max-time", "8", "-o", "/dev/null"
    ]
    arguments.concat(["--noproxy", "*"]) if tun_mode == :enabled
    arguments << "https://www.google.com/generate_204"
    3.times do
      _output, status = Open3.capture2e(CURL_ISOLATED_ENVIRONMENT, *arguments)
      return true if status.success?
    rescue StandardError
      next
    end
    false
  end

  def harmless_proxy_request_healthy?(requester)
    proxy = runtime_loopback_proxy(requester)
    return false unless proxy

    _output, status = Open3.capture2e(
      CURL_ISOLATED_ENVIRONMENT,
      "/usr/bin/curl", "-q", "-sS", "--fail", "--proxy", proxy,
      "--max-time", "8", "-o", "/dev/null", "https://www.google.com/generate_204"
    )
    status.success?
  rescue StandardError
    false
  end

  def profile_result_current?(result)
    expected = result[:patched_digest]
    identity = result[:patched_identity]
    expected_path = result[:patched_path]
    path = result[:path]
    return false unless
      expected.is_a?(String) && expected.match?(/\A[0-9a-f]{64}\z/) &&
      identity.is_a?(Array) && identity.length == 2 &&
      identity.all? { |value| value.is_a?(Integer) && value >= 0 } &&
      expected_path.is_a?(String) && expected_path == File.expand_path(expected_path) &&
      path.is_a?(String)

    write_path = File.realpath(path)
    return false unless write_path == expected_path

    current = regular_file_snapshot_once(write_path, "已提交配置")
    current.fetch(:identity) == identity &&
      Digest::SHA256.hexdigest(current.fetch(:bytes)) == expected
  rescue SystemCallError, IOError, InvalidConfigError
    false
  end

  def restore_profile_bytes(result)
    original = result[:rollback_bytes]
    return false unless original.is_a?(String) && profile_result_current?(result)

    path = result.fetch(:path)
    current = File.binread(result.fetch(:patched_path))

    transactional_compare_and_write_bytes(
      path, current, original,
      expected_identity: result.fetch(:patched_identity),
      expected_path: result.fetch(:patched_path)
    )
  rescue SystemCallError, IOError, KeyError
    false
  end

  def runtime_health_healthy?(requester, selections:, expected_tun:, connectivity_checker: nil,
                              precommit_condition: nil, required_proxy_group: nil,
                              flush_caches: true)
    return false unless runtime_precommit_allowed?(precommit_condition)

    if flush_caches
      caches_flushed = ["/cache/fakeip/flush", "/cache/dns/flush"].all? do |endpoint|
        code, _body = requester.call("POST", endpoint, nil)
        [200, 204].include?(code)
      end
      return false unless caches_flushed
    end
    return false if expected_tun != :ignore && tun_state(requester: requester) != expected_tun

    proxies = runtime_proxies(requester)
    return false unless proxies

    after = proxies.each_with_object({}) do |(name, proxy), current|
      next unless proxy.is_a?(Hash) && proxy["now"].is_a?(String)
      next unless proxy["type"].to_s.casecmp("Selector").zero?

      current[name] = proxy["now"]
    end
    return false unless after.is_a?(Hash) && selections.is_a?(Hash)
    return false unless selections.all? { |name, selected| after.key?(name) && after[name] == selected }
    return false if required_proxy_group &&
                    !runtime_proxy_group_safe?(requester, required_proxy_group, proxies: proxies)
    return false unless dns_runtime_healthy?(requester, "www.baidu.com")
    return false unless dns_runtime_healthy?(requester, "www.google.com")

    connectivity_checker ||= lambda do
      default_connectivity_healthy?(requester: requester, tun_mode: expected_tun)
    end
    return false unless connectivity_checker.call

    runtime_precommit_allowed?(precommit_condition)
  rescue StandardError
    false
  end

  def reload_recovered_profile_runtime(work_items, require_tun:, socket: nil, requester: nil,
                                       connectivity_checker: nil, precommit_condition: nil)
    active = work_items.find { |item| item.fetch(:active) }
    return true unless active

    if requester.nil?
      socket ||= controller_socket
      return false unless socket

      requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    end
    selections = runtime_selections(requester)
    return false unless selections

    selections = runtime_selections_for_profile(selections, active.fetch(:path))
    return false unless selections
    expected_tun = if require_tun == :preserve
                     tun_state(requester: requester)
                   elsif require_tun
                     :enabled
                   else
                     :ignore
                   end
    return false if expected_tun == :unknown
    return false unless runtime_precommit_allowed?(precommit_condition)

    code, _body = requester.call(
      "PUT", "/configs?force=true", JSON.generate("path" => File.expand_path(active.fetch(:path)))
    )
    return false unless code == 204

    healthy = runtime_health_healthy?(
      requester, selections: selections, expected_tun: expected_tun,
      connectivity_checker: connectivity_checker,
      precommit_condition: precommit_condition
    )
    healthy && runtime_precommit_allowed?(precommit_condition)
  rescue StandardError
    false
  end

  def verify_unchanged_profile_runtime(result, socket: nil, requester: nil,
                                       connectivity_checker: nil, precommit_condition: nil,
                                       require_tun: false, require_safe_ai: false)
    if requester.nil?
      socket ||= controller_socket
      return result.merge(status: :runtime_check_failed) unless socket

      requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    end
    selections = runtime_selections(requester)
    return result.merge(status: :runtime_check_failed) unless selections

    selections = runtime_selections_for_profile(
      selections, result.fetch(:path), require_all: true
    )
    return result.merge(status: :runtime_check_failed) unless selections
    group = profile_ai_runtime_group(result.fetch(:path)) if require_safe_ai
    return result.merge(status: :runtime_check_failed) if require_safe_ai && !group
    healthy = runtime_precommit_allowed?(precommit_condition) &&
              runtime_health_healthy?(
                requester, selections: selections,
                expected_tun: require_tun ? :enabled : :ignore,
                connectivity_checker: connectivity_checker,
                precommit_condition: precommit_condition,
                required_proxy_group: group, flush_caches: false
              ) &&
              runtime_precommit_allowed?(precommit_condition)
    healthy ? result : result.merge(status: :runtime_check_failed)
  rescue StandardError
    result.merge(status: :runtime_check_failed)
  end

  def activate_updated_profile(result, socket: nil, requester: nil, connectivity_checker: nil,
                               require_tun: true, precommit_condition: nil,
                               require_safe_ai: false)
    pending = -> { result.merge(status: :reload_failed_restore_pending) }
    return pending.call unless profile_result_current?(result)

    if requester.nil?
      socket ||= controller_socket
      return result.merge(
        status: rollback_after_reload_failure(
          result, nil, nil, precommit_condition: precommit_condition
        )
      ) unless socket

      requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    end
    before = runtime_selections(requester)
    unless before
      return result.merge(
        status: rollback_after_reload_failure(
          result, requester, result[:path], precommit_condition: precommit_condition
        )
      )
    end
    expected_tun = if require_tun == :preserve
                     tun_state(requester: requester)
                   elsif require_tun
                     :enabled
                   else
                     :ignore
                   end
    rollback = lambda do
      rollback_after_reload_failure(
        result, requester, result[:path], selections: before, expected_tun: expected_tun,
        connectivity_checker: connectivity_checker, precommit_condition: precommit_condition
      )
    end
    return result.merge(status: rollback.call) if expected_tun == :unknown
    candidate_selections = runtime_selections_for_profile(before, result.fetch(:path))
    return result.merge(status: rollback.call) unless candidate_selections
    required_proxy_group = profile_ai_runtime_group(result.fetch(:path)) if require_safe_ai
    return result.merge(status: rollback.call) if require_safe_ai && !required_proxy_group
    unless runtime_precommit_allowed?(precommit_condition)
      status = restore_profile_bytes(result) ? :reload_failed_rolled_back : :reload_failed_rollback_conflict
      return result.merge(status: status)
    end
    return pending.call unless profile_result_current?(result)

    code, _body = requester.call(
      "PUT", "/configs?force=true", JSON.generate("path" => File.expand_path(result.fetch(:path)))
    )
    return pending.call unless profile_result_current?(result)
    return result.merge(status: rollback.call) unless code == 204

    healthy = runtime_health_healthy?(
      requester, selections: candidate_selections, expected_tun: expected_tun,
      connectivity_checker: connectivity_checker,
      precommit_condition: precommit_condition,
      required_proxy_group: required_proxy_group
    )
    return pending.call unless profile_result_current?(result)
    return result.merge(status: rollback.call) unless
      runtime_precommit_allowed?(precommit_condition)
    return result.merge(reloaded: true) if healthy

    result.merge(status: rollback.call)
  rescue StandardError
    result.merge(
      status: rollback_after_reload_failure(
        result, requester, result[:path], precommit_condition: precommit_condition
      )
    )
  end

  def rollback_after_reload_failure(result, requester, path, selections: nil, expected_tun: nil,
                                    connectivity_checker: nil, precommit_condition: nil)
    return :reload_failed_rollback_conflict unless restore_profile_bytes(result)
    return :reload_failed_restore_pending unless requester && path && selections && expected_tun
    return :reload_failed_restore_pending unless runtime_precommit_allowed?(precommit_condition)

    code, _body = requester.call(
      "PUT", "/configs?force=true", JSON.generate("path" => File.expand_path(path))
    )
    return :reload_failed_restore_pending unless code == 204

    healthy = runtime_health_healthy?(
      requester, selections: selections, expected_tun: expected_tun,
      connectivity_checker: connectivity_checker,
      precommit_condition: precommit_condition
    )
    healthy && runtime_precommit_allowed?(precommit_condition) ?
      :reload_failed_rolled_back : :reload_failed_restore_pending
  rescue StandardError
    :reload_failed_restore_pending
  end

end
