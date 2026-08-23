require "json"
require "digest"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "socket"
require "stringio"
require "tmpdir"
require "yaml"

ROOT = File.expand_path("..", __dir__)
PATCHER_PATH = File.join(ROOT, "claude-easy/scripts/macos/patch_profiles.rb")
ROUTE_VERIFIER_PATH = File.join(ROOT, "claude-easy/scripts/macos/verify_routes.rb")
RESULT_CONTRACT_PATH = File.join(ROOT, "claude-easy/scripts/macos/result_contract.rb")
OPERATION_LOCK_PATH = File.join(ROOT, "claude-easy/scripts/macos/operation_lock.rb")
USAGE_PROFILE_STATE_PATH = File.join(
  ROOT, "claude-easy/scripts/macos/usage_profile_state.rb"
)
SAFE_UPDATE_RUNTIME_CRASH_PROBE_PATH = File.join(
  ROOT, "tests/fixtures/macos_safe_update_runtime_crash_probe.rb"
)
POLICY_PATH = File.join(ROOT, "claude-easy/references/policy.json")
MAIN_GROUP_FIXTURES = File.join(ROOT, "tests/fixtures/main_group_cases.json")
PATCHER_AVAILABLE = File.file?(PATCHER_PATH) && File.file?(POLICY_PATH)
CHILD_COVERAGE_DIRECTORY_ENV = "CLAUDE_EASY_CHILD_COVERAGE_DIRECTORY"
CHILD_COVERAGE_RUNNER = <<~'RUBY'
  require "coverage"
  require "digest"

  entrypoint = ARGV.shift
  output_path = ENV.fetch("CLAUDE_EASY_CHILD_COVERAGE_OUTPUT")
  Coverage.start(lines: true, branches: true)
  at_exit do
    coverage = Coverage.result
    digests = coverage.each_key.to_h do |path|
      [path, File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil]
    end
    File.binwrite(output_path, Marshal.dump({ coverage: coverage, digests: digests }))
  end
  $PROGRAM_NAME = entrypoint
  load entrypoint
RUBY

require PATCHER_PATH if PATCHER_AVAILABLE
require ROUTE_VERIFIER_PATH if File.file?(ROUTE_VERIFIER_PATH)
require OPERATION_LOCK_PATH if File.file?(OPERATION_LOCK_PATH)

class MacosPatcherTest < Minitest::Test
  def setup
    skip "patcher not implemented" unless PATCHER_AVAILABLE
    @policy = JSON.parse(File.read(POLICY_PATH)) if PATCHER_AVAILABLE
  end

  def require_production_probe!
    skip "set CLAUDE_EASY_RUN_PRODUCTION_PROBES=1 to run known production-failure probes" unless
      ENV["CLAUDE_EASY_RUN_PRODUCTION_PROBES"] == "1"
  end

  def clashx_native_fetch_integration_script
    script = ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT.dup
    identity_start = script.index("var primaryApplications =")
    request_start = script.index("var url =", identity_start)
    raise "ClashX identity block not found" unless identity_start && request_start

    script[identity_start...request_start] = 'var userAgent = "ClashX Meta/integration-test";' + "\n"
    script.gsub!('urlText.match(/^https:\\/\\//)', 'urlText.match(/^http:\\/\\//)')
    script.gsub!('unwrap(nextURL.scheme).toLowerCase() !== "https"',
                 'unwrap(nextURL.scheme).toLowerCase() !== "http"')
    script.gsub!('unwrap(finalURL.scheme).toLowerCase() !== "https"',
                 'unwrap(finalURL.scheme).toLowerCase() !== "http"')
    script
  end

  def run_clashx_native_fetch_integration(max_bytes: 1024, &server_behavior)
    listener = TCPServer.new("127.0.0.1", 0)
    server = Thread.new do
      Thread.current.report_on_exception = false
      server_behavior.call(listener)
    rescue IOError
      nil
    end
    Open3.capture3(
      "/usr/bin/osascript", "-l", "JavaScript", "-e", clashx_native_fetch_integration_script,
      stdin_data: "2\n#{max_bytes}\nhttp://127.0.0.1:#{listener.addr[1]}/subscription\n",
      binmode: true
    )
  ensure
    listener&.close
    server&.join(1)
    server&.kill if server&.alive?
  end

  def write_http_fixture_response(listener, status:, headers: {}, body: "", include_content_length: true)
    client = listener.accept
    request = +""
    request << client.readpartial(1024) until request.include?("\r\n\r\n")
    fields = { "Connection" => "close" }.merge(headers)
    fields["Content-Length"] = body.bytesize if include_content_length
    client.write(
      "HTTP/1.1 #{status}\r\n#{fields.map { |key, value| "#{key}: #{value}\r\n" }.join}\r\n#{body}"
    )
    client.close
  end

  def test_every_macos_usage_profile_persists_proxy_selections_across_reloads
    [1, 2, 3].each do |usage_profile|
      missing = base_config
      disabled = base_config.merge(
        "profile" => { "store-selected" => false, "sibling" => "preserved" }
      )
      invalid = base_config.merge("profile" => [])

      patched_missing = ClaudeEasy.patch(
        missing, @policy, usage_profile: usage_profile
      ).fetch(:config)
      patched_disabled = ClaudeEasy.patch(
        disabled, @policy, usage_profile: usage_profile
      ).fetch(:config)
      patched_invalid = ClaudeEasy.patch(
        invalid, @policy, usage_profile: usage_profile
      ).fetch(:config)

      assert_equal true, patched_missing.dig("profile", "store-selected")
      assert_equal true, patched_disabled.dig("profile", "store-selected")
      assert_equal "preserved", patched_disabled.dig("profile", "sibling")
      assert_equal({ "store-selected" => true }, patched_invalid.fetch("profile"))
    end
  end

  def route_controller_getter(proxies, main_group: "Main", providers: { "providers" => {} })
    lambda do |_socket, endpoint|
      case endpoint
      when "/proxies" then proxies
      when "/rules"
        { "rules" => [{ "type" => "MATCH", "proxy" => main_group }] }
      when "/providers/proxies" then providers
      end
    end
  end

  def with_internal_wrapper_operation(backup_root)
    keys = %w[
      CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD
      CLAUDE_EASY_INTERNAL_OPERATION_LOCK_FD
      CLAUDE_EASY_INTERNAL_OPERATION_LOCK_IDENTITY
    ]
    previous = keys.to_h { |key| [key, ENV[key]] }
    lock_path = File.join(backup_root, ".claude-easy-wrapper.lock")
    handle = ClaudeEasyOperationLock.acquire(lock_path)
    handle.close_on_exec = false
    stat = handle.stat
    ENV[keys.fetch(0)] = "1"
    ENV[keys.fetch(1)] = handle.fileno.to_s
    ENV[keys.fetch(2)] = "#{stat.dev}:#{stat.ino}"
    state_path = File.join(File.dirname(backup_root), "usage-profile.plist")
    ClaudeEasy.stub(:usage_profile_state_path, state_path) { yield }
  ensure
    handle&.close
    previous&.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  def fixture_process?(process_id, marker)
    return false unless process_id

    output, status = Open3.capture2(
      "/bin/ps", "-p", process_id.to_s, "-o", "command="
    )
    status.success? && output.include?(marker)
  rescue SystemCallError
    false
  end

  def capture_ruby_entrypoint(path, *arguments, environment: {}, spawn_options: {})
    coverage_directory = ENV[CHILD_COVERAGE_DIRECTORY_ENV]
    return Open3.capture3(
      environment, RbConfig.ruby, path, *arguments, **spawn_options
    ) unless coverage_directory

    coverage_output = File.join(
      coverage_directory,
      "#{Process.pid}-#{Thread.current.object_id}-#{rand(1 << 62)}.marshal"
    )
    child_environment = environment.merge(
      "CLAUDE_EASY_CHILD_COVERAGE_OUTPUT" => coverage_output
    )
    Open3.capture3(
      child_environment, RbConfig.ruby, "-e", CHILD_COVERAGE_RUNNER, path, *arguments,
      **spawn_options
    )
  end

  def run_log_repair_command(home, json: true)
    arguments = ["--repair-clashx-logs"]
    arguments << "--json" if json
    capture_ruby_entrypoint(PATCHER_PATH, *arguments, environment: { "HOME" => home })
  end

  def run_log_repair_cli_public_case(row)
    Dir.mktmpdir do |home|
      ctx = instance_exec(home, &row.fetch(:arrange))
      stdout, stderr, status = run_log_repair_command(home)
      assert_equal row.fetch(:exit), status.exitstatus, "#{stdout}\n#{stderr}"
      assert_empty stderr
      result = JSON.parse(stdout)
      assert_equal row.fetch(:code), result.fetch("code")
      assert_equal row.fetch(:changes), result.fetch("changes") if row.key?(:changes)
      instance_exec(home, ctx, &row.fetch(:verify)) if row.key?(:verify)
    end
  end

  LOG_REPAIR_CLI_PUBLIC_CASES = [
    {
      name: :test_log_repair_public_command_preserves_unwritable_tree_and_recreates_session,
      exit: 1, code: "log_runtime_unverified", changes: ["log_directory_permissions"],
      arrange: lambda do |home|
        config_root = File.join(home, ".config", "clash.meta")
        session = File.join(config_root, "logs", "2026-08-05_00-59-57")
        FileUtils.mkdir_p(session, mode: 0o700)
        File.binwrite(File.join(session, "old.log"), "incident evidence")
        File.chmod(0o400, session)
        File.chmod(0o500, File.dirname(session))
        config_root
      end,
      verify: lambda do |_home, config_root|
        logs = File.join(config_root, "logs")
        assert File.writable?(logs)
        assert File.executable?(logs)
        assert Dir.exist?(File.join(logs, "2026-08-05_00-59-57"))
        backups = Dir.glob(File.join(config_root, "logs.permission-backup-*"))
        assert_equal 1, backups.length
        FileUtils.chmod_R(0o700, backups.fetch(0))
        assert_equal "incident evidence", File.binread(
          File.join(backups.fetch(0), "2026-08-05_00-59-57", "old.log")
        )
      ensure
        FileUtils.chmod_R(0o700, config_root) if File.exist?(config_root)
      end
    },
    {
      name: :test_log_repair_public_command_rejects_symlink,
      exit: 1, code: "unsafe_log_path",
      arrange: lambda do |home|
        config_root = File.join(home, ".config", "clash.meta")
        outside = File.join(home, "outside")
        FileUtils.mkdir_p([config_root, outside])
        File.binwrite(File.join(outside, "keep"), "unchanged")
        File.symlink(outside, File.join(config_root, "logs"))
        outside
      end,
      verify: lambda do |_home, outside|
        assert_equal "unchanged", File.binread(File.join(outside, "keep"))
      end
    }
  ]

  LOG_REPAIR_CLI_PUBLIC_CASES.each { |row| define_method(row.fetch(:name)) { run_log_repair_cli_public_case(row) } }
  def test_log_repair_public_command_creates_missing_tree_and_is_idempotent
    Dir.mktmpdir do |home|
      config_root = File.join(home, ".config", "clash.meta")
      FileUtils.mkdir_p(config_root, mode: 0o700)

      first_stdout, first_stderr, first_status = run_log_repair_command(home)
      assert_equal 1, first_status.exitstatus, "#{first_stdout}\n#{first_stderr}"
      assert_empty first_stderr
      assert_equal "log_runtime_unverified", JSON.parse(first_stdout).fetch("code")
      logs = File.join(config_root, "logs")
      before = File.stat(logs)

      stdout, stderr, status = run_log_repair_command(home)
      assert_equal 1, status.exitstatus, "#{stdout}\n#{stderr}"
      assert_empty stderr
      assert_equal "log_runtime_unverified", JSON.parse(stdout).fetch("code")
      after = File.stat(logs)
      assert_equal [before.dev, before.ino], [after.dev, after.ino]
    end
  end
  def test_log_repair_helpers_reject_bad_acl_and_paths
    assert_equal File.expand_path("~/.config/clash.meta/logs"), ClaudeEasy.clashx_log_root
    status = Struct.new(:success?)
    failed_runner = ->(*_arguments) { ["", "", status.new(false)] }
    assert_raises(ClaudeEasy::LogRepairError) do
      ClaudeEasy.add_log_acl("ignored", username: "tester", runner: failed_runner)
    end

    calls = 0
    unreadable_runner = lambda do |*_arguments|
      calls += 1
      [calls == 1 ? "" : "no acl", "", status.new(true)]
    end
    assert_raises(ClaudeEasy::LogRepairError) do
      ClaudeEasy.add_log_acl("ignored", username: "tester", runner: unreadable_runner)
    end

    uuid = "FFFFEEEE-DDDD-CCCC-BBBB-AAAA000001F5"
    complete_rights = "list,add_file,search,delete,add_subdirectory,delete_child,readattr," \
                      "writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit"
    acl_runner = lambda do |output|
      lambda do |*arguments|
        if arguments[0] == "/bin/ls"
          [output, "", status.new(true)]
        else
          [uuid, "", status.new(true)]
        end
      end
    end
    assert ClaudeEasy.log_acl_present?(
      "ignored", username: "tester", runner: acl_runner.call(" 0: #{uuid} allow #{complete_rights}\n")
    )
    refute ClaudeEasy.log_acl_present?(
      "ignored", username: "tester",
      runner: acl_runner.call(" 0: #{uuid} allow #{complete_rights.sub(',delete_child', '')}\n")
    )
    refute ClaudeEasy.log_acl_present?(
      "ignored", username: "tester",
      runner: acl_runner.call(
        " 0: #{uuid} allow #{complete_rights}\n 1: #{uuid} deny add_file,file_inherit\n"
      )
    )

    Dir.mktmpdir do |home|
      home_stat = File.stat(home)
      assert_raises(ClaudeEasy::UnsafeLogPathError) do
        ClaudeEasy.chmod_log_directory(home, 0o700, [home_stat.dev, home_stat.ino + 1])
      end

      missing = File.join(home, "missing", "logs")
      assert_raises(ClaudeEasy::UnsafeLogPathError) do
        ClaudeEasy.validate_log_config_root(missing)
      end

      outside = File.join(home, "outside")
      FileUtils.mkdir_p(outside)
      config_link = File.join(home, "clash.meta")
      File.symlink(outside, config_link)
      assert_raises(ClaudeEasy::UnsafeLogPathError) do
        ClaudeEasy.validate_log_config_root(File.join(config_link, "logs"))
      end

      log_link = File.join(outside, "logs-link")
      File.symlink(home, log_link)
      assert_raises(ClaudeEasy::UnsafeLogPathError) do
        ClaudeEasy.repair_clashx_logs(log_root: log_link)
      end
    end

    Dir.stub(:children, ->(_path) { raise Errno::EACCES }) do
      assert_equal [], ClaudeEasy.log_session_names("ignored")
    end
  end
  def test_log_repair_directly_covers_missing_healthy_and_inaccessible_trees
    Dir.mktmpdir do |home|
      config_root = File.join(home, "clash.meta")
      logs = File.join(config_root, "logs")
      FileUtils.mkdir_p(config_root)

      result = ClaudeEasy.repair_clashx_logs(log_root: logs)
      assert_equal :repaired, result.fetch(:status)
      assert_equal false, result.fetch(:backup_preserved)

      FileUtils.rm_rf(logs)
      FileUtils.mkdir_p(logs, mode: 0o700)
      result = ClaudeEasy.repair_clashx_logs(log_root: logs)
      assert_equal :repaired, result.fetch(:status)
      result = ClaudeEasy.repair_clashx_logs(log_root: logs)
      assert_equal :already_writable, result.fetch(:status)

      FileUtils.rm_rf(logs)
      session = File.join(logs, "2026-08-05_00-59-57")
      FileUtils.mkdir_p(session, mode: 0o700)
      File.chmod(0o500, logs)
      begin
        result = ClaudeEasy.repair_clashx_logs(log_root: logs)
        assert_equal :repaired, result.fetch(:status)
        assert_equal true, result.fetch(:backup_preserved)
        assert_equal true, result.fetch(:session_recreated)
        assert Dir.exist?(File.join(logs, "2026-08-05_00-59-57"))
      ensure
        FileUtils.chmod_R(0o700, config_root) if File.exist?(config_root)
      end
    end
  end
  def test_log_repair_does_not_report_success_while_the_current_session_is_inaccessible
    Dir.mktmpdir do |home|
      config_root = File.join(home, "clash.meta")
      logs = File.join(config_root, "logs")
      session_name = "2026-08-05_00-59-57"
      session = File.join(logs, session_name)
      FileUtils.mkdir_p(session, mode: 0o700)
      old_log = File.join(session, "old.log")
      File.binwrite(old_log, "incident evidence")
      File.chmod(0o000, session)

      begin
        result = ClaudeEasy.repair_clashx_logs(log_root: logs)

        assert_equal :repaired, result.fetch(:status)
        assert result.fetch(:backup_preserved)
        assert File.writable?(session)
        assert File.executable?(session)
        backup = Dir.glob(File.join(config_root, "logs.permission-backup-*")).fetch(0)
        FileUtils.chmod_R(0o700, backup)
        assert_equal "incident evidence", File.binread(File.join(backup, session_name, "old.log"))
      ensure
        FileUtils.chmod_R(0o700, config_root) if File.exist?(config_root)
      end
    end
  end
  def test_current_log_session_writability_checks_the_complete_tree
    Dir.mktmpdir do |logs|
      session = File.join(logs, "2026-08-05_00-59-57")
      nested = File.join(session, "nested")
      FileUtils.mkdir_p(nested)
      log = File.join(nested, "current.log")
      File.binwrite(log, "ok")
      assert ClaudeEasy.current_log_session_writable?(logs)

      File.stub(:writable?, ->(path) { path == log ? false : true }) do
        refute ClaudeEasy.current_log_session_writable?(logs)
      end

      fifo = File.join(nested, "unexpected.fifo")
      File.mkfifo(fifo)
      refute ClaudeEasy.current_log_session_writable?(logs)
      FileUtils.rm_f(fifo)
      link = File.join(nested, "linked.log")
      File.symlink(log, link)
      refute ClaudeEasy.current_log_session_writable?(logs)
      FileUtils.rm_f(link)

      File.stub(:lstat, ->(_path) { raise Errno::EACCES }) do
        refute ClaudeEasy.current_log_session_writable?(logs)
      end
    end
  end
  def test_log_repair_rejects_root_and_invalid_acl_username
    Process.stub(:uid, 0) do
      assert_raises(ClaudeEasy::UnsafeLogPathError) do
        ClaudeEasy.repair_clashx_logs(log_root: "/unused")
      end
    end

    Dir.mktmpdir do |home|
      config_root = File.join(home, "clash.meta")
      FileUtils.mkdir_p(config_root)
      account = Struct.new(:name).new("bad user")
      Etc.stub(:getpwuid, account) do
        assert_raises(ClaudeEasy::UnsafeLogPathError) do
          ClaudeEasy.repair_clashx_logs(log_root: File.join(config_root, "logs"))
        end
      end
    end
  end
  def test_log_repair_restores_old_tree_if_replacement_publish_fails
    Dir.mktmpdir do |home|
      config_root = File.join(home, "clash.meta")
      logs = File.join(config_root, "logs")
      FileUtils.mkdir_p(logs)
      File.chmod(0o500, logs)
      calls = 0
      renamer = lambda do |source, destination|
        calls += 1
        raise IOError, "injected publish failure" if calls == 2

        File.rename(source, destination)
        true
      end

      begin
        ClaudeEasyOperationLock.stub(:rename_exclusive, renamer) do
          assert_raises(ClaudeEasy::LogRepairError) do
            ClaudeEasy.repair_clashx_logs(log_root: logs)
          end
        end
        assert_equal 3, calls
        assert Dir.exist?(logs)
        assert_empty Dir.glob(File.join(config_root, ".logs.permission-repair-*"))
      ensure
        FileUtils.chmod_R(0o700, config_root) if File.exist?(config_root)
      end
    end
  end
  def test_log_repair_temporarily_restores_owner_access_before_renaming_unwritable_tree
    Dir.mktmpdir do |home|
      config_root = File.join(home, "clash.meta")
      logs = File.join(config_root, "logs")
      FileUtils.mkdir_p(logs)
      File.chmod(0o500, logs)
      renamed_mode = nil
      renamer = lambda do |source, destination|
        renamed_mode = File.stat(source).mode & 0o777 if source == logs
        raise Errno::EACCES, source unless (renamed_mode & 0o300) == 0o300

        File.rename(source, destination)
        true
      end

      begin
        ClaudeEasyOperationLock.stub(:rename_exclusive, renamer) do
          result = ClaudeEasy.repair_clashx_logs(log_root: logs)
          assert_equal :repaired, result.fetch(:status)
        end
        assert_equal 0o700, renamed_mode
        backup = Dir.glob(File.join(config_root, "logs.permission-backup-*")).fetch(0)
        assert_equal 0o500, File.stat(backup).mode & 0o777
      ensure
        FileUtils.chmod_R(0o700, config_root) if File.exist?(config_root)
      end
    end
  end
  def test_log_repair_restores_original_mode_if_preserving_old_tree_fails
    Dir.mktmpdir do |home|
      config_root = File.join(home, "clash.meta")
      logs = File.join(config_root, "logs")
      FileUtils.mkdir_p(logs)
      File.chmod(0o500, logs)

      begin
        ClaudeEasyOperationLock.stub(:rename_exclusive, ->(*_arguments) { raise IOError, "injected" }) do
          assert_raises(ClaudeEasy::LogRepairError) do
            ClaudeEasy.repair_clashx_logs(log_root: logs)
          end
        end
        assert_equal 0o500, File.stat(logs).mode & 0o777
        assert_empty Dir.glob(File.join(config_root, ".logs.permission-repair-*"))
      ensure
        FileUtils.chmod_R(0o700, config_root) if File.exist?(config_root)
      end
    end
  end
  def test_log_repair_fails_if_replacement_permissions_cannot_be_verified
    Dir.mktmpdir do |home|
      config_root = File.join(home, "clash.meta")
      logs = File.join(config_root, "logs")
      FileUtils.mkdir_p(logs)
      File.chmod(0o500, logs)
      checks = 0
      acl_check = lambda do |*_arguments, **_keywords|
        checks += 1
        checks == 1
      end

      begin
        ClaudeEasy.stub(:log_acl_present?, acl_check) do
          assert_raises(ClaudeEasy::LogRepairPartialError) do
            ClaudeEasy.repair_clashx_logs(log_root: logs)
          end
        end
        assert File.directory?(logs)
        assert_equal 1, Dir.glob(File.join(config_root, "logs.permission-backup-*")).length
      ensure
        FileUtils.chmod_R(0o700, config_root) if File.exist?(config_root)
      end
    end
  end
  def test_log_repair_reports_partial_after_publishing_the_new_tree
    Dir.mktmpdir do |home|
      config_root = File.join(home, "clash.meta")
      logs = File.join(config_root, "logs")
      FileUtils.mkdir_p(logs)
      File.chmod(0o500, logs)
      original_chmod = ClaudeEasy.method(:chmod_log_directory)
      calls = 0
      chmod = lambda do |path, mode, identity|
        calls += 1
        raise IOError, "injected backup chmod failure" if calls == 2

        original_chmod.call(path, mode, identity)
      end

      begin
        ClaudeEasy.stub(:chmod_log_directory, chmod) do
          assert_raises(ClaudeEasy::LogRepairPartialError) do
            ClaudeEasy.repair_clashx_logs(log_root: logs)
          end
        end
        assert Dir.exist?(logs)
        assert_equal 1, Dir.glob(File.join(config_root, "logs.permission-backup-*")).length
      ensure
        FileUtils.chmod_R(0o700, config_root) if File.exist?(config_root)
      end
    end
  end
  def test_log_repair_removes_a_new_tree_when_acl_setup_fails
    Dir.mktmpdir do |home|
      config_root = File.join(home, "clash.meta")
      logs = File.join(config_root, "logs")
      FileUtils.mkdir_p(config_root)
      failed_runner = lambda do |*_arguments|
        ["", "", Struct.new(:success?).new(false)]
      end

      assert_raises(ClaudeEasy::LogRepairError) do
        ClaudeEasy.repair_clashx_logs(log_root: logs, runner: failed_runner)
      end
      refute File.exist?(logs)
    end
  end
  def test_log_repair_reports_partial_when_a_failed_new_tree_cannot_be_removed
    Dir.mktmpdir do |home|
      config_root = File.join(home, "clash.meta")
      logs = File.join(config_root, "logs")
      FileUtils.mkdir_p(config_root)
      failed_runner = lambda do |*_arguments|
        ["", "", Struct.new(:success?).new(false)]
      end

      ClaudeEasy.stub(:remove_created_log_tree, false) do
        assert_raises(ClaudeEasy::LogRepairPartialError) do
          ClaudeEasy.repair_clashx_logs(log_root: logs, runner: failed_runner)
        end
      end
    end

    File.stub(:lstat, ->(_path) { raise Errno::EACCES }) do
      refute ClaudeEasy.remove_created_log_tree([["unreadable", [1, 2]]])
    end
  end
  def test_log_repair_preserves_unexpected_failures
    Dir.mktmpdir do |home|
      config_root = File.join(home, "clash.meta")
      FileUtils.mkdir_p(config_root)
      creator = ->(*_arguments, **_keywords) { raise RuntimeError, "injected" }
      ClaudeEasy.stub(:create_log_tree, creator) do
        error = assert_raises(RuntimeError) do
          ClaudeEasy.repair_clashx_logs(log_root: File.join(config_root, "logs"))
        end
        assert_equal "injected", error.message
      end
    end
  end
  def test_log_repair_cli_covers_human_success_and_failure_messages
    stdout, stderr = capture_io do
      ClaudeEasy.stub(:repair_clashx_logs, { status: :repaired, backup_preserved: false }) do
        ClaudeEasy.stub(:verify_clashx_file_logging, true) do
          assert_equal 0, ClaudeEasy.cli(["--repair-clashx-logs"])
        end
      end
    end
    assert_includes stdout, "已恢复写入"
    assert_empty stderr

    _stdout, stderr = capture_io do
      ClaudeEasy.stub(:repair_clashx_logs, -> { raise ClaudeEasy::UnsafeLogPathError }) do
        assert_equal 1, ClaudeEasy.cli(["--repair-clashx-logs"])
      end
    end
    assert_includes stderr, "路径不安全"

    _stdout, stderr = capture_io do
      ClaudeEasy.stub(:repair_clashx_logs, -> { raise ClaudeEasy::LogRepairError }) do
        assert_equal 1, ClaudeEasy.cli(["--repair-clashx-logs"])
      end
    end
    assert_includes stderr, "修复失败"

    stdout, stderr = capture_io do
      ClaudeEasy.stub(:repair_clashx_logs, -> { raise ClaudeEasy::LogRepairError }) do
        assert_equal 1, ClaudeEasy.cli(["--repair-clashx-logs", "--json"])
      end
    end
    assert_empty stderr
    assert_equal "log_repair_failed", JSON.parse(stdout).fetch("code")

    stdout, stderr = capture_io do
      ClaudeEasy.stub(:repair_clashx_logs, -> { raise ClaudeEasy::LogRepairPartialError }) do
        assert_equal 1, ClaudeEasy.cli(["--repair-clashx-logs", "--json"])
      end
    end
    assert_empty stderr
    partial = JSON.parse(stdout)
    assert_equal "partial", partial.fetch("status")
    assert_equal "log_repair_partial", partial.fetch("code")
    assert_equal ["log_directory_permissions"], partial.fetch("changes")

    _stdout, stderr = capture_io do
      ClaudeEasy.stub(:repair_clashx_logs, -> { raise ClaudeEasy::LogRepairPartialError }) do
        assert_equal 1, ClaudeEasy.cli(["--repair-clashx-logs"])
      end
    end
    assert_includes stderr, "只完成了一部分"

    stdout, stderr = capture_io do
      ClaudeEasy.stub(:repair_clashx_logs, { status: :repaired, backup_preserved: true }) do
        ClaudeEasy.stub(:verify_clashx_file_logging, true) do
          assert_equal 0, ClaudeEasy.cli(["--repair-clashx-logs", "--json"])
        end
      end
    end
    assert_empty stderr
    result = JSON.parse(stdout)
    assert_equal "logs_repaired", result.fetch("code")
    assert_equal ["clashx_file_logging"], result.fetch("changes")
  end
  def test_log_repair_cli_does_not_claim_runtime_recovery_without_runtime_evidence
    stdout, stderr = capture_io do
      ClaudeEasy.stub(:repair_clashx_logs, { status: :repaired, backup_preserved: true }) do
        ClaudeEasy.stub(:verify_clashx_file_logging, false) do
          assert_equal 1, ClaudeEasy.cli(["--repair-clashx-logs", "--json"])
        end
      end
    end

    assert_empty stderr
    result = JSON.parse(stdout)
    assert_equal "partial", result.fetch("status")
    assert_equal "log_runtime_unverified", result.fetch("code")
    assert_equal ["log_directory_permissions"], result.fetch("changes")
    refute_includes result.fetch("summary_zh"), "已恢复写入"

    _stdout, stderr = capture_io do
      ClaudeEasy.stub(:repair_clashx_logs, { status: :already_writable }) do
        ClaudeEasy.stub(:verify_clashx_file_logging, false) do
          assert_equal 1, ClaudeEasy.cli(["--repair-clashx-logs"])
        end
      end
    end
    assert_includes stderr, "未确认"
  end


















  def test_file_logging_runtime_verification_requires_growth_and_clean_unified_logs
    Dir.mktmpdir do |logs|
      session = File.join(logs, "2026-08-05_00-59-57")
      FileUtils.mkdir_p(session)
      log = File.join(session, "clashx_2026-08-05.log")
      File.binwrite(log, "before")
      status = Struct.new(:success?).new(true)
      clean_runner = ->(*_arguments) { ["", "", status] }
      probe = -> { File.binwrite(log, "before-after"); true }

      assert ClaudeEasy.verify_clashx_file_logging(
        log_root: logs, proxy_probe: probe, runner: clean_runner,
        sleeper: ->(_seconds) {}
      )

      File.binwrite(log, "before")
      error_runner = lambda do |*_arguments|
        ["DDFileLogManagerDefault Cocoa 513", "", status]
      end
      refute ClaudeEasy.verify_clashx_file_logging(
        log_root: logs, proxy_probe: probe, runner: error_runner,
        sleeper: ->(_seconds) {}
      )

      refute ClaudeEasy.verify_clashx_file_logging(
        log_root: logs, proxy_probe: -> { true }, runner: clean_runner,
        sleeper: ->(_seconds) {}
      )
      empty_log = File.join(session, "clashx_empty.log")
      refute ClaudeEasy.verify_clashx_file_logging(
        log_root: logs, proxy_probe: -> { File.binwrite(empty_log, ""); true },
        runner: clean_runner, sleeper: ->(_seconds) {}
      )
      FileUtils.rm_f(empty_log)
      refute ClaudeEasy.verify_clashx_file_logging(
        log_root: logs, proxy_probe: -> { false }, runner: clean_runner,
        sleeper: ->(_seconds) {}
      )

      File.binwrite(log, "before")
      requester = ->(_method, _endpoint, _body) { [200, ""] }
      ClaudeEasy.stub(:harmless_proxy_request_healthy?, ->(_requester) {
        File.binwrite(log, "before-after")
        true
      }) do
        assert ClaudeEasy.verify_clashx_file_logging(
          log_root: logs, requester: requester, runner: clean_runner,
          sleeper: ->(_seconds) {}
        )
      end

      ClaudeEasy.stub(:controller_socket, nil) do
        refute ClaudeEasy.verify_clashx_file_logging(
          log_root: logs, runner: clean_runner, sleeper: ->(_seconds) {}
        )
      end

      failed_status = Struct.new(:success?).new(false)
      File.binwrite(log, "before")
      refute ClaudeEasy.verify_clashx_file_logging(
        log_root: logs,
        proxy_probe: -> { File.binwrite(log, "before-again"); true },
        runner: ->(*_arguments) { ["", "", failed_status] },
        sleeper: ->(_seconds) {}
      )

      refute ClaudeEasy.verify_clashx_file_logging(
        log_root: File.join(logs, "missing"), proxy_probe: -> { true },
        runner: clean_runner, sleeper: ->(_seconds) {}
      )
      ClaudeEasy.stub(:log_session_names, ["missing-session"]) do
        assert_empty ClaudeEasy.clashx_log_snapshots(logs)
      end
      refute ClaudeEasy.verify_clashx_file_logging(
        log_root: logs, proxy_probe: -> { raise IOError, "probe failed" },
        runner: clean_runner
      )

      File.binwrite(log, "before")
      ClaudeEasy.stub(:controller_socket, "fixture.sock") do
        ClaudeEasy.stub(:controller_request, ->(*_arguments) { [200, ""] }) do
          ClaudeEasy.stub(:harmless_proxy_request_healthy?, lambda { |_requester|
            File.binwrite(log, "before-after")
            true
          }) do
            assert ClaudeEasy.verify_clashx_file_logging(
              log_root: logs, runner: clean_runner, sleeper: ->(_seconds) {}
            )
          end
        end
      end
    end
  end

  def test_harmless_proxy_request_uses_one_isolated_request
    requester = lambda do |_method, _endpoint, _body|
      [200, JSON.generate("mixed-port" => 7890)]
    end
    status = Struct.new(:success?).new(true)
    captured = nil
    Open3.stub(:capture2e, ->(*arguments) { captured = arguments; ["", status] }) do
      assert ClaudeEasy.harmless_proxy_request_healthy?(requester)
    end
    assert_equal 1, captured.count("https://www.google.com/generate_204")
    assert_includes captured, "http://127.0.0.1:7890"

    Open3.stub(:capture2e, ->(*_arguments) { raise IOError }) do
      refute ClaudeEasy.harmless_proxy_request_healthy?(requester)
    end
    refute ClaudeEasy.harmless_proxy_request_healthy?(->(*_arguments) { [500, ""] })
  end

  def test_wrapper_operation_lock_serializes_mutations_and_uses_private_permissions
    Dir.mktmpdir do |directory|
      path = File.join(directory, "backups", ".claude-easy-wrapper.lock")
      first = ClaudeEasyOperationLock.acquire(path)
      begin
        second = Thread.new do
          ClaudeEasyOperationLock.acquire(path, timeout_seconds: 0.1)
        end.value
        assert_nil second
        assert_equal 0o600, File.stat(path).mode & 0o777
        assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
      ensure
        first.close
      end
    end
  end

  def test_wrapper_operation_lock_durably_publishes_each_new_state_directory
    Dir.mktmpdir do |directory|
      state_root = File.join(directory, "ClaudeEasy")
      backup_root = File.join(state_root, "backups")
      lock_path = File.join(backup_root, ".claude-easy-wrapper.lock")
      syncs = []
      handle = ClaudeEasyOperationLock.stub(:fsync_directory, ->(path) {
        syncs << path
        true
      }) do
        ClaudeEasyOperationLock.acquire(lock_path)
      end
      handle.close

      assert_equal [
        File.dirname(directory),
        state_root, directory,
        backup_root, state_root
      ], syncs
      assert_equal 0o700, File.stat(state_root).mode & 0o777
      assert_equal 0o700, File.stat(backup_root).mode & 0o777
    end
  end

  def test_wrapper_operation_lock_accepts_a_concurrently_created_private_directory
    Dir.mktmpdir do |directory|
      target = File.join(directory, "backups")
      real_mkdir = Dir.method(:mkdir)
      injected = false
      racing_mkdir = lambda do |path, mode|
        unless injected
          injected = true
          real_mkdir.call(path, mode)
          raise Errno::EEXIST
        end
        real_mkdir.call(path, mode)
      end

      result = Dir.stub(:mkdir, racing_mkdir) do
        ClaudeEasyOperationLock.ensure_durable_private_directory(target)
      end

      assert injected
      assert_equal target, result
      assert File.directory?(target)
    end
  end

  def test_wrapper_operation_lock_rejects_a_lock_replaced_before_open
    Dir.mktmpdir do |directory|
      lock_path = File.join(directory, "backups", "lock")
      target = File.join(directory, "unrelated")
      File.binwrite(target, "preserve")
      File.chmod(0o644, target)
      original_open = File.method(:open)
      raced = false
      racing_open = lambda do |path, *arguments, &block|
        if !raced && File.expand_path(path) == lock_path
          raced = true
          File.symlink(target, lock_path)
        end
        original_open.call(path, *arguments, &block)
      end

      File.stub(:open, racing_open) do
        assert_raises(SystemCallError, IOError) do
          ClaudeEasyOperationLock.acquire(lock_path)
        end
      end
      assert_equal 0o644, File.stat(target).mode & 0o777
    end
  end

  def test_wrapper_operation_lock_rejects_links_and_reports_run_outcomes
    Dir.mktmpdir do |directory|
      real_directory = File.join(directory, "real")
      linked_directory = File.join(directory, "linked")
      FileUtils.mkdir_p(real_directory)
      File.symlink(real_directory, linked_directory)
      assert_raises(IOError) do
        ClaudeEasyOperationLock.acquire(File.join(linked_directory, "lock"))
      end

      lock_path = File.join(real_directory, "lock")
      File.write(lock_path, "link-target")
      linked_lock = File.join(real_directory, "linked-lock")
      File.symlink(lock_path, linked_lock)
      assert_raises(IOError) { ClaudeEasyOperationLock.acquire(linked_lock) }

      assert_equal(
        ClaudeEasyOperationLock::BUSY_EXIT,
        ClaudeEasyOperationLock.stub(:acquire, nil) do
          ClaudeEasyOperationLock.run([lock_path, "/usr/bin/true"])
        end
      )
      assert_equal(
        ClaudeEasyOperationLock::FAILED_EXIT,
        ClaudeEasyOperationLock.stub(:acquire, ->(_path) { raise IOError, "injected" }) do
          ClaudeEasyOperationLock.run([lock_path, "/usr/bin/true"])
        end
      )
      assert_equal(
        ClaudeEasyOperationLock::FAILED_EXIT,
        ClaudeEasyOperationLock.run([])
      )
      assert_equal(
        ClaudeEasyOperationLock::FAILED_EXIT,
        ClaudeEasyOperationLock.run(["--unknown", real_directory])
      )
    end
  end

  def test_wrapper_operation_lock_exposes_durable_state_commands
    Dir.mktmpdir do |directory|
      nested = File.join(directory, "state", "backups")
      assert_equal 0, ClaudeEasyOperationLock.run([
        ClaudeEasyOperationLock::ENSURE_DIRECTORY_COMMAND, nested
      ])
      assert_equal 0o700, File.stat(nested).mode & 0o777

      state = File.join(nested, "state.json")
      File.binwrite(state, "{}\n")
      assert_equal 0, ClaudeEasyOperationLock.run([
        ClaudeEasyOperationLock::SYNC_FILE_COMMAND, state
      ])
      assert_equal 0, ClaudeEasyOperationLock.run([
        ClaudeEasyOperationLock::SYNC_DIRECTORY_COMMAND, nested
      ])

      linked = File.join(nested, "linked-state")
      File.symlink(state, linked)
      assert_equal ClaudeEasyOperationLock::FAILED_EXIT,
                   ClaudeEasyOperationLock.run([
                     ClaudeEasyOperationLock::SYNC_FILE_COMMAND, linked
                   ])

      lock_path = File.join(nested, ".claude-easy-wrapper.lock")
      with_internal_wrapper_operation(nested) do
        assert_equal 0, ClaudeEasyOperationLock.run([
          ClaudeEasyOperationLock::VERIFY_HELD_COMMAND, lock_path
        ])
      end
      assert_equal ClaudeEasyOperationLock::FAILED_EXIT,
                   ClaudeEasyOperationLock.run([
                     ClaudeEasyOperationLock::VERIFY_HELD_COMMAND, lock_path
                   ])
    end
  end

  def test_wrapper_operation_lock_renames_without_overwriting_and_syncs_both_parents
    Dir.mktmpdir do |directory|
      source_parent = File.join(directory, "source")
      destination_parent = File.join(directory, "destination")
      FileUtils.mkdir_p([source_parent, destination_parent])
      source = File.join(source_parent, "state")
      destination = File.join(destination_parent, "state")
      File.binwrite(source, "owned")

      assert_equal 0, ClaudeEasyOperationLock.run([
        ClaudeEasyOperationLock::RENAME_EXCLUSIVE_COMMAND, source, destination
      ])
      assert_equal "owned", File.binread(destination)
      refute File.exist?(source)

      replacement = File.join(source_parent, "replacement")
      File.binwrite(replacement, "replacement")
      assert_raises(IOError) do
        ClaudeEasyOperationLock.rename_exclusive(replacement, destination)
      end
      assert_equal "replacement", File.binread(replacement)
      assert_equal "owned", File.binread(destination)

      ClaudeEasyExclusiveRename.stub(:renamex_np, -1) do
        assert_raises(SystemCallError) do
          ClaudeEasyExclusiveRename.call(replacement, File.join(source_parent, "other"))
        end
      end
    end
  end

  def test_wrapper_operation_lock_fails_closed_when_exclusive_directory_rename_is_unsupported
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      destination = File.join(directory, "destination")
      Dir.mkdir(source)

      ClaudeEasyExclusiveRename.stub(:call, ->(*_arguments) { raise Errno::EACCES }) do
        assert_raises(Errno::EACCES) do
          ClaudeEasyOperationLock.rename_exclusive(source, destination)
        end
      end
      assert Dir.exist?(source)
      refute File.exist?(destination)
    end
  end

  def test_wrapper_operation_lock_executes_with_an_inherited_descriptor
    Dir.mktmpdir do |directory|
      lock_path = File.join(directory, "lock")
      executed = nil
      original_marker = ENV[ClaudeEasyOperationLock::HELD_ENV]
      begin
        ClaudeEasyOperationLock.stub(:exec, ->(*command) { executed = command }) do
          assert_equal 0, ClaudeEasyOperationLock.run([lock_path, "/usr/bin/true", "argument"])
        end
        assert_equal ["/usr/bin/true", "argument"], executed
        assert_equal "1", ENV[ClaudeEasyOperationLock::HELD_ENV]
        assert_equal ["example"], ClaudeEasyOperationLock.stub(:exec, ->(*command) { command }) {
          ClaudeEasyOperationLock.execute(["example"])
        }
      ensure
        ENV[ClaudeEasyOperationLock::HELD_ENV] = original_marker
      end
    end
  end

  def test_normal_batch_replans_a_refresh_before_journal_and_recovers_a_later_commit_failure
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "original"))
      refreshed = YAML.dump(base_config.merge("subscription-marker" => "refreshed"))
      backup_root = File.join(directory, "backups")
      File.binwrite(path, original)

      real_prepare = ClaudeEasy.method(:prepare_profile_transaction)
      refresh_injected = false
      prepare_after_refresh = lambda do |items, root, **options|
        unless refresh_injected
          File.binwrite(path, refreshed)
          refresh_injected = true
        end
        real_prepare.call(items, root, **options)
      end

      real_replace = ClaudeEasy.method(:transactional_replace_locked)
      commit_injected = false
      fail_after_commit = lambda do |*arguments|
        result = real_replace.call(*arguments)
        if result && !commit_injected
          commit_injected = true
          raise IOError, "injected after the durable commit"
        end
        result
      end

      results = ClaudeEasy.stub(:prepare_profile_transaction, prepare_after_refresh) do
        ClaudeEasy.stub(:transactional_replace_locked, fail_after_commit) do
          ClaudeEasy.run(
            directory: directory, policy_path: POLICY_PATH,
            backup_root: backup_root, selected_name: "none",
            validator: ->(_path) { true }, auto_reload: false, usage_profile: 1
          )
        end
      end

      assert refresh_injected
      assert commit_injected
      refute results.all? { |result| %i[updated unchanged].include?(result.fetch(:status)) }
      assert_equal refreshed.b, File.binread(path)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_normal_batch_binds_unchanged_preflight_items_before_committing_other_profiles
    Dir.mktmpdir do |directory|
      unchanged_path = File.join(directory, "a-unchanged.yaml")
      changed_path = File.join(directory, "z-changed.yaml")
      unchanged = YAML.dump(ClaudeEasy.patch(base_config, @policy, usage_profile: 1).fetch(:config))
      refreshed = YAML.dump(base_config.merge("subscription-marker" => "refreshed"))
      changed_original = YAML.dump(base_config.merge("subscription-marker" => "unchanged-source"))
      backup_root = File.join(directory, "backups")
      File.binwrite(unchanged_path, unchanged)
      File.binwrite(changed_path, changed_original)

      real_prepare = ClaudeEasy.method(:prepare_profile_transaction)
      prepare_after_refresh = lambda do |items, root, **options|
        File.binwrite(unchanged_path, refreshed)
        real_prepare.call(items, root, **options)
      end
      real_replace = ClaudeEasy.method(:transactional_replace_locked)
      commit_injected = false
      fail_after_commit = lambda do |*arguments|
        result = real_replace.call(*arguments)
        if result && !commit_injected
          commit_injected = true
          raise IOError, "injected after an unjournaled durable commit"
        end
        result
      end

      results = ClaudeEasy.stub(:prepare_profile_transaction, prepare_after_refresh) do
        ClaudeEasy.stub(:transactional_replace_locked, fail_after_commit) do
          ClaudeEasy.run(
            directory: directory, policy_path: POLICY_PATH,
            backup_root: backup_root, selected_name: "none",
            validator: ->(_path) { true }, auto_reload: false, usage_profile: 1
          )
        end
      end

      assert commit_injected
      refute results.all? { |result| %i[updated unchanged].include?(result.fetch(:status)) }
      assert_equal refreshed.b, File.binread(unchanged_path)
      assert_equal changed_original.b, File.binread(changed_path)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_normal_batch_stops_after_repeated_refreshes_and_preserves_the_latest_bytes
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.binwrite(path, YAML.dump(base_config))
      real_prepare = ClaudeEasy.method(:prepare_profile_transaction)
      refreshes = 0
      prepare_after_refresh = lambda do |items, root, **options|
        refreshes += 1
        File.binwrite(
          path,
          YAML.dump(base_config.merge("subscription-marker" => "refresh-#{refreshes}"))
        )
        real_prepare.call(items, root, **options)
      end

      results = ClaudeEasy.stub(:prepare_profile_transaction, prepare_after_refresh) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: backup_root, selected_name: "none",
          validator: ->(_path) { true }, auto_reload: false, usage_profile: 1
        )
      end

      assert_equal ClaudeEasy::MAX_PATCH_ATTEMPTS, refreshes
      assert_equal :concurrent_change, results.fetch(0).fetch(:status)
      written = ClaudeEasy.load_yaml(File.binread(path))
      assert_equal "refresh-#{refreshes}", written.fetch("subscription-marker")
      refute written.dig("rule-providers", "claude-easy-cn-domain")
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_normal_batch_binds_each_commit_to_the_transaction_inode
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.binwrite(path, original)
      real_prepare = ClaudeEasy.method(:prepare_profile_transaction)
      replacements = 0
      latest_identity = nil
      prepare_then_replace = lambda do |items, root, **options|
        transaction = real_prepare.call(items, root, **options)
        replacement = File.join(directory, "replacement-#{replacements}.yaml")
        File.binwrite(replacement, original)
        File.rename(replacement, path)
        current = File.stat(path)
        latest_identity = [current.dev, current.ino]
        replacements += 1
        transaction
      end

      results = ClaudeEasy.stub(:prepare_profile_transaction, prepare_then_replace) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: backup_root, selected_name: "none",
          validator: ->(_path) { true }, auto_reload: false, usage_profile: 1
        )
      end

      current = File.stat(path)
      assert_equal ClaudeEasy::MAX_PATCH_ATTEMPTS, replacements
      assert_equal :concurrent_change, results.fetch(0).fetch(:status)
      assert_equal original.b, File.binread(path)
      assert_equal latest_identity, [current.dev, current.ino]
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_normal_batch_recovers_each_uncommitted_concurrent_attempt
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      real_patch = ClaudeEasy.method(:patch_path)
      patch_with_commit_conflict = lambda do |path, policy, **options|
        if options.fetch(:dry_run)
          real_patch.call(path, policy, **options)
        else
          {
            status: :concurrent_change, path: path, transaction_commit: false,
            changed: false, dry_run: false
          }
        end
      end

      results = ClaudeEasy.stub(:patch_path, patch_with_commit_conflict) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
          selected_name: "friend", validator: ->(_path) { true }
        )
      end

      assert_equal [:concurrent_change], results.map { |result| result.fetch(:status) }
      assert_equal original.b, File.binread(profile)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_production_probe_normal_batch_rejects_duplicate_file_aliases
    require_production_probe!
    Dir.mktmpdir do |directory|
      profiles = File.join(directory, "profiles")
      FileUtils.mkdir_p(profiles)
      target = File.join(directory, "real.yaml")
      original = YAML.dump(base_config)
      File.write(target, original)
      aliases = %w[a-alias.yaml z-active.yaml].map do |name|
        path = File.join(profiles, name)
        File.link(target, path)
        path
      end
      activations = []

      results = ClaudeEasy.stub(
        :activate_updated_profile,
        lambda { |result, **_options|
          activations << result
          result.merge(reloaded: true)
        }
      ) do
        ClaudeEasy.run(
          directory: profiles, active_directory: profiles, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"), selected_name: "z-active",
          validator: ->(_path) { true }, auto_reload: true, usage_profile: 1
        )
      end

      safely_rejected = !results.all? do |result|
        %i[updated unchanged].include?(result.fetch(:status))
      end
      violations = []
      violations << "accepted duplicate aliases" unless safely_rejected
      violations << "changed the shared target" unless File.binread(target) == original.b
      violations << "activated a duplicate target" unless activations.empty?
      assert_empty violations, violations.join("; ")
      aliases.each { |path| assert_equal original.b, File.binread(path), path }
    end
  end

  def test_production_probe_next_run_recovers_batch_killed_after_first_commit
    require_production_probe!
    Dir.mktmpdir do |directory|
      paths = %w[a-first.yaml z-second.yaml].map do |name|
        path = File.join(directory, name)
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => name)))
        path
      end
      originals = paths.to_h { |path| [path, File.binread(path)] }
      ready_reader, ready_writer = IO.pipe
      gate_reader, gate_writer = IO.pipe
      child_id = nil
      begin
        child_id = fork do
          ready_reader.close
          gate_writer.close
          real_replace = ClaudeEasy.method(:transactional_replace_locked)
          commits = 0
          gated_replace = lambda do |*arguments|
            result = real_replace.call(*arguments)
            commits += 1 if result
            if result && commits == 1
              ready_writer.write(".")
              ready_writer.flush
              gate_reader.read(1)
            end
            result
          end
          ClaudeEasy.stub(:transactional_replace_locked, gated_replace) do
            ClaudeEasy.run(
              directory: directory, policy_path: POLICY_PATH,
              backup_root: File.join(directory, "backups"), selected_name: "none",
              validator: ->(_path) { true }, auto_reload: false, usage_profile: 1
            )
          end
          exit! 0
        end
        ready_writer.close
        gate_reader.close
        assert IO.select([ready_reader], nil, nil, 10), "child never reached the first durable commit"
        ready_reader.read(1)
        Process.kill("KILL", child_id)
        _waited_id, status = Process.wait2(child_id)
        child_id = nil
        assert_equal 9, status.termsig

        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"), selected_name: "none",
          validator: ->(_path) { false }, auto_reload: false, usage_profile: 1
        )
        originals.each do |path, bytes|
          assert File.binread(path) == bytes, "next run did not recover #{File.basename(path)}"
        end
      ensure
        gate_writer.write(".") rescue nil
        Process.kill("KILL", child_id) rescue nil
        Process.waitpid(child_id) rescue nil
        [ready_reader, ready_writer, gate_reader, gate_writer].each { |io| io.close rescue nil }
      end
    end
  end

  def test_next_run_recovers_runtime_killed_after_active_reload
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      runtime_state = File.join(directory, "runtime-state.json")
      gate_seen = File.join(directory, "reload-gated")
      original_config = base_config
      original_config["proxy-groups"].reject! { |group| group["name"] == "AI" }
      original_config["rules"] = ["GEOSITE,CN,DIRECT", "MATCH,Main"]
      original = YAML.dump(original_config)
      File.binwrite(profile, original)
      File.write(runtime_state, JSON.generate("Main" => "Taiwan"))
      ready_reader, ready_writer = IO.pipe
      gate_reader, gate_writer = IO.pipe
      child_id = nil
      provider_name = @policy.fetch("cn_domain_provider").fetch("name")
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          selections = JSON.parse(File.read(runtime_state))
          proxies = selections.to_h do |name, selected|
            [name, {
              "type" => "Selector", "now" => selected,
              "all" => ["Taiwan", "Japan"]
            }]
          end
          [200, JSON.generate("proxies" => proxies)]
        when ["PUT", "/configs?force=true"]
          path = JSON.parse(body).fetch("path")
          config = ClaudeEasy.load_yaml(File.read(path))
          marker = config.fetch("rule-providers", {}).key?(provider_name) ? "candidate" : "original"
          selections = ClaudeEasy.selectable_groups(config).to_h do |group|
            [group.fetch("name"), "Japan"]
          end
          File.write(runtime_state, JSON.generate(selections))
          if marker == "candidate" && !File.exist?(gate_seen)
            File.write(gate_seen, "1")
            ready_writer.write(".")
            ready_writer.flush
            gate_reader.read(1)
          end
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        else
          if method == "PUT" && endpoint.start_with?("/proxies/")
            selections = JSON.parse(File.read(runtime_state))
            group = endpoint.delete_prefix("/proxies/")
            selections[group] = JSON.parse(body).fetch("name")
            File.write(runtime_state, JSON.generate(selections))
            [204, ""]
          elsif method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      begin
        child_id = fork do
          ready_reader.close
          gate_writer.close
          ClaudeEasy.run(
            directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
            selected_name: "active", validator: ->(_path) { true },
            auto_reload: true, requester: requester,
            connectivity_checker: -> { true }, usage_profile: 3
          )
          exit! 0
        end
        ready_writer.close
        gate_reader.close
        assert IO.select([ready_reader], nil, nil, 10), "child never loaded the active candidate"
        ready_reader.read(1)
        Process.kill("KILL", child_id)
        _waited_id, status = Process.wait2(child_id)
        child_id = nil
        assert_equal 9, status.termsig
        candidate_selections = JSON.parse(File.read(runtime_state))
        assert_operator candidate_selections.length, :>, 1
        transaction_path = ClaudeEasy.profile_transaction_path(backup_root)
        validator_called = false

        blocked_results = ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
          selected_name: "active", validator: ->(_path) { validator_called = true; false },
          auto_reload: false, requester: requester,
          connectivity_checker: -> { true }, usage_profile: 3
        )

        assert blocked_results.any? do |result|
          result.fetch(:status) == :reload_failed_restore_pending
        end
        refute validator_called
        assert_equal original.b, File.binread(profile)
        assert_equal candidate_selections, JSON.parse(File.read(runtime_state))
        assert File.exist?(transaction_path)

        controller_requester = lambda do |_socket, method, endpoint, body = nil|
          requester.call(method, endpoint, body)
        end
        results = ClaudeEasy.stub(:runtime_loaded_profile_state, :candidate) do
          ClaudeEasy.stub(:controller_socket, "fixture.sock") do
            ClaudeEasy.stub(:controller_request, controller_requester) do
              ClaudeEasy.run(
                directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
                selected_name: "active", validator: ->(_path) { false },
                auto_reload: true, connectivity_checker: -> { true }, usage_profile: 3
              )
            end
          end
        end

        assert results.any? { |result| result.fetch(:status) == :validation_failed }
        assert_equal original.b, File.binread(profile)
        assert_equal({ "Main" => "Taiwan" }, JSON.parse(File.read(runtime_state)))
      ensure
        gate_writer.write(".") rescue nil
        Process.kill("KILL", child_id) rescue nil
        Process.waitpid(child_id) rescue nil
        [ready_reader, ready_writer, gate_reader, gate_writer].each { |io| io.close rescue nil }
      end
    end
  end

  def test_recovered_runtime_helper_fails_closed_if_active_profile_disappears
    Dir.mktmpdir do |directory|
      requester = lambda do |method, endpoint, _body = nil|
        if [method, endpoint] == ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        else
          flunk "runtime recovery continued after the active profile disappeared"
        end
      end
      work_items = [{ path: File.join(directory, "missing-active.yaml"), active: true }]

      refute ClaudeEasy.reload_recovered_profile_runtime(
        work_items, require_tun: false, requester: requester,
        connectivity_checker: -> { true }
      )
    end
  end

  def test_recovered_runtime_accepts_the_original_dns_limit_when_connectivity_is_restored
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        when ["PUT", "/configs?force=true"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.include?("www.baidu.com")
            [500, JSON.generate("message" => "dns resolve failed")]
          else
            raise "unexpected controller request: #{method} #{endpoint}"
          end
        end
      end

      assert ClaudeEasy.reload_recovered_profile_runtime(
        [{ path: profile, active: true }], require_tun: :preserve,
        requester: requester, connectivity_checker: -> { true }
      )
    end
  end

  def test_profile_transaction_records_the_pre_reload_runtime_checkpoint
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "new"))
      File.binwrite(profile, original)
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "Taiwan" }
      }

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.prepare_profile_transaction(
          [{ path: profile, original: original, candidate: candidate }],
          backup_root, roots: [directory], runtime_checkpoint: checkpoint.merge(extra: true)
        )
      end

      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        backup_root, roots: [directory], runtime_checkpoint: checkpoint
      )
      state = JSON.parse(transaction.fetch(:bytes))
      recovered = ClaudeEasy.recover_profile_transaction(
        backup_root, roots: [directory], keep_transaction: true
      )

      assert_equal 4, state.fetch("Version")
      assert_equal checkpoint, recovered.fetch(:runtime_checkpoint)
    end
  end

  def test_profile_transaction_rejects_a_missing_version_four_runtime_checkpoint
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "new"))
      File.binwrite(profile, original)
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "Taiwan" }
      }
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        backup_root, roots: [directory], runtime_checkpoint: checkpoint
      )
      transaction_path = ClaudeEasy.profile_transaction_path(backup_root)
      state = JSON.parse(File.binread(transaction_path))
      state.delete("Runtime")
      File.binwrite(transaction_path, JSON.generate(state))

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.recover_profile_transaction(
          backup_root, roots: [directory], keep_transaction: true
        )
      end
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_runtime_recovery_uses_the_durable_checkpoint_instead_of_damaged_live_state
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      selected = "Japan"
      tun_enabled = false
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => {
              "type" => "Selector", "now" => selected,
              "all" => ["Taiwan", "Japan"]
            }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => tun_enabled })]
        when ["PUT", "/configs?force=true"]
          selected = "Japan"
          tun_enabled = false
          [204, ""]
        when ["PUT", "/proxies/Main"]
          selected = JSON.parse(body).fetch("name")
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          raise "unexpected controller request: #{method} #{endpoint}"
        end
      end
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "Taiwan" }
      }

      restored = ClaudeEasy.reload_recovered_profile_runtime(
        [{ path: profile, active: true }], require_tun: :preserve,
        requester: requester, connectivity_checker: -> { true },
        runtime_checkpoint: checkpoint
      )

      refute restored
      assert_equal "Japan", selected
      refute tun_enabled
    end
  end

  def test_failed_pending_runtime_recovery_keeps_transaction_and_skips_new_patch
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      preview = ClaudeEasy.patch_path(
        profile, @policy, dry_run: true, validator: ->(_path) { true },
        usage_profile: 1, capture_transaction: true
      )
      candidate = preview.fetch(:transaction_candidate)
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original.b, candidate: candidate }],
        backup_root, roots: [directory]
      )
      File.binwrite(profile, candidate)
      transaction_path = ClaudeEasy.profile_transaction_path(backup_root)
      validator_called = false
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" },
            "ClaudeEasy AI" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["PUT", "/configs?force=true"]
          [503, ""]
        else
          [404, ""]
        end
      end

      results = ClaudeEasy.run(
        directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
        selected_name: "active", validator: ->(_path) { validator_called = true; true },
        auto_reload: true, requester: requester,
        connectivity_checker: -> { true }, usage_profile: 1
      )

      assert results.any? { |result| result.fetch(:status) == :reload_failed_restore_pending }
      assert_equal original.b, File.binread(profile)
      assert File.exist?(transaction_path)
      refute validator_called
    end
  end

  def test_pending_runtime_recovery_does_not_reload_a_profile_the_user_left
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      other = File.join(directory, "other.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.binwrite(profile, original)
      File.binwrite(other, YAML.dump(base_config.merge("subscription-marker" => "other")))
      preview = ClaudeEasy.patch_path(
        profile, @policy, dry_run: true, validator: ->(_path) { true },
        usage_profile: 1, capture_transaction: true
      )
      candidate = preview.fetch(:transaction_candidate)
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original.b, candidate: candidate }],
        backup_root, roots: [directory]
      )
      File.binwrite(profile, candidate)
      selected = "active"
      put_paths = []
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          selected = "other"
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        when ["PUT", "/configs?force=true"]
          put_paths << JSON.parse(body).fetch("path")
          [204, ""]
        else
          [204, ""]
        end
      end
      validator_called = false

      results = ClaudeEasy.stub(:selected_profile_name, -> { selected }) do
        ClaudeEasy.stub(:storage_mode, :local) do
          ClaudeEasy.run(
            directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
            validator: ->(_path) { validator_called = true; true },
            auto_reload: true, requester: requester,
            connectivity_checker: -> { true }, usage_profile: 1
          )
        end
      end

      assert_empty put_paths, "runtime recovery forced the profile the user had left"
      assert_equal original.b, File.binread(profile)
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
      refute validator_called
      assert results.any? { |result| result.fetch(:status) == :reload_failed_restore_pending }
    end
  end

  def test_pending_runtime_recovery_keeps_the_journal_when_the_active_profile_is_missing
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, original)
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        backup_root, roots: [directory]
      )
      File.binwrite(profile, candidate)

      result = ClaudeEasy.stub(:selected_profile_name, "missing-profile") do
        ClaudeEasy.recover_pending_profile_transaction(
          backup_root, directories: [directory]
        )
      end

      assert_equal :runtime_restore_pending, result
      assert_equal candidate.b, File.binread(profile)
      assert File.file?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_production_probe_next_safe_update_recovers_batch_killed_after_first_descriptor_commit
    require_production_probe!
    Dir.mktmpdir do |directory|
      paths = %w[a-first z-second].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        path
      end
      targets = paths.map do |path|
        name = File.basename(path, ".yaml")
        { name: name, path: path, url: "https://fixture.invalid/#{name}" }
      end
      originals = paths.to_h { |path| [path, File.binread(path)] }
      ready_reader, ready_writer = IO.pipe
      gate_reader, gate_writer = IO.pipe
      child_id = nil
      begin
        child_id = fork do
          ready_reader.close
          gate_writer.close
          real_write = ClaudeEasy.method(:transactional_replace_locked)
          writes = 0
          gated_write = lambda do |*arguments|
            result = real_write.call(*arguments)
            writes += 1 if result
            if result && writes == 1
              ready_writer.write(".")
              ready_writer.flush
              gate_reader.read(1)
            end
            result
          end
          ClaudeEasy.stub(:transactional_replace_locked, gated_write) do
            ClaudeEasy.safe_update_all(
              targets: targets, policy: @policy,
              backup_root: File.join(directory, "backups"), usage_profile: 1,
              fetcher: lambda { |target|
                YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}"))
              },
              validator: ->(_path) { true }, activation: ->(_items) { true },
              selected_name: "a-first"
            )
          end
          exit! 0
        end
        ready_writer.close
        gate_reader.close
        assert IO.select([ready_reader], nil, nil, 10),
               "child never reached the first safe-update descriptor commit"
        ready_reader.read(1)
        Process.kill("KILL", child_id)
        Process.waitpid(child_id)
        child_id = nil

        ClaudeEasy.safe_update_all(
          targets: targets, policy: @policy,
          backup_root: File.join(directory, "backups"), usage_profile: 1,
          fetcher: ->(_target) { raise IOError, "injected preflight failure" },
          validator: ->(_path) { true }, activation: ->(_items) { true },
          selected_name: "a-first"
        )
        originals.each do |path, bytes|
          assert File.binread(path) == bytes, "next safe-update entry did not recover #{File.basename(path)}"
        end
      ensure
        gate_writer.write(".") rescue nil
        Process.kill("KILL", child_id) rescue nil
        Process.waitpid(child_id) rescue nil
        [ready_reader, ready_writer, gate_reader, gate_writer].each { |io| io.close rescue nil }
      end
    end
  end

  def test_production_probe_mihomo_does_not_survive_a_killed_validator
    require_production_probe!
    Dir.mktmpdir do |directory|
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.local_address.ip_port
      core = File.join(directory, "mihomo")
      File.write(core, <<~RUBY)
        #!#{RbConfig.ruby}
        require "socket"
        socket = TCPSocket.new("127.0.0.1", ENV.fetch("CLAUDE_EASY_READY_PORT").to_i)
        socket.puts(Process.pid)
        socket.close
        sleep 60
      RUBY
      File.chmod(0o700, core)
      worker_id = nil
      core_id = nil
      connection = nil
      core_alive = nil
      leftovers = nil
      begin
        worker_id = fork do
          ENV["CLAUDE_EASY_READY_PORT"] = port.to_s
          ENV["TMPDIR"] = directory
          ClaudeEasy.mihomo_core_status(core, timeout_seconds: 30)
          exit! 0
        end
        assert IO.select([listener], nil, nil, 10), "fake Mihomo never started"
        connection = listener.accept
        core_id = Integer(connection.gets)
        Process.kill("KILL", worker_id)
        Process.waitpid(worker_id)
        worker_id = nil

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        loop do
          core_alive = begin
            Process.kill(0, core_id)
            true
          rescue Errno::ESRCH
            false
          end
          leftovers = Dir.glob(File.join(directory, "claude-easy-command*"))
          break if !core_alive && leftovers.empty?
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.02
        end
      ensure
        Process.kill("KILL", worker_id) rescue nil
        Process.waitpid(worker_id) rescue nil
        if fixture_process?(core_id, core)
          Process.kill("KILL", -core_id) rescue nil
          Process.kill("KILL", core_id) rescue nil
        end
        connection&.close rescue nil
        listener.close rescue nil
        Dir.glob(File.join(directory, "claude-easy-command*")).each { |path| FileUtils.rm_f(path) }
      end

      violations = []
      violations << "Mihomo child survived" if core_alive
      violations << "command output tempfile remained" unless leftovers.empty?
      assert_empty violations, violations.join("; ")
    end
  end

  def test_common_china_domain_baseline_applies_to_lightweight_profiles
    original = base_config
    original["ipv6"] = true
    original["tun"] = { "enable" => false }
    original["dns"]["nameserver-policy"]["geosite:cn"] = ["system"]

    [1, 2].each do |usage_profile|
      patched = ClaudeEasy.patch(original, @policy, usage_profile: usage_profile).fetch(:config)
      provider_name = @policy.fetch("cn_domain_provider").fetch("name")
      provider = patched.fetch("rule-providers").fetch(provider_name)

      assert_equal "http", provider.fetch("type")
      assert_equal "domain", provider.fetch("behavior")
      assert_equal "mrs", provider.fetch("format")
      assert_equal @policy.fetch("cn_domain_provider").fetch("url"), provider.fetch("url")
      assert_equal "Main", provider.fetch("proxy")
      assert_equal @policy.fetch("direct_resolvers"),
                   patched.dig("dns", "nameserver-policy", "rule-set:#{provider_name}")
      assert_equal @policy.fetch("direct_resolvers"),
                   patched.dig("dns", "nameserver-policy", "geosite:cn")
      cn_index = patched.fetch("rules").index("RULE-SET,#{provider_name},DIRECT")
      broad_index = patched.fetch("rules").index("GEOSITE,CN,DIRECT")
      assert_operator cn_index, :<, broad_index
      assert_equal true, patched.fetch("ipv6")
      assert_equal({ "enable" => false }, patched.fetch("tun"))
      refute patched.fetch("rules").any? { |rule| rule.include?("NETWORK,UDP") }
      refute_includes patched.fetch("rules"), @policy.fetch("cn_udp_direct_rule")
      refute patched.fetch("rule-providers").key?(@policy.fetch("cn_ip_provider").fetch("name"))
      assert_equal patched, ClaudeEasy.patch(patched, @policy, usage_profile: usage_profile).fetch(:config)
    end
  end

  def test_common_china_domain_baseline_does_not_overwrite_user_provider_name
    config = base_config
    base_name = @policy.fetch("cn_domain_provider").fetch("name")
    config["rule-providers"] = {
      base_name => { "type" => "file", "behavior" => "domain", "path" => "./user-owned.yaml" }
    }

    patched = ClaudeEasy.patch(config, @policy, usage_profile: 1).fetch(:config)

    assert_equal "./user-owned.yaml", patched.fetch("rule-providers").fetch(base_name).fetch("path")
    assert patched.fetch("rule-providers").key?("#{base_name}-2")
    assert_includes patched.fetch("rules"), "RULE-SET,#{base_name}-2,DIRECT"
  end

  def test_china_ip_udp_provider_does_not_overwrite_a_user_provider
    config = base_config
    provider_name = @policy.fetch("cn_ip_provider").fetch("name")
    user_provider = { "type" => "file", "behavior" => "ipcidr", "path" => "./user/cn-ip.yaml" }
    config["rule-providers"] = { provider_name => user_provider }

    result = ClaudeEasy.patch(config, @policy)
    patched = result.fetch(:config)
    managed_name = "#{provider_name}-2"

    assert_equal user_provider, patched.fetch("rule-providers").fetch(provider_name)
    assert_equal "ipcidr", patched.fetch("rule-providers").fetch(managed_name).fetch("behavior")
    assert_includes patched.fetch("rules"), ClaudeEasy.render_cn_udp_direct_rule(@policy, managed_name)
    refute ClaudeEasy.patch(patched, @policy).fetch(:changed)
  end

  def test_common_china_domain_baseline_does_not_reuse_user_provider_path
    config = base_config
    provider_policy = @policy.fetch("cn_domain_provider")
    base_name = provider_policy.fetch("name")
    config["rule-providers"] = {
      "user-cn" => { "type" => "file", "behavior" => "domain", "path" => provider_policy.fetch("path") }
    }

    patched = ClaudeEasy.patch(config, @policy, usage_profile: 1).fetch(:config)

    assert_equal provider_policy.fetch("path"), patched.fetch("rule-providers").fetch("user-cn").fetch("path")
    assert_equal "./ruleset/#{base_name}-2.mrs",
                 patched.fetch("rule-providers").fetch("#{base_name}-2").fetch("path")
    assert_includes patched.fetch("rules"), "RULE-SET,#{base_name}-2,DIRECT"
  end

  def test_common_china_domain_baseline_normalizes_mihomo_home_paths_before_cache_collision_check
    provider_policy = @policy.fetch("cn_domain_provider")
    base_name = provider_policy.fetch("name")
    equivalent_paths = [
      "ruleset/#{base_name}.mrs",
      "./ruleset/sub/../#{base_name}.mrs",
      File.join(Dir.home, ".config", "clash.meta", "ruleset", "#{base_name}.mrs")
    ]

    equivalent_paths.each do |path|
      config = base_config
      config["rule-providers"] = {
        "user-cn" => { "type" => "file", "behavior" => "domain", "path" => path }
      }

      patched = ClaudeEasy.patch(config, @policy, usage_profile: 1).fetch(:config)

      assert_equal path, patched.fetch("rule-providers").fetch("user-cn").fetch("path")
      refute patched.fetch("rule-providers").key?(base_name)
      assert_equal "./ruleset/#{base_name}-2.mrs",
                   patched.fetch("rule-providers").fetch("#{base_name}-2").fetch("path")
    end


    config = base_config
    invalid_path = "ruleset/invalid\0#{base_name}.mrs"
    config["rule-providers"] = {
      "user-cn" => { "type" => "file", "behavior" => "domain", "path" => invalid_path }
    }
    patched = ClaudeEasy.patch(config, @policy, usage_profile: 1).fetch(:config)
    assert_equal invalid_path, patched.fetch("rule-providers").fetch("user-cn").fetch("path")
    assert patched.fetch("rule-providers").key?(base_name)
  end

  def test_common_china_domain_baseline_respects_mihomo_home_volume_case_sensitivity
    provider_policy = @policy.fetch("cn_domain_provider")
    base_name = provider_policy.fetch("name")
    path = "./RULESET/#{base_name.upcase}.MRS"
    config = base_config
    config["rule-providers"] = {
      "user-cn" => { "type" => "file", "behavior" => "domain", "path" => path }
    }

    patched = ClaudeEasy.patch(config, @policy, usage_profile: 1).fetch(:config)

    if ClaudeEasy.mihomo_home_case_insensitive?
      refute patched.fetch("rule-providers").key?(base_name)
      assert_equal "./ruleset/#{base_name}-2.mrs",
                   patched.fetch("rule-providers").fetch("#{base_name}-2").fetch("path")
    else
      assert_equal provider_policy.fetch("path"), patched.fetch("rule-providers").fetch(base_name).fetch("path")
      refute patched.fetch("rule-providers").key?("#{base_name}-2")
    end
  end

  def test_common_china_domain_baseline_normalizes_unicode_provider_cache_paths
    policy = Marshal.load(Marshal.dump(@policy))
    provider_policy = policy.fetch("cn_domain_provider")
    base_name = provider_policy.fetch("name")
    provider_policy["path"] = "./ruleset/caf\u00E9.mrs"
    decomposed_path = "./ruleset/cafe\u0301.mrs"
    config = base_config
    config["rule-providers"] = {
      "user-cn" => { "type" => "file", "behavior" => "domain", "path" => decomposed_path }
    }

    patched = ClaudeEasy.patch(config, policy, usage_profile: 1).fetch(:config)

    assert_equal decomposed_path, patched.fetch("rule-providers").fetch("user-cn").fetch("path")
    refute patched.fetch("rule-providers").key?(base_name)
    assert_equal "./ruleset/caf\u00E9-2.mrs",
                 patched.fetch("rule-providers").fetch("#{base_name}-2").fetch("path")
  end

  def test_result_contract_rejects_unstable_command_names
    assert_raises(ArgumentError) do
      ClaudeEasyResult.build(
        command: "patch_profiles.rb", operation: "test", ok: true, status: "ok",
        code: "ok", exit_code: 0, summary_zh: "完成"
      )
    end
  end

  def test_result_contract_cli_emits_valid_json_and_rejects_bad_arguments
    output, error = capture_io do
      assert_equal 0, ClaudeEasyResult.cli(%w[
        --command patch --operation test --ok true --status ok --code completed
        --exit-code 0 --summary 完成 --profile 3 --message done --warning check
      ])
    end
    assert_empty error
    result = JSON.parse(output)
    assert_equal "patch", result.fetch("command")
    assert_equal 3, result.fetch("profile")
    assert_equal ["done"], result.fetch("messages")
    assert_equal ["check"], result.fetch("warnings")

    output, error = capture_io do
      assert_equal 0, ClaudeEasyResult.cli(%w[
        --command patch --operation safe_update --ok true --status ok
        --code safe_update_completed --exit-code 0 --summary 完成
        --workflow-complete false --completed-scope subscription_update
        --required-followup route_verification --required-followup final_state_audit
      ])
    end
    assert_empty error
    result = JSON.parse(output)
    assert_equal false, result.fetch("workflow_complete")
    assert_equal "subscription_update", result.fetch("completed_scope")
    assert_equal %w[route_verification final_state_audit], result.fetch("required_followups")

    output, error = capture_io do
      assert_equal 0, ClaudeEasyResult.cli(%w[
        --command patch --operation test --ok true --status ok --code completed
        --exit-code 0 --summary 完成 --profile 4
      ])
    end
    assert_empty error
    assert_nil JSON.parse(output).fetch("profile")

    output, error = capture_io do
      assert_equal 64, ClaudeEasyResult.cli(%w[--command unknown])
    end
    assert_empty error
    result = JSON.parse(output)
    assert_equal "patch", result.fetch("command")
    assert_equal "invalid_request", result.fetch("status")
  end

  def test_result_contract_executable_emits_the_cli_result
    output, error, status = capture_ruby_entrypoint(
      RESULT_CONTRACT_PATH,
      "--command", "patch", "--operation", "entrypoint", "--ok", "true",
      "--status", "ok", "--code", "completed", "--exit-code", "0", "--summary", "完成"
    )

    assert status.success?, error
    assert_empty error
    result = JSON.parse(output)
    assert_equal "entrypoint", result.fetch("operation")
    assert_equal status.exitstatus, result.fetch("exit_code")
  end

  def test_result_contract_normalizes_unknown_status_and_value_types
    result = ClaudeEasyResult.build(
      command: :install, operation: :test, ok: false, status: :unknown, code: :failed,
      exit_code: "1", summary_zh: "完成", changes: [nil, true, 3, :symbol]
    )
    assert_equal "failed", result.fetch("status")
    assert_equal 1, result.fetch("exit_code")
    assert_equal [nil, true, 3, "symbol"], result.fetch("changes")
  end

  def test_result_contract_has_required_fields_and_recursively_redacts_sensitive_text
    output = StringIO.new
    ClaudeEasyResult.write(
      output: output, command: "patch", operation: "test", ok: true, status: "ok", code: "ok",
      exit_code: 0, summary_zh: "password=private https://secret.invalid /Users/private/config.yaml",
      checks: [{ "detail" => "uuid=11111111-2222-3333-4444-555555555555" }]
    )

    result = JSON.parse(output.string)
    assert_equal %w[
      schema version command platform client operation ok status code exit_code summary_zh
      profile changes checks items messages warnings
    ].sort, result.keys.sort
    refute_includes output.string, "private"
    refute_includes output.string, "secret.invalid"
    refute_includes output.string, "11111111-2222-3333-4444-555555555555"
    assert ClaudeEasyResult.valid_child_json?(output.string)
    refute ClaudeEasyResult.valid_child_json?('{"items":[')
    refute ClaudeEasyResult.valid_child_json?(JSON.generate(result.reject { |key, _| key == "checks" }))
    refute ClaudeEasyResult.valid_child_json?(JSON.generate(result.merge("items" => [{ "status" => "verified" }])))
  end

  def test_result_contract_preserves_incomplete_workflow_metadata
    result = ClaudeEasyResult.build(
      command: "install", operation: "safe_update", ok: true, status: "ok",
      code: "safe_update_completed", exit_code: 0,
      summary_zh: "订阅事务完成，后续检查尚未完成。", profile: 3,
      workflow_complete: false, completed_scope: "subscription_update",
      required_followups: %w[
        client_switch_verification site_verification agent_connectivity_verification
        route_verification dns_deep_test webrtc_test local_region_fingerprint_test
        final_state_audit
      ]
    )

    assert_equal false, result.fetch("workflow_complete")
    assert_equal "subscription_update", result.fetch("completed_scope")
    assert_equal 8, result.fetch("required_followups").length
    assert ClaudeEasyResult.valid_child_json?(JSON.generate(result))
    refute ClaudeEasyResult.valid_child_json?(JSON.generate(result.merge("workflow_complete" => "false")))
  end

  def test_result_contract_rejects_safe_update_success_without_workflow_metadata
    common = {
      command: "install", operation: "safe_update", ok: true, status: "ok",
      exit_code: 0, summary_zh: "订阅事务完成。", profile: 3
    }

    %w[safe_update_completed safe_update_verified].each do |code|
      assert_raises(ArgumentError) do
        ClaudeEasyResult.build(**common, code: code)
      end

      legacy = ClaudeEasyResult.build(**common, code: "completed").merge("code" => code)
      refute ClaudeEasyResult.valid_child_json?(JSON.generate(legacy))
    end

    [
      { workflow_complete: true, completed_scope: "subscription_update", required_followups: ["final_state_audit"] },
      { workflow_complete: false, completed_scope: "wrong_scope", required_followups: ["final_state_audit"] },
      { workflow_complete: false, completed_scope: "subscription_update", required_followups: [] }
    ].each do |invalid_workflow|
      assert_raises(ArgumentError) do
        ClaudeEasyResult.build(**common, code: "safe_update_completed", **invalid_workflow)
      end
    end
  end

  def test_result_contract_requires_snapshot_followups_for_windows_style_snapshot_operation
    common = {
      command: "install", operation: "snapshot_profiles", ok: true, status: "ok",
      code: "snapshot_created", exit_code: 0, summary_zh: "已创建快照。", profile: 3
    }

    assert_raises(ArgumentError) { ClaudeEasyResult.build(**common) }
    legacy = ClaudeEasyResult.build(**common.merge(operation: "snapshot_initial"))
      .merge("operation" => "snapshot_profiles")
    refute ClaudeEasyResult.valid_child_json?(JSON.generate(legacy))
    result = ClaudeEasyResult.build(
      **common, workflow_complete: false, completed_scope: "subscription_snapshot",
      required_followups: ["region_fingerprint_baseline", "subscription_refresh"]
    )
    assert ClaudeEasyResult.valid_child_json?(JSON.generate(result))
  end

  def test_result_contract_rejects_workflow_text_that_sanitizes_to_empty
    common = {
      command: "install", operation: "safe_update", ok: true, status: "ok",
      code: "safe_update_completed", exit_code: 0, summary_zh: "订阅事务完成。",
      workflow_complete: false
    }

    assert_raises(ArgumentError) do
      ClaudeEasyResult.build(
        **common, completed_scope: " \e[31m ", required_followups: ["final_state_audit"]
      )
    end
    assert_raises(ArgumentError) do
      ClaudeEasyResult.build(
        **common, completed_scope: "subscription_update", required_followups: [" \u200E "]
      )
    end

    valid = ClaudeEasyResult.build(
      **common, completed_scope: "subscription_update",
      required_followups: ["final_state_audit"]
    )
    refute ClaudeEasyResult.valid_child_json?(
      JSON.generate(valid.merge("completed_scope" => " \e[31m "))
    )
    refute ClaudeEasyResult.valid_child_json?(
      JSON.generate(valid.merge("required_followups" => [" \u200E "]))
    )
  end

  def test_result_contract_cli_merges_child_workflow_metadata
    child = ClaudeEasyResult.build(
      command: "patch", operation: "safe_update", ok: true, status: "ok",
      code: "safe_update_completed", exit_code: 0, summary_zh: "订阅事务完成。",
      workflow_complete: false, completed_scope: "subscription_update",
      required_followups: %w[route_verification final_state_audit]
    )
    output, error, status = Open3.capture3(
      "/usr/bin/ruby", RESULT_CONTRACT_PATH,
      "--command", "install", "--operation", "safe_update", "--ok", "true",
      "--status", "ok", "--code", "safe_update_completed", "--exit-code", "0",
      "--summary", "订阅事务完成，后续检查尚未完成。", "--merge-child-stdin",
      stdin_data: JSON.generate(child)
    )

    assert status.success?, error
    result = JSON.parse(output)
    assert_equal false, result.fetch("workflow_complete")
    assert_equal "subscription_update", result.fetch("completed_scope")
    assert_equal %w[route_verification final_state_audit], result.fetch("required_followups")
  end

  def test_result_contract_redacts_a_uuid_next_to_unicode_text
    output = ClaudeEasyResult.sanitize_text(
      "已更新：11111111-2222-3333-4444-555555555555配置"
    )

    refute_includes output, "11111111-2222-3333-4444-555555555555"
  end

  def test_result_contract_redacts_sensitive_shapes_next_to_unicode_text
    output = ClaudeEasyResult.sanitize_text(
      "错误token=private结束 错误Bearer private结束 错误https://secret.invalid/path结束"
    )

    refute_includes output, "private"
    refute_includes output, "secret.invalid"
    refute_match(/Bearer\s+/i, output)
    refute_match(/token\s*[:=]/i, output)
  end

  def test_patcher_json_mode_emits_one_redacted_contract_object
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      config = base_config
      config["proxies"].first["name"] = "PRIVATE-NODE-NAME"
      File.write(profile, YAML.dump(config))

      output, error, status = capture_ruby_entrypoint(
        PATCHER_PATH, "--json", "--profile-dir", directory,
        "--usage-profile", "1", "--dry-run"
      )

      assert status.success?, error
      assert_empty error
      result = JSON.parse(output)
      assert_equal "claude-easy.result", result.fetch("schema")
      assert_equal status.exitstatus, result.fetch("exit_code")
      assert_equal "patch", result.fetch("command")
      assert_equal "macos", result.fetch("platform")
      assert_equal "clashx-meta", result.fetch("client")
      refute_includes output, directory
      refute_includes output, "PRIVATE-NODE-NAME"
      refute_includes output, "fixture-secret"
    end
  end

  def test_patcher_json_mode_structures_argument_errors_regardless_of_argument_order
    output, error, status = capture_ruby_entrypoint(PATCHER_PATH, "--unknown", "--json")

    assert_equal 64, status.exitstatus
    assert_empty error
    result = JSON.parse(output)
    assert_equal "invalid_request", result.fetch("status")
    assert_equal 64, result.fetch("exit_code")
  end

  def test_json_mode_reports_an_incomplete_ruby_package_as_one_object
    Dir.mktmpdir do |directory|
      patcher_dir = File.join(directory, "patcher")
      verifier_dir = File.join(directory, "verifier")
      FileUtils.mkdir_p([patcher_dir, verifier_dir])
      patcher = File.join(patcher_dir, "patch_profiles.rb")
      verifier = File.join(verifier_dir, "verify_routes.rb")
      FileUtils.cp(PATCHER_PATH, patcher)
      FileUtils.cp(ROUTE_VERIFIER_PATH, verifier)

      [[patcher, "patch"], [verifier, "verify_routes"]].each do |path, command|
        output, error, status = capture_ruby_entrypoint(path, "--json")
        assert_equal 6, status.exitstatus
        assert_empty error
        result = JSON.parse(output)
        assert_equal command, result.fetch("command")
        assert_equal "incomplete_package", result.fetch("code")
        assert_equal status.exitstatus, result.fetch("exit_code")
      end
    end
  end

  def test_ruby_bootstrap_fails_closed_in_json_and_text_modes
    [[ClaudeEasyBootstrap, "patch"], [ClashRouteBootstrap, "verify_routes"]].each do |bootstrap, command|
      [LoadError, SyntaxError].each do |error_class|
        json_output = StringIO.new
        loaded = bootstrap.load_dependencies(
          loader: ->(_path) { raise error_class, "/private/path/fixture" },
          argv: ["--json"], output: json_output
        )
        refute loaded
        result = JSON.parse(json_output.string)
        assert_equal command, result.fetch("command")
        assert_equal "incomplete_package", result.fetch("code")
        assert_equal 6, result.fetch("exit_code")
        refute_includes json_output.string, "/private/path"

        text_output = StringIO.new
        refute bootstrap.load_dependencies(
          loader: ->(_path) { raise error_class, "/private/path/fixture" },
          argv: [], output: text_output
        )
        assert_equal "安装包不完整。\n", text_output.string
      end
    end
  end

  def test_route_verifier_owns_nested_patcher_dependency_failures
    Dir.mktmpdir do |directory|
      macos = File.join(directory, "macos")
      FileUtils.cp_r(File.join(ROOT, "claude-easy/scripts/macos"), macos)
      File.binwrite(
        File.join(macos, "patch_profiles", "transform.rb"),
        "broken (\n"
      )
      verifier = File.join(macos, "verify_routes.rb")

      output, error, status = capture_ruby_entrypoint(verifier, "--json")
      assert_equal 6, status.exitstatus
      assert_empty error
      result = JSON.parse(output)
      assert_equal "verify_routes", result.fetch("command")
      assert_equal "incomplete_package", result.fetch("code")
      assert_equal 1, output.lines.length

      output, error, status = capture_ruby_entrypoint(verifier)
      assert_equal 6, status.exitstatus
      assert_empty error
      assert_equal "安装包不完整。\n", output
    end
  end

  def test_route_verifier_json_mode_emits_one_contract_object_on_business_failure
    output = StringIO.new
    ClashRouteVerifier.stub(:run, false) do
      assert_equal 1, ClashRouteVerifier.cli(["--json"], output: output, profile_reader: -> { 3 })
    end

    result = JSON.parse(output.string)
    assert_equal "verify_routes", result.fetch("command")
    assert_equal "failed", result.fetch("status")
    assert_equal 1, result.fetch("exit_code")
    assert_equal 3, result.fetch("profile")
    refute_includes output.string, Dir.home
    output = StringIO.new
    ClashRouteVerifier.stub(:run, false) do
      assert_equal 1, ClashRouteVerifier.cli([], output: output, profile_reader: -> { 3 })
    end
    assert_equal "实时分流验证未通过。\n", output.string
  end

  def test_route_verifier_cli_json_does_not_forward_human_output
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(output:, details:, **_options) { output.puts("PRIVATE-NODE"); details[:checks] << { "name" => "google", "ok" => true, "status" => "passed" }; true }) do
      assert_equal 0, ClashRouteVerifier.cli(["--json"], output: output, profile_reader: -> { 3 })
    end

    result = JSON.parse(output.string)
    assert_equal "ok", result.fetch("status")
    assert_equal(
      [{ "name" => "google", "ok" => true, "status" => "passed" }],
      result.fetch("checks")
    )
    refute_includes output.string, "PRIVATE-NODE"
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(output:, details:, **_options) { output.puts("中文结果"); false }) do
      assert_equal 1, ClashRouteVerifier.cli([], output: output, profile_reader: -> { 3 })
    end
    assert_equal "中文结果\n实时分流验证未通过。\n", output.string
  end

  def test_route_verifier_cli_accepts_cross_platform_group_and_observation_options
    output = StringIO.new
    received = nil
    runner = lambda do |output:, details:, main_group:, ai_group:, observation_seconds:|
      received = [main_group, ai_group, observation_seconds]
      details[:checks] << { "name" => "google", "ok" => true, "status" => "passed" }
      true
    end
    ClashRouteVerifier.stub(:run, runner) do
      assert_equal(
        0,
        ClashRouteVerifier.cli(
          ["--main-group", "Main Live", "--ai-group", "AI Live",
           "--observation-seconds", "21", "--json"],
          output: output, profile_reader: -> { 3 }
        )
      )
    end

    assert_equal ["Main Live", "AI Live", 21], received
    result = JSON.parse(output.string)
    assert_equal "routes_verified", result.fetch("code")
    assert_equal 3, result.fetch("profile")
  end

  def test_route_verifier_cli_rejects_an_invalid_observation_window
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(**) { flunk "invalid window reached route verification" }) do
      assert_equal(
        64,
        ClashRouteVerifier.cli(["--observation-seconds", "0", "--json"], output: output)
      )
    end
    result = JSON.parse(output.string)
    assert_equal "invalid_request", result.fetch("status")
    assert_equal "invalid_arguments", result.fetch("code")
  end

  def test_route_verifier_cli_returns_structured_json_help
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(**) { flunk "help reached route verification" }) do
      assert_equal 0, ClashRouteVerifier.cli(["--help", "--json"], output: output)
    end

    result = JSON.parse(output.string)
    assert_equal "ok", result.fetch("status")
    assert_equal "help", result.fetch("code")
    assert_equal 0, result.fetch("exit_code")
  end

  def test_route_verifier_cli_rejects_a_blank_group_name
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(**) { flunk "blank group reached route verification" }) do
      assert_equal 64, ClashRouteVerifier.cli(["--main-group=", "--json"], output: output)
    end
    assert_equal "invalid_arguments", JSON.parse(output.string).fetch("code")

    whitespace_output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(**) { flunk "whitespace group reached route verification" }) do
      assert_equal(
        64,
        ClashRouteVerifier.cli(["--ai-group", "  ", "--json"], output: whitespace_output)
      )
    end
    assert_equal "invalid_arguments", JSON.parse(whitespace_output.string).fetch("code")
  end

  def test_route_verifier_rejects_unknown_arguments_before_running
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(**) { flunk "invalid arguments reached route verification" }) do
      assert_equal 64, ClashRouteVerifier.cli(["--typo", "--json"], output: output)
    end
    result = JSON.parse(output.string)
    assert_equal "invalid_request", result.fetch("status")
    assert_equal "invalid_arguments", result.fetch("code")
  end

  def test_route_verifier_reports_human_parameter_errors
    [["--observation-seconds", "abc"], ["--observation-seconds", "0"], ["--typo"]].each do |arguments|
      output = StringIO.new
      ClashRouteVerifier.stub(:run, ->(**) { flunk "invalid arguments reached route verification" }) do
        assert_equal 64, ClashRouteVerifier.cli(arguments, output: output)
      end
      assert_equal "参数错误。\n", output.string
    end
  end

  def test_route_verifier_refuses_ai_probes_below_profile_three
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(**) { flunk "profile 1 reached route verification" }) do
      assert_equal 10, ClashRouteVerifier.cli(
        ["--json"], output: output, profile_reader: -> { 1 }
      )
    end
    result = JSON.parse(output.string)
    assert_equal "invalid_request", result.fetch("status")
    assert_equal "usage_profile_mismatch", result.fetch("code")
    assert_equal 1, result.fetch("profile")
    assert_empty result.fetch("checks")
  end

  def test_route_verifier_reports_unset_invalid_and_human_profile_gates
    unset_output = StringIO.new
    assert_equal 10, ClashRouteVerifier.cli(
      ["--json"], output: unset_output, profile_reader: -> { nil }
    )
    unset_result = JSON.parse(unset_output.string)
    assert_equal "usage_profile_unset", unset_result.fetch("code")
    assert_nil unset_result.fetch("profile")

    invalid_output = StringIO.new
    assert_equal 10, ClashRouteVerifier.cli(
      ["--json"], output: invalid_output,
      profile_reader: -> { raise ClaudeEasy::InvalidConfigError }
    )
    invalid_result = JSON.parse(invalid_output.string)
    assert_equal "usage_profile_invalid", invalid_result.fetch("code")
    assert_nil invalid_result.fetch("profile")

    human_output = StringIO.new
    assert_equal 10, ClashRouteVerifier.cli([], output: human_output, profile_reader: -> { 2 })
    assert_includes human_output.string, "档位 3"
  end

  def test_route_target_patterns_require_real_domain_boundaries
    patterns = ClashRouteVerifier::TARGETS.to_h { |label, _url, _kind, pattern| [label, pattern] }

    assert_match patterns.fetch("ChatGPT"), "chatgpt.com"
    refute_match patterns.fetch("ChatGPT"), "notchatgpt.com"
    refute_match patterns.fetch("ChatGPT"), "chatgpt.com.attacker.invalid"
    assert_match patterns.fetch("Gemini"), "gemini.google.com"
    refute_match patterns.fetch("Gemini"), "notgemini.google.com"
    assert_match patterns.fetch("Grok"), "grok.com"
    refute_match patterns.fetch("Grok"), "notgrok.com"
  end

  def test_unknown_policy_version_is_rejected_without_mutating_config
    config = base_config
    snapshot = Marshal.load(Marshal.dump(config))
    policy = Marshal.load(Marshal.dump(@policy))
    policy["version"] = 999

    result = ClaudeEasy.patch(config, policy)

    assert_equal :invalid_policy, result.fetch(:status)
    assert_equal snapshot, config
    assert_equal snapshot, result.fetch(:config)
  end

  def test_policy_without_local_udp_rules_is_rejected_without_mutating_config
    config = base_config
    snapshot = Marshal.load(Marshal.dump(config))
    policy = Marshal.load(Marshal.dump(@policy))
    policy.delete("lan_udp_direct_rules")

    result = ClaudeEasy.patch(config, policy)

    assert_equal :invalid_policy, result.fetch(:status)
    assert_equal snapshot, config
    assert_equal snapshot, result.fetch(:config)
  end

  def test_policy_without_managed_provider_or_domestic_udp_template_is_rejected_without_mutating_config
    invalid_policies = ["cn_domain_provider", "cn_ip_provider", "cn_udp_direct_rule"].map do |key|
      policy = Marshal.load(Marshal.dump(@policy))
      policy.delete(key)
      policy
    end

    invalid_policies.each do |policy|
      config = base_config
      snapshot = Marshal.load(Marshal.dump(config))
      result = begin
        ClaudeEasy.patch(config, policy)
      rescue StandardError => error
        error
      end

      assert_instance_of Hash, result
      assert_equal :invalid_policy, result.fetch(:status)
      assert_equal snapshot, config
      assert_equal snapshot, result.fetch(:config)
    end
  end

  def test_policy_without_any_required_array_is_rejected_without_mutating_config
    required_arrays = %w[
      resolvers direct_resolvers bootstrap_fallback_resolvers main_group_names
      ai_group_names taiwan_tokens japan_tokens forbidden_ai_domains
      legacy_ai_rules ai_rules
    ]

    required_arrays.each do |key|
      config = base_config
      snapshot = Marshal.load(Marshal.dump(config))
      policy = Marshal.load(Marshal.dump(@policy))
      policy.delete(key)

      result = ClaudeEasy.patch(config, policy)

      assert_equal :invalid_policy, result.fetch(:status), key
      assert_equal snapshot, config, key
      assert_equal snapshot, result.fetch(:config), key
    end
  end

  def test_policy_with_invalid_ai_rule_template_is_rejected_without_mutating_config
    invalid_templates = [
      "DOMAIN-SUFFIX,openai.com,DIRECT",
      "DOMAIN-SUFFIX,openai.com,{AI},{AI}"
    ]

    invalid_templates.each do |template|
      config = base_config
      snapshot = Marshal.load(Marshal.dump(config))
      policy = Marshal.load(Marshal.dump(@policy))
      policy["ai_rules"] = [template]

      result = ClaudeEasy.patch(config, policy)

      assert_equal :invalid_policy, result.fetch(:status), template
      assert_equal snapshot, config, template
      assert_equal snapshot, result.fetch(:config), template
    end
  end

  def test_policy_with_wrong_or_ambiguous_provider_semantics_is_rejected_without_mutation
    invalid_policies = []
    wrong_behavior = Marshal.load(Marshal.dump(@policy))
    wrong_behavior.fetch("cn_ip_provider")["behavior"] = "domain"
    invalid_policies << wrong_behavior
    ambiguous = Marshal.load(Marshal.dump(@policy))
    %w[name url path].each do |key|
      ambiguous.fetch("cn_ip_provider")[key] = ambiguous.fetch("cn_domain_provider").fetch(key)
    end
    invalid_policies << ambiguous

    invalid_policies.each do |policy|
      config = base_config
      snapshot = Marshal.load(Marshal.dump(config))

      result = ClaudeEasy.patch(config, policy)

      assert_equal :invalid_policy, result.fetch(:status)
      assert_equal snapshot, config
      assert_equal snapshot, result.fetch(:config)
    end
  end

  def test_locked_write_restores_original_bytes_after_a_partial_write_error
    fake = Class.new do
      attr_reader :bytes

      def initialize(original)
        @bytes = original.dup
        @position = 0
        @writes = 0
      end

      def rewind
        @position = 0
      end

      def write(value)
        @writes += 1
        if @writes == 1
          half = [value.bytesize / 2, 1].max
          @bytes[0, half] = value.byteslice(0, half)
          @position = half
          raise Errno::ENOSPC
        end
        @bytes = value.dup
        @position = value.bytesize
        value.bytesize
      end

      def truncate(length)
        @bytes = @bytes.byteslice(0, length)
      end

      def flush; end
      def fsync; end
    end.new("original configuration")

    assert_raises(Errno::ENOSPC) do
      ClaudeEasy.write_locked_bytes(fake, "replacement configuration", "original configuration")
    end
    assert_equal "original configuration", fake.bytes
  end

  def test_applies_dns_tun_ai_and_webrtc_policy
    result = ClaudeEasy.patch(base_config, @policy)
    patched = result.fetch(:config)

    assert result.fetch(:changed)
    assert_equal "Main", result.fetch(:main_group)
    assert_equal "AI", result.fetch(:ai_group)
    refute result.key?(:selected_home)
    assert_equal false, patched["ipv6"]
    assert_equal false, patched.dig("dns", "ipv6")
    assert_equal true, patched.dig("tun", "strict-route")
    assert_equal ["any:53", "tcp://any:53"], patched.dig("tun", "dns-hijack")
    assert patched.dig("dns", "nameserver").all? { |value| value.end_with?("##{result.fetch(:route_group)}") }
    assert_equal @policy.fetch("direct_resolvers"), patched.dig("dns", "direct-nameserver")
    assert_equal false, patched.dig("dns", "direct-nameserver-follow-policy")
    assert_equal @policy.fetch("direct_resolvers"), patched.dig("dns", "nameserver-policy", "geosite:cn")
    assert patched.dig("dns", "nameserver-policy", "+.openai.com").all? { |value| value.end_with?("##{result.fetch(:ai_group)}") }

    ai_group = patched.fetch("proxy-groups").find { |group| group["name"] == result.fetch(:ai_group) }
    assert_equal ["Main"], ai_group.fetch("proxies")
    udp = "NETWORK,UDP,#{result.fetch(:ai_group)}"
    assert_includes patched.fetch("rules"), udp
    assert_equal "NETWORK,UDP,REJECT", patched.fetch("rules")[patched.fetch("rules").index(udp) + 1]
    assert_operator patched.fetch("rules").index("RULE-SET,#{result.fetch(:cn_provider)},DIRECT"), :<,
                    patched.fetch("rules").index(udp)
    assert_operator patched.fetch("rules").index(udp), :<, patched.fetch("rules").index("GEOSITE,CN,DIRECT")
    assert_includes patched.fetch("rules"), "DOMAIN,raw.githubusercontent.com,AI"
    assert_includes patched.fetch("rules"), "DOMAIN,storage.googleapis.com,AI"
  end

  def test_routes_udp_by_deterministic_destination_and_fails_closed_for_ai
    result = ClaudeEasy.patch(base_config, @policy)
    patched = result.fetch(:config)
    rules = patched.fetch("rules")
    ai_group = result.fetch(:ai_group)
    cn_provider = result.fetch(:cn_provider)
    cn_ip_provider = @policy.fetch("cn_ip_provider").fetch("name")
    expected_order = [
      "DOMAIN-SUFFIX,openai.com,#{ai_group}",
      "DOMAIN-SUFFIX,openai.com,REJECT",
      "RULE-SET,#{cn_provider},DIRECT",
      "AND,((NETWORK,UDP),(RULE-SET,#{cn_ip_provider})),DIRECT",
      "NETWORK,UDP,#{ai_group}",
      "NETWORK,UDP,REJECT"
    ]

    provider = patched.fetch("rule-providers").fetch(cn_ip_provider)
    assert_equal "ipcidr", provider.fetch("behavior")
    assert_equal result.fetch(:route_group), provider.fetch("proxy")
    indexes = expected_order.map { |rule| rules.index(rule) }
    refute_includes indexes, nil
    indexes.each_cons(2) { |left, right| assert_operator left, :<, right }
    refute ClaudeEasy.patch(patched, @policy).fetch(:changed)
  end

  def test_routes_local_udp_direct_before_the_global_udp_guard
    result = ClaudeEasy.patch(base_config, @policy)
    rules = result.fetch(:config).fetch("rules")
    global_udp = rules.index("NETWORK,UDP,#{result.fetch(:ai_group)}")
    local_rules = [
      "AND,((NETWORK,UDP),(IP-CIDR,10.0.0.0/8,no-resolve)),DIRECT",
      "AND,((NETWORK,UDP),(IP-CIDR,100.64.0.0/10,no-resolve)),DIRECT",
      "AND,((NETWORK,UDP),(IP-CIDR,127.0.0.0/8,no-resolve)),DIRECT",
      "AND,((NETWORK,UDP),(IP-CIDR,169.254.0.0/16,no-resolve)),DIRECT",
      "AND,((NETWORK,UDP),(IP-CIDR,172.16.0.0/12,no-resolve)),DIRECT",
      "AND,((NETWORK,UDP),(IP-CIDR,192.168.0.0/16,no-resolve)),DIRECT",
      "AND,((NETWORK,UDP),(IP-CIDR,224.0.0.0/4,no-resolve)),DIRECT",
      "AND,((NETWORK,UDP),(IP-CIDR,255.255.255.255/32,no-resolve)),DIRECT",
      "AND,((NETWORK,UDP),(IP-CIDR6,::1/128,no-resolve)),DIRECT",
      "AND,((NETWORK,UDP),(IP-CIDR6,fc00::/7,no-resolve)),DIRECT",
      "AND,((NETWORK,UDP),(IP-CIDR6,fe80::/10,no-resolve)),DIRECT",
      "AND,((NETWORK,UDP),(IP-CIDR6,ff00::/8,no-resolve)),DIRECT"
    ]

    local_rules.each do |rule|
      assert_includes rules, rule
      assert_operator rules.index(rule), :<, global_udp
    end
    refute rules.any? { |rule| rule.include?("198.18.0.0/15") }
  end

  def test_reuses_existing_ai_group_without_creating_visible_groups
    config = base_config
    original_ai = Marshal.load(Marshal.dump(config.fetch("proxy-groups").find { |group| group["name"] == "AI" }))

    result = ClaudeEasy.patch(config, @policy)
    patched = result.fetch(:config)

    assert_equal "AI", result.fetch(:ai_group)
    assert_equal "Main", result.fetch(:route_group)
    assert_equal original_ai, patched.fetch("proxy-groups").find { |group| group["name"] == "AI" }
    refute patched.fetch("proxy-groups").any? { |group| ClaudeEasy.managed_group_name?(group["name"]) }
    assert_includes patched.fetch("rules"), "DOMAIN-SUFFIX,openai.com,AI"
    assert_equal ClaudeEasy.render_ai_rules(@policy, "AI").first(2), patched.fetch("rules").first(2)
    assert patched.dig("dns", "nameserver").all? { |value| value.end_with?("#Main") }
    assert patched.dig("dns", "nameserver-policy", "+.openai.com").all? { |value| value.end_with?("#AI") }
  end

  def test_creates_ai_group_with_all_inline_nodes_when_subscription_has_none
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }

    result = ClaudeEasy.patch(config, @policy)
    patched = result.fetch(:config)

    assert_equal "🤖 AI · ClaudeEasy", result.fetch(:ai_group)
    assert_equal "Main", result.fetch(:route_group)
    ai_group = patched.fetch("proxy-groups").find { |group| group["name"] == result.fetch(:ai_group) }
    assert_equal ["台湾家宽 01", "日本家宽 01", "美国家宽 01"], ai_group.fetch("proxies")
    refute ai_group.key?("use")
    refute patched.fetch("proxy-groups").any? { |group| ClaudeEasy.managed_name?(group["name"], ClaudeEasy::SAFE_GROUP_BASE) }
    assert_includes patched.fetch("rules"), "DOMAIN-SUFFIX,openai.com,🤖 AI · ClaudeEasy"
    assert_equal "DOMAIN-SUFFIX,anthropic.com,🤖 AI · ClaudeEasy", patched.fetch("rules")[0]
    assert patched.dig("dns", "nameserver-policy", "+.openai.com").all? do |value|
      value.end_with?("#🤖 AI · ClaudeEasy")
    end
  end

  def test_new_ai_group_includes_every_proxy_provider
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    config["proxy-providers"] = {
      "airport-a" => { "type" => "http", "url" => "https://example.invalid/a" },
      "airport-b" => { "type" => "file", "path" => "./providers/b.yaml" }
    }

    result = ClaudeEasy.patch(config, @policy)
    ai_group = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == result.fetch(:ai_group) }

    assert_equal ["台湾家宽 01", "日本家宽 01", "美国家宽 01"], ai_group.fetch("proxies")
    assert_equal ["airport-a", "airport-b"], ai_group.fetch("use")
  end

  def test_new_ai_group_supports_provider_only_subscriptions
    config = base_config
    config["proxies"] = []
    config["proxy-groups"] = [{ "name" => "Main", "type" => "select", "use" => ["airport-a"] }]
    config["proxy-providers"] = {
      "airport-a" => { "type" => "http", "url" => "https://example.invalid/a" }
    }
    config["rules"] = ["MATCH,Main"]

    first = ClaudeEasy.patch(config, @policy)
    ai_group = first.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == first.fetch(:ai_group) }

    assert_empty ai_group.fetch("proxies")
    assert_equal ["airport-a"], ai_group.fetch("use")
    assert_equal first.fetch(:config), ClaudeEasy.patch(first.fetch(:config), @policy).fetch(:config)
  end

  def test_does_not_create_ai_group_without_nodes_or_providers
    config = base_config
    config["proxies"] = []
    config.delete("proxy-providers")
    config["proxy-groups"] = [{ "name" => "Main", "type" => "select", "proxies" => ["Ghost"] }]
    config["rules"] = ["MATCH,Main"]

    result = ClaudeEasy.patch(config, @policy)

    assert_equal :no_main_group, result.fetch(:status)
    assert_equal config, result.fetch(:config)
  end

  def test_preserves_ambiguous_single_main_ai_group_ownership
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    ai_name = ClaudeEasy::AI_GROUP_BASE
    config["proxy-groups"] << { "name" => ai_name, "type" => "select", "proxies" => ["Main"] }
    config["rules"] = ClaudeEasy.render_ai_rules(@policy, ai_name) + config.fetch("rules")

    result = ClaudeEasy.patch(config, @policy)
    ai_group = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == ai_name }

    refute result.fetch(:ai_group_reset)
    assert_equal ["Main"], ai_group.fetch("proxies")
    refute ClaudeEasy.patch(result.fetch(:config), @policy).fetch(:changed)
  end

  def test_removes_obsolete_managed_groups
    config = base_config
    ai_name = ClaudeEasy::AI_GROUP_BASE
    safe_name = ClaudeEasy::SAFE_GROUP_BASE
    assert_equal "Direct|Dns|Reject|RejectDrop|Pass|PassRule|Compatible|Rematch", ClaudeEasy::EXCLUDED_SAFE_TYPES
    config["proxy-groups"] << {
      "name" => ai_name, "type" => "select",
      "proxies" => ["台湾家宽 01", "日本家宽 01", "美国家宽 01"]
    }
    config["proxy-groups"] << {
      "name" => safe_name, "type" => "select", "proxies" => ["台湾家宽 01", "日本家宽 01"],
      "include-all" => true, "exclude-type" => ClaudeEasy::EXCLUDED_SAFE_TYPES, "empty-fallback" => "REJECT"
    }
    config["dns"]["nameserver"] = ["https://dns.alidns.com/dns-query##{safe_name}"]
    config["dns"]["nameserver-policy"] = { "+.openai.com" => ["https://dns.alidns.com/dns-query##{safe_name}"] }
    config["rules"] = ["NETWORK,UDP,#{safe_name}", "NETWORK,UDP,REJECT"] +
      ClaudeEasy.render_ai_rules(@policy, ai_name) + config.fetch("rules")

    patched = ClaudeEasy.patch(config, @policy).fetch(:config)

    refute patched.fetch("proxy-groups").any? { |group| [ai_name, safe_name].include?(group["name"]) }
    refute patched.fetch("rules").any? { |rule| rule.include?(ai_name) || rule.include?(safe_name) }
    refute JSON.generate(patched.fetch("dns")).include?(safe_name)
    assert_equal ClaudeEasy.render_ai_rules(@policy, "AI").first(2), patched.fetch("rules").first(2)
  end

  def test_preserves_encrypted_ip_bootstrap_and_replaces_direct_resolvers_with_managed_mainland_doh
    config = base_config
    config["proxies"] << { "name" => "ecs", "type" => "ss", "server" => "proxy.invalid" }
    config["dns"]["default-nameserver"] = ["tls://223.5.5.5", "tls://1.12.12.12"]
    config["dns"]["proxy-server-nameserver"] = ["https://223.5.5.5/dns-query", "https://1.1.1.1/dns-query#ecs"]
    config["dns"]["direct-nameserver"] = ["system"]

    patched = ClaudeEasy.patch(config, @policy).fetch(:config).fetch("dns")

    assert_equal ["tls://223.5.5.5", "tls://1.12.12.12"], patched.fetch("default-nameserver")
    assert_equal ["https://223.5.5.5/dns-query", "https://1.1.1.1/dns-query#ecs"], patched.fetch("proxy-server-nameserver")
    assert_equal @policy.fetch("direct_resolvers"), patched.fetch("direct-nameserver")
    assert_equal false, patched.fetch("direct-nameserver-follow-policy")
  end

  def test_managed_dns_uses_bootstrap_free_ip_doh_and_rewrites_other_endpoints
    expected_resolvers = [
      "https://94.140.14.140/dns-query",
      "https://94.140.14.141/dns-query",
      "https://101.101.101.101/dns-query"
    ]
    assert_equal expected_resolvers, @policy.fetch("resolvers")
    assert_equal [
      "https://223.5.5.5/dns-query#DIRECT",
      "https://1.12.12.12/dns-query#DIRECT"
    ], @policy.fetch("direct_resolvers")

    config = base_config
    config["dns"]["proxy-server-nameserver"] = ["223.5.5.5", "120.53.53.53"]
    config["dns"]["nameserver-policy"] = {
      "+.hostname-resolver.example" => ["https://dns.alidns.com/dns-query#台湾家宽 01"],
      "+.blocked-prone.example" => ["https://8.8.8.8/dns-query#台湾家宽 01"],
      "+.managed.example" => ["https://94.140.14.140/dns-query#台湾家宽 01"]
    }

    result = ClaudeEasy.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")
    managed = expected_resolvers.map { |resolver| "#{resolver}#台湾家宽 01" }

    assert_equal managed, policies.fetch("+.hostname-resolver.example")
    assert_equal managed, policies.fetch("+.blocked-prone.example")
    assert_equal managed, policies.fetch("+.managed.example")
    assert_equal @policy.fetch("bootstrap_fallback_resolvers"), result.fetch(:config).dig("dns", "proxy-server-nameserver")
  end

  def test_uses_bootstrap_free_mainland_doh_when_proxy_bootstrap_is_missing
    [1, 2, 3].each do |usage_profile|
      patched = ClaudeEasy.patch(base_config, @policy, usage_profile: usage_profile).fetch(:config).fetch("dns")

      refute patched.key?("default-nameserver")
      assert_equal [
        "https://223.5.5.5/dns-query#DIRECT",
        "https://1.12.12.12/dns-query#DIRECT"
      ], patched.fetch("proxy-server-nameserver")
      assert_equal @policy.fetch("direct_resolvers"), patched.fetch("direct-nameserver")
      assert_equal false, patched.fetch("direct-nameserver-follow-policy")
    end
  end

  def test_migrates_system_proxy_bootstrap_to_bootstrap_free_mainland_doh
    config = base_config
    config["dns"]["proxy-server-nameserver"] = ["system"]

    [1, 2, 3].each do |usage_profile|
      patched = ClaudeEasy.patch(config, @policy, usage_profile: usage_profile).fetch(:config).fetch("dns")

      assert_equal [
        "https://223.5.5.5/dns-query#DIRECT",
        "https://1.12.12.12/dns-query#DIRECT"
      ], patched.fetch("proxy-server-nameserver")
    end
  end

  def test_migrates_mixed_system_and_plaintext_bootstrap_to_bootstrap_free_mainland_doh
    config = base_config
    config["dns"]["default-nameserver"] = ["udp://223.5.5.5", "system", "tls://1.12.12.12"]
    config["dns"]["proxy-server-nameserver"] = ["https://1.1.1.1/dns-query#h3=true#&skip-cert-verify=true&DIRECT"]

    [1, 2, 3].each do |usage_profile|
      patched = ClaudeEasy.patch(config, @policy, usage_profile: usage_profile).fetch(:config).fetch("dns")

      assert_equal @policy.fetch("bootstrap_fallback_resolvers"), patched.fetch("default-nameserver")
      assert_equal @policy.fetch("bootstrap_fallback_resolvers"), patched.fetch("proxy-server-nameserver")
    end
  end

  def test_migrates_the_old_unsafe_bootstrap_signature_to_bootstrap_free_mainland_doh
    config = base_config
    config["dns"]["default-nameserver"] = ["1.1.1.1", "8.8.8.8"]
    config["dns"]["proxy-server-nameserver"] = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]

    patched = ClaudeEasy.patch(config, @policy).fetch(:config).fetch("dns")

    expected = [
      "https://223.5.5.5/dns-query#DIRECT",
      "https://1.12.12.12/dns-query#DIRECT"
    ]
    assert_equal expected, patched.fetch("default-nameserver")
    assert_equal expected, patched.fetch("proxy-server-nameserver")

    config["dns"]["proxy-server-nameserver"] = [
      "https://8.8.8.8/dns-query", "https://1.1.1.1/dns-query"
    ]
    assert_equal expected,
                 ClaudeEasy.patch(config, @policy).fetch(:config).fetch("dns").fetch("proxy-server-nameserver")
  end

  def test_bootstrap_dns_outputs_match_windows_in_every_usage_profile
    cases = [
      ["missing", {}],
      ["scalar system", { "default-nameserver" => "system", "proxy-server-nameserver" => "system" }],
      [
        "scalar encrypted",
        {
          "default-nameserver" => "tls://223.5.5.5",
          "proxy-server-nameserver" => "https://223.5.5.5/dns-query"
        }
      ],
      [
        "mixed unsafe",
        {
          "default-nameserver" => ["tls://1.12.12.12", "223.5.5.5"],
          "proxy-server-nameserver" => ["https://223.5.5.5/dns-query", "system"]
        }
      ]
    ]
    inputs = cases.flat_map do |name, bootstrap|
      [1, 2, 3].map do |usage_profile|
        config = base_config
        config.fetch("dns").merge!(bootstrap)
        { "name" => name, "usage_profile" => usage_profile, "config" => config }
      end
    end
    engine_path = File.join(ROOT, "claude-easy/scripts/windows/clash_verge_global.js")
    javascript = <<~'JS'
      const fs = require('node:fs');
      const engine = require(process.argv[1]);
      const inputs = JSON.parse(fs.readFileSync(0, 'utf8'));
      const keys = [
        'default-nameserver',
        'proxy-server-nameserver',
        'direct-nameserver',
        'direct-nameserver-follow-policy'
      ];
      const outputs = inputs.map(({ config, usage_profile: usageProfile }) => {
        const dns = engine.claudeEasyTransform(config, 'fixture', usageProfile).dns;
        return Object.fromEntries(keys.filter((key) => Object.hasOwn(dns, key)).map((key) => [key, dns[key]]));
      });
      process.stdout.write(JSON.stringify(outputs));
    JS
    stdout, stderr, status = Open3.capture3(
      "node", "-e", javascript, engine_path, stdin_data: JSON.generate(inputs)
    )
    assert status.success?, stderr
    windows = JSON.parse(stdout)
    keys = %w[
      default-nameserver
      proxy-server-nameserver
      direct-nameserver
      direct-nameserver-follow-policy
    ]

    inputs.each_with_index do |entry, index|
      dns = ClaudeEasy.patch(
        entry.fetch("config"), @policy, usage_profile: entry.fetch("usage_profile")
      ).fetch(:config).fetch("dns")
      macos = dns.select { |key, _value| keys.include?(key) }
      assert_equal macos, windows.fetch(index), "#{entry.fetch('name')} profile #{entry.fetch('usage_profile')}"
      next unless entry.fetch("name").start_with?("scalar")

      assert_equal @policy.fetch("bootstrap_fallback_resolvers"), macos.fetch("default-nameserver")
      assert_equal @policy.fetch("bootstrap_fallback_resolvers"), macos.fetch("proxy-server-nameserver")
    end
  end

  def test_does_not_select_japan_home_automatically
    config = base_config
    config["proxies"].reject! { |proxy| proxy["name"].include?("台湾") }
    config["proxy-groups"].each { |group| group["proxies"]&.delete("台湾家宽 01") }
    result = ClaudeEasy.patch(config, @policy)

    refute result.key?(:selected_home)
    assert_equal ["Main"], result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == "AI" }.fetch("proxies")
  end

  def test_new_ai_group_lists_other_country_nodes_without_auto_selecting
    config = base_config
    config["proxies"].select! { |proxy| proxy["name"] == "美国家宽 01" }
    config["proxy-groups"].find { |group| group["name"] == "Main" }["proxies"] = ["美国家宽 01"]
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    result = ClaudeEasy.patch(config, @policy)
    ai_group = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == "🤖 AI · ClaudeEasy" }

    refute result.key?(:selected_home)
    assert_equal ["美国家宽 01"], ai_group.fetch("proxies")
    refute ai_group.key?("now")
  end

  def test_preserves_unmanaged_narrow_rules
    original = base_config.fetch("rules").select { |rule| rule.include?("friend.example") || rule.include?("static.example.net") }
    patched = ClaudeEasy.patch(base_config, @policy).fetch(:config)
    after = patched.fetch("rules").select { |rule| rule.include?("friend.example") || rule.include?("static.example.net") }

    assert_equal original, after
  end

  def test_places_udp_guard_before_narrow_rule_set
    config = base_config
    config["rules"].insert(2, "RULE-SET,private-special,DIRECT")
    rules = ClaudeEasy.patch(config, @policy).fetch(:config).fetch("rules")

    udp_index = rules.index { |rule| rule.start_with?("NETWORK,UDP,") && rule != "NETWORK,UDP,REJECT" }
    expected_cn_udp = ClaudeEasy.render_cn_udp_direct_rule(
      @policy, @policy.fetch("cn_ip_provider").fetch("name")
    )
    assert_equal expected_cn_udp, rules[udp_index - 1]
    assert_equal "NETWORK,UDP,REJECT", rules[udp_index + 1]
    assert_operator udp_index, :<, rules.index("GEOSITE,CN,DIRECT")
    assert_operator udp_index, :<, rules.index("RULE-SET,private-special,DIRECT")
  end

  def test_strips_foreign_target_rules_that_collide_with_managed_ai_keys
    config = base_config
    config["proxy-groups"] << { "name" => "MyGroup", "type" => "select", "proxies" => ["台湾家宽 01"] }
    conflicts = [
      "DOMAIN-SUFFIX,openai.com,MyGroup",
      "DOMAIN-SUFFIX,claude.ai,DIRECT",
      "DOMAIN-SUFFIX,anthropic.com,REJECT"
    ]
    config["rules"] = conflicts + config.fetch("rules")

    result = ClaudeEasy.patch(config, @policy)
    rules = result.fetch(:config).fetch("rules")

    conflicts.first(2).each { |conflict| refute_includes rules, conflict }
    assert_includes rules, "DOMAIN-SUFFIX,anthropic.com,REJECT"
    assert_includes rules, "DOMAIN-SUFFIX,openai.com,#{result.fetch(:ai_group)}"
    assert_includes rules, "DOMAIN-SUFFIX,claude.ai,#{result.fetch(:ai_group)}"
    assert_includes rules, "DOMAIN-SUFFIX,anthropic.com,#{result.fetch(:ai_group)}"
    refute ClaudeEasy.patch(result.fetch(:config), @policy).fetch(:changed)
  end

  def test_main_group_ai_rules_do_not_bypass_the_ai_selector
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    provider_rules = [
      "DOMAIN-SUFFIX,openai.com,Main",
      "DOMAIN-SUFFIX,claude.ai,Main",
      "DOMAIN-KEYWORD,openai,Main"
    ]
    config["rules"] = provider_rules + config.fetch("rules")

    result = ClaudeEasy.patch(config, @policy)
    rules = result.fetch(:config).fetch("rules")
    ai_group = result.fetch(:ai_group)

    provider_rules.each { |rule| refute_includes rules, rule }
    assert_includes rules, "DOMAIN-SUFFIX,openai.com,#{ai_group}"
    assert_includes rules, "DOMAIN-SUFFIX,claude.ai,#{ai_group}"
    assert_includes rules, "DOMAIN-KEYWORD,openai,#{ai_group}"
  end

  def test_udp_guard_precedes_leaking_rules_without_deleting_them
    config = base_config
    user_rules = [
      "NETWORK,udp,DIRECT",
      "NETWORK, UDP, DIRECT",
      "DST-PORT,3478,DIRECT",
      "PROCESS-NAME,chrome,DIRECT"
    ]
    config["rules"] = user_rules + config.fetch("rules")

    result = ClaudeEasy.patch(config, @policy)
    rules = result.fetch(:config).fetch("rules")
    guard = "NETWORK,UDP,#{result.fetch(:ai_group)}"

    expected_cn_udp = ClaudeEasy.render_cn_udp_direct_rule(
      @policy, @policy.fetch("cn_ip_provider").fetch("name")
    )
    assert_equal expected_cn_udp, rules[rules.index(guard) - 1]
    assert_equal "NETWORK,UDP,REJECT", rules[rules.index(guard) + 1]
    user_rules.each do |rule|
      assert_includes rules, rule
      assert_operator rules.index(guard), :<, rules.index(rule)
    end
  end

  def test_preserves_user_udp_rules_to_selected_groups
    { "Main" => 1, "AI" => 2 }.each do |target, expected_count|
      config = base_config
      user_rule = "NETWORK,UDP,#{target}"
      config["rules"].insert(2, user_rule, "NETWORK,UDP,REJECT")

      rules = ClaudeEasy.patch(config, @policy).fetch(:config).fetch("rules")

      assert_equal expected_count, rules.count(user_rule), target
      assert_equal 2, rules.count("NETWORK,UDP,REJECT"), target
    end
  end

  def test_preserves_leading_user_udp_rule_to_main_group
    config = base_config
    config["rules"].unshift("NETWORK,UDP,Main", "NETWORK,UDP,REJECT")

    rules = ClaudeEasy.patch(config, @policy).fetch(:config).fetch("rules")

    assert_equal 1, rules.count("NETWORK,UDP,Main")
    assert_equal 2, rules.count("NETWORK,UDP,REJECT")
  end

  def test_managed_ai_rules_precede_every_rule_set
    config = base_config
    config["rules"] = ["RULE-SET,gfw,DIRECT", "RULE-SET,geolocation-!cn,Main", "MATCH,Main"]

    result = ClaudeEasy.patch(config, @policy)
    rules = result.fetch(:config).fetch("rules")
    managed = "DOMAIN-SUFFIX,openai.com,#{result.fetch(:ai_group)}"

    assert_operator rules.index(managed), :<, rules.index("RULE-SET,gfw,DIRECT")
    assert_operator rules.index(managed), :<, rules.index("RULE-SET,geolocation-!cn,Main")
  end

  def test_is_idempotent
    first = ClaudeEasy.patch(base_config, @policy)
    second = ClaudeEasy.patch(first.fetch(:config), @policy)

    assert first.fetch(:changed)
    refute second.fetch(:changed)
    assert_equal first.fetch(:config), second.fetch(:config)
  end

  def test_skips_invalid_provider_response
    result = ClaudeEasy.patch({ "message" => "401 unauthorized" }, @policy)

    refute result.fetch(:changed)
    assert_equal :invalid, result.fetch(:status)
  end

  def test_preserves_reality_short_id_as_text
    config = base_config
    config["proxies"].first["reality-opts"] = { "short-id" => "0906152e4" }
    patched = ClaudeEasy.patch(config, @policy).fetch(:config)

    assert_equal "0906152e4", patched.fetch("proxies").first.dig("reality-opts", "short-id")
  end

  def test_dump_config_quotes_every_valid_reality_short_id
    short_ids = %w[abcdef12 12ab34cd 0906152e4 12345678]
    config = {
      "proxies" => short_ids.map do |short_id|
        { "reality-opts" => { "short-id" => short_id } }
      end
    }

    dumped = ClaudeEasy.dump_config(config)

    short_ids.each do |short_id|
      assert_match(/short-id: ["']#{Regexp.escape(short_id)}["']/, dumped)
    end
  end

  def test_load_yaml_preserves_every_bare_reality_short_id_as_text
    %w[0906152e4 12345678 0].each do |short_id|
      parsed = ClaudeEasy.load_yaml("reality-opts:\n  short-id: #{short_id}\n")
      assert_instance_of String, parsed.dig("reality-opts", "short-id"), short_id
      assert_equal short_id, parsed.dig("reality-opts", "short-id")
    end
    assert_instance_of Float, ClaudeEasy.load_yaml("ordinary-number: 1e4\n").fetch("ordinary-number")
  end

  def test_short_id_protection_does_not_rewrite_block_scalar_content
    source = "script: |\n  short-id: 12345678\nreality-opts:\n  short-id: 12345678\n"
    parsed = ClaudeEasy.load_yaml(source)

    assert_equal "short-id: 12345678\n", parsed.fetch("script")
    assert_equal "12345678", parsed.dig("reality-opts", "short-id")
  end

  def test_file_patch_preserves_bare_exponent_shaped_reality_short_id
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "bare-short-id.yaml")
      config = base_config
      config["proxies"].first["reality-opts"] = { "short-id" => "0906152e4" }
      source = YAML.dump(config).sub(/short-id: ['"]0906152e4['"]/, "short-id: 0906152e4")
      assert_includes source, "short-id: 0906152e4"
      File.write(profile, source)

      result = ClaudeEasy.patch_path(profile, @policy)
      reparsed = ClaudeEasy.load_yaml(File.read(profile))

      assert result.fetch(:changed)
      assert_equal "0906152e4", reparsed.fetch("proxies").first.dig("reality-opts", "short-id")
    end
  end

  def test_file_patch_is_atomic_quoted_backed_up_and_idempotent
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup = File.join(directory, "private-backups")
      config = base_config
      config["proxies"].first["reality-opts"] = { "short-id" => "0906152e4" }
      File.write(profile, YAML.dump(config))

      first = ClaudeEasy.patch_path(profile, @policy, backup_root: backup)
      first_text = File.read(profile)
      second = ClaudeEasy.patch_path(profile, @policy, backup_root: backup)

      assert first.fetch(:changed)
      assert_match(/short-id: ['"]0906152e4['"]/, first_text)
      assert_equal 1, Dir.glob(File.join(backup, "*.backup")).length
      refute second.fetch(:changed)
      assert_equal first_text, File.read(profile)
    end
  end

  def test_every_write_creates_a_dated_versioned_backup
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.write(profile, original)

      first = ClaudeEasy.patch_path(profile, @policy, backup_root: backup_root)
      changed_again = ClaudeEasy.load_yaml(File.read(profile))
      changed_again["ipv6"] = true
      changed_again["friend-marker"] = "before-second-write"
      second_source = YAML.dump(changed_again)
      File.write(profile, second_source)
      second = ClaudeEasy.patch_path(profile, @policy, backup_root: backup_root)

      backups = Dir.glob(File.join(backup_root, "*.backup")).sort
      assert first.fetch(:changed)
      assert second.fetch(:changed)
      assert_equal 2, backups.length
      backups.each do |path|
        assert_match(/\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.\d{9}[+-]\d{4}--prewrite--[0-9a-f]{16}\.backup\z/, File.basename(path))
      end
      assert_includes backups.map { |path| File.binread(path) }, original.b
      assert_includes backups.map { |path| File.binread(path) }, second_source.b
    end
  end

  def test_initial_snapshot_is_created_once_without_modifying_profiles
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.write(profile, original)

      first = ClaudeEasy.snapshot_initial_profiles([directory], backup_root)
      second = ClaudeEasy.snapshot_initial_profiles([directory], backup_root)
      backups = Dir.glob(File.join(backup_root, "*.backup"))

      assert_equal 1, first.length
      assert_empty second
      assert_equal 1, backups.length
      assert_includes File.basename(backups.first), "--initial--"
      assert_equal original.b, File.binread(backups.first)
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_versioned_backup_is_hidden_until_atomic_publication
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.write(profile, YAML.dump(base_config))

      assert_raises(IOError) do
        ClaudeEasyDarwinFilesystem.stub(:rename_exclusive, ->(*) { raise IOError, "injected" }) do
          ClaudeEasy.create_versioned_backup(profile, backup_root)
        end
      end
      assert_empty ClaudeEasy.backup_entries_for(profile, backup_root)
    end
  end

  def test_list_backups_returns_only_opaque_backup_ids_newest_first
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "11111111-2222-3333-4444-555555555555.yaml")
      File.write(profile, YAML.dump(base_config))
      older = ClaudeEasy.create_versioned_backup(profile, backup_root, reason: "initial")
      newer = ClaudeEasy.create_versioned_backup(profile, backup_root, reason: "prewrite")
      File.write(File.join(backup_root, "not-a-backup.txt"), "ignore")
      File.symlink(older, File.join(backup_root, "2099-01-01_00-00-00.000000000+0000--prewrite--fake--friend.yaml.backup"))

      listed = ClaudeEasy.list_backups(backup_root)

      assert_equal [newer, older].map { |path|
        filename = File.basename(path)
        {
          "id" => ClaudeEasy.public_backup_id(filename),
          "created_at" => ClaudeEasy.backup_created_at(filename)
        }
      }, listed
      assert listed.all? { |item| item.fetch("id").match?(/\Ace-backup-v1-[0-9a-f]{64}\z/) }
      assert listed.all? { |item| Time.iso8601(item.fetch("created_at")) }
      refute listed.any? { |item| JSON.generate(item).include?(File.basename(profile, ".yaml")) }
      assert_equal newer, ClaudeEasy.resolve_backup_id(listed.first.fetch("id"), backup_root)
    end
  end

  def test_long_profile_names_do_not_break_patch_backup_listing_or_restore
    Dir.mktmpdir do |directory|
      basename = ("订" * 60) + "--preference--.yaml"
      profile = File.join(directory, basename)
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)

      backup = ClaudeEasy.create_versioned_backup(profile, backup_root, reason: "initial")
      assert_operator File.basename(backup).bytesize, :<=, 255
      assert_equal 1, ClaudeEasy.backup_entries_for(profile, backup_root, reason: "initial").length
      ascii_profile = File.join(directory, ("a" * 220) + ".yaml")
      File.binwrite(ascii_profile, original)
      ClaudeEasy.create_versioned_backup(ascii_profile, backup_root, reason: "initial")
      assert_equal 1, ClaudeEasy.backup_entries_for(ascii_profile, backup_root, reason: "initial").length
      assert_equal 2, ClaudeEasy.list_backups(backup_root).length

      patch_result = ClaudeEasy.patch_path(
        profile, @policy, backup_root: backup_root, usage_profile: 3,
        validator: ->(path) { File.file?(path) }
      )
      assert patch_result.fetch(:changed)

      backup_id = ClaudeEasy.public_backup_id(File.basename(backup))
      comparison = ClaudeEasy.compare_backup(
        backup_id, directories: [directory], backup_root: backup_root
      )
      restored = ClaudeEasy.restore_backup(
        backup_id, directories: [directory], backup_root: backup_root,
        expected_current_sha256: comparison.fetch(:current_sha256),
        validator: ->(path) { File.file?(path) }, selected_name: "not-active",
        activation: ->(result) { result }
      )
      assert_equal :updated, restored.fetch(:status)
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_opaque_backup_id_round_trips_through_compare_and_restore
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "11111111-2222-3333-4444-555555555555.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.write(profile, original)
      ClaudeEasy.create_versioned_backup(profile, backup_root, content: original, reason: "prewrite")
      changed = base_config
      changed["ipv6"] = true
      File.write(profile, YAML.dump(changed))

      backup_id = ClaudeEasy.list_backups(backup_root).first.fetch("id")
      comparison = ClaudeEasy.compare_backup(
        backup_id, directories: [directory], backup_root: backup_root
      )
      result = ClaudeEasy.restore_backup(
        backup_id, directories: [directory], backup_root: backup_root,
        expected_current_sha256: comparison.fetch(:current_sha256),
        validator: ->(_path) { true }, selected_name: "not-active",
        activation: ->(restore_result) { restore_result }
      )

      assert_equal backup_id, comparison.fetch(:backup_id)
      refute_includes JSON.generate(comparison), "11111111-2222-3333-4444-555555555555"
      assert_equal :updated, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_restore_backup_records_the_active_runtime_checkpoint_before_writing
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      current = YAML.dump(base_config.merge("subscription-marker" => "new"))
      File.binwrite(profile, original)
      ClaudeEasy.create_versioned_backup(profile, backup_root, reason: "prewrite")
      File.binwrite(profile, current)
      backup_id = ClaudeEasy.list_backups(backup_root).first.fetch("id")
      checkpoint = {
        path: File.realpath(profile), expected_tun: :disabled,
        selections: { "Main" => "Taiwan" }
      }
      recorded_state = nil

      result = ClaudeEasy.restore_backup(
        backup_id, directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(current),
        validator: ->(_path) { true }, selected_name: "active",
        runtime_checkpoint_provider: ->(_path) { checkpoint },
        activation: lambda do |restore_result|
          recorded_state = JSON.parse(
            File.binread(ClaudeEasy.profile_transaction_path(backup_root))
          )
          restore_result
        end
      )

      assert_equal :updated, result.fetch(:status)
      assert_equal 4, recorded_state.fetch("Version")
      assert_equal "disabled", recorded_state.fetch("Runtime").fetch("Tun")
      assert_equal({ "Main" => "Taiwan" }, recorded_state.fetch("Runtime").fetch("Selections"))
    end
  end

  def test_backup_compare_never_exposes_profile_names_or_dynamic_provider_keys
    Dir.mktmpdir do |directory|
      profile_name = "private-profile-alias"
      provider_name = "private-provider-alias"
      profile = File.join(directory, "#{profile_name}.yaml")
      backup_root = File.join(directory, "backups")
      original = base_config.merge(
        "proxy-providers" => {
          provider_name => {
            "type" => "http", "url" => "https://example.invalid/old",
            "path" => "./providers/private.yaml"
          }
        }
      )
      current = Marshal.load(Marshal.dump(original))
      current.fetch("proxy-providers").fetch(provider_name)["url"] =
        "https://example.invalid/new"
      File.write(profile, YAML.dump(original))
      ClaudeEasy.create_versioned_backup(profile, backup_root, reason: "prewrite")
      File.write(profile, YAML.dump(current))
      backup_id = ClaudeEasy.list_backups(backup_root).first.fetch("id")

      comparison = ClaudeEasy.compare_backup(
        backup_id, directories: [directory], backup_root: backup_root
      )
      public_comparison = JSON.generate(comparison)
      refute comparison.key?(:profile)
      refute_includes public_comparison, profile_name
      refute_includes public_comparison, provider_name

      common_arguments = [
        "--profile-dir", directory, "--backup-dir", backup_root,
        "--compare-backup", backup_id
      ]
      text_output, = capture_io do
        assert_equal 0, ClaudeEasy.cli(common_arguments.dup)
      end
      json_output, = capture_io do
        assert_equal 0, ClaudeEasy.cli(["--json", *common_arguments])
      end
      [text_output, json_output].each do |output|
        refute_includes output, profile_name
        refute_includes output, provider_name
      end

      map_changes = ClaudeEasy.redacted_changed_paths(
        { "proxies" => { "secret-node" => { "type" => "ss" } },
          "proxy-groups" => { "secret-group" => { "type" => "select" } } },
        { "proxies" => { "secret-node" => { "type" => "trojan" } },
          "proxy-groups" => { "secret-group" => { "type" => "url-test" } } }
      )
      assert_includes map_changes, "proxies.[item].type"
      assert_includes map_changes, "proxy-groups.[item].type"
      refute_includes JSON.generate(map_changes), "secret-node"
      refute_includes JSON.generate(map_changes), "secret-group"
    end
  end

  def test_backup_compare_and_restore_are_redacted_reversible_and_hash_guarded
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.write(profile, original)
      backup = ClaudeEasy.create_versioned_backup(profile, backup_root, content: original, reason: "prewrite")
      changed = base_config
      changed["dns"] = { "nameserver" => ["https://secret.example/dns-query"] }
      changed["rules"] = ["DOMAIN-SUFFIX,private.example,DIRECT", "MATCH,Main"]
      File.write(profile, YAML.dump(changed))

      comparison = ClaudeEasy.compare_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root
      )
      assert_equal false, comparison.fetch(:same)
      assert comparison.fetch(:changes).any? { |path| path == "dns" || path.start_with?("dns.") }
      assert_includes comparison.fetch(:changes), "rules"
      refute_includes JSON.generate(comparison), "secret.example"
      refute_includes JSON.generate(comparison), "private.example"

      wrong = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: "0" * 64, validator: ->(_candidate) { true }
      )
      assert_equal :restore_conflict, wrong.fetch(:status)

      current_sha = Digest::SHA256.hexdigest(File.binread(profile))
      restored = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: current_sha, validator: ->(_candidate) { true }
      )
      assert_equal :updated, restored.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 2, Dir.glob(File.join(backup_root, "*.backup")).length
      assert Dir.glob(File.join(backup_root, "*--pre-restore--*.backup")).any?

      already_restored = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(original.b), validator: ->(_candidate) { true }
      )
      assert_equal :no_change, already_restored.fetch(:status)
      assert_equal original.b, already_restored[:rollback_bytes]
      assert_equal Digest::SHA256.hexdigest(original.b), already_restored[:patched_digest]
    end
  end

  def test_backup_restore_runtime_rollback_never_overwrites_a_replaced_candidate_inode
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(base_config.merge("subscription-marker" => "restored"))
      File.binwrite(profile, current)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: restored, reason: "prewrite"
      )
      external_identity = nil
      activation = lambda do |result|
        refute_nil result[:patched_identity]
        refute_nil result[:patched_path]
        replacement = File.join(directory, "external.yaml")
        File.binwrite(replacement, restored)
        File.rename(replacement, profile)
        external = File.stat(profile)
        external_identity = [external.dev, external.ino]
        refute ClaudeEasy.restore_profile_bytes(result)
        result.merge(status: :reload_failed_rollback_conflict)
      end

      result = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(current.b),
        validator: ->(_candidate) { true }, activation: activation
      )

      actual = File.stat(profile)
      assert_equal :reload_failed_rollback_conflict, result.fetch(:status)
      assert_equal restored.b, File.binread(profile)
      assert_equal external_identity, [actual.dev, actual.ino]
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_restore_backup_rechecks_candidate_ownership_before_success
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(base_config.merge("subscription-marker" => "restored"))
      external = YAML.dump(base_config.merge("subscription-marker" => "external"))
      File.binwrite(profile, current)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: restored, reason: "prewrite"
      )
      activation = lambda do |result|
        replacement = File.join(directory, "external.yaml")
        File.binwrite(replacement, external)
        File.rename(replacement, profile)
        result
      end

      result = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(current.b),
        validator: ->(_candidate) { true }, activation: activation
      )

      assert_equal :restore_conflict, result.fetch(:status)
      assert_equal external.b, File.binread(profile)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_restore_backup_keeps_transaction_for_same_file_partial_overwrite
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(base_config.merge("subscription-marker" => "restored"))
      partial = restored.byteslice(0, restored.bytesize / 2)
      File.binwrite(profile, current)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: restored, reason: "prewrite"
      )
      activation = lambda do |result|
        File.binwrite(profile, partial)
        result
      end

      result = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(current.b),
        validator: ->(_candidate) { true }, activation: activation
      )

      assert_equal :restore_conflict, result.fetch(:status)
      assert_equal partial.b, File.binread(profile)
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_backup_restore_transaction_can_release_a_missing_target
    result = {
      path: "/missing/friend.yaml", patched_path: "/missing/friend.yaml",
      patched_identity: [1, 2], rollback_bytes: "original"
    }

    assert ClaudeEasy.backup_restore_transaction_releasable?(result)
  end

  def test_backup_restore_transaction_keeps_journal_when_target_cannot_be_read
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "candidate")
      stat = File.stat(profile)
      result = {
        path: profile, patched_path: File.realpath(profile),
        patched_identity: [stat.dev, stat.ino], rollback_bytes: "original"
      }

      ClaudeEasy.stub(:regular_file_snapshot_once, ->(*_args) { raise IOError, "injected" }) do
        refute ClaudeEasy.backup_restore_transaction_releasable?(result)
      end
    end
  end

  def test_restore_backup_keeps_recovery_intent_when_loaded_candidate_is_superseded
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(base_config.merge("subscription-marker" => "restored"))
      external = YAML.dump(base_config.merge("subscription-marker" => "external"))
      File.binwrite(profile, current)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: restored, reason: "prewrite"
      )
      activation = lambda do |result|
        replacement = File.join(directory, "external.yaml")
        File.binwrite(replacement, external)
        File.rename(replacement, profile)
        result.merge(active: true, reloaded: true)
      end
      reloads = 0

      result = ClaudeEasy.stub(:reload_recovered_profile_runtime, lambda { |*_items, **_options|
        reloads += 1
        false
      }) do
        ClaudeEasy.restore_backup(
          File.basename(backup), directories: [directory], backup_root: backup_root,
          expected_current_sha256: Digest::SHA256.hexdigest(current.b),
          validator: ->(_candidate) { true }, activation: activation
        )
      end

      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_equal 1, reloads
      assert_equal external.b, File.binread(profile)
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_restore_backup_forwards_candidate_state_when_loaded_candidate_is_superseded
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(base_config.merge("subscription-marker" => "restored"))
      external = YAML.dump(base_config.merge("subscription-marker" => "external"))
      File.binwrite(profile, current)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: restored, reason: "prewrite"
      )
      activation = lambda do |result|
        replacement = File.join(directory, "external.yaml")
        File.binwrite(replacement, external)
        File.rename(replacement, profile)
        result.merge(active: true, reloaded: true)
      end
      reload = lambda do |*_items, **options|
        transaction = options.fetch(:transaction)
        assert_equal restored.b, transaction.fetch(:candidate_bytes).fetch(File.realpath(profile))
        true
      end

      result = ClaudeEasy.stub(:reload_recovered_profile_runtime, reload) do
        ClaudeEasy.restore_backup(
          File.basename(backup), directories: [directory], backup_root: backup_root,
          expected_current_sha256: Digest::SHA256.hexdigest(current.b),
          validator: ->(_candidate) { true }, activation: activation
        )
      end

      assert_equal :restore_conflict, result.fetch(:status)
      assert_equal external.b, File.binread(profile)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_backup_restore_clears_a_superseded_loaded_candidate_after_runtime_recovery
    result = { status: :updated, path: "/profiles/friend.yaml", reloaded: true }
    removed = false
    forwarded_transaction = nil
    ClaudeEasy.stub(:profile_result_current?, false) do
      reload = lambda do |*_items, **options|
        forwarded_transaction = options[:transaction]
        true
      end
      ClaudeEasy.stub(:reload_recovered_profile_runtime, reload) do
        ClaudeEasy.stub(:runtime_precommit_allowed?, true) do
          ClaudeEasy.stub(:remove_profile_transaction, ->(_transaction) { removed = true }) do
            result = ClaudeEasy.finish_backup_restore_transaction(
              :transaction, result, precommit_condition: -> { true }
            )
          end
        end
      end
    end

    assert_equal :restore_conflict, result.fetch(:status)
    refute result.key?(:reloaded)
    assert removed
    assert_equal :transaction, forwarded_transaction
  end

  def test_backup_restore_keeps_recovery_intent_when_the_final_context_changes
    result = { status: :updated, path: "/profiles/friend.yaml", reloaded: true }
    ClaudeEasy.stub(:profile_result_current?, true) do
      ClaudeEasy.stub(:runtime_precommit_allowed?, false) do
        ClaudeEasy.stub(:restore_profile_bytes, true) do
          result = ClaudeEasy.finish_backup_restore_transaction(
            :transaction, result, precommit_condition: -> { false }
          )
        end
      end
    end

    assert_equal :reload_failed_restore_pending, result.fetch(:status)
    refute result.key?(:reloaded)
  end

  def test_backup_restore_keeps_recovery_intent_when_profile_switches_during_runtime_health_check
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(base_config.merge("subscription-marker" => "restored"))
      File.binwrite(profile, current)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: restored, reason: "prewrite"
      )
      selected = "friend"
      put_paths = []
      precommit = -> { selected == "friend" }
      requester = lambda do |method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"]
          put_paths << JSON.parse(body).fetch("path")
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end
      activation = lambda do |restore_result|
        ClaudeEasy.activate_updated_profile(
          restore_result, requester: requester, require_tun: :preserve,
          connectivity_checker: -> {
            selected = "other"
            true
          },
          precommit_condition: precommit
        )
      end

      result = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(current.b),
        validator: ->(_candidate) { true }, selected_name: "friend",
        activation: activation, precommit_condition: precommit
      )

      assert_equal [File.expand_path(profile)], put_paths
      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_equal current.b, File.binread(profile)
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_restore_backup_recovers_an_interrupted_batch_before_writing
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "original"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      older = YAML.dump(base_config.merge("subscription-marker" => "older-backup"))
      File.binwrite(profile, original)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: older, reason: "prewrite"
      )
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        backup_root, roots: [directory]
      )
      File.binwrite(profile, candidate)
      runtime_marker = "candidate"
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"]
          loaded = ClaudeEasy.load_yaml(File.read(JSON.parse(body).fetch("path")))
          runtime_marker = loaded.fetch("subscription-marker")
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      controller_requester = lambda do |_socket, method, endpoint, body = nil|
        requester.call(method, endpoint, body)
      end
      result = ClaudeEasy.stub(:controller_socket, "fixture.sock") do
        ClaudeEasy.stub(:controller_request, controller_requester) do
          ClaudeEasy.stub(:default_connectivity_healthy?, true) do
            ClaudeEasy.stub(:selected_profile_name, "friend") do
              ClaudeEasy.restore_backup(
                File.basename(backup), directories: [directory], backup_root: backup_root,
                expected_current_sha256: Digest::SHA256.hexdigest(candidate.b),
                validator: ->(_candidate) { true }
              )
            end
          end
        end
      end

      assert_equal :restore_conflict, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal "original", runtime_marker
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_restore_backup_keeps_pending_transaction_when_runtime_recovery_fails
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "original"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, original)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: original, reason: "prewrite"
      )
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        backup_root, roots: [directory]
      )
      File.binwrite(profile, candidate)
      validator_called = false
      requester = lambda do |method, endpoint, _body = nil|
        if [method, endpoint] == ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" }
          })]
        elsif [method, endpoint] == ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        elsif [method, endpoint] == ["PUT", "/configs?force=true"]
          [503, ""]
        else
          [404, ""]
        end
      end
      controller_requester = lambda do |_socket, method, endpoint, body = nil|
        requester.call(method, endpoint, body)
      end

      result = ClaudeEasy.stub(:controller_socket, "fixture.sock") do
        ClaudeEasy.stub(:controller_request, controller_requester) do
          ClaudeEasy.stub(:selected_profile_name, "friend") do
            ClaudeEasy.restore_backup(
              File.basename(backup), directories: [directory], backup_root: backup_root,
              expected_current_sha256: Digest::SHA256.hexdigest(candidate.b),
              validator: ->(_candidate) { validator_called = true; true }
            )
          end
        end
      end

      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
      refute validator_called
    end
  end

  def test_next_patch_recovers_backup_restore_killed_after_file_commit
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      runtime_marker = File.join(directory, "runtime-marker")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      older = YAML.dump(base_config.merge("subscription-marker" => "older-backup"))
      File.binwrite(profile, current)
      File.write(runtime_marker, "current")
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: older, reason: "prewrite"
      )
      ready_reader, ready_writer = IO.pipe
      gate_reader, gate_writer = IO.pipe
      child_id = nil
      begin
        child_id = fork do
          ready_reader.close
          gate_writer.close
          real_replace = ClaudeEasy.method(:transactional_compare_and_write_bytes)
          gated_replace = lambda do |*arguments, **keywords|
            replaced = real_replace.call(*arguments, **keywords)
            if replaced
              ready_writer.write(".")
              ready_writer.flush
              gate_reader.read(1)
            end
            replaced
          end
          ClaudeEasy.stub(:transactional_compare_and_write_bytes, gated_replace) do
            ClaudeEasy.restore_backup(
              File.basename(backup), directories: [directory], backup_root: backup_root,
              expected_current_sha256: Digest::SHA256.hexdigest(current.b),
              validator: ->(_candidate) { true }
            )
          end
          exit! 0
        end
        ready_writer.close
        gate_reader.close
        assert IO.select([ready_reader], nil, nil, 10), "backup restore never committed the file"
        ready_reader.read(1)
        Process.kill("KILL", child_id)
        _waited_id, status = Process.wait2(child_id)
        child_id = nil
        assert_equal 9, status.termsig
        assert_equal older.b, File.binread(profile)

        requester = lambda do |method, endpoint, body = nil|
          case [method, endpoint]
          when ["GET", "/proxies"]
            [200, JSON.generate("proxies" => {
              "Main" => { "type" => "Selector", "now" => "台湾家宽 01" }
            })]
          when ["GET", "/configs"]
            [200, JSON.generate("tun" => { "enable" => false })]
          when ["PUT", "/configs?force=true"]
            loaded = ClaudeEasy.load_yaml(File.read(JSON.parse(body).fetch("path")))
            File.write(runtime_marker, loaded.fetch("subscription-marker"))
            [204, ""]
          when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
            [204, ""]
          else
            if method == "GET" && endpoint.start_with?("/dns/query?")
              [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
            else
              [404, ""]
            end
          end
        end
        results = ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
          selected_name: "friend", validator: ->(_path) { false },
          auto_reload: true, requester: requester,
          connectivity_checker: -> { true }, usage_profile: 1
        )

        assert results.any? { |result| result.fetch(:status) == :validation_failed }
        assert_equal current.b, File.binread(profile)
        assert_equal "current", File.read(runtime_marker)
        refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
      ensure
        gate_writer.write(".") rescue nil
        Process.kill("KILL", child_id) rescue nil
        Process.waitpid(child_id) rescue nil
        [ready_reader, ready_writer, gate_reader, gate_writer].each { |io| io.close rescue nil }
      end
    end
  end

  def test_restore_backup_commits_transaction_only_after_active_runtime_check
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      older = YAML.dump(base_config.merge("subscription-marker" => "older-backup"))
      File.binwrite(profile, current)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: older, reason: "prewrite"
      )
      transaction_path = ClaudeEasy.profile_transaction_path(backup_root)
      activation = lambda do |result|
        assert File.exist?(transaction_path)
        assert_equal older.b, File.binread(profile)
        result.merge(reloaded: true)
      end

      result = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(current.b),
        validator: ->(_candidate) { true }, activation: activation
      )

      assert_equal :updated, result.fetch(:status)
      assert_equal true, result.fetch(:reloaded)
      refute File.exist?(transaction_path)
    end
  end

  def test_restore_backup_propagates_uncertain_commit_publication
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      older = YAML.dump(base_config.merge("subscription-marker" => "older"))
      File.binwrite(profile, current)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: older, reason: "prewrite"
      )
      journal_path = ClaudeEasy.profile_transaction_path(backup_root)
      real_sync = ClaudeEasy.method(:fsync_parent_directory)
      injected_sync = lambda do |path|
        if path == journal_path && File.binread(path) == ClaudeEasy::PROFILE_TRANSACTION_COMMITTED_BYTES
          raise IOError, "injected committed marker directory sync failure"
        end
        real_sync.call(path)
      end

      assert_raises(ClaudeEasy::ProfileCommitStateUncertainError) do
        ClaudeEasy.stub(:fsync_parent_directory, injected_sync) do
          ClaudeEasy.restore_backup(
            File.basename(backup), directories: [directory], backup_root: backup_root,
            expected_current_sha256: Digest::SHA256.hexdigest(current.b),
            validator: ->(_candidate) { true }
          )
        end
      end
      assert_equal older.b, File.binread(profile)
      assert_equal ClaudeEasy::PROFILE_TRANSACTION_COMMITTED_BYTES, File.binread(journal_path)
    end
  end

  def test_restore_backup_rolls_back_when_profile_three_rules_are_missing
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(base_config.merge("subscription-marker" => "restored"))
      File.binwrite(profile, current)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: restored, reason: "prewrite"
      )
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" },
            "台湾家宽 01" => { "type" => "Shadowsocks" },
            "AI" => { "type" => "Selector", "now" => "DIRECT" },
            "DIRECT" => { "type" => "Direct" }
          })]
        when ["PUT", "/configs?force=true"], ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end
      activation = lambda do |result|
        ClaudeEasy.activate_updated_profile(
          result, requester: requester, connectivity_checker: -> { true },
          require_tun: :preserve, require_safe_ai: true
        )
      end

      result = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(current.b),
        validator: ->(_candidate) { true }, activation: activation
      )

      assert_equal :reload_failed_rolled_back, result.fetch(:status)
      assert_equal current.b, File.binread(profile)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_restore_backup_keeps_transaction_when_active_runtime_rollback_is_pending
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      older = YAML.dump(base_config.merge("subscription-marker" => "older-backup"))
      File.binwrite(profile, current)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: older, reason: "prewrite"
      )
      runtime_marker = "current"
      reloads = 0
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"]
          reloads += 1
          if reloads == 1
            loaded = ClaudeEasy.load_yaml(File.read(JSON.parse(body).fetch("path")))
            runtime_marker = loaded.fetch("subscription-marker")
            [204, ""]
          else
            [401, ""]
          end
        when ["POST", "/cache/fakeip/flush"]
          [503, ""]
        else
          [404, ""]
        end
      end
      activation = lambda do |result|
        ClaudeEasy.activate_updated_profile(
          result, requester: requester, connectivity_checker: -> { true },
          require_tun: :preserve
        )
      end

      result = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(current.b),
        validator: ->(_candidate) { true }, activation: activation
      )

      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_equal current.b, File.binread(profile)
      assert_equal "older-backup", runtime_marker
      assert_equal 2, reloads
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_restore_backup_no_change_runtime_failure_stays_retryable
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config)
      File.binwrite(profile, current)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: current, reason: "prewrite"
      )
      runtime_marker = "stale"
      allow_reload = false
      reloads = 0
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"]
          reloads += 1
          if allow_reload
            loaded = ClaudeEasy.load_yaml(File.read(JSON.parse(body).fetch("path")))
            runtime_marker = loaded == ClaudeEasy.load_yaml(current) ? "current" : "other"
            [204, ""]
          else
            [503, ""]
          end
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end
      activation = lambda do |result|
        ClaudeEasy.activate_updated_profile(
          result, requester: requester, connectivity_checker: -> { true },
          require_tun: :preserve
        )
      end
      transaction_path = ClaudeEasy.profile_transaction_path(backup_root)

      result = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(current.b),
        validator: ->(_candidate) { true }, activation: activation
      )

      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_equal current.b, File.binread(profile)
      assert_equal "stale", runtime_marker
      assert_equal 2, reloads
      assert File.exist?(transaction_path)

      allow_reload = true
      results = ClaudeEasy.run(
        directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
        selected_name: "friend", validator: ->(_path) { false },
        auto_reload: true, requester: requester,
        connectivity_checker: -> { true }, usage_profile: 1
      )

      assert results.any? { |item| item.fetch(:status) == :validation_failed }
      assert_equal current.b, File.binread(profile)
      assert_equal "current", runtime_marker
      refute File.exist?(transaction_path)
    end
  end

  def test_restore_backup_rejects_a_retargeted_profile_symlink
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      first = File.join(directory, "first-target")
      second = File.join(directory, "second-target")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      changed = YAML.dump(base_config.merge("subscription-marker" => "changed"))
      File.binwrite(first, changed)
      File.binwrite(second, changed)
      File.symlink(first, profile)
      backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: original, reason: "prewrite"
      )

      result = ClaudeEasy.restore_backup(
        File.basename(backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: Digest::SHA256.hexdigest(changed.b),
        validator: lambda { |_candidate|
          File.unlink(profile)
          File.symlink(second, profile)
          true
        }
      )

      assert_equal :invalid_backup, result.fetch(:status)
      assert_equal changed.b, File.binread(first)
      assert_equal changed.b, File.binread(second)
    end
  end

  SUBSCRIPTION_AUTO_UPDATE_STATE_CASES = [
    ["0", :disabled], ["false", :disabled], ["1", :enabled], ["true", :enabled], [nil, :unknown]
  ]

  def test_subscription_auto_update_state_is_explicit
    SUBSCRIPTION_AUTO_UPDATE_STATE_CASES.each do |raw, expected|
      assert_equal expected, ClaudeEasy.subscription_auto_update_state(raw), raw.inspect
    end
  end

  def test_backup_helpers_tolerate_owned_file_permission_errors
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      FileUtils.mkdir_p(backup_root)
      existing = File.join(backup_root, "existing.backup")
      File.write(existing, "old")
      original_chmod = FileUtils.method(:chmod)
      chmod_with_owned_failure = lambda do |mode, path|
        raise Errno::EPERM if path == existing

        original_chmod.call(mode, path)
      end
      FileUtils.stub(:chmod, chmod_with_owned_failure) do
        assert_equal backup_root, ClaudeEasy.secure_backup_root!(backup_root)
      end
      assert_equal "old", File.read(existing)
    end
  end

  def test_secure_backup_root_durably_publishes_each_new_directory
    Dir.mktmpdir do |directory|
      state_root = File.join(directory, "ClaudeEasy")
      backup_root = File.join(state_root, "backups")
      syncs = []

      result = ClaudeEasy.stub(:fsync_directory, ->(path) {
        syncs << path
        true
      }) do
        ClaudeEasy.secure_backup_root!(backup_root)
      end

      assert_equal backup_root, result
      assert_equal [
        File.dirname(directory),
        state_root, directory,
        backup_root, state_root
      ], syncs
      assert_equal 0o700, File.stat(state_root).mode & 0o777
      assert_equal 0o700, File.stat(backup_root).mode & 0o777
    end
  end

  def test_secure_backup_root_accepts_a_concurrently_created_private_directory
    Dir.mktmpdir do |directory|
      target = File.join(directory, "backups")
      real_mkdir = Dir.method(:mkdir)
      injected = false
      racing_mkdir = lambda do |path, mode|
        unless injected
          injected = true
          real_mkdir.call(path, mode)
          raise Errno::EEXIST
        end
        real_mkdir.call(path, mode)
      end

      result = Dir.stub(:mkdir, racing_mkdir) do
        ClaudeEasy.ensure_durable_private_directory(target)
      end

      assert injected
      assert_equal target, result
      assert File.directory?(target)
    end
  end

  def test_secure_backup_root_directory_sync_failure_stops_before_state_files
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "ClaudeEasy", "backups")

      ClaudeEasy.stub(:fsync_directory, ->(_path) { raise IOError, "injected directory sync failure" }) do
        assert_raises(IOError) do
          ClaudeEasy.write_auto_update_ownership_state(
            backup_root, "com.metacubex.ClashX.meta", "1", "prepared"
          )
        end
      end

      refute File.exist?(ClaudeEasy.auto_update_ownership_path(backup_root))
    end
  end

  def test_secure_backup_root_retry_resynchronizes_a_directory_left_by_a_failed_publication
    Dir.mktmpdir do |directory|
      state_root = File.join(directory, "ClaudeEasy")
      backup_root = File.join(state_root, "backups")

      ClaudeEasy.stub(:fsync_directory, lambda { |path|
        raise IOError, "injected parent sync failure" if path == directory

        true
      }) do
        assert_raises(IOError) { ClaudeEasy.secure_backup_root!(backup_root) }
      end
      assert Dir.exist?(state_root)
      refute Dir.exist?(backup_root)

      retry_syncs = []
      ClaudeEasy.stub(:fsync_directory, ->(path) {
        retry_syncs << path
        true
      }) do
        assert_equal backup_root, ClaudeEasy.secure_backup_root!(backup_root)
      end

      assert_operator retry_syncs.index(directory), :<, retry_syncs.index(backup_root)
    end
  end

  def test_versioned_backup_retries_an_exclusive_name_collision
    Dir.mktmpdir do |directory|
      source = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.write(source, "original")
      original_rename = ClaudeEasyDarwinFilesystem.method(:rename_exclusive)
      attempts = 0
      colliding_rename = lambda do |from, to|
        attempts += 1
        raise Errno::EEXIST if attempts == 1

        original_rename.call(from, to)
      end

      backup = ClaudeEasyDarwinFilesystem.stub(:rename_exclusive, colliding_rename) do
        ClaudeEasy.create_versioned_backup(source, backup_root)
      end

      assert_equal 2, attempts
      assert_equal "original", File.read(backup)
    end
  end

  def test_versioned_backup_syncs_its_directory_after_the_file_is_complete
    Dir.mktmpdir do |directory|
      source = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.binwrite(source, "original")
      FileUtils.mkdir_p(backup_root)
      syncs = []

      backup = ClaudeEasy.stub(:fsync_directory, lambda { |path|
        if path == backup_root
          candidates = Dir.glob(File.join(backup_root, "*.backup"))
          assert_equal 1, candidates.length
          assert_equal "original", File.binread(candidates.fetch(0))
        end
        syncs << path
        true
      }) do
        ClaudeEasy.create_versioned_backup(source, backup_root)
      end

      assert_equal [directory, backup_root], syncs
      assert_equal "original", File.binread(backup)
    end
  end

  def test_backup_boundaries_reject_unsafe_roots_ids_and_collision_exhaustion
    assert_empty ClaudeEasy.profile_paths("/path/that/does/not/exist")
    assert_empty ClaudeEasy.list_backups("/path/that/does/not/exist")
    Dir.mktmpdir do |directory|
      real_root = File.join(directory, "real-backups")
      FileUtils.mkdir_p(real_root)
      linked_root = File.join(directory, "linked-backups")
      File.symlink(real_root, linked_root)
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.secure_backup_root!(linked_root)
      end
      assert_empty ClaudeEasy.list_backups(linked_root)

      file_root = File.join(directory, "not-a-directory")
      File.write(file_root, "fixture")
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.secure_backup_root!(file_root)
      end

      source = File.join(directory, "friend.yaml")
      File.write(source, "original")
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.create_versioned_backup(source, real_root, reason: "../unsafe")
      end
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.resolve_backup_id("../friend.backup", real_root)
      end

      symlinked_backup = File.join(real_root, "fixture.backup")
      File.symlink(source, symlinked_backup)
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.resolve_backup_id(File.basename(symlinked_backup), real_root)
      end

      attempts = 0
      collision = lambda do |*_arguments|
        attempts += 1
        raise Errno::EEXIST
      end
      ClaudeEasyDarwinFilesystem.stub(:rename_exclusive, collision) do
        assert_raises(IOError) do
          ClaudeEasy.create_versioned_backup(source, real_root)
        end
      end
      assert_equal 100, attempts
      assert_empty Dir.glob(File.join(real_root, "*--prewrite--*.backup"))
    end
  end

  def test_restore_backup_rejects_invalid_bytes_validation_failures_and_commit_conflicts
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      changed = YAML.dump(base_config.merge("subscription-marker" => "changed"))
      File.write(profile, changed)
      valid_backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: original, reason: "prewrite"
      )
      expected_hash = Digest::SHA256.hexdigest(changed.b)

      timeout = ClaudeEasy.restore_backup(
        File.basename(valid_backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: expected_hash, validator: ->(_path) { :timeout }
      )
      assert_equal :validation_timeout, timeout.fetch(:status)
      assert_equal changed.b, File.binread(profile)

      rejected = ClaudeEasy.restore_backup(
        File.basename(valid_backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: expected_hash, validator: ->(_path) { false }
      )
      assert_equal :validation_failed, rejected.fetch(:status)
      assert_equal changed.b, File.binread(profile)

      ClaudeEasy.stub(:transactional_compare_and_write_bytes, false) do
        conflict = ClaudeEasy.restore_backup(
          File.basename(valid_backup), directories: [directory], backup_root: backup_root,
          expected_current_sha256: expected_hash, validator: ->(_path) { true }
        )
        assert_equal :restore_conflict, conflict.fetch(:status)
      end
      assert_equal changed.b, File.binread(profile)

      invalid_backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: "\xFF".b, reason: "prewrite"
      )
      invalid = ClaudeEasy.restore_backup(
        File.basename(invalid_backup), directories: [directory], backup_root: backup_root,
        expected_current_sha256: expected_hash, validator: ->(_path) { true }
      )
      assert_equal :invalid_backup, invalid.fetch(:status)
      assert_equal changed.b, File.binread(profile)
    end
  end

  def test_restore_backup_rejects_concurrent_changes_while_publishing_either_transaction
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      replacement = YAML.dump(base_config.merge("subscription-marker" => "replacement"))
      File.binwrite(profile, current)
      same_backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: current, reason: "prewrite"
      )
      different_backup = ClaudeEasy.create_versioned_backup(
        profile, backup_root, content: replacement, reason: "prewrite"
      )
      expected_hash = Digest::SHA256.hexdigest(current)

      ClaudeEasy.stub(:prepare_profile_transaction, ->(*_args) {
        raise ClaudeEasy::ConcurrentProfileChangeError
      }) do
        [same_backup, different_backup].each do |backup|
          result = ClaudeEasy.restore_backup(
            File.basename(backup), directories: [directory], backup_root: backup_root,
            expected_current_sha256: expected_hash, validator: ->(_path) { true }
          )
          assert_equal :restore_conflict, result.fetch(:status)
        end
      end
      assert_equal current.b, File.binread(profile)
    end
  end

  def test_restore_backup_classifies_invalid_and_io_failures
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      ClaudeEasy.stub(:resolve_backup_id, ->(*_args) { raise ClaudeEasy::InvalidConfigError }) do
        result = ClaudeEasy.restore_backup(
          "bad.backup", directories: [], backup_root: backup_root,
          expected_current_sha256: "0" * 64, validator: ->(_path) { true }
        )
        assert_equal :invalid_backup, result.fetch(:status)
      end
      ClaudeEasy.stub(:resolve_backup_id, ->(*_args) { raise IOError }) do
        result = ClaudeEasy.restore_backup(
          "bad.backup", directories: [], backup_root: backup_root,
          expected_current_sha256: "0" * 64, validator: ->(_path) { true }
        )
        assert_equal :io_error, result.fetch(:status)
      end
    end
  end

  def test_disables_subscription_auto_update_through_defaults_and_verifies_it
    Dir.mktmpdir do |directory|
      calls = []
      values = ["1", "1", "0"]
      runner = lambda do |*arguments, **_options|
        calls << arguments
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[1] == "write"
          ["", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          [values.shift, "", Struct.new(:success?).new(true)]
        else
          flunk("unexpected command: #{arguments.inspect}")
        end
      end

      result = ClaudeEasy.disable_subscription_auto_update(
        backup_root: directory, runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
      )

      assert_equal :disabled, result.fetch(:status)
      assert_equal "com.metacubex.ClashX.meta", result.fetch(:domain)
      assert_includes calls, [
        "/usr/bin/defaults", "write", "com.metacubex.ClashX.meta",
        "kAutoUpdateEnable", "-bool", "false"
      ]
      backups = Dir.glob(File.join(directory, "*--preference--*.backup"))
      assert_equal 1, backups.length
      assert_equal 0, File.stat(backups.first).mode & 0o077
      backup = JSON.parse(File.read(backups.first))
      assert_equal "kAutoUpdateEnable", backup.fetch("Key")
      assert_equal "1", backup.fetch("Value")
      refute_includes File.read(backups.first), "kRemoteConfigs"
      state = ClaudeEasy.auto_update_ownership_state(directory)
      assert_equal 3, state.fetch("Version")
      assert_equal "com.metacubex.ClashX.meta", state.fetch("Domain")
      assert_equal "kAutoUpdateEnable", state.fetch("Key")
      assert_equal "1", state.fetch("OriginalValue")
      assert_equal "installed", state.fetch("Phase")
    end
  end

  def test_auto_update_ownership_directory_sync_failure_prevents_the_preference_write
    Dir.mktmpdir do |directory|
      calls = []
      runner = lambda do |*arguments, **_options|
        calls << arguments
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          ["1", "", Struct.new(:success?).new(true)]
        elsif arguments[1] == "write"
          flunk "defaults write ran before the ownership directory was durable"
        else
          flunk("unexpected command: #{arguments.inspect}")
        end
      end

      ClaudeEasy.stub(:fsync_parent_directory, ->(_path) { raise IOError, "injected directory sync failure" }) do
        assert_raises(IOError) do
          ClaudeEasy.disable_subscription_auto_update(
            backup_root: directory, runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
          )
        end
      end

      refute calls.any? { |arguments| arguments[1] == "write" }
      ownership = ClaudeEasy.auto_update_ownership_state(directory)
      assert_equal "prepared", ownership.fetch("Phase")
    end
  end

  def test_auto_update_ownership_initial_publication_is_complete_or_absent
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      ClaudeEasyDarwinFilesystem.stub(
        :rename_exclusive,
        ->(_source, _destination) { raise IOError, "injected publication failure" }
      ) do
        assert_raises(IOError) do
          ClaudeEasy.write_auto_update_ownership_state(
            directory, "com.metacubex.ClashX.meta", "1", "prepared"
          )
        end
      end

      refute File.exist?(state_path)
      assert_empty Dir.glob(File.join(directory, ".claude-easy-auto-update-state-*"))

      ownership = ClaudeEasy.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "prepared"
      )
      assert_equal "prepared", ownership.fetch("Phase")
    end
  end

  def test_auto_update_ownership_initial_publication_never_overwrites_a_racing_file
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      outside_bytes = "concurrent-owner\n".b
      publisher = ClaudeEasyDarwinFilesystem.method(:rename_exclusive)
      racing_publisher = lambda do |source, destination|
        File.binwrite(destination, outside_bytes)
        publisher.call(source, destination)
      end

      ClaudeEasyDarwinFilesystem.stub(:rename_exclusive, racing_publisher) do
        assert_raises(SystemCallError) do
          ClaudeEasy.write_auto_update_ownership_state(
            directory, "com.metacubex.ClashX.meta", "1", "prepared"
          )
        end
      end

      assert_equal outside_bytes, File.binread(state_path)
      assert_empty Dir.glob(File.join(directory, ".claude-easy-auto-update-state-*"))
    end
  end

  def test_auto_update_disable_is_idempotent_and_does_not_create_backup_when_already_off
    Dir.mktmpdir do |directory|
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          ["0", "", Struct.new(:success?).new(true)]
        else
          flunk("automatic update was already disabled but tried to write: #{arguments.inspect}")
        end
      end

      result = ClaudeEasy.disable_subscription_auto_update(
        backup_root: directory, runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
      )

      assert_equal :already_disabled, result.fetch(:status)
      assert_empty Dir.glob(File.join(directory, "*.backup"))
      refute File.exist?(File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json"))
    end
  end

  def test_auto_update_disable_completes_a_prepared_disabled_operation_without_releasing_it
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.write(state_path, JSON.generate(
        "Version" => 2,
        "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable",
        "OriginalValue" => "1",
        "Phase" => "prepared"
      ))
      values = %w[0]
      writes = []
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[1] == "write"
          writes << arguments.last
          ["", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          [values.shift, "", Struct.new(:success?).new(true)]
        else
          flunk("unexpected command: #{arguments.inspect}")
        end
      end

      result = ClaudeEasy.disable_subscription_auto_update(
        backup_root: directory, runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
      )

      assert_equal :disabled, result.fetch(:status)
      assert_empty writes
      assert_empty values
      state = ClaudeEasy.auto_update_ownership_state(directory)
      assert_equal "installed", state.fetch("Phase")
      assert_equal %w[prepared installed],
                   File.readlines(state_path).map { |line| JSON.parse(line).fetch("Phase") }
    end
  end

  def test_auto_update_disable_reuses_owned_recovery_state_without_a_release_window
    %w[prepared installed].each do |phase|
      Dir.mktmpdir do |directory|
        state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
        File.write(state_path, JSON.generate(
          "Version" => 3,
          "Domain" => "com.metacubex.ClashX.meta",
          "Key" => "kAutoUpdateEnable",
          "OriginalValue" => "1",
          "Phase" => phase
        ) + "\n")
        exports = 0
        runner = lambda do |*arguments, **_options|
          if arguments[1] == "export"
            exports += 1
            next ["plist", "", Struct.new(:success?).new(true)] if exports == 1

            next ["", "injected retry failure", Struct.new(:success?).new(false)]
          elsif arguments[0] == "/usr/bin/plutil"
            ["1", "", Struct.new(:success?).new(true)]
          else
            flunk("failed retry reached a preference write: #{arguments.inspect}")
          end
        end

        assert_raises(ClaudeEasy::InvalidConfigError) do
          ClaudeEasy.disable_subscription_auto_update(
            backup_root: directory, runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
          )
        end

        state = ClaudeEasy.auto_update_ownership_state(directory)
        assert_equal "prepared", state.fetch("Phase")
        phases = File.readlines(state_path).map { |line| JSON.parse(line).fetch("Phase") }
        refute_includes phases, "released"
      end
    end
  end

  def test_auto_update_disable_rejects_a_change_before_the_preference_write
    Dir.mktmpdir do |directory|
      values = %w[1 0]
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          [values.shift, "", Struct.new(:success?).new(true)]
        else
          flunk("changed preference reached a write: #{arguments.inspect}")
        end
      end

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.disable_subscription_auto_update(
          backup_root: directory, runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
        )
      end
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      assert File.file?(state_path)
      assert_equal "prepared", ClaudeEasy.auto_update_ownership_state(directory).fetch("Phase")
      refute_includes File.read(state_path), '"Phase":"released"'
      assert_empty values
    end
  end

  def test_auto_update_helpers_fail_closed_on_malformed_state_and_runner_errors
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.binwrite(state_path, "\xFF".b)
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.auto_update_ownership_state(directory)
      end
    end
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.binwrite(state_path, "{")
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.auto_update_ownership_state(directory)
      end
    end

    failing_runner = ->(*_arguments, **_options) { raise IOError, "injected runner failure" }
    assert_nil ClaudeEasy.defaults_export_domain(runner: failing_runner)
    assert_nil ClaudeEasy.defaults_export_named_domain("com.metacubex.ClashX.meta", runner: failing_runner)
    assert_equal "", ClaudeEasy.plist_raw_value("plist", "key", runner: failing_runner)
  end

  def test_defaults_bind_to_the_unique_clashx_bundle_identifier
    Dir.mktmpdir do |directory|
      app = File.join(directory, "ClashX Meta.app")
      plist = File.join(app, "Contents", "Info.plist")
      FileUtils.mkdir_p(File.dirname(plist))
      File.write(plist, "fixture")
      alternate = ClaudeEasy::AUTO_UPDATE_DOMAINS.last
      success = Struct.new(:success?).new(true)
      calls = []
      runner = lambda do |*arguments, **_options|
        calls << arguments
        if arguments[0] == "/usr/bin/plutil"
          [alternate, "", success]
        elsif arguments[0] == "/usr/bin/defaults" && arguments[2] == alternate
          ["alternate plist", "", success]
        else
          flunk("read the stale preference domain: #{arguments.inspect}")
        end
      end
      identity = {
        pid: 123, started: "same",
        executable: File.join(app, "Contents", "MacOS", "ClashX Meta")
      }

      domain = ClaudeEasy.clashx_preference_domain(
        app_paths: [File.join(directory, "Other.app")],
        identity_reader: -> { identity }, runner: runner
      )
      result = ClaudeEasy.defaults_export_domain(runner: runner, domain: domain)

      assert_equal alternate, domain
      assert_equal alternate, result.fetch(:domain)
      refute calls.any? { |arguments| arguments[0] == "/usr/bin/defaults" && arguments[2] != alternate }
    end
  end

  def test_stopped_client_accepts_duplicate_apps_only_when_their_bundle_domain_matches
    Dir.mktmpdir do |directory|
      apps = %w[System User].map do |name|
        app = File.join(directory, name, "ClashX Meta.app")
        FileUtils.mkdir_p(File.join(app, "Contents"))
        File.write(File.join(app, "Contents", "Info.plist"), name)
        app
      end
      success = Struct.new(:success?).new(true)
      identifiers = [ClaudeEasy::AUTO_UPDATE_DOMAINS.first, ClaudeEasy::AUTO_UPDATE_DOMAINS.first]
      runner = ->(*_arguments, **_options) { [identifiers.shift, "", success] }
      assert_equal ClaudeEasy::AUTO_UPDATE_DOMAINS.first,
                   ClaudeEasy.clashx_preference_domain(
                     app_paths: apps, identity_reader: -> { nil }, runner: runner
                   )

      identifiers = ClaudeEasy::AUTO_UPDATE_DOMAINS.dup
      runner = ->(*_arguments, **_options) { [identifiers.shift, "", success] }
      assert_nil ClaudeEasy.clashx_preference_domain(
        app_paths: apps, identity_reader: -> { nil }, runner: runner
      )
      assert_nil ClaudeEasy.clashx_preference_domain(
        app_paths: apps, identity_reader: -> { raise IOError }, runner: runner
      )
    end
  end

  def test_auto_update_disable_rejects_ownership_from_an_old_bundle_identifier
    Dir.mktmpdir do |directory|
      ClaudeEasy.write_auto_update_ownership_state(
        directory, ClaudeEasy::AUTO_UPDATE_DOMAINS.first, "1", "installed"
      )
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.disable_subscription_auto_update(
          backup_root: directory,
          runner: ->(*_arguments, **_options) { flunk "stale preference domain was read" },
          preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.last
        )
      end
    end
  end

  def test_stale_auto_update_ownership_cannot_be_deleted
    Dir.mktmpdir do |directory|
      ownership = ClaudeEasy.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "prepared"
      )
      path = ownership.fetch("Path")
      File.write(path, JSON.generate(
        "Version" => 2,
        "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable",
        "OriginalValue" => "different",
        "Phase" => "prepared"
      ))

      assert_raises(IOError) { ClaudeEasy.delete_auto_update_ownership_state(ownership) }
      assert File.file?(path)
      assert_includes File.read(path), "different"
    end
  end

  def test_auto_update_ownership_release_preserves_an_atomic_refresh
    Dir.mktmpdir do |directory|
      ownership = ClaudeEasy.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "prepared"
      )
      path = ownership.fetch("Path")
      external_bytes = (JSON.generate(
        "Version" => 3,
        "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable",
        "OriginalValue" => "1",
        "Phase" => "installed"
      ) + "\n").b
      external_identity = nil
      checks = 0
      real_check = ClaudeEasy.method(:locked_source_current?)
      check_with_refresh = lambda do |source, checked_path, write_path|
        checks += 1
        if checks == 2
          replacement = File.join(directory, "external-state.json")
          File.binwrite(replacement, external_bytes)
          File.rename(replacement, path)
          current = File.stat(path)
          external_identity = [current.dev, current.ino]
        end
        real_check.call(source, checked_path, write_path)
      end

      ClaudeEasy.stub(:locked_source_current?, check_with_refresh) do
        assert_raises(IOError) { ClaudeEasy.delete_auto_update_ownership_state(ownership) }
      end

      current = File.stat(path)
      assert_equal external_bytes, File.binread(path)
      assert_equal external_identity, [current.dev, current.ino]
      assert_equal "installed", ClaudeEasy.auto_update_ownership_state(directory).fetch("Phase")
    end
  end

  def test_auto_update_ownership_log_recovers_an_interrupted_tail
    Dir.mktmpdir do |directory|
      ownership = ClaudeEasy.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "prepared"
      )
      File.open(ownership.fetch("Path"), "ab") { |file| file.write('{"Version":3,"Domain":') }

      recovered = ClaudeEasy.auto_update_ownership_state(directory)
      assert_equal "prepared", recovered.fetch("Phase")
      installed = ClaudeEasy.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "installed", existing: recovered
      )

      assert_equal "installed", installed.fetch("Phase")
      lines = File.binread(ownership.fetch("Path")).lines
      assert_equal 2, lines.length
      lines.each { |line| assert_kind_of Hash, JSON.parse(line) }
    end
  end

  def test_auto_update_ownership_reuses_only_a_released_existing_log
    Dir.mktmpdir do |directory|
      ownership = ClaudeEasy.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "prepared"
      )
      ClaudeEasy.delete_auto_update_ownership_state(ownership)

      replacement = ClaudeEasy.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "prepared"
      )

      assert_equal "prepared", replacement.fetch("Phase")
      assert_equal %w[prepared released prepared],
                   File.readlines(replacement.fetch("Path")).map { |line|
                     JSON.parse(line).fetch("Phase")
                   }

      assert_raises(IOError) do
        ClaudeEasy.write_auto_update_ownership_state(
          directory, "com.metacubex.ClashX.meta", "1", "prepared"
        )
      end
    end
  end

  def test_auto_update_ownership_append_reports_a_failed_write
    Dir.mktmpdir do |directory|
      path = File.join(directory, "state.json")
      original = "original\n".b
      File.binwrite(path, original)
      stat = File.stat(path)
      state = {
        "Path" => path, "Bytes" => original, "ValidBytes" => original,
        "Identity" => [stat.dev, stat.ino]
      }
      event = {
        "Version" => 3, "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable", "OriginalValue" => "1", "Phase" => "released"
      }
      fake = Object.new
      fake.define_singleton_method(:flock) { |_mode| true }
      fake.define_singleton_method(:rewind) { 0 }
      fake.define_singleton_method(:stat) { stat }
      fake.define_singleton_method(:read) { original }
      fake.define_singleton_method(:truncate) { |_length| 0 }
      fake.define_singleton_method(:seek) { |*_arguments| 0 }
      fake.define_singleton_method(:write) { |_bytes| raise IOError, "injected append failure" }
      fake.define_singleton_method(:flush) { nil }
      fake.define_singleton_method(:fsync) { 0 }

      File.stub(:open, ->(*_arguments, &block) { block.call(fake) }) do
        error = assert_raises(IOError) do
          ClaudeEasy.append_auto_update_ownership_event(state, event)
        end
        assert_includes error.message, "injected append failure"
      end
    end
  end

  def test_auto_update_ownership_append_failure_preserves_the_fsynced_prefix
    Dir.mktmpdir do |directory|
      path = File.join(directory, "state.json")
      original = (JSON.generate(
        "Version" => 3, "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable", "OriginalValue" => "1", "Phase" => "prepared"
      ) + "\n").b
      File.binwrite(path, original)
      stat = File.stat(path)
      state = {
        "Path" => path, "Bytes" => original, "ValidBytes" => original,
        "Identity" => [stat.dev, stat.ino]
      }
      event = {
        "Version" => 3, "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable", "OriginalValue" => "1", "Phase" => "installed"
      }
      fake = Object.new
      bytes = original.dup
      position = 0
      writes = 0
      fake.define_singleton_method(:flock) { |_mode| true }
      fake.define_singleton_method(:stat) { stat }
      fake.define_singleton_method(:rewind) { position = 0 }
      fake.define_singleton_method(:read) { bytes.dup }
      fake.define_singleton_method(:truncate) do |length|
        bytes = bytes.byteslice(0, length)
        position = [position, length].min
        length
      end
      fake.define_singleton_method(:seek) do |_offset, _whence|
        position = bytes.bytesize
      end
      fake.define_singleton_method(:write) do |value|
        writes += 1
        fragment = value.byteslice(0, [value.bytesize / 2, 1].max)
        bytes[position, fragment.bytesize] = fragment
        position += fragment.bytesize
        raise IOError, writes == 1 ? "injected append failure" : "injected compensation failure"
      end
      fake.define_singleton_method(:flush) { nil }
      fake.define_singleton_method(:fsync) { 0 }

      ClaudeEasy.stub(:locked_source_current?, true) do
        File.stub(:open, ->(*_arguments, &block) { block.call(fake) }) do
          assert_raises(IOError) do
            ClaudeEasy.append_auto_update_ownership_event(state, event)
          end
        end
      end

      assert_equal 1, writes
      assert bytes.start_with?(original)
      parsed = JSON.parse(bytes.byteslice(0, original.bytesize))
      assert_equal "prepared", parsed.fetch("Phase")
    end
  end

  def test_installed_auto_update_ownership_is_idempotent
    Dir.mktmpdir do |directory|
      ClaudeEasy.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "installed"
      )
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          ["0", "", Struct.new(:success?).new(true)]
        else
          flunk("idempotent disable tried to write: #{arguments.inspect}")
        end
      end

      result = ClaudeEasy.disable_subscription_auto_update(
        backup_root: directory, runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
      )

      assert_equal :already_disabled_owned, result.fetch(:status)
      assert_equal ClaudeEasy.auto_update_ownership_path(directory), result.fetch(:ownership)
    end
  end

  def test_auto_update_disable_preserves_recovery_state_for_each_failure_stage
    status = Struct.new(:success?)
    run_case = lambda do |values, write_success:, installed_state_failure:, &assertion|
      Dir.mktmpdir do |directory|
        runner = lambda do |*arguments, **_options|
          if arguments[1] == "export"
            ["plist", "", status.new(true)]
          elsif arguments[1] == "write"
            ["", "injected defaults failure", status.new(write_success)]
          elsif arguments[0] == "/usr/bin/plutil"
            [values.shift, "", status.new(true)]
          else
            flunk("unexpected command: #{arguments.inspect}")
          end
        end
        original_writer = ClaudeEasy.method(:write_auto_update_ownership_state)
        state_writer = lambda do |root, domain, original, phase, existing: nil|
          raise IOError, "injected installed-state failure" if installed_state_failure && phase == "installed"

          original_writer.call(root, domain, original, phase, existing: existing)
        end
        ClaudeEasy.stub(:enable_subscription_auto_update, ->(**_args) {
          flunk "disable must leave a durable recovery intent instead of opening a release window"
        }) do
          ClaudeEasy.stub(:write_auto_update_ownership_state, state_writer) do
            assertion.call(directory, runner)
          end
        end
      end
    end

    [
      [%w[1 1], false, false, "无法关闭 ClashX Meta"],
      [%w[1 1 1], true, false, "回读失败"],
      [%w[1 1 0], true, true, "injected installed-state failure"]
    ].each do |values, write_success, state_failure, message|
      run_case.call(
        values, write_success: write_success,
        installed_state_failure: state_failure
      ) do |directory, runner|
        error = assert_raises(IOError) do
          ClaudeEasy.disable_subscription_auto_update(
            backup_root: directory, runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
          )
        end
        assert_includes error.message, message
        assert_equal "prepared", ClaudeEasy.auto_update_ownership_state(directory).fetch("Phase")
      end
    end
  end

  def test_owned_auto_update_restore_rejects_an_unknown_live_value
    Dir.mktmpdir do |directory|
      ClaudeEasy.write_auto_update_ownership_state(
        directory, "com.metacubex.ClashX.meta", "1", "installed"
      )
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          ["mystery", "", Struct.new(:success?).new(true)]
        else
          flunk("unknown value reached a write: #{arguments.inspect}")
        end
      end

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.restore_owned_subscription_auto_update(backup_root: directory, runner: runner)
      end
    end
  end

  def test_restores_only_owned_subscription_auto_update_state
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.write(state_path, JSON.generate(
        "Version" => 1,
        "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable",
        "OriginalState" => "enabled",
        "InstalledState" => "disabled"
      ))
      calls = []
      values = ["0", "1"]
      runner = lambda do |*arguments, **_options|
        calls << arguments
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[1] == "write"
          ["", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          [values.shift, "", Struct.new(:success?).new(true)]
        else
          flunk("unexpected command: #{arguments.inspect}")
        end
      end

      result = ClaudeEasy.restore_owned_subscription_auto_update(backup_root: directory, runner: runner)

      assert_equal :restored, result.fetch(:status)
      assert_includes calls, [
        "/usr/bin/defaults", "write", "com.metacubex.ClashX.meta",
        "kAutoUpdateEnable", "-bool", "true"
      ]
      assert File.file?(state_path)
      assert_nil ClaudeEasy.auto_update_ownership_state(directory)
      assert_equal "released", ClaudeEasy.auto_update_ownership_record(directory).fetch("Phase")
    end
  end

  def test_owned_auto_update_restore_accepts_a_user_already_restored_value
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.write(state_path, JSON.generate(
        "Version" => 1,
        "Domain" => "com.metacubex.ClashX.meta",
        "Key" => "kAutoUpdateEnable",
        "OriginalState" => "enabled",
        "InstalledState" => "disabled"
      ))
      runner = lambda do |*arguments, **_options|
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          ["1", "", Struct.new(:success?).new(true)]
        else
          flunk("already restored preference was overwritten: #{arguments.inspect}")
        end
      end

      result = ClaudeEasy.restore_owned_subscription_auto_update(backup_root: directory, runner: runner)

      assert_equal :already_restored, result.fetch(:status)
      assert File.file?(state_path)
      assert_nil ClaudeEasy.auto_update_ownership_state(directory)
      assert_equal "released", ClaudeEasy.auto_update_ownership_record(directory).fetch("Phase")
    end
  end

  def test_owned_auto_update_restore_does_nothing_without_an_ownership_state
    Dir.mktmpdir do |directory|
      result = ClaudeEasy.restore_owned_subscription_auto_update(
        backup_root: directory,
        runner: ->(*arguments, **_options) { flunk("unexpected preference access: #{arguments.inspect}") }
      )

      assert_equal :not_owned, result.fetch(:status)
    end
  end

  def test_owned_auto_update_restore_rejects_an_invalid_state_before_reading_preferences
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.write(state_path, '{"Version":1,"Domain":"attacker.invalid","Key":"kAutoUpdateEnable"}')

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.restore_owned_subscription_auto_update(
          backup_root: directory,
          runner: ->(*arguments, **_options) { flunk("invalid state reached preferences: #{arguments.inspect}") }
        )
      end
      assert File.file?(state_path)
    end
  end

  def test_auto_update_disable_restores_the_preference_when_ownership_state_cannot_be_recorded
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "clashx-meta-kAutoUpdateEnable.state.json")
      File.write(state_path, '{"Version":1,"Domain":"attacker.invalid"}')
      calls = []
      values = ["1", "0", "0", "1"]
      runner = lambda do |*arguments, **_options|
        calls << arguments
        if arguments[1] == "export"
          ["plist", "", Struct.new(:success?).new(true)]
        elsif arguments[1] == "write"
          ["", "", Struct.new(:success?).new(true)]
        elsif arguments[0] == "/usr/bin/plutil"
          [values.shift, "", Struct.new(:success?).new(true)]
        else
          flunk("unexpected command: #{arguments.inspect}")
        end
      end

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.disable_subscription_auto_update(
          backup_root: directory, runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
        )
      end
      refute calls.any? { |arguments| arguments[1] == "write" }
      assert File.file?(state_path)
    end
  end

  def test_enables_subscription_auto_update_and_verifies_the_result
    calls = []
    values = ["0", "1"]
    runner = lambda do |*arguments, **_options|
      calls << arguments
      if arguments[1] == "export"
        ["plist", "", Struct.new(:success?).new(true)]
      elsif arguments[1] == "write"
        ["", "", Struct.new(:success?).new(true)]
      elsif arguments[0] == "/usr/bin/plutil"
        [values.shift, "", Struct.new(:success?).new(true)]
      else
        flunk("unexpected command: #{arguments.inspect}")
      end
    end

    result = ClaudeEasy.enable_subscription_auto_update(
      runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
    )

    assert_equal :enabled, result.fetch(:status)
    assert_includes calls, [
      "/usr/bin/defaults", "write", "com.metacubex.ClashX.meta",
      "kAutoUpdateEnable", "-bool", "true"
    ]
  end

  def test_remote_subscription_records_map_every_client_entry_without_exposing_urls
    Dir.mktmpdir do |directory|
      %w[MESL Yue Express].each { |name| File.write(File.join(directory, "#{name}.yaml"), YAML.dump(base_config)) }
      records = %w[MESL Yue Express].map.with_index do |name, index|
        { "name" => name, "url" => "https://subscriptions.invalid/private-#{index}", "updateTime" => 100 + index }
      end
      raw = Base64.strict_encode64(JSON.generate(records))

      parsed = ClaudeEasy.remote_subscription_records(raw)
      targets = ClaudeEasy.remote_subscription_targets([directory], parsed)

      assert_equal 3, targets.length
      assert_equal %w[Express MESL Yue], targets.map { |target| File.basename(target.fetch(:path), ".yaml") }.sort
      refute_includes JSON.generate(targets.map { |target| target.reject { |key, _value| key == :url } }), "subscriptions.invalid"
    end
  end

  def test_profile_enumeration_and_remote_mapping_reject_symlink_entries
    Dir.mktmpdir do |directory|
      target = File.join(directory, "actual.yaml")
      link = File.join(directory, "friend.yaml")
      File.binwrite(target, YAML.dump(base_config))
      File.symlink("actual.yaml", link)

      refute_includes ClaudeEasy.profile_paths(directory), link
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.remote_subscription_targets(
          [directory], [{ name: "friend", url: "https://subscriptions.invalid/friend" }]
        )
      end
      assert_equal YAML.dump(base_config).b, File.binread(target)
    end
  end

  def test_remote_subscription_manifest_rejects_unsafe_and_ambiguous_records
    encode = ->(records) { Base64.strict_encode64(JSON.generate(records)) }
    invalid_records = [
      {},
      [],
      [nil],
      [{ "name" => "", "url" => "https://example.invalid/subscription" }],
      [{ "name" => "friend", "url" => "" }],
      [{ "name" => "friend", "url" => "http://example.invalid/subscription" }],
      [{ "name" => "nested/friend", "url" => "https://example.invalid/subscription" }],
      [{ "name" => "nested\\friend", "url" => "https://example.invalid/subscription" }],
      [{ "name" => "friend\0hidden", "url" => "https://example.invalid/subscription" }]
    ]
    invalid_records.each do |records|
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.remote_subscription_records(encode.call(records))
      end
    end

    Dir.mktmpdir do |directory|
      record = { name: "friend", url: "https://example.invalid/subscription" }
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.remote_subscription_targets([directory], [record])
      end

      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      File.write(File.join(directory, "friend.yml"), YAML.dump(base_config))
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.remote_subscription_targets([directory], [record])
      end
    end

    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      duplicate = { name: "friend", url: "https://example.invalid/subscription" }
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.remote_subscription_targets([directory], [duplicate, duplicate])
      end
    end
  end

  def test_script_subscription_download_uses_the_clashx_native_request_without_exposing_the_url
    refute_respond_to ClaudeEasy, :curl_config_value
    assert_respond_to ClaudeEasy, :fetch_remote_subscription
    refute_respond_to ClaudeEasy, :fetch_remote_subscription_via_mihomo
    assert_operator ClaudeEasy::MAX_REMOTE_SUBSCRIPTION_BYTES, :>, 0
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT,
                    'request.setValueForHTTPHeaderField("zh-CN,zh;q=0.9", "Accept-Language");'
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT,
                    'connection:willSendRequest:redirectResponse:'
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "originalHost"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "originalPort"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "nextURL.host"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "nextURL.port"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT,
                    'protocols: ["NSURLConnectionDataDelegate", "NSURLConnectionDelegate"]'
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "didReceiveData:"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "connection.cancel;"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "data.appendData(receivedData);"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "request.HTTPShouldHandleCookies = false;"
    refute_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT,
                    "URLSession:dataTask:didReceiveResponse:completionHandler:"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "var finalURL = response.URL;"
    assert_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT,
                    "Number(primaryApplications.count) + Number(alternateApplications.count) !== 1"
    refute_includes ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT, "Alamofire/"

    status = Struct.new(:success?).new(true)
    capture = lambda do |*arguments, **options|
      assert_equal ["/usr/bin/osascript", "-l", "JavaScript", "-e", ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT], arguments
      refute_includes arguments.join(" "), "example.invalid"
      assert_equal "30\n#{ClaudeEasy::MAX_REMOTE_SUBSCRIPTION_BYTES}\nhttps://example.invalid/subscription\n", options.fetch(:stdin_data)
      [YAML.dump(base_config), "", status]
    end
    Open3.stub(:capture3, capture) do
      ClaudeEasy.fetch_remote_subscription(
        { name: "friend", url: "https://example.invalid/subscription" }
      )
    end
    assert_raises(ClaudeEasy::InvalidConfigError) do
      ClaudeEasy.fetch_remote_subscription({ name: "missing-url" })
    end


    exact = "x" * ClaudeEasy::MAX_REMOTE_SUBSCRIPTION_BYTES
    Open3.stub(:capture3, ->(*_arguments, **_options) { [exact, "", status] }) do
      assert_equal exact, ClaudeEasy.fetch_remote_subscription(
        { name: "friend", url: "https://example.invalid/subscription" }
      )
    end
    oversized = exact + "x"
    Open3.stub(:capture3, ->(*_arguments, **_options) { [oversized, "", status] }) do
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.fetch_remote_subscription(
          { name: "friend", url: "https://example.invalid/subscription" }
        )
      end
    end
  end

  def test_clashx_native_fetch_script_completes_a_real_foundation_request
    skip "JXA Foundation integration requires macOS" unless RbConfig::CONFIG["host_os"].include?("darwin")

    body = "real-foundation-response\n"
    stdout, stderr, status = run_clashx_native_fetch_integration do |listener|
      write_http_fixture_response(
        listener, status: "200 OK", headers: { "Content-Type" => "application/octet-stream" }, body: body
      )
    end

    assert status.success?, stderr
    assert_equal body, stdout
  end

  def test_clashx_native_fetch_script_rejects_an_oversized_real_foundation_response
    skip "JXA Foundation integration requires macOS" unless RbConfig::CONFIG["host_os"].include?("darwin")

    stdout, stderr, status = run_clashx_native_fetch_integration(max_bytes: 32) do |listener|
      write_http_fixture_response(
        listener, status: "200 OK", body: "x" * 64, include_content_length: false
      )
    end

    refute status.success?
    assert_empty stdout
    assert_includes stderr, "subscription request failed"
  end

  def test_clashx_native_fetch_script_follows_a_same_origin_redirect
    skip "JXA Foundation integration requires macOS" unless RbConfig::CONFIG["host_os"].include?("darwin")

    body = "redirected-foundation-response\n"
    stdout, stderr, status = run_clashx_native_fetch_integration do |listener|
      port = listener.addr[1]
      write_http_fixture_response(
        listener, status: "302 Found", headers: { "Location" => "http://127.0.0.1:#{port}/final" }
      )
      write_http_fixture_response(listener, status: "200 OK", body: body)
    end

    assert status.success?, stderr
    assert_equal body, stdout
  end

  def test_clashx_native_request_treats_bridged_application_counts_as_numbers
    lines = ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT.lines
    count_check = lines.select do |line|
      line.include?("primaryApplications =") ||
        line.include?("alternateApplications =") ||
        line.include?("ClashX Meta process is not unique")
    end.join
    count_check.sub!(/var primaryApplications = .*;/, 'var primaryApplications = {count: "1"};')
    count_check.sub!(/var alternateApplications = .*;/, 'var alternateApplications = {count: "0"};')
    script = <<~JAVASCRIPT
      function fail(message) { throw new Error(message); }
      #{count_check}
      "unique";
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3(
      "/usr/bin/osascript", "-l", "JavaScript", "-e", script
    )

    assert status.success?, stderr
    assert_equal "unique\n", stdout
  end

  def test_clashx_native_request_selects_the_nonempty_application_list_with_bridged_counts
    selection = ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT[/var application = .*?alternateApplications\.objectAtIndex\(0\);/m]
    script = <<~JAVASCRIPT
      var primaryApplications = {count: "1", objectAtIndex: function(index) { return "primary"; }};
      var alternateApplications = {count: "0", objectAtIndex: function(index) { return "alternate"; }};
      #{selection}
      application;
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3(
      "/usr/bin/osascript", "-l", "JavaScript", "-e", script
    )

    assert status.success?, stderr
    assert_equal "primary\n", stdout
  end

  def test_clashx_native_request_accepts_an_objective_c_nil_error
    error_check = ClaudeEasy::CLASHX_NATIVE_FETCH_SCRIPT.lines.find do |line|
      line.include?("redirectRejected || !finished")
    end
    script = <<~JAVASCRIPT
      function fail(message) { throw new Error(message); }
      var redirectRejected = false;
      var finished = true;
      var requestError = {isNil: function() { return true; }};
      var data = {};
      var response = {};
      #{error_check}
      "accepted";
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3(
      "/usr/bin/osascript", "-l", "JavaScript", "-e", script
    )

    assert status.success?, stderr
    assert_equal "accepted\n", stdout
  end

  def test_update_candidate_rejects_encoding_transform_and_validation_failures
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      File.write(path, YAML.dump(base_config))
      target = { name: "friend", path: path }
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.build_update_candidate(target, "\xFF".b, @policy, 3, ->(_path) { true })
      end
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.build_update_candidate(target, YAML.dump({}), @policy, 3, ->(_path) { true })
      end
      assert_raises(ClaudeEasy::SafeUpdateCandidateError) do
        ClaudeEasy.build_update_candidate(target, "[invalid", @policy, 3, ->(_path) { true })
      end

      ClaudeEasy.stub(:patch, { status: :error }) do
        assert_raises(ClaudeEasy::InvalidConfigError) do
          ClaudeEasy.build_update_candidate(
            target, YAML.dump(base_config), @policy, 3, ->(_path) { true }
          )
        end
      end

      [
        { status: :updated, changed: true, config: base_config },
        { status: :updated, changed: false, config: base_config.merge("unexpected" => true) }
      ].each do |second_result|
        results = [
          { status: :updated, changed: true, config: base_config },
          second_result
        ]
        ClaudeEasy.stub(:patch, ->(*_args, **_options) { results.shift }) do
          assert_raises(ClaudeEasy::InvalidConfigError) do
            ClaudeEasy.build_update_candidate(
              target, YAML.dump(base_config), @policy, 3, ->(_path) { true }
            )
          end
        end
        assert_empty results
      end

      patch_calls = 0
      exploding_second_patch = lambda do |*_args, **_options|
        patch_calls += 1
        raise "injected second patch failure" if patch_calls == 2

        { status: :updated, changed: true, config: base_config }
      end
      ClaudeEasy.stub(:patch, exploding_second_patch) do
        assert_raises(ClaudeEasy::SafeUpdateCandidateError) do
          ClaudeEasy.build_update_candidate(
            target, YAML.dump(base_config), @policy, 3, ->(_path) { true }
          )
        end
      end

      [:timeout, false].each do |validation|
        assert_raises(ClaudeEasy::InvalidConfigError) do
          ClaudeEasy.build_update_candidate(
            target, YAML.dump(base_config), @policy, 3, ->(_path) { validation }
          )
        end
      end
    end
  end

  def test_update_candidate_rejects_replacing_anytls_with_shadowsocks
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      current = base_config.merge(
        "proxies" => base_config.fetch("proxies").map { |proxy| proxy.merge("type" => "anytls") }
      )
      File.write(path, YAML.dump(current))

      error = assert_raises(ClaudeEasy::SafeUpdateCandidateError) do
        ClaudeEasy.build_update_candidate(
          { name: "friend", path: path }, YAML.dump(base_config), @policy, 3, ->(_path) { true }
        )
      end

      assert_equal :protocol_regression, error.reason

      shadowsocks = base_config.merge(
        "proxies" => base_config.fetch("proxies").map { |proxy| proxy.merge("type" => "shadowsocks") }
      )
      error = assert_raises(ClaudeEasy::SafeUpdateCandidateError) do
        ClaudeEasy.build_update_candidate(
          { name: "friend", path: path }, YAML.dump(shadowsocks), @policy, 3, ->(_path) { true }
        )
      end
      assert_equal :protocol_regression, error.reason
    end
  end

  def test_remote_subscription_and_identity_helpers_fail_closed_on_bad_inputs
    assert_raises(ClaudeEasy::InvalidConfigError) do
      ClaudeEasy.remote_subscription_records("not-base64")
    end

    missing = File.join(Dir.tmpdir, "missing-claude-easy-subscription")
    handle = Object.new
    handle.define_singleton_method(:stat) { raise IOError }
    refute ClaudeEasy.locked_profile_current?(handle, missing)
    refute ClaudeEasy.safe_update_item_committed?(
      path: missing, write_path: missing, committed_identity: [1, 1], candidate: "candidate"
    )
    assert_equal ["friend"], ClaudeEasy.rollback_safe_update_items([
      {
        name: "friend", path: missing, original: "old", candidate: "new",
        committed_identity: [1, 1], write_path: missing
      }
    ])
  end

  def test_recovered_safe_update_runtime_failure_is_reported_before_downloading
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "new"))
      File.binwrite(path, original)
      target = { name: "active", path: path, url: "https://subscriptions.invalid/active" }
      ClaudeEasy.prepare_profile_transaction(
        [{ path: path, original: original, candidate: candidate }],
        backup_root, roots: [directory]
      )
      File.binwrite(path, candidate)

      result = ClaudeEasy.stub(:reload_recovered_safe_update_runtime, false) do
        ClaudeEasy.safe_update_all(
          targets: [target], policy: @policy, backup_root: backup_root, usage_profile: 1,
          fetcher: ->(_item) { flunk "runtime recovery must finish before downloading" },
          validator: ->(_path) { true }, selected_name: "active"
        )
      end

      assert_equal :runtime_restore_pending, result.fetch(:status)
      assert_equal :transaction_runtime_restore_failed, result.fetch(:reason)
      assert_equal original.b, File.binread(path)
      assert File.file?(ClaudeEasy.profile_transaction_path(backup_root)),
             "failed runtime recovery discarded the only retry record"
    end
  end

  def test_recovered_safe_update_runtime_reloads_active_config_outside_remote_targets
    Dir.mktmpdir do |directory|
      config_path = File.join(directory, "config.yaml")
      remote_path = File.join(directory, "remote.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old-config"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "new-config"))
      File.binwrite(config_path, original)
      File.binwrite(remote_path, YAML.dump(base_config))
      target = {
        name: "remote", path: remote_path, url: "https://subscriptions.invalid/remote"
      }
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = {
        path: File.realpath(config_path), expected_tun: :enabled, selections: {}
      }
      ClaudeEasy.prepare_profile_transaction(
        [{ path: config_path, original: original, candidate: candidate }],
        backup_root, roots: [directory], runtime_checkpoint: checkpoint,
        activation_identity: identity
      )
      File.binwrite(config_path, candidate)
      reloads = 0
      checkpoint_checks = [false, true]
      result = ClaudeEasy.stub(:current_runtime_loaded_profile_state, :candidate) do
        ClaudeEasy.stub(:capture_runtime_checkpoint, checkpoint) do
          ClaudeEasy.stub(:runtime_checkpoint_current?, ->(*_arguments, **_options) { checkpoint_checks.shift }) do
            ClaudeEasy.safe_update_all(
              targets: [target], policy: @policy, backup_root: backup_root, usage_profile: 1,
              fetcher: ->(_item) { raise IOError, "stop after recovery" },
              validator: ->(_path) { true }, selected_name: "config.yaml",
              client_identity_reader: -> { identity },
              native_reloader: ->(_current) { reloads += 1; true },
              runtime_waiter: ->(*_arguments, **_options) { true },
              reload_snapshot_reader: -> { { "log" => [1, 2, reloads] } }
            )
          end
        end
      end

      assert_equal :aborted, result.fetch(:status)
      assert_equal :download_or_validation_failed, result.fetch(:reason)
      assert_equal 1, reloads
      assert_equal original.b, File.binread(config_path)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_recovered_safe_update_runtime_handles_controller_errors
    target = { name: "active", path: "/tmp/active.yaml" }
    failure = -> { raise IOError, "controller unavailable" }

    restored = ClaudeEasy.stub(:controller_socket, failure) do
      ClaudeEasy.reload_recovered_safe_update_runtime([target], 1, "active")
    end

    refute restored
  end

  def test_safe_update_does_not_reload_runtime_without_a_recovery_transaction
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      FileUtils.mkdir_p(backup_root)
      File.binwrite(path, YAML.dump(base_config.merge("subscription-marker" => "old")))
      target = { name: "active", path: path, url: "https://subscriptions.invalid/active" }
      recovery_calls = 0

      result = ClaudeEasy.stub(:reload_recovered_safe_update_runtime, lambda { |*_arguments|
        recovery_calls += 1
        true
      }) do
        ClaudeEasy.safe_update_all(
          targets: [target], policy: @policy, backup_root: backup_root, usage_profile: 1,
          fetcher: lambda { |_item|
            YAML.dump(base_config.merge("subscription-marker" => "new"))
          },
          validator: ->(_path) { true }, activation: ->(_items) { true },
          selected_name: "active"
        )
      end

      assert_equal :updated, result.fetch(:status)
      assert_equal 0, recovery_calls
    end
  end

  def test_recovered_safe_update_runtime_uses_the_saved_checkpoint
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      File.binwrite(path, YAML.dump(base_config))
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = { path: File.realpath(path), expected_tun: :disabled, selections: {} }
      bytes = File.binread(path)
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: path, original: bytes, candidate: bytes }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      observed_tun = nil
      restored = ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ name: "active", path: path }], 1, "active",
        precommit_condition: -> { true }, runtime_checkpoint: checkpoint,
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { true },
        runtime_waiter: lambda { |_current, **options|
          observed_tun = options.fetch(:expected_tun)
          true
        }, reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      assert restored
      assert_equal :disabled, observed_tun
    end
  end

  def test_recovered_safe_update_runtime_accepts_original_profile_without_ai_group
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      File.binwrite(path, YAML.dump(base_config))
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = { path: File.realpath(path), expected_tun: :enabled, selections: {} }
      bytes = File.binread(path)
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: path, original: bytes, candidate: bytes }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      required_group = :not_observed

      restored = ClaudeEasy.stub(:current_runtime_requester, nil) do
        ClaudeEasy.reload_recovered_safe_update_runtime(
          [{ name: "active", path: path }], 3, "active",
          precommit_condition: -> { true }, runtime_checkpoint: checkpoint,
          transaction: transaction, client_identity: identity,
          runtime_checkpoint_checker: ->(_current) { true },
          native_reloader: ->(_current) { true },
          runtime_waiter: lambda { |_current, **options|
            required_group = options.fetch(:required_proxy_group)
            true
          }, reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
        )
      end

      assert restored
      assert_nil required_group
    end
  end

  def test_recovered_safe_update_runtime_checks_profile_three_ai_group
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      File.binwrite(path, YAML.dump(ClaudeEasy.patch(base_config, @policy, usage_profile: 3).fetch(:config)))
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = { path: File.realpath(path), expected_tun: :enabled, selections: {} }
      bytes = File.binread(path)
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: path, original: bytes, candidate: bytes }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      required_group = nil

      restored = ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ name: "active", path: path }], 3, "active",
        precommit_condition: -> { true }, runtime_checkpoint: checkpoint,
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { true },
        runtime_waiter: lambda { |_current, **options|
          required_group = options.fetch(:required_proxy_group)
          true
        }, reload_snapshot_reader: -> { {} }
      )

      assert restored
      refute_nil required_group
    end
  end

  def test_recovered_safe_update_runtime_reloads_an_already_healthy_original_runtime
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      File.binwrite(path, YAML.dump(base_config))
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = { path: File.realpath(path), expected_tun: :enabled, selections: {} }
      bytes = File.binread(path)
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: path, original: bytes, candidate: bytes }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )

      reloads = 0
      waits = 0
      restored = ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ name: "active", path: path }], 3, "active",
        precommit_condition: -> { true }, runtime_checkpoint: checkpoint,
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { reloads += 1; true },
        runtime_waiter: ->(*_arguments, **_options) { waits += 1; true },
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      assert restored
      assert_equal 1, reloads
      assert_equal 1, waits
    end
  end

  def test_safe_update_legacy_recovery_check_stops_if_the_shared_precheck_misses_a_journal
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "new"))
      File.binwrite(path, original)
      target = { name: "active", path: path, url: "https://subscriptions.invalid/active" }
      ClaudeEasy.prepare_profile_transaction(
        [{ path: path, original: original, candidate: candidate }],
        backup_root, roots: [directory]
      )
      File.binwrite(path, candidate)

      result = ClaudeEasy.stub(:profile_transaction_pending?, false) do
        ClaudeEasy.stub(:reload_recovered_safe_update_runtime, false) do
          ClaudeEasy.safe_update_all(
            targets: [target], policy: @policy, backup_root: backup_root, usage_profile: 1,
            fetcher: ->(_item) { flunk "legacy runtime recovery must finish before downloading" },
            validator: ->(_path) { true }, selected_name: "active"
          )
        end
      end

      assert_equal :runtime_restore_pending, result.fetch(:status)
      assert_equal :transaction_runtime_restore_failed, result.fetch(:reason)
      assert_equal original.b, File.binread(path)
    end
  end

  def test_safe_update_all_is_transactional_and_reapplies_profile_three_patch
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      targets = %w[MESL Yue Express].map.with_index do |name, index|
        path = File.join(directory, "#{name}.yaml")
        source = base_config
        source["subscription-marker"] = "old-#{index}"
        File.write(path, YAML.dump(source))
        { name: name, path: path, url: "https://subscriptions.invalid/#{index}" }
      end
      fetcher = lambda do |target|
        source = base_config
        source["subscription-marker"] = "new-#{target.fetch(:name)}"
        YAML.dump(source)
      end
      activated = false

      result = ClaudeEasy.safe_update_all(
        targets: targets, policy: @policy, backup_root: backup_root, usage_profile: 3,
        fetcher: fetcher, validator: ->(_path) { true },
        activation: ->(_items) { activated = true; true }, selected_name: "MESL"
      )

      assert_equal :updated, result.fetch(:status)
      assert_equal 3, result.fetch(:count)
      assert activated
      targets.each do |target|
        config = ClaudeEasy.load_yaml(File.read(target.fetch(:path)))
        assert_equal "new-#{target.fetch(:name)}", config.fetch("subscription-marker")
        assert_equal false, config.fetch("ipv6")
        assert_equal true, config.dig("tun", "enable")
        assert_equal [
          "https://223.5.5.5/dns-query#DIRECT",
          "https://1.12.12.12/dns-query#DIRECT"
        ], config.dig("dns", "proxy-server-nameserver")
      end
      assert_equal 3, Dir.glob(File.join(backup_root, "*--pre-update--*.backup")).length
    end
  end

  def test_safe_update_all_discards_an_uncommitted_journal_after_a_preflight_refresh
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      refreshed = YAML.dump(base_config.merge("subscription-marker" => "external-refresh"))
      File.binwrite(path, original)
      target = { name: "friend", path: path, url: "https://subscriptions.invalid/friend" }
      refresh_injected = false
      fetcher = lambda do |_target|
        unless refresh_injected
          replacement = File.join(directory, "replacement.yaml")
          File.binwrite(replacement, refreshed)
          File.rename(replacement, path)
          refresh_injected = true
        end
        YAML.dump(base_config.merge("subscription-marker" => "downloaded"))
      end

      first = ClaudeEasy.safe_update_all(
        targets: [target], policy: @policy, backup_root: backup_root, usage_profile: 1,
        fetcher: fetcher, validator: ->(_path) { true },
        activation: ->(_items) { flunk "preflight conflict must not activate" },
        selected_name: "friend"
      )

      assert refresh_injected
      assert_equal :aborted, first.fetch(:status)
      assert_equal :concurrent_change, first.fetch(:reason)
      assert_equal refreshed.b, File.binread(path)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root)),
             "a preflight-only transaction must not block the next public operation"

      second = ClaudeEasy.safe_update_all(
        targets: [target], policy: @policy, backup_root: backup_root, usage_profile: 1,
        fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "retry")) },
        validator: ->(_path) { true }, activation: ->(_items) { true },
        selected_name: "friend"
      )
      assert_equal :updated, second.fetch(:status)
      assert_equal "retry", ClaudeEasy.load_yaml(File.binread(path)).fetch("subscription-marker")
    end
  end

  def test_safe_update_binds_each_commit_to_the_transaction_inode
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.binwrite(path, original)
      real_prepare = ClaudeEasy.method(:prepare_profile_transaction)
      external_identity = nil
      prepare_then_replace = lambda do |items, root, **options|
        transaction = real_prepare.call(items, root, **options)
        replacement = File.join(directory, "replacement.yaml")
        File.binwrite(replacement, original)
        File.rename(replacement, path)
        current = File.stat(path)
        external_identity = [current.dev, current.ino]
        transaction
      end

      result = ClaudeEasy.stub(:prepare_profile_transaction, prepare_then_replace) do
        ClaudeEasy.safe_update_all(
          targets: [{
            name: "friend", path: path,
            url: "https://subscriptions.invalid/friend"
          }],
          policy: @policy, backup_root: backup_root, usage_profile: 1,
          fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
          validator: ->(_candidate) { true },
          activation: ->(_items) { flunk "a replaced transaction inode must not activate" },
          selected_name: "friend"
        )
      end

      current = File.stat(path)
      assert_equal :aborted, result.fetch(:status)
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_equal original.b, File.binread(path)
      assert_equal external_identity, [current.dev, current.ino]
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_safe_update_binds_each_commit_to_the_transaction_realpath
    Dir.mktmpdir do |directory|
      profile_root = File.join(directory, "profiles")
      first_root = File.join(directory, "first-profiles")
      second_root = File.join(directory, "second-profiles")
      FileUtils.mkdir_p([profile_root, second_root])
      path = File.join(profile_root, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.binwrite(path, original)
      File.binwrite(File.join(second_root, "friend.yaml"), original)
      real_prepare = ClaudeEasy.method(:prepare_profile_transaction)
      prepare_then_repoint = lambda do |items, root, **options|
        transaction = real_prepare.call(items, root, **options)
        File.rename(profile_root, first_root)
        File.symlink(second_root, profile_root)
        transaction
      end
      activated = false

      result = ClaudeEasy.stub(:prepare_profile_transaction, prepare_then_repoint) do
        ClaudeEasy.safe_update_all(
          targets: [{
            name: "friend", path: path,
            url: "https://subscriptions.invalid/friend"
          }],
          policy: @policy, backup_root: backup_root, usage_profile: 1,
          fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
          validator: ->(_candidate) { true },
          activation: ->(_items) { activated = true },
          selected_name: "friend"
        )
      end

      refute activated, "a repointed transaction path must not activate"
      assert_equal :rollback_failed, result.fetch(:status)
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_equal File.realpath(File.join(second_root, "friend.yaml")), File.realpath(path)
      assert_equal original.b, File.binread(File.join(first_root, "friend.yaml"))
      assert_equal original.b, File.binread(File.join(second_root, "friend.yaml"))
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_safe_update_all_preserves_an_atomic_refresh_during_backup
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      targets = %w[first second].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      refreshed = YAML.dump(base_config.merge("subscription-marker" => "external-refresh"))
      original_backup = ClaudeEasy.method(:create_versioned_backup)
      backup_calls = 0
      backup_with_refresh = lambda do |path, root, content: nil, reason: "prewrite"|
        result = original_backup.call(path, root, content: content, reason: reason)
        backup_calls += 1
        if backup_calls == 2
          replacement = File.join(directory, "replacement.yaml")
          File.binwrite(replacement, refreshed)
          File.rename(replacement, targets.fetch(1).fetch(:path))
        end
        result
      end

      result = ClaudeEasy.stub(:create_versioned_backup, backup_with_refresh) do
        ClaudeEasy.safe_update_all(
          targets: targets, policy: @policy, backup_root: backup_root, usage_profile: 3,
          fetcher: ->(target) { YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}")) },
          validator: ->(_path) { true }, activation: ->(_items) { flunk "must not activate" },
          selected_name: "first"
        )
      end

      assert_equal :aborted, result.fetch(:status)
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_equal originals.fetch(targets.fetch(0).fetch(:path)), File.binread(targets.fetch(0).fetch(:path))
      assert_equal refreshed.b, File.binread(targets.fetch(1).fetch(:path))
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_safe_update_preserves_an_equal_candidate_external_refresh_during_descriptor_write
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.write(profile, YAML.dump(base_config.merge("subscription-marker" => "old")))
      target = { name: "friend", path: profile, url: "https://subscriptions.invalid/friend" }
      real_write = ClaudeEasy.method(:write_locked_bytes)
      injected = false
      external_bytes = nil
      external_identity = nil
      write_with_refresh = lambda do |handle, bytes, original_bytes|
        result = real_write.call(handle, bytes, original_bytes)
        unless injected
          replacement = File.join(directory, "external.yaml")
          File.binwrite(replacement, bytes)
          File.rename(replacement, profile)
          stat = File.stat(profile)
          external_bytes = bytes.b
          external_identity = [stat.dev, stat.ino]
          injected = true
        end
        result
      end

      result = ClaudeEasy.stub(:write_locked_bytes, write_with_refresh) do
        ClaudeEasy.safe_update_all(
          targets: [target], policy: @policy, backup_root: backup_root, usage_profile: 1,
          fetcher: ->(_item) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
          validator: ->(_path) { true }, activation: ->(_items) { flunk "must not activate" },
          selected_name: "friend"
        )
      end

      current = File.stat(profile)
      assert injected
      assert_equal :rollback_failed, result.fetch(:status)
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_equal external_bytes, File.binread(profile)
      assert_equal external_identity, [current.dev, current.ino]
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_safe_update_all_restores_every_profile_when_a_later_write_fails
    Dir.mktmpdir do |directory|
      targets = %w[first second third].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      original_write = ClaudeEasy.method(:transactional_replace_locked)
      writes = 0
      failing_write = lambda do |*arguments|
        writes += 1
        raise IOError, "injected second profile write failure" if writes == 2

        original_write.call(*arguments)
      end

      result = ClaudeEasy.stub(:transactional_replace_locked, failing_write) do
        ClaudeEasy.safe_update_all(
          targets: targets, policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 3,
          fetcher: ->(target) { YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}")) },
          validator: ->(_path) { true }, activation: ->(_items) { flunk "must not activate" },
          selected_name: "first"
        )
      end

      assert_equal :aborted, result.fetch(:status)
      assert_equal :write_failed, result.fetch(:reason)
      assert_operator writes, :>=, 3
      targets.each { |target| assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path)) }
    end
  end

  def test_safe_update_closes_profile_handles_before_entering_rollback
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config.merge("subscription-marker" => "old")))
      locked_profiles = []
      real_lock = ClaudeEasy.method(:lock_exclusive_with_timeout)
      track_profile_handles = lambda do |handle, **options|
        result = real_lock.call(handle, **options)
        locked_profiles << handle if File.basename(handle.path) == File.basename(profile)
        result
      end
      check_closed = lambda do |_items, _transaction, _backup_root, _roots, **_options|
        assert_operator locked_profiles.length, :>=, 1
        assert locked_profiles.all?(&:closed?), "rollback started while a profile descriptor was still locked"
        { failures: [], superseded: [] }
      end

      result = ClaudeEasy.stub(:lock_exclusive_with_timeout, track_profile_handles) do
        ClaudeEasy.stub(:transactional_replace_locked, ->(*_arguments) { raise IOError, "injected" }) do
          ClaudeEasy.stub(:finish_safe_update_rollback, check_closed) do
            ClaudeEasy.safe_update_all(
              targets: [{
                name: "friend", path: profile,
                url: "https://subscriptions.invalid/friend"
              }],
              policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 1,
              fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
              validator: ->(_path) { true },
              activation: ->(_items) { flunk "a failed write must not activate" },
              selected_name: "friend"
            )
          end
        end
      end

      assert_equal :aborted, result.fetch(:status)
      assert_equal :write_failed, result.fetch(:reason)
    end
  end

  def test_safe_update_all_leaves_every_profile_untouched_when_one_download_is_invalid
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      targets = %w[first second third].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      fetcher = lambda do |target|
        target.fetch(:name) == "second" ? "<html>expired</html>" : YAML.dump(base_config)
      end

      result = ClaudeEasy.safe_update_all(
        targets: targets, policy: @policy, backup_root: backup_root, usage_profile: 3,
        fetcher: fetcher, validator: ->(_path) { true },
        activation: ->(_items) { flunk "must not activate" }, selected_name: "first"
      )

      assert_equal :aborted, result.fetch(:status)
      assert_equal "second", result.fetch(:failed_profile)
      targets.each { |target| assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path)) }
      assert_equal 3, Dir.children(backup_root).count { |name| name.include?("--pre-update--") }
      refute_includes JSON.generate(result), "subscriptions.invalid"
    end
  end

  def test_safe_update_all_attempts_every_subscription_and_reports_each_candidate
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      targets = %w[first second third].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      calls = []
      fetcher = lambda do |target|
        assert_equal 3, Dir.children(backup_root).count { |name| name.include?("--pre-update--") }
        name = target.fetch(:name)
        calls << name
        raise ClaudeEasy::InvalidConfigError, "download unavailable" if name == "first"

        name == "third" ? "<html>disabled</html>" : YAML.dump(base_config)
      end

      result = ClaudeEasy.safe_update_all(
        targets: targets, policy: @policy, backup_root: backup_root,
        usage_profile: 3, fetcher: fetcher, validator: ->(_path) { true },
        activation: ->(_items) { flunk "a partial batch must not activate" }, selected_name: "first"
      )

      assert_equal %w[first second third], calls
      assert_equal :aborted, result.fetch(:status)
      assert_equal :download_or_validation_failed, result.fetch(:reason)
      assert_equal [
        { name: "first", status: :failed, reason: :download_failed, subscription_switch_possible: true },
        { name: "second", status: :ready },
        { name: "third", status: :failed, reason: :invalid_content, subscription_switch_possible: true }
      ], result.fetch(:items)
      targets.each { |target| assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path)) }
      assert_equal 3, Dir.children(backup_root).count { |name| name.include?("--pre-update--") }
      refute_includes JSON.generate(result), "subscriptions.invalid"
    end
  end

  def test_safe_update_all_disables_auto_update_only_after_every_backup_succeeds
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      targets = %w[first second].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      disable_called = false

      result = ClaudeEasy.safe_update_all(
        targets: targets, policy: @policy, backup_root: backup_root, usage_profile: 3,
        auto_update_disabler: lambda do |operation_lock|
          disable_called = true
          refute_nil operation_lock
          assert_equal 2, Dir.children(backup_root).count { |name| name.include?("--pre-update--") }
          raise IOError, "injected"
        end,
        fetcher: ->(_target) { flunk "must not download after auto-update failure" },
        validator: ->(_path) { true }, selected_name: "first"
      )

      assert disable_called
      assert_equal :aborted, result.fetch(:status)
      assert_equal :auto_update_failed, result.fetch(:reason)
    end
  end

  def test_safe_update_all_stops_before_download_when_a_backup_fails
    Dir.mktmpdir do |directory|
      targets = %w[first second].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      backup_calls = 0
      backup = lambda do |*_arguments, **_options|
        backup_calls += 1
        raise IOError, "injected" if backup_calls == 2
      end

      result = ClaudeEasy.stub(:create_versioned_backup, backup) do
        ClaudeEasy.safe_update_all(
          targets: targets, policy: @policy, backup_root: File.join(directory, "backups"),
          usage_profile: 3,
          fetcher: ->(_target) { flunk "must not download after a backup failure" },
          validator: ->(_path) { true }, selected_name: "first"
        )
      end

      assert_equal :aborted, result.fetch(:status)
      assert_equal :backup_failed, result.fetch(:reason)
    end
  end

  def test_safe_update_all_reports_an_unexpected_candidate_failure
    Dir.mktmpdir do |directory|
      path = File.join(directory, "present.yaml")
      File.write(path, YAML.dump(base_config))
      target = { name: "present", path: path, url: "https://subscriptions.invalid/present" }

      result = ClaudeEasy.stub(:build_update_candidate, ->(*_arguments) { raise "injected" }) do
        ClaudeEasy.safe_update_all(
          targets: [target], policy: @policy, backup_root: File.join(directory, "backups"),
          usage_profile: 3, fetcher: ->(_item) { YAML.dump(base_config) },
          validator: ->(_path) { true }, selected_name: "present"
        )
      end

      assert_equal [
        { name: "present", status: :failed, reason: :validation_failed }
      ], result.fetch(:items)
    end
  end

  def test_safe_update_all_stops_when_the_running_client_identity_disappears
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      File.write(path, YAML.dump(base_config))
      target = { name: "active", path: path, url: "https://subscriptions.invalid/active" }

      result = ClaudeEasy.safe_update_all(
        targets: [target], policy: @policy, backup_root: File.join(directory, "backups"),
        usage_profile: 1, fetcher: ->(_item) { YAML.dump(base_config) },
        validator: ->(_path) { true }, selected_name: "active",
        client_identity_reader: -> { nil }
      )

      assert_equal :aborted, result.fetch(:status)
      assert_equal :client_state_changed, result.fetch(:reason)

      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      result = ClaudeEasy.stub(:capture_runtime_checkpoint, nil) do
        ClaudeEasy.safe_update_all(
          targets: [target], policy: @policy, backup_root: File.join(directory, "backups"),
          usage_profile: 1, fetcher: ->(_item) { YAML.dump(base_config) },
          validator: ->(_path) { true }, selected_name: "active",
          client_identity_reader: -> { identity }
        )
      end
      assert_equal :client_state_changed, result.fetch(:reason)
    end
  end

  def test_safe_update_all_reports_local_and_unexpected_candidate_failures
    Dir.mktmpdir do |directory|
      missing = File.join(directory, "missing.yaml")
      present = File.join(directory, "present.yaml")
      File.write(present, YAML.dump(base_config))
      targets = [
        { name: "missing", path: missing, url: "https://subscriptions.invalid/missing" },
        { name: "present", path: present, url: "https://subscriptions.invalid/present" }
      ]

      candidate_called = false
      result = ClaudeEasy.stub(:build_update_candidate, ->(*_arguments) { candidate_called = true; raise "injected" }) do
        ClaudeEasy.safe_update_all(
          targets: targets, policy: @policy, backup_root: File.join(directory, "backups"),
          usage_profile: 3, fetcher: ->(_target) { YAML.dump(base_config) },
          validator: ->(_path) { true }, selected_name: "present"
        )
      end

      assert_equal [
        { name: "missing", status: :failed, reason: :local_profile_failed }
      ], result.fetch(:items)
      assert_equal :aborted, result.fetch(:status)
      refute candidate_called
    end
  end

  def test_safe_update_all_does_not_add_profile_three_patch_to_lightweight_profiles
    Dir.mktmpdir do |directory|
      path = File.join(directory, "ordinary.yaml")
      File.write(path, YAML.dump(base_config))
      downloaded = base_config.merge("subscription-marker" => "fresh")

      result = ClaudeEasy.safe_update_all(
        targets: [{ name: "ordinary", path: path, url: "https://subscriptions.invalid/ordinary" }],
        policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 2,
        fetcher: ->(_target) { YAML.dump(downloaded) }, validator: ->(_path) { true },
        activation: ->(_items) { true }, selected_name: "ordinary"
      )

      assert_equal :updated, result.fetch(:status)
      config = ClaudeEasy.load_yaml(File.read(path))
      assert_equal "fresh", config.fetch("subscription-marker")
      refute config.key?("tun")
      refute config.key?("ipv6")
      provider_name = @policy.fetch("cn_domain_provider").fetch("name")
      assert config.fetch("rule-providers").key?(provider_name)
      assert_includes config.fetch("rules"), "RULE-SET,#{provider_name},DIRECT"
      assert_equal @policy.fetch("direct_resolvers"),
                   config.dig("dns", "nameserver-policy", "rule-set:#{provider_name}")
    end
  end

  def test_safe_update_propagates_uncertain_commit_publication
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "ordinary.yaml")
      backup_root = File.join(directory, "backups")
      File.write(profile, YAML.dump(base_config))
      journal_path = ClaudeEasy.profile_transaction_path(backup_root)
      real_sync = ClaudeEasy.method(:fsync_parent_directory)
      injected_sync = lambda do |path|
        if path == journal_path && File.binread(path) == ClaudeEasy::PROFILE_TRANSACTION_COMMITTED_BYTES
          raise IOError, "injected committed marker directory sync failure"
        end
        real_sync.call(path)
      end

      assert_raises(ClaudeEasy::ProfileCommitStateUncertainError) do
        ClaudeEasy.stub(:fsync_parent_directory, injected_sync) do
          ClaudeEasy.safe_update_all(
            targets: [{ name: "ordinary", path: profile, url: "https://subscriptions.invalid/ordinary" }],
            policy: @policy, backup_root: backup_root, usage_profile: 2,
            fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "fresh")) },
            validator: ->(_path) { true }, activation: ->(_items) { true },
            selected_name: "ordinary"
          )
        end
      end
      assert_equal "fresh", ClaudeEasy.load_yaml(File.read(profile)).fetch("subscription-marker")
      assert_equal ClaudeEasy::PROFILE_TRANSACTION_COMMITTED_BYTES, File.binread(journal_path)
    end
  end

  def test_safe_update_all_rolls_back_every_profile_when_runtime_activation_fails
    Dir.mktmpdir do |directory|
      targets = %w[first second].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.map { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }.to_h

      result = ClaudeEasy.safe_update_all(
        targets: targets, policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 3,
        fetcher: ->(target) { YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}")) },
        validator: ->(_path) { true }, activation: ->(_items) { raise "controller failed" },
        selected_name: "first"
      )

      assert_equal :aborted, result.fetch(:status)
      assert_equal :activation_failed, result.fetch(:reason)
      targets.each { |target| assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path)) }
    end
  end

  def test_safe_update_does_not_reload_the_old_profile_after_the_user_switches_profiles
    Dir.mktmpdir do |directory|
      targets = %w[friend other].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      selected = "friend"
      put_paths = []
      requester = lambda do |_socket, method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" }
          })]
        when ["PUT", "/configs?force=true"]
          put_paths << JSON.parse(body).fetch("path")
          [204, ""]
        else
          [204, ""]
        end
      end
      fetcher = lambda do |target|
        selected = "other"
        YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}"))
      end

      result = ClaudeEasy.stub(:selected_profile_name, -> { selected }) do
        ClaudeEasy.stub(:storage_mode, :local) do
          ClaudeEasy.stub(:controller_socket, "socket") do
            ClaudeEasy.stub(:controller_request, requester) do
              ClaudeEasy.safe_update_all(
                targets: targets, policy: @policy,
                backup_root: File.join(directory, "backups"), usage_profile: 1,
                fetcher: fetcher, validator: ->(_path) { true }
              )
            end
          end
        end
      end

      assert_empty put_paths, "profile switch allowed the old profile to be forced back into Mihomo"
      assert_equal :aborted, result.fetch(:status)
      targets.each do |target|
        assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path)),
                     "profile switch did not restore the safe-update batch"
      end
    end
  end

  def test_safe_update_keeps_recovery_intent_when_profile_switches_during_runtime_health_check
    Dir.mktmpdir do |directory|
      targets = %w[friend other].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.binwrite(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      backup_root = File.join(directory, "backups")
      selected = "friend"
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      reloads = 0
      requester = lambda do |_socket, method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end
      connectivity = lambda do |**_options|
        selected = "other"
        false
      end

      result = ClaudeEasy.stub(:selected_profile_name, -> { selected }) do
        ClaudeEasy.stub(:storage_mode, :local) do
          ClaudeEasy.stub(:controller_socket, "socket") do
            ClaudeEasy.stub(:controller_request, requester) do
              ClaudeEasy.stub(:default_connectivity_healthy?, connectivity) do
                ClaudeEasy.safe_update_all(
                  targets: targets, policy: @policy, backup_root: backup_root,
                  usage_profile: 1,
                  fetcher: ->(target) {
                    YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}"))
                  },
                  validator: ->(_path) { true }, client_identity_reader: -> { identity },
                  native_reloader: ->(_current) { reloads += 1; true },
                  runtime_waiter: ->(*_arguments, **_options) { connectivity.call },
                  reload_snapshot_reader: -> { { "log" => [1, 2, reloads] } }
                )
              end
            end
          end
        end
      end

      assert_equal 2, reloads
      assert_equal :runtime_restore_pending, result.fetch(:status)
      targets.each do |target|
        assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path))
      end
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_safe_update_aborts_when_the_user_enters_a_remote_target_during_validation
    Dir.mktmpdir do |directory|
      config_path = File.join(directory, "config.yaml")
      remote_path = File.join(directory, "remote.yaml")
      backup_root = File.join(directory, "backups")
      File.binwrite(config_path, YAML.dump(base_config.merge("subscription-marker" => "config")))
      original = YAML.dump(base_config.merge("subscription-marker" => "old-remote"))
      File.binwrite(remote_path, original)
      target = {
        name: "remote", path: remote_path,
        url: "https://subscriptions.invalid/remote"
      }
      selected = "config"
      fetcher = lambda do |_item|
        selected = "remote"
        YAML.dump(base_config.merge("subscription-marker" => "new-remote"))
      end

      result = ClaudeEasy.stub(:selected_profile_name, -> { selected }) do
        ClaudeEasy.safe_update_all(
          targets: [target], policy: @policy, backup_root: backup_root,
          usage_profile: 1, fetcher: fetcher, validator: ->(_path) { true }
        )
      end

      assert_equal :aborted, result.fetch(:status)
      assert_equal :activation_failed, result.fetch(:reason)
      assert_equal original.b, File.binread(remote_path)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_safe_update_aborts_if_the_client_changes_storage_during_validation
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.binwrite(profile, original)
      target = {
        name: "friend", path: profile,
        url: "https://subscriptions.invalid/friend"
      }
      storage = :local
      put_paths = []
      controller = lambda do |_socket, method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["PUT", "/configs?force=true"]
          put_paths << JSON.parse(body).fetch("path")
          [204, ""]
        else
          [204, ""]
        end
      end
      fetcher = lambda do |_item|
        storage = :icloud
        YAML.dump(base_config.merge("subscription-marker" => "new"))
      end

      result = ClaudeEasy.stub(:selected_profile_name, "friend") do
        ClaudeEasy.stub(:storage_mode, -> { storage }) do
          ClaudeEasy.stub(:controller_socket, "socket") do
            ClaudeEasy.stub(:controller_request, controller) do
              ClaudeEasy.safe_update_all(
                targets: [target], policy: @policy,
                backup_root: File.join(directory, "backups"), usage_profile: 1,
                fetcher: fetcher, validator: ->(_path) { true },
                guard_storage: true
              )
            end
          end
        end
      end

      assert_empty put_paths
      assert_equal :aborted, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_default_safe_update_activation_preserves_runtime_recovery_status
    item = {
      path: "/profiles/friend.yaml", original: "original", candidate: "candidate"
    }
    activation_result = {
      path: item.fetch(:path), status: :reload_failed_restore_pending
    }

    ClaudeEasy.stub(:active_profile?, true) do
      ClaudeEasy.stub(:activate_safe_updated_profile, activation_result) do
        result = ClaudeEasy.default_safe_update_activation(
          [item], 3, "friend", transaction: {}, client_identity: {},
          runtime_checkpoint: {}
        )

        assert_equal activation_result, result
      end
    end
  end

  def test_safe_update_reports_when_files_are_restored_but_runtime_is_not
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.write(profile, original)
      target = { name: "friend", path: profile, url: "https://subscriptions.invalid/friend" }

      result = ClaudeEasy.safe_update_all(
        targets: [target], policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 3,
        fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
        validator: ->(_path) { true },
        activation: ->(_items) { { status: :reload_failed_restore_pending } },
        selected_name: "friend"
      )

      assert_equal :runtime_restore_pending, result.fetch(:status)
      assert_equal :reload_failed_restore_pending, result.fetch(:runtime_status)
      assert_equal original.b, File.binread(profile)
      assert File.file?(ClaudeEasy.profile_transaction_path(File.join(directory, "backups"))),
             "runtime-pending rollback discarded the only retry record"
    end
  end

  def test_safe_update_does_not_treat_runtime_file_restore_as_a_second_rollback_failure
    Dir.mktmpdir do |directory|
      targets = %w[active other].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      put_paths = []
      requester = lambda do |method, endpoint, body|
        raise "unexpected controller request" unless method == "PUT" && endpoint == "/configs?force=true"

        put_paths << JSON.parse(body).fetch("path")
        [put_paths.length == 1 ? 204 : 500, ""]
      end
      activation = lambda do |items|
        active = items.fetch(0)
        runtime_result = {
          path: active.fetch(:path), status: :updated, active: true,
          rollback_bytes: active.fetch(:original),
          patched_digest: Digest::SHA256.hexdigest(active.fetch(:candidate)),
          patched_identity: active.fetch(:patched_identity),
          patched_path: active.fetch(:patched_path)
        }
        ClaudeEasy.activate_updated_profile(
          runtime_result, requester: requester, connectivity_checker: -> { true }, require_tun: false
        )
      end

      result = ClaudeEasy.stub(:runtime_selections, {}) do
        ClaudeEasy.stub(:runtime_health_healthy?, false) do
          ClaudeEasy.safe_update_all(
            targets: targets, policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 1,
            fetcher: ->(target) { YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}")) },
            validator: ->(_path) { true }, activation: activation,
            selected_name: "active"
          )
        end
      end

      assert_equal 2, put_paths.length
      assert_equal [File.expand_path(targets.fetch(0).fetch(:path))] * 2, put_paths
      assert_equal :runtime_restore_pending, result.fetch(:status)
      assert_equal :reload_failed_restore_pending, result.fetch(:runtime_status)
      targets.each { |target| assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path)) }
    end
  end

  def test_safe_update_keeps_the_transaction_when_a_restored_file_is_refreshed_before_cleanup
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      File.write(profile, YAML.dump(base_config.merge("subscription-marker" => "old")))
      target = { name: "active", path: profile, url: "https://subscriptions.invalid/active" }
      refreshed = YAML.dump(base_config.merge("subscription-marker" => "external-refresh")).b
      put_count = 0
      requester = lambda do |method, endpoint, _body|
        raise "unexpected controller request" unless method == "PUT" && endpoint == "/configs?force=true"

        put_count += 1
        [put_count == 1 ? 204 : 500, ""]
      end
      activation = lambda do |items|
        active = items.fetch(0)
        ClaudeEasy.activate_updated_profile(
          {
            path: active.fetch(:path), status: :updated, active: true,
            rollback_bytes: active.fetch(:original),
            patched_digest: Digest::SHA256.hexdigest(active.fetch(:candidate)),
            patched_identity: active.fetch(:patched_identity),
            patched_path: active.fetch(:patched_path)
          },
          requester: requester, connectivity_checker: -> { true }, require_tun: false
        )
      end
      real_restored = ClaudeEasy.method(:safe_update_item_restored?)
      injected = false
      restore_check = lambda do |item|
        restored = real_restored.call(item)
        if restored && !injected
          replacement = File.join(directory, "external.yaml")
          File.binwrite(replacement, refreshed)
          File.rename(replacement, profile)
          injected = true
        end
        restored
      end

      result = ClaudeEasy.stub(:runtime_selections, {}) do
        ClaudeEasy.stub(:runtime_health_healthy?, false) do
          ClaudeEasy.stub(:safe_update_item_restored?, restore_check) do
            ClaudeEasy.safe_update_all(
              targets: [target], policy: @policy, backup_root: backup_root, usage_profile: 1,
              fetcher: ->(_item) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
              validator: ->(_path) { true }, activation: activation,
              selected_name: "active"
            )
          end
        end
      end

      assert injected
      assert_equal :rollback_failed, result.fetch(:status)
      assert_equal :activation_failed, result.fetch(:reason)
      assert_equal refreshed, File.binread(profile)
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_safe_update_tries_to_restore_every_profile_when_one_rollback_conflicts
    Dir.mktmpdir do |directory|
      targets = %w[first second third].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:path), File.binread(target.fetch(:path))] }
      restore = lambda do |path, bytes, **_options|
        next false if File.basename(path) == "second.yaml"

        File.binwrite(path, bytes)
        true
      end
      real_recover = ClaudeEasy.method(:recover_profile_transaction)
      fail_pending_recovery = lambda do |root, **options|
        raise IOError, "injected journal recovery failure" if ClaudeEasy.profile_transaction_pending?(root)

        real_recover.call(root, **options)
      end

      result = ClaudeEasy.stub(:replace_profile_bytes, restore) do
        ClaudeEasy.stub(:recover_profile_transaction, fail_pending_recovery) do
          ClaudeEasy.safe_update_all(
            targets: targets, policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 3,
            fetcher: ->(target) { YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}")) },
            validator: ->(_path) { true }, activation: ->(_items) { false },
            selected_name: "first"
          )
        end
      end

      assert_equal :rollback_failed, result.fetch(:status)
      assert_equal originals.fetch(targets[0].fetch(:path)), File.binread(targets[0].fetch(:path))
      assert_equal originals.fetch(targets[2].fetch(:path)), File.binread(targets[2].fetch(:path))
      refute_equal originals.fetch(targets[1].fetch(:path)), File.binread(targets[1].fetch(:path))
    end
  end

  def test_safe_update_reports_a_concurrent_replacement_during_failed_activation
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      external = YAML.dump(base_config.merge("subscription-marker" => "external"))
      File.binwrite(profile, original)
      activation = lambda do |_items|
        replacement = File.join(directory, "replacement.yaml")
        File.binwrite(replacement, external)
        File.rename(replacement, profile)
        false
      end

      result = ClaudeEasy.safe_update_all(
        targets: [{
          name: "friend", path: profile,
          url: "https://subscriptions.invalid/friend"
        }],
        policy: @policy, backup_root: backup_root, usage_profile: 1,
        fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
        validator: ->(_path) { true }, activation: activation,
        selected_name: "friend"
      )

      assert_equal :rollback_failed, result.fetch(:status)
      assert_equal :activation_failed, result.fetch(:reason)
      assert_equal external.b, File.binread(profile)
    end
  end

  def test_safe_update_reports_an_external_refresh_after_rollback_completed
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      external = YAML.dump(base_config.merge("subscription-marker" => "external"))
      File.binwrite(profile, original)
      real_replace = ClaudeEasy.method(:replace_profile_bytes)
      replace = lambda do |path, bytes, **options|
        restored = real_replace.call(path, bytes, **options)
        if restored
          replacement = File.join(directory, "external.yaml")
          File.binwrite(replacement, external)
          File.rename(replacement, profile)
        end
        restored
      end

      result = ClaudeEasy.stub(:replace_profile_bytes, replace) do
        ClaudeEasy.safe_update_all(
          targets: [{
            name: "friend", path: profile,
            url: "https://subscriptions.invalid/friend"
          }],
          policy: @policy, backup_root: backup_root, usage_profile: 1,
          fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
          validator: ->(_path) { true }, activation: ->(_items) { false },
          selected_name: "friend"
        )
      end

      assert_equal :rollback_failed, result.fetch(:status)
      assert_equal :activation_failed, result.fetch(:reason)
      assert_equal external.b, File.binread(profile)
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_safe_update_reports_lock_time_identity_and_rollback_failures
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old")))
      target = { name: "friend", path: path, url: "https://subscriptions.invalid/friend" }
      arguments = {
        targets: [target],
        policy: @policy,
        backup_root: File.join(directory, "backups"),
        usage_profile: 3,
        fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
        validator: ->(_candidate) { true },
        activation: ->(_items) { true },
        selected_name: "friend"
      }

      ClaudeEasy.stub(:locked_profile_current?, false) do
        result = ClaudeEasy.safe_update_all(**arguments)
        assert_equal :aborted, result.fetch(:status)
        assert_equal :concurrent_change, result.fetch(:reason)
      end

      File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old")))
      failing_write = lambda do |*_arguments|
        raise IOError, "injected descriptor write failure"
      end
      real_recover = ClaudeEasy.method(:recover_profile_transaction)
      fail_pending_recovery = lambda do |root, **options|
        raise IOError, "injected journal recovery failure" if ClaudeEasy.profile_transaction_pending?(root)

        real_recover.call(root, **options)
      end
      ClaudeEasy.stub(:transactional_replace_locked, failing_write) do
        ClaudeEasy.stub(:rollback_safe_update_items, ["friend"]) do
          ClaudeEasy.stub(:recover_profile_transaction, fail_pending_recovery) do
            result = ClaudeEasy.safe_update_all(**arguments)
            assert_equal :rollback_failed, result.fetch(:status)
            assert_equal :write_failed, result.fetch(:reason)
            assert_equal "friend", result.fetch(:failed_profile)
          end
        end
      end
    end
  end

  def test_safe_update_post_commit_verification_rolls_back_before_reporting
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.write(path, original)
      target = { name: "friend", path: path, url: "https://subscriptions.invalid/friend" }

      ClaudeEasy.stub(:safe_update_item_committed?, false) do
        result = ClaudeEasy.safe_update_all(
          targets: [target], policy: @policy, backup_root: File.join(directory, "backups"),
          usage_profile: 3,
          fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
          validator: ->(_candidate) { true }, activation: ->(_items) { flunk "must not activate" },
          selected_name: "friend"
        )
        assert_equal :aborted, result.fetch(:status)
        assert_equal :concurrent_change, result.fetch(:reason)
        assert_equal original.b, File.binread(path)
      end
    end
  end

  def test_safe_update_reports_superseded_rollbacks_from_write_and_post_commit_checks
    [:write, :post_commit].each do |stage|
      Dir.mktmpdir do |directory|
        path = File.join(directory, "friend.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old")))
        arguments = {
          targets: [{ name: "friend", path: path, url: "https://subscriptions.invalid/friend" }],
          policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 1,
          fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
          validator: ->(_candidate) { true },
          activation: ->(_items) { flunk "must not activate" }, selected_name: "friend"
        }
        rollback = { failures: [], superseded: ["friend"] }

        result = ClaudeEasy.stub(:finish_safe_update_rollback, rollback) do
          if stage == :write
            ClaudeEasy.stub(:transactional_replace_locked, ->(*_arguments) { raise IOError }) do
              ClaudeEasy.safe_update_all(**arguments)
            end
          else
            ClaudeEasy.stub(:safe_update_item_committed?, false) do
              ClaudeEasy.safe_update_all(**arguments)
            end
          end
        end

        assert_equal :aborted, result.fetch(:status)
        assert_equal :rollback_superseded, result.fetch(:reason)
      end
    end
  end

  def test_safe_update_distinguishes_invalid_requests_from_unexpected_setup_failures
    assert_raises(ClaudeEasy::InvalidConfigError) do
      ClaudeEasy.safe_update_all(
        targets: [], policy: @policy, backup_root: Dir.tmpdir, usage_profile: 0
      )
    end

    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      File.write(path, YAML.dump(base_config))
      target = { name: "friend", path: path, url: "https://subscriptions.invalid/friend" }
      ClaudeEasy.stub(:build_update_candidate, YAML.dump(base_config)) do
        File.stub(:stat, ->(_candidate) { raise IOError, "injected identity failure" }) do
          result = ClaudeEasy.safe_update_all(
            targets: [target], policy: @policy, backup_root: File.join(directory, "backups"),
            usage_profile: 3, fetcher: ->(_target) { YAML.dump(base_config) },
            validator: ->(_candidate) { true }, selected_name: "friend"
          )
          assert_equal :aborted, result.fetch(:status)
          assert_equal :unexpected_error, result.fetch(:reason)
        end
      end
    end
  end

  def test_refresh_during_validation_is_reloaded_before_write
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.write(profile, YAML.dump(base_config))
      calls = 0
      validator = lambda do |_candidate|
        calls += 1
        if calls == 1
          refreshed = base_config
          refreshed["friend-marker"] = "new subscription content"
          File.write(profile, YAML.dump(refreshed))
        end
        true
      end

      result = ClaudeEasy.patch_path(profile, @policy, backup_root: backup_root, validator: validator)
      written = ClaudeEasy.load_yaml(File.read(profile))
      backup = ClaudeEasy.load_yaml(File.read(Dir.glob(File.join(backup_root, "*.backup")).fetch(0)))

      assert_equal :updated, result.fetch(:status)
      assert_equal "new subscription content", written.fetch("friend-marker")
      assert_equal "new subscription content", backup.fetch("friend-marker")
      assert_operator calls, :>=, 2
    end
  end

  def test_repeated_refreshes_leave_latest_subscription_untouched
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      calls = 0
      validator = lambda do |_candidate|
        calls += 1
        refreshed = base_config
        refreshed["friend-marker"] = "refresh-#{calls}"
        File.write(profile, YAML.dump(refreshed))
        true
      end

      result = ClaudeEasy.patch_path(profile, @policy, validator: validator)
      latest = ClaudeEasy.load_yaml(File.read(profile))

      assert_equal :concurrent_change, result.fetch(:status)
      assert_equal "refresh-#{calls}", latest.fetch("friend-marker")
      refute latest.key?("ipv6")
    end
  end

  def test_refresh_while_backup_is_created_is_not_overwritten
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.write(profile, YAML.dump(base_config))
      refreshed = base_config
      refreshed["friend-marker"] = "refresh-during-backup"
      original_backup = ClaudeEasy.method(:create_versioned_backup)
      injected = false
      backup_with_refresh = lambda do |path, root, content: nil, reason: "prewrite"|
        result = original_backup.call(path, root, content: content, reason: reason)
        next if injected

        injected = true
        File.write(profile, YAML.dump(refreshed))
        result
      end

      result = ClaudeEasy.stub(:create_versioned_backup, backup_with_refresh) do
        ClaudeEasy.patch_path(profile, @policy, backup_root: backup_root, validator: ->(_candidate) { true })
      end
      written = ClaudeEasy.load_yaml(File.read(profile))

      assert_equal :updated, result.fetch(:status)
      assert_equal "refresh-during-backup", written.fetch("friend-marker")
      assert_equal false, written.fetch("ipv6")
    end
  end

  def test_atomic_refresh_after_final_identity_check_is_not_overwritten
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      refreshed_path = File.join(directory, "refreshed.yaml")
      File.write(profile, YAML.dump(base_config))
      refreshed = base_config
      refreshed["friend-marker"] = "latest atomic refresh"
      File.write(refreshed_path, YAML.dump(refreshed))
      original_check = ClaudeEasy.method(:locked_source_current?)
      checks = 0
      checker = lambda do |source, logical_path, write_path|
        checks += 1
        if checks == 2
          File.rename(refreshed_path, write_path)
          true
        else
          original_check.call(source, logical_path, write_path)
        end
      end

      result = ClaudeEasy.stub(:locked_source_current?, checker) do
        ClaudeEasy.patch_path(profile, @policy)
      end
      written = ClaudeEasy.load_yaml(File.read(profile))

      assert_equal :updated, result.fetch(:status)
      assert_equal "latest atomic refresh", written.fetch("friend-marker")
      assert_equal false, written.fetch("ipv6")
    end
  end

  def test_profile_scan_excludes_runtime_and_backup_files
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), "rules: []\n")
      File.write(File.join(directory, "config.yaml"), "rules: []\n")
      File.write(File.join(directory, "UPPER.YML"), "rules: []\n")
      File.write(File.join(directory, "friend.yaml.backup"), "rules: []\n")
      File.write(File.join(directory, "friend.backup.yaml"), "rules: []\n")
      File.write(File.join(directory, "friend.bak.yml"), "rules: []\n")
      File.write(File.join(directory, "friend.claude-easy.yaml"), "rules: []\n")
      FileUtils.mkdir_p(File.join(directory, "providers"))
      File.write(File.join(directory, "providers", "cache.yaml"), "rules: []\n")

      expected = %w[UPPER.YML config.yaml friend.yaml].map { |name| File.join(directory, name) }
      assert_equal expected, ClaudeEasy.profile_paths(directory)
    end
  end

  def test_multi_document_yaml_is_skipped_without_rewrite
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "multi.yaml")
      original = YAML.dump(base_config) + "---\nfriend: second-document\n"
      File.write(profile, original)

      result = ClaudeEasy.patch_path(profile, @policy)

      assert_equal :invalid, result.fetch(:status)
      assert_equal original, File.read(profile)
    end
  end

  def test_yaml_alias_cycle_is_skipped_without_crashing_run
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "cycle.yaml")
      original = <<~YAML
        proxies:
          - { name: node, type: ss, server: example.com }
        proxy-groups:
          - { name: Main, type: select, proxies: [node] }
        rules: [MATCH,Main]
        cycle: &cycle
          self: *cycle
      YAML
      File.write(profile, original)

      result = ClaudeEasy.patch_path(profile, @policy)

      assert_equal :invalid, result.fetch(:status)
      assert_equal original, File.read(profile)
    end
  end

  def test_deep_yaml_aborts_the_batch_before_other_profiles_are_written
    Dir.mktmpdir do |directory|
      deep_path = File.join(directory, "deep.yaml")
      good_path = File.join(directory, "good.yaml")
      depth = 1_600
      lines = (0...depth).map { |index| "#{'  ' * index}level#{index}:" }
      lines << "#{'  ' * depth}leaf: value"
      File.write(deep_path, lines.join("\n") + "\n")
      good_original = YAML.dump(base_config)
      File.write(good_path, good_original)

      results = ClaudeEasy.run(directories: [directory], policy_path: POLICY_PATH,
                               selected_name: "good")
      by_name = results.each_with_object({}) { |result, memo| memo[File.basename(result.fetch(:path))] = result }

      assert_includes %i[invalid error], by_name.fetch("deep.yaml").fetch(:status)
      assert_equal :batch_aborted, by_name.fetch("good.yaml").fetch(:status)
      assert_equal good_original, File.read(good_path)
    end
  end

  def test_load_yaml_rejects_excessive_depth_before_materialization
    depth = 2_000
    lines = (0...depth).map { |index| "#{'  ' * index}level#{index}:" }
    lines << "#{'  ' * depth}leaf: value"

    error = assert_raises(ClaudeEasy::InvalidConfigError) do
      ClaudeEasy.load_yaml(lines.join("\n") + "\n", "deep.yaml")
    end

    assert_equal "YAML 结构过于复杂", error.message
  end

  def test_load_yaml_accepts_wide_shallow_documents
    entries = (0...20_000).map { |index| "  key#{index}: value#{index}" }
    config = ClaudeEasy.load_yaml("root:\n#{entries.join("\n")}\n", "wide.yaml")

    assert_equal 20_000, config.fetch("root").length
    assert_equal "value19999", config.fetch("root").fetch("key19999")
  end

  def test_yaml_complexity_rejects_excessive_node_count
    root = Psych::Nodes::Sequence.new
    scalar = Psych::Nodes::Scalar.new("value")
    root.children.concat(Array.new(ClaudeEasy::MAX_YAML_AST_NODES + 1, scalar))

    error = assert_raises(ClaudeEasy::InvalidConfigError) do
      ClaudeEasy.validate_yaml_complexity(root)
    end

    assert_equal "YAML 结构过于复杂", error.message
  end

  def test_shared_main_group_fixtures
    shared = JSON.parse(File.read(MAIN_GROUP_FIXTURES))
    assert_equal 1, shared.fetch("schema_version")
    fixtures = shared.fetch("cases")
    fixtures.each do |fixture|
      config = fixture.fetch("config")
      snapshot = JSON.parse(JSON.generate(config))
      expected = fixture["expected_main_group"]

      detected = ClaudeEasy.detect_main_group(config, @policy)
      if expected.nil?
        assert_nil detected, fixture.fetch("name")
      else
        assert_equal expected, detected, fixture.fetch("name")
      end
      next unless expected.nil?

      result = ClaudeEasy.patch(config, @policy)
      refute result.fetch(:changed), fixture.fetch("name")
      assert_equal :no_main_group, result.fetch(:status), fixture.fetch("name")
      assert_equal snapshot, config, fixture.fetch("name")
    end
  end

  def test_complex_dynamic_filter_is_patched_in_every_usage_profile
    config = {
      "proxies" => [{ "name" => "HK 01", "type" => "ss", "server" => "hk.example" }],
      "proxy-groups" => [{
        "name" => "Dynamic", "type" => "select", "include-all-proxies" => true,
        "filter" => "(?i)HK|香港"
      }],
      "rules" => ["MATCH,Dynamic"]
    }

    [1, 2, 3].each do |usage_profile|
      result = ClaudeEasy.patch(config, @policy, usage_profile: usage_profile)
      assert result.fetch(:changed), "usage profile #{usage_profile}"
      assert_equal "Dynamic", result.fetch(:main_group), "usage profile #{usage_profile}"
    end
  end

  def test_shared_unsafe_group_reference_fixtures
    fixtures = JSON.parse(File.read(MAIN_GROUP_FIXTURES)).fetch("unsafe_reference_cases")
    route_wrapper = "🔗 路由引用 · ClaudeEasy"
    ai_wrapper = "🔗 路由引用 · ClaudeEasy 2"

    fixtures.each do |fixture|
      input = fixture.fetch("config")
      snapshot = JSON.parse(JSON.generate(input))
      result = ClaudeEasy.patch(input, @policy)
      patched = result.fetch(:config)
      groups = patched.fetch("proxy-groups")

      assert_equal route_wrapper, result.fetch(:route_group), fixture.fetch("name")
      assert_equal ai_wrapper, result.fetch(:ai_group), fixture.fetch("name")
      assert_equal [fixture.fetch("main_group")],
                   groups.find { |group| group["name"] == route_wrapper }.fetch("proxies"), fixture.fetch("name")
      assert_equal [fixture.fetch("ai_group")],
                   groups.find { |group| group["name"] == ai_wrapper }.fetch("proxies"), fixture.fetch("name")
      provider = patched.fetch("rule-providers").fetch(result.fetch(:cn_provider))
      assert_equal route_wrapper, provider.fetch("proxy"), fixture.fetch("name")
      expected_route_resolvers = @policy.fetch("resolvers").map { |resolver| "#{resolver}##{route_wrapper}" }
      expected_ai_resolvers = @policy.fetch("resolvers").map { |resolver| "#{resolver}##{ai_wrapper}" }
      assert_equal expected_route_resolvers, patched.dig("dns", "nameserver"), fixture.fetch("name")
      assert_equal expected_ai_resolvers,
                   patched.dig("dns", "nameserver-policy", "+.openai.com"), fixture.fetch("name")
      assert_includes patched.fetch("rules"), "NETWORK,UDP,#{ai_wrapper}", fixture.fetch("name")
      assert_includes patched.fetch("rules"), "DOMAIN-SUFFIX,openai.com,#{ai_wrapper}", fixture.fetch("name")
      refute_includes JSON.generate(patched.fetch("dns")), "skip-cert-verify=true", fixture.fetch("name")
      assert_equal snapshot, input, "#{fixture.fetch('name')}: input mutated"
      second = ClaudeEasy.patch(patched, @policy)
      assert_equal patched, second.fetch(:config), "#{fixture.fetch('name')}: second pass"
      refute second.fetch(:changed), "#{fixture.fetch('name')}: second pass changed"
    end
  end

  def test_shared_full_transform_fixtures
    fixtures = JSON.parse(File.read(MAIN_GROUP_FIXTURES)).fetch("transform_cases")
    fixtures.each do |fixture|
      input = fixture.fetch("input")
      snapshot = JSON.parse(JSON.generate(input))
      result = ClaudeEasy.patch(input, @policy)

      assert_equal fixture.fetch("expected_changed"), result.fetch(:changed), fixture.fetch("name")
      expected_main = fixture.fetch("expected_main_group")
      expected_ai = fixture.fetch("expected_ai_group")
      expected_main.nil? ? assert_nil(result.fetch(:main_group), fixture.fetch("name")) :
        assert_equal(expected_main, result.fetch(:main_group), fixture.fetch("name"))
      if expected_main
        group_names = Array(result.fetch(:config)["proxy-groups"]).map do |group|
          group["name"] if group.is_a?(Hash)
        end.compact
        assert_includes group_names, expected_main, "#{fixture.fetch('name')}: main group was removed"
      end
      expected_ai.nil? ? assert_nil(result.fetch(:ai_group), fixture.fetch("name")) :
        assert_equal(expected_ai, result.fetch(:ai_group), fixture.fetch("name"))
      assert_equal fixture.fetch("expected_status").to_sym, result.fetch(:status), fixture.fetch("name")
      assert_equal snapshot, input, "#{fixture.fetch('name')}: input mutated"
      expected_path = File.join(ROOT, "tests/fixtures/transform_expected/#{fixture.fetch('name')}.json")
      expected = JSON.parse(File.read(expected_path))
      actual = JSON.parse(JSON.generate(result.fetch(:config)))
      assert_equal expected, actual, "#{fixture.fetch('name')}: output drift"
      serialized = JSON.generate(result.fetch(:config))
      Array(fixture["expected_absent_strings"]).each do |value|
        refute_includes serialized, value, "#{fixture.fetch('name')}: retained #{value}"
      end
      Array(fixture["expected_present_strings"]).each do |value|
        assert_includes serialized, value, "#{fixture.fetch('name')}: missing #{value}"
      end

      next unless fixture.fetch("expected_changed")

      second = ClaudeEasy.patch(result.fetch(:config), @policy)
      assert_equal result.fetch(:config), second.fetch(:config), "#{fixture.fetch('name')}: second pass"
      refute second.fetch(:changed), "#{fixture.fetch('name')}: second pass changed"
      assert_equal :unchanged, second.fetch(:status), "#{fixture.fetch('name')}: second pass status"
    end
  end

  def test_shared_full_transform_fixtures_match_windows_exactly
    fixtures = JSON.parse(File.read(MAIN_GROUP_FIXTURES)).fetch("transform_cases")
    inputs = fixtures.map { |fixture| fixture.fetch("input") }
    engine_path = File.join(ROOT, "claude-easy/scripts/windows/clash_verge_global.js")
    javascript = <<~'JS'
      const fs = require('node:fs');
      const engine = require(process.argv[1]);
      const inputs = JSON.parse(fs.readFileSync(0, 'utf8'));
      process.stdout.write(JSON.stringify(inputs.map((input) => engine.claudeEasyTransform(input, 'fixture'))));
    JS
    stdout, stderr, status = Open3.capture3("node", "-e", javascript, engine_path, stdin_data: JSON.generate(inputs))
    assert status.success?, stderr
    windows = JSON.parse(stdout)

    fixtures.each_with_index do |fixture, index|
      ruby = ClaudeEasy.patch(fixture.fetch("input"), @policy).fetch(:config)
      assert_equal ruby, windows.fetch(index), fixture.fetch("name")
      expected_path = File.join(ROOT, "tests/fixtures/transform_expected/#{fixture.fetch('name')}.json")
      expected = JSON.parse(File.read(expected_path))
      actual = JSON.parse(JSON.generate(windows.fetch(index)))
      assert_equal expected, actual, "#{fixture.fetch('name')}: Windows output drift"
    end
  end

  def test_ai_named_non_select_group_is_preserved
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    config["proxy-groups"] << { "name" => "AI", "type" => "url-test", "proxies" => ["台湾家宽 01"], "url" => "https://example.invalid", "interval" => 300 }
    result = ClaudeEasy.patch(config, @policy)
    patched = result.fetch(:config)

    original_ai = patched.fetch("proxy-groups").find { |group| group["name"] == "AI" }
    assert_equal "url-test", original_ai.fetch("type")
    created = patched.fetch("proxy-groups").find { |group| group["name"] == "🤖 AI · ClaudeEasy" }
    refute_nil created
    assert_equal "select", created.fetch("type")
    assert_equal "🤖 AI · ClaudeEasy", result.fetch(:ai_group)
    assert_includes patched.fetch("rules"), "DOMAIN-SUFFIX,openai.com,🤖 AI · ClaudeEasy"
    assert_includes patched.fetch("rules"), "NETWORK,UDP,#{result.fetch(:ai_group)}"
    refute_self_reference(patched)
  end

  def test_ai_only_group_receives_the_full_patch_as_a_last_resort
    config = {
      "proxies" => [{ "name" => "台湾家宽 01", "type" => "ss", "server" => "tw.example" }],
      "proxy-groups" => [{ "name" => "AI", "type" => "select", "proxies" => ["台湾家宽 01"] }],
      "rules" => ["MATCH,AI"]
    }
    result = ClaudeEasy.patch(config, @policy)

    assert result.fetch(:changed)
    assert_equal :updated, result.fetch(:status)
    assert_equal "AI", result.fetch(:main_group)
    assert_equal "AI", result.fetch(:ai_group)
    assert_equal "AI", result.fetch(:config).dig("rule-providers", "claude-easy-cn-domain", "proxy")
    assert_includes result.fetch(:config).fetch("rules"), "NETWORK,UDP,AI"
  end

  def test_provider_only_profile_is_patched_and_preserved
    providers = { "provider1" => { "type" => "http", "url" => "https://example.invalid/sub", "interval" => 3600 } }
    config = {
      "proxy-providers" => providers,
      "proxy-groups" => [
        { "name" => "Main", "type" => "select", "use" => ["provider1"] },
        { "name" => "AI", "type" => "select", "use" => ["provider1"] }
      ],
      "rules" => ["MATCH,Main"]
    }
    result = ClaudeEasy.patch(config, @policy)
    patched = result.fetch(:config)

    assert result.fetch(:changed)
    assert_equal "Main", result.fetch(:main_group)
    assert_equal providers, patched.fetch("proxy-providers")
    assert_equal ["provider1"], patched.fetch("proxy-groups").find { |group| group["name"] == "Main" }.fetch("use")
    assert_includes patched.fetch("rules"), "NETWORK,UDP,#{result.fetch(:ai_group)}"
    refute_self_reference(patched)
  end

  def test_existing_backup_is_hardened_not_replaced
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      backup = File.join(directory, "backups")
      FileUtils.mkdir_p(backup)
      key = Digest::SHA256.hexdigest(File.expand_path(profile))[0, 16]
      existing = File.join(backup, "#{key}-friend.yaml.backup")
      File.write(existing, "first-backup")
      File.chmod(0o644, existing)

      ClaudeEasy.patch_path(profile, @policy, backup_root: backup)

      assert_equal "first-backup", File.read(existing)
      assert_equal "600", format("%o", File.stat(existing).mode & 0o777)
      assert_equal 2, Dir.glob(File.join(backup, "*.backup")).length
      assert_equal 1, Dir.glob(File.join(backup, "*--prewrite--*.backup")).length
    end
  end

  def test_dry_run_reports_preview_without_writing
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      File.write(profile, original)

      results = ClaudeEasy.run(directory: directory, policy_path: POLICY_PATH, dry_run: true,
                               backup_root: File.join(directory, "backups"), selected_name: "friend")
      active = results.find { |entry| File.basename(entry[:path]) == "friend.yaml" }
      status = ClaudeEasy.chinese_status(active)

      assert_includes status, "演练"
      refute_includes status, "已更新"
      assert_equal original, File.read(profile)
      refute Dir.exist?(File.join(directory, "backups"))
    end
  end

  def test_invalid_reality_short_ids_are_not_guessed
    config = base_config
    config["proxies"][0]["reality-opts"] = { "short-id" => 83 }
    config["proxies"][1]["reality-opts"] = { "short-id" => "not-hex!!" }
    config["proxies"][2]["reality-opts"] = { "short-id" => "0123456789abcdef00" }
    patched = ClaudeEasy.patch(config, @policy).fetch(:config)

    assert_equal 83, patched.fetch("proxies")[0].dig("reality-opts", "short-id")
    assert_equal "not-hex!!", patched.fetch("proxies")[1].dig("reality-opts", "short-id")
    assert_equal "0123456789abcdef00", patched.fetch("proxies")[2].dig("reality-opts", "short-id")
  end

  def test_comma_joined_nameserver_policy_keys_are_split
    config = base_config
    config["dns"]["nameserver-policy"] = {
      "+.example.com,+.example.org" => ["223.5.5.5"],
      "+.keep.example" => ["https://1.1.1.1/dns-query#OtherGroup"]
    }
    result = ClaudeEasy.patch(config, @policy)
    policy_out = result.fetch(:config).dig("dns", "nameserver-policy")

    refute policy_out.key?("+.example.com,+.example.org")
    route_group = result.fetch(:route_group)
    assert policy_out.fetch("+.example.com").all? { |value| value.end_with?("##{route_group}") }
    assert policy_out.fetch("+.example.org").all? { |value| value.end_with?("##{route_group}") }
    assert policy_out.fetch("+.keep.example").all? { |value| value.end_with?("##{route_group}") }
  end

  def test_run_automatically_reloads_and_checks_the_active_profile
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      File.write(File.join(directory, "other.yaml"), YAML.dump(base_config))

      requests = []
      proxy_body = JSON.generate("proxies" => {
        "Main" => { "type" => "Selector", "now" => "台湾家宽 01" },
        "AI" => { "type" => "Selector", "now" => "台湾家宽 01" },
        "台湾家宽 01" => { "type" => "Shadowsocks" }
      })
      requester = lambda do |method, endpoint, body|
        requests << [method, endpoint, body]
        case [method, endpoint]
        when ["GET", "/proxies"] then [200, proxy_body]
        when ["GET", "/providers/proxies"] then [200, JSON.generate("providers" => {})]
        when ["PUT", "/configs?force=true"] then [204, ""]
        when ["POST", "/cache/fakeip/flush"] then [204, ""]
        when ["POST", "/cache/dns/flush"] then [204, ""]
        when ["GET", "/configs"] then [200, JSON.generate("tun" => { "enable" => true })]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      results = ClaudeEasy.run(directory: directory, policy_path: POLICY_PATH, backup_root: File.join(directory, "backups"),
                               selected_name: "friend", auto_reload: true, requester: requester,
                               connectivity_checker: -> { true })
      active = results.find { |entry| File.basename(entry[:path]) == "friend.yaml" }
      inactive = results.find { |entry| File.basename(entry[:path]) == "other.yaml" }
      assert_equal true, active.fetch(:reloaded)
      assert_includes ClaudeEasy.chinese_status(active), "已更新并自动生效"
      assert_includes ClaudeEasy.chinese_status(inactive), "已更新，选择该订阅时生效"
      assert requests.any? { |method, endpoint, _body| method == "PUT" && endpoint == "/configs?force=true" }
      refute requests.any? { |method, endpoint, _body| method == "POST" && endpoint == "/cache/fakeip/flush" }
      assert requests.any? { |method, endpoint, _body| method == "POST" && endpoint == "/cache/dns/flush" }
      refute requests.any? { |_method, endpoint, _body| endpoint.include?("www.google.com") }
    end
  end

  def test_run_does_not_reload_the_old_profile_after_the_user_switches_profiles
    Dir.mktmpdir do |directory|
      paths = %w[friend other].to_h do |name|
        path = File.join(directory, "#{name}.yaml")
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        [name, path]
      end
      originals = paths.transform_values { |path| File.binread(path) }
      selected = "friend"
      put_paths = []
      requester = lambda do |method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"]
          put_paths << JSON.parse(body).fetch("path")
          [204, ""]
        else
          [204, ""]
        end
      end
      validator = lambda do |_path|
        selected = "other"
        true
      end

      results = ClaudeEasy.stub(:selected_profile_name, -> { selected }) do
        ClaudeEasy.stub(:storage_mode, :local) do
          ClaudeEasy.run(
            directory: directory, policy_path: POLICY_PATH,
            backup_root: File.join(directory, "backups"),
            validator: validator, auto_reload: true, requester: requester,
            connectivity_checker: -> { true }, usage_profile: 1
          )
        end
      end

      assert_empty put_paths, "profile switch allowed the old profile to be forced back into Mihomo"
      paths.each do |name, path|
        assert_equal originals.fetch(name), File.binread(path),
                     "profile switch did not restore the aborted batch: #{name}"
      end
      refute results.all? { |result| %i[updated unchanged].include?(result.fetch(:status)) }
    end
  end

  def test_run_keeps_recovery_intent_when_profile_switches_during_runtime_health_check
    Dir.mktmpdir do |directory|
      paths = %w[friend other].to_h do |name|
        path = File.join(directory, "#{name}.yaml")
        File.binwrite(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        [name, path]
      end
      originals = paths.transform_values { |path| File.binread(path) }
      backup_root = File.join(directory, "backups")
      selected = "friend"
      put_paths = []
      requester = lambda do |method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"]
          put_paths << JSON.parse(body).fetch("path")
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end
      connectivity = lambda do
        selected = "other"
        true
      end

      results = ClaudeEasy.stub(:selected_profile_name, -> { selected }) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
          validator: ->(_path) { true }, auto_reload: true, requester: requester,
          connectivity_checker: connectivity, usage_profile: 1
        )
      end

      assert_equal [File.expand_path(paths.fetch("friend"))], put_paths
      refute results.all? { |result| %i[updated unchanged].include?(result.fetch(:status)) }
      paths.each do |name, path|
        assert_equal originals.fetch(name), File.binread(path)
      end
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_run_rechecks_every_candidate_after_active_runtime_health
    Dir.mktmpdir do |directory|
      paths = %w[friend other].to_h do |name|
        path = File.join(directory, "#{name}.yaml")
        File.binwrite(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        [name, path]
      end
      originals = paths.transform_values { |path| File.binread(path) }
      external = YAML.dump(base_config.merge("subscription-marker" => "external-other")).b
      backup_root = File.join(directory, "backups")
      put_paths = []
      requester = lambda do |method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"]
          put_paths << JSON.parse(body).fetch("path")
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end
      injected = false
      connectivity = lambda do
        unless injected
          replacement = File.join(directory, "external.yaml")
          File.binwrite(replacement, external)
          File.rename(replacement, paths.fetch("other"))
          injected = true
        end
        true
      end

      results = ClaudeEasy.run(
        directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
        selected_name: "friend", validator: ->(_path) { true }, auto_reload: true,
        requester: requester, connectivity_checker: connectivity, usage_profile: 1
      )

      active = results.find { |result| File.basename(result.fetch(:path)) == "friend.yaml" }
      other = results.find { |result| File.basename(result.fetch(:path)) == "other.yaml" }
      assert_equal :reload_failed_restore_pending, active.fetch(:status)
      assert_equal :concurrent_change, other.fetch(:status)
      assert_equal originals.fetch("friend"), File.binread(paths.fetch("friend"))
      assert_equal external, File.binread(paths.fetch("other"))
      assert_equal [File.expand_path(paths.fetch("friend"))], put_paths
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_run_marks_a_loaded_candidate_pending_when_the_final_context_changes
    results = run_with_stubbed_finalization(
      auto_reload: true, runtime_precommit: false,
      recover: :success, reload: true, remove: :success
    )

    assert_equal [:reload_failed_restore_pending], results.map { |result| result.fetch(:status) }
  end

  def test_run_reports_a_final_ownership_conflict_when_transaction_recovery_fails
    results = run_with_stubbed_finalization(
      auto_reload: false, runtime_precommit: true,
      recover: :raise, reload: false, remove: :success
    )

    assert_equal [:concurrent_change], results.map { |result| result.fetch(:status) }
  end

  def test_run_keeps_the_journal_when_final_runtime_cleanup_fails
    results = run_with_stubbed_finalization(
      auto_reload: true, runtime_precommit: true,
      recover: :success, reload: true, remove: :raise
    )

    assert_equal [:reload_failed_restore_pending], results.map { |result| result.fetch(:status) }
  end

  def test_run_aborts_if_the_user_enters_an_updated_profile_while_the_initial_profile_is_unchanged
    Dir.mktmpdir do |directory|
      config_path = File.join(directory, "config.yaml")
      friend_path = File.join(directory, "friend.yaml")
      patched_config = ClaudeEasy.patch(
        base_config.merge("subscription-marker" => "config"),
        @policy, usage_profile: 1
      ).fetch(:config)
      File.binwrite(config_path, YAML.dump(patched_config))
      File.binwrite(
        friend_path,
        YAML.dump(base_config.merge("subscription-marker" => "old-friend"))
      )
      originals = {
        config_path => File.binread(config_path),
        friend_path => File.binread(friend_path)
      }
      backup_root = File.join(directory, "backups")
      selected = ""
      put_paths = []
      validator = lambda do |_path|
        selected = "friend"
        true
      end
      requester = lambda do |method, endpoint, body|
        if method == "PUT" && endpoint == "/configs?force=true"
          put_paths << JSON.parse(body).fetch("path")
        end
        [204, ""]
      end

      results = ClaudeEasy.stub(:selected_profile_name, -> { selected }) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: backup_root, validator: validator,
          auto_reload: true, requester: requester,
          connectivity_checker: -> { true }, usage_profile: 1
        )
      end

      assert_empty put_paths
      originals.each do |path, original|
        assert_equal original, File.binread(path),
                     "profile switch did not restore the aborted batch: #{File.basename(path)}"
      end
      refute results.all? { |result| %i[updated unchanged].include?(result.fetch(:status)) }
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_run_rechecks_profile_context_after_all_files_are_written
    Dir.mktmpdir do |directory|
      %w[config friend other].each do |name|
        File.binwrite(
          File.join(directory, "#{name}.yaml"),
          YAML.dump(base_config.merge("subscription-marker" => name))
        )
      end
      originals = %w[config friend].to_h do |name|
        path = File.join(directory, "#{name}.yaml")
        [path, File.binread(path)]
      end
      selected = "friend"
      validations = 0
      validator = lambda do |_path|
        validations += 1
        selected = "other" if validations == 2
        true
      end

      results = ClaudeEasy.stub(:selected_profile_name, -> { selected }) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"), validator: validator,
          auto_reload: false, usage_profile: 1
        )
      end

      originals.each do |path, original|
        assert_equal original, File.binread(path)
      end
      assert results.any? { |result| result.fetch(:status) == :batch_rolled_back }
    end
  end

  def test_run_without_reload_stops_when_the_current_profile_cannot_be_read
    Dir.mktmpdir do |directory|
      paths = %w[config friend].to_h do |name|
        path = File.join(directory, "#{name}.yaml")
        File.binwrite(path, YAML.dump(base_config.merge("subscription-marker" => name)))
        [name, path]
      end
      originals = paths.transform_values { |path| File.binread(path) }

      results = ClaudeEasy.stub(:selected_profile_name, nil) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"),
          auto_reload: false, validator: ->(_path) { true },
          usage_profile: 1
        )
      end

      assert_equal [:concurrent_change], results.map { |result| result.fetch(:status) }.uniq
      paths.each do |name, path|
        assert_equal originals.fetch(name), File.binread(path)
      end
    end
  end

  def test_runtime_selection_guard_ignores_automatic_url_test_groups
    requester = lambda do |_method, _endpoint, _body|
      [200, JSON.generate("proxies" => {
        "Main" => { "type" => "Selector", "now" => "Singapore" },
        "Automatic" => { "type" => "URLTest", "now" => "Japan" }
      })]
    end

    assert_equal({ "Main" => "Singapore" }, ClaudeEasy.runtime_selections(requester))
  end

  def test_runtime_profile_context_guards_fail_closed
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))

      selected_reads = %w[friend other]
      unstable = ClaudeEasy.stub(:selected_profile_name, -> { selected_reads.shift }) do
        ClaudeEasy.capture_runtime_profile_context([directory])
      end
      assert_nil unstable

      File.stub(:realpath, ->(_path) { raise Errno::ENOENT }) do
        ClaudeEasy.stub(:selected_profile_name, "friend") do
          assert_nil ClaudeEasy.capture_runtime_profile_context([directory])
        end
      end

      ClaudeEasy.stub(:selected_profile_name, nil) do
        assert_nil ClaudeEasy.capture_runtime_profile_context([directory])
      end
      ClaudeEasy.stub(:selected_profile_name, "missing") do
        assert_nil ClaudeEasy.capture_runtime_profile_context([directory])
      end

      refute ClaudeEasy.runtime_profile_context_current?("invalid", [directory])
      ClaudeEasy.stub(:capture_runtime_profile_context, ->(*_args, **_kwargs) { raise "changed" }) do
        refute ClaudeEasy.runtime_profile_context_current?({}, [directory])
      end
      assert ClaudeEasy.runtime_precommit_allowed?(nil)
      assert ClaudeEasy.runtime_precommit_allowed?(-> { true })
      refute ClaudeEasy.runtime_precommit_allowed?(-> { false })
      refute ClaudeEasy.runtime_precommit_allowed?(-> { raise "changed" })

      results = ClaudeEasy.stub(:capture_runtime_profile_context, nil) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"),
          auto_reload: true, validator: ->(_path) { flunk "unstable context reached validation" }
        )
      end
      assert_equal [:concurrent_change], results.map { |result| result.fetch(:status) }.uniq

      target = {
        name: "friend", path: profile,
        url: "https://subscriptions.invalid/friend"
      }
      result = ClaudeEasy.stub(:capture_runtime_profile_context, nil) do
        ClaudeEasy.safe_update_all(
          targets: [target], policy: @policy,
          backup_root: File.join(directory, "safe-backups"), usage_profile: 1,
          fetcher: ->(_item) { flunk "unstable context reached download" },
          validator: ->(_path) { true }
        )
      end
      assert_equal :aborted, result.fetch(:status)
      assert_equal :client_state_changed, result.fetch(:reason)
    end
  end

  def test_public_transaction_recovery_forwards_the_live_profile_guard
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      FileUtils.mkdir_p(backup_root)
      File.write(profile, YAML.dump(base_config))
      File.write(ClaudeEasy.profile_transaction_path(backup_root), "{}\n")
      forwarded = false
      resume = lambda do |_root, roots:, work_items:, reload_runtime:, require_tun:,
                         precommit_condition:, **_keywords|
        assert_equal [directory], roots
        assert work_items.any? { |item| item.fetch(:active) }
        assert reload_runtime
        assert_equal :preserve, require_tun
        assert precommit_condition.call
        forwarded = true
        :recovered
      end

      result = ClaudeEasy.stub(:selected_profile_name, "friend") do
        ClaudeEasy.stub(:resume_profile_transaction, resume) do
          ClaudeEasy.recover_pending_profile_transaction(
            backup_root, directories: [directory]
          )
        end
      end

      assert_equal :recovered, result
      assert forwarded
    end
  end

  def test_route_verifier_rejects_direct_hidden_below_ai_selector
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      proxies = { "proxies" => {
        "Main" => { "type" => "Selector", "now" => "Taiwan" },
        "AI" => { "type" => "Selector", "now" => "Nested" },
        "Taiwan" => { "type" => "Shadowsocks" },
        "Nested" => { "type" => "Selector", "now" => "DIRECT" },
        "DIRECT" => { "type" => "Direct" }
      } }
      observations = [
        { "chains" => ["Taiwan", "Main"] },
        { "chains" => ["DIRECT", "Nested", "AI"] },
        { "chains" => ["DIRECT", "Nested", "AI"] },
        { "chains" => ["DIRECT", "Nested", "AI"] }
      ]

      ClaudeEasy.stub(:controller_socket, "socket") do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashRouteVerifier.stub(:get_json, route_controller_getter(proxies)) do
            ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
              refute ClashRouteVerifier.run(output: StringIO.new)
            end
          end
        end
      end
    end
  end

  def test_route_verifier_force_reaps_a_curl_process_that_ignores_term
    reader, writer = IO.pipe
    pid = Process.spawn(RbConfig.ruby, "-e", 'trap("TERM") {}; STDOUT.puts("ready"); STDOUT.flush; sleep 30', out: writer)
    writer.close
    assert_equal "ready\n", reader.gets
    reader.close
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ClashRouteVerifier.terminate_process(pid, grace_seconds: 0.05)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1
    assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
  ensure
    Process.kill("KILL", pid) rescue nil
    Process.waitpid(pid) rescue nil
  end

  def test_active_reload_fails_when_an_existing_selector_disappears
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      candidate = YAML.dump(base_config.merge("changed" => true))
      File.binwrite(profile, candidate)
      proxy_reads = 0
      requester = lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          proxy_reads += 1
          body = proxy_reads == 2 ? {} : { "Main" => { "type" => "Selector", "now" => "Taiwan" } }
          [200, JSON.generate("proxies" => body)]
        when ["PUT", "/configs?force=true"], ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      committed = File.stat(profile)
      result = ClaudeEasy.activate_updated_profile(
        {
          path: profile, rollback_bytes: original.b,
          patched_digest: Digest::SHA256.hexdigest(candidate.b),
          patched_identity: [committed.dev, committed.ino],
          patched_path: File.realpath(profile)
        },
        requester: requester, connectivity_checker: -> { true }
      )

      assert_equal :reload_failed_rolled_back, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_profile_three_rolls_back_when_the_ai_group_resolves_to_direct
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      requester = lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" },
            "台湾家宽 01" => { "type" => "Shadowsocks" },
            "AI" => { "type" => "Selector", "now" => "DIRECT" },
            "DIRECT" => { "type" => "Direct" }
          })]
        when ["PUT", "/configs?force=true"], ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      result = ClaudeEasy.run(
        directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
        selected_name: "friend", validator: ->(_path) { true },
        auto_reload: true, requester: requester,
        connectivity_checker: -> { true }, usage_profile: 3
      ).first

      assert_equal :reload_failed_rolled_back, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_profile_three_checks_the_ai_path_when_the_active_file_is_unchanged
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      patched = ClaudeEasy.patch(base_config, @policy, usage_profile: 3).fetch(:config)
      File.write(profile, YAML.dump(patched))
      requests = []
      requester = lambda do |method, endpoint, _body = nil|
        requests << [method, endpoint]
        if [method, endpoint] == ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "AI" => { "type" => "Selector", "now" => "DIRECT" },
            "DIRECT" => { "type" => "Direct" }
          })]
        else
          [404, ""]
        end
      end

      result = ClaudeEasy.run(
        directory: directory, policy_path: POLICY_PATH, backup_root: File.join(directory, "backups"),
        selected_name: "friend", validator: ->(_path) { true }, auto_reload: true,
        requester: requester, connectivity_checker: -> { true }, usage_profile: 3
      ).first

      assert_equal :runtime_check_failed, result.fetch(:status)
      refute requests.any? { |method, endpoint| method == "PUT" && endpoint == "/configs?force=true" }

      requests.clear
      result = ClaudeEasy.run(
        directory: directory, policy_path: POLICY_PATH, backup_root: File.join(directory, "backups"),
        selected_name: "friend", validator: ->(_path) { true }, auto_reload: false,
        requester: requester, connectivity_checker: -> { true }, usage_profile: 3
      ).first

      assert_equal :runtime_check_failed, result.fetch(:status)
      assert requests.any? { |method, endpoint| method == "GET" && endpoint == "/proxies" }
      refute requests.any? { |method, endpoint| method == "PUT" && endpoint == "/configs?force=true" }

      ClaudeEasy.stub(:controller_socket, nil) do
        checked = ClaudeEasy.verify_unchanged_profile_runtime(
          { path: profile, status: :unchanged }, require_safe_ai: true
        )
        assert_equal :runtime_check_failed, checked.fetch(:status)
      end
      ClaudeEasy.stub(:controller_socket, "socket") do
        ClaudeEasy.stub(:controller_request, ->(_socket, method, endpoint, body) {
          requester.call(method, endpoint, body)
        }) do
          checked = ClaudeEasy.verify_unchanged_profile_runtime(
            { path: profile, status: :unchanged }, require_safe_ai: true
          )
          assert_equal :runtime_check_failed, checked.fetch(:status)
        end
      end
      checked = ClaudeEasy.verify_unchanged_profile_runtime(
        { status: :unchanged }, requester: requester, require_safe_ai: true
      )
      assert_equal :runtime_check_failed, checked.fetch(:status)
    end
  end

  def test_unchanged_active_profile_runs_full_non_mutating_runtime_acceptance
    [1, 2, 3].each do |usage_profile|
      Dir.mktmpdir do |directory|
        profile = File.join(directory, "friend.yaml")
        patch_result = ClaudeEasy.patch(base_config, @policy, usage_profile: usage_profile)
        File.write(profile, YAML.dump(patch_result.fetch(:config)))
        ai_group = patch_result[:ai_group]
        requests = []
        proxies = {
          "Main" => { "type" => "Selector", "now" => "node" },
          "node" => { "type" => "Shadowsocks" }
        }
        if ai_group
          proxies[ai_group] = { "type" => "Selector", "now" => usage_profile == 3 ? "DIRECT" : "node" }
          proxies["DIRECT"] = { "type" => "Direct" }
        end
        requester = lambda do |method, endpoint, _body = nil|
          requests << [method, endpoint]
          case [method, endpoint]
          when ["GET", "/proxies"]
            [200, JSON.generate("proxies" => proxies)]
          when ["GET", "/configs"]
            [200, JSON.generate("tun" => { "enable" => usage_profile != 2 })]
          else
            if method == "GET" && endpoint.start_with?("/dns/query?")
              [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
            else
              [404, ""]
            end
          end
        end

        result = ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"), selected_name: "friend",
          validator: ->(_path) { true }, auto_reload: false, requester: requester,
          connectivity_checker: -> { false }, usage_profile: usage_profile
        ).first

        assert_equal :runtime_check_failed, result.fetch(:status), "profile #{usage_profile}"
        assert requests.any? { |method, _endpoint| method == "GET" }, "profile #{usage_profile}"
        refute requests.any? { |method, _endpoint| %w[POST PUT].include?(method) }, "profile #{usage_profile}"
      end
    end
  end

  def test_unchanged_runtime_resolves_required_and_preserved_tun_state
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" },
            "AI" => { "type" => "Selector", "now" => "Main" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        else
          [404, ""]
        end
      end
      expected_tun = []

      ClaudeEasy.stub(:runtime_selections, { "Main" => "台湾家宽 01" }) do
        ClaudeEasy.stub(:runtime_selections_for_profile, { "Main" => "台湾家宽 01" }) do
          ClaudeEasy.stub(:runtime_health_healthy?, true) do
            ClaudeEasy.stub(:runtime_matches_profile?, false) do
              checked = ClaudeEasy.verify_unchanged_profile_runtime(
                { path: profile, status: :unchanged }, requester: requester
              )
              assert_equal :runtime_check_failed, checked.fetch(:status)
            end
          end
        end
      end

      ClaudeEasy.stub(:runtime_matches_profile?, true) do
        ClaudeEasy.stub(:runtime_health_healthy?, lambda { |_requester, **options|
          expected_tun << options.fetch(:expected_tun)
          true
        }) do
          result = { path: profile, status: :unchanged }
          assert_equal result, ClaudeEasy.verify_unchanged_profile_runtime(
            result, requester: requester, require_tun: true
          )
          assert_equal result, ClaudeEasy.verify_unchanged_profile_runtime(
            result, requester: requester, require_tun: :preserve
          )
          assert_equal result, ClaudeEasy.verify_unchanged_profile_runtime(
            result, requester: requester, require_tun: false
          )
        end
      end

      assert_equal [:enabled, :disabled, :ignore], expected_tun
    end
  end

  def test_unchanged_runtime_rejects_missing_disk_selectors
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      patched = ClaudeEasy.patch(base_config, @policy, usage_profile: 1).fetch(:config)
      File.binwrite(profile, YAML.dump(patched))
      requester = lambda do |method, endpoint, _body = nil|
        if [method, endpoint] == ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Unrelated" => { "type" => "Selector", "now" => "other-node" },
            "other-node" => { "type" => "Shadowsocks" }
          })]
        elsif method == "GET" && endpoint.start_with?("/dns/query?")
          [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
        else
          [404, ""]
        end
      end

      result = ClaudeEasy.run(
        directory: directory, policy_path: POLICY_PATH,
        backup_root: File.join(directory, "backups"), selected_name: "friend",
        validator: ->(_path) { true }, auto_reload: false, requester: requester,
        connectivity_checker: -> { true }, usage_profile: 1
      ).first

      assert_equal :runtime_check_failed, result.fetch(:status)
    end
  end

  def test_updated_profile_can_add_a_new_ai_selector_before_runtime_reload
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      patch_result = ClaudeEasy.patch_path(
        profile, @policy, usage_profile: 3, validator: ->(_candidate) { true }
      )
      health_options = nil
      put_paths = []
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "node" },
            "node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        when ["PUT", "/configs?force=true"]
          put_paths << JSON.parse(body).fetch("path")
          [204, ""]
        else
          [404, ""]
        end
      end

      activated = ClaudeEasy.stub(:runtime_health_healthy?, lambda { |_requester, **options|
        health_options = options
        true
      }) do
        ClaudeEasy.activate_updated_profile(
          patch_result, requester: requester, connectivity_checker: -> { true },
          require_tun: true, require_safe_ai: true
        )
      end

      assert_equal true, activated.fetch(:reloaded)
      assert_equal [File.expand_path(profile)], put_paths
      assert_equal({ "Main" => "node" }, health_options.fetch(:selections))
      assert_equal "AI", health_options.fetch(:required_proxy_group)
    end
  end

  def test_activation_does_not_reload_runtime_when_tun_is_unknown_before_candidate_load
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config)
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      result = {
        path: profile, rollback_bytes: original.b,
        patched_digest: Digest::SHA256.hexdigest(candidate.b),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      reloads = 0
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => {})]
        when ["PUT", "/configs?force=true"]
          reloads += 1
          [204, ""]
        else
          raise "unexpected controller request: #{method} #{endpoint}"
        end
      end

      activated = ClaudeEasy.activate_updated_profile(
        result, requester: requester, require_tun: :preserve
      )

      assert_equal :reload_failed_rolled_back, activated.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 0, reloads
    end
  end

  def test_run_stops_before_writing_when_the_runtime_checkpoint_is_unavailable
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)

      results = ClaudeEasy.stub(:selected_profile_name, "active") do
        ClaudeEasy.stub(:storage_mode, :local) do
          ClaudeEasy.stub(:capture_runtime_checkpoint, nil) do
            ClaudeEasy.run(
              directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
              validator: ->(_path) { true }, auto_reload: true, usage_profile: 1
            )
          end
        end
      end

      assert_equal :runtime_check_failed, results.fetch(0).fetch(:status)
      assert_equal original.b, File.binread(profile)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_candidate_reload_restores_existing_selector_before_health_check
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      result = ClaudeEasy.patch_path(
        profile, @policy, usage_profile: 3, validator: ->(_candidate) { true }
      )
      selected = "Taiwan"
      selector_updates = []
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => {
              "type" => "Selector", "now" => selected,
              "all" => ["Taiwan", "Japan"]
            },
            "Taiwan" => { "type" => "Shadowsocks" },
            "Japan" => { "type" => "Shadowsocks" },
            "AI" => {
              "type" => "Selector", "now" => "Taiwan", "all" => ["Taiwan", "Japan"]
            }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        when ["PUT", "/configs?force=true"]
          selected = "Japan"
          [204, ""]
        when ["PUT", "/proxies/Main"]
          selector_updates << JSON.parse(body).fetch("name")
          selected = selector_updates.last
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            raise "unexpected controller request: #{method} #{endpoint}"
          end
        end
      end

      activated = ClaudeEasy.activate_updated_profile(
        result, requester: requester, connectivity_checker: -> { true },
        require_tun: true, require_safe_ai: true
      )

      assert_equal true, activated.fetch(:reloaded)
      assert_equal "Taiwan", selected
      assert_equal ["Taiwan"], selector_updates
    end
  end

  def test_runtime_selector_restore_percent_encodes_controller_path_components
    requested_endpoint = nil
    selected = "Japan"
    requester = lambda do |method, endpoint, _body = nil|
      if method == "GET" && endpoint == "/proxies"
        [200, JSON.generate("proxies" => {
          "AI / 中文" => {
            "type" => "Selector", "now" => selected, "all" => ["Taiwan", "Japan"]
          }
        })]
      elsif method == "PUT"
        requested_endpoint = endpoint
        selected = "Taiwan"
        [204, ""]
      else
        raise "unexpected controller request: #{method} #{endpoint}"
      end
    end

    assert ClaudeEasy.restore_runtime_selections(
      requester, { "AI / 中文" => "Taiwan" }
    )
    assert_equal "/proxies/AI%20%2F%20%E4%B8%AD%E6%96%87", requested_endpoint
  end

  def test_runtime_rollback_restores_existing_selector_after_original_reload
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "original"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      result = {
        path: profile, rollback_bytes: original.b,
        patched_digest: Digest::SHA256.hexdigest(candidate.b),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      selected = "Taiwan"
      reloads = 0
      selector_updates = []
      connectivity_checks = 0
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => {
              "type" => "Selector", "now" => selected,
              "all" => ["Taiwan", "Japan"]
            },
            "Taiwan" => { "type" => "Shadowsocks" },
            "Japan" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        when ["PUT", "/configs?force=true"]
          reloads += 1
          selected = "Japan"
          [204, ""]
        when ["PUT", "/proxies/Main"]
          selector_updates << JSON.parse(body).fetch("name")
          selected = selector_updates.last
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            raise "unexpected controller request: #{method} #{endpoint}"
          end
        end
      end
      connectivity = lambda do
        connectivity_checks += 1
        reloads > 1
      end

      activated = ClaudeEasy.stub(:sleep, nil) do
        ClaudeEasy.activate_updated_profile(
          result, requester: requester, connectivity_checker: connectivity,
          require_tun: true
        )
      end

      assert_equal :reload_failed_rolled_back, activated.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal "Taiwan", selected
      assert_equal 2, reloads
      assert_equal ["Taiwan", "Taiwan"], selector_updates
    end
  end

  def test_unchanged_batch_rechecks_every_file_after_runtime_acceptance
    Dir.mktmpdir do |directory|
      patched = ClaudeEasy.patch(base_config, @policy, usage_profile: 1).fetch(:config)
      config_path = File.join(directory, "other.yaml")
      friend_path = File.join(directory, "friend.yaml")
      File.binwrite(config_path, YAML.dump(patched))
      File.binwrite(friend_path, YAML.dump(patched))
      replacement = YAML.dump(base_config.merge("subscription-marker" => "external"))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "node" },
            "AI" => { "type" => "Selector", "now" => "Main" },
            "node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end
      refreshed = false
      connectivity_checker = lambda do
        unless refreshed
          temporary = File.join(directory, ".external-refresh.yaml")
          File.binwrite(temporary, replacement)
          File.rename(temporary, config_path)
          refreshed = true
        end
        true
      end

      results = ClaudeEasy.stub(:runtime_matches_profile?, true) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"), selected_name: "friend",
          validator: ->(_path) { true }, auto_reload: false, requester: requester,
          connectivity_checker: connectivity_checker, usage_profile: 1
        )
      end

      assert results.any? { |result| result.fetch(:status) == :updated }, results.inspect
      final_config = ClaudeEasy.load_yaml(File.binread(config_path), config_path)
      assert_equal "external", final_config.fetch("subscription-marker")
      refute ClaudeEasy.patch(final_config, @policy, usage_profile: 1).fetch(:changed)
    end
  end

  def test_runtime_ai_path_rejects_nested_non_proxy_cycles_and_unsafe_load_balance_members
    safe_node = { "type" => "Shadowsocks" }
    nested_direct = {
      "AI" => { "type" => "Selector", "now" => "Nested" },
      "Nested" => { "type" => "Fallback", "now" => "Local" },
      "Local" => { "type" => "Direct" }
    }
    cycle = {
      "AI" => { "type" => "Selector", "now" => "Nested" },
      "Nested" => { "type" => "URLTest", "now" => "AI" }
    }
    safe_balance = {
      "AI" => { "type" => "LoadBalance", "all" => %w[node-a node-b] },
      "node-a" => safe_node,
      "node-b" => { "type" => "Vmess" }
    }
    unsafe_balance = safe_balance.merge(
      "AI" => { "type" => "LoadBalance", "all" => %w[node-a local] },
      "local" => { "type" => "Direct" }
    )
    relay = {
      "AI" => { "type" => "Selector", "now" => "Relay" },
      "Relay" => { "type" => "Relay", "all" => ["DIRECT"] },
      "DIRECT" => { "type" => "Direct" }
    }
    unknown_group = {
      "AI" => { "type" => "Selector", "now" => "FutureGroup" },
      "FutureGroup" => { "type" => "FutureGroup", "all" => ["safe-node"] },
      "safe-node" => safe_node
    }

    refute ClaudeEasy.runtime_proxy_path_safe?(nested_direct, "AI")
    refute ClaudeEasy.runtime_proxy_path_safe?(cycle, "AI")
    assert ClaudeEasy.runtime_proxy_path_safe?(safe_balance, "AI")
    refute ClaudeEasy.runtime_proxy_path_safe?(unsafe_balance, "AI")
    refute ClaudeEasy.runtime_proxy_path_safe?(relay, "AI")
    refute ClaudeEasy.runtime_proxy_path_safe?(unknown_group, "AI")
    refute ClaudeEasy.runtime_proxy_candidates_safe?(
      { "AI" => { "type" => "Selector", "now" => "shared" } },
      { "shared" => [{ "name" => "shared", "type" => "Relay", "all" => ["DIRECT"] }] },
      "shared", { "AI" => true }
    )

    Dir.mktmpdir do |directory|
      assert_nil ClaudeEasy.profile_ai_runtime_group(File.join(directory, "missing.yaml"))
      direct = base_config
      direct["rules"] = ["NETWORK,UDP,DIRECT", "NETWORK,UDP,REJECT"]
      path = File.join(directory, "direct.yaml")
      File.write(path, YAML.dump(direct))
      assert_nil ClaudeEasy.profile_ai_runtime_group(path)
      refute ClaudeEasy.restore_candidate_valid?(
        path, 3, policy: @policy, validator: ->(_candidate) { true }
      )
      refute ClaudeEasy.restore_candidate_valid?(
        path, 2, validator: ->(_candidate) { raise "validator failed" }
      )

      incomplete = base_config
      incomplete["proxy-groups"] << {
        "name" => "AI", "type" => "select", "proxies" => ["Taiwan"]
      }
      incomplete["rules"] = ["NETWORK,UDP,AI", "NETWORK,UDP,REJECT", "MATCH,DIRECT"]
      File.write(path, YAML.dump(incomplete))
      assert_equal "AI", ClaudeEasy.profile_ai_runtime_group(path)
      refute ClaudeEasy.restore_candidate_valid?(
        path, 3, policy: @policy, validator: ->(_candidate) { true }
      )

      complete = ClaudeEasy.render_ai_rules(@policy, "AI")
      rejects = complete.map { |rule| ClaudeEasy.rule_with_target(rule, "REJECT") }
      cn_provider = ClaudeEasy.ensure_cn_provider(incomplete, @policy, "Main")
      cn_ip_provider = ClaudeEasy.ensure_cn_ip_provider(incomplete, @policy, "Main")
      managed_tail = [
        "RULE-SET,#{cn_provider},DIRECT",
        ClaudeEasy.render_cn_udp_direct_rule(@policy, cn_ip_provider),
        "NETWORK,UDP,AI",
        "NETWORK,UDP,REJECT"
      ]
      incomplete["rules"] = complete + rejects + managed_tail + ["MATCH,DIRECT"]
      File.write(path, YAML.dump(incomplete))
      refute ClaudeEasy.restore_candidate_valid?(
        path, 3, policy: @policy, validator: ->(_candidate) { true }
      )
      incomplete["rules"] = complete + rejects + @policy.fetch("lan_udp_direct_rules") +
                            managed_tail + ["MATCH,DIRECT"]
      incomplete = ClaudeEasy.patch(incomplete, @policy, usage_profile: 3).fetch(:config)
      File.write(path, YAML.dump(incomplete))
      assert ClaudeEasy.restore_candidate_valid?(
        path, 3, policy: @policy, validator: ->(_candidate) { true }
      )
      managed_cn_provider = Marshal.load(
        Marshal.dump(incomplete.fetch("rule-providers").fetch(cn_provider))
      )
      managed_cn_ip_provider = Marshal.load(
        Marshal.dump(incomplete.fetch("rule-providers").fetch(cn_ip_provider))
      )
      corruptions = [
        [cn_ip_provider, "type", "file"],
        [cn_ip_provider, "behavior", "domain"],
        [cn_ip_provider, "format", "yaml"],
        [cn_ip_provider, "interval", 60],
        [cn_ip_provider, "size-limit", 1],
        [cn_provider, "proxy", "DIRECT"],
        [cn_provider, "unexpected", true]
      ]
      corruptions.each do |provider_name, field, value|
        incomplete.fetch("rule-providers").fetch(provider_name)[field] = value
        File.write(path, YAML.dump(incomplete))
        refute ClaudeEasy.restore_candidate_valid?(
          path, 3, policy: @policy, validator: ->(_candidate) { true }
        ), "#{provider_name}.#{field}"
        incomplete.fetch("rule-providers")[cn_provider] = Marshal.load(Marshal.dump(managed_cn_provider))
        incomplete.fetch("rule-providers")[cn_ip_provider] = Marshal.load(Marshal.dump(managed_cn_ip_provider))
      end
      incomplete["rules"].insert(1, "MATCH,DIRECT")
      File.write(path, YAML.dump(incomplete))
      refute ClaudeEasy.restore_candidate_valid?(
        path, 3, policy: @policy, validator: ->(_candidate) { true }
      )
      incomplete["rules"].delete_at(1)
      incomplete.fetch("rule-providers")[cn_provider] = {
        "type" => "file", "behavior" => "domain", "path" => "./user/cn-domain.mrs"
      }
      File.write(path, YAML.dump(incomplete))
      refute ClaudeEasy.restore_candidate_valid?(
        path, 3, policy: @policy, validator: ->(_candidate) { true }
      )
      incomplete.fetch("rule-providers")[cn_provider] = managed_cn_provider
      incomplete["rules"] = complete + managed_tail + rejects + ["MATCH,DIRECT"]
      File.write(path, YAML.dump(incomplete))
      refute ClaudeEasy.restore_candidate_valid?(
        path, 3, policy: @policy, validator: ->(_candidate) { true }
      )
    end
  end

  def test_runtime_ai_path_accepts_a_proxy_only_exposed_by_its_provider
    requester = lambda do |method, endpoint, _body = nil|
      case [method, endpoint]
      when ["GET", "/proxies"]
        [200, JSON.generate("proxies" => {
          "AI" => { "type" => "Selector", "now" => "Provider Node" }
        })]
      when ["GET", "/providers/proxies"]
        [200, JSON.generate("providers" => {
          "remote" => { "proxies" => [{ "name" => "Provider Node", "type" => "Vmess" }] }
        })]
      when ["GET", "/configs"]
        [200, JSON.generate("tun" => { "enable" => true })]
      when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
        [204, ""]
      else
        if method == "GET" && endpoint.start_with?("/dns/query?")
          [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
        else
          [404, ""]
        end
      end
    end

    assert ClaudeEasy.runtime_health_healthy?(
      requester, selections: { "AI" => "Provider Node" }, expected_tun: :enabled,
      connectivity_checker: -> { true }, required_proxy_group: "AI"
    )

    collision_requester = lambda do |method, endpoint, body = nil|
      if [method, endpoint] == ["GET", "/proxies"]
        [200, JSON.generate("proxies" => {
          "AI" => { "type" => "Selector", "now" => "Provider Node" },
          "Provider Node" => { "type" => "Shadowsocks" }
        })]
      elsif [method, endpoint] == ["GET", "/providers/proxies"]
        [200, JSON.generate("providers" => {
          "remote" => { "proxies" => [{ "name" => "Provider Node", "type" => "Direct" }] }
        })]
      else
        requester.call(method, endpoint, body)
      end
    end
    refute ClaudeEasy.runtime_health_healthy?(
      collision_requester, selections: { "AI" => "Provider Node" }, expected_tun: :enabled,
      connectivity_checker: -> { true }, required_proxy_group: "AI"
    )

    load_balance_requester = lambda do |method, endpoint, body = nil|
      if [method, endpoint] == ["GET", "/proxies"]
        [200, JSON.generate("proxies" => {
          "AI" => { "type" => "LoadBalance", "all" => ["Provider Node"] }
        })]
      else
        requester.call(method, endpoint, body)
      end
    end
    assert ClaudeEasy.runtime_proxy_group_safe?(load_balance_requester, "AI")
    assert_nil ClaudeEasy.runtime_provider_proxies(
      ->(_method, _endpoint, _body) { [200, "{"] }
    )
    refute ClaudeEasy.runtime_proxy_group_safe?(
      ->(_method, _endpoint, _body) { raise "controller failed" }, "AI"
    )
  end

  def test_active_reload_allows_a_removed_legacy_managed_selector
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      safe_group = ClaudeEasy::SAFE_GROUP_BASE
      config = base_config
      config["proxy-groups"] << {
        "name" => safe_group,
        "type" => "select",
        "proxies" => ["台湾家宽 01"],
        "include-all" => true,
        "exclude-type" => ClaudeEasy::EXCLUDED_SAFE_TYPES,
        "empty-fallback" => "REJECT"
      }
      config["rules"].unshift("NETWORK,UDP,#{safe_group}", "NETWORK,UDP,REJECT")
      config["dns"]["nameserver"] = ["https://dns.alidns.com/dns-query##{safe_group}"]
      File.binwrite(profile, YAML.dump(config))
      candidate_loaded = false
      requester = lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          proxies = {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" },
            "AI" => { "type" => "Selector", "now" => "Main" },
            "台湾家宽 01" => { "type" => "Shadowsocks" }
          }
          proxies[safe_group] = { "type" => "Selector", "now" => "台湾家宽 01" } unless candidate_loaded
          [200, JSON.generate("proxies" => proxies)]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        when ["PUT", "/configs?force=true"]
          candidate_loaded = true
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      result = ClaudeEasy.run(
        directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
        selected_name: "friend", validator: ->(_path) { true },
        auto_reload: true, requester: requester,
        connectivity_checker: -> { true }, usage_profile: 3
      ).first

      assert_equal :updated, result.fetch(:status)
      assert_equal true, result.fetch(:reloaded)
      refute ClaudeEasy.load_yaml(File.read(profile)).fetch("proxy-groups").any? { |group|
        group["name"] == safe_group
      }
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_active_reload_never_accepts_a_replaced_candidate_inode
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, candidate)
      committed = File.stat(profile)
      external_identity = nil
      put_calls = 0
      candidate_replaced = false
      post_replace_requests = 0
      requester = lambda do |method, endpoint, _body|
        post_replace_requests += 1 if candidate_replaced
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["PUT", "/configs?force=true"]
          put_calls += 1
          replacement = File.join(directory, "external.yaml")
          File.binwrite(replacement, candidate)
          File.rename(replacement, profile)
          current = File.stat(profile)
          external_identity = [current.dev, current.ino]
          candidate_replaced = true
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => ["203.0.113.1"])]
          else
            [404, ""]
          end
        end
      end

      result = ClaudeEasy.activate_updated_profile(
        {
          path: profile, rollback_bytes: original.b,
          patched_digest: Digest::SHA256.hexdigest(candidate.b),
          patched_identity: [committed.dev, committed.ino],
          patched_path: File.realpath(profile)
        },
        requester: requester, connectivity_checker: -> { true }
      )

      current = File.stat(profile)
      assert_equal 1, put_calls
      assert_equal 0, post_replace_requests
      refute result[:reloaded]
      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_equal candidate.b, File.binread(profile)
      assert_equal external_identity, [current.dev, current.ino]
    end
  end

  def test_reload_failure_does_not_force_the_old_profile_after_a_late_user_switch
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "new"))
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      guard_calls = 0
      precommit = lambda do
        guard_calls += 1
        guard_calls == 1
      end
      put_paths = []
      requester = lambda do |method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["PUT", "/configs?force=true"]
          put_paths << JSON.parse(body).fetch("path")
          [204, ""]
        when ["POST", "/cache/fakeip/flush"]
          [503, ""]
        else
          [204, ""]
        end
      end

      result = ClaudeEasy.activate_updated_profile(
        {
          path: profile, rollback_bytes: original.b,
          patched_digest: Digest::SHA256.hexdigest(candidate.b),
          patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
        },
        requester: requester, connectivity_checker: -> { true },
        require_tun: false, precommit_condition: precommit
      )

      assert_equal [File.expand_path(profile)], put_paths
      assert_equal original.b, File.binread(profile)
      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_operator guard_calls, :>=, 2
    end
  end

  def test_restore_activation_preserves_the_existing_tun_state
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      candidate = YAML.dump(base_config.merge("changed" => true))
      File.binwrite(profile, candidate)
      proxy_body = JSON.generate(
        "proxies" => { "Main" => { "type" => "Selector", "now" => "Taiwan" } }
      )
      requester = lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, proxy_body]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"], ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      committed = File.stat(profile)
      result = ClaudeEasy.activate_updated_profile(
        {
          path: profile, rollback_bytes: original.b,
          patched_digest: Digest::SHA256.hexdigest(candidate.b),
          patched_identity: [committed.dev, committed.ino],
          patched_path: File.realpath(profile)
        },
        requester: requester, connectivity_checker: -> { true }, require_tun: :preserve
      )

      assert_equal true, result[:reloaded]
      assert_equal candidate.b, File.binread(profile)
    end
  end

  def test_profile_one_activation_does_not_query_or_gate_on_tun
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      candidate = YAML.dump(base_config.merge("changed" => true))
      File.binwrite(profile, candidate)
      requester = lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          flunk "profile 1 must not inspect TUN"
        when ["PUT", "/configs?force=true"], ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => ["203.0.113.1"])]
          else
            [404, ""]
          end
        end
      end

      committed = File.stat(profile)
      result = ClaudeEasy.activate_updated_profile(
        {
          path: profile, rollback_bytes: "original",
          patched_digest: Digest::SHA256.hexdigest(candidate.b),
          patched_identity: [committed.dev, committed.ino],
          patched_path: File.realpath(profile)
        },
        requester: requester, connectivity_checker: -> { true }, require_tun: false
      )

      assert_equal true, result.fetch(:reloaded)
      assert_equal candidate.b, File.binread(profile)
    end
  end

  def test_activation_restores_profile_when_tun_state_is_unknown
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      candidate = YAML.dump(base_config.merge("changed" => true))
      File.binwrite(profile, candidate)
      reloads = 0
      requester = lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => nil })]
        when ["PUT", "/configs?force=true"]
          reloads += 1
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          [404, ""]
        end
      end

      committed = File.stat(profile)
      result = ClaudeEasy.activate_updated_profile(
        {
          path: profile, rollback_bytes: original.b,
          patched_digest: Digest::SHA256.hexdigest(candidate.b),
          patched_identity: [committed.dev, committed.ino],
          patched_path: File.realpath(profile)
        },
        requester: requester, connectivity_checker: -> { true }, require_tun: :preserve
      )

      assert_equal :reload_failed_rolled_back, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 0, reloads
    end
  end

  def test_failed_active_reload_restores_the_exact_original_profile
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      reloads = 0
      requester = lambda do |method, endpoint, _body|
        if method == "GET" && endpoint == "/proxies"
          [200, JSON.generate("proxies" => { "Main" => { "type" => "Selector", "now" => "台湾家宽 01" } })]
        elsif method == "GET" && endpoint == "/configs"
          [200, JSON.generate("tun" => { "enable" => false })]
        elsif method == "PUT" && endpoint == "/configs?force=true"
          reloads += 1
          [reloads == 1 ? 204 : 401, ""]
        elsif method == "POST" && endpoint == "/cache/fakeip/flush"
          [503, ""]
        else
          [404, ""]
        end
      end

      result = ClaudeEasy.run(
        directory: directory,
        policy_path: POLICY_PATH,
        backup_root: backup_root,
        selected_name: "friend",
        auto_reload: true,
        requester: requester,
        connectivity_checker: -> { true }
      ).first

      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 2, reloads
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
      assert_includes ClaudeEasy.chinese_status(result), "运行内核恢复失败"
    end
  end

  def test_runtime_health_failure_reloads_the_restored_profile
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      reload_bodies = []
      requester = lambda do |method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => { "Main" => { "type" => "Selector", "now" => "台湾家宽 01" } })]
        when ["PUT", "/configs?force=true"]
          reload_bodies << body
          [204, ""]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        else
          [404, ""]
        end
      end

      result = ClaudeEasy.run(
        directory: directory,
        policy_path: POLICY_PATH,
        selected_name: "friend",
        auto_reload: true,
        requester: requester,
        connectivity_checker: -> { true }
      ).first

      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 2, reload_bodies.length
    end
  end

  def test_status_output_contains_no_secrets
    Dir.mktmpdir do |directory|
      config = base_config
      config["proxies"].first.merge!(
        "server" => "secret-server.internal.example",
        "password" => "secret-password-123",
        "uuid" => "11111111-2222-3333-4444-555555555555"
      )
      File.write(File.join(directory, "friend.yaml"), YAML.dump(config))

      results = ClaudeEasy.run(directory: directory, policy_path: POLICY_PATH, backup_root: File.join(directory, "backups"),
                               selected_name: "friend")
      output = results.map { |entry| ClaudeEasy.chinese_status(entry) }.join("\n")
      ["secret-server.internal.example", "secret-password-123", "11111111-2222-3333-4444-555555555555"].each do |secret|
        refute_includes output, secret
      end
    end
  end

  def test_status_labels_remove_terminal_controls_and_secret_shapes
    result = {
      path: "/profiles/\e[31m11111111-2222-3333-4444-555555555555.yaml",
      status: :updated,
      active: false,
      ai_group: "node\e]0;owned\a password=secret-value 11111111-2222-3333-4444-555555555555"
    }

    output = ClaudeEasy.chinese_status(result)

    refute_includes output, "\e"
    refute_includes output, "\a"
    refute_includes output, "11111111-2222-3333-4444-555555555555"
    refute_includes output, "secret-value"
  end

  def test_status_output_never_includes_an_ai_group_name
    ai_group = "ACME Taiwan Enterprise"
    output = ClaudeEasy.chinese_status(
      path: "/profiles/friend.yaml", status: :updated, active: false,
      ai_group: ai_group, ai_group_created: false, ai_group_reset: false
    )

    refute_includes output, ai_group
    assert_includes output, "已复用 AI 分组"
  end

  def test_safe_labels_hide_absolute_paths
    output = ClaudeEasy.safe_label("failed at /Users/private/Clash/config.yaml and C:\\Users\\private\\Clash\\config.yaml")

    refute_includes output, "/Users/private"
    refute_includes output, "C:\\Users\\private"
    assert_includes output, "[路径已隐藏]"
  end

  def test_safe_labels_hide_all_proxy_uri_schemes
    output = ClaudeEasy.safe_label("ss://secret@example trojan://password@example vless://uuid@example")

    refute_includes output, "secret"
    refute_includes output, "password"
    refute_includes output, "uuid"
    assert_equal 3, output.scan("[已隐藏]").length
  end

  def test_safe_labels_hide_a_uuid_next_to_unicode_text
    output = ClaudeEasy.safe_label("订阅11111111-2222-3333-4444-555555555555配置")

    refute_includes output, "11111111-2222-3333-4444-555555555555"
  end

  def test_safe_labels_hide_sensitive_shapes_next_to_unicode_text
    output = ClaudeEasy.safe_label(
      "错误password=private结束 错误Bearer private结束 错误https://secret.invalid/path结束"
    )

    refute_includes output, "private"
    refute_includes output, "secret.invalid"
    refute_match(/Bearer\s+/i, output)
    refute_match(/password\s*[:=]/i, output)
  end

  def test_backup_directory_and_files_use_private_permissions
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      File.chmod(0o644, profile)
      backup = File.join(directory, "backups")

      ClaudeEasy.patch_path(profile, @policy, backup_root: backup)

      assert_equal "700", format("%o", File.stat(backup).mode & 0o777)
      backup_file = Dir.glob(File.join(backup, "*.backup")).first
      refute_nil backup_file
      assert_equal "600", format("%o", File.stat(backup_file).mode & 0o777)
      assert_equal "644", format("%o", File.stat(profile).mode & 0o777)
    end
  end

  def test_yaml_12_plain_strings_survive_round_trip
    text = <<~YAML
      proxies:
        - name: node
          type: socks5
          server: example.com
          port: 443
          username: yes
          password: on
          sni: 0123
          client-fingerprint: 1:20
      proxy-groups:
        - name: Main
          type: select
          proxies: [node]
      rules: [MATCH,Main]
      expire: 2026-07-21
    YAML

    loaded = ClaudeEasy.load_yaml(text)
    proxy = loaded.fetch("proxies").first
    assert_equal "yes", proxy.fetch("username")
    assert_equal "on", proxy.fetch("password")
    assert_equal "0123", proxy.fetch("sni")
    assert_equal "1:20", proxy.fetch("client-fingerprint")
    assert_equal "2026-07-21", loaded.fetch("expire")

    Dir.mktmpdir do |directory|
      path = File.join(directory, "config.yaml")
      File.write(path, text)
      result = ClaudeEasy.patch_path(path, @policy)
      assert_equal :updated, result.fetch(:status)
      round_trip = ClaudeEasy.load_yaml(File.read(path))
      values = %w[username password sni client-fingerprint].map { |key| round_trip.fetch("proxies").first.fetch(key) }
      assert_equal ["yes", "on", "0123", "1:20"], values
      assert_equal "2026-07-21", round_trip.fetch("expire")
    end
  end

  def test_dns_policy_preserves_only_verified_non_direct_targets
    config = base_config
    config["proxy-groups"] << { "name" => "SafeExisting", "type" => "select", "proxies" => ["台湾家宽 01"] }
    config["proxy-groups"] << { "name" => "CanDirect", "type" => "select", "proxies" => ["台湾家宽 01", "DIRECT"] }
    config["dns"]["nameserver-policy"] = {
      "+.proxy.example" => ["https://1.1.1.1/dns-query#台湾家宽 01"],
      "+.group.example" => ["https://1.1.1.1/dns-query#SafeExisting"],
      "+.direct.example" => ["https://1.1.1.1/dns-query#CanDirect"],
      "+.option.example" => ["https://1.1.1.1/dns-query#h3=true"],
      "+.interface.example" => ["https://1.1.1.1/dns-query#en0"],
      "+.overridden.example" => ["https://1.1.1.1/dns-query#SafeExisting&DIRECT"],
      "+.encoded-overridden.example" => ["https://1.1.1.1/dns-query#SafeExisting&%44IRECT"],
      "+.multi-fragment.example" => ["https://1.1.1.1/dns-query#h3=true#&skip-cert-verify=true&SafeExisting"]
    }
    result = ClaudeEasy.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")

    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}#台湾家宽 01" }, policies.fetch("+.proxy.example")
    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}#SafeExisting" }, policies.fetch("+.group.example")
    %w[
      +.direct.example +.option.example +.interface.example
      +.overridden.example +.encoded-overridden.example +.multi-fragment.example
    ].each do |pattern|
      assert policies.fetch(pattern).all? { |value| value.end_with?("##{result.fetch(:route_group)}") }, pattern
    end
  end

  def test_dns_policy_rejects_plaintext_and_dynamic_group_targets
    config = base_config
    config["proxy-providers"] = { "provider1" => { "type" => "http", "url" => "https://example.invalid/sub" } }
    config["proxy-groups"] << { "name" => "ProviderGroup", "type" => "select", "use" => ["provider1"] }
    config["proxy-groups"] << {
      "name" => "IncludeAllGroup", "type" => "select", "include-all" => true,
      "exclude-type" => "Indirect"
    }
    config["dns"]["nameserver-policy"] = {
      "+.encrypted.example" => ["https://1.1.1.1/dns-query#台湾家宽 01"],
      "+.plaintext.example" => ["1.1.1.1#台湾家宽 01"],
      "+.provider.example" => ["https://1.1.1.1/dns-query#ProviderGroup"],
      "+.include-all.example" => ["https://1.1.1.1/dns-query#IncludeAllGroup"]
    }

    result = ClaudeEasy.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")
    safe_suffix = "##{result.fetch(:route_group)}"

    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}#台湾家宽 01" }, policies.fetch("+.encrypted.example")
    %w[+.plaintext.example +.provider.example +.include-all.example].each do |pattern|
      assert policies.fetch(pattern).all? { |endpoint| endpoint.end_with?(safe_suffix) }, pattern
    end
  end

  def test_dns_policy_refuses_subscription_filtered_groups_and_dns_outbounds
    config = base_config
    original_main = Marshal.load(Marshal.dump(config.fetch("proxy-groups").find { |group| group["name"] == "Main" }))
    config["proxies"] << { "name" => "InternalDNS", "type" => "dns" }
    config["proxy-groups"].push(
      {
        "name" => "FilteredToCompatible", "type" => "select", "proxies" => ["台湾家宽 01"],
        "exclude-filter" => "台湾"
      },
      {
        "name" => "FilteredToSafeProxy", "type" => "select", "proxies" => ["台湾家宽 01"],
        "exclude-filter" => "台湾", "empty-fallback" => "日本家宽 01"
      },
      { "name" => "DnsOutboundGroup", "type" => "select", "proxies" => ["InternalDNS"] }
    )
    config["dns"]["nameserver-policy"] = {
      "+.compatible.example" => ["https://1.1.1.1/dns-query#FilteredToCompatible"],
      "+.fallback.example" => ["https://1.1.1.1/dns-query#FilteredToSafeProxy"],
      "+.dns-out.example" => ["https://1.1.1.1/dns-query#DnsOutboundGroup"]
    }

    result = ClaudeEasy.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")
    safe_suffix = "##{result.fetch(:route_group)}"
    main_group = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == result.fetch(:route_group) }

    assert policies.fetch("+.compatible.example").all? { |endpoint| endpoint.end_with?(safe_suffix) }
    assert policies.fetch("+.fallback.example").all? { |endpoint| endpoint.end_with?(safe_suffix) }
    assert policies.fetch("+.dns-out.example").all? { |endpoint| endpoint.end_with?(safe_suffix) }
    assert_equal original_main, main_group
  end

  def test_dns_policy_rejects_privacy_weakening_resolver_options
    config = base_config
    target = "台湾家宽 01"
    config["dns"]["nameserver-policy"] = {
      "+.h3.example" => ["https://1.1.1.1/dns-query##{target}&h3=true"],
      "+.skip-cert.example" => ["https://1.1.1.1/dns-query##{target}&skip-cert-verify=true"],
      "+.ecs.example" => ["https://1.1.1.1/dns-query##{target}&ecs=203.0.113.0/24&ecs-override=true"],
      "+.encoded-skip-cert.example" => ["https://1.1.1.1/dns-query##{target}&skip-cert-verify%3Dtrue"],
      "+.encoded-ecs.example" => ["https://1.1.1.1/dns-query##{target}&%65cs=203.0.113.0/24"]
    }

    result = ClaudeEasy.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")
    safe_suffix = "##{result.fetch(:route_group)}"

    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}##{target}&h3=true" }, policies.fetch("+.h3.example")
    %w[+.skip-cert.example +.ecs.example +.encoded-skip-cert.example +.encoded-ecs.example].each do |pattern|
      assert policies.fetch(pattern).all? { |endpoint| endpoint.end_with?(safe_suffix) }, pattern
    end
  end

  def test_null_proxy_providers_do_not_crash_dns_validation
    config = base_config
    config["proxy-providers"] = nil
    config["proxy-groups"] << { "name" => "NullProviderGroup", "type" => "select", "use" => ["missing"] }
    config["dns"]["nameserver-policy"] = {
      "+.null-provider.example" => ["https://1.1.1.1/dns-query#NullProviderGroup"]
    }

    result = ClaudeEasy.patch(config, @policy)

    assert_equal :updated, result.fetch(:status)
    assert result.fetch(:config).dig("dns", "nameserver-policy", "+.null-provider.example").all? do |endpoint|
      endpoint.end_with?("##{result.fetch(:route_group)}")
    end
  end

  def test_direct_and_rematch_home_names_are_not_selected_automatically
    config = base_config
    config["proxies"].unshift(
      { "name" => "台湾家宽 DIRECT", "type" => "direct" },
      { "name" => "台湾家宽 REMATCH", "type" => "rematch", "target-rematch-name" => "again" }
    )
    config["proxy-groups"].find { |group| group["name"] == "Main" }["proxies"].unshift(
      "台湾家宽 DIRECT", "台湾家宽 REMATCH"
    )

    result = ClaudeEasy.patch(config, @policy)
    main = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == "Main" }

    refute result.key?(:selected_home)
    assert_includes main.fetch("proxies"), "台湾家宽 DIRECT"
    assert_includes main.fetch("proxies"), "台湾家宽 REMATCH"
    refute result.fetch(:config).fetch("proxy-groups").any? { |group| ClaudeEasy.managed_name?(group["name"], ClaudeEasy::SAFE_GROUP_BASE) }
  end

  def test_owned_ai_group_is_independent_and_collision_safe
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    config["proxy-groups"] << { "name" => "🤖 AI · ClaudeEasy", "type" => "url-test", "proxies" => ["台湾家宽 01"] }
    config["proxy-groups"] << { "name" => "🤖 AI · ClaudeEasy 2", "type" => "url-test", "proxies" => ["台湾家宽 01"] }
    result = ClaudeEasy.patch(config, @policy)
    names = result.fetch(:config).fetch("proxy-groups").map { |group| group["name"] }

    assert_equal names.uniq, names
    assert_equal "🤖 AI · ClaudeEasy 3", result.fetch(:ai_group)
    managed = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == result.fetch(:ai_group) }
    assert_equal ["台湾家宽 01", "日本家宽 01", "美国家宽 01"], managed.fetch("proxies")
  end

  def test_user_owned_branded_select_group_is_preserved
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    user_group = {
      "name" => ClaudeEasy::AI_GROUP_BASE,
      "type" => "select",
      "proxies" => ["Main"]
    }
    config["proxy-groups"] << user_group

    first = ClaudeEasy.patch(config, @policy)
    second = ClaudeEasy.patch(first.fetch(:config), @policy)
    preserved = first.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == user_group["name"] }

    assert_equal user_group, preserved
    assert_equal user_group, second.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == user_group["name"] }
    assert_equal ClaudeEasy::AI_GROUP_BASE, first.fetch(:ai_group)
    refute second.fetch(:changed)
  end

  def test_branded_user_group_with_ai_rules_is_not_mistaken_for_patch_ownership
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    user_group = {
      "name" => ClaudeEasy::AI_GROUP_BASE,
      "type" => "select",
      "proxies" => ["Main", "日本家宽 01"],
      "icon" => "https://example.invalid/user-icon.png"
    }
    config["proxy-groups"] << user_group
    config["rules"].unshift(
      "DOMAIN-SUFFIX,anthropic.com,#{ClaudeEasy::AI_GROUP_BASE}",
      "DOMAIN-SUFFIX,openai.com,#{ClaudeEasy::AI_GROUP_BASE}"
    )

    first = ClaudeEasy.patch(config, @policy)
    second = ClaudeEasy.patch(first.fetch(:config), @policy)

    assert_equal user_group, first.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == user_group["name"] }
    assert_equal user_group, second.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == user_group["name"] }
    assert_equal ClaudeEasy::AI_GROUP_BASE, first.fetch(:ai_group)
    assert_equal ClaudeEasy::AI_GROUP_BASE, second.fetch(:ai_group)
    refute second.fetch(:changed)
  end

  def test_inline_proxy_names_reserve_managed_group_names
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    config["proxies"].unshift(
      { "name" => "🤖 AI · ClaudeEasy", "type" => "ss", "server" => "ai.example", "port" => 443 },
      { "name" => "🛡 安全代理 · ClaudeEasy", "type" => "ss", "server" => "safe.example", "port" => 443 }
    )

    result = ClaudeEasy.patch(config, @policy)

    assert_equal "🤖 AI · ClaudeEasy 2", result.fetch(:ai_group)
    assert_equal "Main", result.fetch(:route_group)
    refute result.fetch(:config).fetch("proxy-groups").any? { |group| ClaudeEasy.managed_name?(group["name"], ClaudeEasy::SAFE_GROUP_BASE) }
  end

  def test_migrates_legacy_owned_ai_rules_and_dns_pattern
    old = base_config
    old["proxy-groups"].reject! { |group| group["name"] == "AI" }
    ai_group = ClaudeEasy::AI_GROUP_BASE
    safe_group = ClaudeEasy::SAFE_GROUP_BASE
    old["proxy-groups"] << {
      "name" => ai_group, "type" => "select",
      "proxies" => ["台湾家宽 01", "日本家宽 01", "美国家宽 01"]
    }
    old["proxy-groups"] << {
      "name" => safe_group, "type" => "select", "proxies" => ["台湾家宽 01"], "include-all" => true,
      "exclude-type" => ClaudeEasy::EXCLUDED_SAFE_TYPES, "empty-fallback" => "REJECT"
    }
    old["rules"] = ["NETWORK,UDP,#{safe_group}", "NETWORK,UDP,REJECT"] +
      ClaudeEasy.render_ai_rules(@policy, ai_group).map { |rule| rule.sub("160.79.104.0/23", "160.79.104.0/21") } +
      ["DOMAIN-SUFFIX,ai.com,#{ai_group}"] + old.fetch("rules")
    old["dns"]["nameserver"] = ["https://dns.alidns.com/dns-query##{safe_group}"]
    old["dns"]["nameserver-policy"] = { "+.ai.com" => old.dig("dns", "nameserver").dup }

    result = ClaudeEasy.patch(old, @policy)
    rules = result.fetch(:config).fetch("rules")
    dns_policy = result.fetch(:config).dig("dns", "nameserver-policy")

    refute_includes rules, "DOMAIN-SUFFIX,ai.com,#{ai_group}"
    refute_includes rules, "IP-CIDR,160.79.104.0/21,#{ai_group},no-resolve"
    assert_includes rules, "IP-CIDR,160.79.104.0/23,#{ai_group},no-resolve"
    refute dns_policy.key?("+.ai.com")
    assert result.fetch(:ai_group_reset)
    assert_includes ClaudeEasy.chinese_status(result.merge(path: "/profiles/friend.yaml", active: false)), "升级 AI 分组"
  end

  def test_preserves_user_legacy_ai_rules_and_dns_pattern
    config = base_config
    config["proxy-groups"] << { "name" => "Friend", "type" => "select", "proxies" => ["台湾家宽 01"] }
    config["rules"].unshift(
      "DOMAIN-SUFFIX,ai.com,Friend",
      "IP-CIDR,160.79.104.0/21,Friend,no-resolve"
    )
    config["dns"]["nameserver-policy"]["+.ai.com"] = ["https://1.1.1.1/dns-query#Friend"]

    result = ClaudeEasy.patch(config, @policy)

    assert_includes result.fetch(:config).fetch("rules"), "DOMAIN-SUFFIX,ai.com,Friend"
    assert_includes result.fetch(:config).fetch("rules"), "IP-CIDR,160.79.104.0/21,Friend,no-resolve"
    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}#Friend" }, result.fetch(:config).dig("dns", "nameserver-policy", "+.ai.com")
  end

  def test_patches_config_without_rules_array
    config = base_config
    config.delete("rules")

    result = ClaudeEasy.patch(config, @policy)

    assert_equal :updated, result.fetch(:status)
    assert_instance_of Array, result.fetch(:config).fetch("rules")
    assert result.fetch(:config).fetch("rules").any? { |rule| rule.start_with?("DOMAIN-SUFFIX,openai.com,") }
  end

  def test_existing_ai_group_is_reused_even_when_many_similar_names_exist
    config = base_config
    base = ClaudeEasy::AI_GROUP_BASE
    config["proxy-groups"] << { "name" => base, "type" => "select", "proxies" => ["Main"] }
    (2..9).each do |suffix|
      config["proxy-groups"] << { "name" => "#{base} #{suffix}", "type" => "select", "proxies" => ["Main"] }
    end

    first = ClaudeEasy.patch(config, @policy)
    second = ClaudeEasy.patch(first.fetch(:config), @policy)

    assert_equal "AI", first.fetch(:ai_group)
    refute first.fetch(:config).fetch("proxy-groups").any? { |group| group["name"] == "#{base} 10" }
    refute second.fetch(:changed)
    assert_equal first.fetch(:config), second.fetch(:config)
  end

  def test_rule_template_inserts_group_name_literally
    rendered = ClaudeEasy.render_ai_rules(@policy, 'AI \\1')
    assert_includes rendered, 'DOMAIN-SUFFIX,openai.com,AI \\1'
  end

  def test_symlinked_profile_is_preserved
    Dir.mktmpdir do |directory|
      target = File.join(directory, "actual.yaml")
      link = File.join(directory, "friend.yaml")
      File.write(target, YAML.dump(base_config))
      File.symlink(target, link)

      result = ClaudeEasy.patch_path(link, @policy)

      assert result.fetch(:changed)
      assert File.symlink?(link)
      assert_equal :updated, result.fetch(:status)
      assert_equal false, ClaudeEasy.load_yaml(File.read(target)).fetch("ipv6")
    end
  end

  def test_io_errors_are_not_reported_as_invalid_content
    Dir.mktmpdir do |directory|
      result = ClaudeEasy.patch_path(directory, @policy)
      assert_equal :io_error, result.fetch(:status)
      assert_includes ClaudeEasy.chinese_status(result), "读取或写入失败"
    end
  end

  def test_validator_failure_preserves_original_file
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      File.write(path, original)

      result = ClaudeEasy.patch_path(path, @policy, validator: ->(_candidate) { false })

      assert_equal :validation_failed, result.fetch(:status)
      assert_equal original, File.read(path)
    end
  end

  def test_unchanged_profiles_are_still_validated_before_batch_acceptance
    Dir.mktmpdir do |directory|
      active = File.join(directory, "active.yaml")
      inactive = File.join(directory, "inactive.yaml")
      patched = ClaudeEasy.patch(base_config, @policy, usage_profile: 1).fetch(:config)
      File.binwrite(active, YAML.dump(patched))
      File.binwrite(inactive, YAML.dump(patched.merge("mixed-port" => "not-a-port")))
      timeout = ClaudeEasy.patch_path(
        active, @policy, usage_profile: 1, validator: ->(_candidate) { :timeout }
      )
      assert_equal :validation_timeout, timeout.fetch(:status)
      validator_calls = []
      validator = lambda do |candidate|
        config = ClaudeEasy.load_yaml(File.read(candidate, encoding: "UTF-8"), candidate)
        validator_calls << config["mixed-port"]
        config["mixed-port"] != "not-a-port"
      end

      results = ClaudeEasy.run(
        directory: directory, policy_path: POLICY_PATH,
        backup_root: File.join(directory, "backups"), selected_name: "active",
        validator: validator, auto_reload: false, usage_profile: 1
      )

      assert_equal 2, validator_calls.length
      assert results.any? { |result| result.fetch(:status) == :validation_failed }
      refute results.all? { |result| result.fetch(:status) == :unchanged }
    end
  end

  def test_active_profile_matching_accepts_extension_and_case
    assert ClaudeEasy.active_profile?("/profiles/Config.YAML", "config.yaml")
    assert ClaudeEasy.active_profile?("/profiles/config.yaml", "CONFIG")
    assert ClaudeEasy.active_profile?("/profiles/config.yaml", "")
    refute ClaudeEasy.active_profile?("/profiles/other.yaml", "config")
  end

  def test_defaults_read_decodes_unicode_profile_names_from_plist
    status = Struct.new(:success?).new(true)
    plist = "<?xml version=\"1.0\"?><plist><dict><key>selectConfigName</key><string>Yue.to | 悦通</string></dict></plist>"
    responses = [[plist, "", status], ["Yue.to | 悦通\n", "", status]]
    runner = lambda do |*_args, **_kwargs|
      responses.shift || ["", "", Struct.new(:success?).new(false)]
    end

    Open3.stub(:capture3, runner) do
      assert_equal "Yue.to | 悦通", ClaudeEasy.defaults_read(
        "selectConfigName", preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
      )
    end
  end

  def test_selected_profile_snapshot_distinguishes_default_config_from_read_failure
    success = Struct.new(:success?).new(true)
    failure = Struct.new(:success?).new(false)
    plist = "<?xml version=\"1.0\"?><plist><dict/></plist>"
    cases = [
      [
        [
          [plist, "", success],
          [
            "<plist><dict><key>selectConfigName</key><string>friend</string></dict></plist>",
            "", success
          ]
        ],
        "friend"
      ],
      [
        [[plist, "", success], ["<plist><dict/></plist>", "", success]],
        ""
      ],
      [
        [
          [plist, "", success],
          [
            "<plist><dict><key>selectConfigName</key><integer>3</integer></dict></plist>",
            "", success
          ]
        ],
        nil
      ],
      [
        [[plist, "", success], ["", "invalid plist", failure]],
        nil
      ]
    ]

    cases.each do |responses, expected|
      runner = lambda do |*_args, **_kwargs|
        responses.shift || ["", "", failure]
      end
      if expected.nil?
        assert_nil ClaudeEasy.selected_profile_name(
          runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
        )
      else
        assert_equal expected, ClaudeEasy.selected_profile_name(
          runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
        )
      end
    end
    assert_nil ClaudeEasy.selected_profile_name(
      runner: ->(*_args, **_kwargs) { raise IOError },
      preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
    )
    responses = [[plist, "", success]]
    assert_nil ClaudeEasy.selected_profile_name(
      runner: lambda { |*_args, **_kwargs|
        responses.shift || raise(IOError, "plutil unavailable")
      }, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
    )
  end

  def test_selected_profile_snapshot_ignores_unrelated_non_json_plist_values
    success = Struct.new(:success?).new(true)
    plist = <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0">
        <dict>
          <key>lastCheckedAt</key>
          <date>2026-07-25T13:00:00Z</date>
          <key>opaqueState</key>
          <data>AQID</data>
          <key>selectConfigName</key>
          <string>friend</string>
        </dict>
      </plist>
    PLIST
    real_runner = Open3.method(:capture3)
    runner = lambda do |*arguments, **options|
      if arguments[0] == "/usr/bin/defaults" && arguments[1] == "export"
        [plist, "", success]
      else
        real_runner.call(*arguments, **options)
      end
    end

    assert_equal "friend", ClaudeEasy.selected_profile_name(
      runner: runner, preference_domain: ClaudeEasy::AUTO_UPDATE_DOMAINS.first
    )
  end

  def test_single_custom_profile_directory_is_active
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))

      results = ClaudeEasy.run(directories: [directory], policy_path: POLICY_PATH, selected_name: "friend")

      assert_equal true, results.fetch(0).fetch(:active)
      refute results.fetch(0).key?(:reloaded)
    end
  end

  def test_run_silently_skips_default_config_when_another_profile_is_selected
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "config.yaml"), "mode: rule\nrules: []\n")
      selected = File.join(directory, "friend.yaml")
      File.write(selected, YAML.dump(base_config))

      results = ClaudeEasy.run(directories: [directory], policy_path: POLICY_PATH, selected_name: "friend", dry_run: true)

      assert_equal [selected], results.map { |result| result.fetch(:path) }
    end
  end

  def test_run_applies_the_common_baseline_to_every_subscription_in_current_storage
    Dir.mktmpdir do |directory|
      names = ["MESL", "Yue.to | 悦通", "网际快车"]
      names.each { |name| File.write(File.join(directory, "#{name}.yaml"), YAML.dump(base_config)) }
      File.write(File.join(directory, "config.yaml"), YAML.dump(base_config))

      results = ClaudeEasy.run(
        directories: [directory], policy_path: POLICY_PATH,
        selected_name: "MESL", usage_profile: 1
      )

      assert_equal names.sort, results.map { |result| File.basename(result.fetch(:path), ".yaml") }.sort
      provider_name = @policy.fetch("cn_domain_provider").fetch("name")
      names.each do |name|
        config = ClaudeEasy.load_yaml(File.read(File.join(directory, "#{name}.yaml")))
        assert config.fetch("rule-providers").key?(provider_name), name
        assert_includes config.fetch("rules"), "RULE-SET,#{provider_name},DIRECT", name
        refute config.key?("tun"), name
      end
    end
  end

  def test_run_keeps_default_config_when_it_is_selected
    Dir.mktmpdir do |directory|
      config = File.join(directory, "config.yaml")
      File.write(config, YAML.dump(base_config))
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))

      results = ClaudeEasy.run(directories: [directory], policy_path: POLICY_PATH, selected_name: "config", dry_run: true)

      assert_includes results.map { |result| result.fetch(:path) }, config
    end
  end

  def test_selected_profile_chooses_the_matching_icloud_container
    Dir.mktmpdir do |home|
      current = File.join(home, "Library", "Mobile Documents", "iCloud~com~metacubex~ClashX", "Documents")
      legacy = File.join(home, "Library", "Mobile Documents", "iCloud~com~west2online~ClashX", "Documents")
      FileUtils.mkdir_p(current)
      FileUtils.mkdir_p(legacy)
      File.write(File.join(current, "other.yaml"), YAML.dump(base_config))
      selected = File.join(legacy, "friend.yaml")
      File.write(selected, YAML.dump(base_config))

      results = ClaudeEasy.stub(:icloud_enabled?, true) do
        ClaudeEasy.run(directories: [current, legacy], policy_path: POLICY_PATH, selected_name: "friend")
      end
      active = results.find { |result| result[:active] }

      assert_equal selected, active.fetch(:path)
      refute active.key?(:reloaded)
    end
  end

  def test_controller_socket_ignores_disappearing_cache_files
    Dir.mktmpdir do |home|
      old_home = ENV["HOME"]
      ENV["HOME"] = home
      cache = File.join(home, "Library", "Caches", "com.MetaCubeX.ClashX.meta", "cacheConfigs")
      FileUtils.mkdir_p(cache)
      File.symlink(File.join(cache, "missing-target"), File.join(cache, "vanished.yaml"))

      assert_nil ClaudeEasy.controller_socket
    ensure
      ENV["HOME"] = old_home
    end
  end

  def test_tun_state_uses_authoritative_runtime_config
    assert_respond_to ClaudeEasy, :tun_state
    enabled = ->(*_args) { [200, JSON.generate("tun" => { "enable" => true })] }
    disabled = ->(*_args) { [200, JSON.generate("tun" => { "enable" => false })] }
    unavailable = ->(*_args) { [503, ""] }
    malformed = ->(*_args) { [200, "not json"] }
    wrong_shape = ->(*_args) { [200, "[]"] }

    assert_equal :enabled, ClaudeEasy.tun_state(socket: "/tmp/fake.sock", requester: enabled)
    assert_equal :disabled, ClaudeEasy.tun_state(socket: "/tmp/fake.sock", requester: disabled)
    assert_equal :unknown, ClaudeEasy.tun_state(socket: "/tmp/fake.sock", requester: unavailable)
    assert_equal :unknown, ClaudeEasy.tun_state(socket: "/tmp/fake.sock", requester: malformed)
    assert_equal :unknown, ClaudeEasy.tun_state(socket: "/tmp/fake.sock", requester: wrong_shape)
  end

  def test_tun_state_does_not_require_a_local_socket_when_a_requester_is_supplied
    enabled = ->(*_args) { [200, JSON.generate("tun" => { "enable" => true })] }

    ClaudeEasy.stub(:controller_socket, nil) do
      assert_equal :enabled, ClaudeEasy.tun_state(requester: enabled)
    end
    [1, 2, 3].each do |usage_profile|
      assert_equal :preserve, ClaudeEasy.runtime_tun_requirement(usage_profile)
    end
  end

  def test_profile_discovery_uses_only_the_active_storage_root
    Dir.mktmpdir do |home|
      local = File.join(home, ".config", "clash.meta")
      current = File.join(home, "Library", "Mobile Documents", "iCloud~com~metacubex~ClashX", "Documents")
      legacy = File.join(home, "Library", "Mobile Documents", "iCloud~com~west2online~ClashX", "Documents")
      [local, current, legacy].each { |path| FileUtils.mkdir_p(path) }

      File.write(File.join(current, "active.yaml"), YAML.dump(base_config))
      File.write(File.join(legacy, "abandoned.yaml"), YAML.dump(base_config))

      local_directories = ClaudeEasy.default_profile_directories(
        home: home, app_paths: [], cloud_enabled: false, selected: "active"
      )
      cloud_directories = ClaudeEasy.default_profile_directories(
        home: home, app_paths: [], cloud_enabled: true, selected: "active"
      )

      assert_equal [local], local_directories
      assert_equal [current], cloud_directories
      refute_includes cloud_directories, legacy
    end
  end

  def test_profile_discovery_refuses_ambiguous_icloud_roots
    Dir.mktmpdir do |home|
      current = File.join(home, "Library", "Mobile Documents", "iCloud~com~metacubex~ClashX", "Documents")
      legacy = File.join(home, "Library", "Mobile Documents", "iCloud~com~west2online~ClashX", "Documents")
      [current, legacy].each { |path| FileUtils.mkdir_p(path) }
      File.write(File.join(current, "one.yaml"), YAML.dump(base_config))
      File.write(File.join(legacy, "two.yaml"), YAML.dump(base_config))

      directories = ClaudeEasy.default_profile_directories(
        home: home, app_paths: [], cloud_enabled: true, selected: "missing"
      )

      assert_empty directories
    end
  end

  def test_profile_discovery_refuses_single_icloud_root_without_the_selected_profile
    Dir.mktmpdir do |home|
      current = File.join(home, "Library", "Mobile Documents", "iCloud~com~metacubex~ClashX", "Documents")
      FileUtils.mkdir_p(current)
      File.write(File.join(current, "other.yaml"), YAML.dump(base_config))

      directories = ClaudeEasy.default_profile_directories(
        home: home, app_paths: [], cloud_enabled: true, selected: "missing"
      )

      assert_empty directories
    end
  end

  def test_profile_discovery_ignores_an_undeclared_legacy_icloud_root
    Dir.mktmpdir do |home|
      current = File.join(home, "Library", "Mobile Documents", "iCloud~com~metacubex~ClashX", "Documents")
      legacy = File.join(home, "Library", "Mobile Documents", "iCloud~com~west2online~ClashX", "Documents")
      [current, legacy].each do |path|
        FileUtils.mkdir_p(path)
        File.write(File.join(path, "friend.yaml"), YAML.dump(base_config))
      end

      directories = ClaudeEasy.default_profile_directories(
        home: home, app_paths: [], cloud_enabled: true, selected: "friend"
      )

      assert_equal [current], directories
    end
  end

  def test_profile_discovery_refuses_unknown_storage_mode
    Dir.mktmpdir do |home|
      local = File.join(home, ".config", "clash.meta")
      FileUtils.mkdir_p(local)
      File.write(File.join(local, "old.yaml"), YAML.dump(base_config))

      directories = ClaudeEasy.stub(:defaults_read, "") do
        ClaudeEasy.default_profile_directories(home: home, app_paths: [])
      end

      assert_empty directories
    end
  end

  def test_library_run_does_not_reload_unless_explicitly_enabled
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))

      results = ClaudeEasy.run(
        directory: directory,
        policy_path: POLICY_PATH,
        backup_root: File.join(directory, "backups"),
        selected_name: "friend"
      )
      active = results.find { |entry| entry.fetch(:path) == profile }

      assert_equal :updated, active.fetch(:status)
      refute active.key?(:reloaded)
      assert_includes ClaudeEasy.chinese_status(active), "已更新，尚未自动刷新"
    end
  end

  def test_mihomo_validation_uses_the_profile_directory
    Dir.mktmpdir do |home|
      Dir.mktmpdir do |icloud|
        old_home = ENV["HOME"]
        ENV["HOME"] = home
        FileUtils.mkdir_p(File.join(home, ".config", "clash.meta"))
        profile = File.join(icloud, "friend.yaml")
        File.write(profile, "rules: []\n")

        assert_equal icloud, ClaudeEasy.mihomo_validation_directory(profile)
      ensure
        ENV["HOME"] = old_home
      end
    end
  end

  def test_mihomo_version_gate_and_missing_core_fail_closed
    assert ClaudeEasy.mihomo_version_supported?("Mihomo Meta v1.19.27 linux amd64")
    assert ClaudeEasy.mihomo_version_supported?("mihomo v1.20.0")
    refute ClaudeEasy.mihomo_version_supported?("Mihomo Meta v1.19.26")
    refute ClaudeEasy.mihomo_version_supported?("unknown")
    refute ClaudeEasy.validate_with_mihomo("/tmp/missing.yaml", core_path: nil)
  end

  def test_mihomo_default_core_is_resolved_before_status_and_validation
    discovered_core = "/tmp/discovered-mihomo"
    status_calls = []
    validation_calls = []
    success = Struct.new(:success?).new(true)

    ClaudeEasy.stub(:mihomo_core_path, discovered_core) do
      File.stub(:file?, ->(path) { path == discovered_core }) do
        File.stub(:executable?, ->(path) { path == discovered_core }) do
          ClaudeEasy.stub(:run_process_with_timeout, lambda { |core, *arguments, **_keywords|
            status_calls << [core, arguments]
            ["Mihomo Meta v1.19.27", success, false]
          }) do
            assert_equal :supported, ClaudeEasy.mihomo_core_status
          end
        end
      end

      ClaudeEasy.stub(:mihomo_core_status, lambda { |core, **_keywords|
        validation_calls << [:status, core]
        :supported
      }) do
        ClaudeEasy.stub(:run_process_with_timeout, lambda { |core, *arguments, **_keywords|
          validation_calls << [:validate, core, arguments]
          ["", success, false]
        }) do
          assert ClaudeEasy.validate_with_mihomo("/tmp/profile/config.yaml")
        end
      end
    end

    assert_equal [[discovered_core, ["-v"]]], status_calls
    assert_equal [
      [:status, discovered_core],
      [:validate, discovered_core, ["-d", "/tmp/profile", "-t", "-f", "/tmp/profile/config.yaml"]]
    ], validation_calls
  end

  def test_mihomo_validation_times_out_and_terminates_the_child
    Dir.mktmpdir do |directory|
      core = File.join(directory, "mihomo-test")
      profile = File.join(directory, "friend.yaml")
      File.write(core, <<~SH)
        #!/bin/sh
        if [ "$1" = "-v" ]; then
          echo 'Mihomo Meta v1.19.27 test'
          exit 0
        fi
        sleep 5
      SH
      File.chmod(0o700, core)
      File.write(profile, "rules: []\n")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = ClaudeEasy.validate_with_mihomo(profile, core_path: core, timeout_seconds: 0.1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal :timeout, result
      assert_operator elapsed, :<, 2
    end
  end

  def test_cli_default_policy_path_works_from_the_repository
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))

      output, error, status = Open3.capture3(
        RbConfig.ruby, PATCHER_PATH, "--profile-dir", directory,
        "--usage-profile", "1", "--dry-run"
      )

      assert status.success?, "stdout=#{output.inspect} stderr=#{error.inspect}"
      assert_includes output, "演练"
    end
  end

  def test_cli_reports_useful_policy_errors_without_dumping_policy_content
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      policy = File.join(directory, "policy.json")
      File.write(profile, YAML.dump(base_config))
      File.write(policy, %({"token":"do-not-print",))

      _output, error, status = Open3.capture3(
        RbConfig.ruby, PATCHER_PATH, "--profile-dir", directory, "--policy", policy,
        "--usage-profile", "1", "--dry-run"
      )

      refute status.success?
      assert_includes error, "策略文件不是有效的 JSON"
      refute_includes error, "do-not-print"
      refute_equal "ClaudeEasy 运行失败：JSON::ParserError\n", error
    end
  end

  def test_generated_profile_passes_installed_mihomo_validation
    core = ENV["CLAUDE_EASY_TEST_MIHOMO"]
    if core.to_s.empty?
      flunk "CI required a real Mihomo core but CLAUDE_EASY_TEST_MIHOMO was empty" if ENV["CLAUDE_EASY_REQUIRE_REAL_MIHOMO"] == "1"
      skip "set CLAUDE_EASY_RUN_INSTALLED_CORE_TEST=1 to test the locally installed Mihomo core" unless ENV["CLAUDE_EASY_RUN_INSTALLED_CORE_TEST"] == "1"
      core = ClaudeEasy.mihomo_core_path
      skip "ClashX Meta Mihomo core is not installed" unless core
    end
    assert_equal :supported, ClaudeEasy.mihomo_core_status(core)

    text = <<~YAML
      mixed-port: 7890
      proxies:
        - name: node
          type: socks5
          server: 127.0.0.1
          port: 1080
          username: yes
          password: on
          udp: true
      proxy-groups:
        - name: Main
          type: select
          proxies: [node]
      rules:
        - MATCH,Main
    YAML
    validations = []
    profiles_completed = []
    Dir.mktmpdir do |directory|
      [1, 2, 3].each do |usage_profile|
        profile = File.join(directory, "profile-#{usage_profile}.yaml")
        File.write(profile, text)
        assert_equal true, ClaudeEasy.validate_with_mihomo(profile, core_path: core),
                     "profile #{usage_profile} baseline fixture must be valid"
        validations << { "profile" => usage_profile, "stage" => "baseline" }
        validator = ->(path) { ClaudeEasy.validate_with_mihomo(path, core_path: core) }
        result = ClaudeEasy.patch_path(
          profile, @policy, validator: validator, usage_profile: usage_profile
        )
        assert_equal :updated, result.fetch(:status), "profile #{usage_profile}"
        assert_equal true, ClaudeEasy.validate_with_mihomo(profile, core_path: core),
                     "profile #{usage_profile} patch must stay valid"
        validations << { "profile" => usage_profile, "stage" => "patched" }
        profiles_completed << usage_profile
      end
    end
    receipt_path = ENV["CLAUDE_EASY_MIHOMO_RECEIPT_PATH"].to_s
    unless receipt_path.empty?
      receipt = {
        "schema" => "claude-easy.mihomo-validation",
        "version" => 1,
        "nonce" => ENV.fetch("CLAUDE_EASY_MIHOMO_RECEIPT_NONCE"),
        "core_sha256" => Digest::SHA256.file(core).hexdigest,
        "profiles_completed" => profiles_completed,
        "validations" => validations
      }
      File.write(receipt_path, JSON.generate(receipt))
    end
  end

  def test_rule_parser_keeps_nested_commas_and_identifies_no_resolve_target
    rule = "AND,((NETWORK,UDP),(DST-PORT,443)),Reject,no-resolve"

    assert_equal ["AND", "((NETWORK,UDP),(DST-PORT,443))", "Reject", "no-resolve"], ClaudeEasy.split_rule_fields(rule)
    info = ClaudeEasy.rule_info(rule)
    assert_equal "AND", info.fetch(:type)
    assert_equal "((NETWORK,UDP),(DST-PORT,443))", info.fetch(:payload)
    assert_equal "Reject", info.fetch(:target)
  end

  def test_group_safety_rejects_every_subscription_controlled_member_filter
    config = base_config
    config["proxy-groups"] << { "name" => "Filtered", "type" => "select", "proxies" => ["台湾家宽 01"], "exclude-filter" => "[" }
    refute ClaudeEasy.group_cannot_reach_direct?(config, "Filtered")

    config["proxy-groups"].last["exclude-filter"] = "(?=台湾)"
    refute ClaudeEasy.group_cannot_reach_direct?(config, "Filtered")
  end

  def test_group_safety_never_executes_subscription_controlled_catastrophic_filters
    config = base_config
    near_miss = "#{"a" * 18}!"
    config["proxies"] << { "name" => near_miss, "type" => "ss", "server" => "safe.example", "password" => "fixture-secret" }

    ["(a+)+$", "(a|aa)+$"].each do |filter|
      config["proxy-groups"] << {
        "name" => "Catastrophic", "type" => "select", "proxies" => [near_miss], "exclude-filter" => filter
      }
      refute ClaudeEasy.group_cannot_reach_direct?(config, "Catastrophic"), filter
      config["proxy-groups"].pop
    end
  end

  def test_group_safety_accepts_an_explicit_safe_empty_fallback
    config = base_config
    config["proxy-groups"] << { "name" => "Fallback", "type" => "select", "proxies" => [], "empty-fallback" => "台湾家宽 01" }

    assert ClaudeEasy.group_cannot_reach_direct?(config, "Fallback")
  end

  def test_managed_select_group_lookup_recognizes_an_owned_ai_selector
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    name = ClaudeEasy::AI_GROUP_BASE
    config["proxy-groups"] << {
      "name" => name, "type" => "select",
      "proxies" => ["台湾家宽 01", "日本家宽 01", "美国家宽 01"]
    }
    config["rules"] = ClaudeEasy.render_ai_rules(@policy, name) + config.fetch("rules")

    group = ClaudeEasy.find_managed_select_group(config, ClaudeEasy::AI_GROUP_BASE, :ai, @policy)

    assert_equal name, group.fetch("name")
  end

  def test_legacy_ai_dns_patterns_include_exact_domain_rules
    policy = Marshal.load(Marshal.dump(@policy))
    policy["legacy_ai_rules"] << "DOMAIN,legacy-ai.example,AI"

    assert_includes ClaudeEasy.legacy_ai_dns_patterns(policy), "legacy-ai.example"
  end

  def test_yaml_scalar_scanner_falls_back_to_text_when_numeric_conversion_rejects_input
    loader = Psych::ClassLoader::Restricted.new([], [])
    scanner = ClaudeEasy::YAML12ScalarScanner.new(loader)

    scanner.stub(:Integer, ->(_value) { raise ArgumentError, "conversion failed" }) do
      assert_equal "123", scanner.tokenize("123")
    end
  end

  def test_patch_rules_removes_the_owned_legacy_quic_guard
    config = base_config
    user_rule = "AND,((NETWORK,UDP),(DST-PORT,3478)),REJECT"
    config["rules"].unshift(user_rule, ClaudeEasy::LEGACY_QUIC_REJECT_RULE)

    patched = ClaudeEasy.patch(config, @policy).fetch(:config)

    assert_includes patched.fetch("rules"), user_rule
    refute_includes patched.fetch("rules"), ClaudeEasy::LEGACY_QUIC_REJECT_RULE
  end

  def test_mihomo_status_classifies_command_failures_without_running_a_real_core
    status = Object.new
    status.define_singleton_method(:success?) { false }

    ClaudeEasy.stub(:run_process_with_timeout, ["bad executable", status, false]) do
      assert_equal :unreadable, ClaudeEasy.mihomo_core_status(RbConfig.ruby)
    end
    ClaudeEasy.stub(:run_process_with_timeout, ["", nil, true]) do
      assert_equal :timeout, ClaudeEasy.mihomo_core_status(RbConfig.ruby)
    end
  end

  def test_controller_request_returns_safe_empty_response_when_curl_fails
    failure = Object.new
    failure.define_singleton_method(:success?) { false }

    Open3.stub(:capture2e, ["curl failed", failure]) do
      assert_equal [0, ""], ClaudeEasy.controller_request("/tmp/missing.sock", "GET", "/configs")
    end
  end

  def test_controller_request_parses_a_successful_controller_response
    success = Object.new
    success.define_singleton_method(:success?) { true }

    Open3.stub(:capture2e, ["{\"tun\":true}\n200", success]) do
      assert_equal [200, "{\"tun\":true}"], ClaudeEasy.controller_request("/tmp/controller.sock", "GET", "/configs")
    end
  end

  def test_controller_request_sends_json_body_with_the_reload_request
    success = Object.new
    success.define_singleton_method(:success?) { true }
    arguments = nil
    stdin = nil

    Open3.stub(:capture2e, ->(*items) {
      options = items.pop
      arguments = items
      stdin = options.fetch(:stdin_data)
      ["\n204", success]
    }) do
      assert_equal(
        [204, ""],
        ClaudeEasy.stub(:controller_secret, "controller-secret") do
          ClaudeEasy.controller_request(
            "/tmp/controller.sock", "PUT", "/configs?force=true", '{"path":"profile.yaml"}'
          )
        end
      )
    end
    refute_includes arguments.join(" "), "/tmp/controller.sock"
    refute_includes arguments.join(" "), "profile.yaml"
    refute_includes arguments.join(" "), "controller-secret"
    assert_includes stdin, 'unix-socket = "/tmp/controller.sock"'
    assert_includes stdin, 'data = "{\"path\":\"profile.yaml\"}"'
    assert_includes stdin, 'header = "Authorization: Bearer controller-secret"'
  end

  def test_mihomo_validation_uses_the_profile_directory_and_fails_closed
    success = Object.new
    success.define_singleton_method(:success?) { true }
    calls = []
    ClaudeEasy.stub(:mihomo_core_status, :supported) do
      ClaudeEasy.stub(:run_process_with_timeout, ->(*args, **kwargs) { calls << [args, kwargs]; ["ok", success, false] }) do
        assert ClaudeEasy.validate_with_mihomo("/tmp/profile/config.yaml", core_path: "/tmp/mihomo")
      end
    end
    assert_equal ["/tmp/mihomo", "-d", "/tmp/profile", "-t", "-f", "/tmp/profile/config.yaml"], calls.fetch(0).fetch(0)

    ClaudeEasy.stub(:mihomo_core_status, :timeout) do
      assert_equal :timeout, ClaudeEasy.validate_with_mihomo("/tmp/profile/config.yaml", core_path: "/tmp/mihomo")
    end
  end

  def test_default_connectivity_retries_transient_errors_and_returns_false
    failed = Object.new
    failed.define_singleton_method(:success?) { false }
    attempts = 0
    Open3.stub(:capture2e, ->(*_args) { attempts += 1; ["", failed] }) do
      refute ClaudeEasy.default_connectivity_healthy?
    end
    assert_equal 3, attempts

    successful = Object.new
    successful.define_singleton_method(:success?) { true }
    Open3.stub(:capture2e, ["", successful]) do
      assert ClaudeEasy.default_connectivity_healthy?
    end
  end

  def test_default_connectivity_waits_between_cold_reload_failures
    failed = Object.new
    failed.define_singleton_method(:success?) { false }
    successful = Object.new
    successful.define_singleton_method(:success?) { true }
    attempts = 0
    delays = []

    Open3.stub(:capture2e, lambda { |*_args|
      attempts += 1
      ["", attempts == 3 ? successful : failed]
    }) do
      ClaudeEasy.stub(:sleep, ->(seconds) { delays << seconds }) do
        assert ClaudeEasy.default_connectivity_healthy?
      end
    end

    assert_equal [1, 1], delays
  end

  def test_default_connectivity_uses_the_current_mihomo_listener_without_ambient_proxies
    success = Object.new
    success.define_singleton_method(:success?) { true }
    requester = lambda do |method, endpoint, _body|
      assert_equal "GET", method
      assert_equal "/configs", endpoint
      [200, JSON.generate("mixed-port" => 7890)]
    end
    invocation = nil

    Open3.stub(:capture2e, lambda { |*arguments|
      invocation = arguments
      ["", success]
    }) do
      assert ClaudeEasy.default_connectivity_healthy?(
        requester: requester, tun_mode: :ignore
      )
    end

    environment = invocation.fetch(0)
    arguments = invocation.drop(1)
    assert_instance_of Hash, environment
    %w[http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY].each do |name|
      assert environment.key?(name), name
      assert_nil environment.fetch(name), name
    end
    assert_equal ["/usr/bin/curl", "-q"], arguments.first(2)
    proxy_index = arguments.index("--proxy")
    refute_nil proxy_index
    assert_equal "http://127.0.0.1:7890", arguments.fetch(proxy_index + 1)
  end

  def test_tun_connectivity_disables_curl_config_and_every_proxy_source
    success = Object.new
    success.define_singleton_method(:success?) { true }
    invocation = nil

    Open3.stub(:capture2e, lambda { |*arguments|
      invocation = arguments
      ["", success]
    }) do
      assert ClaudeEasy.default_connectivity_healthy?(tun_mode: :enabled)
    end

    environment = invocation.fetch(0)
    arguments = invocation.drop(1)
    %w[http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY].each do |name|
      assert environment.key?(name), name
      assert_nil environment.fetch(name), name
    end
    assert_equal ["/usr/bin/curl", "-q"], arguments.first(2)
    proxy_index = arguments.index("--proxy")
    refute_nil proxy_index
    assert_equal "", arguments.fetch(proxy_index + 1)
    assert_includes arguments, "--noproxy"
    assert_includes arguments, "*"
  end

  def test_non_tun_connectivity_fails_closed_without_a_loopback_proxy_listener
    calls = 0
    requester = lambda do |_method, _endpoint, _body|
      [200, JSON.generate("mixed-port" => 0, "port" => nil, "socks-port" => 70_000)]
    end

    Open3.stub(:capture2e, ->(*_arguments) { calls += 1; raise "curl must not run" }) do
      refute ClaudeEasy.default_connectivity_healthy?(
        requester: requester, tun_mode: :ignore
      )
    end
    assert_equal 0, calls
  end

  def test_runtime_helpers_fail_closed_on_invalid_json
    requester = ->(*_args) { [200, "not json"] }

    assert_equal :unknown, ClaudeEasy.tun_state(requester: requester)
    assert_nil ClaudeEasy.runtime_selections(requester)
    refute ClaudeEasy.dns_runtime_healthy?(requester, "example.invalid")
  end

  def test_runtime_parsers_reject_http_and_proxy_shape_failures
    assert_nil ClaudeEasy.runtime_selections(
      ->(*_args) { [200, JSON.generate("proxies" => [])] }
    )
    assert_equal(
      {},
      ClaudeEasy.runtime_selections(
        ->(*_args) {
          [200, JSON.generate("proxies" => {
            "not-a-map" => [],
            "missing-selection" => { "type" => "Selector" },
            "automatic" => { "type" => "URLTest", "now" => "Taiwan" }
          })]
        }
      )
    )
    refute ClaudeEasy.dns_runtime_healthy?(
      ->(*_args) { [503, JSON.generate("Status" => 0, "Answer" => ["203.0.113.1"])] },
      "example.invalid"
    )
  end

  def test_runtime_health_rejects_every_partial_health_failure
    requester_for = lambda do |failure|
      lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["POST", "/cache/fakeip/flush"]
          flunk "runtime health must preserve Fake-IP mappings"
        when ["POST", "/cache/dns/flush"]
          [failure == :dns_flush ? 503 : 204, ""]
        when ["GET", "/configs"]
          tun = failure == :tun ? nil : true
          [200, JSON.generate("tun" => { "enable" => tun })]
        when ["GET", "/proxies"]
          proxies = if failure == :proxy_shape
                      []
                    else
                      selected = failure == :selection ? "Japan" : "Taiwan"
                      { "Main" => { "type" => "Selector", "now" => selected } }
                    end
          [200, JSON.generate("proxies" => proxies)]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            failed_dns = failure == :baidu_dns && endpoint.include?("www.baidu.com")
            [failed_dns ? 503 : 200, JSON.generate("Status" => 0, "Answer" => ["203.0.113.1"])]
          else
            [404, ""]
          end
        end
      end
    end
    selections = { "Main" => "Taiwan" }
    checker = -> { true }

    assert ClaudeEasy.runtime_health_healthy?(
      requester_for.call(nil), selections: selections, expected_tun: :enabled,
      connectivity_checker: checker
    )
    %i[dns_flush tun proxy_shape selection baidu_dns].each do |failure|
      refute ClaudeEasy.runtime_health_healthy?(
        requester_for.call(failure), selections: selections, expected_tun: :enabled,
        connectivity_checker: checker
      ), "runtime health accepted #{failure}"
    end
    refute ClaudeEasy.runtime_health_healthy?(
      requester_for.call(nil), selections: selections, expected_tun: nil,
      connectivity_checker: checker
    )
    refute ClaudeEasy.runtime_health_healthy?(
      requester_for.call(nil), selections: [], expected_tun: :enabled,
      connectivity_checker: checker
    )
    refute ClaudeEasy.runtime_health_healthy?(
      requester_for.call(nil), selections: selections, expected_tun: :enabled,
      connectivity_checker: -> { false }
    )
  end

  def test_profile_restore_refuses_incomplete_metadata_and_digest_conflicts
    Dir.mktmpdir do |directory|
      path = File.join(directory, "profile.yaml")
      File.binwrite(path, "current")

      refute ClaudeEasy.restore_profile_bytes(path: path, rollback_bytes: nil, patched_digest: "digest")
      refute ClaudeEasy.restore_profile_bytes(
        path: path, rollback_bytes: "original",
        patched_digest: Digest::SHA256.hexdigest("different")
      )
      assert_equal "current", File.binread(path)
    end
  end

  def test_profile_runtime_file_error_boundaries_fail_closed
    Dir.mktmpdir do |directory|
      missing_root = File.join(directory, "missing-root")
      missing_profile = File.join(missing_root, "profile.yaml")
      assert ClaudeEasy.profile_path_allowed?(missing_profile, [missing_root])

      metadata = {
        path: missing_profile,
        rollback_bytes: "original",
        patched_digest: Digest::SHA256.hexdigest("candidate"),
        patched_identity: [1, 2],
        patched_path: missing_profile
      }
      refute ClaudeEasy.profile_result_current?(metadata)

      ClaudeEasy.stub(:profile_result_current?, true) do
        refute ClaudeEasy.restore_profile_bytes(metadata)
      end

      active = [{ active: true, path: missing_profile }]
      refute ClaudeEasy.reload_recovered_profile_runtime(
        active, require_tun: false,
        requester: ->(*_args) { raise IOError, "injected runtime read failure" }
      )
      refute ClaudeEasy.restore_runtime_selections(
        ->(*_args) { raise IOError, "injected selector failure" }, { "Main" => "Taiwan" }
      )

      profile = File.join(directory, "profile.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        else
          raise "unexpected request: #{method} #{endpoint}"
        end
      end
      checkpoint = ClaudeEasy.capture_runtime_checkpoint(
        profile, require_tun: false, requester: requester
      )
      assert_equal :ignore, checkpoint.fetch(:expected_tun)
      checkpoint = ClaudeEasy.capture_runtime_checkpoint(
        profile, require_tun: true, requester: requester
      )
      assert_equal :enabled, checkpoint.fetch(:expected_tun)
      assert_nil ClaudeEasy.capture_runtime_checkpoint(
        missing_profile, require_tun: false, requester: requester
      )
      assert_nil ClaudeEasy.capture_runtime_checkpoint(
        profile, require_tun: false,
        requester: ->(*_args) { raise IOError, "injected checkpoint failure" }
      )
    end
  end

  def test_activation_rolls_back_missing_runtime_state_and_request_exceptions
    result = {
      path: "/missing/profile.yaml",
      rollback_bytes: "original",
      patched_digest: Digest::SHA256.hexdigest("candidate"),
      patched_identity: [1, 2],
      patched_path: "/missing/profile.yaml"
    }
    rollback_calls = 0
    rollback = lambda do |*_args, **_kwargs|
      rollback_calls += 1
      :reload_failed_restore_pending
    end

    ClaudeEasy.stub(:profile_result_current?, true) do
      ClaudeEasy.stub(:runtime_selections, nil) do
        ClaudeEasy.stub(:rollback_before_runtime_reload, rollback) do
          failed = ClaudeEasy.activate_updated_profile(
            result, requester: ->(*_args) { [200, "{}"] }
          )
          assert_equal :reload_failed_restore_pending, failed.fetch(:status)
        end
      end

      ClaudeEasy.stub(:runtime_selections, ->(_requester) { raise IOError, "injected request failure" }) do
        ClaudeEasy.stub(:rollback_before_runtime_reload, rollback) do
          failed = ClaudeEasy.activate_updated_profile(
            result, requester: ->(*_args) { [200, "{}"] }
          )
          assert_equal :reload_failed_restore_pending, failed.fetch(:status)
        end
      end

      Dir.mktmpdir do |directory|
        profile = File.join(directory, "active.yaml")
        other = File.join(directory, "other.yaml")
        File.binwrite(profile, "candidate")
        File.binwrite(other, "other")
        stat = File.stat(profile)
        mismatch_result = {
          path: profile, rollback_bytes: "original",
          patched_digest: Digest::SHA256.hexdigest("candidate"),
          patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
        }
        checkpoint = {
          path: File.realpath(other), expected_tun: :ignore, selections: {}
        }
        ClaudeEasy.stub(:rollback_before_runtime_reload, rollback) do
          failed = ClaudeEasy.activate_updated_profile(
            mismatch_result, requester: ->(*_args) { [204, ""] },
            runtime_checkpoint: checkpoint
          )
          assert_equal :reload_failed_restore_pending, failed.fetch(:status)
        end
      end

      Dir.mktmpdir do |directory|
        profile = File.join(directory, "active.yaml")
        File.binwrite(profile, "candidate")
        stat = File.stat(profile)
        loaded_result = {
          path: profile, rollback_bytes: "original",
          patched_digest: Digest::SHA256.hexdigest("candidate"),
          patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
        }
        loaded_checkpoint = {
          path: File.realpath(profile), expected_tun: :ignore, selections: {}
        }
        requester = ->(*_args) { raise IOError, "injected load failure" }
        ClaudeEasy.stub(:runtime_checkpoint_current?, true) do
          ClaudeEasy.stub(:rollback_after_reload_failure, rollback) do
            failed = ClaudeEasy.activate_updated_profile(
              loaded_result, requester: requester, runtime_checkpoint: loaded_checkpoint
            )
            assert_equal :reload_failed_restore_pending, failed.fetch(:status)
          end
        end
      end
    end
    ClaudeEasy.stub(:restore_profile_bytes, ->(_result) { raise IOError, "injected restore failure" }) do
      assert_equal :reload_failed_rollback_conflict,
                   ClaudeEasy.rollback_before_runtime_reload(result)
    end
    assert_equal 4, rollback_calls
  end

  def test_process_timeout_helpers_cover_normal_exit_and_kill_fallbacks
    output, status, timed_out = ClaudeEasy.run_process_with_timeout(
      RbConfig.ruby, "-e", "STDOUT.write('fixture-output')", timeout_seconds: 2
    )
    assert_equal "fixture-output", output
    assert status.success?
    refute timed_out

    signals = []
    killer = lambda do |signal, pid|
      signals << [signal, pid]
      raise Errno::ESRCH
    end
    Process.stub(:kill, killer) do
      Process.stub(:waitpid, ->(_pid) { raise Errno::ECHILD }) do
        assert_nil ClaudeEasy.terminate_process_group(12_345)
      end
    end
    assert_equal [["TERM", -12_345], ["KILL", 12_345]], signals
  end

  def test_process_owner_watchdog_covers_completion_and_owner_death
    output_class = Struct.new(:closed, :removed) do
      def close
        self.closed = true
      end

      def close!
        self.removed = true
      end
    end

    completed_output = output_class.new(false, false)
    ClaudeEasy.watch_process_owner(StringIO.new("D"), 12_345, completed_output)
    assert completed_output.closed
    refute completed_output.removed

    abandoned_output = output_class.new(false, false)
    signals = []
    Process.stub(:kill, lambda { |signal, pid|
      signals << [signal, pid]
      raise Errno::ESRCH if signal == "TERM"
    }) do
      ClaudeEasy.watch_process_owner(StringIO.new, 12_345, abandoned_output)
    end
    assert abandoned_output.removed
    assert_equal [["TERM", -12_345], ["KILL", 12_345]], signals

    terminated_output = output_class.new(false, false)
    signals = []
    Process.stub(:kill, ->(signal, pid) { signals << [signal, pid] }) do
      ClaudeEasy.watch_process_owner(StringIO.new, 12_345, terminated_output)
    end
    assert terminated_output.removed
    assert_equal [["TERM", -12_345], ["KILL", -12_345]], signals

    writer = Object.new
    writer.define_singleton_method(:write) { |_value| raise Errno::EPIPE }
    writer.define_singleton_method(:close) { true }
    finished_output = output_class.new(false, false)
    Process.stub(:waitpid, ->(_pid) { raise Errno::ECHILD }) do
      ClaudeEasy.finish_process_watchdog(writer, 12_345, finished_output)
    end
    assert finished_output.removed
  end

  def test_profile_operation_lock_closes_after_lock_failure
    Dir.mktmpdir do |directory|
      ClaudeEasy.stub(:lock_exclusive_with_timeout, ->(_handle) { raise IOError, "injected lock failure" }) do
        assert_raises(IOError) { ClaudeEasy.profile_operation_lock(File.join(directory, "backups")) }
      end
    end
  end

  def test_pending_profile_transaction_recovery_restores_the_running_profile
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "original"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, original)
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        backup_root, roots: [directory]
      )
      File.binwrite(profile, candidate)
      runtime_reloaded = false

      ClaudeEasy.stub(:selected_profile_name, "friend") do
        ClaudeEasy.stub(:active_profile_root, directory) do
          reload = lambda do |work_items, require_tun:, **_arguments|
            runtime_reloaded = true
            assert_equal :preserve, require_tun
            assert_equal [profile], work_items.select { |item| item.fetch(:active) }.map { |item| item.fetch(:path) }
            true
          end
          ClaudeEasy.stub(:reload_recovered_profile_runtime, reload) do
            assert_equal :recovered, ClaudeEasy.recover_pending_profile_transaction(
              backup_root, directories: [directory]
            )
          end
        end
      end

      assert runtime_reloaded
      assert_equal original.b, File.binread(profile)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_pending_transaction_keeps_recovery_intent_when_profile_switches_during_runtime_health_check
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "original"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, original)
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        backup_root, roots: [directory]
      )
      File.binwrite(profile, candidate)
      selected = "friend"
      put_paths = []
      requester = lambda do |_socket, method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"]
          put_paths << JSON.parse(body).fetch("path")
          [204, ""]
        when ["POST", "/cache/fakeip/flush"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
            [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "203.0.113.1" }])]
          else
            [404, ""]
          end
        end
      end

      result = ClaudeEasy.stub(:selected_profile_name, -> { selected }) do
        ClaudeEasy.stub(:controller_socket, "socket") do
          ClaudeEasy.stub(:controller_request, requester) do
            ClaudeEasy.stub(:default_connectivity_healthy?, lambda { |**_options|
              selected = "other"
              true
            }) do
              ClaudeEasy.recover_pending_profile_transaction(
                backup_root, directories: [directory]
              )
            end
          end
        end
      end

      assert_equal [File.expand_path(profile)], put_paths
      assert_equal :runtime_restore_pending, result
      assert_equal original.b, File.binread(profile)
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_profile_transaction_recovery_normalizes_invalid_base64
    Dir.mktmpdir do |directory|
      root = File.join(directory, "backups")
      FileUtils.mkdir_p(root)
      File.chmod(0o700, root)
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")
      transaction = {
        "Version" => 1,
        "Items" => [{
          "Path" => profile,
          "WritePath" => File.realpath(profile),
          "OriginalBase64" => "!",
          "CandidateSha256" => Digest::SHA256.hexdigest("candidate")
        }]
      }
      File.binwrite(
        File.join(root, ClaudeEasy::PROFILE_TRANSACTION_BASENAME),
        JSON.generate(transaction)
      )

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.recover_profile_transaction(root, roots: [directory])
      end
    end

    Dir.mktmpdir do |directory|
      root = File.join(directory, "backups")
      FileUtils.mkdir_p(root)
      File.chmod(0o700, root)
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "external-refresh")
      transaction = {
        "Version" => 1,
        "Items" => [{
          "Path" => profile,
          "WritePath" => File.realpath(profile),
          "OriginalBase64" => Base64.strict_encode64("original"),
          "CandidateSha256" => Digest::SHA256.hexdigest("candidate")
        }]
      }
      transaction_path = File.join(root, ClaudeEasy::PROFILE_TRANSACTION_BASENAME)
      File.binwrite(transaction_path, JSON.generate(transaction))

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.recover_profile_transaction(root, roots: [directory])
      end
      assert_equal "external-refresh", File.binread(profile)
      assert File.exist?(transaction_path)
    end
  end

  def test_profile_transaction_recovery_keeps_a_missing_recorded_target
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [directory]
      )
      File.unlink(profile)

      assert_raises(IOError) do
        ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])
      end
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_profile_transaction_recovery_keeps_unsafe_recorded_targets
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile_root = File.join(directory, "profiles")
      FileUtils.mkdir_p(profile_root)
      profile = File.join(profile_root, "friend.yaml")
      File.binwrite(profile, "original")
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [profile_root]
      )
      File.link(profile, File.join(profile_root, "alias.yaml"))

      assert_raises(IOError) do
        ClaudeEasy.recover_profile_transaction(backup_root, roots: [profile_root])
      end
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end

    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile_root = File.join(directory, "profiles")
      moved_root = File.join(directory, "moved-profiles")
      FileUtils.mkdir_p(profile_root)
      profile = File.join(profile_root, "friend.yaml")
      File.binwrite(profile, "original")
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [profile_root]
      )
      File.rename(profile_root, moved_root)
      File.symlink(moved_root, profile_root)

      ClaudeEasy.stub(:profile_path_allowed?, true) do
        assert_raises(IOError) do
          ClaudeEasy.recover_profile_transaction(backup_root, roots: [profile_root])
        end
      end
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_profile_transaction_keeps_journal_when_restore_loses_the_inode
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [directory]
      )
      File.binwrite(profile, "candidate")
      failed_restore = lambda do |*_arguments, **_options|
        replacement = File.join(directory, "replacement.yaml")
        File.binwrite(replacement, "candidate")
        File.rename(replacement, profile)
        false
      end

      ClaudeEasy.stub(:transactional_compare_and_write_bytes, failed_restore) do
        assert_raises(IOError) do
          ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])
        end
      end
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_profile_transaction_recovery_keeps_v2_journal_when_descriptor_restore_fails
    Dir.mktmpdir do |directory|
      root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        root, roots: [directory]
      )
      File.binwrite(profile, "candidate")

      ClaudeEasy.stub(:transactional_compare_and_write_bytes, false) do
        assert_raises(IOError) do
          ClaudeEasy.recover_profile_transaction(root, roots: [directory])
        end
      end
      assert_equal "candidate", File.binread(profile)
      assert File.exist?(ClaudeEasy.profile_transaction_path(root))
    end
  end

  def test_profile_transaction_recovery_continues_after_a_same_inode_partial_write
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      partial = File.join(directory, "partial.yaml")
      complete = File.join(directory, "complete.yaml")
      File.binwrite(partial, "first-original")
      File.binwrite(complete, "second-original")
      ClaudeEasy.prepare_profile_transaction([
        { path: partial, original: "first-original", candidate: "first-candidate" },
        { path: complete, original: "second-original", candidate: "second-candidate" }
      ], backup_root, roots: [directory])
      File.binwrite(partial, "first-partial")
      File.binwrite(complete, "second-candidate")

      assert_raises(IOError) do
        ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])
      end
      assert_equal "first-partial", File.binread(partial)
      assert_equal "second-original", File.binread(complete)
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_profile_transaction_rejects_a_symlink_target_outside_the_profile_root_before_publication
    Dir.mktmpdir do |directory|
      profile_root = File.join(directory, "profiles")
      outside_root = File.join(directory, "outside")
      backup_root = File.join(directory, "backups")
      FileUtils.mkdir_p([profile_root, outside_root])
      target = File.join(outside_root, "actual.yaml")
      linked_directory = File.join(profile_root, "linked")
      profile = File.join(linked_directory, "actual.yaml")
      File.binwrite(target, "original")
      File.symlink(outside_root, linked_directory)

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.prepare_profile_transaction(
          [{ path: profile, original: "original", candidate: "candidate" }],
          backup_root, roots: [profile_root]
        )
      end

      assert_equal "original", File.binread(target)
      refute ClaudeEasy.profile_transaction_pending?(backup_root)
    end
  end

  def test_profile_transaction_rejects_a_symlink_target_inside_the_profile_root_before_publication
    Dir.mktmpdir do |directory|
      profile_root = File.join(directory, "profiles")
      backup_root = File.join(directory, "backups")
      FileUtils.mkdir_p(profile_root)
      target = File.join(profile_root, "actual.yaml")
      profile = File.join(profile_root, "friend.yaml")
      File.binwrite(target, "original")
      File.symlink("actual.yaml", profile)

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.prepare_profile_transaction(
          [{ path: profile, original: "original", candidate: "candidate" }],
          backup_root, roots: [profile_root]
        )
      end

      assert_equal "original", File.binread(target)
      refute ClaudeEasy.profile_transaction_pending?(backup_root)
    end
  end

  def test_profile_transaction_requires_exclusive_publication
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")

      assert_raises(IOError) do
        ClaudeEasyDarwinFilesystem.stub(:rename_exclusive, ->(*) { raise IOError, "injected" }) do
          ClaudeEasy.prepare_profile_transaction(
            [{ path: profile, original: "original", candidate: "candidate" }],
            backup_root, roots: [directory]
          )
        end
      end
      refute ClaudeEasy.profile_transaction_pending?(backup_root)
    end
  end

  def test_profile_transaction_fsyncs_the_journal_directory_after_publish_and_remove
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")
      journal_path = ClaudeEasy.profile_transaction_path(backup_root)
      publication_syncs = []
      snapshot = ClaudeEasy.stub(:fsync_parent_directory, lambda { |path|
        assert File.file?(path)
        publication_syncs << path
        true
      }) do
        ClaudeEasy.prepare_profile_transaction(
          [{ path: profile, original: "original", candidate: "candidate" }],
          backup_root, roots: [directory]
        )
      end
      assert_equal [journal_path], publication_syncs

      removal_syncs = []
      ClaudeEasy.stub(:fsync_parent_directory, lambda { |path|
        removal_syncs << if File.exist?(path)
                           assert_equal ClaudeEasy::PROFILE_TRANSACTION_COMMITTED_BYTES,
                                        File.binread(path)
                           :marker_published
                         else
                           :marker_removed
                         end
        true
      }) do
        ClaudeEasy.remove_profile_transaction(snapshot)
      end
      assert_equal %i[marker_published marker_removed], removal_syncs
    end
  end

  def test_profile_transaction_remove_sync_failure_keeps_the_commit_successful
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      journal_path = ClaudeEasy.profile_transaction_path(backup_root)
      real_sync = ClaudeEasy.method(:fsync_parent_directory)
      injected_sync = lambda do |path|
        if path == journal_path && !File.exist?(path)
          raise IOError, "injected removal directory sync failure"
        end

        real_sync.call(path)
      end

      results = ClaudeEasy.stub(:fsync_parent_directory, injected_sync) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
          selected_name: "friend", validator: ->(_path) { true }, usage_profile: 1
        )
      end

      assert_equal :updated, results.first.fetch(:status)
      refute_equal original.b, File.binread(profile)
      refute File.exist?(journal_path)
    end
  end

  def test_profile_transaction_committed_marker_never_rolls_back_the_candidate
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [directory]
      )
      File.binwrite(profile, "candidate")
      File.binwrite(transaction.fetch(:path), ClaudeEasy::PROFILE_TRANSACTION_COMMITTED_BYTES)

      result = ClaudeEasy.resume_profile_transaction(
        backup_root, roots: [directory],
        work_items: [{ path: profile, active: true }], reload_runtime: true,
        require_tun: true,
        requester: ->(*_arguments) { flunk "committed marker triggered runtime rollback" }
      )

      assert_equal :recovered, result
      assert_equal "candidate", File.binread(profile)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_profile_transaction_commit_publication_never_truncates_the_pending_journal
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [directory]
      )
      pending_bytes = File.binread(transaction.fetch(:path))
      real_rename = File.method(:rename)
      reject_commit = lambda do |source, destination|
        raise IOError, "injected commit publication failure" if destination == transaction.fetch(:path)

        real_rename.call(source, destination)
      end

      File.stub(:rename, reject_commit) do
        assert_raises(IOError) { ClaudeEasy.remove_profile_transaction(transaction) }
      end

      assert_equal pending_bytes, File.binread(transaction.fetch(:path))
      ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])
      refute File.exist?(transaction.fetch(:path))
    end
  end

  def test_profile_transaction_commit_directory_sync_failure_reports_uncertain_state
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [directory]
      )
      journal_path = transaction.fetch(:path)
      real_sync = ClaudeEasy.method(:fsync_parent_directory)
      fail_committed_sync = lambda do |path|
        if path == journal_path && File.binread(path) == ClaudeEasy::PROFILE_TRANSACTION_COMMITTED_BYTES
          raise IOError, "injected committed marker directory sync failure"
        end

        real_sync.call(path)
      end

      error = assert_raises(ClaudeEasy::ProfileCommitStateUncertainError) do
        ClaudeEasy.stub(:fsync_parent_directory, fail_committed_sync) do
          ClaudeEasy.remove_profile_transaction(
            transaction, state_uncertain_on_sync_failure: true
          )
        end
      end

      assert_includes error.message, "无法确认"
      assert_equal ClaudeEasy::PROFILE_TRANSACTION_COMMITTED_BYTES, File.binread(journal_path)
      assert_equal :committed, ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])
      refute File.exist?(journal_path)

      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [directory]
      )
      error = assert_raises(IOError) do
        ClaudeEasy.stub(:fsync_parent_directory, fail_committed_sync) do
          ClaudeEasy.remove_profile_transaction(transaction)
        end
      end
      refute_kind_of ClaudeEasy::ProfileCommitStateUncertainError, error
      assert_equal ClaudeEasy::PROFILE_TRANSACTION_COMMITTED_BYTES, File.binread(journal_path)
    end
  end

  def test_pending_recovery_cleans_a_committed_marker_without_runtime_context_or_profiles
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      ClaudeEasy.secure_backup_root!(backup_root)
      journal_path = ClaudeEasy.profile_transaction_path(backup_root)
      File.binwrite(journal_path, ClaudeEasy::PROFILE_TRANSACTION_COMMITTED_BYTES)

      result = ClaudeEasy.stub(:capture_runtime_profile_context, ->(*_arguments) {
        flunk "committed marker requested runtime context"
      }) do
        ClaudeEasy.recover_pending_profile_transaction(
          backup_root, directories: []
        )
      end

      assert_equal :committed_cleaned, result
      refute File.exist?(journal_path)
    end
  end

  def test_profile_transaction_directory_sync_failure_aborts_before_target_write
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")

      ClaudeEasy.stub(:fsync_parent_directory, ->(_path) { raise IOError, "injected directory sync failure" }) do
        assert_raises(IOError) do
          ClaudeEasy.prepare_profile_transaction(
            [{ path: profile, original: "original", candidate: "candidate" }],
            backup_root, roots: [directory]
          )
        end
      end

      assert_equal "original", File.binread(profile)
      assert ClaudeEasy.profile_transaction_pending?(backup_root)
    end
  end

  def test_profile_transaction_v1_never_overwrites_an_unidentified_candidate_inode
    Dir.mktmpdir do |directory|
      root = File.join(directory, "backups")
      FileUtils.mkdir_p(root)
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "candidate")
      transaction = {
        "Version" => 1,
        "Items" => [{
          "Path" => profile,
          "WritePath" => File.realpath(profile),
          "OriginalBase64" => Base64.strict_encode64("original"),
          "CandidateSha256" => Digest::SHA256.hexdigest("candidate")
        }]
      }
      transaction_path = ClaudeEasy.profile_transaction_path(root)
      File.binwrite(transaction_path, JSON.generate(transaction) + "\n")

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.recover_profile_transaction(root, roots: [directory])
      end
      assert_equal "candidate", File.binread(profile)
      assert File.exist?(transaction_path)

      File.binwrite(profile, "original")
      ClaudeEasy.recover_profile_transaction(root, roots: [directory])
      assert_equal "original", File.binread(profile)
      refute File.exist?(transaction_path)
    end
  end

  def test_safe_update_rollback_reports_unreadable_candidate_recovery_failure
    item = {
      name: "friend", path: "/missing/profile.yaml", write_path: "/missing/profile.yaml",
      candidate: "candidate", candidate_identity: [1, 2]
    }
    recovered = false
    removed = false
    ClaudeEasy.stub(:rollback_safe_update_items, []) do
      ClaudeEasy.stub(:recover_profile_transaction, lambda { |*_args, **_kwargs|
        recovered = true
        raise IOError
      }) do
        ClaudeEasy.stub(:remove_profile_transaction, ->(_transaction) { removed = true }) do
          assert_equal({ failures: [""], superseded: [] },
                       ClaudeEasy.finish_safe_update_rollback([item], {}, "/backups", ["/missing"]))
        end
      end
    end
    assert recovered
    refute removed
  end

  def test_safe_update_rollback_separates_failures_from_superseded_items
    failed = { name: "failed", committed_identity: [1, 1] }
    superseded = { name: "superseded", committed_identity: [2, 2] }
    result = ClaudeEasy.stub(:rollback_safe_update_items, ["failed"]) do
      ClaudeEasy.stub(:recover_profile_transaction, true) do
        ClaudeEasy.stub(:safe_update_item_restored?, false) do
          ClaudeEasy.finish_safe_update_rollback(
            [failed, superseded], {}, "/backups", ["/profiles"]
          )
        end
      end
    end
    assert_equal ["failed"], result.fetch(:failures)
    assert_equal ["superseded"], result.fetch(:superseded)
  end

  def test_mihomo_core_status_covers_supported_old_and_unreadable_results
    Dir.mktmpdir do |directory|
      core = File.join(directory, "mihomo")
      File.write(core, "#!/bin/sh\n")
      File.chmod(0o700, core)
      success = Struct.new(:success?).new(true)

      ClaudeEasy.stub(:run_process_with_timeout, ["Mihomo Meta v1.19.27", success, false]) do
        assert_equal :supported, ClaudeEasy.mihomo_core_status(core)
      end
      ClaudeEasy.stub(:run_process_with_timeout, ["Mihomo Meta v1.19.26", success, false]) do
        assert_equal :too_old, ClaudeEasy.mihomo_core_status(core)
      end
      ClaudeEasy.stub(:run_process_with_timeout, ->(*_args, **_kwargs) { raise IOError }) do
        assert_equal :unreadable, ClaudeEasy.mihomo_core_status(core)
      end

      expected = File.expand_path(
        "~/Library/Application Support/com.metacubex.ClashX.meta/.private_core/" \
          "com.metacubex.ClashX.ProxyConfigHelper.meta"
      )
      File.stub(:file?, ->(path) { path == expected }) do
        File.stub(:executable?, ->(path) { path == expected }) do
          assert_equal expected, ClaudeEasy.mihomo_core_path
        end
      end
    end
  end

  def test_file_transaction_helpers_fail_closed_and_restore_partial_writes
    handle = Object.new
    handle.define_singleton_method(:flock) { |_mode| false }
    times = [0.0, 0.0, 1.0]
    ClaudeEasy.stub(:monotonic_now, -> { times.shift }) do
      ClaudeEasy.stub(:sleep, nil) do
        assert_raises(IOError) { ClaudeEasy.lock_exclusive_with_timeout(handle, timeout_seconds: 0.5) }
      end
    end

    missing = File.join(Dir.tmpdir, "missing-claude-easy-identity")
    refute ClaudeEasy.transactional_compare_and_write_bytes(missing, "old", "new")
    refute ClaudeEasy.locked_source_current?(Tempfile.new("missing-source"), missing, missing)

    Tempfile.create("claude-easy-write") do |file|
      file.binmode
      file.write("original")
      file.flush
      assert ClaudeEasy.write_locked_bytes(file, "replacement", "original")
      file.rewind
      assert_equal "replacement", file.read
    end

    failing = Object.new
    failing.define_singleton_method(:rewind) {}
    failing.define_singleton_method(:truncate) { |_length| }
    failing.define_singleton_method(:write) { |_bytes| raise IOError, "injected write failure" }
    error = assert_raises(IOError) { ClaudeEasy.write_locked_bytes(failing, "new", "old") }
    assert_includes error.message, "原内容恢复失败"
  end

  def test_patch_path_reports_non_idempotence_validation_timeout_and_unexpected_errors
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      File.write(path, YAML.dump(base_config))
      calls = 0
      non_idempotent = lambda do |config, _policy, usage_profile:|
        calls += 1
        assert_equal 3, usage_profile
        { changed: true, status: :updated, config: config }
      end
      ClaudeEasy.stub(:patch, non_idempotent) do
        result = ClaudeEasy.patch_path(path, @policy, dry_run: true)
        assert_equal :non_idempotent, result.fetch(:status)
      end
      assert_equal 2, calls

      result = ClaudeEasy.patch_path(path, @policy, validator: ->(_candidate) { :timeout })
      assert_equal :validation_timeout, result.fetch(:status)

      concurrent = ClaudeEasy.patch_path(
        path, @policy, expected_original: "different original"
      )
      assert_equal :concurrent_change, concurrent.fetch(:status)
      assert_equal false, concurrent.fetch(:transaction_commit)

      ClaudeEasy.stub(:patch_path_once, ->(*_args, **_kwargs) { raise "injected unexpected failure" }) do
        assert_equal :error, ClaudeEasy.patch_path(path, @policy).fetch(:status)
      end
    end
  end

  def test_run_rejects_bad_policy
    Dir.mktmpdir do |directory|
      invalid_policy = File.join(directory, "policy.json")
      [
        { "version" => -1 },
        @policy.reject { |key, _value| key == "cn_ip_provider" }
      ].each do |policy|
        File.write(invalid_policy, JSON.generate(policy))
        error = assert_raises(ClaudeEasy::InvalidConfigError) do
          ClaudeEasy.run(directory: directory, policy_path: invalid_policy)
        end
        assert_equal "策略版本或内容无效", error.message
      end
    end
  end

  def test_runtime_helpers_cover_socket_discovery_and_exception_boundaries
    status = Struct.new(:success?).new(true)
    ClaudeEasy.stub(:mihomo_core_paths, [RbConfig.ruby]) do
      Open3.stub(:capture2, ["#{RbConfig.ruby} -f /tmp/active.yaml\n/untrusted/mihomo -f /tmp/no.yaml\n", status]) do
        assert_equal ["/tmp/active.yaml"], ClaudeEasy.running_mihomo_config_paths
      end
    end
    Open3.stub(:capture2, ->(*_args) { raise IOError }) do
      assert_empty ClaudeEasy.running_mihomo_config_paths
    end

    Dir.mktmpdir do |home|
      old_home = ENV["HOME"]
      ENV["HOME"] = home
      cache = File.join(home, "Library", "Caches", "com.MetaCubeX.ClashX.meta", "cacheConfigs")
      FileUtils.mkdir_p(cache)
      socket_path = File.join(home, "controller.sock")
      server = UNIXServer.new(socket_path)
      active_config = File.join(cache, "active.yaml")
      File.write(active_config, YAML.dump(
        "external-controller-unix" => socket_path, "secret" => "fixture-secret"
      ))
      ClaudeEasy.stub(:running_mihomo_config_paths, [active_config]) do
        assert_equal socket_path, ClaudeEasy.controller_socket
        assert_equal "fixture-secret", ClaudeEasy.controller_secret(socket_path)
      end
    ensure
      server&.close
      ENV["HOME"] = old_home
    end

    Dir.mktmpdir do |home|
      old_home = ENV["HOME"]
      ENV["HOME"] = home
      cache = File.join(home, "Library", "Caches", "com.MetaCubeX.ClashX.meta", "cacheConfigs")
      FileUtils.mkdir_p(cache)
      File.write(File.join(cache, "invalid.yaml"), ":\n")
      assert_nil ClaudeEasy.controller_socket
    ensure
      ENV["HOME"] = old_home
    end

    Open3.stub(:capture2e, ->(*_args) { raise IOError }) do
      assert_equal [0, ""], ClaudeEasy.controller_request("socket", "GET", "/configs")
    end
    ClaudeEasy.stub(:controller_socket, nil) do
      assert_equal :unknown, ClaudeEasy.tun_state
    end
    ClaudeEasy.stub(:controller_socket, "socket") do
      ClaudeEasy.stub(:controller_request, [200, JSON.generate("tun" => { "enable" => true })]) do
        assert_equal :enabled, ClaudeEasy.tun_state
      end
    end
    assert_equal :unknown, ClaudeEasy.tun_state(requester: ->(*_args) {
      [200, JSON.generate("tun" => { "enable" => nil })]
    })
    Open3.stub(:capture2e, ->(*_args) { raise IOError }) do
      refute ClaudeEasy.default_connectivity_healthy?
    end
  end

  def test_controller_socket_refuses_ambiguous_live_cache_controllers
    Dir.mktmpdir do |home|
      old_home = ENV["HOME"]
      ENV["HOME"] = home
      cache = File.join(home, "Library", "Caches", "com.MetaCubeX.ClashX.meta", "cacheConfigs")
      FileUtils.mkdir_p(cache)
      first_path = File.join(home, "first.sock")
      second_path = File.join(home, "second.sock")
      first_server = UNIXServer.new(first_path)
      second_server = UNIXServer.new(second_path)
      first_config = File.join(cache, "first.yaml")
      first_alias = File.join(cache, "first-alias.yaml")
      second_config = File.join(cache, "second.yaml")
      File.write(first_config, YAML.dump("external-controller-unix" => first_path))
      File.write(first_alias, YAML.dump("external-controller-unix" => first_path))
      File.write(second_config, YAML.dump("external-controller-unix" => second_path))

      ClaudeEasy.stub(:running_mihomo_config_paths, []) do
        assert_nil ClaudeEasy.controller_socket
      end
      ClaudeEasy.stub(:running_mihomo_config_paths, [first_alias]) do
        assert_equal first_path, ClaudeEasy.controller_socket
      end
      ClaudeEasy.stub(:running_mihomo_config_paths, [second_config]) do
        assert_equal second_path, ClaudeEasy.controller_socket
      end
      ClaudeEasy.stub(:running_mihomo_config_paths, [first_config, second_config]) do
        assert_nil ClaudeEasy.controller_socket
      end
      FileUtils.rm_f(second_config)
      ClaudeEasy.stub(:running_mihomo_config_paths, []) { assert_nil ClaudeEasy.controller_socket }
    ensure
      first_server&.close
      second_server&.close
      ENV["HOME"] = old_home
    end
  end

  def test_runtime_rollback_helpers_fail_closed_on_missing_files_and_request_errors
    missing_result = {
      path: File.join(Dir.tmpdir, "missing-claude-easy-profile"),
      rollback_bytes: "old",
      patched_digest: Digest::SHA256.hexdigest("new")
    }
    refute ClaudeEasy.restore_profile_bytes(missing_result)
    refute ClaudeEasy.runtime_health_healthy?(
      ->(*_args) { raise IOError },
      selections: {}, expected_tun: :enabled, connectivity_checker: -> { true }
    )

    ClaudeEasy.stub(:controller_socket, nil) do
      ClaudeEasy.stub(:rollback_after_reload_failure, :reload_failed_restore_pending) do
        result = ClaudeEasy.activate_updated_profile(missing_result)
        assert_equal :reload_failed_restore_pending, result.fetch(:status)
      end
    end
    ClaudeEasy.stub(:runtime_selections, ->(_requester) { raise IOError }) do
      ClaudeEasy.stub(:rollback_after_reload_failure, :reload_failed_restore_pending) do
        result = ClaudeEasy.activate_updated_profile(missing_result, requester: ->(*_args) { [200, "{}"] })
        assert_equal :reload_failed_restore_pending, result.fetch(:status)
      end
    end
    ClaudeEasy.stub(:controller_socket, "socket") do
      ClaudeEasy.stub(:controller_request, [503, ""]) do
        ClaudeEasy.stub(:rollback_after_reload_failure, :reload_failed_restore_pending) do
          result = ClaudeEasy.activate_updated_profile(missing_result)
          assert_equal :reload_failed_restore_pending, result.fetch(:status)
        end
      end
    end
    ClaudeEasy.stub(:restore_profile_bytes, true) do
      assert_equal(
        :reload_failed_restore_pending,
        ClaudeEasy.rollback_after_reload_failure(missing_result, nil, nil)
      )
      status = ClaudeEasy.rollback_after_reload_failure(
        missing_result, ->(*_args) { raise IOError }, missing_result.fetch(:path),
        selections: {}, expected_tun: :enabled
      )
      assert_equal :reload_failed_restore_pending, status
    end
    ClaudeEasy.stub(:restore_profile_bytes, false) do
      assert_equal(
        :reload_failed_rollback_conflict,
        ClaudeEasy.rollback_after_reload_failure(missing_result, nil, nil)
      )
    end
    refute ClaudeEasy.restore_runtime_tun_state(
      ->(*_args) { raise IOError }, :enabled
    )
    requests = []
    requester = lambda do |method, endpoint, body = nil|
      requests << [method, endpoint, body]
      [200, JSON.generate("tun" => { "enable" => false })]
    end
    refute ClaudeEasy.restore_runtime_tun_state(requester, :enabled)
    assert_equal [["GET", "/configs", nil]], requests
    ClaudeEasy.stub(:restore_profile_bytes, true) do
      ClaudeEasy.stub(:reload_profile_runtime, true) do
        ClaudeEasy.stub(:runtime_health_healthy?, false) do
          assert_equal(
            :reload_failed_restore_pending,
            ClaudeEasy.rollback_after_reload_failure(
              missing_result, ->(*_args) { [204, ""] }, missing_result.fetch(:path),
              selections: {}, expected_tun: :enabled
            )
          )
        end
        ClaudeEasy.stub(:runtime_health_healthy?, ->(*_args, **_options) { raise IOError }) do
          assert_equal(
            :reload_failed_restore_pending,
            ClaudeEasy.rollback_after_reload_failure(
              missing_result, ->(*_args) { [204, ""] }, missing_result.fetch(:path),
              selections: {}, expected_tun: :enabled
            )
          )
        end
      end
    end
  end

  def test_runtime_rollback_does_not_patch_tun_when_the_original_subscription_omits_it
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      original = YAML.dump(base_config.reject { |key, _value| key == "tun" })
      candidate = YAML.dump(base_config.merge("tun" => { "enable" => true }))
      File.binwrite(path, candidate)
      stat = File.stat(path)
      result = {
        path: path, rollback_bytes: original.b,
        patched_digest: Digest::SHA256.hexdigest(candidate.b),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(path)
      }
      tun_enabled = true
      reloads = 0
      config_reads = 0
      patches = []
      requester = lambda do |method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/configs"]
          config_reads += 1
          [200, JSON.generate("tun" => { "enable" => tun_enabled })]
        when ["PUT", "/configs?force=true"]
          reloads += 1
          loaded = ClaudeEasy.load_yaml(File.read(JSON.parse(body).fetch("path")))
          tun_enabled = loaded.dig("tun", "enable") == true
          [204, ""]
        when ["PATCH", "/configs"]
          payload = JSON.parse(body)
          patches << payload
          tun_enabled = payload.dig("tun", "enable") == true
          [204, ""]
        else
          raise "unexpected controller request: #{method} #{endpoint}"
        end
      end
      health_checks = 0
      health = lambda do |_requester, **_options|
        health_checks += 1
        reloads > 1 && tun_enabled
      end

      activated = ClaudeEasy.stub(:runtime_selections, {}) do
        ClaudeEasy.stub(:runtime_health_healthy?, health) do
          ClaudeEasy.stub(:sleep, nil) do
            ClaudeEasy.activate_updated_profile(result, requester: requester, require_tun: true)
          end
        end
      end

      assert_equal :reload_failed_restore_pending, activated.fetch(:status)
      assert_equal original.b, File.binread(path)
      refute tun_enabled
      assert_equal 2, reloads
      assert_equal 3, config_reads
      assert_empty patches
    end
  end

  def test_runtime_rollback_accepts_the_original_dns_limit_when_connectivity_is_restored
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "new"))
      File.binwrite(path, candidate)
      stat = File.stat(path)
      result = {
        path: path, rollback_bytes: original.b,
        patched_digest: Digest::SHA256.hexdigest(candidate.b),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(path)
      }
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        when ["PUT", "/configs?force=true"], ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          if method == "GET" && endpoint.include?("www.baidu.com")
            [500, JSON.generate("message" => "dns resolve failed")]
          else
            raise "unexpected controller request: #{method} #{endpoint}"
          end
        end
      end

      status = ClaudeEasy.rollback_after_reload_failure(
        result, requester, path, selections: { "Main" => "Taiwan" },
        expected_tun: :enabled, connectivity_checker: -> { true }
      )

      assert_equal :reload_failed_rolled_back, status
      assert_equal original.b, File.binread(path)
    end
  end

  def test_controller_socket_ignores_wrong_shapes_and_regular_files
    Dir.mktmpdir do |home|
      old_home = ENV["HOME"]
      ENV["HOME"] = home
      cache = File.join(home, "Library", "Caches", "com.MetaCubeX.ClashX.meta", "cacheConfigs")
      FileUtils.mkdir_p(cache)
      regular_file = File.join(home, "not-a-socket")
      File.write(regular_file, "")
      File.write(File.join(cache, "array.yaml"), YAML.dump(["wrong shape"]))
      File.write(
        File.join(cache, "regular-file.yaml"),
        YAML.dump("external-controller-unix" => regular_file)
      )

      assert_nil ClaudeEasy.controller_socket
    ensure
      ENV["HOME"] = old_home
    end
  end

  def test_transactional_replace_preserves_an_external_refresh_after_the_final_identity_check
    Dir.mktmpdir do |directory|
      path = File.join(directory, "profile.yaml")
      replacement_path = File.join(directory, "external.yaml")
      File.binwrite(path, "original")
      File.binwrite(replacement_path, "external-refresh")
      external_identity = nil
      checks = 0
      real_current = ClaudeEasy.method(:locked_source_current?)
      check_with_refresh = lambda do |*arguments|
        current = real_current.call(*arguments)
        checks += 1
        if current && checks == 1
          File.rename(replacement_path, path)
          stat = File.stat(path)
          external_identity = [stat.dev, stat.ino]
        end
        current
      end

      File.open(path, "r+b") do |source|
        result = ClaudeEasy.stub(:locked_source_current?, check_with_refresh) do
          ClaudeEasy.transactional_replace_locked(source, path, File.realpath(path), "original", "candidate")
        end
        refute result
      end

      current = File.stat(path)
      assert_equal 2, checks
      assert_equal "external-refresh", File.binread(path)
      assert_equal external_identity, [current.dev, current.ino]
      assert_empty Dir.glob(File.join(directory, ".claude-easy-swap-*"))
    end
  end

  def test_safe_update_preserves_an_external_refresh_after_the_final_identity_check
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      external = YAML.dump(base_config.merge("subscription-marker" => "external-refresh"))
      File.binwrite(path, original)
      injected = false
      external_identity = nil
      checks = 0
      real_current = ClaudeEasy.method(:locked_profile_current?)
      check_with_refresh = lambda do |*arguments|
        current = real_current.call(*arguments)
        checks += 1
        if current && checks == 2
          replacement_path = File.join(directory, "external.yaml")
          File.binwrite(replacement_path, external)
          File.rename(replacement_path, path)
          stat = File.stat(path)
          external_identity = [stat.dev, stat.ino]
          injected = true
        end
        current
      end

      result = ClaudeEasy.stub(:locked_profile_current?, check_with_refresh) do
        ClaudeEasy.safe_update_all(
          targets: [{ name: "friend", path: path, url: "https://subscriptions.invalid/friend" }],
          policy: @policy, backup_root: backup_root, usage_profile: 1,
          fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
          validator: ->(_path) { true },
          activation: ->(_items) { flunk "a concurrent refresh must not activate" },
          selected_name: "friend"
        )
      end

      current = File.stat(path)
      assert injected
      assert_equal :rollback_failed, result.fetch(:status)
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_equal external.b, File.binread(path)
      assert_equal external_identity, [current.dev, current.ino]
      assert_empty Dir.glob(File.join(directory, ".claude-easy-update-swap-*"))
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_safe_update_rechecks_every_candidate_after_runtime_activation
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      targets = %w[active other].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.binwrite(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:name), File.binread(target.fetch(:path))] }
      external = YAML.dump(base_config.merge("subscription-marker" => "external-other")).b
      activation = lambda do |_items|
        replacement = File.join(directory, "external.yaml")
        File.binwrite(replacement, external)
        File.rename(replacement, targets.fetch(1).fetch(:path))
        { status: :updated, reloaded: true }
      end
      reloads = 0

      result = ClaudeEasy.stub(:reload_recovered_safe_update_runtime, lambda { |*_arguments, **_options|
        reloads += 1
        false
      }) do
        ClaudeEasy.safe_update_all(
          targets: targets, policy: @policy, backup_root: backup_root, usage_profile: 1,
          fetcher: lambda { |target|
            YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}"))
          },
          validator: ->(_path) { true }, activation: activation, selected_name: "active"
        )
      end

      assert_equal :runtime_restore_pending, result.fetch(:status)
      assert result.fetch(:rollback_superseded)
      assert_equal 1, reloads
      assert_equal originals.fetch("active"), File.binread(targets.fetch(0).fetch(:path))
      assert_equal external, File.binread(targets.fetch(1).fetch(:path))
      assert File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_safe_update_restores_runtime_after_a_post_activation_replacement
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      targets = %w[active other].map do |name|
        path = File.join(directory, "#{name}.yaml")
        File.binwrite(path, YAML.dump(base_config.merge("subscription-marker" => "old-#{name}")))
        { name: name, path: path, url: "https://subscriptions.invalid/#{name}" }
      end
      originals = targets.to_h { |target| [target.fetch(:name), File.binread(target.fetch(:path))] }
      external = YAML.dump(base_config.merge("subscription-marker" => "external-other")).b
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(targets.fetch(0).fetch(:path)),
        expected_tun: :ignore, selections: {}
      }
      reloads = 0
      native_reloader = lambda do |_current|
        reloads += 1
        if reloads == 1
          replacement = File.join(directory, "external.yaml")
          File.binwrite(replacement, external)
          File.rename(replacement, targets.fetch(1).fetch(:path))
        end
        true
      end

      result = ClaudeEasy.stub(:runtime_checkpoint_current?, true) do
        ClaudeEasy.stub(:capture_runtime_checkpoint, checkpoint) do
          ClaudeEasy.safe_update_all(
            targets: targets, policy: @policy, backup_root: backup_root, usage_profile: 1,
            fetcher: lambda { |target|
              YAML.dump(base_config.merge("subscription-marker" => "new-#{target.fetch(:name)}"))
            },
            validator: ->(_path) { true }, selected_name: "active",
            client_identity_reader: -> { identity }, native_reloader: native_reloader,
            runtime_waiter: ->(*_arguments, **_options) { true },
            reload_snapshot_reader: -> { { "log" => [1, 2, reloads] } }
          )
        end
      end

      assert_equal :aborted, result.fetch(:status)
      assert_equal :rollback_superseded, result.fetch(:reason)
      assert_equal 2, reloads
      assert_equal originals.fetch("active"), File.binread(targets.fetch(0).fetch(:path))
      assert_equal external, File.binread(targets.fetch(1).fetch(:path))
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
    end
  end

  def test_safe_update_finalization_covers_runtime_and_rollback_outcomes
    precommit = run_with_stubbed_safe_update_finalization(
      activation: { status: :updated, reloaded: true },
      runtime_precommit: false, rollback: { failures: [], superseded: [] }
    )
    assert_equal :runtime_restore_pending, precommit.fetch(:status)

    failed = run_with_stubbed_safe_update_finalization(
      activation: true, runtime_precommit: true,
      rollback: { failures: ["unexpected"], superseded: [] }
    )
    assert_equal :rollback_failed, failed.fetch(:status)

    cleanup_failed = run_with_stubbed_safe_update_finalization(
      activation: { status: :updated, reloaded: true },
      runtime_precommit: true, rollback: { failures: [], superseded: ["friend"] },
      reload: true, remove: :raise
    )
    assert_equal :runtime_restore_pending, cleanup_failed.fetch(:status)

    superseded = run_with_stubbed_safe_update_finalization(
      activation: true, runtime_precommit: true,
      rollback: { failures: [], superseded: ["friend"] }
    )
    assert_equal :rollback_superseded, superseded.fetch(:reason)

    activation_superseded = run_with_stubbed_safe_update_finalization(
      activation: false, runtime_precommit: true,
      rollback: { failures: [], superseded: ["friend"] }
    )
    assert_equal :rollback_superseded, activation_superseded.fetch(:reason)

  end

  def test_profile_transaction_preserves_ambiguous_partial_writes_for_manual_retry
    ["", "candida", "original"].each do |partial|
      Dir.mktmpdir do |directory|
        backup_root = File.join(directory, "backups")
        profile = File.join(directory, "friend.yaml")
        original = "original-profile-bytes"
        candidate = "candidate-profile-bytes"
        File.binwrite(profile, original)
        ClaudeEasy.prepare_profile_transaction(
          [{ path: profile, original: original, candidate: candidate }],
          backup_root, roots: [directory]
        )
        state = JSON.parse(File.binread(ClaudeEasy.profile_transaction_path(backup_root)))
        assert_equal 2, state.fetch("Version")

        File.open(profile, "r+b") do |handle|
          handle.truncate(0)
          handle.write(partial)
          handle.flush
          handle.fsync
        end

        assert_raises(IOError) do
          ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])
        end

        assert_equal partial, File.binread(profile)
        assert ClaudeEasy.profile_transaction_pending?(backup_root)
      end
    end
  end

  def test_profile_transaction_keeps_candidate_bytes_after_an_atomic_replacement
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      original = "original-profile-bytes"
      candidate = "candidate-profile-bytes"
      File.binwrite(profile, original)
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        backup_root, roots: [directory]
      )
      external_path = File.join(directory, "external.yaml")
      File.binwrite(external_path, candidate)
      File.rename(external_path, profile)
      external_stat = File.stat(profile)

      assert_raises(IOError) do
        ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])
      end

      current = File.stat(profile)
      assert_equal candidate.b, File.binread(profile)
      assert_equal [external_stat.dev, external_stat.ino], [current.dev, current.ino]
      assert ClaudeEasy.profile_transaction_pending?(backup_root)
    end
  end

  def test_profile_transaction_rejects_unrelated_bytes_on_the_original_inode
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      original = "original-profile-bytes"
      candidate = "candidate-profile-bytes"
      File.binwrite(profile, original)
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        backup_root, roots: [directory]
      )
      original_stat = File.stat(profile)
      File.binwrite(profile, "unrelated-concurrent-bytes")

      assert_raises(IOError) do
        ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])
      end

      current_stat = File.stat(profile)
      assert_equal [original_stat.dev, original_stat.ino], [current_stat.dev, current_stat.ino]
      assert_equal "unrelated-concurrent-bytes", File.binread(profile)
      assert ClaudeEasy.profile_transaction_pending?(backup_root)
    end
  end

  def test_safe_update_preserves_an_ambiguous_partial_descriptor_write_and_journal
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.binwrite(profile, original)
      real_write = ClaudeEasy.method(:write_locked_bytes)
      writes = 0
      partial_first_write = lambda do |handle, replacement, original_bytes|
        writes += 1
        if writes == 1
          handle.rewind
          handle.truncate(0)
          handle.write(replacement.byteslice(0, 24))
          handle.flush
          handle.fsync
          raise IOError, "injected interruption after a partial descriptor write"
        end
        real_write.call(handle, replacement, original_bytes)
      end

      result = ClaudeEasy.stub(:write_locked_bytes, partial_first_write) do
        ClaudeEasy.safe_update_all(
          targets: [{
            name: "friend", path: profile,
            url: "https://subscriptions.invalid/friend"
          }],
          policy: @policy, backup_root: backup_root, usage_profile: 1,
          fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
          validator: ->(_path) { true },
          activation: ->(_items) { flunk "a partial write must not activate" },
          selected_name: "friend"
        )
      end

      assert_equal :rollback_failed, result.fetch(:status)
      assert_equal :write_failed, result.fetch(:reason)
      assert_equal 1, writes
      refute_equal original.b, File.binread(profile)
      assert ClaudeEasy.profile_transaction_pending?(backup_root)
    end
  end

  def test_safe_update_detects_lock_time_and_post_write_identity_changes
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.write(path, original)
      arguments = {
        targets: [{ name: "friend", path: path, url: "https://subscriptions.invalid/friend" }],
        policy: @policy,
        backup_root: File.join(directory, "backups"),
        usage_profile: 3,
        fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
        validator: ->(_candidate) { true },
        activation: ->(_items) { flunk "must not activate" },
        selected_name: "friend"
      }

      lock_checks = [true, false]
      result = ClaudeEasy.stub(:locked_profile_current?, ->(*_args) { lock_checks.shift }) do
        ClaudeEasy.safe_update_all(**arguments)
      end
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_empty lock_checks
      assert_equal original.b, File.binread(path)

      File.binwrite(path, original)
      real_current = ClaudeEasy.method(:locked_source_current?)
      identity_checks = 0
      post_write_change = false
      reject_final_identity = lambda do |*arguments|
        current = real_current.call(*arguments)
        identity_checks += 1
        if current && identity_checks == 2
          post_write_change = true
          false
        else
          current
        end
      end
      result = ClaudeEasy.stub(:locked_source_current?, reject_final_identity) do
        ClaudeEasy.safe_update_all(**arguments)
      end
      assert_equal :concurrent_change, result.fetch(:reason)
      assert post_write_change
      assert_equal original.b, File.binread(path)
    end
  end

  def test_storage_and_application_discovery_cover_local_and_icloud_variants
    ClaudeEasy.stub(:storage_mode, :icloud) do
      assert ClaudeEasy.icloud_enabled?
    end
    ClaudeEasy.stub(:selected_profile_name, nil) do
      assert_empty ClaudeEasy.default_profile_directories(
        home: Dir.tmpdir, app_paths: [], cloud_enabled: true
      )
    end

    expected_user_app = File.expand_path("~/Applications/ClashX Meta.app")
    Dir.stub(:exist?, ->(path) { path == expected_user_app }) do
      assert_equal [expected_user_app], ClaudeEasy.clashx_app_paths
    end

    Dir.mktmpdir do |directory|
      missing_app = File.join(directory, "Missing.app")
      valid_app = File.join(directory, "Valid.app")
      broken_app = File.join(directory, "Broken.app")
      FileUtils.mkdir_p(File.join(valid_app, "Contents"))
      FileUtils.mkdir_p(File.join(broken_app, "Contents"))
      File.write(File.join(valid_app, "Contents", "Info.plist"), "fixture")
      File.write(File.join(broken_app, "Contents", "Info.plist"), "fixture")
      success = Struct.new(:success?).new(true)
      runner = lambda do |*_args|
        [JSON.generate("NSUbiquitousContainers" => { "iCloud.com.friend" => {} }), success]
      end

      ids = Open3.stub(:capture2, runner) do
        ClaudeEasy.icloud_container_ids([missing_app, valid_app])
      end
      assert_includes ids, "iCloud.com.friend"

      Open3.stub(:capture2, ->(*_args) { raise IOError, "injected plist failure" }) do
        ids = ClaudeEasy.icloud_container_ids([broken_app])
        assert_equal %w[iCloud.com.metacubex.ClashX], ids
      end
    end

    roots = ["/tmp/cloud", "/tmp/local/.config/clash.meta"]
    ClaudeEasy.stub(:profile_paths, []) do
      ClaudeEasy.stub(:icloud_enabled?, false) do
        assert_raises(ClaudeEasy::InvalidConfigError) do
          ClaudeEasy.active_profile_root(roots, "friend")
        end
      end
    end

    ClaudeEasy.stub(:profile_paths, ["/tmp/friend.yaml"]) do
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.active_profile_root(roots, "friend")
      end
    end
  end

  def test_result_contract_sanitizes_unknown_objects
    object = Object.new
    object.define_singleton_method(:to_s) { "token=fixture-secret" }

    assert_equal "[已隐藏]", ClaudeEasyResult.sanitize(object)
  end

  def test_cli_preserves_the_saved_profile_when_runtime_or_file_recovery_is_pending
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.write(profile, YAML.dump(base_config))
      arguments = [
        "--json", "--profile-dir", directory, "--backup-dir", backup_root,
        "--policy", POLICY_PATH, "--usage-profile", "1"
      ]

      ClaudeEasy.stub(:saved_usage_profile, 1) do
        ClaudeEasy.stub(:run, [{ status: :reload_failed_restore_pending, path: profile }]) do
          output, error = capture_io { assert_equal 77, ClaudeEasy.cli(arguments.dup) }
          assert_empty error
          result = JSON.parse(output)
          assert_equal "partial", result.fetch("status")
          assert_equal "profile_recovery_pending", result.fetch("code")
        end

        ClaudeEasy.stub(:run, ->(**_options) { raise IOError, "injected partial write" }) do
          ClaudeEasy.stub(:profile_transaction_pending?, true) do
            output, error = capture_io { assert_equal 77, ClaudeEasy.cli(arguments.dup) }
            assert_empty error
            assert_equal "profile_recovery_pending", JSON.parse(output).fetch("code")

            output, error = capture_io do
              assert_equal 77, ClaudeEasy.cli(arguments.reject { |item| item == "--json" })
            end
            assert_empty output
            assert_includes error, "配置恢复尚未完成"
          end

          ClaudeEasy.stub(:profile_transaction_pending?, ->(_root) { raise IOError }) do
            output, error = capture_io { assert_equal 1, ClaudeEasy.cli(arguments.dup) }
            assert_empty error
            assert_equal "unexpected_error", JSON.parse(output).fetch("code")
          end
        end
      end
    end
  end

  def test_cli_reconciles_macos_client_switches_and_returns_manual_steps
    success = {
      status: :reconciled, reason: nil, changes: %i[tun system_proxy],
      checks: [{ "name" => "connectivity", "ok" => true }]
    }
    ClaudeEasy.stub(:saved_usage_profile, 2) do
      ClaudeEasy.stub(:reconcile_clashx_client_switches, success) do
        output, error = capture_io do
          assert_equal 0, ClaudeEasy.cli([
            "--json", "--reconcile-client-switches", "--usage-profile", "2"
          ])
        end
        assert_empty error
        result = JSON.parse(output)
        assert_equal "client_switches_reconciled", result.fetch("code")
        assert_equal %w[tun system_proxy], result.fetch("changes")
      end
    end

    manual = {
      status: :manual_required, reason: :state_ambiguous, changes: [], checks: []
    }
    ClaudeEasy.stub(:saved_usage_profile, 3) do
      ClaudeEasy.stub(:reconcile_clashx_client_switches, manual) do
        output, error = capture_io do
          assert_equal 1, ClaudeEasy.cli([
            "--json", "--reconcile-client-switches", "--usage-profile", "3"
          ])
        end
        assert_empty error
        result = JSON.parse(output)
        assert_equal "client_switch_manual_required", result.fetch("code")
        assert_includes result.fetch("messages").join(" "), "点击菜单栏 ClashX Meta 图标"
        assert_includes result.fetch("messages").join(" "), "TUN 模式"
        assert_includes result.fetch("messages").join(" "), "设置为系统代理"
        assert_includes result.fetch("messages").join(" "), "只有未勾选时才点击一次"
        assert_includes result.fetch("messages").join(" "), "只有已勾选时才点击一次"
      end
    end
    output, error = capture_io do
      assert_equal 64, ClaudeEasy.cli(["--reconcile-client-switches"])
    end
    assert_empty output
    assert_includes error, "必须指定用途档位"

    cases = [
      [
        2, { status: :reconciled, reason: nil, changes: [:tun], checks: [] },
        0, "已经自动协调"
      ],
      [
        2, { status: :unchanged, reason: nil, changes: [], checks: [] },
        0, "已经符合当前档位"
      ],
      [
        1, { status: :manual_required, reason: :state_ambiguous, changes: [], checks: [] },
        1, "设置为系统代理"
      ],
      [
        2, { status: :manual_required, reason: :third_party_proxy_active, changes: [], checks: [] },
        1, "第三方 PAC"
      ]
    ]
    cases.each do |profile, result, exit_code, expected|
      ClaudeEasy.stub(:saved_usage_profile, profile) do
        ClaudeEasy.stub(:reconcile_clashx_client_switches, result) do
          output, error = capture_io do
            assert_equal exit_code, ClaudeEasy.cli([
              "--reconcile-client-switches", "--usage-profile", profile.to_s
            ])
          end
          assert_includes "#{output}#{error}", expected
        end
      end
    end

    third_party = {
      status: :manual_required, reason: :third_party_proxy_active,
      changes: [], checks: []
    }
    ClaudeEasy.stub(:saved_usage_profile, 1) do
      ClaudeEasy.stub(:reconcile_clashx_client_switches, third_party) do
        output, error = capture_io do
          assert_equal 1, ClaudeEasy.cli([
            "--json", "--reconcile-client-switches", "--usage-profile", "1"
          ])
        end
        assert_empty error
        assert_includes JSON.parse(output).fetch("messages").join(" "), "第三方 PAC"
      end
    end
  end

  def test_cli_client_switch_reconciliation_requires_the_saved_profile
    ClaudeEasy.stub(:saved_usage_profile, 1) do
      output, error = capture_io do
        assert_equal 10, ClaudeEasy.cli([
          "--json", "--reconcile-client-switches", "--usage-profile", "2"
        ])
      end
      assert_empty error
      result = JSON.parse(output)
      assert_equal "usage_profile_mismatch", result.fetch("code")
      assert_equal 1, result.fetch("profile")
    end
  end

  def test_cli_recovers_a_pending_profile_transaction_for_uninstall
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      calls = []
      recovery = lambda do |root, directories:, guard_storage:, expected_storage:|
        calls << [root, directories, guard_storage, expected_storage]
        :recovered
      end
      ClaudeEasy.stub(:recover_pending_profile_transaction, recovery) do
        output, error = capture_io do
          assert_equal 0, ClaudeEasy.cli([
            "--profile-dir", directory, "--backup-dir", backup_root,
            "--recover-profile-transaction"
          ])
        end
        assert_empty error
        assert_equal "未完成的配置事务已恢复。\n", output
      end
      assert_equal [[backup_root, [directory], false, nil]], calls

      ClaudeEasy.stub(:recover_pending_profile_transaction, :recovered) do
        output, error = capture_io do
          assert_equal 0, ClaudeEasy.cli([
            "--json", "--profile-dir", directory, "--backup-dir", backup_root,
            "--recover-profile-transaction"
          ])
        end
        assert_empty error
        result = JSON.parse(output)
        assert_equal "profile_transaction_recovered", result.fetch("code")
        assert_equal ["profiles", "runtime_config"], result.fetch("changes")
      end
      ClaudeEasy.stub(:recover_pending_profile_transaction, :none) do
        output, error = capture_io do
          assert_equal 0, ClaudeEasy.cli([
            "--json", "--profile-dir", directory, "--backup-dir", backup_root,
            "--recover-profile-transaction"
          ])
        end
        assert_empty error
        result = JSON.parse(output)
        assert_equal "no_change", result.fetch("status")
        assert_empty result.fetch("changes")
      end
      ClaudeEasy.stub(:recover_pending_profile_transaction, :committed_cleaned) do
        output, error = capture_io do
          assert_equal 0, ClaudeEasy.cli([
            "--profile-dir", directory, "--backup-dir", backup_root,
            "--recover-profile-transaction"
          ])
        end
        assert_empty error
        assert_equal "已清理完成提交后遗留的事务标记。\n", output
      end
      ClaudeEasy.stub(:recover_pending_profile_transaction, :none) do
        output, error = capture_io do
          assert_equal 0, ClaudeEasy.cli([
            "--profile-dir", directory, "--backup-dir", backup_root,
            "--recover-profile-transaction"
          ])
        end
        assert_empty error
        assert_equal "没有未完成的配置事务。\n", output
      end
      ClaudeEasy.stub(:recover_pending_profile_transaction, :runtime_restore_pending) do
        _output, error = capture_io do
          assert_equal 1, ClaudeEasy.cli([
            "--profile-dir", directory, "--backup-dir", backup_root,
            "--recover-profile-transaction"
          ])
        end
        assert_includes error, "运行配置"
      end
      ClaudeEasy.stub(:recover_pending_profile_transaction, :runtime_restore_pending) do
        output, error = capture_io do
          assert_equal 1, ClaudeEasy.cli([
            "--json", "--profile-dir", directory, "--backup-dir", backup_root,
            "--recover-profile-transaction"
          ])
        end
        assert_empty error
        assert_equal "profile_transaction_runtime_pending", JSON.parse(output).fetch("code")
      end
      ClaudeEasy.stub(:recover_pending_profile_transaction, :profile_directory_missing) do
        output, error = capture_io do
          assert_equal 2, ClaudeEasy.cli([
            "--json", "--backup-dir", backup_root, "--recover-profile-transaction"
          ])
        end
        assert_empty error
        assert_equal "profile_directory_missing", JSON.parse(output).fetch("code")
      end
      ClaudeEasy.stub(:recover_pending_profile_transaction, :profile_directory_missing) do
        _output, error = capture_io do
          assert_equal 2, ClaudeEasy.cli([
            "--backup-dir", backup_root, "--recover-profile-transaction"
          ])
        end
        assert_includes error, "没有找到"
      end
    end
  end

  def test_cli_cleans_a_committed_transaction_when_profile_directories_are_missing
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      ClaudeEasy.secure_backup_root!(backup_root)
      journal_path = ClaudeEasy.profile_transaction_path(backup_root)
      File.binwrite(journal_path, ClaudeEasy::PROFILE_TRANSACTION_COMMITTED_BYTES)

      ClaudeEasy.stub(:default_profile_directories, []) do
        output, error = capture_io do
          assert_equal 0, ClaudeEasy.cli([
            "--json", "--backup-dir", backup_root, "--recover-profile-transaction"
          ])
        end
        assert_empty error
        result = JSON.parse(output)
        assert_equal "profile_transaction_cleanup_completed", result.fetch("code")
        assert_equal "no_change", result.fetch("status")
        assert_empty result.fetch("changes")
      end
      refute File.exist?(journal_path)
    end
  end

  def test_cli_reports_missing_profile_directories
    ClaudeEasy.stub(:default_profile_directories, []) do
      _output, error = capture_io { assert_equal 2, ClaudeEasy.cli([]) }
      assert_includes error, "没有找到"
    end

    Dir.mktmpdir do |directory|
      ClaudeEasy.stub(:saved_usage_profile, 1) do
        ClaudeEasy.stub(:run, []) do
          _output, error = capture_io do
            arguments = [
              "--profile-dir", directory, "--policy", POLICY_PATH,
              "--usage-profile", "1"
            ]
            assert_equal 1, ClaudeEasy.cli(arguments)
          end
          assert_includes error, "没有找到可处理的配置"
        end
      end
    end
  end

  def test_cli_read_only_runtime_operations_use_their_authoritative_helpers
    ClaudeEasy.stub(:mihomo_core_status, :supported) do
      output, = capture_io { assert_equal 0, ClaudeEasy.cli(["--print-core-status"]) }
      assert_includes output, "supported"
    end
    ClaudeEasy.stub(:tun_state, :enabled) do
      output, = capture_io { assert_equal 0, ClaudeEasy.cli(["--print-tun-state"]) }
      assert_includes output, "enabled"
    end
    ClaudeEasy.stub(:subscription_auto_update_state, :disabled) do
      output, = capture_io { assert_equal 0, ClaudeEasy.cli(["--print-subscription-auto-update-state"]) }
      assert_includes output, "disabled"
    end
    ClaudeEasy.stub(:auto_update_ownership_state, { "Phase" => "installed" }) do
      output, = capture_io { assert_equal 0, ClaudeEasy.cli(["--print-auto-update-ownership-state"]) }
      assert_includes output, "owned"
    end
    ClaudeEasy.stub(:auto_update_ownership_state, nil) do
      output, = capture_io { assert_equal 0, ClaudeEasy.cli(["--print-auto-update-ownership-state"]) }
      assert_includes output, "not_owned"
    end
    ClaudeEasy.stub(:auto_update_ownership_state, ->(_root) { raise ClaudeEasy::InvalidConfigError, "bad state" }) do
      _output, error = capture_io do
        assert_equal 1, ClaudeEasy.cli(["--print-auto-update-ownership-state"])
      end
      assert_includes error, "bad state"
    end
    output, error = capture_io { assert_equal 0, ClaudeEasy.cli(["--json", "--help"]) }
    assert_empty error
    assert_equal "help", JSON.parse(output).fetch("operation")

    ClaudeEasy.stub(:mihomo_core_status, :supported) do
      output, error = capture_io { assert_equal 0, ClaudeEasy.cli(["--json", "--print-core-status"]) }
      assert_empty error
      assert_equal "ok", JSON.parse(output).fetch("status")
    end
    ClaudeEasy.stub(:mihomo_core_status, :missing) do
      output, error = capture_io { assert_equal 1, ClaudeEasy.cli(["--json", "--print-core-status"]) }
      assert_empty error
      assert_equal "unsupported", JSON.parse(output).fetch("status")
    end
    ClaudeEasy.stub(:tun_state, :enabled) do
      output, = capture_io { assert_equal 0, ClaudeEasy.cli(["--json", "--print-tun-state"]) }
      assert_equal "tun_state", JSON.parse(output).fetch("operation")
    end
    ClaudeEasy.stub(:subscription_auto_update_state, :disabled) do
      output, = capture_io do
        assert_equal 0, ClaudeEasy.cli(["--json", "--print-subscription-auto-update-state"])
      end
      assert_equal "subscription_auto_update_state", JSON.parse(output).fetch("operation")
    end
    ClaudeEasy.stub(:auto_update_ownership_state, nil) do
      output, = capture_io do
        assert_equal 0, ClaudeEasy.cli(["--json", "--print-auto-update-ownership-state"])
      end
      result = JSON.parse(output)
      assert_equal "auto_update_ownership_state", result.fetch("operation")
      assert_equal "not_owned", result.fetch("code")
    end
    ClaudeEasy.stub(:auto_update_ownership_state, ->(_root) { raise ClaudeEasy::InvalidConfigError }) do
      output, error = capture_io do
        assert_equal 1, ClaudeEasy.cli(["--json", "--print-auto-update-ownership-state"])
      end
      assert_empty error
      assert_equal "auto_update_state_invalid", JSON.parse(output).fetch("code")
    end
  end

  def test_saved_usage_profile_reads_one_fixed_private_snapshot
    Dir.mktmpdir do |temporary_directory|
      directory = File.realpath(temporary_directory)
      path = File.join(directory, "usage-profile.plist")
      system("/usr/bin/plutil", "-create", "xml1", path)
      system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", path)
      system("/usr/bin/plutil", "-insert", "Profile", "-integer", "2", path)
      File.chmod(0o600, path)

      assert_equal 2, ClaudeEasy.saved_usage_profile(path: path)
      assert_match(
        %r{/Library/Application Support/ClaudeEasy/usage-profile\.plist\z},
        ClaudeEasy.usage_profile_state_path
      )

      File.chmod(0o644, path)
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.saved_usage_profile(path: path)
      end
      File.chmod(0o600, path)

      File.unlink(path)
      File.symlink(File.join(directory, "outside"), path)
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.saved_usage_profile(path: path)
      end
      File.unlink(path)
      assert_nil ClaudeEasy.saved_usage_profile(path: path)
    end

    Dir.mktmpdir do |temporary_directory|
      directory = File.realpath(temporary_directory)
      path = File.join(directory, "usage-profile.plist")
      File.binwrite(path, "invalid")
      File.chmod(0o600, path)
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.saved_usage_profile(path: path)
      end
    end
  end

  def test_saved_usage_profile_rejects_document_type_entity_indirection
    Dir.mktmpdir do |temporary_directory|
      path = File.join(File.realpath(temporary_directory), "usage-profile.plist")
      File.binwrite(
        path,
        <<~PLIST
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd" [<!ENTITY profile "3">]>
          <plist version="1.0"><dict>
          <key>Version</key><integer>1</integer>
          <key>Profile</key><integer>&profile;</integer>
          </dict></plist>
        PLIST
      )
      File.chmod(0o600, path)

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.saved_usage_profile(path: path)
      end
    end
  end

  def test_usage_profile_reader_standalone_exit_contract
    _stdout, _stderr, status = capture_ruby_entrypoint(USAGE_PROFILE_STATE_PATH)
    assert_equal 2, status.exitstatus

    Dir.mktmpdir do |directory|
      missing = File.join(directory, "missing.plist")
      stdout, stderr, status = capture_ruby_entrypoint(USAGE_PROFILE_STATE_PATH, missing)
      assert_equal 1, status.exitstatus
      assert_empty stdout
      assert_empty stderr

      state = File.join(directory, "usage-profile.plist")
      File.binwrite(
        state,
        %(<?xml version="1.0"?><plist version="1.0"><dict>) \
          + %(<key>Version</key><integer>1</integer>) \
          + %(<key>Profile</key><integer>3</integer></dict></plist>)
      )
      File.chmod(0o600, state)
      stdout, stderr, status = capture_ruby_entrypoint(USAGE_PROFILE_STATE_PATH, state)
      assert_equal 0, status.exitstatus
      assert_equal "3\n", stdout
      assert_empty stderr
    end
  end

  def test_cli_profile_guard_rejects_unset_invalid_and_mismatched_state_before_work
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      original = File.binread(profile)
      calls = 0
      forbidden_run = lambda do |**_arguments|
        calls += 1
        flunk "profile work ran without an approved saved usage profile"
      end

      [
        [nil, "usage_profile_unset"],
        [1, "usage_profile_mismatch"],
        [-> { raise ClaudeEasy::InvalidConfigError }, "usage_profile_invalid"]
      ].each do |saved, expected_code|
        ClaudeEasy.stub(:saved_usage_profile, saved) do
          ClaudeEasy.stub(:run, forbidden_run) do
            output, error = capture_io do
              assert_equal 10, ClaudeEasy.cli([
                "--json", "--profile-dir", directory, "--policy", POLICY_PATH,
                "--usage-profile", "3"
              ])
            end
            assert_empty error
            assert_equal expected_code, JSON.parse(output).fetch("code")
          end
        end
      end

      assert_equal 0, calls
      assert_equal original.b, File.binread(profile)
      refute File.exist?(File.join(directory, "backups"))

      output, error = ClaudeEasy.stub(:saved_usage_profile, nil) do
        capture_io do
          assert_equal 10, ClaudeEasy.cli([
            "--profile-dir", directory, "--policy", POLICY_PATH,
            "--usage-profile", "3"
          ])
        end
      end
      assert_empty output
      assert_includes error, "尚未保存用途档位"

      output, error = capture_io do
        assert_equal 64, ClaudeEasy.cli([
          "--json", "--profile-dir", directory, "--policy", POLICY_PATH, "--dry-run"
        ])
      end
      assert_empty error
      assert_equal "usage_profile_required", JSON.parse(output).fetch("code")

      _output, error = capture_io do
        assert_equal 64, ClaudeEasy.cli([
          "--profile-dir", directory, "--policy", POLICY_PATH, "--dry-run"
        ])
      end
      assert_includes error, "必须显式指定用途档位"
    end
  end

  def test_cli_safe_update_and_auto_update_commands_cannot_bypass_wrapper_scope
    Dir.mktmpdir do |directory|
      targets = [{ name: "friend", path: File.join(directory, "friend.yaml") }]
      expected_followups = {
        1 => %w[macos_client_switch_reconciliation site_verification final_state_audit],
        2 => %w[
          macos_client_switch_reconciliation site_verification
          agent_connectivity_verification final_state_audit
        ],
        3 => %w[
          macos_client_switch_reconciliation site_verification agent_connectivity_verification
          route_verification dns_deep_test webrtc_test local_region_fingerprint_test
          final_state_audit
        ]
      }
      expected_followups.each do |profile, followups|
        ClaudeEasy.stub(:saved_usage_profile, profile) do
          ClaudeEasy.stub(:remote_subscription_targets, targets) do
            ClaudeEasy.stub(:safe_update_all, { status: :updated, count: 1, profiles: ["friend"] }) do
              output, error = capture_io do
                assert_equal 0, ClaudeEasy.cli([
                  "--json", "--profile-dir", directory, "--safe-update-all",
                  "--usage-profile", profile.to_s
                ])
              end
              assert_empty error
              result = JSON.parse(output)
              assert_equal "safe_update", result.fetch("operation")
              assert_equal "safe_update_completed", result.fetch("code")
              assert_equal false, result.fetch("workflow_complete")
              assert_equal "subscription_update", result.fetch("completed_scope")
              assert_equal followups, result.fetch("required_followups")
            end
          end
        end
      end

      [
        ["--disable-subscription-auto-update", "disable_subscription_auto_update"],
        ["--restore-owned-subscription-auto-update", "restore_owned_subscription_auto_update"]
      ].each do |argument, operation|
        output, error = capture_io do
          assert_equal 64, ClaudeEasy.cli([
            "--json", "--backup-dir", directory, "--usage-profile", "3", argument
          ])
        end
        assert_empty error
        result = JSON.parse(output)
        assert_equal operation, result.fetch("operation")
        assert_equal "internal_operation_required", result.fetch("code")
      end
    end
  end

  def test_uninstall_recovery_profile_accepts_every_managed_tier
    Dir.mktmpdir do |directory|
      state_path = File.join(directory, "usage-profile.plist")
      staging = File.join(directory, ".claude-easy-uninstall-staging")
      usage = File.join(staging, "usage")
      backup_root = File.join(directory, "backups")
      FileUtils.mkdir_p(staging)
      %w[READY AUTO_UPDATE_WAS_OWNED].each do |name|
        File.binwrite(File.join(staging, name), "")
      end

      ClaudeEasy.stub(:usage_profile_state_path, state_path) do
        [1, 2, 3].each do |profile|
          system("/usr/bin/plutil", "-create", "xml1", usage)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", usage)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", profile.to_s, usage)
          File.chmod(0o600, usage)
          assert ClaudeEasy.valid_uninstall_recovery_profile?(usage),
                 "档位 #{profile} 的卸载恢复凭据被拒绝"
        end
        refute ClaudeEasy.valid_uninstall_recovery_profile?(File.join(directory, "usage"))
        File.unlink(File.join(staging, "READY"))
        refute ClaudeEasy.valid_uninstall_recovery_profile?(usage)
        File.binwrite(File.join(staging, "READY"), "")
      end

      ClaudeEasy.stub(:disable_subscription_auto_update, { status: :already_disabled }) do
        output, error = with_internal_wrapper_operation(backup_root) do
          capture_io do
            assert_equal 0, ClaudeEasy.cli([
              "--json", "--backup-dir", backup_root, "--usage-profile", "3",
              "--internal-uninstall-recovery-state", usage,
              "--disable-subscription-auto-update"
            ])
          end
        end
        assert_empty error
        assert_equal "already_disabled", JSON.parse(output).fetch("code")
      end
    end
  end

  def test_cli_auto_update_internal_guard_covers_invalid_human_requests
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      invalid_recovery = File.join(directory, "wrong-usage")

      with_internal_wrapper_operation(backup_root) do
        _output, error = capture_io do
          assert_equal 64, ClaudeEasy.cli([
            "--backup-dir", backup_root, "--disable-subscription-auto-update"
          ])
        end
        assert_includes error, "必须显式指定用途档位"
      end

      ClaudeEasy.stub(:saved_usage_profile, 1) do
        with_internal_wrapper_operation(backup_root) do
          _output, error = capture_io do
            assert_equal 10, ClaudeEasy.cli([
              "--backup-dir", backup_root, "--usage-profile", "3",
              "--disable-subscription-auto-update"
            ])
          end
          assert_includes error, "不一致"
        end
      end

      with_internal_wrapper_operation(backup_root) do
        output, error = capture_io do
          assert_equal 10, ClaudeEasy.cli([
            "--json", "--backup-dir", backup_root, "--usage-profile", "3",
            "--internal-uninstall-recovery-state", invalid_recovery,
            "--disable-subscription-auto-update"
          ])
        end
        assert_empty error
        assert_equal "uninstall_recovery_state_invalid", JSON.parse(output).fetch("code")

        _output, error = capture_io do
          assert_equal 10, ClaudeEasy.cli([
            "--backup-dir", backup_root, "--usage-profile", "3",
            "--internal-uninstall-recovery-state", invalid_recovery,
            "--disable-subscription-auto-update"
          ])
        end
        assert_includes error, "恢复凭据无效"
      end

      [
        ["--disable-subscription-auto-update", "安装或恢复流程"],
        ["--restore-owned-subscription-auto-update", "安装、卸载或恢复流程"]
      ].each do |argument, message|
        _output, error = capture_io do
          assert_equal 64, ClaudeEasy.cli([
            "--backup-dir", backup_root, "--usage-profile", "3", argument
          ])
        end
        assert_includes error, message
      end
    end
  end

  def test_outer_lock_human_failure_reports_the_lock_status
    options = {
      disable_subscription_auto_update: false,
      enable_subscription_auto_update: false,
      restore_owned_subscription_auto_update: false,
      list_backups: false,
      compare_backup: nil,
      snapshot_initial: true,
      recover_profile_transaction: false,
      restore_backup: nil,
      safe_update_all: false,
      dry_run: false,
      json: false
    }
    ClaudeEasy.stub(:public_cli_entrypoint?, true) do
      ClaudeEasyOperationLock.stub(:run, ClaudeEasyOperationLock::BUSY_EXIT) do
        _output, error = capture_io do
          assert_equal ClaudeEasyOperationLock::BUSY_EXIT,
                       ClaudeEasy.enter_outer_wrapper_lock([], options)
        end
        assert_includes error, "另一个 ClaudeEasy 操作"
      end
    end
  end

  def test_public_mutations_reject_forged_or_unlocked_inherited_lock_descriptors
    Dir.mktmpdir do |home|
      profiles = File.join(home, "profiles")
      backup_root = File.join(home, "custom-backups")
      fixed_backup_root = File.join(
        home, "Library", "Application Support", "ClaudeEasy", "backups"
      )
      FileUtils.mkdir_p(profiles)
      FileUtils.mkdir_p(fixed_backup_root)
      profile = File.join(profiles, "friend.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      lock_path = File.join(fixed_backup_root, ".claude-easy-wrapper.lock")
      unlocked = File.open(lock_path, File::RDWR | File::CREAT, 0o600)
      unlocked.close_on_exec = false
      stat = unlocked.stat
      base_environment = {
        "HOME" => home,
        "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD" => "1"
      }
      cases = [
        {
          "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_FD" => nil,
          "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_IDENTITY" => nil
        },
        {
          "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_FD" => "1",
          "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_IDENTITY" => "#{stat.dev}:#{stat.ino}"
        },
        {
          "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_FD" => unlocked.fileno.to_s,
          "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_IDENTITY" => "#{stat.dev}:#{stat.ino}"
        }
      ]

      cases.each do |environment|
        stdout, stderr, status = capture_ruby_entrypoint(
          PATCHER_PATH,
          "--json", "--profile-dir", profiles, "--backup-dir", backup_root,
          "--snapshot-initial",
          environment: base_environment.merge(environment),
          spawn_options: { close_others: false }
        )
        assert_equal ClaudeEasyOperationLock::FAILED_EXIT, status.exitstatus, stderr
        assert_empty stderr
        assert_equal "operation_lock_failed", JSON.parse(stdout).fetch("code")
        assert_equal original.b, File.binread(profile)
        refute File.exist?(backup_root)
      end
    ensure
      unlocked&.close
    end
  end

  def test_public_patch_process_holds_the_fixed_wrapper_lock_before_reading_the_saved_profile
    Dir.mktmpdir do |home|
      profiles = File.join(home, "profiles")
      install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
      backup_root = File.join(install_dir, "backups")
      state = File.join(install_dir, "usage-profile.plist")
      core = File.join(
        home, "Applications", "ClashX Meta.app", "Contents", "Resources",
        "com.metacubex.ClashX.ProxyConfigHelper.meta"
      )
      FileUtils.mkdir_p(profiles)
      FileUtils.mkdir_p(backup_root)
      FileUtils.mkdir_p(File.dirname(core))
      File.binwrite(
        File.join(home, "Applications", "ClashX Meta.app", "Contents", "Info.plist"),
        <<~PLIST
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.metacubex.ClashX.meta</string>
          </dict></plist>
        PLIST
      )
      system("/usr/bin/plutil", "-create", "xml1", state)
      system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
      system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)
      File.chmod(0o600, state)
      File.binwrite(core, <<~'SH')
        #!/bin/sh
        [ "${1:-}" = "-v" ] && /usr/bin/printf '%s\n' "Mihomo Meta v1.19.27 test"
        exit 0
      SH
      File.chmod(0o700, core)
      preferences = File.join(home, "preferences_fixture.rb")
      File.binwrite(preferences, <<~'RUBY')
        require "open3"
        ClaudeEasyPublicPatchStatus = Struct.new(:success?)
        module Open3
          class << self
            alias claude_easy_public_patch_capture3 capture3
            def capture3(*arguments, **options)
              if arguments[0] == "/usr/bin/defaults" && arguments[1] == "export"
                return [
                  "<plist><dict><key>selectConfigName</key><string>friend</string></dict></plist>",
                  "", ClaudeEasyPublicPatchStatus.new(true)
                ]
              end
              if arguments[0] == "/usr/bin/plutil" && arguments[1] == "-convert" &&
                 options[:stdin_data].to_s.include?("selectConfigName")
                return [
                  options[:stdin_data], "",
                  ClaudeEasyPublicPatchStatus.new(true)
                ]
              end
              claude_easy_public_patch_capture3(*arguments, **options)
            end
          end
        end
      RUBY
      profile = File.join(profiles, "friend.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      arguments = [
        "--json", "--profile-dir", profiles, "--backup-dir", backup_root,
        "--usage-profile", "1", "--no-reload"
      ]
      environment = { "HOME" => home, "RUBYOPT" => "-r#{preferences}" }

      lock = ClaudeEasyOperationLock.acquire(
        File.join(backup_root, ".claude-easy-wrapper.lock")
      )
      begin
        stdout, stderr, status = capture_ruby_entrypoint(
          PATCHER_PATH, *arguments, environment: environment
        )
        assert_equal ClaudeEasyOperationLock::BUSY_EXIT, status.exitstatus, stderr
        assert_empty stderr
        assert_equal "operation_in_progress", JSON.parse(stdout).fetch("code")
        assert_equal original.b, File.binread(profile)
      ensure
        lock.close
      end

      stdout, stderr, status = capture_ruby_entrypoint(
        PATCHER_PATH, *arguments, environment: environment
      )
      assert status.success?, "#{stdout}\n#{stderr}"
      assert_empty stderr
      assert_equal "completed", JSON.parse(stdout).fetch("code")
      refute_equal original.b, File.binread(profile)
    end
  end

  def test_cli_json_covers_backup_and_auto_update_operations
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      backup_id = "ce-backup-v1-#{'a' * 64}"
      backup_item = { "id" => backup_id, "created_at" => "2026-08-04T12:34:56.123456789+08:00" }
      ClaudeEasy.stub(:list_backups, [backup_item]) do
        output, = capture_io do
          assert_equal 0, ClaudeEasy.cli(["--json", "--profile-dir", directory, "--list-backups"])
        end
        result = JSON.parse(output)
        assert_equal "backups_listed", result.fetch("code")
        assert_equal [backup_item], result.fetch("items")
      end
      ClaudeEasy.stub(:snapshot_initial_profiles, ["/private/friend.yaml.backup"]) do
        output, = capture_io do
          assert_equal 0, ClaudeEasy.cli(["--json", "--profile-dir", directory, "--snapshot-initial"])
        end
        assert_equal ["initial_snapshot"], JSON.parse(output).fetch("changes")
      end
      comparison = {
        backup_id: backup_id, same: false,
        backup_sha256: "b" * 64, current_sha256: "c" * 64,
        changes: ["dns.nameserver"]
      }
      ClaudeEasy.stub(:compare_backup, comparison) do
        output, = capture_io do
          assert_equal 0, ClaudeEasy.cli([
            "--json", "--profile-dir", directory, "--compare-backup", backup_id
          ])
        end
        result = JSON.parse(output)
        assert_equal ["dns.nameserver"], result.fetch("changes")
        assert_equal [{
          "id" => backup_id,
          "same" => false,
          "backup_sha256" => "b" * 64,
          "current_sha256" => "c" * 64
        }], result.fetch("items")
      end
      private_uuid = "11111111-2222-3333-4444-555555555555"
      private_comparison = comparison.merge(changes: ["proxy-providers.#{private_uuid}.url"])
      ClaudeEasy.stub(:compare_backup, private_comparison) do
        output, error = capture_io do
          assert_equal 0, ClaudeEasy.cli([
            "--profile-dir", directory, "--compare-backup", backup_id
          ])
        end
        refute_includes output, private_uuid
        assert_includes output, "[已隐藏]"
        assert_empty error
      end
      ClaudeEasy.stub(:saved_usage_profile, 3) do
        ClaudeEasy.stub(:restore_backup, ->(*_arguments, **_options) { flunk "invalid restore reached storage" }) do
          output, = capture_io do
            assert_equal 64, ClaudeEasy.cli([
              "--json", "--profile-dir", directory, "--restore-backup", "id"
            ])
          end
          result = JSON.parse(output)
          assert_equal "invalid_request", result.fetch("status")
          assert_equal "expected_current_sha256_required", result.fetch("code")
        end
      end
      output, error = capture_io do
        assert_equal 64, ClaudeEasy.cli([
          "--profile-dir", directory, "--restore-backup", "id"
        ])
      end
      assert_empty output
      assert_includes error, "SHA-256"
      ClaudeEasy.stub(:disable_subscription_auto_update, { status: :already_disabled }) do
        output, = ClaudeEasy.stub(:saved_usage_profile, 3) do
          with_internal_wrapper_operation(backup_root) do
            capture_io do
              assert_equal 0, ClaudeEasy.cli([
                "--json", "--backup-dir", backup_root, "--usage-profile", "3",
                "--disable-subscription-auto-update"
              ])
            end
          end
        end
        assert_equal "no_change", JSON.parse(output).fetch("status")
      end
      ClaudeEasy.stub(:disable_subscription_auto_update, ->(**_args) { raise ClaudeEasy::InvalidConfigError }) do
        output, error = ClaudeEasy.stub(:saved_usage_profile, 3) do
          with_internal_wrapper_operation(backup_root) do
            capture_io do
              assert_equal 1, ClaudeEasy.cli([
                "--json", "--backup-dir", backup_root, "--usage-profile", "3",
                "--disable-subscription-auto-update"
              ])
            end
          end
        end
        assert_empty error
        assert_equal "auto_update_failed", JSON.parse(output).fetch("code")
      end
      ClaudeEasy.stub(:restore_owned_subscription_auto_update, { status: :restored }) do
        output, = with_internal_wrapper_operation(backup_root) do
          capture_io do
            assert_equal 0, ClaudeEasy.cli([
              "--json", "--backup-dir", backup_root, "--restore-owned-subscription-auto-update"
            ])
          end
        end
        result = JSON.parse(output)
        assert_equal "restore_owned_subscription_auto_update", result.fetch("operation")
        assert_equal "restored", result.fetch("code")
        assert_equal ["subscription_auto_update"], result.fetch("changes")
      end
      ClaudeEasy.stub(:restore_owned_subscription_auto_update, ->(**_args) { raise ClaudeEasy::InvalidConfigError }) do
        output, error = with_internal_wrapper_operation(backup_root) do
          capture_io do
            assert_equal 1, ClaudeEasy.cli([
              "--json", "--backup-dir", backup_root, "--restore-owned-subscription-auto-update"
            ])
          end
        end
        assert_empty error
        assert_equal "auto_update_restore_failed", JSON.parse(output).fetch("code")
      end
    end
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      operations = [
        [
          :disable_subscription_auto_update,
          [
            "--backup-dir", backup_root, "--usage-profile", "3",
            "--disable-subscription-auto-update"
          ],
          { status: :disabled }
        ],
        [
          :restore_owned_subscription_auto_update,
          ["--backup-dir", backup_root, "--restore-owned-subscription-auto-update"],
          { status: :restored }
        ]
      ]
      operations.each do |method_name, arguments, result|
        calls = 0
        behavior = lambda do |*_arguments, **_keywords|
          calls += 1
          raise ClaudeEasy::InvalidConfigError, "injected maintenance failure" if calls == 2

          result
        end
        ClaudeEasy.stub(method_name, behavior) do
          output, error = ClaudeEasy.stub(:saved_usage_profile, 3) do
            with_internal_wrapper_operation(backup_root) do
              capture_io { assert_equal 0, ClaudeEasy.cli(arguments.dup) }
            end
          end
          assert_includes output, result.fetch(:status).to_s
          assert_empty error

          _output, error = ClaudeEasy.stub(:saved_usage_profile, 3) do
            with_internal_wrapper_operation(backup_root) do
              capture_io { assert_equal 1, ClaudeEasy.cli(arguments.dup) }
            end
          end
          assert_includes error, "injected maintenance failure"
        end
      end

      private_snapshot = "/private/11111111-2222-3333-4444-555555555555.yaml.backup"
      ClaudeEasy.stub(:snapshot_initial_profiles, [private_snapshot]) do
        output, error = capture_io do
          assert_equal 0, ClaudeEasy.cli(["--profile-dir", directory, "--snapshot-initial"])
        end
        assert_equal "#{ClaudeEasy.public_backup_id(File.basename(private_snapshot))}\n", output
        refute_includes output, "11111111-2222-3333-4444-555555555555"
        assert_empty error
      end
    end
  end

  def test_subscription_backup_preserves_files_and_cli_reports_completion
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      first = File.join(directory, "first.yaml")
      second = File.join(directory, "second.yaml")
      originals = { first => "first bytes\n".b, second => "second bytes\n".b }
      originals.each { |path, bytes| File.binwrite(path, bytes) }
      targets = [
        { name: "first", path: first },
        { name: "second", path: second }
      ]

      result = ClaudeEasy.backup_remote_subscriptions(
        targets: targets, backup_root: backup_root
      )
      assert_equal 2, result.fetch(:count)
      assert_equal %w[first second], result.fetch(:profiles)
      originals.each do |path, bytes|
        assert_equal bytes, File.binread(path)
        assert_equal 1, ClaudeEasy.backup_entries_for(path, backup_root, reason: "initial").length
        assert_equal 1, ClaudeEasy.backup_entries_for(path, backup_root, reason: "pre-update").length
      end

      ClaudeEasy.stub(:saved_usage_profile, 3) do
        ClaudeEasy.stub(:remote_subscription_targets, targets) do
          ClaudeEasy.stub(:safe_update_all, { status: :updated, count: 2, profiles: %w[first second] }) do
            output, error = capture_io do
              assert_equal 0, ClaudeEasy.cli([
                "--json", "--profile-dir", directory, "--backup-dir", backup_root,
                "--safe-update-all", "--usage-profile", "3"
              ])
            end
            assert_empty error
            parsed = JSON.parse(output)
            assert_equal "safe_update", parsed.fetch("operation")
            assert_equal "safe_update_completed", parsed.fetch("code")
            assert_equal %w[updated updated], parsed.fetch("items").map { |item| item.fetch("status") }
          end
        end
      end
    end
  end

  def test_cli_subscription_backup_failure_does_not_report_an_update
    Dir.mktmpdir do |directory|
      ClaudeEasy.stub(:saved_usage_profile, 3) do
        ClaudeEasy.stub(:remote_subscription_targets, ->(_directories) {
          raise ClaudeEasy::InvalidConfigError, "injected update failure"
        }) do
          output, error = capture_io do
            assert_equal 1, ClaudeEasy.cli([
              "--json", "--profile-dir", directory, "--safe-update-all", "--usage-profile", "3"
            ])
          end
          assert_empty error
          result = JSON.parse(output)
          assert_equal "safe_update", result.fetch("operation")
          assert_equal "invalid_configuration", result.fetch("code")
          refute_includes result.fetch("summary_zh"), "更新成功"
        end
      end
    end
  end

  def test_cli_human_restore_and_top_level_errors_report_without_sensitive_values
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      [
        :reload_failed_rolled_back,
        :reload_failed_rollback_conflict,
        :runtime_state_unavailable,
        :invalid_backup
      ].each do |status|
        private_id = "11111111-2222-3333-4444-555555555555"
        ClaudeEasy.stub(:saved_usage_profile, 3) do
          ClaudeEasy.stub(:restore_backup, {
            status: status, path: "/private/#{private_id}.yaml",
            restored_backup: "physical-#{private_id}.backup"
          }) do
            ClaudeEasy.stub(:selected_profile_name, "friend") do
              output, error = capture_io do
                assert_equal 1, ClaudeEasy.cli([
                  "--profile-dir", directory, "--restore-backup", "backup-id",
                  "--expected-current-sha256", "0" * 64
                ])
              end
              assert_includes output, status.to_s
              assert_includes output, "备份"
              refute_includes output, private_id
              refute_includes output, "/private/"
              assert_empty error
            end
          end
        end
      end

      missing_policy = File.join(directory, "missing-policy.json")
      _output, error = ClaudeEasy.stub(:saved_usage_profile, 1) do
        capture_io do
          assert_equal 1, ClaudeEasy.cli([
            "--profile-dir", directory, "--policy", missing_policy,
            "--usage-profile", "1"
          ])
        end
      end
      assert_includes error, "找不到所需文件"

      invalid_policy = File.join(directory, "invalid-policy.json")
      File.write(invalid_policy, "{")
      _output, error = ClaudeEasy.stub(:saved_usage_profile, 1) do
        capture_io do
          assert_equal 1, ClaudeEasy.cli([
            "--profile-dir", directory, "--policy", invalid_policy,
            "--usage-profile", "1"
          ])
        end
      end
      assert_includes error, "不是有效的 JSON"

      [
        [ClaudeEasy::InvalidConfigError.new("password=fixture-secret"), "ClaudeEasy 运行失败"],
        [RuntimeError.new("token=fixture-secret"), "ClaudeEasy 运行失败"]
      ].each do |exception, expected_text|
        ClaudeEasy.stub(:saved_usage_profile, 1) do
          ClaudeEasy.stub(:run, ->(**_arguments) { raise exception }) do
            _output, error = capture_io do
              assert_equal 1, ClaudeEasy.cli([
                "--profile-dir", directory, "--policy", POLICY_PATH,
                "--usage-profile", "1"
              ])
            end
            assert_includes error, expected_text
            refute_includes error, "fixture-secret"
          end
        end
      end
    end
  end

  def test_cli_restore_backup_reloads_and_checks_the_active_profile
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      restore_result = {
        status: :updated, path: profile, rollback_bytes: "current",
        patched_digest: Digest::SHA256.hexdigest("restored")
      }
      activated = false
      checkpoint = {
        path: File.realpath(profile), expected_tun: :disabled,
        selections: { "Main" => "Taiwan" }
      }
      activation = lambda do |result, require_tun:, require_safe_ai:, runtime_checkpoint:, **_keywords|
        activated = true
        assert_equal :preserve, require_tun
        assert_equal true, require_safe_ai
        assert_equal checkpoint, runtime_checkpoint
        result.merge(reloaded: true)
      end

      restore = lambda do |*_arguments, **keywords|
        assert_equal checkpoint,
                     keywords.fetch(:runtime_checkpoint_provider).call(profile)
        keywords.fetch(:activation).call(restore_result)
      end
      ClaudeEasy.stub(:restore_backup, restore) do
        ClaudeEasy.stub(:selected_profile_name, "friend") do
          ClaudeEasy.stub(:active_profile_root, directory) do
            ClaudeEasy.stub(:capture_runtime_checkpoint, checkpoint) do
              ClaudeEasy.stub(:activate_updated_profile, activation) do
                output, error = ClaudeEasy.stub(:saved_usage_profile, 3) do
                  capture_io do
                    assert_equal 0, ClaudeEasy.cli([
                      "--json", "--profile-dir", directory, "--restore-backup", "backup-id",
                      "--expected-current-sha256", "0" * 64
                    ])
                  end
                end
                assert_empty error
                assert_equal "ok", JSON.parse(output).fetch("status")
              end
            end
          end
        end
      end

      assert activated
    end
  end

  def test_cli_restore_backup_requires_a_valid_saved_usage_profile_before_work
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      forbidden = lambda do |*_arguments, **_keywords|
        flunk "restore ran without a valid saved usage profile"
      end
      [
        [nil, "usage_profile_unset"],
        [-> { raise ClaudeEasy::InvalidConfigError }, "usage_profile_invalid"]
      ].each do |saved, expected_code|
        output, error = ClaudeEasy.stub(:saved_usage_profile, saved) do
          ClaudeEasy.stub(:restore_backup, forbidden) do
            capture_io do
              assert_equal 10, ClaudeEasy.cli([
                "--json", "--profile-dir", directory, "--restore-backup", "backup-id",
                "--expected-current-sha256", "0" * 64
              ])
            end
          end
        end
        assert_empty error
        result = JSON.parse(output)
        assert_equal "restore_backup", result.fetch("operation")
        assert_equal expected_code, result.fetch("code")
      end

      _output, error = ClaudeEasy.stub(:saved_usage_profile, nil) do
        ClaudeEasy.stub(:restore_backup, forbidden) do
          capture_io do
            assert_equal 10, ClaudeEasy.cli([
              "--profile-dir", directory, "--restore-backup", "backup-id",
              "--expected-current-sha256", "0" * 64
            ])
          end
        end
      end
      assert_includes error, "尚未保存用途档位"
    end
  end

  def test_cli_restore_backup_labels_an_uncertain_commit_as_restore
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      context = {
        selected: "friend", active_path: File.realpath(profile),
        storage: nil, roots: [File.realpath(directory)]
      }
      uncertain = lambda do |*_arguments, **_keywords|
        raise ClaudeEasy::ProfileCommitStateUncertainError, "injected uncertain restore"
      end

      output, error = ClaudeEasy.stub(:saved_usage_profile, 1) do
        ClaudeEasy.stub(:capture_runtime_profile_context, context) do
          ClaudeEasy.stub(:restore_backup, uncertain) do
            capture_io do
              assert_equal ClaudeEasy::PROFILE_COMMIT_STATE_UNCERTAIN_EXIT, ClaudeEasy.cli([
                "--json", "--profile-dir", directory, "--restore-backup", "backup-id",
                "--expected-current-sha256", "0" * 64
              ])
            end
          end
        end
      end
      assert_empty error
      result = JSON.parse(output)
      assert_equal "restore_backup", result.fetch("operation")
      assert_equal "profile_commit_state_uncertain", result.fetch("code")
    end
  end

  def test_cli_restore_backup_refuses_an_unstable_client_context
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      [false, true].each do |json|
        arguments = [
          "--profile-dir", directory, "--restore-backup", "backup-id",
          "--expected-current-sha256", "0" * 64
        ]
        arguments.unshift("--json") if json
        output, error = ClaudeEasy.stub(:saved_usage_profile, 3) do
          ClaudeEasy.stub(:capture_runtime_profile_context, nil) do
            capture_io { assert_equal 1, ClaudeEasy.cli(arguments) }
          end
        end
        if json
          result = JSON.parse(output)
          assert_equal "client_state_changed", result.fetch("code")
          assert_empty error
        else
          assert_empty output
          assert_includes error, "当前订阅或存储位置正在变化"
        end
      end
    end
  end

  def test_cli_restore_backup_does_not_activate_a_noncurrent_profile
    Dir.mktmpdir do |directory|
      friend = File.join(directory, "friend.yaml")
      other = File.join(directory, "other.yaml")
      File.write(friend, YAML.dump(base_config))
      File.write(other, YAML.dump(base_config))
      restore_result = {
        status: :updated, path: friend, rollback_bytes: "current",
        patched_digest: Digest::SHA256.hexdigest("restored")
      }
      restore = lambda do |*_arguments, **keywords|
        keywords.fetch(:activation).call(restore_result)
      end

      ClaudeEasy.stub(:saved_usage_profile, 3) do
        ClaudeEasy.stub(:restore_backup, restore) do
          ClaudeEasy.stub(:selected_profile_name, "other") do
            output, error = capture_io do
              assert_equal 0, ClaudeEasy.cli([
                "--json", "--profile-dir", directory, "--restore-backup", "backup-id",
                "--expected-current-sha256", "0" * 64
              ])
            end
            assert_empty error
            result = JSON.parse(output)
            assert_equal "ok", result.fetch("status")
            assert_equal "updated", result.fetch("code")
            assert_equal "备份已恢复。", result.fetch("summary_zh")
          end
        end
      end
    end
  end

  def test_cli_restore_backup_applies_the_saved_profile_to_inactive_candidates
    Dir.mktmpdir do |directory|
      friend = File.join(directory, "friend.yaml")
      other = File.join(directory, "other.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(ClaudeEasy.patch(
        base_config.merge("subscription-marker" => "restored"), @policy, usage_profile: 2
      ).fetch(:config))
      File.binwrite(friend, current)
      File.binwrite(other, YAML.dump(base_config))
      backup = ClaudeEasy.create_versioned_backup(
        friend, backup_root, content: restored, reason: "prewrite"
      )
      arguments = [
        "--json", "--profile-dir", directory, "--backup-dir", backup_root,
        "--restore-backup", File.basename(backup),
        "--expected-current-sha256", Digest::SHA256.hexdigest(current.b)
      ]

      ClaudeEasy.stub(:selected_profile_name, "other") do
        ClaudeEasy.stub(:validate_with_mihomo, :timeout) do
          [2, 3].each do |usage_profile|
            output, error = ClaudeEasy.stub(:saved_usage_profile, usage_profile) do
              capture_io { assert_equal 1, ClaudeEasy.cli(arguments.dup) }
            end
            assert_empty error
            assert_equal "validation_timeout", JSON.parse(output).fetch("code")
            assert_equal current.b, File.binread(friend)
          end
        end
        ClaudeEasy.stub(:validate_with_mihomo, true) do
          output, error = ClaudeEasy.stub(:saved_usage_profile, 3) do
            capture_io { assert_equal 1, ClaudeEasy.cli(arguments.dup) }
          end
          assert_empty error
          assert_equal "validation_failed", JSON.parse(output).fetch("code")
          assert_equal current.b, File.binread(friend)

          output, error = ClaudeEasy.stub(:saved_usage_profile, 2) do
            capture_io { assert_equal 0, ClaudeEasy.cli(arguments.dup) }
          end
          assert_empty error
          assert_equal "updated", JSON.parse(output).fetch("code")
          assert_equal restored.b, File.binread(friend)
        end
      end
    end
  end

  def test_cli_restore_backup_rolls_back_if_the_user_enters_the_target_during_validation
    Dir.mktmpdir do |directory|
      friend = File.join(directory, "friend.yaml")
      other = File.join(directory, "other.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(ClaudeEasy.patch(
        base_config.merge("subscription-marker" => "restored"), @policy, usage_profile: 2
      ).fetch(:config))
      File.binwrite(friend, current)
      File.binwrite(other, YAML.dump(base_config.merge("subscription-marker" => "other")))
      backup = ClaudeEasy.create_versioned_backup(
        friend, backup_root, content: restored, reason: "prewrite"
      )
      selected = "other"
      validator = lambda do |_path|
        selected = "friend"
        true
      end
      output = nil

      ClaudeEasy.stub(:selected_profile_name, -> { selected }) do
        ClaudeEasy.stub(:validate_with_mihomo, validator) do
          output, error = ClaudeEasy.stub(:saved_usage_profile, 2) do
            capture_io do
              assert_equal 1, ClaudeEasy.cli([
                "--json", "--profile-dir", directory,
                "--backup-dir", backup_root,
                "--restore-backup", File.basename(backup),
                "--expected-current-sha256", Digest::SHA256.hexdigest(current.b)
              ])
            end
          end
          assert_empty error
        end
      end

      assert_equal current.b, File.binread(friend)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
      result = JSON.parse(output)
      assert_equal "rolled_back", result.fetch("status")
      assert_equal "restore_runtime_check_failed", result.fetch("code")
    end
  end

  def test_cli_restore_backup_preserves_a_concurrent_refresh_after_context_changes
    Dir.mktmpdir do |directory|
      friend = File.join(directory, "friend.yaml")
      other = File.join(directory, "other.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(ClaudeEasy.patch(
        base_config.merge("subscription-marker" => "restored"), @policy, usage_profile: 2
      ).fetch(:config))
      refreshed = YAML.dump(base_config.merge("subscription-marker" => "external-refresh"))
      File.binwrite(friend, current)
      File.binwrite(other, YAML.dump(base_config.merge("subscription-marker" => "other")))
      backup = ClaudeEasy.create_versioned_backup(
        friend, backup_root, content: restored, reason: "prewrite"
      )
      context_check = lambda do |*_arguments, **_keywords|
        File.binwrite(friend, refreshed)
        false
      end
      output = nil

      ClaudeEasy.stub(:selected_profile_name, "other") do
        ClaudeEasy.stub(:validate_with_mihomo, true) do
          ClaudeEasy.stub(:runtime_profile_context_current?, context_check) do
            output, error = ClaudeEasy.stub(:saved_usage_profile, 2) do
              capture_io do
                assert_equal 1, ClaudeEasy.cli([
                  "--json", "--profile-dir", directory,
                  "--backup-dir", backup_root,
                  "--restore-backup", File.basename(backup),
                  "--expected-current-sha256", Digest::SHA256.hexdigest(current.b)
                ])
              end
            end
            assert_empty error
          end
        end
      end

      assert_equal refreshed.b, File.binread(friend)
      assert File.file?(ClaudeEasy.profile_transaction_path(backup_root))
      result = JSON.parse(output)
      assert_equal "partial", result.fetch("status")
      assert_equal "restore_rollback_conflict", result.fetch("code")
    end
  end

  def test_cli_restore_backup_reports_when_the_previous_runtime_cannot_be_reloaded
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      restore_result = {
        status: :updated, path: profile, rollback_bytes: "current",
        patched_digest: Digest::SHA256.hexdigest("restored")
      }
      activation_result = restore_result.merge(status: :reload_failed_restore_pending)

      restore = lambda do |*_arguments, **keywords|
        keywords.fetch(:activation).call(restore_result)
      end
      ClaudeEasy.stub(:saved_usage_profile, 3) do
        ClaudeEasy.stub(:restore_backup, restore) do
          ClaudeEasy.stub(:selected_profile_name, "friend") do
            ClaudeEasy.stub(:active_profile_root, directory) do
              ClaudeEasy.stub(:activate_updated_profile, activation_result) do
                output, error = capture_io do
                  assert_equal 1, ClaudeEasy.cli([
                    "--json", "--profile-dir", directory, "--restore-backup", "backup-id",
                    "--expected-current-sha256", "0" * 64
                  ])
                end
                assert_empty error
                result = JSON.parse(output)
                assert_equal "partial", result.fetch("status")
                assert_equal "restore_runtime_pending", result.fetch("code")
                assert_includes result.fetch("summary_zh"), "保留外部改动"
              end
            end
          end
        end
      end
    end
  end

  def test_cli_restore_backup_does_not_reload_the_old_profile_after_a_user_switch
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(base_config.merge("subscription-marker" => "restored"))
      File.binwrite(profile, restored)
      stat = File.stat(profile)
      selected = "friend"
      put_paths = []
      controller = lambda do |_socket, method, endpoint, body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"]
          put_paths << JSON.parse(body).fetch("path")
          [204, ""]
        else
          [204, ""]
        end
      end
      restore_result = {
        status: :updated, path: profile, rollback_bytes: current.b,
        patched_digest: Digest::SHA256.hexdigest(restored.b),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      restore = lambda do |*_arguments, **keywords|
        selected = "other"
        keywords.fetch(:activation).call(restore_result)
      end

      output = nil
      ClaudeEasy.stub(:saved_usage_profile, 3) do
        ClaudeEasy.stub(:restore_backup, restore) do
          ClaudeEasy.stub(:selected_profile_name, -> { selected }) do
            ClaudeEasy.stub(:controller_socket, "socket") do
              ClaudeEasy.stub(:controller_request, controller) do
                output, error = capture_io do
                  assert_equal 1, ClaudeEasy.cli([
                    "--json", "--profile-dir", directory, "--restore-backup", "backup-id",
                    "--expected-current-sha256", "0" * 64
                  ])
                end
                assert_empty error
              end
            end
          end
        end
      end

      assert_empty put_paths, "backup restore forced the profile the user had left"
      assert_equal current.b, File.binread(profile)
      result = JSON.parse(output)
      assert_equal "rolled_back", result.fetch("status")
      assert_equal "restore_runtime_check_failed", result.fetch("code")
    end
  end

  def test_cli_restore_backup_checks_the_active_runtime_when_the_file_already_matches
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      restore_result = {
        status: :no_change, path: profile, rollback_bytes: "restored",
        patched_digest: Digest::SHA256.hexdigest("restored")
      }
      activated = false
      activation = lambda do |result, require_tun:, **_keywords|
        activated = true
        assert_equal :preserve, require_tun
        result.merge(reloaded: true)
      end

      restore = lambda do |*_arguments, **keywords|
        keywords.fetch(:activation).call(restore_result)
      end
      ClaudeEasy.stub(:saved_usage_profile, 3) do
        ClaudeEasy.stub(:restore_backup, restore) do
          ClaudeEasy.stub(:selected_profile_name, "friend") do
            ClaudeEasy.stub(:active_profile_root, directory) do
              ClaudeEasy.stub(:activate_updated_profile, activation) do
                output, error = capture_io do
                  assert_equal 0, ClaudeEasy.cli([
                    "--json", "--profile-dir", directory, "--restore-backup", "backup-id",
                    "--expected-current-sha256", "0" * 64
                  ])
                end
                assert_empty error
                result = JSON.parse(output)
                assert_equal "no_change", result.fetch("status")
                assert_includes result.fetch("summary_zh"), "运行检查"
              end
            end
          end
        end
      end

      assert activated
    end
  end

  def test_cli_subscription_update_calls_the_update_transaction
    Dir.mktmpdir do |directory|
      targets = [{ name: "friend", path: File.join(directory, "friend.yaml") }]
      called = false
      update_arguments = nil
      update = lambda do |**arguments|
        called = true
        update_arguments = arguments
        arguments.fetch(:auto_update_disabler).call(:operation_lock)
        { status: :updated, count: 1, profiles: ["friend"] }
      end
      disabled_with = nil
      disabler = lambda do |backup_root:, operation_lock:|
        disabled_with = [backup_root, operation_lock]
        { status: :already_disabled }
      end
      ClaudeEasy.stub(:disable_subscription_auto_update, disabler) do
        ClaudeEasy.stub(:saved_usage_profile, 3) do
          ClaudeEasy.stub(:remote_subscription_targets, targets) do
            ClaudeEasy.stub(:safe_update_all, update) do
              output, error = capture_io do
                assert_equal 0, ClaudeEasy.cli([
                  "--json", "--profile-dir", directory, "--backup-dir", directory,
                  "--safe-update-all", "--usage-profile", "3"
                ])
              end
              assert_empty error
              assert_equal "safe_update_completed", JSON.parse(output).fetch("code")
            end
          end
        end
      end
      assert called
      assert_kind_of Proc, update_arguments.fetch(:auto_update_disabler)
      assert_equal [directory, :operation_lock], disabled_with
    end
  end

  def test_cli_subscription_update_reports_profile_rejection_success_and_failure
    Dir.mktmpdir do |directory|
      targets = [{ name: "friend", path: File.join(directory, "friend.yaml") }]
      arguments = [
        "--profile-dir", directory, "--policy", POLICY_PATH,
        "--safe-update-all", "--usage-profile", "3"
      ]

      output, error = ClaudeEasy.stub(:saved_usage_profile, nil) do
        capture_io { assert_equal 10, ClaudeEasy.cli(arguments.dup) }
      end
      assert_empty output
      assert_includes error, "尚未保存用途档位"

      ClaudeEasy.stub(:saved_usage_profile, 3) do
        ClaudeEasy.stub(:remote_subscription_targets, targets) do
          ClaudeEasy.stub(:safe_update_all, { status: :updated, count: 1, profiles: ["friend"] }) do
            output, error = capture_io { assert_equal 0, ClaudeEasy.cli(arguments.dup) }
            assert_empty error
            assert_includes output, "全部远程订阅已更新：1 份"
            assert_includes output, "已更新：friend"
          end

          ClaudeEasy.stub(:safe_update_all, { status: :rollback_failed }) do
            output, error = capture_io { assert_equal 1, ClaudeEasy.cli(["--json", *arguments]) }
            assert_empty error
            result = JSON.parse(output)
            assert_equal "partial", result.fetch("status")
            assert_equal "rollback_failed", result.fetch("code")
          end

          ClaudeEasy.stub(:safe_update_all, { status: :runtime_restore_pending, reason: :activation_failed }) do
            output, error = capture_io { assert_equal 1, ClaudeEasy.cli(["--json", *arguments]) }
            assert_empty error
            result = JSON.parse(output)
            assert_equal "partial", result.fetch("status")
            assert_equal "safe_update_runtime_pending", result.fetch("code")
            assert_includes result.fetch("summary_zh"), "恢复原内容或保留外部改动"
          end

          ClaudeEasy.stub(:safe_update_all, { status: :aborted, reason: :rollback_superseded }) do
            output, error = capture_io { assert_equal 1, ClaudeEasy.cli(["--json", *arguments]) }
            assert_empty error
            result = JSON.parse(output)
            assert_equal "partial", result.fetch("status")
            assert_equal "safe_update_rollback_superseded", result.fetch("code")
          end

          ClaudeEasy.stub(:safe_update_all, { status: :aborted }) do
            output, error = capture_io { assert_equal 1, ClaudeEasy.cli(arguments.dup) }
            assert_empty output
            assert_includes error, "订阅更新失败"
          end

          ClaudeEasy.stub(:safe_update_all, { status: :invalid }) do
            output, error = capture_io { assert_equal 1, ClaudeEasy.cli(["--json", *arguments]) }
            assert_empty error
            assert_equal "safe_update_failed", JSON.parse(output).fetch("code")
          end
        end
      end
    end
  end

  def test_json_item_and_batch_statuses_cover_success_failure_and_rollback
    assert_equal "updated", ClaudeEasy.result_item(path: "/private/a.yaml", status: :updated).fetch("status")
    assert_equal "unchanged", ClaudeEasy.result_item(path: "/private/a.yaml", status: :unchanged).fetch("status")
    assert_equal "rolled_back", ClaudeEasy.result_item(path: "/private/a.yaml", status: :reload_failed_rolled_back).fetch("status")
    assert_equal "skipped", ClaudeEasy.result_item(path: "/private/a.yaml", status: :invalid).fetch("status")
    assert_equal "failed", ClaudeEasy.result_item(path: "/private/a.yaml", status: :unknown).fetch("status")

    assert_equal "no_change", ClaudeEasy.batch_json_status([{ status: :unchanged }]).first
    assert_equal "ok", ClaudeEasy.batch_json_status([{ status: :updated }]).first
    assert_equal "partial", ClaudeEasy.batch_json_status([{ status: :updated }, { status: :invalid }]).first
    assert_equal "failed", ClaudeEasy.batch_json_status([{ status: :invalid }]).first
  end

  def test_wrapper_commit_receipt_is_preallocated_validated_and_marked
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      FileUtils.mkdir_p(backup_root)
      nonce = "a" * 32
      path = File.join(backup_root, ".profile-operation-receipt.test")
      pending = ClaudeEasy.wrapper_commit_receipt_bytes(nonce, false)
      committed = ClaudeEasy.wrapper_commit_receipt_bytes(nonce, true)
      File.binwrite(path, pending)
      File.chmod(0o600, path)
      options = {
        backup_root: backup_root,
        wrapper_commit_receipt: path,
        wrapper_commit_nonce: nonce
      }

      assert_nil ClaudeEasy.validate_wrapper_commit_receipt(options)
      ClaudeEasy.mark_wrapper_commit_receipt(options)
      assert_equal committed, File.binread(path)
      assert_nil ClaudeEasy.validate_wrapper_commit_receipt(
        backup_root: backup_root,
        wrapper_commit_receipt: nil,
        wrapper_commit_nonce: nil
      )

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.validate_wrapper_commit_receipt(
          backup_root: backup_root,
          wrapper_commit_receipt: path,
          wrapper_commit_nonce: nil
        )
      end
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.validate_wrapper_commit_receipt(
          backup_root: backup_root,
          wrapper_commit_receipt: path,
          wrapper_commit_nonce: "invalid"
        )
      end

      outside = File.join(directory, "outside")
      File.binwrite(outside, pending)
      File.chmod(0o600, outside)
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.validate_wrapper_commit_receipt(
          backup_root: backup_root,
          wrapper_commit_receipt: outside,
          wrapper_commit_nonce: nonce
        )
      end

      File.binwrite(path, pending)
      File.chmod(0o644, path)
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.validate_wrapper_commit_receipt(options)
      end
      File.chmod(0o600, path)

      other = File.join(backup_root, ".profile-operation-receipt.other")
      File.binwrite(other, pending)
      File.chmod(0o600, other)
      File.stub(:lstat, File.lstat(other)) do
        assert_raises(ClaudeEasy::InvalidConfigError) do
          ClaudeEasy.validate_wrapper_commit_receipt(options)
        end
      end

      reads = [pending, pending]
      fake = Object.new
      fake.define_singleton_method(:stat) { File.stat(path) }
      fake.define_singleton_method(:read) { reads.shift }
      fake.define_singleton_method(:rewind) { 0 }
      fake.define_singleton_method(:write) { |value| value.bytesize }
      fake.define_singleton_method(:flush) { nil }
      fake.define_singleton_method(:fsync) { 0 }
      File.stub(:open, ->(*_arguments, &block) { block.call(fake) }) do
        assert_raises(ClaudeEasy::WrapperCommitReceiptError) do
          ClaudeEasy.mark_wrapper_commit_receipt(options)
        end
      end
    end
  end

  def test_cli_marks_wrapper_receipt_before_success_result_output
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profiles = File.join(directory, "profiles")
      FileUtils.mkdir_p(backup_root)
      FileUtils.mkdir_p(profiles)
      nonce = "b" * 32
      path = File.join(backup_root, ".profile-operation-receipt.test")
      pending = ClaudeEasy.wrapper_commit_receipt_bytes(nonce, false)
      committed = ClaudeEasy.wrapper_commit_receipt_bytes(nonce, true)
      arguments = [
        "--profile-dir", profiles,
        "--backup-dir", backup_root,
        "--usage-profile", "3",
        "--wrapper-commit-receipt", path,
        "--wrapper-commit-nonce", nonce,
        "--json"
      ]
      failing_output = Object.new
      failing_output.define_singleton_method(:write) do |_value|
        raise Errno::ENOSPC, "injected output failure"
      end

      File.binwrite(path, pending)
      File.chmod(0o600, path)
      results = [{ path: File.join(profiles, "a.yaml"), status: :updated }]
      ClaudeEasy.stub(:saved_usage_profile, 3) do
        ClaudeEasy.stub(:run, results) do
          original = $stdout
          $stdout = failing_output
          begin
            assert_raises(Errno::ENOSPC) { ClaudeEasy.cli(arguments.dup) }
          ensure
            $stdout = original
          end
        end
      end
      assert_equal committed, File.binread(path)
    end
  end

  def test_cli_reports_commit_receipt_publication_failure_with_internal_exit
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profiles = File.join(directory, "profiles")
      FileUtils.mkdir_p(backup_root)
      FileUtils.mkdir_p(profiles)
      nonce = "c" * 32
      path = File.join(backup_root, ".profile-operation-receipt.test")
      File.binwrite(path, ClaudeEasy.wrapper_commit_receipt_bytes(nonce, false))
      File.chmod(0o600, path)
      arguments = [
        "--profile-dir", profiles,
        "--backup-dir", backup_root,
        "--usage-profile", "3",
        "--wrapper-commit-receipt", path,
        "--wrapper-commit-nonce", nonce,
        "--json"
      ]
      results = [{ path: File.join(profiles, "a.yaml"), status: :updated }]
      failing_publication = lambda do |_options|
        raise ClaudeEasy::WrapperCommitReceiptError, "injected receipt publication failure"
      end

      output = StringIO.new
      original = $stdout
      $stdout = output
      begin
        exit_code = ClaudeEasy.stub(:saved_usage_profile, 3) do
          ClaudeEasy.stub(:run, results) do
            ClaudeEasy.stub(:mark_wrapper_commit_receipt, failing_publication) do
              ClaudeEasy.cli(arguments.dup)
            end
          end
        end
      ensure
        $stdout = original
      end

      assert_equal ClaudeEasy::WRAPPER_COMMIT_RECEIPT_FAILURE_EXIT, exit_code
      result = JSON.parse(output.string)
      assert_equal "wrapper_commit_receipt_failed", result.fetch("code")
      assert_equal exit_code, result.fetch("exit_code")

      text_output = StringIO.new
      text_arguments = arguments.reject { |argument| argument == "--json" }
      original = $stderr
      $stderr = text_output
      begin
        exit_code = ClaudeEasy.stub(:saved_usage_profile, 3) do
          ClaudeEasy.stub(:run, results) do
            ClaudeEasy.stub(:mark_wrapper_commit_receipt, failing_publication) do
              ClaudeEasy.cli(text_arguments.dup)
            end
          end
        end
      ensure
        $stderr = original
      end
      assert_equal ClaudeEasy::WRAPPER_COMMIT_RECEIPT_FAILURE_EXIT, exit_code
      assert_includes text_output.string, "提交收据写入失败"

      failing_output = Object.new
      failing_output.define_singleton_method(:write) do |_value|
        raise Errno::ENOSPC, "injected result write failure"
      end
      original = $stdout
      $stdout = failing_output
      begin
        exit_code = ClaudeEasy.stub(:saved_usage_profile, 3) do
          ClaudeEasy.stub(:run, results) do
            ClaudeEasy.stub(:mark_wrapper_commit_receipt, failing_publication) do
              ClaudeEasy.cli(arguments.dup)
            end
          end
        end
      ensure
        $stdout = original
      end
      assert_equal ClaudeEasy::WRAPPER_COMMIT_RECEIPT_FAILURE_EXIT, exit_code
    end
  end

  def test_cli_reports_uncertain_profile_commit_with_recovery_exit
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profiles = File.join(directory, "profiles")
      FileUtils.mkdir_p(backup_root)
      FileUtils.mkdir_p(profiles)
      nonce = "d" * 32
      receipt = File.join(backup_root, ".profile-operation-receipt.test")
      File.binwrite(receipt, ClaudeEasy.wrapper_commit_receipt_bytes(nonce, false))
      File.chmod(0o600, receipt)
      arguments = [
        "--json", "--profile-dir", profiles, "--backup-dir", backup_root,
        "--usage-profile", "3", "--wrapper-commit-receipt", receipt,
        "--wrapper-commit-nonce", nonce
      ]
      text_arguments = arguments.reject { |argument| argument == "--json" }
      uncertain = lambda do |**_arguments|
        raise ClaudeEasy::ProfileCommitStateUncertainError, "injected uncertain commit"
      end

      output = StringIO.new
      original = $stdout
      $stdout = output
      begin
        exit_code = ClaudeEasy.stub(:saved_usage_profile, 3) do
          ClaudeEasy.stub(:run, uncertain) { ClaudeEasy.cli(arguments) }
        end
      ensure
        $stdout = original
      end

      assert_equal ClaudeEasy::PROFILE_COMMIT_STATE_UNCERTAIN_EXIT, exit_code
      result = JSON.parse(output.string)
      assert_equal "partial", result.fetch("status")
      assert_equal "profile_commit_state_uncertain", result.fetch("code")
      assert_equal exit_code, result.fetch("exit_code")
      assert_equal ClaudeEasy.wrapper_commit_receipt_bytes(nonce, false), File.binread(receipt)

      _output, error = capture_io do
        exit_code = ClaudeEasy.stub(:saved_usage_profile, 3) do
          ClaudeEasy.stub(:run, uncertain) { ClaudeEasy.cli(text_arguments) }
        end
        assert_equal ClaudeEasy::PROFILE_COMMIT_STATE_UNCERTAIN_EXIT, exit_code
      end
      assert_includes error, "提交状态无法确认"

    end
  end

  def test_cli_labels_an_uncertain_safe_update_as_safe_update
    Dir.mktmpdir do |directory|
      profiles = File.join(directory, "profiles")
      backup_root = File.join(directory, "backups")
      FileUtils.mkdir_p([profiles, backup_root])
      uncertain = lambda do |**_arguments|
        raise ClaudeEasy::ProfileCommitStateUncertainError, "injected uncertain commit"
      end
      output = StringIO.new
      original = $stdout
      $stdout = output
      begin
        exit_code = ClaudeEasy.stub(:saved_usage_profile, 3) do
          ClaudeEasy.stub(:remote_subscription_targets, []) do
            ClaudeEasy.stub(:safe_update_all, uncertain) do
              ClaudeEasy.cli([
                "--json", "--safe-update-all", "--profile-dir", profiles,
                "--backup-dir", backup_root, "--usage-profile", "3"
              ])
            end
          end
        end
      ensure
        $stdout = original
      end

      assert_equal ClaudeEasy::PROFILE_COMMIT_STATE_UNCERTAIN_EXIT, exit_code
      assert_equal "safe_update", JSON.parse(output.string).fetch("operation")
    end
  end

  def test_cli_returns_failure_when_any_profile_was_not_applied
    results = [
      { path: "/private/current.yaml", status: :reload_failed_rolled_back },
      { path: "/private/other.yaml", status: :unchanged }
    ]
    ClaudeEasy.stub(:saved_usage_profile, 3) do
      ClaudeEasy.stub(:run, results) do
        output, error = capture_io do
          assert_equal 1, ClaudeEasy.cli(["--json", "--profile-dir", "/private", "--usage-profile", "3"])
        end
        assert_empty error
        result = JSON.parse(output)
        assert_equal "partial", result.fetch("status")
        assert_equal 1, result.fetch("exit_code")
      end

      ClaudeEasy.stub(:run, results) do
        _output, _error = capture_io do
          assert_equal 1, ClaudeEasy.cli(["--profile-dir", "/private", "--usage-profile", "3"])
        end
      end
    end
  end

  def test_normal_batch_aborts_before_writing_when_a_later_profile_fails
    Dir.mktmpdir do |directory|
      first = File.join(directory, "a-valid.yaml")
      second = File.join(directory, "z-invalid.yaml")
      original = YAML.dump(base_config)
      File.write(first, original)
      File.write(second, "not: [valid")

      results = ClaudeEasy.run(
        directory: directory, policy_path: POLICY_PATH,
        backup_root: File.join(directory, "backups"),
        validator: ->(_path) { true }, auto_reload: false, usage_profile: 3,
        selected_name: "a-valid"
      )

      assert results.any? { |result| result[:status] == :invalid }
      assert_equal original, File.read(first)
      assert results.any? { |result| result[:status] == :batch_aborted }
    end
  end

  def test_normal_batch_restores_an_earlier_real_write_when_a_later_commit_fails
    Dir.mktmpdir do |directory|
      first = File.join(directory, "a-first.yaml")
      second = File.join(directory, "z-second.yaml")
      File.write(first, YAML.dump(base_config.merge("subscription-marker" => "first-original")))
      File.write(second, YAML.dump(base_config.merge("subscription-marker" => "second-original")))
      originals = [first, second].to_h { |path| [path, File.binread(path)] }
      original_write = ClaudeEasy.method(:transactional_replace_locked)
      writes = 0
      fail_second_commit = lambda do |*arguments|
        writes += 1
        raise IOError, "injected second profile commit failure" if writes == 2

        original_write.call(*arguments)
      end

      results = ClaudeEasy.stub(:transactional_replace_locked, fail_second_commit) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"),
          validator: ->(_path) { true }, auto_reload: false, usage_profile: 3,
          selected_name: "a-first"
        )
      end

      assert_equal :batch_rolled_back, results.fetch(0).fetch(:status)
      assert_equal :io_error, results.fetch(1).fetch(:status)
      assert_operator writes, :>=, 3
      originals.each { |path, original| assert_equal original, File.binread(path), path }
    end
  end

  CLI_UNKNOWN_OPTION_CASES = [
    { argv: ["--unknown-option"], needs_dir: false, error_fragment: "参数错误" },
    { argv: ["--safe-update-all"], needs_dir: true, error_fragment: "必须指定用途档位" }
  ]

  def test_cli_rejects_unknown_options_and_subscription_update_needs_a_usage_profile
    CLI_UNKNOWN_OPTION_CASES.each do |row|
      if row.fetch(:needs_dir)
        Dir.mktmpdir do |directory|
          output, error = capture_io { assert_equal 64, ClaudeEasy.cli(row.fetch(:argv) + ["--profile-dir", directory]) }
          assert_empty output
          assert_includes error, row.fetch(:error_fragment)
        end
      else
        _output, error = capture_io { assert_equal 64, ClaudeEasy.cli(row.fetch(:argv)) }
        assert_includes error, row.fetch(:error_fragment)
      end
    end
  end

  def test_cli_dry_run_reports_each_profile_without_calling_the_mihomo_validator
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      output, error = ClaudeEasy.stub(:saved_usage_profile, 1) do
        capture_io do
          assert_equal 0, ClaudeEasy.cli([
            "--profile-dir", directory, "--policy", POLICY_PATH,
            "--usage-profile", "1", "--dry-run"
          ])
        end
      end
      assert_includes output, "friend.yaml"
      assert_empty error
    end
  end

  def test_cli_rejects_safety_modifiers_that_an_explicit_operation_would_ignore
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      operations = [
        ["--snapshot-initial"], ["--restore-backup", "backup-id"],
        ["--safe-update-all"], ["--recover-profile-transaction"]
      ]

      %w[--dry-run --no-reload].each do |modifier|
        operations.each do |operation|
          arguments = ["--json", "--profile-dir", directory, modifier, *operation]
          output, error = capture_io { assert_equal 64, ClaudeEasy.cli(arguments) }
          assert_empty error
          assert_equal "incompatible_options", JSON.parse(output).fetch("code")
          assert_equal original.b, File.binread(profile)
        end
      end

      output, error = capture_io do
        assert_equal 64, ClaudeEasy.cli([
          "--json", "--profile-dir", directory,
          "--restore-backup", "backup-id", "--safe-update-all"
        ])
      end
      assert_empty error
      assert_equal "incompatible_options", JSON.parse(output).fetch("code")
      assert_equal original.b, File.binread(profile)

      output, error = capture_io do
        assert_equal 64, ClaudeEasy.cli([
          "--profile-dir", directory, "--dry-run", "--restore-backup", "backup-id"
        ])
      end
      assert_empty output
      assert_includes error, "命令选项不能组合"
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_cli_backup_commands_delegate_without_exposing_backup_contents
    Dir.mktmpdir do |directory|
      backup_item = { "id" => "backup-id", "created_at" => "2026-08-04T12:34:56.123456789+08:00" }
      ClaudeEasy.stub(:list_backups, [backup_item]) do
        output, = capture_io { assert_equal 0, ClaudeEasy.cli(["--profile-dir", directory, "--list-backups"]) }
        assert_includes output, "backup-id"
        assert_includes output, backup_item.fetch("created_at")
        assert_includes output, "已读取可用备份"
      end
      ClaudeEasy.stub(:list_backups, []) do
        output, error = capture_io do
          assert_equal 0, ClaudeEasy.cli(["--profile-dir", directory, "--list-backups"])
        end
        assert_includes output, "没有可用备份"
        assert_empty error
      end
      ClaudeEasy.stub(:compare_backup, { status: :changed }) do
        output, = capture_io do
          assert_equal 0, ClaudeEasy.cli(["--profile-dir", directory, "--compare-backup", "backup-id"])
        end
        assert_includes output, "changed"
        assert_includes output, "备份比较完成"
      end
    end
  end

  def test_route_verifier_json_and_profile_discovery_fail_closed
    ClaudeEasy.stub(:controller_request, [503, "unavailable"]) do
      assert_nil ClashRouteVerifier.get_json("socket", "/proxies")
    end
    ClaudeEasy.stub(:controller_request, [200, "not json"]) do
      assert_nil ClashRouteVerifier.get_json("socket", "/proxies")
    end
    ClaudeEasy.stub(:selected_profile_name, "friend") do
      ClaudeEasy.stub(:default_profile_directories, ["one", "two"]) do
        ClaudeEasy.stub(:profile_paths, ->(directory) { directory == "two" ? ["/tmp/friend.yaml"] : [] }) do
          ClaudeEasy.stub(:active_profile?, ->(path, selected) { path == "/tmp/friend.yaml" && selected == "friend" }) do
            assert_equal "/tmp/friend.yaml", ClashRouteVerifier.active_profile
          end
        end
      end
    end
    ClaudeEasy.stub(:selected_profile_name, "missing") do
      ClaudeEasy.stub(:default_profile_directories, ["one", "two"]) do
        ClaudeEasy.stub(:profile_paths, []) do
          assert_nil ClashRouteVerifier.active_profile
        end
      end
    end
  end

  def test_route_verifier_reserves_and_releases_a_local_source_port
    port = ClashRouteVerifier.reserve_local_port
    assert_operator port, :>, 0
    listener = TCPServer.new("127.0.0.1", port)
    listener.close
  end

  def test_runtime_helpers_fail_closed_on_controller_and_filesystem_errors
    assert_nil ClaudeEasy.runtime_loopback_proxy(->(*_arguments) { raise IOError, "gone" })

    assert_includes [true, false], ClaudeEasy.mihomo_home_case_insensitive?
    File.stub(:exist?, false) do
      refute ClaudeEasy.mihomo_home_case_insensitive?
    end
    File.stub(:realpath, ->(_path) { raise Errno::EIO }) do
      refute ClaudeEasy.mihomo_home_case_insensitive?
    end
  end

  def test_route_verifier_resolves_the_runtime_proxy_before_spawning_curl
    resolved = false
    resolver = lambda do |requester|
      resolved = requester.call("GET", "/configs", nil) == [200, "{}"]
      nil
    end
    ClaudeEasy.stub(:controller_request, [200, "{}"]) do
      ClaudeEasy.stub(:runtime_loopback_proxy, resolver) do
        assert_nil ClashRouteVerifier.observe_connection(
          "socket", "https://www.google.com", /google/i
        )
      end
    end
    assert resolved
  end

  def test_route_verifier_observes_a_new_matching_connection_and_reaps_curl
    calls = 0
    connections = [
      { "connections" => [{ "id" => "old", "metadata" => { "host" => "www.google.com" } }] },
      {
        "connections" => [
          { "id" => "old" },
          {
            "id" => "new",
            "metadata" => { "host" => "www.google.com", "network" => "tcp", "sourcePort" => 45_555 },
            "chains" => ["Main"]
          }
        ]
      }
    ]

    ClashRouteVerifier.stub(:get_json, ->(*_args) { entry = connections[calls]; calls += 1; entry || { "connections" => [] } }) do
      ClashRouteVerifier.stub(:reserve_local_port, 45_555) do
        Process.stub(:spawn, 42) do
          Process.stub(:kill, true) do
            Process.stub(:wait, true) do
              observed = ClashRouteVerifier.observe_connection(
                "socket", "https://www.google.com", /google/i,
                proxy_url: "http://127.0.0.1:7890"
              )
              assert_equal "new", observed.fetch("id")
            end
          end
        end
      end
    end
  end

  def test_route_verifier_ignores_same_host_traffic_from_another_source_port
    calls = 0
    spawn_arguments = nil
    controller = lambda do |*_args|
      calls += 1
      next({ "connections" => [] }) if calls == 1

      local_port_index = spawn_arguments&.index("--local-port")
      curl_port = local_port_index ? spawn_arguments.fetch(local_port_index + 1).to_i : 45_555
      {
        "connections" => [
          {
            "id" => "background", "metadata" => {
              "host" => "www.google.com", "network" => "tcp", "sourcePort" => curl_port + 1
            }
          },
          {
            "id" => "curl", "metadata" => {
              "host" => "www.google.com", "network" => "tcp", "sourcePort" => curl_port
            }
          }
        ]
      }
    end

    ClashRouteVerifier.stub(:get_json, controller) do
      Process.stub(:spawn, ->(*arguments) { spawn_arguments = arguments; 42 }) do
        Process.stub(:kill, true) do
          Process.stub(:wait, true) do
            observed = ClashRouteVerifier.observe_connection(
              "socket", "https://www.google.com", /google/i,
              proxy_url: "http://127.0.0.1:7890"
            )
            assert_equal "curl", observed.fetch("id")
            environment = spawn_arguments.fetch(0)
            arguments = spawn_arguments.drop(1)
            assert_equal ClaudeEasy::CURL_ISOLATED_ENVIRONMENT, environment
            assert_equal ["/usr/bin/curl", "-q"], arguments.first(2)
            proxy_index = arguments.index("--proxy")
            refute_nil proxy_index
            assert_equal "http://127.0.0.1:7890", arguments.fetch(proxy_index + 1)
          end
        end
      end
    end
  end

  def test_route_verifier_ignores_missing_curl_process_during_cleanup
    responses = [
      { "connections" => [] },
      {
        "connections" => [{
          "id" => "new",
          "metadata" => { "host" => "www.google.com", "network" => "tcp", "sourcePort" => 45_555 }
        }]
      }
    ]
    ClashRouteVerifier.stub(:get_json, ->(*_args) { responses.shift || { "connections" => [] } }) do
      ClashRouteVerifier.stub(:reserve_local_port, 45_555) do
        Process.stub(:spawn, 42) do
          Process.stub(:kill, ->(*_args) { raise Errno::ESRCH }) do
            Process.stub(:wait, ->(*_args) { raise Errno::ECHILD }) do
              assert_equal "new", ClashRouteVerifier.observe_connection(
                "socket", "https://www.google.com", /google/i,
                proxy_url: "http://127.0.0.1:7890"
              ).fetch("id")
            end
          end
        end
      end
    end
  end

  def test_route_verifier_returns_nil_when_no_matching_connection_is_observed
    ClashRouteVerifier.stub(:get_json, { "connections" => [] }) do
      ClashRouteVerifier.stub(:reserve_local_port, 45_555) do
        ClashRouteVerifier.stub(:sleep, ->(_seconds) {}) do
          Process.stub(:spawn, 42) do
            Process.stub(:kill, true) do
              Process.stub(:waitpid, ->(*_arguments) { raise Errno::ECHILD }) do
                assert_nil ClashRouteVerifier.observe_connection(
                  "socket", "https://www.google.com", /google/i,
                  proxy_url: "http://127.0.0.1:7890"
                )
              end
            end
          end
        end
      end
    end
  end

  def test_route_verifier_gracefully_reaps_a_finished_curl_process
    signals = []
    waits = [nil, [42, Struct.new(:success?).new(true)]]
    Process.stub(:kill, ->(signal, process_id) { signals << [signal, process_id] }) do
      Process.stub(:waitpid, ->(*_arguments) { waits.shift }) do
        assert_nil ClashRouteVerifier.terminate_process(42, grace_seconds: 1)
      end
    end
    assert_equal [["TERM", 42]], signals
    assert_empty waits
  end

  def test_route_verifier_returns_false_when_live_proxy_loading_raises
    ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
      ClashRouteVerifier.stub(:get_json, ->(*_args) { raise IOError, "controller disappeared" }) do
        refute ClashRouteVerifier.run(output: StringIO.new)
      end
    end
  end

  def test_route_verifier_fails_closed_at_every_discovery_boundary
    ClaudeEasy.stub(:controller_requester, nil) do
      ClashRouteVerifier.stub(:active_profile, "/tmp/friend.yaml") do
        refute ClashRouteVerifier.run(output: StringIO.new)
      end
    end
    ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
      ClashRouteVerifier.stub(:active_profile, nil) do
        refute ClashRouteVerifier.run(output: StringIO.new)
      end
    end

    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClaudeEasy.stub(:detect_main_group, nil) do
            refute ClashRouteVerifier.run(output: StringIO.new)
          end
          ClaudeEasy.stub(:existing_ai_group, nil) do
            refute ClashRouteVerifier.run(output: StringIO.new)
          end
          ClashRouteVerifier.stub(:get_json, { "proxies" => [] }) do
            refute ClashRouteVerifier.run(output: StringIO.new)
          end
          direct_proxies = {
            "proxies" => {
              "Main" => { "now" => "DIRECT" },
              "AI" => { "now" => "Japan" }
            }
          }
          ClashRouteVerifier.stub(:get_json, direct_proxies) do
            refute ClashRouteVerifier.run(output: StringIO.new)
          end
        end
      end
    end
  end

  def test_route_verifier_uses_the_live_match_rule_for_main_group
    proxies = {
      "Disk Main" => { "type" => "Selector", "now" => "Disk Node" },
      "Live Main" => { "type" => "LoadBalance" },
      "Disk Node" => { "type" => "Shadowsocks" },
      "Live Node" => { "type" => "Vmess" }
    }
    rules = {
      "rules" => [
        { "type" => "DomainSuffix", "proxy" => "Disk Main" },
        { "type" => "MATCH", "proxy" => "Live Main" }
      ]
    }
    getter = ->(_socket, endpoint) { endpoint == "/rules" ? rules : nil }

    ClashRouteVerifier.stub(:get_json, getter) do
      assert_equal "Live Main", ClashRouteVerifier.live_main_group("socket", proxies)
    end
  end

  def test_route_verifier_finds_ai_group_from_live_proxies
    policy = { "ai_group_names" => ["AI"] }
    proxies = {
      "AI Balanced" => { "type" => "LoadBalance" },
      "Main" => { "type" => "Selector", "now" => "Taiwan" }
    }

    assert_equal(
      "AI Balanced",
      ClashRouteVerifier.find_group(proxies, policy.fetch("ai_group_names"), nil, ai: true)
    )
  end

  def test_route_verifier_validates_explicit_live_groups
    proxies = {
      "Main Live" => { "type" => "Selector", "now" => "Taiwan" },
      "Not A Group" => { "type" => "Vmess" }
    }

    assert_equal(
      "Main Live",
      ClashRouteVerifier.find_group(proxies, [], "Main Live")
    )
    assert_nil ClashRouteVerifier.find_group(proxies, [], "Missing")
    assert_equal(
      "Main Live",
      ClashRouteVerifier.live_main_group("socket", proxies, "Main Live")
    )
    assert_nil ClashRouteVerifier.live_main_group("socket", proxies, "Not A Group")
  end

  def test_route_verifier_does_not_read_the_disk_to_find_ai_group
    proxies_payload = { "proxies" => {
      "Main" => { "type" => "Selector", "now" => "Taiwan" },
      "AI" => { "type" => "Selector", "now" => "Japan" },
      "Taiwan" => { "type" => "Shadowsocks" },
      "Japan" => { "type" => "Vmess" }
    } }
    responses = {
      "/proxies" => proxies_payload,
      "/rules" => { "rules" => [{ "type" => "MATCH", "proxy" => "Main" }] },
      "/providers/proxies" => { "providers" => {} }
    }
    observations = Array.new(3) { { "chains" => ["Japan", "AI"] } }

    ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
      ClashRouteVerifier.stub(:active_profile, -> { flunk "read the disk for a live group" }) do
        ClashRouteVerifier.stub(:get_json, ->(_socket, endpoint) { responses[endpoint] }) do
          ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
            assert ClashRouteVerifier.run(output: StringIO.new)
          end
        end
      end
    end
  end

  def test_route_verifier_uses_controller_context_once_for_all_polling_requests
    context_calls = 0
    context = { socket: "/tmp/controller.sock", secret: "controller-secret" }
    responses = {
      "/proxies" => { "proxies" => {
        "Main" => { "type" => "Selector", "now" => "Taiwan" },
        "AI" => { "type" => "Selector", "now" => "Japan" },
        "Taiwan" => { "type" => "Shadowsocks" },
        "Japan" => { "type" => "Vmess" }
      } },
      "/rules" => { "rules" => [{ "type" => "MATCH", "proxy" => "Main" }] },
      "/providers/proxies" => { "providers" => {} }
    }
    observations = Array.new(3) { { "chains" => ["Japan", "AI"] } }
    getter = lambda do |requester, endpoint|
      assert_respond_to requester, :call
      responses[endpoint]
    end
    observer = lambda do |requester, *_arguments, **_options|
      assert_respond_to requester, :call
      20.times { requester.call("GET", "/connections", nil) }
      observations.shift
    end

    ClaudeEasy.stub(:controller_context, -> { context_calls += 1; context }) do
      ClaudeEasy.stub(:controller_request_with_secret, [200, "{}"]) do
        ClashRouteVerifier.stub(:get_json, getter) do
          ClashRouteVerifier.stub(:observe_connection, observer) do
            assert ClashRouteVerifier.run(output: StringIO.new)
          end
        end
      end
    end

    assert_equal 1, context_calls
  end

  def test_route_verifier_rejects_a_proxy_snapshot_changed_during_observation
    proxies = { "proxies" => {
      "Main" => { "type" => "Selector", "now" => "Same Leaf" },
      "AI" => { "type" => "Selector", "now" => "Same Leaf" },
      "Same Leaf" => { "type" => "Vmess" }
    } }
    changed = Marshal.load(Marshal.dump(proxies))
    changed["proxies"]["Same Leaf"]["type"] = "Direct"
    proxy_reads = 0
    getter = lambda do |_socket, endpoint|
      proxy_reads += 1 if endpoint == "/proxies"
      next(proxy_reads == 1 ? proxies : changed) if endpoint == "/proxies"
      next({ "rules" => [{ "type" => "MATCH", "proxy" => "Main" }] }) if endpoint == "/rules"
      { "providers" => {} }
    end
    observations = Array.new(3) { { "chains" => ["Same Leaf", "AI"] } }

    ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
      ClashRouteVerifier.stub(:get_json, getter) do
        ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
          refute ClashRouteVerifier.run(output: StringIO.new)
        end
      end
    end
  end

  def test_route_verifier_rejects_every_non_proxy_terminal_as_a_group_selection
    terminals = %w[
      DIRECT DNS REJECT REJECT-DROP PASS PASS-RULE COMPATIBLE REMATCH RELAY
    ]
    proxies = terminals.to_h do |selection|
      [
        selection,
        {
          "type" => "Selector",
          "now" => selection
        }
      ]
    end

    proxies.each_key do |group|
      refute ClashRouteVerifier.usable_route_group_selection?(proxies, group), group
    end
  end

  def test_route_verifier_marks_unobserved_connections_like_windows
    responses = {
      "/proxies" => { "proxies" => {
        "Main" => { "type" => "Selector", "now" => "Taiwan" },
        "AI" => { "type" => "Selector", "now" => "Japan" },
        "Taiwan" => { "type" => "Shadowsocks" },
        "Japan" => { "type" => "Vmess" }
      } },
      "/rules" => { "rules" => [{ "type" => "MATCH", "proxy" => "Main" }] },
      "/providers/proxies" => { "providers" => {} }
    }
    details = { checks: [] }

    ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
      ClashRouteVerifier.stub(:get_json, ->(_socket, endpoint) { responses[endpoint] }) do
        ClashRouteVerifier.stub(:observe_connection, nil) do
          refute ClashRouteVerifier.run(output: StringIO.new, details: details)
        end
      end
    end

    assert_equal(
      %w[not_observed not_observed not_observed],
      details.fetch(:checks).map { |check| check.fetch("status") }
    )
  end

  def test_route_verifier_reports_a_full_healthy_route_check
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      main_group = "Private Main Group"
      ai_group = "Private AI Group"
      main_node = "203.0.113.7:443"
      ai_node = "private-node.example:8443"
      proxies = { "proxies" => {
        main_group => { "type" => "Selector", "now" => main_node },
        ai_group => { "type" => "Selector", "now" => ai_node },
        main_node => { "type" => "Shadowsocks" },
        ai_node => { "type" => "Shadowsocks" }
      } }
      observations = Array.new(3) { { "chains" => [ai_node, ai_group] } }
      ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashRouteVerifier.stub(:get_json, route_controller_getter(proxies, main_group: main_group)) do
            ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
              output = StringIO.new
              assert ClashRouteVerifier.run(output: output)
              assert_includes output.string, "主代理组：已识别；当前选择已隐藏"
              assert_includes output.string, "AI 分组：已识别；当前选择已隐藏"
              assert_includes output.string, "ChatGPT：通过"
              assert_includes output.string, "Gemini：通过"
              assert_includes output.string, "Grok：通过"
              refute_includes output.string, main_node
              refute_includes output.string, ai_node
              refute_includes output.string, main_group
              refute_includes output.string, ai_group
            end
          end
        end
      end
    end
  end

  def test_route_verifier_accepts_load_balance_main_group_without_now
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      config = base_config
      main = config.fetch("proxy-groups").find { |group| group.fetch("name") == "Main" }
      main["type"] = "load-balance"
      main["url"] = "https://example.invalid/generate_204"
      File.write(profile, YAML.dump(config))
      proxies = { "proxies" => {
        "Main" => { "type" => "LoadBalance" },
        "AI" => { "type" => "Selector", "now" => "Japan" },
        "Taiwan" => { "type" => "Shadowsocks" },
        "Japan" => { "type" => "Shadowsocks" }
      } }
      observations = Array.new(3) { { "chains" => ["Japan", "AI"] } }
      ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashRouteVerifier.stub(:get_json, route_controller_getter(proxies)) do
            ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
              assert ClashRouteVerifier.run(output: StringIO.new)
            end
          end
        end
      end
    end
  end

  def test_route_verifier_accepts_load_balance_ai_group_without_now
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      config = base_config
      ai = config.fetch("proxy-groups").find { |group| group.fetch("name") == "AI" }
      ai["type"] = "load-balance"
      ai["url"] = "https://example.invalid/generate_204"
      File.write(profile, YAML.dump(config))
      proxies_payload = { "proxies" => {
        "Main" => { "type" => "Selector", "now" => "Taiwan" },
        "AI" => { "type" => "LoadBalance" },
        "Taiwan" => { "type" => "Shadowsocks" },
        "Japan" => { "type" => "Shadowsocks" }
      } }
      provider_payload = { "providers" => {} }
      rules_payload = { "rules" => [{ "type" => "MATCH", "proxy" => "Main" }] }
      responses = {
        "/proxies" => proxies_payload,
        "/providers/proxies" => provider_payload,
        "/rules" => rules_payload
      }
      observations = Array.new(3) { { "chains" => ["Japan", "AI"] } }
      ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashRouteVerifier.stub(:get_json, ->(_socket, endpoint) { responses[endpoint] }) do
            ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
              assert ClashRouteVerifier.run(output: StringIO.new, ai_group: "AI")
            end
          end
        end
      end
    end
  end

  def test_route_verifier_rejects_an_unrelated_selector_for_google
    proxies = {
      "Main" => { "type" => "Selector", "now" => "Taiwan" },
      "AI" => { "type" => "Selector", "now" => "Japan" },
      "Gaming" => { "type" => "Selector", "now" => "GameNode" },
      "GameNode" => { "type" => "Shadowsocks" },
      "DIRECT" => { "type" => "Direct" },
      "Google" => { "type" => "Selector", "now" => "" }
    }
    refute ClashRouteVerifier.route_passes?(
      ["GameNode", "Gaming"], proxies: proxies, kind: :main,
      expected_group: "Main", expected_selection: "Taiwan", ai_group: "AI"
    )
    refute ClashRouteVerifier.route_passes?(
      ["Google"], proxies: proxies.merge("Google" => { "now" => "" }), kind: :main,
      expected_group: "Main", expected_selection: "Taiwan", ai_group: "AI"
    )
    refute ClashRouteVerifier.route_passes?(
      ["DIRECT", "Google"], proxies: proxies.merge("Google" => { "now" => "DIRECT" }), kind: :main,
      expected_group: "Main", expected_selection: "Taiwan", ai_group: "AI"
    )
  end

  def test_route_verifier_requires_the_main_group_for_google
    refute ClashRouteVerifier.route_passes?(
      ["Singapore", "Google"], proxies: {
        "Main" => { "type" => "Selector", "now" => "Taiwan" },
        "AI" => { "type" => "Selector", "now" => "Japan" },
        "Google" => { "type" => "Selector", "now" => "Singapore" },
        "Singapore" => { "type" => "Shadowsocks" }
      }, kind: :main, expected_group: "Main", expected_selection: "Taiwan", ai_group: "AI"
    )

    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      proxies = { "proxies" => {
        "Main" => { "type" => "Selector", "now" => "Taiwan" },
        "AI" => { "type" => "Selector", "now" => "Japan" },
        "Google" => { "type" => "Selector", "now" => "Singapore" },
        "Singapore" => { "type" => "Shadowsocks" },
        "Japan" => { "type" => "Shadowsocks" }
      } }
      observations = Array.new(3) { { "chains" => ["Japan", "AI"] } }
      ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashRouteVerifier.stub(:get_json, route_controller_getter(proxies)) do
            ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
              assert ClashRouteVerifier.run(output: StringIO.new)
            end
          end
        end
      end
    end
  end

  def test_route_verifier_accepts_the_ai_group_when_it_is_also_the_main_group
    proxies = {
      "AI" => { "type" => "Selector", "now" => "Japan" },
      "Japan" => { "type" => "Vmess" }
    }

    assert ClashRouteVerifier.route_passes?(
      ["Japan", "AI"], proxies: proxies, kind: :main,
      expected_group: "AI", expected_selection: "Japan", ai_group: "AI"
    )
  end

  def test_route_verifier_uses_the_observed_leaf_for_automatic_groups
    proxies = {
      "Auto" => { "type" => "URLTest", "now" => "Node A" },
      "Fallback" => { "type" => "Fallback", "now" => "Node A" },
      "AI" => { "type" => "Selector", "now" => "AI Node" },
      "Node A" => { "type" => "Shadowsocks" },
      "Node B" => { "type" => "Vmess" }
    }

    %w[Auto Fallback].each do |group|
      assert ClashRouteVerifier.route_passes?(
        ["Node B", group], proxies: proxies, providers: {}, provider_chains: [],
        kind: :main, expected_group: group, expected_selection: "Node A", ai_group: "AI"
      )
    end
  end

  def test_route_verifier_rejects_every_custom_non_proxy_outbound_type
    expected_types = %w[Direct Dns Reject RejectDrop Pass PassRule Compatible Rematch Relay]
    assert_equal expected_types, ClashRouteVerifier::NON_PROXY_TYPES
    expected_types.each do |type|
      proxies = {
        "Main" => { "type" => "Selector", "now" => "Local" },
        "AI" => { "type" => "Selector", "now" => "Local" },
        "Local" => { "type" => type }
      }

      refute ClashRouteVerifier.route_passes?(
        ["Local", "Main"], proxies: proxies, providers: {}, provider_chains: [],
        kind: :main, expected_group: "Main", expected_selection: "Local", ai_group: "AI"
      ), "main route accepted #{type}"
      refute ClashRouteVerifier.route_passes?(
        ["Local", "AI"], proxies: proxies, providers: {}, provider_chains: [],
        kind: :ai, expected_group: "AI", expected_selection: "Local", ai_group: "AI"
      ), "AI route accepted #{type}"
    end
  end

  def test_route_verifier_resolves_provider_leaf_types
    proxies = {
      "Balanced" => { "type" => "LoadBalance" },
      "AI" => { "type" => "Selector", "now" => "AI Node" }
    }
    providers = {
      "remote" => {
        "proxies" => [
          { "name" => "Provider Node", "type" => "Shadowsocks" },
          { "name" => "Provider Direct", "type" => "Direct" }
        ]
      }
    }

    assert ClashRouteVerifier.route_passes?(
      ["Provider Node", "Balanced"], proxies: proxies, providers: providers,
      provider_chains: ["remote", ""], kind: :main, expected_group: "Balanced",
      expected_selection: "", ai_group: "AI"
    )
    refute ClashRouteVerifier.route_passes?(
      ["Provider Direct", "Balanced"], proxies: proxies, providers: providers,
      provider_chains: ["remote", ""], kind: :main, expected_group: "Balanced",
      expected_selection: "", ai_group: "AI"
    )
    refute ClashRouteVerifier.route_passes?(
      ["Unknown", "Balanced"], proxies: proxies, providers: providers,
      provider_chains: ["remote", ""], kind: :main, expected_group: "Balanced",
      expected_selection: "", ai_group: "AI"
    )
  end

  def test_route_verifier_runs_the_provider_endpoint_and_provider_chains_end_to_end
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      proxies = {
        "proxies" => {
          "Main" => { "type" => "Selector", "now" => "Provider Main" },
          "AI" => { "type" => "Selector", "now" => "Provider AI" }
        }
      }
      provider_payload = {
        "providers" => {
          "remote" => {
            "proxies" => [
              { "name" => "Provider Main", "type" => "Shadowsocks" },
              { "name" => "Provider AI", "type" => "Vmess" }
            ]
          }
        }
      }
      healthy_observations = Array.new(3) do
        { "chains" => ["Provider AI", "AI"], "providerChains" => ["remote", ""] }
      end
      endpoints = []
      get_json = lambda do |_socket, endpoint|
        endpoints << endpoint
        {
          "/proxies" => proxies,
          "/rules" => { "rules" => [{ "type" => "MATCH", "proxy" => "Main" }] },
          "/providers/proxies" => provider_payload
        }[endpoint]
      end

      ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashRouteVerifier.stub(:get_json, get_json) do
            observations = healthy_observations.map(&:dup)
            ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
              assert ClashRouteVerifier.run(output: StringIO.new)
            end
          end
        end
      end
      %w[/proxies /rules /providers/proxies].each do |endpoint|
        assert_equal 4, endpoints.count(endpoint)
      end

      [
        [nil, healthy_observations, "missing provider endpoint"],
        [provider_payload, healthy_observations.map { |entry| entry.merge("providerChains" => ["missing", ""]) },
         "unknown provider"],
        [{ "providers" => { "remote" => { "proxies" => [] } } }, healthy_observations,
         "missing provider node"]
      ].each do |payload, observations_fixture, label|
        get_json = lambda do |_socket, endpoint|
          {
            "/proxies" => proxies,
            "/rules" => { "rules" => [{ "type" => "MATCH", "proxy" => "Main" }] },
            "/providers/proxies" => payload
          }[endpoint]
        end
        ClaudeEasy.stub(:controller_requester, -> { ->(*_args) { [0, ""] } }) do
          ClashRouteVerifier.stub(:active_profile, profile) do
            ClashRouteVerifier.stub(:get_json, get_json) do
              observations = observations_fixture.map(&:dup)
              ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
                refute ClashRouteVerifier.run(output: StringIO.new), label
              end
            end
          end
        end
      end
    end
  end

  def test_safe_update_rejects_two_paths_to_the_same_inode
    Dir.mktmpdir do |directory|
      first = File.join(directory, "first.yaml")
      second = File.join(directory, "second.yaml")
      File.write(first, YAML.dump(base_config))
      File.link(first, second)

      result = ClaudeEasy.safe_update_all(
        targets: [{ name: "first", path: first }, { name: "second", path: second }],
        backup_root: File.join(directory, "backups"),
        policy: @policy, usage_profile: 3,
        fetcher: ->(_target) { YAML.dump(base_config) },
        validator: ->(_path) { true }, selected_name: "first"
      )

      assert_equal :aborted, result.fetch(:status)
      assert_equal :duplicate_target, result.fetch(:reason)
    end
  end

  def test_cli_rejects_an_empty_profile_directory
    Dir.mktmpdir do |directory|
      output, error = ClaudeEasy.stub(:saved_usage_profile, 1) do
        capture_io do
          assert_equal 1, ClaudeEasy.cli([
            "--json", "--profile-dir", directory, "--policy", POLICY_PATH,
            "--usage-profile", "1", "--no-reload"
          ])
        end
      end
      assert_empty error
      result = JSON.parse(output)
      assert_equal "failed", result.fetch("status")
      assert_equal "no_profiles", result.fetch("code")
    end
  end

  def test_runtime_profile_match_rejects_same_names_with_different_loaded_content
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "candidate.yaml")
      loaded = File.join(directory, "loaded.yaml")
      candidate = base_config
      old = Marshal.load(Marshal.dump(candidate))
      old.fetch("proxies").first["server"] = "old.example"
      File.binwrite(profile, YAML.dump(candidate))
      File.binwrite(loaded, YAML.dump(old))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          proxies = candidate.fetch("proxies").to_h do |proxy|
            [proxy.fetch("name"), { "type" => proxy.fetch("type") }]
          end
          candidate.fetch("proxy-groups").each do |group|
            proxies[group.fetch("name")] = {
              "type" => "Selector", "all" => group.fetch("proxies")
            }
          end
          [200, JSON.generate("proxies" => proxies)]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        when ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          flunk "unexpected request: #{method} #{endpoint}"
        end
      end

      refute ClaudeEasy.runtime_matches_profile?(
        requester, profile, runtime_path_reader: -> { [loaded] }
      )
      stale_hosts = Marshal.load(Marshal.dump(candidate))
      stale_hosts["hosts"] = { "api.example" => "192.0.2.1" }
      File.binwrite(loaded, YAML.dump(stale_hosts))
      refute ClaudeEasy.runtime_matches_profile?(
        requester, profile, runtime_path_reader: -> { [loaded] }
      )
      File.binwrite(loaded, YAML.dump(candidate))
      assert ClaudeEasy.runtime_matches_profile?(
        requester, profile, runtime_path_reader: -> { [loaded] }
      )
      runtime_injected = Marshal.load(Marshal.dump(candidate)).merge(
        "external-controller-unix" => "/tmp/clash.sock", "secret" => "runtime-only"
      )
      File.binwrite(loaded, YAML.dump(runtime_injected))
      assert ClaudeEasy.runtime_matches_profile?(
        requester, profile, runtime_path_reader: -> { [loaded] }
      )
      assert_nil ClaudeEasy.profile_runtime_fingerprint(File.join(directory, "missing.yaml"))
      refute ClaudeEasy.runtime_matches_profile?(
        requester, profile, runtime_path_reader: -> { [File.join(directory, "missing.yaml")] }
      )
    end
  end

  def test_native_event_senders_only_treat_wait_reply_timeout_as_delivered
    disposer = ->(*_arguments) { 0 }
    ClaudeEasyAppleEvents.stub(:AEDisposeDesc, disposer) do
      ClaudeEasyAppleEvents.stub(:AECreateDesc, ->(*_arguments) { 0 }) do
        ClaudeEasyAppleEvents.stub(:AECreateAppleEvent, ->(*_arguments) { 0 }) do
          ClaudeEasyAppleEvents.stub(:AEPutParamPtr, ->(*_arguments) { 0 }) do
            ClaudeEasyAppleEvents.stub(:AESendMessage, ->(*_arguments) { -1712 }) do
              assert ClaudeEasyAppleEvents.send_get_url(12_345, "clash://update-config")
              assert ClaudeEasyAppleEvents.send_command(12_345, 0x434c5348, 0x544f4747)
            end
            ClaudeEasyAppleEvents.stub(:AESendMessage, ->(*_arguments) { -600 }) do
              refute ClaudeEasyAppleEvents.send_get_url(12_345, "clash://update-config")
              refute ClaudeEasyAppleEvents.send_command(12_345, 0x434c5348, 0x544f4747)
            end
          end
        end
      end
    end
  end

  def test_restore_candidate_must_match_the_saved_usage_profile
    Dir.mktmpdir do |directory|
      profile_one = ClaudeEasy.patch(base_config, @policy, usage_profile: 1).fetch(:config)
      profile_three = ClaudeEasy.patch(base_config, @policy, usage_profile: 3).fetch(:config)
      path = File.join(directory, "restore.yaml")
      File.binwrite(path, YAML.dump(profile_one))
      assert ClaudeEasy.restore_candidate_valid?(
        path, 1, policy: @policy, validator: ->(_candidate) { true }
      )
      File.binwrite(path, YAML.dump(profile_three))
      refute ClaudeEasy.restore_candidate_valid?(
        path, 1, policy: @policy, validator: ->(_candidate) { true }
      )
      assert ClaudeEasy.restore_candidate_valid?(
        path, 3, policy: @policy, validator: ->(_candidate) { true }
      )
      tun_only = Marshal.load(Marshal.dump(profile_one))
      tun_only["tun"] = ClaudeEasy::TUN_POLICY.dup
      File.binwrite(path, YAML.dump(tun_only))
      refute ClaudeEasy.restore_candidate_valid?(
        path, 1, policy: @policy, validator: ->(_candidate) { true }
      )
    end
  end

  def test_recovered_runtime_fails_closed_without_an_active_path
    refute ClaudeEasy.reload_recovered_profile_runtime(
      [{ path: "/missing.yaml", active: false }], require_tun: :preserve,
      requester: ->(*_arguments) { flunk "runtime must not be touched without an active path" }
    )
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      File.binwrite(path, YAML.dump(base_config))
      checkpoint = { path: File.realpath(path), selections: {}, expected_tun: :disabled }
      ClaudeEasy.stub(:reload_profile_runtime, true) do
        ClaudeEasy.stub(:runtime_health_healthy?, true) do
          checkpoint_checks = [false, true]
          ClaudeEasy.stub(:capture_runtime_checkpoint, checkpoint) do
            ClaudeEasy.stub(:runtime_checkpoint_current?, ->(*_arguments, **_options) { checkpoint_checks.shift }) do
              assert ClaudeEasy.reload_recovered_profile_runtime(
                [{ path: path, active: false }], require_tun: :preserve,
                runtime_checkpoint: checkpoint, requester: ->(*_arguments) { [200, "{}"] },
                runtime_profile_state_reader: ->(_path, _candidate) { :candidate }
              )
            end
          end
        end
      end
      refute ClaudeEasy.reload_recovered_profile_runtime(
        [{ path: File.join(directory, "missing.yaml"), active: false }],
        require_tun: :preserve, runtime_checkpoint: checkpoint,
        requester: ->(*_arguments) { flunk }
      )
    end
  end

  def test_safe_runtime_waiter_flushes_dns_once_after_profile_match
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    flushes = 0
    requester = lambda do |method, endpoint, _body = nil|
      if [method, endpoint] == ["POST", "/cache/dns/flush"]
        flushes += 1
        [204, ""]
      else
        [200, "{}"]
      end
    end
    health_checks = 0
    ClaudeEasy.stub(:runtime_restorable_selections, {}) do
      ClaudeEasy.stub(:restore_runtime_selections, true) do
        ClaudeEasy.stub(:runtime_health_healthy?, lambda { |_requester, **options|
          refute options.fetch(:flush_caches)
          health_checks += 1
          health_checks > 1
        }) do
          assert ClaudeEasy.wait_for_clashx_safe_runtime(
            identity, reload_receipt: {}, selections: {}, expected_tun: :disabled,
            requester_factory: -> { requester }, reload_receipt_reader: ->(_receipt) { true },
            process_reader: -> { identity }, profile_match_reader: ->(_requester) { true },
            sleeper: ->(_seconds) {}, attempts: 2
          )
        end
      end
    end
    assert_equal 1, flushes
  end

  def test_domestic_dns_health_rejects_fake_ip_answers
    requester = lambda do |_method, _endpoint, _body = nil|
      [200, JSON.generate("Status" => 0, "Answer" => [{ "data" => "198.19.2.3" }])]
    end
    refute ClaudeEasy.dns_runtime_healthy?(requester, "www.baidu.com")
  end

  def test_profile_two_proxy_disable_refuses_inconsistent_intent
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    events = []
    result = ClaudeEasy.reconcile_clashx_client_switches(
      usage_profile: 2, identity_reader: -> { identity },
      command_support_reader: ->(_current) { true },
      state_reader: -> {
        {
          tun_effective: :enabled, tun_intent: true,
          system_proxy_effective: :disabled, system_proxy_intent: true
        }
      },
      command_sender: ->(_current, command) { events << command; true },
      connectivity_checker: -> { true }, sleeper: ->(_seconds) {}
    )
    assert_equal :state_ambiguous, result.fetch(:reason)
    assert_empty events
  end

  def test_backup_reads_source_through_one_regular_file_snapshot
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.binwrite(profile, "later")
      snapshot = { bytes: "snapshotted".b, identity: [1, 2], path: profile }
      backup = ClaudeEasy.stub(:regular_file_snapshot_once, snapshot) do
        ClaudeEasy.create_versioned_backup(profile, backup_root)
      end
      assert_equal "snapshotted".b, File.binread(backup)
    end
  end

  def test_public_sanitizers_hide_bare_node_addresses_and_unc_paths
    unsafe = "node.example:443 1.2.3.4:8443 \\\\server\\share\\profile.yaml"
    [ClaudeEasy.safe_label(unsafe), ClaudeEasyResult.sanitize_text(unsafe)].each do |output|
      refute_includes output, "node.example"
      refute_includes output, "1.2.3.4"
      refute_includes output, "server"
    end
  end

  def test_common_dns_normalizes_scalar_nameservers_and_combined_policy_keys
    [1, 2, 3].each do |usage_profile|
      config = base_config
      config.fetch("dns")["nameserver"] = "system"
      config.fetch("dns")["nameserver-policy"] = {
        "geosite:cn,+.example.com" => ["system"]
      }
      patched = ClaudeEasy.patch(config, @policy, usage_profile: usage_profile).fetch(:config)
      assert_kind_of Array, patched.fetch("dns").fetch("nameserver")
      refute patched.fetch("dns").fetch("nameserver-policy").key?("geosite:cn,+.example.com")
      assert patched.fetch("dns").fetch("nameserver-policy").key?("+.example.com")
    end
  end

  private

  def run_with_stubbed_finalization(auto_reload:, runtime_precommit:, recover:, reload:, remove:)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      File.binwrite(path, "old")
      identity = File.stat(path).then { |stat| [stat.dev, stat.ino] }
      preview = {
        status: :updated, transaction_original: "old", transaction_candidate: "new"
      }
      committed = {
        status: :updated, path: path, rollback_bytes: "old",
        patched_digest: Digest::SHA256.hexdigest("new"),
        patched_identity: identity, patched_path: File.realpath(path)
      }
      transaction = {
        targets: {
          File.expand_path(path) => { identity: identity, write_path: File.realpath(path) }
        }
      }
      runtime_checkpoint = {
        path: File.realpath(path), expected_tun: :disabled,
        selections: { "Main" => "Taiwan" }
      }
      patcher = lambda do |_path, _policy, dry_run:, **_options|
        dry_run ? preview.dup : committed.dup
      end
      lock = Object.new
      lock.define_singleton_method(:close) { true }
      recoverer = lambda do |*_arguments, **_options|
        raise IOError, "injected recovery failure" if recover == :raise

        transaction
      end
      remover = lambda do |_transaction|
        raise IOError, "injected journal removal failure" if remove == :raise

        true
      end
      activator = ->(result, **_options) { result.merge(reloaded: true) }

      ClaudeEasy.stub(:profile_operation_lock, lock) do
        ClaudeEasy.stub(:resume_profile_transaction, :none) do
          ClaudeEasy.stub(:profile_work_items, [{ path: path, active: true }]) do
            ClaudeEasy.stub(:patch_path, patcher) do
              ClaudeEasy.stub(:capture_runtime_checkpoint, runtime_checkpoint) do
                ClaudeEasy.stub(:prepare_profile_transaction, transaction) do
                  ClaudeEasy.stub(:activate_updated_profile, activator) do
                    ClaudeEasy.stub(:runtime_precommit_allowed?, runtime_precommit) do
                      ClaudeEasy.stub(:profile_result_current?, false) do
                        ClaudeEasy.stub(:restore_profile_bytes, true) do
                          ClaudeEasy.stub(:recover_profile_transaction, recoverer) do
                            ClaudeEasy.stub(:reload_recovered_profile_runtime, reload) do
                              ClaudeEasy.stub(:remove_profile_transaction, remover) do
                                return ClaudeEasy.run(
                                  directory: directory, policy_path: POLICY_PATH,
                                  backup_root: File.join(directory, "backups"),
                                  selected_name: "friend", validator: ->(_candidate) { true },
                                  auto_reload: auto_reload, usage_profile: 1
                                )
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  def run_with_stubbed_safe_update_finalization(activation:, runtime_precommit:, rollback:,
                                                 reload: false, remove: :success)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      File.binwrite(path, YAML.dump(base_config.merge("subscription-marker" => "old")))
      checks = 0
      current = lambda do |_item|
        checks += 1
        checks == 1
      end
      remover = lambda do |_transaction|
        raise IOError, "injected journal removal failure" if remove == :raise

        true
      end

      ClaudeEasy.stub(:safe_update_item_committed?, current) do
        ClaudeEasy.stub(:finish_safe_update_rollback, rollback) do
          ClaudeEasy.stub(:runtime_precommit_allowed?, runtime_precommit) do
            ClaudeEasy.stub(:reload_recovered_safe_update_runtime, reload) do
              ClaudeEasy.stub(:remove_profile_transaction, remover) do
                return ClaudeEasy.safe_update_all(
                  targets: [{
                    name: "friend", path: path,
                    url: "https://subscriptions.invalid/friend"
                  }],
                  policy: @policy, backup_root: File.join(directory, "backups"),
                  usage_profile: 1,
                  fetcher: ->(_target) {
                    YAML.dump(base_config.merge("subscription-marker" => "new"))
                  },
                  validator: ->(_candidate) { true },
                  activation: ->(_items) { activation }, selected_name: "friend"
                )
              end
            end
          end
        end
      end
    end
  end

  def refute_self_reference(config)
    config.fetch("proxy-groups").each do |group|
      refute_includes Array(group["proxies"]), group["name"], "group #{group['name']} references itself"
    end
  end

  public

  def test_clashx_native_reload_targets_only_the_existing_process
    identity = {
      pid: 12_345, started: "Thu Aug 20 00:14:18 2026",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    calls = []
    sender = lambda do |pid, url|
      calls << [pid, url]
      true
    end

    assert ClaudeEasy.request_clashx_native_reload(
      identity, sender: sender, process_reader: -> { identity }
    )
    assert_equal [[identity.fetch(:pid), "clash://update-config"]], calls

    refute ClaudeEasy.request_clashx_native_reload(
      identity, sender: ->(*_arguments) { flunk "stale PID must not receive an event" },
      process_reader: -> { identity.merge(pid: 54_321) }
    )
  end

  def test_clashx_script_commands_target_only_the_existing_process
    identity = {
      pid: 12_345, started: "Thu Aug 20 00:14:18 2026",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    calls = []
    sender = lambda do |pid, event_class, event_id|
      calls << [pid, event_class, event_id]
      true
    end

    assert ClaudeEasy.request_clashx_script_command(
      identity, :tun_mode, sender: sender, process_reader: -> { identity }
    )
    assert ClaudeEasy.request_clashx_script_command(
      identity, :system_proxy, sender: sender, process_reader: -> { identity }
    )
    assert_equal [
      [12_345, 0x636c6173, 0x6874756e],
      [12_345, 0x636c6173, 0x68746f67]
    ], calls
    refute ClaudeEasy.request_clashx_script_command(
      identity, :unknown, sender: ->(*_arguments) { flunk }, process_reader: -> { identity }
    )
    refute ClaudeEasy.request_clashx_script_command(
      identity, :tun_mode, sender: ->(*_arguments) { flunk },
      process_reader: -> { identity.merge(pid: 54_321) }
    )
    refute ClaudeEasy.request_clashx_script_command(
      identity, :tun_mode, sender: ->(*_arguments) { raise IOError },
      process_reader: -> { identity }
    )
  end

  def test_low_level_client_switch_event_sender_covers_success_and_failures
    disposer = ->(*_arguments) { 0 }
    ClaudeEasyAppleEvents.stub(:AEDisposeDesc, disposer) do
      ClaudeEasyAppleEvents.stub(:AECreateDesc, ->(*_arguments) { 0 }) do
        ClaudeEasyAppleEvents.stub(:AECreateAppleEvent, ->(*_arguments) { 0 }) do
          ClaudeEasyAppleEvents.stub(:AESendMessage, ->(*_arguments) { 0 }) do
            assert ClaudeEasyAppleEvents.send_command(12_345, 0x636c6173, 0x6874756e)
          end
          ClaudeEasyAppleEvents.stub(:AESendMessage, ->(*_arguments) { raise IOError }) do
            refute ClaudeEasyAppleEvents.send_command(12_345, 0x636c6173, 0x6874756e)
          end
        end
        ClaudeEasyAppleEvents.stub(:AECreateAppleEvent, ->(*_arguments) { 1 }) do
          refute ClaudeEasyAppleEvents.send_command(12_345, 0x636c6173, 0x6874756e)
        end
      end
      ClaudeEasyAppleEvents.stub(:AECreateDesc, ->(*_arguments) { 1 }) do
        refute ClaudeEasyAppleEvents.send_command(12_345, 0x636c6173, 0x6874756e)
      end
    end
  end

  def test_client_switch_reconciliation_is_a_noop_when_profile_two_matches
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    state = {
      tun_effective: :enabled, tun_intent: true,
      system_proxy_effective: :disabled, system_proxy_intent: false
    }
    events = []
    checks = 0
    result = ClaudeEasy.reconcile_clashx_client_switches(
      usage_profile: 2, identity_reader: -> { identity },
      command_support_reader: ->(_current) { true }, state_reader: -> { state },
      command_sender: ->(_current, command) { events << command; true },
      connectivity_checker: -> { checks += 1; true }, sleeper: ->(_seconds) {}
    )

    assert_equal :unchanged, result.fetch(:status)
    assert_empty events
    assert_equal 1, checks
  end

  def test_profile_three_preserves_a_third_party_pac_when_clash_system_proxy_is_off
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    state = {
      tun_effective: :enabled, tun_intent: true,
      system_proxy_effective: :other, system_proxy_intent: false
    }
    events = []

    result = ClaudeEasy.reconcile_clashx_client_switches(
      usage_profile: 3, identity_reader: -> { identity },
      command_support_reader: ->(_current) { true }, state_reader: -> { state },
      command_sender: ->(_current, command) { events << command; true },
      connectivity_checker: -> { true }, sleeper: ->(_seconds) {}
    )

    assert_equal :unchanged, result.fetch(:status)
    assert_equal "other", result.fetch(:checks).find { |check| check["name"] == "system_proxy" }.fetch("status")
    assert_empty events
  end

  def test_profile_two_reconciliation_orders_one_event_per_switch
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    state = {
      tun_effective: :disabled, tun_intent: false,
      system_proxy_effective: :clash, system_proxy_intent: true
    }
    order = []
    sender = lambda do |_current, command|
      order << command
      if command == :tun_mode
        state = state.merge(tun_effective: :enabled, tun_intent: true)
      else
        state = state.merge(system_proxy_effective: :disabled, system_proxy_intent: false)
      end
      true
    end
    result = ClaudeEasy.reconcile_clashx_client_switches(
      usage_profile: 2, identity_reader: -> { identity },
      command_support_reader: ->(_current) { true }, state_reader: -> { state },
      command_sender: sender,
      connectivity_checker: -> { order << :connectivity; true }, sleeper: ->(_seconds) {}
    )

    assert_equal :reconciled, result.fetch(:status)
    assert_equal %i[tun_mode connectivity system_proxy connectivity], order
    assert_equal %i[tun system_proxy], result.fetch(:changes)
  end

  def test_client_switch_reconciliation_refuses_ambiguous_or_third_party_state
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    events = []
    common = {
      identity_reader: -> { identity }, command_support_reader: ->(_current) { true },
      command_sender: ->(_current, command) { events << command; true },
      connectivity_checker: -> { true }, sleeper: ->(_seconds) {}
    }
    ambiguous = ClaudeEasy.reconcile_clashx_client_switches(
      **common, usage_profile: 2,
      state_reader: -> {
        {
          tun_effective: :enabled, tun_intent: false,
          system_proxy_effective: :disabled, system_proxy_intent: false
        }
      }
    )
    third_party = ClaudeEasy.reconcile_clashx_client_switches(
      **common, usage_profile: 1,
      state_reader: -> {
        {
          tun_effective: :disabled, tun_intent: false,
          system_proxy_effective: :other, system_proxy_intent: false
        }
      }
    )

    assert_equal :manual_required, ambiguous.fetch(:status)
    assert_equal :state_ambiguous, ambiguous.fetch(:reason)
    assert_equal :manual_required, third_party.fetch(:status)
    assert_equal :third_party_proxy_active, third_party.fetch(:reason)
    assert_empty events
  end

  def test_client_switch_reconciliation_never_retries_a_toggle
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    state = {
      tun_effective: :disabled, tun_intent: false,
      system_proxy_effective: :disabled, system_proxy_intent: false
    }
    events = []
    result = ClaudeEasy.reconcile_clashx_client_switches(
      usage_profile: 2, identity_reader: -> { identity },
      command_support_reader: ->(_current) { true }, state_reader: -> { state },
      command_sender: ->(_current, command) { events << command; true },
      connectivity_checker: -> { true }, sleeper: ->(_seconds) {}, attempts: 2
    )

    assert_equal :manual_required, result.fetch(:status)
    assert_equal :native_command_unverified, result.fetch(:reason)
    assert_equal [:tun_mode], events
  end

  def test_client_switch_reconciliation_preserves_third_party_proxy_after_connectivity_check
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    state = {
      tun_effective: :enabled, tun_intent: true,
      system_proxy_effective: :clash, system_proxy_intent: true
    }
    events = []
    result = ClaudeEasy.reconcile_clashx_client_switches(
      usage_profile: 2, identity_reader: -> { identity },
      command_support_reader: ->(_current) { true }, state_reader: -> { state },
      command_sender: ->(_current, command) { events << command; true },
      connectivity_checker: lambda {
        state = state.merge(system_proxy_effective: :other, system_proxy_intent: false)
        true
      },
      sleeper: ->(_seconds) {}
    )

    assert_equal :unchanged, result.fetch(:status)
    assert_empty events
  end

  def test_client_switch_reconciliation_refreshes_final_state_after_connectivity_check
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    state = {
      tun_effective: :disabled, tun_intent: false,
      system_proxy_effective: :disabled, system_proxy_intent: false
    }
    result = ClaudeEasy.reconcile_clashx_client_switches(
      usage_profile: 1, identity_reader: -> { identity },
      command_support_reader: ->(_current) { true }, state_reader: -> { state },
      command_sender: lambda { |_current, command|
        assert_equal :system_proxy, command
        state = state.merge(system_proxy_effective: :clash, system_proxy_intent: true)
        true
      },
      connectivity_checker: lambda {
        state = state.merge(system_proxy_effective: :disabled, system_proxy_intent: false)
        true
      },
      sleeper: ->(_seconds) {}
    )

    assert_equal :manual_required, result.fetch(:status)
    assert_equal :state_ambiguous, result.fetch(:reason)
  end

  def test_client_switch_state_combines_preferences_runtime_and_system_proxy
    requester = lambda do |_method, endpoint, _body|
      assert_equal "/configs", endpoint
      [200, JSON.generate(
        "tun" => { "enable" => true }, "mixed-port" => 7893,
        "port" => 0, "socks-port" => 0
      )]
    end
    preferences = {
      "restoreTunProxy" => "true", "proxyPortAutoSet" => "false"
    }
    state = ClaudeEasy.clashx_client_switch_state(
      requester: requester, preference_reader: ->(key) { preferences.fetch(key) },
      proxy_reader: -> {
        {
          http_enabled: false, http_port: 0,
          https_enabled: false, https_port: 0,
          socks_enabled: false, socks_port: 0,
          pac_enabled: false, auto_discovery_enabled: false
        }
      }
    )

    assert_equal :enabled, state.fetch(:tun_effective)
    assert_equal true, state.fetch(:tun_intent)
    assert_equal :disabled, state.fetch(:system_proxy_effective)
    assert_equal false, state.fetch(:system_proxy_intent)
  end

  def test_clashx_script_dictionary_supports_a_unicode_application_path
    Dir.mktmpdir("客户端应用") do |directory|
      bundle = File.join(directory, "ClashX Meta.app")
      executable = File.join(bundle, "Contents/MacOS/ClashX Meta")
      dictionary = File.join(bundle, "Contents/Resources/ProxySetting.sdef")
      FileUtils.mkdir_p(File.dirname(executable))
      FileUtils.mkdir_p(File.dirname(dictionary))
      File.binwrite(executable, "")
      File.binwrite(dictionary, '<command code="clashtun"/><command code="clashtog"/>')
      identity = { pid: 12_345, started: "same", executable: executable }

      assert ClaudeEasy.clashx_script_commands_supported?(identity)
    end
  end

  def test_client_switch_reconciliation_rechecks_the_process_before_success
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    identities = [identity, identity, identity.merge(pid: 54_321)]
    state = {
      tun_effective: :enabled, tun_intent: true,
      system_proxy_effective: :disabled, system_proxy_intent: false
    }
    result = ClaudeEasy.reconcile_clashx_client_switches(
      usage_profile: 2, identity_reader: -> { identities.shift || identities.last },
      command_support_reader: ->(_current) { true }, state_reader: -> { state },
      command_sender: ->(*_arguments) { flunk }, connectivity_checker: -> { true },
      sleeper: ->(_seconds) {}
    )

    assert_equal :manual_required, result.fetch(:status)
    assert_equal :client_changed, result.fetch(:reason)
  end

  def test_system_proxy_snapshot_classifies_clash_disabled_and_third_party
    status = Struct.new(:success?).new(true)
    output = <<~SCUTIL
      <dictionary> {
        HTTPEnable : 1
        HTTPProxy : 127.0.0.1
        HTTPPort : 7893
        HTTPSEnable : 1
        HTTPSProxy : 127.0.0.1
        HTTPSPort : 7893
        SOCKSEnable : 1
        SOCKSProxy : 127.0.0.1
        SOCKSPort : 7893
        ProxyAutoConfigEnable : 0
      }
    SCUTIL
    snapshot = ClaudeEasy.macos_system_proxy_snapshot(
      runner: ->(*_arguments) { [output, "", status] }
    )
    assert_equal "127.0.0.1", snapshot.fetch(:http_proxy)
    assert_equal :clash, ClaudeEasy.classify_system_proxy(snapshot, 7893, 7893)
    assert_equal :disabled, ClaudeEasy.classify_system_proxy(
      snapshot.transform_values { |value| value == true ? false : value }, 7893, 7893
    )
    assert_equal :other, ClaudeEasy.classify_system_proxy(
      snapshot.merge(pac_enabled: true), 7893, 7893
    )
    assert_equal :other, ClaudeEasy.classify_system_proxy(
      snapshot.merge(
        http_proxy: "10.0.0.2", https_proxy: "10.0.0.2", socks_proxy: "10.0.0.2"
      ),
      7893, 7893
    )
  end

  def test_client_switch_readers_fail_closed_on_bad_sources
    refute ClaudeEasy.clashx_script_commands_supported?({})
    assert_nil ClaudeEasy.macos_system_proxy_snapshot(
      runner: ->(*_arguments) { raise IOError }
    )
    assert_nil ClaudeEasy.runtime_client_switch_values(
      ->(*_arguments) { [200, "not json"] }
    )
    requester = ->(*_arguments) {
      [200, JSON.generate(
        "tun" => { "enable" => false }, "mixed-port" => 7893
      )]
    }
    assert_nil ClaudeEasy.clashx_client_switch_state(
      requester: requester, preference_reader: ->(_key) { raise IOError },
      proxy_reader: -> { {} }
    )
    assert_nil ClaudeEasy.wait_for_client_switch(
      { pid: 1 }, -> { { pid: 1 } }, -> { raise IOError }, 1, ->(_seconds) {}
    ) { true }
  end

  def test_profile_one_uses_default_native_helpers
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    proxy = :disabled
    pending_proxy = false
    delayed_read = false
    preferences = { "restoreTunProxy" => "false", "proxyPortAutoSet" => "false" }
    requester = lambda do |_method, _endpoint, _body|
      [200, JSON.generate(
        "tun" => { "enable" => false }, "mixed-port" => 7893
      )]
    end
    proxy_snapshot = lambda do
      if pending_proxy && !delayed_read
        delayed_read = true
      elsif pending_proxy
        proxy = :clash
      end
      enabled = proxy == :clash
      {
        http_enabled: enabled, http_port: enabled ? 7893 : 0,
        http_proxy: enabled ? "127.0.0.1" : nil,
        https_enabled: enabled, https_port: enabled ? 7893 : 0,
        https_proxy: enabled ? "127.0.0.1" : nil,
        socks_enabled: enabled, socks_port: enabled ? 7893 : 0,
        socks_proxy: enabled ? "127.0.0.1" : nil,
        pac_enabled: false, auto_discovery_enabled: false
      }
    end
    modes = []
    ClaudeEasy.stub(:clashx_running_identity, identity) do
      ClaudeEasy.stub(:clashx_script_commands_supported?, true) do
        ClaudeEasy.stub(:current_runtime_requester, -> { requester }) do
          ClaudeEasy.stub(:defaults_read, ->(key) { preferences.fetch(key) }) do
            ClaudeEasy.stub(:macos_system_proxy_snapshot, proxy_snapshot) do
              ClaudeEasy.stub(:request_clashx_script_command, lambda { |_current, command, *_options|
                assert_equal :system_proxy, command
                pending_proxy = true
                preferences["proxyPortAutoSet"] = "true"
                true
              }) do
                ClaudeEasy.stub(:default_connectivity_healthy?, lambda { |options|
                  modes << options.fetch(:tun_mode)
                  true
                }) do
                  result = ClaudeEasy.reconcile_clashx_client_switches(usage_profile: 1)
                  assert_equal :reconciled, result.fetch(:status), result.inspect
                end
              end
            end
          end
        end
      end
    end
    assert_equal [:disabled], modes
  end

  def test_client_switch_reconciliation_converts_unexpected_errors_to_manual_result
    result = ClaudeEasy.reconcile_clashx_client_switches(
      usage_profile: 9, identity_reader: -> { raise IOError }
    )
    assert_equal :invalid_profile, result.fetch(:reason)

    result = ClaudeEasy.reconcile_clashx_client_switches(
      usage_profile: 1, identity_reader: -> { raise IOError }
    )
    assert_equal :unexpected_error, result.fetch(:reason)
  end

  def test_clashx_runtime_waits_for_profile_match_and_full_health
    identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
    matches = [false, false, true]
    dns_checks = []
    sleeps = 0

    ClaudeEasy.stub(:runtime_health_healthy?, lambda { |_requester, **options|
      dns_checks << options.fetch(:check_dns, true)
      true
    }) do
      requester = ->(*_arguments) {
        [200, JSON.generate("proxies" => {
          "Main" => { "type" => "Selector", "now" => "Taiwan", "all" => ["Taiwan"] }
        })]
      }
      assert ClaudeEasy.wait_for_clashx_safe_runtime(
        identity, selections: { "Main" => "Taiwan" },
        expected_tun: :enabled, requester_factory: -> { requester },
        reload_receipt: {}, reload_receipt_reader: ->(_receipt) { true },
        profile_match_reader: ->(_requester) { matches.shift },
        process_reader: -> { identity }, connectivity_checker: -> { true },
        sleeper: ->(_seconds) { sleeps += 1 }, attempts: 4
      )
    end

    assert_equal 2, sleeps
    assert_equal [true], dns_checks
  end

  def test_clashx_runtime_waits_for_a_new_core_reload_completion_record
    assert_respond_to ClaudeEasy, :clashx_reload_snapshot
    assert_respond_to ClaudeEasy, :clashx_reload_completed_since?

    Dir.mktmpdir do |directory|
      session = File.join(directory, "2026-08-21_17-00-00")
      FileUtils.mkdir_p(session)
      log = File.join(session, "clashx_core_21_17-00-01.log")
      File.binwrite(log, "Initial configuration complete, total time: 10ms\n")
      snapshot = ClaudeEasy.clashx_reload_snapshot(log_root: directory)
      refute_nil snapshot

      File.open(log, "ab") { |handle| handle.write("unrelated runtime log\n") }
      refute ClaudeEasy.clashx_reload_completed_since?(snapshot, log_root: directory)
      File.open(log, "ab") do |handle|
        handle.write("Initial configuration complete, total time: 12ms\n")
      end
      assert ClaudeEasy.clashx_reload_completed_since?(snapshot, log_root: directory)

      rotated_snapshot = ClaudeEasy.clashx_reload_snapshot(log_root: directory)
      rotated_log = File.join(session, "clashx_core_21_17-01-00.log")
      File.binwrite(rotated_log, "Initial configuration complete, total time: 9ms\n")
      assert ClaudeEasy.clashx_reload_completed_since?(rotated_snapshot, log_root: directory)

      ClaudeEasy.stub(:clashx_reload_snapshot, ->(**_options) { raise IOError }) do
        refute ClaudeEasy.clashx_reload_completed_since?(rotated_snapshot, log_root: directory)
      end

      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      receipts = [false, true]
      sleeps = 0
      requester = ->(*_arguments) {
        [200, JSON.generate("proxies" => {
          "Main" => { "type" => "Selector", "now" => "Taiwan", "all" => ["Taiwan"] }
        })]
      }
      ClaudeEasy.stub(:runtime_health_healthy?, true) do
        assert ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "Taiwan" },
          expected_tun: :enabled, requester_factory: -> { requester },
          reload_receipt: {}, reload_receipt_reader: ->(_receipt) { true },
          profile_match_reader: ->(_requester) { receipts.shift },
          process_reader: -> { identity }, sleeper: ->(_seconds) { sleeps += 1 }, attempts: 3
        )
      end
      assert_equal 1, sleeps
    end
  end

  def test_clashx_reload_receipt_stream_reads_a_live_controller_event
    Dir.mktmpdir do |directory|
      socket_path = File.join(directory, "controller.sock")
      server = UNIXServer.new(socket_path)
      release = Queue.new
      worker = Thread.new do
        client = server.accept
        request = +""
        request << client.readpartial(1024) until request.include?("\r\n\r\n")
        client.write(
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
          "Connection: Upgrade\r\nSec-WebSocket-Accept: fixture\r\n\r\n"
        )
        release.pop
        payload = "{\"type\":\"info\",\"payload\":\"Initial configuration complete, total time: 1ms\"}\n"
        client.write([0x81, payload.bytesize].pack("CC") + payload)
        request
      ensure
        client&.close
      end

      receipt = ClaudeEasy.stub(:controller_secret, "fixture-secret") do
        ClaudeEasy.open_clashx_reload_receipt(socket_path, timeout: 1)
      end
      assert receipt
      release << true
      assert IO.select([receipt.fetch(:socket)], nil, nil, 1)
      assert ClaudeEasy.clashx_reload_receipt_completed?(receipt)
      assert_includes worker.value, "GET /logs?level=info HTTP/1.1"
      assert_includes worker.value, "Upgrade: websocket"
      assert_includes worker.value, "Authorization: Bearer fixture-secret"
      ClaudeEasy.close_clashx_reload_receipt(receipt)
      server.close
    end
  end

  def test_clashx_reload_receipt_helpers_fail_closed_and_bound_the_buffer
    closed = false
    broken_socket = Object.new
    broken_socket.define_singleton_method(:close_on_exec=) { |_value| }
    broken_socket.define_singleton_method(:write) { |_request| raise IOError }
    broken_socket.define_singleton_method(:close) { closed = true }
    UNIXSocket.stub(:new, broken_socket) do
      assert_nil ClaudeEasy.open_clashx_reload_receipt("socket")
    end
    assert closed

    completed_socket = Object.new
    completed_socket.define_singleton_method(:read_nonblock) { |_size, exception:| :wait_readable }
    completed = { socket: completed_socket, buffer: "Initial configuration complete, total time:".b, completed: false }
    assert ClaudeEasy.clashx_reload_receipt_completed?(completed)
    assert completed[:completed]
    assert_empty completed[:buffer]

    reads = ["x", :wait_readable]
    reader = Object.new
    reader.define_singleton_method(:read_nonblock) { |_size, exception:| reads.shift }
    bounded = { socket: reader, buffer: "x" * 65_536, completed: false }
    refute ClaudeEasy.clashx_reload_receipt_completed?(bounded)
    assert_operator bounded.fetch(:buffer).bytesize, :<, 65_536

    raising_reader = Object.new
    raising_reader.define_singleton_method(:read_nonblock) { |_size, exception:| raise IOError }
    refute ClaudeEasy.clashx_reload_receipt_completed?(
      socket: raising_reader, buffer: "", completed: false
    )

    raising_close = Object.new
    raising_close.define_singleton_method(:closed?) { false }
    raising_close.define_singleton_method(:close) { raise IOError }
    refute ClaudeEasy.close_clashx_reload_receipt(socket: raising_close)
  end


  def test_runtime_match_rejects_an_old_in_memory_config
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.write(profile, YAML.dump(
        "proxies" => [{ "name" => "New Node", "type" => "ss" }],
        "proxy-groups" => [{ "name" => "Main", "type" => "select", "proxies" => ["New Node"] }]
      ))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Old Node", "all" => ["Old Node"] },
            "Old Node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        else
          [0, ""]
        end
      end

      runtime_path_reader = -> { [profile] }
      refute ClaudeEasy.runtime_matches_profile?(
        requester, profile, runtime_path_reader: runtime_path_reader
      )

      loaded = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "New Node", "all" => ["New Node"] },
            "New Node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        when ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          [0, ""]
        end
      end
      assert ClaudeEasy.runtime_matches_profile?(
        loaded, profile, runtime_path_reader: runtime_path_reader
      )

      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      ClaudeEasy.stub(:runtime_health_healthy?, true) do
        assert ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
          requester_factory: -> { loaded }, expected_profile_path: profile,
          reload_receipt: {}, reload_receipt_reader: ->(_receipt) { true },
          profile_match_reader: ->(requester) {
            ClaudeEasy.runtime_matches_profile?(
              requester, profile, runtime_path_reader: runtime_path_reader
            )
          },
          process_reader: -> { identity }, attempts: 1
        )
        refute ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
          requester_factory: -> { loaded }, expected_profile_path: profile,
          reload_receipt_reader: ->(_receipt) { false }, reload_receipt: {},
          process_reader: -> { identity }, attempts: 1
        )
        refute ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "Old Node" }, expected_tun: :ignore,
          requester_factory: -> { requester }, expected_profile_path: profile,
          process_reader: -> { identity }, attempts: 1
        )
        refute ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
          requester_factory: -> { loaded }, process_reader: -> { identity },
          attempts: 1
        )
        refute ClaudeEasy.wait_for_clashx_safe_runtime(
          identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
          requester_factory: -> { loaded }, reload_receipt: {},
          reload_receipt_reader: ->(_before) { true },
          process_reader: -> { identity }, attempts: 1
        )
      end

      refute ClaudeEasy.runtime_matches_profile?(->(*) { raise IOError }, profile)
      refute ClaudeEasy.runtime_matches_profile?(
        loaded, File.join(directory, "missing.yaml")
      )
      File.write(profile, YAML.dump(
        "proxies" => [{ "name" => "New Node", "type" => "ss" }, { "type" => "ss" }],
        "proxy-groups" => [
          { "name" => "Main", "type" => "select", "proxies" => ["New Node"] },
          { "type" => "select" }
        ],
        "proxy-providers" => { "sub" => { "type" => "http" } }
      ))
      refute ClaudeEasy.runtime_matches_profile?(loaded, profile)
      with_provider = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "New Node", "all" => ["New Node"] },
            "New Node" => { "type" => "Shadowsocks" },
            "GLOBAL" => { "type" => "Selector" }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => { "sub" => {} })]
        else
          [0, ""]
        end
      end
      assert ClaudeEasy.runtime_matches_profile?(
        with_provider, profile, runtime_path_reader: runtime_path_reader
      )
      missing_provider = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "New Node", "all" => ["New Node"] },
            "New Node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/providers/proxies"]
          [404, ""]
        else
          [0, ""]
        end
      end
      refute ClaudeEasy.runtime_matches_profile?(missing_provider, profile)
      File.write(profile, "[]")
      refute ClaudeEasy.runtime_matches_profile?(loaded, profile)
    end
  end

  def test_runtime_match_accepts_members_removed_by_a_group_exclude_filter
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.write(profile, YAML.dump(
        "proxies" => [
          { "name" => "Available Node", "type" => "ss" },
          { "name" => "Expired Node", "type" => "ss" }
        ],
        "proxy-groups" => [{
          "name" => "Main", "type" => "select",
          "proxies" => ["Available Node", "Expired Node"],
          "exclude-filter" => "(?i)(expired|remaining)"
        }]
      ))
      loaded = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => {
              "type" => "Selector", "now" => "Available Node", "all" => ["Available Node"]
            },
            "Available Node" => { "type" => "Shadowsocks" },
            "Expired Node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        else
          [0, ""]
        end
      end

      assert ClaudeEasy.runtime_matches_profile?(
        loaded, profile, runtime_path_reader: -> { [profile] }
      )

      stale = lambda do |method, endpoint, body = nil|
        next loaded.call(method, endpoint, body) unless [method, endpoint] == ["GET", "/proxies"]

        [200, JSON.generate("proxies" => {
          "Main" => {
            "type" => "Selector", "now" => "Available Node",
            "all" => ["Available Node", "Removed Node"]
          },
          "Available Node" => { "type" => "Shadowsocks" },
          "Expired Node" => { "type" => "Shadowsocks" },
          "Removed Node" => { "type" => "Shadowsocks" }
        })]
      end
      refute ClaudeEasy.runtime_matches_profile?(
        stale, profile, runtime_path_reader: -> { [profile] }
      )
    end
  end

  def test_safe_reload_uses_the_fresh_receipt_instead_of_the_clashx_bootstrap_config
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      bootstrap = File.join(directory, "bootstrap.yaml")
      File.write(profile, YAML.dump(
        "proxies" => [{ "name" => "New Node", "type" => "ss" }],
        "proxy-groups" => [
          { "name" => "Main", "type" => "select", "proxies" => ["New Node"] }
        ]
      ))
      File.write(bootstrap, YAML.dump(
        "mixed-port" => 7890,
        "external-ui" => "ui",
        "rules" => ["MATCH,DIRECT"]
      ))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "New Node", "all" => ["New Node"] },
            "New Node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        when ["POST", "/cache/dns/flush"]
          [204, ""]
        else
          [0, ""]
        end
      end
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }

      ClaudeEasy.stub(:running_mihomo_config_paths, [bootstrap]) do
        ClaudeEasy.stub(:runtime_health_healthy?, true) do
          assert ClaudeEasy.wait_for_clashx_safe_runtime(
            identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
            requester_factory: -> { requester }, expected_profile_path: profile,
            reload_receipt: {}, reload_receipt_reader: ->(_receipt) { true },
            process_reader: -> { identity }, attempts: 1
          )
        end
      end
    end
  end

  def test_safe_reload_rejects_entries_only_present_in_the_previous_profile
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.write(profile, YAML.dump(
        "proxies" => [{ "name" => "New Node", "type" => "ss" }],
        "proxy-groups" => [
          { "name" => "Main", "type" => "select", "proxies" => ["New Node"] }
        ]
      ))
      requester = lambda do |method, endpoint, _body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => {
              "type" => "Selector", "now" => "New Node", "all" => ["New Node", "Old Node"]
            },
            "New Node" => { "type" => "Shadowsocks" },
            "Old Node" => { "type" => "Shadowsocks" }
          })]
        when ["GET", "/providers/proxies"]
          [200, JSON.generate("providers" => {})]
        else
          [0, ""]
        end
      end
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      previous_identity = {
        proxies: ["New Node", "Old Node"],
        groups: { "Main" => ["New Node", "Old Node"] }, providers: []
      }

      refute ClaudeEasy.wait_for_clashx_safe_runtime(
        identity, selections: { "Main" => "New Node" }, expected_tun: :ignore,
        requester_factory: -> { requester }, expected_profile_path: profile,
        previous_profile_identity: previous_identity,
        reload_receipt: {}, reload_receipt_reader: ->(_receipt) { true },
        process_reader: -> { identity }, attempts: 1
      )
    end
  end

  def test_clashx_reload_receipt_ignores_an_old_completion_moved_by_log_rotation
    Dir.mktmpdir do |directory|
      session = File.join(directory, "2026-08-21_17-00-00")
      FileUtils.mkdir_p(session)
      log = File.join(session, "clashx_core_21_17-00-01.log")
      File.binwrite(log, "Initial configuration complete, total time: 10ms\n")
      snapshot = ClaudeEasy.clashx_reload_snapshot(log_root: directory)

      File.rename(log, "#{log}.1")
      File.binwrite(log, "reload started\n")

      refute ClaudeEasy.clashx_reload_completed_since?(snapshot, log_root: directory)
      File.open(log, "ab") do |handle|
        handle.write("Initial configuration complete, total time: 12ms\n")
      end
      assert ClaudeEasy.clashx_reload_completed_since?(snapshot, log_root: directory)
    end
  end

  def test_clashx_runtime_wait_rejects_when_any_previous_selection_is_removed
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    health_checked = false
    requester = lambda do |method, endpoint, _body = nil|
      raise "unexpected request: #{method} #{endpoint}" unless method == "GET" && endpoint == "/proxies"

      [200, JSON.generate("proxies" => {
        "Main" => {
          "type" => "Selector", "now" => "New Node", "all" => ["New Node"]
        },
        "AI" => {
          "type" => "Selector", "now" => "Taiwan", "all" => ["Taiwan", "Japan"]
        }
      })]
    end

    ClaudeEasy.stub(:runtime_health_healthy?, lambda { |_requester, **options|
      options.fetch(:selections)
      health_checked = true
      true
    }) do
      refute ClaudeEasy.wait_for_clashx_safe_runtime(
        identity, selections: { "Main" => "Old Node", "AI" => "Taiwan" },
        expected_tun: :enabled, requester_factory: -> { requester },
        profile_match_reader: ->(_requester) { true }, process_reader: -> { identity },
        sleeper: ->(_seconds) {}, attempts: 1
      )
    end

    refute health_checked
  end

  def test_clashx_runtime_wait_retries_after_a_failed_health_check
    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    health = [false, true]
    sleeps = 0
    requester = ->(*_arguments) { [200, "{}"] }

    ClaudeEasy.stub(:runtime_restorable_selections, {}) do
      ClaudeEasy.stub(:restore_runtime_selections, true) do
        ClaudeEasy.stub(:runtime_health_healthy?, ->(*_arguments, **_options) { health.shift }) do
          assert ClaudeEasy.wait_for_clashx_safe_runtime(
            identity, reload_receipt: {}, selections: {}, expected_tun: :ignore,
            requester_factory: -> { requester }, reload_receipt_reader: ->(_receipt) { true },
            profile_match_reader: ->(_requester) { true }, process_reader: -> { identity },
            sleeper: ->(_seconds) { sleeps += 1 }, attempts: 2
          )
        end
      end
    end
    assert_equal 1, sleeps
  end


  def test_safe_update_preserves_selections_when_only_group_and_node_names_are_localized
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original, candidate = localized_selection_configs
      original_bytes = YAML.dump(original)
      candidate_bytes = YAML.dump(candidate)
      File.binwrite(profile, candidate_bytes)
      stat = File.stat(profile)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "Taiwan 1", "AI" => "Main" }
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: candidate_bytes, candidate: candidate_bytes }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      result = {
        path: profile, rollback_bytes: original_bytes,
        patched_digest: Digest::SHA256.hexdigest(candidate_bytes),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      restored = nil

      activated = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { true },
        runtime_waiter: lambda { |_identity, **options|
          restored = options.fetch(:selections)
          true
        },
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      assert_equal true, activated[:reloaded]
      assert_equal({ "主节点" => "台湾 1", "人工智能" => "主节点" }, restored)
    end
  end

  def test_safe_update_localizes_a_renamed_node_inside_the_same_group
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = Marshal.load(Marshal.dump(base_config))
      original.fetch("proxy-groups").first["use"] = ["airport"]
      candidate = Marshal.load(Marshal.dump(original))
      old_name = candidate.fetch("proxies").first.fetch("name")
      new_name = "Taiwan Home"
      candidate.fetch("proxies").first["name"] = new_name
      candidate.fetch("proxy-groups").each do |group|
        group["proxies"] = Array(group["proxies"]).map { |name| name == old_name ? new_name : name }
      end
      File.binwrite(profile, YAML.dump(candidate))
      selections = { "Main" => old_name, "AI" => "Main" }

      assert_equal(
        selections,
        ClaudeEasy.runtime_selections_for_profile(selections, profile, preserve_all: true)
      )
      assert_equal(
        { "Main" => new_name, "AI" => "Main" },
        ClaudeEasy.localized_runtime_selections(selections, YAML.dump(original), profile)
      )

      candidate_bytes = YAML.dump(candidate)
      stat = File.stat(profile)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled, selections: selections
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: candidate_bytes, candidate: candidate_bytes }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      result = {
        path: profile, rollback_bytes: YAML.dump(original),
        patched_digest: Digest::SHA256.hexdigest(candidate_bytes),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      restored = nil
      activated = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { true },
        runtime_waiter: lambda { |_identity, **options|
          restored = options.fetch(:selections)
          true
        },
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      assert_equal true, activated.fetch(:reloaded)
      assert_equal({ "Main" => new_name, "AI" => "Main" }, restored)
    end
  end

  def test_safe_update_keeps_a_provider_selection_when_it_cannot_be_localized
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      config = {
        "proxy-groups" => [
          { "name" => "Main", "type" => "select", "use" => ["airport"] }
        ]
      }
      File.binwrite(profile, YAML.dump(config))
      selections = { "Main" => "Provider Node" }

      assert_nil ClaudeEasy.localized_runtime_selections(
        selections, YAML.dump(config), profile
      )
      assert_equal selections, ClaudeEasy.runtime_selections_for_profile(
        selections, profile, preserve_all: true
      )
      assert_equal selections, ClaudeEasy.provider_runtime_selections(
        selections, YAML.dump(config), profile
      )
    end
  end

  def test_safe_update_combines_provider_and_explicit_group_selections
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      config = {
        "proxy-groups" => [
          { "name" => "Main", "type" => "select", "use" => ["airport"] },
          { "name" => "AI", "type" => "select", "proxies" => ["Main"] }
        ]
      }
      File.binwrite(profile, YAML.dump(config))
      selections = { "Main" => "Provider Node", "AI" => "Main" }

      assert_nil ClaudeEasy.localized_runtime_selections(
        selections, YAML.dump(config), profile
      )
      assert_equal selections, ClaudeEasy.provider_runtime_selections(
        selections, YAML.dump(config), profile
      )
    end

    ClaudeEasy.stub(:load_yaml, ->(*_arguments) { raise RuntimeError, "injected" }) do
      assert_nil ClaudeEasy.provider_runtime_selections({}, "ignored", "ignored")
    end
  end

  def test_safe_update_does_not_load_a_mixed_group_after_its_selected_inline_node_was_removed
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original_config = base_config
      original_config.fetch("proxy-groups").first["use"] = ["airport"]
      selected = original_config.fetch("proxies").first.fetch("name")
      candidate_config = Marshal.load(Marshal.dump(original_config))
      candidate_config.fetch("proxies").shift
      candidate_config.fetch("proxy-groups").each do |group|
        group["proxies"] = Array(group["proxies"]).reject { |name| name == selected }
      end
      original = YAML.dump(original_config)
      candidate = YAML.dump(candidate_config)
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => selected, "AI" => "Main" }
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: candidate, candidate: candidate }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      result = {
        path: profile, rollback_bytes: original,
        patched_digest: Digest::SHA256.hexdigest(candidate),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      reloads = 0

      activated = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { reloads += 1; true },
        runtime_waiter: ->(*_arguments, **_options) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      assert_equal :reload_failed_rolled_back, activated.fetch(:status)
      assert_equal 0, reloads
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_safe_update_rejects_candidate_that_cannot_preserve_every_previous_selection
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config)
      candidate_config = base_config.merge(
        "proxy-groups" => [
          { "name" => "English Main", "type" => "select", "proxies" => ["Taiwan"] }
        ]
      )
      candidate = YAML.dump(candidate_config)
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "台湾家宽 01" }
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: candidate, candidate: candidate }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      result = {
        path: profile, rollback_bytes: original,
        patched_digest: Digest::SHA256.hexdigest(candidate),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      reloads = 0

      activated = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { reloads += 1; true },
        runtime_waiter: ->(*_arguments, **_options) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      assert_equal :reload_failed_rolled_back, activated.fetch(:status)
      assert_equal 0, reloads
      assert_equal original.b, File.binread(profile)
    end
  end

  def test_safe_update_rejects_candidate_without_any_previous_selector
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      config = base_config.merge(
        "proxy-groups" => [
          { "name" => "Automatic", "type" => "url-test", "proxies" => ["台湾家宽 01"] }
        ]
      )
      File.write(profile, YAML.dump(config))

      assert_nil ClaudeEasy.runtime_selections_for_profile(
        { "Main" => "台湾家宽 01" }, profile, preserve_all: true
      )
    end
  end

  def test_profile_transaction_allows_each_native_reload_phase_once_per_client_process
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      File.binwrite(profile, "original")
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [directory],
        runtime_checkpoint: { path: File.realpath(profile), expected_tun: :enabled, selections: {} },
        activation_identity: identity
      )
      candidate_bytes = transaction.fetch(:candidate_bytes).dup

      assert ClaudeEasy.mark_profile_transaction_activation(transaction, :update, identity)
      assert_equal candidate_bytes, transaction.fetch(:candidate_bytes)
      refute ClaudeEasy.mark_profile_transaction_activation(transaction, :update, identity)
      assert ClaudeEasy.mark_profile_transaction_activation(transaction, :rollback, identity)
      assert_equal candidate_bytes, transaction.fetch(:candidate_bytes)
      refute ClaudeEasy.mark_profile_transaction_activation(transaction, :rollback, identity)

      restarted = identity.merge(pid: 54_321, started: "later")
      assert ClaudeEasy.mark_profile_transaction_activation(transaction, :rollback, restarted)
      refute ClaudeEasy.mark_profile_transaction_activation(transaction, :rollback, restarted)
    end
  end

  def test_profile_transaction_recovers_an_incomplete_activation_tail_without_resending
    ["{\"Version\":1", "\xFF".b].each do |tail|
      Dir.mktmpdir do |directory|
        profile = File.join(directory, "active.yaml")
        backup_root = File.join(directory, "backups")
        File.binwrite(profile, "original")
        identity = {
          pid: 12_345, started: "same",
          executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
        }
        transaction = ClaudeEasy.prepare_profile_transaction(
          [{ path: profile, original: "original", candidate: "candidate" }],
          backup_root, roots: [directory],
          runtime_checkpoint: {
            path: File.realpath(profile), expected_tun: :enabled, selections: {}
          }, activation_identity: identity
        )
        File.binwrite(profile, "candidate")
        File.open(transaction.fetch(:path), "ab") { |file| file.write(tail) }

        recovered = ClaudeEasy.recover_profile_transaction(
          backup_root, roots: [directory], keep_transaction: true
        )

        assert_equal "original", File.binread(profile)
        assert recovered.fetch(:activation_state).fetch(:update_requested)
        assert recovered.fetch(:activation_state).fetch(:rollback_requested)
        assert File.binread(transaction.fetch(:path)).end_with?("\n")
        refute ClaudeEasy.mark_profile_transaction_activation(recovered, :rollback, identity)
      end
    end
  end

  def test_profile_transaction_keeps_a_complete_unflushed_activation_event_conservative
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      File.binwrite(profile, "original")
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [directory],
        runtime_checkpoint: {
          path: File.realpath(profile), expected_tun: :enabled, selections: {}
        }, activation_identity: identity
      )
      activation = ClaudeEasy.serialized_activation_state(identity, update_requested: true)
      event = JSON.generate("Version" => 1, "Activation" => activation) + "\n"
      File.open(transaction.fetch(:path), "ab") { |file| file.write(event) }

      recovered = ClaudeEasy.recover_profile_transaction(
        backup_root, roots: [directory], keep_transaction: true
      )

      assert recovered.fetch(:activation_state).fetch(:update_requested)
      refute recovered.fetch(:activation_state).fetch(:rollback_requested)
      refute ClaudeEasy.mark_profile_transaction_activation(recovered, :update, identity)
    end
  end

  def test_runtime_checkpoint_detects_user_selection_and_tun_changes
    checkpoint = {
      path: "/profiles/active.yaml", expected_tun: :disabled,
      selections: { "Main" => "Taiwan" }
    }
    requester = lambda do |_method, endpoint, _body = nil|
      case endpoint
      when "/proxies"
        [200, JSON.generate("proxies" => {
          "Main" => { "type" => "Selector", "now" => "Japan" }
        })]
      when "/configs"
        [200, JSON.generate("tun" => { "enable" => true })]
      else
        flunk("unexpected runtime request: #{endpoint}")
      end
    end

    refute ClaudeEasy.runtime_checkpoint_current?(checkpoint, requester: requester)
  end

  def test_runtime_recovery_state_uses_only_controller_graph_differences
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = base_config
      candidate = Marshal.load(Marshal.dump(original))
      candidate["proxy-groups"] << {
        "name" => "Managed", "type" => "select", "proxies" => ["台湾家宽 01"]
      }
      File.binwrite(profile, YAML.dump(original))
      requester_for = lambda do |config|
        proxies = Array(config["proxies"]).to_h do |proxy|
          [proxy.fetch("name"), { "type" => proxy.fetch("type") }]
        end
        Array(config["proxy-groups"]).each do |group|
          runtime_type = group["type"].to_s.casecmp("relay").zero? ? "Relay" : "Selector"
          proxies[group.fetch("name")] = {
            "type" => runtime_type, "all" => Array(group["proxies"]),
            "now" => Array(group["proxies"]).first
          }
        end
        lambda do |_method, endpoint, _body = nil|
          case endpoint
          when "/proxies" then [200, JSON.generate("proxies" => proxies)]
          when "/providers/proxies" then [200, JSON.generate("providers" => {})]
          else flunk("unexpected recovery-state request: #{endpoint}")
          end
        end
      end

      assert_equal :candidate, ClaudeEasy.runtime_loaded_profile_state(
        requester_for.call(candidate), profile, YAML.dump(candidate)
      )
      assert_equal :restored, ClaudeEasy.runtime_loaded_profile_state(
        requester_for.call(original), profile, YAML.dump(candidate)
      )

      graph_identical_candidate = Marshal.load(Marshal.dump(original))
      graph_identical_candidate["profile"] = { "store-selected" => true }
      assert_equal :unknown, ClaudeEasy.runtime_loaded_profile_state(
        requester_for.call(graph_identical_candidate), profile,
        YAML.dump(graph_identical_candidate)
      )

      relay_candidate = Marshal.load(Marshal.dump(original))
      relay_candidate["proxy-groups"] << {
        "name" => "Chain", "type" => "relay", "proxies" => ["台湾家宽 01"]
      }
      assert_equal :candidate, ClaudeEasy.runtime_loaded_profile_state(
        requester_for.call(relay_candidate), profile, YAML.dump(relay_candidate)
      )

      provider_original = Marshal.load(Marshal.dump(original))
      provider_original["proxy-providers"] = { "airport" => { "type" => "http" } }
      File.binwrite(profile, YAML.dump(provider_original))
      provider_candidate = Marshal.load(Marshal.dump(original))
      provider_failure = lambda do |_method, endpoint, _body = nil|
        if endpoint == "/proxies"
          requester_for.call(provider_original).call("GET", endpoint, nil)
        else
          [503, ""]
        end
      end
      assert_equal :unknown, ClaudeEasy.runtime_loaded_profile_state(
        provider_failure, profile, YAML.dump(provider_candidate)
      )
      malformed_provider = lambda do |method, endpoint, body = nil|
        next [200, JSON.generate("providers" => [])] if endpoint == "/providers/proxies"

        requester_for.call(provider_original).call(method, endpoint, body)
      end
      assert_equal :unknown, ClaudeEasy.runtime_loaded_profile_state(
        malformed_provider, profile, YAML.dump(provider_candidate)
      )

      actual = {
        proxies: ["candidate"], providers: ["airport"],
        groups: { "Main" => ["new"] }
      }
      expected = {
        proxies: ["candidate"], providers: ["airport"],
        groups: { "Main" => ["new"] }
      }
      alternative = {
        proxies: ["original"], providers: [],
        groups: { "Main" => ["old"] }
      }
      assert ClaudeEasy.runtime_identity_matches_difference?(actual, expected, alternative)
      refute ClaudeEasy.runtime_identity_matches_difference?(actual, alternative, expected)

      assert_nil ClaudeEasy.profile_runtime_identity(File.join(directory, "missing.yaml"))
      ClaudeEasy.stub(:profile_runtime_identity, ->(_path) { raise IOError }) do
        assert_equal :unknown, ClaudeEasy.runtime_loaded_profile_state(
          requester_for.call(original), profile, YAML.dump(candidate)
        )
      end
      ClaudeEasy.stub(:runtime_selections, ->(_requester) { raise IOError }) do
        refute ClaudeEasy.runtime_checkpoint_current?(
          { path: profile, selections: {}, expected_tun: :ignore },
          requester: requester_for.call(original)
        )
      end
    end
  end

  def test_current_runtime_loaded_profile_state_uses_the_live_requester
    requester = Object.new
    classifier = lambda do |actual_requester, path, bytes|
      assert_same requester, actual_requester
      assert_equal "/tmp/restored.yaml", path
      assert_equal "candidate", bytes
      :candidate
    end

    ClaudeEasy.stub(:current_runtime_requester, requester) do
      ClaudeEasy.stub(:runtime_loaded_profile_state, classifier) do
        assert_equal :candidate, ClaudeEasy.current_runtime_loaded_profile_state(
          "/tmp/restored.yaml", "candidate"
        )
      end
    end
  end

  def test_recovered_profile_runtime_keeps_a_user_selection_changed_after_the_crash
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      saved_checkpoint = {
        path: File.realpath(profile), expected_tun: :disabled,
        selections: { "Main" => "台湾家宽 01" }
      }
      selected = "日本家宽 01"
      restored = []
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => {
              "type" => "Selector", "now" => selected,
              "all" => ["台湾家宽 01", "日本家宽 01", "美国家宽 01"]
            },
            "AI" => { "type" => "Selector", "now" => "Main", "all" => ["Main"] }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => true })]
        when ["PUT", "/configs?force=true"]
          [204, ""]
        else
          if method == "PUT" && endpoint.start_with?("/proxies/")
            restored << JSON.parse(body).fetch("name")
            [204, ""]
          elsif method == "PATCH" && endpoint == "/configs"
            [204, ""]
          elsif method == "POST"
            [204, ""]
          else
            flunk("unexpected recovery request: #{method} #{endpoint}")
          end
        end
      end

      healthy_selections = nil
      health = lambda do |_requester, selections:, **_options|
        healthy_selections = selections
        true
      end
      recovered = ClaudeEasy.stub(:runtime_health_healthy?, health) do
        ClaudeEasy.reload_recovered_profile_runtime(
          [{ path: profile, active: true }], require_tun: :preserve,
          requester: requester, runtime_checkpoint: saved_checkpoint,
          runtime_profile_state_reader: ->(_path, _candidate) { :restored }
        )
      end

      assert recovered
      assert_equal({ "Main" => selected, "AI" => "Main" }, healthy_selections)
      assert_empty restored
    end
  end

  def test_recovered_profile_runtime_restores_saved_selection_after_candidate_reset
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      checkpoint = {
        path: File.realpath(profile), expected_tun: :disabled,
        selections: { "Main" => "台湾家宽 01" }
      }
      current_selection = "日本家宽 01"
      restored = []
      requester = lambda do |method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => {
              "type" => "Selector", "now" => current_selection,
              "all" => ["台湾家宽 01", "日本家宽 01", "美国家宽 01"]
            },
            "AI" => { "type" => "Selector", "now" => "Main", "all" => ["Main"] }
          })]
        when ["GET", "/configs"]
          [200, JSON.generate("tun" => { "enable" => false })]
        when ["PUT", "/configs?force=true"]
          [204, ""]
        else
          if method == "PUT" && endpoint.start_with?("/proxies/")
            current_selection = JSON.parse(body).fetch("name")
            restored << current_selection
            [204, ""]
          elsif method == "PATCH" && endpoint == "/configs"
            [204, ""]
          else
            flunk("unexpected recovery request: #{method} #{endpoint}")
          end
        end
      end
      transaction = {
        candidate_bytes: { File.realpath(profile) => YAML.dump(base_config.merge("marker" => "candidate")) }
      }

      recovered = ClaudeEasy.stub(:runtime_health_healthy?, true) do
        ClaudeEasy.reload_recovered_profile_runtime(
          [{ path: profile, active: true }], require_tun: :preserve,
          requester: requester, runtime_checkpoint: checkpoint, transaction: transaction,
          runtime_profile_state_reader: ->(_path, _candidate) { :candidate }
        )
      end

      assert recovered
      assert_includes restored, "台湾家宽 01"
      refute_includes restored, "日本家宽 01"
    end
  end

  def test_recovered_safe_update_restores_saved_selection_after_candidate_reset
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :disabled,
        selections: { "Main" => "台湾家宽 01" }
      }
      transaction = {
        candidate_bytes: { File.realpath(profile) => YAML.dump(base_config.merge("marker" => "candidate")) },
        original_snapshots: {
          File.realpath(profile) => {
            identity: [File.stat(profile).dev, File.stat(profile).ino],
            bytes: File.binread(profile)
          }
        }
      }
      waited_selections = nil
      checkpoint_checks = [false, true]
      dispatch_checkpoint = checkpoint.merge(selections: { "Main" => "日本家宽 01" })

      recovered = ClaudeEasy.stub(:mark_profile_transaction_activation, true) do
        ClaudeEasy.reload_recovered_safe_update_runtime(
          [{ path: profile }], 1, "active", runtime_checkpoint: checkpoint,
          transaction: transaction, client_identity: identity,
          runtime_checkpoint_checker: ->(_current) { checkpoint_checks.shift },
          runtime_checkpoint_reader: ->(_path) { dispatch_checkpoint },
          runtime_profile_state_reader: ->(_path, _candidate) { :candidate },
          native_reloader: ->(_current) { true },
          runtime_waiter: lambda do |_current, **options|
            waited_selections = options.fetch(:selections)
            true
          end,
          reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
        )
      end

      assert recovered
      assert_equal({ "Main" => "台湾家宽 01" }, waited_selections)
    end
  end

  def test_runtime_dispatches_preserve_user_changes_after_checkpoint_capture
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "new"))
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :disabled,
        selections: { "Main" => "台湾家宽 01" }
      }
      result = {
        path: profile, rollback_bytes: original,
        patched_digest: Digest::SHA256.hexdigest(candidate),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      request_count = 0
      requester = ->(*_arguments) { request_count += 1; [204, ""] }

      ordinary = ClaudeEasy.stub(:runtime_checkpoint_current?, false) do
        ClaudeEasy.activate_updated_profile(
          result, requester: requester, runtime_checkpoint: checkpoint
        )
      end
      assert_equal :reload_failed_rolled_back, ordinary.fetch(:status)
      assert_equal 0, request_count
      assert_equal original.b, File.binread(profile)

      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      result = result.merge(patched_identity: [stat.dev, stat.ino])
      native_reloads = 0
      safe = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint,
        runtime_checkpoint_checker: ->(_current) { false },
        native_reloader: ->(_current) { native_reloads += 1; true },
        runtime_waiter: ->(*_arguments, **_options) { true },
        reload_snapshot_reader: -> { flunk "opened a reload receipt after user selection changed" }
      )
      assert_equal :reload_failed_rolled_back, safe.fetch(:status)
      assert_equal 0, native_reloads
      assert_equal original.b, File.binread(profile)

      recovered_selections = nil
      current_checkpoint = checkpoint.merge(selections: { "Main" => "日本家宽 01" })
      recovery_checks = [false, true]
      recovered = ClaudeEasy.stub(:capture_runtime_checkpoint, current_checkpoint) do
        ClaudeEasy.reload_recovered_safe_update_runtime(
          [{ path: profile }], 1, "active", runtime_checkpoint: checkpoint,
          transaction: transaction, client_identity: identity,
          runtime_checkpoint_checker: ->(_current) { recovery_checks.shift },
          runtime_profile_state_reader: ->(_path, _candidate) { :restored },
          native_reloader: ->(_current) { native_reloads += 1; true },
          runtime_waiter: lambda do |_current, **options|
            recovered_selections = options.fetch(:selections)
            true
          end,
          reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
        )
      end
      assert recovered
      assert_equal({ "Main" => "日本家宽 01" }, recovered_selections)
      assert_equal 1, native_reloads
    end
  end

  def test_runtime_dispatches_recheck_checkpoint_at_the_send_boundary
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "new"))
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :disabled,
        selections: { "Main" => "台湾家宽 01" }
      }
      result = {
        path: profile, rollback_bytes: original,
        patched_digest: Digest::SHA256.hexdigest(candidate),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }

      controller_checks = [true, false]
      controller_requests = 0
      ordinary = ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
        ClaudeEasy.stub(:runtime_checkpoint_current?, ->(_checkpoint, **_options) { controller_checks.shift }) do
          ClaudeEasy.activate_updated_profile(
            result, requester: ->(*) { controller_requests += 1; [204, ""] },
            runtime_checkpoint: checkpoint
          )
        end
      end
      assert_equal :reload_failed_rolled_back, ordinary.fetch(:status)
      assert_equal 0, controller_requests

      recovery_checks = [true, false]
      controller_recovery = ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
        ClaudeEasy.stub(:runtime_checkpoint_current?, ->(_checkpoint, **_options) { recovery_checks.shift }) do
          ClaudeEasy.reload_recovered_profile_runtime(
            [{ path: profile, active: true }], require_tun: :preserve,
            requester: ->(*) { controller_requests += 1; [204, ""] },
            runtime_checkpoint: checkpoint
          )
        end
      end
      refute controller_recovery
      assert_equal 0, controller_requests

      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      result = result.merge(patched_identity: [stat.dev, stat.ino])
      rollback_requests = 0
      rollback_status = ClaudeEasy.stub(:runtime_checkpoint_current?, false) do
        ClaudeEasy.rollback_after_reload_failure(
          result, ->(*) { rollback_requests += 1; [204, ""] }, profile,
          selections: checkpoint.fetch(:selections),
          expected_tun: checkpoint.fetch(:expected_tun), runtime_checkpoint: checkpoint
        )
      end
      assert_equal :reload_failed_restore_pending, rollback_status
      assert_equal 0, rollback_requests

      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      result = result.merge(patched_identity: [stat.dev, stat.ino])
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: candidate, candidate: candidate }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      update_checks = [true, false]
      native_reloads = 0
      updated = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint,
        runtime_checkpoint_checker: ->(_current) { update_checks.shift },
        native_reloader: ->(_current) { native_reloads += 1; true },
        runtime_waiter: ->(*_arguments, **_options) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )
      assert_equal :reload_failed_rolled_back, updated.fetch(:status)
      assert_equal 0, native_reloads

      recovery_checks = [true, false]
      recovered = ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
        ClaudeEasy.stub(:mark_profile_transaction_activation, true) do
          ClaudeEasy.reload_recovered_safe_update_runtime(
            [{ path: profile }], 1, "active", runtime_checkpoint: checkpoint,
            transaction: transaction, client_identity: identity,
            runtime_checkpoint_checker: ->(_current) { recovery_checks.shift },
            native_reloader: ->(_current) { native_reloads += 1; true },
            runtime_waiter: ->(*_arguments, **_options) { true },
            reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
          )
        end
      end
      refute recovered
      assert_equal 0, native_reloads
    end
  end

  def test_safe_update_uses_one_client_native_reload_and_no_controller_reload
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "original"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = { path: File.realpath(profile), expected_tun: :enabled, selections: {} }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: candidate, candidate: candidate }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      result = {
        path: profile, rollback_bytes: original,
        patched_digest: Digest::SHA256.hexdigest(candidate),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      reloads = []

      activated = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(current) { reloads << current; true },
        runtime_waiter: ->(*_arguments, **_options) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      assert_equal true, activated.fetch(:reloaded)
      assert_equal [identity], reloads
      assert_equal candidate.b, File.binread(profile)
    end
  end

  def test_default_safe_update_wires_the_client_native_reload_path
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      File.binwrite(profile, YAML.dump(base_config.merge("subscription-marker" => "old")))
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :ignore,
        selections: { "Main" => "台湾家宽 01", "AI" => "Main" }
      }
      reloads = 0
      checkpoint_requirement = nil
      checkpoint_reader = lambda do |_path, require_tun:, **_options|
        checkpoint_requirement = require_tun
        checkpoint
      end

      result = ClaudeEasy.stub(:capture_runtime_checkpoint, checkpoint_reader) do
        ClaudeEasy.stub(:runtime_checkpoint_current?, true) do
          ClaudeEasy.safe_update_all(
            targets: [{ name: "friend", path: profile, url: "https://subscriptions.invalid/friend" }],
            policy: @policy, backup_root: backup_root, usage_profile: 1,
            selected_name: "friend",
            fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
            validator: ->(_candidate) { true }, client_identity_reader: -> { identity },
            native_reloader: ->(_current) { reloads += 1; true },
            runtime_waiter: ->(*_arguments, **_options) { true },
            reload_snapshot_reader: -> { { "log" => [1, 2, reloads] } }
          )
        end
      end

      assert_equal :updated, result.fetch(:status), result.inspect
      assert_equal :preserve, checkpoint_requirement
      assert_equal 1, reloads
      assert_equal "new", ClaudeEasy.load_yaml(File.read(profile)).fetch("subscription-marker")
    end
  end

  def test_safe_update_failure_restores_file_and_attempts_native_rollback_only_once
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "original"))
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = { path: File.realpath(profile), expected_tun: :enabled, selections: {} }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: candidate, candidate: candidate }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      result = {
        path: profile, rollback_bytes: original,
        patched_digest: Digest::SHA256.hexdigest(candidate),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      reloads = 0
      waits = [false, true]
      native = ->(_current) { reloads += 1; true }
      waiter = ->(*_arguments, **_options) { waits.shift }

      activated = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint, runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: native,
        runtime_waiter: waiter, reload_snapshot_reader: -> { { "log" => [1, 2, reloads] } }
      )

      assert_equal :reload_failed_rolled_back, activated.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 2, reloads

      repeated = ClaudeEasy.activate_safe_updated_profile(
        result, transaction: transaction, client_identity: identity,
        runtime_checkpoint: checkpoint,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { flunk "same process must not reload again" },
        runtime_waiter: waiter, reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )
      assert_equal :reload_failed_restore_pending, repeated.fetch(:status)
    end
  end

  def test_safe_update_closes_reload_receipts_when_activation_is_already_used
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      bytes = YAML.dump(base_config)
      File.binwrite(profile, bytes)
      stat = File.stat(profile)
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = { path: File.realpath(profile), expected_tun: :ignore, selections: {} }
      result = {
        path: profile, rollback_bytes: bytes,
        patched_digest: Digest::SHA256.hexdigest(bytes),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      closed = []

      ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
        ClaudeEasy.stub(:mark_profile_transaction_activation, false) do
          ClaudeEasy.stub(:close_clashx_reload_receipt, ->(receipt) { closed << receipt; true }) do
            activated = ClaudeEasy.activate_safe_updated_profile(
              result, transaction: {}, client_identity: identity,
              runtime_checkpoint: checkpoint,
              runtime_checkpoint_checker: ->(_current) { true },
              reload_snapshot_reader: -> { :update_receipt }
            )
            assert_equal :reload_failed_restore_pending, activated.fetch(:status)
          end
        end
      end
      assert_equal [:update_receipt], closed
    end
  end

  def test_safe_update_closes_rollback_receipt_when_rollback_activation_is_already_used
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      candidate = YAML.dump(base_config)
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.binwrite(profile, candidate)
      stat = File.stat(profile)
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = { path: File.realpath(profile), expected_tun: :ignore, selections: {} }
      result = {
        path: profile, rollback_bytes: original,
        patched_digest: Digest::SHA256.hexdigest(candidate),
        patched_identity: [stat.dev, stat.ino], patched_path: File.realpath(profile)
      }
      phases = [true, false]
      receipts = [:update_receipt, :rollback_receipt]
      closed = []

      ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
        ClaudeEasy.stub(:mark_profile_transaction_activation, ->(*_arguments) { phases.shift }) do
          ClaudeEasy.stub(:close_clashx_reload_receipt, ->(receipt) { closed << receipt; true }) do
            activated = ClaudeEasy.activate_safe_updated_profile(
              result, transaction: {}, client_identity: identity,
              runtime_checkpoint: checkpoint,
              runtime_checkpoint_checker: ->(_current) { true },
              native_reloader: ->(_current) { false },
              reload_snapshot_reader: -> { receipts.shift }
            )
            assert_equal :reload_failed_restore_pending, activated.fetch(:status)
          end
        end
      end
      assert_equal [:update_receipt, :rollback_receipt], closed
    end
  end


  def test_pending_safe_update_recovery_rechecks_runtime_without_repeating_native_reload
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      File.binwrite(profile, YAML.dump(base_config))
      identity = { pid: 12_345, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "台湾家宽 01", "AI" => "Main" }
      }
      bytes = File.binread(profile)
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: bytes, candidate: bytes }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      reloads = 0
      options = {
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { reloads += 1; true },
        runtime_waiter: ->(*_arguments, **_keywords) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, reloads] } }
      }

      assert ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )
      assert ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )
      assert_equal 1, reloads
    end
  end

  def test_pending_safe_update_recovery_keeps_different_candidate_runtime_pending
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config)
      candidate = YAML.dump(base_config.merge("subscription-marker" => "candidate"))
      File.binwrite(profile, original)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "台湾家宽 01", "AI" => "Main" }
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: candidate }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      reloads = 0
      options = {
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { reloads += 1; true },
        runtime_waiter: ->(*_arguments, **_keywords) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, reloads] } }
      }

      assert ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )
      refute ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )
      assert_equal 1, reloads
    end
  end

  def test_pending_safe_update_recovery_rechecks_the_restored_file_after_runtime_validation
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "台湾家宽 01", "AI" => "Main" }
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: original }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      options = {
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { true },
        runtime_waiter: ->(*_arguments, **_keywords) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      }
      assert ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )

      options[:runtime_waiter] = lambda do |*_arguments, **_keywords|
        File.binwrite(profile, YAML.dump(base_config.merge("external-change" => true)))
        true
      end
      refute ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active", **options
      )
    end
  end

  def test_safe_update_recovery_rechecks_the_restored_file_after_first_rollback_event
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "台湾家宽 01", "AI" => "Main" }
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: original }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      reloads = 0

      restored = ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active",
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { reloads += 1; true },
        runtime_waiter: lambda do |*_arguments, **_keywords|
          File.binwrite(profile, YAML.dump(base_config.merge("external-change" => true)))
          true
        end,
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      refute restored
      assert_equal 1, reloads
    end
  end

  def test_safe_update_recovery_rejects_a_same_byte_external_replacement_before_rollback
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      original = YAML.dump(base_config)
      File.binwrite(profile, original)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      checkpoint = {
        path: File.realpath(profile), expected_tun: :enabled,
        selections: { "Main" => "台湾家宽 01", "AI" => "Main" }
      }
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: original, candidate: original }],
        File.join(directory, "backups"), roots: [directory],
        runtime_checkpoint: checkpoint, activation_identity: identity
      )
      replacement = File.join(directory, "replacement.yaml")
      File.binwrite(replacement, original)
      File.rename(replacement, profile)
      reloads = 0

      restored = ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: profile }], 1, "active",
        transaction: transaction, client_identity: identity,
        runtime_checkpoint_checker: ->(_current) { true },
        native_reloader: ->(_current) { reloads += 1; true },
        runtime_waiter: ->(*_arguments, **_keywords) { true },
        reload_snapshot_reader: -> { { "log" => [1, 2, 3] } }
      )

      refute restored
      assert_equal 0, reloads
    end
  end

  def test_native_and_runtime_helpers_fail_closed_on_system_errors
    assert_nil ClaudeEasy.clashx_running_identity(runner: ->(*_arguments) { raise IOError })

    identity = {
      pid: 12_345, started: "same",
      executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
    }
    status = Struct.new(:success?).new(true)
    process_line = "  12345 Thu Aug 20 00:14:18 2026 #{identity.fetch(:executable)}\n"
    assert_equal identity.merge(started: "Thu Aug 20 00:14:18 2026"), ClaudeEasy.clashx_running_identity(
      runner: ->(*_arguments) { [process_line, "", status] }
    )
    refute ClaudeEasy.request_clashx_native_reload(
      identity, sender: ->(*_arguments) { raise IOError }, process_reader: -> { identity }
    )
    refute ClaudeEasy.wait_for_clashx_safe_runtime(
      identity, selections: {}, expected_tun: :disabled,
      requester_factory: -> { raise IOError },
      profile_match_reader: ->(_requester) { true },
      process_reader: -> { identity }, attempts: 1
    )
    assert_nil ClaudeEasy.runtime_restorable_selections(
      ->(*_arguments) { raise IOError }, { "Main" => "Taiwan" }
    )
    assert_nil ClaudeEasy.stub(:controller_socket, nil) { ClaudeEasy.current_runtime_requester }
    response = ClaudeEasy.stub(:controller_socket, "socket") do
      ClaudeEasy.stub(:controller_request, ->(*arguments) { arguments }) do
        ClaudeEasy.current_runtime_requester.call("GET", "/configs", nil)
      end
    end
    assert_equal ["socket", "GET", "/configs", nil], response

    Dir.mktmpdir do |directory|
      assert_nil ClaudeEasy.clashx_reload_snapshot(log_root: File.join(directory, "missing"))
      refute ClaudeEasy.clashx_reload_completed_since?({}, log_root: directory)
    end

    ClaudeEasyAppleEvents.stub(:AECreateDesc, ->(*_arguments) { raise IOError }) do
      ClaudeEasyAppleEvents.stub(:AEDisposeDesc, ->(*_arguments) { 0 }) do
        refute ClaudeEasyAppleEvents.send_get_url(12_345, "clash://update-config")
      end
    end
  end

  def test_runtime_identity_and_safe_update_comparison_error_boundaries
    actual = {
      proxies: ["New"], providers: [],
      groups: { "Kept" => ["Shared"] }
    }
    expected = {
      proxies: ["New"], providers: [],
      groups: { "Kept" => ["Shared"] }
    }
    previous = {
      proxies: ["Old"], providers: [],
      groups: { "Removed" => ["Old"], "Kept" => ["Old", "Shared"] }
    }
    assert ClaudeEasy.runtime_excludes_previous_profile_entries?(actual, expected, previous)

    ClaudeEasy.stub(:load_yaml, ->(*_arguments) { raise IOError, "injected" }) do
      assert_nil ClaudeEasy.profile_runtime_identity_from_bytes("{}", "fixture")
      refute ClaudeEasy.safe_update_runtime_equivalent?({ bytes: "{}" }, "fixture", "{}")
    end
    ClaudeEasy.stub(:regular_file_snapshot_once, ->(*_arguments) { raise IOError, "injected" }) do
      refute ClaudeEasy.safe_update_runtime_snapshot_current?("fixture", {})
    end
  end

  def test_localized_selection_rejects_a_group_with_changed_identity_at_the_same_position
    original = {
      "proxies" => [{ "name" => "Node", "type" => "ss", "server" => "example", "port" => 443 }],
      "proxy-groups" => [
        { "name" => "Main", "type" => "select", "proxies" => ["Node"] },
        { "name" => "AI", "type" => "select", "proxies" => ["Node"], "interval" => 10 }
      ]
    }
    candidate = {
      "proxies" => [{ "name" => "节点", "type" => "ss", "server" => "example", "port" => 443 }],
      "proxy-groups" => [
        { "name" => "Main", "type" => "select", "proxies" => ["节点"] },
        { "name" => "人工智能", "type" => "select", "proxies" => ["节点"], "interval" => 20 }
      ]
    }

    Dir.mktmpdir do |directory|
      path = File.join(directory, "candidate.yaml")
      File.binwrite(path, YAML.dump(candidate))
      assert_nil ClaudeEasy.localized_runtime_selections(
        { "AI" => "Node" }, YAML.dump(original), path
      )
      assert_nil ClaudeEasy.localized_runtime_selections(
        { "AI" => "Node" }, YAML.dump(original), File.join(directory, "missing.yaml")
      )
    end
  end

  def test_localized_selection_rejects_a_changed_node_at_the_same_position
    original = {
      "proxies" => [
        { "name" => "A", "type" => "ss", "server" => "a.example", "port" => 443 },
        { "name" => "B", "type" => "ss", "server" => "b.example", "port" => 443 },
        { "name" => "C", "type" => "ss", "server" => "c.example", "port" => 443 }
      ],
      "proxy-groups" => [{ "name" => "Main", "type" => "select", "proxies" => %w[A B C] }]
    }
    candidate = {
      "proxies" => [
        { "name" => "甲", "type" => "ss", "server" => "other.example", "port" => 443 },
        { "name" => "乙", "type" => "ss", "server" => "b.example", "port" => 443 },
        { "name" => "丙", "type" => "ss", "server" => "c.example", "port" => 443 }
      ],
      "proxy-groups" => [{ "name" => "主节点", "type" => "select", "proxies" => %w[甲 乙 丙] }]
    }

    Dir.mktmpdir do |directory|
      path = File.join(directory, "candidate.yaml")
      File.binwrite(path, YAML.dump(candidate))
      assert_nil ClaudeEasy.localized_runtime_selections(
        { "Main" => "A" }, YAML.dump(original), path
      )
    end
  end

  def test_runtime_activation_covers_required_tun_and_fail_closed_paths
    Dir.mktmpdir do |directory|
      path = File.join(directory, "active.yaml")
      File.binwrite(path, YAML.dump(base_config))
      requester = ->(*_arguments) { [200, "{}"] }
      work_items = [{ path: path, active: true }]

      ClaudeEasy.stub(:runtime_selections, {}) do
        ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
          ClaudeEasy.stub(:reload_profile_runtime, true) do
            ClaudeEasy.stub(:runtime_health_healthy?, true) do
              assert ClaudeEasy.reload_recovered_profile_runtime(
                work_items, require_tun: true, requester: requester
              )
            end
          end
        end
      end

      result = {
        path: path, rollback_bytes: File.binread(path), patched_digest: "digest",
        patched_identity: [0, 0], patched_path: File.realpath(path)
      }
      checkpoint = { path: File.realpath(path), expected_tun: :disabled, selections: {} }
      transaction = { path: path }
      ClaudeEasy.stub(:profile_result_current?, true) do
        ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
          ClaudeEasy.stub(:rollback_before_runtime_reload, :rolled_back) do
            rejected = ClaudeEasy.activate_safe_updated_profile(
              result, transaction: transaction, client_identity: {},
              runtime_checkpoint: checkpoint, precommit_condition: -> { false },
              runtime_checkpoint_checker: ->(_current) { true }
            )
            assert_equal :rolled_back, rejected.fetch(:status)

            pending = ClaudeEasy.activate_safe_updated_profile(
              result, transaction: transaction, client_identity: {},
              runtime_checkpoint: checkpoint,
              runtime_checkpoint_checker: ->(_current) { true },
              reload_snapshot_reader: -> { raise IOError }
            )
            assert_equal :reload_failed_restore_pending, pending.fetch(:status)

            no_socket = ClaudeEasy.stub(:controller_socket, nil) do
              ClaudeEasy.activate_updated_profile(result)
            end
            assert_equal :rolled_back, no_socket.fetch(:status)
          end
        end
      end
      controller_failed = ClaudeEasy.stub(:profile_result_current?, true) do
        ClaudeEasy.stub(:controller_request, ->(*_arguments) { raise IOError }) do
          ClaudeEasy.activate_updated_profile(result, socket: "socket")
        end
      end
      assert_equal :reload_failed_rollback_conflict, controller_failed.fetch(:status)
    end
  end

  def test_profile_transaction_rejects_malformed_runtime_journals
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")
      root = ClaudeEasy.secure_backup_root!(backup_root)
      journal = ClaudeEasy.profile_transaction_path(root)
      File.binwrite(journal, "{\n")
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.recover_profile_transaction(root, roots: [directory])
      end
      File.unlink(journal)

      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.prepare_profile_transaction(
          [{ path: profile, original: "original", candidate: "candidate" }],
          backup_root, roots: [directory], activation_identity: { pid: 1 }
        )
      end

      File.binwrite(journal, "{\n")
      stat = File.stat(journal)
      transaction = {
        path: journal, bytes: File.binread(journal), identity: [stat.dev, stat.ino],
        targets: {}, runtime_checkpoint: nil, activation_state: nil
      }
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.mark_profile_transaction_activation(transaction, :update, { pid: 1 })
      end

      File.unlink(journal)
      valid = ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [directory]
      )
      state = JSON.parse(File.binread(valid.fetch(:path)))
      state.fetch("Items").first["CandidateBase64"] = "!"
      File.binwrite(valid.fetch(:path), JSON.generate(state) + "\n")
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])
      end
    end
  end

  def test_pending_safe_update_recovery_handles_reload_and_cleanup_errors
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      File.binwrite(path, YAML.dump(base_config))
      checkpoint = { path: File.realpath(path), expected_tun: :disabled, selections: {} }
      assert_equal false, ClaudeEasy.stub(:runtime_selections_for_profile, {}) {
        ClaudeEasy.reload_recovered_safe_update_runtime(
          [{ path: path }], 1, "friend", runtime_checkpoint: checkpoint,
          transaction: {}, client_identity: {}, reload_snapshot_reader: -> { raise IOError }
        )
      }
      assert_equal false, ClaudeEasy.reload_recovered_safe_update_runtime(
        [{ path: path }], 1, "friend", runtime_checkpoint: checkpoint,
        transaction: {}, client_identity: {},
        runtime_checkpoint_checker: ->(_current) { raise IOError }
      )

      backup_root = File.join(directory, "backups")
      transaction = ClaudeEasy.prepare_profile_transaction(
        [{ path: path, original: File.binread(path), candidate: File.binread(path) }],
        backup_root, roots: [directory], runtime_checkpoint: checkpoint,
        activation_identity: { pid: 1, started: "same", executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta" }
      )
      result = ClaudeEasy.stub(:reload_recovered_safe_update_runtime, true) do
        ClaudeEasy.stub(:remove_profile_transaction, ->(_record) { raise IOError }) do
          ClaudeEasy.safe_update_all(
            targets: [{ name: "friend", path: path }], policy: @policy,
            backup_root: backup_root, usage_profile: 1, selected_name: "friend",
            client_identity_reader: -> { { pid: 1 } },
            fetcher: ->(_target) { flunk "recovery failure must stop before download" },
            validator: ->(_candidate) { true }
          )
        end
      end
      assert_equal :runtime_restore_pending, result.fetch(:status)
    end
  end

  def test_v5_transaction_recovery_uses_the_native_safe_update_path
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("marker" => "original"))
      candidate = YAML.dump(base_config.merge("marker" => "candidate"))
      File.binwrite(path, original)
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      current_identity = identity.merge(pid: 54_321, started: "restarted")
      checkpoint = { path: File.realpath(path), expected_tun: :disabled, selections: {} }
      ClaudeEasy.prepare_profile_transaction(
        [{ path: path, original: original, candidate: candidate }],
        backup_root, roots: [directory], runtime_checkpoint: checkpoint,
        activation_identity: identity
      )
      File.binwrite(path, candidate)
      reloads = []
      checkpoint_checks = [false, true]

      ClaudeEasy.stub(:saved_usage_profile, 1) do
        ClaudeEasy.stub(:clashx_running_identity, current_identity) do
          ClaudeEasy.stub(:reload_recovered_profile_runtime, ->(*) { flunk "v5 recovery used controller reload" }) do
            ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
              ClaudeEasy.stub(:open_clashx_reload_receipt, {}) do
                ClaudeEasy.stub(:request_clashx_native_reload, ->(current) { reloads << current; true }) do
                  ClaudeEasy.stub(:wait_for_clashx_safe_runtime, true) do
                    ClaudeEasy.stub(:current_runtime_loaded_profile_state, :candidate) do
                      ClaudeEasy.stub(:capture_runtime_checkpoint, checkpoint) do
                        ClaudeEasy.stub(:runtime_checkpoint_current?, ->(*_arguments, **_options) { checkpoint_checks.shift }) do
                          assert_equal :recovered, ClaudeEasy.resume_profile_transaction(
                            backup_root, roots: [directory], work_items: [{ path: path, active: true }],
                            reload_runtime: true, require_tun: :preserve
                          )
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
      assert_equal [current_identity], reloads
      assert_equal original.b, File.binread(path)
    end
  end

  def test_v5_transaction_recovery_honors_no_reload
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("marker" => "original"))
      candidate = YAML.dump(base_config.merge("marker" => "candidate"))
      identity = {
        pid: 12_345, started: "same",
        executable: "/Applications/ClashX Meta.app/Contents/MacOS/ClashX Meta"
      }
      File.binwrite(path, original)
      ClaudeEasy.prepare_profile_transaction(
        [{ path: path, original: original, candidate: candidate }],
        backup_root, roots: [directory],
        runtime_checkpoint: {
          path: File.realpath(path), expected_tun: :disabled, selections: {}
        },
        activation_identity: identity
      )
      File.binwrite(path, candidate)

      ClaudeEasy.stub(:saved_usage_profile, 1) do
        ClaudeEasy.stub(:clashx_running_identity, -> { flunk "no-reload read client identity" }) do
          ClaudeEasy.stub(:reload_recovered_safe_update_runtime, ->(*) { flunk "no-reload sent native reload" }) do
            assert_equal :runtime_restore_pending, ClaudeEasy.resume_profile_transaction(
              backup_root, roots: [directory], work_items: [{ path: path, active: true }],
              reload_runtime: false, require_tun: :preserve
            )
          end
        end
      end
      assert_equal original.b, File.binread(path)
      assert ClaudeEasy.profile_transaction_pending?(backup_root)
    end
  end

  private

  def localized_selection_configs
    english = {
      "proxies" => [
        { "name" => "Taiwan 1", "type" => "vless", "server" => "tw.example", "port" => 443 },
        { "name" => "Hong Kong 1", "type" => "vless", "server" => "hk.example", "port" => 443 }
      ],
      "proxy-groups" => [
        { "name" => "Main", "type" => "select", "proxies" => ["Taiwan 1", "Hong Kong 1"] },
        { "name" => "AI", "type" => "select", "proxies" => ["Main", "DIRECT"] }
      ]
    }
    chinese = {
      "proxies" => [
        { "name" => "台湾 1", "type" => "vless", "server" => "tw.example", "port" => 443 },
        { "name" => "香港 1", "type" => "vless", "server" => "hk.example", "port" => 443 }
      ],
      "proxy-groups" => [
        { "name" => "主节点", "type" => "select", "proxies" => ["台湾 1", "香港 1"] },
        { "name" => "人工智能", "type" => "select", "proxies" => ["主节点", "DIRECT"] }
      ]
    }
    [english, chinese]
  end

  def with_home(home)
    original = ENV["HOME"]
    ENV["HOME"] = home
    yield
  ensure
    ENV["HOME"] = original
  end

  def base_config
    {
      "proxies" => [
        { "name" => "台湾家宽 01", "type" => "ss", "server" => "tw.example", "password" => "fixture-secret" },
        { "name" => "日本家宽 01", "type" => "ss", "server" => "jp.example", "password" => "fixture-secret" },
        { "name" => "美国家宽 01", "type" => "ss", "server" => "us.example", "password" => "fixture-secret" }
      ],
      "proxy-groups" => [
        { "name" => "Main", "type" => "select", "proxies" => ["台湾家宽 01", "日本家宽 01", "美国家宽 01"] },
        { "name" => "AI", "type" => "select", "proxies" => ["Main"] }
      ],
      "dns" => {
        "enable" => true,
        "nameserver" => ["223.5.5.5"],
        "nameserver-policy" => { "+.example.com,+.example.org" => ["223.5.5.5"] }
      },
      "rules" => [
        "DOMAIN,raw.githubusercontent.com,AI",
        "DOMAIN,storage.googleapis.com,AI",
        "DOMAIN-SUFFIX,friend.example,DIRECT",
        "DOMAIN,static.example.net,DIRECT",
        "GEOSITE,CN,DIRECT",
        "MATCH,Main"
      ]
    }
  end
end
