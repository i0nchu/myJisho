import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/application/library_controller.dart';
import '../../media/application/audio_controller.dart';
import '../../pronunciation/application/speech_controller.dart';
import '../application/dictionary_providers.dart';
import '../data/dictionary_repository.dart';
import '../data/local_dictionary_client.dart';
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

class _EntryContent extends StatelessWidget {
  const _EntryContent({required this.entry});

  final DictionaryEntry entry;

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: ListView(
        key: Key('entry-${entry.id}'),
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
        children: [
          _EntryStatusNotices(entry: entry),
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
              _EntryActions(entry: entry),
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
                        '${relation.headword}　${relation.displayRelationLabel}',
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

class _EntryStatusNotices extends StatelessWidget {
  const _EntryStatusNotices({required this.entry});

  final DictionaryEntry entry;

  @override
  Widget build(BuildContext context) {
    final notices = <(IconData, String)>[
      if (entry.isStale) (Icons.update_outlined, 'この詞条は生成バージョンが古くなっています。'),
      if (entry.isKnowledgeOnly)
        (Icons.info_outline, '利用できる出典がなく、主にモデルの既有知識から生成されました。'),
      if (entry.hasLowSourceWarning)
        (Icons.info_outline, '利用できる出典が少ないため、内容を慎重に確認してください。'),
    ];
    if (notices.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            children: [
              for (final notice in notices)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(notice.$1, size: 17),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          notice.$2,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryActions extends ConsumerWidget {
  const _EntryActions({required this.entry});

  final DictionaryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFavorite = ref.watch(
      libraryControllerProvider.select(
        (library) =>
            library.asData?.value.favoriteEntryIds.contains(entry.id) ?? false,
      ),
    );
    final speechIsLoading = ref.watch(
      speechControllerProvider.select((speech) => speech.isLoading),
    );

    Future<void> speak() async {
      try {
        await ref.read(speechControllerProvider.notifier).speak(entry.reading);
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(const SnackBar(content: Text('日本語の合成音声を再生しました。')));
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text(speechFailureMessage(error))));
        }
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          key: const Key('tts-button'),
          tooltip: '${entry.headword}の合成音声を聞く',
          onPressed: speechIsLoading ? null : speak,
          icon: speechIsLoading
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.volume_up_outlined),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          key: const Key('favorite-button'),
          tooltip: isFavorite ? 'お気に入りから削除' : 'お気に入りに追加',
          onPressed: () => ref
              .read(libraryControllerProvider.notifier)
              .toggleFavorite(entry.id),
          icon: Icon(isFavorite ? Icons.star : Icons.star_outline),
        ),
        if (entry.isGeneratedLocally) ...[
          const SizedBox(width: 4),
          PopupMenuButton<_EntryCommand>(
            key: const Key('local-entry-menu'),
            tooltip: 'ローカル詞条を管理',
            onSelected: (command) =>
                _runEntryCommand(context, ref, entry, command),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _EntryCommand.edit,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.edit_outlined),
                  title: Text('編集'),
                ),
              ),
              const PopupMenuItem(
                value: _EntryCommand.revisions,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.history),
                  title: Text('バージョン履歴'),
                ),
              ),
              PopupMenuItem(
                value: _EntryCommand.regenerate,
                enabled: !entry.locked,
                child: const ListTile(
                  dense: true,
                  leading: Icon(Icons.auto_awesome_outlined),
                  title: Text('再生成'),
                ),
              ),
              PopupMenuItem(
                value: _EntryCommand.lock,
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    entry.locked ? Icons.lock_open : Icons.lock_outline,
                  ),
                  title: Text(entry.locked ? 'ロックを解除' : '現在版をロック'),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: _EntryCommand.delete,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.delete_outline),
                  title: Text('削除'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

enum _EntryCommand { edit, revisions, regenerate, lock, delete }

Future<void> _runEntryCommand(
  BuildContext context,
  WidgetRef ref,
  DictionaryEntry entry,
  _EntryCommand command,
) async {
  final repository = ref.read(dictionaryRepositoryProvider);
  if (repository is! DictionaryEntryManagementRepository) return;
  final manager = repository as DictionaryEntryManagementRepository;
  try {
    switch (command) {
      case _EntryCommand.edit:
        final patch = await _showEditDialog(context, entry);
        if (patch == null) return;
        await manager.editEntry(entry.id, patch);
        break;
      case _EntryCommand.revisions:
        final revisions = await manager.listRevisions(entry.id);
        if (!context.mounted) return;
        final revision = await _showRevisionDialog(
          context,
          manager,
          entry.id,
          revisions,
        );
        if (revision == null) return;
        await manager.restoreRevision(entry.id, revision);
        break;
      case _EntryCommand.regenerate:
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('詞条を再生成しています。')));
        await manager.regenerate(entry.id);
        break;
      case _EntryCommand.lock:
        await manager.setLocked(entry.id, !entry.locked);
        break;
      case _EntryCommand.delete:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('詞条を削除しますか'),
            content: Text('「${entry.headword}」をローカル辞書から削除します。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('削除'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        await manager.deleteEntry(entry.id);
        break;
    }
    ref.invalidate(entryProvider(entry.id));
    ref.invalidate(allEntriesProvider);
    ref.invalidate(searchResultsProvider);
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('ローカル詞条を更新しました。')));
    }
  } on Object catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text('操作に失敗しました：$error')));
  }
}

