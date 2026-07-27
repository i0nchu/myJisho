import 'dart:typed_data';

import '../domain/release_manifest.dart';
import '../domain/update_models.dart';
import 'dictionary_update_service.dart';

DictionaryPackageSource createLocalDirectoryPackageSource(
  String directoryPath,
) => _UnsupportedLocalPackageSource();

class _UnsupportedLocalPackageSource
    implements DictionaryPackageSource, CompleteDictionaryPackageSource {
  @override
  Future<Map<String, Object?>> fetchManifest() {
    throw UnsupportedError('Local release directories are not supported.');
  }

  @override
  Future<Uint8List> fetchDatabase(ReleaseManifest manifest) {
    throw UnsupportedError('Local release directories are not supported.');
  }

  @override
  Future<CompletePackageMetadata> fetchCompletePackageMetadata(
    UpdateCancellationToken cancellationToken,
  ) {
    throw UnsupportedError('Local release directories are not supported.');
  }

  @override
  Future<DictionaryDownload> openDatabaseDownload(
    ReleaseManifest manifest,
    UpdateCancellationToken cancellationToken,
  ) {
    throw UnsupportedError('Local release directories are not supported.');
  }
}
