module ClaudeEasy
  module_function

  def excluded_path?(path)
    basename = File.basename(path)
    basename.start_with?(".") || basename.match?(/(?:^|[._-])(?:bak|backup|clash-patch|claude-easy)(?:[._-]|\z)/i) ||
      basename.match?(/(?:\.tmp|\.bak|\.backup)\z/i)
  end

  def profile_paths(directory)
    return [] unless Dir.exist?(directory)

    Dir.children(directory).sort.map do |basename|
      path = File.join(directory, basename)
      next if excluded_path?(path)
      next unless basename.match?(/\.ya?ml\z/i) && File.file?(path)

      path
    end.compact
  end

  def backup_key(path)
    Digest::SHA256.hexdigest(File.expand_path(path))[0, 16]
  end

  def secure_backup_root!(backup_root)
    root = File.expand_path(backup_root)
    raise InvalidConfigError, "备份目录不能是符号链接" if File.symlink?(root)
    raise InvalidConfigError, "备份位置不是目录" if File.exist?(root) && !File.directory?(root)

    FileUtils.mkdir_p(root, mode: 0o700)
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
    suffix = "--#{key}--#{File.basename(path)}.backup"
    reason_token = reason && "--#{reason}--#{key}--"
    Dir.children(root).select do |name|
      name.end_with?(suffix) && (!reason_token || name.include?(reason_token)) &&
        File.file?(File.join(root, name)) && !File.symlink?(File.join(root, name))
    end.sort.map { |name| File.join(root, name) }
  end

  def create_versioned_backup(path, backup_root, content: nil, reason: "prewrite")
    raise InvalidConfigError, "备份原因无效" unless reason.match?(/\A[a-z][a-z0-9-]{0,31}\z/)

    root = secure_backup_root!(backup_root)
    bytes = content.nil? ? File.binread(File.realpath(path)) : content.b
    key = backup_key(path)
    destination = nil
    100.times do
      timestamp = Time.now.strftime("%Y-%m-%d_%H-%M-%S.%9N%z")
      candidate = File.join(root, "#{timestamp}--#{reason}--#{key}--#{File.basename(path)}.backup")
      begin
        File.open(candidate, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |backup|
          backup.write(bytes)
          backup.flush
          backup.fsync
        end
        destination = candidate
        break
      rescue Errno::EEXIST
        Thread.pass
      end
    end
    raise IOError, "无法创建唯一的版本化备份" unless destination

    FileUtils.chmod(0o600, destination)
    destination
  rescue StandardError
    FileUtils.rm_f(destination) if destination && File.exist?(destination)
    raise
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

  def list_backups(backup_root)
    root = File.expand_path(backup_root)
    return [] unless File.directory?(root) && !File.symlink?(root)

    Dir.children(root).select do |name|
      path = File.join(root, name)
      name.match?(/\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.\d{9}[+-]\d{4}--[a-z][a-z0-9-]{0,31}--[0-9a-f]{16}--.+\.backup\z/) &&
        !name.include?("--preference--") &&
        File.file?(path) && !File.symlink?(path)
    end.sort.reverse
  end

  def resolve_backup_id(backup_id, backup_root)
    raise InvalidConfigError, "备份编号无效" unless backup_id == File.basename(backup_id.to_s) && backup_id.end_with?(".backup")

    root = File.expand_path(backup_root)
    path = File.join(root, backup_id)
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
    matches = directories.flat_map { |directory| profile_paths(directory) }.select do |path|
      backup_id.include?("--#{backup_key(path)}--") && backup_id.end_with?("--#{File.basename(path)}.backup")
    end
    raise InvalidConfigError, "备份无法对应到当前存储位置中的唯一配置" unless matches.length == 1

    matches.first
  end

  def redacted_changed_paths(before, after, prefix = nil, output = [], limit = 200)
    return output if output.length >= limit || before == after

    if before.is_a?(Hash) && after.is_a?(Hash)
      (before.keys | after.keys).map(&:to_s).sort.each do |key|
        break if output.length >= limit
        path = prefix ? "#{prefix}.#{key}" : key
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
    target = find_backup_target(backup_id, directories)
    backup_bytes = read_regular_file_once(backup_path, "备份")
    current_bytes = File.binread(File.realpath(target))
    backup_config = load_yaml(backup_bytes.dup.force_encoding(Encoding::UTF_8), backup_id)
    current_config = load_yaml(current_bytes.dup.force_encoding(Encoding::UTF_8), target)
    {
      backup_id: backup_id,
      profile: File.basename(target),
      same: backup_bytes == current_bytes,
      backup_sha256: Digest::SHA256.hexdigest(backup_bytes),
      current_sha256: Digest::SHA256.hexdigest(current_bytes),
      changes: redacted_changed_paths(backup_config, current_config)
    }
  end

  def finish_backup_restore_transaction(transaction, result)
    if %i[updated no_change reload_failed_rolled_back].include?(result.fetch(:status))
      remove_profile_transaction(transaction)
    end
    result
  end

  def restore_backup(backup_id, directories:, backup_root:, expected_current_sha256:, validator:,
                     selected_name: nil, activation: nil, precommit_condition: nil)
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
    target = find_backup_target(backup_id, directories)
    write_path = File.realpath(target)
    backup_bytes = read_regular_file_once(backup_path, "备份")
    backup_text = backup_bytes.dup.force_encoding(Encoding::UTF_8)
    raise InvalidConfigError, "备份不是有效的 UTF-8" unless backup_text.valid_encoding?

    load_yaml(backup_text, backup_id)
    Tempfile.create([File.basename(write_path), ".restore"], File.dirname(write_path)) do |temporary|
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
      transaction = prepare_profile_transaction(
        [{ path: target, original: current_bytes, candidate: backup_bytes }], backup_root
      )
      result = {
        status: :no_change, path: target, rollback_bytes: current_bytes,
        patched_digest: Digest::SHA256.hexdigest(backup_bytes), restored_backup: backup_id
      }
      result = activation.call(result) if activation
      return finish_backup_restore_transaction(transaction, result)
    end

    create_versioned_backup(target, backup_root, content: current_bytes, reason: "pre-restore")
    transaction = prepare_profile_transaction(
      [{ path: target, original: current_bytes, candidate: backup_bytes }], backup_root
    )
    replaced = atomic_compare_and_swap_bytes(
      target, current_bytes, backup_bytes,
      expected_identity: current_snapshot.fetch(:identity), expected_path: write_path
    )
    unless replaced
      remove_profile_transaction(transaction)
      return { status: :restore_conflict, path: target }
    end
    result = {
      status: :updated,
      path: target,
      rollback_bytes: current_bytes,
      patched_digest: Digest::SHA256.hexdigest(backup_bytes),
      restored_backup: backup_id
    }
    result = activation.call(result) if activation
    finish_backup_restore_transaction(transaction, result)
  rescue Psych::Exception, InvalidConfigError, SystemStackError
    { status: :invalid_backup }
  rescue SystemCallError, IOError
    { status: :io_error }
  ensure
    operation_lock&.close
  end

end
