# Kotoba complete-package remote update contract

Status: implemented for the iOS, Windows, and macOS native clients.

## Trusted endpoint

The app receives one build-time directory URL through
`KOTOBA_DICTIONARY_BASE_URL`. The value must be an absolute HTTPS URL ending in
`/`, without credentials, query, or fragment. Redirects are rejected so a
remote response cannot silently change origin or downgrade transport. Debug
integration tests may explicitly permit plain HTTP only for a loopback host.

The selected host must serve direct `200` responses for four fixed sibling
paths:

```text
release-manifest.json
assets-manifest.json
checksums.txt
dictionary.sqlite
```

Remote values never select a local path. `database_file` must be exactly
`dictionary.sqlite`. Metadata files are limited to 512 KiB and the database is
limited to 150 MiB.

## Metadata contract

`release-manifest.json` has exactly these fields:

```json
{
  "channel": "release",
  "content_status": "reviewed",
  "database_file": "dictionary.sqlite",
  "schema_version": 1,
  "dictionary_version": "2026.08.0",
  "minimum_app_version": "0.1.0",
  "database_size": 123456,
  "database_sha256": "<64 lowercase hex>",
  "released_at": "2026-08-01T00:00:00Z",
  "license_status": "cleared"
}
```

Production installation requires `release`, `reviewed`, and `cleared`. Versions
use the project's SemVer-compatible comparison. An incompatible schema,
unsupported minimum app version, non-newer dictionary, invalid filename, or
oversized package is rejected before the database request.

`assets-manifest.json` has exactly `schema_version`, `dictionary_version`,
`released_at`, and `assets`. Its version and release time must agree with the
release manifest. Every asset item has exactly `asset_id`, `kind`, `path`,
`sha256`, `source_id`, and `license_spdx`; IDs and paths are unique, paths are
normalized relative POSIX paths without traversal, and hashes are lowercase
SHA-256. Media binaries remain the separately downloaded P1 capability from the
product specification; the MVP complete database release nevertheless
authenticates and validates the asset metadata contract.

`checksums.txt` uses `<sha256><two spaces><filename><LF>` and contains each of
these entries exactly once:

```text
dictionary.sqlite
assets-manifest.json
release-manifest.json
```

The manifest files are hashed as received, without JSON reserialization. The
database checksum must match `database_sha256`.

## Transaction and failure invariants

1. Fetch and validate all metadata.
2. Compare release, schema, app, and size constraints.
3. Check available capacity when a platform probe is available.
4. Stream the database to a fixed same-volume `.staged` path while computing
   SHA-256 and emitting byte progress. Cancellation closes the HTTP client and
   removes staging.
5. Require the actual byte count and digest to match the metadata.
6. Open staged SQLite read-only; require `quick_check`, application ID,
   `user_version`, all canonical tables and payload columns, no foreign-key
   errors, and a dictionary version matching the manifest.
7. Under an exclusive update lock, close the current repository, write and
   flush a transaction marker, rename the active database to backup, and rename
   staging into the active path.
8. Construct a new Drift repository and await a real `SELECT ... LIMIT 1`
   readiness query. Delete the marker and backup only after that query succeeds.
   Any replace, reopen, or query error first closes the failed repository, then
   restores the backup and awaits the same readiness query against the old DB.
9. On every process start, the native database-path bootstrap acquires the
   update lock and resolves a transaction marker before the first SQLite open.
   This recovery is one-shot for the process; staging never moves an active file
   merely because it encounters a stale marker after SQLite is already open.

An OS disk-full error is classified even if free-space probing is unavailable.
At no point does the updater open or mutate the separate favorites/history
store.

Fault-injection coverage lives in
`apps/dictionary_app/test/remote_dictionary_update_test.dart` and
`dictionary_update_production_path_test.dart`: interrupted HTTP, cancellation,
insufficient capacity, wrong size/hash, tampered metadata, release-assets-to-
SQLite cross-binding, incompatible manifest, unhealthy/version-mismatched
SQLite, startup recovery, real Drift reopen/query rollback, explicit HTTP
handle disposal, and successful end-to-end activation.

## Release decisions still external

- Select and operate the HTTPS package host/CDN, retention policy, and rollback
  mechanism.
- Decide whether public distribution requires a signed manifest and key
  rotation. HTTPS plus SHA-256 does not prove publisher identity if the host is
  compromised.
- Provide final iOS, Windows, and macOS build-time endpoint values and execute
  platform CI/real-device fault smoke tests.
