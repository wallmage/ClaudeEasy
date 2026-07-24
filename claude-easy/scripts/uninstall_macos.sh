#!/bin/sh
set -eu
set -f

INSTALL_DIR="$HOME/Library/Application Support/ClaudeEasy"
LEGACY_INSTALL_DIR="$HOME/Library/Application Support/ClashPatch"
BACKUP_DIR="$INSTALL_DIR/backups"
CUSTOM_PROFILE_DIR="${CLAUDE_EASY_PROFILE_DIR:-}"
STATE_PATH="$INSTALL_DIR/install-state.plist"
USAGE_STATE_PATH="${CLAUDE_EASY_USAGE_STATE_PATH:-$INSTALL_DIR/usage-profile.plist}"
LEGACY_PATCH_LABEL="com.clashpatch.profiles"
LEGACY_PATCH_PLIST="$HOME/Library/LaunchAgents/$LEGACY_PATCH_LABEL.plist"
LEGACY_PATCHER_CURRENT_PATH="$INSTALL_DIR/patch_profiles.rb"
LEGACY_PATCHER_OLD_PATH="$LEGACY_INSTALL_DIR/patch_profiles.rb"
LEGACY_LABEL="com.wallny.clash-profile-patcher"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_PATCHER="$HOME/Library/Application Support/ClashProfilePatcher/patch_profiles.rb"
DEFAULTS_DOMAIN="com.metacubex.ClashX.meta"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RESULT_CONTRACT_SOURCE="$SCRIPT_DIR/macos/result_contract.rb"
PATCHER_SOURCE="$SCRIPT_DIR/macos/patch_profiles.rb"
OPERATION_LOCK_SOURCE="$SCRIPT_DIR/macos/operation_lock.rb"
AUTO_UPDATE_OWNERSHIP_PATH="$BACKUP_DIR/clashx-meta-kAutoUpdateEnable.state.json"
OPERATION_LOCK_PATH="$BACKUP_DIR/.claude-easy-wrapper.lock"
LEGACY_OPERATION_LOCK_PATH="$LEGACY_INSTALL_DIR/backups/.clash-patch-wrapper.lock"
MIGRATED_LEGACY_OPERATION_LOCK_PATH="$BACKUP_DIR/.clash-patch-wrapper.lock"
JSON_OUTPUT=0
UNINSTALL_STAGING="$INSTALL_DIR/.claude-easy-uninstall-staging"
LEGACY_UNINSTALL_STAGING="$INSTALL_DIR/.clash-patch-uninstall-staging"
PROFILE_TRANSACTION_PATH="$BACKUP_DIR/.claude-easy-profile-transaction.json"
LEGACY_PROFILE_TRANSACTION_PATH="$BACKUP_DIR/.clash-patch-profile-transaction.json"
OPERATION_LOCK_REQUIRED=1
LEGACY_STATE_MIGRATION_REQUIRED=0
ACTIVE_STATE_DIR=""
ACTIVE_BACKUP_DIR=""

unexpected_uninstall_exit() {
  unexpected_status=$1
  trap - EXIT HUP INT TERM
  [ "$unexpected_status" -ne 0 ] || return 0
  set +e
  if [ -d "$UNINSTALL_STAGING" ] && [ ! -f "$UNINSTALL_STAGING/COMMITTED" ]; then
    restore_uncommitted_uninstall
  fi
  exit "$unexpected_status"
}

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

finish() {
  finish_exit=$1
  finish_status=$2
  finish_code=$3
  finish_summary=$4
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if [ -x /usr/bin/ruby ] && [ -f "$RESULT_CONTRACT_SOURCE" ]; then
      /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
        --command uninstall --operation uninstall --ok "$([ "$finish_exit" -eq 0 ] && /usr/bin/printf true || /usr/bin/printf false)" \
        --status "$finish_status" --code "$finish_code" --exit-code "$finish_exit" --summary "$finish_summary"
    else
      /usr/bin/printf '%s\n' "{\"schema\":\"claude-easy.result\",\"version\":1,\"command\":\"uninstall\",\"platform\":\"macos\",\"client\":\"clashx-meta\",\"operation\":\"uninstall\",\"ok\":false,\"status\":\"$finish_status\",\"code\":\"$finish_code\",\"exit_code\":$finish_exit,\"summary_zh\":\"$finish_summary\",\"profile\":null,\"changes\":[],\"checks\":[],\"items\":[],\"messages\":[],\"warnings\":[]}"
    fi
  fi
  trap - EXIT HUP INT TERM
  exit "$finish_exit"
}

