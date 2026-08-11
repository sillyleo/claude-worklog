#!/bin/bash
# Claude Code Status Line - 顯示 user@host, git info, 累積工時
# 搭配 claude-worklog plugin 使用，優先讀取 task 專屬 activity 顯示計時

input=$(cat)
worklog_root="${WORKLOG_ROOT:-$HOME/Documents/GitHub/worklog}"

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
pdir=$(echo "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd')

username=$(whoami)
hostname=$(hostname -s)
current_dir="${cwd/#$HOME/~}"

# Git info
git_info=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)
  if git -C "$cwd" --no-optional-locks diff-index --quiet HEAD -- 2>/dev/null; then
    git_info=" ($branch ✓)"
  else
    git_info=" ($branch ✗)"
  fi
fi

# Resolve repo-name 同 hook: git toplevel basename，fallback pdir basename
if repo_root=$(git -C "$pdir" rev-parse --show-toplevel 2>/dev/null); then
  repo_name=$(basename "$repo_root")
else
  repo_name=$(basename "$pdir")
fi

# Worktime from session activity
worktime=""
session_id=$(echo "$input" | jq -r '.session_id // .conversation_id // empty')
session_key=$(printf '%s' "$session_id" | tr -c '[:alnum:]_.-' '_')
af="$worklog_root/$repo_name/.sessions/$session_key.activity"
if [ -z "$session_key" ] || [ ! -f "$af" ]; then
  af="$worklog_root/$repo_name/.session_activity"
fi
if [ -f "$af" ]; then
  acc=$(cut -d'|' -f4 "$af")
  if [ -n "$acc" ] && [ "$acc" -gt 0 ] 2>/dev/null; then
    h=$((acc / 3600))
    m=$(((acc % 3600) / 60))
    if [ "$h" -gt 0 ]; then
      worktime=" ⏱${h}h${m}m"
    else
      worktime=" ⏱${m}m"
    fi
  fi
fi

echo "${username}@${hostname} ${current_dir}${git_info}${worktime}"
