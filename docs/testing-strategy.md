# Kotoba 測試策略

## 1. 目標與原則

測試的首要目的，是以可重現證據保護離線查詞、搜尋品質、個人資料、內容授權與更新安全。每個 P0 requirement 必須可追溯至自動化測試或明確手動驗收；「編譯成功」不等於使用者流程完成。

- 測試資料與規則鎖版；CI 不依賴 mutable upstream。
- 低層規則大量單元測試，跨模組以 contract/integration 測試，少量但關鍵的 E2E。
- 對排序、資料輸出與更新流程要求 deterministic／fault-injection。
- 多平台共用邏輯只需一次完整組合測試，但 platform adapter 和關鍵 UX 必須在平台矩陣驗證。
- 缺陷修復先增加能重現失敗的測試。

## 2. 測試層級與 owner

| 層級 | 範圍 | Owner | PR Gate |
|---|---|---|---|
| Unit/property | normalizer、romaji、活用、scoring、manifest/checksum、state reducers | 實作 owner | 是 |
| Schema/data quality | canonical、refs、status、source/license、stable ID | Data/Licensing | 是 |
| Golden/conformance | 查詢→結果／match/explain；Dart/Python parity | Search+Data | 是 |
| Repository/contract | DB query、typed failures、user/dictionary separation | Flutter+Search | 是 |
| Widget/UI | IME、狀態、詞條、收藏、theme、adaptive/keyboard/a11y | Flutter | 是 |
| Integration | builder→SQLite→App、editor→source→build、update transaction | 跨模組 owner | PR fixture；完整於 main |
| E2E | 真實離線任務、持久化、更新 | QA | release gate |
| Performance | cold start、search、scroll、build size | Search/Flutter/QA | baseline；M1/M4 gate |
| Security/license | path/manifest tampering、dependency/source notices | Security/Licensing | release gate |

## 3. 固定測試資料

### 3.1 搜尋黃金集

至少包含：100 常見詞、50 動詞活用、20 形容詞活用、20 片假名、20 羅馬字、20 歧義、20 不應錯誤命中。Normalization conformance row 記錄原始輸入與預期 normalized/kana/romaji variants；search acceptance row 記錄：

```text
case_id, raw_query, locale/input context,
expected entry IDs and allowable order,
expected match kind,
expected conjugation analysis,
forbidden entry IDs,
case rationale, search_rules_version
```

歧義案例以「允許集合＋排序約束」表達，不假設自然語言只有一個答案。負例檢查 false-positive；任何 golden 變更必須附產品／語言理由，不可只為讓測試變綠。

目前固定檔案為
`data/fixtures/search_acceptance_v1.json`（corpus
`kotoba-search-acceptance-v1`，SHA-256
`f004b66861cc64ac6204dc85c317e502ed70099bc70bd6a52776bd2d6f07c281`）。
它包含 100／50／20／20／20／20／20，共 250 個不重複查詢、235 個不同
lexicon entries，歧義組共 52 個 alternatives。CI 以
`python -m tools.verify_search_acceptance` 驗證 checksum、數量、唯一性與防灌水
條件，經 canonical schema v1 與正式 builder 建 SQLite 後，逐筆驗證
Python SearchEngine 的結果、排序、match/explain、活用分析及兩次執行完全相同。
Flutter test 直接讀同一 JSON，驗證 Dart normalizer/query candidates 對 210 個
正向 normalization／inflection／katakana／romaji cases 的 conformance。

### 3.2 效能資料集

固定 seed 建立 10k、100k、300k 模擬資料。保留具代表性的表記長度、同音詞、前綴密度、活用候選數與高／低頻分布；不能只重複單一簡單列。輸出 generator 版本、seed、資料 checksum、SQLite page/index stats。

### 3.3 更新 fixture

- known-good V1/V2、舊／新 schema boundary。
- 大小不符、hash 不符、截斷、非 SQLite、`quick_check` 失敗、minimum app 不符。
- 穩定 ID 保留／刪除／orphan favorite 案例。
- transaction 在 download、verify、close、replace、reopen 各階段中斷的 recovery states。

## 4. 功能測試設計

### 4.1 Normalization 與羅馬字

涵蓋 NFC/NFKC policy、全／半形、前後／重複空白、標點、平／片假名、小假名、濁／半濁音、長音、大小寫。Property tests 檢查 idempotence、空白結果、不得修改原始 query、無例外處理任意 Unicode。Romanization 包含 `taberu`、`hirou`、`gakkou`、`shimbun`、`shinbun` 與多候選。

### 4.2 活用還原

動詞涵蓋 ます／ました／ません／ませんでした、て／た、ない／なかった、可能／被動／使役／意向／命令／條件、進行形主要動詞；形容詞涵蓋 い形過去／否定／副詞與 な形連接。測試不規則詞、同形歧義、短輸入、不是活用的負例，並驗證可能多候選與信心／說明。

### 4.3 排序

對每種 match kind、frequency、curated/common/rare/archaic/domain、confidence modifier 建 table-driven tests。加入 stable tie-breaker、整數／精度 boundary、相同輸入可重現與 exact-over-lower-strategy invariant。開發 explain 的 score components 總和必須等於 final score。

### 4.4 App／UI

