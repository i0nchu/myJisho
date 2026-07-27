import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myjisho_dictionary_app/features/update/data/dictionary_update_service.dart';
import 'package:myjisho_dictionary_app/features/update/domain/release_manifest.dart';

void main() {
  final bytes = Uint8List.fromList(utf8.encode('healthy sqlite package'));

  Map<String, Object?> manifestFor(Uint8List value) => {
    'channel': 'release',
    'content_status': 'reviewed',
    'database_file': 'dictionary.sqlite',
    'schema_version': 1,
    'dictionary_version': '2026.08.0',
    'minimum_app_version': '0.1.0',
    'database_size': value.length,
    'database_sha256': sha256.convert(value).toString(),
    'released_at': '2026-08-01T00:00:00Z',
  };

  test('validates and atomically activates a healthy package', () async {
    final storage = _MemoryUpdateStorage();
    final service = DictionaryUpdateService(
      source: _MemorySource(manifestFor(bytes), bytes),
      storage: storage,
      supportedSchemaVersion: 1,
      currentDictionaryVersion: '2026.07.0',
      currentAppVersion: '0.1.0',
    );

    expect(await service.checkAndInstall(), DictionaryUpdateResult.updated);
    expect(storage.active, bytes);
    expect(storage.activateCount, 1);
  });

  test('rejects a package before staging when checksum is invalid', () async {
    final storage = _MemoryUpdateStorage();
    final manifest = manifestFor(bytes)..['database_sha256'] = '0' * 64;
    final service = DictionaryUpdateService(
      source: _MemorySource(manifest, bytes),
      storage: storage,
      supportedSchemaVersion: 1,
      currentDictionaryVersion: '2026.07.0',
      currentAppVersion: '0.1.0',
    );

    expect(
      await service.checkAndInstall(),
      DictionaryUpdateResult.invalidChecksum,
    );
    expect(storage.activateCount, 0);
  });

  test('rejects development channel before fetching database', () async {
    final storage = _MemoryUpdateStorage();
    final manifest = manifestFor(bytes)..['channel'] = 'development';
    final source = _MemorySource(manifest, bytes);
    final service = DictionaryUpdateService(
      source: source,
      storage: storage,
      supportedSchemaVersion: 1,
      currentDictionaryVersion: '2026.07.0',
      currentAppVersion: '0.1.0',
    );

    expect(
      await service.checkAndInstall(),
      DictionaryUpdateResult.invalidReleaseChannel,
    );
    expect(source.databaseFetchCount, 0);
  });

  test('rejects unreviewed content before fetching database', () async {
    final storage = _MemoryUpdateStorage();
    final manifest = manifestFor(bytes)..['content_status'] = 'unreviewed';
    final source = _MemorySource(manifest, bytes);
    final service = DictionaryUpdateService(
      source: source,
      storage: storage,
      supportedSchemaVersion: 1,
      currentDictionaryVersion: '2026.07.0',
      currentAppVersion: '0.1.0',
    );

    expect(
      await service.checkAndInstall(),
      DictionaryUpdateResult.unreviewedContent,
    );
    expect(source.databaseFetchCount, 0);
  });

  test('rejects unsafe or unexpected database_file', () async {
    for (final fileName in ['../dictionary.sqlite', 'other.sqlite']) {
      final manifest = manifestFor(bytes)..['database_file'] = fileName;
      final source = _MemorySource(manifest, bytes);
      final service = DictionaryUpdateService(
        source: source,
        storage: _MemoryUpdateStorage(),
        supportedSchemaVersion: 1,
        currentDictionaryVersion: '2026.07.0',
        currentAppVersion: '0.1.0',
      );
      expect(
        await service.checkAndInstall(),
        DictionaryUpdateResult.invalidDatabaseFile,
      );
      expect(source.databaseFetchCount, 0);
    }
  });

  test(
    'keeps the active package when staged SQLite health check fails',
    () async {
      final storage = _MemoryUpdateStorage(healthy: false)
        ..active = Uint8List.fromList([1, 2, 3]);
      final previous = storage.active;
      final service = DictionaryUpdateService(
        source: _MemorySource(manifestFor(bytes), bytes),
        storage: storage,
        supportedSchemaVersion: 1,
        currentDictionaryVersion: '2026.07.0',
        currentAppVersion: '0.1.0',
      );

      expect(
        await service.checkAndInstall(),
        DictionaryUpdateResult.unhealthyDatabase,
      );
      expect(storage.active, same(previous));
    },
  );

  test('compares prerelease dictionary versions safely', () async {
    final releaseManifest = manifestFor(bytes)
      ..['dictionary_version'] = '0.1.0';
    final update = DictionaryUpdateService(
      source: _MemorySource(releaseManifest, bytes),
      storage: _MemoryUpdateStorage(),
      supportedSchemaVersion: 1,
      currentDictionaryVersion: '0.1.0-fixture.1',
      currentAppVersion: '0.1.0',
    );
    expect(await update.checkAndInstall(), DictionaryUpdateResult.updated);

    final prereleaseManifest = manifestFor(bytes)
      ..['dictionary_version'] = '0.1.0-fixture.2';
    final noDowngrade = DictionaryUpdateService(
      source: _MemorySource(prereleaseManifest, bytes),
      storage: _MemoryUpdateStorage(),
      supportedSchemaVersion: 1,
      currentDictionaryVersion: '0.1.0',
      currentAppVersion: '0.1.0',
    );
    expect(
      await noDowngrade.checkAndInstall(),
      DictionaryUpdateResult.alreadyCurrent,
    );
  });

  test('rolls back when reopening the activated database fails', () async {
    final oldBytes = Uint8List.fromList([1, 2, 3]);
    final storage = _MemoryUpdateStorage()..active = oldBytes;
    var reopenCount = 0;
    final service = DictionaryUpdateService(
      source: _MemorySource(manifestFor(bytes), bytes),
      storage: storage,
      supportedSchemaVersion: 1,
      currentDictionaryVersion: '2026.07.0',
      currentAppVersion: '0.1.0',
      beforeActivate: () async {},
      afterActivate: () async {
        reopenCount++;
        if (reopenCount == 1) throw StateError('new database cannot reopen');
      },
    );

    await expectLater(service.checkAndInstall(), throwsStateError);
    expect(storage.active, same(oldBytes));
    expect(storage.commitCount, 0);
    expect(reopenCount, 2, reason: 'the restored database is reopened');
  });
}

