import 'dictionary_update_recovery_stub.dart'
    if (dart.library.io) 'dictionary_update_recovery_io.dart'
    as implementation;

/// Restores the known-good backup for an interrupted activation transaction.
///
/// This must run before any SQLite connection opens the active path.
Future<void> recoverInterruptedDictionaryUpdateBeforeOpen(
  String activeDatabasePath,
) {
  return implementation.recoverInterruptedDictionaryUpdateBeforeOpen(
    activeDatabasePath,
  );
}
