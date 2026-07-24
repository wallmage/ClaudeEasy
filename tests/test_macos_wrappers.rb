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
OPERATION_LOCK = File.join(ROOT, "claude-easy/scripts/macos/operation_lock.rb")

class MacosWrapperTest < Minitest::Test
  include MacosRuntimeFixture

  REQUIRED_RESULT_FIELDS = %w[
    schema version command platform client operation ok status code exit_code summary_zh
    profile changes checks items messages warnings
  ].freeze

  def run_script(path, *arguments, home:, extra_env: {})
    state = File.join(home, "usage-profile.plist")
    env = {
      "HOME" => home,
      "CLAUDE_EASY_USAGE_STATE_PATH" => state,
      "CLAUDE_EASY_USAGE_PROFILE" => nil,
      "CLAUDE_EASY_PROFILE_DIR" => nil
    }.merge(extra_env)
    stdout, stderr, status = Open3.capture3(env, "/bin/sh", path, *arguments)
    [stdout, stderr, status, state]
  end

  def require_production_probe!
    skip "set CLAUDE_EASY_RUN_PRODUCTION_PROBES=1 to run known production-failure probes" unless
      ENV["CLAUDE_EASY_RUN_PRODUCTION_PROBES"] == "1"
  end

  def with_supported_app(home)
    FileUtils.mkdir_p(File.join(home, "Applications", "ClashX Meta.app"))
    yield
  end

  def install_fake_mihomo(home)
    core = File.join(
      home, "Applications", "ClashX Meta.app", "Contents", "Resources",
      "com.metacubex.ClashX.ProxyConfigHelper.meta"
    )
    FileUtils.mkdir_p(File.dirname(core))
    File.write(core, <<~SH)
      #!/bin/sh
      /usr/bin/printf '%s\n' "$*" >> "$HOME/fake-mihomo-arguments.log"
      if [ "${1:-}" = "-v" ]; then
        /usr/bin/printf '%s\n' 'Mihomo Meta v1.19.27 test'
      fi
      exit 0
    SH
    File.chmod(0o700, core)
    core
  end

  def with_missing_mihomo_installer
    Dir.mktmpdir do |package|
      scripts = File.join(package, "scripts")
      FileUtils.mkdir_p(File.join(scripts, "macos"))
      FileUtils.mkdir_p(File.join(package, "references"))
      FileUtils.cp(INSTALLER, File.join(scripts, "install_macos.sh"))
      FileUtils.cp(RESULT_CONTRACT, File.join(scripts, "macos", "result_contract.rb")) if File.file?(RESULT_CONTRACT)
      FileUtils.cp(OPERATION_LOCK, File.join(scripts, "macos", "operation_lock.rb")) if File.file?(OPERATION_LOCK)
      File.write(
        File.join(scripts, "macos", "patch_profiles.rb"),
        "puts 'missing' if ARGV.include?('--print-core-status')\n"
      )
      File.write(File.join(package, "references", "policy.json"), "{}\n")
      yield File.join(scripts, "install_macos.sh")
    end
  end

  def with_supported_mihomo_installer(patcher_source: nil)
    Dir.mktmpdir do |package|
      scripts = File.join(package, "scripts")
      FileUtils.mkdir_p(File.join(scripts, "macos"))
      FileUtils.mkdir_p(File.join(package, "references"))
      FileUtils.cp(INSTALLER, File.join(scripts, "install_macos.sh"))
      FileUtils.cp(RESULT_CONTRACT, File.join(scripts, "macos", "result_contract.rb"))
      FileUtils.cp(OPERATION_LOCK, File.join(scripts, "macos", "operation_lock.rb"))
      File.write(
        File.join(scripts, "macos", "patch_profiles.rb"),
        patcher_source || "if ARGV.include?('--print-core-status'); puts 'supported'; end\nexit 0\n"
      )
      File.write(File.join(package, "references", "policy.json"), "{}\n")
      yield File.join(scripts, "install_macos.sh")
    end
  end

  def with_uninstaller_package(patcher_source:)
    Dir.mktmpdir do |package|
      scripts = File.join(package, "scripts")
      FileUtils.mkdir_p(File.join(scripts, "macos"))
      FileUtils.cp(UNINSTALLER, File.join(scripts, "uninstall_macos.sh"))
      FileUtils.cp(RESULT_CONTRACT, File.join(scripts, "macos", "result_contract.rb"))
      FileUtils.cp(OPERATION_LOCK, File.join(scripts, "macos", "operation_lock.rb"))
      File.write(File.join(scripts, "macos", "patch_profiles.rb"), patcher_source)
      yield File.join(scripts, "uninstall_macos.sh")
    end
  end

  def assert_json_result(stdout, status, command:)
    result = JSON.parse(stdout)
    assert_equal REQUIRED_RESULT_FIELDS.sort, result.keys.sort
    assert_equal "claude-easy.result", result.fetch("schema")
    assert_equal 1, result.fetch("version")
    assert_equal command, result.fetch("command")
    assert_equal "macos", result.fetch("platform")
    assert_equal "clashx-meta", result.fetch("client")
    assert_equal status.exitstatus, result.fetch("exit_code")
    assert_equal stdout.bytes, stdout.encode("UTF-8").bytes
    result
  end

  def test_operation_lock_rejects_symlinked_claude_easy_state_root
    Dir.mktmpdir do |home|
      application_support = File.join(home, "Library", "Application Support")
      outside = File.join(home, "outside-state")
      state_root = File.join(application_support, "ClaudeEasy")
      FileUtils.mkdir_p(application_support)
      FileUtils.mkdir_p(outside)
      File.symlink(outside, state_root)

      _stdout, _stderr, status = Open3.capture3(
        "/usr/bin/ruby",
        OPERATION_LOCK,
        File.join(state_root, "backups", ".claude-easy-wrapper.lock"),
        "/usr/bin/true"
      )

      assert_equal 76, status.exitstatus
      refute File.exist?(File.join(outside, "backups"))
    end
  end

  def test_production_probe_uninstall_preserves_a_file_replaced_after_staging
    require_production_probe!
    patcher = <<~'RUBY'
      backup_dir = ARGV[ARGV.index("--backup-dir") + 1] if ARGV.include?("--backup-dir")
      ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json") if backup_dir
      preference = File.join(ENV.fetch("HOME"), "auto-update-state")
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
        state = File.join(home, "usage-profile.plist")
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
            readers << Thread.new { stdout << out.read }
            readers << Thread.new { stderr << error.read }
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

  def test_production_probe_shared_wrapper_lock_prevents_uninstall_from_deleting_a_concurrent_install
    require_production_probe!
    patcher = <<~'RUBY'
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      with_uninstaller_package(patcher_source: patcher) do |uninstaller|
        Dir.mktmpdir do |home|
          with_supported_app(home) do
            install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
            FileUtils.mkdir_p(install_dir)
            File.binwrite(File.join(install_dir, "patch_profiles.rb"), "owned-patcher")
            File.binwrite(File.join(install_dir, "policy.json"), "{}")
            state = File.join(home, "usage-profile.plist")
            system("/usr/bin/plutil", "-create", "xml1", state)
            system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
            system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)

            ready = File.join(home, "uninstall-delete-ready")
            continue_path = File.join(home, "uninstall-delete-continue")
            anchor = "  /bin/rm -f \\\n"
            source = File.binread(uninstaller)
            assert_equal 1, source.scan(anchor).length
            instrumented = <<~'SH'
              /usr/bin/touch "$CLAUDE_EASY_TEST_READY"
              while [ ! -e "$CLAUDE_EASY_TEST_CONTINUE" ]; do
                /bin/sleep 0.01
              done
            SH
            File.binwrite(uninstaller, source.sub(anchor, instrumented + anchor))

            env = {
              "HOME" => home,
              "CLAUDE_EASY_USAGE_STATE_PATH" => state,
              "CLAUDE_EASY_USAGE_PROFILE" => nil,
              "CLAUDE_EASY_PROFILE_DIR" => nil,
              "CLAUDE_EASY_TEST_READY" => ready,
              "CLAUDE_EASY_TEST_CONTINUE" => continue_path
            }
            uninstall_stdout = +""
            uninstall_stderr = +""
            uninstall_thread = nil
            readers = []
            uninstall_status = nil
            first_install = nil
            begin
              Open3.popen3(env, "/bin/sh", uninstaller, "--json") do |stdin, out, error, thread|
                uninstall_thread = thread
                stdin.close
                readers << Thread.new { uninstall_stdout << out.read }
                readers << Thread.new { uninstall_stderr << error.read }
                deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
                until File.exist?(ready)
                  raise "uninstaller never reached the pre-delete gate" if
                    Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
                  sleep 0.01
                end

                first_install = run_script(installer, "--profile", "2", "--json", home: home)
                File.binwrite(continue_path, "continue")
                raise "uninstaller did not exit after the pre-delete gate" unless thread.join(10)
                uninstall_status = thread.value
              end
            ensure
              File.binwrite(continue_path, "continue") rescue nil
              if uninstall_thread&.alive?
                Process.kill("KILL", uninstall_thread.pid) rescue nil
                uninstall_thread.join
              end
              readers.each(&:join)
            end

            first_stdout, first_stderr, first_status, = first_install
            refute first_status.success?,
                   "concurrent installer escaped the uninstall operation lock: #{first_stdout}\n#{first_stderr}"
            first_result = assert_json_result(first_stdout, first_status, command: "install")
            assert_equal "operation_in_progress", first_result.fetch("code")
            assert uninstall_status.success?, "#{uninstall_stdout}\n#{uninstall_stderr}"

            second_stdout, second_stderr, second_status, = run_script(
              installer, "--profile", "2", "--json", home: home
            )
            assert second_status.success?, "#{second_stdout}\n#{second_stderr}"
            saved_profile, saved_error, saved_status = Open3.capture3(
              "/usr/bin/plutil", "-extract", "Profile", "raw", state
            )
            assert saved_status.success?, saved_error
            assert_equal "2", saved_profile.strip
          end
        end
      end
    end
  end

  def test_production_probe_install_recovers_a_killed_ready_uninstall_before_changing_profile
    require_production_probe!
    patcher = <<~'RUBY'
      backup_dir = ARGV[ARGV.index("--backup-dir") + 1] if ARGV.include?("--backup-dir")
      ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json") if backup_dir
      preference = File.join(ENV.fetch("HOME"), "auto-update-state")
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(preference, "disabled")
        File.write(ownership, "{}") unless File.exist?(ownership)
        puts "already_disabled"
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.write(preference, "enabled")
        File.delete(ownership) if File.exist?(ownership)
        puts "restored"
        exit 0
      end
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
          state = File.join(home, "usage-profile.plist")
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "3", state)
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
          refute File.exist?(ownership), "installer retained stale automatic-update ownership"
          assert_equal "enabled", File.binread(preference)
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

      backup_dir = ARGV[ARGV.index("--backup-dir") + 1] if ARGV.include?("--backup-dir")
      profile_dir = ARGV[ARGV.index("--profile-dir") + 1] if ARGV.include?("--profile-dir")
      profile = File.join(profile_dir, "friend.yaml") if profile_dir
      transaction = File.join(backup_dir, ".claude-easy-profile-transaction.json") if backup_dir
      ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json") if backup_dir
      preference = File.join(ENV.fetch("HOME"), "auto-update-state")
      runtime = File.join(ENV.fetch("HOME"), "runtime-profile")
      original = File.join(ENV.fetch("HOME"), "original-profile")

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
        File.binwrite(profile, File.binread(original))
        File.binwrite(runtime, "original")
        File.delete(transaction)
        puts "recovered"
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
          state = File.join(home, "usage-profile.plist")
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
          File.join(home, "usage-profile.plist") => "owned-usage-state",
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
      end
    end
  end

  def test_uninstaller_resumes_after_kill_during_file_restore
    patcher = <<~'RUBY'
      backup_dir = ARGV[ARGV.index("--backup-dir") + 1] if ARGV.include?("--backup-dir")
      ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json") if backup_dir
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
        state = File.join(home, "usage-profile.plist")
        ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json")
        original = ("owned-patcher-" * 65_536).b
        File.binwrite(installed_patcher, original)
        File.binwrite(state, "owned-state")
        File.binwrite(ownership, "{}")
        ready = File.join(home, "restore-ready")
        source = File.binread(uninstaller)
        old_restore = '  /bin/cp -p "$slot" "$destination"' + "\n"
        atomic_restore =
          "  if /bin/ln \"$slot\" \"$destination\"; then\n" \
          "    return 0\n" \
          "  fi\n"
        direct_copy_restore = false
        if source.include?(old_restore)
          direct_copy_restore = true
          injected = <<~'SH'
            /usr/bin/ruby -e '
              source, destination, ready = ARGV
              bytes = File.binread(source)
              File.open(destination, "wb") do |file|
                file.write(bytes.byteslice(0, bytes.bytesize / 2))
                file.flush
                file.fsync
                File.write(ready, "ready")
                sleep 30
              end
            ' "$slot" "$destination" "$CLAUDE_EASY_TEST_RESTORE_READY"
          SH
          source = source.sub(old_restore, injected)
        elsif source.include?(atomic_restore)
          instrumented = atomic_restore.sub(
            "    return 0\n",
            "    /usr/bin/touch \"$CLAUDE_EASY_TEST_RESTORE_READY\"\n" \
            "    while :; do /bin/sleep 1; done\n"
          )
          source = source.sub(atomic_restore, instrumented)
        else
          flunk "uninstaller restore publication is not recognized"
        end
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

        if direct_copy_restore
          refute_equal original, File.binread(installed_patcher),
                       "fault injection must interrupt the old direct-copy restore"
        else
          assert File.binread(installed_patcher) == original
        end
        recovery_entry = "restore_uncommitted_uninstall\n\nAUTO_UPDATE_OWNED=0"
        resume_source = File.binread(UNINSTALLER)
        assert_equal 1, resume_source.scan(recovery_entry).length
        File.binwrite(
          uninstaller,
          resume_source.sub(
            recovery_entry,
            "restore_uncommitted_uninstall\nexit 99\n\nAUTO_UPDATE_OWNED=0"
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

  def test_uninstaller_discards_a_stage_killed_before_ready
    with_uninstaller_package(patcher_source: "exit 1\n") do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        staging = File.join(install_dir, ".claude-easy-uninstall-staging")
        installed_patcher = File.join(install_dir, "patch_profiles.rb")
        original = "owned-patcher".b
        FileUtils.mkdir_p(staging)
        File.binwrite(installed_patcher, original)
        File.binwrite(File.join(staging, "patcher"), "partial")
        File.binwrite(File.join(staging, "patcher.meta"), "present:incomplete\n")

        recovery_entry = "restore_uncommitted_uninstall\n\nAUTO_UPDATE_OWNED=0"
        source = File.binread(uninstaller)
        assert_equal 1, source.scan(recovery_entry).length
        File.binwrite(
          uninstaller,
          source.sub(
            recovery_entry,
            "restore_uncommitted_uninstall\nexit 99\n\nAUTO_UPDATE_OWNED=0"
          )
        )

        _stdout, _stderr, status, = run_script(uninstaller, home: home)

        assert_equal 99, status.exitstatus
        refute File.exist?(staging)
        assert File.binread(installed_patcher) == original
      end
    end
  end

  def test_installer_json_mode_returns_one_contract_object_for_help_and_errors
    Dir.mktmpdir do |home|
      stdout, stderr, status = run_script(INSTALLER, "--help", "--json", home: home)
      assert status.success?
      assert_empty stderr
      assert_json_result(stdout, status, command: "install")

      stdout, stderr, status = run_script(INSTALLER, "--unknown", "--json", home: home)
      assert_equal 64, status.exitstatus
      assert_empty stderr
      result = assert_json_result(stdout, status, command: "install")
      assert_equal "invalid_request", result.fetch("status")
    end
  end

  def test_installer_json_mode_reports_saved_profile_without_extra_output
    with_supported_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          _stdout, _stderr, status = run_script(installer, "--profile", "1", home: home)
          assert status.success?

          stdout, stderr, status = run_script(installer, "--show-profile", "--json", home: home)
          assert status.success?
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal 1, result.fetch("profile")
        end
      end
    end
  end

  def test_installer_keeps_pending_uninstall_when_recovery_program_is_missing
    with_supported_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          staging = File.join(
            home, "Library", "Application Support", "ClaudeEasy",
            ".claude-easy-uninstall-staging"
          )
          FileUtils.mkdir_p(staging)
          File.binwrite(File.join(staging, "READY"), "")

          stdout, stderr, status, state = run_script(
            installer, "--profile", "2", "--json", home: home
          )

          assert_equal 6, status.exitstatus
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "uninstall_recovery", result.fetch("operation")
          assert_equal "uninstall_recovery_failed", result.fetch("code")
          assert File.file?(File.join(staging, "READY"))
          refute File.exist?(state)
        end
      end
    end
  end

  def test_uninstaller_json_mode_returns_one_contract_object
    Dir.mktmpdir do |home|
      stdout, stderr, status = run_script(UNINSTALLER, "--json", home: home)
      assert status.success?, stdout
      assert_empty stderr
      result = assert_json_result(stdout, status, command: "uninstall")
      refute_includes JSON.generate(result), home
    end
  end

  def test_uninstaller_rejects_unknown_arguments_without_removing_state
    Dir.mktmpdir do |home|
      state = File.join(home, "usage-profile.plist")
      File.write(state, "owned")

      stdout, _stderr, status = run_script(UNINSTALLER, "--typo", home: home)

      assert_equal 64, status.exitstatus
      assert_includes stdout, "用法："
      assert File.file?(state)
    end
  end

  def test_installer_help_and_argument_errors_have_stable_exit_codes
    Dir.mktmpdir do |home|
      stdout, _stderr, status = run_script(INSTALLER, "--help", home: home)
      assert status.success?
      assert_includes stdout, "用法："

      _stdout, _stderr, status = run_script(INSTALLER, "--unknown", home: home)
      assert_equal 64, status.exitstatus

      _stdout, _stderr, status = run_script(INSTALLER, "--profile", home: home)
      assert_equal 64, status.exitstatus

      stdout, _stderr, status = run_script(INSTALLER, "--profile", "4", home: home)
      assert_equal 64, status.exitstatus
      assert_includes stdout, "用途档位无效"

      _stdout, _stderr, status = run_script(
        INSTALLER, "--show-profile", "--safe-update", home: home
      )
      assert_equal 64, status.exitstatus

      _stdout, _stderr, status = run_script(
        INSTALLER, "--show-profile", "--profile", "1", home: home
      )
      assert_equal 64, status.exitstatus
    end
  end

  def test_installer_reports_unset_profile_without_modifying_state
    Dir.mktmpdir do |home|
      stdout, _stderr, status, state = run_script(INSTALLER, home: home)
      assert_equal 10, status.exitstatus
      assert_includes stdout, "还没有选择用途档位"
      refute File.exist?(state)

      stdout, _stderr, status = run_script(INSTALLER, "--show-profile", home: home)
      assert status.success?
      assert_equal "unset\n", stdout
    end
  end

  def test_profiles_one_and_two_are_saved_and_apply_the_common_subscription_baseline
    with_supported_mihomo_installer do |installer|
      [1, 2].each do |profile|
        Dir.mktmpdir do |home|
          with_supported_app(home) do
            stdout, _stderr, status, state = run_script(installer, "--profile", profile.to_s, home: home)
            assert status.success?, stdout
            assert File.file?(state)
            assert_includes stdout, "已保存用途档位 #{profile}"
            assert_includes stdout, "全部订阅都已使用同一套国内域名直连规则"

            stdout, _stderr, status = run_script(installer, "--show-profile", home: home)
            assert status.success?
            assert_equal "#{profile}\n", stdout

            stdout, _stderr, status = run_script(installer, home: home)
            assert status.success?, stdout
            refute_includes stdout, "已保存用途档位"
          end
        end
      end
    end
  end

  def test_installer_runs_the_real_ruby_patcher_and_mihomo_validation
    Dir.mktmpdir do |home|
      with_supported_app(home) do
        install_fake_mihomo(home)
        profiles = File.join(home, "profiles")
        FileUtils.mkdir_p(profiles)
        profile = File.join(profiles, "friend.yaml")
        original = <<~YAML
          mixed-port: 7890
          proxies:
            - name: node
              type: ss
              server: proxy.invalid
              cipher: aes-128-gcm
              password: fixture-secret
          proxy-groups:
            - name: Proxy
              type: select
              proxies:
                - node
          dns:
            enable: true
            nameserver:
              - 223.5.5.5
          rules:
            - MATCH,Proxy
        YAML
        File.write(profile, original)

        preferences_fixture = write_release_preferences_fixture(home)
        controller_server, controller_thread, controller_socket_path, controller_requests =
          start_release_controller(home)
        connectivity_server, connectivity_thread =
          start_release_connectivity_server(home)
        begin
          stdout, stderr, status, state = run_script(
            INSTALLER, "--profile", "1", home: home,
            extra_env: {
              "CLAUDE_EASY_PROFILE_DIR" => profiles,
              "RUBYOPT" => "-r#{preferences_fixture}"
            }
          )
        ensure
          stop_release_runtime_fixture(
            controller_server: controller_server,
            controller_thread: controller_thread,
            controller_socket_path: controller_socket_path,
            connectivity_server: connectivity_server,
            connectivity_thread: connectivity_thread
          )
        end

        assert status.success?, "#{controller_requests.inspect}\n#{stdout}\n#{stderr}"
        assert_empty stderr
        assert File.file?(state)
        output = File.read(profile)
        refute_equal original, output
        assert_includes output, "claude-easy-cn-domain"
        assert_includes output, "RULE-SET,claude-easy-cn-domain,DIRECT"
        assert Dir.glob(File.join(home, "Library/Application Support/ClaudeEasy/backups/*.backup")).any?
        core_arguments = File.read(File.join(home, "fake-mihomo-arguments.log"))
        assert_match(/^-v$/m, core_arguments)
        assert_includes core_arguments, " -t -f "
      end
    end
  end

  def test_environment_profile_is_supported_but_invalid_environment_is_rejected
    with_supported_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, _stderr, status = run_script(
            installer, home: home, extra_env: { "CLAUDE_EASY_USAGE_PROFILE" => "1" }
          )
          assert status.success?, stdout
          assert_includes stdout, "已保存用途档位 1"
        end
      end
    end

    Dir.mktmpdir do |home|
      stdout, _stderr, status = run_script(
        INSTALLER, home: home, extra_env: { "CLAUDE_EASY_USAGE_PROFILE" => "bad" }
      )
      assert_equal 64, status.exitstatus
      assert_includes stdout, "用途档位无效"
    end
  end

  def test_profile_three_fails_closed_before_saving_when_mihomo_is_missing
    with_missing_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, _stderr, status, state = run_script(installer, "--profile", "3", home: home)
          assert_equal 8, status.exitstatus
          assert_includes stdout, "没有找到可用的 Mihomo"
          refute File.exist?(state)
        end
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
      exit 1
    RUBY
    with_supported_mihomo_installer(patcher_source: failing_patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = File.join(home, "usage-profile.plist")
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)
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
        File.write(File.join(ENV.fetch("HOME"), "safe-update-profile"), profile)
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
          state = File.join(home, "usage-profile.plist")
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)
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
          assert_equal "3", File.read(File.join(home, "safe-update-profile"))
        end
      end
    end
  end

  def test_signal_after_profile_commit_preserves_outer_profile_state
    patcher = <<~'RUBY'
      home = ENV.fetch("HOME")
      File.open(File.join(home, "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(File.join(home, "auto-update-owned"), "disabled")
        puts "disabled"
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.delete(File.join(home, "auto-update-owned")) if File.exist?(File.join(home, "auto-update-owned"))
        puts "restored"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      profile_index = ARGV.index("--usage-profile")
      profile = ARGV.fetch(profile_index + 1)
      operation = ARGV.include?("--safe-update-all") ? "safe-update" : "install"
      File.write(File.join(home, "#{operation}-committed"), profile)
      if ENV["CLAUDE_EASY_TEST_SIGNAL_SCOPE"] == "group"
        Process.kill("TERM", -Process.getpgrp)
      else
        Process.kill("TERM", Process.ppid)
      end
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      %w[install safe-update].each do |operation|
        %w[parent group].each do |signal_scope|
          [false, true].each do |json|
            Dir.mktmpdir do |home|
              with_supported_app(home) do
                state = File.join(home, "usage-profile.plist")
                system("/usr/bin/plutil", "-create", "xml1", state)
                system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
                system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)
                arguments = ["--profile", "3"]
                arguments.unshift("--safe-update") if operation == "safe-update"
                arguments << "--json" if json
                env = {
                  "HOME" => home,
                  "CLAUDE_EASY_USAGE_STATE_PATH" => state,
                  "CLAUDE_EASY_USAGE_PROFILE" => nil,
                  "CLAUDE_EASY_PROFILE_DIR" => nil,
                  "CLAUDE_EASY_TEST_SIGNAL_SCOPE" => signal_scope
                }

                stdout, _stderr, status = Open3.capture3(
                  env, "/bin/sh", installer, *arguments, pgroup: true
                )

                assert_equal 143, status.exitstatus
                if json
                  result = assert_json_result(stdout, status, command: "install")
                  assert_equal "partial", result.fetch("status")
                  expected_code = if signal_scope == "group"
                                    "operation_interrupted_recovery_intent"
                                  else
                                    "operation_committed_interrupted"
                                  end
                  assert_equal expected_code, result.fetch("code")
                end
                assert_equal "3", File.read(File.join(home, "#{operation}-committed"))
                assert File.exist?(File.join(home, "auto-update-owned"))
                saved_profile, error, read_status = Open3.capture3(
                  "/usr/bin/plutil", "-extract", "Profile", "raw", state
                )
                assert read_status.success?, error
                assert_equal "3", saved_profile.strip
                calls = File.read(File.join(home, "patcher-calls.log")).lines.map(&:strip)
                assert calls.any? { |call| call.include?("--disable-subscription-auto-update") }
                refute calls.any? { |call| call.include?("--restore-owned-subscription-auto-update") }
              end
            end
          end
        end
      end
    end
  end

  def test_result_failure_after_profile_commit_preserves_outer_profile_state
    patcher = <<~'RUBY'
      home = ENV.fetch("HOME")
      File.open(File.join(home, "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(File.join(home, "auto-update-owned"), "disabled")
        puts "disabled"
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.delete(File.join(home, "auto-update-owned")) if File.exist?(File.join(home, "auto-update-owned"))
        puts "restored"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      profile_index = ARGV.index("--usage-profile")
      profile = ARGV.fetch(profile_index + 1)
      operation = ARGV.include?("--safe-update-all") ? "safe-update" : "install"
      File.write(File.join(home, "#{operation}-committed"), profile)
      receipt_index = ARGV.index("--wrapper-commit-receipt")
      nonce_index = ARGV.index("--wrapper-commit-nonce")
      if receipt_index && nonce_index
        File.binwrite(
          ARGV.fetch(receipt_index + 1),
          "1:#{ARGV.fetch(nonce_index + 1)}\n"
        )
      end
      raise Errno::ENOSPC, "injected result write failure"
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      %w[install safe-update].each do |operation|
        [false, true].each do |json|
          Dir.mktmpdir do |home|
            with_supported_app(home) do
              state = File.join(home, "usage-profile.plist")
              system("/usr/bin/plutil", "-create", "xml1", state)
              system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
              system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)
              arguments = ["--profile", "3"]
              arguments.unshift("--safe-update") if operation == "safe-update"
              arguments << "--json" if json

              stdout, _stderr, status = run_script(installer, *arguments, home: home)

              assert_equal 1, status.exitstatus
              if json
                result = assert_json_result(stdout, status, command: "install")
                assert_equal "partial", result.fetch("status")
                assert_equal "operation_committed_result_failed", result.fetch("code")
              end
              assert_equal "3", File.read(File.join(home, "#{operation}-committed"))
              assert File.exist?(File.join(home, "auto-update-owned"))
              saved_profile, error, read_status = Open3.capture3(
                "/usr/bin/plutil", "-extract", "Profile", "raw", state
              )
              assert read_status.success?, error
              assert_equal "3", saved_profile.strip
              calls = File.read(File.join(home, "patcher-calls.log")).lines.map(&:strip)
              refute calls.any? { |call| call.include?("--restore-owned-subscription-auto-update") }
            end
          end
        end
      end
    end
  end

  def test_uncertain_or_unpublished_commit_receipt_preserves_outer_profile_state
    patcher = <<~'RUBY'
      home = ENV.fetch("HOME")
      File.open(File.join(home, "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(File.join(home, "auto-update-owned"), "disabled")
        puts "disabled"
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.delete(File.join(home, "auto-update-owned")) if File.exist?(File.join(home, "auto-update-owned"))
        puts "restored"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      profile_index = ARGV.index("--usage-profile")
      profile = ARGV.fetch(profile_index + 1)
      operation = ARGV.include?("--safe-update-all") ? "safe-update" : "install"
      File.write(File.join(home, "#{operation}-committed"), profile)
      receipt_index = ARGV.index("--wrapper-commit-receipt")
      case ENV.fetch("CLAUDE_EASY_TEST_RECEIPT_OUTCOME")
      when "invalid"
        File.binwrite(ARGV.fetch(receipt_index + 1), "invalid\n")
        exit 1
      when "publish-failed"
        exit 75
      when "killed"
        Process.kill("KILL", Process.pid)
      else
        raise "unexpected receipt outcome"
      end
    RUBY
    expected_codes = {
      "invalid" => "operation_result_unknown_recovery_intent",
      "publish-failed" => "operation_committed_result_failed",
      "killed" => "operation_result_unknown_recovery_intent"
    }
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      expected_codes.each do |receipt_outcome, expected_code|
        %w[install safe-update].each do |operation|
          [false, true].each do |json|
            Dir.mktmpdir do |home|
              with_supported_app(home) do
                state = File.join(home, "usage-profile.plist")
                system("/usr/bin/plutil", "-create", "xml1", state)
                system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
                system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)
                arguments = ["--profile", "3"]
                arguments.unshift("--safe-update") if operation == "safe-update"
                arguments << "--json" if json

                stdout, _stderr, status = run_script(
                  installer, *arguments, home: home,
                  extra_env: { "CLAUDE_EASY_TEST_RECEIPT_OUTCOME" => receipt_outcome }
                )

                assert_equal 1, status.exitstatus
                if json
                  result = assert_json_result(stdout, status, command: "install")
                  assert_equal "partial", result.fetch("status")
                  assert_equal expected_code, result.fetch("code")
                end
                assert_equal "3", File.read(File.join(home, "#{operation}-committed"))
                assert File.exist?(File.join(home, "auto-update-owned"))
                saved_profile, error, read_status = Open3.capture3(
                  "/usr/bin/plutil", "-extract", "Profile", "raw", state
                )
                assert read_status.success?, error
                assert_equal "3", saved_profile.strip
                calls = File.read(File.join(home, "patcher-calls.log")).lines.map(&:strip)
                refute calls.any? { |call| call.include?("--restore-owned-subscription-auto-update") }
              end
            end
          end
        end
      end
    end
  end

  def test_profile_three_restores_auto_update_when_a_later_step_fails
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

  def test_failed_profile_three_reinstall_preserves_preexisting_auto_update_ownership
    patcher = <<~RUBY
      File.open(File.join(ENV.fetch("HOME"), "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        puts "already_disabled"
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
          ownership = File.join(
            home, "Library", "Application Support", "ClaudeEasy", "backups",
            "clashx-meta-kAutoUpdateEnable.state.json"
          )
          FileUtils.mkdir_p(File.dirname(ownership))
          File.write(ownership, "preexisting-installed-state")

          _stdout, _stderr, status = run_script(installer, "--profile", "3", home: home)

          assert_equal 1, status.exitstatus
          calls = File.read(File.join(home, "patcher-calls.log"))
          refute_includes calls, "--restore-owned-subscription-auto-update"
          assert_equal "preexisting-installed-state", File.read(ownership)
        end
      end
    end
  end

  def test_unsafe_profile_state_is_rejected_before_profile_three_changes_settings
    patcher = <<~RUBY
      File.open(File.join(ENV.fetch("HOME"), "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      puts "supported" if ARGV.include?("--print-core-status")
      puts "disabled" if ARGV.include?("--disable-subscription-auto-update")
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = File.join(home, "usage-profile.plist")
          File.symlink(File.join(home, "outside-state"), state)
          File.write(File.join(home, "patcher-calls.log"), "")

          stdout, _stderr, status = run_script(installer, "--profile", "3", home: home)

          assert_equal 7, status.exitstatus
          assert_includes stdout, "档位保存位置不安全"
          calls = File.read(File.join(home, "patcher-calls.log"))
          refute_includes calls, "--disable-subscription-auto-update"
          refute_includes calls, "--snapshot-initial"
        end
      end
    end
  end

  def test_auto_update_restore_failure_is_reported_as_partial
    patcher = <<~RUBY
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        puts "disabled"
        exit 0
      end
      exit 1 if ARGV.include?("--restore-owned-subscription-auto-update")
      exit 0 if ARGV.include?("--snapshot-initial")
      exit 1
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, stderr, status = run_script(installer, "--profile", "3", "--json", home: home)

          assert_equal 1, status.exitstatus
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "partial", result.fetch("status")
          assert_equal "auto_update_restore_failed", result.fetch("code")
        end
      end
    end
  end

  def test_json_wrapper_preserves_a_partial_safe_update_result
    patcher = <<~RUBY
      require "json"
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--safe-update-all")
        puts JSON.generate(
          "status" => "partial",
          "code" => "safe_update_runtime_pending",
          "summary_zh" => "订阅文件已恢复，但运行内核恢复失败。"
        )
        exit 1
      end
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, stderr, status = run_script(
            installer, "--safe-update", "--profile", "1", "--json", home: home
          )

          assert_equal 1, status.exitstatus
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "partial", result.fetch("status")
          assert_equal "safe_update_runtime_pending", result.fetch("code")
        end
      end
    end
  end

  def test_profile_three_downgrade_requires_safe_uninstall
    with_supported_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = File.join(home, "usage-profile.plist")
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "3", state)
          original = File.binread(state)

          stdout, _stderr, status = run_script(installer, "--profile", "1", home: home)

          assert_equal 1, status.exitstatus
          assert_includes stdout, "先运行安全卸载"
          assert_equal original, File.binread(state)
        end
      end
    end
  end

  def test_safe_update_requires_the_same_mihomo_preflight
    with_missing_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, _stderr, status = run_script(installer, "--safe-update", "--profile", "1", home: home)
          assert_equal 8, status.exitstatus
          assert_includes stdout, "没有找到可用的 Mihomo"
        end
      end
    end
  end

  def test_installer_rejects_non_macos_and_missing_custom_directory
    Dir.mktmpdir do |home|
      fake_bin = File.join(home, "bin")
      FileUtils.mkdir_p(fake_bin)
      uname = File.join(fake_bin, "uname")
      File.write(uname, "#!/bin/sh\nprintf 'Linux\\n'\n")
      File.chmod(0o700, uname)
      stdout, _stderr, status = run_script(
        INSTALLER, "--profile", "1", home: home,
        extra_env: { "PATH" => "#{fake_bin}:/usr/bin:/bin" }
      )
      assert_equal 2, status.exitstatus
      assert_includes stdout, "当前系统不是 macOS"
    end

    Dir.mktmpdir do |home|
      with_supported_app(home) do
        missing = File.join(home, "missing-profiles")
        stdout, _stderr, status = run_script(
          INSTALLER, "--profile", "1", home: home,
          extra_env: { "CLAUDE_EASY_PROFILE_DIR" => missing }
        )
        assert_equal 5, status.exitstatus
        assert_includes stdout, "没有找到指定的 ClashX Meta 配置目录"
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
      state = File.join(home, "usage-profile.plist")
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
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.write(File.join(ENV.fetch("HOME"), "restore-auto-update-arguments"), ARGV.join("\\n"))
        backup_dir = ARGV.fetch(ARGV.index("--backup-dir") + 1)
        File.delete(File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json"))
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
        usage_state = File.join(home, "usage-profile.plist")
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
        usage_state = File.join(home, "usage-profile.plist")
        File.write(usage_state, "owned")

        stdout, _stderr, status = run_script(uninstaller, home: home)

        assert_equal 1, status.exitstatus
        assert File.file?(ownership)
        assert File.file?(usage_state)
        assert_includes stdout, "无法恢复"
      end
    end
  end

  def test_uninstaller_rejects_non_macos
    Dir.mktmpdir do |home|
      fake_bin = File.join(home, "bin")
      FileUtils.mkdir_p(fake_bin)
      uname = File.join(fake_bin, "uname")
      File.write(uname, "#!/bin/sh\nprintf 'Linux\\n'\n")
      File.chmod(0o700, uname)
      stdout, _stderr, status = run_script(
        UNINSTALLER, home: home, extra_env: { "PATH" => "#{fake_bin}:/usr/bin:/bin" }
      )
      assert_equal 2, status.exitstatus
      assert_includes stdout, "当前系统不是 macOS"
    end
  end
end
