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
normalization contract. `data/fixtures/search_acceptance_v1.json` is the
versioned query-to-result, deinflection, ambiguity, negative, and ranking
contract consumed by both Python and Dart tests.

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

### Fixed acceptance corpus

The committed `kotoba-search-acceptance-v1` corpus contains 250 distinct
queries backed by 235 distinct lexical rows:

| Category | Cases | Distinct expected entries |
|---|---:|---:|
| Common learner words | 100 | 100 |
| Verb inflections | 50 | 50 |
| Adjective inflections | 20 | 20 |
| Katakana/width inputs | 20 | 20 |
| Common Hepburn romaji | 20 | 20 |
| Same-reading ambiguities | 20 | 52 alternatives |
| Negative/non-match probes | 20 | n/a |

This corpus cannot be padded with empty or duplicate queries: the verifier
checks category minima, global query and case-ID uniqueness, distinct-entry
coverage, ambiguity reading/order consistency, references, and an embedded
SHA-256 over the lexicon and cases. The current checksum is
`e7c6113aa7aae1dfbdf97ca81a059443ae07ceb520c1f77418c08b06da8089c0`.
Its generator is committed at `tools/generate_search_acceptance_fixture.py`;
tests require the checked-in JSON to be byte-for-byte equal to a deterministic
regeneration.

Run the complete AC-02/03/04 machine contract with:

```powershell
python -m tools.verify_search_acceptance
```

The command validates the corpus, materializes its 235 rows through canonical
schema v1 and the production SQLite builder, then executes every query twice
through `SearchEngine(debug=True)`. It checks top result/order, match kind,
forbidden results, deinflection lemma/reason/confidence, score-component
arithmetic, and deterministic equality. The 2026-07-23 reference run passed
250/250 deterministic checks, 230/230 positive explain checks, and 20/20
negative checks with zero failures.

Python and deployed Dart evidence are intentionally reported separately:

- Python regenerates a canonical schema-v1 document, builds it with the
  production database builder, and runs all 250 cases through `SearchEngine`.
- Dart first checks normalizer/query-candidate conformance for the 210
  common/inflection/katakana/romaji cases. A second test builds a temporary
  SQLite database directly from the same 235 lexicon rows and runs all 250
  cases through the production `DriftDictionaryRepository`, not the in-memory
  fixture repository. It checks expected IDs and match kind, all 20 ambiguity
  orders, all 20 no-match negatives, and byte-stable result snapshots across
  two executions.
- Every deployed `SearchHit` exposes a matched display key, match kind,
  raw/base score, named modifiers, weighted/final score, original derived
  query, and deinflection reason. Tests require raw plus modifiers to equal the
  final score.

The first ambiguity group assigns equal frequency ranks to a featured, curated,
and imported entry. Both runtimes must therefore produce the canonical
`featured +80`, `curated +40`, `imported +0` editorial modifiers and preserve
that result order; a legacy boolean cannot collapse these levels.

The corpus is a CC0 QA behavior contract, not release dictionary content or an
authoritative frequency list. Its generated canonical rows remain `ai_draft`;
passing search acceptance does not bypass the separate human content-review
gate.

### Performance harness

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

Reference run on 2026-07-23 (Windows, CPython 3.14, fixed seed `20260722`,
500 queries per size, freshly built current schema):

| Dataset | Build | P50 | P95 | Max |
|---|---:|---:|---:|---:|
| 10k | 0.702 s | 0.592 ms | 2.722 ms | 7.181 ms |
| 100k | 5.500 s | 1.272 ms | 6.671 ms | 94.385 ms |
| 300k | 23.272 s | 1.623 ms | 7.977 ms | 299.176 ms |

The 100k P95 passes the 100 ms target. The larger maximums are deliberate
no-match substring fallback scans; this is tracked separately from the P95
acceptance gate and is a candidate for an optional n-gram/FTS index in P1.

P1 fuzzy matching must be added below all exact/normalized/deinflection results,
with golden non-match cases and script-aware edit costs before it is enabled.
