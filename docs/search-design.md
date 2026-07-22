# Kotoba search design

Status: Python MVP, search contract version 1
Owner: Search Engine

## Goals

Search is offline, deterministic, debuggable, and independent of Flutter UI. It
must find a useful lemma from kanji, hiragana, katakana, common Hepburn romaji,
or a common inflected form. P0 deliberately excludes edit-distance fuzzy search
and definition full-text search; their schema extension points remain available.

The implementation is split into pure normalization
(`packages/japanese_normalizer`) and read-only SQLite ranking
(`packages/search_engine`). The database builder uses the same normalizer to
precompute keys. `data/fixtures/normalization_golden.json` is the cross-runtime
contract that the Dart implementation must also pass.

## Query pipeline

The raw query is retained for UI explanation. Search then performs the following
ordered stages:

1. NFKC normalization, case folding, trim, extra-space and Japanese punctuation removal.
2. Half-width/full-width normalization and katakana-to-hiragana conversion.
3. Long-vowel expansion for the kana comparison key (`コーヒー` → `こおひい`).
4. Exact primary form, alternate form, or reading lookup.
5. Common Hepburn romaji conversion, including consonant doubling, syllabic
   `n`, `shimbun`/`shinbun`, `hirou`, and the accepted learner spelling `hirowu`.
6. Multi-candidate verb/adjective deinflection followed by lexicon verification.
7. Indexed primary-form/reading prefix lookup.
8. Substring fallback only when no stronger stage produced a candidate.

Normalization never overwrites the raw query. Romaji conversion may return
multiple candidates (`ou` ambiguity). Deinflection is intentionally generative:
it returns possible lemmas and confidence rather than claiming a single parse.
Only candidates present in dictionary search keys can become results.

P0 deinflection covers polite, past/te, negative, progressive, potential,
passive, causative, causative-passive, volitional, imperative, and conditional
verb forms; common i-adjective past/negative/connective/adverbial forms; and
common na-adjective copular/connective forms. `行って`/`行った` is an explicit
irregular rule. Ambiguity such as ichidan versus godan `-る` remains multiple
candidates and is resolved by actual lexicon entries and ranking.

## Ranking

The MVP base scores are:

| Match | Base |
|---|---:|
| Primary form exact | 1000 |
| Alternate form exact | 950 |
| Reading exact | 900 |
| Normalized exact | 850 |
| Deinflected lemma | 800 |
| Primary/form prefix | 650 |
| Reading prefix | 600 |
| Romaji exact | 550 |
| Romaji prefix | 500 |
| Contains | 450 |

Deterministic modifiers are frequency rank (`+120` through rank 1,000, `+80`
through 5,000, `+40` through 10,000), featured editorial entry `+80`, curated
entry `+40`, common form `+40`, and deinflection uncertainty `0` to `-100`.
Ties use frequency rank, headword, then stable entry ID. No model, network,
locale-sensitive collation, or wall-clock state affects the score.

When `debug=True`, each result exposes matched display key, match type, base
score, named modifiers, final score, deinflection reason, and confidence. This
is the required evidence for ranking regressions and learner-facing messages
such as `「食べました」は「食べる」の活用形から検索`.

## API and database behavior

```python
from packages.search_engine import SearchEngine

with SearchEngine("dictionary.sqlite") as engine:
    hits = engine.search("食べました", limit=20, debug=True)
```

The engine opens file-backed SQLite with `mode=ro` and enables `query_only`.
Exact and prefix stages use prebuilt indexes. Contains lookup is last-resort and
may scan; it never runs after a stronger stage has returned candidates. The app
must debounce input and execute search outside its UI thread.

## Acceptance and performance

Unit/golden coverage includes Unicode width, script conversion, long vowels,
romaji examples, verb/adjective forms, same-reading ambiguity, score trace, empty
input, and non-matches. Fixture acceptance includes:

- `食べる` / `たべる` / `taberu` → `食べる`
- `食べました` / `食べられない` → `食べる` with deinflection evidence
- `拾って` / `hirowu` → `拾う`
- `行かなかった` → `行く`
- `ガッコウ` / `gakkou` → `学校`
- `shimbun` → `新聞`
- `高かった` → `高い`; `静かだった` → `静か`
- `あう` ranks common `会う`, then `合う`, then less common `遭う`

The fixed-seed performance harness is:

```powershell
python -m tools.database_builder.benchmark --size 10000
python -m tools.database_builder.benchmark --size 100000
python -m tools.database_builder.benchmark --size 300000
```

It reports build time, DB bytes, query count, hits, P50, P95, and max latency.
The release target is P95 under 100 ms at 100k entries on the supported reference
environment. The 300k case is a manual capacity check, not a reason to weaken
exact-result quality.

Reference run on 2026-07-22 (Windows, CPython 3.14, fixed seed `20260722`):

| Dataset | Queries | P50 | P95 | Max | Note |
|---|---:|---:|---:|---:|---|
| 10k | 500 | 1.235 ms | 2.635 ms | 4.451 ms | indexed current schema |
| 100k | 500 | 31.278 ms | 57.946 ms | 544.554 ms | reused older compatible DB without new display-field indexes |

The 100k P95 passes the 100 ms target. Its maximum is a deliberate no-match
substring fallback scan; this is tracked separately from the P95 acceptance
gate and is a candidate for an optional n-gram/FTS index in P1. A freshly built
100k database with current indexes measured P95 9.137 ms over 200 queries.

P1 fuzzy matching must be added below all exact/normalized/deinflection results,
with golden non-match cases and script-aware edit costs before it is enabled.
