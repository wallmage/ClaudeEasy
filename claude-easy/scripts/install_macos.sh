#!/bin/sh
set -eu
set -f

CUSTOM_PROFILE_DIR="${CLAUDE_EASY_PROFILE_DIR:-}"
INSTALL_DIR="$HOME/Library/Application Support/ClaudeEasy"
BACKUP_DIR="$INSTALL_DIR/backups"
AUTO_UPDATE_OWNERSHIP_PATH="$BACKUP_DIR/clashx-meta-kAutoUpdateEnable.state.json"
USAGE_STATE_PATH="$INSTALL_DIR/usage-profile.plist"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCHER_SOURCE="$SCRIPT_DIR/macos/patch_profiles.rb"
RESULT_CONTRACT_SOURCE="$SCRIPT_DIR/macos/result_contract.rb"
OPERATION_LOCK_SOURCE="$SCRIPT_DIR/macos/operation_lock.rb"
USAGE_PROFILE_STATE_SOURCE="$SCRIPT_DIR/macos/usage_profile_state.rb"
OPERATION_LOCK_PATH="$BACKUP_DIR/.claude-easy-wrapper.lock"
UNINSTALLER_SOURCE="$SCRIPT_DIR/uninstall_macos.sh"
UNINSTALL_STAGING="$INSTALL_DIR/.claude-easy-uninstall-staging"
POLICY_SOURCE="$SCRIPT_DIR/../references/policy.json"
USAGE_PROFILE=""
PROFILE_SOURCE=""
SHOW_PROFILE=0
SAFE_UPDATE=0
JSON_OUTPUT=0
OPERATION="install"
AUTO_UPDATE_RECOVERY_REQUIRED=0
AUTO_UPDATE_RECOVERY_PENDING=0
AUTO_UPDATE_OPERATION_SIGNAL=0
PENDING_TEMPORARY=""
PREVIOUS_PROFILE=""
PROFILE_STATE_CHANGED=0
PROFILE_OPERATION_COMMITTED=0
PROFILE_OPERATION_RECOVERY_INTENT=0
PROFILE_OPERATION_SIGNAL=0
PROFILE_OPERATION_CHILD_FINISHED=0
PROFILE_OPERATION_CHILD_STATUS=0
PROFILE_OPERATION_RECEIPT_PATH=""
PROFILE_OPERATION_RECEIPT_NONCE=""
PROFILE_OPERATION_RECEIPT_COMMITTED=0
PROFILE_OPERATION_RECEIPT_INVALID=0
PROFILE_OPERATION_RESULT_FAILED=0
PROFILE_OPERATION_RESULT_UNKNOWN=0
OPERATION_LOCK_REQUIRED=1
child_json=""

valid_child_json() {
  /usr/bin/printf '%s' "$child_json" | /usr/bin/ruby -e '
    require ARGV.fetch(0)
    exit ClaudeEasyResult.valid_child_json?(STDIN.read) ? 0 : 1
  ' "$RESULT_CONTRACT_SOURCE"
}

restore_auto_update_if_required() {
  [ "$AUTO_UPDATE_RECOVERY_REQUIRED" -eq 1 ] || return 0
  restore_result=$(/usr/bin/ruby "$PATCHER_SOURCE" \
    --backup-dir "$BACKUP_DIR" --restore-owned-subscription-auto-update 2>&1) || return 1
  case "$restore_result" in
    restored|already_restored|not_owned)
      AUTO_UPDATE_RECOVERY_REQUIRED=0
      return 0
      ;;
    *) return 1 ;;
  esac
}

