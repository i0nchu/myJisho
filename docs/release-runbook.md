# Kotoba Release Runbook

- Owner: Release / QA
- Applies to: iOS, Windows, macOS
- Current production status: NO-GO until every mandatory gate below has evidence

This runbook turns a reviewed canonical dictionary and a tagged application
revision into auditable release artifacts. A successful command is evidence
only for the step it executes; CI builds do not replace device checks or
editorial approval.

## 1. Freeze release inputs

1. Choose an application version and dictionary version. Record the Git commit.
2. Freeze canonical JSON, source/license evidence, media, schema version and
   search-rules version.
3. Confirm the worktree is clean and the release commit is reachable from the
   protected release branch.
4. Create an evidence directory outside generated source:
   `release-evidence/<version>/`.

Required record:

```text
app_version:
dictionary_version:
git_commit:
schema_version:
search_rules_version:
release_owner:
editorial_owner:
qa_owner:
```

## 2. Editorial and licensing gate

Production data must not use `--allow-unreviewed`.

```powershell
python -m tools.database_builder `
  data/fixtures/dictionary.json `
  release-evidence/<version>/dictionary.sqlite `
  --report release-evidence/<version>/build-report.json `
  --release-dir release-evidence/<version>
```

Stop the release if the validator reports an AI draft, missing qualified human
review evidence, missing provenance/license data, unsafe media path, broken
relation, schema mismatch or invalid SQLite. Preserve the failed report; do not
edit generated SQLite to bypass canonical validation.

The editorial owner signs the exact canonical-data checksum and report. At
least 20 complete featured entries must be approved or published.

## 3. Engineering verification

From repository root:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/verify.ps1
python tools/security_audit.py
git diff --check
git status --short
```

Record command output, test counts, benchmark dataset checksum, P50/P95/max,
security audit/SBOM and Web build warnings. Any P0 failure is NO-GO. A rerun
may confirm a suspected environment issue, but must not hide a flaky gate;
record owner and defect.

## 4. Platform artifacts

CI must build the exact release commit. Download artifacts without repacking,
then record SHA-256 and CI run URL.

| Platform | Required CI command | Required artifact |
|---|---|---|
| Windows | `flutter build windows --release` | signed application directory/installer |
| macOS | `flutter build macos --release` | signed/notarized app or distribution image |
| iOS | `flutter build ipa --release` | signed archive/IPA from configured Apple team |

The current debug/simulator CI jobs are preflight only. Production GO requires
release signing identities, bundle IDs, entitlements, version/build numbers,
notarization where applicable, artifact checksums and installation evidence.

## 5. Dictionary package publication

1. Copy only builder-produced database, assets, manifests and checksums into an
   immutable versioned package location.
2. Confirm the manifest uses the release channel, reviewed content state,
   compatible schema/minimum app version, exact byte sizes and SHA-256 values.
3. Upload to the selected HTTPS package host without changing bytes.
4. Fetch the published objects from a clean environment, verify checksums and
   run SQLite `quick_check`.
5. Update the release pointer only after the immutable package passes the
   client fault suite. Keep the previous known-good package address available.

SHA-256 detects changed bytes but does not by itself authenticate a compromised
host. Package-host trust, optional manifest signing, key rotation and
revocation are explicit security decisions before public rollout.

## 6. Device acceptance

Execute the platform matrix in `docs/testing-strategy.md`. Minimum production
evidence:

- iOS physical device: clean install, offline launch/search, Japanese IME,
  TTS/audio, favorites/history restart, update success/failure and VoiceOver.
- Windows physical/virtual release environment: installer, Microsoft IME,
  desktop keyboard flow, TTS/audio, update/rollback and Narrator.
- macOS physical release environment: notarized launch, Japanese IME,
  keyboard flow, TTS/audio, update/rollback and VoiceOver.
- 200% text, light/dark/high-contrast behavior and reduced-motion checks.
- Cold-start P95 and input-to-first-result P95 using the release build and
  protocol in `docs/testing-strategy.md`.

Attach device/OS/app/database versions, tester, timestamp and pass/fail notes.
Screenshots alone are not evidence for audio, persistence, latency or rollback.

## 7. Go / no-go meeting

GO requires:

- all AC-01 through AC-12 evidence rows marked PASS;
- production content/license validator PASS;
- immutable package and three release artifacts verified;
- required platform/device matrix complete;
- zero open Blocker/Critical defects;
- every accepted Major defect has an owner and does not violate P0;
- rollback owner, previous package and customer-support message prepared.

Record approvers from Product/Customer, Engineering, Editorial/Licensing and
QA/Release. If any mandatory row is missing, the decision is NO-GO.

## 8. Rollout and rollback

Use a staged rollout when the selected stores/host permit it. Monitor only
privacy-approved aggregate crash/update signals; Kotoba must not upload queries,
favorites or history.

Rollback trigger examples: startup/database-open regression, incorrect or
unlicensed content, update loop, personal-data loss, severe TTS/IME regression.
Freeze the release pointer, restore the previous immutable package/store
version, publish a customer notice, preserve evidence and open an incident.
Never reuse a dictionary version or stable ID for different content.

## 9. Closeout

Archive the Git commit, CI URLs, checksums, build/data/license reports, device
matrix, performance report, known issues, approvals and rollout/rollback
decision. Update `docs/traceability-matrix.md` and the customer review report.
