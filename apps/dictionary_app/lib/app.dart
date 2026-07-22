import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/dictionary/presentation/dictionary_screen.dart';
import 'features/settings/application/settings_controller.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const DictionaryScreen()),
      GoRoute(
        path: '/entry/:entryId',
        builder: (context, state) =>
            DictionaryScreen(selectedEntryId: state.pathParameters['entryId']),
      ),
    ],
  );
});

class KotobaApp extends ConsumerWidget {
  const KotobaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final router = ref.watch(routerProvider);

    ThemeData buildTheme(Brightness brightness) {
      final base = ThemeData(
        brightness: brightness,
        colorSchemeSeed: const Color(0xff315c49),
        useMaterial3: true,
      );
      return base.copyWith(
        textTheme: base.textTheme.apply(fontSizeFactor: settings.fontScale),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
        ),
        cardTheme: const CardThemeData(margin: EdgeInsets.zero),
      );
    }

    return MaterialApp.router(
      title: 'ことば',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: settings.themeMode,
      routerConfig: router,
    );
  }
}
