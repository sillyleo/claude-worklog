#!/bin/bash

# task 計時狀態的共同實作。activity 檔維持舊的四欄格式供 status line 使用，
# 另以 .segments 保存可正確跨日、跨 timeout 結算的工作區段。

activity_is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

activity_epoch_date() {
  date -r "$1" '+%Y-%m-%d' 2>/dev/null || date -d "@$1" '+%Y-%m-%d'
}

activity_epoch_time() {
  date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M'
}

activity_next_midnight() {
  ACTIVITY_DATE=$(activity_epoch_date "$1")
  date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$ACTIVITY_DATE 00:00:00" '+%s' 2>/dev/null ||
    date -d "$ACTIVITY_DATE +1 day 00:00:00" '+%s'
}

activity_sum_segments() {
  awk -F'|' '
    $3 ~ /^[0-9]+$/ { total += $3 }
    END { printf "%d", total + 0 }
  ' "$ACTIVITY_SEGMENTS_FILE"
}

activity_refresh_summary() {
  ACTIVITY_START=$(awk -F'|' 'NR == 1 { print $1; exit }' "$ACTIVITY_SEGMENTS_FILE")
  ACTIVITY_TOTAL=$(activity_sum_segments)
  activity_is_uint "$ACTIVITY_START" || ACTIVITY_START="$ACTIVITY_LAST"
}

activity_load() {
  ACTIVITY_FILE="$1"
  ACTIVITY_SEGMENTS_FILE="$2"
  ACTIVITY_SESSION_ID="$3"
  ACTIVITY_NOW="$4"
  ACTIVITY_START="$ACTIVITY_NOW"
  ACTIVITY_LAST="$ACTIVITY_NOW"
  ACTIVITY_TOTAL=0

  if [ -f "$ACTIVITY_FILE" ]; then
    IFS='|' read -r ACTIVITY_STORED_SESSION ACTIVITY_START ACTIVITY_LAST ACTIVITY_TOTAL < "$ACTIVITY_FILE"
    activity_is_uint "$ACTIVITY_START" || ACTIVITY_START="$ACTIVITY_NOW"
    activity_is_uint "$ACTIVITY_LAST" || ACTIVITY_LAST="$ACTIVITY_NOW"
    activity_is_uint "$ACTIVITY_TOTAL" || ACTIVITY_TOTAL=0
  fi

  # 舊格式只有總秒數，無法還原每次 heartbeat。以 last-total 建立等值區段，
  # 完整保留已累積工時，且不再沿用可能跨日的舊 start。
  ACTIVITY_SEGMENTS_TOTAL=''
  ACTIVITY_SEGMENTS_LAST=''
  if [ -s "$ACTIVITY_SEGMENTS_FILE" ]; then
    ACTIVITY_SEGMENTS_TOTAL=$(activity_sum_segments)
    ACTIVITY_SEGMENTS_LAST=$(awk -F'|' 'END { print $2 }' "$ACTIVITY_SEGMENTS_FILE")
  fi
  if [ ! -s "$ACTIVITY_SEGMENTS_FILE" ] || \
    [ "$ACTIVITY_SEGMENTS_TOTAL" != "$ACTIVITY_TOTAL" ] || \
    [ "$ACTIVITY_SEGMENTS_LAST" != "$ACTIVITY_LAST" ]; then
    ACTIVITY_SYNTHETIC_START=$((ACTIVITY_LAST - ACTIVITY_TOTAL))
    [ "$ACTIVITY_SYNTHETIC_START" -ge 0 ] || ACTIVITY_SYNTHETIC_START="$ACTIVITY_LAST"
    printf '%s|%s|%s\n' \
      "$ACTIVITY_SYNTHETIC_START" "$ACTIVITY_LAST" "$ACTIVITY_TOTAL" \
      > "$ACTIVITY_SEGMENTS_FILE"
  fi

  activity_refresh_summary
}

activity_replace_last_segment() {
  ACTIVITY_NEW_END="$1"
  ACTIVITY_DELTA="$2"
  ACTIVITY_TMP_FILE="$ACTIVITY_SEGMENTS_FILE.tmp.$$"
  awk -F'|' -v OFS='|' -v new_end="$ACTIVITY_NEW_END" -v delta="$ACTIVITY_DELTA" '
    { rows[NR] = $0 }
    END {
      for (i = 1; i < NR; i++) print rows[i]
      split(rows[NR], last, "|")
      duration = last[3] + delta
      print last[1], new_end, duration
    }
  ' "$ACTIVITY_SEGMENTS_FILE" > "$ACTIVITY_TMP_FILE"
  mv "$ACTIVITY_TMP_FILE" "$ACTIVITY_SEGMENTS_FILE"
}

