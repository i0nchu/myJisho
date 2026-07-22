import 'package:sqlite3/sqlite3.dart';

Future<bool> isHealthySqliteDictionary(String path) async {
  final database = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    final integrity = database
        .select('PRAGMA integrity_check')
        .first
        .values
        .first;
    if (integrity != 'ok') return false;
    final tables = database.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'entries'",
    );
    if (tables.isEmpty) return false;
    database.select('SELECT entry_id, payload_json FROM entries LIMIT 1');
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
