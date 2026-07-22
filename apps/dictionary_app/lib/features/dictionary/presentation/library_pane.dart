import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/application/library_controller.dart';
import '../application/dictionary_providers.dart';
import '../domain/dictionary_entry.dart';

enum LibraryPaneMode { favorites, history }

class LibraryPane extends ConsumerWidget {
  const LibraryPane({
    required this.mode,
    required this.onOpenEntry,
    required this.onUseHistoryQuery,
    super.key,
  });

  final LibraryPaneMode mode;
  final ValueChanged<String> onOpenEntry;
  final ValueChanged<String> onUseHistoryQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryControllerProvider);
    return library.when(
      data: (value) {
        if (mode == LibraryPaneMode.history) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PaneHeader(
                title: '検索履歴',
                action: value.history.isEmpty
                    ? null
                    : TextButton(
                        onPressed: () => ref
                            .read(libraryControllerProvider.notifier)
                            .clearHistory(),
                        child: const Text('すべて消す'),
                      ),
              ),
              Expanded(
                child: value.history.isEmpty
                    ? const _EmptyLibrary(
                        icon: Icons.history,
                        title: '履歴はまだありません',
                        message: '検索した言葉がここに表示されます。',
                      )
                    : ListView.builder(
                        itemCount: value.history.length,
                        itemBuilder: (context, index) {
                          final item = value.history[index];
                          return ListTile(
                            leading: const Icon(Icons.history),
                            title: Text(item.query),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => onUseHistoryQuery(item.query),
                          );
                        },
                      ),
              ),
            ],
          );
        }

        return ref
            .watch(entriesByIdsProvider(value.favoriteEntryIds))
            .when(
              data: (entries) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _PaneHeader(title: 'お気に入り'),
                    Expanded(
                      child: entries.isEmpty
                          ? const _EmptyLibrary(
                              icon: Icons.star_outline,
                              title: 'お気に入りはまだありません',
                              message: '言葉の星を押すと、ここに保存できます。',
                            )
                          : _FavoriteList(
                              entries: entries,
                              onOpenEntry: onOpenEntry,
                            ),
                    ),
                  ],
                );
              },
              loading: () =>
                  const Center(child: CircularProgressIndicator.adaptive()),
              error: (error, stackTrace) =>
                  const Center(child: Text('お気に入りを読み込めませんでした。')),
            );
      },
      loading: () => const Center(child: CircularProgressIndicator.adaptive()),
      error: (error, stackTrace) =>
          const Center(child: Text('保存した内容を読み込めませんでした。')),
    );
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _FavoriteList extends StatelessWidget {
  const _FavoriteList({required this.entries, required this.onOpenEntry});

  final List<DictionaryEntry> entries;
  final ValueChanged<String> onOpenEntry;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ListTile(
          leading: const Icon(Icons.star),
          title: Text(entry.headword),
          subtitle: Text('${entry.reading}　${entry.primarySense.definition}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => onOpenEntry(entry.id),
        );
      },
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44),
            const SizedBox(height: 12),
            Text(title),
            const SizedBox(height: 6),
            Text(message),
          ],
        ),
      ),
    );
  }
}
