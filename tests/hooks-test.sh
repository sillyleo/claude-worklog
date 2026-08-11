#!/bin/bash

set -euo pipefail

PLUGIN_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export TMPDIR="$TEST_ROOT/tmp"
REPO="$TEST_ROOT/example-repo"
export WORKLOG_ROOT="$HOME/Documents/GitHub/worklog"
mkdir -p "$HOME" "$TMPDIR" "$REPO" "$WORKLOG_ROOT"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Worklog Test"
git -C "$REPO" config user.email "worklog@example.com"
git -C "$WORKLOG_ROOT" init -q -b main
git -C "$WORKLOG_ROOT" config user.name "Worklog Test"
git -C "$WORKLOG_ROOT" config user.email "worklog@example.com"

mkdir -p "$REPO/.git/hooks"
cat > "$REPO/.git/hooks/post-commit" <<'EOF'
#!/bin/sh
printf 'called\n' >> "$HOME/original-hook.log"
EOF
chmod +x "$REPO/.git/hooks/post-commit"

# 升級前若有相同 task 尚未 commit 的舊版計時，必須搬入 task 專屬檔。
mkdir -p "$WORKLOG_ROOT/example-repo"
LEGACY_NOW=$(date '+%s')
printf 'task-a|%s|%s|1500\n' "$((LEGACY_NOW - 1500))" "$LEGACY_NOW" \
  > "$WORKLOG_ROOT/example-repo/.session_activity"

printf '{"session_id":"test-session"}\n' | \
  CODEX_THREAD_ID="task-a" CLAUDE_PROJECT_DIR="$REPO" "$PLUGIN_ROOT/hooks/session-start.sh"

grep -Fq '# claude-worklog managed post-commit wrapper' "$REPO/.git/hooks/post-commit"
[ "$(find "$REPO/.git/hooks/post-commit.claude-worklog.d" -type f | wc -l | tr -d ' ')" = "1" ]

# 同一個 repo 的兩個 Codex task 各有獨立計時檔。
printf '{"session_id":"second-payload-session"}\n' | \
  CODEX_THREAD_ID="task-b" CLAUDE_PROJECT_DIR="$REPO" "$PLUGIN_ROOT/hooks/session-start.sh"

WORKLOG_DIR="$WORKLOG_ROOT/example-repo"
TASK_A_ACTIVITY="$WORKLOG_DIR/.sessions/task-a.activity"
TASK_B_ACTIVITY="$WORKLOG_DIR/.sessions/task-b.activity"
[ -f "$TASK_A_ACTIVITY" ]
[ -f "$TASK_B_ACTIVITY" ]
[ "$(cut -d'|' -f4 "$TASK_A_ACTIVITY")" = "1500" ]
[ "$(cut -d'|' -f4 "$TASK_B_ACTIVITY")" = "0" ]

# 任意 Claude Code／Codex 工具格式都能更新自己的 heartbeat。
printf '{"session_id":"test-session","tool_name":"exec","tool_input":{"source":"tools.exec_command(...)"}}\n' | \
  CODEX_THREAD_ID="task-a" CLAUDE_PROJECT_DIR="$REPO" "$PLUGIN_ROOT/hooks/worklog.sh"
grep -Fq 'task-a|' "$TASK_A_ACTIVITY"
grep -Fq 'task-b|' "$TASK_B_ACTIVITY"

# 模擬兩個 task 完全重疊，各自累積一小時。
NOW_EPOCH=$(date '+%s')
printf 'task-a|%s|%s|3600\n' "$((NOW_EPOCH - 3600))" "$NOW_EPOCH" > "$TASK_A_ACTIVITY"
printf 'task-b|%s|%s|3600\n' "$((NOW_EPOCH - 3600))" "$NOW_EPOCH" > "$TASK_B_ACTIVITY"

printf 'first\n' > "$REPO/tracked.txt"
git -C "$REPO" add tracked.txt
CODEX_THREAD_ID="task-a" git -C "$REPO" commit -q -m 'feat: task A commit'

WORKLOG="$WORKLOG_ROOT/example-repo/worklog.md"
grep -Fq '| 1h 0m | feat: task A commit |' "$WORKLOG"
[ "$(git -C "$REPO" rev-list --count HEAD)" = "1" ]
[ "$(git -C "$WORKLOG_ROOT" rev-list --count HEAD)" = "1" ]
git -C "$WORKLOG_ROOT" log -1 --pretty=%s | grep -Fq 'log: example-repo — feat: task A commit'
[ "$(cut -d'|' -f4 "$TASK_A_ACTIVITY")" = "0" ]
[ "$(cut -d'|' -f4 "$TASK_B_ACTIVITY")" = "3600" ]
[ "$(grep -c '^called$' "$HOME/original-hook.log")" = "1" ]

