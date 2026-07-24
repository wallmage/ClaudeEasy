module ClaudeEasy
  module_function

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
    arguments = ["/usr/bin/curl", "-sS", "--max-time", "3", "-X", method, "--unix-socket", socket,
                 "-o", "-", "-w", "\n%{http_code}"]
    arguments.concat(["-H", "Content-Type: application/json", "--data", body]) if body
    arguments << "http://localhost#{path}"
    output, status = Open3.capture2e(*arguments)
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

  def runtime_selections(requester)
    status, body = requester.call("GET", "/proxies", nil)
    return nil unless status == 200

    payload = JSON.parse(body)
    proxies = payload["proxies"]
    return nil unless proxies.is_a?(Hash)

    proxies.each_with_object({}) do |(name, proxy), selections|
      next unless proxy.is_a?(Hash) && proxy["now"].is_a?(String)
      next unless proxy["type"].to_s.casecmp("Selector").zero?

      selections[name] = proxy["now"]
    end
  rescue JSON::ParserError
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

  def default_connectivity_healthy?
    3.times do
      _output, status = Open3.capture2e(
        "/usr/bin/curl", "-sS", "--fail", "--max-time", "8", "-o", "/dev/null",
        "https://www.google.com/generate_204"
      )
      return true if status.success?
    rescue StandardError
      next
    end
    false
  end

  def restore_profile_bytes(result)
    original = result[:rollback_bytes]
    expected = result[:patched_digest]
    return false unless original.is_a?(String) && expected.is_a?(String)

    path = result.fetch(:path)
    current = File.binread(File.realpath(path))
    return false unless Digest::SHA256.hexdigest(current) == expected

    atomic_compare_and_swap_bytes(
      path, current, original,
      expected_identity: result[:patched_identity],
      expected_path: result[:patched_path]
    )
  rescue SystemCallError, IOError, KeyError
    false
  end

  def runtime_health_healthy?(requester, selections:, expected_tun:, connectivity_checker:)
    caches_flushed = ["/cache/fakeip/flush", "/cache/dns/flush"].all? do |endpoint|
      code, _body = requester.call("POST", endpoint, nil)
      [200, 204].include?(code)
    end
    return false unless caches_flushed
    return false if expected_tun != :ignore && tun_state(requester: requester) != expected_tun

    after = runtime_selections(requester)
    return false unless after.is_a?(Hash) && selections.is_a?(Hash)
    return false unless selections.all? { |name, selected| after.key?(name) && after[name] == selected }
    return false unless dns_runtime_healthy?(requester, "www.baidu.com")
    return false unless dns_runtime_healthy?(requester, "www.google.com")

    connectivity_checker.call
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
    connectivity_checker ||= method(:default_connectivity_healthy?)
    selections = runtime_selections(requester)
    return false unless selections

    config = load_yaml(File.read(active.fetch(:path), encoding: "UTF-8"), active.fetch(:path))
    selector_names = selectable_groups(config).map { |group| group.fetch("name") }
    selections = selections.select { |name, _selected| selector_names.include?(name) }
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

    runtime_health_healthy?(
      requester, selections: selections, expected_tun: expected_tun,
      connectivity_checker: connectivity_checker
    )
  rescue StandardError
    false
  end

  def activate_updated_profile(result, socket: nil, requester: nil, connectivity_checker: nil,
                               require_tun: true, precommit_condition: nil)
    if requester.nil?
      socket ||= controller_socket
      return result.merge(
        status: rollback_after_reload_failure(
          result, nil, nil, precommit_condition: precommit_condition
        )
      ) unless socket

      requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    end
    connectivity_checker ||= method(:default_connectivity_healthy?)

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
    unless runtime_precommit_allowed?(precommit_condition)
      status = restore_profile_bytes(result) ? :reload_failed_rolled_back : :reload_failed_rollback_conflict
      return result.merge(status: status)
    end

    code, _body = requester.call(
      "PUT", "/configs?force=true", JSON.generate("path" => File.expand_path(result.fetch(:path)))
    )
    return result.merge(status: rollback.call) unless code == 204

    healthy = runtime_health_healthy?(
      requester, selections: before, expected_tun: expected_tun,
      connectivity_checker: connectivity_checker
    )
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
    connectivity_checker ||= method(:default_connectivity_healthy?)
    return :reload_failed_restore_pending unless runtime_precommit_allowed?(precommit_condition)

    code, _body = requester.call(
      "PUT", "/configs?force=true", JSON.generate("path" => File.expand_path(path))
    )
    return :reload_failed_restore_pending unless code == 204

    runtime_health_healthy?(
      requester, selections: selections, expected_tun: expected_tun,
      connectivity_checker: connectivity_checker
    ) ? :reload_failed_rolled_back : :reload_failed_restore_pending
  rescue StandardError
    :reload_failed_restore_pending
  end

end
