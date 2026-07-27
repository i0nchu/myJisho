from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from services.local_dictionary.generation import DictionaryGenerator
from services.local_dictionary.storage import LocalDictionaryStore

from .support import FakeLLMProvider, FakeSearchProvider


class LocalDictionaryStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="kotoba-local-store-")
        self.store = LocalDictionaryStore(Path(self.temporary.name) / "dictionary.sqlite")
        self.generator = DictionaryGenerator(FakeSearchProvider(), FakeLLMProvider())

    def tearDown(self) -> None:
        self.store.close()
        self.temporary.cleanup()

    def _generate(self) -> dict:
        job = self.store.start_job("食べました")
        entry = self.generator.generate(
            "食べました",
            existing_form_keys=self.store.existing_form_keys(),
        )
        return self.store.complete_job(job["job_id"], entry)

    def test_generated_entry_is_reused_for_repeated_query(self) -> None:
        entry = self._generate()
        repeated = self.store.start_job("食べる")

        self.assertEqual(repeated["status"], "ready")
        self.assertEqual(repeated["entry_id"], entry["entry_id"])
        self.assertEqual(len(self.store.search("食べました")), 1)
        self.assertEqual(len(self.store.list_revisions(entry["entry_id"])), 1)

    def test_active_generation_job_is_reused_for_same_query(self) -> None:
        first = self.store.start_job("食べる")
        second = self.store.start_job("食べる")

        self.assertEqual(first["status"], "generating")
        self.assertEqual(second["job_id"], first["job_id"])
        self.assertTrue(second["_reused"])

    def test_edit_lock_restore_and_delete_keep_revision_history(self) -> None:
        entry = self._generate()
        entry_id = entry["entry_id"]
        edited = self.store.edit_entry(
            entry_id,
            {"definition_ja_simple": "食べ物を口に入れて飲み込む。"},
        )
        self.assertEqual(edited["version_origin"], "edited")
        locked = self.store.set_locked(entry_id, True)
        self.assertTrue(locked["locked"])
        restored = self.store.restore_revision(entry_id, 1)
        self.assertTrue(restored["locked"])
        self.assertEqual(restored["version_origin"], "edited")
        self.assertEqual(
            [item["revision"] for item in self.store.list_revisions(entry_id)],
            [4, 3, 2, 1],
        )

        self.store.delete_entry(entry_id)
        self.assertIsNone(self.store.get_entry(entry_id))
        self.assertEqual(len(self.store.list_revisions(entry_id)), 4)

    def test_failed_job_never_creates_formal_entry(self) -> None:
        job = self.store.start_job("存在しない")
        self.store.fail_job(
            job["job_id"],
            {
                "code": "validation_failed",
                "message": "invalid",
                "issues": [{"path": "$.headword", "code": "required", "message": "missing"}],
                "retryable": True,
            },
        )

        failed = self.store.get_job(job["job_id"])
        self.assertEqual(failed["status"], "failed")
        self.assertIsNone(self.store.find_exact("存在しない"))


if __name__ == "__main__":
    unittest.main()