unexpected_exit() {
  unexpected_status=$1
  trap - EXIT HUP INT TERM
  [ "$unexpected_status" -ne 0 ] || return 0
  set +e
  [ -z "$PENDING_TEMPORARY" ] || /bin/rm -f "$PENDING_TEMPORARY"
  [ -z "$PROFILE_OPERATION_RECEIPT_PATH" ] ||
    /bin/rm -f "$PROFILE_OPERATION_RECEIPT_PATH"
  profile_restore_failed=0
  auto_update_restore_failed=0
  restore_auto_update_if_required >/dev/null 2>&1 || auto_update_restore_failed=1
  if [ "$auto_update_restore_failed" -eq 1 ]; then
    AUTO_UPDATE_RECOVERY_PENDING=1
    commit_profile_selection
  elif [ "$PROFILE_STATE_CHANGED" -eq 1 ]; then
    rollback_profile_selection || profile_restore_failed=1
  fi
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if [ -x /usr/bin/ruby ] && [ -f "$RESULT_CONTRACT_SOURCE" ]; then
      if [ "$PROFILE_OPERATION_COMMITTED" -eq 1 ]; then
        /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$OPERATION" --ok false --status partial \
          --code operation_committed_interrupted --exit-code "$unexpected_status" \
          --summary "配置已经提交；返回成功结果前收到中断，保存档位和自动更新状态保持不变。"
      elif [ "$PROFILE_OPERATION_RECOVERY_INTENT" -eq 1 ]; then
        /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$OPERATION" --ok false --status partial \
          --code operation_interrupted_recovery_intent --exit-code "$unexpected_status" \
          --summary "最终处理被中断；保存档位和自动更新关闭状态已经保留，下次运行将按该档位继续。"
      elif [ "$profile_restore_failed" -eq 1 ] && [ "$auto_update_restore_failed" -eq 1 ]; then
        /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$OPERATION" --ok false --status partial \
          --code state_restore_failed --exit-code "$unexpected_status" \
          --summary "安装流程意外中止，且旧用途档位与订阅自动更新均未能完整恢复。"
      elif [ "$auto_update_restore_failed" -eq 1 ]; then
        /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$OPERATION" --ok false --status partial \
          --code auto_update_restore_failed --exit-code "$unexpected_status" \
          --summary "安装流程意外中止；已保留当前档位，但订阅自动更新仍需重试恢复。"
      elif [ "$AUTO_UPDATE_RECOVERY_PENDING" -eq 1 ]; then
        /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$OPERATION" --ok false --status partial \
          --code auto_update_recovery_pending --exit-code "$unexpected_status" \
          --summary "订阅自动更新尚未达到当前档位的完整状态；已保留恢复记录，请按当前档位重试。"
      elif [ "$profile_restore_failed" -eq 1 ]; then
        /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$OPERATION" --ok false --status partial \
          --code profile_restore_failed --exit-code "$unexpected_status" --summary "安装流程意外中止，且旧用途档位未能恢复。"
      else
        /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$OPERATION" --ok false --status failed \
          --code unexpected_exit --exit-code "$unexpected_status" --summary "安装流程意外中止。"
      fi
    fi
  else
    if [ "$PROFILE_OPERATION_COMMITTED" -eq 1 ]; then
      /usr/bin/printf '%s\n' "[ClaudeEasy] 配置已经提交；返回成功结果前收到中断，保存档位和自动更新状态保持不变。"
    elif [ "$PROFILE_OPERATION_RECOVERY_INTENT" -eq 1 ]; then
      /usr/bin/printf '%s\n' "[ClaudeEasy] 最终处理被中断；保存档位和自动更新关闭状态已经保留，下次运行将按该档位继续。"
    elif [ "$profile_restore_failed" -eq 1 ] && [ "$auto_update_restore_failed" -eq 1 ]; then
      /usr/bin/printf '%s\n' "[ClaudeEasy] 安装流程意外中止，且旧用途档位与订阅自动更新均未能完整恢复。"
    elif [ "$auto_update_restore_failed" -eq 1 ]; then
      /usr/bin/printf '%s\n' "[ClaudeEasy] 安装流程意外中止；已保留当前档位，但订阅自动更新仍需重试恢复。"
    elif [ "$AUTO_UPDATE_RECOVERY_PENDING" -eq 1 ]; then
      /usr/bin/printf '%s\n' "[ClaudeEasy] 订阅自动更新尚未达到当前档位的完整状态；已保留恢复记录，请按当前档位重试。"
    elif [ "$profile_restore_failed" -eq 1 ]; then
      /usr/bin/printf '%s\n' "[ClaudeEasy] 安装流程意外中止，且旧用途档位未能恢复。"
    else
      /usr/bin/printf '%s\n' "[ClaudeEasy] 安装流程意外中止；已尝试恢复用途档位与订阅自动更新。"
    fi
  fi
  exit "$unexpected_status"
}

trap 'unexpected_exit $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for argument do
  [ "$argument" = "--json" ] && JSON_OUTPUT=1
  [ "$argument" = "--safe-update" ] && OPERATION="safe_update"
  case "$argument" in
    --show-profile|-h|--help) OPERATION_LOCK_REQUIRED=0 ;;
  esac
done

finish() {
  finish_exit=$1
  finish_status=$2
  finish_code=$3
  finish_summary=$4
  finish_operation=${5:-$OPERATION}
  finish_profile=${6:-$USAGE_PROFILE}
  if [ "$finish_exit" -ne 0 ]; then
    auto_update_restore_failed=0
    restore_auto_update_if_required || auto_update_restore_failed=1
    if [ "$auto_update_restore_failed" -eq 1 ]; then
      AUTO_UPDATE_RECOVERY_PENDING=1
      commit_profile_selection
    elif [ "$PROFILE_STATE_CHANGED" -eq 1 ] && ! rollback_profile_selection; then
      finish_status=partial
      finish_code=profile_restore_failed
      finish_summary="操作失败，且旧用途档位未能恢复。"
    fi
    if [ "$auto_update_restore_failed" -eq 1 ]; then
      finish_status=partial
      finish_code=auto_update_restore_failed
      finish_summary="操作失败；已保留当前档位，但订阅自动更新仍需重试恢复。"
    elif [ "$AUTO_UPDATE_RECOVERY_PENDING" -eq 1 ]; then
      finish_status=partial
      finish_code=auto_update_recovery_pending
      finish_summary="订阅自动更新尚未达到当前档位的完整状态；已保留恢复记录，请按当前档位重试。"
    fi
  fi
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if [ -x /usr/bin/ruby ] && [ -f "$RESULT_CONTRACT_SOURCE" ]; then
      if [ -n "$child_json" ] && ! valid_child_json; then
        child_json=""
      fi
      if [ -n "$child_json" ] && [ -n "$finish_profile" ]; then
        /usr/bin/printf '%s' "$child_json" | /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$finish_operation" --ok "$([ "$finish_exit" -eq 0 ] && /usr/bin/printf true || /usr/bin/printf false)" \
          --status "$finish_status" --code "$finish_code" --exit-code "$finish_exit" --summary "$finish_summary" \
          --profile "$finish_profile" --merge-child-stdin
      elif [ -n "$child_json" ]; then
        /usr/bin/printf '%s' "$child_json" | /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$finish_operation" --ok "$([ "$finish_exit" -eq 0 ] && /usr/bin/printf true || /usr/bin/printf false)" \
          --status "$finish_status" --code "$finish_code" --exit-code "$finish_exit" --summary "$finish_summary" \
          --merge-child-stdin
      elif [ -n "$finish_profile" ]; then
        /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$finish_operation" --ok "$([ "$finish_exit" -eq 0 ] && /usr/bin/printf true || /usr/bin/printf false)" \
          --status "$finish_status" --code "$finish_code" --exit-code "$finish_exit" --summary "$finish_summary" \
          --profile "$finish_profile"
      else
        /usr/bin/ruby "$RESULT_CONTRACT_SOURCE" \
          --command install --operation "$finish_operation" --ok "$([ "$finish_exit" -eq 0 ] && /usr/bin/printf true || /usr/bin/printf false)" \
          --status "$finish_status" --code "$finish_code" --exit-code "$finish_exit" --summary "$finish_summary"
      fi
    else
      /usr/bin/printf '%s\n' "{\"schema\":\"claude-easy.result\",\"version\":1,\"command\":\"install\",\"platform\":\"macos\",\"client\":\"clashx-meta\",\"operation\":\"$finish_operation\",\"ok\":false,\"status\":\"$finish_status\",\"code\":\"$finish_code\",\"exit_code\":$finish_exit,\"summary_zh\":\"$finish_summary\",\"profile\":null,\"changes\":[],\"checks\":[],\"items\":[],\"messages\":[],\"warnings\":[]}"
    fi
  fi
  trap - EXIT HUP INT TERM
  exit "$finish_exit"
}

