#!/bin/sh
set -eu
set -f

INSTALL_DIR="$HOME/Library/Application Support/ClaudeEasy"
BACKUP_DIR="$INSTALL_DIR/backups"
CUSTOM_PROFILE_DIR="${CLAUDE_EASY_PROFILE_DIR:-}"
STATE_PATH="$INSTALL_DIR/install-state.plist"
USAGE_STATE_PATH="$INSTALL_DIR/usage-profile.plist"
DEFAULTS_DOMAIN="com.metacubex.ClashX.meta"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESULT_CONTRACT_SOURCE="$SCRIPT_DIR/macos/result_contract.rb"
PATCHER_SOURCE="$SCRIPT_DIR/macos/patch_profiles.rb"
OPERATION_LOCK_SOURCE="$SCRIPT_DIR/macos/operation_lock.rb"
POLICY_SOURCE="$SCRIPT_DIR/../references/policy.json"
AUTO_UPDATE_OWNERSHIP_PATH="$BACKUP_DIR/clashx-meta-kAutoUpdateEnable.state.json"
OPERATION_LOCK_PATH="$BACKUP_DIR/.claude-easy-wrapper.lock"
JSON_OUTPUT=0
UNINSTALL_STAGING="$INSTALL_DIR/.claude-easy-uninstall-staging"
PROFILE_TRANSACTION_PATH="$BACKUP_DIR/.claude-easy-profile-transaction.json"
OPERATION_LOCK_REQUIRED=1
UNINSTALL_READY=0
UNINSTALL_COMMITTED=0
RESTORE_FAILURE_CODE=""
RESTORE_FAILURE_SUMMARY=""
INTERNAL_UNINSTALL_EXIT_RECEIPT=""
if [ "${CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD:-0}" = "1" ]; then
  INTERNAL_UNINSTALL_EXIT_RECEIPT="${CLAUDE_EASY_UNINSTALL_EXIT_RECEIPT:-}"
fi

unexpected_uninstall_exit() {
  unexpected_status=$1
  trap - EXIT HUP INT TERM
  [ "$unexpected_status" -ne 0 ] || return 0
  set +e
  public_exit=$unexpected_status
  unexpected_result_status=failed
  unexpected_code=unexpected_exit
  unexpected_summary="卸载流程意外中止。"
  if { [ -e "$UNINSTALL_STAGING" ] || [ -L "$UNINSTALL_STAGING" ]; } &&
     [ -d "$UNINSTALL_STAGING" ] && [ ! -L "$UNINSTALL_STAGING" ]; then
    if [ -f "$UNINSTALL_STAGING/COMMITTED" ]; then
      unexpected_result_status=partial
      unexpected_code=uninstall_committed_interrupted
      unexpected_summary="卸载已经提交，但最终清理或同步未完成；下次运行会继续清理。"
    else
      unexpected_was_ready=0
      [ -f "$UNINSTALL_STAGING/READY" ] && unexpected_was_ready=1
      if command -v restore_uncommitted_uninstall >/dev/null 2>&1 &&
         restore_uncommitted_uninstall; then
        unexpected_result_status=rolled_back
        if [ "$unexpected_was_ready" -eq 1 ] || [ "$UNINSTALL_READY" -eq 1 ]; then
          unexpected_code=uninstall_interrupted_rolled_back
          unexpected_summary="卸载意外中止；已恢复移出的安装文件。"
        else
          unexpected_code=uninstall_interrupted_before_ready
          unexpected_summary="卸载在删除准备完成前中止；安装文件保持不变。"
        fi
      else
        unexpected_result_status=partial
        unexpected_code=uninstall_recovery_failed
        unexpected_summary="卸载意外中止，且恢复未能完整同步；请重试安全卸载。"
      fi
    fi
  elif [ "$UNINSTALL_COMMITTED" -eq 1 ]; then
    unexpected_result_status=partial
    unexpected_code=uninstall_committed_interrupted
    unexpected_summary="卸载已经提交，但最终清理或同步未完成；下次运行会继续清理。"
  elif [ -e "$UNINSTALL_STAGING" ] || [ -L "$UNINSTALL_STAGING" ] ||
       [ "$UNINSTALL_READY" -eq 1 ]; then
    unexpected_result_status=partial
    unexpected_code=uninstall_recovery_failed
    unexpected_summary="卸载意外中止，且恢复状态不安全；未继续处理。"
  fi
  if command -v emit_uninstall_result >/dev/null 2>&1; then
    if [ "$JSON_OUTPUT" -eq 1 ]; then
      emit_uninstall_result "$public_exit" "$unexpected_result_status" \
        "$unexpected_code" "$unexpected_summary"
    else
      /usr/bin/printf '%s\n' "[ClaudeEasy] $unexpected_summary"
    fi
  elif [ "$JSON_OUTPUT" -eq 0 ]; then
    /usr/bin/printf '%s\n' "[ClaudeEasy] $unexpected_summary"
  fi
  if [ -n "${CLAUDE_EASY_UNINSTALL_EXIT_RECEIPT:-}" ] &&
     [ -f "$CLAUDE_EASY_UNINSTALL_EXIT_RECEIPT" ] &&
     [ ! -L "$CLAUDE_EASY_UNINSTALL_EXIT_RECEIPT" ]; then
    /usr/bin/printf 'unexpected:%s\n' "$public_exit" >"$CLAUDE_EASY_UNINSTALL_EXIT_RECEIPT"
  fi
  exit "$public_exit"
}

