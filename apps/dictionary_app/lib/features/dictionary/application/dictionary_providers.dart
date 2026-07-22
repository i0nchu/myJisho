import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dictionary_repository.dart';
import '../data/drift_dictionary_repository.dart';
import '../data/fixture_dictionary_repository.dart';
import '../domain/dictionary_entry.dart';
import '../domain/search_hit.dart';

final dictionaryRepositoryProvider = Provider<DictionaryRepository>((ref) {
  final fixture = FixtureDictionaryRepository(rootBundle);
  if (kIsWeb) return fixture;
  final drift = DriftDictionaryRepository.bundled(rootBundle);
  ref.onDispose(drift.close);
  return FallbackDictionaryRepository(primary: drift, fallback: fixture);
});

class SearchQueryState {
  const SearchQueryState({this.query = '', this.selectedIndex = 0});

  final String query;
  final int selectedIndex;

  SearchQueryState copyWith({String? query, int? selectedIndex}) {
    return SearchQueryState(
      query: query ?? this.query,
      selectedIndex: selectedIndex ?? this.selectedIndex,
    );
  }
}

class SearchQueryController extends Notifier<SearchQueryState> {
  Timer? _debounce;

  @override
  SearchQueryState build() {
    ref.onDispose(() => _debounce?.cancel());
    return const SearchQueryState();
  }

  void schedule(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), () {
      state = SearchQueryState(query: query.trim());
    });
  }

  void submit(String query) {
    _debounce?.cancel();
    state = SearchQueryState(query: query.trim());
  }

  void clear() {
    _debounce?.cancel();
    state = const SearchQueryState();
  }

  void moveSelection(int delta, int resultCount) {
    if (resultCount == 0) return;
    final next = (state.selectedIndex + delta).clamp(0, resultCount - 1);
    state = state.copyWith(selectedIndex: next);
  }
}

final searchQueryControllerProvider =
    NotifierProvider<SearchQueryController, SearchQueryState>(
      SearchQueryController.new,
    );

final searchResultsProvider = FutureProvider<List<SearchHit>>((ref) async {
  final query = ref.watch(searchQueryControllerProvider).query;
  return ref.watch(dictionaryRepositoryProvider).search(query);
});

final entryProvider = FutureProvider.family<DictionaryEntry?, String>(
  (ref, entryId) => ref.watch(dictionaryRepositoryProvider).findById(entryId),
);

final allEntriesProvider = FutureProvider<List<DictionaryEntry>>(
  (ref) => ref.watch(dictionaryRepositoryProvider).allEntries(),
);

final entriesByIdsProvider =
    FutureProvider.family<List<DictionaryEntry>, Set<String>>(
      (ref, entryIds) =>
          ref.watch(dictionaryRepositoryProvider).findByIds(entryIds),
    );
