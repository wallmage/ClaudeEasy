require "etc"
require "open3"
require "securerandom"

module ClaudeEasy
  class UnsafeLogPathError < StandardError; end
  class LogRepairError < StandardError; end

  module_function

  LOG_ACL_RIGHTS = %w[
    read write append execute delete delete_child readattr writeattr readextattr writeextattr
    readsecurity file_inherit directory_inherit
  ].join(",").freeze
  LOG_SESSION_PATTERN = /\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\z/.freeze

  def clashx_log_root
    File.expand_path("~/.config/clash.meta/logs")
  end

  def log_acl_present?(path, username:, runner: Open3.method(:capture3))
    output, _error, status = runner.call("/bin/ls", "-lde", path)
    status.success? && output.lines.any? do |line|
      line.include?("user:#{username} ") &&
        line.include?("file_inherit,directory_inherit")
    end
  end

  def add_log_acl(path, username:, runner: Open3.method(:capture3))
    _output, _error, status = runner.call(
      "/bin/chmod", "+a", "#{username} allow #{LOG_ACL_RIGHTS}", path
    )
    raise LogRepairError, "无法设置日志目录权限" unless status.success?
    raise LogRepairError, "日志目录权限回读失败" unless
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

  def create_log_tree(path, session_name:, username:, runner:)
    Dir.mkdir(path, 0o700)
    File.chmod(0o700, path)
    add_log_acl(path, username: username, runner: runner)
    if session_name
      session = File.join(path, session_name)
      Dir.mkdir(session, 0o700)
      File.chmod(0o700, session)
    end
    true
  end

  def repair_clashx_logs(log_root: clashx_log_root, runner: Open3.method(:capture3), now: Time.now)
    raise UnsafeLogPathError, "不能以 root 身份修复用户日志" if Process.uid.zero?

    config_root = validate_log_config_root(log_root)
    username = Etc.getpwuid(Process.uid).name
    raise UnsafeLogPathError, "当前用户名不适合 ACL" unless username.match?(/\A[A-Za-z0-9._-]+\z/)

    begin
      current = File.lstat(log_root)
      raise UnsafeLogPathError, "日志路径不是安全目录" unless current.directory? && !current.symlink?

      if File.writable?(log_root) && File.executable?(log_root)
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
    create_log_tree(staging, session_name: session_name, username: username, runner: runner)
    ClaudeEasyOperationLock.rename_exclusive(log_root, backup)
    begin
      ClaudeEasyOperationLock.rename_exclusive(staging, log_root)
    rescue StandardError
      ClaudeEasyOperationLock.rename_exclusive(backup, log_root) unless File.exist?(log_root)
      raise
    end
    raise LogRepairError, "日志目录仍不可写" unless
      File.writable?(log_root) && File.executable?(log_root) &&
      log_acl_present?(log_root, username: username, runner: runner)

    { status: :repaired, backup_preserved: true, session_recreated: !session_name.nil? }
  rescue UnsafeLogPathError, LogRepairError
    raise
  rescue SystemCallError, IOError => error
    raise LogRepairError, error.message
  end
end
