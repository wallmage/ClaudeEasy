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
      copy_install_package_dependencies(scripts)
      FileUtils.cp(INSTALLER, File.join(scripts, "install_macos.sh"))
      copy_install_package_dependencies(scripts)
      File.write(
        File.join(scripts, "macos", "patch_profiles.rb"),
        "exit 0 if ARGV.include?('--help')\n" \
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

  def with_real_installer_package
    Dir.mktmpdir do |package|
      FileUtils.cp_r(File.join(ROOT, "claude-easy", "scripts"), package)
      references = File.join(package, "references")
      FileUtils.mkdir_p(references)
      FileUtils.cp(
        File.join(ROOT, "claude-easy", "references", "policy.json"),
        File.join(references, "policy.json")
      )
      yield File.join(package, "scripts", "install_macos.sh")
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

  def test_operation_lock_exclusive_rename_never_overwrites_a_destination
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source")
      destination = File.join(directory, "destination")
      File.binwrite(source, "isolated-new")
      File.binwrite(destination, "later-new")

      _stdout, _stderr, status = Open3.capture3(
        "/usr/bin/ruby", OPERATION_LOCK, "--rename-exclusive", source, destination
      )

      assert_equal 76, status.exitstatus
      assert_equal "isolated-new", File.binread(source)
      assert_equal "later-new", File.binread(destination)
    end
  end

  def test_wrappers_reject_a_forged_inherited_lock_before_any_mutation
    with_supported_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, stderr, status, state = run_script(
            installer, "--profile", "1", "--json", home: home,
            extra_env: {
              "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD" => "1",
              "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_FD" => nil,
              "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_IDENTITY" => nil
            }
          )

          refute status.success?, "#{stdout}\n#{stderr}"
          assert_equal "operation_lock_failed", JSON.parse(stdout).fetch("code")
          refute File.exist?(state)
        end
      end
    end

    with_uninstaller_package(patcher_source: "exit 0\n") do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        FileUtils.mkdir_p(install_dir)
        installed = File.join(install_dir, "patch_profiles.rb")
        File.binwrite(installed, "keep")
        stdout, stderr, status = Open3.capture3(
          {
            "HOME" => home,
            "CLAUDE_EASY_USAGE_STATE_PATH" => nil,
            "CLAUDE_EASY_USAGE_PROFILE" => nil,
            "CLAUDE_EASY_PROFILE_DIR" => nil,
            "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD" => "1",
            "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_FD" => nil,
            "CLAUDE_EASY_INTERNAL_OPERATION_LOCK_IDENTITY" => nil
          },
          "/bin/sh", uninstaller, "--json"
        )

        refute status.success?, "#{stdout}\n#{stderr}"
        assert_equal "operation_lock_failed", JSON.parse(stdout).fetch("code")
        assert_equal "keep", File.binread(installed)
      end
    end
  end

  def test_uninstaller_ignores_an_inherited_exit_receipt_in_the_outer_process
    with_uninstaller_package(patcher_source: "exit 0\n") do |uninstaller|
      Dir.mktmpdir do |home|
        FileUtils.mkdir_p(File.join(home, "tmp"))
        victim = File.join(home, "victim.txt")
        sentinel = "sentinel-must-survive\n"
        handler_ran = false

        [0.03, 0.05, 0.10, 0.15].each do |delay|
          File.binwrite(victim, sentinel)
          env = {
            "HOME" => home,
            "TMPDIR" => File.join(home, "tmp"),
            "CLAUDE_EASY_UNINSTALL_EXIT_RECEIPT" => victim
          }
          Open3.popen3(env, "/bin/sh", uninstaller, pgroup: true) do |stdin, stdout, stderr, thread|
            stdin.close
            readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
            sleep(delay)
            Process.kill("TERM", -thread.pid) rescue nil
            thread.join(10) || flunk("uninstaller did not exit after TERM")
            output = readers.map(&:value).join
            handler_ran = output.include?("卸载流程意外中止")
          ensure
            Process.kill("KILL", -thread.pid) rescue nil
          end
          break if handler_ran
        end

        assert handler_ran, "TERM never reached the trap-armed outer-process window"
        assert_equal sentinel, File.binread(victim)
      end
    end
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

  def test_uninstaller_never_deletes_install_files_before_ready_is_durable
    with_uninstaller_package(patcher_source: "exit 0\n") do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        FileUtils.mkdir_p(File.join(install_dir, "backups"))
        originals = {
          File.join(install_dir, "patch_profiles.rb") => "patcher",
          File.join(install_dir, "policy.json") => "policy",
          usage_state_path(home) => "usage"
        }
        originals.each { |path, bytes| File.binwrite(path, bytes) }
        marker = File.join(home, "ready-sync-failed")
        prepend_operation_lock_fault(uninstaller, <<~'RUBY')
          if ARGV[0] == "--sync-file" &&
             ARGV[1].to_s.end_with?("/READY") &&
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

  def test_uninstaller_exit_fallback_reports_committed_and_failed_recovery_phases
    [
      ["--sync-file", "/COMMITTED", "uninstall_committed_interrupted", "partial"],
      ["--sync-directory", nil, "uninstall_recovery_failed", "partial"]
    ].each do |fault_command, suffix, expected_code, expected_status|
      with_uninstaller_package(patcher_source: "exit 0\n") do |uninstaller|
        Dir.mktmpdir do |home|
          install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
          FileUtils.mkdir_p(File.join(install_dir, "backups"))
          File.binwrite(File.join(install_dir, "patch_profiles.rb"), "patcher")
          File.binwrite(File.join(install_dir, "policy.json"), "policy")
          File.binwrite(usage_state_path(home), "usage")
          match = if suffix
                    'ARGV[1].to_s.end_with?(ENV.fetch("CLAUDE_EASY_TEST_SUFFIX"))'
                  else
                    'ARGV[1].to_s == ENV.fetch("CLAUDE_EASY_TEST_INSTALL_DIR")'
                  end
          prepend_operation_lock_fault(uninstaller, <<~RUBY)
            if ARGV[0] == #{fault_command.inspect} && #{match}
              exit 76
            end
          RUBY

          stdout, stderr, status = Open3.capture3(
            {
              "HOME" => home,
              "CLAUDE_EASY_USAGE_STATE_PATH" => nil,
              "CLAUDE_EASY_USAGE_PROFILE" => nil,
              "CLAUDE_EASY_PROFILE_DIR" => nil,
              "CLAUDE_EASY_TEST_SUFFIX" => suffix,
              "CLAUDE_EASY_TEST_INSTALL_DIR" => install_dir
            },
            "/bin/sh", uninstaller, "--json"
          )

          assert_equal 76, status.exitstatus, "#{stdout}\n#{stderr}"
          assert_equal 1, stdout.lines.length
          result = assert_json_result(stdout, status, command: "uninstall")
          assert_equal expected_code, result.fetch("code")
          assert_equal expected_status, result.fetch("status")
        end
      end
    end
  end

  def test_uninstaller_exit_fallback_prints_a_default_mode_summary
    with_uninstaller_package(patcher_source: "exit 0\n") do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        FileUtils.mkdir_p(File.join(install_dir, "backups"))
        File.binwrite(usage_state_path(home), "usage")
        prepend_operation_lock_fault(uninstaller, <<~'RUBY')
          if ARGV[0] == "--sync-file" && ARGV[1].to_s.end_with?("/READY")
            exit 76
          end
        RUBY

        stdout, stderr, status = run_script(uninstaller, home: home)

        assert_equal 76, status.exitstatus, stderr
        assert_equal 1, stdout.lines.length
        assert_includes stdout, "已恢复"
      end
    end
  end

  def test_uninstaller_exit_fallback_uses_one_static_json_when_the_emitter_fails
    with_uninstaller_package(patcher_source: "exit 0\n") do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        FileUtils.mkdir_p(File.join(install_dir, "backups"))
        File.binwrite(usage_state_path(home), "usage")
        File.binwrite(
          File.join(File.dirname(uninstaller), "macos", "result_contract.rb"),
          "puts '{\"schema\":\"claude-easy.result\"}'\n"
        )
        prepend_operation_lock_fault(uninstaller, <<~'RUBY')
          if ARGV[0] == "--sync-file" && ARGV[1].to_s.end_with?("/READY")
            exit 76
          end
        RUBY

        stdout, stderr, status = run_script(uninstaller, "--json", home: home)

        assert_equal 76, status.exitstatus, stderr
        assert_equal 1, stdout.lines.length
        result = assert_json_result(stdout, status, command: "uninstall")
        assert_equal "uninstall_interrupted_rolled_back", result.fetch("code")
        refute result.fetch("ok")
      end
    end
  end

  def test_uninstaller_static_json_fallback_keeps_success_semantics
    with_uninstaller_package(patcher_source: "exit 0\n") do |uninstaller|
      File.binwrite(
        File.join(File.dirname(uninstaller), "macos", "result_contract.rb"),
        "puts '{\"schema\":\"claude-easy.result\"}'\n"
      )
      Dir.mktmpdir do |home|
        stdout, stderr, status = run_script(uninstaller, "--help", "--json", home: home)

        assert status.success?, stderr
        assert_empty stderr
        result = assert_json_result(stdout, status, command: "uninstall")
        assert result.fetch("ok")
        assert_equal "ok", result.fetch("status")
        assert_equal "help", result.fetch("code")
      end
    end
  end

  def test_uninstaller_signal_after_ready_emits_one_json_and_restores_every_file
    with_uninstaller_package(patcher_source: "exit 0\n") do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        FileUtils.mkdir_p(File.join(install_dir, "backups"))
        originals = {
          File.join(install_dir, "patch_profiles.rb") => "patcher",
          File.join(install_dir, "policy.json") => "policy",
          usage_state_path(home) => "usage"
        }
        originals.each { |path, bytes| File.binwrite(path, bytes) }
        ready = File.join(home, "signal-ready")
        source = File.binread(uninstaller)
        anchor = "  durable_sync_file \"$UNINSTALL_STAGING/READY\"\n" \
          "  UNINSTALL_READY=1\n"
        assert_equal 1, source.scan(anchor).length
        File.binwrite(uninstaller, source.sub(anchor, anchor + <<~'SH'))
          /usr/bin/touch "$CLAUDE_EASY_TEST_READY"
          while :; do /bin/sleep 1; done
        SH
        env = {
          "HOME" => home,
          "CLAUDE_EASY_USAGE_STATE_PATH" => nil,
          "CLAUDE_EASY_USAGE_PROFILE" => nil,
          "CLAUDE_EASY_PROFILE_DIR" => nil,
          "CLAUDE_EASY_TEST_READY" => ready
        }
        stdout = +""
        stderr = +""
        process_thread = nil
        readers = []
        status = nil
        begin
          Open3.popen3(env, "/bin/sh", uninstaller, "--json", pgroup: true) do |stdin, out, error, thread|
            process_thread = thread
            stdin.close
            readers << capture_stream(out, stdout)
            readers << capture_stream(error, stderr)
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
            until File.exist?(ready)
              raise "uninstaller never reached durable READY" if
                Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              sleep 0.01
            end
            Process.kill("TERM", -thread.pid)
            raise "uninstaller did not exit after TERM" unless thread.join(10)
            status = thread.value
            readers.each(&:join)
          end
        ensure
          Process.kill("KILL", -process_thread.pid) rescue nil
          process_thread&.join
          readers.each(&:join)
        end

        assert_equal 143, status.exitstatus, "#{stdout}\n#{stderr}"
        assert_equal 1, stdout.lines.length
        result = assert_json_result(stdout, status, command: "uninstall")
        assert_equal "uninstall_interrupted_rolled_back", result.fetch("code")
        originals.each { |path, bytes| assert_equal bytes, File.binread(path) }
      end
    end
  end

  def test_installer_does_not_write_usage_state_outside_its_managed_state_directory
    patcher = <<~'RUBY'
      require "json"
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        puts "already_disabled"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      puts JSON.generate(
        "schema" => "claude-easy.result", "version" => 1, "command" => "patch",
        "platform" => "macos", "client" => "clashx-meta", "operation" => "patch_profiles",
        "ok" => true, "status" => "ok", "code" => "patched", "exit_code" => 0,
        "summary_zh" => "配置处理完成。", "profile" => 1,
        "changes" => [], "checks" => [], "items" => [], "messages" => [], "warnings" => []
      ) if ARGV.include?("--json")
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          external_file = File.join(home, "important-user-file")
          canonical_state = File.join(
            home, "Library", "Application Support", "ClaudeEasy", "usage-profile.plist"
          )
          File.binwrite(external_file, "keep-me")

          stdout, stderr, status = Open3.capture3(
            {
              "HOME" => home,
              "CLAUDE_EASY_USAGE_STATE_PATH" => external_file,
              "CLAUDE_EASY_USAGE_PROFILE" => nil,
              "CLAUDE_EASY_PROFILE_DIR" => nil
            },
            "/bin/sh", installer, "--profile", "1", "--json"
          )

          assert status.success?, "#{stdout}\n#{stderr}"
          assert_equal "keep-me", File.binread(external_file)
          assert File.file?(canonical_state)
        end
      end
    end
  end

  def test_uninstaller_does_not_delete_usage_state_outside_its_managed_state_directory
    with_uninstaller_package(patcher_source: "exit 0\n") do |uninstaller|
      Dir.mktmpdir do |home|
        install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
        backup_dir = File.join(install_dir, "backups")
        canonical_state = File.join(install_dir, "usage-profile.plist")
        external_file = File.join(home, "important-user-file")
        FileUtils.mkdir_p(backup_dir)
        File.binwrite(File.join(install_dir, "patch_profiles.rb"), "owned-patcher")
        File.binwrite(File.join(install_dir, "policy.json"), "{}")
        File.binwrite(canonical_state, "owned-state")
        File.binwrite(external_file, "keep-me")

        stdout, stderr, status = Open3.capture3(
          {
            "HOME" => home,
            "CLAUDE_EASY_USAGE_STATE_PATH" => external_file,
            "CLAUDE_EASY_USAGE_PROFILE" => nil,
            "CLAUDE_EASY_PROFILE_DIR" => nil
          },
          "/bin/sh", uninstaller, "--json"
        )

        assert status.success?, "#{stdout}\n#{stderr}"
        assert_equal "keep-me", File.binread(external_file)
        refute File.exist?(canonical_state)
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

  def test_production_probe_shared_wrapper_lock_prevents_uninstall_from_deleting_a_concurrent_install
    require_production_probe!
    patcher = <<~'RUBY'
      require "fileutils"
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
        FileUtils.mkdir_p(backup_dir)
        File.binwrite(preference, "disabled")
        File.binwrite(ownership, "{}") unless already_owned
        puts(already_owned ? "already_disabled_owned" : "disabled")
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.binwrite(preference, "enabled")
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
      with_uninstaller_package(patcher_source: patcher) do |uninstaller|
        Dir.mktmpdir do |home|
          with_supported_app(home) do
            install_dir = File.join(home, "Library", "Application Support", "ClaudeEasy")
            FileUtils.mkdir_p(install_dir)
            File.binwrite(File.join(install_dir, "patch_profiles.rb"), "owned-patcher")
            File.binwrite(File.join(install_dir, "policy.json"), "{}")
            state = usage_state_path(home)
            FileUtils.mkdir_p(File.dirname(state))
            system("/usr/bin/plutil", "-create", "xml1", state)
            system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
            system("/usr/bin/plutil", "-insert", "Profile", "-integer", "1", state)
            File.chmod(0o600, state)

            ready = File.join(home, "uninstall-delete-ready")
            continue_path = File.join(home, "uninstall-delete-continue")
            anchor = '  quarantine_staged_slot "$INSTALL_DIR/patch_profiles.rb" patcher || finish_quarantine_failure' + "\n"
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
                readers << capture_stream(out, uninstall_stdout)
                readers << capture_stream(error, uninstall_stderr)
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
                readers.each(&:join)
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
            assert_equal "disabled", File.binread(File.join(home, "auto-update-state"))
            assert File.file?(
              File.join(
                home, "Library", "Application Support", "ClaudeEasy", "backups",
                "clashx-meta-kAutoUpdateEnable.state.json"
              )
            )
          end
        end
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

        recovery_entry = "restore_uncommitted_or_finish\n\nAUTO_UPDATE_OWNED=0"
        source = File.binread(uninstaller)
        assert_equal 1, source.scan(recovery_entry).length
        File.binwrite(
          uninstaller,
          source.sub(
            recovery_entry,
            "restore_uncommitted_or_finish\nexit 99\n\nAUTO_UPDATE_OWNED=0"
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

  def test_installer_rejects_each_missing_release_dependency_before_creating_state
    INSTALL_PACKAGE_DEPENDENCIES.each do |relative_path|
      with_real_installer_package do |installer|
        scripts = File.dirname(installer)
        FileUtils.rm_f(File.expand_path(relative_path, scripts))
        Dir.mktmpdir do |home|
          with_supported_app(home) do
            stdout, stderr, status = run_script(
              installer, "--profile", "1", "--json", home: home
            )

            assert_equal 6, status.exitstatus, "#{relative_path}\n#{stdout}\n#{stderr}"
            assert_empty stderr
            result = assert_json_result(stdout, status, command: "install")
            assert_equal "incomplete_package", result.fetch("code")
            refute Dir.exist?(
              File.join(home, "Library", "Application Support", "ClaudeEasy")
            ), relative_path
          end
        end
      end
    end
  end

  def test_installer_rejects_a_loadable_module_missing_its_api_before_creating_state
    cases = {
      "macos/patch_profiles/runtime.rb" => "\nmodule ClaudeEasy\n singleton_class.send(:undef_method, :controller_socket)\nend\n",
      "macos/patch_profiles/mihomo.rb" => "\nmodule ClaudeEasy\n singleton_class.send(:undef_method, :mihomo_core_paths)\nend\n",
      "macos/result_contract.rb" => "\nmodule ClaudeEasyResult\n singleton_class.send(:undef_method, :valid_child_json?)\nend\n"
    }
    cases.each do |relative_path, mutation|
      with_real_installer_package do |installer|
        dependency = File.join(File.dirname(installer), relative_path)
        File.open(dependency, "a") { |file| file.write(mutation) }
        Dir.mktmpdir do |home|
          with_supported_app(home) do
            stdout, stderr, status = run_script(installer, "--profile", "1", "--json", home: home)
            assert_equal 6, status.exitstatus, relative_path
            assert_empty stderr
            assert_equal "incomplete_package", assert_json_result(stdout, status, command: "install").fetch("code")
            refute Dir.exist?(File.join(home, "Library", "Application Support", "ClaudeEasy"))
          end
        end
      end
    end
  end

  def test_uninstaller_rejects_each_missing_release_dependency_before_mutating_state
    UNINSTALL_PACKAGE_DEPENDENCIES.each do |relative_path|
      with_real_installer_package do |installer|
        scripts = File.dirname(installer)
        uninstaller = File.join(scripts, "uninstall_macos.sh")
        FileUtils.rm_f(File.expand_path(relative_path, scripts))
        Dir.mktmpdir do |home|
          state = usage_state_path(home)
          FileUtils.mkdir_p(File.dirname(state))
          File.binwrite(state, "owned-state")

          stdout, stderr, status = run_script(uninstaller, "--json", home: home)

          assert_equal 6, status.exitstatus, "#{relative_path}\n#{stdout}\n#{stderr}"
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "uninstall")
          assert_equal "incomplete_package", result.fetch("code")
          assert_equal "owned-state", File.binread(state)
          refute Dir.exist?(File.join(File.dirname(state), ".claude-easy-uninstall-staging"))
        end
      end
    end
  end

  def test_uninstaller_rejects_corrupt_ruby_and_policy_dependencies_before_mutating_state
    UNINSTALL_PACKAGE_DEPENDENCIES.each do |relative_path|
      with_real_installer_package do |installer|
        scripts = File.dirname(installer)
        uninstaller = File.join(scripts, "uninstall_macos.sh")
        dependency = File.expand_path(relative_path, scripts)
        File.binwrite(dependency, relative_path.end_with?(".json") ? "{" : "broken (\n")
        Dir.mktmpdir do |home|
          state = usage_state_path(home)
          FileUtils.mkdir_p(File.dirname(state))
          File.binwrite(state, "owned-state")

          stdout, stderr, status = run_script(uninstaller, "--json", home: home)

          assert_equal 6, status.exitstatus, "#{relative_path}\n#{stdout}\n#{stderr}"
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "uninstall")
          assert_equal "incomplete_package", result.fetch("code")
          assert_equal "owned-state", File.binread(state)
          refute Dir.exist?(File.join(File.dirname(state), ".claude-easy-uninstall-staging"))
        end
      end
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
      FileUtils.rm_f(File.join(File.dirname(installer), "uninstall_macos.sh"))
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
          assert_equal "install", result.fetch("operation")
          assert_equal "incomplete_package", result.fetch("code")
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
      state = usage_state_path(home)
      FileUtils.mkdir_p(File.dirname(state))
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

  def test_installer_rejects_an_existing_invalid_usage_profile_state
    [
      "truncated",
      "<?xml version=\"1.0\"?><plist><dict><key>Version</key><integer>2</integer></dict></plist>",
      "<?xml version=\"1.0\"?><plist><dict><key>Version</key><string>1</string><key>Profile</key><string>3</string></dict></plist>",
      "<?xml version=\"1.0\"?><plist><dict><key>Version</key><integer>1</integer><key>Profile</key><integer>1</integer><key>Profile</key><integer>3</integer></dict></plist>",
      "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Version</key><integer>1<unexpected/></integer><key>Profile</key><integer>3</integer></dict></plist>"
    ].each do |bytes|
      [["--show-profile", "--json"], ["--profile", "1", "--json"],
       ["--profile", "2", "--json"], ["--profile", "3", "--json"]].each do |arguments|
        with_supported_mihomo_installer do |installer|
          Dir.mktmpdir do |home|
            with_supported_app(home) do
              state = usage_state_path(home)
              FileUtils.mkdir_p(File.dirname(state))
              File.binwrite(state, bytes)

              stdout, stderr, status = run_script(installer, *arguments, home: home)

              assert_equal 10, status.exitstatus, "#{arguments.inspect}\n#{stdout}\n#{stderr}"
              assert_empty stderr
              result = assert_json_result(stdout, status, command: "install")
              assert_equal "usage_profile_invalid", result.fetch("code")
              assert_equal bytes, File.binread(state)
              refute Dir.exist?(File.join(File.dirname(state), "backups"))
            end
          end
        end
      end
    end
  end

  def test_installer_rejects_non_private_or_hardlinked_usage_profile_state_before_locking
    %i[public hardlink].each do |variant|
      [["--show-profile", "--json"], ["--profile", "1", "--json"],
       ["--profile", "2", "--json"], ["--profile", "3", "--json"]].each do |arguments|
        with_supported_mihomo_installer do |installer|
          Dir.mktmpdir do |home|
            with_supported_app(home) do
              state = usage_state_path(home)
              FileUtils.mkdir_p(File.dirname(state))
              system("/usr/bin/plutil", "-create", "xml1", state)
              system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
              system("/usr/bin/plutil", "-insert", "Profile", "-integer", "3", state)
              File.chmod(0o600, state)
              if variant == :public
                File.chmod(0o644, state)
              else
                File.link(state, File.join(home, "usage-profile-alias.plist"))
              end
              original = File.binread(state)

              stdout, stderr, status = run_script(installer, *arguments, home: home)

              assert_equal 10, status.exitstatus, "#{variant} #{arguments.inspect}\n#{stdout}\n#{stderr}"
              assert_empty stderr
              result = assert_json_result(stdout, status, command: "install")
              assert_equal "usage_profile_invalid", result.fetch("code")
              assert_equal original, File.binread(state)
              refute Dir.exist?(File.join(File.dirname(state), "backups"))
            end
          end
        end
      end
    end
  end

  def test_installer_reports_an_incomplete_package_when_strict_profile_reader_cannot_load
    cases = {
      "macos/usage_profile_state.rb" => [["--show-profile", "--json"], ["--profile", "3", "--json"]],
      "macos/patch_profiles.rb" => [["--profile", "3", "--json"]],
      "macos/patch_profiles/runtime.rb" => [["--profile", "3", "--json"]]
    }
    cases.each do |relative_path, argument_sets|
      argument_sets.each do |arguments|
        with_real_installer_package do |installer|
          scripts = File.dirname(installer)
          FileUtils.rm_f(File.expand_path(relative_path, scripts))
          Dir.mktmpdir do |home|
            state = usage_state_path(home)
            FileUtils.mkdir_p(File.dirname(state))
            system("/usr/bin/plutil", "-create", "xml1", state)
            system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
            system("/usr/bin/plutil", "-insert", "Profile", "-integer", "3", state)
            File.chmod(0o600, state)
            original = File.binread(state)

            stdout, stderr, status = run_script(installer, *arguments, home: home)

            assert_equal 6, status.exitstatus, "#{relative_path} #{arguments.inspect}\n#{stdout}\n#{stderr}"
            assert_empty stderr
            result = assert_json_result(stdout, status, command: "install")
            assert_equal "incomplete_package", result.fetch("code")
            assert_equal original, File.binread(state)
            refute Dir.exist?(File.join(File.dirname(state), "backups"))
          end
        end
      end
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
        connectivity_server, connectivity_thread, connectivity_ca, mixed_port =
          start_release_connectivity_server(home)
        controller_server, controller_thread, controller_socket_path, controller_requests =
          start_release_controller(home, mixed_port: mixed_port, selector_names: ["Proxy"])
        begin
          stdout, stderr, status, state = run_script(
            INSTALLER, "--profile", "1", home: home,
            extra_env: {
              "CLAUDE_EASY_PROFILE_DIR" => profiles,
              "RUBYOPT" => "-r#{preferences_fixture}",
              "CURL_CA_BUNDLE" => connectivity_ca
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
      %w[install].each do |operation|
        %w[parent group].each do |signal_scope|
          [false, true].each do |json|
            Dir.mktmpdir do |home|
              with_supported_app(home) do
                state = write_usage_profile(home, operation == "safe-update" ? 3 : 1)
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
      print '{"items":[' if ARGV.include?("--json")
      raise Errno::ENOSPC, "injected result write failure"
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      %w[install].each do |operation|
        [false, true].each do |json|
          Dir.mktmpdir do |home|
            with_supported_app(home) do
              state = write_usage_profile(home, operation == "safe-update" ? 3 : 1)
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
      when "commit-uncertain"
        exit 77
      when "killed"
        Process.kill("KILL", Process.pid)
      else
        raise "unexpected receipt outcome"
      end
    RUBY
    expected_codes = {
      "invalid" => "operation_result_unknown_recovery_intent",
      "publish-failed" => "operation_committed_result_failed",
      "commit-uncertain" => "operation_result_unknown_recovery_intent",
      "killed" => "operation_result_unknown_recovery_intent"
    }
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      expected_codes.each do |receipt_outcome, expected_code|
        %w[install].each do |operation|
          [false, true].each do |json|
            Dir.mktmpdir do |home|
              with_supported_app(home) do
                state = write_usage_profile(home, operation == "safe-update" ? 3 : 1)
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

  def test_child_lock_failure_exit_does_not_preserve_an_uncommitted_profile
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
      exit 76
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

          stdout, stderr, status = run_script(installer, "--profile", "3", "--json", home: home)

          refute status.success?, "#{stdout}\n#{stderr}"
          assert_equal "patch_failed", assert_json_result(stdout, status, command: "install").fetch("code")
          saved = Open3.capture2(
            "/usr/bin/plutil", "-extract", "Profile", "raw", state
          ).first.strip
          assert_equal "1", saved
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

  def test_existing_profile_keeps_auto_update_disabled_when_disable_exits_after_changing_it
    patcher = <<~'RUBY'
      home = ENV.fetch("HOME")
      calls = File.join(home, "patcher-calls.log")
      File.open(calls, "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(File.join(home, "auto-update"), "disabled")
        File.write(File.join(home, "auto-update-owned"), "prepared")
        exit 1
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.write(File.join(home, "auto-update"), "enabled")
        File.delete(File.join(home, "auto-update-owned"))
        puts "restored"
        exit 0
      end
      exit 0
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

          _stdout, _stderr, status = run_script(installer, "--profile", "3", home: home)

          assert_equal 9, status.exitstatus
          assert_equal "disabled", File.read(File.join(home, "auto-update"))
          assert File.exist?(File.join(home, "auto-update-owned"))
          saved, error, read_status = Open3.capture3(
            "/usr/bin/plutil", "-extract", "Profile", "raw", state
          )
          assert read_status.success?, error
          assert_equal "1", saved.strip
          refute_includes File.read(File.join(home, "patcher-calls.log")),
                          "--restore-owned-subscription-auto-update"
        end
      end
    end
  end

  def test_profile_three_transition_reports_partial_when_disable_and_restore_both_fail
    patcher = <<~'RUBY'
      home = ENV.fetch("HOME")
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(File.join(home, "auto-update"), "disabled")
        File.write(File.join(home, "auto-update-owned"), "prepared")
        exit 1
      end
      exit 1 if ARGV.include?("--restore-owned-subscription-auto-update")
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, stderr, status = run_script(
            installer, "--profile", "3", "--json", home: home
          )

          assert_equal 9, status.exitstatus
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "partial", result.fetch("status")
          assert_equal "auto_update_restore_failed", result.fetch("code")
          assert_equal "disabled", File.read(File.join(home, "auto-update"))
          assert File.exist?(File.join(home, "auto-update-owned"))
          saved, error, read_status = Open3.capture3(
            "/usr/bin/plutil", "-extract", "Profile", "raw", usage_state_path(home)
          )
          assert read_status.success?, error
          assert_equal "3", saved.strip
        end
      end
    end
  end

  def test_existing_profile_defers_a_signal_and_keeps_auto_update_disabled
    patcher = <<~'RUBY'
      home = ENV.fetch("HOME")
      File.open(File.join(home, "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(File.join(home, "auto-update"), "disabled")
        File.write(File.join(home, "auto-update-owned"), "prepared")
        puts "disabled"
        STDOUT.flush
        Process.kill("TERM", Process.ppid)
        sleep 0.05
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.write(File.join(home, "auto-update"), "enabled")
        File.delete(File.join(home, "auto-update-owned"))
        puts "restored"
        exit 0
      end
      exit 0
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

          _stdout, _stderr, status = run_script(installer, "--profile", "3", home: home)

          assert_equal 143, status.exitstatus
          assert_equal "disabled", File.read(File.join(home, "auto-update"))
          assert File.exist?(File.join(home, "auto-update-owned"))
          saved, error, read_status = Open3.capture3(
            "/usr/bin/plutil", "-extract", "Profile", "raw", state
          )
          assert read_status.success?, error
          assert_equal "1", saved.strip
          refute_includes File.read(File.join(home, "patcher-calls.log")),
                          "--restore-owned-subscription-auto-update"
        end
      end
    end
  end

  def test_saved_profile_three_keeps_recovery_state_when_disable_retry_fails
    patcher = <<~'RUBY'
      home = ENV.fetch("HOME")
      File.open(File.join(home, "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(File.join(home, "auto-update"), "disabled")
        File.write(File.join(home, "auto-update-owned"), "prepared")
        exit 1
      end
      if ARGV.include?("--restore-owned-subscription-auto-update")
        File.write(File.join(home, "auto-update"), "enabled")
        File.delete(File.join(home, "auto-update-owned"))
        puts "restored"
        exit 0
      end
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = usage_state_path(home)
          FileUtils.mkdir_p(File.dirname(state))
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "3", state)
          File.chmod(0o600, state)

          _stdout, _stderr, status = run_script(installer, home: home)

          assert_equal 9, status.exitstatus
          assert_equal "disabled", File.read(File.join(home, "auto-update"))
          assert File.exist?(File.join(home, "auto-update-owned"))
          calls = File.read(File.join(home, "patcher-calls.log"))
          refute_includes calls, "--restore-owned-subscription-auto-update"
        end
      end
    end
  end

  def test_light_profiles_keep_auto_update_disabled_before_install_or_safe_update
    patcher = <<~'RUBY'
      home = ENV.fetch("HOME")
      calls = File.join(home, "patcher-calls.log")
      File.open(calls, "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(File.join(home, "auto-update"), "disabled")
        puts "already_disabled_owned"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      File.write(File.join(home, "profile-work-ran"), "yes")
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      [1, 2].product([[]]).each do |profile, arguments|
        Dir.mktmpdir do |home|
          with_supported_app(home) do
            state = usage_state_path(home)
            ownership = File.join(
              home, "Library", "Application Support", "ClaudeEasy", "backups",
              "clashx-meta-kAutoUpdateEnable.state.json"
            )
            FileUtils.mkdir_p(File.dirname(state))
            FileUtils.mkdir_p(File.dirname(ownership))
            system("/usr/bin/plutil", "-create", "xml1", state)
            system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
            system("/usr/bin/plutil", "-insert", "Profile", "-integer", profile.to_s, state)
            File.chmod(0o600, state)
            File.write(ownership, "owned")
            File.write(File.join(home, "auto-update"), "disabled")

            _stdout, _stderr, status = run_script(installer, *arguments, home: home)

            assert status.success?
            assert_equal "disabled", File.read(File.join(home, "auto-update"))
            assert File.exist?(ownership)
            assert File.exist?(File.join(home, "profile-work-ran"))
            calls = File.readlines(File.join(home, "patcher-calls.log")).map(&:strip)
            disable_index = calls.index { |call| call.include?("--disable-subscription-auto-update") }
            work_index = calls.index { |call| call.include?("--policy") }
            refute_nil disable_index
            refute_nil work_index
            assert_operator disable_index, :<, work_index
            refute calls.any? { |call| call.include?("--restore-owned-subscription-auto-update") }
          end
        end
      end
    end
  end

  def test_saved_light_profiles_stop_before_profile_work_when_disabling_auto_update_fails
    patcher = <<~'RUBY'
      home = ENV.fetch("HOME")
      File.open(File.join(home, "patcher-calls.log"), "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-core-status")
        puts "supported"
        exit 0
      end
      exit 0 if ARGV.include?("--snapshot-initial")
      if ARGV.include?("--disable-subscription-auto-update")
        File.write(File.join(home, "auto-update"), "disabled")
        exit 1
      end
      File.write(File.join(home, "profile-work-ran"), "unexpected")
      exit 0
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      [1, 2].product([[]]).each do |profile, arguments|
        Dir.mktmpdir do |home|
          with_supported_app(home) do
            state = usage_state_path(home)
            FileUtils.mkdir_p(File.dirname(state))
            system("/usr/bin/plutil", "-create", "xml1", state)
            system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
            system("/usr/bin/plutil", "-insert", "Profile", "-integer", profile.to_s, state)
            File.chmod(0o600, state)

            stdout, stderr, status = run_script(
              installer, *arguments, "--json", home: home
            )

            assert_equal 9, status.exitstatus
            assert_empty stderr
            result = assert_json_result(stdout, status, command: "install")
            assert_equal "partial", result.fetch("status")
            assert_equal "auto_update_recovery_pending", result.fetch("code")
            refute File.exist?(File.join(home, "profile-work-ran"))
            assert_equal "disabled", File.read(File.join(home, "auto-update"))
          end
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
          state = usage_state_path(home)
          FileUtils.mkdir_p(File.dirname(state))
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
        end
      end
    end
  end

  def test_json_subscription_update_preserves_required_followups
    patcher = <<~'RUBY'
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
        puts JSON.generate(
          "schema" => "claude-easy.result", "version" => 1, "command" => "patch",
          "platform" => "macos", "client" => "clashx-meta", "operation" => "safe_update",
          "ok" => true, "status" => "ok", "code" => "safe_update_completed", "exit_code" => 0,
          "summary_zh" => "订阅事务完成，后续验收尚未完成。", "profile" => 3,
          "changes" => ["remote_subscriptions"], "checks" => [], "items" => [],
          "messages" => [], "warnings" => [], "workflow_complete" => false,
          "completed_scope" => "subscription_update",
          "required_followups" => %w[route_verification final_state_audit]
        )
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

          assert status.success?, stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal "safe_update_completed", result.fetch("code")
          assert_equal false, result.fetch("workflow_complete")
          assert_equal "subscription_update", result.fetch("completed_scope")
          assert_equal %w[route_verification final_state_audit], result.fetch("required_followups")
        end
      end
    end
  end

  def test_json_wrapper_rejects_subscription_update_without_workflow_metadata
    patcher = <<~'RUBY'
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
        puts JSON.generate(
          "schema" => "claude-easy.result", "version" => 1, "command" => "patch",
          "platform" => "macos", "client" => "clashx-meta", "operation" => "safe_update",
          "ok" => true, "status" => "ok", "code" => "subscription_update_completed", "exit_code" => 0,
          "summary_zh" => "全部订阅已经更新。", "profile" => 3,
          "changes" => ["remote_subscriptions"], "checks" => [], "items" => [],
          "messages" => [], "warnings" => []
        )
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

          refute status.success?
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          refute result.fetch("ok")
          refute_equal "subscription_update_completed", result.fetch("code")
        end
      end
    end
  end

  def test_json_wrapper_preserves_patch_profile_items
    child = {
      "schema" => "claude-easy.result", "version" => 1, "command" => "patch",
      "platform" => "macos", "client" => "clashx-meta", "operation" => "patch_profiles",
      "ok" => false, "status" => "partial", "code" => "patch_partial", "exit_code" => 1,
      "summary_zh" => "部分失败", "profile" => 1, "changes" => [], "checks" => [],
      "items" => [{ "status" => "rolled_back" }, { "status" => "failed" }],
      "messages" => [], "warnings" => []
    }
    patcher = <<~RUBY
      if ARGV.include?("--print-core-status")
        puts "supported"
      elsif ARGV.include?("--disable-subscription-auto-update")
        puts "already_disabled"
      elsif ARGV.include?("--snapshot-initial")
      else
        puts #{JSON.generate(child).dump}
        exit 1
      end
    RUBY
    with_supported_mihomo_installer(patcher_source: patcher) do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          stdout, stderr, status = run_script(installer, "--profile", "1", "--json", home: home)
          assert_equal 1, status.exitstatus
          assert_empty stderr
          result = assert_json_result(stdout, status, command: "install")
          assert_equal %w[rolled_back failed], result.fetch("items").map { |item| item.fetch("status") }
        end
      end
    end
  end

  def test_profile_three_downgrade_requires_safe_uninstall
    with_supported_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          state = usage_state_path(home)
          FileUtils.mkdir_p(File.dirname(state))
          system("/usr/bin/plutil", "-create", "xml1", state)
          system("/usr/bin/plutil", "-insert", "Version", "-integer", "1", state)
          system("/usr/bin/plutil", "-insert", "Profile", "-integer", "3", state)
          File.chmod(0o600, state)
          original = File.binread(state)

          stdout, _stderr, status = run_script(installer, "--profile", "1", home: home)

          assert_equal 1, status.exitstatus
          assert_includes stdout, "先运行安全卸载"
          assert_equal original, File.binread(state)
        end
      end
    end
  end

  def test_subscription_update_requires_mihomo
    with_missing_mihomo_installer do |installer|
      Dir.mktmpdir do |home|
        with_supported_app(home) do
          write_usage_profile(home, 3)
          stdout, stderr, status = run_script(installer, "--safe-update", home: home)
          assert_equal 8, status.exitstatus
          assert_empty stderr
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

  def test_uninstaller_treats_an_existing_released_ownership_log_as_not_owned
    patcher = <<~'RUBY'
      require "json"
      backup_dir = ARGV[ARGV.index("--backup-dir") + 1] if ARGV.include?("--backup-dir")
      ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json")
      calls = File.join(ENV.fetch("HOME"), "auto-update-calls")
      File.open(calls, "a") { |file| file.puts(ARGV.join(" ")) }
      if ARGV.include?("--print-auto-update-ownership-state")
        state = JSON.parse(File.read(ownership))
        puts(state.fetch("Phase") == "released" ? "not_owned" : "owned")
        exit 0
      end
      if ARGV.include?("--restore-owned-subscription-auto-update") ||
         ARGV.include?("--disable-subscription-auto-update")
        exit 91
      end
      exit 1
    RUBY
    with_uninstaller_package(patcher_source: patcher) do |uninstaller|
      Dir.mktmpdir do |home|
        backup_dir = File.join(home, "Library", "Application Support", "ClaudeEasy", "backups")
        FileUtils.mkdir_p(backup_dir)
        ownership = File.join(backup_dir, "clashx-meta-kAutoUpdateEnable.state.json")
        File.write(ownership, JSON.generate("Version" => 3, "Phase" => "released") + "\n")
        usage_state = usage_state_path(home)
        FileUtils.mkdir_p(File.dirname(usage_state))
        File.write(usage_state, "owned")

        stdout, stderr, status = run_script(uninstaller, "--json", home: home)

        assert status.success?, "#{stdout}\n#{stderr}"
        calls = File.read(File.join(home, "auto-update-calls"))
        assert_includes calls, "--print-auto-update-ownership-state"
        refute_includes calls, "--restore-owned-subscription-auto-update"
        refute_includes calls, "--disable-subscription-auto-update"
        refute File.exist?(usage_state)
        assert File.file?(ownership)
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
