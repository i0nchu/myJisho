import 'package:flutter/services.dart';

Future<String> prepareBundledDictionaryDatabase(
  AssetBundle bundle,
  String assetPath,
) {
  throw UnsupportedError(
    'Bundled native SQLite is unavailable on this platform.',
  );
}
