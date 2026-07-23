import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/services.dart';

import '../domain/dictionary_entry.dart';
import '../domain/japanese_query_normalizer.dart';
import '../domain/search_hit.dart';
import 'bundled_database_path.dart';
import 'dictionary_repository.dart';

/// Drift-backed adapter for the immutable bundled dictionary package.
///
/// The fixture database stores the canonical entry JSON in a typed SQLite row.
/// The production data pipeline can replace the in-memory ranker with indexed
/// `search_keys` queries while keeping this repository contract unchanged.
class DriftDictionaryRepository
    implements
        DictionaryRepository,
        DictionaryRepositoryLifecycle,
        DictionaryRepositoryReadiness {
  DriftDictionaryRepository(this._executor);

  factory DriftDictionaryRepository.bundled(AssetBundle bundle) {
    return DriftDictionaryRepository.withDatabasePath(
      () => prepareBundledDictionaryDatabase(
        bundle,
        'assets/database/dictionary.sqlite',
        recoverInterruptedUpdate: true,
      ),
    );
  }

  factory DriftDictionaryRepository.withDatabasePath(
    Future<String> Function() databasePath,
  ) {
    final executor = driftDatabase(
      name: 'kotoba_dictionary',
      native: DriftNativeOptions(
        shareAcrossIsolates: true,
        databasePath: databasePath,
      ),
    );
    return DriftDictionaryRepository(executor);
  }

  final QueryExecutor _executor;
  final QueryExecutorUser _user = _DictionaryExecutorUser();
  bool _opened = false;
  bool _closed = false;
  static const _normalizer = JapaneseQueryNormalizer();

  Future<void> _ensureOpen() async {
    if (_closed) {
      throw StateError('Dictionary repository is closed.');
    }
    if (_opened) return;
    await _executor.ensureOpen(_user);
    _opened = true;
  }

  @override
  Future<void> verifyReady() async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      'SELECT entry_id FROM entries ORDER BY entry_id LIMIT 1',
      const [],
    );
    if (rows.isEmpty) {
      throw StateError('Dictionary readiness query returned no entries.');
    }
  }

  @override
  Future<List<DictionaryEntry>> allEntries() async {
    await _ensureOpen();
    final rows = await _executor.runSelect(
      'SELECT payload_json FROM entries ORDER BY frequency_rank, entry_id',
      const [],
    );
    final entries = rows
        .map(
          (row) => DictionaryEntry.fromJson(
            jsonDecode(row['payload_json']! as String) as Map<String, Object?>,
          ),
        )
        .toList(growable: false);
    final byId = {for (final entry in entries) entry.id: entry};
    return entries
        .map(
          (entry) => entry.copyWith(
            relations: entry.relations
                .map(
                  (relation) => relation.copyWith(
                    headword: relation.targetEntryId == null
                        ? relation.headword
                        : byId[relation.targetEntryId]?.headword ??
                              relation.headword,
                  ),
                )
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<DictionaryEntry?> findById(String entryId) async {
    final entries = await findByIds([entryId]);
    return entries.isEmpty ? null : entries.single;
  }

  @override
  Future<List<DictionaryEntry>> findByIds(Iterable<String> entryIds) async {
    await _ensureOpen();
    final ids = entryIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await _executor.runSelect(
      'SELECT payload_json FROM entries WHERE entry_id IN ($placeholders)',
      ids,
    );
    final entries = rows
        .map(
          (row) => DictionaryEntry.fromJson(
            jsonDecode(row['payload_json']! as String) as Map<String, Object?>,
          ),
        )
        .toList(growable: false);
    final targetIds = entries
        .expand((entry) => entry.relations)
        .map((relation) => relation.targetEntryId)
        .whereType<String>()
        .toSet()
        .toList(growable: false);
    final targetHeadwords = <String, String>{};
    if (targetIds.isNotEmpty) {
      final targetPlaceholders = List.filled(targetIds.length, '?').join(', ');
      final targetRows = await _executor.runSelect(
        'SELECT entry_id, headword FROM entries '
        'WHERE entry_id IN ($targetPlaceholders)',
        targetIds,
      );
      for (final row in targetRows) {
        targetHeadwords[row['entry_id']! as String] =
            row['headword']! as String;
      }
    }
    final byId = {for (final entry in entries) entry.id: entry};
    return ids
        .map((id) => byId[id])
        .whereType<DictionaryEntry>()
        .map(
          (entry) => entry.copyWith(
            relations: entry.relations
                .map(
                  (relation) => relation.copyWith(
                    headword: relation.targetEntryId == null
                        ? relation.headword
                        : targetHeadwords[relation.targetEntryId] ??
                              relation.headword,
                  ),
                )
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<SearchHit>> search(String rawQuery, {int limit = 50}) async {
    await _ensureOpen();
    final query = rawQuery.trim();
    if (query.isEmpty) return const [];
    final candidates = _normalizer.queryCandidates(query);
    if (candidates.isEmpty) return const [];

    final values = List.filled(
      candidates.length,
      '(?, ?, ?, ?, ?, ?)',
    ).join(', ');
    final arguments = <Object?>[];
    for (final candidate in candidates) {
      arguments.addAll([
        candidate.key,
        '${candidate.key}\u{10ffff}',
        candidate.kind.name,
        candidate.derivedFrom,
        candidate.deinflectionReason,
        candidate.deinflectionConfidence,
      ]);
    }
    arguments.add((limit * 4).clamp(20, 200));
    var rows = await _executor.runSelect('''
WITH requested(
  search_key,
  upper_bound,
  source_kind,
  derived_from,
  deinflection_reason,
  deinflection_confidence
) AS (
  VALUES $values
)
SELECT e.payload_json,
       e.frequency_rank,
       sk.search_key,
       sk.display_key,
       sk.key_type,
       sk.is_common,
       q.source_kind,
       q.derived_from,
       q.deinflection_reason,
       q.deinflection_confidence,
       CASE WHEN sk.search_key = q.search_key THEN 1 ELSE 0 END AS exact_match,
       0 AS contains_match
FROM requested AS q
JOIN search_keys AS sk INDEXED BY idx_search_keys_key
  ON sk.search_key >= q.search_key AND sk.search_key < q.upper_bound
 AND (
   sk.search_key = q.search_key
   OR q.source_kind IN ('normalized', 'kana', 'romaji')
 )
JOIN entries AS e ON e.entry_id = sk.entry_id
ORDER BY exact_match DESC, e.frequency_rank ASC, e.entry_id ASC
LIMIT ?
''', arguments);

    if (rows.isEmpty) {
      final containsCandidates = <String, QueryCandidate>{};
      for (final candidate in candidates) {
        if (candidate.kind == QueryCandidateKind.inflection ||
            candidate.key.runes.length < 2) {
          continue;
        }
        containsCandidates.putIfAbsent(
          '${candidate.kind.name}\u0000${candidate.key}',
          () => candidate,
        );
      }
      if (containsCandidates.isNotEmpty) {
        final containsValues = List.filled(
          containsCandidates.length,
          '(?, ?, ?, ?, ?, ?)',
        ).join(', ');
        final containsArguments = <Object?>[];
        for (final candidate in containsCandidates.values) {
          containsArguments.addAll([
            candidate.key,
            '%${_escapeLike(candidate.key)}%',
            candidate.kind.name,
            candidate.derivedFrom,
            candidate.deinflectionReason,
            candidate.deinflectionConfidence,
          ]);
        }
        containsArguments.add((limit * 4).clamp(20, 200));
        rows = await _executor.runSelect('''
WITH requested(
  search_key,
  pattern,
  source_kind,
  derived_from,
  deinflection_reason,
  deinflection_confidence
) AS (
  VALUES $containsValues
)
SELECT e.payload_json,
       e.frequency_rank,
       sk.search_key,
       sk.display_key,
       sk.key_type,
       sk.is_common,
       q.source_kind,
       q.derived_from,
       q.deinflection_reason,
       q.deinflection_confidence,
       0 AS exact_match,
       1 AS contains_match
FROM requested AS q
JOIN search_keys AS sk
  ON sk.search_key LIKE q.pattern ESCAPE '\\'
 AND sk.search_key != q.search_key
JOIN entries AS e ON e.entry_id = sk.entry_id
ORDER BY e.frequency_rank ASC,
         e.entry_id ASC,
         sk.key_type ASC,
         sk.display_key ASC
LIMIT ?
''', containsArguments);
      }
    }

    final bestByEntry = <String, SearchHit>{};
    for (final row in rows) {
      final entry = DictionaryEntry.fromJson(
        jsonDecode(row['payload_json']! as String) as Map<String, Object?>,
      );
      final sourceKind = QueryCandidateKind.values.byName(
        row['source_kind']! as String,
      );
      final exact = row['exact_match'] == 1;
      final keyType = row['key_type']! as String;
      final (kind, baseScore) = _classifyMatch(
        rawQuery: query,
        entry: entry,
        sourceKind: sourceKind,
        keyType: keyType,
        matchedKey: row['display_key']! as String,
        exact: exact,
        contains: row['contains_match'] == 1,
      );
      final modifiers = <SearchScoreModifier>[];
      final frequencyBoost = entry.frequencyRank <= 1000
          ? 120
          : entry.frequencyRank <= 5000
          ? 80
          : entry.frequencyRank <= 10000
          ? 40
          : 0;
      if (frequencyBoost > 0) {
        modifiers.add(SearchScoreModifier('frequency', frequencyBoost));
      }
      final editorialBoost = entry.editorialLevel.rankingBoost;
      if (editorialBoost > 0) {
        modifiers.add(
          SearchScoreModifier(
            'editorial_${entry.editorialLevel.name}',
            editorialBoost,
          ),
        );
      }
      if (row['is_common'] == 1) {
        modifiers.add(const SearchScoreModifier('common_form', 40));
      }
      final deinflectionConfidence = (row['deinflection_confidence'] as num?)
          ?.toDouble();
      if (sourceKind == QueryCandidateKind.inflection &&
          deinflectionConfidence != null) {
        final penalty = -((1 - deinflectionConfidence) * 100).round();
        if (penalty != 0) {
          modifiers.add(
            SearchScoreModifier('deinflection_uncertainty', penalty),
          );
        }
      }
      final score =
          baseScore +
          modifiers.fold<int>(0, (total, modifier) => total + modifier.value);
      final hit = SearchHit(
        entry: entry,
        kind: kind,
        baseScore: baseScore,
        score: score,
        matchedKey: row['display_key']! as String,
        modifiers: List.unmodifiable(modifiers),
        derivedFrom: row['derived_from'] as String?,
        deinflectionReason: row['deinflection_reason'] as String?,
        deinflectionConfidence: deinflectionConfidence,
      );
      final existing = bestByEntry[entry.id];
      if (existing == null || _isBetterEvidence(hit, existing)) {
        bestByEntry[entry.id] = hit;
      }
    }
    final hits = bestByEntry.values.toList()
      ..sort((left, right) {
        final score = right.score.compareTo(left.score);
        return score != 0 ? score : _tieBreak(left, right);
      });
    return hits.take(limit).toList(growable: false);
  }

  bool _isBetterEvidence(SearchHit candidate, SearchHit existing) {
    final score = candidate.score.compareTo(existing.score);
    if (score != 0) return score > 0;
    final raw = candidate.baseScore.compareTo(existing.baseScore);
    if (raw != 0) return raw > 0;
    final kind = candidate.kind.index.compareTo(existing.kind.index);
    if (kind != 0) return kind < 0;
    return candidate.matchedKey.compareTo(existing.matchedKey) < 0;
  }

  int _tieBreak(SearchHit left, SearchHit right) {
    final frequency = left.entry.frequencyRank.compareTo(
      right.entry.frequencyRank,
    );
    if (frequency != 0) return frequency;
    final headword = left.entry.headword.compareTo(right.entry.headword);
    if (headword != 0) return headword;
    return left.entry.id.compareTo(right.entry.id);
  }

  (MatchKind, int) _classifyMatch({
    required String rawQuery,
    required DictionaryEntry entry,
    required QueryCandidateKind sourceKind,
    required String keyType,
    required String matchedKey,
    required bool exact,
    required bool contains,
  }) {
    if (contains) {
      return (MatchKind.contains, 450);
    }
    if (sourceKind == QueryCandidateKind.inflection) {
      return (MatchKind.inflection, 800);
    }
    if (sourceKind == QueryCandidateKind.romaji) {
      return exact ? (MatchKind.romaji, 550) : (MatchKind.romajiPrefix, 500);
    }
    if (!exact) {
      return keyType == 'primary'
          ? (MatchKind.headwordPrefix, 650)
          : (MatchKind.readingPrefix, 600);
    }
    if (keyType == 'primary') {
      return rawQuery == entry.headword
          ? (MatchKind.primaryExact, 1000)
          : (MatchKind.normalizedExact, 850);
    }
    if (keyType == 'alternate') {
      return (MatchKind.alternativeExact, 950);
    }
    return _normalizer.normalizeText(rawQuery) ==
            _normalizer.normalizeText(matchedKey)
        ? (MatchKind.readingExact, 900)
        : (MatchKind.normalizedExact, 850);
  }

  String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _executor.close();
    _opened = false;
  }
}

class _DictionaryExecutorUser extends QueryExecutorUser {
  @override
  int get schemaVersion => 1;

  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

class FallbackDictionaryRepository
    implements
        DictionaryRepository,
        DictionaryRepositoryLifecycle,
        DictionaryRepositoryReadiness {
  const FallbackDictionaryRepository({
    required this.primary,
    required this.fallback,
  });

  final DictionaryRepository primary;
  final DictionaryRepository fallback;

  Future<T> _attempt<T>(
    Future<T> Function(DictionaryRepository repository) operation,
  ) async {
    try {
      return await operation(primary);
    } on Exception {
      return operation(fallback);
    }
  }

  @override
  Future<List<DictionaryEntry>> allEntries() =>
      _attempt((repository) => repository.allEntries());

  @override
  Future<DictionaryEntry?> findById(String entryId) =>
      _attempt((repository) => repository.findById(entryId));

  @override
  Future<List<DictionaryEntry>> findByIds(Iterable<String> entryIds) =>
      _attempt((repository) => repository.findByIds(entryIds));

  @override
  Future<List<SearchHit>> search(String rawQuery, {int limit = 50}) =>
      _attempt((repository) => repository.search(rawQuery, limit: limit));

  @override
  Future<void> close() async {
    final repository = primary;
    if (repository is DictionaryRepositoryLifecycle) {
      await (repository as DictionaryRepositoryLifecycle).close();
    }
  }

  @override
  Future<void> verifyReady() async {
    final repository = primary;
    if (repository is DictionaryRepositoryReadiness) {
      await (repository as DictionaryRepositoryReadiness).verifyReady();
      return;
    }
    final entries = await repository.allEntries();
    if (entries.isEmpty) {
      throw StateError(
        'Primary dictionary readiness query returned no entries.',
      );
    }
  }
}
