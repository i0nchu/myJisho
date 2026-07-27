import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotoba_dictionary_app/app.dart';
import 'package:kotoba_dictionary_app/features/dictionary/application/dictionary_providers.dart';
import 'package:kotoba_dictionary_app/features/dictionary/data/fixture_dictionary_repository.dart';
import 'package:kotoba_dictionary_app/features/dictionary/domain/dictionary_entry.dart';
import 'package:kotoba_dictionary_app/features/library/application/library_controller.dart';
import 'package:kotoba_dictionary_app/features/library/data/user_library_repository.dart';
import 'package:kotoba_dictionary_app/features/media/application/audio_controller.dart';
import 'package:kotoba_dictionary_app/features/media/data/audio_playback_service.dart';
import 'package:kotoba_dictionary_app/features/pronunciation/application/speech_controller.dart';
import 'package:kotoba_dictionary_app/features/pronunciation/data/speech_service.dart';
import 'package:kotoba_dictionary_app/features/settings/application/settings_controller.dart';
import 'package:kotoba_dictionary_app/features/settings/data/settings_repository.dart';
import 'package:kotoba_dictionary_app/features/settings/domain/app_settings.dart';
import 'package:kotoba_dictionary_app/features/update/application/dictionary_update_controller.dart';

import 'test_data.dart';

