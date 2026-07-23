import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotoba_dictionary_app/features/dictionary/data/drift_dictionary_repository.dart';
import 'package:kotoba_dictionary_app/features/dictionary/domain/dictionary_entry.dart';
import 'package:kotoba_dictionary_app/features/dictionary/domain/japanese_query_normalizer.dart';
import 'package:kotoba_dictionary_app/features/dictionary/domain/search_hit.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temporaryDirectory;
  late DriftDictionaryRepository repository;
  late Map<String, Object?> corpus;
  late Map<String, Object?> categories;

  setUpAll(() async {
    corpus =
        jsonDecode(
              File(
                '../../data/fixtures/search_acceptance_v1.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    categories = corpus['categories']! as Map<String, Object?>;
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'kotoba-search-acceptance-drift-',
    );
    final databaseFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}acceptance.sqlite',
    );
    _buildAcceptanceDatabase(databaseFile, corpus);
    repository = DriftDictionaryRepository(NativeDatabase(databaseFile));
  });

  tearDownAll(() async {
    await repository.close();
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'production Drift search satisfies all 250 fixed corpus cases',
    () async {
      final caseIds = <String>{};
      final queries = <String>{};
      var caseCount = 0;
      var ambiguityCount = 0;
      var negativeCount = 0;

      for (final category in [
        'common_words',
        'verb_inflections',
        'adjective_inflections',
        'katakana',
        'romaji',
        'ambiguity',
        'negative',
      ]) {
        for (final value in categories[category]! as List<Object?>) {
          final searchCase = value! as Map<String, Object?>;
          final caseId = searchCase['case_id']! as String;
          final query = searchCase['raw_query']! as String;
          final expectedIds =
              (searchCase['expected_entry_ids']! as List<Object?>)
                  .cast<String>();
          caseCount++;
          expect(caseIds.add(caseId), isTrue, reason: 'duplicate $caseId');
          expect(
            queries.add(query),
            isTrue,
            reason: 'query must be globally unique: $caseId / $query',
          );

          final first = await repository.search(query);
          final second = await repository.search(query);
          expect(
            _snapshot(second),
            _snapshot(first),
            reason: '$caseId must be deterministic',
          );

          if (category == 'negative') {
            negativeCount++;
            expect(first, isEmpty, reason: '$caseId / $query');
            continue;
          }

          final actualIds = first.map((hit) => hit.entry.id).toList();
          expect(
            actualIds.take(expectedIds.length),
            expectedIds,
            reason: '$caseId / $query',
          );
          if (category == 'ambiguity') {
            ambiguityCount++;
            expect(expectedIds.length, greaterThanOrEqualTo(2));
          }
          final expectedKind = searchCase['expected_match_kind'] as String?;
          if (expectedKind != null) {
            expect(
              first.first.kind,
              _matchKind(expectedKind),
              reason: '$caseId / $query',
            );
          }
          for (final hit in first.take(expectedIds.length)) {
            final evidence = hit.evidence;
            expect(evidence.matchedKey, isNotEmpty, reason: caseId);
            expect(evidence.matchKind, hit.kind, reason: caseId);
            expect(evidence.rawScore, hit.baseScore, reason: caseId);
            expect(evidence.finalScore, hit.score, reason: caseId);
            expect(evidence.isScoreConsistent, isTrue, reason: caseId);
          }
          if (expectedKind == 'deinflection') {
            final evidence = first.first.evidence;
            expect(evidence.derivedFrom, query, reason: caseId);
            expect(evidence.deinflectionReason, isNotEmpty, reason: caseId);
          }
        }
      }

      expect(caseCount, 250);
      expect(queries.length, 250);
      expect(ambiguityCount, 20);
      expect(negativeCount, 20);
    },
  );

  test(
    'featured curated and imported modifiers drive canonical ambiguity order',
    () async {
      final firstCase =
          (categories['ambiguity']! as List<Object?>).first!
              as Map<String, Object?>;
      final expectedIds = (firstCase['expected_entry_ids']! as List<Object?>)
          .cast<String>();
      final hits = await repository.search(firstCase['raw_query']! as String);
      final alternatives = hits.take(3).toList(growable: false);

      expect(alternatives.map((hit) => hit.entry.id), expectedIds);
      expect(
        alternatives.map((hit) => hit.entry.frequencyRank).toSet().length,
        1,
        reason: 'editorial level, not frequency, must decide this order',
      );
      expect(alternatives.map((hit) => hit.entry.editorialLevel), [
        EditorialLevel.featured,
        EditorialLevel.curated,
        EditorialLevel.imported,
      ]);
      expect(_modifier(alternatives[0], 'editorial_featured'), 80);
      expect(_modifier(alternatives[1], 'editorial_curated'), 40);
      expect(_modifier(alternatives[2], 'editorial_imported'), 0);
      for (final hit in alternatives) {
        expect(hit.evidence.rawScore, 900);
        expect(_modifier(hit, 'common_form'), 40);
        expect(hit.evidence.isScoreConsistent, isTrue);
      }
    },
  );
}