say() {
  [ "$JSON_OUTPUT" -eq 0 ] || return 0
  /usr/bin/printf '%s\n' "[ClaudeEasy] $1"
}

usage() {
  [ "$JSON_OUTPUT" -eq 0 ] || return 0
  /usr/bin/printf '%s\n' "用法：uninstall_macos.sh [--json]"
}

legacy_state_failure() {
  legacy_code=$1
  legacy_summary=$2
  say "$legacy_summary"
  finish 1 failed "$legacy_code" "$legacy_summary"
}

select_operation_lock_path() {
  if [ -L "$INSTALL_DIR" ] || [ -L "$LEGACY_INSTALL_DIR" ] ||
     { [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; } ||
     { [ -e "$LEGACY_INSTALL_DIR" ] && [ ! -d "$LEGACY_INSTALL_DIR" ]; }; then
    legacy_state_failure legacy_state_unsafe "旧版或当前状态目录不安全；未执行任何修改。"
  fi
  if [ -d "$INSTALL_DIR" ] && [ -d "$LEGACY_INSTALL_DIR" ]; then
    legacy_state_failure legacy_state_conflict "旧版与当前状态目录同时存在；为避免覆盖，未执行任何修改。"
  fi

  if [ -d "$INSTALL_DIR" ]; then
    if { [ -e "$OPERATION_LOCK_PATH" ] || [ -L "$OPERATION_LOCK_PATH" ]; } &&
       { [ -e "$MIGRATED_LEGACY_OPERATION_LOCK_PATH" ] || [ -L "$MIGRATED_LEGACY_OPERATION_LOCK_PATH" ]; }; then
      legacy_state_failure legacy_state_conflict "旧版与当前操作锁同时存在；为避免并发冲突，未执行任何修改。"
    fi
    if [ -e "$MIGRATED_LEGACY_OPERATION_LOCK_PATH" ] ||
       [ -L "$MIGRATED_LEGACY_OPERATION_LOCK_PATH" ]; then
      OPERATION_LOCK_PATH=$MIGRATED_LEGACY_OPERATION_LOCK_PATH
    fi
  elif [ -d "$LEGACY_INSTALL_DIR" ]; then
    OPERATION_LOCK_PATH=$LEGACY_OPERATION_LOCK_PATH
  fi
}

migrate_legacy_entry_under_lock() {
  legacy_entry=$1
  current_entry=$2
  entry_kind=$3
  expected_type=$4
  if [ -L "$legacy_entry" ] || [ -L "$current_entry" ]; then
    legacy_state_failure legacy_state_unsafe "旧版${entry_kind}不是安全的本地状态；未执行任何修改。"
  fi
  if [ -e "$legacy_entry" ] && [ -e "$current_entry" ]; then
    legacy_state_failure legacy_state_conflict "旧版与当前${entry_kind}同时存在；为避免覆盖，未执行任何修改。"
  fi
  [ -e "$legacy_entry" ] || return 0
  case "$expected_type" in
    file) [ -f "$legacy_entry" ] ||
      legacy_state_failure legacy_state_unsafe "旧版${entry_kind}类型异常；未执行任何修改。" ;;
    directory) [ -d "$legacy_entry" ] ||
      legacy_state_failure legacy_state_unsafe "旧版${entry_kind}类型异常；未执行任何修改。" ;;
  esac
  /bin/mv "$legacy_entry" "$current_entry" ||
    legacy_state_failure legacy_state_migration_failed "旧版${entry_kind}无法迁移；未继续修改。"
}

preflight_legacy_entry_under_lock() {
  legacy_entry=$1
  current_entry=$2
  entry_kind=$3
  expected_type=$4
  if [ -L "$legacy_entry" ] || [ -L "$current_entry" ]; then
    legacy_state_failure legacy_state_unsafe "旧版${entry_kind}不是安全的本地状态；未执行任何修改。"
  fi
  if [ -e "$legacy_entry" ] && [ -e "$current_entry" ]; then
    legacy_state_failure legacy_state_conflict "旧版与当前${entry_kind}同时存在；为避免覆盖，未执行任何修改。"
  fi
  for state_entry in "$legacy_entry" "$current_entry"; do
    [ -e "$state_entry" ] || continue
    case "$expected_type" in
      file) [ -f "$state_entry" ] ||
        legacy_state_failure legacy_state_unsafe "${entry_kind}类型异常；未执行任何修改。" ;;
      directory) [ -d "$state_entry" ] ||
        legacy_state_failure legacy_state_unsafe "${entry_kind}类型异常；未执行任何修改。" ;;
    esac
  done
}

