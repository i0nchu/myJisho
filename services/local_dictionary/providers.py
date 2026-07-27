"""Network-search and OpenAI-compatible LLM providers for local generation."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import html
import json
import os
import re
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True)
class SearchResult:
    source_id: str
    title: str
    url: str
    snippet: str
    retrieved_at: str
    license_spdx: str

    def to_json(self) -> dict[str, str]:
        return {
            "source_id": self.source_id,
            "title": self.title,
            "url": self.url,
            "snippet": self.snippet,
            "retrieved_at": self.retrieved_at,
            "license_spdx": self.license_spdx,
        }


class SearchProvider(Protocol):
    def search(self, query: str, *, limit: int = 6) -> list[SearchResult]: ...


class LLMProvider(Protocol):
    @property
    def model(self) -> str: ...

    def generate_json(self, *, system_prompt: str, user_prompt: str) -> dict[str, Any]: ...


class WikimediaSearchProvider:
    """Search Japanese Wiktionary and Wikipedia without an API key."""

    _ENDPOINTS = (
        ("jawiktionary", "https://ja.wiktionary.org/w/api.php", "CC-BY-SA-4.0"),
        ("jawikipedia", "https://ja.wikipedia.org/w/api.php", "CC-BY-SA-4.0"),
    )

    def __init__(self, *, timeout_seconds: float = 12.0):
        self.timeout_seconds = timeout_seconds

    def search(self, query: str, *, limit: int = 6) -> list[SearchResult]:
        normalized = query.strip()
        if not normalized:
            return []
        per_source = max(1, (limit + len(self._ENDPOINTS) - 1) // len(self._ENDPOINTS))
        results: list[SearchResult] = []
        failures: list[Exception] = []
        for namespace, endpoint, license_spdx in self._ENDPOINTS:
            try:
                results.extend(
                    self._search_endpoint(
                        namespace,
                        endpoint,
                        license_spdx,
                        normalized,
                        per_source,
                    )
                )
            except (HTTPError, URLError, TimeoutError, ValueError) as error:
                failures.append(error)
        if not results and failures:
            raise RuntimeError("all configured web searches failed") from failures[-1]
        return results[:limit]

    def _search_endpoint(
        self,
        namespace: str,
        endpoint: str,
        license_spdx: str,
        query: str,
        limit: int,
    ) -> list[SearchResult]:
        params = urlencode(
            {
                "action": "query",
                "list": "search",
                "srsearch": query,
                "srlimit": limit,
                "utf8": 1,
                "format": "json",
            }
        )
        request = Request(
            f"{endpoint}?{params}",
            headers={
                "Accept": "application/json",
                "User-Agent": "KotobaSelfHosted/0.2 (local Japanese dictionary)",
            },
        )
        with urlopen(request, timeout=self.timeout_seconds) as response:
            payload = json.load(response)
        search_rows = payload.get("query", {}).get("search", [])
        if not isinstance(search_rows, list):
            raise ValueError("Wikimedia response did not contain a search result list")
        retrieved_at = utc_now()
        rows: list[SearchResult] = []
        for row in search_rows:
            if not isinstance(row, dict) or not isinstance(row.get("title"), str):
                continue
            title = row["title"].strip()
            page_url = (
                f"https://ja.wiktionary.org/wiki/{quote(title.replace(' ', '_'))}"
                if namespace == "jawiktionary"
                else f"https://ja.wikipedia.org/wiki/{quote(title.replace(' ', '_'))}"
            )
            source_hash = hashlib.sha256(f"{namespace}\0{title}".encode("utf-8")).hexdigest()[:20]
            snippet = html.unescape(re.sub(r"<[^>]+>", "", str(row.get("snippet", ""))))
            rows.append(
                SearchResult(
                    source_id=f"web_{namespace}_{source_hash}",
                    title=title,
                    url=page_url,
                    snippet=snippet.strip(),
                    retrieved_at=retrieved_at,
                    license_spdx=license_spdx,
                )
            )
        return rows


class OpenAICompatibleLLMProvider:
    """Call a local OpenAI-compatible endpoint such as Ollama or vLLM."""

    def __init__(
        self,
        *,
        base_url: str | None = None,
        model: str | None = None,
        api_key: str | None = None,
        timeout_seconds: float = 90.0,
    ):
        self.base_url = (base_url or os.environ.get("KOTOBA_LLM_BASE_URL") or "http://127.0.0.1:11434/v1").rstrip("/")
        self._model = model or os.environ.get("KOTOBA_LLM_MODEL") or "qwen3:8b"
        self.api_key = api_key if api_key is not None else os.environ.get("KOTOBA_LLM_API_KEY", "")
        self.timeout_seconds = timeout_seconds

    @property
    def model(self) -> str:
        return self._model

    def generate_json(self, *, system_prompt: str, user_prompt: str) -> dict[str, Any]:
        body = json.dumps(
            {
                "model": self._model,
                "temperature": 0.1,
                "response_format": {"type": "json_object"},
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
            },
            ensure_ascii=False,
        ).encode("utf-8")
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        request = Request(
            f"{self.base_url}/chat/completions",
            data=body,
            headers=headers,
            method="POST",
        )
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:
                payload = json.load(response)
        except HTTPError as error:
            detail = error.read(4096).decode("utf-8", errors="replace")
            raise RuntimeError(f"LLM endpoint returned HTTP {error.code}: {detail}") from error
        except (URLError, TimeoutError) as error:
            raise RuntimeError(f"LLM endpoint is unavailable: {error}") from error
        try:
            content = payload["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError) as error:
            raise RuntimeError("LLM response did not contain choices[0].message.content") from error
        if not isinstance(content, str):
            raise RuntimeError("LLM response content was not text")
        return _parse_json_object(content)


def _parse_json_object(content: str) -> dict[str, Any]:
    text = content.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text, flags=re.IGNORECASE)
        text = re.sub(r"\s*```$", "", text)
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        if start < 0:
            raise ValueError("LLM response did not contain a JSON object")
        value, _ = json.JSONDecoder().raw_decode(text[start:])
    if not isinstance(value, dict):
        raise ValueError("LLM response must be a JSON object")
    return value