unset CLAUDE_EASY_UNINSTALL_EXIT_RECEIPT

trap 'unexpected_uninstall_exit $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for argument do
  [ "$argument" = "--json" ] && JSON_OUTPUT=1
  case "$argument" in
    -h|--help) OPERATION_LOCK_REQUIRED=0 ;;
  esac
done

emit_uninstall_result() {
  result_exit=$1
  result_status=$2
  result_code=$3
  result_summary=$4
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    result_ok=false
    [ "$result_exit" -ne 0 ] || result_ok=true
    result_payload=""
    if [ -x /usr/bin/ruby ] && [ -f "$RESULT_CONTRACT_SOURCE" ]; then
      result_payload=$(/usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
        --command uninstall --operation uninstall --ok "$result_ok" \
        --status "$result_status" --code "$result_code" --exit-code "$result_exit" --summary "$result_summary" 2>/dev/null) || result_payload=""
    fi
    if [ -n "$result_payload" ] &&
       /usr/bin/printf '%s' "$result_payload" | /usr/bin/ruby -rjson -e '
         value = JSON.parse(STDIN.read)
         required = %w[schema version command platform client operation ok status code exit_code summary_zh profile changes checks items messages warnings]
         abort unless value.is_a?(Hash) && value.keys.sort == required.sort &&
           value["schema"] == "claude-easy.result" && value["command"] == "uninstall" &&
           value["status"] == ARGV.fetch(0) && value["code"] == ARGV.fetch(1) &&
           value["exit_code"] == Integer(ARGV.fetch(2), 10) &&
           value["ok"] == (ARGV.fetch(3) == "true")
       ' "$result_status" "$result_code" "$result_exit" "$result_ok" >/dev/null 2>&1; then
      /usr/bin/printf '%s\n' "$result_payload"
      return 0
    fi
    /usr/bin/printf '%s\n' "{\"schema\":\"claude-easy.result\",\"version\":1,\"command\":\"uninstall\",\"platform\":\"macos\",\"client\":\"clashx-meta\",\"operation\":\"uninstall\",\"ok\":$result_ok,\"status\":\"$result_status\",\"code\":\"$result_code\",\"exit_code\":$result_exit,\"summary_zh\":\"$result_summary\",\"profile\":null,\"changes\":[],\"checks\":[],\"items\":[],\"messages\":[],\"warnings\":[]}"
  fi
}

finish() {
  finish_exit=$1
  finish_status=$2
  finish_code=$3
  finish_summary=$4
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    emit_uninstall_result "$finish_exit" "$finish_status" "$finish_code" "$finish_summary"
  fi
  trap - EXIT HUP INT TERM
  exit "$finish_exit"
}

say() {
  [ "$JSON_OUTPUT" -eq 0 ] || return 0
  /usr/bin/printf '%s\n' "[ClaudeEasy] $1"
}

durable_ensure_private_directory() {
  /usr/bin/ruby "$OPERATION_LOCK_SOURCE" --ensure-private-directory "$1"
}

durable_sync_directory() {
  /usr/bin/ruby "$OPERATION_LOCK_SOURCE" --sync-directory "$1"
}

