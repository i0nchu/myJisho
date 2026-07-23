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
| AC-02 Normalization | `tests/test_data_search.py`; `bundled_data_test.dart`; `fixture_dictionary_repository_test.dart`; canonical normalization golden JSON | Japanese product review of golden changes | PASS for named examples; corpus audit pending |
| AC-03 Deinflection | Python normalizer/search tests and Dart fixture search tests | Qualified Japanese review of 50 verb + 20 adjective corpus | PARTIAL |
| AC-04 Explainable ranking | deterministic search score/debug tests; reproducible SQLite builder | Search owner reviews intentional ranking changes | PASS |
| AC-05 Entry experience | Flutter entry/media/widget tests; responsive browser smoke | 20 entries must pass qualified editorial review | PARTIAL / EXTERNAL GATE |
| AC-06 Pronunciation | speech abstraction, synthesized-speech label and media widget tests | Offline TTS/audio and screen-reader test on all three platforms | PARTIAL / EXTERNAL GATE |
| AC-07 Personal data | user-library persistence tests; update handoff test keeps user repository separate | Release-build restart/update smoke | PASS automated; device check pending |
| AC-08 Desktop/mobile | desktop widget test; 390×844 and desktop browser smoke | Full keyboard/IME matrix on iOS, Windows and macOS | PARTIAL |
| AC-09 Accessibility | semantic tooltips and current widget/browser checks | Contrast measurement, 200% text, VoiceOver/Narrator and reduced-motion matrix | PARTIAL / EXTERNAL GATE |
| AC-10 Safe update | manifest/checksum/SQLite/rollback unit and integration tests | Published HTTPS package, interruption/disk-full tests and platform update smoke | PARTIAL |
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
- Engineering gaps still being closed: full search corpus, remote full-package
  update fault suite, accessibility automation and app performance evidence
