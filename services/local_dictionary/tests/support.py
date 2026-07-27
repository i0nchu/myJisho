from __future__ import annotations

import copy
from typing import Any

from services.local_dictionary.providers import SearchResult


SOURCE = SearchResult(
    source_id="web_test_1",
    title="食べる",
    url="https://example.invalid/taberu",
    snippet="食べるという動詞についての資料。",
    retrieved_at="2026-07-27T12:00:00Z",
    license_spdx="CC-BY-SA-4.0",
)


def valid_draft() -> dict[str, Any]:
    return {
        "headword": "食べる",
        "forms": [
            {"text": "食べる", "type": "primary", "common": True},
            {"text": "たべる", "type": "kana", "common": True},
        ],
        "readings": [{"kana": "たべる", "primary": True}],
        "parts_of_speech": ["verb-ichidan"],
        "frequency_rank": 180,
        "source_ids": ["web_test_1"],
        "senses": [
            {
                "definition_ja_simple": "食べ物を口に入れ、かんで飲み込む。",
                "usage_note_ja": "日常生活で広く使う。",
                "register": "neutral",
                "importance": "primary",
                "source_ids": ["web_test_1"],
                "examples": [
                    {
                        "sentence": "毎朝パンを食べる。",
                        "source_id": "web_test_1",
                    }
                ],
            }
        ],
    }


class FakeSearchProvider:
    def __init__(
        self,
        results: list[SearchResult] | None = None,
        *,
        results_by_query: dict[str, list[SearchResult]] | None = None,
    ):
        self.results = list(results if results is not None else [SOURCE])
        self.results_by_query = {
            query: list(items)
            for query, items in (results_by_query or {}).items()
        }
        self.queries: list[str] = []

    def search(self, query: str, *, limit: int = 6) -> list[SearchResult]:
        self.queries.append(query)
        return self.results_by_query.get(query, self.results)[:limit]


class FakeLLMProvider:
    model = "Qwen3 8B Test"

    def __init__(
        self,
        draft: dict[str, Any] | None = None,
        *,
        drafts: list[dict[str, Any]] | None = None,
    ):
        self.draft = draft if draft is not None else valid_draft()
        self.drafts = [copy.deepcopy(item) for item in drafts or []]
        self.calls = 0
        self.system_prompts: list[str] = []
        self.user_prompts: list[str] = []

    def generate_json(self, *, system_prompt: str, user_prompt: str) -> dict[str, Any]:
        self.calls += 1
        self.system_prompts.append(system_prompt)
        self.user_prompts.append(user_prompt)
        if self.drafts:
            index = min(self.calls - 1, len(self.drafts) - 1)
            return copy.deepcopy(self.drafts[index])
        return copy.deepcopy(self.draft)
