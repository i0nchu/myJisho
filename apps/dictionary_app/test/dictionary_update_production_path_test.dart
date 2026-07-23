import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotoba_dictionary_app/features/dictionary/application/dictionary_providers.dart';
import 'package:kotoba_dictionary_app/features/dictionary/data/dictionary_repository.dart';
import 'package:kotoba_dictionary_app/features/dictionary/data/drift_dictionary_repository.dart';
import 'package:kotoba_dictionary_app/features/dictionary/domain/dictionary_entry.dart';
import 'package:kotoba_dictionary_app/features/dictionary/domain/search_hit.dart';
import 'package:kotoba_dictionary_app/features/update/application/dictionary_update_controller.dart';
import 'package:kotoba_dictionary_app/features/update/data/dictionary_update_recovery.dart';
import 'package:kotoba_dictionary_app/features/update/data/file_update_storage.dart';
import 'package:kotoba_dictionary_app/features/update/data/sqlite_dictionary_inspector.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late Directory temporaryDirectory;
  late File activeDatabase;
  late Uint8List oldDatabaseBytes;
  late Uint8List nextDatabaseBytes;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'kotoba-production-update-test-',
    );
    activeDatabase = await File(
      'assets/database/dictionary.sqlite',
    ).copy('${temporaryDirectory.path}${Platform.pathSeparator}active.sqlite');
    oldDatabaseBytes = await activeDatabase.readAsBytes();
    final next = await activeDatabase.copy(
      '${temporaryDirectory.path}${Platform.pathSeparator}next.sqlite',
    );
    final database = sqlite.sqlite3.open(next.path);
    database.execute(
      "UPDATE metadata SET metadata_value = '0.2.0' "
      "WHERE metadata_key = 'dictionary_version'",
    );
    database.close();
    nextDatabaseBytes = await next.readAsBytes();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'startup recovery restores backup before the first Drift open',
    () async {
      final backup = File('${activeDatabase.path}.backup');
      await backup.writeAsBytes(oldDatabaseBytes, flush: true);
      await activeDatabase.writeAsBytes(nextDatabaseBytes, flush: true);
      await File(
        '${activeDatabase.path}.staged',
      ).writeAsBytes(<int>[1, 2, 3], flush: true);
      await File(
        '${activeDatabase.path}.update-in-progress',
      ).writeAsString('replace', flush: true);

      await recoverInterruptedDictionaryUpdateBeforeOpen(activeDatabase.path);

      expect(
        await readDictionaryVersion(activeDatabase.path),
        '0.1.0-fixture.1',
      );
      expect(await backup.exists(), isFalse);
      expect(
        File('${activeDatabase.path}.update-in-progress').existsSync(),
        isFalse,
      );
      expect(File('${activeDatabase.path}.staged').existsSync(), isFalse);

      final repository = DriftDictionaryRepository(
        NativeDatabase(activeDatabase),
      );
      addTearDown(repository.close);
      await repository.verifyReady();
      expect((await repository.search('学校')).first.entry.headword, '学校');
    },
  );

  test('stage never performs late recovery while SQLite is open', () async {
    final repository = DriftDictionaryRepository(
      NativeDatabase(activeDatabase),
    );
    addTearDown(repository.close);
    await repository.verifyReady();
    final backup = await activeDatabase.copy('${activeDatabase.path}.backup');
    await File(
      '${activeDatabase.path}.update-in-progress',
    ).writeAsString('replace', flush: true);
    final storage = createFileUpdateStorage(
      activeDatabasePath: activeDatabase.path,
      healthCheck: isHealthySqliteDictionary,
      manifestHealthCheck: sqliteDictionaryMatchesManifest,
    );

    await expectLater(
      storage.stage(nextDatabaseBytes),
      throwsA(isA<Exception>()),
    );

    expect(await activeDatabase.readAsBytes(), oldDatabaseBytes);
    expect(await backup.exists(), isTrue);
    expect(
      File('${activeDatabase.path}.update-in-progress').existsSync(),
      isTrue,
    );
  });

  test(
    'controller awaits real Drift reopen query before committing backup',
    () async {
      final releaseDirectory = await _writeReleaseDirectory(
        temporaryDirectory,
        nextDatabaseBytes,
      );
      final events = <String>[];
      final container = _container(
        activeDatabase.path,
        events: events,
        failNewReadiness: false,
      );
      addTearDown(container.dispose);
      await _waitForControllerInitialization(container);

      await container
          .read(dictionaryUpdateControllerProvider.notifier)
          .installFromDirectory(releaseDirectory.path);

      final state = container.read(dictionaryUpdateControllerProvider);
      expect(state.phase, DictionaryUpdatePhase.succeeded);
      expect(state.currentVersion, '0.2.0');
      expect(await readDictionaryVersion(activeDatabase.path), '0.2.0');
      expect(events, contains('verify:0.2.0'));
      expect(File('${activeDatabase.path}.backup').existsSync(), isFalse);
      expect(
        File('${activeDatabase.path}.update-in-progress').existsSync(),
        isFalse,
      );
      final live = container.read(dictionaryRepositoryProvider);
      expect(live, isA<DictionaryRepositoryReadiness>());
      await (live as DictionaryRepositoryReadiness).verifyReady();
    },
  );

  test(
    'new Drift query failure closes it, rolls back, and verifies old repository',
    () async {
      final releaseDirectory = await _writeReleaseDirectory(
        temporaryDirectory,
        nextDatabaseBytes,
      );
      final events = <String>[];
      final container = _container(
        activeDatabase.path,
        events: events,
        failNewReadiness: true,
      );
      addTearDown(container.dispose);
      await _waitForControllerInitialization(container);

      await container
          .read(dictionaryUpdateControllerProvider.notifier)
          .installFromDirectory(releaseDirectory.path);

      final state = container.read(dictionaryUpdateControllerProvider);
      expect(state.phase, DictionaryUpdatePhase.failed);
      expect(
        await readDictionaryVersion(activeDatabase.path),
        '0.1.0-fixture.1',
      );
      expect(
        events,
        containsAllInOrder(<String>[
          'close:0.1.0-fixture.1',
          'verify:0.2.0',
          'close:0.2.0',
          'verify:0.1.0-fixture.1',
        ]),
      );
      expect(File('${activeDatabase.path}.backup').existsSync(), isFalse);
      expect(
        File('${activeDatabase.path}.update-in-progress').existsSync(),
        isFalse,
      );

      final restored = container.read(dictionaryRepositoryProvider);
      await (restored as DictionaryRepositoryReadiness).verifyReady();
      expect((await restored.search('学校')).first.entry.headword, '学校');
    },
  );
}

