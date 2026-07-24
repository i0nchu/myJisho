# Kotoba editor API

This is the single-administrator MVP editorial service. It uses only the Python
standard library at runtime and serves the browser UI from `apps/content_editor`.
It writes a copied working document, never the canonical source or generated
SQLite artifacts.

## Start

From the repository root with Python 3.10 or newer:

```powershell
python -m services.editor_api
```

Open <http://127.0.0.1:8765>. On first start the server copies
`data/fixtures/dictionary.json` when that fixture exists. Otherwise it creates a
valid empty working document. Runtime files live under
`services/editor_api/.working/` and are ignored by Git.

To use another canonical document or isolate the working copy:

```powershell
python -m services.editor_api --source C:\path\canonical.json --working-dir C:\path\kotoba-editor-work
```

`--source` is only read when that working directory has no existing
`dictionary.working.json`. A source must pass both
`packages/dictionary_schema/schema.json` and semantic validation before the
copy is created.

This MVP has no account system and is deliberately local-only. The server accepts
only `localhost` or an IP loopback address for `--host`; wildcard, LAN, public,
and arbitrary hostname binds are rejected. It is not a remotely deployable
service. Add authentication and TLS in a separate trusted service before any
future remote-access design.

## API

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/api/health` | Liveness check |
| `GET` | `/api/schema` | Canonical schema and workflow transitions |
| `GET` | `/api/entries?q=...` | Search up to 100 entries by ID, form, headword, or reading |
| `GET` | `/api/sources?q=...` | Search editor-safe source titles, authors, types, and license summaries |
| `GET` | `/api/entries/{entry_id}` | Entry, global revision, and allowed transitions |
| `POST` | `/api/entries/{entry_id}/validate` | Validate a proposed `{ "entry": ... }` in full-document context |
| `PUT` | `/api/entries/{entry_id}` | Validate and atomically save `{ "entry": ..., "base_revision": ... }` |
| `POST` | `/api/entries/{entry_id}/transition` | Apply `{ "status", "reviewer", "notes", "base_revision" }` |

A save uses an SHA-256 revision for optimistic concurrency. A stale save returns
HTTP 409. Schema failures return HTTP 422 with stable `path`, `code`, `message`,
and `severity` fields.

Normal editor saves submit the complete entry snapshot. Before validation, the
server restores system-owned entry metadata and review state, assigns globally
unique IDs to new senses/examples/assets, derives sense order from the submitted
array, and sets `updated_at`. Rewriting an existing child ID is rejected. Review
transitions continue to use the dedicated transition endpoint.

## Workflow and safety

Allowed transitions are explicit in `workflow.py`. An `ai_draft` can only move
to `needs_review` or `rejected`; review must then pass through `reviewed` before
`approved`, and only `approved` can become `published`. Human reviewer identity
and time are mandatory at signed-off states. Changing reviewed, approved, or
published content without first returning it to review is rejected.

HTTP input never selects a file path. Static assets are served from an explicit
allowlist. Every request must use the bound loopback IP (or `localhost` for the
standard loopback) and exact listening port in `Host`, which blocks DNS-rebinding
authorities. Browser `POST` and `PUT` requests must have a same-origin `Origin`
when present and `Sec-Fetch-Site: same-origin` when Fetch Metadata is present.
Both headers may be absent for local CLI clients.

The fixed working copy is confined to its configured directory and symlink
targets are rejected. Each save writes and `fsync`s a `prepared` audit record,
then writes a same-directory `fsync`ed temporary file and atomically replaces the
working copy, then writes and `fsync`s the matching `committed` audit record. An
audit preflight failure cannot change the working copy. A failure after atomic
replacement still leaves the durable prepared record and intended revision for
recovery. Request bodies are capped at 2 MiB.

## Test

```powershell
python -m unittest discover -s services/editor_api/tests -v
```

The tests cover structural and semantic schema errors, nested media metadata,
persisted human-review state alignment, illegal transition jumps, signed-off
edit protection, canonical source immutability, revision conflicts, prepared and
committed audit ordering, audit/directory/permission failures, API round-trips,
non-loopback bind rejection, DNS-rebinding Host probes, cross-origin mutation
probes, and path traversal.
