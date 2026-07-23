from __future__ import annotations

import copy
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from packages.dictionary_schema import (
    assert_valid_dictionary,
    sha256_file,
    validate_dictionary,
    validate_release_manifest,
    verify_release_artifacts,
)
from packages.japanese_normalizer import (
    deinflect,
    hiragana_to_katakana,
    katakana_to_hiragana,
    normalize_kana,
    normalize_text,
    query_variants,
    romaji_to_hiragana,
)
from packages.search_engine import SearchEngine
from tools.database_builder import build_database, write_release_artifacts


ROOT = Path(__file__).resolve().parents[1]
FIXTURE_PATH = ROOT / "data" / "fixtures" / "dictionary.json"
GOLDEN_PATH = ROOT / "data" / "fixtures" / "normalization_golden.json"


def mark_all_human_approved(document: dict[str, object]) -> None:
    for entry in document["entries"]:  # type: ignore[index]
        entry["edit_status"] = "approved"
        entry["review"] = {
            "status": "approved",
            "reviewed_by": "human-editor-001",
            "reviewed_at": "2026-07-22T01:00:00Z",
            "notes": "Language, examples, relations, and provenance reviewed.",
        }
        for sense in entry["senses"]:
            sense["review_status"] = "approved"


class NormalizerTests(unittest.TestCase):
    def test_unicode_width_space_punctuation_and_kana(self) -> None:
        self.assertEqual(normalize_text("  Ｔａｂｅｒｕ。 "), "taberu")
        self.assertEqual(normalize_kana(" ｶﾞｯｺｳ "), "がっこう")
        self.assertEqual(normalize_kana("コーヒー"), "こおひい")
        self.assertEqual(katakana_to_hiragana("ヴァイオリン"), "ゔぁいおりん")
        self.assertEqual(hiragana_to_katakana("がっこう"), "ガッコウ")

    def test_romaji_examples(self) -> None:
        expected = {
            "taberu": "たべる",
            "hirou": "ひろう",
            "hirowu": "ひろう",
            "gakkou": "がっこう",
            "shimbun": "しんぶん",
            "shinbun": "しんぶん",
        }
        for value, kana in expected.items():
            with self.subTest(value=value):
                self.assertEqual(romaji_to_hiragana(value)[0], kana)

    def test_golden_conformance_fixture(self) -> None:
        golden = json.loads(GOLDEN_PATH.read_text(encoding="utf-8"))
        for case in golden["cases"]:
            with self.subTest(value=case["input"]):
                variants = query_variants(case["input"])
                self.assertEqual(variants["normalized"][0], case["normalized"])
                self.assertEqual(variants["kana"][0], case["kana"])
                self.assertEqual(list(variants["romaji"]), case["romaji"])

    def test_verb_and_adjective_deinflection(self) -> None:
        cases = {
            "食べました": "食べる",
            "食べられない": "食べる",
            "拾って": "拾う",
            "拾える": "拾う",
            "行かなかった": "行く",
            "高かった": "高い",
            "高くない": "高い",
            "静かだった": "静か",
        }
        for inflected, lemma in cases.items():
            with self.subTest(inflected=inflected):
                self.assertIn(lemma, {item.lemma for item in deinflect(inflected)})


class SchemaAndBuilderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.document = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))

    def test_fixture_is_valid_and_has_safe_coverage(self) -> None:
        assert_valid_dictionary(self.document)
        self.assertGreaterEqual(len(self.document["entries"]), 20)
        self.assertTrue(all(entry["edit_status"] == "ai_draft" for entry in self.document["entries"]))
        source = self.document["sources"][0]
        self.assertEqual(source["license_spdx"], "CC0-1.0")
        self.assertTrue(source["ai_assisted"])

    def test_schema_file_is_canonical_json_schema(self) -> None:
        schema = json.loads((ROOT / "packages" / "dictionary_schema" / "schema.json").read_text(encoding="utf-8"))
        self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertEqual(schema["properties"]["schema_version"]["const"], 1)

    def test_duplicate_and_relation_integrity_are_reported_together(self) -> None:
        bad = copy.deepcopy(self.document)
        bad["entries"][1]["entry_id"] = bad["entries"][0]["entry_id"]
        bad["entries"][0]["senses"][0]["relations"][0]["entry_id"] = "missing"
        codes = {issue.code for issue in validate_dictionary(bad)}
        self.assertIn("duplicate_id", codes)
        self.assertIn("unknown_entry", codes)

    def test_ai_content_cannot_be_approved_directly(self) -> None:
        bad = copy.deepcopy(self.document)
        bad["entries"][0]["edit_status"] = "published"
        self.assertIn("ai_review_gate", {issue.code for issue in validate_dictionary(bad)})

    def test_ai_content_with_human_review_can_be_approved(self) -> None:
        reviewed = copy.deepcopy(self.document)
        entry = reviewed["entries"][0]
        entry["edit_status"] = "approved"
        entry["review"] = {
            "status": "approved",
            "reviewed_by": "human-editor-001",
            "reviewed_at": "2026-07-22T01:00:00Z",
            "notes": "Language, examples, relations, and provenance reviewed.",
        }
        for sense in entry["senses"]:
            sense["review_status"] = "approved"
        assert_valid_dictionary(reviewed)

    def test_ai_review_status_mismatch_remains_blocked(self) -> None:
        for mismatched_field in ("entry_review", "sense_review"):
            with self.subTest(mismatched_field=mismatched_field):
                bad = copy.deepcopy(self.document)
                entry = bad["entries"][0]
                entry["edit_status"] = "approved"
                entry["review"] = {
                    "status": "approved",
                    "reviewed_by": "human-editor-001",
                    "reviewed_at": "2026-07-22T01:00:00Z",
                    "notes": "Review evidence present.",
                }
                for sense in entry["senses"]:
                    sense["review_status"] = "approved"
                if mismatched_field == "entry_review":
                    entry["review"]["status"] = "reviewed"
                else:
                    entry["senses"][0]["review_status"] = "reviewed"
                self.assertIn("ai_review_gate", {issue.code for issue in validate_dictionary(bad)})

    def test_unlicensed_media_is_release_blocking(self) -> None:
        bad = copy.deepcopy(self.document)
        bad["entries"][0]["senses"][0]["image_assets"].append(
            {
                "asset_id": "unsafe_image",
                "source_id": "missing_source",
                "license_spdx": "NOASSERTION",
                "redistribution_allowed": False,
                "sha256": "not-a-checksum",
                "path": "unsafe.jpg",
                "kind": "image",
            }
        )
        codes = {issue.code for issue in validate_dictionary(bad)}
        self.assertTrue({"redistribution_blocked", "checksum", "unknown_source"}.issubset(codes))

    def test_asset_path_traversal_is_rejected(self) -> None:
        unsafe_paths = (
            "../../outside.png", "/absolute.png", "C:/windows.png",
            "images\\escape.png", "images/\x00bad.png", "", "images//bad.png", "images/./bad.png",
        )
        for index, unsafe_path in enumerate(unsafe_paths):
            with self.subTest(path=repr(unsafe_path)):
                bad = copy.deepcopy(self.document)
                bad["entries"][0]["senses"][0]["image_assets"].append(
                    {
                        "asset_id": f"unsafe_image_{index}",
                        "source_id": "kotoba_fixture_original_cc0",
                        "license_spdx": "CC0-1.0",
                        "redistribution_allowed": True,
                        "sha256": "0" * 64,
                        "path": unsafe_path,
                        "kind": "image",
                    }
                )
                issues = validate_dictionary(bad)
                self.assertIn("unsafe_asset_path", {issue.code for issue in issues})
                with self.assertRaisesRegex(ValueError, "unsafe_asset_path"):
                    assert_valid_dictionary(bad)

    def test_database_is_reproducible_and_keeps_canonical_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.sqlite"
            second = Path(directory) / "second.sqlite"
            report_a = build_database(self.document, first)
            report_b = build_database(self.document, second)
            self.assertEqual(report_a.database_sha256, report_b.database_sha256)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            connection = sqlite3.connect(first)
            row = connection.execute(
                "SELECT payload_json FROM entries WHERE entry_id = ?",
                (self.document["entries"][0]["entry_id"],),
            ).fetchone()
            connection.close()
            self.assertEqual(json.loads(row[0]), self.document["entries"][0])
            self.assertEqual(report_a.entries, 24)
            self.assertEqual(report_a.examples, 25)

    def test_release_gate_and_development_bypass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "build.sqlite"
            release = root / "release"
            build_database(self.document, database)
            with self.assertRaisesRegex(ValueError, "release blocked"):
                write_release_artifacts(self.document, database, release)
            manifest = write_release_artifacts(
                self.document, database, release, allow_unreviewed=True
            )
            self.assertEqual(manifest["channel"], "development")
            self.assertEqual(manifest["content_status"], "contains_unreviewed")
            self.assertEqual(validate_release_manifest(manifest), [])
            self.assertEqual(verify_release_artifacts(release), manifest)

    def test_fully_reviewed_and_license_cleared_release_is_allowed(self) -> None:
        reviewed = copy.deepcopy(self.document)
        mark_all_human_approved(reviewed)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "build.sqlite"
            release = root / "release"
            build_database(reviewed, database)
            manifest = write_release_artifacts(reviewed, database, release)
            self.assertEqual(manifest["channel"], "release")
            self.assertEqual(manifest["content_status"], "reviewed")
            self.assertEqual(manifest["license_status"], "cleared")
            self.assertEqual(verify_release_artifacts(release), manifest)

    def test_uncleared_referenced_source_is_development_only(self) -> None:
        unsafe = copy.deepcopy(self.document)
        mark_all_human_approved(unsafe)
        source = unsafe["sources"][0]
        source.update(
            {
                "source_type": "open_data",
                "license_spdx": "NOASSERTION",
                "original_url": None,
                "retrieved_at": "2026-07-22T00:00:00Z",
                "redistribution_allowed": False,
                "modification_allowed": True,
                "commercial_use_allowed": True,
                "attribution_required": True,
            }
        )
        warnings = [issue for issue in validate_dictionary(unsafe) if issue.severity == "warning"]
        self.assertTrue({"uncleared_license", "redistribution_blocked", "attribution_metadata"}.issubset({issue.code for issue in warnings}))
        assert_valid_dictionary(unsafe)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "build.sqlite"
            release = root / "release"
            build_database(unsafe, database)
            with self.assertRaisesRegex(ValueError, "license-cleared"):
                write_release_artifacts(unsafe, database, release)
            manifest = write_release_artifacts(
                unsafe, database, release, allow_unreviewed=True
            )
            self.assertEqual(manifest["channel"], "development")
            self.assertEqual(manifest["content_status"], "reviewed")
            self.assertEqual(manifest["license_status"], "contains_uncleared")
            self.assertEqual(verify_release_artifacts(release), manifest)

    def test_uncleared_media_is_development_only(self) -> None:
        unsafe = copy.deepcopy(self.document)
        mark_all_human_approved(unsafe)
        unsafe["entries"][0]["senses"][0]["image_assets"].append(
            {
                "asset_id": "uncleared_image",
                "source_id": "kotoba_fixture_original_cc0",
                "license_spdx": "NOASSERTION",
                "redistribution_allowed": False,
                "sha256": "0" * 64,
                "path": "images/uncleared.png",
                "kind": "image",
            }
        )
        assert_valid_dictionary(unsafe)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "build.sqlite"
            release = root / "release"
            build_database(unsafe, database)
            with self.assertRaisesRegex(ValueError, "license-cleared"):
                write_release_artifacts(unsafe, database, release)
            manifest = write_release_artifacts(
                unsafe, database, release, allow_unreviewed=True
            )
            self.assertEqual(manifest["license_status"], "contains_uncleared")
            self.assertEqual(verify_release_artifacts(release), manifest)

    def test_checksum_tampering_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "build.sqlite"
            release = root / "release"
            build_database(self.document, database)
            write_release_artifacts(self.document, database, release, allow_unreviewed=True)
            with (release / "dictionary.sqlite").open("ab") as handle:
                handle.write(b"tampered")
            with self.assertRaisesRegex(ValueError, "size mismatch"):
                verify_release_artifacts(release)

    def test_self_consistent_non_sqlite_payload_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "build.sqlite"
            release = root / "release"
            build_database(self.document, database)
            write_release_artifacts(self.document, database, release, allow_unreviewed=True)
            release_database = release / "dictionary.sqlite"
            release_database.write_bytes(b"not a sqlite database")
            manifest_path = release / "release-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["database_size"] = release_database.stat().st_size
            manifest["database_sha256"] = sha256_file(release_database)
            manifest_path.write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            checksum_names = ("dictionary.sqlite", "assets-manifest.json", "release-manifest.json")
            (release / "checksums.txt").write_text(
                "".join(f"{sha256_file(release / name)}  {name}\n" for name in checksum_names),
                encoding="utf-8",
                newline="\n",
            )
            with self.assertRaisesRegex(ValueError, "SQLite health check"):
                verify_release_artifacts(release)


class SearchGoldenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temporary = tempfile.TemporaryDirectory()
        document = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        cls.database = Path(cls.temporary.name) / "dictionary.sqlite"
        build_database(document, cls.database)
        cls.engine = SearchEngine(cls.database)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.engine.close()
        cls.temporary.cleanup()

    def test_exact_reading_romaji_normalized_and_inflection(self) -> None:
        cases = {
            "食べる": ("食べる", "primary_exact"),
            "たべる": ("食べる", "reading_exact"),
            "taberu": ("食べる", "romaji"),
            "食べました": ("食べる", "deinflection"),
            "食べられない": ("食べる", "deinflection"),
            "拾って": ("拾う", "deinflection"),
            "行かなかった": ("行く", "deinflection"),
            "ガッコウ": ("学校", "normalized_exact"),
            "gakkou": ("学校", "romaji"),
            "shimbun": ("新聞", "romaji"),
            "shinbun": ("新聞", "romaji"),
            "hirowu": ("拾う", "romaji"),
            "高かった": ("高い", "deinflection"),
            "静かだった": ("静か", "deinflection"),
        }
        for query, expected in cases.items():
            with self.subTest(query=query):
                result = self.engine.search(query, debug=True)[0]
                self.assertEqual((result.headword, result.match_type), expected)
                self.assertTrue(result.evidence)

    def test_ambiguity_is_ranked_by_frequency(self) -> None:
        results = self.engine.search("あう", limit=3)
        self.assertEqual([item.headword for item in results], ["会う", "合う", "遭う"])

    def test_debug_score_is_reproducible(self) -> None:
        first = self.engine.search("食べました", debug=True)[0]
        second = self.engine.search("食べました", debug=True)[0]
        self.assertEqual(first, second)
        self.assertEqual(first.evidence[0].base_score, 800)
        self.assertIsNotNone(first.evidence[0].deinflection_reason)

    def test_empty_and_no_match(self) -> None:
        self.assertEqual(self.engine.search("   "), [])
        self.assertEqual(self.engine.search("存在しない語"), [])


if __name__ == "__main__":
    unittest.main()
