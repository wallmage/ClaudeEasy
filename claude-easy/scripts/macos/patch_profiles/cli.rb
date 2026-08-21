module ClaudeEasy
  module_function

  WRAPPER_COMMIT_RECEIPT_FAILURE_EXIT = 75
  PROFILE_COMMIT_STATE_UNCERTAIN_EXIT = 77
  class WrapperCommitReceiptError < StandardError; end

  def usage_profile_state_path
    File.expand_path("~/Library/Application Support/ClaudeEasy/usage-profile.plist")
  end

  def usage_profile_rejection(expected)
    saved = saved_usage_profile
    return ["usage_profile_unset", "尚未保存用途档位，未执行任何修改。", nil] unless saved
    return nil if saved == expected

    ["usage_profile_mismatch", "命令指定的用途档位与已保存档位不一致，未执行任何修改。", saved]
  rescue InvalidConfigError
    ["usage_profile_invalid", "已保存的用途档位状态无效，未执行任何修改。", nil]
  end

  def reject_unapproved_usage_profile(options, operation:, expected:)
    rejection = usage_profile_rejection(expected)
    return nil unless rejection

    code, summary, saved = rejection
    if options[:json]
      emit_cli_result(
        operation: operation, exit_code: 10, status: "invalid_request",
        code: code, summary_zh: summary, profile: saved
      )
    else
      warn summary
      10
    end
  end

  def internal_wrapper_operation?(backup_root)
    fixed_backup_root = File.join(File.dirname(usage_profile_state_path), "backups")
    return false unless File.expand_path(backup_root) == fixed_backup_root

    lock_path = File.join(fixed_backup_root, ".claude-easy-wrapper.lock")
    ClaudeEasyOperationLock.inherited_lock_held?(lock_path)
  end

  def valid_uninstall_recovery_profile?(path)
    expected = File.join(
      File.dirname(usage_profile_state_path),
      ".claude-easy-uninstall-staging", "usage"
    )
    expanded = File.expand_path(path.to_s)
    return false unless expanded == expected

    staging = File.dirname(expanded)
    %w[READY AUTO_UPDATE_WAS_OWNED].all? do |name|
      marker = File.join(staging, name)
      stat = File.lstat(marker)
      stat.file? && !stat.symlink? && stat.nlink == 1
    end && [1, 2, 3].include?(saved_usage_profile(path: expanded))
  rescue InvalidConfigError, SystemCallError, IOError
    false
  end

  def public_cli_entrypoint?
    File.expand_path($PROGRAM_NAME) == File.expand_path("../patch_profiles.rb", __dir__)
  end

  def cli_requires_outer_lock?(options)
    return false if options[:disable_subscription_auto_update] ||
                    options[:enable_subscription_auto_update] ||
                    options[:restore_owned_subscription_auto_update] ||
                    options[:list_backups] || options[:compare_backup]
    return true if options[:snapshot_initial] || options[:recover_profile_transaction] ||
                   options[:restore_backup] || options[:safe_update_all]

    !options[:dry_run]
  end

  def enter_outer_wrapper_lock(arguments, options)
    return nil unless public_cli_entrypoint? && cli_requires_outer_lock?(options)

    backup_root = File.join(File.dirname(usage_profile_state_path), "backups")
    lock_path = File.join(backup_root, ".claude-easy-wrapper.lock")
    if ENV["CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD"] == "1"
      return nil if internal_wrapper_operation?(backup_root)

      status = ClaudeEasyOperationLock::FAILED_EXIT
    else
      status = ClaudeEasyOperationLock.run([
        lock_path, RbConfig.ruby, File.expand_path("../patch_profiles.rb", __dir__), *arguments
      ])
    end
    code = status == ClaudeEasyOperationLock::BUSY_EXIT ?
      "operation_in_progress" : "operation_lock_failed"
    summary = status == ClaudeEasyOperationLock::BUSY_EXIT ?
      "另一个 ClaudeEasy 操作正在进行，请稍后重试。" : "无法建立 ClaudeEasy 操作锁；未执行任何修改。"
    return emit_cli_result(
      operation: "operation_lock", exit_code: status, status: "failed",
      code: code, summary_zh: summary
    ) if options[:json]

    warn summary
    status
  end

  def chinese_status(result)
    name = safe_label(File.basename(result[:path].to_s))
    case result[:status]
    when :updated
      "#{name}：#{updated_state(result)}#{ai_state(result)}"
    when :unchanged then "#{name}：无需修改"
    when :no_main_group then "#{name}：未修改：找不到可用的主代理组"
    when :no_ai_nodes then "#{name}：未修改：找不到可用的 AI 节点"
    when :validation_failed then "#{name}：已跳过：内核校验失败"
    when :validation_timeout then "#{name}：已跳过：订阅响应超时"
    when :non_idempotent then "#{name}：已跳过：二次转换不一致"
    when :invalid_policy then "#{name}：已跳过：策略版本无效"
    when :concurrent_change then "#{name}：已跳过：订阅正在刷新，稍后重试"
    when :io_error then "#{name}：已跳过：读取或写入失败"
    when :reload_failed_rolled_back then "#{name}：自动刷新失败，已恢复原配置"
    when :reload_failed_restore_pending then "#{name}：自动刷新失败；文件已恢复，运行内核恢复失败"
    when :reload_failed_rollback_conflict then "#{name}：自动刷新失败；订阅同时发生变化，未覆盖新内容"
    when :runtime_check_failed, :batch_aborted, :duplicate_target
      "#{name}：已跳过：处理失败"
    when :error then "#{name}：已跳过：处理失败"
    else "#{name}：已跳过：订阅内容无效"
    end
  end

  def ai_state(result)
    return "" if result[:ai_group].nil?

    return "；已创建独立 AI 分组，包含全部可用节点和代理提供者，节点由你选择" if result[:ai_group_created]
    return "；已升级 AI 分组为独立节点选择器，节点由你选择" if result[:ai_group_reset]

    "；已复用 AI 分组，只补全规则，节点未改"
  end

  def safe_label(value)
    text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
    text = text.gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
    text = text.gsub(/\e\[[0-?]*[ -\/]?[@-~]/, "")
    text = text.gsub(/[\p{Cc}\p{Cf}]/, "")
    text = text.gsub(/(?<![A-Za-z0-9])Bearer\s+\S+/i, "[已隐藏]")
    text = text.gsub(/(?<![A-Za-z0-9])(?:password|passwd|token|secret|uuid|private[-_ ]?key|controller[-_ ]?key)\s*[=:]\s*\S+/i, "[已隐藏]")
    text = text.gsub(/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/i, "[已隐藏]")
    text = text.gsub(%r{(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9+.-]*://\S+}, "[已隐藏]")
    text = text.gsub(/(?<![A-Za-z0-9])(?:localhost|\d{1,3}(?:\.\d{1,3}){3}|[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+):\d{1,5}(?![A-Za-z0-9])/, "[已隐藏]")
    text = text.gsub(/\\\\[^\\\s]+\\[^\s]+/, "[路径已隐藏]")
    text = text.gsub(%r{(?<![A-Za-z0-9])/(?:[^/\s]+/)+[^/\s]*}, "[路径已隐藏]")
    text = text.gsub(/(?<![A-Za-z0-9])[A-Za-z]:[\\\/](?:[^\\\/\s]+[\\\/])+[^\\\/\s]*/, "[路径已隐藏]")
    text = text.strip
    text = "未命名" if text.empty?
    text.each_char.take(120).join
  end

  def updated_state(result)
    return "将更新（演练，未写入文件）" if result[:dry_run]
    return "已更新，选择该订阅时生效" unless result[:active]
    return "已更新并自动生效" if result[:reloaded]

    "已更新，尚未自动刷新"
  end

  def emit_cli_result(operation:, exit_code:, status:, code:, summary_zh:, profile: nil,
                      changes: [], checks: [], items: [], messages: [], warnings: [],
                      workflow_complete: nil, completed_scope: nil, required_followups: nil)
    ClaudeEasyResult.emit(
      command: "patch", operation: operation, ok: exit_code.zero? && !%w[failed partial].include?(status),
      status: status, code: code, exit_code: exit_code, summary_zh: summary_zh, profile: profile,
      changes: changes, checks: checks, items: items, messages: messages, warnings: warnings,
      workflow_complete: workflow_complete, completed_scope: completed_scope,
      required_followups: required_followups
    )
    exit_code
  end

  def result_item(result)
    status = case result[:status]
             when :updated then "updated"
             when :unchanged then "unchanged"
             when :reload_failed_rolled_back then "rolled_back"
             when :no_main_group, :no_ai_nodes, :invalid, :validation_failed, :validation_timeout,
                  :non_idempotent, :invalid_policy, :concurrent_change, :io_error, :error
               "skipped"
             else "failed"
             end
    { "profile" => safe_label(File.basename(result[:path].to_s)), "status" => status }
  end

  def batch_json_status(results)
    return ["failed", "no_profiles", "没有找到可处理的配置。"] if results.empty?

    statuses = results.map { |result| result[:status] }
    failures = statuses - %i[updated unchanged]
    return ["no_change", "no_change", "所有配置都无需修改。"] if failures.empty? && statuses.all? { |status| status == :unchanged }
    return ["ok", "completed", "配置处理完成。"] if failures.empty?
    return ["partial", "partially_completed", "部分配置未能处理。"] if statuses.any? { |status| %i[updated unchanged].include?(status) }

    ["failed", "processing_failed", "配置处理失败。"]
  end

  def wrapper_commit_receipt_bytes(nonce, committed)
    "#{committed ? 1 : 0}:#{nonce}\n".b
  end

  def with_wrapper_commit_receipt(options)
    path = options[:wrapper_commit_receipt]
    nonce = options[:wrapper_commit_nonce]
    return if path.nil? && nonce.nil?
    raise InvalidConfigError, "wrapper commit receipt is incomplete" if path.nil? || nonce.nil?
    raise InvalidConfigError, "wrapper commit nonce is invalid" unless nonce.match?(/\A[0-9a-f]{32}\z/)
    raise InvalidConfigError, "wrapper commit receipt is outside backup directory" unless
      File.realpath(File.dirname(path)) == File.realpath(options[:backup_root])

    before = File.lstat(path)
    raise InvalidConfigError, "wrapper commit receipt is unsafe" unless
      before.file? && !before.symlink? && before.nlink == 1 && (before.mode & 0o077).zero?
    File.open(path, File::RDWR) do |io|
      opened = io.stat
      raise InvalidConfigError, "wrapper commit receipt changed" unless
        opened.dev == before.dev && opened.ino == before.ino &&
        io.read == wrapper_commit_receipt_bytes(nonce, false)
      yield io, nonce
    end
  end

  def validate_wrapper_commit_receipt(options)
    with_wrapper_commit_receipt(options) { |_io, _nonce| nil }
  end

  def mark_wrapper_commit_receipt(options)
    return if options[:wrapper_commit_receipt].nil? && options[:wrapper_commit_nonce].nil?

    with_wrapper_commit_receipt(options) do |io, nonce|
      committed = wrapper_commit_receipt_bytes(nonce, true)
      io.rewind
      io.write(committed)
      io.flush
      io.fsync
      io.rewind
      raise IOError, "wrapper commit receipt was not persisted" unless io.read == committed
    end
  rescue StandardError
    raise WrapperCommitReceiptError, "wrapper commit receipt publication failed"
  end

  def cli(argv = ARGV)
    original_arguments = argv.dup
    json_mode = argv.include?("--json")
    options = {
      profile_dirs: [],
      policy: File.expand_path("../../../references/policy.json", __dir__),
      backup_root: File.expand_path("~/Library/Application Support/ClaudeEasy/backups"),
      dry_run: false,
      auto_reload: true,
      print_tun_state: false,
      print_core_status: false,
      print_subscription_auto_update_state: false,
      print_auto_update_ownership_state: false,
      disable_subscription_auto_update: false,
      enable_subscription_auto_update: false,
      restore_owned_subscription_auto_update: false,
      snapshot_initial: false,
      list_backups: false,
      compare_backup: nil,
      restore_backup: nil,
      expected_current_sha256: nil,
      safe_update_all: false,
      reconcile_client_switches: false,
      recover_profile_transaction: false,
      repair_clashx_logs: false,
      usage_profile: nil,
      uninstall_recovery_state: nil,
      wrapper_commit_receipt: nil,
      wrapper_commit_nonce: nil,
      json: json_mode,
      help: false
    }
    parser = OptionParser.new do |opts|
      opts.banner = "用法：patch_profiles.rb [选项]"
      opts.on("--profile-dir PATH", "添加一个订阅目录，可重复使用") { |value| options[:profile_dirs] << File.expand_path(value) }
      opts.on("--policy PATH", "指定策略文件") { |value| options[:policy] = File.expand_path(value) }
      opts.on("--backup-dir PATH", "指定备份目录") { |value| options[:backup_root] = File.expand_path(value) }
      opts.on("--dry-run", "只预览，不写入文件") { options[:dry_run] = true }
      opts.on("--no-reload", "只更新文件，不自动刷新当前订阅") { options[:auto_reload] = false }
      opts.on("--print-tun-state", "输出当前运行内核的 TUN 状态") { options[:print_tun_state] = true }
      opts.on("--print-core-status", "检查 Mihomo 内核是否满足最低版本") { options[:print_core_status] = true }
      opts.on("--print-subscription-auto-update-state", "输出订阅自动更新状态") { options[:print_subscription_auto_update_state] = true }
      opts.on("--print-auto-update-ownership-state", "输出订阅自动更新所有权状态") { options[:print_auto_update_ownership_state] = true }
      opts.on("--disable-subscription-auto-update", "关闭订阅自动更新并回读确认") { options[:disable_subscription_auto_update] = true }
      opts.on("--enable-subscription-auto-update", "恢复订阅自动更新并回读确认") { options[:enable_subscription_auto_update] = true }
      opts.on("--restore-owned-subscription-auto-update", "只恢复本工具关闭的订阅自动更新") { options[:restore_owned_subscription_auto_update] = true }
      opts.on("--snapshot-initial", "为当前存储位置创建一次初始快照") { options[:snapshot_initial] = true }
      opts.on("--list-backups", "按时间倒序列出可用备份") { options[:list_backups] = true }
      opts.on("--compare-backup ID", "比较指定备份与当前配置") { |value| options[:compare_backup] = value }
      opts.on("--restore-backup ID", "恢复指定备份") { |value| options[:restore_backup] = value }
      opts.on("--expected-current-sha256 SHA256", "恢复前要求当前配置哈希匹配") { |value| options[:expected_current_sha256] = value }
      opts.on("--safe-update-all", "更新当前存储位置中的全部远程订阅") { options[:safe_update_all] = true }
      opts.on("--reconcile-client-switches", "按已保存档位协调 ClashX Meta 客户端开关") do
        options[:reconcile_client_switches] = true
      end
      opts.on("--recover-profile-transaction", "恢复未完成的配置事务及当前运行配置") { options[:recover_profile_transaction] = true }
      opts.on("--repair-clashx-logs", "修复 ClashX Meta 文件日志目录权限") { options[:repair_clashx_logs] = true }
      opts.on("--usage-profile N", Integer, "补丁采用的用途档位") { |value| options[:usage_profile] = value }
      opts.on("--internal-uninstall-recovery-state PATH") do |value|
        options[:uninstall_recovery_state] = File.expand_path(value)
      end
      opts.on("--wrapper-commit-receipt PATH") { |value| options[:wrapper_commit_receipt] = File.expand_path(value) }
      opts.on("--wrapper-commit-nonce VALUE") { |value| options[:wrapper_commit_nonce] = value }
      opts.on("--json", "输出 JSON v1 结果") { options[:json] = true }
      opts.on("-h", "--help", "显示帮助") do
        options[:help] = true
      end
    end
    parser.parse!(argv)
    validate_wrapper_commit_receipt(options)

    if options[:help]
      return emit_cli_result(
        operation: "help", exit_code: 0, status: "ok", code: "help", summary_zh: "已显示帮助。"
      ) if options[:json]
      puts parser
      return 0
    end

    explicit_operations = [
      options[:print_tun_state], options[:print_core_status],
      options[:print_subscription_auto_update_state], options[:print_auto_update_ownership_state],
      options[:disable_subscription_auto_update], options[:enable_subscription_auto_update],
      options[:restore_owned_subscription_auto_update], options[:snapshot_initial],
      options[:list_backups], options[:compare_backup], options[:restore_backup],
      options[:safe_update_all], options[:reconcile_client_switches],
      options[:recover_profile_transaction], options[:repair_clashx_logs]
    ].compact.reject { |value| value == false }
    incompatible_options = explicit_operations.length > 1 ||
                           (!explicit_operations.empty? &&
                            (options[:dry_run] || !options[:auto_reload]))
    if incompatible_options
      return emit_cli_result(
        operation: "options", exit_code: 64, status: "invalid_request",
        code: "incompatible_options", summary_zh: "命令选项不能组合；未执行任何修改。"
      ) if options[:json]
      warn "命令选项不能组合；未执行任何修改。"
      return 64
    end

    if options[:print_core_status]
      status = mihomo_core_status
      exit_code = status == :supported ? 0 : 1
      return emit_cli_result(
        operation: "core_status", exit_code: exit_code,
        status: status == :supported ? "ok" : "unsupported", code: "core_#{status}",
        summary_zh: status == :supported ? "Mihomo 内核版本受支持。" : "Mihomo 内核不可用或版本不受支持。",
        checks: [{ "name" => "mihomo_core", "ok" => status == :supported, "status" => status.to_s }]
      ) if options[:json]
      puts status
      return exit_code
    end

    if options[:print_tun_state]
      state = tun_state
      return emit_cli_result(
        operation: "tun_state", exit_code: 0, status: "ok", code: "tun_#{state}",
        summary_zh: "已读取 TUN 运行状态。", checks: [{ "name" => "tun", "status" => state.to_s }]
      ) if options[:json]
      puts state
      return 0
    end

    if options[:print_subscription_auto_update_state]
      state = subscription_auto_update_state
      return emit_cli_result(
        operation: "subscription_auto_update_state", exit_code: 0, status: "ok", code: "auto_update_#{state}",
        summary_zh: "已读取订阅自动更新状态。", checks: [{ "name" => "subscription_auto_update", "status" => state.to_s }]
      ) if options[:json]
      puts state
      return 0
    end

    if options[:print_auto_update_ownership_state]
      begin
        state = auto_update_ownership_state(options[:backup_root]) ? :owned : :not_owned
        return emit_cli_result(
          operation: "auto_update_ownership_state", exit_code: 0, status: "ok",
          code: state.to_s, summary_zh: "已读取订阅自动更新所有权状态。",
          checks: [{ "name" => "auto_update_ownership", "status" => state.to_s }]
        ) if options[:json]
        puts state
        return 0
      rescue InvalidConfigError, SystemCallError, IOError => error
        return emit_cli_result(
          operation: "auto_update_ownership_state", exit_code: 1, status: "failed",
          code: "auto_update_state_invalid", summary_zh: "无法读取订阅自动更新所有权状态。"
        ) if options[:json]
        warn safe_label(error.message)
        return 1
      end
    end

    if options[:restore_backup] &&
       !options[:expected_current_sha256].to_s.match?(/\A[0-9a-f]{64}\z/i)
      return emit_cli_result(
        operation: "restore_backup", exit_code: 64, status: "invalid_request",
        code: "expected_current_sha256_required",
        summary_zh: "恢复备份必须提供比较时取得的当前配置 SHA-256。"
      ) if options[:json]
      warn "恢复备份必须提供比较时取得的当前配置 SHA-256。"
      return 64
    end

    lock_status = enter_outer_wrapper_lock(original_arguments, options)
    return lock_status if lock_status

    if options[:reconcile_client_switches]
      unless [1, 2, 3].include?(options[:usage_profile])
        return emit_cli_result(
          operation: "reconcile_client_switches", exit_code: 64,
          status: "invalid_request", code: "usage_profile_required",
          summary_zh: "协调客户端开关必须指定用途档位 1、2 或 3。"
        ) if options[:json]
        warn "协调客户端开关必须指定用途档位 1、2 或 3。"
        return 64
      end
      if (rejected = reject_unapproved_usage_profile(
        options, operation: "reconcile_client_switches", expected: options[:usage_profile]
      ))
        return rejected
      end

      result = reconcile_clashx_client_switches(usage_profile: options[:usage_profile])
      if result.fetch(:status) == :reconciled
        return emit_cli_result(
          operation: "reconcile_client_switches", exit_code: 0, status: "ok",
          code: "client_switches_reconciled", summary_zh: "ClashX Meta 客户端开关已经自动协调并验收。",
          profile: options[:usage_profile], changes: result.fetch(:changes),
          checks: result.fetch(:checks)
        ) if options[:json]
        puts "ClashX Meta 客户端开关已经自动协调并验收。"
        return 0
      end
      if result.fetch(:status) == :unchanged
        return emit_cli_result(
          operation: "reconcile_client_switches", exit_code: 0, status: "no_change",
          code: "client_switches_already_correct", summary_zh: "ClashX Meta 客户端开关已经符合当前档位。",
          profile: options[:usage_profile], checks: result.fetch(:checks)
        ) if options[:json]
        puts "ClashX Meta 客户端开关已经符合当前档位。"
        return 0
      end

      reason = result.fetch(:reason).to_s
      message = if result.fetch(:reason) == :third_party_proxy_active
                  "检测到第三方 PAC、自动发现或其他代理，未改动系统代理；请先决定是否保留该代理，不要直接覆盖。"
                elsif options[:usage_profile] == 1
                  "请点击菜单栏 ClashX Meta 图标，确认“设置为系统代理”已勾选；只有未勾选时才点击一次。完成后回复“已完成”。"
                else
                  "请点击菜单栏 ClashX Meta 图标，确认“TUN 模式”已勾选，只有未勾选时才点击一次；再确认“设置为系统代理”未勾选，只有已勾选时才点击一次。完成后回复“已完成”。"
                end
      return emit_cli_result(
        operation: "reconcile_client_switches", exit_code: 1, status: "failed",
        code: "client_switch_manual_required", summary_zh: "无法安全自动完成 ClashX Meta 客户端开关。",
        profile: options[:usage_profile], changes: result.fetch(:changes),
        checks: result.fetch(:checks), messages: [message], warnings: [reason]
      ) if options[:json]
      warn message
      return 1
    end

    if options[:repair_clashx_logs]
      begin
        result = repair_clashx_logs
        changed = result.fetch(:status) == :repaired
        runtime_verified = verify_clashx_file_logging
        unless runtime_verified
          summary = changed ?
            "ClashX Meta 日志目录权限已修复，但未确认文件日志已经恢复；请继续使用控制器实时日志。" :
            "未确认 ClashX Meta 文件日志已经恢复；请继续使用控制器实时日志。"
          return emit_cli_result(
            operation: "repair_clashx_logs", exit_code: 1,
            status: changed ? "partial" : "failed", code: "log_runtime_unverified",
            summary_zh: summary,
            changes: changed ? ["log_directory_permissions"] : [],
            checks: [
              { "name" => "log_directory_writable", "ok" => true },
              { "name" => "file_logging_runtime", "ok" => false }
            ]
          ) if options[:json]
          warn summary
          return 1
        end
        return emit_cli_result(
          operation: "repair_clashx_logs", exit_code: 0,
          status: changed ? "ok" : "no_change",
          code: changed ? "logs_repaired" : "logs_already_writable",
          summary_zh: changed ? "ClashX Meta 文件日志已恢复写入。" : "ClashX Meta 文件日志目录可以正常写入。",
          changes: changed ? ["clashx_file_logging"] : [],
          checks: [
            { "name" => "log_directory_writable", "ok" => true },
            { "name" => "file_logging_runtime", "ok" => true },
            { "name" => "old_logs_preserved", "ok" => true,
              "value" => result.fetch(:backup_preserved) }
          ]
        ) if options[:json]
        puts(changed ? "ClashX Meta 文件日志已恢复写入。" : "ClashX Meta 文件日志目录可以正常写入。")
        return 0
      rescue UnsafeLogPathError
        return emit_cli_result(
          operation: "repair_clashx_logs", exit_code: 1, status: "failed",
          code: "unsafe_log_path", summary_zh: "ClashX Meta 日志路径不安全，未执行修改。"
        ) if options[:json]
        warn "ClashX Meta 日志路径不安全，未执行修改。"
        return 1
      rescue LogRepairPartialError
        return emit_cli_result(
          operation: "repair_clashx_logs", exit_code: 1, status: "partial",
          code: "log_repair_partial", summary_zh: "ClashX Meta 文件日志修复只完成了一部分；旧日志已保留。",
          changes: ["log_directory_permissions"]
        ) if options[:json]
        warn "ClashX Meta 文件日志修复只完成了一部分；旧日志已保留。"
        return 1
      rescue LogRepairError
        return emit_cli_result(
          operation: "repair_clashx_logs", exit_code: 1, status: "failed",
          code: "log_repair_failed", summary_zh: "ClashX Meta 文件日志修复失败。"
        ) if options[:json]
        warn "ClashX Meta 文件日志修复失败。"
        return 1
      end
    end

    if options[:disable_subscription_auto_update]
      unless internal_wrapper_operation?(options[:backup_root])
        return emit_cli_result(
          operation: "disable_subscription_auto_update", exit_code: 64,
          status: "invalid_request", code: "internal_operation_required",
          summary_zh: "订阅自动更新只能由安装或恢复流程修改。"
        ) if options[:json]
        warn "订阅自动更新只能由安装或恢复流程修改。"
        return 64
      end
      unless [1, 2, 3].include?(options[:usage_profile])
        return emit_cli_result(
          operation: "disable_subscription_auto_update", exit_code: 64,
          status: "invalid_request", code: "usage_profile_required",
          summary_zh: "关闭订阅自动更新必须显式指定用途档位。"
        ) if options[:json]
        warn "关闭订阅自动更新必须显式指定用途档位。"
        return 64
      end
      if options[:uninstall_recovery_state]
        unless valid_uninstall_recovery_profile?(options[:uninstall_recovery_state])
          return emit_cli_result(
            operation: "disable_subscription_auto_update", exit_code: 10,
            status: "invalid_request", code: "uninstall_recovery_state_invalid",
            summary_zh: "安全卸载恢复凭据无效，未修改订阅自动更新。"
          ) if options[:json]
          warn "安全卸载恢复凭据无效，未修改订阅自动更新。"
          return 10
        end
      elsif (rejected = reject_unapproved_usage_profile(
        options, operation: "disable_subscription_auto_update",
        expected: options[:usage_profile]
      ))
        return rejected
      end
      begin
        result = disable_subscription_auto_update(backup_root: options[:backup_root])
        unchanged = [:already_disabled, :already_disabled_owned].include?(result.fetch(:status))
        return emit_cli_result(
          operation: "disable_subscription_auto_update", exit_code: 0,
          status: unchanged ? "no_change" : "ok",
          code: result.fetch(:status).to_s,
          summary_zh: unchanged ? "订阅自动更新已经关闭。" : "已关闭订阅自动更新。",
          changes: unchanged ? [] : ["subscription_auto_update"]
        ) if options[:json]
        puts result.fetch(:status)
        return 0
      rescue InvalidConfigError, SystemCallError, IOError => error
        return emit_cli_result(
          operation: "disable_subscription_auto_update", exit_code: 1, status: "failed",
          code: "auto_update_failed", summary_zh: "无法关闭订阅自动更新。"
        ) if options[:json]
        warn safe_label(error.message)
        return 1
      end
    end

    if options[:enable_subscription_auto_update]
      return emit_cli_result(
        operation: "enable_subscription_auto_update", exit_code: 64,
        status: "invalid_request", code: "internal_operation_required",
        summary_zh: "订阅自动更新只能按本工具的所有权记录恢复。"
      ) if options[:json]
      warn "订阅自动更新只能按本工具的所有权记录恢复。"
      return 64
    end

    if options[:restore_owned_subscription_auto_update]
      unless internal_wrapper_operation?(options[:backup_root])
        return emit_cli_result(
          operation: "restore_owned_subscription_auto_update", exit_code: 64,
          status: "invalid_request", code: "internal_operation_required",
          summary_zh: "订阅自动更新只能由安装、卸载或恢复流程修改。"
        ) if options[:json]
        warn "订阅自动更新只能由安装、卸载或恢复流程修改。"
        return 64
      end
      begin
        result = restore_owned_subscription_auto_update(backup_root: options[:backup_root])
        changed = result.fetch(:status) == :restored
        return emit_cli_result(
          operation: "restore_owned_subscription_auto_update", exit_code: 0,
          status: changed ? "ok" : "no_change", code: result.fetch(:status).to_s,
          summary_zh: changed ? "已恢复本工具关闭的订阅自动更新。" : "订阅自动更新无需恢复。",
          changes: changed ? ["subscription_auto_update"] : []
        ) if options[:json]
        puts result.fetch(:status)
        return 0
      rescue InvalidConfigError, SystemCallError, IOError => error
        return emit_cli_result(
          operation: "restore_owned_subscription_auto_update", exit_code: 1, status: "failed",
          code: "auto_update_restore_failed", summary_zh: "无法安全恢复订阅自动更新。"
        ) if options[:json]
        warn safe_label(error.message)
        return 1
      end
    end

    if options[:list_backups]
      backups = list_backups(options[:backup_root])
      return emit_cli_result(
        operation: "list_backups", exit_code: 0, status: backups.empty? ? "no_change" : "ok",
        code: backups.empty? ? "no_backups" : "backups_listed",
        summary_zh: backups.empty? ? "没有可用备份。" : "已读取可用备份。",
        checks: [{ "name" => "backup_count", "value" => backups.length }], items: backups
      ) if options[:json]
      backups.each { |item| puts "#{item.fetch('created_at')}\t#{item.fetch('id')}" }
      puts(backups.empty? ? "没有可用备份。" : "已读取可用备份。")
      return 0
    end

    guard_storage = options[:profile_dirs].empty?
    expected_storage = storage_mode if guard_storage
    directories = guard_storage ? default_profile_directories : options[:profile_dirs]
    if options[:recover_profile_transaction]
      result = recover_pending_profile_transaction(
        options[:backup_root], directories: directories,
        guard_storage: guard_storage, expected_storage: expected_storage
      )
      if result == :profile_directory_missing
        return emit_cli_result(
          operation: "recover_profile_transaction", exit_code: 2, status: "failed",
          code: "profile_directory_missing", summary_zh: "没有找到 ClashX Meta 配置目录。"
        ) if options[:json]
        warn "没有找到 ClashX Meta 配置目录。"
        return 2
      end
      if result == :runtime_restore_pending
        return emit_cli_result(
          operation: "recover_profile_transaction", exit_code: 1, status: "partial",
          code: "profile_transaction_runtime_pending",
          summary_zh: "配置文件已恢复，但当前运行配置未能恢复。"
        ) if options[:json]
        warn "配置文件已恢复，但当前运行配置未能恢复。"
        return 1
      end
      return emit_cli_result(
        operation: "recover_profile_transaction", exit_code: 0,
        status: result == :recovered ? "ok" : "no_change",
        code: result == :recovered ? "profile_transaction_recovered" : "no_pending_transaction",
        summary_zh: result == :recovered ? "未完成的配置事务已恢复。" : "没有未完成的配置事务。",
        changes: result == :recovered ? ["profiles", "runtime_config"] : []
      ) if options[:json]
      puts result
      return 0
    end

    if directories.empty?
      return emit_cli_result(
        operation: "patch_profiles", exit_code: 2, status: "failed", code: "profile_directory_missing",
        summary_zh: "没有找到 ClashX Meta 配置目录。"
      ) if options[:json]
      warn "没有找到 ClashX Meta 配置目录。"
      return 2
    end

    if options[:snapshot_initial]
      snapshots = snapshot_initial_profiles(directories, options[:backup_root])
      return emit_cli_result(
        operation: "snapshot_initial", exit_code: 0, status: snapshots.empty? ? "no_change" : "ok",
        code: snapshots.empty? ? "snapshot_exists" : "snapshot_created", summary_zh: "初始快照处理完成。",
        changes: snapshots.empty? ? [] : ["initial_snapshot"]
      ) if options[:json]
      snapshots.each { |path| puts public_backup_id(File.basename(path)) }
      return 0
    end

    if options[:compare_backup]
      comparison = compare_backup(options[:compare_backup], directories: directories, backup_root: options[:backup_root])
      return emit_cli_result(
        operation: "compare_backup", exit_code: 0, status: comparison.fetch(:same) ? "no_change" : "ok",
        code: comparison.fetch(:same) ? "backup_matches" : "backup_differs", summary_zh: "备份比较完成。",
        changes: comparison.fetch(:changes),
        items: [{
          "id" => comparison.fetch(:backup_id), "same" => comparison.fetch(:same),
          "backup_sha256" => comparison.fetch(:backup_sha256),
          "current_sha256" => comparison.fetch(:current_sha256)
        }]
      ) if options[:json]
      puts JSON.generate(ClaudeEasyResult.sanitize(comparison))
      puts "备份比较完成。"
      return 0
    end

    if options[:restore_backup]
      begin
        restore_usage_profile = saved_usage_profile
        profile_rejection = unless restore_usage_profile
                              ["usage_profile_unset", "尚未保存用途档位，未恢复备份。"]
                            end
      rescue InvalidConfigError
        profile_rejection = ["usage_profile_invalid", "已保存的用途档位状态无效，未恢复备份。"]
      end
      if profile_rejection
        code, summary = profile_rejection
        return emit_cli_result(
          operation: "restore_backup", exit_code: 10, status: "invalid_request",
          code: code, summary_zh: summary
        ) if options[:json]
        warn summary
        return 10
      end
      runtime_context = capture_runtime_profile_context(
        directories, guard_storage: guard_storage,
        expected_storage: expected_storage
      )
      unless runtime_context
        return emit_cli_result(
          operation: "restore_backup", exit_code: 1, status: "failed",
          code: "client_state_changed",
          summary_zh: "当前订阅或存储位置正在变化，未恢复备份。"
        ) if options[:json]
        warn "当前订阅或存储位置正在变化，未恢复备份。"
        return 1
      end
      selected = runtime_context.fetch(:selected)
      precommit_condition = lambda do
        runtime_profile_context_current?(
          runtime_context, directories, guard_storage: guard_storage
        )
      end
      runtime_checkpoint = nil
      runtime_checkpoint_provider = lambda do |target|
        active = runtime_context[:active_path] &&
                 File.realpath(target) == runtime_context.fetch(:active_path)
        next nil unless active

        runtime_checkpoint = capture_runtime_checkpoint(target, require_tun: :preserve)
        runtime_checkpoint || false
      end
      activation = lambda do |restore_result|
        if restore_result[:status] != :no_change &&
           !runtime_precommit_allowed?(precommit_condition)
          status = if restore_profile_bytes(restore_result)
                     :reload_failed_rolled_back
                   else
                     :reload_failed_rollback_conflict
                   end
          next restore_result.merge(status: status)
        end
        active = runtime_context[:active_path] &&
                 File.realpath(restore_result.fetch(:path)) == runtime_context.fetch(:active_path)
        restore_result = restore_result.merge(active: !!active)
        if active
          activate_updated_profile(
            restore_result, require_tun: :preserve,
            precommit_condition: precommit_condition,
            require_safe_ai: restore_usage_profile == 3,
            runtime_checkpoint: runtime_checkpoint
          )
        else
          restore_result
        end
      end
      restore_policy = JSON.parse(File.read(options[:policy], encoding: "UTF-8"))
      result = restore_backup(
        options[:restore_backup], directories: directories, backup_root: options[:backup_root],
        expected_current_sha256: options[:expected_current_sha256],
        validator: ->(path) {
          restore_candidate_valid?(path, restore_usage_profile, policy: restore_policy)
        },
        selected_name: selected, activation: activation,
        precommit_condition: precommit_condition,
        runtime_checkpoint_provider: runtime_checkpoint_provider
      )

      status, code, summary = case result[:status]
                              when :updated
                                ["ok", "updated", result[:active] ? "备份已恢复并通过运行检查。" : "备份已恢复。"]
                              when :no_change
                                summary = result[:reloaded] ? "当前配置已经与备份一致，并通过运行检查。" : "当前配置已经与备份一致。"
                                ["no_change", "no_change", summary]
                              when :reload_failed_rolled_back
                                ["rolled_back", "restore_runtime_check_failed", "备份未能通过运行检查，已恢复回滚前版本。"]
                              when :reload_failed_restore_pending
                                ["partial", "restore_runtime_pending", "备份未能通过运行检查；文件已恢复回滚前版本，但运行内核恢复失败。"]
                              when :reload_failed_rollback_conflict
                                ["partial", "restore_rollback_conflict", "备份未能通过运行检查，且订阅同时发生变化；未覆盖新内容。"]
                              when :runtime_state_unavailable
                                ["failed", "client_state_changed", "无法确认更新前的运行状态，未恢复备份。"]
                              else
                                ["failed", result[:status].to_s, "备份恢复失败。"]
                              end
      exit_code = %w[ok no_change].include?(status) ? 0 : 1
      return emit_cli_result(
        operation: "restore_backup", exit_code: exit_code,
        status: status, code: code, summary_zh: summary,
        changes: result[:status] == :updated ? ["profile_restored"] : []
      ) if options[:json]
      public_result = result.reject { |key, _value| key == :rollback_bytes }
      puts JSON.generate(ClaudeEasyResult.sanitize(public_result))
      puts summary
      return exit_code
    end

    if options[:safe_update_all]
      unless [1, 2, 3].include?(options[:usage_profile])
        return emit_cli_result(
          operation: "safe_update", exit_code: 64, status: "invalid_request", code: "usage_profile_required",
          summary_zh: "更新订阅必须指定用途档位 1、2 或 3。"
        ) if options[:json]
        warn "更新订阅必须指定用途档位 1、2 或 3。"
        return 64
      end
      if (rejected = reject_unapproved_usage_profile(
        options, operation: "safe_update", expected: options[:usage_profile]
      ))
        return rejected
      end
      policy = JSON.parse(File.read(options[:policy], encoding: "UTF-8"))
      targets = remote_subscription_targets(directories)
      result = safe_update_all(
        targets: targets, policy: policy, backup_root: options[:backup_root],
        usage_profile: options[:usage_profile], guard_storage: guard_storage,
        expected_storage: expected_storage,
        auto_update_disabler: lambda do |operation_lock|
          disable_subscription_auto_update(
            backup_root: options[:backup_root], operation_lock: operation_lock
          )
        end
      )
      if result[:status] == :updated
        mark_wrapper_commit_receipt(options)
        required_followups = case options[:usage_profile]
                             when 1
                               %w[macos_client_switch_reconciliation site_verification final_state_audit]
                             when 2
                               %w[
                                 macos_client_switch_reconciliation site_verification
                                 agent_connectivity_verification final_state_audit
                               ]
                             else
                               %w[
                                 macos_client_switch_reconciliation site_verification
                                 agent_connectivity_verification
                                 route_verification dns_deep_test webrtc_test_1 webrtc_test_2
                                 region_fingerprint_test final_state_audit
                               ]
                             end
        return emit_cli_result(
          operation: "safe_update", exit_code: 0, status: "ok", code: "safe_update_completed",
          summary_zh: "订阅、补丁和内部运行检查已完成；当前档位的后续验收尚未完成。",
          profile: options[:usage_profile],
          changes: ["remote_subscriptions"],
          checks: [{ "name" => "updated_count", "value" => result.fetch(:count) }],
          items: result.fetch(:profiles).map do |name|
            {
              "id" => "ce-subscription-v1-#{Digest::SHA256.hexdigest(name.to_s)}",
              "label" => safe_label(name), "status" => "updated"
            }
          end,
          workflow_complete: false, completed_scope: "subscription_update",
          required_followups: required_followups
        ) if options[:json]
        puts "全部远程订阅已更新：#{result.fetch(:count)} 份。"
        result.fetch(:profiles).each { |name| puts "已更新：#{safe_label(name)}" }
        return 0
      end
      status, code, summary = case result[:status]
                              when :rollback_failed
                                ["partial", "rollback_failed", "订阅更新失败，且原文件或运行状态未能完整恢复。"]
                              when :runtime_restore_pending
                                ["partial", "safe_update_runtime_pending", "订阅文件已保留新内容，但运行内核仍待恢复或确认。"]
                              when :aborted
                                if result[:reason] == :rollback_superseded
                                  ["partial", "safe_update_rollback_superseded", "订阅在回滚前已被外部更新；已保留较新的内容，未覆盖。"]
                                else
                                  ["failed", "safe_update_failed", "订阅更新失败。"]
                                end
                              else
                                ["failed", "safe_update_failed", "订阅更新失败。"]
                              end
      return emit_cli_result(
        operation: "safe_update", exit_code: 1, status: status, code: code,
        summary_zh: summary, profile: options[:usage_profile]
      ) if options[:json]
      warn summary
      return 1
    end

    unless [1, 2, 3].include?(options[:usage_profile])
      return emit_cli_result(
        operation: options[:dry_run] ? "preview_profiles" : "patch_profiles",
        exit_code: 64, status: "invalid_request", code: "usage_profile_required",
        summary_zh: "处理配置必须显式指定用途档位。"
      ) if options[:json]
      warn "处理配置必须显式指定用途档位。"
      return 64
    end
    unless options[:dry_run]
      if (rejected = reject_unapproved_usage_profile(
        options, operation: "patch_profiles", expected: options[:usage_profile]
      ))
        return rejected
      end
    end

    results = run(
      directories: directories,
      policy_path: options[:policy],
      dry_run: options[:dry_run],
      backup_root: options[:backup_root],
      validator: options[:dry_run] ? nil : method(:validate_with_mihomo),
      auto_reload: options[:auto_reload] && !options[:dry_run],
      usage_profile: options[:usage_profile],
      guard_storage: guard_storage, expected_storage: expected_storage
    )
    if results.empty?
      return emit_cli_result(
        operation: options[:dry_run] ? "preview_profiles" : "patch_profiles", exit_code: 1,
        status: "failed", code: "no_profiles", summary_zh: "没有找到可处理的配置。"
      ) if options[:json]
      warn "没有找到可处理的配置。"
      return 1
    end
    operation_succeeded = results.all? { |result| %i[updated unchanged].include?(result[:status]) }
    mark_wrapper_commit_receipt(options) if operation_succeeded
    if options[:json]
      status, code, summary = batch_json_status(results)
      exit_code = %w[ok no_change].include?(status) ? 0 : 1
      return emit_cli_result(
        operation: options[:dry_run] ? "preview_profiles" : "patch_profiles", exit_code: exit_code,
        status: status, code: code, summary_zh: summary,
        changes: results.any? { |result| result[:status] == :updated } ? ["profiles"] : [],
        items: results.map { |result| result_item(result) }
      )
    end
    results.each { |result| puts chinese_status(result) }
    operation_succeeded ? 0 : 1
  rescue OptionParser::ParseError => error
    return emit_cli_result(
      operation: "parse_arguments", exit_code: 64, status: "invalid_request", code: "invalid_arguments",
      summary_zh: "参数错误。"
    ) if json_mode
    warn "参数错误：#{safe_label(error.message)}"
    warn parser
    64
  rescue Errno::ENOENT
    return emit_cli_result(
      operation: "patch_profiles", exit_code: 1, status: "failed", code: "required_file_missing",
      summary_zh: "ClaudeEasy 运行失败：找不到所需文件。"
    ) if json_mode
    warn "ClaudeEasy 运行失败：找不到所需文件。"
    1
  rescue JSON::ParserError
    return emit_cli_result(
      operation: "patch_profiles", exit_code: 1, status: "failed", code: "invalid_policy_json",
      summary_zh: "ClaudeEasy 运行失败：策略文件不是有效的 JSON。"
    ) if json_mode
    warn "ClaudeEasy 运行失败：策略文件不是有效的 JSON。"
    1
  rescue InvalidConfigError => error
    return emit_cli_result(
      operation: options[:safe_update_all] ? "safe_update" : "patch_profiles",
      exit_code: 1, status: "failed", code: "invalid_configuration",
      summary_zh: "ClaudeEasy 运行失败。"
    ) if json_mode
    warn "ClaudeEasy 运行失败：#{safe_label(error.message)}。"
    1
  rescue WrapperCommitReceiptError
    begin
      if json_mode
        emit_cli_result(
          operation: options[:safe_update_all] ? "safe_update" : "patch_profiles",
          exit_code: WRAPPER_COMMIT_RECEIPT_FAILURE_EXIT,
          status: "partial", code: "wrapper_commit_receipt_failed",
          summary_zh: "配置已经提交，但提交收据写入失败。",
          profile: options[:usage_profile]
        )
      else
        warn "配置已经提交，但提交收据写入失败。"
      end
    rescue StandardError
      nil
    end
    WRAPPER_COMMIT_RECEIPT_FAILURE_EXIT
  rescue ProfileCommitStateUncertainError
    operation = if options[:restore_backup]
                  "restore_backup"
                elsif options[:safe_update_all]
                  "safe_update"
                else
                  "patch_profiles"
                end
    return emit_cli_result(
      operation: operation,
      exit_code: PROFILE_COMMIT_STATE_UNCERTAIN_EXIT,
      status: "partial", code: "profile_commit_state_uncertain",
      summary_zh: "配置提交状态无法确认；必须保留当前档位并在下次运行时恢复。",
      profile: options[:usage_profile]
    ) if json_mode
    warn "配置提交状态无法确认；必须保留当前档位并在下次运行时恢复。"
    PROFILE_COMMIT_STATE_UNCERTAIN_EXIT
  rescue StandardError => error
    return emit_cli_result(
      operation: "patch_profiles", exit_code: 1, status: "failed", code: "unexpected_error",
      summary_zh: "ClaudeEasy 运行失败。"
    ) if json_mode
    warn "ClaudeEasy 运行失败：#{safe_label(error.message)}（#{error.class}）"
    1
  end
end
