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
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('端末に合わせる')),
                ButtonSegment(value: ThemeMode.light, label: Text('明るい')),
                ButtonSegment(value: ThemeMode.dark, label: Text('暗い')),
              ],
              selected: {settings.themeMode},
              onSelectionChanged: (values) =>
                  controller.setThemeMode(values.first),
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
            if (kIsWeb)
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.web_asset_off_outlined),
                title: Text('Web版では本機更新を利用できません'),
                subtitle: Text('現在は同梱されたデモ辞書を使います。'),
              )
            else ...[
              TextField(
                key: const Key('release-directory-field'),
                controller: _releaseDirectoryController,
                enabled: !update.isRunning,
                decoration: const InputDecoration(
                  labelText: 'releaseフォルダーのパス',
                  hintText: 'release-manifest.json があるフォルダー',
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
                  icon: update.isRunning
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.system_update_alt),
                  label: const Text('本機パッケージを検証して更新'),
                ),
              ),
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
                'release・reviewed のパッケージだけを受け入れます。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
