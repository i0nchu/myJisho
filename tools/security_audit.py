"""Kotoba release supply-chain audit using only the Python standard library."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


SCHEMA_VERSION = "kotoba-security-audit-v1"
OSV_BATCH_URL = "https://api.osv.dev/v1/querybatch"
MAX_SCANNED_FILE_BYTES = 2 * 1024 * 1024


@dataclass(frozen=True)
class LockedPackage:
    name: str
    version: str
    source: str
    dependency: str
    content_sha256: str | None = None


class AuditInfrastructureError(RuntimeError):
    """The audit could not produce authoritative evidence."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_pub_lock(path: Path) -> list[LockedPackage]:
    """Parse the stable subset of pubspec.lock needed for release evidence."""

    packages: list[LockedPackage] = []
    current: dict[str, str] | None = None
    in_packages = False

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if raw_line == "packages:":
            in_packages = True
            continue
        if not in_packages:
            continue
        if raw_line and not raw_line.startswith(" "):
            break

        package_match = re.fullmatch(r"  ([A-Za-z0-9_]+):", raw_line)
        if package_match:
            if current is not None:
                packages.append(_locked_package(current, path))
            current = {"name": package_match.group(1)}
            continue
        if current is None:
            continue

        field_match = re.fullmatch(
            r'    (dependency|source|version):\s*"?([^"]+?)"?', raw_line
        )
        if field_match:
            current[field_match.group(1)] = field_match.group(2)
            continue
        hash_match = re.fullmatch(r'      sha256:\s*"?([0-9a-fA-F]{64})"?', raw_line)
        if hash_match:
            current["sha256"] = hash_match.group(1).lower()

    if current is not None:
        packages.append(_locked_package(current, path))
    if not packages:
        raise AuditInfrastructureError(f"no packages parsed from {path}")
    if len({package.name for package in packages}) != len(packages):
        raise AuditInfrastructureError(f"duplicate package in {path}")
    return sorted(packages, key=lambda package: package.name)


def _locked_package(fields: dict[str, str], path: Path) -> LockedPackage:
    missing = {"name", "version", "source", "dependency"} - fields.keys()
    if missing:
        raise AuditInfrastructureError(
            f"incomplete package record in {path}: {sorted(missing)}"
        )
    return LockedPackage(
        name=fields["name"],
        version=fields["version"],
        source=fields["source"],
        dependency=fields["dependency"],
        content_sha256=fields.get("sha256"),
    )