preflight_legacy_state_under_lock() {
  [ "${CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD:-0}" = "1" ] ||
    legacy_state_failure operation_lock_failed "未持有 ClaudeEasy 操作锁；未执行状态迁移。"

  if [ -L "$INSTALL_DIR" ] || [ -L "$LEGACY_INSTALL_DIR" ] ||
     { [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; } ||
     { [ -e "$LEGACY_INSTALL_DIR" ] && [ ! -d "$LEGACY_INSTALL_DIR" ]; }; then
    legacy_state_failure legacy_state_unsafe "旧版或当前状态目录不安全；未执行任何修改。"
  fi
  if [ -d "$INSTALL_DIR" ] && [ -d "$LEGACY_INSTALL_DIR" ]; then
    legacy_state_failure legacy_state_conflict "旧版与当前状态目录同时存在；为避免覆盖，未执行任何修改。"
  fi

  LEGACY_STATE_MIGRATION_REQUIRED=0
  ACTIVE_STATE_DIR=$INSTALL_DIR
  if [ ! -d "$INSTALL_DIR" ] && [ -d "$LEGACY_INSTALL_DIR" ]; then
    LEGACY_STATE_MIGRATION_REQUIRED=1
    ACTIVE_STATE_DIR=$LEGACY_INSTALL_DIR
  fi
  ACTIVE_BACKUP_DIR="$ACTIVE_STATE_DIR/backups"

  preflight_legacy_entry_under_lock \
    "$ACTIVE_BACKUP_DIR/.clash-patch-wrapper.lock" \
    "$ACTIVE_BACKUP_DIR/.claude-easy-wrapper.lock" \
    "操作锁" file
  preflight_legacy_entry_under_lock \
    "$ACTIVE_STATE_DIR/.clash-patch-uninstall-staging" \
    "$ACTIVE_STATE_DIR/.claude-easy-uninstall-staging" \
    "卸载恢复状态" directory
  preflight_legacy_entry_under_lock \
    "$ACTIVE_BACKUP_DIR/.clash-patch-profile-transaction.json" \
    "$ACTIVE_BACKUP_DIR/.claude-easy-profile-transaction.json" \
    "配置事务" file
  preflight_legacy_entry_under_lock \
    "$ACTIVE_BACKUP_DIR/.clash-patch-operation.lock" \
    "$ACTIVE_BACKUP_DIR/.claude-easy-operation.lock" \
    "配置事务锁" file
}

migrate_legacy_state_under_lock() {
  preflight_legacy_state_under_lock
  if [ "$LEGACY_STATE_MIGRATION_REQUIRED" -eq 1 ]; then
    /bin/mv "$LEGACY_INSTALL_DIR" "$INSTALL_DIR" ||
      legacy_state_failure legacy_state_migration_failed "旧版状态目录无法迁移；未继续修改。"
  fi

  migrate_legacy_entry_under_lock \
    "$MIGRATED_LEGACY_OPERATION_LOCK_PATH" "$BACKUP_DIR/.claude-easy-wrapper.lock" "操作锁" file
  migrate_legacy_entry_under_lock \
    "$LEGACY_UNINSTALL_STAGING" "$UNINSTALL_STAGING" "卸载恢复状态" directory
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
select_operation_lock_path

if [ "$OPERATION_LOCK_REQUIRED" -eq 1 ] &&
   [ "${CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD:-0}" != "1" ]; then
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
  if [ ! -f "$OPERATION_LOCK_SOURCE" ]; then
    say "安装包不完整：缺少操作锁程序。"
    finish 6 failed incomplete_package "安装包不完整。"
  fi
  set +e
  /usr/bin/ruby "$OPERATION_LOCK_SOURCE" "$OPERATION_LOCK_PATH" /bin/sh "$0" "$@"
  operation_lock_status=$?
  set -e
  case "$operation_lock_status" in
    75)
      finish 1 failed operation_in_progress "另一个 ClaudeEasy 操作正在进行，请稍后重试。"
      ;;
    76)
      finish 1 failed operation_lock_failed "无法建立 ClaudeEasy 操作锁；未执行任何修改。"
      ;;
    *)
      trap - EXIT HUP INT TERM
      exit "$operation_lock_status"
      ;;
  esac
fi

preflight_legacy_state_under_lock

