"""Validate and execute the fixed Kotoba search-acceptance corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import tempfile
from typing import Any

from packages.dictionary_schema import assert_valid_dictionary
from packages.japanese_normalizer import deinflect, normalize_text
from packages.search_engine import SearchEngine
from tools.database_builder import build_database


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CORPUS = ROOT / "data" / "fixtures" / "search_acceptance_v1.json"
MINIMUM_COUNTS = {
    "common_words": 100,
    "verb_inflections": 50,
    "adjective_inflections": 20,
    "katakana": 20,
    "romaji": 20,
    "ambiguity": 20,
    "negative": 20,
}
_ROMAJI = re.compile(r"^[A-Za-zāīūēōĀĪŪĒŌ' -]+$")


class CorpusError(ValueError):
    """Raised when the acceptance corpus does not satisfy its contract."""


def _content_checksum(corpus: dict[str, Any]) -> str:
    content = {
        "lexicon": corpus["lexicon"],
        "categories": corpus["categories"],
    }
    return hashlib.sha256(
        json.dumps(
            content,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()


def validate_corpus(corpus: dict[str, Any]) -> dict[str, int]:
    """Validate schema, anti-padding invariants, references, and checksum."""

    required_root = {
        "schema_version",
        "corpus_id",
        "search_rules_version",
        "normalizer_version",
        "content_sha256",
        "lexicon",
        "categories",
    }
    missing_root = sorted(required_root - corpus.keys())
    if missing_root:
        raise CorpusError(f"missing root fields: {missing_root}")
    if corpus["schema_version"] != 1:
        raise CorpusError("unsupported corpus schema_version")
    if corpus["search_rules_version"] != 1 or corpus["normalizer_version"] != 1:
        raise CorpusError("corpus/runtime version mismatch")
    actual_checksum = _content_checksum(corpus)
    if corpus["content_sha256"] != actual_checksum:
        raise CorpusError(
            f"content checksum mismatch: {corpus['content_sha256']} != {actual_checksum}"
        )

    lexicon = corpus["lexicon"]
    if not isinstance(lexicon, list) or not lexicon:
        raise CorpusError("lexicon must be a non-empty list")
    ids: set[str] = set()
    lexical_pairs: set[tuple[str, str]] = set()
    lexicon_by_id: dict[str, dict[str, Any]] = {}
    for row in lexicon:
        required = {
            "entry_id",
            "headword",
            "reading",
            "part_of_speech",
            "frequency_rank",
        }
        if not isinstance(row, dict) or required - row.keys():
            raise CorpusError(f"invalid lexicon row: {row!r}")
        if (
            not all(
                isinstance(row[field], str) and row[field].strip()
                for field in ("entry_id", "headword", "reading", "part_of_speech")
            )
            or not isinstance(row["frequency_rank"], int)
            or row["frequency_rank"] < 1
        ):
            raise CorpusError(f"empty or invalid lexicon field: {row!r}")
        if row["entry_id"] in ids:
            raise CorpusError(f"duplicate entry_id: {row['entry_id']}")
        pair = (row["headword"], row["reading"])
        if pair in lexical_pairs:
            raise CorpusError(f"duplicate lexical pair: {pair}")
        ids.add(row["entry_id"])
        lexical_pairs.add(pair)
        lexicon_by_id[row["entry_id"]] = row

    categories = corpus["categories"]
    if not isinstance(categories, dict):
        raise CorpusError("categories must be an object")
    unknown = sorted(set(categories) - set(MINIMUM_COUNTS))
    missing = sorted(set(MINIMUM_COUNTS) - set(categories))
    if unknown or missing:
        raise CorpusError(f"category mismatch; missing={missing}, unknown={unknown}")

    all_case_ids: set[str] = set()
    statistics: dict[str, int] = {}
    for category, minimum in MINIMUM_COUNTS.items():
        cases = categories[category]
        if not isinstance(cases, list) or len(cases) < minimum:
            raise CorpusError(
                f"{category} requires at least {minimum} cases, got "
                f"{len(cases) if isinstance(cases, list) else 'non-list'}"
            )
        queries: set[str] = set()
        expected_distinct: set[str] = set()
        for case in cases:
            required = {
                "case_id",
                "raw_query",
                "input_context",
                "expected_entry_ids",
                "forbidden_entry_ids",
                "note",
            }
            if not isinstance(case, dict) or required - case.keys():
                raise CorpusError(f"invalid {category} case: {case!r}")
            case_id = case["case_id"]
            query = case["raw_query"]
            if not isinstance(case_id, str) or not case_id:
                raise CorpusError(f"empty case_id in {category}")
            if case_id in all_case_ids:
                raise CorpusError(f"duplicate case_id: {case_id}")
            all_case_ids.add(case_id)
            if (
                not isinstance(query, str)
                or not query.strip()
                or not normalize_text(query)
            ):
                raise CorpusError(f"empty effective query: {case_id}")
            if query in queries:
                raise CorpusError(f"duplicate query in {category}: {query}")
            queries.add(query)
            expected = case["expected_entry_ids"]
            forbidden = case["forbidden_entry_ids"]
            if (
                not isinstance(expected, list)
                or not isinstance(forbidden, list)
                or any(item not in ids for item in expected + forbidden)
            ):
                raise CorpusError(f"unknown or invalid entry reference: {case_id}")
            if set(expected) & set(forbidden):
                raise CorpusError(f"expected/forbidden overlap: {case_id}")
            expected_distinct.update(expected)
            if not isinstance(case["note"], str) or not case["note"].strip():
                raise CorpusError(f"missing rationale: {case_id}")

        if len(queries) != len(cases):
            raise CorpusError(f"{category} contains duplicate/empty query padding")
        if category in {
            "common_words",
            "verb_inflections",
            "adjective_inflections",
            "katakana",
            "romaji",
        } and len(expected_distinct) < minimum:
            raise CorpusError(
                f"{category} must exercise {minimum} distinct entries, got "
                f"{len(expected_distinct)}"
            )
        if category == "ambiguity":
            if any(len(case["expected_entry_ids"]) < 2 for case in cases):
                raise CorpusError("every ambiguity case requires at least two entries")
            if len(expected_distinct) < 40:
                raise CorpusError(
                    f"ambiguity corpus requires >=40 distinct alternatives, got "
                    f"{len(expected_distinct)}"
                )
            for case in cases:
                readings = {
                    lexicon_by_id[entry_id]["reading"]
                    for entry_id in case["expected_entry_ids"]
                }
                if readings != {case["raw_query"]}:
                    raise CorpusError(
                        f"ambiguity alternatives do not share query reading: "
                        f"{case['case_id']}"
                    )
        if category == "negative" and any(
            case["expected_entry_ids"] for case in cases
        ):
            raise CorpusError("negative cases cannot contain expected entries")
        if category == "romaji" and any(
            not _ROMAJI.fullmatch(case["raw_query"]) for case in cases
        ):
            raise CorpusError("romaji category contains a non-romaji query")
        if category in {"verb_inflections", "adjective_inflections"}:
            for case in cases:
                expected_id = case["expected_entry_ids"][0]
                expected_lemma = lexicon_by_id[expected_id]["headword"]
                if case.get("expected_analysis_lemma") != expected_lemma:
                    raise CorpusError(
                        f"analysis lemma mismatch: {case['case_id']}"
                    )
                if case["raw_query"] == expected_lemma:
                    raise CorpusError(
                        f"uninﬂected padding in inflection corpus: {case['case_id']}"
                    )
        statistics[category] = len(cases)
    statistics["lexicon_entries"] = len(lexicon)
    statistics["total_cases"] = sum(
        statistics[category] for category in MINIMUM_COUNTS
    )
    return statistics


def load_corpus(path: str | Path = DEFAULT_CORPUS) -> dict[str, Any]:
    corpus = json.loads(Path(path).read_text(encoding="utf-8"))
    validate_corpus(corpus)
    return corpus


def corpus_to_canonical(corpus: dict[str, Any]) -> dict[str, Any]:
    """Convert acceptance-only lexicon rows into the canonical data contract."""

    validate_corpus(corpus)
    source_id = "kotoba_search_acceptance_cc0"
    entries: list[dict[str, Any]] = []
    for row in corpus["lexicon"]:
        entry_id = row["entry_id"]
        headword = row["headword"]
        reading = row["reading"]
        forms = [{"text": headword, "type": "primary", "common": True}]
        if reading != headword:
            forms.append({"text": reading, "type": "kana", "common": True})
        sense_id = f"{entry_id}:sense:001"
        entries.append(
            {
                "entry_id": entry_id,
                "headword": headword,
                "forms": forms,
                "readings": [{"kana": reading, "primary": True}],
                "parts_of_speech": [row["part_of_speech"]],
                "frequency_rank": row["frequency_rank"],
                "editorial_level": "curated",
                "edit_status": "ai_draft",
                "senses": [
                    {
                        "sense_id": sense_id,
                        "order": 1,
                        "definition_ja_simple": (
                            f"検索受入試験で「{headword}」を識別するための固定項目。"
                        ),
                        "usage_note_ja": "QA fixture。公開辞典内容には使用しない。",
                        "register": "test",
                        "importance": "primary",
                        "examples": [
                            {
                                "example_id": f"{entry_id}:example:001",
                                "sentence": (
                                    f"検索受入試験で「{headword}」を確認する。"
                                ),
                                "source_id": source_id,
                                "audio_asset_id": None,
                            }
                        ],
                        "relations": [],
                        "image_assets": [],
                        "audio_assets": [],
                        "source_ids": [source_id],
                        "review_status": "ai_draft",
                    }
                ],
                "source_ids": [source_id],
                "review": {
                    "status": "ai_draft",
                    "reviewed_by": None,
                    "reviewed_at": None,
                    "notes": "Machine acceptance corpus; not release content.",
                },
                "created_at": "2026-07-23T00:00:00Z",
                "updated_at": "2026-07-23T00:00:00Z",
                "data_version": "search-acceptance-v1",
            }
        )
    document = {
        "schema_version": 1,
        "dictionary_version": "search-acceptance-v1",
        "sources": [
            {
                "source_id": source_id,
                "title": "Kotoba fixed search acceptance corpus",
                "source_type": "original",
                "author": "Kotoba project QA (AI-assisted draft)",
                "license_spdx": "CC0-1.0",
                "license_url": (
                    "https://creativecommons.org/publicdomain/zero/1.0/"
                ),
                "original_url": None,
                "retrieved_at": None,
                "redistribution_allowed": True,
                "modification_allowed": True,
                "commercial_use_allowed": True,
                "attribution_required": False,
                "ai_assisted": True,
                "notes": (
                    "Search-only QA fixture. Human linguistic review is still "
                    "required before any row may be reused as release content."
                ),
            }
        ],
        "entries": entries,
    }
    assert_valid_dictionary(document)
    return document


def verify_runtime(
    corpus: dict[str, Any], database_path: str | Path
) -> dict[str, Any]:
    """Build canonical SQLite and execute all acceptance cases twice."""

    statistics = validate_corpus(corpus)
    document = corpus_to_canonical(corpus)
    report = build_database(document, database_path)
    categories = corpus["categories"]
    failures: list[str] = []
    explanation_checks = 0
    deterministic_checks = 0
    with SearchEngine(database_path) as engine:
        for category in (
            "common_words",
            "verb_inflections",
            "adjective_inflections",
            "katakana",
            "romaji",
            "ambiguity",
            "negative",
        ):
            for case in categories[category]:
                query = case["raw_query"]
                first = engine.search(query, limit=20, debug=True)
                second = engine.search(query, limit=20, debug=True)
                deterministic_checks += 1
                if first != second:
                    failures.append(f"{case['case_id']}: nondeterministic result")
                    continue
                actual_ids = [result.entry_id for result in first]
                expected_ids = case["expected_entry_ids"]
                if category == "negative":
                    if actual_ids:
                        failures.append(
                            f"{case['case_id']}: expected no result, got {actual_ids}"
                        )
                    continue
                if actual_ids[: len(expected_ids)] != expected_ids:
                    failures.append(
                        f"{case['case_id']}: expected prefix {expected_ids}, "
                        f"got {actual_ids}"
                    )
                    continue
                if any(
                    forbidden in actual_ids
                    for forbidden in case["forbidden_entry_ids"]
                ):
                    failures.append(
                        f"{case['case_id']}: returned forbidden entry"
                    )
                expected_kind = case.get("expected_match_kind")
                if expected_kind is not None and first[0].match_type != expected_kind:
                    failures.append(
                        f"{case['case_id']}: expected {expected_kind}, "
                        f"got {first[0].match_type}"
                    )
                evidence = first[0].evidence
                if not evidence:
                    failures.append(f"{case['case_id']}: missing debug evidence")
                    continue
                top = evidence[0]
                if (
                    not top.matched_key
                    or not top.match_type
                    or top.base_score <= 0
                    or top.final_score != first[0].score
                    or top.final_score
                    != top.base_score + sum(value for _, value in top.modifiers)
                ):
                    failures.append(
                        f"{case['case_id']}: incomplete/inconsistent score trace"
                    )
                    continue
                explanation_checks += 1
                if category in {"verb_inflections", "adjective_inflections"}:
                    expected_lemma = case["expected_analysis_lemma"]
                    candidates = deinflect(query)
                    if expected_lemma not in {
                        candidate.lemma for candidate in candidates
                    }:
                        failures.append(
                            f"{case['case_id']}: normalizer did not produce "
                            f"{expected_lemma}"
                        )
                    if (
                        first[0].deinflected_from != query
                        or top.deinflection_reason is None
                        or top.deinflection_confidence is None
                    ):
                        failures.append(
                            f"{case['case_id']}: missing deinflection analysis"
                        )

    if failures:
        preview = "\n".join(failures[:25])
        remainder = len(failures) - min(25, len(failures))
        if remainder:
            preview += f"\n... and {remainder} more"
        raise CorpusError(f"search acceptance failed:\n{preview}")
    return {
        **statistics,
        "corpus_id": corpus["corpus_id"],
        "content_sha256": corpus["content_sha256"],
        "canonical_schema_version": document["schema_version"],
        "dictionary_entries": report.entries,
        "database_sha256": report.database_sha256,
        "deterministic_checks": deterministic_checks,
        "explanation_checks": explanation_checks,
        "failures": 0,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument(
        "--database",
        type=Path,
        help="retain the generated canonical acceptance SQLite database",
    )
    args = parser.parse_args(argv)
    corpus = load_corpus(args.corpus)
    if args.database is not None:
        args.database.parent.mkdir(parents=True, exist_ok=True)
        result = verify_runtime(corpus, args.database)
    else:
        with tempfile.TemporaryDirectory(prefix="kotoba-search-acceptance-") as root:
            result = verify_runtime(corpus, Path(root) / "acceptance.sqlite")
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
