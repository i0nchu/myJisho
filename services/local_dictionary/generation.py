"""Search, LLM generation, normalization and validation orchestration."""

from __future__ import annotations

import copy
from datetime import datetime, timezone
import hashlib
import json
import re
from typing import Any, Iterable

from packages.japanese_normalizer.normalizer import deinflect, normalize_text

from .providers import LLMProvider, SearchProvider, SearchResult
from .validation import validate_generated_entry


GENERATOR_VERSION = "myjisho-local-2"
_READING_HINT_RE = re.compile(r"[\s（(]([ぁ-ゖゝゞー・]{2,32})[）)]")
_SEARCH_RESULT_LIMIT = 6
_SEARCH_TERM_LIMIT = 6
_LEMMA_TERM_LIMIT = 4
_NON_REPAIRABLE_ISSUE_CODES = {"duplicate_entry"}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class GenerationError(RuntimeError):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        issues: list[dict[str, str]] | None = None,
        retryable: bool = True,
    ):
        super().__init__(message)
        self.code = code
        self.issues = issues or []
        self.retryable = retryable

    def to_json(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "message": str(self),
            "issues": self.issues,
            "retryable": self.retryable,
        }


class DictionaryGenerator:
    def __init__(self, search: SearchProvider, llm: LLMProvider):
        self.search = search
        self.llm = llm

    def generate(
        self,
        query: str,
        *,
        origin: str = "generated",
        existing_entry: dict[str, Any] | None = None,
        existing_form_keys: Iterable[str] = (),
    ) -> dict[str, Any]:
        normalized_query = query.strip()
        if not normalized_query:
            raise GenerationError("empty_query", "查詢不可為空白", retryable=False)
        existing_form_keys = tuple(existing_form_keys)
        try:
            search_results, search_terms = self._search(normalized_query)
        except Exception as error:
            raise GenerationError("search_failed", f"網路搜尋失敗：{error}") from error
        user_prompt = _user_prompt(normalized_query, search_results, search_terms)
        try:
            draft = self.llm.generate_json(
                system_prompt=_SYSTEM_PROMPT,
                user_prompt=user_prompt,
            )
            if (
                search_results
                and not _draft_source_ids(draft)
                and _has_exact_source(search_results, search_terms)
            ):
                draft = self.llm.generate_json(
                    system_prompt=_SYSTEM_PROMPT,
                    user_prompt=(
                        f"{user_prompt}\n"
                        "前回の回答は、見出しと一致する検索資料があるのに source_ids が空でした。"
                        "定義・読み・表記を直接裏付ける資料だけを選び、詞条と各義項の "
                        "source_ids に同じ ID を入れて、JSON 全体を作り直してください。"
                    ),
                )
        except Exception as error:
            raise GenerationError("llm_failed", f"模型生成失敗：{error}") from error
        entry = self._canonicalize(
            draft,
            search_results=search_results,
            origin=origin,
            existing_entry=existing_entry,
        )
        issues = validate_generated_entry(
            entry,
            query=normalized_query,
            search_results=search_results,
            existing_form_keys=existing_form_keys,
        )
        if issues and not any(
            item.get("code") in _NON_REPAIRABLE_ISSUE_CODES
            for item in issues
        ):
            try:
                draft = self.llm.generate_json(
                    system_prompt=_SYSTEM_PROMPT,
                    user_prompt=_repair_prompt(
                        user_prompt,
                        draft,
                        issues,
                    ),
                )
            except Exception as error:
                raise GenerationError(
                    "llm_failed",
                    f"模型修復驗證錯誤時失敗：{error}",
                ) from error
            entry = self._canonicalize(
                draft,
                search_results=search_results,
                origin=origin,
                existing_entry=existing_entry,
            )
            issues = validate_generated_entry(
                entry,
                query=normalized_query,
                search_results=search_results,
                existing_form_keys=existing_form_keys,
            )
        if issues:
            raise GenerationError(
                "validation_failed",
                "模型回傳內容未通過自動驗證",
                issues=issues,
            )
        return entry

    def _search(self, query: str) -> tuple[list[SearchResult], list[str]]:
        results: list[SearchResult] = []
        failures: list[Exception] = []

        def search_term(term: str) -> list[SearchResult]:
            try:
                matches = self.search.search(
                    term,
                    limit=_SEARCH_RESULT_LIMIT,
                )
                results.extend(matches)
                return matches
            except Exception as error:
                failures.append(error)
                return []

        raw_term = query.strip()
        raw_results = search_term(raw_term)
        raw_key = normalize_text(raw_term)
        raw_exact = any(
            normalize_text(item.title) == raw_key
            for item in raw_results
        )
        lemma_terms = [] if raw_exact else _lemma_search_terms(query)
        search_terms = _unique_terms([*lemma_terms, raw_term])
        for term in lemma_terms:
            if normalize_text(term) == raw_key:
                continue
            search_term(term)

        for hint in _reading_hints(results, search_terms):
            if len(search_terms) >= _SEARCH_TERM_LIMIT:
                break
            search_terms.append(hint)
            search_term(hint)

        if not results and failures:
            raise failures[-1]
        return (
            _rank_search_results(results, search_terms)[:_SEARCH_RESULT_LIMIT],
            search_terms,
        )

    def _canonicalize(
        self,
        draft: dict[str, Any],
        *,
        search_results: list[SearchResult],
        origin: str,
        existing_entry: dict[str, Any] | None,
    ) -> dict[str, Any]:
        now = _now()
        result_by_id = {item.source_id: item for item in search_results}
        cited_ids = list(
            dict.fromkeys(
                source_id
                for source_id in draft.get("source_ids", [])
                if isinstance(source_id, str)
            )
        )
        headword = draft.get("headword", "")
        entry_id = (
            existing_entry["entry_id"]
            if existing_entry
            else f"entry_generated_{hashlib.sha256(normalize_text(str(headword)).encode('utf-8')).hexdigest()[:20]}"
        )
        senses: list[dict[str, Any]] = []
        raw_senses = draft.get("senses", [])
        if isinstance(raw_senses, list):
            for index, raw_sense in enumerate(raw_senses, start=1):
                if not isinstance(raw_sense, dict):
                    continue
                examples: list[dict[str, Any]] = []
                raw_examples = raw_sense.get("examples", [])
                if isinstance(raw_examples, list):
                    for example_index, raw_example in enumerate(raw_examples, start=1):
                        if not isinstance(raw_example, dict):
                            continue
                        source_id = raw_example.get("source_id")
                        examples.append(
                            {
                                "example_id": f"{entry_id}:example:{index:03d}:{example_index:03d}",
                                "sentence": raw_example.get("sentence", ""),
                                "source_id": source_id,
                            }
                        )
                sense_source_ids = list(
                    dict.fromkeys(
                        source_id
                        for source_id in raw_sense.get("source_ids", cited_ids)
                        if isinstance(source_id, str)
                    )
                )
                senses.append(
                    {
                        "sense_id": f"{entry_id}:sense:{index:03d}",
                        "order": index,
                        "definition_ja_simple": raw_sense.get("definition_ja_simple", ""),
                        "usage_note_ja": raw_sense.get("usage_note_ja", ""),
                        "register": raw_sense.get("register", "neutral"),
                        "importance": raw_sense.get(
                            "importance",
                            "primary" if index == 1 else "secondary",
                        ),
                        "examples": examples,
                        "relations": [],
                        "image_assets": [],
                        "audio_assets": [],
                        "source_ids": sense_source_ids,
                    }
                )
        embedded_sources = [
            result_by_id[source_id].to_json()
            for source_id in cited_ids
            if source_id in result_by_id
        ]
        retrieved_sources = [item.to_json() for item in search_results]
        entry = {
            "entry_id": entry_id,
            "headword": headword,
            "forms": _canonicalize_forms(draft.get("forms", [])),
            "readings": copy.deepcopy(draft.get("readings", [])),
            "parts_of_speech": copy.deepcopy(draft.get("parts_of_speech", [])),
            "frequency_rank": draft.get("frequency_rank"),
            "editorial_level": "curated",
            "status": "ready",
            "version_origin": origin,
            "locked": bool(existing_entry.get("locked", False)) if existing_entry else False,
            "senses": senses,
            "source_ids": cited_ids,
            "generation": {
                "model": self.llm.model,
                "generated_at": now,
                "generator_version": GENERATOR_VERSION,
                "source_count": len(cited_ids),
                "retrieved_source_count": len(retrieved_sources),
                "knowledge_only": not cited_ids,
                "sources": embedded_sources,
                "retrieved_sources": retrieved_sources,
            },
            "created_at": existing_entry.get("created_at", now) if existing_entry else now,
            "updated_at": now,
            "data_version": GENERATOR_VERSION,
        }
        return entry


