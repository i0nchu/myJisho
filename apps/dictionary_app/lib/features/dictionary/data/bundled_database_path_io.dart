import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String> prepareBundledDictionaryDatabase(
  AssetBundle bundle,
  String assetPath,
) async {
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
  return databaseFile.path;
}
