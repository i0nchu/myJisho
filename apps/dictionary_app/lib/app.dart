import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/dictionary/presentation/dictionary_screen.dart';
import 'features/settings/application/settings_controller.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => CustomTransitionPage<void>(
          key: state.pageKey,
          transitionsBuilder: buildKotobaPageTransition,
          transitionDuration: const Duration(milliseconds: 180),
          reverseTransitionDuration: const Duration(milliseconds: 140),
          child: const DictionaryScreen(),
        ),
      ),
      GoRoute(
        path: '/entry/:entryId',
        pageBuilder: (context, state) => CustomTransitionPage<void>(
          key: state.pageKey,
          transitionsBuilder: buildKotobaPageTransition,
          transitionDuration: const Duration(milliseconds: 180),
          reverseTransitionDuration: const Duration(milliseconds: 140),
          child: DictionaryScreen(
            selectedEntryId: state.pathParameters['entryId'],
          ),
        ),
      ),
    ],
  );
});

ThemeData buildKotobaTheme(Brightness brightness, {double fontScale = 1}) {
  final base = ThemeData(
    brightness: brightness,
    colorSchemeSeed: const Color(0xff315c49),
    useMaterial3: true,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontSizeFactor: fontScale),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      filled: true,
    ),
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
  );
}

Widget buildKotobaPageTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final media = MediaQuery.maybeOf(context);
  final platformFeatures = View.maybeOf(
    context,
  )?.platformDispatcher.accessibilityFeatures;
  final reduceMotion =
      media?.disableAnimations == true ||
      media?.accessibleNavigation == true ||
      platformFeatures?.reduceMotion == true;
  if (reduceMotion) return child;
  return FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
    child: child,
  );
}

class KotobaApp extends ConsumerWidget {
  const KotobaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'ことば',
      debugShowCheckedModeBanner: false,
      theme: buildKotobaTheme(Brightness.light, fontScale: settings.fontScale),
      darkTheme: buildKotobaTheme(
        Brightness.dark,
        fontScale: settings.fontScale,
      ),
      themeMode: settings.themeMode,
      routerConfig: router,
    );
  }
}
