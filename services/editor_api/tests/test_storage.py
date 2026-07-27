from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from services.editor_api.storage import ConflictError, WorkingCopyStore
from services.editor_api.tests.support import valid_document


class WorkingCopyStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.source = root / "source.json"
        self.source.write_text(json.dumps(valid_document(), ensure_ascii=False), encoding="utf-8")
        self.store = WorkingCopyStore(root / "work", self.source)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_source_is_copied_and_never_modified(self) -> None:
        source_before = self.source.read_bytes()
        entry, revision = self.store.get_entry("entry-taberu")
        assert entry is not None
        entry["headword"] = "食う"
        self.store.replace_entry("entry-taberu", entry, revision)
        self.assertEqual(self.source.read_bytes(), source_before)
        self.assertEqual(self.store.get_entry("entry-taberu")[0]["headword"], "食う")

    def test_stale_revision_is_rejected(self) -> None:
        entry, revision = self.store.get_entry("entry-taberu")
        assert entry is not None
        entry["headword"] = "食う"
        self.store.replace_entry("entry-taberu", entry, revision)
        with self.assertRaises(ConflictError):
            self.store.replace_entry("entry-taberu", entry, revision)

    def test_editor_preparation_preserves_system_fields_and_allocates_child_ids(self) -> None:
        current, _ = self.store.get_entry("entry-taberu")
        assert current is not None
        submitted = json.loads(json.dumps(current))
        submitted["created_at"] = "2000-01-01T00:00:00Z"
        submitted["updated_at"] = "2000-01-01T00:00:00Z"
        submitted["data_version"] = "tampered"
        submitted["edit_status"] = "published"
        submitted["review"] = {
            "status": "published",
            "reviewed_by": "Mallory",
            "reviewed_at": "2000-01-01T00:00:00Z",
            "notes": "",
        }
        submitted["senses"][0]["review_status"] = "published"
        submitted["senses"].append({
            "sense_id": "",
            "order": 99,
            "definition_ja_simple": "新しい意味。",
            "usage_note_ja": "",
            "register": "neutral",
            "importance": "secondary",
            "examples": [{
                "example_id": "",
                "sentence": "新しい例文。",
                "source_id": "myjisho.original",
                "audio_asset_id": None,
            }],
            "relations": [],
            "image_assets": [],
            "audio_assets": [],
            "source_ids": ["myjisho.original"],
            "review_status": "published",
        })

        before, prepared = self.store.prepare_editor_entry("entry-taberu", submitted)

        self.assertEqual(before, current)
        for field in ("entry_id", "created_at", "data_version", "edit_status", "review"):
            self.assertEqual(prepared[field], current[field])
        self.assertNotEqual(prepared["updated_at"], submitted["updated_at"])
        self.assertEqual([sense["order"] for sense in prepared["senses"]], [1, 2])
        self.assertEqual([sense["review_status"] for sense in prepared["senses"]], ["draft", "draft"])
        self.assertTrue(prepared["senses"][1]["sense_id"].startswith("sense-"))
        self.assertTrue(prepared["senses"][1]["examples"][0]["example_id"].startswith("example-"))

    def test_editor_preparation_rejects_rewritten_stable_ids(self) -> None:
        submitted, _ = self.store.get_entry("entry-taberu")
        assert submitted is not None
        submitted["senses"][0]["sense_id"] = "rewritten-by-client"
        with self.assertRaisesRegex(ValueError, "sense_id is system managed"):
            self.store.prepare_editor_entry("entry-taberu", submitted)

    def test_filesystem_target_cannot_escape_working_directory(self) -> None:
        with self.assertRaises(ValueError):
            self.store._confined(self.store.root.parent / "outside.json")

    def test_audit_uses_fixed_jsonl_inside_working_directory(self) -> None:
        entry, revision = self.store.get_entry("entry-taberu")
        assert entry is not None
        entry["headword"] = "食う"
        self.store.replace_entry("entry-taberu", entry, revision)
        records = [json.loads(line) for line in self.store.audit_path.read_text(encoding="utf-8").splitlines()]
        self.assertEqual([record["phase"] for record in records], ["prepared", "committed"])
        self.assertEqual(records[0]["operation_id"], records[1]["operation_id"])
        self.assertEqual(records[0]["entry_id"], "entry-taberu")
        self.assertEqual(self.store.audit_path.parent, self.store.root)

    def test_audit_directory_failure_prevents_working_copy_commit(self) -> None:
        entry, revision = self.store.get_entry("entry-taberu")
        assert entry is not None
        before = self.store.path.read_bytes()
        entry["headword"] = "changed"
        self.store.audit_path.mkdir()

        with self.assertRaises(OSError):
            self.store.replace_entry("entry-taberu", entry, revision)

        self.assertEqual(self.store.path.read_bytes(), before)

    def test_audit_permission_failure_prevents_working_copy_commit(self) -> None:
        entry, revision = self.store.get_entry("entry-taberu")
        assert entry is not None
        before = self.store.path.read_bytes()
        entry["headword"] = "changed"

        with patch.object(self.store, "_audit", side_effect=PermissionError("audit denied")):
            with self.assertRaises(PermissionError):
                self.store.replace_entry("entry-taberu", entry, revision)

        self.assertEqual(self.store.path.read_bytes(), before)

    def test_atomic_replace_permission_failure_leaves_prepared_audit(self) -> None:
        entry, revision = self.store.get_entry("entry-taberu")
        assert entry is not None
        before = self.store.path.read_bytes()
        entry["headword"] = "changed"

        with patch("services.editor_api.storage.os.replace", side_effect=PermissionError("replace denied")):
            with self.assertRaises(PermissionError):
                self.store.replace_entry("entry-taberu", entry, revision)

        self.assertEqual(self.store.path.read_bytes(), before)
        records = [json.loads(line) for line in self.store.audit_path.read_text(encoding="utf-8").splitlines()]
        self.assertEqual([record["phase"] for record in records], ["prepared"])

    def test_committed_audit_failure_still_has_durable_prepared_record(self) -> None:
        entry, revision = self.store.get_entry("entry-taberu")
        assert entry is not None
        entry["headword"] = "changed"
        original_audit = self.store._audit

        def fail_committed(phase: str, *args: object) -> None:
            if phase == "committed":
                raise PermissionError("commit audit denied")
            original_audit(phase, *args)  # type: ignore[arg-type]

        with patch.object(self.store, "_audit", side_effect=fail_committed):
            with self.assertRaises(PermissionError):
                self.store.replace_entry("entry-taberu", entry, revision)

        self.assertEqual(self.store.get_entry("entry-taberu")[0]["headword"], "changed")
        records = [json.loads(line) for line in self.store.audit_path.read_text(encoding="utf-8").splitlines()]
        self.assertEqual([record["phase"] for record in records], ["prepared"])
        self.assertEqual(records[0]["after_revision"], self.store.snapshot()[1])


if __name__ == "__main__":
    unittest.main()
