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

clear_source_git_env() {
  while IFS= read -r variable; do
    [ -n "$variable" ] && unset "$variable"
  done <<< "$GIT_LOCAL_ENV_VARS"

  # hook 不得等待互動式認證或編輯器；失敗時保留本地紀錄，稍後重試。
  export GIT_TERMINAL_PROMPT=0
  export GIT_EDITOR=true
  export GIT_SEQUENCE_EDITOR=true
}

worklog_current_branch() {
  git -C "$WORKLOG_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null
}

worklog_tracked_tree_is_clean() {
  git -C "$WORKLOG_ROOT" diff --quiet --ignore-submodules -- &&
    git -C "$WORKLOG_ROOT" diff --cached --quiet --ignore-submodules --
}

# 兩台電腦若同時在同一份 worklog.md 尾端新增資料，用 union merge driver
# 保留雙方列；其他檔案照一般 rebase 規則處理，發生衝突就中止。
rebase_worklog_onto() (
  REMOTE_REF="$1"
  ATTRIBUTES_FILE=$(mktemp "${TMPDIR:-/tmp}/claude-worklog-attributes.XXXXXX") || return 1
  trap 'rm -f "$ATTRIBUTES_FILE"' EXIT INT TERM
  printf '%s\n' '**/worklog.md merge=union' > "$ATTRIBUTES_FILE"

  if ! git -c core.hooksPath=/dev/null \
    -c core.attributesFile="$ATTRIBUTES_FILE" \
    -C "$WORKLOG_ROOT" rebase "$REMOTE_REF" >/dev/null 2>&1; then
    git -c core.hooksPath=/dev/null -C "$WORKLOG_ROOT" rebase --abort >/dev/null 2>&1 || true
    return 1
  fi
)

# 寫入前先取得另一台電腦的提交。無 origin、離線、dirty tree 或衝突時
# 回傳失敗但不阻止本地記錄；絕不 force push、絕不丟棄本地 commit。
sync_worklog_before_write() (
  clear_source_git_env

  git -C "$WORKLOG_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 0
  BRANCH=$(worklog_current_branch) || return 0
  git -C "$WORKLOG_ROOT" remote get-url origin >/dev/null 2>&1 || return 0
  git -C "$WORKLOG_ROOT" fetch -q origin "$BRANCH" >/dev/null 2>&1 || return 1

  REMOTE_REF="refs/remotes/origin/$BRANCH"
  git -C "$WORKLOG_ROOT" show-ref --verify --quiet "$REMOTE_REF" || return 0

  if git -C "$WORKLOG_ROOT" merge-base --is-ancestor "$REMOTE_REF" HEAD; then
    return 0
  fi

  worklog_tracked_tree_is_clean || return 1

  if git -C "$WORKLOG_ROOT" merge-base --is-ancestor HEAD "$REMOTE_REF"; then
    git -c core.hooksPath=/dev/null -C "$WORKLOG_ROOT" \
      merge -q --ff-only "$REMOTE_REF"
    return
  fi

  rebase_worklog_onto "$REMOTE_REF"
)

# commit 完成後推送；若另一台剛好搶先，重新 fetch/rebase 後最多重試三次。
push_worklog_with_retry() (
  clear_source_git_env

  BRANCH=$(worklog_current_branch) || return 0
  git -C "$WORKLOG_ROOT" remote get-url origin >/dev/null 2>&1 || return 0

  ATTEMPT=1
  while [ "$ATTEMPT" -le 3 ]; do
    if git -C "$WORKLOG_ROOT" push -q origin "HEAD:$BRANCH" >/dev/null 2>&1; then
      return 0
    fi

    git -C "$WORKLOG_ROOT" fetch -q origin "$BRANCH" >/dev/null 2>&1 || return 1
    REMOTE_REF="refs/remotes/origin/$BRANCH"
    git -C "$WORKLOG_ROOT" show-ref --verify --quiet "$REMOTE_REF" || return 1

    if ! git -C "$WORKLOG_ROOT" merge-base --is-ancestor "$REMOTE_REF" HEAD; then
      worklog_tracked_tree_is_clean || return 1
      rebase_worklog_onto "$REMOTE_REF" || return 1
    fi

    ATTEMPT=$((ATTEMPT + 1))
  done

  return 1
)

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

if ! sync_worklog_before_write; then
  printf '%s\n' 'claude-worklog: 無法同步遠端，這筆工時會先安全保留在本機。' >&2
fi

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

# 只提交這次變更的 worklog.md，避免夾帶 Worklog repo 內其他 WIP；
# 接著安全推送，離線或衝突時保留本地 commit 供下次自動重試。
(
  clear_source_git_env

  if git -C "$WORKLOG_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    WORKLOG_RELATIVE="$REPO_NAME/worklog.md"
    git -C "$WORKLOG_ROOT" add -- "$WORKLOG_RELATIVE" >/dev/null 2>&1 || true
    if git -c core.hooksPath=/dev/null -C "$WORKLOG_ROOT" \
      commit -q --only -m "log: ${REPO_NAME} — ${COMMIT_MSG}" -- "$WORKLOG_RELATIVE" \
      >/dev/null 2>&1; then
      if ! push_worklog_with_retry; then
        printf '%s\n' 'claude-worklog: 推送失敗，工時 commit 已保留在本機，下次會重試。' >&2
      fi
    fi
  fi
)

exit 0
