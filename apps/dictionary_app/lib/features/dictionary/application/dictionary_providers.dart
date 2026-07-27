import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dictionary_repository.dart';
import '../data/bundled_database_path.dart';
import '../data/drift_dictionary_repository.dart';
import '../data/fixture_dictionary_repository.dart';
import '../data/local_dictionary_client.dart';
import '../data/on_demand_dictionary_repository.dart';
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
  final bundled = FallbackDictionaryRepository(
    primary: drift,
    fallback: fixture,
  );
  final local = LocalDictionaryClient();
  ref.onDispose(() {
    local.close();
    unawaited(drift.close());
  });
  return OnDemandDictionaryRepository(bundled: bundled, local: local);
});

class SearchQueryState {
  const SearchQueryState({
    this.query = '',
    this.selectedIndex = 0,
    this.submissionSequence = 0,
  });

  final String query;
  final int selectedIndex;
  final int submissionSequence;

  SearchQueryState copyWith({
    String? query,
    int? selectedIndex,
    int? submissionSequence,
  }) {
    return SearchQueryState(
      query: query ?? this.query,
      selectedIndex: selectedIndex ?? this.selectedIndex,
      submissionSequence: submissionSequence ?? this.submissionSequence,
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
    final normalized = query.trim();
    if (normalized.isEmpty) {
      clear();
      return;
    }
    state = SearchQueryState(
      query: normalized,
      submissionSequence: state.submissionSequence + 1,
    );
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
    state = SearchQueryState(
      query: normalized,
      submissionSequence: state.submissionSequence,
    );
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
    this.isGenerating = false,
    this.hasCompletedSearch = false,
    this.error,
    this.generationFailure,
    this.generatedEntryId,
  });

  final String query;
  final List<SearchHit> hits;
  final bool isLoading;
  final bool isGenerating;
  final bool hasCompletedSearch;
  final Object? error;
  final DictionaryGenerationFailure? generationFailure;
  final String? generatedEntryId;

  SearchResultsState copyWith({
    String? query,
    List<SearchHit>? hits,
    bool? isLoading,
    bool? isGenerating,
    bool? hasCompletedSearch,
    Object? error,
    DictionaryGenerationFailure? generationFailure,
    String? generatedEntryId,
    bool clearError = false,
    bool clearGenerationFailure = false,
    bool clearGeneratedEntry = false,
  }) {
    return SearchResultsState(
      query: query ?? this.query,
      hits: hits ?? this.hits,
      isLoading: isLoading ?? this.isLoading,
      isGenerating: isGenerating ?? this.isGenerating,
      hasCompletedSearch: hasCompletedSearch ?? this.hasCompletedSearch,
      error: clearError ? null : error ?? this.error,
      generationFailure: clearGenerationFailure
          ? null
          : generationFailure ?? this.generationFailure,
      generatedEntryId: clearGeneratedEntry
          ? null
          : generatedEntryId ?? this.generatedEntryId,
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
    ref.listen<SearchQueryState>(searchQueryControllerProvider, (
      previous,
      next,
    ) {
      final submitted =
          previous != null &&
          next.submissionSequence != previous.submissionSequence;
      if (next.query != previous?.query || submitted) {
        unawaited(
          _search(repository, next.query, generateIfMissing: submitted),
        );
      }
    });

    final query = ref.read(searchQueryControllerProvider).query;
    if (query.isNotEmpty) {
      Future<void>.microtask(
        () => _search(repository, query, generateIfMissing: false),
      );
      return SearchResultsState(query: query, isLoading: true);
    }
    return const SearchResultsState();
  }

  Future<void> retryGeneration() => _search(
    ref.read(dictionaryRepositoryProvider),
    ref.read(searchQueryControllerProvider).query,
    generateIfMissing: true,
  );

  Future<void> _search(
    DictionaryRepository repository,
    String query, {
    required bool generateIfMissing,
  }) async {
    final generation = ++_generation;
    if (query.isEmpty) {
      state = const SearchResultsState();
      return;
    }

    state = state.copyWith(
      query: query,
      isLoading: true,
      isGenerating: false,
      hasCompletedSearch: false,
      clearError: true,
      clearGenerationFailure: true,
      clearGeneratedEntry: true,
    );
    try {
      final hits = await repository.search(query);
      if (generation != _generation) return;
      if (hits.isEmpty &&
          generateIfMissing &&
          repository is DictionaryGenerationRepository) {
        final generator = repository as DictionaryGenerationRepository;
        state = SearchResultsState(
          query: query,
          isGenerating: true,
          hasCompletedSearch: true,
        );
        try {
          final entry = await generator.generateMissing(query);
          if (generation != _generation) return;
          final hit = SearchHit(
            entry: entry,
            kind: MatchKind.primaryExact,
            baseScore: 1000,
            score: 1000 + entry.editorialLevel.rankingBoost,
            matchedKey: entry.headword,
            modifiers: entry.editorialLevel.rankingBoost == 0
                ? const []
                : [
                    SearchScoreModifier(
                      'editorial_${entry.editorialLevel.name}',
                      entry.editorialLevel.rankingBoost,
                    ),
                  ],
            derivedFrom: query == entry.headword ? null : query,
          );
          state = SearchResultsState(
            query: query,
            hits: [hit],
            hasCompletedSearch: true,
            generatedEntryId: entry.id,
          );
        } on DictionaryGenerationFailure catch (error) {
          if (generation != _generation) return;
          state = SearchResultsState(
            query: query,
            hasCompletedSearch: true,
            generationFailure: error,
          );
        } on Object catch (error) {
          if (generation != _generation) return;
          state = SearchResultsState(
            query: query,
            hasCompletedSearch: true,
            generationFailure: DictionaryGenerationFailure(
              message: '詞條生成失敗：$error',
            ),
          );
        }
        return;
      }
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
