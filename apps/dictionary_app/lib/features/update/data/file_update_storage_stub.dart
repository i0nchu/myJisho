import 'dictionary_update_service.dart';
import '../domain/release_manifest.dart';

DictionaryUpdateStorage createFileUpdateStorage({
  required String activeDatabasePath,
  required Future<bool> Function(String path) healthCheck,
  Future<bool> Function(String path, ReleaseManifest manifest)?
  manifestHealthCheck,
  Future<int?> Function(String path)? availableBytes,
}) {
  throw UnsupportedError(
    'Atomic file updates are unavailable on this platform.',
  );
}
