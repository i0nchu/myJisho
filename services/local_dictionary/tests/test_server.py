from __future__ import annotations

import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from services.local_dictionary.generation import DictionaryGenerator
from services.local_dictionary.server import create_server
from services.local_dictionary.storage import LocalDictionaryStore

from .support import FakeLLMProvider, FakeSearchProvider


class LocalDictionaryServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="kotoba-local-api-")
        self.llm = FakeLLMProvider()
        store = LocalDictionaryStore(Path(self.temporary.name) / "dictionary.sqlite")
        self.server = create_server(
            "127.0.0.1",
            0,
            store,
            DictionaryGenerator(FakeSearchProvider(), self.llm),
            api_token="test-token-0123456789abcdef012345",
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def request(
        self,
        method: str,
        path: str,
        payload: dict | None = None,
        headers: dict[str, str] | None = None,
        *,
        authenticated: bool = True,
    ) -> tuple[int, dict]:
        body = (
            json.dumps(payload, ensure_ascii=False).encode("utf-8")
            if payload is not None
            else None
        )
        request_headers = {"Accept": "application/json"}
        if authenticated:
            request_headers["Authorization"] = (
                "Bearer test-token-0123456789abcdef012345"
            )
        if body is not None:
            request_headers["Content-Type"] = "application/json"
        request_headers.update(headers or {})
        request = Request(
            f"{self.base_url}{path}",
            data=body,
            headers=request_headers,
            method=method,
        )
        try:
            with urlopen(request, timeout=3) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw else {}
        except HTTPError as error:
            try:
                raw = error.read()
                return error.code, json.loads(raw) if raw else {}
            finally:
                error.close()

    def wait_for_job(self, job_id: str) -> dict:
        for _ in range(100):
            status, payload = self.request("GET", f"/api/generation-jobs/{job_id}")
            self.assertEqual(status, 200)
            job = payload["job"]
            if job["status"] != "generating":
                return job
            time.sleep(0.01)
        self.fail("generation job did not finish")

    def test_generate_reuse_revision_and_management_contract(self) -> None:
        status, payload = self.request(
            "POST",
            "/api/generation-jobs",
            {"query": "食べました"},
        )
        self.assertEqual(status, 202)
        job = self.wait_for_job(payload["job"]["job_id"])
        self.assertEqual(job["status"], "ready")
        entry_id = job["entry_id"]

        status, payload = self.request("GET", "/api/search?q=%E9%A3%9F%E3%81%B9%E3%82%8B")
        self.assertEqual(status, 200)
        self.assertEqual(payload["entries"][0]["entry_id"], entry_id)

        status, payload = self.request("GET", "/api/entries")
        self.assertEqual(status, 200)
        self.assertEqual(len(payload["entries"]), 1)

        status, payload = self.request(
            "POST",
            "/api/generation-jobs",
            {"query": "食べる"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(payload["job"]["entry_id"], entry_id)
        self.assertEqual(self.llm.calls, 1)

        status, payload = self.request(
            "PUT",
            f"/api/entries/{entry_id}",
            {"patch": {"definition_ja_simple": "食べ物を口に入れて飲み込む。"}},
        )
        self.assertEqual(status, 200)
        self.assertEqual(payload["entry"]["version_origin"], "edited")

        status, payload = self.request("GET", f"/api/entries/{entry_id}/revisions")
        self.assertEqual(status, 200)
        self.assertEqual([row["revision"] for row in payload["revisions"]], [2, 1])

        status, payload = self.request(
            "GET",
            f"/api/entries/{entry_id}/revisions/1",
        )
        self.assertEqual(status, 200)
        self.assertEqual(payload["entry"]["version_origin"], "generated")

        status, payload = self.request(
            "POST",
            f"/api/entries/{entry_id}/lock",
            {"locked": True},
        )
        self.assertEqual(status, 200)
        self.assertTrue(payload["entry"]["locked"])

        status, payload = self.request(
            "POST",
            f"/api/entries/{entry_id}/regenerate",
            {},
        )
        self.assertEqual(status, 409)
        self.assertEqual(payload["error"]["code"], "conflict")

    def test_cross_origin_mutation_is_rejected(self) -> None:
        status, payload = self.request(
            "POST",
            "/api/generation-jobs",
            {"query": "食べる"},
            headers={"Origin": "http://malicious.invalid"},
        )
        self.assertEqual(status, 403)
        self.assertEqual(payload["error"]["code"], "forbidden_origin")

    def test_missing_bearer_token_is_rejected(self) -> None:
        status, payload = self.request(
            "GET",
            "/api/health",
            authenticated=False,
        )
        self.assertEqual(status, 401)
        self.assertEqual(payload["error"]["code"], "unauthorized")


if __name__ == "__main__":
    unittest.main()
