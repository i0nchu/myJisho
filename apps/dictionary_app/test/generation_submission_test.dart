import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myjisho_dictionary_app/features/dictionary/application/dictionary_providers.dart';
import 'package:myjisho_dictionary_app/features/dictionary/data/dictionary_repository.dart';
import 'package:myjisho_dictionary_app/features/dictionary/domain/dictionary_entry.dart';
import 'package:myjisho_dictionary_app/features/dictionary/domain/search_hit.dart';

import 'test_data.dart';

void main() {
  testWidgets('typing never generates; explicit submission generates a miss', (
    tester,
  ) async {
    final repository = _GeneratingRepository();
    final container = ProviderContainer(
      overrides: [dictionaryRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final subscription = container.listen<SearchResultsState>(
      searchResultsProvider,
      (previous, next) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    container.read(searchQueryControllerProvider.notifier).schedule('未登録語');
    await tester.pump(const Duration(milliseconds: 130));
    await tester.pump();

    expect(repository.searchCalls, 1);
    expect(repository.generationCalls, 0);
    expect(container.read(searchResultsProvider).hits, isEmpty);

    container.read(searchQueryControllerProvider.notifier).submit('未登録語');
    await tester.pump();
    await tester.pump();

    expect(repository.generationCalls, 1);
    expect(
      container.read(searchResultsProvider).hits.single.entry.headword,
      '新語',
    );
    expect(
      container.read(searchResultsProvider).generatedEntryId,
      'entry_generated_test',
    );
  });

  testWidgets('an existing result is reused without generation', (
    tester,
  ) async {
    final existing = testEntry();
    final repository = _GeneratingRepository(hits: [_hit(existing)]);
    final container = ProviderContainer(
      overrides: [dictionaryRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    final subscription = container.listen<SearchResultsState>(
      searchResultsProvider,
      (previous, next) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    container
        .read(searchQueryControllerProvider.notifier)
        .submit(existing.headword);
    await tester.pump();
    await tester.pump();

    expect(repository.generationCalls, 0);
    expect(container.read(searchResultsProvider).hits.single.entry, existing);
  });
}

class _GeneratingRepository
    implements DictionaryRepository, DictionaryGenerationRepository {
  _GeneratingRepository({this.hits = const []});

  final List<SearchHit> hits;
  var searchCalls = 0;
  var generationCalls = 0;

  @override
  Future<List<SearchHit>> search(String rawQuery, {int limit = 50}) async {
    searchCalls += 1;
    return hits;
  }

  @override
  Future<DictionaryEntry> generateMissing(String query) async {
    generationCalls += 1;
    return testEntry(
      id: 'entry_generated_test',
      headword: '新語',
      reading: 'しんご',
    );
  }

  @override
  Future<List<DictionaryEntry>> allEntries() async =>
      hits.map((hit) => hit.entry).toList(growable: false);

  @override
  Future<DictionaryEntry?> findById(String entryId) async {
    for (final hit in hits) {
      if (hit.entry.id == entryId) return hit.entry;
    }
    return null;
  }

  @override
  Future<List<DictionaryEntry>> findByIds(Iterable<String> entryIds) async {
    final wanted = entryIds.toSet();
    return hits
        .map((hit) => hit.entry)
        .where((entry) => wanted.contains(entry.id))
        .toList(growable: false);
  }
}

SearchHit _hit(DictionaryEntry entry) => SearchHit(
  entry: entry,
  kind: MatchKind.primaryExact,
  baseScore: 1000,
  score: 1000,
  matchedKey: entry.headword,
  modifiers: const [],
);