ProviderContainer _container(
  String activePath, {
  required List<String> events,
  required bool failNewReadiness,
}) {
  return ProviderContainer(
    overrides: [
      activeDictionaryDatabasePathProvider.overrideWith(
        (ref) async => activePath,
      ),
      dictionaryRepositoryProvider.overrideWith((ref) {
        final repository = _TrackedDriftRepository(
          activePath,
          events: events,
          failNewReadiness: failNewReadiness,
        );
        ref.onDispose(() => unawaited(repository.close()));
        return repository;
      }),
    ],
  );
}

Future<void> _waitForControllerInitialization(
  ProviderContainer container,
) async {
  container.read(dictionaryUpdateControllerProvider);
  for (var attempt = 0; attempt < 100; attempt++) {
    final state = container.read(dictionaryUpdateControllerProvider);
    if (state.currentVersion != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('Dictionary update controller did not initialize.');
}

Future<Directory> _writeReleaseDirectory(
  Directory root,
  Uint8List databaseBytes,
) async {
  final directory = await Directory(
    '${root.path}${Platform.pathSeparator}release',
  ).create();
  await File(
    '${directory.path}${Platform.pathSeparator}dictionary.sqlite',
  ).writeAsBytes(databaseBytes, flush: true);
  final databaseDigest = sha256.convert(databaseBytes).toString();
  final releaseBytes = utf8.encode(
    '${jsonEncode(<String, Object?>{'channel': 'release', 'content_status': 'reviewed', 'database_file': 'dictionary.sqlite', 'schema_version': 1, 'dictionary_version': '0.2.0', 'minimum_app_version': '0.1.0', 'database_size': databaseBytes.length, 'database_sha256': databaseDigest, 'released_at': '2026-08-01T00:00:00Z', 'license_status': 'cleared'})}\n',
  );
  final assetsBytes = utf8.encode(
    '${jsonEncode(<String, Object?>{'schema_version': 1, 'dictionary_version': '0.2.0', 'released_at': '2026-08-01T00:00:00Z', 'assets': <Object?>[]})}\n',
  );
  await File(
    '${directory.path}${Platform.pathSeparator}release-manifest.json',
  ).writeAsBytes(releaseBytes, flush: true);
  await File(
    '${directory.path}${Platform.pathSeparator}assets-manifest.json',
  ).writeAsBytes(assetsBytes, flush: true);
  await File(
    '${directory.path}${Platform.pathSeparator}checksums.txt',
  ).writeAsString(
    '$databaseDigest  dictionary.sqlite\n'
    '${sha256.convert(assetsBytes)}  assets-manifest.json\n'
    '${sha256.convert(releaseBytes)}  release-manifest.json\n',
    flush: true,
  );
  return directory;
}

class _TrackedDriftRepository
    implements
        DictionaryRepository,
        DictionaryRepositoryLifecycle,
        DictionaryRepositoryReadiness {
  _TrackedDriftRepository(
    this.path, {
    required this.events,
    required this.failNewReadiness,
  }) : _delegate = DriftDictionaryRepository(NativeDatabase(File(path)));

  final String path;
  final List<String> events;
  final bool failNewReadiness;
  final DriftDictionaryRepository _delegate;
  bool _closed = false;

  Future<String> _version() => readDictionaryVersion(path);

  @override
  Future<void> verifyReady() async {
    await _delegate.verifyReady();
    final version = await _version();
    events.add('verify:$version');
    if (failNewReadiness && version == '0.2.0') {
      throw StateError('Injected production repository query failure.');
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    events.add('close:${await _version()}');
    await _delegate.close();
  }

  @override
  Future<List<DictionaryEntry>> allEntries() => _delegate.allEntries();

  @override
  Future<DictionaryEntry?> findById(String entryId) {
    return _delegate.findById(entryId);
  }

  @override
  Future<List<DictionaryEntry>> findByIds(Iterable<String> entryIds) {
    return _delegate.findByIds(entryIds);
  }

  @override
  Future<List<SearchHit>> search(String rawQuery, {int limit = 50}) {
    return _delegate.search(rawQuery, limit: limit);
  }
}