void main() {
  group('AC-08 adaptive layout', () {
    testWidgets('390 px primary flows have no horizontal overflow', (
      tester,
    ) async {
      _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mobile-layout')), findsOneWidget);
      _expectNoRenderException(tester);

      await _searchFor(tester, '食べる');
      await tester.tap(find.byKey(const Key('result-entry_taberu_001')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('entry-entry_taberu_001')), findsOneWidget);
      _expectNoRenderException(tester);

      await tester.tap(find.byTooltip('戻る'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-button')));
      await tester.pumpAndSettle();

      final themeSelector = tester.widget<SegmentedButton<ThemeMode>>(
        find.byKey(const Key('theme-mode-segmented-control')),
      );
      expect(themeSelector.direction, Axis.vertical);
      _expectNoRenderException(tester);
    });

    testWidgets('wide desktop keeps result and detail panes together', (
      tester,
    ) async {
      _setViewport(tester, const Size(1200, 800));
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();
      await _searchFor(tester, '食べる');
      await tester.tap(find.byKey(const Key('result-entry_taberu_001')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('desktop-layout')), findsOneWidget);
      expect(find.byKey(const Key('desktop-primary-pane')), findsOneWidget);
      expect(find.byKey(const Key('desktop-detail-pane')), findsOneWidget);
      expect(find.byKey(const Key('search-results')), findsOneWidget);
      expect(find.byKey(const Key('entry-entry_taberu_001')), findsOneWidget);

      final primaryRect = tester.getRect(
        find.byKey(const Key('desktop-primary-pane')),
      );
      final detailRect = tester.getRect(
        find.byKey(const Key('desktop-detail-pane')),
      );
      expect(primaryRect.right, lessThanOrEqualTo(detailRect.left));
      _expectNoRenderException(tester);
    });

    testWidgets('keyboard search opens a selected result', (tester) async {
      _setViewport(tester, const Size(1200, 800));
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();

      final editable = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('search-field')),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.focusNode.hasFocus, isTrue);

      await tester.enterText(find.byKey(const Key('search-field')), '拾');
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('entry-entry_hirou_001')), findsOneWidget);
      _expectNoRenderException(tester);
    });

    testWidgets('Space is input-safe and disabled shortcuts stay disabled', (
      tester,
    ) async {
      _setViewport(tester, const Size(1200, 800));
      final speech = DemoSpeechService();
      await tester.pumpWidget(_testApp(speechService: speech));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(speech.lastSpokenText, isNull);

      await _searchFor(tester, '食べる');
      await tester.tap(find.byKey(const Key('result-entry_taberu_001')));
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(speech.lastSpokenText, 'たべる');
      expect(find.text('日本語の合成音声を再生しました。'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        _testApp(settings: const AppSettings(shortcutsEnabled: false)),
      );
      await tester.pumpAndSettle();
      await _searchFor(tester, '食べる');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('entry-entry_taberu_001')), findsNothing);
    });

    testWidgets(
      'Space reports a missing Japanese voice without false success',
      (tester) async {
        _setViewport(tester, const Size(1200, 800));
        await tester.pumpWidget(
          _testApp(speechService: const _UnavailableSpeechService()),
        );
        await tester.pumpAndSettle();
        await _searchFor(tester, '食べる');
        await tester.tap(find.byKey(const Key('result-entry_taberu_001')));
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();

        expect(find.textContaining('日本語のシステム音声が見つかりません'), findsOneWidget);
        expect(find.text('日本語の合成音声を再生しました。'), findsNothing);
      },
    );
  });

  group('AC-09 accessibility and appearance', () {
    testWidgets('200% text remains operable at 390 px', (tester) async {
      _setViewport(tester, const Size(390, 844));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();
      await _searchFor(tester, '食べる');
      await tester.tap(find.byKey(const Key('result-entry_taberu_001')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tts-button')), findsOneWidget);
      expect(find.byKey(const Key('favorite-button')), findsOneWidget);
      _expectNoRenderException(tester);

      await tester.tap(find.byTooltip('戻る'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-button')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('暗い'));
      await tester.tap(find.text('暗い'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(
          tester.element(find.byKey(const Key('theme-mode-segmented-control'))),
        ).brightness,
        Brightness.dark,
      );
      _expectNoRenderException(tester);
    });

    testWidgets('interactive controls are labeled and keyboard focusable', (
      tester,
    ) async {
      _setViewport(tester, const Size(390, 844));
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_testApp(entries: [testEntry()]));
      await tester.pumpAndSettle();

      final searchData = tester
          .getSemantics(
            find.descendant(
              of: find.byKey(const Key('search-field')),
              matching: find.byType(EditableText),
            ),
          )
          .getSemanticsData();
      expect(searchData.label, contains('言葉を検索'));
      expect(searchData.flagsCollection.isTextField, isTrue);
      expect(searchData.flagsCollection.isFocused, isNot(ui.Tristate.none));

      final settingsData = tester
          .getSemantics(find.byKey(const Key('settings-button')))
          .getSemanticsData();
      expect(_accessibleName(settingsData), contains('設定'));
      expect(settingsData.hasAction(ui.SemanticsAction.tap), isTrue);
      expect(settingsData.flagsCollection.isFocused, isNot(ui.Tristate.none));

      await _searchFor(tester, '食べる');
      final resultData = tester
          .getSemantics(find.byKey(const Key('result-entry_taberu_001')))
          .getSemanticsData();
      expect(resultData.label, contains('食べる'));
      expect(resultData.hasAction(ui.SemanticsAction.tap), isTrue);
      expect(resultData.flagsCollection.isFocused, isNot(ui.Tristate.none));

      await tester.tap(find.byKey(const Key('result-entry_taberu_001')));
      await tester.pumpAndSettle();
      final speechData = tester
          .getSemantics(find.byKey(const Key('tts-button')))
          .getSemanticsData();
      expect(_accessibleName(speechData), contains('食べるの合成音声を聞く'));
      expect(speechData.hasAction(ui.SemanticsAction.tap), isTrue);
      expect(speechData.flagsCollection.isFocused, isNot(ui.Tristate.none));

      final favoriteData = tester
          .getSemantics(find.byKey(const Key('favorite-button')))
          .getSemanticsData();
      expect(_accessibleName(favoriteData), contains('お気に入りに追加'));
      expect(favoriteData.hasAction(ui.SemanticsAction.tap), isTrue);
      expect(favoriteData.flagsCollection.isFocused, isNot(ui.Tristate.none));
      semantics.dispose();
    });

    testWidgets('normal entries do not show a review warning', (tester) async {
      _setViewport(tester, const Size(390, 844));
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_testApp(entries: [testEntry()]));
      await tester.pumpAndSettle();
      await _searchFor(tester, '食べる');
      await tester.tap(find.byKey(const Key('result-entry_taberu_001')));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.science_outlined), findsNothing);
      expect(find.text('レビュー前のデモ内容'), findsNothing);
      expect(find.byKey(const Key('review-status-banner')), findsNothing);
      semantics.dispose();
    });

    testWidgets('framework accessibility guidelines pass for primary flow', (
      tester,
    ) async {
      _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();

      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    });

    testWidgets('settings exposes bundled open-source notices', (tester) async {
      _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(_testApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-button')));
      await tester.pumpAndSettle();

      final licenses = find.byKey(const Key('open-source-licenses'));
      await tester.ensureVisible(licenses);
      await tester.tap(licenses);
      await tester.pumpAndSettle();

      expect(find.byType(LicensePage), findsOneWidget);
      expect(find.text('ことば'), findsWidgets);
      _expectNoRenderException(tester);
    });

    testWidgets('reduced-motion settings bypass custom route fades', (
      tester,
    ) async {
      const child = SizedBox(key: Key('transition-child'));
      final animation = AlwaysStoppedAnimation<double>(0.25);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) =>
                buildKotobaPageTransition(context, animation, animation, child),
          ),
        ),
      );
      expect(find.byType(FadeTransition), findsNothing);
      expect(find.byKey(const Key('transition-child')), findsOneWidget);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(accessibleNavigation: true),
          child: Builder(
            builder: (context) =>
                buildKotobaPageTransition(context, animation, animation, child),
          ),
        ),
      );
      expect(find.byType(FadeTransition), findsNothing);

      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Builder(
            builder: (context) =>
                buildKotobaPageTransition(context, animation, animation, child),
          ),
        ),
      );
      expect(find.byType(FadeTransition), findsNothing);
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Builder(
            builder: (context) =>
                buildKotobaPageTransition(context, animation, animation, child),
          ),
        ),
      );
      expect(find.byType(FadeTransition), findsOneWidget);
    });

    test('light and dark core text color pairs meet 4.5:1', () {
      for (final brightness in Brightness.values) {
        final scheme = buildKotobaTheme(brightness).colorScheme;
        final pairs = <(Color, Color)>[
          (scheme.onSurface, scheme.surface),
          (scheme.onPrimary, scheme.primary),
          (scheme.onSecondaryContainer, scheme.secondaryContainer),
          (scheme.onTertiaryContainer, scheme.tertiaryContainer),
          (scheme.onError, scheme.error),
        ];
        for (final pair in pairs) {
          expect(
            _contrastRatio(pair.$1, pair.$2),
            greaterThanOrEqualTo(4.5),
            reason:
                '${brightness.name}: ${pair.$1} on ${pair.$2} '
                'must meet normal-text contrast',
          );
        }
      }
    });
  });
}

