# ADR-0001：採用 polyglot monorepo 與明確模組邊界

- 狀態：Accepted
- 日期：2026-07-22

## Context

Kotoba 同時包含 Flutter App、Web 編輯器、Python 資料管線、共享 schema、搜尋核心和版本化內容。這些模組需要協同演進，但部署生命週期不同。

## Decision

採單一 monorepo。Flutter/Dart 負責 App 與 runtime 搜尋邏輯；Python 負責 ETL、validation、SQLite/release builder 與 editor API；TypeScript 負責 Web editor。跨語言契約以版本化 JSON Schema、SQLite schema、manifest schema 和 golden fixtures 表達，不以複製未測試的程式碼共享行為。

Canonical／editorial 檔案是內容權威來源，`data/generated` 是可重建產物。Widget 不得呼叫 raw SQL；search engine 不依賴 Flutter UI；editor 不得直接編輯生成 SQLite。

## Consequences

好處是跨模組變更可在同一 PR 做原子審查與 contract tests，內容和程式版本可追溯。代價是 CI 與工具鏈較複雜，需避免「共享資料夾」演變為無 owner 的耦合。各 workspace 需獨立 lockfile／測試，根層 scripts 只做 orchestration。

## Rejected alternatives

- 多 repository：初期 contract/schema 漂移與跨 repo release 協調成本過高。
- 全部使用 Dart：資料 ETL／schema 工具生態與編輯 API 開發效率較差。
- 全部使用 TypeScript：不符合 Flutter App 技術要求。

## Verification

CI 從根目錄能 bootstrap 並執行各 workspace tests；architecture lint／review 確認禁止依賴方向；乾淨 checkout 能從 authoritative sources 重建 fixture database。
