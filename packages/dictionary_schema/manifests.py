"""Release-manifest and checksum validation used before atomic DB updates."""

from __future__ import annotations

from datetime import datetime
import hashlib
import hmac
import json
from pathlib import Path
import re
import sqlite3
from typing import Any


_SHA256 = re.compile(r"^[a-f0-9]{64}$")
_VERSION = re.compile(r"^[0-9]+(?:\.[0-9]+){2}(?:[-+][0-9A-Za-z.-]+)?$")
EXPECTED_APPLICATION_ID = 1263489602
REQUIRED_DICTIONARY_TABLES = {
    "entries", "entry_forms", "readings", "parts_of_speech",
    "entry_parts_of_speech", "senses", "definitions", "examples",
    "relations", "images", "audio_assets", "search_keys", "sources",
    "entry_sources", "editorial_reviews", "metadata",
}


def validate_release_manifest(manifest: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(manifest, dict):
        return ["manifest must be an object"]
    required = {
        "schema_version", "dictionary_version", "minimum_app_version",
        "database_file", "database_size", "database_sha256", "released_at",
        "channel", "content_status", "license_status",
    }
    unknown = set(manifest) - required
    missing = required - set(manifest)
    if missing:
        errors.append("missing fields: " + ", ".join(sorted(missing)))
    if unknown:
        errors.append("unknown fields: " + ", ".join(sorted(unknown)))
    if manifest.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    for field in ("dictionary_version", "minimum_app_version"):
        if not isinstance(manifest.get(field), str) or not _VERSION.fullmatch(manifest[field]):
            errors.append(f"{field} is not a supported semantic version")
    if manifest.get("database_file") != "dictionary.sqlite":
        errors.append("database_file must be dictionary.sqlite")
    if manifest.get("channel") not in {"release", "development"}:
        errors.append("channel must be release or development")
    if manifest.get("content_status") not in {"reviewed", "contains_unreviewed"}:
        errors.append("content_status is invalid")
    if manifest.get("license_status") not in {"cleared", "contains_uncleared"}:
        errors.append("license_status is invalid")
    if manifest.get("channel") == "release" and manifest.get("content_status") != "reviewed":
        errors.append("release channel may contain only reviewed content")
    if manifest.get("channel") == "release" and manifest.get("license_status") != "cleared":
        errors.append("release channel may contain only license-cleared content")
    if not isinstance(manifest.get("database_size"), int) or manifest.get("database_size", 0) < 1:
        errors.append("database_size must be a positive integer")
    if not isinstance(manifest.get("database_sha256"), str) or not _SHA256.fullmatch(manifest["database_sha256"]):
        errors.append("database_sha256 must be a lowercase SHA-256")
    try:
        datetime.fromisoformat(str(manifest.get("released_at", "")).replace("Z", "+00:00"))
    except ValueError:
        errors.append("released_at must be ISO-8601")
    return errors


def sha256_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_release_artifacts(directory: str | Path) -> dict[str, Any]:
    """Verify a staged release without following manifest-controlled paths."""

    root = Path(directory).resolve(strict=True)
    manifest_path = root / "release-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    errors = validate_release_manifest(manifest)
    if errors:
        raise ValueError("invalid release manifest: " + "; ".join(errors))
    database = root / "dictionary.sqlite"
    if not database.is_file() or database.is_symlink():
        raise ValueError("dictionary.sqlite must be a regular, non-symlink file")
    if database.stat().st_size != manifest["database_size"]:
        raise ValueError("dictionary.sqlite size mismatch")
    actual = sha256_file(database)
    if not hmac.compare_digest(actual, manifest["database_sha256"]):
        raise ValueError("dictionary.sqlite checksum mismatch")

    checksum_path = root / "checksums.txt"
    expected_files = {"dictionary.sqlite", "assets-manifest.json", "release-manifest.json"}
    seen: set[str] = set()
    for line in checksum_path.read_text(encoding="utf-8").splitlines():
        parts = line.split("  ", 1)
        if len(parts) != 2 or not _SHA256.fullmatch(parts[0]) or parts[1] not in expected_files:
            raise ValueError("malformed or unsafe checksums.txt line")
        filename = parts[1]
        if filename in seen:
            raise ValueError("duplicate checksums.txt filename")
        seen.add(filename)
        file_path = root / filename
        if not file_path.is_file() or file_path.is_symlink():
            raise ValueError(f"unsafe or missing release file: {filename}")
        if not hmac.compare_digest(sha256_file(file_path), parts[0]):
            raise ValueError(f"checksum mismatch: {filename}")
    if seen != expected_files:
        raise ValueError("checksums.txt must cover exactly the release files")

    # A checksum proves byte identity, not that the bytes form the expected
    # dictionary database. Validate the staged file before activation.
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(database.as_uri() + "?mode=ro&immutable=1", uri=True)
        connection.execute("PRAGMA query_only = ON")
        quick_check = connection.execute("PRAGMA quick_check").fetchall()
        if quick_check != [("ok",)]:
            raise ValueError(f"SQLite quick_check failed: {quick_check}")
        application_id = connection.execute("PRAGMA application_id").fetchone()[0]
        if application_id != EXPECTED_APPLICATION_ID:
            raise ValueError(f"SQLite application_id mismatch: {application_id}")
        user_version = connection.execute("PRAGMA user_version").fetchone()[0]
        if user_version != manifest["schema_version"]:
            raise ValueError(f"SQLite user_version mismatch: {user_version}")
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_schema WHERE type='table'"
            ).fetchall()
        }
        missing_tables = REQUIRED_DICTIONARY_TABLES - tables
        if missing_tables:
            raise ValueError("SQLite missing required tables: " + ", ".join(sorted(missing_tables)))
        entry_columns = {row[1] for row in connection.execute("PRAGMA table_info(entries)").fetchall()}
        if not {"entry_id", "frequency_rank", "payload_json"}.issubset(entry_columns):
            raise ValueError("SQLite entries table lacks required canonical payload columns")
        foreign_key_errors = connection.execute("PRAGMA foreign_key_check").fetchall()
        if foreign_key_errors:
            raise ValueError(f"SQLite foreign key check failed: {foreign_key_errors[:10]}")
    except sqlite3.Error as exc:
        raise ValueError(f"SQLite health check failed: {exc}") from exc
    finally:
        if connection is not None:
            connection.close()
    return manifest
