#!/bin/bash
# Git post-commit hook - 將 commit 寫入集中式 worklog

set -euo pipefail

MAX_IDLE=7200

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  exit 0
fi

WORKLOG_ROOT="${WORKLOG_ROOT:-$HOME/Documents/GitHub/worklog}"
mkdir -p "$WORKLOG_ROOT"
REPO_ROOT_PHYSICAL=$(CDPATH= cd -- "$REPO_ROOT" && pwd -P)
WORKLOG_ROOT_PHYSICAL=$(CDPATH= cd -- "$WORKLOG_ROOT" && pwd -P)
if [ "$REPO_ROOT_PHYSICAL" = "$WORKLOG_ROOT_PHYSICAL" ]; then
  exit 0
fi

GIT_LOCAL_ENV_VARS=$(git rev-parse --local-env-vars 2>/dev/null || true)

# 不同 repo 可能同時提交；序列化 Worklog 寫入與自動 commit。
LOCK_DIR="${TMPDIR:-/tmp}/claude-worklog-${UID:-user}.lock"
LOCK_ATTEMPTS=0
until mkdir "$LOCK_DIR" 2>/dev/null; do
  LOCK_ATTEMPTS=$((LOCK_ATTEMPTS + 1))
  if [ -f "$LOCK_DIR/pid" ]; then
    LOCK_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    case "$LOCK_PID" in
      ''|*[!0-9]*) ;;
      *)
        if ! kill -0 "$LOCK_PID" 2>/dev/null; then
          rm -f "$LOCK_DIR/pid"
          rmdir "$LOCK_DIR" 2>/dev/null || true
          continue
        fi
        ;;
    esac
  fi
  [ "$LOCK_ATTEMPTS" -lt 400 ] || exit 0
  sleep 0.05
done
printf '%s\n' "$$" > "$LOCK_DIR/pid"

cleanup_lock() {
  rm -f "$LOCK_DIR/pid"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup_lock EXIT INT TERM

REPO_NAME=$(basename "$REPO_ROOT")
WORKLOG_DIR="$WORKLOG_ROOT/$REPO_NAME"
LEGACY_ACTIVITY_FILE="$WORKLOG_DIR/.session_activity"
SESSIONS_DIR="$WORKLOG_DIR/.sessions"
WORKLOG_FILE="$WORKLOG_DIR/worklog.md"
LAST_COMMIT_FILE="$WORKLOG_DIR/.last_commit"
RECORDED_COMMITS_DIR="$WORKLOG_DIR/.recorded_commits"

SESSION_ID="${WORKLOG_SESSION_ID:-${CODEX_THREAD_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-terminal}}}}"
SESSION_KEY=$(printf '%s' "$SESSION_ID" | tr -c '[:alnum:]_.-' '_')
[ -n "$SESSION_KEY" ] || SESSION_KEY="terminal"
ACTIVITY_FILE="$SESSIONS_DIR/$SESSION_KEY.activity"

mkdir -p "$WORKLOG_DIR" "$SESSIONS_DIR" "$RECORDED_COMMITS_DIR"

COMMIT_HASH=$(git rev-parse HEAD 2>/dev/null || true)
[ -n "$COMMIT_HASH" ] || exit 0

# 同一個 commit 的 hook 若被重送，只寫入一次
if [ -f "$LAST_COMMIT_FILE" ] && [ "$(cat "$LAST_COMMIT_FILE")" = "$COMMIT_HASH" ]; then
  exit 0
fi

# 不同 task 可能同時 commit；每個 hash 用獨立目錄做原子去重。
COMMIT_MARKER="$RECORDED_COMMITS_DIR/$COMMIT_HASH"
if ! mkdir "$COMMIT_MARKER" 2>/dev/null; then
  exit 0
fi

NOW_EPOCH=$(date '+%s')
NOW_DATE=$(date '+%Y-%m-%d')
NOW_TIME=$(date '+%H:%M')
START_EPOCH="$NOW_EPOCH"
LAST_ACTIVITY="$NOW_EPOCH"
ACCUMULATED=0

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

  INTERVAL=$((NOW_EPOCH - LAST_ACTIVITY))
  if [ "$INTERVAL" -ge 0 ] && [ "$INTERVAL" -lt "$MAX_IDLE" ]; then
    ACCUMULATED=$((ACCUMULATED + INTERVAL))
  elif [ "$ACCUMULATED" -eq 0 ]; then
    START_EPOCH="$NOW_EPOCH"
  fi
fi

START_TIME=$(date -r "$START_EPOCH" '+%H:%M' 2>/dev/null || date -d "@$START_EPOCH" '+%H:%M' 2>/dev/null || echo "unknown")
HOURS=$((ACCUMULATED / 3600))
MINUTES=$(((ACCUMULATED % 3600) / 60))

if [ "$HOURS" -gt 0 ]; then
  DURATION="${HOURS}h ${MINUTES}m"
else
  DURATION="${MINUTES}m"
fi

COMMIT_MSG=$(git log -1 --pretty=format:'%s' 2>/dev/null || echo "unknown")
COMMIT_MSG=$(printf '%s' "$COMMIT_MSG" | sed 's/|/\\|/g')

if [ ! -f "$WORKLOG_FILE" ]; then
  cat > "$WORKLOG_FILE" <<'EOF'
# Work Log

| Date | Start | End | Duration | Commit |
|------|-------|-----|----------|--------|
EOF
fi

printf '| %s | %s | %s | %s | %s |\n' \
  "$NOW_DATE" "$START_TIME" "$NOW_TIME" "$DURATION" "$COMMIT_MSG" >> "$WORKLOG_FILE"
printf '%s\n' "$COMMIT_HASH" > "$LAST_COMMIT_FILE"
printf '%s|%s|%s|0\n' "$SESSION_ID" "$NOW_EPOCH" "$NOW_EPOCH" > "$ACTIVITY_FILE"
printf '%s|%s|%s|0\n' "$SESSION_ID" "$NOW_EPOCH" "$NOW_EPOCH" > "$LEGACY_ACTIVITY_FILE"

# 自動 commit Worklog repo。先清除來源 repo 的 Git 環境，避免 worktree
# 的 GIT_DIR / GIT_INDEX_FILE 讓 git -C 仍操作到來源 repo。
(
  while IFS= read -r variable; do
    [ -n "$variable" ] && unset "$variable"
  done <<< "$GIT_LOCAL_ENV_VARS"

  if git -C "$WORKLOG_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$WORKLOG_ROOT" add -A >/dev/null 2>&1 || true
    git -c core.hooksPath=/dev/null -C "$WORKLOG_ROOT" \
      commit -q -m "log: ${REPO_NAME} — ${COMMIT_MSG}" \
      >/dev/null 2>&1 || true
  fi
)

exit 0