say() {
  [ "$JSON_OUTPUT" -eq 0 ] || return 0
  /usr/bin/printf '%s\n' "[ClaudeEasy] $1"
}

install_package_complete() {
  for required_package_file in \
    "$UNINSTALLER_SOURCE" \
    "$PATCHER_SOURCE" \
    "$RESULT_CONTRACT_SOURCE" \
    "$OPERATION_LOCK_SOURCE" \
    "$USAGE_PROFILE_STATE_SOURCE" \
    "$POLICY_SOURCE"; do
    [ -f "$required_package_file" ] && [ ! -L "$required_package_file" ] || return 1
  done
  return 0
}

install_package_dependencies_load() {
  /usr/bin/ruby "$PATCHER_SOURCE" --json --help >/dev/null 2>&1
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

record_auto_update_signal() {
  received_signal_status=$1
  [ "$AUTO_UPDATE_OPERATION_SIGNAL" -ne 0 ] ||
    AUTO_UPDATE_OPERATION_SIGNAL=$received_signal_status
}

run_subscription_auto_update_disable() {
  auto_update_output_path=$(
    /usr/bin/mktemp "$BACKUP_DIR/.auto-update-result.XXXXXX"
  ) || return 1
  PENDING_TEMPORARY=$auto_update_output_path
  if ! /bin/chmod 600 "$auto_update_output_path"; then
    /bin/rm -f "$auto_update_output_path"
    PENDING_TEMPORARY=""
    return 1
  fi
  AUTO_UPDATE_OPERATION_SIGNAL=0
  trap 'record_auto_update_signal 129' HUP
  trap 'record_auto_update_signal 130' INT
  trap 'record_auto_update_signal 143' TERM
  set +e
  /usr/bin/ruby "$PATCHER_SOURCE" \
    --backup-dir "$BACKUP_DIR" --usage-profile "$USAGE_PROFILE" \
    --disable-subscription-auto-update >"$auto_update_output_path" 2>&1
  auto_update_status=$?
  set -e
  auto_update_result=$(/bin/cat "$auto_update_output_path" 2>/dev/null || true)
  /bin/rm -f "$auto_update_output_path"
  PENDING_TEMPORARY=""
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ "$AUTO_UPDATE_OPERATION_SIGNAL" -ne 0 ]; then
    exit "$AUTO_UPDATE_OPERATION_SIGNAL"
  fi
  return "$auto_update_status"
}

finish_json_child_failure() {
  child_json=$1
  fallback_status=$2
  fallback_code=$3
  fallback_summary=$4
  child_operation=$5
  child_status=$(/usr/bin/printf '%s' "$child_json" | /usr/bin/ruby -rjson -e 'v=JSON.parse(STDIN.read)[ARGV[0]]; abort unless v.is_a?(String); print v' status 2>/dev/null || true)
  child_code=$(/usr/bin/printf '%s' "$child_json" | /usr/bin/ruby -rjson -e 'v=JSON.parse(STDIN.read)[ARGV[0]]; abort unless v.is_a?(String); print v' code 2>/dev/null || true)
  child_summary=$(/usr/bin/printf '%s' "$child_json" | /usr/bin/ruby -rjson -e 'v=JSON.parse(STDIN.read)[ARGV[0]]; abort unless v.is_a?(String); print v' summary_zh 2>/dev/null || true)
  case "$child_status" in
    failed|partial|rolled_back|invalid_request|unsupported) ;;
    *) child_status="" ;;
  esac
  case "$child_code" in
    *[!a-z0-9_]*) child_code="" ;;
  esac
  if [ -n "$child_status" ] && [ -n "$child_code" ] && [ -n "$child_summary" ]; then
    finish 1 "$child_status" "$child_code" "$child_summary" "$child_operation"
  fi
  child_json=""
  finish 1 "$fallback_status" "$fallback_code" "$fallback_summary" "$child_operation"
}

usage() {
  [ "$JSON_OUTPUT" -eq 0 ] || return 0
  /usr/bin/printf '%s\n' "用法：install_macos.sh [--profile 1|2|3] [--show-profile] [--safe-update]"
}