def query_osv(
    packages: Sequence[LockedPackage],
    *,
    endpoint: str = OSV_BATCH_URL,
    timeout_seconds: int = 30,
) -> list[dict[str, object]]:
    hosted = [package for package in packages if package.source == "hosted"]
    body = json.dumps(
        {
            "queries": [
                {
                    "package": {"ecosystem": "Pub", "name": package.name},
                    "version": package.version,
                }
                for package in hosted
            ]
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "Kotoba-security-audit/1",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            payload = json.load(response)
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as error:
        raise AuditInfrastructureError(f"OSV query failed: {error}") from error

    results = payload.get("results")
    if not isinstance(results, list) or len(results) != len(hosted):
        raise AuditInfrastructureError("OSV response does not match requested packages")

    findings: list[dict[str, object]] = []
    for package, result in zip(hosted, results, strict=True):
        if not isinstance(result, dict):
            raise AuditInfrastructureError("OSV result is not an object")
        vulnerabilities = result.get("vulns", [])
        if not isinstance(vulnerabilities, list):
            raise AuditInfrastructureError("OSV vulnerabilities field is not a list")
        for vulnerability in vulnerabilities:
            if not isinstance(vulnerability, dict):
                continue
            findings.append(
                {
                    "package": package.name,
                    "version": package.version,
                    "id": vulnerability.get("id"),
                    "aliases": vulnerability.get("aliases", []),
                    "summary": vulnerability.get("summary", ""),
                    "modified": vulnerability.get("modified"),
                }
            )
    return findings


def package_cache_roots() -> list[Path]:
    roots: list[Path] = []
    configured = os.environ.get("PUB_CACHE")
    if configured:
        roots.append(Path(configured))
    local_app_data = os.environ.get("LOCALAPPDATA")
    if local_app_data:
        roots.append(Path(local_app_data) / "Pub" / "Cache")
    roots.append(Path.home() / ".pub-cache")
    unique: list[Path] = []
    for root in roots:
        resolved = root.expanduser().resolve()
        if resolved not in unique:
            unique.append(resolved)
    return unique


def license_inventory(
    packages: Sequence[LockedPackage],
    *,
    cache_roots: Sequence[Path] | None = None,
) -> tuple[list[dict[str, object]], list[str]]:
    roots = list(cache_roots or package_cache_roots())
    inventory: list[dict[str, object]] = []
    missing: list[str] = []

    for package in packages:
        if package.source == "sdk":
            inventory.append(
                {
                    "package": package.name,
                    "version": package.version,
                    "source": "sdk",
                    "license_file": "provided by Flutter/Dart SDK notices",
                }
            )
            continue
        if package.source != "hosted":
            missing.append(f"{package.name}@{package.version}: unsupported source")
            continue

        package_directories = [
            root / "hosted" / "pub.dev" / f"{package.name}-{package.version}"
            for root in roots
        ]
        license_file: Path | None = None
        for directory in package_directories:
            if not directory.is_dir():
                continue
            candidates = sorted(
                candidate
                for candidate in directory.iterdir()
                if candidate.is_file()
                and re.match(r"^(LICENSE|LICENCE|COPYING|NOTICE)", candidate.name, re.I)
            )
            if candidates:
                license_file = candidates[0]
                break
        if license_file is None:
            missing.append(f"{package.name}@{package.version}")
            continue
        inventory.append(
            {
                "package": package.name,
                "version": package.version,
                "source": package.source,
                "license_file": license_file.name,
                "license_sha256": sha256_file(license_file),
            }
        )
    return inventory, missing


SECRET_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        "private_key",
        re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    ),
    ("github_fine_grained_token", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b")),
    ("github_token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b")),
    ("aws_access_key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("slack_token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b")),
)


def tracked_files(repository: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "-C", str(repository), "ls-files", "-z"],
        check=True,
        capture_output=True,
    )
    return [
        repository / item.decode("utf-8")
        for item in result.stdout.split(b"\0")
        if item
    ]


def scan_secret_files(
    repository: Path, files: Iterable[Path]
) -> list[dict[str, object]]:
    findings: list[dict[str, object]] = []
    for path in files:
        try:
            if not path.is_file() or path.stat().st_size > MAX_SCANNED_FILE_BYTES:
                continue
            raw = path.read_bytes()
        except OSError:
            continue
        if b"\0" in raw:
            continue
        text = raw.decode("utf-8", errors="replace")
        for line_number, line in enumerate(text.splitlines(), start=1):
            for kind, pattern in SECRET_PATTERNS:
                if pattern.search(line):
                    findings.append(
                        {
                            "kind": kind,
                            "file": path.relative_to(repository).as_posix(),
                            "line": line_number,
                        }
                    )
    return findings


