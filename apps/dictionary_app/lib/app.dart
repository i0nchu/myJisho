import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/dictionary/presentation/dictionary_screen.dart';
import 'features/settings/application/settings_controller.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    routes: [
      ShellRoute(
        builder: (context, state, mobileNavigator) {
          final entryId =
              state.pathParameters['entryId'] ??
              _entryIdFromLocation(state.uri);
          return LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 840) {
                return DictionaryScreen(
                  layoutMode: DictionaryLayoutMode.desktop,
                  selectedEntryId: entryId,
                );
              }
              return mobileNavigator;
            },
          );
        },
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (context, state) => _platformPage(
              state: state,
              child: const DictionaryScreen(
                layoutMode: DictionaryLayoutMode.mobile,
              ),
            ),
            routes: [
              GoRoute(
                path: 'entry/:entryId',
                pageBuilder: (context, state) => _platformPage(
                  state: state,
                  isDetail: true,
                  child: MobileEntryScreen(
                    entryId: state.pathParameters['entryId']!,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

String? _entryIdFromLocation(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length == 2 && segments.first == 'entry') {
    return segments.last;
  }
  return null;
}

Page<void> _platformPage({
  required GoRouterState state,
  required Widget child,
  bool isDetail = false,
}) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return CupertinoPage<void>(
      key: state.pageKey,
      title: isDetail ? '言葉' : 'ことば',
      child: child,
    );
  }
  if (!isDetail) {
    return NoTransitionPage<void>(key: state.pageKey, child: child);
  }
  return CustomTransitionPage<void>(
    key: state.pageKey,
    transitionsBuilder: buildMyJishoPageTransition,
    transitionDuration: const Duration(milliseconds: 150),
    reverseTransitionDuration: const Duration(milliseconds: 120),
    child: child,
  );
}

ThemeData buildMyJishoTheme(Brightness brightness, {double fontScale = 1}) {
  assert(fontScale > 0);
  final base = ThemeData(
    brightness: brightness,
    colorSchemeSeed: const Color(0xff315c49),
    platform: defaultTargetPlatform,
    useMaterial3: true,
  );
  final isDesktop =
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;
  return base.copyWith(
    visualDensity: isDesktop ? VisualDensity.compact : VisualDensity.standard,
    splashFactory: defaultTargetPlatform == TargetPlatform.iOS || isDesktop
        ? NoSplash.splashFactory
        : null,
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: base.colorScheme.primary,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      filled: true,
    ),
    cardTheme: const CardThemeData(margin: EdgeInsets.zero),
  );
}

Widget buildMyJishoPageTransition(
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

class MyJishoApp extends ConsumerWidget {
  const MyJishoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(
      settingsControllerProvider.select(
        (value) => (value.themeMode, value.fontScale),
      ),
    );
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'ことば',
      debugShowCheckedModeBanner: false,
      theme: buildMyJishoTheme(Brightness.light, fontScale: appearance.$2),
      darkTheme: buildMyJishoTheme(Brightness.dark, fontScale: appearance.$2),
      themeMode: appearance.$1,
      routerConfig: router,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final effectiveScale = media.textScaler.scale(1) * appearance.$2;
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(effectiveScale)),
          child: child!,
        );
      },
    );
  }
}
