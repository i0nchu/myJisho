# Ubuntu Server 24.04 內網 staging 部署手冊

- 適用環境：Ubuntu Server 24.04 LTS
- 網路範圍：server loopback；實機／遠端選用 Tailscale Serve
- 模型服務：沿用主機已安裝的 Ollama，不建立 Ollama container
- 資料位置：server 本機 Docker volume，不使用 NAS
- 不包含：公網 port、公開 DNS、Caddy、Tailscale Funnel、正式資料

## 1. 實際拓樸

```text
Server 本機測試
    │ HTTP 127.0.0.1:8766 + bearer token
    ▼
Kotoba API container（host network，只監聽 loopback）
    │
    ├─ http://127.0.0.1:11434/v1
    │          ▼
    │    主機既有 Ollama + qwen3:8b
    │
    └─ Docker volume：kotoba-stage_kotoba-data

選用實機／外部測試
iPhone / Windows / macOS
    │ Tailscale tailnet 私人 HTTPS
    ▼
Tailscale Serve
    │ proxy 至 http://127.0.0.1:8766
    └─ Kotoba API
```

標準部署不發布 80、443、8766 或 11434，也不要求公開網域。Tailscale Serve
只在 tailnet 內提供 HTTPS；不得使用會把服務公開到 Internet 的
`tailscale funnel`。

## 2. Ollama 不需要重裝

如果 Ubuntu 主機已經安裝並執行 Ollama，不需要再安裝，也不需要啟動
Compose 內的 Ollama service。先檢查：

```bash
systemctl status ollama --no-pager
curl --fail http://127.0.0.1:11434/api/version
ollama list
```

Kotoba 預設需要 `qwen3:8b`。安裝 Ollama 不代表模型已下載；若
`ollama list` 沒有該模型，執行：

```bash
ollama pull qwen3:8b
ollama show qwen3:8b
```

再檢查 OpenAI-compatible endpoint：

```bash
curl --fail http://127.0.0.1:11434/v1/models
```

Kotoba API container 使用 Linux host networking，因此可直接連主機的
`127.0.0.1:11434`。不必把 Ollama 改成 `0.0.0.0`，也不要向 LAN 或
tailnet 公開 11434。

## 3. 建議 server 規格

CPU-only staging 最低建議 4 vCPU、16 GB RAM、30 GB 可用 SSD；較適合
`qwen3:8b` 實機驗收的是 8 vCPU、32 GB RAM、60 GB SSD。這只是起始基線，
最後仍以真實生成延遲與記憶體用量決定。

已有 GPU 且主機 Ollama 能正常使用時，Kotoba 會直接受益，不必在 Kotoba
Compose 額外宣告 GPU。可用以下命令確認模型實際執行情況：

```bash
ollama ps
nvidia-smi  # 僅 NVIDIA 主機
```

## 4. 搬移程式碼

以下使用 `/opt/kotoba`：

```bash
sudo install -d -o "$USER" -g "$USER" /opt/kotoba
git clone <YOUR_REPOSITORY_URL> /opt/kotoba
cd /opt/kotoba
```

若尚未放到 Git server，可從開發機以 `rsync` 搬移，但不要傳送機密或資料：

```bash
rsync -av \
  --exclude .git \
  --exclude .tooling \
  --exclude deploy/.env \
  --exclude deploy/backups \
  ./ <SERVER_USER>@<SERVER_IP>:/opt/kotoba/
```

## 5. Docker Engine

如果尚未安裝 Docker Engine 與 Compose v2：

```bash
cd /opt/kotoba
sudo ./scripts/install-docker-ubuntu.sh
```

第一次安裝後登出 SSH 並重新登入：

```bash
exit
ssh <SERVER_USER>@<SERVER_IP>
docker version
docker compose version
```

安裝器使用 Docker 官方 apt repository，遇到既有衝突 runtime 會停止，
不會自動刪除既有 container 或資料。`docker` 群組具 root 等級權限，
只應加入可信任的 server 管理者。

## 6. 純 server 內部部署

```bash
cd /opt/kotoba
./scripts/deploy-self-hosted.sh
```

腳本會：

