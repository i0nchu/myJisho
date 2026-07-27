# Ubuntu Server 24.04 staging 部署手冊

- 適用環境：Ubuntu Server 24.04 LTS（amd64 或 arm64）
- 部署型態：單機 Docker Compose、Caddy HTTPS、Ollama、Kotoba API
- 資料型態：staging 測試資料，保存在伺服器本機 Docker volume
- 不包含：NAS、正式資料搬遷、HA、公共詞條發布、Android App

## 1. 支援判定與拓樸

Kotoba 的伺服器端現在提供 Ubuntu Server 24.04 staging 部署。客戶端產品
仍是 iOS、Windows、macOS；Android 已依客戶決策移除，不是待驗證平台。
倉庫內的 Flutter Linux runner 不代表 Linux 桌面 App 已列入產品發布承諾。

```text
iPhone / Windows App / macOS App
                  │
                  │ HTTPS + bearer token
                  ▼
        stage-kotoba.example.com
                  │
             Caddy :443
                  │ Docker private network
                  ▼
           Kotoba API :8766
             │           │
             │           └─ local SQLite
             ▼
          Ollama :11434
             └─ qwen3:8b
```

對外只發布 Caddy 的 TCP 80、TCP/UDP 443。Kotoba API 在主機上只綁
`127.0.0.1:8766`，Ollama 不發布任何 host port。API 所有請求都需要
bearer token，Caddy 傳入的 Host 也必須出現在 allowlist。

## 2. 上線前準備

### 2.1 建議規格

CPU-only staging 的最低建議是 4 vCPU、16 GB RAM、30 GB 可用磁碟；
較合適的實機驗收基線是 8 vCPU、32 GB RAM、60 GB SSD。`qwen3:8b`
在 CPU 上的延遲會因 CPU 與記憶體頻寬有明顯差異，正式決定硬體前須以
第 8 節的測試實測 P50/P95。標準 Compose 是 CPU 版；GPU 加速需另行
安裝 NVIDIA Container Toolkit 並加入 GPU overlay。

### 2.2 DNS 與網路

準備一個只供 staging 使用的網域，例如：

```text
stage-kotoba.example.com
```

在 DNS 建立指向伺服器公網 IP 的 A 記錄；只有伺服器確實具備可連入的
IPv6 時才建立 AAAA。若伺服器在 NAT 後方，將 TCP 80、TCP 443 轉送到
此主機；UDP 443 可選擇轉送以使用 HTTP/3。Caddy 需能從公網接收 80 或
443 的 ACME 驗證，才可自動取得公開 TLS 憑證。

雲端 security group／路由器防火牆建議：

| Port | Source | 用途 |
| --- | --- | --- |
| TCP 22 | 僅管理者固定 IP 或 VPN | SSH |
| TCP 80 | Internet | ACME 驗證與 HTTPS redirect |
| TCP 443 | Internet；如有 VPN 可再限縮 | App API |
| UDP 443 | Internet，可省略 | HTTP/3 |

不要開放 8766 或 11434。Docker published ports 可能先於 UFW 規則處理，
因此不能只靠 UFW 隱藏容器服務；同時使用雲端 security group、路由器 ACL
或 `DOCKER-USER` 規則。

### 2.3 搬移程式碼

以下以 `/opt/kotoba` 為例。若已有 Git remote：

```bash
sudo install -d -o "$USER" -g "$USER" /opt/kotoba
git clone <YOUR_REPOSITORY_URL> /opt/kotoba
cd /opt/kotoba
```

若尚未放到 Git server，可從開發機以 `rsync` 搬移，但不要傳送
`deploy/.env`、`deploy/backups`、`.tooling` 或任何正式資料：

```bash
rsync -av --delete \
  --exclude .git \
  --exclude .tooling \
  --exclude deploy/.env \
  --exclude deploy/backups \
  ./ <SERVER_USER>@<SERVER_IP>:/opt/kotoba/
```

