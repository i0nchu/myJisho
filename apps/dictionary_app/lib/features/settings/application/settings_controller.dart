import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_repository.dart';
import '../domain/app_settings.dart';

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    unawaited(_hydrate());
    return const AppSettings();
  }

  Future<void> _hydrate() async {
    state = await ref.read(settingsRepositoryProvider).load();
  }

  void _persist(AppSettings next) {
    state = next;
    unawaited(ref.read(settingsRepositoryProvider).save(next));
  }

  void setThemeMode(ThemeMode value) =>
      _persist(state.copyWith(themeMode: value));
  void setFontScale(double value) => _persist(state.copyWith(fontScale: value));
  void setShortcutsEnabled(bool value) =>
      _persist(state.copyWith(shortcutsEnabled: value));
}

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SharedPreferencesSettingsRepository();
});

final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
