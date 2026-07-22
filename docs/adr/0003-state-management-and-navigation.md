# ADR-0003：Riverpod 狀態管理與 go_router 導航

- 狀態：Accepted
- 日期：2026-07-22

## Context

App 需支援手機單頁 navigation、桌面雙欄 selection、非同步搜尋取消、更新狀態、持久設定與可注入 repository。重要狀態必須能在不啟動真實平台服務下測試。

## Decision

採 Riverpod 管理依賴注入、feature controller 與 immutable view state；採 go_router 管理 route／deep-link 可表達狀態。Navigator/page layout 僅負責呈現，搜尋／收藏／更新流程由 application controller 驅動。

搜尋 controller 使用 query identity/cancellation，禁止較舊 response 覆蓋新 query。IME composing gate 位於 presentation boundary；debounce 位於 controller/application boundary。手機與桌面共享 route/domain state，但以 adaptive shell 呈現單欄或雙欄。快捷鍵透過統一 intents/actions，並尊重設定與文字欄焦點。

套件版本在 platform spike 後鎖定；若維護狀態或平台相容性不符合 gate，需另立 superseding ADR。

## Consequences

好處是狀態／依賴可替換、async 狀態有一致生命週期且 route 可測。代價是團隊需遵守 provider ownership，避免全域 provider 膨脹；go_router 與 adaptive layout 的 back/selection semantics 需明確 widget tests。

## Rejected alternatives

- setState／Navigator 分散於 Widget：跨頁 async 與 repository 測試性不足。
- BLoC：可行，但對本專案以 repository injection + fine-grained feature state 而言樣板較多。
- 自製 router/state framework：維護與平台 edge case 成本不合理。

## Verification

以 fake repository 測 search/favorite/update controllers；Widget tests 覆蓋 mobile/desktop route、deep link/back、stale search、IME、快捷鍵與設定停用；Widget tree 不含 raw SQL 呼叫。
