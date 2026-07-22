import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';

abstract interface class AudioPlaybackService {
  Future<void> play(String assetOrDataUri);
  Future<void> stop();
}

class AudioPlayersPlaybackService implements AudioPlaybackService {
  AudioPlayersPlaybackService(this._player);

  final AudioPlayer _player;

  @override
  Future<void> play(String assetOrDataUri) async {
    if (assetOrDataUri.startsWith('data:audio/')) {
      final encoded = assetOrDataUri.substring(assetOrDataUri.indexOf(',') + 1);
      await _player.play(BytesSource(base64Decode(encoded)));
    } else {
      final assetPath = assetOrDataUri.startsWith('assets/')
          ? assetOrDataUri.substring('assets/'.length)
          : assetOrDataUri;
      await _player.play(AssetSource(assetPath));
    }
  }

  @override
  Future<void> stop() => _player.stop();
}
