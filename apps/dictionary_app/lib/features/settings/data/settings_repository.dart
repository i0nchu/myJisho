import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/app_settings.dart';

abstract interface class SettingsRepository {
  Future<AppSettings> load();
  Future<void> save(AppSettings value);
}

class SharedPreferencesSettingsRepository implements SettingsRepository {
  SharedPreferencesSettingsRepository([Future<SharedPreferences>? preferences])
    : _preferences = preferences ?? SharedPreferences.getInstance();

  static const _themeKey = 'kotoba.settings.theme.v1';
  static const _fontScaleKey = 'kotoba.settings.font_scale.v1';
  static const _shortcutsKey = 'kotoba.settings.shortcuts.v1';

  final Future<SharedPreferences> _preferences;

  @override
  Future<AppSettings> load() async {
    final preferences = await _preferences;
    final themeName = preferences.getString(_themeKey);
    final theme = ThemeMode.values.where((value) => value.name == themeName);
    return AppSettings(
      themeMode: theme.isEmpty ? ThemeMode.system : theme.first,
      fontScale: (preferences.getDouble(_fontScaleKey) ?? 1)
          .clamp(0.9, 1.4)
          .toDouble(),
      shortcutsEnabled: preferences.getBool(_shortcutsKey) ?? true,
    );
  }

  @override
  Future<void> save(AppSettings value) async {
    final preferences = await _preferences;
    await Future.wait([
      preferences.setString(_themeKey, value.themeMode.name),
      preferences.setDouble(_fontScaleKey, value.fontScale),
      preferences.setBool(_shortcutsKey, value.shortcutsEnabled),
    ]);
  }
}

class InMemorySettingsRepository implements SettingsRepository {
  AppSettings value = const AppSettings();

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings value) async => this.value = value;
}
