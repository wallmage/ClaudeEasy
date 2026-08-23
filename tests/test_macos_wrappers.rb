require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "support/macos_runtime_fixture"

ROOT = File.expand_path("..", __dir__) unless defined?(ROOT)
INSTALLER = File.join(ROOT, "claude-easy/scripts/install_macos.sh")
UNINSTALLER = File.join(ROOT, "claude-easy/scripts/uninstall_macos.sh")
RESULT_CONTRACT = File.join(ROOT, "claude-easy/scripts/macos/result_contract.rb")
POLICY_PATH = File.join(ROOT, "claude-easy/references/policy.json")

class MacosWrapperTest < Minitest::Test
  include MacosRuntimeFixture

  REQUIRED_RESULT_FIELDS = %w[
    schema version command platform client operation ok status code exit_code summary_zh
    profile changes checks items messages warnings
  ].freeze
  OPTIONAL_RESULT_FIELDS = %w[
    workflow_complete completed_scope required_followups
  ].freeze

  INSTALL_PACKAGE_DEPENDENCIES = %w[
    uninstall_macos.sh
    macos/patch_profiles.rb
    macos/result_contract.rb
    macos/operation_lock.rb
    macos/usage_profile_state.rb
    macos/patch_profiles/transform.rb
    macos/patch_profiles/backups.rb
    macos/patch_profiles/mihomo.rb
    macos/patch_profiles/profile_writer.rb
    macos/patch_profiles/subscriptions.rb
    macos/patch_profiles/runtime.rb
    macos/patch_profiles/log_repair.rb
    macos/patch_profiles/cli.rb
    ../references/policy.json
  ].freeze
  UNINSTALL_PACKAGE_DEPENDENCIES = (
    INSTALL_PACKAGE_DEPENDENCIES - ["uninstall_macos.sh"]
  ).freeze

  def usage_state_path(home)
    File.join(home, "Library", "Application Support", "ClaudeEasy", "usage-profile.plist")
  end

  def write_usage_profile(home, profile)
    state = usage_state_path(home)
    FileUtils.mkdir_p(File.dirname(state))
    system("/usr/bin/plutil", "-create", "xml1", state)
    system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
    system("/usr/bin/plutil", "-insert", "Profile", "-integer", profile.to_s, state)
    File.chmod(0o600, state)
    state
  end

  def run_script(path, *arguments, home:, extra_env: {})
    state = usage_state_path(home)
    env = {
      "HOME" => home,
      "CLAUDE_EASY_USAGE_STATE_PATH" => nil,
      "CLAUDE_EASY_USAGE_PROFILE" => nil,
      "CLAUDE_EASY_PROFILE_DIR" => nil
    }.merge(extra_env)
    stdout, stderr, status = Open3.capture3(env, "/bin/sh", path, *arguments)
    [stdout, stderr, status, state]
  end

  def capture_stream(stream, buffer)
    Thread.new do
      buffer << stream.read
    rescue IOError
      nil
    end
  end

  def require_production_probe!
    skip "set CLAUDE_EASY_RUN_PRODUCTION_PROBES=1 to run known production-failure probes" unless
      ENV["CLAUDE_EASY_RUN_PRODUCTION_PROBES"] == "1"
  end

  def with_supported_app(home)
    write_supported_clashx_app(home)
    yield
  end

  def with_supported_mihomo_installer(patcher_source: nil)
    Dir.mktmpdir do |package|
      scripts = File.join(package, "scripts")
      FileUtils.mkdir_p(File.join(scripts, "macos"))
      FileUtils.mkdir_p(File.join(package, "references"))
      FileUtils.cp(INSTALLER, File.join(scripts, "install_macos.sh"))
      copy_install_package_dependencies(scripts)
      File.write(
        File.join(scripts, "macos", "patch_profiles.rb"),
        "exit 0 if ARGV.include?('--help')\n" + (patcher_source || <<~RUBY)
          if ARGV.include?("--print-core-status")
            puts "supported"
          elsif ARGV.include?("--disable-subscription-auto-update")
            puts "already_disabled"
          end
          exit 0
        RUBY
      )
      File.write(File.join(package, "references", "policy.json"), "{}\n")
      yield File.join(scripts, "install_macos.sh")
    end
  end

  def copy_install_package_dependencies(scripts)
    source_scripts = File.join(ROOT, "claude-easy", "scripts")
    INSTALL_PACKAGE_DEPENDENCIES.each do |relative_path|
      next if relative_path == "macos/patch_profiles.rb" || relative_path == "../references/policy.json"

      source = File.expand_path(relative_path, source_scripts)
      destination = File.expand_path(relative_path, scripts)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(source, destination)
    end
  end

  def with_uninstaller_package(patcher_source:)
    Dir.mktmpdir do |package|
      scripts = File.join(package, "scripts")
      FileUtils.mkdir_p(File.join(scripts, "macos"))
      FileUtils.mkdir_p(File.join(package, "references"))
      copy_install_package_dependencies(scripts)
      FileUtils.cp(POLICY_PATH, File.join(package, "references", "policy.json"))
      File.write(
        File.join(scripts, "macos", "patch_profiles.rb"),
        "exit 0 if ARGV.include?(\"--help\")\n" + patcher_source
      )
      yield File.join(scripts, "uninstall_macos.sh")
    end
  end

  def prepend_operation_lock_fault(script, source)
    operation_lock = File.join(File.dirname(script), "macos", "operation_lock.rb")
    original = File.binread(operation_lock)
    anchor = "#!/usr/bin/ruby\n"
    assert_equal 1, original.scan(anchor).length
    File.binwrite(operation_lock, original.sub(anchor, anchor + source))
  end

  def assert_json_result(stdout, status, command:)
    result = JSON.parse(stdout)
    assert_empty REQUIRED_RESULT_FIELDS - result.keys
    assert_empty result.keys - REQUIRED_RESULT_FIELDS - OPTIONAL_RESULT_FIELDS
    assert_equal "claude-easy.result", result.fetch("schema")
    assert_equal 1, result.fetch("version")
    assert_equal command, result.fetch("command")
    assert_equal "macos", result.fetch("platform")
    assert_equal "clashx-meta", result.fetch("client")
    assert_equal status.exitstatus, result.fetch("exit_code")
    assert_equal stdout.bytes, stdout.encode("UTF-8").bytes
    result
  end

  def test_installer_restores_the_previous_profile_when_profile_publication_cannot_sync
    with_supported_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = usage_state_path(home)
          FileUtils.mkdir_p(File.dirname(state))
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)
          File.chmod(0o600, state)
          marker = File.join(home, "profile-sync-failed")
          prepend_operation_lock_fault(installer, <<~'RUBY')
            if ARGV[0] == "--sync-file" &&
               ARGV[1].to_s.end_with?("/usage-profile.plist") &&
               !File.exist?(ENV.fetch("CLAUDE_EASY_TEST_SYNC_FAILURE"))
              File.binwrite(ENV.fetch("CLAUDE_EASY_TEST_SYNC_FAILURE"), "failed")
              exit 76
            end
          RUBY

          stdout, stderr, status, = run_script(
            installer, "--profile", "2", "--json", home: home,
            extra_env: { "CLAUDE_EASY_TEST_SYNC_FAILURE" => marker }
          )

          refute status.success?, "#{stdout}\n#{stderr}"
          assert File.file?(marker)
          saved = Open3.capture2(
            "/usr/bin/plutil", "-extract", "Profile", "raw", state
          ).first.strip
          assert_equal "1", saved
        end
      end
    end
  end

  def test_uninstaller_restores_every_file_when_the_delete_directory_cannot_sync
    with_uninstaller_package(patcher_source: "exit 0\n") do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        FileUtils.mkdir_p(File.join(install_dir, "backups"))
        originals = {
          File.join(install_dir, "patch_profiles.rb") => "patcher",
          File.join(install_dir, "policy.json") => "policy",
          usage_state_path(home) => "usage",
          File.join(install_dir, "patch.log") => "log"
        }
        originals.each { |path, bytes| File.binwrite(path, bytes) }
        marker = File.join(home, "delete-directory-sync-failed")
        prepend_operation_lock_fault(uninstaller, <<~'RUBY')
          if ARGV[0] == "--sync-directory" &&
             ARGV[1].to_s == ENV.fetch("CLAUDE_EASY_TEST_INSTALL_DIR") &&
             !File.exist?(ENV.fetch("CLAUDE_EASY_TEST_SYNC_FAILURE"))
            File.binwrite(ENV.fetch("CLAUDE_EASY_TEST_SYNC_FAILURE"), "failed")
            exit 76
          end
        RUBY

        stdout, stderr, status = Open3.capture3(
          {
            "HOME" => home,
            "CLAUDE_EASY_USAGE_STATE_PATH" => nil,
            "CLAUDE_EASY_USAGE_PROFILE" => nil,
            "CLAUDE_EASY_PROFILE_DIR" => nil,
            "CLAUDE_EASY_TEST_INSTALL_DIR" => install_dir,
            "CLAUDE_EASY_TEST_SYNC_FAILURE" => marker
          },
          "/bin/sh", uninstaller, "--json"
        )

        assert_equal 76, status.exitstatus, "#{stdout}\n#{stderr}"
        assert File.file?(marker)
        assert_equal 1, stdout.lines.length
        result = assert_json_result(stdout, status, command: "uninstall")
        assert_equal "rolled_back", result.fetch("status")
        assert_equal "uninstall_interrupted_rolled_back", result.fetch("code")
        originals.each { |path, bytes| assert_equal bytes, File.binread(path) }
        refute File.exist?(File.join(install_dir, ".claude-easy-uninstall-staging"))
      end
    end
  end

  def test_uninstaller_preserves_a_replacement_created_after_final_verification
    with_uninstaller_package(patcher_source: "exit 0\n") do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        FileUtils.mkdir_p(File.join(install_dir, "backups"))
        state = usage_state_path(home)
        File.binwrite(File.join(install_dir, "patch_profiles.rb"), "patcher")
        File.binwrite(File.join(install_dir, "policy.json"), "policy")
        File.binwrite(state, "original-state")
        ready = File.join(home, "final-verification-ready")
        continue_path = File.join(home, "final-verification-continue")
        source = File.binread(uninstaller)
        anchor = (
          "    finish 1 failed uninstall_state_conflict \"卸载目标在暂存后被替换；未删除新文件。\"\n" \
          "  fi\n"
        ).b
        assert_equal 1, source.scan(anchor).length
        File.binwrite(uninstaller, source.sub(anchor, anchor + <<~'SH'))
          /usr/bin/touch "$CLAUDE_EASY_TEST_READY"
          while [ ! -e "$CLAUDE_EASY_TEST_CONTINUE" ]; do
            /bin/sleep 0.01
          done
        SH

        env = {
          "HOME" => home,
          "CLAUDE_EASY_USAGE_STATE_PATH" => nil,
          "CLAUDE_EASY_USAGE_PROFILE" => nil,
          "CLAUDE_EASY_PROFILE_DIR" => nil,
          "CLAUDE_EASY_TEST_READY" => ready,
          "CLAUDE_EASY_TEST_CONTINUE" => continue_path
        }
        stdout = +""
        stderr = +""
        status = nil
        process_thread = nil
        readers = []
        begin
          Open3.popen3(env, "/bin/sh", uninstaller, "--json") do |stdin, out, error, thread|
            process_thread = thread
            stdin.close
            readers << capture_stream(out, stdout)
            readers << capture_stream(error, stderr)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
            until File.exist?(ready)
              raise "uninstaller never reached final verification" if
                Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              sleep 0.01
            end
            replacement = "#{state}.replacement"
            File.binwrite(replacement, "concurrent-new")
            File.rename(replacement, state)
            File.binwrite(continue_path, "continue")
            raise "uninstaller did not exit" unless thread.join(10)
            status = thread.value
            readers.each(&:join)
          end
        ensure
          File.binwrite(continue_path, "continue") rescue nil
          if process_thread&.alive?
            Process.kill("KILL", process_thread.pid) rescue nil
            process_thread.join
          end
          readers.each(&:join)
        end

        refute status.success?, "#{stdout}\n#{stderr}"
        assert_equal "concurrent-new", File.binread(state)
        assert_equal 1, stdout.lines.length
        result = assert_json_result(stdout, status, command: "uninstall")
        assert_match(/(?:conflict|unsafe)/, result.fetch("code"))
      end
    end
  end

  def test_production_probe_uninstall_preserves_a_file_replaced_after_staging
    require_production_probe!
    patcher = <<~'RUBY'
      backup_dir = ARGV[ARGV.index("--backup-dir") + 1] if ARGV.include?("--backup-dir")
      ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json") if backup_dir
      preference = File.join(ENV.fetch("HOME"), "auto-update-state")
      if ARGV.include?("--print-auto-update-ownership-state")
        puts(File.exist?(ownership) ? "owned" : "not_owned")
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.write(preference, "enabled")
        File.delete(ownership)
        puts "restored"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(preference, "disabled")
        File.write(ownership, "{}") unless File.exist?(ownership)
        puts "disabled"
        exit 0
      end
      exit 1
    RUBY
    with_uninstaller_package(patcher_source: patcher) do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        backup_dir = File.join(install_dir, "backups")
        FileUtils.mkdir_p(backup_dir)
        installed_patcher = File.join(install_dir, "patch_profiles.rb")
        state = usage_state_path(home)
        FileUtils.mkdir_p(File.dirname(state))
        ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json")
        preference = File.join(home, "auto-update-state")
        File.binwrite(installed_patcher, "owned-patcher")
        File.binwrite(state, "owned-state")
        File.binwrite(ownership, "{}")
        File.binwrite(preference, "disabled")
        ready = File.join(home, "uninstall-ready")
        continue_path = File.join(home, "uninstall-continue")
        anchor = "  /usr/bin/touch \"$UNINSTALL_STAGING/READY\"\n"
        source = File.binread(uninstaller)
        assert_equal 1, source.scan(anchor).length
        instrumented = anchor + <<~'SH'
          /usr/bin/touch "$CLAUDE_EASY_TEST_READY"
          while [ ! -e "$CLAUDE_EASY_TEST_CONTINUE" ]; do
            /bin/sleep 0.01
          done
        SH
        File.binwrite(uninstaller, source.sub(anchor, instrumented))
        env = {
          "HOME" => home,
          "CLAUDE_EASY_USAGE_STATE_PATH" => state,
          "CLAUDE_EASY_USAGE_PROFILE" => nil,
          "CLAUDE_EASY_PROFILE_DIR" => nil,
          "CLAUDE_EASY_TEST_READY" => ready,
          "CLAUDE_EASY_TEST_CONTINUE" => continue_path
        }
        stdout = +""
        stderr = +""
        process_thread = nil
        readers = []
        status = nil
        begin
          Open3.popen3(env, "/bin/sh", uninstaller, "--json") do |stdin, out, error, thread|
            process_thread = thread
            stdin.close
            readers << capture_stream(out, stdout)
            readers << capture_stream(error, stderr)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
            until File.exist?(ready)
              raise "uninstaller never reached the staging gate" if
                Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              sleep 0.01
            end
            replacement = "#{state}.replacement"
            File.binwrite(replacement, "concurrent-new")
            File.rename(replacement, state)
            File.binwrite(continue_path, "continue")
            raise "uninstaller did not exit after the staging gate" unless thread.join(10)
            status = thread.value
            readers.each(&:join)
          end
        ensure
          File.binwrite(continue_path, "continue") rescue nil
          if process_thread&.alive?
            Process.kill("KILL", process_thread.pid) rescue nil
            process_thread.join
          end
          readers.each(&:join)
        end

        replacement_preserved = File.file?(state) && File.binread(state) == "concurrent-new"
        violations = []
        violations << "deleted the replacement" unless replacement_preserved
        violations << "reported success" if status.success?
        violations << "omitted a conflict message" unless (stdout + stderr).match?(/conflict|concurrent|并发|替换/)
        violations << "enabled automatic updates while profile 3 remained" unless File.binread(preference) == "disabled"
        violations << "discarded automatic-update ownership" unless File.file?(ownership)
        assert_empty violations, violations.join("; ")
      end
    end
  end

  def test_production_probe_install_recovers_a_killed_ready_uninstall_before_changing_profile
    require_production_probe!
    patcher = <<~'RUBY'
      require "json"

      backup_dir = ARGV[ARGV.index("--backup-dir") + 1] if ARGV.include?("--backup-dir")
      ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json") if backup_dir
      preference = File.join(ENV.fetch("HOME"), "auto-update-state")
      if ARGV.include?("--print-auto-update-ownership-state")
        puts(File.exist?(ownership) ? "owned" : "not_owned")
        exit 0
      end
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        already_owned = File.exist?(ownership)
        File.write(preference, "disabled")
        File.write(ownership, "{}") unless File.exist?(ownership)
        puts(already_owned ? "already_disabled_owned" : "disabled")
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.write(preference, "enabled")
        File.delete(ownership) if File.exist?(ownership)
        puts "restored"
        exit 0
      end
      puts JSON.generate(
        "schema" => "claude-easy.result", "version" => 1, "command" => "patch",
        "platform" => "macos", "client" => "clashx-meta", "operation" => "patch_profiles",
        "ok" => true, "status" => "ok", "code" => "patched", "exit_code" => 0,
        "summary_zh" => "配置处理完成。", "profile" => 2,
        "changes" => [], "checks" => [], "items" => [], "messages" => [], "warnings" => []
      ) if ARGV.include?("--json")
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      scripts = File.dirname(installer)
      uninstaller = File.join(scripts, "uninstall_macos.sh")
      FileUtils.cp(UNINSTALLER, uninstaller)
      source = File.binread(uninstaller)
      anchor = "  for removed in \\\n"
      assert_equal 1, source.scan(anchor).length
      instrumented = <<~'SH'
        /usr/bin/touch "$CLAUDE_EASY_TEST_READY"
        while [ ! -e "$CLAUDE_EASY_TEST_CONTINUE" ]; do
          /bin/sleep 60
        done
      SH
      File.binwrite(uninstaller, source.sub(anchor, instrumented + anchor))

      Dir.mktmpdir do |home|
        with_supported_app(home) do
          install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
          backup_dir = File.join(install_dir, "backups")
          FileUtils.mkdir_p(backup_dir)
          File.binwrite(File.join(install_dir, "patch_profiles.rb"), "owned-patcher")
          File.binwrite(File.join(install_dir, "policy.json"), "{}")
          state = usage_state_path(home)
          FileUtils.mkdir_p(File.dirname(state))
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "3", state)
          File.chmod(0o600, state)
          ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json")
          preference = File.join(home, "auto-update-state")
          File.binwrite(ownership, "{}")
          File.binwrite(preference, "disabled")
          ready = File.join(home, "uninstall-deleted-ready")
          continue_path = File.join(home, "uninstall-deleted-continue")
          env = {
            "HOME" => home,
            "CLAUDE_EASY_USAGE_STATE_PATH" => state,
            "CLAUDE_EASY_USAGE_PROFILE" => nil,
            "CLAUDE_EASY_PROFILE_DIR" => nil,
            "CLAUDE_EASY_TEST_READY" => ready,
            "CLAUDE_EASY_TEST_CONTINUE" => continue_path
          }
          uninstall_thread = nil
          readers = []
          begin
            Open3.popen3(
              env, "/bin/sh", uninstaller, "--json", pgroup: true
            ) do |stdin, stdout, stderr, thread|
              uninstall_thread = thread
              stdin.close
              readers << Thread.new { stdout.read rescue nil }
              readers << Thread.new { stderr.read rescue nil }
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
              until File.exist?(ready)
                raise "uninstaller never reached the post-delete gate" if
                  Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                sleep 0.01
              end
              Process.kill("KILL", -thread.pid)
              raise "uninstaller did not stop after the post-delete kill" unless thread.join(10)
              refute thread.value.success?
            end
            File.binwrite(continue_path, "continue")
          ensure
            Process.kill("KILL", -uninstall_thread.pid) rescue nil
            uninstall_thread&.join
            readers.each(&:join)
          end

          staging = File.join(install_dir, ".claude-easy-uninstall-staging")
          assert File.file?(File.join(staging, "READY"))
          refute File.exist?(state)

          stdout, stderr, status, = run_script(
            installer, "--profile", "2", "--json", home: home,
            extra_env: {
              "CLAUDE_EASY_TEST_READY" => ready,
              "CLAUDE_EASY_TEST_CONTINUE" => continue_path
            }
          )
          assert status.success?, "#{stdout}\n#{stderr}"
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "install_completed", result.fetch("code")
          refute File.exist?(staging), "installer left the interrupted uninstall pending"
          assert File.exist?(ownership), "installer did not retain automatic-update ownership"
          assert_equal "disabled", File.binread(preference)
          saved_profile, saved_error, saved_status = Open3.capture3(
            "/usr/bin/plutil", "-extract", "Profile", "raw", state
          )
          assert saved_status.success?, saved_error
          assert_equal "2", saved_profile.strip
        end
      end
    end
  end

  def test_production_probe_uninstall_recovers_a_killed_profile_transaction_before_enabling_updates
    require_production_probe!
    patcher = <<~'RUBY'
      require "fileutils"
      require "json"

      backup_dir = ARGV[ARGV.index("--backup-dir") + 1] if ARGV.include?("--backup-dir")
      profile_dir = ARGV[ARGV.index("--profile-dir") + 1] if ARGV.include?("--profile-dir")
      profile = File.join(profile_dir, "friend.yaml") if profile_dir
      transaction = File.join(backup_dir, ".claude-easy-profile-transaction.json") if backup_dir
      ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json") if backup_dir
      preference = File.join(ENV.fetch("HOME"), "auto-update-state")
      runtime = File.join(ENV.fetch("HOME"), "runtime-profile")
      original = File.join(ENV.fetch("HOME"), "original-profile")

      if ARGV.include?("--print-auto-update-ownership-state")
        puts(File.exist?(ownership) ? "owned" : "not_owned")
        exit 0
      end
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--disable-subscription-auto-update")
        FileUtils.mkdir_p(backup_dir)
        File.binwrite(ownership, "{}") unless File.exist?(ownership)
        File.binwrite(preference, "disabled")
        puts "disabled"
        exit 0
      end
      if ARGV.include?("--recover-profile-transaction")
        abort "missing --json" unless ARGV.include?("--json")
        File.binwrite(profile, File.binread(original))
        File.binwrite(runtime, "original")
        File.delete(transaction)
        puts JSON.generate(
          "schema" => "claude-easy.result", "version" => 1, "command" => "patch",
          "operation" => "recover_profile_transaction", "exit_code" => 0,
          "code" => "profile_transaction_recovered"
        )
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.binwrite(preference, "enabled")
        File.delete(ownership) if File.exist?(ownership)
        puts "restored"
        exit 0
      end

      File.binwrite(transaction, "pending")
      File.binwrite(profile, "candidate")
      File.binwrite(runtime, "candidate")
      File.binwrite(ENV.fetch("CLAUDE_EASY_TEST_READY"), "ready")
      sleep 60
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      scripts = File.dirname(installer)
      uninstaller = File.join(scripts, "uninstall_macos.sh")
      FileUtils.cp(UNINSTALLER, uninstaller)

      Dir.mktmpdir do |home|
        with_supported_app(home) do
          profile_dir = File.join(home, "profiles")
          FileUtils.mkdir_p(profile_dir)
          profile = File.join(profile_dir, "friend.yaml")
          File.binwrite(profile, "original")
          File.binwrite(File.join(home, "original-profile"), "original")
          File.binwrite(File.join(home, "runtime-profile"), "original")
          File.binwrite(File.join(home, "auto-update-state"), "enabled")
          ready = File.join(home, "profile-transaction-ready")
          state = usage_state_path(home)
          FileUtils.mkdir_p(File.dirname(state))
          env = {
            "HOME" => home,
            "CLAUDE_EASY_USAGE_STATE_PATH" => state,
            "CLAUDE_EASY_USAGE_PROFILE" => nil,
            "CLAUDE_EASY_PROFILE_DIR" => profile_dir,
            "CLAUDE_EASY_TEST_READY" => ready
          }
          process_thread = nil
          readers = []
          begin
            Open3.popen3(
              env, "/bin/sh", installer, "--profile", "3", "--json", pgroup: true
            ) do |stdin, stdout, stderr, thread|
              process_thread = thread
              stdin.close
              readers << Thread.new { stdout.read rescue nil }
              readers << Thread.new { stderr.read rescue nil }
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
              until File.exist?(ready)
                raise "installer never reached the profile transaction gate" if
                  Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                sleep 0.01
              end
              Process.kill("KILL", -thread.pid)
              raise "installer did not stop after profile transaction kill" unless thread.join(10)
              refute thread.value.success?
            end
          ensure
            Process.kill("KILL", -process_thread.pid) rescue nil
            process_thread&.join
            readers.each(&:join)
          end

          backup_dir = File.join(home, "Library", "Application Support", "ClaudeEasy", "backups")
          transaction = File.join(backup_dir, ".claude-easy-profile-transaction.json")
          ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json")
          preference = File.join(home, "auto-update-state")
          runtime = File.join(home, "runtime-profile")
          assert File.file?(transaction)
          assert_equal "candidate", File.binread(profile)
          assert_equal "candidate", File.binread(runtime)
          assert_equal "disabled", File.binread(preference)
          assert File.file?(ownership)

          stdout, stderr, status, = run_script(
            uninstaller, "--json", home: home,
            extra_env: { "CLAUDE_EASY_PROFILE_DIR" => profile_dir }
          )

          assert status.success?, "#{stdout}\n#{stderr}"
          result = assert_json_result(stdout, status, command: "uninstall")
          assert_equal "uninstall_completed", result.fetch("code")
          assert_equal "original", File.binread(profile)
          assert_equal "original", File.binread(runtime)
          refute File.exist?(transaction)
          assert_equal "enabled", File.binread(preference)
          refute File.exist?(ownership)
          refute File.exist?(state)
        end
      end
    end
  end

  def test_uninstaller_preserves_everything_when_profile_transaction_recovery_fails
    patcher = <<~'RUBY'
      if ARGV.include?("--recover-profile-transaction")
        exit 1
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.binwrite(File.join(ENV.fetch("HOME"), "unexpected-auto-update-restore"), "called")
        puts "restored"
        exit 0
      end
      exit 1
    RUBY
    with_uninstaller_package(patcher_source: patcher) do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        backup_dir = File.join(install_dir, "backups")
        profile_dir = File.join(home, "profiles")
        FileUtils.mkdir_p(backup_dir)
        FileUtils.mkdir_p(profile_dir)
        protected_files = {
          File.join(install_dir, "patch_profiles.rb") => "owned-patcher",
          File.join(install_dir, "policy.json") => "{}",
          usage_state_path(home) => "owned-usage-state",
          File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json") => "{}",
          File.join(backup_dir, ".claude-easy-profile-transaction.json") => "pending",
          File.join(profile_dir, "friend.yaml") => "candidate",
          File.join(home, "auto-update-state") => "disabled"
        }
        protected_files.each { |path, bytes| File.binwrite(path, bytes) }

        stdout, stderr, status, = run_script(
          uninstaller, "--json", home: home,
          extra_env: { "CLAUDE_EASY_PROFILE_DIR" => profile_dir }
        )

        refute status.success?, "#{stdout}\n#{stderr}"
        result = assert_json_result(stdout, status, command: "uninstall")
        assert_equal "profile_transaction_recovery_failed", result.fetch("code")
        protected_files.each do |path, bytes|
          assert_equal bytes, File.binread(path), "uninstaller changed #{File.basename(path)}"
        end
        refute File.exist?(File.join(home, "unexpected-auto-update-restore"))
        refute File.exist?(File.join(install_dir, ".claude-easy-uninstall-staging"))

        stdout, _stderr, status, = run_script(
          uninstaller, home: home,
          extra_env: { "CLAUDE_EASY_PROFILE_DIR" => profile_dir }
        )
        refute status.success?
        assert_includes stdout, "未完成的配置事务无法恢复"
        protected_files.each do |path, bytes|
          assert_equal bytes, File.binread(path), "human failure changed #{File.basename(path)}"
        end
      end
    end
  end

  def test_uninstaller_resumes_after_kill_during_file_restore
    patcher = <<~'RUBY'
      backup_dir = ARGV[ARGV.index("--backup-dir") + 1] if ARGV.include?("--backup-dir")
      ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json") if backup_dir
      if ARGV.include?("--print-auto-update-ownership-state")
        puts(File.exist?(ownership) ? "owned" : "not_owned")
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        exit 1
      end
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(ownership, "{}") unless File.exist?(ownership)
        puts "disabled"
        exit 0
      end
      exit 1
    RUBY
    with_uninstaller_package(patcher_source: patcher) do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        backup_dir = File.join(install_dir, "backups")
        FileUtils.mkdir_p(backup_dir)
        installed_patcher = File.join(install_dir, "patch_profiles.rb")
        state = usage_state_path(home)
        FileUtils.mkdir_p(File.dirname(state))
        ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json")
        original = ("owned-patcher-" * 65_536).b
        File.binwrite(installed_patcher, original)
        File.binwrite(state, "owned-state")
        File.binwrite(ownership, "{}")
        ready = File.join(home, "restore-ready")
        source = File.binread(uninstaller)
        atomic_restore =
          "    if durable_rename_exclusive \"$removed_slot\" \"$destination\"; then\n" \
          "      return 0\n" \
          "    fi\n"
        assert_equal 1, source.scan(atomic_restore).length
        instrumented = atomic_restore.sub(
          "      return 0\n",
          "      /usr/bin/touch \"$CLAUDE_EASY_TEST_RESTORE_READY\"\n" \
          "      while :; do /bin/sleep 1; done\n"
        )
        source = source.sub(atomic_restore, instrumented)
        File.binwrite(uninstaller, source)
        env = {
          "HOME" => home,
          "CLAUDE_EASY_USAGE_STATE_PATH" => state,
          "CLAUDE_EASY_USAGE_PROFILE" => nil,
          "CLAUDE_EASY_PROFILE_DIR" => nil,
          "CLAUDE_EASY_TEST_RESTORE_READY" => ready
        }
        process_thread = nil
        readers = []
        begin
          Open3.popen3(env, "/bin/sh", uninstaller, "--json", pgroup: true) do |stdin, out, error, thread|
            process_thread = thread
            stdin.close
            readers << Thread.new { out.read rescue nil }
            readers << Thread.new { error.read rescue nil }
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
            until File.exist?(ready)
              raise "uninstaller never reached restore publication" if
                Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              sleep 0.01
            end
            Process.kill("KILL", -thread.pid)
            raise "uninstaller did not stop after restore kill" unless thread.join(10)
          end
        ensure
          Process.kill("KILL", -process_thread.pid) rescue nil
          process_thread&.join
          readers.each(&:join)
        end

        assert File.binread(installed_patcher) == original
        recovery_entry = "restore_uncommitted_or_finish\n\nAUTO_UPDATE_OWNED=0"
        resume_source = File.binread(UNINSTALLER)
        assert_equal 1, resume_source.scan(recovery_entry).length
        File.binwrite(
          uninstaller,
          resume_source.sub(
            recovery_entry,
            "restore_uncommitted_or_finish\nexit 99\n\nAUTO_UPDATE_OWNED=0"
          )
        )
        _stdout, _stderr, status, = run_script(uninstaller, home: home)

        assert_equal 99, status.exitstatus
        assert File.binread(installed_patcher) == original,
               "interrupted uninstall did not restore the original patcher bytes"
        assert_equal "owned-state", File.binread(state)
      end
    end
  end

  def test_failed_profile_change_preserves_the_previous_saved_profile
    failing_patcher = <<~RUBY
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--disable-subscription-auto-update")
        puts "already_disabled"
        exit 0
      end
      exit 1
    RUBY
    with_supported_mihomo_installer(patcher_source: failing_patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = usage_state_path(home)
          FileUtils.mkdir_p(File.dirname(state))
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)
          File.chmod(0o600, state)
          original = File.binread(state)

          stdout, _stderr, status = run_script(installer, "--profile", "2", home: home)

          assert_equal 1, status.exitstatus
          assert_includes stdout, "配置处理失败"
          assert_equal "1", Open3.capture3(
            "/usr/bin/plutil", "-extract", "Profile", "raw", state
          ).first.strip
          assert_equal original, File.binread(state)

          stdout, stderr, status = run_script(installer, "--profile", "2", "--json", home: home)
          assert_equal 1, status.exitstatus
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "patch_failed", result.fetch("code")
          assert_equal "1", Open3.capture3(
            "/usr/bin/plutil", "-extract", "Profile", "raw", state
          ).first.strip
          assert_equal original, File.binread(state)
        end
      end
    end
  end

  def test_strong_kill_after_profile_application_keeps_new_profile_as_recovery_intent
    patcher = <<~'RUBY'
      profile_index = ARGV.index("--usage-profile")
      profile = ARGV.fetch(profile_index + 1) if profile_index
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        puts "already_disabled"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--safe-update-all")
        File.write(File.join(ENV.fetch("HOME"), "subscription-backup"), "created")
        exit 0
      end
      File.write(File.join(ENV.fetch("HOME"), "applied-profile"), profile)
      File.write(File.join(ENV.fetch("HOME"), "patcher-pid"), Process.pid.to_s)
      File.write(File.join(ENV.fetch("HOME"), "patcher-ready"), "ready")
      sleep 60
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = usage_state_path(home)
          FileUtils.mkdir_p(File.dirname(state))
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)
          File.chmod(0o600, state)
          env = {
            "HOME" => home,
            "CLAUDE_EASY_USAGE_STATE_PATH" => state,
            "CLAUDE_EASY_USAGE_PROFILE" => nil,
            "CLAUDE_EASY_PROFILE_DIR" => nil
          }
          ready = File.join(home, "patcher-ready")
          process_thread = nil
          child_pid = nil
          readers = []
          begin
            Open3.popen3(
              env, "/bin/sh", installer, "--profile", "3", pgroup: true
            ) do |stdin, stdout, stderr, thread|
              process_thread = thread
              stdin.close
              readers << Thread.new { stdout.read rescue nil }
              readers << Thread.new { stderr.read rescue nil }
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
              until File.exist?(ready)
                raise "installer never reached the profile application gate" if
                  Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                sleep 0.01
              end
              child_pid = Integer(File.read(File.join(home, "patcher-pid")))
              Process.kill("KILL", -thread.pid)
              raise "installer did not stop after SIGKILL" unless thread.join(10)
              refute thread.value.success?
            end
          ensure
            begin
              Process.kill("KILL", child_pid) if child_pid
            rescue Errno::ESRCH
              nil
            end
            begin
              Process.kill("KILL", -process_thread.pid) if process_thread
            rescue Errno::ESRCH, Errno::EPERM
              nil
            end
            process_thread&.join
            readers.each(&:join)
          end

          assert_equal "3", File.read(File.join(home, "applied-profile"))
          saved_profile, _error, read_status = Open3.capture3(
            "/usr/bin/plutil", "-extract", "Profile", "raw", state
          )
          assert read_status.success?
          assert_equal "3", saved_profile.strip

          stdout, stderr, status = run_script(installer, "--safe-update", home: home)
          assert status.success?, "#{stdout}\n#{stderr}"
          assert_equal "created", File.read(File.join(home, "subscription-backup"))
        end
      end
    end
  end

  def test_first_install_restores_auto_update_when_a_later_step_fails
    patcher = <<~RUBY
      File.open(File.join(ENV.fetch("HOME"), "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        puts "disabled"
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        puts "restored"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      exit 1
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, _stderr, status = run_script(installer, "--profile", "3", home: home)

          assert_equal 1, status.exitstatus
          assert_includes stdout, "配置处理失败"
          calls = File.read(File.join(home, "patcher-calls.log")).lines.map(&:strip)
          disable_index = calls.index { |call| call.include?("--disable-subscription-auto-update") }
          restore_index = calls.index { |call| call.include?("--restore-owned-subscription-auto-update") }
          refute_nil disable_index
          refute_nil restore_index
          assert_operator restore_index, :>, disable_index
        end
      end
    end
  end

  def test_safe_update_failure_before_download_does_not_change_auto_update
    patcher = <<~'RUBY'
      home = ENV.fetch("HOME")
      File.open(File.join(home, "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(File.join(home, "auto-update-changed"), "yes")
        puts "disabled"
        exit 0
      end
      exit 1 if ARGV.include?("--safe-update-all")
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          write_usage_profile(home, 3)

          _stdout, _stderr, status = run_script(installer, "--safe-update", home: home)

          assert_equal 1, status.exitstatus
          refute File.exist?(File.join(home, "auto-update-changed"))
          calls = File.read(File.join(home, "patcher-calls.log"))
          assert_includes calls, "--safe-update-all"
          refute_includes calls, "--disable-subscription-auto-update"
        end
      end
    end
  end

  def test_json_wrapper_preserves_subscription_update_result
    patcher = <<~RUBY
      require "json"
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--disable-subscription-auto-update")
        puts "already_disabled"
        exit 0
      end
      if ARGV.include?("--safe-update-all")
        result = {
          "schema" => "claude-easy.result", "version" => 1, "command" => "patch",
          "platform" => "macos", "client" => "clashx-meta", "operation" => "safe_update",
          "ok" => true, "exit_code" => 0, "profile" => 3,
          "changes" => ["remote_subscriptions"], "checks" => [], "messages" => [],
          "workflow_complete" => false, "completed_scope" => "subscription_update",
          "required_followups" => %w[route_verification final_state_audit]
        }
        puts JSON.generate(result.merge(
          "status" => "ok", "code" => "safe_update_completed",
          "summary_zh" => "订阅事务完成，后续验收尚未完成。",
          "items" => [{ "id" => "ce-subscription-v1-#{"a" * 64}", "label" => "订阅 A", "status" => "updated" }],
          "warnings" => []
        ))
        exit 0
      end
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          write_usage_profile(home, 3)
          stdout, stderr, status = run_script(
            installer, "--safe-update", "--json", home: home
          )

          assert status.success?
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "ok", result.fetch("status")
          assert_equal "safe_update_completed", result.fetch("code")
          assert_equal "订阅 A", result.fetch("items").fetch(0).fetch("label")
          assert_equal ["remote_subscriptions"], result.fetch("changes")
        end
      end
    end
  end

  def test_safe_update_deadline_stops_the_update_without_stopping_unrelated_processes
    patcher = <<~'RUBY'
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--safe-update-all")
        File.write(File.join(ENV.fetch("HOME"), "safe-update-child-pid"), Process.pid.to_s)
        sleep 5
      end
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      installer_source = File.binread(installer)
      replacement = installer_source.sub("SAFE_UPDATE_TIMEOUT_SECONDS=180", "SAFE_UPDATE_TIMEOUT_SECONDS=3")
      refute_equal installer_source, replacement
      File.binwrite(installer, replacement)

      Dir.mktmpdir do |home|
        with_supported_app(home) do
          write_usage_profile(home, 1)
          unrelated_pid = Process.spawn("/bin/sleep", "30")
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          stdout, stderr, status = run_script(
            installer, "--safe-update", "--json", home: home
          )
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

          assert_operator elapsed, :<, 8
          refute status.success?
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "safe_update_timeout", result.fetch("code")
          assert Process.kill(0, unrelated_pid)
          child_pid = Integer(File.read(File.join(home, "safe-update-child-pid")))
          assert_raises(Errno::ESRCH) { Process.kill(0, child_pid) }
        ensure
          begin
            Process.kill("KILL", unrelated_pid) if unrelated_pid
          rescue Errno::ESRCH
            nil
          end
          Process.wait(unrelated_pid) if unrelated_pid
        end
      end
    end
  end

  def test_subscription_update_requires_and_preserves_the_saved_usage_profile
    patcher = <<~'RUBY'
      require "json"
      if ARGV.include?("--safe-update-all")
        File.write(File.join(ENV.fetch("HOME"), "subscription-backup"), ARGV.join(" "))
        if ARGV.include?("--json")
          puts JSON.generate(
            "schema" => "claude-easy.result", "version" => 1, "command" => "patch",
            "platform" => "macos", "client" => "clashx-meta",
            "operation" => "backup_subscriptions", "ok" => true, "status" => "ok",
            "code" => "subscription_backups_created", "exit_code" => 0,
            "summary_zh" => "已创建更新前备份。", "profile" => nil,
            "changes" => ["profile_backups"], "checks" => [], "items" => [],
            "messages" => [], "warnings" => []
          )
        end
      end
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, stderr, status = run_script(
            installer, "--safe-update", home: home
          )

          assert_equal 10, status.exitstatus
          assert_empty stderr
          refute File.exist?(usage_state_path(home))
          refute File.exist?(File.join(home, "subscription-backup"))
        end
      end

      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = write_usage_profile(home, 1)
          original = File.binread(state)

          stdout, stderr, status = run_script(
            installer, "--safe-update", "--profile", "2", "--json", home: home
          )

          assert_equal 64, status.exitstatus
          assert_empty stderr
          assert_equal original, File.binread(state)
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "usage_profile_mismatch", result.fetch("code")
          assert_equal 1, result.fetch("profile")
        end
      end
    end
  end

  def test_uninstaller_removes_owned_files_and_preserves_backups
    Dir.mktmpdir do |home|
      install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
      backup_dir = File.join(install_dir, "backups")
      FileUtils.mkdir_p(backup_dir)
      File.write(File.join(install_dir, "patch_profiles.rb"), "owned")
      File.write(File.join(install_dir, "policy.json"), "owned")
      state = usage_state_path(home)
      FileUtils.mkdir_p(File.dirname(state))
      File.write(state, "owned")
      File.write(File.join(backup_dir, "keep.backup"), "keep")
      stdout, _stderr, status = run_script(UNINSTALLER, home: home)

      assert status.success?, stdout
      refute File.exist?(File.join(install_dir, "patch_profiles.rb"))
      refute File.exist?(File.join(install_dir, "policy.json"))
      refute File.exist?(state)
      assert File.file?(File.join(backup_dir, "keep.backup"))
      assert_includes stdout, "备份仍保留"
    end
  end

  def test_uninstaller_restores_owned_subscription_auto_update_before_removing_profile_state
    patcher = <<~RUBY
      backup_dir = ARGV[ARGV.index("--backup-dir") + 1] if ARGV.include?("--backup-dir")
      ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json") if backup_dir
      if ARGV.include?("--print-auto-update-ownership-state")
        puts(File.exist?(ownership) ? "owned" : "not_owned")
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.write(File.join(ENV.fetch("HOME"), "restore-auto-update-arguments"), ARGV.join("\\n"))
        File.delete(ownership)
        puts "restored"
        exit 0
      end
      exit 1
    RUBY
    with_uninstaller_package(patcher_source: patcher) do |uninstaller|
      Dir.mktmpdir do |home|
        backup_dir = File.join(home, "Library", "Application Support", "ClaudeEasy", "backups")
        FileUtils.mkdir_p(backup_dir)
        File.write(File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json"), "{}")
        usage_state = usage_state_path(home)
        FileUtils.mkdir_p(File.dirname(usage_state))
        File.write(usage_state, "owned")

        stdout, _stderr, status = run_script(uninstaller, home: home)

        assert status.success?, stdout
        arguments = File.read(File.join(home, "restore-auto-update-arguments"))
        assert_includes arguments, "--restore-owned-subscription-auto-update"
        assert_includes arguments, "--backup-dir"
        refute File.exist?(usage_state)
        assert_includes stdout, "订阅自动更新"
      end
    end
  end

  def test_uninstaller_keeps_profile_and_ownership_state_when_auto_update_restore_fails
    patcher = <<~RUBY
      backup_dir = ARGV[ARGV.index("--backup-dir") + 1] if ARGV.include?("--backup-dir")
      ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json") if backup_dir
      if ARGV.include?("--print-auto-update-ownership-state")
        puts(File.exist?(ownership) ? "owned" : "not_owned")
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        warn "restore failed"
        exit 1
      end
      if ARGV.include?("--disable-subscription-auto-update")
        puts "already_disabled"
        exit 0
      end
      exit 1
    RUBY
    with_uninstaller_package(patcher_source: patcher) do |uninstaller|
      Dir.mktmpdir do |home|
        backup_dir = File.join(home, "Library", "Application Support", "ClaudeEasy", "backups")
        FileUtils.mkdir_p(backup_dir)
        ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json")
        File.write(ownership, "{}")
        usage_state = usage_state_path(home)
        FileUtils.mkdir_p(File.dirname(usage_state))
        File.write(usage_state, "owned")

        stdout, _stderr, status = run_script(uninstaller, home: home)

        assert_equal 1, status.exitstatus
        assert File.file?(ownership)
        assert File.file?(usage_state)
        assert_includes stdout, "无法恢复"
      end
    end
  end

end
