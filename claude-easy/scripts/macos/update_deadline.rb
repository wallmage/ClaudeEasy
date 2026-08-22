#!/usr/bin/ruby

require "tempfile"

TIMEOUT_EXIT = 124
POLL_SECONDS = 0.05
TERM_GRACE_SECONDS = 0.5

seconds = Integer(ARGV.shift, 10)
abort "invalid update deadline" unless seconds.positive?
abort "missing update command" if ARGV.empty?

output = Tempfile.new("claude-easy-update")
output.chmod(0o600)
error = Tempfile.new("claude-easy-update-error")
error.chmod(0o600)
pid = Process.spawn(*ARGV, pgroup: true, out: output, err: error)
forwarded_signal = nil
%w[HUP INT TERM].each do |name|
  Signal.trap(name) do
    forwarded_signal ||= Signal.list.fetch(name)
    begin
      Process.kill(name, -pid)
    rescue Errno::ESRCH
      nil
    end
  end
end

deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
status = nil
loop do
  waited = Process.waitpid2(pid, Process::WNOHANG)
  if waited
    status = waited.last
    break
  end
  break if forwarded_signal || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

  sleep POLL_SECONDS
end

if status.nil?
  timed_out = forwarded_signal.nil?
  begin
    Process.kill("TERM", -pid) if timed_out
  rescue Errno::ESRCH
    nil
  end
  grace_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TERM_GRACE_SECONDS
  loop do
    waited = Process.waitpid2(pid, Process::WNOHANG)
    if waited
      status = waited.last
      break
    end
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= grace_deadline

    sleep POLL_SECONDS
  end
  unless status
    begin
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end
    _, status = Process.waitpid2(pid)
  end
  exit(timed_out ? TIMEOUT_EXIT : 128 + forwarded_signal)
end

output.rewind
IO.copy_stream(output, STDOUT)
error.rewind
IO.copy_stream(error, STDERR)
exit(status.exitstatus || 128 + status.termsig)
