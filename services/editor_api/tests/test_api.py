from __future__ import annotations

import json
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from services.editor_api.server import create_server
from services.editor_api.storage import WorkingCopyStore
from services.editor_api.tests.support import valid_document


class EditorAPITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        source = root / "source.json"
        source.write_text(json.dumps(valid_document("ai_draft"), ensure_ascii=False), encoding="utf-8")
        self.store = WorkingCopyStore(root / "work", source)
        self.server = create_server("127.0.0.1", 0, self.store)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def call(
        self,
        path: str,
        method: str = "GET",
        payload: dict | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict]:
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        request_headers = {"Content-Type": "application/json"}
        request_headers.update(headers or {})
        request = Request(self.base + path, data=data, method=method, headers=request_headers)
        try:
            with urlopen(request, timeout=2) as response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            try:
                return error.code, json.loads(error.read())
            finally:
                error.close()

    def test_search_get_validate_and_save_round_trip(self) -> None:
        status, search = self.call("/api/entries?q=%E9%A3%9F")
        self.assertEqual(status, 200)
        self.assertEqual(search["entries"][0]["entry_id"], "entry-taberu")
        status, detail = self.call("/api/entries/entry-taberu")
        self.assertEqual(status, 200)
        detail["entry"]["headword"] = "食う"
        status, validation = self.call("/api/entries/entry-taberu/validate", "POST", {"entry": detail["entry"]})
        self.assertEqual(status, 200)
        self.assertTrue(validation["valid"])
        status, saved = self.call("/api/entries/entry-taberu", "PUT", {"entry": detail["entry"], "base_revision": detail["revision"]})
        self.assertEqual(status, 200)
        self.assertEqual(saved["entry"]["headword"], "食う")

    def test_source_catalog_exposes_friendly_reference_metadata(self) -> None:
        status, payload = self.call("/api/sources?q=Kotoba")
        self.assertEqual(status, 200)
        self.assertEqual(payload["sources"], [{
            "source_id": "kotoba.original",
            "title": "Kotoba original",
            "source_type": "original",
            "author": "Kotoba editorial team",
            "license_spdx": "CC-BY-4.0",
        }])

    def test_editor_save_preserves_hidden_system_fields(self) -> None:
        _, detail = self.call("/api/entries/entry-taberu")
        original = json.loads(json.dumps(detail["entry"]))
        submitted = detail["entry"]
        submitted["headword"] = "食う"
        submitted["created_at"] = "2000-01-01T00:00:00Z"
        submitted["updated_at"] = "2000-01-01T00:00:00Z"
        submitted["data_version"] = "client-version"
        submitted["edit_status"] = "published"
        submitted["review"]["status"] = "published"
        submitted["senses"][0]["review_status"] = "published"

        status, saved = self.call(
            "/api/entries/entry-taberu",
            "PUT",
            {"entry": submitted, "base_revision": detail["revision"]},
        )

        self.assertEqual(status, 200)
        self.assertEqual(saved["entry"]["headword"], "食う")
        for field in ("entry_id", "created_at", "data_version", "edit_status", "review"):
            self.assertEqual(saved["entry"][field], original[field])
        self.assertEqual(saved["entry"]["senses"][0]["sense_id"], original["senses"][0]["sense_id"])
        self.assertEqual(saved["entry"]["senses"][0]["review_status"], original["senses"][0]["review_status"])
        self.assertNotEqual(saved["entry"]["updated_at"], "2000-01-01T00:00:00Z")

    def test_stale_save_returns_conflict(self) -> None:
        _, detail = self.call("/api/entries/entry-taberu")
        first = dict(detail["entry"])
        first["headword"] = "食う"
        self.assertEqual(self.call("/api/entries/entry-taberu", "PUT", {"entry": first, "base_revision": detail["revision"]})[0], 200)
        status, payload = self.call("/api/entries/entry-taberu", "PUT", {"entry": detail["entry"], "base_revision": detail["revision"]})
        self.assertEqual(status, 409)
        self.assertEqual(payload["error"]["code"], "revision_conflict")

    def test_ai_draft_cannot_jump_to_approved(self) -> None:
        _, detail = self.call("/api/entries/entry-taberu")
        status, payload = self.call("/api/entries/entry-taberu/transition", "POST", {
            "status": "approved", "reviewer": "Alice", "base_revision": detail["revision"],
        })
        self.assertEqual(status, 409)
        self.assertEqual(payload["error"]["code"], "workflow_error")
        persisted, persisted_revision = self.store.get_entry("entry-taberu")
        self.assertEqual(persisted["edit_status"], "ai_draft")
        self.assertEqual(persisted_revision, detail["revision"])
        self.assertFalse(self.store.audit_path.exists())

    def test_human_review_sequence_is_persisted_with_aligned_statuses(self) -> None:
        _, detail = self.call("/api/entries/entry-taberu")
        revision = detail["revision"]
        browser_headers = {"Origin": self.base, "Sec-Fetch-Site": "same-origin"}

        for target, reviewer in (("needs_review", ""), ("reviewed", "Alice"), ("approved", "Alice")):
            status, result = self.call(
                "/api/entries/entry-taberu/transition",
                "POST",
                {"status": target, "reviewer": reviewer, "base_revision": revision},
                browser_headers,
            )
            self.assertEqual(status, 200)
            revision = result["revision"]
            self.assertEqual(result["entry"]["edit_status"], target)
            self.assertEqual(result["entry"]["review"]["status"], target)
            self.assertTrue(all(sense["review_status"] == target for sense in result["entry"]["senses"]))

            persisted, persisted_revision = self.store.get_entry("entry-taberu")
            self.assertEqual(persisted_revision, revision)
            self.assertEqual(persisted["edit_status"], target)
            self.assertEqual(persisted["review"]["status"], target)
            self.assertTrue(all(sense["review_status"] == target for sense in persisted["senses"]))

        phases = [json.loads(line)["phase"] for line in self.store.audit_path.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(phases, ["prepared", "committed"] * 3)

    def test_non_loopback_bind_addresses_are_rejected(self) -> None:
        for host in ("0.0.0.0", "192.168.1.20", "kotoba.example"):
            with self.subTest(host=host), self.assertRaises(ValueError):
                create_server(host, 0, self.store)

    def test_dns_rebinding_host_header_is_rejected(self) -> None:
        status, payload = self.call(
            "/api/health",
            headers={"Host": f"attacker.example:{self.server.server_port}"},
        )
        self.assertEqual(status, 421)
        self.assertEqual(payload["error"]["code"], "invalid_host")

    def test_cross_local_origin_is_rejected_before_mutation(self) -> None:
        _, detail = self.call("/api/entries/entry-taberu")
        status, payload = self.call(
            "/api/entries/entry-taberu/transition",
            "POST",
            {"status": "needs_review", "base_revision": detail["revision"]},
            {"Origin": f"http://localhost:{self.server.server_port}", "Sec-Fetch-Site": "same-origin"},
        )
        self.assertEqual(status, 403)
        self.assertEqual(payload["error"]["code"], "forbidden_origin")
        self.assertEqual(self.store.get_entry("entry-taberu")[0]["edit_status"], "ai_draft")

    def test_cross_site_fetch_metadata_is_rejected_before_mutation(self) -> None:
        _, detail = self.call("/api/entries/entry-taberu")
        status, payload = self.call(
            "/api/entries/entry-taberu/transition",
            "POST",
            {"status": "needs_review", "base_revision": detail["revision"]},
            {"Sec-Fetch-Site": "cross-site"},
        )
        self.assertEqual(status, 403)
        self.assertEqual(payload["error"]["code"], "forbidden_origin")
        self.assertEqual(self.store.get_entry("entry-taberu")[0]["edit_status"], "ai_draft")

    def test_invalid_schema_returns_paths(self) -> None:
        _, detail = self.call("/api/entries/entry-taberu")
        detail["entry"]["senses"][0]["definition_ja_simple"] = ""
        status, payload = self.call("/api/entries/entry-taberu", "PUT", {"entry": detail["entry"], "base_revision": detail["revision"]})
        self.assertEqual(status, 422)
        self.assertTrue(any(item["path"].endswith("definition_ja_simple") for item in payload["issues"]))

    def test_static_path_traversal_is_not_served(self) -> None:
        status, _ = self.call("/%2e%2e/packages/dictionary_schema/schema.json")
        self.assertEqual(status, 404)
        status, _ = self.call("/api/entries/%2e%2e%2fdictionary.working.json")
        self.assertEqual(status, 404)

    def test_editor_shell_and_script_are_served_with_security_headers(self) -> None:
        with urlopen(self.base + "/", timeout=2) as response:
            html = response.read().decode("utf-8")
            self.assertEqual(response.status, 200)
            self.assertIn("Kotoba 內容編輯器", html)
            self.assertIn("frame-ancestors 'none'", response.headers["Content-Security-Policy"])
        with urlopen(self.base + "/app.js", timeout=2) as response:
            script = response.read().decode("utf-8")
            self.assertIn("async function saveDraft", script)


if __name__ == "__main__":
    unittest.main()
