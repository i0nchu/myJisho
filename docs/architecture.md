# Kotoba 系統架構

- 狀態：MVP baseline
- 架構型態：離線優先的跨平台客戶端 + 可重建內容供應鏈
- 核心原則：canonical data 是內容權威來源；SQLite 是唯讀、可替換、可重建的交付產物；個人資料與辭典資料隔離

## 1. 系統脈絡

```text
Open / Original Sources
          │ provenance + license
          ▼
Importers → Canonical JSON ← Editorial Overlay ← Editor UI / API
                         │
                         ▼
              Schema / Data / License Gates
                         │
                         ▼
             SQLite + Asset + Release Builder
                         │
                  signed-off artifacts
                         ▼
     ┌──────── Update endpoint / static hosting ────────┐
     │                                                   │
     ▼                                                   ▼
Flutter App ── repository ── Dictionary DB (replaceable, read-only)
     │
     └────────────────────── User DB (history/favorites/settings)
```

App 在完全離線時不需要任何服務端。內容編輯與發布是開發／營運工具鏈，不在終端使用者的查詞關鍵路徑上。

## 2. Monorepo 與技術邊界

```text
apps/dictionary_app        Flutter presentation + application layer
apps/content_editor        Browser-based internal editor
services/editor_api        Local/internal editorial API
packages/dictionary_schema Shared schema/types and validation contracts
packages/search_engine     Query planning, scoring, explain data structures
packages/japanese_normalizer Runtime normalization/conjugation logic
packages/shared_types      Cross-package value objects only
data/imported              Immutable-ish source snapshots and metadata
data/editorial             Version-controlled authoritative overlays
data/fixtures              Test/golden datasets
data/generated             Rebuildable outputs; never authoritative
tools/*                    Import, validate, DB and release builders
assets/*                   Reviewed redistributable media
docs/*                     Product, architecture, decisions, operations
```

語言策略：終端 App 與可嵌入搜尋核心使用 Dart；ETL／validator／builder／editor API 使用 Python；編輯器 UI 使用 TypeScript。跨語言不共享「隱含行為」，而共享有版本的 JSON Schema、release manifest schema、SQLite schema 及 golden conformance fixtures。

禁止依賴方向：Widget 不得呼叫原始 SQL；搜尋 package 不得依賴 Flutter UI；canonical schema 不得依賴 editor；data pipeline 不得將 `data/generated` 當唯一來源。

## 3. Flutter App 分層

```text
Presentation (screens/widgets/adaptive layout/accessibility)
                │ intent / view state
Application (controllers/providers/use cases/navigation policy)
                │ repository interfaces
Domain (Entry, SearchQuery, SearchHit, UpdatePlan, UserPreference)
                │ adapters
Infrastructure (Drift/SQLite, TTS, audio, filesystem, network update)
```

- Riverpod 負責依賴注入與可測試狀態；狀態由 feature controller 管理，不把 repository 或 SQL 散落在 Widget。
- go_router 負責可測試導航與 desktop/mobile URL/state 模型；版面差異不應產生兩套 domain flow。
- repository interface 隔離資料來源，測試可注入 memory/fake implementation。
- 查詢透過遞增 request token 或 cancellation 防止舊查詢覆蓋新查詢；debounce 位於 application boundary，IME composing 由 presentation gate 阻擋。
- CPU／I/O 密集查詢不得阻塞 UI isolate；實作應先量測 Drift background execution，再決定 isolate 策略。

### 3.1 建議 repository 契約

```text
DictionaryRepository
  search(SearchRequest) -> SearchPage<SearchHit>
  getEntry(EntryId) -> EntryDetail?
  getDatabaseMetadata() -> DictionaryMetadata
  closeForUpdate() / reopenAfterUpdate()

UserDataRepository
  list/add/removeFavorite(EntryId)
  add/list/clearHistory(...)
  get/setPreferences(...)

DictionaryUpdateRepository
  check() -> UpdateAvailability
  downloadAndVerify() -> StagedPackage
  activate(StagedPackage) -> ActivationResult
  rollback() -> void

SpeechService / AudioService / ConnectivityService
```

外部穩定 ID 是跨資料包引用鍵。SQLite rowid／自動遞增值不可穿越 repository boundary。

## 4. 資料儲存

### 4.1 Dictionary database

