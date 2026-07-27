import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../domain/release_manifest.dart';
import '../domain/update_models.dart';
import 'dictionary_update_service.dart';

DictionaryPackageSource createLocalDirectoryPackageSource(
  String directoryPath,
) => LocalDirectoryPackageSource(directoryPath);

class LocalDirectoryPackageSource
    implements DictionaryPackageSource, CompleteDictionaryPackageSource {
  LocalDirectoryPackageSource(this.directoryPath);

  final String directoryPath;

  @override
  Future<Map<String, Object?>> fetchManifest() async {
    final file = File(p.join(directoryPath, 'release-manifest.json'));
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('release-manifest.json must be an object.');
    }
    return decoded;
  }

  @override
  Future<CompletePackageMetadata> fetchCompletePackageMetadata(
    UpdateCancellationToken cancellationToken,
  ) async {
    cancellationToken.throwIfCancelled();
    Future<Uint8List> readFixed(String filename) async {
      cancellationToken.throwIfCancelled();
      return File(p.join(directoryPath, filename)).readAsBytes();
    }

    return CompletePackageMetadata(
      releaseManifestBytes: await readFixed('release-manifest.json'),
      assetsManifestBytes: await readFixed('assets-manifest.json'),
      checksumsBytes: await readFixed('checksums.txt'),
    );
  }

  @override
  Future<Uint8List> fetchDatabase(ReleaseManifest manifest) async {
    return _databaseFile(manifest).readAsBytes();
  }

  @override
  Future<DictionaryDownload> openDatabaseDownload(
    ReleaseManifest manifest,
    UpdateCancellationToken cancellationToken,
  ) async {
    cancellationToken.throwIfCancelled();
    final file = _databaseFile(manifest);
    return DictionaryDownload(
      bytes: _cancellableFileStream(file, cancellationToken),
      contentLength: await file.length(),
    );
  }

  File _databaseFile(ReleaseManifest manifest) {
    if (manifest.databaseFile != 'dictionary.sqlite') {
      throw const FormatException('database_file must be dictionary.sqlite.');
    }
    return File(p.join(directoryPath, 'dictionary.sqlite'));
  }

  Stream<List<int>> _cancellableFileStream(
    File file,
    UpdateCancellationToken cancellationToken,
  ) async* {
    await for (final chunk in file.openRead()) {
      cancellationToken.throwIfCancelled();
      yield chunk;
    }
    cancellationToken.throwIfCancelled();
  }
}
