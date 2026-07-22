# Kotoba data model

Status: MVP contract, schema version 1
Owner: Dictionary Data

## Authority and artifacts

Version-controlled canonical UTF-8 JSON is the source of truth. The normative
machine-readable contract is `packages/dictionary_schema/schema.json` (JSON
Schema 2020-12); semantic validation is implemented in
`packages/dictionary_schema/validation.py`. SQLite, manifests, checksums, and
application assets are generated artifacts and must never become the only copy
of editorial content.

The MVP fixture is `data/fixtures/dictionary.json`. A build from identical
input is deterministic: entries and child records use stable ordering, generated
IDs derive from stable parent IDs and array positions, metadata timestamps come
from canonical content, and no wall-clock value is inserted.

## Canonical document

The top-level document contains:

- `schema_version`: integer compatibility boundary; MVP supports `1`.
- `dictionary_version`: version of the content package.
- `sources`: reusable provenance and license records.
- `entries`: complete dictionary entries.

An entry contains stable `entry_id`, headword and forms, one or more readings,
parts of speech, optional frequency rank, editorial level, editorial status,
senses, provenance, review record, creation/update times, and data version.
Exactly one form is `primary`. A reading is independent from a form because a
headword may have several readings and one reading may belong to many entries.

A sense contains stable `sense_id`, explicit display order, one simple-Japanese
definition, usage note, register, importance, examples, typed relations, media,
sources, and review state. Each primary fixture sense has at least one example.
Relations store a target stable entry ID and a learner-facing Japanese difference
note; they are validated only after the complete entry set is loaded.

No Chinese or English translation field exists in schema version 1. Unknown
canonical fields fail schema validation rather than silently drifting between
editor, builder, and client. A future compatible reader may ignore fields only
after a schema migration decision is recorded.

## Provenance and review state

Every entry and example cites a source ID. External sources additionally require
the license URL, retrieval time, redistribution/modification/commercial-use
permissions, and attribution requirement. Media records carry their own source,
license, redistribution permission, canonical `path`, and SHA-256 because
sentence, image, and audio licenses are not assumed to be the same. `path` is a
normalized relative POSIX path; absolute paths, traversal (`..`), empty segments,
NUL, and backslash escapes are rejected.

Editorial states are `imported`, `draft`, `ai_draft`, `needs_review`, `reviewed`,
`approved`, `published`, `rejected`, and `deprecated`. AI-assisted content may
be approved or published only when it has a non-empty human reviewer, review
timestamp, and entry/review/sense statuses aligned to the requested state. The
fixture intentionally remains `ai_draft` pending that independent review.

## SQLite projection

The builder produces the following normalized tables:

`entries`, `entry_forms`, `readings`, `parts_of_speech`,
`entry_parts_of_speech`, `senses`, `definitions`, `examples`, `relations`,
`images`, `audio_assets`, `search_keys`, `sources`, `entry_sources`,
`editorial_reviews`, and `metadata`.

All externally meaningful primary keys are stable text IDs. Foreign keys are
enabled and checked before an artifact replaces its destination. Search indexes
cover normalized form, reading, frequency, sense ownership, relation direction,
and precomputed search keys. Search keys are generated at build time; the app
does not normalize the complete dictionary at startup.

`entries.payload_json` stores the complete canonical entry as deterministic JSON.
This is the compatibility boundary for the Flutter Drift adapter; relational
columns and search indexes accelerate access without creating a second editorial
format. The dictionary DB is immutable at runtime and remains separate from the
user DB containing favorites, history, and settings.

## Validation and build

From the repository root:

```powershell
python -m tools.database_builder data/fixtures/dictionary.json data/generated/dictionary.sqlite --report data/generated/build-report.json
```

For the bundled development asset (the fixture is not release-approved):

```powershell
python -m tools.database_builder data/fixtures/dictionary.json assets/database/dictionary.sqlite --release-dir assets/database --allow-unreviewed
```

`--allow-unreviewed` is an explicit development-only escape hatch. Its manifest
is marked `channel: development`; `content_status` and `license_status`
independently identify unreviewed content and uncleared sources/media.
Without that flag, release artifact generation fails if any entry is not
`approved` or `published`.

The build report counts entries, forms, readings, senses, examples, media,
sources, missing sources, unreviewed entries, duplicate IDs, unparseable items,
and the database SHA-256. Validation accumulates errors so one malformed entry
does not hide other data-quality failures; a release build fails after reporting
the complete set.

Schema changes require a schema-version decision, migration tests, regenerated
golden fixtures, and coordinated canonical/Python/Dart updates. Generated output
must remain reproducible from a clean checkout.
