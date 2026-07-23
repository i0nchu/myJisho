# Security and supply-chain release evidence

Kotoba uses a versioned standard-library audit at
`tools/security_audit.py`. It reads the committed Flutter lockfile, queries the
OSV batch API for exact Pub package versions, verifies that every cached hosted
package has a license/notice file, scans Git-tracked text files for high-signal
secret formats and writes a CycloneDX 1.7 SBOM.

Run from repository root after `flutter pub get`:

```powershell
python tools/security_audit.py
```

Outputs:

- `build/security-audit.json`
- `build/kotoba.cdx.json`

The command exits nonzero for a reported vulnerability, a hosted dependency
without license evidence, a secret finding, an invalid lockfile or an
unavailable/malformed OSV response. A network failure is an infrastructure
failure, not a clean vulnerability result.

The tracked secret scan intentionally uses a small high-signal pattern set and
does not claim to replace repository-host secret protection or incident
response. The SBOM describes the locked Pub/Flutter dependency inventory; native
store packaging and operating-system components require platform release
evidence. CI uploads both reports, but production GO requires an actual report
from the exact release commit and review of every finding.
