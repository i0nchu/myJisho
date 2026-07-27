from __future__ import annotations

import unittest

from services.local_dictionary.generation import DictionaryGenerator, GenerationError
from services.local_dictionary.providers import SearchResult

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
        self.assertEqual(entry["generation"]["retrieved_source_count"], 1)
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

    def test_validation_feedback_gets_one_guarded_model_repair(self) -> None:
        invalid = valid_draft()
        invalid["senses"][0]["definition_ja_simple"] = "這個詞的意思。"
        llm = FakeLLMProvider(drafts=[invalid, valid_draft()])

        entry = DictionaryGenerator(
            FakeSearchProvider(),
            llm,
        ).generate("食べる")

        self.assertEqual(llm.calls, 2)
        self.assertEqual(
            entry["senses"][0]["definition_ja_simple"],
            valid_draft()["senses"][0]["definition_ja_simple"],
        )
        self.assertIn("definition_language", llm.user_prompts[1])

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
        self.assertEqual(entry["generation"]["retrieved_source_count"], 0)

    def test_inflected_query_searches_lemma_and_reading_before_raw_noise(self) -> None:
        lemma_source = SearchResult(
            source_id="web_jawiktionary_lemma",
            title="食べる",
            url="https://ja.wiktionary.org/wiki/食べる",
            snippet="食べる (たべる) たべるの漢字表記。",
            retrieved_at="2026-07-27T12:00:00Z",
            license_spdx="CC-BY-SA-4.0",
        )
        reading_source = SearchResult(
            source_id="web_jawiktionary_reading",
            title="たべる",
            url="https://ja.wiktionary.org/wiki/たべる",
            snippet="たべる【食べる】何かを口からかんで飲み込む。",
            retrieved_at="2026-07-27T12:00:00Z",
            license_spdx="CC-BY-SA-4.0",
        )
        noisy_source = SearchResult(
            source_id="web_jawikipedia_noise",
            title="食べ放題",
            url="https://ja.wikipedia.org/wiki/食べ放題",
            snippet="飲食店のサービスについての記事。",
            retrieved_at="2026-07-27T12:00:00Z",
            license_spdx="CC-BY-SA-4.0",
        )
        search = FakeSearchProvider(
            results=[],
            results_by_query={
                "食べる": [noisy_source, lemma_source],
                "食べました": [noisy_source],
                "たべる": [reading_source],
            },
        )
        draft = valid_draft()
        draft["source_ids"] = [reading_source.source_id]
        draft["senses"][0]["source_ids"] = [reading_source.source_id]
        draft["senses"][0]["examples"][0]["source_id"] = reading_source.source_id
        llm = FakeLLMProvider(draft)

        entry = DictionaryGenerator(search, llm).generate("食べました")

        self.assertEqual(search.queries, ["食べました", "食べる", "たべる"])
        self.assertEqual(entry["generation"]["source_count"], 1)
        self.assertEqual(entry["generation"]["retrieved_source_count"], 3)
        self.assertEqual(
            [item["source_id"] for item in entry["generation"]["retrieved_sources"]],
            [
                lemma_source.source_id,
                reading_source.source_id,
                noisy_source.source_id,
            ],
        )
        self.assertIn("食べる", llm.user_prompts[0])
        self.assertIn("たべる", llm.user_prompts[0])

    def test_exact_dictionary_form_skips_ambiguous_deinflection_candidate(self) -> None:
        lemma_source = SearchResult(
            source_id="web_jawiktionary_lemma",
            title="食べる",
            url="https://ja.wiktionary.org/wiki/食べる",
            snippet="食べる (たべる) たべるの漢字表記。",
            retrieved_at="2026-07-27T12:00:00Z",
            license_spdx="CC-BY-SA-4.0",
        )
        reading_source = SearchResult(
            source_id="web_jawiktionary_reading",
            title="たべる",
            url="https://ja.wiktionary.org/wiki/たべる",
            snippet="たべる【食べる】何かを口からかんで飲み込む。",
            retrieved_at="2026-07-27T12:00:00Z",
            license_spdx="CC-BY-SA-4.0",
        )
        search = FakeSearchProvider(
            results=[],
            results_by_query={
                "食べる": [lemma_source],
                "たべる": [reading_source],
            },
        )
        draft = valid_draft()
        draft["source_ids"] = [reading_source.source_id]
        draft["senses"][0]["source_ids"] = [reading_source.source_id]
        draft["senses"][0]["examples"][0]["source_id"] = reading_source.source_id

        DictionaryGenerator(search, FakeLLMProvider(draft)).generate("食べる")

        self.assertEqual(search.queries, ["食べる", "たべる"])
        self.assertNotIn("食ぶ", search.queries)

    def test_godan_polite_query_keeps_lexically_verifiable_lemma_candidate(self) -> None:
        search = FakeSearchProvider(results=[])
        draft = valid_draft()
        draft["headword"] = "飲む"
        draft["forms"] = [
            {"text": "飲む", "type": "primary", "common": True},
            {"text": "のむ", "type": "kana", "common": True},
        ]
        draft["readings"] = [{"kana": "のむ", "primary": True}]
        draft["parts_of_speech"] = ["verb-godan"]
        draft["source_ids"] = []
        draft["senses"][0]["definition_ja_simple"] = "飲み物を口から体の中に入れる。"
        draft["senses"][0]["source_ids"] = []
        draft["senses"][0]["examples"] = [
            {
                "sentence": "毎朝水を飲む。",
                "source_id": None,
            }
        ]

        DictionaryGenerator(search, FakeLLMProvider(draft)).generate("飲みました")

        self.assertIn("飲む", search.queries)
        self.assertNotIn("飲みます", search.queries)

    def test_missing_form_common_flag_gets_a_safe_structural_default(self) -> None:
        draft = valid_draft()
        draft["forms"][0].pop("common")
        draft["forms"][1].pop("common")
        draft["forms"].append({"text": "喰べる", "type": "variant"})

        entry = DictionaryGenerator(
            FakeSearchProvider(),
            FakeLLMProvider(draft),
        ).generate("食べる")

        self.assertTrue(entry["forms"][0]["common"])
        self.assertTrue(entry["forms"][1]["common"])
        self.assertFalse(entry["forms"][2]["common"])


if __name__ == "__main__":
    unittest.main()
