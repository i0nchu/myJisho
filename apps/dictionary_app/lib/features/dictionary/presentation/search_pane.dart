import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/application/library_controller.dart';
import '../application/dictionary_providers.dart';
import '../domain/search_hit.dart';

class SearchPane extends ConsumerWidget {
  const SearchPane({
    required this.controller,
    required this.focusNode,
    required this.onClear,
    required this.onOpenEntry,
    required this.onUseHistoryQuery,
    super.key,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;
  final ValueChanged<String> onOpenEntry;
  final ValueChanged<String> onUseHistoryQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queryState = ref.watch(searchQueryControllerProvider);
    final resultState = ref.watch(searchResultsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: TextField(
            key: const Key('search-field'),
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: '言葉を検索',
              hintText: '漢字・かな・ローマ字',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '消す',
                      onPressed: onClear,
                      icon: const Icon(Icons.clear),
                    ),
            ),
            onChanged: (value) {
              final composing = controller.value.composing;
              if (composing.isValid && !composing.isCollapsed) return;
              ref.read(searchQueryControllerProvider.notifier).schedule(value);
            },
            onSubmitted: (value) =>
                ref.read(searchQueryControllerProvider.notifier).submit(value),
          ),
        ),
        Expanded(
          child: queryState.query.isEmpty
              ? _RecentSearches(onUseQuery: onUseHistoryQuery)
              : resultState.when(
                  data: (hits) => hits.isEmpty
                      ? const _NoResults()
                      : _ResultList(
                          hits: hits,
                          selectedIndex: queryState.selectedIndex,
                          onOpenEntry: onOpenEntry,
                        ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator.adaptive()),
                  error: (error, stackTrace) => const _SearchError(),
                ),
        ),
      ],
    );
  }
}

class _ResultList extends StatelessWidget {
  const _ResultList({
    required this.hits,
    required this.selectedIndex,
    required this.onOpenEntry,
  });

  final List<SearchHit> hits;
  final int selectedIndex;
  final ValueChanged<String> onOpenEntry;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      key: const Key('search-results'),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
      itemCount: hits.length,
      separatorBuilder: (context, index) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        final hit = hits[index];
        return Card(
          color: index == selectedIndex
              ? Theme.of(context).colorScheme.secondaryContainer
              : null,
          child: ListTile(
            key: Key('result-${hit.entry.id}'),
            selected: index == selectedIndex,
            onTap: () => onOpenEntry(hit.entry.id),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    hit.entry.headword,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (hit.entry.frequencyRank <= 5000)
                  const Tooltip(
                    message: 'よく使う言葉',
                    child: Icon(Icons.local_fire_department_outlined, size: 18),
                  ),
              ],
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${hit.entry.reading}　${hit.entry.partOfSpeechLabel}'),
                  const SizedBox(height: 4),
                  Text(
                    hit.entry.primarySense.definition,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (hit.derivedFrom != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      '「${hit.derivedFrom}」は「${hit.entry.headword}」の活用形かもしれません。',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RecentSearches extends ConsumerWidget {
  const _RecentSearches({required this.onUseQuery});

  final ValueChanged<String> onUseQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryControllerProvider);
    return library.when(
      data: (value) {
        if (value.history.isEmpty) {
          return const _SearchStartHint();
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text('最近の検索', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final item in value.history.take(8))
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(item.query),
                trailing: const Icon(Icons.north_west, size: 18),
                onTap: () => onUseQuery(item.query),
              ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator.adaptive()),
      error: (error, stackTrace) => const _SearchStartHint(),
    );
  }
}

class _SearchStartHint extends StatelessWidget {
  const _SearchStartHint();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, size: 44),
            SizedBox(height: 12),
            Text('調べたい言葉を入力してください'),
            SizedBox(height: 6),
            Text('漢字、かな、ローマ字で検索できます。'),
          ],
        ),
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults();

  @override
  Widget build(BuildContext context) {
    return const Center(
      key: Key('empty-results'),
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 44),
            SizedBox(height: 12),
            Text('見つかりませんでした'),
            SizedBox(height: 6),
            Text('別の表記や読み方を試してください。'),
          ],
        ),
      ),
    );
  }
}

class _SearchError extends StatelessWidget {
  const _SearchError();

  @override
  Widget build(BuildContext context) {
    return const Center(
      key: Key('search-error'),
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 44),
            SizedBox(height: 12),
            Text('検索できませんでした'),
            SizedBox(height: 6),
            Text('辞書データを確認してください。'),
          ],
        ),
      ),
    );
  }
}