Widget _testApp({
  List<DictionaryEntry>? entries,
  SpeechService? speechService,
  AppSettings settings = const AppSettings(),
}) {
  final repository = FixtureDictionaryRepository.fromEntries(
    entries ??
        [
          testEntry(),
          testEntry(id: 'entry_hirou_001', headword: '拾う', reading: 'ひろう'),
        ],
  );
  final settingsRepository = InMemorySettingsRepository()..value = settings;
  return ProviderScope(
    overrides: [
      dictionaryRepositoryProvider.overrideWithValue(repository),
      userLibraryRepositoryProvider.overrideWithValue(
        InMemoryUserLibraryRepository(),
      ),
      settingsRepositoryProvider.overrideWithValue(settingsRepository),
      speechServiceProvider.overrideWithValue(
        speechService ?? DemoSpeechService(),
      ),
      audioPlaybackServiceProvider.overrideWithValue(_FakeAudioService()),
      dictionaryUpdateControllerProvider.overrideWith(
        _StaticUpdateController.new,
      ),
    ],
    child: const KotobaApp(),
  );
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _searchFor(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const Key('search-field')), query);
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump();
}

void _expectNoRenderException(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}

double _contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter = firstLuminance > secondLuminance
      ? firstLuminance
      : secondLuminance;
  final darker = firstLuminance > secondLuminance
      ? secondLuminance
      : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

String _accessibleName(SemanticsData data) {
  return data.label.isNotEmpty ? data.label : data.tooltip;
}

class _StaticUpdateController extends DictionaryUpdateController {
  @override
  DictionaryUpdateState build() {
    return const DictionaryUpdateState(
      phase: DictionaryUpdatePhase.unsupported,
      message: 'テストでは更新しません。',
      currentVersion: 'test',
    );
  }
}

class _FakeAudioService implements AudioPlaybackService {
  @override
  Future<void> play(String assetOrDataUri) async {}

  @override
  Future<void> stop() async {}
}

class _UnavailableSpeechService implements SpeechService {
  const _UnavailableSpeechService();

  @override
  Future<void> speakJapanese(String text) async {
    throw const JapaneseVoiceUnavailableException();
  }

  @override
  Future<void> stop() async {}
}
