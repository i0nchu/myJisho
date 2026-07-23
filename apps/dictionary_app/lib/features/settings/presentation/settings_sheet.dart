import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../update/application/dictionary_update_controller.dart';
import '../application/settings_controller.dart';

Future<void> showSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const _SettingsSheet(),
  );
}

class _SettingsSheet extends ConsumerStatefulWidget {
  const _SettingsSheet();

  @override
  ConsumerState<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<_SettingsSheet> {
  final _releaseDirectoryController = TextEditingController();

  @override
  void dispose() {
    _releaseDirectoryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final update = ref.watch(dictionaryUpdateControllerProvider);

    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [
            Text('設定', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 20),
            Text('表示', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final textScale = MediaQuery.textScalerOf(context).scale(1);
                final useVerticalSegments =
                    constraints.maxWidth < 480 || textScale >= 1.5;
                return SegmentedButton<ThemeMode>(
                  key: const Key('theme-mode-segmented-control'),
                  direction: useVerticalSegments
                      ? Axis.vertical
                      : Axis.horizontal,
                  segments: const [
                    ButtonSegment(
                      value: ThemeMode.system,
                      label: Text('端末に合わせる'),
                    ),
                    ButtonSegment(value: ThemeMode.light, label: Text('明るい')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('暗い')),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (values) =>
                      controller.setThemeMode(values.first),
                );
              },
            ),
            const SizedBox(height: 20),
            Text('文字の大きさ：${(settings.fontScale * 100).round()}%'),
            Slider(
              value: settings.fontScale,
              min: 0.9,
              max: 1.4,
              divisions: 5,
              label: '${(settings.fontScale * 100).round()}%',
              onChanged: controller.setFontScale,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('キーボードショートカット'),
              subtitle: const Text('/、Ctrl+L、矢印、Enter、Esc、Ctrl+D、Space'),
              value: settings.shortcutsEnabled,
              onChanged: controller.setShortcutsEnabled,
            ),
            const Divider(height: 32),
            Text('辞書データ', style: Theme.of(context).textTheme.titleMedium),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.offline_bolt_outlined),
              title: Text(update.currentVersion ?? '確認中'),
              subtitle: const Text('端末に保存済み・オフラインで利用できます'),
            ),
            if (update.phase == DictionaryUpdatePhase.unsupported)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.sync_disabled_outlined),
                title: const Text('このプラットフォームでは更新できません'),
                subtitle: Text(update.message),
              )
            else ...[
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const Key('check-remote-dictionary-update'),
                    onPressed: update.isRunning || !update.remoteConfigured
                        ? null
                        : () => ref
                              .read(dictionaryUpdateControllerProvider.notifier)
                              .checkForRemoteUpdate(),
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('更新を確認してインストール'),
                  ),
                  if (update.canCancel)
                    OutlinedButton.icon(
                      key: const Key('cancel-dictionary-update'),
                      onPressed: () => ref
                          .read(dictionaryUpdateControllerProvider.notifier)
                          .cancel(),
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('キャンセル'),
                    ),
                ],
              ),
              if (update.isRunning) ...[
                const SizedBox(height: 12),
                Semantics(
                  label: '辞書更新の進捗',
                  value: update.progress == null
                      ? '処理中'
                      : '${(update.progress! * 100).round()}%',
                  child: LinearProgressIndicator(value: update.progress),
                ),
              ],
              const SizedBox(height: 10),
              Text(
                update.message,
                key: const Key('dictionary-update-status'),
                style: TextStyle(
                  color: update.phase == DictionaryUpdatePhase.failed
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'HTTPSから完全なrelease・reviewed・license-clearedパッケージ'
                'だけを受け入れます。失敗時は以前の辞書を維持します。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (kDebugMode) ...[
                const Divider(height: 28),
                Text(
                  'リリース担当者向け（デバッグ専用）',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('release-directory-field'),
                  controller: _releaseDirectoryController,
                  enabled: !update.isRunning,
                  decoration: const InputDecoration(
                    labelText: '完全パッケージのフォルダー',
                    hintText: '4つのリリースファイルがあるフォルダー',
                    prefixIcon: Icon(Icons.folder_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonalIcon(
                    key: const Key('install-local-release'),
                    onPressed: update.isRunning
                        ? null
                        : () => ref
                              .read(dictionaryUpdateControllerProvider.notifier)
                              .installFromDirectory(
                                _releaseDirectoryController.text,
                              ),
                    icon: const Icon(Icons.system_update_alt),
                    label: const Text('本機完全パッケージを検証'),
                  ),
                ),
              ],
            ],
            const Divider(height: 32),
            ListTile(
              key: const Key('open-source-licenses'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined),
              title: const Text('オープンソースライセンス'),
              subtitle: const Text('使用しているパッケージの著作権とライセンス'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'ことば',
                applicationVersion: '0.1.0',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
