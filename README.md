# myJisho

![Version 0.1.1](https://img.shields.io/badge/version-0.1.1-0969da)

myJisho is a self-hosted Japanese-to-Japanese dictionary with clients for iOS,
macOS, and Windows. It combines an offline SQLite dictionary with on-demand
entry generation through an OpenAI-compatible LLM endpoint.

The system normalizes and deinflects submitted queries, searches Japanese web
sources, generates structured entries, validates their language and citations,
and saves successful results locally. It also supports revision history,
editing, regeneration, restoration, deletion, version locking, Japanese TTS,
favorites, and search history.

The current development version is `0.1.1`. The first public release will use
version `1.0.0`.

## Project structure

```text
apps/dictionary_app       Flutter client
apps/content_editor       Local content editor
services/local_dictionary Generation, validation, storage, and HTTP API
services/editor_api       Content editor API
packages                  Schema, normalization, deinflection, and search
tools/database_builder    SQLite dictionary package builder
deploy                    Docker Compose configuration
scripts                   Deployment, backup, restore, and verification
```

## Deployment

myJisho is deployed with Docker Compose. Copy `deploy/.env.example` to
`deploy/.env`, set a secure `MYJISHO_API_TOKEN`, and explicitly select
`MYJISHO_LLM_MODEL`; the model has no default.

Start myJisho together with its managed Ollama service:

```bash
docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --build
```

The selected model must be installed in Ollama before the first generated
lookup.

To reuse an existing Ollama or another OpenAI-compatible endpoint, configure
`MYJISHO_LLM_BASE_URL` and use `deploy/compose.internal.yaml` instead.
