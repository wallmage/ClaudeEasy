module ClaudeEasy
  module_function

  class ProfileCommitStateUncertainError < IOError; end

  LOCK_TIMEOUT_SECONDS = 5
  PROFILE_TRANSACTION_BASENAME = ".claude-easy-profile-transaction.json".freeze
  PROFILE_OPERATION_LOCK_BASENAME = ".claude-easy-operation.lock".freeze
  PROFILE_TRANSACTION_COMMITTED_BYTES = (JSON.generate("Version" => 3, "Committed" => true) + "\n").b.freeze

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

  def transactional_replace_locked(source, path, write_path, expected_bytes, replacement_bytes)
    expected_bytes = expected_bytes.b
    replacement_bytes = replacement_bytes.b
    source.rewind
    return false unless locked_source_current?(source, path, write_path) &&
                        source.read.b == expected_bytes

    write_locked_bytes(source, replacement_bytes, expected_bytes)
    source.rewind
    return false unless source.read.b == replacement_bytes

    locked_source_current?(source, path, write_path)
  end

  def transactional_compare_and_write_bytes(path, expected_bytes, replacement_bytes,
                                            expected_identity: nil, expected_path: nil)
    expected_bytes = expected_bytes.b
    replacement_bytes = replacement_bytes.b
    write_path = File.realpath(path)
    return false if expected_path && write_path != expected_path

    File.open(write_path, "r+b") do |source|
      lock_exclusive_with_timeout(source)
      if expected_identity
        stat = source.stat
        return false unless [stat.dev, stat.ino] == expected_identity
      end
      transactional_replace_locked(source, path, write_path, expected_bytes, replacement_bytes)
    end
  rescue SystemCallError, IOError
    false
  end

  def write_locked_bytes(source, replacement_bytes, original_bytes)
    source.rewind
    source.truncate(0)
    written = source.write(replacement_bytes)
    raise IOError, "配置写入不完整" unless written == replacement_bytes.bytesize

    source.flush
    source.fsync
    true
  rescue SystemCallError, IOError => write_error
    begin
      source.rewind
      source.truncate(0)
      restored = source.write(original_bytes)
      raise IOError, "原配置恢复不完整" unless restored == original_bytes.bytesize

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

  def profile_operation_lock(backup_root)
    root = secure_backup_root!(backup_root)
    path = File.join(root, PROFILE_OPERATION_LOCK_BASENAME)
    handle = ClaudeEasyOperationLock.open_private_lock(path)
    lock_exclusive_with_timeout(handle)
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

  def cleanup_committed_profile_transaction(backup_root)
    path = profile_transaction_path(backup_root)
    return :none unless File.exist?(path) || File.symlink?(path)

    snapshot = regular_file_snapshot_once(path, "配置事务记录")
    return :pending unless snapshot.fetch(:bytes) == PROFILE_TRANSACTION_COMMITTED_BYTES

    remove_profile_transaction(snapshot)
    :committed
  end

  def fsync_parent_directory(path)
    directory = File.dirname(File.expand_path(path))
    File.open(directory, File::RDONLY) do |handle|
      handle.fsync
    end
    true
  end

  def profile_path_allowed?(path, roots)
    expanded = File.expand_path(path)
    roots.any? do |root|
      candidates = [File.expand_path(root)]
      candidates << File.realpath(root)
      candidates.uniq.any? do |candidate|
        expanded.start_with?(candidate + File::SEPARATOR)
      end
    rescue SystemCallError
      expanded.start_with?(File.expand_path(root) + File::SEPARATOR)
    end
  end

  def remove_profile_transaction(snapshot, state_uncertain_on_sync_failure: false)
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

      unless snapshot.fetch(:bytes) == PROFILE_TRANSACTION_COMMITTED_BYTES
        Tempfile.create([".claude-easy-profile-committed-", ".tmp"], File.dirname(path)) do |temporary|
          temporary.binmode
          temporary.write(PROFILE_TRANSACTION_COMMITTED_BYTES)
          temporary.flush
          temporary.fsync
          temporary.chmod(0o600)
          current = File.lstat(path)
          handle.rewind
          raise IOError, "配置事务记录同时发生变化" unless
            current.file? && !current.symlink? &&
            [current.dev, current.ino] == snapshot.fetch(:identity) &&
            handle.read.b == snapshot.fetch(:bytes)

          File.rename(temporary.path, path)
          begin
            fsync_parent_directory(path)
          rescue SystemCallError, IOError
            raise ProfileCommitStateUncertainError, "配置事务提交状态无法确认" if
              state_uncertain_on_sync_failure
            raise
          end
        end
      end
    end

    begin
      committed = regular_file_snapshot_once(path, "配置事务已提交标记")
      raise IOError, "配置事务已提交标记同时发生变化" unless
        committed.fetch(:bytes) == PROFILE_TRANSACTION_COMMITTED_BYTES

      current = File.lstat(path)
      File.unlink(path) if [current.dev, current.ino] == committed.fetch(:identity)
      fsync_parent_directory(path)
    rescue SystemCallError, IOError
      # The durable committed marker makes a reappearing or retained journal safe to clean later.
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
    if state == { "Version" => 3, "Committed" => true }
      remove_profile_transaction(snapshot)
      return :committed
    end
    valid_state = state.is_a?(Hash) && state.keys.sort == %w[Items Version] &&
                  [1, 2].include?(state["Version"]) && state["Items"].is_a?(Array) &&
                  !state["Items"].empty?
    raise InvalidConfigError, "配置事务记录无效" unless valid_state

    seen = {}
    state.fetch("Items").each do |item|
      version = state.fetch("Version")
      expected_keys = if version == 1
                        %w[CandidateSha256 OriginalBase64 Path WritePath]
                      else
                        %w[CandidateBase64 CandidateSha256 OriginalBase64 OriginalIdentity Path WritePath]
                      end
      valid_item = item.is_a?(Hash) && item.keys.sort == expected_keys.sort &&
                   item["Path"].is_a?(String) && item["WritePath"].is_a?(String) &&
                   item["OriginalBase64"].is_a?(String) &&
                   item["CandidateSha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
      if version == 2
        identity = item["OriginalIdentity"]
        valid_item &&= item["CandidateBase64"].is_a?(String) &&
                       identity.is_a?(Array) && identity.length == 2 &&
                       identity.all? { |value| value.is_a?(Integer) && value >= 0 }
      end
      raise InvalidConfigError, "配置事务记录无效" unless valid_item
      logical_path = item.fetch("Path")
      write_path = item.fetch("WritePath")
      raise InvalidConfigError, "配置事务记录路径无效" unless
        logical_path == File.expand_path(logical_path) &&
        write_path == File.expand_path(write_path) &&
        profile_path_allowed?(logical_path, roots) &&
        profile_path_allowed?(write_path, roots)
      raise InvalidConfigError, "配置事务记录包含重复目标" if seen[write_path]

      seen[write_path] = true
      original = Base64.strict_decode64(item.fetch("OriginalBase64"))
      begin
        target = File.lstat(write_path)
        next unless target.file? && !target.symlink? && target.nlink == 1
        next unless File.realpath(write_path) == write_path

        current_snapshot = regular_file_snapshot_once(write_path, "配置事务目标")
      rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
        next
      end
      current = current_snapshot.fetch(:bytes)
      if version == 2
        candidate = Base64.strict_decode64(item.fetch("CandidateBase64"))
        raise InvalidConfigError, "配置事务记录无效" unless
          Digest::SHA256.hexdigest(candidate) == item.fetch("CandidateSha256")

        expected_identity = item.fetch("OriginalIdentity")
        next unless current_snapshot.fetch(:identity) == expected_identity
        next if current == original
        raise InvalidConfigError, "配置事务目标处于无法安全判定的部分写入状态" unless
          current == candidate

        restored = transactional_compare_and_write_bytes(
          write_path, current, original,
          expected_identity: expected_identity, expected_path: write_path
        )
        unless restored
          latest = regular_file_snapshot_once(write_path, "配置事务目标")
          next unless latest.fetch(:identity) == expected_identity
          next if latest.fetch(:bytes) == original

          raise IOError, "配置事务恢复失败"
        end
        next
      end

      current_digest = Digest::SHA256.hexdigest(current)
      original_digest = Digest::SHA256.hexdigest(original)
      next if current_digest == original_digest
      next if current_digest != item.fetch("CandidateSha256") &&
              allowed_concurrent_paths[File.expand_path(logical_path)]

      raise InvalidConfigError, "旧版配置事务缺少文件身份，不能自动恢复"
    end
    remove_profile_transaction(snapshot) unless keep_transaction
    snapshot
  rescue ArgumentError, JSON::ParserError
    raise InvalidConfigError, "配置事务记录无效"
  end

  def prepare_profile_transaction(items, backup_root, roots:)
    root = secure_backup_root!(backup_root)
    path = profile_transaction_path(root)
    raise IOError, "发现尚未恢复的配置事务记录" if File.exist?(path) || File.symlink?(path)

    records = items.map do |item|
      logical_path = File.expand_path(item.fetch(:path))
      write_path = File.realpath(logical_path)
      raise InvalidConfigError, "配置事务目标路径无效" unless
        profile_path_allowed?(logical_path, roots) &&
        profile_path_allowed?(write_path, roots)

      current = regular_file_snapshot_once(write_path, "当前配置")
      raise ConcurrentProfileChangeError, "配置在事务建立前发生变化" unless
        current.fetch(:bytes) == item.fetch(:original).b &&
        File.realpath(logical_path) == write_path

      candidate = item.fetch(:candidate).b
      {
        "Path" => logical_path,
        "WritePath" => write_path,
        "OriginalBase64" => Base64.strict_encode64(item.fetch(:original).b),
        "OriginalIdentity" => current.fetch(:identity),
        "CandidateBase64" => Base64.strict_encode64(candidate),
        "CandidateSha256" => Digest::SHA256.hexdigest(candidate)
      }
    end
    raise InvalidConfigError, "配置事务包含重复目标" unless
      records.map { |record| record.fetch("WritePath") }.uniq.length == records.length

    bytes = (JSON.generate("Version" => 2, "Items" => records) + "\n").b
    Tempfile.create([".claude-easy-profile-transaction-", ".tmp"], root) do |temporary|
      temporary.binmode
      temporary.write(bytes)
      temporary.flush
      temporary.fsync
      temporary.chmod(0o600)
      ClaudeEasyDarwinFilesystem.rename_exclusive(temporary.path, path)
      fsync_parent_directory(path)
    end
    snapshot = regular_file_snapshot_once(path, "配置事务记录")
    targets = records.to_h do |record|
      [
        record.fetch("Path"),
        {
          write_path: record.fetch("WritePath"),
          identity: record.fetch("OriginalIdentity")
        }
      ]
    end
    snapshot.merge(targets: targets)
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
    return :recovered if transaction == :committed
    return :runtime_restore_pending unless
      reload_runtime &&
      reload_recovered_profile_runtime(
        work_items, require_tun: require_tun, socket: socket, requester: requester,
        connectivity_checker: connectivity_checker,
        precommit_condition: precommit_condition
      )
    return :runtime_restore_pending unless
      runtime_precommit_allowed?(precommit_condition)

    remove_profile_transaction(transaction)
    :recovered
  end

  def recover_pending_profile_transaction(backup_root, directories:, selected_name: nil,
                                          guard_storage: false, expected_storage: nil)
    operation_lock = profile_operation_lock(backup_root)
    transaction_state = cleanup_committed_profile_transaction(backup_root)
    return :recovered if transaction_state == :committed
    return :profile_directory_missing if directories.empty?
    return :none if transaction_state == :none

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
                      capture_transaction: false, expected_original: nil,
                      expected_identity: nil, expected_path: nil)
    write_path = File.realpath(path)
    outcome = nil
    File.open(write_path, dry_run ? "rb" : "r+b") do |source|
      lock_exclusive_with_timeout(source)
      opened = source.stat
      if (expected_path && write_path != expected_path) ||
         (expected_identity && [opened.dev, opened.ino] != expected_identity)
        return base_result(nil, :concurrent_change).merge(
          path: path, transaction_commit: false
        )
      end
      original_bytes = source.read
      if expected_original && original_bytes.b != expected_original.b
        return base_result(nil, :concurrent_change).merge(path: path, transaction_commit: false)
      end
      original_text = original_bytes.dup.force_encoding(Encoding::UTF_8)
      raise InvalidConfigError, "配置不是有效的 UTF-8" unless original_text.valid_encoding?

      config = load_yaml(original_text, path)
      result = patch(config, policy, usage_profile: usage_profile)
      unless result[:changed]
        unless validator.nil?
          Tempfile.create(
            [File.basename(write_path), ".tmp"], File.dirname(write_path), encoding: "UTF-8"
          ) do |temporary|
            temporary.write(original_text)
            temporary.flush
            temporary.fsync
            validation = validator.call(temporary.path)
            if validation == :timeout
              return base_result(config, :validation_timeout).merge(path: path)
            end
            unless validation == true
              return base_result(config, :validation_failed).merge(path: path)
            end
          end
        end
        preview = result.merge(
          path: path,
          patched_digest: Digest::SHA256.hexdigest(original_bytes.b),
          patched_identity: [opened.dev, opened.ino],
          patched_path: write_path
        )
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
            written = transactional_replace_locked(source, path, write_path, original_bytes, patched_bytes)
            outcome = if written
                        committed = source.stat
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
                 capture_transaction: false, expected_original: nil,
                 expected_identity: nil, expected_path: nil)
    MAX_PATCH_ATTEMPTS.times do
      outcome = patch_path_once(
        path, policy, dry_run: dry_run, backup_root: backup_root,
        validator: validator, usage_profile: usage_profile,
        capture_transaction: capture_transaction,
        expected_original: expected_original,
        expected_identity: expected_identity, expected_path: expected_path
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
        if backup_root && preflight.any? { |preview| preview.fetch(:status) == :updated }
          transaction_items = work_items.zip(preflight).map do |item, preview|
            {
              path: item.fetch(:path),
              original: preview.fetch(:transaction_original),
              candidate: preview.fetch(:transaction_candidate)
            }
          end
          begin
            transaction = prepare_profile_transaction(
              transaction_items, backup_root, roots: roots
            )
          rescue ConcurrentProfileChangeError
            if batch_attempt + 1 < MAX_PATCH_ATTEMPTS
              next
            end
            return preflight.map do |result|
              result.merge(status: :concurrent_change, dry_run: false, transaction_commit: false)
            end
          end
        end

        results = []
        transaction_expectations = if backup_root
                                     work_items.zip(preflight).to_h do |item, preview|
                                       expanded_path = File.expand_path(item.fetch(:path))
                                       target = transaction && transaction.fetch(:targets).fetch(expanded_path)
                                       [
                                         expanded_path,
                                         {
                                           original: preview.fetch(:transaction_original),
                                           candidate: preview.fetch(:transaction_candidate),
                                           identity: target&.fetch(:identity),
                                           write_path: target&.fetch(:write_path)
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
            expected_original: expectation&.fetch(:original),
            expected_identity: expectation&.fetch(:identity),
            expected_path: expectation&.fetch(:write_path)
          )
          if transaction && result[:status] == :unchanged
            result = result.merge(
              rollback_bytes: expectation.fetch(:original),
              patched_digest: Digest::SHA256.hexdigest(expectation.fetch(:candidate)),
              patched_identity: expectation.fetch(:identity),
              patched_path: expectation.fetch(:write_path)
            )
          end
          result[:active] = item.fetch(:active)
          if !dry_run && result[:active]
            if auto_reload && result[:status] == :updated
              result = activate_updated_profile(
                result,
                socket: socket,
                requester: requester,
                connectivity_checker: connectivity_checker,
                require_tun: usage_profile >= 2,
                precommit_condition: precommit_condition,
                require_safe_ai: usage_profile == 3
              )
            elsif result[:status] == :unchanged
              result = verify_unchanged_profile_runtime(
                result, socket: socket, requester: requester,
                connectivity_checker: connectivity_checker,
                precommit_condition: precommit_condition,
                require_tun: usage_profile >= 2,
                require_safe_ai: usage_profile == 3
              )
            end
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
        if batch_committed &&
           results.any? { |result| result[:status] == :updated } &&
           !runtime_precommit_allowed?(precommit_condition)
          results.reverse_each do |result|
            next unless result[:status] == :updated

            restored = restore_profile_bytes(result)
            if result[:active] && result[:reloaded] == true
              result.delete(:reloaded)
              result[:status] = restored ?
                :reload_failed_restore_pending : :reload_failed_rollback_conflict
            else
              result[:status] = restored ? :batch_rolled_back : :batch_rollback_failed
            end
          end
        end

        if !transaction && results.length == work_items.length &&
           results.all? { |result| %i[updated unchanged].include?(result.fetch(:status)) }
          results.reject { |result| profile_result_current?(result) }.each do |result|
            result[:status] = :concurrent_change
            result[:transaction_commit] = false
          end
        end

        if transaction
          if results.length == work_items.length &&
             results.all? { |result| %i[updated unchanged].include?(result.fetch(:status)) }
            stale = results.reject { |result| profile_result_current?(result) }
            if stale.empty?
              remove_profile_transaction(transaction, state_uncertain_on_sync_failure: true)
            else
              runtime_committed = results.any? do |result|
                result[:active] && result[:reloaded] == true
              end
              stale.each do |result|
                result.delete(:reloaded)
                result[:status] = :concurrent_change
                result[:transaction_commit] = true
              end
              recovery = begin
                recover_profile_transaction(
                  backup_root, roots: roots,
                  allow_concurrent_paths: stale.map { |result| result.fetch(:path) },
                  keep_transaction: runtime_committed
                )
              rescue StandardError
                nil
              end
              results.each do |result|
                next unless result[:status] == :updated

                result.delete(:reloaded)
                result[:status] = recovery ? :batch_rolled_back : :batch_rollback_failed
              end
              if runtime_committed
                restored_runtime = recovery && reload_recovered_profile_runtime(
                  work_items, require_tun: usage_profile >= 2,
                  socket: socket, requester: requester,
                  connectivity_checker: connectivity_checker,
                  precommit_condition: precommit_condition
                ) && runtime_precommit_allowed?(precommit_condition)
                if restored_runtime
                  begin
                    remove_profile_transaction(recovery)
                  rescue StandardError
                    restored_runtime = false
                  end
                end
                unless restored_runtime
                  active_result = results.find { |result| result[:active] }
                  active_result[:status] = :reload_failed_restore_pending if active_result
                end
              end
            end
          else
            allowed_concurrent_paths = results.each_with_object([]) do |result, paths|
              if result[:status] == :concurrent_change && result[:transaction_commit] == false
                paths << result.fetch(:path)
              end
            end
            recover_profile_transaction(
              backup_root, roots: roots, allow_concurrent_paths: allowed_concurrent_paths,
              keep_transaction: results.any? do |result|
                %i[reload_failed_restore_pending reload_failed_rollback_conflict].include?(
                  result[:status]
                )
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
