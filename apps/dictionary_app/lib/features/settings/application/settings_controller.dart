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
    if (_sameSettings(next, state)) return;
    state = next;
    unawaited(ref.read(settingsRepositoryProvider).save(next));
  }

  void setThemeMode(ThemeMode value) =>
      _persist(state.copyWith(themeMode: value));
  void previewFontScale(double value) {
    final next = state.copyWith(fontScale: value);
    if (_sameSettings(next, state)) return;
    state = next;
  }

  void commitFontScale(double value) {
    final next = state.copyWith(fontScale: value);
    state = next;
    unawaited(ref.read(settingsRepositoryProvider).save(next));
  }

  void setShortcutsEnabled(bool value) =>
      _persist(state.copyWith(shortcutsEnabled: value));

  bool _sameSettings(AppSettings left, AppSettings right) {
    return left.themeMode == right.themeMode &&
        left.fontScale == right.fontScale &&
        left.shortcutsEnabled == right.shortcutsEnabled;
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SharedPreferencesSettingsRepository();
});

final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);
