#!/bin/bash

set -euo pipefail

PLUGIN_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$PLUGIN_ROOT/hooks/activity-state.sh"

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

to_epoch() {
  date -j -f '%Y-%m-%d %H:%M:%S' "$1" '+%s' 2>/dev/null ||
    date -d "$1" '+%s'
}

assert_eq() {
  [ "$1" = "$2" ] || {
    printf '預期：%s\n實際：%s\n' "$2" "$1" >&2
    exit 1
  }
}

ACTIVITY_FILE="$TEST_ROOT/activity"
SEGMENTS_FILE="$ACTIVITY_FILE.segments"
LEGACY_FILE="$TEST_ROOT/legacy"
SESSION_ID='test-session'

# 舊格式升級時以 last-total 建立等值區段，不丟失已累積秒數。
LEGACY_LAST=$(to_epoch '2026-09-25 16:00:00')
LEGACY_START=$(to_epoch '2026-09-25 15:28:00')
printf '%s|%s|%s|1800\n' "$SESSION_ID" "$LEGACY_START" "$LEGACY_LAST" > "$ACTIVITY_FILE"
activity_load "$ACTIVITY_FILE" "$SEGMENTS_FILE" "$SESSION_ID" "$LEGACY_LAST"
assert_eq "$ACTIVITY_TOTAL" '1800'
assert_eq "$(cat "$SEGMENTS_FILE")" "$((LEGACY_LAST - 1800))|$LEGACY_LAST|1800"

# 少於兩小時全部計入；剛好兩小時則整段排除並開始新區段。
BASE=$(to_epoch '2026-09-26 09:00:00')
printf '%s|%s|%s|0\n' "$SESSION_ID" "$BASE" "$BASE" > "$ACTIVITY_FILE"
printf '%s|%s|0\n' "$BASE" "$BASE" > "$SEGMENTS_FILE"
activity_load "$ACTIVITY_FILE" "$SEGMENTS_FILE" "$SESSION_ID" "$BASE"
activity_record "$((BASE + 7199))" 7200
assert_eq "$ACTIVITY_TOTAL" '7199'
activity_record "$((BASE + 14399))" 7200
assert_eq "$ACTIVITY_TOTAL" '7199'
assert_eq "$(wc -l < "$SEGMENTS_FILE" | tr -d ' ')" '2'

# timeout 前後的工時分成兩個區段，兩邊都保留。
FIRST_START=$(to_epoch '2026-09-26 09:00:00')
FIRST_END=$(to_epoch '2026-09-26 10:00:00')
SECOND_START=$(to_epoch '2026-09-26 13:00:00')
SECOND_END=$(to_epoch '2026-09-26 14:11:00')
printf '%s|%s|%s|3600\n' "$SESSION_ID" "$FIRST_START" "$FIRST_END" > "$ACTIVITY_FILE"
printf '%s|%s|3600\n' "$FIRST_START" "$FIRST_END" > "$SEGMENTS_FILE"
activity_load "$ACTIVITY_FILE" "$SEGMENTS_FILE" "$SESSION_ID" "$FIRST_END"
activity_record "$SECOND_START" 7200
activity_record "$SECOND_END" 7200
assert_eq "$ACTIVITY_TOTAL" '7860'

ROWS="$TEST_ROOT/rows.md"
activity_write_worklog_rows "$SECOND_END" 'test: segmented work' "$ROWS"
grep -Fq '| 2026-09-26 | 09:00 | 10:00 | 1h 0m | test: segmented work |' "$ROWS"
grep -Fq '| 2026-09-26 | 13:00 | 14:11 | 1h 11m | test: segmented work |' "$ROWS"

# 跨午夜的連續區段拆成兩天，結束時間不倒置，總分鐘數保持不變。
MIDNIGHT_START=$(to_epoch '2026-09-26 23:30:00')
MIDNIGHT_END=$(to_epoch '2026-09-27 00:30:00')
printf '%s|%s|3600\n' "$MIDNIGHT_START" "$MIDNIGHT_END" > "$SEGMENTS_FILE"
MIDNIGHT_ROWS="$TEST_ROOT/midnight.md"
activity_write_worklog_rows "$MIDNIGHT_END" 'test: midnight work' "$MIDNIGHT_ROWS"
grep -Fq '| 2026-09-26 | 23:30 | 24:00 | 30m | test: midnight work |' "$MIDNIGHT_ROWS"
grep -Fq '| 2026-09-27 | 00:00 | 00:30 | 30m | test: midnight work |' "$MIDNIGHT_ROWS"
assert_eq "$(awk -F'|' '/test: midnight work/ { gsub(/[^0-9]/, "", $5); total += $5 } END { print total }' "$MIDNIGHT_ROWS")" '60'

printf 'activity-state-test: ok\n'
