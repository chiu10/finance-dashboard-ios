# Arena Direct 接手說明

這是原生 iPhone Swift／SwiftUI 財務控制台的目前工作樹來源碼。請直接接手開發，不要把它改成 Next.js 或 Web App。

先讀 `README.md`、`DOMAIN.md`、`ACCEPTANCE.md`，再檢查 `Sources/FinanceCore`、`FinanceDashboard`、`Tests`。保留現有資料模型與未提交進度，所有變更可回退；不要要求帳務資料、收據、金鑰或私密設定。

優先完成：成員／標籤獨立 CRUD、外幣現金匯率換算、首頁卡片與日曆彩點／逐筆刪改、允許有歷史帳戶軟刪除、固定支出預留且到期不重扣、直立柱狀圖。完整需求和已確認財務規則請從 `DOMAIN.md` 與 `ACCEPTANCE.md` 核對。

交付時回報實際修改檔案、migration、測試與 build 結果、未執行項目及回退點。沒有 Xcode 時仍修改與測試可執行的 Swift package；不要宣稱 iOS build 或 Simulator 已通過。
