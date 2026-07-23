import '../domain/release_manifest.dart';

Future<bool> isHealthySqliteDictionary(String path) async => false;

Future<bool> sqliteDictionaryMatchesManifest(
  String path,
  ReleaseManifest manifest,
) async => false;

Future<String> readDictionaryVersion(String path) async => '0.0.0';
