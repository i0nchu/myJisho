"""Dependency-free localhost HTTP server for the myJisho editor."""

from __future__ import annotations

import argparse
import ipaddress
import json
import re
import socket
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlsplit

from .schema_validation import load_schema
from .storage import ConflictError, ValidationError, WorkingCopyStore
from .workflow import WorkflowError, allowed_transitions, check_replacement, transition


PROJECT_ROOT = Path(__file__).resolve().parents[2]
STATIC_ROOT = PROJECT_ROOT / "apps" / "content_editor"
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/styles.css": ("styles.css", "text/css; charset=utf-8"),
}
ENTRY_ROUTE = re.compile(r"^/api/entries/([^/]+?)(/validate|/transition)?$")


class EditorHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], store: WorkingCopyStore):
        bind_host = _loopback_bind_host(address[0])
        bind_address = ipaddress.ip_address(bind_host)
        if bind_address.version == 6:
            self.address_family = socket.AF_INET6
        super().__init__((bind_host, address[1]), EditorHandler)
        self.store = store
        allowed_hosts = {bind_address.compressed}
        if bind_address in {ipaddress.ip_address("127.0.0.1"), ipaddress.ip_address("::1")}:
            allowed_hosts.add("localhost")
        self.allowed_hosts = frozenset(allowed_hosts)


