"""Dependency-free HTTP API for Kotoba's self-hosted local dictionary."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
from typing import Any
from urllib.parse import parse_qs, unquote, urlsplit

from .generation import DictionaryGenerator, GenerationError
from .providers import OpenAICompatibleLLMProvider, WikimediaSearchProvider
from .storage import (
    LocalDictionaryStore,
    StoreConflictError,
    StoreValidationError,
)


JOB_ROUTE = re.compile(r"^/api/generation-jobs/([^/]+?)(/retry)?$")
ENTRY_ROUTE = re.compile(
    r"^/api/entries/([^/]+?)(/revisions|/restore|/regenerate|/lock)?$"
)
ENTRY_REVISION_ROUTE = re.compile(r"^/api/entries/([^/]+?)/revisions/([1-9][0-9]*)$")


class LocalDictionaryHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        store: LocalDictionaryStore,
        generator: DictionaryGenerator,
        *,
        api_token: str = "",
        allowed_hosts: set[str] | None = None,
    ):
        if api_token and (
            len(api_token) < 32
            or len(api_token) > 512
            or any(character.isspace() for character in api_token)
        ):
            raise ValueError(
                "API token must contain 32 to 512 non-whitespace characters"
            )
        bind_host = _bind_host(address[0], allow_remote=bool(api_token))
        bind_address = ipaddress.ip_address(bind_host)
        if bind_address.version == 6:
            self.address_family = socket.AF_INET6
        super().__init__((bind_host, address[1]), LocalDictionaryHandler)
        self.store = store
        self.generator = generator
        self.api_token = api_token
        self.worker_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="kotoba-generate")
        resolved_allowed_hosts = {
            item.strip().lower()
            for item in (allowed_hosts or set())
            if item.strip()
        }
        if bind_address in {
            ipaddress.ip_address("127.0.0.1"),
            ipaddress.ip_address("::1"),
        }:
            resolved_allowed_hosts.update({bind_address.compressed, "localhost"})
        if bind_address.is_unspecified:
            resolved_allowed_hosts.update({"127.0.0.1", "::1", "localhost"})
        if not resolved_allowed_hosts:
            resolved_allowed_hosts.add(bind_address.compressed)
        self.allowed_hosts = frozenset(resolved_allowed_hosts)

    def server_close(self) -> None:
        self.worker_pool.shutdown(wait=False, cancel_futures=False)
        self.store.close()
        super().server_close()

    def create_generation_job(
        self,
        query: str,
        *,
        force: bool = False,
        existing_entry: dict[str, Any] | None = None,
        origin: str = "generated",
    ) -> dict[str, Any]:
        job = self.store.start_job(query, force=force)
        reused = bool(job.pop("_reused", False))
        if job["status"] == "generating" and not reused:
            self.worker_pool.submit(
                self._run_generation,
                job["job_id"],
                query,
                existing_entry,
                origin,
            )
        return job

    def _run_generation(
        self,
        job_id: str,
        query: str,
        existing_entry: dict[str, Any] | None,
        origin: str,
    ) -> None:
        try:
            entry = self.generator.generate(
                query,
                origin=origin,
                existing_entry=existing_entry,
                existing_form_keys=self.store.existing_form_keys(
                    excluding_entry_id=(
                        existing_entry.get("entry_id") if existing_entry else None
                    )
                ),
            )
            self.store.complete_job(job_id, entry)
        except GenerationError as error:
            self.store.fail_job(job_id, error.to_json())
        except Exception as error:
            self.store.fail_job(
                job_id,
                {
                    "code": "internal_error",
                    "message": f"生成工作失敗：{error}",
                    "issues": [],
                    "retryable": True,
                },
            )


class LocalDictionaryHandler(BaseHTTPRequestHandler):
    server: LocalDictionaryHTTPServer
    protocol_version = "HTTP/1.1"
    max_body_bytes = 2 * 1024 * 1024

    def do_GET(self) -> None:  # noqa: N802
        if not self._guard_request(mutating=False):
            return
        route = urlsplit(self.path)
        if route.path == "/api/health":
            self._json(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "service": "kotoba-local-dictionary",
                    "model": self.server.generator.llm.model,
                },
            )
            return
        if route.path == "/api/schema":
            from .schema_validation import load_schema

            self._json(HTTPStatus.OK, {"schema": load_schema()})
            return
        if route.path == "/api/search":
            query = parse_qs(route.query).get("q", [""])[0][:200]
            self._json(HTTPStatus.OK, {"entries": self.server.store.search(query)})
            return
        if route.path == "/api/entries":
            raw_limit = parse_qs(route.query).get("limit", ["10000"])[0]
            try:
                limit = int(raw_limit)
                self._json(
                    HTTPStatus.OK,
                    {"entries": self.server.store.all_entries(limit=limit)},
                )
            except ValueError as error:
                self._error(HTTPStatus.BAD_REQUEST, "bad_request", str(error))
            return
        job_match = JOB_ROUTE.fullmatch(route.path)
        if job_match and not job_match.group(2):
            try:
                self._json(
                    HTTPStatus.OK,
                    {"job": self.server.store.get_job(unquote(job_match.group(1)))},
                )
            except KeyError:
                self._error(HTTPStatus.NOT_FOUND, "not_found", "generation job was not found")
            return
        revision_match = ENTRY_REVISION_ROUTE.fullmatch(route.path)
        if revision_match:
            try:
                entry_id = unquote(revision_match.group(1))
                revision = int(revision_match.group(2))
                self._json(
                    HTTPStatus.OK,
                    {
                        "entry_id": entry_id,
                        "revision": revision,
                        "entry": self.server.store.get_revision(entry_id, revision),
                    },
                )
            except KeyError:
                self._error(
                    HTTPStatus.NOT_FOUND,
                    "not_found",
                    "entry revision was not found",
                )
            return
        entry_match = ENTRY_ROUTE.fullmatch(route.path)
        if entry_match:
            entry_id = unquote(entry_match.group(1))
            suffix = entry_match.group(2)
            try:
                if suffix == "/revisions":
                    self._json(
                        HTTPStatus.OK,
                        {
                            "entry_id": entry_id,
                            "revisions": self.server.store.list_revisions(entry_id),
                        },
                    )
                    return
                if suffix is not None:
                    self._error(HTTPStatus.METHOD_NOT_ALLOWED, "method_not_allowed", "use POST for this route")
                    return
                entry = self.server.store.get_entry(entry_id)
                if entry is None:
                    raise KeyError(entry_id)
                self._json(HTTPStatus.OK, {"entry": entry})
            except KeyError:
                self._error(HTTPStatus.NOT_FOUND, "not_found", "entry was not found")
            return
        self._error(HTTPStatus.NOT_FOUND, "not_found", "route was not found")

    def do_POST(self) -> None:  # noqa: N802
        if not self._guard_request(mutating=True):
            return
        route = urlsplit(self.path)
        try:
            if route.path == "/api/generation-jobs":
                payload = self._body()
                query = str(payload.get("query", "")).strip()
                job = self.server.create_generation_job(query)
                status = HTTPStatus.OK if job["status"] == "ready" else HTTPStatus.ACCEPTED
                self._json(status, {"job": job})
                return
            job_match = JOB_ROUTE.fullmatch(route.path)
            if job_match and job_match.group(2) == "/retry":
                prior = self.server.store.get_job(unquote(job_match.group(1)))
                if prior["status"] != "failed":
                    raise StoreConflictError("only failed jobs can be retried")
                job = self.server.create_generation_job(prior["query"])
                status = HTTPStatus.OK if job["status"] == "ready" else HTTPStatus.ACCEPTED
                self._json(status, {"job": job})
                return
            entry_match = ENTRY_ROUTE.fullmatch(route.path)
            if entry_match:
                entry_id = unquote(entry_match.group(1))
                suffix = entry_match.group(2)
                if suffix == "/restore":
                    payload = self._body()
                    revision = int(payload.get("revision", 0))
                    entry = self.server.store.restore_revision(entry_id, revision)
                    self._json(HTTPStatus.OK, {"entry": entry})
                    return
                if suffix == "/lock":
                    payload = self._body()
                    locked = payload.get("locked")
                    if not isinstance(locked, bool):
                        raise ValueError("locked must be boolean")
                    entry = self.server.store.set_locked(entry_id, locked)
                    self._json(HTTPStatus.OK, {"entry": entry})
                    return
                if suffix == "/regenerate":
                    entry = self.server.store.get_entry(entry_id)
                    if entry is None:
                        raise KeyError(entry_id)
                    if entry.get("locked") is True:
                        raise StoreConflictError("entry is locked and cannot be regenerated")
                    job = self.server.create_generation_job(
                        entry["headword"],
                        force=True,
                        existing_entry=entry,
                        origin="regenerated",
                    )
                    self._json(HTTPStatus.ACCEPTED, {"job": job})
                    return
            self._error(HTTPStatus.NOT_FOUND, "not_found", "route was not found")
        except Exception as error:
            self._handle_exception(error)

    def do_PUT(self) -> None:  # noqa: N802
        if not self._guard_request(mutating=True):
            return
        route = urlsplit(self.path)
        match = ENTRY_ROUTE.fullmatch(route.path)
        if not match or match.group(2):
            self._error(HTTPStatus.NOT_FOUND, "not_found", "route was not found")
            return
        try:
            entry_id = unquote(match.group(1))
            payload = self._body()
            patch = payload.get("patch")
            if not isinstance(patch, dict):
                raise ValueError("patch must be a JSON object")
            entry = self.server.store.edit_entry(entry_id, patch)
            self._json(HTTPStatus.OK, {"entry": entry})
        except Exception as error:
            self._handle_exception(error)

    def do_DELETE(self) -> None:  # noqa: N802
        if not self._guard_request(mutating=True):
            return
        route = urlsplit(self.path)
        match = ENTRY_ROUTE.fullmatch(route.path)
        if not match or match.group(2):
            self._error(HTTPStatus.NOT_FOUND, "not_found", "route was not found")
            return
        try:
            self.server.store.delete_entry(unquote(match.group(1)))
            self._send(HTTPStatus.NO_CONTENT, b"", "application/json")
        except Exception as error:
            self._handle_exception(error)

    def _body(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as error:
            raise ValueError("invalid Content-Length") from error
        if length <= 0 or length > self.max_body_bytes:
            raise ValueError(f"body size must be between 1 and {self.max_body_bytes} bytes")
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("body must be valid UTF-8 JSON") from error
        if not isinstance(payload, dict):
            raise ValueError("body must be a JSON object")
        return payload

    def _guard_request(self, *, mutating: bool) -> bool:
        try:
            request_origin = self._request_origin()
        except ValueError:
            self.close_connection = True
            self._error(
                HTTPStatus.MISDIRECTED_REQUEST,
                "invalid_host",
                "Host is not allowed for this server",
            )
            return False
        if self.server.api_token:
            authorization = self.headers.get_all("Authorization", failobj=[])
            expected = f"Bearer {self.server.api_token}"
            if len(authorization) != 1 or not hmac.compare_digest(
                authorization[0],
                expected,
            ):
                self._error(
                    HTTPStatus.UNAUTHORIZED,
                    "unauthorized",
                    "a valid bearer token is required",
                )
                return False
        if not mutating:
            return True
        origins = self.headers.get_all("Origin", failobj=[])
        if len(origins) > 1:
            self._error(HTTPStatus.FORBIDDEN, "forbidden_origin", "cross-origin mutation is not allowed")
            return False
        if origins:
            try:
                origin = _parse_origin(origins[0])
            except ValueError:
                origin = None
            if origin != request_origin:
                self._error(HTTPStatus.FORBIDDEN, "forbidden_origin", "cross-origin mutation is not allowed")
                return False
        fetch_sites = self.headers.get_all("Sec-Fetch-Site", failobj=[])
        if len(fetch_sites) > 1 or any(
            value.strip().lower() != "same-origin" for value in fetch_sites
        ):
            self._error(HTTPStatus.FORBIDDEN, "forbidden_origin", "Sec-Fetch-Site must be same-origin")
            return False
        return True

    def _request_origin(self) -> tuple[str, str, int]:
        values = self.headers.get_all("Host", failobj=[])
        if len(values) != 1:
            raise ValueError("exactly one Host header is required")
        raw = values[0]
        forwarded_hosts = self.headers.get_all("X-Forwarded-Host", failobj=[])
        forwarded_protocols = self.headers.get_all("X-Forwarded-Proto", failobj=[])
        is_trusted_proxy_request = bool(forwarded_hosts or forwarded_protocols)
        if is_trusted_proxy_request:
            if (
                len(forwarded_hosts) != 1
                or len(forwarded_protocols) != 1
                or forwarded_protocols[0].strip().lower() != "https"
                or not _is_loopback_hostname(self.client_address[0])
            ):
                raise ValueError("invalid reverse-proxy headers")
            raw = forwarded_hosts[0]
        if raw != raw.strip() or any(character in raw for character in "/\\@,?#"):
            raise ValueError("invalid Host header")
        parsed = urlsplit(f"//{raw}")
        hostname = parsed.hostname
        port = parsed.port
        if not hostname or parsed.username is not None or parsed.password is not None:
            raise ValueError("invalid Host header")
        hostname = hostname.lower()
        if hostname not in self.server.allowed_hosts:
            raise ValueError("Host is not the bound loopback address")
        if _is_loopback_hostname(hostname) and not is_trusted_proxy_request:
            effective_port = port if port is not None else 80
            if effective_port != self.server.server_port:
                raise ValueError("Host port does not match the server")
            return "http", hostname, effective_port
        if _is_loopback_hostname(hostname):
            raise ValueError("reverse proxy must provide a non-loopback host")
        if port not in {None, 443}:
            raise ValueError("reverse-proxy Host port must be 443")
        return "https", hostname, 443

    def _handle_exception(self, error: Exception) -> None:
        if isinstance(error, StoreConflictError):
            self._error(HTTPStatus.CONFLICT, "conflict", str(error))
        elif isinstance(error, StoreValidationError):
            self._json(
                HTTPStatus.UNPROCESSABLE_ENTITY,
                {
                    "error": {
                        "code": "validation_failed",
                        "message": "entry failed automatic validation",
                        "issues": error.issues,
                        "retryable": True,
                    },
                },
            )
        elif isinstance(error, KeyError):
            self._error(HTTPStatus.NOT_FOUND, "not_found", "entry or revision was not found")
        elif isinstance(error, (TypeError, ValueError)):
            self._error(HTTPStatus.BAD_REQUEST, "bad_request", str(error))
        else:
            self.log_error("internal error: %r", error)
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "internal_error", "request could not be completed")

    def _json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        self._send(
            status,
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
            "application/json; charset=utf-8",
        )

    def _error(self, status: HTTPStatus, code: str, message: str) -> None:
        self._json(status, {"error": {"code": code, "message": message}})

    def _send(self, status: HTTPStatus, content: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if content:
            self.wfile.write(content)

    def log_message(self, format: str, *args: Any) -> None:
        print(f"{self.address_string()} - {format % args}")


def _parse_origin(raw: str) -> tuple[str, str, int]:
    if raw != raw.strip():
        raise ValueError("invalid Origin header")
    parsed = urlsplit(raw)
    if (
        parsed.scheme.lower() not in {"http", "https"}
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("invalid Origin header")
    scheme = parsed.scheme.lower()
    default_port = 443 if scheme == "https" else 80
    return scheme, parsed.hostname.lower(), parsed.port if parsed.port is not None else default_port


def _is_loopback_hostname(hostname: str) -> bool:
    if hostname == "localhost":
        return True
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


def _bind_host(host: str, *, allow_remote: bool) -> str:
    candidate = host.strip()
    if candidate.lower() == "localhost":
        candidate = "127.0.0.1"
    try:
        address = ipaddress.ip_address(candidate)
    except ValueError as error:
        raise ValueError("listen address must be an IP loopback address or localhost") from error
    if not address.is_loopback and not allow_remote:
        raise ValueError("a non-loopback listen address requires an API token")
    return address.compressed


def create_server(
    host: str,
    port: int,
    store: LocalDictionaryStore,
    generator: DictionaryGenerator,
    *,
    api_token: str = "",
    allowed_hosts: set[str] | None = None,
) -> LocalDictionaryHTTPServer:
    return LocalDictionaryHTTPServer(
        (host, port),
        store,
        generator,
        api_token=api_token,
        allowed_hosts=allowed_hosts,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the Kotoba self-hosted local dictionary API")
    parser.add_argument(
        "--host",
        default=os.environ.get("KOTOBA_API_HOST", "127.0.0.1"),
    )
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument(
        "--database",
        type=Path,
        default=Path(__file__).parent / ".working" / "local_dictionary.sqlite",
    )
    parser.add_argument("--llm-base-url")
    parser.add_argument("--model")
    parser.add_argument(
        "--api-token",
        default=os.environ.get("KOTOBA_API_TOKEN", ""),
        help="Bearer token. Required when binding to a non-loopback address.",
    )
    parser.add_argument(
        "--allowed-host",
        action="append",
        default=[],
        help="Accepted HTTP Host name; repeat for reverse-proxy host names.",
    )
    args = parser.parse_args()
    env_allowed_hosts = {
        item.strip()
        for item in os.environ.get("KOTOBA_ALLOWED_HOSTS", "").split(",")
        if item.strip()
    }
    store = LocalDictionaryStore(args.database)
    generator = DictionaryGenerator(
        WikimediaSearchProvider(),
        OpenAICompatibleLLMProvider(
            base_url=args.llm_base_url,
            model=args.model,
        ),
    )
    server = create_server(
        args.host,
        args.port,
        store,
        generator,
        api_token=args.api_token,
        allowed_hosts=env_allowed_hosts.union(args.allowed_host),
    )
    print(f"Kotoba local dictionary API: http://{args.host}:{server.server_port}")
    print(f"Database: {store.path}")
    print(f"Model: {generator.llm.model}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
