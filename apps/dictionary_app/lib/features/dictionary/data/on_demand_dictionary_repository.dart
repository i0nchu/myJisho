import '../domain/dictionary_entry.dart';
import '../domain/search_hit.dart';
import 'dictionary_repository.dart';
import 'fixture_dictionary_repository.dart';
import 'local_dictionary_client.dart';

/// Presents the immutable bundled dictionary and the mutable self-hosted
/// dictionary as one read surface.
///
/// Local-service failures never hide the bundled dictionary. Generation and
/// management calls do report those failures because there is no local
/// fallback for a mutation.
class OnDemandDictionaryRepository
    implements
        DictionaryRepository,
        DictionaryGenerationRepository,
        DictionaryEntryManagementRepository,
        DictionaryRepositoryLifecycle {
  OnDemandDictionaryRepository({required this.bundled, required this.local});

  final DictionaryRepository bundled;
  final LocalDictionaryGateway local;

  @override
  Future<List<SearchHit>> search(String rawQuery, {int limit = 50}) async {
    List<DictionaryEntry> localEntries;
    try {
      localEntries = await local.search(rawQuery);
    } on Object {
      localEntries = const [];
    }
    final results = await Future.wait([
      bundled.search(rawQuery, limit: limit),
      FixtureDictionaryRepository.fromEntries(
        localEntries,
      ).search(rawQuery, limit: limit),
    ]);
    final localHits = results[1];
    final localIds = localHits.map((hit) => hit.entry.id).toSet();
    final merged = <SearchHit>[
      ...localHits,
      ...results[0].where((hit) => !localIds.contains(hit.entry.id)),
    ]..sort((left, right) => right.score.compareTo(left.score));
    return merged.take(limit).toList(growable: false);
  }

  @override
  Future<DictionaryEntry?> findById(String entryId) async {
    try {
      final generated = await local.findById(entryId);
      if (generated != null) return generated;
    } on Object {
      // The immutable dictionary remains usable while the local service is
      // stopped or restarting.
    }
    return bundled.findById(entryId);
  }

  @override
  Future<List<DictionaryEntry>> findByIds(Iterable<String> entryIds) async {
    final wanted = entryIds.toSet();
    final generated = <DictionaryEntry>[];
    for (final entryId in wanted) {
      try {
        final entry = await local.findById(entryId);
        if (entry != null) generated.add(entry);
      } on Object {
        break;
      }
    }
    final localIds = generated.map((entry) => entry.id).toSet();
    final bundledEntries = await bundled.findByIds(wanted.difference(localIds));
    return [...generated, ...bundledEntries];
  }

  @override
  Future<List<DictionaryEntry>> allEntries() async {
    final bundledEntries = await bundled.allEntries();
    try {
      final generated = await local.allEntries();
      final localIds = generated.map((entry) => entry.id).toSet();
      return [
        ...generated,
        ...bundledEntries.where((entry) => !localIds.contains(entry.id)),
      ];
    } on Object {
      return bundledEntries;
    }
  }

  @override
  Future<DictionaryEntry> generateMissing(String query) =>
      local.generateMissing(query);

  @override
  Future<List<LocalDictionaryRevision>> listRevisions(String entryId) =>
      local.listRevisions(entryId);

  @override
  Future<DictionaryEntry> getRevision(String entryId, int revision) =>
      local.getRevision(entryId, revision);

  @override
  Future<DictionaryEntry> editEntry(
    String entryId,
    Map<String, Object?> patch,
  ) => local.editEntry(entryId, patch);

  @override
  Future<DictionaryEntry> restoreRevision(String entryId, int revision) =>
      local.restoreRevision(entryId, revision);

  @override
  Future<DictionaryEntry> regenerate(String entryId) =>
      local.regenerate(entryId);

  @override
  Future<DictionaryEntry> setLocked(String entryId, bool locked) =>
      local.setLocked(entryId, locked);

  @override
  Future<void> deleteEntry(String entryId) => local.deleteEntry(entryId);

  @override
  Future<void> close() async {
    if (local case final LocalDictionaryClient client) client.close();
    if (bundled case final DictionaryRepositoryLifecycle lifecycle) {
      await lifecycle.close();
    }
  }
}
