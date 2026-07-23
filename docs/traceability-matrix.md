# Kotoba MVP Traceability Matrix

- Baseline: `docs/product-spec.md`
- Platforms: iOS, Windows, macOS
- Status vocabulary: PASS, PARTIAL, EXTERNAL GATE, FAIL
- Last audit: 2026-07-23

PASS means the cited evidence directly covers the acceptance criterion. PARTIAL
means useful evidence exists but the full criterion is not proven. EXTERNAL GATE
requires a qualified reviewer, CI service, signing identity or target device
that local automation cannot replace.

| AC | Automated / repository evidence | Manual / external evidence | Status |
|---|---|---|---|
| AC-01 First launch | Flutter App has offline fixture/SQLite repositories and widget smoke tests | Release cold-start P95, clean offline install and initial focus on target devices | PARTIAL |
| AC-02 Normalization | 250-case globally unique corpus; Python canonical runtime and 235-row temporary SQLite through deployed Drift; exact/prefix/last-resort contains and checksum/anti-padding tests | Japanese product review of golden language expectations | PASS automated / EXTERNAL REVIEW |
| AC-03 Deinflection | 50 distinct verb lemmas + 20 adjective cases pass Python and deployed Drift paths; Dart parity tests cover all P0 rule families, confidence and `食べられない → 食べる` | Qualified Japanese review of inflection expectations | PASS automated / EXTERNAL REVIEW |
| AC-04 Explainable ranking | Python/Dart share featured +80, curated +40, imported +0 and deinflection uncertainty 0..-100; 20 ambiguity orders and SearchHit raw/modifier/final/deinflection evidence are deterministic | Search owner reviews intentional ranking changes | PASS |
| AC-05 Entry experience | Flutter entry/media/widget tests; responsive browser smoke | 20 entries must pass qualified editorial review | PARTIAL / EXTERNAL GATE |
| AC-06 Pronunciation | speech abstraction, synthesized-speech label and media widget tests | Offline TTS/audio and screen-reader test on all three platforms | PARTIAL / EXTERNAL GATE |
| AC-07 Personal data | user-library persistence tests; update handoff test keeps user repository separate | Release-build restart/update smoke | PASS automated; device check pending |
| AC-08 Desktop/mobile | 11-case AC-08/09 suite covers 390×844, 1200×800, keyboard selection, Space guard and shortcut disable; browser smoke confirms latest build | Full keyboard/IME matrix on iOS, Windows and macOS | PASS automated / EXTERNAL DEVICE |
| AC-09 Accessibility | 200% text, semantic/focus labels, non-color status, 4.5:1 core contrast, reduced-motion routes and LicensePage tests | VoiceOver/Narrator, system high contrast and full platform focus order | PASS automated / EXTERNAL DEVICE |
| AC-10 Safe update | 24 update tests cover HTTPS, fixed package contract, progress/cancel, interruption/disk-full, size/hash/assets/checksums, assets↔SQLite binding, pre-open recovery, real Drift readiness and rollback | Select/publish HTTPS host and run platform fault smoke; signing/key rotation decision | PASS automated / EXTERNAL CONFIG+DEVICE |
| AC-11 Traceable release | schema/data/license/review validator tests; deterministic builder; editor audit workflow/security tests | Editorial/licensing sign-off for exact production input checksum | PASS mechanism; EXTERNAL GATE for content |
| AC-12 Platform RC | committed iOS/Windows/macOS runners and CI jobs | Successful release artifacts, signing and recorded device smoke for all three platforms | EXTERNAL GATE |

## Evidence commands

```powershell
python -m unittest discover -s tests -v
python -m unittest discover -s services/editor_api/tests -v
powershell -ExecutionPolicy Bypass -File scripts/verify.ps1
git diff --check
```

The CI run URL, immutable artifact IDs and device records are intentionally not
pre-filled. They must refer to the exact release commit; a workflow definition
or local Web build is not proof that Apple/Windows jobs ran.

## Current release decision

- Engineering MVP / customer review: GO
- Production release: NO-GO
- External mandatory gates: qualified Japanese editorial approval, production
  signing/CI artifacts and iOS/Windows/macOS device acceptance
- Remaining product evidence: release-device cold start and real SQLite UI P95
- Remaining external decisions: HTTPS package host, manifest-signing policy and
  exact build-time endpoints
- Current supply-chain audit: 106 locked / 102 hosted packages, OSV 0
  vulnerabilities, 0 missing license files, 0 high-signal tracked secrets;
  exact-release CI report and CycloneDX SBOM review remain required