_SYSTEM_PROMPT = """\
あなたは日本語学習者向け辞典の編集エンジンです。
返答は JSON オブジェクトだけにしてください。Markdown は禁止です。
定義・用法・例文は自然な日本語だけで書き、中国語の説明を混ぜないでください。
検索資料にない事実を断定しないでください。引用には提示された source_id だけを使ってください。
検索語の原形または読みと見出しが一致し、定義・読み・表記を直接裏付ける資料がある場合は、
source_ids を空にせず、詞条と対応する義項の両方で引用してください。
検索資料が明確に裏付ける最小限の義項だけを作ってください。根拠が曖昧な副義は削除し、
一つの確実な義項だけでも構いません。例文には見出し語または自然な活用形を必ず含めてください。
入力が活用形なら、headword には辞書形を返してください。
必要な形:
{
  "headword": "辞書形",
  "forms": [{"text":"...","type":"primary|alternate|kana|variant|rare","common":true}],
  "readings": [{"kana":"...","primary":true}],
  "parts_of_speech": ["noun|verb-godan|verb-ichidan|adjective-i|adjective-na|other"],
  "frequency_rank": null,
  "source_ids": ["提示された source_id"],
  "senses": [{
    "definition_ja_simple":"やさしい日本語の定義。",
    "usage_note_ja":"必要なら用法。",
    "register":"neutral",
    "importance":"primary|secondary|rare",
    "source_ids":["提示された source_id"],
    "examples":[{"sentence":"対象語または自然な活用形を含む例文。","source_id":"source_id または null"}]
  }]
}
主要語形と主要読みに primary を一つずつ設定してください。
"""