- 由 pipeline 預先產生搜尋鍵與索引，App 不在啟動時重建。
- 正常執行以唯讀方式開啟；版本更新透過整個檔案替換。
- 至少包含規格指定的 entries、forms、readings、POS、senses、definitions、examples、relations、media、search_keys、sources、reviews、metadata。
- SQLite schema 有獨立版本；App 啟動前檢查 schema 與 minimum app version。
- 所有 query 參數化；排序規則可回傳 explain payload，release UI 不必顯示 debug 細節。

### 4.2 User database

- 物理上與 dictionary database 分離，保存收藏、歷史和偏好。
- dictionary update 不取得此 DB 的寫入權；刪除／清除操作必須是明確 user action。
- favorite 只保存穩定 `entry_id`；若新資料包移除詞條，保留 orphan 狀態以供復原或顯示「目前版本不可用」，不可靜默刪除。
- migration forward/backward path 至少有 fixture 測試；資料庫損壞與 dictionary 損壞需分別處理。

### 4.3 媒體

核心包只放必要的小型、已審核資產；額外媒體以內容雜湊命名並由 assets manifest 驗證。媒體失敗不影響文字詞條，asset provenance／license 保留在 canonical metadata 與 App 署名頁。

## 5. 搜尋資料流與契約

```text
raw input
  → Unicode/width/whitespace/punctuation normalization
  → kana/romaji variants
  → conjugation analyses (0..n, confidence + explanation)
  → ordered query strategies against prebuilt search_keys
  → deterministic base score + metadata adjustments
  → stable tie-breakers
  → SearchHit + SearchExplanation
```

建置端與 runtime 端的正規化必須通過同一套 UTF-8 fixture；任何規則變更需同時升級 fixture/version。排序 tie-breaker 明訂為：final score 降冪、frequency rank 升冪（null last）、headword codepoint 順序、stable entry ID，確保重現性。

P0 不做 fuzzy／definition full-text，但 schema／match kind enum 需可向前擴充。任何 P1 結果不能蓋過合理精確命中。

## 6. 內容編輯與發布供應鏈

1. Importer 讀取固定版本來源，保存 source ID、取得日期、授權 metadata 與原始內容雜湊。
2. 轉為 canonical document；無法解析的單項進 report，不中止所有可處理資料。
3. Editorial overlay 以穩定 ID 覆寫／補充，不直接編輯 generated SQLite。
4. Editor API 只改動合法的 canonical/editorial working copy；MVP 單一管理者，不建完整帳號系統。
5. Schema、referential integrity、editorial status、內容品質、license gates 全部通過才可 build。
6. Builder 以固定排序、固定時間／metadata 注入策略產生內容等價、可重現 artifact 與統計。
7. Release builder 產生 SQLite、assets manifest、release manifest、checksums 和 provenance/license report。

發布狀態機由 schema 驗證：`ai_draft` 不能直接轉 `approved`／`published`；`published` 必須有 review evidence。工具輸出的錯誤報告包含穩定 item ID、來源檔、JSON path、rule ID 與 severity。

## 7. 完整資料包更新

```text
fetch manifest → parse/validate → compare version/compatibility
→ download to app-owned staging path → verify exact size + SHA-256
→ quick_check/open staged SQLite → acquire update lock
→ close dictionary connections → retain known-good backup
→ same-volume atomic rename/replace → reopen + health check
→ delete backup only after success; otherwise rollback and reopen old DB
```

安全規則：

- 僅接受 HTTPS；下載位置、檔名與目標路徑由 App 固定，不使用遠端任意路徑。
- manifest schema 嚴格驗證；`schema_version`、`minimum_app_version` 與大小上限在下載前檢查。
- SHA-256 提供完整性但不單獨提供發布者身分；MVP 的 endpoint／manifest 信任建立於 HTTPS 與受控發布流程。正式公開發布前評估 manifest 數位簽章並另立 ADR。
- staging 與 target 位於同一 filesystem 以使用原子替換；同時只允許一個 updater。
- 啟動時偵測中斷 transaction marker，選擇已通過 health check 的 newest known-good DB。
- 更新服務永不開啟 user DB 作 mutation。

## 8. 版本契約

| 版本 | 用途 | 相容策略 |
|---|---|---|
| canonical schema version | 編輯／pipeline 文件 | 工具明確 migration，未知必要欄位 fail |
| SQLite schema version | App query contract | App 列出支援範圍，不相容包拒絕啟用 |
| dictionary version | 內容 release | SemVer-like `YYYY.MM.patch`，只用於新舊比較 |
| minimum app version | data 所需能力 | 目前 App 太舊即不下載／不啟用 |
| search rules version | normalization/scoring | golden fixture 與資料 search_keys 一致性檢查 |
| assets manifest version | 媒體 contract | 允許忽略明訂 optional 欄位，必要欄位嚴格驗證 |

