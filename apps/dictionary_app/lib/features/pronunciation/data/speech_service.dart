import 'package:flutter_tts/flutter_tts.dart';

enum SpeechKind { synthesized, recorded }

class JapaneseVoiceUnavailableException implements Exception {
  const JapaneseVoiceUnavailableException();

  @override
  String toString() => 'No Japanese system TTS voice is available.';
}

class SpeechConfigurationException implements Exception {
  const SpeechConfigurationException(this.operation);

  final String operation;

  @override
  String toString() => 'System TTS configuration failed at $operation.';
}

class SpeechPlaybackException implements Exception {
  const SpeechPlaybackException();

  @override
  String toString() => 'The system TTS engine rejected playback.';
}

abstract interface class SpeechService {
  Future<void> speakJapanese(String text);

  Future<void> stop();
}

abstract interface class TtsDriver {
  Future<Object?> getVoices();

  Future<Object?> setLanguage(String language);

  Future<Object?> setVoice(Map<String, String> voice);

  Future<Object?> setSpeechRate(double rate);

  Future<Object?> setPitch(double pitch);

  Future<Object?> awaitSpeakCompletion(bool awaitCompletion);

  Future<Object?> speak(String text);

  Future<Object?> stop();
}

class FlutterTtsDriver implements TtsDriver {
  FlutterTtsDriver(this._tts);

  final FlutterTts _tts;

  @override
  Future<Object?> getVoices() async => _tts.getVoices;

  @override
  Future<Object?> setLanguage(String language) => _tts.setLanguage(language);

  @override
  Future<Object?> setVoice(Map<String, String> voice) => _tts.setVoice(voice);

  @override
  Future<Object?> setSpeechRate(double rate) => _tts.setSpeechRate(rate);

  @override
  Future<Object?> setPitch(double pitch) => _tts.setPitch(pitch);

  @override
  Future<Object?> awaitSpeakCompletion(bool awaitCompletion) =>
      _tts.awaitSpeakCompletion(awaitCompletion);

  @override
  Future<Object?> speak(String text) => _tts.speak(text);

  @override
  Future<Object?> stop() => _tts.stop();
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
  FlutterTtsSpeechService(this._driver);

  final TtsDriver _driver;
  bool _initialized = false;
  Future<void>? _initialization;

  Future<void> _initialize() async {
    if (_initialized) return;
    final inProgress = _initialization;
    if (inProgress != null) return inProgress;

    final attempt = _configure();
    _initialization = attempt;
    try {
      await attempt;
      _initialized = true;
    } finally {
      _initialization = null;
    }
  }

  Future<void> _configure() async {
    final voices = _parseVoices(await _driver.getVoices());
    final japaneseVoice = _selectJapaneseVoice(voices);
    if (japaneseVoice == null) {
      throw const JapaneseVoiceUnavailableException();
    }

    await _requireSuccess(
      _driver.setLanguage(japaneseVoice.locale),
      operationName: 'setLanguage',
    );
    await _requireSuccess(
      _driver.setVoice(japaneseVoice.toPlatformMap()),
      operationName: 'setVoice',
    );
    await _requireSuccess(
      _driver.setSpeechRate(0.46),
      operationName: 'setSpeechRate',
    );
    await _requireSuccess(_driver.setPitch(1.0), operationName: 'setPitch');
    await _requireSuccess(
      _driver.awaitSpeakCompletion(true),
      operationName: 'awaitSpeakCompletion',
    );
  }

  @override
  Future<void> speakJapanese(String text) async {
    await _initialize();
    final result = await _driver.speak(text);
    if (!_isSuccess(result)) {
      throw const SpeechPlaybackException();
    }
  }

  @override
  Future<void> stop() async {
    await _driver.stop();
  }
}

Future<void> _requireSuccess(
  Future<Object?> operation, {
  required String operationName,
}) async {
  final result = await operation;
  if (!_isSuccess(result)) {
    throw SpeechConfigurationException(operationName);
  }
}

bool _isSuccess(Object? result) => result == 1 || result == true;

List<_TtsVoice> _parseVoices(Object? rawVoices) {
  if (rawVoices is! Iterable<Object?>) return const [];

  return rawVoices
      .whereType<Map<Object?, Object?>>()
      .map(_TtsVoice.tryParse)
      .whereType<_TtsVoice>()
      .toList(growable: false);
}

_TtsVoice? _selectJapaneseVoice(List<_TtsVoice> voices) {
  _TtsVoice? languageFallback;
  for (final voice in voices) {
    final normalizedLocale = _normalizeLocale(voice.locale);
    if (normalizedLocale == 'ja-jp') return voice;
    if (languageFallback == null && _isJapaneseLocale(normalizedLocale)) {
      languageFallback = voice;
    }
  }
  return languageFallback;
}

String _normalizeLocale(String locale) =>
    locale.trim().replaceAll('_', '-').toLowerCase();

bool _isJapaneseLocale(String normalizedLocale) =>
    normalizedLocale == 'ja' || normalizedLocale.startsWith('ja-');

class _TtsVoice {
  const _TtsVoice({required this.name, required this.locale, this.identifier});

  static _TtsVoice? tryParse(Map<Object?, Object?> voice) {
    final name = voice['name']?.toString().trim();
    final locale = voice['locale']?.toString().trim();
    final identifier = voice['identifier']?.toString().trim();
    if (name == null || name.isEmpty || locale == null || locale.isEmpty) {
      return null;
    }
    return _TtsVoice(
      name: name,
      locale: locale,
      identifier: identifier == null || identifier.isEmpty ? null : identifier,
    );
  }

  final String name;
  final String locale;
  final String? identifier;

  Map<String, String> toPlatformMap() {
    final platformVoice = {'name': name, 'locale': locale};
    final identifier = this.identifier;
    if (identifier != null) platformVoice['identifier'] = identifier;
    return platformVoice;
  }
}