`--delete` 只適合專用且已確認的 `/opt/kotoba` 目標。若目標內有手動保存
的檔案，先移除該參數。

## 3. 安裝 Docker Engine

倉庫提供 Ubuntu 24.04 專用安裝器，內容使用 Docker 官方 apt repository，
遇到既有衝突套件時會停止，不會自行刪除既有 container runtime：

```bash
cd /opt/kotoba
chmod +x scripts/*.sh
sudo ./scripts/install-docker-ubuntu.sh
```

第一次安裝會把執行 sudo 的管理帳號加入 `docker` 群組。此群組具有
root 等級權限，只應授予可信任帳號。安裝完成後登出 SSH 並重新登入：

```bash
exit
ssh <SERVER_USER>@<SERVER_IP>
docker version
docker compose version
```

若主機已正確安裝 Docker Engine 與 Compose v2，安裝器只會檢查服務並略過
套件安裝。

## 4. 一鍵部署 staging

先確認 DNS 已指向此伺服器、80/443 可由公網連入，再執行：

```bash
cd /opt/kotoba
./scripts/deploy-self-hosted.sh \
  --domain stage-kotoba.example.com
```

腳本會：

1. 以權限 `600` 建立 `deploy/.env` 與 64 字元隨機 bearer token。
2. 建立權限 `700` 的 `deploy/backups`。
3. 啟動固定版本的 Ollama，下載 `qwen3:8b`。
4. 建置並啟動非 root 的 Kotoba API container。
5. 啟動 Caddy，自動申請／續期公開 TLS 憑證。
6. 依序驗證主機 loopback 與公開 HTTPS health endpoint。

首次下載模型與 image 需要數 GB 流量，CPU-only 主機也可能需要數分鐘。
若模型已在 `ollama-models` volume，可使用：

```bash
./scripts/deploy-self-hosted.sh \
  --domain stage-kotoba.example.com \
  --skip-model-pull
```

`--skip-public-health` 僅供 DNS 尚在傳播時診斷使用；要交付實機測試前仍須
讓公開 HTTPS health check 通過。

## 5. 部署後檢查

### 5.1 Container 與 log

```bash
cd /opt/kotoba/deploy
docker compose \
  --env-file .env \
  -f compose.yaml \
  -f compose.stage.yaml \
  ps

docker compose \
  --env-file .env \
  -f compose.yaml \
  -f compose.stage.yaml \
  logs --tail=200 kotoba-api ollama caddy
```

三個常駐 service 應為 running，`kotoba-api` 與 `ollama` 應為 healthy。
持續觀察時在 logs 命令最後加 `--follow`。

### 5.2 API 驗證

在 server 上：

```bash
cd /opt/kotoba
TOKEN=$(sed -n 's/^KOTOBA_API_TOKEN=//p' deploy/.env)
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${TOKEN}" \
  https://stage-kotoba.example.com/api/health
unset TOKEN
```

預期會得到含有 `ok: true`、service 與 model 的 JSON。接著執行真實網路搜尋、
LLM 生成、自動驗證、保存、再次查詢重用與 Revision 測試：

```bash
python3 scripts/stage-smoke-test.py --query 食べました
```

此命令會在 staging 詞庫新增測試詞條；不得在正式資料庫執行。通過時會逐項
輸出 `[PASS]`，若模型內容未過 validator，也會印出實際失敗原因。

## 6. 實機 App 連線

API URL 與 token 是 Flutter 編譯期參數。token 位於 server 的
`deploy/.env`，請透過 SSH 或密碼管理器安全取用，不要提交 Git、貼到 issue
或寫進公開 CI log。

在有 Flutter SDK 的開發機執行：

```bash
cd apps/dictionary_app
flutter pub get
flutter run -d <DEVICE_ID> \
  --dart-define=KOTOBA_LOCAL_API=https://stage-kotoba.example.com \
  --dart-define=KOTOBA_LOCAL_API_TOKEN=<KOTOBA_API_TOKEN>
```