printf 'second\n' >> "$REPO/tracked.txt"
git -C "$REPO" add tracked.txt
CODEX_THREAD_ID="task-b" git -C "$REPO" commit -q -m 'feat: task B commit'
grep -Fq '| 1h 0m | feat: task B commit |' "$WORKLOG"
[ "$(grep -c '| 1h 0m |' "$WORKLOG")" = "2" ]

# 同一個 task 忘記 commit，隔天 resume 時必須保留已累積工時。
printf '{"session_id":"overnight-payload"}\n' | \
  CODEX_THREAD_ID="task-overnight" CLAUDE_PROJECT_DIR="$REPO" "$PLUGIN_ROOT/hooks/session-start.sh"
OVERNIGHT_ACTIVITY="$WORKLOG_DIR/.sessions/task-overnight.activity"
OLD_START=$((NOW_EPOCH - 90000))
OLD_LAST_ACTIVITY=$((NOW_EPOCH - 86400))
printf 'task-overnight|%s|%s|1800\n' "$OLD_START" "$OLD_LAST_ACTIVITY" > "$OVERNIGHT_ACTIVITY"
OVERNIGHT_BEFORE_RESUME=$(cat "$OVERNIGHT_ACTIVITY")

printf '{"session_id":"overnight-payload"}\n' | \
  CODEX_THREAD_ID="task-overnight" CLAUDE_PROJECT_DIR="$REPO" "$PLUGIN_ROOT/hooks/session-start.sh"
[ "$(cat "$OVERNIGHT_ACTIVITY")" = "$OVERNIGHT_BEFORE_RESUME" ]

# 開啟另一個 task 不得覆蓋尚未 commit 的隔夜工時。
printf '{"session_id":"new-task-payload"}\n' | \
  CODEX_THREAD_ID="task-new" CLAUDE_PROJECT_DIR="$REPO" "$PLUGIN_ROOT/hooks/session-start.sh"
NEW_TASK_ACTIVITY="$WORKLOG_DIR/.sessions/task-new.activity"
[ -f "$NEW_TASK_ACTIVITY" ]
[ "$(cut -d'|' -f4 "$OVERNIGHT_ACTIVITY")" = "1800" ]

# 隔夜 idle 不計入，但既有 30 分鐘在 heartbeat 與 commit 後必須保留。
printf '{"session_id":"overnight-payload","tool_name":"exec","tool_input":{"source":"tools.exec_command(...)"}}\n' | \
  CODEX_THREAD_ID="task-overnight" CLAUDE_PROJECT_DIR="$REPO" "$PLUGIN_ROOT/hooks/worklog.sh"
[ "$(cut -d'|' -f4 "$OVERNIGHT_ACTIVITY")" = "1800" ]

printf 'overnight\n' >> "$REPO/tracked.txt"
git -C "$REPO" add tracked.txt
CODEX_THREAD_ID="task-overnight" git -C "$REPO" commit -q -m 'feat: overnight commit'
grep -Fq '| 30m | feat: overnight commit |' "$WORKLOG"
[ "$(cut -d'|' -f4 "$OVERNIGHT_ACTIVITY")" = "0" ]
[ "$(cut -d'|' -f4 "$NEW_TASK_ACTIVITY")" = "0" ]

# Claude Code commit 透過繼承的 session id 結算自己的計時檔。
printf '{"session_id":"claude-task"}\n' | \
  CLAUDE_PROJECT_DIR="$REPO" "$PLUGIN_ROOT/hooks/session-start.sh"
CLAUDE_ACTIVITY="$WORKLOG_DIR/.sessions/claude-task.activity"
printf 'claude-task|%s|%s|900\n' "$((NOW_EPOCH - 900))" "$NOW_EPOCH" > "$CLAUDE_ACTIVITY"
printf 'claude\n' >> "$REPO/tracked.txt"
git -C "$REPO" add tracked.txt
env -u CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID="claude-task" \
  git -C "$REPO" commit -q -m 'feat: claude session commit'
grep -Fq '| 15m | feat: claude session commit |' "$WORKLOG"
[ "$(cut -d'|' -f4 "$CLAUDE_ACTIVITY")" = "0" ]

# 相同 commit 重送不會重複寫入
BEFORE=$(grep -c '^| 20' "$WORKLOG")
env -u CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID="claude-task" \
  git -C "$REPO" hook run post-commit
AFTER=$(grep -c '^| 20' "$WORKLOG")
[ "$BEFORE" = "$AFTER" ]

# 重新安裝仍只保留一份原始 hook
printf '{"session_id":"third-session"}\n' | \
  CODEX_THREAD_ID="task-c" CLAUDE_PROJECT_DIR="$REPO" "$PLUGIN_ROOT/hooks/session-start.sh"
[ "$(find "$REPO/.git/hooks/post-commit.claude-worklog.d" -type f | wc -l | tr -d ' ')" = "1" ]

