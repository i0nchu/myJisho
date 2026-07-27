import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myjisho_dictionary_app/features/update/data/dictionary_update_service.dart';
import 'package:myjisho_dictionary_app/features/update/data/file_update_storage.dart';
import 'package:myjisho_dictionary_app/features/update/data/remote_dictionary_package_source.dart';
import 'package:myjisho_dictionary_app/features/update/data/sqlite_dictionary_inspector.dart';
import 'package:myjisho_dictionary_app/features/update/domain/release_manifest.dart';
import 'package:myjisho_dictionary_app/features/update/domain/update_models.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temporaryDirectory;
  late File activeDatabase;
  late Uint8List oldDatabaseBytes;
  late Uint8List nextDatabaseBytes;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'myjisho-remote-update-test-',
    );
    activeDatabase = await File(
      'assets/database/dictionary.sqlite',
    ).copy('${temporaryDirectory.path}${Platform.pathSeparator}active.sqlite');
    oldDatabaseBytes = await activeDatabase.readAsBytes();
    final nextDatabase = await activeDatabase.copy(
      '${temporaryDirectory.path}${Platform.pathSeparator}next.sqlite',
    );
    final database = sqlite3.open(nextDatabase.path);
    database.execute(
      "UPDATE metadata SET metadata_value = '0.2.0' "
      "WHERE metadata_key = 'dictionary_version'",
    );
    database.close();
    nextDatabaseBytes = await nextDatabase.readAsBytes();
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  DictionaryUpdateService makeService(
    _PackageServer server, {
    UpdateCancellationToken? cancellationToken,
    DictionaryUpdateProgressCallback? onProgress,
    Future<int?> Function(String path)? availableBytes,
  }) {
    return DictionaryUpdateService(
      source: createRemoteDictionaryPackageSource(
        server.baseUri,
        allowInsecureLoopback: true,
      ),
      storage: createFileUpdateStorage(
        activeDatabasePath: activeDatabase.path,
        healthCheck: isHealthySqliteDictionary,
        manifestHealthCheck: sqliteDictionaryMatchesManifest,
        availableBytes: availableBytes,
      ),
      supportedSchemaVersion: 1,
      currentDictionaryVersion: '0.1.0-fixture.1',
      currentAppVersion: '0.1.0',
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  test('streams a complete HTTP package and atomically activates it', () async {
    final package = _ReleasePackage(nextDatabaseBytes);
    final server = await _PackageServer.start(package);
    addTearDown(server.close);
    final progress = <DictionaryUpdateProgress>[];

    final result = await makeService(
      server,
      onProgress: progress.add,
    ).checkAndInstall();

    expect(result, DictionaryUpdateResult.updated);
    expect(await activeDatabase.readAsBytes(), nextDatabaseBytes);
    expect(await readDictionaryVersion(activeDatabase.path), '0.2.0');
    expect(
      server.requests,
      containsAll(<String>[
        '/releases/stable/release-manifest.json',
        '/releases/stable/assets-manifest.json',
        '/releases/stable/checksums.txt',
        '/releases/stable/dictionary.sqlite',
      ]),
    );
    final downloadProgress = progress
        .where(
          (item) => item.phase == DictionaryUpdateProgressPhase.downloading,
        )
        .toList();
    expect(downloadProgress, isNotEmpty);
    expect(downloadProgress.last.receivedBytes, nextDatabaseBytes.length);
    expect(downloadProgress.last.fraction, 1);
  });

  test(
    'wrong database SHA-256 discards staging and keeps the old DB',
    () async {
      final package = _ReleasePackage(
        nextDatabaseBytes,
        databaseDigest: '0' * 64,
      );
      final server = await _PackageServer.start(package);
      addTearDown(server.close);

      final result = await makeService(server).checkAndInstall();

      expect(result, DictionaryUpdateResult.invalidChecksum);
      expect(await activeDatabase.readAsBytes(), oldDatabaseBytes);
      expect(File('${activeDatabase.path}.staged').existsSync(), isFalse);
    },
  );

  test('HTTP size mismatch is rejected before staging', () async {
    final package = _ReleasePackage(
      nextDatabaseBytes,
      declaredDatabaseSize: nextDatabaseBytes.length + 1,
    );
    final server = await _PackageServer.start(package);
    addTearDown(server.close);

    final result = await makeService(server).checkAndInstall();

    expect(result, DictionaryUpdateResult.invalidSize);
    expect(await activeDatabase.readAsBytes(), oldDatabaseBytes);
    expect(File('${activeDatabase.path}.staged').existsSync(), isFalse);
  });

  test('size preflight disposes an unconsumed download handle', () async {
    final package = _ReleasePackage(
      nextDatabaseBytes,
      declaredDatabaseSize: nextDatabaseBytes.length + 1,
    );
    final source = _DisposablePackageSource(package);
    final service = DictionaryUpdateService(
      source: source,
      storage: createFileUpdateStorage(
        activeDatabasePath: activeDatabase.path,
        healthCheck: isHealthySqliteDictionary,
        manifestHealthCheck: sqliteDictionaryMatchesManifest,
      ),
      supportedSchemaVersion: 1,
      currentDictionaryVersion: '0.1.0-fixture.1',
      currentAppVersion: '0.1.0',
    );

    expect(await service.checkAndInstall(), DictionaryUpdateResult.invalidSize);
    expect(source.disposed, isTrue);
    expect(source.streamListened, isFalse);
  });

  test(
    'tampered assets manifest contract is rejected before database download',
    () async {
      final package = _ReleasePackage(
        nextDatabaseBytes,
        corruptAssetsChecksum: true,
      );
      final server = await _PackageServer.start(package);
      addTearDown(server.close);

      final result = await makeService(server).checkAndInstall();

      expect(result, DictionaryUpdateResult.invalidPackageContract);
      expect(
        server.requests,
        isNot(contains('/releases/stable/dictionary.sqlite')),
      );
      expect(await activeDatabase.readAsBytes(), oldDatabaseBytes);
    },
  );

  test('assets manifest must match SQLite media rows exactly', () async {
    final package = _ReleasePackage(
      nextDatabaseBytes,
      assets: <Object?>[
        <String, Object?>{
          'asset_id': 'asset_missing_from_sqlite',
          'kind': 'image',
          'path': 'assets/images/missing.png',
          'sha256': 'a' * 64,
          'source_id': 'source_missing',
          'license_spdx': 'CC0-1.0',
        },
      ],
    );
    final server = await _PackageServer.start(package);
    addTearDown(server.close);

    final result = await makeService(server).checkAndInstall();

    expect(result, DictionaryUpdateResult.unhealthyDatabase);
    expect(await activeDatabase.readAsBytes(), oldDatabaseBytes);
  });

  test(
    'cancelling a streamed download removes staging and keeps old DB',
    () async {
      final package = _ReleasePackage(nextDatabaseBytes);
      final server = await _PackageServer.start(package, slowDatabase: true);
      addTearDown(server.close);
      final cancellation = UpdateCancellationToken();

      final result = await makeService(
        server,
        cancellationToken: cancellation,
        onProgress: (progress) {
          if (progress.phase == DictionaryUpdateProgressPhase.downloading &&
              progress.receivedBytes > 0) {
            cancellation.cancel();
          }
        },
      ).checkAndInstall();

      expect(result, DictionaryUpdateResult.cancelled);
      expect(await activeDatabase.readAsBytes(), oldDatabaseBytes);
      expect(File('${activeDatabase.path}.staged').existsSync(), isFalse);
    },
  );

  test(
    'disk capacity failure occurs before download and keeps old DB',
    () async {
      final package = _ReleasePackage(nextDatabaseBytes);
      final server = await _PackageServer.start(package);
      addTearDown(server.close);

      final result = await makeService(
        server,
        availableBytes: (_) async => 0,
      ).checkAndInstall();

      expect(result, DictionaryUpdateResult.insufficientStorage);
      expect(
        server.requests,
        isNot(contains('/releases/stable/dictionary.sqlite')),
      );
      expect(await activeDatabase.readAsBytes(), oldDatabaseBytes);
    },
  );

  test('interrupted HTTP body removes staging and keeps old DB', () async {
    final package = _ReleasePackage(nextDatabaseBytes);
    final server = await _PackageServer.start(package, interruptDatabase: true);
    addTearDown(server.close);

    final result = await makeService(server).checkAndInstall();

    expect(result, DictionaryUpdateResult.downloadFailed);
    expect(await activeDatabase.readAsBytes(), oldDatabaseBytes);
    expect(File('${activeDatabase.path}.staged').existsSync(), isFalse);
  });

  test('SQLite metadata must match the release manifest version', () async {
    final package = _ReleasePackage(
      nextDatabaseBytes,
      dictionaryVersion: '0.3.0',
    );
    final server = await _PackageServer.start(package);
    addTearDown(server.close);

    final result = await makeService(server).checkAndInstall();

    expect(result, DictionaryUpdateResult.unhealthyDatabase);
    expect(await activeDatabase.readAsBytes(), oldDatabaseBytes);
  });

  test('oversized manifest is rejected before database download', () async {
    final package = _ReleasePackage(
      nextDatabaseBytes,
      declaredDatabaseSize: 151 * 1024 * 1024,
    );
    final server = await _PackageServer.start(package);
    addTearDown(server.close);

    final result = await makeService(server).checkAndInstall();

    expect(result, DictionaryUpdateResult.packageTooLarge);
    expect(
      server.requests,
      isNot(contains('/releases/stable/dictionary.sqlite')),
    );
    expect(await activeDatabase.readAsBytes(), oldDatabaseBytes);
  });

  test('non-loopback HTTP package sources are refused', () {
    expect(
      () => createRemoteDictionaryPackageSource(
        Uri.parse('http://example.com/releases/stable/'),
        allowInsecureLoopback: true,
      ),
      throwsArgumentError,
    );
  });
}

class _ReleasePackage {
  _ReleasePackage(
    this.databaseBytes, {
    this.dictionaryVersion = '0.2.0',
    String? databaseDigest,
    this.declaredDatabaseSize,
    this.corruptAssetsChecksum = false,
    this.assets = const <Object?>[],
  }) : databaseDigest =
           databaseDigest ?? sha256.convert(databaseBytes).toString() {
    releaseManifestBytes = Uint8List.fromList(
      utf8.encode(
        '${jsonEncode(<String, Object?>{'channel': 'release', 'content_status': 'reviewed', 'database_file': 'dictionary.sqlite', 'schema_version': 1, 'dictionary_version': dictionaryVersion, 'minimum_app_version': '0.1.0', 'database_size': declaredDatabaseSize ?? databaseBytes.length, 'database_sha256': this.databaseDigest, 'released_at': '2026-08-01T00:00:00Z', 'license_status': 'cleared'})}\n',
      ),
    );
    assetsManifestBytes = Uint8List.fromList(
      utf8.encode(
        '${jsonEncode(<String, Object?>{'schema_version': 1, 'dictionary_version': dictionaryVersion, 'released_at': '2026-08-01T00:00:00Z', 'assets': assets})}\n',
      ),
    );
    final assetsDigest = corruptAssetsChecksum
        ? 'f' * 64
        : sha256.convert(assetsManifestBytes).toString();
    checksumsBytes = Uint8List.fromList(
      utf8.encode(
        '${this.databaseDigest}  dictionary.sqlite\n'
        '$assetsDigest  assets-manifest.json\n'
        '${sha256.convert(releaseManifestBytes)}  release-manifest.json\n',
      ),
    );
  }

  final Uint8List databaseBytes;
  final String dictionaryVersion;
  final String databaseDigest;
  final int? declaredDatabaseSize;
  final bool corruptAssetsChecksum;
  final List<Object?> assets;
  late final Uint8List releaseManifestBytes;
  late final Uint8List assetsManifestBytes;
  late final Uint8List checksumsBytes;
}

class _PackageServer {
  _PackageServer._(
    this._server,
    this.package, {
    required this.slowDatabase,
    required this.interruptDatabase,
  });

  final HttpServer _server;
  final _ReleasePackage package;
  final bool slowDatabase;
  final bool interruptDatabase;
  final List<String> requests = <String>[];

  Uri get baseUri => Uri.parse(
    'http://${_server.address.address}:${_server.port}/releases/stable/',
  );

  static Future<_PackageServer> start(
    _ReleasePackage package, {
    bool slowDatabase = false,
    bool interruptDatabase = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _PackageServer._(
      server,
      package,
      slowDatabase: slowDatabase,
      interruptDatabase: interruptDatabase,
    );
    server.listen(fixture._handle);
    return fixture;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.uri.path);
    final filename = request.uri.pathSegments.last;
    final response = request.response;
    try {
      switch (filename) {
        case 'release-manifest.json':
          response.headers.contentType = ContentType.json;
          response.add(package.releaseManifestBytes);
        case 'assets-manifest.json':
          response.headers.contentType = ContentType.json;
          response.add(package.assetsManifestBytes);
        case 'checksums.txt':
          response.headers.contentType = ContentType.text;
          response.add(package.checksumsBytes);
        case 'dictionary.sqlite':
          response.headers.contentType = ContentType.binary;
          response.contentLength = package.databaseBytes.length;
          if (interruptDatabase) {
            response.add(
              package.databaseBytes.sublist(
                0,
                package.databaseBytes.length ~/ 3,
              ),
            );
            await response.close();
            return;
          }
          if (slowDatabase) {
            const chunkSize = 4096;
            for (
              var offset = 0;
              offset < package.databaseBytes.length;
              offset += chunkSize
            ) {
              final end = (offset + chunkSize).clamp(
                0,
                package.databaseBytes.length,
              );
              response.add(package.databaseBytes.sublist(offset, end));
              await response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 2));
            }
          } else {
            response.add(package.databaseBytes);
          }
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    } on Object {
      // Client cancellation and forced disconnects are expected fault cases.
    }
  }
}

