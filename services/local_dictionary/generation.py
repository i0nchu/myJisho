"""Search, LLM generation, normalization and validation orchestration."""

from __future__ import annotations

import copy
from datetime import datetime, timezone
import hashlib
import json
from typing import Any, Iterable

from packages.japanese_normalizer.normalizer import normalize_text

from .providers import LLMProvider, SearchProvider, SearchResult
from .validation import validate_generated_entry


GENERATOR_VERSION = "kotoba-local-1"


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
        try:
            search_results = self.search.search(normalized_query, limit=6)
        except Exception as error:
            raise GenerationError("search_failed", f"網路搜尋失敗：{error}") from error
        try:
            draft = self.llm.generate_json(
                system_prompt=_SYSTEM_PROMPT,
                user_prompt=_user_prompt(normalized_query, search_results),
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
        if issues:
            raise GenerationError(
                "validation_failed",
                "模型回傳內容未通過自動驗證",
                issues=issues,
            )
        return entry

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
        entry = {
            "entry_id": entry_id,
            "headword": headword,
            "forms": copy.deepcopy(draft.get("forms", [])),
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
                "knowledge_only": not cited_ids,
                "sources": embedded_sources,
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


def _user_prompt(query: str, search_results: list[SearchResult]) -> str:
    evidence = [item.to_json() for item in search_results]
    return (
        f"検索語: {query}\n"
        "次の検索結果だけを外部資料として利用できます。資料が不十分なら source_ids を空にし、"
        "モデル既有知識による控えめな定義を返してください。\n"
        f"検索結果:\n{json.dumps(evidence, ensure_ascii=False, indent=2)}"
    )
