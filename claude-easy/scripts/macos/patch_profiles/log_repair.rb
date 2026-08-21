require "etc"
require "open3"
require "securerandom"

module ClaudeEasy
  class UnsafeLogPathError < StandardError; end
  class LogRepairError < StandardError; end
  class LogRepairPartialError < LogRepairError; end

  module_function

  LOG_ACL_RIGHTS = %w[
    read write append execute delete delete_child readattr writeattr readextattr writeextattr
    readsecurity file_inherit directory_inherit
  ].join(",").freeze
  LOG_ACL_DIRECTORY_RIGHT_GROUPS = [
    %w[read list], %w[write add_file], %w[append add_subdirectory], %w[execute search],
    %w[delete], %w[delete_child], %w[readattr], %w[writeattr], %w[readextattr],
    %w[writeextattr], %w[readsecurity], %w[file_inherit], %w[directory_inherit]
  ].freeze
  LOG_SESSION_PATTERN = /\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\z/.freeze

  def clashx_log_root
    File.expand_path("~/.config/clash.meta/logs")
  end

  def log_acl_present?(path, username:, runner: Open3.method(:capture3))
    output, _error, status = runner.call("/bin/ls", "-lde", path)
    return false unless status.success?

    identifiers = [username.downcase]
    uuid, _uuid_error, uuid_status = runner.call("/usr/bin/dsmemberutil", "getuuid", "-U", username)
    identifiers << uuid.to_s.strip.downcase if uuid_status.success? && !uuid.to_s.strip.empty?
    entries = output.lines.each_with_object([]) do |line, found|
      match = line.chomp.match(/\A\s*\d+:\s+(?:user:)?(\S+)\s+(allow|deny)\s+(.+)\z/i)
      next unless match && identifiers.include?(match[1].downcase)

      found << [match[2].downcase, match[3].split(",").map { |right| right.strip.downcase }]
    end
    return false if entries.any? do |kind, rights|
      kind == "deny" && LOG_ACL_DIRECTORY_RIGHT_GROUPS.any? { |aliases| !(aliases & rights).empty? }
    end

    entries.any? do |kind, rights|
      kind == "allow" && LOG_ACL_DIRECTORY_RIGHT_GROUPS.all? { |aliases| !(aliases & rights).empty? }
    end
  end

  def add_log_acl(path, username:, runner: Open3.method(:capture3))
    _output, _error, status = runner.call(
      "/bin/chmod", "+a", "#{username} allow #{LOG_ACL_RIGHTS}", path
    )
    raise LogRepairError, "无法设置日志目录权限" unless status.success?
    raise LogRepairPartialError, "日志目录权限回读失败" unless
      log_acl_present?(path, username: username, runner: runner)

    true
  end

  def validate_log_config_root(log_root)
    config_root = File.dirname(log_root)
    stat = File.lstat(config_root)
    raise UnsafeLogPathError, "ClashX Meta 配置目录不安全" unless
      stat.directory? && !stat.symlink? && stat.uid == Process.uid &&
      File.writable?(config_root) && File.executable?(config_root)

    config_root
  rescue Errno::ENOENT
    raise UnsafeLogPathError, "找不到 ClashX Meta 配置目录"
  end

  def log_session_names(log_root)
    Dir.children(log_root).select { |name| name.match?(LOG_SESSION_PATTERN) }.sort
  rescue SystemCallError
    []
  end

  def current_log_session_writable?(log_root)
    session_name = log_session_names(log_root).last
    return true unless session_name

    pending = [File.join(log_root, session_name)]
    until pending.empty?
      path = pending.pop
      stat = File.lstat(path)
      return false if stat.symlink?
      if stat.directory?
        return false unless File.writable?(path) && File.executable?(path)

        pending.concat(Dir.children(path).map { |name| File.join(path, name) })
      elsif stat.file?
        return false unless File.writable?(path)
      else
        return false
      end
    end
    true
  rescue SystemCallError
    false
  end

  def clashx_log_snapshots(log_root)
    session_name = log_session_names(log_root).last
    return {} unless session_name

    session = File.join(log_root, session_name)
    Dir.children(session).each_with_object({}) do |name, snapshots|
      next unless name.match?(/\Aclashx_.*\.log\z/)

      path = File.join(session, name)
      stat = File.lstat(path)
      next unless stat.file? && !stat.symlink?

      snapshots[path] = [stat.dev, stat.ino, stat.size]
    end
  rescue SystemCallError
    {}
  end

  def verify_clashx_file_logging(log_root: clashx_log_root, requester: nil, proxy_probe: nil,
                                 runner: Open3.method(:capture3), now: -> { Time.now },
                                 sleeper: Kernel.method(:sleep))
    before = clashx_log_snapshots(log_root)
    if proxy_probe.nil?
      if requester.nil?
        socket = controller_socket
        return false unless socket

        requester = ->(method, endpoint, body) { controller_request(socket, method, endpoint, body) }
      end
      proxy_probe = -> { harmless_proxy_request_healthy?(requester) }
    end
    started_at = now.call
    return false unless proxy_probe.call

    grew = false
    10.times do
      after = clashx_log_snapshots(log_root)
      grew = after.any? do |path, identity_and_size|
        previous = before[path]
        previous.nil? ? identity_and_size.fetch(2).positive? :
          identity_and_size.fetch(2) > previous.fetch(2)
      end
      break if grew

      sleeper.call(0.2)
    end
    return false unless grew

    output, _error, status = runner.call(
      "/usr/bin/log", "show", "--start", started_at.utc.iso8601(6),
      "--style", "compact", "--info", "--debug", "--predicate", 'process == "ClashX Meta"'
    )
    return false unless status.success?

    !output.match?(/DDFileLogManagerDefault.*(?:Cocoa\D+(?:257|513)|POSIX\D+13)/im)
  rescue StandardError
    false
  end

  def create_log_tree(path, session_name:, username:, runner:)
    created = []
    Dir.mkdir(path, 0o700)
    stat = File.lstat(path)
    created << [path, [stat.dev, stat.ino]]
    File.chmod(0o700, path)
    add_log_acl(path, username: username, runner: runner)
    if session_name
      session = File.join(path, session_name)
      Dir.mkdir(session, 0o700)
      stat = File.lstat(session)
      created << [session, [stat.dev, stat.ino]]
      File.chmod(0o700, session)
    end
    created
  rescue StandardError => error
    rolled_back = remove_created_log_tree(created)
    if rolled_back
      raise
    end
    raise LogRepairPartialError, "日志目录修复只完成了一部分"
  end

  def remove_created_log_tree(created)
    created.reverse_each.all? do |entry, identity|
      stat = File.lstat(entry)
      next false unless stat.directory? && !stat.symlink? && [stat.dev, stat.ino] == identity

      Dir.rmdir(entry)
      true
    rescue SystemCallError
      false
    end
  end

  def chmod_log_directory(path, mode, identity)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    File.open(path, flags) do |handle|
      stat = handle.stat
      raise UnsafeLogPathError, "日志目录在修复期间被替换" unless
        stat.directory? && [stat.dev, stat.ino] == identity

      handle.chmod(mode)
    end
  end

  def repair_clashx_logs(log_root: clashx_log_root, runner: Open3.method(:capture3), now: Time.now)
    raise UnsafeLogPathError, "不能以 root 身份修复用户日志" if Process.uid.zero?

    config_root = validate_log_config_root(log_root)
    username = Etc.getpwuid(Process.uid).name
    raise UnsafeLogPathError, "当前用户名不适合 ACL" unless username.match?(/\A[A-Za-z0-9._-]+\z/)

    begin
      current = File.lstat(log_root)
      raise UnsafeLogPathError, "日志路径不是安全目录" unless current.directory? && !current.symlink?

      if File.writable?(log_root) && File.executable?(log_root) &&
         current_log_session_writable?(log_root)
        return { status: :already_writable, backup_preserved: false } if
          log_acl_present?(log_root, username: username, runner: runner)

        add_log_acl(log_root, username: username, runner: runner)
        return { status: :repaired, backup_preserved: false }
      end
    rescue Errno::ENOENT
      create_log_tree(log_root, session_name: nil, username: username, runner: runner)
      return { status: :repaired, backup_preserved: false }
    end

    session_name = log_session_names(log_root).last
    nonce = SecureRandom.hex(4)
    timestamp = now.strftime("%Y%m%d-%H%M%S")
    staging = File.join(config_root, ".logs.permission-repair-#{timestamp}-#{nonce}")
    backup = File.join(config_root, "logs.permission-backup-#{timestamp}-#{nonce}")
    staging_entries = create_log_tree(
      staging, session_name: session_name, username: username, runner: runner
    )
    original_mode = current.mode & 0o7777
    original_identity = [current.dev, current.ino]
    relaxed_owner_mode = current.uid == Process.uid && (original_mode & 0o300) != 0o300
    owner_mode_changed = false
    tree_changed = false
    published = false
    if relaxed_owner_mode
      chmod_log_directory(log_root, original_mode | 0o700, original_identity)
      owner_mode_changed = true
    end
    begin
      ClaudeEasyOperationLock.rename_exclusive(log_root, backup)
      tree_changed = true
      ClaudeEasyOperationLock.rename_exclusive(staging, log_root)
      published = true
    rescue StandardError
      restored_path = tree_changed ? backup : log_root
      begin
        if tree_changed && !File.exist?(log_root)
          ClaudeEasyOperationLock.rename_exclusive(backup, log_root)
          restored_path = log_root
        end
      ensure
        chmod_log_directory(restored_path, original_mode, original_identity) if
          owner_mode_changed && File.exist?(restored_path)
        owner_mode_changed = false
        tree_changed = false if restored_path == log_root
      end
      raise
    end
    chmod_log_directory(backup, original_mode, original_identity) if relaxed_owner_mode
    owner_mode_changed = false
    raise LogRepairPartialError, "日志目录仍不可写" unless
      File.writable?(log_root) && File.executable?(log_root) &&
      log_acl_present?(log_root, username: username, runner: runner)

    { status: :repaired, backup_preserved: true, session_recreated: !session_name.nil? }
  rescue StandardError => error
    staging_clean = !defined?(staging_entries) || staging_entries.nil? ||
                    !File.exist?(staging) || remove_created_log_tree(staging_entries)
    raise LogRepairPartialError, "日志目录修复只完成了一部分" if
      !staging_clean || published || tree_changed || owner_mode_changed

    raise error if error.is_a?(UnsafeLogPathError) || error.is_a?(LogRepairError)
    raise LogRepairError, error.message if error.is_a?(SystemCallError) || error.is_a?(IOError)

    raise
  end
end
