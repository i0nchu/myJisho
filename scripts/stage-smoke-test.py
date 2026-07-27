#!/usr/bin/env python3
"""Run a real staging API generation/reuse/revision smoke test."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import ssl
import sys
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify Kotoba staging health, generation, search reuse and Revision."
    )
    parser.add_argument(
        "--query",
        default="食べました",
        help="Japanese query to submit (default: 食べました)",
    )
    parser.add_argument(
        "--endpoint",
        help="API endpoint; defaults to https://KOTOBA_STAGE_DOMAIN from deploy/.env",
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "deploy" / ".env",
        help="deployment env file (default: deploy/.env)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="generation timeout in seconds (default: 300)",
    )
    return parser.parse_args()


def load_env(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise RuntimeError(f"找不到環境檔：{path}")
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


class Api:
    def __init__(self, endpoint: str, token: str):
        self.endpoint = endpoint.rstrip("/")
        self.headers = {"Authorization": f"Bearer {token}"}
        self.ssl_context = ssl.create_default_context()

    def request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
    ) -> tuple[int, dict[str, Any]]:
        payload = None
        headers = dict(self.headers)
        if body is not None:
            payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = Request(
            f"{self.endpoint}{path}",
            data=payload,
            headers=headers,
            method=method,
        )
        try:
            with urlopen(request, timeout=15, context=self.ssl_context) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw else {}
        except HTTPError as error:
            raw = error.read()
            detail = json.loads(raw) if raw else {}
            raise RuntimeError(
                f"{method} {path} 回傳 HTTP {error.code}: "
                f"{json.dumps(detail, ensure_ascii=False)}"
            ) from error
        except URLError as error:
            raise RuntimeError(f"{method} {path} 連線失敗：{error.reason}") from error


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    args = parse_args()
    values = load_env(args.env_file.resolve())
    token = values.get("KOTOBA_API_TOKEN", "")
    require(32 <= len(token) <= 512 and not any(char.isspace() for char in token), "API token 無效")
    endpoint = args.endpoint or f"https://{values.get('KOTOBA_STAGE_DOMAIN', '')}"
    require(endpoint.startswith("https://") and len(endpoint) > 8, "staging endpoint 無效")
    query = args.query.strip()
    require(bool(query), "查詢詞不可為空")

    api = Api(endpoint, token)
    started_at = time.monotonic()
    _, health = api.request("GET", "/api/health")
    require(health.get("ok") is True, "health payload 未回報 ok=true")
    print(f"[PASS] HTTPS health：model={health.get('model', '')}")

    submit_status, submitted = api.request(
        "POST",
        "/api/generation-jobs",
        {"query": query},
    )
    require(submit_status in {200, 202}, f"非預期的送出狀態：{submit_status}")
    job = submitted.get("job", {})
    job_id = str(job.get("job_id", ""))
    require(bool(job_id), "送出結果缺少 job_id")

    deadline = time.monotonic() + args.timeout
    while job.get("status") == "generating" and time.monotonic() < deadline:
        time.sleep(1)
        _, job_payload = api.request(
            "GET",
            f"/api/generation-jobs/{quote(job_id, safe='')}",
        )
        job = job_payload.get("job", {})
    require(job.get("status") != "generating", f"生成超過 {args.timeout} 秒")
    if job.get("status") == "failed":
        raise RuntimeError(
            "生成或驗證失敗："
            + json.dumps(job.get("error", {}), ensure_ascii=False, indent=2)
        )
    require(job.get("status") == "ready", f"非預期工作狀態：{job.get('status')}")
    entry_id = str(job.get("entry_id", ""))
    require(bool(entry_id), "ready job 缺少 entry_id")
    generation_elapsed = time.monotonic() - started_at
    print(f"[PASS] 正式送出後生成／取用完成：{generation_elapsed:.1f}s")

    _, search_payload = api.request(
        "GET",
        f"/api/search?{urlencode({'q': query})}",
    )
    matches = search_payload.get("entries", [])
    require(
        any(item.get("entry_id") == entry_id for item in matches),
        "生成後以相同查詢找不到詞條",
    )
    entry = next(item for item in matches if item.get("entry_id") == entry_id)
    readings = entry.get("readings", [])
    primary_reading = next(
        (
            str(item.get("kana", ""))
            for item in readings
            if isinstance(item, dict) and item.get("primary") is True
        ),
        "",
    )
    print(
        "[PASS] 查詢命中："
        f"{entry.get('headword', '')}【{primary_reading}】 "
        f"status={entry.get('status', '')}"
    )

    _, revision_payload = api.request(
        "GET",
        f"/api/entries/{quote(entry_id, safe='')}/revisions",
    )
    revisions = revision_payload.get("revisions", [])
    require(len(revisions) >= 1, "詞條沒有 Revision")
    print(f"[PASS] Revision 可讀：{len(revisions)} 版")

    reuse_status, reused_payload = api.request(
        "POST",
        "/api/generation-jobs",
        {"query": query},
    )
    reused_job = reused_payload.get("job", {})
    require(reuse_status == 200, f"重複查詢應直接回傳 200，實際為 {reuse_status}")
    require(reused_job.get("status") == "ready", "重複查詢未直接回傳 ready")
    require(reused_job.get("entry_id") == entry_id, "重複查詢建立了不同詞條")
    print("[PASS] 重複查詢直接重用本地詞條，未重新生成")

    generation = entry.get("generation", {})
    source_count = int(generation.get("source_count", 0))
    knowledge_only = bool(generation.get("knowledge_only"))
    print(
        "[INFO] 品質抽查："
        f"sources={source_count}, knowledge_only={str(knowledge_only).lower()}"
    )
    print("API staging smoke test 全部通過。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        raise SystemExit(1) from error
