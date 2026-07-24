import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dictionary_repository.dart';
import '../data/bundled_database_path.dart';
import '../data/drift_dictionary_repository.dart';
import '../data/fixture_dictionary_repository.dart';
import '../domain/dictionary_entry.dart';
import '../domain/search_hit.dart';

final activeDictionaryDatabasePathProvider = FutureProvider<String>((ref) {
  return prepareBundledDictionaryDatabase(
    rootBundle,
    'assets/database/dictionary.sqlite',
    recoverInterruptedUpdate: true,
  );
});

final dictionaryRepositoryProvider = Provider<DictionaryRepository>((ref) {
  final fixture = FixtureDictionaryRepository(rootBundle);
  if (kIsWeb) return fixture;
  final drift = DriftDictionaryRepository.withDatabasePath(
    () => ref.read(activeDictionaryDatabasePathProvider.future),
  );
  ref.onDispose(() => unawaited(drift.close()));
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
      _setQuery(query);
    });
  }

  void submit(String query) {
    _debounce?.cancel();
    _setQuery(query);
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

  void _setQuery(String query) {
    final normalized = query.trim();
    if (normalized == state.query && state.selectedIndex == 0) return;
    state = SearchQueryState(query: normalized);
  }
}

final searchQueryControllerProvider =
    NotifierProvider<SearchQueryController, SearchQueryState>(
      SearchQueryController.new,
    );

class SearchResultsState {
  const SearchResultsState({
    this.query = '',
    this.hits = const [],
    this.isLoading = false,
    this.hasCompletedSearch = false,
    this.error,
  });

  final String query;
  final List<SearchHit> hits;
  final bool isLoading;
  final bool hasCompletedSearch;
  final Object? error;

  SearchResultsState copyWith({
    String? query,
    List<SearchHit>? hits,
    bool? isLoading,
    bool? hasCompletedSearch,
    Object? error,
    bool clearError = false,
  }) {
    return SearchResultsState(
      query: query ?? this.query,
      hits: hits ?? this.hits,
      isLoading: isLoading ?? this.isLoading,
      hasCompletedSearch: hasCompletedSearch ?? this.hasCompletedSearch,
      error: clearError ? null : error ?? this.error,
    );
  }
}

/// Runs debounced searches with latest-query-wins semantics.
///
/// Existing hits remain visible while the next query is in flight. The
/// generation guard prevents a slow, stale response from replacing a newer
/// response even when the underlying database operation cannot be cancelled.
class SearchResultsController extends Notifier<SearchResultsState> {
  var _generation = 0;

  @override
  SearchResultsState build() {
    final repository = ref.watch(dictionaryRepositoryProvider);
    ref.listen<String>(
      searchQueryControllerProvider.select((value) => value.query),
      (previous, next) => unawaited(_search(repository, next)),
    );

    final query = ref.read(searchQueryControllerProvider).query;
    if (query.isNotEmpty) {
      Future<void>.microtask(() => _search(repository, query));
      return SearchResultsState(query: query, isLoading: true);
    }
    return const SearchResultsState();
  }

  Future<void> _search(DictionaryRepository repository, String query) async {
    final generation = ++_generation;
    if (query.isEmpty) {
      state = const SearchResultsState();
      return;
    }

    state = state.copyWith(
      query: query,
      isLoading: true,
      hasCompletedSearch: false,
      clearError: true,
    );
    try {
      final hits = await repository.search(query);
      if (generation != _generation) return;
      state = SearchResultsState(
        query: query,
        hits: hits,
        hasCompletedSearch: true,
      );
    } catch (error) {
      if (generation != _generation) return;
      state = state.copyWith(
        query: query,
        isLoading: false,
        hasCompletedSearch: true,
        error: error,
      );
    }
  }
}

final searchResultsProvider =
    NotifierProvider<SearchResultsController, SearchResultsState>(
      SearchResultsController.new,
    );

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