durable_sync_file() {
  /usr/bin/ruby "$OPERATION_LOCK_SOURCE" --sync-file "$1"
}

durable_rename_exclusive() {
  /usr/bin/ruby "$OPERATION_LOCK_SOURCE" --rename-exclusive "$1" "$2"
}

usage() {
  [ "$JSON_OUTPUT" -eq 0 ] || return 0
  /usr/bin/printf '%s\n' "用法：uninstall_macos.sh [--json]"
}

parse_arguments() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        shift
        ;;
      -h|--help)
        usage
        finish 0 ok help "已显示帮助。"
        ;;
      *)
        usage
        finish 64 invalid_request invalid_arguments "参数错误。"
        ;;
    esac
  done
}

parse_arguments "$@"

uninstall_package_complete() {
  for required_package_file in \
    "$PATCHER_SOURCE" \
    "$RESULT_CONTRACT_SOURCE" \
    "$OPERATION_LOCK_SOURCE" \
    "$SCRIPT_DIR/macos/patch_profiles/transform.rb" \
    "$SCRIPT_DIR/macos/patch_profiles/backups.rb" \
    "$SCRIPT_DIR/macos/patch_profiles/mihomo.rb" \
    "$SCRIPT_DIR/macos/patch_profiles/profile_writer.rb" \
    "$SCRIPT_DIR/macos/patch_profiles/subscriptions.rb" \
    "$SCRIPT_DIR/macos/patch_profiles/runtime.rb" \
    "$SCRIPT_DIR/macos/patch_profiles/cli.rb" \
    "$POLICY_SOURCE"; do
    [ -f "$required_package_file" ] && [ ! -L "$required_package_file" ] || return 1
  done
  return 0
}

uninstall_package_dependencies_load() {
  /usr/bin/ruby "$PATCHER_SOURCE" --json --help >/dev/null 2>&1 &&
    /usr/bin/ruby -rjson -e '
      value = JSON.parse(File.binread(ARGV.fetch(0)))
      abort unless value.is_a?(Hash)
    ' "$POLICY_SOURCE" >/dev/null 2>&1
}

if [ "$OPERATION_LOCK_REQUIRED" -eq 1 ]; then
  if [ "$(uname -s)" != "Darwin" ]; then
    say "当前系统不是 macOS。"
    finish 2 unsupported unsupported_platform "当前系统不是 macOS。"
  fi
  lock_user_id=$(/usr/bin/id -u)
  if [ "$lock_user_id" -eq 0 ]; then
    say "请不要使用 sudo 或 root 运行卸载程序；请用当前登录用户直接运行。"
    finish 2 invalid_request root_not_allowed "请用当前登录用户直接运行。"
  fi
  if [ ! -x /usr/bin/ruby ]; then
    say "这台 Mac 没有系统 Ruby，无法安全卸载。"
    finish 3 unsupported ruby_missing "这台 Mac 没有系统 Ruby，无法安全卸载。"
  fi
  if ! uninstall_package_complete || ! uninstall_package_dependencies_load; then
    say "安装包不完整。"
    finish 6 failed incomplete_package "安装包不完整。"
  fi
  if [ "${CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD:-0}" = "1" ]; then
    if ! /usr/bin/ruby "$OPERATION_LOCK_SOURCE" \
        --verify-held-lock "$OPERATION_LOCK_PATH"; then
      finish 1 failed operation_lock_failed "无法建立 ClaudeEasy 操作锁；未执行任何修改。"
    fi
    CLAUDE_EASY_UNINSTALL_EXIT_RECEIPT=$INTERNAL_UNINSTALL_EXIT_RECEIPT
  else
    operation_result_receipt=$(/usr/bin/mktemp -t claude-easy-uninstall-result) ||
      finish 1 failed operation_lock_failed "无法建立 ClaudeEasy 操作锁；未执行任何修改。"
    /bin/chmod 600 "$operation_result_receipt" || {
      /bin/rm -f "$operation_result_receipt"
      finish 1 failed operation_lock_failed "无法建立 ClaudeEasy 操作锁；未执行任何修改。"
    }
    trap ':' HUP INT TERM
    set +e
    CLAUDE_EASY_UNINSTALL_EXIT_RECEIPT="$operation_result_receipt" \
      /usr/bin/ruby "$OPERATION_LOCK_SOURCE" "$OPERATION_LOCK_PATH" /bin/sh "$0" "$@"
    operation_lock_status=$?
    set -e
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    operation_result_state=$(/bin/cat "$operation_result_receipt" 2>/dev/null || true)
    /bin/rm -f "$operation_result_receipt"
    case "$operation_lock_status" in
      75)
        if [ "$operation_result_state" = "unexpected:75" ]; then
          trap - EXIT HUP INT TERM
          exit 75
        fi
        finish 1 failed operation_in_progress "另一个 ClaudeEasy 操作正在进行，请稍后重试。"
        ;;
      76)
        if [ "$operation_result_state" = "unexpected:76" ]; then
          trap - EXIT HUP INT TERM
          exit 76
        fi
        finish 1 failed operation_lock_failed "无法建立 ClaudeEasy 操作锁；未执行任何修改。"
        ;;
      *)
        trap - EXIT HUP INT TERM
        exit "$operation_lock_status"
        ;;
    esac
  fi