1. 確認主機 Ollama 的 `127.0.0.1:11434` 可用。
2. 確認 `qwen3:8b` 存在；缺少時才執行 `ollama pull`。
3. 建立權限 `600` 的 `deploy/.env` 與隨機 bearer token。
4. 只建置、啟動 Kotoba API，不啟動 Ollama container。
5. 讓 API 只監聽 `127.0.0.1:8766` 並完成 health check。

確認 container：

```bash
cd /opt/kotoba/deploy
docker compose \
  --env-file .env \
  -f compose.internal.yaml \
  ps

docker compose \
  --env-file .env \
  -f compose.internal.yaml \
  logs --tail=200 kotoba-api
```

確認 host 沒有公開 listener：

```bash
sudo ss -lntp | grep -E ':(8766|11434)\b'
```

預期兩者都只出現在 `127.0.0.1` 或 `::1`。若 11434 已經是
`0.0.0.0:11434`，請先檢查既有 Ollama 設定與防火牆；Kotoba 不需要它對外。

## 7. 本機真實生成測試

```bash
cd /opt/kotoba
python3 scripts/stage-smoke-test.py --query 食べました
```

未設定 Tailscale 時，smoke script 只連
`http://127.0.0.1:8766`。它會驗證：

- bearer token 與 health endpoint。
- 正式送出 generation job。
- 主機 Ollama、網路搜尋、LLM 結構化輸出與自動驗證。
- SQLite 保存與 Revision。
- 第二次相同查詢直接重用本地 entry。

這個命令會新增 staging 測試詞，不得對正式資料庫執行。

### 7.1 內網桌面 App：SSH tunnel

Windows／macOS 測試機可在不開 LAN port、不安裝 Tailscale 的情況下建立
SSH tunnel：

```bash
ssh -N -L 8766:127.0.0.1:8766 <SERVER_USER>@<SERVER_LAN_IP>
```

保持該連線開啟，桌面 App 使用：

```text
KOTOBA_LOCAL_API=http://127.0.0.1:8766
```

此方式適合桌面 App，不適合 iPhone，因為 iPhone 的 `127.0.0.1` 是手機本身。
為避免 token 在 LAN 上以明文傳送，本專案不提供直接公開
`http://<LAN_IP>:8766` 的模式。iPhone 實機請使用下一節的 Tailscale
私人 HTTPS。

## 8. 選用 Tailscale 私人 HTTPS

若只在 server 本機驗證，到第 7 節即可。需要 iPhone、桌面實機或外部網路
連線時，才在 server 與測試裝置安裝並登入同一個 tailnet。

若 server 尚未安裝 Tailscale，依官方 Linux 安裝方式完成後：

```bash
sudo tailscale up
tailscale status
```

重新部署並啟用 Serve：

```bash
cd /opt/kotoba
./scripts/deploy-self-hosted.sh --tailscale
```

腳本會自動讀取 server 的 MagicDNS FQDN，加入 API Host allowlist，然後執行：

```bash
sudo tailscale serve --bg --yes http://127.0.0.1:8766
```

確認：

```bash
sudo tailscale serve status
python3 scripts/stage-smoke-test.py --query 木漏れ日
```

Tailscale Serve 的 HTTPS URL 類似：

```text
https://kotoba-server.example-tailnet.ts.net
```

它只在 tailnet 內可用。若要停止分享：

```bash
sudo tailscale serve reset
```

不要執行 `tailscale funnel`。

## 9. 實機 App

server 的 `deploy/.env` 會保存：

```text
KOTOBA_STAGE_DOMAIN=kotoba-server.example-tailnet.ts.net
KOTOBA_API_TOKEN=<secret>
```

在 Flutter 開發機：

```bash
cd apps/dictionary_app
flutter pub get
flutter run -d <DEVICE_ID> \
  --dart-define=KOTOBA_LOCAL_API=https://kotoba-server.example-tailnet.ts.net \
  --dart-define=KOTOBA_LOCAL_API_TOKEN=<KOTOBA_API_TOKEN>
```

- iPhone 與 server 都須登入具存取權的 tailnet。
- iPhone 由 macOS/Xcode 建置及簽署。
- Windows 使用 `-d windows`，macOS 使用 `-d macos`。
- Tailscale Serve 使用 HTTPS，因此不需替 iOS 加入不安全 HTTP 例外。
- Android 已依客戶決策移除。

