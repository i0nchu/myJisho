from __future__ import annotations

import unittest

from services.editor_api.schema_validation import validate_document
from services.editor_api.workflow import WorkflowError, check_replacement, transition
from services.editor_api.tests.support import valid_document, valid_entry


class SchemaValidationTests(unittest.TestCase):
    def test_valid_document_passes_structural_and_semantic_validation(self) -> None:
        self.assertEqual(validate_document(valid_document()), [])

    def test_reports_json_path_for_unknown_property(self) -> None:
        document = valid_document()
        document["entries"][0]["unexpected"] = True
        issues = validate_document(document)
        self.assertTrue(any(item["path"] == "$.entries[0].unexpected" and item["code"] == "additional_property" for item in issues))

    def test_reports_nested_media_metadata_error(self) -> None:
        document = valid_document()
        document["entries"][0]["senses"][0]["image_assets"] = [{
            "asset_id": "image-1",
            "source_id": "myjisho.original",
            "license_spdx": "CC-BY-4.0",
            "redistribution_allowed": True,
            "sha256": "not-a-hash",
            "kind": "image",
        }]
        issues = validate_document(document)
        self.assertTrue(any(item["path"].endswith(".sha256") and item["code"] == "pattern" for item in issues))


class WorkflowTests(unittest.TestCase):
    def test_ai_draft_cannot_skip_human_review(self) -> None:
        entry = valid_entry("ai_draft")
        with self.assertRaises(WorkflowError):
            transition(entry, "approved", "Alice")

    def test_human_review_sequence_records_evidence(self) -> None:
        entry = valid_entry("ai_draft")
        entry = transition(entry, "needs_review")
        self.assertEqual(entry["review"]["status"], "needs_review")
        self.assertTrue(all(sense["review_status"] == "needs_review" for sense in entry["senses"]))
        entry = transition(entry, "reviewed", "Alice", "Checked against source")
        self.assertEqual(entry["edit_status"], "reviewed")
        self.assertEqual(entry["review"]["status"], "reviewed")
        self.assertTrue(all(sense["review_status"] == "reviewed" for sense in entry["senses"]))
        self.assertEqual(entry["review"]["reviewed_by"], "Alice")
        self.assertTrue(entry["review"]["reviewed_at"].endswith("Z"))
        entry = transition(entry, "approved", "Alice")
        self.assertEqual(entry["edit_status"], "approved")
        self.assertEqual(entry["review"]["status"], "approved")
        self.assertTrue(all(sense["review_status"] == "approved" for sense in entry["senses"]))

    def test_published_content_must_return_to_review_before_editing(self) -> None:
        before = valid_entry("published")
        before["review"] = {"status": "published", "reviewed_by": "Alice", "reviewed_at": "2026-07-22T00:00:00Z", "notes": ""}
        after = valid_entry("published")
        after["review"] = dict(before["review"])
        after["headword"] = "改変"
        with self.assertRaises(WorkflowError):
            check_replacement(before, after)


if __name__ == "__main__":
    unittest.main()
