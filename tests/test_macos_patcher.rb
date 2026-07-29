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
    skip "patcher not implemented" unless PATCHER_AVAILABLE || name == "test_patcher_files_exist"
    @policy = JSON.parse(File.read(POLICY_PATH)) if PATCHER_AVAILABLE
  end

  def require_production_probe!
    skip "set CLAUDE_EASY_RUN_PRODUCTION_PROBES=1 to run known production-failure probes" unless
      ENV["CLAUDE_EASY_RUN_PRODUCTION_PROBES"] == "1"
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

  def test_production_probe_normal_batch_restores_a_commit_when_bookkeeping_raises
    require_production_probe!
    Dir.mktmpdir do |directory|
      paths = %w[a-first.yaml z-second.yaml].map do |name|
        path = File.join(directory, name)
        File.write(path, YAML.dump(base_config.merge("subscription-marker" => name)))
        path
      end
      originals = paths.to_h { |path| [path, File.binread(path)] }
      real_replace = ClaudeEasy.method(:transactional_replace_locked)
      commits = 0
      injected = false
      faulty_replace = lambda do |*arguments|
        result = real_replace.call(*arguments)
        commits += 1 if result
        if result && commits == 2 && !injected
          injected = true
          raise IOError, "injected after the second durable commit"
        end
        result
      end

      results = ClaudeEasy.stub(:transactional_replace_locked, faulty_replace) do
        ClaudeEasy.run(
          directory: directory, policy_path: POLICY_PATH,
          backup_root: File.join(directory, "backups"), selected_name: "none",
          validator: ->(_path) { true }, auto_reload: false, usage_profile: 1
        )
      end

      assert injected
      refute results.all? { |result| %i[updated unchanged].include?(result.fetch(:status)) }
      originals.each do |path, bytes|
        assert File.binread(path) == bytes, "failed batch left committed bytes in #{File.basename(path)}"
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

  def test_production_probe_safe_update_restores_a_swap_when_bookkeeping_raises
    require_production_probe!
    Dir.mktmpdir do |directory|
      path = File.join(directory, "friend.yaml")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.write(path, original)
      canonical = File.realpath(path)
      real_stat = File.method(:stat)
      injected = false
      faulty_stat = lambda do |candidate|
        if !injected && candidate.to_s == canonical && File.binread(path) != original.b
          injected = true
          raise IOError, "injected after the safe-update swap"
        end
        real_stat.call(candidate)
      end

      result = File.stub(:stat, faulty_stat) do
        ClaudeEasy.safe_update_all(
          targets: [{ name: "friend", path: path, url: "https://fixture.invalid/friend" }],
          policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 1,
          fetcher: ->(_target) { YAML.dump(base_config.merge("subscription-marker" => "new")) },
          validator: ->(_path) { true },
          activation: ->(_items) { flunk "failed transaction must not activate" },
          selected_name: "friend"
        )
      end

      assert injected
      refute_equal :updated, result.fetch(:status)
      assert File.binread(path) == original.b, "failed safe update left committed bytes"
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
        File.symlink(target, path)
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
      aliases.each { |path| assert File.symlink?(path), path }
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
            [name, { "type" => "Selector", "now" => selected }]
          end
          [200, JSON.generate("proxies" => proxies)]
        when ["PUT", "/configs?force=true"]
          path = JSON.parse(body).fetch("path")
          config = ClaudeEasy.load_yaml(File.read(path))
          marker = config.fetch("rule-providers", {}).key?(provider_name) ? "candidate" : "original"
          selections = ClaudeEasy.selectable_groups(config).to_h do |group|
            [group.fetch("name"), "Taiwan"]
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
        else
          if method == "GET" && endpoint.start_with?("/dns/query?")
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
        results = ClaudeEasy.stub(:controller_socket, "fixture.sock") do
          ClaudeEasy.stub(:controller_request, controller_requester) do
            ClaudeEasy.run(
              directory: directory, policy_path: POLICY_PATH, backup_root: backup_root,
              selected_name: "active", validator: ->(_path) { false },
              auto_reload: true, connectivity_checker: -> { true }, usage_profile: 3
            )
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

  def test_production_probe_next_safe_update_recovers_runtime_killed_after_reload
    require_production_probe!
    Dir.mktmpdir do |directory|
      profile = File.join(directory, "active.yaml")
      backup_root = File.join(directory, "backups")
      runtime_marker = File.join(directory, "runtime-marker")
      gate_seen = File.join(directory, "reload-gated")
      original = YAML.dump(base_config.merge("subscription-marker" => "old-active"))
      File.binwrite(profile, original)
      File.write(runtime_marker, "old-active")
      target = {
        name: "active", path: profile, url: "https://fixture.invalid/active"
      }
      ready_reader, ready_writer = IO.pipe
      gate_reader, gate_writer = IO.pipe
      child_id = nil
      requester = lambda do |_socket, method, endpoint, body = nil|
        case [method, endpoint]
        when ["GET", "/proxies"]
          [200, JSON.generate("proxies" => {
            "Main" => { "type" => "Selector", "now" => "Taiwan" }
          })]
        when ["PUT", "/configs?force=true"]
          path = JSON.parse(body).fetch("path")
          marker = ClaudeEasy.load_yaml(File.read(path)).fetch("subscription-marker")
          File.write(runtime_marker, marker)
          if marker == "new-active" && !File.exist?(gate_seen)
            File.write(gate_seen, "1")
            ready_writer.write(".")
            ready_writer.flush
            gate_reader.read(1)
          end
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

      begin
        child_id = fork do
          ready_reader.close
          gate_writer.close
          ClaudeEasy.stub(:controller_socket, "socket") do
            ClaudeEasy.stub(:controller_request, requester) do
              ClaudeEasy.stub(:default_connectivity_healthy?, true) do
                ClaudeEasy.safe_update_all(
                  targets: [target], policy: @policy, backup_root: backup_root,
                  usage_profile: 1, selected_name: "active",
                  fetcher: ->(_item) {
                    YAML.dump(base_config.merge("subscription-marker" => "new-active"))
                  },
                  validator: ->(_path) { true }
                )
              end
            end
          end
          exit! 0
        end
        ready_writer.close
        gate_reader.close
        assert IO.select([ready_reader], nil, nil, 10), "child never loaded the candidate profile"
        ready_reader.read(1)
        Process.kill("KILL", child_id)
        _waited_id, status = Process.wait2(child_id)
        child_id = nil
        assert_equal 9, status.termsig
        assert_equal "new-active", File.read(runtime_marker)

        result = ClaudeEasy.stub(:controller_socket, "socket") do
          ClaudeEasy.stub(:controller_request, requester) do
            ClaudeEasy.stub(:default_connectivity_healthy?, true) do
              ClaudeEasy.safe_update_all(
                targets: [target], policy: @policy, backup_root: backup_root,
                usage_profile: 1, selected_name: "active",
                fetcher: ->(_item) { raise IOError, "injected preflight failure" },
                validator: ->(_path) { true }
              )
            end
          end
        end

        assert_equal :aborted, result.fetch(:status)
        assert_equal :download_or_validation_failed, result.fetch(:reason)
        assert_equal original.b, File.binread(profile)
        assert_equal "old-active", File.read(runtime_marker)
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

  def test_patcher_files_exist
    assert File.file?(PATCHER_PATH), "macOS patcher is missing"
    assert File.file?(RESULT_CONTRACT_PATH), "macOS result contract is missing"
    assert File.file?(POLICY_PATH), "canonical policy is missing"
  end

  def test_common_china_domain_baseline_applies_to_lightweight_profiles
    original = base_config
    original["ipv6"] = true
    original["tun"] = { "enable" => false }

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
      cn_index = patched.fetch("rules").index("RULE-SET,#{provider_name},DIRECT")
      broad_index = patched.fetch("rules").index("GEOSITE,CN,DIRECT")
      assert_operator cn_index, :<, broad_index
      assert_equal true, patched.fetch("ipv6")
      assert_equal({ "enable" => false }, patched.fetch("tun"))
      refute patched.fetch("rules").any? { |rule| rule.start_with?("NETWORK,UDP,") }
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
      output = StringIO.new
      loaded = bootstrap.load_dependencies(
        loader: ->(_path) { raise LoadError, "fixture" }, argv: ["--json"], output: output
      )
      refute loaded
      result = JSON.parse(output.string)
      assert_equal command, result.fetch("command")
      assert_equal "incomplete_package", result.fetch("code")
      assert_equal 6, result.fetch("exit_code")
      assert_raises(LoadError) do
        bootstrap.load_dependencies(
          loader: ->(_path) { raise LoadError, "fixture" }, argv: [], output: StringIO.new
        )
      end
    end
  end

  def test_route_verifier_json_mode_emits_one_contract_object_on_business_failure
    output = StringIO.new
    ClashRouteVerifier.stub(:run, false) do
      assert_equal 1, ClashRouteVerifier.cli(["--json"], output: output)
    end

    result = JSON.parse(output.string)
    assert_equal "verify_routes", result.fetch("command")
    assert_equal "failed", result.fetch("status")
    assert_equal 1, result.fetch("exit_code")
    refute_includes output.string, Dir.home
  end

  def test_route_verifier_cli_json_does_not_forward_human_output
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(output:, details:, **_options) { output.puts("PRIVATE-NODE"); details[:checks] << { "name" => "google", "ok" => true, "status" => "passed" }; true }) do
      assert_equal 0, ClashRouteVerifier.cli(["--json"], output: output)
    end

    result = JSON.parse(output.string)
    assert_equal "ok", result.fetch("status")
    assert_equal(
      [{ "name" => "google", "ok" => true, "status" => "passed" }],
      result.fetch("checks")
    )
    refute_includes output.string, "PRIVATE-NODE"
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
          output: output
        )
      )
    end

    assert_equal ["Main Live", "AI Live", 21], received
    assert_equal "routes_verified", JSON.parse(output.string).fetch("code")
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

  def test_route_verifier_cli_returns_text_help
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(**) { flunk "help reached route verification" }) do
      assert_equal 0, ClashRouteVerifier.cli(["--help"], output: output)
    end
    assert_includes output.string, "用法：verify_routes.rb"
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

  def test_route_verifier_cli_keeps_default_human_output
    output = StringIO.new
    ClashRouteVerifier.stub(:run, ->(output:, details:, **_options) { output.puts("中文结果"); false }) do
      assert_equal 1, ClashRouteVerifier.cli([], output: output)
    end
    assert_equal "中文结果\n", output.string
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

  def test_route_target_patterns_require_real_domain_boundaries
    patterns = ClashRouteVerifier::TARGETS.to_h { |label, _url, _kind, pattern| [label, pattern] }

    assert_match patterns.fetch("Google"), "www.google.com"
    refute_match patterns.fetch("Google"), "notgoogle.com"
    refute_match patterns.fetch("Google"), "google.com.attacker.invalid"
    assert_match patterns.fetch("OpenAI"), "api.openai.com"
    refute_match patterns.fetch("OpenAI"), "openai.com.attacker.invalid"
    assert_match patterns.fetch("Claude"), "claude.ai"
    refute_match patterns.fetch("Claude"), "notclaude.ai"
  end

  def test_unknown_policy_version_is_rejected_without_mutating_config
    config = base_config
    snapshot = Marshal.load(Marshal.dump(config))
    policy = Marshal.load(Marshal.dump(@policy))
    policy["version"] = 2

    result = ClaudeEasy.patch(config, policy)

    assert_equal :invalid_policy, result.fetch(:status)
    assert_equal snapshot, config
    assert_equal snapshot, result.fetch(:config)
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
    assert_equal 0, patched.fetch("rules").index(udp)
    assert_operator patched.fetch("rules").index(udp), :<, patched.fetch("rules").index("GEOSITE,CN,DIRECT")
    assert_includes patched.fetch("rules"), "DOMAIN,raw.githubusercontent.com,AI"
    assert_includes patched.fetch("rules"), "DOMAIN,storage.googleapis.com,AI"
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
    assert_equal ["NETWORK,UDP,AI", "NETWORK,UDP,REJECT"], patched.fetch("rules").first(2)
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
    assert_equal "NETWORK,UDP,🤖 AI · ClaudeEasy", patched.fetch("rules")[0]
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

    assert_equal :no_ai_nodes, result.fetch(:status)
    assert_equal config, result.fetch(:config)
  end

  def test_normalizes_owned_single_main_ai_group_to_independent_node_selector
    config = base_config
    config["proxy-groups"].reject! { |group| group["name"] == "AI" }
    ai_name = ClaudeEasy::AI_GROUP_BASE
    config["proxy-groups"] << { "name" => ai_name, "type" => "select", "proxies" => ["Main"] }
    config["rules"] = ClaudeEasy.render_ai_rules(@policy, ai_name) + config.fetch("rules")

    result = ClaudeEasy.patch(config, @policy)
    ai_group = result.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == ai_name }

    assert result.fetch(:ai_group_reset)
    assert_equal ["台湾家宽 01", "日本家宽 01", "美国家宽 01"], ai_group.fetch("proxies")
    refute_includes ai_group.fetch("proxies"), "Main"
  end

  def test_removes_obsolete_managed_groups
    config = base_config
    ai_name = ClaudeEasy::AI_GROUP_BASE
    safe_name = ClaudeEasy::SAFE_GROUP_BASE
    config["proxy-groups"] << { "name" => ai_name, "type" => "select", "proxies" => ["台湾家宽 01"] }
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
    assert_equal ["NETWORK,UDP,AI", "NETWORK,UDP,REJECT"], patched.fetch("rules").first(2)
  end

  def test_preserves_bootstrap_and_replaces_direct_resolvers_with_managed_mainland_doh
    config = base_config
    config["dns"]["default-nameserver"] = ["223.5.5.5", "119.29.29.29"]
    config["dns"]["proxy-server-nameserver"] = ["223.5.5.5", "120.53.53.53"]
    config["dns"]["direct-nameserver"] = ["system"]

    patched = ClaudeEasy.patch(config, @policy).fetch(:config).fetch("dns")

    assert_equal ["223.5.5.5", "119.29.29.29"], patched.fetch("default-nameserver")
    assert_equal ["223.5.5.5", "120.53.53.53"], patched.fetch("proxy-server-nameserver")
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
    assert_equal ["223.5.5.5", "120.53.53.53"], result.fetch(:config).dig("dns", "proxy-server-nameserver")
  end

  def test_uses_system_only_when_proxy_bootstrap_is_missing
    patched = ClaudeEasy.patch(base_config, @policy).fetch(:config).fetch("dns")

    refute patched.key?("default-nameserver")
    assert_equal ["system"], patched.fetch("proxy-server-nameserver")
    assert_equal @policy.fetch("direct_resolvers"), patched.fetch("direct-nameserver")
    assert_equal false, patched.fetch("direct-nameserver-follow-policy")
  end

  def test_migrates_the_old_unsafe_bootstrap_signature_to_system
    config = base_config
    config["dns"]["default-nameserver"] = ["1.1.1.1", "8.8.8.8"]
    config["dns"]["proxy-server-nameserver"] = ["https://1.1.1.1/dns-query", "https://8.8.8.8/dns-query"]

    patched = ClaudeEasy.patch(config, @policy).fetch(:config).fetch("dns")

    assert_equal ["system"], patched.fetch("default-nameserver")
    assert_equal ["system"], patched.fetch("proxy-server-nameserver")
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
    assert_equal 0, udp_index
    assert_equal "NETWORK,UDP,REJECT", rules[udp_index + 1]
    assert_operator udp_index, :<, rules.index("GEOSITE,CN,DIRECT")
    assert_operator udp_index, :<, rules.index("RULE-SET,private-special,DIRECT")
  end

  def test_preserves_user_ai_target_ahead_of_managed_rule
    config = base_config
    config["proxy-groups"] << { "name" => "MyGroup", "type" => "select", "proxies" => ["台湾家宽 01"] }
    user_rule = "DOMAIN-SUFFIX,openai.com,MyGroup"
    config["rules"].insert(0, user_rule)

    result = ClaudeEasy.patch(config, @policy)
    rules = result.fetch(:config).fetch("rules")
    managed_rule = "DOMAIN-SUFFIX,openai.com,#{result.fetch(:ai_group)}"

    assert_equal 1, rules.count(user_rule)
    assert_operator rules.index(user_rule), :<, rules.index(managed_rule)
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

    assert_equal 0, rules.index(guard)
    assert_equal "NETWORK,UDP,REJECT", rules[1]
    user_rules.each do |rule|
      assert_includes rules, rule
      assert_operator rules.index(guard), :<, rules.index(rule)
    end
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
        assert_match(/\A\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.\d{9}[+-]\d{4}--prewrite--[0-9a-f]{16}--friend\.yaml\.backup\z/, File.basename(path))
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

  def test_list_backups_returns_only_safe_dated_backup_ids_newest_first
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      older = ClaudeEasy.create_versioned_backup(profile, backup_root, reason: "initial")
      newer = ClaudeEasy.create_versioned_backup(profile, backup_root, reason: "prewrite")
      File.write(File.join(backup_root, "not-a-backup.txt"), "ignore")
      File.symlink(older, File.join(backup_root, "2099-01-01_00-00-00.000000000+0000--prewrite--fake--friend.yaml.backup"))

      listed = ClaudeEasy.list_backups(backup_root)

      assert_equal [File.basename(newer), File.basename(older)].sort.reverse, listed
      assert listed.all? { |name| name.match?(/\A\d{4}-\d{2}-\d{2}_/) }
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

      assert_equal :restore_conflict, result.fetch(:status)
      assert_equal changed.b, File.binread(first)
      assert_equal changed.b, File.binread(second)
    end
  end

  def test_subscription_auto_update_state_is_explicit
    assert_equal :disabled, ClaudeEasy.subscription_auto_update_state("0")
    assert_equal :disabled, ClaudeEasy.subscription_auto_update_state("false")
    assert_equal :enabled, ClaudeEasy.subscription_auto_update_state("1")
    assert_equal :enabled, ClaudeEasy.subscription_auto_update_state("true")
    assert_equal :unknown, ClaudeEasy.subscription_auto_update_state(nil)
  end

  def test_backup_helpers_tolerate_owned_file_permission_errors_and_cleanup_failed_creates
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

      source = File.join(directory, "friend.yaml")
      File.write(source, "original")
      chmod_with_new_failure = lambda do |mode, path|
        raise Errno::EPERM if path.end_with?(".backup")

        original_chmod.call(mode, path)
      end
      FileUtils.stub(:chmod, chmod_with_new_failure) do
        assert_raises(Errno::EPERM) do
          ClaudeEasy.create_versioned_backup(source, backup_root)
        end
      end
      assert_empty Dir.glob(File.join(backup_root, "*--prewrite--*.backup"))
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
      original_open = File.method(:open)
      attempts = 0
      colliding_open = lambda do |path, *arguments, &block|
        if path.to_s.end_with?(".backup")
          attempts += 1
          raise Errno::EEXIST if attempts == 1
        end
        original_open.call(path, *arguments, &block)
      end

      backup = File.stub(:open, colliding_open) do
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
      original_open = File.method(:open)
      collision = lambda do |path, *arguments, &block|
        if path.to_s.end_with?(".backup")
          attempts += 1
          raise Errno::EEXIST
        end
        original_open.call(path, *arguments, &block)
      end
      File.stub(:open, collision) do
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

      result = ClaudeEasy.disable_subscription_auto_update(backup_root: directory, runner: runner)

      assert_equal :disabled, result.fetch(:status)
      assert_equal "com.metacubex.ClashX.meta", result.fetch(:domain)
      assert_includes calls, [
        "/usr/bin/defaults", "write", "com.metacubex.ClashX.meta",
        "kAutoUpdateEnable", "-bool", "false"
      ]
      backups = Dir.glob(File.join(directory, "*--preference--*.json.backup"))
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
          ClaudeEasy.disable_subscription_auto_update(backup_root: directory, runner: runner)
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

      result = ClaudeEasy.disable_subscription_auto_update(backup_root: directory, runner: runner)

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

      result = ClaudeEasy.disable_subscription_auto_update(backup_root: directory, runner: runner)

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
          ClaudeEasy.disable_subscription_auto_update(backup_root: directory, runner: runner)
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
        ClaudeEasy.disable_subscription_auto_update(backup_root: directory, runner: runner)
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

      result = ClaudeEasy.disable_subscription_auto_update(backup_root: directory, runner: runner)

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
          ClaudeEasy.disable_subscription_auto_update(backup_root: directory, runner: runner)
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
        ClaudeEasy.disable_subscription_auto_update(backup_root: directory, runner: runner)
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

    result = ClaudeEasy.enable_subscription_auto_update(runner: runner)

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

  def test_remote_subscription_curl_input_rejects_injection_and_empty_downloads
    assert_raises(ClaudeEasy::InvalidConfigError) { ClaudeEasy.curl_config_value("safe\rnext") }
    assert_raises(ClaudeEasy::InvalidConfigError) { ClaudeEasy.curl_config_value("safe\nnext") }
    assert_equal "a\\\\b\\\"c", ClaudeEasy.curl_config_value("a\\b\"c")

    failure = Struct.new(:success?).new(false)
    success = Struct.new(:success?).new(true)
    [[failure, "body"], [success, ""]].each do |status, body|
      Open3.stub(:capture3, [body, "", status]) do
        assert_raises(ClaudeEasy::InvalidConfigError) do
          ClaudeEasy.fetch_remote_subscription(
            { name: "friend", url: "https://example.invalid/subscription" }
          )
        end
      end
    end
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

      [:timeout, false].each do |validation|
        assert_raises(ClaudeEasy::InvalidConfigError) do
          ClaudeEasy.build_update_candidate(
            target, YAML.dump(base_config), @policy, 3, ->(_path) { validation }
          )
        end
      end
    end
  end

  def test_remote_subscription_and_identity_helpers_fail_closed_on_bad_inputs
    assert_raises(ClaudeEasy::InvalidConfigError) do
      ClaudeEasy.remote_subscription_records("not-base64")
    end
    assert_raises(ClaudeEasy::InvalidConfigError) do
      ClaudeEasy.fetch_remote_subscription({})
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

  def test_remote_subscription_url_is_passed_to_curl_over_stdin_not_process_arguments
    url = "https://subscriptions.invalid/private-token"
    status = Struct.new(:success?).new(true)
    capture = lambda do |*arguments, **options|
      refute arguments.join(" ").include?(url)
      assert_includes options.fetch(:stdin_data), url
      [YAML.dump(base_config), "", status]
    end

    body = Open3.stub(:capture3, capture) do
      ClaudeEasy.fetch_remote_subscription({ name: "private", url: url })
    end

    assert_includes body, "proxy-groups"
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
      ClaudeEasy.prepare_profile_transaction(
        [{ path: config_path, original: original, candidate: candidate }],
        backup_root, roots: [directory]
      )
      File.binwrite(config_path, candidate)
      put_paths = []
      requester = lambda do |_socket, method, endpoint, body|
        raise "unexpected controller request" unless method == "PUT" && endpoint == "/configs?force=true"

        put_paths << JSON.parse(body).fetch("path")
        [204, ""]
      end

      result = ClaudeEasy.stub(:controller_socket, "socket") do
        ClaudeEasy.stub(:controller_request, requester) do
          ClaudeEasy.stub(:runtime_selections, {}) do
            ClaudeEasy.stub(:runtime_health_healthy?, true) do
              ClaudeEasy.safe_update_all(
                targets: [target], policy: @policy, backup_root: backup_root, usage_profile: 1,
                fetcher: ->(_item) { raise IOError, "stop after recovery" },
                validator: ->(_path) { true }, selected_name: "config.yaml"
              )
            end
          end
        end
      end

      assert_equal :aborted, result.fetch(:status)
      assert_equal :download_or_validation_failed, result.fetch(:reason)
      assert_equal [File.expand_path(config_path)], put_paths
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

  def test_recovered_safe_update_runtime_checks_the_remote_active_profile
    target = { name: "active", path: "/tmp/active.yaml" }
    put_paths = []
    expected_tun = nil
    requester = lambda do |_socket, method, endpoint, body|
      raise "unexpected controller request" unless method == "PUT" && endpoint == "/configs?force=true"

      put_paths << JSON.parse(body).fetch("path")
      [204, ""]
    end

    no_socket = ClaudeEasy.stub(:controller_socket, nil) do
      ClaudeEasy.reload_recovered_safe_update_runtime([target], 3, "active")
    end
    refute no_socket

    changed = ClaudeEasy.stub(:controller_socket, "socket") do
      ClaudeEasy.stub(:controller_request, requester) do
        ClaudeEasy.stub(:runtime_selections, {}) do
          ClaudeEasy.stub(:capture_runtime_profile_context, nil) do
            ClaudeEasy.reload_recovered_safe_update_runtime([target], 3, "active")
          end
        end
      end
    end
    refute changed
    assert_empty put_paths

    restored = ClaudeEasy.stub(:controller_socket, "socket") do
      ClaudeEasy.stub(:controller_request, requester) do
        ClaudeEasy.stub(:runtime_selections, {}) do
          context = {
            selected: "active", storage: nil,
            active_path: File.expand_path(target.fetch(:path))
          }
          ClaudeEasy.stub(:capture_runtime_profile_context, context) do
            ClaudeEasy.stub(:runtime_selections_for_profile, {}) do
              ClaudeEasy.stub(:runtime_health_healthy?, lambda { |_requester, **options|
                expected_tun = options.fetch(:expected_tun)
                true
              }) do
                ClaudeEasy.reload_recovered_safe_update_runtime([target], 3, "active")
              end
            end
          end
        end
      end
    end

    assert restored
    assert_equal [File.expand_path(target.fetch(:path))], put_paths
    assert_equal :enabled, expected_tun
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
      first = File.join(directory, "first.yaml")
      second = File.join(directory, "second.yaml")
      path = File.join(directory, "friend.yaml")
      backup_root = File.join(directory, "backups")
      original = YAML.dump(base_config.merge("subscription-marker" => "old"))
      File.binwrite(first, original)
      File.symlink(first, path)
      real_prepare = ClaudeEasy.method(:prepare_profile_transaction)
      prepare_then_repoint = lambda do |items, root, **options|
        transaction = real_prepare.call(items, root, **options)
        File.link(first, second)
        File.unlink(path)
        File.symlink(second, path)
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
      assert_equal :aborted, result.fetch(:status)
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_equal File.realpath(second), File.realpath(path)
      assert_equal original.b, File.binread(first)
      assert_equal original.b, File.binread(second)
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
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
      assert_equal :aborted, result.fetch(:status)
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_equal external_bytes, File.binread(profile)
      assert_equal external_identity, [current.dev, current.ino]
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
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
        []
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
        targets: targets, policy: @policy, backup_root: File.join(directory, "backups"), usage_profile: 3,
        fetcher: fetcher, validator: ->(_path) { true },
        activation: ->(_items) { flunk "must not activate" }, selected_name: "first"
      )

      assert_equal :aborted, result.fetch(:status)
      assert_equal "second", result.fetch(:failed_profile)
      targets.each { |target| assert_equal originals.fetch(target.fetch(:path)), File.binread(target.fetch(:path)) }
      refute Dir.exist?(File.join(directory, "backups"))
      refute_includes JSON.generate(result), "subscriptions.invalid"
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
      ClaudeEasy.stub(:activate_updated_profile, activation_result) do
        result = ClaudeEasy.default_safe_update_activation([item], 3, "friend")

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
      assert_equal :runtime_restore_pending, result.fetch(:status)
      assert_equal :activation_failed, result.fetch(:reason)
      assert_equal :reload_failed_restore_pending, result.fetch(:runtime_status)
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
      serialized = JSON.generate(result.fetch(:config))
      assert_equal fixture.fetch("expected_config_sha256"), Digest::SHA256.hexdigest(serialized), "#{fixture.fetch('name')}: output drift"
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
      assert_equal fixture.fetch("expected_config_sha256"), Digest::SHA256.hexdigest(JSON.generate(windows.fetch(index))), "#{fixture.fetch('name')}: Windows output drift"
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

  def test_chinese_status_covers_all_update_states
    base = { path: "/profiles/friend.yaml", status: :updated, ai_group: "AI" }

    assert_includes ClaudeEasy.chinese_status(base.merge(active: true, reloaded: true)), "已更新并自动生效"
    assert_includes ClaudeEasy.chinese_status(base.merge(active: false)), "已更新，选择该订阅时生效"
    assert_includes ClaudeEasy.chinese_status(base.merge(status: :reload_failed_rolled_back)), "自动刷新失败，已恢复原配置"
    assert_includes ClaudeEasy.chinese_status(base.merge(status: :unchanged)), "无需修改"
  end

  def test_run_automatically_reloads_and_checks_the_active_profile
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "friend.yaml"), YAML.dump(base_config))
      File.write(File.join(directory, "other.yaml"), YAML.dump(base_config))

      requests = []
      proxy_body = JSON.generate("proxies" => {
        "Main" => { "type" => "Selector", "now" => "台湾家宽 01" },
        "AI" => { "type" => "Selector", "now" => "台湾家宽 01" }
      })
      requester = lambda do |method, endpoint, body|
        requests << [method, endpoint, body]
        case [method, endpoint]
        when ["GET", "/proxies"] then [200, proxy_body]
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
      assert requests.any? { |method, endpoint, _body| method == "POST" && endpoint == "/cache/fakeip/flush" }
      assert requests.any? { |method, endpoint, _body| method == "POST" && endpoint == "/cache/dns/flush" }
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
      proxy_reads = 0
      requester = lambda do |method, endpoint, _body|
        case [method, endpoint]
        when ["GET", "/proxies"]
          proxy_reads += 1
          proxies = {
            "Main" => { "type" => "Selector", "now" => "台湾家宽 01" },
            "AI" => { "type" => "Selector", "now" => "Main" }
          }
          proxies[safe_group] = { "type" => "Selector", "now" => "台湾家宽 01" } if proxy_reads == 1
          [200, JSON.generate("proxies" => proxies)]
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
      assert_equal 2, guard_calls
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

      assert_equal :reload_failed_restore_pending, result.fetch(:status)
      assert_equal original.b, File.binread(profile)
      assert_equal 1, reloads
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
      "+.interface.example" => ["https://1.1.1.1/dns-query#en0"]
    }
    result = ClaudeEasy.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")

    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}#台湾家宽 01" }, policies.fetch("+.proxy.example")
    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}#SafeExisting" }, policies.fetch("+.group.example")
    %w[+.direct.example +.option.example +.interface.example].each do |pattern|
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
      "+.ecs.example" => ["https://1.1.1.1/dns-query##{target}&ecs=203.0.113.0/24&ecs-override=true"]
    }

    result = ClaudeEasy.patch(config, @policy)
    policies = result.fetch(:config).dig("dns", "nameserver-policy")
    safe_suffix = "##{result.fetch(:route_group)}"

    assert_equal @policy.fetch("resolvers").map { |resolver| "#{resolver}##{target}&h3=true" }, policies.fetch("+.h3.example")
    %w[+.skip-cert.example +.ecs.example].each do |pattern|
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
      "proxies" => ["Main", "日本家宽 01"],
      "icon" => "https://example.invalid/user-icon.png"
    }
    config["proxy-groups"] << user_group

    first = ClaudeEasy.patch(config, @policy)
    second = ClaudeEasy.patch(first.fetch(:config), @policy)
    preserved = first.fetch(:config).fetch("proxy-groups").find { |group| group["name"] == user_group["name"] }

    assert_equal user_group, preserved
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
    old["proxy-groups"] << { "name" => ai_group, "type" => "select", "proxies" => ["台湾家宽 01"] }
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
      assert_equal "Yue.to | 悦通", ClaudeEasy.defaults_read("selectConfigName")
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
        assert_nil ClaudeEasy.selected_profile_name(runner: runner)
      else
        assert_equal expected, ClaudeEasy.selected_profile_name(runner: runner)
      end
    end
    assert_nil ClaudeEasy.selected_profile_name(runner: ->(*_args, **_kwargs) { raise IOError })
    responses = [[plist, "", success]]
    assert_nil ClaudeEasy.selected_profile_name(
      runner: lambda { |*_args, **_kwargs|
        responses.shift || raise(IOError, "plutil unavailable")
      }
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

    assert_equal "friend", ClaudeEasy.selected_profile_name(runner: runner)
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

  def test_profile_discovery_refuses_two_icloud_roots_with_the_selected_profile
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

      assert_empty directories
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

  def test_every_profile_status_is_documented
    policy_document = File.read(File.join(ROOT, "claude-easy/references/patch-policy.md"))
    skill_document = File.read(File.join(ROOT, "claude-easy/SKILL.md"))
    examples = [
      { path: "/profiles/friend.yaml", status: :updated, active: true, reloaded: true, ai_group: "AI" },
      { path: "/profiles/friend.yaml", status: :updated, active: true, ai_group: "AI" },
      { path: "/profiles/friend.yaml", status: :updated, active: false, ai_group: "AI" },
      { path: "/profiles/friend.yaml", status: :reload_failed_rolled_back },
      { path: "/profiles/friend.yaml", status: :reload_failed_restore_pending },
      { path: "/profiles/friend.yaml", status: :reload_failed_rollback_conflict },
      { path: "/profiles/friend.yaml", status: :unchanged },
      { path: "/profiles/friend.yaml", status: :no_main_group },
      { path: "/profiles/friend.yaml", status: :no_ai_nodes },
      { path: "/profiles/friend.yaml", status: :invalid },
      { path: "/profiles/friend.yaml", status: :validation_failed },
      { path: "/profiles/friend.yaml", status: :validation_timeout },
      { path: "/profiles/friend.yaml", status: :non_idempotent },
      { path: "/profiles/friend.yaml", status: :invalid_policy },
      { path: "/profiles/friend.yaml", status: :concurrent_change },
      { path: "/profiles/friend.yaml", status: :io_error },
      { path: "/profiles/friend.yaml", status: :error }
    ]
    examples.each do |example|
      message = ClaudeEasy.chinese_status(example).split("：", 2).last
      status = message.split("；", 2).first
      assert_includes policy_document, status
    end
    assert_includes skill_document, "全部状态以"
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
    config["proxy-groups"] << { "name" => name, "type" => "select", "proxies" => ["台湾家宽 01"] }
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

    Open3.stub(:capture2e, ->(*items) { arguments = items; ["\n204", success] }) do
      assert_equal(
        [204, ""],
        ClaudeEasy.controller_request(
          "/tmp/controller.sock", "PUT", "/configs?force=true", '{"path":"profile.yaml"}'
        )
      )
    end
    assert_includes arguments, "Content-Type: application/json"
    assert_includes arguments, "--data"
    assert_includes arguments, '{"path":"profile.yaml"}'
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
          [failure == :fakeip_flush ? 503 : 204, ""]
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
            failed_dns = (failure == :baidu_dns && endpoint.include?("www.baidu.com")) ||
                         (failure == :google_dns && endpoint.include?("www.google.com"))
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
    %i[fakeip_flush dns_flush tun proxy_shape selection baidu_dns google_dns].each do |failure|
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
        ClaudeEasy.stub(:rollback_after_reload_failure, rollback) do
          failed = ClaudeEasy.activate_updated_profile(
            result, requester: ->(*_args) { [200, "{}"] }
          )
          assert_equal :reload_failed_restore_pending, failed.fetch(:status)
        end
      end

      ClaudeEasy.stub(:runtime_selections, ->(_requester) { raise IOError, "injected request failure" }) do
        ClaudeEasy.stub(:rollback_after_reload_failure, rollback) do
          failed = ClaudeEasy.activate_updated_profile(
            result, requester: ->(*_args) { [200, "{}"] }
          )
          assert_equal :reload_failed_restore_pending, failed.fetch(:status)
        end
      end
    end
    assert_equal 2, rollback_calls
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

  def test_profile_transaction_recovery_discards_a_missing_recorded_target
    Dir.mktmpdir do |directory|
      backup_root = File.join(directory, "backups")
      profile = File.join(directory, "friend.yaml")
      File.binwrite(profile, "original")
      ClaudeEasy.prepare_profile_transaction(
        [{ path: profile, original: "original", candidate: "candidate" }],
        backup_root, roots: [directory]
      )
      File.unlink(profile)

      assert ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])
      refute File.exist?(ClaudeEasy.profile_transaction_path(backup_root))
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

  def test_profile_transaction_rejects_a_symlink_target_outside_the_profile_root_before_publication
    Dir.mktmpdir do |directory|
      profile_root = File.join(directory, "profiles")
      outside_root = File.join(directory, "outside")
      backup_root = File.join(directory, "backups")
      FileUtils.mkdir_p([profile_root, outside_root])
      target = File.join(outside_root, "actual.yaml")
      profile = File.join(profile_root, "friend.yaml")
      File.binwrite(target, "original")
      File.symlink(target, profile)

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
        refute File.exist?(path)
        removal_syncs << path
        true
      }) do
        ClaudeEasy.remove_profile_transaction(snapshot)
      end
      assert_equal [journal_path], removal_syncs
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
          assert_equal [""], ClaudeEasy.finish_safe_update_rollback([item], {}, "/backups", ["/missing"])
        end
      end
    end
    assert recovered
    refute removed
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
      File.write(invalid_policy, JSON.generate("version" => -1))
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.run(directory: directory, policy_path: invalid_policy)
      end
    end
  end

  def test_runtime_helpers_cover_socket_discovery_and_exception_boundaries
    Dir.mktmpdir do |home|
      old_home = ENV["HOME"]
      ENV["HOME"] = home
      cache = File.join(home, "Library", "Caches", "com.MetaCubeX.ClashX.meta", "cacheConfigs")
      FileUtils.mkdir_p(cache)
      socket_path = File.join(home, "controller.sock")
      server = UNIXServer.new(socket_path)
      File.write(File.join(cache, "active.yaml"), YAML.dump("external-controller-unix" => socket_path))
      assert_equal socket_path, ClaudeEasy.controller_socket
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
      assert_equal :aborted, result.fetch(:status)
      assert_equal :concurrent_change, result.fetch(:reason)
      assert_equal external.b, File.binread(path)
      assert_equal external_identity, [current.dev, current.ino]
      assert_empty Dir.glob(File.join(directory, ".claude-easy-update-swap-*"))
    end
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

        assert_raises(ClaudeEasy::InvalidConfigError) do
          ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])
        end

        assert_equal partial, File.binread(profile)
        assert ClaudeEasy.profile_transaction_pending?(backup_root)
      end
    end
  end

  def test_profile_transaction_preserves_an_atomic_refresh_after_an_interrupted_write
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
      File.binwrite(external_path, "external-refresh")
      File.rename(external_path, profile)
      external_stat = File.stat(profile)

      ClaudeEasy.recover_profile_transaction(backup_root, roots: [directory])

      current = File.stat(profile)
      assert_equal "external-refresh", File.binread(profile)
      assert_equal [external_stat.dev, external_stat.ino], [current.dev, current.ino]
      refute ClaudeEasy.profile_transaction_pending?(backup_root)
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

      assert_raises(ClaudeEasy::InvalidConfigError) do
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
        assert_equal %w[iCloud.com.metacubex.ClashX iCloud.com.west2online.ClashX], ids
      end
    end

    roots = ["/tmp/cloud", "/tmp/local/.config/clash.meta"]
    ClaudeEasy.stub(:profile_paths, []) do
      ClaudeEasy.stub(:icloud_enabled?, false) do
        assert_equal roots.last, ClaudeEasy.active_profile_root(roots, "friend")
      end
    end
  end

  def test_result_contract_sanitizes_unknown_objects
    object = Object.new
    object.define_singleton_method(:to_s) { "token=fixture-secret" }

    assert_equal "[已隐藏]", ClaudeEasyResult.sanitize(object)
  end

  def test_cli_help_exposes_every_supported_operation_without_touching_profiles
    output, error = capture_io { assert_equal 0, ClaudeEasy.cli(["--help"]) }

    assert_includes output, "--safe-update-all"
    assert_includes output, "--recover-profile-transaction"
    assert_empty error
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
        assert_equal "recovered\n", output
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
  end

  def test_cli_json_covers_read_only_and_help_operations
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
      failing_runner = ->(*_arguments, **_options) { raise IOError, "injected parser failure" }
      assert_raises(ClaudeEasy::InvalidConfigError) do
        ClaudeEasy.saved_usage_profile(path: path, runner: failing_runner)
      end
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
      assert_equal original, File.binread(profile)
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
      remote_calls = 0
      ClaudeEasy.stub(:saved_usage_profile, 1) do
        ClaudeEasy.stub(:remote_subscription_targets, ->(_directories) { remote_calls += 1 }) do
          output, error = capture_io do
            assert_equal 10, ClaudeEasy.cli([
              "--json", "--profile-dir", directory, "--safe-update-all",
              "--usage-profile", "3"
            ])
          end
          assert_empty error
          assert_equal "usage_profile_mismatch", JSON.parse(output).fetch("code")
        end
      end
      assert_equal 0, remote_calls

      [
        ["--disable-subscription-auto-update", "disable_subscription_auto_update"],
        ["--restore-owned-subscription-auto-update", "restore_owned_subscription_auto_update"],
        ["--enable-subscription-auto-update", "enable_subscription_auto_update"]
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
        ["--restore-owned-subscription-auto-update", "安装、卸载或恢复流程"],
        ["--enable-subscription-auto-update", "所有权记录"]
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
      ClaudeEasy.stub(:list_backups, ["private.backup"]) do
        output, = capture_io do
          assert_equal 0, ClaudeEasy.cli(["--json", "--profile-dir", directory, "--list-backups"])
        end
        assert_equal "backups_listed", JSON.parse(output).fetch("code")
      end
      ClaudeEasy.stub(:snapshot_initial_profiles, ["/private/friend.yaml.backup"]) do
        output, = capture_io do
          assert_equal 0, ClaudeEasy.cli(["--json", "--profile-dir", directory, "--snapshot-initial"])
        end
        assert_equal ["initial_snapshot"], JSON.parse(output).fetch("changes")
      end
      comparison = { same: false, changes: ["dns.nameserver"] }
      ClaudeEasy.stub(:compare_backup, comparison) do
        output, = capture_io do
          assert_equal 0, ClaudeEasy.cli(["--json", "--profile-dir", directory, "--compare-backup", "id"])
        end
        assert_equal ["dns.nameserver"], JSON.parse(output).fetch("changes")
      end
      ClaudeEasy.stub(:restore_backup, { status: :updated }) do
        ClaudeEasy.stub(:selected_profile_name, "friend") do
          output, = capture_io do
            assert_equal 0, ClaudeEasy.cli(["--json", "--profile-dir", directory, "--restore-backup", "id"])
          end
          assert_equal "updated", JSON.parse(output).fetch("code")
        end
      end
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
  end

  def test_cli_human_mode_covers_maintenance_success_and_failure_outputs
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

      ClaudeEasy.stub(:snapshot_initial_profiles, ["/private/friend.yaml.backup"]) do
        output, error = capture_io do
          assert_equal 0, ClaudeEasy.cli(["--profile-dir", directory, "--snapshot-initial"])
        end
        assert_includes output, "friend.yaml.backup"
        assert_empty error
      end
    end
  end

  def test_cli_safe_update_covers_every_human_and_json_result_class
    Dir.mktmpdir do |directory|
      cases = [
        [{ status: :updated, count: 2, profiles: %w[first second] }, 0, "已安全更新"],
        [{ status: :rollback_failed }, 1, "未能恢复"],
        [{ status: :runtime_restore_pending }, 1, "运行内核恢复失败"],
        [{ status: :aborted }, 1, "保持原样"]
      ]
      ClaudeEasy.stub(:saved_usage_profile, 3) do
        cases.each do |result, expected_exit, expected_text|
          ClaudeEasy.stub(:remote_subscription_targets, []) do
            ClaudeEasy.stub(:selected_profile_name, "friend") do
              ClaudeEasy.stub(:safe_update_all, result) do
                output, error = capture_io do
                  assert_equal expected_exit, ClaudeEasy.cli([
                    "--profile-dir", directory, "--safe-update-all", "--usage-profile", "3"
                  ])
                end
                assert_includes output + error, expected_text
              end
            end
          end
        end

        json_cases = [
          [{ status: :updated, count: 1, profiles: ["friend"] }, "safe_update_completed"],
          [{ status: :rollback_failed }, "rollback_failed"],
          [{ status: :aborted }, "safe_update_failed"]
        ]
        json_cases.each do |result, expected_code|
          ClaudeEasy.stub(:remote_subscription_targets, []) do
            ClaudeEasy.stub(:selected_profile_name, "friend") do
              ClaudeEasy.stub(:safe_update_all, result) do
                output, error = capture_io do
                  ClaudeEasy.cli([
                    "--json", "--profile-dir", directory, "--safe-update-all", "--usage-profile", "3"
                  ])
                end
                assert_empty error
                assert_equal expected_code, JSON.parse(output).fetch("code")
              end
            end
          end
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
        :invalid_backup
      ].each do |status|
        ClaudeEasy.stub(:restore_backup, { status: status }) do
          ClaudeEasy.stub(:selected_profile_name, "friend") do
            output, error = capture_io do
              assert_equal 1, ClaudeEasy.cli(["--profile-dir", directory, "--restore-backup", "backup-id"])
            end
            assert_includes output, status.to_s
            assert_empty error
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
      activation = lambda do |result, require_tun:, **_keywords|
        activated = true
        assert_equal :preserve, require_tun
        result.merge(reloaded: true)
      end

      restore = lambda do |*_arguments, **keywords|
        keywords.fetch(:activation).call(restore_result)
      end
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
              assert_equal "ok", JSON.parse(output).fetch("status")
            end
          end
        end
      end

      assert activated
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
        output, error = ClaudeEasy.stub(:capture_runtime_profile_context, nil) do
          capture_io { assert_equal 1, ClaudeEasy.cli(arguments) }
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

  def test_cli_restore_backup_rolls_back_if_the_user_enters_the_target_during_validation
    Dir.mktmpdir do |directory|
      friend = File.join(directory, "friend.yaml")
      other = File.join(directory, "other.yaml")
      backup_root = File.join(directory, "backups")
      current = YAML.dump(base_config.merge("subscription-marker" => "current"))
      restored = YAML.dump(base_config.merge("subscription-marker" => "restored"))
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
          output, error = capture_io do
            assert_equal 1, ClaudeEasy.cli([
              "--json", "--profile-dir", directory,
              "--backup-dir", backup_root,
              "--restore-backup", File.basename(backup),
              "--expected-current-sha256", Digest::SHA256.hexdigest(current.b)
            ])
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
      restored = YAML.dump(base_config.merge("subscription-marker" => "restored"))
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
            output, error = capture_io do
              assert_equal 1, ClaudeEasy.cli([
                "--json", "--profile-dir", directory,
                "--backup-dir", backup_root,
                "--restore-backup", File.basename(backup),
                "--expected-current-sha256", Digest::SHA256.hexdigest(current.b)
              ])
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
              assert_includes result.fetch("summary_zh"), "运行内核"
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

      assert activated
    end
  end

  def test_cli_safe_update_reports_unresolved_runtime_recovery
    Dir.mktmpdir do |directory|
      ClaudeEasy.stub(:remote_subscription_targets, []) do
        ClaudeEasy.stub(:selected_profile_name, "friend") do
          ClaudeEasy.stub(:saved_usage_profile, 3) do
            ClaudeEasy.stub(
              :safe_update_all,
              { status: :runtime_restore_pending, runtime_status: :reload_failed_restore_pending }
            ) do
              output, error = capture_io do
                assert_equal 1, ClaudeEasy.cli([
                  "--json", "--profile-dir", directory, "--safe-update-all", "--usage-profile", "3"
                ])
              end
              assert_empty error
              result = JSON.parse(output)
              assert_equal "partial", result.fetch("status")
              assert_equal "safe_update_runtime_pending", result.fetch("code")
              assert_includes result.fetch("summary_zh"), "运行内核"
            end
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

      File.binwrite(path, pending)
      File.chmod(0o600, path)
      safe_arguments = arguments.dup.concat(["--safe-update-all", "--policy", POLICY_PATH])
      safe_result = { status: :updated, count: 1, profiles: ["a.yaml"] }
      ClaudeEasy.stub(:saved_usage_profile, 3) do
        ClaudeEasy.stub(:remote_subscription_targets, []) do
          ClaudeEasy.stub(:safe_update_all, safe_result) do
            original = $stdout
            $stdout = failing_output
            begin
              assert_raises(Errno::ENOSPC) { ClaudeEasy.cli(safe_arguments) }
            ensure
              $stdout = original
            end
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

  def test_patcher_is_split_into_explicit_modules_and_coverage_tracks_them
    expected = {
      "transform.rb" => :patch,
      "backups.rb" => :create_versioned_backup,
      "mihomo.rb" => :validate_with_mihomo,
      "profile_writer.rb" => :patch_path,
      "subscriptions.rb" => :safe_update_all,
      "runtime.rb" => :activate_updated_profile,
      "cli.rb" => :cli
    }
    module_root = File.join(ROOT, "claude-easy/scripts/macos/patch_profiles")
    expected.each do |filename, method_name|
      path = File.join(module_root, filename)
      assert File.file?(path), filename
      source = File.read(path)
      assert_match(/^module ClaudeEasy$/, source, filename)
      assert_match(/^  module_function$/, source, filename)
      assert_equal path, ClaudeEasy.method(method_name).source_location.first, method_name
    end

    coverage_source = File.read(File.join(ROOT, "tests/coverage_ruby.rb"))
    assert_includes coverage_source, 'Dir.glob(File.join(MACOS_RUBY_ROOT, "**", "*.rb"))'
    assert_includes coverage_source, "MINIMUM_MODULE_LINE_COVERAGE"
  end

  def test_cli_rejects_unknown_options_and_safe_updates_without_a_usage_profile
    _output, error = capture_io { assert_equal 64, ClaudeEasy.cli(["--unknown-option"]) }
    assert_includes error, "参数错误"

    Dir.mktmpdir do |directory|
      _output, error = capture_io do
        assert_equal 64, ClaudeEasy.cli(["--profile-dir", directory, "--safe-update-all"])
      end
      assert_includes error, "必须指定用途档位"
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

  def test_cli_backup_commands_delegate_without_exposing_backup_contents
    Dir.mktmpdir do |directory|
      ClaudeEasy.stub(:list_backups, ["backup-id"]) do
        output, = capture_io { assert_equal 0, ClaudeEasy.cli(["--profile-dir", directory, "--list-backups"]) }
        assert_includes output, "backup-id"
      end
      ClaudeEasy.stub(:compare_backup, { status: :changed }) do
        output, = capture_io do
          assert_equal 0, ClaudeEasy.cli(["--profile-dir", directory, "--compare-backup", "backup-id"])
        end
        assert_includes output, "changed"
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
              observed = ClashRouteVerifier.observe_connection("socket", "https://www.google.com", /google/i)
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
            observed = ClashRouteVerifier.observe_connection("socket", "https://www.google.com", /google/i)
            assert_equal "curl", observed.fetch("id")
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
              assert_equal "new", ClashRouteVerifier.observe_connection("socket", "https://www.google.com", /google/i).fetch("id")
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
                  "socket", "https://www.google.com", /google/i
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
    ClaudeEasy.stub(:controller_socket, "socket") do
      ClashRouteVerifier.stub(:get_json, ->(*_args) { raise IOError, "controller disappeared" }) do
        refute ClashRouteVerifier.run(output: StringIO.new)
      end
    end
  end

  def test_route_verifier_fails_closed_at_every_discovery_boundary
    ClaudeEasy.stub(:controller_socket, nil) do
      ClashRouteVerifier.stub(:active_profile, "/tmp/friend.yaml") do
        refute ClashRouteVerifier.run(output: StringIO.new)
      end
    end
    ClaudeEasy.stub(:controller_socket, "socket") do
      ClashRouteVerifier.stub(:active_profile, nil) do
        refute ClashRouteVerifier.run(output: StringIO.new)
      end
    end

    Dir.mktmpdir do |directory|
      profile = File.join(directory, "friend.yaml")
      File.write(profile, YAML.dump(base_config))
      ClaudeEasy.stub(:controller_socket, "socket") do
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
      "Main Live" => { "type" => "Relay", "now" => "Taiwan" },
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
    observations = [
      { "chains" => ["Taiwan", "Main"] },
      { "chains" => ["Japan", "AI"] },
      { "chains" => ["Japan", "AI"] },
      { "chains" => ["Japan", "AI"] }
    ]

    ClaudeEasy.stub(:controller_socket, "socket") do
      ClashRouteVerifier.stub(:active_profile, -> { flunk "read the disk for a live group" }) do
        ClashRouteVerifier.stub(:get_json, ->(_socket, endpoint) { responses[endpoint] }) do
          ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
            assert ClashRouteVerifier.run(output: StringIO.new)
          end
        end
      end
    end
  end

  def test_route_verifier_rejects_every_non_proxy_terminal_as_a_group_selection
    terminals = %w[
      DIRECT DNS REJECT REJECT-DROP PASS PASS-RULE COMPATIBLE REMATCH
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

    ClaudeEasy.stub(:controller_socket, "socket") do
      ClashRouteVerifier.stub(:get_json, ->(_socket, endpoint) { responses[endpoint] }) do
        ClashRouteVerifier.stub(:observe_connection, nil) do
          refute ClashRouteVerifier.run(output: StringIO.new, details: details)
        end
      end
    end

    assert_equal(
      %w[not_observed not_observed not_observed not_observed],
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
      observations = [
        { "chains" => [main_node, main_group] },
        { "chains" => [ai_node, ai_group] },
        { "chains" => [ai_node, ai_group] },
        { "chains" => [ai_node, ai_group] }
      ]
      ClaudeEasy.stub(:controller_socket, "socket") do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashRouteVerifier.stub(:get_json, route_controller_getter(proxies, main_group: main_group)) do
            ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
              output = StringIO.new
              assert ClashRouteVerifier.run(output: output)
              assert_includes output.string, "主代理组：已识别；当前选择已隐藏"
              assert_includes output.string, "AI 分组：已识别；当前选择已隐藏"
              assert_includes output.string, "Google：通过"
              assert_includes output.string, "Claude：通过"
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
      observations = [
        { "chains" => ["Taiwan", "Main"] },
        { "chains" => ["Japan", "AI"] },
        { "chains" => ["Japan", "AI"] },
        { "chains" => ["Japan", "AI"] }
      ]
      ClaudeEasy.stub(:controller_socket, "socket") do
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
      observations = [
        { "chains" => ["Taiwan", "Main"] },
        { "chains" => ["Japan", "AI"] },
        { "chains" => ["Japan", "AI"] },
        { "chains" => ["Japan", "AI"] }
      ]
      ClaudeEasy.stub(:controller_socket, "socket") do
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

  def test_route_verifier_accepts_a_user_google_proxy_group
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
      observations = [
        { "chains" => ["Singapore", "Google"] },
        { "chains" => ["Japan", "AI"] },
        { "chains" => ["Japan", "AI"] },
        { "chains" => ["Japan", "AI"] }
      ]
      ClaudeEasy.stub(:controller_socket, "socket") do
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
    expected_types = %w[Direct Dns Reject RejectDrop Pass PassRule Compatible Rematch]
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
      healthy_observations = [
        { "chains" => ["Provider Main", "Main"], "providerChains" => ["remote", ""] },
        { "chains" => ["Provider AI", "AI"], "providerChains" => ["remote", ""] },
        { "chains" => ["Provider AI", "AI"], "providerChains" => ["remote", ""] },
        { "chains" => ["Provider AI", "AI"], "providerChains" => ["remote", ""] }
      ]
      endpoints = []
      get_json = lambda do |_socket, endpoint|
        endpoints << endpoint
        {
          "/proxies" => proxies,
          "/rules" => { "rules" => [{ "type" => "MATCH", "proxy" => "Main" }] },
          "/providers/proxies" => provider_payload
        }[endpoint]
      end

      ClaudeEasy.stub(:controller_socket, "socket") do
        ClashRouteVerifier.stub(:active_profile, profile) do
          ClashRouteVerifier.stub(:get_json, get_json) do
            observations = healthy_observations.map(&:dup)
            ClashRouteVerifier.stub(:observe_connection, ->(*_args, **_options) { observations.shift }) do
              assert ClashRouteVerifier.run(output: StringIO.new)
            end
          end
        end
      end
      assert_equal ["/proxies", "/rules", "/providers/proxies"], endpoints

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
        ClaudeEasy.stub(:controller_socket, "socket") do
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

  private

  def refute_self_reference(config)
    config.fetch("proxy-groups").each do |group|
      refute_includes Array(group["proxies"]), group["name"], "group #{group['name']} references itself"
    end
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