class EditorHandler(BaseHTTPRequestHandler):
    server: EditorHTTPServer
    protocol_version = "HTTP/1.1"
    max_body_bytes = 2 * 1024 * 1024

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self._guard_request(mutating=False):
            return
        route = urlsplit(self.path)
        if route.path == "/api/health":
            self._json(HTTPStatus.OK, {"ok": True})
            return
        if route.path == "/api/schema":
            self._json(HTTPStatus.OK, {"schema": load_schema(), "transitions": self._transitions()})
            return
        if route.path == "/api/entries":
            query = parse_qs(route.query).get("q", [""])[0]
            results, revision = self.server.store.search(query[:200])
            self._json(HTTPStatus.OK, {"entries": results, "revision": revision})
            return
        if route.path == "/api/sources":
            query = parse_qs(route.query).get("q", [""])[0]
            results, revision = self.server.store.search_sources(query[:200])
            self._json(HTTPStatus.OK, {"sources": results, "revision": revision})
            return
        match = ENTRY_ROUTE.fullmatch(route.path)
        if match and not match.group(2):
            entry_id = unquote(match.group(1))
            entry, revision = self.server.store.get_entry(entry_id)
            if entry is None:
                self._error(HTTPStatus.NOT_FOUND, "not_found", "entry was not found")
                return
            self._json(HTTPStatus.OK, {
                "entry": entry,
                "revision": revision,
                "allowed_transitions": allowed_transitions(entry["edit_status"]),
            })
            return
        if route.path in STATIC_FILES:
            name, content_type = STATIC_FILES[route.path]
            self._static(name, content_type)
            return
        self._error(HTTPStatus.NOT_FOUND, "not_found", "route was not found")

    def do_POST(self) -> None:  # noqa: N802
        if not self._guard_request(mutating=True):
            return
        route = urlsplit(self.path)
        match = ENTRY_ROUTE.fullmatch(route.path)
        if not match:
            self._error(HTTPStatus.NOT_FOUND, "not_found", "route was not found")
            return
        entry_id = unquote(match.group(1))
        try:
            payload = self._body()
            if match.group(2) == "/validate":
                submitted = self._entry_payload(payload)
                current, entry = self.server.store.prepare_editor_entry(entry_id, submitted)
                check_replacement(current, entry)
                issues = self.server.store.validate_replacement(entry_id, entry)
                self._json(HTTPStatus.OK, {"valid": not issues, "issues": issues})
                return
            if match.group(2) == "/transition":
                current, _ = self._require_entry(entry_id)
                updated = transition(
                    current,
                    str(payload.get("status", "")),
                    str(payload.get("reviewer", "")),
                    str(payload.get("notes", "")),
                )
                revision = self.server.store.replace_entry(
                    entry_id,
                    updated,
                    str(payload.get("base_revision", "")),
                    action=f"transition:{current['edit_status']}->{updated['edit_status']}",
                )
                self._json(HTTPStatus.OK, {
                    "entry": updated,
                    "revision": revision,
                    "allowed_transitions": allowed_transitions(updated["edit_status"]),
                })
                return
            self._error(HTTPStatus.METHOD_NOT_ALLOWED, "method_not_allowed", "use GET for this route")
        except Exception as error:  # mapped to a stable JSON error response
            self._handle_exception(error)

    def do_PUT(self) -> None:  # noqa: N802
        if not self._guard_request(mutating=True):
            return
        route = urlsplit(self.path)
        match = ENTRY_ROUTE.fullmatch(route.path)
        if not match or match.group(2):
            self._error(HTTPStatus.NOT_FOUND, "not_found", "route was not found")
            return
        entry_id = unquote(match.group(1))
        try:
            payload = self._body()
            submitted = self._entry_payload(payload)
            current, entry = self.server.store.prepare_editor_entry(entry_id, submitted)
            check_replacement(current, entry)
            revision = self.server.store.replace_entry(entry_id, entry, str(payload.get("base_revision", "")))
            self._json(HTTPStatus.OK, {
                "entry": entry,
                "revision": revision,
                "allowed_transitions": allowed_transitions(entry["edit_status"]),
            })
        except Exception as error:
            self._handle_exception(error)

    def _require_entry(self, entry_id: str) -> tuple[dict[str, Any], str]:
        entry, revision = self.server.store.get_entry(entry_id)
        if entry is None:
            raise KeyError(entry_id)
        return entry, revision

    @staticmethod
    def _entry_payload(payload: dict[str, Any]) -> dict[str, Any]:
        entry = payload.get("entry")
        if not isinstance(entry, dict):
            raise ValueError("entry must be a JSON object")
        return entry

    def _body(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as error:
            raise ValueError("invalid Content-Length") from error
        if length <= 0 or length > self.max_body_bytes:
            raise ValueError(f"body size must be between 1 and {self.max_body_bytes} bytes")
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("body must be valid UTF-8 JSON") from error
        if not isinstance(payload, dict):
            raise ValueError("body must be a JSON object")
        return payload

    def _guard_request(self, mutating: bool) -> bool:
        """Reject untrusted authorities and browser cross-origin mutations."""

        try:
            request_origin = self._request_origin()
        except ValueError:
            self.close_connection = True
            self._error(HTTPStatus.MISDIRECTED_REQUEST, "invalid_host", "Host must name this loopback server")
            return False
        if not mutating:
            return True

        origins = self.headers.get_all("Origin", failobj=[])
        if len(origins) > 1:
            self.close_connection = True
            self._error(HTTPStatus.FORBIDDEN, "forbidden_origin", "cross-origin mutation is not allowed")
            return False
        if origins:
            try:
                origin = self._parse_origin(origins[0])
            except ValueError:
                origin = None
            if origin != request_origin:
                self.close_connection = True
                self._error(HTTPStatus.FORBIDDEN, "forbidden_origin", "cross-origin mutation is not allowed")
                return False

        fetch_sites = self.headers.get_all("Sec-Fetch-Site", failobj=[])
        if len(fetch_sites) > 1 or any(value.strip().lower() != "same-origin" for value in fetch_sites):
            self.close_connection = True
            self._error(HTTPStatus.FORBIDDEN, "forbidden_origin", "Sec-Fetch-Site must be same-origin")
            return False
        # Origin and Fetch Metadata are optional so non-browser local CLI tools
        # remain usable. Browsers send one or both for script-driven mutations.
        return True

    def _request_origin(self) -> tuple[str, str, int]:
        values = self.headers.get_all("Host", failobj=[])
        if len(values) != 1:
            raise ValueError("exactly one Host header is required")
        raw = values[0]
        if raw != raw.strip() or any(character in raw for character in "/\\@,?#"):
            raise ValueError("invalid Host header")
        try:
            parsed = urlsplit(f"//{raw}")
            hostname = parsed.hostname
            port = parsed.port
        except ValueError as error:
            raise ValueError("invalid Host header") from error
        if not hostname or parsed.path or parsed.username is not None or parsed.password is not None:
            raise ValueError("invalid Host header")
        hostname = hostname.lower()
        if hostname not in self.server.allowed_hosts:
            raise ValueError("Host is not the bound loopback address")
        effective_port = port if port is not None else 80
        if effective_port != self.server.server_port:
            raise ValueError("Host port does not match the server")
        return "http", hostname, effective_port

    @staticmethod
    def _parse_origin(raw: str) -> tuple[str, str, int]:
        if raw != raw.strip():
            raise ValueError("invalid Origin header")
        try:
            parsed = urlsplit(raw)
            port = parsed.port
        except ValueError as error:
            raise ValueError("invalid Origin header") from error
        if (
            parsed.scheme.lower() != "http"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError("invalid Origin header")
        return "http", parsed.hostname.lower(), port if port is not None else 80

    def _handle_exception(self, error: Exception) -> None:
        if isinstance(error, ConflictError):
            self._error(HTTPStatus.CONFLICT, "revision_conflict", str(error))
        elif isinstance(error, ValidationError):
            self._json(HTTPStatus.UNPROCESSABLE_ENTITY, {
                "error": {"code": "validation_failed", "message": str(error)},
                "issues": error.issues,
            })
        elif isinstance(error, WorkflowError):
            self._error(HTTPStatus.CONFLICT, "workflow_error", str(error))
        elif isinstance(error, KeyError):
            self._error(HTTPStatus.NOT_FOUND, "not_found", "entry was not found")
        elif isinstance(error, (ValueError, TypeError)):
            self._error(HTTPStatus.BAD_REQUEST, "bad_request", str(error))
        else:
            self.log_error("internal error: %r", error)
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "internal_error", "request could not be completed")

    def _static(self, name: str, content_type: str) -> None:
        # Only names from STATIC_FILES reach this method; no request path is joined.
        path = STATIC_ROOT / name
        try:
            content = path.read_bytes()
        except FileNotFoundError:
            self._error(HTTPStatus.NOT_FOUND, "not_found", "editor asset was not found")
            return
        self._send(HTTPStatus.OK, content, content_type)

    def _json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        content = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._send(status, content, "application/json; charset=utf-8")

    def _error(self, status: HTTPStatus, code: str, message: str) -> None:
        self._json(status, {"error": {"code": code, "message": message}})

    def _send(self, status: HTTPStatus, content: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; script-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(content)

    @staticmethod
    def _transitions() -> dict[str, list[str]]:
        from .workflow import TRANSITIONS

        return {status: sorted(targets) for status, targets in TRANSITIONS.items()}

    def log_message(self, format: str, *args: Any) -> None:
        print(f"{self.address_string()} - {format % args}")


def create_server(host: str, port: int, store: WorkingCopyStore) -> EditorHTTPServer:
    return EditorHTTPServer((host, port), store)


def _loopback_bind_host(host: str) -> str:
    candidate = host.strip()
    if candidate.lower() == "localhost":
        candidate = "127.0.0.1"
    try:
        address = ipaddress.ip_address(candidate)
    except ValueError as error:
        raise ValueError("listen address must be an IP loopback address or localhost") from error
    if not address.is_loopback:
        raise ValueError("listen address must be loopback-only")
    return address.compressed


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the myJisho local content editor")
    parser.add_argument("--host", default="127.0.0.1", help="listen address (default: localhost only)")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--working-dir", type=Path, default=Path(__file__).parent / ".working")
    parser.add_argument("--source", type=Path, help="canonical JSON copied once when no working copy exists")
    args = parser.parse_args()
    bundled_fixture = PROJECT_ROOT / "data" / "fixtures" / "dictionary.json"
    source = args.source or (bundled_fixture if bundled_fixture.exists() else None)
    store = WorkingCopyStore(args.working_dir, source)
    server = create_server(args.host, args.port, store)
    print(f"myJisho editor: http://{args.host}:{server.server_port}")
    print(f"Working copy: {store.path}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