launch_agent_owned() {
  candidate=$1
  expected_label=$2
  expected_patcher=$3
  alternate_patcher=${4:-}
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  agent_label=$(/usr/bin/plutil -extract Label raw "$candidate" 2>/dev/null || true)
  agent_arg0=$(/usr/bin/plutil -extract ProgramArguments.0 raw "$candidate" 2>/dev/null || true)
  agent_arg1=$(/usr/bin/plutil -extract ProgramArguments.1 raw "$candidate" 2>/dev/null || true)
  [ "$agent_label" = "$expected_label" ] &&
    [ "$agent_arg0" = "/usr/bin/ruby" ] &&
    { [ "$agent_arg1" = "$expected_patcher" ] ||
      { [ -n "$alternate_patcher" ] && [ "$agent_arg1" = "$alternate_patcher" ]; }; }
}

remove_owned_agent() {
  candidate=$1
  expected_label=$2
  expected_patcher=$3
  alternate_patcher=${4:-}
  remove_patcher=${5:-0}
  if [ -f "$candidate" ]; then
    if launch_agent_owned "$candidate" "$expected_label" "$expected_patcher" "$alternate_patcher"; then
      if /bin/launchctl print "gui/$USER_ID/$expected_label" >/dev/null 2>&1; then
        /bin/launchctl bootout "gui/$USER_ID/$expected_label" >/dev/null 2>&1 ||
          finish 1 failed legacy_agent_remove_failed "旧版自动目录监听仍在运行；未继续卸载。"
        if /bin/launchctl print "gui/$USER_ID/$expected_label" >/dev/null 2>&1; then
          finish 1 failed legacy_agent_remove_failed "旧版自动目录监听仍在运行；未继续卸载。"
        fi
      fi
      /bin/rm -f "$candidate"
      if [ "$remove_patcher" -eq 1 ] &&
         [ -f "$expected_patcher" ] && [ ! -L "$expected_patcher" ]; then
        /bin/rm -f "$expected_patcher"
        /bin/rmdir "$(/usr/bin/dirname "$expected_patcher")" >/dev/null 2>&1 || true
      fi
      say "已移除旧版自动目录监听：${expected_label}。"
    else
      say "发现同名但无法确认属于 ClaudeEasy 的 LaunchAgent，已保留：${expected_label}。"
    fi
  elif /bin/launchctl print "gui/$USER_ID/$expected_label" >/dev/null 2>&1; then
    say "发现同名 LaunchAgent，但缺少可核对的 plist；未停止该服务：${expected_label}。"
    finish 1 failed legacy_agent_unverified "发现无法确认所有权的同名 LaunchAgent；未继续卸载。"
  fi
}

restore_uncommitted_uninstall() {
  [ -e "$UNINSTALL_STAGING" ] || return 0
  [ -d "$UNINSTALL_STAGING" ] && [ ! -L "$UNINSTALL_STAGING" ] ||
    finish 1 failed uninstall_state_unsafe "卸载恢复目录不安全；未继续删除。"
  if [ -f "$UNINSTALL_STAGING/COMMITTED" ]; then
    /bin/rm -rf "$UNINSTALL_STAGING"
    return 0
  fi
  if [ ! -f "$UNINSTALL_STAGING/READY" ]; then
    /bin/rm -rf "$UNINSTALL_STAGING"
    return 0
  fi
  if [ -f "$UNINSTALL_STAGING/AUTO_UPDATE_WAS_OWNED" ]; then
    [ -f "$PATCHER_SOURCE" ] ||
      finish 6 failed incomplete_package "安装包不完整，无法恢复未完成的安全卸载。"
    if ! disable_result=$(/usr/bin/ruby "$PATCHER_SOURCE" \
      --backup-dir "$BACKUP_DIR" --disable-subscription-auto-update 2>/dev/null); then
      finish 1 failed auto_update_rollback_failed "无法恢复未完成安全卸载的订阅自动更新状态。"
    fi
    case "$disable_result" in
      disabled|already_disabled) ;;
      *) finish 1 failed auto_update_rollback_failed "订阅自动更新回退结果异常。" ;;
    esac
    [ -f "$AUTO_UPDATE_OWNERSHIP_PATH" ] && [ ! -L "$AUTO_UPDATE_OWNERSHIP_PATH" ] ||
      finish 1 failed auto_update_rollback_failed "订阅自动更新所有权未能恢复。"
  fi
  restore_slot "$UNINSTALL_STAGING/patcher" "$INSTALL_DIR/patch_profiles.rb"
  restore_slot "$UNINSTALL_STAGING/policy" "$INSTALL_DIR/policy.json"
  restore_slot "$UNINSTALL_STAGING/state" "$STATE_PATH"
  restore_slot "$UNINSTALL_STAGING/usage" "$USAGE_STATE_PATH"
  restore_slot "$UNINSTALL_STAGING/log" "$INSTALL_DIR/patch.log"
  restore_slot "$UNINSTALL_STAGING/error-log" "$INSTALL_DIR/patch-error.log"
  /bin/rm -rf "$UNINSTALL_STAGING"
}

