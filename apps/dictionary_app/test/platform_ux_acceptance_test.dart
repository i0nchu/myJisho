import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotoba_dictionary_app/app.dart';
import 'package:kotoba_dictionary_app/features/dictionary/application/dictionary_providers.dart';
import 'package:kotoba_dictionary_app/features/dictionary/data/dictionary_repository.dart';
import 'package:kotoba_dictionary_app/features/dictionary/data/fixture_dictionary_repository.dart';
import 'package:kotoba_dictionary_app/features/dictionary/domain/dictionary_entry.dart';
import 'package:kotoba_dictionary_app/features/dictionary/domain/search_hit.dart';
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
  setUp(() => debugDefaultTargetPlatformOverride = null);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('platform UX contract', () {
    testWidgets('desktop route keeps the workspace and search state alive', (
      tester,
    ) async {
      _setPlatform(TargetPlatform.windows);
      _setViewport(tester, const Size(1200, 800));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      final workspace = tester.element(
        find.byKey(const Key('dictionary-workspace-continuity')),
      );
      final editableBefore = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('search-field')),
          matching: find.byType(EditableText),
        ),
      );

      await _searchFor(tester, '食べる');
      await tester.tap(find.byKey(const Key('result-entry_taberu_001')));
      await tester.pumpAndSettle();

      expect(
        tester.element(
          find.byKey(const Key('dictionary-workspace-continuity')),
        ),
        same(workspace),
      );
      final editableAfter = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('search-field')),
          matching: find.byType(EditableText),
        ),
      );
      expect(editableAfter.controller, same(editableBefore.controller));
      expect(editableAfter.controller.text, '食べる');
      expect(find.byKey(const Key('entry-entry_taberu_001')), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byKey(const Key('desktop-platform-sidebar')), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('iOS uses Cupertino navigation and preserves search on pop', (
      tester,
    ) async {
      _setPlatform(TargetPlatform.iOS);
      _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoNavigationBar), findsOneWidget);
      expect(find.byType(CupertinoTabBar), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await _searchFor(tester, '食べる');
      await tester.tap(find.byKey(const Key('result-entry_taberu_001')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ios-entry-back')), findsOneWidget);

      await tester.tap(find.byTooltip('戻る'));
      await tester.pumpAndSettle();
      final editable = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const Key('search-field')),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.controller.text, '食べる');
      expect(find.byType(CupertinoTabBar), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
      testWidgets('$platform uses a desktop dialog and custom sidebar', (
        tester,
      ) async {
        _setPlatform(platform);
        _setViewport(tester, const Size(1200, 800));
        await tester.pumpWidget(_app());
        await tester.pumpAndSettle();

        expect(find.byType(NavigationRail), findsNothing);
        expect(
          find.byKey(const Key('desktop-platform-sidebar')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('settings-button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('desktop-settings-dialog')),
          findsOneWidget,
        );
        expect(find.byType(BottomSheet), findsNothing);
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('font scale persists on change end instead of every drag', (
      tester,
    ) async {
      _setPlatform(TargetPlatform.windows);
      _setViewport(tester, const Size(1200, 800));
      final settings = _RecordingSettingsRepository();
      await tester.pumpWidget(_app(settingsRepository: settings));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-button')));
      await tester.pumpAndSettle();

      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(1.2);
      await tester.pump();
      expect(settings.saved, isEmpty);

      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(1.2);
      await tester.pump();
      expect(settings.saved, hasLength(1));
      expect(settings.saved.single.fontScale, 1.2);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  testWidgets('search keeps previous hits and ignores stale completion', (
    tester,
  ) async {
    _setPlatform(TargetPlatform.windows);
    _setViewport(tester, const Size(1200, 800));
    final repository = _ControlledDictionaryRepository();
    await tester.pumpWidget(_app(repository: repository));
    await tester.pumpAndSettle();

    await _searchFor(tester, '食');
    repository.complete('食', [_hit(testEntry())]);
    await tester.pump();
    expect(find.byKey(const Key('result-entry_taberu_001')), findsOneWidget);

    await _searchFor(tester, '食べ');
    expect(find.byKey(const Key('result-entry_taberu_001')), findsOneWidget);
    expect(find.byKey(const Key('search-refresh-progress')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await _searchFor(tester, '拾');
    repository.complete('食べ', [_hit(testEntry())]);
    await tester.pump();
    expect(find.byKey(const Key('result-entry_taberu_001')), findsOneWidget);

    repository.complete('拾', [
      _hit(testEntry(id: 'entry_hirou_001', headword: '拾う', reading: 'ひろう')),
    ]);
    await tester.pump();
    expect(find.byKey(const Key('result-entry_hirou_001')), findsOneWidget);
    expect(find.byKey(const Key('result-entry_taberu_001')), findsNothing);
    final editable = tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('search-field')),
        matching: find.byType(EditableText),
      ),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  group('platform surface goldens', () {
    testWidgets('iOS compact home', (tester) async {
      _setPlatform(TargetPlatform.iOS);
      _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await expectLater(
        find.byKey(const Key('mobile-layout')),
        matchesGoldenFile('goldens/kotoba_ios_home.png'),
      );
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Windows desktop home', (tester) async {
      _setPlatform(TargetPlatform.windows);
      _setViewport(tester, const Size(1200, 800));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await expectLater(
        find.byKey(const Key('desktop-layout')),
        matchesGoldenFile('goldens/kotoba_windows_home.png'),
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

Widget _app({
  DictionaryRepository? repository,
  SettingsRepository? settingsRepository,
}) {
  return ProviderScope(
    overrides: [
      dictionaryRepositoryProvider.overrideWithValue(
        repository ??
            FixtureDictionaryRepository.fromEntries([
              testEntry(),
              testEntry(id: 'entry_hirou_001', headword: '拾う', reading: 'ひろう'),
            ]),
      ),
      userLibraryRepositoryProvider.overrideWithValue(
        InMemoryUserLibraryRepository(),
      ),
      settingsRepositoryProvider.overrideWithValue(
        settingsRepository ?? InMemorySettingsRepository(),
      ),
      speechServiceProvider.overrideWithValue(DemoSpeechService()),
      audioPlaybackServiceProvider.overrideWithValue(_FakeAudioService()),
      dictionaryUpdateControllerProvider.overrideWith(
        _StaticUpdateController.new,
      ),
    ],
    child: const KotobaApp(),
  );
}

void _setPlatform(TargetPlatform platform) {
  debugDefaultTargetPlatformOverride = platform;
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

SearchHit _hit(DictionaryEntry entry) {
  return SearchHit(
    entry: entry,
    kind: MatchKind.primaryExact,
    baseScore: 1000,
    score: 1120,
    matchedKey: entry.headword,
    modifiers: const [],
  );
}

class _ControlledDictionaryRepository implements DictionaryRepository {
  final _requests = <String, Completer<List<SearchHit>>>{};

  @override
  Future<List<SearchHit>> search(String rawQuery, {int limit = 50}) {
    return (_requests[rawQuery] ??= Completer<List<SearchHit>>()).future;
  }

  void complete(String query, List<SearchHit> hits) {
    _requests[query]!.complete(hits);
  }

  @override
  Future<List<DictionaryEntry>> allEntries() async => const [];

  @override
  Future<DictionaryEntry?> findById(String entryId) async => null;

  @override
  Future<List<DictionaryEntry>> findByIds(Iterable<String> entryIds) async =>
      const [];
}

class _RecordingSettingsRepository implements SettingsRepository {
  final saved = <AppSettings>[];

  @override
  Future<AppSettings> load() async => const AppSettings();

  @override
  Future<void> save(AppSettings value) async {
    saved.add(value);
  }
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