MatchKind _matchKind(String wireValue) => switch (wireValue) {
  'primary_exact' => MatchKind.primaryExact,
  'alternate_exact' => MatchKind.alternativeExact,
  'reading_exact' => MatchKind.readingExact,
  'normalized_exact' => MatchKind.normalizedExact,
  'deinflection' => MatchKind.inflection,
  'primary_prefix' => MatchKind.headwordPrefix,
  'reading_prefix' => MatchKind.readingPrefix,
  'romaji' => MatchKind.romaji,
  'romaji_prefix' => MatchKind.romajiPrefix,
  'contains' => MatchKind.contains,
  _ => throw StateError('Unknown match kind: $wireValue'),
};

int _modifier(SearchHit hit, String name) {
  for (final modifier in hit.modifiers) {
    if (modifier.name == name) return modifier.value;
  }
  return 0;
}

List<String> _snapshot(List<SearchHit> hits) => hits
    .map(
      (hit) => [
        hit.entry.id,
        hit.kind.name,
        hit.matchedKey,
        hit.baseScore,
        hit.score,
        hit.derivedFrom,
        hit.deinflectionReason,
        for (final modifier in hit.modifiers)
          '${modifier.name}:${modifier.value}',
      ].join('|'),
    )
    .toList(growable: false);

void _buildAcceptanceDatabase(File file, Map<String, Object?> corpus) {
  const normalizer = JapaneseQueryNormalizer();
  final database = sqlite.sqlite3.open(file.path);
  try {
    database.execute('''
CREATE TABLE entries (
  entry_id TEXT PRIMARY KEY,
  headword TEXT NOT NULL,
  frequency_rank INTEGER NOT NULL,
  payload_json TEXT NOT NULL
);
CREATE TABLE search_keys (
  search_key_id TEXT PRIMARY KEY,
  entry_id TEXT NOT NULL,
  search_key TEXT NOT NULL,
  search_key_prefix TEXT NOT NULL,
  display_key TEXT NOT NULL,
  key_type TEXT NOT NULL,
  is_common INTEGER NOT NULL
);
CREATE INDEX idx_search_keys_key ON search_keys(search_key, key_type);
''');
    for (final value in corpus['lexicon']! as List<Object?>) {
      final row = value! as Map<String, Object?>;
      final entryId = row['entry_id']! as String;
      final headword = row['headword']! as String;
      final reading = row['reading']! as String;
      final payload = <String, Object?>{
        'entry_id': entryId,
        'headword': headword,
        'forms': [
          {'text': headword, 'type': 'primary', 'common': true},
          if (reading != headword)
            {'text': reading, 'type': 'kana', 'common': true},
        ],
        'readings': [
          {'kana': reading, 'primary': true},
        ],
        'parts_of_speech': [row['part_of_speech']],
        'frequency_rank': row['frequency_rank'],
        'editorial_level': row['editorial_level'],
        'edit_status': 'ai_draft',
        'senses': [
          {
            'sense_id': '$entryId:sense:001',
            'definition_ja_simple': '検索受入試験の固定項目。',
            'usage_note_ja': 'QA fixture。',
            'examples': <Object?>[],
            'relations': <Object?>[],
            'image_assets': <Object?>[],
            'audio_assets': <Object?>[],
          },
        ],
        'source_ids': ['kotoba_search_acceptance_cc0'],
        'review': {'status': 'ai_draft'},
      };
      database.execute('INSERT INTO entries VALUES (?, ?, ?, ?)', [
        entryId,
        headword,
        row['frequency_rank'],
        jsonEncode(payload),
      ]);
      _insertSearchKey(
        database,
        id: '$entryId:primary',
        entryId: entryId,
        key: normalizer.normalizeText(headword),
        displayKey: headword,
        keyType: 'primary',
      );
      _insertSearchKey(
        database,
        id: '$entryId:reading',
        entryId: entryId,
        key: normalizer.normalizeKana(reading),
        displayKey: reading,
        keyType: 'reading',
      );
    }
  } finally {
    database.close();
  }
}

void _insertSearchKey(
  sqlite.Database database, {
  required String id,
  required String entryId,
  required String key,
  required String displayKey,
  required String keyType,
}) {
  database.execute('INSERT INTO search_keys VALUES (?, ?, ?, ?, ?, ?, 1)', [
    id,
    entryId,
    key,
    key,
    displayKey,
    keyType,
  ]);
}
