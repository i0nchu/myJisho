# ADR-0002：離線 SQLite 與辭典／個人資料庫實體隔離

- 狀態：Accepted
- 日期：2026-07-22

## Context

查詞必須完全離線、低延遲且能以完整資料包更新。收藏、歷史與設定不可因更新辭典而消失。若將兩者放在同一資料庫，整檔替換會危害個人資料；逐列更新則增加交易與相容複雜度。

## Decision

使用兩個 SQLite 檔案：

1. Dictionary DB：pipeline 建置、預先產生 search keys/indexes、App 正常執行唯讀、整包可原子替換。
2. User DB：App 擁有並可寫，保存 favorites/history/preferences，以穩定 entry ID 參照辭典。

Flutter infrastructure 以 Drift 提供 typed adapter，但 domain/application 只依賴 repository interfaces。所有外部引用使用 stable string ID，不暴露 rowid／auto-increment ID。

## Consequences

更新失敗不影響個人資料，dictionary query 與 user migration 可獨立測試。代價是無法用跨檔案 foreign key 強制 favorite 引用存在；需在 application 層處理 orphan，保留而不靜默刪除。Drift/platform SQLite 相容性需納入三平台 spike 與 CI。

## Rejected alternatives

- 單一 SQLite：整包更新與 user writes 衝突，rollback/data-loss 風險過高。
- 啟動時匯入 JSON：冷啟動與可重現性不符，300k 規模代價高。
- 遠端 database/API：違反離線核心需求。

## Verification

E2E 驗證重啟、成功／失敗更新後 favorites/history 不變；dictionary DB 以 read-only 開啟；100k query P95 <100ms；user DB migration fixtures 通過。
