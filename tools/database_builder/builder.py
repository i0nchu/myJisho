"""Canonical JSON to deterministic SQLite builder."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
from typing import Any

from packages.dictionary_schema import (
    assert_valid_dictionary,
    is_safe_asset_path,
    license_clearance_issues,
    sha256_file,
    validate_dictionary,
)
from packages.japanese_normalizer import normalize_kana, normalize_text


SCHEMA_SQL = """
PRAGMA application_id = 1263489602;
PRAGMA user_version = 1;
PRAGMA page_size = 4096;
PRAGMA journal_mode = DELETE;
PRAGMA synchronous = FULL;
PRAGMA foreign_keys = ON;

CREATE TABLE entries (
    entry_id TEXT PRIMARY KEY,
    headword TEXT NOT NULL,
    frequency_rank INTEGER,
    payload_json TEXT NOT NULL,
    editorial_level TEXT NOT NULL,
    edit_status TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    data_version TEXT NOT NULL
) WITHOUT ROWID;
CREATE INDEX idx_entries_frequency_rank ON entries(frequency_rank);

CREATE TABLE entry_forms (
    form_id TEXT PRIMARY KEY,
    entry_id TEXT NOT NULL REFERENCES entries(entry_id),
    text TEXT NOT NULL,
    normalized_text TEXT NOT NULL,
    form_type TEXT NOT NULL,
    is_common INTEGER NOT NULL CHECK (is_common IN (0, 1))
) WITHOUT ROWID;
CREATE INDEX idx_entry_forms_normalized_text ON entry_forms(normalized_text);

CREATE TABLE readings (
    reading_id TEXT PRIMARY KEY,
    entry_id TEXT NOT NULL REFERENCES entries(entry_id),
    kana TEXT NOT NULL,
    normalized_kana TEXT NOT NULL,
    is_primary INTEGER NOT NULL CHECK (is_primary IN (0, 1))
) WITHOUT ROWID;
CREATE INDEX idx_readings_normalized_kana ON readings(normalized_kana);
CREATE INDEX idx_readings_entry_id ON readings(entry_id, is_primary, reading_id);

CREATE TABLE parts_of_speech (
    pos_code TEXT PRIMARY KEY
) WITHOUT ROWID;
CREATE TABLE entry_parts_of_speech (
    entry_id TEXT NOT NULL REFERENCES entries(entry_id),
    pos_code TEXT NOT NULL REFERENCES parts_of_speech(pos_code),
    sort_order INTEGER NOT NULL,
    PRIMARY KEY (entry_id, pos_code)
) WITHOUT ROWID;

CREATE TABLE senses (
    sense_id TEXT PRIMARY KEY,
    entry_id TEXT NOT NULL REFERENCES entries(entry_id),
    sort_order INTEGER NOT NULL,
    usage_note_ja TEXT NOT NULL,
    register_name TEXT NOT NULL,
    importance TEXT NOT NULL,
    review_status TEXT NOT NULL
) WITHOUT ROWID;
CREATE INDEX idx_senses_entry_id ON senses(entry_id, sort_order);

CREATE TABLE definitions (
    definition_id TEXT PRIMARY KEY,
    sense_id TEXT NOT NULL REFERENCES senses(sense_id),
    language TEXT NOT NULL,
    definition_text TEXT NOT NULL
) WITHOUT ROWID;
CREATE INDEX idx_definitions_sense_id ON definitions(sense_id, language);

CREATE TABLE examples (
    example_id TEXT PRIMARY KEY,
    sense_id TEXT NOT NULL REFERENCES senses(sense_id),
    sentence TEXT NOT NULL,
    source_id TEXT NOT NULL,
    audio_asset_id TEXT
) WITHOUT ROWID;
CREATE INDEX idx_examples_sense_id ON examples(sense_id);

CREATE TABLE relations (
    relation_id TEXT PRIMARY KEY,
    source_entry_id TEXT NOT NULL REFERENCES entries(entry_id),
    source_sense_id TEXT NOT NULL REFERENCES senses(sense_id),
    target_entry_id TEXT NOT NULL REFERENCES entries(entry_id) DEFERRABLE INITIALLY DEFERRED,
    relation_type TEXT NOT NULL,
    note_ja TEXT NOT NULL
) WITHOUT ROWID;
CREATE INDEX idx_relations_source ON relations(source_entry_id);
CREATE INDEX idx_relations_target ON relations(target_entry_id);