recover_interrupted_uninstall() {
  if [ ! -e "$UNINSTALL_STAGING" ] && [ ! -L "$UNINSTALL_STAGING" ]; then
    return 0
  fi
  if [ ! -d "$UNINSTALL_STAGING" ] || [ -L "$UNINSTALL_STAGING" ]; then
    finish 1 failed uninstall_recovery_failed "未完成的安全卸载状态不安全；未继续安装。" uninstall_recovery
  fi
  if [ ! -f "$UNINSTALLER_SOURCE" ] || [ -L "$UNINSTALLER_SOURCE" ]; then
    finish 6 failed uninstall_recovery_failed "安装包不完整，无法恢复未完成的安全卸载。" uninstall_recovery
  fi

  set +e
  recovery_json=$(/bin/sh "$UNINSTALLER_SOURCE" --json 2>/dev/null)
  recovery_status=$?
  set -e
  if [ "$recovery_status" -ne 0 ]; then
    finish 1 failed uninstall_recovery_failed "未完成的安全卸载无法恢复；未继续安装。" uninstall_recovery
  fi
  recovery_receipt=$(/usr/bin/printf '%s' "$recovery_json" | /usr/bin/ruby -rjson -e '
    value = JSON.parse(STDIN.read)
    abort unless value.is_a?(Hash) &&
      value["schema"] == "claude-easy.result" &&
      value["version"] == 1 &&
      value["command"] == "uninstall" &&
      value["operation"] == "uninstall" &&
      value["ok"] == true &&
      value["status"] == "ok" &&
      value["code"] == "uninstall_completed" &&
      value["exit_code"] == 0
    print "uninstall_completed"
  ' 2>/dev/null || true)
  if [ "$recovery_receipt" != "uninstall_completed" ]; then
    finish 1 failed uninstall_recovery_failed "未完成的安全卸载返回了无法验证的结果；未继续安装。" uninstall_recovery
  fi
  if [ -e "$UNINSTALL_STAGING" ] || [ -L "$UNINSTALL_STAGING" ]; then
    finish 1 failed uninstall_recovery_failed "未完成的安全卸载状态仍然存在；未继续安装。" uninstall_recovery
  fi
  say "已先完成上次中断的安全卸载。"
}

read_saved_profile() {
  if [ ! -e "$USAGE_STATE_PATH" ] && [ ! -L "$USAGE_STATE_PATH" ]; then
    return 1
  fi
  [ -f "$USAGE_STATE_PATH" ] && [ ! -L "$USAGE_STATE_PATH" ] || return 3
  [ -f "$USAGE_PROFILE_STATE_SOURCE" ] && [ ! -L "$USAGE_PROFILE_STATE_SOURCE" ] || return 4
  [ -x /usr/bin/ruby ] || return 5
  saved_profile_status=0
  saved_profile=$(
    /usr/bin/ruby "$USAGE_PROFILE_STATE_SOURCE" "$USAGE_STATE_PATH" 2>/dev/null
  ) || saved_profile_status=$?
  case "$saved_profile_status" in
    0) ;;
    2) return 2 ;;
    *) return 4 ;;
  esac
  case "$saved_profile" in
    1|2|3) /usr/bin/printf '%s\n' "$saved_profile" ;;
    *) return 2 ;;
  esac
}

load_saved_profile_or_finish() {
  saved_profile_operation=$1
  SAVED_PROFILE=""
  saved_profile_status=0
  SAVED_PROFILE=$(read_saved_profile) || saved_profile_status=$?
  case "$saved_profile_status" in
    0|1) ;;
    2)
      say "已保存的用途档位状态无效，未执行任何修改。"
      finish 10 invalid_request usage_profile_invalid "已保存的用途档位状态无效，未执行任何修改。" "$saved_profile_operation"
      ;;
    4)
      say "安装包不完整。"
      finish 6 failed incomplete_package "安装包不完整。" "$saved_profile_operation"
      ;;
    5)
      say "这台 Mac 没有系统 Ruby，无法读取用途档位。"
      finish 3 unsupported ruby_missing "这台 Mac 没有系统 Ruby，无法读取用途档位。" "$saved_profile_operation"
      ;;
    *)
      say "档位保存位置不安全，未写入任何设置。"
      finish 7 failed unsafe_profile_state "档位保存位置不安全，未写入任何设置。" "$saved_profile_operation"
      ;;
  esac
}

profile_state_is_safe() {
  state_dir=$(/usr/bin/dirname "$USAGE_STATE_PATH")
  if [ -L "$state_dir" ] || [ -L "$USAGE_STATE_PATH" ] ||
     { [ -e "$USAGE_STATE_PATH" ] && [ ! -f "$USAGE_STATE_PATH" ]; }; then
    return 1
  fi
  return 0
}

assert_profile_state_safe() {
  profile_state_is_safe && return 0
  say "档位保存位置不安全，未写入任何设置。"
  finish 7 failed unsafe_profile_state "档位保存位置不安全，未写入任何设置。" save_profile
}

