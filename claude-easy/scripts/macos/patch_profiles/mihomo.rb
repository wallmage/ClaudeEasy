module ClaudeEasy
  module_function

  def mihomo_version(text)
    match = text.to_s.match(/\bv?(\d+)\.(\d+)\.(\d+)\b/i)
    match && match.captures.map(&:to_i)
  end

  def mihomo_version_supported?(text)
    version = mihomo_version(text)
    version && (version <=> MIN_MIHOMO_VERSION) >= 0
  end

  def terminate_process_group(pid)
    Process.kill("TERM", -pid)
    sleep 0.05
    Process.kill("KILL", -pid)
  rescue Errno::ESRCH, Errno::EPERM
    begin
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  ensure
    begin
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def watch_process_owner(reader, pid, output)
    completed = reader.read(1) == "D"
    unless completed
      begin
        Process.kill("TERM", -pid)
        sleep 0.05
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        Process.kill("KILL", pid) rescue nil
      end
      output.close!
    else
      output.close
    end
  ensure
    reader.close rescue nil
  end

  def finish_process_watchdog(writer, watchdog_pid, output)
    begin
      writer&.write("D")
    rescue Errno::EPIPE, IOError
      nil
    end
    writer&.close
    begin
      Process.waitpid(watchdog_pid) if watchdog_pid
    rescue Errno::ECHILD
      nil
    end
    output.close! if output
  end

  def run_process_with_timeout(command, *arguments, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)
    output = Tempfile.new("claude-easy-command")
    pid = Process.spawn(command, *arguments, out: output, err: output, pgroup: true)
    watchdog_reader, watchdog_writer = IO.pipe
    watchdog_pid = fork { watchdog_writer.close; watch_process_owner(watchdog_reader, pid, output); exit! 0 }
    watchdog_reader.close
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds

    loop do
      waited = Process.waitpid2(pid, Process::WNOHANG)
      if waited
        output.flush
        output.rewind
        return [output.read, waited[1], false]
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        terminate_process_group(pid)
        output.flush
        output.rewind
        return [output.read, nil, true]
      end
      sleep 0.05
    end
  ensure
    finish_process_watchdog(watchdog_writer, watchdog_pid, output)
  end

  def mihomo_core_status(core_path = AUTO_CORE, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)
    core = core_path.equal?(AUTO_CORE) ? mihomo_core_path : core_path
    return :missing unless core && File.file?(core) && File.executable?(core)

    output, status, timed_out = run_process_with_timeout(core, "-v", timeout_seconds: timeout_seconds)
    return :timeout if timed_out
    return :unreadable unless status.success?

    mihomo_version_supported?(output) ? :supported : :too_old
  rescue SystemCallError, IOError
    :unreadable
  end

  def validate_with_mihomo(path, core_path: AUTO_CORE, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)
    core = core_path.equal?(AUTO_CORE) ? mihomo_core_path : core_path
    core_status = mihomo_core_status(core, timeout_seconds: timeout_seconds)
    return :timeout if core_status == :timeout
    return false unless core_status == :supported

    _output, status, timed_out = run_process_with_timeout(
      core, "-d", mihomo_validation_directory(path), "-t", "-f", path,
      timeout_seconds: timeout_seconds
    )
    return :timeout if timed_out

    status.success?
  end

  def mihomo_validation_directory(path)
    File.dirname(File.expand_path(path))
  end

  def mihomo_core_path
    mihomo_core_paths.find { |path| File.file?(path) && File.executable?(path) }
  end

  def mihomo_core_paths
    [
      File.expand_path("~/Library/Application Support/com.metacubex.ClashX.meta/.private_core/com.metacubex.ClashX.ProxyConfigHelper.meta"),
      "/Applications/ClashX Meta.app/Contents/Resources/com.metacubex.ClashX.ProxyConfigHelper.meta",
      File.expand_path("~/Applications/ClashX Meta.app/Contents/Resources/com.metacubex.ClashX.ProxyConfigHelper.meta")
    ]
  end

end