CREATE TABLE images (
    asset_id TEXT PRIMARY KEY,
    sense_id TEXT NOT NULL REFERENCES senses(sense_id),
    source_id TEXT NOT NULL,
    license_spdx TEXT NOT NULL,
    redistribution_allowed INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    local_path TEXT
) WITHOUT ROWID;

CREATE TABLE audio_assets (
    asset_id TEXT PRIMARY KEY,
    sense_id TEXT NOT NULL REFERENCES senses(sense_id),
    source_id TEXT NOT NULL,
    audio_type TEXT NOT NULL,
    license_spdx TEXT NOT NULL,
    redistribution_allowed INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    local_path TEXT
) WITHOUT ROWID;

CREATE TABLE sources (
    source_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    source_type TEXT NOT NULL,
    author TEXT NOT NULL,
    license_spdx TEXT NOT NULL,
    license_url TEXT,
    original_url TEXT,
    retrieved_at TEXT,
    redistribution_allowed INTEGER,
    modification_allowed INTEGER,
    commercial_use_allowed INTEGER,
    attribution_required INTEGER,
    ai_assisted INTEGER NOT NULL,
    notes TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE entry_sources (
    entry_id TEXT NOT NULL REFERENCES entries(entry_id),
    source_id TEXT NOT NULL REFERENCES sources(source_id),
    PRIMARY KEY (entry_id, source_id)
) WITHOUT ROWID;

CREATE TABLE editorial_reviews (
    entry_id TEXT PRIMARY KEY REFERENCES entries(entry_id),
    status TEXT NOT NULL,
    reviewed_by TEXT,
    reviewed_at TEXT,
    notes TEXT NOT NULL
) WITHOUT ROWID;

CREATE TABLE search_keys (
    search_key_id TEXT PRIMARY KEY,
    entry_id TEXT NOT NULL REFERENCES entries(entry_id),
    search_key TEXT NOT NULL,
    search_key_prefix TEXT NOT NULL,
    display_key TEXT NOT NULL,
    key_type TEXT NOT NULL,
    is_common INTEGER NOT NULL
) WITHOUT ROWID;
CREATE INDEX idx_search_keys_key ON search_keys(search_key, key_type);
CREATE INDEX idx_search_keys_prefix ON search_keys(search_key_prefix, key_type);

CREATE TABLE metadata (
    metadata_key TEXT PRIMARY KEY,
    metadata_value TEXT NOT NULL
) WITHOUT ROWID;
"""


@dataclass(frozen=True)
class BuildReport:
    entries: int = 0
    forms: int = 0
    readings: int = 0
    senses: int = 0
    examples: int = 0
    images: int = 0
    audio: int = 0
    sources: int = 0
    missing_sources: int = 0
    unreviewed_entries: int = 0
    duplicate_ids: int = 0
    unparseable_items: int = 0
    database_sha256: str = ""


def load_canonical(path: str | Path) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as handle:
        document = json.load(handle)
    assert_valid_dictionary(document)
    return document


def _bool(value: Any) -> int | None:
    return None if value is None else int(bool(value))


def _add_search_key(
    connection: sqlite3.Connection,
    *,
    key_id: str,
    entry_id: str,
    display_key: str,
    key_type: str,
    common: bool,
    kana: bool = False,
) -> None:
    key = normalize_kana(display_key) if kana else normalize_text(display_key)
    connection.execute(
        "INSERT INTO search_keys VALUES (?, ?, ?, ?, ?, ?, ?)",
        (key_id, entry_id, key, key, display_key, key_type, int(common)),
    )


def build_database(document: dict[str, Any], output_path: str | Path) -> BuildReport:
    """Validate *document* and atomically replace *output_path* on success."""

    assert_valid_dictionary(document)
    output = Path(output_path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".building")
    if temporary.exists():
        temporary.unlink()

    counts = {
        "entries": 0,
        "forms": 0,
        "readings": 0,
        "senses": 0,
        "examples": 0,
        "images": 0,
        "audio": 0,
        "sources": 0,
        "missing_sources": 0,
        "unreviewed_entries": 0,
        "duplicate_ids": 0,
        "unparseable_items": 0,
    }
    try:
        connection = sqlite3.connect(temporary)
        connection.executescript(SCHEMA_SQL)
        with connection:
            for source in sorted(document["sources"], key=lambda item: item["source_id"]):
                connection.execute(
                    "INSERT INTO sources VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        source["source_id"], source["title"], source["source_type"], source["author"],
                        source["license_spdx"], source.get("license_url"), source.get("original_url"),
                        source.get("retrieved_at"), _bool(source.get("redistribution_allowed")),
                        _bool(source.get("modification_allowed")), _bool(source.get("commercial_use_allowed")),
                        _bool(source.get("attribution_required")), _bool(source["ai_assisted"]), source.get("notes", ""),
                    ),
                )
                counts["sources"] += 1

            all_parts = sorted({part for entry in document["entries"] for part in entry["parts_of_speech"]})
            connection.executemany("INSERT INTO parts_of_speech VALUES (?)", ((part,) for part in all_parts))

            for entry in sorted(document["entries"], key=lambda item: item["entry_id"]):
                entry_id = entry["entry_id"]
                connection.execute(
                    "INSERT INTO entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (entry_id, entry["headword"], entry.get("frequency_rank"),
                     json.dumps(entry, ensure_ascii=False, sort_keys=True, separators=(",", ":")), entry["editorial_level"],
                     entry["edit_status"], entry["created_at"], entry["updated_at"], entry["data_version"]),
                )
                counts["entries"] += 1
                if entry["edit_status"] not in {"reviewed", "approved", "published"}:
                    counts["unreviewed_entries"] += 1

                seen_entry_keys: set[tuple[str, str]] = set()
                for index, form in enumerate(entry["forms"], 1):
                    form_id = f"{entry_id}:form:{index:03d}"
                    normalized = normalize_text(form["text"])
                    connection.execute(
                        "INSERT INTO entry_forms VALUES (?, ?, ?, ?, ?, ?)",
                        (form_id, entry_id, form["text"], normalized, form["type"], int(form["common"])),
                    )
                    counts["forms"] += 1
                    key_type = "primary" if form["type"] == "primary" else ("reading" if form["type"] == "kana" else "alternate")
                    dedupe = (normalized, key_type)
                    if dedupe not in seen_entry_keys:
                        _add_search_key(connection, key_id=f"{entry_id}:key:form:{index:03d}", entry_id=entry_id,
                                        display_key=form["text"], key_type=key_type, common=form["common"], kana=key_type == "reading")
                        seen_entry_keys.add(dedupe)

                for index, reading in enumerate(entry["readings"], 1):
                    reading_id = f"{entry_id}:reading:{index:03d}"
                    normalized = normalize_kana(reading["kana"])
                    connection.execute(
                        "INSERT INTO readings VALUES (?, ?, ?, ?, ?)",
                        (reading_id, entry_id, reading["kana"], normalized, int(reading["primary"])),
                    )
                    counts["readings"] += 1
                    dedupe = (normalized, "reading")
                    if dedupe not in seen_entry_keys:
                        _add_search_key(connection, key_id=f"{entry_id}:key:reading:{index:03d}", entry_id=entry_id,
                                        display_key=reading["kana"], key_type="reading", common=reading["primary"], kana=True)
                        seen_entry_keys.add(dedupe)

                for order, pos in enumerate(entry["parts_of_speech"], 1):
                    connection.execute("INSERT INTO entry_parts_of_speech VALUES (?, ?, ?)", (entry_id, pos, order))

                for source_id in sorted(entry["source_ids"]):
                    connection.execute("INSERT INTO entry_sources VALUES (?, ?)", (entry_id, source_id))

                review = entry["review"]
                connection.execute(
                    "INSERT INTO editorial_reviews VALUES (?, ?, ?, ?, ?)",
                    (entry_id, review["status"], review.get("reviewed_by"), review.get("reviewed_at"), review.get("notes", "")),
                )

                for sense in sorted(entry["senses"], key=lambda item: (item["order"], item["sense_id"])):
                    sense_id = sense["sense_id"]
                    connection.execute(
                        "INSERT INTO senses VALUES (?, ?, ?, ?, ?, ?, ?)",
                        (sense_id, entry_id, sense["order"], sense["usage_note_ja"], sense["register"], sense["importance"], sense["review_status"]),
                    )
                    connection.execute(
                        "INSERT INTO definitions VALUES (?, ?, 'ja-simple', ?)",
                        (sense_id + ":definition:ja-simple", sense_id, sense["definition_ja_simple"]),
                    )
                    counts["senses"] += 1
                    for example in sorted(sense["examples"], key=lambda item: item["example_id"]):
                        connection.execute(
                            "INSERT INTO examples VALUES (?, ?, ?, ?, ?)",
                            (example["example_id"], sense_id, example["sentence"], example["source_id"], example.get("audio_asset_id")),
                        )
                        counts["examples"] += 1
                    for index, relation in enumerate(sense["relations"], 1):
                        relation_id = f"{sense_id}:relation:{index:03d}"
                        connection.execute(
                            "INSERT INTO relations VALUES (?, ?, ?, ?, ?, ?)",
                            (relation_id, entry_id, sense_id, relation["entry_id"], relation["relation_type"], relation["note_ja"]),
                        )
                    for asset in sorted(sense["image_assets"], key=lambda item: item["asset_id"]):
                        connection.execute(
                            "INSERT INTO images VALUES (?, ?, ?, ?, ?, ?, ?)",
                            (asset["asset_id"], sense_id, asset["source_id"], asset["license_spdx"],
                             int(asset["redistribution_allowed"]), asset["sha256"], asset.get("path")),
                        )
                        counts["images"] += 1
                    for asset in sorted(sense["audio_assets"], key=lambda item: item["asset_id"]):
                        connection.execute(
                            "INSERT INTO audio_assets VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                            (asset["asset_id"], sense_id, asset["source_id"], asset["audio_type"], asset["license_spdx"],
                             int(asset["redistribution_allowed"]), asset["sha256"], asset.get("path")),
                        )
                        counts["audio"] += 1

            metadata = {
                "schema_version": str(document["schema_version"]),
                "dictionary_version": document["dictionary_version"],
                "normalizer_version": "1",
                "content_updated_at": max((entry["updated_at"] for entry in document["entries"]), default=""),
            }
            connection.executemany("INSERT INTO metadata VALUES (?, ?)", sorted(metadata.items()))

        foreign_key_errors = connection.execute("PRAGMA foreign_key_check").fetchall()
        if foreign_key_errors:
            raise ValueError(f"foreign key check failed: {foreign_key_errors}")
        connection.execute("ANALYZE")
        connection.execute("VACUUM")
        connection.close()
        temporary.replace(output)
    except Exception:
        try:
            connection.close()
        except UnboundLocalError:
            pass
        if temporary.exists():
            temporary.unlink()
        raise

    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    return BuildReport(**counts, database_sha256=digest)


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_name(path.name + ".building")
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def write_release_artifacts(
    document: dict[str, Any],
    database_path: str | Path,
    release_directory: str | Path,
    *,
    minimum_app_version: str = "0.1.0",
    released_at: str | None = None,
    allow_unreviewed: bool = False,
) -> dict[str, Any]:
    """Create a deterministic complete-package release next to the SQLite DB.

    ``released_at`` defaults to the newest canonical ``updated_at`` value so two
    builds from identical input remain byte-for-byte equivalent.
    """

    assert_valid_dictionary(document)
    unreviewed = [
        entry["entry_id"] for entry in document["entries"]
        if entry["edit_status"] not in {"approved", "published"}
    ]
    license_issues = license_clearance_issues(document)
    unsafe_asset_paths = [
        asset.get("path")
        for entry in document["entries"]
        for sense in entry["senses"]
        for asset in sense["image_assets"] + sense["audio_assets"]
        if not is_safe_asset_path(asset.get("path"))
    ]
    if unsafe_asset_paths:
        raise ValueError(f"release blocked: unsafe asset paths: {unsafe_asset_paths[:10]}")
    if unreviewed and not allow_unreviewed:
        raise ValueError(
            "release blocked: entries are not approved/published: "
            + ", ".join(unreviewed[:10])
            + ("..." if len(unreviewed) > 10 else "")
        )
    if license_issues and not allow_unreviewed:
        raise ValueError(
            "release blocked: referenced sources/media are not license-cleared: "
            + "; ".join(str(issue) for issue in license_issues[:10])
        )
    source_database = Path(database_path).resolve(strict=True)
    release_dir = Path(release_directory).resolve()
    release_dir.mkdir(parents=True, exist_ok=True)
    release_database = release_dir / "dictionary.sqlite"
    if source_database != release_database:
        staged = release_database.with_name(release_database.name + ".building")
        shutil.copyfile(source_database, staged)
        staged.replace(release_database)
    timestamp = released_at or max(entry["updated_at"] for entry in document["entries"])
    database_digest = sha256_file(release_database)
    manifest = {
        "schema_version": document["schema_version"],
        "dictionary_version": document["dictionary_version"],
        "minimum_app_version": minimum_app_version,
        "database_file": "dictionary.sqlite",
        "database_size": release_database.stat().st_size,
        "database_sha256": database_digest,
        "released_at": timestamp,
        "channel": "development" if unreviewed or license_issues else "release",
        "content_status": "contains_unreviewed" if unreviewed else "reviewed",
        "license_status": "contains_uncleared" if license_issues else "cleared",
    }
    assets_manifest = {
        "schema_version": 1,
        "dictionary_version": document["dictionary_version"],
        "released_at": timestamp,
        "assets": sorted(
            (
                {
                    "asset_id": asset["asset_id"], "kind": asset["kind"], "path": asset.get("path", ""),
                    "sha256": asset["sha256"], "source_id": asset["source_id"],
                    "license_spdx": asset["license_spdx"],
                }
                for entry in document["entries"]
                for sense in entry["senses"]
                for asset in sense["image_assets"] + sense["audio_assets"]
            ),
            key=lambda item: item["asset_id"],
        ),
    }
    _write_json(release_dir / "assets-manifest.json", assets_manifest)
    _write_json(release_dir / "release-manifest.json", manifest)
    checksum_names = ("dictionary.sqlite", "assets-manifest.json", "release-manifest.json")
    checksum_text = "".join(f"{sha256_file(release_dir / name)}  {name}\n" for name in checksum_names)
    checksum_temp = release_dir / "checksums.txt.building"
    checksum_temp.write_text(checksum_text, encoding="utf-8", newline="\n")
    checksum_temp.replace(release_dir / "checksums.txt")
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="canonical UTF-8 JSON")
    parser.add_argument("output", type=Path, help="output SQLite path")
    parser.add_argument("--report", type=Path, help="optional build report JSON")
    parser.add_argument("--release-dir", type=Path, help="also write complete-package release artifacts")
    parser.add_argument("--minimum-app-version", default="0.1.0")
    parser.add_argument("--released-at", help="explicit ISO-8601 release time; defaults to newest content timestamp")
    parser.add_argument(
        "--allow-unreviewed", action="store_true",
        help="development package only: allow draft content and mark manifest development/contains_unreviewed",
    )
    args = parser.parse_args(argv)
    try:
        with args.input.open("r", encoding="utf-8") as handle:
            document = json.load(handle)
        issues = validate_dictionary(document)
        errors = [issue for issue in issues if issue.severity == "error"]
        if errors:
            raise ValueError("\n".join(map(str, errors)))
        report = build_database(document, args.output)
        if args.release_dir:
            write_release_artifacts(
                document, args.output, args.release_dir,
                minimum_app_version=args.minimum_app_version, released_at=args.released_at,
                allow_unreviewed=args.allow_unreviewed,
            )
    except (OSError, json.JSONDecodeError, ValueError, sqlite3.Error) as exc:
        parser.exit(1, f"database build failed: {exc}\n")
    payload = json.dumps(asdict(report), ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(payload, encoding="utf-8")
    print(payload, end="")
    return 0