write_profile() {
  profile_to_write=$1
  profile_state_is_safe || return 1
  state_dir=$(/usr/bin/dirname "$USAGE_STATE_PATH")
  durable_ensure_private_directory "$state_dir"
  temporary=$(/usr/bin/mktemp "$state_dir/.usage-profile.XXXXXX")
  PENDING_TEMPORARY=$temporary
  trap '/bin/rm -f "$temporary"; exit 1' HUP INT TERM
  /usr/bin/plutil -create xml1 "$temporary"
  /usr/bin/plutil -insert Version -integer 1 "$temporary"
  /usr/bin/plutil -insert Profile -integer "$profile_to_write" "$temporary"
  /bin/chmod 600 "$temporary"
  /bin/mv -f "$temporary" "$USAGE_STATE_PATH"
  PROFILE_STATE_CHANGED=1
  PENDING_TEMPORARY=""
  durable_sync_file "$USAGE_STATE_PATH"
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

save_profile() {
  assert_profile_state_safe
  write_profile "$USAGE_PROFILE"
}

rollback_profile_selection() {
  [ "$PROFILE_STATE_CHANGED" -eq 1 ] || return 0
  profile_state_is_safe || return 1
  current_profile=$(read_saved_profile || true)
  [ "$current_profile" = "$USAGE_PROFILE" ] || return 1
  if [ -n "$PREVIOUS_PROFILE" ]; then
    write_profile "$PREVIOUS_PROFILE" || return 1
  else
    /bin/rm -f "$USAGE_STATE_PATH" || return 1
    durable_sync_directory "$(/usr/bin/dirname "$USAGE_STATE_PATH")" || return 1
  fi
  PROFILE_STATE_CHANGED=0
}

stage_profile_selection() {
  [ "$PROFILE_SOURCE" != "saved" ] || return 0
  save_profile
}

commit_profile_selection() {
  [ "$PROFILE_STATE_CHANGED" -eq 1 ] || return 0
  PROFILE_STATE_CHANGED=0
  say "已保存用途档位 ${USAGE_PROFILE}。"
}

preserve_profile_operation_state() {
  commit_profile_selection
  AUTO_UPDATE_RECOVERY_REQUIRED=0
  AUTO_UPDATE_RECOVERY_PENDING=0
}

finish_profile_operation_signal() {
  trap '' HUP INT TERM
  preserve_profile_operation_state
  if [ "$PROFILE_OPERATION_CHILD_STATUS" -eq 0 ] ||
     [ "$PROFILE_OPERATION_RECEIPT_COMMITTED" -eq 1 ]; then
    PROFILE_OPERATION_COMMITTED=1
  else
    PROFILE_OPERATION_RECOVERY_INTENT=1
  fi
  exit "$PROFILE_OPERATION_SIGNAL"
}

record_profile_operation_signal() {
  received_signal_status=$1
  [ "$PROFILE_OPERATION_SIGNAL" -ne 0 ] ||
    PROFILE_OPERATION_SIGNAL=$received_signal_status
  if [ "$PROFILE_OPERATION_CHILD_FINISHED" -eq 1 ]; then
    finish_profile_operation_signal
  fi
}

run_committing_profile_operation() {
  child_output_path=""
  child_json=""
  PROFILE_OPERATION_RECEIPT_NONCE=$(
    /usr/bin/uuidgen |
      /usr/bin/tr '[:upper:]' '[:lower:]' |
      /usr/bin/tr -d '-'
  ) || return 1
  case "$PROFILE_OPERATION_RECEIPT_NONCE" in
    ""|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#PROFILE_OPERATION_RECEIPT_NONCE}" -eq 32 ] || return 1
  PROFILE_OPERATION_RECEIPT_PATH=$(
    /usr/bin/mktemp "$BACKUP_DIR/.profile-operation-receipt.XXXXXX"
  ) || return 1
  if ! /usr/bin/printf '0:%s\n' "$PROFILE_OPERATION_RECEIPT_NONCE" \
      >"$PROFILE_OPERATION_RECEIPT_PATH" ||
     ! /bin/chmod 600 "$PROFILE_OPERATION_RECEIPT_PATH"; then
    /bin/rm -f "$PROFILE_OPERATION_RECEIPT_PATH"
    PROFILE_OPERATION_RECEIPT_PATH=""
    return 1
  fi
  PROFILE_OPERATION_RECEIPT_COMMITTED=0
  PROFILE_OPERATION_RECEIPT_INVALID=0
  PROFILE_OPERATION_RESULT_FAILED=0
  PROFILE_OPERATION_RESULT_UNKNOWN=0
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if ! child_output_path=$(
      /usr/bin/mktemp "$BACKUP_DIR/.profile-operation-result.XXXXXX"
    ); then
      /bin/rm -f "$PROFILE_OPERATION_RECEIPT_PATH"
      PROFILE_OPERATION_RECEIPT_PATH=""
      return 1
    fi
    PENDING_TEMPORARY=$child_output_path
    if ! /bin/chmod 600 "$child_output_path"; then
      /bin/rm -f "$child_output_path" "$PROFILE_OPERATION_RECEIPT_PATH"
      PENDING_TEMPORARY=""
      PROFILE_OPERATION_RECEIPT_PATH=""
      return 1
    fi
  fi

  PROFILE_OPERATION_SIGNAL=0
  PROFILE_OPERATION_CHILD_FINISHED=0
  PROFILE_OPERATION_CHILD_STATUS=0
  trap 'record_profile_operation_signal 129' HUP
  trap 'record_profile_operation_signal 130' INT
  trap 'record_profile_operation_signal 143' TERM
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if /usr/bin/ruby "$PATCHER_SOURCE" "$@" \
        --wrapper-commit-receipt "$PROFILE_OPERATION_RECEIPT_PATH" \
        --wrapper-commit-nonce "$PROFILE_OPERATION_RECEIPT_NONCE" \
        --json >"$child_output_path" 2>/dev/null; then
      PROFILE_OPERATION_CHILD_STATUS=0
    else
      PROFILE_OPERATION_CHILD_STATUS=$?
    fi
    child_json=$(/bin/cat "$child_output_path" 2>/dev/null || true)
    /bin/rm -f "$child_output_path"
    PENDING_TEMPORARY=""
  else
    if /usr/bin/ruby "$PATCHER_SOURCE" "$@" \
        --wrapper-commit-receipt "$PROFILE_OPERATION_RECEIPT_PATH" \
        --wrapper-commit-nonce "$PROFILE_OPERATION_RECEIPT_NONCE"; then
      PROFILE_OPERATION_CHILD_STATUS=0
    else
      PROFILE_OPERATION_CHILD_STATUS=$?
    fi
  fi

  receipt_value=$(/bin/cat "$PROFILE_OPERATION_RECEIPT_PATH" 2>/dev/null || true)
  case "$receipt_value" in
    "1:$PROFILE_OPERATION_RECEIPT_NONCE") PROFILE_OPERATION_RECEIPT_COMMITTED=1 ;;
    "0:$PROFILE_OPERATION_RECEIPT_NONCE") ;;
    *) PROFILE_OPERATION_RECEIPT_INVALID=1 ;;
  esac
  /bin/rm -f "$PROFILE_OPERATION_RECEIPT_PATH"
  PROFILE_OPERATION_RECEIPT_PATH=""
  PROFILE_OPERATION_CHILD_FINISHED=1
  if [ "$PROFILE_OPERATION_SIGNAL" -ne 0 ]; then
    finish_profile_operation_signal
  fi
  if [ "$PROFILE_OPERATION_CHILD_STATUS" -eq 0 ] ||
     [ "$PROFILE_OPERATION_RECEIPT_COMMITTED" -eq 1 ]; then
    preserve_profile_operation_state
    PROFILE_OPERATION_COMMITTED=1
    if [ "$PROFILE_OPERATION_CHILD_STATUS" -ne 0 ]; then
      PROFILE_OPERATION_RESULT_FAILED=1
    fi
  elif [ "$PROFILE_OPERATION_CHILD_STATUS" -eq 75 ]; then
    preserve_profile_operation_state
    PROFILE_OPERATION_COMMITTED=1
    PROFILE_OPERATION_RESULT_FAILED=1
  elif [ "$PROFILE_OPERATION_CHILD_STATUS" -eq 77 ]; then
    preserve_profile_operation_state
    PROFILE_OPERATION_RECOVERY_INTENT=1
    PROFILE_OPERATION_RESULT_UNKNOWN=1
  elif [ "$PROFILE_OPERATION_RECEIPT_INVALID" -eq 1 ] ||
       [ "$PROFILE_OPERATION_CHILD_STATUS" -ge 128 ]; then
    preserve_profile_operation_state
    PROFILE_OPERATION_RECOVERY_INTENT=1
    PROFILE_OPERATION_RESULT_UNKNOWN=1
  fi
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  return "$PROFILE_OPERATION_CHILD_STATUS"
}

