# myJisho

![Version 0.1.1](https://img.shields.io/badge/version-0.1.1-0969da)

myJisho is a self-hosted, Japanese-to-Japanese dictionary for iOS, macOS, and
Windows. It works from a bundled offline dictionary and can generate missing
entries through a private local service.

The current development version is `0.1.1`. The first public release will use
version `1.0.0`.

When a submitted query is not in the local database, myJisho normalizes and
deinflects the input, searches Japanese web sources, asks an OpenAI-compatible
LLM for a structured entry, validates the result, and saves it as an immutable
SQLite revision. Repeated queries reuse the local entry.

> This repository is an engineering MVP. Android and Linux desktop clients are
> not supported release targets. The self-hosted service runs through Docker
> Compose on mainstream Linux distributions.

## Client platforms

![iOS supported](https://img.shields.io/badge/iOS-supported-2ea44f?logo=apple&logoColor=white)
![macOS supported](https://img.shields.io/badge/macOS-supported-2ea44f?logo=apple&logoColor=white)
![Windows supported](https://img.shields.io/badge/Windows-supported-2ea44f?logo=windows11&logoColor=white)
![Android not supported](https://img.shields.io/badge/Android-not_supported-6e7781?logo=android&logoColor=white)

iOS, macOS, and Windows are native client release targets. Android is not
maintained.

## Highlights

- Offline-first lookup with kana, romaji, and inflection-aware search
- On-demand generation only after an explicit query submission
- Automatic schema, language, source, example, and duplicate validation
- Revision history, restore, edit, regenerate, delete, and version locking
- Japanese TTS, favorites, history, keyboard navigation, and accessible layouts
- Token-protected self-hosting with backup and restore scripts

## Repository

```text
apps/dictionary_app       Flutter client
apps/content_editor       Optional local content editor
services/local_dictionary Generation, validation, storage, and HTTP API
services/editor_api       Content editor API
packages                  Schema, normalization, deinflection, and search
tools/database_builder    Deterministic SQLite package builder
deploy                    Docker Compose configuration
scripts                   Deployment, backup, restore, and verification
```

## Linux self-hosting

Requirements:

- A mainstream Linux distribution with Docker Engine and Compose v2
- Git, curl, OpenSSL, and Python 3.10 or newer
- Ollama reachable at `http://127.0.0.1:11434`

If Ollama already runs through Docker Compose, publish its API only on host
loopback:

```yaml
ports:
  - "127.0.0.1:11434:11434"
```

Deploy myJisho:

```bash
git clone git@github.com:i0nchu/myJisho.git
cd myJisho

./scripts/deploy-self-hosted.sh --model your-model-name
python3 scripts/stage-smoke-test.py --query 食べました
```

The deployment script:

- requires an explicit model name and reuses the existing Ollama API;
- pulls the selected model through the Ollama API if it is not installed;
- generates a private API token in `deploy/.env`;
- starts only the myJisho API;
- binds it to `127.0.0.1:8766` by default;
- stores dictionary data in the `myjisho-data` Docker volume.

Useful options:

```bash
./scripts/deploy-self-hosted.sh --model your-model-name
./scripts/deploy-self-hosted.sh --model your-model-name --skip-model-pull
./scripts/deploy-self-hosted.sh --model your-model-name --tailscale
```

myJisho calls an OpenAI-compatible chat-completions API and is not coupled to
one model. `MYJISHO_LLM_MODEL` has no default and must contain a model exposed
by that endpoint. Startup fails immediately when the value is missing or blank.
The included deployment scripts use Ollama as the managed local endpoint; the
service itself can also connect to another OpenAI-compatible endpoint through
`MYJISHO_LLM_BASE_URL` and, when required, `MYJISHO_LLM_API_KEY`.

`--tailscale` binds directly to the server's Tailscale IPv4 for private device
testing. For Cloudflare Tunnel, keep the default loopback listener and route the
tunnel to `http://127.0.0.1:8766`; add the public hostname to
`MYJISHO_ALLOWED_HOSTS` in `deploy/.env` before restarting the API. Do not expose
port 8766 directly to the public Internet.

Back up and restore the local dictionary:

```bash
./scripts/backup-self-hosted.sh
./scripts/restore-self-hosted.sh myjisho-stage-YYYYMMDDTHHMMSSZ.tar.gz
```

## Run the client

Install Flutter 3.44 or newer, then:

```bash
cd apps/dictionary_app
flutter pub get
flutter run -d windows
```

To connect a client to the self-hosted API:

```bash
flutter run -d windows \
  --dart-define=MYJISHO_LOCAL_API=http://127.0.0.1:8766 \
  --dart-define=MYJISHO_LOCAL_API_TOKEN=<value-from-deploy/.env>
```

Replace the URL with the server's Tailscale address when testing from another
device. Never commit the API token.

On Windows, a local Docker deployment that includes Ollama can be started with:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/deploy-self-hosted.ps1 `
  -Model your-model-name
powershell -ExecutionPolicy Bypass -File scripts/run-self-hosted-app.ps1
```

## Development

Requirements: Python 3.10+ and Flutter 3.44+. Python 3.11 or newer is
recommended for new development and deployments. CI verifies the Python 3.10
compatibility floor separately from the current development runtime.

```bash
python -m unittest discover -s tests -v
python -m unittest discover -s services/local_dictionary/tests -t . -v
python -m unittest discover -s services/editor_api/tests -v

cd apps/dictionary_app
flutter pub get
flutter analyze
flutter test
```

Run every local quality gate on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verify.ps1
```

Build the sample dictionary package into the ignored `build/` directory:

```bash
python -m tools.database_builder \
  data/fixtures/dictionary.json \
  build/dictionary-release/dictionary.sqlite \
  --report build/dictionary-release/build-report.json \
  --release-dir build/dictionary-release \
  --allow-unreviewed
```

## License

The source code is available for MVP evaluation under [LICENSE](LICENSE).
Original fixture data under `data/fixtures` is separately available under
[CC0-1.0](data/fixtures/LICENSE.md). Third-party dependencies and imported data
remain subject to their respective licenses.
