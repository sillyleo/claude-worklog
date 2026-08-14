# claude-worklog

自動追蹤 Claude Code 與 Codex 工作時間的 plugin。透過 Git `post-commit`，無論 commit 來自 Claude Code、Codex 或一般終端機，都會記錄到 `~/Documents/GitHub/worklog/<repo-name>/worklog.md`，不污染 repo。

## 功能

- **Session 追蹤**：記錄每次 Claude Code 或 Codex 對話的開始時間
- **並行 task**：同一 repo 內依 Codex task 分開計時，重疊工時會各自寫入與計費
- **跨日續接**：尚未 commit 的累積工時保留在原對話，隔夜 idle 不計入
- **Heartbeat**：透過 PostToolUse hook 持續更新活動時間，自動排除超過 2 小時的 idle 時間
- **Commit 偵測**：透過 Git `post-commit` 自動記錄，不依賴代理工具名稱或指令格式
- **終端機支援**：專案開啟過一次後，一般終端機執行 `git commit` 也會記錄
- **既有 hook 相容**：安裝時保留並串接專案原本的 `post-commit`
- **累積工時**：精確計算實際工作時間（排除 idle），commit 後自動重置計時器
- **集中存放**：所有專案的工時紀錄統一收在 `~/Documents/GitHub/worklog/<repo-name>/`，repo 樹保持乾淨
- **跨電腦同步**：每次寫入前先取得遠端紀錄，寫入後自動推送；離線時保留本機 commit，下次自動重試

## 安裝

### Claude Code 安裝

```bash
# 加入 marketplace
claude plugin marketplace add sillyleo/claude-worklog --scope user

# 安裝 plugin
claude plugin install claude-worklog@sillyleo-plugins --scope user

# 或開發測試模式（不安裝）
claude --plugin-dir ~/Documents/GitHub/claude-worklog
```

### Codex 安裝

repo 內含 `.codex-plugin/plugin.json`，並支援 Codex 的 hook payload。

```bash
# 加入 marketplace
codex plugin marketplace add sillyleo/claude-worklog
```

加入 marketplace 後，在 Codex App 的 Plugins 頁面啟用 `claude-worklog`。

另一台電腦使用前，先把同一個 Worklog repo clone 到固定位置，再安裝並啟用 plugin：

```bash
git clone https://github.com/sillyleo/worklog.git ~/Documents/GitHub/worklog
codex plugin marketplace add sillyleo/claude-worklog
```

若目錄已存在，請使用既有 clone，不要再次執行 `git clone`。

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

工時記錄寫到 `~/Documents/GitHub/worklog/<repo-name>/worklog.md`（其中 `<repo-name>` = git toplevel basename，沒 git 就用專案目錄 basename）：

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

## 檔案位置

所有追蹤資料統一放在 `~/Documents/GitHub/worklog/<repo-name>/`：

```
~/Documents/GitHub/worklog/
├── smking/
│   ├── worklog.md
│   ├── .session_start
│   ├── .session_activity
│   └── .sessions/
│       ├── <task-a>.activity
│       └── <task-b>.activity
├── my-other-repo/
│   └── worklog.md
└── ...
```

從舊版本升級時，SessionStart hook 會自動把 repo 內舊位置 (`$PROJECT_DIR/worklog.md` / `$PROJECT_DIR/.claude/.session_*`) 一次性 **copy** 到新位置（不刪舊檔，自行刪除並從 git 移除）。

## 運作原理

1. **SessionStart** hook：解析 `<repo-name>` 與 task 識別碼、初始化 task 專屬活動追蹤，並安裝 Git `post-commit` wrapper；已存在的 task 計時不會被新 task 或跨日 resume 覆蓋，升級時也會接回識別碼相同的舊版未結算工時
2. **PostToolUse** hook：每次 Claude Code 或 Codex 使用工具時更新該 task 的 heartbeat（間隔 > 2h 視為 idle，不計入工時，但既有累積工時會保留）
3. **Git post-commit**：commit 成功後先同步 Worklog repo，依 `CODEX_THREAD_ID` 取回該 task 的累積時間、寫入 `worklog.md`，只提交這份紀錄並推送遠端，再只重置該 task 的計時器
4. **statusline.sh**（選配）：讀取對應 repo 的 `.session_activity` 在 status line 顯示即時工時

若完全沒有 Claude Code 或 Codex 工作階段可供計時，一般終端機 commit 仍會寫入，但該筆 Duration 會是 `0m`。
兩個 Codex task 即使時間重疊，只要各自 commit，就會產生兩筆獨立工時；計費工具會分別計入。
同一個對話可以在未 commit 的狀態下隔天 resume；commit 時會結算該對話跨日保留的累積工時，不會計入隔夜 idle。
兩台電腦同時追加同一份 `worklog.md` 時會保留雙方紀錄；其他檔案若發生無法安全解決的衝突，會保留本機 commit 並停止推送，不會 force push。

## License

MIT