activity_start_segment() {
  ACTIVITY_SEGMENT_NOW="$1"
  ACTIVITY_LAST_DURATION=$(awk -F'|' 'END { print $3 + 0 }' "$ACTIVITY_SEGMENTS_FILE")
  if [ "$ACTIVITY_LAST_DURATION" -eq 0 ]; then
    ACTIVITY_TMP_FILE="$ACTIVITY_SEGMENTS_FILE.tmp.$$"
    awk -F'|' -v OFS='|' -v now="$ACTIVITY_SEGMENT_NOW" '
      { rows[NR] = $0 }
      END {
        for (i = 1; i < NR; i++) print rows[i]
        print now, now, 0
      }
    ' "$ACTIVITY_SEGMENTS_FILE" > "$ACTIVITY_TMP_FILE"
    mv "$ACTIVITY_TMP_FILE" "$ACTIVITY_SEGMENTS_FILE"
  else
    printf '%s|%s|0\n' "$ACTIVITY_SEGMENT_NOW" "$ACTIVITY_SEGMENT_NOW" \
      >> "$ACTIVITY_SEGMENTS_FILE"
  fi
}

activity_record() {
  ACTIVITY_RECORD_NOW="$1"
  ACTIVITY_MAX_IDLE="$2"
  ACTIVITY_INTERVAL=$((ACTIVITY_RECORD_NOW - ACTIVITY_LAST))

  if [ "$ACTIVITY_INTERVAL" -ge 0 ] && [ "$ACTIVITY_INTERVAL" -lt "$ACTIVITY_MAX_IDLE" ]; then
    activity_replace_last_segment "$ACTIVITY_RECORD_NOW" "$ACTIVITY_INTERVAL"
  else
    activity_start_segment "$ACTIVITY_RECORD_NOW"
  fi

  ACTIVITY_LAST="$ACTIVITY_RECORD_NOW"
  activity_refresh_summary
}

activity_save() {
  ACTIVITY_LEGACY_FILE="$1"
  printf '%s|%s|%s|%s\n' \
    "$ACTIVITY_SESSION_ID" "$ACTIVITY_START" "$ACTIVITY_LAST" "$ACTIVITY_TOTAL" \
    > "$ACTIVITY_FILE"
  printf '%s|%s|%s|%s\n' \
    "$ACTIVITY_SESSION_ID" "$ACTIVITY_START" "$ACTIVITY_LAST" "$ACTIVITY_TOTAL" \
    > "$ACTIVITY_LEGACY_FILE"
}

activity_reset() {
  ACTIVITY_RESET_NOW="$1"
  ACTIVITY_LEGACY_FILE="$2"
  printf '%s|%s|%s|0\n' \
    "$ACTIVITY_SESSION_ID" "$ACTIVITY_RESET_NOW" "$ACTIVITY_RESET_NOW" \
    > "$ACTIVITY_FILE"
  printf '%s|%s|%s|0\n' \
    "$ACTIVITY_SESSION_ID" "$ACTIVITY_RESET_NOW" "$ACTIVITY_RESET_NOW" \
    > "$ACTIVITY_LEGACY_FILE"
  printf '%s|%s|0\n' "$ACTIVITY_RESET_NOW" "$ACTIVITY_RESET_NOW" \
    > "$ACTIVITY_SEGMENTS_FILE"
}

activity_format_minutes() {
  ACTIVITY_FORMAT_MINUTES="$1"
  ACTIVITY_HOURS=$((ACTIVITY_FORMAT_MINUTES / 60))
  ACTIVITY_MINUTES=$((ACTIVITY_FORMAT_MINUTES % 60))
  if [ "$ACTIVITY_HOURS" -gt 0 ]; then
    printf '%sh %sm' "$ACTIVITY_HOURS" "$ACTIVITY_MINUTES"
  else
    printf '%sm' "$ACTIVITY_MINUTES"
  fi
}

