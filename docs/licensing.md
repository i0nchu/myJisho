# Data licensing, provenance, and release safety

Status: MVP policy
Owner: Security / Licensing Review

## Current inventory

No external dictionary, example corpus, image, or audio dataset is included in
the MVP. The 24 fixture entries were created specifically for Kotoba, are marked
AI-assisted drafts, and are dedicated under CC0-1.0 by
`data/fixtures/LICENSE.md`. This data dedication is separate from the repository
root license: source code currently remains under the root all-rights-reserved
notice unless another file explicitly says otherwise.

CC0 permission does not equal editorial approval. Every fixture entry and sense
remains `ai_draft`; none may be represented as reviewed, approved, or published
until a qualified human reviewer checks naturalness, correctness, learner level,
relations, examples, and provenance.

## Admission checklist

Before adding any external source, the licensing reviewer must save a source
record and evidence for:

1. Exact dataset/title, publisher/author, source ID, original URL, and retrieval date.
2. License name/SPDX identifier and the exact license-version URL or archived text.
3. Permission for redistribution, modification, and commercial use.
4. Attribution, notice, share-alike, database-right, and file-level requirements.
5. Whether definitions, example sentences, images, and audio have different terms.
6. Stable external item IDs so each imported record can be traced and removed.
7. Compatibility with offline redistribution in an application data package.

“Publicly viewable,” accessible through search, or technically downloadable is
not evidence of reuse permission. Commercial dictionary pages must not be
scraped, copied, paraphrased too closely, or used as a requested stylistic model.
Search-engine images, unattributed recordings, and material with unknown authors
must not enter imported, editorial, generated, or application directories.

Potential open datasets may be evaluated later, but none is approved merely by
being named in planning documents. Legal terms must be reviewed from the actual
upstream license before adoption, and a source-specific notice/test fixture must
be added in the same change.

## Machine-enforced provenance

Canonical source records include source type, author, license SPDX ID/URL,
original URL, retrieval date, redistribution/modification/commercial-use flags,
attribution requirement, AI-assistance flag, and notes. External records fail
validation when required evidence is absent. Entries, senses, and examples refer
to stable source IDs. Image and audio assets repeat their applicable source,
license, redistribution permission, and SHA-256 rather than inheriting text terms.

Release-blocking validation includes duplicate stable IDs, missing entry or
example sources, dangling relations, unlicensed external media, unsupported
schema, and an unreadable database. AI-assisted content can reach `approved` or
`published` only with a named human reviewer, timestamp, and aligned entry,
review, and sense statuses; merely changing the entry status remains blocked.

The release builder is fail closed: drafts, `NOASSERTION`, non-redistributable
referenced sources/media, or missing required attribution metadata prevent a
release-channel manifest. The development-only `--allow-unreviewed` flag marks
`channel: development`, plus independent `content_status` and `license_status`
fields. Production publication must contain only `approved` or `published`
entries, have `license_status: cleared`, and preserve third-party notices in the
app's data-source/license screen.

## Package integrity and update boundary

Complete-package output contains `dictionary.sqlite`, `assets-manifest.json`,
`release-manifest.json`, and `checksums.txt`. The release manifest fixes schema
version, dictionary version, minimum app version, database filename, size,
SHA-256, release time, channel, content status, and license status. Identical
canonical input uses the newest content timestamp rather than the build clock,
making development artifacts reproducible.

The verifier accepts only fixed filenames, rejects symlinks and malformed or
duplicate checksum lines, checks size, compares hashes without early-exit string
comparison, and refuses path-controlled manifest values. Hash-valid bytes must
also pass SQLite `quick_check`, application ID, schema `user_version`, required
table/canonical payload-column checks, and foreign-key validation. The client
must stage, verify, close the old DB, atomically activate the new DB, and roll
back on failure. User favorites/history live in a different database and must
never be replaced with dictionary content.

SHA-256 detects accidental or malicious alteration only when the manifest itself
is trusted; it is not publisher authentication. Remote production delivery must
use authenticated transport. A signed manifest with pinned publisher keys is a
recommended hardening item before operating an untrusted mirror or CDN.

## Incident and removal process

For a provenance or license complaint: stop the affected release, identify every
record by source ID, preserve the report and reviewed license evidence, remove or
replace affected items in canonical JSON, rebuild the complete package, update
notices, and issue a new dictionary version. Do not silently change attribution
or reuse a removed stable ID for different content.
