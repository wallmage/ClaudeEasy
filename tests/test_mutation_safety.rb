require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

ROOT = File.expand_path("..", __dir__) unless defined?(ROOT)

class MutationSafetyTest < Minitest::Test
  def with_repo_copy
    Dir.mktmpdir("claude-easy-mutation-") do |directory|
      %w[.github claude-easy tests README.md].each do |entry|
        FileUtils.cp_r(File.join(ROOT, entry), File.join(directory, entry))
      end
      yield directory
    end
  end

  def replace_once(root, relative_path, before, after)
    path = File.join(root, relative_path)
    source = File.binread(path)
    binary_before = before.b
    binary_after = after.b
    assert_equal 1, source.scan(binary_before).length, "mutation anchor changed: #{relative_path}"
    File.binwrite(path, source.sub(binary_before, binary_after))
  end

  def assert_mutation_is_killed(root, *command)
    stdout = +""
    stderr = +""
    status = nil
    timed_out = false
    Open3.popen3(*command, chdir: root, pgroup: true) do |stdin, child_stdout, child_stderr, thread|
      stdin.close
      stdout_reader = Thread.new { child_stdout.read }
      stderr_reader = Thread.new { child_stderr.read }
      begin
        Timeout.timeout(30) { status = thread.value }
      rescue Timeout::Error
        timed_out = true
        begin
          Process.kill("KILL", -thread.pid)
        rescue Errno::ESRCH, Errno::EPERM
          Process.kill("KILL", thread.pid) rescue nil
        end
        thread.join
      ensure
        stdout = stdout_reader.value
        stderr = stderr_reader.value
      end
    end
    refute timed_out, "mutation test timed out instead of detecting the behavior: #{command.join(' ')}"
    refute_match(/(?:SyntaxError|syntax error|LoadError|cannot load such file)/i, stdout + stderr)
    refute status.success?, <<~MESSAGE
      mutation survived: #{command.join(" ")}
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MESSAGE
    assert_match(
      /(?:Failure:|failed|fail|not ok)/i,
      stdout + stderr,
      "mutation exited nonzero without an assertion failure: #{command.join(' ')}"
    )
  end

  def test_read_only_automatic_variable_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/verify_routes.ps1",
        '$connectionHost = [string]$connection.metadata.host',
        '$host = [string]$connection.metadata.host'
      )

      assert_mutation_is_killed(
        root,
        "node", "--test",
        "--test-name-pattern=PowerShell scripts never assign to read-only automatic variables",
        "tests/test_windows_patcher.js"
      )
    end
  end

  def test_windows_live_match_main_group_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/verify_routes.ps1",
        '$main = Get-LiveMainGroup $proxies',
        '$main = Find-Group $proxies @($policy.main_group_names) $MainGroup "主代理组"'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_route_verifier_uses_live_match_rule_for_main_group"
      )
    end
  end

  def test_safe_update_path_identity_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "def locked_profile_current?(handle, path)\n",
        "def locked_profile_current?(handle, path)\n    return true\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_all_preserves_an_atomic_refresh_during_backup"
      )
    end
  end

  def test_restore_backup_transaction_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/backups.rb",
        "      recovery = resume_profile_transaction(\n" \
          "        backup_root, roots: directories, work_items: work_items, reload_runtime: true,\n" \
          "        require_tun: :preserve, precommit_condition: precommit_condition\n" \
          "      )\n",
        "      recovery = :recovered\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_restore_backup_recovers_an_interrupted_batch_before_writing"
      )
    end
  end

  def test_safe_update_precommit_journal_cleanup_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "        remove_profile_transaction(transaction)\n" \
          "        return { status: :aborted, failed_profile: \"\", reason: :concurrent_change }\n",
        "        true\n" \
          "        return { status: :aborted, failed_profile: \"\", reason: :concurrent_change }\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_all_discards_an_uncommitted_journal_after_a_preflight_refresh"
      )
    end
  end

  def test_profile_restore_removal_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        "    if ! rollback_profile_selection; then\n",
        "    if false; then\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_failed_profile_change_preserves_the_previous_saved_profile"
      )
    end
  end

  def test_safe_update_rollback_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "        item.fetch(\"Path\"), current, original, expected_path: item.fetch(\"WritePath\")\n",
        "        item.fetch(\"Path\"), current, current, expected_path: item.fetch(\"WritePath\")\n"
      )

      assert_mutation_is_killed(
        root,
        { "CLAUDE_EASY_RUN_PRODUCTION_PROBES" => "1" },
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_production_probe_next_safe_update_recovers_batch_killed_after_first_swap"
      )
    end
  end

  def test_pending_patch_runtime_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "    return :runtime_restore_pending unless\n" \
          "      reload_runtime &&\n" \
          "      reload_recovered_profile_runtime(\n" \
          "        work_items, require_tun: require_tun, socket: socket, requester: requester,\n" \
          "        connectivity_checker: connectivity_checker,\n" \
          "        precommit_condition: precommit_condition\n" \
          "      )\n",
        "    return :runtime_restore_pending unless true\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_next_run_recovers_runtime_killed_after_active_reload"
      )
    end
  end

  def test_pending_patch_transaction_retention_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "      backup_root, roots: roots, keep_transaction: pending\n",
        "      backup_root, roots: roots, keep_transaction: false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_failed_pending_runtime_recovery_keeps_transaction_and_skips_new_patch"
      )
    end
  end

  def test_pending_patch_no_reload_bypass_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "          backup_root, roots: roots, work_items: work_items, reload_runtime: auto_reload,\n",
        "          backup_root, roots: roots, work_items: work_items, reload_runtime: true,\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_next_run_recovers_runtime_killed_after_active_reload"
      )
    end
  end

  def test_failed_patch_runtime_transaction_retention_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "              keep_transaction: results.any? do |result|\n" \
          "                result[:status] == :reload_failed_restore_pending\n" \
          "              end\n",
        "              keep_transaction: false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_failed_active_reload_restores_the_exact_original_profile"
      )
    end
  end

  def test_restore_backup_transaction_creation_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/backups.rb",
        "    create_versioned_backup(target, backup_root, content: current_bytes, reason: \"pre-restore\")\n" \
          "    transaction = prepare_profile_transaction(\n" \
          "      [{ path: target, original: current_bytes, candidate: backup_bytes }], backup_root\n" \
          "    )\n",
        "    create_versioned_backup(target, backup_root, content: current_bytes, reason: \"pre-restore\")\n" \
          "    transaction = {}\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_next_patch_recovers_backup_restore_killed_after_file_commit"
      )
    end
  end

  def test_restore_backup_activation_order_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/backups.rb",
        "    result = activation.call(result) if activation\n" \
          "    finish_backup_restore_transaction(transaction, result)\n",
        "    remove_profile_transaction(transaction)\n" \
          "    result = activation.call(result) if activation\n" \
          "    finish_backup_restore_transaction(transaction, result)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_restore_backup_commits_transaction_only_after_active_runtime_check"
      )
    end
  end

  def test_restore_backup_pending_runtime_retention_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/backups.rb",
        "    if %i[updated no_change reload_failed_rolled_back].include?(result.fetch(:status))\n",
        "    if true\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_restore_backup_keeps_transaction_when_active_runtime_rollback_is_pending"
      )
    end
  end

  def test_restore_backup_no_change_transaction_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/backups.rb",
        "    if current_bytes == backup_bytes\n" \
          "      transaction = prepare_profile_transaction(\n" \
          "        [{ path: target, original: current_bytes, candidate: backup_bytes }], backup_root\n" \
          "      )\n",
        "    if current_bytes == backup_bytes\n" \
          "      transaction = {}\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_restore_backup_no_change_runtime_failure_stays_retryable"
      )
    end
  end

  def test_safe_update_completed_file_restore_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "  def safe_update_item_restored?(item)\n",
        "  def safe_update_item_restored?(item)\n    return false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_does_not_treat_runtime_file_restore_as_a_second_rollback_failure"
      )
    end
  end

  def test_safe_update_pending_runtime_resume_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "      if profile_transaction_pending?(backup_root)\n" \
          "        selected = selected_name\n" \
          "        active_root = active_profile_root(roots, selected)\n" \
          "        work_items = profile_work_items(roots, selected, active_root)\n" \
          "        recovery = resume_profile_transaction(\n" \
          "          backup_root, roots: roots, work_items: work_items, reload_runtime: true,\n" \
          "          require_tun: usage_profile >= 2,\n" \
          "          precommit_condition: precommit_condition\n" \
          "        )\n" \
          "        if recovery == :runtime_restore_pending\n" \
          "          return {\n" \
          "            status: :runtime_restore_pending, failed_profile: \"\",\n" \
          "            reason: :transaction_runtime_restore_failed\n" \
          "          }\n" \
          "        end\n" \
          "      end\n",
        ""
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_recovered_safe_update_runtime_reloads_active_config_outside_remote_targets"
      )
    end
  end

  def test_safe_update_runtime_pending_retention_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "        items, transaction, backup_root, roots, keep_transaction: runtime_restore_pending\n",
        "        items, transaction, backup_root, roots, keep_transaction: false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_reports_when_files_are_restored_but_runtime_is_not"
      )
    end
  end

  def test_safe_update_final_restore_check_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "    all_restored = items.all? { |item| safe_update_item_restored?(item) }\n",
        "    all_restored = true\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_keeps_the_transaction_when_a_restored_file_is_refreshed_before_cleanup"
      )
    end
  end

  def test_safe_update_uncommitted_transaction_cleanup_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "    if items.none? { |item| item[:committed_identity] } && !candidate_remains\n",
        "    if false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_all_preserves_an_atomic_refresh_during_backup"
      )
    end
  end

  def test_safe_update_unrecorded_candidate_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "    candidate_remains = items.any? { |item| safe_update_item_candidate_or_unknown?(item) }\n",
        "    candidate_remains = false\n"
      )

      assert_mutation_is_killed(
        root,
        { "CLAUDE_EASY_RUN_PRODUCTION_PROBES" => "1" },
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_production_probe_safe_update_restores_a_swap_when_bookkeeping_raises"
      )
    end
  end

  def test_safe_update_unrecorded_candidate_identity_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "    [stat.dev, stat.ino] == item.fetch(:candidate_identity) &&\n",
        "    true &&\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_preserves_an_equal_candidate_external_refresh_before_swap"
      )
    end
  end

  def test_safe_update_unreadable_candidate_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "      File.binread(item.fetch(:write_path)) == item.fetch(:candidate)\n" \
          "  rescue StandardError\n" \
          "    true\n" \
          "  end\n\n" \
          "  def rollback_safe_update_items",
        "      File.binread(item.fetch(:write_path)) == item.fetch(:candidate)\n" \
          "  rescue StandardError\n" \
          "    false\n" \
          "  end\n\n" \
          "  def rollback_safe_update_items"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_rollback_reports_unreadable_candidate_recovery_failure"
      )
    end
  end

  def test_windows_safe_update_proxy_group_check_removal_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_windows.ps1",
        "            Assert-ClaudeEasyProxyGroupCollection $text ([string]$item.File)\n",
        ""
      )

      assert_mutation_is_killed(
        root,
        "node", "--test",
        "--test-name-pattern=PowerShell safe update checks installed script and proxy-group prerequisites before acceptance",
        "tests/test_windows_patcher.js"
      )
    end
  end

  def test_windows_safe_update_managed_script_check_removal_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_windows.ps1",
        "        Assert-ClaudeEasyManagedScriptCurrent $scriptText $savedProfile $enginePath $targetScript\n",
        ""
      )

      assert_mutation_is_killed(
        root,
        "node", "--test",
        "--test-name-pattern=PowerShell safe update checks installed script and proxy-group prerequisites before acceptance",
        "tests/test_windows_patcher.js"
      )
    end
  end

  def test_windows_safe_update_multiline_flow_boundary_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/safe_update.ps1",
        "$flowLines += @($lines[($groupsNode.Start + 1)..($lines.Count - 1)])\n",
        "$flowLines += @($lines[($groupsNode.Start + 1)..($groupsNode.End - 1)])\n"
      )

      assert_mutation_is_killed(
        root,
        "node", "--test",
        "--test-name-pattern=PowerShell safe update checks installed script and proxy-group prerequisites before acceptance",
        "tests/test_windows_patcher.js"
      )
    end
  end

  def test_windows_safe_update_rollback_manifest_transaction_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/safe_update.ps1",
        "            Invoke-VerifiedWriteDeleteTransaction $targets @($manifestTarget)\n",
        "            Invoke-VerifiedFileTransaction $targets\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_failed_safe_update_rollback_deletes_manifest_in_the_same_transaction"
      )
    end
  end

  def test_windows_safe_update_missing_target_restore_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/safe_update.ps1",
        "            if ([string]::IsNullOrWhiteSpace($observedHash)) {\n",
        "            if ($false) {\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_safe_update_restores_a_missing_manifest_target"
      )
    end
  end

  def test_windows_preparation_missing_target_handoff_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        '        if (-not $target.Exists) { continue }',
        '        if (-not $target.Exists) { throw "mutant rejected a main-journal cleanup" }'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_preparation_recovery_accepts_targets_removed_by_the_main_journal"
      )
    end
  end

  def test_windows_interrupted_current_config_recovery_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        "    \$recovered = Invoke-InterruptedTransactionRecovery \$plan \$preCommitCondition\n",
        "    \$recovered = Invoke-InterruptedTransactionRecovery \$plan \$null\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_interrupted_current_config_recovery_waits_for_the_client"
      )
    end
  end

  def test_windows_interrupted_current_config_preparation_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        "                Test-InterruptedRecoveryCommitCondition \$preCommitCondition\n",
        "                \$true\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_interrupted_current_config_recovery_waits_for_the_client"
      )
    end
  end

  def test_windows_uninstall_client_precommit_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_windows.ps1",
        "        $writeTargets $deletePlans $clientStoppedPreCommit\n",
        "        $writeTargets $deletePlans $null\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_uninstall_rechecks_client_after_transaction_targets_are_locked"
      )
    end
  end

  def test_windows_single_write_precommit_forwarding_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        "    $committed = Invoke-VerifiedPathTransaction $Targets @() $PreCommitCondition\n",
        "    $committed = Invoke-VerifiedPathTransaction $Targets @() $null\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_install_and_restore_recheck_client_at_locked_precommit"
      )
    end
  end

  def test_windows_install_client_precommit_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_windows.ps1",
        "$installCommitted = Invoke-VerifiedFileTransaction $targets $clientStoppedPreCommit\n",
        "$installCommitted = Invoke-VerifiedFileTransaction $targets $null\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_install_and_restore_recheck_client_at_locked_precommit"
      )
    end
  end

  def test_windows_restore_client_precommit_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_windows.ps1",
        ") $clientStoppedPreCommit\n" \
          "    if (-not $restoreCommitted)",
        ") $null\n" \
          "    if (-not $restoreCommitted)"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_install_and_restore_recheck_client_at_locked_precommit"
      )
    end
  end

  def test_windows_uninstall_pending_safe_update_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_windows.ps1",
        "    if ($safeUpdateStateSnapshot.Exists) {\n" \
          "        Complete-PendingSafeUpdateUninstall\n" \
          "    }\n",
        "    if ($false) {\n" \
          "        Complete-PendingSafeUpdateUninstall\n" \
          "    }\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_uninstall_preserves_a_pending_safe_update"
      )
    end
  end

  def test_ruby_automatic_route_group_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/transform.rb",
        "    groups = route_groups(config)\n",
        "    groups = selectable_groups(config)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_shared_main_group_fixtures"
      )
    end
  end

  def test_windows_automatic_route_group_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/clash_verge_global.js",
        "  const groups = claudeEasyRouteGroups(config);\n",
        "  const groups = claudeEasySelectableGroups(config);\n"
      )

      assert_mutation_is_killed(
        root,
        "node", "--test",
        "--test-name-pattern=shared main-group fixtures match the Ruby engine",
        "tests/test_windows_patcher.js"
      )
    end
  end

  def test_ruby_last_resort_route_group_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/transform.rb",
        "    groups.first&.fetch(\"name\")\n",
        "    nil\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_shared_main_group_fixtures"
      )
    end
  end

  def test_windows_last_resort_route_group_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/clash_verge_global.js",
        "  return groups.length ? groups[0].name : null;\n",
        "  return null;\n"
      )

      assert_mutation_is_killed(
        root,
        "node", "--test",
        "--test-name-pattern=shared main-group fixtures match the Ruby engine",
        "tests/test_windows_patcher.js"
      )
    end
  end

  def test_ruby_owned_safe_route_group_removal_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/transform.rb",
        "(owned_safe_names - [route_group])",
        "owned_safe_names"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_shared_full_transform_fixtures"
      )
    end
  end

  def test_windows_owned_safe_route_group_removal_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/clash_verge_global.js",
        ".concat(ownedNames.safe.filter(function (name) { return name !== routeGroup; }))",
        ".concat(ownedNames.safe)"
      )

      assert_mutation_is_killed(
        root,
        "node", "--test",
        "--test-name-pattern=shared full-transform fixtures match the Ruby engine",
        "tests/test_windows_patcher.js"
      )
    end
  end

  def test_partial_write_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "    begin\n      source.rewind\n      restored = source.write(original_bytes)",
        "    begin\n      raise write_error\n      source.rewind\n      restored = source.write(original_bytes)"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_locked_write_restores_original_bytes_after_a_partial_write_error"
      )
    end
  end

  def test_atomic_swap_verification_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "        if File.exist?(temporary.path) && File.exist?(write_path) &&\n" \
          "           same_file_identity?(source_stat, temporary.path) &&\n" \
          "           File.binread(write_path) == replacement_bytes\n" \
          "          atomic_swap_paths(temporary.path, write_path)\n" \
          "        end\n",
        "        if File.exist?(temporary.path) && File.exist?(write_path) &&\n" \
          "           same_file_identity?(source_stat, temporary.path) &&\n" \
          "           File.binread(write_path) == replacement_bytes\n" \
          "          false\n" \
          "        end\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_atomic_replace_restores_the_original_when_commit_verification_fails"
      )
    end
  end

  def test_safe_update_post_swap_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/mihomo.rb",
        "    unless completed\n",
        "    if completed\n"
      )

      assert_mutation_is_killed(
        root,
        { "CLAUDE_EASY_RUN_PRODUCTION_PROBES" => "1" },
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_production_probe_mihomo_does_not_survive_a_killed_validator"
      )
    end
  end

  def test_route_domain_boundary_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/verify_routes.rb",
        '/(?:\A|\.)google\.com\z/i',
        "/google/i"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_route_target_patterns_require_real_domain_boundaries"
      )
    end
  end

  def test_route_source_port_binding_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/verify_routes.rb",
        "          metadata[\"network\"].to_s.casecmp(\"tcp\").zero? &&\n" \
          "          metadata[\"sourcePort\"].to_i == source_port\n",
        "          metadata[\"network\"].to_s.casecmp(\"tcp\").zero?\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_route_verifier_ignores_same_host_traffic_from_another_source_port"
      )
    end
  end

  def test_windows_idempotence_fail_safe_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/clash_verge_global.js",
        "  if (JSON.stringify(candidate) !== JSON.stringify(secondPass)) return config;\n",
        "  if (JSON.stringify(candidate) !== JSON.stringify(secondPass)) return candidate;\n"
      )

      assert_mutation_is_killed(
        root,
        "node", "--test",
        "--test-name-pattern=global transform verifies a second pass before returning a candidate",
        "tests/test_windows_patcher.js"
      )
    end
  end

  def test_release_archive_dependency_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles.rb",
        "patch_profiles/profile_writer patch_profiles/subscriptions patch_profiles/runtime",
        "patch_profiles/profile_writer patch_profiles/missing_subscriptions patch_profiles/runtime"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_release_archive_is_self_contained_and_runs_from_a_unicode_space_path"
      )
    end
  end

  def test_release_public_install_dry_run_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        "  if ! run_committing_profile_operation \\\n" \
          "      --profile-dir \"$CUSTOM_PROFILE_DIR\" \\\n" \
          "      --policy \"$POLICY_SOURCE\" \\\n" \
          "      --backup-dir \"$BACKUP_DIR\" --usage-profile \"$USAGE_PROFILE\"; then",
        "  if ! run_committing_profile_operation \\\n" \
          "      --profile-dir \"$CUSTOM_PROFILE_DIR\" \\\n" \
          "      --policy \"$POLICY_SOURCE\" \\\n" \
          "      --backup-dir \"$BACKUP_DIR\" --usage-profile \"$USAGE_PROFILE\" --dry-run; then"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_release_archive_is_self_contained_and_runs_from_a_unicode_space_path"
      )
    end
  end

  def test_normal_batch_preflight_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "    unless preflight.all? { |result| %i[updated unchanged].include?(result[:status]) }\n",
        "    if false && !preflight.all? { |result| %i[updated unchanged].include?(result[:status]) }\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_normal_batch_aborts_before_writing_when_a_later_profile_fails"
      )
    end
  end

  def test_auto_update_compensation_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        'disabled) AUTO_UPDATE_CHANGED=1; say "已自动关闭订阅更新，并保存修改前状态。" ;;',
        'disabled) say "已自动关闭订阅更新，并保存修改前状态。" ;;'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_profile_three_restores_auto_update_when_a_later_step_fails"
      )
    end
  end

  def test_macos_profile_operation_signal_handoff_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        "preserve_profile_operation_state() {\n" \
          "  commit_profile_selection\n" \
          "  AUTO_UPDATE_CHANGED=0\n" \
          "}\n",
        "preserve_profile_operation_state() {\n" \
          "  :\n" \
          "}\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_signal_after_profile_commit_preserves_outer_profile_state"
      )
    end
  end

  def test_macos_operation_lock_signal_delegation_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        "  trap ':' HUP INT TERM\n" \
          "  set +e\n" \
          "  /usr/bin/ruby \"$OPERATION_LOCK_SOURCE\" \"$OPERATION_LOCK_PATH\" /bin/sh \"$0\" \"$@\"\n",
        "  set +e\n" \
          "  /usr/bin/ruby \"$OPERATION_LOCK_SOURCE\" \"$OPERATION_LOCK_PATH\" /bin/sh \"$0\" \"$@\"\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_signal_after_profile_commit_preserves_outer_profile_state"
      )
    end
  end

  def test_macos_wrapper_commit_receipt_detection_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        '    "1:$PROFILE_OPERATION_RECEIPT_NONCE") PROFILE_OPERATION_RECEIPT_COMMITTED=1 ;;',
        '    "1:$PROFILE_OPERATION_RECEIPT_NONCE") PROFILE_OPERATION_RECEIPT_COMMITTED=0 ;;'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_result_failure_after_profile_commit_preserves_outer_profile_state"
      )
    end
  end

  def test_macos_normal_commit_receipt_publication_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/cli.rb",
        "    mark_wrapper_commit_receipt(options) if operation_succeeded\n",
        ""
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_cli_marks_wrapper_receipt_before_success_result_output"
      )
    end
  end

  def test_macos_safe_update_commit_receipt_publication_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/cli.rb",
        "        mark_wrapper_commit_receipt(options)\n",
        ""
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_cli_marks_wrapper_receipt_before_success_result_output"
      )
    end
  end

  def test_macos_commit_receipt_failure_exit_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        '  elif [ "$PROFILE_OPERATION_CHILD_STATUS" -eq 75 ]; then',
        '  elif [ "$PROFILE_OPERATION_CHILD_STATUS" -eq 76 ]; then'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_uncertain_or_unpublished_commit_receipt_preserves_outer_profile_state"
      )
    end
  end

  def test_macos_unknown_commit_result_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        "    PROFILE_OPERATION_RESULT_UNKNOWN=1\n",
        "    PROFILE_OPERATION_RESULT_UNKNOWN=0\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_uncertain_or_unpublished_commit_receipt_preserves_outer_profile_state"
      )
    end
  end

  def test_macos_abnormal_commit_exit_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        "  elif [ \"\$PROFILE_OPERATION_RECEIPT_INVALID\" -eq 1 ] ||\n" \
        "       [ \"\$PROFILE_OPERATION_CHILD_STATUS\" -ge 128 ]; then",
        "  elif [ \"\$PROFILE_OPERATION_RECEIPT_INVALID\" -eq 1 ]; then"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_uncertain_or_unpublished_commit_receipt_preserves_outer_profile_state"
      )
    end
  end

  def test_macos_commit_receipt_error_mapping_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/cli.rb",
        '    raise WrapperCommitReceiptError, "wrapper commit receipt publication failed"',
        '    raise IOError, "wrapper commit receipt publication failed"'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_wrapper_commit_receipt_is_preallocated_validated_and_marked"
      )
    end
  end

  def test_auto_update_ownership_state_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "      ownership = write_auto_update_ownership_state(\n" \
          "        backup_root, domain, original, \"installed\", existing: auto_update_ownership_state(backup_root)\n" \
          "      )\n",
        "      ownership = { \"Path\" => auto_update_ownership_path(backup_root) }\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_disables_subscription_auto_update_through_defaults_and_verifies_it"
      )
    end
  end

  def test_result_contract_profile_boundary_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/result_contract.rb",
        'value.match?(/\A[1-3]\z/) ? value.to_i : nil',
        'value.match?(/\A[1-4]\z/) ? value.to_i : nil'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_result_contract_cli_emits_valid_json_and_rejects_bad_arguments"
      )
    end
  end

  def test_default_mihomo_resolution_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/mihomo.rb",
        "  def validate_with_mihomo(path, core_path: AUTO_CORE, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)\n" \
          "    core = core_path.equal?(AUTO_CORE) ? mihomo_core_path : core_path\n",
        "  def validate_with_mihomo(path, core_path: AUTO_CORE, timeout_seconds: VALIDATION_TIMEOUT_SECONDS)\n" \
          "    core = core_path\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_mihomo_default_core_is_resolved_before_status_and_validation"
      )
    end
  end

  def test_runtime_google_dns_health_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        '    return false unless dns_runtime_healthy?(requester, "www.google.com")',
        '    true'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_runtime_health_rejects_every_partial_health_failure"
      )
    end
  end

  def test_remote_subscription_https_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        '      raise InvalidConfigError, "远程订阅地址不是 HTTPS" unless url.start_with?("https://")',
        '      true'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_remote_subscription_manifest_rejects_unsafe_and_ambiguous_records"
      )
    end
  end

  def test_windows_deferred_probe_failure_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_windows_installer.ps1",
        '    if ($script:deferredProbeFailures.Count -gt 0) {' + "\n" +
          '        throw ("deferred production probes failed:',
        '    if ($script:deferredProbeFailures.Count -gt 0) {' + "\n" +
          '        Write-Host ("deferred production probes failed:'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_runtime_tests_use_powershell_ast_for_automatic_variable_writes"
      )
    end
  end

  def test_windows_failure_diagnostic_privacy_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_windows_installer.ps1",
        '    return "output_length=$($text.Length) output_sha256=$digest"',
        '    return $text'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_test_failure_diagnostics_do_not_echo_captured_output"
      )
    end
  end

  def test_windows_candidate_cleanup_publish_order_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/mihomo.ps1",
        "        Start-MihomoCandidateCleanupWatcher $temporary\n" +
          "        [System.IO.File]::Move($staging, $temporary)",
        "        [System.IO.File]::Move($staging, $temporary)\n" +
          "        Start-MihomoCandidateCleanupWatcher $temporary"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_candidate_cleanup_watcher_is_armed_before_publish"
      )
    end
  end

  def test_macos_production_probe_ci_gate_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/run_macos_production_probes.rb",
        'probe_environment = { "CLAUDE_EASY_RUN_PRODUCTION_PROBES" => "1" }.freeze',
        'probe_environment = { "CLAUDE_EASY_RUN_PRODUCTION_PROBES" => "0" }.freeze'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_macos_production_probe_runner_executes_all_cases_and_propagates_any_failure"
      )
    end
  end

  def test_macos_real_mihomo_test_rename_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_macos_patcher.rb",
        "  def test_generated_profile_passes_installed_mihomo_validation\n",
        "  def test_generated_profile_passes_real_mihomo_validation\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_macos_real_mihomo_runner_rejects_zero_or_skipped_cases"
      )
    end
  end

  def test_macos_real_mihomo_profile_loop_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_macos_patcher.rb",
        "      [1, 2, 3].each do |usage_profile|\n",
        "      [1].each do |usage_profile|\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_macos_real_mihomo_runner_rejects_zero_or_skipped_cases"
      )
    end
  end

  def test_windows_real_mihomo_profile_receipt_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_windows_installer.ps1",
        '                foreach ($realUsageProfile in @(1, 2, 3)) {',
        '                foreach ($realUsageProfile in @(1)) {'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_real_mihomo_jobs_require_case_completion_receipts"
      )
    end
  end

  def test_macos_production_probe_failure_aggregation_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/run_macos_production_probes.rb",
        "  failed ||= !success\n",
        "  failed ||= false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_macos_production_probe_runner_executes_all_cases_and_propagates_any_failure"
      )
    end
  end

  def test_github_actions_dynamic_shell_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        ".github/workflows/test.yml",
        "      - name: Download and verify official Windows Mihomo\n        shell: powershell",
        "      - name: Download and verify official Windows Mihomo\n        shell: ${{ matrix.shell }}"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_github_actions_shell_fields_are_static"
      )
    end
  end

  def test_windows_powershell_5_full_suite_entrypoint_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        ".github/workflows/test.yml",
        "          $runtime = (Get-Command powershell.exe).Source\n" +
          "          & $runtime -NoLogo -NoProfile -File ./tests/test_windows_installer.ps1",
        "          $runtime = (Get-Command powershell.exe).Source\n" +
          "          Write-Host $runtime -NoLogo -NoProfile -File ./tests/test_windows_installer.ps1"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_full_runtime_jobs_require_completion_receipts"
      )
    end
  end

  def test_windows_powershell_7_full_suite_entrypoint_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        ".github/workflows/test.yml",
        "          $runtime = (Get-Command pwsh.exe).Source\n" +
          "          & $runtime -NoLogo -NoProfile -File ./tests/test_windows_installer.ps1",
        "          $runtime = (Get-Command pwsh.exe).Source\n" +
          "          Write-Host $runtime -NoLogo -NoProfile -File ./tests/test_windows_installer.ps1"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_full_runtime_jobs_require_completion_receipts"
      )
    end
  end

  def test_macos_uninstall_auto_update_transaction_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_macos.sh",
        "\ndelete_staged_install_files\n\nAUTO_UPDATE_RESTORED=0",
        "\nAUTO_UPDATE_RESTORED=0"
      )
      replace_once(
        root,
        "claude-easy/scripts/uninstall_macos.sh",
        "\ncommit_staged_install_files\n/bin/rmdir",
        "\ndelete_staged_install_files\ncommit_staged_install_files\n/bin/rmdir"
      )

      assert_mutation_is_killed(
        root,
        "/usr/bin/env", "CLAUDE_EASY_RUN_PRODUCTION_PROBES=1",
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_production_probe_uninstall_preserves_a_file_replaced_after_staging"
      )
    end
  end

  def test_macos_runtime_profile_precommit_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "    unless runtime_precommit_allowed?(precommit_condition)\n" \
          "      status = restore_profile_bytes(result) ?",
        "    if false\n" \
          "      status = restore_profile_bytes(result) ?"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name",
        "test_run_does_not_reload_the_old_profile_after_the_user_switches_profiles"
      )
    end
  end

  def test_macos_batch_profile_context_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "        if batch_committed &&\n" \
          "           !runtime_committed &&\n" \
          "           results.any? { |result| result[:status] == :updated } &&\n" \
          "           !runtime_precommit_allowed?(precommit_condition)\n",
        "        if false &&\n" \
          "           !runtime_committed &&\n" \
          "           results.any? { |result| result[:status] == :updated } &&\n" \
          "           !runtime_precommit_allowed?(precommit_condition)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name",
        "test_run_aborts_if_the_user_enters_an_updated_profile_while_the_initial_profile_is_unchanged"
      )
    end
  end

  def test_macos_runtime_recovery_profile_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "    return false if expected_tun == :unknown\n" \
          "    return false unless runtime_precommit_allowed?(precommit_condition)\n",
        "    return false if expected_tun == :unknown\n" \
          "    # mutant: skip the live profile check\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name",
        "test_pending_runtime_recovery_does_not_reload_a_profile_the_user_left"
      )
    end
  end

  def test_macos_runtime_context_requires_one_active_profile_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "    return nil unless matching_paths.length == 1\n",
        "    return nil if matching_paths.length > 1\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name",
        "test_pending_runtime_recovery_keeps_the_journal_when_the_active_profile_is_missing"
      )
    end
  end

  def test_macos_no_reload_profile_context_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "    needs_runtime_context = selected_name.nil? && !dry_run\n",
        "    needs_runtime_context = selected_name.nil? && auto_reload && !dry_run\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name",
        "test_run_without_reload_stops_when_the_current_profile_cannot_be_read"
      )
    end
  end

  def test_macos_runtime_rollback_profile_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "    return :reload_failed_restore_pending unless runtime_precommit_allowed?(precommit_condition)\n",
        "    return :reload_failed_restore_pending if false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name",
        "test_reload_failure_does_not_force_the_old_profile_after_a_late_user_switch"
      )
    end
  end

  def test_macos_wrapper_operation_lock_mutations_are_killed
    %w[
      claude-easy/scripts/install_macos.sh
      claude-easy/scripts/uninstall_macos.sh
    ].each do |relative_path|
      with_repo_copy do |root|
        replace_once(
          root,
          relative_path,
          'if [ "$OPERATION_LOCK_REQUIRED" -eq 1 ] &&',
          'if [ "$OPERATION_LOCK_REQUIRED" -eq 0 ] &&'
        )

        assert_mutation_is_killed(
          root,
          "/usr/bin/env", "CLAUDE_EASY_RUN_PRODUCTION_PROBES=1",
          RbConfig.ruby, "tests/test_macos_wrappers.rb",
          "--name",
          "test_production_probe_shared_wrapper_lock_prevents_uninstall_from_deleting_a_concurrent_install"
        )
      end
    end
  end

  def test_macos_install_pending_uninstall_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        "recover_interrupted_uninstall\nresolve_usage_profile",
        ": # mutant: skip pending uninstall recovery\nresolve_usage_profile"
      )

      assert_mutation_is_killed(
        root,
        "/usr/bin/env", "CLAUDE_EASY_RUN_PRODUCTION_PROBES=1",
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name",
        "test_production_probe_install_recovers_a_killed_ready_uninstall_before_changing_profile"
      )
    end
  end

  def test_macos_uninstall_pending_profile_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_macos.sh",
        "recover_pending_profile_transaction\nrestore_uncommitted_uninstall",
        ": # mutant: skip pending profile recovery\nrestore_uncommitted_uninstall"
      )

      assert_mutation_is_killed(
        root,
        "/usr/bin/env", "CLAUDE_EASY_RUN_PRODUCTION_PROBES=1",
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name",
        "test_production_probe_uninstall_recovers_a_killed_profile_transaction_before_enabling_updates"
      )
    end
  end

  def test_macos_uninstall_atomic_restore_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_macos.sh",
        "  if /bin/ln \"$slot\" \"$destination\"; then\n" \
        "    return 0\n" \
        "  fi\n",
        "  /bin/cp -p \"$slot\" \"$destination\"\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_uninstaller_resumes_after_kill_during_file_restore"
      )
    end
  end

  def test_macos_uninstall_incomplete_stage_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_macos.sh",
        "  if [ ! -f \"$UNINSTALL_STAGING/READY\" ]; then\n" \
        "    /bin/rm -rf \"$UNINSTALL_STAGING\"\n" \
        "    return 0\n" \
        "  fi\n",
        ""
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_uninstaller_discards_a_stage_killed_before_ready"
      )
    end
  end

  def test_macos_production_probe_inventory_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_macos_patcher.rb",
        "def test_production_probe_mihomo_does_not_survive_a_killed_validator",
        "def test_mihomo_does_not_survive_a_killed_validator"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_production_probe_inventory_and_ci_aggregation_are_fixed"
      )
    end
  end

  def test_windows_transaction_journal_matrix_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_windows_installer.ps1",
        '                    Name = "alternate-data-stream"',
        '                    Name = "alternate-stream-removed"'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_production_probe_inventory_and_ci_aggregation_are_fixed"
      )
    end
  end

  def test_windows_interrupted_new_file_probe_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_windows_installer.ps1",
        '        Invoke-DeferredProbe "interrupted new-file transaction preserves later content" {',
        '        Invoke-DeferredProbe "interrupted new-file transaction probe removed" {'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_production_probe_inventory_and_ci_aggregation_are_fixed"
      )
    end
  end

  def test_windows_interrupted_new_file_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        '            if ($snapshot.Exists -and' + "\n" +
          '                $currentHash -ne $replacementHash -and -not $isInterruptedReplacement) {' + "\n" +
          '                throw "中断事务新建目标有无法自动合并的新改动：$($action.Path)"' + "\n" +
          "            }\n",
        '            if ($false) {' + "\n" +
          '                throw "中断事务新建目标有无法自动合并的新改动：$($action.Path)"' + "\n" +
          "            }\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_interrupted_new_file_recovery_requires_managed_bytes"
      )
    end
  end

  def test_windows_recovery_prefix_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        '            -not ($action.Action -eq "delete" -and $isInterruptedOriginal)) {',
        '            $true) {'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_interrupted_recovery_accepts_only_original_byte_prefixes"
      )
    end
  end

  def test_windows_suffix_main_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/script_js.ps1",
        "                Assert-JavaScriptDoesNotBindMain $suffix\n",
        "                Assert-JavaScriptReservedIdentifiers $suffix\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_managed_script_suffix_cannot_rebind_main"
      )
    end
  end

  def test_windows_existing_script_main_binding_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/script_js.ps1",
        "    Assert-JavaScriptDoesNotBindMain $withoutDeclaration\n",
        "    Assert-JavaScriptReservedIdentifiers $withoutDeclaration\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_existing_script_cannot_rebind_main_outside_its_declaration"
      )
    end
  end

  def test_windows_atomic_backup_publication_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        "        [System.IO.File]::Move($temporary, $destination)\n",
        "        [System.IO.File]::Copy($temporary, $destination)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_backups_are_published_only_after_complete_private_write"
      )
    end
  end

  def test_windows_ambiguous_app_home_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        '    if ($existing.Count -gt 1) {',
        '    if ($false) {'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_default_app_home_rejects_multiple_existing_candidates"
      )
    end
  end

  def test_windows_public_uninstall_kill_probe_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "tests/test_windows_installer.ps1",
        '        $env:CLAUDE_EASY_TEST_UNINSTALL_CRASH_READY = $publicUninstallCrashReady',
        '        $env:CLAUDE_EASY_TEST_UNINSTALL_PROBE_REMOVED = $publicUninstallCrashReady'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_production_probe_inventory_and_ci_aggregation_are_fixed"
      )
    end
  end
end
