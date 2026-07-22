import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../data/speech_service.dart';

final speechServiceProvider = Provider<SpeechService>((ref) {
  return FlutterTtsSpeechService(FlutterTts());
});

class SpeechController extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async => null;

  Future<void> speak(String text) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await ref.read(speechServiceProvider).speakJapanese(text);
      return text;
    });
  }
}

final speechControllerProvider =
    AsyncNotifierProvider<SpeechController, String?>(SpeechController.new);
