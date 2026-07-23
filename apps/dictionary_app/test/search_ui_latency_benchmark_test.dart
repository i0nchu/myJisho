import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kotoba_dictionary_app/app.dart';
import 'package:kotoba_dictionary_app/features/dictionary/application/dictionary_providers.dart';
import 'package:kotoba_dictionary_app/features/dictionary/data/fixture_dictionary_repository.dart';
import 'package:kotoba_dictionary_app/features/library/application/library_controller.dart';
import 'package:kotoba_dictionary_app/features/library/data/user_library_repository.dart';
import 'package:kotoba_dictionary_app/features/media/application/audio_controller.dart';
import 'package:kotoba_dictionary_app/features/media/data/audio_playback_service.dart';
import 'package:kotoba_dictionary_app/features/pronunciation/application/speech_controller.dart';
import 'package:kotoba_dictionary_app/features/pronunciation/data/speech_service.dart';
import 'package:kotoba_dictionary_app/features/settings/application/settings_controller.dart';
import 'package:kotoba_dictionary_app/features/settings/data/settings_repository.dart';

import 'test_data.dart';

/// A deterministic widget-pipeline regression benchmark.
///
/// This is deliberately not evidence for release-build cold start, a physical
/// device, or the 100k SQLite acceptance target. It measures Enter/submit to a
/// rendered first result on the Flutter test VM with a fixed 10k in-memory
/// fixture. Run the documented command on the same host to compare revisions.
void main() {
  testWidgets('10k fixture submit-to-first-result latency stays bounded', (
    tester,
  ) async {
    const hostDebugRegressionBudget = Duration(milliseconds: 800);
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final entries = List.generate(10000, (index) {
      final suffix = index.toString().padLeft(5, '0');
      return testEntry(
        id: 'entry_benchmark_$suffix',
        headword: '語$suffix',
        reading: 'ご$suffix',
      );
    }, growable: false);
    final repository = FixtureDictionaryRepository.fromEntries(entries);

    await tester.pumpWidget(
      ProviderScope(
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
        child: const KotobaApp(),
      ),
    );
    await tester.pumpAndSettle();

    for (var index = 0; index < 5; index++) {
      await _submitAndRender(tester, '語0$index');
    }

    final samples = <Duration>[];
    for (var index = 0; index < 30; index++) {
      final stopwatch = Stopwatch()..start();
      await _submitAndRender(tester, '語0${index % 10}');
      stopwatch.stop();
      samples.add(stopwatch.elapsed);
    }

    samples.sort();
    final p50 = samples[14];
    final p95 = samples[28];
    final maximum = samples.last;
    tester.printToConsole(
      'KOTOBA_UI_SEARCH_BENCHMARK '
      'fixture=in_memory_10k samples=30 warmups=5 '
      'scope=widget_vm_submit_to_first_result '
      'p50_us=${p50.inMicroseconds} '
      'p95_us=${p95.inMicroseconds} '
      'max_us=${maximum.inMicroseconds} '
      'budget_us=${hostDebugRegressionBudget.inMicroseconds} '
      'not_cold_start=true not_physical_device=true not_sqlite_100k=true',
    );

    expect(find.byKey(const Key('search-results')), findsOneWidget);
    expect(
      p95,
      lessThan(hostDebugRegressionBudget),
      reason:
          'This host-debug 10k in-memory regression budget is not the '
          'release-device or 100k SQLite acceptance result.',
    );
  });
}

Future<void> _submitAndRender(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(const Key('search-field')), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('search-results')), findsOneWidget);
}

class _FakeAudioService implements AudioPlaybackService {
  @override
  Future<void> play(String assetOrDataUri) async {}

  @override
  Future<void> stop() async {}
}
