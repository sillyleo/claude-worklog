#!/bin/bash
# Session Start Hook - 記錄對話開始時間 + 初始化活動追蹤
# 從 stdin 讀取 JSON，取得 session_id，記錄 epoch timestamp

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR}"
SESSION_FILE="$PROJECT_DIR/.claude/.session_start"
ACTIVITY_FILE="$PROJECT_DIR/.claude/.session_activity"

# 確保 .claude 目錄存在
mkdir -p "$PROJECT_DIR/.claude"

# 讀取 stdin JSON
INPUT=$(cat)

# 取得 session_id（jq 優先，fallback python3）
if command -v jq &>/dev/null; then
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
else
  SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id','unknown'))" 2>/dev/null || echo "unknown")
fi

# 如果是 resume session 且已有記錄，不覆蓋
if [ -f "$ACTIVITY_FILE" ]; then
  EXISTING_SESSION=$(head -1 "$ACTIVITY_FILE" 2>/dev/null | cut -d'|' -f1)
  if [ "$EXISTING_SESSION" = "$SESSION_ID" ]; then
    exit 0
  fi
fi

TIMESTAMP=$(date '+%s')

# 寫入 session_start（向後相容）
echo "${SESSION_ID}|${TIMESTAMP}" > "$SESSION_FILE"

# 寫入 session_activity: session_id|start_epoch|last_activity_epoch|accumulated_seconds
echo "${SESSION_ID}|${TIMESTAMP}|${TIMESTAMP}|0" > "$ACTIVITY_FILE"

exit 0
