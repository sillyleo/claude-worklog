#!/bin/bash
# PostToolUse Hook - Heartbeat
# 每次工具使用時更新活動追蹤（max idle 2h）
# 追蹤資料寫到 ~/Documents/GitHub/worklog/<repo-name>/ 而非專案內

set -euo pipefail

MAX_IDLE=7200  # 最大 idle time: 2 hours (秒)
WORKLOG_ROOT="${WORKLOG_ROOT:-$HOME/Documents/GitHub/worklog}"

# 讀取 stdin JSON
INPUT=$(cat || true)

# 取得 session_id / cwd（jq 優先，fallback python3）
if command -v jq &>/dev/null; then
  PAYLOAD_SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // .conversation_id // empty' 2>/dev/null || true)
  INPUT_CWD=$(printf '%s' "$INPUT" | jq -r '.tool_input.workdir // .cwd // .workspace_roots[0] // empty' 2>/dev/null || true)
else
  PAYLOAD_SESSION_ID=$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id') or d.get('conversation_id') or '')" 2>/dev/null || true)
  INPUT_CWD=$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); ti=d.get('tool_input') or {}; print(ti.get('workdir') or d.get('cwd') or (d.get('workspace_roots') or [''])[0] or '')" 2>/dev/null || true)
fi

SESSION_ID="${WORKLOG_SESSION_ID:-${CODEX_THREAD_ID:-${PAYLOAD_SESSION_ID:-unknown}}}"
SESSION_KEY=$(printf '%s' "$SESSION_ID" | tr -c '[:alnum:]_.-' '_')
[ -n "$SESSION_KEY" ] || SESSION_KEY="unknown"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-${INPUT_CWD:-$(pwd)}}}"

# 解析 repo-name: 優先 git toplevel basename，fallback PROJECT_DIR basename
if REPO_ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null); then
  REPO_NAME=$(basename "$REPO_ROOT")
else
  REPO_NAME=$(basename "$PROJECT_DIR")
fi

WORKLOG_DIR="$WORKLOG_ROOT/$REPO_NAME"
LEGACY_ACTIVITY_FILE="$WORKLOG_DIR/.session_activity"
SESSIONS_DIR="$WORKLOG_DIR/.sessions"
ACTIVITY_FILE="$SESSIONS_DIR/$SESSION_KEY.activity"

mkdir -p "$WORKLOG_DIR" "$SESSIONS_DIR"

NOW_EPOCH=$(date '+%s')

# --- Heartbeat: 更新活動追蹤 ---
ACCUMULATED=0
START_EPOCH="$NOW_EPOCH"
LAST_ACTIVITY="$NOW_EPOCH"

if [ -f "$ACTIVITY_FILE" ]; then
  IFS='|' read -r STORED_SESSION_ID START_EPOCH LAST_ACTIVITY ACCUMULATED < "$ACTIVITY_FILE"

  case "$START_EPOCH" in
    ''|*[!0-9]*) START_EPOCH="$NOW_EPOCH" ;;
  esac
  case "$LAST_ACTIVITY" in
    ''|*[!0-9]*) LAST_ACTIVITY="$NOW_EPOCH" ;;
  esac
  case "$ACCUMULATED" in
    ''|*[!0-9]*) ACCUMULATED=0 ;;
  esac

  # 計算距離上次活動的間隔
  INTERVAL=$((NOW_EPOCH - LAST_ACTIVITY))

  # 如果間隔 < MAX_IDLE，累加到工時；否則 idle time 不計入
  if [ "$INTERVAL" -ge 0 ] && [ "$INTERVAL" -lt "$MAX_IDLE" ]; then
    ACCUMULATED=$((ACCUMULATED + INTERVAL))
  fi

fi

# 更新 task 專屬計時；舊檔只保留給 status line 相容顯示。
echo "${SESSION_ID}|${START_EPOCH}|${NOW_EPOCH}|${ACCUMULATED}" > "$ACTIVITY_FILE"
echo "${SESSION_ID}|${START_EPOCH}|${NOW_EPOCH}|${ACCUMULATED}" > "$LEGACY_ACTIVITY_FILE"

exit 0