def _user_prompt(
    query: str,
    search_results: list[SearchResult],
    search_terms: list[str],
) -> str:
    evidence = [item.to_json() for item in search_results]
    return (
        f"検索語: {query}\n"
        f"検索に使用した原形・読み候補: {json.dumps(search_terms, ensure_ascii=False)}\n"
        "次の検索結果だけを外部資料として利用できます。資料が不十分なら source_ids を空にし、"
        "モデル既有知識による控えめな定義を返してください。\n"
        f"検索結果:\n{json.dumps(evidence, ensure_ascii=False, indent=2)}"
    )


def _repair_prompt(
    user_prompt: str,
    draft: dict[str, Any],
    issues: list[dict[str, str]],
) -> str:
    return (
        f"{user_prompt}\n"
        "前回の JSON は自動検証に失敗しました。検証を回避せず、指摘されたパスを修正し、"
        "完全な JSON オブジェクトをもう一度返してください。未提示の source_id は作らないでください。"
        "根拠が弱い義項は修復しようとせず削除して構いません。一つの有効な義項で十分です。\n"
        f"前回の JSON:\n{json.dumps(draft, ensure_ascii=False, indent=2)}\n"
        f"検証エラー:\n{json.dumps(issues, ensure_ascii=False, indent=2)}"
    )


def _lemma_search_terms(query: str) -> list[str]:
    candidates = [
        item
        for item in deinflect(query)
        if (
            item.confidence >= 0.90
            and not item.lemma.endswith(("ます", "ました", "ません"))
        )
    ]
    lemma_terms = _unique_terms(
        item.lemma for item in candidates
    )[:_LEMMA_TERM_LIMIT]
    return lemma_terms


def _reading_hints(
    results: list[SearchResult],
    search_terms: list[str],
) -> list[str]:
    term_keys = {normalize_text(item) for item in search_terms}
    hints: list[str] = []
    for result in results:
        if normalize_text(result.title) not in term_keys:
            continue
        match = _READING_HINT_RE.search(result.snippet)
        if match:
            hints.append(match.group(1))
    return [
        item
        for item in _unique_terms(hints)
        if normalize_text(item) not in term_keys
    ]


def _rank_search_results(
    results: list[SearchResult],
    search_terms: list[str],
) -> list[SearchResult]:
    preferred_keys = [normalize_text(item) for item in search_terms]
    deduplicated: dict[str, tuple[int, SearchResult]] = {}
    for index, result in enumerate(results):
        deduplicated.setdefault(result.source_id, (index, result))

    def rank(item: tuple[int, SearchResult]) -> tuple[int, int, int, int]:
        original_index, result = item
        title_key = normalize_text(result.title)
        try:
            exact_index = preferred_keys.index(title_key)
        except ValueError:
            exact_index = len(preferred_keys)
        is_related = any(
            key and (key in title_key or title_key in key)
            for key in preferred_keys
        )
        match_rank = 0 if exact_index < len(preferred_keys) else 1 if is_related else 2
        provider_rank = 0 if result.source_id.startswith("web_jawiktionary_") else 1
        return (match_rank, exact_index, provider_rank, original_index)

    return [
        result
        for _, result in sorted(deduplicated.values(), key=rank)
    ]


def _unique_terms(values: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        term = value.strip()
        key = normalize_text(term)
        if not key or key in seen:
            continue
        seen.add(key)
        result.append(term)
    return result


def _draft_source_ids(draft: dict[str, Any]) -> list[str]:
    source_ids = draft.get("source_ids")
    if not isinstance(source_ids, list):
        return []
    return [
        source_id
        for source_id in source_ids
        if isinstance(source_id, str) and source_id.strip()
    ]


def _canonicalize_forms(raw_forms: Any) -> list[Any]:
    if not isinstance(raw_forms, list):
        return []
    forms = copy.deepcopy(raw_forms)
    for form in forms:
        if not isinstance(form, dict) or "common" in form:
            continue
        form["common"] = form.get("type") in {"primary", "kana"}
    return forms


def _has_exact_source(
    results: list[SearchResult],
    search_terms: list[str],
) -> bool:
    term_keys = {normalize_text(item) for item in search_terms}
    return any(normalize_text(item.title) in term_keys for item in results)
