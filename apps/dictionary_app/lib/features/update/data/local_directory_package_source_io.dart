import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../domain/release_manifest.dart';
import 'dictionary_update_service.dart';

DictionaryPackageSource createLocalDirectoryPackageSource(
  String directoryPath,
) => LocalDirectoryPackageSource(directoryPath);

class LocalDirectoryPackageSource implements DictionaryPackageSource {
  LocalDirectoryPackageSource(this.directoryPath);

  final String directoryPath;

  @override
  Future<Map<String, Object?>> fetchManifest() async {
    final file = File(p.join(directoryPath, 'release-manifest.json'));
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('release-manifest.json must be an object.');
    }
    return decoded;
  }

  @override
  Future<Uint8List> fetchDatabase(ReleaseManifest manifest) async {
    final fileName = manifest.databaseFile;
    final safeName =
        RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(fileName) &&
        p.basename(fileName) == fileName &&
        !fileName.contains('..');
    if (!safeName) {
      throw const FormatException('database_file must be a safe file name.');
    }
    return File(p.join(directoryPath, fileName)).readAsBytes();
  }
}
