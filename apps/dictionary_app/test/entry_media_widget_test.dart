import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotoba_dictionary_app/features/dictionary/application/dictionary_providers.dart';
import 'package:kotoba_dictionary_app/features/dictionary/data/fixture_dictionary_repository.dart';
import 'package:kotoba_dictionary_app/features/dictionary/presentation/entry_detail_view.dart';
import 'package:kotoba_dictionary_app/features/library/application/library_controller.dart';
import 'package:kotoba_dictionary_app/features/library/data/user_library_repository.dart';
import 'package:kotoba_dictionary_app/features/media/application/audio_controller.dart';
import 'package:kotoba_dictionary_app/features/media/data/audio_playback_service.dart';
import 'package:kotoba_dictionary_app/features/pronunciation/application/speech_controller.dart';
import 'package:kotoba_dictionary_app/features/pronunciation/data/speech_service.dart';

import 'test_data.dart';

void main() {
  testWidgets('renders offline image and audio fields and invokes playback', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final audio = _RecordingAudioService();
    final entry = testEntry(
      imageAsset:
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      audioAsset: 'data:audio/wav;base64,UklGRg==',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dictionaryRepositoryProvider.overrideWithValue(
            FixtureDictionaryRepository.fromEntries([entry]),
          ),
          userLibraryRepositoryProvider.overrideWithValue(
            InMemoryUserLibraryRepository(),
          ),
          speechServiceProvider.overrideWithValue(DemoSpeechService()),
          audioPlaybackServiceProvider.overrideWithValue(audio),
        ],
        child: const MaterialApp(
          home: Scaffold(body: EntryDetailView(entryId: 'entry_taberu_001')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('画像'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);

    await tester.ensureVisible(find.text('音声資料'));
    await tester.tap(find.text('音声資料'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('play-audio-asset')));
    await tester.pumpAndSettle();
    expect(audio.lastAsset, startsWith('data:audio/wav'));
  });
}

class _RecordingAudioService implements AudioPlaybackService {
  String? lastAsset;

  @override
  Future<void> play(String assetOrDataUri) async => lastAsset = assetOrDataUri;

  @override
  Future<void> stop() async {}
}
