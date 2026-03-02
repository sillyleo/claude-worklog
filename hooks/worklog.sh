#!/bin/bash
# PostToolUse Hook - Heartbeat + Git Commit 偵測
# 每次工具使用時更新活動追蹤（max idle 2h），偵測 commit 時記錄工時

set -euo pipefail

MAX_IDLE=7200  # 最大 idle time: 2 hours (秒)

PROJECT_DIR="${CLAUDE_PROJECT_DIR}"
ACTIVITY_FILE="$PROJECT_DIR/.claude/.session_activity"
WORKLOG_FILE="$PROJECT_DIR/worklog.md"

# 讀取 stdin JSON
INPUT=$(cat)

# 取得 tool_name 和 command（jq 優先，fallback python3）
if command -v jq &>/dev/null; then
  TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
else
  TOOL_NAME=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || echo "")
  COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")
fi

NOW_EPOCH=$(date '+%s')

# --- Heartbeat: 更新活動追蹤 ---
ACCUMULATED=0
START_EPOCH=""

if [ -f "$ACTIVITY_FILE" ]; then
  IFS='|' read -r SESSION_ID START_EPOCH LAST_ACTIVITY ACCUMULATED < "$ACTIVITY_FILE"

  # 計算距離上次活動的間隔
  INTERVAL=$((NOW_EPOCH - LAST_ACTIVITY))

  # 如果間隔 < MAX_IDLE，累加到工時；否則 idle time 不計入
  if [ "$INTERVAL" -lt "$MAX_IDLE" ]; then
    ACCUMULATED=$((ACCUMULATED + INTERVAL))
  fi

  # 更新 activity file
  echo "${SESSION_ID}|${START_EPOCH}|${NOW_EPOCH}|${ACCUMULATED}" > "$ACTIVITY_FILE"
fi

# --- Git Commit 偵測（僅 Bash 工具） ---
if [ "$TOOL_NAME" = "Bash" ] && [ -n "$COMMAND" ]; then
  # 檢查是否為真正的 git commit
  if echo "$COMMAND" | grep -qE '(^|&&\s*|;\s*)git\s+commit\b'; then
    # 排除搜尋/印出類指令
    if ! echo "$COMMAND" | grep -qE '^\s*(grep|echo|cat|git\s+log|git\s+show|git\s+diff)'; then

      NOW_DATE=$(date '+%Y-%m-%d')
      NOW_TIME=$(date '+%H:%M')

      # Start time
      if [ -n "$START_EPOCH" ] && [ "$START_EPOCH" -gt 0 ] 2>/dev/null; then
        START_TIME=$(date -r "$START_EPOCH" '+%H:%M' 2>/dev/null || date -d "@$START_EPOCH" '+%H:%M' 2>/dev/null || echo "unknown")
      else
        START_TIME="unknown"
      fi

      # Duration（用累積工時，已排除 idle）
      HOURS=$((ACCUMULATED / 3600))
      MINUTES=$(( (ACCUMULATED % 3600) / 60 ))
      if [ "$HOURS" -gt 0 ]; then
        DURATION="${HOURS}h ${MINUTES}m"
      else
        DURATION="${MINUTES}m"
      fi

      # 取得 commit message
      COMMIT_MSG=$(cd "$PROJECT_DIR" && git log -1 --pretty=format:'%s' 2>/dev/null || echo "unknown")
      COMMIT_MSG=$(echo "$COMMIT_MSG" | sed 's/|/\\|/g')

      # 建立或更新 worklog.md
      if [ ! -f "$WORKLOG_FILE" ]; then
        cat > "$WORKLOG_FILE" << 'EOF'
# Work Log

| Date | Start | End | Duration | Commit |
|------|-------|-----|----------|--------|
EOF
      fi

      echo "| ${NOW_DATE} | ${START_TIME} | ${NOW_TIME} | ${DURATION} | ${COMMIT_MSG} |" >> "$WORKLOG_FILE"

      # 重置追蹤：下一次 commit 的 start = 此次 commit 的時間
      echo "${SESSION_ID}|${NOW_EPOCH}|${NOW_EPOCH}|0" > "$ACTIVITY_FILE"
    fi
  fi
fi

exit 0