fi

set_restore_failure() {
  if [ -z "$RESTORE_FAILURE_CODE" ]; then
    RESTORE_FAILURE_CODE=$1
    RESTORE_FAILURE_SUMMARY=$2
  fi
}

restore_uncommitted_uninstall() {
  RESTORE_FAILURE_CODE=""
  RESTORE_FAILURE_SUMMARY=""
  [ -e "$UNINSTALL_STAGING" ] || return 0
  if [ ! -d "$UNINSTALL_STAGING" ] || [ -L "$UNINSTALL_STAGING" ]; then
    set_restore_failure uninstall_state_unsafe "卸载恢复目录不安全；未继续处理。"
    return 1
  fi
  if [ -f "$UNINSTALL_STAGING/COMMITTED" ]; then
    if ! /bin/rm -rf "$UNINSTALL_STAGING" ||
       ! durable_sync_directory "$INSTALL_DIR"; then
      set_restore_failure uninstall_restore_failed "已提交卸载的恢复目录无法完整清理或同步。"
      return 1
    fi
    return 0
  fi
  if [ ! -f "$UNINSTALL_STAGING/READY" ]; then
    if ! /bin/rm -rf "$UNINSTALL_STAGING" ||
       ! durable_sync_directory "$INSTALL_DIR"; then
      set_restore_failure uninstall_restore_failed "未完成的卸载暂存无法完整清理或同步。"
      return 1
    fi
    return 0
  fi
  restore_failed=0
  if [ -f "$UNINSTALL_STAGING/AUTO_UPDATE_WAS_OWNED" ]; then
    if [ ! -f "$PATCHER_SOURCE" ]; then
      set_restore_failure incomplete_package "安装包不完整，无法恢复未完成的安全卸载。"
      restore_failed=1
    elif ! disable_result=$(/usr/bin/ruby "$PATCHER_SOURCE" \
        --backup-dir "$BACKUP_DIR" --usage-profile 3 \
        --internal-uninstall-recovery-state "$UNINSTALL_STAGING/usage" \
        --disable-subscription-auto-update 2>/dev/null); then
      set_restore_failure auto_update_rollback_failed "无法恢复未完成安全卸载的订阅自动更新状态。"
      restore_failed=1
    else
      case "$disable_result" in
        disabled|already_disabled|already_disabled_owned) ;;
        *)
          set_restore_failure auto_update_rollback_failed "订阅自动更新回退结果异常。"
          restore_failed=1
          ;;
      esac
      if [ "$restore_failed" -eq 0 ]; then
        if ! restored_ownership=$(/usr/bin/ruby "$PATCHER_SOURCE" \
            --backup-dir "$BACKUP_DIR" --print-auto-update-ownership-state 2>/dev/null) ||
           [ "$restored_ownership" != "owned" ]; then
          set_restore_failure auto_update_rollback_failed "订阅自动更新所有权未能恢复。"
          restore_failed=1
        fi
      fi
    fi
  fi
  restore_slot "$UNINSTALL_STAGING/patcher" "$INSTALL_DIR/patch_profiles.rb" || restore_failed=1
  restore_slot "$UNINSTALL_STAGING/policy" "$INSTALL_DIR/policy.json" || restore_failed=1
  restore_slot "$UNINSTALL_STAGING/state" "$STATE_PATH" || restore_failed=1
  restore_slot "$UNINSTALL_STAGING/usage" "$USAGE_STATE_PATH" || restore_failed=1
  restore_slot "$UNINSTALL_STAGING/log" "$INSTALL_DIR/patch.log" || restore_failed=1
  restore_slot "$UNINSTALL_STAGING/error-log" "$INSTALL_DIR/patch-error.log" || restore_failed=1
  [ "$restore_failed" -eq 0 ] || return 1
  if ! /bin/rm -rf "$UNINSTALL_STAGING" ||
     ! durable_sync_directory "$INSTALL_DIR"; then
    set_restore_failure uninstall_restore_failed "卸载文件已经恢复，但恢复状态未能完整同步。"
    return 1
  fi
  return 0
}

