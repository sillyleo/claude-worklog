# claude-worklog

自動追蹤 Claude Code 工作時間的 plugin。每次 git commit 時，自動記錄工時到專案的 `worklog.md`。

## 功能

- **Session 追蹤**：記錄每次 Claude Code 對話的開始時間
- **Heartbeat**：透過 PostToolUse hook 持續更新活動時間，自動排除超過 2 小時的 idle 時間
- **Commit 偵測**：偵測到 `git commit` 時，自動將工時記錄寫入 `worklog.md`
- **累積工時**：精確計算實際工作時間（排除 idle），commit 後自動重置計時器

## 安裝

### Plugin 安裝

```bash
# 加入 marketplace
claude plugin marketplace add sillyleo/claude-worklog --scope user

# 安裝 plugin
claude plugin install claude-worklog@sillyleo-plugins --scope user

# 或開發測試模式（不安裝）
claude --plugin-dir ~/Documents/GitHub/claude-worklog
```

### Status Line（選配）

Plugin 不含 status line（Claude Code 不支援 plugin 貢獻 status line）。如需在底部顯示累積工時計時器，手動設定：

```bash
# 複製 statusline.sh 到 ~/.claude/
cp statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

在 `~/.claude/settings.json` 加入：

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

Status line 會顯示：`user@host ~/project (branch ✓) ⏱12m`

## 輸出格式

工時記錄在專案根目錄的 `worklog.md`：

```markdown
# Work Log

| Date | Start | End | Duration | Commit |
|------|-------|-----|----------|--------|
| 2025-02-07 | 14:30 | 15:45 | 1h 15m | feat: 新增購物車功能 |
| 2025-02-07 | 15:45 | 16:20 | 35m | fix: 修正結帳流程 |
```

- **Start**：上次 commit 時間（或 session 開始時間）
- **End**：本次 commit 時間
- **Duration**：實際工作時間（已排除 idle）

## 運作原理

1. **SessionStart** hook：初始化 `.claude/.session_activity` 追蹤檔
2. **PostToolUse** hook：
   - 每次工具使用時更新 heartbeat（間隔 > 2h 視為 idle，不計入工時）
   - 偵測到 `git commit` 指令時，計算累積工時並寫入 `worklog.md`
   - Commit 後重置計時器，下一段工時從此刻開始
3. **statusline.sh**（選配）：讀取 `.session_activity` 在 status line 顯示即時工時

## License

MIT
