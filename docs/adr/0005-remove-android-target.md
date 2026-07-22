# ADR-0005：移除 Android 產品目標

- 狀態：Accepted
- 日期：2026-07-22
- 決策者：客戶／產品負責人

## 背景

客戶在 MVP 開發期間明確要求停止支援 Android。繼續保留 Android runner、CI
工作或驗收條件，會造成產品範圍與實際承諾不一致。

## 決策

Kotoba 的主要平台調整為 iOS、Windows、macOS。專案不再提供 Android runner、
Android build job、Android 發布產物或 Android 驗收承諾；規格、架構、roadmap、
backlog 與測試矩陣同步改為三平台。

Flutter 套件鎖定檔仍可能含有套件作者提供的 Android federated implementation。
這是相依性解析結果，不代表本專案提供 Android target；判斷依據為 runner、CI、
產品文件與發布產物。

## 影響

- Android 不列入 MVP 與後續 release gate。
- 行動裝置驗收以 iOS 為準。
- 若未來恢復 Android，須另開 scope change，重新建立 runner、簽章、CI、實機與
  商店發布流程，不能視為自動恢復支援。