recover_pending_profile_transaction() {
  if [ ! -e "$PROFILE_TRANSACTION_PATH" ] && [ ! -L "$PROFILE_TRANSACTION_PATH" ]; then
    return 0
  fi
  [ -f "$PATCHER_SOURCE" ] && [ ! -L "$PATCHER_SOURCE" ] ||
    finish 6 failed incomplete_package "安装包不完整，无法恢复未完成的配置事务。"

  set +e
  if [ -n "$CUSTOM_PROFILE_DIR" ]; then
    profile_recovery=$(/usr/bin/ruby "$PATCHER_SOURCE" \
      --profile-dir "$CUSTOM_PROFILE_DIR" --backup-dir "$BACKUP_DIR" \
      --recover-profile-transaction 2>/dev/null)
  else
    profile_recovery=$(/usr/bin/ruby "$PATCHER_SOURCE" \
      --backup-dir "$BACKUP_DIR" --recover-profile-transaction 2>/dev/null)
  fi
  profile_recovery_status=$?
  set -e
  if [ "$profile_recovery_status" -ne 0 ]; then
    finish 1 failed profile_transaction_recovery_failed "未完成的配置事务无法恢复；未继续卸载。"
  fi
  case "$profile_recovery" in
    recovered|none) ;;
    *) finish 1 failed profile_transaction_recovery_failed "配置事务恢复结果异常；未继续卸载。" ;;
  esac
  if [ -e "$PROFILE_TRANSACTION_PATH" ] || [ -L "$PROFILE_TRANSACTION_PATH" ]; then
    finish 1 failed profile_transaction_recovery_failed "配置事务恢复记录仍然存在；未继续卸载。"
  fi
  say "已先恢复上次中断的配置事务和当前运行配置。"
}

restore_slot() {
  slot=$1
  destination=$2
  destination_directory=$(/usr/bin/dirname "$destination")
  removed_slot="$slot.removed"
  if [ -e "$removed_slot" ] || [ -L "$removed_slot" ]; then
    if durable_rename_exclusive "$removed_slot" "$destination"; then
      return 0
    fi
    set_restore_failure uninstall_restore_conflict "卸载中断后检测到新文件；隔离文件已保留，未覆盖。"
    return 1
  fi
  [ -f "$slot" ] || return 0
  if [ -L "$slot" ]; then
    set_restore_failure uninstall_state_unsafe "卸载恢复文件不安全；未覆盖现有文件。"
    return 1
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ ! -f "$destination" ] || [ -L "$destination" ] ||
       ! /usr/bin/cmp -s "$slot" "$destination"; then
      set_restore_failure uninstall_restore_conflict "卸载中断后检测到新文件；未覆盖。"
      return 1
    fi
    if ! durable_sync_directory "$destination_directory"; then
      set_restore_failure uninstall_restore_failed "卸载恢复文件未能完整同步。"
      return 1
    fi
    return 0
  fi
  if ! durable_ensure_private_directory "$destination_directory"; then
    set_restore_failure uninstall_restore_failed "卸载恢复目录无法安全创建。"
    return 1
  fi
  if /bin/ln "$slot" "$destination"; then
    if ! durable_sync_directory "$destination_directory"; then
      set_restore_failure uninstall_restore_failed "卸载恢复文件未能完整同步。"
      return 1
    fi
    return 0
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ ! -f "$destination" ] || [ -L "$destination" ] ||
       ! /usr/bin/cmp -s "$slot" "$destination"; then
      set_restore_failure uninstall_restore_conflict "卸载中断后检测到新文件；未覆盖。"
      return 1
    fi
    if ! durable_sync_directory "$destination_directory"; then
      set_restore_failure uninstall_restore_failed "卸载恢复文件未能完整同步。"
      return 1
    fi
    return 0
  fi
  set_restore_failure uninstall_restore_failed "卸载文件无法原子恢复；保留恢复目录以便重试。"
  return 1
}

