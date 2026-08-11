#!/bin/bash
# 安裝 claude-worklog Git post-commit wrapper，並保留既有 hooks

set -euo pipefail

PROJECT_DIR="${1:-${CLAUDE_PROJECT_DIR:-}}"
[ -n "$PROJECT_DIR" ] || exit 0

if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORKLOG_ROOT="${WORKLOG_ROOT:-$HOME/Documents/GitHub/worklog}"
STABLE_SCRIPT="$WORKLOG_ROOT/.claude-worklog-post-commit.sh"
HOOKS_DIR=$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-path hooks)
HOOK_PATH="$HOOKS_DIR/post-commit"
CHAIN_DIR="$HOOKS_DIR/post-commit.claude-worklog.d"
MARKER="# claude-worklog managed post-commit wrapper"

# 只寫 Git 內部目錄。若專案把 core.hooksPath 指到 working tree
#（例如 .husky/），跳過安裝，避免把 wrapper 寫進專案檔案。
GIT_COMMON_DIR=$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-common-dir)
case "$HOOKS_DIR" in
  "$GIT_COMMON_DIR"/*) : ;;
  *) exit 0 ;;
esac

mkdir -p "$(dirname -- "$STABLE_SCRIPT")" "$HOOKS_DIR" "$CHAIN_DIR"
cp "$SCRIPT_DIR/git-post-commit.sh" "$STABLE_SCRIPT"
chmod +x "$STABLE_SCRIPT"

# 第一次安裝時，把原有 hook 移入串接目錄，避免覆蓋其他工具的行為
if [ -f "$HOOK_PATH" ] && ! grep -Fq "$MARKER" "$HOOK_PATH"; then
  ORIGINAL_HOOK="$CHAIN_DIR/original-$(date '+%s')-$$"
  mv "$HOOK_PATH" "$ORIGINAL_HOOK"
  chmod +x "$ORIGINAL_HOOK"
fi

TMP_HOOK="$HOOK_PATH.tmp.$$"
cat > "$TMP_HOOK" <<'EOF'
#!/bin/sh
# claude-worklog managed post-commit wrapper

HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

for chained_hook in "$HOOK_DIR/post-commit.claude-worklog.d/"*; do
  [ -f "$chained_hook" ] || continue
  [ -x "$chained_hook" ] && "$chained_hook" "$@" || true
done

WORKLOG_ROOT="${WORKLOG_ROOT:-$HOME/Documents/GitHub/worklog}"
TRACKER="$WORKLOG_ROOT/.claude-worklog-post-commit.sh"
[ -x "$TRACKER" ] && "$TRACKER" "$@" || true

exit 0
EOF
chmod +x "$TMP_HOOK"
mv "$TMP_HOOK" "$HOOK_PATH"

exit 0
