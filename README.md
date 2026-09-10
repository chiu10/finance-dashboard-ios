# 個人財務控制台（iPhone）

這是 iPhone-only 的原生 SwiftUI 個人財務控制台。舊有 HTML 骨架仍保留於 repository 歷史中，但不是產品 UI。

## 開啟方式

使用 Xcode 15 或較新版本開啟 `FinanceDashboard.xcodeproj`，選擇 iPhone simulator 或實機後執行。專案沒有第三方套件、沒有 API key，並以本機離線資料為優先。

核心規則和 Case A–L 的測試位於 `Sources/FinanceCore/` 與 `Tests/FinanceCoreTests/`。在完整 Xcode toolchain 上可執行：

```sh
swift test
xcodebuild -project FinanceDashboard.xcodeproj -scheme FinanceDashboard -sdk iphonesimulator build
```

本機資料在 App 的 Application Support 目錄中；不會寫入 repository。

## 可回退規則

- 每個可驗證的里程碑完成後建立一個 Git commit。
- 帳務資料庫與個人資料不納入版本控制。
- 回退前先查看 `git log --oneline`，再用 `git switch --detach <commit>` 檢視；確認後才決定是否還原工作分支。

第一個 checkpoint 是此專案基線。
