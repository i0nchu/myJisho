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

    def search_sources(self, query: str = "") -> tuple[list[dict[str, Any]], str]:
        """Return editor-safe provenance summaries without exposing the document."""

        document, revision = self.snapshot()
        needle = query.casefold().strip()
        results = []
        for source in document["sources"]:
            values = (
                source.get("source_id", ""),
                source.get("title", ""),
                source.get("author", ""),
            )
            if needle and not any(needle in str(value).casefold() for value in values):
                continue
            results.append({
                "source_id": source["source_id"],
                "title": source["title"],
                "source_type": source["source_type"],
                "author": source["author"],
                "license_spdx": source["license_spdx"],
            })
        results.sort(key=lambda item: (item["title"].casefold(), item["source_id"]))
        return results[:200], revision

    def get_entry(self, entry_id: str) -> tuple[dict[str, Any] | None, str]:
        document, revision = self.snapshot()
        entry = next((entry for entry in document["entries"] if entry.get("entry_id") == entry_id), None)
        return copy.deepcopy(entry), revision

    def prepare_editor_entry(
        self, entry_id: str, submitted: dict[str, Any]
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        """Protect system-owned fields and allocate IDs before editor validation.

        The browser submits a complete canonical snapshot with editable fields
        patched in place. This boundary still treats IDs, timestamps, versions,
        and review state as server-owned so hiding them in the UI cannot erase or
        silently rewrite them.
        """

        document, _ = self.snapshot()
        index = self._entry_index(document, entry_id)
        current = copy.deepcopy(document["entries"][index])
        if submitted.get("entry_id") != entry_id:
            raise ValueError("entry_id is system managed")

        prepared = copy.deepcopy(submitted)
        for key in ("entry_id", "created_at", "data_version", "edit_status", "review"):
            prepared[key] = copy.deepcopy(current[key])
        prepared["updated_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

        used_ids = self._stable_ids(document)
        current_senses = {
            sense.get("sense_id"): sense
            for sense in current.get("senses", [])
            if isinstance(sense, dict) and isinstance(sense.get("sense_id"), str)
        }
        current_examples = {
            example.get("example_id"): example
            for sense in current.get("senses", [])
            if isinstance(sense, dict)
            for example in sense.get("examples", [])
            if isinstance(example, dict) and isinstance(example.get("example_id"), str)
        }
        current_assets = {
            asset.get("asset_id"): asset
            for sense in current.get("senses", [])
            if isinstance(sense, dict)
            for field in ("image_assets", "audio_assets")
            for asset in sense.get(field, [])
            if isinstance(asset, dict) and isinstance(asset.get("asset_id"), str)
        }

        senses = prepared.get("senses")
        if isinstance(senses, list):
            for order, sense in enumerate(senses, start=1):
                if not isinstance(sense, dict):
                    continue
                sense_id = sense.get("sense_id")
                if not sense_id:
                    sense_id = self._new_stable_id("sense", used_ids)
                    sense["sense_id"] = sense_id
                elif sense_id not in current_senses:
                    raise ValueError("sense_id is system managed")
                sense["order"] = order
                prior_sense = current_senses.get(sense_id)
                sense["review_status"] = (
                    prior_sense.get("review_status", current["edit_status"])
                    if prior_sense
                    else current["edit_status"]
                )
                self._prepare_child_ids(
                    sense.get("examples"),
                    "example_id",
                    "example",
                    current_examples,
                    used_ids,
                )
                for field in ("image_assets", "audio_assets"):
                    self._prepare_child_ids(
                        sense.get(field),
                        "asset_id",
                        "asset",
                        current_assets,
                        used_ids,
                    )
        return current, prepared

    @staticmethod
    def _stable_ids(document: dict[str, Any]) -> set[str]:
        used: set[str] = set()
        for entry in document.get("entries", []):
            if not isinstance(entry, dict):
                continue
            if isinstance(entry.get("entry_id"), str):
                used.add(entry["entry_id"])
            for sense in entry.get("senses", []):
                if not isinstance(sense, dict):
                    continue
                if isinstance(sense.get("sense_id"), str):
                    used.add(sense["sense_id"])
                for example in sense.get("examples", []):
                    if isinstance(example, dict) and isinstance(example.get("example_id"), str):
                        used.add(example["example_id"])
                for field in ("image_assets", "audio_assets"):
                    for asset in sense.get(field, []):
                        if isinstance(asset, dict) and isinstance(asset.get("asset_id"), str):
                            used.add(asset["asset_id"])
        return used

    @staticmethod
    def _new_stable_id(kind: str, used_ids: set[str]) -> str:
        while True:
            candidate = f"{kind}-{uuid.uuid4().hex}"
            if candidate not in used_ids:
                used_ids.add(candidate)
                return candidate

    @classmethod
    def _prepare_child_ids(
        cls,
        children: Any,
        key: str,
        kind: str,
        current: dict[str, dict[str, Any]],
        used_ids: set[str],
    ) -> None:
        if not isinstance(children, list):
            return
        for child in children:
            if not isinstance(child, dict):
                continue
            child_id = child.get(key)
            if not child_id:
                child[key] = cls._new_stable_id(kind, used_ids)
            elif child_id not in current:
                raise ValueError(f"{key} is system managed")

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
