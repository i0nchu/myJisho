"""Atomic, confined working-copy storage."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import tempfile
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .schema_validation import validate_document


class ConflictError(RuntimeError):
    pass


class ValidationError(ValueError):
    def __init__(self, issues: list[dict[str, str]]):
        super().__init__("document failed validation")
        self.issues = issues


class WorkingCopyStore:
    """Own one fixed JSON file under a configured directory.

    HTTP input never becomes a filesystem path. Writes are fsync'd and replaced
    atomically, and symlinked targets are rejected.
    """

    FILENAME = "dictionary.working.json"
    AUDIT_FILENAME = "audit.jsonl"

    def __init__(self, working_dir: Path, source: Path | None = None):
        self.root = working_dir.expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        if not self.root.is_dir() or self.root.is_symlink():
            raise ValueError("working directory must be a real directory")
        self.path = self._confined(self.root / self.FILENAME)
        self.audit_path = self._confined(self.root / self.AUDIT_FILENAME)
        self._lock = threading.RLock()
        if self.path.exists() and self.path.is_symlink():
            raise ValueError("working copy may not be a symlink")
        if not self.path.exists():
            initial = self._read_source(source) if source else {
                "schema_version": 1,
                "dictionary_version": "working-1",
                "sources": [],
                "entries": [],
            }
            issues = validate_document(initial)
            if issues:
                raise ValidationError(issues)
            self._write_atomic(initial)

    def _confined(self, path: Path) -> Path:
        resolved = path.resolve(strict=False)
        if os.path.commonpath((str(self.root), str(resolved))) != str(self.root):
            raise ValueError("path escapes working directory")
        return resolved

    @staticmethod
    def _read_source(source: Path) -> dict[str, Any]:
        with source.expanduser().resolve(strict=True).open("r", encoding="utf-8") as stream:
            document = json.load(stream)
        if not isinstance(document, dict):
            raise ValueError("source document must be a JSON object")
        return document

    def _read(self) -> dict[str, Any]:
        if self.path.is_symlink():
            raise ValueError("working copy may not be a symlink")
        with self.path.open("r", encoding="utf-8") as stream:
            return json.load(stream)

    @staticmethod
    def _revision(document: dict[str, Any]) -> str:
        encoded = json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def snapshot(self) -> tuple[dict[str, Any], str]:
        with self._lock:
            document = self._read()
            return copy.deepcopy(document), self._revision(document)

    def search(self, query: str) -> tuple[list[dict[str, Any]], str]:
        document, revision = self.snapshot()
        needle = query.casefold().strip()
        results = []
        for entry in document["entries"]:
            values = [entry.get("entry_id", ""), entry.get("headword", "")]
            values.extend(item.get("text", "") for item in entry.get("forms", []))
            values.extend(item.get("kana", "") for item in entry.get("readings", []))
            if not needle or any(needle in str(value).casefold() for value in values):
                results.append({
                    "entry_id": entry["entry_id"],
                    "headword": entry["headword"],
                    "reading": next((item["kana"] for item in entry.get("readings", []) if item.get("primary")), ""),
                    "edit_status": entry["edit_status"],
                })
            if len(results) >= 100:
                break
        return results, revision

    def get_entry(self, entry_id: str) -> tuple[dict[str, Any] | None, str]:
        document, revision = self.snapshot()
        entry = next((entry for entry in document["entries"] if entry.get("entry_id") == entry_id), None)
        return copy.deepcopy(entry), revision

    def validate_replacement(self, entry_id: str, entry: dict[str, Any]) -> list[dict[str, str]]:
        document, _ = self.snapshot()
        index = self._entry_index(document, entry_id)
        document["entries"][index] = copy.deepcopy(entry)
        return validate_document(document)

    def replace_entry(self, entry_id: str, entry: dict[str, Any], base_revision: str, action: str = "save") -> str:
        with self._lock:
            document = self._read()
            current = self._revision(document)
            if not base_revision or base_revision != current:
                raise ConflictError("working copy changed; reload before saving")
            index = self._entry_index(document, entry_id)
            if entry.get("entry_id") != entry_id:
                raise ValueError("entry_id in URL and document must match")
            document["entries"][index] = copy.deepcopy(entry)
            issues = validate_document(document)
            if issues:
                raise ValidationError(issues)
            revision = self._revision(document)
            operation_id = uuid.uuid4().hex
            # The durable prepared record must exist before the working copy can
            # change. If the atomic replace or committed append later fails, the
            # prepared record still identifies the attempted revision.
            self._audit(
                "prepared",
                operation_id,
                action,
                entry_id,
                current,
                revision,
                entry.get("edit_status", ""),
            )
            self._write_atomic(document)
            self._audit(
                "committed",
                operation_id,
                action,
                entry_id,
                current,
                revision,
                entry.get("edit_status", ""),
            )
            return revision

    @staticmethod
    def _entry_index(document: dict[str, Any], entry_id: str) -> int:
        for index, entry in enumerate(document["entries"]):
            if entry.get("entry_id") == entry_id:
                return index
        raise KeyError(entry_id)

    def _write_atomic(self, document: dict[str, Any]) -> None:
        handle, temporary_name = tempfile.mkstemp(prefix=".dictionary-", suffix=".tmp", dir=self.root)
        try:
            with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as stream:
                json.dump(document, stream, ensure_ascii=False, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary_name, self.path)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)

    def _audit(
        self,
        phase: str,
        operation_id: str,
        action: str,
        entry_id: str,
        before: str,
        after: str,
        status: str,
    ) -> None:
        record = {
            "at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "phase": phase,
            "operation_id": operation_id,
            "action": action,
            "entry_id": entry_id,
            "status": status,
            "before_revision": before,
            "after_revision": after,
        }
        if self.audit_path.exists() and self.audit_path.is_symlink():
            raise ValueError("audit file may not be a symlink")
        with self.audit_path.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
