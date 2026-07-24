module ClaudeEasy
  module_function

  LOCK_TIMEOUT_SECONDS = 5
  RENAME_SWAP = 0x00000002
  PROFILE_TRANSACTION_BASENAME = ".claude-easy-profile-transaction.json".freeze
  PROFILE_OPERATION_LOCK_BASENAME = ".claude-easy-operation.lock".freeze
  LEGACY_PROFILE_TRANSACTION_BASENAME = ".clash-patch-profile-transaction.json".freeze
  LEGACY_PROFILE_OPERATION_LOCK_BASENAME = ".clash-patch-operation.lock".freeze

  module DarwinRename
    extend Fiddle::Importer
    dlload "/usr/lib/libSystem.B.dylib"
    extern "int renamex_np(const char *, const char *, unsigned int)"
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def lock_exclusive_with_timeout(handle, timeout_seconds: LOCK_TIMEOUT_SECONDS)
    deadline = monotonic_now + timeout_seconds
    loop do
      return true if handle.flock(File::LOCK_EX | File::LOCK_NB)
      raise IOError, "等待配置文件锁超时" if monotonic_now >= deadline

      sleep 0.05
    end
  end

  def atomic_swap_paths(first, second)
    result = DarwinRename.renamex_np(first.to_s, second.to_s, RENAME_SWAP)
    raise SystemCallError.new("无法原子交换配置文件", Fiddle.last_error) unless result.zero?

    true
  end

  def same_file_identity?(stat, path)
    current = File.stat(path)
    stat.dev == current.dev && stat.ino == current.ino
  rescue SystemCallError
    false
  end

  def atomic_replace_locked(source, path, write_path, expected_bytes, replacement_bytes)
    expected_bytes = expected_bytes.b
    replacement_bytes = replacement_bytes.b
    source.rewind
    return false unless locked_source_current?(source, path, write_path) && source.read.b == expected_bytes

    source_stat = source.stat
    Tempfile.create([".claude-easy-swap-", ".tmp"], File.dirname(write_path)) do |temporary|
      temporary.binmode
      temporary.write(replacement_bytes)
      temporary.flush
      temporary.fsync
      File.chmod(source_stat.mode & 0o7777, temporary.path)
      return false unless locked_source_current?(source, path, write_path)

      atomic_swap_paths(temporary.path, write_path)
      committed = same_file_identity?(source_stat, temporary.path) &&
                  File.binread(temporary.path) == expected_bytes &&
                  File.realpath(path) == write_path &&
                  File.binread(write_path) == replacement_bytes
      unless committed
        if File.exist?(temporary.path) && File.exist?(write_path) &&
           same_file_identity?(source_stat, temporary.path) &&
           File.binread(write_path) == replacement_bytes
          atomic_swap_paths(temporary.path, write_path)
        end
        return false
      end
      true
    end
  end

  def atomic_compare_and_swap_bytes(path, expected_bytes, replacement_bytes,
                                    expected_identity: nil, expected_path: nil)
    expected_bytes = expected_bytes.b
    replacement_bytes = replacement_bytes.b
    write_path = File.realpath(path)
    return false if expected_path && write_path != expected_path
    File.open(write_path, "rb") do |source|
      lock_exclusive_with_timeout(source)
      if expected_identity
        stat = source.stat
        return false unless [stat.dev, stat.ino] == expected_identity
      end
      atomic_replace_locked(source, path, write_path, expected_bytes, replacement_bytes)
    end
  rescue SystemCallError, IOError
    false
  end

  def write_locked_bytes(source, replacement_bytes, original_bytes)
    source.rewind
    written = source.write(replacement_bytes)
    raise IOError, "配置写入不完整" unless written == replacement_bytes.bytesize

    source.truncate(replacement_bytes.bytesize)
    source.flush
    source.fsync
    true
  rescue SystemCallError, IOError => write_error
    begin
      source.rewind
      restored = source.write(original_bytes)
      raise IOError, "原配置恢复不完整" unless restored == original_bytes.bytesize

      source.truncate(original_bytes.bytesize)
      source.flush
      source.fsync
    rescue SystemCallError, IOError => restore_error
      raise IOError, "配置写入失败且原内容恢复失败：#{restore_error.class}"
    end
    raise write_error
  end

  def locked_source_current?(source, path, write_path)
    return false unless File.realpath(path) == write_path

    source_stat = source.stat
    path_stat = File.stat(write_path)
    source_stat.dev == path_stat.dev && source_stat.ino == path_stat.ino
  rescue SystemCallError, IOError
    false
  end

  # 旧版中断留下的状态只能在旧锁已经独占后采用，避免与旧进程并发恢复。
  def rename_legacy_profile_state_file(root, legacy_basename, basename)
    current = File.join(root, basename)
    legacy = File.join(root, legacy_basename)
    current_exists = File.exist?(current) || File.symlink?(current)
    legacy_exists = File.exist?(legacy) || File.symlink?(legacy)
    if current_exists && legacy_exists
      raise InvalidConfigError, "旧版与当前配置事务状态同时存在；未执行任何修改"
    end
    return unless legacy_exists
    unless File.file?(legacy) && !File.symlink?(legacy)
      raise InvalidConfigError, "旧版配置事务状态不安全；未执行任何修改"
    end

    File.rename(legacy, current)
  end

  def profile_operation_lock(backup_root)
    root = secure_backup_root!(backup_root)
    path = File.join(root, PROFILE_OPERATION_LOCK_BASENAME)
    legacy_path = File.join(root, LEGACY_PROFILE_OPERATION_LOCK_BASENAME)
    current_exists = File.exist?(path) || File.symlink?(path)
    legacy_exists = File.exist?(legacy_path) || File.symlink?(legacy_path)
    if current_exists && legacy_exists
      raise InvalidConfigError, "旧版与当前配置操作锁同时存在；未执行任何修改"
    end
    if legacy_exists
      unless File.file?(legacy_path) && !File.symlink?(legacy_path)
        raise InvalidConfigError, "旧版配置操作锁不安全；未执行任何修改"
      end
      handle = File.open(legacy_path, File::RDWR)
      lock_exclusive_with_timeout(handle)
      if File.exist?(path) || File.symlink?(path)
        raise InvalidConfigError, "旧版与当前配置操作锁同时存在；未执行任何修改"
      end
      File.rename(legacy_path, path)
    else
      handle = File.open(path, File::RDWR | File::CREAT, 0o600)
      lock_exclusive_with_timeout(handle)
    end
    rename_legacy_profile_state_file(
      root, LEGACY_PROFILE_TRANSACTION_BASENAME, PROFILE_TRANSACTION_BASENAME
    )
    FileUtils.chmod(0o600, path)
    handle
  rescue StandardError
    handle&.close
    raise
  end

  def profile_transaction_path(backup_root)
    File.join(File.expand_path(backup_root), PROFILE_TRANSACTION_BASENAME)
  end

  def profile_transaction_pending?(backup_root)
    path = profile_transaction_path(backup_root)
    File.exist?(path) || File.symlink?(path)
  end

  def profile_path_allowed?(path, roots)
    expanded = File.expand_path(path)
    roots.any? do |root|
      prefix = File.expand_path(root) + File::SEPARATOR
      expanded.start_with?(prefix)
    end
  end

  def remove_profile_transaction(snapshot)
    path = snapshot.fetch(:path)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    File.open(path, flags) do |handle|
      lock_exclusive_with_timeout(handle)
      stat = handle.stat
      current = File.lstat(path)
      raise IOError, "配置事务记录同时发生变化" unless
        current.file? && !current.symlink? &&
        [stat.dev, stat.ino] == snapshot.fetch(:identity) &&
        [current.dev, current.ino] == snapshot.fetch(:identity) &&
        handle.read.b == snapshot.fetch(:bytes)

      File.unlink(path)
    end
    true
  end

  def recover_profile_transaction(backup_root, roots:, allow_concurrent_paths: [], keep_transaction: false)
    path = profile_transaction_path(backup_root)
    return true unless File.exist?(path) || File.symlink?(path)

    snapshot = regular_file_snapshot_once(path, "配置事务记录")
    allowed_concurrent_paths = allow_concurrent_paths.map { |item| File.expand_path(item) }.to_h { |item| [item, true] }
    text = snapshot.fetch(:bytes).dup.force_encoding(Encoding::UTF_8)
    raise InvalidConfigError, "配置事务记录无效" unless text.valid_encoding?

    state = JSON.parse(text)
    valid_state = state.is_a?(Hash) && state.keys.sort == %w[Items Version] &&
                  state["Version"] == 1 && state["Items"].is_a?(Array) &&
                  !state["Items"].empty?
    raise InvalidConfigError, "配置事务记录无效" unless valid_state

    seen = {}
    state.fetch("Items").each do |item|
      valid_item = item.is_a?(Hash) &&
                   item.keys.sort == %w[CandidateSha256 OriginalBase64 Path WritePath] &&
                   item["Path"].is_a?(String) && item["WritePath"].is_a?(String) &&
                   item["OriginalBase64"].is_a?(String) &&
                   item["CandidateSha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
      raise InvalidConfigError, "配置事务记录无效" unless valid_item
      raise InvalidConfigError, "配置事务记录路径无效" unless
        profile_path_allowed?(item.fetch("Path"), roots) &&
        File.realpath(item.fetch("Path")) == item.fetch("WritePath")
      raise InvalidConfigError, "配置事务记录包含重复目标" if seen[item.fetch("WritePath")]

      seen[item.fetch("WritePath")] = true
      original = Base64.strict_decode64(item.fetch("OriginalBase64"))
      current = File.binread(item.fetch("WritePath"))
      current_digest = Digest::SHA256.hexdigest(current)
      original_digest = Digest::SHA256.hexdigest(original)
      next if current_digest == original_digest
      unless current_digest == item.fetch("CandidateSha256")
        next if allowed_concurrent_paths[File.expand_path(item.fetch("Path"))]

        raise InvalidConfigError, "配置事务目标包含新的并发修改"
      end
      restored = atomic_compare_and_swap_bytes(
        item.fetch("Path"), current, original, expected_path: item.fetch("WritePath")
      )
      raise IOError, "配置事务恢复失败" unless restored
    end
    remove_profile_transaction(snapshot) unless keep_transaction
    snapshot
  rescue ArgumentError, JSON::ParserError
    raise InvalidConfigError, "配置事务记录无效"
  end

  def prepare_profile_transaction(items, backup_root)
    root = secure_backup_root!(backup_root)
    path = profile_transaction_path(root)
    raise IOError, "发现尚未恢复的配置事务记录" if File.exist?(path) || File.symlink?(path)

    records = items.map do |item|
      {
        "Path" => File.expand_path(item.fetch(:path)),
        "WritePath" => File.realpath(item.fetch(:path)),
        "OriginalBase64" => Base64.strict_encode64(item.fetch(:original).b),
        "CandidateSha256" => Digest::SHA256.hexdigest(item.fetch(:candidate).b)
      }
    end
    raise InvalidConfigError, "配置事务包含重复目标" unless
      records.map { |record| record.fetch("WritePath") }.uniq.length == records.length

    bytes = (JSON.generate("Version" => 1, "Items" => records) + "\n").b
    Tempfile.create([".claude-easy-profile-transaction-", ".tmp"], root) do |temporary|
      temporary.binmode
      temporary.write(bytes)
      temporary.flush
      temporary.fsync
      File.chmod(0o600, temporary.path)
      File.rename(temporary.path, path)
    end
    regular_file_snapshot_once(path, "配置事务记录")
  end

  def profile_work_items(roots, selected, active_root)
    roots.flat_map do |root|
      paths = profile_paths(root)
      unless active_profile?(File.join(root, "config.yaml"), selected)
        paths = paths.reject { |path| File.basename(path).casecmp("config.yaml").zero? }
      end
      paths.map do |path|
        {
          path: path,
          active: active_root &&
            File.expand_path(File.dirname(path)) == File.expand_path(active_root) &&
            active_profile?(path, selected)
        }
      end
    end
  end

  def resume_profile_transaction(backup_root, roots:, work_items:, reload_runtime:,
                                 require_tun:, socket: nil, requester: nil,
                                 connectivity_checker: nil, precommit_condition: nil)
    pending = profile_transaction_pending?(backup_root)
    transaction = recover_profile_transaction(
      backup_root, roots: roots, keep_transaction: pending
    )
    return :none unless pending
    return :runtime_restore_pending unless
      reload_runtime &&
      reload_recovered_profile_runtime(
        work_items, require_tun: require_tun, socket: socket, requester: requester,
        connectivity_checker: connectivity_checker,
        precommit_condition: precommit_condition
      )

    remove_profile_transaction(transaction)
    :recovered
  end

  def recover_pending_profile_transaction(backup_root, directories:, selected_name: nil,
                                          guard_storage: false, expected_storage: nil)
    operation_lock = profile_operation_lock(backup_root)
    return :none unless profile_transaction_pending?(backup_root)

    runtime_context = if selected_name.nil?
                        capture_runtime_profile_context(
                          directories, guard_storage: guard_storage,
                          expected_storage: expected_storage
                        )
                      end
    return :runtime_restore_pending if selected_name.nil? && runtime_context.nil?

    selected = runtime_context ? runtime_context.fetch(:selected) : selected_name
    precommit_condition = if runtime_context
                            lambda do
                              runtime_profile_context_current?(
                                runtime_context, directories,
                                guard_storage: guard_storage
                              )
                            end
                          end
    active_root = active_profile_root(directories, selected)
    work_items = profile_work_items(directories, selected, active_root)
    resume_profile_transaction(
      backup_root, roots: directories, work_items: work_items, reload_runtime: true,
      require_tun: :preserve, precommit_condition: precommit_condition
    )
  ensure
    operation_lock&.close
  end

  def patch_path_once(path, policy, dry_run:, backup_root:, validator:, usage_profile: 3,
                      capture_transaction: false, expected_original: nil)
    write_path = File.realpath(path)
    outcome = nil
    File.open(write_path, dry_run ? "rb" : "r+b") do |source|
      lock_exclusive_with_timeout(source)
      original_bytes = source.read
      if expected_original && original_bytes.b != expected_original.b
        return base_result(nil, :concurrent_change).merge(path: path, transaction_commit: false)
      end
      original_text = original_bytes.dup.force_encoding(Encoding::UTF_8)
      raise InvalidConfigError, "配置不是有效的 UTF-8" unless original_text.valid_encoding?

      config = load_yaml(original_text, path)
      result = patch(config, policy, usage_profile: usage_profile)
      unless result[:changed]
        preview = result.merge(path: path)
        if dry_run && capture_transaction
          preview[:transaction_original] = original_bytes.b
          preview[:transaction_candidate] = original_bytes.b
        end
        return preview
      end

      patched_text = dump_config(result[:config])
      candidate_config = load_yaml(patched_text, path)
      second_pass = patch(candidate_config, policy, usage_profile: usage_profile)
      if second_pass[:changed] || second_pass[:config] != candidate_config
        return base_result(config, :non_idempotent).merge(path: path)
      end
      Tempfile.create([File.basename(write_path), ".tmp"], File.dirname(write_path), encoding: "UTF-8") do |temporary|
        temporary.write(patched_text)
        temporary.flush
        temporary.fsync
        load_yaml(File.read(temporary.path, encoding: "UTF-8"), temporary.path)
        unless validator.nil?
          validation = validator.call(temporary.path)
          if validation == :timeout
            return base_result(config, :validation_timeout).merge(path: path)
          end
          unless validation == true
            return base_result(config, :validation_failed).merge(path: path)
          end
        end
        if dry_run
          preview = result.merge(path: path, dry_run: true)
          if capture_transaction
            preview[:transaction_original] = original_bytes.b
            preview[:transaction_candidate] = patched_text.b
          end
          return preview
        end

        source.rewind
        if !locked_source_current?(source, path, write_path) || source.read != original_bytes
          outcome = :retry
        else
          create_versioned_backup(path, backup_root, content: original_bytes, reason: "prewrite") if backup_root
          source.rewind
          if !locked_source_current?(source, path, write_path) || source.read != original_bytes
            outcome = :retry
          else
            patched_bytes = File.binread(temporary.path)
            swapped = atomic_replace_locked(source, path, write_path, original_bytes, patched_bytes)
            outcome = if swapped
                        committed = File.stat(write_path)
                        result.merge(
                          path: path,
                          rollback_bytes: original_bytes,
                          patched_digest: Digest::SHA256.hexdigest(patched_bytes),
                          patched_identity: [committed.dev, committed.ino],
                          patched_path: write_path
                        )
                      else
                        :retry
                      end
          end
        end
      end
    end
    outcome
  end

  def patch_path(path, policy, dry_run: false, backup_root: nil, validator: nil, usage_profile: 3,
                 capture_transaction: false, expected_original: nil)
    MAX_PATCH_ATTEMPTS.times do
      outcome = patch_path_once(
        path, policy, dry_run: dry_run, backup_root: backup_root,
        validator: validator, usage_profile: usage_profile,
        capture_transaction: capture_transaction,
        expected_original: expected_original
      )
      return outcome unless outcome == :retry
    end
    base_result(nil, :concurrent_change).merge(path: path)
  rescue Psych::Exception, JSON::ParserError, InvalidConfigError, SystemStackError
    base_result(nil, :invalid).merge(path: path)
  rescue SystemCallError, IOError
    base_result(nil, :io_error).merge(path: path)
  rescue StandardError
    base_result(nil, :error).merge(path: path)
  end

  def run(directory: nil, directories: nil, policy_path:, dry_run: false, backup_root: nil,
          selected_name: nil, active_directory: nil, validator: nil, auto_reload: false,
          socket: nil, requester: nil, connectivity_checker: nil, usage_profile: 3,
          guard_storage: false, expected_storage: nil)
    policy = JSON.parse(File.read(policy_path, encoding: "UTF-8"))
    unless policy.is_a?(Hash) && policy["version"] == POLICY_VERSION
      raise InvalidConfigError, "不支持的策略版本"
    end
    roots = directories || (directory ? [directory] : default_profile_directories)
    needs_runtime_context = selected_name.nil? && !dry_run
    runtime_context = if needs_runtime_context
                        capture_runtime_profile_context(
                          roots, guard_storage: guard_storage,
                          expected_storage: expected_storage
                        )
                      end
    if needs_runtime_context && runtime_context.nil?
      return roots.flat_map { |root| profile_paths(root) }.map do |path|
        base_result(nil, :concurrent_change).merge(path: path, active: false)
      end
    end
    selected = runtime_context ? runtime_context.fetch(:selected) :
      (selected_name.nil? ? selected_profile_name : selected_name)
    precommit_condition = if runtime_context
                            lambda do
                              runtime_profile_context_current?(
                                runtime_context, roots, guard_storage: guard_storage
                              )
                            end
                          end
    active_root = active_directory || active_profile_root(roots, selected, directory)
    operation_lock = profile_operation_lock(backup_root) if !dry_run && backup_root
    begin
      work_items = profile_work_items(roots, selected, active_root)
      if !dry_run && backup_root
        recovery = resume_profile_transaction(
          backup_root, roots: roots, work_items: work_items, reload_runtime: auto_reload,
          require_tun: usage_profile >= 2, socket: socket, requester: requester,
          connectivity_checker: connectivity_checker,
          precommit_condition: precommit_condition
        )
        if recovery == :runtime_restore_pending
          return work_items.map do |item|
            status = item.fetch(:active) ? :reload_failed_restore_pending : :batch_aborted
            base_result(nil, status).merge(path: item.fetch(:path), active: item.fetch(:active))
          end
        end
      end
      identities = work_items.map do |item|
        stat = File.stat(File.realpath(item.fetch(:path)))
        [stat.dev, stat.ino]
      end
      if identities.uniq.length != identities.length
        return work_items.map do |item|
          base_result(nil, :duplicate_target).merge(path: item.fetch(:path), active: item.fetch(:active))
        end
      end

      results = nil
      MAX_PATCH_ATTEMPTS.times do |batch_attempt|
        preflight = work_items.map do |item|
          result = patch_path(
            item.fetch(:path), policy, dry_run: true, backup_root: nil,
            validator: validator, usage_profile: usage_profile,
            capture_transaction: !dry_run && !backup_root.nil?
          )
          result[:active] = item.fetch(:active)
          result
        end
        return preflight if dry_run

        unless preflight.all? { |result| %i[updated unchanged].include?(result[:status]) }
          return preflight.map do |result|
            result[:status] == :updated ? result.merge(status: :batch_aborted, dry_run: false) : result
          end
        end

        transaction = nil
        if backup_root
          transaction_items = work_items.zip(preflight).each_with_object([]) do |(item, preview), output|
            next unless preview.fetch(:status) == :updated
            output << {
              path: item.fetch(:path),
              original: preview.fetch(:transaction_original),
              candidate: preview.fetch(:transaction_candidate)
            }
          end
          transaction = prepare_profile_transaction(transaction_items, backup_root) unless transaction_items.empty?
        end

        results = []
        transaction_expectations = if backup_root
                                     work_items.zip(preflight).to_h do |item, preview|
                                       [
                                         File.expand_path(item.fetch(:path)),
                                         {
                                           original: preview.fetch(:transaction_original)
                                         }
                                       ]
                                     end
                                   else
                                     {}
                                   end
        work_items.sort_by { |item| item.fetch(:active) ? 1 : 0 }.each do |item|
          path = item.fetch(:path)
          expectation = transaction_expectations[File.expand_path(path)]
          result = patch_path(
            path, policy, dry_run: dry_run, backup_root: backup_root,
            validator: validator, usage_profile: usage_profile,
            expected_original: expectation&.fetch(:original)
          )
          result[:active] = item.fetch(:active)
          if auto_reload && !dry_run && result[:active] && result[:status] == :updated
            result = activate_updated_profile(
              result,
              socket: socket,
              requester: requester,
              connectivity_checker: connectivity_checker,
              require_tun: usage_profile >= 2,
              precommit_condition: precommit_condition
            )
          end
          results << result
          next if %i[updated unchanged].include?(result[:status])

          results.reverse_each do |prior|
            next unless prior[:status] == :updated

            prior[:status] = restore_profile_bytes(prior) ? :batch_rolled_back : :batch_rollback_failed
          end
          break
        end

        batch_committed = results.length == work_items.length &&
                          results.all? { |result| %i[updated unchanged].include?(result.fetch(:status)) }
        runtime_committed = results.any? do |result|
          result[:active] && result[:status] == :updated && result[:reloaded] == true
        end
        if batch_committed &&
           !runtime_committed &&
           results.any? { |result| result[:status] == :updated } &&
           !runtime_precommit_allowed?(precommit_condition)
          results.reverse_each do |result|
            next unless result[:status] == :updated

            result[:status] = restore_profile_bytes(result) ? :batch_rolled_back : :batch_rollback_failed
          end
        end

        if transaction
          if results.length == work_items.length &&
             results.all? { |result| %i[updated unchanged].include?(result.fetch(:status)) }
            remove_profile_transaction(transaction)
          else
            allowed_concurrent_paths = results.each_with_object([]) do |result, paths|
              if result[:status] == :concurrent_change && result[:transaction_commit] == false
                paths << result.fetch(:path)
              end
            end
            recover_profile_transaction(
              backup_root, roots: roots, allow_concurrent_paths: allowed_concurrent_paths,
              keep_transaction: results.any? do |result|
                result[:status] == :reload_failed_restore_pending
              end
            )
          end
        end

        retryable = results.any? do |result|
          result[:status] == :concurrent_change && result[:transaction_commit] == false
        end
        retryable &&= results.none? { |result| result[:status] == :batch_rollback_failed }
        return results unless retryable && batch_attempt + 1 < MAX_PATCH_ATTEMPTS
      end
    ensure
      operation_lock&.close
    end
  end

end
