import 'dictionary_update_service.dart';

DictionaryUpdateStorage createFileUpdateStorage({
  required String activeDatabasePath,
  required Future<bool> Function(String path) healthCheck,
}) {
  throw UnsupportedError(
    'Atomic file updates are unavailable on this platform.',
  );
}
