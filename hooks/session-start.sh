#!/bin/bash
# Session Start Hook - 記錄對話開始時間 + 初始化活動追蹤
# 從 stdin 讀取 JSON，取得 session_id，記錄 epoch timestamp
# 追蹤資料寫到 ~/Documents/GitHub/worklog/<repo-name>/ 而非專案內

set -euo pipefail

WORKLOG_ROOT="${WORKLOG_ROOT:-$HOME/Documents/GitHub/worklog}"

# 讀取 stdin JSON
INPUT=$(cat || true)

# 取得 session_id / cwd（jq 優先，fallback python3）
if command -v jq &>/dev/null; then
  PAYLOAD_SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // .conversation_id // empty' 2>/dev/null || true)
  INPUT_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // .workspace_roots[0] // empty' 2>/dev/null || true)
else
  PAYLOAD_SESSION_ID=$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id') or d.get('conversation_id') or '')" 2>/dev/null || true)
  INPUT_CWD=$(printf '%s' "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd') or (d.get('workspace_roots') or [''])[0] or '')" 2>/dev/null || true)
fi

# Codex 的 Git 子程序會繼承 CODEX_THREAD_ID，優先使用它才能把 commit
# 對回正確 task。其他環境仍使用 hook payload 的 session_id。
SESSION_ID="${WORKLOG_SESSION_ID:-${CODEX_THREAD_ID:-${PAYLOAD_SESSION_ID:-unknown}}}"
SESSION_KEY=$(printf '%s' "$SESSION_ID" | tr -c '[:alnum:]_.-' '_')
[ -n "$SESSION_KEY" ] || SESSION_KEY="unknown"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-${INPUT_CWD:-$(pwd)}}}"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# 解析 repo-name: 優先 git toplevel basename，fallback PROJECT_DIR basename
if REPO_ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null); then
  REPO_NAME=$(basename "$REPO_ROOT")
else
  REPO_NAME=$(basename "$PROJECT_DIR")
fi

WORKLOG_DIR="$WORKLOG_ROOT/$REPO_NAME"
SESSION_FILE="$WORKLOG_DIR/.session_start"
LEGACY_ACTIVITY_FILE="$WORKLOG_DIR/.session_activity"
SESSIONS_DIR="$WORKLOG_DIR/.sessions"
ACTIVITY_FILE="$SESSIONS_DIR/$SESSION_KEY.activity"
WORKLOG_FILE="$WORKLOG_DIR/worklog.md"

mkdir -p "$WORKLOG_DIR" "$SESSIONS_DIR"

# Backward compat: 舊位置的資料一次性 copy 到新位置（不刪），避免歷史工時遺失
if [ ! -f "$WORKLOG_FILE" ] && [ -f "$PROJECT_DIR/worklog.md" ]; then
  cp "$PROJECT_DIR/worklog.md" "$WORKLOG_FILE"
fi
if [ ! -f "$LEGACY_ACTIVITY_FILE" ] && [ -f "$PROJECT_DIR/.claude/.session_activity" ]; then
  cp "$PROJECT_DIR/.claude/.session_activity" "$LEGACY_ACTIVITY_FILE"
fi
if [ ! -f "$SESSION_FILE" ] && [ -f "$PROJECT_DIR/.claude/.session_start" ]; then
  cp "$PROJECT_DIR/.claude/.session_start" "$SESSION_FILE"
fi

# 從舊版單一計時檔搬移尚未結算的工時。只有 session id 相同才接手，
# 避免新 task 誤拿另一個 task 的累積時間。
if [ ! -f "$ACTIVITY_FILE" ] && [ -f "$LEGACY_ACTIVITY_FILE" ]; then
  LEGACY_SESSION_ID=$(head -1 "$LEGACY_ACTIVITY_FILE" 2>/dev/null | cut -d'|' -f1)
  if [ "$LEGACY_SESSION_ID" = "$SESSION_ID" ]; then
    cp "$LEGACY_ACTIVITY_FILE" "$ACTIVITY_FILE"
  fi
fi

# 安裝真正的 Git post-commit hook，支援 Claude Code、Codex 與一般終端機
"$SCRIPT_DIR/install-git-hook.sh" "$PROJECT_DIR" || true

# 如果是 resume session 且已有記錄，不覆蓋
if [ -f "$ACTIVITY_FILE" ]; then
  exit 0
fi

TIMESTAMP=$(date '+%s')

# 寫入 session_start（向後相容）
echo "${SESSION_ID}|${TIMESTAMP}" > "$SESSION_FILE"

# 寫入 session_activity: session_id|start_epoch|last_activity_epoch|accumulated_seconds
echo "${SESSION_ID}|${TIMESTAMP}|${TIMESTAMP}|0" > "$ACTIVITY_FILE"
echo "${SESSION_ID}|${TIMESTAMP}|${TIMESTAMP}|0" > "$LEGACY_ACTIVITY_FILE"

exit 0
