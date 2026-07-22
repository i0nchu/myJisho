import 'package:flutter/material.dart';

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.fontScale = 1,
    this.shortcutsEnabled = true,
  });

  final ThemeMode themeMode;
  final double fontScale;
  final bool shortcutsEnabled;

  AppSettings copyWith({
    ThemeMode? themeMode,
    double? fontScale,
    bool? shortcutsEnabled,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      fontScale: fontScale ?? this.fontScale,
      shortcutsEnabled: shortcutsEnabled ?? this.shortcutsEnabled,
    );
  }
}
