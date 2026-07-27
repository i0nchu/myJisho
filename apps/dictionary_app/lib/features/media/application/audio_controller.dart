import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/audio_playback_service.dart';

final audioPlaybackServiceProvider = Provider<AudioPlaybackService>((ref) {
  final player = AudioPlayer();
  ref.onDispose(player.dispose);
  return AudioPlayersPlaybackService(player);
});

class AudioController extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async => null;

  Future<void> play(String asset) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      await ref.read(audioPlaybackServiceProvider).play(asset);
      return asset;
    });
  }
}

final audioControllerProvider = AsyncNotifierProvider<AudioController, String?>(
  AudioController.new,
);
