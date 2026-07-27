from __future__ import annotations

import unittest

from services.local_dictionary.generation import DictionaryGenerator, GenerationError

from .support import FakeLLMProvider, FakeSearchProvider, valid_draft


class DictionaryGenerationTests(unittest.TestCase):
    def test_inflected_query_generates_valid_dictionary_form(self) -> None:
        search = FakeSearchProvider()
        llm = FakeLLMProvider()
        entry = DictionaryGenerator(search, llm).generate("食べました")

        self.assertEqual(entry["headword"], "食べる")
        self.assertEqual(entry["status"], "ready")
        self.assertEqual(entry["version_origin"], "generated")
        self.assertEqual(entry["generation"]["model"], "Qwen3 8B Test")
        self.assertEqual(entry["generation"]["source_count"], 1)
        self.assertFalse(entry["generation"]["knowledge_only"])
        self.assertNotIn("review", entry)
        self.assertNotIn("edit_status", entry)
        self.assertNotIn("review_status", entry["senses"][0])

    def test_chinese_definition_is_rejected_before_storage(self) -> None:
        draft = valid_draft()
        draft["senses"][0]["definition_ja_simple"] = "這個詞的意思是把食物吃下去。"

        with self.assertRaises(GenerationError) as raised:
            DictionaryGenerator(FakeSearchProvider(), FakeLLMProvider(draft)).generate("食べる")

        self.assertEqual(raised.exception.code, "validation_failed")
        self.assertIn(
            "definition_language",
            {issue["code"] for issue in raised.exception.issues},
        )

    def test_unknown_search_source_is_rejected(self) -> None:
        draft = valid_draft()
        draft["source_ids"] = ["invented_source"]
        draft["senses"][0]["source_ids"] = ["invented_source"]
        draft["senses"][0]["examples"][0]["source_id"] = "invented_source"

        with self.assertRaises(GenerationError) as raised:
            DictionaryGenerator(FakeSearchProvider(), FakeLLMProvider(draft)).generate("食べる")

        self.assertIn(
            "unknown_search_source",
            {issue["code"] for issue in raised.exception.issues},
        )

    def test_nested_source_must_be_declared_by_entry(self) -> None:
        draft = valid_draft()
        draft["source_ids"] = []

        with self.assertRaises(GenerationError) as raised:
            DictionaryGenerator(
                FakeSearchProvider(),
                FakeLLMProvider(draft),
            ).generate("食べる")

        self.assertIn(
            "undeclared_source",
            {issue["code"] for issue in raised.exception.issues},
        )

    def test_irrelevant_example_is_rejected(self) -> None:
        draft = valid_draft()
        draft["senses"][0]["examples"][0]["sentence"] = "今日は雨が降っている。"

        with self.assertRaises(GenerationError) as raised:
            DictionaryGenerator(FakeSearchProvider(), FakeLLMProvider(draft)).generate("食べる")

        self.assertIn(
            "irrelevant_example",
            {issue["code"] for issue in raised.exception.issues},
        )

    def test_existing_form_is_rejected_as_duplicate(self) -> None:
        with self.assertRaises(GenerationError) as raised:
            DictionaryGenerator(FakeSearchProvider(), FakeLLMProvider()).generate(
                "食べる",
                existing_form_keys={"食べる"},
            )

        self.assertIn(
            "duplicate_entry",
            {issue["code"] for issue in raised.exception.issues},
        )

    def test_knowledge_only_entry_is_allowed_and_flagged(self) -> None:
        draft = valid_draft()
        draft["source_ids"] = []
        draft["senses"][0]["source_ids"] = []
        draft["senses"][0]["examples"][0]["source_id"] = None
        entry = DictionaryGenerator(
            FakeSearchProvider(results=[]),
            FakeLLMProvider(draft),
        ).generate("食べる")

        self.assertTrue(entry["generation"]["knowledge_only"])
        self.assertEqual(entry["generation"]["source_count"], 0)


if __name__ == "__main__":
    unittest.main()
