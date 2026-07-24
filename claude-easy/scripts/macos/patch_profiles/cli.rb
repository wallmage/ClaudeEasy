module ClaudeEasy
  module_function

  WRAPPER_COMMIT_RECEIPT_FAILURE_EXIT = 75
  class WrapperCommitReceiptError < StandardError; end

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
    when :error then "#{name}：已跳过：处理失败"
    else "#{name}：已跳过：订阅内容无效"
    end
  end

  def ai_state(result)
    return "" if result[:ai_group].nil?

    ai_group = safe_label(result[:ai_group])
    return "；已创建独立 AI 分组「#{ai_group}」，包含全部可用节点和代理提供者，节点由你选择" if result[:ai_group_created]
    return "；已升级 AI 分组「#{ai_group}」为独立节点选择器，节点由你选择" if result[:ai_group_reset]

    "；已复用 AI 分组「#{ai_group}」，只补全规则，节点未改"
  end

  def safe_label(value)
    text = value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
    text = text.gsub(/\e\][^\a]*(?:\a|\e\\)/, "")
    text = text.gsub(/\e\[[0-?]*[ -\/]?[@-~]/, "")
    text = text.gsub(/[\p{Cc}\p{Cf}]/, "")
    text = text.gsub(/\b(?:password|passwd|token|secret|uuid)\s*[=:]\s*\S+/i, "[已隐藏]")
    text = text.gsub(/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i, "[已隐藏]")
    text = text.gsub(%r{\b[A-Za-z][A-Za-z0-9+.-]*://\S+}, "[已隐藏]")
    text = text.gsub(%r{(?<![A-Za-z0-9])/(?:[^/\s]+/)+[^/\s]*}, "[路径已隐藏]")
    text = text.gsub(/\b[A-Za-z]:[\\\/](?:[^\\\/\s]+[\\\/])+[^\\\/\s]*/, "[路径已隐藏]")
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
                      changes: [], checks: [], items: [], messages: [], warnings: [])
    ClaudeEasyResult.emit(
      command: "patch", operation: operation, ok: exit_code.zero? && !%w[failed partial].include?(status),
      status: status, code: code, exit_code: exit_code, summary_zh: summary_zh, profile: profile,
      changes: changes, checks: checks, items: items, messages: messages, warnings: warnings
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
      disable_subscription_auto_update: false,
      enable_subscription_auto_update: false,
      restore_owned_subscription_auto_update: false,
      snapshot_initial: false,
      list_backups: false,
      compare_backup: nil,
      restore_backup: nil,
      expected_current_sha256: nil,
      safe_update_all: false,
      recover_profile_transaction: false,
      usage_profile: nil,
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
      opts.on("--disable-subscription-auto-update", "关闭订阅自动更新并回读确认") { options[:disable_subscription_auto_update] = true }
      opts.on("--enable-subscription-auto-update", "恢复订阅自动更新并回读确认") { options[:enable_subscription_auto_update] = true }
      opts.on("--restore-owned-subscription-auto-update", "只恢复本工具关闭的订阅自动更新") { options[:restore_owned_subscription_auto_update] = true }
      opts.on("--snapshot-initial", "为当前存储位置创建一次初始快照") { options[:snapshot_initial] = true }
      opts.on("--list-backups", "按时间倒序列出可用备份") { options[:list_backups] = true }
      opts.on("--compare-backup ID", "比较指定备份与当前配置") { |value| options[:compare_backup] = value }
      opts.on("--restore-backup ID", "恢复指定备份") { |value| options[:restore_backup] = value }
      opts.on("--expected-current-sha256 SHA256", "恢复前要求当前配置哈希匹配") { |value| options[:expected_current_sha256] = value }
      opts.on("--safe-update-all", "安全更新当前存储位置中的全部远程订阅") { options[:safe_update_all] = true }
      opts.on("--recover-profile-transaction", "恢复未完成的配置事务及当前运行配置") { options[:recover_profile_transaction] = true }
      opts.on("--usage-profile N", Integer, "补丁与安全更新采用的用途档位") { |value| options[:usage_profile] = value }
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

    if options[:disable_subscription_auto_update]
      begin
        result = disable_subscription_auto_update(backup_root: options[:backup_root])
        return emit_cli_result(
          operation: "disable_subscription_auto_update", exit_code: 0,
          status: result.fetch(:status) == :already_disabled ? "no_change" : "ok",
          code: result.fetch(:status).to_s,
          summary_zh: result.fetch(:status) == :already_disabled ? "订阅自动更新已经关闭。" : "已关闭订阅自动更新。",
          changes: result.fetch(:status) == :already_disabled ? [] : ["subscription_auto_update"]
        ) if options[:json]
        puts result.fetch(:status)
        return 0
      rescue InvalidConfigError, SystemCallError, IOError => error
        return emit_cli_result(
          operation: "disable_subscription_auto_update", exit_code: 1, status: "failed",
          code: "auto_update_failed", summary_zh: "无法关闭订阅自动更新。"
        ) if options[:json]
        warn error.message
        return 1
      end
    end

    if options[:enable_subscription_auto_update]
      begin
        result = enable_subscription_auto_update
        return emit_cli_result(
          operation: "enable_subscription_auto_update", exit_code: 0,
          status: result.fetch(:status) == :already_enabled ? "no_change" : "ok",
          code: result.fetch(:status).to_s,
          summary_zh: result.fetch(:status) == :already_enabled ? "订阅自动更新已经开启。" : "已恢复订阅自动更新。",
          changes: result.fetch(:status) == :already_enabled ? [] : ["subscription_auto_update"]
        ) if options[:json]
        puts result.fetch(:status)
        return 0
      rescue InvalidConfigError, SystemCallError, IOError => error
        return emit_cli_result(
          operation: "enable_subscription_auto_update", exit_code: 1, status: "failed",
          code: "auto_update_restore_failed", summary_zh: "无法恢复订阅自动更新。"
        ) if options[:json]
        warn error.message
        return 1
      end
    end

    if options[:restore_owned_subscription_auto_update]
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
        warn error.message
        return 1
      end
    end

    if options[:list_backups]
      backups = list_backups(options[:backup_root])
      return emit_cli_result(
        operation: "list_backups", exit_code: 0, status: backups.empty? ? "no_change" : "ok",
        code: backups.empty? ? "no_backups" : "backups_listed", summary_zh: "已读取可用备份。",
        checks: [{ "name" => "backup_count", "value" => backups.length }]
      ) if options[:json]
      puts backups
      return 0
    end

    guard_storage = options[:profile_dirs].empty?
    expected_storage = storage_mode if guard_storage
    directories = guard_storage ? default_profile_directories : options[:profile_dirs]
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
      snapshots.each { |path| puts File.basename(path) }
      return 0
    end

    if options[:recover_profile_transaction]
      result = recover_pending_profile_transaction(
        options[:backup_root], directories: directories,
        guard_storage: guard_storage, expected_storage: expected_storage
      )
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

    if options[:compare_backup]
      comparison = compare_backup(options[:compare_backup], directories: directories, backup_root: options[:backup_root])
      return emit_cli_result(
        operation: "compare_backup", exit_code: 0, status: comparison.fetch(:same) ? "no_change" : "ok",
        code: comparison.fetch(:same) ? "backup_matches" : "backup_differs", summary_zh: "备份比较完成。",
        changes: comparison.fetch(:changes)
      ) if options[:json]
      puts JSON.generate(comparison)
      return 0
    end

    if options[:restore_backup]
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
            precommit_condition: precommit_condition
          )
        else
          restore_result
        end
      end
      result = restore_backup(
        options[:restore_backup], directories: directories, backup_root: options[:backup_root],
        expected_current_sha256: options[:expected_current_sha256], validator: method(:validate_with_mihomo),
        selected_name: selected, activation: activation,
        precommit_condition: precommit_condition
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
                              else
                                ["failed", result[:status].to_s, "备份恢复失败。"]
                              end
      exit_code = %w[ok no_change].include?(status) ? 0 : 1
      return emit_cli_result(
        operation: "restore_backup", exit_code: exit_code,
        status: status, code: code, summary_zh: summary,
        changes: result[:status] == :updated ? ["profile_restored"] : []
      ) if options[:json]
      puts JSON.generate(result.reject { |key, _value| key == :rollback_bytes })
      return exit_code
    end

    if options[:safe_update_all]
      unless [1, 2, 3].include?(options[:usage_profile])
        return emit_cli_result(
          operation: "safe_update", exit_code: 64, status: "invalid_request", code: "usage_profile_required",
          summary_zh: "安全更新必须指定用途档位 1、2 或 3。"
        ) if options[:json]
        warn "安全更新必须指定用途档位 1、2 或 3。"
        return 64
      end
      policy = JSON.parse(File.read(options[:policy], encoding: "UTF-8"))
      targets = remote_subscription_targets(directories)
      result = safe_update_all(
        targets: targets, policy: policy, backup_root: options[:backup_root],
        usage_profile: options[:usage_profile], guard_storage: guard_storage,
        expected_storage: expected_storage
      )
      if result[:status] == :updated
        mark_wrapper_commit_receipt(options)
        return emit_cli_result(
          operation: "safe_update", exit_code: 0, status: "ok", code: "safe_update_completed",
          summary_zh: "全部远程订阅已安全更新。", profile: options[:usage_profile],
          changes: ["remote_subscriptions"],
          checks: [{ "name" => "updated_count", "value" => result.fetch(:count) }],
          items: result.fetch(:profiles).map { |_name| { "status" => "updated" } }
        ) if options[:json]
        puts "全部远程订阅已安全更新：#{result.fetch(:count)} 份。"
        result.fetch(:profiles).each { |name| puts "已更新：#{safe_label(name)}" }
        return 0
      end
      if result[:status] == :rollback_failed
        return emit_cli_result(
          operation: "safe_update", exit_code: 1, status: "partial", code: "rollback_failed",
          summary_zh: "安全更新失败，且至少一份订阅未能恢复。", profile: options[:usage_profile]
        ) if options[:json]
        warn "安全更新失败，且至少一份订阅未能恢复；请立即按备份记录处理。"
        return 1
      end
      if result[:status] == :runtime_restore_pending
        return emit_cli_result(
          operation: "safe_update", exit_code: 1, status: "partial", code: "safe_update_runtime_pending",
          summary_zh: "安全更新失败；订阅文件已恢复，但运行内核恢复失败。", profile: options[:usage_profile]
        ) if options[:json]
        warn "安全更新失败；订阅文件已恢复，但运行内核恢复失败。"
        return 1
      end
      return emit_cli_result(
        operation: "safe_update", exit_code: 1, status: "rolled_back", code: "safe_update_failed",
        summary_zh: "安全更新失败，订阅已保持原样。", profile: options[:usage_profile]
      ) if options[:json]
      warn "安全更新失败；全部订阅保持原样。"
      return 1
    end

    results = run(
      directories: directories,
      policy_path: options[:policy],
      dry_run: options[:dry_run],
      backup_root: options[:backup_root],
      validator: options[:dry_run] ? nil : method(:validate_with_mihomo),
      auto_reload: options[:auto_reload] && !options[:dry_run],
      usage_profile: options[:usage_profile] || 3,
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
    warn "参数错误：#{error.message}"
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
      operation: "patch_profiles", exit_code: 1, status: "failed", code: "invalid_configuration",
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
  rescue StandardError => error
    return emit_cli_result(
      operation: "patch_profiles", exit_code: 1, status: "failed", code: "unexpected_error",
      summary_zh: "ClaudeEasy 运行失败。"
    ) if json_mode
    warn "ClaudeEasy 运行失败：#{safe_label(error.message)}（#{error.class}）"
    1
  end
end
