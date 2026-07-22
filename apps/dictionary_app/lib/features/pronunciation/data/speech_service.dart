import 'package:flutter_tts/flutter_tts.dart';

enum SpeechKind { synthesized, recorded }

abstract interface class SpeechService {
  Future<void> speakJapanese(String text);

  Future<void> stop();
}

/// Safe prototype adapter used until each platform runner wires a Japanese TTS
/// implementation. It deliberately reports success without pretending that a
/// bundled recording exists.
class DemoSpeechService implements SpeechService {
  String? lastSpokenText;

  @override
  Future<void> speakJapanese(String text) async {
    lastSpokenText = text;
  }

  @override
  Future<void> stop() async {
    lastSpokenText = null;
  }
}

class FlutterTtsSpeechService implements SpeechService {
  FlutterTtsSpeechService(this._tts);

  final FlutterTts _tts;
  bool _initialized = false;

  Future<void> _initialize() async {
    if (_initialized) return;
    await _tts.setLanguage('ja-JP');
    await _tts.setSpeechRate(0.46);
    await _tts.setPitch(1.0);
    await _tts.awaitSpeakCompletion(true);
    _initialized = true;
  }

  @override
  Future<void> speakJapanese(String text) async {
    await _initialize();
    final result = await _tts.speak(text);
    if (result != 1) {
      throw StateError('The system TTS engine rejected playback.');
    }
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
  }
}
