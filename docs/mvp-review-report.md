# Kotoba MVP 客戶評審報告

- 評審版本：Engineering MVP 0.1
- 評審日期：2026-07-22（搜尋驗收證據補充：2026-07-23）
- 產品平台：iOS、Windows、macOS
- Android：依客戶決策移除，見 ADR-0005
- 整體判定：**Engineering MVP 可進行客戶評審；正式發布 NO-GO**

## 1. 已交付範圍

- Flutter 離線辭典 App：漢字、假名、羅馬字、活用形搜尋，響應式手機／桌面
  版面，詞條詳情、TTS、本地媒體、收藏、歷史、設定與鍵盤操作。
- 決定性內容供應鏈：canonical JSON schema、normalizer、deinflection、ranked
  search、SQLite builder、release manifest、checksum、provenance/license gate。
- 本機內容編輯器：搜尋、編輯、即時 App 預覽、schema 驗證、working copy、
  audit log 與不得跳級的人工審核狀態機。
- 更新原型：本機完整資料包 sideload、manifest/SQLite 驗證、quiesce/reopen、
  rollback marker 與 cache invalidation。
- 24 筆原創 CC0 開發 fixture；全部保留 `ai_draft`，App 明確顯示為
  「レビュー前のデモ内容」，production builder 會拒絕發布。

## 2. 驗證證據

| 檢查 | 結果 | 證據摘要 |
|---|---|---|
| 資料／搜尋單元與整合 | PASS | 原有 23 項加 6 項 corpus contract tests |
| AC-02/03/04 固定搜尋 corpus | PASS | 250/250 可重現；100 常見詞、50 動詞、20 形容詞、20 片假名、20 羅馬字、20 歧義、20 負例 |
| 編輯器 schema、workflow、storage、HTTP security | PASS | 25/25 |
| Flutter format | PASS | 47 files，0 changes |
| Flutter analyze | PASS | No issues found |
| Flutter unit/widget/integration | PASS | 25/25 |
| Flutter Web release build | PASS | `build/web` 成功產生 |
| 內容編輯器瀏覽器 smoke | PASS | 搜尋、選取、編輯表單、即時預覽 |
| Flutter 桌面響應式 smoke | PASS | 雙欄搜尋／詳情空狀態 |
| Flutter 390×844 smoke | PASS | `taberu`→食べる→詳情，無水平捲動 |
| 100k 搜尋 benchmark | PASS | P95 低於 100 ms 的規格門檻 |
| Android scope removal | PASS | 無 runner、無 CI job、無發布／驗收承諾 |

本機全套驗證入口：`scripts/verify.ps1`。

## 3. 正式發布 Gate

| Gate | 狀態 | 完成條件 |
|---|---|---|
| Engineering vertical slice | PASS | 已從 canonical data 建置並由 App 查詢 |
| 內容／授權發布 | BLOCKED | 合格日文審核者完成人工審核，至少 20 筆達 approved/published |
| 完整搜尋黃金集 | PASS | 固定 corpus 經 canonical builder、Python runtime 與 Dart conformance 驗證；checksum 與防灌水規則由 CI 鎖定 |
| 遠端完整資料包更新 | PARTIAL | 目前只有安全本機 sideload；補上下載、進度／取消與網路 fault injection |
| 原生三平台 build | PENDING | GitHub CI 實際跑通 iOS simulator、Windows、macOS artifacts |
| 實機／實體桌面驗收 | PENDING | iOS 及至少一個桌面完成離線、IME、TTS、音訊、a11y smoke |
| 效能與啟動指標 | PARTIAL | SQLite benchmark 通過；仍須 release app 冷啟動與 UI P95 證據 |

依產品規格，以上 Blocked／Pending 項目完成前不得稱為「正式 MVP 已驗收」或
發布 production dictionary。這不影響本版用於客戶操作評審與需求修訂。

## 4. 客戶評審會議議程

1. 搜尋結果與詞條資訊層級是否符合「數秒內先懂最常用義」的產品方向。
2. 手機單頁、桌面雙欄、收藏／歷史／設定的操作是否需要調整。
3. 指派具資格的日文內容審核者，確認 24 筆草稿的 reviewer、evidence 與
   publishing responsibility。
4. 決定遠端更新是否維持 P0；若維持，確認 package host、簽章與 rollout 政策。
5. 確認 iOS／Windows／macOS 的 CI、簽章、測試裝置與商店／安裝包交付方式。

## 5. 建議下一個里程碑

先進行客戶 UX 驗收並凍結主要互動；同時啟動人工內容審核、三平台 CI 與實機
測試。完成後產出 Release Candidate 0.1，執行完整 P0 traceability review，才將
狀態由 NO-GO 改為 GO。
