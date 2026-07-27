"""Semantic validation for automatically generated local entries."""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Any, Iterable

from packages.japanese_normalizer.normalizer import deinflect, normalize_kana, normalize_text

from .providers import SearchResult
from .schema_validation import validate_schema


_KANA_RE = re.compile(r"[\u3040-\u30ff]")
_CHINESE_ONLY_MARKERS = re.compile(
    r"[這这個个們们為为於于與与還还請请讓让從从將将]|"
    r"(?:可以|沒有|没有|用於|用于|通過|通过|詞彙|词汇|意思是)"
)
_ABNORMAL_SPACE_RE = re.compile(r"\s{2,}")


@dataclass(frozen=True)
class ValidationIssue:
    path: str
    code: str
    message: str

    def to_json(self) -> dict[str, str]:
        return {
            "path": self.path,
            "code": self.code,
            "message": self.message,
            "severity": "error",
        }


def validate_generated_entry(
    entry: dict[str, Any],
    *,
    query: str,
    search_results: Iterable[SearchResult],
    existing_form_keys: Iterable[str] = (),
) -> list[dict[str, str]]:
    issues = [ValidationIssue(item["path"], item["code"], item["message"]) for item in validate_schema(entry)]
    sources = {item.source_id: item for item in search_results}
    existing = set(existing_form_keys)

    headword = entry.get("headword")
    forms = entry.get("forms") if isinstance(entry.get("forms"), list) else []
    readings = entry.get("readings") if isinstance(entry.get("readings"), list) else []
    parts = entry.get("parts_of_speech") if isinstance(entry.get("parts_of_speech"), list) else []
    senses = entry.get("senses") if isinstance(entry.get("senses"), list) else []
    source_ids = entry.get("source_ids") if isinstance(entry.get("source_ids"), list) else []

    if not _non_empty(headword):
        issues.append(ValidationIssue("$.headword", "required_headword", "詞頭不可為空白"))
    if not readings or not any(isinstance(item, dict) and _non_empty(item.get("kana")) for item in readings):
        issues.append(ValidationIssue("$.readings", "required_reading", "至少需要一個有效讀音"))
    if not parts or not all(_non_empty(item) for item in parts):
        issues.append(ValidationIssue("$.parts_of_speech", "required_part_of_speech", "至少需要一個有效詞性"))
    if not senses:
        issues.append(ValidationIssue("$.senses", "required_sense", "至少需要一個有效義項"))

    primary_forms = [
        item for item in forms if isinstance(item, dict) and item.get("type") == "primary"
    ]
    if len(primary_forms) != 1:
        issues.append(ValidationIssue("$.forms", "primary_form", "必須且只能有一個主要詞形"))
    primary_readings = [
        item for item in readings if isinstance(item, dict) and item.get("primary") is True
    ]
    if len(primary_readings) != 1:
        issues.append(ValidationIssue("$.readings", "primary_reading", "必須且只能有一個主要讀音"))

    form_values = [
        str(item.get("text", ""))
        for item in forms
        if isinstance(item, dict) and _non_empty(item.get("text"))
    ]
    reading_values = [
        str(item.get("kana", ""))
        for item in readings
        if isinstance(item, dict) and _non_empty(item.get("kana"))
    ]
    lookup_values = [value for value in [headword, *form_values, *reading_values] if _non_empty(value)]
    lookup_keys = {normalize_text(str(value)) for value in lookup_values}
    kana_keys = {normalize_kana(str(value)) for value in lookup_values}
    if existing.intersection(lookup_keys | kana_keys):
        issues.append(ValidationIssue("$.headword", "duplicate_entry", "本地資料庫已有相同詞條或詞形"))

    normalized_query = normalize_text(query)
    normalized_query_kana = normalize_kana(query)
    deinflected = {normalize_text(item.lemma) for item in deinflect(query)}
    if normalized_query not in lookup_keys and normalized_query_kana not in kana_keys and not deinflected.intersection(lookup_keys):
        issues.append(
            ValidationIssue(
                "$.headword",
                "query_lemma_mismatch",
                "查詢詞或其活用還原結果與模型回傳原形不一致",
            )
        )

    cited = set()
    for index, source_id in enumerate(source_ids):
        if not _non_empty(source_id) or source_id not in sources:
            issues.append(
                ValidationIssue(
                    f"$.source_ids[{index}]",
                    "unknown_search_source",
                    "引用來源不存在於本次網路搜尋結果",
                )
            )
        else:
            cited.add(source_id)
    generation = entry.get("generation") if isinstance(entry.get("generation"), dict) else {}
    embedded_sources = generation.get("sources") if isinstance(generation.get("sources"), list) else []
    embedded_ids = {
        item.get("source_id")
        for item in embedded_sources
        if isinstance(item, dict) and _non_empty(item.get("source_id"))
    }
    if embedded_ids != cited:
        issues.append(
            ValidationIssue(
                "$.generation.sources",
                "source_snapshot_mismatch",
                "生成資訊中的來源快照必須與詞條引用來源完全一致",
            )
        )
    if generation.get("source_count") != len(cited):
        issues.append(
            ValidationIssue(
                "$.generation.source_count",
                "source_count_mismatch",
                "來源數量與實際引用不一致",
            )
        )
    retrieved_source_count = generation.get("retrieved_source_count")
    retrieved_sources = (
        generation.get("retrieved_sources")
        if isinstance(generation.get("retrieved_sources"), list)
        else None
    )
    if retrieved_source_count is not None:
        if retrieved_source_count != len(sources):
            issues.append(
                ValidationIssue(
                    "$.generation.retrieved_source_count",
                    "retrieved_source_count_mismatch",
                    "檢索來源數量與本次搜尋結果不一致",
                )
            )
        retrieved_ids = {
            item.get("source_id")
            for item in retrieved_sources or []
            if isinstance(item, dict) and _non_empty(item.get("source_id"))
        }
        if retrieved_sources is None or retrieved_ids != set(sources):
            issues.append(
                ValidationIssue(
                    "$.generation.retrieved_sources",
                    "retrieved_source_snapshot_mismatch",
                    "檢索來源快照必須與本次搜尋結果完全一致",
                )
            )
    if generation.get("knowledge_only") != (len(cited) == 0):
        issues.append(
            ValidationIssue(
                "$.generation.knowledge_only",
                "knowledge_only_mismatch",
                "模型既有知識標記與實際引用來源不一致",
            )
        )

    seen_definitions: set[str] = set()
    for sense_index, sense in enumerate(senses):
        if not isinstance(sense, dict):
            continue
        sense_source_ids = (
            sense.get("source_ids")
            if isinstance(sense.get("source_ids"), list)
            else []
        )
        for source_index, source_id in enumerate(sense_source_ids):
            source_path = (
                f"$.senses[{sense_index}].source_ids[{source_index}]"
            )
            if not _non_empty(source_id) or source_id not in sources:
                issues.append(
                    ValidationIssue(
                        source_path,
                        "unknown_search_source",
                        "義項引用來源不存在於本次網路搜尋結果",
                    )
                )
            elif source_id not in cited:
                issues.append(
                    ValidationIssue(
                        source_path,
                        "undeclared_source",
                        "義項引用來源必須同時列於詞條 source_ids",
                    )
                )
        definition = sense.get("definition_ja_simple")
        definition_path = f"$.senses[{sense_index}].definition_ja_simple"
        if not _non_empty(definition):
            issues.append(ValidationIssue(definition_path, "blank_sense", "義項不可為空白"))
        else:
            definition_text = str(definition)
            normalized_definition = normalize_text(definition_text)
            if normalized_definition in seen_definitions:
                issues.append(ValidationIssue(definition_path, "duplicate_sense", "義項內容重複"))
            seen_definitions.add(normalized_definition)
            if not _KANA_RE.search(definition_text) or _CHINESE_ONLY_MARKERS.search(definition_text):
                issues.append(
                    ValidationIssue(
                        definition_path,
                        "definition_language",
                        "日文釋義疑似包含中文內容或缺少日文假名",
                    )
                )
            _validate_spacing(definition_text, definition_path, issues)

        examples = sense.get("examples") if isinstance(sense.get("examples"), list) else []
        for example_index, example in enumerate(examples):
            if not isinstance(example, dict):
                continue
            sentence = example.get("sentence")
            path = f"$.senses[{sense_index}].examples[{example_index}]"
            if not _non_empty(sentence):
                issues.append(ValidationIssue(f"{path}.sentence", "blank_example", "例句不可為空白"))
                continue
            sentence_text = str(sentence)
            if not _example_matches(sentence_text, lookup_values, parts):
                issues.append(
                    ValidationIssue(
                        f"{path}.sentence",
                        "irrelevant_example",
                        "例句未包含目標詞彙或其合理活用形式",
                    )
                )
            example_source = example.get("source_id")
            if example_source is not None and example_source not in sources:
                issues.append(
                    ValidationIssue(
                        f"{path}.source_id",
                        "unknown_search_source",
                        "例句引用來源不存在於本次網路搜尋結果",
                    )
                )
            elif example_source is not None and example_source not in cited:
                issues.append(
                    ValidationIssue(
                        f"{path}.source_id",
                        "undeclared_source",
                        "例句引用來源必須同時列於詞條 source_ids",
                    )
                )
            _validate_spacing(sentence_text, f"{path}.sentence", issues)

    return _deduplicate(item.to_json() for item in issues)