stage_slot() {
  source=$1
  slot=$2
  if [ ! -e "$source" ] && [ ! -L "$source" ]; then
    /usr/bin/printf '%s\n' absent >"$UNINSTALL_STAGING/$slot.meta"
    durable_sync_file "$UNINSTALL_STAGING/$slot.meta"
    return 0
  fi
  [ -f "$source" ] && [ ! -L "$source" ] ||
    finish 1 failed uninstall_target_unsafe "卸载目标不是安全的普通文件；未删除。"
  source_identity=$(/usr/bin/stat -f '%d:%i' "$source")
  /usr/bin/printf 'present:%s\n' "$source_identity" >"$UNINSTALL_STAGING/$slot.meta"
  durable_sync_file "$UNINSTALL_STAGING/$slot.meta"
  /bin/cp -p "$source" "$UNINSTALL_STAGING/$slot"
  durable_sync_file "$UNINSTALL_STAGING/$slot"
}

verify_staged_slot() {
  source=$1
  slot=$2
  metadata=$(/bin/cat "$UNINSTALL_STAGING/$slot.meta")
  case "$metadata" in
    absent)
      [ ! -e "$source" ] && [ ! -L "$source" ]
      ;;
    present:*)
      [ -f "$source" ] && [ ! -L "$source" ] &&
        [ "$(/usr/bin/stat -f '%d:%i' "$source")" = "${metadata#present:}" ] &&
        /usr/bin/cmp -s "$UNINSTALL_STAGING/$slot" "$source"
      ;;
    *)
      return 1
      ;;
  esac
}

quarantine_staged_slot() {
  source=$1
  slot=$2
  metadata=$(/bin/cat "$UNINSTALL_STAGING/$slot.meta") || return 1
  removed_slot="$UNINSTALL_STAGING/$slot.removed"
  if [ -e "$removed_slot" ] || [ -L "$removed_slot" ]; then
    QUARANTINE_FAILURE_CODE=uninstall_state_unsafe
    QUARANTINE_FAILURE_SUMMARY="卸载隔离位置已被占用；未继续删除。"
    return 1
  fi
  case "$metadata" in
    absent)
      if [ ! -e "$source" ] && [ ! -L "$source" ]; then
        return 0
      fi
      ;;
    present:*) ;;
    *)
      QUARANTINE_FAILURE_CODE=uninstall_state_unsafe
      QUARANTINE_FAILURE_SUMMARY="卸载暂存记录无效；未继续删除。"
      return 1
      ;;
  esac

  if ! durable_rename_exclusive "$source" "$removed_slot"; then
    QUARANTINE_FAILURE_CODE=uninstall_state_conflict
    QUARANTINE_FAILURE_SUMMARY="卸载目标在最终核对后发生变化；未继续删除。"
    return 1
  fi

  moved_matches=0
  case "$metadata" in
    present:*)
      if [ -f "$removed_slot" ] && [ ! -L "$removed_slot" ] &&
         [ "$(/usr/bin/stat -f '%d:%i' "$removed_slot")" = "${metadata#present:}" ] &&
         /usr/bin/cmp -s "$UNINSTALL_STAGING/$slot" "$removed_slot"; then
        moved_matches=1
      fi
      ;;
  esac
  [ "$moved_matches" -eq 0 ] || return 0

  durable_rename_exclusive "$removed_slot" "$source" >/dev/null 2>&1 || true
  QUARANTINE_FAILURE_CODE=uninstall_state_conflict
  QUARANTINE_FAILURE_SUMMARY="卸载目标在最终核对后被替换；并发文件未被删除。"
  return 1
}

finish_quarantine_failure() {
  if ! restore_uncommitted_uninstall; then
    finish 1 partial "${RESTORE_FAILURE_CODE:-uninstall_restore_failed}" \
      "${RESTORE_FAILURE_SUMMARY:-卸载文件未能完整恢复；隔离内容已保留。}"
  fi
  finish 1 failed "$QUARANTINE_FAILURE_CODE" "$QUARANTINE_FAILURE_SUMMARY"
}