class _MemorySource implements DictionaryPackageSource {
  _MemorySource(this.manifest, this.bytes);

  final Map<String, Object?> manifest;
  final Uint8List bytes;
  int databaseFetchCount = 0;

  @override
  Future<Uint8List> fetchDatabase(ReleaseManifest manifest) async {
    databaseFetchCount++;
    return bytes;
  }

  @override
  Future<Map<String, Object?>> fetchManifest() async => manifest;
}

class _MemoryUpdateStorage implements DictionaryUpdateStorage {
  _MemoryUpdateStorage({this.healthy = true});

  final bool healthy;
  Uint8List? staged;
  Uint8List? active;
  Uint8List? backup;
  int activateCount = 0;
  int commitCount = 0;

  @override
  Future<String> stage(Uint8List databaseBytes) async {
    staged = databaseBytes;
    return 'staged';
  }

  @override
  Future<bool> isHealthy(String stagedHandle) async => healthy;

  @override
  Future<void> activate(String stagedHandle) async {
    activateCount++;
    backup = active;
    active = staged;
    staged = null;
  }

  @override
  Future<void> commit() async {
    commitCount++;
    backup = null;
  }

  @override
  Future<void> rollback() async => active = backup;

  @override
  Future<void> discard(String stagedHandle) async => staged = null;
}