class _DisposablePackageSource
    implements DictionaryPackageSource, CompleteDictionaryPackageSource {
  _DisposablePackageSource(this.package);

  final _ReleasePackage package;
  bool disposed = false;
  bool streamListened = false;

  @override
  Future<CompletePackageMetadata> fetchCompletePackageMetadata(
    UpdateCancellationToken cancellationToken,
  ) async {
    return CompletePackageMetadata(
      releaseManifestBytes: package.releaseManifestBytes,
      assetsManifestBytes: package.assetsManifestBytes,
      checksumsBytes: package.checksumsBytes,
    );
  }

  @override
  Future<DictionaryDownload> openDatabaseDownload(
    ReleaseManifest manifest,
    UpdateCancellationToken cancellationToken,
  ) async {
    Stream<List<int>> bytes() async* {
      streamListened = true;
      yield package.databaseBytes;
    }

    return DictionaryDownload(
      bytes: bytes(),
      contentLength: package.databaseBytes.length,
      onDispose: () async {
        disposed = true;
      },
    );
  }

  @override
  Future<Uint8List> fetchDatabase(ReleaseManifest manifest) async {
    return package.databaseBytes;
  }

  @override
  Future<Map<String, Object?>> fetchManifest() async {
    return jsonDecode(utf8.decode(package.releaseManifestBytes))
        as Map<String, Object?>;
  }
}
