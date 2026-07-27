# Kotoba MVP 路線圖

本路線圖採「可驗收增量」而非日期承諾。客戶於 2026-07-27 將產品改為 self-hosted 生成式辭典，因此新增 M2G；私人本地詞條不再依賴 M3 的公共內容審核。各里程碑只能在 exit criteria 具有 CI、測試或外部驗收證據時關閉。

## 0. 治理節奏

- 每週：PM／Tech Lead 檢視 scope、風險、依賴、P0 burn-up 與 defect aging。
- 每個 PR：小型、單一責任、附 acceptance/test evidence；跨界面先更新 contract/ADR。
- 每個 milestone：內部 demo + QA gate + accessibility/license/security checklist。
- MVP 候選：三平台 build、至少 1 行動＋1 桌面實機離線測試、客戶驗收會議。
- 缺陷級別：Blocker（資料遺失／無法查詞／發布不合法）、Critical（P0 主要流程不可用）、Major、Minor。MVP 不得有已知 Blocker/Critical。

## M0 — Walking Skeleton

### 目標

證明從版本控制內容到離線 App 的最短垂直切片可運作。

### 交付

- monorepo、架構／產品／測試／ADR baseline。
- Flutter App 在至少 1 行動與 1 桌面 target 啟動。
- 3 個原創 fixture 詞條 → validator → SQLite builder → App 查詢／詞條頁。
- 搜尋欄 IME-safe debounce、基本結果／空／錯誤狀態。
- 基本 CI、dependency lock、README 開發步驟。

### Exit criteria

- 乾淨 checkout 可依文件重建 fixture DB。
- 網路關閉時，漢字與讀音能查到 3 詞條並開啟詞條。
- CI format/lint/unit/schema/fixture build/Flutter tests 全綠。
- 行動與桌面 smoke test 有證據，不以 mock 畫面代替 DB 整合。

## M1 — 搜尋核心

### 目標

讓非精確原形輸入仍能快速、可解釋地找到正確詞。

### 交付

- Unicode／寬度／空白／標點／假名／長音／羅馬字正規化。
- 常見動詞與形容詞活用還原，多候選與信心／解釋。
- 精確、其他表記、讀音、正規化、羅馬字、活用、前綴、包含策略。
- 決定性 scoring/tie-breaker、開發 explain 資訊。
- 規格完整 golden corpus 及 10k/100k/300k benchmark datasets。

### Exit criteria

- 規格範例與完整黃金集全通過，負例不發生禁配命中。
- 100k dataset SQLite 查詢 P95 < 100 ms；輸入後首結果 P95 ≤ 150 ms。
- build/runtime normalization conformance 100% 一致。
- 結果對相同 query/data/rules 可重現。

## M2 — 詞條與跨平台體驗

### 目標

完成使用者從查詞到理解、聆聽、收藏的離線閉環。

### 交付

- 主要／次要資訊層級、例句、關係說明、收合區塊。
- 系統日文 TTS（合成標示）、本地圖片、音訊播放及錯誤 fallback。
- 獨立 user DB 的收藏、歷史、偏好。
- 深色模式、字體調整、screen reader semantics、reduced motion。
- 手機頁面與桌面雙欄、完整鍵盤操作及可停用快捷鍵。

### Exit criteria

- 無網路 E2E：搜尋→詞條→TTS→收藏→重啟→收藏存在。
- 200% 字體、淺／深色、鍵盤與螢幕閱讀器 checklist 通過。
- 手機與桌面主要流程可用，沒有 Blocker/Critical。
- 核心頁面涵蓋 loading/empty/error/offline 狀態。

## M2G — Self-hosted 按需生成

### 目標

在私人環境中，正式送出未收錄詞彙時自動搜尋、生成、驗證、保存並立即使用，不需要人工審核或發布。

### 交付

- 輸入 lookup 與 explicit-submit generation 的硬性邊界。
- Wikimedia 搜尋、OpenAI-compatible LLM、local entry JSON Schema 與語意 validator。
- `generating`／`ready`／`failed`／`stale` jobs 與 `generated`／`edited`／`regenerated` immutable Revision。
- 編輯、歷史預覽／復原、重新生成、刪除與鎖定。
- 低干擾來源不足／knowledge-only／stale／failed 提示及生成資訊。
- bearer-token API、Ollama + Qwen3 8B Compose 與一鍵部署／啟動腳本。

### Exit criteria

- 十項客戶驗收條件均有自動化或明確外部測試證據。
- 失敗生成不得寫入 entries，重複正式送出不得產生平行同詞工作。
- 私人詞條 schema／App 不包含 review／approve／publish 狀態。
- 真實 Qwen3 8B 代表詞集完成日文品質抽樣；iPhone 實機透過 HTTPS endpoint 完成 smoke test。

