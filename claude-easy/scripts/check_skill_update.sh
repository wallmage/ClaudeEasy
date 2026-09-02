#!/bin/bash
set -euo pipefail

install_root="${CLAUDE_EASY_INSTALLED_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
repo_url="https://github.com/wallmage/ClaudeEasy.git"
marker="$install_root/.source-revision"
remote_sha="$(git ls-remote "$repo_url" HEAD | awk 'NR == 1 { print $1 }')"
if [[ ! "$remote_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "skill_update_check_failed" >&2
  exit 1
fi
if [[ -f "$marker" && "$(<"$marker")" == "$remote_sha" ]]; then
  echo "skill_up_to_date"
  exit 0
fi

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
git clone --quiet --depth 1 "$repo_url" "$temporary/repo"
rsync -a --delete "$temporary/repo/claude-easy/" "$install_root/"
printf '%s\n' "$remote_sha" > "$install_root/.source-revision"
echo "skill_updated"
