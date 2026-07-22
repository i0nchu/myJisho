import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotoba_dictionary_app/features/dictionary/data/drift_dictionary_repository.dart';
import 'package:kotoba_dictionary_app/features/dictionary/data/fixture_dictionary_repository.dart';
import 'package:kotoba_dictionary_app/features/dictionary/domain/japanese_query_normalizer.dart';
import 'package:kotoba_dictionary_app/features/update/data/sqlite_dictionary_inspector.dart';
import 'package:kotoba_dictionary_app/features/update/data/dictionary_update_service.dart';
import 'package:kotoba_dictionary_app/features/update/data/file_update_storage.dart';
import 'package:kotoba_dictionary_app/features/update/domain/release_manifest.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'canonical fixture bundle loads and resolves relation headwords',
    () async {
      final repository = FixtureDictionaryRepository(rootBundle);
      final entries = await repository.allEntries();

      expect(entries.length, 24);
      expect(entries.every((entry) => entry.isReviewPending), isTrue);
      final rain = entries.singleWhere((entry) => entry.headword == '雨');
      expect(rain.relations.single.headword, '飴');
      for (final (query, expected) in [
        ('学校', '学校'),
        ('がっこう', '学校'),
        ('ガッコウ', '学校'),
        ('gakkou', '学校'),
        ('食べました', '食べる'),
        ('拾って', '拾う'),
        ('行かなかった', '行く'),
      ]) {
        expect(
          (await repository.search(query)).first.entry.headword,
          expected,
          reason: 'fixture fallback search for $query',
        );
      }
    },
  );

  test(
    'bundled SQLite passes integrity and Drift repository parsing',
    () async {
      final source = File('assets/database/dictionary.sqlite');
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'kotoba-drift-test-',
      );
      addTearDown(() => temporaryDirectory.delete(recursive: true));
      final copy = await source.copy(
        '${temporaryDirectory.path}${Platform.pathSeparator}dictionary.sqlite',
      );
      final executor = NativeDatabase(copy);
      final repository = DriftDictionaryRepository(executor);
      addTearDown(repository.close);

      final entries = await repository.allEntries();
      expect(entries.length, 24);
      expect(entries.first.id, isNotEmpty);
      expect(await readDictionaryVersion(copy.path), '0.1.0-fixture.1');
      for (final (query, expected) in [
        ('学校', '学校'),
        ('がっこう', '学校'),
        ('ガッコウ', '学校'),
        ('gakkou', '学校'),
        ('食べました', '食べる'),
        ('拾って', '拾う'),
        ('行かなかった', '行く'),
      ]) {
        expect(
          (await repository.search(query)).first.entry.headword,
          expected,
          reason: 'native indexed search for $query',
        );
      }
      final rain = await repository.findById('entry_ame_rain_001');
      expect(rain?.headword, '雨');
      expect(rain?.relations.single.headword, '飴');
    },
  );

  test('Dart normalizer follows the canonical golden contract', () {
    const normalizer = JapaneseQueryNormalizer();
    final cases = [
      (' ガッコウ ', 'ガッコウ', 'がっこう', <String>[]),
      ('ｶﾞｯｺｳ', 'ガッコウ', 'がっこう', <String>[]),
      ('コーヒー', 'コーヒー', 'こおひい', <String>[]),
      ('taberu', 'taberu', 'taberu', ['たべる']),
      ('hirou', 'hirou', 'hirou', ['ひろう']),
      ('hirowu', 'hirowu', 'hirowu', ['ひろう']),
      ('gakkou', 'gakkou', 'gakkou', ['がっこう']),
      ('shimbun', 'shimbun', 'shimbun', ['しんぶん']),
      ('shinbun', 'shinbun', 'shinbun', ['しんぶん']),
      ('Ｔａｂｅｒｕ。', 'taberu', 'taberu', <String>[]),
    ];
    for (final (input, normalized, kana, romaji) in cases) {
      expect(normalizer.normalizeText(input), normalized, reason: input);
      expect(normalizer.normalizeKana(input), kana, reason: input);
      expect(normalizer.romajiToHiragana(input), romaji, reason: input);
    }
  });

  test('sideload handoff reopens and searches the activated database', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'kotoba-update-query-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    final active = await File(
      'assets/database/dictionary.sqlite',
    ).copy('${temporaryDirectory.path}${Platform.pathSeparator}active.sqlite');
    final next = await active.copy(
      '${temporaryDirectory.path}${Platform.pathSeparator}next.sqlite',
    );
    final database = sqlite.sqlite3.open(next.path);
    final row = database
        .select(
          "SELECT payload_json FROM entries WHERE entry_id = 'entry_gakkou_001'",
        )
        .single;
    final payload =
        jsonDecode(row['payload_json']! as String) as Map<String, Object?>;
    payload['headword'] = '新語';
    final forms = payload['forms']! as List<Object?>;
    (forms.first! as Map<String, Object?>)['text'] = '新語';
    database.execute(
      "UPDATE entries SET headword = ?, payload_json = ? "
      "WHERE entry_id = 'entry_gakkou_001'",
      ['新語', jsonEncode(payload)],
    );
    database.execute(
      "DELETE FROM search_keys WHERE entry_id = 'entry_gakkou_001'",
    );
    database.execute('INSERT INTO search_keys VALUES (?, ?, ?, ?, ?, ?, ?)', [
      'entry_gakkou_001:key:test',
      'entry_gakkou_001',
      '新語',
      '新語',
      '新語',
      'primary',
      1,
    ]);
    database.execute(
      "UPDATE metadata SET metadata_value = '0.2.0' "
      "WHERE metadata_key = 'dictionary_version'",
    );
    database.close();
    final nextBytes = await next.readAsBytes();

    var repository = DriftDictionaryRepository(NativeDatabase(active));
    expect((await repository.search('学校')).first.entry.headword, '学校');
    String? reopenedResult;
    final service = DictionaryUpdateService(
      source: _BytesPackageSource(nextBytes),
      storage: createFileUpdateStorage(
        activeDatabasePath: active.path,
        healthCheck: isHealthySqliteDictionary,
      ),
      supportedSchemaVersion: 1,
      currentDictionaryVersion: '0.1.0-fixture.1',
      currentAppVersion: '0.1.0',
      beforeActivate: repository.close,
      afterActivate: () async {
        repository = DriftDictionaryRepository(NativeDatabase(active));
        reopenedResult = (await repository.search('新語')).first.entry.headword;
      },
    );
    addTearDown(() => repository.close());

    expect(await service.checkAndInstall(), DictionaryUpdateResult.updated);
    expect(reopenedResult, '新語');
    expect(await readDictionaryVersion(active.path), '0.2.0');
  });
}

class _BytesPackageSource implements DictionaryPackageSource {
  _BytesPackageSource(this.bytes);

  final Uint8List bytes;

  @override
  Future<Map<String, Object?>> fetchManifest() async => {
    'channel': 'release',
    'content_status': 'reviewed',
    'database_file': 'dictionary.sqlite',
    'schema_version': 1,
    'dictionary_version': '0.2.0',
    'minimum_app_version': '0.1.0',
    'database_size': bytes.length,
    'database_sha256': sha256.convert(bytes).toString(),
    'released_at': '2026-08-01T00:00:00Z',
  };

  @override
  Future<Uint8List> fetchDatabase(ReleaseManifest manifest) async => bytes;
}
