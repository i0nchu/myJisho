# AC-08／AC-09 自動化證據

- 證據版本：Engineering MVP 0.1
- 執行日期：2026-07-23
- 適用提交：以本文件所在提交為準
- 執行環境：Windows host、Flutter widget test VM

## 覆蓋範圍

`apps/dictionary_app/test/adaptive_accessibility_acceptance_test.dart` 提供下列
不依賴實機的回歸證據：

| 契約 | 自動化檢查 |
|---|---|
| AC-08 行動版 | 390×844 搜尋、詞條、設定主流程無 RenderFlex／水平 overflow |
| AC-08 桌面版 | 1200×800 同時保留搜尋結果 pane 與詞條 detail pane |
| AC-08 鍵盤 | 搜尋欄自動焦點、方向鍵＋Enter、搜尋輸入時 Space 不播放、快捷鍵可停用 |
| AC-09 200% 文字 | 390×844、系統文字尺度 200%，搜尋、詞條按鈕及設定 theme 仍可操作 |
| AC-09 語意／焦點 | 搜尋、設定、結果、TTS、收藏皆有非空 label、tap action 與 focusable state |
| AC-09 非顏色狀態 | 未審內容同時以 icon、可見文字與 review-status semantics 表達 |
| AC-09 淺／深色 | 核心文字／surface color pairs 以 WCAG 公式驗證至少 4.5:1 |
| AC-09 reduced motion | `disableAnimations`、`accessibleNavigation` 或系統 `reduceMotion` 時略過 route fade |
| 授權可見性 | 設定頁可由鍵盤／觸控開啟 Flutter `LicensePage` 查看 bundled package notices |
| Flutter guideline | 主流程通過 labeled target、iOS tap target、text contrast guideline |

執行：

```powershell
cd apps/dictionary_app
..\..\.tooling\flutter\bin\flutter.bat test `
  test\adaptive_accessibility_acceptance_test.dart --reporter expanded
```

## 搜尋 UI 延遲回歸量測

`apps/dictionary_app/test/search_ui_latency_benchmark_test.dart` 使用固定生成的
10,000 筆 in-memory fixture，先暖機 5 次，再量測 30 次「按下
Search/Enter 至首批結果完成 widget render」的 host wall-clock latency。輸出固定
machine-readable prefix `KOTOBA_UI_SEARCH_BENCHMARK`，包含 P50、P95、max 與
scope 標記。兩次通過紀錄如下；host-debug regression budget 設為
P95 < 800 ms，以保留 CI 環境差異的餘裕。

| 執行情境 | P50 | P95 | max |
|---|---:|---:|---:|
| 單獨執行 benchmark test | 447.329 ms | 611.969 ms | 889.489 ms |
| 完整 Flutter suite | 343.236 ms | 388.184 ms | 401.343 ms |

執行：

```powershell
cd apps/dictionary_app
..\..\.tooling\flutter\bin\flutter.bat test `
  test\search_ui_latency_benchmark_test.dart --reporter expanded
```

此量測只作為同一測試環境下的 UI pipeline 回歸警戒；800 ms 是 debug VM
與 10k 線性 in-memory fixture 的工程 budget，不是產品的 150 ms 目標。它不是：

- iOS、Windows 或 macOS 實機／實體桌面 release/profile 結果；
- 100k SQLite query benchmark；
- process cold start 至搜尋欄可輸入的 P95；
- 規格「輸入完成至首批結果」的 production acceptance 證明。

## 尚待實機證據

AC-08／AC-09 仍須在 iOS、Windows、macOS release candidate 執行並留存：

- 390 px 等效 iOS 實機、Windows/macOS 桌面 resize 與真實日文 IME；
- VoiceOver／Narrator 完整朗讀順序及全鍵盤巡覽；
- 系統 200%／High Contrast／Dark Mode／Reduce Motion；
- TTS、錄音、焦點可視性與輸入法組字期間快捷鍵行為；
- release/profile 的冷啟動 P50/P95/max 與真實 SQLite UI 首結果 P50/P95/max。

因此本文件提升的是可重現的自動化覆蓋率，不將 AC-08／AC-09 或效能 gate
誤標為實機已驗收。
