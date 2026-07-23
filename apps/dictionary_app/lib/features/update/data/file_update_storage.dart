import 'file_update_storage_stub.dart'
    if (dart.library.io) 'file_update_storage_io.dart'
    as implementation;

import 'dictionary_update_service.dart';
import '../domain/release_manifest.dart';

DictionaryUpdateStorage createFileUpdateStorage({
  required String activeDatabasePath,
  required Future<bool> Function(String path) healthCheck,
  Future<bool> Function(String path, ReleaseManifest manifest)?
  manifestHealthCheck,
  Future<int?> Function(String path)? availableBytes,
}) {
  return implementation.createFileUpdateStorage(
    activeDatabasePath: activeDatabasePath,
    healthCheck: healthCheck,
    manifestHealthCheck: manifestHealthCheck,
    availableBytes: availableBytes,
  );
}