- iPhone 必須由 macOS/Xcode 進行簽署與實機啟動。
- Windows 使用 `-d windows`。
- macOS 使用 `-d macos`。
- iPhone 不需加入不安全 HTTP 例外，因 staging endpoint 使用公開 HTTPS。
- Android 已移除，不提供 build、簽章或實機驗收。

實機最小 smoke：

1. 開啟 App，確認內建離線詞可查。
2. 正式送出一個本地沒有的詞；輸入過程不得建立 generation job。
3. 等待詞條顯示，確認詞頭、讀音、詞性、至少一個義項與生成資訊。
4. 再查相同詞，應直接命中且明顯快於首次。
5. 查看 Revision，進行一次編輯、鎖定／解鎖、重新生成及舊版復原。
6. 讓裝置斷網，確認已生成詞與內建詞仍可查；新詞生成應顯示可理解的錯誤。
7. 播放 TTS，確認實機選用日文 voice，而非中文 voice。

## 7. 日常操作

以下命令皆在 `/opt/kotoba/deploy` 執行，且不會刪除 volume：

```bash
# 重啟
docker compose --env-file .env -f compose.yaml -f compose.stage.yaml restart

# 停止
docker compose --env-file .env -f compose.yaml -f compose.stage.yaml down

# 再啟動
docker compose --env-file .env -f compose.yaml -f compose.stage.yaml up -d
```

不要執行 `docker compose down -v`，該參數會刪除詞庫、模型及 TLS volume。

本次 staging 的本機持久資料為：

| 資料 | Docker volume／路徑 | 備註 |
| --- | --- | --- |
| 生成詞庫 SQLite | `kotoba-stage_kotoba-data` | 必須備份 |
| Ollama 模型 | `kotoba-stage_ollama-models` | 可重新下載 |
| Caddy 憑證 | `kotoba-stage_caddy-data` | Caddy 管理 |
| Caddy runtime config | `kotoba-stage_caddy-config` | Caddy 管理 |
| API token／設定 | `/opt/kotoba/deploy/.env` | 機密、權限 600 |
| DB 備份 | `/opt/kotoba/deploy/backups` | stage 本機磁碟 |

不要直接修改 `/var/lib/docker/volumes` 內的檔案。

## 8. 備份、還原、更新與回滾

### 8.1 一致性備份

```bash
cd /opt/kotoba
./scripts/backup-self-hosted.sh
```

腳本只短暫停止 API，Caddy 與 Ollama 可保持運行；它會將
`kotoba-data` 建立成 `deploy/backups/kotoba-stage-<UTC>.tar.gz`，另存
SHA-256 checksum，然後重新啟動 API。模型不備份，因為可由 `ollama pull`
重建。`deploy/.env` 也不會放進資料備份；正式上線前應把它存入加密的
secret／backup 系統。

### 8.2 還原

列出備份：

```bash
ls -lh /opt/kotoba/deploy/backups
```

還原指定版本：

```bash
cd /opt/kotoba
./scripts/restore-self-hosted.sh \
  kotoba-stage-20260727T120000Z.tar.gz
```

腳本會先驗證 checksum，再自動備份目前資料，要求輸入 `RESTORE`，然後才
清空資料 volume 並解壓指定備份。自動化環境可加 `--yes`，但人工操作不建議。

### 8.3 更新

```bash
cd /opt/kotoba
./scripts/backup-self-hosted.sh
git rev-parse HEAD
git pull --ff-only
./scripts/deploy-self-hosted.sh \
  --domain stage-kotoba.example.com \
  --skip-model-pull
python3 scripts/stage-smoke-test.py --query 更新
```

更新前記錄的 Git SHA 與備份檔名是回滾依據。`deploy/.env` 與 volumes 不受
`git pull` 影響。

