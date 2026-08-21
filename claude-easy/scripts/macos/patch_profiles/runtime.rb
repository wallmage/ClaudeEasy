require "socket"

module ClaudeEasy
  module_function

  RUNTIME_NON_PROXY_NAMES = %w[
    DIRECT DNS REJECT REJECT-DROP PASS PASS-RULE COMPATIBLE REMATCH RELAY
  ].freeze
  RUNTIME_NON_PROXY_TYPES = %w[
    Direct Dns Reject RejectDrop Pass PassRule Compatible Rematch Relay
  ].freeze
  RUNTIME_PROXY_GROUP_TYPES = %w[Selector URLTest Fallback LoadBalance].freeze
  CLASHX_RELOAD_COMPLETION = "Initial configuration complete, total time:".b.freeze
  CLASHX_LOG_SESSION_PATTERN = /\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\z/.freeze
  CLASHX_CORE_LOG_PATTERN = /\Aclashx_core_\d{2}_\d{2}-\d{2}-\d{2}\.log(?:\.\d+)?\z/.freeze

  CURL_ISOLATED_ENVIRONMENT = {
    "http_proxy" => nil, "https_proxy" => nil, "all_proxy" => nil,
    "HTTP_PROXY" => nil, "HTTPS_PROXY" => nil, "ALL_PROXY" => nil,
    "no_proxy" => nil, "NO_PROXY" => nil
  }.freeze

  def clashx_running_identity(runner: Open3.method(:capture3))
    output, _error, status = runner.call(
      "/bin/ps", "axww", "-o", "pid=", "-o", "lstart=", "-o", "comm="
    )
    return nil unless status.success?

    matches = output.each_line.each_with_object([]) do |line, found|
      match = line.match(/\A\s*(\d+)\s+(.{24})\s+(.+ClashX Meta\.app\/Contents\/MacOS\/ClashX Meta)\s*\z/)
      next unless match

      executable = match[3].strip
      next unless executable == File.expand_path(executable)

      found << { pid: match[1].to_i, started: match[2], executable: executable }
    end
    matches.length == 1 ? matches.first : nil
  rescue StandardError
    nil
  end

  def same_clashx_process?(left, right)
    left.is_a?(Hash) && right.is_a?(Hash) &&
      left.values_at(:pid, :started, :executable) == right.values_at(:pid, :started, :executable)
  end

  def request_clashx_native_reload(identity, sender: ClaudeEasyAppleEvents.method(:send_get_url),
                                   process_reader: nil)
    process_reader ||= method(:clashx_running_identity)
    return false unless same_clashx_process?(identity, process_reader.call)

    sender.call(identity.fetch(:pid), "clash://update-config") &&
      same_clashx_process?(identity, process_reader.call)
  rescue StandardError
    false
  end

  def clashx_reload_snapshot(log_root: File.expand_path("~/.config/clash.meta/logs"))
    root_stat = File.lstat(log_root)
    return nil unless root_stat.directory? && !root_stat.symlink? && root_stat.uid == Process.uid

    session_name = Dir.children(log_root).select do |name|
      name.match?(CLASHX_LOG_SESSION_PATTERN)
    end.max
    return nil unless session_name

    session = File.join(log_root, session_name)
    session_stat = File.lstat(session)
    return nil unless session_stat.directory? && !session_stat.symlink? &&
                      session_stat.uid == Process.uid

    snapshots = Dir.children(session).each_with_object({}) do |name, result|
      next unless name.match?(CLASHX_CORE_LOG_PATTERN)

      path = File.join(session, name)
      stat = File.lstat(path)
      next unless stat.file? && !stat.symlink? && stat.uid == Process.uid

      result[path] = [stat.dev, stat.ino, stat.size]
    end
    snapshots.empty? ? nil : snapshots
  rescue StandardError
    nil
  end

  def clashx_reload_completed_since?(before, log_root: File.expand_path("~/.config/clash.meta/logs"))
    current = clashx_reload_snapshot(log_root: log_root)
    return false unless before.is_a?(Hash) && current

    current.any? do |path, identity_and_size|
      previous = before.values.find do |snapshot|
        snapshot.first(2) == identity_and_size.first(2)
      end
      offset = if previous && identity_and_size.fetch(2) >= previous.fetch(2)
                 previous.fetch(2)
               else
                 0
               end
      next false unless identity_and_size.fetch(2) > offset

      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(path, flags) do |handle|
        stat = handle.stat
        next false unless stat.file? && stat.uid == Process.uid &&
                          [stat.dev, stat.ino] == identity_and_size.first(2)

        handle.seek(offset)
        handle.read.include?(CLASHX_RELOAD_COMPLETION)
      end
    end
  rescue StandardError
    false
  end

  def open_clashx_reload_receipt(socket_path = controller_socket, timeout: 3)
    return nil unless socket_path

    socket = UNIXSocket.new(socket_path)
    socket.close_on_exec = true
    socket.write(
      "GET /logs?level=info HTTP/1.1\r\nHost: localhost\r\n" \
      "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n" \
      "Sec-WebSocket-Key: Y2xhdWRlLWVhc3ktbG9nIQ==\r\n\r\n"
    )
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    response = +""
    until (header_end = response.index("\r\n\r\n"))
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise IOError, "ClashX Meta 控制器日志流超时" if remaining <= 0
      raise IOError, "ClashX Meta 控制器日志流关闭" unless IO.select([socket], nil, nil, remaining)

      chunk = socket.read_nonblock(4096, exception: false)
      raise IOError, "ClashX Meta 控制器日志流关闭" if chunk.nil?
      next if chunk == :wait_readable

      response << chunk
      raise IOError, "ClashX Meta 控制器日志流响应无效" if response.bytesize > 16_384
    end
    header = response.byteslice(0, header_end)
    raise IOError, "ClashX Meta 控制器日志流响应无效" unless
      header.match?(/\AHTTP\/1\.[01] 101(?:\s|\z)/) &&
      header.match?(/^Upgrade:\s*websocket\s*$/i)

    { socket: socket, buffer: response.byteslice(header_end + 4..-1).to_s.b, completed: false }
  rescue StandardError
    socket&.close
    nil
  end

  def clashx_reload_receipt_completed?(receipt)
    return false unless receipt.is_a?(Hash)
    return true if receipt[:completed]

    socket = receipt[:socket]
    return false unless socket.respond_to?(:read_nonblock)

    buffer = receipt[:buffer].to_s.b
    loop do
      if buffer.include?(CLASHX_RELOAD_COMPLETION)
        receipt[:completed] = true
        receipt[:buffer] = +""
        return true
      end
      chunk = socket.read_nonblock(4096, exception: false)
      break if chunk.nil? || chunk == :wait_readable

      buffer << chunk
      if buffer.include?(CLASHX_RELOAD_COMPLETION)
        receipt[:completed] = true
        receipt[:buffer] = +""
        return true
      end
      if buffer.bytesize > 65_536
        buffer = buffer.byteslice(-(CLASHX_RELOAD_COMPLETION.bytesize - 1)..-1)
      end
    end
    receipt[:buffer] = buffer
    false
  rescue StandardError
    false
  end

  def close_clashx_reload_receipt(receipt)
    socket = receipt[:socket] if receipt.is_a?(Hash)
    socket.close if socket.respond_to?(:close) && !socket.closed?
    true
  rescue StandardError
    false
  end

  def current_runtime_requester
    socket = controller_socket
    return nil unless socket

    ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
  end

  def wait_for_clashx_safe_runtime(identity, reload_receipt: nil, selections:, expected_tun:,
                                    required_proxy_group: nil, requester_factory: nil,
                                    reload_receipt_reader: nil, process_reader: nil,
                                    connectivity_checker: nil, precommit_condition: nil,
                                    sleeper: nil, attempts: 120, expected_profile_path: nil,
                                    profile_match_reader: nil)
    requester_factory ||= method(:current_runtime_requester)
    reload_receipt_reader ||= method(:clashx_reload_receipt_completed?)
    process_reader ||= method(:clashx_running_identity)
    sleeper ||= ->(seconds) { sleep(seconds) }
    profile_match_reader ||= if expected_profile_path
                               ->(requester) { runtime_matches_profile?(requester, expected_profile_path) }
                             end

    attempts.times do |attempt|
      return false unless same_clashx_process?(identity, process_reader.call)

      requester = requester_factory.call
      matched = reload_receipt_reader.call(reload_receipt) &&
                profile_match_reader && requester && profile_match_reader.call(requester)
      unless matched
        sleeper.call(0.25) if attempt + 1 < attempts
        next
      end
      restorable_selections = requester && runtime_restorable_selections(requester, selections)
      selections_restored = requester && restorable_selections &&
                            restore_runtime_selections(requester, restorable_selections)
      healthy = selections_restored && runtime_health_healthy?(
        requester, selections: restorable_selections, expected_tun: expected_tun,
        connectivity_checker: connectivity_checker,
        precommit_condition: precommit_condition,
        required_proxy_group: required_proxy_group, flush_caches: false
      )
      return same_clashx_process?(identity, process_reader.call) if healthy
      sleeper.call(0.25) if attempt + 1 < attempts
    end
    false
  rescue StandardError
    false
  end

  def profile_runtime_identity(path)
    config = load_yaml(File.read(path, encoding: "UTF-8"), path)
    return nil unless config.is_a?(Hash)

    proxies = Array(config["proxies"]).each_with_object([]) do |proxy, names|
      next unless proxy.is_a?(Hash) && proxy["name"].is_a?(String) && !proxy["name"].empty?

      names << proxy["name"]
    end.sort
    groups = Array(config["proxy-groups"]).each_with_object({}) do |group, result|
      next unless group.is_a?(Hash) && group["name"].is_a?(String) && !group["name"].empty?

      result[group["name"]] = Array(group["proxies"]).map(&:to_s).sort
    end
    providers = if config["proxy-providers"].is_a?(Hash)
                  config["proxy-providers"].keys.map(&:to_s).sort
                else
                  []
                end
    { proxies: proxies, groups: groups, providers: providers }
  rescue StandardError
    nil
  end

  def runtime_loaded_identity(requester)
    proxies = runtime_proxies(requester)
    return nil unless proxies

    leaf_names = proxies.each_with_object([]) do |(name, proxy), names|
      next unless proxy.is_a?(Hash)

      type = proxy["type"].to_s
      next if runtime_proxy_group_type?(type) || runtime_non_proxy_name?(name)

      names << name
    end.sort
    groups = proxies.each_with_object({}) do |(name, proxy), result|
      next unless proxy.is_a?(Hash) && runtime_proxy_group_type?(proxy["type"])

      result[name] = Array(proxy["all"]).map(&:to_s).sort
    end
    status, body = requester.call("GET", "/providers/proxies", nil)
    providers = []
    if status == 200
      payload = JSON.parse(body)
      providers = payload["providers"].keys.map(&:to_s).sort if payload["providers"].is_a?(Hash)
    end
    { proxies: leaf_names, groups: groups, providers: providers }
  rescue StandardError
    nil
  end

  def runtime_matches_profile?(requester, path)
    expected = profile_runtime_identity(path)
    actual = runtime_loaded_identity(requester)
    return false unless expected && actual

    return false unless expected[:proxies].all? { |name| actual[:proxies].include?(name) }
    expected[:groups].each do |name, members|
      loaded = actual[:groups][name]
      return false unless loaded.is_a?(Array)
      return false unless members.all? { |member| loaded.include?(member) }
    end
    expected[:providers].all? { |name| actual[:providers].include?(name) }
  end

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

  def runtime_selections_for_profile(selections, path, require_all: false, preserve_all: false)
    return nil unless selections.is_a?(Hash)

    config = load_yaml(File.read(path, encoding: "UTF-8"), path)
    selector_names = selectable_groups(config).map { |group| group.fetch("name") }
    return nil if preserve_all && !selections.keys.all? { |name| selector_names.include?(name) }
    return {} if selector_names.empty?
    return nil if require_all && !selector_names.all? { |name| selections.key?(name) }

    selections.select { |name, _selected| selector_names.include?(name) }
  rescue StandardError
    nil
  end

  def localized_runtime_selections(selections, original_bytes, candidate_path)
    return nil unless selections.is_a?(Hash)

    original = load_yaml(original_bytes.dup.force_encoding(Encoding::UTF_8), "previous subscription")
    candidate = load_yaml(File.read(candidate_path, encoding: "UTF-8"), candidate_path)
    original_proxies = Array(original["proxies"]).select { |item| item.is_a?(Hash) && item["name"].is_a?(String) }
    candidate_proxies = Array(candidate["proxies"]).select { |item| item.is_a?(Hash) && item["name"].is_a?(String) }
    candidate_by_identity = candidate_proxies.group_by { |item| item.reject { |key, _value| key == "name" } }
    proxy_names = original_proxies.map { |item| item.fetch("name") }
    proxy_map = original_proxies.each_with_object({}) do |item, mapping|
      matches = candidate_by_identity[item.reject { |key, _value| key == "name" }]
      mapping[item.fetch("name")] = matches.first.fetch("name") if matches && matches.length == 1
    end
    proxy_positions_match = original_proxies.length == candidate_proxies.length &&
                            proxy_map.length * 2 >= original_proxies.length &&
                            proxy_map.all? do |old_name, new_name|
                              original_proxies.index { |item| item.fetch("name") == old_name } ==
                                candidate_proxies.index { |item| item.fetch("name") == new_name }
                            end
    if proxy_positions_match
      original_proxies.each_with_index do |item, index|
        next if proxy_map.key?(item.fetch("name"))
        candidate_proxy = candidate_proxies.fetch(index)
        next unless item["type"].to_s.casecmp(candidate_proxy["type"].to_s).zero?
        next if proxy_map.value?(candidate_proxy.fetch("name"))

        proxy_map[item.fetch("name")] = candidate_proxy.fetch("name")
      end
    end

    original_groups = Array(original["proxy-groups"]).select { |item| item.is_a?(Hash) && item["name"].is_a?(String) }
    candidate_groups = Array(candidate["proxy-groups"]).select { |item| item.is_a?(Hash) && item["name"].is_a?(String) }
    original_group_names = original_groups.map { |item| item.fetch("name") }
    candidate_group_names = candidate_groups.map { |item| item.fetch("name") }
    group_map = original_group_names.each_with_object({}) do |name, mapping|
      mapping[name] = name if candidate_group_names.include?(name)
    end

    loop do
      changed = false
      original_groups.each do |group|
        name = group.fetch("name")
        next if group_map.key?(name)

        translated = []
        Array(group["proxies"]).each do |member|
          mapped = proxy_map[member] || group_map[member]
          if mapped.nil? && (proxy_names.include?(member) || original_group_names.include?(member))
            next
          end
          translated << (mapped || member)
        end
        next if translated.empty?

        body = group.reject { |key, _value| %w[name proxies].include?(key) }
        matches = candidate_groups.select do |candidate_group|
          candidate_group.reject { |key, _value| %w[name proxies].include?(key) } == body &&
            translated.all? { |member| Array(candidate_group["proxies"]).include?(member) }
        end
        next unless matches.length == 1
        next if group_map.value?(matches.first.fetch("name"))

        group_map[name] = matches.first.fetch("name")
        changed = true
      end
      break unless changed
    end

    group_positions_match = original_groups.length == candidate_groups.length &&
                            group_map.length * 2 >= original_groups.length &&
                            group_map.all? do |old_name, new_name|
                              original_groups.index { |item| item.fetch("name") == old_name } ==
                                candidate_groups.index { |item| item.fetch("name") == new_name }
                            end
    if group_positions_match
      original_groups.each_with_index do |group, index|
        next if group_map.key?(group.fetch("name"))
        candidate_group = candidate_groups.fetch(index)
        next unless group["type"].to_s.casecmp(candidate_group["type"].to_s).zero?
        next if group_map.value?(candidate_group.fetch("name"))

        translated = Array(group["proxies"]).map { |member| proxy_map[member] || group_map[member] }.compact
        next if translated.length * 2 < Array(group["proxies"]).length
        next unless Array(group["proxies"]).length == Array(candidate_group["proxies"]).length
        next unless translated.all? { |member| Array(candidate_group["proxies"]).include?(member) }

        group_map[group.fetch("name")] = candidate_group.fetch("name")
      end
    end

    candidate_groups_by_name = candidate_groups.each_with_object({}) do |group, mapping|
      mapping[group.fetch("name")] = group
    end
    translated = selections.each_with_object({}) do |(group_name, selected), mapping|
      candidate_group_name = group_map[group_name]
      return nil unless candidate_group_name
      candidate_group = candidate_groups_by_name[candidate_group_name]
      candidate_selection = proxy_map[selected] || group_map[selected] || selected
      return nil unless Array(candidate_group["proxies"]).include?(candidate_selection)
      return nil if mapping.key?(candidate_group_name)

      mapping[candidate_group_name] = candidate_selection
    end
    translated
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
    expected_tun == :ignore || tun_state(requester: requester) == expected_tun
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

  def runtime_restorable_selections(requester, selections)
    return nil unless selections.is_a?(Hash)

    proxies = runtime_proxies(requester)
    return nil unless proxies

    selections.each do |name, selected|
      proxy = proxies[name]
      return nil unless proxy.is_a?(Hash) &&
                        proxy["type"].to_s.casecmp("Selector").zero? &&
                        proxy["all"].is_a?(Array) && proxy["all"].include?(selected)
    end
    selections
  rescue StandardError
    nil
  end

  def runtime_tun_requirement(_usage_profile)
    :preserve
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
    expected_tun = if require_tun == :preserve
                     tun_state(requester: requester)
                   elsif require_tun
                     :enabled
                   else
                     :ignore
                   end
    return result.merge(status: :runtime_check_failed) if expected_tun == :unknown
    healthy = runtime_precommit_allowed?(precommit_condition) &&
              runtime_health_healthy?(
                requester, selections: selections,
                expected_tun: expected_tun,
                connectivity_checker: connectivity_checker,
                precommit_condition: precommit_condition,
                required_proxy_group: group, flush_caches: false
              ) &&
              runtime_precommit_allowed?(precommit_condition)
    healthy ? result : result.merge(status: :runtime_check_failed)
  rescue StandardError
    result.merge(status: :runtime_check_failed)
  end

  def activate_safe_updated_profile(result, transaction:, client_identity:, runtime_checkpoint:,
                                    precommit_condition: nil, require_safe_ai: false,
                                    native_reloader: nil, runtime_waiter: nil,
                                    reload_snapshot_reader: nil)
    pending = -> { result.merge(status: :reload_failed_restore_pending) }
    native_reloader ||= method(:request_clashx_native_reload)
    runtime_waiter ||= method(:wait_for_clashx_safe_runtime)
    reload_receipt_opener = reload_snapshot_reader || method(:open_clashx_reload_receipt)
    return pending.call unless profile_result_current?(result)
    return result.merge(status: rollback_before_runtime_reload(result)) unless
      runtime_checkpoint.is_a?(Hash) &&
      runtime_checkpoint[:path] == File.realpath(result.fetch(:path))

    original_selections = runtime_checkpoint[:selections]
    selections = runtime_selections_for_profile(
      runtime_checkpoint[:selections], result.fetch(:path), preserve_all: true
    )
    selections ||= localized_runtime_selections(
      original_selections, result.fetch(:rollback_bytes), result.fetch(:path)
    )
    expected_tun = runtime_checkpoint[:expected_tun]
    return result.merge(status: rollback_before_runtime_reload(result)) unless
      selections && %i[enabled disabled ignore].include?(expected_tun)

    required_proxy_group = profile_ai_runtime_group(result.fetch(:path)) if require_safe_ai
    return result.merge(status: rollback_before_runtime_reload(result)) if
      require_safe_ai && !required_proxy_group
    unless runtime_precommit_allowed?(precommit_condition)
      return result.merge(status: rollback_before_runtime_reload(result))
    end

    reload_receipt = reload_receipt_opener.call
    return result.merge(status: rollback_before_runtime_reload(result)) unless reload_receipt
    unless mark_profile_transaction_activation(transaction, :update, client_identity)
      close_clashx_reload_receipt(reload_receipt)
      return pending.call
    end

    begin
      update_loaded = native_reloader.call(client_identity) &&
                      runtime_waiter.call(
                        client_identity, reload_receipt: reload_receipt,
                        selections: selections, expected_tun: expected_tun,
                        required_proxy_group: required_proxy_group,
                        precommit_condition: precommit_condition,
                        expected_profile_path: result.fetch(:path)
                      )
    ensure
      close_clashx_reload_receipt(reload_receipt)
    end
    return result.merge(reloaded: true) if
      update_loaded && profile_result_current?(result) &&
      runtime_precommit_allowed?(precommit_condition)

    return result.merge(status: :reload_failed_rollback_conflict) unless restore_profile_bytes(result)
    rollback_reload_receipt = reload_receipt_opener.call
    return pending.call unless rollback_reload_receipt
    unless mark_profile_transaction_activation(transaction, :rollback, client_identity)
      close_clashx_reload_receipt(rollback_reload_receipt)
      return pending.call
    end
    begin
      return pending.call unless native_reloader.call(client_identity)

      restored = runtime_waiter.call(
        client_identity, reload_receipt: rollback_reload_receipt,
        selections: original_selections, expected_tun: expected_tun,
        required_proxy_group: required_proxy_group,
        precommit_condition: precommit_condition,
        expected_profile_path: result.fetch(:path)
      )
    ensure
      close_clashx_reload_receipt(rollback_reload_receipt)
    end
    result.merge(status: restored ? :reload_failed_rolled_back : :reload_failed_restore_pending)
  rescue StandardError
    pending.call
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