- 搜尋欄 auto-focus、clear/paste、80–150ms debounce、IME composing 不查詢、舊 request 不覆蓋新 request。
- result row 欄位、活用提示、空／錯／loading；手機 navigation、桌面 selection。
- 詞條首屏層級、收合內容、媒體有／無／損壞、TTS 合成標示。
- favorite/history 的 add/remove/deduplicate/order/clear/persistence。
- light/dark、200% text、長日文、窄手機／寬桌面、screen reader semantics、focus order、reduced motion。
- 快捷鍵與禁用設定；文字輸入聚焦時 Space 不觸發音訊。

### 4.5 Data／Editor

正面／負面 fixture 覆蓋 required fields、stable/duplicate ID、refs、sense order、published definition/readings、source/license、media fields、review transition。Editor 保存後執行 schema validation，preview 與 canonical renderer 使用同資料；audit 可辨識修改前後。AI draft direct publish 必須被 API 與 release validator 雙重阻擋。

## 5. 非功能測試

### 5.1 效能量測協議

- 使用 release/profile build、固定裝置、固定 dataset、暖機後至少 30 次查詢；同時報 P50/P95/max。
- 冷啟動量測從 process start 到 search input enabled，不把 background update 算作可輸入前必要工作。
- search latency 分開報 debounce、query、mapping、first render，防止平均值掩蓋瓶頸。
- 目標：冷啟動 P95 ≤ 2s；輸入完成到首結果 P95 ≤ 150ms；100k SQLite query P95 <100ms；核心包 <150MB。
- 300k 是容量／趨勢 gate；若規格未明訂絕對門檻，至少不得有非線性退化或 UI thread stall，release report 保留數值。

### 5.2 Reliability／fault injection

模擬 kill process、無網路、timeout、磁碟滿、permission/I/O、corrupt database、bad manifest/hash、atomic replace/reopen failure。每次驗證舊 dictionary 可開啟、user DB 不變、transaction marker 可恢復、錯誤可理解且可重試。

### 5.3 Privacy／security

- 靜態檢查與測試確認無 analytics／account 初始化；network mock 在離線核心流程期間應為零請求。
- logs snapshot 不含完整 query、favorites、clipboard、device identifiers。
- manifest 欄位 fuzz／path traversal 值不得改變 staging/target path；只接受 app-owned locations。
- dependency vulnerability/license/secret scans；外部資料 license report 逐項可追溯。

### 5.4 Accessibility

自動 semantics／contrast 檢查加人工 screen reader（VoiceOver、Windows Narrator 或對應平台）與全鍵盤巡覽。文字 200%、系統 dark/high contrast、reduced motion 分別驗證。狀態不得只依顏色，音訊按鈕 label 包含內容與音聲類型。

## 6. 平台矩陣

| 測試 | iOS | Windows | macOS |
|---|---|---|---|
| CI build | 每次 release | PR 代表＋release | 每次 release |
| Unit/widget | 共享 | 主要 desktop runner | 共享 |
| SQLite open/search/update | 實機完整 | 實機完整 | 實機 smoke |
| TTS/audio | 實機 | 實機 | 實機 |
| IME | 日文 IME | Microsoft IME | Japanese IME |
| Keyboard/adaptive | 外接抽查 | 完整 | 完整 |
| Screen reader | VoiceOver | Narrator | VoiceOver |

CI runner 限制不能取代實機驗收。至少 1 行動（iOS）＋1 桌面每個 release candidate 執行完整 E2E，其餘平台執行 smoke + platform adapters；正式 MVP 前三平台均需一次紀錄。

## 7. 關鍵 E2E 場景

### E2E-01 離線首查

乾淨安裝→關網→啟動→輸入 `食べました`→看到食べる活用提示→開詞條→看到定義／例句→TTS→收藏→重啟→收藏存在。全程 network spy 零 request。

### E2E-02 羅馬字與取消競態

快速依序輸入 `ta`→`tabe`→`taberu`，只顯示最新 query 的結果；第一候選食べる且 match kind 為 romaji。IME composing 測試不得中途 query。

### E2E-03 更新成功

V1 建立收藏／歷史→下載合法 V2→啟用→查到 V2 新詞→既有收藏／歷史存在→metadata 顯示 V2。

### E2E-04 更新失敗

對各 fault fixture 啟動更新→顯示原因→重新啟動→V1 可搜尋→收藏／歷史未變→可再次嘗試。

### E2E-05 桌面無滑鼠

以快捷鍵聚焦→輸入→方向鍵選取→Enter→Space 播音→收藏鍵→Esc；焦點順序與雙欄 selection 正確，禁用 shortcuts 後不觸發。

## 8. Release Gate 與缺陷政策

MVP release 必須滿足：

- 所有 P0 unit/schema/golden/widget/integration/E2E 綠燈。
- 100k 搜尋與 cold-start/first-render 效能達標；無 UI thread blocking 證據。
- 三平台 build 成功，平台 smoke／完整 E2E 紀錄齊全。
- 資料品質與 licensing zero blocker；20 精選詞條通過人工審核。
- 更新 fault suite 全通過；無個人資料遺失。
- 無已知 Blocker/Critical；Major 必須有 owner、風險接受與修復版本，且不得違反任何 P0 AC。

Flaky test 不得以無期限 retry 隱藏；第一次隔離需有 owner/issue/期限，P0 gate test 不可被隔離後發布。

## 9. Traceability

每個 backlog item 的完成證據至少包含 requirement/AC ID、測試 ID、CI run/artifact、平台與 reviewer。QA 維護 MVP traceability matrix；規格變更時同步新增／修改測試，不以口頭接受取代紀錄。
