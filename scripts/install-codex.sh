#!/bin/bash

set -euo pipefail

WORKLOG_ROOT="${WORKLOG_ROOT:-$HOME/Documents/GitHub/worklog}"
WORKLOG_REPOSITORY="${WORKLOG_REPOSITORY:-https://github.com/sillyleo/worklog.git}"
PLUGIN_MARKETPLACE_SOURCE="${PLUGIN_MARKETPLACE_SOURCE:-sillyleo/claude-worklog}"
PLUGIN_MARKETPLACE_NAME="${PLUGIN_MARKETPLACE_NAME:-sillyleo-plugins}"
PLUGIN_NAME="claude-worklog"

fail() {
  printf 'claude-worklog 安裝失敗：%s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "找不到 $1，請先安裝後再重試。"
}

normalize_repository() {
  REPOSITORY="$1"
  case "$REPOSITORY" in
    git@github.com:*) REPOSITORY="https://github.com/${REPOSITORY#git@github.com:}" ;;
    ssh://git@github.com/*) REPOSITORY="https://github.com/${REPOSITORY#ssh://git@github.com/}" ;;
  esac
  REPOSITORY="${REPOSITORY%.git}"
  printf '%s\n' "${REPOSITORY%/}"
}

require_command git
require_command codex

# Worklog repo 不存在就建立；已存在時只允許正確、乾淨的 clone，避免覆寫資料。
if [ ! -e "$WORKLOG_ROOT" ]; then
  mkdir -p "$(dirname -- "$WORKLOG_ROOT")"
  git clone --branch main "$WORKLOG_REPOSITORY" "$WORKLOG_ROOT"
elif ! git -C "$WORKLOG_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  fail "$WORKLOG_ROOT 已存在但不是 Git repo，未進行覆寫。"
else
  ORIGIN_URL=$(git -C "$WORKLOG_ROOT" remote get-url origin 2>/dev/null || true)
  [ -n "$ORIGIN_URL" ] || fail "$WORKLOG_ROOT 沒有 origin，無法確認同步來源。"
  if [ "$(normalize_repository "$ORIGIN_URL")" != "$(normalize_repository "$WORKLOG_REPOSITORY")" ]; then
    fail "$WORKLOG_ROOT 的 origin 不是 $WORKLOG_REPOSITORY，未進行覆寫。"
  fi
fi

if [ -n "$(git -C "$WORKLOG_ROOT" status --porcelain --untracked-files=no)" ]; then
  fail "$WORKLOG_ROOT 有尚未提交的變更，請先處理後再重試。"
fi

WORKLOG_BRANCH=$(git -C "$WORKLOG_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$WORKLOG_BRANCH" ] || fail "$WORKLOG_ROOT 目前不是一般分支。"
git -C "$WORKLOG_ROOT" pull --ff-only origin "$WORKLOG_BRANCH"
git -C "$WORKLOG_ROOT" push origin "HEAD:$WORKLOG_BRANCH"

# Marketplace 已存在就更新，不存在才新增；接著安裝並驗證 plugin 已啟用。
MARKETPLACE_LIST=$(codex plugin marketplace list --json)
MARKETPLACE_COMPACT=$(printf '%s' "$MARKETPLACE_LIST" | tr -d '[:space:]')
if printf '%s' "$MARKETPLACE_COMPACT" | grep -Fq "\"name\":\"$PLUGIN_MARKETPLACE_NAME\""; then
  codex plugin marketplace upgrade "$PLUGIN_MARKETPLACE_NAME"
else
  codex plugin marketplace add "$PLUGIN_MARKETPLACE_SOURCE"
fi

codex plugin add "$PLUGIN_NAME@$PLUGIN_MARKETPLACE_NAME"

PLUGIN_LIST=$(codex plugin list --marketplace "$PLUGIN_MARKETPLACE_NAME" --json)
PLUGIN_COMPACT=$(printf '%s' "$PLUGIN_LIST" | tr -d '[:space:]')
printf '%s' "$PLUGIN_COMPACT" | \
  grep -Fq "\"pluginId\":\"$PLUGIN_NAME@$PLUGIN_MARKETPLACE_NAME\"" || \
  fail "Codex 查不到已安裝的 $PLUGIN_NAME。"
printf '%s' "$PLUGIN_COMPACT" | grep -Fq '"enabled":true' || \
  fail "$PLUGIN_NAME 尚未啟用。"

printf '\nclaude-worklog 安裝完成。\n'
printf 'Worklog：%s\n' "$WORKLOG_ROOT"
printf '請開啟新的 Codex task，讓新版 hook 開始追蹤。\n'
