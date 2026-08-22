module ClaudeEasy
  module_function

  BACKUP_FILENAME_PATTERN = /\A(?<timestamp>\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.\d{9}[+-]\d{4})--(?<reason>[a-z][a-z0-9-]{0,31})--(?<key>[0-9a-f]{16})(?:--.+)?\.backup\z/

  def excluded_path?(path)
    basename = File.basename(path)
    basename.start_with?(".") || basename.match?(/(?:^|[._-])(?:bak|backup|claude-easy)(?:[._-]|\z)/i) ||
      basename.match?(/(?:\.tmp|\.bak|\.backup)\z/i)
  end

  def profile_paths(directory)
    return [] unless Dir.exist?(directory)

    Dir.children(directory).sort.map do |basename|
      path = File.join(directory, basename)
      next if excluded_path?(path)
      next if File.symlink?(path)
      next unless basename.match?(/\.ya?ml\z/i) && File.file?(path)

      path
    end.compact
  end

  def backup_key(path)
    Digest::SHA256.hexdigest(File.expand_path(path))[0, 16]
  end

  def fsync_directory(path)
    expanded = File.expand_path(path)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    File.open(expanded, flags) do |handle|
      opened = handle.stat
      current = File.lstat(expanded)
      raise IOError, "备份目录在发布时发生变化" unless
        opened.directory? && current.directory? && !current.symlink? &&
        [opened.dev, opened.ino] == [current.dev, current.ino]

      handle.fsync
    end
    true
  end

  def ensure_durable_private_directory(path)
    target = File.expand_path(path)
    missing = []
    cursor = target
    loop do
      begin
        current = File.lstat(cursor)
        raise InvalidConfigError, "备份位置不是安全目录" unless
          current.directory? && !current.symlink?
        break
      rescue Errno::ENOENT
        missing << cursor
        parent = File.dirname(cursor)
        raise InvalidConfigError, "备份位置不是安全目录" if parent == cursor

        cursor = parent
      end
    end

    existing_parent = File.dirname(cursor)
    fsync_directory(existing_parent) unless existing_parent == cursor
    missing.reverse_each do |directory|
      begin
        Dir.mkdir(directory, 0o700)
      rescue Errno::EEXIST
        current = File.lstat(directory)
        raise InvalidConfigError, "备份位置不是安全目录" unless
          current.directory? && !current.symlink?
      end
      FileUtils.chmod(0o700, directory)
      fsync_directory(directory)
      fsync_directory(File.dirname(directory))
    end
    target
  end

  def secure_backup_root!(backup_root)
    root = File.expand_path(backup_root)
    raise InvalidConfigError, "备份目录不能是符号链接" if File.symlink?(root)
    raise InvalidConfigError, "备份位置不是目录" if File.exist?(root) && !File.directory?(root)

    ensure_durable_private_directory(root)
    FileUtils.chmod(0o700, root)
    Dir.children(root).each do |name|
      path = File.join(root, name)
      next unless name.end_with?(".backup") && File.file?(path) && !File.symlink?(path)

      FileUtils.chmod(0o600, path)
    rescue SystemCallError
      next
    end
    root
  end

  def backup_entries_for(path, backup_root, reason: nil)
    root = File.expand_path(backup_root)
    return [] unless File.directory?(root) && !File.symlink?(root)

    key = backup_key(path)
    Dir.children(root).select do |name|
      match = BACKUP_FILENAME_PATTERN.match(name)
      match && match[:key] == key && (!reason || match[:reason] == reason) &&
        File.file?(File.join(root, name)) && !File.symlink?(File.join(root, name))
    end.sort.map { |name| File.join(root, name) }
  end

  def create_versioned_backup(path, backup_root, content: nil, reason: "prewrite")
    raise InvalidConfigError, "备份原因无效" unless reason.match?(/\A[a-z][a-z0-9-]{0,31}\z/)

    root = secure_backup_root!(backup_root)
    bytes = content.nil? ? regular_file_snapshot_once(path, "备份源").fetch(:bytes) : content.b
    key = backup_key(path)
    destination = nil
    Tempfile.create([".claude-easy-backup-", ".tmp"], root) do |backup|
      backup.binmode
      backup.chmod(0o600)
      backup.write(bytes)
      backup.flush
      backup.fsync
      100.times do
        timestamp = Time.now.strftime("%Y-%m-%d_%H-%M-%S.%9N%z")
        candidate = File.join(root, "#{timestamp}--#{reason}--#{key}.backup")
        begin
          ClaudeEasyDarwinFilesystem.rename_exclusive(backup.path, candidate)
          destination = candidate
          break
        rescue Errno::EEXIST
          Thread.pass
        end
      end
      raise IOError, "无法创建唯一的版本化备份" unless destination
    end

    fsync_directory(root)
    destination
  end

  def snapshot_initial_profiles(directories, backup_root)
    directories.each_with_object([]) do |directory, snapshots|
      profile_paths(directory).each do |path|
        if backup_entries_for(path, backup_root, reason: "initial").empty?
          snapshots << create_versioned_backup(path, backup_root, reason: "initial")
        end
      end
    end
  end

  def backup_filenames(backup_root)
    root = File.expand_path(backup_root)
    return [] unless File.directory?(root) && !File.symlink?(root)

    Dir.children(root).select do |name|
      path = File.join(root, name)
      match = BACKUP_FILENAME_PATTERN.match(name)
      match && match[:reason] != "preference" &&
        File.file?(path) && !File.symlink?(path)
    end.sort.reverse
  end

  def public_backup_id(filename)
    "ce-backup-v1-#{Digest::SHA256.hexdigest(File.basename(filename.to_s))}"
  end

  def backup_created_at(filename)
    match = BACKUP_FILENAME_PATTERN.match(File.basename(filename.to_s))
    raise InvalidConfigError, "备份编号无效" unless match

    Time.strptime(match[:timestamp], "%Y-%m-%d_%H-%M-%S.%N%z").iso8601(9)
  end

  def list_backups(backup_root)
    backup_filenames(backup_root).map do |filename|
      { "id" => public_backup_id(filename), "created_at" => backup_created_at(filename) }
    end
  end

  def resolve_backup_id(backup_id, backup_root)
    normalized = backup_id.to_s
    raise InvalidConfigError, "备份编号无效" unless normalized == File.basename(normalized)

    root = File.expand_path(backup_root)
    filename = if normalized.match?(/\Ace-backup-v1-[0-9a-f]{64}\z/)
                 matches = backup_filenames(root).select { |name| public_backup_id(name) == normalized }
                 raise InvalidConfigError, "找不到指定备份" unless matches.length == 1

                 matches.first
               else
                 raise InvalidConfigError, "备份编号无效" unless normalized.end_with?(".backup")

                 normalized
               end
    path = File.join(root, filename)
    raise InvalidConfigError, "找不到指定备份" unless File.file?(path) && !File.symlink?(path)

    path
  end

  def regular_file_snapshot_once(path, label)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    File.open(path, flags) do |file|
      lock_exclusive_with_timeout(file)
      stat = file.stat
      raise InvalidConfigError, "#{label}不是普通文件" unless stat.file? && stat.nlink == 1

      current = File.lstat(path)
      raise InvalidConfigError, "#{label}在读取前发生变化" unless
        current.file? && !current.symlink? && current.dev == stat.dev && current.ino == stat.ino

      bytes = file.read.b
      after = file.stat
      raise InvalidConfigError, "#{label}在读取期间发生变化" unless
        after.dev == stat.dev && after.ino == stat.ino && after.size == bytes.bytesize

      { bytes: bytes, identity: [stat.dev, stat.ino], path: File.expand_path(path) }
    end
  end

  def read_regular_file_once(path, label)
    regular_file_snapshot_once(path, label).fetch(:bytes)
  end

  def find_backup_target(backup_id, directories)
    match = BACKUP_FILENAME_PATTERN.match(File.basename(backup_id.to_s))
    raise InvalidConfigError, "备份编号无效" unless match

    matches = directories.flat_map { |directory| profile_paths(directory) }.select do |path|
      backup_key(path) == match[:key]
    end
    raise InvalidConfigError, "备份无法对应到当前存储位置中的唯一配置" unless matches.length == 1

    matches.first
  end

  def redacted_changed_paths(before, after, prefix = nil, output = [], limit = 200)
    return output if output.length >= limit || before == after

    if before.is_a?(Hash) && after.is_a?(Hash)
      (before.keys | after.keys).map(&:to_s).sort.each do |key|
        break if output.length >= limit
        public_key = if %w[
          proxies proxy-groups proxy-providers rule-providers hosts
          dns.hosts dns.nameserver-policy script.shortcuts
        ].include?(prefix)
                       "[item]"
                     else
                       key
                     end
        path = prefix ? "#{prefix}.#{public_key}" : public_key
        before_key = before.key?(key) ? key : before.keys.find { |candidate| candidate.to_s == key }
        after_key = after.key?(key) ? key : after.keys.find { |candidate| candidate.to_s == key }
        if before_key.nil? || after_key.nil?
          output << path
        else
          redacted_changed_paths(before[before_key], after[after_key], path, output, limit)
        end
      end
    else
      output << (prefix || "配置")
    end
    output
  end

  def compare_backup(backup_id, directories:, backup_root:)
    backup_path = resolve_backup_id(backup_id, backup_root)
    physical_id = File.basename(backup_path)
    public_id = public_backup_id(physical_id)
    target = find_backup_target(physical_id, directories)
    backup_bytes = read_regular_file_once(backup_path, "备份")
    current_bytes = regular_file_snapshot_once(target, "当前配置").fetch(:bytes)
    backup_config = load_yaml(backup_bytes.dup.force_encoding(Encoding::UTF_8), public_id)
    current_config = load_yaml(current_bytes.dup.force_encoding(Encoding::UTF_8), target)
    {
      backup_id: public_id,
      same: backup_bytes == current_bytes,
      backup_sha256: Digest::SHA256.hexdigest(backup_bytes),
      current_sha256: Digest::SHA256.hexdigest(current_bytes),
      changes: redacted_changed_paths(backup_config, current_config).uniq
    }
  end

  def finish_backup_restore_transaction(transaction, result, precommit_condition: nil)
    successful = %i[updated no_change].include?(result.fetch(:status))
    if successful && !profile_result_current?(result)
      runtime_committed = result[:reloaded] == true
      result = result.dup
      result.delete(:reloaded)
      unless runtime_committed
        remove_profile_transaction(transaction) if backup_restore_transaction_releasable?(result)
        return result.merge(status: :restore_conflict)
      end

      restored_runtime = reload_recovered_profile_runtime(
        [{ path: result.fetch(:path), active: true }], require_tun: :preserve,
        precommit_condition: precommit_condition,
        runtime_checkpoint: transaction.is_a?(Hash) ? transaction[:runtime_checkpoint] : nil,
        transaction: transaction
      ) && runtime_precommit_allowed?(precommit_condition)
      if restored_runtime
        remove_profile_transaction(transaction)
        return result.merge(status: :restore_conflict)
      end

      return result.merge(status: :reload_failed_restore_pending)
    end
    if %i[updated no_change].include?(result.fetch(:status)) &&
       !runtime_precommit_allowed?(precommit_condition)
      restored = restore_profile_bytes(result)
      result = result.merge(
        status: restored ? :reload_failed_restore_pending : :reload_failed_rollback_conflict
      )
      result.delete(:reloaded)
      return result
    end
    if %i[updated no_change reload_failed_rolled_back].include?(result.fetch(:status))
      remove_profile_transaction(
        transaction,
        state_uncertain_on_sync_failure: %i[updated no_change].include?(result.fetch(:status))
      )
    end
    result
  end

  def backup_restore_transaction_releasable?(result)
    path = result.fetch(:path)
    expected_path = result.fetch(:patched_path)
    expected_identity = result.fetch(:patched_identity)
    original = result.fetch(:rollback_bytes)
    write_path = File.realpath(path)
    return true unless write_path == expected_path

    stat = File.stat(write_path)
    return true unless [stat.dev, stat.ino] == expected_identity

    regular_file_snapshot_once(write_path, "备份恢复目标").fetch(:bytes) == original
  rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
    true
  rescue SystemCallError, IOError, InvalidConfigError, KeyError
    false
  end

  def restore_backup(backup_id, directories:, backup_root:, expected_current_sha256:, validator:,
                     selected_name: nil, activation: nil, precommit_condition: nil,
                     runtime_checkpoint: nil, runtime_checkpoint_provider: nil)
    operation_lock = nil
    return { status: :restore_conflict } unless expected_current_sha256.to_s.match?(/\A[0-9a-f]{64}\z/i)

    operation_lock = profile_operation_lock(backup_root)
    if profile_transaction_pending?(backup_root)
      selected = selected_name.nil? ? selected_profile_name : selected_name
      active_root = active_profile_root(directories, selected)
      work_items = profile_work_items(directories, selected, active_root)
      recovery = resume_profile_transaction(
        backup_root, roots: directories, work_items: work_items, reload_runtime: true,
        require_tun: :preserve, precommit_condition: precommit_condition
      )
      if recovery == :runtime_restore_pending
        active = work_items.find { |item| item.fetch(:active) }
        return {
          status: :reload_failed_restore_pending,
          path: active&.fetch(:path), active: !active.nil?
        }
      end
    else
      recover_profile_transaction(backup_root, roots: directories)
    end
    backup_path = resolve_backup_id(backup_id, backup_root)
    physical_id = File.basename(backup_path)
    public_id = public_backup_id(physical_id)
    target = find_backup_target(physical_id, directories)
    write_path = File.realpath(target)
    if runtime_checkpoint_provider
      provided_checkpoint = runtime_checkpoint_provider.call(target)
      return { status: :runtime_state_unavailable, path: target } if provided_checkpoint == false

      runtime_checkpoint = provided_checkpoint
    end
    backup_bytes = read_regular_file_once(backup_path, "备份")
    backup_text = backup_bytes.dup.force_encoding(Encoding::UTF_8)
    raise InvalidConfigError, "备份不是有效的 UTF-8" unless backup_text.valid_encoding?

    load_yaml(backup_text, public_id)
    Tempfile.create([".claude-easy-restore-", ".yaml"], File.dirname(write_path)) do |temporary|
      temporary.binmode
      temporary.write(backup_bytes)
      temporary.flush
      temporary.fsync
      validation = validator.call(temporary.path)
      return { status: :validation_timeout, path: target } if validation == :timeout
      return { status: :validation_failed, path: target } unless validation == true
    end

    current_snapshot = regular_file_snapshot_once(write_path, "当前配置")
    current_bytes = current_snapshot.fetch(:bytes)
    return { status: :restore_conflict, path: target } unless Digest::SHA256.hexdigest(current_bytes).casecmp(expected_current_sha256).zero?
    if current_bytes == backup_bytes
      begin
        transaction = prepare_profile_transaction(
          [{ path: target, original: current_bytes, candidate: backup_bytes }],
          backup_root, roots: directories, runtime_checkpoint: runtime_checkpoint
        )
      rescue ConcurrentProfileChangeError
        return { status: :restore_conflict, path: target }
      end
      transaction_target = transaction.fetch(:targets).fetch(File.expand_path(target))
      result = {
        status: :no_change, path: target, rollback_bytes: current_bytes,
        patched_digest: Digest::SHA256.hexdigest(backup_bytes),
        patched_identity: transaction_target.fetch(:identity),
        patched_path: transaction_target.fetch(:write_path),
        restored_backup: public_id
      }
      result = activation.call(result) if activation
      return finish_backup_restore_transaction(
        transaction, result, precommit_condition: precommit_condition
      )
    end

    create_versioned_backup(target, backup_root, content: current_bytes, reason: "pre-restore")
    begin
      transaction = prepare_profile_transaction(
        [{ path: target, original: current_bytes, candidate: backup_bytes }],
        backup_root, roots: directories, runtime_checkpoint: runtime_checkpoint
      )
    rescue ConcurrentProfileChangeError
      return { status: :restore_conflict, path: target }
    end
    transaction_target = transaction.fetch(:targets).fetch(File.expand_path(target))
    replaced = transactional_compare_and_write_bytes(
      target, current_bytes, backup_bytes,
      expected_identity: current_snapshot.fetch(:identity), expected_path: write_path
    )
    unless replaced
      recover_profile_transaction(backup_root, roots: directories)
      return { status: :restore_conflict, path: target }
    end
    result = {
      status: :updated,
      path: target,
      rollback_bytes: current_bytes,
      patched_digest: Digest::SHA256.hexdigest(backup_bytes),
      patched_identity: transaction_target.fetch(:identity),
      patched_path: transaction_target.fetch(:write_path),
      restored_backup: public_id
    }
    result = activation.call(result) if activation
    finish_backup_restore_transaction(
      transaction, result, precommit_condition: precommit_condition
    )
  rescue Psych::Exception, InvalidConfigError, SystemStackError
    { status: :invalid_backup }
  rescue ProfileCommitStateUncertainError
    raise
  rescue SystemCallError, IOError
    { status: :io_error }
  ensure
    operation_lock&.close
  end

end
