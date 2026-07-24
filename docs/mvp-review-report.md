# Kotoba MVP 客戶評審報告

- 評審版本：Engineering MVP 0.1
- 評審日期：2026-07-24
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
- 完整資料包更新：HTTPS 固定端點、串流 staging、進度／取消、
  manifest/assets/checksums/SQLite 驗證、exclusive lock、quiesce/reopen、
  rollback marker 與 cache invalidation。
- 24 筆原創 CC0 開發 fixture；全部保留 `ai_draft`，App 明確顯示為
  「レビュー前のデモ内容」，production builder 會拒絕發布。

## 2. 驗證證據

| 檢查 | 結果 | 證據摘要 |
|---|---|---|
| Python 資料／搜尋／供應鏈 | PASS | 37/37 |
| AC-02/03/04 固定搜尋 corpus | PASS（自動化） | 250/250 全域唯一、可重現；235-row temporary SQLite 經 deployed Drift 全量驗證 exact/prefix/contains/deinflection、ID/kind/order/negative/explain |
| 編輯器 schema、workflow、storage、HTTP security | PASS | 25/25 |
| Flutter format | PASS | 61 files，0 changes |
| Flutter analyze | PASS | No issues found |
| Flutter unit/widget/integration | PASS | 80/80 |
| TTS 日文 voice P0 | PASS（自動化）／DEVICE PENDING | 枚舉系統 voice、正規化並明確選取 `ja` locale；中文-only、設定拒絕、retry、按鈕／Space reading 與真實 success/error 均有測試；三平台實機尚未驗收 |
| 遠端更新／fault injection | PASS（自動化） | 24/24；含 pre-open recovery、真實 Drift readiness、reopen failure rollback、HTTP cleanup、assets↔SQLite binding |
| AC-08/09 adaptive/a11y automation | PASS（自動化） | 12 adaptive/a11y + 8 platform UX cases；390px、雙欄、200%、鍵盤、semantics、contrast、reduced motion |
| 供應鏈 audit | PASS（目前 lock） | 106 locked／102 hosted；OSV 0 漏洞、0 缺 license、0 secret；CycloneDX 1.7 SBOM |
| Flutter Web release build | PASS | `build/web` 成功產生 |
| 內容編輯器瀏覽器 smoke | PASS | 搜尋、選取、編輯表單、即時預覽 |
| Flutter 桌面響應式 smoke | PASS | 最新 Web build 雙欄搜尋／詳情空狀態 |
| Flutter 390×844 smoke | PASS | `shinbun`→新聞→詳情，無水平捲動 |
| 100k 搜尋 benchmark | PASS | P95 6.070 ms；規格門檻 <100 ms |
| Android scope removal | PASS | 無 runner、無 CI job、無發布／驗收承諾 |

本機全套驗證入口：`scripts/verify.ps1`。

## 3. 正式發布 Gate

| Gate | 狀態 | 完成條件 |
|---|---|---|
| Engineering vertical slice | PASS | 已從 canonical data 建置並由 App 查詢 |
| 內容／授權發布 | BLOCKED | 合格日文審核者完成人工審核，至少 20 筆達 approved/published |
| 完整搜尋黃金集 | AUTOMATION PASS／REVIEW PENDING | 固定 corpus 已經 canonical builder、Python reference 與 deployed Drift 全量驗證；仍須日文／產品 reviewer 核准語言預期 |
| 遠端完整資料包更新 | AUTOMATION PASS／CONFIG PENDING | 安全交易與 fault suite 通過；客戶須選定 HTTPS host/CDN、build-time endpoint、rollback policy，並決定 manifest signing/key rotation |
| Adaptive／accessibility | AUTOMATION PASS／DEVICE PENDING | Widget 契約通過；VoiceOver、Narrator、真實 IME、高對比與系統 reduced-motion 仍須三平台驗收 |
| 日文系統 TTS | AUTOMATION PASS／DEVICE PENDING | 非 `ja` voice 一律 fail-closed，只有完成 `getVoices → setLanguage → setVoice` 驗證才播放權威 reading；仍須 iOS、Windows、macOS 在日文 voice 已安裝／缺失及離線狀態各驗一次 |
| Dependency/license/secret/SBOM | AUTOMATION PASS／CI EVIDENCE PENDING | 本機 exact-lock audit 通過；release commit 的 CI reports/SBOM 仍須保存及人工審閱 |
| 原生三平台 build | PENDING | GitHub CI 實際跑通 iOS simulator、Windows、macOS artifacts |
| 實機／實體桌面驗收 | PENDING | iOS 及至少一個桌面完成離線、IME、TTS、音訊、a11y smoke |
| 效能與啟動指標 | PARTIAL | SQLite benchmark 通過；本次 10k host-debug UI regression P95 290.072 ms（800 ms 工程 budget）；仍須 release app 冷啟動與真實 SQLite UI P95 ≤150 ms |

依產品規格，以上 Blocked／Pending 項目完成前不得稱為「正式 MVP 已驗收」或
發布 production dictionary。這不影響本版用於客戶操作評審與需求修訂。

## 4. 客戶評審會議議程

1. 搜尋結果與詞條資訊層級是否符合「數秒內先懂最常用義」的產品方向。
2. 手機單頁、桌面雙欄、收藏／歷史／設定的操作是否需要調整。
3. 指派具資格的日文內容審核者，確認 24 筆草稿的 reviewer、evidence 與
   publishing responsibility。
4. 確認遠端更新的 package host/CDN、manifest signing/key rotation 與 rollout 政策。
5. 確認 iOS／Windows／macOS 的 CI、簽章、測試裝置與商店／安裝包交付方式。

## 5. 建議下一個里程碑

先進行客戶 UX 驗收並凍結主要互動；同時啟動人工內容審核、三平台 CI 與實機
測試。完成後產出 Release Candidate 0.1，執行完整 P0 traceability review，才將
狀態由 NO-GO 改為 GO。
