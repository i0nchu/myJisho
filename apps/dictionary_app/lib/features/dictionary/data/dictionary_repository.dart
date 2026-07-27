import '../domain/dictionary_entry.dart';
import '../domain/search_hit.dart';
import 'local_dictionary_client.dart';

/// Read-only contract for the versioned dictionary database.
///
/// The prototype uses a bundled JSON fixture. A production Drift adapter can
/// implement this interface without changing Riverpod state or widgets.
abstract interface class DictionaryRepository {
  Future<List<SearchHit>> search(String rawQuery, {int limit = 50});

  Future<DictionaryEntry?> findById(String entryId);

  Future<List<DictionaryEntry>> findByIds(Iterable<String> entryIds);

  Future<List<DictionaryEntry>> allEntries();
}

abstract interface class DictionaryRepositoryLifecycle {
  Future<void> close();
}

/// Opens the production repository and executes a minimal real query.
///
/// Update activation must await this before deleting its rollback backup.
abstract interface class DictionaryRepositoryReadiness {
  Future<void> verifyReady();
}

/// Optional self-hosted generation capability.
///
/// Search remains read-only. Implementations may generate only when this
/// method is called after an explicit user submission.
abstract interface class DictionaryGenerationRepository {
  Future<DictionaryEntry> generateMissing(String query);
}

abstract interface class DictionaryEntryManagementRepository {
  Future<List<LocalDictionaryRevision>> listRevisions(String entryId);

  Future<DictionaryEntry> getRevision(String entryId, int revision);

  Future<DictionaryEntry> editEntry(String entryId, Map<String, Object?> patch);

  Future<DictionaryEntry> restoreRevision(String entryId, int revision);

  Future<DictionaryEntry> regenerate(String entryId);

  Future<DictionaryEntry> setLocked(String entryId, bool locked);

  Future<void> deleteEntry(String entryId);
}
