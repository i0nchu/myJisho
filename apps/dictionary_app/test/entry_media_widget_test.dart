import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotoba_dictionary_app/features/dictionary/application/dictionary_providers.dart';
import 'package:kotoba_dictionary_app/features/dictionary/data/fixture_dictionary_repository.dart';
import 'package:kotoba_dictionary_app/features/dictionary/domain/dictionary_entry.dart';
import 'package:kotoba_dictionary_app/features/dictionary/presentation/entry_detail_view.dart';
import 'package:kotoba_dictionary_app/features/library/application/library_controller.dart';
import 'package:kotoba_dictionary_app/features/library/data/user_library_repository.dart';
import 'package:kotoba_dictionary_app/features/media/application/audio_controller.dart';
import 'package:kotoba_dictionary_app/features/media/data/audio_playback_service.dart';
import 'package:kotoba_dictionary_app/features/pronunciation/application/speech_controller.dart';
import 'package:kotoba_dictionary_app/features/pronunciation/data/speech_service.dart';

import 'test_data.dart';

void main() {
  testWidgets('TTS button speaks the reading and reports success', (
    tester,
  ) async {
    final speech = DemoSpeechService();
    await tester.pumpWidget(_detailApp(speech));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tts-button')));
    await tester.pumpAndSettle();

    expect(speech.lastSpokenText, 'たべる');
    expect(find.text('日本語の合成音声を再生しました。'), findsOneWidget);
    expect(find.textContaining('日本語のシステム音声が見つかりません'), findsNothing);
  });

  testWidgets('TTS button reports a missing Japanese voice without success', (
    tester,
  ) async {
    await tester.pumpWidget(_detailApp(const _UnavailableSpeechService()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('tts-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('日本語のシステム音声が見つかりません'), findsOneWidget);
    expect(find.text('日本語の合成音声を再生しました。'), findsNothing);
  });

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

  testWidgets(
    'uses a learner-facing relation label instead of a contract code',
    (tester) async {
      final entry = testEntry(
        relations: const [
          RelatedEntry(
            headword: '橋',
            relation: 'easily_confused',
            note: '「箸」は食事の道具で、「橋」は川などを渡る場所。',
          ),
        ],
      );

      await tester.pumpWidget(_detailApp(DemoSpeechService(), entry: entry));
      await tester.pumpAndSettle();

      expect(find.text('橋　間違えやすい言葉'), findsOneWidget);
      expect(find.textContaining('easily_confused'), findsNothing);
    },
  );

  testWidgets(
    'generated entry shows low-noise metadata and management actions',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final entry = testEntry(
        versionOrigin: 'generated',
        generationInfo: GenerationInfo(
          model: 'Qwen3 8B',
          generatedAt: DateTime.utc(2026, 7, 27, 13, 16),
          generatorVersion: 'kotoba-local-1',
          sourceCount: 1,
          knowledgeOnly: false,
          sources: [
            GenerationSource(
              sourceId: 'web_1',
              title: '日本語版ウィクショナリー',
              url: 'https://ja.wiktionary.org/wiki/食べる',
              snippet: '食べるについての資料。',
              retrievedAt: DateTime.utc(2026, 7, 27, 13, 15),
              licenseSpdx: 'CC-BY-SA-4.0',
            ),
          ],
        ),
      );

      await tester.pumpWidget(_detailApp(DemoSpeechService(), entry: entry));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('review-status-banner')), findsNothing);
      expect(find.textContaining('利用できる出典が少ない'), findsOneWidget);
      expect(find.byKey(const Key('local-entry-menu')), findsOneWidget);

      await tester.ensureVisible(find.text('生成情報'));
      await tester.tap(find.text('生成情報'));
      await tester.pumpAndSettle();
      expect(find.text('Qwen3 8B'), findsOneWidget);
      expect(find.text('1 件'), findsOneWidget);

      await tester.tap(find.byKey(const Key('local-entry-menu')));
      await tester.pumpAndSettle();
      expect(find.text('編集'), findsOneWidget);
      expect(find.text('バージョン履歴'), findsOneWidget);
      expect(find.text('再生成'), findsOneWidget);
      expect(find.text('現在版をロック'), findsOneWidget);
      expect(find.text('削除'), findsOneWidget);
    },
  );
}

Widget _detailApp(SpeechService speechService, {DictionaryEntry? entry}) {
  final detailEntry = entry ?? testEntry();
  return ProviderScope(
    overrides: [
      dictionaryRepositoryProvider.overrideWithValue(
        FixtureDictionaryRepository.fromEntries([detailEntry]),
      ),
      userLibraryRepositoryProvider.overrideWithValue(
        InMemoryUserLibraryRepository(),
      ),
      speechServiceProvider.overrideWithValue(speechService),
      audioPlaybackServiceProvider.overrideWithValue(_RecordingAudioService()),
    ],
    child: const MaterialApp(
      home: Scaffold(body: EntryDetailView(entryId: 'entry_taberu_001')),
    ),
  );
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

class _RecordingAudioService implements AudioPlaybackService {
  String? lastAsset;

  @override
  Future<void> play(String assetOrDataUri) async => lastAsset = assetOrDataUri;

  @override
  Future<void> stop() async {}
}
