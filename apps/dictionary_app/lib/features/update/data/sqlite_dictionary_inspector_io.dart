import 'package:sqlite3/sqlite3.dart';

import '../domain/release_manifest.dart';

const _applicationId = 1263489602;
const _requiredTables = <String>{
  'entries',
  'entry_forms',
  'readings',
  'parts_of_speech',
  'entry_parts_of_speech',
  'senses',
  'definitions',
  'examples',
  'relations',
  'images',
  'audio_assets',
  'search_keys',
  'sources',
  'entry_sources',
  'editorial_reviews',
  'metadata',
};

Future<bool> isHealthySqliteDictionary(String path) async {
  return _inspect(path);
}

Future<bool> sqliteDictionaryMatchesManifest(
  String path,
  ReleaseManifest manifest,
) {
  return _inspect(
    path,
    expectedSchemaVersion: manifest.schemaVersion,
    expectedDictionaryVersion: manifest.dictionaryVersion,
    expectedAssets: manifest.assets,
  );
}

Future<bool> _inspect(
  String path, {
  int? expectedSchemaVersion,
  String? expectedDictionaryVersion,
  List<ReleaseAssetRecord>? expectedAssets,
}) async {
  final database = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    final integrity = database.select('PRAGMA quick_check').first.values.first;
    if (integrity != 'ok') return false;
    final applicationId =
        database.select('PRAGMA application_id').first.values.first as int;
    if (applicationId != _applicationId) return false;
    final userVersion =
        database.select('PRAGMA user_version').first.values.first as int;
    if (expectedSchemaVersion != null && userVersion != expectedSchemaVersion) {
      return false;
    }
    final tables = database
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name']! as String)
        .toSet();
    if (_requiredTables.difference(tables).isNotEmpty) return false;
    final entryColumns = database
        .select('PRAGMA table_info(entries)')
        .map((row) => row['name']! as String)
        .toSet();
    if (!entryColumns.containsAll(<String>{
      'entry_id',
      'frequency_rank',
      'payload_json',
    })) {
      return false;
    }
    database.select('SELECT entry_id, payload_json FROM entries LIMIT 1');
    if (database.select('PRAGMA foreign_key_check').isNotEmpty) return false;
    if (expectedDictionaryVersion != null) {
      final versions = database.select(
        "SELECT metadata_value FROM metadata "
        "WHERE metadata_key = 'dictionary_version' LIMIT 1",
      );
      if (versions.isEmpty ||
          versions.first['metadata_value'] != expectedDictionaryVersion) {
        return false;
      }
    }
    if (expectedAssets != null) {
      final expectedById = <String, ReleaseAssetRecord>{
        for (final asset in expectedAssets) asset.assetId: asset,
      };
      final actualRows = database.select('''
SELECT asset_id, 'image' AS kind, COALESCE(local_path, '') AS path,
       sha256, source_id, license_spdx
FROM images
UNION ALL
SELECT asset_id, 'audio' AS kind, COALESCE(local_path, '') AS path,
       sha256, source_id, license_spdx
FROM audio_assets
''');
      if (actualRows.length != expectedById.length) return false;
      for (final row in actualRows) {
        final expected = expectedById[row['asset_id']! as String];
        if (expected == null ||
            row['kind'] != expected.kind ||
            row['path'] != expected.path ||
            row['sha256'] != expected.sha256 ||
            row['source_id'] != expected.sourceId ||
            row['license_spdx'] != expected.licenseSpdx) {
          return false;
        }
      }
    }
    return true;
  } on SqliteException {
    return false;
  } finally {
    database.close();
  }
}

Future<String> readDictionaryVersion(String path) async {
  final database = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    final rows = database.select(
      "SELECT metadata_value FROM metadata WHERE metadata_key = 'dictionary_version' LIMIT 1",
    );
    return rows.isEmpty ? '0.0.0' : rows.first['metadata_value']! as String;
  } on SqliteException {
    return '0.0.0';
  } finally {
    database.close();
  }
}