實機最小驗收：

1. 內建離線詞可查。
2. 輸入搜尋文字時不建立 generation job。
3. 正式送出本地不存在的詞後才開始生成。
4. 詞條通過驗證後立即顯示，且有來源與生成資訊。
5. 再查相同詞直接命中。
6. Revision、編輯、鎖定、重新生成與復原可用。
7. TTS 使用日文 voice。
8. 關閉 Tailscale 或斷網後，新生成顯示明確錯誤，既有本地詞仍可查。

## 10. 日常操作

```bash
cd /opt/kotoba/deploy

# 狀態
docker compose --env-file .env -f compose.internal.yaml ps

# Log
docker compose --env-file .env -f compose.internal.yaml \
  logs --tail=200 --follow kotoba-api

# 重啟 API；不影響主機 Ollama
docker compose --env-file .env -f compose.internal.yaml restart kotoba-api

# 停止 API；不刪資料
docker compose --env-file .env -f compose.internal.yaml down

# 再啟動
docker compose --env-file .env -f compose.internal.yaml up -d
```

不要執行 `docker compose down -v`。

本機資料：

| 資料 | 位置 | 備註 |
| --- | --- | --- |
| 生成詞庫 | `kotoba-stage_kotoba-data` | Docker volume |
| Ollama 模型 | 主機既有 Ollama 目錄 | Kotoba 不管理 |
| API 設定/token | `/opt/kotoba/deploy/.env` | 權限 600 |
| DB 備份 | `/opt/kotoba/deploy/backups` | 本機 stage |
| Tailscale Serve | tailscaled state | 選用 |

## 11. 備份、還原、更新與回滾

一致性備份：

```bash
cd /opt/kotoba
./scripts/backup-self-hosted.sh
```

它只短暫停止 Kotoba API，不停止主機 Ollama。輸出為：

```text
deploy/backups/kotoba-stage-<UTC>.tar.gz
deploy/backups/kotoba-stage-<UTC>.tar.gz.sha256
```

還原：

```bash
./scripts/restore-self-hosted.sh \
  kotoba-stage-20260727T120000Z.tar.gz
```

還原前會驗證 checksum、自動備份目前資料，並要求輸入 `RESTORE`。

更新：

```bash
./scripts/backup-self-hosted.sh
git rev-parse HEAD
git pull --ff-only
./scripts/deploy-self-hosted.sh --tailscale  # 沒用 Tailscale 就移除此參數
python3 scripts/stage-smoke-test.py --query 更新
```

回滾程式：

```bash
git switch --detach <PREVIOUS_GIT_SHA>
./scripts/deploy-self-hosted.sh --tailscale
```

若資料格式也不相容，再還原更新前備份。修復後切回正式分支，不要讓 server
長期停在 detached HEAD。

## 12. staging 品質 Gate

部署成功只證明服務能執行，不代表生成品質或正式發布完成。至少抽測 30 詞：

- 常用名詞 5、動詞活用 5。
- 形容詞活用 5、外來語 5。
- 同音／多義詞 5、長尾／專門詞 5。

記錄首次延遲、重複查詢延遲、來源數、knowledge-only、validator 結果、
日文正確性、例句相關性與中文混入。暫定標準：

| 指標 | staging 目標 |
| --- | --- |
| ready | ≥ 95% |
| 相同詞重用同一 entry | 100% |
| 未正式送出前無 job | 100% |
| 日文釋義混入中文 | 0 |
| Revision 歷史保留 | 100% |
| server port 未公開 | 100% |
| Tailscale URL 僅 tailnet 可用 | 100% |

目前的日文 Wiktionary 與日文 Wikipedia 都屬 Wikimedia 生態，不能因此
宣稱已完成異質多來源檢索。真實模型品質與實機可用性也必須完成記錄後才可
由 pending 改為 pass。

## 13. 上游參考

- [Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility)
- [Ollama Linux service](https://docs.ollama.com/linux)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
- [Tailscale Serve CLI](https://tailscale.com/docs/reference/tailscale-cli/serve)
- [Tailscale Linux 安裝](https://tailscale.com/docs/install/linux)
- [Docker Engine Ubuntu 安裝](https://docs.docker.com/engine/install/ubuntu/)