recover_pending_profile_transaction() {
  if [ ! -e "$PROFILE_TRANSACTION_PATH" ] && [ ! -L "$PROFILE_TRANSACTION_PATH" ] &&
     [ ! -e "$LEGACY_PROFILE_TRANSACTION_PATH" ] && [ ! -L "$LEGACY_PROFILE_TRANSACTION_PATH" ]; then
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
  if [ -e "$PROFILE_TRANSACTION_PATH" ] || [ -L "$PROFILE_TRANSACTION_PATH" ] ||
     [ -e "$LEGACY_PROFILE_TRANSACTION_PATH" ] || [ -L "$LEGACY_PROFILE_TRANSACTION_PATH" ]; then
    finish 1 failed profile_transaction_recovery_failed "配置事务恢复记录仍然存在；未继续卸载。"
  fi
  say "已先恢复上次中断的配置事务和当前运行配置。"
}

restore_slot() {
  slot=$1
  destination=$2
  [ -f "$slot" ] || return 0
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    /usr/bin/cmp -s "$slot" "$destination" ||
      finish 1 failed uninstall_restore_conflict "卸载中断后检测到新文件；未覆盖。"
    return 0
  fi
  /bin/mkdir -p "$(/usr/bin/dirname "$destination")"
  if /bin/ln "$slot" "$destination"; then
    return 0
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    /usr/bin/cmp -s "$slot" "$destination" ||
      finish 1 failed uninstall_restore_conflict "卸载中断后检测到新文件；未覆盖。"
    return 0
  fi
  finish 1 failed uninstall_restore_failed "卸载文件无法原子恢复；保留恢复目录以便重试。"
}

