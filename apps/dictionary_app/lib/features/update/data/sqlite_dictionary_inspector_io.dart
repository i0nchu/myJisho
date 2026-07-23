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
  );
}

Future<bool> _inspect(
  String path, {
  int? expectedSchemaVersion,
  String? expectedDictionaryVersion,
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