activity_write_segment_rows() {
  ACTIVITY_ROW_START="$1"
  ACTIVITY_ROW_END="$2"
  ACTIVITY_ROW_SECONDS="$3"
  ACTIVITY_ROW_MESSAGE="$4"
  ACTIVITY_ROW_FILE="$5"
  ACTIVITY_CURSOR="$ACTIVITY_ROW_START"
  ACTIVITY_REMAINING_SECONDS="$ACTIVITY_ROW_SECONDS"
  ACTIVITY_REMAINING_MINUTES=$((ACTIVITY_ROW_SECONDS / 60))

  while [ "$ACTIVITY_REMAINING_SECONDS" -gt 0 ]; do
    ACTIVITY_MIDNIGHT=$(activity_next_midnight "$ACTIVITY_CURSOR")
    ACTIVITY_BOUNDARY="$ACTIVITY_ROW_END"
    if [ "$ACTIVITY_MIDNIGHT" -lt "$ACTIVITY_BOUNDARY" ]; then
      ACTIVITY_BOUNDARY="$ACTIVITY_MIDNIGHT"
    fi

    ACTIVITY_PIECE_SECONDS=$((ACTIVITY_BOUNDARY - ACTIVITY_CURSOR))
    [ "$ACTIVITY_PIECE_SECONDS" -gt 0 ] || break

    if [ "$ACTIVITY_BOUNDARY" -eq "$ACTIVITY_ROW_END" ]; then
      ACTIVITY_PIECE_MINUTES="$ACTIVITY_REMAINING_MINUTES"
    else
      ACTIVITY_PIECE_MINUTES=$((ACTIVITY_PIECE_SECONDS / 60))
    fi
    ACTIVITY_REMAINING_MINUTES=$((ACTIVITY_REMAINING_MINUTES - ACTIVITY_PIECE_MINUTES))

    ACTIVITY_OUTPUT_DATE=$(activity_epoch_date "$ACTIVITY_CURSOR")
    ACTIVITY_OUTPUT_START=$(activity_epoch_time "$ACTIVITY_CURSOR")
    if [ "$ACTIVITY_BOUNDARY" -eq "$ACTIVITY_MIDNIGHT" ]; then
      ACTIVITY_OUTPUT_END='24:00'
    else
      ACTIVITY_OUTPUT_END=$(activity_epoch_time "$ACTIVITY_BOUNDARY")
    fi
    ACTIVITY_OUTPUT_DURATION=$(activity_format_minutes "$ACTIVITY_PIECE_MINUTES")
    printf '| %s | %s | %s | %s | %s |\n' \
      "$ACTIVITY_OUTPUT_DATE" "$ACTIVITY_OUTPUT_START" "$ACTIVITY_OUTPUT_END" \
      "$ACTIVITY_OUTPUT_DURATION" "$ACTIVITY_ROW_MESSAGE" >> "$ACTIVITY_ROW_FILE"

    ACTIVITY_CURSOR="$ACTIVITY_BOUNDARY"
    ACTIVITY_REMAINING_SECONDS=$((ACTIVITY_REMAINING_SECONDS - ACTIVITY_PIECE_SECONDS))
  done
}

activity_write_worklog_rows() {
  ACTIVITY_WRITE_NOW="$1"
  ACTIVITY_WRITE_MESSAGE="$2"
  ACTIVITY_WRITE_FILE="$3"
  ACTIVITY_ROWS_WRITTEN=0

  while IFS='|' read -r ACTIVITY_SEGMENT_START ACTIVITY_SEGMENT_END ACTIVITY_SEGMENT_SECONDS; do
    activity_is_uint "$ACTIVITY_SEGMENT_START" || continue
    activity_is_uint "$ACTIVITY_SEGMENT_END" || continue
    activity_is_uint "$ACTIVITY_SEGMENT_SECONDS" || continue
    # 與舊格式相同，以完整分鐘寫入；不足一分鐘的尾端不另產生 0m 重複列。
    [ "$ACTIVITY_SEGMENT_SECONDS" -ge 60 ] || continue
    activity_write_segment_rows \
      "$ACTIVITY_SEGMENT_START" "$ACTIVITY_SEGMENT_END" "$ACTIVITY_SEGMENT_SECONDS" \
      "$ACTIVITY_WRITE_MESSAGE" "$ACTIVITY_WRITE_FILE"
    ACTIVITY_ROWS_WRITTEN=$((ACTIVITY_ROWS_WRITTEN + 1))
  done < "$ACTIVITY_SEGMENTS_FILE"

  if [ "$ACTIVITY_ROWS_WRITTEN" -eq 0 ]; then
    ACTIVITY_OUTPUT_DATE=$(activity_epoch_date "$ACTIVITY_WRITE_NOW")
    ACTIVITY_OUTPUT_TIME=$(activity_epoch_time "$ACTIVITY_WRITE_NOW")
    printf '| %s | %s | %s | 0m | %s |\n' \
      "$ACTIVITY_OUTPUT_DATE" "$ACTIVITY_OUTPUT_TIME" "$ACTIVITY_OUTPUT_TIME" \
      "$ACTIVITY_WRITE_MESSAGE" >> "$ACTIVITY_WRITE_FILE"
  fi
}
