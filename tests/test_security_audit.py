from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from tools.security_audit import (
    LockedPackage,
    build_cyclonedx,
    license_inventory,
    parse_pub_lock,
    scan_secret_files,
)


class SecurityAuditTests(unittest.TestCase):
    def test_parses_hosted_and_sdk_lock_records(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "pubspec.lock"
            lock.write_text(
                """packages:
  alpha:
    dependency: "direct main"
    description:
      name: alpha
      sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    source: hosted
    version: "1.2.3"
  flutter:
    dependency: "direct main"
    description: flutter
    source: sdk
    version: "0.0.0"
sdks:
  dart: ">=3.0.0"
""",
                encoding="utf-8",
            )
            packages = parse_pub_lock(lock)
        self.assertEqual([package.name for package in packages], ["alpha", "flutter"])
        self.assertEqual(packages[0].content_sha256, "a" * 64)
        self.assertEqual(packages[1].source, "sdk")

    def test_license_inventory_requires_every_hosted_package(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            package = cache / "hosted" / "pub.dev" / "alpha-1.2.3"
            package.mkdir(parents=True)
            (package / "LICENSE").write_text("MIT License\n", encoding="utf-8")
            packages = [
                LockedPackage("alpha", "1.2.3", "hosted", "direct main"),
                LockedPackage("flutter", "0.0.0", "sdk", "direct main"),
            ]
            inventory, missing = license_inventory(packages, cache_roots=[cache])
        self.assertFalse(missing)
        self.assertEqual(len(inventory), 2)
        self.assertEqual(inventory[0]["license_file"], "LICENSE")

    def test_secret_scan_reports_location_without_secret_value(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            safe = repository / "safe.txt"
            unsafe = repository / "unsafe.txt"
            safe.write_text("AKIA is documentation, not a key\n", encoding="utf-8")
            unsafe.write_text(
                "token=" + "AKIA" + "ABCDEFGHIJKLMNOP" + "\n",
                encoding="utf-8",
            )
            findings = scan_secret_files(repository, [safe, unsafe])
        self.assertEqual(
            findings,
            [{"kind": "aws_access_key", "file": "unsafe.txt", "line": 1}],
        )
        self.assertNotIn("AKIA", json.dumps(findings))

    def test_cyclonedx_has_deterministic_components_and_lock_identity(self) -> None:
        packages = [
            LockedPackage(
                "alpha",
                "1.2.3",
                "hosted",
                "direct main",
                content_sha256="a" * 64,
            )
        ]
        first = build_cyclonedx(
            packages, lock_sha256="b" * 64, app_version="0.1.0+1"
        )
        second = build_cyclonedx(
            packages, lock_sha256="b" * 64, app_version="0.1.0+1"
        )
        self.assertEqual(first["serialNumber"], second["serialNumber"])
        self.assertEqual(first["specVersion"], "1.7")
        self.assertEqual(
            first["components"][0]["purl"], "pkg:pub/alpha@1.2.3"
        )
        self.assertEqual(
            first["components"][0]["hashes"][0]["content"], "a" * 64
        )


if __name__ == "__main__":
    unittest.main()
