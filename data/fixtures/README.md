# myJisho fixtures

`dictionary.json` is a canonical-schema test corpus containing 24 original,
CC0-1.0 fixture entries. It intentionally covers kanji, hiragana, katakana,
romaji, verb/adjective inflection, same-reading ambiguity, and easily confused
words. These are prototype data, not claims copied from a commercial dictionary.

All definitions and examples are marked as AI-assisted drafts. The license
allows redistribution, but editorial policy independently prevents shipping
them as approved content until a qualified human reviewer records approval.

`normalization_golden.json` is the cross-runtime conformance contract. Python
and Dart implementations should produce identical values for every case.

Build the fixture database and release package from the repository root:

```powershell
python -m tools.database_builder data/fixtures/dictionary.json build/dictionary-release/dictionary.sqlite --report build/dictionary-release/build-report.json --release-dir build/dictionary-release --allow-unreviewed
```

`--allow-unreviewed` is limited to development packages. It produces a manifest
with `channel: development` and `content_status: contains_unreviewed`; omitting
the flag blocks release artifacts while any entry is not approved or published.