restore_uncommitted_or_finish() {
  if ! restore_uncommitted_uninstall; then
    restore_exit=1
    [ "$RESTORE_FAILURE_CODE" != "incomplete_package" ] || restore_exit=6
    finish "$restore_exit" partial \
      "${RESTORE_FAILURE_CODE:-uninstall_restore_failed}" \
      "${RESTORE_FAILURE_SUMMARY:-卸载文件未能完整恢复；恢复目录已保留。}"
  fi
}

delete_staged_install_files() {
  if [ -e "$UNINSTALL_STAGING" ] || [ -L "$UNINSTALL_STAGING" ]; then
    finish 1 failed uninstall_state_conflict "卸载恢复目录已存在；未继续删除。"
  fi
  durable_ensure_private_directory "$UNINSTALL_STAGING"
  stage_slot "$INSTALL_DIR/patch_profiles.rb" patcher
  stage_slot "$INSTALL_DIR/policy.json" policy
  stage_slot "$STATE_PATH" state
  stage_slot "$USAGE_STATE_PATH" usage
  stage_slot "$INSTALL_DIR/patch.log" log
  stage_slot "$INSTALL_DIR/patch-error.log" error-log
  if [ "$AUTO_UPDATE_OWNED" -eq 1 ]; then
    [ -f "$AUTO_UPDATE_OWNERSHIP_PATH" ] && [ ! -L "$AUTO_UPDATE_OWNERSHIP_PATH" ] ||
      finish 1 failed auto_update_state_unsafe "订阅自动更新所有权状态不安全；未继续卸载。"
    /usr/bin/touch "$UNINSTALL_STAGING/AUTO_UPDATE_WAS_OWNED"
    durable_sync_file "$UNINSTALL_STAGING/AUTO_UPDATE_WAS_OWNED"
  fi
  /usr/bin/touch "$UNINSTALL_STAGING/READY"
  durable_sync_file "$UNINSTALL_STAGING/READY"
  UNINSTALL_READY=1

  if ! verify_staged_slot "$INSTALL_DIR/patch_profiles.rb" patcher ||
     ! verify_staged_slot "$INSTALL_DIR/policy.json" policy ||
     ! verify_staged_slot "$STATE_PATH" state ||
     ! verify_staged_slot "$USAGE_STATE_PATH" usage ||
     ! verify_staged_slot "$INSTALL_DIR/patch.log" log ||
     ! verify_staged_slot "$INSTALL_DIR/patch-error.log" error-log; then
    /bin/rm -rf "$UNINSTALL_STAGING"
    durable_sync_directory "$INSTALL_DIR"
    finish 1 failed uninstall_state_conflict "卸载目标在暂存后被替换；未删除新文件。"
  fi

  quarantine_staged_slot "$INSTALL_DIR/patch_profiles.rb" patcher || finish_quarantine_failure
  quarantine_staged_slot "$INSTALL_DIR/policy.json" policy || finish_quarantine_failure
  quarantine_staged_slot "$STATE_PATH" state || finish_quarantine_failure
  quarantine_staged_slot "$USAGE_STATE_PATH" usage || finish_quarantine_failure
  quarantine_staged_slot "$INSTALL_DIR/patch.log" log || finish_quarantine_failure
  quarantine_staged_slot "$INSTALL_DIR/patch-error.log" error-log || finish_quarantine_failure
  for removed in \
    "$INSTALL_DIR/patch_profiles.rb" \
    "$INSTALL_DIR/policy.json" \
    "$STATE_PATH" \
    "$USAGE_STATE_PATH" \
    "$INSTALL_DIR/patch.log" \
    "$INSTALL_DIR/patch-error.log"; do
    if [ -e "$removed" ] || [ -L "$removed" ]; then
      if ! restore_uncommitted_uninstall; then
        finish 1 partial "${RESTORE_FAILURE_CODE:-uninstall_restore_failed}" \
          "${RESTORE_FAILURE_SUMMARY:-安装文件未能完整恢复；隔离内容已保留。}"
      fi
      finish 1 failed uninstall_delete_failed "安装文件未能整批删除，已恢复其余文件。"
    fi
  done
  durable_sync_directory "$INSTALL_DIR"
}

