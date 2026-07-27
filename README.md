# Kotoba

Kotoba is a self-hosted, generative Japanese-to-Japanese dictionary for iOS,
Windows, and macOS. Its bundled dictionary remains available offline. When an
explicitly submitted query is missing, the private local service searches the
web, asks an OpenAI-compatible LLM for structured content, validates it, stores
an immutable revision in local SQLite, and returns it immediately.

Client release targets are iOS, Windows, and macOS. Android support was
explicitly removed by customer scope decision (ADR-0005). The self-hosted
server supports an Ubuntu Server 24.04 staging deployment through Docker
Compose; a repository Linux runner is not a committed Linux desktop release.

## Current release status

This repository contains a runnable **engineering MVP**. Private self-hosted
entries use `generating` / `ready` / `failed` / `stale` and do not require
review, approval, or publication. Only automatically validated content enters
the local formal-entry table. The older editorial approval state machine is
retained solely for a future public dictionary package and is not part of
private lookup or generation.

## Repository map

- `apps/dictionary_app` — Flutter client, native SQLite with a Web fixture
  fallback, on-demand local generation, Revision management, TTS, favorites,
  history, settings, and safe package updates.
- `services/local_dictionary` — private generation jobs, Wikimedia search,
  OpenAI-compatible LLM adapter, automatic validation, SQLite and HTTP API.
- `deploy` + `scripts/deploy-self-hosted.ps1` / `.sh` — token-protected Docker
  Compose deployment with Ollama, Qwen3 8B and optional Caddy HTTPS.
- `apps/content_editor` + `services/editor_api` — future public-package
  editorial workbench; it is separate from private self-hosted entries.
- `packages` — canonical schema, Japanese normalization, deinflection, and
  ranked search.
- `tools/database_builder` — deterministic SQLite/release builder, validators,
  checksums, and repeatable performance benchmarks.
- `data/fixtures` — 24 original, traceable AI-assisted draft entries.
- `assets/database` — verified development package and manifests.
- `docs` — product baseline, architecture, ADRs, licensing, search, testing,
  roadmap, and backlog.

## One-command self-hosted start

Requirements: Docker Desktop / Docker Engine with Compose v2, plus Flutter
3.44+ to run the client.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/deploy-self-hosted.ps1
powershell -ExecutionPolicy Bypass -File scripts/run-self-hosted-app.ps1
```

The deployment script creates a random API token, starts Ollama and the Kotoba
API, pulls `qwen3:8b`, and completes a health check. See
[the self-hosted generation guide](docs/self-hosted-generation.md) for manual,
remote, macOS and iOS configuration.

For an Ubuntu Server 24.04 staging server with a real iPhone or desktop client:

```bash
sudo ./scripts/install-docker-ubuntu.sh
# Log out and back in once after first-time Docker installation.
./scripts/deploy-self-hosted.sh --domain stage-kotoba.example.com
python3 scripts/stage-smoke-test.py --query 食べました
```

The complete DNS, HTTPS, firewall, device, backup, restore, update and rollback
procedure is in the
[Ubuntu staging deployment runbook](docs/ubuntu-stage-deployment.md).

## Development

Requirements: Python 3.12+ and Flutter 3.44+. A portable Flutter SDK is kept in
`.tooling/flutter` on the original development machine but is not committed.

```powershell
# All Python data/search tests
python -m unittest discover -s tests -v

# Self-hosted generation/API tests
python -m unittest discover -s services/local_dictionary/tests -t . -v

# Content editor API/security tests
python -m unittest discover -s services/editor_api/tests -v

# Start the generation API (requires an OpenAI-compatible LLM)
python -m services.local_dictionary

# Flutter client
cd apps/dictionary_app
..\..\.tooling\flutter\bin\flutter.bat pub get
..\..\.tooling\flutter\bin\flutter.bat analyze
..\..\.tooling\flutter\bin\flutter.bat test
..\..\.tooling\flutter\bin\flutter.bat run -d windows
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

This builder is for versioned public/bundled packages. Its review gates do not
apply to the separate private local-generation SQLite.

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
and the remaining production gates. Release owners use the
[traceability matrix](docs/traceability-matrix.md) and
[release runbook](docs/release-runbook.md). Dependency, license, secret and
SBOM evidence is documented in
[the supply-chain review](docs/security-supply-chain.md). The project does not
include Chinese definitions, accounts, advertising, analytics, OCR, flashcards,
or a general-purpose AI chat tutor in MVP scope.