finish_profile_operation_result_failure() {
  if [ "$PROFILE_OPERATION_RESULT_FAILED" -eq 1 ]; then
    finish 1 partial operation_committed_result_failed \
      "配置已经提交，但结果传输失败；保存档位和自动更新状态保持不变，请按同一档位重试。" \
      "$OPERATION"
  fi
  [ "$PROFILE_OPERATION_RESULT_UNKNOWN" -eq 1 ] || return 0
  finish 1 partial operation_result_unknown_recovery_intent \
    "无法确认配置是否提交；保存档位和自动更新状态保持不变，请按同一档位重试以完成恢复。" \
    "$OPERATION"
}

parse_arguments() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --profile)
        [ "$#" -ge 2 ] || { usage; finish 64 invalid_request missing_profile_value "--profile 缺少档位值。" parse_arguments; }
        USAGE_PROFILE=$2
        PROFILE_SOURCE="argument"
        shift 2
        ;;
      --show-profile)
        SHOW_PROFILE=1
        shift
        ;;
      --safe-update)
        SAFE_UPDATE=1
        OPERATION="safe_update"
        shift
        ;;
      --json)
        JSON_OUTPUT=1
        shift
        ;;
      -h|--help)
        usage
        finish 0 ok help "已显示帮助。" help
        ;;
      *)
        usage
        finish 64 invalid_request invalid_arguments "参数错误。" parse_arguments
        ;;
    esac
  done
}

resolve_usage_profile() {
  load_saved_profile_or_finish select_profile
  if [ "$SAFE_UPDATE" -eq 1 ]; then
    if [ -z "$SAVED_PROFILE" ]; then
      say "还没有选择用途档位。"
      USAGE_PROFILE=""
      finish 10 invalid_request usage_profile_required "还没有选择用途档位。" safe_update
    fi
    if [ -n "$USAGE_PROFILE" ] && [ "$USAGE_PROFILE" != "$SAVED_PROFILE" ]; then
      say "请求档位与已保存档位不一致；未执行安全更新。"
      USAGE_PROFILE=""
      finish 64 invalid_request usage_profile_mismatch \
        "请求档位与已保存档位不一致；未执行安全更新。" safe_update
    fi
    USAGE_PROFILE=$SAVED_PROFILE
    PROFILE_SOURCE="saved"
  fi
  if [ -z "$USAGE_PROFILE" ]; then
    USAGE_PROFILE=$SAVED_PROFILE
    PROFILE_SOURCE="saved"
  fi
  case "$USAGE_PROFILE" in
    1|2|3) ;;
    "")
      say "还没有选择用途档位。请先在 skill 中选择：1 普通浏览、2 海外 AI、3 Claude/Claude Code。"
      finish 10 invalid_request profile_required "还没有选择用途档位。" select_profile
      ;;
    *)
      say "用途档位无效，只能是 1、2 或 3。"
      finish 64 invalid_request invalid_profile "用途档位无效，只能是 1、2 或 3。" select_profile
      ;;
  esac

  PREVIOUS_PROFILE=$SAVED_PROFILE
  if [ "$PREVIOUS_PROFILE" = "3" ] && [ "$USAGE_PROFILE" != "3" ] &&
     [ "$PROFILE_SOURCE" != "saved" ]; then
    say "从档位 3 改为轻量档位前，必须先运行安全卸载。"
    finish 1 failed safe_uninstall_required "从档位 3 降档前必须先运行安全卸载。" install
  fi
}

parse_arguments "$@"

operation_count=0
[ "$SHOW_PROFILE" -eq 1 ] && operation_count=$((operation_count + 1))
[ "$SAFE_UPDATE" -eq 1 ] && operation_count=$((operation_count + 1))
if [ "$operation_count" -gt 1 ]; then
  finish 64 invalid_request conflicting_operations "一次只能执行一个操作。" parse_arguments
fi
if [ "$SHOW_PROFILE" -eq 1 ] && [ -n "$USAGE_PROFILE" ]; then
  finish 64 invalid_request conflicting_operations "读取档位时不能同时保存新档位。" parse_arguments
fi

if [ "$SHOW_PROFILE" -eq 1 ]; then
  OPERATION="show_profile"
  load_saved_profile_or_finish show_profile
  saved_profile=$SAVED_PROFILE
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if [ -n "$saved_profile" ]; then
      finish 0 ok profile_set "已读取用途档位。" show_profile "$saved_profile"
    else
      finish 0 no_change profile_unset "尚未保存用途档位。" show_profile ""
    fi
  fi
  [ -n "$saved_profile" ] && /usr/bin/printf '%s\n' "$saved_profile" || /usr/bin/printf '%s\n' "unset"
  exit 0
fi

if [ -z "$USAGE_PROFILE" ] && [ -n "${CLAUDE_EASY_USAGE_PROFILE:-}" ]; then
  USAGE_PROFILE=$CLAUDE_EASY_USAGE_PROFILE
  PROFILE_SOURCE="environment"
