# Kotoba

Kotoba is an offline-first, ad-free Japanese-to-Japanese dictionary MVP for
iOS, Windows, and macOS. It prioritizes the most useful meaning,
simple Japanese definitions, examples, pronunciation, and clear distinctions
between similar words.

## Current release status

This repository contains a runnable **engineering MVP / development package**.
Its 24 original fixture entries are intentionally marked `ai_draft` and the
App labels them `レビュー前のデモ内容`. They may be used for development and
customer review, but the release builder blocks a production package until a
qualified human reviewer supplies review evidence and approves the content.

## Repository map

- `apps/dictionary_app` — Flutter client, native SQLite with a Web fixture
  fallback, TTS, favorites, history, settings, and safe package updates.
- `apps/content_editor` + `services/editor_api` — local editorial workbench and
  guarded working-copy API.
- `packages` — canonical schema, Japanese normalization, deinflection, and
  ranked search.
- `tools/database_builder` — deterministic SQLite/release builder, validators,
  checksums, and repeatable performance benchmarks.
- `data/fixtures` — 24 original, traceable AI-assisted draft entries.
- `assets/database` — verified development package and manifests.
- `docs` — product baseline, architecture, ADRs, licensing, search, testing,
  roadmap, and backlog.

## Quick start

Requirements: Python 3.12+ and Flutter 3.44+. A portable Flutter SDK is kept in
`.tooling/flutter` on the original development machine but is not committed.

```powershell
# All Python data/search tests
python -m unittest discover -s tests -v

# Content editor API/security tests
python -m unittest discover -s services/editor_api/tests -v

# Start the local content editor
python -m services.editor_api
# Open http://127.0.0.1:8765

# Flutter client
cd apps/dictionary_app
..\..\.tooling\flutter\bin\flutter.bat pub get
..\..\.tooling\flutter\bin\flutter.bat analyze
..\..\.tooling\flutter\bin\flutter.bat test
..\..\.tooling\flutter\bin\flutter.bat run -d chrome
```

Rebuild the development dictionary package from canonical data:

```powershell
python -m tools.database_builder `
  data/fixtures/dictionary.json `
  assets/database/dictionary.sqlite `
  --report assets/database/build-report.json `
  --release-dir assets/database `
  --allow-unreviewed
```

`--allow-unreviewed` always marks the manifest as
`development/contains_unreviewed`; the App updater refuses that manifest. Omit
the flag for a production release. Draft content then causes a hard failure.

## One-command local verification

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verify.ps1
```

The script runs Python tests, editor tests, Flutter formatting, analysis,
Widget/unit tests, and a Web release build. GitHub Actions additionally defines
Windows, macOS, and iOS simulator build gates. A CI build is not an
equivalent substitute for physical-device TTS, audio, IME, accessibility, and
offline smoke tests.

## Product and governance

Start with [the MVP product baseline](docs/product-spec.md),
[architecture](docs/architecture.md), [roadmap](docs/roadmap.md), and
[release testing strategy](docs/testing-strategy.md). The current
[MVP customer review report](docs/mvp-review-report.md) records passed checks
and the remaining production gates. The project does not
include Chinese definitions, accounts, advertising, analytics, OCR, flashcards,
or AI tutoring in MVP scope.
