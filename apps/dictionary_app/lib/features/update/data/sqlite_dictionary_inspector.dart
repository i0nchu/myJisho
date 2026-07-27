import 'sqlite_dictionary_inspector_stub.dart'
    if (dart.library.io) 'sqlite_dictionary_inspector_io.dart'
    as implementation;

import '../domain/release_manifest.dart';

Future<bool> isHealthySqliteDictionary(String path) =>
    implementation.isHealthySqliteDictionary(path);

Future<bool> sqliteDictionaryMatchesManifest(
  String path,
  ReleaseManifest manifest,
) => implementation.sqliteDictionaryMatchesManifest(path, manifest);

Future<String> readDictionaryVersion(String path) =>
    implementation.readDictionaryVersion(path);
