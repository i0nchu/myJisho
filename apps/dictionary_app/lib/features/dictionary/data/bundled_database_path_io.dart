import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../update/data/dictionary_update_recovery.dart';

final Map<String, Future<String>> _startupPreparations =
    <String, Future<String>>{};

Future<String> prepareBundledDictionaryDatabase(
  AssetBundle bundle,
  String assetPath, {
  bool recoverInterruptedUpdate = false,
}) async {
  if (recoverInterruptedUpdate) {
    return _startupPreparations.putIfAbsent(
      assetPath,
      () => _prepareDatabase(bundle, assetPath, recover: true),
    );
  }
  return _prepareDatabase(bundle, assetPath, recover: false);
}

Future<String> _prepareDatabase(
  AssetBundle bundle,
  String assetPath, {
  required bool recover,
}) async {
  final directory = await getApplicationSupportDirectory();
  final databaseDirectory = Directory(p.join(directory.path, 'dictionary'));
  await databaseDirectory.create(recursive: true);
  final databaseFile = File(
    p.join(databaseDirectory.path, 'dictionary_fixture_v1.sqlite'),
  );
  if (!await databaseFile.exists()) {
    final data = await bundle.load(assetPath);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final temporaryFile = File('${databaseFile.path}.tmp');
    await temporaryFile.writeAsBytes(bytes, flush: true);
    await temporaryFile.rename(databaseFile.path);
  }
  if (recover) {
    await recoverInterruptedDictionaryUpdateBeforeOpen(databaseFile.path);
  }
  return databaseFile.path;
}