## M3 — 公共內容供應鏈與編輯器

### 目標

建立未來公共詞條包可審核、可追溯、可重建且不依賴商業辭典的內容生產線。此流程不限制私人 self-hosted 詞條。

### 交付

- canonical schema、stable ID policy、editorial overlay、provenance/license model。
- importer、validator、SQLite/release builders、統計／錯誤／授權報告。
- 單一管理者 Web editor：搜尋、CRUD、義項排序、例句、關係、媒體、狀態、預覽、audit。
- 20 個經人工審核的完整精選詞條。
- 外部資料源採用決策與第三方 notices（若實際採用）。

### Exit criteria

- 乾淨環境從鎖定輸入建立可開啟 SQLite；相同輸入內容等價且非決定性欄位受控。
- editor 修改 canonical/editorial source 後可重建資料包，無 generated-only 變更。
- 所有發布阻擋規則有正反 fixture；20 詞條通過內容與授權雙審核。
- AI 草稿 bypass 測試證明不能直接 published。

## M4 — 安全更新與 MVP Release Candidate

### 目標

在不危害現有離線能力與個人資料的前提下交付新資料包。

### 交付

- release/assets manifests、checksums、版本相容性檢查。
- staged download、大小/SHA-256/SQLite health check、同 volume 原子替換、rollback／startup recovery。
- 更新 UI 狀態、三平台 build pipeline、release runbook、完整測試／資料／授權報告。
- 隱私、安全、依賴、授權與 accessibility release review。

### Exit criteria

- fault injection 覆蓋中斷、錯 hash、不相容、磁碟不足、替換／reopen 失敗，舊版均可用。
- 更新成功／失敗後收藏與歷史完全保留。
- iOS、Windows、macOS build 全綠；至少 1 行動＋1 桌面實機全流程通過。
- 所有 P0 AC 有 traceability evidence，無 Blocker/Critical，客戶可進行 MVP 驗收會議。

## M5 — MVP 後擴充（不屬 MVP Gate）

- 經排序的 300–1,000 人工詞條、更多例句與關係說明。
- 拼字／模糊搜尋（不可壓過精確結果）、整句分詞原型。
- 東京式音調、更多可授權圖片與真人錄音試驗。
- 差分更新、錯誤回報、分享選單、瀏覽器擴充。

每項 P1 另有產品假設、效能預算、授權審查與 A/B 或可用性測試計畫，不能以 P1 破壞主畫面簡潔或 P0 搜尋速度。

## 跨里程碑依賴

```text
Product acceptance ───────────────────────────────► M4 release gate
Schema + stable IDs ─► builder ─► App repository ─► update compatibility
Normalization contract ─► search keys ─► ranking ─► golden/performance
Provenance/license ─► editor workflow ─► release validator/notices
User DB separation ─► favorites/history ─────────► update preservation
```

## 主要風險登錄

| ID | 風險 | 機率/影響 | Owner | 預防與觸發行動 |
|---|---|---|---|---|
| R1 | 外部來源授權不符 | 中/極高 | Licensing | 採用前全文審查；不核准即用原創 fixture、替換來源 |
| R2 | 搜尋鍵規則漂移 | 中/高 | Search+Data | 同版 fixtures；任何 mismatch 阻擋 merge/release |
| R3 | 300k 效能不達標 | 中/高 | Search | M1 早期 benchmark；檢查 query plan/index；限制候選 |
| R4 | 跨平台插件行為不同 | 中/高 | Flutter | M0 spike + 每 milestone matrix smoke test |
| R5 | 更新造成 DB 損壞 | 低/極高 | Flutter+Security | staging/atomic/rollback + fault injection |
| R6 | 穩定 ID 變更遺失收藏關聯 | 中/高 | Data | stable ID lint、mapping、orphan report |
| R7 | 內容審核產能不足 | 高/中 | Editorial/PM | 先鎖 20 詞條 DoD；P1 數量不阻擋 MVP |
| R8 | 範圍膨脹 | 高/高 | PM | P0/P1 gate；新增需求需 change control |
| R9 | AI 草稿錯誤發布 | 中/高 | Editorial+QA | 狀態機、review evidence、bypass tests |

## 變更控制

任何新增 P0 必須說明：使用者問題、為何不可延至 P1、受影響 AC、估計與風險、要移除／延後的同等工作。PM 提案、Tech/QA/Licensing 評估，客戶核准後更新產品規格、roadmap、backlog；schema、更新、資料信任或搜尋規則另需 ADR。
