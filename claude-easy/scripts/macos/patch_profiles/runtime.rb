module ClaudeEasy
  module_function

  RUNTIME_NON_PROXY_NAMES = %w[
    DIRECT DNS REJECT REJECT-DROP PASS PASS-RULE COMPATIBLE REMATCH RELAY
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

  def running_mihomo_config_paths
    output, status = Open3.capture2("/bin/ps", "ax", "-o", "command=")
    return [] unless status.success?

    cores = mihomo_core_paths.select { |path| File.file?(path) && File.executable?(path) }
    output.each_line.each_with_object([]) do |line, paths|
      core = cores.find { |path| line.start_with?("#{path} ") }
      next unless core

      match = line.match(/(?:\A|\s)-f\s+(.+?\.yaml)(?:\s|\z)/)
      paths << File.expand_path(match[1]) if match
    end.uniq
  rescue SystemCallError, IOError
    []
  end

  def controller_socket
    cache_directories = [
      File.expand_path("~/Library/Caches/com.MetaCubeX.ClashX.meta/cacheConfigs"),
      File.expand_path("~/Library/Caches/com.metacubex.ClashX.meta/cacheConfigs")
    ]
    candidates = cache_directories.flat_map do |directory|
      candidates = Dir.glob(File.join(directory, "*.yaml")).each_with_object([]) do |path, entries|
        entries << [path, File.mtime(path)]
      rescue SystemCallError
        next
      end
      candidates.sort_by { |_path, modified| modified }.reverse_each.with_object([]) do |(path, _modified), entries|
        begin
          config = load_yaml(File.read(path, encoding: "UTF-8"), path)
          socket = config["external-controller-unix"] if config.is_a?(Hash)
          entries << [path, socket] if socket.is_a?(String) && File.socket?(socket)
        rescue StandardError
          next
        end
      end
    end
    candidates_by_socket = candidates.group_by { |_path, socket| socket }
    return nil if candidates_by_socket.empty?

    active_configs = running_mihomo_config_paths
    active_sockets = candidates_by_socket.select do |_socket, entries|
      entries.any? { |path, _candidate_socket| active_configs.include?(File.expand_path(path)) }
    end.keys
    active_sockets.length == 1 ? active_sockets.first : nil
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
    udp_index = if policy
                  providers = config["rule-providers"]
                  return nil unless providers.is_a?(Hash)

                  cn_ip_entry = providers.find do |name, provider|
                    owned_rule_provider?(name, provider, policy["cn_ip_provider"])
                  end
                  cn_domain_entry = providers.find do |name, provider|
                    owned_rule_provider?(name, provider, policy["cn_domain_provider"])
                  end
                  return nil unless cn_ip_entry && cn_domain_entry

                  cn_ip_provider, cn_ip_config = cn_ip_entry
                  cn_domain_provider, cn_domain_config = cn_domain_entry
                  route_group = cn_domain_config["proxy"]
                  return nil unless route_group.is_a?(String) && !route_group.empty? &&
                                    cn_ip_config["proxy"] == route_group
                  return nil unless route_groups(config).any? { |group| group["name"] == route_group }
                  return nil unless managed_rule_provider_config?(
                    cn_domain_provider, cn_domain_config, policy["cn_domain_provider"], route_group
                  )
                  return nil unless managed_rule_provider_config?(
                    cn_ip_provider, cn_ip_config, policy["cn_ip_provider"], route_group
                  )

                  cn_udp = render_cn_udp_direct_rule(policy, cn_ip_provider)
                  cn_udp_index = rules.index do |rule|
                    rule.to_s.gsub(/\s+/, "").casecmp(cn_udp.gsub(/\s+/, "")).zero?
                  end
                  cn_udp_index && cn_udp_index + 1
                else
                  rules.each_index.find do |index|
                    first = rule_info(rules[index])
                    second = rule_info(rules[index + 1])
                    first[:type] == "NETWORK" && first[:payload].to_s.casecmp("UDP").zero? &&
                      second[:type] == "NETWORK" && second[:payload].to_s.casecmp("UDP").zero? &&
                      second[:target].to_s.casecmp("REJECT").zero?
                  end
                end
    return nil unless udp_index

    first = rule_info(rules[udp_index])
    second = rule_info(rules[udp_index + 1])
    return nil unless first[:type] == "NETWORK" && first[:payload].to_s.casecmp("UDP").zero? &&
                      second[:type] == "NETWORK" && second[:payload].to_s.casecmp("UDP").zero? &&
                      second[:target].to_s.casecmp("REJECT").zero?

    target = first[:target].to_s
    return nil unless selectable_groups(config).any? { |group| group["name"] == target }

    if policy
      required = render_ai_rules(policy, target)
      rejects = required.map { |rule| rule_with_target(rule, "REJECT") }
      lan_rules = Array(policy["lan_udp_direct_rules"])
      expected_prefix = required + rejects + lan_rules + [
        "RULE-SET,#{cn_domain_provider},DIRECT",
        cn_udp,
        "NETWORK,UDP,#{target}",
        "NETWORK,UDP,REJECT"
      ]
      return nil if required.empty? || lan_rules.empty? || rules.first(expected_prefix.length) != expected_prefix
    end

    target
  rescue StandardError
    nil
  end

  def managed_rule_provider_config?(name, provider, expected, route_group)
    provider == {
      "type" => expected["type"],
      "behavior" => expected["behavior"],
      "format" => expected["format"],
      "url" => expected["url"],
      "path" => cn_provider_path(expected, name),
      "interval" => expected["interval"],
      "proxy" => route_group,
      "size-limit" => expected["size_limit"]
    }
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
    3.times do |attempt|
      _output, status = Open3.capture2e(CURL_ISOLATED_ENVIRONMENT, *arguments)
      return true if status.success?
      sleep 1 if attempt < 2
    rescue StandardError
      sleep 1 if attempt < 2
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

  def restore_runtime_tun_state(requester, expected_tun)
    return false if expected_tun == :unknown
    return true if expected_tun == :ignore || tun_state(requester: requester) == expected_tun

    enabled = expected_tun == :enabled
    code, _body = requester.call(
      "PATCH", "/configs", JSON.generate("tun" => { "enable" => enabled })
    )
    code == 204 && tun_state(requester: requester) == expected_tun
  rescue StandardError
    false
  end

  def controller_path_component(value)
    value.to_s.encode("UTF-8").bytes.map do |byte|
      character = byte.chr
      character.match?(/[A-Za-z0-9\-._~]/) ? character : format("%%%02X", byte)
    end.join
  end

  def restore_runtime_selections(requester, selections)
    return false unless selections.is_a?(Hash) &&
                        selections.all? do |name, selected|
                          name.is_a?(String) && !name.empty? &&
                            selected.is_a?(String) && !selected.empty?
                        end
    return true if selections.empty?

    proxies = runtime_proxies(requester)
    return false unless proxies

    selections.each do |name, selected|
      proxy = proxies[name]
      return false unless proxy.is_a?(Hash) && proxy["type"].to_s.casecmp("Selector").zero?
      next if proxy["now"] == selected
      return false unless proxy["all"].is_a?(Array) && proxy["all"].include?(selected)

      code, _body = requester.call(
        "PUT", "/proxies/#{controller_path_component(name)}", JSON.generate("name" => selected)
      )
      return false unless code == 204
    end

    restored = runtime_selections(requester)
    restored.is_a?(Hash) && selections.all? { |name, selected| restored[name] == selected }
  rescue StandardError
    false
  end

  def runtime_tun_requirement(usage_profile)
    usage_profile >= 2 ? true : :preserve
  end

  def capture_runtime_checkpoint(path, require_tun:, socket: nil, requester: nil)
    if requester.nil?
      socket ||= controller_socket
      return nil unless socket

      requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    end
    selections = runtime_selections(requester)
    return nil unless selections

    selections = runtime_selections_for_profile(selections, path)
    return nil unless selections
    expected_tun = if require_tun == :preserve
                     tun_state(requester: requester)
                   elsif require_tun
                     :enabled
                   else
                     :ignore
                   end
    return nil if expected_tun == :unknown

    {
      path: File.realpath(path), selections: selections,
      expected_tun: expected_tun
    }
  rescue StandardError
    nil
  end

  def reload_profile_runtime(requester, path, expected_tun: :ignore, selections: {})
    code, _body = requester.call(
      "PUT", "/configs?force=true", JSON.generate("path" => File.expand_path(path))
    )
    code == 204 &&
      restore_runtime_tun_state(requester, expected_tun) &&
      restore_runtime_selections(requester, selections)
  rescue StandardError
    false
  end

  def runtime_health_healthy?(requester, selections:, expected_tun:, connectivity_checker: nil,
                              precommit_condition: nil, required_proxy_group: nil,
                              flush_caches: true, check_dns: true)
    return false unless runtime_precommit_allowed?(precommit_condition)

    if flush_caches
      code, _body = requester.call("POST", "/cache/dns/flush", nil)
      return false unless [200, 204].include?(code)
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
    if check_dns
      return false unless dns_runtime_healthy?(requester, "www.baidu.com")
    end

    connectivity_checker ||= lambda do
      default_connectivity_healthy?(requester: requester, tun_mode: expected_tun)
    end
    return false unless connectivity_checker.call

    runtime_precommit_allowed?(precommit_condition)
  rescue StandardError
    false
  end

  def reload_recovered_profile_runtime(work_items, require_tun:, socket: nil, requester: nil,
                                       connectivity_checker: nil, precommit_condition: nil,
                                       runtime_checkpoint: nil)
    active = work_items.find { |item| item.fetch(:active) }
    return true unless active

    if requester.nil?
      socket ||= controller_socket
      return false unless socket

      requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    end
    if runtime_checkpoint
      return false unless runtime_checkpoint[:path] == File.realpath(active.fetch(:path))

      selections = runtime_selections_for_profile(
        runtime_checkpoint[:selections], active.fetch(:path)
      )
      expected_tun = runtime_checkpoint[:expected_tun]
    else
      selections = runtime_selections(requester)
      return false unless selections
      selections = runtime_selections_for_profile(selections, active.fetch(:path))
      expected_tun = if require_tun == :preserve
                       tun_state(requester: requester)
                     elsif require_tun
                       :enabled
                     else
                       :ignore
                     end
    end
    return false unless selections
    return false if expected_tun == :unknown
    return false unless runtime_precommit_allowed?(precommit_condition)

    return false unless reload_profile_runtime(
      requester, active.fetch(:path), expected_tun: expected_tun, selections: selections
    )

    healthy = runtime_health_healthy?(
      requester, selections: selections, expected_tun: expected_tun,
      connectivity_checker: connectivity_checker,
      precommit_condition: precommit_condition, check_dns: false
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
                               require_safe_ai: false, runtime_checkpoint: nil)
    pending = -> { result.merge(status: :reload_failed_restore_pending) }
    reload_attempted = false
    return pending.call unless profile_result_current?(result)

    if requester.nil?
      socket ||= controller_socket
      return result.merge(status: rollback_before_runtime_reload(result)) unless socket

      requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    end
    if runtime_checkpoint
      unless runtime_checkpoint[:path] == File.realpath(result.fetch(:path))
        return result.merge(status: rollback_before_runtime_reload(result))
      end
      before = runtime_checkpoint[:selections]
      expected_tun = runtime_checkpoint[:expected_tun]
    else
      before = runtime_selections(requester)
      return result.merge(status: rollback_before_runtime_reload(result)) unless before
      expected_tun = if require_tun == :preserve
                       tun_state(requester: requester)
                     elsif require_tun
                       :enabled
                     else
                       :ignore
                     end
    end
    rollback = lambda do
      rollback_after_reload_failure(
        result, requester, result[:path], selections: before, expected_tun: expected_tun,
        connectivity_checker: connectivity_checker, precommit_condition: precommit_condition
      )
    end
    return result.merge(status: rollback_before_runtime_reload(result)) if expected_tun == :unknown
    candidate_selections = runtime_selections_for_profile(before, result.fetch(:path))
    return result.merge(status: rollback_before_runtime_reload(result)) unless candidate_selections
    required_proxy_group = profile_ai_runtime_group(result.fetch(:path)) if require_safe_ai
    if require_safe_ai && !required_proxy_group
      return result.merge(status: rollback_before_runtime_reload(result))
    end
    unless runtime_precommit_allowed?(precommit_condition)
      status = restore_profile_bytes(result) ? :reload_failed_rolled_back : :reload_failed_rollback_conflict
      return result.merge(status: status)
    end
    return pending.call unless profile_result_current?(result)

    reload_attempted = true
    code, _body = requester.call(
      "PUT", "/configs?force=true", JSON.generate("path" => File.expand_path(result.fetch(:path)))
    )
    return pending.call unless profile_result_current?(result)
    return result.merge(status: rollback.call) unless code == 204
    tun_restored = restore_runtime_tun_state(requester, expected_tun)
    return pending.call unless profile_result_current?(result)
    return result.merge(status: rollback.call) unless tun_restored
    selections_restored = restore_runtime_selections(requester, candidate_selections)
    return pending.call unless profile_result_current?(result)
    return result.merge(status: rollback.call) unless selections_restored

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
    status = if reload_attempted
               rollback_after_reload_failure(
                 result, requester, result[:path], selections: before,
                 expected_tun: expected_tun, connectivity_checker: connectivity_checker,
                 precommit_condition: precommit_condition
               )
             else
               rollback_before_runtime_reload(result)
             end
    result.merge(status: status)
  end

  def rollback_before_runtime_reload(result)
    restore_profile_bytes(result) ? :reload_failed_rolled_back : :reload_failed_rollback_conflict
  rescue StandardError
    :reload_failed_rollback_conflict
  end

  def rollback_after_reload_failure(result, requester, path, selections: nil, expected_tun: nil,
                                    connectivity_checker: nil, precommit_condition: nil)
    return :reload_failed_rollback_conflict unless restore_profile_bytes(result)
    return :reload_failed_restore_pending unless requester && path && selections && expected_tun
    return :reload_failed_restore_pending unless runtime_precommit_allowed?(precommit_condition)

    return :reload_failed_restore_pending unless reload_profile_runtime(
      requester, path, expected_tun: expected_tun, selections: selections
    )

    healthy = runtime_health_healthy?(
      requester, selections: selections, expected_tun: expected_tun,
      connectivity_checker: connectivity_checker,
      precommit_condition: precommit_condition, check_dns: false
    )
    return :reload_failed_rolled_back if
      healthy && runtime_precommit_allowed?(precommit_condition)

    :reload_failed_restore_pending
  rescue StandardError
    :reload_failed_restore_pending
  end

end
