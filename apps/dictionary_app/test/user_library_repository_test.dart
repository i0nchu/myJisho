import 'package:flutter_test/flutter_test.dart';
import 'package:myjisho_dictionary_app/features/library/data/user_library_repository.dart';
import 'package:myjisho_dictionary_app/features/settings/data/settings_repository.dart';
import 'package:myjisho_dictionary_app/features/settings/domain/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps favorites independent from history changes', () async {
    final repository = InMemoryUserLibraryRepository();
    await repository.toggleFavorite('entry_001');
    await repository.addHistory('拾う');
    await repository.clearHistory();

    final value = await repository.load();
    expect(value.favoriteEntryIds, {'entry_001'});
    expect(value.history, isEmpty);
  });

  test('deduplicates recent queries and puts newest first', () async {
    final repository = InMemoryUserLibraryRepository();
    await repository.addHistory('見る');
    await repository.addHistory('拾う');
    await repository.addHistory('見る');

    final value = await repository.load();
    expect(value.history.map((item) => item.query), ['見る', '拾う']);
  });

  test('persistent adapter survives repository recreation', () async {
    SharedPreferences.setMockInitialValues({});
    final first = SharedPreferencesUserLibraryRepository();
    await first.toggleFavorite('entry_001');
    await first.addHistory('拾う');

    final restored = await SharedPreferencesUserLibraryRepository().load();
    expect(restored.favoriteEntryIds, {'entry_001'});
    expect(restored.history.single.query, '拾う');
  });

  test('display settings survive repository recreation', () async {
    SharedPreferences.setMockInitialValues({});
    final first = SharedPreferencesSettingsRepository();
    await first.save(
      const AppSettings(
        themeMode: ThemeMode.dark,
        fontScale: 1.3,
        shortcutsEnabled: false,
      ),
    );

    final restored = await SharedPreferencesSettingsRepository().load();
    expect(restored.themeMode, ThemeMode.dark);
    expect(restored.fontScale, 1.3);
    expect(restored.shortcutsEnabled, isFalse);
  });
}
