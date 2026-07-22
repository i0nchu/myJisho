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
    implements DictionaryRepository, DictionaryRepositoryLifecycle {
  DriftDictionaryRepository(this._executor);

  factory DriftDictionaryRepository.bundled(AssetBundle bundle) {
    final executor = driftDatabase(
      name: 'kotoba_dictionary',
      native: DriftNativeOptions(
        shareAcrossIsolates: true,
        databasePath: () => prepareBundledDictionaryDatabase(
          bundle,
          'assets/database/dictionary.sqlite',
        ),
      ),
    );
    return DriftDictionaryRepository(executor);
  }

  final QueryExecutor _executor;
  final QueryExecutorUser _user = _DictionaryExecutorUser();
  bool _opened = false;
  static const _normalizer = JapaneseQueryNormalizer();

  Future<void> _ensureOpen() async {
    if (_opened) return;
    await _executor.ensureOpen(_user);
    _opened = true;
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

    final values = List.filled(candidates.length, '(?, ?, ?, ?)').join(', ');
    final arguments = <Object?>[];
    for (final candidate in candidates) {
      arguments.addAll([
        candidate.key,
        '${candidate.key}\u{10ffff}',
        candidate.kind.name,
        candidate.derivedFrom,
      ]);
    }
    arguments.add((limit * 4).clamp(20, 200));
    final rows = await _executor.runSelect('''
WITH requested(search_key, upper_bound, source_kind, derived_from) AS (
  VALUES $values
)
SELECT e.payload_json,
       e.frequency_rank,
       sk.search_key,
       sk.key_type,
       sk.is_common,
       q.source_kind,
       q.derived_from,
       CASE WHEN sk.search_key = q.search_key THEN 1 ELSE 0 END AS exact_match
FROM requested AS q
JOIN search_keys AS sk INDEXED BY idx_search_keys_key
  ON sk.search_key >= q.search_key AND sk.search_key < q.upper_bound
JOIN entries AS e ON e.entry_id = sk.entry_id
ORDER BY exact_match DESC, e.frequency_rank ASC, e.entry_id ASC
LIMIT ?
''', arguments);

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
        exact: exact,
      );
      final frequencyBoost = entry.frequencyRank <= 1000
          ? 120
          : entry.frequencyRank <= 5000
          ? 80
          : 30;
      final score =
          baseScore +
          frequencyBoost +
          (entry.curated ? 80 : 0) +
          (row['is_common'] == 1 ? 40 : 0);
      final hit = SearchHit(
        entry: entry,
        kind: kind,
        baseScore: baseScore,
        score: score,
        derivedFrom: row['derived_from'] as String?,
      );
      final existing = bestByEntry[entry.id];
      if (existing == null || hit.score > existing.score) {
        bestByEntry[entry.id] = hit;
      }
    }
    final hits = bestByEntry.values.toList()
      ..sort((left, right) {
        final score = right.score.compareTo(left.score);
        return score != 0
            ? score
            : left.entry.frequencyRank.compareTo(right.entry.frequencyRank);
      });
    return hits.take(limit).toList(growable: false);
  }

  (MatchKind, int) _classifyMatch({
    required String rawQuery,
    required DictionaryEntry entry,
    required QueryCandidateKind sourceKind,
    required String keyType,
    required bool exact,
  }) {
    if (sourceKind == QueryCandidateKind.inflection) {
      return (MatchKind.inflection, 800);
    }
    if (sourceKind == QueryCandidateKind.romaji) {
      return (MatchKind.romaji, 550);
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
    return rawQuery == entry.reading
        ? (MatchKind.readingExact, 900)
        : (MatchKind.normalizedExact, 850);
  }

  @override
  Future<void> close() => _executor.close();
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
    implements DictionaryRepository, DictionaryRepositoryLifecycle {
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
}
