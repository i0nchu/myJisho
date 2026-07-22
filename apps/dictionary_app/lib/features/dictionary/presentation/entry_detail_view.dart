import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/application/library_controller.dart';
import '../../media/application/audio_controller.dart';
import '../../pronunciation/application/speech_controller.dart';
import '../application/dictionary_providers.dart';
import '../domain/dictionary_entry.dart';

class EntryDetailView extends ConsumerWidget {
  const EntryDetailView({required this.entryId, super.key});

  final String entryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(entryProvider(entryId))
        .when(
          data: (entry) => entry == null
              ? const _MissingEntry()
              : _EntryContent(entry: entry),
          loading: () =>
              const Center(child: CircularProgressIndicator.adaptive()),
          error: (error, stackTrace) => const _EntryError(),
        );
  }
}

class _EntryContent extends ConsumerWidget {
  const _EntryContent({required this.entry});

  final DictionaryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryControllerProvider);
    final isFavorite =
        library.asData?.value.favoriteEntryIds.contains(entry.id) ?? false;
    final speech = ref.watch(speechControllerProvider);

    Future<void> speak() async {
      await ref.read(speechControllerProvider.notifier).speak(entry.headword);
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('合成音声を再生しました。')));
      }
    }

    return SelectionArea(
      child: ListView(
        key: Key('entry-${entry.id}'),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
        children: [
          if (entry.isReviewPending) ...[
            Card(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              child: const ListTile(
                dense: true,
                leading: Icon(Icons.science_outlined),
                title: Text('レビュー前のデモ内容'),
                subtitle: Text('公開前に日本語の確認が必要です。'),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.headword,
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${entry.reading}　${entry.partOfSpeechLabel}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
              Semantics(
                button: true,
                label: '${entry.headword}の合成音声を聞く',
                child: IconButton.filledTonal(
                  tooltip: '合成音声を聞く',
                  onPressed: speech.isLoading ? null : speak,
                  icon: speech.isLoading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.volume_up_outlined),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: isFavorite ? 'お気に入りから削除' : 'お気に入りに追加',
                onPressed: () => ref
                    .read(libraryControllerProvider.notifier)
                    .toggleFavorite(entry.id),
                icon: Icon(isFavorite ? Icons.star : Icons.star_outline),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.graphic_eq, size: 16),
              const SizedBox(width: 6),
              Text('合成音声', style: Theme.of(context).textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            entry.primarySense.definition,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 24),
          Text('例文', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final sentence in entry.primarySense.examples.take(2))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Icon(Icons.circle, size: 6),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      sentence,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                ],
              ),
            ),
          if (entry.relations.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('似ている言葉', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final relation in entry.relations)
              Card.outlined(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${relation.headword}　${relation.relation}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      Text(relation.note),
                    ],
                  ),
                ),
              ),
          ],
          const SizedBox(height: 16),
          _SecondaryInformation(entry: entry),
        ],
      ),
    );
  }
}

class _SecondaryInformation extends ConsumerWidget {
  const _SecondaryInformation({required this.entry});

  final DictionaryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.watch(audioControllerProvider);
    return Column(
      children: [
        if (entry.senses.length > 1)
          ExpansionTile(
            title: const Text('ほかの意味'),
            children: [
              for (final sense in entry.senses.skip(1))
                ListTile(
                  title: Text(sense.definition),
                  subtitle: Text(sense.examples.join('\n')),
                ),
            ],
          ),
        if (entry.primarySense.usageNote.isNotEmpty)
          ExpansionTile(
            title: const Text('使い方の注意'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(entry.primarySense.usageNote),
                ),
              ),
            ],
          ),
        if (entry.primarySense.collocations.isNotEmpty)
          ExpansionTile(
            title: const Text('よく使う組み合わせ'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final value in entry.primarySense.collocations)
                        Chip(label: Text(value)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        if (entry.imageAsset != null)
          ExpansionTile(
            title: const Text('画像'),
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Semantics(
                  image: true,
                  label: '${entry.headword}の説明画像',
                  child: _EntryImage(asset: entry.imageAsset!),
                ),
              ),
            ],
          ),
        if (entry.audioAsset != null)
          ExpansionTile(
            title: const Text('音声資料'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    key: const Key('play-audio-asset'),
                    onPressed: audio.isLoading
                        ? null
                        : () => ref
                              .read(audioControllerProvider.notifier)
                              .play(entry.audioAsset!),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('音声を再生'),
                  ),
                ),
              ),
            ],
          ),
        ExpansionTile(
          title: const Text('出典'),
          children: [
            ListTile(
              leading: const Icon(Icons.verified_outlined),
              title: Text(entry.sourceLabel),
              subtitle: const Text('プロトタイプ用に作成した内容'),
            ),
          ],
        ),
      ],
    );
  }
}

class _EntryImage extends StatelessWidget {
  const _EntryImage({required this.asset});

  final String asset;

  @override
  Widget build(BuildContext context) {
    Widget errorBuilder(
      BuildContext context,
      Object error,
      StackTrace? stackTrace,
    ) => const Text('画像を表示できません。');
    if (asset.startsWith('data:image/')) {
      final encoded = asset.substring(asset.indexOf(',') + 1);
      return Image.memory(
        base64Decode(encoded),
        height: 160,
        fit: BoxFit.contain,
        errorBuilder: errorBuilder,
      );
    }
    return Image.asset(
      asset,
      height: 160,
      fit: BoxFit.contain,
      errorBuilder: errorBuilder,
    );
  }
}

class _MissingEntry extends StatelessWidget {
  const _MissingEntry();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('この言葉は見つかりませんでした。'));
}

class _EntryError extends StatelessWidget {
  const _EntryError();

  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('言葉を読み込めませんでした。'));
}
