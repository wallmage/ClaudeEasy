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
        "--name", "test_both_route_verifiers_use_live_match_rule_for_main_group"
      )
    end
  end

  def test_macos_live_group_discovery_mutations_are_killed
    {
      "main_group = live_main_group(socket, proxies, main_group)" => [
        'main_group = "Proxy"',
        "test_route_verifier_does_not_read_the_disk_to_find_ai_group"
      ],
      'ai_group = find_group(proxies, policy["ai_group_names"], ai_group, ai: true)' =>
        ['ai_group = "Missing AI"', "test_route_verifier_does_not_read_the_disk_to_find_ai_group"]
    }.each do |source, mutation|
      replacement, test_name = mutation
      with_repo_copy do |root|
        replace_once(
          root,
          "claude-easy/scripts/macos/verify_routes.rb",
          source,
          replacement
        )

        assert_mutation_is_killed(
          root,
          RbConfig.ruby, "tests/test_macos_patcher.rb",
          "--name", test_name
        )
      end
    end
  end

  def test_windows_controller_secret_command_line_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/verify_routes.ps1",
        '    if (-not [string]::IsNullOrEmpty($Secret)) {' + "\n",
        '    if ($false) {' + "\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_route_verifier_keeps_the_controller_secret_off_process_metadata"
      )
    end
  end

  def test_windows_controller_redirect_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/verify_routes.ps1",
        '    $request.AllowAutoRedirect = $false' + "\n",
        '    $request.AllowAutoRedirect = $true' + "\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_route_verifier_keeps_the_controller_secret_off_process_metadata"
      )
    end
  end

  def test_windows_controller_loopback_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/verify_routes.ps1",
        '    if (-not $rawHostIsLoopback) {' + "\n",
        '    if ($false) {' + "\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_route_verifier_keeps_the_controller_secret_off_process_metadata"
      )
    end
  end

  def test_windows_controller_proxy_bypass_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/verify_routes.ps1",
        '    $request.Proxy = $null' + "\n",
        '    $request.Proxy = [System.Net.WebRequest]::DefaultWebProxy' + "\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_route_verifier_keeps_the_controller_secret_off_process_metadata"
      )
    end
  end

  def test_windows_supported_main_group_types_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/verify_routes.ps1",
        "if ($null -eq $property -or -not (Test-SupportedRouteGroupType ([string]$property.Value.type))) {",
        'if ($null -eq $property -or -not ([string]$property.Value.type -eq "Selector")) {'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_patch_runtime_route_verifiers_exist_on_both_platforms"
      )
    end
  end

  def test_safe_update_path_identity_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "  def locked_source_current?(source, path, write_path)\n",
        "  def locked_source_current?(source, path, write_path)\n    return true\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_transactional_replace_preserves_an_external_refresh_after_the_final_identity_check"
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

  def test_profile_transaction_precommit_binding_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "        current.fetch(:bytes) == item.fetch(:original).b &&\n" \
          "        File.realpath(logical_path) == write_path\n",
        "        true &&\n" \
          "        File.realpath(logical_path) == write_path\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_normal_batch_binds_unchanged_preflight_items_before_committing_other_profiles"
      )
    end
  end

  def test_normal_batch_transaction_inode_binding_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "         (expected_identity && [opened.dev, opened.ino] != expected_identity)\n",
        "         false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_normal_batch_binds_each_commit_to_the_transaction_inode"
      )
    end
  end

  def test_safe_update_transaction_inode_binding_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "        item[:transaction_identity] = target.fetch(:identity)\n",
        "        item[:transaction_identity] = [handle.stat.dev, handle.stat.ino]\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_binds_each_commit_to_the_transaction_inode"
      )
    end
  end

  def test_safe_update_transaction_realpath_binding_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "        unless write_path == target.fetch(:write_path)\n",
        "        if false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_binds_each_commit_to_the_transaction_realpath"
      )
    end
  end

  def test_profile_restore_removal_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        '    elif [ "$PROFILE_STATE_CHANGED" -eq 1 ] && ! rollback_profile_selection; then' + "\n",
        '    elif [ "$PROFILE_STATE_CHANGED" -eq 1 ] && false; then' + "\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_failed_profile_change_preserves_the_previous_saved_profile"
      )
    end
  end

  def test_profile_state_file_sync_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        "  durable_sync_file \"$USAGE_STATE_PATH\"\n",
        "  : # mutant: skip the profile file and parent-directory sync\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name",
        "test_installer_restores_the_previous_profile_when_profile_publication_cannot_sync"
      )
    end
  end

  def test_uninstall_ready_sync_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_macos.sh",
        "  /usr/bin/touch \"$UNINSTALL_STAGING/READY\"\n" \
          "  durable_sync_file \"$UNINSTALL_STAGING/READY\"\n",
        "  /usr/bin/touch \"$UNINSTALL_STAGING/READY\"\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name",
        "test_uninstaller_never_deletes_install_files_before_ready_is_durable"
      )
    end
  end

  def test_uninstall_delete_directory_sync_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_macos.sh",
        "  done\n" \
          "  durable_sync_directory \"$INSTALL_DIR\"\n" \
          "}\n\n" \
          "commit_staged_install_files()",
        "  done\n" \
          "}\n\n" \
          "commit_staged_install_files()"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name",
        "test_uninstaller_restores_every_file_when_the_delete_directory_cannot_sync"
      )
    end
  end

  def test_wrapper_inherited_lock_verification_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/operation_lock.rb",
        "  def inherited_lock_held?(path)\n" \
          "    return false unless ENV[HELD_ENV] == \"1\"\n",
        "  def inherited_lock_held?(_path)\n" \
          "    return true if ENV[HELD_ENV] == \"1\"\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_wrappers_reject_a_forged_inherited_lock_before_any_mutation"
      )
    end
  end

  def test_cli_saved_profile_match_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/cli.rb",
        "    return nil if saved == expected\n",
        "    return nil if saved\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name",
        "test_cli_profile_guard_rejects_unset_invalid_and_mismatched_state_before_work"
      )
    end
  end

  def test_safe_update_rollback_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "          write_path, current, original,\n" \
          "          expected_identity: expected_identity, expected_path: write_path\n",
        "          write_path, current, current,\n" \
          "          expected_identity: expected_identity, expected_path: write_path\n"
      )

      assert_mutation_is_killed(
        root,
        { "CLAUDE_EASY_RUN_PRODUCTION_PROBES" => "1" },
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_production_probe_next_safe_update_recovers_batch_killed_after_first_descriptor_commit"
      )
    end
  end

  def test_pending_patch_runtime_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "                          reload_runtime && reload_recovered_profile_runtime(\n" \
          "                            work_items, require_tun: require_tun, socket: socket,\n" \
          "                            requester: requester, connectivity_checker: connectivity_checker,\n" \
          "                            precommit_condition: precommit_condition,\n" \
          "                            runtime_checkpoint: transaction.fetch(:runtime_checkpoint, nil)\n" \
          "                          )\n",
        "                          true\n"
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
          "                %i[reload_failed_restore_pending reload_failed_rollback_conflict].include?(\n" \
          "                  result[:status]\n" \
          "                )\n" \
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

  def test_active_reload_candidate_identity_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "    code, _body = requester.call(\n" \
          "      \"PUT\", \"/configs?force=true\", JSON.generate(\"path\" => File.expand_path(result.fetch(:path)))\n" \
          "    )\n" \
          "    return pending.call unless profile_result_current?(result)\n",
        "    code, _body = requester.call(\n" \
          "      \"PUT\", \"/configs?force=true\", JSON.generate(\"path\" => File.expand_path(result.fetch(:path)))\n" \
          "    )\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_active_reload_never_accepts_a_replaced_candidate_inode"
      )
    end
  end

  def test_cold_reload_connectivity_delay_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "      sleep 1 if attempt < 2\n" \
          "    rescue StandardError\n" \
          "      sleep 1 if attempt < 2\n",
        "    rescue StandardError\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_default_connectivity_waits_between_cold_reload_failures"
      )
    end
  end

  def test_runtime_reload_tun_verification_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "      restore_runtime_tun_state(requester, expected_tun) &&\n" \
          "      restore_runtime_selections(requester, selections)\n",
        "      restore_runtime_selections(requester, selections)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_runtime_rollback_does_not_patch_tun_when_the_original_subscription_omits_it"
      )
    end
  end

  def test_safe_update_recovery_tun_restore_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "        selections: selections, expected_tun: expected_tun,\n" \
          "        required_proxy_group: required_proxy_group,\n",
        "        selections: selections, expected_tun: :ignore,\n" \
          "        required_proxy_group: required_proxy_group,\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_recovered_safe_update_runtime_uses_the_saved_checkpoint"
      )
    end
  end

  def test_recovered_patch_runtime_dns_baseline_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "      precommit_condition: precommit_condition, check_dns: false\n" \
          "    )\n" \
          "    healthy && runtime_precommit_allowed?(precommit_condition)\n" \
          "  rescue StandardError\n" \
          "    false\n" \
          "  end\n\n" \
          "  def verify_unchanged_profile_runtime",
        "      precommit_condition: precommit_condition\n" \
          "    )\n" \
          "    healthy && runtime_precommit_allowed?(precommit_condition)\n" \
          "  rescue StandardError\n" \
          "    false\n" \
          "  end\n\n" \
          "  def verify_unchanged_profile_runtime"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_recovered_runtime_accepts_the_original_dns_limit_when_connectivity_is_restored"
      )
    end
  end

  def test_runtime_rollback_dns_baseline_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "      precommit_condition: precommit_condition, check_dns: false\n" \
          "    )\n" \
          "    return :reload_failed_rolled_back if\n" \
          "      healthy && runtime_precommit_allowed?(precommit_condition)",
        "      precommit_condition: precommit_condition\n" \
          "    )\n" \
          "    return :reload_failed_rolled_back if\n" \
          "      healthy && runtime_precommit_allowed?(precommit_condition)"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_runtime_rollback_accepts_the_original_dns_limit_when_connectivity_is_restored"
      )
    end
  end

  def test_safe_update_recovery_dns_baseline_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "        required_proxy_group: required_proxy_group, flush_caches: false\n",
        "        required_proxy_group: required_proxy_group, check_dns: false, flush_caches: false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_clashx_runtime_waits_for_profile_match_and_full_health"
      )
    end
  end

  def test_active_reload_candidate_selection_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "      requester, selections: candidate_selections, expected_tun: expected_tun,\n",
        "      requester, selections: before, expected_tun: expected_tun,\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_active_reload_allows_a_removed_legacy_managed_selector"
      )
    end
  end

  def test_runtime_profile_selection_filter_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "    selections.select { |name, _selected| selector_names.include?(name) }\n",
        "    selections\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_active_reload_allows_a_removed_legacy_managed_selector"
      )
    end
  end

  def test_restore_backup_transaction_creation_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/backups.rb",
        "    create_versioned_backup(target, backup_root, content: current_bytes, reason: \"pre-restore\")\n" \
          "    begin\n" \
          "      transaction = prepare_profile_transaction(\n" \
          "        [{ path: target, original: current_bytes, candidate: backup_bytes }],\n" \
          "        backup_root, roots: directories, runtime_checkpoint: runtime_checkpoint\n" \
          "      )\n" \
          "    rescue ConcurrentProfileChangeError\n" \
          "      return { status: :restore_conflict, path: target }\n" \
          "    end\n",
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
          "    finish_backup_restore_transaction(\n" \
          "      transaction, result, precommit_condition: precommit_condition\n" \
          "    )\n",
        "    remove_profile_transaction(transaction)\n" \
          "    result = activation.call(result) if activation\n" \
          "    finish_backup_restore_transaction(\n" \
          "      transaction, result, precommit_condition: precommit_condition\n" \
          "    )\n"
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

  def test_restore_backup_candidate_identity_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/backups.rb",
        "      status: :updated,\n" \
          "      path: target,\n" \
          "      rollback_bytes: current_bytes,\n" \
          "      patched_digest: Digest::SHA256.hexdigest(backup_bytes),\n" \
          "      patched_identity: transaction_target.fetch(:identity),\n",
        "      status: :updated,\n" \
          "      path: target,\n" \
          "      rollback_bytes: current_bytes,\n" \
          "      patched_digest: Digest::SHA256.hexdigest(backup_bytes),\n" \
          "      patched_identity: nil,\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_backup_restore_runtime_rollback_never_overwrites_a_replaced_candidate_inode"
      )
    end
  end

  def test_restore_backup_no_change_transaction_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/backups.rb",
        "    if current_bytes == backup_bytes\n" \
          "      begin\n" \
          "        transaction = prepare_profile_transaction(\n" \
          "          [{ path: target, original: current_bytes, candidate: backup_bytes }],\n" \
          "          backup_root, roots: directories, runtime_checkpoint: runtime_checkpoint\n" \
          "        )\n" \
          "      rescue ConcurrentProfileChangeError\n" \
          "        return { status: :restore_conflict, path: target }\n" \
          "      end\n",
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

  def test_safe_update_closes_locked_handles_before_rollback_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "      handles.each { |_item, handle| handle.close rescue nil }\n" \
          "      handles.clear\n" \
          "      rollback = finish_safe_update_rollback(items, transaction, backup_root, roots)\n",
        "      handles.clear\n" \
          "      rollback = finish_safe_update_rollback(items, transaction, backup_root, roots)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_closes_profile_handles_before_entering_rollback"
      )
    end
  end

  def test_safe_update_pending_runtime_resume_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "      if journal_pending\n",
        "      if false\n"
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

  def test_profile_transaction_original_inode_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        <<~RUBY.lines.map { |line| "        #{line}" }.join,
          unless current_snapshot.fetch(:identity) == expected_identity
            fully_restored = false
            next
          end
        RUBY
        "        true\n"
      )
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "          expected_identity: expected_identity, expected_path: write_path\n",
        "          expected_identity: nil, expected_path: write_path\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_profile_transaction_keeps_candidate_bytes_after_an_atomic_replacement"
      )
    end
  end

  def test_profile_transaction_v1_identity_fail_closed_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        '      raise InvalidConfigError, "旧版配置事务缺少文件身份，不能自动恢复"',
        "      next"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_profile_transaction_v1_never_overwrites_an_unidentified_candidate_inode"
      )
    end
  end

  def test_profile_transaction_interrupted_bytes_validation_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "        unless current == candidate\n" \
          "          fully_restored = false\n" \
          "          next\n" \
          "        end\n",
        "        next unless current == candidate\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_profile_transaction_recovery_continues_after_a_same_inode_partial_write"
      )
    end
  end

  def test_safe_update_v2_journal_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "    recover_profile_transaction(backup_root, roots: roots, keep_transaction: keep_transaction)\n",
        "    remove_profile_transaction(transaction)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_safe_update_preserves_an_ambiguous_partial_descriptor_write_and_journal"
      )
    end
  end

  def test_profile_transaction_write_path_boundary_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "        profile_path_allowed?(logical_path, roots) &&\n" \
          "        profile_path_allowed?(write_path, roots)\n\n" \
          "      current = regular_file_snapshot_once(write_path, \"当前配置\")\n",
        "        profile_path_allowed?(logical_path, roots)\n\n" \
          "      current = regular_file_snapshot_once(write_path, \"当前配置\")\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_profile_transaction_rejects_a_symlink_target_outside_the_profile_root_before_publication"
      )
    end
  end

  def test_profile_transaction_journal_publication_directory_sync_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "      ClaudeEasyDarwinFilesystem.rename_exclusive(temporary.path, path)\n" \
          "      fsync_parent_directory(path)\n",
        "      ClaudeEasyDarwinFilesystem.rename_exclusive(temporary.path, path)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_profile_transaction_fsyncs_the_journal_directory_after_publish_and_remove"
      )
    end
  end

  def test_profile_transaction_journal_removal_directory_sync_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "      File.unlink(path) if [current.dev, current.ino] == committed.fetch(:identity)\n" \
          "      fsync_parent_directory(path)\n",
        "      File.unlink(path) if [current.dev, current.ino] == committed.fetch(:identity)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_profile_transaction_fsyncs_the_journal_directory_after_publish_and_remove"
      )
    end
  end

  def test_profile_transaction_committed_marker_directory_sync_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "          File.rename(temporary.path, path)\n" \
          "          begin\n" \
          "            fsync_parent_directory(path)\n",
        "          File.rename(temporary.path, path)\n" \
          "          begin\n" \
          "            true\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_profile_transaction_fsyncs_the_journal_directory_after_publish_and_remove"
      )
    end
  end

  def test_auto_update_ownership_directory_sync_barrier_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "        ClaudeEasyDarwinFilesystem.rename_exclusive(file.path, path)\n" \
          "        fsync_parent_directory(path)\n",
        "        ClaudeEasyDarwinFilesystem.rename_exclusive(file.path, path)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_auto_update_ownership_directory_sync_failure_prevents_the_preference_write"
      )
    end
  end

  def test_auto_update_ownership_exclusive_publication_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "        ClaudeEasyDarwinFilesystem.rename_exclusive(file.path, path)\n",
        "        File.rename(file.path, path)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name",
        "test_auto_update_ownership_initial_publication_never_overwrites_a_racing_file"
      )
    end
  end

  def test_secure_backup_root_parent_publication_sync_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/backups.rb",
        "      fsync_directory(directory)\n" \
          "      fsync_directory(File.dirname(directory))\n",
        "      fsync_directory(directory)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_secure_backup_root_durably_publishes_each_new_directory"
      )
    end
  end

  def test_secure_backup_root_retry_resync_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/backups.rb",
        "    existing_parent = File.dirname(cursor)\n" \
          "    fsync_directory(existing_parent) unless existing_parent == cursor\n",
        "    existing_parent = File.dirname(cursor)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_secure_backup_root_retry_resynchronizes_a_directory_left_by_a_failed_publication"
      )
    end
  end

  def test_wrapper_operation_lock_parent_publication_sync_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/operation_lock.rb",
        "      fsync_directory(directory)\n" \
          "      fsync_directory(File.dirname(directory))\n",
        "      fsync_directory(directory)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_wrapper_operation_lock_durably_publishes_each_new_state_directory"
      )
    end
  end

  def test_wrapper_operation_lock_retry_resync_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/operation_lock.rb",
        "    existing_parent = File.dirname(cursor)\n" \
          "    fsync_directory(existing_parent) unless existing_parent == cursor\n",
        "    existing_parent = File.dirname(cursor)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_wrapper_operation_lock_durably_publishes_each_new_state_directory"
      )
    end
  end

  def test_versioned_backup_directory_sync_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/backups.rb",
        "    end\n\n" \
          "    fsync_directory(root)\n" \
          "    destination\n",
        "    end\n\n" \
          "    destination\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_versioned_backup_syncs_its_directory_after_the_file_is_complete"
      )
    end
  end

  def test_auto_update_ownership_post_write_identity_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "      source.flush\n" \
          "      source.fsync\n" \
          "      locked_source_current?(source, path, write_path)\n",
        "      source.flush\n" \
          "      source.fsync\n" \
          "      true\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_auto_update_ownership_release_preserves_an_atomic_refresh"
      )
    end
  end

  def test_auto_update_ownership_append_prefix_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "      source.truncate(valid_bytes.bytesize)\n",
        "      source.truncate(0)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_auto_update_ownership_append_failure_preserves_the_fsynced_prefix"
      )
    end
  end

  def test_auto_update_ownership_release_event_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "    changed = append_auto_update_ownership_event(state, event)\n" \
          "    raise IOError, \"订阅自动更新所有权状态同时发生变化\" unless changed\n",
        "    changed = true\n" \
          "    raise IOError, \"订阅自动更新所有权状态同时发生变化\" unless changed\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_auto_update_ownership_release_preserves_an_atomic_refresh"
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

  def test_macos_owned_disabled_uninstall_recovery_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_macos.sh",
        "      disabled|already_disabled|already_disabled_owned) ;;\n",
        "      disabled|already_disabled) ;;\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_p1_recovery_and_refresh_guards_are_documented_and_exercised"
      )
    end
  end

  def test_windows_running_all_profiles_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_windows.ps1",
        "    if ($clientRunning) {\n",
        "    if ($false) {\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_p1_recovery_and_refresh_guards_are_documented_and_exercised"
      )
    end
  end

  def test_windows_legacy_safe_update_auto_restore_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_windows.ps1",
        '        if (@($recoveryItems | Where-Object { -not $_.CanAutoRestore }).Count -gt 0) {' + "\n",
        "        if ($false) {\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_p1_recovery_and_refresh_guards_are_documented_and_exercised"
      )
    end
  end

  def test_windows_legacy_safe_update_backup_dependency_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/safe_update.ps1",
        "        if ($manifestVersion -ge 2 -and (\n",
        "        if ($true -and (\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_p1_recovery_and_refresh_guards_are_documented_and_exercised"
      )
    end
  end

  def test_windows_safe_update_control_file_concurrency_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_windows.ps1",
        "        if (-not $safeUpdateContentRestoreEligible) {\n",
        "        if ($false) {\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_p1_recovery_and_refresh_guards_are_documented_and_exercised"
      )
    end
  end

  def test_windows_null_update_timestamp_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/profiles.ps1",
        "        if ($updatedRawValue -match '^(?:~|null|Null|NULL)$') {\n",
        "        if ($false) {\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_p1_recovery_and_refresh_guards_are_documented_and_exercised"
      )
    end
  end

  def test_windows_safe_update_snapshot_index_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/safe_update.ps1",
        "        $fileGuards += $indexGuard\n",
        "        $indexGuard.Dispose()\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_p1_recovery_and_refresh_guards_are_documented_and_exercised"
      )
    end
  end

  def test_contract_windows_safe_update_requires_a_passive_script_envelope
    source = File.read(
      File.join(
        ROOT,
        "claude-easy/scripts/windows/install_windows/safe_update.ps1"
      )
    )
    analysis_source = File.read(
      File.join(
        ROOT,
        "claude-easy/scripts/windows/install_windows/script_js.ps1"
      )
    )

    assert_includes source,
                    "function Assert-ClaudeEasyScriptOutsideManagedBlockIsPassive("
    assert_includes source,
                    "Assert-ClaudeEasyScriptOutsideManagedBlockIsPassive $ScriptText"
    assert_includes source, "Get-JavaScriptAnalysis $outsidePrefix"
    assert_includes source, "Get-JavaScriptAnalysis $outsideSuffix"
    assert_includes source, '$outsidePrefixAnalysis.HasLiteral'
    assert_includes source, '$outsideSuffixAnalysis.HasLiteral'
    assert_includes analysis_source, 'HasLiteral = $hasLiteral'
  end

  def test_contract_windows_script_composition_rejects_unrenamed_main_references
    source = File.read(
      File.join(
        ROOT,
        "claude-easy/scripts/windows/install_windows/script_js.ps1"
      )
    )

    assert_includes source, "function Assert-JavaScriptDoesNotReferenceMain("
    assert_includes source, "Assert-JavaScriptDoesNotReferenceMain $withoutDeclaration"
    assert_includes source, "不能在入口声明之外引用 main"
  end

  def test_contract_windows_delete_recovery_uses_an_atomic_private_file
    source = File.read(
      File.join(
        ROOT,
        "claude-easy/scripts/windows/install_windows/transaction.ps1"
      )
    )
    helper_start = source.index("function New-InterruptedRecoveryTemporaryFile(")
    helper_end = source.index(
      "function Remove-InterruptedRecoveryTemporaryFile(",
      helper_start || 0
    )
    invoke_start = source.index("function Invoke-InterruptedTransactionRecovery(")
    invoke_end = source.index(
      "function Assert-InterruptedTransactionRecovered(",
      invoke_start || 0
    )

    refute_nil helper_start
    refute_nil helper_end
    refute_nil invoke_start
    refute_nil invoke_end
    helper = source[helper_start...helper_end]
    invocation = source[invoke_start...invoke_end]
    assert_includes source,
                    "public static SafeFileHandle CreatePrivateFile(string path)"
    assert_includes source, "private struct SecurityAttributes"
    assert_includes source, "security.GetSecurityDescriptorBinaryForm()"
    assert_includes helper, "CreatePrivateFile"
    assert_includes helper, '$stream.Flush($true)'
    assert_includes invocation,
                    "[System.IO.File]::Move(\n" \
                    "                        $entry.Temporary.Path,\n" \
                    "                        $entry.Item.Action.Path\n" \
                    "                    )"
    assert_includes source,
                    '$differentIdentityIsRestoredOriginal = $action.Action -eq "write" -and'
    assert_includes source,
                    '$snapshot.Identity -cne $action.Identity -and' \
                    "\n            -not $differentIdentityIsRestoredOriginal -and"
    assert_includes source,
                    '($action.Action -ne "delete" -or ' \
                    '$currentHash -ne $originalHash)) {'
  end

  def test_windows_safe_update_passive_envelope_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/safe_update.ps1",
        "    Assert-ClaudeEasyScriptOutsideManagedBlockIsPassive $ScriptText\n",
        ""
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_mutation_safety.rb",
        "--name",
        "test_contract_windows_safe_update_requires_a_passive_script_envelope"
      )
    end
  end

  def test_windows_safe_update_literal_envelope_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/safe_update.ps1",
        "    if ($outsidePrefixAnalysis.HasLiteral -or\n" \
          "        $outsideSuffixAnalysis.HasLiteral -or\n",
        "    if ($false -or\n" \
          "        $false -or\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_mutation_safety.rb",
        "--name",
        "test_contract_windows_safe_update_requires_a_passive_script_envelope"
      )
    end
  end

  def test_windows_main_reference_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/script_js.ps1",
        "    Assert-JavaScriptDoesNotReferenceMain $withoutDeclaration\n",
        ""
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_mutation_safety.rb",
        "--name",
        "test_contract_windows_script_composition_rejects_unrenamed_main_references"
      )
    end
  end

  def test_windows_delete_recovery_identity_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        '            ($action.Action -ne "delete" -or ' \
          '$currentHash -ne $originalHash)) {' + "\n",
        '            -not ($action.Action -eq "delete" -and ' \
          '$isInterruptedOriginal)) {' + "\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_mutation_safety.rb",
        "--name",
        "test_contract_windows_delete_recovery_uses_an_atomic_private_file"
      )
    end
  end

  def test_windows_delete_recovery_atomic_publish_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        "                    [System.IO.File]::Move(\n" \
          "                        $entry.Temporary.Path,\n" \
          "                        $entry.Item.Action.Path\n" \
          "                    )\n",
        "                    [System.IO.File]::WriteAllBytes(\n" \
          "                        $entry.Item.Action.Path,\n" \
          "                        $entry.Item.Action.Original\n" \
          "                    )\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_mutation_safety.rb",
        "--name",
        "test_contract_windows_delete_recovery_uses_an_atomic_private_file"
      )
    end
  end

  def test_windows_delete_recovery_durable_temporary_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        "        $stream.SetLength($Bytes.Length)\n" \
          "        $stream.Flush($true)\n" \
          "        $completedBytes = Get-StreamBytes $stream\n",
        "        $stream.SetLength($Bytes.Length)\n" \
          "        $completedBytes = Get-StreamBytes $stream\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_mutation_safety.rb",
        "--name",
        "test_contract_windows_delete_recovery_uses_an_atomic_private_file"
      )
    end
  end

  def test_windows_delete_recovery_private_temporary_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        "        $handle = [ClaudeEasy.VerifiedDeleteNative]::CreatePrivateFile($temporary)\n",
        "        $handle = [ClaudeEasy.VerifiedDeleteNative]::Open($temporary, $true, $true)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_mutation_safety.rb",
        "--name",
        "test_contract_windows_delete_recovery_uses_an_atomic_private_file"
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

  def test_windows_safe_update_rollback_runtime_record_transaction_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/safe_update.ps1",
        "                Invoke-VerifiedWriteDeleteTransaction (@($targets) + @($manifestTarget)) @() `\n" \
        "                    -InterruptedRecoveryPolicy \"safe_update_running_client\"\n",
        "            Invoke-VerifiedFileTransaction $targets\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_failed_safe_update_rollback_publishes_runtime_recovery_in_the_same_transaction"
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

  def test_windows_interrupted_client_sensitive_recovery_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        "        \$preCommitCondition `\n        \$finalizeCondition\n",
        "        \$null `\n        \$finalizeCondition\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_interrupted_client_sensitive_recovery_waits_for_the_client"
      )
    end
  end

  def test_windows_interrupted_recovery_final_rejection_rollback_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        "                if (\$finalizeRejected) {\n" \
        "                    Undo-InterruptedTransactionRecovery \$opened\n" \
        "                    \$rollbackCompleted = \$true\n",
        "                if (\$finalizeRejected) {\n" \
        "                    \$rollbackCompleted = \$true\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_interrupted_client_sensitive_recovery_waits_for_the_client"
      )
    end
  end

  def test_windows_legacy_interrupted_recovery_policy_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        '    if ([long]$Record.Version -eq 1) { return "client_stopped" }',
        '    if ([long]$Record.Version -eq 1) { return "safe_update_running_client" }'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_interrupted_client_sensitive_recovery_waits_for_the_client"
      )
    end
  end

  def test_windows_interrupted_client_sensitive_preparation_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/transaction.ps1",
        "                \$finalizeRejected = -not (\n                    Test-InterruptedRecoveryCommitCondition \$preCommitCondition\n",
        "                \$finalizeRejected = -not (\n                    \$true\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name",
        "test_windows_interrupted_client_sensitive_recovery_waits_for_the_client"
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

  def test_windows_light_profile_uninstall_client_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_windows.ps1",
        "$uninstallHasProtectedChanges = " \
        "($filePlans.Count -gt 0 -or $null -ne $state -or " \
        "$autoUpdateStateExists -or $usageStateExists)",
        "$uninstallHasProtectedChanges = ($null -ne $state)"
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
        "    $committed = Invoke-VerifiedPathTransaction $Targets @() " \
        "$PreCommitCondition $InterruptedRecoveryPolicy\n",
        "    $committed = Invoke-VerifiedPathTransaction $Targets @() " \
        "$null $InterruptedRecoveryPolicy\n"
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

  def test_ruby_subscription_filter_fail_closed_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/transform.rb",
        "    return false unless group[\"exclude-filter\"].to_s.empty?\n",
        "    group[\"exclude-filter\"].to_s.empty?\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_group_safety_never_executes_subscription_controlled_catastrophic_filters"
      )
    end
  end

  def test_windows_subscription_filter_fail_closed_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/clash_verge_global.js",
        "  if (exclusion !== undefined && exclusion !== null && exclusion !== \"\") return false;\n",
        "  exclusion !== undefined && exclusion !== null && exclusion !== \"\";\n"
      )

      assert_mutation_is_killed(
        root,
        "node", "--test",
        "--test-name-pattern=catastrophic group filters",
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
        "    begin\n" \
          "      source.rewind\n" \
          "      source.truncate(0)\n" \
          "      restored = source.write(original_bytes)",
        "    begin\n" \
          "      raise write_error\n" \
          "      source.rewind\n" \
          "      source.truncate(0)\n" \
          "      restored = source.write(original_bytes)"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_locked_write_restores_original_bytes_after_a_partial_write_error"
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

  def test_route_custom_non_proxy_type_mutations_are_killed
    types = %w[Direct Dns Reject RejectDrop Pass PassRule Compatible Rematch Relay]
    types.each do |removed|
      with_repo_copy do |root|
        replace_once(
          root,
          "claude-easy/scripts/macos/verify_routes.rb",
          "  NON_PROXY_TYPES = %w[#{types.join(' ')}].freeze\n",
          "  NON_PROXY_TYPES = %w[#{(types - [removed]).join(' ')}].freeze\n"
        )

        assert_mutation_is_killed(
          root,
          RbConfig.ruby, "tests/test_macos_patcher.rb",
          "--name", "test_route_verifier_rejects_every_custom_non_proxy_outbound_type"
        )
      end
    end
  end

  def test_route_provider_leaf_lookup_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/verify_routes.rb",
        "      return Array(provider[\"proxies\"]).find do |proxy|\n" \
          "        proxy.is_a?(Hash) && proxy[\"name\"].to_s == name.to_s\n" \
          "      end\n",
        "      return nil\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_route_verifier_resolves_provider_leaf_types"
      )
    end
  end

  def test_route_provider_endpoint_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/verify_routes.rb",
        '    provider_payload = get_json(socket, "/providers/proxies")',
        '    provider_payload = get_json(socket, "/proxies")'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_route_verifier_runs_the_provider_endpoint_and_provider_chains_end_to_end"
      )
    end
  end

  def test_route_provider_chain_forwarding_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/verify_routes.rb",
        '      provider_chains = Array(connection && connection["providerChains"])',
        "      provider_chains = []"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_route_verifier_runs_the_provider_endpoint_and_provider_chains_end_to_end"
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
        "if [ \"$SAFE_UPDATE\" -ne 1 ]; then\n" \
          "  if [ -z \"$PREVIOUS_PROFILE\" ]; then\n" \
          "    AUTO_UPDATE_RECOVERY_REQUIRED=1\n" \
          "  fi\n",
        "if [ \"$SAFE_UPDATE\" -ne 1 ]; then\n" \
          "  AUTO_UPDATE_RECOVERY_REQUIRED=0\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_first_install_restores_auto_update_when_a_later_step_fails"
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
          "  AUTO_UPDATE_RECOVERY_REQUIRED=0\n" \
          "  AUTO_UPDATE_RECOVERY_PENDING=0\n" \
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
        "    trap ':' HUP INT TERM\n" \
          "    set +e\n" \
          "    /usr/bin/ruby \"$OPERATION_LOCK_SOURCE\" \"$OPERATION_LOCK_PATH\" /bin/sh \"$0\" \"$@\"\n",
        "    set +e\n" \
          "    /usr/bin/ruby \"$OPERATION_LOCK_SOURCE\" \"$OPERATION_LOCK_PATH\" /bin/sh \"$0\" \"$@\"\n"
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
        "  elif [ \"\$PROFILE_OPERATION_RECEIPT_INVALID\" -eq 1 ] ||\n" \
          "       [ \"\$PROFILE_OPERATION_CHILD_STATUS\" -ge 128 ]; then\n" \
          "    preserve_profile_operation_state\n" \
          "    PROFILE_OPERATION_RECOVERY_INTENT=1\n" \
          "    PROFILE_OPERATION_RESULT_UNKNOWN=1\n",
        "  elif [ \"\$PROFILE_OPERATION_RECEIPT_INVALID\" -eq 1 ] ||\n" \
          "       [ \"\$PROFILE_OPERATION_CHILD_STATUS\" -ge 128 ]; then\n" \
          "    preserve_profile_operation_state\n" \
          "    PROFILE_OPERATION_RECOVERY_INTENT=1\n" \
          "    PROFILE_OPERATION_RESULT_UNKNOWN=0\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_uncertain_or_unpublished_commit_receipt_preserves_outer_profile_state"
      )
    end
  end

  def test_macos_uncertain_profile_commit_exit_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        '  elif [ "$PROFILE_OPERATION_CHILD_STATUS" -eq 77 ]; then',
        '  elif [ "$PROFILE_OPERATION_CHILD_STATUS" -eq 78 ]; then'
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
        "    ownership = write_auto_update_ownership_state(\n" \
          "      backup_root, domain, original, \"installed\", existing: auto_update_ownership_state(backup_root)\n" \
          "    )\n",
        "    ownership = { \"Path\" => auto_update_ownership_path(backup_root) }\n"
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

  def test_runtime_fakeip_flush_reintroduction_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        "      code, _body = requester.call(\"POST\", \"/cache/dns/flush\", nil)\n" \
          "      return false unless [200, 204].include?(code)\n",
        "      caches_flushed = [\"/cache/fakeip/flush\", \"/cache/dns/flush\"].all? do |endpoint|\n" \
          "        code, _body = requester.call(\"POST\", endpoint, nil)\n" \
          "        [200, 204].include?(code)\n" \
          "      end\n" \
          "      return false unless caches_flushed\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_run_automatically_reloads_and_checks_the_active_profile"
      )
    end
  end

  def test_macos_wrapper_fakeip_flush_reintroduction_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        "if [ \"$SAFE_UPDATE\" -eq 1 ]; then\n  if [ -n \"$CUSTOM_PROFILE_DIR\" ]; then\n",
        "/usr/bin/curl -X POST http://localhost/cache/fakeip/flush\n" \
          "if [ \"$SAFE_UPDATE\" -eq 1 ]; then\n  if [ -n \"$CUSTOM_PROFILE_DIR\" ]; then\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_policy_documents_dns_filters_and_safety_migrations"
      )
    end
  end

  def test_runtime_fixed_foreign_dns_query_reintroduction_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/runtime.rb",
        '      return false unless dns_runtime_healthy?(requester, "www.baidu.com")',
        "      return false unless dns_runtime_healthy?(requester, \"www.baidu.com\")\n" \
          "      return false unless dns_runtime_healthy?(requester, \"www.google.com\")"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_run_automatically_reloads_and_checks_the_active_profile"
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
          "        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)\n" +
          "        $stagingStream = New-PrivateFileStream $staging",
        "        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)\n" +
          "        $stagingStream = New-PrivateFileStream $staging\n" +
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

  def test_macos_uninstall_post_verification_quarantine_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_macos.sh",
        '  quarantine_staged_slot "$USAGE_STATE_PATH" usage || finish_quarantine_failure',
        '  /bin/rm -f "$USAGE_STATE_PATH"'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_uninstaller_preserves_a_replacement_created_after_final_verification"
      )
    end
  end

  def test_macos_install_package_bootstrap_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/install_macos.sh",
        "install_package_dependencies_load() {\n" \
          "  /usr/bin/ruby \"$PATCHER_SOURCE\" --json --help >/dev/null 2>&1\n" \
          "}\n",
        "install_package_dependencies_load() {\n" \
          "  return 0\n" \
          "}\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_installer_rejects_each_missing_release_dependency_before_creating_state"
      )
    end
  end

  def test_macos_uninstall_phase_aware_exit_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/uninstall_macos.sh",
        "          unexpected_code=uninstall_interrupted_rolled_back\n",
        "          unexpected_code=unexpected_exit\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_wrappers.rb",
        "--name", "test_uninstaller_never_deletes_install_files_before_ready_is_durable"
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
          "           results.any? { |result| result[:status] == :updated } &&\n" \
          "           !runtime_precommit_allowed?(precommit_condition)\n",
        "        if false &&\n" \
          "           results.any? { |result| result[:status] == :updated } &&\n" \
          "           !runtime_precommit_allowed?(precommit_condition)\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name",
        "test_run_rechecks_profile_context_after_all_files_are_written"
      )
    end
  end

  def test_macos_runtime_recovery_profile_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "                            requester: requester, connectivity_checker: connectivity_checker,\n" \
          "                            precommit_condition: precommit_condition,\n" \
          "                            runtime_checkpoint: transaction.fetch(:runtime_checkpoint, nil)\n",
        "                            requester: requester, connectivity_checker: connectivity_checker,\n" \
          "                            precommit_condition: nil,\n" \
          "                            runtime_checkpoint: transaction.fetch(:runtime_checkpoint, nil)\n"
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
          'if [ "$OPERATION_LOCK_REQUIRED" -eq 1 ]; then',
          'if [ "$OPERATION_LOCK_REQUIRED" -eq 0 ]; then'
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
        "recover_pending_profile_transaction\nrestore_uncommitted_or_finish",
        ": # mutant: skip pending profile recovery\nrestore_uncommitted_or_finish"
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
        "    if durable_rename_exclusive \"$removed_slot\" \"$destination\"; then\n" \
          "      return 0\n" \
          "    fi\n",
        "    /bin/cp -p \"$removed_slot\" \"$destination\"\n"
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
          "    if ! /bin/rm -rf \"$UNINSTALL_STAGING\" ||\n" \
          "       ! durable_sync_directory \"$INSTALL_DIR\"; then\n" \
          "      set_restore_failure uninstall_restore_failed \"未完成的卸载暂存无法完整清理或同步。\"\n" \
          "      return 1\n" \
          "    fi\n" \
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
        '            ($action.Action -ne "delete" -or ' \
          '$currentHash -ne $originalHash)) {',
        '            ($action.Action -ne "delete" -or ' \
          '$isInterruptedOriginal)) {'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_mutation_safety.rb",
        "--name",
        "test_contract_windows_delete_recovery_uses_an_atomic_private_file"
      )
    end
  end

  def test_windows_suffix_main_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/script_js.ps1",
        "                    Assert-JavaScriptCanCompose $restored\n" \
          "                    $previous = Rename-JavaScriptMain $restored \"main\" \"claudeEasyPreviousMain\"\n" \
          "                    $currentDirectives = @(Get-JavaScriptDirectivePrologue $previous)\n",
        "                    Assert-JavaScriptReservedIdentifiers $restored\n" \
          "                    $previous = Rename-JavaScriptMain $restored \"main\" \"claudeEasyPreviousMain\"\n" \
          "                    $currentDirectives = @(Get-JavaScriptDirectivePrologue $previous)\n"
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

  def test_windows_dynamic_code_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/script_js.ps1",
        "    Assert-JavaScriptDoesNotUseDynamicCode $Text\n",
        "    Assert-JavaScriptReservedIdentifiers $Text\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_existing_script_rejects_dynamic_global_escape_before_writing"
      )
    end
  end

  def test_windows_computed_constructor_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/script_js.ps1",
        '$_.Substring(1, $_.Length - 2) -ceq "constructor"',
        '$_.Substring(1, $_.Length - 2) -ceq "constructor-disabled"'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_existing_script_rejects_dynamic_global_escape_before_writing"
      )
    end
  end

  def test_windows_template_expression_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/script_js.ps1",
        "                \$templateExpressionDepths += 1\n",
        "                \$templateExpressionDepths += 0\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_existing_script_rejects_dynamic_global_escape_before_writing"
      )
    end
  end

  def test_windows_safe_update_envelope_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/safe_update.ps1",
        "    $managed = Get-ClaudeEasyManagedScriptEnvelope $ScriptText $UsageProfile\n",
        "    $managed = Get-ClaudeEasyManagedScriptBlock $ScriptText $UsageProfile\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_safe_update_compares_managed_envelope_not_user_script_body"
      )
    end
  end

  def test_windows_managed_script_entry_seal_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/script_js.ps1",
        '$parts += "    configurable: false"',
        '$parts += "    configurable: true"'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_managed_script_preserves_top_level_semantics_then_seals_entry"
      )
    end
  end

  def test_windows_managed_script_finally_restore_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/script_js.ps1",
        '$parts += "        claudeEasyRestoreIntrinsics();"',
        '$parts += "        // intrinsic restoration removed"'
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_managed_script_preserves_top_level_semantics_then_seals_entry"
      )
    end
  end

  def test_windows_managed_script_finalization_order_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/windows/install_windows/script_js.ps1",
        "    $parts += $originalEnd\n" \
          "    $parts += 'claudeEasyInstallManagedMain(typeof claudeEasyPreviousMain === \"function\" ? claudeEasyPreviousMain : null);'\n",
        "    $parts += 'claudeEasyInstallManagedMain(typeof claudeEasyPreviousMain === \"function\" ? claudeEasyPreviousMain : null);'\n" \
          "    $parts += $originalEnd\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_skill_contract.rb",
        "--name", "test_windows_managed_script_preserves_top_level_semantics_then_seals_entry"
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
        "--name", "test_windows_backups_are_private_before_the_first_byte_is_written"
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

  def test_macos_safe_update_native_reload_wiring_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/subscriptions.rb",
        "    activate_safe_updated_profile(\n",
        "    activate_updated_profile(\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_default_safe_update_wires_the_client_native_reload_path"
      )
    end
  end

  def test_macos_native_reload_repeat_guard_mutation_is_killed
    with_repo_copy do |root|
      replace_once(
        root,
        "claude-easy/scripts/macos/patch_profiles/profile_writer.rb",
        "      return false if activation.fetch(key)\n",
        "      return false if false\n"
      )

      assert_mutation_is_killed(
        root,
        RbConfig.ruby, "tests/test_macos_patcher.rb",
        "--name", "test_profile_transaction_allows_each_native_reload_phase_once_per_client_process"
      )
    end
  end

end
