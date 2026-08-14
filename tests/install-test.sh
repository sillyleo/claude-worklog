#!/bin/bash

set -euo pipefail

PLUGIN_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export CODEX_TEST_LOG="$TEST_ROOT/codex.log"
export CODEX_TEST_STATE="$TEST_ROOT/codex-state"
FAKE_BIN="$TEST_ROOT/bin"
WORKLOG_SOURCE="$TEST_ROOT/worklog-source"
WORKLOG_REMOTE="$TEST_ROOT/worklog.git"
export WORKLOG_ROOT="$HOME/Documents/GitHub/worklog"
export WORKLOG_REPOSITORY="$WORKLOG_REMOTE"
export PLUGIN_MARKETPLACE_SOURCE="$TEST_ROOT/claude-worklog"

mkdir -p "$HOME" "$FAKE_BIN" "$WORKLOG_SOURCE"
git -C "$WORKLOG_SOURCE" init -q -b main
git -C "$WORKLOG_SOURCE" config user.name "Installer Test"
git -C "$WORKLOG_SOURCE" config user.email "installer@example.com"
printf 'worklog\n' > "$WORKLOG_SOURCE/README.md"
git -C "$WORKLOG_SOURCE" add README.md
git -C "$WORKLOG_SOURCE" commit -q -m 'test: initial worklog'
git clone -q --bare "$WORKLOG_SOURCE" "$WORKLOG_REMOTE"

cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$CODEX_TEST_LOG"

case "$*" in
  'plugin marketplace list --json')
    if [ -f "$CODEX_TEST_STATE/marketplace" ]; then
      printf '{"marketplaces":[{"name":"sillyleo-plugins"}]}\n'
    else
      printf '{"marketplaces":[]}\n'
    fi
    ;;
  plugin\ marketplace\ add\ *)
    mkdir -p "$CODEX_TEST_STATE"
    : > "$CODEX_TEST_STATE/marketplace"
    ;;
  'plugin marketplace upgrade sillyleo-plugins')
    [ -f "$CODEX_TEST_STATE/marketplace" ]
    ;;
  'plugin add claude-worklog@sillyleo-plugins')
    mkdir -p "$CODEX_TEST_STATE"
    : > "$CODEX_TEST_STATE/plugin"
    ;;
  'plugin list --marketplace sillyleo-plugins --json')
    [ -f "$CODEX_TEST_STATE/plugin" ]
    printf '{"installed":[{"pluginId":"claude-worklog@sillyleo-plugins","enabled":true}]}\n'
    ;;
  *)
    printf 'unexpected codex command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$FAKE_BIN/codex"
export PATH="$FAKE_BIN:$PATH"

"$PLUGIN_ROOT/scripts/install-codex.sh"
[ -d "$WORKLOG_ROOT/.git" ]
[ "$(git -C "$WORKLOG_ROOT" remote get-url origin)" = "$WORKLOG_REMOTE" ]
grep -Fq "plugin marketplace add $PLUGIN_MARKETPLACE_SOURCE" "$CODEX_TEST_LOG"
grep -Fq 'plugin add claude-worklog@sillyleo-plugins' "$CODEX_TEST_LOG"

"$PLUGIN_ROOT/scripts/install-codex.sh"
grep -Fq 'plugin marketplace upgrade sillyleo-plugins' "$CODEX_TEST_LOG"
[ "$(grep -c '^plugin add claude-worklog@sillyleo-plugins$' "$CODEX_TEST_LOG")" = "2" ]

# 已有未提交變更時必須停止，不能覆寫或自動提交。
printf 'dirty\n' >> "$WORKLOG_ROOT/README.md"
if "$PLUGIN_ROOT/scripts/install-codex.sh" > "$TEST_ROOT/dirty.out" 2>&1; then
  printf 'installer unexpectedly accepted dirty worklog repo\n' >&2
  exit 1
fi
grep -Fq '有尚未提交的變更' "$TEST_ROOT/dirty.out"
grep -Fq 'dirty' "$WORKLOG_ROOT/README.md"
git -C "$WORKLOG_ROOT" restore README.md

# 固定路徑已有其他資料時也必須停止，不能刪除或重新 clone。
BLOCKED_ROOT="$HOME/Documents/GitHub/not-a-repo"
mkdir -p "$BLOCKED_ROOT"
printf 'keep\n' > "$BLOCKED_ROOT/keep.txt"
if WORKLOG_ROOT="$BLOCKED_ROOT" "$PLUGIN_ROOT/scripts/install-codex.sh" \
  > "$TEST_ROOT/blocked.out" 2>&1; then
  printf 'installer unexpectedly overwrote a non-repo directory\n' >&2
  exit 1
fi
grep -Fq '已存在但不是 Git repo' "$TEST_ROOT/blocked.out"
grep -Fq 'keep' "$BLOCKED_ROOT/keep.txt"

printf 'install-test: ok\n'