def _example_matches(sentence: str, lookup_values: list[Any], parts: list[Any]) -> bool:
    normalized_sentence = normalize_text(sentence)
    for value in lookup_values:
        normalized = normalize_text(str(value))
        if normalized and normalized in normalized_sentence:
            return True
    is_inflecting = any(
        isinstance(part, str)
        and (part.startswith("verb") or part.startswith("adjective"))
        for part in parts
    )
    if is_inflecting:
        for value in lookup_values:
            normalized = normalize_text(str(value))
            stem = normalized[:-1] if len(normalized) >= 3 else ""
            if stem and stem in normalized_sentence:
                return True
    return False


def _validate_spacing(
    value: str,
    path: str,
    issues: list[ValidationIssue],
) -> None:
    if value != value.strip() or _ABNORMAL_SPACE_RE.search(value):
        issues.append(ValidationIssue(path, "abnormal_whitespace", "內容含首尾或連續空白"))


def _non_empty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _deduplicate(items: Iterable[dict[str, str]]) -> list[dict[str, str]]:
    seen: set[tuple[str, str, str]] = set()
    result: list[dict[str, str]] = []
    for item in items:
        key = (item["path"], item["code"], item["message"])
        if key in seen:
            continue
        seen.add(key)
        result.append(item)
    return result
