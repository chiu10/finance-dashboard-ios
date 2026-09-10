# 原始需求驗收與續作記錄

更新：2026-09-05。程式基準：51caa22。本文件是未完成驗收清單，不能當作 DONE 證明。

## 已有可重現證據

- Swift 核心測試 36/36 通過，包含原 Case A–L 對應測試、持久化、migration、固定交易、歷史分類保留與分析期間邊界。
- iOS Simulator SDK 原生 target 編譯成功；未安裝 Simulator runtime，尚未實際啟動 App 或做 Face ID／UI 操作驗收。
- 最近回退節點：a1ca77b（保留歷史 soft-delete 參照）、cf20fc0（分類利息與實際預算比例）、51caa22（分析期間與貸款明細）。
- 安全掃描 9827bb16-3872-4131-84f0-0043613196cf 只涵蓋 a1ca77b 的兩檔修正，0 findings。掃描期間出現 build 產物造成 working-tree 變更警告；不可將該結果外推為全專案或後續提交安全通過。

## 完整規格覆蓋索引

每列都仍需逐項驗收；程式存在不代表產品行為已驗收。

| 原需求 | 主要證據入口 | 待補證據／缺口 |
|---|---|---|
| 0、36、41–44 原生 iPhone、scope、工程與交付 | Xcode project、README、全 repo diff | 實際 iPhone UI、全需求驗收、最終 review 與安全掃描 |
| 1、3、10–12 收支、可用結餘、轉帳、卡費、貸款 | Ledger.swift、核心 Case A–F、DashboardView | 多筆混合流程 UI、分類明細與總額一致性 |
| 2、4–6 首頁、淨資產、帳戶、快速記帳 | RootView、DashboardView、AccountsView、LedgerEntryView | 小螢幕、Dynamic Type、VoiceOver、完整快速記帳操作 |
| 7 精確計算機 | AmountCalculator.swift、Money.swift、testCalculator | 小數與連續運算 UI；TWD 現採零小數，需核對使用者小數輸入需求 |
| 8–9 分類與備註 | SettingsView、FinanceDashboardApp | 分類排序、刪除後歷史編輯、備註保存操作 |
| 13 固定收扣款 | RecurringTransactionService、occurrences tests | 跨月份未開啟 App 的補入政策與驗證；目前只補本月到期項 |
| 14–16 預算、異常、預測 | BudgetService、SpendingInsightService、ForecastService | 超標整月狀態在修改／刪除後是否需鎖存；低樣本提示與未設預算分類 UI |
| 17–23 股票、Crypto、買賣、股息、未實現 | Models、Analytics、Ledger、AccountOperationsView | 股息 asset 關聯驗證；部分賣出、多幣別、報酬率與畫面逐欄核對 |
| 24 行情 | MarketData.swift、quote failure tests | Binance 真實網路驗證；股票目前 UnavailableStockQuoteProvider，未接台／美股來源 |
| 25 淨資產快照 | SnapshotService、App lifecycle | 同日多次資產變動、跨日更新、資料還原後一致性 |
| 26–29 分析、排名、趨勢、淨資產 | AnalysisView、ManagementViews、AnalysisPeriod、CashFlowTrendService | 本週／本月目前使用 monthly trend，單月不顯示曲線；自訂期間查詢 E2E |
| 30 淨資產成長來源 | NetWorthGrowthService、testNetWorthGrowth | 完整負債變動場景、避免重複歸因與無法分類變動顯示 |
| 31 Face ID | App requireAuthentication、RootView | 裝置密碼 fallback、背景返回與取消辨識的實機驗證 |
| 32 雲端帳號／同步 | LedgerSyncProvider、OfflineOnlySyncProvider | 目前僅抽象層，無登入、跨裝置下載或真實 backend；不能宣稱同步完成 |
| 33 備份匯出還原 | SettingsView、LedgerBackupCodec、LedgerRepository | 檔案匯入匯出 UI、全實體 round-trip、壞檔拒絕及 rollback |
| 34–35 Audit、垃圾桶 | Persistence.swift、audit／purge tests | 30 天邊界、還原相依投資交易、垃圾桶實際操作 |
| 37–39 schema、服務層、migration | Models schema v3、Persistence、各 calculator | 所有 UUID／日期／數值輸入驗證；LocalDate 目前只檢查 Calendar 可建日期，需檢查無效日期正規化問題 |
| 40 A–L | FinanceCoreTests.swift | 現有案例通過但不是整份產品規格完整覆蓋 |

## 下一段工作

1. （取消）
2. 優先驗證 LocalDate 對 2 月 30 日、month 13 等無效資料是否拒絕；如可重現，修正共同入口並測試 decode 邊界。
3. 改進本週／本月收支趨勢的日粒度，避免整個單月只能看到「至少兩個月份」提示。
4. 回到使用者指定 ChatGPT 專案原對話進行文字摘要審查循環。使用者已授權此循環，不重複要求送出確認。只送任務／成果摘要，不貼本機檔案、diff、logs 或憑證。遵守使用者不嘗試臨時地址的指示。
5. 完成剩餘實作後，依 Ponytail、review-agent、Codex Security／attack-path-analysis 驗收；不要逐次小改都啟動完整掃描耗用額度。

## 重現指令

```sh
swift test
xcodebuild -quiet -project FinanceDashboard.xcodeproj -target FinanceDashboard -configuration Debug -sdk iphonesimulator SYMROOT=/private/tmp/finance-dashboard-verification CODE_SIGNING_ALLOWED=NO build
git diff --check
```

