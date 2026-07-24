import 'package:flutter_test/flutter_test.dart';
import 'package:kotoba_dictionary_app/features/pronunciation/data/speech_service.dart';

void main() {
  group('FlutterTtsSpeechService', () {
    test('fails closed when only a Chinese voice is installed', () async {
      final driver = _FakeTtsDriver(
        voices: [
          {'name': 'Hanhan', 'locale': 'zh-TW'},
        ],
      );
      final service = FlutterTtsSpeechService(driver);

      await expectLater(
        service.speakJapanese('がっこう'),
        throwsA(isA<JapaneseVoiceUnavailableException>()),
      );

      expect(driver.calls, ['getVoices']);
      expect(driver.spokenText, isNull);
    });

    test('normalizes locale and explicitly selects a Japanese voice', () async {
      final driver = _FakeTtsDriver(
        voices: [
          {'name': 'Hanhan', 'locale': 'zh-TW'},
          {
            'name': 'Kyoko',
            'locale': 'ja_JP',
            'identifier': 'com.apple.voice.compact.ja-JP.Kyoko',
          },
        ],
      );
      final service = FlutterTtsSpeechService(driver);

      await service.speakJapanese('がっこう');

      expect(driver.selectedLanguage, 'ja_JP');
      expect(driver.selectedVoice, {
        'name': 'Kyoko',
        'locale': 'ja_JP',
        'identifier': 'com.apple.voice.compact.ja-JP.Kyoko',
      });
      expect(driver.spokenText, 'がっこう');
      expect(driver.calls, [
        'getVoices',
        'setLanguage:ja_JP',
        'setVoice:Kyoko:ja_JP',
        'setSpeechRate:0.46',
        'setPitch:1.0',
        'awaitSpeakCompletion:true',
        'speak:がっこう',
      ]);
    });

    test('accepts a case-insensitive Japanese language fallback', () async {
      final driver = _FakeTtsDriver(
        voices: [
          {'name': 'Japanese', 'locale': 'JA'},
        ],
      );
      final service = FlutterTtsSpeechService(driver);

      await service.speakJapanese('しんぶん');

      expect(driver.selectedLanguage, 'JA');
      expect(driver.spokenText, 'しんぶん');
    });

    test('setLanguage failure does not speak and can be retried', () async {
      final driver = _FakeTtsDriver(
        voices: [
          {'name': 'Haruka', 'locale': 'ja-JP'},
        ],
        setLanguageResult: 0,
      );
      final service = FlutterTtsSpeechService(driver);

      await expectLater(
        service.speakJapanese('たべる'),
        throwsA(
          isA<SpeechConfigurationException>().having(
            (error) => error.operation,
            'operation',
            'setLanguage',
          ),
        ),
      );
      expect(driver.spokenText, isNull);
      expect(driver.calls, ['getVoices', 'setLanguage:ja-JP']);

      driver
        ..setLanguageResult = 1
        ..calls.clear();
      await service.speakJapanese('たべる');

      expect(driver.calls.first, 'getVoices');
      expect(driver.spokenText, 'たべる');
    });

    test('setVoice failure does not speak and can be retried', () async {
      final driver = _FakeTtsDriver(
        voices: [
          {'name': 'Haruka', 'locale': 'ja-JP'},
        ],
        setVoiceResult: 0,
      );
      final service = FlutterTtsSpeechService(driver);

      await expectLater(
        service.speakJapanese('しんぶん'),
        throwsA(
          isA<SpeechConfigurationException>().having(
            (error) => error.operation,
            'operation',
            'setVoice',
          ),
        ),
      );
      expect(driver.spokenText, isNull);
      expect(driver.calls, [
        'getVoices',
        'setLanguage:ja-JP',
        'setVoice:Haruka:ja-JP',
      ]);

      driver
        ..setVoiceResult = 1
        ..calls.clear();
      await service.speakJapanese('しんぶん');

      expect(driver.calls.first, 'getVoices');
      expect(driver.spokenText, 'しんぶん');
    });

    for (final scenario in [
      (
        operation: 'setSpeechRate',
        driver: _FakeTtsDriver(
          voices: [
            {'name': 'Haruka', 'locale': 'ja-JP'},
          ],
          setSpeechRateResult: 0,
        ),
      ),
      (
        operation: 'setPitch',
        driver: _FakeTtsDriver(
          voices: [
            {'name': 'Haruka', 'locale': 'ja-JP'},
          ],
          setPitchResult: 0,
        ),
      ),
      (
        operation: 'awaitSpeakCompletion',
        driver: _FakeTtsDriver(
          voices: [
            {'name': 'Haruka', 'locale': 'ja-JP'},
          ],
          awaitCompletionResult: 0,
        ),
      ),
    ]) {
      test('${scenario.operation} failure is fail-closed', () async {
        await expectLater(
          FlutterTtsSpeechService(scenario.driver).speakJapanese('がっこう'),
          throwsA(
            isA<SpeechConfigurationException>().having(
              (error) => error.operation,
              'operation',
              scenario.operation,
            ),
          ),
        );

        expect(scenario.driver.spokenText, isNull);
      });
    }

    test('reports a typed playback failure', () async {
      final driver = _FakeTtsDriver(
        voices: [
          {'name': 'Haruka', 'locale': 'ja-JP'},
        ],
        speakResult: 0,
      );
      final service = FlutterTtsSpeechService(driver);

      await expectLater(
        service.speakJapanese('たべる'),
        throwsA(isA<SpeechPlaybackException>()),
      );
    });
  });
}

class _FakeTtsDriver implements TtsDriver {
  _FakeTtsDriver({
    required this.voices,
    this.setLanguageResult = 1,
    this.setVoiceResult = 1,
    this.setSpeechRateResult = 1,
    this.setPitchResult = 1,
    this.awaitCompletionResult = 1,
    this.speakResult = 1,
  });

  Object? voices;
  Object? setLanguageResult;
  Object? setVoiceResult;
  Object? setSpeechRateResult;
  Object? setPitchResult;
  Object? awaitCompletionResult;
  Object? speakResult;
  String? selectedLanguage;
  Map<String, String>? selectedVoice;
  String? spokenText;
  final List<String> calls = [];

  @override
  Future<Object?> getVoices() async {
    calls.add('getVoices');
    return voices;
  }

  @override
  Future<Object?> setLanguage(String language) async {
    calls.add('setLanguage:$language');
    selectedLanguage = language;
    return setLanguageResult;
  }

  @override
  Future<Object?> setVoice(Map<String, String> voice) async {
    calls.add('setVoice:${voice['name']}:${voice['locale']}');
    selectedVoice = voice;
    return setVoiceResult;
  }

  @override
  Future<Object?> setSpeechRate(double rate) async {
    calls.add('setSpeechRate:$rate');
    return setSpeechRateResult;
  }

  @override
  Future<Object?> setPitch(double pitch) async {
    calls.add('setPitch:$pitch');
    return setPitchResult;
  }

  @override
  Future<Object?> awaitSpeakCompletion(bool awaitCompletion) async {
    calls.add('awaitSpeakCompletion:$awaitCompletion');
    return awaitCompletionResult;
  }

  @override
  Future<Object?> speak(String text) async {
    calls.add('speak:$text');
    spokenText = text;
    return speakResult;
  }

  @override
  Future<Object?> stop() async {
    calls.add('stop');
    return 1;
  }
}
