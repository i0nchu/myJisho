import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
          child: _AdaptiveSearchField(
            controller: controller,
            focusNode: focusNode,
            onClear: onClear,
            onChanged: (value) {
              final composing = controller.value.composing;
              if (composing.isValid && !composing.isCollapsed) return;
              ref.read(searchQueryControllerProvider.notifier).schedule(value);
            },
            onSubmitted: (value) =>
                ref.read(searchQueryControllerProvider.notifier).submit(value),
          ),
        ),
        SizedBox(
          key: const Key('search-progress-slot'),
          height: 2,
          child: resultState.isLoading
              ? const LinearProgressIndicator(
                  key: Key('search-refresh-progress'),
                  minHeight: 2,
                )
              : null,
        ),
        Expanded(
          child: queryState.query.isEmpty
              ? _RecentSearches(onUseQuery: onUseHistoryQuery)
              : resultState.hits.isNotEmpty
              ? _ResultList(
                  hits: resultState.hits,
                  selectedIndex: queryState.selectedIndex,
                  onOpenEntry: onOpenEntry,
                )
              : resultState.isLoading
              ? const _FirstSearchProgress()
              : resultState.error != null
              ? const _SearchError()
              : const _NoResults(),
        ),
      ],
    );
  }
}

class _AdaptiveSearchField extends StatefulWidget {
  const _AdaptiveSearchField({
    required this.controller,
    required this.focusNode,
    required this.onClear,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  State<_AdaptiveSearchField> createState() => _AdaptiveSearchFieldState();
}

class _AdaptiveSearchFieldState extends State<_AdaptiveSearchField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refreshSuffix);
  }

  @override
  void didUpdateWidget(covariant _AdaptiveSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_refreshSuffix);
    widget.controller.addListener(_refreshSuffix);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refreshSuffix);
    super.dispose();
  }

  void _refreshSuffix() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return CupertinoSearchTextField(
        key: const Key('search-field'),
        controller: widget.controller,
        focusNode: widget.focusNode,
        autofocus: true,
        placeholder: '漢字・かな・ローマ字・活用形',
        suffixMode: OverlayVisibilityMode.editing,
        onSuffixTap: widget.onClear,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
      );
    }

    return TextField(
      key: const Key('search-field'),
      controller: widget.controller,
      focusNode: widget.focusNode,
      autofocus: true,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '言葉を検索',
        helperText: '漢字・かな・ローマ字・活用形',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: widget.controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: '消す',
                onPressed: widget.onClear,
                icon: const Icon(Icons.clear),
              ),
      ),
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
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
        return _ResultRow(
          key: Key('result-${hit.entry.id}'),
          hit: hit,
          selected: index == selectedIndex,
          onTap: () => onOpenEntry(hit.entry.id),
        );
      },
    );
  }
}

class _ResultRow extends StatefulWidget {
  const _ResultRow({
    required this.hit,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final SearchHit hit;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ResultRow> createState() => _ResultRowState();
}

class _ResultRowState extends State<_ResultRow> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = widget.selected
        ? colors.secondaryContainer
        : _hovered || _focused
        ? colors.surfaceContainerHighest
        : colors.surface;
    final hit = widget.hit;

    return Semantics(
      button: true,
      focusable: true,
      selected: widget.selected,
      label:
          '${hit.entry.headword}、${hit.entry.reading}、'
          '${hit.entry.partOfSpeechLabel}、${hit.entry.primarySense.definition}',
      onTap: widget.onTap,
      child: ExcludeSemantics(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: FocusableActionDetector(
            onShowFocusHighlight: (value) => setState(() => _focused = value),
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onTap();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: AnimatedContainer(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 100),
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(
                    defaultTargetPlatform == TargetPlatform.iOS ? 10 : 6,
                  ),
                  border: Border.all(
                    color: widget.selected || _focused
                        ? colors.primary.withValues(alpha: 0.55)
                        : colors.outlineVariant.withValues(alpha: 0.55),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
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
                            child: Icon(
                              Icons.local_fire_department_outlined,
                              size: 18,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
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
                        '「${hit.derivedFrom}」は'
                        '「${hit.entry.headword}」の活用形かもしれません。',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
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

class _FirstSearchProgress extends StatelessWidget {
  const _FirstSearchProgress();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('first-search-progress'),
      child: Semantics(
        liveRegion: true,
        label: '検索中',
        child: const Text('検索しています…'),
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
