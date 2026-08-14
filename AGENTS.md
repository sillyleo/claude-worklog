# Worklog 安裝指示

若使用者只把這個 repo 連結交給你，視為要求在目前電腦完成 Codex Worklog 安裝與同步。

1. 若尚未取得 repo，先 clone `https://github.com/sillyleo/claude-worklog.git`。
2. 在 repo 根目錄執行 `bash scripts/install-codex.sh`。
3. 腳本成功後，確認它回報 `claude-worklog 安裝完成`，再請使用者開一個新的 Codex task。
4. 不要手動覆寫 `~/Documents/GitHub/worklog`。若腳本因路徑、origin、未提交變更或認證失敗而停止，保留原資料並回報錯誤。
5. 單純安裝時不要修改、commit 或 push 這兩個 repo。

安裝腳本會自行處理：

- clone 或快轉同步 `https://github.com/sillyleo/worklog.git`
- 新增或更新 `sillyleo-plugins` marketplace
- 安裝並啟用 `claude-worklog`
- 驗證 Codex 已載入 plugin
