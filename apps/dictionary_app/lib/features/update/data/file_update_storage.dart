import 'file_update_storage_stub.dart'
    if (dart.library.io) 'file_update_storage_io.dart'
    as implementation;

import 'dictionary_update_service.dart';

DictionaryUpdateStorage createFileUpdateStorage({
  required String activeDatabasePath,
  required Future<bool> Function(String path) healthCheck,
}) {
  return implementation.createFileUpdateStorage(
    activeDatabasePath: activeDatabasePath,
    healthCheck: healthCheck,
  );
}