## 9. 品質屬性策略

### 效能

- 查詢只打預建索引，限制首批數量並分頁；以 10k／100k／300k 固定 dataset benchmark。
- 冷啟動不做資料匯入、索引重建或更新下載；先讓搜尋可輸入。
- 圖片採尺寸適配與 lazy decode；音訊串流／下載不阻塞 UI。

### 穩定性

- 辭典唯讀、個人資料獨立；更新為 staged transaction。
- repository 對「無資料」「資料損壞」「不相容」「I/O」提供 typed failure，UI 不以 catch-all 空畫面隱藏錯誤。
- last-known-good core fixture 可隨 App 包裝，正式資料缺失時至少能提示修復；是否包完整核心 DB 由 release sizing 決定。

### 隱私與安全

- 第一版無帳號、無預設 analytics；查詢／收藏不離開裝置。
- 剪貼簿只在使用者觸發貼上時讀取。
- logs 不記錄完整查詢、檔案路徑中的個資或裝置識別；debug explain 僅本機開發模式。
- 依賴鎖版並執行 dependency／license／secret scans；發布 artifact 有 checksum、來源清單和 SBOM（若工具鏈支援）。

### 無障礙

UI component contract 包含 semantics label、keyboard focus、200% text scale、對比與 reduced motion；不得只把無障礙留給頁面完成後補測。

## 10. CI/CD Gate

PR 必跑：format、lint/static analysis、unit、schema、data fixtures、normalization/search golden、Flutter widget、editor tests、license metadata gate、至少一種代表平台 build。主分支／release 額外跑 deterministic full build、100k/300k benchmark、三平台 build、update fault injection、artifact checksum、資料統計及 license report。

任何外部 fixture 必須鎖定版本與 checksum；CI 不在執行時抓取 mutable upstream 資料。生成 artifact 若不進 Git，CI／release job 必須能從鎖定輸入重建。

## 11. Ownership 與介面責任

| 模組 | Owner | 提供契約 | 不負責 |
|---|---|---|---|
| Product/UX | Product | journey、priority、acceptance | 排序演算法、授權判定 |
| Search | Search | normalization/query/scoring/explain | Widget、內容審核 |
| Data | Dictionary Data | canonical/schema/SQLite/provenance | App state、UX |
| App | Flutter | UI、repositories adapters、TTS、user DB、update UX | canonical 編輯、license 核准 |
| Editor | Content Editor | validated editorial changes、preview/audit | 正式發布核准 |
| Security/Licensing | Security | source approval、update threat review、notices | 詞義語言品質 |
| QA/Release | QA | evidence、gates、release decision record | 任意降低 acceptance 門檻 |

跨界面變更先更新 contract tests／ADR。衝突處理順序為資料正確性、授權與安全、搜尋品質、UX、效能、開發便利性。

## 12. 主要風險

| 風險 | 早期訊號 | 緩解／Owner |
|---|---|---|
| 正規化 build/runtime 漂移 | 同輸入漏搜 | shared golden fixture；Search + Data |
| 100k+ 查詢超時 | P95 趨勢上升 | query plan、索引、benchmark gate；Search |
| 更新破壞可用 DB | restart 無 DB | staged/atomic/rollback fault tests；App + Security |
| 穩定 ID 改變造成收藏失聯 | orphan 激增 | ID policy、migration map/report；Data |
| 授權不允許重散布 | gate 缺 metadata | source approval before import；Licensing |
| AI 草稿誤發布 | status skip | state machine + reviewer evidence gate；Editorial |
| 多平台 native plugin 差異 | 某平台 build/runtime fail | platform matrix + abstraction + smoke tests；App/QA |
| P0 被內容／P1 膨脹拖延 | WIP 長期無驗收 | milestone gates、WIP limit、scope owner；PM |

## 13. 尚待驗證但不阻擋 M0 的假設

- Flutter 套件的最終版本只在 dependency lock／platform spike 後固定，ADR 記錄的是角色與邊界，不是永遠鎖定某版本。
- 公開 release endpoint、manifest signing 與 App 商店分發細節在 M4 前完成威脅模型與 ADR。
- 內容編輯器可先以本機／內網單一管理者運作；正式多人權限不屬 MVP。
- 真實資料來源必須經 licensing review 後才可採用；fixture／原創 20 詞條不代表任何外部資料源已核准。
