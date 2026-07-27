import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../data/speech_service.dart';

final speechServiceProvider = Provider<SpeechService>((ref) {
  return FlutterTtsSpeechService(FlutterTtsDriver(FlutterTts()));
});

class SpeechController extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async => null;

  Future<void> speak(String text) async {
    state = const AsyncLoading();
    try {
      await ref.read(speechServiceProvider).speakJapanese(text);
      state = AsyncData(text);
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }
}

final speechControllerProvider =
    AsyncNotifierProvider<SpeechController, String?>(SpeechController.new);

String speechFailureMessage(Object error) {
  if (error is JapaneseVoiceUnavailableException) {
    return '日本語のシステム音声が見つかりません。端末の音声設定で日本語を追加してください。';
  }
  if (error is SpeechConfigurationException) {
    return '日本語のシステム音声を設定できませんでした。音声設定を確認して、もう一度お試しください。';
  }
  return '合成音声を再生できませんでした。もう一度お試しください。';
}