# 沒有 task 識別碼的一般終端機 commit 仍會記錄，但不會拿走其他 task 工時。
printf 'terminal\n' >> "$REPO/tracked.txt"
git -C "$REPO" add tracked.txt
env -u CODEX_THREAD_ID -u WORKLOG_SESSION_ID \
  git -C "$REPO" commit -q -m 'chore: terminal commit'
grep -Fq '| 0m | chore: terminal commit |' "$WORKLOG"
[ "$(grep -c '^called$' "$HOME/original-hook.log")" = "6" ]

# 模擬 linked worktree 掛鉤繼承來源 repo 的 Git 環境；Worklog commit 不得
# 寫回來源 repo，也不得再次觸發來源 repo 的 post-commit。
printf 'foreign-env\n' >> "$REPO/tracked.txt"
git -C "$REPO" add tracked.txt
git -c core.hooksPath=/dev/null -C "$REPO" commit -q -m 'fix: foreign git env'
SOURCE_COUNT_BEFORE=$(git -C "$REPO" rev-list --count HEAD)
WORKLOG_COUNT_BEFORE=$(git -C "$WORKLOG_ROOT" rev-list --count HEAD)
GIT_DIR="$REPO/.git" \
  GIT_WORK_TREE="$REPO" \
  GIT_INDEX_FILE="$REPO/.git/index" \
  "$WORKLOG_ROOT/.claude-worklog-post-commit.sh"
[ "$(git -C "$REPO" rev-list --count HEAD)" = "$SOURCE_COUNT_BEFORE" ]
[ "$(git -C "$WORKLOG_ROOT" rev-list --count HEAD)" = "$((WORKLOG_COUNT_BEFORE + 1))" ]
git -C "$WORKLOG_ROOT" log -1 --pretty=%s | grep -Fq 'log: example-repo — fix: foreign git env'

# Worklog 自己即使誤裝或被直接呼叫，也不得記錄或提交自己。
WORKLOG_HEAD_BEFORE=$(git -C "$WORKLOG_ROOT" rev-parse HEAD)
GIT_DIR="$WORKLOG_ROOT/.git" \
  GIT_WORK_TREE="$WORKLOG_ROOT" \
  "$WORKLOG_ROOT/.claude-worklog-post-commit.sh"
[ "$(git -C "$WORKLOG_ROOT" rev-parse HEAD)" = "$WORKLOG_HEAD_BEFORE" ]

# 兩個 repo 同時觸發 tracker 時，Worklog 寫入與 commit 必須序列化。
CONCURRENT_A="$TEST_ROOT/concurrent-a"
CONCURRENT_B="$TEST_ROOT/concurrent-b"
for concurrent_repo in "$CONCURRENT_A" "$CONCURRENT_B"; do
  mkdir -p "$concurrent_repo"
  git -C "$concurrent_repo" init -q -b main
  git -C "$concurrent_repo" config user.name "Worklog Test"
  git -C "$concurrent_repo" config user.email "worklog@example.com"
  printf 'concurrent\n' > "$concurrent_repo/tracked.txt"
  git -C "$concurrent_repo" add tracked.txt
  git -c core.hooksPath=/dev/null -C "$concurrent_repo" commit -q -m "test: $(basename "$concurrent_repo")"
done

(
  GIT_DIR="$CONCURRENT_A/.git" GIT_WORK_TREE="$CONCURRENT_A" \
    "$WORKLOG_ROOT/.claude-worklog-post-commit.sh"
) &
PID_A=$!
(
  GIT_DIR="$CONCURRENT_B/.git" GIT_WORK_TREE="$CONCURRENT_B" \
    "$WORKLOG_ROOT/.claude-worklog-post-commit.sh"
) &
PID_B=$!
wait "$PID_A"
wait "$PID_B"
grep -Fq 'test: concurrent-a' "$WORKLOG_ROOT/concurrent-a/worklog.md"
grep -Fq 'test: concurrent-b' "$WORKLOG_ROOT/concurrent-b/worklog.md"
[ -z "$(git -C "$WORKLOG_ROOT" status --short)" ]

# 專案把 core.hooksPath 放在 working tree 時，不得寫入或污染該路徑。
CUSTOM_HOOK_REPO="$TEST_ROOT/custom-hook-repo"
mkdir -p "$CUSTOM_HOOK_REPO"
git -C "$CUSTOM_HOOK_REPO" init -q -b main
git -C "$CUSTOM_HOOK_REPO" config core.hooksPath .husky
printf '{"session_id":"custom-hook-task"}\n' | \
  CODEX_THREAD_ID="custom-hook-task" CLAUDE_PROJECT_DIR="$CUSTOM_HOOK_REPO" \
  "$PLUGIN_ROOT/hooks/session-start.sh"
[ ! -e "$CUSTOM_HOOK_REPO/.husky/post-commit" ]

printf 'hooks-test: ok\n'