commit_staged_install_files() {
  /usr/bin/touch "$UNINSTALL_STAGING/COMMITTED"
  durable_sync_file "$UNINSTALL_STAGING/COMMITTED"
  UNINSTALL_COMMITTED=1
  /bin/rm -rf "$UNINSTALL_STAGING"
  durable_sync_directory "$INSTALL_DIR"
}

if [ "$(uname -s)" != "Darwin" ]; then
  say "当前系统不是 macOS。"
  finish 2 unsupported unsupported_platform "当前系统不是 macOS。"
fi

USER_ID=$(/usr/bin/id -u)
if [ "$USER_ID" -eq 0 ]; then
  say "请不要使用 sudo 或 root 运行卸载程序；请用当前登录用户直接运行。"
  finish 2 invalid_request root_not_allowed "请用当前登录用户直接运行。"
fi

recover_pending_profile_transaction
restore_uncommitted_or_finish

AUTO_UPDATE_OWNED=0
if [ -e "$AUTO_UPDATE_OWNERSHIP_PATH" ] || [ -L "$AUTO_UPDATE_OWNERSHIP_PATH" ]; then
  if [ ! -f "$PATCHER_SOURCE" ] || [ -L "$PATCHER_SOURCE" ]; then
    say "安装包不完整，无法安全恢复订阅自动更新；未删除用途档位。"
    finish 6 failed incomplete_package "安装包不完整，无法安全恢复订阅自动更新。"
  fi
  if ! ownership_status=$(/usr/bin/ruby "$PATCHER_SOURCE" \
    --backup-dir "$BACKUP_DIR" --print-auto-update-ownership-state 2>/dev/null); then
    say "无法读取订阅自动更新所有权；未删除用途档位。"
    finish 1 failed auto_update_state_unsafe "无法读取订阅自动更新所有权。"
  fi
  case "$ownership_status" in
    owned) AUTO_UPDATE_OWNED=1 ;;
    not_owned) ;;
    *) finish 1 failed auto_update_state_unsafe "订阅自动更新所有权结果异常。" ;;
  esac
fi

delete_staged_install_files

AUTO_UPDATE_RESTORED=0
if [ "$AUTO_UPDATE_OWNED" -eq 1 ]; then
  if ! auto_update_restore=$(/usr/bin/ruby "$PATCHER_SOURCE" \
    --backup-dir "$BACKUP_DIR" --restore-owned-subscription-auto-update 2>/dev/null); then
    restore_uncommitted_or_finish
    say "无法恢复本工具关闭的订阅自动更新；未删除用途档位和所有权状态。"
    finish 1 failed auto_update_restore_failed "无法恢复本工具关闭的订阅自动更新；未删除用途档位。"
  fi
  case "$auto_update_restore" in
    restored|already_restored)
      if ! ownership_status=$(/usr/bin/ruby "$PATCHER_SOURCE" \
        --backup-dir "$BACKUP_DIR" --print-auto-update-ownership-state 2>/dev/null) ||
         [ "$ownership_status" != "not_owned" ]; then
        restore_uncommitted_or_finish
        say "订阅自动更新虽已处理，但所有权状态未能清除；未删除用途档位。"
        finish 1 partial auto_update_state_cleanup_failed "订阅自动更新已处理，但所有权状态未能清除。"
      fi
      AUTO_UPDATE_RESTORED=1
      ;;
    *)
      restore_uncommitted_or_finish
      say "订阅自动更新恢复结果异常；未删除用途档位和所有权状态。"
      finish 1 failed auto_update_restore_failed "订阅自动更新恢复结果异常；未删除用途档位。"
      ;;
  esac
fi

commit_staged_install_files
/bin/rmdir "$INSTALL_DIR" >/dev/null 2>&1 || true

say "ClaudeEasy 安装文件已移除；当前版本没有后台监听任务。"
if [ -d "$BACKUP_DIR" ]; then
  say "原始订阅备份仍保留在本机；卸载程序没有删除或还原它们。"
fi
say "旧版安装前的 TUN 偏好无法证明仍是当前选择，因此保留当前值。订阅里的 DNS、WebRTC 和 AI 设置不会自动撤销。"
if [ "$AUTO_UPDATE_RESTORED" -eq 1 ]; then
  say "本工具关闭的订阅自动更新已经恢复并回读确认。"
fi
finish 0 ok uninstall_completed "ClaudeEasy 卸载处理完成；备份未删除。"
