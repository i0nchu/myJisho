import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myjisho_dictionary_app/app.dart';
import 'package:myjisho_dictionary_app/features/dictionary/application/dictionary_providers.dart';
import 'package:myjisho_dictionary_app/features/dictionary/data/fixture_dictionary_repository.dart';
import 'package:myjisho_dictionary_app/features/library/application/library_controller.dart';
import 'package:myjisho_dictionary_app/features/library/data/user_library_repository.dart';
import 'package:myjisho_dictionary_app/features/media/application/audio_controller.dart';
import 'package:myjisho_dictionary_app/features/media/data/audio_playback_service.dart';
import 'package:myjisho_dictionary_app/features/pronunciation/application/speech_controller.dart';
import 'package:myjisho_dictionary_app/features/pronunciation/data/speech_service.dart';
import 'package:myjisho_dictionary_app/features/settings/application/settings_controller.dart';
import 'package:myjisho_dictionary_app/features/settings/data/settings_repository.dart';

import 'test_data.dart';

void main() {
  Widget app() {
    final repository = FixtureDictionaryRepository.fromEntries([
      testEntry(),
      testEntry(id: 'entry_hirou_001', headword: '拾う', reading: 'ひろう'),
    ]);
    return ProviderScope(
      overrides: [
        dictionaryRepositoryProvider.overrideWithValue(repository),
        userLibraryRepositoryProvider.overrideWithValue(
          InMemoryUserLibraryRepository(),
        ),
        settingsRepositoryProvider.overrideWithValue(
          InMemorySettingsRepository(),
        ),
        speechServiceProvider.overrideWithValue(DemoSpeechService()),
        audioPlaybackServiceProvider.overrideWithValue(_FakeAudioService()),
      ],
      child: const MyJishoApp(),
    );
  }

  testWidgets('shows a helpful empty result state', (tester) async {
    await tester.pumpWidget(app());
    await tester.enterText(find.byKey(const Key('search-field')), '存在しない');
    await tester.pump(const Duration(milliseconds: 130));
    await tester.pump();

    expect(find.text('ローカル辞書には見つかりませんでした'), findsOneWidget);
    expect(find.text('Enter または検索ボタンで送信すると、新しい詞条を生成します。'), findsOneWidget);
  });

  testWidgets('desktop layout opens a result in the detail column', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app());
    expect(find.text('言葉を選んでください'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('search-field')), '食べる');
    await tester.pump(const Duration(milliseconds: 130));
    await tester.pump();
    await tester.tap(find.byKey(const Key('result-entry_taberu_001')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('entry-entry_taberu_001')), findsOneWidget);
    expect(find.text('食べ物を口に入れて、飲み込む。'), findsWidgets);
  });

  testWidgets('favorite action updates accessible tooltip', (tester) async {
    await tester.pumpWidget(app());
    await tester.enterText(find.byKey(const Key('search-field')), '拾う');
    await tester.pump(const Duration(milliseconds: 130));
    await tester.pump();
    await tester.tap(find.byKey(const Key('result-entry_hirou_001')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('お気に入りに追加'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('お気に入りから削除'), findsOneWidget);
  });
}

class _FakeAudioService implements AudioPlaybackService {
  @override
  Future<void> play(String assetOrDataUri) async {}

  @override
  Future<void> stop() async {}
}