Future<Map<String, Object?>?> _showEditDialog(
  BuildContext context,
  DictionaryEntry entry,
) async {
  final headword = TextEditingController(text: entry.headword);
  final reading = TextEditingController(text: entry.reading);
  final partsOfSpeech = TextEditingController(
    text: entry.partsOfSpeech.join(', '),
  );
  final definition = TextEditingController(text: entry.primarySense.definition);
  final usageNote = TextEditingController(text: entry.primarySense.usageNote);
  try {
    return await showDialog<Map<String, Object?>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('詞条を編集'),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: headword,
                  decoration: const InputDecoration(labelText: '見出し'),
                ),
                TextField(
                  controller: reading,
                  decoration: const InputDecoration(labelText: '読み'),
                ),
                TextField(
                  controller: partsOfSpeech,
                  decoration: const InputDecoration(labelText: '品詞（カンマ区切り）'),
                ),
                TextField(
                  controller: definition,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: '意味'),
                ),
                TextField(
                  controller: usageNote,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '使い方の注意'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'headword': headword.text.trim(),
              'reading': reading.text.trim(),
              'parts_of_speech': partsOfSpeech.text
                  .split(',')
                  .map((value) => value.trim())
                  .where((value) => value.isNotEmpty)
                  .toList(growable: false),
              'definition_ja_simple': definition.text.trim(),
              'usage_note_ja': usageNote.text.trim(),
            }),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  } finally {
    headword.dispose();
    reading.dispose();
    partsOfSpeech.dispose();
    definition.dispose();
    usageNote.dispose();
  }
}

Future<int?> _showRevisionDialog(
  BuildContext context,
  DictionaryEntryManagementRepository manager,
  String entryId,
  List<LocalDictionaryRevision> revisions,
) {
  return showDialog<int>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('バージョン履歴'),
      content: SizedBox(
        width: 480,
        child: revisions.isEmpty
            ? const Text('履歴はありません。')
            : ListView.separated(
                shrinkWrap: true,
                itemCount: revisions.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final revision = revisions[index];
                  return ListTile(
                    onTap: () async {
                      final historical = await manager.getRevision(
                        entryId,
                        revision.revision,
                      );
                      if (!context.mounted) return;
                      final restore = await _showRevisionPreview(
                        context,
                        revision.revision,
                        historical,
                      );
                      if (restore == true && context.mounted) {
                        Navigator.pop(context, revision.revision);
                      }
                    },
                    title: Text(
                      'Revision ${revision.revision}・'
                      '${_versionOriginLabel(revision.origin)}',
                    ),
                    subtitle: Text(
                      '${_formatDateTime(revision.createdAt)}\n'
                      '${revision.model}・出典 ${revision.sourceCount} 件',
                    ),
                    isThreeLine: true,
                    trailing: FilledButton.tonal(
                      onPressed: () =>
                          Navigator.pop(context, revision.revision),
                      child: const Text('復元'),
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('閉じる'),
        ),
      ],
    ),
  );
}

Future<bool?> _showRevisionPreview(
  BuildContext context,
  int revision,
  DictionaryEntry entry,
) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Revision $revision'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                entry.headword,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text('${entry.reading}　${entry.partOfSpeechLabel}'),
              const SizedBox(height: 16),
              Text(entry.primarySense.definition),
              if (entry.primarySense.examples.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final example in entry.primarySense.examples)
                  Text('・$example'),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('戻る'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('この版を復元'),
        ),
      ],
    ),
  );
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
        if (entry.generationInfo case final generation?)
          ExpansionTile(
            title: const Text('出典'),
            children: generation.sources.isEmpty
                ? [
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: Text(
                        (generation.retrievedSourceCount ?? 0) > 0
                            ? 'ウェブ資料は引用されませんでした'
                            : '参照できるウェブ資料はありません',
                      ),
                      subtitle: Text(
                        (generation.retrievedSourceCount ?? 0) > 0
                            ? '${generation.retrievedSourceCount} 件を取得しましたが、'
                                  'この語義の根拠として採用されていません。'
                            : 'モデルの既有知識を主に使用しています。',
                      ),
                    ),
                  ]
                : [
                    for (final source in generation.sources)
                      ListTile(
                        leading: const Icon(Icons.link),
                        title: Text(source.title),
                        subtitle: Text(
                          '${source.url}\n${source.licenseSpdx}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
          )
        else
          ExpansionTile(
            title: const Text('出典'),
            children: [
              ListTile(
                leading: const Icon(Icons.verified_outlined),
                title: Text(entry.sourceLabel),
                subtitle: const Text('myJisho 内蔵辞書'),
              ),
            ],
          ),
        if (entry.generationInfo case final generation?)
          ExpansionTile(
            key: const Key('generation-information'),
            title: const Text('生成情報'),
            children: [
              ListTile(
                dense: true,
                title: const Text('モデル'),
                subtitle: Text(generation.model),
              ),
              ListTile(
                dense: true,
                title: const Text('生成日時'),
                subtitle: Text(_formatDateTime(generation.generatedAt)),
              ),
              ListTile(
                dense: true,
                title: const Text('情報源'),
                subtitle: Text(
                  generation.retrievedSourceCount == null
                      ? '${generation.sourceCount} 件'
                      : '${generation.sourceCount} 件引用'
                            '（${generation.retrievedSourceCount} 件取得）',
                ),
              ),
              ListTile(
                dense: true,
                title: const Text('バージョン'),
                subtitle: Text(
                  '${_versionOriginLabel(entry.versionOrigin)}'
                  '・${generation.generatorVersion}',
                ),
                trailing: entry.locked
                    ? const Tooltip(
                        message: '現在のバージョンはロックされています',
                        child: Icon(Icons.lock_outline),
                      )
                    : null,
              ),
            ],
          ),
      ],
    );
  }
}

String _formatDateTime(DateTime? value) {
  if (value == null) return '不明';
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _versionOriginLabel(String value) => switch (value) {
  'generated' => '初回生成',
  'edited' => 'ユーザー編集',
  'regenerated' => '再生成',
  _ => '内蔵データ',
};

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
