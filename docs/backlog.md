# Kotoba MVP Backlog

狀態值：`Ready`、`In progress`、`Blocked`、`In review`、`Done`。優先級：P0 為 MVP gate，P1 不阻擋 MVP。以下是可轉成 GitHub Issues 的初始清單；每項完成須符合 repo Definition of Done 與對應驗收證據。

## Epic E0 — 基礎與治理

| ID | Pri | 工作 | Owner | 驗收／依賴 |
|---|---|---|---|---|
| KTB-001 | P0 | 建 monorepo、workspace scripts、README | Architecture | 乾淨 checkout 一鍵 bootstrap/test；無 generated-only source |
| KTB-002 | P0 | 建 PR／issue templates、CODEOWNERS、DoD checklist | PM/Architecture | PR 包含 AC、tests、license/a11y、screenshots/benchmark 欄位 |
| KTB-003 | P0 | 建 PR CI baseline | DevEx/QA | format/lint/unit/schema/fixture/Flutter/editor/代表 build 可執行 |
| KTB-004 | P0 | 鎖依賴與供應鏈掃描 | Security | lockfiles、dependency/license/secret scan；更新政策記錄 |
| KTB-005 | P0 | 建 requirement traceability matrix | QA | P0 AC 對應 test IDs、platform/evidence |

## Epic E1 — Canonical Data 與建置

| ID | Pri | 工作 | Owner | 驗收／依賴 |
|---|---|---|---|---|
| KTB-101 | P0 | 定義 canonical JSON schema 與版本 | Data | entry/sense/forms/readings/POS/media/source/review 欄位正反 fixtures |
| KTB-102 | P0 | 定義 stable ID 與 relation policy | Data | duplicate/dangling lint；ID 不依賴 DB autoincrement |
| KTB-103 | P0 | 定義 provenance/license schema | Data+Licensing | 圖片／音訊可分離授權；source/version/acquired_at/redistribution |
| KTB-104 | P0 | 實作 editorial overlay merge | Data | 固定順序；衝突報告；相同輸入內容等價 |
| KTB-105 | P0 | 實作 schema/data/review/license validator | Data | 所有規格發布阻擋條件有 failing fixture/report |
| KTB-106 | P0 | 實作 SQLite builder 與索引 | Data+Search | 從零 build；metadata/count stats；`quick_check`；deterministic |
| KTB-107 | P0 | 實作 release/assets manifests/checksums | Data+Security | schema/size/SHA-256/version fields 經正反測試 |
| KTB-108 | P0 | 建 3 walking-skeleton 詞條 | Editorial | 原創／授權安全，M0 App 可查 |
| KTB-109 | P0 | 建 20 完整精選詞條 | Editorial+Japanese reviewer | 每主要 sense ≥1 例句；來源、review、relation/media 規則通過 |
| KTB-110 | P0 | 外部來源採用審查與 notices | Licensing | 未核准來源不得 import；保存全文版本、取得日與署名要求 |

## Epic E2 — 搜尋核心

| ID | Pri | 工作 | Owner | 驗收／依賴 |
|---|---|---|---|---|
| KTB-201 | P0 | Unicode/width/space/punctuation normalizer | Search | idempotence/property/Unicode edge tests |
| KTB-202 | P0 | 平片假名、小假名、濁半濁、長音處理 | Search | conformance fixtures；原始 query 保留 |
| KTB-203 | P0 | Hepburn 羅馬字轉假名多候選 | Search | 規格例與 20+ golden cases |
| KTB-204 | P0 | 動詞活用還原 | Search | 全指定 forms、歧義/負例、50 golden cases |
| KTB-205 | P0 | 形容詞活用還原 | Search | 指定 forms、歧義/負例、20 golden cases |
| KTB-206 | P0 | Query planner/match kinds | Search+Data | exact→contains 順序；P1 enum 可擴充 |
| KTB-207 | P0 | Deterministic scoring/tie-break/explain | Search | components 對帳；相同輸入排序相同 |
| KTB-208 | P0 | Dart/runtime 與 builder conformance | Search+Data | 同 UTF-8 fixture 100% parity，版本不符阻擋 build |
| KTB-209 | P0 | 完整搜尋黃金集 | QA+Search+Japanese reviewer | 規格數量全通過；變更需語言／產品審核 |
| KTB-210 | P0 | 10k/100k/300k benchmark harness | Search+QA | 固定 seed/checksum；100k P95 <100ms |
| KTB-211 | P1 | 模糊搜尋與拼字容錯 | Search | 不蓋 exact；依長度 edit limits；效能預算 |
| KTB-212 | P1 | 整句分詞原型 | Search/Product | 獨立 discovery，不耦合 P0 query path |

## Epic E3 — Flutter App 與離線體驗