fi
if [ -n "$USAGE_PROFILE" ]; then
  case "$USAGE_PROFILE" in
    1|2|3) ;;
    *)
      say "用途档位无效，只能是 1、2 或 3。"
      finish 64 invalid_request invalid_profile "用途档位无效，只能是 1、2 或 3。" select_profile
      ;;
  esac
fi

if [ "$OPERATION_LOCK_REQUIRED" -eq 1 ]; then
  load_saved_profile_or_finish select_profile
  if ! install_package_complete; then
    say "安装包不完整。"
    finish 6 failed incomplete_package "安装包不完整。" install
  fi
  if [ "$(uname -s)" != "Darwin" ]; then
    say "当前系统不是 macOS。Windows 请使用 Clash Verge Rev 的 Windows 安装程序。"
    finish 2 unsupported unsupported_platform "当前系统不是 macOS。" install
  fi
  lock_user_id=$(/usr/bin/id -u)
  if [ "$lock_user_id" -eq 0 ]; then
    say "请不要使用 sudo 或 root；请用当前登录用户直接运行。"
    finish 2 invalid_request root_not_allowed "请用当前登录用户直接运行。" install
  fi
  if [ ! -x /usr/bin/ruby ]; then
    say "这台 Mac 没有系统 Ruby，无法运行补丁。"
    finish 3 unsupported ruby_missing "这台 Mac 没有系统 Ruby，无法运行补丁。" install
  fi
  if ! install_package_dependencies_load; then
    say "安装包不完整。"
    finish 6 failed incomplete_package "安装包不完整。" install
  fi
  if [ "${CLAUDE_EASY_INTERNAL_OPERATION_LOCK_HELD:-0}" = "1" ]; then
    if ! /usr/bin/ruby "$OPERATION_LOCK_SOURCE" \
        --verify-held-lock "$OPERATION_LOCK_PATH"; then
      finish 1 failed operation_lock_failed "无法建立 ClaudeEasy 操作锁；未执行任何修改。" "$OPERATION"
    fi
  else
    trap ':' HUP INT TERM
    set +e
    /usr/bin/ruby "$OPERATION_LOCK_SOURCE" "$OPERATION_LOCK_PATH" /bin/sh "$0" "$@"
    operation_lock_status=$?
    set -e
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    case "$operation_lock_status" in
      75)
        finish 1 failed operation_in_progress "另一个 ClaudeEasy 操作正在进行，请稍后重试。" "$OPERATION"
        ;;
      76)
        finish 1 failed operation_lock_failed "无法建立 ClaudeEasy 操作锁；未执行任何修改。" "$OPERATION"
        ;;
      *)
        trap - EXIT HUP INT TERM
        exit "$operation_lock_status"
        ;;
    esac
  fi
fi

recover_interrupted_uninstall
resolve_usage_profile
if [ "$PROFILE_SOURCE" != "saved" ]; then
  assert_profile_state_safe
fi

if [ "$(uname -s)" != "Darwin" ]; then
  say "当前系统不是 macOS。Windows 请使用 Clash Verge Rev 的 Windows 安装程序。"
  finish 2 unsupported unsupported_platform "当前系统不是 macOS。" install
fi

USER_ID=$(/usr/bin/id -u)
if [ "$USER_ID" -eq 0 ]; then
  say "请不要使用 sudo 或 root；请用当前登录用户直接运行。"
  finish 2 invalid_request root_not_allowed "请用当前登录用户直接运行。" install
fi

if [ ! -x /usr/bin/ruby ]; then
  say "这台 Mac 没有系统 Ruby，无法运行补丁。"
  finish 3 unsupported ruby_missing "这台 Mac 没有系统 Ruby，无法运行补丁。" install
fi

if [ ! -d "/Applications/ClashX Meta.app" ] && [ ! -d "$HOME/Applications/ClashX Meta.app" ]; then
  say "没有找到受支持的 ClashX Meta。"
  finish 4 unsupported client_missing "没有找到受支持的 ClashX Meta。" install
fi

if [ -n "$CUSTOM_PROFILE_DIR" ] && [ ! -d "$CUSTOM_PROFILE_DIR" ]; then
  say "没有找到指定的 ClashX Meta 配置目录。"
  finish 5 failed profile_directory_missing "没有找到指定的 ClashX Meta 配置目录。" install
fi

if ! install_package_complete || ! install_package_dependencies_load; then
  say "安装包不完整。"
  finish 6 failed incomplete_package "安装包不完整。" install
fi

core_status=$(/usr/bin/ruby "$PATCHER_SOURCE" --print-core-status 2>/dev/null || true)
if [ "$core_status" != "supported" ]; then
  case "$core_status" in
    too_old) say "Mihomo 内核版本过旧，需要 1.19.27 或更高版本。" ;;
    timeout) say "Mihomo 内核检查超过 30 秒，未修改任何订阅。" ;;
    *) say "没有找到可用的 Mihomo 内核，或无法确认版本。" ;;
  esac
  finish 8 unsupported mihomo_unavailable "Mihomo 内核不可用或版本不受支持。" core_status
fi

if [ "$PROFILE_SOURCE" != "saved" ]; then
  assert_profile_state_safe
fi

/bin/mkdir -p "$BACKUP_DIR"
/bin/chmod 700 "$INSTALL_DIR" "$BACKUP_DIR"

if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if ! child_json=$(/usr/bin/ruby "$PATCHER_SOURCE" --profile-dir "$CUSTOM_PROFILE_DIR" --backup-dir "$BACKUP_DIR" --snapshot-initial --json 2>/dev/null); then
      finish_json_child_failure "$child_json" failed snapshot_failed "无法创建初始快照。" snapshot_initial
    fi
  else
    /usr/bin/ruby "$PATCHER_SOURCE" --profile-dir "$CUSTOM_PROFILE_DIR" --backup-dir "$BACKUP_DIR" --snapshot-initial ||
      { say "无法创建初始快照。"; finish 1 failed snapshot_failed "无法创建初始快照。" snapshot_initial; }
  fi
