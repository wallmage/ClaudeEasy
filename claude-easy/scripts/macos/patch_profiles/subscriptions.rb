module ClaudeEasy
  module_function

  AUTO_UPDATE_OWNERSHIP_BASENAME = "clashx-meta-kAutoUpdateEnable.state.json".freeze
  AUTO_UPDATE_DOMAINS = %w[com.metacubex.ClashX.meta com.MetaCubeX.ClashX.meta].freeze

  def auto_update_ownership_path(backup_root)
    File.join(File.expand_path(backup_root), AUTO_UPDATE_OWNERSHIP_BASENAME)
  end

  def auto_update_ownership_state(backup_root)
    path = auto_update_ownership_path(backup_root)
    return nil unless File.exist?(path) || File.symlink?(path)
    raise InvalidConfigError, "订阅自动更新所有权状态无效" if File.symlink?(path) || !File.file?(path)

    snapshot = regular_file_snapshot_once(path, "订阅自动更新所有权状态")
    state = JSON.parse(snapshot.fetch(:bytes).dup.force_encoding(Encoding::UTF_8))
    legacy = state.is_a?(Hash) && state.keys.sort == %w[Domain InstalledState Key OriginalState Version] &&
             state["Version"] == 1 && state["OriginalState"] == "enabled" &&
             state["InstalledState"] == "disabled"
    current = state.is_a?(Hash) && state.keys.sort == %w[Domain Key OriginalValue Phase Version] &&
              state["Version"] == 2 && state["OriginalValue"].is_a?(String) &&
              %w[prepared installed].include?(state["Phase"])
    valid = (legacy || current) &&
            AUTO_UPDATE_DOMAINS.include?(state["Domain"]) &&
            state["Key"] == "kAutoUpdateEnable"
    raise InvalidConfigError, "订阅自动更新所有权状态无效" unless valid

    state = state.merge("OriginalValue" => "true", "Phase" => "installed") if legacy
    state.merge(
      "Path" => path, "Bytes" => snapshot.fetch(:bytes),
      "Identity" => snapshot.fetch(:identity)
    )
  rescue JSON::ParserError, EncodingError
    raise InvalidConfigError, "订阅自动更新所有权状态无效"
  end

  def write_auto_update_ownership_state(backup_root, domain, original_value, phase, existing: nil)
    root = secure_backup_root!(backup_root)
    state = {
      "Version" => 2,
      "Domain" => domain,
      "Key" => "kAutoUpdateEnable",
      "OriginalValue" => original_value,
      "Phase" => phase
    }
    path = auto_update_ownership_path(root)
    bytes = (JSON.generate(state) + "\n").b
    if existing
      changed = atomic_compare_and_swap_bytes(
        path, existing.fetch("Bytes"), bytes,
        expected_identity: existing.fetch("Identity"), expected_path: File.realpath(path)
      )
      raise IOError, "订阅自动更新所有权状态同时发生变化" unless changed
    else
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(bytes)
        file.flush
        file.fsync
      end
    end
    FileUtils.chmod(0o600, path)
    auto_update_ownership_state(root)
  end

  def delete_auto_update_ownership_state(state)
    path = state.fetch("Path")
    write_path = File.realpath(path)
    Tempfile.create([".claude-easy-state-delete-", ".tmp"], File.dirname(write_path)) do |temporary|
      temporary.binmode
      temporary.flush
      temporary.fsync
      atomic_swap_paths(temporary.path, write_path)
      deleted = File.binread(temporary.path) == state.fetch("Bytes") &&
                begin
                  stat = File.stat(temporary.path)
                  [stat.dev, stat.ino] == state.fetch("Identity")
                end
      unless deleted
        atomic_swap_paths(temporary.path, write_path)
        raise IOError, "订阅自动更新所有权状态同时发生变化"
      end
      File.unlink(write_path)
      true
    end
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

  def disable_subscription_auto_update(backup_root:, runner: Open3.method(:capture3))
    ownership = auto_update_ownership_state(backup_root)
    if ownership
      owned_export = defaults_export_named_domain(ownership.fetch("Domain"), runner: runner)
      owned_value = owned_export &&
                    plist_raw_value(owned_export.fetch(:plist), "kAutoUpdateEnable", runner: runner)
      if ownership.fetch("Phase") == "installed" &&
         subscription_auto_update_state(owned_value) == :disabled
        return { status: :already_disabled, domain: ownership.fetch("Domain") }
      end
      restore_owned_subscription_auto_update(backup_root: backup_root, runner: runner)
    end
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
    before_write = defaults_export_named_domain(domain, runner: runner)
    before_value = before_write && plist_raw_value(before_write.fetch(:plist), "kAutoUpdateEnable", runner: runner)
    unless before_value == original
      delete_auto_update_ownership_state(ownership)
      raise InvalidConfigError, "订阅自动更新设置在修改前发生变化"
    end

    _output, error, write_status = runner.call(
      "/usr/bin/defaults", "write", domain, "kAutoUpdateEnable", "-bool", "false"
    )
    unless write_status.success?
      begin
        enable_subscription_auto_update(domain: domain, runner: runner)
      rescue InvalidConfigError, SystemCallError, IOError => restore_error
        raise IOError, "无法关闭订阅自动更新，且恢复原值失败：#{restore_error.message}"
      end
      raise IOError, "无法关闭 ClashX Meta 订阅自动更新：#{error.to_s.strip}"
    end

    verified_export = defaults_export_named_domain(domain, runner: runner)
    verified_value = verified_export &&
                     plist_raw_value(verified_export.fetch(:plist), "kAutoUpdateEnable", runner: runner)
    unless subscription_auto_update_state(verified_value) == :disabled
      begin
        enable_subscription_auto_update(domain: domain, runner: runner)
      rescue InvalidConfigError, SystemCallError, IOError => restore_error
        raise IOError, "订阅自动更新设置回读失败，且恢复原值失败：#{restore_error.message}"
      end
      raise IOError, "ClashX Meta 订阅自动更新设置回读失败，已经恢复原值"
    end

    begin
      ownership = write_auto_update_ownership_state(
        backup_root, domain, original, "installed", existing: auto_update_ownership_state(backup_root)
      )
    rescue StandardError => state_error
      begin
        enable_subscription_auto_update(domain: domain, runner: runner)
      rescue InvalidConfigError, SystemCallError, IOError => restore_error
        raise IOError, "无法记录订阅自动更新所有权，且恢复原值失败：#{restore_error.message}"
      end
      raise IOError, "无法记录订阅自动更新所有权，已经恢复原值：#{state_error.message}"
    end

    { status: :disabled, domain: domain, backup: created_backup, ownership: ownership.fetch("Path") }
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

  def restore_owned_subscription_auto_update(backup_root:, runner: Open3.method(:capture3))
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
  end

  def selected_profile_name(runner: Open3.method(:capture3))
    exported = defaults_export_domain(runner: runner)
    return nil unless exported

    json, _error, status = runner.call(
      "/usr/bin/plutil", "-convert", "json", "-o", "-", "-",
      stdin_data: exported.fetch(:plist)
    )
    return nil unless status.success?

    preferences = JSON.parse(json)
    return nil unless preferences.is_a?(Hash)
    return "" unless preferences.key?("selectConfigName")

    selected = preferences["selectConfigName"]
    selected.is_a?(String) ? selected.strip : nil
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

  def fetch_remote_subscription(target, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)
    config = <<~CURL
      url = "#{curl_config_value(target.fetch(:url))}"
      silent
      show-error
      fail
      location
      proto = "=https"
      max-time = #{Integer(timeout_seconds)}
    CURL
    stdout, _stderr, status = Open3.capture3(
      "/usr/bin/curl", "--config", "-", stdin_data: config, binmode: true
    )
    raise InvalidConfigError, "远程订阅下载失败" unless status.success? && !stdout.empty?

    stdout
  rescue KeyError, ArgumentError
    raise InvalidConfigError, "远程订阅下载失败"
  end

  def build_update_candidate(target, source, policy, usage_profile, validator)
    bytes = source.to_s.b
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise InvalidConfigError, "远程订阅内容不是有效 UTF-8" unless text.valid_encoding?

    config = load_yaml(text, target.fetch(:name))
    raise InvalidConfigError, "远程订阅内容无效" unless usable_config?(config)
    patched = patch(config, policy, usage_profile: usage_profile)
    raise InvalidConfigError, "远程订阅无法应用共享补丁" unless %i[updated unchanged].include?(patched.fetch(:status))
    candidate = patched.fetch(:config)
    output = dump_config(candidate).b
    reparsed = load_yaml(output.dup.force_encoding(Encoding::UTF_8), target.fetch(:name))
    second = patch(reparsed, policy, usage_profile: usage_profile)
    raise InvalidConfigError, "远程订阅二次转换不一致" if second.fetch(:changed) || dump_config(second.fetch(:config)).b != output

    Tempfile.create([".claude-easy-update-", ".yaml"], File.dirname(File.realpath(target.fetch(:path)))) do |temporary|
      temporary.binmode
      temporary.write(output)
      temporary.flush
      temporary.fsync
      validation = validator.call(temporary.path)
      raise InvalidConfigError, "远程订阅校验超时" if validation == :timeout
      raise InvalidConfigError, "远程订阅未通过 Mihomo 校验" unless validation == true
    end
    output
  end

  def replace_profile_bytes(path, bytes, expected_bytes: nil, expected_identity: nil, expected_path: nil)
    write_path = File.realpath(path)
    current = File.binread(write_path)
    return false if expected_bytes && current != expected_bytes

    atomic_compare_and_swap_bytes(
      path, current, bytes, expected_identity: expected_identity, expected_path: expected_path
    )
  end

  def write_locked_profile(handle, bytes)
    handle.rewind
    handle.write(bytes)
    handle.truncate(bytes.bytesize)
    handle.flush
    handle.fsync
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

  def safe_update_item_candidate_or_unknown?(item)
    return false unless item[:candidate_identity]
    return true unless File.realpath(item.fetch(:path)) == item.fetch(:write_path)

    stat = File.stat(item.fetch(:write_path))
    [stat.dev, stat.ino] == item.fetch(:candidate_identity) &&
      File.binread(item.fetch(:write_path)) == item.fetch(:candidate)
  rescue StandardError
    true
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
    return failures unless failures.empty?

    candidate_remains = items.any? { |item| safe_update_item_candidate_or_unknown?(item) }
    if items.none? { |item| item[:committed_identity] } && !candidate_remains
      remove_profile_transaction(transaction) unless keep_transaction
      return []
    end
    all_restored = items.all? { |item| safe_update_item_restored?(item) }
    if all_restored
      remove_profile_transaction(transaction) unless keep_transaction
    else
      recover_profile_transaction(backup_root, roots: roots, keep_transaction: keep_transaction)
    end
    []
  rescue StandardError
    [""]
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
      precommit_condition: precommit_condition
    )
  end

  def reload_recovered_safe_update_runtime(targets, usage_profile, selected_name)
    active = targets.find { |target| active_profile?(target.fetch(:path), selected_name) }
    return true unless active

    socket = controller_socket
    return false unless socket

    requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
    selections = runtime_selections(requester)
    return false unless selections

    expected_tun = usage_profile >= 2 ? :enabled : :ignore
    roots = targets.map { |target| File.dirname(File.expand_path(target.fetch(:path))) }.uniq
    runtime_context = capture_runtime_profile_context(roots)
    return false unless runtime_context && runtime_context.fetch(:selected) == selected_name

    code, _body = requester.call(
      "PUT", "/configs?force=true", JSON.generate("path" => File.expand_path(active.fetch(:path)))
    )
    return false unless code == 204

    runtime_health_healthy?(
      requester, selections: selections, expected_tun: expected_tun,
      connectivity_checker: method(:default_connectivity_healthy?)
    )
  rescue StandardError
    false
  end

  def safe_update_all(targets:, policy:, backup_root:, usage_profile:, fetcher: method(:fetch_remote_subscription),
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
         !reload_recovered_safe_update_runtime(targets, usage_profile, selected_name)
        return {
          status: :runtime_restore_pending, failed_profile: "",
          reason: :transaction_runtime_restore_failed
        }
      end
    end

    items = targets.map do |target|
      path = target.fetch(:path)
      original = File.binread(File.realpath(path))
      source = fetcher.call(target)
      candidate = build_update_candidate(target, source, policy, usage_profile, validator)
      { name: target.fetch(:name), path: path, original: original, candidate: candidate }
    rescue StandardError
      return { status: :aborted, failed_profile: target[:name].to_s, reason: :download_or_validation_failed }
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
    transaction = prepare_profile_transaction(items, backup_root)

    handles = []
    temporary_files = []
    concurrent_change = false
    begin
      items.sort_by { |item| File.expand_path(item.fetch(:path)) }.each do |item|
        write_path = File.realpath(item.fetch(:path))
        handle = File.open(write_path, "rb")
        lock_exclusive_with_timeout(handle)
        item[:write_path] = write_path
        handles << [item, handle]
      end
      unless handles.all? do |item, handle|
               locked_profile_current?(handle, item.fetch(:path)) &&
                 handle.rewind && handle.read == item.fetch(:original)
             end
        remove_profile_transaction(transaction)
        return { status: :aborted, failed_profile: "", reason: :concurrent_change }
      end

      handles.each do |item, _handle|
        create_versioned_backup(item.fetch(:path), backup_root, content: item.fetch(:original), reason: "pre-update")
      end
      handles.each do |item, handle|
        unless locked_profile_current?(handle, item.fetch(:path))
          concurrent_change = true
          raise IOError, "subscription path changed during safe update"
        end
        temporary = Tempfile.new([".claude-easy-update-swap-", ".tmp"], File.dirname(item.fetch(:write_path)))
        temporary.binmode
        write_locked_profile(temporary, item.fetch(:candidate))
        candidate = temporary.stat
        item[:candidate_identity] = [candidate.dev, candidate.ino]
        temporary_files << temporary
        item[:temporary] = temporary
      end
      handles.each do |item, handle|
        unless locked_profile_current?(handle, item.fetch(:path)) &&
               handle.rewind && handle.read == item.fetch(:original)
          concurrent_change = true
          raise IOError, "subscription path changed during safe update"
        end
        original_identity = [handle.stat.dev, handle.stat.ino]
        atomic_swap_paths(item.fetch(:temporary).path, item.fetch(:write_path))
        unless same_file_identity?(handle.stat, item.fetch(:temporary).path) &&
               File.binread(item.fetch(:temporary).path) == item.fetch(:original) &&
               File.realpath(item.fetch(:path)) == item.fetch(:write_path) &&
               File.binread(item.fetch(:write_path)) == item.fetch(:candidate)
          if File.exist?(item.fetch(:temporary).path) &&
             same_file_identity?(handle.stat, item.fetch(:temporary).path) &&
             File.binread(item.fetch(:write_path)) == item.fetch(:candidate)
            atomic_swap_paths(item.fetch(:temporary).path, item.fetch(:write_path))
          end
          concurrent_change = true
          raise IOError, "subscription path changed during safe update"
        end
        committed = File.stat(item.fetch(:write_path))
        item[:committed_identity] = [committed.dev, committed.ino]
        item[:original_identity] = original_identity
      end
    rescue StandardError
      reason = concurrent_change ? :concurrent_change : :write_failed
      failures = finish_safe_update_rollback(items, transaction, backup_root, roots)
      unless failures.empty?
        return {
          status: :rollback_failed, failed_profile: failures.reject(&:empty?).first.to_s, reason: reason
        }
      end
      return { status: :aborted, failed_profile: "", reason: reason }
    ensure
      handles.each { |_item, handle| handle.close rescue nil }
      temporary_files.each { |temporary| temporary.close! rescue nil }
    end

    unless items.all? { |item| safe_update_item_committed?(item) }
      rollback_failed = !finish_safe_update_rollback(items, transaction, backup_root, roots).empty?
      return {
        status: rollback_failed ? :rollback_failed : :aborted,
        failed_profile: "", reason: :concurrent_change
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
    runtime_status = activation_result[:status] if activation_result.is_a?(Hash)
    unless activated
      runtime_restore_pending = %i[
        reload_failed_restore_pending reload_failed_rollback_conflict
      ].include?(runtime_status)
      failures = finish_safe_update_rollback(
        items, transaction, backup_root, roots, keep_transaction: runtime_restore_pending
      )
      unless failures.empty?
        return { status: :rollback_failed, failed_profile: "", reason: :activation_failed }
      end
      if runtime_restore_pending
        return {
          status: :runtime_restore_pending, failed_profile: "", reason: :activation_failed,
          runtime_status: runtime_status
        }
      end
      return { status: :aborted, failed_profile: "", reason: :activation_failed }
    end

    remove_profile_transaction(transaction)
    { status: :updated, count: items.length, profiles: items.map { |item| item.fetch(:name) } }
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
