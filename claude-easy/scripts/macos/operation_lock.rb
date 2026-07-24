#!/usr/bin/ruby

require "fileutils"

module ClaudeEasyOperationLock
  module_function

  LOCK_TIMEOUT_SECONDS = 5
  BUSY_EXIT = 75
  FAILED_EXIT = 76
  HELD_ENV = "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD".freeze

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def acquire(path, timeout_seconds: LOCK_TIMEOUT_SECONDS)
    directory = File.dirname(path)
    state_root = File.dirname(directory)
    raise IOError, "operation lock state root is unsafe" if File.symlink?(state_root) ||
                                                             (File.exist?(state_root) && !File.directory?(state_root))

    FileUtils.mkdir_p(directory, mode: 0o700)
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
    raise ArgumentError, "operation lock requires a path and command" if arguments.length < 2

    lock_path = File.expand_path(arguments.fetch(0))
    command = arguments.drop(1)
    handle = acquire(lock_path)
    return BUSY_EXIT unless handle

    handle.close_on_exec = false
    ENV[HELD_ENV] = "1"
    execute(command)
    0
  rescue StandardError
    FAILED_EXIT
  ensure
    handle&.close
  end
end

exit ClaudeEasyOperationLock.run(ARGV) if $PROGRAM_NAME == __FILE__
