# Self-hosted 生成式詞庫

- 狀態：MVP implementation baseline
- 適用：私人部署者的本地詞庫
- 不適用：未來公共詞條包的投稿與發布治理

## 1. 執行流程

```text
搜尋欄輸入變化
└─ 只搜尋本地生成詞庫與內建詞庫，不產生內容

使用者正式送出
└─ 正規化／活用還原
   └─ 搜尋本地生成詞庫與內建詞庫
      ├─ 命中：顯示既有詞條
      └─ 未命中：Wikimedia 搜尋
         └─ OpenAI-compatible LLM 產生 JSON
            └─ Schema 與語意自動驗證
               ├─ 通過：建立 immutable Revision、寫入 SQLite、立即顯示
               └─ 失敗：只保留 failed job，顯示原因與重試，不寫入 entries
```

搜尋結果由兩層組成：

1. App 內建、唯讀的版本化辭典包，離線時仍可查詢。
2. `services/local_dictionary` 管理的可變本地 SQLite；私人生成內容只存在此層。

這兩層刻意與 `services/editor_api` 的公共辭典包編輯／發布流程分離，避免私人生成詞條意外進入公共發布產線。

## 2. 狀態與 Revision

Generation job 使用 `generating`、`ready`、`failed`、`stale`。正式 `entries` 只保存通過驗證的 `ready` 或 `stale` 詞條。失敗內容不會成為可查詞條。

每次內容變更建立新 Revision，來源固定為：

- `generated`：首次模型生成。
- `edited`：使用者編輯、復原舊版或切換鎖定。
- `regenerated`：以模型重新生成。

編輯、復原、重新生成與鎖定都不覆寫既有 Revision。刪除會移除目前可查詞條，但保留 Revision 稽核紀錄。鎖定詞條時，API 拒絕重新生成。

## 3. 自動驗證

`services/local_dictionary/schema.json` 與語意 validator 會在正式保存前檢查：

- JSON Schema、必要詞頭、讀音、詞性與至少一個義項。
- 主要詞形與主要讀音唯一。
- 查詢活用形可合理還原到回傳原形。
- 本地詞形不重複。
- 詞條、義項與例句引用只使用本次搜尋取得的 source ID。
- 來源快照、來源數量及 knowledge-only 標記一致。
- 例句包含詞彙、讀音或合理活用詞幹。
- 日文釋義具日文假名且不含常見中文專用標記。
- 空白、重複義項、首尾空白與連續異常空白。

任何一項失敗都產生具 `path`、`code`、`message` 的錯誤清單。

## 4. 預設資料來源與模型

預設搜尋器使用日文 Wiktionary 與日文 Wikipedia 的 MediaWiki API，並把本次實際引用的標題、URL、摘要、抓取時間與授權識別保存為 Revision 的來源快照。

預設模型介面為 OpenAI-compatible `/v1/chat/completions`，本機預設：

- Endpoint：`http://127.0.0.1:11434/v1`
- Model：`qwen3:8b`
- 可用 `KOTOBA_LLM_BASE_URL`、`KOTOBA_LLM_MODEL`、`KOTOBA_LLM_API_KEY` 覆寫。

模型輸出不是信任邊界；即使 JSON mode 成功，仍必須通過本專案 validator。

## 5. 一鍵私人部署

Windows 開發／驗收機可執行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/deploy-self-hosted.ps1
powershell -ExecutionPolicy Bypass -File scripts/run-self-hosted-app.ps1
```

第一個命令會：

1. 建立隨機 API bearer token 並保存於未納入 Git 的 `deploy/.env`。
2. 啟動固定版本的 Ollama container。
3. 下載 `qwen3:8b`。
4. 建置並啟動 Kotoba API。
5. 以帶 token 的 `/api/health` 完成健康檢查。

第二個命令從 `deploy/.env` 讀取 token，以 `--dart-define` 啟動 Windows App。可用 `-Device macos` 或 `-Device ios` 切換 Flutter target。

Docker Compose 預設只把 API 發布在 host loopback `127.0.0.1:8766`。實體 iPhone 或跨主機部署必須使用 HTTPS reverse proxy、專用網域與 bearer token，並把該網域加入 `KOTOBA_ALLOWED_HOSTS`；不得直接把未加密的 8766 port 暴露到公網。

## 6. 手動啟動

已有 Ollama 或其他 OpenAI-compatible 模型服務時：

```powershell
$env:KOTOBA_LLM_BASE_URL = 'http://127.0.0.1:11434/v1'
$env:KOTOBA_LLM_MODEL = 'qwen3:8b'
python -m services.local_dictionary
```

API 預設為 `http://127.0.0.1:8766`，資料庫預設在 `services/local_dictionary/.working/local_dictionary.sqlite`。App 的編譯期設定為：

```text
KOTOBA_LOCAL_API
KOTOBA_LOCAL_API_TOKEN
```

## 7. API 摘要

- `GET /api/search?q=...`
- `GET /api/entries`、`GET /api/entries/{id}`
- `POST /api/generation-jobs`、`GET /api/generation-jobs/{id}`
- `PUT /api/entries/{id}`
- `GET /api/entries/{id}/revisions`
- `GET /api/entries/{id}/revisions/{revision}`
- `POST /api/entries/{id}/restore`
- `POST /api/entries/{id}/regenerate`
- `POST /api/entries/{id}/lock`
- `DELETE /api/entries/{id}`

非 loopback 綁定必須提供 `KOTOBA_API_TOKEN`。所有 API 請求在 token 啟用時都必須使用 `Authorization: Bearer ...`。
