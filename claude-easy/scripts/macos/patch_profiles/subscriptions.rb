module ClaudeEasy
  module_function

  class SafeUpdateCandidateError < InvalidConfigError
    attr_reader :reason, :subscription_switch_possible

    def initialize(message, reason:, subscription_switch_possible: false)
      super(message)
      @reason = reason
      @subscription_switch_possible = subscription_switch_possible
    end
  end

  AUTO_UPDATE_OWNERSHIP_BASENAME = "clashx-meta-kAutoUpdateEnable.state.json".freeze
  AUTO_UPDATE_DOMAINS = %w[com.metacubex.ClashX.meta com.MetaCubeX.ClashX.meta].freeze
  MAX_REMOTE_SUBSCRIPTION_BYTES = 32 * 1024 * 1024

  def auto_update_ownership_path(backup_root)
    File.join(File.expand_path(backup_root), AUTO_UPDATE_OWNERSHIP_BASENAME)
  end

  def auto_update_ownership_record(backup_root)
    path = auto_update_ownership_path(backup_root)
    return nil unless File.exist?(path) || File.symlink?(path)
    raise InvalidConfigError, "订阅自动更新所有权状态无效" if File.symlink?(path) || !File.file?(path)

    snapshot = regular_file_snapshot_once(path, "订阅自动更新所有权状态")
    bytes = snapshot.fetch(:bytes)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise InvalidConfigError, "订阅自动更新所有权状态无效" unless text.valid_encoding?

    valid_bytes = if bytes.end_with?("\n")
                    bytes
                  else
                    newline = bytes.rindex("\n")
                    prefix = newline ? bytes.byteslice(0, newline + 1) : "".b
                    if prefix.empty?
                      parsed = JSON.parse(text)
                      prefix = bytes if [1, 2].include?(parsed["Version"])
                    end
                    prefix
                  end
    raise InvalidConfigError, "订阅自动更新所有权状态无效" if valid_bytes.empty?

    state = nil
    valid_bytes.each_line do |line|
      record = JSON.parse(line)
      legacy = record.is_a?(Hash) &&
               record.keys.sort == %w[Domain InstalledState Key OriginalState Version] &&
               record["Version"] == 1 && record["OriginalState"] == "enabled" &&
               record["InstalledState"] == "disabled"
      current = record.is_a?(Hash) &&
                record.keys.sort == %w[Domain Key OriginalValue Phase Version] &&
                [2, 3].include?(record["Version"]) && record["OriginalValue"].is_a?(String) &&
                subscription_auto_update_state(record["OriginalValue"]) == :enabled &&
                (record["Version"] == 2 ? %w[prepared installed] : %w[prepared installed released]).include?(record["Phase"])
      valid = (legacy || current) &&
              AUTO_UPDATE_DOMAINS.include?(record["Domain"]) &&
              record["Key"] == "kAutoUpdateEnable"
      raise InvalidConfigError, "订阅自动更新所有权状态无效" unless valid

      state = if legacy
                {
                  "Version" => 1, "Domain" => record.fetch("Domain"),
                  "Key" => record.fetch("Key"), "OriginalValue" => "true",
                  "Phase" => "installed"
                }
              else
                record
              end
    end
    raise InvalidConfigError, "订阅自动更新所有权状态无效" unless state

    state.merge(
      "Path" => path, "Bytes" => bytes, "ValidBytes" => valid_bytes,
      "Identity" => snapshot.fetch(:identity)
    )
  rescue JSON::ParserError, EncodingError
    raise InvalidConfigError, "订阅自动更新所有权状态无效"
  end

  def auto_update_ownership_state(backup_root)
    state = auto_update_ownership_record(backup_root)
    state unless state && state.fetch("Phase") == "released"
  end

  def append_auto_update_ownership_event(state, event)
    path = state.fetch("Path")
    write_path = File.realpath(path)
    event_bytes = (JSON.generate(event) + "\n").b
    File.open(write_path, "r+b") do |source|
      lock_exclusive_with_timeout(source)
      source.rewind
      return false unless locked_source_current?(source, path, write_path) &&
                          [source.stat.dev, source.stat.ino] == state.fetch("Identity") &&
                          source.read.b == state.fetch("Bytes")

      valid_bytes = state.fetch("ValidBytes")
      source.rewind
      source.truncate(valid_bytes.bytesize)
      source.seek(0, IO::SEEK_END)
      separator = valid_bytes.end_with?("\n") ? "".b : "\n".b
      written = source.write(separator + event_bytes)
      raise IOError, "订阅自动更新所有权状态写入不完整" unless
        written == separator.bytesize + event_bytes.bytesize

      source.flush
      source.fsync
      locked_source_current?(source, path, write_path)
    end
  end

  def write_auto_update_ownership_state(backup_root, domain, original_value, phase, existing: nil)
    root = secure_backup_root!(backup_root)
    state = {
      "Version" => 3,
      "Domain" => domain,
      "Key" => "kAutoUpdateEnable",
      "OriginalValue" => original_value,
      "Phase" => phase
    }
    raise InvalidConfigError, "订阅自动更新所有权状态无效" unless
      AUTO_UPDATE_DOMAINS.include?(domain) && %w[prepared installed].include?(phase)

    path = auto_update_ownership_path(root)
    if existing.nil? && (File.exist?(path) || File.symlink?(path))
      existing = auto_update_ownership_record(root)
      raise IOError, "订阅自动更新所有权状态已经存在" unless
        existing && existing.fetch("Phase") == "released"
    end
    if existing
      changed = append_auto_update_ownership_event(existing, state)
      raise IOError, "订阅自动更新所有权状态同时发生变化" unless changed
    else
      bytes = (JSON.generate(state) + "\n").b
      Tempfile.create([".claude-easy-auto-update-state-", ".tmp"], root) do |file|
        file.binmode
        written = file.write(bytes)
        raise IOError, "订阅自动更新所有权状态写入不完整" unless written == bytes.bytesize

        file.flush
        file.fsync
        file.chmod(0o600)
        file.close
        ClaudeEasyDarwinFilesystem.rename_exclusive(file.path, path)
        fsync_parent_directory(path)
      end
    end
    auto_update_ownership_state(root)
  end

  def delete_auto_update_ownership_state(state)
    event = {
      "Version" => 3,
      "Domain" => state.fetch("Domain"),
      "Key" => "kAutoUpdateEnable",
      "OriginalValue" => state.fetch("OriginalValue"),
      "Phase" => "released"
    }
    changed = append_auto_update_ownership_event(state, event)
    raise IOError, "订阅自动更新所有权状态同时发生变化" unless changed

    true
  end

  def defaults_export_domain(runner: Open3.method(:capture3))
    AUTO_UPDATE_DOMAINS.each do |domain|
      plist, _export_error, export_status = runner.call("/usr/bin/defaults", "export", domain, "-")
      next unless export_status.success? && !plist.empty?

      return { domain: domain, plist: plist }
    rescue StandardError
      next
    end
    nil
  end

  def defaults_export_named_domain(domain, runner: Open3.method(:capture3))
    plist, _error, status = runner.call("/usr/bin/defaults", "export", domain, "-")
    return nil unless status.success? && !plist.empty?

    { domain: domain, plist: plist }
  rescue StandardError
    nil
  end

  def plist_raw_value(plist, key, runner: Open3.method(:capture3))
    value, _extract_error, extract_status = runner.call(
      "/usr/bin/plutil", "-extract", key, "raw", "-o", "-", "-", stdin_data: plist
    )
    value = value.to_s.strip
    extract_status.success? && !value.empty? ? value : ""
  rescue StandardError
    ""
  end

  def defaults_read(key, runner: Open3.method(:capture3))
    exported = defaults_export_domain(runner: runner)
    return "" unless exported

    plist_raw_value(exported.fetch(:plist), key, runner: runner)
  end

  def disable_subscription_auto_update(backup_root:, runner: Open3.method(:capture3), operation_lock: nil)
    owns_operation_lock = operation_lock.nil?
    operation_lock ||= profile_operation_lock(backup_root)
    ownership = auto_update_ownership_state(backup_root)
    created_backup = nil
    if ownership
      owned_export = defaults_export_named_domain(ownership.fetch("Domain"), runner: runner)
      raise InvalidConfigError, "无法读取 ClashX Meta 偏好设置" unless owned_export

      domain = ownership.fetch("Domain")
      original = ownership.fetch("OriginalValue")
      current = plist_raw_value(owned_export.fetch(:plist), "kAutoUpdateEnable", runner: runner)
      current_state = subscription_auto_update_state(current)
      raise InvalidConfigError, "无法确认 ClashX Meta 订阅自动更新状态" if current_state == :unknown

      if ownership.fetch("Phase") == "installed" && current_state == :disabled
        return {
          status: :already_disabled_owned, domain: ownership.fetch("Domain"),
          ownership: ownership.fetch("Path")
        }
      end

      if current_state == :disabled
        ownership = write_auto_update_ownership_state(
          backup_root, domain, original, "installed", existing: ownership
        )
        return {
          status: :disabled, domain: domain, ownership: ownership.fetch("Path")
        }
      end

      if ownership.fetch("Phase") != "prepared"
        ownership = write_auto_update_ownership_state(
          backup_root, domain, original, "prepared", existing: ownership
        )
      end
    else
      exported = defaults_export_domain(runner: runner)
      raise InvalidConfigError, "无法读取 ClashX Meta 偏好设置" unless exported

      domain = exported.fetch(:domain)
      original = plist_raw_value(exported.fetch(:plist), "kAutoUpdateEnable", runner: runner)
      state = subscription_auto_update_state(original)
      return { status: :already_disabled, domain: domain } if state == :disabled
      raise InvalidConfigError, "无法确认 ClashX Meta 订阅自动更新状态" unless state == :enabled

      backup = {
        "Version" => 1,
        "Domain" => domain,
        "Key" => "kAutoUpdateEnable",
        "Value" => original,
        "RecordedAt" => Time.now.iso8601
      }
      backup_path = File.join(backup_root, "clashx-meta-kAutoUpdateEnable.json")
      created_backup = create_versioned_backup(
        backup_path, backup_root, content: JSON.generate(backup) + "\n", reason: "preference"
      )
      ownership = write_auto_update_ownership_state(backup_root, domain, original, "prepared")
      current = original
    end

    before_write = defaults_export_named_domain(domain, runner: runner)
    before_value = before_write &&
                   plist_raw_value(before_write.fetch(:plist), "kAutoUpdateEnable", runner: runner)
    unless before_value == current && subscription_auto_update_state(before_value) == :enabled
      raise InvalidConfigError, "订阅自动更新设置在修改前发生变化"
    end

    _output, error, write_status = runner.call(
      "/usr/bin/defaults", "write", domain, "kAutoUpdateEnable", "-bool", "false"
    )
    raise IOError, "无法关闭 ClashX Meta 订阅自动更新：#{error.to_s.strip}" unless
      write_status.success?

    verified_export = defaults_export_named_domain(domain, runner: runner)
    verified_value = verified_export &&
                     plist_raw_value(verified_export.fetch(:plist), "kAutoUpdateEnable", runner: runner)
    raise IOError, "ClashX Meta 订阅自动更新设置回读失败" unless
      subscription_auto_update_state(verified_value) == :disabled

    ownership = write_auto_update_ownership_state(
      backup_root, domain, original, "installed", existing: auto_update_ownership_state(backup_root)
    )

    { status: :disabled, domain: domain, backup: created_backup, ownership: ownership.fetch("Path") }
  ensure
    operation_lock&.close if owns_operation_lock
  end

  def enable_subscription_auto_update(domain: nil, runner: Open3.method(:capture3))
    exported = domain ? defaults_export_named_domain(domain, runner: runner) : defaults_export_domain(runner: runner)
    raise InvalidConfigError, "无法读取 ClashX Meta 偏好设置" unless exported

    domain = exported.fetch(:domain)
    current = plist_raw_value(exported.fetch(:plist), "kAutoUpdateEnable", runner: runner)
    state = subscription_auto_update_state(current)
    return { status: :already_enabled, domain: domain } if state == :enabled
    raise InvalidConfigError, "无法确认 ClashX Meta 订阅自动更新状态" unless state == :disabled

    _output, error, write_status = runner.call(
      "/usr/bin/defaults", "write", domain, "kAutoUpdateEnable", "-bool", "true"
    )
    raise IOError, "无法恢复 ClashX Meta 订阅自动更新：#{error.to_s.strip}" unless write_status.success?

    verified_export = defaults_export_named_domain(domain, runner: runner)
    verified_value = verified_export &&
                     plist_raw_value(verified_export.fetch(:plist), "kAutoUpdateEnable", runner: runner)
    raise IOError, "ClashX Meta 订阅自动更新恢复后回读失败" unless subscription_auto_update_state(verified_value) == :enabled

    { status: :enabled, domain: domain }
  end

  def restore_owned_subscription_auto_update(backup_root:, runner: Open3.method(:capture3), operation_lock: nil)
    owns_operation_lock = operation_lock.nil?
    operation_lock ||= profile_operation_lock(backup_root)
    ownership = auto_update_ownership_state(backup_root)
    return { status: :not_owned } unless ownership

    exported = defaults_export_named_domain(ownership.fetch("Domain"), runner: runner)
    raise InvalidConfigError, "无法读取 ClashX Meta 偏好设置" unless exported

    current = plist_raw_value(exported.fetch(:plist), "kAutoUpdateEnable", runner: runner)
    state = subscription_auto_update_state(current)
    if state == :disabled
      _output, error, write_status = runner.call(
        "/usr/bin/defaults", "write", ownership.fetch("Domain"), "kAutoUpdateEnable", "-bool", "true"
      )
      raise IOError, "无法恢复 ClashX Meta 订阅自动更新：#{error.to_s.strip}" unless write_status.success?

      verified_export = defaults_export_named_domain(ownership.fetch("Domain"), runner: runner)
      verified_value = verified_export &&
                       plist_raw_value(verified_export.fetch(:plist), "kAutoUpdateEnable", runner: runner)
      raise IOError, "ClashX Meta 订阅自动更新恢复后回读失败" unless subscription_auto_update_state(verified_value) == :enabled
      result = :restored
    elsif state == :enabled
      result = :already_restored
    else
      raise InvalidConfigError, "无法确认 ClashX Meta 订阅自动更新状态"
    end

    delete_auto_update_ownership_state(ownership)
    { status: result, domain: ownership.fetch("Domain") }
  ensure
    operation_lock&.close if owns_operation_lock
  end

  def selected_profile_name(runner: Open3.method(:capture3))
    exported = defaults_export_domain(runner: runner)
    return nil unless exported

    xml, _error, status = runner.call(
      "/usr/bin/plutil", "-convert", "xml1", "-o", "-", "-",
      stdin_data: exported.fetch(:plist)
    )
    return nil unless status.success?

    document = REXML::Document.new(xml)
    dictionary = document.elements["plist/dict"]
    return nil unless dictionary

    elements = dictionary.elements.to_a
    key_index = elements.index do |element|
      element.name == "key" && element.text.to_s == "selectConfigName"
    end
    return "" unless key_index

    selected = elements[key_index + 1]
    selected&.name == "string" ? selected.text.to_s.strip : nil
  rescue StandardError
    nil
  end

  def capture_runtime_profile_context(roots, guard_storage: false, expected_storage: nil)
    storage_before = guard_storage ? storage_mode : nil
    return nil if guard_storage && !expected_storage.nil? && storage_before != expected_storage

    selected_before = selected_profile_name
    return nil unless selected_before.is_a?(String)

    matching_paths = roots.flat_map { |root| profile_paths(root) }.select do |path|
      active_profile?(path, selected_before)
    end
    storage_after = guard_storage ? storage_mode : nil
    selected_after = selected_profile_name
    return nil unless selected_after.is_a?(String)
    return nil unless selected_before == selected_after && storage_before == storage_after
    return nil if guard_storage && storage_before == :unknown
    return nil unless matching_paths.length == 1

    {
      selected: selected_before,
      storage: storage_before,
      active_path: matching_paths.first && File.realpath(matching_paths.first)
    }
  rescue SystemCallError, IOError
    nil
  end

  def runtime_profile_context_current?(expected, roots, guard_storage: false)
    return false unless expected.is_a?(Hash)

    current = capture_runtime_profile_context(roots, guard_storage: guard_storage)
    !current.nil? && current == expected
  rescue StandardError
    false
  end

  def runtime_precommit_allowed?(condition)
    condition.nil? || condition.call == true
  rescue StandardError
    false
  end

  def icloud_enabled?
    storage_mode == :icloud
  end

  def storage_mode(value = defaults_read("kUserEnableiCloud"))
    normalized = value.to_s.strip.downcase
    return :icloud if %w[1 true yes].include?(normalized)
    return :local if %w[0 false no].include?(normalized)

    :unknown
  end

  def subscription_auto_update_state(value = defaults_read("kAutoUpdateEnable"))
    normalized = value.to_s.strip.downcase
    return :disabled if %w[0 false no].include?(normalized)
    return :enabled if %w[1 true yes].include?(normalized)

    :unknown
  end

  def remote_subscription_records(raw = defaults_read("kRemoteConfigs"))
    decoded = Base64.strict_decode64(raw.to_s.strip)
    records = JSON.parse(decoded)
    raise InvalidConfigError, "远程订阅清单无效" unless records.is_a?(Array) && !records.empty?

    records.map do |record|
      name = record.is_a?(Hash) ? record["name"].to_s.strip : ""
      url = record.is_a?(Hash) ? record["url"].to_s.strip : ""
      raise InvalidConfigError, "远程订阅清单缺少名称或地址" if name.empty? || url.empty?
      raise InvalidConfigError, "远程订阅地址不是 HTTPS" unless url.start_with?("https://")
      raise InvalidConfigError, "远程订阅名称包含非法字符" if name.include?("/") || name.include?("\\") || name.include?("\0")

      { name: name, url: url }
    end
  rescue ArgumentError, JSON::ParserError
    raise InvalidConfigError, "远程订阅清单无效"
  end

  def remote_subscription_targets(directories, records = remote_subscription_records)
    paths = directories.flat_map { |directory| profile_paths(directory) }
    targets = records.map do |record|
      matches = paths.select do |path|
        basename = File.basename(path)
        stem = basename.sub(/\.ya?ml\z/i, "")
        basename.casecmp(record.fetch(:name)).zero? || stem.casecmp(record.fetch(:name)).zero?
      end
      raise InvalidConfigError, "远程订阅无法对应到唯一配置文件" unless matches.length == 1

      record.merge(path: matches.first)
    end
    raise InvalidConfigError, "多个远程订阅对应到同一配置文件" unless targets.map { |target| File.expand_path(target.fetch(:path)) }.uniq.length == targets.length

    targets
  end

  def curl_config_value(value)
    raise InvalidConfigError, "远程订阅地址无效" if value.include?("\r") || value.include?("\n")

    value.gsub("\\") { "\\\\" }.gsub('"', '\\"')
  end

  def mihomo_loopback_proxy_url?(value)
    value.is_a?(String) && value.match?(%r{\A(?:http|socks5h)://127\.0\.0\.1:(?:[1-9]\d{0,4})\z}) &&
      value.rpartition(":").last.to_i <= 65_535
  end

  def fetch_remote_subscription(target, timeout_seconds: VALIDATION_TIMEOUT_SECONDS,
                                proxy_url: nil)
    raise InvalidConfigError, "Mihomo 本机代理不可用" unless
      mihomo_loopback_proxy_url?(proxy_url)

    config = <<~CURL
      url = "#{curl_config_value(target.fetch(:url))}"
      silent
      show-error
      fail
      location
      user-agent = "ClashX Meta"
      proto = "=https"
      max-time = #{Integer(timeout_seconds)}
      max-filesize = #{MAX_REMOTE_SUBSCRIPTION_BYTES}
    CURL
    stdout, _stderr, status = Open3.capture3(
      CURL_ISOLATED_ENVIRONMENT,
      "/usr/bin/curl", "-q", "--proxy", proxy_url, "--config", "-",
      stdin_data: config, binmode: true
    )
    raise InvalidConfigError, "远程订阅下载失败" unless
      status.success? && !stdout.empty? && stdout.bytesize <= MAX_REMOTE_SUBSCRIPTION_BYTES

    stdout
  rescue KeyError, ArgumentError
    raise InvalidConfigError, "远程订阅下载失败"
  end

  def fetch_remote_subscription_via_mihomo(target,
                                           timeout_seconds: VALIDATION_TIMEOUT_SECONDS)
    socket = controller_socket
    raise InvalidConfigError, "Mihomo 本机代理不可用" unless socket

    requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    proxy_url = runtime_loopback_proxy(requester)
    raise InvalidConfigError, "Mihomo 本机代理不可用" unless proxy_url

    fetch_remote_subscription(target, timeout_seconds: timeout_seconds, proxy_url: proxy_url)
  rescue SystemCallError, IOError
    raise InvalidConfigError, "远程订阅下载失败"
  end

  def build_update_candidate(target, source, policy, usage_profile, validator)
    bytes = source.to_s.b
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    unless text.valid_encoding?
      raise SafeUpdateCandidateError.new(
        "远程订阅内容不是有效 UTF-8", reason: :invalid_content,
        subscription_switch_possible: true
      )
    end

    config = begin
      load_yaml(text, target.fetch(:name))
    rescue InvalidConfigError, KeyError, Psych::Exception
      raise SafeUpdateCandidateError.new(
        "远程订阅内容无效", reason: :invalid_content,
        subscription_switch_possible: true
      )
    end
    unless usable_config?(config)
      raise SafeUpdateCandidateError.new(
        "远程订阅内容无效", reason: :invalid_content,
        subscription_switch_possible: true
      )
    end
    patched = patch(config, policy, usage_profile: usage_profile)
    unless %i[updated unchanged].include?(patched.fetch(:status))
      raise SafeUpdateCandidateError.new(
        "远程订阅无法应用共享补丁", reason: :patch_failed
      )
    end
    candidate = patched.fetch(:config)
    output = dump_config(candidate).b
    begin
      reparsed = load_yaml(output.dup.force_encoding(Encoding::UTF_8), target.fetch(:name))
      second = patch(reparsed, policy, usage_profile: usage_profile)
      consistent = !second.fetch(:changed) && dump_config(second.fetch(:config)).b == output
    rescue StandardError
      consistent = false
    end
    unless consistent
      raise SafeUpdateCandidateError.new(
        "远程订阅二次转换不一致", reason: :patch_inconsistent
      )
    end

    Tempfile.create([".claude-easy-update-", ".yaml"], File.dirname(File.realpath(target.fetch(:path)))) do |temporary|
      temporary.binmode
      temporary.write(output)
      temporary.flush
      temporary.fsync
      validation = validator.call(temporary.path)
      if validation == :timeout
        raise SafeUpdateCandidateError.new(
          "远程订阅校验超时", reason: :validation_timeout
        )
      end
      unless validation == true
        raise SafeUpdateCandidateError.new(
          "远程订阅未通过 Mihomo 校验", reason: :validation_failed
        )
      end
    end
    output
  end

  def replace_profile_bytes(path, bytes, expected_bytes: nil, expected_identity: nil, expected_path: nil)
    write_path = File.realpath(path)
    current = File.binread(write_path)
    return false if expected_bytes && current != expected_bytes

    transactional_compare_and_write_bytes(
      path, current, bytes, expected_identity: expected_identity, expected_path: expected_path
    )
  end

  def locked_profile_current?(handle, path)
    opened = handle.stat
    current = File.stat(File.realpath(path))
    opened.dev == current.dev && opened.ino == current.ino
  rescue StandardError
    false
  end

  def safe_update_item_committed?(item)
    return false unless File.realpath(item.fetch(:path)) == item.fetch(:write_path)

    stat = File.stat(item.fetch(:write_path))
    [stat.dev, stat.ino] == item.fetch(:committed_identity) &&
      File.binread(item.fetch(:write_path)) == item.fetch(:candidate)
  rescue StandardError
    false
  end

  def safe_update_item_restored?(item)
    return false unless File.realpath(item.fetch(:path)) == item.fetch(:write_path)

    File.binread(item.fetch(:write_path)) == item.fetch(:original)
  rescue StandardError
    false
  end

  def rollback_safe_update_items(items)
    failures = []
    items.each do |item|
      next unless item[:committed_identity]
      next if safe_update_item_restored?(item)

      restored = replace_profile_bytes(
        item.fetch(:path), item.fetch(:original),
        expected_bytes: item.fetch(:candidate),
        expected_identity: item.fetch(:committed_identity),
        expected_path: item.fetch(:write_path)
      )
      failures << item.fetch(:name) unless restored || safe_update_item_restored?(item)
    rescue StandardError
      failures << item.fetch(:name)
    end
    failures
  end

  def finish_safe_update_rollback(items, transaction, backup_root, roots, keep_transaction: false)
    failures = rollback_safe_update_items(items)
    recover_profile_transaction(backup_root, roots: roots, keep_transaction: keep_transaction)
    unrestored = items.select do |item|
      item[:committed_identity] && !safe_update_item_restored?(item)
    end.map { |item| item.fetch(:name) }.uniq
    {
      failures: failures.select { |name| unrestored.include?(name) }.uniq,
      superseded: unrestored.reject { |name| failures.include?(name) }
    }
  rescue StandardError
    unrestored = items.select do |item|
      item[:committed_identity] && !safe_update_item_restored?(item)
    end.map { |item| item.fetch(:name) }.uniq
    failures = Array(failures) | unrestored
    { failures: failures.empty? ? [""] : failures, superseded: [] }
  end

  def default_safe_update_activation(items, usage_profile, selected_name = selected_profile_name,
                                     precommit_condition: nil)
    active = items.find { |item| active_profile?(item.fetch(:path), selected_name) }
    return runtime_precommit_allowed?(precommit_condition) unless active

    result = {
      path: active.fetch(:path), status: :updated, active: true,
      rollback_bytes: active.fetch(:original), patched_digest: Digest::SHA256.hexdigest(active.fetch(:candidate)),
      patched_identity: active[:patched_identity], patched_path: active[:patched_path]
    }
    activate_updated_profile(
      result, require_tun: usage_profile >= 2,
      precommit_condition: precommit_condition,
      require_safe_ai: usage_profile == 3
    )
  end

  def reload_recovered_safe_update_runtime(targets, usage_profile, selected_name,
                                           precommit_condition: nil)
    active = targets.find { |target| active_profile?(target.fetch(:path), selected_name) }
    return true unless active

    socket = controller_socket
    return false unless socket

    requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    selections = runtime_selections(requester)
    return false unless selections
    selections = runtime_selections_for_profile(selections, active.fetch(:path))
    return false unless selections

    expected_tun = usage_profile >= 2 ? :enabled : :ignore
    roots = targets.map { |target| File.dirname(File.expand_path(target.fetch(:path))) }.uniq
    unless precommit_condition
      runtime_context = capture_runtime_profile_context(roots)
      return false unless runtime_context && runtime_context.fetch(:selected) == selected_name

      precommit_condition = lambda do
        runtime_profile_context_current?(runtime_context, roots)
      end
    end
    return false unless runtime_precommit_allowed?(precommit_condition)

    code, _body = requester.call(
      "PUT", "/configs?force=true", JSON.generate("path" => File.expand_path(active.fetch(:path)))
    )
    return false unless code == 204
    return false unless runtime_precommit_allowed?(precommit_condition)
    return false unless restore_runtime_tun_state(requester, expected_tun)
    return false unless runtime_precommit_allowed?(precommit_condition)

    healthy = runtime_health_healthy?(
      requester, selections: selections, expected_tun: expected_tun,
      precommit_condition: precommit_condition
    )
    healthy && runtime_precommit_allowed?(precommit_condition)
  rescue StandardError
    false
  end

  def safe_update_all(targets:, policy:, backup_root:, usage_profile:,
                      fetcher: method(:fetch_remote_subscription_via_mihomo),
                      validator: method(:validate_with_mihomo), activation: nil, selected_name: nil,
                      guard_storage: false, expected_storage: nil)
    operation_lock = nil
    raise InvalidConfigError, "用途档位无效" unless [1, 2, 3].include?(usage_profile)
    raise InvalidConfigError, "没有可更新的远程订阅" unless targets.is_a?(Array) && !targets.empty?
    roots = targets.map { |target| File.dirname(File.expand_path(target.fetch(:path))) }.uniq
    runtime_context = if selected_name.nil?
                        capture_runtime_profile_context(
                          roots, guard_storage: guard_storage,
                          expected_storage: expected_storage
                        )
                      end
    if selected_name.nil? && runtime_context.nil?
      return { status: :aborted, failed_profile: "", reason: :client_state_changed }
    end
    selected_name = runtime_context.fetch(:selected) if runtime_context
    precommit_condition = if runtime_context
                            lambda do
                              runtime_profile_context_current?(
                                runtime_context, roots, guard_storage: guard_storage
                              )
                            end
                          end
    if Dir.exist?(backup_root)
      operation_lock = profile_operation_lock(backup_root)
      if profile_transaction_pending?(backup_root)
        selected = selected_name
        active_root = active_profile_root(roots, selected)
        work_items = profile_work_items(roots, selected, active_root)
        recovery = resume_profile_transaction(
          backup_root, roots: roots, work_items: work_items, reload_runtime: true,
          require_tun: usage_profile >= 2,
          precommit_condition: precommit_condition
        )
        if recovery == :runtime_restore_pending
          return {
            status: :runtime_restore_pending, failed_profile: "",
            reason: :transaction_runtime_restore_failed
          }
        end
      end
      pending_runtime_restore = File.exist?(profile_transaction_path(backup_root)) ||
                                File.symlink?(profile_transaction_path(backup_root))
      recover_profile_transaction(backup_root, roots: roots)
      if pending_runtime_restore &&
         !reload_recovered_safe_update_runtime(
           targets, usage_profile, selected_name,
           precommit_condition: precommit_condition
         )
        return {
          status: :runtime_restore_pending, failed_profile: "",
          reason: :transaction_runtime_restore_failed
        }
      end
    end

    items = []
    item_results = []
    targets.each do |target|
      name = target[:name].to_s
      begin
        path = target.fetch(:path)
        original = File.binread(File.realpath(path))
      rescue StandardError
        item_results << { name: name, status: :failed, reason: :local_profile_failed }
        next
      end
      begin
        source = fetcher.call(target)
      rescue StandardError
        item_results << {
          name: name, status: :failed, reason: :download_failed,
          subscription_switch_possible: true
        }
        next
      end
      begin
        candidate = build_update_candidate(target, source, policy, usage_profile, validator)
      rescue SafeUpdateCandidateError => error
        failure = { name: name, status: :failed, reason: error.reason }
        failure[:subscription_switch_possible] = true if error.subscription_switch_possible
        item_results << failure
        next
      rescue StandardError
        item_results << { name: name, status: :failed, reason: :validation_failed }
        next
      end
      items << { name: name, path: path, original: original, candidate: candidate }
      item_results << { name: name, status: :ready }
    end
    if item_results.any? { |item| item.fetch(:status) == :failed }
      failed = item_results.find { |item| item.fetch(:status) == :failed }
      return {
        status: :aborted, failed_profile: failed.fetch(:name),
        reason: :download_or_validation_failed, items: item_results
      }
    end
    operation_lock ||= profile_operation_lock(backup_root)
    recover_profile_transaction(backup_root, roots: roots)

    identities = items.map do |item|
      stat = File.stat(File.realpath(item.fetch(:path)))
      [stat.dev, stat.ino]
    end
    if identities.uniq.length != identities.length
      return { status: :aborted, failed_profile: "", reason: :duplicate_target }
    end
    begin
      transaction = prepare_profile_transaction(items, backup_root, roots: roots)
    rescue ConcurrentProfileChangeError
      return { status: :aborted, failed_profile: "", reason: :concurrent_change }
    end

    handles = []
    concurrent_change = false
    begin
      items.sort_by { |item| File.expand_path(item.fetch(:path)) }.each do |item|
        write_path = File.realpath(item.fetch(:path))
        target = transaction.fetch(:targets).fetch(File.expand_path(item.fetch(:path)))
        unless write_path == target.fetch(:write_path)
          concurrent_change = true
          raise IOError, "subscription path changed during safe update"
        end
        handle = File.open(write_path, "r+b")
        lock_exclusive_with_timeout(handle)
        item[:write_path] = write_path
        item[:transaction_identity] = target.fetch(:identity)
        handles << [item, handle]
      end
      unless handles.all? do |item, handle|
               opened = handle.stat
               locked_profile_current?(handle, item.fetch(:path)) &&
                 [opened.dev, opened.ino] == item.fetch(:transaction_identity) &&
                 handle.rewind && handle.read == item.fetch(:original)
             end
        remove_profile_transaction(transaction)
        return { status: :aborted, failed_profile: "", reason: :concurrent_change }
      end

      handles.each do |item, _handle|
        create_versioned_backup(item.fetch(:path), backup_root, content: item.fetch(:original), reason: "pre-update")
      end
      handles.each do |item, handle|
        opened = handle.stat
        unless locked_profile_current?(handle, item.fetch(:path)) &&
               [opened.dev, opened.ino] == item.fetch(:transaction_identity) &&
               handle.rewind && handle.read == item.fetch(:original)
          concurrent_change = true
          raise IOError, "subscription path changed during safe update"
        end
        original_identity = [handle.stat.dev, handle.stat.ino]
        written = transactional_replace_locked(
          handle, item.fetch(:path), item.fetch(:write_path),
          item.fetch(:original), item.fetch(:candidate)
        )
        unless written
          concurrent_change = true
          raise IOError, "subscription path changed during safe update"
        end
        committed = handle.stat
        item[:committed_identity] = [committed.dev, committed.ino]
        item[:original_identity] = original_identity
      end
    rescue StandardError
      reason = concurrent_change ? :concurrent_change : :write_failed
      handles.each { |_item, handle| handle.close rescue nil }
      handles.clear
      rollback = finish_safe_update_rollback(items, transaction, backup_root, roots)
      unless rollback.fetch(:failures).empty?
        return {
          status: :rollback_failed,
          failed_profile: rollback.fetch(:failures).reject(&:empty?).first.to_s,
          reason: reason
        }
      end
      unless rollback.fetch(:superseded).empty?
        return { status: :aborted, failed_profile: "", reason: :rollback_superseded }
      end
      return { status: :aborted, failed_profile: "", reason: reason }
    ensure
      handles.each { |_item, handle| handle.close rescue nil }
    end

    unless items.all? { |item| safe_update_item_committed?(item) }
      rollback = finish_safe_update_rollback(items, transaction, backup_root, roots)
      reason = if rollback.fetch(:failures).empty? && !rollback.fetch(:superseded).empty?
                 :rollback_superseded
               else
                 :concurrent_change
               end
      return {
        status: rollback.fetch(:failures).empty? ? :aborted : :rollback_failed,
        failed_profile: "", reason: reason
      }
    end

    items.each do |item|
      item[:patched_identity] = item.fetch(:committed_identity)
      item[:patched_path] = item.fetch(:write_path)
    end
    activation ||= lambda do |updated_items|
      default_safe_update_activation(
        updated_items, usage_profile, selected_name,
        precommit_condition: precommit_condition
      )
    end
    activation_result = begin
      activation.call(items)
    rescue StandardError
      false
    end
    activated = activation_result == true ||
                (activation_result.is_a?(Hash) && activation_result[:reloaded] == true)
    if activated && !runtime_precommit_allowed?(precommit_condition)
      activation_result = { status: :reload_failed_restore_pending }
      activated = false
    end
    runtime_status = activation_result[:status] if activation_result.is_a?(Hash)
    unless activated
      runtime_restore_pending = %i[
        reload_failed_restore_pending reload_failed_rollback_conflict
      ].include?(runtime_status)
      rollback = finish_safe_update_rollback(
        items, transaction, backup_root, roots, keep_transaction: runtime_restore_pending
      )
      unless rollback.fetch(:failures).empty?
        return { status: :rollback_failed, failed_profile: "", reason: :activation_failed }
      end
      if runtime_restore_pending
        return {
          status: :runtime_restore_pending, failed_profile: "", reason: :activation_failed,
          runtime_status: runtime_status,
          rollback_superseded: !rollback.fetch(:superseded).empty?
        }
      end
      unless rollback.fetch(:superseded).empty?
        return { status: :aborted, failed_profile: "", reason: :rollback_superseded }
      end
      return { status: :aborted, failed_profile: "", reason: :activation_failed }
    end

    stale_items = items.reject { |item| safe_update_item_committed?(item) }
    unless stale_items.empty?
      runtime_committed = activation_result.is_a?(Hash) && activation_result[:reloaded] == true
      rollback = finish_safe_update_rollback(
        items, transaction, backup_root, roots, keep_transaction: runtime_committed
      )
      stale_names = stale_items.map { |item| item.fetch(:name) }
      failures = rollback.fetch(:failures) - stale_names
      superseded = rollback.fetch(:superseded) | stale_names
      unless failures.empty?
        return {
          status: :rollback_failed, failed_profile: failures.first.to_s,
          reason: :concurrent_change
        }
      end
      if runtime_committed
        restored_runtime = reload_recovered_safe_update_runtime(
          targets, usage_profile, selected_name,
          precommit_condition: precommit_condition
        ) && runtime_precommit_allowed?(precommit_condition)
        if restored_runtime
          begin
            remove_profile_transaction(transaction)
          rescue StandardError
            restored_runtime = false
          end
        end
        unless restored_runtime
          return {
            status: :runtime_restore_pending, failed_profile: "",
            reason: :concurrent_change,
            runtime_status: :reload_failed_restore_pending,
            rollback_superseded: !superseded.empty?
          }
        end
      end
      return { status: :aborted, failed_profile: "", reason: :rollback_superseded }
    end

    remove_profile_transaction(transaction, state_uncertain_on_sync_failure: true)
    { status: :updated, count: items.length, profiles: items.map { |item| item.fetch(:name) } }
  rescue ProfileCommitStateUncertainError
    raise
  rescue InvalidConfigError
    raise
  rescue StandardError
    { status: :aborted, failed_profile: "", reason: :unexpected_error }
  ensure
    operation_lock&.close
  end

  def clashx_app_paths
    ["/Applications/ClashX Meta.app", File.expand_path("~/Applications/ClashX Meta.app")].select { |path| Dir.exist?(path) }
  end

  def icloud_container_ids(app_paths = clashx_app_paths)
    ids = %w[iCloud.com.metacubex.ClashX iCloud.com.west2online.ClashX]
    app_paths.each do |app|
      plist = File.join(app, "Contents", "Info.plist")
      next unless File.file?(plist)

      json, status = Open3.capture2("/usr/bin/plutil", "-convert", "json", "-o", "-", plist)
      next unless status.success?

      containers = JSON.parse(json)["NSUbiquitousContainers"]
      ids.concat(containers.keys) if containers.is_a?(Hash)
    rescue StandardError
      next
    end
    ids.uniq
  end

  def icloud_container_roots(home: Dir.home, app_paths: clashx_app_paths)
    base = File.join(home, "Library", "Mobile Documents")
    icloud_container_ids(app_paths).map do |identifier|
      File.join(base, identifier.tr(".", "~"))
    end.uniq
  end

  def default_profile_directories(home: Dir.home, app_paths: clashx_app_paths, cloud_enabled: nil, selected: nil)
    local = File.join(home, ".config", "clash.meta")
    clouds = icloud_container_roots(home: home, app_paths: app_paths).map { |root| File.join(root, "Documents") }
    mode = cloud_enabled.nil? ? storage_mode : (cloud_enabled ? :icloud : :local)
    return [] if mode == :unknown
    return Dir.exist?(local) ? [local] : [] if mode == :local

    if selected.nil?
      selected = selected_profile_name
      return [] unless selected.is_a?(String)
    end
    existing_clouds = clouds.select { |path| Dir.exist?(path) }.uniq
    matching = existing_clouds.select do |root|
      profile_paths(root).any? { |path| active_profile?(path, selected) }
    end
    return [] if matching.length > 1
    return [] if matching.empty? && existing_clouds.length > 1

    candidates = matching.empty? ? existing_clouds : matching
    chosen = candidates.max_by do |root|
      selected_paths = profile_paths(root).select { |path| active_profile?(path, selected) }
      selected_paths.map { |path| File.mtime(path).to_f }.max || 0
    end
    chosen ? [chosen] : []
  end

  def active_profile?(path, selected)
    selected_name = File.basename(selected.to_s)
    selected_name = "config.yaml" if selected_name.empty?
    selected_stem = selected_name.sub(/\.ya?ml\z/i, "")
    profile_name = File.basename(path)
    profile_stem = profile_name.sub(/\.ya?ml\z/i, "")
    profile_name.casecmp(selected_name).zero? || profile_stem.casecmp(selected_stem).zero?
  end

  def active_profile_root(roots, selected, directory = nil)
    return directory if directory
    return roots.first if roots.length == 1

    matching = roots.select { |root| profile_paths(root).any? { |path| active_profile?(path, selected) } }
    candidates = matching.empty? ? roots : matching
    preferred = if icloud_enabled?
                  candidates.find { |path| path.include?("/Library/Mobile Documents/") }
                else
                  candidates.find { |path| path.end_with?("/.config/clash.meta") }
                end
    preferred || matching.first
  end

end
