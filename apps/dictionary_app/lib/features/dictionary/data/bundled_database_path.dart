import 'package:flutter/services.dart';

import 'bundled_database_path_stub.dart'
    if (dart.library.io) 'bundled_database_path_io.dart'
    as implementation;

Future<String> prepareBundledDictionaryDatabase(
  AssetBundle bundle,
  String assetPath,
) {
  return implementation.prepareBundledDictionaryDatabase(bundle, assetPath);
}
