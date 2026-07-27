import 'dart:typed_data';

import '../domain/release_manifest.dart';
import '../domain/update_models.dart';
import 'dictionary_update_service.dart';

DictionaryPackageSource createRemoteDictionaryPackageSource(
  Uri baseUri, {
  bool allowInsecureLoopback = false,
}) {
  return _UnsupportedRemotePackageSource();
}

class _UnsupportedRemotePackageSource
    implements DictionaryPackageSource, CompleteDictionaryPackageSource {
  Never _unsupported() {
    throw UnsupportedError(
      'Remote dictionary updates are unavailable on this platform.',
    );
  }

  @override
  Future<Uint8List> fetchDatabase(ReleaseManifest manifest) => _unsupported();

  @override
  Future<Map<String, Object?>> fetchManifest() => _unsupported();

  @override
  Future<CompletePackageMetadata> fetchCompletePackageMetadata(
    UpdateCancellationToken cancellationToken,
  ) => _unsupported();

  @override
  Future<DictionaryDownload> openDatabaseDownload(
    ReleaseManifest manifest,
    UpdateCancellationToken cancellationToken,
  ) => _unsupported();
}
