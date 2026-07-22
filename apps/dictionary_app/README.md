# Kotoba dictionary client

Flutter MVP for the offline-first Japanese-to-Japanese dictionary. The UI is
Japanese-only and supports phone navigation plus a desktop search/detail split.

## Runtime architecture

- Riverpod owns searchable/testable state; `go_router` owns `/` and
  `/entry/:entryId` navigation.
- The native runtime opens the bundled `assets/database/dictionary.sqlite`
  through `DriftDictionaryRepository`. A JSON fixture is an explicit recovery
  fallback and is the Web prototype data source.
- Dictionary data and user data have separate repository contracts. Favorites
  and history use `SharedPreferences`, so replacing the dictionary package
  cannot erase them. Theme, text scale, and shortcut preferences are persistent.
- `FlutterTtsSpeechService` selects `ja-JP` system TTS and labels it as
  `合成音声`. `AudioPlayersPlaybackService` handles separately licensed asset or
  data-URI audio. Widgets never call a plugin, SQL, or file API directly.
- `DictionaryUpdateService` validates schema/app compatibility, byte size and
  SHA-256 before health-checking a staged database. The settings UI exposes this
  only as a local-folder sideload prototype: it accepts exactly a
  `release`/`reviewed` manifest and `dictionary.sqlite`. Drift is quiesced before
  replacement and reopened before the backup is committed; an update marker
  restores an interrupted replacement on the next sideload attempt.

`DictionaryEntry.fromJson` treats the canonical snake_case model as its primary
contract (`entry_id`, structured forms/readings, `parts_of_speech`, canonical
senses/examples/sources/review). It also accepts the compact bundled fixture so
UI tests remain easy to read.

## Flutter SDK setup

With Flutter 3.44+ / Dart 3.12+ installed:

```powershell
cd apps/dictionary_app
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

Current dependency support sets the practical app floor to iOS 13, macOS 10.15
and Windows 10. Android is intentionally not a supported target.

## Adapter hand-off

Native search expands deterministic normalized, kana, romaji and deinflection
candidates, then uses bounded index-range queries over SQLite `search_keys`.
Direct entry and favorite lookup use `entry_id` queries instead of decoding the
whole dictionary. The repository remains injectable for a generated, fully
typed Drift database in the next milestone.

The Web build intentionally uses the JSON fixture until `sqlite3.wasm` and a
versioned worker are added to `web/`. Native iOS, Windows, and macOS use
the bundled SQLite path.

There is no remote update client in this MVP. The sideload prototype validates
the manifest and dictionary database only; it does not yet validate a complete
`checksums.txt`, an assets manifest, or a media package. Those checks are release
blockers before the UI may be presented as a general data updater.

## Implemented acceptance coverage

- debounced IME-safe search, deterministic ordering, inflection hints, loading,
  error, and empty states;
- priority definition/examples and collapsed secondary information;
- image and audio fields, synthetic TTS, favorites, history, dark mode and text
  scale;
- `/`, Ctrl/Cmd+L, arrows, Enter, Esc, Ctrl/Cmd+D and Space shortcuts with an
  option to disable them;
- phone navigation and the desktop search/detail layout;
- unit and widget tests for canonical parsing, sorting, kana/romaji/inflection,
  user library isolation, media, responsive detail flow and package updates.

## Validation status

Validated with Flutter 3.44.7 / Dart 3.12.2:

```text
flutter pub get     passed
flutter analyze     No issues found
flutter test        25/25 passed
```

The tests open a copied bundled SQLite file through the Drift adapter, exercise
indexed native and fixture-fallback search goldens, resolve relation IDs, and
verify sideload release gates, rollback/reopen, media paths, persistence and UI
vertical slices. Platform runners are committed; remaining release checks are
executed iOS/Windows/macOS CI builds and manual checks of each device's
installed Japanese TTS voice and audio output. Web remains on the documented
fixture fallback until the Wasm database worker is packaged.
