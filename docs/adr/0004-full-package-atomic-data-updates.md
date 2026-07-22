# ADR-0004：MVP 採完整資料包的 staged 原子更新

- 狀態：Accepted
- 日期：2026-07-22

## Context

MVP 必須有基本資料更新，但更新中斷、壞檔或不相容不能破壞現有離線辭典；收藏與歷史必須保留。差分更新能節省頻寬，但顯著增加 patch、基底版本與 rollback 複雜度。

## Decision

MVP 發布完整 `dictionary.sqlite`、`assets-manifest.json`、`release-manifest.json`、`checksums.txt`。App 先驗證 manifest schema、dictionary/schema/minimum app version 和大小，再下載到 app-owned、同 volume staging；驗證實際大小、SHA-256 與 SQLite health。取得單一更新鎖、關閉 dictionary connections、保留 known-good backup，以原子 rename/replace 啟用；reopen/health check 失敗則 rollback。啟動時依 transaction marker 復原中斷流程。

更新流程不寫 user DB。只接受 HTTPS，遠端值不能控制本機任意路徑。SHA-256 作完整性驗證；公開發行前另評估 manifest 數位簽章與 key rotation。

## Consequences

流程容易審核、測試與回復，代價是每次更新下載較大且 staging/backup 需要額外磁碟空間。UI 應在下載前檢查空間並保留查詞能力。P1 可研究 changeset／分區／資產按需下載，但完整包保留作 fallback。

## Rejected alternatives

- 原地覆寫 DB：process kill 或 I/O error 會破壞唯一可用版本。
- 直接下載到 active path：無法在啟用前完整驗證。
- MVP 先做差分：測試矩陣、基底版本與 rollback 風險不符合第一版優先級。

## Verification

Fault-injection 覆蓋 manifest 不相容、大小／hash 錯、截斷、磁碟不足、各 transaction stage kill、replace/reopen 失敗；所有失敗均重開舊 DB，成功更新顯示新版本，user DB byte/content invariant 通過。