else
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if ! child_json=$(/usr/bin/ruby "$PATCHER_SOURCE" --backup-dir "$BACKUP_DIR" --snapshot-initial --json 2>/dev/null); then
      finish_json_child_failure "$child_json" failed snapshot_failed "无法创建初始快照。" snapshot_initial
    fi
  else
    /usr/bin/ruby "$PATCHER_SOURCE" --backup-dir "$BACKUP_DIR" --snapshot-initial ||
      { say "无法创建初始快照。"; finish 1 failed snapshot_failed "无法创建初始快照。" snapshot_initial; }
  fi
fi

child_json=""

stage_profile_selection

if [ -z "$PREVIOUS_PROFILE" ]; then
  AUTO_UPDATE_RECOVERY_REQUIRED=1
fi
if ! run_subscription_auto_update_disable; then
  if [ -n "$PREVIOUS_PROFILE" ]; then
    AUTO_UPDATE_RECOVERY_PENDING=1
  fi
  say "无法完成 ClashX Meta 的订阅自动更新设置；未继续处理订阅文件，请按当前档位重试。"
  finish 9 failed auto_update_failed "无法完成订阅自动更新设置；未继续处理订阅文件。" install
fi
case "$auto_update_result" in
  disabled) say "已自动关闭订阅更新，并保存修改前状态。" ;;
  already_disabled) AUTO_UPDATE_RECOVERY_REQUIRED=0; say "订阅自动更新已经关闭。" ;;
  already_disabled_owned) say "订阅自动更新已经由 ClaudeEasy 关闭。" ;;
  *)
    if [ -n "$PREVIOUS_PROFILE" ]; then
      AUTO_UPDATE_RECOVERY_PENDING=1
    fi
    say "订阅自动更新回读结果异常；未继续处理订阅文件，请按当前档位重试。"
    finish 9 failed auto_update_verify_failed "订阅自动更新回读结果异常；未继续处理订阅文件。" install
    ;;
esac

if [ "$SAFE_UPDATE" -eq 1 ]; then
  if [ -n "$CUSTOM_PROFILE_DIR" ]; then
    if ! run_committing_profile_operation \
        --profile-dir "$CUSTOM_PROFILE_DIR" \
        --policy "$POLICY_SOURCE" \
        --backup-dir "$BACKUP_DIR" \
        --safe-update-all --usage-profile "$USAGE_PROFILE"; then
      finish_profile_operation_result_failure
      if [ "$JSON_OUTPUT" -eq 1 ]; then
        finish_json_child_failure "$child_json" failed safe_update_failed "安全更新失败。" safe_update
      else
        say "安全更新失败。"
        finish 1 failed safe_update_failed "安全更新失败。" safe_update
      fi
    fi
  else
    if ! run_committing_profile_operation \
        --policy "$POLICY_SOURCE" \
        --backup-dir "$BACKUP_DIR" \
        --safe-update-all --usage-profile "$USAGE_PROFILE"; then
      finish_profile_operation_result_failure
      if [ "$JSON_OUTPUT" -eq 1 ]; then
        finish_json_child_failure "$child_json" failed safe_update_failed "安全更新失败。" safe_update
      else
        say "安全更新失败。"
        finish 1 failed safe_update_failed "安全更新失败。" safe_update
      fi
    fi
  fi
  if ! run_subscription_auto_update_disable; then
    AUTO_UPDATE_RECOVERY_PENDING=1
    finish 9 partial auto_update_recheck_failed \
      "订阅已经更新并重新应用当前档位补丁，但无法再次确认自动更新关闭；请按当前档位重试。" \
      safe_update
  fi
  case "$auto_update_result" in
    disabled|already_disabled|already_disabled_owned) ;;
    *)
      AUTO_UPDATE_RECOVERY_PENDING=1
      finish 9 partial auto_update_recheck_failed \
        "订阅已经更新并重新应用当前档位补丁，但自动更新回读结果异常；请按当前档位重试。" \
        safe_update
      ;;
  esac
  say "订阅、补丁和内部运行检查已完成：当前存储位置中的全部远程订阅已一起更新。"
  say "已再次确认订阅自动更新关闭。"
  say "当前档位的后续验收尚未完成，必须继续完成后才能结束任务。"
  finish 0 ok safe_update_completed \
    "订阅、补丁和内部运行检查已完成；当前档位的后续验收尚未完成。" safe_update
fi

if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  if ! run_committing_profile_operation \
      --profile-dir "$CUSTOM_PROFILE_DIR" \
      --policy "$POLICY_SOURCE" \
      --backup-dir "$BACKUP_DIR" --usage-profile "$USAGE_PROFILE"; then
    finish_profile_operation_result_failure
    if [ "$JSON_OUTPUT" -eq 1 ]; then
      finish_json_child_failure "$child_json" failed patch_failed "配置处理失败。" patch_profiles
    else
      say "配置处理失败。"
      finish 1 failed patch_failed "配置处理失败。" patch_profiles
    fi
  fi
else
  if ! run_committing_profile_operation \
      --policy "$POLICY_SOURCE" \
      --backup-dir "$BACKUP_DIR" --usage-profile "$USAGE_PROFILE"; then
    finish_profile_operation_result_failure
    if [ "$JSON_OUTPUT" -eq 1 ]; then
      finish_json_child_failure "$child_json" failed patch_failed "配置处理失败。" patch_profiles
    else
      say "配置处理失败。"
      finish 1 failed patch_failed "配置处理失败。" patch_profiles
    fi
  fi
fi

say "本次为单次运行；当前存储位置中的全部订阅都已使用同一套国内域名直连规则。"
say "当前订阅需要修改时，会通过本地控制器自动刷新并检查；失败时补丁程序会恢复原配置。"
say "脚本没有退出、停止或重启 ClashX Meta，也没有切换订阅、代理组或节点。"
finish 0 ok install_completed "ClaudeEasy 处理完成。" install