| ID | Pri | 工作 | Owner | 驗收／依賴 |
|---|---|---|---|---|
| KTB-301 | P0 | App 分層、Riverpod DI/state、go_router shell | Flutter | repository fakes 可測；Widget 無 raw SQL |
| KTB-302 | P0 | Dictionary repository/Drift read-only adapter | Flutter+Search | typed error、explain mapping、DB compatibility check |
| KTB-303 | P0 | 獨立 user DB 與 migration | Flutter | favorite/history/settings；migration fixtures；update 無寫入 |
| KTB-304 | P0 | 搜尋首頁與 IME-safe debounce | Flutter | autofocus、80–150ms、composing gate、stale result cancellation |
| KTB-305 | P0 | 結果列與空／錯／載入狀態 | Flutter+UX | 規定欄位、活用提示、retry/clear flow |
| KTB-306 | P0 | 手機詞條頁與資訊層級 | Flutter+UX | 主要首屏、次要收合、長文/200% text 無截斷 |
| KTB-307 | P0 | 桌面雙欄與 keyboard shortcuts | Flutter+UX | 全快捷鍵、focus、Space guard、可停用 |
| KTB-308 | P0 | TTS abstraction 與合成音聲標示 | Flutter | 三平台 adapter smoke；offline；a11y label |
| KTB-309 | P0 | 圖片與音訊呈現／播放 | Flutter | downloaded asset、missing/corrupt fallback、真人／合成區分 |
| KTB-310 | P0 | 收藏與歷史 UI／持久化 | Flutter | dedupe/order/clear/restart/update preservation |
| KTB-311 | P0 | theme、字體、reduced motion、semantics | Flutter+Accessibility | WCAG AA target、200%、screen reader/focus checklist |
| KTB-312 | P0 | 冷啟動與 first-result instrumentation | Flutter+QA | release build P95 達 2s/150ms；分段 latency report |

## Epic E4 — 編輯器

| ID | Pri | 工作 | Owner | 驗收／依賴 |
|---|---|---|---|---|
| KTB-401 | P0 | Editor API 的 validated read/write contract | Editor+Data | 只改 canonical/editorial working copy；schema errors 有 JSON path |
| KTB-402 | P0 | 詞條搜尋、建立、編輯、義項排序 | Editor | refresh 後保存；stable ID/reference validation |
| KTB-403 | P0 | 例句、relations、media metadata 編輯 | Editor | 必填來源／授權提示；斷裂 ref 不可發布 |
| KTB-404 | P0 | 狀態機、review/audit trail | Editor+Editorial | AI draft bypass 於 UI/API/release gate 均失敗 |
| KTB-405 | P0 | App-like content preview | Editor+UX | 主要／次要層級與 App contract 一致 |
| KTB-406 | P0 | 發布前檢查與報告下載 | Editor+Data | 執行同一 validator，結果可定位 rule/item/path |

## Epic E5 — 資料更新與發布

| ID | Pri | 工作 | Owner | 驗收／依賴 |
|---|---|---|---|---|
| KTB-501 | P0 | Manifest fetch/parse/version compatibility | Flutter+Security | HTTPS、strict schema、min app/schema/size preflight |
| KTB-502 | P0 | App-owned staging download | Flutter | 可取消／重試；remote filename/path 不控制本機 target |
| KTB-503 | P0 | 大小、SHA-256、SQLite health verification | Flutter+Security | tampered/truncated/non-DB fixtures 全拒絕 |
| KTB-504 | P0 | Connection quiesce + atomic activation | Flutter | update lock、same-volume replace、成功 reopen |
| KTB-505 | P0 | Rollback 與啟動 recovery | Flutter+QA | 每個 transaction stage kill 後恢復 known-good |
| KTB-506 | P0 | 更新 UI 狀態 | Flutter+UX | offline/current/downloading/verifying/success/error，查詞不被破壞 |
| KTB-507 | P0 | 三平台 release builds/artifacts | DevEx+QA | iOS/Windows/macOS build、checksum/report |
| KTB-508 | P0 | Release runbook 與 go/no-go checklist | QA/Release | rollback、artifact/version/notices/store steps 可操作 |
| KTB-509 | P1 | Manifest signing threat model/ADR | Security | 比較 key rotation/revocation/store constraints |
| KTB-510 | P1 | 差分／分區更新 spike | Architecture+Data | 不影響完整包 fallback、可量測收益 |

## Epic E6 — QA、Accessibility、Security

| ID | Pri | 工作 | Owner | 驗收／依賴 |
|---|---|---|---|---|
| KTB-601 | P0 | App 關鍵 widget tests | Flutter+QA | search/result/empty/error/entry/collapse/favorite/history/theme/layout |
| KTB-602 | P0 | 離線 E2E 與 network spy | QA | 核心流程零 network、重啟持久化 |
| KTB-603 | P0 | 更新 fault-injection suite | QA+Security | 全 fault fixture 保舊 DB/user data |
| KTB-604 | P0 | 三平台 smoke matrix | QA | SQLite/TTS/audio/IME/keyboard/screen reader 紀錄 |
| KTB-605 | P0 | Accessibility audit | Accessibility+QA | semantics、focus、contrast、200%、reduced motion |
| KTB-606 | P0 | Privacy/log/network audit | Security | 無未同意上傳；logs/clipboard/device ID policy 通過 |
| KTB-607 | P0 | Data/license release audit | Licensing+QA | zero missing provenance/license；notices 正確 |
| KTB-608 | P0 | MVP traceability/go-no-go report | QA/PM | 全 P0 AC evidence、zero Blocker/Critical、客戶驗收包 |

## MVP Critical Path

```text
KTB-101/102/105 → KTB-106 → KTB-302 → KTB-304/305/306
KTB-201..208 ────────────────────────┘
KTB-303 → KTB-310 → KTB-504/505 → KTB-603
KTB-103/110 → KTB-109 → KTB-107 → KTB-507/608
```

## Ready 與 Done

Issue 進入 `Ready` 前需：scope 清楚、AC/test strategy、owner、依賴、必要設計／ADR 與 fixture 已確認。進入 `Done` 前需：code/data/docs 完成、相關 tests/CI 綠、錯誤／空／載入狀態、必要平台、離線、a11y、license/security 檢查、另一角色 review，且 traceability evidence 已連結。