def build_cyclonedx(
    packages: Sequence[LockedPackage],
    *,
    lock_sha256: str,
    app_version: str,
) -> dict[str, object]:
    components: list[dict[str, object]] = []
    for package in packages:
        component: dict[str, object] = {
            "type": "library",
            "bom-ref": f"pkg:pub/{urllib.parse.quote(package.name)}@{package.version}",
            "name": package.name,
            "version": package.version,
            "scope": "optional"
            if package.dependency == "direct dev"
            else "required",
            "purl": f"pkg:pub/{urllib.parse.quote(package.name)}@{package.version}",
            "properties": [
                {"name": "kotoba:pub-source", "value": package.source},
                {"name": "kotoba:dependency-kind", "value": package.dependency},
            ],
        }
        if package.content_sha256:
            component["hashes"] = [
                {"alg": "SHA-256", "content": package.content_sha256}
            ]
        components.append(component)

    serial = uuid.uuid5(uuid.NAMESPACE_URL, f"kotoba:{lock_sha256}")
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.7",
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
            "component": {
                "type": "application",
                "bom-ref": f"pkg:generic/kotoba_dictionary_app@{urllib.parse.quote(app_version)}",
                "name": "kotoba_dictionary_app",
                "version": app_version,
                "purl": f"pkg:generic/kotoba_dictionary_app@{urllib.parse.quote(app_version)}",
            },
            "properties": [
                {"name": "kotoba:pubspec-lock-sha256", "value": lock_sha256}
            ],
        },
        "components": components,
    }


def read_app_version(pubspec: Path) -> str:
    for line in pubspec.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r'version:\s*"?([^"]+)"?', line)
        if match:
            return match.group(1)
    raise AuditInfrastructureError(f"version not found in {pubspec}")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repository", type=Path, default=Path(__file__).resolve().parents[1]
    )
    parser.add_argument(
        "--lock", type=Path, default=Path("apps/dictionary_app/pubspec.lock")
    )
    parser.add_argument(
        "--pubspec", type=Path, default=Path("apps/dictionary_app/pubspec.yaml")
    )
    parser.add_argument(
        "--output", type=Path, default=Path("build/security-audit.json")
    )
    parser.add_argument(
        "--sbom", type=Path, default=Path("build/kotoba.cdx.json")
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    repository = args.repository.resolve()
    lock = args.lock if args.lock.is_absolute() else repository / args.lock
    pubspec = args.pubspec if args.pubspec.is_absolute() else repository / args.pubspec
    output = args.output if args.output.is_absolute() else repository / args.output
    sbom_path = args.sbom if args.sbom.is_absolute() else repository / args.sbom

    try:
        packages = parse_pub_lock(lock)
        lock_hash = sha256_file(lock)
        vulnerabilities = query_osv(packages)
        licenses, missing_licenses = license_inventory(packages)
        secret_findings = scan_secret_files(repository, tracked_files(repository))
        sbom = build_cyclonedx(
            packages,
            lock_sha256=lock_hash,
            app_version=read_app_version(pubspec),
        )
    except (AuditInfrastructureError, OSError, subprocess.CalledProcessError) as error:
        print(f"security audit infrastructure failure: {error}", file=sys.stderr)
        return 2

    failed = bool(vulnerabilities or missing_licenses or secret_findings)
    report = {
        "schema": SCHEMA_VERSION,
        "status": "fail" if failed else "pass",
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "pubspec_lock_sha256": lock_hash,
        "package_count": len(packages),
        "hosted_package_count": sum(
            package.source == "hosted" for package in packages
        ),
        "osv": {
            "endpoint": OSV_BATCH_URL,
            "vulnerabilities": vulnerabilities,
        },
        "licenses": {
            "inventory": licenses,
            "missing": missing_licenses,
        },
        "secret_scan": {
            "patterns": [name for name, _ in SECRET_PATTERNS],
            "findings": secret_findings,
        },
        "sbom": {
            "format": "CycloneDX",
            "spec_version": sbom["specVersion"],
            "path": sbom_path.relative_to(repository).as_posix(),
        },
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    sbom_path.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", "utf-8")
    sbom_path.write_text(json.dumps(sbom, ensure_ascii=False, indent=2) + "\n", "utf-8")

    print(
        "KOTOBA_SECURITY_AUDIT "
        f"status={report['status']} packages={len(packages)} "
        f"vulnerabilities={len(vulnerabilities)} "
        f"missing_licenses={len(missing_licenses)} "
        f"secret_findings={len(secret_findings)}"
    )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
