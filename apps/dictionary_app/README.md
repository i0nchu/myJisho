# myJisho dictionary client

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
- `DictionaryUpdateService` fetches the four-file complete-package contract
  over HTTPS, streams `dictionary.sqlite` directly to app-owned same-volume
  staging, and reports byte progress with cooperative cancellation. It rejects
  an incompatible or oversized manifest before downloading, then verifies the
  exact size, SHA-256, `assets-manifest.json`, `checksums.txt`, SQLite
  application/schema/content versions, required tables and foreign keys.
  Drift is quiesced before atomic replacement and reopened before the backup is
  committed; a transaction marker and exclusive update lock recover interrupted
  replacement before the first SQLite open. Commit waits for a newly constructed
  Drift repository to execute a real readiness query; download, disk-full,
  validation, replace, reopen, or query failure preserves and verifies the
  previous database.

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
versioned worker are added to `web/`. Native iOS, Windows, and macOS use the
bundled SQLite path and are the only platforms on which the update UI is
enabled.

## Complete-package remote updates

Configure the trusted release directory at build time; it is not editable by
end users:

```powershell
flutter run -d windows `
  --dart-define=MYJISHO_DICTIONARY_BASE_URL=https://updates.example/releases/stable/
```

That directory must serve direct `200` responses (redirects are refused) for:

```text
release-manifest.json
assets-manifest.json
checksums.txt
dictionary.sqlite
```

Non-loopback sources require HTTPS. Plain HTTP can be enabled only explicitly
for loopback integration tests in debug code. The client accepts only
`channel: release`, `content_status: reviewed`, `license_status: cleared`,
schema-compatible packages no larger than 150 MiB. `checksums.txt` must contain
exactly one SHA-256 entry for each of `dictionary.sqlite`,
`assets-manifest.json`, and `release-manifest.json`, with no other filenames.
Each line uses the format `<64 lowercase hex characters><two spaces><filename>`.
The database digest must agree with both `checksums.txt` and the release
manifest. SHA-256 provides byte integrity, not publisher identity. The release
owner must choose the HTTPS host and decide whether to add signed manifests
before public distribution.

The local-folder path is retained in debug builds only for release engineering
and enforces the same complete-package checks. Web, Linux, Android, builds with
no endpoint, and malformed/non-HTTPS endpoints do not claim remote update
availability.

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
  user library isolation, media, responsive detail flow, and complete-package
  local/HTTP updates with fault injection.

## Validation status

Validated with Flutter 3.44.7 / Dart 3.12.2:

```text
flutter pub get     passed
flutter analyze     No issues found
flutter test        passed
```

The tests open a copied bundled SQLite file through the Drift adapter, exercise
indexed native and fixture-fallback search goldens, resolve relation IDs, and
verify complete-package contracts, cancellation/progress, interrupted transfer,
disk-full preflight, rollback/reopen, media paths, persistence and UI vertical
slices. Platform runners are committed; remaining release checks are executed
iOS/Windows/macOS CI builds and manual checks of each device's installed
Japanese TTS voice and audio output. Web remains on the documented fixture
fallback until the Wasm database worker is packaged.
