"""SQLite persistence for generated entries, jobs and immutable revisions."""

from __future__ import annotations

import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import threading
import uuid
from typing import Any, Iterable

from packages.japanese_normalizer.normalizer import (
    deinflect,
    normalize_kana,
    normalize_text,
    query_variants,
)

from .providers import SearchResult
from .validation import validate_generated_entry


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _encode(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


class StoreConflictError(RuntimeError):
    pass


class StoreValidationError(ValueError):
    def __init__(self, issues: list[dict[str, str]]):
        super().__init__("entry failed automatic validation")
        self.issues = issues


class LocalDictionaryStore:
    """Own a mutable self-hosted dictionary database.

    Only entries that passed automatic validation are stored in ``entries``.
    Failed attempts remain in ``generation_jobs`` with structured issues.
    """

    def __init__(self, path: Path):
        self.path = path.expanduser().resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.path.exists() and self.path.is_symlink():
            raise ValueError("local dictionary database may not be a symlink")
        self._lock = threading.RLock()
        self._connection = sqlite3.connect(self.path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        self._connection.execute("PRAGMA foreign_keys = ON")
        self._connection.execute("PRAGMA journal_mode = WAL")
        self._connection.executescript(_SCHEMA)
        self._connection.commit()

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def search(self, query: str, *, limit: int = 50) -> list[dict[str, Any]]:
        keys = _query_keys(query)
        if not keys:
            return []
        with self._lock:
            rows: list[sqlite3.Row] = []
            seen: set[str] = set()
            for key in keys:
                exact_rows = self._connection.execute(
                    """
                    SELECT e.entry_id, e.payload_json
                    FROM entry_forms f
                    JOIN entries e USING (entry_id)
                    WHERE f.form_key = ?
                    ORDER BY e.updated_at DESC, e.entry_id
                    LIMIT ?
                    """,
                    (key, limit),
                ).fetchall()
                for row in exact_rows:
                    if row["entry_id"] not in seen:
                        seen.add(row["entry_id"])
                        rows.append(row)
            if not rows:
                for key in keys:
                    if len(key) < 2:
                        continue
                    prefix_rows = self._connection.execute(
                        """
                        SELECT DISTINCT e.entry_id, e.payload_json
                        FROM entry_forms f
                        JOIN entries e USING (entry_id)
                        WHERE f.form_key >= ? AND f.form_key < ?
                        ORDER BY e.updated_at DESC, e.entry_id
                        LIMIT ?
                        """,
                        (key, f"{key}\U0010ffff", limit),
                    ).fetchall()
                    for row in prefix_rows:
                        if row["entry_id"] not in seen:
                            seen.add(row["entry_id"])
                            rows.append(row)
            return [json.loads(row["payload_json"]) for row in rows[:limit]]

    def find_exact(self, query: str) -> dict[str, Any] | None:
        keys = _query_keys(query)
        if not keys:
            return None
        with self._lock:
            for key in keys:
                row = self._connection.execute(
                    """
                    SELECT e.payload_json
                    FROM entry_forms f
                    JOIN entries e USING (entry_id)
                    WHERE f.form_key = ?
                    ORDER BY e.updated_at DESC, e.entry_id
                    LIMIT 1
                    """,
                    (key,),
                ).fetchone()
                if row:
                    return json.loads(row["payload_json"])
        return None

    def get_entry(self, entry_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT payload_json FROM entries WHERE entry_id = ?",
                (entry_id,),
            ).fetchone()
            return json.loads(row["payload_json"]) if row else None

    def all_entries(self, *, limit: int = 10000) -> list[dict[str, Any]]:
        if limit < 1 or limit > 10000:
            raise ValueError("limit must be between 1 and 10000")
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT payload_json
                FROM entries
                ORDER BY updated_at DESC, entry_id
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
            return [json.loads(row["payload_json"]) for row in rows]

    def all_entry_ids(self) -> set[str]:
        with self._lock:
            return {
                row["entry_id"]
                for row in self._connection.execute("SELECT entry_id FROM entries")
            }

    def existing_form_keys(self, *, excluding_entry_id: str | None = None) -> set[str]:
        with self._lock:
            if excluding_entry_id is None:
                rows = self._connection.execute("SELECT form_key FROM entry_forms")
            else:
                rows = self._connection.execute(
                    "SELECT form_key FROM entry_forms WHERE entry_id != ?",
                    (excluding_entry_id,),
                )
            return {row["form_key"] for row in rows}

    def start_job(self, query: str, *, force: bool = False) -> dict[str, Any]:
        normalized = normalize_text(query)
        if not normalized:
            raise ValueError("query must not be empty")
        with self._lock:
            if not force:
                active = self._connection.execute(
                    """
                    SELECT job_id
                    FROM generation_jobs
                    WHERE normalized_query = ? AND status = 'generating'
                    ORDER BY created_at DESC
                    LIMIT 1
                    """,
                    (normalized,),
                ).fetchone()
                if active is not None:
                    job = self.get_job(active["job_id"])
                    job["_reused"] = True
                    return job
            existing = None if force else self.find_exact(query)
            job_id = f"job-{uuid.uuid4().hex}"
            now = _now()
            status = "ready" if existing else "generating"
            entry_id = existing["entry_id"] if existing else None
            self._connection.execute(
                """
                INSERT INTO generation_jobs (
                    job_id, query, normalized_query, status, entry_id,
                    error_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, NULL, ?, ?)
                """,
                (job_id, query.strip(), normalized, status, entry_id, now, now),
            )
            self._connection.commit()
            job = self.get_job(job_id)
            job["_reused"] = False
            return job

    def get_job(self, job_id: str) -> dict[str, Any]:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM generation_jobs WHERE job_id = ?",
                (job_id,),
            ).fetchone()
            if row is None:
                raise KeyError(job_id)
            job = {
                "job_id": row["job_id"],
                "query": row["query"],
                "status": row["status"],
                "entry_id": row["entry_id"],
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
                "error": json.loads(row["error_json"]) if row["error_json"] else None,
            }
            if row["entry_id"] and row["status"] == "ready":
                job["entry"] = self.get_entry(row["entry_id"])
            return job

    def complete_job(self, job_id: str, entry: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            job = self.get_job(job_id)
            if job["status"] != "generating":
                raise StoreConflictError("generation job is not active")
            existing = self.find_exact(job["query"])
            if existing and existing["entry_id"] != entry["entry_id"]:
                self._connection.execute(
                    """
                    UPDATE generation_jobs
                    SET status = 'ready', entry_id = ?, updated_at = ?
                    WHERE job_id = ?
                    """,
                    (existing["entry_id"], _now(), job_id),
                )
                self._connection.commit()
                return existing
            self._save_revision(entry)
            self._connection.execute(
                """
                UPDATE generation_jobs
                SET status = 'ready', entry_id = ?, error_json = NULL, updated_at = ?
                WHERE job_id = ?
                """,
                (entry["entry_id"], _now(), job_id),
            )
            self._connection.commit()
            return copy.deepcopy(entry)

    def fail_job(self, job_id: str, error: dict[str, Any]) -> None:
        with self._lock:
            self._connection.execute(
                """
                UPDATE generation_jobs
                SET status = 'failed', error_json = ?, updated_at = ?
                WHERE job_id = ? AND status = 'generating'
                """,
                (_encode(error), _now(), job_id),
            )
            self._connection.commit()

    def list_revisions(self, entry_id: str) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT revision, origin, created_at, model, source_count
                FROM revisions
                WHERE entry_id = ?
                ORDER BY revision DESC
                """,
                (entry_id,),
            ).fetchall()
            return [dict(row) for row in rows]

    def get_revision(self, entry_id: str, revision: int) -> dict[str, Any]:
        with self._lock:
            row = self._connection.execute(
                """
                SELECT payload_json
                FROM revisions
                WHERE entry_id = ? AND revision = ?
                """,
                (entry_id, revision),
            ).fetchone()
            if row is None:
                raise KeyError(f"{entry_id}:{revision}")
            return json.loads(row["payload_json"])

    def restore_revision(self, entry_id: str, revision: int) -> dict[str, Any]:
        with self._lock:
            current = self._require_entry(entry_id)
            restored = self.get_revision(entry_id, revision)
            restored["version_origin"] = "edited"
            restored["status"] = "ready"
            restored["locked"] = current.get("locked", False)
            restored["updated_at"] = _now()
            self._validate_for_save(restored, query=restored["headword"])
            self._save_revision(restored)
            self._connection.commit()
            return restored

    def edit_entry(self, entry_id: str, patch: dict[str, Any]) -> dict[str, Any]:
        with self._lock:
            current = self._require_entry(entry_id)
            updated = copy.deepcopy(current)
            if "headword" in patch:
                updated["headword"] = patch["headword"]
                primary = next(
                    (item for item in updated["forms"] if item.get("type") == "primary"),
                    None,
                )
                if primary:
                    primary["text"] = patch["headword"]
            if "reading" in patch:
                primary_reading = next(
                    (item for item in updated["readings"] if item.get("primary") is True),
                    None,
                )
                if primary_reading:
                    primary_reading["kana"] = patch["reading"]
                kana_form = next(
                    (item for item in updated["forms"] if item.get("type") == "kana"),
                    None,
                )
                if kana_form:
                    kana_form["text"] = patch["reading"]
            if "parts_of_speech" in patch:
                updated["parts_of_speech"] = patch["parts_of_speech"]
            if "definition_ja_simple" in patch:
                updated["senses"][0]["definition_ja_simple"] = patch["definition_ja_simple"]
            if "usage_note_ja" in patch:
                updated["senses"][0]["usage_note_ja"] = patch["usage_note_ja"]
            updated["version_origin"] = "edited"
            updated["status"] = "ready"
            updated["updated_at"] = _now()
            self._validate_for_save(updated, query=updated["headword"])
            self._save_revision(updated)
            self._connection.commit()
            return updated

    def set_locked(self, entry_id: str, locked: bool) -> dict[str, Any]:
        with self._lock:
            entry = self._require_entry(entry_id)
            if entry.get("locked") is locked:
                return entry
            entry["locked"] = locked
            entry["version_origin"] = "edited"
            entry["updated_at"] = _now()
            self._validate_for_save(entry, query=entry["headword"])
            self._save_revision(entry)
            self._connection.commit()
            return entry

    def mark_stale(self, entry_id: str) -> dict[str, Any]:
        with self._lock:
            entry = self._require_entry(entry_id)
            entry["status"] = "stale"
            entry["updated_at"] = _now()
            self._validate_for_save(entry, query=entry["headword"])
            self._save_revision(entry)
            self._connection.commit()
            return entry

    def delete_entry(self, entry_id: str) -> None:
        with self._lock:
            if self.get_entry(entry_id) is None:
                raise KeyError(entry_id)
            self._connection.execute("DELETE FROM entries WHERE entry_id = ?", (entry_id,))
            self._connection.commit()

    def _validate_for_save(self, entry: dict[str, Any], *, query: str) -> None:
        search_results = _search_results_from_entry(entry)
        issues = validate_generated_entry(
            entry,
            query=query,
            search_results=search_results,
            existing_form_keys=self.existing_form_keys(
                excluding_entry_id=entry.get("entry_id"),
            ),
        )
        if issues:
            raise StoreValidationError(issues)

    def _save_revision(self, entry: dict[str, Any]) -> None:
        entry_id = entry["entry_id"]
        row = self._connection.execute(
            "SELECT current_revision FROM entries WHERE entry_id = ?",
            (entry_id,),
        ).fetchone()
        revision = int(row["current_revision"]) + 1 if row else 1
        payload = _encode(entry)
        generation = entry.get("generation", {})
        self._connection.execute(
            """
            INSERT INTO revisions (
                entry_id, revision, origin, payload_json, created_at, model, source_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                entry_id,
                revision,
                entry["version_origin"],
                payload,
                _now(),
                str(generation.get("model", "")),
                int(generation.get("source_count", 0)),
            ),
        )
        self._connection.execute(
            """
            INSERT INTO entries (
                entry_id, headword, reading, status, locked, current_revision,
                payload_json, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entry_id) DO UPDATE SET
                headword = excluded.headword,
                reading = excluded.reading,
                status = excluded.status,
                locked = excluded.locked,
                current_revision = excluded.current_revision,
                payload_json = excluded.payload_json,
                updated_at = excluded.updated_at
            """,
            (
                entry_id,
                entry["headword"],
                _primary_reading(entry),
                entry["status"],
                1 if entry.get("locked") else 0,
                revision,
                payload,
                entry["created_at"],
                entry["updated_at"],
            ),
        )
        self._connection.execute("DELETE FROM entry_forms WHERE entry_id = ?", (entry_id,))
        for key in sorted(_entry_form_keys(entry)):
            self._connection.execute(
                "INSERT INTO entry_forms (entry_id, form_key) VALUES (?, ?)",
                (entry_id, key),
            )

    def _require_entry(self, entry_id: str) -> dict[str, Any]:
        entry = self.get_entry(entry_id)
        if entry is None:
            raise KeyError(entry_id)
        return entry


def _primary_reading(entry: dict[str, Any]) -> str:
    for reading in entry.get("readings", []):
        if isinstance(reading, dict) and reading.get("primary") is True:
            return str(reading.get("kana", ""))
    return ""


def _entry_form_keys(entry: dict[str, Any]) -> set[str]:
    values: list[str] = [str(entry.get("headword", ""))]
    values.extend(
        str(item.get("text", ""))
        for item in entry.get("forms", [])
        if isinstance(item, dict)
    )
    values.extend(
        str(item.get("kana", ""))
        for item in entry.get("readings", [])
        if isinstance(item, dict)
    )
    result: set[str] = set()
    for value in values:
        if value.strip():
            result.add(normalize_text(value))
            result.add(normalize_kana(value))
    return {item for item in result if item}


def _query_keys(query: str) -> list[str]:
    variants = query_variants(query)
    values = [
        item
        for group in variants.values()
        for item in group
        if isinstance(item, str) and item
    ]
    values.extend(item.lemma for item in deinflect(query))
    result: list[str] = []
    for value in values:
        for key in (normalize_text(value), normalize_kana(value)):
            if key and key not in result:
                result.append(key)
    return result


def _search_results_from_entry(entry: dict[str, Any]) -> list[SearchResult]:
    generation = entry.get("generation")
    if not isinstance(generation, dict):
        return []
    results: list[SearchResult] = []
    for source in generation.get("sources", []):
        if not isinstance(source, dict):
            continue
        try:
            results.append(
                SearchResult(
                    source_id=str(source["source_id"]),
                    title=str(source["title"]),
                    url=str(source["url"]),
                    snippet=str(source.get("snippet", "")),
                    retrieved_at=str(source["retrieved_at"]),
                    license_spdx=str(source["license_spdx"]),
                )
            )
        except KeyError:
            continue
    return results


_SCHEMA = """
CREATE TABLE IF NOT EXISTS entries (
    entry_id TEXT PRIMARY KEY,
    headword TEXT NOT NULL,
    reading TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('ready', 'stale')),
    locked INTEGER NOT NULL CHECK (locked IN (0, 1)),
    current_revision INTEGER NOT NULL CHECK (current_revision >= 1),
    payload_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS entry_forms (
    entry_id TEXT NOT NULL REFERENCES entries(entry_id) ON DELETE CASCADE,
    form_key TEXT NOT NULL,
    PRIMARY KEY (entry_id, form_key)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS idx_local_entry_forms_key ON entry_forms(form_key);
CREATE TABLE IF NOT EXISTS revisions (
    entry_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    origin TEXT NOT NULL CHECK (origin IN ('generated', 'edited', 'regenerated')),
    payload_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    model TEXT NOT NULL,
    source_count INTEGER NOT NULL CHECK (source_count >= 0),
    PRIMARY KEY (entry_id, revision)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS generation_jobs (
    job_id TEXT PRIMARY KEY,
    query TEXT NOT NULL,
    normalized_query TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('generating', 'ready', 'failed', 'stale')),
    entry_id TEXT,
    error_json TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_generation_jobs_query
ON generation_jobs(normalized_query, created_at DESC);
"""
