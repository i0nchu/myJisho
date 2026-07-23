from __future__ import annotations

import copy
import json
from pathlib import Path
import tempfile
import unittest

from packages.dictionary_schema import assert_valid_dictionary
from tools import verify_search_acceptance as acceptance
from tools.generate_search_acceptance_fixture import render_fixture


ROOT = Path(__file__).resolve().parents[1]
CORPUS_PATH = ROOT / "data" / "fixtures" / "search_acceptance_v1.json"


class SearchAcceptanceCorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.committed_text = CORPUS_PATH.read_text(encoding="utf-8")
        cls.corpus = json.loads(cls.committed_text)

    def test_committed_fixture_is_exact_generator_output(self) -> None:
        self.assertEqual(self.committed_text, render_fixture())

    def test_counts_checksum_and_anti_padding_contract(self) -> None:
        statistics = acceptance.validate_corpus(self.corpus)
        self.assertEqual(
            statistics,
            {
                "common_words": 100,
                "verb_inflections": 50,
                "adjective_inflections": 20,
                "katakana": 20,
                "romaji": 20,
                "ambiguity": 20,
                "negative": 20,
                "lexicon_entries": 235,
                "total_cases": 250,
            },
        )
        for category in (
            "common_words",
            "verb_inflections",
            "adjective_inflections",
            "katakana",
            "romaji",
        ):
            cases = self.corpus["categories"][category]
            self.assertEqual(
                len({case["expected_entry_ids"][0] for case in cases}),
                len(cases),
                f"{category} must not repeat one entry to pad its count",
            )
        all_queries = [
            case["raw_query"]
            for cases in self.corpus["categories"].values()
            for case in cases
        ]
        self.assertEqual(len(all_queries), len(set(all_queries)))
        self.assertEqual(
            {row["editorial_level"] for row in self.corpus["lexicon"]},
            {"featured", "curated", "imported"},
        )

    def test_checksum_detects_unreviewed_fixture_edits(self) -> None:
        modified = copy.deepcopy(self.corpus)
        modified["categories"]["negative"][0]["raw_query"] = "別の負例"
        with self.assertRaisesRegex(acceptance.CorpusError, "checksum mismatch"):
            acceptance.validate_corpus(modified)

    def test_duplicate_query_is_rejected_even_with_new_checksum(self) -> None:
        modified = copy.deepcopy(self.corpus)
        cases = modified["categories"]["verb_inflections"]
        cases[1]["raw_query"] = cases[0]["raw_query"]
        modified["content_sha256"] = acceptance._content_checksum(modified)
        with self.assertRaisesRegex(acceptance.CorpusError, "duplicate query"):
            acceptance.validate_corpus(modified)

    def test_cross_category_duplicate_is_rejected(self) -> None:
        modified = copy.deepcopy(self.corpus)
        modified["categories"]["negative"][0]["raw_query"] = modified[
            "categories"
        ]["common_words"][0]["raw_query"]
        modified["content_sha256"] = acceptance._content_checksum(modified)
        with self.assertRaisesRegex(
            acceptance.CorpusError, "duplicate query across categories"
        ):
            acceptance.validate_corpus(modified)

    def test_acceptance_lexicon_uses_canonical_builder_contract(self) -> None:
        document = acceptance.corpus_to_canonical(self.corpus)
        assert_valid_dictionary(document)
        self.assertEqual(document["schema_version"], 1)
        self.assertEqual(len(document["entries"]), 235)
        self.assertTrue(
            all(entry["edit_status"] == "ai_draft" for entry in document["entries"])
        )

    def test_python_normalizer_search_ranking_and_explain_end_to_end(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "acceptance.sqlite"
            evidence = acceptance.verify_runtime(self.corpus, database)
        self.assertEqual(evidence["total_cases"], 250)
        self.assertEqual(evidence["deterministic_checks"], 250)
        self.assertEqual(evidence["explanation_checks"], 230)
        self.assertEqual(evidence["failures"], 0)
        self.assertEqual(evidence["canonical_schema_version"], 1)
        self.assertEqual(evidence["dictionary_entries"], 235)


if __name__ == "__main__":
    unittest.main()