### 8.4 回滾

```bash
cd /opt/kotoba
git switch --detach <PREVIOUS_GIT_SHA>
./scripts/deploy-self-hosted.sh \
  --domain stage-kotoba.example.com \
  --skip-model-pull
```

若只是程式回歸且舊程式可讀新資料，完成 health／smoke 後即可。若更新包含
不相容資料遷移，再以 8.2 的更新前備份還原。問題處理完成後，切回原分支，
不要長期把 server 留在 detached HEAD。

## 9. staging 驗收與退出條件

部署成功只證明服務可執行，不等於詞條品質或正式發布完成。建議至少抽測
30 個詞，涵蓋：

- 5 個常用名詞、5 個一段／五段／不規則動詞活用。
- 5 個い形容詞／な形容詞活用、5 個外來語。
- 5 個同音異義或多義詞、5 個長尾／專門詞。

每筆記錄 query、還原原形、首次延遲、重複查詢延遲、來源數、
knowledge-only、validator 結果、日文正確性、例句相關性與是否誤含中文。
本輪 provisional gate：

| 指標 | staging 目標 |
| --- | --- |
| 自動驗證後 ready | ≥ 95% |
| 重複查詢重用同一 entry | 100% |
| 未送出前無 generation job | 100% |
| 中文混入正式日文釋義 | 0 |
| Revision／復原不覆蓋歷史 | 100% |
| HTTPS／token／Host allowlist | 100% |
| 實機首次生成完成 | 在 App timeout 內；另記 P50/P95 |

多來源檢索目前只有日文 Wiktionary 與日文 Wikipedia，兩者同屬 Wikimedia
生態；因此本輪可驗證「兩個 endpoint 與來源引用一致性」，不能據此宣稱
已完成異質多來源檢索。詞條生成品質與實機可用性也必須以本節記錄後才能
由 pending 改為 pass。

## 10. 常見問題

### Caddy 無法取得憑證

```bash
cd /opt/kotoba/deploy
docker compose --env-file .env -f compose.yaml -f compose.stage.yaml \
  logs --tail=200 caddy
```

依序確認 A/AAAA、NAT、雲端 security group、TCP 80/443。錯誤的 AAAA
很常造成 CA 或 IPv6 client 連到錯誤主機。

### API healthy，但 App 連不到

先從手機瀏覽器開啟 `https://stage-kotoba.example.com/api/health`。收到
`401` 代表 HTTPS 與路由正常，只是瀏覽器沒有 bearer token；完全無法開啟
才是 DNS／TLS／網路問題。再確認 App build 的 API URL 沒有尾端路徑，且
token 與 server 的 `deploy/.env` 完全一致。

### 生成很慢或 App timeout

```bash
docker stats
cd /opt/kotoba/deploy
docker compose --env-file .env -f compose.yaml -f compose.stage.yaml \
  exec ollama ollama ps
```

先記錄 CPU、RAM、swap 與實際耗時。CPU-only `qwen3:8b` 若穩定超出 App
timeout，staging 結論應是硬體／模型效能 gate 未通過；可升級 CPU／RAM、
導入受支援 GPU，或另開模型品質比較，不應直接把慢速誤判為 API 故障。

### 磁碟空間增加

```bash
docker system df
du -sh /opt/kotoba/deploy/backups
```

刪除舊備份前先確認至少保留一份已驗證且可回復的版本。不要以
`docker system prune --volumes` 清理 staging 主機。

## 11. 上游參考

- [Docker Engine：Ubuntu 安裝](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Engine：Linux 安裝後設定](https://docs.docker.com/engine/install/linux-postinstall/)
- [Docker：packet filtering、UFW 與 published ports](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [Caddy：Automatic HTTPS](https://caddyserver.com/docs/automatic-https)
- [Ollama：Docker 執行方式](https://docs.ollama.com/docker)
