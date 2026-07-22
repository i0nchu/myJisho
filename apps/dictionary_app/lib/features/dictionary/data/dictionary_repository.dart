import '../domain/dictionary_entry.dart';
import '../domain/search_hit.dart';

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
