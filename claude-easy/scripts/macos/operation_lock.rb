#!/usr/bin/ruby

require "fileutils"
require "fiddle/import"

module ClaudeEasyExclusiveRename
  extend Fiddle::Importer

  RENAME_EXCL = 0x00000004

  dlload "/usr/lib/libSystem.B.dylib"
  extern "int renamex_np(const char *, const char *, unsigned int)"

  def self.call(source, destination)
    return true if renamex_np(source, destination, RENAME_EXCL).zero?

    raise SystemCallError.new("exclusive rename failed", Fiddle.last_error)
  end
end

module ClaudeEasyOperationLock
  module_function

  LOCK_TIMEOUT_SECONDS = 5
  BUSY_EXIT = 75
  FAILED_EXIT = 76
  HELD_ENV = "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD".freeze
  HELD_FD_ENV = "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_FD".freeze
  HELD_IDENTITY_ENV = "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_IDENTITY".freeze
  ENSURE_DIRECTORY_COMMAND = "--ensure-private-directory".freeze
  SYNC_DIRECTORY_COMMAND = "--sync-directory".freeze
  SYNC_FILE_COMMAND = "--sync-file".freeze
  VERIFY_HELD_COMMAND = "--verify-held-lock".freeze
  RENAME_EXCLUSIVE_COMMAND = "--rename-exclusive".freeze

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def fsync_directory(path)
    expanded = File.expand_path(path)
    flags = File::RDONLY
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    File.open(expanded, flags) do |handle|
      opened = handle.stat
      current = File.lstat(expanded)
      raise IOError, "operation lock directory changed during publication" unless
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
        raise IOError, "operation lock directory is unsafe" unless
          current.directory? && !current.symlink?
        break
      rescue Errno::ENOENT
        missing << cursor
        parent = File.dirname(cursor)
        raise IOError, "operation lock directory is unsafe" if parent == cursor

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
        raise IOError, "operation lock directory is unsafe" unless
          current.directory? && !current.symlink?
      end
      FileUtils.chmod(0o700, directory)
      fsync_directory(directory)
      fsync_directory(File.dirname(directory))
    end
    target
  end

  def sync_regular_file(path)
    expanded = File.expand_path(path)
    flags = File::RDWR
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    File.open(expanded, flags) do |handle|
      opened = handle.stat
      current = File.lstat(expanded)
      raise IOError, "state file changed during synchronization" unless
        opened.file? && current.file? && !current.symlink? && current.nlink == 1 &&
        [opened.dev, opened.ino] == [current.dev, current.ino]

      handle.fsync
      verified = File.lstat(expanded)
      raise IOError, "state file changed during synchronization" unless
        verified.file? && !verified.symlink? &&
        [opened.dev, opened.ino] == [verified.dev, verified.ino]
    end
    fsync_directory(File.dirname(expanded))
    true
  end

  def inherited_lock_held?(path)
    return false unless ENV[HELD_ENV] == "1"

    descriptor = Integer(ENV.fetch(HELD_FD_ENV), 10)
    expected_identity = ENV.fetch(HELD_IDENTITY_ENV)
    expanded = File.expand_path(path)
    inherited = IO.for_fd(descriptor, autoclose: false)
    inherited_stat = inherited.stat
    path_stat = File.lstat(expanded)
    identity = "#{inherited_stat.dev}:#{inherited_stat.ino}"
    return false unless inherited_stat.file? && inherited_stat.nlink == 1 &&
                        path_stat.file? && !path_stat.symlink? &&
                        [path_stat.dev, path_stat.ino] == [inherited_stat.dev, inherited_stat.ino] &&
                        identity == expected_identity

    flags = File::RDWR
    flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
    File.open(expanded, flags) do |contender|
      available = contender.flock(File::LOCK_EX | File::LOCK_NB)
      contender.flock(File::LOCK_UN) if available
      !available
    end
  rescue ArgumentError, KeyError, SystemCallError, IOError
    false
  end

  def rename_exclusive(source, destination)
    expanded_source = File.expand_path(source)
    expanded_destination = File.expand_path(destination)
    source_parent = File.dirname(expanded_source)
    destination_parent = File.dirname(expanded_destination)
    source_parent_stat = File.lstat(source_parent)
    destination_parent_stat = File.lstat(destination_parent)
    raise IOError, "rename parent is unsafe" unless
      source_parent_stat.directory? && !source_parent_stat.symlink? &&
      destination_parent_stat.directory? && !destination_parent_stat.symlink?

    source_stat = File.lstat(expanded_source)
    begin
      File.lstat(expanded_destination)
      raise IOError, "rename destination already exists"
    rescue Errno::ENOENT
      nil
    end
    begin
      ClaudeEasyExclusiveRename.call(expanded_source, expanded_destination)
    rescue Errno::EACCES, Errno::EINVAL, Errno::ENOTSUP
      # Some macOS volumes reject RENAME_EXCL for directories even though an
      # ordinary atomic directory rename is supported. Reserve the destination
      # first so another normal writer cannot appear in the fallback window.
      # Files still fail closed because they cannot use this directory guard.
      raise unless source_stat.directory?

      placeholder_stat = nil
      begin
        begin
          Dir.mkdir(expanded_destination, 0o700)
        rescue Errno::EEXIST
          raise IOError, "rename destination already exists"
        end
        placeholder_stat = File.lstat(expanded_destination)
        raise IOError, "rename destination reservation is unsafe" unless
          placeholder_stat.directory? && !placeholder_stat.symlink?
        File.rename(expanded_source, expanded_destination)
      rescue StandardError
        if placeholder_stat
          begin
            current = File.lstat(expanded_destination)
            Dir.rmdir(expanded_destination) if
              current.directory? && !current.symlink? &&
              [current.dev, current.ino] == [placeholder_stat.dev, placeholder_stat.ino]
          rescue Errno::ENOENT, Errno::ENOTEMPTY
            nil
          end
        end
        raise
      end
    end
    destination_stat = File.lstat(expanded_destination)
    raise IOError, "renamed path identity changed" unless
      [source_stat.dev, source_stat.ino] == [destination_stat.dev, destination_stat.ino]

    fsync_directory(source_parent)
    fsync_directory(destination_parent) unless destination_parent == source_parent
    true
  end

  def acquire(path, timeout_seconds: LOCK_TIMEOUT_SECONDS)
    directory = File.dirname(path)
    state_root = File.dirname(directory)
    raise IOError, "operation lock state root is unsafe" if File.symlink?(state_root) ||
                                                             (File.exist?(state_root) && !File.directory?(state_root))

    ensure_durable_private_directory(directory)
    raise IOError, "operation lock directory is unsafe" if File.symlink?(directory)
    raise IOError, "operation lock path is unsafe" if File.symlink?(path) ||
                                                      (File.exist?(path) && !File.file?(path))

    FileUtils.chmod(0o700, directory)
    handle = File.open(path, File::RDWR | File::CREAT, 0o600)
    deadline = monotonic_now + timeout_seconds
    until handle.flock(File::LOCK_EX | File::LOCK_NB)
      if monotonic_now >= deadline
        handle.close
        return nil
      end
      sleep 0.05
    end
    FileUtils.chmod(0o600, path)
    handle
  rescue StandardError
    handle&.close
    raise
  end

  def execute(command)
    exec(*command)
  end

  def run(arguments)
    if arguments.length == 3 && arguments.fetch(0) == RENAME_EXCLUSIVE_COMMAND
      rename_exclusive(arguments.fetch(1), arguments.fetch(2))
      return 0
    end
    if arguments.length == 2
      case arguments.fetch(0)
      when ENSURE_DIRECTORY_COMMAND
        ensure_durable_private_directory(arguments.fetch(1))
        return 0
      when SYNC_DIRECTORY_COMMAND
        fsync_directory(arguments.fetch(1))
        return 0
      when SYNC_FILE_COMMAND
        sync_regular_file(arguments.fetch(1))
        return 0
      when VERIFY_HELD_COMMAND
        return inherited_lock_held?(arguments.fetch(1)) ? 0 : FAILED_EXIT
      end
      raise ArgumentError, "unknown durable-state command" if arguments.fetch(0).start_with?("--")
    end
    raise ArgumentError, "operation lock requires a path and command" if arguments.length < 2

    lock_path = File.expand_path(arguments.fetch(0))
    command = arguments.drop(1)
    handle = acquire(lock_path)
    return BUSY_EXIT unless handle

    handle.close_on_exec = false
    ENV[HELD_ENV] = "1"
    ENV[HELD_FD_ENV] = handle.fileno.to_s
    stat = handle.stat
    ENV[HELD_IDENTITY_ENV] = "#{stat.dev}:#{stat.ino}"
    execute(command)
    0
  rescue StandardError
    FAILED_EXIT
  ensure
    handle&.close
  end
end

exit ClaudeEasyOperationLock.run(ARGV) if $PROGRAM_NAME == __FILE__