stage_slot() {
  source=$1
  slot=$2
  if [ ! -e "$source" ] && [ ! -L "$source" ]; then
    /usr/bin/printf '%s\n' absent >"$UNINSTALL_STAGING/$slot.meta"
    return 0
  fi
  [ -f "$source" ] && [ ! -L "$source" ] ||
    finish 1 failed uninstall_target_unsafe "卸载目标不是安全的普通文件；未删除。"
  source_identity=$(/usr/bin/stat -f '%d:%i' "$source")
  /usr/bin/printf 'present:%s\n' "$source_identity" >"$UNINSTALL_STAGING/$slot.meta"
  /bin/cp -p "$source" "$UNINSTALL_STAGING/$slot"
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

delete_staged_install_files() {
  if [ -e "$UNINSTALL_STAGING" ] || [ -L "$UNINSTALL_STAGING" ]; then
    finish 1 failed uninstall_state_conflict "卸载恢复目录已存在；未继续删除。"
  fi
  /bin/mkdir -p "$UNINSTALL_STAGING"
  /bin/chmod 700 "$UNINSTALL_STAGING"
  stage_slot "$INSTALL_DIR/patch_profiles.rb" patcher
  stage_slot "$INSTALL_DIR/policy.json" policy
  stage_slot "$STATE_PATH" state
  stage_slot "$USAGE_STATE_PATH" usage
  stage_slot "$INSTALL_DIR/patch.log" log
  stage_slot "$INSTALL_DIR/patch-error.log" error-log
  if [ -e "$AUTO_UPDATE_OWNERSHIP_PATH" ] || [ -L "$AUTO_UPDATE_OWNERSHIP_PATH" ]; then
    [ -f "$AUTO_UPDATE_OWNERSHIP_PATH" ] && [ ! -L "$AUTO_UPDATE_OWNERSHIP_PATH" ] ||
      finish 1 failed auto_update_state_unsafe "订阅自动更新所有权状态不安全；未继续卸载。"
    /usr/bin/touch "$UNINSTALL_STAGING/AUTO_UPDATE_WAS_OWNED"
  fi
  /usr/bin/touch "$UNINSTALL_STAGING/READY"

  if ! verify_staged_slot "$INSTALL_DIR/patch_profiles.rb" patcher ||
     ! verify_staged_slot "$INSTALL_DIR/policy.json" policy ||
     ! verify_staged_slot "$STATE_PATH" state ||
     ! verify_staged_slot "$USAGE_STATE_PATH" usage ||
     ! verify_staged_slot "$INSTALL_DIR/patch.log" log ||
     ! verify_staged_slot "$INSTALL_DIR/patch-error.log" error-log; then
    /bin/rm -rf "$UNINSTALL_STAGING"
    finish 1 failed uninstall_state_conflict "卸载目标在暂存后被替换；未删除新文件。"
  fi

  /bin/rm -f \
    "$INSTALL_DIR/patch_profiles.rb" \
    "$INSTALL_DIR/policy.json" \
    "$STATE_PATH" \
    "$USAGE_STATE_PATH" \
    "$INSTALL_DIR/patch.log" \
    "$INSTALL_DIR/patch-error.log"
  for removed in \
    "$INSTALL_DIR/patch_profiles.rb" \
    "$INSTALL_DIR/policy.json" \
    "$STATE_PATH" \
    "$USAGE_STATE_PATH" \
    "$INSTALL_DIR/patch.log" \
    "$INSTALL_DIR/patch-error.log"; do
    if [ -e "$removed" ] || [ -L "$removed" ]; then
      restore_uncommitted_uninstall
      finish 1 failed uninstall_delete_failed "安装文件未能整批删除，已恢复其余文件。"
    fi
  done
}

commit_staged_install_files() {
  /usr/bin/touch "$UNINSTALL_STAGING/COMMITTED"
  /bin/rm -rf "$UNINSTALL_STAGING"
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

# 旧版目录被改名之前，先移除能确认所有权的旧监听，避免它在迁移期间继续写入。
remove_owned_agent \
  "$LEGACY_PATCH_PLIST" "$LEGACY_PATCH_LABEL" \
  "$LEGACY_PATCHER_CURRENT_PATH" "$LEGACY_PATCHER_OLD_PATH" 0
remove_owned_agent "$LEGACY_PLIST" "$LEGACY_LABEL" "$LEGACY_PATCHER" "" 1

migrate_legacy_state_under_lock
recover_pending_profile_transaction
restore_uncommitted_uninstall

remove_owned_agent \
  "$LEGACY_PATCH_PLIST" "$LEGACY_PATCH_LABEL" \
  "$LEGACY_PATCHER_CURRENT_PATH" "$LEGACY_PATCHER_OLD_PATH" 0
remove_owned_agent "$LEGACY_PLIST" "$LEGACY_LABEL" "$LEGACY_PATCHER" "" 1

AUTO_UPDATE_OWNED=0
if [ -e "$AUTO_UPDATE_OWNERSHIP_PATH" ] || [ -L "$AUTO_UPDATE_OWNERSHIP_PATH" ]; then
  if [ ! -f "$PATCHER_SOURCE" ]; then
    say "安装包不完整，无法安全恢复订阅自动更新；未删除用途档位。"
    finish 6 failed incomplete_package "安装包不完整，无法安全恢复订阅自动更新。"
  fi
  AUTO_UPDATE_OWNED=1
fi

delete_staged_install_files

AUTO_UPDATE_RESTORED=0
if [ "$AUTO_UPDATE_OWNED" -eq 1 ]; then
  if ! auto_update_restore=$(/usr/bin/ruby "$PATCHER_SOURCE" \
    --backup-dir "$BACKUP_DIR" --restore-owned-subscription-auto-update 2>/dev/null); then
    restore_uncommitted_uninstall
    say "无法恢复本工具关闭的订阅自动更新；未删除用途档位和所有权状态。"
    finish 1 failed auto_update_restore_failed "无法恢复本工具关闭的订阅自动更新；未删除用途档位。"
  fi
  case "$auto_update_restore" in
    restored|already_restored)
      if [ -e "$AUTO_UPDATE_OWNERSHIP_PATH" ] || [ -L "$AUTO_UPDATE_OWNERSHIP_PATH" ]; then
        restore_uncommitted_uninstall
        say "订阅自动更新虽已处理，但所有权状态未能清除；未删除用途档位。"
        finish 1 partial auto_update_state_cleanup_failed "订阅自动更新已处理，但所有权状态未能清除。"
      fi
      AUTO_UPDATE_RESTORED=1
      ;;
    *)
      restore_uncommitted_uninstall
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
